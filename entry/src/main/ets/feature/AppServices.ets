/**
 * 应用级单例与认证控制器。
 *
 * 对应 Android 的 `app/AgentsAnywhereApp.kt` 组装逻辑 + `feature/auth/AuthController.kt`。
 * ArkTS 里没有 DI 容器，用模块级单例最省事，也方便页面直接取用。
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ApiClient } from '../api/ApiClient';
import { AuthApi } from '../api/AuthApi';
import { DevicesApi } from '../api/DevicesApi';
import { FilesApi } from '../api/FilesApi';
import { SessionsApi } from '../api/SessionsApi';
import { TerminalApi } from '../api/TerminalApi';
import { RealtimeApi, newRealtimeClientId } from '../api/RealtimeApi';
import { normalizeServerOrigin } from '../api/ApiUrls';
import {
  APPEARANCE_DARK, APPEARANCE_LIGHT, APPEARANCE_SYSTEM, SavedAuthSession, clearAuthSession,
  clearAuthSessionIfTokenMatches, hasAuthSession, initAppPrefs, readAccessToken, readAppearanceMode,
  readDisplayName, readEmail, readOrCreateRealtimeClientId, readRole, readServerUrl, readUserId,
  saveAppearanceMode, saveAuthSession, saveServerUrl, updateProfileFields
} from '../store/AuthSessionStore';
import { AuthConfigResponse, AuthMeResponse, MobileLoginExchangeResponse, MobileLoginStatusResponse } from '../model/Types';
import { Raw, optString, str } from '../api/Parse';

export const OFFICIAL_SERVER_URL: string = 'https://web.agents-anywhere.com';

export class AppServices {
  private static instance?: AppServices;

  readonly client: ApiClient;
  readonly auth: AuthApi;
  readonly devices: DevicesApi;
  readonly files: FilesApi;
  readonly sessions: SessionsApi;
  readonly terminal: TerminalApi;
  readonly realtime: RealtimeApi;
  realtimeClientId: string = '';

  private constructor() {
    this.client = new ApiClient((token: string) => {
      // 401：只有当前 token 与回调 token 一致才清（避免并发请求互相覆盖）
      if (clearAuthSessionIfTokenMatches(token)) {
        authController.markSignedOut('登录已失效，请重新登录。');
      }
    });
    this.auth = new AuthApi(this.client);
    this.devices = new DevicesApi(this.client);
    this.files = new FilesApi(this.client);
    this.sessions = new SessionsApi(this.client);
    this.terminal = new TerminalApi(this.client);
    this.realtime = new RealtimeApi(this.client);
    this.realtimeClientId = readOrCreateRealtimeClientId(() => newRealtimeClientId());
  }

  static get(): AppServices {
    if (AppServices.instance === undefined) {
      AppServices.instance = new AppServices();
    }
    return AppServices.instance;
  }

  /** 用 EntryAbility 的 context 初始化 preferences（幂等）。 */
  init(context: common.Context): void {
    initAppPrefs(context);
    // R13：EntryAbility 现在会静态 import 本模块（为了外观下发 setColorMode），模块求值因此提前到
    // `onCreate` 的 initAppPrefs 之前 —— 本单例可能在被 `get()` 构造时 preferences 还没打开，
    // 那种情况下构造函数读到的实时连接 id 是空值、落盘也被静默跳过（每次冷启都会换一个 id）。
    // 这里在 preferences 打开后补读一次：有值就复用，没有就当场生成并落盘。
    this.realtimeClientId = readOrCreateRealtimeClientId(() => newRealtimeClientId());
  }
}

export enum AuthStage {
  NEED_SERVER = 'need_server',
  NEED_LOGIN = 'need_login',
  SIGNED_IN = 'signed_in'
}

export interface AuthSnapshot {
  stage: AuthStage;
  serverUrl: string;
  displayName: string;
  email: string;
  userId: string;
  role: string;
  needsBootstrap: boolean;
  registrationOpen: boolean;
  oauthEnabled: boolean;
  oauthProviderLabel: string;
  loading: boolean;
  error: string;
  notice: string;
}

/** 认证控制器：服务器校验 → 登录（密码 / 扫码 / 网页）→ 会话落盘。 */
export class AuthController {
  private listeners: Array<() => void> = [];
  private snapshot: AuthSnapshot = {
    stage: AuthStage.NEED_SERVER,
    serverUrl: '',
    displayName: '',
    email: '',
    userId: '',
    role: '',
    needsBootstrap: false,
    registrationOpen: false,
    oauthEnabled: false,
    oauthProviderLabel: '',
    loading: false,
    error: '',
    notice: ''
  };
  private config?: AuthConfigResponse;

  constructor() {
    this.reloadFromStorage();
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  get current(): AuthSnapshot {
    return this.snapshot;
  }

  get authConfig(): AuthConfigResponse | undefined {
    return this.config;
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  private patch(changes: Partial<AuthSnapshot>): void {
    const next: AuthSnapshot = {
      stage: changes.stage !== undefined ? changes.stage : this.snapshot.stage,
      serverUrl: changes.serverUrl !== undefined ? changes.serverUrl : this.snapshot.serverUrl,
      displayName: changes.displayName !== undefined ? changes.displayName : this.snapshot.displayName,
      email: changes.email !== undefined ? changes.email : this.snapshot.email,
      userId: changes.userId !== undefined ? changes.userId : this.snapshot.userId,
      role: changes.role !== undefined ? changes.role : this.snapshot.role,
      needsBootstrap: changes.needsBootstrap !== undefined ? changes.needsBootstrap : this.snapshot.needsBootstrap,
      registrationOpen: changes.registrationOpen !== undefined ? changes.registrationOpen : this.snapshot.registrationOpen,
      oauthEnabled: changes.oauthEnabled !== undefined ? changes.oauthEnabled : this.snapshot.oauthEnabled,
      oauthProviderLabel: changes.oauthProviderLabel !== undefined
        ? changes.oauthProviderLabel : this.snapshot.oauthProviderLabel,
      loading: changes.loading !== undefined ? changes.loading : this.snapshot.loading,
      error: changes.error !== undefined ? changes.error : this.snapshot.error,
      notice: changes.notice !== undefined ? changes.notice : this.snapshot.notice
    };
    this.snapshot = next;
    this.notify();
  }

  reloadFromStorage(): void {
    const serverUrl = readServerUrl();
    if (serverUrl.length === 0) {
      this.patch({ stage: AuthStage.NEED_SERVER, serverUrl: '' });
      return;
    }
    if (!hasAuthSession()) {
      this.patch({ stage: AuthStage.NEED_LOGIN, serverUrl: serverUrl });
      return;
    }
    this.patch({
      stage: AuthStage.SIGNED_IN,
      serverUrl: serverUrl,
      displayName: readDisplayName(),
      email: readEmail(),
      userId: readUserId(),
      role: readRole()
    });
  }

  /** 清掉错误提示（界面关掉错误条时调用）。 */
  clearError(): void {
    this.patch({ error: '' });
  }

  markSignedOut(message: string): void {
    this.patch({
      stage: AuthStage.NEED_LOGIN,
      error: message,
      displayName: '',
      email: '',
      userId: '',
      role: ''
    });
  }

  /** 设置服务器地址：校验 origin + `/health` + `/auth/config`。 */
  async connectServer(serverInput: string): Promise<boolean> {
    const origin = normalizeServerOrigin(serverInput);
    if (origin === null) {
      this.patch({ error: '请输入合法的服务器地址（http/https）。' });
      return false;
    }
    this.patch({ loading: true, error: '', notice: '' });
    try {
      await AppServices.get().auth.requireHealthyServer(origin);
      const config = await AppServices.get().auth.authConfig(origin);
      this.config = config;
      saveServerUrl(origin);
      this.patch({
        stage: AuthStage.NEED_LOGIN,
        serverUrl: origin,
        needsBootstrap: config.needsBootstrap,
        registrationOpen: config.registrationOpen,
        oauthEnabled: config.oauthEnabled,
        oauthProviderLabel: config.oauthProviderLabel !== undefined ? config.oauthProviderLabel : '',
        loading: false
      });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ loading: false, error: message });
      return false;
    }
  }

  /** 密码登录（服务端 `/auth/login`）。 */
  async loginWithPassword(email: string, password: string): Promise<boolean> {
    const serverUrl = this.snapshot.serverUrl;
    if (serverUrl.length === 0) {
      this.patch({ error: '请先设置服务器地址。' });
      return false;
    }
    this.patch({ loading: true, error: '' });
    try {
      const auth = await AppServices.get().auth.login(serverUrl, email, password);
      this.persistAuth(serverUrl, auth.accessToken, auth.tokenType, auth.userId, auth.role,
        auth.displayName !== undefined ? auth.displayName : '', auth.email !== undefined ? auth.email : '', '', '');
      this.patch({
        stage: AuthStage.SIGNED_IN,
        loading: false,
        userId: auth.userId,
        role: auth.role,
        displayName: auth.displayName !== undefined ? auth.displayName : '',
        email: auth.email !== undefined ? auth.email : ''
      });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ loading: false, error: message });
      return false;
    }
  }

  /** 注册（服务端 `/auth/register`，仅在 registrationOpen 时可用）。 */
  async register(email: string, password: string, displayName: string): Promise<boolean> {
    const serverUrl = this.snapshot.serverUrl;
    this.patch({ loading: true, error: '' });
    try {
      const auth = await AppServices.get().auth.register(serverUrl, email, password, displayName);
      this.persistAuth(serverUrl, auth.accessToken, auth.tokenType, auth.userId, auth.role,
        auth.displayName !== undefined ? auth.displayName : displayName,
        auth.email !== undefined ? auth.email : email, '', '');
      this.patch({
        stage: AuthStage.SIGNED_IN,
        loading: false,
        userId: auth.userId,
        role: auth.role,
        displayName: auth.displayName !== undefined ? auth.displayName : displayName,
        email: auth.email !== undefined ? auth.email : email
      });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ loading: false, error: message });
      return false;
    }
  }

  /** 扫码登录第 1 步 + 轮询 + 兑换；`onStatus` 用于界面显示进度。 */
  async completeQrLogin(
    userId: string, loginToken: string, deviceName: string, onStatus: (status: string) => void
  ): Promise<boolean> {
    const serverUrl = this.snapshot.serverUrl;
    if (serverUrl.length === 0) {
      this.patch({ error: '请先设置服务器地址。' });
      return false;
    }
    this.patch({ loading: true, error: '' });
    try {
      let status = await AppServices.get().auth.requestMobileLogin(serverUrl, userId, loginToken, deviceName);
      onStatus(status.status);
      let attempts = 0;
      while (status.status !== 'approved' && attempts < 120) {
        if (status.status === 'expired' || status.status === 'denied') {
          this.patch({ loading: false, error: '二维码已失效或被拒绝，请在网页端重新生成。' });
          return false;
        }
        await sleep(1500);
        status = await AppServices.get().auth.mobileLoginStatus(serverUrl, loginToken);
        onStatus(status.status);
        attempts += 1;
      }
      if (status.status !== 'approved') {
        this.patch({ loading: false, error: '等待确认超时，请重试。' });
        return false;
      }
      const exchange = await AppServices.get().auth.exchangeMobileLogin(serverUrl, userId, loginToken);
      this.applyExchange(serverUrl, exchange);
      this.patch({ stage: AuthStage.SIGNED_IN, loading: false, notice: '扫码登录成功。' });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ loading: false, error: message });
      return false;
    }
  }

  /** OAuth 授权码 → token（网页登录回调后调用）。 */
  async completeWebLogin(code: string, codeVerifier: string): Promise<boolean> {
    const serverUrl = this.snapshot.serverUrl;
    this.patch({ loading: true, error: '' });
    try {
      const token = await AppServices.get().auth.oauthToken(serverUrl, code, codeVerifier);
      const me = await AppServices.get().auth.me(serverUrl, token.access_token);
      this.persistAuth(serverUrl, token.access_token, token.token_type !== undefined ? token.token_type : 'Bearer',
        me.userId, me.role, me.displayName !== undefined ? me.displayName : '',
        me.email !== undefined ? me.email : '',
        token.refresh_token !== undefined ? token.refresh_token : '', '');
      this.patch({
        stage: AuthStage.SIGNED_IN,
        loading: false,
        userId: me.userId,
        role: me.role,
        displayName: me.displayName !== undefined ? me.displayName : '',
        email: me.email !== undefined ? me.email : ''
      });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ loading: false, error: message });
      return false;
    }
  }

  private applyExchange(serverUrl: string, exchange: MobileLoginExchangeResponse): void {
    this.persistAuth(serverUrl, exchange.auth.accessToken, exchange.auth.tokenType, exchange.auth.userId,
      exchange.auth.role,
      exchange.auth.displayName !== undefined ? exchange.auth.displayName : '',
      exchange.auth.email !== undefined ? exchange.auth.email : '',
      exchange.refreshToken, exchange.expiresAt);
    this.patch({
      userId: exchange.auth.userId,
      role: exchange.auth.role,
      displayName: exchange.auth.displayName !== undefined ? exchange.auth.displayName : '',
      email: exchange.auth.email !== undefined ? exchange.auth.email : ''
    });
  }

  private persistAuth(
    serverUrl: string, accessToken: string, tokenType: string, userId: string, role: string,
    displayName: string, email: string, refreshToken: string, refreshExpiresAt: string
  ): void {
    const session: SavedAuthSession = {
      serverUrl: serverUrl,
      accessToken: accessToken,
      tokenType: tokenType,
      userId: userId,
      role: role,
      displayName: displayName,
      email: email,
      refreshToken: refreshToken,
      refreshExpiresAt: refreshExpiresAt
    };
    saveAuthSession(session);
  }

  /** 拉取 `/auth/me` 刷新资料；401 会由 ApiClient 回调清登录态。 */
  async refreshMe(): Promise<void> {
    const serverUrl = this.snapshot.serverUrl;
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      return;
    }
    try {
      const me = await AppServices.get().auth.me(serverUrl, token);
      updateProfileFields(me.displayName !== undefined ? me.displayName : '',
        me.email !== undefined ? me.email : '');
      this.patch({
        displayName: me.displayName !== undefined ? me.displayName : '',
        email: me.email !== undefined ? me.email : '',
        userId: me.userId,
        role: me.role
      });
    } catch (error) {
      // 网络异常不改变登录态
    }
  }

  async updateDisplayName(displayName: string): Promise<boolean> {
    const serverUrl = this.snapshot.serverUrl;
    const token = readAccessToken();
    try {
      const me = await AppServices.get().auth.updateDisplayName(serverUrl, token, displayName);
      updateProfileFields(me.displayName !== undefined ? me.displayName : '',
        me.email !== undefined ? me.email : '');
      this.patch({ displayName: me.displayName !== undefined ? me.displayName : '', notice: '昵称已更新。' });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ error: message });
      return false;
    }
  }

  async changePassword(newPassword: string): Promise<boolean> {
    try {
      await AppServices.get().auth.changePassword(this.snapshot.serverUrl, readAccessToken(), newPassword);
      this.patch({ notice: '密码已修改。', error: '' });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ error: message });
      return false;
    }
  }

  async bindEmail(email: string, code: string): Promise<boolean> {
    try {
      const me = await AppServices.get().auth.bindEmail(this.snapshot.serverUrl, readAccessToken(), email, code);
      updateProfileFields(me.displayName !== undefined ? me.displayName : '',
        me.email !== undefined ? me.email : '');
      this.patch({ email: me.email !== undefined ? me.email : '', notice: '邮箱已绑定。', error: '' });
      return true;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ error: message });
      return false;
    }
  }

  async sendEmailCode(email: string): Promise<number> {
    try {
      const response = await AppServices.get().auth.sendEmailCode(
        this.snapshot.serverUrl, readAccessToken(), email);
      return response.retryAfter;
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.patch({ error: message });
      return -1;
    }
  }

  /** 退出登录：清 token 但保留 server_url。 */
  logout(): void {
    clearAuthSession();
    this.config = undefined;
    this.patch({
      stage: AuthStage.NEED_LOGIN,
      displayName: '',
      email: '',
      userId: '',
      role: '',
      notice: '已退出登录。',
      error: ''
    });
  }

  /** 切换服务器（清空当前登录态，回到地址输入）。 */
  switchServer(): void {
    clearAuthSession();
    this.config = undefined;
    this.patch({ stage: AuthStage.NEED_SERVER, serverUrl: '', displayName: '', email: '', userId: '', role: '' });
  }
}

export interface QrPayload {
  serverUrl: string;
  userId: string;
  loginToken: string;
  expiresAt?: string;
}

/**
 * 解析网页端展示的登录二维码内容：
 * `{"type":"agents-anywhere.mobile-login","serverUrl"|"webUrl":...,"userId":...,"loginToken":...}`
 */
export function parseMobileLoginQr(qrValue: string): QrPayload | undefined {
  try {
    const raw = JSON.parse(qrValue) as Raw;
    if (str(raw, 'type', '') !== 'agents-anywhere.mobile-login') {
      return undefined;
    }
    const serverUrlRaw = optString(raw, 'serverUrl') ?? optString(raw, 'webUrl') ?? '';
    const serverUrl = normalizeServerOrigin(serverUrlRaw);
    const userId = optString(raw, 'userId');
    const loginToken = optString(raw, 'loginToken');
    if (serverUrl === null || userId === undefined || loginToken === undefined) {
      return undefined;
    }
    return { serverUrl: serverUrl, userId: userId, loginToken: loginToken, expiresAt: optString(raw, 'expiresAt') };
  } catch (error) {
    return undefined;
  }
}

/**
 * 外观模式（system/light/dark）：内存值 + 持久化 + **下发系统 colorMode** + 监听者广播。
 *
 * ⚠️ R13 修复（P0，依据 R12 真机复核）：设置页选「深色」时只有那一行的文案变，**整机仍按浅色渲染**。
 * 两条根因都在本类与下面的 `isDarkAppearance()` 里，均已修：
 *  ① `set()` 改前只做「改内存 + 落盘 + 通知」，**从未调用系统的深色模式 API** —— 鸿蒙的深浅色由
 *  「应用级 colorMode」决定，不下发就永远停在默认浅色；
 *  ② `isDarkAppearance()` 的 system 分支硬编码 `return false`，跟随系统时也永远按浅色。
 *
 * 现在的链路（详见 开发期验证记录）：
 *  用户点选 → `set(mode)` → `apply()` → `ApplicationContext.setColorMode(appearanceColorMode(mode))`
 *  → 系统切换本应用 colorMode → `EntryAbility.onConfigurationUpdate` → `syncSystemColorMode()` 广播。
 * 本工程界面颜色**全部**走 `$r('app.color.*')`，且 `resources/dark/element/color.json` 有全套深色值，
 * 所以 colorMode 一改、资源限定目录自动切换 ⇒ 整机界面跟着翻，无需逐页改颜色。
 */
export class AppearanceController {
  private static listeners: Array<() => void> = [];
  private static mode: string = APPEARANCE_SYSTEM;
  /**
   * EntryAbility 注册进来的 Ability 上下文 —— **唯一**能拿到 ApplicationContext 的入口。
   * 不注册只会退化成「切外观不下发」（界面仍按默认浅色），不会崩：下面所有调用都容错。
   */
  private static abilityContext?: common.UIAbilityContext;
  /** 系统最近一次上报的深浅色（由 `onConfigurationUpdate` 的**推送**维护）。 */
  private static systemDark: boolean = false;
  /**
   * 是否**收到过权威推送**（R90-T3）。
   *
   * ⚠️ 为什么需要这个标志：真机回读日志抓到了**两个来源互相矛盾**的一帧 ——
   * ```
   * 13:02:11.639 systemBar dark=false icon=#E5000000 | mode=system ctxColorMode=1 cachedDark=true -> dark=false
   * 13:02:11.640 systemBar dark=true icon=#E5FFFFFF | mode=system ctxColorMode=0 cachedDark=true -> dark=true
   * ```
   * 系统此刻是**深色**（推送已报 dark，cachedDark=true），但 `context.config.colorMode` 还停在
   * **1=浅色**（它**滞后推送约 1ms**）⇒ 旧代码"优先信 context"就画出**深色图标**，
   * 落在深色画布上**一片看不见**（用户截图实测：图标区 max=17、背景 6.3）。
   * 1ms 后 context 才追上把它纠正 —— **只要那次纠正没有第二次触发，就永久错**。
   * ⇒ 规则：**推送值优先**（它是系统主动给的、且及时）；`context.config` 只在
   * "还没收到过任何推送"时用来兜底（冷启动首帧）。
   */
  private static systemDarkKnown: boolean = false;

  /** 注册上下文（`EntryAbility.onCreate` 调用一次，紧随 `initAppPrefs`）。 */
  static attach(context: common.UIAbilityContext): void {
    AppearanceController.abilityContext = context;
    // ⚠️ R90-T3：此刻 `context.config.colorMode` 可能还没定下来（NOT_SET）⇒ 读出来是"未知"。
    //  若在未知时强行覆写缓存，等于把"未知"钉成 false（= 浅色）——深色系统下正是这个坑。
    //  只在拿到**具体**值时更新缓存；未知就保留 onConfigurationUpdate 维护的值。
    // ⚠️ 这里**不**置 systemDarkKnown：attach 只是"注册上下文"，还没收到系统推送，
    //  仍属于"兜底阶段"。等 onConfigurationUpdate 来了才算权威。
    let resolved: boolean | undefined;
    try {
      const mode = context.config.colorMode;
      if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        resolved = true;
      } else if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        resolved = false;
      }
    } catch (error) {
      resolved = undefined;
    }
    if (resolved !== undefined) {
      AppearanceController.systemDark = resolved;
    }
  }

  /**
   * 冷启动：**先**读持久化值，**再**立刻下发一次。
   * 顺序不能反 —— 反了就是把默认的 system 下发下去，用户会看到「设置没保住」。
   * 返回是否下发成功（未注册 context 或系统拒绝时为 false）。
   */
  static init(): boolean {
    AppearanceController.mode = readAppearanceMode();
    // ⚠️ R90-T3：**不要**在这里无条件覆写 `systemDark`。冷启时 `context.config.colorMode`
    //  可能还是 `COLOR_MODE_NOT_SET(-1)`，而旧写法把它当"非深色" ⇒ 深色系统被判成浅色
    //  ⇒ 状态栏画深色图标、落在深色画布上**看不见**（用户报的正是这个）。
    //  `readContextDark()` 现在对"未知"会**回退到缓存**，所以这里直接取即可；
    //  真正的权威值由 `onConfigurationUpdate` 上报后覆盖。
    AppearanceController.systemDark = AppearanceController.readContextDark();
    return AppearanceController.apply();
  }

  static get current(): string {
    return AppearanceController.mode;
  }

  /** 选外观：落盘 → 下发系统 → 通知监听者（三步固定顺序）。 */
  static set(mode: string): void {
    AppearanceController.mode = mode;
    saveAppearanceMode(mode);
    AppearanceController.apply();
    AppearanceController.notify();
  }

  /**
   * 把当前模式下发到系统（幂等，可重复调用）。
   *
   * 调用时机有两处，缺一不可：
   *  · `EntryAbility.onCreate`（`init()` 内）—— 冷启动尽早生效；
   *  · `EntryAbility.onWindowStageCreate` 的 `loadContent` 回调 —— SDK 注明 `setColorMode`
   *  要求「窗口已创建且页面已加载」，早于该时机的调用只能算尽力而为。
   * 返回是否真的下发成功（失败只影响观感，界面继续按既有资源渲染）。
   */
  static apply(): boolean {
    const context = AppearanceController.abilityContext;
    if (context === undefined) {
      return false;
    }
    try {
      context.getApplicationContext().setColorMode(appearanceColorMode(AppearanceController.mode));
      return true;
    } catch (error) {
      return false;
    }
  }

  /**
   * 系统深浅色变化（`EntryAbility.onConfigurationUpdate` → 这里）。
   *
   * 「跟随系统」时按钮文案不变，但按 `isDarkAppearance()` 取过色的页面必须重渲染，
   * 所以变化时广播一次。返回是否真的变了（调用方据此决定要不要打日志）。
   */
  static syncSystemColorMode(colorMode: ConfigurationConstant.ColorMode): boolean {
    const dark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const changed = dark !== AppearanceController.systemDark;
    AppearanceController.systemDark = dark;
    // ⚠️ R90-T3：从此以后 `context.config` 只是兜底 —— 它会在切换瞬间滞后（见字段注释）。
    AppearanceController.systemDarkKnown = true;
    if (changed) {
      AppearanceController.notify();
    }
    return changed;
  }

  /** 系统当前是否深色（现读 `context.config`，system 分支的权威值）。 */
  static get systemIsDark(): boolean {
    return AppearanceController.readContextDark();
  }

  /**
   * 诊断用只读探针（R90-T3）：把「判定输入」原样吐出来，供 hilog 做**效果回读**。
   *
   * 为什么需要：状态栏图标色由**框架**画，"代码里设了"不等于"设备上生效"
   * （坑 81/82 同款教训）。把 mode / context.config.colorMode / 缓存 / 最终判定一起打出来，
   * 才能定位错在哪一环。
   */
  static describe(): string {
    const context = AppearanceController.abilityContext;
    let raw: string = 'n/a';
    if (context !== undefined) {
      try {
        raw = String(context.config.colorMode);
      } catch (error) {
        raw = 'throw';
      }
    }
    return 'mode=' + AppearanceController.mode + ' ctxColorMode=' + raw
      + ' pushedDark=' + (AppearanceController.systemDarkKnown ? String(AppearanceController.systemDark) : 'unknown')
      + ' -> dark=' + String(AppearanceController.readContextDark());
  }

  static onChange(listener: () => void): void {
    AppearanceController.listeners.push(listener);
  }

  /** 与其它 store 对称：组件销毁时必须能摘掉监听，否则静态数组只增不减。 */
  static offChange(listener: () => void): void {
    const index = AppearanceController.listeners.indexOf(listener);
    if (index >= 0) {
      AppearanceController.listeners.splice(index, 1);
    }
  }

  /**
   * 系统当前是否深色。
   *
   * ⚠️ **R90-T3 修正（用户：「时间栏内容没有适配深浅色模式，根本看不见信息」）**：
   * 旧写法是 `return context.config.colorMode === COLOR_MODE_DARK;` ——
   * 一旦 `context.config.colorMode` 取到 `COLOR_MODE_NOT_SET(-1)`，
   * `-1 === 0` 为 **false** ⇒ **深色被判成浅色** ⇒ 状态栏画**深色图标**，
   * 落在深色画布上就是**一片看不见**（用户截图实测：图标区 max=17、背景 6.3）。
   * ⇒ 现在**只有拿到具体值才采信**，`NOT_SET` / 读不到一律退回
   * `onConfigurationUpdate` 维护的缓存 `systemDark`（不再默认成浅色）。
   */
  private static readContextDark(): boolean {
    // ① 收到过权威推送 ⇒ **以推送为准**。context 在深浅切换瞬间会滞后约 1ms，
    //  真机实测它会报告与推送**相反**的值（见 systemDarkKnown 的日志）。
    if (AppearanceController.systemDarkKnown) {
      return AppearanceController.systemDark;
    }
    // ② 还没收到过推送（冷启动首帧）⇒ 用 context 兜底，但只采信**具体值**：
    //  COLOR_MODE_NOT_SET(-1) 表示"未设置/跟随系统"，**不许**当浅色。
    const context = AppearanceController.abilityContext;
    if (context !== undefined) {
      try {
        const mode = context.config.colorMode;
        if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
          return true;
        }
        if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
          return false;
        }
      } catch (error) {
        // 读不到就用下面的初值
      }
    }
    return AppearanceController.systemDark;
  }

  private static notify(): void {
    for (let i = 0; i < AppearanceController.listeners.length; i++) {
      AppearanceController.listeners[i]();
    }
  }
}

/**
 * 外观模式 → 系统 ColorMode（纯映射，自测直接断言；跟随系统 = `COLOR_MODE_NOT_SET`）。
 * 脏值一律按「跟随系统」处理，与 `readAppearanceMode()` 的归一化口径一致。
 */
export function appearanceColorMode(mode: string): ConfigurationConstant.ColorMode {
  if (mode === APPEARANCE_DARK) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
  if (mode === APPEARANCE_LIGHT) {
    return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
}

/**
 * 当前是否按深色渲染（system 分支**不再恒 false** —— R12 P0 根因②）。
 *
 * 跟随系统时以系统当前 colorMode 作答；取不到上下文时退回 `onConfigurationUpdate` 维护的缓存。
 */
export function isDarkAppearance(): boolean {
  const mode = AppearanceController.current;
  if (mode === APPEARANCE_DARK) {
    return true;
  }
  if (mode === APPEARANCE_LIGHT) {
    return false;
  }
  return AppearanceController.systemIsDark;
}

export function sleep(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, milliseconds);
  });
}

/** 全局认证控制器（模块级单例）。 */
export const authController: AuthController = new AuthController();

export { APPEARANCE_DARK, APPEARANCE_LIGHT, APPEARANCE_SYSTEM };
export type { AuthConfigResponse, AuthMeResponse, MobileLoginStatusResponse };
