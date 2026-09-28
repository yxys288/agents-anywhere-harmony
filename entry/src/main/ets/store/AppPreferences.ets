/**
 * 设置页的本地偏好与展示用纯逻辑。
 *
 * 上游对应：
 *  - `ui/screens/home/HomeSidebarViewMode.kt`（侧边栏显示：project / session）
 *  - `ui/designsystem/Theme.kt` 里的 `AALanguageMode`（system / en / zh-CN）
 *  - `ui/screens/profile/ProfileSettingsSupport.kt` 的三个 `labelFor*` 扩展与 `prettyRole`
 *  - `ui/screens/profile/ProfileSettingsDetails.kt` 的 `ProfileAvatar` / `accountLabel`
 *  - `AppConfig.isOfficialServer`（账号行的「官方服务」标签）
 *
 * 为什么单独一个模块：
 *  - **外观**（`appearance_mode`）已有归属（`AppearanceController` + `store/AuthSessionStore`），
 *  本模块**不接管**，只由设置页去读；
 *  - **语言**与**侧边栏显示**是 R9 新增的两个偏好，其中「侧边栏显示」要被**首页**读到
 *  （首页按它决定渲染「项目分组」还是「会话列表」），所以除了落盘还要发布到 `AppStorage`。
 *
 * 刻意的设计取舍（与 `store/ComposerDraftStore.ets` 同款）：本模块**不 import 任何 @kit / ArkUI 模块**，
 * 只用 `AppStorage` / `PersistentStorage` 这两个**全局内置对象**。于是
 * 「归一化 → 写入 AppStorage → 安装持久化」整条链路能在 Node 里直接断言
 * （见 `tools/logic-test/suite-settings.mjs`，测试里把两个全局对象换成假实现）。
 *
 * ⚠️ 为什么不走 `@kit.ArkData` 的 preferences：那需要 `common.Context`，会立刻把本模块
 * 拖出「可在 Node 里断言」的范围（`AuthSessionStore` 就是这个代价）。`PersistentStorage.persistProp`
 * 不需要 context，且与 `@StorageLink` 是官方配套用法 —— 一条链路同时解决「跨页面联动」与「冷启动恢复」。
 */

// ---------------------------------------------------------------------------
// 跨页面联动的 AppStorage 键
// ---------------------------------------------------------------------------

/**
 * 「侧边栏显示」的 AppStorage 键（**首页与本页共用**）。
 *
 * ⚠️ `@StorageLink` 的参数必须是**字符串字面量**，所以首页要写
 * `@StorageLink('aaSidebarView') sidebarView: string = 'project';`；
 * 本常量用于「写入」与「取值比较」，不要直接塞进装饰器。
 */
export const SIDEBAR_VIEW_KEY: string = 'aaSidebarView';

/** 「语言」的 AppStorage 键（同样由 @StorageLink 直读）。 */
export const LANGUAGE_KEY: string = 'aaLanguage';

/**
 * 首页项目分组的「**手动折叠**」集合键（R38 新增，黑名单语义；逗号分隔的字符串）。
 *
 * ⚠️ 必须在这里注册 `PersistentStorage.persistProp` —— 只写 `AppStorage` 是**内存**的。
 * 真机实测（R38）：没注册时「折叠一个项目 → 杀进程重进」会**弹回全部展开**，
 * 因为冷启动读到的 storedCollapsed 是空串，迁移逻辑于是回落到「全部展开」。
 * 这是本键（以及 R38 之前的旧键）从未真正持久化过的既有缺陷，不是新引入的。
 */
export const PROJECT_COLLAPSED_KEY: string = 'aaProjectCollapsed';

/**
 * 新建会话的「上次选择」原文（JSON，形状见 `model/NewSessionPreference`）。R47 新增。
 *
 * 为什么用**一个固定键 + 内部分账号/分作用域**，而不是按账号拼动态键名：
 * `PersistentStorage.persistProp` 只认固定键；动态键名要么每次启动都要重注册、要么得绕开它
 * 直接操作 preferences（`AuthSessionStore` 那套），代价是失去 AppStorage 的即时联动。
 * 这条偏好本身只是个字符串、量级几 KB，固定键最省事。
 */
export const NEW_SESSION_PREF_KEY: string = 'aaNewSessionPref';

/**
 * 「最后打开过的会话 id」（R53 新增）。
 *
 * 用途只有一个：**新对话的默认工作区**。DSH 电脑端的回退链是
 * 「显式指定的工作区 ＞ **当前会话所属工作区** ＞ 最近更新的工作区」
 * （`dsh-client-ui-workspace/lib/client.js:887-901`），本工程此前只有后两级的等价物，
 * 补上这一键之后，第 2 级才成立 —— 用户「刚才在哪个工作区里看会话，新建就回到哪里」。
 *
 * 与侧边栏/语言那几个键同一套机制（`PersistentStorage.persistProp` 托管），
 * 因此杀进程重开后仍然记得（DSH 也是持久化的：`dsh.sessions.current`）。
 */
export const LAST_SESSION_KEY: string = 'aaLastSessionId';

// ---------------------------------------------------------------------------
// 语言（对应 Android `AALanguageMode`）
// ---------------------------------------------------------------------------

export const LANGUAGE_SYSTEM: string = 'system';
export const LANGUAGE_ENGLISH: string = 'en';
export const LANGUAGE_CHINESE: string = 'zh-CN';

/** 归一化：只认三个合法值，其余（空串 / 脏数据 / 旧版本写入）一律回落到「跟随系统」。 */
export function normalizeLanguage(value: string): string {
  if (value === LANGUAGE_CHINESE || value === LANGUAGE_ENGLISH || value === LANGUAGE_SYSTEM) {
    return value;
  }
  return LANGUAGE_SYSTEM;
}

/**
 * 「语言」行右侧的当前值（对应上游 `labelForLanguage`）。
 *
 * ⚠️ 与上游的一处**有意偏差**：上游中文资源包里 `profile_language_follow_system` 的值
 * 本身就是英文 "Follow system"（该条未翻译），这里按中文界面的一致性写作「跟随系统」。
 */
export function languageLabel(value: string): string {
  if (value === LANGUAGE_CHINESE) {
    return '简体中文';
  }
  if (value === LANGUAGE_ENGLISH) {
    return 'English';
  }
  return '跟随系统';
}

// ---------------------------------------------------------------------------
// 侧边栏显示（对应 Android `HomeSidebarViewMode`）
// ---------------------------------------------------------------------------

export const SIDEBAR_VIEW_PROJECT: string = 'project';
export const SIDEBAR_VIEW_SESSION: string = 'session';

/** 归一化：只认 `session`，其余一律回落到「项目视图」（与上游 `HomeSidebarViewMode.normalize` 一致）。 */
export function normalizeSidebarView(value: string): string {
  return value === SIDEBAR_VIEW_SESSION ? SIDEBAR_VIEW_SESSION : SIDEBAR_VIEW_PROJECT;
}

/** 「侧边栏显示」行右侧的当前值（对应上游 `labelForSidebarView`）。 */
export function sidebarViewLabel(value: string): string {
  return value === SIDEBAR_VIEW_SESSION ? '会话视图' : '项目视图';
}

// ---------------------------------------------------------------------------
// 账号行的展示逻辑
// ---------------------------------------------------------------------------

/** 账号显示名（对应上游 `AuthMeResponse.accountLabel`：昵称优先，其次邮箱，都没有时回退「账号」）。 */
export function accountLabel(displayName: string, email: string): string {
  const name = displayName.trim();
  if (name.length > 0) {
    return name;
  }
  const mail = email.trim();
  if (mail.length > 0) {
    return mail;
  }
  return '账号';
}

/** 头像里的首字母（对应上游 `ProfileAvatar`：显示名首字符大写，空则 "A"）。 */
export function avatarLetter(label: string): string {
  const trimmed = label.trim();
  if (trimmed.length === 0) {
    return 'A';
  }
  return trimmed.substring(0, 1).toUpperCase();
}

/** 官方 Cloud 的 origin（与 `model/AppConfig.ets` 的 `OFFICIAL_SERVER` 同值）。 */
const OFFICIAL_SERVER_ORIGIN: string = 'https://web.agents-anywhere.com';

/** 是否连的是官方服务（对应上游 `AppConfig.isOfficialServer`，忽略大小写与尾部斜杠）。 */
export function isOfficialServer(serverUrl: string): boolean {
  const normalized = serverUrl.trim().toLowerCase().replace(/\/+$/, '');
  return normalized === OFFICIAL_SERVER_ORIGIN;
}

/** 账号行第二行的服务标签（对应上游 `profile_official_service` / `profile_self_hosted`）。 */
export function serviceLabel(serverUrl: string): string {
  return isOfficialServer(serverUrl) ? '官方服务' : 'Self-host 服务';
}

/** 角色文案（对应上游 `prettyRole`：admin/member 走中文，其余首字母大写）。 */
export function roleLabel(role: string): string {
  const normalized = role.trim().toLowerCase();
  if (normalized === 'admin') {
    return '管理员';
  }
  if (normalized === 'member') {
    return '成员';
  }
  const trimmed = role.trim();
  if (trimmed.length === 0) {
    return '成员';
  }
  return trimmed.substring(0, 1).toUpperCase() + trimmed.substring(1);
}

/** 「版本」行右侧文案（对应上游 `"v${versionName}"`）。 */
export function versionLabel(version: string): string {
  const trimmed = version.trim();
  if (trimmed.length === 0) {
    return '—';
  }
  if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
    return trimmed;
  }
  return 'v' + trimmed;
}

// ---------------------------------------------------------------------------
// 「检查更新」行的状态（对应上游 `AppUpdateUiState` 的简化投影）
// ---------------------------------------------------------------------------

export const UPDATE_IDLE: string = 'idle';
export const UPDATE_CHECKING: string = 'checking';
export const UPDATE_LATEST: string = 'latest';
export const UPDATE_AVAILABLE: string = 'available';
export const UPDATE_FAILED: string = 'failed';

/** 「检查更新」行右侧的状态文案；空串表示「还没检查过」（页面此时显示 `›`）。 */
export function updateStatusLabel(status: string, detail: string): string {
  if (status === UPDATE_CHECKING) {
    return '检查中…';
  }
  if (status === UPDATE_LATEST) {
    return '已是最新';
  }
  if (status === UPDATE_AVAILABLE) {
    return detail.length > 0 ? detail : '有新版本';
  }
  if (status === UPDATE_FAILED) {
    return detail.length > 0 ? detail : '检查失败';
  }
  return '';
}

/** 状态对应的强调色（`''` = 普通灰字；其余由页面映射到颜色资源）。 */
export function updateStatusTone(status: string): string {
  if (status === UPDATE_AVAILABLE) {
    return 'warning';
  }
  if (status === UPDATE_FAILED) {
    return 'error';
  }
  if (status === UPDATE_LATEST) {
    return 'success';
  }
  return '';
}

// ---------------------------------------------------------------------------
// 偏好读写
// ---------------------------------------------------------------------------

/**
 * 两个偏好的读写门面。
 *
 * **AppStorage 是唯一的真相源**：本类不另存内存副本，读就是 `AppStorage.get`、
 * 写就是 `AppStorage.setOrCreate`。这样首页 `@StorageLink('aaSidebarView')` 与本页
 * 天然联动 —— 不存在「两处状态谁同步谁」的问题。
 */
export class AppPreferences {
  private static instance?: AppPreferences;
  /** 已安装持久化（幂等标记）。 */
  private static installed: boolean = false;

  static get(): AppPreferences {
    if (AppPreferences.instance === undefined) {
      AppPreferences.instance = new AppPreferences();
      // 顺手装一次持久化：任何页面第一次拿到门面就完成安装（幂等）
      AppPreferences.instance.install();
    }
    return AppPreferences.instance;
  }

  /**
   * 安装持久化（幂等）：把两个键交给 `PersistentStorage` 托管，应用重启后自动恢复。
   *
   * ⚠️ 顺序要求：`persistProp` 要用**磁盘上的值**作为初值，所以必须在任何
   * `setOrCreate` 之前调用 —— 否则内存里的默认值会把磁盘值顶掉。
   * 安装点有三处（都是幂等的）：模块顶层（import 即安装）、本类 `get()`、设置页 `aboutToAppear`。
   */
  install(): void {
    if (AppPreferences.installed) {
      return;
    }
    try {
      PersistentStorage.persistProp<string>(SIDEBAR_VIEW_KEY, SIDEBAR_VIEW_PROJECT);
      PersistentStorage.persistProp<string>(LANGUAGE_KEY, LANGUAGE_SYSTEM);
      // R38：项目折叠集合也要托管，否则「折叠后杀进程重进」会弹回全部展开（真机实测）。
      PersistentStorage.persistProp<string>(PROJECT_COLLAPSED_KEY, '');
      // R47：新建会话的「上次选择」（空串 = 还没记过）。
      PersistentStorage.persistProp<string>(NEW_SESSION_PREF_KEY, '');
      // R53：最后打开过的会话 id（只用于新对话的默认工作区，空串 = 还没打开过）。
      PersistentStorage.persistProp<string>(LAST_SESSION_KEY, '');
      AppPreferences.installed = true;
    } catch (error) {
      // UI 上下文还没就绪时这里会失败：标记保持 false，留给下一次调用重试。
    }
  }

  /** 当前侧边栏显示模式（脏值自动归一化）。 */
  get sidebarView(): string {
    const value = AppStorage.get<string>(SIDEBAR_VIEW_KEY);
    return normalizeSidebarView(value !== undefined ? value : SIDEBAR_VIEW_PROJECT);
  }

  /**
   * 设置侧边栏显示模式。
   * 写的是 `AppStorage`（首页的 `@StorageLink` 会立刻跟着变），持久化由 `persistProp` 接管。
   */
  setSidebarView(mode: string): void {
    AppStorage.setOrCreate<string>(SIDEBAR_VIEW_KEY, normalizeSidebarView(mode));
  }

  /** 当前语言偏好（脏值自动归一化）。 */
  get language(): string {
    const value = AppStorage.get<string>(LANGUAGE_KEY);
    return normalizeLanguage(value !== undefined ? value : LANGUAGE_SYSTEM);
  }

  setLanguage(mode: string): void {
    AppStorage.setOrCreate<string>(LANGUAGE_KEY, normalizeLanguage(mode));
  }
}

/**
 * 模块顶层安装一次：任何页面 import 本模块（哪怕只是为了拿常量）都会触发，
 * 于是首页在**首次渲染前**就能读到磁盘上恢复出来的「侧边栏显示」。
 * 失败时静默 —— 页面的 `aboutToAppear` 会再调一次（见 `install`）。
 */
AppPreferences.get().install();
