/**
 * 已归档会话（对应 Android `ui/screens/home/ArchivedSessionsScreen.kt` +
 * `ArchivedSessionComponents.kt` / `ArchivedProjectPicker.kt`）。
 *
 * 复刻口径见 开发期验证记录：
 *  topBar 64dp/17sp → 项目筛选器（锚定弹层）→ 五种状态分派 → 按项目分组列表（整组一张卡）。
 *
 * ⚠️ 三条易错点（上游实现）：
 *  ① 归档时间用 `archivedAt ?: sortKey`，解析失败要显示兜底文案；
 *  ② 「列表为空但服务端还有更多」是**独立状态**（文案 +「继续加载」），不等于「没有归档」；
 *  ③ 切换项目筛选时整列重建（ForEach 的 key 带上筛选值）。
 */

import { DashboardListener, DashboardStore, SessionGroup } from '../../feature/DashboardStore';
import { AgentProject, AgentSession } from '../../model/AppModels';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, errorText, faint, ink, inkSoft, muted,
  raisedSurface, rowPressedSurface, subtle
} from '../Design';
import { AaCircleIconButton, AaMenuActionRow, AaSecondaryButton } from '../Components';
import { Route, Router } from '../Router';
import {
  ArchivedStateInput, ArchivedStateKind, ArchivedStateText, archivedStateOf, archivedTimeLabel
} from '../../model/ArchivedPaging';
import { AaIcon, ICONS } from '../Icon';

/** 筛选器「全部项目」的哨兵值（项目 id 是服务端 uuid，不会与它相撞）。 */
const FILTER_ALL: string = '__all__';
/** 筛选弹层的锚点（与终端页设备菜单同款：卡片绝对定位在筛选器下方）。 */
const MENU_LEFT: number = Space.PAGE;
/**
 * 筛选菜单卡片的锚点（相对**内容区**左上角，即 `rootStack` 的坐标系）。
 *
 * ⚠️ **R65-A 改口径**：顶栏已从正文提到 `Navigation.title(...)` 的**框架标题栏**里
 * （缺省 `BarStyle.STANDARD` ⇒ 内容区起始点由框架让到标题栏之下），所以原来那项
 * `Control.TOP_BAR_PAGE`（64vp 的自绘顶栏高）**必须去掉** —— 否则菜单会整体下移一整条顶栏高。
 * 现在是「内容区顶部 →（首个子节点 = 筛选器的 `Space.M` 上内边距）→ 筛选器
 * `Control.FIELD_LARGE` → `Space.S` 间距」，与 `build()` 里内容列的排布一一对应。
 */
const MENU_TOP: number = Space.M + Control.FIELD_LARGE + Space.S;

@Component
export struct ArchivedSessionsScreen {
  // 状态必须在 build 里被真正读到才会触发刷新（见 HomeScreen 顶部注释）。
  @State archived: AgentSession[] = [];
  @State projects: AgentProject[] = [];
  /** 当前筛选后的分组（build 只读它，store 数据在 pull() 里拷进来）。 */
  @State groups: SessionGroup[] = [];
  /** 当前筛选的项目 id（`FILTER_ALL` = 全部项目）。 */
  @State projectFilter: string = FILTER_ALL;
  /** 筛选弹层是否展开。 */
  @State filterOpen: boolean = false;
  /** 首屏加载态与首屏错误（状态面板的前两支）。 */
  @State loading: boolean = false;
  @State loadError: string = '';
  /** 恢复（取消归档）进行中：这个期间筛选器不可点，避免中途切项目打断。 */
  @State mutating: boolean = false;
  @State busySessionId: string = '';
  @State busyProjectId: string = '';
  // 底部「加载更多」的展示状态（同 §0：build 只读 @State）。
  @State showLoadMore: boolean = false;
  @State loadingMore: boolean = false;
  @State pageError: string = '';

  private store: DashboardStore = DashboardStore.get();
  /** 存成字段才能被 `offChange` 摘除（单例 store 的监听器数组只增不减）。 */
  private storeListener: DashboardListener = () => {
    this.pull();
  };
  /** 页面是否还活着：恢复 / 加载更多这类异步链路返回后要复查。 */
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    this.store.onChange(this.storeListener);
    this.pull();
    if (this.store.archivedSessions.length === 0) {
      this.store.refreshAll();
    }
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.store.offChange(this.storeListener);
  }

  /** store -> @State 快照（build 只读这些字段）。 */
  private pull(): void {
    this.archived = this.store.archivedSessions.slice();
    this.projects = this.store.projects.slice();
    // 筛选目标消失（项目被删掉/改名后不在列表里）→ 自动回到「全部项目」。
    if (this.projectFilter !== FILTER_ALL && this.projectFilter.length > 0
      && !this.hasProject(this.projectFilter)) {
      this.projectFilter = FILTER_ALL;
    }
    this.groups = this.visibleGroups();
    this.loading = this.store.loading;
    this.loadError = this.store.error;
    this.showLoadMore = this.store.showLoadMore(true);
    this.loadingMore = this.store.loadingMore(true);
    this.pageError = this.store.loadMoreError(true);
  }

  private hasProject(projectId: string): boolean {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].id === projectId) {
        return true;
      }
    }
    return false;
  }

  /** 按项目分组的可见列表（筛选生效时只留该项目）—— 分组/排序复用 store 的既有实现。 */
  private visibleGroups(): SessionGroup[] {
    const all = this.store.groupedSessions(true);
    if (this.projectFilter === FILTER_ALL) {
      return all;
    }
    const out: SessionGroup[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].projectId === this.projectFilter) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /** 筛选器上显示的当前项目名（上游 `ArchivedProjectSelector`）。 */
  private filterLabel(): string {
    if (this.projectFilter === FILTER_ALL) {
      return '全部项目';
    }
    if (this.projectFilter.length === 0) {
      return '未分组会话';
    }
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].id === this.projectFilter) {
        return this.projects[i].name;
      }
    }
    return '全部项目';
  }

  /**
   * 状态面板的判定输入（摊平成标量后交给 `model/ArchivedPaging.ets` 的纯函数分派）。
   * 五个分支的顺序（list → loading → error → more → empty）在 model 层，已进 Node 单测。
   */
  private stateInfo(): ArchivedStateText {
    const input: ArchivedStateInput = {
      groupCount: this.groups.length,
      loading: this.loading,
      errorText: this.loadError,
      hasMore: this.showLoadMore,
      filtered: this.projectFilter !== FILTER_ALL
    };
    return archivedStateOf(input);
  }

  private runStateAction(): void {
    if (this.stateInfo().kind === ArchivedStateKind.MORE) {
      this.store.loadMore(true);
      return;
    }
    this.store.refreshAll();
  }

  /**
   * 归档时间标签 —— 上游 `archive_archived_at`「归档于 %1$s」+ `yyyy-MM-dd HH:mm`
   * （`ArchivedSessionsScreen.kt:57/173-175`）。判定与格式化都在 `model/ArchivedPaging.ets`（纯函数、已进 Node 单测）。
   *
   * ⚠️ R20 勘误：本工程此前显示的是**相对时间**（`1w`），与上游的绝对时间不一致。
   */
  private timeLabelOf(session: AgentSession): string {
    return archivedTimeLabel(session.archivedAt, session.sortKey);
  }

  /**
   * 恢复单条：成功后 store 会刷新，列表里自然少一条；失败有错误横幅外的分页脚文案兜底。
   *
   * ⚠️ **R92-T5（P2 收口）改前是一个真缺陷，别再改回去**：
   *
   * ```
   * this.mutating = true;
   * await this.store.setSessionArchived(session.id, false);
   * if (!this.alive) { return; } // ← 守卫卡在**清理之前**
   * this.mutating = false; // ← 上面的 return 一命中，这两行永不到达
   * this.busySessionId = '';
   * ```
   *
   * 缺陷链：`await` 期间页面被切走 ⇒ `aboutToDisappear()` 把 `alive` 置 false ⇒ 提前 return ⇒
   * `mutating` 永久为 true。而它**没有任何自愈路径**：本页 `pull()` 不碰它（只搬 store 的快照），
   * `DashboardStore.mutate()`（`DashboardStore.ets:330-347`）也不重置调用方状态 ⇒
   * 只要该组件实例被**复用**（ArkUI 对 `if` 条件渲染的组件在部分路径下会复用而非重建），
   * 筛选器就永久停在 `opacity(0.6)` 且不可点（本文件 `.opacity(this.mutating ? 0.6 : 1)`），
   * 用户再也无法筛选项目。
   *
   * 修法（两条一起才完整）：
   *  ① 清理移进 `try/finally` —— 无论 await 正常返回、被 `return` 打断、还是 store 违约抛错，
   *  `mutating` / `busySessionId` **一定**被复位；
   *  ② `alive` 守卫**上移成入口前置判断** —— 已销毁的组件根本不该发起写请求，
   *  而不是「先发出去、回来了再决定要不要清理」。
   * ⚠️ 给已销毁组件写 `@State` 是安全的（不会崩，只是无意义），所以 finally 里无条件复位没有副作用；
   *  真正会造成「永久卡死」的是**跳过**复位，不是执行复位。
   */
  private async restoreSession(session: AgentSession): Promise<void> {
    if (this.mutating || !this.alive) {
      return;
    }
    this.mutating = true;
    this.busySessionId = session.id;
    try {
      await this.store.setSessionArchived(session.id, false);
    } finally {
      this.mutating = false;
      this.busySessionId = '';
    }
  }

  /**
   * 恢复整个项目下的归档会话（上游分组头右侧按钮）。
   *
   * ⚠️ R92-T5：与 `restoreSession()` **同型缺陷、同型修法**（守卫卡在清理之前 ⇒ `mutating` 永久 true ⇒
   * 整个页面的筛选器与分组头按钮一起变灰）。两处必须成对维护：只改一处 = 另一处仍是死的。
   * 详见 `restoreSession()` 上方那段完整推导，此处不重复。
   */
  private async restoreProject(group: SessionGroup): Promise<void> {
    if (this.mutating || !this.alive || group.projectId.length === 0) {
      return;
    }
    this.mutating = true;
    this.busyProjectId = group.projectId;
    try {
      await this.store.archiveAllForProject(group.projectId, false);
    } finally {
      this.mutating = false;
      this.busyProjectId = '';
    }
  }

  build() {
    // R65-A（设计规格 §2）：顶栏从正文里**提到 `Navigation` 标题栏**。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容区之上**、占自己一行）而不是 `STACK`：
    //  `STACK` 把标题栏**叠在内容上**，那就必须自己给内容让位（`contentStartOffset` 那套），
    //  而 设计规格 §2 明确要求「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
    //  ⇒ STANDARD 下内容天然落在标题栏下方，首屏不会被顶栏压住（本页是唯一按此口径写的次级页之一，
    //  与 R65-B 的 `DevicesScreen` / `FilesScreen` / `TerminalScreen` 逐字同款）。
    Navigation() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          Column({ space: Space.M }) {
            this.projectSelector()
            if (this.stateInfo().kind === ArchivedStateKind.LIST) {
              this.groupList()
            } else {
              this.statusPanel()
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.M })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(canvas())

        if (this.filterOpen) {
          this.projectMenuLayer()
        }
      }
      .width('100%')
      .height('100%')
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
    .backgroundColor(canvas())
  }

  // -------------------------------------------------------------------------
  // 顶栏 + 筛选器
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
   * （高 64 / 水平 18 / 标题 17sp，上游实现 第一行）。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End`
   * 的底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1/§2）。
   */
  @Builder
  navTitleBar() {
    Row({ space: Space.M }) {
      // ⚠️ **R65-A 子决策**：返回钮原来是一个「40×40 命中区 + **裸** 28vp chevron」（无底色、无描边）。
      //  本轮要求本页顶栏的控件也走官方沉浸光感，而官方材质只对**进入生效范围的控件**有意义
      //  ⇒ 这里按 R57（T2b「功能栏液态玻璃化」）的既定口径补成 `AaCircleIconButton` 的**玻璃档**
      //  （其余功能栏返回钮已是玻璃档；本页是当时的漏网之鱼）。
      //  **几何逐字保留**（40vp 圆 / 28vp 图标 / 同一位置），只换材质层 —— 与 R57/T2b 的
      //  「只换材质不换几何」原则一致。「玻璃盘从无到有」是**本轮唯一的观感变更**，
      //  已列入「待 Lead 真机确认」清单。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.NAV_ICON,
        filled: true,
        glass: true,
        // R65-A：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内（`坑 245`）。
        officialMaterial: true,
        accessibilityLabel: '返回',
        tint: ink(),
        onTap: () => {
          // 上游返回目标是硬编码的 Sessions（首页），不是「回上一页」。
          Router.back();
        }
      })
      // 上游 `ArchivedPageHeader`（`ArchivedSessionComponents.kt:48-70`）：
      // 左 40dp 返回钮 + `weight(1f)` 标题（`padding(horizontal 12.dp)`、**TextAlign.Center**）+ 右 40dp 占位
      // ⇒ 标题**严格居中**。⚠️ R20 勘误：本工程此前只写了 `layoutWeight(1)`，标题一直是**左对齐**。
      Text('已归档会话')
        .fontSize(FontSize.TITLE)
        .fontColor(ink())
        .layoutWeight(1)
        .padding({ left: Space.M, right: Space.M })
        .textAlign(TextAlign.Center)
      // 右侧 40dp 占位：没有它标题会偏左（上游用的是 `Spacer(Modifier.width(40.dp))`）。
      Row()
        .width(Control.NAV_BUTTON_LARGE)
        .height(Control.NAV_BUTTON_LARGE)
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），64vp → 262px（低 27px）。
    // ⚠️ 同时保留 R65 的口径：栏高**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：挂材质的栏会画出比正文亮约
    //  +19 的一整条「带」；首页栏本体零材质、同口径 +0.00）。**光效只留在栏内控件上。**
    //  ⚠️ 历史：R66 曾把整条栏改官方材质（本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），
    //  R87 因「有明显分界」撤回；同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  /** 项目筛选器（圆角 18 / 最小高 48 / 图标 21 / 文字 15sp / 右侧 chevron）。 */
  @Builder
  projectSelector() {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON_XL, color: muted() })
      Text(this.filterLabel())
        .fontSize(FontSize.BODY)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: this.filterOpen ? ICONS['chevron-up'] : ICONS['chevron-down'], iconSize: FontSize.CHEVRON, color: muted() })
    }
    .width('100%')
    .constraintSize({ minHeight: Control.FIELD_LARGE })
    .padding({ left: Space.L, right: Space.L, top: Space.M, bottom: Space.M })
    .borderRadius(Radius.XL)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
    .opacity(this.mutating ? 0.6 : 1)
    .onClick(() => {
      if (this.mutating) {
        return;
      }
      this.filterOpen = !this.filterOpen;
    })
  }

  /**
   * 项目菜单：全屏透明遮罩（点它关闭）+ 锚定卡片。
   * 自绘而不 `bindMenu` 的理由同终端页设备菜单（几何可控 + `dumpLayout` 可判定 + 不与根节点的 bindSheet 争弹层）。
   */
  @Builder
  projectMenuLayer() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.filterOpen = false;
      })
    Column() {
      Scroll() {
        Column() {
          AaMenuActionRow({
            label: '全部项目',
            active: this.projectFilter === FILTER_ALL,
            onTap: () => {
              this.pickFilter(FILTER_ALL);
            }
          })
          ForEach(this.projects, (project: AgentProject) => {
            AaMenuActionRow({
              label: project.name,
              active: this.projectFilter === project.id,
              onTap: () => {
                this.pickFilter(project.id);
              }
            })
          }, (project: AgentProject) => project.id)
        }
        .width('100%')
      }
      .width('100%')
      .align(Alignment.Top)
    }
    .width(Control.MENU_WIDTH)
    .constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .position({ x: MENU_LEFT, y: MENU_TOP })
  }

  private pickFilter(projectId: string): void {
    this.projectFilter = projectId;
    this.filterOpen = false;
    // 分组是按筛选值算出来的，改筛选后要立刻重算（pull 读的是 store，不产生请求）。
    this.pull();
  }

  // -------------------------------------------------------------------------
  // 分组列表
  // -------------------------------------------------------------------------

  @Builder
  groupList() {
    List() {
      ForEach(this.groups, (group: SessionGroup) => {
        ListItem() {
          this.groupSection(group)
        }
      }, (group: SessionGroup) => this.groupKey(group))
      // 列表底部「加载更多」：还有更多时显示、加载中禁用、失败可重试。
      if (this.showLoadMore) {
        ListItem() {
          this.loadMoreFooter()
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ top: Space.XS, bottom: Space.XL })
    .scrollBar(BarState.Off)
  }

  /**
   * 分组的 ForEach key。
   * ⚠️ 必须带上**筛选值**：切项目时整列重建，避免旧项被复用成错行（易错点 3）。
   * 也要带上组内会变的字段（标题/序号），否则重命名后组内不刷新（坑 138）。
   */
  private groupKey(group: SessionGroup): string {
    let members = '';
    for (let i = 0; i < group.sessions.length; i++) {
      const session = group.sessions[i];
      members += `${session.id}:${session.title}:${session.updatedSeq}:${session.archived},`;
    }
    return `${this.projectFilter}:${group.projectId}:${members}`;
  }

  /**
   * 一个项目的卡片：**只有会话行**（组内首末行的圆角由这层 `clip` 统一给出）。
   *
   * ⚠️ R20 勘误：分组头原来被写在这张卡**内部** ⇒ 并排图上看得出卡片从分组头上方就开始画边框。
   * 上游（`ArchivedSessionsScreen.kt:158-188`）里 `ArchivedProjectHeader` 与每条 `ArchivedSessionRow`
   * 是**同一个 LazyColumn 的独立 item**，卡片轮廓由 `ArchivedSessionRow` 的
   * `archivedGroupBorder(first, last)`（`:172-203`）**逐行分段画**（首行画上圆角、末行画下圆角、中间只画两侧）
   * ⇒ 视觉上是一张连体卡，但**分组头在卡外**。
   */
  @Builder
  groupCard(group: SessionGroup) {
    Column() {
      ForEach(group.sessions, (session: AgentSession) => {
        Column() {
          Divider()
            .color(borderColor())
            .width('100%')
          this.sessionRow(session)
        }
        .width('100%')
      }, (session: AgentSession) => `${session.id}:${session.title}:${session.updatedSeq}:${session.archived}`)
    }
    .width('100%')
    .borderRadius(Radius.XL)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
    .clip(true)
  }

  /** 一个项目的整块（分组头 + 卡片）—— 分组头在卡**外**，见 `groupCard()` 的注释。 */
  @Builder
  groupSection(group: SessionGroup) {
    Column() {
      this.groupHeader(group)
      this.groupCard(group)
    }
    .width('100%')
    .margin({ bottom: Space.L })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 分组头：top16 / bottom12 / 图标 20 / 标题 15sp / 副文 11sp（缩进 28）。
   * ⚠️ 缩进 28 = 图标 20 + 行内间距 8（`Space.S`）—— 副文与标题同列即等价于上游的 28dp 缩进，
   * 因此这里**不额外加 padding**（加了反而会让副文比标题右移）。
   */
  @Builder
  groupHeader(group: SessionGroup) {
    Row({ space: Space.S }) {
      AaIcon({ d: ICONS['folder-open'], iconSize: FontSize.ICON, color: muted() })
      Column({ space: Space.XXS }) {
        // 上游 `ArchivedProjectHeader`（`:90-99`）：15sp / **SemiBold** / ink。
        // ⚠️ R20 勘误：本工程此前漏了字重（渲染成常规体，并排图上一眼比安卓细）。
        // ArkTS 的 `FontWeight` 没有 SemiBold，按本工程既有约定取 Bold（见 `Components.ets:775`）。
        Text(group.title)
          .fontSize(FontSize.BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (group.workspacePath.length > 0) {
          Text(group.workspacePath)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      this.restoreProjectButton(group)
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, top: Space.L, bottom: Space.M })
  }

  /** 会话行：水平 16 / 垂直 14、标题 15sp、时间 11sp。 */
  @Builder
  sessionRow(session: AgentSession) {
    Row({ space: Space.M }) {
      Column({ space: Space.XS }) {
        // 上游 `ArchivedSessionRow`（`:150-151`）：15sp / **Medium** / colors.ink。
        Text(session.title)
          .fontSize(FontSize.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.timeLabelOf(session))
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      this.restoreButton(session)
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, top: Space.ROW_PAD_V, bottom: Space.ROW_PAD_V })
    // R39：官方按压态。本行无底色（透明）⇒ `normal` 给透明；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      Router.push(Route.SESSION, session.id);
    })
  }

  /**
   * 恢复单条按钮 —— 上游 `ArchiveActionButton(filled = true, icon = Lucide.ArchiveRestore)`
   * （`ArchivedSessionComponents.kt:154-162` + `:206-245`）：
   * 「图标 16dp + 6dp + 文字 12sp」，`subtle` 底 + 圆角 12 + 浅色下 1dp 描边。
   *
   * ⚠️ R20 勘误：本工程此前**没有图标**，与上游的「图标 + 文字」不一致。
   */
  @Builder
  restoreButton(session: AgentSession) {
    Row({ space: Space.XS_PLUS }) {
      AaIcon({ d: ICONS['archive-restore'], iconSize: FontSize.ICON_MD, color: inkSoft() })
      Text(this.busySessionId === session.id ? '恢复中…' : '恢复')
        .fontSize(FontSize.SMALL_PLUS)
        .fontColor(inkSoft())
    }
    .padding({ left: Space.M, right: Space.M, top: Space.XS_PLUS, bottom: Space.XS_PLUS })
    .borderRadius(Radius.M)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(subtle())
    .opacity(this.mutating ? 0.5 : 1)
    .onClick(() => {
      this.restoreSession(session);
    })
  }

  /**
   * 恢复该项目全部（分组头右侧）—— 上游 `ArchiveActionButton(filled = **false**)`
   * （`ArchivedSessionComponents.kt:100-107`）：**透明底、无描边、无图标**，只有文字。
   *
   * ⚠️ R20 勘误两处：① 本工程此前给它套了与单条按钮相同的胶囊底与描边，与上游不符；
   * ② 文案写成了「恢复全部」，上游 `archived_restore_project` 是「**全部恢复**」（词序相反）。
   */
  @Builder
  restoreProjectButton(group: SessionGroup) {
    Text(this.busyProjectId === group.projectId ? '恢复中…' : '全部恢复')
      .fontSize(FontSize.SMALL_PLUS)
      .fontColor(inkSoft())
      .padding({ left: Space.M, right: Space.M, top: Space.XS_PLUS, bottom: Space.XS_PLUS })
      .opacity(this.mutating ? 0.5 : 1)
      .onClick(() => {
        this.restoreProject(group);
      })
  }

  // -------------------------------------------------------------------------
  // 状态面板与分页脚
  // -------------------------------------------------------------------------

  /**
   * 状态面板：插图 + 标题 + 说明 + 动作按钮（五种状态共用一套骨架，文案由方法分派）。
   * ⚠️ 不传值参数 —— 值参数 @Builder 会停在首建快照（坑 38）。
   */
  @Builder
  statusPanel() {
    Column({ space: Space.XL }) {
      Column({ space: Space.XL }) {
        this.statusArtwork()
        Column({ space: Space.S }) {
          // 上游 `ArchivedStatusPanel`（`:280-281`）：标题 16sp / lineHeight 23 / SemiBold / **inkSoft**
          //（不是 `ink`）；副文（`:282-283`）13sp / lineHeight 20 / max 260 / **inkSoft**，且 `padding(top 10)`。
          Text(this.stateInfo().title)
            .fontSize(FontSize.ROW_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(inkSoft())
            .lineHeight(23)
            .textAlign(TextAlign.Center)
          if (this.stateInfo().description.length > 0) {
            Text(this.stateInfo().description)
              .fontSize(FontSize.SMALL)
              .fontColor(inkSoft())
              .lineHeight(20)
              .textAlign(TextAlign.Center)
              .constraintSize({ maxWidth: Control.HERO_TEXT_MAX })
              .padding({ top: Space.S_PLUS })
          }
        }
        .alignItems(HorizontalAlign.Center)
      }
      .alignItems(HorizontalAlign.Center)
      if (this.stateInfo().actionLabel.length > 0) {
        AaSecondaryButton({
          label: this.stateInfo().actionLabel,
          onTap: () => {
            this.runStateAction();
          }
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: Space.PANEL_V, bottom: Space.PANEL_V })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 状态面板的插图 —— 上游 `ArchivedStatusPanel`（`ArchivedSessionComponents.kt:264-278`）是**两种**形态：
   *
   * - `showEmptyIllustration = true`（**只有真空态**）：128dp 的**位图**
   *  （`ic_archive_empty_light/dark`，「打开的盒子 + ✕ 徽标」）；
   * - 其余：80dp 圆角 26 的方块 + 32dp 图标（加载中是 26dp 转圈）。
   *
   * ⚠️ R21 勘误：本工程此前把两种混成了一种（外圈 128 圆 + 内层 80 方块 + 32 图标），
   * 于是**真空态的插图与安卓对不上**（并排图 `../r16-side-by-side/18-archived-empty.png` 一眼可见）。
   *
   * 两张位图放在资源限定目录（浅色 `base/media/`、深色 `dark/media/`，**同名** `ic_archive_empty`）。
   * **R56 起本工程为自绘液态玻璃版，不再与上游位图逐字节相同**；上游对照见
   * 开发期验证记录（旧口径 md5 `b8211d6b…` / `b19c1454…` 已作废，别再当判据）。
   * 深浅由资源目录自动切换、代码里不判主题。
   */
  @Builder
  statusArtwork() {
    if (this.stateInfo().kind === ArchivedStateKind.EMPTY) {
      Image($r('app.media.ic_archive_empty'))
        .width(Control.HERO_CIRCLE)
        .height(Control.HERO_CIRCLE)
    } else {
      Column() {
        if (this.stateInfo().kind === ArchivedStateKind.LOADING) {
          // 上游状态面板是 26dp 的转圈（`Control.HERO_SPINNER`）。
          // ⚠️ `LoadingProgress` **没有线宽参数**（SDK 只给 color / enableLoading / contentModifier），
          // 线宽由系统决定 —— 上游的 2dp 线宽在这里配不了，也不该写一个看起来配了的样式。
          LoadingProgress()
            .width(Control.HERO_SPINNER)
            .height(Control.HERO_SPINNER)
            .color(muted())
        } else {
          AaIcon({ d: ICONS[this.stateIconName()], iconSize: Control.HERO_ICON, color: faint() })
        }
      }
      .width(Control.HERO_INNER)
      .height(Control.HERO_INNER)
      .borderRadius(Radius.HERO_INNER)
      .backgroundColor(raisedSurface())
      .justifyContent(FlexAlign.Center)
    }
  }

  private stateIconName(): string {
    return this.stateInfo().kind === ArchivedStateKind.ERROR ? 'circle-alert' : 'archive';
  }

  /**
   * 分页脚 —— 上游 `ArchivedListFooter`（`ArchivedSessionComponents.kt:292-310`）：
   * `Column(padding top 20, spacedBy 8, 水平居中)`；失败时上方一行 `archive_more_failed`
   * 「**暂时无法加载更多会话**」（13sp、`archiveSecondaryInk`）；按钮是
   * `ArchiveActionButton(filled = **false**)` + `icon = if (failed) RefreshCw else ChevronDown`。
   *
   * ⚠️ R21 三处勘误：① 失败文案原来直接显示服务端/本地的错误原文（上游是**固定文案**）；
   * ② 按钮原用 `AaSecondaryButton`（有底 + 描边），上游是透明无边框；③ 原来没有图标。
   */
  @Builder
  loadMoreFooter() {
    Column({ space: Space.S }) {
      if (this.pageError.length > 0) {
        Text('暂时无法加载更多会话')
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Row({ space: Space.XS_PLUS }) {
        AaIcon({
          d: ICONS[this.pageError.length > 0 ? 'refresh-cw' : 'chevron-down'],
          iconSize: FontSize.ICON_MD,
          color: inkSoft()
        })
        Text(this.loadingMore ? '加载中…' : (this.pageError.length > 0 ? '重试' : '加载更多'))
          .fontSize(FontSize.SMALL_PLUS)
          .fontColor(inkSoft())
      }
      .padding({ left: Space.M, right: Space.M, top: Space.XS_PLUS, bottom: Space.XS_PLUS })
      .opacity(this.loadingMore ? 0.5 : 1)
      .onClick(() => {
        if (!this.loadingMore) {
          this.store.loadMore(true);
        }
      })
    }
    .width('100%')
    .padding({ top: Space.FOOTER_TOP, bottom: Space.S })
  }
}

export { SessionGroup };
