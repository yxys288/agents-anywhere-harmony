/**
 * 时间线投影（对应 Android `feature/sessiondetail/SessionTimelineProjection.kt`）。
 *
 * 服务端的 `RemoteTimelineItem` 是「带 content/source 的通用容器」，
 * 这里把它摊平成渲染层好用的 `TimelineMessage`：
 * 一条 message 可能展开成多条（如一次 tool 调用 + 它的结果），
 * 并按 `orderSeq` 排序、按 `revision/updatedSeq` 去重（upsert-only）。
 *
 * 与 Android 的差异：Android 端做了 DSH 专属的 assistant_activity 合并与
 * 附件预览继承等 20 余条特例；这里保留通用语义（message/tool/artifact/marker/system），
 * 覆盖 Codex / Claude Code / DSH 三种 Runtime 的常规输出。
 */

import { JsonMap, RemoteTimelineItem } from '../model/Types';
import { optNumber, optRaw, optString, Raw, asRawArray } from '../api/Parse';

export enum MessageAuthor {
  USER = 'user',
  AGENT = 'agent',
  TOOL = 'tool',
  SYSTEM = 'system'
}

export enum MessageKind {
  MESSAGE = 'message',
  /** 推理段（思考过程）—— 上游 `TimelineMessageKind.Reasoning`。 */
  REASONING = 'reasoning',
  COMMAND = 'command',
  FILE_CHANGE = 'file_change',
  TOOL_CALL = 'tool_call',
  WEB_SEARCH = 'web_search',
  MCP = 'mcp',
  ARTIFACT = 'artifact',
  MARKER = 'marker',
  SYSTEM = 'system',
  DIAGNOSTIC = 'diagnostic'
}

export interface TimelineAttachment {
  fileId: string;
  name: string;
  mediaType: string;
  size: number;
}

export interface TimelineMessage {
  /** 渲染用唯一 id（一条 item 可展开成多条）。 */
  id: string;
  sourceItemId: string;
  orderSeq: number;
  revision: number;
  updatedSeq: number;
  author: MessageAuthor;
  kind: MessageKind;
  title: string;
  body: string;
  status: string;
  /** 命令类消息的工作目录 / 退出码等补充信息。 */
  subtitle: string;
  exitCode?: number;
  /**
   * 推理段原文（仅 `kind === REASONING` 非空）—— 上游 `TimelineMessage.reasoningSegments`。
   * 折叠行标题的三态与「能不能展开」都由它决定，见 `model/ReasoningText.ets`。
   */
  reasoningSegments: string[];
  attachments: TimelineAttachment[];
  /** 默认是否折叠（工具类默认折叠，正文默认展开）。 */
  collapsedByDefault: boolean;
  createdAt: string;
}

function readAttachments(content: JsonMap, nested: JsonMap | undefined): TimelineAttachment[] {
  const out: TimelineAttachment[] = [];
  const seen: string[] = [];
  const sources: Raw[] = [];
  const direct = asRawArray(content['attachments']);
  for (let i = 0; i < direct.length; i++) {
    sources.push(direct[i]);
  }
  if (nested !== undefined) {
    const extra = asRawArray(nested['attachments']);
    for (let i = 0; i < extra.length; i++) {
      sources.push(extra[i]);
    }
  }
  for (let i = 0; i < sources.length; i++) {
    const item = sources[i];
    const fileId = optString(item, 'fileId');
    if (fileId === undefined || seen.includes(fileId)) {
      continue;
    }
    seen.push(fileId);
    const attachment: TimelineAttachment = {
      fileId: fileId,
      name: optString(item, 'name') ?? fileId,
      mediaType: optString(item, 'mediaType') ?? '',
      size: optNumber(item, 'size') ?? 0
    };
    out.push(attachment);
  }
  return out;
}

/** 去掉正文里被注入的附件提及（`@@attachment:xxx` 之类）。 */
function stripInjectedMentions(text: string): string {
  return text.replace(/@@[a-zA-Z_-]*attachment:[^\s)]+/g, '').trim();
}

function messageText(item: RemoteTimelineItem): string {
  const content = item.content;
  const nested = optRaw(content, 'content');
  if (item.text.length > 0) {
    return stripInjectedMentions(item.text);
  }
  const nestedText = nested !== undefined ? optString(nested, 'text') : undefined;
  if (nestedText !== undefined) {
    return stripInjectedMentions(nestedText);
  }
  const platformText = optString(content, 'message') ?? optString(content, 'description');
  return platformText !== undefined ? stripInjectedMentions(platformText) : '';
}

function toolTitle(item: RemoteTimelineItem): string {
  const content = item.content;
  const input = optRaw(content, 'input');
  const fromInput = input !== undefined ? optString(input, 'command') : undefined;
  return optString(content, 'command') ?? optString(content, 'name') ?? optString(content, 'tool')
    ?? fromInput ?? optString(content, 'title') ?? '工具调用';
}

function toolSubtitle(item: RemoteTimelineItem): string {
  const content = item.content;
  const cwd = optString(content, 'cwd');
  const target = optString(content, 'path') ?? optString(content, 'target') ?? optString(content, 'file');
  return target ?? cwd ?? '';
}

function toolOutput(item: RemoteTimelineItem): string {
  const content = item.content;
  return optString(content, 'output') ?? optString(content, 'aggregatedOutput')
    ?? optString(content, 'result') ?? optString(content, 'stderr') ?? '';
}

interface TimelineBase {
  sourceItemId: string;
  orderSeq: number;
  revision: number;
  updatedSeq: number;
  status: string;
  createdAt: string;
  attachments: TimelineAttachment[];
}

/**
 * 上游 `JSONObject.text(name)` 对字符串是 `takeIf { it.isNotBlank() }` —— **空白串按缺失处理**。
 * 本文件的 `optString` 只挡空串、不挡纯空白，所以这里要再过一道 `trim`。
 */
function nonBlank(content: JsonMap, key: string): string | undefined {
  const value = optString(content, key);
  return value !== undefined && value.trim().length > 0 ? value : undefined;
}

/**
 * 上游 `toSystemMessage()` 里 `if (kind == "reasoning")` 那三行取数：
 *  `summaries = content.records("summaries").mapNotNull { it.text("text") }`；
 *  `rawText = content.text("rawText") ?: content.text("text")`；
 *  `segments = if (summaries.isNotEmpty()) summaries else listOfNotNull(rawText)`。
 *
 * ⚠️ 两处容易写偏的地方：`summaries` 里 **text 为空白的条目会被丢掉**（`it.text` 同为 isNotBlank 语义）；
 * `rawText` 为空白时按**没有**处理 —— 所以 `rawText == ""` 得到的是空段表（标题「推理」、不可展开），
 * 而不是一段空串（那会变成「推理过程 · 1 条摘要」且可展开）。
 */
function reasoningSegmentsOf(content: JsonMap): string[] {
  const summaries: string[] = [];
  const entries = asRawArray(content['summaries']);
  for (let i = 0; i < entries.length; i++) {
    const text = nonBlank(entries[i], 'text');
    if (text !== undefined) {
      summaries.push(text);
    }
  }
  if (summaries.length > 0) {
    return summaries;
  }
  const rawText = nonBlank(content, 'rawText') ?? nonBlank(content, 'text');
  return rawText !== undefined ? [rawText] : [];
}

function toMessages(item: RemoteTimelineItem): TimelineMessage[] {
  const attachmentList = readAttachments(item.content, optRaw(item.content, 'content'));
  const base: TimelineBase = {
    sourceItemId: item.id,
    orderSeq: item.orderSeq,
    revision: item.revision,
    updatedSeq: item.updatedSeq,
    status: item.status,
    createdAt: item.createdAt,
    attachments: attachmentList
  };

  if (item.type === 'message') {
    const role = item.role !== undefined ? item.role : '';
    let author = MessageAuthor.TOOL;
    if (role === 'user') {
      author = MessageAuthor.USER;
    } else if (role === 'assistant') {
      author = MessageAuthor.AGENT;
    }
    const body = messageText(item);
    if (body.length === 0 && attachmentList.length === 0) {
      if (role === 'assistant') {
        return [];
      }
      const diagnostic: TimelineMessage = {
        id: `${item.id}#0`,
        sourceItemId: base.sourceItemId,
        orderSeq: base.orderSeq,
        revision: base.revision,
        updatedSeq: base.updatedSeq,
        author: MessageAuthor.SYSTEM,
        kind: MessageKind.DIAGNOSTIC,
        title: '（空消息）',
        body: '',
        reasoningSegments: [],
        status: base.status,
        subtitle: '',
        attachments: base.attachments,
        collapsedByDefault: false,
        createdAt: base.createdAt
      };
      return [diagnostic];
    }
    const message: TimelineMessage = {
      id: `${item.id}#0`,
      sourceItemId: base.sourceItemId,
      orderSeq: base.orderSeq,
      revision: base.revision,
      updatedSeq: base.updatedSeq,
      author: author,
      kind: MessageKind.MESSAGE,
      title: '',
      body: body,
      reasoningSegments: [],
      status: base.status,
      subtitle: '',
      attachments: base.attachments,
      collapsedByDefault: false,
      createdAt: base.createdAt
    };
    return [message];
  }

  if (item.type === 'tool') {
    const kindText = optString(item.content, 'kind') ?? '';
    let kind = MessageKind.TOOL_CALL;
    let title = toolTitle(item);
    let subtitle = toolSubtitle(item);
    let body = toolOutput(item);
    let exitCode: number | undefined = undefined;

    if (kindText === 'command') {
      kind = MessageKind.COMMAND;
      exitCode = optNumber(item.content, 'exitCode');
    } else if (kindText === 'file_change') {
      kind = MessageKind.FILE_CHANGE;
      title = '文件变更';
      subtitle = '';
      body = fileChangeSummary(item.content);
    } else if (kindText === 'web_search') {
      kind = MessageKind.WEB_SEARCH;
      title = optString(item.content, 'query') ?? title;
      subtitle = '';
      body = '';
    } else if (kindText === 'mcp') {
      kind = MessageKind.MCP;
      title = `${optString(item.content, 'server') ?? 'mcp'} / ${optString(item.content, 'tool') ?? 'tool'}`;
      subtitle = '';
    } else if (kindText === 'agent_call') {
      kind = MessageKind.TOOL_CALL;
      title = `子 Agent：${optString(item.content, 'agent') ?? title}`;
    }

    const message: TimelineMessage = {
      id: `${item.id}#0`,
      sourceItemId: base.sourceItemId,
      orderSeq: base.orderSeq,
      revision: base.revision,
      updatedSeq: base.updatedSeq,
      author: MessageAuthor.TOOL,
      kind: kind,
      title: title,
      body: body,
      status: base.status,
      subtitle: subtitle,
      exitCode: exitCode,
      reasoningSegments: [],
      attachments: base.attachments,
      collapsedByDefault: true,
      createdAt: base.createdAt
    };
    return [message];
  }

  if (item.type === 'artifact') {
    const message: TimelineMessage = {
      id: `${item.id}#0`,
      sourceItemId: base.sourceItemId,
      orderSeq: base.orderSeq,
      revision: base.revision,
      updatedSeq: base.updatedSeq,
      author: MessageAuthor.TOOL,
      kind: MessageKind.ARTIFACT,
      title: optString(item.content, 'title') ?? optString(item.content, 'name') ?? '产物',
      body: optString(item.content, 'text') ?? optString(item.content, 'content') ?? '',
      reasoningSegments: [],
      status: base.status,
      subtitle: optString(item.content, 'mediaType') ?? '',
      attachments: base.attachments,
      collapsedByDefault: true,
      createdAt: base.createdAt
    };
    return [message];
  }

  if (item.type === 'marker') {
    const message: TimelineMessage = {
      id: `${item.id}#0`,
      sourceItemId: base.sourceItemId,
      orderSeq: base.orderSeq,
      revision: base.revision,
      updatedSeq: base.updatedSeq,
      author: MessageAuthor.SYSTEM,
      kind: MessageKind.MARKER,
      title: optString(item.content, 'title') ?? item.text,
      body: '',
      reasoningSegments: [],
      status: base.status,
      subtitle: '',
      attachments: [],
      collapsedByDefault: false,
      createdAt: base.createdAt
    };
    return [message];
  }

  // 推理段（思考过程）—— 上游 `RemoteTimelineItem.toSystemMessage()` 的 `if (kind == "reasoning")`。
  // 服务端把推理项发成 `type === 'system'` + `content.kind === 'reasoning'`
  // （connector 侧 `ReasoningSystemContent`；DSH 侧 `history.ts` 的 reasoning block 也落成 'system'），
  // 所以必须在**下面那条 system/diagnostic 兜底之前**分派 —— 否则它会被渲染成标题「系统」的空行。
  if (optString(item.content, 'kind') === 'reasoning') {
    const segments = reasoningSegmentsOf(item.content);
    const reasoning: TimelineMessage = {
      id: `${item.id}#0`,
      sourceItemId: base.sourceItemId,
      orderSeq: base.orderSeq,
      revision: base.revision,
      updatedSeq: base.updatedSeq,
      author: MessageAuthor.AGENT,
      kind: MessageKind.REASONING,
      // 上游 `title = "Reasoning"`（英文原样，不走字符串资源）。
      title: 'Reasoning',
      body: segments.join('\n\n'),
      status: base.status,
      subtitle: '',
      attachments: base.attachments,
      reasoningSegments: segments,
      // 上游 `ReasoningSection` 初始 `expanded = false`（本工程该字段暂无读者，展开态在 `expandedIds`）。
      collapsedByDefault: true,
      createdAt: base.createdAt
    };
    return [reasoning];
  }

  const systemText = messageText(item);
  const message: TimelineMessage = {
    id: `${item.id}#0`,
    sourceItemId: base.sourceItemId,
    orderSeq: base.orderSeq,
    revision: base.revision,
    updatedSeq: base.updatedSeq,
    author: MessageAuthor.SYSTEM,
    kind: item.type === 'system' ? MessageKind.SYSTEM : MessageKind.DIAGNOSTIC,
    title: item.type === 'system' ? '系统' : item.type,
    body: systemText,
    reasoningSegments: [],
    status: base.status,
    subtitle: '',
    attachments: base.attachments,
    collapsedByDefault: item.type !== 'system',
    createdAt: base.createdAt
  };
  return [message];
}

function fileChangeSummary(content: JsonMap): string {
  const changes = asRawArray(content['changes']);
  const lines: string[] = [];
  for (let i = 0; i < changes.length; i++) {
    const change = changes[i];
    const path = optString(change, 'path') ?? optString(change, 'file') ?? '';
    const kindText = optString(change, 'kind') ?? optString(change, 'type') ?? 'update';
    const added = optNumber(change, 'added') ?? 0;
    const removed = optNumber(change, 'removed') ?? 0;
    const stats = (added > 0 || removed > 0) ? `  +${added} -${removed}` : '';
    lines.push(`${kindText}  ${path}${stats}`);
  }
  if (lines.length === 0) {
    return optString(content, 'summary') ?? optString(content, 'diff') ?? '';
  }
  return lines.join('\n');
}

/**
 * R80 业务身份键：**同一条逻辑消息** = 同 `source.clientMessageId` 且同 `source.itemId`。
 *
 * 为什么不能只按 `item.id` 去重：上游可能对同一条消息产出两条 **id 不同** 的 item
 * （例如 `agent/inbox/spliced` 与 `user/message` 各映射一次，或乐观回执 item 与运行期 item 并存），
 * 而这条消息的业务身份在线上契约里是稳定的（`source.clientMessageId`，见 protocol schema 的 `TimelineSource`）。
 *
 * 返回空串表示**不参与去重** —— 助手消息、工具项等没有 clientMessageId 的 item 保持逐字节原行为。
 * 键取得**窄**：还必须同 `source.itemId`（缺省按空串），这样同一条消息的多个内容块
 * （`<nativeId>:0` / `<nativeId>:1`，上游各自带同一个 clientMessageId）不会被误并成一条。
 */
function businessIdentity(item: RemoteTimelineItem): string {
  const clientId = optString(item.source, 'clientMessageId');
  if (clientId === undefined || clientId.length === 0) {
    return '';
  }
  const nativeItemId = optString(item.source, 'itemId') ?? '';
  return clientId + '\u0000' + nativeItemId;
}

/** 按业务身份去重：同一逻辑消息只留 revision/updatedSeq 最新者，位置沿用首次出现处。 */
function dedupeByBusinessIdentity(items: RemoteTimelineItem[]): RemoteTimelineItem[] {
  const indexOfKey: Map<string, number> = new Map<string, number>();
  const out: RemoteTimelineItem[] = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const key = businessIdentity(item);
    if (key.length === 0) {
      out.push(item);
      continue;
    }
    const hit = indexOfKey.get(key);
    if (hit === undefined) {
      indexOfKey.set(key, out.length);
      out.push(item);
    } else {
      const existing = out[hit];
      if (item.revision > existing.revision || item.updatedSeq >= existing.updatedSeq) {
        out[hit] = item;
      }
    }
  }
  return out;
}

/**
 * 是否是「上下文压缩」标记 item（上游 bridge 对**每一条** `compaction/*` 记录各产出一个 marker，
 * 标题恒为「上下文压缩」）。判别只看语义字段，不看标题文本，避免按文案去重。
 */
function isCompactMarker(item: RemoteTimelineItem): boolean {
  if (item.type !== 'marker') {
    return false;
  }
  if (optString(item.content, 'kind') === 'compact') {
    return true;
  }
  const eventType = optString(item.content, 'eventType');
  return eventType !== undefined && eventType.startsWith('compaction/');
}

function compactionIdOf(item: RemoteTimelineItem): string {
  const details = optRaw(item.content, 'details');
  if (details === undefined) {
    return '';
  }
  return optString(details, 'compactionId') ?? '';
}

/**
 * 选组代表：**优先保住组的身份**（有 compactionId 的那条），其次才是 revision/updatedSeq 最新。
 *
 * 为什么不能只按「最新」：无 id 的 prune 比本组的 start/summary/end 都新，若让它当代表，
 * 下一次增量调用就再也认不出这个组 —— 组身份丢失会让后续 prune 漂到别的组里（实测会把 5 行压成 3 行）。
 */
function preferCompactRepresentative(candidate: RemoteTimelineItem, existing: RemoteTimelineItem): boolean {
  const candidateHasId = compactionIdOf(candidate).length > 0;
  const existingHasId = compactionIdOf(existing).length > 0;
  if (candidateHasId !== existingHasId) {
    return candidateHasId;
  }
  return candidate.revision > existing.revision || candidate.updatedSeq >= existing.updatedSeq;
}

/**
 * 归并「上下文压缩」标记：**一次压缩只留一行**。
 *
 * 规则（R80 裁决版；宁可多一行，也不丢信息）：
 * 1. 有 `content.details.compactionId` 的按它成组，同组只留代表一条；
 * 2. 没有 id 的（`compaction/prune`）**优先并入后一个已存在的组** —— 真机会话日志的物理顺序是
 *  `compaction/prune`×N 紧贴在它所服务的那次 `compaction/start` **之前**（先剪枝、再写摘要），
 *  见 开发期验证记录；后面没有组时才并入**前一个**组；
 * 3. 前后都没有组时**不吞**：该 marker 自己成组照常显示（再往后的无 id marker 并入它）。
 *
 * 三遍扫描：① 给有 id 的定组键；② 给无 id 的按「后 → 前」就近解析组键；③ 按组键归并并选代表。
 * 非压缩标记与非 marker item 一律原样保留。
 */
function collapseCompactMarkers(items: RemoteTimelineItem[]): RemoteTimelineItem[] {
  const keys: string[] = [];
  const pending: number[] = [];
  for (let i = 0; i < items.length; i++) {
    keys.push('');
    if (!isCompactMarker(items[i])) {
      continue;
    }
    const compactionId = compactionIdOf(items[i]);
    if (compactionId.length > 0) {
      keys[i] = 'compact:' + compactionId;
    } else {
      pending.push(i);
    }
  }
  for (let p = 0; p < pending.length; p++) {
    const index = pending[p];
    let key = '';
    for (let j = index + 1; j < items.length && key.length === 0; j++) {
      key = keys[j];
    }
    for (let j = index - 1; j >= 0 && key.length === 0; j--) {
      key = keys[j];
    }
    keys[index] = key.length > 0 ? key : 'compact:' + items[index].id;
  }
  const indexOfGroup: Map<string, number> = new Map<string, number>();
  const out: RemoteTimelineItem[] = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const key = keys[i];
    if (key.length === 0) {
      out.push(item);
      continue;
    }
    const hit = indexOfGroup.get(key);
    if (hit === undefined) {
      indexOfGroup.set(key, out.length);
      out.push(item);
    } else if (preferCompactRepresentative(item, out[hit])) {
      out[hit] = item;
    }
  }
  return out;
}

/**
 * upsert-only 合并：同 id 以 revision/updatedSeq 更新者为准。
 *
 * R80 追加两道**items 层**后处理（刻意不放到投影/视图层，以保持
 * 「view.messages() == projectTimeline(items) + 未回执乐观消息」这条 R42 硬约束）：
 *  ① `dedupeByBusinessIdentity` —— 同一条逻辑消息的两条 item 合成一条；
 *  ② `collapseCompactMarkers` —— 一次上下文压缩只留一个标记。
 */
export function mergeTimelineItems(
  current: RemoteTimelineItem[], incoming: RemoteTimelineItem[], replace: boolean
): RemoteTimelineItem[] {
  if (replace) {
    // R80：快照分支与增量分支走同一套后置处理，否则「重进会话」与「增量更新」结果会不一致。
    return collapseCompactMarkers(dedupeByBusinessIdentity(latestById(incoming)));
  }
  const byId: Map<string, RemoteTimelineItem> = new Map<string, RemoteTimelineItem>();
  const ordering: string[] = [];
  // R91-T2：本批是否**真的**动了 items（新 id 出现，或同 id 被更新的 revision/updatedSeq 替换）。
  // 它同时是下面「无操作快速路径」的判据。
  let changed = false;
  for (let i = 0; i < current.length; i++) {
    const item = current[i];
    if (!byId.has(item.id)) {
      ordering.push(item.id);
    }
    byId.set(item.id, item);
  }
  for (let i = 0; i < incoming.length; i++) {
    const observed = incoming[i];
    const existing = byId.get(observed.id);
    if (existing === undefined) {
      ordering.push(observed.id);
      byId.set(observed.id, observed);
      changed = true;
    } else if (observed.revision > existing.revision || observed.updatedSeq >= existing.updatedSeq) {
      byId.set(observed.id, observed);
      changed = true;
    }
  }
  // ---- R91-T2 无操作快速路径 -------------------------------------------------
  // 为什么要有它：`flushBatch()` 每 34ms 一批地把 WS 事件喂进来，而绝大多数批次里
  // 新 item 都是**已知 id + 同 revision/updatedSeq**（重复投递、心跳、只更新 session/state
  // 的事件也会走到这里）。原实现无论如何都要重建 Map + ordering + out，再跑
  // `dedupeByBusinessIdentity` + `collapseCompactMarkers` 两道**全量**后处理 ——
  // 会话跑到几百条 item 时，每个空批次都是白烧的 4 趟 O(N)。
  //
  // 等价性依据（三条，缺一不可）：
  // ① `changed === false` ⇒ 每个 observed 都在 byId 里且未被替换 ⇒ byId 逐键等于 current
  //  （Map.set 同键同值只是赋引用），ordering 逐项等于 current 的 id 序列；
  // ② 两道后处理对**已处理过**的数组是幂等的：`dedupeByBusinessIdentity` 给每个非空业务键
  //  只留一个位置（每个键在 indexOfKey 里只命中一次 ⇒ 输出即入参的浅拷贝），
  //  `collapseCompactMarkers` 每组只留一个代表（同理 ⇒ 输出即入参的浅拷贝）。
  //  而 current 的每一份都产生自本函数 ⇒ 它已经过这两道处理 ⇒ 再跑一遍不改变元素；
  // ③ ordering.length === current.length 挡住「current 里有重复 id」的防御场景 —— 那种输入下
  //  out 是去重后的结果，不能拿 current 顶替。
  // ⇒ 此时返回值与 collapseCompactMarkers(dedupeByBusinessIdentity(out)) **逐项同引用**。
  //  返回 current 原引用（而不是新数组）：调用方接下来会 view.setItems(this.items)，
  //  原引用还能命中 TimelineProjectionCache 的同输入快速路径。
  if (!changed && ordering.length === current.length) {
    return current;
  }
  const out: RemoteTimelineItem[] = [];
  for (let i = 0; i < ordering.length; i++) {
    const item = byId.get(ordering[i]);
    if (item !== undefined) {
      out.push(item);
    }
  }
  return collapseCompactMarkers(dedupeByBusinessIdentity(out));
}

function latestById(items: RemoteTimelineItem[]): RemoteTimelineItem[] {
  const byId: Map<string, RemoteTimelineItem> = new Map<string, RemoteTimelineItem>();
  const ordering: string[] = [];
  for (let i = 0; i < items.length; i++) {
    const observed = items[i];
    const existing = byId.get(observed.id);
    if (existing === undefined) {
      ordering.push(observed.id);
      byId.set(observed.id, observed);
    } else if (observed.revision > existing.revision || observed.updatedSeq >= existing.updatedSeq) {
      byId.set(observed.id, observed);
    }
  }
  const out: RemoteTimelineItem[] = [];
  for (let i = 0; i < ordering.length; i++) {
    const item = byId.get(ordering[i]);
    if (item !== undefined) {
      out.push(item);
    }
  }
  return out;
}

/**
 * 投影结果的排序规则：先 orderSeq 升序，同序按 id 升序。
 *
 * ⚠️ 这里是**顺序定义的唯一出处**：全量投影与增量缓存（feature/TimelineView.ets）必须共用它，
 * 否则「增量结果逐项等于全量结果」这个不变量就不成立。
 */
export function sortTimelineMessages(messages: TimelineMessage[]): void {
  messages.sort((a: TimelineMessage, b: TimelineMessage): number => {
    if (a.orderSeq !== b.orderSeq) {
      return a.orderSeq - b.orderSeq;
    }
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
  });
}

/** 把时间线 item 列表投影成可渲染消息（按 orderSeq 升序）。 */
export function projectTimeline(items: RemoteTimelineItem[]): TimelineMessage[] {
  const messages: TimelineMessage[] = [];
  for (let i = 0; i < items.length; i++) {
    const produced = toMessages(items[i]);
    for (let j = 0; j < produced.length; j++) {
      messages.push(produced[j]);
    }
  }
  sortTimelineMessages(messages);
  return messages;
}

// ---------------------------------------------------------------------------
// 时间线分组与回合末尾动作（对应上游 `SessionMessages.kt` 的 `groupTimelineMessages` :603-673
// 与 `buildAgentActionsByTurnEnd` :680-740）—— 纯函数，进 Node 断言。
// ---------------------------------------------------------------------------

/** 工具组汇总文案：逐字取自上游 `values-zh-rCN/strings.xml` 的 `session_tool_summary_*`。 */
export class ToolRunText {
  /** `session_tool_summary_commands`。 */
  static readonly COMMANDS: string = '执行了 %1$d 条指令';
  /** `session_tool_summary_reasoning`。 */
  static readonly REASONING: string = '推理了 %1$d 次';
  /** `session_tool_summary_changed_files`。 */
  static readonly CHANGED_FILES: string = '修改了 %1$d 个文件';
  /** `session_tool_summary_created_files`。 */
  static readonly CREATED_FILES: string = '创建了 %1$d 个文件';
  /** `session_tool_summary_items`（无任何可计数项时的兜底）。 */
  static readonly ITEMS: string = '%1$d 条活动';

  static commands(count: number): string {
    return '执行了 ' + count + ' 条指令';
  }

  static reasoning(count: number): string {
    return '推理了 ' + count + ' 次';
  }

  static items(count: number): string {
    return count + ' 条活动';
  }
}

/** 一个渲染单元（上游 `TimelineRenderItem`：Single / ToolRun / Reconnect）。 */
export interface TimelineRenderItem {
  /** ForEach 的 key（= 首条消息 id + 组类型）。 */
  key: string;
  /** `single` = 单独一条；`toolRun` = 连续工具调用折成一组；`reconnect` = 连续重连失败折成一组。 */
  groupKind: string;
  messages: TimelineMessage[];
}

/**
 * 上游 `TimelineMessage.isToolRunItem()`（`:748-755`）：
 * Reasoning / Command / FileChange / AgentCall / ToolCall / Artifact（diff 除外）。
 *
 * ⚠️ 本工程的 `TimelineMessage` 没有单独的 AgentCall 类型（并入 `TOOL_CALL`），
 * 也没有 Artifact 的 `contentKind`，所以 Artifact 一律按工具项处理（diff 那条例外写进交付说明）。
 */
export function isToolRunItem(message: TimelineMessage): boolean {
  return message.kind === MessageKind.REASONING
    || message.kind === MessageKind.COMMAND
    || message.kind === MessageKind.FILE_CHANGE
    || message.kind === MessageKind.TOOL_CALL
    || message.kind === MessageKind.MCP
    || message.kind === MessageKind.WEB_SEARCH
    || message.kind === MessageKind.ARTIFACT;
}

/** 上游 `TimelineMessage.isReconnectError()`（`:757-758`）：system + failed + 以 `Reconnecting...` 开头。 */
function isReconnectErrorItem(message: TimelineMessage): boolean {
  return message.kind === MessageKind.SYSTEM
    && message.status === 'failed'
    && message.body.indexOf('Reconnecting...') === 0;
}

/**
 * 上游 `groupTimelineMessages()`（`:603-673`）：**连续**同类项才成组，单条不成组。
 * 组只影响渲染，不改数据；入参顺序即渲染顺序。
 */
export function groupTimelineMessages(messages: TimelineMessage[]): TimelineRenderItem[] {
  const out: TimelineRenderItem[] = [];
  let tools: TimelineMessage[] = [];
  let reconnects: TimelineMessage[] = [];

  const flushTools = (): void => {
    if (tools.length === 1) {
      out.push({ key: tools[0].id, groupKind: 'single', messages: [tools[0]] });
    } else if (tools.length > 1) {
      out.push({ key: 'toolrun:' + tools[0].id, groupKind: 'toolRun', messages: tools.slice() });
    }
    tools = [];
  };
  const flushReconnects = (): void => {
    if (reconnects.length === 1) {
      out.push({ key: reconnects[0].id, groupKind: 'single', messages: [reconnects[0]] });
    } else if (reconnects.length > 1) {
      out.push({ key: 'reconnect:' + reconnects[0].id, groupKind: 'reconnect', messages: reconnects.slice() });
    }
    reconnects = [];
  };

  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (isReconnectErrorItem(message)) {
      flushTools();
      reconnects.push(message);
    } else if (isToolRunItem(message)) {
      flushReconnects();
      tools.push(message);
    } else {
      flushReconnects();
      flushTools();
      out.push({ key: message.id, groupKind: 'single', messages: [message] });
    }
  }
  flushReconnects();
  flushTools();
  return out;
}


// ---------------------------------------------------------------------------
// 渲染单元的 **LazyForEach 增量口径**（R55 性能轮）—— 纯逻辑，进 Node 断言。
//
// 背景：时间线此前是 `ForEach(this.renderItems, ...)`（一次性建出全部子组件），
// R55 换成 `LazyForEach` + `IDataSource`。数据源不能在每次 `pull()` 时整表重发，
// 于是「哪些索引真的变了」这件事必须有一个**可单测**的定义 —— 就是下面这组函数。
// ---------------------------------------------------------------------------

/** 渲染单元的**稳定标识**（= 分组边界 + 组内每条消息的会变字段）。 */
export function timelineRenderItemKey(item: TimelineRenderItem): string {
  let key = item.key + ':' + item.groupKind;
  for (let i = 0; i < item.messages.length; i++) {
    const message = item.messages[i];
    key += '|' + message.id + ':' + message.revision + ':' + message.updatedSeq + ':' + message.status;
  }
  return key;
}

/**
 * 两个渲染单元**内容是否相同**。
 *
 * 判据：`key` + `groupKind` + 组内消息的**对象引用**逐项相等。
 * 这条判据可靠的前提是 `TimelineProjectionCache` 对「未变的 item」复用同一批
 * `TimelineMessage` 对象（`TimelineView.ets`：`hit.item === item ⇒ produced = hit.messages`）
 * ⇒ 「引用相同 ⇒ 内容相同」。反过来「引用不同」只会**多**报一次 change，不会漏报。
 * ⚠️ 唯一前提：消息对象不做原地改写（`mergeTimelineItems` 只换引用、从不原地赋值）——
 *  这条前提在 `tools/logic-test/suite-timeline-incremental.mjs` 里有断言固定。
 */
export function sameTimelineRenderItem(a: TimelineRenderItem, b: TimelineRenderItem): boolean {
  if (a === b) {
    return true;
  }
  if (a.key !== b.key || a.groupKind !== b.groupKind) {
    return false;
  }
  if (a.messages.length !== b.messages.length) {
    return false;
  }
  for (let i = 0; i < a.messages.length; i++) {
    if (a.messages[i] !== b.messages[i]) {
      return false;
    }
  }
  return true;
}

/** 渲染单元增量操作的类型常量（与 ArkUI `DataChangeListener` 一一对应）。 */
export class TimelineRenderOp {
  /** → `onDataReloaded()`：整表重来（key 未变的项仍复用原组件）。 */
  static readonly RELOAD: string = 'reload';
  /** → `onDataAdd(index)`：在 index 处插入（必须**升序**回放）。 */
  static readonly ADD: string = 'add';
  /** → `onDataDelete(index)`：删除 index 处（必须**降序**回放）。 */
  static readonly DELETE: string = 'delete';
  /** → `onDataChange(index)`：index 处内容变了。 */
  static readonly CHANGE: string = 'change';
}

/** 一条增量操作（`kind` 取 `TimelineRenderOp` 的四个常量；`reload` 时 `index` 无意义）。 */
export interface TimelineRenderOperation {
  kind: string;
  index: number;
}

function renderOperation(kind: string, index: number): TimelineRenderOperation {
  const op: TimelineRenderOperation = { kind: kind, index: index };
  return op;
}

/**
 * 渲染单元列表的**增量 diff**（纯函数）—— LazyForEach 数据源的通知口径。
 *
 * 算法：按 `item.key` 对齐 → 前缀 / 尾部 / 中段三段处理。
 * 1. 前缀 `p`：同 index 且 `key` 相同的最长前缀；
 * 2. 尾部 `s`：从两端往中间、同 index 且 `key` 相同的最长尾部（与前缀不重叠）；
 * 3. 尾部区**有任何内容变化就直接整表 reload** —— 尾部区只会在「中段发生了增删」时出现，
 *  那种场景下尾部项的 next 索引会平移，逐条 change 的索引在回放期不好保证，reload 更稳、也更少；
 * 4. 中段：只有 next 有 ⇒ add（升序）；只有 prev 有 ⇒ delete（降序，先删后面的索引才不失效）；
 *  两边等长 ⇒ change（「单条工具 ⇄ 工具组」这种**分组边界翻转**就落在这里）；其余 ⇒ reload；
 * 5. 前缀区的内容变化 ⇒ change（索引都 < p，不受中段增删影响）。
 *
 * 不变量（自测断言）：把返回的 ops **按顺序回放**到 `prev` 上，逐项等于 `next`；
 * 且「内容没变时 ops 为空」—— 既不漏报（界面不动）也不乱报（白重绘）。
 */
export function diffTimelineRenderItems(
  prev: TimelineRenderItem[], next: TimelineRenderItem[]
): TimelineRenderOperation[] {
  const ops: TimelineRenderOperation[] = [];
  if (prev === next) {
    return ops;
  }
  let p = 0;
  while (p < prev.length && p < next.length && prev[p].key === next[p].key) {
    p += 1;
  }
  let s = 0;
  while (prev.length - 1 - s >= p && next.length - 1 - s >= p
    && prev[prev.length - 1 - s].key === next[next.length - 1 - s].key) {
    s += 1;
  }
  for (let j = 0; j < s; j++) {
    if (!sameTimelineRenderItem(prev[prev.length - s + j], next[next.length - s + j])) {
      ops.push(renderOperation(TimelineRenderOp.RELOAD, 0));
      return ops;
    }
  }
  const prevMid = prev.length - s - p;
  const nextMid = next.length - s - p;
  if (prevMid === 0 && nextMid > 0) {
    for (let i = p; i < next.length - s; i++) {
      ops.push(renderOperation(TimelineRenderOp.ADD, i));
    }
  } else if (nextMid === 0 && prevMid > 0) {
    for (let i = prev.length - s - 1; i >= p; i--) {
      ops.push(renderOperation(TimelineRenderOp.DELETE, i));
    }
  } else if (prevMid === nextMid) {
    for (let i = p; i < prev.length - s; i++) {
      if (!sameTimelineRenderItem(prev[i], next[i])) {
        ops.push(renderOperation(TimelineRenderOp.CHANGE, i));
      }
    }
  } else {
    ops.push(renderOperation(TimelineRenderOp.RELOAD, 0));
    return ops;
  }
  for (let i = 0; i < p; i++) {
    if (!sameTimelineRenderItem(prev[i], next[i])) {
      ops.push(renderOperation(TimelineRenderOp.CHANGE, i));
    }
  }
  return ops;
}

/**
 * 工具组汇总标题 —— 上游 `toolRunSummary()`（`:1014-1030`）：
 * 先按「推理 / 指令 / 修改文件 / 创建文件」拼（英文逗号分隔），全空时回落「N 条活动」。
 *
 * ⚠️ 本工程的时间线没有结构化 `fileChanges`（文件变更只在 body 里），所以只统计前两项；
 * 这一条取舍写进交付说明由 Lead 复核。
 */
export function toolRunSummary(messages: TimelineMessage[]): string {
  let reasoning = 0;
  let commands = 0;
  for (let i = 0; i < messages.length; i++) {
    if (messages[i].kind === MessageKind.REASONING) {
      reasoning += 1;
    } else if (messages[i].kind === MessageKind.COMMAND) {
      commands += 1;
    }
  }
  const parts: string[] = [];
  if (reasoning > 0) {
    parts.push(ToolRunText.reasoning(reasoning));
  }
  if (commands > 0) {
    parts.push(ToolRunText.commands(commands));
  }
  return parts.length > 0 ? parts.join(', ') : ToolRunText.items(messages.length);
}

/** 一条「回合末尾动作」（上游 `AgentReplyAction` + `agentActionsByTurnEnd`）。 */
export interface TimelineTurnAction {
  /** 挂在哪一个渲染单元的 key 上（该回合的**最后一个**单元）。 */
  key: string;
  /** 该回合里 agent 全部正文拼起来（两换行连接、去首尾空白）。 */
  copyText: string;
  /** 参与复制的消息 id。 */
  itemIds: string[];
}

/** 可复制的 agent 正文（上游 `isCopyableAgentText`：`kind == Text && author == Agent`）。 */
export function isCopyableAgentText(message: TimelineMessage): boolean {
  return message.kind === MessageKind.MESSAGE && message.author === MessageAuthor.AGENT;
}

/**
 * 上游 `buildAgentActionsByTurnEnd()`（`:680-740`）：
 * 以「用户消息」为回合起点，把该回合里 agent 的正文收集起来，动作挂在**回合最后一个渲染单元**上。
 * 页面从旧到新渲染，这里同样按传入顺序处理。
 */
export function buildTurnActions(items: TimelineRenderItem[]): TimelineTurnAction[] {
  const out: TimelineTurnAction[] = [];
  let parts: string[] = [];
  let ids: string[] = [];
  let endKey: string = '';
  let open: boolean = false;

  const finish = (): void => {
    const text = parts.filter((p: string) => p.trim().length > 0).join('\n\n').trim();
    if (open && endKey.length > 0 && ids.length > 0) {
      out.push({ key: endKey, copyText: text, itemIds: ids });
    }
    parts = [];
    ids = [];
    endKey = '';
    open = false;
  };

  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    let startsTurn = false;
    for (let j = 0; j < item.messages.length; j++) {
      const m = item.messages[j];
      if (m.kind === MessageKind.MESSAGE && m.author === MessageAuthor.USER) {
        startsTurn = true;
      }
    }
    if (startsTurn && open) {
      finish();
    }
    if (startsTurn) {
      open = true;
    }
    for (let j = 0; j < item.messages.length; j++) {
      const m = item.messages[j];
      if (isCopyableAgentText(m) && m.body.trim().length > 0) {
        if (!open) {
          open = true;
        }
        parts.push(m.body.trimEnd());
        ids.push(m.id);
      }
    }
    if (open) {
      endKey = item.key;
    }
  }
  finish();
  return out;
}

/** 某个渲染单元是不是「回合末尾」（决定那一行要不要出 `复制 / 分享`）。 */
export function turnActionForKey(actions: TimelineTurnAction[], key: string): TimelineTurnAction | undefined {
  for (let i = 0; i < actions.length; i++) {
    if (actions[i].key === key) {
      return actions[i];
    }
  }
  return undefined;
}

/** 从任意文本里提取可渲染的代码块（```lang ... ```）。 */
export interface CodeBlock {
  language: string;
  code: string;
}

export function splitCodeBlocks(text: string): (string | CodeBlock)[] {
  const parts: (string | CodeBlock)[] = [];
  const fence = '```';
  let index = 0;
  while (index < text.length) {
    const start = text.indexOf(fence, index);
    if (start < 0) {
      parts.push(text.substring(index));
      break;
    }
    if (start > index) {
      parts.push(text.substring(index, start));
    }
    const afterFence = start + fence.length;
    const lineEnd = text.indexOf('\n', afterFence);
    if (lineEnd < 0) {
      parts.push(text.substring(start));
      break;
    }
    const language = text.substring(afterFence, lineEnd).trim();
    const end = text.indexOf(fence, lineEnd + 1);
    if (end < 0) {
      const code: CodeBlock = { language: language, code: text.substring(lineEnd + 1) };
      parts.push(code);
      break;
    }
    const code: CodeBlock = { language: language, code: text.substring(lineEnd + 1, end) };
    parts.push(code);
    index = end + fence.length;
  }
  return parts;
}
