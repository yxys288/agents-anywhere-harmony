/**
 * **首条消息的内联附件**（R54，草稿态专用）的纯逻辑层。
 *
 * 背景：aa-hm 的新建对话（草稿态）此前**完全没有附件入口** —— 会话详情的附件走的是
 * 「先 `POST /sessions/{id}/attachments`（multipart）拿 fileId，再随消息发 fileId」这一条链，
 * 它**必须有 sessionId**；而草稿态服务端会话还不存在 ⇒ 只能走 `create-and-start` 的
 * **内联附件**（base64 随创建请求一起发）。
 *
 * 契约（**以服务端源码为准，不是猜的**）：
 *  · 请求体：`specs/01-api-spec.md` §3 —— `attachments: [{fileId,name,mediaType,size,sha256,contentBase64}]`；
 *  · 服务端模型 `server/agent_server/core/models.py:707-728`（`InlineAttachmentRef` / `SessionCreateAndStartRequest`）：
 *  `fileId` 1..64、`name` 1..512、`mediaType` 默认 `application/octet-stream`、
 *  `size` 给了就必须**等于**字节数、`sha256` 给了就必须**等于**内容的 sha256，`attachments` 最多 **10** 条；
 *  · 落盘：`server/agent_server/services/session_run.py:225-239`（`_persist_inline_attachments` →
 *  `save_user_uploaded_file`）——客户端传的 `fileId` **会被服务端替换**成它自己生成的 `file_…`；
 *  · 能力闸门：带附件时服务端要求 `runtime.attachment` 可用（`session_run.py:185-193`），
 *  连接器侧再查一次 bridge 能力（`connector/connector/runtimes/dsh/runtime.py:334-337`，
 *  不支持时抛 `This DSH Bridge does not support attachments`）。
 *
 * ⚠️ 为什么草稿态另设一个**更小**的体积上限：内联附件要把整个文件读进内存 → base64（约 ×1.33）
 *  → 再拼进 JSON 文本，25MB 的文件在这条链上会占到 60MB 以上，手机上极易被系统杀掉。
 *  已上传那条链（multipart，原始字节）仍走 `feature/AttachmentStore` 的 25MB 闸门。
 *
 * 本文件零 ArkUI / 零 @kit 依赖（只 import 同目录的纯类型）⇒ 可被
 * `tools/logic-test/suite-inline-attachment.mjs` 直接转译断言。
 */

import { RemoteInlineAttachmentRef } from './Types';

/** 服务端要求的能力 id（`server/agent_server/core/capabilities.py:12` 逐字同值）。 */
export const RUNTIME_ATTACHMENT_CAPABILITY: string = 'runtime.attachment';

/** 服务端 `attachments: max_length=10` —— 客户端提前拦，别等服务端 422。 */
export const MAX_INLINE_ATTACHMENTS: number = 10;

/**
 * 草稿态单文件上限（10MB）。
 *
 * 取值依据见文件头：内存里要同时存在「原始字节 + base64 字符串 + JSON 文本」三份。
 */
export const MAX_INLINE_ATTACHMENT_BYTES: number = 10 * 1024 * 1024;

/**
 * 本地待发附件（**只在本机存在**：草稿态没有 fileId，也没有上传过的服务端副本）。
 *
 * `uri` 是 picker 给的文档 URI，创建会话那一刻才会被读成字节。
 */
export interface LocalAttachment {
  uri: string;
  name: string;
  mediaType: string;
  size: number;
}

/** 闸门结果（`ok = false` 时 `message` 是可直接展示给用户的中文提示）。 */
export interface AttachmentStageCheck {
  ok: boolean;
  message: string;
}

/**
 * 人读的体积（B / KB / MB）。
 *
 * ⚠️ 不能一律按 MB 保留一位小数：25KB 的图片会显示成「0.0MB」，用户会以为附件是空的
 * （真机实测的观感问题）。
 */
export function humanSize(bytes: number): string {
  if (bytes < 1024) {
    return String(bytes) + 'B';
  }
  if (bytes < 1024 * 1024) {
    return (bytes / 1024).toFixed(1) + 'KB';
  }
  return (bytes / (1024 * 1024)).toFixed(1) + 'MB';
}

/** 附件条/行/去重都用它：picker 的 URI 在同一台机器上唯一。 */
export function localAttachmentKey(attachment: LocalAttachment): string {
  return attachment.uri;
}

/** 附件条上显示的名字（picker 偶尔给空名，兜一个占位而不是留空白）。 */
export function localAttachmentLabel(attachment: LocalAttachment): string {
  return attachment.name.length > 0 ? attachment.name : '未命名文件';
}

/**
 * 还能不能再放一个：条数上限（服务端 10）+ 体积上限（本机 10MB）。
 *
 * ⚠️ 体积必须在 `readSync` **之前**判（与 `AttachmentStore.checkUploadSize` 同一条理由），
 *  否则一个几百 MB 的文件会先把内存吃光再谈上限。
 */
export function canStageAttachment(current: LocalAttachment[], size: number, name: string): AttachmentStageCheck {
  const label = name.length > 0 ? name : '（未命名文件）';
  if (current.length >= MAX_INLINE_ATTACHMENTS) {
    const full: AttachmentStageCheck = {
      ok: false,
      message: '首条消息最多带 ' + String(MAX_INLINE_ATTACHMENTS) + ' 个附件，已经放满了。'
    };
    return full;
  }
  if (size < 0) {
    const invalid: AttachmentStageCheck = { ok: false, message: '读不到「' + label + '」的大小，已跳过。' };
    return invalid;
  }
  if (size > MAX_INLINE_ATTACHMENT_BYTES) {
    const oversize: AttachmentStageCheck = {
      ok: false,
      message: '「' + label + '」有 ' + humanSize(size) + '，超过首条消息单个附件 '
        + humanSize(MAX_INLINE_ATTACHMENT_BYTES) + ' 的上限，未添加。'
    };
    return oversize;
  }
  const pass: AttachmentStageCheck = { ok: true, message: '' };
  return pass;
}

/**
 * 内联附件的占位 `fileId`。
 *
 * 服务端**不用**它（`_persist_inline_attachments` 用的是 `save_user_uploaded_file` 生成的
 * `file_…`），但模型要求 1..64 字符且唯一 ⇒ 给一个稳定、可读、绝不会撞的串。
 */
export function inlineAttachmentFileId(index: number): string {
  return 'file_aa_inline_' + String(index + 1);
}

/**
 * 组装一条内联附件引用。
 *
 * `sha256` / `contentBase64` 由调用方算（本文件零 @kit 依赖，不能自己编码）：
 *  · `sha256` = 内容的 sha256 十六进制（`utils/Codec.sha256Hex`）；
 *  · `contentBase64` = 标准 base64（`utils/Codec.base64Encode`，**不是** base64url、无换行）。
 * ⚠️ 两个校验值都必须**与内容一致**：服务端 `_decode_inline_attachment` 对不上就直接拒。
 */
export function inlineAttachmentRefFor(local: LocalAttachment, index: number, sha256: string,
  contentBase64: string): RemoteInlineAttachmentRef {
  const ref: RemoteInlineAttachmentRef = {
    fileId: inlineAttachmentFileId(index),
    name: localAttachmentLabel(local),
    mediaType: local.mediaType.length > 0 ? local.mediaType : 'application/octet-stream',
    size: local.size,
    sha256: sha256,
    contentBase64: contentBase64
  };
  return ref;
}

/** 附件条右上角/提示里的一句话（0 个时返回空串，调用方据此不占位）。 */
export function localAttachmentSummary(list: LocalAttachment[]): string {
  if (list.length === 0) {
    return '';
  }
  let total = 0;
  for (let i = 0; i < list.length; i++) {
    total += list[i].size;
  }
  return String(list.length) + ' 个附件 · ' + humanSize(total);
}

/** 草稿态下「添加文件」这一行能不能用（`runtime.attachment` 可用时才可以）。 */
export function inlineAttachmentRowDetail(allowed: boolean): string {
  return allowed ? '图片 / 文件，随首条消息一起发出' : '这台 Agent 不支持随首条消息发附件';
}

/** 能力不可用时给用户的原话（**不要**把服务端那句英文甩给用户）。 */
export function inlineAttachmentUnavailableText(): string {
  return '这个 Agent 没有上报 `runtime.attachment` 能力，暂时不能在首条消息里带附件；'
    + '可以在对话开始后再添加。';
}
