/**
 * 应用根页面：登录态门控 + 路由分发。
 *
 * 对应 Android `app/AgentsAnywhereApp.kt`（根 Composable）+ `AgentsAnywhereNavHost.kt`。
 *
 * ⚠️ 渲染依赖：本页 build 直接读 `@StorageLink('aaRoute')` / `@StorageLink('aaParam')`
 * 与 `@StorageLink('aaAuthStage')`，三者都是**字符串**。ArkUI 只在 build 期间读取过的
 * 状态变量上登记依赖，所以「路由/登录态」必须摊平成字符串键并被直读，
 * 否则会出现「状态变了、界面不动」。
 */

import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { authController, AppServices, AuthStage, AppearanceController } from '../feature/AppServices';
import { DashboardStore } from '../feature/DashboardStore';
import { PARAM_KEY, ROUTE_KEY, Route, Router } from '../ui/Router';
import { consumeBackPress } from '../ui/BackHandler';
import { LoginScreen } from '../ui/screens/LoginScreen';
import { HomeScreen } from '../ui/screens/HomeScreen';
import { SessionDetailScreen } from '../ui/screens/SessionDetailScreen';
import { NewSessionScreen } from '../ui/screens/NewSessionScreen';
import { NewChatWorkspaceScreen } from '../ui/screens/NewChatWorkspaceScreen';
import { FilesScreen } from '../ui/screens/FilesScreen';
import { TerminalScreen } from '../ui/screens/TerminalScreen';
import { DeviceDetailScreen } from '../ui/screens/DeviceDetailScreen';
import { DevicesScreen } from '../ui/screens/DevicesScreen';
import { SettingsScreen } from '../ui/screens/SettingsScreen';
import { ArchivedSessionsScreen } from '../ui/screens/ArchivedSessionsScreen';
import { AddDeviceScreen } from '../ui/screens/AddDeviceScreen';
import {
  FontSize, Radius, SAFE_AREA_BOTTOM_PX, SAFE_AREA_TOP_PX, Space, StrokeWidth, borderColor, canvas, ink, muted
} from '../ui/Design';
import {
  AaBottomNav, AaBottomTabItem, BOTTOM_BAR_HEIGHT_IS_CAPSULE_ONLY, BOTTOM_BAR_HIDDEN_KEY, BOTTOM_BAR_HIDE_SCALE,
  BOTTOM_BAR_SIDE_MARGIN, BOTTOM_BAR_VIA_TABS, BOTTOM_BAR_WIDTH_VP, BOTTOM_NAV_HEIGHT, BOTTOM_NAV_ITEMS,
  BOTTOM_TABS_FLOATING_BAR, BOTTOM_TABS_OFFICIAL_MATERIAL, BOTTOM_BAR_PROBE, bottomBarMaterial,
  bottomNavIndex, bottomNavKey, bottomNavSelect, overlayBarShownOn
} from '../ui/BottomNav';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { uiMaterial } from '@kit.ArkUI';
import { compileProbe } from '../dev/CompileProbe';
import { ApiClient } from '../api/ApiClient';


/** 底栏自动收回的补间时长（ms）。偏短 ⇒ 滑动一开始就收起，跟手。 */
const BOTTOM_BAR_ANIM_MS: number = 220;

@Entry
@Component
struct Index {
  @StorageLink(ROUTE_KEY) @Watch('onRouteChanged') route: string = Route.LOGIN;
  @StorageLink(PARAM_KEY) param: string = '';
  @StorageLink('aaAuthStage') authStage: string = AuthStage.NEED_SERVER;
  @State booted: boolean = false;
  /**
   * 底栏**自动收回**状态（键 `BOTTOM_BAR_HIDDEN_KEY`，全工程**唯一写入方是 HomeScreen**）。
   *
   * ⚠️ 本页只读不写：写方只有一个，才能保证「只首页自动收回、其余页常驻」不会打架
   * （其余页根本不碰这个键 ⇒ 切过去自然就是显示态）。
   */
  @StorageLink(BOTTOM_BAR_HIDDEN_KEY) bottomBarHidden: boolean = false;
  /**
   * 路线 A 用的 Tabs 控制器。
   *
   * `坑 101`：`Tabs({ index })` 的 `index` 只是**受控入参**，用户点 bar 不会自动写回、
   * `changeIndex()` 也不会替你回灌 ⇒ 两个方向都要显式做（`onTabChanged` 回灌路由、`onRouteChanged` 对齐页）。
   */
  private tabsController: TabsController = new TabsController();
  /**
   * 系统栏避让高度（单位 px，由 `EntryAbility.pushSafeAreaInsets()` 实测写入）。
   * 沉浸态下鸿蒙不替应用避让系统栏（见 ui/Design.ets 的 SAFE_AREA_* 注释），所以这里必须显式 padding。
   */
  @StorageLink(SAFE_AREA_TOP_PX) safeAreaTopPx: number = 0;
  @StorageLink(SAFE_AREA_BOTTOM_PX) safeAreaBottomPx: number = 0;

  aboutToAppear(): void {
    /**
     * 键盘避让改成 **RESIZE**（默认是 OFFSET）。
     *
     * OFFSET 只把**聚焦控件**顶上键盘之上、页面其余部分原地不动，于是：
     *  - 登录页：密码框被顶到可视区了，但紧挨它下面的「登录」按钮仍在键盘后面
     *  （模拟器实测：键盘弹起时 `dumpLayout` 里查不到「登录」节点）；
     *  - 终端页：承接键盘的隐藏输入框在 (0,0)，**不需要**上移，
     *  结果底部的 ESC/TAB/CTRL/ALT 功能键行整排留在键盘后面（实测 y≈2601）。
     *
     * RESIZE 让页面真正被压缩：`Scroll` 变成可滚动（登录页因此能把按钮滚进视野），
     * 终端网格随视口重算，功能键行落在键盘之上。这是 Android 端 `adjustResize` 的同款行为。
     * 注意：文档明确 `bindSheet`/Dialog/Popup 不受该设置影响，本应用没有依赖弹层的输入场景。
     */
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    // getContext() 已废弃；从 UI 上下文取宿主 Context
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    AppServices.get().init(context);
    AppearanceController.init();

    AppStorage.setOrCreate(ROUTE_KEY, this.route);
    AppStorage.setOrCreate(PARAM_KEY, this.param);
    AppStorage.setOrCreate('aaAuthStage', authController.current.stage);

    // 全工程唯一一处**故意不注销**的监听：根页面与应用同生命周期，
    // `aboutToAppear` 只跑一次、`aboutToDisappear` 要等应用退出才可能触发，
    // 注销它没有意义。其余页面的 store 监听一律「注册-注销」配对（见各 screen）。
    authController.onChange(() => {
      this.authStage = authController.current.stage;
      this.syncRootRoute();
    });
    authController.reloadFromStorage();
    this.authStage = authController.current.stage;
    this.syncRootRoute();
    authController.refreshMe();

    // 构建期自检（保证全量模块被 ArkTS 类型检查覆盖）
    compileProbe(new ApiClient());
    this.booted = true;
  }

  /** 登录态变化时把根路由切到对应页面。 */
  private syncRootRoute(): void {
    const stage = authController.current.stage;
    const current = Router.current();
    if (stage === AuthStage.SIGNED_IN) {
      if (current.route === Route.LOGIN || current.route.length === 0) {
        Router.reset(Route.HOME);
        DashboardStore.get().refreshAll();
        DashboardStore.get().startRealtime();
      }
    } else {
      if (current.route !== Route.LOGIN) {
        DashboardStore.get().stopRealtime();
        Router.reset(Route.LOGIN);
      }
    }
  }

  /**
   * 系统返回键 / 返回手势 → 回退自研路由栈。
   *
   * 不做这件事的后果（模拟器实测）：在会话详情、文件、终端、新建会话等任意子页按返回键，
   * 应用**直接退到桌面**（`07-backkey-exits-to-launcher.jpeg`），而且因为没走 `Router.pop()`，
   * 被离开的页面不会触发 `aboutToDisappear`，会话详情的 `stopRealtime()` 也就不会执行。
   *
   * `Router.pop()` 在栈深 ≤ 1 时返回 false —— 此时交回系统处理（根页面按返回 = 退到桌面）。
   */
  onBackPress(): boolean {
    // ① 页面内部的返回消费者优先（`ui/BackHandler.ets` 的注册表）：
    //  设置抽屉在根页按返回 = 关抽屉、在子页按返回 = 逐级回退；会话详情等页面同理。
    //  ⚠️ 首页**不注册**自己的消费者 —— 注册表只有一个槽（后注册覆盖先注册），
    //  首页注册会在抽屉开合一次之后把抽屉的消费者挤掉。首页靠下面的 Router.back() 兜底即可。
    if (consumeBackPress()) {
      return true;
    }
    // ② ⚠️ 用 `Router.back()` 而不是 `pop()`：上游的返回目标是**硬编码的 Sessions（回首页）**，
    //  不是「回上一页」（见 `Router.back` 的注释与 `ANDROID-DESIGN-LOGIC.md`）。
    //  已经在首页时它返回 false，交回系统（根页面按返回 = 退出应用）。
    return Router.back();
  }

  /**
   * 系统栏区域要铺的底色 —— **跟随当前路由的页面底色**，不能写死全局画布色。
   *
   * 终端页本体是深色（`$r('app.color.terminal_background')`），真机第四轮实测：
   * 固定填浅色画布色会在终端页上下刷出两条浅色带（用户口中的「遮罩」）。
   * 其余页面（首页/会话/文件/设置）的页面底色都是 `canvas()`。
   */
  @Builder
  immersiveBackground() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(this.route === Route.TERMINAL
        ? $r('app.color.terminal_background')
        : canvas())
      // 只扩展**绘制范围**：背景铺到状态栏与手势条区域。
      // ⚠️ 它会把容器一起撑大（R13-11/12 的教训），所以**内容层必须靠 padding 自己避让**
      // （`safeAreaTopPx` / `safeAreaBottomPx` 由 EntryAbility 实测写入）。两层缺一不可。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 路线 B 浮层盒子的总高（vp）= 胶囊 `BOTTOM_NAV_HEIGHT`(54) + 离底让位（32）。（路线 A 不用它：A 的 `barHeight` 只给胶囊高。） */
  private areaBarHeightVp(): number {
    return BOTTOM_NAV_HEIGHT + this.barBottomGapVp();
  }

  /**
   * 路线 A 的 `barHeight` 取值 —— **H1/H2 一行开关**（真机量完胶囊高度后钉死，见 `BOTTOM_BAR_HEIGHT_IS_CAPSULE_ONLY` 的注释）。
   * · H1（默认）：只给胶囊高 54vp；
   * · H2：给整条 bar 带 86vp（R68 的分配）。
   * 隐藏态两者都置 0（在调用处统一处理）。
   */
  private routeBarHeightVp(): number {
    return BOTTOM_BAR_HEIGHT_IS_CAPSULE_ONLY ? BOTTOM_NAV_HEIGHT : this.areaBarHeightVp();
  }

  /**
   * 底栏与屏幕下缘的距离（vp）= max(实测底部安全区, `Space.XXL`)。
   *
   * 喂给两处：① 路线 B 浮层盒子的总高（`areaBarHeightVp`）；② 路线 A 的 `barFloatingStyle.barBottomMargin`。
   * ⚠️ R69 起**不再**参与路线 A 的 `barHeight` —— 那个值现在只表达胶囊高（54vp），否则框架会把胶囊拉满整条带。
   * 读的是 `EntryAbility` 实测写入的安全区，不写死像素。
   */
  private barBottomGapVp(): number {
    const inset = this.getUIContext().px2vp(this.safeAreaBottomPx);
    return inset > Space.XXL ? inset : Space.XXL;
  }

  /** 路线 A：当前路由在 `BOTTOM_NAV_ITEMS` 里的下标（调用点已用 `bottomNavIndex >= 0` 兜住非顶层页）。 */
  private topTabIndex(): number {
    const index = bottomNavIndex(this.route);
    return index < 0 ? 0 : index;
  }

  /**
   * 路线 A：`Tabs` 的构造参数。
   *
   * ⚠️ **材质不在这里** —— 官方底栏材质字段 `systemMaterial` 不在 `TabsOptions` 里，
   * 而在 `FloatingTabBarStyle`（见 `floatingBarStyle()` 的注释，R65-C 编译期证伪过）。
   * `index` 由路由算出（声明式对齐），`controller` 供返回键那条路（命令式对齐）用。
   */
  private tabsOptions(): TabsOptions {
    return {
      barPosition: BarPosition.End,
      index: this.topTabIndex(),
      controller: this.tabsController
    };
  }

  /**
   * 路线 A 的**栏宽** —— 走官方正规入口 `FloatingTabBarStyle.barWidth: FloatingTabBarWidth`
   * （`tabs.d.ts` L824-896 / L783-814；SDK 明确「不可用百分比」）。
   *
   * R68 更正：R66-3/R67 是拿 `barSideMargin`(79vp) 去**凑**参考图的宽度，属于旁门；
   * 官方既然给了按断点定栏宽的字段，就用它。
   */
  private floatingBarWidth(): FloatingTabBarWidth {
    // 参考图折算：胶囊宽 835px ÷ 3 = 278.3vp ⇒ 278（本机 438.7vp 屏宽上 = 63.4%，与参考图 63.5% 一致）。
    // ⚠️ 三个断点给**同一个值**：本工程是手机（md 断点）；大小断点先与手机一致，
    //  避免平板上出现「宽度跳成另一个数」的意外。将来若要按断点分档，改这里。
    return {
      smallBarWidth: BOTTOM_BAR_WIDTH_VP,
      mediumBarWidth: BOTTOM_BAR_WIDTH_VP,
      largeBarWidth: BOTTOM_BAR_WIDTH_VP
    };
  }

  /**
   * 路线 A：官方「悬浮 bar」的形态 —— **也是官方底栏材质的唯一入口**（`systemMaterial` 属于
   * `FloatingTabBarStyle`，**不在** `TabsOptions` —— R65-C 编译期证伪过，报错原文是
   * 「'systemMaterial' does not exist in type 'TabsOptions'」）。
   *
   * · 几何：`barWidth = 278vp`（参考图实测 835px/3；本机 = 屏宽 63.4%）+ 离底 `barBottomGapVp()`（≥ `Space.XXL`）；
   * · **A/B 的唯一开关就在这里**：官方档带 `systemMaterial`、对照档不带 —— 其余（含 `barOverlap(true)`
   *  带来的官方 blur）两臂**完全相同** ⇒ MAE 可 100% 归因到材质。
   *  （⚠️ R68 起对照档**不再**叠自绘 `barBackgroundEffect`：那会让两臂差两个变量，也可能把材质盖住造成假阴性。）
   * · `BOTTOM_TABS_FLOATING_BAR = false` ⇒ 返回 `undefined`（贴底 bar）；
   *  ⚠️ 该档同时失去官方材质与栏宽（字段都在这个对象里），只用于隔离「悬浮几何对不对」，别当材质 A/B 的对照包。
   */
  /**
   * **R71 探针**（tag=`aaBottomBar`，受 `BOTTOM_BAR_PROBE` 编译期开关控制）：
   * 打印本次**实际下发给 Tabs 的几何**，用来一次性判定胶囊偏胖是 H1/H2/H3 里的哪一种：
   * · `barHeight` 应当 = 54（H1）或 86（H2）；框架若把它拉满，真机量到的胶囊就会比这个值大；
   * · `gap` 应当 = 32（可见态）/ 0（隐藏态）；
   * · `material` 应当 = on（可见态且开关开）/ off（隐藏态 —— R70 起隐藏态连材质一起去掉）。
   */
  private bottomBarProbe(): void {
    if (!BOTTOM_BAR_PROBE) {
      return;
    }
    hilog.info(0x0000, 'aaBottomBar',
      'floatingBarStyle hidden=%{public}s barHeight=%{public}d gap=%{public}d width=%{public}d material=%{public}s official=%{public}s',
      String(this.bottomBarHidden),
      this.bottomBarHidden ? 0 : this.routeBarHeightVp(),
      this.bottomBarHidden ? 0 : this.barBottomGapVp(),
      BOTTOM_BAR_WIDTH_VP,
      this.bottomBarHidden ? 'off(hidden)' : (BOTTOM_TABS_OFFICIAL_MATERIAL ? 'on' : 'off'),
      String(BOTTOM_TABS_OFFICIAL_MATERIAL));
  }

  /**
   * T6 临时 A/B 仪表（实验用，交付前必须删）。
   *
   * 为什么需要它：底栏隐藏态的真实触发条件是「首页列表下滑」或「设置抽屉打开」，
   * 而本机模拟器上应用没有可连的账号/后端 ⇒ 首页是空态、列表 onScrollIndex 恒 end <= 0
   * （代码里的守卫会强制保持显示）；抽屉虽然会置隐藏态，但抽屉是铺满全屏的
   * （SettingsDrawerPanel 的 width('100%') + 不透明 profile_page_surface）
   * ⇒ 底栏那条被完全盖住，测不到。
   * ⇒ 用这个常量把隐藏态钉成确定性，其余分支（几何 / 材质表达式）逐字不变，
   *  这样 A/B 仍是单变量。
   */


  private floatingBarStyle(): FloatingTabBarStyle | undefined {
    // R71：探针挂在唯一分叉点的入口 ⇒ 每次下发几何都会被记录（可见态与隐藏态各一条）。
    this.bottomBarProbe();
    if (!BOTTOM_TABS_FLOATING_BAR) {
      return undefined;
    }
    // ⚠️ R69：隐藏态把**离底间隙也归 0** —— R68 只塌陷 `barHeight`，32vp 的间隔带（连同材质/阴影）还在，
    //  用户看到的正是「只塌陷没消失、底下仍留一条」。两处一起归零才是真消失。
    //  （若真机上仍有残留材质/阴影带：下一档是把隐藏态的 `systemMaterial` 也去掉 —— 同样只改本函数。）
    const gap = this.bottomBarHidden ? 0 : this.barBottomGapVp();
    if (BOTTOM_TABS_OFFICIAL_MATERIAL) {
      return {
        barWidth: this.floatingBarWidth(),
        barBottomMargin: gap,
        // ⚠️ **T6 修正（官方语义，R70 的写法是错的）**：隐藏态必须用 **`uiMaterial.Material.empty`**
        //  （**显式关闭**），**不能传 `undefined`**。
        //
        // ## 为什么（两条 SDK 原文，逐字）
        // · `systemMaterial(material)`：**Setting it to undefined will make the component return to the
        //  no-material effect**（`common.d.ts:22632-22633`）—— 即「**恢复组件默认的材质**」；
        // · `uiMaterial.Material.empty`：**used to disable the immersive system material effect for a
        //  component … you can disable the immersive system material effect for a component by setting
        //  `systemMaterial(uiMaterial.Material.empty)`**（`@ohos.arkui.uiMaterial.d.ts:467-472`）。
        // ⇒ 两者**不是一回事**：本工程 `module.json5` 的 `ohos.arkui.UIMaterial.state = enable`，
        //  应用级 ENABLE 档下**悬浮 TabBar 默认就带材质**（默认档 THIN）⇒ 传 `undefined` 等于
        //  **把默认材质放回来**，隐藏态仍可能画出一条材质带 —— 正是用户此前投诉的
        //  「只塌陷没消失、底下仍留一条」的同一现象。R70 注释里「不传它就没有任何可绘制的面」
        //  建立在「`undefined` = 不含材质」这个**错误前提**上（本工程历史踩过的同类语义坑：
        //  `坑 74` 的 `backgroundBlurStyle` 不是模糊而是材质）。
        //
        // ⚠️ 可见态**不变**：仍走 `bottomBarMaterial()`（显式 `ImmersiveMaterial(THIN, …)`）。
        // ⚠️ `barOverlap(true)`：官方写明它是 `barFloatingStyle` 生效的**前置条件**
        //  （`barOverlap=true` + 水平 `vertical=false` + `barPosition=End` 三者同时满足）⇒ **不许动**。
        // ⚠️ 证据与判定见 开发期验证记录（模拟器可见 / 真机未验证）。
        systemMaterial: this.bottomBarHidden ? uiMaterial.Material.empty : bottomBarMaterial()
      };
    }
    return {
      barWidth: this.floatingBarWidth(),
      barBottomMargin: gap
    };
  }

  /** 路线 A：`Tabs` 的页变了 ⇒ **回灌**唯一状态源（`坑 101` 的修法）。 */
  private onTabChanged(index: number): void {
    if (index < 0 || index >= BOTTOM_NAV_ITEMS.length) {
      return;
    }
    bottomNavSelect(BOTTOM_NAV_ITEMS[index].key);
  }

  /**
   * 路线 A：路由（唯一状态源）一变，就把 Tabs 的当前页对齐过去。
   * 非顶层页时 `bottomNavIndex` 返回 -1：那时 Tabs 已被卸载，不做对齐（也不向未挂载的 controller 发指令）。
   */
  private onRouteChanged(): void {
    const index = bottomNavIndex(this.route);
    if (index < 0) {
      return;
    }
    this.tabsController.changeIndex(index);
  }

  /** 路线 A：底栏单项（官方 Tabs 的 `tabBar` 自定义内容）。实参都是**常量**，选中态由子组件自读路由。 */
  @Builder
  bottomTabItem(itemKey: string, label: string, icon: string) {
    AaBottomTabItem({ itemKey: itemKey, label: label, icon: icon })
  }

  /**
   * 路线 A：四个顶层页的**内容**（次序 = `BOTTOM_NAV_ITEMS` 的 0..3）。
   *
   * ⚠️ 每个 `TabContent` 里是 `if (this.route === X)` —— **不是**无条件挂载：非当前页渲染成空节点
   * ⇒ 同一时刻只有**一个**页面组件存活（终端/文件页不会在首页就建连；切页照旧走 aboutToAppear/aboutToDisappear）。
   * ⚠️ 参数与 `build()` 里的四条原分支逐字一致。
   */
  @Builder
  topLevelPages() {
    TabContent() {
      if (this.route === Route.HOME) {
        HomeScreen()
      }
    }
    .tabBar(this.bottomTabItem('home', '首页', 'house'))

    TabContent() {
      if (this.route === Route.DEVICES) {
        DevicesScreen()
      }
    }
    .tabBar(this.bottomTabItem('devices', '设备', 'monitor'))

    TabContent() {
      if (this.route === Route.TERMINAL) {
        TerminalScreen({
          deviceId: this.paramAt(0),
          root: this.paramAt(1),
          cwd: this.paramAt(2)
        })
      }
    }
    .tabBar(this.bottomTabItem('terminal', '终端', 'terminal'))

    TabContent() {
      if (this.route === Route.FILES) {
        FilesScreen({
          deviceId: this.paramAt(0),
          root: this.paramAt(1),
          initialPath: this.paramAt(2)
        })
      }
    }
    .tabBar(this.bottomTabItem('files', '文件', 'folder'))
  }

  /**
   * 路线 A：官方 `Tabs` 壳（`barPosition: BarPosition.End` ⇒ 官方沉浸光感第 ④ 类生效位置）。
   *
   * ## 三条关键官方行为（SDK 原文，`tabs.d.ts`）
   * · `.barOverlap(true)`（**L1467**）：「the tab bar **overlaps the TabContent component with a blurred
   *  background effect**, and the **default blur style of the tab bar is set to BlurStyle.COMPONENT_THICK**」
   *  ⇒ 一行拿到两件事：① bar 叠在内容之上（内容从背后穿过）② **官方 blur**（COMPONENT_THICK）。
   *  没有 ① 时 bar 是独立布局带（R65 真机 dump：TabContent 裁到 2556、bar 2555~2832）⇒ 背后没有内容，
   *  而官方材质是折射/模糊材质 ⇒ 背后均匀纯色时「本来就和背景一样」⇒ R65 的 Δ+0.0 是**假阴性**。
   * · `.barFloatingStyle(...)`（**L1683**，参数类型 `FloatingTabBarStyle` **L824-896**）：
   *  `barWidth{{}small/medium/largeBarWidth{}}` 是**官方按断点定栏宽**的正规入口（不可用百分比），
   *  `systemMaterial` 也在这个结构里 —— **不在** `TabsOptions`（R65-C 编译期证伪过）。
   *
   * ## ⛔ R68 更正（本轮的核心）：**不要再中和官方默认行为**
   * R66-3 为了让「材质开/关」成为单变量，写了 `.barBackgroundBlurStyle(BlurStyle.NONE)` ——
   * 它中和掉的**正是用户要的那层效果本身**（参考图胶囊的通透感 = 官方 blur × 材质）⇒ 真机上只剩平板灰底，
   * 用户反馈「不像官方」。⇒ 现在**删掉那一行**，两臂都留 `barOverlap(true)` 的 COMPONENT_THICK blur，
   * A/B 的单变量改成「**`systemMaterial` 有/无**」，而且这个差异**只存在于 `floatingBarStyle()` 一个函数里**
   * （见下：Tabs 属性链因此只有**一份**，从结构上保证不会再多出第二个变量）。
   *
   * ## 其他
   * · `.barHeight(hidden ? 0 : 全高, true)`：路线 A **没有**框架级隐藏 API，自动收回只能靠 bar 条带塌陷
   *  （`noMinHeightLimit = true` 才允许小于默认最小值）。有 `barOverlap(true)` 时内容不回流 ⇒ 不会带得列表跳。
   *
   * ## R70：隐藏态「**还剩什么可渲染**」的源码级清单（逐项确认不会再有残余）
   * | 可能的绘制源 | 隐藏态取值 | 为什么画不出来 |
   * | --- | --- | --- |
   * | `barHeight`（bar 的绘制区高） | `0` | 绘制区高 0 ⇒ bar 自身与其子内容都没有像素 |
   * | 四个 `AaBottomTabItem` | 盒高随绘制区（`height('100%')`）→ 0 | item 无底色/无边框/无阴影，只剩图标+文字，盒高 0 ⇒ 不画 |
   * | `barBottomMargin`（离底间隙） | `0` | R69 之前它是 32 —— 那条「间隔带」正是用户看到的「只塌陷没消失」的残留 |
   * | `systemMaterial`（表面 + `applyShadow` 投影 + `interactive` 反馈） | `undefined`（**R70 新增**） | 字段不传 ⇒ 官方材质 / 阴影 / 按压反馈全部不存在 |
   * | `barBackgroundColor` | 恒 `Color.Transparent` | alpha = 0，且 SDK 默认值本来就是透明（L1471） |
   * | `barOverlap(true)` 自带的 `COMPONENT_THICK` 模糊 | 仍为 true | 它是 **bar 的**背景模糊，绘制范围 = bar 的绘制区 ⇒ 高 0 ⇒ 无像素 |
   * | `barBackgroundBlurStyle` | R68 已删除，回落到 barOverlap 的默认 | 同上 |
   * | `divider` | `null`（恒不画） | 已显式关闭 |
   * | `maskColor` / `maskHeight` | **从未使用** | 不传 = 无遮罩层 |
   * | 路线 B 的浮层（`bottomBarOverlay()`） | A 档下**根本不在树上** | 调用条件是 `!BOTTOM_BAR_VIA_TABS` ⇒ 为 false |
   * ⚠️ 唯一有嫌疑的是 `barOverlap` 的模糊：若真机在隐藏态**仍看到一条模糊带**，说明框架给 bar 留了最小绘制高度
   *  ⇒ 升级路径两选一（都一行）：① 隐藏态 `.barOverlap(false)`；② 隐藏态让 `floatingBarStyle()` 直接 `return undefined`。
   * ⚠️ 按用户拍板，A 档**不加** `scale` 动效 —— 收回就是「塌陷到什么都不剩」。
   *
   * ## ⚠️ R67 动画的**诚实差异**（不要假装两档一致）
   * 用户要的收回观感是「**向手势条缩小直至消失**」。路线 B 用 `scale(centerY '100%') + opacity` 做到；
   * 路线 A 的 bar 由**框架拥有**，没有「以底边为锚点缩放」这类 API ⇒ 只能把整条 bar 的高度塌陷到 0，
   * 观感是「条带被抽走/瞬间消失」，**不是**缩进手势条。⇒ 若真机判定 A 的材质成立、要按 A 收口，
   * 这条动画差异必须写进交付说明，并由你决定是接受它、还是只把「材质」按 A 走而把「动效」留在 B。
   * · `.barBackgroundColor(Color.Transparent)`：bar 底色**只**由材质/磨砂供给。
   * · `.animationDuration(0)`：切页动画关掉（路由一变旧 TabContent 立刻成空节点，带动画会滑出空白）。
   * · `.scrollable(false)`：禁用横滑切页（横滑绕过 Router，会把唯一状态源变成两个）。
   *
   */
  @Builder
  topLevelTabs() {
    Tabs(this.tabsOptions()) {
      this.topLevelPages()
    }
    .width('100%')
    .height('100%')
    // ⚠️ R68：**保留** `barOverlap(true)` 带来的官方 blur（COMPONENT_THICK）—— 它 + `systemMaterial`
    //  才是参考图那条胶囊的通透感。上一轮那句 `.barBackgroundBlurStyle(BlurStyle.NONE)` 已删除（教训见上）。
    .barOverlap(true)
    // ⚠️ R69 瘦身：`barHeight` **只表达胶囊高度**（54vp）—— R68 时给的是 86（54 胶囊 + 32 让位），
    //  框架会把胶囊本体**拉满整条 bar 带** ⇒ 真机量到 ≈71vp、比参考图的 54.3vp 胖一圈（用户反馈「太胖了」）。
    //  那 32vp 离底间隙**整段移到 `barBottomMargin`**（见 `floatingBarStyle()`）。
    //  隐藏态把两者**同时归零**（54→0 且 32→0）⇒ 条带与间隙一起消失，不再留一条。
    //  `noMinHeightLimit = true` 保证 54 这种「小于框架默认 56」的值能生效（SDK 明确 height<0 才回落默认）。
    .barHeight(this.bottomBarHidden ? 0 : this.routeBarHeightVp(), true)
    .barBackgroundColor(Color.Transparent)
    .divider(null)
    .animationDuration(0)
    .scrollable(false)
    .barMode(BarMode.Fixed)
    // 材质的「有 / 无」只在这里分叉（`floatingBarStyle()`）⇒ Tabs 属性链只有一份，结构上不存在第二个变量。
    .barFloatingStyle(this.floatingBarStyle())
    .animation({ duration: BOTTOM_BAR_ANIM_MS, curve: Curve.FastOutSlowIn })
    .onChange((index: number) => {
      this.onTabChanged(index);
    })
  }

  /**
   * 路线 B（默认）：**真浮层底栏**。
   *
   * · 它**不占布局**：根 `Stack` 里的一层浮层（`alignContent(Alignment.Bottom)`），
   *  页面内容仍是 `height('100%')` ⇒ 内容能从胶囊**背后滚过去**（截图形态）；
   * · 盒子高度 = 胶囊 60 + 离底让位 ⇒ 胶囊贴顶、下方留出手势条空间（与 R62/R63 同一套几何）；
   * · 自动收回 = `translate`(整条移出屏) + `opacity` + `animation`：平滑、且**不改变内容视口**
   *  （这正是路线 A 用 `barHeight` 塌陷做不到的）；
   * · 盒子**只有底栏那一条高**（不是铺满容器）⇒ 不会吃掉列表的手势与点击（`坑 29`）。
   */
  @Builder
  bottomBarOverlay() {
    Column() {
      // ⚠️ 缩放挂在**这一层内层包装**上（不挂 `AaBottomNav` 自己）：本工程对「自定义组件后接通用属性」零先例。
      Column() {
        AaBottomNav({
          active: bottomNavKey(this.route),
          onSelect: (key: string) => {
            bottomNavSelect(key);
          }
        })
      }
      .width('100%')
      .height(BOTTOM_NAV_HEIGHT)
      /**
       * ⚠️ R67：收回动画由「整条下移淡出」改成「**以底边中心为锚点缩小**直至消失」。
       *
       * · `centerY: '100%'` ⇒ 缩放的锚点 = 这一层的**底边**，而这一层的底边就是胶囊的底边
       *  （外层容器的 `justifyContent(FlexAlign.Start)` 把它顶在上方、下方留出离底让位）
       *  ⇒ 缩放过程中**底边钉在原地**（贴着安全区/手势条），视觉上是「缩进手势条里」，
       *  而不是原来的「整条往下滑走」（那会让底边临时跑出手势条区域）。
       * · 同步 `opacity → 0`：纯缩放会留下一个「小胶囊」，叠上不透明度才是干净的消失。
       * · 终态 `BOTTOM_BAR_HIDE_SCALE`(0.25) 而不是 0：0 在部分机型上退化成瞬间消失。
       * · `hitTestBehavior`：缩到 0.25 后命中区也跟着变小，但仍可能在底部留下一小条**看不见却可点**的区域
       *  ⇒ 隐藏态显式置 `HitTestMode.None`（自身与子节点都不响应），恢复显示态回 `Default`。
       */
      .scale({
        x: this.bottomBarHidden ? BOTTOM_BAR_HIDE_SCALE : 1,
        y: this.bottomBarHidden ? BOTTOM_BAR_HIDE_SCALE : 1,
        centerX: '50%',
        centerY: '100%'
      })
      .opacity(this.bottomBarHidden ? 0 : 1)
      .hitTestBehavior(this.bottomBarHidden ? HitTestMode.None : HitTestMode.Default)
      .animation({ duration: BOTTOM_BAR_ANIM_MS, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height(this.areaBarHeightVp())
    // R67：留边由 `Space.PAGE`(18vp) 改成**参考图实测的屏宽 18%**（≈79vp @438.7vp 屏宽）。
    .padding({ left: BOTTOM_BAR_SIDE_MARGIN, right: BOTTOM_BAR_SIDE_MARGIN })
    .justifyContent(FlexAlign.Start)
  }

  build() {
    Stack() {
      this.immersiveBackground()

      /**
       * **底栏的两条路线**（R66-3，编译期开关 `BOTTOM_BAR_VIA_TABS`）：
       *
       * · **路线 A**（`true`，**R68 起默认**）：四个顶层页由官方 `Tabs` 承载
       *  （`barPosition: BarPosition.End`）—— 底栏就是 Tabs 的 bar，才能落在官方沉浸光感的生效范围内
       * （`坑 245` 第 ④ 类）。关键见 `topLevelTabs()`：`.barOverlap(true)`
       *  既让**内容从 bar 背后穿过**、又**保留官方默认 blur**（COMPONENT_THICK）—— 后者正是参考图那种通透感的来源，
       *  R66-3 曾用 `barBackgroundBlurStyle(NONE)` 把它中和掉，R68 已删除（教训见 `ui/BottomNav.ets` 文件头）。
       * · **路线 B**（`false`，回退档）：页面照旧（下面这串分支），底栏是根 `Stack` 里的一层**浮层**
       *  （`bottomBarOverlay()`，内容同样从背后滚过去）—— 自绘胶囊 + 缩进手势条的收回动画。
       *
       * ⚠️ R65 的教训：底栏背后**必须真的有内容**才谈得上材质。R65 那次 bar 是独立布局带
       * （TabContent 裁到 2556、bar 2555~2832）⇒ 背后是均匀纯色 ⇒ 官方材质本来就该长得和背景一样，
       * 当时的 Δ+0.0 是**假阴性**。
       */
      if (BOTTOM_BAR_VIA_TABS && bottomNavIndex(this.route) >= 0) {
        this.topLevelTabs()
      } else if (this.route === Route.LOGIN) {
        LoginScreen()
      } else if (this.route === Route.SERVER_SETUP) {
        // TODO(login 包)：上游是独立目的地 `ServerSetup`（自建服务地址页）。
        // 本工程目前把「选服务 + 登录」合并在 LoginScreen 内的分段里（结构等价）。
        this.pendingDestination()
      } else if (this.route === Route.QR_LOGIN) {
        // TODO(login 包)：上游 `QrLogin` —— 本工程是 LoginScreen 内的「扫码」分段。
        this.pendingDestination()
      } else if (this.route === Route.QR_WAITING) {
        // TODO(login 包)：上游 `QrWaiting`（带 `pendingMobileLoginQr` 参数）。
        this.pendingDestination()
      } else if (this.route === Route.HOME) {
        HomeScreen()
      } else if (this.route === Route.NEW_CHAT) {
        // R53 第一步：点首页「+」→ **选择工作区**（一个选择器页，不是对话界面）。
        NewChatWorkspaceScreen()
      } else if (this.route === Route.DRAFT_SESSION) {
        // R53 第二步：选定工作区后进**原对话页**的草稿态（用户明确要求「不要另做一个对话界面」）。
        // sessionId 传空串：真正的会话在第一条消息发出时才由 store 创建（`create-and-start`），
        // 页面本身仍是会话详情页 —— 输入区 / ⚙ 运行时设置 / 时间线都用同一套。
        SessionDetailScreen({ sessionId: '', draftParam: this.param })
      } else if (this.route === Route.NEW_PROJECT) {
        // 上游 `NewProject` 与 `NewSession` **共用同一个屏**（projectOnly 模式）：
        // NewSessionScreen 内部用 `Router.current().route === Route.NEW_PROJECT` 自行判定，
        // 不需要额外参数（第十轮由新建会话包实现、Lead 接线）。
        NewSessionScreen()
      } else if (this.route === Route.DEVICES) {
        // 上游 `Devices` 是**顶层目的地**（首页快捷卡片的第一个入口），顶部不画返回钮。
        // 第十轮由设备域包新建、Lead 接线。
        DevicesScreen()
      } else if (this.route === Route.TERMINAL) {
        TerminalScreen({
          deviceId: this.paramAt(0),
          root: this.paramAt(1),
          cwd: this.paramAt(2)
        })
      } else if (this.route === Route.FILES) {
        FilesScreen({
          deviceId: this.paramAt(0),
          root: this.paramAt(1),
          initialPath: this.paramAt(2)
        })
      } else if (this.route === Route.DEVICE) {
        DeviceDetailScreen({ deviceId: this.param })
      } else if (this.route === Route.SESSION) {
        SessionDetailScreen({ sessionId: this.param })
      } else if (this.route === Route.ARCHIVED) {
        ArchivedSessionsScreen()
      } else if (this.route === Route.ADD_DEVICE) {
        AddDeviceScreen()
      } else if (this.route === Route.SETTINGS) {
        SettingsScreen()
      } else {
        HomeScreen()
      }

      /**
       * **路线 B 的浮层底栏**（`BOTTOM_BAR_VIA_TABS === false` 时生效）。
       * 叠在内容之上、不占布局 ⇒ 内容从胶囊背后滚过去；只有 `OVERLAY_BAR_ROUTES` 里的路由才画
       * （过渡态：Devices/Terminal/Files 三页当前仍各自挂载底栏，见 `ui/BottomNav.ets` 的同名常量）。
       */
      if (!BOTTOM_BAR_VIA_TABS && overlayBarShownOn(this.route)) {
        this.bottomBarOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // ⚠️ R66-3：根 Stack 改成**靠底对齐** —— 浮层底栏要贴在屏幕下缘。
    // 其余子节点（`immersiveBackground()` 与页面根）都是 `width/height('100%')` ⇒ 对齐方式对它们无影响。
    .alignContent(Alignment.Bottom)
    /**
     * ⚠️⚠️ **本页不要用 `expandSafeArea` 做沉浸**（R13-11 / R13-12 / R13-13 三次真机返工的结论）：
     *
     * 它名义上是「扩展绘制范围」，但在**百分比尺寸**下会**连组件自身尺寸一起扩**
     * （SDK `common.d.ts` 的 `Expands the safe area`：固定宽高才被限制为仅 TOP/START），
     * 而内部 `width/height('100%')` 的节点以**已扩展的容器**为坐标系 ⇒ 内容照样进系统栏。
     * 实测：挂根节点上 5865 墨点、改成「背景层 + 内容层」两层后仍是 **5897 墨点**（安卓 2150）——
     * 分层**在这条 API 语义下不成立**（内容层是那个已扩展 Stack 的子节点）。
     *
     * ⇒ 两件事**必须显式成对做**：
     *  ① 系统栏区域像页面底色 → `EntryAbility.syncSystemBarColors()`（`statusBarColor`/`navigationBarColor` = 画布色）；
     *  ② 内容留在安全区内 → 本页根节点的 `padding`（高度由 EntryAbility 实测避让区写入 AppStorage）。
     * ⚠️ 「不写 expandSafeArea 就自动避让」**不成立**：沉浸态下 ArkUI 不替应用避让
     * （真机 dump：搜索图标 y=51、标题被压进状态栏只剩 7px），所以 ② 必须显式给。
     */
    .backgroundColor(canvas())
    /**
     * **显式避让系统栏**（R13-12）：沉浸态下 ArkUI 不会自动避让，`expandSafeArea` 又只能「取消」避让，
     * 所以内容层必须自己让出状态栏与手势条 —— 高度取 `EntryAbility` 实测的避让区（px → vp），
     * 不写死像素（横竖屏 / 手势条显隐 / 不同机型都不同）。
     * 背景铺满由 EntryAbility 的系统栏配色承担（`statusBarColor` / `navigationBarColor` = 画布色）。
     */
    // ⚠️ R13-15：**只避让顶部**。底部避让下放到各页面自己的底部元素（TerminalScreen.extraKeys() /
    // SessionDetailScreen.composer() / AddDeviceScreen 的动作行）—— 根节点再避让一次会让列表底部
    // 多出整整一条安全区高度的空白（用户连问两次的「底部大块空白」）。
    //
    // ⚠️⚠️ R37 五改：**顶部避让也从这里下放到各页面的顶栏了**（改前是 `.padding({ top: … })`）。
    // 用户要求「最上面系统状态栏那条也要和上方功能栏一样的模糊，确保视觉统一性」——
    // 状态栏区域要能被内容**穿过**（毛玻璃才糊得到东西），页面内容就必须铺到屏幕顶。
    // 根节点一 padding，页面顶栏就被推到状态栏之下，那一条永远是纯色画布色。
    // 现在各页面顶栏自己加 `topInset()`：**内容仍留在安全区内，而顶栏的背景（毛玻璃）铺到屏幕顶**。
    // 新增页面时别忘了这一条（漏了的表现：该页顶栏被状态栏压住）。
  }

  private paramAt(index: number): string {
    const parts = this.param.split('|');
    return index < parts.length ? parts[index] : '';
  }

  /** 尚未实现的目的地 → 中文名（用于下面那个兜底页）。 */
  private pendingLabel(): string {
    if (this.route === Route.SERVER_SETUP) {
      return '服务器设置（ServerSetup）';
    }
    if (this.route === Route.QR_LOGIN) {
      return '扫码登录（QrLogin）';
    }
    if (this.route === Route.QR_WAITING) {
      return '扫码等待（QrWaiting）';
    }
    if (this.route === Route.NEW_PROJECT) {
      return '新建项目（NewProject）';
    }
    if (this.route === Route.DEVICES) {
      return '设备列表（Devices）';
    }
    return this.route;
  }

  /**
   * 未实现目的地的兜底页。
   *
   * ⚠️ 刻意**不**让它落进 `else { HomeScreen() }`：
   * 第八轮踩过「推送一个没有分支的路由 → 静默渲染首页」——用户看到的是首页，
   * 既不像报错也不会有人发现「这个目的地根本没接线」。这里给一个明确的提示页 + 回首页入口。
   * ⚠️ @Builder 不带值参数（只读 this 上的 @StorageLink），避免值参数停在首建快照。
   */
  @Builder
  pendingDestination() {
    Column({ space: Space.M }) {
      Text('该页面尚未实现')
        .fontSize(FontSize.TITLE)
        .fontColor(ink())
      Text(this.pendingLabel())
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
      Text('返回首页')
        .fontSize(FontSize.BODY)
        .fontColor(ink())
        .padding({ left: Space.L, right: Space.L, top: Space.S, bottom: Space.S })
        .borderRadius(Radius.M)
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .onClick(() => {
          Router.back();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(canvas())
  }
}
