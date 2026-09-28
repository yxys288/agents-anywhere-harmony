/**
 * API 路径与服务器地址规则（对应 Android `api/ApiUrls.kt`）。
 *
 * 关键语义：
 * - 所有产品端点默认挂在 `/api/v2` 下；
 * - 老部署可能只有 legacy 路径（`/sessions` 而不是 `/api/v2/sessions`），
 *  因此首次请求会同时尝试两个候选，命中后把该 origin 的路由风格记下来；
 * - `normalizeServerOrigin()` 只接受 http(s) 纯 origin，带 userinfo/query/fragment 或
 *  非 `/api/v2` 路径的一律判非法。
 */

const API_NAMESPACE: string = '/api/v2';

enum ApiRouteStyle {
  NAMESPACED = 'namespaced',
  LEGACY = 'legacy'
}

const routeStyles: Map<string, ApiRouteStyle> = new Map<string, ApiRouteStyle>();

export function apiPath(path: string): string {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  let pathEnd = normalized.length;
  const q = normalized.indexOf('?');
  const h = normalized.indexOf('#');
  if (q >= 0 && (h < 0 || q < h)) {
    pathEnd = q;
  } else if (h >= 0) {
    pathEnd = h;
  }
  const pathname = normalized.substring(0, pathEnd);
  if (pathname === API_NAMESPACE || pathname.startsWith(`${API_NAMESPACE}/`)) {
    return normalized;
  }
  return `${API_NAMESPACE}${normalized}`;
}

function legacyApiPath(path: string): string {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  if (normalized === API_NAMESPACE) {
    return '/';
  }
  if (normalized.startsWith(`${API_NAMESPACE}/`)) {
    return normalized.substring(API_NAMESPACE.length);
  }
  return normalized;
}

export function apiUrl(serverUrl: string, path: string): string {
  const origin = normalizeServerOrigin(serverUrl);
  if (origin === null) {
    throw new Error('服务器地址必须是 http(s) origin。');
  }
  const style = routeStyles.get(origin);
  if (style === ApiRouteStyle.LEGACY) {
    return `${origin}${legacyApiPath(path)}`;
  }
  return `${origin}${apiPath(path)}`;
}

/** 未确定路由风格时返回 [namespaced, legacy] 两个候选，调用方按序重试。 */
export function apiUrlCandidates(serverUrl: string, path: string): string[] {
  const origin = normalizeServerOrigin(serverUrl);
  if (origin === null) {
    throw new Error('服务器地址必须是 http(s) origin。');
  }
  const style = routeStyles.get(origin);
  if (style === ApiRouteStyle.NAMESPACED) {
    return [`${origin}${apiPath(path)}`];
  }
  if (style === ApiRouteStyle.LEGACY) {
    return [`${origin}${legacyApiPath(path)}`];
  }
  return [`${origin}${apiPath(path)}`, `${origin}${legacyApiPath(path)}`];
}

/** 命中候选后记住该 origin 使用的路由风格。 */
export function rememberApiUrl(serverUrl: string, resolvedUrl: string): void {
  const origin = normalizeServerOrigin(serverUrl);
  if (origin === null) {
    return;
  }
  if (resolvedUrl.startsWith(origin)) {
    const rest = resolvedUrl.substring(origin.length);
    const style = (rest === API_NAMESPACE || rest.startsWith(`${API_NAMESPACE}/`))
      ? ApiRouteStyle.NAMESPACED
      : ApiRouteStyle.LEGACY;
    routeStyles.set(origin, style);
  }
}

export function webSocketApiUrl(serverUrl: string, path: string): string {
  const httpUrl = apiUrl(serverUrl, path);
  if (httpUrl.startsWith('https://')) {
    return `wss://${httpUrl.substring('https://'.length)}`;
  }
  return `ws://${httpUrl.substring('http://'.length)}`;
}

export function urlEncode(value: string): string {
  return encodeURIComponent(value);
}

export function usesLocalNetworkHost(host: string): boolean {
  if (host === 'localhost' || host === '::1' || host === '[::1]' || host.endsWith('.local')) {
    return true;
  }
  const parts = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  const octets: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (!/^\d+$/.test(parts[i])) {
      return false;
    }
    const value = Number.parseInt(parts[i], 10);
    if (value < 0 || value > 255) {
      return false;
    }
    octets.push(value);
  }
  if (octets[0] === 10 || octets[0] === 127) {
    return true;
  }
  if (octets[0] === 192 && octets[1] === 168) {
    return true;
  }
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) {
    return true;
  }
  return false;
}

interface ParsedAuthority {
  host: string;
  port: string;
}

function parseAuthority(authority: string): ParsedAuthority | null {
  if (authority.length === 0) {
    return null;
  }
  let host = authority;
  let port = '';
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']');
    if (close < 0) {
      return null;
    }
    host = authority.substring(1, close);
    const remainder = authority.substring(close + 1);
    if (remainder.length > 0) {
      if (!remainder.startsWith(':')) {
        return null;
      }
      port = remainder.substring(1);
    }
  } else {
    const colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      host = authority.substring(0, colon);
      port = authority.substring(colon + 1);
    }
  }
  if (host.length === 0) {
    return null;
  }
  if (port.length > 0) {
    if (!/^\d+$/.test(port)) {
      return null;
    }
    const portValue = Number.parseInt(port, 10);
    if (portValue < 0 || portValue > 65535) {
      return null;
    }
  }
  return { host: host.toLowerCase(), port: port };
}

/**
 * 归一化为 `scheme://host[:port]`；非法返回 null。
 * 不带 scheme 时：局域网/带端口 → http，其余 → https（与 Android 一致）。
 */
export function normalizeServerOrigin(serverUrl: string): string | null {
  let trimmed = serverUrl.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.length === 0) {
    return null;
  }

  let candidate = trimmed;
  if (!trimmed.includes('://')) {
    const beforeSlash = trimmed.includes('/') ? trimmed.substring(0, trimmed.indexOf('/')) : trimmed;
    const hostOnly = beforeSlash.includes(':') ? beforeSlash.substring(0, beforeSlash.indexOf(':')) : beforeSlash;
    if (hostOnly.length === 0) {
      return null;
    }
    const scheme = (usesLocalNetworkHost(hostOnly.toLowerCase()) || beforeSlash.includes(':')) ? 'http' : 'https';
    candidate = `${scheme}://${trimmed}`;
  }

  const schemeIndex = candidate.indexOf('://');
  if (schemeIndex <= 0) {
    return null;
  }
  const scheme = candidate.substring(0, schemeIndex).toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    return null;
  }
  const rest = candidate.substring(schemeIndex + 3);
  if (rest.includes('@') || rest.includes('?') || rest.includes('#')) {
    return null;
  }
  const slash = rest.indexOf('/');
  const authorityText = slash >= 0 ? rest.substring(0, slash) : rest;
  const rawPath = slash >= 0 ? rest.substring(slash) : '';

  let path = rawPath;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.length > 0 && path !== API_NAMESPACE) {
    return null;
  }

  const authority = parseAuthority(authorityText);
  if (authority === null) {
    return null;
  }
  const portSuffix = authority.port.length > 0 ? `:${authority.port}` : '';
  return `${scheme}://${authority.host}${portSuffix}`;
}
