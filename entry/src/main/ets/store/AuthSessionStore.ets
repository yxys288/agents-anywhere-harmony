/**
 * 本地持久化（对应 Android 的 SharedPreferences：
 * `AuthSessionStore` 用 `agents_anywhere_auth`，`RealtimeClientIdStore` 用 `agents_anywhere_realtime`）。
 *
 * 采用 preferences 的同步接口：数据量极小（几个 token 字符串），同步读写更简单也不会有竞态。
 * 注意：清登录态时**保留** server_url（换账号不用重新填地址），但真实密钥类字段会一并清掉。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { normalizeServerOrigin } from '../api/ApiUrls';

const AUTH_STORE_NAME: string = 'agents_anywhere_auth';
const REALTIME_STORE_NAME: string = 'agents_anywhere_realtime';

const KEY_SERVER_URL: string = 'server_url';
const KEY_ACCESS_TOKEN: string = 'access_token';
const KEY_TOKEN_TYPE: string = 'token_type';
const KEY_USER_ID: string = 'user_id';
const KEY_ROLE: string = 'role';
const KEY_REFRESH_TOKEN: string = 'refresh_token';
const KEY_REFRESH_EXPIRES_AT: string = 'refresh_expires_at';
const KEY_DISPLAY_NAME: string = 'display_name';
const KEY_EMAIL: string = 'email';
const KEY_CLIENT_ID: string = 'client_id';
const KEY_APPEARANCE: string = 'appearance_mode';

export const APPEARANCE_SYSTEM: string = 'system';
export const APPEARANCE_LIGHT: string = 'light';
export const APPEARANCE_DARK: string = 'dark';

class PrefStore {
  private store?: preferences.Preferences;

  open(context: common.Context, name: string): void {
    if (this.store !== undefined) {
      return;
    }
    const options: preferences.Options = { name: name };
    try {
      this.store = preferences.getPreferencesSync(context, options);
    } catch (error) {
      // preferences 打不开时退化为「不持久化」：功能降级但不崩溃
      this.store = undefined;
    }
  }

  read(key: string, fallback: string): string {
    const store = this.store;
    if (store === undefined) {
      return fallback;
    }
    try {
      const value = store.getSync(key, fallback);
      return typeof value === 'string' ? value as string : fallback;
    } catch (error) {
      return fallback;
    }
  }

  write(key: string, value: string): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (error) {
      // 落盘失败不阻塞主流程
    }
  }

  remove(key: string): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.deleteSync(key);
      store.flush();
    } catch (error) {
    }
  }

  clear(): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.clearSync();
      store.flush();
    } catch (error) {
    }
  }
}

const authStore: PrefStore = new PrefStore();
const realtimeStore: PrefStore = new PrefStore();

export function initAppPrefs(context: common.Context): void {
  authStore.open(context, AUTH_STORE_NAME);
  realtimeStore.open(context, REALTIME_STORE_NAME);
}

/** 保存的服务器 origin（非法/为空时返回空串）。 */
export function readServerUrl(): string {
  const stored = authStore.read(KEY_SERVER_URL, '');
  const origin = normalizeServerOrigin(stored);
  return origin !== null ? origin : '';
}

export function readAccessToken(): string {
  return authStore.read(KEY_ACCESS_TOKEN, '');
}

export function readUserId(): string {
  return authStore.read(KEY_USER_ID, '');
}

export function readRole(): string {
  return authStore.read(KEY_ROLE, '');
}

export function readDisplayName(): string {
  return authStore.read(KEY_DISPLAY_NAME, '');
}

export function readEmail(): string {
  return authStore.read(KEY_EMAIL, '');
}

export function hasAuthSession(): boolean {
  return readServerUrl().length > 0 && readAccessToken().length > 0;
}

export function saveServerUrl(serverUrl: string): void {
  const origin = normalizeServerOrigin(serverUrl);
  if (origin === null) {
    throw new Error('服务器地址必须是 http(s) origin。');
  }
  authStore.write(KEY_SERVER_URL, origin);
}

export interface SavedAuthSession {
  serverUrl: string;
  accessToken: string;
  tokenType: string;
  userId: string;
  role: string;
  displayName: string;
  email: string;
  refreshToken: string;
  refreshExpiresAt: string;
}

export function saveAuthSession(session: SavedAuthSession): void {
  const origin = normalizeServerOrigin(session.serverUrl);
  if (origin === null) {
    throw new Error('服务器地址必须是 http(s) origin。');
  }
  authStore.write(KEY_SERVER_URL, origin);
  authStore.write(KEY_ACCESS_TOKEN, session.accessToken);
  authStore.write(KEY_TOKEN_TYPE, session.tokenType);
  authStore.write(KEY_USER_ID, session.userId);
  authStore.write(KEY_ROLE, session.role);
  authStore.write(KEY_DISPLAY_NAME, session.displayName);
  authStore.write(KEY_EMAIL, session.email);
  authStore.write(KEY_REFRESH_TOKEN, session.refreshToken);
  authStore.write(KEY_REFRESH_EXPIRES_AT, session.refreshExpiresAt);
}

/** 只更新资料字段（改昵称/绑邮箱后调用）。 */
export function updateProfileFields(displayName: string, email: string): void {
  authStore.write(KEY_DISPLAY_NAME, displayName);
  authStore.write(KEY_EMAIL, email);
}

/** 清登录态但保留 server_url（与 Android `clearAuthSessionKeepingServerUrl` 一致）。 */
export function clearAuthSession(): void {
  const serverUrl = readServerUrl();
  authStore.clear();
  if (serverUrl.length > 0) {
    authStore.write(KEY_SERVER_URL, serverUrl);
  }
}

/**
 * 只有当前 token 与 401 回调带回来的 token 相同才清（避免并发请求把新登录态清掉）。
 * 返回是否真的清了。
 */
export function clearAuthSessionIfTokenMatches(unauthorizedAccessToken: string): boolean {
  if (unauthorizedAccessToken.length === 0) {
    return false;
  }
  if (readAccessToken() !== unauthorizedAccessToken) {
    return false;
  }
  clearAuthSession();
  return true;
}

/** 实时连接 id：首次生成后长期复用（对应 `RealtimeClientIdStore.readOrCreate`）。 */
export function readOrCreateRealtimeClientId(create: () => string): string {
  const existing = realtimeStore.read(KEY_CLIENT_ID, '');
  if (existing.length > 0) {
    return existing;
  }
  const created = create();
  realtimeStore.write(KEY_CLIENT_ID, created);
  return created;
}

export function readAppearanceMode(): string {
  const value = authStore.read(KEY_APPEARANCE, APPEARANCE_SYSTEM);
  if (value === APPEARANCE_LIGHT || value === APPEARANCE_DARK || value === APPEARANCE_SYSTEM) {
    return value;
  }
  return APPEARANCE_SYSTEM;
}

export function saveAppearanceMode(mode: string): void {
  authStore.write(KEY_APPEARANCE, mode);
}
