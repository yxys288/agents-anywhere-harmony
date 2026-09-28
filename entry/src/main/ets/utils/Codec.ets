/**
 * 编解码助手：Base64 解码 + SHA-256 十六进制摘要。
 * 用于附件下载后的完整性校验（对应 Android `SessionsApi.downloadSessionAttachment`）。
 */

import { util } from '@kit.ArkTS';
import { sha256Hex as sha256HexPure } from './Sha256';

/** 标准 Base64 解码；非法输入抛错（调用方转成 AttachmentTransferFailure.InvalidBase64）。 */
export function base64Decode(text: string): Uint8Array {
  const helper = new util.Base64Helper();
  try {
    return helper.decodeSync(text);
  } catch (error) {
    throw new Error(`Base64 解码失败：${error instanceof Error ? (error as Error).message : String(error)}`);
  }
}

export function base64Encode(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  try {
    return helper.encodeToStringSync(bytes);
  } catch (error) {
    throw new Error(`Base64 编码失败：${error instanceof Error ? (error as Error).message : String(error)}`);
  }
}

/**
 * SHA-256 十六进制小写摘要。
 *
 * 用工程内的纯 ArkTS 实现（`utils/Sha256.ets`）而不是 `@kit.CryptoArchitectureKit`：
 * 后者在构建期会产生 6 条「system capacity ... not supported on all devices」与
 * 「Function may throw exceptions」告警，且部分设备上不可用；
 * 而附件校验与 PKCE 是**必须成功**的路径，不适合依赖可选 Kit。
 * 纯实现还顺带进了 Node 侧逻辑自测（NIST 向量断言）。
 */
export function sha256Hex(bytes: Uint8Array): string {
  return sha256HexPure(bytes);
}

/** 生成客户端消息 id（用于乐观消息与服务端回执对齐）。 */
export function newClientMessageId(): string {
  const random = Math.floor(Math.random() * 0xFFFFFFFF).toString(16);
  return `hm-${Date.now()}-${random}`;
}
