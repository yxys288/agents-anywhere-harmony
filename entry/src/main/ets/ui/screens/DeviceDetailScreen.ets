/**
 * 设备详情（对应 Android `ui/screens/devices/DeviceDetailScreen.kt`，1345 行 Compose 的收敛版）。
 *
 * 覆盖：设备信息、Runtime 列表（启动/停止/配置/清除）、Runtime 能力与目录查看、
 * 从设备进入「文件浏览」与「终端」。
 *
 * ## 第八十六轮（R86）改动 —— 官方沉浸光感（契约 开发期验证记录 §2 #2/#3）
 * · 顶栏**提到 `Navigation.title(...)`**（原来画在页面正文里）：栏本体改挂官方 `ImmersiveMaterial`、
 *  删掉自绘 `backgroundEffect` 与自持的状态栏避让（`topInset()`），`titleMode` 显式 **`Full`**；
 * · 返回钮 / 右上「⋯」钮**都保留**（契约 §2 #2 明写保留 ⋯；返回钮的理由见 `topBar()` 上方注释）
 *  并升级为**官方材质档**（`AaCircleIconButton` 的 `glass + officialMaterial` 分支）；
 * · ⋯ 打开的 `bindSheet` 半模态下发 `SheetOptions.systemMaterial = panelMaterial()`（`blurStyle` 保留）。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { DeviceStore } from '../../feature/DeviceStore';
import { RemoteDeviceRuntime } from '../../model/Types';
import { DashboardStore } from '../../feature/DashboardStore';
import {
  AgentSession, SessionListIndicator,
  deviceArchiveAllActionLabel, deviceRuntimeLabel, deviceRuntimeSecondary
} from '../../model/AppModels';
import {
  ConfirmPhase, DeviceSessionsFilter, RuntimeConfigDraft, RuntimeEnvEntry, archiveAllBody,
  archiveAllConfirmLabel, archiveAllTitle, archiveTargetIds, bulkActionLabel, confirmNext,
  selectionTargetArchived,
  deviceSessionsEmptyText, environmentError, revokeConfirmBody, revokeConfirmTitle, revokeDoneText,
  runtimeConfigDraft, runtimeConfigPayload, runtimeSupportsField, sessionsForDevice, toggleSelectAll,
  toggleSelected
} from '../../feature/DeviceStore';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, errorText, faint, ink, inkSoft, muted,
  onPrimaryAction, primaryAction, raisedSurface, rowPressedSurface, runtimeStatusColor, runtimeStatusLabel, subtle
} from '../Design';
import {
  AaCircleIconButton, AaConfirmDialog, AaEmptyState, AaErrorBanner, AaInfoRow, AaMenuActionRow, AaSecondaryButton,
  AaSectionHeader, DIALOG_VARIANT_CONFIRM, closeAaConfirmDialog, openAaConfirmDialog,
  // R86（契约 §2 #1/#2/#3）：标题栏与半模态面板的**官方沉浸材质**一律走 `Components.ets` 已冻结的构造入口
  // （`officialBarMaterial` / `panelMaterial`）—— 页面**不许**自己 `import { uiMaterial }`（契约 §1.6）。
  panelMaterial
} from '../Components';
import { Route, Router } from '../Router';
import { authController } from '../../feature/AppServices';
import { runtimeReasonText as gatingRuntimeReasonText } from '../../model/SessionGating';
import { AaIcon, ICONS } from '../Icon';


@Component
export struct DeviceDetailScreen {
  @Prop deviceId: string = '';
  // 状态必须在 build 里被真正读到才会触发刷新（见 HomeScreen 顶部注释）。
  @State nameText: string = '';
  @State osText: string = '';
  @State onlineFlag: boolean = false;
  @State lastSeenText: string = '';
  @State runtimes: RemoteDeviceRuntime[] = [];
  @State errorText: string = '';
  @State noticeText: string = '';
  @State renaming: boolean = false;
  @State renameValue: string = '';
  /** 顶栏 ⋯ 打开的设备操作面板（上游 `DeviceActionsSheet`，176 行）。 */
  @State showActions: boolean = false;
  /** 「发现 Runtime」进行中（上游 AGENT 区的加载行，高 56dp）。 */
  @State discovering: boolean = false;
  /** 面板内的错误（重命名失败之类），与页面主错误分开，免得互相覆盖。 */
  @State actionsError: string = '';
  // —— A2 设备会话区（列表 + 多选 + 批量归档）——
  @State sessions: AgentSession[] = [];
  @State sessionFilter: string = DeviceSessionsFilter.ACTIVE;
  @State selectMode: boolean = false;
  @State selectedIds: string[] = [];
  @State bulkBusy: boolean = false;
  // —— A5 撤销设备令牌（确认 → 请求在飞 → 完成，由 `confirmNext` 纯函数驱动）——
  @State revokePhase: string = ConfirmPhase.IDLE;
  @State revokeError: string = '';
  @State revokeCommand: string = '';
  @State revokeHint: string = '';
  // —— B4 Runtime 配置（内联展开，不用 bindSheet：弹层不吃键盘避让，见 EXPERIENCE §29）——
  @State configRuntimeId: string = '';
  @State configTitle: string = '';
  @State configPath: string = '';
  @State configEnv: RuntimeEnvEntry[] = [];
  @State configSupportsPath: boolean = false;
  @State configSupportsEnv: boolean = false;
  @State configError: string = '';
  @State configSaving: boolean = false;
  /**
   * 环境变量行的**增删版本号**（进 ForEach 的 key）。
   *
   * 变量名/值刻意**不进** key：那会让每敲一个字符就重建整行（输入法组合态被打断）。
   * 但增删会让「同一个 index」前后指向不同条目 —— 只按 index 做 key 会复用错行，
   * 所以在这一刻把版本号 +1、整体重建一次；行数是个位数，代价可忽略。
   */
  @State envEpoch: number = 0;
  // —— R13-14：自绘确认框（上游 `DeviceConfirmDialog`）的四条链路共用一套状态 ——
  /** 当前确认框的类型：`archive-all` / `revoke` / `delete-device` / `clear-config`。 */
  @State confirmKind: string = '';
  @State confirmTitle: string = '';
  @State confirmBody: string = '';
  @State confirmLabel: string = '';
  @State confirmDanger: boolean = false;
  @State confirmBusy: boolean = false;
  @State confirmError: string = '';
  /** 「删除运行时配置」时被操作的 Runtime id（`clear-config` 用）。 */
  private confirmRuntimeId: string = '';
  /** 自绘确认框的 dialogId（`closeAaConfirmDialog` 用）；0 = 当前没开。 */
  private confirmDialogId: number = 0;

  private store: DeviceStore = DeviceStore.get();
  private dashboard: DashboardStore = DashboardStore.get();
  /** 存成字段才能被 `offChange` 摘除（单例 store 的监听器数组只增不减）。 */
  private storeListener: () => void = () => {
    this.pull();
  };
  /**
   * 会话区跟着**工作台**走：设备详情的会话列表直接取自 `DashboardStore`
   * （活跃 + 已归档两份），它变了本页要跟着重算。
   */
  private dashboardListener: () => void = () => {
    this.pullSessions();
  };

  aboutToDisappear(): void {
    this.store.offChange(this.storeListener);
    this.dashboard.offChange(this.dashboardListener);
  }

  aboutToAppear(): void {
    this.store.onChange(this.storeListener);
    this.dashboard.onChange(this.dashboardListener);
    const device = this.dashboard.deviceById(this.deviceId);
    this.store.bind(
      this.deviceId,
      device !== undefined ? device.name : this.deviceId,
      device !== undefined && device.deviceOs !== undefined ? device.deviceOs : '',
      device !== undefined ? device.online : false,
      device !== undefined && device.lastSeenAt !== undefined ? device.lastSeenAt : '');
    this.renameValue = this.store.deviceName;
    this.pull();
    this.pullSessions();
    this.store.load();
    // 会话区用的是工作台快照；直接进本页（例如刚配对完）时它可能还没拉过 —— 补一次。
    if (this.dashboard.activeSessions.length === 0 && this.dashboard.archivedSessions.length === 0) {
      this.dashboard.refreshAll();
    }
  }

  /** store -> @State 快照（build 只读这些字段）。 */
  private pull(): void {
    this.nameText = this.store.deviceName;
    this.osText = this.store.deviceOs;
    this.onlineFlag = this.store.online;
    this.lastSeenText = this.store.lastSeenAt;
    this.runtimes = this.store.runtimes.slice();
    this.errorText = this.store.error;
    this.noticeText = this.store.notice;
    this.discovering = this.store.discovering;
  }

  /** 工作台 → 会话区的 @State（筛选与排序都在纯函数里，已进 Node 单测）。 */
  private pullSessions(): void {
    const next = sessionsForDevice(
      this.dashboard.activeSessions, this.dashboard.archivedSessions, this.deviceId, this.sessionFilter);
    this.sessions = next;
    // 会话可能已被别处归档或删除：把选中集合收敛到「此刻仍在列表里」的 id，
    // 否则批量按钮会拿着一个不存在的 id 去发请求。
    const alive: string[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      const id = this.selectedIds[i];
      for (let j = 0; j < next.length; j++) {
        if (next[j].id === id) {
          alive.push(id);
          break;
        }
      }
    }
    if (alive.length !== this.selectedIds.length) {
      this.selectedIds = alive;
    }
  }

  /**
   * ⚠️ **R86 删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）。
   *
   * R37 五改的本意是「顶栏背景铺到屏幕顶、状态栏那一条也一起糊」。但顶栏一旦进入 `Navigation`
   * 标题栏（R86，见 `build()` 的说明），**高度与位置由框架接管**：真机 `dumpLayout` 实测标题栏落在
   * `[0,137][1316,332]`（`HomeScreen` R62 的实测记录）—— 页面根节点**已经在状态栏之下**，
   * 顶栏再避让一次就是**重复避让 137px**。而且原来读的是 `AppStorage.get(SAFE_AREA_TOP_PX)` 这个
   * **非响应**读取，值随冷启动时序在 `0 / 46vp` 之间跳（R61 实测：同一份包两次冷启动顶栏行高
   * 136px / 274px）。⇒ 本页按 R86 固定**不避让**，与 `HomeScreen`(R62) / `DevicesScreen`(R65-B) /
   * `AddDeviceScreen`(R86) 同一口径。
   *
   * **R86：本页标题栏** —— `Navigation.title(...)` 的自定义构造器，内容只有**顶栏一行**
   * （上游 `DeviceDetailHeader` :510-576 的**形态②**：64dp、元素间距 8、左返回钮、
   * 标题 25sp ExtraBold（行高 29）+ 状态标签 13sp、右 ⋯ 钮）。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End` 的
   * 底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`）。
   *
   * ⚠️ 两个钮都**保留**：契约 §2 #2 明写「**保留**右上『⋯』钮 —— 它开半模态，不是返回语义」；
   * 返回钮同理保留，理由是 SDK 一手原文 `navigation.d.ts:2367-2370`（`hideBackButton`）——
   * 框架的返回键「takes effect **only when** `titleMode` is `NavigationTitleMode.Mini`」，
   * 而 `Mini` 已被真机证伪（`坑 247`：56vp 从窗口顶 y=0 起算，状态栏之下只剩 29px）；
   * 本页 `Navigation` 又没有 `NavPathStack`（路由是自研 `ui/Router.ets`）⇒ 删掉它就零返回入口。
   * 两者都已在标题栏内 ⇒ 按 Lead 裁决升级为**官方材质档**（与其余 9 页同构，
   * `AaCircleIconButton({ glass: true, officialMaterial: true })` = 材质 only、零自绘层）。
   */
  @Builder
  topBar() {
    Row({ space: Space.S }) {
      // 返回钮（`Router.pop()`：回上一页 —— 本页可能从设备列表或首页进来）。几何 40vp / 图标 20 不变。
      // R86：本钮在 `Navigation` 标题栏内 ⇒ 命中官方生效范围第③类（`坑 245`），走官方材质 only 分支
      // （`GlassIcon.ets#officialGlass()`：无 backgroundEffect / 渐变 / 描边 / 底色，符合契约 §1.2）。
      // 关闭姿势：撤掉 `glass` / `officialMaterial` 两行即回到原来的自绘圆钮；材质「关」的语义是
      // `uiMaterial.Material.empty`（**不传 `undefined`**，`坑 256`）。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        tint: ink(),
        glass: true,
        officialMaterial: true,
        accessibilityLabel: '返回',
        onTap: () => {
          Router.pop();
        }
      })
      // 上游 `DeviceDetailScreen.kt:531-547`：设备名与状态标签在**同一个 Row**（`spacedBy(9.dp)`），
      // 名称 `weight(1f, fill = false)`（只占自身需要的宽度、放不下才省略），状态标签紧随其后。
      // 改前两者被放进 `Column` ⇒ 「LYW」与「✓ 在线」被拆成两行（DIFF 7-1）。
      // ⚠️ R86：本行几何/字号/间距**一字未改**（只把它从 build 的正文移进标题栏构造器）。
      Row({ space: Space.TIGHT }) {
        Text(this.nameText)
          .fontSize(FontSize.DETAIL_TITLE)
          .fontWeight(FontWeight.Bolder)
          .fontColor(ink())
          .lineHeight(29)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1)
        this.deviceStatusLabel()
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      // ⋯ 钮（打开设备操作面板 `actionsSheet()` 半模态）—— 契约 §2 #2 明写**保留**；同样升级官方材质档。
      AaCircleIconButton({
        name: 'ellipsis',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        tint: ink(),
        glass: true,
        officialMaterial: true,
        accessibilityLabel: '设备操作',
        onTap: () => {
          this.actionsError = '';
          this.showActions = true;
        }
      })
    }
    .width('100%')
    // ## R86（契约 §2 #1/#2 同款口径）：**栏本体切官方材质** —— 原来那条自绘 `backgroundEffect` 磨砂
    //  **整段删除**，整条栏改由官方 `ImmersiveMaterial` 接管（口径 = 零自绘层；官方：材质会接管
    //  `backgroundColor`/`borderColor`/`borderWidth`/`shadow`，不建议与它们同用 ⇒ 本节点上这四项
    //  **一个都没有**，也不新增）。
    // ⚠️ 几何：行高 `Control.TOP_BAR_PAGE + topInset`(64+46) → `Control.NAV_TITLE_ROW`(46)
    // （栏已进 65.5vp 的框架槽位，64vp 的自绘行放不进去，`坑 255`；R81 起全工程标题栏行高统一 46，
    //  真机实测栏内控件垂直中心 = 166 + 行高/2 = 235px = 首页同一条线）；
    //  `width('100%')` 与左右 padding（本页上游是 `Space.XL` = 24，与其它页的 18 不同）**原样保留**。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.XL, right: Space.XL })
    .alignItems(VerticalAlign.Center)
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：挂材质的栏画出比正文亮约
    //  +19 的一整条「带」；首页栏本体零材质、同口径 +0.00）。**光效只留在栏内控件（返回钮 / ⋯ 钮）上。**
    //  ⚠️ 历史：本栏 R86 迁入 `Navigation` 时按当时的契约挂了栏本体材质
    //  （本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），R87 因观感投诉撤回；
    //  同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  build() {
    // ## R86（契约 §2 #2）：顶栏从正文里**提到 `Navigation` 标题栏**（原来是页面正文里的自绘行）。
    //
    // ⚠️ 官方依据 —— 官方「生效范围」行为变更（**仅对 `targetSdkVersion >= 26.0.0` 生效**，本工程 = 26.0.0）：
    //  其他组件**只在 `Navigation`/`NavDestination` 标题栏**、或横向 Tabs 且 `barPosition =
    //  BarPosition.End` 的底部 TabBar 中生效；**在页面正文里设置沉浸光感不生效**
    // （不报错、不告警，静默无效）—— `坑 245`。
    //  ⇒ 本页要让顶栏吃到官方材质，**必须先让顶栏进标题栏**。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容区之上**、占自己一行）而不是 `STACK`：
    //  STANDARD 下内容天然落在标题栏下方，首屏不会被顶栏压住（与 `DevicesScreen`(R65-B) /
    //  `ArchivedSessionsScreen`(R65-A) 同款口径）。
    //
    // ⚠️ 安全区：进标题栏后**避让由框架接管** ⇒ 本页原来的 `topInset()` 整段删除（见 `topBar()` 上方注释）。
    Navigation() {
      Column() {
        AaErrorBanner({
          message: this.errorText,
          onRetry: () => {
            this.store.load();
          },
          onDismiss: () => {
            this.store.error = '';
            this.errorText = '';
          }
        })
        if (this.noticeText.length > 0) {
          Text(this.noticeText)
            .fontSize(FontSize.CAPTION)
            .fontColor($r('app.color.session_status_accent_text'))
            .padding({ left: Space.M, right: Space.M, bottom: Space.S })
        }

        Scroll() {
          // 内容区（上游实现 / 列表页）：水平 24、区块间距 18、上下 top 8 / bottom 28。
          Column({ space: Space.PAGE }) {
            // ⚠️ 上游 `DeviceDetailScreen.kt` 主体只有顶栏 + AGENT 区 + 会话区，**没有**设备元数据行
            // （整文件零「设备 ID / 最后在线」文案）。按 R13-4 的裁决，这两项收进顶栏 ⋯ 的操作面板，
            // 不再占主列表的第一屏位置。

            // AGENT 区 —— 上游 `AgentsSection`（`:584-646`）+ `SectionBlock`（`:1092-1113`）：
            // `SectionBlock` 是 `Column(spacedBy 4.dp) { 34dp 区头; 内容 }`，
            // `ConfiguredAgentRow`（`:683-730`）**没有卡片容器**（无底色 / 无圆角 / 无边框），
            // 行间用 `DetailDivider`（`:1141-1148`，1dp 全宽、`colors.border`）分隔 ⇒ **平铺形态**。
            // （F-9：本工程此前每台 Runtime 一张圆角白卡，行中位数比安卓亮 21，这里按上游拉平。）
            Column({ space: Space.XS }) {
              // ⚠️ R20：这里原来带了 `trailing: `${this.runtimes.length}``（标题右侧的计数）。
              // 上游 `AgentsSection`（`DeviceDetailScreen.kt:590-592`）调的是 `SectionBlock(title = ...)`，
              // **不传 `action`**（`:1092-1094` 的 `action` 是可选槽，只有「会话」段用它放「选择 / 全部归档」）
              // ⇒ AGENT 段标题右侧**没有内容**。计数是本工程自加的，已删。
              AaSectionHeader({ title: 'AGENT' })
              Row() {
                Text(this.discovering ? '发现中…' : '发现 Runtime')
                  .fontSize(FontSize.SMALL_PLUS)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ink())
                  .height(Control.MINI_ACTION)
                  .padding({ left: Space.M, right: Space.M })
                  .textAlign(TextAlign.Center)
                  .opacity(this.discovering ? 0.6 : 1)
                  .onClick(() => {
                    if (!this.discovering) {
                      this.store.discover();
                    }
                  })
              }
              if (this.discovering) {
                Row({ space: Space.S_PLUS }) {
                  LoadingProgress().width(Control.SPINNER).height(Control.SPINNER).color(muted())
                  Text('正在加载运行时...')
                    .fontSize(FontSize.SMALL_PLUS)
                    .fontColor(muted())
                    .lineHeight(17)
                }
                .width('100%')
                .height(Control.LOADING_ROW)
                .alignItems(VerticalAlign.Center)
              }
              if (this.runtimes.length === 0) {
                Text('在该设备上安装并启动 Connector 后，点上面的「发现 Runtime」。')
                  .fontSize(FontSize.SMALL_PLUS)
                  .fontColor(muted())
                  .lineHeight(17)
                  .width('100%')
                  .padding({ bottom: Space.S })
              } else {
                ForEach(this.runtimes, (runtime: RemoteDeviceRuntime, index: number) => {
                  this.runtimeRow(runtime)
                  // 上游 `AgentsSection` :628：行间才画 `DetailDivider()`（末行不画）。
                  if (index !== this.runtimes.length - 1) {
                    this.detailDivider()
                  }
                }, (runtime: RemoteDeviceRuntime) =>
                  `${runtime.runtimeId}:${runtime.status}:${runtime.active}:${runtime.configured}:${runtime.present}`)
              }
              Row({ space: Space.S }) {
                // 上游 `DesktopAgentConfigurationHint`（`:648-673`）：15dp `CircleAlert` + 12.5sp muted 文案。
                AaIcon({ d: ICONS['circle-alert'], iconSize: FontSize.BODY, color: muted() })
                Text('如需配置或添加其他 Agent，请前往桌面端操作。')
                  .fontSize(FontSize.SMALL_PLUS)
                  .fontColor(muted())
                  .lineHeight(17)
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ top: Space.M, bottom: Space.XXS })
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 会话区 —— 上游 `SessionsSection`（`:834-950`）是 `SectionBlock` 的平铺形态：
            // 区头**没有计数**，右侧是 [选择][归档全部] 两个动作（`DeviceDetailScreen.kt:860-881`：
            // `SectionBlock(title = 会话, action = Row(spacedBy 8) { MiniTextAction(选择); MiniTextAction(归档全部) })`）
            // + 44dp 筛选行（三个 tag）+ 行（`SessionDetailRow` 无底色）+ `SessionDivider`。
            // ⚠️ `AaSectionHeader` 自带 `padding(top 12, bottom 4)`（Components.ets，本轮不可改）⇒ 动作行补
            //  `padding top 8`，使两者视觉中线一致（标题 12+9=21，动作 8+15=23 → 差 2vp 以内）。
            Column({ space: Space.XS }) {
              Row() {
                AaSectionHeader({ title: '会话' })
                  .layoutWeight(1)
                Row({ space: Space.S }) {
                  this.miniTextAction(this.selectMode ? '取消' : '选择', false)
                  if (!this.selectMode) {
                    this.miniTextAction(
                      deviceArchiveAllActionLabel(this.sessionFilter !== DeviceSessionsFilter.ARCHIVED), true)
                  }
                }
                .padding({ top: Space.S, right: Space.M })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              this.sessionToolbar()
              if (this.sessions.length === 0) {
                AaEmptyState({ title: deviceSessionsEmptyText(this.sessionFilter) })
              } else {
                ForEach(this.sessions, (session: AgentSession) => {
                  this.sessionRow(session)
                }, (session: AgentSession) =>
                  `${session.id}:${session.archived}:${session.title}:${session.updatedSeq}`)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // R92（用户裁决）：删除原「工作区动作」段（浏览该设备的文件 / 打开远程终端）——
            // 上游本页**没有**这一段（文件/终端入口在项目维度），删掉即回归上游形态；
            // 文件/终端入口由首页快捷入口与会话详情页承担（`Route.FILES` / `Route.TERMINAL` 仍被引用）。

            // 撤销令牌 / 删除设备都收进顶栏 ⋯ 的操作面板（上游 `DeviceActionsSheet`）；
            // 这里只留撤销成功后要展示的新令牌命令 —— 用户随时能回来再看一次。
            if (this.revokeCommand.length > 0) {
              Text(revokeDoneText(this.nameText))
                .fontSize(FontSize.SMALL)
                .fontColor(ink())
                .lineHeight(17)
                .width('100%')
              this.commandCard()
            }
            if (this.revokeError.length > 0) {
              Text(this.revokeError)
                .fontSize(FontSize.SMALL)
                .fontColor($r('app.color.error_text'))
                .width('100%')
            }

            Blank().height(Space.XXL)
          }
          .width('100%')
          .padding({ left: Space.XL, right: Space.XL, top: Space.S, bottom: Space.PAGE_BOTTOM })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(canvas())
    }
    // 标题栏 = 顶栏一行；底色**透明**，让标题栏自己的**官方材质**（`topBar()` 的 `systemMaterial`）
    // 透出页面底色 —— 不透明底会把材质那层整个盖住（同 `DevicesScreen` 口径）。
    .title(this.topBar(), { backgroundColor: Color.Transparent })
    .mode(NavigationMode.Stack)
    // ## `titleMode` **必须显式 `Full`**（缺省 ≠ Full：SDK `titleMode` 原文 Default value =
    //  `NavigationTitleMode.Free`）
    // · `Free`：主标题随内容滚动**收起/改变位置**（SDK `navigation.d.ts:224-243`）⇒ 顶栏「整条消失」；
    // · `Mini`：⛔ 已被真机证伪 —— 它的 56vp **从窗口顶 y=0 起算**，状态栏（46vp）之下只剩 29px
    // （`坑 247`）；
    // · `Full`：标题栏恒为 `[0,137][1316,332]`（本工程真机实测），栏内容落在**状态栏之下**，
    //  可用高 = 112 − 状态栏 = 65.5vp（`坑 255`）⇒ 容得下 `Control.NAV_TITLE_ROW`(46)。
    .titleMode(NavigationTitleMode.Full)
    .hideToolBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor(canvas())
    // ⚠️ 根节点**只有这一个** bindSheet（EXPERIENCE §34：同节点挂多个是「后写覆盖先写」）。
    // 页面内的 Runtime 配置区因此做成**内联展开**、撤销/删除确认走系统 AlertDialog，都不占这个名额。
    // ⚠️ 高度 380：面板里除了三行动作，还收了「设备 ID / 最后在线」两行元数据（R13-4 裁决）。
    //
    // ⚠️ R37 六改（用户拍板「那就删掉关闭按钮嘛」）：**关掉系统自带的关闭按钮**。
    // 真机实测那个按钮**点不动**（合成点击与 `uinput` 真触摸都无效；对照实验证明注入本身有效 ——
    // 点面板外能正常关闭），留着只会误导人。面板另有「下滑关闭」与「点面板外关闭」两个入口，
    // 关掉它不损失任何能力，还顺手腾出了右上角那块空间（面板内容因此可以回到顶部）。
    .bindSheet($$this.showActions, this.actionsSheet(), {
      height: 380,
      dragBar: true,
      showClose: false,
      // ⚠️ R86（契约 §2 #3）：**保留** `blurStyle`（官方未禁止与材质同用；删掉会让非玻璃控件变糊/失效）
      // —— 它是本轮 A/B 的**单变量登记项**（材质有/无之差），不是漏改。
      blurStyle: BlurStyle.Thin,
      // ## R86（契约 §2 #3 / §0.2 A4）：半模态面板下发**官方沉浸材质**。
      // · 官方依据：`SheetOptions.systemMaterial`（`SystemUiMaterial`，SDK `common.d.ts:12155`，
      //  归属 `declare interface SheetOptions` :11753；类型 `SystemUiMaterial` = `uiMaterial.Material`，
      //  `common.d.ts:16964`）。
      // · 生效范围：`bindSheet` 属于**弹窗类接口** ⇒ 官方「生效范围」里「在页面内**全部区域**生效」
      // （仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0；`坑 245`）
      //  ⇒ 与正文里的普通容器不同，本处不需要先搬进标题栏。
      // · §1.2：面板内容（`actionsSheet()`）本来就**没有**自绘底/描边/投影（它的根节点只有
      //  `width` + `padding` + `alignItems`）⇒ 无自绘层可删；材质接管的是**面板本体**的底/描边/投影。
      // · **关闭姿势**：删掉下面 `systemMaterial` 这一行 = 逐字回到 R85 前行为；显式关档的语义是
      //  `uiMaterial.Material.empty`（**不是** `undefined` —— 后者 = 「恢复组件默认材质」，`坑 256`）。
      //  `panelMaterial()` 内部已含降级：探针不通过时它自己返回 `Material.empty` ⇒ 面板回到系统默认底。
      systemMaterial: panelMaterial()
    })
  }

  // -------------------------------------------------------------------------
  // A2 设备会话区（列表 / 筛选 / 多选 / 批量归档）
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // 会话区（上游实现，上游 `SessionsSection` :835-1001）
  //
  // 数值：头部行 44dp（元素间距 18）/ 筛选 tag 34dp（水平 14、文字 14sp）/
  //  多选工具条 44dp 圆角 8（水平 10）/ 会话行 52dp（标题 16sp 行高 20、时间 10.8sp）/
  //  勾选圈 20dp（内勾 13）/ 分隔线 1dp / 小按钮 34dp 圆角 6（文字 14sp）/ 小文字动作 30dp（12.5sp）。
  // -------------------------------------------------------------------------

  /** 筛选行（三个 tag）+ 多选工具条（进入多选后才出现）。后者的两个动作已上移到区头行。 */
  @Builder
  sessionToolbar() {
    Column({ space: Space.S }) {
      // 上游筛选项行（`DeviceDetailScreen.kt:884-901`，高 44dp、`spacedBy(18.dp)`）只有三个 tag；
      // [选择] 与 [归档全部] 两个动作已上移到区头行（见 `build()` 里的会话区头）。
      Row({ space: Space.PAGE }) {
        this.sessionFilterChip('活跃', DeviceSessionsFilter.ACTIVE)
        this.sessionFilterChip('已归档', DeviceSessionsFilter.ARCHIVED)
        this.sessionFilterChip('全部', DeviceSessionsFilter.ALL)
      }
      .width('100%')
      .height(Control.FIELD)
      .alignItems(VerticalAlign.Center)

      if (this.selectMode) {
        Row({ space: Space.S_PLUS }) {
          Text(`已选择 ${this.selectedIds.length} 个`)
            .fontSize(FontSize.SMALL_PLUS)
            .fontWeight(FontWeight.Bold)
            .fontColor(ink())
          Text(this.allVisibleSelected() ? '取消全选' : '全选')
            .fontSize(FontSize.CAPTION_PLUS)
            .fontColor(muted())
            .onClick(() => {
              this.selectedIds = toggleSelectAll(this.visibleIds(), this.selectedIds);
            })
          Blank()
          this.smallActionButton(
            this.bulkBusy ? '处理中…' : bulkActionLabel(this.sessions, this.selectedIds),
            this.selectedIds.length > 0 && !this.bulkBusy, true, true)
        }
        .width('100%')
        .height(Control.FIELD)
        .padding({ left: Space.S_PLUS, right: Space.S_PLUS })
        .borderRadius(Radius.S)
        .backgroundColor(raisedSurface())
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .alignItems(VerticalAlign.Center)
      }

      // ⚠️ 「全部归档 / 全部取消归档」文案来自 `device_detail_archive_all`（`deviceArchiveAllActionLabel`），
      // 与确认框里的 `device_confirm_archive_all_confirm`「归档全部」不是同一个 key。
      // 该动作已上移到区头行（上游 `DeviceDetailScreen.kt:868-879` 的 `SectionBlock.action`）。
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 筛选 tag（高 34、水平 padding 14、文字 14sp）。
   *
   * 高亮判定读 `@State sessionFilter`，`value` 只是常量 —— 这正是 [坑 152] 说的
   * 「`@State` 标记在行内判」的路径：@State 被 build 读到即登记元素级依赖，变化即重绘。
   */
  /**
   * 会话筛选 tag（上游 `DeviceSessionFilterTag`，`DeviceDetailScreen.kt:1151-1182`）。
   *
   * 逐项照上游：高 34 / 水平内边距 14 / `CircleShape`；
   * 背景 `selected ? subtle : Color.Transparent`（**未选中是透明的**）；
   * 文字 `selected ? ink : #8A8A88（深色 #A1A1AA）`；字重 `selected ? Bold : SemiBold`（ArkTS 无 SemiBold，取 Medium 近似）。
   *
   * ⚠️ **R68 修正**：本工程此前给**未选中**的 tag 也画了 `raisedSurface` 底色 + 1dp 描边 ——
   * 并排图上安卓的「已归档 / 全部」是**纯文字无边框**，鸿蒙却是两个描边胶囊（`../r16-side-by-side/12-device-detail.png`）。
   * 上游那份实现里**根本没有 border**。
   */
  @Builder
  sessionFilterChip(label: string, value: string) {
    Text(label)
      .fontSize(FontSize.BODY_SMALL)
      .fontWeight(this.sessionFilter === value ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.sessionFilter === value ? ink() : $r('app.color.session_filter_idle_text'))
      .height(Control.TAG)
      .padding({ left: Space.M_PLUS, right: Space.M_PLUS })
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.PILL)
      .backgroundColor(this.sessionFilter === value ? subtle() : Color.Transparent)
      .onClick(() => {
        this.sessionFilter = value;
        this.selectedIds = [];
        this.pullSessions();
      })
  }

  /** 小文字动作（高 30、水平 padding 11、文字 12.5sp）。 */
  /**
   * 区头右侧的「小文字动作」（上游 `MiniTextAction`，高 30、12.5sp）。
   *
   * `isArchiveAll = false` → [选择 / 取消]（切多选模式）；`true` → [归档全部 / 取消归档全部]。
   * ⚠️ 回调不通过 @Builder 函数参数传（函数参数在 @Builder 里不可靠，见 `smallActionButton` 的说明），
   *  改用布尔分派 —— 与上游 `SectionBlock.action` 里那两个 `MiniTextAction` 一一对应。
   */
  @Builder
  miniTextAction(label: string, isArchiveAll: boolean) {
    Text(label)
      .fontSize(FontSize.SMALL_PLUS)
      .fontWeight(FontWeight.Medium)
      .fontColor(ink())
      .height(Control.MINI_ACTION)
      .padding({ left: Space.M, right: Space.M })
      .textAlign(TextAlign.Center)
      .opacity(isArchiveAll && (this.bulkBusy || this.sessions.length === 0) ? 0.45 : 1)
      .onClick(() => {
        if (isArchiveAll) {
          if (this.bulkBusy || this.sessions.length === 0) {
            return;
          }
          this.promptArchiveAll();
        } else {
          this.selectMode = !this.selectMode;
          this.selectedIds = [];
        }
      })
  }

  /**
   * 小按钮（高 34、圆角 6、文字 14sp）；`isBulk` 决定点下去是「归档所选」还是「全部归档」。
   *
   * ⚠️ 回调不通过 @Builder 参数传（函数参数在 @Builder 里不可靠），改用布尔分派。
   */
  @Builder
  smallActionButton(label: string, interactive: boolean, isBulk: boolean, primary: boolean) {
    Text(label)
      .fontSize(FontSize.BODY_SMALL)
      .fontWeight(FontWeight.Medium)
      .fontColor(primary ? onPrimaryAction() : ink())
      .height(Control.TAG)
      .padding({ left: Space.M, right: Space.M })
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.XS)
      .backgroundColor(primary ? primaryAction() : raisedSurface())
      .borderWidth(primary ? 0 : StrokeWidth.HAIRLINE)
      .borderColor(borderColor())
      .opacity(interactive ? 1 : 0.45)
      .onClick(() => {
        if (!interactive) {
          return;
        }
        if (isBulk) {
          this.applyBulkArchive();
        } else {
          this.promptArchiveAll();
        }
      })
  }

  /** 勾选圈（20dp、边框 1dp、内勾 13）。参数是会话 id，勾选态在**内部**读 @State。 */
  @Builder
  selectionCircle(sessionId: string) {
    Column() {
      if (this.selectedIds.indexOf(sessionId) >= 0) {
        AaIcon({ d: ICONS['check'], iconSize: FontSize.SMALL, color: this.selectedIds.indexOf(sessionId) >= 0 ? onPrimaryAction() : ink() })
      }
    }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width(Control.CHECK_CIRCLE)
      .height(Control.CHECK_CIRCLE)
      .borderRadius(Control.CHECK_CIRCLE / 2)
      .backgroundColor(this.selectedIds.indexOf(sessionId) >= 0 ? ink() : Color.Transparent)
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(this.selectedIds.indexOf(sessionId) >= 0 ? ink() : borderColor())
  }

  /** 会话行（高 52、间距 12、标题 16sp 行高 20、时间 10.8sp、行尾 1dp 分隔线）。 */
  @Builder
  sessionRow(session: AgentSession) {
    Column() {
      // 上游 `DeviceDetailScreen.kt:1010-1046 SessionDetailRow`：`Row(52dp, spacedBy 12)`，
      // [勾选圈][ListIcon 14][标题 16sp Bold `inkSoft` `weight(1f)`][**时间 10.8sp Monospace faint 右对齐**]。
      // 改前时间被塞进标题下方的 `Column` ⇒ 行更高、时间跑到第二行左侧（DIFF 7-5）。
      Row({ space: Space.M }) {
        if (this.selectMode) {
          this.selectionCircle(session.id)
        }
        // 上游 `DeviceDetailScreen.kt:1022-1027`：标题左侧还有一个 `Lucide.ListIcon`（14dp、tint=faint）。
        AaIcon({ d: ICONS['list'], iconSize: FontSize.ICON_SMALL, color: faint() })
        Text(session.title)
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(inkSoft())
          .lineHeight(20)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 行里**只有相对时间**（上游 `:1038-1045`，无状态字）：状态在会话详情里看。
        // ⚠️ ArkUI 的 `FontWeight` 枚举没有 SemiBold（同 `AaMenuActionRow` 的说明），600 档取 Medium。
        // ⚠️ R33：上游是 `session.updatedAtLabel.ifBlank { stringResource(R.string.common_now) }`
        //  —— **空值兜底「刚刚」**（`DeviceDetailScreen.kt:1039`）。本工程原样渲染空串 ⇒ 该位置留白。
        //
        // ⚠️ R37 八改（用户要求「活跃的会话把 now 改为加载的圆圈，这样能知道会话的状态」）：
        // **活跃（Busy = running / waiting / pending）的会话改显示转圈**，其余仍显示相对时间。
        // 这是**有意偏离上游**的一处（上游这一行只有时间，状态要去会话详情里看）。
        if (session.indicator === SessionListIndicator.Busy) {
          LoadingProgress()
            .width(16)
            .height(16)
            // 用色资源而不是 `statusColor('running')`：本页没 import 那个 helper，
            // 而 `statusColor('running')` 返回的正是这个资源（两处同源）。
            .color($r('app.color.runtime_running'))
        } else {
          Text(session.updatedAtLabel.length > 0 ? session.updatedAtLabel : '刚刚')
            .fontSize(FontSize.TIME)
            .fontWeight(FontWeight.Medium)
            .fontFamily('Noto Sans Mono')
            .fontColor(faint())
            .maxLines(1)
        }
      }
      .width('100%')
      .height(Control.ROW)
      .alignItems(VerticalAlign.Center)
      // R39：官方按压态。本行整行可点（选中模式 = 勾选，否则 = 进会话）⇒ 与首页会话行同款。
      // `normal` 给透明（本行链式无底色）；单属性约束见坑 227。
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        pressed: { .backgroundColor(rowPressedSurface()) }
      })
      .onClick(() => {
        if (this.selectMode) {
          this.selectedIds = toggleSelected(this.selectedIds, session.id);
        } else {
          Router.push(Route.SESSION, session.id);
        }
      })
      Divider()
        .color(borderColor())
        .strokeWidth(StrokeWidth.HAIRLINE)
    }
    .width('100%')
  }

  private visibleIds(): string[] {
    const ids: string[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      ids.push(this.sessions[i].id);
    }
    return ids;
  }

  private allVisibleSelected(): boolean {
    if (this.sessions.length === 0) {
      return false;
    }
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.selectedIds.indexOf(this.sessions[i].id) < 0) {
        return false;
      }
    }
    return true;
  }

  /** 「归档所选 / 取消归档所选」：目标由 `selectionTargetArchived` 决定，实际 id 先收敛一次。 */
  private applyBulkArchive(): void {
    if (this.bulkBusy || this.selectedIds.length === 0) {
      return;
    }
    const target = selectionTargetArchived(this.sessions, this.selectedIds);
    const ids = archiveTargetIds(this.sessions, this.selectedIds, target);
    if (ids.length === 0) {
      this.noticeText = '选中的会话已经是目标状态，无需改动。';
      return;
    }
    this.bulkBusy = true;
    this.bulkArchiveAsync(ids, target);
  }

  private async bulkArchiveAsync(ids: string[], target: boolean): Promise<void> {
    const ok = await this.store.setSessionsArchived(ids, target);
    this.bulkBusy = false;
    if (ok) {
      this.selectedIds = [];
      this.selectMode = false;
    }
    await this.dashboard.refreshAll();
    this.pullSessions();
    this.pull();
    if (!ok) {
      // pull() 会用 store.notice 覆盖提示，所以失败文案放在它之后写。
      this.noticeText = this.store.error.length > 0 ? this.store.error : '批量归档失败。';
    }
  }

  /** 「全部归档」是破坏面较大的批量写操作：上游也走确认框（`DeviceConfirmDialog`）。 */
  // -------------------------------------------------------------------------
  // R13-14：自绘确认框（上游 `DeviceConfirmDialog`）
  // -------------------------------------------------------------------------

  /**
   * 打开自绘确认框（几何 = 上游 `DeviceConfirmDialog`，见 `DialogSpec`）。
   * 四条链路（全部归档 / 撤销令牌 / 删除设备 / 删除运行时配置）共用这一套状态与内容。
   */
  private openConfirm(
    kind: string, title: string, body: string, label: string, danger: boolean, runtimeId: string
  ): void {
    this.confirmKind = kind;
    this.confirmTitle = title;
    this.confirmBody = body;
    this.confirmLabel = label;
    this.confirmDanger = danger;
    this.confirmRuntimeId = runtimeId;
    this.confirmError = '';
    this.confirmBusy = false;
    openAaConfirmDialog(this.getUIContext(), () => {
      this.confirmDialogCard()
    }, DIALOG_VARIANT_CONFIRM)
      .then((id: number) => {
        this.confirmDialogId = id;
      })
      .catch(() => {
        // 弹层起不来时**不能**跳过确认直接执行破坏性操作：押回并提示（与替换前一致）。
        this.confirmKind = '';
        this.noticeText = '无法弹出确认框，请重试。';
        this.revokePhase = confirmNext(this.revokePhase, 'cancel');
      });
  }

  private closeConfirm(): void {
    const id = this.confirmDialogId;
    this.confirmDialogId = 0;
    closeAaConfirmDialog(this.getUIContext(), id);
  }

  /** 确认：按类型分派到原有动作（动作实现一行未改）。 */
  private runConfirm(): void {
    const kind = this.confirmKind;
    const runtimeId = this.confirmRuntimeId;
    this.confirmKind = '';
    this.confirmRuntimeId = '';
    if (kind === 'archive-all') {
      this.applyArchiveAll(this.sessionFilter !== DeviceSessionsFilter.ARCHIVED);
    } else if (kind === 'revoke') {
      this.confirmRevoke();
    } else if (kind === 'delete-device') {
      this.deleteDevice();
    } else if (kind === 'clear-config') {
      this.store.clearRuntimeConfig(runtimeId);
    }
  }

  /** 确认框内容（几何与排布在 `AaConfirmDialog` + `DialogSpec` 里）。 */
  @Builder
  confirmDialogCard() {
    AaConfirmDialog({
      variant: DIALOG_VARIANT_CONFIRM,
      title: this.confirmTitle,
      body: this.confirmBody,
      confirmLabel: this.confirmLabel,
      danger: this.confirmDanger,
      busy: this.confirmBusy,
      errorMessage: this.confirmError,
      onConfirm: () => {
        this.closeConfirm();
        this.runConfirm();
      },
      onDismiss: () => {
        this.closeConfirm();
      }
    })
  }

  private promptArchiveAll(): void {
    if (this.bulkBusy || this.sessions.length === 0) {
      return;
    }
    const archived = this.sessionFilter !== DeviceSessionsFilter.ARCHIVED;
    this.openConfirm('archive-all', archiveAllTitle(archived, this.sessionFilter),
      archiveAllBody(this.nameText, archived), archiveAllConfirmLabel(archived), false, '');
  }

  private applyArchiveAll(archived: boolean): void {
    this.bulkBusy = true;
    this.archiveAllAsync(archived);
  }

  private async archiveAllAsync(archived: boolean): Promise<void> {
    // 走既有的 `DashboardStore.archiveAllForDevice`（`POST /connectors/{id}/sessions/archive-all`）。
    // 它内部的 scope 固定 `all`：取消归档时对活跃会话是幂等的，安全。
    const ok = await this.dashboard.archiveAllForDevice(this.deviceId, archived);
    this.bulkBusy = false;
    await this.dashboard.refreshAll();
    this.selectedIds = [];
    this.selectMode = false;
    this.pullSessions();
    this.pull();
    if (!ok) {
      this.noticeText = this.dashboard.error.length > 0 ? this.dashboard.error : '批量归档失败。';
    }
  }

  // -------------------------------------------------------------------------
  // A5 撤销设备令牌（二次确认 → 请求在飞 → 完成；相位由 `confirmNext` 驱动）
  // -------------------------------------------------------------------------

  private requestRevoke(): void {
    // DONE 是终态：再点一次要先 reset，否则状态机把这次点击当成「已完成」而忽略。
    if (this.revokePhase === ConfirmPhase.DONE) {
      this.revokePhase = confirmNext(this.revokePhase, 'reset');
    }
    this.revokePhase = confirmNext(this.revokePhase, 'request');
    this.revokeError = '';
    this.showRevokeDialog();
  }

  /**
   * 二次确认弹层（R13-14 起是**自绘**框，几何 = 上游 `DeviceConfirmDialog`）。
   * 弹层本身不渲染新令牌 —— 那部分在页面内的命令卡片里（用户随时能回来再看）。
   */
  private showRevokeDialog(): void {
    try {
      this.openConfirm('revoke', revokeConfirmTitle(), revokeConfirmBody(this.nameText),
        '撤销令牌', true, '');
    } catch (error) {
      // 弹窗起不来时**不能**跳过确认直接撤销（破坏性操作）：押回 IDLE 并提示重试。
      this.revokePhase = confirmNext(this.revokePhase, 'cancel');
      this.revokeError = '无法弹出确认框，请再点一次「撤销设备令牌」。';
    }
  }

  private confirmRevoke(): void {
    this.revokePhase = confirmNext(this.revokePhase, 'confirm');
    if (this.revokePhase !== ConfirmPhase.BUSY) {
      // 已有一个请求在飞（重复点击）：**不能**再发一次 —— 撤销会再签发一个令牌，
      // 多发几次会让用户手上的命令连续作废。
      return;
    }
    this.revokeAsync();
  }

  private async revokeAsync(): Promise<void> {
    const credential = await this.store.revokeToken();
    if (credential === undefined) {
      this.revokePhase = confirmNext(this.revokePhase, 'failed');
      this.pull();
      this.revokeError = this.store.error.length > 0 ? this.store.error : '无法撤销设备令牌。';
      this.noticeText = this.revokeError;
      return;
    }
    this.revokeCommand = DeviceStore.tokenCommandText(credential.deviceId, credential.deviceToken);
    this.revokeHint = '';
    this.revokePhase = confirmNext(this.revokePhase, 'settled');
    this.pull();
    this.noticeText = '已撤销该设备的令牌：旧令牌立即失效，请在该设备上运行新命令。';
    // 撤销后设备会掉线，列表里的在线状态需要重拉（设备详情本身的 store 也会再 load 一次）。
    this.dashboard.refreshAll();
  }

  /** 撤销成功后的新命令卡片（可选中 + 一键复制）。 */
  @Builder
  commandCard() {
    Column({ space: Space.S }) {
      Text(this.revokeCommand)
        .fontSize(FontSize.SMALL)
        .fontColor(ink())
        .width('100%')
        .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
        .copyOption(CopyOptions.InApp)
      Row({ space: Space.S }) {
        AaSecondaryButton({
          label: '复制命令',
          compact: true,
          onTap: () => {
            this.copyText(this.revokeCommand);
          }
        })
        if (this.revokeHint.length > 0) {
          Text(this.revokeHint)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
        }
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.M)
    .backgroundColor(raisedSurface())
    .borderWidth(1)
    .borderColor(borderColor())
    .alignItems(HorizontalAlign.Start)
  }

  /** 复制到系统剪贴板（写剪贴板不需要权限，但 SDK 标了 @throws，必须包 try）。 */
  private copyText(value: string): void {
    if (value.length === 0) {
      this.revokeHint = '命令为空，没有可复制的内容。';
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.revokeHint = '命令已复制。';
      }).catch(() => {
        this.revokeHint = '复制失败，请长按命令手动复制。';
      });
    } catch (error) {
      this.revokeHint = '复制失败，请长按命令手动复制。';
    }
  }

  // -------------------------------------------------------------------------
  // B4 Runtime 配置（可执行文件路径 + 环境变量；内联展开）
  // -------------------------------------------------------------------------

  private openConfig(runtime: RemoteDeviceRuntime): void {
    const draft = runtimeConfigDraft(runtime.config, runtime.schema);
    this.configRuntimeId = runtime.runtimeId;
    // 上游 `DeviceRuntimeConfigureSheet.kt:141` 的标题也是 `runtime.labels.primary`。
    this.configTitle = runtime.displayName.length > 0
      ? deviceRuntimeLabel(runtime.displayName, runtime.runtimeType)
      : runtime.runtimeId;
    this.configPath = draft.executablePath;
    this.configEnv = draft.environment.slice();
    this.configSupportsPath = runtimeSupportsField(runtime.schema, 'executablePath');
    this.configSupportsEnv = runtimeSupportsField(runtime.schema, 'environment');
    this.configError = '';
    this.configSaving = false;
    this.envEpoch = this.envEpoch + 1;
  }

  private closeConfig(): void {
    this.configRuntimeId = '';
    this.configPath = '';
    this.configEnv = [];
    this.configError = '';
    this.configSaving = false;
  }

  private envAt(index: number): RuntimeEnvEntry {
    if (index >= 0 && index < this.configEnv.length) {
      return this.configEnv[index];
    }
    const empty: RuntimeEnvEntry = { name: '', value: '', unset: false };
    return empty;
  }

  private updateEnv(index: number, name: string, value: string, unset: boolean): void {
    const next: RuntimeEnvEntry[] = [];
    for (let i = 0; i < this.configEnv.length; i++) {
      if (i === index) {
        next.push({ name: name, value: value, unset: unset });
      } else {
        next.push(this.configEnv[i]);
      }
    }
    this.configEnv = next;
  }

  private addEnv(): void {
    const entry: RuntimeEnvEntry = { name: '', value: '', unset: false };
    this.configEnv = this.configEnv.concat([entry]);
    this.envEpoch = this.envEpoch + 1;
  }

  private removeEnv(index: number): void {
    const next: RuntimeEnvEntry[] = [];
    for (let i = 0; i < this.configEnv.length; i++) {
      if (i !== index) {
        next.push(this.configEnv[i]);
      }
    }
    this.configEnv = next;
    this.envEpoch = this.envEpoch + 1;
  }

  private currentRuntime(): RemoteDeviceRuntime | undefined {
    for (let i = 0; i < this.runtimes.length; i++) {
      if (this.runtimes[i].runtimeId === this.configRuntimeId) {
        return this.runtimes[i];
      }
    }
    return undefined;
  }

  private saveConfig(): void {
    if (this.configSaving) {
      return;
    }
    const reason = environmentError(this.configEnv);
    if (reason.length > 0) {
      this.configError = reason;
      return;
    }
    const runtime = this.currentRuntime();
    const draft: RuntimeConfigDraft = { executablePath: this.configPath, environment: this.configEnv };
    const payload = runtimeConfigPayload(
      runtime !== undefined ? runtime.config : undefined, draft,
      this.configSupportsPath, this.configSupportsEnv);
    this.configSaving = true;
    this.configError = '';
    this.store.saveRuntimeConfig(this.configRuntimeId, payload).then((ok: boolean) => {
      this.configSaving = false;
      if (ok) {
        this.closeConfig();
      } else {
        this.configError = this.store.error.length > 0 ? this.store.error : '无法保存 Runtime 配置。';
      }
      this.pull();
    });
  }

  /** Runtime 配置编辑器（展开在对应运行时卡片下面）。 */
  @Builder
  runtimeConfigEditor() {
    Column({ space: Space.S }) {
      Text(`配置 ${this.configTitle}`)
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .width('100%')

      if (this.configSupportsPath) {
        Text('可执行文件路径（留空使用自动发现结果）')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
        TextInput({ text: this.configPath, placeholder: '/运行时/可执行文件/路径' })
          .fontSize(FontSize.SMALL)
          .height(Control.FIELD)
          .borderRadius(Radius.S)
          .borderWidth(1)
          .borderColor(borderColor())
          .onChange((value: string) => {
            this.configPath = value;
            this.configError = '';
          })
      } else {
        Text('这个 Runtime 的 schema 不支持自定义可执行文件路径。')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
      }

      if (this.configSupportsEnv) {
        Text('环境变量（勾选「移除继承值」时服务端会写 null，即删掉继承来的该项）')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
        if (this.configEnv.length === 0) {
          Text('还没有自定义环境变量。')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .width('100%')
        }
        ForEach(this.configEnv, (entry: RuntimeEnvEntry, index: number) => {
          this.envRow(index)
        }, (entry: RuntimeEnvEntry, index: number) => `env:${index}:${this.envEpoch}`)
        AaSecondaryButton({
          label: '添加环境变量',
          compact: true,
          onTap: () => {
            this.addEnv();
          }
        })
      } else {
        Text('这个 Runtime 的 schema 不支持自定义环境变量。')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
      }

      if (this.configError.length > 0) {
        Text(this.configError)
          .fontSize(FontSize.CAPTION)
          .fontColor($r('app.color.error_text'))
          .width('100%')
      }

      Row({ space: Space.S }) {
        AaSecondaryButton({
          label: this.configSaving ? '保存中…' : '保存配置',
          compact: true,
          interactive: !this.configSaving,
          onTap: () => {
            this.saveConfig();
          }
        })
        AaSecondaryButton({
          label: '取消',
          compact: true,
          onTap: () => {
            this.closeConfig();
          }
        })
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.M)
    .backgroundColor($r('app.color.subtle'))
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一行环境变量。
   *
   * 只接 `index`（不接条目对象）：条目内容全部从 `@State configEnv` 现读，
   * 这样勾选「移除继承值」这类标记变化会走**元素级依赖**刷新（坑 152 ②），
   * 而不会因为 `@Builder` 值参数不重跑（坑 38）而停在旧快照。
   */
  @Builder
  envRow(index: number) {
    Column({ space: Space.XS }) {
      Row({ space: Space.S }) {
        TextInput({ text: this.envAt(index).name, placeholder: '变量名称' })
          .fontSize(FontSize.CAPTION)
          .height(Control.FIELD_COMPACT)
          .layoutWeight(1)
          .borderRadius(Radius.S)
          .borderWidth(1)
          .borderColor(borderColor())
          .onChange((value: string) => {
            const entry = this.envAt(index);
            this.updateEnv(index, value, entry.value, entry.unset);
            this.configError = '';
          })
        if (this.envAt(index).unset) {
          Text('已改为移除继承值')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .layoutWeight(1)
        } else {
          TextInput({ text: this.envAt(index).value, placeholder: '变量值' })
            .fontSize(FontSize.CAPTION)
            .height(Control.FIELD_COMPACT)
            .layoutWeight(1)
            .borderRadius(Radius.S)
            .borderWidth(1)
            .borderColor(borderColor())
            .onChange((value: string) => {
              const entry = this.envAt(index);
              this.updateEnv(index, entry.name, value, entry.unset);
              this.configError = '';
            })
        }
      }
      .width('100%')

      Row({ space: Space.S }) {
        // 勾选框：Lucide `square-check` / `square`（本工程扩展键，上游该屏无对应 Lucide）。
        Row({ space: Space.XS }) {
          AaIcon({ d: this.envAt(index).unset ? ICONS['square-check'] : ICONS['square'], iconSize: FontSize.CAPTION, color: muted() })
          Text('移除继承值')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
        }
        .onClick(() => {
          const entry = this.envAt(index);
          this.updateEnv(index, entry.name, entry.value, !entry.unset);
        })
        Blank()
        AaSecondaryButton({
          label: '删除',
          compact: true,
          onTap: () => {
            this.removeEnv(index);
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: Space.XS, bottom: Space.XS })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 状态标签（上游 `DeviceDetailScreen.kt:557-576`）：点 16dp + 文字 13sp、间距 6dp。
   * 与标题同列、间距 8dp（上游 9dp，无同值令牌，取最接近的 `Space.S`）。
   */
  @Builder
  deviceStatusLabel() {
    Row({ space: Space.XS_PLUS }) {
      AaIcon({ d: this.onlineFlag ? ICONS['circle-check'] : ICONS['circle'], iconSize: FontSize.ICON_MD, color: this.onlineFlag ? $r('app.color.runtime_running') : muted() })
        .opacity(this.onlineFlag ? 1 : 0.4)
      // 上游 `DeviceDetailScreen.kt:572-579` 只有「在线 / 离线」（`devices_online` / `devices_offline`），
      // 系统类型由设备图标表达；本工程此前多加了 `windows ·` 前缀，按裁决去掉。
      Text(this.onlineFlag ? '在线' : '离线')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.onlineFlag ? $r('app.color.runtime_running') : muted())
        .maxLines(1)
    }
  }

  /**
   * 设备操作面板（上游 `DeviceActionsSheet.kt:51-175`）。
   *
   * 三行：重命名设备 / 撤销令牌（**离线时同一行显示「重新连接」**，上游 `:169` 的二元文案）/ 删除设备。
   * 点「重命名设备」后面板内容切换成输入框 + 取消/保存（上游 `renaming` 状态）。
   */
  @Builder
  actionsSheet() {
    Column({ space: Space.XS }) {
      if (this.renaming) {
        TextInput({ text: this.renameValue, placeholder: '设备名称' })
          .fontSize(FontSize.BODY)
          .height(Control.FIELD_LARGE)
          .borderRadius(Radius.M_PLUS)
          .backgroundColor(subtle())
          .borderWidth(StrokeWidth.HAIRLINE)
          .borderColor(borderColor())
          .padding({ left: Space.M, right: Space.M })
          .onChange((value: string) => {
            this.renameValue = value;
            this.actionsError = '';
          })
        if (this.actionsError.length > 0) {
          Text(this.actionsError)
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(errorText())
            .lineHeight(17)
            .width('100%')
            .padding({ left: Space.L, right: Space.L, bottom: Space.XS })
        }
        AaMenuActionRow({
          label: '取消',
          onTap: () => {
            this.renaming = false;
            this.actionsError = '';
          }
        })
        AaMenuActionRow({
          label: '保存',
          onTap: () => {
            this.submitRename();
          }
        })
      } else {
        AaMenuActionRow({
          label: '重命名设备',
          iconName: 'pencil',
          onTap: () => {
            this.renameValue = this.nameText;
            this.actionsError = '';
            this.renaming = true;
          }
        })
        AaMenuActionRow({
          label: this.onlineFlag ? '撤销令牌' : '重新连接',
          iconName: 'key-round',
          interactive: this.revokePhase !== ConfirmPhase.BUSY,
          onTap: () => {
            this.showActions = false;
            this.requestRevoke();
          }
        })
        AaMenuActionRow({
          label: '删除设备',
          iconName: 'trash-2',
          danger: true,
          onTap: () => {
            this.showActions = false;
            this.promptDeleteDevice();
          }
        })
        // 设备元数据（上游本页没有；按 R13-4 裁决从主列表收进这里，保留可排查性）。
        Divider()
          .color(borderColor())
          .strokeWidth(StrokeWidth.HAIRLINE)
          .margin({ top: Space.S, bottom: Space.S })
        Column({ space: Space.XS }) {
          AaInfoRow({ label: '设备 ID', value: this.deviceId, selectable: true })
          AaInfoRow({ label: '最后在线', value: this.lastSeenText })
        }
        .width('100%')
      }
    }
    .width('100%')
    // R37 六改：面板内容**回到顶部**（`Space.S`）——
    // 中间那版为了避开 `bindSheet` 自带的关闭按钮而整体下移过 44vp，现在那个按钮已经关掉
    // （`showClose: false`，见 build 里的注释），不再需要让位。
    .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.L })
    .alignItems(HorizontalAlign.Start)
  }

  /** 面板内改名（上游 `submitRename()`：空名或与原名相同直接收起）。 */
  private submitRename(): void {
    const next = this.renameValue.trim();
    if (next.length === 0 || next === this.nameText) {
      this.renaming = false;
      this.actionsError = '';
      return;
    }
    this.dashboard.renameDevice(this.deviceId, next).then((ok: boolean) => {
      if (ok) {
        this.store.deviceName = next;
        this.renaming = false;
        this.actionsError = '';
        this.showActions = false;
        this.pull();
      } else {
        this.actionsError = this.dashboard.error.length > 0 ? this.dashboard.error : '无法重命名设备。';
      }
    });
  }

  /** 删除设备确认（上游 `device_confirm_delete_device_title/body`）。 */
  private promptDeleteDevice(): void {
    try {
      this.openConfirm('delete-device', '删除这台设备？',
        '这会移除设备，并删除服务端所有关联记录，包括会话、工作区、已关联的 agent、'
          + '运行时设置和连接器令牌。之后需要重新配对才能恢复。',
        '删除', true, '');
    } catch (error) {
      this.noticeText = '无法弹出确认框，请重试。';
    }
  }

  private deleteDevice(): void {
    // `deleteDevice` 失败时返回 false（不抛）—— 不看返回值就退出页面，
    // 用户以为删掉了，其实设备还在列表里。
    this.dashboard.deleteDevice(this.deviceId).then((ok: boolean) => {
      if (ok) {
        Router.pop();
      } else {
        this.noticeText = this.dashboard.error.length > 0 ? this.dashboard.error : '无法删除设备。';
      }
    });
  }

  /** 状态点（槽 14dp、外点 14dp 淡色、内点 8dp 实心；上游 `RuntimeStatusIndicator` :734-760）。 */
  @Builder
  runtimeStatusDot(status: string) {
    Stack() {
      Circle()
        .width(Control.DOT_SLOT)
        .height(Control.DOT_SLOT)
        .fill(runtimeStatusColor(status))
        .opacity(0.25)
      Circle()
        .width(Control.DOT_INNER)
        .height(Control.DOT_INNER)
        .fill(runtimeStatusColor(status))
    }
    .width(Control.DOT_SLOT)
    .height(Control.DOT_SLOT)
  }

  /**
   * 启停开关（轨道 32×20、圆角 16、边框 2、滑块 16；上游 `WebRuntimeSwitch` :762-815）。
   *
   * 上游是自绘轨道 + 滑块，鸿蒙端没有能定尺寸到 32×20 的官方 Switch，也照抄自绘。
   */
  @Builder
  runtimeSwitch(runtimeId: string) {
    Stack() {
      Row()
        .width(Control.SWITCH_TRACK_W)
        .height(Control.SWITCH_TRACK_H)
        .borderRadius(Radius.L)
        .backgroundColor(this.runtimeIsActive(runtimeId) ? primaryAction() : subtle())
        .borderWidth(StrokeWidth.EMPHASIS)
        .borderColor(this.runtimeIsActive(runtimeId) ? primaryAction() : borderColor())
      Row()
        .width(Control.SWITCH_KNOB)
        .height(Control.SWITCH_KNOB)
        .borderRadius(Control.SWITCH_KNOB / 2)
        .backgroundColor(raisedSurface())
        .shadow({ radius: 1, color: '#14000000', offsetX: 0, offsetY: 1 })
        .translate({ x: this.runtimeIsActive(runtimeId) ? 6 : -6 })
    }
    .width(Control.SWITCH_TRACK_W)
    .height(Control.SWITCH_TRACK_H)
    .opacity(this.runtimeCanToggle(runtimeId) ? 1 : 0.45)
    .onClick(() => {
      if (!this.runtimeCanToggle(runtimeId)) {
        return;
      }
      this.store.setRuntimeActive(runtimeId, !this.runtimeIsActive(runtimeId));
    })
  }

  /**
   * 「配置 / 收起配置」文字按钮（高 34、圆角 6、文字 14sp；上游 `SmallActionButton` :1264-1322）。
   *
   * ⚠️ 配置入口本身与上游**形态不同**（上游是 `DeviceRuntimeConfigureSheet` 弹层）：
   * 本工程做成行内展开（EXPERIENCE §29：同节点只能挂一个 `bindSheet`，键盘避让在弹层里不可靠）。
   */
  @Builder
  runtimeActionButton(runtimeId: string) {
    Text(this.configRuntimeId === runtimeId ? '收起配置' : '配置')
      .fontSize(FontSize.BODY_SMALL)
      .fontWeight(FontWeight.Medium)
      .fontColor(ink())
      .height(Control.TAG)
      .padding({ left: Space.M, right: Space.M })
      .textAlign(TextAlign.Center)
      .borderRadius(Radius.XS)
      .backgroundColor(raisedSurface())
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(borderColor())
      .onClick(() => {
        this.toggleConfig(runtimeId);
      })
  }

  /**
   * 「删除运行时配置」—— 上游是**图标按钮**：`AgentIconButton(Lucide.Trash2)`（`:723-728` / `:1323-1345`），
   * 32dp 命中面 + 16dp 图标 + `tint = muted`，`contentDescription = device_detail_remove_agent`
   * 「删除运行时配置」（无障碍文案用 `accessibilityText` 落到容器上）。点击仍走原确认框。
   */
  @Builder
  runtimeDeleteButton(runtimeId: string) {
    Column() {
      AaIcon({ d: ICONS['trash-2'], iconSize: FontSize.ICON_MD, color: muted() })
    }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width(Control.NAV_BUTTON)
      .height(Control.NAV_BUTTON)
      .accessibilityText('删除运行时配置')
      .onClick(() => {
        this.promptClearConfig(runtimeId);
      })
  }

  private runtimeAt(runtimeId: string): RemoteDeviceRuntime | undefined {
    for (let i = 0; i < this.runtimes.length; i++) {
      if (this.runtimes[i].runtimeId === runtimeId) {
        return this.runtimes[i];
      }
    }
    return undefined;
  }

  private runtimeIsActive(runtimeId: string): boolean {
    const runtime = this.runtimeAt(runtimeId);
    return runtime !== undefined && runtime.active;
  }

  /** 上游 `canActivate = present && configured`（没配置就启不了，服务端也会拦）。 */
  private runtimeCanToggle(runtimeId: string): boolean {
    const runtime = this.runtimeAt(runtimeId);
    return runtime !== undefined && runtime.present && (runtime.active || runtime.configured);
  }

  /**
   * 副文 —— 成员与上游 `DeviceDetailScreen.kt:817-831` 的 `runtimeStatusLabel` 一一对应：
   * `!present` → `device_runtime_not_present`「**连接器上不存在此运行时**」、
   * `!configured` → `device_runtime_not_configured`「需要配置」，否则按状态表。
   */
  private runtimeSubtitle(runtime: RemoteDeviceRuntime): string {
    if (!runtime.present) {
      return '连接器上不存在此运行时';
    }
    if (!runtime.configured) {
      return '需要配置';
    }
    return runtimeStatusLabel(runtime.status);
  }

  private toggleConfig(runtimeId: string): void {
    if (this.configRuntimeId === runtimeId) {
      this.closeConfig();
      return;
    }
    const runtime = this.runtimeAt(runtimeId);
    if (runtime !== undefined) {
      this.openConfig(runtime);
    }
  }

  /** 清除 Runtime 配置的二次确认（上游 `DeviceConfirmAction.DeleteRuntimeConfig`）。 */
  private promptClearConfig(runtimeId: string): void {
    const runtime = this.runtimeAt(runtimeId);
    // 上游 `DeviceConfirmDialog.kt:75`：`val label = action.runtime.labels.primary`。
    const label = runtime !== undefined && runtime.displayName.length > 0
      ? deviceRuntimeLabel(runtime.displayName, runtime.runtimeType) : runtimeId;
    const running = runtime !== undefined && runtime.status === 'running';
    try {
      this.openConfirm('clear-config', `删除 ${label} 配置？`,
        running
          ? `${label} 正在运行。服务端会先停止运行时，再删除保存的配置；不会删除本地安装或已有会话。`
          : `这会删除服务端保存的 ${label} 配置，不会删除本地运行时安装或已有会话。`,
        '删除配置', true, runtimeId);
    } catch (error) {
      this.noticeText = '无法弹出确认框，请重试。';
    }
  }

  /**
   * 运行时的人类可读原因：优先 `error.message`，退回 `error.code`、`discovery.reason`。
   *
   * 优先级由 `model/SessionGating.ets` 的纯函数决定（已进 Node 单测），本方法只负责
   * 把 `JsonMap` 字段摊平成标量 —— 同样的选择逻辑也用在「新建会话」页的 Runtime 行上，
   * 两处共用一套口径，避免各写一遍后逐渐走偏。
   */
  private runtimeReason(runtime: RemoteDeviceRuntime): string {
    let errorMessage = '';
    let errorCode = '';
    let discoveryReason = '';
    const error = runtime.error;
    if (error !== undefined) {
      const message = error['message'];
      if (typeof message === 'string') {
        errorMessage = message;
      }
      const code = error['code'];
      if (typeof code === 'string') {
        errorCode = code;
      }
    }
    const discovery = runtime.discovery;
    if (discovery !== undefined) {
      const reason = discovery['reason'];
      if (typeof reason === 'string') {
        discoveryReason = reason;
      }
    }
    return gatingRuntimeReasonText(errorMessage, errorCode, discoveryReason);
  }

  /**
   * Runtime 行（上游 `ConfiguredAgentRow` :683-730）：**平铺行，无卡片容器** ——
   * 上游是 `Row(fillMaxWidth().heightIn(min = 72.dp).padding(vertical = 5.dp))`，没有底色 / 圆角 / 边框；
   * 行间由调用方插 `DetailDivider()`（`:628`）。元素间距 12dp；名称 16.5sp、副文 11.5sp；
   * 右侧是 32×20 的开关（圆角 16、边框 2、滑块 16）。
   *
   * ⚠️ 开关的启停态在**内部**按 id 现读 `@State runtimes`（元素级依赖），不靠值参数传对象
   * —— 后者是 [坑 38] 的坑（`@Builder` 值参数不因内容变化重建）。
   * 上游用的是 Switch（`WebRuntimeSwitch`），语义就是 `PUT /runtimes/{rid}/active` 的启停。
   */
  @Builder
  runtimeRow(runtime: RemoteDeviceRuntime) {
    Column({ space: Space.S }) {
      Row({ space: Space.M }) {
        this.runtimeStatusDot(runtime.status)
        Column({ space: Space.XXS }) {
          // 上游 `DeviceDetailScreen.kt:694` 是 `runtime.labels.primary`（不是服务端 displayName）：
          // DSH 上报的 displayName 就是 `DSH`，等于 runtimeType ⇒ 回落到「DeepSeek Harness」。
          Text(runtime.displayName.length > 0
            ? deviceRuntimeLabel(runtime.displayName, runtime.runtimeType)
            : runtime.runtimeId)
            .fontSize(FontSize.ROW_TITLE_LARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(ink())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          // 上游 `DeviceDetailScreen.kt:702`：`listOfNotNull(labels.secondary, runtimeStatusLabel).join(" · ")`
          Text(deviceRuntimeSecondary(runtime.displayName, runtime.runtimeType, this.runtimeSubtitle(runtime)))
            .fontSize(FontSize.CAPTION_PLUS)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        // 上游 `ConfiguredAgentRow`（`:714-729`）右侧是一个 `Row(spacedBy 8.dp)`：
        // `WebRuntimeSwitch` + `AgentIconButton(Trash2)`，**与名称同一行** —— 上游没有第二行操作条。
        Row({ space: Space.S }) {
          // ⚠️「配置」是本工程多出来的：上游 `DeviceRuntimeConfigureSheet`（`DeviceRuntimeConfigureSheet.kt:65`）
          // **全仓零调用点** ⇒ 上游当前**没有**配置入口。本工程提供实际可用的行内配置，
          // 放在本排最左，开关与垃圾桶维持上游的相对次序与 8dp 间距。
          this.runtimeActionButton(runtime.runtimeId)
          this.runtimeSwitch(runtime.runtimeId)
          this.runtimeDeleteButton(runtime.runtimeId)
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .constraintSize({ minHeight: Control.ROW_AGENT })
      .padding({ top: Space.XS, bottom: Space.XS })
      .alignItems(VerticalAlign.Center)

      // R20：原来这里还有**第二行**操作条（「默认」chip + 配置 + 垃圾桶）。已按上游删掉：
      // ① 上游 `ConfiguredAgentRow` 只有一行；
      // ② `runtime.active` 由**开关的开态**表达（`WebRuntimeSwitch(checked = runtime.active)`，`:718-722`），
      //  再挂一个「默认」chip 是**重复表达**同一件事。

      if (this.configRuntimeId === runtime.runtimeId) {
        this.runtimeConfigEditor()
      }

      // 把运行时的原因/错误摊开显示。上游有 `detailMessage`（`DeviceRuntimeState.kt` L39-42）；
      // 本工程此前只显示一个状态 chip，于是 DSH 卡在 `starting` 时用户完全看不出
      // 「正在等待本地 DSH Bridge」——界面只写「启动中」，然后就一直不动了。
      if (this.runtimeReason(runtime).length > 0) {
        Text(this.runtimeReason(runtime))
          .fontSize(FontSize.CAPTION)
          .fontColor(runtime.status === 'error'
            ? $r('app.color.error_text') : muted())
          .width('100%')
      }
    }
    .width('100%')
    // ⚠️ 这里**不能**再给 `.padding(Space.M)` / `.borderRadius` / `.backgroundColor` —— F-9：
    // 上游是平铺行（`heightIn(min=72) + padding(vertical=5)`），套白卡会让整段底色比安卓亮 21。
    .padding({ top: 5, bottom: 5 })
  }

  /** 上游 `DetailDivider`（`:1141-1148`）：1dp 全宽细线，`colors.border`，**不带左右内缩**。 */
  @Builder
  detailDivider() {
    Divider()
      .color(borderColor())
      .strokeWidth(StrokeWidth.HAIRLINE)
  }
}

export { authController };
