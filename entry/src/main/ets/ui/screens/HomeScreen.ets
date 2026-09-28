/**
 * 首页 / Sessions（对应 Android `ui/screens/home/HomeScreen.kt` 的 `HomeContent` + `HomeHeader` +
 * `QuickEntries` + `FloatingHomeButton`；列表部分对应 `HomeProjectComponents.kt` / `HomeLists.kt`）。
 *
 * 结构（一比一复刻，锚文见 开发期验证记录 §C，数值照抄 dp/sp）：
 * ```
 * Box(BottomEnd)
 * ├─ Column(padding 18/6/18, spacedBy 15) `HomeScreen.kt:481-487`
 * │ ├─ HomeHeader Row(46, spacedBy 12) `:626-665`
 * │ │ ├─ 头像圆钮(40, raisedSurface + 1dp 边框) → 打开设置抽屉
 * │ │ ├─ Box(weight 1, h40) { 字标 31sp 居中 }
 * │ │ └─ 搜索圆钮(40, 透明底无边框) → 提示「搜索功能即将推出。」
 * │ ├─ QuickEntries Row(76, spacedBy 10) `:667-752`
 * │ │ └─ 三张等宽卡片：设备 / 终端 / 文件（圆角 18、padding h12/v13、图标 22、文案 14sp Bold）
 * │ └─ Refresh { 列表 }（官方 `Refresh` 替代 Material3 PullToRefreshBox）
 * └─ FloatingHomeButton 54 圆形，end 18 / bottom 32 `:853-882`
 * ```
 *
 * ⚠️ **没有底部 tab**：上游确认无底部导航（上游实现 ① —— `ScreenScaffold` 的 `bottomBar` 插槽全仓无人使用，
 *  首页内部那个 `HomeTab` 枚举是「内容区分段」且会话视图分支硬编码 `tab = Active`）。
 *  所以「设备」「我的」不再是 tab：设备是顶层目的地 `Route.DEVICES`（快捷卡片的第一个入口），
 *  设置是**首页之上的一层抽屉**（头像进入；开合状态摊平到 AppStorage 键 `aaSettingsDrawerOpen`，
 *  因为系统返回键的处理在根页面 `pages/Index.ets`）。
 * ⚠️ 状态绑定约定（本工程所有页面一致）：ArkUI 只在 build 期间**读取过**的状态变量上登记依赖，
 *  所以 store 的数据一律在监听器里拷进 `@State` 字段，build 只读这些字段。
 * ⚠️ 弹层约定：**根节点只有一个 bindSheet**（EXPERIENCE §34：同节点多个 bindSheet 是「后写覆盖先写」），
 *  会话操作 / 项目菜单 / 会话状态筛选 / 项目编辑四类面板合并进同一个 sheet，用 `sheetKind` 分发。
 */

// ⚠️ `isDarkAppearance` 只服务 `menuSurface()`（三处弹窗内容根的**材质不可用**回退支路）—— 别删。
import { authController, isDarkAppearance } from '../../feature/AppServices';
import { AppPreferences, PROJECT_COLLAPSED_KEY, SIDEBAR_VIEW_SESSION } from '../../store/AppPreferences';
import { AgentDevice, AgentSession, SessionListIndicator } from '../../model/AppModels';
import { DashboardListener, DashboardStore } from '../../feature/DashboardStore';
import {
  ProjectRow, ProjectSessionFilter, buildProjectRows, deviceListsEqual, mergeSessionsById,
  migrateCollapsedIds, normalizeProjectSessionFilter, pagingSideIsArchived, parseProjectCollapsed,
  pinnedSessionsOf, projectDeviceLabel, projectRowListsEqual, projectSessionFilterLabel,
  pruneUnknownProjectIds, recentSessionsOf, sameSessionList, serializeProjectCollapsed, stringListsEqual,
  toggleCollapsedId
} from '../../model/HomeGrouping';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, errorText, faint, ink, inkSoft, muted,
  raisedSurface, rowPressedSurface, statusColor, subtle, SAFE_AREA_TOP_PX,
  // R90-T2：恢复「原先那层模糊」所需的四个玻璃令牌（R58「内容划过」自绘 backgroundEffect 那套）。
  // 来源就是本文件 header() 末尾那段回退说明：「把 GLASS_BLUR_RADIUS / GLASS_SATURATION /
  // GLASS_BRIGHTNESS / glassSurface() 这四个引用加回来即可（import 与会话详情页同源）」。
  GLASS_BLUR_RADIUS, GLASS_SATURATION, GLASS_BRIGHTNESS, glassSurface
} from '../Design';
import {
  AaCircleIconButton, AaEmptyState, AaErrorBanner, AaMenuActionRow, AaPrimaryButton,
  AaReadOnlyField, AaSecondaryButton,
  // R86：弹层类的两个**官方沉浸光感**入口（半模态取 `panelMaterial()`=THIN、弹窗取 `dialogMaterial()`=REGULAR），
  // 外加**可用性探针** `immersiveMaterialEnabled()` —— 三处弹窗内容根的「材质 / 自绘玻璃」二选一都用它门控
  // （同一个探针 ⇒ 两条支路互斥，绝不同时存在）。
  // ⚠️ 页面**不得**自己 `import { uiMaterial }`：Kit 依赖收口在 `ui/Components.ets`（契约 §1.6）。
  dialogMaterial, immersiveMaterialEnabled, panelMaterial
} from '../Components';
import { AaIcon, ICONS } from '../Icon';
// ⚠️ 只引一个**编译期常量**做探针开关（R71）；首页写 `aaBottomBarHidden` 仍用字面量键（本文件既有约定）。
import { BOTTOM_BAR_PROBE } from '../BottomNav';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ensureWordmarkFont, WORDMARK_FAMILY } from '../Components';
import { SettingsDrawerPanel } from './SettingsScreen';
import { Route, Router } from '../Router';

// ⚠️ R73 移除：原先这里有一个 `BOTTOM_BAR_IDLE_MS = 420`（「停滑 420ms ⇒ 底栏再现」）。
// 它当时是照 R66-3 的原始要求（「滚动停下或向上滑时再出现」）实现的；R73 用户拍板改为
// 「**用 A 档，且最后要消失**，而不是坍缩在底部」⇒ 停滑自动复原与「最后要消失」直接冲突，
// 故整条移除（定时器、句柄、离页清理一并删）。现在的再现条件见 `syncBottomBarOnFirstIndex`。

/** 弹层种类（根节点只有一个 bindSheet，靠它分发内容）。 */
const SHEET_SESSION: string = 'session';
const SHEET_PROJECT: string = 'project';
const SHEET_PROJECT_EDIT: string = 'project_edit';

/**
 * R62：`Navigation` **标题栏的高度**（vp）—— **框架给定值，真机标定常量**。
 *
 * ## 值从哪来
 *
 * `dumpLayout` 实测 `TitleBar [0,137][1316,332]` ⇒ 栏高 **195px**；屏幕密度 **2.975**
 * （同一次 dump 可交叉验证：全屏 2832px ↔ `Area.height` 951.93vp）⇒ `195 / 2.975 = 65.5vp`，取 **66**。
 *
 * ⚠️ 它**只是「栏高」这一项**。`contentStartOffset` 要的是**内容起点的绝对坐标**（见
 *  `listTopOffsetVp()`），所以实际入参是「状态栏避让高度 + 本常量」，不是本常量本身
 *  —— 这正是第一次把它单独传进去时首项只到 196px 的原因。
 *
 * ## ⚠️ 为什么不用 `onAreaChange` 反算（**两次实测都算错**，别重犯）
 *
 * 标题栏是**框架控制高度**的 `Navigation` 自定义标题，相关两个节点的 `globalPosition` **参考系不一致**：
 * 实测 `Navigation.onAreaChange` 报 `top=0`、而 `homeTitleBar()` 的构造器报 `top=56vp`
 * （= 绝对 166px，与 dump 吻合）。用它俩相减求「栏内边距」会得到 56vp（真值 9.75vp）：
 *  · 第一版公式 ⇒ 传 **158vp**，首项落到 **470px**（栏底才 332px，下方空 138px —— 用户报的「离顶部还有很多距离」）；
 *  · 第二版改用安全区反算 ⇒ 传 **66vp**，首项落到 **196px**（钻到标题栏底下去了）。
 * ⇒ **标定常量 + 真机 dump 钉死**（首项应落在 **332px** 栏底附近）是这里唯一可靠的写法。
 */
const TITLE_BAR_VP: number = 66;

/**
 * R90：首页**刷新指示器圆环**的边长（vp）。
 *
 * 取 **32** 是为了与框架默认指示器**同尺寸**：R89 真机 dump 的默认指示器是
 * `LoadingProgress [610,137][706,220]` ⇒ 96px / 2.975 ≈ **32vp**。
 * ⚠️ 它现在画在 `Refresh` **外面**的浮层里（见 `build()` 的 ③），
 * 因为挂在 `Refresh` 内部时**位置与去留都有一半不归我们管**（三轮实测，见 `refreshArea()` 的注释）。
 */
const REFRESH_INDICATOR_VP: number = 32;

/**
 * R90：下拉多少（vp）才显示出刷新指示器。
 *
 * 取 **16** 与框架默认的 `triggerLoadingDistance`（16vp）同源 —— 即"下拉刚一起效就该有反馈"。
 * ⚠️ 配合 `pullActive` 的滞回：亮用本阈值、灭用 `offset <= 0`，避免在阈值附近抖动。
 */
const PULL_SHOW_VP: number = 16;

/**
 * R88 真机验证探针（⚠️ **交付档必须是空串**，`suite-material` 有断言钉住）：
 * 非空时给首页**强行注入**一条错误信息，用来在真机上量「错误条出现时它落在哪」。
 *
 * 为什么需要它：本机只有在断网（用户截图那种 `Operation timed out`）时才出错误条，
 * 而实测 `svc wifi disable` 之后应用**仍显示缓存列表、不报错**（请求未失败或超时未到），
 * 复现不稳定 ⇒ 用编译期常量把这条路径**确定性地**打开，量完即改回 `''`。
 */
const R88_ERROR_PROBE: string = '';

/**
 * R90 真机验证探针（⚠️ **交付档必须为空串**，`suite-material` 有断言钉住）：
 * 非空时在下拉刷新里**把 `refreshing` 多钉住这么多毫秒**，用来确定性地量
 * 「刷新态圆圈落在屏幕哪个 y」—— 真机 `dumpLayout` 单次约 1.7 秒，
 * 而正常刷新只有几秒，采样根本追不上（V6 那轮 40 次采样全部落在手势之外）。
 *
 * 用法：改成 `'8000'` → 构建 → 下拉 → 从容 dump；量完**必须改回 `''`**。
 */
const R90_REFRESH_PROBE: string = '';

/**
 * `CustomPopupOptions.onStateChange` 的入参。
 *
 * SDK 里它是**匿名对象类型**（`component/common.d.ts` 的 `(event: { isVisible: boolean }) => void`），
 * ArkTS 需要一个具名类型来标注箭头函数参数，故声明等价接口。
 */
interface AaPopupStateChange {
  isVisible: boolean;
}

/** 就地弹窗的两个常量（上游 `AADropdownMenu` / `AAAnchoredPopup`）。 */
/** 下拉菜单与触发按钮的间距（上游 `AADropdownMenu.MenuGap = 4.dp`）。 */
const MENU_GAP: number = 4;
/** 项目动作卡与触发按钮的间距（上游 `AAAnchoredPopup` 默认 `gap = 6.dp`）。 */
const CARD_GAP: number = 6;
/** 动作卡上下内边距（上游 `HomeProjectActionCard.padding(vertical = 7.dp)`）。 */
const CARD_PAD_V: number = 7;

/** 偏好持久化键（`AppStorage` 只放原始类型，集合按逗号分隔的字符串存）。 */
const FILTER_KEY: string = 'aaProjectFilter';
/**
 * 旧键：项目「**展开**」集合（白名单语义）。
 *
 * ⚠️ R38 起不再写入，只在冷启动时读一次作为**一次性迁移**的依据（见 `migrateCollapsedIds`）。
 *  迁移完成后会被写成哨兵串 `'*'`，表示「这台机器已经迁移过」。
 */
const EXPANDED_KEY: string = 'aaProjectExpanded';
/**
 * 新键：项目「**手动折叠**」集合（黑名单语义）。
 *
 * 为什么不复用旧键：旧键存的是「展开白名单」，直接当黑名单读会把「用户展开过的项目」
 * 判成「用户折叠过的项目」，语义 180 度反转 —— 老用户升级后列表会正好反过来。
 *
 * ⚠️ 值的**唯一来源**是 `AppPreferences.PROJECT_COLLAPSED_KEY`：键名必须与 `install()` 里
 * 注册给 `PersistentStorage` 的那个字面量一致，两处各写一份迟早会漂。
 */
const COLLAPSED_KEY: string = PROJECT_COLLAPSED_KEY;
const SECTION_KEY: string = 'aaProjectsExpanded';
/** 迁移完成标记（写进旧键，避免每次冷启动都重算迁移）。 */
const MIGRATED_SENTINEL: string = '*';

/** 顶栏提示条自动消失时间（毫秒）。安卓对应 `AAToast`（Snackbar）。 */
const NOTICE_MILLIS: number = 4000;

/** 设置抽屉的滑入 / 滑出时长（毫秒）。抽屉内部的 transition 用的也是同一个量级。 */
const SETTINGS_ANIM_MS: number = 240;
/**
 * R39：页面**入场**淡入时长（与设置抽屉同一个 240ms 量级的转场口径，取略短的 200ms）。
 *
 * ⚠️ 只做 `opacity`，**不做位移**：本工程的路由分发是 `pages/Index.ets` 里的 `if/else` 单分支，
 *  同一时刻只有一个页面节点 —— 旧页面是**瞬消**的，加位移会在「旧页消失」与「新页滑入」之间
 *  露出一帧空白底。R38 刚治完「刷新闪」，入场动效必须最小步走。
 */
const PAGE_ENTER_MS: number = 200;

@Component
export struct HomeScreen {
  // ---- 数据快照（build 只读这些字段） ----
  @State devices: AgentDevice[] = [];
  @State pinnedRows: ProjectRow[] = [];
  @State regularRows: ProjectRow[] = [];
  @State pinnedSessionRows: AgentSession[] = [];
  @State recentRows: AgentSession[] = [];
  @State visibleProjectCount: number = 0;
  @State activeShowLoadMore: boolean = false;
  @State activeLoadingMore: boolean = false;
  @State activePageError: string = '';
  @State archivedShowLoadMore: boolean = false;
  @State archivedLoadingMore: boolean = false;
  @State archivedPageError: string = '';
  @State loading: boolean = false;
  @State error: string = '';
  @State realtimeConnected: boolean = false;
  @State userName: string = '';
  /** 下拉刷新的视觉状态（`Refresh` 组件双向绑定）。 */
  @State refreshing: boolean = false;
  /**
   * R90：**下拉中**是否显示指示器（`Refresh.onOffsetChange` 驱动）。
   *
   * ⚠️ 用**布尔 + 滞回**而不是把 offset 数值存下来：`build()` 读了它 ⇒ 每写一次就重跑整页 build。
   *  `onOffsetChange` 是**逐帧**回调，存数值会让整页每帧重建（本页 build 很重）⇒ 只在**跨阈值**时翻一次。
   *  滞回：`≥ 16vp` 亮（与框架默认的 `triggerLoadingDistance` 16vp 同源）、`≤ 0` 灭 ⇒ 一次手势最多翻两次。
   */
  @State pullActive: boolean = false;
  /** 顶栏提示条（上游 `AAToast` 的等价物；用节点而不是 promptAction：可 dump 验证且零告警）。 */
  @State notice: string = '';
  /**
   * R39：页面入场淡入的开关（`false` → 首帧透明，下一帧置 `true` 由隐式动画补间到不透明）。
   *
   * ⚠️ 必须**延后一帧**置位（见 `aboutToAppear` 里的 `setTimeout(..., 0)`）：
   *  `aboutToAppear` 在首次 `build` **之前**执行，同步置 `true` 会让首帧就是 opacity 1 ⇒ 没有动画。
   */
  @State entered: boolean = false;
  /** 入场置位的定时器句柄；页面销毁时必须清掉（否则会往已销毁组件的 @State 里写值）。 */
  private enterTimer: number = -1;

  /**
   * R62：页面内容顶（系统状态栏避让区，vp）—— 由 `EntryAbility` 实测写入，**响应式**。
   */
  @StorageLink(SAFE_AREA_TOP_PX) safeTopPx: number = 0;

  /**
   * ## R62：列表要让位的**内容起点绝对坐标**（vp）—— `List.contentStartOffset` 的入参
   *
   * ### 语义（由真机两点标定出来的）
   *
   * `contentStartOffset(v)` 把内容起点放到 **绝对 y = v × 屏幕密度** 的位置，
   * **不是**「相对视口顶偏移 v」：
   *  · `v = 158` ⇒ 首项落在 `158 × 2.975 = 470px` ✓（实测）
   *  · `v = 66` ⇒ 首项落在 `66 × 2.975 = 196px` ✓（实测）
   * ⇒ 要让首项**正好落在标题栏下沿**（实测 `TitleBar [0,137][1316,332]` ⇒ 332px），
   *  必须传「状态栏避让高度 + 标题栏高」= `46 + 66 = 112vp`（112 × 2.975 ≈ 333px ✓）。
   *
   * ⚠️ **不要用 `onAreaChange` 反算**：标题栏是**框架控制高度**的 `Navigation` 自定义标题，
   *  两个相关节点的 `globalPosition` 参考系不一致（实测 `Navigation` 报 0、构造器报 56vp），
   *  反算两次都错（158vp → 首项 470px、下方空 138px；66vp → 首项 196px、钻到栏底下）。
   */
  private listTopOffsetVp(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + TITLE_BAR_VP;
  }

  /**
   * **有效错误文案**（真实错误优先，其次真机探针）。
   *
   * ⚠️ R89 修正：探针**必须与真实错误状态完全等价**，否则量出来的东西是伪影 ——
   * 上一版探针只让 `AaErrorBanner` 显示（`listArea` 里 `|| R88_ERROR_PROBE.length > 0`），
   * 但 `contentTopOffsetVp()` 只认 `this.error` ⇒ 探针包下 List **又让位了一次 333px**，
   * 于是「错误条与列表首项之间」量出约 190px 的空白 —— **那是探针伪影，不是真实缺陷**
   * （真实断网时 `this.error` 非空：错误条容器 `[53,332][1263,496]`、List 顶 `519`，只隔 23px）。
   * ⇒ 所有读错误状态的地方一律走本方法。
   */
  private effectiveError(): string {
    return this.error.length > 0 ? this.error : R88_ERROR_PROBE;
  }

  /**
   * ## R88 → R89（`margin` 版）→ **R90（回到内容层让位）**：这一族"让位"的三轮演进
   *
   * · **R88**：`List` 用 `contentStartOffset`、错误条/空态/加载中各自 `padding.top`，
   *  再靠 `contentTopOffsetVp()` 去重（有错误条时归 0）—— 三处都要记着让位，脆。
   * · **R89**：让位**收回到一处** —— `Refresh` 整体 `.margin({ top: listTopOffsetVp() })`，
   *  内容层内部一律不让位（`contentTopOffsetVp()` 随之被删）。
   *  这么改是因为刷新圆圈被画在 `Refresh` 自己的顶边（137px）＝标题栏内；
   *  但**代价**是内容再也穿不过标题栏（用户第二期明确说更看重「穿过」）。
   * · **R90（现行）**：`margin` **已撤销**（`Refresh` 回原位 ⇒ 内容重新从标题栏背后穿过），
   *  指示器**移出 `Refresh`**、自绘在外层浮层（`Refresh` 里的 `builder` 只留空 `Column` 关掉默认指示器）
 *  ⇒ 内容层的让位**全部回来**
   *  （错误条 / 空态 / 加载中走本方法，两条 `List` 走 `contentStartOffset`）。
   *
   * ⚠️ 本方法是那"三处让位"的**唯一去重闸**：有错误条时返回 0（错误条已经让过一次），
   *  否则返回完整让位量。**它必须与"内容流第一行是谁"保持一致**，否则首行会多空/少空一整条标题栏。
   */
  private contentTopOffsetVp(): number {
    return this.effectiveError().length > 0 ? 0 : this.listTopOffsetVp();
  }

  // ---- 视图状态 ----
  @State filter: string = ProjectSessionFilter.ACTIVE;
  /**
   * 被用户**手动折叠**的项目 id（R38 起是黑名单语义）。
   *
   * 初值空数组 = 没有任何项目被折叠过 = **全部展开**，这正是用户要的「项目默认全部加载」。
   * 服务端后续新增的项目天然不在这个集合里 ⇒ 也会自动展开（增量展开行为）。
   *
   * ⚠️ 它**不是** build 的渲染依赖（build 不直接读它）：真正进 build 的是 `pinnedRows` /
   *  `regularRows`，它们的 `expanded` 字段由 `pull()` 里的 `buildProjectRows(..., this.collapsedIds)`
   *  算出来。所以**任何改动折叠集合的地方都必须紧跟着调 `pull()`**（`toggleProject` 就是这么做的），
   *  否则界面不会动 —— 与坑 134「@State 只在 build 读过它时才登记渲染依赖」是同一件事。
   */
  @State collapsedIds: string[] = [];
  @State projectsExpanded: boolean = true;
  @State pinnedExpanded: boolean = true;
  @State recentExpanded: boolean = true;
  /**
   * 「侧边栏显示」（设置抽屉里的偏好）：`project` = 项目分组视图，`session` = 平铺会话视图
   * （上游 `HomeSidebarViewMode` + `HomeContent` 的二选一；开关在设置抽屉的「侧边栏显示」一行）。
   *
   * ⚠️ `@StorageLink` 的参数必须是**字符串字面量**，所以这里不能写常量。
   */
  @StorageLink('aaSidebarView') sidebarView: string = 'project';
  /**
   * 设置抽屉的开合（上游 `HomeScreen.kt:304` 的 `profileOpen`，**只在首页作用域里**）。
   *
   * 抽屉本体是 `SettingsDrawerPanel`（settings-ui 交付，`./SettingsScreen` 导出）：全屏左滑覆盖首页，
   * 无圆角 / 无阴影 / 无遮罩（上游 `ProfileSettingsDrawer.kt:150-153` 就是 `Box.fillMaxSize` 左滑）。
   * ⚠️ 关闭态它**完全卸载**（内部 `if (this.open)`），所以不会挡首页的点击。
   * ⚠️ 系统返回键由抽屉自己消费（`ui/BackHandler.ets` 的注册表）—— 首页**不注册**消费者，
   *  否则会把抽屉的消费者挤掉（注册表只有一个槽）。
   */
  @State settingsOpen: boolean = false;
  /**
   * 底栏**自动收回**状态（R66-3）—— 键与 `ui/BottomNav.ets` 的 `BOTTOM_BAR_HIDDEN_KEY` **必须同值**
   * （沿用本文件 L217 的既有约定：`@StorageLink` 参数写字面量；`pages/Index.ets` 那边用的是那个常量）。
   *
   * ⚠️ **全工程只有本页写它**（列表滚动方向 / 停滑 / 抽屉开合）⇒「只首页自动收回、其余页常驻」由写入方天然保证。
   * 读取方是 `pages/Index.ets` 的浮层底栏（路线 B）或 Tabs bar（路线 A）。
   */
  @StorageLink('aaBottomBarHidden') bottomBarHidden: boolean = false;
  /** 上一次列表首项下标 —— 判方向用（`onScrollIndex` 的 `start` 是**绝对语义**，无歧义）。 */
  private lastFirstIndex: number = -1;
  // ⚠️ R73：原 `bottomBarTimer`（停滑再现定时器）已删除 —— 见文件顶部那一段说明。

  // ---- 就地弹窗（R13-9 F-6/F-5） ----
  // 上游这两处都是「贴触发按钮的浮层」而非底部弹层 + 全页遮罩（`AADropdownMenu` / `AAAnchoredPopup`），
  // 所以它们**不进** bindSheet —— 否则会给整页压一层 scrim（安卓实测 P06 行中位数 252 vs 鸿蒙 202）。
  /** 分组头「…」→ 会话状态筛选（上游 `HomeProjectFilterMenu`）。 */
  @State filterMenuOpen: boolean = false;
  /** 项目行「…」→ 编辑/置顶/归档（上游 `HomeProjectActionOverlay`）；存项目 id，空串 = 关闭。 */
  @State projectMenuRowKey: string = '';
  /**
   * 会话行「⋯」→ 重命名 / 置顶 / 归档 / 标记已读（本轮从**底部大面板**改成**就地小窗口**）。
   *
   * 用户原话：「点开对话菜单时，弹出的窗口优化，改为小窗口显示重命名、置顶、归档、标记已读就行」。
   * 形态与同页的项目动作卡一致（锚在「⋯」下方、无遮罩、卡片自己画底/描边/圆角）。
   * 存会话 id，空串 = 关闭。
   */
  @State sessionMenuRowKey: string = '';

  // ---- 唯一弹层（会话操作面板 / 项目归档确认 / 项目编辑表单） ----
  @State showSheet: boolean = false;
  @State sheetKind: string = '';

  // ---- 会话操作面板（布尔开关 + 标量快照，见 EXPERIENCE §15） ----
  @State actionSheetSessionId: string = '';
  @State actionSheetTitle: string = '';
  @State actionSheetPinned: boolean = false;
  @State actionSheetArchived: boolean = false;
  @State renameValue: string = '';
  @State renaming: boolean = false;

  // ---- 项目操作面板 ----
  @State projectSheetId: string = '';
  @State projectSheetName: string = '';
  @State projectSheetPath: string = '';
  @State projectSheetDevice: string = '';
  @State projectSheetPinned: boolean = false;
  @State projectRenameValue: string = '';
  @State projectEditBusy: boolean = false;
  @State projectEditError: string = '';
  /** 「归档该项目」的二次确认（对齐上游 `HomeArchiveProjectDialog`）。 */
  @State projectArchiveConfirm: boolean = false;

  private store: DashboardStore = DashboardStore.get();
  /**
   * 项目行的**固定顺序**（R55：用户报「多个工作区多个对话时首页项目频繁跳动」）。
   *
   * 存的是上一次 `buildProjectRows()` 返回的 `order`（全部项目 id，含本档未渲染的），
   * 下次原样传回去 ⇒ 后台快照（WS `dashboard.changed`）再频繁也不会让项目行换位。
   *
   * 清理时机只有两处，都是「用户主动要求重排」：
   *  · 下拉刷新（`onRefresh()`）；
   *  · 离开首页再回来（本字段随页面实例一起重建，届时按最新活动排一次）。
   *
   * ⚠️ 它**不是**渲染依赖（build 不读它，只读 `pinnedRows` / `regularRows`），所以加不加
   *  `@State` 都一样；用普通字段是为了明示「它不参与渲染」。
   */
  private projectOrder: string[] = [];
  /** 提示条定时器；页面销毁时必须清掉，否则会往已销毁组件的 @State 里写值。 */
  private noticeTimer: number = -1;
  /** 折叠偏好的老键迁移是否已经做过（每次冷启动只需一次，见 `migrateCollapsePreferenceOnce`）。 */
  private collapseMigrated: boolean = false;
  /**
   * 监听器必须存成字段：`offChange` 用 `indexOf` 定位，传匿名箭头函数摘不掉。
   * DashboardStore 是单例，只增不减会让「返回过的」页面继续被 notify（写已销毁组件的 @State）。
   */
  private storeListener: DashboardListener = () => {
    this.pull();
  };

  aboutToAppear(): void {
    // 字标字体（Caveat）必须在首次渲染前注册一次；幂等，重复进入首页无副作用。
    ensureWordmarkFont(this.getUIContext());
    this.store.onChange(this.storeListener);
    // 冷启动时首页可能先于设置抽屉渲染：显式装一次持久化（幂等），
    // 否则用户上次选的「会话视图」要等打开一次设置抽屉才恢复。
    AppPreferences.get().install();
    this.sidebarView = AppPreferences.get().sidebarView;
    this.syncProfile();
    this.restorePreferences();
    this.pull();
    this.store.refreshAll();
    this.store.startRealtime();
    // R39 入场淡入：**延后一帧**再置位 —— 首次 build 必须读到 `false`（opacity 0），
    // 下一帧置 `true` 才会被根节点那条 `.animation()` 补间；同步置位等于没有动画。
    this.enterTimer = setTimeout(() => {
      this.enterTimer = -1;
      this.entered = true;
    }, 0);
  }

  aboutToDisappear(): void {
    // R66-3：离页复位 —— 底栏状态是**跨组件**的（Index 读它），留着「收起」会让下次回首页时底栏先不见。
    this.setBottomBarHidden(false, 'leave-page');
    this.lastFirstIndex = -1;
    this.store.offChange(this.storeListener);
    if (this.noticeTimer >= 0) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = -1;
    }
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  // -------------------------------------------------------------------------
  // 状态同步
  // -------------------------------------------------------------------------

  private syncProfile(): void {
    this.userName = authController.current.displayName;
  }

  /**
   * 读回上次的筛选档 / **折叠集合** / 分组折叠（上游 `HomeProjectPreferences` 的同款语义）。
   *
   * ⚠️ R38：这里读的是**新键** `COLLAPSED_KEY`（手动折叠集合）。老用户的旧键
   * （`EXPANDED_KEY`，展开白名单）不能直接拿来当折叠集合用 —— 迁移放到 `pull()` 里做，
   * 因为迁移需要「当前全部项目 id」这个输入，而此刻 store 还没拉到项目。
   */
  private restorePreferences(): void {
    const filter = AppStorage.get<string>(FILTER_KEY);
    this.filter = normalizeProjectSessionFilter(filter !== undefined ? filter : '');
    const collapsed = AppStorage.get<string>(COLLAPSED_KEY);
    this.collapsedIds = parseProjectCollapsed(collapsed !== undefined ? collapsed : '');
    const section = AppStorage.get<boolean>(SECTION_KEY);
    this.projectsExpanded = section !== undefined ? section : true;
  }

  /**
   * 老用户一次性迁移：旧「展开白名单」→ 新「折叠黑名单」（R38）。
   *
   * 为什么必须等 store 拉到项目才做：迁移要算「当前项目里哪些不在旧白名单中」，
   * 没有项目列表就只能凭空猜。所以它挂在 `pull()` 里、项目非空时执行一次。
   *
   * 规则见 `HomeGrouping.migrateCollapsedIds`；迁移完把旧键写成哨兵串，
   * 下次冷启动直接走新键，不再重算。
   */
  private migrateCollapsePreferenceOnce(): void {
    if (this.collapseMigrated || this.store.projects.length === 0) {
      return;
    }
    const legacyRaw = AppStorage.get<string>(EXPANDED_KEY);
    const legacy = legacyRaw !== undefined ? legacyRaw : '';
    if (legacy === MIGRATED_SENTINEL) {
      this.collapseMigrated = true;
      return;
    }
    const projectIds: string[] = [];
    for (let i = 0; i < this.store.projects.length; i++) {
      projectIds.push(this.store.projects[i].id);
    }
    const stored = AppStorage.get<string>(COLLAPSED_KEY);
    const collapsed = migrateCollapsedIds(stored !== undefined ? stored : '', legacy, projectIds);
    this.collapseMigrated = true;
    if (!stringListsEqual(collapsed, this.collapsedIds)) {
      this.collapsedIds = collapsed;
    }
    AppStorage.setOrCreate(COLLAPSED_KEY, serializeProjectCollapsed(collapsed));
    AppStorage.setOrCreate(EXPANDED_KEY, MIGRATED_SENTINEL);
  }

  /** 活跃 + 归档两侧合并去重后的全集（项目行的会话来源）。 */
  private allSessions(): AgentSession[] {
    return mergeSessionsById(this.store.activeSessions, this.store.archivedSessions);
  }

  /**
   * store → @State 快照（build 只读这些字段）。
   *
   * ⚠️ **R38 差分更新（消除刷新闪烁的核心）**：数组一律「**内容相等就不赋值**」。
   *  ArkUI 的 `@State` 对**原始类型**赋相同值本身就是 no-op，但对**数组 / 对象**
   *  赋新引用一律视为变化 —— 于是每次 notify（WS 每次 `dashboard.changed` 都推全量快照、
   *  下拉刷新、写操作后的 `refreshAll`）都会让整页白跑一遍 diff，用户看到的就是「闪一下」。
   *  改成先比较、相等就保留旧引用之后，内容没变的 notify 变成完全静默。
   *
   * ⚠️ 标量（`loading` / `error` / `*ShowLoadMore` 等）**不需要**差分，直接赋值即可。
   */
  private pull(): void {
    this.migrateCollapsePreferenceOnce();

    const devices = this.store.devices.slice();
    if (!deviceListsEqual(devices, this.devices)) {
      this.devices = devices;
    }

    // 折叠集合只清掉「已经不存在的项目 id」；内容没变就保留旧引用（prune 每次都返回新数组）。
    const collapsed = pruneUnknownProjectIds(this.collapsedIds, this.store.projects);
    if (!stringListsEqual(collapsed, this.collapsedIds)) {
      this.collapsedIds = collapsed;
    }

    // R55：顺序**沿用上一次**（`this.projectOrder`），只有新项目才按最新活动插到规范位置 ——
    // 不这么做的话，WS 每推一次快照都会按「最近活动」重排一次项目行（用户看到的「频繁跳动」）。
    // R91-T2：**只算一次**合并集合，三处共用。
    // 改前 `this.allSessions()` 在一次 pull() 里被调 3 次，而它是
    // `mergeSessionsById(active, archived)`：内部用**数组 + indexOf** 去重 ⇒ 每次 O(N²)
    // （N = 活跃 + 归档会话数，分页加载后会到几百条）。而 pull() 挂在 store 的每次
    // notify 上（WS 的 dashboard.changed 全量快照、下拉刷新、写操作后的 refreshAll 都会触发），
    // 于是同一份输入在一帧里被 O(N²) 地算了三遍。
    //
    // 语义不变：三次调用的入参完全相同（同一个 store 引用的 activeSessions/archivedSessions，
    // pull() 内不会改它们），而 mergeSessionsById 是**纯函数**（不读全局、不取时间、不改入参）
    // ⇒ 三次结果逐项相同，合并成一次只是省掉两份重复计算。
    const allSessions = this.allSessions();

    const rows = buildProjectRows(this.store.projects, allSessions, this.filter, this.collapsedIds,
      this.projectOrder);
    this.projectOrder = rows.order;
    if (!projectRowListsEqual(rows.pinned, this.pinnedRows)) {
      this.pinnedRows = rows.pinned;
    }
    if (!projectRowListsEqual(rows.regular, this.regularRows)) {
      this.regularRows = rows.regular;
    }
    this.visibleProjectCount = rows.visibleCount;

    const pinnedSessions = pinnedSessionsOf(allSessions, this.filter);
    if (!sameSessionList(pinnedSessions, this.pinnedSessionRows)) {
      this.pinnedSessionRows = pinnedSessions;
    }
    const recentSessions = recentSessionsOf(allSessions, this.filter);
    if (!sameSessionList(recentSessions, this.recentRows)) {
      this.recentRows = recentSessions;
    }

    this.activeShowLoadMore = this.store.showLoadMore(false);
    this.activeLoadingMore = this.store.loadingMore(false);
    this.activePageError = this.store.loadMoreError(false);
    this.archivedShowLoadMore = this.store.showLoadMore(true);
    this.archivedLoadingMore = this.store.loadingMore(true);
    this.archivedPageError = this.store.loadMoreError(true);
    this.loading = this.store.loading;
    this.error = this.store.error;
    this.realtimeConnected = this.store.realtimeConnected;
  }

  /** 顶栏提示条：4 秒后自动消失（同时只留一条，新提示覆盖旧提示）。 */
  private showNotice(text: string): void {
    this.notice = text;
    if (this.noticeTimer >= 0) {
      clearTimeout(this.noticeTimer);
    }
    this.noticeTimer = setTimeout(() => {
      this.noticeTimer = -1;
      this.notice = '';
    }, NOTICE_MILLIS);
  }

  /**
   * 下拉刷新：跑完必须把 `refreshing` 置回 false，否则指示器不会收（`Refresh` 的约定）。
   *
   * ## R89 修复（与 DevicesScreen 同款隐患，用户报的是设备页）
   * 改前是裸 `await this.store.refreshAll(); this.refreshing = false;` ——
   * `refreshAll()` **reject 时 `await` 会抛出**，`refreshing = false` 那行**永远走不到**
   * ⇒ 下拉圆圈一直转（断网 / 401 / 服务端 5xx 都会触发）。⇒ 用 `try/finally`。
   */
  private async onRefresh(): Promise<void> {
    // R55：下拉刷新是**用户主动**要求重排 —— 先清掉固定顺序，让项目行按最新活动重新排一次。
    // 换筛选档 / 展开折叠都**不**清，避免用户只是切个视图就把列表顺序打乱。
    this.projectOrder = [];
    try {
      await this.store.refreshAll();
    } catch (error) {
      // 失败也要收指示器；错误文案由 `store.error` 走 store 回调同步到本页的 `error`。
    } finally {
      // R90 真机探针（交付档为空串 ⇒ 这段是死代码）：把刷新态钉住，便于从容 dump 圆圈落点。
      const probe = Number.parseInt(R90_REFRESH_PROBE, 10);
      if (!Number.isNaN(probe) && probe > 0) {
        await new Promise<void>((resolve) => { setTimeout(() => { resolve(); }, probe); });
      }
      this.refreshing = false;
    }
  }

  /** 当前是不是「会话视图」（平铺会话列表，上游 `HomeList` + `SessionList`）。 */
  private isSessionView(): boolean {
    return this.sidebarView === SIDEBAR_VIEW_SESSION;
  }

  /** 当前视图下有没有任何可渲染的行（决定是显示列表还是空态）。 */
  private hasAnyRow(): boolean {
    if (this.isSessionView()) {
      return this.pinnedSessionRows.length > 0 || this.recentRows.length > 0;
    }
    return this.visibleProjectCount > 0 || this.pinnedSessionRows.length > 0;
  }

  /** 收起时展开「项目」分组（上游 `onCreateProject` 里的 `if (!projectsExpanded) toggleSection()`）。 */
  private toggleProjectsSectionIfCollapsed(): void {
    if (!this.projectsExpanded) {
      this.toggleProjectsSection();
    }
  }

  // -------------------------------------------------------------------------
  // 视图操作
  // -------------------------------------------------------------------------

  private applyFilter(next: string): void {
    this.filter = normalizeProjectSessionFilter(next);
    AppStorage.setOrCreate(FILTER_KEY, this.filter);
    this.filterMenuOpen = false;
    this.pull();
  }

  private toggleProjectsSection(): void {
    this.projectsExpanded = !this.projectsExpanded;
    AppStorage.setOrCreate(SECTION_KEY, this.projectsExpanded);
  }

  /**
   * 展开 / 折叠一个项目（R38 起作用于**折叠黑名单**）。
   *
   * ⚠️ 「点击之后集合怎么变」全部交给 `HomeGrouping.toggleCollapsedId` —— **调用点不要自己算**。
   *  集成验收实测过一个真 bug：这里原本在调用点自己算集合增删的布尔实参，而算出来的是
   *  「当前是否未展开」（即「当前折叠」），**不是**「用户想要折叠」——两者在「已展开」这一侧
   *  正好相反，于是双向都退化成空操作（点项目行完全没反应）。
   *  纯函数化之后这个语义只剩一个入口，且可被 Node 断言直接钉住（见 suite-home 的 R38-8/R38-9）。
   *
   * ⚠️ 这段注释刻意**不写**出那段错误代码的字面量：R38-9 有一条源码断言要求整个 HomeScreen
   *  里不再出现旧的组合，注释里带上它会把自己的断言弄红（注释应描述意图，不该留死代码）。
   */
  private toggleProject(projectId: string): void {
    this.collapsedIds = toggleCollapsedId(this.collapsedIds, projectId);
    AppStorage.setOrCreate(COLLAPSED_KEY, serializeProjectCollapsed(this.collapsedIds));
    this.pull();
  }

  private openSheet(kind: string): void {
    this.sheetKind = kind;
    this.showSheet = true;
  }

  /**
   * 会话状态筛选的就地弹窗参数（上游 `AAAnchoredDropdownMenu` + `menuSurface`）。
   *
   * 逐项对应关系：
   *  · `placement: BottomRight` —— 弹窗**右边缘对齐触发按钮右边缘**、挂在按钮下方；上游算的正是
   *  `x = anchor.right - 286dp`（安卓 dump：菜单左 298 / 右 1149px，`…` 右边缘 1149px = 386.2dp）。
   *  · `targetSpace: MENU_GAP(4)` —— 上游 `DropdownMenu(offset = DpOffset(0.dp, 4.dp))`。
   *  · `enableArrow: false` —— 上游没有箭头。
   *  · `mask: { color: Transparent }` —— **透明**遮罩：只吃掉外部点击（点外部关闭），**完全不压暗**。
   *  这是 F-5 的正解：安卓这一屏没有 scrim（P06 行中位数 252），鸿蒙原来用 bindSheet 才多出那层 −50。
   *  · `popupColor: Transparent` + `backgroundBlurStyle: NONE` + 零阴影 —— 容器不画任何东西，
   *  卡片（底色 / 1dp 描边 / 圆角）全部由 `filterMenuPopup()` 自己画，才能和上游逐项对上。
   */
  private filterMenuPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.filterMenuPopup();
      },
      placement: Placement.BottomRight,
      targetSpace: MENU_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      // R86：弹窗容器的**底**改由官方沉浸光感接管；内容根同一探针门控成「材质档零自绘层 / 不可用档自绘玻璃」
      // （两档互斥，绝不共存 ⇒ 不存在「材质 + 自绘」双保险）。
      // · 官方依据 `CustomPopupOptions.systemMaterial`（SDK `common.d.ts:14406`）。
      // · 生效范围：`bindPopup` 属**弹窗类接口** ⇒ 依官方「生效范围」在**页面内全部区域**生效
      // （`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）。
      // · 关闭姿势 = `uiMaterial.Material.empty`（= disable，SDK `uiMaterial.d.ts:467-472`），由
      //  `dialogMaterial()` 在探针不可用时自己返回；**不得**改传 `undefined`（官方语义是
      //  「恢复组件默认材质」，`common.d.ts:22632-22633` / `坑 256`）。
      // · 回退：删掉下面这一行 ⇒ 内容根的三元恒走自绘玻璃支路（`menuSurface()`），逐字回到 R86 前行为。
      systemMaterial: dialogMaterial(),
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_WIDTH,
      radius: Radius.XL,
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.filterMenuOpen = false;
        }
      }
    };
  }

  /** 项目「…」就地弹窗参数（上游 `AAAnchoredPopup`：默认 gap 6dp、宽度由卡片自己定 252）。 */
  private projectMenuPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.projectMenuPopup();
      },
      placement: Placement.BottomRight,
      targetSpace: CARD_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      // R86：容器底改由官方沉浸光感接管；内容根由**同一探针**门控成「材质档零自绘层 / 不可用档自绘玻璃」。
      // · 官方依据 `CustomPopupOptions.systemMaterial`（SDK `common.d.ts:14406`）。
      // · 生效范围：`bindPopup` = 弹窗类接口 ⇒ 页面内全部区域生效（`坑 245`）。
      // · 关闭姿势 = `Material.empty`（由 `dialogMaterial()` 在探针不可用时返回，SDK `uiMaterial.d.ts:467-472`）；
      //  **不得**传 `undefined`（= 恢复组件默认材质，`common.d.ts:22632-22633` / `坑 256`）。
      // · 回退：删掉下面这一行 ⇒ 内容根恒走自绘玻璃支路，逐字回到 R86 前行为。
      systemMaterial: dialogMaterial(),
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_CARD_W,
      radius: Radius.XXL,
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.projectMenuRowKey = '';
        }
      }
    };
  }
  /** 会话「⋯」小窗口的弹窗参数（与项目动作卡同一套：无遮罩、无箭头、容器透明、卡片自画）。 */
  private sessionMenuPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.sessionMenuPopup();
      },
      placement: Placement.BottomRight,
      targetSpace: CARD_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      // R86：容器底改由官方沉浸光感接管；内容根由**同一探针**门控成「材质档零自绘层 / 不可用档自绘玻璃」。
      // · 官方依据 `CustomPopupOptions.systemMaterial`（SDK `common.d.ts:14406`）。
      // · 生效范围：`bindPopup` = 弹窗类接口 ⇒ 页面内全部区域生效（`坑 245`）。
      // · 关闭姿势 = `Material.empty`（由 `dialogMaterial()` 在探针不可用时返回，SDK `uiMaterial.d.ts:467-472`）；
      //  **不得**传 `undefined`（= 恢复组件默认材质，`common.d.ts:22632-22633` / `坑 256`）。
      // · 回退：删掉下面这一行 ⇒ 内容根恒走自绘玻璃支路，逐字回到 R86 前行为。
      systemMaterial: dialogMaterial(),
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_CARD_W,
      radius: Radius.XXL,
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.sessionMenuRowKey = '';
        }
      }
    };
  }
  /**
   * 就地弹窗卡片的底色（**R86 起只服务「材质不可用」那条回退支路**）。
   *
   * 上游 `AADropdownMenu.kt:176 menuSurface`：深色取 `subtle`、浅色取 `raisedSurface`；描边两边都取
   * `border`（本工程 `dark/border` 恰好是 `#00000000`，= 上游深色下的 `Color.Transparent`）。
   * ⚠️ 渲染期求值：弹窗正开着时切主题不会自动重取色（关掉再开就对）。
   * ⚠️ R86：三处弹窗内容根都改成 `immersiveMaterialEnabled() ? Color.Transparent : this.menuSurface()`
   *  —— 官方材质可用时底由材质画（材质接管 background / border / blur / shadow，`common.d.ts:22625-22630`），
   *  不可用时**逐字回到这里的自绘玻璃**。⚠️ **不要删**：弹窗容器自身是 `popupColor: Color.Transparent`，
   *  删了它，材质不可用的机器上弹窗会完全透明（文字浮在正文上）。
   */
  private menuSurface(): Resource {
    return isDarkAppearance() ? subtle() : raisedSurface();
  }

  /**
   * 首页列表**首项下标**变化 ⇒ 判方向、驱动底栏自动收回（R66-3；条件集 R73 收敛）。
   *
   * ## 现在的完整条件集（R73 定稿）
   * | 触发 | 结果 | 日志 `why` |
   * | --- | --- | --- |
   * | `start` 变大（向下浏览） | **收回** | `scroll-down` |
   * | `start` 变小（上滑回看） | 显示 | `scroll-up` |
   * | `start === 0`（回到顶部） | 显示 | `at-top` |
   * | `end <= 0`（不足一屏、没得滑） | 显示 | `no-scroll-needed(end<=0)` |
   * | `start` 与上次相同（停手 / 原地） | **不变**（这就是「停滑不自动复原」） | —— |
   * | 切页 / 离页 | 复位为显示 | `leave-page` |
   * | 打开设置抽屉 | 收回；关闭抽屉 | 显示（`drawer-open` / `drawer-close`） |
   *
   * · 用 `onScrollIndex` 而不是 `onDidScroll` 的 offset 判方向：前者是**绝对语义**
   *  （首/末可见项下标），后者是逐帧偏移量（SDK 原文的 «offset per frame»），语义不适合判累计方向。
   * ⚠️ 抽屉开着时不参与：底栏此刻本就该收着（否则 Index 的浮层会浮在抽屉之上）。
   * ⚠️ R73 不再有「停滑 N ms 自动复原」——理由见下面那段注释。
   */
  /**
   * `bottomBarHidden` 的**唯一写入入口**（R71）—— 赋值 + 探针一行，保证「每次状态变化都有原因可查」。
   * 探针在 `hdc shell hilog -x | Select-String aaBottomBar` 里看 `hidden <- x (why)`。
   */
  private setBottomBarHidden(value: boolean, why: string): void {
    if (BOTTOM_BAR_PROBE && value !== this.bottomBarHidden) {
      hilog.info(0x0000, 'aaBottomBar', 'hidden %{public}s -> %{public}s why=%{public}s',
        String(this.bottomBarHidden), String(value), why);
    }
    this.bottomBarHidden = value;
  }

  private syncBottomBarOnFirstIndex(start: number, end: number, source: string): void {
    // ⚠️ R71 探针（tag=aaBottomBar）：**每个回调都打**，即使下面因守卫提前 return ——
    //  它是「onScrollIndex 到底有没有回调」「start 有没有变化」「end 是否恒 ≤0」的唯一判据。
    if (BOTTOM_BAR_PROBE) {
      hilog.info(0x0000, 'aaBottomBar',
        'onScrollIndex src=%{public}s start=%{public}d end=%{public}d last=%{public}d open=%{public}s hidden=%{public}s',
        source, start, end, this.lastFirstIndex, String(this.settingsOpen), String(this.bottomBarHidden));
    }
    if (this.settingsOpen) {
      return;
    }
    // R73 新增：**回到顶部 ⇒ 显示**（用户从列表顶端重新开始时，底栏应当回来）。
    if (start === 0) {
      this.setBottomBarHidden(false, 'at-top');
      this.lastFirstIndex = start;
      return;
    }
    // 连最后一项都在首屏内 ⇒ 压根没得滑 ⇒ 保持显示（顺便让 `end` 这个参数有真实用途，
    // 而不是为了消除「未使用参数」凑数）。
    if (end <= 0) {
      this.setBottomBarHidden(false, 'no-scroll-needed(end<=0)');
      this.lastFirstIndex = start;
      return;
    }
    if (this.lastFirstIndex >= 0) {
      if (start > this.lastFirstIndex) {
        this.setBottomBarHidden(true, 'scroll-down');
      } else if (start < this.lastFirstIndex) {
        this.setBottomBarHidden(false, 'scroll-up');
      }
      // `start === lastFirstIndex` ⇒ **什么都不做**：这正是「停手不自动回来」的实现
      //（没有事件就没有状态变化；即便有事件而首项没变，也保持当前态）。
    }
    this.lastFirstIndex = start;
  }

  // ⚠️ R73：`armBottomBarShowTimer()`（「停滑 420ms ⇒ 自动复原」）已**整段删除**。
  //  理由：用户要求「用 A 档，且**最后要消失**，而不是坍缩在底部」—— 停滑自动复原会让底栏
  //  在停手 420ms 后自己回来，与「最后要消失」直接冲突。
  //  它原本不是随手加的：R66-3 的原始要求写的是「滚动停下或向上滑时再出现」，这条定时器就是照那句话做的。
  //  R73 起**由用户的新要求覆盖**：再现条件收敛为「上滑 / 回到顶部 / 切页离页复位 / 关抽屉」，
  //  停手本身不再触发任何状态变化（主流阅读类应用的自动隐藏底栏就是这个语义）。
  //  （历史分支：若将来又要「停滑再现」，把定时器加回即可 —— 探针里的 `why` 会区分 `idle-timeout`。）

  /**
   * 打开设置抽屉。
   *
   * ⚠️ 必须用 `animateTo` 包住这次赋值：ArkUI 的 `transition` 只在「插入 / 删除发生在 animateTo 闭包内」
   * 时补间；直接赋值也能开，但抽屉会**瞬现**（上游是从左滑入）。
   * ⚠️ 用 `this.getUIContext().animateTo(...)`（组件级）而不是全局 `animateTo`：多实例下前者的归属明确。
   */
  private openSettingsDrawer(): void {
    // R66-3：抽屉全屏覆盖首页（含底栏那条）⇒ 让浮层底栏先收回，避免它浮在抽屉之上。
    this.setBottomBarHidden(true, 'drawer-open');
    this.getUIContext().animateTo({ duration: SETTINGS_ANIM_MS, curve: Curve.FastOutSlowIn }, () => {
      this.settingsOpen = true;
    });
  }

  /** 关闭设置抽屉（抽屉内「‹」在根页时回调到这里；同样要走动画闭包，否则瞬时消失）。 */
  private closeSettingsDrawer(): void {
    this.getUIContext().animateTo({ duration: SETTINGS_ANIM_MS, curve: Curve.FastOutSlowIn }, () => {
      this.settingsOpen = false;
    });
    // R66-3：抽屉关掉 ⇒ 底栏回到显示态（与列表滚动的写入方一致，都是本页）。
    this.setBottomBarHidden(false, 'drawer-close');
  }

  // -------------------------------------------------------------------------
  // 会话 / 项目操作
  // -------------------------------------------------------------------------

  private openActions(session: AgentSession): void {
    this.snapshotSession(session);
    this.openSheet(SHEET_SESSION);
  }

  /** 把会话行的快照存进 `actionSheet*` 字段（弹层与就地弹窗**共用**同一份快照，见 EXPERIENCE §15）。 */
  private snapshotSession(session: AgentSession): void {
    this.actionSheetSessionId = session.id;
    this.actionSheetTitle = session.title;
    this.actionSheetPinned = session.pinned;
    this.actionSheetArchived = session.archived;
    this.renaming = false;
    this.renameValue = session.title;
  }

  /**
   * 会话行「⋯」→ **就地小窗口**（本轮按用户要求从底部大面板改过来）。
   *
   * 只放四个动作（重命名 / 置顶 / 归档 / 标记已读）；「重命名」要输入框，点它再进二级
   * （仍然复用原来那个 bindSheet，避免为了一个输入框自造一套弹层）。
   */
  private openSessionMenu(session: AgentSession): void {
    this.snapshotSession(session);
    this.sessionMenuRowKey = session.id;
  }

  /**
   * 项目「…」：存下这一行的快照并**就地弹窗**（上游 `HomeProjectComponents.kt:452`）。
   * 弹窗内容读 `projectSheet*`（@Builder 值参数不重建，所以一律走字段，见 EXPERIENCE §15）。
   */
  private openProjectMenu(row: ProjectRow): void {
    this.projectSheetId = row.projectId;
    this.projectSheetName = row.name;
    this.projectSheetPath = row.workspacePath;
    this.projectSheetPinned = row.pinned;
    this.projectRenameValue = row.name;
    this.projectEditError = '';
    this.projectArchiveConfirm = false;
    const project = this.store.projectById(row.projectId);
    this.projectSheetDevice = project !== undefined
      ? projectDeviceLabel(project, this.devices) : '未命名设备';
    this.projectMenuRowKey = row.projectId;
  }

  /** 项目 ✎（行内第二个按钮）：先关掉就地弹窗，再进编辑表单（上游 `HomeProjectEditSheet`）。 */
  private openProjectEdit(row: ProjectRow): void {
    this.openProjectMenu(row);
    this.projectMenuRowKey = '';
    this.openSheet(SHEET_PROJECT_EDIT);
  }

  private async toggleProjectPinned(): Promise<void> {
    const id = this.projectSheetId;
    const next = !this.projectSheetPinned;
    this.showSheet = false;
    this.projectMenuRowKey = '';
    const ok = await this.store.setProjectPinned(id, next);
    this.showNotice(ok ? (next ? '项目已置顶。' : '项目已取消置顶。') : '无法更新项目。');
  }

  private async archiveProjectSessions(): Promise<void> {
    const id = this.projectSheetId;
    const name = this.projectSheetName;
    this.showSheet = false;
    this.projectMenuRowKey = '';
    this.projectArchiveConfirm = false;
    const ok = await this.store.archiveAllForProject(id, true);
    this.showNotice(ok ? `项目「${name}」的会话已归档。` : '无法归档项目会话。');
  }

  private async saveProjectName(): Promise<void> {
    const id = this.projectSheetId;
    const value = this.projectRenameValue.trim();
    if (value.length === 0) {
      this.projectEditError = '项目名称不能为空。';
      return;
    }
    if (value === this.projectSheetName) {
      this.projectEditError = '名称没有变化。';
      return;
    }
    this.projectEditBusy = true;
    this.projectEditError = '';
    const ok = await this.store.renameProject(id, value);
    this.projectEditBusy = false;
    if (ok) {
      this.showSheet = false;
      this.showNotice('项目已更新。');
    } else {
      this.projectEditError = '无法更新项目。';
    }
  }

  // -------------------------------------------------------------------------
  // 分页（进行中 / 已归档两侧共用一套状态选择）
  // -------------------------------------------------------------------------

  /** 当前筛选档下「加载更多」应该翻哪一侧（`all` 档以活跃侧为准，见 HomeGrouping 的说明）。 */
  private pagingSide(): boolean {
    return pagingSideIsArchived(this.filter);
  }

  private showLoadMoreFooter(): boolean {
    return this.pagingSide() ? this.archivedShowLoadMore : this.activeShowLoadMore;
  }

  private loadingMoreFooter(): boolean {
    return this.pagingSide() ? this.archivedLoadingMore : this.activeLoadingMore;
  }

  private pageErrorFooter(): string {
    return this.pagingSide() ? this.archivedPageError : this.activePageError;
  }

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  /**
   * ForEach 的 key 必须能**区分不同筛选档**，也必须**随项目内会话内容变化**。
   *
   * 两个真机实测的坑（都属于「key 不变 → 组件复用 → 不重建」）：
   *  ① 原来用 `${projectId}:${sessions.length}`：同一个项目下两个列表的会话数恰好都是 2 时 key 完全相同，
   *  切到「已归档」只换了按钮高亮，列表还是「进行中」那两条；
   *  ② 只带上会话 id 时：重命名一个会话后服务端已经改了标题，但组内 id 集合没变 → 组不重建 →
   *  `projectRow()` 这个「值参数 @Builder」不重跑 → 内层 ForEach 更不会被求值 → 列表还显示旧标题。
   */
  private rowKey(row: ProjectRow): string {
    let members = '';
    for (let i = 0; i < row.sessions.length; i++) {
      const session = row.sessions[i];
      members += `${session.id}:${session.title}:${session.status}:${session.updatedSeq}:`
        + `${session.pinned}:${session.archived}:${session.updatedAtLabel}:${session.indicator},`;
    }
    return `${row.projectId}:${this.filter}:${row.expanded}:${row.name}:${row.sessionCount}:${members}`;
  }

  /**
   * 会话行 key。
   *
   * ⚠️ R38（lead 裁决 U5：**正确性优先**）补了三个「会变但原来不在 key 里」的字段：
   *  `updatedAtLabel`（相对时间，每次映射都按当前时间重算 ⇒ 不补就永远停在 `now`）、
   *  `indicator`（行首/行尾的状态点 ⇒ 不补则未读变已读后点不消失）、
   *  `metaLabel`（Runtime / 设备名 / 工作区 ⇒ 不补则设备重命名后行内 meta 不更新）。
   *  ⚠️ 与 `坑 152②` 的分工：**会变的数据字段进 key**；`@State` 标记（弹窗开关、当前会话）
   *  仍然走行内判等，绝不进 key。
   */
  private sessionKey(session: AgentSession): string {
    return `${session.id}:${session.title}:${session.status}:${session.updatedSeq}:${session.pinned}:`
      + `${session.archived}:${session.updatedAtLabel}:${session.indicator}:${session.metaLabel}`;
  }

  build() {
    // ## R58：顶栏（含快捷入口带）从「流式占位行」改为**浮层** —— 首页侧根因
    //
    // 改前（Lead 真机 + 本轮逐像素复核确认）：`header()` 是外层 `Column` 的第一个子节点，
    // 占**自己的一行高度**（y 137~273），列表在它下方的 `Column(layoutWeight 1)` 里 ⇒
    // **滚动内容物理上到不了顶栏背后**。真机三帧（滚动 400px × 2）在顶栏 ROI 上
    // `changed(>0) = 0.00%`、`max|d| = 0` —— **逐字节相同**，而列表区同时有 13.45% 像素在变。
    // ⇒ 顶栏 `backgroundEffect` 底下永远是一块纯色 `canvas()`，**任何参数都不可能糊出液态效果**。
    //
    // 改后（与 `SessionDetailScreen.ets` 同构，坑 217 的正解）：
    //  ① 内容层 = 列表铺满整屏（**视口从屏幕顶开始**）⇒ 内容必然从顶栏背后穿过；
    //  ② 顶栏带 = 浮层（顶栏 + 快捷入口 + 提示条），高度**实测**；
    //  ③ 列表头部让位用 `List.contentStartOffset`（**绝不用 padding**），值 = 实测浮层高。
    //
    // ⚠️ **为什么快捷入口也要进浮层**（而不是留在内容层）：只要它留在内容层里，列表视口就被
    //  它推到下面去了，内容照样到不了顶栏背后 —— 等于没改。浮层里的快捷卡是**不透明**的
    //  （`raisedSurface()`），所以视觉与改前逐像素同源；差异只出现在**卡片之间的 10vp 缝**里
    //  （改前露 `canvas()`，现在露滚动的正文）—— 这是「内容穿过」的必然代价，已如实记进报告。
    Stack({ alignContent: Alignment.BottomEnd }) {
      /**
       * ① **R62：内容层放进 `Navigation`**，顶栏行作它的**标题栏**（`barStyle: STACK`），
       * 从而拿到**官方**的标题栏滚动柔渐变（`scrollEffectOptions: GRADUAL_BLUR`）。
       *
       * ## 为什么必须放进 Navigation
       *
       * 官方 `scrollEffectOptions` **只跟踪 Navigation 自己的可滚动内容** ——
       * 这版 SDK 的 `Navigation` **没有** `bindToScrollable`（那是 Hds 专属），
       * 内容放在 Navigation 外就没有东西可跟。R61 探针实测：内容放进 Navigation 内
       * + `barStyle: STACK` + **手势**滚动时，`GRADUAL_BLUR` 会把标题栏背景糊成柔渐变
       * （amp 255 → 131.2、edge 255 → 24.2）；程序化 `Scroller.scrollTo()` **不触发**。
       * 证据：开发期验证记录 §5.4 / §10。
       *
       * ## 与 R61 那次失败尝试的区别（那次已回退，见 REPORT §11）
       *
       * R61 把**整条顶栏带**（顶栏 + 快捷卡 + 提示条，自然高 517px）塞进标题栏，
       * 而标题栏高度由框架控制（实测 `TitleBar` 195px、构造器被钳在 333px）⇒ 子节点溢出、
       * 让位量偏小、快捷卡压住列表首行。
       * **R62 的形态变了**：快捷入口已按用户要求**移到底部悬浮底栏**，提示条改为独立浮层，
       * 所以标题栏里**只剩顶栏一行**（自然高 136px）—— 能落进框架给的栏高。
       *
       * ⚠️ `systemMaterial`（沉浸光感材质）已在 R61 被逐像素证伪，**不要**再往这里挂。
       */
      Navigation() {
        // 内容层：列表铺满整屏。⚠️ 必须 `height('100%')` 且**顶部不留白** ——
        // 只要它比屏幕矮或往下推，内容就滚不到标题栏背后。
        Column() {
          /**
           * 下拉刷新：Lead 拍板用官方 `Refresh`（不自绘 Material3 `PullToRefreshBox`），视觉差异列为已知项。
           * 上游锚文 `HomeScreen.kt:494-510`。
           *
           * ⚠️ R58：让位量加在**真正的 List 上**（`projectViewList` / `sessionViewList`
           * 各自的链式末尾），**不是**加在 `Refresh` 上 —— `Refresh` 不持有 `contentStartOffset`。
           */
          Refresh({ refreshing: $$this.refreshing, builder: this.refreshArea() }) {
            this.listArea()
          }
          .layoutWeight(1)
          .width('100%')
          // ## R90（用户第一期：「加载圆圈位置不对，**应在标题栏下方**」；第二期：「我更看重**穿过**效果」）
          //
          // **实测事实**（真机 dumpLayout，慢速下拉 `velocity=200`）：默认指示器是
          // `LoadingProgress [610,137][706,220]` —— 顶边**就是 `Refresh` 的顶边 137px**，
          // 而标题栏是 `[0,137][1316,332]` ⇒ 圆圈正落在标题栏里（用户看到的就是这个）。
          //
          // **两条死路（都实测过，别再试）**：
          // · `.refreshOffset(…)` 只改**触发阈值**，刷新态指示器固定画在 `Refresh` 顶边 —— 改完位置**一字未变**；
          // · `.margin({ top })` 把整块 `Refresh` 下移能挪动圆圈 ✓，但**内容再也穿不过标题栏** ✗（用户不接受）。
          //
          // **第三条死路（R90 第一版，也实测过）**：把指示器画进 `builder` 自己 ——
          //  位置与去留**只有一半归我们管**（框架按自己的高度基数摆它；静止态高度不为 0 ⇒ 圆圈常驻、
          //  压在标题栏里，被用户读成"位置不对"+"加载不会结束"）。三轮实测见 `refreshArea()` 的注释。
          //
          // ⇒ **R90 现行方案（两条腿，都归我们管）**：
          //  ① `margin` 已撤销 ⇒ `Refresh` 回原位（`[53,137]`），内容重新从标题栏背后穿过；
          //  ② 指示器**移出 `Refresh`**、自绘在外层浮层（见下面的 ③）：位置读 `listTopOffsetVp()`
          //  （与列表首项**同值同源**）、去留由 `pullActive || refreshing` 决定。
          //  `Refresh` 里那个 `builder` 只留一个**空 `Column`** —— 它唯一的作用是让框架
          //  **不再创建默认指示器**（否则默认那个又画回 `Refresh` 顶边 137px＝标题栏里）。
          //  ⚠️ 让位**同步回到内容层**（错误条 / 空态 / 加载中 / 两条 `List`，与 R88 同源）——
          //  `Refresh` 既然不下移了，内容层的「第一行自己让位」这条规则就重新生效。
          .onRefreshing(() => {
            this.onRefresh();
          })
          // R90：下拉过程中也要有反馈 —— `refreshArea()` 是空的（默认指示器已被关掉），
          // 指示器改由外层浮层画 ⇒ 它得知道"手指正在下拉"。用**滞回布尔**，见 `pullActive` 的注释。
          .onOffsetChange((offset: number) => {
            if (offset <= 0) {
              if (this.pullActive) { this.pullActive = false; }
            } else if (offset >= PULL_SHOW_VP) {
              if (!this.pullActive) { this.pullActive = true; }
            }
          })
        }
        .width('100%')
        .height('100%')
        // 左右内边距与改前一致（原外层 Column 的那 18vp）；顶部**不给**内边距。
        .padding({ left: Space.PAGE, right: Space.PAGE })
      }
      // 标题栏 = 顶栏一行；`STACK` 让标题栏**叠在内容之上**（默认 `STANDARD` 会占掉一行，
      // 内容就再也穿不过去了）。
      // ## R90-T2（用户：「**模糊效果不好**，在真机上尝试恢复原先模糊效果」）
      //
      // ### 为什么 R90 之后模糊突然"不好看"了
      // R89 那版 `Refresh` 被 `.margin` 整体下移 ⇒ **内容压根不走标题栏背后** ⇒
      // 官方滚动遮罩没有东西可糊，观感是"干净透明"。R90 把 `margin` 撤销、**恢复了「穿过」**
      // ⇒ 正文真的从栏背后滚过去，那条滚动遮罩这才第一次"显形"。
      //
      // ### 那条遮罩为什么不好看（SDK 原文 + 真机 dump 双证）
      // · SDK 对 `GRADUAL_BLUR` 的定义是「applies uniform blur to the title background
      //  **with clear boundaries**」—— **clear boundaries = 硬边界**：
      //  真机截图 `modeA-deep.jpeg` 里栏内就是一片**带硬直底边**的灰糊带（底边压在 332px）。
      // · 更糟的是它的遮罩点：真机 dump 实测 `TitleBarMaskBlur [0,137][1316,428]` ——
      //  底边 **428px 越过标题栏底 332px 整整 96px**，把栏下那一条也一起洗掉
      // （即 `坑 249` 记的那条）；而 R90 的刷新指示器**恰好**落在
      //  `[610,332][706,427]` —— 正处在被洗掉的那 96px 里。
      //
      // ### 改法：换成**官方常驻** `backgroundEffect`（本工程 R77 已在本仓验证过的同款处置）
      // `NavigationTitleOptions.backgroundEffect`（SDK `navigation.d.ts:1745-1758`）：
      // 「Title bar background properties, including **blur radius, brightness, saturation, and color**」
      // · 由**框架自己**画在那条栏上 ⇒ **没有硬边界、没有越过栏底 96px 的遮罩点**；
      // · 它是**常开**的（不像滚动遮罩要等滚动）⇒ 静止时栏背后有内容也读得出来；
      // · 参数取本工程**同一套玻璃令牌**（`GLASS_BLUR_RADIUS` / `GLASS_SATURATION` /
      //  `GLASS_BRIGHTNESS` / `glassSurface()`）—— 也就是"原先那层玻璃"的配方。
      // ⚠️ 官方要求 `backgroundEffect` **不要**与 `backgroundBlurStyleOptions` 同用 ⇒ 本处只用前者。
      // ⚠️ 两者是**互斥的取舍**：`scrollEffectOptions`＝"滚起来才糊 + 硬边界"，
      //  `backgroundEffect`＝"一直糊 + 无边界"。既然要「穿过」，就选后者（R77 同一裁决）。
      .title(this.homeTitleBar(), {
        barStyle: BarStyle.STACK,
        // ⚠️ 底色必须**透明**：不透明背景会把标题栏自己的模糊层整个盖住。
        backgroundColor: Color.Transparent,
        backgroundEffect: {
          radius: GLASS_BLUR_RADIUS,
          saturation: GLASS_SATURATION,
          brightness: GLASS_BRIGHTNESS,
          color: glassSurface()
        }
      })
      .hideToolBar(true)
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
      // ⚠️ 本页是 `barStyle: BarStyle.STACK`（标题栏叠在内容上），让位量由 `listTopOffsetVp()` 的标定
      //  常量 `TITLE_BAR_VP`(66) 给 —— 该标定本来就是按 `TitleBar [0,137][1316,332]`（= Full/Free
      //  静止态）标定的 ⇒ 换成 Full 后**标定依旧成立**（真机复核点：列表首行 / 提示条浮层不被标题栏压住）。
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')

      // ② 提示条浮层（R62）：贴在**标题栏下沿**，让位量与列表用同一个 `listTopOffsetVp()`。
      //  ⚠️ 它原来是「顶栏带」的一部分；R62 顶栏带只剩标题栏里的一行，提示条必须单独成层。
      //  只在 `notice` 非空时挂载 ⇒ 常态下这一层根本不存在，不吃任何手势。
      //  ⚠️ 铺满型兄弟容器 ⇒ **必须** `hitTestBehavior(HitTestMode.None)`，
      //  否则它会把整屏的手势（列表拖拽 / 下拉刷新）全吃掉（坑 29 真机踩过）。
      if (this.notice.length > 0) {
        Column() {
          Column() {
            this.noticeBar()
          }
          .width('100%')
          .padding({ left: Space.PAGE, right: Space.PAGE })
          // 与 `List.contentStartOffset` 同源：都读实测的标题栏让位量，两者不会错位。
          .margin({ top: this.listTopOffsetVp() })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.None)
      }

      /**
       * ## ③ R90：**刷新指示器浮层** —— 与提示条同构，贴在标题栏下沿
       *
       * 为什么必须自绘（三轮实测，细节见 `refreshArea()` 的注释）：`Refresh` 自带指示器
       * **固定画在 `Refresh` 自己的顶边**（=`137px`，正落在标题栏里）；`.refreshOffset` 改不动它，
       * `.margin` 挪得动却会**废掉「内容穿过」**，把它画进 `builder` 又有**一半不归我们管**
       * （位置随框架高度基数浮动、且静止态常驻可见 ⇒ 用户读成"加载不会结束"）。
       *
       * ⇒ 指示器搬到 `Refresh` 外面自绘，**位置与去留全部由本页决定**：
       *  · 位置：`.margin({ top: this.listTopOffsetVp() })` —— 与列表首项**同值同源**，恒在标题栏下沿 333px；
       *  · 去留：`if (this.refreshing)` —— 只在刷新态挂载，`onRefresh()` 的 `try/finally` 一收尾就整体卸载。
       *
       * ⚠️ 与提示条同款：铺满型兄弟容器 ⇒ **必须 `hitTestBehavior(HitTestMode.None)`**，
       *  否则会把整屏手势（列表拖拽 / 下拉刷新）全吃掉（坑 29 真机踩过）。
       * ⚠️ 它**不是**手势层：`Refresh` 仍在原位、照常接收下拉（它的默认指示器由空的 `refreshArea()` 关掉）。
       */
      if (this.pullActive || this.refreshing) {
        Column() {
          Column() {
            LoadingProgress()
              .width(REFRESH_INDICATOR_VP)
              .height(REFRESH_INDICATOR_VP)
              .color(muted())
          }
          .width('100%')
          // 与列表首项同源：都读实测的标题栏让位量，两者不会错位。
          .margin({ top: this.listTopOffsetVp() })
        }
        .width('100%')
        // ⚠️⚠️ **必须 `height('100%')` + `justifyContent(Start)`**（与 ② 提示条浮层逐字同构）：
        //  根 `Stack` 是 `alignContent(Alignment.BottomEnd)`，**尺寸未铺满的兄弟节点会被摆到底部**——
        //  第一版漏了这两行，真机截图里圆圈落在**屏幕底部** `[610,2737][706,2832]`（被底栏挡着），
        //  而不是标题栏下方。铺满 + 顶部对齐后，内层 `margin.top` 才等价于"贴标题栏下沿"。
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.None)
      }

      /**
       * ③ 底栏**已上移到 `pages/Index.ets` 的浮层**（R66-3）：首页不再自己挂 `AaBottomNav`。
       *
       * ## 为什么必须上移（用户要的形态）
       * 用户给的应用市场截图里，底栏是**浮在内容之上**的半透明胶囊（背后图标/文字透视且被模糊）。
       * 挂在页面布局流里的胶囊做不到这一点：它会占掉列表底部一条布局空间，内容**穿不过去**；
       * 而官方材质本身是折射/模糊材质 —— 背后是均匀纯色时**它长得和背景一样**
       * （R65 那次「底栏 Δ+0.0」就是这么测出来的假阴性）。
       * 上移到根 `Stack`（`alignContent(Alignment.Bottom)`）后：① 浮层不占布局，内容从背后滚过去；
       * ② 官方 Tabs 那一路可以开 `.barOverlap(true)` 让内容从 bar 背后穿过。
       *
       * ⚠️ **本页仍是底栏自动收回的唯一驱动方**（写 `aaBottomBarHidden`，见本页的
       *  `syncBottomBarOnFirstIndex` / `setBottomBarHidden`），只是**画**在 Index 那一层。
       *  R73 条件集：下滑收回 / 上滑显示 / 回顶部显示 / 停手**不**自动复原 / 切页离页复位 / 抽屉开合。
       * ⚠️ 首页列表的尾部留白（`Space.HOME_LIST_BOTTOM`，96vp ≥ 胶囊总高）**保持不变** ——
       *  内容能滚到胶囊背后，但最后一行仍能完整滚进可视区。
       */

      /**
       * 设置抽屉 —— ⚠️ 必须是 Stack 的**最后一个子节点**（最上层），否则会被底栏之类的兄弟盖住。
       * 上游锚文：`ProfileSettingsDrawer.kt:150-153`（全屏左滑覆盖，无遮罩）。
       */
      SettingsDrawerPanel({
        open: this.settingsOpen,
        onClose: () => {
          this.closeSettingsDrawer();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(canvas())
    // R39 入场淡入：只做透明度（不做位移，理由见 `PAGE_ENTER_MS` 的注释）。
    // ⚠️ 视觉上是安全的：页面底色与根页 `immersiveBackground` 同色（都是 `canvas()`），
    //  所以淡入期间看到的是同色底，只有内容在浮现 —— 不会闪白/闪黑。
    // ⚠️ `.animation()` 挂在链式末尾 ⇒ 对前面的 width/height/backgroundColor/opacity 都生效；
    //  前三个在页面存活期间恒定，实际只有 opacity 会被补间。
    .opacity(this.entered ? 1 : 0)
    .animation({ duration: PAGE_ENTER_MS, curve: Curve.FastOutSlowIn })
    // ⚠️ 根节点**只有这一个** bindSheet；其余面板都是它的内容分支（EXPERIENCE §34）。
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: this.sheetHeight(),
      dragBar: true,
      // R37 六改：系统关闭按钮真机实测**点不动**（见 DeviceDetailScreen 的注释）⇒ 统一关掉。
      // 面板另有「下滑关闭 / 点面板外关闭」两个入口。
      showClose: false,
      // ## R86：半模态面板的**底**改由官方沉浸光感接管（本行是唯一变化，几何一字未动）
      // · 官方依据：`SheetOptions.systemMaterial`（SDK `common.d.ts:12155`，类型 `SystemUiMaterial`）。
      // · 生效范围：`bindSheet` 属**弹窗类接口** ⇒ 依官方「生效范围」在**页面内全部区域**生效
      // （`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0），
      //  不需要「`Navigation` 标题栏」那类位置前提。
      // · 档位取 `panelMaterial()`（THIN）：面板背后就是首页正文列表、面板内又是用户要读的动作行
      //  ⇒ 取薄档保可读性。
      // · 关闭姿势 = `uiMaterial.Material.empty`（= disable，SDK `uiMaterial.d.ts:467-472`），
      //  由 `panelMaterial()` 在探针不可用时**自己返回**（`immersiveMaterialEnabled()` 判 `state===1`）
      //  ⇒ 本处**不得**改传 `undefined`：官方语义里 `undefined` = 「恢复组件默认材质」，
      //  与「关闭」不是一回事（`common.d.ts:22632-22633` / `坑 256`）。
      // · 保留 `blurStyle`：官方只不建议材质与 `backgroundColor`/`borderColor`/`borderWidth`/`shadow`
      //  同用（`common.d.ts:22625-22630`），**未**禁止模糊；且材质不可用时它是本面板唯一的底
      //  （登记为本处回退路径）。回退 = 删掉下面这一行。
      systemMaterial: panelMaterial(),
      blurStyle: BlurStyle.Thin
    })
  }

  /** 弹层高度按内容给（面板内容差异大，统一高度会让短面板出现大片空白）。 */
  private sheetHeight(): number {
    if (this.sheetKind === SHEET_SESSION) {
      return 430;
    }
    if (this.sheetKind === SHEET_PROJECT) {
      // 项目「…」菜单已改就地弹窗（R13-9），这里只剩「归档确认」一段正文。
      return 300;
    }
    if (this.sheetKind === SHEET_PROJECT_EDIT) {
      return 470;
    }
    return 320;
  }

  @Builder
  sheetContent() {
    if (this.sheetKind === SHEET_SESSION) {
      this.sessionActions()
    } else if (this.sheetKind === SHEET_PROJECT) {
      this.projectArchiveSheet()
    } else if (this.sheetKind === SHEET_PROJECT_EDIT) {
      this.projectEditSheet()
    } else {
      Column() {
      }
    }
  }

  /**
   * 顶栏 `HomeHeader`（上游 `HomeScreen.kt:626-665`）：高 46、元素间距 12。
   *
   * ⚠️ 只用**一条 Row**的三槽排布，不要为了「字标绝对居中」改成 `Stack` 叠层 ——
   * 铺满的兄弟容器会吃掉整条顶栏的点击（坑 29 真机踩过：侧栏完全打不开）。
   */
  /**
   * 顶栏要自己避让的**状态栏高度**（vp）。
   *
   * ⚠️ R37 五改：顶部避让从 `pages/Index.ets` 的根节点下放到各页面顶栏 —— 根节点一 padding，
   * 页面内容就被推到状态栏之下，那一整条永远是纯色画布色，用户要的「系统状态栏那条和上方
   * 功能栏一样糊」就无从谈起。顶栏自己留出这段高度（内容避开状态栏），**背景铺到屏幕顶**。
   * 读的是 `EntryAbility` 实测写入的 `AppStorage` 值，不写死像素。
   */
  /**
   * 顶栏**不再自己避让状态栏**（R62 删除原 `topInset()` 方法，保留这条说明）。
   *
   * ⚠️ **为什么不避让（真机证据）**：`uitest dumpLayout` 两次证明**页面根节点已经在 `[0,137]`**
   *  —— 内容**已经**避让过状态栏；顶栏再加一次 `px2vp(SAFE_AREA_TOP_PX)`（≈46vp）就是
   *  **重复避让 137px**。而且它原本是 `AppStorage.get` 的**一次性非响应读取**，读到 `0` 还是
   *  `46vp` 取决于冷启动时序（R61 实测：同一份包两次冷启动，顶栏行高一次 136px、一次 274px）
   *  ⇒ 顶栏位置会随机跳 137px。R57 基线与此前所有真机验收都发生在「读到 0」的状态下
   *  （顶栏行实测 136px = 46vp），所以本页顶栏**固定按 0 避让 = 保持已验证的观感**。
   *
   * ⚠️ R37 原意是「顶栏背景铺到屏幕顶、状态栏那条也一起模糊」。该意图在当前页面根已避让状态栏的
   *  前提下**本来就不成立**（状态栏那条一直由 `pages/Index.ets` 的 `immersiveBackground` 铺纯色）。
   *  要真正实现得改根避让，而 R13-11/12/13 已三次证明「扩展安全区」那条 API 在百分比尺寸下会把容器
   *  一起扩掉 —— 属独立议题。
   *
   * ⚠️ **其余 12 个页面各自仍写着同名方法**（`DevicesScreen` / `FilesScreen` / `SettingsScreen` …），
   *  本轮**不动它们**：那是跨 13 个页面的横切改动，需要单独一轮带完整回归。
   */

  @Builder
  header() {
    Row({ space: Space.M }) {
      // 左：头像 → 打开设置抽屉（上游 `onProfile = { onProfileOpenChange(true) }`）。
      // 上游 `HomeScreen.kt:639` 是 `Lucide.UserRound`（21dp）—— 不是字母头像。
      // R57（T2b）：顶栏就是毛玻璃带（下面 `backgroundEffect`），钮改成**玻璃档**后
      // 与栏同一套材质语言（磨砂 + 亮边 + 镜面高光 + 外阴影）；几何（40 / 21）一个没动。
      AaCircleIconButton({
        name: 'user-round',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: 21,
        filled: true,
        glass: true,
        // R65-T1：全工程**唯一**位于 `Navigation` 标题栏内的功能钮 ⇒ 官方沉浸光感的 A/B 样本。
        officialMaterial: true,
        accessibilityLabel: '打开设置',
        onTap: () => {
          this.openSettingsDrawer();
        }
      })

      // 中：字标（上游 `AAWordmark.kt`：Caveat 手写体 + `FontWeight.Medium`，
      // 字号/行高由调用方给 —— `HomeScreen.kt:655` 传 31.sp / 40.sp，与本工程的 31 / 高度 40 一致）。
      Column() {
        Text('Agents Anywhere')
          .fontSize(FontSize.WORDMARK)
          .fontFamily(WORDMARK_FAMILY)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // 右：**新建对话**（R62 用户指定：把原来的搜索钮换成新建对话钮）。
      // ⚠️ R62：搜索入口按用户要求**取消**（原位置只弹「搜索功能即将推出。」toast）。
      // 图标沿用被移除的悬浮「+」的 `plus`（同一动作、同一符号，避免用户重新学）。
      // `filled: false`（原本无底色）在玻璃档下不参与 ——
      // 玻璃档**恒有玻璃盘**（参考图里每个功能钮都是可见的玻璃圆），否则钮在深色顶栏上看不见。
      AaCircleIconButton({
        name: 'plus',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: 24,
        filled: false,
        glass: true,
        // R65-T1：同左（官方材质 A/B 的第二个样本）。
        officialMaterial: true,
        accessibilityLabel: '新建对话',
        onTap: () => {
          Router.push(Route.NEW_CHAT);
        }
      })
    }
    .width('100%')
    // ⚠️ 顶栏是**全宽**的（R37 五改）：毛玻璃要铺到左右边缘，所以它不能待在下面那层
    // 带左右内边距的 `Column` 里（那样玻璃会左右各缺 18vp）。左右内边距改由顶栏自己给。
    .height(Control.HOME_HEADER)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    // ⚠️ **R62：这里原本是自绘 `backgroundEffect`（R58 起的「内容穿过」方案）—— 已移除。**
    //  用户选定「只做官方能画的那一点：滚动柔渐变」。官方 `scrollEffectOptions` 作用在
    //  **Navigation 标题栏自己的背景层**上；这里若再叠一层自绘模糊，官方那层会被压在下面、
    //  逐像素测不出贡献（R61 探针把「叠两层」明确列为必须避免的混淆）。
    //  ⇒ 顶栏的滚动模糊现在**唯一**由 `homeTitleBar()` / `.title(..., { scrollEffectOptions })` 供给。
    //  ⚠️ 回退自绘路线：把 `GLASS_BLUR_RADIUS` / `GLASS_SATURATION` / `GLASS_BRIGHTNESS` /
    //  `glassSurface()` 这四个引用加回来即可（import 与会话详情页同源）。
    // ⚠️ **这里不再实测 `headerHeight`**（R58 Lead 收口修正）：本行只是**浮层带里的第一条**，
    //  它的高度 ≠ 列表要让位的总高（浮层带还含快捷入口 + 提示条）。
    //  实测统一由**浮层带**那一层做（见 `build()` 里那段 `.onAreaChange`）。
    //  ⚠️ 曾经这里也写了一次 `headerHeight` ⇒ 两个 `onAreaChange` **互相覆盖**，
    //  `contentStartOffset` 在两个值之间跳、列表让位量不稳定。**只允许一个写入点。**
  }

  /**
   * **R62：首页标题栏** —— `Navigation` 的自定义标题栏，内容**只有顶栏一行**。
   *
   * ⚠️ 为什么只能放一行（R61 的失败教训，见 `material-probe-r61/REPORT.md` §11）：
   *  标题栏高度由**框架**控制（实测 `TitleBar` 195px、自定义构造器被钳在 333px），
   *  把整条带（自然高 517px）塞进去会让**子节点溢出**、让位量偏小。
   *  快捷入口已按用户要求移到底部悬浮底栏，所以这里只剩顶栏（自然高 136px），能落进栏高。
   *
   * ⚠️ **不要加 `.height('100%')`**：那会让构造器撑到框架给的**最大内容高**（实测 333px），
   *  而不是标题栏的**视觉高度**（实测 195px），实测反而多留 167px 空白。
   *  保持自然高度（顶栏一行 = 46vp），框架会把它在栏内**上下居中**。
   */
  @Builder
  homeTitleBar() {
    Column() {
      this.header()
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    // ⚠️ R62：**这里不再有 `onAreaChange` 实测**（R58 起那套在 `Navigation` 标题栏上算不对，
    //  见 `TITLE_BAR_VP` 注释里的两次实测记录）。让位量改由标定常量 `TITLE_BAR_VP` 供给。
  }

  /** 顶栏提示条（上游 `AAToast`：Snackbar，短暂显示后消失）。 */
  @Builder
  noticeBar() {
    if (this.notice.length > 0) {
      Row() {
        Text(this.notice)
          .fontSize(FontSize.SMALL)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.S })
      .borderRadius(Radius.M_PLUS)
      .backgroundColor(subtle())
    }
  }

  /**
   * 快捷入口 `QuickEntries`（上游 `HomeScreen.kt:667-752`）：三张等宽卡片，行高 76、间距 10。
   *
   * ⚠️ 图标是**矢量**的（R12 起有 `ui/Icon.ets`）：设备 = Monitor、终端 = SquareTerminal、
   *  文件 = Folder，尺寸 22dp，与上游 `HomeScreen.kt:681/687/693` 一致。
   *  （改前真机实测：'🖥' 是彩色 emoji、'>_' 两个字符被排成两行、'🗀' 没有翻盖斜线。）
   * ⚠️ 三张卡片曾是**顶层目的地的唯一入口**（设备 / 终端 / 文件）。
   *
   * ⚠️⚠️ **R62：本构造器已不再被 `build()` 挂载。** 用户要求把这三个入口**移到底部**
   *  做悬浮功能底栏（`ui/BottomNav.ets` 的 `AaBottomNav`，共四项：首页 / 设备 / 终端 / 文件）。
   *  代码**故意保留**：它带着上游 `HomeScreen.kt` 的锚文与图标/尺寸依据，
   *  将来若要回退成顶部卡片，把 `homeTitleBar()` 里换成 `this.header()` + `quickEntries()` 即可。
   *  ⚠️ 保留也意味着 `Control.QUICK_ROW` / `homeSection` 之类常量仍被引用，不会变成死令牌。
   */
  @Builder
  quickEntries() {
    Row({ space: Space.S_PLUS }) {
      Column() {
        this.quickEntryCard('设备', 'monitor', Route.DEVICES)
      }
      .layoutWeight(1)
      .height('100%')

      Column() {
        // 上游 `HomeScreen.kt:687` 是 `Lucide.Terminal`（无外框的 `>_`），不是 `SquareTerminal`；
        // 真机对照：安卓墨迹 49×43，本工程改前用 square-terminal 是 55×55（多了一圈方框）。
        this.quickEntryCard('终端', 'terminal', Route.TERMINAL)
      }
      .layoutWeight(1)
      .height('100%')

      Column() {
        this.quickEntryCard('文件', 'folder', Route.FILES)
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height(Control.QUICK_ROW)
  }

  /**
   * 一张快捷卡片（上游 `QuickEntryCard`，`HomeScreen.kt:700-752`）。
   *
   * ⚠️ 值参数 `label` / `icon` / `target` 都是常量、永不变化 —— 值参数 @Builder 的
   * 「停在首建快照」问题只对**会变的数据**成立（EXPERIENCE §16），这里不受影响。
   */
  @Builder
  quickEntryCard(label: string, name: string, target: string) {
    Column({ space: Space.XS_PLUS }) {
      // 上游 `HomeScreen.kt:740` 的图标色是组件内联值 `#8E8E8E`（深 `#9A9A9A`），
      // 既不是 `faint`(#AAA8A2) 也不是 `muted`(#777777) —— 单独一个资源色（`icon_muted`）。
      // 图标边长 = `HomeScreen.kt:741` 的 `Modifier.size(22.dp)`，即 `FontSize.ICON_XL`。
      // R39：这条锚文原本写在已删除的 `AaQuickEntryCard` 里，删组件时迁到这里，别丢。
      AaIcon({ d: ICONS[name], iconSize: FontSize.ICON_XL, color: $r('app.color.icon_muted') })
      Text(label)
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding({ left: Space.M, right: Space.M, top: Space.M_PLUS, bottom: Space.M_PLUS })
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .onClick(() => {
      Router.push(target);
    })
  }

  // -------------------------------------------------------------------------
  // 列表区（项目视图 / 会话视图 / 空态 / 加载中）
  // -------------------------------------------------------------------------

  /**
   * ## R90：自绘刷新区 —— **故意留空**，唯一作用是「让框架不要再画它自己的指示器」
   *
   * ### 三轮实测把三条路都走死了（全记在这里，别再试）
   * · `.refreshOffset(…)` 只改**触发阈值** ⇒ 指示器位置**一字未变**（R89 实测）。
   * · `.margin({ top })` 能把默认指示器挪到标题栏下方 ✓，但**内容再也穿不过标题栏** ✗（用户不接受）。
   * · **把指示器画进 `builder`**（R90 前两版）：位置与去留有一半**不归我们管** ——
   *  · v1 `if (this.refreshing) { LoadingProgress() }` ⇒ 真机 dump **根本找不到该节点**
   * （`builder` 内容建一次快照，`if` 分支不随外部状态重建，坑 38 同源）；
   *  · v2 无条件挂载 ⇒ 节点有了，但**静止态常驻可见**：真机实测刷新区静止态高 `95px`、
   *  指示器落在 `[610,196][706,291]`（圆心 243px）—— **整个压在标题栏（137..332）里**，
   *  用户当场指出"位置不对"，而"永不消失"被读成"**加载不会结束**"。
   *  根因是框架把「内容高」当高度基数：**静止态高度不为 0**（下限 ≈ 32vp），
   *  圆心恒为 `(H + padding.top)/2`，压根不会自己归零；
   *  · 想让它归到 333px 得让让位量 = 状态栏+标题栏 = 112vp，而 `builder` 建快照时读
   *  `@StorageLink(SAFE_AREA_TOP_PX)` 会取到**旧值 0**（实测：内容层首项 332px vs 自绘区只让出 196px，
   *  差的正是状态栏那 46vp）⇒ 让位量在 builder 里**不可靠**。
   * ⇒ 结论：**只要指示器挂在 `Refresh` 里面，位置和去留就都有一半不归我们管。**
   *
   * ### ✅ 现行方案
   * 本 builder **画一个空的 `Column`**：它存在的唯一作用，是让框架走「自定义刷新区域」这条路
   * （`InitChildNode` 见到 `isCustomBuilderExist_` 就**不再创建默认指示器**），
   * 而指示器本体搬到 `Refresh` **外面**的浮层里自绘（见 `build()` 的 ③ 刷新指示器浮层）：
   *  · 位置 = `.margin({ top: this.listTopOffsetVp() })` —— 与列表首项**同值同源**，恒在标题栏下沿；
   *  · 去留 = `if (this.refreshing)` —— 只在我们显式置位时存在，`onRefresh()` 的 `try/finally`
   *  一收尾就整体卸载（**不存在"停不下来"的可能**：它不是常驻的，是被状态挂载的）。
   *
   * ⚠️ 空 `Column` 还顺带保证了两件事：
   * ① 高度基数 = 0 ⇒ 内容区仍从 `Refresh` 顶边起算（与不加 builder 时**逐像素同构**，「穿过」不受影响）；
   * ② 没有 `backgroundColor` ⇒ 它盖不住任何东西（自绘区会盖住 `Refresh` 顶边以下一条）。
   * ⚠️ 三条老禁令继续有效：**不写死 `height`**、**不写 `position`**（SDK：会把下拉位移钉死）、**不写 `backgroundColor`**。
   */
  @Builder
  refreshArea() {
    Column() {
    }
    .width('100%')
  }
  @Builder
  listArea() {
    Column() {
      // ## R88 → R89（`margin` 版）**→ R90（回到内容层让位）**
      // R89 用「`Refresh` 整体下移」换掉了内容层的三处让位；R90 撤销那次下移（为了「穿过」），
      // ⇒ **让位必须回到内容层**：错误条 / 空态 / 加载中就是内容流的第一行，它们自己不让位就会
      //  压住状态栏（0..137px）与标题栏（137..332px）—— 这正是 R88 修过的缺陷，别让它复发。
      if (this.effectiveError().length > 0) {
        Column() {
          AaErrorBanner({
            message: this.effectiveError(),
            onRetry: () => {
              this.store.refreshAll();
            },
            onDismiss: () => {
              this.store.error = '';
              this.error = '';
            }
          })
        }
        .width('100%')
        // ⚠️ R90：错误条自己让位（内容第一行）；下面的空态 / 加载中**不再重复让位**。
        .padding({ top: this.listTopOffsetVp() })
      }

      if (this.loading && !this.hasAnyRow()) {
        Column() {
          LoadingProgress().width(28).height(28).color(muted())
        }
        .width('100%')
        // ⚠️ 无错误条时**这三块就是内容第一行** ⇒ 由它让位（有错误条时错误条已让过，不重复）。
        .padding({ top: this.contentTopOffsetVp() })
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (!this.hasAnyRow()) {
        Column() {
          AaEmptyState({
            title: this.isSessionView()
              ? (this.filter === ProjectSessionFilter.ARCHIVED ? '没有已归档会话' : '还没有会话')
              : (this.filter === ProjectSessionFilter.ARCHIVED ? '还没有已归档的项目会话' : '还没有项目'),
            message: this.filter === ProjectSessionFilter.ARCHIVED
              ? '归档后的会话会出现在这里。'
              : (this.isSessionView()
                ? '先配对设备，然后就可以在设备上启动会话。'
                : '还没有项目。准备好后创建一个吧。'),
            actionLabel: this.filter === ProjectSessionFilter.ARCHIVED ? '看全部' : '配对新设备',
            onAction: () => {
              if (this.filter === ProjectSessionFilter.ARCHIVED) {
                this.applyFilter(ProjectSessionFilter.ALL);
              } else {
                Router.push(Route.ADD_DEVICE);
              }
            }
          })
        }
        .width('100%')
        // ⚠️ R90：与上面的加载中同款 —— 它是这一支的内容第一行。
        .padding({ top: this.contentTopOffsetVp() })
        .layoutWeight(1)
      } else if (this.isSessionView()) {
        this.sessionViewList()
      } else {
        this.projectViewList()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 项目视图（上游 `HomeProjectModeList` → `HomeProjectList`）：置顶区 + 「项目 ▼」分组。
   * ⚠️ 无值参数的 @Builder，列表项全部读 `this` 上的 @State。
   */
  @Builder
  projectViewList() {
    List() {
      // 置顶区（上游 `home_pinned`）：置顶项目 + 置顶会话，只在有内容时才出现。
      if (this.pinnedRows.length > 0 || this.pinnedSessionRows.length > 0) {
        ListItem() {
          Row({ space: Space.XS_PLUS }) {
            Text('置顶')
              .fontSize(FontSize.SECTION)
              .fontWeight(FontWeight.Bold)
              .fontColor(faint())
              .layoutWeight(1)
            // 上游 `HomeProjectComponents.kt:403`：ChevronDown 16dp，收起时 rotationZ = -90（= ChevronRight）。
            AaIcon({ d: this.pinnedExpanded ? ICONS['chevron-down'] : ICONS['chevron-right'], iconSize: 16, color: faint() })
          }
          .width('100%')
          .height(Control.SECTION_HEADER)
          .onClick(() => {
            this.pinnedExpanded = !this.pinnedExpanded;
          })
        }
        if (this.pinnedExpanded) {
          ForEach(this.pinnedRows, (row: ProjectRow) => {
            ListItem() {
              this.projectRow(row)
            }
          }, (row: ProjectRow) => `pin-project:${this.rowKey(row)}`)
          ForEach(this.pinnedSessionRows, (session: AgentSession) => {
            ListItem() {
              // 项目视图的置顶会话：上游用的是 `HomeProjectSessionRow(inset = false)`（44dp、无下划线），
              // 不是会话视图那条 66dp 的 `HomePinnedSessionRow`。
              this.projectSessionRow(session, false)
            }
          }, (session: AgentSession) => `pin-session:${this.sessionKey(session)}`)
        }
      }

      // 「项目 ▼」分组头 + 右侧「…」（会话状态筛选）+「+」（新建项目）。
      ListItem() {
        // ⚠️ 外层 Row **不给 space**：上游 `HomeProjectComponents.kt:377 HomeListSectionHeader` 的外层 Row
        // 没有 horizontalArrangement（只有内层标题 Row 是 spacedBy(6)）⇒「…」与「＋」两个 38dp 按钮**紧邻**。
        // 差这 6dp 就会让会话状态弹窗整体左移 18px（安卓 dump：菜单 [298,1149]，右边缘 1149px 正是「…」右边缘）。
        Row() {
          Row({ space: Space.XS_PLUS }) {
            Text('项目')
              .fontSize(FontSize.SECTION)
              .fontWeight(FontWeight.Bold)
              .fontColor(faint())
            AaIcon({ d: this.projectsExpanded ? ICONS['chevron-down'] : ICONS['chevron-right'], iconSize: 16, color: faint() })
          }
          .layoutWeight(1)
          .height(Control.SECTION_HEADER)
          .onClick(() => {
            this.toggleProjectsSection();
          })
          Column() {
            AaIcon({ d: ICONS['ellipsis'], iconSize: 19, color: faint() })
          }
          .width(Control.ICON_BUTTON)
          .height(Control.ICON_BUTTON)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(Radius.PILL)
          .onClick(() => {
            this.filterMenuOpen = !this.filterMenuOpen;
          })
          // 就地弹窗（R13-9 F-6）：贴「…」按钮右下角，无全页遮罩。
          // 两处分组头（项目视图 / 会话视图）共用这一个开关 —— 两个列表由 `isSessionView()` 二选一渲染，
          // 同一时刻只存在一个锚点，所以不会「一开弹两个」。
          .bindPopup(this.filterMenuOpen, this.filterMenuPopupOptions())
          Column() {
            AaIcon({ d: ICONS['plus'], iconSize: 19, color: faint() })
          }
          .width(Control.ICON_BUTTON)
          .height(Control.ICON_BUTTON)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(Radius.PILL)
          .onClick(() => {
            // 上游 `onCreateProject`：先展开「项目」分组，再 navigate 到 NewProject（独立目的地）。
            this.toggleProjectsSectionIfCollapsed();
            Router.push(Route.NEW_PROJECT);
          })
        }
        .width('100%')
        .height(Control.SECTION_HEADER)
      }

      if (this.projectsExpanded) {
        if (this.regularRows.length === 0) {
          ListItem() {
            Row() {
              Text('暂无项目。')
                .fontSize(FontSize.BODY_SMALL)
                .fontColor(faint())
            }
            .width('100%')
            .height(72)
            .justifyContent(FlexAlign.Center)
          }
        } else {
          ForEach(this.regularRows, (row: ProjectRow) => {
            ListItem() {
              this.projectRow(row)
            }
          }, (row: ProjectRow) => this.rowKey(row))
        }
      }

      // 列表底部「加载更多」：还有更多时显示、加载中禁用、失败可重试。
      if (this.showLoadMoreFooter()) {
        ListItem() {
          this.loadMoreFooter()
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    // 尾部留白：避开右下悬浮按钮，见 `Space.HOME_LIST_BOTTOM` 的注释。
    // ⚠️ R37（真机 + 用户投诉「底部内容显示不完全」）：**必须用 `contentEndOffset`，不能用 `.padding()`**。
    // `List` 的 `.padding({bottom})` 是**容器内边距** ⇒ 可视区高度被压掉 96dp，
    // 于是**最后 96dp 的内容永远滚不进可视区**（末项被硬裁断）。
    // 上游是 `contentPadding = PaddingValues(bottom = 96.dp)`（**内容**内边距，可视区不变）——
    // ArkUI 的等价物就是 `contentEndOffset`（只给内容末尾加偏移）。
    .contentEndOffset(Space.HOME_LIST_BOTTOM)
    // R58：**头部**让位给顶栏浮层（内容从顶栏玻璃背后穿过）。
    // ⚠️ 让位量与**会话详情页**（`contentStartOffset(this.headerHeight + Space.S)`）不再是同一套写法：
    //  那边顶栏是自绘浮层、可 `onAreaChange` 实测；这边是**框架控制高度**的 `Navigation` 标题栏，
    //  反算会错（见 `listTopOffsetVp()` 的标定记录）。
    // ⚠️ 必须是 `contentStartOffset`，**不能用 `.padding({top})`** —— padding 是容器内边距，
    //  会把内容裁在留白区之外、永远穿不过去（坑 217）。
    // ⚠️ R90：`contentStartOffset` 的标题栏让位**已恢复**（R89 曾随 `Refresh` 的 `margin` 一起撤销）。
    // `Refresh` 回原位后内容从 y=0 起滚（这正是「穿过」要的），所以**首项必须自己让位**，
    // 走 `contentTopOffsetVp()`（有错误条时返回 0，不重复让位 —— 与 R88 同源）。
    .contentStartOffset(this.contentTopOffsetVp())
    // R66-3：底栏**自动收回**的信号源（本页是全工程唯一写入 `aaBottomBarHidden` 的地方）。
    // ⚠️ 判据用 `onScrollIndex` 的 start/end（**绝对语义**：首/末可见项下标），不用
    //  `onDidScroll` 的 offset（其语义是「累计偏移」还是「逐帧增量」随版本/实现有歧义）。
    .onScrollIndex((start: number, end: number) => {
      this.syncBottomBarOnFirstIndex(start, end, 'project');
    })
    .scrollBar(BarState.Off)
  }

  /** 会话视图（上游 `HomeLists.kt` 的 `SessionList`）：「置顶」区 +「最近」区，都可折叠。 */
  @Builder
  sessionViewList() {
    List() {
      ListItem() {
        Row({ space: Space.XS_PLUS }) {
          Text('置顶')
            .fontSize(FontSize.SECTION)
            .fontWeight(FontWeight.Bold)
            .fontColor(faint())
            .layoutWeight(1)
          // 上游 `HomeProjectComponents.kt:403`：ChevronDown 16dp，收起时 rotationZ = -90（= ChevronRight）。
          AaIcon({ d: this.pinnedExpanded ? ICONS['chevron-down'] : ICONS['chevron-right'], iconSize: 16, color: faint() })
        }
        .width('100%')
        .height(Control.SECTION_HEADER)
        .onClick(() => {
          this.pinnedExpanded = !this.pinnedExpanded;
        })
      }
      if (this.pinnedExpanded) {
        if (this.pinnedSessionRows.length === 0) {
          ListItem() {
            Row() {
              Text('没有置顶会话。')
                .fontSize(FontSize.BODY_SMALL)
                .fontColor(faint())
            }
            .width('100%')
            .height(Control.ROW)
            .justifyContent(FlexAlign.Center)
          }
        } else {
          ForEach(this.pinnedSessionRows, (session: AgentSession) => {
            ListItem() {
              this.pinnedSessionRow(session)
            }
          }, (session: AgentSession) => `view-pin:${this.sessionKey(session)}`)
        }
      }

      ListItem() {
        Row({ space: Space.XS_PLUS }) {
          Row({ space: Space.XS_PLUS }) {
            Text('最近')
              .fontSize(FontSize.SECTION)
              .fontWeight(FontWeight.Bold)
              .fontColor(faint())
            AaIcon({ d: this.recentExpanded ? ICONS['chevron-down'] : ICONS['chevron-right'], iconSize: 16, color: faint() })
          }
          .layoutWeight(1)
          .height(Control.SECTION_HEADER)
          .onClick(() => {
            this.recentExpanded = !this.recentExpanded;
          })
          Column() {
            AaIcon({ d: ICONS['ellipsis'], iconSize: 19, color: faint() })
          }
          .width(Control.ICON_BUTTON)
          .height(Control.ICON_BUTTON)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(Radius.PILL)
          .onClick(() => {
            this.filterMenuOpen = !this.filterMenuOpen;
          })
          // 就地弹窗（R13-9 F-6）：贴「…」按钮右下角，无全页遮罩。
          // 两处分组头（项目视图 / 会话视图）共用这一个开关 —— 两个列表由 `isSessionView()` 二选一渲染，
          // 同一时刻只存在一个锚点，所以不会「一开弹两个」。
          .bindPopup(this.filterMenuOpen, this.filterMenuPopupOptions())
        }
        .width('100%')
        .height(Control.SECTION_HEADER)
      }
      if (this.recentExpanded) {
        if (this.recentRows.length === 0) {
          ListItem() {
            Row() {
              Text('没有最近会话。')
                .fontSize(FontSize.BODY_SMALL)
                .fontColor(faint())
            }
            .width('100%')
            .height(Control.ROW)
            .justifyContent(FlexAlign.Center)
          }
        } else {
          ForEach(this.recentRows, (session: AgentSession) => {
            ListItem() {
              this.recentSessionRow(session)
            }
          }, (session: AgentSession) => `view-recent:${this.sessionKey(session)}`)
        }
      }

      if (this.showLoadMoreFooter()) {
        ListItem() {
          this.loadMoreFooter()
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    // 尾部留白：避开右下悬浮按钮，见 `Space.HOME_LIST_BOTTOM` 的注释。
    // ⚠️ R37（真机 + 用户投诉「底部内容显示不完全」）：**必须用 `contentEndOffset`，不能用 `.padding()`**。
    // `List` 的 `.padding({bottom})` 是**容器内边距** ⇒ 可视区高度被压掉 96dp，
    // 于是**最后 96dp 的内容永远滚不进可视区**（末项被硬裁断）。
    // 上游是 `contentPadding = PaddingValues(bottom = 96.dp)`（**内容**内边距，可视区不变）——
    // ArkUI 的等价物就是 `contentEndOffset`（只给内容末尾加偏移）。
    .contentEndOffset(Space.HOME_LIST_BOTTOM)
    // R58：头部让位给顶栏浮层（同上，用法见 `projectViewList` 的注释）。
    // ⚠️ R90：`contentStartOffset` 的标题栏让位**已恢复**（R89 曾随 `Refresh` 的 `margin` 一起撤销）。
    // `Refresh` 回原位后内容从 y=0 起滚（这正是「穿过」要的），所以**首项必须自己让位**，
    // 走 `contentTopOffsetVp()`（有错误条时返回 0，不重复让位 —— 与 R88 同源）。
    .contentStartOffset(this.contentTopOffsetVp())
    // R66-3：底栏**自动收回**的信号源（本页是全工程唯一写入 `aaBottomBarHidden` 的地方）。
    // ⚠️ 判据用 `onScrollIndex` 的 start/end（**绝对语义**：首/末可见项下标），不用
    //  `onDidScroll` 的 offset（其语义是「累计偏移」还是「逐帧增量」随版本/实现有歧义）。
    .onScrollIndex((start: number, end: number) => {
      this.syncBottomBarOnFirstIndex(start, end, 'session');
    })
    .scrollBar(BarState.Off)
  }

  /**
   * 置顶会话行（上游 `HomePinnedSessionRow`，高 66dp、双行）：标题 16sp Bold + 副标题 11.2sp。
   * ⚠️ 值参数 @Builder：靠外层 ForEach 的 key 带内容来保证重建（EXPERIENCE §16）。
   */
  @Builder
  pinnedSessionRow(session: AgentSession) {
    Column() {
      Row({ space: Space.M }) {
        this.rowLeading(session)
        Column({ space: Space.XXS }) {
          Text(session.title)
            .fontSize(FontSize.ROW_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(inkSoft())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(session.metaLabel)
            .fontSize(FontSize.SUBTITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(faint())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.rowTrailing(session)
      }
      .width('100%')
      .height(Control.ROW_TALL)
      // R39：官方按压态。本行链式**没有**底色（上游语义：列表行静止态透明）⇒ `normal` 给透明。
      // ⚠️ 一个状态**只写一个**链式属性：多属性用逗号会报「An object literal cannot have multiple
      //  properties with the same name」+「.stateStyles doesn't conform standard」（坑 227）。
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        pressed: { .backgroundColor(rowPressedSurface()) }
      })
      .onClick(() => {
        Router.push(Route.SESSION, session.id);
      })
      // ⚠️ B-3：本行同时有 `onClick` 与 `LongPressGesture` —— 长按弹菜单后**抬手必须恢复常态底色**，
      //  这是批 B 最容易出的 bug（pressed 与长按态叠加）。判据见 REPORT-batchB §3；
      //  若实测卡住，回退方案：撤掉本行 stateStyles，或改 `onTouch` 手动管理两态。
      .gesture(
        LongPressGesture()
          .onAction(() => {
            this.openActions(session);
          })
      )
      // 行下划：上游 `HomeLists.kt:667` 是组件内联值 `#E9E8E5`（深 `#27272A`），
      // 与卡片边框的 `border`(#E7E5E0) 不是同一个色 —— 走 `row_divider`。
      Divider().color($r('app.color.row_divider')).strokeWidth(StrokeWidth.HAIRLINE)
    }
    .width('100%')
  }

  /**
   * 项目展开后的会话子行（上游 `ui/screens/home/HomeProjectSessionRow.kt:32`）。
   *
   * ⚠️ 与「最近」那条（`HomeRecentSessionRow`，52dp + 行下划线）**不是同一个组件**：
   *  这里是 **44dp**、**没有行下划线**、用 **34dp 左缩进**代替行首图标列（上游 `padding(start = 34.dp)`）；
   *  项目视图「置顶」区用的是同一组件但 `inset = false`（不给缩进）。
   *  标题 15sp Medium（上游 `fontSize = 15.sp` + `FontWeight.Medium`）。
   * 本工程保留行尾可见的「⋯」（上游只有长按，见 `rowTrailing` 的注释）—— 既有取舍，未变。
   */
  @Builder
  projectSessionRow(session: AgentSession, inset: boolean) {
    Row({ space: Space.S_PLUS }) {
      Text(session.title)
        .fontSize(FontSize.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.rowTrailing(session)
    }
    .width('100%')
    .height(Control.ROW_PROJECT_SESSION)
    .padding({ left: inset ? Control.PROJECT_SESSION_INSET : 0, right: Space.S_PLUS })
    // R39：官方按压态（本行无底色 ⇒ `normal` 透明）。见 `pinnedSessionRow` 的同款注释（坑 227 单属性约束）。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      Router.push(Route.SESSION, session.id);
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.openActions(session);
        })
    )
  }
  /** 最近会话行（上游 `HomeRecentSessionRow`，高 52dp、单行）。 */
  @Builder
  recentSessionRow(session: AgentSession) {
    Column() {
      Row({ space: Space.M }) {
        this.rowLeading(session)
        Text(session.title)
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(inkSoft())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.rowTrailing(session)
      }
      .width('100%')
      .height(Control.ROW)
      // R39：官方按压态（本行无底色 ⇒ `normal` 透明）；B-3 长按交互见 `pinnedSessionRow` 的同款注释。
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        pressed: { .backgroundColor(rowPressedSurface()) }
      })
      .onClick(() => {
        Router.push(Route.SESSION, session.id);
      })
      .gesture(
        LongPressGesture()
          .onAction(() => {
            this.openActions(session);
          })
      )
      Divider().color($r('app.color.row_divider')).strokeWidth(StrokeWidth.HAIRLINE)
    }
    .width('100%')
  }

  /**
   * 行首槽（上游 `SessionRowLeading`）：固定 20dp；有状态时画 8dp 状态点，否则一个淡色列表图标。
   */
  @Builder
  rowLeading(session: AgentSession) {
    Row() {
      // 上游 `HomeLists.kt:519` 的 `SessionRowLeading`：
      //  Busy / Unread → 状态点
      //  WaitingApproval / None → Lucide.ListIcon 14dp
      // ⚠️ 改前 WaitingApproval 在**行首也画一个状态点**，而行尾
      //  （对应上游 `SessionRowTrailing`，`HomeLists.kt:527`）已经有一个同色的点 ——
      //  一行里两个点，这也是「图标重复」的一个来源。现按上游对齐。
      if (this.leadingShowsDot(session)) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.indicatorColor(session))
      } else {
        AaIcon({ d: ICONS['list'], iconSize: 14, color: faint() })
      }
    }
    .width(Control.ROW_LEADING)
    .justifyContent(FlexAlign.Start)
  }

  /** 行首是否画状态点（对齐上游 `SessionRowLeading` 的 when 分支）。 */
  private leadingShowsDot(session: AgentSession): boolean {
    return session.indicator === SessionListIndicator.Busy
      || session.indicator === SessionListIndicator.Unread;
  }

  /**
   * 行尾（上游 `SessionRowTrailing`）：时间 10.8sp；等待审批时改为状态点。
   * 比上游多一个可见的「⋯」入口 —— 上游只支持长按出菜单，而真机上合成长按不可靠、
   * 用户也发现不了（本工程第三轮的教训），长按保留、另给看得见的按钮。
   */
  @Builder
  rowTrailing(session: AgentSession) {
    Row({ space: Space.S }) {
      if (session.indicator === SessionListIndicator.WaitingApproval) {
        // 待审批：警示点（保留 —— 那是一个**需要用户动作**的状态，比转圈更该被看见）
        Circle()
          .width(8)
          .height(8)
          .fill($r('app.color.notice_warning'))
      } else if (session.indicator === SessionListIndicator.Busy) {
        // ⚠️ R37 八改（用户要求「活跃的会话把 now 改为加载的圆圈，这样能知道会话的状态」）：
        // **活跃会话（Busy = running / waiting / pending）显示转圈**，不再显示相对时间。
        // 颜色与行首那个 Busy 状态点同源（`statusColor('running')`），一处状态两处同色。
        // 说明：用户举的例子是「now」，但活跃会话跑上几分钟后时间会变成 `5m` ——
        // 按「能知道会话状态」的原意，这里对**整个 Busy 态**生效，而不只是 `now` 那一种。
        LoadingProgress()
          .width(16)
          .height(16)
          .color(statusColor('running'))
      } else if (session.updatedAtLabel.length > 0) {
        Text(session.updatedAtLabel)
          .fontSize(FontSize.TIME)
          .fontColor(faint())
      }
      Column() {
        AaIcon({ d: ICONS['ellipsis'], iconSize: 19, color: muted() })
      }
      .width(Control.ICON_BUTTON)
      .height(Control.ICON_BUTTON)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(Radius.PILL)
      // 本轮：点「⋯」开**就地小窗口**（改前是整页底部大面板）。
      // 长按仍走 `openActions`（底部面板）—— 那条路是既有入口，不动。
      .bindPopup(this.sessionMenuRowKey === session.id, this.sessionMenuPopupOptions())
      .onClick(() => {
        this.openSessionMenu(session);
      })
    }
  }

  private indicatorColor(session: AgentSession): Resource {
    if (session.indicator === SessionListIndicator.WaitingApproval) {
      return $r('app.color.notice_warning');
    }
    if (session.indicator === SessionListIndicator.Busy) {
      return statusColor('running');
    }
    if (session.indicator === SessionListIndicator.Unread) {
      return $r('app.color.session_status_accent');
    }
    return faint();
  }

  /**
   * 项目行（上游 `HomeProjectComponents.kt:296 HomeProjectRow`）：**固定 56dp 的平铺行** ——
   * 无背景 / 无边框 / 无卡片 / 无内外边距，只有 [Folder|FolderOpen 21dp][项目名 16sp Bold][⋯ 38][✎ 38]。
   *
   * ⚠️ R13-16 改前这里是「圆角卡片 + 1dp 边框 + 上下内边距 + 会话计数列」，真机 dump 实测行高
   *  **205px（≈69vp）**，比上游的 56dp（≈167px）大 23% ⇒ 一屏少显示 3 行（用户连问四次的「底部内容」）。
   *  会话计数列也是本工程自加的：上游 `HomeProjectRow` 没有它（全仓 `sessionCount` 只出现在设备详情页）。
   * ⚠️ 展开/收起只能绑在**左侧内容区**，不能绑整行 —— 整行的 onClick 会和右侧两个按钮抢事件
   *  （同 `sessionRow` 里「只有内容区负责进会话」的做法）。
   */
  @Builder
  projectRow(row: ProjectRow) {
    Column() {
      Row({ space: Space.S_PLUS }) {
        Row({ space: Space.S_PLUS }) {
          // 上游 `HomeProjectComponents.kt:328`：`if (expanded) Lucide.FolderOpen else Lucide.Folder`，21dp。
          AaIcon({ d: row.expanded ? ICONS['folder-open'] : ICONS['folder'], iconSize: 21, color: faint() })
          Text(row.name)
            .fontSize(FontSize.ROW_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(inkSoft())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        // 上游是 `.height(56.dp).padding(vertical = 4.dp)` ⇒ 内容区 48dp；整块内容区都能展开。
        .height('100%')
        // R39：官方按压态。⚠️ 只挂在**左侧内容区**（它才是 `toggleProject` 的命中区），
        //  不挂整行 —— 整行还含右侧「⋯」按钮，挂上去会让点「⋯」也把整行点亮。
        //  `normal` 透明（本行无底色）；单属性约束见坑 227。
        .stateStyles({
          normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(rowPressedSurface()) }
        })
        .onClick(() => {
          this.toggleProject(row.projectId);
        })

        // 上游 `HomeProjectComponents.kt:343/358` 在这里放了**两个**图标（Ellipsis + SquarePen，都是 38dp 圆）。
        //
        // ⚠️ R37 按用户要求**删掉 SquarePen（✎）**：它干的「编辑项目」在紧邻的「⋯」菜单里已经有了
        // （`projectMenuPopup()` 第一行就是「编辑」）—— 两个入口摆在一起属于重复，用户原话「图标重复了」。
        // 这是**有意偏离上游**的一处（复刻口径：用户明确指出的重复入口，按用户改）。
        // 编辑能力本身没有丢：`openProjectEdit` 仍由「⋯ → 编辑」调用。
        Column() {
          AaIcon({ d: ICONS['ellipsis'], iconSize: 19, color: muted() })
        }
        .width(Control.ICON_BUTTON)
        .height(Control.ICON_BUTTON)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(Radius.PILL)
        .onClick(() => {
          this.openProjectMenu(row);
        })
        // 就地弹窗（R13-9）：上游 `HomeProjectComponents.kt:452 HomeProjectAnchoredPopup`。
        .bindPopup(this.projectMenuRowKey === row.projectId, this.projectMenuPopupOptions())
      }
      .width('100%')
      // 上游 `HomeProjectComponents.kt:307-324`：`.height(56.dp)` + `.padding(vertical = 4.dp)`，
      // 且外层 LazyColumn 没有任何 item 间距（`Arrangement` 未设）⇒ 行与行紧邻、总高正好 56dp。
      .height(Control.ROW_PROJECT)
      .padding({ top: Space.XS, bottom: Space.XS })

      if (row.expanded) {
        if (row.sessions.length === 0) {
          // 上游 `HomeProjectComponents.kt:269-282`：`Box(height 42.dp, padding start 38.dp)` + 13sp SemiBold。
          // ⚠️ ArkUI 的 `FontWeight` 枚举只有 Lighter/Normal/Regular/Medium/Bold/Bolder（**没有 SemiBold**），
          //  600 档取最接近的 Medium —— 与 `AaMenuActionRow` 遇到的是同一个平台限制。
          Text('暂无会话。')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(faint())
            .width('100%')
            .height(Control.PROJECT_EMPTY)
            .padding({ left: Control.PROJECT_SESSION_INSET + Space.XS, right: Space.S_PLUS })
        } else {
          ForEach(row.sessions, (session: AgentSession) => {
            this.projectSessionRow(session, true)
          }, (session: AgentSession) => this.sessionKey(session))
        }
      }
    }
    .width('100%')
    // 上游项目行是**平铺行**：无背景 / 无圆角 / 无边框 / 无内边距（卡片形态是 R13-16 之前的实现）。
  }

  /** 底部入口：正常时「加载更多」，请求中禁用，失败时显示原因与「重试」。 */
  @Builder
  loadMoreFooter() {
    Column({ space: Space.S }) {
      if (this.pageErrorFooter().length > 0) {
        Text(this.pageErrorFooter())
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      AaSecondaryButton({
        label: this.loadingMoreFooter() ? '加载中…'
          : (this.pageErrorFooter().length > 0 ? '重试' : '加载更多'),
        interactive: !this.loadingMoreFooter(),
        onTap: () => {
          this.store.loadMore(this.pagingSide());
        }
      })
    }
    .width('100%')
    .padding({ top: Space.S, bottom: Space.S })
  }

  // -------------------------------------------------------------------------
  // 弹层内容（全部挂在根节点那一个 bindSheet 上，用 sheetKind 分发）
  // -------------------------------------------------------------------------

  @Builder
  sessionActions() {
    Column({ space: Space.S }) {
      Text(this.actionSheetTitle)
        .fontSize(FontSize.TITLE)
        .fontColor(ink())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.renaming) {
        TextInput({ text: this.renameValue, placeholder: '会话标题' })
          .fontSize(FontSize.BODY)
          .height(Control.FIELD)
          .borderRadius(Radius.M)
          .borderWidth(StrokeWidth.HAIRLINE)
          .borderColor(borderColor())
          .backgroundColor(raisedSurface())
          .onChange((value: string) => {
            this.renameValue = value;
          })
        AaSecondaryButton({
          label: '保存标题',
          onTap: () => {
            const id = this.actionSheetSessionId;
            const value = this.renameValue;
            // R23：对齐上游 `HomeSessionActions.kt:296-302` 的 `submit()` ——
            // ① 没有改动 → 什么都不做；② 空标题 → 提示「标题不能为空。」且**不提交**；③ 否则才保存。
            // 修前这里把空标题也直接 PATCH 出去了（服务端会拒或把标题改坏）。
            if (value === this.actionSheetTitle) {
              this.renaming = false;
              this.showSheet = false;
              return;
            }
            if (value.length === 0) {
              this.showNotice('标题不能为空。');
              return;
            }
            this.renaming = false;
            this.showSheet = false;
            // 成功要有反馈 —— 上游 `HomeScreen.kt:358` 的 `showToast(home_session_renamed)`。
            // 失败侧不用管：`mutate()` 会把原因写进 `store.error`，页面渲染成错误横幅。
            this.store.renameSession(id, value).then((ok: boolean) => {
              if (ok) {
                this.showNotice('会话已重命名。');
              }
            });
          }
        })
      } else {
        AaSecondaryButton({
          label: '重命名',
          onTap: () => {
            this.renaming = true;
          }
        })
      }

      AaSecondaryButton({
        label: this.actionSheetPinned ? '取消置顶' : '置顶',
        onTap: () => {
          const id = this.actionSheetSessionId;
          const next = !this.actionSheetPinned;
          this.showSheet = false;
          // R23：上游 `HomeScreen.kt:246` 按结果给两条文案（置顶 / 取消置顶）。
          this.store.setSessionPinned(id, next).then((ok: boolean) => {
            if (ok) {
              this.showNotice(next ? '会话已置顶。' : '会话已取消置顶。');
            }
          });
        }
      })
      AaSecondaryButton({
        label: this.actionSheetArchived ? '取消归档' : '归档',
        onTap: () => {
          const id = this.actionSheetSessionId;
          const next = !this.actionSheetArchived;
          this.showSheet = false;
          // R23：上游 `HomeScreen.kt:256` —— 归档 / 恢复各一条文案。
          // R41（交互审计 ③）：归档后的提示补上**恢复路径** —— 归档是从主列表移除，
          // 而取消归档的入口要切到「已归档」筛选才看得到，用户容易以为「归档 = 删掉了」。
          // ⚠️ 这里**刻意不加二次确认**（与项目级 `HomeArchiveProjectDialog` 的不对称是**有意保留**）：
          //  单条归档可逆（同一个菜单里就是「取消归档」）、且是高频操作，加确认会让高频路径变重。
          //  别把它当「漏了确认」补上；要补请连同项目级的取舍一起评估。
          this.store.setSessionArchived(id, next).then((ok: boolean) => {
            if (ok) {
              this.showNotice(next ? '会话已归档，可在「已归档」里恢复。' : '会话已恢复。');
            }
          });
        }
      })
      AaSecondaryButton({
        label: '标记已读',
        onTap: () => {
          const id = this.actionSheetSessionId;
          this.showSheet = false;
          this.store.markSessionRead(id);
        }
      })
    }
    .width('100%')
    .padding(Space.L)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 项目「…」**就地弹窗**卡片（上游 `HomeProjectComponents.kt:452 HomeProjectActionOverlay`：
   * 锚定在触发按钮下方、**无遮罩**；卡片本体是 `:544 HomeProjectActionCard`：252×168dp / 圆角 22 /
   * 上下内边距 7dp / 3 行 50dp）。
   * ⚠️ 卡片里没有「项目名 + 路径」头 —— 上游的动作卡没有；旧底部弹层那一版是本工程自加的。
   */
  @Builder
  projectMenuPopup() {
    Column() {
      AaMenuActionRow({
        label: '编辑',
        iconName: 'pencil',
        // 上游 `HomeProjectActionRow`：16sp / Bold / 左右内边距 20dp
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          this.projectMenuRowKey = '';
          this.openSheet(SHEET_PROJECT_EDIT);
        }
      })
      AaMenuActionRow({
        label: this.projectSheetPinned ? '取消置顶项目' : '置顶项目',
        iconName: 'pin',
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          this.projectMenuRowKey = '';
          this.toggleProjectPinned();
        }
      })
      AaMenuActionRow({
        label: '归档该项目',
        iconName: 'archive',
        danger: true,
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          this.projectMenuRowKey = '';
          this.projectArchiveConfirm = true;
          this.openSheet(SHEET_PROJECT);
        }
      })
    }
    .width(Control.MENU_CARD_W)
    .height(Control.MENU_CARD_H)
    .padding({ top: CARD_PAD_V, bottom: CARD_PAD_V })
    // ## R86：卡片底改由「官方材质 / 自绘玻璃」**二选一**，由同一个探针门控（绝不同时存在 ⇒ 契约 §1.8 可归因）
    // · 材质可用（`immersiveMaterialEnabled()` = 应用级 `state=enable` **且** 设备支持）：本根**零自绘层**
    //  —— 透明底 + 零描边，底由 `projectMenuPopupOptions()` 下发的 `dialogMaterial()` 画
    // （官方：材质会接管 background / border / blur / shadow，`common.d.ts:22625-22630`；生效范围 `坑 245`）。
    // · 材质不可用：**逐字回到 R86 前的自绘玻璃**（`menuSurface()` + 1vp 描边）—— 弹窗容器自己是
    //  `popupColor: Color.Transparent`，本根是**唯一**提供「底」的节点，删净会让面板完全透明（文字浮在正文上）。
    // · 关闭姿势 = `uiMaterial.Material.empty`（= disable），由 `dialogMaterial()` 在探针不可用时自己返回
    //  （`uiMaterial.d.ts:467-472`）；**不得**传 `undefined`（官方语义 = 「恢复组件默认材质」，
    //  `common.d.ts:22632-22633` / `坑 256`）。
    // · `.borderRadius()` 与宽/高/内边距一字未动（几何不属「谁在画底」）。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : this.menuSurface())
    .borderRadius(Radius.XXL)
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 会话「⋯」的**小窗口**内容（本轮新增）：只四行 —— 重命名 / 置顶 / 归档 / 标记已读。
   *
   * 几何与同页项目动作卡逐项一致（`HomeProjectActionCard`：252 宽 / 圆角 22 / 上下内边距 7 /
   * 行高 50 / 文字 16sp Bold / 左右内边距 20），所以两处弹窗看起来是同一套东西。
   * ⚠️ 行数比项目卡多一行，所以**不写死高度**（项目卡是 `MENU_CARD_H = 168` = 3×50 + 14）。
   */
  @Builder
  sessionMenuPopup() {
    Column() {
      AaMenuActionRow({
        label: '重命名',
        iconName: 'pencil',
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          this.sessionMenuRowKey = '';
          // 重命名要输入框 ⇒ 进二级（复用原来的 bindSheet，不为此自造弹层）
          this.openSheet(SHEET_SESSION);
        }
      })
      AaMenuActionRow({
        label: this.actionSheetPinned ? '取消置顶' : '置顶',
        iconName: 'pin',
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          const id = this.actionSheetSessionId;
          const next = !this.actionSheetPinned;
          this.sessionMenuRowKey = '';
          // R23：上游 `HomeScreen.kt:246` 按结果给两条文案（置顶 / 取消置顶）。
          this.store.setSessionPinned(id, next).then((ok: boolean) => {
            if (ok) {
              this.showNotice(next ? '会话已置顶。' : '会话已取消置顶。');
            }
          });
        }
      })
      AaMenuActionRow({
        label: this.actionSheetArchived ? '取消归档' : '归档',
        iconName: 'archive',
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          const id = this.actionSheetSessionId;
          const next = !this.actionSheetArchived;
          this.sessionMenuRowKey = '';
          // R23：上游 `HomeScreen.kt:256` —— 归档 / 恢复各一条文案。
          // R41：同 `actionSheet` 那处 —— 补恢复路径、且**不加确认**（理由见该处注释）。
          this.store.setSessionArchived(id, next).then((ok: boolean) => {
            if (ok) {
              this.showNotice(next ? '会话已归档，可在「已归档」里恢复。' : '会话已恢复。');
            }
          });
        }
      })
      AaMenuActionRow({
        label: '标记已读',
        iconName: 'mail-check',
        textSize: FontSize.ROW_TITLE,
        padH: Space.L_PLUS,
        boldText: true,
        onTap: () => {
          const id = this.actionSheetSessionId;
          this.sessionMenuRowKey = '';
          this.store.markSessionRead(id);
        }
      })
    }
    .width(Control.MENU_CARD_W)
    .padding({ top: CARD_PAD_V, bottom: CARD_PAD_V })
    // ## R86：同 `projectMenuPopup()` —— 底由「官方材质 / 自绘玻璃」**二选一**（同一探针门控，禁止双保险）。
    // · 材质可用（`immersiveMaterialEnabled()`）：本根零自绘层，底由 `sessionMenuPopupOptions()` 的
    //  `dialogMaterial()` 画（官方：材质接管 background / border / blur / shadow，`common.d.ts:22625-22630`；
    //  生效范围见 `坑 245`）；不可用则逐字回到 R86 前的 `menuSurface()` + 1vp 描边。
    // · 关闭姿势 = `uiMaterial.Material.empty`（`dialogMaterial()` 在探针不可用时返回，`uiMaterial.d.ts:467-472`）；
    //  **不得**传 `undefined`（= 恢复组件默认材质，`common.d.ts:22632-22633` / `坑 256`）。
    // · 几何（宽 / 圆角 / 内边距）一字未动。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : this.menuSurface())
    .borderRadius(Radius.XXL)
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 项目归档二次确认（**保留**弹层形态）。
   *
   * 上游 `HomeProjectComponents.kt:768 HomeArchiveProjectDialog` 是 **Dialog**（带遮罩）—— F-5 说的是
   * 「本该贴按钮弹的菜单却压了整页遮罩」，不含对话框，所以这一处不动（含 300 高度的 sheet 参数）。
   */
  @Builder
  projectArchiveSheet() {
    Column({ space: Space.XS }) {
      if (this.projectArchiveConfirm) {
        Text(`「${this.projectSheetName}」中的所有活跃会话都会被归档，项目本身会保留。`)
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .width('100%')
          .padding({ left: Space.M, right: Space.M, bottom: Space.S })
        Row({ space: Space.S }) {
          AaSecondaryButton({
            label: '取消',
            onTap: () => {
              this.projectArchiveConfirm = false;
            }
          })
          Row() {
            AaPrimaryButton({
              label: '确认归档',
              onTap: () => {
                this.archiveProjectSessions();
              }
            })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: Space.M, right: Space.M })
      }
    }
    .width('100%')
    .padding({ top: Space.L, bottom: Space.L })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 会话状态筛选卡片 —— **就地弹窗**的内容（上游 `HomeProjectMenus.kt:24 HomeProjectFilterMenu`
   * → `AADropdownMenu.kt:94 AAAnchoredDropdownMenu`）。
   *
   * 几何逐项照抄上游，并用安卓 dump 复核（开发期验证记录）：
   * 容器 286×212.8dp（dump `[298,743]-[1149,1376]` px ÷ dpr 2.975；宽正好 286）、圆角 18、
   * 上下内边距 14、标签项高 40.5dp（743→905）、三个选项行 48.07dp（行距 143px）。
   * 卡片**没有**箭头、没有阴影（上游 `shadowElevation = 0`），浅色下只有 1dp 描边。
   */
  @Builder
  filterMenuPopup() {
    // ⚠️ **不要**给这里加 `space`（R25 实测缺陷）：上游 `AADropdownMenuItem` 是
    // `heightIn(min = 48.dp)` 的行**紧挨着**排（Material 的 Column 无 spacing），
    // 安卓 dump 实测行距 143px ÷ dpr 2.975 = **48.07dp**。此前写成 `Column({ space: Space.XS })`
    // （+4vp）⇒ 鸿蒙行距 182px ÷ 3.5 = **52dp**，三行菜单整整高出 12dp、标签到首项也错位。
    Column() {
      // 上游 `AADropdownMenuLabel`：12sp / inkSoft α0.72 / 左右内边距 16。
      Text('会话状态')
        .fontSize(FontSize.MENU_LABEL)
        .fontColor(muted())
        .width('100%')
        .height(Control.MENU_LABEL_H)
        .padding({ left: Space.L, right: Space.L })
      AaMenuActionRow({
        label: projectSessionFilterLabel(ProjectSessionFilter.ACTIVE),
        active: this.filter === ProjectSessionFilter.ACTIVE,
        rowHeight: Control.MENU_ITEM_MIN,
        // 上游 `AADropdownMenuItem`：14sp；无 SemiBold ⇒ 取 Bold（工程既有约定）
        textSize: FontSize.BODY_SMALL,
        boldText: true,
        activeTint: ink(),
        onTap: () => {
          this.applyFilter(ProjectSessionFilter.ACTIVE);
        }
      })
      AaMenuActionRow({
        label: projectSessionFilterLabel(ProjectSessionFilter.ARCHIVED),
        active: this.filter === ProjectSessionFilter.ARCHIVED,
        rowHeight: Control.MENU_ITEM_MIN,
        textSize: FontSize.BODY_SMALL,
        boldText: true,
        activeTint: ink(),
        onTap: () => {
          this.applyFilter(ProjectSessionFilter.ARCHIVED);
        }
      })
      AaMenuActionRow({
        label: projectSessionFilterLabel(ProjectSessionFilter.ALL),
        active: this.filter === ProjectSessionFilter.ALL,
        rowHeight: Control.MENU_ITEM_MIN,
        textSize: FontSize.BODY_SMALL,
        boldText: true,
        activeTint: ink(),
        onTap: () => {
          this.applyFilter(ProjectSessionFilter.ALL);
        }
      })
    }
    .width(Control.MENU_WIDTH)
    .padding({ top: Control.MENU_PAD_V, bottom: Control.MENU_PAD_V })
    .constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })
    // ## R86：同两处动作卡 —— 底由「官方材质 / 自绘玻璃」**二选一**（同一探针门控，禁止双保险）。
    // · 材质可用（`immersiveMaterialEnabled()`）：本根零自绘层，底由 `filterMenuPopupOptions()` 的
    //  `dialogMaterial()` 画（官方：材质接管 background / border / blur / shadow，`common.d.ts:22625-22630`；
    //  生效范围见 `坑 245`）；不可用则逐字回到 R86 前的 `menuSurface()` + 1vp 描边。
    // · 关闭姿势 = `uiMaterial.Material.empty`（`dialogMaterial()` 在探针不可用时返回，`uiMaterial.d.ts:467-472`）；
    //  **不得**传 `undefined`（= 恢复组件默认材质，`common.d.ts:22632-22633` / `坑 256`）。
    // · 几何（286 宽 / 圆角 18 / 上下 14 / 最大高 328）一字未动。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : this.menuSurface())
    .borderRadius(Radius.XL)
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .alignItems(HorizontalAlign.Start)
  }

  /** 项目编辑（上游 `HomeProjectEditSheet`：名称可改，设备与路径只读）。 */
  @Builder
  projectEditSheet() {
    Column({ space: Space.S }) {
      Text('编辑项目')
        .fontSize(FontSize.HEADLINE)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .width('100%')

      Text('项目名称')
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .width('100%')
      TextInput({ text: this.projectRenameValue, placeholder: '项目名称' })
        .fontSize(FontSize.BODY)
        .height(Control.FIELD)
        .borderRadius(Radius.M)
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .backgroundColor(subtle())
        .onChange((value: string) => {
          this.projectRenameValue = value;
        })

      Text('设备')
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .width('100%')
      AaReadOnlyField({ value: this.projectSheetDevice })

      Text('路径')
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .width('100%')
      AaReadOnlyField({ value: this.projectSheetPath, mono: true })

      Text('项目创建后，设备和路径不可修改。')
        .fontSize(FontSize.CAPTION)
        .fontColor(faint())
        .width('100%')

      if (this.projectEditError.length > 0) {
        Text(this.projectEditError)
          .fontSize(FontSize.SMALL)
          .fontColor(errorText())
          .width('100%')
      }

      Row({ space: Space.S }) {
        AaSecondaryButton({
          label: '取消',
          interactive: !this.projectEditBusy,
          onTap: () => {
            this.showSheet = false;
          }
        })
        Row() {
          AaPrimaryButton({
            label: this.projectEditBusy ? '保存中…' : '保存',
            loading: this.projectEditBusy,
            interactive: this.projectRenameValue.trim().length > 0,
            onTap: () => {
              this.saveProjectName();
            }
          })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: Space.XS })
    }
    .width('100%')
    .padding(Space.L)
    .alignItems(HorizontalAlign.Start)
  }
}
