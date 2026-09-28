/**
 * 登录流程四屏（对应 Android `ui/screens/auth/` 的 AuthScreens.kt + WebLoginScreen.kt + QrAuthScreens.kt）。
 *
 * 上游是**单目的地状态机**（上游实现）：
 *  LoginMethods ──扫码────→ QrLogin ──→ QrWaiting
 *  └─账号密码─→ ServerSetup（HostChoice → SelfHostLoginForm）→ 登录
 * 本工程的步骤常量 / 数值契约 / 文案契约全部在 `ui/screens/AuthFlow.ets`（纯逻辑，可进 Node 自测）。
 *
 * 与上游**有意的三处差异**（都是「保留第八轮已上线的能力」所必需）：
 * 1. `ServerSetup` 连上服务后进的是**原生密码 / 注册表单**（上游是 EmbeddedWebLogin 整屏 WebView）——
 *  本工程第八轮已上线原生密码登录与注册，不得回归；网页 OAuth（PKCE + ArkWeb 拦截回调）
 *  作为该屏内的入口保留。
 * 2. `QrLogin` 没有相机预览（不申请 CAMERA 权限、不引相机 Kit）：取景框内显示上游「无权限」态文案，
 *  扫码能力以**粘贴二维码内容**的方式保留（第八轮真机验过的三段式）。
 * 3. `LoginMethods` 多一个「输入服务器」入口：上游把自建地址藏在 HostChoice 里，
 *  而本工程首次启动必须能直接配置服务器地址。
 *
 * 数值口径（施工图 §0.1）：`dp → vp`、`sp → fp` **1:1 不乘 density**，小数照抄
 * （15.3 / 13.6 / 12.6 / 12.5 / 22.5 不四舍五入）。
 */

import { webview } from '@kit.ArkWeb';
import {
  authController, AuthSnapshot, AuthStage, OFFICIAL_SERVER_URL, QrPayload, parseMobileLoginQr
} from '../../feature/AppServices';
import { base64UrlNoPadding, sha256, utf8Bytes } from '../../utils/Sha256';
import {
  Radius, borderColor, canvas, errorText, ink, muted, raisedSurface, subtle, SAFE_AREA_TOP_PX
} from '../Design';
import {
  AuthFont, AuthLineHeight, AuthMetrics, AuthText, LoginStep, backTargetOf, initialStep
} from './AuthFlow';
import { AaBackPill, QrWaitingScreen } from './QrWaitingScreen';
import { AaIcon, ICONS } from '../Icon';

/** 网页登录会话（PKCE）。 */
class WebLoginSession {
  authorizeUrl: string = '';
  codeVerifier: string = '';
  state: string = '';
}

function randomUrlSafe(byteCount: number): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let out = '';
  for (let i = 0; i < byteCount; i++) {
    out += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return out;
}

/**
 * PKCE 的 `code_challenge = BASE64URL(SHA256(verifier))`（RFC 7636）。
 * 用工程内的纯 ArkTS 实现，避免 CryptoFramework 的构建告警与设备能力差异。
 */
function pkceChallenge(codeVerifier: string): string {
  return base64UrlNoPadding(sha256(utf8Bytes(codeVerifier)));
}

/**
 * 登录方式按钮（上游 `AuthScreens.kt:107-176` 的 `LoginMethodButton`）。
 *
 * 高 56 / 圆角 12 / 水平 padding 18 / 图标 22 + 间距 10 / 文字 15.3sp Medium 居中 / 按下变色。
 * 上游图标是 Lucide 矢量图，本工程用文本符号近似（与 AaTopBar 的 '‹' 同款做法）。
 *
 * ⚠️ 参数名不能叫 `enabled`：`CustomComponent` 基类已占用该名字（Components.ets 有同款注释）。
 */
@Component
export struct LoginMethodButton {
  @Prop label: string = '';
  /** 图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）；空串表示无图标（官方 Cloud 按钮就是无图标）。 */
  @Prop iconName: string = '';
  @Prop primary: boolean = false;
  @Prop interactive: boolean = true;
  onTap?: () => void;
  /**
   * 按下态。
   *
   * ⚠️ 成员名不能与 ArkUI 通用属性方法撞名（`background` / `border` / `size` / `enabled` …）——
   * 那类名字会被判 `Property 'x' in type 'LoginMethodButton' is not assignable to the same
   * property in base type 'CustomComponent'`（本工程第九轮踩过 `border`，本轮踩过 `background`）。
   */
  @State isPressed: boolean = false;

  build() {
    Row({ space: AuthMetrics.ICON_GAP }) {
      if (this.iconName.length > 0) {
        AaIcon({ d: ICONS[this.iconName], iconSize: AuthMetrics.ICON, color: this.contentColor() })
      }
      Text(this.label)
        .fontSize(AuthFont.BUTTON)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.contentColor())
        .lineHeight(AuthLineHeight.BUTTON)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(AuthMetrics.BUTTON_H)
    .justifyContent(FlexAlign.Center)
    .padding({ left: AuthMetrics.BUTTON_PADDING_H, right: AuthMetrics.BUTTON_PADDING_H })
    .borderRadius(AuthMetrics.BUTTON_RADIUS)
    .backgroundColor(this.surfaceColor())
    // 下游「非主按钮」按下去会有 3dp 投影（上游 `:144-149` 的 shadow）
    .shadow({
      radius: this.isPressed && !this.primary ? 3 : 0,
      color: '#1F000000',
      offsetX: 0,
      offsetY: this.isPressed && !this.primary ? 1 : 0
    })
    .opacity(this.interactive ? 1 : 0.5)
    .onTouch((event: TouchEvent) => {
      if (!this.interactive) {
        return;
      }
      this.isPressed = event.type === TouchType.Down;
    })
    .onClick(() => {
      if (this.interactive && this.onTap !== undefined) {
        this.onTap();
      }
    })
  }

  /**
   * 底色。上游主按钮是固定浅灰底深字（#E5E5E5 / #171717）；本工程用 `subtle` 近似
   * （深浅色各自成立），按下时非主按钮才浮出底色。
   *
   * ⚠️ 方法名不能叫 `background`：ArkUI 通用属性里已有同名方法，会报
   * 「Property background in type LoginMethodButton is not assignable to the same property
   * in base type CustomComponent」（预构建实测；第九轮踩过 `border`、第一轮踩过 `size`）。
   */
  private surfaceColor(): ResourceColor {
    if (this.primary) {
      return subtle();
    }
    return this.isPressed ? subtle() : Color.Transparent;
  }

  /** 前景色（图标 + 文字）。名字同样避开通用属性一族的 `foregroundColor`。 */
  private contentColor(): Resource {
    if (this.primary) {
      return ink();
    }
    return this.isPressed ? ink() : muted();
  }
}

@Component
export struct LoginScreen {
  // ⚠️ 必须是「build 里真正读到的 @State」：ArkUI 只在 build 期间读取过的状态上登记依赖，
  // 早先用 `@State tick` + 读 authController.current 的写法不会触发刷新（真机实测过）。
  @State snap: AuthSnapshot = authController.current;
  /** 状态机当前步骤（取值见 AuthFlow.LoginStep）。 */
  @State step: string = LoginStep.METHODS;
  @State serverInput: string = OFFICIAL_SERVER_URL;
  /** HostChoice 的「自建实例」是否展开（上游 `selfHostExpanded`）。 */
  @State selfHostExpanded: boolean = false;
  /** 官方服务连通中（上游 `openingOfficial`：按钮文案换成「正在打开网页登录...」）。 */
  @State officialOpening: boolean = false;
  @State email: string = '';
  @State password: string = '';
  @State displayName: string = '';
  @State registerMode: boolean = false;
  @State qrInput: string = '';
  @State qrStatus: string = '';
  /** 进 QrWaiting 需要的三个参数（从粘贴的二维码内容里解析出来）。 */
  @State qrUserId: string = '';
  @State qrLoginToken: string = '';
  @State qrServerUrl: string = '';
  @State webLoginUrl: string = '';
  @State localError: string = '';
  private webController: webview.WebviewController = new webview.WebviewController();
  private webSession: WebLoginSession = new WebLoginSession();
  /** 键盘弹起后把表单滚到底，保证「登录」按钮在可视区内（第八轮真机修过，不得回归）。 */
  private scroller: Scroller = new Scroller();
  /** 取景框角标画布（上游是 `QrScannerOverlay` 的 8 条 drawLine）。 */
  private frameContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  /**
   * 密码框是否聚焦中。
   *
   * ⚠️ 只在 `onFocus` 里 `scrollEdge` 是**没用**的：聚焦回调触发时软键盘还没把视口压缩，
   * 滚动的还是旧高度，等键盘真的弹起来按钮又被挤出去了（模拟器实测「登录」节点不在
   * `dumpLayout` 里）。所以改成在**视口尺寸变化时**再滚 —— 事件驱动，不依赖延时猜测。
   */
  @State passwordFocused: boolean = false;
  /** 存成字段才能被 `offChange` 摘除（`AuthController.listeners` 只增不减）。 */
  private authListener: () => void = () => {
    this.snap = authController.current;
    this.syncStepWithStage();
  };

  aboutToAppear(): void {
    const snapshot = authController.current;
    if (snapshot.serverUrl.length > 0) {
      this.serverInput = snapshot.serverUrl;
    }
    this.step = initialStep(snapshot.serverUrl.length > 0, snapshot.stage === AuthStage.SIGNED_IN);
    if (this.step.length === 0) {
      // 已有登录态：根页面马上会切到首页，这里给个安全默认值，避免渲染到空分支。
      this.step = LoginStep.METHODS;
    }
    authController.onChange(this.authListener);
  }

  aboutToDisappear(): void {
    authController.offChange(this.authListener);
  }

  /**
   * 服务器被清掉（「更换服务器」）后退回选服务：
   * 否则页面停在密码表单上，一点提交只会得到「请先设置服务器地址」。
   */
  private syncStepWithStage(): void {
    if (authController.current.stage === AuthStage.NEED_SERVER && this.step === LoginStep.PASSWORD) {
      this.step = LoginStep.METHODS;
    }
  }

  /** 当前要显示的错误文案：控制器写进来的优先，其次是页面自己的（如二维码解析失败）。 */
  private currentError(): string {
    return this.snap.error.length > 0 ? this.snap.error : this.localError;
  }

  /** 返回目标（上游是硬编码的，不是返回栈；根步没有目标）。 */
  private goBack(): void {
    const target = backTargetOf(this.step);
    if (target.length > 0) {
      this.step = target;
    }
  }

  /**
   * 顶栏 / 根容器要自己避让的**状态栏高度**（vp）。
   *
   * ⚠️ R37 五改：顶部避让从 `pages/Index.ets` 的根节点下放到各页面 —— 根节点一 padding，
   * 页面内容就被推到状态栏之下，那一整条永远是纯色画布色，用户要的「系统状态栏那条和上方
   * 功能栏一样糊」就无从谈起。本页没有独立顶栏（登录屏自成一屏），由根容器整体避让。
   * 读的是 `EntryAbility` 实测写入的 `AppStorage` 值，不写死像素。
   */
  private topInset(): number {
    const px = AppStorage.get<number>(SAFE_AREA_TOP_PX);
    return px === undefined ? 0 : this.getUIContext().px2vp(px);
  }
  build() {
    Column() {
      if (this.step === LoginStep.METHODS) {
        this.methodsScreen()
      } else if (this.step === LoginStep.SERVER_SETUP) {
        this.serverSetupScreen()
      } else if (this.step === LoginStep.QR_LOGIN) {
        this.qrLoginScreen()
      } else if (this.step === LoginStep.QR_WAITING) {
        QrWaitingScreen({
          userId: this.qrUserId,
          loginToken: this.qrLoginToken,
          serverUrl: this.qrServerUrl,
          onBack: () => {
            this.step = LoginStep.QR_LOGIN;
          }
        })
      } else {
        this.passwordScreen()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(canvas())
    // 本页没有独立顶栏 ⇒ 由根容器整体让出状态栏（R37 五改，见 `topInset()`）。
    .padding({ top: this.topInset() })
  }

  /**
   * 屏 1：LoginMethods（上游 `AuthScreens.kt:56-104`）。
   *
   * 水平 32 / top **104** / bottom 30；区块间距 30；标题块间距 6；按钮列间距 24。
   * **本屏是根，没有返回钮**（易错点 2），也不套 `AaTopBar`（登录页顶栏与主 App 不同）。
   */
  @Builder
  methodsScreen() {
    Column({ space: AuthMetrics.METHODS_GAP }) {
      Column({ space: AuthMetrics.TITLE_GAP }) {
        Text(AuthText.CONTINUE_TO)
          .fontSize(AuthFont.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .lineHeight(AuthLineHeight.TITLE)
        // 上游是自绘字标（AAWordmark = 专用字体 + Medium）；本工程没有该字体资源，
        // 用同字号同字重的文本近似 —— **登录页 42sp / 首页 31sp 两个字号都要保留**（易错点 3）。
        Text(AuthText.WORDMARK)
          .fontSize(AuthFont.WORDMARK)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .lineHeight(AuthLineHeight.WORDMARK)
        Text(AuthText.CHOOSE_LOGIN)
          .fontSize(AuthFont.DESC)
          .fontColor(muted())
          .lineHeight(AuthLineHeight.DESC)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.authErrorNotice()

      Column({ space: AuthMetrics.BUTTON_GAP }) {
        LoginMethodButton({
          label: AuthText.QR_LOGIN,
          iconName: AuthText.ICON_QR,
          primary: true,
          onTap: () => {
            this.step = LoginStep.QR_LOGIN;
          }
        })
        LoginMethodButton({
          label: AuthText.PASSWORD_LOGIN,
          iconName: AuthText.ICON_KEY,
          onTap: () => {
            this.step = LoginStep.SERVER_SETUP;
          }
        })
        // 差异 3：上游 LoginMethods 没有这个入口（自建地址藏在 HostChoice 里），
        // 本工程首次启动必须能配置地址，因此保留（文案取上游 strings 的 auth_enter_server）。
        LoginMethodButton({
          label: AuthText.ENTER_SERVER,
          iconName: AuthText.ICON_SERVER,
          onTap: () => {
            this.step = LoginStep.SERVER_SETUP;
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({
      left: AuthMetrics.PAGE_H,
      right: AuthMetrics.PAGE_H,
      top: AuthMetrics.METHODS_TOP,
      bottom: AuthMetrics.PAGE_BOTTOM
    })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 错误条（对应上游 `AuthErrorNotice`，`Components.kt:89-117`）：
   * 圆角 14、内边距 14、图标 20、间距 10、正文 13.5sp/行高 17。
   *
   * 上游这一件在 HostChoice / QrLogin 两屏都有；本工程复用它而不是 `AaErrorBanner`
   * （后者的圆角 12、内边距 12、正文 13sp 与上游不一致）。
   */
  @Builder
  authErrorNotice() {
    if (this.currentError().length > 0) {
      Row({ space: AuthMetrics.ERROR_ICON_GAP }) {
        // 上游是 Lucide.CircleAlert 矢量图标，这里沿用工程里「文本符号近似」的做法。
        Column() {
          AaIcon({ d: ICONS['circle-alert'], iconSize: AuthFont.ERROR, color: $r('app.color.error_icon') })
        }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .width(AuthMetrics.ERROR_ICON)
        Text(this.currentError())
          .fontSize(AuthFont.ERROR)
          .fontWeight(FontWeight.Medium)
          .fontColor(errorText())
          .lineHeight(AuthLineHeight.ERROR)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(AuthMetrics.ERROR_PADDING)
      .borderRadius(AuthMetrics.ERROR_RADIUS)
      .backgroundColor($r('app.color.error_surface'))
      .borderWidth(AuthMetrics.INPUT_BORDER)
      .borderColor($r('app.color.error_border'))
      .onClick(() => {
        this.localError = '';
        authController.clearError();
      })
    }
  }

  /**
   * 屏 2：ServerSetup（= 上游 `WebLoginHostScreen` 的 `HostChoiceScreen`，`WebLoginScreen.kt:107-194`）。
   *
   * 水平 32 / top **74** / bottom 30；BackPill → Spacer 30 → 标题块（间距 10）→ Spacer 30
   * →（可选错误条 + Spacer 18）→ 按钮列（间距 24）；自建展开时插「OR」分隔 + 表单（间距 12）。
   */
  @Builder
  serverSetupScreen() {
    Scroll(this.scroller) {
      Column() {
        AaBackPill({
          label: AuthText.BACK,
          onBack: () => {
            this.goBack();
          }
        })

        Column({ space: AuthMetrics.HOST_TITLE_GAP }) {
          Text(AuthText.HOST_TITLE)
            .fontSize(AuthFont.HOST_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(ink())
            .lineHeight(AuthLineHeight.HOST_TITLE)
          Row() {
            AaIcon({ d: ICONS[AuthText.ICON_INFO], iconSize: AuthMetrics.HINT_ICON, color: $r('app.color.faint') })
            Text(AuthText.HOST_HINT)
              .fontSize(AuthFont.HOST_HINT)
              .fontColor(muted())
              .lineHeight(AuthLineHeight.HOST_HINT)
              .layoutWeight(1)
              .margin({ left: AuthMetrics.HINT_ICON_GAP })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: AuthMetrics.HOST_GAP })

        if (this.currentError().length > 0) {
          Column() {
            this.authErrorNotice()
          }
          .width('100%')
          .margin({ top: AuthMetrics.HOST_GAP })
        }

        Column({ space: AuthMetrics.BUTTON_GAP }) {
          LoginMethodButton({
            label: this.officialOpening ? AuthText.OPENING_WEB_LOGIN : AuthText.OFFICIAL,
            primary: true,
            interactive: !this.snap.loading,
            onTap: () => {
              this.startOfficial();
            }
          })
          if (!this.selfHostExpanded) {
            LoginMethodButton({
              label: AuthText.SELF_HOST,
              interactive: !this.snap.loading,
              onTap: () => {
                this.selfHostExpanded = true;
              }
            })
          }
          if (this.selfHostExpanded) {
            Column({ space: AuthMetrics.BUTTON_GAP }) {
              // 上游 `:180-187`：两侧分隔线 + 中间「OR」（间距 12）
              Row({ space: AuthMetrics.OR_GAP }) {
                Divider().layoutWeight(1).strokeWidth(1).color(borderColor())
                Text(AuthText.OR)
                  .fontSize(AuthFont.OR)
                  .fontColor(muted())
                Divider().layoutWeight(1).strokeWidth(1).color(borderColor())
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Column({ space: AuthMetrics.FORM_GAP }) {
                Text(AuthText.SELF_HOST)
                  .fontSize(AuthFont.BUTTON)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ink())
                  .lineHeight(AuthLineHeight.FORM_LABEL)
                this.serverUrlRow()
                LoginMethodButton({
                  label: this.snap.loading ? AuthText.CHECKING : AuthText.CONNECT,
                  primary: true,
                  interactive: this.canConnect(),
                  onTap: () => {
                    this.connectSelfHost();
                  }
                })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
          }
        }
        .width('100%')
        .margin({ top: this.currentError().length > 0 ? AuthMetrics.ERROR_GAP : AuthMetrics.HOST_GAP })
      }
      .width('100%')
      .padding({
        left: AuthMetrics.PAGE_H,
        right: AuthMetrics.PAGE_H,
        top: AuthMetrics.SHELL_TOP,
        bottom: AuthMetrics.PAGE_BOTTOM
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /**
   * `AuthInputRow`（上游 `AuthScreens.kt:179-240`）：高 62 / 圆角 17 / 边框 1.2 /
   * 水平 padding 18 / 图标 22 + 间距 10 / 文字 15.3sp。
   *
   * ⚠️ 这里**故意不抽成带值参数的 @Builder 或子组件**：ArkUI 的 `@Builder` 值参数不随内容
   * 变化重建（坑 38），受控输入框会表现为「打字不回显 / 光标跳」。
   */
  @Builder
  serverUrlRow() {
    Row({ space: AuthMetrics.INPUT_GAP }) {
      AaIcon({ d: ICONS[AuthText.ICON_SERVER], iconSize: AuthMetrics.ICON, color: ink() })
      TextInput({ text: this.serverInput, placeholder: AuthText.BACKEND_URL })
        .type(InputType.URL)
        .fontSize(AuthFont.BUTTON)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .placeholderColor(muted())
        .placeholderFont({ size: AuthFont.BUTTON, weight: FontWeight.Medium })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        // 上游 `:207-211`：`KeyboardType.Uri` + `ImeAction.Go` → 地址行回车即「连接服务器」
        .enterKeyType(EnterKeyType.Go)
        .onChange((value: string) => {
          this.serverInput = value;
        })
        .onSubmit(() => {
          this.connectSelfHost();
        })
    }
    .width('100%')
    .height(AuthMetrics.INPUT_H)
    .padding({ left: AuthMetrics.INPUT_PADDING_H, right: AuthMetrics.INPUT_PADDING_H })
    .borderRadius(AuthMetrics.INPUT_RADIUS)
    .borderWidth(AuthMetrics.INPUT_BORDER)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
  }

  /**
   * 屏 3：QrLogin（上游 `QrAuthScreens.kt:124-190`）。
   *
   * 水平 32 / top 74 / bottom 30；主区块间距 **128**（易错点 4）；
   * 取景框与文字块间距 34；文字块内部间距 6；取景框 286 方形 + 圆角 22。
   */
  @Builder
  qrLoginScreen() {
    Scroll(this.scroller) {
      Column({ space: AuthMetrics.QR_BLOCK_GAP }) {
        AaBackPill({
          label: AuthText.BACK,
          onBack: () => {
            this.goBack();
          }
        })

        Column({ space: AuthMetrics.QR_TEXT_GAP }) {
          this.qrFrame()

          Column({ space: AuthMetrics.TITLE_GAP }) {
            Text(AuthText.QR_HELP_TITLE)
              .fontSize(AuthFont.QR_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(ink())
              .lineHeight(AuthLineHeight.QR_TITLE)
              .textAlign(TextAlign.Center)
            Text(AuthText.QR_HELP_BODY)
              .fontSize(AuthFont.QR_BODY)
              .fontColor(muted())
              .lineHeight(AuthLineHeight.QR_BODY)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          this.qrPasteBlock()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding({
        left: AuthMetrics.PAGE_H,
        right: AuthMetrics.PAGE_H,
        top: AuthMetrics.SHELL_TOP,
        bottom: AuthMetrics.PAGE_BOTTOM
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /**
   * 取景框（上游 `QrScannerFrame`，`QrAuthScreens.kt:294-326`）：286 方形、圆角 22、raisedSurface 底，
   * 四角 L 形白色角标（`QrScannerOverlay` 的 8 条线：inset 26 / 线长 22 / 线宽 2.3）。
   *
   * 上游框内是 CameraX 预览；本工程不申请相机权限，因此框内是上游「无权限」态的同一句文案。
   */
  @Builder
  qrFrame() {
    Stack() {
      Text(AuthText.QR_CAMERA_ACCESS)
        .fontSize(AuthFont.QR_HINT)
        .fontColor(muted())
        .lineHeight(AuthLineHeight.QR_HINT)
        .textAlign(TextAlign.Center)
        .padding({ left: AuthMetrics.QR_FRAME_PADDING_H, right: AuthMetrics.QR_FRAME_PADDING_H })
      Canvas(this.frameContext)
        .width(AuthMetrics.QR_FRAME)
        .height(AuthMetrics.QR_FRAME)
        .onReady(() => {
          this.drawScannerCorners();
        })
    }
    .width(AuthMetrics.QR_FRAME)
    .height(AuthMetrics.QR_FRAME)
    .borderRadius(AuthMetrics.QR_FRAME_RADIUS)
    .backgroundColor(raisedSurface())
    .clip(true)
  }

  /** 四角 L 形角标（画布坐标就是 vp，与上游 `26.dp.toPx()` 的几何一致）。 */
  private drawScannerCorners(): void {
    const inset = AuthMetrics.QR_CORNER_INSET;
    const length = AuthMetrics.QR_CORNER_LENGTH;
    const far = AuthMetrics.QR_FRAME - inset;
    this.frameContext.lineWidth = AuthMetrics.QR_CORNER_STROKE;
    this.frameContext.strokeStyle = '#FFFFFF';
    this.frameContext.beginPath();
    this.frameContext.moveTo(inset, inset + length);
    this.frameContext.lineTo(inset, inset);
    this.frameContext.lineTo(inset + length, inset);
    this.frameContext.moveTo(far - length, inset);
    this.frameContext.lineTo(far, inset);
    this.frameContext.lineTo(far, inset + length);
    this.frameContext.moveTo(inset, far - length);
    this.frameContext.lineTo(inset, far);
    this.frameContext.lineTo(inset + length, far);
    this.frameContext.moveTo(far - length, far);
    this.frameContext.lineTo(far, far);
    this.frameContext.lineTo(far, far - length);
    this.frameContext.stroke();
  }

  /**
   * 粘贴二维码（差异 2 的落地）：上游是相机扫码，本工程不申请相机能力，
   * 但第八轮已上线的「粘贴二维码内容 → 解析 → 轮询 → 兑换」必须保留。
   */
  @Builder
  qrPasteBlock() {
    Column({ space: AuthMetrics.FORM_GAP }) {
      Text(AuthText.QR_PASTE_HINT)
        .fontSize(AuthFont.QR_HINT)
        .fontColor(muted())
        .lineHeight(AuthLineHeight.QR_HINT)
      TextArea({ text: this.qrInput, placeholder: AuthText.QR_PASTE_PLACEHOLDER })
        .fontSize(AuthFont.QR_HINT)
        .height(AuthMetrics.QR_PASTE_HEIGHT)
        .borderRadius(AuthMetrics.INPUT_RADIUS)
        .borderWidth(AuthMetrics.INPUT_BORDER)
        .borderColor(borderColor())
        .backgroundColor(raisedSurface())
        .onChange((value: string) => {
          this.qrInput = value;
        })
      LoginMethodButton({
        label: AuthText.QR_START,
        primary: true,
        interactive: this.qrInput.trim().length > 0 && !this.snap.loading,
        onTap: () => {
          this.startQrLogin();
        }
      })
      if (this.currentError().length > 0) {
        Column() {
          this.authErrorNotice()
        }
        .width('100%')
        .margin({ top: AuthMetrics.QR_ERROR_TOP })
      }
    }
    .width('100%')
  }

  /**
   * 登录表单（差异 1）：上游 `ServerSetup` 连上服务后是 EmbeddedWebLogin 整屏 WebView，
   * 本工程第八轮已上线原生密码 / 注册，因此这里保留原生表单，
   * 并把「使用网页登录」（PKCE + ArkWeb 拦截回调）作为同屏入口。
   *
   * 外壳数值沿用 ServerSetup（水平 32 / top 74 / bottom 30 / BackPill / 标题块 / 按钮列 24）。
   */
  @Builder
  passwordScreen() {
    Scroll(this.scroller) {
      Column() {
        AaBackPill({
          label: AuthText.BACK,
          onBack: () => {
            this.goBack();
          }
        })

        Column({ space: AuthMetrics.HOST_TITLE_GAP }) {
          Text(this.registerMode ? AuthText.REGISTER_TITLE : AuthText.LOGIN_TITLE)
            .fontSize(AuthFont.HOST_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(ink())
            .lineHeight(AuthLineHeight.HOST_TITLE)
          Row() {
            AaIcon({ d: ICONS[AuthText.ICON_SERVER], iconSize: AuthMetrics.HINT_ICON, color: $r('app.color.faint') })
            Text(this.snap.serverUrl)
              .fontSize(AuthFont.HOST_HINT)
              .fontColor(muted())
              .lineHeight(AuthLineHeight.HOST_HINT)
              .layoutWeight(1)
              .margin({ left: AuthMetrics.HINT_ICON_GAP })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          if (this.snap.needsBootstrap) {
            Text(AuthText.NEEDS_BOOTSTRAP)
              .fontSize(AuthFont.HOST_HINT)
              .fontColor(muted())
              .lineHeight(AuthLineHeight.HOST_HINT)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: AuthMetrics.HOST_GAP })

        if (this.currentError().length > 0) {
          Column() {
            this.authErrorNotice()
          }
          .width('100%')
          .margin({ top: AuthMetrics.HOST_GAP })
        }

        Column({ space: AuthMetrics.BUTTON_GAP }) {
          if (this.registerMode) {
            this.displayNameRow()
          }
          this.emailRow()
          this.passwordInputRow()
          LoginMethodButton({
            label: this.registerMode ? AuthText.REGISTER_ACTION : AuthText.LOGIN_ACTION,
            primary: true,
            interactive: this.canSubmitPassword(),
            onTap: () => {
              this.submitPassword();
            }
          })
          LoginMethodButton({
            label: this.webLoginUrl.length > 0 ? AuthText.CLOSE_WEB_LOGIN : AuthText.USE_WEB_LOGIN,
            onTap: () => {
              this.toggleWebLogin();
            }
          })
          if (this.snap.registrationOpen) {
            Text(this.registerMode ? AuthText.SWITCH_TO_LOGIN : AuthText.SWITCH_TO_REGISTER)
              .fontSize(AuthFont.BUTTON)
              .fontColor(muted())
              .lineHeight(AuthLineHeight.FORM_LABEL)
              .onClick(() => {
                this.registerMode = !this.registerMode;
              })
          }
          LoginMethodButton({
            label: AuthText.SWITCH_SERVER,
            onTap: () => {
              // 先清空登录态与地址，再落到选服务屏（listener 会把 step 拉回 METHODS，
              // 因此这里的赋值必须发生在 `switchServer()` **之后**）。
              authController.switchServer();
              this.selfHostExpanded = false;
              this.step = LoginStep.SERVER_SETUP;
            }
          })
          if (this.webLoginUrl.length > 0) {
            Web({ src: this.webLoginUrl, controller: this.webController })
              .width('100%')
              .height(AuthMetrics.WEB_HEIGHT)
              .borderRadius(Radius.M)
              .borderWidth(AuthMetrics.INPUT_BORDER)
              .borderColor(borderColor())
              .onLoadIntercept((event) => {
                return this.handleWebCallback(event.data.getRequestUrl());
              })
          }
        }
        .width('100%')
        .margin({ top: this.currentError().length > 0 ? AuthMetrics.ERROR_GAP : AuthMetrics.HOST_GAP })
      }
      .width('100%')
      .padding({
        left: AuthMetrics.PAGE_H,
        right: AuthMetrics.PAGE_H,
        top: AuthMetrics.SHELL_TOP,
        bottom: AuthMetrics.PAGE_BOTTOM
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 视口高度变化（软键盘弹起/收起）后重新贴底，保证提交按钮可见。
      if (this.passwordFocused) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    })
  }

  /** 邮箱行（`AuthInputRow` 样式）。 */
  @Builder
  emailRow() {
    Row({ space: AuthMetrics.INPUT_GAP }) {
      AaIcon({ d: ICONS[AuthText.ICON_USER], iconSize: AuthMetrics.ICON, color: ink() })
      TextInput({ text: this.email, placeholder: AuthText.EMAIL })
        .type(InputType.Email)
        .fontSize(AuthFont.BUTTON)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .placeholderColor(muted())
        .placeholderFont({ size: AuthFont.BUTTON, weight: FontWeight.Medium })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        .onChange((value: string) => {
          this.email = value;
        })
    }
    .width('100%')
    .height(AuthMetrics.INPUT_H)
    .padding({ left: AuthMetrics.INPUT_PADDING_H, right: AuthMetrics.INPUT_PADDING_H })
    .borderRadius(AuthMetrics.INPUT_RADIUS)
    .borderWidth(AuthMetrics.INPUT_BORDER)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
  }

  /** 密码行：回车即提交（对应上游 `AuthInputRow` 的 `ImeAction.Go`）。 */
  @Builder
  passwordInputRow() {
    Row({ space: AuthMetrics.INPUT_GAP }) {
      AaIcon({ d: ICONS[AuthText.ICON_LOCK], iconSize: AuthMetrics.ICON, color: ink() })
      TextInput({ text: this.password, placeholder: AuthText.PASSWORD })
        .type(InputType.Password)
        .fontSize(AuthFont.BUTTON)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .placeholderColor(muted())
        .placeholderFont({ size: AuthFont.BUTTON, weight: FontWeight.Medium })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Go)
        .onChange((value: string) => {
          this.password = value;
        })
        .onSubmit(() => {
          this.submitPassword();
        })
        // 实测：软键盘弹起后视口被压缩，「登录」按钮落在可视区之外
        // （`dumpLayout` 里查不到该节点），用户必须手动上滑或先收起键盘才能提交。
        // 密码框聚焦期间，只要视口尺寸一变（键盘弹起/收起）就把表单滚到底。
        .onFocus(() => {
          this.passwordFocused = true;
          this.scroller.scrollEdge(Edge.Bottom);
        })
        .onBlur(() => {
          this.passwordFocused = false;
        })
    }
    .width('100%')
    .height(AuthMetrics.INPUT_H)
    .padding({ left: AuthMetrics.INPUT_PADDING_H, right: AuthMetrics.INPUT_PADDING_H })
    .borderRadius(AuthMetrics.INPUT_RADIUS)
    .borderWidth(AuthMetrics.INPUT_BORDER)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
  }

  /** 昵称行（仅注册时出现）。 */
  @Builder
  displayNameRow() {
    Row({ space: AuthMetrics.INPUT_GAP }) {
      AaIcon({ d: ICONS[AuthText.ICON_USER], iconSize: AuthMetrics.ICON, color: ink() })
      TextInput({ text: this.displayName, placeholder: AuthText.DISPLAY_NAME })
        .fontSize(AuthFont.BUTTON)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .placeholderColor(muted())
        .placeholderFont({ size: AuthFont.BUTTON, weight: FontWeight.Medium })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        .onChange((value: string) => {
          this.displayName = value;
        })
    }
    .width('100%')
    .height(AuthMetrics.INPUT_H)
    .padding({ left: AuthMetrics.INPUT_PADDING_H, right: AuthMetrics.INPUT_PADDING_H })
    .borderRadius(AuthMetrics.INPUT_RADIUS)
    .borderWidth(AuthMetrics.INPUT_BORDER)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
  }

  // -------------------------------------------------------------------------
  // 行为（沿用第八轮已上线的调用链，只把「进哪一屏」换成状态机）
  // -------------------------------------------------------------------------

  /** 自建地址是否可提交（上游 `canConnect`：非空且不忙）。 */
  private canConnect(): boolean {
    return this.serverInput.trim().length > 0 && !this.snap.loading;
  }

  private canSubmitPassword(): boolean {
    return this.email.length > 0 && this.password.length > 0 && !this.snap.loading;
  }

  /** 自建实例：校验 `/health` + `/auth/config`，成功后进登录表单。 */
  private async connectSelfHost(): Promise<void> {
    if (!this.canConnect()) {
      return;
    }
    this.localError = '';
    const connected = await authController.connectServer(this.serverInput.trim());
    if (connected) {
      this.step = LoginStep.PASSWORD;
    }
  }

  /**
   * 官方 Cloud：上游 `startOfficialLogin()` 直接开网页登录并置 `openingOfficial`；
   * 本工程先用官方地址把服务连上（校验 `/health` + `/auth/config`），再进登录表单（差异 1），
   * 文案仍按上游在连通期间显示「正在打开网页登录...」。
   */
  private async startOfficial(): Promise<void> {
    if (this.officialOpening || this.snap.loading) {
      return;
    }
    this.officialOpening = true;
    this.localError = '';
    const connected = await authController.connectServer(OFFICIAL_SERVER_URL);
    this.officialOpening = false;
    if (connected) {
      this.step = LoginStep.PASSWORD;
    }
  }

  /**
   * 扫码登录第一段：解析粘贴的二维码内容，拿到 `userId` / `loginToken` / 服务器地址。
   * 后面两段（轮询 + 兑换）在 `QrWaitingScreen` 里，与上游「QrLogin 起请求 → QrWaiting 等待」等价。
   */
  private async startQrLogin(): Promise<void> {
    const payload: QrPayload | undefined = parseMobileLoginQr(this.qrInput.trim());
    if (payload === undefined) {
      this.localError = AuthText.QR_PARSE_FAILED;
      return;
    }
    this.localError = '';
    this.qrStatus = '';
    this.qrUserId = payload.userId;
    this.qrLoginToken = payload.loginToken;
    this.qrServerUrl = payload.serverUrl;
    this.step = LoginStep.QR_WAITING;
  }

  /** 密码登录 / 注册（第八轮已上线，行为与调用链保持不变）。 */
  private async submitPassword(): Promise<void> {
    if (!this.canSubmitPassword()) {
      return;
    }
    this.localError = '';
    if (this.registerMode) {
      await authController.register(this.email, this.password, this.displayName);
    } else {
      await authController.loginWithPassword(this.email, this.password);
    }
  }

  /**
   * 打开 / 关闭内嵌网页登录（第八轮已上线的 PKCE 流程）。
   *
   * `authorizeUrl` 走网页端的 `#/mobile-oauth`，回调由 `handleWebCallback` 拦截。
   */
  private async toggleWebLogin(): Promise<void> {
    if (this.webLoginUrl.length > 0) {
      this.webLoginUrl = '';
      return;
    }
    const serverUrl = this.snap.serverUrl;
    if (serverUrl.length === 0) {
      this.localError = AuthText.BACKEND_URL;
      return;
    }
    const codeVerifier = randomUrlSafe(32);
    const state = randomUrlSafe(24);
    const challenge = pkceChallenge(codeVerifier);
    this.webSession = new WebLoginSession();
    this.webSession.codeVerifier = codeVerifier;
    this.webSession.state = state;
    const query = 'response_type=code&client_id=agents-anywhere-mobile' +
      '&redirect_uri=' + encodeURIComponent('agents-anywhere://oauth/callback') +
      '&code_challenge=' + encodeURIComponent(challenge) + '&code_challenge_method=S256' +
      '&scope=profile&state=' + encodeURIComponent(state);
    this.webSession.authorizeUrl = serverUrl + '/#/mobile-oauth?' + query;
    this.webLoginUrl = this.webSession.authorizeUrl;
  }

  /** 拦截 OAuth 回调；返回 true 表示已处理（阻止 Web 继续导航）。 */
  private handleWebCallback(url: string): boolean {
    if (!url.startsWith('agents-anywhere://oauth/callback')) {
      return false;
    }
    const queryIndex = url.indexOf('?');
    if (queryIndex < 0) {
      return true;
    }
    const query = url.substring(queryIndex + 1);
    const params = query.split('&');
    let code = '';
    let state = '';
    let error = '';
    for (let i = 0; i < params.length; i++) {
      const pair = params[i];
      const eq = pair.indexOf('=');
      if (eq < 0) {
        continue;
      }
      const name = decodeURIComponent(pair.substring(0, eq));
      const value = decodeURIComponent(pair.substring(eq + 1));
      if (name === 'code') {
        code = value;
      } else if (name === 'state') {
        state = value;
      } else if (name === 'error') {
        error = value;
      }
    }
    if (error.length > 0) {
      this.localError = error === 'access_denied' ? '已取消登录。' : error;
      this.webLoginUrl = '';
      return true;
    }
    if (state !== this.webSession.state) {
      this.localError = '回调校验失败（state 不匹配）。';
      this.webLoginUrl = '';
      return true;
    }
    if (code.length === 0) {
      this.localError = '回调里没有授权码。';
      this.webLoginUrl = '';
      return true;
    }
    this.webLoginUrl = '';
    authController.completeWebLogin(code, this.webSession.codeVerifier);
    return true;
  }
}
