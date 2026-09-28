/**
 * 纯 ArkTS 的 SHA-256（FIPS 180-4）。
 *
 * 为什么不用 `@kit.CryptoArchitectureKit`：
 * 1. 构建期会报 `The system capacity of this api 'createMd' is not supported on all devices`
 *  与 `Function may throw exceptions`（共 12 条告警），而本工程要求「无 ArkTS 告警构建」；
 * 2. 该 kit 在部分设备上不可用，而附件完整性校验与 PKCE 挑战都**必须有**摘要能力，
 *  能力缺失时应当是可预期的失败而不是运行期异常；
 * 3. 纯逻辑实现不依赖任何 Kit，可以直接进 Node 侧的逻辑自测（已有 NIST 向量断言）。
 *
 * 只在附件下载校验与 OAuth PKCE 挑战两处使用，输入量很小（≤ 25 MB），性能足够。
 */

const K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function rotr(value: number, bits: number): number {
  return ((value >>> bits) | (value << (32 - bits))) >>> 0;
}

/** SHA-256 摘要（32 字节）。 */
export function sha256(input: Uint8Array): Uint8Array {
  const bitLength = input.length * 8;
  // 填充：0x80 + 若干 0，使长度 ≡ 56 (mod 64)，末尾 8 字节大端位长
  const paddedLength = (((input.length + 8) >> 6) + 1) << 6;
  const buffer = new Uint8Array(paddedLength);
  buffer.set(input, 0);
  buffer[input.length] = 0x80;
  // JS 数字只有 53 位安全整数；用高/低 32 位分写，覆盖到 2^53 位（约 1 PB）输入
  const highBits = Math.floor(bitLength / 0x100000000);
  const lowBits = bitLength >>> 0;
  buffer[paddedLength - 8] = (highBits >>> 24) & 0xFF;
  buffer[paddedLength - 7] = (highBits >>> 16) & 0xFF;
  buffer[paddedLength - 6] = (highBits >>> 8) & 0xFF;
  buffer[paddedLength - 5] = highBits & 0xFF;
  buffer[paddedLength - 4] = (lowBits >>> 24) & 0xFF;
  buffer[paddedLength - 3] = (lowBits >>> 16) & 0xFF;
  buffer[paddedLength - 2] = (lowBits >>> 8) & 0xFF;
  buffer[paddedLength - 1] = lowBits & 0xFF;

  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  const w = new Uint32Array(64);
  const chunkCount = paddedLength >> 6;
  for (let chunk = 0; chunk < chunkCount; chunk++) {
    const offset = chunk * 64;
    for (let i = 0; i < 16; i++) {
      const base = offset + i * 4;
      w[i] = ((buffer[base] << 24) | (buffer[base + 1] << 16) | (buffer[base + 2] << 8) |
        buffer[base + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i++) {
      const s0 = (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
      const s1 = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let i = 0; i < 64; i++) {
      const s1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
      const ch = ((e & f) ^ ((~e) & g)) >>> 0;
      const temp1 = (h + s1 + ch + K[i] + w[i]) >>> 0;
      const s0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const temp2 = (s0 + maj) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }

  const out = new Uint8Array(32);
  const words: number[] = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (let i = 0; i < 8; i++) {
    out[i * 4] = (words[i] >>> 24) & 0xFF;
    out[i * 4 + 1] = (words[i] >>> 16) & 0xFF;
    out[i * 4 + 2] = (words[i] >>> 8) & 0xFF;
    out[i * 4 + 3] = words[i] & 0xFF;
  }
  return out;
}

function byteHex(value: number): string {
  const text = (value & 0xFF).toString(16);
  return text.length === 1 ? `0${text}` : text;
}

/** SHA-256 十六进制小写摘要（64 字符）。 */
export function sha256Hex(input: Uint8Array): string {
  const digest = sha256(input);
  let out = '';
  for (let i = 0; i < digest.length; i++) {
    out += byteHex(digest[i]);
  }
  return out;
}

/**
 * UTF-8 字符串 → 字节。**全工程唯一实现**（R83 收敛：改前 `api/ApiClient.ets` 的 `utf8ToBuffer`
 * 与 `feature/TerminalStore.ets` 的 `uint8FromString` 是同一份算法的另外两份复制，本轮已删）。
 *
 * 为什么两遍扫描：第一遍只算字节数、第二遍直接写进**精确长度**的 `Uint8Array`。
 * 改前是「`number[]` 逐字节 push → 再拷进 `Uint8Array`」：多一次全量拷贝、多一倍峰值内存，
 * 而这是 HTTP 请求体 / 终端按键 / 附件摘要三条链路的**共同**热路径。
 *
 * ⚠️ 两遍的推进规则必须**逐字一致**（代理对合成一个码点后 `i` 再多走一格），否则长度与实际写入错位。
 * ⚠️ 孤代理码元（未成对的 D800~DFFF）仍按 3 字节**原样**编码 —— 这是改前就有的行为，本轮只做等价改写，
 * 不动它（Node 的 `Buffer.from` 会把孤代理换成 U+FFFD，两者不同，勿拿它当判据）。
 */
export function utf8Bytes(text: string): Uint8Array {
  // 第一遍：只算精确字节数（代理对合成一个码点后 i 再多走一格）
  let size = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        i += 1;
        size += 4;
        continue;
      }
    }
    if (code < 0x80) {
      size += 1;
    } else if (code < 0x800) {
      size += 2;
    } else {
      size += 3;
    }
  }
  // 第二遍：一次分配、顺序写入 —— 没有中间 number[]，也没有第二次全量拷贝
  const out = new Uint8Array(size);
  let at = 0;
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        i += 1;
      }
    }
    if (code < 0x80) {
      out[at] = code;
      at += 1;
    } else if (code < 0x800) {
      out[at] = 0xC0 | (code >> 6);
      out[at + 1] = 0x80 | (code & 0x3F);
      at += 2;
    } else if (code < 0x10000) {
      out[at] = 0xE0 | (code >> 12);
      out[at + 1] = 0x80 | ((code >> 6) & 0x3F);
      out[at + 2] = 0x80 | (code & 0x3F);
      at += 3;
    } else {
      out[at] = 0xF0 | (code >> 18);
      out[at + 1] = 0x80 | ((code >> 12) & 0x3F);
      out[at + 2] = 0x80 | ((code >> 6) & 0x3F);
      out[at + 3] = 0x80 | (code & 0x3F);
      at += 4;
    }
  }
  return out;
}

/** base64url（无填充），OAuth PKCE 的 `code_challenge` 用。 */
export function base64UrlNoPadding(bytes: Uint8Array): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += chars.charAt(b0 >> 2);
    out += chars.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    if (i + 1 < bytes.length) {
      out += chars.charAt(((b1 & 0x0F) << 2) | (b2 >> 6));
    }
    if (i + 2 < bytes.length) {
      out += chars.charAt(b2 & 0x3F);
    }
    i += 3;
  }
  return out;
}
