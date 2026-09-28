/**
 * 消息附件的**按需下载 + 缓存**（对应 Android `ui/screens/sessiondetail/AttachmentImages.kt`
 * 里「按 fileId 拉内容再渲染」的那部分职责）。
 *
 * 为什么要单独一层：
 *  ① 附件内容是 base64 JSON，一条消息可能带多个附件，**不能在 build() 里拉**（build 会重复执行）；
 *  ② 同一条消息会在时间线里被反复重建（分页、事件合批），必须按 fileId 去重，避免重复请求；
 *  ③ 失败要能被界面读到（显示「附件加载失败」而不是空白）。
 *
 * 两个接口事实（决定了这里的形状）：
 *  - `GET /sessions/{id}/attachments/{fid}` 的响应里**没有 mediaType**，只有
 *  `{fileId,sessionId,path,name,size,sha256,contentBase64,createdAt}`；mediaType 只能从
 *  时间线上那条消息的附件元信息带进来（`TimelineAttachment.mediaType`）。
 *  - ArkUI 的 `Image` 支持 `data:image/png;base64,…`，但**不支持通配符** `image/*`，
 *  所以 mediaType 必须落到具体子类型，否则渲染成空白。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl } from '../store/AuthSessionStore';
import { AttachmentTransferException, AttachmentTransferFailure, RemoteDownloadedAttachment } from '../model/Types';
import { base64Encode } from '../utils/Codec';

export type AttachmentListener = () => void;

/**
 * R91-T2：附件缓存的**条目数上限**（超出后按 LRU 淘汰最久未用的那条）。
 *
 * 为什么要有界：`entries` 的值是**已经 base64 编码好的 data URI 字符串** ——
 * 一张 1MB 的图片在缓存里就是约 1.37M 个字符。原实现只增不减，
 * 一个翻过很多附件的历史会话会把图片内容一直留在内存里（ark ts heap 的常驻部分）。
 *
 * 为什么取 48：正常会话里带附件的消息是**少数**，一屏可见的附件通常个位数；
 * 48 条足以覆盖「来回滚动看同一批图」的场景，不会造成反复下载。
 * 上限以内**行为逐字不变**（本改动不触碰 `ensure` 的幂等判据）。
 */
export const MAX_CACHED_ATTACHMENTS: number = 48;

/**
 * R91-T2：缓存里 **data URI 字符总数**的上限。
 *
 * 只数 `dataUri`（非图片附件恒为空串、不占额度）。base64 是 latin1 文本，
 * 1 字符 ≈ 1 字节 ⇒ 16M 字符 ≈ 16MB，约等于十来张 1MB 的图。
 * 条目数上限与字节上限**同时生效**，任一条越界就淘汰 —— 因为「48 张 3MB 的图」
 * 与「48 张 20KB 的图」完全不是一回事。
 */
export const MAX_CACHED_DATA_URI_CHARS: number = 16 * 1024 * 1024;

/**
 * R91-T2：失败记录的条目数上限（FIFO 淘汰最旧的）。
 *
 * `errors` 同样是只增不减的 Map：一条长期会话里每个下载失败的 fileId 都会留下一条。
 * 它**必须**保留（见 `ensure` 的注释：短路「已失败」才不会自我放大成无限请求），
 * 所以只做**有界**而不是清空。
 */
export const MAX_ATTACHMENT_ERRORS: number = 128;

/** R91-T2：`cacheStats()` 的返回形状（有界性的可读判据）。 */
export interface AttachmentCacheStats {
  entries: number;
  errors: number;
  pending: number;
  dataUriChars: number;
}

export interface AttachmentEntry {
  /** 可直接喂给 `Image()` 的 data URI；非图片为空串。 */
  dataUri: string;
  /** 归一后的具体 mediaType（不含通配符）。 */
  mediaType: string;
  name: string;
  size: number;
}

export class AttachmentStore {
  private static instance?: AttachmentStore;

  private entries: Map<string, AttachmentEntry> = new Map<string, AttachmentEntry>();
  private errors: Map<string, string> = new Map<string, string>();
  private pending: Set<string> = new Set<string>();
  private listeners: AttachmentListener[] = [];
  /** R91-T2：`entries` 里所有 data URI 的字符总数（增删时同步维护，供字节上限判据用）。 */
  private dataUriChars: number = 0;

  static get(): AttachmentStore {
    if (AttachmentStore.instance === undefined) {
      AttachmentStore.instance = new AttachmentStore();
    }
    return AttachmentStore.instance;
  }

  onChange(listener: AttachmentListener): void {
    this.listeners.push(listener);
  }

  offChange(listener: AttachmentListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  entryOf(fileId: string): AttachmentEntry | undefined {
    const entry = this.entries.get(fileId);
    if (entry !== undefined) {
      // R91-T2：页面在 pull() 里对每条可见附件都会调一次 entryOf ⇒ 它天然就是
      // 「这一条现在还要用」的信号，正好当 LRU 的 touch。上限内它只做一次
      // delete+set（Map 顺序维护），不改任何可见行为。
      this.touch(fileId);
    }
    return entry;
  }

  errorOf(fileId: string): string | undefined {
    return this.errors.get(fileId);
  }

  /** 清空（切换会话时调用，避免上一个会话的附件占内存）。 */
  reset(): void {
    this.entries.clear();
    this.errors.clear();
    this.pending.clear();
    this.dataUriChars = 0;
    this.notify();
  }

  /**
   * R91-T2：缓存规模（诊断/断言用，不进渲染路径）。
   *
   * 返回的是「运行期真实占用」而不是配置值 —— 验收时可以直接读它证明有界。
   */
  cacheStats(): AttachmentCacheStats {
    const stats: AttachmentCacheStats = {
      entries: this.entries.size,
      errors: this.errors.size,
      pending: this.pending.size,
      dataUriChars: this.dataUriChars
    };
    return stats;
  }

  /**
   * R91-T2：把缓存压回限额内（LRU：最久未 `touch` 的先淘汰）。
   *
   * 触发点在 `ensure` 的命中路径与写入路径上，所以淘汰成本分摊在正常使用里，
   * 不需要另开定时器（本文件不持有任何计时器）。
   */
  private evictIfNeeded(): void {
    // ① 失败记录：FIFO。Map 的迭代顺序即插入顺序，取最前面的键即可。
    while (this.errors.size > MAX_ATTACHMENT_ERRORS) {
      const oldest = this.errors.keys().next();
      if (oldest.done === true) {
        break;
      }
      this.errors.delete(oldest.value);
    }
    // ② 条目数 / 字节数：LRU。entries 的插入顺序即「最近使用顺序」——
    //  `touch` 会在命中后把该键删掉再 set 回去，于是队尾恒为最近使用。
    while (this.entries.size > MAX_CACHED_ATTACHMENTS
      || (this.dataUriChars > MAX_CACHED_DATA_URI_CHARS && this.entries.size > 1)) {
      const oldest = this.entries.keys().next();
      if (oldest.done === true) {
        break;
      }
      const key = oldest.value;
      const dropped = this.entries.get(key);
      if (dropped !== undefined) {
        this.dataUriChars -= dropped.dataUri.length;
      }
      this.entries.delete(key);
    }
  }

  /** R91-T2：把某个条目挪到 LRU 队尾（命中即「最近使用」）。 */
  private touch(fileId: string): void {
    const entry = this.entries.get(fileId);
    if (entry === undefined) {
      return;
    }
    this.entries.delete(fileId);
    this.entries.set(fileId, entry);
  }

  /**
   * 确保某个附件已被拉取（幂等；已在缓存 / 请求中 / **已失败** 则直接返回）。
   * 页面在 `pull()` 里对所有可见附件调用它，而不是在 `build()` 里。
   *
   * ⚠️ 必须短路「已失败」的 fileId：页面是 `onChange → pull() → ensure()` 的闭环，
   * 而失败回调里会 `notify()` —— 只看 entries/pending 的话，一次失败就会
   * 「请求失败 → notify → pull → ensure → 再请求」**自我放大成无限请求**。
   * 失败后要重试请走 `retry()`（清掉错误记录再放行）。
   *
   * @param mediaTypeHint 时间线里带的 mediaType（下载接口不返回它）
   * @param nameHint 时间线里带的文件名（下载接口的 name 为空时兜底）
   */
  ensure(sessionId: string, fileId: string, mediaTypeHint: string, nameHint: string): void {
    if (fileId.length === 0 || sessionId.length === 0) {
      return;
    }
    if (this.entries.has(fileId) || this.pending.has(fileId) || this.errors.has(fileId)) {
      return;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      return;
    }
    this.pending.add(fileId);
    AppServices.get().sessions.downloadSessionAttachment(serverUrl, token, sessionId, fileId)
      .then((downloaded: RemoteDownloadedAttachment) => {
        this.pending.delete(fileId);
        this.errors.delete(fileId);
        const name = downloaded.name.length > 0 ? downloaded.name : nameHint;
        const mediaType = normalizeMediaType(mediaTypeHint, name);
        const dataUri = toDataUri(mediaType, downloaded.bytes);
        const previous = this.entries.get(fileId);
        if (previous !== undefined) {
          this.dataUriChars -= previous.dataUri.length;
        }
        this.entries.set(fileId, {
          dataUri: dataUri,
          mediaType: mediaType,
          name: name,
          size: downloaded.size
        });
        this.dataUriChars += dataUri.length;
        // R91-T2：写入后立刻收敛到限额内（超出则淘汰最久未用的条目）。
        this.evictIfNeeded();
        this.notify();
      })
      .catch((error: Object) => {
        this.pending.delete(fileId);
        this.errors.set(fileId, describeFailure(error));
        // R91-T2：**失败路径也要收敛**。第一版只在成功路径调了 evictIfNeeded()，
        // 于是「整屏附件全部下载失败」时 errors 会一路涨到 fileId 的个数（实测 200 条时
        // 完全没被压到上限内）。这是基准断言抓出来的真缺陷，不是理论问题。
        this.evictIfNeeded();
        this.notify();
      });
  }

  /** 用户在界面上点「重试」时调用：清掉失败记录后重新拉一次。 */
  retry(sessionId: string, fileId: string, mediaTypeHint: string, nameHint: string): void {
    this.errors.delete(fileId);
    this.notify();
    this.ensure(sessionId, fileId, mediaTypeHint, nameHint);
  }
}

/** mediaType 归一：优先用时间线给的，缺失/通配时按扩展名兜底。 */
function normalizeMediaType(hint: string, name: string): string {
  const trimmed = hint.trim().toLowerCase();
  if (trimmed.length > 0 && !trimmed.includes('*')) {
    return trimmed;
  }
  return guessMediaType(name);
}

/** ArkUI `Image` **不支持** `data:image/*;base64,…`，必须是具体子类型。 */
function toDataUri(mediaType: string, bytes: Uint8Array): string {
  if (!mediaType.startsWith('image/')) {
    return '';
  }
  if (bytes.length === 0) {
    return '';
  }
  return `data:${mediaType};base64,${base64Encode(bytes)}`;
}

/** 服务端没给 mediaType 时按扩展名兜底。 */
function guessMediaType(name: string): string {
  const lower = name.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.svg')) {
    return 'image/svg+xml';
  }
  if (lower.endsWith('.txt') || lower.endsWith('.md') || lower.endsWith('.log')) {
    return 'text/plain';
  }
  if (lower.endsWith('.json')) {
    return 'application/json';
  }
  return 'application/octet-stream';
}

/** 下载路径自带「base64/字节数/sha256」三重校验，失败原因要原样讲给用户。 */
function describeFailure(error: Object): string {
  if (error instanceof AttachmentTransferException) {
    const failure = (error as AttachmentTransferException).failure;
    if (failure === AttachmentTransferFailure.InvalidBase64) {
      return '附件内容不是合法的 base64。';
    }
    if (failure === AttachmentTransferFailure.SizeMismatch) {
      return '附件字节数与声明不一致。';
    }
    if (failure === AttachmentTransferFailure.Sha256Mismatch) {
      return '附件校验值不匹配，内容可能已损坏。';
    }
    return '附件下载未完成。';
  }
  return error instanceof Error ? (error as Error).message : String(error);
}

// ---------------------------------------------------------------------------
// 上传侧：体积上限（对应下载侧同样是 25MB 的那道闸）
// ---------------------------------------------------------------------------

/**
 * 上传单文件体积上限（25MB，与 `api/SessionsApi.ets` 里 `MAX_ATTACHMENT_DOWNLOAD_BYTES` 同量级）。
 *
 * 为什么必须在 `readSync` **之前**拦：上传是把整个文件读进内存再 base64 编码
 * （`fileIo.readSync` → `new Uint8Array(buffer)` → multipart 组装），一个几百 MB 的文件
 * 会直接撑爆应用内存；下载侧早就有这道闸，上传侧一直缺（第七轮审计发现）。
 */
export const MAX_ATTACHMENT_UPLOAD_BYTES: number = 25 * 1024 * 1024;

/** 体积校验结果（`ok = false` 时 `message` 是可直接展示给用户的中文提示）。 */
export interface UploadSizeCheck {
  ok: boolean;
  message: string;
}

/** 把字节数写成用户能读的 MB（保留一位小数）。 */
export function formatMegabytes(bytes: number): string {
  return (bytes / (1024 * 1024)).toFixed(1);
}

/**
 * 上传前的体积闸门。**纯函数**（不碰文件系统），所以能在 Node 里直接断言
 * （`tools/logic-test/suite-input.mjs`）；调用方拿到 `ok = false` 时
 * **不要再发上传请求**，把 `message` 展示出来即可。
 */
export function checkUploadSize(name: string, size: number): UploadSizeCheck {
  const label = name.length > 0 ? name : '（未命名文件）';
  if (size < 0) {
    const invalid: UploadSizeCheck = { ok: false, message: `读不到「${label}」的大小，已跳过。` };
    return invalid;
  }
  if (size > MAX_ATTACHMENT_UPLOAD_BYTES) {
    const oversize: UploadSizeCheck = {
      ok: false,
      message: `「${label}」有 ${formatMegabytes(size)}MB，超过单个附件 ${formatMegabytes(MAX_ATTACHMENT_UPLOAD_BYTES)}MB 的上限，未上传。`
    };
    return oversize;
  }
  const pass: UploadSizeCheck = { ok: true, message: '' };
  return pass;
}
