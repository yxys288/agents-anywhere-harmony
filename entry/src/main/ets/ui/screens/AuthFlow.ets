/**
 * 登录流程的**纯逻辑**（状态机 / 文案 / 数值契约）—— 零 ArkUI、零 import，可直接进 Node 自测。
 *
 * 为什么要单独一个文件：四屏（LoginMethods / ServerSetup / QrLogin / QrWaiting）的**数值与分支**
 * 是这一轮最容易做错的部分（上游实现 四条易错点全部是数值与分支），
 * 放在渲染层里就只能"看代码"、不能断assert。这里把它们抽成纯常量 + 纯函数，
 * `tools/logic-test/suite-login.mjs` 直接转译本文件跑断言。
 *
 * 数值口径（施工图 §0.1）：Android `N.dp` → HarmonyOS `N`(vp)、`N.sp` → `N`(fp)，**1:1 不乘 density**；
 * 小数照抄（15.3 / 13.6 / 12.6 / 12.5 / 22.5 不四舍五入）。
 *
 * 锚文：`android/.../ui/screens/auth/AuthScreens.kt` + `WebLoginScreen.kt` + `QrAuthScreens.kt`。
 */

/**
 * 步骤（对应上游四个目的地 + 本工程保留的原生密码表单）。
 *
 * - METHODS = `AppDestination.LoginMethods`（根，无返回钮）
 * - SERVER_SETUP= `AppDestination.ServerSetup`（= WebLoginHostScreen: HostChoice + SelfHostLoginForm）
 * - QR_LOGIN = `AppDestination.QrLogin`
 * - QR_WAITING = `AppDestination.QrWaiting`
 * - PASSWORD = 上游没有独立目的地（它走 EmbeddedWebLogin），
 *  本工程第八轮已上线的**原生密码/注册表单**挂在这一步（既有能力不得回归）。
 */
export class LoginStep {
  static readonly METHODS: string = 'methods';
  static readonly SERVER_SETUP: string = 'serverSetup';
  static readonly QR_LOGIN: string = 'qrLogin';
  static readonly QR_WAITING: string = 'qrWaiting';
  static readonly PASSWORD: string = 'password';
}

/**
 * 尺寸契约（vp）。
 *
 * ⚠️ 这些值**大多不在 `Design.ets` 现有 78 个令牌里**（Design 只有 8/10/12/14/16/18/22/24/28/32 这类通用档），
 * 登录页是唯一一处使用 56/62/286/128/168 这类专用尺寸的界面。
 * 本轮先集中放在这里（而不是散落成裸值），并在交付简报里列出「建议上收到 Design.ets」的清单。
 */
export class AuthMetrics {
  /** 四屏共同的水平内边距（`AuthScreens.kt:64`、`WebLoginScreen.kt:124`、`QrAuthScreens.kt:128/254`）。 */
  static readonly PAGE_H: number = 32;
  /** LoginMethods 顶部（`:65`）——**比其余屏大 30**，是刻意的视觉重心。 */
  static readonly METHODS_TOP: number = 104;
  /** ServerSetup / QrLogin / QrWaiting 顶部（`WebLoginScreen.kt:125`、`QrAuthScreens.kt:129/255`）。 */
  static readonly SHELL_TOP: number = 74;
  /** 四屏共同的底部内边距。 */
  static readonly PAGE_BOTTOM: number = 30;
  /** LoginMethods 区块间距（`:66`）。 */
  static readonly METHODS_GAP: number = 30;
  /** ServerSetup 里 BackPill 之后 / 标题块之后的两个 Spacer（`WebLoginScreen.kt:128/153`）。 */
  static readonly HOST_GAP: number = 30;
  /** 标题块内部间距（`AuthScreens.kt:70`）、QrLogin 文字块内部间距（`QrAuthScreens.kt:163`）。 */
  static readonly TITLE_GAP: number = 6;
  /** ServerSetup 标题块内部间距（`WebLoginScreen.kt:129`）。 */
  static readonly HOST_TITLE_GAP: number = 10;
  /** 按钮列间距（`AuthScreens.kt:88`、`WebLoginScreen.kt:158`）。 */
  static readonly BUTTON_GAP: number = 24;
  /** 错误条与按钮列之间的 Spacer（`WebLoginScreen.kt:156`）。 */
  static readonly ERROR_GAP: number = 18;
  /** `LoginMethodButton` 高度（`:143`）。 */
  static readonly BUTTON_H: number = 56;
  /** `LoginMethodButton` 圆角（`:115`）。 */
  static readonly BUTTON_RADIUS: number = 12;
  /** `LoginMethodButton` 水平内边距（`:159`）。 */
  static readonly BUTTON_PADDING_H: number = 18;
  /** 图标边长（按钮 `/ 输入行` 都是 22dp，`:164` / `:200`）。 */
  static readonly ICON: number = 22;
  /** 图标与文字间距（`:167`）。 */
  static readonly ICON_GAP: number = 10;
  /** `AuthInputRow` 高度（`:192`）。 */
  static readonly INPUT_H: number = 62;
  /** `AuthInputRow` 圆角（`:193`）。 */
  static readonly INPUT_RADIUS: number = 17;
  /** `AuthInputRow` 边框宽度（`:195`，**1.2 不是 1**）。 */
  static readonly INPUT_BORDER: number = 1.2;
  /** `AuthInputRow` 水平内边距（`:196`）。 */
  static readonly INPUT_PADDING_H: number = 18;
  /** `AuthInputRow` 图标与输入框间距（`:197`）。 */
  static readonly INPUT_GAP: number = 10;
  /** SelfHostLoginForm 区块间距（`WebLoginScreen.kt:211`）。 */
  static readonly FORM_GAP: number = 12;
  /** BackPill 高度（`Components.kt:64-85`）。 */
  static readonly BACK_PILL_H: number = 36;
  /** BackPill 水平内边距（`Components.kt:74`）。 */
  static readonly BACK_PILL_PADDING_H: number = 12;
  /** BackPill 图标与文字间距（`Components.kt:76`）。 */
  static readonly BACK_PILL_GAP: number = 7;
  /** BackPill 边框宽度（`Components.kt:72`，同样是 1.2 而不是 1）。 */
  static readonly BACK_PILL_BORDER: number = 1.2;
  /** BackPill 图标（`‹`）边长。 */
  static readonly BACK_PILL_ICON: number = 16;

  /** 错误条圆角 / 内边距 / 图标 / 图标与文字间距（`Components.kt:89-117` 的 AuthErrorNotice）。 */
  static readonly ERROR_RADIUS: number = 14;
  static readonly ERROR_PADDING: number = 14;
  static readonly ERROR_ICON: number = 20;
  static readonly ERROR_ICON_GAP: number = 10;
  /** 说明行图标（Info）边长（`WebLoginScreen.kt:142`）。 */
  static readonly HINT_ICON: number = 17;
  /** 说明行图标与文字间距（`:145`）。 */
  static readonly HINT_ICON_GAP: number = 9;
  /** 「OR」左右分隔线间距（`:181`）。 */
  static readonly OR_GAP: number = 12;
  /** QrLogin 主区块间距（`QrAuthScreens.kt:130`）—— **128 是刻意的视觉重心，不是笔误**。 */
  static readonly QR_BLOCK_GAP: number = 128;
  /** QrLogin 取景框与文字块之间的间距（`:136`）。 */
  static readonly QR_TEXT_GAP: number = 34;
  /** 取景框边长（`:304`）。 */
  static readonly QR_FRAME: number = 286;
  /** 取景框圆角（`:305`）。 */
  static readonly QR_FRAME_RADIUS: number = 22;
  /** 取景框内提示的水平内边距（`:316`）。 */
  static readonly QR_FRAME_PADDING_H: number = 28;
  /** 取景框四角角标的 inset / 线长 / 线宽（`QrAuthScreens.kt:407-409`）。 */
  static readonly QR_CORNER_INSET: number = 26;
  static readonly QR_CORNER_LENGTH: number = 22;
  static readonly QR_CORNER_STROKE: number = 2.3;
  /** QrLogin 里错误条距文字块的顶部间距（`QrAuthScreens.kt:181` 的 padding top 8）。 */
  static readonly QR_ERROR_TOP: number = 8;
  /** 粘贴二维码输入框高度（本工程自定：上游没有这一块，它是差异 2 的落地控件）。 */
  static readonly QR_PASTE_HEIGHT: number = 96;
  /** QrWaiting 区块间距（`:256`）。 */
  static readonly WAITING_GAP: number = 42;
  /** QrWaiting 图标区顶部留白（`:262`）—— 同样是刻意的视觉重心。 */
  static readonly WAITING_TOP: number = 168;
  /** QrWaiting 图标尺寸（`:440`，宽 64 高 52）。 */
  static readonly WAITING_ICON_W: number = 64;
  static readonly WAITING_ICON_H: number = 52;
  /** QrWaiting 图标 / 标题 / 副文之间的间距（`QrAuthScreens.kt:268`）。 */
  static readonly WAITING_TEXT_GAP: number = 18;
  /** 内嵌网页登录的容器内边距（`WebLoginScreen.kt:257`）。 */
  static readonly WEB_PADDING_H: number = 16;
  static readonly WEB_PADDING_V: number = 10;
  /** 内嵌网页高度（本工程自定：上游是 fillMaxSize 的整屏 WebView）。 */
  static readonly WEB_HEIGHT: number = 420;
}

/** 字号契约（sp → fp，1:1；小数照抄）。 */
export class AuthFont {
  /** LoginMethods 标题 24sp（`AuthScreens.kt:76`）。 */
  static readonly TITLE: number = 24;
  /** **登录页**字标 42sp（`AuthScreens.kt:79`）。 */
  static readonly WORDMARK: number = 42;
  /** **首页**字标 31sp（`HomeScreen.kt:653`）—— 同一个字标两处不同，两个都要保留。 */
  static readonly WORDMARK_HOME: number = 31;
  /** LoginMethods 说明 14sp（`AuthScreens.kt:83`）。 */
  static readonly DESC: number = 14;
  /** 按钮 / 输入行文字 15.3sp（`AuthScreens.kt:170` / `:215`）。 */
  static readonly BUTTON: number = 15.3;
  /** ServerSetup 标题 28sp（`WebLoginScreen.kt:134`）。 */
  static readonly HOST_TITLE: number = 28;
  /** ServerSetup 说明行 13sp（`:148`）。 */
  static readonly HOST_HINT: number = 13;
  /** 「OR」14sp（`:185`）。 */
  static readonly OR: number = 14;
  /** QrLogin 标题 16sp（`QrAuthScreens.kt:168`）。 */
  static readonly QR_TITLE: number = 16;
  /** QrLogin 说明 14sp（`:176`）。 */
  static readonly QR_BODY: number = 14;
  /** 取景框内提示 / QrWaiting 副文 12.5sp（`:319` / `:283`）。 */
  static readonly QR_HINT: number = 12.5;
  /** QrWaiting 标题 18sp（`:274`）。 */
  static readonly WAITING_TITLE: number = 18;
  /** AuthErrorNotice 正文 13.5sp（`Components.kt:112`）。 */
  static readonly ERROR: number = 13.5;
}

/** 行高契约（sp → fp，1:1）。 */
export class AuthLineHeight {
  static readonly TITLE: number = 26;
  static readonly WORDMARK: number = 44;
  static readonly DESC: number = 18;
  static readonly BUTTON: number = 18;
  static readonly HOST_TITLE: number = 34;
  static readonly HOST_HINT: number = 19;
  static readonly FORM_LABEL: number = 21;
  static readonly QR_TITLE: number = 21;
  static readonly QR_BODY: number = 20;
  static readonly QR_HINT: number = 16;
  static readonly WAITING_TITLE: number = 22.5;
  /** AuthErrorNotice 正文行高 17sp（`Components.kt:113`）。 */
  static readonly ERROR: number = 17;
}

/**
 * 文案契约（**逐字**取上游 `values-zh-rCN/strings.xml`）。
 *
 * 为什么写死在这里而不是散在页面里：文案是"复刻口径"的一部分，
 * 集中一处才能被自测逐条守住（改字会红）。
 */
export class AuthText {
  static readonly WORDMARK: string = 'Agents Anywhere';
  static readonly CONTINUE_TO: string = '继续使用';
  static readonly CHOOSE_LOGIN: string = '选择登录方式。';
  static readonly QR_LOGIN: string = '扫码登录';
  static readonly PASSWORD_LOGIN: string = '账号密码登录';
  static readonly ENTER_SERVER: string = '输入服务器';
  static readonly BACK: string = '返回';
  static readonly HOST_TITLE: string = '选择登录服务';
  static readonly OFFICIAL: string = '登录Agents Anywhere Cloud';
  static readonly OFFICIAL_DESC: string = '使用 Agents Anywhere 在线服务';
  static readonly SELF_HOST: string = '连接到你自己的服务实例';
  static readonly SELF_HOST_DESC: string = '连接你自己部署的服务器';
  static readonly OR: string = 'OR';
  static readonly CONNECT: string = '连接服务器';
  static readonly CHECKING: string = '检查中...';
  static readonly HOST_HINT: string = '如果你没有私有化部署后端，请选择 Cloud 登录。';
  static readonly BACKEND_URL: string = '后端地址';
  static readonly OPENING_WEB_LOGIN: string = '正在打开网页登录...';
  static readonly QR_HELP_TITLE: string = '如何生成移动端登录二维码？';
  static readonly QR_HELP_BODY: string = '打开 Agents Anywhere 桌面端或网页端，进入设置 - 手机连接 - 开始连接，然后扫描页面上的二维码。';
  static readonly QR_CAMERA_ACCESS: string = '需要相机权限才能扫描。';
  static readonly QR_PASTE_HINT: string = '本机没有相机扫码：复制网页端二维码里的内容，粘贴到下面即可完成同样的登录。';
  static readonly QR_WAITING: string = '等待网页端确认...';
  static readonly QR_COMPLETING: string = '正在完成登录...';
  static readonly QR_REJECTED: string = '登录已被拒绝。';
  static readonly QR_EXPIRED: string = '二维码已过期。';
  static readonly QR_CONSUMED: string = '二维码已被使用。';
  static readonly QR_SCAN_FIRST: string = '请先扫描二维码。';
  static readonly QR_START_FAILED: string = '无法开始二维码登录。';
  static readonly QR_PARSE_FAILED: string = '二维码内容无法识别，请确认复制的是网页端的登录二维码。';
  /** QrWaiting 的监控图标（上游 `QrAuthScreens.kt:437` 的 `Lucide.Monitor`）。 */
  static readonly ICON_MONITOR: string = 'monitor';

  /**
   * 登录流程用到的图标名（kebab-case，见 `ui/Icon.ets` 的 `ICONS`）。
   *
   * R12-9：从「文本符号 / emoji 近似」换成 Lucide 矢量（`AaIcon`）。逐处按**上游语义**取，
   * 上游锚文写在行内；上游没有对应位置的写明理由。
   */
  static readonly ICON_QR: string = 'qr-code';       // 上游 `AuthScreens.kt:91` Lucide.QrCode
  static readonly ICON_KEY: string = 'key-round';    // 上游是自绘矢量 `R.drawable.ic_user_key`（鸿蒙不可用），取工程既有的凭据语义 KeyRound
  static readonly ICON_SERVER: string = 'server';    // 上游 `WebLoginScreen.kt:223` AuthInputRow(icon = Lucide.Server)
  static readonly ICON_INFO: string = 'info';        // 上游 `WebLoginScreen.kt:139` Lucide.Info 17dp
  static readonly ICON_USER: string = 'user-round';  // 无上游对应（上游该屏字段行不带图标），取 Lucide 通用用户图标
  static readonly ICON_LOCK: string = 'lock';        // 无上游对应，密码字段的通用语义（本工程扩展键）

  // 下面这些是**本工程既有能力**（原生密码 / 注册 / 网页登录）所需的文案，
  // 上游没有同款屏（它走 EmbeddedWebLogin），所以文案由本工程自拟并逐字稳定下来。
  static readonly LOGIN_TITLE: string = '登录你的账号';
  static readonly REGISTER_TITLE: string = '注册账号';
  static readonly NEEDS_BOOTSTRAP: string = '该服务器还没有管理员，请先在网页端完成初始化。';
  static readonly LOGIN_ACTION: string = '登录';
  static readonly REGISTER_ACTION: string = '注册并登录';
  static readonly SWITCH_TO_REGISTER: string = '没有账号？去注册';
  static readonly SWITCH_TO_LOGIN: string = '已有账号？去登录';
  static readonly SWITCH_SERVER: string = '更换服务器';
  static readonly USE_WEB_LOGIN: string = '使用网页登录';
  static readonly CLOSE_WEB_LOGIN: string = '关闭网页登录';
  static readonly EMAIL: string = '邮箱';
  static readonly PASSWORD: string = '密码';
  static readonly DISPLAY_NAME: string = '昵称（可选）';
  static readonly QR_START: string = '开始登录';
  static readonly QR_PASTE_PLACEHOLDER: string =
    '{"type":"agents-anywhere.mobile-login",...}';
}

/**
 * 初始步骤。
 *
 * 有登录态 → 由根页面切首页（返回空串，调用方不渲染本页）；
 * 已配服务器 → 直接进登录表单（不用再选服务）；
 * 没配服务器 → 从 LoginMethods 起步（上游无登录态时的初始目的地就是它）。
 */
export function initialStep(hasServer: boolean, hasSession: boolean): string {
  if (hasSession) {
    return '';
  }
  return hasServer ? LoginStep.PASSWORD : LoginStep.METHODS;
}

/**
 * 返回目标（上游是**硬编码**的，不是返回栈，见上游实现）：
 * `QrWaiting → QrLogin → LoginMethods`、`ServerSetup → LoginMethods`。
 * 根（LoginMethods）没有返回目标，返回空串 —— 对应易错点 2「登录页顶栏与主 App 不同，LoginMethods 是根、无返回钮」。
 */
export function backTargetOf(step: string): string {
  if (step === LoginStep.QR_WAITING) {
    return LoginStep.QR_LOGIN;
  }
  if (step === LoginStep.QR_LOGIN) {
    return LoginStep.METHODS;
  }
  if (step === LoginStep.SERVER_SETUP) {
    return LoginStep.METHODS;
  }
  if (step === LoginStep.PASSWORD) {
    return LoginStep.SERVER_SETUP;
  }
  return '';
}

/** 这一步是否显示返回钮（只有 LoginMethods 是根，没有）。 */
export function stepHasBack(step: string): boolean {
  return step !== LoginStep.METHODS && step.length > 0;
}

/** 顶部内边距：LoginMethods 是 104，其余三屏是 74（易错点 2 的数值面）。 */
export function stepTopInset(step: string): number {
  return step === LoginStep.METHODS ? AuthMetrics.METHODS_TOP : AuthMetrics.SHELL_TOP;
}

/**
 * QrWaiting 的标题（对应上游 `qrWaitingTitle`，`QrAuthScreens.kt:445-454`）。
 *
 * ⚠️ 上游判的是 `rejected` / `expired` / `consumed` 三个**精确**状态；
 * 本工程 AuthApi 用的是 `denied`（见 `AppServices.completeQrLogin` 的失效分支），
 * 所以这里同时接受 `rejected` 与 `denied` —— 否则真机被拒时只会一直显示「等待网页端确认...」。
 */
export function qrWaitingTitle(isExchanging: boolean, status: string): string {
  if (isExchanging) {
    return AuthText.QR_COMPLETING;
  }
  if (status === 'rejected' || status === 'denied') {
    return AuthText.QR_REJECTED;
  }
  if (status === 'expired') {
    return AuthText.QR_EXPIRED;
  }
  if (status === 'consumed') {
    return AuthText.QR_CONSUMED;
  }
  return AuthText.QR_WAITING;
}

/**
 * 轮询是否该停下来（上游 `when (status.status) { "approved" -> 兑换;
 * "rejected","expired","consumed" -> return@LaunchedEffect }`）。
 */
export function qrWaitingTerminal(status: string): boolean {
  return status === 'approved' || status === 'rejected' || status === 'denied' ||
    status === 'expired' || status === 'consumed';
}
