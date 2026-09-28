/**
 * 远程终端页面（对应 Android `ui/screens/terminal/TerminalScreen.kt` +
 * `com.termux.view.RemoteTerminalView` 的渲染/滚动手势）。
 *
 * **顶层目的地**（与首页平级，由首页快捷卡片进入），页内自带设备选择器 —— 复刻上游的
 * `TerminalScreen.kt` 结构：默认选中第一个在线设备（`firstOrNull { it.online }`），
 * 顶栏是「40dp 圆形返回钮 + 44dp 设备选择条」，点开只列**在线设备**的下拉；
 * 无设备 / 全离线各有专门空态；返回一律回首页（上游 `navigate(Sessions)`）。
 * 与文件页（`FilesScreen.ets`）**结构逐字同构**，两页共用本文件末尾「设备选择（纯逻辑）」区的函数。
 *
 * 渲染方式：用 `Canvas` 按「单元格网格」自绘——这是终端唯一可行的做法
 * （每行按样式分段 fillText，宽字符占两格，反显/下划线/删除线单独画线）。
 * 输入方式：
 * - 额外按键行（ESC/TAB/CTRL/ALT/方向键/Home/End/PgUp/PgDn/^C/^D/^Z/符号）；
 * - 一个 1x1 的透明 TextInput 承接软键盘，走**系统输入法的上屏回调**
 *  （`onWillInsert`）逐字符写回 PTY —— 候选串（拼音预上屏）不会被写进去；
 * - 输入法不提供该回调时（如硬件键盘）退化为「输入框累积 + 回车整段送入」，
 *  见 `submitFromKeyboard`。两条通道的判定见文件末尾的「输入策略（纯逻辑）」区。
 */

import { TerminalStore, TerminalConnectionState } from '../../feature/TerminalStore';
import { DashboardStore } from '../../feature/DashboardStore';
import { AgentDevice } from '../../model/AppModels';
// 设备级终端的 root 契约常量：与 FilesScreen 共用 `model/DirBrowse.ets` 里那一份
// （`HOME_ROOT = '~'`，锚上游 `TerminalController.kt:72` 的 `root = "~"`）。
import { HOME_ROOT } from '../../model/DirBrowse';
import { TerminalRow } from '../../vt/TerminalRow';
import { TerminalStyle, TerminalStylePool, TextStyleFlags, colorToHex, resolveColor, hasUnderline } from '../../vt/TerminalStyle';
import {
  TERMINAL_KEY_ROWS, ExtraKey, MODIFIER_ALT, MODIFIER_CTRL, MODIFIER_SHIFT,
  backspaceKey, ctrlSequence, enterKey, resolveExtraKey
} from '../../vt/KeyHandler';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, faint, ink, inkSoft, muted,
  onPrimaryAction, primaryAction, raisedSurface,
  SAFE_AREA_BOTTOM_PX,
  glassCardSurface
} from '../Design';
// R66（SPEC §2）：标题栏（功能栏）本体与栏内胶囊的**官方沉浸材质**走本工程唯一构造入口
// `Components.ets#officialBarMaterial(color)` —— 页面**不得**直接 import `uiMaterial`
// （Kit 依赖收口在 Components.ets；`suite-files.mjs` 有依赖卫生断言，lead 已裁决签名）。
import {
  AaCircleIconButton, AaErrorBanner, AaPrimaryIconButton, AaSecondaryButton, officialBarMaterial,
  // R86：半模态（`pastePanel` 的 `bindSheet`）底走 `panelMaterial()`（THIN 档）。
  // 与 `officialBarMaterial` 同一处收口 —— 页面**不得**自己 import `uiMaterial`（契约 §1.6）。
  panelMaterial
} from '../Components';
import { display } from '@kit.ArkUI';
import { Route, Router } from '../Router';
import { AaIcon, ICONS } from '../Icon';
import { BOTTOM_BAR_RESERVED_VP } from '../BottomNav';
import { AppearanceController, isDarkAppearance } from '../../feature/AppServices';

const FONT_SIZE: number = 13;
/** 目标可见列数（手机竖屏约 45~55 列比较舒服）。 */
const TARGET_COLUMNS: number = 48;
const LINE_HEIGHT: number = 17;
const CELL_WIDTH_ESTIMATE: number = 7.8;
/**
 * 承接软键盘的透明输入框 id。
 * 它只有 1x1 且透明，用户点不到，必须由画面点击处 `focusControl.requestFocus` 主动聚焦，
 * 否则终端里没有任何办法唤起输入法。
 */
const TERMINAL_INPUT_ID: string = 'aaTerminalInput';
/**
 * 设备下拉与锚点条的间距（上游 `AADropdownMenu` 的 `MenuGap = 4.dp`）。
 * ⚠️ 下面这几个常量被 `FilesScreen.ets` 一起 import —— 两页的设备选择条是同一种形态，
 * 数值只留这一处（同构靠共享实现，不靠两份复制）。
 */
export const MENU_GAP: number = Space.XS;
/**
 * 菜单左边缘 = 页面水平内边距 + 返回钮直径 + 两者间距。
 * 上游把菜单挂在与锚点条**同一个 Box** 里（左缘对齐），这里换算成根 Stack 的绝对坐标。
 */
export const MENU_LEFT: number = Space.PAGE + Control.NAV_BUTTON_LARGE + Space.M;
/**
 * `Navigation` 标题栏**那一行的顶边**在**页面坐标系**里的 y（vp）。
 *
 * ⚠️ 这是**框架常量、与行高无关**，两处真机证据：
 *  · `HomeScreen` R62 记录：`Navigation.onAreaChange` 报 `top=0`，而 `homeTitleBar()` 的构造器报
 *  `top=**56vp**`（= 绝对 **166px**，与 `dumpLayout` 吻合）；
 *  · R80/R81 复核：`titleMode: Full` 的槽恒为 `TitleBar [0,137][1316,332]`，**46vp 行与 64vp 行的
 *  构造器顶边都在 166px** ⇒ 栏内控件垂直中心 = `166 + 行高/2`。
 * ⇒ 本页根 `Stack`（`deviceMenuLayer()` 的 `.position()` 就以它为原点）的顶边 = 屏幕顶 **0**，
 *  而标题行是从 **56vp** 起算的 —— **凡是以"页面根"为原点却按"标题行"数偏移的常量都要加回这一项。**
 * ⚠️ 顶栏进框架标题栏（R65-B）之前，标题栏是**自绘**且就挂在页面根最顶上（基准 = 0）；
 *  那之后这条基准就变了，这正是 R81 要收口的「从旧行高派生的量」。
 */
export const NAV_TITLE_ROW_TOP: number = 56;
/**
 * 菜单上边缘 = **标题行顶边** + 行内锚点条的垂直居中偏移 + 锚点条高度 + 间距。
 * · 行高 `Control.NAV_TITLE_ROW`=46（R81）、锚点条 `Control.FIELD`=44 ⇒ 居中偏移 (46-44)/2 = 1；
 * · R65-B 之前的老式子是 `(64-44)/2 + 44 + 4 = 58`（那时基准就是 0，自绘顶栏在页面根最顶上）；
 *  R65-B 把顶栏移进框架标题栏、R81 统一行高之后，一并收口成：
 *  `56 + 1 + 44 + 4 = **105**`（vp）。
 * ⚠️ 真机复测时：锚点条底 ≈ 166 + 1 + 131 = 298px，菜单顶应在 **≈312px**（= 105vp）；
 *  若发现差整整 ~56vp（而不是几 px），先查 `NAV_TITLE_ROW_TOP` 这一项，别先怀疑 `MENU_GAP`。
 */
export const MENU_TOP: number = NAV_TITLE_ROW_TOP
  + (Control.NAV_TITLE_ROW - Control.FIELD) / 2 + Control.FIELD + MENU_GAP;
/** 空态插图字号（本工程没有 `ic_sessions_empty` 那类位图，用字符近似；上游位图 188×156dp）。 */
export const EMPTY_ILLUSTRATION_SIZE: number = 56;
/**
 * 「清空终端」悬浮钮的几何（逐字取自上游 `TerminalClearButton` 的 `Modifier`，
 * `SessionAgentFilesScreen.kt:713-722`）：`.size(34.dp)` + `.padding(top = 10.dp, end = 18.dp)`。
 */
export const CLEAR_BUTTON_SIZE: number = 34;
export const CLEAR_BUTTON_TOP: number = 10;
export const CLEAR_BUTTON_END: number = 18;

@Component
export struct TerminalScreen {
  @Prop deviceId: string = '';
  /**
   * 工作区根。**设备级终端**的 root 契约是上游硬编码的 `"~"`
   * （`feature/terminal/TerminalController.kt:72` `openDeviceTerminal` → `root = "~"`；
   * 会话级终端才用 `session.cwd`，同文件 23 行 `session.cwd?.takeIf { it.isNotBlank() }`）。
   *
   * ⚠️ 默认值写成 `'.'` 曾是本页「一进就出错」的根因：首页快捷卡片
   * `HomeScreen.quickEntryCard('终端', '>_', Route.TERMINAL)` 只 `Router.push(target)`，
   * **不带路由参数** → `Index.ets` 的 `paramAt(1)` 返回空串 → 而这种传参下 `@Prop` 的
   * 默认值**不生效**，空串被 `TerminalApi` 拼成 `?root=` → 服务端
   * `root: str = Query(..., min_length=1)` 直接 422（真机复现见简报）。
   * 现在默认值即 `~`，并且 `openSelected()` 再走一次 `effectiveTerminalRoot()` 归一。
   */
  @Prop root: string = HOME_ROOT;
  @Prop cwd: string = '.';
  @Prop label: string = '终端';

  // ⚠️ 状态必须在 build 里被真正读到才会触发刷新（见 HomeScreen 顶部注释）。
  @State titleText: string = '终端';
  /**
   * 底部安全区高度（px，`EntryAbility.pushSafeAreaInsets()` 实测写入）。
   * R13-15：底部避让由**本页自己的底部元素**承担（根节点只避让顶部，否则列表底部会多一条空白）。
   */
  @StorageLink(SAFE_AREA_BOTTOM_PX) safeAreaBottomPx: number = 0;
  @State statusLabel: string = '';
  /**
   * 连接/创建失败的**服务端原文**（`store.error` 的页面快照）。
   * 只读快照而不是直接读 store —— ArkUI 不会因为 class 内部字段变化而刷新（坑 134）。
   */
  @State errorText: string = '';
  @State streaming: boolean = false;
  @State cols: number = 80;
  @State rows: number = 24;
  @State ctrlArmed: boolean = false;
  @State altArmed: boolean = false;
  @State mirror: string = '';
  @State pasteSheet: boolean = false;
  @State pasteText: string = '';
  @State canvasWidth: number = 0;
  @State canvasHeight: number = 0;
  /**
   * 设备列表（已按上游 `sortedForDevicesPage()` 排序：在线优先 → createdAt → name）。
   * 上游是 `remember(state.devices) { state.devices.sortedForDevicesPage() }`，数据源是工作台。
   */
  @State devices: AgentDevice[] = [];
  /** 当前选中的设备 id（上游 `selectedDeviceId`：页面内局部状态，不跨页保持）。 */
  @State selectedDeviceId: string = '';
  /** 设备选择下拉是否展开（对应上游锚点行里的 `expanded`）。 */
  @State deviceMenuOpen: boolean = false;

  private store: TerminalStore = TerminalStore.get();
  /** 工作台 store：设备列表的唯一数据源（对应上游 `state.devices`）。 */
  private dashboard: DashboardStore = DashboardStore.get();
  /** 存成字段才能被 `offChange` 摘除（单例 store 的监听器数组只增不减）。 */
  private storeListener: () => void = () => {
    this.pull();
    this.draw();
  };
  private dashboardListener: () => void = () => {
    this.syncDevices();
  };
  /**
   * 外观切换 → 重设 VT 配色（R20）。
   *
   * 上游在 `AndroidView.update` 里**每次重组**都调 `applyTerminalColors(controller, darkMode)`
   * （锚文 `SessionAgentFilesScreen.kt:700-707`），所以切深浅色时终端底色跟着翻；
   * 本工程原先在构造时硬编码 `dark = true` 且再没改过 ⇒ 浅色主题下终端永远是黑底。
   */
  private appearanceListener: () => void = () => {
    this.store.applyAppearance(isDarkAppearance());
    this.draw();
  };

  aboutToAppear(): void {
    this.dashboard.onChange(this.dashboardListener);
    this.store.onChange(this.storeListener);
    // ⚠️ 必须排在首次 `draw()` 之前：store 的单例构造里给的是深色占位色表。
    this.store.applyAppearance(isDarkAppearance());
    AppearanceController.onChange(this.appearanceListener);
    // 每次进入终端页都重建终端实例（用户要求「打开即刷新」）。
    // 复用旧实例有两个后果：
    //  ① 上一轮画面留在本地缓冲里，新提示符追加在后面 ⇒ 每打开一次多一行 PS ...>；
    //  ② 页面初始网格是 80x24，而旧实例的实际网格是屏宽算出来的（如 56x43），
    //  一进一出会 resize 两次：远端 shell 每次重绘提示符，本地缓冲扩张时补的空行
    //  被 unshift 到屏幕顶部 ⇒ 内容掉到屏幕中间（真机复现）。
    this.store.close();
    // 用**上一次实测**的网格尺寸打开（store 是单例，跨页面存活），
    // 避免首帧拿 80x24 去抖一次远端 PTY。
    if (this.store.cols > 0 && this.store.rows > 0) {
      this.cols = this.store.cols;
      this.rows = this.store.rows;
    }
    // 先定下选中设备（路由参数优先 → 第一个在线设备），再连终端。
    // 上游的顺序一样：`selectedDeviceId` 先由 remember 初始化，`LaunchedEffect` 再纠正。
    this.syncDevices();
    this.openSelected();
  }

  aboutToDisappear(): void {
    // 不主动关闭终端：返回后仍可在其它入口复用（与服务端 scrollback 语义一致）。
    // 但**必须**摘掉监听器 —— store 是单例，留着会让已销毁的页面继续被 notify，
    // 在 detached 节点上重绘 Canvas。
    this.store.offChange(this.storeListener);
    this.dashboard.offChange(this.dashboardListener);
    // 与上面同理：`AppearanceController.listeners` 也是静态数组，只增不减就是泄漏。
    AppearanceController.offChange(this.appearanceListener);
  }

  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private cellWidth: number = CELL_WIDTH_ESTIMATE;
  private density: number = 0;
  /**
   * R57 性能轮（B1）：字体步进的缓存。
   * 改前：draw() 每帧（PTY 高频输出时 30+ 次/秒）都重设 `context.font` + 全量 `measureText` 一次。
   * 字号与密度在一帧的生命里都不变，样本宽度是常数 —— 每次重量是纯浪费。
   * 改后：只有「上次应用的 fontPx 变了」才重设 font 并重测样本；cellWidth 的反推与
   * recomputeGrid 语义**一行不动**（targetCell 公式、0.01 容差原样保留）。
   * 回退：把 `applyFontIfNeeded(fontPx)` 内联回原来的三行即可。
   */
  private measuredSample: number = 0;
  private lastFontPx: number = 0;
  private metrics: string = '';
  /** 长按标题切换「网格度量」显示（诊断用，默认不占界面）。 */
  @State showMetrics: boolean = false;
  /** 有没有活的终端实例 —— 决定右上角「清空终端」按钮的启用态（上游 `terminalKey != null`）。 */
  @State hasTerminal: boolean = false;
  /**
   * 系统输入法的「上屏」回调（`onWillInsert`）是否出现过 —— 组合态守卫的核心状态。
   *
   * ⚠️ 第七轮审计发现的缺陷就出在这里：老实现把 `onChange` 当成「已上屏」信号，
   * 而拼音/日文输入法在**候选阶段**（预上屏）也会触发它，于是候选串被逐字符写进 PTY。
   * SDK 对 `onWillInsert`/`onDidInsert` 的注释明确写着「not triggered for pre-edit or
   * candidate word operations」，所以只有它才是可信的上屏信号。
   *
   * 代价：输入法不提供该回调（如硬件键盘）时退化为「一行输入 + 回车整段送入」，
   * 见 `submitFromKeyboard` —— 这条路上英文同样不会丢，只是不再逐字符即时。
   */
  private systemInsertAlive: boolean = false;
  /** 兜底通道里输入框累积的文本（系统插入通道可用时恒为空）。 */
  private mirrorText: string = '';
  /**
   * 回看偏移（行）。0 = 跟随最新输出；> 0 表示整屏上移了多少行历史。
   * VT 层本来就有 scrollback（`TerminalBuffer.screenFirstRow`），这里只是把它渲染出来 ——
   * 没有它，Agent 跑出一条长输出后用户**只能看清屏、翻不回去**。
   */
  @State scrollBack: number = 0;
  /** 一次拖拽的起点（`onActionStart` 记录，`onActionUpdate` 累计位移）。 */
  private dragStartOffset: number = 0;

  // -------------------------------------------------------------------------
  // 顶层页：设备选择（与 FilesScreen 逐字同构，纯逻辑在文件末尾，见 suite 断言）
  // -------------------------------------------------------------------------

  /**
   * 工作台设备列表 → 页面状态（排序 + 默认选中）。
   *
   * 上游是两段合起来的语义：`remember(state.devices) { sortedForDevicesPage() }` +
   * `LaunchedEffect(devices) { if (devices.none { it.id == selectedDeviceId && it.online })
   * selectedDeviceId = devices.firstOrNull { it.online }?.id }` —— 也就是
   * 「当前选中掉线了就自动换一个在线的；路由带了 deviceId 就先用它」。
   */
  private syncDevices(): void {
    const sorted = sortDevicesForPage(this.dashboard.devices);
    this.devices = sorted;
    // `@Prop deviceId` 只当**初次**的首选：从设备详情 / 会话文件页进来时带着设备，
    // 用户在本页主动切换过之后就以页面内状态为准（上游没有这个入口，是本工程的兼容口径）。
    const preferred = this.selectedDeviceId.length > 0 ? this.selectedDeviceId : this.deviceId;
    const next = pickDefaultDeviceId(sorted, preferred);
    if (next === this.selectedDeviceId) {
      return;
    }
    this.selectedDeviceId = next;
    this.deviceMenuOpen = false;
    this.openSelected();
  }

  /** 用当前选中设备连终端；没有可选设备时什么都不做（此时界面是空态）。 */
  private openSelected(): void {
    if (this.selectedDeviceId.length === 0) {
      return;
    }
    // root 归一：空串 / 纯空白 / `.` 一律落到设备级终端的 `~`（见 `effectiveTerminalRoot`）。
    this.store.open(
      this.selectedDeviceId, effectiveTerminalRoot(this.root, HOME_ROOT), this.cols, this.rows, this.cwd);
  }

  /**
   * 当前「真正选中」的设备：必须**在线**才算（对齐上游 `devices.firstOrNull { it.id == … && it.online }`）。
   * 离线设备仍留在列表里，但不会被当成选中项 —— 界面转而显示离线空态。
   */
  private selectedDevice(): AgentDevice | undefined {
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (device.id === this.selectedDeviceId && device.online) {
        return device;
      }
    }
    return undefined;
  }

  /** 是否至少有一台在线设备（决定选择条可不可点、要不要显示离线空态）。 */
  private hasOnlineDevice(): boolean {
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].online) {
        return true;
      }
    }
    return false;
  }

  /** 选中设备的显示名（无在线设备时是上游的 `devices_no_online`）。 */
  private selectedDeviceLabel(): string {
    const device = this.selectedDevice();
    return device !== undefined ? device.name : '暂无在线设备';
  }

  /** 选中设备（供菜单打勾用，离线设备的 id 不算选中）。 */
  private selectedDeviceIdOrEmpty(): string {
    const device = this.selectedDevice();
    return device !== undefined ? device.id : '';
  }

  /** store → @State 快照（build 只读这些字段）。 */
  private pull(): void {
    this.titleText = this.store.terminalTitle;
    this.statusLabel = this.connectionLabel();
    this.streaming = this.store.state === TerminalConnectionState.STREAMING;
    this.errorText = this.store.error;
    // 「清空终端」按钮的启用态（上游 `enabled = terminalKey != null`）：
    // 存进 @State 才会登记渲染依赖 —— 直接读 `this.store.terminal` 在 build() 里
    // 不会随 store 变化重绘（坑 134）。
    this.hasTerminal = this.store.terminal !== undefined;
  }

  build() {
    // 根 Stack：主内容 + 设备下拉浮层。
    // ⚠️ 浮层**不挂在根节点**上（根节点已经挂了 `bindSheet` 粘贴面板）—— 同一节点挂多个弹层会
    // 「后写覆盖先写」（EXPERIENCE §34；第八轮 D2 那个 sheet 永不呈现就是这么来的）。
    Stack({ alignContent: Alignment.TopStart }) {
      // R65-B（设计规格 §2）：正文包进 `Navigation`，顶栏改作它的**标题栏**（`this.navTitleBar()`）。
      //
      // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏布局在内容**上方**、占自己一行）而不是 `STACK`：
      //  STACK 会把它**叠在内容上**，那就得自己给内容让位（`contentStartOffset` 那套），而
      //  设计规格 §2 明写「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
      //
      // ⚠️ 设备下拉浮层仍是本 Stack 的**后一个兄弟**（见下方 `deviceMenuLayer()`）：它的
      //  `.position({ x: MENU_LEFT, y: MENU_TOP })` 以**页面根**为原点 ——
      //  而 R65-B 起标题栏已经**不在页面根的最顶上**了（它在框架标题栏里，行顶边在 `NAV_TITLE_ROW_TOP`
      //  = 56vp 处）⇒ 这个锚点常量**必须**把那一项算进去，见 `MENU_TOP` 的注释（R81 收口）。
      Navigation() {
        Column() {
          this.deviceStatusLine()
          this.errorBanner()
          if (this.devices.length === 0) {
            // 上游：`devices.isEmpty()` → AppEmptyState(terminal_pair_first, 配对新设备)
            this.emptyState('先配对一台设备，再打开终端。', '配对新设备')
          } else if (this.selectedDevice() === undefined) {
            // 上游：有设备但一台都不在线 → EmptyTerminalMessage(terminal_all_devices_offline)
            this.emptyMessage('先让一台设备上线，再打开终端。')
          } else {
            this.terminalBody()
            this.extraKeys()
          }

        // R66-3：底栏**已上移到 `pages/Index.ets` 的浮层**，本页不再挂 `AaBottomNav`。
        // 浮层不占布局 ⇒ 整页内容必须自己让出「底栏那一条」（见下面 Column 的 padding）。
        // ⚠️ 功能键行自己的 `.margin({ bottom: px2vp(safeAreaBottomPx) })` **保留不动** —— 那是它
        //  R13-15 起就有的**手势条**避让；两者相加（安全区 + `BOTTOM_BAR_RESERVED_VP`=86vp）
        //  才是对「手势条 + 浮层底栏」的完整避让。
        }
        .width('100%')
        .height('100%')
        // ⚠️ R66-3：为**浮层底栏**预留底部一条（`Index` 的浮层不占布局，必须由内容自己让位，
        //  否则终端网格与功能键行会被胶囊压住）。功能键行另有手势条 margin，两者相加才是完整避让。
        .padding({ bottom: BOTTOM_BAR_RESERVED_VP })
      }
      // 标题栏 = 顶栏一行；底色**透明**，让标题栏自己的**官方材质**（`navTitleBar()` 的 `systemMaterial`）透出页面底色。
      .title(this.navTitleBar(), { backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      // ## R66-1 修正（两轮真机证据 + SDK 逐行核对才定下来）：**必须显式 Full**。
      // · 缺省 ≠ Full：SDK `titleMode` 原文 **Default value: NavigationTitleMode.Free**；R66 SPEC 里
      //  「缺省是 Full」是误判。**Free** 的主标题**随内容滚动收起 / 改变位置**（SDK :224-243）
      //  ⇒ 真机就是用户截图的「顶栏整条消失、状态栏后面留残影」（缺陷 ① 的真因，不是 Full）。
      // · **Mini**（R66-1 第一版）确实钉住了，但真机 dump + 截图实测：它的 56vp **从窗口顶 y=0 起算**
      //  ⇒ 标题栏落在 y≈30..128px，与状态栏带（0..136px 的时钟/信号/电池）**重叠**；框架里的
      //  `TitleBar` 可见部分只剩 `[0,137][1316,166]`（29px），且 56vp < 本页栏高 ⇒ 栏被钳、按钮被压扁。
      //  **Mini / Free 两档都不合用**（⛔ 别再改回 Mini，已证伪）。
      // · **Full**：SDK 原文「The title is **fixed** at full mode」、标题栏高 **112vp**（:244-255）；本工程
      //  R62/R65 真机实测（未加 titleMode 的 Free 静止态 = Full）为 `TitleBar [0,137][1316,332]`
      //  ⇒ 栏内容落在 **46..112vp（状态栏之下）**，正是 R65 那版被验收过的几何，且 112vp 容得下本页栏高。
      //  ⇒ **Full = 常驻钉住 + 落在状态栏之下**，不需要任何安全区补丁（**不再叠任何安全区 API / padding**）。
      .titleMode(NavigationTitleMode.Full)
      .hideToolBar(true)
      .width('100%')
      .height('100%')

      if (this.deviceMenuOpen) {
        this.deviceMenuLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(canvas())
    .bindSheet($$this.pasteSheet, this.pastePanel(), {
      height: 280,
      dragBar: true,
      // R37 六改：系统关闭按钮真机实测**点不动**（见 DeviceDetailScreen 的注释）⇒ 统一关掉。
      // 面板另有「下滑关闭 / 点面板外关闭」两个入口。
      showClose: false,
      // ## R86：粘贴半模态的**底**改由官方沉浸光感接管（本行是这处唯一变化，几何一字未动）
      // · 官方依据：`SheetOptions.systemMaterial`（SDK `common.d.ts:12155`）。
      // · 生效范围：`bindSheet` 属**弹窗类接口** ⇒ 依官方「生效范围」在**页面内全部区域**生效
      // （`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）；
      //  终端画布与按键区属页面正文，不在本条内（它们的底不动）。
      // · 档位 `panelMaterial()`（THIN）：面板内是用户要读的说明 + 待粘贴文本，取薄档保可读性。
      // · 关闭姿势 = `uiMaterial.Material.empty`（= disable，SDK `uiMaterial.d.ts:467-472`），由
      //  `panelMaterial()` 在探针不可用时自己返回；**不得**改传 `undefined`（官方语义 =
      //  「恢复组件默认材质」，`common.d.ts:22632-22633` / `坑 256`）。
      // · 保留 `blurStyle`：官方只不建议材质与底色/描边/描边宽/投影同用（`common.d.ts:22625-22630`），
      //  未禁止模糊；它也是材质不可用时本面板唯一的底。回退 = 删掉下面这一行。
      systemMaterial: panelMaterial(),
      blurStyle: BlurStyle.Thin
    })
  }

  /**
   * 顶栏下方的状态条（**与上游的已知差异**：上游顶栏没有这一行）。
   *
   * 它承载三件本工程既有、不能因为复刻而丢的东西：网格/连接读数（长按切到详细度量，
   * 排查用）、「回看中 ↑N 行」提示（第七轮验收过：不显示用户就不知道自己在回看态）、
   * 以及流式状态色。
   */
  @Builder
  deviceStatusLine() {
    Text(this.showMetrics && this.metrics.length > 0
      ? `${this.cols}x${this.rows} · ${this.metrics}`
      : (this.scrollBack > 0
        ? `回看中 ↑${this.scrollBack} 行 · 点屏幕回最新`
        // 终端标题（原来在顶栏的标题列里）跟着这一行保留：顶栏让位给设备选择条后它不该消失
        : `${this.titleText} · ${this.cols}x${this.rows} · ${this.statusLabel}`))
      .fontSize(FontSize.CAPTION)
      // 文案过长会折行 → 顶栏变高 → 终端区被挤下去，所以强制单行
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .padding({ left: Space.PAGE, right: Space.PAGE, bottom: Space.XS })
      .fontColor(this.scrollBack > 0
        ? $r('app.color.runtime_running')
        : (this.streaming ? $r('app.color.runtime_running') : muted()))
      .gesture(LongPressGesture().onAction(() => {
        this.showMetrics = !this.showMetrics;
      }))
  }

  /**
   * 连接 / 创建失败时把**服务端原文**摆出来。
   *
   * 上游锚文：`SessionAgentFilesScreen.kt` 的 `TerminalContent` 把
   * `statusText = terminalState.message ?: stringResource(files_terminal_error)`（517-524 行）
   * 交给**强调态**的 `AuthErrorNotice`（572-577 行）；`reconnectable` 时整块可点，
   * 点了走 `LaunchedEffect` 之外的 `onReconnect()`（525-529 / 558-561 行）。
   *
   * ⚠️ 本工程此前**只**在状态条上显示「出错」，`store.error`（服务端返回的原文）一个字都不显示 ——
   * 这正是本轮 P0 最难诊断的一点：真机上只看到「出错」，看不到服务端说了什么。
   * 现在用工程既有的 `AaErrorBanner`（其余 6 个页面同款，重试文案锚 `common_retry` = 「重试」）承载；
   * 点「重试」= 上游的 `onReconnect()`。
   */
  @Builder
  errorBanner() {
    AaErrorBanner({
      message: this.errorText,
      onRetry: () => {
        this.openSelected();
      },
      onDismiss: () => {
        this.errorText = '';
        this.store.error = '';
      }
    })
  }

  /**
   * 上游 `TerminalClearButton(enabled = terminalKey != null)`（`SessionAgentFilesScreen.kt:608-612`）：
   * 没有终端实例时按钮只是「灰着、点了没反应」，不隐藏。
   */
  private clearEnabled(): boolean {
    return this.hasTerminal;
  }

  /** 终端主体：Canvas 网格 + 承接键盘的隐藏输入框（内容与顶层化之前逐字一致）。 */
  @Builder
  terminalBody() {
    // ⚠️ `alignContent` 必须写在 Stack 上：实测（R24 模拟器）子节点上的 `.align(Alignment.TopEnd)`
    // 在本 SDK 上**不生效** —— 按钮会落进 Stack 的默认居中位（dump 实测 [567,1381][686,1500]，
    // 屏幕正中）。工程里 `.align()` 的先例全是 Scroll 的**单子节点**对齐，Stack 一律用 `alignContent`。
    Stack({ alignContent: Alignment.TopEnd }) {
      Canvas(this.context)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.draw();
        })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.canvasWidth = Number.parseFloat(`${newValue.width}`);
          this.canvasHeight = Number.parseFloat(`${newValue.height}`);
          this.recomputeGrid();
          this.draw();
        })
        // 上下拖拽 = 回看历史（对应 Android 端终端的滚动行为）。
        // 位移按行高换算成行数，并 clamp 到 `maxScrollOffset()`。
        .gesture(
          PanGesture({ direction: PanDirection.Vertical })
            .onActionStart(() => {
              this.dragStartOffset = this.scrollBack;
            })
            .onActionUpdate((event: GestureEvent) => {
              // 向下拖（offsetY > 0）= 把更早的内容拉进视野 → 回看偏移**增大**。
              // 写成减法会让回看永远被 clamp 在 0（模拟器上表现为「怎么拖都不动」）。
              const moved = Math.round(event.offsetY / LINE_HEIGHT);
              this.applyScroll(this.dragStartOffset + moved);
            })
        )
        .onClick(() => {
          // 轻点：回到最新输出 + 拉起软键盘。
          //
          // ⚠️ 必须显式 `requestFocus`：承接键盘的 TextInput 是 1x1、opacity 0、钉在 (0,0)，
          // 用户**根本点不到它** —— 不请求焦点就没有任何途径唤起输入法，
          // 「软键盘流式输入」等于不可用（模拟器实测：点画面后键盘不出现）。
          if (this.scrollBack > 0) {
            this.applyScroll(0);
          }
          focusControl.requestFocus(TERMINAL_INPUT_ID);
        })
      // 透明输入层：承接软键盘（靠上面的 onClick 显式请求焦点）
      TextInput({ text: this.mirror })
        .id(TERMINAL_INPUT_ID)
        .width(1)
        .height(1)
        .opacity(0)
        .position({ x: 0, y: 0 })
        // 预上屏（拼音/日文候选串）默认就是开的，这里显式写出来：
        // 候选阶段的内容**不会**触发 onWillInsert/onDidInsert —— 这是组合态守卫成立的前提。
        .enablePreviewText(true)
        // 回车键当「动作键」用：IME 不插入换行，而是回 onSubmit。
        // 这样「回车」只有一个来源，不会既插入换行又触发 onSubmit 而发出两个回车。
        .enterKeyType(EnterKeyType.Send)
        .onWillInsert((value: InsertValue) => {
          return this.acceptSystemInsert(value);
        })
        .onWillDelete((value: DeleteValue) => {
          return this.acceptSystemDelete(value);
        })
        .onChange((value: string) => {
          this.consumeTyped(value);
        })
        .onSubmit(() => {
          this.submitFromKeyboard();
        })

      // 「清空终端」（复刻上游 `TerminalClearButton`，锚文 `SessionAgentFilesScreen.kt:608-618`
      // 调用点 + 713-745 实现）：终端区**右上角**悬浮（top 10dp / end 18dp / zIndex 1）、
      // 34dp 圆形、1dp 描边、17dp Trash2；底 #EEFFFFFF / #DD18181B，描边 #E7E5E0 / #3F3F46，
      // 图标启用 #B42318 / #FCA5A5、禁用 #A7A5A0 / #71717A —— 四个值都落进颜色资源，
      // 深浅色由资源限定符自动切换（不再需要页面自己判主题）。
      //
      // ⚠️ 语义按上游是 `restart()` = **关闭并重建终端**，不是只清本地缓冲。
      Column() {
        AaIcon({
          d: ICONS['trash-2'],
          iconSize: 17,
          color: this.clearEnabled()
            ? $r('app.color.terminal_clear_icon')
            : $r('app.color.terminal_clear_icon_off')
        })
      }
      .width(CLEAR_BUTTON_SIZE)
      .height(CLEAR_BUTTON_SIZE)
      .borderRadius(Radius.PILL)
      .backgroundColor($r('app.color.terminal_clear_surface'))
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor($r('app.color.terminal_clear_border'))
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin({ top: CLEAR_BUTTON_TOP, right: CLEAR_BUTTON_END })
      .accessibilityText('清空终端')
      .onClick(() => {
        if (!this.clearEnabled()) {
          return;
        }
        this.store.restart();
      })
    }
    .layoutWeight(1)
    .width('100%')
    .backgroundColor($r('app.color.terminal_background'))
  }

  /**
   * 无设备空态（复刻上游 `AppEmptyState`：插图 + 16sp 文案 + 44dp 主按钮）。
   *
   * 已知差异：本工程没有 `ic_sessions_empty` 那类空态插图位图，用字符近似；
   * 按钮是自绘的 44dp 胶囊（工程既有 `AaPrimaryButton` 是 46dp，与上游不一致）。
   */
  @Builder
  emptyState(message: string, buttonLabel: string) {
    Column({ space: Space.L }) {
      AaIcon({ d: ICONS['monitor'], iconSize: EMPTY_ILLUSTRATION_SIZE, color: ink() })
      Text(message)
        .fontSize(FontSize.ROW_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: 294 })
        .padding({ left: Space.EMPTY_TEXT, right: Space.EMPTY_TEXT })
      Row({ space: Space.S }) {
        AaIcon({ d: ICONS['monitor'], iconSize: FontSize.BUTTON_ICON, color: onPrimaryAction() })
        Text(buttonLabel)
          .fontSize(FontSize.BODY_SMALL)
          .fontWeight(FontWeight.Bold)
          .fontColor(onPrimaryAction())
      }
      .height(Control.FIELD)
      .padding({ left: Space.PAGE, right: Space.PAGE })
      .borderRadius(Radius.PILL)
      .backgroundColor(primaryAction())
      .onClick(() => {
        // 上游 `onPairDevice` → DeviceSetup（配对页）
        Router.push(Route.ADD_DEVICE);
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 有设备但一台都不在线（复刻上游 `EmptyTerminalMessage`：14sp、居中、水平 34dp 内边距）。 */
  @Builder
  emptyMessage(text: string) {
    Column() {
      Text(text)
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .textAlign(TextAlign.Center)
        .padding({ left: Space.EMPTY_TEXT, right: Space.EMPTY_TEXT })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 设备下拉浮层：全屏透明遮罩（点它关闭）+ 菜单卡片。
   *
   * 为什么自绘而不 `bindMenu`：① 上游菜单的几何是明确的（286dp 宽 / 最大高 328dp / 圆角 18dp /
   * 行高 48dp / 选中打勾），系统菜单容器改不了这几项；② 自绘节点必然出现在 `dumpLayout` 里，
   * 设备侧验收可判定（第八轮「弹层不呈现」的教训）；③ 与根节点已有的 `bindSheet` 互不干扰
   * （EXPERIENCE §34：同一节点不要挂多个弹层）。
   */
  @Builder
  deviceMenuLayer() {
    Column()
      .width('100%')
      .height('100%')
      // 透明遮罩只为一件事：吃掉点击（对应上游 DropdownMenu「点外部关闭」）
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.deviceMenuOpen = false;
      })
    this.deviceMenuCard()
  }

  /** 下拉卡片（对应上游 `AADropdownMenu` + `DevicePickerMenu`：只列在线设备、选中项打勾）。 */
  @Builder
  deviceMenuCard() {
    Scroll() {
      Column() {
        ForEach(onlineDevices(this.devices), (device: AgentDevice) => {
          Row({ space: Space.M }) {
            Text(device.name)
              .fontSize(FontSize.BODY_SMALL)
              .fontWeight(FontWeight.Medium)
              .fontColor(ink())
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (device.id === this.selectedDeviceIdOrEmpty()) {
              AaIcon({ d: ICONS['check'], iconSize: FontSize.ICON, color: ink() })
            } else {
              // 未选中行留等宽占位，让「打勾列」对齐（上游 `Spacer(Modifier.size(18.dp))`）
              Text('')
                .fontSize(FontSize.ICON)
                .width(FontSize.ICON)
            }
          }
          .width('100%')
          .height(Control.MENU_ITEM_MIN)
          .padding({ left: Space.L, right: Space.L })
          .onClick(() => {
            this.selectedDeviceId = device.id;
            this.deviceMenuOpen = false;
            this.openSelected();
          })
        }, (device: AgentDevice) => device.id)
      }
      .width('100%')
    }
    .width(Control.MENU_WIDTH)
    .constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })
    .scrollBar(BarState.Auto)
    .align(Alignment.Top)
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .position({ x: MENU_LEFT, y: MENU_TOP })
  }

  @Builder
  pastePanel() {
    // R38（用户需求「软件所有发送功能都用图标取代，并尽量放在对话框右下角」）：
    // 发送按钮由**全宽文字胶囊**（`AaSecondaryButton({ label: '发送到终端' })`）改为
    // **34vp 圆形图标按钮**（`ICONS['send']`），并贴到弹层右下角。
    //
    // ⚠️ 贴右下角**不用 `Blank()`**（Lead 裁决：它在 `bindSheet` 里能否撑开是不确定的，
    //  不引入可能静默失效的机制）。改为「内容块 + 按钮行」两段：外层 `SpaceBetween` 把按钮行
    //  确定地推到底，右对齐由按钮行自己的 `width('100%') + justifyContent(End)` 给。
    //  按钮行另给 `margin({ top: Space.M })` 作**最小间距兜底**：万一内容超高、`SpaceBetween`
    //  没有剩余空间可分配，两块也不会贴在一起。
    //
    // ⚠️ 高度预算（弹层高度是 `bindSheet` 的 `height: 280`，见 `build()`）——
    //  上下内边距 16×2 = 32；内容块 ≈ 标题 24 + 间距 12 + 说明两行 36 + 间距 12
    //  + TextArea 最小 80 ≈ 164；按钮行 34 ⇒ 合计 ≈ 230 < 280，**不溢出**。
    //  将来若调大字号 / 让说明换更多行，这里要重新复算，否则按钮会被弹层裁掉。
    Column() {
      Column({ space: Space.M }) {
        Text('粘贴到终端')
          .fontSize(FontSize.TITLE)
          .fontColor(ink())
          .width('100%')
        // 提示必须同步改（需求原文：「修改后也要同步修改提示」）：按钮已不是文字胶囊，
        // 再写「再点『发送到终端』」会把用户指向一个界面上不存在的控件。
        Text('在下面的输入框里长按 → 粘贴（走系统粘贴菜单，无需剪贴板权限），再点右下角的发送图标。')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
        TextArea({ text: this.pasteText, placeholder: '在此粘贴内容' })
          .fontSize(FontSize.SMALL)
          .constraintSize({ minHeight: 80, maxHeight: 120 })
          .width('100%')
          .borderRadius(Radius.M)
          .borderWidth(1)
          .borderColor(borderColor())
          .backgroundColor(raisedSurface())
          .onChange((value: string) => {
            this.pasteText = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row() {
        AaPrimaryIconButton({
          name: 'send',
          // R42-F2（本轮修）：空输入时进**禁用态**（subtle 底 + muted 图标，见 AaPrimaryIconButton
          // 的 surfaceColor/iconColor）—— 改前是「看着能点、点了什么也不发生」：
          // `sendPastedText()` 首行遇到空串直接 return，按钮本身却一直是主色底。
          interactive: this.pasteText.length > 0,
          // 图标取代文字后，无障碍文本是 dumpLayout / 读屏唯一的语义载体
          accessibilityLabel: '发送到终端',
          onTap: () => {
            this.sendPastedText();
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: Space.M })
    }
    .width('100%')
    .height('100%')
    .padding(Space.L)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  /**
   * 顶栏（复刻上游 `TerminalHeader`，`TerminalScreen.kt:116-182`）：行高 64dp、水平内边距 18dp；
   * 左侧 40dp 圆形返回钮（`raisedSurface` 底 + 1dp 描边 + 22dp ChevronLeft）；
   * 中间是 44dp 圆角条（圆角 14dp、设备名 16sp SemiBold、右侧 19dp ChevronDown），
   * 点开只列**在线设备**的下拉。
   *
   * 与上游的**已知差异**（简报里也列了）：
   *  ① 本工程在选择条右侧多一个「粘贴」按钮 —— 上游顶栏没有它。这是**必要的补偿**：
   *  上游终端是 Termux 视图，长按画面走系统选择/粘贴菜单；本工程是自研 Canvas 网格，
   *  没有长按选区能力，而程序化读剪贴板要 `ohos.permission.READ_PASTEBOARD`（ACL 级），
   *  所以改成「零权限的粘贴弹层」（见 `pastePanel()`），入口必须留在页面上。
   *  ⚠️ 原先这里还有一个「清屏」文字胶囊，已按上游搬到**终端区右上角**、改成
   *  `TerminalClearButton` 的圆形图标形态（锚文 `SessionAgentFilesScreen.kt:608-618`）。
   * 返回钮一律 `Router.back()`：上游 `TerminalScreen.kt:69/87` 的返回目标是硬编码的 Sessions（首页），
   * 不是「回上一页」。
   *
   * ⚠️ **R65-B 删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）。
   *
   * R37 五改的本意是「顶栏背景铺到屏幕顶、状态栏那一条也一起糊」。但顶栏一旦进入 `Navigation`
   * 标题栏，**高度与位置由框架接管**：真机 `dumpLayout` 实测标题栏落在 `[0,137][1316,332]`
   * （`HomeScreen` R62 的实测记录）—— 页面根节点**已经在状态栏之下**，顶栏再避让一次就是
   * **重复避让 137px**。而且原来读的是 `AppStorage.get(SAFE_AREA_TOP_PX)` 这个**非响应**读取，
   * 值随冷启动时序在 `0 / 46vp` 之间跳（R61 实测：同一份包两次冷启动顶栏行高 136px / 274px）。
   * ⇒ 本页按 R65-B 固定**不避让**，与 `HomeScreen`（R62）同一口径。
   *
   * **R65-B：本页标题栏** —— `Navigation.title(...)` 的自定义构造器（原 `header()`）。
   * 除返回钮改成共用玻璃钮（见下）外，其余元素逐字未动。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感自 HarmonyOS 7 起有**生效范围约束**：其他
   * 组件只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 的底部 TabBar（`barPosition =
   * BarPosition.End`）中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1）。
   */
  @Builder
  navTitleBar() {
    Row({ space: Space.M }) {
      // R65-B：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内
      //（`坑 245`）。返回钮由「自绘 Column + `raisedSurface` 圆盘」改成**共用的
      // 玻璃钮**（`AaCircleIconButton` 的玻璃档统一委托 `ui/GlassIcon.ets`，与首页/设备页/设置页同源），
      // 并开官方材质（官方分支零自绘层：无 backgroundEffect / 渐变 / 描边）；几何按原值 40vp / 22vp 不变。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        tint: ink(),
        surface: raisedSurface(),
        ringColor: borderColor(),
        glass: true,
        officialMaterial: true,
        accessibilityLabel: '返回',
        onTap: () => {
          Router.back();
        }
      })

      // 44dp 设备选择条：上游 `clickable(enabled = hasOnlineDevice)` —— 没有在线设备时点了没反应
      Row({ space: Space.S }) {
        Text(this.selectedDeviceLabel())
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.CHEVRON, color: faint() })
      }
      .layoutWeight(1)
      .height(Control.FIELD)
      .padding({ left: Radius.M_PLUS, right: Radius.M_PLUS })
      .borderRadius(Radius.M_PLUS)
      // ## R66（SPEC §2，真机缺陷 ②）：设备选择条原来是**自绘底 + 1vp 描边**
      //  （`backgroundColor(raisedSurface())` + `borderWidth`/`borderColor`），现整段删除，改由官方
      //  `ImmersiveMaterial` 接管（口径 = **零自绘层**，同 `GlassIcon.ets#officialGlass()`）。
      // ⚠️ 几何逐字不变：`layoutWeight(1)` / `height(Control.FIELD)` / `padding` / `borderRadius(Radius.M_PLUS)`
      //  与内部 `Text`(16sp Medium) / `AaIcon`(chevron-down) 全是原值 —— 只换「谁在画底与边」。
      // ⚠️ `materialColor` 取**既有的半透明令牌** `glassCardSurface()`（base `#B3FDFCFB` / dark `#B31C1C20`，
      //  alpha ≈ 70%，与原来那层实底 `raisedSurface()` 观感同档；官方要求完全 opaque 会挡死滤镜）。
      //  不新造资源键。原实底是不透明的（base #FFFFFF / dark #1F1F1F）⇒ 这一档是它在玻璃族里最近的一档。
      // ⚠️ 生效范围：本胶囊在 `Navigation.title(...)` 的构造器里 ⇒ 命中官方允许的位置
      // （`坑 245`、SPEC §2）；正文里的胶囊**不许**照抄这一段。
      .systemMaterial(officialBarMaterial(glassCardSurface()))
      .onClick(() => {
        if (!this.hasOnlineDevice()) {
          return;
        }
        this.deviceMenuOpen = !this.deviceMenuOpen;
      })

      // ## R66（SPEC §2，真机缺陷 ②）：本「粘贴」是**标题栏内的胶囊**（自绘 borderWidth/borderColor/
      //  backgroundColor + 按压底），现整组换成**官方沉浸光感** `systemMaterial(ImmersiveMaterial)`
      //  —— 组件内的官方分支是 R66 由 task-18 落在 `ui/Components.ets#AaSecondaryButton.officialBody()`
      //  里的（零自绘层，`materialColor: glassCardSurface()`；缺省 false ⇒ 其余调用点逐像素不变）。
      // ⚠️ 几何逐字不变：`compact: true` ⇒ 与原自绘分支同一组 `padding`(左右 `Space.M` / 上下 6) /
      //  `borderRadius(Radius.M)` / `FontSize.SMALL` —— 只换「谁在画底」。
      // ⚠️ 官方分支**整个**受编译期常量 `TOPBAR_OFFICIAL_MATERIAL`（`GlassIcon.ets`）× 本处 opt-in 控制
      //  （SPEC「硬约束」：跟随既有开关，不新造开关）。
      // ⚠️ 生效范围：本钮在 `Navigation.title(...)` 的构造器里 ⇒ 命中官方允许的位置
      // （`坑 245`、SPEC §2）；正文里的调用点**必须**保持 false。
      AaSecondaryButton({
        label: '粘贴',
        compact: true,
        officialMaterial: true,
        onTap: () => {
          this.pasteSheet = true;
        }
      })
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），64vp → 262px（低 27px）。
    // ⚠️ 同时保留 R65 的口径：栏高**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .alignItems(VerticalAlign.Center)
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：栏底色 28.8 vs 正文 9.67
    //  ⇒ 一条比正文亮 +19.1 的带；首页同口径 +0.00）。**光效只留在栏内控件（返回钮、设备条、「粘贴」）上。**
    //  ⚠️ 历史：R66 曾把整条栏改官方材质（本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），
    //  R87 因「有明显分界」撤回；同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  private connectionLabel(): string {
    switch (this.store.state) {
      case TerminalConnectionState.CREATING: return '创建中';
      case TerminalConnectionState.CONNECTING: return '连接中';
      case TerminalConnectionState.STREAMING: return this.store.statusText;
      case TerminalConnectionState.EXITED: return this.store.statusText;
      case TerminalConnectionState.ERROR: return '出错';
      default: return '空闲';
    }
  }

  // -------------------------------------------------------------------------
  // 按键行
  // -------------------------------------------------------------------------

  // 上游 `TerminalShortcutDeck`（SessionAgentFilesScreen.kt:785）为**两行 × 7 键**：
  // 第 1 行 Esc / - Home ↑ End PGUP，第 2 行 Tab Ctrl Alt ← ↓ → PGDN；
  // 容器 height(88.dp) + padding(h14,v6) + spacedBy(3.dp)，键 height(34.dp) + weight(1f)，
  // 键底**透明**、仅 Ctrl/Alt 武装时上色（#1A67E8F9 / #1A0891B2），文字 14.sp。
  @Builder
  extraKeys() {
    Column({ space: 3 }) {
      Row() {
        ForEach(TERMINAL_KEY_ROWS[0], (key: ExtraKey) => {
          Text(key.label)
            .fontSize(14)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .borderRadius(8)
            .fontColor(((key.action === 'ctrl' && this.ctrlArmed) || (key.action === 'alt' && this.altArmed))
              ? $r('app.color.terminal_key_active') : ink())
            .backgroundColor(((key.action === 'ctrl' && this.ctrlArmed) || (key.action === 'alt' && this.altArmed))
              ? $r('app.color.terminal_key_active_surface') : Color.Transparent)
            .onClick(() => {
              this.handleExtraKey(key);
            })
        }, (key: ExtraKey) => key.label)
      }
      .width('100%')
      .layoutWeight(1)

      Row() {
        ForEach(TERMINAL_KEY_ROWS[1], (key: ExtraKey) => {
          Text(key.label)
            .fontSize(14)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .borderRadius(8)
            .fontColor(((key.action === 'ctrl' && this.ctrlArmed) || (key.action === 'alt' && this.altArmed))
              ? $r('app.color.terminal_key_active') : ink())
            .backgroundColor(((key.action === 'ctrl' && this.ctrlArmed) || (key.action === 'alt' && this.altArmed))
              ? $r('app.color.terminal_key_active_surface') : Color.Transparent)
            .onClick(() => {
              this.handleExtraKey(key);
            })
        }, (key: ExtraKey) => key.label)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height(88)
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
    .borderWidth({ top: 1 })
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
    // ⚠️ R13-15：功能键行是终端页的底部固定元素，**手势条避让由它自己承担**（真机 + 模拟器都验过）。
    // ⚠️ R66-3：`Index` 的**浮层底栏**那一条**不在这里** —— 由本页外层 Column 的
    //  `.padding({ bottom: BOTTOM_BAR_RESERVED_VP })` 承担。分成两处是有意的：
    //  ① 它让「手势条避让」这条既有语义与既有护栏（suite-settings 的那条断言）保持原样；
    //  ② 坑 180 明确警告过不要写 `max(安全区, 目标)` 这类合成值，两处相加语义更清楚。
    .margin({ bottom: this.getUIContext().px2vp(this.safeAreaBottomPx) })
  }

  private handleExtraKey(key: ExtraKey): void {
    if (key.action === 'ctrl') {
      this.ctrlArmed = !this.ctrlArmed;
      return;
    }
    if (key.action === 'alt') {
      this.altArmed = !this.altArmed;
      return;
    }
    const sequence = resolveExtraKey(key, this.store.emulator, this.ctrlArmed, this.altArmed);
    this.ctrlArmed = false;
    this.altArmed = false;
    if (sequence.length > 0) {
      this.store.sendSequence(sequence);
    }
  }

  /**
   * 粘贴：不直接读剪贴板（READ_PASTEBOARD 是 system_basic 级权限，三方应用需 ACL）。
   * 改为弹一个输入框，用户在系统粘贴菜单里贴入后点**右下角的发送图标**（ICONS['send']）——零权限且行为可预期。
 * R38：按钮形态由文字胶囊改为图标，本注释与面板内的提示句同步改（需求：「修改后也要同步修改提示」）。
   */
  private sendPastedText(): void {
    if (this.pasteText.length === 0) {
      return;
    }
    this.store.sendSequence(this.pasteText);
    this.pasteText = '';
    this.pasteSheet = false;
  }

  /**
   * 输入通道 A（兜底）：镜像输入框的内容变化。
   *
   * ⚠️ `onChange` **不是**可信的「已上屏」信号：拼音/日文输入法在**候选阶段**（预上屏）
   * 也会触发它。老实现每次 onChange 都复位输入框并逐字符写 PTY，于是候选串被逐个字母
   * 写进 PTY（真机现象，第七轮审计发现）。现在的规矩：
   *  - 系统输入法的插入回调（`onWillInsert`）出现过 → 这条通道只做丢弃，一个字都不发；
   *  - 完全没见过那个回调（例如硬件键盘）→ 只把内容记进 `mirrorText`，
   *  等回车时整段送入（见 `submitFromKeyboard`），**不逐字符即时发送**。
   */
  private consumeTyped(value: string): void {
    if (!shouldTrustChangeEvent(this.systemInsertAlive)) {
      return;
    }
    this.mirrorText = value;
    // 与输入框保持一致，回车清空时才真的能把它清掉（mirror 值没变过的话赋值不触发更新）
    this.mirror = value;
  }

  /**
   * 输入通道 B（主）：系统输入法**真正上屏**的内容。
   *
   * 返回 `false` 拒绝把文本插进这个隐藏输入框 —— 它只是个「收字器」，内容一律直接进 PTY。
   * 这还顺带消掉一个隐患：老实现每收一个字就把输入框复位，等于把 IME 的预上屏强行提交
   * （候选串因此变成「真文本」）。现在输入框始终为空，IME 的组合态不受干扰。
   */
  private acceptSystemInsert(value: InsertValue): boolean {
    this.systemInsertAlive = true;
    this.commitText(value.insertValue);
    return false;
  }

  /** 系统输入法的删除（退格）：输入框是空的，所以只把退格转给 PTY（键行里没有退格键）。 */
  private acceptSystemDelete(_value: DeleteValue): boolean {
    this.store.sendSequence(backspaceKey());
    return false;
  }

  /**
   * 键盘上的回车（`enterKeyType(EnterKeyType.Send)` → `onSubmit`）。
   * 系统插入通道可用时输入框为空，补一个回车即可；兜底通道下先把 `mirrorText` 整段送出去。
   */
  private submitFromKeyboard(): void {
    if (!this.systemInsertAlive && this.mirrorText.length > 0) {
      const pending = this.mirrorText;
      this.mirrorText = '';
      this.mirror = '';
      this.commitText(pending);
    }
    this.store.sendSequence(enterKey());
  }

  /** 把一段**已确认上屏**的文本按 CTRL/ALT 武装状态转成序列写回 PTY。 */
  private commitText(text: string): void {
    if (text.length === 0) {
      return;
    }
    const state: ModifierState = { ctrl: this.ctrlArmed, alt: this.altArmed };
    const sequences = composeKeySequence(
      text, state,
      (): string => enterKey(),
      (key: string): string => ctrlSequence(key));
    for (let i = 0; i < sequences.length; i++) {
      this.store.sendSequence(sequences[i]);
    }
    // 武装被本次输入消费掉（与键行里 CTRL/ALT 的语义一致：一次输入即复位）
    this.ctrlArmed = state.ctrl;
    this.altArmed = state.alt;
  }

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  /** 设置回看偏移：clamp 到 [0, maxScrollOffset]，并只在真的变化时重绘。 */
  private applyScroll(offset: number): void {
    const max = this.store.emulator.maxScrollOffset();
    let next = offset;
    if (next < 0) {
      next = 0;
    }
    if (next > max) {
      next = max;
    }
    if (next === this.scrollBack) {
      return;
    }
    this.scrollBack = next;
    this.draw();
  }

  /**
   * R57（B1）：fontPx 变化才重设字体并重测步进样本；其余帧直接复用 `measuredSample`。
   * fontPx = FONT_SIZE * density：字号常量、密度只在屏幕变化时变 —— 运行时基本只算一次。
   */
  private applyFontIfNeeded(fontPx: number): void {
    if (fontPx === this.lastFontPx && this.measuredSample > 0) {
      return;
    }
    // 字体族要带引号并给回退链：不带引号时 Canvas 会忽略族名直接用默认比例字体，
    // 等宽字形的步进就会偏大（真机实测 cell 恒为 11.35vp，与字号无关）。
    this.context.font = `${fontPx}px "Noto Sans Mono", "NotoSansMono", monospace`;
    // 用一段「宽字符 + ASCII 混合」的样本来量步进，比只量 'M' 更能反映真实排版；
    // 再按目标列数反推单元格宽度，保证手机上列数稳定在可用区间（不随字体回退而漂）。
    this.measuredSample = this.context.measureText('MMMMMMMMMM').width / 10;
    this.lastFontPx = fontPx;
  }

  private recomputeGrid(): void {
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    const cols = Math.max(20, Math.floor(this.canvasWidth / this.cellWidth));
    const rows = Math.max(4, Math.floor(this.canvasHeight / LINE_HEIGHT));
    if (cols !== this.cols || rows !== this.rows) {
      this.cols = cols;
      this.rows = rows;
      this.store.resize(cols, rows);
    }
  }

  private draw(): void {    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    const emulator = this.store.emulator;
    const scheme = emulator.colorScheme;
    const pool: TerminalStylePool = emulator.stylePool();

    // 网格度量：先按屏幕密度把字号换算成物理像素，再量等宽字体的实际步进。
    // 直接用 `13px` 会在高密度屏上得到过小的字形（真机 1316px 宽会挤进 115 列，
    // 肉眼几乎看不清），所以字号必须乘密度。
    if (this.density <= 0) {
      try {
        this.density = display.getDefaultDisplaySync().densityPixels;
      } catch (error) {
        this.density = 1;
      }
      if (this.density <= 0) {
        this.density = 1;
      }
    }
    const fontPx = FONT_SIZE * this.density;
    this.applyFontIfNeeded(fontPx);
    const sample = this.measuredSample;
    const byArea = this.canvasWidth > 0 ? this.canvasWidth / TARGET_COLUMNS : sample;
    const measured = sample > 0 ? sample : byArea;
    const targetCell = byArea > 0 && measured > 0 ? Math.min(measured, byArea) : measured;
    if (targetCell > 0 && Math.abs(targetCell - this.cellWidth) > 0.01) {
      this.cellWidth = targetCell;
      this.recomputeGrid();
    }
    // 度量信息放在测量/更新**之后**，否则显示的是上一帧的值（真机上被这一点坑过一次）
    this.metrics = `cell=${this.cellWidth.toFixed(2)} font=${fontPx.toFixed(1)} d=${this.density.toFixed(2)} area=${Math.round(this.canvasWidth)}x${Math.round(this.canvasHeight)}`;

    this.context.fillStyle = colorToHex(scheme.background);
    this.context.fillRect(0, 0, this.canvasWidth, this.canvasHeight);
    this.context.textBaseline = 'middle';

    const rows = emulator.rows;
    const cols = emulator.columns;
    // 回看偏移可能因为回看区被裁掉而超界（长输出会 trim 掉最旧的行），先收敛一次。
    if (this.scrollBack > emulator.maxScrollOffset()) {
      this.scrollBack = emulator.maxScrollOffset();
    }
    const offset = this.scrollBack;
    for (let rowIndex = 0; rowIndex < rows; rowIndex++) {
      const row: TerminalRow = emulator.rowWithOffset(rowIndex, offset);
      const y = rowIndex * LINE_HEIGHT + LINE_HEIGHT / 2;
      // 先铺背景色块
      let column = 0;
      while (column < cols) {
        const style = pool.get(row.getStyle(column));
        if (style.background >= 0 || (style.flags & TextStyleFlags.INVERSE) !== 0) {
          let runEnd = column;
          while (runEnd < cols && sameBackground(pool, row, runEnd, style)) {
            runEnd += 1;
          }
          this.context.fillStyle = colorToHex(resolveColor(style.background, scheme, false));
          this.context.fillRect(column * this.cellWidth, rowIndex * LINE_HEIGHT,
            (runEnd - column) * this.cellWidth, LINE_HEIGHT);
          column = runEnd;
        } else {
          column += 1;
        }
      }
      // 再画文字
      for (let col = 0; col < cols; col++) {
        const codePoint = row.getChar(col);
        if (codePoint === 0) {
          continue;
        }
        const style = pool.get(row.getStyle(col));
        const inverse = (style.flags & TextStyleFlags.INVERSE) !== 0;
        let foreground = resolveColor(style.foreground, scheme, true);
        let background = resolveColor(style.background, scheme, false);
        if (inverse) {
          const swapped = foreground;
          foreground = background;
          background = swapped;
        }
        if ((style.flags & TextStyleFlags.INVISIBLE) !== 0) {
          continue;
        }
        this.context.fillStyle = colorToHex(foreground);
        this.context.fillText(String.fromCodePoint(codePoint), col * this.cellWidth, y);
        if ((style.flags & TextStyleFlags.BOLD) !== 0) {
          this.context.fillText(String.fromCodePoint(codePoint), col * this.cellWidth + 0.6, y);
        }
        const textWidth = row.isWideContinuation(col + 1) ? this.cellWidth * 2 : this.cellWidth;
        if (hasUnderline(style.flags)) {
          this.context.fillRect(col * this.cellWidth, rowIndex * LINE_HEIGHT + LINE_HEIGHT - 3,
            textWidth, 1);
        }
        if ((style.flags & TextStyleFlags.STRIKETHROUGH) !== 0) {
          this.context.fillRect(col * this.cellWidth, rowIndex * LINE_HEIGHT + LINE_HEIGHT / 2,
            textWidth, 1);
        }
      }
    }

    // 光标：只在实际跟随最新输出时画（回看态画光标会指错位置）
    if (offset === 0 && emulator.cursorVisible() && this.store.state !== TerminalConnectionState.EXITED) {
      const cursorRow = emulator.cursorRow();
      const cursorCol = emulator.cursorCol();
      this.context.fillStyle = colorToHex(scheme.cursor);
      this.context.fillRect(cursorCol * this.cellWidth, cursorRow * LINE_HEIGHT,
        this.cellWidth, LINE_HEIGHT);
      const codePoint = emulator.row(cursorRow).getChar(cursorCol);
      if (codePoint !== 0) {
        const style = pool.get(emulator.row(cursorRow).getStyle(cursorCol));
        this.context.fillStyle = colorToHex(resolveColor(style.background, scheme, false));
        this.context.fillText(String.fromCodePoint(codePoint), cursorCol * this.cellWidth,
          cursorRow * LINE_HEIGHT + LINE_HEIGHT / 2);
      }
    }
  }
}

function sameBackground(pool: TerminalStylePool, row: TerminalRow, column: number, style: TerminalStyle): boolean {
  const candidate = pool.get(row.getStyle(column));
  return candidate.background === style.background && candidate.flags === style.flags;
}

export { MODIFIER_ALT, MODIFIER_CTRL, MODIFIER_SHIFT };

// =============================================================================
// 设备选择（纯逻辑）
//
// ⚠️ 本区代码不得引用 ArkUI / @kit 符号，也不得引用本文件其它成员 ——
// `tools/logic-test/run-tests.mjs` 会按下面两行标记把本区源码**原样切出来**转译到 Node 断言。
// 终端页与文件页**共用**这几个函数（`FilesScreen.ets` 直接 import 本模块），
// 于是「两页逐字同构」不只是口号，而是同一份实现。
// >>> AA-DEVICE-PURE-BEGIN
// =============================================================================

/** 设备排序（对齐上游 `sortedForDevicesPage()`：在线优先 → createdAt → name 小写）。 */
export function sortDevicesForPage(devices: AgentDevice[]): AgentDevice[] {
  const copy = devices.slice();
  copy.sort((left: AgentDevice, right: AgentDevice): number => {
    if (left.online !== right.online) {
      return left.online ? -1 : 1;
    }
    const leftCreated = left.createdAt !== undefined ? left.createdAt : '';
    const rightCreated = right.createdAt !== undefined ? right.createdAt : '';
    if (leftCreated !== rightCreated) {
      return leftCreated < rightCreated ? -1 : 1;
    }
    const leftName = left.name.toLowerCase();
    const rightName = right.name.toLowerCase();
    if (leftName === rightName) {
      return 0;
    }
    return leftName < rightName ? -1 : 1;
  });
  return copy;
}

/** 下拉里只列在线设备（上游 `DevicePickerMenu` 的 `devices.filter { it.online }`）。 */
export function onlineDevices(devices: AgentDevice[]): AgentDevice[] {
  const out: AgentDevice[] = [];
  for (let i = 0; i < devices.length; i++) {
    if (devices[i].online) {
      out.push(devices[i]);
    }
  }
  return out;
}

/**
 * 默认选中的设备 id（上游两段逻辑合并）：
 * 路由带来的 `preferredId` 在线就用它，否则取第一个在线设备；一台在线的都没有则返回空串。
 */
export function pickDefaultDeviceId(devices: AgentDevice[], preferredId: string): string {
  if (preferredId.length > 0) {
    for (let i = 0; i < devices.length; i++) {
      const device = devices[i];
      if (device.id === preferredId && device.online) {
        return device.id;
      }
    }
  }
  for (let i = 0; i < devices.length; i++) {
    if (devices[i].online) {
      return devices[i].id;
    }
  }
  return '';
}

/**
 * 设备级 / 会话级两种终端的 root 契约归一。
 *
 * 上游的 root 只有两个来源（`feature/terminal/TerminalController.kt`）：
 *  - **设备级**（顶层「终端」页，`TerminalScreen.kt:67` → `terminalPool.forDevice(...)`）
 *  → 硬编码 `root = "~"`（`TerminalController.kt:72`）；
 *  - **会话级**（`forSession` → `ensureStarted(session)`）→ `session.cwd?.takeIf { it.isNotBlank() }`
 *  （同文件第 23 行）。
 *
 * 本工程从首页快捷卡片进终端页时路由**不带参数**（`HomeScreen.quickEntryCard` 只
 * `Router.push(target)`），`Index.ets` 的 `paramAt(1)` 于是返回空串；而 `@Prop` 一旦被传参就
 * **不再启用默认值**，空串被 `TerminalApi` 拼成 `?root=` —— 服务端
 * `root: str = Query(..., min_length=1)` 直接 422（真机复现原文见本轮简报）。
 * 设备详情取不到项目时传的 `'.'` 也不是合法工作区根（服务端会解析成连接器进程自己的 cwd）。
 *
 * 所以：空串 / 纯空白 / `'.'` 一律落到 `homeRoot`，其余显式 root 去掉首尾空白后原样保留。
 * `homeRoot` 由调用方注入（页面传 `model/DirBrowse.HOME_ROOT`，即 `'~'`）——
 * 与文件页共用同一份常量，两页的 root 契约因此不会各写一个字面量而漂掉。
 */
export function effectiveTerminalRoot(root: string, homeRoot: string): string {
  const trimmed = root.trim();
  if (trimmed.length === 0 || trimmed === '.') {
    return homeRoot;
  }
  return trimmed;
}

// <<< AA-DEVICE-PURE-END
// =============================================================================

// =============================================================================
// 输入策略（纯逻辑）
//
// ⚠️ 本区内的代码**不得**引用 ArkUI / @kit 符号，也不得引用本文件其它成员 ——
// `tools/logic-test/suite-input.mjs` 会按下面两行标记把本区源码**原样切出来**，
// 用 DevEco 自带的 TypeScript 转译到 Node 里跑断言：「输入法把什么当成上屏」只能在
// 设备上复现，但「什么该发、什么不该发」必须由纯逻辑守住。
// 改完本区请跑一次：node tools/logic-test/suite-input.mjs
// >>> AA-PURE-LOGIC-BEGIN
// =============================================================================

/** CTRL/ALT 武装状态（可变：`composeKeySequence` 会消费其中的一次）。 */
export interface ModifierState {
  ctrl: boolean;
  alt: boolean;
}

/**
 * 组合态守卫：`onChange` 的值能不能当作「可信的上屏文本」。
 *
 * 系统输入法（会走 `onWillInsert`）下答案永远是 false —— 候选阶段（预上屏）也会触发
 * onChange，只有 `onWillInsert` 才代表真正上屏；完全没见过那个回调时（硬件键盘、
 * 不提供插入回调的输入法）才放行，此时页面退化为「输入框累积 + 回车整段送入」。
 */
export function shouldTrustChangeEvent(systemInsertAlive: boolean): boolean {
  return !systemInsertAlive;
}

/**
 * 一段已上屏的文本 → 要写回 PTY 的序列列表。
 *
 * - 换行走 `mapEnter()`（终端的回车是 `\r`，不是 `\n`）；
 * - CTRL/ALT 武装只作用于**紧跟着的那一个字符**，用完即复位（与键行语义一致）；
 * - CTRL 映射不出控制字符时得到空串，由调用方跳过（`sendSequence` 本身也会忽略空串）。
 *
 * 映射函数由调用方注入（页面传 `vt/KeyHandler` 的实现，测试传同一份实现），
 * 这样本区保持零依赖、可被 Node 直接加载断言。
 */
export function composeKeySequence(
  text: string,
  state: ModifierState,
  mapEnter: () => string,
  mapCtrl: (key: string) => string
): string[] {
  const out: string[] = [];
  for (let i = 0; i < text.length; i++) {
    const char = text.charAt(i);
    if (char === '\n' || char === '\r') {
      out.push(mapEnter());
      continue;
    }
    if (state.ctrl) {
      out.push(mapCtrl(char));
      state.ctrl = false;
      continue;
    }
    if (state.alt) {
      out.push('\u001b' + char);
      state.alt = false;
      continue;
    }
    out.push(char);
  }
  return out;
}

// <<< AA-PURE-LOGIC-END
// =============================================================================

