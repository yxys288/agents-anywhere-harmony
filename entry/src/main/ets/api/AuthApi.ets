/**
 * 认证 API（对应 Android `api/Auth.kt`）。
 *
 * 支持三条登录路径：密码登录、OAuth(PKCE) 网页登录、扫码（mobile-login）登录。
 */

import { ApiClient } from './ApiClient';
import {
  AuthConfigResponse, AuthMeResponse, AuthResponse, EmailCodeResponse, MobileLoginExchangeResponse,
  MobileLoginStatusResponse, OAuthTokenResponse
} from '../model/Types';
import { optRaw, optString, Raw, str } from './Parse';

const MOBILE_LOGIN_CLIENT_ID: string = 'agents-anywhere-mobile';
const OAUTH_REDIRECT_URI: string = 'agents-anywhere://oauth/callback';

export class AuthApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async me(serverUrl: string, token: string): Promise<AuthMeResponse> {
    const raw = await this.client.getJson(serverUrl, '/auth/me', token) as Raw;
    return this.toAuthMe(raw);
  }

  async authConfig(serverUrl: string): Promise<AuthConfigResponse> {
    const raw = await this.client.getJson(serverUrl, '/auth/config') as Raw;
    const config: AuthConfigResponse = {
      needsBootstrap: raw['needsBootstrap'] === true,
      registrationOpen: raw['registrationOpen'] === true,
      oauthRegistrationOpen: raw['oauthRegistrationOpen'] === true,
      oauthEnabled: raw['oauthEnabled'] === true,
      oauthProviderLabel: optString(raw, 'oauthProviderLabel'),
      setupTokenExpiresAt: optString(raw, 'setupTokenExpiresAt'),
      serverTime: str(raw, 'serverTime', ''),
      emailVerificationRequired: raw['emailVerificationRequired'] === true
    };
    return config;
  }

  /** `/health` 必须返回 `status: ok`，否则视为不是 Agents Anywhere 服务器。 */
  async requireHealthyServer(serverUrl: string): Promise<void> {
    const raw = await this.client.getJson(serverUrl, '/health') as Raw;
    if (str(raw, 'status', '') !== 'ok') {
      throw new Error('该地址返回的不是健康的 Agents Anywhere 服务器。');
    }
  }

  async oauthToken(serverUrl: string, code: string, codeVerifier: string): Promise<OAuthTokenResponse> {
    const fields: Record<string, string> = {
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': MOBILE_LOGIN_CLIENT_ID,
      'redirect_uri': OAUTH_REDIRECT_URI,
      'code_verifier': codeVerifier
    };
    const raw = await this.client.postForm(serverUrl, '/oauth/token', fields) as Raw;
    const token: OAuthTokenResponse = {
      access_token: str(raw, 'access_token', ''),
      token_type: str(raw, 'token_type', 'Bearer'),
      expires_in: typeof raw['expires_in'] === 'number' ? raw['expires_in'] as number : 0,
      scope: optString(raw, 'scope'),
      refresh_token: optString(raw, 'refresh_token')
    };
    return token;
  }

  /** 扫码登录第 1 步：把二维码里的 userId/loginToken 提交给服务器。 */
  async requestMobileLogin(
    serverUrl: string, userId: string, loginToken: string, deviceName?: string
  ): Promise<MobileLoginStatusResponse> {
    const body: Record<string, Object> = { 'userId': userId, 'loginToken': loginToken };
    if (deviceName !== undefined && deviceName.trim().length > 0) {
      body['deviceName'] = deviceName;
    }
    const raw = await this.client.postJson(serverUrl, '/auth/mobile-login/request', body) as Raw;
    return this.toMobileLoginStatus(raw);
  }

  /** 扫码登录第 2 步：轮询审批状态。 */
  async mobileLoginStatus(serverUrl: string, loginToken: string): Promise<MobileLoginStatusResponse> {
    const body: Record<string, Object> = { 'loginToken': loginToken };
    const raw = await this.client.postJson(serverUrl, '/auth/mobile-login/status', body) as Raw;
    return this.toMobileLoginStatus(raw);
  }

  /** 扫码登录第 3 步：审批通过后换取长期 accessToken / refreshToken。 */
  async exchangeMobileLogin(
    serverUrl: string, userId: string, loginToken: string
  ): Promise<MobileLoginExchangeResponse> {
    const body: Record<string, Object> = { 'userId': userId, 'loginToken': loginToken };
    const raw = await this.client.postJson(serverUrl, '/auth/mobile-login/exchange', body) as Raw;
    const authRaw = optRaw(raw, 'auth') ?? {};
    const result: MobileLoginExchangeResponse = {
      auth: this.toAuth(authRaw),
      refreshToken: str(raw, 'refreshToken', ''),
      expiresAt: str(raw, 'expiresAt', ''),
      serverTime: str(raw, 'serverTime', '')
    };
    return result;
  }

  async updateDisplayName(serverUrl: string, token: string, displayName: string): Promise<AuthMeResponse> {
    const body: Record<string, Object> = { 'displayName': displayName.trim() };
    const raw = await this.client.putJson(serverUrl, '/auth/me/profile', body, token) as Raw;
    return this.toAuthMe(raw);
  }

  async sendEmailCode(serverUrl: string, token: string, email: string): Promise<EmailCodeResponse> {
    const body: Record<string, Object> = { 'email': email.trim(), 'purpose': 'bind' };
    const raw = await this.client.postJson(serverUrl, '/auth/email-code', body, token) as Raw;
    const result: EmailCodeResponse = {
      expiresIn: typeof raw['expiresIn'] === 'number' ? raw['expiresIn'] as number : 0,
      retryAfter: typeof raw['retryAfter'] === 'number' ? raw['retryAfter'] as number : 0
    };
    return result;
  }

  async bindEmail(serverUrl: string, token: string, email: string, code?: string): Promise<AuthMeResponse> {
    const body: Record<string, Object> = { 'email': email.trim() };
    if (code !== undefined && code.trim().length > 0) {
      body['code'] = code.trim();
    }
    const raw = await this.client.putJson(serverUrl, '/auth/me/email', body, token) as Raw;
    return this.toAuthMe(raw);
  }

  async changePassword(serverUrl: string, token: string, newPassword: string): Promise<void> {
    const body: Record<string, Object> = { 'newPassword': newPassword };
    await this.client.postJson(serverUrl, '/auth/change-password', body, token);
  }

  async login(serverUrl: string, email: string, password: string): Promise<AuthResponse> {
    const body: Record<string, Object> = { 'email': email.trim(), 'password': password };
    const raw = await this.client.postJson(serverUrl, '/auth/login', body) as Raw;
    return this.toAuth(raw);
  }

  async register(
    serverUrl: string, email: string, password: string, displayName?: string
  ): Promise<AuthResponse> {
    const body: Record<string, Object> = { 'email': email.trim(), 'password': password };
    if (displayName !== undefined && displayName.trim().length > 0) {
      body['displayName'] = displayName.trim();
    }
    const raw = await this.client.postJson(serverUrl, '/auth/register', body) as Raw;
    return this.toAuth(raw);
  }

  toAuth(raw: Raw): AuthResponse {
    const auth: AuthResponse = {
      userId: str(raw, 'userId', ''),
      role: str(raw, 'role', ''),
      accessToken: str(raw, 'accessToken', ''),
      tokenType: str(raw, 'tokenType', 'bearer'),
      serverTime: str(raw, 'serverTime', ''),
      email: optString(raw, 'email'),
      displayName: str(raw, 'displayName', ''),
      emailVerified: raw['emailVerified'] === true
    };
    return auth;
  }

  toAuthMe(raw: Raw): AuthMeResponse {
    const me: AuthMeResponse = {
      userId: str(raw, 'userId', ''),
      role: str(raw, 'role', ''),
      disabled: raw['disabled'] === true,
      avatar: optString(raw, 'avatar'),
      serverTime: str(raw, 'serverTime', ''),
      email: optString(raw, 'email'),
      displayName: str(raw, 'displayName', ''),
      emailVerified: raw['emailVerified'] === true
    };
    return me;
  }

  private toMobileLoginStatus(raw: Raw): MobileLoginStatusResponse {
    const status: MobileLoginStatusResponse = {
      status: str(raw, 'status', ''),
      userId: optString(raw, 'userId'),
      deviceName: optString(raw, 'deviceName'),
      expiresAt: optString(raw, 'expiresAt'),
      requestedAt: optString(raw, 'requestedAt'),
      approvedAt: optString(raw, 'approvedAt'),
      serverTime: str(raw, 'serverTime', '')
    };
    return status;
  }
}

/** accountLabel：displayName 优先，其次 email。 */
export function accountLabel(me: AuthMeResponse): string {
  const displayName = me.displayName !== undefined ? me.displayName.trim() : '';
  if (displayName.length > 0) {
    return displayName;
  }
  return me.email !== undefined ? me.email : '';
}
