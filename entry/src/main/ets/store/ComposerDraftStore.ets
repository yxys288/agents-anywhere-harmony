/**
 * 会话输入框草稿的本地持久化（对应上游 Android `SessionComposerDraftStore.kt`）。
 *
 * 语义照抄上游：
 *  - key = sessionId，value = {text, attachments} 的 JSON；
 *  - **空草稿等价于清除**（文本全空白且没有附件时不写记录，见 save）；
 *  - 读取先命中内存缓存，未命中再读持久化后端；
 *  - 单条记录损坏（截断 / 旧格式 / 被手改）时按「没有草稿」处理 —— 一条坏数据不该把输入区拖垮。
 *
 * 两个刻意的设计取舍：
 *  ① 本模块**不 import 任何 @kit / ArkUI**：持久化后端由 attachStorage() 注入
 *  （页面侧用 preferences 实现，见 SessionDetailScreen 里的 DraftPrefsStorage）。
 *  这样整份存取策略能在 Node 里跑断言（tools/logic-test/suite-input.mjs）——
 *  「杀掉应用再回来草稿还在不在」这类行为只能在真机上复现，却最适合用纯逻辑守住。
 *  ② **不给 store 加监听器**：草稿只有当前页面一个读者，页面自己写、自己读（@State draft）。
 *  加 onChange/offChange 只会引入 [坑 147] 那类「注册/注销必须配对」的泄漏面，
 *  这里没有任何收益。
 */

/** 草稿里的一条待发附件（已上传成功、只有服务端 fileId，与上游 remote 附件同构）。 */
export interface DraftAttachment {
  fileId: string;
  name: string;
}

/** 一份会话草稿。 */
export interface ComposerDraft {
  text: string;
  attachments: DraftAttachment[];
}

/**
 * 持久化后端（preferences 的最小投影）。
 * ⚠️ 用函数类型属性而不是方法签名：ArkTS 不允许对象字面量实现「带方法签名」的接口。
 */
export interface DraftStorage {
  read: (key: string) => string;
  write: (key: string, value: string) => void;
  remove: (key: string) => void;
}

/** 偏好键前缀：与登录态等其它键隔离，便于排查与将来整体迁移。 */
const DRAFT_KEY_PREFIX: string = 'composer_draft:';

/** 某个会话的偏好键。 */
export function draftKey(sessionId: string): string {
  return DRAFT_KEY_PREFIX + sessionId;
}

/** 空草稿判定：文本全空白且没有附件时不留记录（对齐上游 text.isBlank() && attachments.isEmpty()）。 */
export function isDraftEmpty(text: string, attachments: DraftAttachment[]): boolean {
  return text.trim().length === 0 && attachments.length === 0;
}

/** 草稿 → 持久化字符串。 */
export function encodeDraft(text: string, attachments: DraftAttachment[]): string {
  const items: Record<string, Object>[] = [];
  for (let i = 0; i < attachments.length; i++) {
    const item: Record<string, Object> = {
      'fileId': attachments[i].fileId,
      'name': attachments[i].name
    };
    items.push(item);
  }
  const payload: Record<string, Object> = { 'text': text, 'attachments': items };
  return JSON.stringify(payload);
}

/**
 * 持久化字符串 → 草稿；**任何**不合法输入都返回 undefined（调用方按「没有草稿」处理）。
 * 逐字段做类型检查而不是一句 as：preferences 里的内容会被旧版本覆盖、也可能被手改。
 */
export function decodeDraft(raw: string): ComposerDraft | undefined {
  if (raw.length === 0) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(raw) as Record<string, Object>;
    const textValue = parsed['text'];
    const text = typeof textValue === 'string' ? textValue as string : '';
    const attachments: DraftAttachment[] = [];
    const listValue = parsed['attachments'];
    if (listValue !== undefined && listValue !== null && Array.isArray(listValue)) {
      const list = listValue as Object[];
      for (let i = 0; i < list.length; i++) {
        const item = list[i];
        if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
          continue;
        }
        const entry = item as Record<string, Object>;
        const fileIdValue = entry['fileId'];
        if (typeof fileIdValue !== 'string' || (fileIdValue as string).length === 0) {
          continue;
        }
        const fileId = fileIdValue as string;
        const nameValue = entry['name'];
        const name = typeof nameValue === 'string' && (nameValue as string).length > 0
          ? nameValue as string : fileId;
        const attachment: DraftAttachment = { fileId: fileId, name: name };
        attachments.push(attachment);
      }
    }
    if (isDraftEmpty(text, attachments)) {
      return undefined;
    }
    const draft: ComposerDraft = { text: text, attachments: attachments };
    return draft;
  } catch (error) {
    // 坏数据不该让输入区崩掉：当成「没有草稿」，下一次输入会重新写一份干净的。
    return undefined;
  }
}

/**
 * 是否要（重新）为这个会话从持久化后端恢复草稿。
 *
 * 两条规则都来自真机缺陷（R8 模拟器冒烟 D1：杀进程重启后草稿不恢复，而 preferences 里数据完好）：
 *  - **后端还没就绪时，不能把「没读成」记成「已恢复」** —— 否则 attach 之后也永远不会再读；
 *  - 已经成功为**同一个**会话读过一次就不再读 —— pull() 会被频繁调用，再读会把用户刚敲进
 *  输入框的内容覆盖回旧值（内存里的那份才是最新的）。
 *
 * 「同一会话二次进入要重读」成立：新页面实例的 restoredSessionId 是空串，
 * 切会话后 restoredSessionId 又是另一个会话 —— 两种情况下都返回 true。
 *
 * @param sessionId 当前会话
 * @param restoredSessionId 上一次**成功**恢复过的会话 id（从未成功过传空串）
 * @param storageReady 持久化后端是否就绪（ComposerDraftStore.hasStorage()）
 */
export function shouldRestoreDraft(
  sessionId: string, restoredSessionId: string, storageReady: boolean
): boolean {
  if (sessionId.length === 0) {
    return false;
  }
  if (!storageReady) {
    return false;
  }
  return restoredSessionId !== sessionId;
}

/**
 * 「已恢复这个会话上次没发出去的草稿」这句提示该不该显示。
 *
 * 判据是**当前草稿是否仍等于恢复出来的那一份**，而不是一个「显示过就置位」的开关：
 *  - R8 第二轮复验里这条提示 6 帧全 0 命中 —— 根因就是最早那版用一个 @State 字符串开关，
 *  而 `TextArea({ text: this.draft })` 被程序回填时**也会触发 onChange**，
 *  onChange 里那句「提示 = 空」把刚设好的提示在同一帧清掉了；
 *  - 现在不设开关、也**不在任何回调里清它**：只比较「当前草稿」与「恢复时的原文」。
 *  用户一改动内容，两个字符串自然不等 ⇒ 提示消失；草稿清空（发送成功 / 用户清空）
 *  ⇒ 长度判据让它消失。要点是「页面里没有任何一处把提示置空」—— 没有清空语句，
 *  就没有被误清的路径。
 *
 * @param draftText 输入框当前内容
 * @param restoredSnapshot 恢复草稿时的原文（没从后端恢复过草稿时是空串）
 */
export function shouldShowRestoredNotice(draftText: string, restoredSnapshot: string): boolean {
  return draftText.length > 0 && draftText === restoredSnapshot;
}

export class ComposerDraftStore {
  private static instance?: ComposerDraftStore;

  private memory: Map<string, ComposerDraft> = new Map<string, ComposerDraft>();
  private storage?: DraftStorage;

  static get(): ComposerDraftStore {
    if (ComposerDraftStore.instance === undefined) {
      ComposerDraftStore.instance = new ComposerDraftStore();
    }
    return ComposerDraftStore.instance;
  }

  /** 注入持久化后端（页面首次进入时调用）。已注入过就忽略 —— 幂等，可安全地反复调用。 */
  attachStorage(storage: DraftStorage): void {
    if (this.storage !== undefined) {
      return;
    }
    this.storage = storage;
  }

  /**
   * 持久化后端是否已就绪。
   * 页面据此区分「后端还没准备好」与「这个会话确实没有草稿」—— 前者不该锁定恢复（见 shouldRestoreDraft）。
   */
  hasStorage(): boolean {
    return this.storage !== undefined;
  }

  /** 读取草稿；没有草稿时返回空草稿（调用方不必再判 undefined）。 */
  restore(sessionId: string): ComposerDraft {
    const empty: ComposerDraft = { text: '', attachments: [] };
    if (sessionId.length === 0) {
      return empty;
    }
    const cached = this.memory.get(sessionId);
    if (cached !== undefined) {
      return cached;
    }
    const storage = this.storage;
    if (storage === undefined) {
      return empty;
    }
    const decoded = decodeDraft(storage.read(draftKey(sessionId)));
    if (decoded === undefined) {
      return empty;
    }
    this.memory.set(sessionId, decoded);
    return decoded;
  }

  /** 保存草稿；空草稿等价于清除（与上游 save 的行为一致）。 */
  save(sessionId: string, text: string, attachments: DraftAttachment[]): void {
    if (sessionId.length === 0) {
      return;
    }
    if (isDraftEmpty(text, attachments)) {
      this.clear(sessionId);
      return;
    }
    const draft: ComposerDraft = { text: text, attachments: attachments.slice() };
    this.memory.set(sessionId, draft);
    const storage = this.storage;
    if (storage !== undefined) {
      storage.write(draftKey(sessionId), encodeDraft(draft.text, draft.attachments));
    }
  }

  /** 清除草稿（发送成功后调用）。 */
  clear(sessionId: string): void {
    if (sessionId.length === 0) {
      return;
    }
    this.memory.delete(sessionId);
    const storage = this.storage;
    if (storage !== undefined) {
      storage.remove(draftKey(sessionId));
    }
  }
}
