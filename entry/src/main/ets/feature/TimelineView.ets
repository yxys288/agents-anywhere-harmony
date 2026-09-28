/**
 * 时间线**视图层**（R42 性能轮新增）：增量投影缓存 + 乐观消息叠加。
 *
 * 为什么需要它：`SessionDetailStore` 的 `messages` 原先有 4 处 `this.messages = projectTimeline(this.items)`，
 * 而 `projectTimeline` 是**全量**投影 —— 流式期间每收到一批增量就把整个 `items` 重新投影一遍，
 * 一轮回复 M 次更新 × N 条历史 ⇒ O(N·M) 次投影；同时那 3 处乐观消息的 `concat`/`filter`
 * 每次都要复制整个 messages 数组。
 *
 * 本文件把这两件事都变成增量：
 * 1. `TimelineProjectionCache`：按 `item.id` 缓存「item → 投影结果」，只有**新出现**或**引用变化**
 *  的 item 才真正执行投影。等价性依据见该类的注释。
 * 2. `TimelineMessageView`：在增量投影之上叠加一层「乐观消息」（本地已发出、服务端尚未回执的那几条），
 *  并用增量索引判定「服务端是否已回执」—— 只扫本次新投影的 item，不再每次全量扫 `items`。
 *
 * ⚠️ 硬约束：`view.messages()` 必须**逐项等于** `projectTimeline(items)` 叠加未回执的乐观消息
 * （条数、顺序、每个字段全等）。Node 侧随机序列自测见 `tools/logic-test/suite-timeline-incremental.mjs`。
 */

import { RemoteTimelineItem } from '../model/Types';
import {
  MessageAuthor, MessageKind, TimelineAttachment, TimelineMessage, projectTimeline, sortTimelineMessages
} from './TimelineProjection';

/** 乐观消息 id 前缀（服务端 item id 不会以它开头，所以不会撞车）。 */
export const OPTIMISTIC_ID_PREFIX: string = 'optimistic:';

/** 乐观消息的渲染 id（对应原 appendOptimistic 里的 `optimistic:<clientMessageId>#0`）。 */
export function optimisticMessageId(clientMessageId: string): string {
  return OPTIMISTIC_ID_PREFIX + clientMessageId + '#0';
}

function optimisticSourceId(clientMessageId: string): string {
  return OPTIMISTIC_ID_PREFIX + clientMessageId;
}

/**
 * 造一条「发送中」的乐观用户消息（原 `SessionDetailStore.appendOptimistic()` 的构造段原样搬来）。
 *
 * `createdAt` 由调用方传入（不在纯逻辑里取当前时间），这样本函数可进 Node 断言。
 */
export function buildOptimisticMessage(
  clientMessageId: string, content: string, attachmentIds: string[], createdAt: string
): TimelineMessage {
  const attachmentList: TimelineAttachment[] = attachmentIds.map((fileId: string): TimelineAttachment => {
    const attachment: TimelineAttachment = { fileId: fileId, name: fileId, mediaType: '', size: 0 };
    return attachment;
  });
  const message: TimelineMessage = {
    id: optimisticMessageId(clientMessageId),
    sourceItemId: optimisticSourceId(clientMessageId),
    orderSeq: Number.MAX_SAFE_INTEGER,
    revision: 0,
    updatedSeq: 0,
    author: MessageAuthor.USER,
    kind: MessageKind.MESSAGE,
    title: '',
    body: content,
    status: 'sending',
    subtitle: '',
    attachments: attachmentList,
    // 用户消息没有推理段（reasoningSegments 是必填字段）。
    reasoningSegments: [],
    collapsedByDefault: false,
    createdAt: createdAt
  };
  return message;
}

interface ProjectionEntry {
  item: RemoteTimelineItem;
  messages: TimelineMessage[];
}

/**
 * 增量投影缓存：`project(items)` 与 `projectTimeline(items)` 逐项等价，但只对「新出现」或
 * 「引用变化」的 item 真正执行投影。
 *
 * 等价性依据（三条，缺一不可）：
 * 1. 单条投影是纯函数（只读入参字段，无全局状态、不取时间、无随机）；
 * 2. `items` 里的 item 对象不可变（`mergeTimelineItems` 只替换引用，从不原地改字段）
 *  ⇒ `entry.item === item` 成立时投影结果必然与上次相同；
 * 3. 输出顺序由 `sortTimelineMessages` 定义，与 `projectTimeline` 是**同一个**比较器。
 *
 * 反向也保守：引用变了就重投影一次（哪怕内容其实没变），所以「命中缓存」只会少算、不会算错。
 */
export class TimelineProjectionCache {
  private entries: Map<string, ProjectionEntry> = new Map<string, ProjectionEntry>();
  /** 累计真正执行投影的 item 次数（自测与基准的判据；运行期只读）。 */
  projectedItems: number = 0;
  /** 最近一次 `project()` 复用的 item 数。 */
  reusedItems: number = 0;
  /** 最近一次 `project()` 里真正投影的 item（顺序同入参），供上层做增量索引。 */
  changedItems: RemoteTimelineItem[] = [];
  /**
   * R91-T2 同输入快速路径的「上次入参 / 上次输出」。
   *
   * 只做 === 引用比较，不复制数据（两个字段各持一个引用），所以它本身的开销是常数级。
   * ⚠️ 不要改成 slice() 存副本 —— 那样每次调用都要 O(N) 分配，正是本优化要省掉的东西。
   */
  private lastInput?: RemoteTimelineItem[];
  private lastOutput: TimelineMessage[] = [];

  reset(): void {
    this.entries = new Map<string, ProjectionEntry>();
    this.projectedItems = 0;
    this.reusedItems = 0;
    this.changedItems = [];
    // R91-T2：快速路径的缓存必须一起归零，否则 reset 后第一次 project() 可能返回上一个
    // 会话残留的产物（快速路径会绕过 entries 的逐项校验）。
    this.lastInput = undefined;
    this.lastOutput = [];
  }

  project(items: RemoteTimelineItem[]): TimelineMessage[] {
    // ---- R91-T2 同输入快速路径 -------------------------------------------------
    // 判据：与上次入参**长度相同且逐项同引用**。
    //
    // 为什么安全：
    //  ① 命中时直接返回上一次同一输入算出的**同一个数组**，逐项同引用；
    //  ② item 对象不可变（mergeTimelineItems 只换引用，见本文件顶部硬约束与
    //  suite-timeline-incremental 的「前提固定器」断言）⇒ 同引用即同内容，投影结果不变；
    //  ③ 入参**即使换成了新数组**、只要元素逐项同引用，投影产物也与上次逐项相同
    //  （产物只由元素内容与顺序决定，不读数组身份）；
    //  ④ 命中时 changedItems 置空：本次零变化，没有需要上层认领的 clientMessageId
    //  （原实现此时本来也只会得到空数组）。
    //
    // 收益：flushBatch() 的批次里很大一部分是「items 一条没变、只有 session/state/notice 变」
    // —— 原实现仍要 O(N) 重建 Map + 逐项查表 + 重新排序，快速路径只做 O(N) 引用比较，
    // 且不分配任何新对象（对 GC 压力同样有效）。
    if (this.lastInput !== undefined && this.lastInput.length === items.length) {
      let identical = true;
      for (let i = 0; i < items.length; i++) {
        if (this.lastInput[i] !== items[i]) {
          identical = false;
          break;
        }
      }
      if (identical) {
        this.reusedItems = items.length;
        this.changedItems = [];
        return this.lastOutput;
      }
    }
    const previous = this.entries;
    const next: Map<string, ProjectionEntry> = new Map<string, ProjectionEntry>();
    const changed: RemoteTimelineItem[] = [];
    const messages: TimelineMessage[] = [];
    let reused = 0;
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const hit = previous.get(item.id);
      let produced: TimelineMessage[];
      if (hit !== undefined && hit.item === item) {
        produced = hit.messages;
        reused += 1;
      } else {
        // 复用全量投影同一条路径（单条投影 + 单元素排序不改变结果），避免再复制一份投影逻辑。
        produced = projectTimeline([item]);
        this.projectedItems += 1;
        changed.push(item);
      }
      const entry: ProjectionEntry = { item: item, messages: produced };
      next.set(item.id, entry);
      for (let j = 0; j < produced.length; j++) {
        messages.push(produced[j]);
      }
    }
    sortTimelineMessages(messages);
    this.entries = next;
    this.reusedItems = reused;
    this.changedItems = changed;
    this.lastInput = items;
    this.lastOutput = messages;
    return messages;
  }
}

/**
 * 会话时间线的对外视图：`projectTimeline(items)` 叠加本地乐观消息。
 *
 * 它取代了原先「每次变化都全量重投影 + 用 concat/filter 增删乐观消息」的写法：
 *  · 投影走增量缓存（只算新 item）；
 *  · 乐观消息单独存一层 `overlay`，增删只动这一层（长度 ≤ 在途发送数），不再复制整个 messages；
 *  · 「服务端是否已回执」由增量索引判定（只扫本次新投影的 item，不再每次全量扫 `items`）。
 */
export class TimelineMessageView {
  private cache: TimelineProjectionCache = new TimelineProjectionCache();
  private overlay: TimelineMessage[] = [];
  private projected: TimelineMessage[] = [];
  private current: TimelineMessage[] = [];
  /** clientMessageId → 已在服务端时间线里出现（即已回执）。只增不减，`reset()` 时清空。 */
  private acknowledged: Map<string, boolean> = new Map<string, boolean>();

  /** 换会话 / 重新拉全量快照时调用：缓存与乐观消息一起归零。 */
  reset(): void {
    this.cache.reset();
    this.overlay = [];
    this.projected = [];
    this.current = [];
    this.acknowledged = new Map<string, boolean>();
  }

  /** `items` 更新后调用：增量重投影 → 摘掉已被服务端回执的乐观消息 → 重建视图。 */
  setItems(items: RemoteTimelineItem[]): void {
    this.projected = this.cache.project(items);
    const changed = this.cache.changedItems;
    for (let i = 0; i < changed.length; i++) {
      // R80：回执键在线上契约里位于 **source**（protocol schema `TimelineSource.clientMessageId`，
      // 连接器 `runtime_protocol/timeline.py` 与 bridge `index.js` 都写 source）。
      // 旧形态 `content.clientMessageId` 保留作兼容回退；两者都查，**source 优先**。
      const wire = changed[i].source['clientMessageId'];
      const legacy = changed[i].content['clientMessageId'];
      const candidate = (typeof wire === 'string' && wire.length > 0) ? wire : legacy;
      if (typeof candidate === 'string' && candidate.length > 0) {
        this.acknowledged.set(candidate, true);
      }
    }
    this.reconcile();
    this.rebuild();
  }

  /** 本地乐观追加（用户点了发送、服务端还没回执）。 */
  addOptimistic(message: TimelineMessage): void {
    this.overlay = this.overlay.concat([message]);
    this.rebuild();
  }

  /** 撤回一条乐观消息（发送失败）。 */
  removeOptimistic(clientMessageId: string): void {
    const target = optimisticMessageId(clientMessageId);
    this.overlay = this.overlay.filter((message: TimelineMessage) => message.id !== target);
    this.rebuild();
  }

  /** 未回执的乐观消息条数。 */
  optimisticCount(): number {
    return this.overlay.length;
  }

  /** 当前视图。返回内部数组引用，调用方不要原地修改（页面侧是 `.slice()` 拷贝后使用的）。 */
  messages(): TimelineMessage[] {
    return this.current;
  }

  /** 把「服务端已回执」的乐观消息从 overlay 里摘掉。 */
  private reconcile(): void {
    if (this.overlay.length === 0) {
      return;
    }
    const remaining: TimelineMessage[] = [];
    let dropped = false;
    for (let i = 0; i < this.overlay.length; i++) {
      const message = this.overlay[i];
      const source = message.sourceItemId;
      const clientMessageId = source.startsWith(OPTIMISTIC_ID_PREFIX)
        ? source.substring(OPTIMISTIC_ID_PREFIX.length) : '';
      if (clientMessageId.length > 0 && this.acknowledged.get(clientMessageId) === true) {
        dropped = true;
      } else {
        remaining.push(message);
      }
    }
    if (dropped) {
      this.overlay = remaining;
    }
  }

  private rebuild(): void {
    this.current = this.overlay.length === 0 ? this.projected : this.projected.concat(this.overlay);
  }
}
