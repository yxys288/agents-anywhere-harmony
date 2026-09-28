/**
 * 底部功能栏 —— **自绘悬浮胶囊**（R62 用户指定形态 + R63/F1 令牌；R65-D 回退后的交付路径）。
 *
 * 用户原话：「将"设备"，"终端"，"文件"移到底部做悬浮功能底栏，底栏共四个选项：
 * "首页"，"设备"，"终端"，"文件"」。
 *
 * ## 为什么是自绘、不是官方 ImmersiveMaterial（真机结论，2026-09-24，Mate70 Pro+，深色，同一集成包）
 * | 底栏档 | 胶囊带 p50 | 带外 p50 | Δ |
 * | --- | --- | --- | --- |
 * | 官方材质（Tabs + `barFloatingStyle.systemMaterial`） | 9.2 | 9.2 | **+0.0** |
 * | 官方 Tabs + 自绘磨砂 `barBackgroundEffect` | 9.2 | 9.2 | **+0.0** |
 * | **本文件的自绘悬浮胶囊（R63/F1）** | **25.2** | 9.2 | **+16.0** |
 * 另：`barFloatingStyle` 也未生效（四个 item 重心 164/493/822/1151 = 1316/8 的整数倍 ⇒ 仍横铺满宽）。
 * ⇒ **Tabs 底部 TabBar 在本机型 / 本位置画不出任何可见表面**。
 *  ⚠️ 这不是「API 用错」也不是「全局开关没开」：同一台机、同一次构建里，**顶栏**（`Navigation` 标题栏内）
 *  的官方材质 MAE 有 5.16 ~ 8.44。`坑 245` 的生效范围④（横向 `Tabs` 且
 *  `barPosition = BarPosition.End` 的底部 TabBar）在本机型上属于「在范围内但不出效果」
 *  ⇒ 按坑 245 配方的第 5 条走**第二条路：放弃官方效果走自绘**。
 *
 * ## 本文件两条路并存（R65-D；**T2/task-1 改默认**）
 * ① **交付路径 = 官方 Tabs 底栏基建**（`bottomNavIndex` / `bottomBarMaterial` / `AaBottomTabItem`）：
 *  `pages/Index.ets` 的 `topLevelTabs()`（`barPosition: BarPosition.End`）＋ `barOverlap(true)` 的官方 blur
 *  ＋ **官方材质** `FloatingTabBarStyle.systemMaterial`（`BOTTOM_TABS_OFFICIAL_MATERIAL` **本轮起默认 `true`**）；
 * ② **回退路径 = `AaBottomNav` 自绘悬浮胶囊**（磨砂 + 同源渐变光层 + 亮边）：
 *  它**只在** `BOTTOM_BAR_VIA_TABS === false` 时上树，承载「向手势条缩没」的收回动画
 *  （官方 Tabs 的 bar 由框架拥有，没有缩放锚点 API）。真机若否掉 ①，改开关即回到这条。
 *
 * ## 复跑方法（换机型时，5 步；判据仍是「材质开 / 关」两包的逐像素 MAE）
 * 1. `pages/Index.ets` 的 build **最前面**加分支 `if (bottomNavIndex(this.route) >= 0) { this.topLevelTabs() }`，
 *  并删掉 HOME/DEVICES/TERMINAL/FILES 四条原分支（四页改由 `TabContent` 内的 `if (this.route === X)` 挂载
 *  —— 非当前页渲染成空节点，保证同一时刻只有一个页面存活）；
 * 2. 加 `Tabs({ barPosition: BarPosition.End, index: this.topTabIndex(), controller: this.tabsController })`
 *  + 四个 `TabContent`；`index` 由路由算出（声明式对齐），`@Watch(ROUTE_KEY)` 里用
 *  `tabsController.changeIndex()` 做命令式对齐（`坑 101`：`index` 只是受控入参，两个方向都要显式做）；
 * 3. 材质挂在 **`.barFloatingStyle({ barSideMargin: Space.PAGE, barBottomMargin: gap, systemMaterial: bottomBarMaterial() })`**
 *  —— ⚠️ 入口在 `FloatingTabBarStyle` 里，**不在 `TabsOptions` 里**（详见 `bottomBarMaterial()` 的注释）；
 * 4. `.scrollable(false)`（横滑会绕过 `Router`，把唯一状态源变成两个）/ `.animationDuration(0)` /
 *  `.barBackgroundColor(Color.Transparent)` / `.divider(null)` /
 *  `.onChange(i => bottomNavSelect(BOTTOM_NAV_ITEMS[i].key))`；
 * 5. 四页删掉自己的 `AaBottomNav` 挂载（TerminalScreen 另删 `extraKeys` 的底部安全区 margin）。
 */
import {
  FontSize, GLASS_BLUR_RADIUS, GLASS_BRIGHTNESS, GLASS_SATURATION, GlassSpec, Space, StrokeWidth,
  bottomNavActive, glassNavSurface, glassRimHigh, glassSheenClear, glassSheenHigh, glassSheenMid, muted
} from './Design';
import { AaIcon, ICONS } from './Icon';
import { ROUTE_KEY, Route, Router } from './Router';
import { uiMaterial } from '@kit.ArkUI';

/** 底栏入口。`key` 是选中态标识；`route` 是点它要去的顶层目的地。 */
export interface BottomNavItem {
  key: string;
  label: string;
  icon: string;
  route: string;
}

/**
 * 底栏高度（vp）：图标 24 + 间距 4 + 文案 11pt 行高 ≈ 46，留 60 保证每项点击区 ≥ 44vp。
 */
export const BOTTOM_NAV_HEIGHT: number = 54;

/**
 * 参考图（开发期验证记录，1316×323）的**实测值 → 本工程落值**
 * —— R67 的缩身依据，**逐项都是量出来的，不是估的**（开发期量测脚本）。
 *
 * | 项 | 参考图实测(px) | 折算(vp, 3x) | 本工程落值 |
 * | --- | --- | --- | --- |
 * | 胶囊宽 | 835（x 240..1074） | 278.3 = **屏宽 63.5%** | 见 `BOTTOM_BAR_SIDE_MARGIN`（左右各 18%） |
 * | 胶囊高 | 163（y 60..222） | **54.3** | `BOTTOM_NAV_HEIGHT = 54` |
 * | 全圆角 | r = 81.5 = 高/2 | 27 | `.borderRadius(BOTTOM_NAV_HEIGHT / 2)` |
 * | 图标（ink 宽中位） | 65 | 21.7 | `FontSize.ICON_XL = 22` |
 * | 文字（ink 高） | 28 | 9.3 ⇒ 字号 ≈ 11 | `FontSize.CAPTION = 11`（不变） |
 * | 图标→文字间隙 | 14 | 4.7 | `Space.XS = 4` |
 * | 胶囊上下内边距 | 26 / 28 | 8.7 / 9.3 | 由 54 − 内容高自然得出 ≈ 7 |
 * | 项中心距 | 154 | 51.3 | 4 项撑满 63.5% ⇒ 69.6（5 项参考图 vs 4 项本工程，见下） |
 *
 * ⚠️ **两条必须写清楚的测量结论**（都推翻了上一轮的估读）：
 * ① 胶囊高不是 110px 而是 **163px**：`y 166..194` 那一段不是「胶囊下方的正文」，而是**item 文字**
 *  （探索/游戏/应用/元服务/我的）—— 它画在材质**之上**，所以是锐利的。判据：把
 *  stadium(y 60..222, r=81.5) 反向画回原图，圆弧与胶囊边缘**逐点贴合**
 *  （预测 x(y=62)=301.5 实测 304、x(y=90)=257.9 实测 258、x(y=141)=240 实测 240）；
 *  而按 y 55..165 画框会**从文字中间横切过去**（`tmp/r67-overlay.png`）。
 * ② 右上角那个「安装」是**独立按钮**（填充偏蓝 (227,235,246)，x 1085..1275），**不属于底栏**，
 *  否则会把宽度多算 62px。
 *
 * ⚠️ **项数差异**：参考图 5 项（中心距 51.3vp），本工程 4 项。这里选择**匹配外轮廓比例**
 *（胶囊 = 屏宽 63.5%），因此本工程每项 69.6vp、比参考图的项距宽 —— 若你更想要参考图那种
 *「项挨得更紧」的节奏（项距 51.3vp ⇒ 胶囊 ≈ 屏宽 51.7%），改 `BOTTOM_BAR_SIDE_MARGIN` 一处即可。
 *
 * ⚠️ **触控区**：本胶囊高 **54vp ≥ 44vp** ⇒ 四项的点击区天然达标，**不需要**「光学放大 hitTest」
 *（那会让点击区超出视觉胶囊，反而误触）。⚠️ 若将来把 `BOTTOM_NAV_HEIGHT` 再缩到 44 以下，
 * 必须把「视觉层（胶囊底）」与「交互层（item）」拆成 `Stack` 两层，否则 44vp 的要求会破。
 */
export const BOTTOM_NAV_ICON_SIZE: number = 22;

/**
 * 胶囊左右留边 = **屏宽的 18%**（参考图实测 240px / 1316px = 18.2%）。
 * 用百分比而不是 vp：这样在别的屏宽上仍是「参考图那个比例」。
 */
export const BOTTOM_BAR_SIDE_MARGIN: string = '18%';

/**
 * 官方**定栏宽**的正规入口（`FloatingTabBarStyle.barWidth`，SDK 明确「不可用百分比」）的取值。
 *
 * 折算：参考图胶囊宽 **835px** ÷ 3 = **278.3vp**（参考图 1316px@3x 与本机同刻度）⇒ 取 **278**。
 * 在本机 438.7vp 屏宽上 = **63.4%**，与参考图实测的 63.5% 一致。
 * ⚠️ 它替代了 R66-3/R67 的 `barSideMargin`(79vp) —— 那是拿「左右留边」凑宽度，
 *  官方给了按断点定栏宽的字段，就该用它（R68 更正）。
 */
export const BOTTOM_BAR_WIDTH_VP: number = 278;

/**
 * **B 档（自绘）专用的背景模糊半径**（vp）—— R69 新增。
 *
 * 为什么单独一档：参考图那条胶囊的通透感来自「**背后内容被糊住**」，而 B 档没有官方材质，
 * 只剩 `backgroundEffect` 这一个磨砂入口。共用的 `GLASS_BLUR_RADIUS` 只有 **6**（顶栏/卡片尺度，
 * 对 54vp 的底栏太轻）⇒ 这里取 **18**，让背后内容明显糊掉、更接近参考图。
 * ⚠️ 只动**半径**，`saturation/brightness/color` 三个令牌一字未改 ⇒ R63/F1 的 Δ 判据（胶囊内 vs 带外）不受影响。
 * ⚠️ `坑 84` 的告诫：半径过大会采样到组件外的清晰内容、在边缘留「糊→清」的接缝 —— 18 对 54vp 高
 *  属于可接受区间；真机若看出边缘接缝，往下调（12~14）即可，改这一处。
 */
export const BOTTOM_BAR_BLUR_RADIUS: number = 18;

/**
 * **R71 临时探针总开关**（编译期常量，**本轮默认 true**）—— 由 Lead 上机采证后改回 `false`。
 *
 * 为什么需要它：R70 包的真机证据是「滑 4 次 / 3 秒长拖动期间抓帧，底栏都完整显示」⇒
 * `aaBottomBarHidden` **从未变 true**（纸面接线全对）⇒ 嫌疑集中在
 * **`List.onScrollIndex` 在真机上根本没回调**（或回调了但 `start` 不变 / `end ≤ 0 恒成立，
 * 被 `syncBottomBarOnFirstIndex` 的「不足一屏」守卫短路）。
 *
 * 打开后会打两类日志，tag 统一用 `aaBottomBar`（采证：`hdc shell hilog -x | Select-String aaBottomBar`）：
 * · `HomeScreen` 每个 `onScrollIndex` 回调 + 每次 `bottomBarHidden` 赋值（带原因）；
 * · `Index` 每次 `floatingBarStyle()` 求值时**实际下发的几何**（barHeight / gap / width / 材质开关）
 *  —— 一次上机即可同时判定「胶囊偏胖是值没生效还是框架拉伸」（H1/H2/H3）。
 */
export const BOTTOM_BAR_PROBE: boolean = true;

/**
 * **H3 一行开关**：官方材质的投影（`ImmersiveMaterial.applyShadow`）。默认 true = 官方原样。
 * 若真机上胶囊的**像素外沿**明显大于**节点 bounds**（阴影 + 模糊外溢把视觉高度撑大），切 false 复量。
 */
export const BOTTOM_BAR_MATERIAL_SHADOW: boolean = true;

/**
 * **H1/H2 一行开关**：路线 A 的 `barHeight` 到底表达哪一段。
 *
 * · `true`（默认，**H1**）：= **胶囊自身高度** 54vp；离底 32vp 间隙在 `barBottomMargin`（R69 起）。
 * · `false`（**H2**）：= **整条 bar 带** 86vp（= 54 + 32），间隙仍由 `barBottomMargin` 在带内上抬 —— 即 R68 的分配。
 * ⚠️ 判据（真机）：量到胶囊 ≈**162px**、底边离屏底 ≈96px ⇒ H1 对（保持 true）；
 *  量到胶囊**比 54 更薄 / 贴着带底** ⇒ 框架把 margin 当「带内缩」，切 false。
 */
export const BOTTOM_BAR_HEIGHT_IS_CAPSULE_ONLY: boolean = true;

/**
 * 收回动画的**终态缩放**（R67：以底边中心为锚点缩进手势条）。
 * 取 0.25 而不是 0：0 在部分机型上会退化成「瞬间消失」，留一点收束过程更像「缩进手势条」；
 * 与同时降到 0 的不透明度叠加后，视觉上就是消失。
 */
export const BOTTOM_BAR_HIDE_SCALE: number = 0.25;

/**
 * 四项入口（顺序 = 用户给的顺序：首页 / 设备 / 终端 / 文件）。
 *
 * ⚠️ 图标名必须是 `ui/Icon.ets` 的 `ICONS` 里**真实存在**的键（`suite-icons` 会守）：
 * `house`（R62 新增）/ `monitor` / `terminal` / `folder`。
 * ⚠️ 四个目的地都是**顶层页**，四页各自挂载本底栏并把 `active` 传成自己的 key
 * （`bottomNavSelect` 的注释里有跨页切换的语义约定）。
 */
export const BOTTOM_NAV_ITEMS: BottomNavItem[] = [
  { key: 'home', label: '首页', icon: 'house', route: Route.HOME },
  { key: 'devices', label: '设备', icon: 'monitor', route: Route.DEVICES },
  { key: 'terminal', label: '终端', icon: 'terminal', route: Route.TERMINAL },
  { key: 'files', label: '文件', icon: 'folder', route: Route.FILES }
];

/**
 * 底栏**自动收回**状态的共享键（AppStorage）。
 *
 * · 写入方**只有** `HomeScreen`（列表滚动方向 / 停滑 / 打开设置抽屉）；
 * · 读取方是 `pages/Index.ets` 的浮层底栏（路线 B）或 Tabs bar（路线 A）；
 * · 用 AppStorage 字符串键而不是 `@Provide/@Consume`：两者**没有父子关系**
 *  （Index 是 HomeScreen 的宿主），字符串键也是全工程既有的状态通道（`aaRoute` / `aaSafeArea*` 同一套）；
 * · 只有首页写它 ⇒「只首页自动收回、其余页常驻」由写入方天然保证。
 */
export const BOTTOM_BAR_HIDDEN_KEY: string = 'aaBottomBarHidden';

/**
 * 底栏由谁承载 —— **编译期常量**（真机 A/B 用：改这一行 + 重新构建）。
 *
 * | 值 | 路线 | 承载者 | 官方材质 | 自动收回 |
 * | --- | --- | --- | --- | --- |
 * | `true`（**R68 起默认**） | **A** | `pages/Index.ets` 的官方 `Tabs`（`barPosition: End`） | ✅ `barFloatingStyle.systemMaterial` + `barOverlap(true)` 的官方模糊 | ⚠️ 无框架级隐藏 API ⇒ 只能用 `barHeight` 塌陷（**不是**缩进手势条） |
 * | `false`（回退档） | **B** | `pages/Index.ets` 根 `Stack` 的浮层 + `AaBottomNav` 自绘胶囊 | ❌ 页面正文位置，`坑 245` 不在生效范围 | ✅ `scale`(底边锚定) + `opacity`，可做「缩进手势条」 |
 *
 * ⚠️ **路线 A 有前置**：Devices/Terminal/Files 三页必须先删掉自己挂载的 `AaBottomNav`
 * （否则同屏两条底栏，且自绘胶囊正好挡在材质 ROI 背后，污染 A/B）。
 *
 * ## R69：**两档差异表**（一行常量切换 `BOTTOM_BAR_VIA_TABS`，供用户在两者间选）
 * | 维度 | **A 档 = 官方（默认）** | **B 档 = 自绘** |
 * | --- | --- | --- |
 * | 载体 | `pages/Index.ets` 的官方 `Tabs`（`barPosition: End`） | `pages/Index.ets` 根 `Stack` 的浮层 + `AaBottomNav` |
 * | 材质 | `FloatingTabBarStyle.systemMaterial`（官方沉浸材质） | 自绘：`glassNavSurface()` 纱 + `backgroundEffect` 磨砂 |
 * | 背后内容被糊住 | `barOverlap(true)` 的官方 `BlurStyle.COMPONENT_THICK` | `backgroundEffect(radius = BOTTOM_BAR_BLUR_RADIUS)`（自绘模糊，本质同一层效果） |
 * | 亮边 / 光感 | 官方材质自带 | `glassRimHigh()` 亮边 + 同源渐变光层 |
 * | 几何 | `barWidth = 278vp` / `barHeight = 54vp` / 全圆角 / 图标 22 / 文字 11pt | 同一套实测值（18% 留边 / 54 / h/2 / 22 / 11pt） |
 * | **自动收回** | **只能塌陷**：`barHeight 54 → 0` + `barBottomMargin 32 → 0`，无缩放 ⇒ 观感「条带被抽走」 | `scale(centerY '100%') 1 → 0.25` + `opacity 1 → 0` + 隐藏态 `hitTestBehavior(None)` ⇒ **向手势条缩没** |
 * | 用户要的「缩进手势条消失」 | ❌ 做不到（框架拥有 bar，没有缩放锚点 API） | ✅ 就是它 |
 * | 风险 | 官方材质在本机型底栏位置**是否出像素仍未定**（决定性 A/B 未完） | 自绘观感的「原生度」不如官方；模糊/纱参数需真机微调 |
 *
 * ## ⛔ R68 教训（不要再犯）：**不要为了「A/B 干净」去中和官方默认行为**
 * R66-3 为了让「材质开/关」成为单变量，显式写了 `.barBackgroundBlurStyle(BlurStyle.NONE)` ——
 * 而 SDK 原文（`tabs.d.ts:1467` `barOverlap`）写的正是：
 * 「true: the tab bar **overlaps the TabContent with a blurred background effect**, and the **default blur style
 * of the tab bar is set to BlurStyle.COMPONENT_THICK**」。⇒ 被中和掉的**正是用户要的那层效果本身**
 * （参考图胶囊的通透感 = 官方 blur × 材质），真机上于是只剩一块平板灰底 ⇒ 用户反馈「不像官方」。
 * ⇒ 正确做法：**两臂都留 blur，只切 `systemMaterial`**（见 `pages/Index.ets` 的 `topLevelTabs()`）。
 * ⚠️ 两路线都**必须让内容从底栏背后穿过**：官方材质是折射/模糊材质，背后是均匀纯色时
 * 它**本来就长得和背景一样** —— R65 那次 Δ+0.0 正是踩了这个假阴性（ROI 选在空区）。
 */
export const BOTTOM_BAR_VIA_TABS: boolean = true;

/**
 * 浮层底栏（路线 B）**覆盖哪些顶层路由**。
 *
 * ⚠️ 过渡态（R66-3）：Devices/Terminal/Files 三页当前仍各自挂载 `AaBottomNav`
 * （本轮不在写入面、正被 r66-topbar 改）⇒ 默认**只覆盖首页**，避免同一屏出现两条底栏。
 * 那三页的挂载删掉后，把四条路由都加进本数组即可 —— **本数组是这件事的唯一开关**。
 */
export const OVERLAY_BAR_ROUTES: string[] = [Route.HOME, Route.DEVICES, Route.TERMINAL, Route.FILES];

/**
 * 浮层底栏要**给内容留出的底部高度**（vp）= 胶囊 `BOTTOM_NAV_HEIGHT`(54) + 离底让位（`Space.XXL` 档 32）= **86**。
 * ⚠️ R67 复核：胶囊由 60 缩到 54（按参考图实测 163px/3）⇒ 预留由 92 收到 **86**；四页的接入点
 * 全部引用本常量（Devices 的尾部内边距 / Terminal 的页面 padding / Files 的 list 尾部偏移与预览内边距），
 * 所以**改这一处即四页同步**，不会留一大片空白。
 *
 * ⚠️ R66-3 的**关键配套**：底栏从「页内停靠」改成「Index 浮层」后，页面内容会一直铺到屏幕下缘、
 * **从胶囊背后滚过去** —— 于是四个顶层页的**最底部内容**必须自己留出这一条，否则会被胶囊压住：
 * · 终端页的功能键行（ESC/TAB/CTRL/ALT）会被整条盖掉；
 * · 设备/文件页的末行会「滚不出来」（末行停在胶囊背后）。
 *
 * 取 `Space.XXL`(32) 而不是实测安全区：32 ≥ 本机手势条避让（约 15vp），且它是**下限** ——
 * 与 `pages/Index.ets` 的 `barBottomGapVp()`（= max(Space.XXL, 安全区)）同一口径，
 * 页面侧不必（也不该）重复读安全区。首页用的是既有的 `Space.HOME_LIST_BOTTOM`(96 ≥ 92)，保持不变。
 */
export const BOTTOM_BAR_RESERVED_VP: number = BOTTOM_NAV_HEIGHT + Space.XXL;

/** 该路由上是否由 Index 的浮层底栏负责画底栏。 */
export function overlayBarShownOn(route: string): boolean {
  let i: number = 0;
  while (i < OVERLAY_BAR_ROUTES.length) {
    if (OVERLAY_BAR_ROUTES[i] === route) {
      return true;
    }
    i = i + 1;
  }
  return false;
}

/** 路由 → 底栏入口 key（浮层底栏的选中态要用）；不是顶层页时返回空串。 */
export function bottomNavKey(route: string): string {
  const index = bottomNavIndex(route);
  return index >= 0 ? BOTTOM_NAV_ITEMS[index].key : '';
}

/**
 * 底栏点选的**共享处理** —— 四个顶层页共用同一份（用户要求：底栏在四个功能页上「始终保持显示」）。
 *
 * ## 为什么用 `Router.reset()` 而不是 `Router.push()`
 *
 * 本工程的路由**上游就是单值状态机**（`Router` 头部注释：只有 `destinationName` 一个字符串），
 * 顶层目的地之间是**平级切换**，不是压栈。用 `push` 的后果：首页→设备→终端→设备…来回点会把栈越堆越深，
 * 返回键要按很多次才退出。`reset` 把栈重置成单条 ⇒ 与上游语义一致，也让
 * 「顶层页按返回 = 回首页（已首页则退出）」这条既有行为保持成立（`Router.back()`）。
 *
 * ⚠️ 已在目标页时**直接返回**，不重复 `reset` —— 否则每次点当前项都会整页重建（闪一下）。
 */
export function bottomNavSelect(key: string): void {
  let target: string = '';
  let i: number = 0;
  while (i < BOTTOM_NAV_ITEMS.length) {
    if (BOTTOM_NAV_ITEMS[i].key === key) {
      target = BOTTOM_NAV_ITEMS[i].route;
    }
    i = i + 1;
  }
  if (target.length === 0) {
    return;
  }
  if (Router.current().route === target) {
    return;
  }
  Router.reset(target);
}

/**
 * 悬浮功能底栏的**自绘悬浮胶囊**（R62 用户指定的形态，R65-D 回退后的交付实现）。
 *
 * ## 设计要点
 * · **四个入口都是顶层目的地**，跳转方式与原首页快捷卡**完全一致**（`Router.reset(target)` 不带参数）；
 * · 「首页」= 当前页，只呈现选中态（`active` 由各页自己传）；
 * · 观感沿用工程既有的**自绘玻璃**语言（`glassNavSurface()` + `backgroundEffect`），
 *  与顶栏同一套材质，不引入新的视觉体系（`坑 74`：玻璃一律用 `backgroundEffect`）。
 * · ⚠️ 自绘玻璃盘是**不透明卡片**装不出来的，所以这里给的是**整条胶囊**的玻璃底，
 *  而不是四块独立玻璃（四块会把中间的缝露成硬边）。
 *
 * ## R67 缩身（按参考图实测，见文件头那张对照表）
 * 高 **54vp**（参考图 163px/3）、全圆角（= 高/2）、图标 **22vp**、文字 11pt、项间距由「胶囊宽 = 屏宽 63.5%」
 * 反推。左右留边由渲染方（`pages/Index.ets` 的浮层）用 `BOTTOM_BAR_SIDE_MARGIN` 给，
 * 组件自己**不**带外边距（与 R62 的写法一致：外边距挂在外层容器上，本工程对「自定义组件后接通用属性」零先例）。
 * ⚠️ 触控区：胶囊高 54 ≥ 44vp ⇒ 四项点击区天然达标，**不需要**光学放大 hitTest。
 *
 * ⚠️ 它是**页面正文**里的容器 ⇒ 从 HarmonyOS 7 起不在沉浸光感的生效范围内（`坑 245`）。
 *  本机的官方 Tabs 底栏路线已实测 Δ+0.0（见文件头表格），所以这里**刻意**走自绘 —— 这是结论，不是遗漏。
 */
@Component
export struct AaBottomNav {
  /** 当前选中项的 `key`（默认 `home`）。 */
  @Prop active: string = 'home';
  /**
   * 点选回调。`home` 也会回调 —— 由调用方判断是否已经在首页、要不要重复入栈。
   *
   * ⚠️ 默认给空实现（ArkTS 里函数类型属性必须初始化），调用方不传也不会崩。
   */
  onSelect: (key: string) => void = () => {
  };

  build() {
    Row() {
      // ⚠️ ForEach 的 key **必须含会变字段**（坑 38/52）：`active` 一变，
      //  选中态若只写在 item 的 build 里，ForEach 不会重建子项 ⇒ 选中态不刷新。
      //  把 active 编进 key 是本法里最直接的解法（四项、代价可忽略）。
      ForEach(BOTTOM_NAV_ITEMS, (item: BottomNavItem) => {
        Column({ space: Space.XS }) {
          // R90-T4：回退档（自绘胶囊）的选中色**必须与官方档一致** —— 否则
          //  两档切换时选中项颜色会变（同一个语义、两套颜色是最典型的"漂移"来源）。
          AaIcon({
            d: ICONS[item.icon],
            iconSize: BOTTOM_NAV_ICON_SIZE,
            color: item.key === this.active ? bottomNavActive() : muted()
          })
          Text(item.label)
            .fontSize(FontSize.CAPTION)
            .fontColor(item.key === this.active ? bottomNavActive() : muted())
            .maxLines(1)
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // 无障碍：整项可点，语义由 label 承担（读屏与 dumpLayout 都靠它）。
        .accessibilityText(item.label)
        .onClick(() => {
          this.onSelect(item.key);
        })
      }, (item: BottomNavItem) => `${item.key}:${item.key === this.active ? 1 : 0}`)
    }
    .width('100%')
    .height(BOTTOM_NAV_HEIGHT)
    // ⚠️ 全圆角胶囊：半径 = 高/2（R67 起高 54 ⇒ r = 27；参考图实测 r = 81.5px = 高/2 ✔）。
    // **只动几何**，颜色 / 模糊令牌一个没碰 ⇒ R63/F1 的 Δ 判据（胶囊内 vs 带外）不受影响。
    .borderRadius(BOTTOM_NAV_HEIGHT / 2)
    .backgroundEffect({
      // R69：底栏专用的更强模糊（18）—— 参考图那层「背后内容被糊住」在 B 档就靠它。
      radius: BOTTOM_BAR_BLUR_RADIUS,
      saturation: GLASS_SATURATION,
      brightness: GLASS_BRIGHTNESS,
      // ⚠️ R63/F1 定点修复：**不是** `glassSurface()`（浅色 25% 近白 ⇒ 叠在近白页面上与背景逐点相同、
      //  底栏在浅色档整体不可见，模拟器实测 252.1 vs 252.1）。改用底栏专属档 `glassNavSurface()`
      //  （浅色 7.8% 黑纱 ⇒ Δ ≈ −19.7，深色与 `glass_surface` 同值 ⇒ 深色观感逐像素不变）。
      //  依据与取值推导见 `Design.ets` 的 `glassNavSurface()` 注释 + 开发期验证记录 §9 F1。
      //  真机复核（R65-D）：深色 胶囊带 25.2 vs 带外 9.2 = **Δ+16.0**，与 R63 首测同档。
      color: glassNavSurface()
    })
    // R63（SPEC §2.3-3）：加**同源渐变光层** + 亮边，让底栏与顶栏 / 功能钮是同一套观感。
    // 令牌与 `ui/GlassIcon.ets` 的 ② 层逐字同源（`GlassSpec.SHEEN_ANGLE` / `SHEEN_MID_STOP` +
    // `glassSheenHigh/Mid/Clear()`，终点是同 RGB、alpha=0 的 clear 色）；亮边取圆钮亮环峰值档
    // `glassRimHigh()`（原来是通用描边 `borderColor()`）。**不写径向环**（亮环唯一实现在 GlassIcon.ets）。
    // ⚠️ 渐变与磨砂挂在**同一条胶囊节点**上：底栏宽度 = 屏宽（`width('100%')`），
    //  再插一个铺满型装饰兄弟层只会多一个要 `hitTestBehavior(None)` 的节点，
    //  而同节点的 background → linearGradient → border 绘制序已经给出正确层序。
    .linearGradient({
      angle: GlassSpec.SHEEN_ANGLE,
      colors: [
        [glassSheenHigh(), 0.0],
        [glassSheenMid(), GlassSpec.SHEEN_MID_STOP],
        [glassSheenClear(), 1.0]
      ]
    })
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(glassRimHigh())
  }
}

/* ==========================================================================================
 * ⚠️ **T2/task-1 改判**：以下官方 Tabs 底栏基建**重新成为交付路径**（`BOTTOM_TABS_OFFICIAL_MATERIAL`
 *  本轮起默认 `true`）—— 理由与**不得抹掉的反对材料**（R65-D 的真机 Δ+0.0 及该实验的假阴性风险）
 *  都写在 `BOTTOM_TABS_OFFICIAL_MATERIAL` 的注释里，改默认前先读那一段。
 *  它们由 R65-D 标过 DEPRECATED，但代码本身一直是完整的（编译通过、接线正确），
 *  所谓「已否决」只针对「本机型这个位置不出表面」这一条实测结论。
 * ========================================================================================== */

/**
 * 底栏走官方沉浸材质还是只留官方 blur —— **默认 `true`（T2/task-1 起）**。
 *
 * ## 为什么本轮把它从 `false` 翻成 `true`（用户诉求：「功能栏模糊与沉浸光感用官方材质」）
 * ① **位置在生效范围内**：`pages/Index.ets` 的 `topLevelTabs()` 是横向 `Tabs` 且
 *  `barPosition: BarPosition.End` ⇒ 命中官方四类生效位置的第 ④ 类（`坑 245`）；
 * ② **入口就是官方的那个**：底栏材质**只有** `FloatingTabBarStyle.systemMaterial` 一条路
 * （`tabs.d.ts:895`，挂载点 `barFloatingStyle()` `tabs.d.ts:1683`；**不在 `TabsOptions` 里**，`坑 246`）；
 * ③ 翻之前，交付路径（路线 A）**只发官方 blur、不发官方材质** —— 等于「用了官方组件的模糊，没用官方材质」，
 *  正是用户要修的那件事。
 *
 * ## ⚠️ 不得抹掉的反对材料（R65-D 的真机否决）
 * `Mate70 Pro+` 深色实测：官方材质档 **Δ+0.0**、官方 Tabs + 自绘磨砂 **Δ+0.0**、
 * **自绘胶囊 Δ+16.0**（表见文件头）；同一次构建里顶栏位置的官方材质 MAE 有 5.16~8.44。
 * ⚠️ 但该实验有**已记录的假阴性风险**：那次 bar 是**独立布局带**（TabContent 裁到 2556、bar 2555~2832）
 * ⇒ bar 背后是均匀纯色，而材质是折射/模糊材质，**背后无内容时它本来就长得和背景一样**
 * （同一条也写在文件头 R65 的说明里）。
 * ⇒ 本轮改的是**默认值**（让交付路径发材质），**不宣称**「真机上一定出像素」——
 *  开发期验证记录的结论按「模拟器可见 / 真机未验证」标注。
 *
 * ## 回退（一行）
 * 真机上若看到材质画出**带硬边的一条**（同 R77 在会话详情页测到的「标题栏/时间栏分界」），
 * 把本常量改回 `false` 即可 —— 那条路已经跑过一整轮，代码完整。
 */
export const BOTTOM_TABS_OFFICIAL_MATERIAL: boolean = true;

/**
 * 官方 Tabs 底栏是否用「悬浮 bar」形态（`barFloatingStyle`）—— **交付路径默认 `true`**。
 *
 * ⚠️ 官方底栏材质字段（`systemMaterial`）**就长在 `FloatingTabBarStyle` 这个对象里**
 * （`tabs.d.ts:895`；见 `坑 246`）⇒ 关掉它**同时失去官方材质与栏宽**，
 * 只用于隔离「悬浮几何对不对」，别把它当材质 A/B 的对照包。
 *
 * 真机实测它在本机型**没生效**（四个 item 仍横铺满宽）。⚠️ 官方材质字段（`systemMaterial`）就在
 * `FloatingTabBarStyle` 里 ⇒ 关掉它**同时也失去官方材质**，只用于隔离「悬浮几何对不对」。
 */
export const BOTTOM_TABS_FLOATING_BAR: boolean = true;

/**
 * 顶层四页在 `BOTTOM_NAV_ITEMS` 里的下标；不是顶层页返回 `-1`。
 * 官方 Tabs 路径用它把路由映射成 `TabContent` 的次序（复跑步骤 1/2 要用）。
 */
export function bottomNavIndex(route: string): number {
  let i: number = 0;
  while (i < BOTTOM_NAV_ITEMS.length) {
    if (BOTTOM_NAV_ITEMS[i].route === route) {
      return i;
    }
    i = i + 1;
  }
  return -1;
}

/**
 * 官方底栏材质实例（`.barFloatingStyle({ systemMaterial: … })` 的实参）—— **交付路径的材质本体**。
 *
 * ## ⚠️ 入口位置的实证更正（R65-C 编译期证伪 + SDK 逐行复核）
 * `systemMaterial` **不在 `TabsOptions` 里**：`tabs.d.ts` 的 `declare interface TabsOptions` 到 **L596** 结束
 * （成员只有 `barPosition / index / controller / barModifier / strokeWidth / color / startMargin / endMargin`）；
 * `tabs.d.ts:895` 的 `systemMaterial?: UIMaterial.ImmersiveMaterial` 属于
 * **`interface FloatingTabBarStyle`（L824-896）**，挂载点是
 * `TabsAttribute.barFloatingStyle(style: Optional<FloatingTabBarStyle>)`（**L1683**）。
 * 写进 `TabsOptions` 会被 ArkTS 直接拒编译（原文：`'systemMaterial' does not exist in type 'TabsOptions'`）。
 *
 * · `materialColor` 复用 `glassNavSurface()`（带透明度 —— 官方要求「完全 opaque 会挡死滤镜」）；
 * · `lightEffect` **不传**：`坑 13` 真机上会在顶缘合成一条锐利贯穿亮线。
 */
export function bottomBarMaterial(): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: glassNavSurface(),
    colorInvert: false,
    // ⚠️ R70 H3 一行开关：真机若量到「节点 bounds ≈162px 但像素视觉外沿 ≈213px」，
    //  说明胶囊的**视觉**高度被官方阴影 + 模糊外溢撑大 ⇒ 这里切 false 再量。
    applyShadow: BOTTOM_BAR_MATERIAL_SHADOW,
    interactive: true
  });
}

/**
 * 官方 Tabs 底栏的**自绘磨砂档**（`BOTTOM_TABS_OFFICIAL_MATERIAL === false` 时用；本轮默认档不走它）。
 *
 * 令牌与 R63/F1 的胶囊同源（`glass_nav_surface`）；模糊三参数与 `AaBottomNav` 一字不差
 * （`坑 74`：玻璃只用 `backgroundEffect`）。它挂在 **bar** 上（`.barBackgroundEffect()`），
 * 与挂在页面正文里的 `AaBottomNav` 是**两个不同位置** —— 真机上底栏位置两档都是 Δ+0.0，
 * 所以回退用的是能出 +16.0 的后者。
 */
export function bottomBarBackgroundEffect(): BackgroundEffectOptions {
  return {
    radius: GLASS_BLUR_RADIUS,
    saturation: GLASS_SATURATION,
    brightness: GLASS_BRIGHTNESS,
    color: glassNavSurface()
  };
}

/**
 * 官方 Tabs 底栏的单项（`TabContent.tabBar()` 的自定义内容）—— **交付路径在用**。
 *
 * 选中态读**自己的** `@StorageLink(ROUTE_KEY)`（不依赖父级是否重跑 tabBar builder）——
 * 这是 `坑 101`（`index` 只是受控入参、用户点 bar 不会自动写回）的正解。
 * 按压反馈用 `stateStyles` 的 **scale**（不用 `brightness` —— `坑 241` 真机上会把矩形区域提亮成方块）。
 */
@Component
export struct AaBottomTabItem {
  /** 入口 key（`BOTTOM_NAV_ITEMS[].key`），只用于判选中。 */
  @Prop itemKey: string = 'home';
  @Prop label: string = '';
  /** `ICONS` 里的图标名。 */
  @Prop icon: string = 'house';
  @StorageLink(ROUTE_KEY) route: string = Route.LOGIN;

  /** 当前路由是否就是本项的目的地。 */
  private active(): boolean {
    const index = bottomNavIndex(this.route);
    return index >= 0 && BOTTOM_NAV_ITEMS[index].key === this.itemKey;
  }

  build() {
    Column({ space: Space.XS }) {
      // ## R90-T4（用户：「底部功能栏增加被选中的页面图标变绿」）
      // 选中项 = **绿色**（`bottomNavActive()`，导航态专属令牌）；
      // 未选中仍是 `muted()`。图标与文字**用同一个色**，否则选中项会显得"半亮"。
      // ⚠️ 换掉的是原来的 `primaryAction()`（浅色档是近黑 #0A0A0B、深色档是近白 #FAFAFA）
      //  —— 它作"选中态"与「未选中的 muted 灰」对比不够、也容易被误读成"只是黑了点"。
      AaIcon({
        d: ICONS[this.icon],
        iconSize: BOTTOM_NAV_ICON_SIZE,
        color: this.active() ? bottomNavActive() : muted()
      })
      Text(this.label)
        .fontSize(FontSize.CAPTION)
        .fontColor(this.active() ? bottomNavActive() : muted())
        .maxLines(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .accessibilityText(this.label)
    .stateStyles({
      normal: {
        .scale({ x: 1, y: 1 })
      },
      pressed: {
        .scale({ x: 0.94, y: 0.94 })
      }
    })
    .animation({ duration: 120, curve: Curve.EaseOut })
  }
}
