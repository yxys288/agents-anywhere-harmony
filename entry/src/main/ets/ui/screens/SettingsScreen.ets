/**
 * 设置页（对应 Android `ui/screens/profile/ProfileSettingsDrawer.kt` +
 * `ProfileSettingsComponents.kt` + `ProfileSettingsDetails.kt` + `ProfileSettingsSupport.kt`）。
 *
 * 结构按上游 `ProfileDetailPage`，但**只剩两个页面态**：
 *  - **根页**（None）：账号行 → 外观 → 语言 → 侧边栏显示 → Agent 预设 → 版本（版本 + 检查更新）→
 *  已归档会话 → 退出登录；
 *  - **账号子页**（Account）：大头像 + 资料 + 改昵称 / 绑邮箱 / 改密码。
 *  ⚠️ R92-T5（P2 收口）：上游的**第三个**页面态「语言子页」（Language）在本工程**已删除** ——
 *  R63 把「语言」入口改成小窗后 `PAGE_LANGUAGE` 就不可达了，T5 把常量 / `build()` 分发分支 /
 *  `languagePage()` / `titleText()` 分支一起清掉。三选一的**内容**仍在（`languageRows()`），
 *  只是改为由 `languageWindow()` 在小窗里渲染。
 *
 * 与上游的三处**结构差异**（都是 ArkUI 侧的等价选择，详见本轮简报）：
 *  ① 外观与侧边栏显示用**行内展开**的三选一，而不是 Compose 的 `AADropdownMenu` 弹层 ——
 *  弹层在本工程有「isShow 类型不对就永不弹出、且编译不报错」的先例（坑 137），
 *  而本页无法在设备上验证；行内展开只用 Column/Row/if，行为完全可预测。
 *  ② 改昵称 / 绑邮箱 / 改密码用**页面内卡片**而不是 Compose 的 Dialog —— 同样为了避开弹层，
 *  且 `KeyboardAvoidMode.RESIZE` 对页面内输入框生效、对弹层不生效（见 pages/Index.ets 的注释）。
 *  ③ 退出登录的二次确认：R13-14 起**已不是**系统 `showAlertDialog`，而是自绘 `AaConfirmDialog`
 *  + `openAaConfirmDialog()`（`openCustomDialog`，见本文件 `confirmSignOut()`）。
 *  ⚠️ 本行原写「用系统 `showAlertDialog` 二次确认」，是 R13-14 之前的旧口径，R86 复核时按代码
 *  事实更正（本页**不得**再出现系统弹窗调用，`suite-devices` 有断言钉住 —— 该断言的判据是整文件
 *  字符串扫描，**连注释里的写法也会被数进去**，故此处不复述那串调用字面量，见 §3.0 的教训）。
 *  该确认框的外层官方材质在 R85 已由 `openAaConfirmDialog()` 统一下发，本轮无需再改。
 *
 * 渲染依赖（见坑 134）：本页所有会变的显示值都在 `build()` 路径上经 `this.xxx` 读出
 * （`appearanceLabelText()` 这类方法内部读 `@State`，同样登记元素级依赖），
 * **不用 `@Builder` 的值参数传**会变的数据 —— 值参数会停在首建快照（坑 38）。
 */

import {
  APPEARANCE_DARK, APPEARANCE_LIGHT, APPEARANCE_SYSTEM, AppearanceController, AppServices,
  AuthSnapshot, authController
} from '../../feature/AppServices';
import { APP_VERSION_NAME, compareVersions } from '../../model/AppConfig';
import {
  AppPreferences, LANGUAGE_CHINESE, LANGUAGE_ENGLISH, LANGUAGE_SYSTEM,
  SIDEBAR_VIEW_PROJECT, SIDEBAR_VIEW_SESSION,
  UPDATE_AVAILABLE, UPDATE_CHECKING, UPDATE_FAILED, UPDATE_IDLE, UPDATE_LATEST,
  accountLabel, avatarLetter, languageLabel, roleLabel, serviceLabel, sidebarViewLabel,
  updateStatusLabel, updateStatusTone, versionLabel
} from '../../store/AppPreferences';
// R54：设置页的「Agent 预设」子页（预设目录来自连接器，写入的是「上次选择」记忆）。
import { AgentPresetRow, AgentPresetStore } from '../../feature/AgentPresetStore';
import {
  AgentPresetOption, agentPresetDetail, agentPresetLabel, agentPresetRowValue
} from '../../model/AgentPreset';
import { registerBackConsumer, unregisterBackConsumer } from '../BackHandler';
import {
  AaChip, AaCircleIconButton, AaConfigMenuItem, AaConfirmDialog, AaDropdownMenuItem, AaErrorBanner,
  AaSecondaryButton, DIALOG_VARIANT_PROFILE, closeAaConfirmDialog, dialogMaterial,
  immersiveMaterialEnabled, openAaConfirmDialog
} from '../Components';
// R86：四处弹层内容根的「底」改由官方沉浸材质接管，但**按 `immersiveMaterialEnabled()` 门控** ——
// 探针不可用时逐字回到 R86 前的自绘玻璃 ⇒ `glassPanelSurface()` / `GLASS_PANEL_BLUR` /
// `GLASS_SATURATION` / `GLASS_BRIGHTNESS` / `StrokeWidth` / `appShadow()` / `Shadow` 全部仍在使用。
import {
  Control, FontSize, Radius, Shadow, Space, StrokeWidth, appShadow, borderColor, canvas, faint,
  glassPanelSurface, ink, muted, raisedSurface,
  GLASS_BRIGHTNESS, GLASS_PANEL_BLUR, GLASS_SATURATION
} from '../Design';
import { Route, Router } from '../Router';
import { AaIcon, ICONS } from '../Icon';
import { uiMaterial } from '@kit.ArkUI';

/**
 * ⚠️ **R59（glass-ball）材质 A/B 实验开关（编译期常量）**。
 *
 * | 值 | 含义 |
 * | --- | --- |
 * | `0` | **基线**（交付默认）：`bindPopup` 内容根节点用不透明 `raised_surface` 底、**不挂** `systemMaterial` |
 * | `1` | 实验：底色改 `Color.Transparent` + 显式 `.systemMaterial(ImmersiveMaterial(THIN))` |
 * | `2` | **对照（隔离变量用）**：底色 `Color.Transparent` + `Material.empty`（**不挂**材质） |
 *
 * ⚠️ **为什么必须有档 2**：档 1 相对档 0 同时改了**两个**变量（底色透明 + 挂材质）。
 * 若不做档 2，「ROI MAE 从 0.0000 变成 4.10」就无法归因 ——
 * 可能全是**底色透明**的功劳（背后列表文字透出来），跟材质一点关系没有。
 * 这正是本工程反复强调的「一次只动一个变量」（见 §3.0 的 A/B 纪律）。
 *
 * 要回答的问题（Lead 裁决第 2 条）：
 * SDK `MaterialState.ENABLE` 原文说「**其他组件需要自己设置是否启用**」，
 * 而 R59 已测出「`state=1` + 不显式挂载 ⇒ 抽屉/弹窗 ROI MAE = 0.0000」。
 * ⇒ 本变体就是那句话的字面实现：**显式挂载**，并**去掉会盖住材质的不透明底色**。
 *
 * ⚠️ 交付前必须回到 `0`（`suite-design` 有断言钉住）。
 */
export const MATERIAL_PROBE_MODE: number = 0;

/**
 * 按 `MATERIAL_PROBE_MODE` 返回材质对象（唯一入口，与 `GlassIcon.ets` 的 `glassMaterial()` 同构）。
 * 档 0/2 返回 `uiMaterial.Material.empty`（SDK 原文：用于**禁用**某组件的沉浸材质）⇒ 可无条件调用。
 * 档 2 与档 0 的差别**只在底色**（见 `appearanceMenu()` 的 `backgroundColor`）—— 这正是隔离变量所需。
 */
export function probeMaterial(): uiMaterial.Material {
  if (MATERIAL_PROBE_MODE === 0 || MATERIAL_PROBE_MODE === 2) {
    return uiMaterial.Material.empty;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    // ⚠️ materialColor 必须带透明度；完全不透明会完全挡住材质滤镜（SDK 原文）
    materialColor: '#33FFFFFF',
    colorInvert: false,
    applyShadow: false,
    interactive: false
  });
}

/**
 * R86 真机位置级 A/B 的唯一变量：外观弹层的官方材质（A6 `CustomPopupOptions.systemMaterial`）总开关。
 * true（交付默认）= 下发 `dialogMaterial()` + 内容根零自绘层；
 * false（对照包）= 下发 `Material.empty` + 内容根回到自绘玻璃。
 * 它同时绑「容器材质」与「内容根门控」两处 ⇒ 两包只差这一个常量，A/B 可唯一归因到 A6 入口。
 * ⚠️ 交付档必须为 true（断言钉住）；回退 = 改成 false 重编译。
 *
 * ## 与既有 `MATERIAL_PROBE_MODE` / `probeMaterial()` 的关系（**不打架，两者正交**）
 * · `MATERIAL_PROBE_MODE`（R59）管的是**内容根自身**那一层 `.systemMaterial(probeMaterial())`，
 *  交付档 0 = `Material.empty`（对内容根**显式关闭**材质，让容器的官方材质透上来）；
 *  1 = 额外挂 THIN（R59 的实验路径）。本常量**不动**它，两者互不读对方。
 * · 本常量（R86）管的是**弹层容器**那一层的 `systemMaterial:` + 内容根的自绘底门控，
 *  只为「真机两包逐像素 A/B」提供单变量。
 *
 * ## ⚠️ 这是**验证脚手架**，不是产品开关
 * · 默认交付档 = `true`（`suite-material` / `material-audit` 会按「已接 dialogMaterial()」判定）；
 * · `false` 档**只用于构建对照包**（Lead 真机 A/B 用），**真实交付不得为 false**；
 * · 只绑**外观弹层**一处 —— sidebar / language / agentPreset 三个弹层保持纯
 *  `immersiveMaterialEnabled()` 门控，这样「一包只差一个变量」才成立。
 */
export const R86_APPEARANCE_MATERIAL_PROBE: boolean = true;

/** 头像底色：与上游 `Color(0xFF7857D8)` 同值，**不随深浅色变化**（上游也是固定色）。 */
const AVATAR_SURFACE: string = '#7857D8';

/** 卡片圆角（上游 `RoundedCornerShape(15.dp)`）。 */
const CARD_RADIUS: number = 15;
/** 行高（上游 `ProfileRow` 56dp / `IdentityCard` 72dp）。 */
const ROW_HEIGHT: number = 56;
const IDENTITY_HEIGHT: number = 72;
/** 图标槽宽与行内水平间距（上游 `SettingIcon` 34dp + `Arrangement.spacedBy(11.dp)`）。 */
const ICON_SIZE: number = 34;
const ROW_GAP: number = 11;
/** 分割线左起点（上游 `ProfileDivider(start = 57.dp, end = 12.dp)`）。 */
const DIVIDER_START: number = 57;
// 上游 `ProfileSettingsDrawer.kt:159-161` 的三个数值已全部走 `Space` 令牌（Lead 已补档位）：
//  水平内边距 → `Space.PAGE`(18)；卡片纵向间距 → `Space.S_PLUS`(10)；底部留白 → `Space.PAGE_BOTTOM`(28)。
/** 抽屉滑入/滑出时长（上游 `AnimatedVisibility` 用系统默认时长，此处取 240ms 与首页其它动效一致）。 */
const DRAWER_ANIM_MS: number = 240;
/**
 * 锚定弹层与锚点之间的间距（上游 `AADropdownMenu.kt:59 MenuGap = 4.dp`）。
 * 与首页 R13-9 那套（`HomeScreen.ets` 的 `MENU_GAP`）同值，保持一致。
 */
const DROPDOWN_GAP: number = 4;

/** `bindPopup` 的 `onStateChange` 入参（与 `HomeScreen.ets:63` 的同名接口一致）。 */
interface AaPopupStateChange {
  isVisible: boolean;
}

/**
 * 页面内的子页（上游 `ProfileDetailPage` 的 None / Account）。
 *
 * ⚠️ **R92-T5（P2 收口）删掉了 `PAGE_LANGUAGE`**：R63 把「语言」入口改成小窗之后，
 * 全工程**再没有任何调用点**会写 `this.page = PAGE_LANGUAGE` —— 唯一写入口是 `openSubPage()`，
 * 而它的调用者只剩账号页一处（`this.openSubPage(PAGE_ACCOUNT)`）。
 * ⇒ 常量 + `build()` 分发分支 + `languagePage()` + `titleText()` 分支四件套一起成了死代码，本轮整体删除。
 * ⚠️ 对照：`PAGE_AGENT_PRESET` 是**活的**（`agentPresetPage()` 被 `agentPresetWindow()` 复用），**没有**一起删。
 * ⚠️ 三选一的行组 `languageRows()` 仍被语言小窗使用，**保留**（删的只是「整页子页」这一层壳）。
 */
const PAGE_ROOT: string = 'root';
const PAGE_ACCOUNT: string = 'account';
/**
 * R54：**本工程特有**的第四个子页 —— 「Agent 预设」。
 *
 * 上游没有这一页（预设是本工程 R51 才接进来的 DSH 能力）。用户要求「设置菜单增加 Agent 预设选项」：
 * 对话页的运行设置面板里能选预设，但那是**每次新建**的临时入口；设置页这一份回答
 * 「这台机器的连接器到底上报了哪些预设、默认用哪个」，并且提供「刷新目录」这条自救路径。
 */
const PAGE_AGENT_PRESET: string = 'agent_preset';

/**
 * 账号子页「当前展开的输入表单」的三个取值。
 *
 * 上游这三项是 Dialog（`ProfileSettingsDialogs.kt`），本工程改成「点动作行 → 卡下方内联展开」，
 * 理由同设备详情的 Runtime 配置（EXPERIENCE §29：弹层不吃键盘避让）。
 */
const FORM_NICKNAME: string = 'nickname';
const FORM_EMAIL: string = 'email';
const FORM_PASSWORD: string = 'password';

// ---------------------------------------------------------------------------
// 取码冷却（纯逻辑区）—— 上游 `ProfileIdentityDialogs.kt` 的 `cooldown` 状态机
// ---------------------------------------------------------------------------
// R42-F1：本工程此前**丢弃**了 `sendEmailCode()` 的返回值（`AppServices.sendEmailCode` 已经返回
// `retryAfter`），于是取码钮既不会变成「N 秒后重发」、也不会在冷却期禁用 —— 上游有整套实现：
//  · `:83` `var cooldown by remember { mutableIntStateOf(0) }`；
//  · `:101-106` `LaunchedEffect(cooldown) { if (cooldown > 0) { delay(1000); cooldown -= 1 } }`；
//  · `:129` `label = if (cooldown > 0) stringResource(R.string.profile_resend_in, cooldown) else 发送验证码`；
//  · `:130` `enabled = validEmail && !busy && cooldown == 0`；
//  · `:137-139` `onSuccess { cooldown = it.retryAfter.coerceAtLeast(1) }`。
// 这几个函数刻意**零依赖**（不 import 任何东西）⇒ 能被 `tools/logic-test/suite-send-icon.mjs` 按
// AA-PURE-LOGIC 标记切片转译，在 Node 侧直接断言（同 `SessionDetailScreen.ets` / `TerminalScreen.ets`）。
// >>> AA-PURE-LOGIC-BEGIN

/**
 * 邮箱看起来合法（上游 `Patterns.EMAIL_ADDRESS.matcher(email.trim()).matches()`）。
 *
 * ⚠️ 这是**故意放宽**的近似：只要求「恰好一个 @、两侧非空、域名含点且点不在首尾、无空白字符」。
 * 宁可放过（服务端拒绝时原话进 `snap.error` 横幅，与改前行为一致），也不误杀合法地址。
 */
export function emailLooksValid(email: string): boolean {
  const trimmed = email.trim();
  if (trimmed.length === 0 || trimmed.indexOf(' ') >= 0) {
    return false;
  }
  const at = trimmed.indexOf('@');
  if (at <= 0 || at !== trimmed.lastIndexOf('@') || at === trimmed.length - 1) {
    return false;
  }
  const domain = trimmed.substring(at + 1);
  const dot = domain.indexOf('.');
  return dot > 0 && dot < domain.length - 1;
}

/** 取码钮是否可点（上游 `enabled = validEmail && !busy && cooldown == 0`）。 */
export function emailCodeButtonEnabled(email: string, cooldown: number, busy: boolean): boolean {
  return emailLooksValid(email) && cooldown <= 0 && !busy;
}

/**
 * 取码钮文案：冷却中「N 秒后重发」，否则「发送验证码」
 * （上游 `profile_send_code` = 「发送验证码」；resend 那条 key 不在本工程的文案覆盖表里，
 *  ⇒ 「N 秒后重发」是本工程措辞，待文案复核）。
 */
export function emailCodeButtonLabel(cooldown: number): string {
  if (cooldown > 0) {
    return String(cooldown) + ' 秒后重发';
  }
  return '发送验证码';
}

/**
 * 服务端给的 `retryAfter` → 冷却秒数（上游 `coerceAtLeast(1)`）。
 * 非正数一律不起冷却：`AppServices.sendEmailCode()` 失败时返回 **-1**（原话已写进 `snap.error`）。
 */
export function emailCodeCooldownStart(retryAfter: number): number {
  if (retryAfter <= 0) {
    return 0;
  }
  return retryAfter < 1 ? 1 : Math.floor(retryAfter);
}

/** 冷却每秒一步（上游 `cooldown -= 1`，到 0 停住，不出现负数）。 */
export function emailCodeCooldownTick(current: number): number {
  return current > 0 ? current - 1 : 0;
}

// <<< AA-PURE-LOGIC-END

/**
 * 设置内容主体 —— 两种宿主共用这一份实现：
 *  - `SettingsScreen`：独立页面（`pages/Index.ets` 的 `Route.SETTINGS` 分支）；
 *  - `SettingsDrawerPanel`：抽屉（首页顶栏头像打开、叠在首页之上、**不走路由**，
 *  对应安卓 `ui/screens/profile/ProfileSettingsDrawer.kt`）。
 *
 * 两者的差别只有两处：根页的「退出」动作（`onClose()` 还是 `Router.pop()`），
 * 以及系统返回键在根页的兜底。内容、子页三态、偏好读写全部共用。
 */
@Component
struct SettingsContent {
  /** 抽屉形态（true）/ 独立页面形态（false）。 */
  @Prop drawer: boolean = false;
  /** 抽屉形态的关闭回调（由 `SettingsDrawerPanel` 透传；页面形态留空）。 */
  onClose?: () => void;
  // 状态必须在 build 里被真正读到才会触发刷新（见 HomeScreen 顶部注释）。
  @State snap: AuthSnapshot = authController.current;
  @State appearance: string = AppearanceController.current;
  @State languageMode: string = LANGUAGE_SYSTEM;
  @State sidebarView: string = SIDEBAR_VIEW_PROJECT;
  /** 当前子页（PAGE_ROOT / PAGE_ACCOUNT / PAGE_AGENT_PRESET；`PAGE_LANGUAGE` 已于 R92-T5 删除）。 */
  @State page: string = PAGE_ROOT;
  // ---- R54：「Agent 预设」子页的快照（build 只读 @State，见 HomeScreen 顶部那条纪律）----
  @State presetRows: AgentPresetRow[] = [];
  @State presetLoading: boolean = false;
  @State presetRefreshingDeviceId: string = '';
  @State presetError: string = '';
  @State presetNotice: string = '';
  /** 预设 store 的监听器（存成字段才能在 aboutToDisappear 里注销）。 */
  private presetListener: () => void = () => {
    this.syncPresetState();
  };
  /** 外观 / 侧边栏显示两个三选区的展开态。 */
  /** 退出登录确认框的 dialogId（R13-14 自绘；0 = 当前没开）。 */
  private signOutDialogId: number = 0;
  @State appearanceOpen: boolean = false;
  @State sidebarOpen: boolean = false;
  /**
   * R63：「语言」/「Agent 预设」两个**小窗**的开关（点击入口卡后以浮层小卡片展开，不再整页切子页）。
   *
   * ⚠️ 必须是 `@State` 且被 `bindPopup` 的第一个参数读到：它参与条件渲染，普通成员点了不刷新
   * （坑 48），而 `bindPopup` 的 isShow 类型不对会「永不弹出、且编译不报错」（坑 137 同族）。
   */
  @State languageOpen: boolean = false;
  @State agentPresetOpen: boolean = false;
  @State displayName: string = '';
  @State newPassword: string = '';
  @State email: string = '';
  @State emailCode: string = '';
  /**
   * 取码冷却剩余秒数（0 = 可以取码）。对应上游 `ProfileIdentityDialogs.kt` 的 `cooldown`（R42-F1）。
   * 由纯逻辑区的 `emailCodeCooldownStart / `emailCodeCooldownTick` 驱动，见文件顶部的纯逻辑区。
   */
  @State emailCodeCooldown: number = 0;
  /** 冷却计时器句柄（-1 = 没在跑）；与 `emailCodeCooldown` 同生共死。 */
  private emailCodeTimer: number = -1;
  /**
   * 账号子页当前**展开**的输入表单（`''` = 都收起）。
   *
   * 上游这三个入口是 Dialog（`ProfileSettingsDialogs.kt`），本工程改成「点动作行 → 卡下方内联展开」，
   * 理由与设备详情的 Runtime 配置一致（EXPERIENCE §29：弹层不吃键盘避让，输入框会被键盘挡住）。
   */
  @State accountForm: string = '';
  @State updateStatus: string = UPDATE_IDLE;
  @State updateDetail: string = '';
  @State localError: string = '';

  /** 存成字段才能被 `offChange` 摘除（两个控制器的监听器数组都只增不减）。 */
  private authListener: () => void = () => {
    this.snap = authController.current;
  };
  private appearanceListener: () => void = () => {
    this.appearance = AppearanceController.current;
  };
  /**
   * 系统返回键的消费者（见 ui/BackHandler.ets）：
   * 返回 true = 这次返回已被本页内部消化（收起展开区 / 子页回根页），根页面不要再 pop 路由。
   * 存成字段是为了能在 aboutToDisappear 里注销 —— 注册表只留一个消费者，悬空回调会吞掉返回键。
   */
  private backConsumer: () => boolean = () => this.consumeBack();
  /**
   * 本页是否还活着（aboutToAppear → true，aboutToDisappear → false）。
   * 注册表里万一残留了回调（注销路径出意外），这个守卫能保证「僵尸消费者」不会把返回键吞掉。
   */
  private alive: boolean = false;

  aboutToAppear(): void {
    // 偏好：先装持久化再读值。`install()` 幂等，且必须早于任何 setOrCreate（见 AppPreferences 注释）。
    const preferences = AppPreferences.get();
    preferences.install();
    this.languageMode = preferences.language;
    this.sidebarView = preferences.sidebarView;

    this.displayName = authController.current.displayName;
    this.email = authController.current.email;
    this.appearance = AppearanceController.current;
    authController.onChange(this.authListener);
    AppearanceController.onChange(this.appearanceListener);
    AgentPresetStore.get().onChange(this.presetListener);
    this.syncPresetState();
    // 系统返回键先问本页（逐级返回），只有本页不消费时才交回路由栈
    this.alive = true;
    registerBackConsumer(this.backConsumer);
    // R42-F1：冷却中回到本页（同一实例被复用）时把表接回去，
    // 否则按钮会永远停在「N 秒后重发」的灰态（@State 还在、表没了）。
    if (this.emailCodeCooldown > 0) {
      this.startEmailCodeCooldown(this.emailCodeCooldown);
    }
  }

  aboutToDisappear(): void {
    authController.offChange(this.authListener);
    AppearanceController.offChange(this.appearanceListener);
    AgentPresetStore.get().offChange(this.presetListener);
    // 先置「已销毁」，再按**身份**注销：`unregisterBackConsumer` 只在当前登记的消费者就是自己时才清空，
    // 因此抽屉关闭不会误清掉首页自己注册的消费者（单槽注册表的坑，见 ui/BackHandler.ets 注释）。
    this.alive = false;
    unregisterBackConsumer(this.backConsumer);
    // R42-F1：冷却表必须随页面一起停 —— 留着会每秒写一次已销毁页面的 @State（R37 的教训）。
    this.stopEmailCodeCooldown();
  }

  build() {
    // R65-A（设计规格 §2）：顶栏从正文里**提到 `Navigation` 标题栏**。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容区之上**、占自己一行）而不是 `STACK`：
    //  `STACK` 把标题栏**叠在内容上**，那就必须自己给内容让位（`contentStartOffset` 那套），
    //  而 设计规格 §2 明确要求「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
    //  ⇒ STANDARD 下内容天然落在标题栏下方，首屏不会被顶栏压住（与 R65-B 的三页逐字同款）。
    //
    // ⚠️ **本组件有两种宿主**（独立页面 `SettingsScreen` / 抽屉 `SettingsDrawerPanel`），
    //  R65-A 起**两种宿主统一**走同一个 `Navigation` 标题栏：
    //  · 官方沉浸光感的生效范围是「`Navigation`/`NavDestination` 标题栏」等四类位置
    // （`坑 245`）—— 抽屉形态虽然不是路由页面，但它渲染的同样是一个
    //  `Navigation` 标题栏 ⇒ 两种形态**都在生效范围内**，可以一律开官方材质；
    //  · 反过来说，若给抽屉保留自绘顶栏，就必须保留 `topInset()`（抽屉不在框架标题栏里、
    //  状态栏要自己避让），那会变成 suite-settings 明令禁止的「半迁移态」——
    //  且该页会被判成「既进标题栏又自己避让」的重复避让。
    Navigation() {
      Column() {
        AaErrorBanner({
          message: this.localError.length > 0 ? this.localError : this.snap.error,
          onDismiss: () => {
            this.localError = '';
            authController.clearError();
          }
        })

        Scroll() {
          // 卡片间距 10dp（上游 `Arrangement.spacedBy(10.dp)`）
          Column({ space: Space.S_PLUS }) {
            // R92-T5：`PAGE_LANGUAGE` 分支已删除（不可达死代码，见常量区注释）。
            if (this.page === PAGE_ACCOUNT) {
              this.accountPage()
            } else if (this.page === PAGE_AGENT_PRESET) {
              this.agentPresetPage()
            } else {
              this.rootPage()
            }
            // 底部留白（上游 contentPadding bottom = 28dp）
            Blank().height(Space.PAGE_BOTTOM)
          }
          .width('100%')
          // ⚠️ R13 F-10：`top: Space.S_PLUS` 不是随手的内边距 —— 上游把 `ProfileHeader` 与 `IdentityCard`
          // 放在**同一个 LazyColumn**里（`ProfileSettingsDrawer.kt:155-162`），`spacedBy(10.dp)` 在两者之间
          // 插了 10dp；本工程把 header 留在 Scroll 之外（不随内容滚走），这 10vp 就得由滚动内容自己补，
          // 否则首卡比安卓高 30px（≈10vp）。
          .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.S_PLUS })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        /**
         * ⚠️⚠️ R13 F-10 的关键一行：`align` 是**通用属性**，SDK 写明默认值是 `Alignment.Center`
         * （`@ohos` 侧的 `common.d.ts` → `align(value: Alignment)`：Default value: **Alignment.Center**），
         * 而它管的是「组件内容在其绘制区内的对齐」⇒ **`Scroll` 的内容比视口短时会被垂直居中**。
         * 设置页内容 1739px < 视口 2408px，于是上下各空 334px（≈112vp）——
         * 这正是「标题与首卡之间多出一大块空白」的根因（不是安全区被避让了两次）。
         * 真机 dump 佐证（开发期验证记录）：
         * `Scroll`[0,326][1316,2734] 的子 `Column`[0,660][1316,2399]，660-326 = 334 = (2408-1739)/2，
         * 底部同样空 335px（严格对称 ⇒ 是居中而不是 padding）。
         * 修法与另一工程的滚动区一致（`pages/Index.ets` 的 `.align(Alignment.Top)`）。
         */
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      // 抽屉形态用上游 `profilePageBackground`（base #F4F3EF / dark #09090B）——
      // 内容层必须是**不透明**的，否则抽屉外壳那层色会被内容自己的 canvas 盖回去。
      // ⚠️ R65-A：这一层现在同时是**标题栏的背景**（`Navigation` 自身不给底色）⇒ 抽屉形态下
      //  标题栏那一条透出的就是 `profile_page_surface`，与改前逐像素同源。
      .backgroundColor(this.drawer ? $r('app.color.profile_page_surface') : canvas())
    }
    // 标题栏 = 顶栏一行；底色**透明**，让标题栏自己的**官方材质**（`navTitleBar()` 的 `systemMaterial`）透出页面底色。
    .title(this.navTitleBar(), { backgroundColor: Color.Transparent })
    .mode(NavigationMode.Stack)
    // ## R66-2 修正（两轮真机证据合起来才定下来）：**必须显式 Full**。
    // · 缺省 ≠ Full：SDK `titleMode` 原文 **Default value: NavigationTitleMode.Free**；R66 SPEC 里
    //  「缺省是 Full」是误判。**Free** 的主标题**随内容滚动收起 / 改变位置**
    //  ⇒ 真机就是用户截图的「顶栏整条消失、状态栏后面留残影」（R66 缺陷 ①）。
    // · **Mini**（R66-2 第一版）确实钉住了，但真机实测：它的 56vp **从窗口顶 y=0 起算**
    //  ⇒ 标题栏落在 y≈30..128px，与状态栏带（0..136px 时钟/信号/电池）**重叠**；
    //  且 56vp < 本页栏高（58/64vp）⇒ 栏被钳、按钮被压扁。**Mini/Free 两档都不合用。**
    // · **Full**：SDK 原文「The title is **fixed** at full mode」、标题栏高 **112vp**；本工程 R62/R65
    //  真机实测（未加 titleMode 的 Free 静止态 = Full）为 `TitleBar [0,137][1316,332]`
    //  ⇒ 栏内容落在 **46..112vp（状态栏之下）**，正是 R65 那版被验收过的几何，且 66vp 容得下本页栏高。
    //  ⇒ **Full = 常驻钉住 + 落在状态栏之下**，不需要任何安全区补丁。
    .titleMode(NavigationTitleMode.Full)
    .hideToolBar(true)
    .width('100%')
    .height('100%')
  }

  // -------------------------------------------------------------------------
  // 顶部标题栏（上游 `ProfileHeader`：返回键 + 居中标题 + 等宽占位）
  // -------------------------------------------------------------------------

  /**
   * ⚠️ **R65-A 删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）。
   *
   * R37 五改的本意是「顶栏背景铺到屏幕顶、状态栏那一条也一起糊」。但顶栏一旦进入 `Navigation`
   * 标题栏，**高度与位置由框架接管**：真机 `dumpLayout` 实测标题栏落在 `[0,137][1316,332]`
   * （`HomeScreen` R62 的实测记录）—— 页面根节点**已经在状态栏之下**，顶栏再避让一次就是
   * **重复避让 137px**。而且原来读的是 `AppStorage.get(SAFE_AREA_TOP_PX)` 这个**非响应**读取，
   * 值随冷启动时序在 `0 / 46vp` 之间跳（R61 实测：同一份包两次冷启动顶栏行高 136px / 274px）。
   * ⇒ 本页按 R65-A 固定**不避让**，与 `HomeScreen`（R62）/ `DevicesScreen`（R65-B）同一口径。
   *
   * **R65-A：本页标题栏** —— `Navigation.title(...)` 的自定义构造器，内容只有**顶栏一行**
   * （上游 `ProfileHeader`：返回键 + 居中标题 + 等宽占位）。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End`
   * 的底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1/§2）。
   */
  @Builder
  navTitleBar() {
    Row() {
      // 返回钮：上游 `ProfileHeader` 用的是 `BackIconButton`（`ui/designsystem/Components.kt:38`）——
      // **40dp 圆盘 + raisedSurface 底 + 1dp 描边 + 22dp `Lucide.ChevronLeft`**，不是裸箭头。
      // 直接复用本工程同构的 `AaCircleIconButton`（Components.ets 的「圆形图标按钮」，
      // 对应首页 `RoundLucideButton`），不再自己拼 Column —— 以前那个是裸箭头（无底色、无描边）。
      // R13 F-10 像素判据：返回区 x60-230/y190-300 的「≥250 近白」像素 安卓 8707 vs 鸿蒙 156。
      // R57（T2b）：改**玻璃档**（磨砂 + 1vp 渐变亮边 + 左上镜面高光 + 柔和外阴影）。
      // ⚠️ 圆盘直径 40 / 图标 22 / `filled: true` 都保留 —— 视觉上仍是「白圆盘返回钮」，
      // 多的只是玻璃材质（F-10 那条「返回区近白像素 ≥ 8707px²」的判据因此只会更亮，不会变暗）。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        filled: true,
        glass: true,
        // R65-A：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内（`坑 245`）。
        officialMaterial: true,
        accessibilityLabel: '返回',
        tint: ink(),
        onTap: () => {
          this.goBack();
        }
      })
      Text(this.titleText())
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 右侧等高占位：三槽不重叠（坑 29 的实测教训），标题因此严格居中。
      // 用空 Text 而不是 Blank：Blank 在 Row 里会抢剩余空间，把标题挤出真正的中心。
      Text('').width(40).height(40)
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），64vp → 262px（低 27px）。
    // ⚠️ R65-A 之前这里是字面量 `64`（自绘顶栏时代的行高），R81 起改用共享令牌；
    //  栏高同样**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.S, right: Space.S })
    .alignItems(VerticalAlign.Center)
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：栏底色 28.7 vs 正文 9.67
    //  ⇒ 一条比正文亮 +19.0 的带；首页同口径 +0.00）。**光效只留在栏内控件（返回钮）上。**
    //  ⚠️ 历史：R66 曾把整条栏改官方材质（本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），
    //  R87 因「有明显分界」撤回；同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  // -------------------------------------------------------------------------
  // 根页
  // -------------------------------------------------------------------------

  @Builder
  rootPage() {
    Column({ space: Space.M }) {
      this.identityCard()
      this.appearanceCard()
      this.languageCard()
      this.sidebarCard()
      // R54：用户要求的「设置菜单增加 Agent 预设选项」。
      this.agentPresetCard()
      this.versionCard()
      this.archivedCard()
      this.signOutCard()
    }
    .width('100%')
  }

  /** 账号行：头像（首字母）+ 用户名 + 「官方服务」+ ›（上游 `IdentityCard`）。 */
  @Builder
  identityCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        Text(this.avatarText())
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary_action'))
          .textAlign(TextAlign.Center)
          .width(42)
          .height(42)
          .borderRadius(21)
          .backgroundColor(AVATAR_SURFACE)
        Column({ space: 1 }) {
          Text(this.accountLabelText())
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(ink())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(serviceLabel(this.snap.serverUrl))
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(muted())
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        AaIcon({ d: ICONS['chevron-right'], iconSize: 20, color: $r('app.color.faint') })
      }
      .width('100%')
      .height(IDENTITY_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openSubPage(PAGE_ACCOUNT);
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  /** 外观行：右侧当前值 + 展开后的三选一（上游 `AppearancePopup`）。 */
  @Builder
  appearanceCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('moon', $r('app.color.ink_soft'))
        Text('外观')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        Text(this.appearanceLabelText())
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(muted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // R13-21（4-2）：上游 `ProfileSettingsDrawer.kt:217 trailingIcon = Lucide.ChevronsUpDown`
        // （表示「点开选值」，**不随展开态翻转**）—— 原来是随状态翻转的单向 chevron。
        AaIcon({ d: ICONS['chevrons-up-down'], iconSize: 16, color: $r('app.color.faint') })
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // R13-22（4-3）：点行打开**锚定弹层**（上游 `AppearancePopup`），不再是行内手风琴
        this.appearanceOpen = true;
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
    // 上游 `ProfileDropdown`：`Box(fillMaxWidth, TopEnd)` + 1dp 锚点 ⇒ 菜单右缘对齐卡片右缘、挂在行下方。
    // 参数逐项对齐 R13-9 已验证的那一套（首页筛选/项目弹窗），见 `appearancePopupOptions()`。
    .bindPopup(this.appearanceOpen, this.appearancePopupOptions())
  }

  /**
   * 语言行：右侧当前值 + 双向箭头（上游 `ProfileRow`；三选一内容来自上游 `LanguageDetailPage`）。
   *
   * ⚠️ R63：点击后**不再整页切到 `PAGE_LANGUAGE`**，改为在当前页弹出**小窗**（`languageWindow()`）。
   * ⚠️ R92-T5：`PAGE_LANGUAGE` 常量与 `languagePage()` 随后被删除（不可达死代码），小窗走
   *  `languageWindow()` → `languageRows()`；本卡只负责「一行 + 打开小窗」。
   *
   * R92（用户原话「将设置页的『语言』栏、『Agent 预设』栏的展开标签换成上下三角，统一一下逻辑」）：
   * 行尾由 `chevron-right` / 20vp 改为 `chevrons-up-down` / 16vp —— 与「外观」「侧边栏显示」两张卡
   * **逐字一致**。取舍依据：四张卡都是「点开弹小窗选值」这**同一个交互语义**，行尾图标是同一枚
   * 「可展开」提示，因此必须同字形同尺寸（20 vs 16 并列摆放时视觉重量不一致，真机上一眼能看出）且
   * **不随展开态翻转**（R13-21 已定）。同时推翻 R63 的旧口径「入口卡上的 chevron-right 保持不动」——
   * 那条是为了不动 `suite-settings` 4-2 的「双向箭头恰好 2 处」计数；本轮用户明确要求统一，
   * 计数按契约演进更新为 4（见 suite-settings.mjs 的 R92 注释）。
   * ⚠️ 这里用的是**线条**双向 chevron（Lucide `chevrons-up-down`，字形就是上下两个三角），
   * 不是实心 caret；若要实心三角必须新引入图标并同步 `ui/Icon.ets` 与 `suite-icons`，未做。
   */
  @Builder
  languageCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('globe', $r('app.color.ink_soft'))
        Text('语言')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        Text(languageLabel(this.languageMode))
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(muted())
          .maxLines(1)
        // R92：与「外观」「侧边栏显示」统一成同一枚双向箭头 + 同尺寸 16vp（取舍见本 Builder 上方注释）。
        AaIcon({ d: ICONS['chevrons-up-down'], iconSize: 16, color: $r('app.color.faint') })
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // R63：开**小窗**（不再是 openSubPage 整页切换）
        this.languageOpen = true;
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
    .bindPopup(this.languageOpen, this.languagePopupOptions())
  }

  /** 侧边栏显示行：右侧当前值 + 展开后的二选一（上游 `SidebarViewPopup`，取值见 `HomeSidebarViewMode`）。 */
  @Builder
  sidebarCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('list', $r('app.color.ink_soft'))
        Text('侧边栏显示')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        Text(sidebarViewLabel(this.sidebarView))
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(muted())
          .maxLines(1)
        // R13-21（4-2）：同上，上游 `ProfileSettingsDrawer.kt:248 trailingIcon = Lucide.ChevronsUpDown`。
        AaIcon({ d: ICONS['chevrons-up-down'], iconSize: 16, color: $r('app.color.faint') })
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // R13-22（4-3）：同上，侧边栏显示也改成锚定弹层（上游 `SidebarViewPopup`）。
        this.sidebarOpen = true;
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
    .bindPopup(this.sidebarOpen, this.sidebarPopupOptions())
  }

  /**
   * R54：**Agent 预设**入口卡（用户要求「设置菜单增加 Agent 预设选项」）。
   *
   * 右侧显示「N 个 Agent」（还没读过目录时不占位）。
   *
   * ⚠️ R63：点击后**不再整页切到 `PAGE_AGENT_PRESET`**，改为在当前页弹出**小窗**
   * （`agentPresetWindow()`：沿用 `agentPresetPage()` 的全部内容 —— 每「设备 • Agent」一张卡、
   * 单选写回、`刷新目录`（含 refreshing 态）、加载态 / 空态 / 错误横幅 / notice，且**可滚动**）。
   */
  @Builder
  agentPresetCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('sparkles', $r('app.color.ink_soft'))
        Text('Agent 预设')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        if (this.presetSummary().length > 0) {
          Text(this.presetSummary())
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(muted())
            .maxLines(1)
        }
        // R92：与「外观」「侧边栏显示」「语言」统一成同一枚双向箭头 + 同尺寸 16vp（取舍见本 Builder 上方注释）。
        AaIcon({ d: ICONS['chevrons-up-down'], iconSize: 16, color: $r('app.color.faint') })
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // R63：开**小窗**（不再是 openSubPage 整页切换）。
        // ## R94：开窗改为**自动刷新目录**（用户要求删掉手动「刷新目录」行）
        // `autoRefresh()` = 先 `load()` 拿设备列表、再对每台在线设备重新发现；失败写进 `presetError`
        // ⇒ 弹窗顶部那条 `AaErrorBanner` 自动显示（不需要另加控件）。
        this.agentPresetOpen = true;
        this.autoRefreshPresets();
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
    .bindPopup(this.agentPresetOpen, this.agentPresetPopupOptions())
  }

  /** 版本卡：版本 + 检查更新两行（上游 `item("version")` 的 ProfileCard）。 */
  @Builder
  versionCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('package-check', $r('app.color.ink_soft'))
        Text('版本')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        Text(versionLabel(APP_VERSION_NAME))
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(muted())
          .maxLines(1)
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)

      this.rowDivider()

      Row({ space: ROW_GAP }) {
        // R13-21（4-1）：上游 `ProfileSettingsDrawer.kt:273` 这一行的 `icon = Lucide.Server`
        // （下载图标是**行尾**的 `trailingIcon`，只在有新版时出现，见下面）。
        this.rowIcon('server', $r('app.color.ink_soft'))
        Text('检查更新')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        if (this.updateStatus === UPDATE_CHECKING) {
          LoadingProgress().width(16).height(16).color(muted())
        }
        if (this.updateStatus === UPDATE_AVAILABLE) {
          // R13-21（4-1）：上游 `ProfileSettingsDrawer.kt:275-276` —— 有新版时行尾是 `Lucide.Download`
          // 且 `trailingAttention = true`（用警示色）；无新版时才用 chevron。
          AaIcon({ d: ICONS['download'], iconSize: FontSize.ICON_MD, color: $r('app.color.notice_warning') })
        }
        if (this.updateStatusText().length > 0) {
          // 不给它 layoutWeight：标题已经占了剩余空间，这里只限个上限，
          // 免得长文案把「检查更新」四个字挤没（两个 layoutWeight 会平分整行）。
          Text(this.updateStatusText())
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.updateStatusColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 168 })
            .textAlign(TextAlign.End)
        } else {
          AaIcon({ d: ICONS['chevron-right'], iconSize: 20, color: $r('app.color.faint') })
        }
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.checkUpdate();
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  /** 已归档会话（上游 `item("archived-sessions")`）。 */
  @Builder
  archivedCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('archive', $r('app.color.ink_soft'))
        Text('已归档会话')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
        AaIcon({ d: ICONS['chevron-right'], iconSize: 20, color: $r('app.color.faint') })
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        Router.push(Route.ARCHIVED);
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  /** 退出登录（上游 `SignOutCard`：红色文字 + LogOut 图标，整卡可点）。 */
  @Builder
  signOutCard() {
    Column() {
      Row({ space: ROW_GAP }) {
        this.rowIcon('log-out', $r('app.color.error_text'))
        Text('退出登录')
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.error_text'))
          .layoutWeight(1)
          .maxLines(1)
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.confirmSignOut();
      })
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  // -------------------------------------------------------------------------
  // 账号子页（上游 `AccountDetailPage`）
  // -------------------------------------------------------------------------

  @Builder
  accountPage() {
    Column({ space: Space.M }) {
      Column({ space: Space.XS }) {
        Text(this.avatarText())
          .fontSize(38)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary_action'))
          .textAlign(TextAlign.Center)
          .width(86)
          .height(86)
          .borderRadius(43)
          .backgroundColor(AVATAR_SURFACE)
        Text(this.accountLabelText())
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .margin({ top: Space.S })
          .maxLines(1)
        Text(serviceLabel(this.snap.serverUrl))
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(1)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: Space.L, bottom: Space.S })

      this.accountInfoCard()
      // R22：三张**常驻的内联表单**改成上游的「动作卡 + 点开后展开」。
      this.accountActionsCard()
      if (this.accountForm === FORM_NICKNAME) {
        this.nicknameForm()
      } else if (this.accountForm === FORM_EMAIL) {
        this.emailForm()
      } else if (this.accountForm === FORM_PASSWORD) {
        this.passwordForm()
      }
      // 上游 `AccountDetailPage` 底部还有一张退出登录卡（`:158-161`）。
      this.signOutCard()
    }
    .width('100%')
  }

  /**
   * 账号动作卡 —— 上游 `AccountDetailPage` 的第二张 `ProfileCard`（`ProfileSettingsDetails.kt:143-157`）：
   * 三个 `AccountActionRow(icon, text, onClick)` + 行间 `ProfileDivider`。
   *
   * ⚠️ R22 勘误：本工程此前把这三项做成了**常驻的内联表单**（三个输入区一直摊在页面上），
   * 与上游「先看到三个动作行、点一下才出现输入界面」的结构与交互都不同（并排图 `../开发期验证记录`）。
   * 现在：静态结构 = 上游的三个动作行；点击 → 在动作卡**下方内联展开**对应表单，
   * 交互与上游的「点动作行 → 出现输入界面」等价，同时避开弹层的键盘避让问题。
   */
  @Builder
  accountActionsCard() {
    Column() {
      // 图标逐一对应上游：`ic_user_round_arrow_left` / `Lucide.MailCheck` / `Lucide.KeyRound`。
      this.accountActionRow(FORM_NICKNAME, 'user-round-arrow-left', '修改昵称')
      Divider().color(borderColor()).strokeWidth(1).margin({ left: DIVIDER_START })
      this.accountActionRow(FORM_EMAIL, 'mail-check', '绑定或修改邮箱')
      Divider().color(borderColor()).strokeWidth(1).margin({ left: DIVIDER_START })
      this.accountActionRow(FORM_PASSWORD, 'key-round', '修改密码')
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  /** 单个动作行（上游 `AccountActionRow`：图标 + 文字，整行可点）。 */
  @Builder
  accountActionRow(form: string, icon: string, label: string) {
    Row({ space: ROW_GAP }) {
      this.rowIcon(icon, ink())
      Text(label)
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
      if (this.accountForm === form) {
        AaIcon({ d: ICONS['chevron-up'], iconSize: FontSize.ICON, color: faint() })
      }
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: Space.M, right: Space.M })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // 再点一次收起（与设备详情的「配置 / 收起配置」同一套心智）。
      this.accountForm = this.accountForm === form ? '' : form;
    })
  }

  /** 资料卡：昵称 / 邮箱 / 角色 / 账号 ID / 服务器（前三行对上游，后两行是本工程既有信息）。 */
  @Builder
  accountInfoCard() {
    Column() {
      Row() {
        Text('昵称')
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .layoutWeight(1)
        Text(accountLabel(this.snap.displayName, this.snap.email))
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(48)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)

      this.flatDivider()

      Row() {
        Text('邮箱')
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .layoutWeight(1)
        Text(this.snap.email.length > 0 ? this.snap.email : '未绑定')
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(48)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)

      this.flatDivider()

      Row() {
        Text('角色')
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .layoutWeight(1)
        Text(roleLabel(this.snap.role))
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(1)
      }
      .width('100%')
      .height(48)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)

      this.flatDivider()

      Row() {
        Text('账号 ID')
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .layoutWeight(1)
        Text(this.snap.userId.length > 0 ? this.snap.userId : '—')
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(48)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)

      this.flatDivider()

      Row() {
        Text('服务器')
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .layoutWeight(1)
        Text(this.snap.serverUrl.length > 0 ? this.snap.serverUrl : '未设置')
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(48)
      .padding({ left: Space.M, right: Space.M })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  /**
   * 改昵称表单（上游 `NicknameDialog` 的**页面内等价物**，在动作卡下方内联展开）。
   * 标题不再重复写「修改昵称」—— 上面那行动作行就是标题。
   */
  @Builder
  nicknameForm() {
    Column({ space: Space.S }) {
      Row({ space: Space.S }) {
        TextInput({ text: this.displayName, placeholder: '昵称' })
          .fontSize(FontSize.BODY)
          .height(44)
          .layoutWeight(1)
          .borderRadius(Radius.M)
          .borderWidth(1)
          .borderColor(borderColor())
          .onChange((value: string) => {
            this.displayName = value;
          })
        AaSecondaryButton({
          label: '保存',
          onTap: () => {
            authController.updateDisplayName(this.displayName);
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(Space.M)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
  }

  /**
   * 取验证码（上游 `onSendCode` 那段 `scope.launch`）。
   * R42-F1：`AppServices.sendEmailCode()` **已经**返回 `retryAfter`（失败返回 **-1**，原话由它写进
   * `snap.error`），本轮把返回值接上：>0 就起冷却（按钮禁用 + label 变「N 秒后重发」）。
   * ⚠️ 这个 Promise **不会 reject**（内部 try/catch 全兜住）⇒ 只挂 then 是安全的。
   */
  private requestEmailCode(): void {
    const email = this.email.trim();
    authController.sendEmailCode(email).then((retryAfter: number) => {
      this.startEmailCodeCooldown(emailCodeCooldownStart(retryAfter));
    });
  }

  /**
   * 起冷却（上游 `cooldown = it.retryAfter.coerceAtLeast(1)` + `LaunchedEffect` 每秒递减）。
   * ⚠️ **先停旧表再起新表**：连点两次不会留下两个每秒写 @State 的定时器。
   */
  private startEmailCodeCooldown(seconds: number): void {
    this.stopEmailCodeCooldown();
    this.emailCodeCooldown = emailCodeCooldownStart(seconds);
    if (this.emailCodeCooldown <= 0) {
      return;
    }
    this.emailCodeTimer = setInterval(() => {
      if (!this.alive) {
        // 页面已销毁：停表，别每秒写一次已销毁页面的 @State（R37 的教训）。
        this.stopEmailCodeCooldown();
        return;
      }
      this.emailCodeCooldown = emailCodeCooldownTick(this.emailCodeCooldown);
      if (this.emailCodeCooldown <= 0) {
        this.stopEmailCodeCooldown();
      }
    }, 1000);
  }

  /** 停冷却计时器（句柄置回 -1）；`aboutToDisappear` 也走这里。 */
  private stopEmailCodeCooldown(): void {
    if (this.emailCodeTimer >= 0) {
      clearInterval(this.emailCodeTimer);
      this.emailCodeTimer = -1;
    }
  }

  /** 绑定邮箱表单（上游 `EmailBindingDialog` 的**页面内等价物**，在动作卡下方内联展开）。 */
  @Builder
  emailForm() {
    Column({ space: Space.S }) {
      TextInput({ text: this.email, placeholder: '邮箱' })
        .type(InputType.Email)
        .fontSize(FontSize.BODY)
        .height(44)
        .borderRadius(Radius.M)
        .borderWidth(1)
        .borderColor(borderColor())
        .onChange((value: string) => {
          this.email = value;
        })
      Row({ space: Space.S }) {
        TextInput({ text: this.emailCode, placeholder: '邮箱验证码' })
          .fontSize(FontSize.BODY)
          .height(44)
          .layoutWeight(1)
          .borderRadius(Radius.M)
          .borderWidth(1)
          .borderColor(borderColor())
          .onChange((value: string) => {
            this.emailCode = value;
          })
        // R42 裁决（「发送类入口全量复核」）：**保持文字形态**（不改图标），三条可核理由 ——
        //  ① 上游这一颗就是**文字按钮**，且 label 要承载倒计时：`ProfileIdentityDialogs.kt:128-146`
        //  的 `label = if (cooldown > 0) <N 秒后重发> else 发送验证码`（`profile_send_code`
        //  = 「发送验证码」；resend 那条 key 不在本工程文案覆盖表里 ⇒「N 秒后重发」是本工程措辞），
        //  纯图标承载不了这段动态文案；
        //  ② 它是**账号域取码**动作，不是「把用户内容发出去」的发送（裁决口径见
        //  开发期验证记录的裁决表 A4）；
        //  ③ 它在验证码输入框**同排**，不是对话框右下角的发送位（上游还是 `fillMaxWidth` 整条）。
        //  `tools/logic-test/suite-send-icon.mjs` 把这条裁决钉住了：改成图标会让套件变红。
        // R42-F1（本轮修）：label / 可点条件改为**纯逻辑区**的返回值 ——
        //  冷却期按钮禁用（`interactive` ⇒ AaSecondaryButton 的 opacity 0.5 分支）+ 文案变「N 秒后重发」。
        AaSecondaryButton({
          label: emailCodeButtonLabel(this.emailCodeCooldown),
          compact: true,
          interactive: emailCodeButtonEnabled(this.email, this.emailCodeCooldown, this.snap.loading),
          onTap: () => {
            this.requestEmailCode();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      Row({ space: Space.S }) {
        AaSecondaryButton({
          label: '绑定邮箱',
          onTap: () => {
            authController.bindEmail(this.email, this.emailCode);
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Space.M)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
  }

  /** 修改密码表单（上游 `ChangePasswordDialog` 的**页面内等价物**，在动作卡下方内联展开）。 */
  @Builder
  passwordForm() {
    Column({ space: Space.S }) {
      Row({ space: Space.S }) {
        // R41 交互审计 ②：本表单是上游 `ChangePasswordDialog`（弹窗）的**页面内等价物**，
        // placeholder 属本工程自造（不是逐字复刻的 strings.xml 文案），因此可以把规则写进去。
        // 改前只写「新密码」，而下方按钮 `interactive: this.newPassword.length >= 6` 会在不足 6 位时
        // **静默置灰** —— 用户不知道差什么（审计里全工程唯一一处「条件不满足就置灰且无说明」的主按钮）。
        TextInput({ text: this.newPassword, placeholder: '新密码（至少 6 位）' })
          .type(InputType.Password)
          .fontSize(FontSize.BODY)
          .height(44)
          .layoutWeight(1)
          .borderRadius(Radius.M)
          .borderWidth(1)
          .borderColor(borderColor())
          .onChange((value: string) => {
            this.newPassword = value;
          })
        AaSecondaryButton({
          label: '修改密码',
          interactive: this.newPassword.length >= 6,
          onTap: () => {
            authController.changePassword(this.newPassword);
            this.newPassword = '';
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(Space.M)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
  }

  // -------------------------------------------------------------------------
  // 语言三选一（上游 `LanguageDetailPage`）
  // -------------------------------------------------------------------------
  // ⚠️ R92-T5：原来这一节还有一层「语言子页」壳（`languagePage()`），随 `PAGE_LANGUAGE` 一起删了。
  //  留在这里的 `languageRows()` 是**小窗**用的那三个选项（`languageWindow()` 调它）。

  /**
   * 语言三选一的**行组**（R92-T5 之后只剩 R63 的语言小窗用它 —— 三个选项只在这里写一次）。
   */
  @Builder
  languageRows() {
    Column() {
      // ## R90-T5（用户：「将设置里语言弹窗中的 Follow system 改为跟随系统」）
      //
      // ⚠️ 这里**有意偏离上游**，与 R13-21 的取舍相反 —— 前提变了，写清楚：
      // · R13-21（4b-1）当年改成英文 `Follow system`，依据是「上游中文包里
      //  `profile_language_follow_system`（`values-zh-rCN/strings.xml:619`）**本身就是英文**，
      //  语言列表按"语言自称"排版」。那条依据本身没错，但它带来一个副作用：
      //  在一个**全中文**的设置页里，唯一一项是英文 —— 用户直接报了这条。
      // · 上游其实**有两个** key：`profile_follow_system` = 「跟随系统」（真正的中文文案）与
      //  `profile_language_follow_system` = "Follow system"。既然用户要中文，
      //  就取**前者**的文案 —— 这仍然是有据可依的上游文案，不是自己编的。
      // · ⚠️ 本工程 `store/AppPreferences.ets` 的 `languageLabel()` 早就写着「跟随系统」
      //  （行右侧的当前值）⇒ 改完**弹窗与行右侧才一致**（改前是"弹窗英文 / 行中文"的割裂态）。
      this.languageOption(LANGUAGE_SYSTEM, '跟随系统')
      this.flatDivider()
      this.languageOption(LANGUAGE_ENGLISH, 'English')
      this.flatDivider()
      this.languageOption(LANGUAGE_CHINESE, '简体中文')
    }
    .width('100%')
  }

  // ⚠️ R92-T5（P2 收口）：`languagePage()` 已在这里删除 —— 它是 `PAGE_LANGUAGE` 那一整套死代码的
  //  最后一件（R63 把语言入口改成小窗后，再没有 `openSubPage(PAGE_LANGUAGE)` 这样的调用点）。
  //  小窗走的是 `languageWindow()` → `languageRows()`，与它无关；`languageRows()` 完整保留。

  /**
   * R54：**Agent 预设**子页。
   *
   * 每个「设备 · Agent」一张卡：连接器上报的预设目录（单选，勾选即写进「上次选择」记忆，
   * 与对话页同一本 ⇒ 新建对话直接沿用），加一条「刷新目录」（重新发现，见 store 注释）。
   */
  @Builder
  agentPresetPage() {
    Column({ space: Space.M }) {
      // ⚠️ 这里是普通 Text（不是 Markdown 渲染器）：** 不会被加粗，只会原样显示，所以纯文本写。
      Text('预设由 DSH 连接器上报，每个「设备 • Agent」一份。选中的会成为新建对话的默认值；'
        + '在对话页里改预设，同样会写回这里。')
        .fontSize(FontSize.CAPTION)
        .fontColor(muted())
        .width('100%')

      AaErrorBanner({
        message: this.presetError,
        onDismiss: () => {
          this.presetError = '';
        }
      })

      if (this.presetNotice.length > 0) {
        Text(this.presetNotice)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
      }

      if (this.presetLoading) {
        Row({ space: Space.S }) {
          LoadingProgress().width(16).height(16).color(muted())
          // R94：开窗即自动刷新目录 ⇒ 文案从「正在读取…」改成「正在刷新…」更贴合实际在做的事。
          Text('正在刷新 Agent 预设…')
            .fontSize(FontSize.SMALL)
            .fontColor(muted())
        }
        .width('100%')
        .padding(Space.M)
        .alignItems(VerticalAlign.Center)
      } else if (this.presetRows.length === 0) {
        Text(this.presetEmptyText())
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .width('100%')
          .padding(Space.M)
          .borderRadius(CARD_RADIUS)
          .backgroundColor(raisedSurface())
          .borderWidth(1)
          .borderColor(borderColor())
      } else {
        ForEach(this.presetRows, (row: AgentPresetRow) => {
          this.agentPresetDeviceCard(row)
        }, (row: AgentPresetRow) => 'apd:' + row.deviceId + ':' + row.runtimeId + ':' + row.selected
          + ':' + String(row.options.length))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一个「设备 · Agent」的预设卡：**卡头 → 刷新目录 → 预设选项**。
   *
   * ⚠️ R63-F1（真机定点修复）：`刷新目录` 从**卡尾**移到**卡头之下、选项列表之前**。
   * 依据（真机 dump，开发期验证记录）：
   * 978px 高的预设小窗里，卡尾那行的 `刷新目录` Text = `[578,2382][1177,2387]`（**只剩 5px**，
   * 窗底 2387）⇒ 首屏看不到、也点不到。**关键操作必须永远在首屏可视区内**。
   * 上移后它是每张设备卡第一眼就能看到的行（多设备时也是「滚到该卡即见该卡第一行」）。
   */
  @Builder
  agentPresetDeviceCard(row: AgentPresetRow) {
    Column() {
      Row({ space: ROW_GAP }) {
        Column({ space: Space.XXS }) {
          // ⚠️ 分隔号必须用 U+2022（bullet）—— suite-icons 只放行「…/—/•」三个非 ASCII 标点
          //（U+00B7 间隔号会被当成字符图标残留）。
          Text(row.deviceName + ' • ' + row.runtimeName)
            .fontSize(FontSize.ROW_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(ink())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(row.online ? '设备在线 · 目录 ' + String(row.options.length) + ' 项' : '设备离线')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (row.fromMemory) {
          AaChip({ label: '上次使用' })
        }
      }
      .width('100%')
      .padding({ left: Space.L, right: Space.L, top: Space.S, bottom: Space.S })
      .alignItems(VerticalAlign.Center)

      this.flatDivider()

      // ## R94：原「刷新目录」行**已删除**
      // 用户原话：「将设置页的 Agent 预设弹窗中的『刷新目录』删掉，改为每次打开弹窗自动刷新，若失败则提示」。
      // ⇒ 刷新入口从「用户手动点一行」改成「开窗时 store.autoRefresh() 自动跑」，失败经 `presetError`
      //  走弹窗顶部那条 `AaErrorBanner`（见 `agentPresetPage()`）。
      // ⚠️ 过程态（「正在让连接器重新上报…」+ 转圈）**保留** —— 它在 `agentPresetPage()` 的
      //  `presetLoading` / `presetNotice` 分支里，改成自动后用户更需要看见「正在刷新」。
      // ⚠️ R63-F1 的历史结论（「关键操作必须在首屏可视区内」）**仍然有效**：
      //  本行当年从卡尾上移到卡头之下就是为它；现在整行删掉，这条约束自然满足，无需再摆位。

      if (row.options.length === 0) {
        Text('这个连接器没有上报 Agent 预设目录。点上面的「刷新目录」让连接器重新向 DSH 插件要一次。')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
          .padding({ left: Space.L, right: Space.L, top: Space.S, bottom: Space.S })
      } else {
        ForEach(row.options, (option: AgentPresetOption) => {
          AaConfigMenuItem({
            // R94：走显示名口径（内置预设 standard/ptc/minimal/cordis ⇒ 中文名）。
            label: agentPresetLabel(option),
            // ## R93（用户：「设置里的预设，选择时前面用☑️，统一下 ui」＋「去掉预设的描述，只留名字」）
            // 1. **只留名字**：`hideDetail: true` 关掉副标题（`detail` 仍传 —— 组件在
            //  不可用点击时要用它报原因，见下面 `onTap` 里的 `presetNotice`）。
            // 2. **☑️ 已经是本组件既有的选中形态**：`active` ⇒ 右侧 `ICONS['check']` 矢量勾 +
            //  未选中时留 18dp 等宽占位（`Components.ets#AaConfigMenuItem`）—— 与运行时面板
            //  的模型 / 权限两处**同一形态**，不需要另改（用户诉求在预设段本来就是满足的，
            //  真正缺统一的是**会话详情页那处用了字符 `● `** 的旧写法，已在 R93 一并改掉）。
            detail: agentPresetDetail(option),
            hideDetail: true,
            active: row.selected === option.value,
            usable: !option.disabled,
            onTap: () => {
              // 副标题被隐掉后，「为什么不可用」改由提示通道说出来（否则用户只会看到点了没反应）。
              if (option.disabled) {
                this.presetNotice = agentPresetDetail(option).length > 0
                  ? agentPresetDetail(option) : '该预设当前不可用。';
                return;
              }
              this.pickAgentPreset(row, option.value);
            }
          })
        }, (option: AgentPresetOption) => 'apo:' + option.value + ':' + String(option.disabled)
          + ':' + row.selected)
      }
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .clip(true)
  }

  // ## R94：`presetRefreshRow()` 已**整段删除**
  // 它是原「刷新目录」行的构造器（`POST /connectors/{id}/runtimes/discover`）。改自动刷新后不再有调用点，
  // 按工程纪律「删死代码三步（先证伪、再删、留回潮闸门）」整段删除，而不是留一个零引用 Builder。
  // ⚠️ 能力本身**没有消失** —— 挪到了 `AgentPresetStore.autoRefresh()`（开窗时自动跑），
  //  `refreshPresetDevice()` 这个私有转发也就一并成了零引用、同时删除。
  // ⚠️ `presetRefreshingDeviceId` **保留**（自动刷新期间的「正在刷新…」过程态仍要读它）。

  /** 语言三选一的一行（上游 `LanguageRow`：左侧标题 + 右侧 ✓）。 */
  @Builder
  languageOption(mode: string, label: string) {
    Row() {
      Text(label)
        // 上游 `LanguageRow`（`ProfileSettingsDetails.kt:206-214`）：**16.sp / lineHeight 20.sp / SemiBold**。
        // ⚠️ R29 修前是 15sp + Medium + 无行高（文本行框 17.7dp，上游 20dp）。
        .fontSize(FontSize.ROW_TITLE)
        .fontWeight(FontWeight.Bold)
        .lineHeight(20)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
      if (this.languageMode === mode) {
        // 上游 `:216`：`Icon(Lucide.Check, size(20.dp))` —— R29 修前是 16。
        AaIcon({ d: ICONS['check'], iconSize: 20, color: ink() })
      }
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: Space.L, right: Space.L })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.pickLanguage(mode);
    })
  }

  /** 外观三选一的一行（与语言行同构，勾选态读 `this.appearance`）。 */
  // -------------------------------------------------------------------------
  // 选值锚定弹层（R13-22 / 4-3；上游 `ProfileSettingsComponents.kt` 的 `AppearancePopup` /
  // `SidebarViewPopup` + `ProfileDropdown`→`AADropdownMenu`）
  // -------------------------------------------------------------------------

/**
 * 弹层卡片的容器属性（上游 `menuSurface`）：
 * `clip(MenuShape).background(if dark subtle else raisedSurface).border(1.dp, if dark Transparent else border)`，
 * `MenuShape = RoundedCornerShape(18.dp)`；内容纵向内边距 = `MenuVerticalPadding(14) - Material 自带的 8` = **6**。
 *
 * ⚠️ ArkTS 的 `@Builder` **不能**把回调参数当 UI 子节点（`'content()' does not meet UI component syntax`），
 * 所以这段属性在两个菜单里各写一遍，不做「通用外壳」抽象。
 */
/** 外观弹层内容（上游 `AppearancePopup`：跟随系统/浅色/深色，图标 Circle/Sun/Moon）。 */
@Builder
appearanceMenu() {
  Column() {
    AaDropdownMenuItem({
      label: '跟随系统',
      iconName: 'circle',
      active: this.appearance === APPEARANCE_SYSTEM,
      onTap: () => { this.pickAppearance(APPEARANCE_SYSTEM); }
    })
    AaDropdownMenuItem({
      label: '浅色',
      iconName: 'sun',
      active: this.appearance === APPEARANCE_LIGHT,
      onTap: () => { this.pickAppearance(APPEARANCE_LIGHT); }
    })
    AaDropdownMenuItem({
      label: '深色',
      iconName: 'moon',
      active: this.appearance === APPEARANCE_DARK,
      onTap: () => { this.pickAppearance(APPEARANCE_DARK); }
    })
  }
  .width('100%')
  .padding({ top: 6, bottom: 6 })
  .borderRadius(Radius.XL)
  // ⚠️ R86：本节点是 `bindPopup` 的**内容根**，官方材质挂在弹层容器上（见 `appearancePopupOptions()`
  // 的 `systemMaterial:`）；而弹层容器本身是全透明的（`popupColor` 送 `Color.Transparent`）⇒
  // 「底」只有这一个来源，所以底色/描边按 `immersiveMaterialEnabled()` **门控**（与 R85
  // `Components#customDialogGeometry()` 完全同构）：
  //  · 材质可用 ⇒ 送 `Color.Transparent` / `borderWidth 0` ⇒ 本节点**零自绘层**，官方材质接管
  //  background / border / shadow / blur（SDK `common.d.ts:22625-22633`；契约 §1.2 / §1.8，
  //  A/B 可归因性不受损）；
  //  · 材质不可用（设备不支持 / 探针 false / 未来关档）⇒ **逐字回到 R86 前的自绘底**（不透明
  //  `raised_surface` + 1vp 描边）⇒ 面板不会变成「文字浮在正文上」的空壳。
  //  几何（宽 / 内边距 / 圆角 / 子节点）一个字未动（契约 §1.4）。
  //
  // ⚠️ R86 真机 A/B：本节点是 `R86_APPEARANCE_MATERIAL_PROBE` 的**另一个绑点** —— 该常量与
  //  `immersiveMaterialEnabled()` 取与，`false` 档（对照包）即走下面的自绘玻璃分支，与
  //  `appearancePopupOptions()` 的 `Material.empty` 严格同步 ⇒ 两包只差一个常量。
  //
  // ⚠️ 与 R59（glass-ball）实验开关的关系：`MATERIAL_PROBE_MODE` / `probeMaterial()` **语义未动**
  //  （档 0 仍返回 `Material.empty`，仍是交付默认；下面那行 `.systemMaterial(probeMaterial())` 原样保留）。
  //  只是「底色归谁画」从「实验常量」改成「可用性探针」：档 0 在材质可用时底色也交给官方材质，
  //  档 1 仍会在本节点额外挂一层 THIN 材质 ⇒ 实验剩下「挂不挂材质」这一个变量。
  // ⚠️ 回退：删掉 `appearancePopupOptions()` 里的 `systemMaterial:` 行即回到 R86 前行为
  //  （门控在材质不可用分支下与 R86 前逐字一致；彻底回退 = `%TEMP%/aa-hm-r86-before/SettingsScreen.ets`，契约 §6）。
  .backgroundColor((R86_APPEARANCE_MATERIAL_PROBE && immersiveMaterialEnabled())
    ? Color.Transparent : $r('app.color.raised_surface'))
  .borderWidth((R86_APPEARANCE_MATERIAL_PROBE && immersiveMaterialEnabled()) ? 0 : StrokeWidth.HAIRLINE)
  .borderColor((R86_APPEARANCE_MATERIAL_PROBE && immersiveMaterialEnabled())
    ? Color.Transparent : borderColor())
  .clip(true)
  .systemMaterial(probeMaterial())
}

  /** 侧边栏显示弹层内容（上游 `SidebarViewPopup`：项目视图/会话视图，图标 Folder/List）。 */
  @Builder
  sidebarMenu() {
    Column() {
      AaDropdownMenuItem({
        label: '项目视图',
        iconName: 'folder',
        active: this.sidebarView === SIDEBAR_VIEW_PROJECT,
        onTap: () => { this.pickSidebarView(SIDEBAR_VIEW_PROJECT); }
      })
      AaDropdownMenuItem({
        label: '会话视图',
        iconName: 'list',
        active: this.sidebarView === SIDEBAR_VIEW_SESSION,
        onTap: () => { this.pickSidebarView(SIDEBAR_VIEW_SESSION); }
      })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .borderRadius(Radius.XL)
    // R86：同 `appearanceMenu()` —— 内容根的底/描边按 `immersiveMaterialEnabled()` **门控**
    //（材质可用 ⇒ 透明 + 0 描边，官方材质接管这四层，SDK `common.d.ts:22625-22633`，契约 §1.2/§1.8；
    // 不可用 ⇒ 逐字回到 R86 前的不透明 `raised_surface` + 1vp 描边，面板不会变空壳）。
    // 底由 `sidebarPopupOptions()` 下发的 `systemMaterial: dialogMaterial()` 承担。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : $r('app.color.raised_surface'))
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .clip(true)
  }

  /** 外观弹层参数。逐项对齐 R13-9 已验证的那一套（首页筛选/项目弹窗，见 `HomeScreen.ets` 的注释）。 */
  private appearancePopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.appearanceMenu();
      },
      placement: Placement.BottomRight,
      targetSpace: DROPDOWN_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_WIDTH,
      radius: Radius.XL,
      /**
       * R86：弹层**容器**改挂官方沉浸光感（`CustomPopupOptions.systemMaterial`）。
       * 本页四处弹层（外观 / 侧边栏 / 语言 / Agent 预设）同款，各自写在本文档块里，口径一致。
       *
       * · 官方依据：SDK `common.d.ts:14406`（`CustomPopupOptions.systemMaterial?: SystemUiMaterial`，
       *  接口归属 :13866；`SystemUiMaterial` = `uiMaterial.Material`，:16964）。
       * · 生效范围判定：**`bindPopup` 属「弹窗类接口」**，按官方 OS 平台行为变更（仅对
       *  `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）在**页面内全部区域**生效 ——
       *  本弹层锚在设置页滚动卡片上，仍属生效范围（`坑 245`）。
       * · 关闭姿势：`dialogMaterial()` 在探针不可用时返回 `uiMaterial.Material.empty`（= disable，
       *  `uiMaterial.d.ts:467-472`），**绝不传 `undefined`**（那个语义是「恢复组件默认材质」，`坑 256`）。
       * · R86 真机 A/B：本处是 `R86_APPEARANCE_MATERIAL_PROBE` 的**唯一绑点之一**（另一处是
       *  `appearanceMenu()` 的内容根门控）—— `true` = 交付档（下发 `dialogMaterial()`）；
       *  `false` = 对照包（显式 `Material.empty`，内容根同时回到自绘玻璃）⇒ 两包只差这一个常量。
       */
      systemMaterial: R86_APPEARANCE_MATERIAL_PROBE ? dialogMaterial() : uiMaterial.Material.empty,
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.appearanceOpen = false;
        }
      }
    };
  }

  /** 侧边栏显示弹层参数（同上）。 */
  private sidebarPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.sidebarMenu();
      },
      placement: Placement.BottomRight,
      targetSpace: DROPDOWN_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_WIDTH,
      radius: Radius.XL,
      // R86：同 `appearancePopupOptions()` —— `bindPopup` = 弹窗类接口 ⇒ 页面内全部区域生效
      //（SDK `common.d.ts:14406`；`坑 245`）；关闭姿势 = `Material.empty`（`uiMaterial.d.ts:467-472`）。
      systemMaterial: dialogMaterial(),
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.sidebarOpen = false;
        }
      }
    };
  }

  // -------------------------------------------------------------------------
  // R63：语言 / Agent 预设的**小窗**（点入口卡后在当前页展开，不再整页切子页）
  // -------------------------------------------------------------------------

  /**
   * 「语言」小窗：跟随系统 / English / 简体中文 三选一，当前项打勾；点选即写偏好并关闭。
   *
   * **形态选型 = ① `bindPopup` + `CustomPopupOptions`**（不是根 `Stack` 里的 `if` 浮层），三条理由：
   *  ① 本工程「小窗 / 就地弹层」的既有实现**全部**走 `bindPopup`（首页筛选菜单、项目动作卡、
   *  会话「⋯」小窗，加上本页的外观/侧边栏共 10 处）⇒ 同一套心智与**已验证**的参数组合；
   *  `autoCancel` + 透明遮罩天然实现「点小窗外即关」，**不必**再往 `Stack` 里加一个铺满的兄弟容器
   *  去抢命中面（坑 151 / 坑 29：铺满的兄弟容器会静默吃掉下层点击）。
   *  ② **不动 `build()` 的 `Column` / `Scroll` 结构** ⇒ 根页滚动位置与 R13 F-10 的
   *  `.align(Alignment.Top)`、抽屉形态、独立页面入口（`SettingsScreen` → `SettingsContent({ drawer: false })`）
   *  都不受影响。
   *  ③ 开关是 `@State boolean`，同时被 `bindPopup` 的第一个参数与 `onStateChange` 收敛（坑 137：
   *  开关类型不对会「永不弹出、且编译不报错」）。
   *
   * ⚠️ **R86 改口径**：底的归属改为**门控** —— 材质可用时本 Builder（`bindPopup` 的**内容根**，
   *  弹窗类接口在官方生效范围内，`坑 245`）零自绘层、由 `languagePopupOptions()` 下发的
   *  `systemMaterial: dialogMaterial()` 接管；探针不可用时**逐字回到** R86 前的
   *  `glassPanelSurface()` + `GLASS_PANEL_BLUR` + `appShadow()` 自绘玻璃（可用性回退，
   *  与 R85 `customDialogGeometry()` 同构）。判据：材质优先于 background/blur/shadow/border
   *  （SDK `common.d.ts:22625-22633`；契约 §1.2/§1.8 的「不共存」只在材质可用分支成立）。
   * ⚠️ 内容里的 `this.languageMode` 是**直接读 @State**（不是 Builder 值参数）—— 读时登记元素级依赖，
   *  勾选态才会当场跟着变（坑 134 / 坑 38）。
   *
   * ⚠️ **本机（Windows）无法渲染 ArkUI，以下两点只能上设备确认**（已在交付说明里登记）：
   *  ① 挂点在 `Scroll` 里的卡片上，弹层位置由 ArkUI 按 `Placement.BottomRight` 自适应 ——
   *  卡片滚到视口底部时，希望框架自动翻到上方；若被屏幕裁掉，改成 `Placement.Top` 即可；
   *  ② 语言小窗 3 行 × 56vp = 168vp，恒小于限高（`Control.MENU_MAX_HEIGHT`）的观感上限，
   *  无需滚动容器（原判据写的是 `GLASS_PANEL_BLUR` 面板，改用官方材质后该令牌已退场）。
   */
  @Builder
  languageWindow() {
    Column() {
      this.languageRows()
    }
    .width('100%')
    // R86：本节点是 `bindPopup` 的**内容根**（材质挂在弹层容器上，见 `languagePopupOptions()`），
    // 而弹层容器本身全透明（`popupColor` 送 `Color.Transparent`，不上任何容器底）⇒「底」只有这一个来源，故四层自绘
    // 玻璃按 `immersiveMaterialEnabled()` **门控**（与 R85 `Components#customDialogGeometry()` 同构）：
    //  · 材质可用 ⇒ 透明底 + 零模糊 + 0 描边 + 零投影 ⇒ 本节点**零自绘层**，官方材质接管
    //  background / blur / shadow / border（SDK `common.d.ts:22625-22633`；契约 §1.2 / §1.8）；
    //  · 材质不可用 ⇒ **逐字回到 R86 前的自绘玻璃**（`glassPanelSurface()` + `GLASS_PANEL_BLUR`/
    //  `GLASS_SATURATION`/`GLASS_BRIGHTNESS` + 1vp 描边 + `Shadow.PILL`/`appShadow()` 投影），
    //  面板不会退化成空壳。
    //  几何（宽 / 圆角 / 子节点）未动（契约 §1.4）。
    // ⚠️ 回退：删掉 `languagePopupOptions()` 里的 `systemMaterial:` 行即回到 R86 前行为（材质不可用
    //  分支与 R86 前逐字一致）；彻底回退 = `%TEMP%/aa-hm-r86-before/SettingsScreen.ets`（契约 §6）。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : glassPanelSurface())
    .backgroundEffect(immersiveMaterialEnabled() ? { radius: 0 } : {
      radius: GLASS_PANEL_BLUR,
      saturation: GLASS_SATURATION,
      brightness: GLASS_BRIGHTNESS,
      color: glassPanelSurface()
    })
    .borderRadius(Radius.XL)
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .shadow(immersiveMaterialEnabled()
      ? { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 }
      : { radius: Shadow.PILL, color: appShadow(), offsetX: 0, offsetY: Space.XXS })
    .clip(true)
  }

  /**
   * 「Agent 预设」小窗：内容**原样复用** `agentPresetPage()` ——
   * 每「设备 • Agent」一张预设卡、单选写回、加载态 / 空态 / 错误横幅 / notice 全部保留
   * （数据源仍是 `presetRows / presetLoading / presetRefreshingDeviceId / presetError / presetNotice`，
   * 与子页共用同一份内容）。
   *
   * ⚠️ R94：**开窗时自动刷新**（`autoRefreshPresets()`，见入口卡 onClick）—— 本 Builder 自己不发请求，
   *  它只负责把 store 的快照画出来；失败经 `presetError` 走这里的错误横幅。
   *
   * ⚠️ `Scroll` 是硬要求（EXPERIENCE §62.3）：限高容器里裸 `Column` + `constraintSize(maxHeight)`
   *  会被**直接裁掉且完全滚不动**；圆角必须留在**滚动容器**上，否则内容滚出边界时会被圆角切到。
   *  （R86 起底色/描边按 `immersiveMaterialEnabled()` 门控：材质可用时让位给官方材质、不可用时
   *  逐字回到自绘玻璃 —— 见 `agentPresetWindow()` 本体与 `agentPresetPopupOptions()`；
   *  裁切语义只依赖圆角 + `clip(true)`，两者都保留。）
   * ⚠️ 小窗开着时 `presetLoading / presetRefreshingDeviceId / presetRows` 都会变（开窗自动刷新、单选写回），
   *  这些值都在本 Builder 内以 `this.xxx` 直接读 ⇒ 读时登记依赖、当场重绘（坑 134）。
   */
  @Builder
  agentPresetWindow() {
    Scroll() {
      Column() {
        this.agentPresetPage()
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })
    .scrollBar(BarState.Off)
    // ⚠️ `align` 是通用属性，默认值是 `Alignment.Center` ⇒ 内容比视口短时会被垂直居中
    //（R13 F-10 的根因；`suite-scroll-align` 对全工程每一处 Scroll 都有硬断言）。
    .align(Alignment.Top)
    /**
     * ⚠️ R63-F1（真机定点修复）：**小窗内任意位置的点击都不能关窗**。
     *
     * 真机实测（开发期验证记录 §5.3）：小窗内容高于限高时，
     * 最底下一行被 `Scroll` 的 clip 切剩一条 sliver（`刷新目录` Text `[578,2382][1177,2387]` = 5px）；
     * 点这条 sliver **既没落到该行、也没有任何窗内节点消费** ⇒ 事件落到弹层的「窗外」判定上，
     * **直接把小窗关掉**（同一个点落在**完整可见**的行上则正常工作：见 10:33:30 那 12 帧，
     * 点中刷新行后 notice「正在让连接器重新上报…」+ 错误横幅「connector is offline」出现、窗仍开着）。
     *
     * 这里给滚动容器挂一个**空 `onClick`**：窗内任何位置至少有它消费，⇒ 只有点**窗外**的遮罩才关窗。
     * ⚠️ 不能用 `hitTestBehavior(HitTestMode.Block)` 代替 —— 那个连子节点一起挡（坑 61），
     *  预设行与刷新行会全部点不动。
     */
    .onClick(() => {
      // 故意留空：只为消费「落在窗内但没命中可点子控件」的点击。
    })
    /**
     * ⚠️ 底部内边距 = `Space.L`(16)：**「最后一行不贴窗底」的唯一可靠手段** —— 滚到底时
     * 最后一行的下沿距离窗底恰好等于它（真机上「行贴窗底只剩 5px」正是这条缺失时的样子）。
     * 只把 `maxHeight` 减一点做不到这件事：视口高度永远会对某一行半切（行高 48/56 不是视口高度的因子）。
     */
    .padding({ left: Space.M, right: Space.M, top: Space.M, bottom: Space.L })
    // R86：同 `languageWindow()` —— 内容根的**自绘玻璃按 `immersiveMaterialEnabled()` 门控**
    //（材质可用 ⇒ 透明底 + 零模糊 + 0 描边 + 零投影，底交给 `agentPresetPopupOptions()` 下发的
    // 官方材质，SDK `common.d.ts:22625-22633`，契约 §1.2/§1.8；不可用 ⇒ 逐字回到 R86 前的
    // `glassPanelSurface()` + 模糊 + 1vp 描边 + `appShadow()` 投影，面板不会变空壳）。
    // ⚠️ 圆角 / 底色 / 描边原本留在**滚动容器**上是为了「内容滚出边界不被圆角切到」（EXPERIENCE §62.3）
    //  —— 圆角与 `clip(true)` 仍在，裁切语义不变。
    // ⚠️ 回退：删掉 `agentPresetPopupOptions()` 的 `systemMaterial:` 行即回到 R86 前行为
    //（`%TEMP%/aa-hm-r86-before/SettingsScreen.ets`，契约 §6）。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : glassPanelSurface())
    .backgroundEffect(immersiveMaterialEnabled() ? { radius: 0 } : {
      radius: GLASS_PANEL_BLUR,
      saturation: GLASS_SATURATION,
      brightness: GLASS_BRIGHTNESS,
      color: glassPanelSurface()
    })
    .borderRadius(Radius.XL)
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .shadow(immersiveMaterialEnabled()
      ? { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 }
      : { radius: Shadow.PILL, color: appShadow(), offsetX: 0, offsetY: Space.XXS })
    .clip(true)
  }

  /**
   * 语言小窗参数（与 `appearancePopupOptions()` / `sidebarPopupOptions()` 同一套）：
   * 透明遮罩 + `autoCancel` ⇒ 点小窗外的区域即关；容器全透明，卡片由 `languageWindow()` 自己画。
   */
  private languagePopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.languageWindow();
      },
      placement: Placement.BottomRight,
      targetSpace: DROPDOWN_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_WIDTH,
      radius: Radius.XL,
      // R86：同 `appearancePopupOptions()` —— `bindPopup` = 弹窗类接口 ⇒ 页面内全部区域生效
      //（SDK `common.d.ts:14406`；`坑 245`）；关闭姿势 = `Material.empty`（`uiMaterial.d.ts:467-472`）。
      systemMaterial: dialogMaterial(),
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.languageOpen = false;
        }
      }
    };
  }

  /**
   * Agent 预设小窗参数（同上）。
   *
   * ⚠️ 宽度取 `Control.MENU_WIDTH`(286)：与两处菜单同宽。每张预设卡是「设备名 • Agent 名 + 目录项 +
   * 刷新目录行」，长名走卡片自己的 `TextOverflow.Ellipsis`，与改前子页同一口径。
   */
  private agentPresetPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.agentPresetWindow();
      },
      placement: Placement.BottomRight,
      targetSpace: DROPDOWN_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_WIDTH,
      radius: Radius.XL,
      // R86：同 `appearancePopupOptions()` —— `bindPopup` = 弹窗类接口 ⇒ 页面内全部区域生效
      //（SDK `common.d.ts:14406`；`坑 245`）；关闭姿势 = `Material.empty`（`uiMaterial.d.ts:467-472`）。
      systemMaterial: dialogMaterial(),
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.agentPresetOpen = false;
        }
      }
    };
  }

  // -------------------------------------------------------------------------
  // 小块拼装
  // -------------------------------------------------------------------------

  /**
   * 行首图标槽（上游 `ProfileSettingsComponents.kt:248` 的 `SettingIcon`：**34dp 槽 + 22dp 图标**，居中）。
   *
   * ⚠️ R12-8 把图标尺寸从历史的 `18` 改成上游的 **22** —— 原来注释写 22、代码却是 18，两者不一致；
   * 本轮既然要按 R12-7 修正坐标空间（图标墨迹会从 ~18px 变成 ~53px），就一并对齐上游的 22dp，
   * 而不是把注释改小去迁就代码。槽宽 `ICON_SIZE`(34) 与行高 `ROW_HEIGHT` 都不变，22 仍有余量。
   */
  @Builder
  rowIcon(name: string, tint: Resource) {
    Column() {
      AaIcon({ d: ICONS[name], iconSize: 22, color: tint })
    }
    .width(ICON_SIZE)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 卡片内分割线（对应上游 `ProfileDivider(start = 57.dp, end = 12.dp)`：给「图标 + 标题」行用）。 */
  @Builder
  rowDivider() {
    Divider()
      .color(borderColor())
      .strokeWidth(1)
      .margin({ left: DIVIDER_START, right: Space.M })
  }

  /** 无图标行之间的分割线（上游 `ProfileDivider(start = 12.dp, end = 12.dp)`：语言三选一与资料卡）。 */
  @Builder
  flatDivider() {
    Divider()
      .color(borderColor())
      .strokeWidth(1)
      .margin({ left: Space.M, right: Space.M })
  }

  // -------------------------------------------------------------------------
  // R54：「Agent 预设」子页的数据编排（store → @State 快照）
  // -------------------------------------------------------------------------

  /** store → @State 快照（build 只读 @State）。 */
  private syncPresetState(): void {
    const store = AgentPresetStore.get();
    this.presetRows = store.rows.slice();
    this.presetLoading = store.loading;
    this.presetRefreshingDeviceId = store.refreshingDeviceId;
    this.presetError = store.error;
    this.presetNotice = store.notice;
  }

  /**
   * 开窗时的**自动刷新**（R94）。
   *
   * 取代了原来的 `loadPresets()`（只读快照）与「刷新目录」行（手动重新发现）：
   * `store.autoRefresh()` 内部先 `load()`、再逐台在线设备 `refreshDevice()`，
   * 失败原因写在 `store.error` ⇒ `syncPresetState()` 拷进 `presetError` ⇒ 弹窗顶部横幅显示。
   *
   * ⚠️ `catch` 仍要 `syncPresetState()`：`autoRefresh()` 内部已 try/catch 兜住单台失败，
   *  但万一有未预期的 rejection，也要让界面拿到**当前**状态而不是停在转圈上。
   */
  private autoRefreshPresets(): void {
    AgentPresetStore.get().autoRefresh().then(() => {
      this.syncPresetState();
    }).catch(() => {
      this.syncPresetState();
    });
  }

  private pickAgentPreset(row: AgentPresetRow, value: string): void {
    AgentPresetStore.get().select(row, value);
    this.syncPresetState();
  }

  /**
   * 卡右侧的摘要（R94 改）：显示**当前选中的预设名**，不再显示「N 个 Agent」。
   *
   * 用户原话：「agent预设的横条右边也改为显示当前选择的预设名，而不是"1个Agent"」。
   *
   * 口径：
   *  · 单选一处（本工程每个「设备 • Agent」一份预设，通常只有一行）⇒ 取第一行的 `selected`；
   *  · 还没读到目录 / 没选中 ⇒ **不占位**（返回空串，与改前一致）；
   *  · 名字走 `agentPresetRowValue()` ⇒ 内置预设显示中文名，且与选项列表里的字**逐字一致**。
   */
   private presetSummary(): string {
    if (this.presetLoading || this.presetRows.length === 0) {
      return '';
    }
    const first = this.presetRows[0];
    if (first.selected.length === 0) {
      return '';
    }
    return agentPresetRowValue(first.options, first.selected);
  }

  /** 空态文案（区分「没有设备」/「设备上没有 DSH Agent」/「还在读」）。 */
  private presetEmptyText(): string {
    if (this.presetRows.length === 0) {
      return this.presetNotice.length > 0
        ? this.presetNotice
        : '还没有可选的 Agent 预设。请先在设备上安装并启动 DSH（DeepSeek Harness），再回来刷新。';
    }
    return '';
  }

  // -------------------------------------------------------------------------
  // 行为
  // -------------------------------------------------------------------------

  private titleText(): string {
    if (this.page === PAGE_ACCOUNT) {
      return '账号';
    }
    if (this.page === PAGE_AGENT_PRESET) {
      return 'Agent 预设';
    }
    return '设置';
  }

  /** 左上角「‹」：子页回根页；根页退出（抽屉形态 = 关抽屉，页面形态 = 退出路由）。 */
  private goBack(): void {
    if (this.page === PAGE_ROOT) {
      this.exitRoot();
      return;
    }
    this.page = PAGE_ROOT;
  }

  /**
   * 根页的「退出」（上游 `ProfileHeader(onClose = onClose)`）：
   *  - 抽屉形态：调 `onClose()` 让首页把抽屉收起来（上游 `onClose = { onProfileOpenChange(false) }`）；
   *  - 独立页面形态：`Router.pop()`，与 task-9 完全一致。
   */
  private exitRoot(): void {
    if (this.drawer) {
      // 抽屉形态：只关抽屉，**绝不 pop 路由** —— 抽屉不是路由页，pop 会把首页弹掉。
      if (this.onClose !== undefined) {
        this.onClose();
      }
      return;
    }
    Router.pop();
  }

  /**
   * 系统返回键的消费逻辑（逐级返回，对齐上游 `BackHandler`）：
   *  ① 展开着的三选区、以及 R63 的两个小窗先收起；
   *  ② 非根页 → 回根页；
   *  ③ **根页必须 return false** —— 本页不再消费，交回 `pages/Index.ets` 的 `Router.pop()`。
   * 第 ③ 条是硬要求：根页返回 false 才能让「设置页按返回键回上级页面」继续成立。
   */
  private consumeBack(): boolean {
    // 已销毁（理论上注销已生效，这里是双保险）：不消费，交回路由栈
    if (!this.alive) {
      return false;
    }
    if (this.appearanceOpen) {
      this.appearanceOpen = false;
      return true;
    }
    if (this.sidebarOpen) {
      this.sidebarOpen = false;
      return true;
    }
    // R63：开着的小窗先关 —— 返回键行为不退化（小窗开着时按返回只关窗，不退出设置页）
    if (this.languageOpen) {
      this.languageOpen = false;
      return true;
    }
    if (this.agentPresetOpen) {
      this.agentPresetOpen = false;
      return true;
    }
    if (this.page !== PAGE_ROOT) {
      this.page = PAGE_ROOT;
      return true;
    }
    if (this.drawer) {
      // 抽屉形态：上游 `BackHandler(enabled = open) { … else onClose() }` —— 根页再按返回键就关抽屉。
      // 这里的 `true`（消费）与 onClose 是否接上无关：抽屉不是路由页，漏接时也必须吞掉这次返回，
      // 否则会走到根页面的 `Router.pop()` 把首页弹掉。
      if (this.onClose !== undefined) {
        this.onClose();
      }
      return true;
    }
    // 页面形态的根页：不消费，交回 `pages/Index.ets` 的 `Router.pop()`
    return false;
  }

  /**
   * 进入子页；顺手收起两个展开区 ——
   * 不收起的话在子页按返回键会先「收起一个看不见的展开区」，用户要按两次才能回根页。
   */
  private openSubPage(page: string): void {
    this.appearanceOpen = false;
    this.sidebarOpen = false;
    this.page = page;
  }

  private accountLabelText(): string {
    return accountLabel(this.snap.displayName, this.snap.email);
  }

  private avatarText(): string {
    return avatarLetter(this.accountLabelText());
  }

  private appearanceLabelText(): string {
    if (this.appearance === APPEARANCE_LIGHT) {
      return '浅色';
    }
    if (this.appearance === APPEARANCE_DARK) {
      return '深色';
    }
    return '系统';
  }

  private updateStatusText(): string {
    return updateStatusLabel(this.updateStatus, this.updateDetail);
  }

  private updateStatusColor(): Resource {
    const tone = updateStatusTone(this.updateStatus);
    if (tone === 'warning') {
      return $r('app.color.notice_warning');
    }
    if (tone === 'error') {
      return $r('app.color.error_text');
    }
    if (tone === 'success') {
      return $r('app.color.notice_success');
    }
    return $r('app.color.muted');
  }

  private pickAppearance(mode: string): void {
    AppearanceController.set(mode);
    this.appearance = mode;
    this.appearanceOpen = false;
  }

  /**
   * 选语言：只落偏好（`AppPreferences` → `AppStorage['aaLanguage']` → `PersistentStorage`）。
   * 应用内文案本轮不切换（英文资源目录为空，见本轮简报），所以这里不刷新页面。
   */
  private pickLanguage(mode: string): void {
    AppPreferences.get().setLanguage(mode);
    this.languageMode = AppPreferences.get().language;
    // R63：语言小窗「点选后写偏好并关闭」（与 pickAppearance / pickSidebarView 同一套）
    this.languageOpen = false;
  }

  /** 选侧边栏显示：写的是 AppStorage，首页的 `@StorageLink('aaSidebarView')` 会立刻联动。 */
  private pickSidebarView(mode: string): void {
    AppPreferences.get().setSidebarView(mode);
    this.sidebarView = AppPreferences.get().sidebarView;
    this.sidebarOpen = false;
  }

  /**
   * 退出登录二次确认（上游 `ProfileSettingsDialogs.kt:78-91` 的 `ConfirmSignOutDialog`）。
   *
   * R13-14：系统 `showAlertDialog` 换成**自绘**框；这一处走 `profile` 几何族
   * （上游 `ProfileDialog`：`fillMaxWidth` / 圆角 20 / 内边距 18 / 标题 20sp SemiBold / 按钮 46·14dp），
   * 与设备确认框那一族（380 上限 / 26 / 22 / 24sp / 50·16dp）不是同一套数值。
   */
  /**
   * 退出登录确认框的**内容**。
   *
   * ⚠️ R13-19（真机/模拟器实测崩溃）：这个内容**必须是 `@Builder` 方法**，
   * 不能在传给 `openCustomDialog` 的箭头函数里直接写 `AaConfirmDialog({...})` ——
   * 那样编译器不会把它转成组件构造，运行期抛
   * `TypeError: class constructor cannot called without 'new'`，
   * **整个应用进程当场死亡**（`jscrash` 日志栈顶正是本文件原第 1209 行）。
   * 同工程的 `DeviceDetailScreen.confirmDialogCard()` 一直是对的，本处漏了。
   */
  @Builder
  signOutDialogCard() {
    AaConfirmDialog({
      variant: DIALOG_VARIANT_PROFILE,
      title: '退出登录？',
      body: '退出后需要重新登录才能继续使用此服务器。',
      confirmLabel: '退出',
      onConfirm: () => {
        this.closeSignOutDialog();
        this.signOut();
      },
      onDismiss: () => {
        this.closeSignOutDialog();
      }
    })
  }

  private confirmSignOut(): void {
    try {
      openAaConfirmDialog(this.getUIContext(), () => {
        this.signOutDialogCard()
      }, DIALOG_VARIANT_PROFILE)
        .then((id: number) => {
          this.signOutDialogId = id;
        })
        .catch(() => {
          // 弹层起不来不能什么都不做：用户点了「退出登录」必须真的退出。
          this.signOut();
        });
    } catch (error) {
      this.signOut();
    }
  }

  private closeSignOutDialog(): void {
    const id = this.signOutDialogId;
    this.signOutDialogId = 0;
    closeAaConfirmDialog(this.getUIContext(), id);
  }

  /**
   * 退出登录。
   * `authController.logout()` 会触发根页面（`pages/Index.ets`）的 `syncRootRoute()`，
   * 它负责 `DashboardStore.stopRealtime()` 并把路由重置回登录页 —— 本页不必重复做。
   */
  private signOut(): void {
    authController.logout();
  }

  /** 与服务端 `/health` 的 version 比对（逐段数值比较，同 Android `compareUpdateVersions`）。 */
  private async checkUpdate(): Promise<void> {
    if (this.updateStatus === UPDATE_CHECKING) {
      return;
    }
    this.updateStatus = UPDATE_CHECKING;
    this.updateDetail = '';
    this.localError = '';
    try {
      const serverUrl = this.snap.serverUrl;
      const health = await AppServices.get().client.getJson(serverUrl, '/health') as Record<string, Object>;
      const latest = typeof health['version'] === 'string' ? health['version'] as string : '';
      if (latest.length === 0) {
        this.updateStatus = UPDATE_FAILED;
        this.localError = '服务器没有返回版本号。';
        return;
      }
      const comparison = compareVersions(latest, APP_VERSION_NAME);
      if (comparison === undefined) {
        this.updateStatus = UPDATE_FAILED;
        this.localError = '版本号格式无法比较。';
      } else if (comparison <= 0) {
        this.updateStatus = UPDATE_LATEST;
      } else {
        this.updateStatus = UPDATE_AVAILABLE;
        this.updateDetail = '服务端 ' + latest;
      }
    } catch (error) {
      this.updateStatus = UPDATE_FAILED;
      this.localError = error instanceof Error ? (error as Error).message : String(error);
    }
  }
}

// ---------------------------------------------------------------------------
// 两种宿主（内容都是上面的 SettingsContent）
// ---------------------------------------------------------------------------

/**
 * 独立页面形态（`pages/Index.ets` 的 `Route.SETTINGS` 分支调用）。
 *
 * ⚠️ **本轮保留这个入口**：抽屉化之后它仍然可用（内容与抽屉共用 `SettingsContent`），
 * 行为与 task-9/task-11 完全一致 —— 根页「‹」= `Router.pop()`，系统返回键在根页不消费（交回路由栈）。
 * 保留的另一个原因：其它调用点（首页「我的」tab 的「设置与外观」按钮）不会因此断掉。
 */
@Component
export struct SettingsScreen {
  build() {
    SettingsContent({ drawer: false })
  }
}

/**
 * 抽屉形态（对应安卓 `ui/screens/profile/ProfileSettingsDrawer.kt`）。
 *
 * 对外接口固定为 `@Prop open` + `onClose?`：首页用 `@State` 控制 `open`、
 * 把本组件内嵌在首页的 `Stack` 上层即可（Lead 已把接口同步给首页包 home-ui）。
 *
 * **形态依据（照上游源码，不是「窄侧栏 + 圆角 + 阴影」那种抽屉）**：
 *  - `ProfileSettingsDrawer.kt:145-148`：`AnimatedVisibility(enter = slideInHorizontally(initialOffsetX = { -it }) + fadeIn(),
 *  exit = slideOutHorizontally(targetOffsetX = { -it }) + fadeOut())` ⇒ **从左滑入 + 淡入**，位移量 = 自身宽度；
 *  - `:150-153`：`Box(Modifier.fillMaxSize().background(profilePageBackground(colors)))`
 *  ⇒ **铺满全屏、无圆角、无阴影、无独立遮罩**（面板自己铺满，遮罩无处可见；也正因此它天然拦住首页的点击）；
 *  - `:155-161`：`LazyColumn(... .statusBarsPadding().padding(horizontal = 18.dp),
 *  contentPadding = PaddingValues(top = 0.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp))`
 *  ⇒ 18 / 28 / 10 三个数值已落到 `Space.PAGE` / `Space.PAGE_BOTTOM` / `Space.S_PLUS`（dp→vp 1:1）。
 *
 * ⚠️ 滑入动画的生效条件：ArkUI 的 `transition` 只在「组件插入/删除发生在 `animateTo` 闭包内」时补间。
 * 首页写成 `animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => { this.settingsOpen = true; })` 就能看到滑入；
 * 直接赋值则瞬时出现（功能不受影响）。
 * ⚠️ 不用 `bindSheet` 实现：同一个页面只允许一个 `bindSheet`（EXPERIENCE §34），首页已有 sheet 用途。
 */
@Component
export struct SettingsDrawerPanel {
  @Prop open: boolean = false;
  onClose?: () => void;

  build() {
    // 关闭态**完全卸载**：这层是铺满的，留在树上会一直挡住首页的点击；
    // 卸载同时让内部的返回键消费者随 aboutToDisappear 注销（见 SettingsContent）。
    if (this.open) {
      Column() {
        SettingsContent({ drawer: true, onClose: this.onClose })
      }
      .width('100%')
      .height('100%')
      // 上游 `Box(Modifier.fillMaxSize().background(profilePageBackground(colors)))`（:150-153）
      .backgroundColor($r('app.color.profile_page_surface'))
      // 上游 `initialOffsetX = { -it }`：位移量取自身宽度（-100%），不是拍脑袋的像素值
      .transition(TransitionEffect.translate({ x: '-100%' })
        .combine(TransitionEffect.OPACITY)
        .animation({ duration: DRAWER_ANIM_MS, curve: Curve.FastOutSlowIn }))
    }
  }
}


