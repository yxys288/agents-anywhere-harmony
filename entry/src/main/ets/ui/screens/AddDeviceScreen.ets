/**
 * 添加 / 配对新设备（对应 Android `ui/screens/devices/AddDeviceScreen.kt` 234 行 +
 * 同目录 `DevicePairingComponents.kt` 227 行 + `DevicePairingSteps.kt` 136 行）。
 *
 * **步骤机**（上游实现，`DevicePairingFlow.kt:5-13`）：
 *  ConnectionMethod → DesktopInstall | CliConfirm → Name → CliMethod → Command | PairCode
 * 两条易错规则都落在纯函数里（已进 Node 单测）：
 *  ① `pairingStepTarget`：目标是 Command/PairCode 而凭据还没建 → 先落 Name（「先有名字才能往下」）；
 *  ② `pairingShowsCloseButton`：第一步顶栏右侧是 40dp **占位**、其余步才画 ✕ —— 两者同宽，标题因此始终居中。
 *
 * 数值全部来自 `DevicePairingComponents.kt`（**不是** `DeviceSetupSheet.kt` —— 那是设备详情里
 * 「重新连接」的半模态面板，是另一套组件，Lead 已确认按来源对号入座）：
 * 卡片圆角 18 / padding 16、动作按钮 min 50 圆角 16、名字输入框 54 圆角 16 Monospace 15、
 * 配对码是 6 个 54 高的格子（圆角 12、间距 8）、命令块圆角 14 / padding 14 / Monospace 12 / 复制钮 44、
 * 步骤标题 22sp SemiBold（行高 29）、正文 14sp（行高 22）。
 *
 * ## 第八十六轮（R86）改动 —— 官方沉浸光感（契约 开发期验证记录 §2 #1/#4）
 * · 顶栏**提到 `Navigation.title(...)`**（原来画在页面正文里）：栏本体改挂官方 `ImmersiveMaterial`、
 *  删掉自绘 `backgroundEffect` 与自持的状态栏避让（`topInset()`），`titleMode` 显式 **`Full`**；
 * · 栏内两个钮（返回 / 关闭）都在生效范围内 ⇒ 升级为**官方材质档**
 *  （`AaCircleIconButton` 的 `glass + officialMaterial` 分支 = 材质 only、零自绘层）；
 * · `leave()` 的「设备已创建」系统 `AlertDialog` 下发 `systemMaterial: dialogMaterial()`。
 */

import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { DashboardStore } from '../../feature/DashboardStore';
import {
  DeviceStore, PairingStep, apiErrorMessage, apiErrorStatus, pairCodeError, pairingErrorText,
  pairingPreviousStep, pairingShowsCloseButton, pairingStepTarget, randomPairingDeviceName
} from '../../feature/DeviceStore';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, faint, ink, inkSoft, muted,
  onPrimaryAction, primaryAction, raisedSurface, subtle,
  SAFE_AREA_BOTTOM_PX
} from '../Design';
// R86（契约 §2 #1/#4）：标题栏的**官方沉浸材质**与弹窗的官方材质一律走 `Components.ets` 已冻结的构造入口
// （`officialBarMaterial` / `dialogMaterial`）—— 页面**不许**自己 `import { uiMaterial }`（契约 §1.6，
// `suite-files.mjs` 有依赖卫生断言）。
import { AaCircleIconButton, dialogMaterial } from '../Components';
import { Route, Router } from '../Router';
import { AaIcon, ICONS } from '../Icon';

/** 配对码输入框的组件 id（透明 TextInput 收键盘用，终端页是同一套做法）。 */
const PAIR_CODE_INPUT_ID: string = 'aa_pair_code_input';

/** 桌面程序下载页（上游 `AppConfig.DESKTOP_DOWNLOAD_URL`）。 */
const DESKTOP_DOWNLOAD_URL: string = 'https://agents-anywhere.com/download';

/** 等待上线的轮询节奏（上游 `DevicePairingMonitor`：起步 1.5s、间隔 2s）。 */
const WAIT_FIRST_DELAY_MS: number = 1500;
const WAIT_INTERVAL_MS: number = 2000;
const WAIT_MAX_ATTEMPTS: number = 10;

@Component
export struct AddDeviceScreen {
  @State step: string = PairingStep.CONNECTION_METHOD;
  /**
   * 底部安全区高度（px，`EntryAbility.pushSafeAreaInsets()` 实测写入）。
   * R13-15：底部避让由**本页自己的底部元素**承担（根节点只避让顶部，否则列表底部会多一条空白）。
   */
  @StorageLink(SAFE_AREA_BOTTOM_PX) safeAreaBottomPx: number = 0;
  @State nameValue: string = '';
  @State pairCode: string = '';
  @State busy: boolean = false;
  @State waitingOnline: boolean = false;
  @State errorText: string = '';
  @State copyHint: string = '';
  /** 凭据拆成标量：@State 里不放对象字面量（ArkTS 要显式类型）。 */
  @State credentialDeviceId: string = '';
  @State credentialToken: string = '';
  @State hasCredential: boolean = false;
  @State pairCommandValue: string = '';
  @State tokenCommandValue: string = '';

  private dashboard: DashboardStore = DashboardStore.get();
  private waitTimer: number = -1;

  aboutToAppear(): void {
    // 上游 `name by rememberSaveable { mutableStateOf(randomPairingDeviceName()) }`：
    // 进页面就先给一个能用的名字（空名字会让「继续」一直是灰的）。
    this.nameValue = randomPairingDeviceName(Date.now());
    this.pairCommandValue = DeviceStore.pairingCommandText();
  }

  aboutToDisappear(): void {
    // 页面走了就别再轮询（回调里会动 @State）。
    this.waitingOnline = false;
    if (this.waitTimer >= 0) {
      clearTimeout(this.waitTimer);
      this.waitTimer = -1;
    }
  }

  build() {
    // ## R86（契约 §2 #1）：顶栏从正文里**提到 `Navigation` 标题栏**（原来是页面正文里的自绘行）。
    //
    // ⚠️ 官方依据 —— 官方「生效范围」行为变更（**仅对 `targetSdkVersion >= 26.0.0` 生效**，本工程 = 26.0.0）：
    //  其他组件**只在 `Navigation`/`NavDestination` 标题栏**、或横向 Tabs 且 `barPosition =
    //  BarPosition.End` 的底部 TabBar 中生效；**在页面正文里设置沉浸光感不生效**
    // （不报错、不告警，静默无效）—— `坑 245`。
    //  ⇒ 本页要让顶栏吃到官方材质，**必须先让顶栏进标题栏**（否则 §1.1 白挂、还把回退层删了变空壳）。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容区之上**、占自己一行）而不是 `STACK`：
    //  STACK 会把标题栏**叠在内容上**，那就得自己给内容让位；STANDARD 下内容天然落在标题栏下方，
    //  首屏不会被顶栏压住（与 `DevicesScreen`(R65-B) / `ArchivedSessionsScreen`(R65-A) 逐字同款）。
    //
    // ⚠️ 安全区：进标题栏后**避让由框架接管**（框架已把页面根节点放在状态栏之下）⇒ 本页原来的
    //  `topInset()` 整段删除，否则是**重复避让约 137px**（`DevicesScreen` R65-B 的真机实测记录）。
    Navigation() {
      Column() {
        Scroll() {
          // ⚠️ 间距是上游 `AddDeviceScreen.kt:190-191` 的 `Arrangement.spacedBy(20.dp)` ——
          // **不能用 `Space.XL`（24）**：全局令牌的 XL 是按别处的 24 定的，这里照抄会把
          // 「标题块→卡片→卡片」的间距整体撑大 4vp（并排图上肉眼可见）。
          Column({ space: 20 }) {
            this.stepContent()
            Blank().height(20)
          }
          .width('100%')
          .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.PAGE })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        /**
         * ⚠️ R13-21（8-1）：`align` 是通用属性，SDK 默认值是 `Alignment.Center`，
         * 于是**内容比视口短时会被垂直居中** —— 配对页首屏内容只有几百 px，
         * 顶部因此多出 ≈300px（≈100vp）空白（「连接您的设备」y≈455 vs 安卓 180）。
         * 与设置页 R13-10 的根因/修法完全一致（那里也是 `.align(Alignment.Top)`）。
         */
        .align(Alignment.Top)
        this.stepActions()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(canvas())
    }
    // 标题栏 = 顶栏一行；底色**透明**，让标题栏自己的**官方材质**（`topBar()` 的 `systemMaterial`）
    // 透出页面底色 —— 不透明底会把材质那层整个盖住（同 `DevicesScreen` 口径）。
    .title(this.topBar(), { backgroundColor: Color.Transparent })
    .mode(NavigationMode.Stack)
    // ## `titleMode` **必须显式 `Full`**（缺省 ≠ Full：SDK `titleMode` 原文 Default value = `NavigationTitleMode.Free`）
    // · `Free`：主标题随内容滚动**收起/改变位置**（SDK `navigation.d.ts:224-243`）⇒ 顶栏会「整条消失、状态栏后面留残影」；
    // · `Mini`：⛔ 已被真机证伪 —— 它的 56vp **从窗口顶 y=0 起算**，状态栏（46vp）之下只剩 29px，
    //  栏内控件会压住状态栏（`坑 247`，两次踩到）；
    // · `Full`：标题栏恒为 `[0,137][1316,332]`（本工程真机实测），栏内容落在**状态栏之下**，
    //  可用高 = 112 − 状态栏 = 65.5vp（`坑 255`）⇒ 容得下 `Control.NAV_TITLE_ROW`(46)。
    .titleMode(NavigationTitleMode.Full)
    .hideToolBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor(canvas())
  }

  /**
   * ⚠️ **R86 删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）。
   *
   * R37 五改的本意是「顶栏背景铺到屏幕顶、状态栏那一条也一起糊」。但顶栏一旦进入 `Navigation`
   * 标题栏，**高度与位置由框架接管**：真机 `dumpLayout` 实测标题栏落在 `[0,137][1316,332]`
   * （`HomeScreen` R62 的实测记录）—— 页面根节点**已经在状态栏之下**，顶栏再避让一次就是
   * **重复避让 137px**。而且原来读的是 `AppStorage.get(SAFE_AREA_TOP_PX)` 这个**非响应**读取，
   * 值随冷启动时序在 `0 / 46vp` 之间跳（R61 实测：同一份包两次冷启动顶栏行高 136px / 274px）。
   * ⇒ 本页按 R86 固定**不避让**，与 `HomeScreen`(R62) / `DevicesScreen`(R65-B) 同一口径。
   *
   * **R86：本页标题栏** —— `Navigation.title(...)` 的自定义构造器，内容只有**顶栏一行**
   * （上游 `AddDeviceScreen.kt:180-189`）。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End` 的
   * 底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`）。
   *
   * ⚠️ **R86：契约 §2 #1「删自绘返回钮」经 Lead 裁决作废**（依据是下面这条 SDK 一手证据 + `坑 247`）：
   *  SDK 原文 `navigation.d.ts:2367-2370`（`hideBackButton`）写明「The back button takes effect
   *  **only when** `titleMode` is set to **`NavigationTitleMode.Mini`**」；而 `Mini` 已被真机证伪
   * （`坑 247`：它的 56vp 从窗口顶 y=0 起算，状态栏之下只剩 29px）⇒ **Mini 有箭头但栏不可用、
   *  Full 栏可用但无箭头**，二者不可兼得。本页的 `Navigation` 又没有 `NavPathStack`（路由是自研
   *  `ui/Router.ets` 的 `AppStorage` 栈）⇒ 框架也没有「可弹栈」的依据。删掉它，本页栏内将**零返回入口**，
   *  向导的「上一步」（`goBack()`）会失去唯一调用点。
   *  ⇒ **保留返回钮**，并按 Lead 裁决把它**升级成与其余 9 页同构的官方材质档**
   *  （`AaCircleIconButton({ glass: true, officialMaterial: true })`，见下面 `topBar()` 内的注释）。
   *  Lead 的真机验证会专门盯这两个钮；回退 = 撤掉 `glass: true` / `officialMaterial: true` 两行。
   */
  @Builder
  topBar() {
    Row({ space: Space.S }) {
      // 返回钮：向导内语义是「上一步」（`goBack()`：CONNECTION_METHOD → DESKTOP_INSTALL | CLI_CONFIRM →
      // NAME → CLI_METHOD → COMMAND | PAIR_CODE），首步等价于 `leave()`（带「设备已创建」确认框）。
      // ⚠️ 保留理由见上面那段 R86 注释（Full 档没有框架返回箭头）。
      //
      // ## R86（Lead 裁决：返回钮「保留 + 升级为官方材质档」）
      // 本钮已在 `Navigation` 标题栏内 ⇒ 命中官方生效范围第③类（`坑 245`），
      // 于是切成与其余 9 个页面**完全同构**的官方材质档：`AaCircleIconButton({ glass: true,
      // officialMaterial: true })` —— 走 `GlassIcon.ets#officialGlass()` 的**材质 only 分支**，
      // 该分支**零自绘层**（无 `backgroundEffect` / 渐变 / 描边 / 底色，按压反馈交给材质的
      // `interactive: true`），符合契约 §1.2「材质与自绘层不共存」。
      // ⚠️ 几何：外径 `Control.NAV_BUTTON_LARGE`(40) / 图标 `FontSize.ICON_XL` / 位置与原来一致（只换材质层）。
      // ⚠️ 关闭姿势：把 `glass` 去掉即回到本页原来的自绘圆钮（`filled` 档）；材质关档的语义是
      //  `uiMaterial.Material.empty`（**不是** `undefined`，`坑 256`），本钮不另传开关。
      // ⚠️ 「请求中」禁用态沿用原写法（整体 0.5 不透明 + onTap 内自查 `busy`），不改成 `interactive: false`
      //  （那会变成 0.4 不透明，与改前不是同一个观感）。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        tint: ink(),
        glass: true,
        officialMaterial: true,
        accessibilityLabel: '返回',
        onTap: () => {
          if (!this.busy) {
            this.goBack();
          }
        }
      })
        .opacity(this.busy ? 0.5 : 1)
      Text('添加新设备')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (pairingShowsCloseButton(this.step)) {
        // 关闭钮（离开配对页）：同样是**标题栏内的控件** ⇒ 与返回钮同一条理由升级到官方材质档
        // （`glass: true, officialMaterial: true` ⇒ 材质 only、零自绘层；`坑 245` 生效范围第③类）。
        // ⚠️ 保留它的语义与禁用口径不变（`leave()` / busy 时 0.5 不透明且不自查通过）。
        AaCircleIconButton({
          name: 'x',
          diameter: Control.NAV_BUTTON_LARGE,
          iconSize: FontSize.ICON_XL,
          tint: muted(),
          glass: true,
          officialMaterial: true,
          accessibilityLabel: '关闭',
          onTap: () => {
            if (!this.busy) {
              this.leave();
            }
          }
        })
          .opacity(this.busy ? 0.5 : 1)
      } else {
        // 第一步右侧：40dp **等宽占位**（上游 `pairingShowsCloseButton` 的 `false` 分支）——
        // 有它标题才严格居中。本轮**原样保留**（几何不动）。
        Blank().width(Control.NAV_BUTTON_LARGE).height(Control.NAV_BUTTON_LARGE)
      }
    }
    .width('100%')
    // ## R86（契约 §2 #1 / §1.2）：**栏本体切官方材质** —— 原来那条自绘 `backgroundEffect` 磨砂**整段删除**，
    //  整条栏改由官方 `ImmersiveMaterial` 接管（口径 = 零自绘层，同 `GlassIcon.ets#officialGlass()`；
    //  官方：材质会接管 `backgroundColor`/`borderColor`/`borderWidth`/`shadow` 且不建议与它们同用
    //  ⇒ 本节点上这四项**一个都没有**，也不新增）。
    // ⚠️ 几何：行高改成 `Control.NAV_TITLE_ROW`(46)（原来是自绘栏的 `TOP_BAR_PAGE + topInset` = 64+46）——
    //  栏已进 195px(=65.5vp) 的框架槽位，64vp 的自绘行放不进去（`坑 255`），且 R81 起全工程标题栏
    //  行高统一 46（真机实测：栏内控件垂直中心 = 166 + 行高/2 = 235px = 首页同一条线）。
    //  `width('100%')` 与左右 padding 的取值（`Space.PAGE` = 18）**原样保留**。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .alignItems(VerticalAlign.Center)
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：挂材质的栏会画出比正文亮约
    //  +19 的一整条「带」；首页栏本体零材质、同口径 +0.00）。**光效只留在栏内控件（返回钮 / ✕ 钮）上。**
    //  ⚠️ 历史：本栏 R86 迁入 `Navigation` 时按当时的契约挂了栏本体材质
    //  （本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），R87 因观感投诉撤回；
    //  同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  /** 当前步骤的内容（上游 `DevicePairingStepContent`，`DevicePairingSteps.kt:31-109`）。 */
  @Builder
  stepContent() {
    if (this.step === PairingStep.CONNECTION_METHOD) {
      this.stepHeading('连接您的设备', '您可以通过桌面程序或 CLI 连接您的设备。')
      this.choiceCard('monitor-up', '使用桌面程序连接',
        '如果您使用 Windows 或 macOS，搭配桌面程序连接可以获得最佳体验。', PairingStep.DESKTOP_INSTALL)
      this.choiceCard('terminal', '使用命令行连接',
        '使用一行命令连接您的设备，建议用于 Linux。', PairingStep.CLI_CONFIRM)
    } else if (this.step === PairingStep.DESKTOP_INSTALL) {
      this.stepHeading('使用桌面程序连接',
        '前往官网下载页下载 Agents Anywhere 桌面程序，然后按照下方步骤完成连接。')
      // ⚠️ R28：上游这三张卡是**嵌在 `Column(spacedBy(12.dp))` 里**的
      // （`DevicePairingSteps.kt:57-61`），不是平铺在外层 `spacedBy(20.dp)` 上 ——
      // 平铺会让「卡→卡」变成 20dp（多 8dp/步，三步累计 16dp，并排图上逐步放大）。
      Column({ space: 12 }) {
        this.instructionCard('下载并安装',
          '在官网下载页选择适合您设备的 Windows 或 macOS 安装包，下载后完成安装。')
        this.instructionCard('打开程序并登录',
          '打开桌面程序，连接到您当前使用的服务，并使用同一个账号登录。')
        this.instructionCard('等待设备上线',
          '登录后，桌面程序会自动连接这台设备。回到当前应用，即可在设备列表中查看并使用它。')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.step === PairingStep.CLI_CONFIRM) {
      this.stepHeading('确定要使用命令行吗？',
        '此方式需要一定的计算机基础，您需要会使用终端以及 uv / uvx 命令行工具。')
      this.bodyText('如果您使用 Windows 或 macOS，更推荐使用桌面程序，连接和日常使用会更方便。')
    } else if (this.step === PairingStep.NAME) {
      this.stepHeading('命名设备', '为您的设备起一个容易辨认的名字，然后选择配对方式。')
      this.nameInput()
    } else if (this.step === PairingStep.CLI_METHOD) {
      this.stepHeading('选择配对方式', `选择一种方式，将 ${this.nameValue.trim()} 连接到您的账号。`)
      this.choiceCard('hash', '使用配对码', '在设备终端运行命令，将生成的 6 位配对码填回这里。',
        PairingStep.PAIR_CODE)
      this.choiceCard('key-round', '使用 Token', '在设备终端运行包含 Token 的命令，直接完成连接。',
        PairingStep.COMMAND)
    } else if (this.step === PairingStep.COMMAND) {
      this.stepHeading('使用 Token 连接',
        `在 ${this.nameValue.trim()} 的终端中运行下方命令，设备会自动连接到您的账号。`)
      if (this.hasCredential) {
        this.codeBlock('启动连接器', this.tokenCommandValue)
        this.bodyText('请保持终端运行，关闭后设备会离线。如果您使用 Linux，可以通过 screen 保持后台会话：')
        this.codeBlock('screen', `screen -S anywhere\n${this.tokenCommandValue}`)
        this.bodyText('设备上线后，在 screen 会话中按 Ctrl-A，再按 D，即可离开并保持后台运行。需要返回会话时运行：')
        this.codeBlock('回到会话', 'screen -r anywhere')
      }
      if (this.waitingOnline) {
        this.waitingIndicator('等待设备上线...')
      }
    } else {
      this.stepHeading('使用配对码配对',
        `将 ${this.nameValue.trim()} 的配对码填入下方，即可完成连接。`)
      if (this.hasCredential) {
        Column({ space: Space.M }) {
          Text('在设备上运行')
            .fontSize(FontSize.BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor(ink())
            .width('100%')
          this.codeBlock('配对命令', this.pairCommandValue)
          this.bodyText('运行命令后，将终端显示的 6 位配对码输入下方。')
        }
        .width('100%')
        .padding(Space.L)
        .borderRadius(Radius.XL)
        .backgroundColor(raisedSurface())
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .alignItems(HorizontalAlign.Start)
      }
      this.pairCodeInput()
      if (this.busy) {
        this.waitingIndicator('正在确认配对，等待设备上线...')
      }
    }
    if (this.errorText.length > 0) {
      Text(this.errorText)
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.error_text'))
        .width('100%')
    }
  }

  /** 底部动作区（上游 `DevicePairingStepActions`：全宽按钮，min 高 50 / 圆角 16）。 */
  @Builder
  stepActions() {
    Column({ space: Space.S_PLUS }) {
      if (this.step === PairingStep.DESKTOP_INSTALL) {
        // ⚠️ 只有这一颗带图标（R13-12 / F-4）：上游 `DevicePairingSteps.kt:125`
        // `PairingActionButton(device_pairing_download, onDownload, secondary = true, icon = Lucide.ExternalLink)`
        // —— 真机量测过鸿蒙这里图标区墨像素为 0（安卓 735），是**确认缺陷**，不是设计差异。
        // 同一步的「完成」与 CLI_CONFIRM 的两颗上游都没有 icon，一律传空串。
        this.actionButton('前往官网下载', false, true, false, 'external-link')
        this.actionButton('完成', true, true, false, '')
      } else if (this.step === PairingStep.CLI_CONFIRM) {
        this.actionButton('使用桌面程序', false, true, false, '')
        this.actionButton('继续使用命令行', true, true, false, '')
      } else if (this.step === PairingStep.NAME) {
        this.actionButton('继续', true, this.nameValue.trim().length > 0, this.busy, '')
      } else if (this.step === PairingStep.PAIR_CODE) {
        this.actionButton('认领', true, this.pairCode.length === 6, this.busy, '')
      }
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.S_PLUS, bottom: Space.M })
    // R13-15：让出底部安全区（手势条），否则这一行会被手势条压住；
    // 系统栏那条留白由 Index 的背景层铺页面底色。
    .margin({ bottom: this.getUIContext().px2vp(this.safeAreaBottomPx) })
  }

  // -------------------------------------------------------------------------
  // 复刻的组件（对应 DevicePairingComponents.kt）
  // -------------------------------------------------------------------------

  /** 步骤标题 + 描述（标题 22sp SemiBold / 行高 29，正文 14sp / 行高 22，间距 10）。 */
  @Builder
  stepHeading(title: string, description: string) {
    Column({ space: Space.S_PLUS }) {
      // 上游 `DevicePairingComponents.kt:57-58`：22sp / lineHeight 29 / **SemiBold**。
      // ⚠️ R20 勘误：本工程此前是 Medium（并排图上比安卓细）。ArkTS 无 SemiBold，按既有约定取 Bold。
      Text(title)
        .fontSize(FontSize.HEADLINE)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .lineHeight(29)
        .width('100%')
      this.bodyText(description)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 正文（14sp / 行高 22，色 muted）。 */
  @Builder
  bodyText(text: string) {
    Text(text)
      .fontSize(FontSize.BODY_SMALL)
      .fontColor(muted())
      .lineHeight(22)
      .width('100%')
  }

  /** 选择卡（圆角 18 / padding 16 / 图标 21 / 标题 15sp / 描述 14sp，间距 8）。 */
  @Builder
  choiceCard(name: string, title: string, description: string, next: string) {
    Column({ space: Space.S }) {
      Row({ space: Space.S_PLUS }) {
        AaIcon({ d: ICONS[name], iconSize: FontSize.HEADLINE, color: inkSoft() })
        // 上游 `DevicePairingComponents.kt:76`：15sp / lineHeight 21 / **SemiBold**（同 stepHeading）。
        Text(title)
          .fontSize(FontSize.BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      this.bodyText(description)
    }
    .width('100%')
    .padding(Space.L)
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.showStep(next);
    })
  }

  /** 说明卡（与选择卡同形，只是不可点）。 */
  @Builder
  instructionCard(title: string, description: string) {
    Column({ space: Space.S }) {
      Text(title)
        .fontSize(FontSize.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        // 上游 `DevicePairingComponents.kt:89`：15sp / **lineHeight 21** / SemiBold。
        // R28 补上行高（缺它时卡片矮约 3dp，与「卡间距 20 vs 12」叠加成 5.4dp/步的偏差）。
        .lineHeight(21)
        .width('100%')
      this.bodyText(description)
    }
    .width('100%')
    .padding(Space.L)
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 动作按钮（上游 `PairingActionButton`：min 高 50 / 圆角 16 / 文字 15sp / 内边距 16×14）。
   *
   * `iconName` = 图标在 `ICONS` 表里的键，空串表示不画图标 —— 上游 `icon: ImageVector? = null`。
   * 逐条对齐上游 `DevicePairingComponents.kt:118-126`：
   *  · loading 时先画 17dp 转圈、再 `Spacer(8.dp)`、再文字；
   *  · **图标在文字之后**（`Spacer(Modifier.width(8.dp))` + `Icon(icon, null, Modifier.size(17.dp))`）。
   * 本工程 `Row({ space: Space.S })` 的 8vp 间距与上游那两个 `Spacer(8.dp)` 同值，故不再单加 Spacer。
   *
   * ⚠️ 回调**不通过 @Builder 参数**传（ArcUI 对函数参数的按值传递不稳），而是按 `primary`
   * 分派到 `runPrimaryAction` / `runSecondaryAction` 两个方法；`iconName` 是每个调用点写死的常量，
   * 不走「按变化重算」那条路（坑 38 说的是值参数不因内容变化重建）。
   */
  @Builder
  actionButton(label: string, primary: boolean, interactive: boolean, loading: boolean, iconName: string) {
    Row({ space: Space.S }) {
      if (loading) {
        LoadingProgress()
          .width(Control.SPINNER)
          .height(Control.SPINNER)
          .color(primary ? onPrimaryAction() : muted())
      }
      Text(label)
        .fontSize(FontSize.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(primary ? onPrimaryAction() : ink())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 17dp 是上游 `Icon(..., Modifier.size(17.dp))` 的原值（Design 里就是 BUTTON_ICON）。
      if (iconName.length > 0) {
        AaIcon({
          d: ICONS[iconName],
          iconSize: FontSize.BUTTON_ICON,
          color: primary ? onPrimaryAction() : ink()
        })
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .constraintSize({ minHeight: Control.ACTION_ROW_LARGE })
    .padding({ left: Space.L, right: Space.L, top: Space.M_PLUS, bottom: Space.M_PLUS })
    .borderRadius(Radius.L)
    .backgroundColor(primary ? primaryAction() : raisedSurface())
    .borderWidth(primary ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .opacity(interactive && !loading ? 1 : 0.45)
    .onClick(() => {
      if (!interactive || loading) {
        return;
      }
      if (primary) {
        this.runPrimaryAction();
      } else {
        this.runSecondaryAction();
      }
    })
  }

  /** 命令块（圆角 14 / padding 14 / 等宽 12sp / 复制钮 44）。 */
  @Builder
  codeBlock(label: string, code: string) {
    Row() {
      Column({ space: Space.XS }) {
        Text(label)
          .fontSize(FontSize.SMALL)
          .fontColor(faint())
          .width('100%')
        Text(code)
          .fontSize(FontSize.MONO_SMALL)
          .fontColor(ink())
          .lineHeight(19)
          .width('100%')
          .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
          .copyOption(CopyOptions.InApp)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Column() {
        AaIcon({ d: this.copyHint.length > 0 ? ICONS['check'] : ICONS['copy'], iconSize: FontSize.CHEVRON, color: muted() })
      }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width(Control.FIELD)
        .height(Control.FIELD)
        .onClick(() => {
          this.copyText(code);
        })
    }
    .width('100%')
    .padding(Space.M_PLUS)
    .borderRadius(Radius.M_PLUS)
    .backgroundColor(subtle())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .alignItems(VerticalAlign.Center)
  }

  /** 名字输入（标签 13sp + 输入框 54 高 / 圆角 16 / 15sp，间距 10）。 */
  @Builder
  nameInput() {
    Column({ space: Space.S_PLUS }) {
      Text('设备名')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .width('100%')
      TextInput({ text: this.nameValue, placeholder: '例如 amber-finch' })
        .fontSize(FontSize.BODY)
        .height(Control.FIELD_TALL)
        .borderRadius(Radius.L)
        .backgroundColor(raisedSurface())
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .padding({ left: Space.L, right: Space.L })
        .onChange((value: string) => {
          this.nameValue = value;
          this.errorText = '';
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 配对码输入（标签 13sp + 6 个格子，透明输入框收键盘）。 */
  @Builder
  pairCodeInput() {
    Column({ space: Space.S_PLUS }) {
      Text('设备上的配对码')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .width('100%')
      Stack() {
        Row({ space: Space.S }) {
          ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
            this.pairCodeCell(index)
          }, (index: number) => `cell:${index}`)
        }
        .width('100%')
        // 透明输入框盖在格子上：它才是真正收键盘的组件（终端页同一套做法）。
        TextInput({ text: this.pairCode })
          .id(PAIR_CODE_INPUT_ID)
          .type(InputType.NUMBER_PASSWORD)
          .opacity(0)
          .width('100%')
          .height(Control.FIELD_TALL)
          .onChange((value: string) => {
            this.pairCode = value.replace(/[^0-9]/g, '').slice(0, 6);
            this.errorText = '';
          })
      }
      .width('100%')
      .onClick(() => {
        focusControl.requestFocus(PAIR_CODE_INPUT_ID);
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  pairCodeCell(index: number) {
    Text(index < this.pairCode.length ? this.pairCode.charAt(index) : '')
      .fontSize(FontSize.HEADLINE)
      .fontColor(ink())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(Control.FIELD_TALL)
      .borderRadius(Radius.M)
      .backgroundColor(raisedSurface())
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(this.pairCode.length === index ? inkSoft() : borderColor())
  }

  /** 等待指示器（圈 16 + 正文 14sp）。 */
  @Builder
  waitingIndicator(label: string) {
    Row({ space: Space.S }) {
      LoadingProgress().width(Control.SPINNER).height(Control.SPINNER).color(muted())
      this.bodyText(label)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  // -------------------------------------------------------------------------
  // 流程（对应上游 AddDeviceScreen 的 goBack / leave / showStep / createCredential / claim）
  // -------------------------------------------------------------------------

  private goBack(): void {
    if (this.step === PairingStep.CONNECTION_METHOD) {
      this.leave();
      return;
    }
    this.waitingOnline = false;
    this.errorText = '';
    this.step = pairingPreviousStep(this.step);
  }

  /** 离开（上游 `leave()`：建过设备才弹「设备已创建」确认，否则直接退）。 */
  private leave(): void {
    if (this.busy) {
      return;
    }
    if (!this.hasCredential) {
      Router.pop();
      return;
    }
    try {
      // ## R86（契约 §2 #4 / §0.2 A12）：系统 `AlertDialog` 下发官方沉浸材质。
      // · 官方依据：`AlertDialog` 参数对象的 `systemMaterial?: SystemUiMaterial`
      //  （SDK `alert_dialog.d.ts:894`，归属 `declare interface AlertDialogParam` :340 ——
      //  `AlertDialogParamWithConfirm`(:907) / `...WithButtons`(:965) / `...WithOptions`(:1006) 三个重载
      //  都继承它，所以 `showAlertDialog()` 的任一重载都能收到本字段）；
      //  类型 `SystemUiMaterial` = `uiMaterial.Material`（`common.d.ts:16964`）。
      // · 生效范围：**弹窗类组件在页面内全部区域生效**（官方「生效范围」行为变更，仅对
      //  `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0；`坑 245`）
      //  ⇒ 与「正文里的普通容器」不同，本处**不需要**先把弹窗搬进标题栏。
      // · §1.2：本参数对象里**没有** `backgroundColor` / `borderColor` / `borderWidth` / `shadow`
      //  （一个都没下发）⇒ 无自绘层可删，也不新增（材质会接管这四项）。
      // · **关闭姿势**：删掉下面 `systemMaterial` 这一行 = 逐字回到 R85 前行为；要「显式关档」的语义是
      //  `uiMaterial.Material.empty`（**不是** `undefined`，后者 = 「恢复组件默认材质」，`坑 256`）。
      //  `dialogMaterial()` 内部已含这条降级：探针（应用级 metadata `enable` + 设备支持）不通过时
      //  它自己返回 `Material.empty` ⇒ 弹窗回到系统默认底，不会变成没有底的空壳。
      this.getUIContext().showAlertDialog({
        title: '设备已创建',
        message: `设备 ${this.nameValue.trim()} 已经创建但尚未完成配对。如果不再需要，请在设备列表中手动删除。`,
        autoCancel: true,
        systemMaterial: dialogMaterial(),
        confirm: {
          value: '仍然关闭',
          action: () => {
            Router.pop();
          }
        },
        cancel: () => {
        }
      });
    } catch (error) {
      Router.pop();
    }
  }

  /** 切步骤（「先有名字才能往下」这条规则在 `pairingStepTarget` 里）。 */
  private showStep(next: string): void {
    if (this.busy) {
      return;
    }
    this.waitingOnline = false;
    this.errorText = '';
    const target = pairingStepTarget(next, this.hasCredential);
    if (target === PairingStep.COMMAND && this.hasCredential) {
      // 令牌路径：进这一步就意味着命令已经能展示，顺带开始等设备上线。
      this.startWaitingOnline();
    }
    this.step = target;
  }

  /** 底部主按钮：按当前步骤分派（@Builder 不接函数参数，见 `actionButton` 注释）。 */
  private runPrimaryAction(): void {
    if (this.step === PairingStep.DESKTOP_INSTALL) {
      this.complete();
      return;
    }
    if (this.step === PairingStep.CLI_CONFIRM) {
      this.showStep(PairingStep.NAME);
      return;
    }
    if (this.step === PairingStep.NAME) {
      this.createCredential();
      return;
    }
    if (this.step === PairingStep.PAIR_CODE) {
      this.claim();
    }
  }

  /** 底部次按钮。 */
  private runSecondaryAction(): void {
    if (this.step === PairingStep.DESKTOP_INSTALL) {
      this.openDownloadPage();
      return;
    }
    if (this.step === PairingStep.CLI_CONFIRM) {
      this.showStep(PairingStep.DESKTOP_INSTALL);
    }
  }

  /** `POST /connectors`：建一台待认领设备，拿到 connectorId + 一次性 token。 */
  private createCredential(): void {
    const cleanName = this.nameValue.trim();
    if (this.busy || cleanName.length === 0) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.createCredentialAsync(cleanName);
  }

  private async createCredentialAsync(cleanName: string): Promise<void> {
    try {
      const credential = await DeviceStore.createDevice(cleanName);
      this.credentialDeviceId = credential.deviceId;
      this.credentialToken = credential.deviceToken;
      this.tokenCommandValue = DeviceStore.tokenCommandText(credential.deviceId, credential.deviceToken);
      this.hasCredential = true;
      this.busy = false;
      this.step = PairingStep.CLI_METHOD;
    } catch (error) {
      this.busy = false;
      this.errorText = pairingErrorText(apiErrorStatus(error as Object), apiErrorMessage(error as Object));
    }
  }

  /** `POST /pairing/claim`：用 6 位配对码把设备认领到当前账号。 */
  private claim(): void {
    if (this.busy) {
      return;
    }
    const reason = pairCodeError(this.pairCode);
    if (reason.length > 0) {
      this.errorText = reason;
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.claimAsync();
  }

  private async claimAsync(): Promise<void> {
    try {
      const device = await DeviceStore.claimPairingWithCredential(
        this.credentialDeviceId, this.credentialToken, this.pairCode, this.nameValue.trim());
      this.busy = false;
      await this.dashboard.refreshAll();
      Router.replace(Route.DEVICE, device.id.length > 0 ? device.id : this.credentialDeviceId);
    } catch (error) {
      this.busy = false;
      this.errorText = pairingErrorText(apiErrorStatus(error as Object), apiErrorMessage(error as Object));
    }
  }

  /** 桌面程序路径的收尾（上游 `onComplete`）。 */
  private complete(): void {
    this.dashboard.refreshAll();
    Router.pop();
  }

  /** 令牌路径：轮询设备直到上线，上线即回上一级（上游 `DevicePairingMonitor`）。 */
  private startWaitingOnline(): void {
    if (this.waitingOnline || this.credentialDeviceId.length === 0) {
      return;
    }
    this.waitingOnline = true;
    this.scheduleWait(0);
  }

  private scheduleWait(attempt: number): void {
    if (!this.waitingOnline || attempt >= WAIT_MAX_ATTEMPTS) {
      return;
    }
    const delayMs = attempt === 0 ? WAIT_FIRST_DELAY_MS : WAIT_INTERVAL_MS;
    this.waitTimer = setTimeout(() => {
      DeviceStore.isDeviceOnline(this.credentialDeviceId).then((online: boolean) => {
        if (!this.waitingOnline) {
          return;
        }
        if (online) {
          this.waitingOnline = false;
          Router.pop();
        } else {
          this.scheduleWait(attempt + 1);
        }
      });
    }, delayMs);
  }

  /** 打开桌面程序下载页（上游 `uriHandler.openUri(AppConfig.DESKTOP_DOWNLOAD_URL)`）。 */
  private openDownloadPage(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.openLink(DESKTOP_DOWNLOAD_URL).catch(() => {
        this.errorText = '无法打开下载页面，请稍后重试。';
      });
    } catch (error) {
      this.errorText = '无法打开下载页面，请稍后重试。';
    }
  }

  /** 复制到系统剪贴板（写剪贴板不需要权限；`createData` 标了 @throws，必须包 try）。 */
  private copyText(value: string): void {
    if (value.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copyHint = '已复制';
      }).catch(() => {
        this.copyHint = '';
      });
    } catch (error) {
      this.copyHint = '';
    }
  }
}


