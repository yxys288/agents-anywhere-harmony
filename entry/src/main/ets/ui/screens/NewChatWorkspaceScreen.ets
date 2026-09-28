/**
 * 「新建对话」的第一步：**选择工作区**（R53）。
 *
 * 用户拍板的流程：「新建对话 → **选择工作区** → 进入该工作区对话」。
 * 所以点首页「+」先到这里（只是一个选择器，**不是**对话界面），选定后
 * `Router.replace(Route.DRAFT_SESSION, connectorId|projectId)` 直接进**原对话页**的草稿态
 * （`SessionDetailScreen` + `store.beginPrepared`）——那一页就是真会话页，只是服务端会话
 * 还没建：输入区 / ⚙ 运行时设置（模型 / 推理强度 / 权限 / Agent 预设）/ 顶栏全部照常可用，
 * 首条消息发出时才 `create-and-start`。
 *
 * ⚠️ 用 `replace` 而不是 `push`：选完工作区后返回键应当回首页，
 * 而不是回到这个「已经选过了」的选择器。
 */

import { DashboardListener, DashboardStore } from '../../feature/DashboardStore';
import { LAST_SESSION_KEY } from '../../store/AppPreferences';
import {
  NewChatDevice, NewChatProject, NewChatSession, encodeNewChatEntry, findProject,
  pickDraftProject, projectIdOfSession, projectsForDevice
} from '../../model/NewChatDraft';
import { AgentDevice, AgentProject, AgentSession } from '../../model/AppModels';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, ink, muted,
  onPrimaryAction, primaryAction, raisedSurface
} from '../Design';
import { AaCircleIconButton, AaConfigMenuItem, AaEmptyState, AaSecondaryButton } from '../Components';
import { Route, Router } from '../Router';

// ⚠️ R81：本页原来私有一个 `HEADER_HEIGHT = 58`（「与新建族其余两页同款 58dp」）——
//  标题栏口径统一后**该常量已删除**，行高走 `Control.NAV_TITLE_ROW`（见 `navTitleBar()`）。

@Component
export struct NewChatWorkspaceScreen {
  @State devices: NewChatDevice[] = [];
  @State projects: NewChatProject[] = [];
  @State sessions: NewChatSession[] = [];
  @State deviceId: string = '';
  /** 「上次用过」的工作区（最后打开过的会话所属；没有就看最近更新的会话）。 */
  @State recommendedProjectId: string = '';
  @State loading: boolean = true;

  private dashboard: DashboardStore = DashboardStore.get();
  private alive: boolean = false;
  private storeListener: DashboardListener = () => {
    this.pull();
  };

  aboutToAppear(): void {
    this.alive = true;
    this.dashboard.onChange(this.storeListener);
    this.pull();
    if (this.devices.length === 0) {
      this.dashboard.refreshAll().then(() => {
        if (!this.alive) {
          return;
        }
        this.pull();
        this.loading = false;
      });
    } else {
      this.loading = false;
    }
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.dashboard.offChange(this.storeListener);
  }

  /** store → @State 快照（窄接口显式映射：ArkTS 不支持结构化类型）。 */
  private pull(): void {
    const devices: NewChatDevice[] = [];
    for (let i = 0; i < this.dashboard.devices.length; i++) {
      const device: AgentDevice = this.dashboard.devices[i];
      devices.push({ id: device.id, name: device.name, online: device.online });
    }
    const projects: NewChatProject[] = [];
    for (let i = 0; i < this.dashboard.projects.length; i++) {
      const project: AgentProject = this.dashboard.projects[i];
      projects.push({
        id: project.id,
        connectorId: project.connectorId,
        name: project.name,
        workspacePath: project.workspacePath,
        pinned: project.pinned
      });
    }
    const sessions: NewChatSession[] = [];
    for (let i = 0; i < this.dashboard.activeSessions.length; i++) {
      const session: AgentSession = this.dashboard.activeSessions[i];
      sessions.push({
        id: session.id,
        connectorId: session.connectorId,
        projectId: session.projectId !== undefined ? session.projectId : '',
        cwd: session.cwd !== undefined ? session.cwd : '',
        sortKey: session.sortKey
      });
    }
    this.devices = devices;
    this.projects = projects;
    this.sessions = sessions;
    if (this.deviceId.length === 0 && devices.length > 0) {
      // 设备沿用 R47 记忆（还在列表里才用），否则第一台在线设备。
      this.deviceId = this.firstReachableDevice();
    }
    this.recommendedProjectId = this.computeRecommended();
  }

  /** 设备默认值：记忆的设备仍在列表里就用它，否则第一台在线设备，再否则第一台。 */
  private firstReachableDevice(): string {
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].online) {
        return this.devices[i].id;
      }
    }
    return this.devices.length > 0 ? this.devices[0].id : '';
  }
  /**
   * 「上次用过」的工作区：① 最后打开过的那个会话所在；② 否则当前设备上最近更新的会话所在；
   * ③ 都没有就空串（列表里不标推荐，用户自己挑）。
   */
  private computeRecommended(): string {
    if (this.deviceId.length === 0) {
      return '';
    }
    const lastSessionId = AppStorage.get<string>(LAST_SESSION_KEY);
    const fromLast = projectIdOfSession(this.sessions, lastSessionId !== undefined ? lastSessionId : '');
    const candidates = projectsForDevice(this.deviceId, this.projects);
    if (fromLast.length > 0 && findProject(candidates, fromLast) !== undefined) {
      return fromLast;
    }
    return pickDraftProject(this.deviceId, '', this.projects, this.sessions);
  }

  /** 选定工作区 ⇒ 进**原对话页**的草稿态（显式带上 connectorId|projectId）。 */
  private enterWorkspace(project: NewChatProject): void {
    Router.replace(Route.DRAFT_SESSION, encodeNewChatEntry(project.connectorId, project.id));
  }

  private visibleProjects(): NewChatProject[] {
    return projectsForDevice(this.deviceId, this.projects);
  }

  build() {
    // R65-A（设计规格 §2）：顶栏从正文里**提到 `Navigation` 标题栏**。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容区之上**、占自己一行）而不是 `STACK`：
    //  `STACK` 把标题栏**叠在内容上**，那就必须自己给内容让位（`contentStartOffset` 那套），
    //  而 设计规格 §2 明确要求「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
    //  ⇒ STANDARD 下内容天然落在标题栏下方，首屏不会被顶栏压住（与 R65-B 的三页逐字同款）。
    //
    // ⚠️ **R65-A 子决策**：原来「顶栏」是**两行**（58vp 标题行 + 一行副标题「在哪个工作区里开新对话？」）。
    //  框架标题栏的栏高由框架给定（真机实测 66vp，见 `HomeScreen` 的 `TITLE_BAR_VP`）—— 两行
    //  （≈79vp）塞进去会**溢出**（R61 的失败形态：子节点溢出 ⇒ 压住内容首行）。所以标题行走
    //  `.title(...)`，副标题下移为**内容区第一行**（仍是居中一行小字，观感基本不变）。
    Navigation() {
      Column() {
        this.subtitleLine()

        if (this.devices.length === 0) {
          Column() {
            AaEmptyState({
              title: this.loading ? '正在检查设备…' : '还没有配对的设备',
              message: this.loading
                ? '稍候片刻，检查完会自动进入下一步。'
                : '先在工作电脑上运行 Connector，再用配对码把它接到这里。',
              actionLabel: this.loading ? '' : '配对新设备',
              onAction: () => {
                Router.push(Route.ADD_DEVICE);
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.visibleProjects().length === 0) {
          Column() {
            AaEmptyState({
              title: '这台设备上还没有工作区',
              message: '工作区就是 Agent 干活的那个目录。先新建一个，再回来开对话。',
              actionLabel: '新建工作区',
              onAction: () => {
                Router.push(Route.NEW_PROJECT);
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          this.workspaceList()
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
   * （左返回圆钮 + 居中标题「选择工作区」）。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End`
   * 的底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1/§2）。
   */
  @Builder
  navTitleBar() {
    Row() {
      // R57（T2b）：玻璃档（顶栏已有 `backgroundEffect`，钮与栏同一套材质语言）。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.NAV_ICON,
        filled: true,
        glass: true,
        // R65-A：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内（`坑 245`），
        // 返回钮改走官方 `ImmersiveMaterial`（官方分支零自绘层：无 backgroundEffect / 渐变 / 描边）。
        officialMaterial: true,
        accessibilityLabel: '返回',
        tint: ink(),
        onTap: () => {
          Router.back();
        }
      })
      Text('选择工作区')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 右侧留一个等宽空位，标题才是**真正居中**的（同 NewSessionScreen 的写法）。
      Row()
        .width(Control.NAV_BUTTON_LARGE)
        .height(Control.NAV_BUTTON_LARGE)
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），58vp → 252px（低 17px）。
    // ⚠️ 原来这里是本页私有常量 `HEADER_HEIGHT = 58`（R53 抄「新建族 58dp」），R81 起**删除该常量**、
    //  统一到共享令牌（新建族三页必须同一条线，行高不同 ⇒ 同一位置控件差半个行高）。
    //  栏高同样**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: 18, right: 18 })
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：挂材质的栏会画出比正文亮约
    //  +19 的一整条「带」；首页栏本体零材质、同口径 +0.00）。**光效只留在栏内控件上。**
    //  ⚠️ 历史：R66 曾把整条栏改官方材质（本行那时是 `.systemMaterial(officialBarMaterial(glassCardSurface()))`），
    //  R87 因「有明显分界」撤回；同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  /**
   * 副标题「在哪个工作区里开新对话？」—— **R65-A 起改挂内容区第一行**。
   *
   * 原来它是顶栏的第二行。框架标题栏的栏高由框架给定（真机 66vp），两行会溢出
   * ⇒ 标题行走 `.title(...)`、本行留在内容区顶部（仍是居中一行小字，位置就在标题栏正下方）。
   */
  @Builder
  subtitleLine() {
    Text('在哪个工作区里开新对话？')
      .fontSize(FontSize.CAPTION)
      .fontColor(muted())
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ bottom: Space.XS })
  }

  /** 工作区列表：设备 chips（多设备时）+ 工作区行（带「上次使用」标记）+ 新建工作区。 */
  @Builder
  workspaceList() {
    Column({ space: Space.M }) {
      if (this.devices.length > 1) {
        Scroll() {
          Row({ space: Space.S }) {
            ForEach(this.devices, (device: NewChatDevice) => {
              Text(device.name)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.deviceId === device.id ? onPrimaryAction() : ink())
                .padding({ left: Space.M, right: Space.M, top: Space.XS, bottom: Space.XS })
                .borderRadius(Radius.PILL)
                .backgroundColor(this.deviceId === device.id ? primaryAction() : raisedSurface())
                .borderWidth(StrokeWidth.HAIRLINE)
                .borderColor(borderColor())
                .maxLines(1)
                .onClick(() => {
                  this.deviceId = device.id;
                  this.recommendedProjectId = this.computeRecommended();
                })
            }, (device: NewChatDevice) => device.id)
          }
          .padding({ left: Space.PAGE, right: Space.PAGE })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        // 横向 Scroll 必须显式 Start（见 suite-scroll-align）。
        .align(Alignment.Start)
      }

      Scroll() {
        Column() {
          ForEach(this.visibleProjects(), (project: NewChatProject) => {
            AaConfigMenuItem({
              label: project.name,
              detail: project.id === this.recommendedProjectId
                ? project.workspacePath + '   ·   上次使用'
                : project.workspacePath,
              onTap: () => {
                this.enterWorkspace(project);
              }
            })
          }, (project: NewChatProject) => project.id)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      AaSecondaryButton({
        label: '新建工作区',
        onTap: () => {
          Router.push(Route.NEW_PROJECT);
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.L })
  }
}
