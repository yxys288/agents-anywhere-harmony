/**
 * 设备页（顶层目的地；对应 Android `ui/screens/devices/DevicesScreen.kt`，570 行）。
 *
 * 复刻要点（上游实现 开发期验证记录 + 形态①）：
 * - 骨架：`Box(canvas) → Column → 顶栏 + 可下拉刷新的列表`；
 * - 顶栏是**形态① 通用页顶栏**：行高 64dp、水平内边距 18dp、40dp 圆形返回钮（1dp 边框）+
 *  间距 12dp + 标题 17sp SemiBold；本页是顶层目的地（从首页快捷卡片进）⇒ **不画返回钮**，
 *  与上游 `onBack = null` 的行为一致；
 * - 列表：`padding(horizontal = 24dp)` + `spacedBy(10dp)` + `contentPadding(top 8 / bottom 28)`；
 * - **第一行恒为「添加新设备」行**（上游 item key = `add-device`），设备为空时它下面才是空态；
 * - 设备行 60dp / 圆角 15dp / 图标 42dp / 名称 17sp SemiBold / 状态标签 13sp / 副文 13sp；
 *  副文是 Agent 预览（`deviceAgentPreviewLabel`），数据源与上游同一口径（`listDeviceRuntimes`）。
 *
 * 排序走纯函数 `sortedForDevicesPage`（在线优先 → createdAt → 名称），已进 Node 单测。
 */

import { DashboardStore } from '../../feature/DashboardStore';
import { AgentDevice } from '../../model/AppModels';
import { DeviceAgentState, DeviceStore, deviceAgentPreviewLabel, sortedForDevicesPage } from '../../feature/DeviceStore';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, faint, ink, muted,
  raisedSurface, rowPressedSurface
} from '../Design';
// R66（SPEC §2）：标题栏（功能栏）本体的**官方沉浸材质**走本工程唯一构造入口
// `Components.ets#officialBarMaterial(color)`（页面不直接引入 `uiMaterial`）。
import { AaCircleIconButton, AaEmptyState } from '../Components';
import { Route, Router } from '../Router';
import { AaIcon, ICONS } from '../Icon';
import { BOTTOM_BAR_RESERVED_VP } from '../BottomNav';
import { isDarkAppearance } from '../../feature/AppServices';

/** 一台设备的 Agent 预览（对应上游 `DeviceAgentPreviews.byDeviceId` 的一个条目）。 */
interface DevicePreviewEntry {
  deviceId: string;
  state: string;
  count: number;
}

@Component
export struct DevicesScreen {
  @State devices: AgentDevice[] = [];
  @State previews: DevicePreviewEntry[] = [];
  @State errorText: string = '';
  @State isRefreshing: boolean = false;

  private store: DashboardStore = DashboardStore.get();
  private storeListener: () => void = () => {
    this.pull();
  };

  aboutToAppear(): void {
    this.store.onChange(this.storeListener);
    this.pull();
    // 进页面就拉一次设备列表（首页可能还没同步过）；已在刷新的会话不重复拉。
    if (this.store.devices.length === 0) {
      this.refresh();
    }
  }

  aboutToDisappear(): void {
    this.store.offChange(this.storeListener);
  }

  /** store → @State 快照（build 只读这些字段）。 */
  private pull(): void {
    this.devices = sortedForDevicesPage(this.store.devices);
    this.errorText = this.store.error;
    this.loadPreviews();
  }

  /**
   * 刷新设备列表（**进页自动拉一次** + **下拉刷新**两个入口共用）。
   *
   * ## R89 修复（用户：「设备页刷新状态不会结束」）
   * 这里修的是**第二层**问题（失败分支）；**第一层**是 `build()` 里的 `Refresh` **没有 `.onRefreshing`**
   * —— 下拉时框架把 `isRefreshing` 置 `true` 后无人置回，圆圈**永远转**（那才是用户看到的现象，
   * 见 build() 里那段注释）。
   * 本函数的旧写法还有第二个坑：`refreshDevices().then(() => { this.isRefreshing = false; … })`
   * 是**裸 then、没有 catch** —— `refreshDevices()` 在请求失败时 reject（断网 / 401 / 连接器离线都是常见路径），
   * 于是 `then` 的回调**根本不执行** ⇒ 指示器同样收不掉（这条路径由 `aboutToAppear` 触发）。
   * ⇒ 用 `finally` 收尾：成功 / 失败都要把 `isRefreshing` 置回 `false`（`Refresh` 的约定）。
   */
  private refresh(): void {
    this.isRefreshing = true;
    this.store.refreshDevices().then(() => {
      this.pull();
    }).catch(() => {
      // 失败也要收指示器；错误文案由 `store.error` 走 `pull()` 同步到 `errorText`。
      this.pull();
    }).finally(() => {
      this.isRefreshing = false;
    });
  }

  private previewOf(deviceId: string): DevicePreviewEntry | undefined {
    for (let i = 0; i < this.previews.length; i++) {
      if (this.previews[i].deviceId === deviceId) {
        return this.previews[i];
      }
    }
    return undefined;
  }

  /**
   * 给**在线**设备各拉一次运行时列表（上游 `rememberDeviceAgentPreviews` 同一做法）。
   *
   * 已经拿到过的条目保持不动（上游 `beginRefresh` 对 `Loaded` 的条目也保持不变），
   * 避免每次 store 变化都把 N 台设备重拉一遍。
   */
  private loadPreviews(): void {
    const next: DevicePreviewEntry[] = [];
    const pending: string[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (!device.online) {
        continue;
      }
      const existing = this.previewOf(device.id);
      if (existing !== undefined && existing.state === DeviceAgentState.LOADED) {
        next.push(existing);
      } else {
        const loading: DevicePreviewEntry = {
          deviceId: device.id, state: DeviceAgentState.LOADING, count: 0
        };
        next.push(loading);
        pending.push(device.id);
      }
    }
    this.previews = next;
    for (let i = 0; i < pending.length; i++) {
      this.fetchPreview(pending[i]);
    }
  }

  private async fetchPreview(deviceId: string): Promise<void> {
    const count = await DeviceStore.onlineAgentCountFor(deviceId);
    const state = count >= 0 ? DeviceAgentState.LOADED : DeviceAgentState.UNAVAILABLE;
    const next: DevicePreviewEntry[] = [];
    for (let i = 0; i < this.previews.length; i++) {
      const entry = this.previews[i];
      if (entry.deviceId === deviceId) {
        next.push({ deviceId: deviceId, state: state, count: count >= 0 ? count : 0 });
      } else {
        next.push(entry);
      }
    }
    this.previews = next;
  }

  private previewLabel(device: AgentDevice): string {
    const entry = this.previewOf(device.id);
    const state = entry !== undefined ? entry.state : DeviceAgentState.LOADING;
    const count = entry !== undefined ? entry.count : 0;
    return deviceAgentPreviewLabel(device.online, state, count);
  }

  /**
   * ⚠️ **R65-B 删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）。
   *
   * R37 五改的本意是「顶栏背景铺到屏幕顶、状态栏那一条也一起糊」。但顶栏一旦进入 `Navigation`
   * 标题栏，**高度与位置由框架接管**：真机 `dumpLayout` 实测标题栏落在 `[0,137][1316,332]`
   * （`HomeScreen` R62 的实测记录）—— 页面根节点**已经在状态栏之下**，顶栏再避让一次就是
   * **重复避让 137px**。而且原来读的是 `AppStorage.get(SAFE_AREA_TOP_PX)` 这个**非响应**读取，
   * 值随冷启动时序在 `0 / 46vp` 之间跳（R61 实测：同一份包两次冷启动顶栏行高 136px / 274px）。
   * ⇒ 本页按 R65-B 固定**不避让**，与 `HomeScreen`（R62）同一口径。
   *
   * **R65-B：本页标题栏** —— `Navigation.title(...)` 的自定义构造器，内容只有**顶栏一行**。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End` 的
   * 底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1/§2）。
   */
  @Builder
  navTitleBar() {
    // 顶栏：返回钮**必须有** —— 上游 `DevicesScreen.kt:229-257 DevicesHeader` 是 `if (onBack != null)`
    // 才画 `Lucide.ChevronLeft` 圆钮，而 `AgentsAnywhereNavHost.kt:307-315` 给设备页**总是**传
    // `onBack = { navigate(AppDestination.Sessions) }` ⇒ 安卓一定有。（R13-3 当年判「顶层目的地不画
    // 返回钮」，已被这两条锚文证伪。）
    // 圆钮规格照上游：40dp 圆 + 1dp 描边 + chevron-left 22dp + `raisedSurface` 底 + 间距 12。
    Row({ space: Space.M }) {
      // R57（T2b）：玻璃档。`surface` / `ringColor` 在玻璃档下不参与（玻璃盘自带底与亮边），
      // 但**保留传参**：玻璃档缺省 false 时它们仍是这一处的正确定义（回退只需删 `glass: true`）。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        tint: ink(),
        surface: raisedSurface(),
        ringColor: borderColor(),
        glass: true,
        // R65-B：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内（`坑 245`），
        // 返回钮改走官方 `ImmersiveMaterial`（官方分支零自绘层：无 backgroundEffect / 渐变 / 描边）。
        officialMaterial: true,
        accessibilityLabel: '返回',
        onTap: () => {
          // 上游返回目标是硬编码的 Sessions（首页），不是「回上一页」（`Router.back()` 的说明）。
          Router.back();
        }
      })
      Text('设备')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），64vp → 262px（低 27px）。
    // ⚠️ 同时保留 R65 的口径：栏高**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .alignItems(VerticalAlign.Center)
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**。
    //  真机深色实测（Mate70 Pro+ / 7.0.0.109；读数
    //  开发期验证记录）：挂官方材质的栏本体在深色下画出
    //  比正文亮 **+19.0** 的一整条「带」（栏底色 28.7 vs 正文 9.67，左右边缘纯底色采样），
    //  边界肉眼可见；而首页（栏本体零材质）同口径读数是 **+0.00**。
    //  ⇒ 与 R77 对 `SessionDetailScreen` 的处置同构：**光效只留在栏内控件（返回钮等）上，栏本体不挂**。
    //  同源坑：`坑 250`（官方材质会画出带缘高光的「带」，相邻两块各挂一层就是分界）。
    //  ⚠️ 历史（不要抹掉）：R66 曾按「功能栏本体换官方材质」执行 —— 本行那时是
    //  `.systemMaterial(officialBarMaterial(glassSurface()))`，R87 因观感投诉撤回。
    //  ⚠️ 也**不**加 `scrollEffectOptions`：本页是 STANDARD（标题栏占位、内容不从栏背后穿过），
    //  滚动遮罩没有可糊的内容；且 R77 真机实测过它会生成越过标题栏的 `TitleBarMaskBlur`
    //  把下方内容洗淡（`坑 249`）。
  }

  build() {
    // R65-B（设计规格 §2）：顶栏从正文里**提到 `Navigation` 标题栏**。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容之上方**、占自己一行）而不是 `STACK`：
    //  `STACK` 会把标题栏**叠在内容上**，那就必须自己给内容让位（`contentStartOffset` 那套），
    //  而 设计规格 §2 明确要求「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
    //  ⇒ STANDARD 下内容天然落在标题栏下方，首屏不会被顶栏压住。
    Navigation() {
      Column() {
        Refresh({ refreshing: $$this.isRefreshing }) {
          Scroll() {
            Column({ space: Space.S_PLUS }) {
              this.addDeviceRow()
              if (this.devices.length === 0) {
                AaEmptyState({
                  message: this.errorText.length > 0 ? this.errorText : '还没有设备。添加一台设备开始配对。'
                })
                  .height(Control.EMPTY_TALL)
              } else {
                ForEach(this.devices, (device: AgentDevice) => {
                  this.deviceRow(device)
                }, (device: AgentDevice) => `${device.id}:${device.online}:${device.name}:${this.previewLabel(device)}`)
              }
            }
            .width('100%')
            // ⚠️ R66-3：尾部内边距 = 原有呼吸留白 + **浮层底栏预留**（底栏不占布局后必须自己留）。
          .padding({
            left: Space.XL, right: Space.XL, top: Space.S,
            bottom: Space.PAGE_BOTTOM + BOTTOM_BAR_RESERVED_VP
          })
            .alignItems(HorizontalAlign.Start)
          }
          // ⚠️ R37（真机发现，用户报的「底部内容显示不完全」）：`Scroll` **必须** `layoutWeight(1)`。
          // 只写 `width('100%')` 时它的高度按**内容**撑开 ⇒ 设备一多就撑过屏幕、被 `Refresh` 裁断，
          // 而 Scroll 自身的视口 = 内容高 ⇒ **既不显示、也滚不到**。
          // 上游 `DevicesScreen.kt:111-132` 是 `PullToRefreshBox(...weight(1f))` 内套 `LazyColumn(fillMaxSize)`。
          // ⚠️ 实测：`layoutWeight(1)` 在 `Refresh` 内**不生效**（Scroll 仍停在内容高 819）⇒ 用 `height('100%')`。
          // 父 `Refresh` 自身是 `layoutWeight(1)`（有确定高度），所以百分比高度是安全的。
          .height('100%')
          .width('100%')
          .scrollBar(BarState.Off)
          // 通用属性 `align` 默认 Center：内容短于视口会被垂直居中（防御性显式声明）。
          .align(Alignment.Top)
        }
        .layoutWeight(1)
        .width('100%')
        // ## R89 修复（用户：「设备页刷新状态不会结束」）—— **真正的根因在这里**：
        // 本 `Refresh` 只有 `refreshing: $$this.isRefreshing` 的**双向绑定**、**没有 `.onRefreshing`** ⇒
        // 用户下拉时框架把 `isRefreshing` 置成 `true`，而**没有任何代码把它置回 `false`**
        // ⇒ 刷新圆圈**永远转下去**（全工程只有两处 `Refresh`：首页有 `onRefreshing`，
        //  **只有本页漏了**，所以只有设备页会卡）。
        // ⚠️ 与 `refresh()` 里的 `finally` 是**两件不同的事**，缺任何一个圆圈都停不下来：
        //  · `.onRefreshing` = 「下拉动作本身要有人响应」（本处，缺了则**永不结束**）；
        //  · `refresh()` 的 `catch/finally` = 「请求失败也要收指示器」（`aboutToAppear` 那条路径会走到）。
        .onRefreshing(() => {
          this.refresh();
        })

      /**
       * R66-3：底栏**已上移到 `pages/Index.ets` 的浮层**（用户要的那张截图 = 浮在内容之上的半透明胶囊），
       * 本页不再挂 `AaBottomNav`。
       *
       * ⚠️ 配套：浮层**不占布局** ⇒ 内容会铺到屏幕下缘、从胶囊背后滚过去，
       *  所以下面那个 `Scroll` 的内容尾部内边距要**自己留出底栏那一条**
       *  （`BOTTOM_BAR_RESERVED_VP`），否则末行的「⋯」会停在胶囊背后滚不出来。
       */
      }
      .width('100%')
      .height('100%')
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
    .backgroundColor(canvas())
  }

  /** 第一行：添加新设备（上游 `AddDeviceRow`，60dp / 圆角 15 / 图标底 42dp）。 */
  @Builder
  addDeviceRow() {
    // 上游 `AddDeviceRow`（`DevicesScreen.kt:289-343`）：`Spacer(Modifier.width(**11.dp**))`
    // ⚠️ R34：原写 `Space.S_PLUS`(10)，比上游少 1dp。
    Row({ space: 11 }) {
      Column() {
        AaIcon({ d: ICONS['plus'], iconSize: FontSize.ICON_XL, color: ink() })
      }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width(Control.DEVICE_ICON)
        .height(Control.DEVICE_ICON)
        .borderRadius(Radius.M)
        // 上游 `:316`：`background(if (darkMode) Color(0xFF27272A) else Color(0xFFF3F2EF))`
        // ⚠️ R34：原写 `subtle()`（浅 #F1F0ED / 深 #292929）—— 两个值都与上游不同。
        .backgroundColor($r('app.color.device_icon_surface'))
      // 上游 `:327-336`：`17.sp / SemiBold / lineHeight 21.sp`（工程无 SemiBold ⇒ 取 Bold）
      // ⚠️ R34：原写 Medium 且缺 lineHeight。
      Text('添加新设备')
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)
        .lineHeight(21)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.ICON, color: faint() })
    }
    .width('100%')
    .height(Control.ROW_DEVICE)
    .padding({ left: Space.M, right: Space.S })
    .borderRadius(Radius.M_PLUS)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .onClick(() => {
      Router.push(Route.ADD_DEVICE, '');
    })
  }

  /** 设备行（上游 `DeviceRow`，60dp / 圆角 15 / 图标 42dp）。 */
  @Builder
  deviceRow(device: AgentDevice) {
    // 上游 `DeviceRow`（`DevicesScreen.kt:365-420`）：`Spacer(Modifier.width(**11.dp**))`
    // ⚠️ R35：原写 `Space.S_PLUS`(10)，比上游少 1dp（与「添加新设备」行同一处笔误）。
    Row({ space: 11 }) {
      // 上游 `DevicesScreen.kt:388` 的 `DeviceIcon`：42dp 位图（`painterResource(deviceIconRes(...))`）。
      // ⚠️ 位图**自带圆角底色**（在线黑底/离线灰底），所以这里不要再叠 `subtle()` 底与圆角 ——
      //  叠了会在图标后面多出一个灰方块；离线的「变淡」也由 `_offline` 那张图自己表达，不另加 opacity。
      Image(this.deviceIconRes(device))
        .width(Control.DEVICE_ICON)
        .height(Control.DEVICE_ICON)
      // 上游 `:390-392` 是 `Column(verticalArrangement = Arrangement.**Center**)` —— **没有 spacing**，
      // 两行紧贴。⚠️ R35：原写 `space: Space.XXS`(2) 多出 2dp。
      Column() {
        // 上游 `DevicesScreen.kt:394-409`：`Row(spacedBy 8dp) { Text(name, weight(1f, fill = false));
        // DeviceStatusLabel }` —— `fill = false` 让名称**按内容占宽、状态标签紧贴其后**（不是推到行尾）。
        // ArkUI 没有等价的 fill=false，用「百分比上限 + 省略号」等效：长名仍然省略，短名之后立刻跟标签。
        Row({ space: Space.S }) {
          // 上游 `:398-407`：`17.sp / **SemiBold** / **lineHeight 21.sp**`，
          // 色 `online ? (dark ? 0xFFDADADF : 0xFF343436) : colors.muted`。
          Text(device.name)
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Bold)
            .lineHeight(21)
            .fontColor(device.online ? $r('app.color.device_row_title') : muted())
            .constraintSize({ maxWidth: '76%' })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          this.statusLabel(device.online)
        }
        .width('100%')
        // 上游 `:410-419`：`13.sp / Medium / **lineHeight 16.sp**`，色 `meta = dark ? muted : **faint**`，
        // 且宽度是 `fillMaxWidth(**0.84f**)`。
        Text(this.previewLabel(device))
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .lineHeight(16)
          .fontColor(isDarkAppearance() ? muted() : faint())
          .constraintSize({ maxWidth: '84%' })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.ICON, color: faint() })
    }
    .width('100%')
    .height(Control.ROW_DEVICE)
    .padding({ left: Space.M, right: Space.S })
    .borderRadius(Radius.M_PLUS)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    // R39：官方按压态。本行是**卡片形态**（有常驻底色 `raisedSurface()`）⇒ `normal` 必须与链式同值，
    //  不能像透明行那样给 `Color.Transparent`（给了会把卡片底色抹掉）。
    //  单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(raisedSurface()) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      Router.push(Route.DEVICE, device.id);
    })
  }

  /**
   * 在线状态标签（上游 `DevicesScreen.kt:431-455` 的 `DeviceStatusLabel`）：
   * **`Lucide.CircleCheck`（圆圈内打勾）/ `Lucide.Circle`** 16dp + 文字 13sp Medium、间距 6dp，
   * 颜色 `#10B981`（本工程 `app.color.runtime_running`，base 与 dark 两套都是这个值）。
   *
   * ⚠️ 两处按截图核对过的修正（r12 基线 `android-02-devices.jpeg` vs `hm-02-devices.jpeg`，
   * 6 倍放大图见 开发期验证记录）：
   *  ① 上游是**带圈**的 `CircleCheck`，本工程原先用裸 `check`；
   *  ② 上游**没有胶囊底**，就是「图标 + 文字」贴在一起（所以「改成绿色胶囊」这个说法不成立，
   *  真正的差异是**位置**与**图标形状**）。
   */
  @Builder
  statusLabel(online: boolean) {
    Row({ space: Space.XS_PLUS }) {
      AaIcon({ d: online ? ICONS['circle-check'] : ICONS['circle'], iconSize: FontSize.ICON_MD, color: online ? $r('app.color.runtime_running') : muted() })
        .opacity(online ? 1 : 0.4)
      // 上游 `DevicesScreen.kt:445-452`：`13.sp / Medium / **lineHeight 16.sp**`。
      // ⚠️ R36：原缺行高（行框 15.1dp，上游 16dp）。
      Text(online ? '在线' : '离线')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .lineHeight(16)
        .fontColor(online ? $r('app.color.runtime_running') : muted())
    }
  }

  /**
   * 设备图标资源（上游 `DevicesScreen.kt:540` 的 `deviceIconRes`）：按 **OS × 在线状态 × 深浅色** 取图。
   *
   * 12 张位图对应上游 `android/app/src/main/res/drawable-nodpi/device_icon_{light,dark}_{windows,macos,linux}_{online,offline}_3x.png`
   * —— **R56 起本工程为自绘液态玻璃版，不再与上游位图逐字节相同**；上游对照见
   * 开发期验证记录（旧口径「逐字节相同 + r12-icons §8 的 md5」已作废，别再当判据）。
   * 浅色 6 张放 `resources/base/media/`、深色 6 张放 `resources/dark/media/`，**同名**
   * ⇒ 深浅色由鸿蒙的资源限定目录自动切换，代码里不需要也不能判主题。
   * 未知/通用系统落到 linux 图标（取图规则与上游一致）。
   */
  private deviceIconRes(device: AgentDevice): Resource {
    const os = device.deviceOs !== undefined ? device.deviceOs.toLowerCase() : '';
    const online = device.online;
    if (os === 'macos') {
      return online ? $r('app.media.device_icon_macos_online') : $r('app.media.device_icon_macos_offline');
    }
    if (os === 'windows') {
      return online ? $r('app.media.device_icon_windows_online') : $r('app.media.device_icon_windows_offline');
    }
    return online ? $r('app.media.device_icon_linux_online') : $r('app.media.device_icon_linux_offline');
  }
}
