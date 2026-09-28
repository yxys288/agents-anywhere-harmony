/**
 * 应用常量与版本工具。
 */

/** 与服务端 `/health` 的 `version` 同源的客户端版本号（对应 Android `BuildConfig.VERSION_NAME`）。 */
export const APP_VERSION_NAME: string = '2.0.0';

/** 官方 Cloud 地址（与服务端 `/health` 校验通过后才算可用）。 */
export const OFFICIAL_SERVER: string = 'https://web.agents-anywhere.com';

/**
 * 版本比较（对应 Android `api/UpdateVersion.kt`）：
 * 逐段按数值比较，段数不同时缺省段按 0；非数字段返回 undefined（调用方报格式错误）。
 */
export function compareVersions(left: string, right: string): number | undefined {
  const leftParts = parseVersion(left);
  const rightParts = parseVersion(right);
  if (leftParts === undefined || rightParts === undefined) {
    return undefined;
  }
  const length = Math.max(leftParts.length, rightParts.length);
  for (let i = 0; i < length; i++) {
    const a = i < leftParts.length ? leftParts[i] : 0;
    const b = i < rightParts.length ? rightParts[i] : 0;
    if (a > b) {
      return 1;
    }
    if (a < b) {
      return -1;
    }
  }
  return 0;
}

function parseVersion(version: string): number[] | undefined {
  const trimmed = version.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  // 允许 `v1.2.3` / `1.2.3-beta.1` 形式：只取数字主干
  const normalized = trimmed.startsWith('v') || trimmed.startsWith('V')
    ? trimmed.substring(1) : trimmed;
  const main = normalized.split('-')[0].split('+')[0];
  const segments = main.split('.');
  const out: number[] = [];
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i];
    if (segment.length === 0 || !/^\d+$/.test(segment)) {
      return undefined;
    }
    out.push(Number.parseInt(segment, 10));
  }
  return out.length > 0 ? out : undefined;
}
