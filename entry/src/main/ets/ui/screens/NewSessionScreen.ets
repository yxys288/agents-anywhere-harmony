/**
 * 新建会话 / 新建项目（对应 Android `ui/screens/home/NewSessionScreen.kt`）。
 *
 * 上游 `NewProject` 与 `NewSession` **共用同一个屏**（`projectOnly = true` 时只显示项目名 + 目录），
 * 本文件同样按 `projectOnly` 分派，不再单独建页面（复刻口径见
 * 开发期验证记录 /）。
 *
 * ⚠️ 三条口径（上游实现 的易错点）：
 *  ① 未就绪态**不是错误页**，是一张引导面板：按「设备没配好 / Agent 没启动 / Runtime 未激活」分支文案与动作；
 *  ② 底部动作区**固定在滚动区之外**（不是列表的最后一项）；
 *  ③ 顶栏 **58dp**（≠ 通用 64dp，按拍板不做统一）。
 *
 * 既有能力（第八轮 mock + 真机验过）保持不变：设备 → Runtime 联动与过渡态轮询、
 * 工作区选择、`create-and-start`（含稳定 `clientMessageId`）、Runtime「不可用也列出」的诚实展示。
 *
 * 第十一轮 B5 新增（对应上游 `NewSessionPathSection.kt` + `NewSessionConfigurationCard.kt`）：
 *  ① 远程目录浏览器：主目录起点 → 逐级进入 → 上一级（越界收敛）→ 面包屑 → 三态 → 回填；
 *  ② 配置卡的「模型 / 推理强度 / 权限模式」三行，选中值随请求体的 `selections` 一起提交。
 * 两块纯逻辑都在 `model/DirBrowse.ets`（Node 可测，断言见 `tools/logic-test/suite-dirbrowse.mjs`）。
 *
 * R91 新增：**首条消息区带斜杠指令入口**（用户反馈「新建对话时看不到 /goal /plan」）。
 * 目录来自 `model/SlashCommand.ets` 的内置清单（本页会话尚未建立 ⇒ 不查服务端目录），
 * 点选只把指令填进首条消息；作用于会话的指令（/compact 等）在本页**禁用并说明理由** ——
 * 当普通消息发出去只会进模型，而用户会以为指令执行了。
 */

import { DashboardListener, DashboardStore } from '../../feature/DashboardStore';
import { DeviceStore } from '../../feature/DeviceStore';
// R86：`configMenuSurface()` 保留 —— 它是内容根**门控回退**分支（材质不可用）的底色来源。
import { AppServices, isDarkAppearance } from '../../feature/AppServices';
import { readAccessToken, readServerUrl, readUserId } from '../../store/AuthSessionStore';
import { NEW_SESSION_PREF_KEY } from '../../store/AppPreferences';
import {
  NewSessionPreferenceBook, NewSessionPreferenceEntry, NewSessionSelection, decodePreferenceBook, emptyBook,
  encodePreferenceBook, newSessionAccountKey, pickExistingId, pickRestorableDevice,
  pickRestorableRuntime, readPreferenceEntry, restoreSelection, withSelection, withTarget
} from '../../model/NewSessionPreference';
import { AgentDevice, AgentProject, AgentSession, deviceRuntimeLabel } from '../../model/AppModels';
import {
  RemoteDeviceRuntime, RemoteDirectoryEntry, RemoteRuntimeModel, RemoteRuntimeModelCatalog,
  RemoteRuntimePermission, RemoteRuntimePermissionCatalog, RemoteRuntimeReasoning,
  RemoteSessionCreateAndStartRequest
} from '../../model/Types';
import {
  DirBreadcrumb, HOME_ROOT, ModelSelection, WINDOWS_DRIVE_OVERVIEW_LABEL, breadcrumbSegments,
  browseParentPath, canonicalRemoteDirectoryPath, defaultReasoningId, displayRemotePath,
  isAbsoluteRemotePath, isSelectableRemoteDirectory, isWindowsDeviceOs, modelHasValidSelection,
  modelSelectionIdFor, permissionSelectionIdFor, reasoningOptionsFor, remoteFileRequest,
  resolveModelSelection, windowsDriveRoot,
  resolvePermissionSelection, runtimePermissionTranslationKey, sortDirectoryEntries,
  recentWorkspacePaths, workspacePathKey, workspaceProjectName
} from '../../model/DirBrowse';
import { capabilityUsable } from '../../api/Parse';
// R51：DSH 会话级 Agent 预设（可选项来自 runtime 的 `uiSchema.defaultAgentPreset`）。
import {
  AGENT_PRESET_LABEL, AgentPresetOption, agentPresetDetail, agentPresetLabel, agentPresetOptions, agentPresetRowValue,
  defaultAgentPreset, presetStillSelectable, runtimeOptionsForPreset
} from '../../model/AgentPreset';
// R91：新建会话页也要能用斜杠指令（用户反馈「新建对话时看不到 /goal /plan」）。
// 目录 = 内置清单（本页恒为草稿态语义：会话还没建立），点选只把指令填进首条消息。
import {
  SlashCommandCatalog, SlashCommandItem, appendSlashToDraft, builtInCatalog, catalogSourceLabel,
  draftCommandDisabledReason, draftSlashNotice, draftTypedCommandBlocker, draftUsableCount,
  slashCommandUsableInDraft, slashInsertionFor
} from '../../model/SlashCommand';
import { SlashCommandStore } from '../../feature/SlashCommandStore';
import { newClientMessageId } from '../../utils/Codec';
import {
  runtimeIsReady as gatingRuntimeIsReady, runtimeIsSettling as gatingRuntimeIsSettling,
  runtimeReasonText as gatingRuntimeReasonText
} from '../../model/SessionGating';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, ink, inkSoft, muted,
  onPrimaryAction, primaryAction, raisedSurface, rowPressedSurface, subtle
} from '../Design';
// R86：`dialogMaterial()` = 弹窗类小面板的官方材质入口（`REGULAR` 档，见 Components.ets:147）；
// `immersiveMaterialEnabled()` = 可用性探针，用来**门控**内容根的自绘底（材质可用时让位）。
// 与 `officialBarMaterial` 同源收口 ⇒ 本页仍然**只**引 Components，不引 `uiMaterial`。
import { AaCircleIconButton, AaConfigMenuItem, AaErrorBanner, dialogMaterial,
  immersiveMaterialEnabled } from '../Components';
import { Route, Router } from '../Router';
import { AaIcon, ICONS } from '../Icon';

/**
 * `CustomPopupOptions.onStateChange` 的入参。
 *
 * SDK 里它是**匿名对象类型**（`component/common.d.ts` 的 `(event: { isVisible: boolean }) => void`），
 * ArkTS 需要一个具名类型来标注箭头函数参数，故声明等价接口（与 `HomeScreen.ets` 同形）。
 */
interface AaPopupStateChange {
  isVisible: boolean;
}

/** 配置行下拉菜单与触发行的间距（上游 `AADropdownMenu.MenuGap = 4.dp`）。 */
const CONFIG_MENU_GAP: number = 4;

/**
 * 主按钮（上游 `StartChatButton`）的禁用不透明度。
 *
 * 锚文 `NewSessionCommonComponents.kt:88`：`val alpha = if (enabled) 1f else 0.45f`，
 * 紧接 `:94` `.background(colors.primaryAction.copy(alpha = alpha))` ——
 * **底色恒为主色，禁用只是把它降到 45%**；文字始终是全白的 `onPrimaryAction`。
 * 所以本工程旧实现的「禁用 = `subtle()` 浅灰底 + `muted()` 灰字」是自创形态（R13-12 / F-2 取证：
 * 鸿蒙禁用态行中位数 ≈240 = `subtle` #F1F0ED，与上游的合成值 ≈#909090 不是一回事）。
 */
const START_BUTTON_DISABLED_ALPHA: number = 0.45;
/** `ForwardGlyph` 画在 22dp 画布上（`Glyphs.kt:26` → `LineGlyph(sizeDp = 22)`），故图标盒取 22vp。 */
const START_BUTTON_GLYPH_SIZE: number = 22;
/**
 * `ForwardGlyph` 的线宽。
 *
 * 锚文 `Glyphs.kt:27-28`：`drawLine(..., strokeWidth = 3.2f)`，画布 22dp。
 * `AaIcon` 的 `stroke` 口径是「24 单位画布下的线宽」，故 3.2 × 24 ÷ 22 = 3.49 ≈ 3.5。
 */
const START_BUTTON_GLYPH_STROKE: number = 3.5;


@Component
export struct NewSessionScreen {
  @State deviceId: string = '';
  @State projectId: string = '';
  @State runtimeId: string = '';
  @State runtimeType: string = '';
  @State title: string = '';
  @State content: string = '';
  /**
   * R91：斜杠指令目录（本页恒为**内置清单** —— 会话还没建立，没有 sessionId 可查服务端目录）。
   *
   * 面板点选只把指令**填进首条消息**，真正发出仍由用户点「开始聊天」——
   * 「作用于会话的指令」（/compact、/export、/file）在本页禁用，理由见 model/SlashCommand.ets。
   */
  @State commandCatalog: SlashCommandCatalog = builtInCatalog();
  @State commandPanelOpen: boolean = false;
  @State commandNotice: string = '';
  @State runtimes: RemoteDeviceRuntime[] = [];
  @State loadingRuntimes: boolean = false;
  @State creating: boolean = false;
  @State error: string = '';
  @State newProjectName: string = '';
  @State creatingProject: boolean = false;
  @State pendingWorkspace: string = '';
  /**
   * `NewProject` 模式（上游同一屏的 `projectOnly`）：只显示项目名 + 目录，隐藏设备/Agent/模型区块。
   * 由进入时的目的地决定（`Route.NEW_PROJECT`），见 `resolveEntryMode()`。
   *
   * ## ⚠️ R82：这段「模式分派」是**有意保留**，不是漏删的死代码
   * 删除 `Route.NEW_SESSION`（死路由）之后，本屏**只剩 `Route.NEW_PROJECT` 一个入口** ⇒
   * 真机上 `projectOnly` **恒为 true**，非 project 分支（设备 / Agent / 模型 / 首条消息那一整套）
   * 当前**无入口**。它**按上游同屏口径保留**：上游 `AppDestination.NewSession` 与 `NewProject`
   * 共用同一个 `NewSessionScreen`，本工程照抄这一屏的分派结构（`docs`/CHANGELOG 的 R53/R82 记录），
   * 将来若重新开放「新建会话」入口，这里不需要重写。
   * ⇒ **下一轮不要当死代码再删一遍**；要删必须先由用户明确否掉「新建会话」这个目的地。
   */
  @State projectOnly: boolean = false;
  /** 配置卡里当前展开的行（'' = 都收起）。 */
  @State expandedRow: string = '';
  /**
   * store → @State 快照。**build 绝不能直接读 `this.dashboard.devices`**：
   * `dashboard` 是普通字段，ArkUI 只在 build 期间读过的 @State 上登记渲染依赖，
   * 直接读 store 会出现「数据到了、界面不动」（坑 134，本工程最贵的一课）。
   */
  @State devices: AgentDevice[] = [];
  @State projects: AgentProject[] = [];
  @State dashboardError: string = '';
  /**
   * 本次「创建并开始」的稳定消息 id。
   *
   * DSH 运行时硬性要求（见 `createSession()` 内注释）；跨重试保持不变，
   * 避免「其实建成了但响应丢了」时重试建出第二条会话。
   */
  @State pendingClientMessageId: string = '';

  // -------------------------------------------------------------------------
  // 第十一轮 B5：远程目录浏览器（对应上游 NewSessionPathSection.kt）
  // -------------------------------------------------------------------------

  /** 浏览面板是否展开（上游 `choosePath`）：展开时工作区区块被浏览面板取代。 */
  @State browseOpen: boolean = false;
  /** 浏览根：面包屑与「上一级」的天花板（设备主目录；解析失败时退化成 `~`）。 */
  @State browseRoot: string = '';
  /** 当前目录（服务端回话经 `canonicalRemoteDirectoryPath` 归一后的形态）。 */
  @State browsePath: string = '';
  /** 当前列出的子目录（已过滤非目录项并按名排序）。 */
  @State browseEntries: RemoteDirectoryEntry[] = [];
  /** 面包屑（第一节固定是浏览根）。 */
  @State browseCrumbs: DirBreadcrumb[] = [];
  @State browseLoading: boolean = false;
  @State browseError: string = '';
  /** 失败重试要回到的路径（上游 `retryDirectoryPath`）。 */
  @State browseRetryPath: string = '';
  /**
   * 新建会话侧选定的工作目录（回填目标）。
   * `NewProject` 模式复用既有 `pendingWorkspace` 输入框，不另开一个状态。
   */
  @State workspacePath: string = '';
  /**
   * 设备主目录（上游 `homePath`）：进页面后解析一次，用作浏览起点（上游 `onBrowse` 开在
   * 主目录）。解析失败保持空串 —— 浏览时退回 `~`，由服务端按 root 解析。
   */
  @State homePath: string = '';
  /** 会话快照（最近使用的工作目录要用 cwd）—— build 不直接读 store（见 pull() 注释）。 */
  @State sessions: AgentSession[] = [];

  // -------------------------------------------------------------------------
  // 第十一轮 B5：模型 / 推理强度 / 权限（对应上游 NewSessionConfigurationCard）
  // -------------------------------------------------------------------------

  @State modelOptions: RemoteRuntimeModel[] = [];
  @State reasoningOptions: RemoteRuntimeReasoning[] = [];
  @State permissionOptions: RemoteRuntimePermission[] = [];
  @State selectedModelId: string = '';
  @State selectedReasoningId: string = '';
  @State selectedPermissionId: string = '';
  @State catalogLoading: boolean = false;
  /** 目录加载失败的原因（与「能力不可用」区分开，见 `catalogNote()`）。 */
  @State catalogError: string = '';
  /** 运行时能力里是否**声称**提供模型 / 权限目录（不可用时不显示对应行）。 */
  @State modelCatalogAvailable: boolean = false;
  @State permissionCatalogAvailable: boolean = false;
  /**
   * **DSH Agent 预设**（R51）：选项来自所选 runtime 的 `uiSchema.defaultAgentPreset.options`。
   * 只有提供预设的 runtime（目前是 DSH）才有这个字段 ⇒ 别的 runtime 这里是空数组、整行不显示。
   */
  @State agentPresetOptions: AgentPresetOption[] = [];
  @State selectedAgentPresetId: string = '';

  private dashboard: DashboardStore = DashboardStore.get();
  /** 存成字段才能被 `offChange` 摘除（单例 store 的监听器数组只增不减）。 */
  private storeListener: DashboardListener = () => {
    this.pull();
  };

  aboutToAppear(): void {
    this.alive = true;
    this.loadPreference();
    this.resolveEntryMode();
    this.dashboard.onChange(this.storeListener);
    this.pull();
    if (this.dashboard.devices.length === 0) {
      this.dashboard.refreshAll().then(() => {
        if (!this.alive) {
          return;
        }
        this.pull();
        this.selectDefaultDevice();
      });
    } else {
      this.selectDefaultDevice();
    }
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.dashboard.offChange(this.storeListener);
  }

  /** 页面是否还活着：`refreshAll()` 等异步链路返回后要复查。 */
  private alive: boolean = false;

  // -------------------------------------------------------------------------
  // 上次选择（R47，用户原话「新建能保留默认设置」）
  // -------------------------------------------------------------------------

  /** 已解码的偏好整本（内存态；磁盘原文在 `AppStorage` 的 `aaNewSessionPref`）。 */
  private prefBook: NewSessionPreferenceBook = emptyBook();
  /** 当前账号键（服务器 + 用户）；空串 = 还没登录到能定位账号的程度 ⇒ 不读也不写。 */
  private prefAccount: string = '';
  /**
   * 目录类恢复是否已经做过一次（模型 / 权限各一个标志）。
   *
   * ⚠️ 必须只做一次：这两个目录函数在「设备 / Agent 切换」时都会重跑，
   * 若每次都拿偏好覆盖，用户刚手动改的选择会被立刻顶回去。
   * 切换设备/Agent 时由 `loadRuntimeConfiguration()` 重新置 false（那是新作用域，该恢复新记忆）。
   */
  private prefRestoredModel: boolean = false;
  private prefRestoredPermission: boolean = false;
  /** R52：Agent 预设同款「只恢复一次」闸。 */
  private prefRestoredAgentPreset: boolean = false;

  /** 读一次偏好（进页面时调；读不到就是空书，不报错）。 */
  private loadPreference(): void {
    this.prefAccount = newSessionAccountKey(readServerUrl(), readUserId());
    const raw = AppStorage.get<string>(NEW_SESSION_PREF_KEY);
    this.prefBook = decodePreferenceBook(raw !== undefined ? raw : '');
  }

  /** 落盘（内存态 → 磁盘）。账号未知时什么都不做。 */
  private persistPreference(): void {
    if (this.prefAccount.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(NEW_SESSION_PREF_KEY, encodePreferenceBook(this.prefBook));
  }

  private preferenceEntry(): NewSessionPreferenceEntry | undefined {
    return readPreferenceEntry(this.prefBook, this.prefAccount);
  }

  /** 记住「设备 + Agent」这一对（用户显式选择时调）。 */
  private rememberTarget(): void {
    const next = withTarget(this.prefBook, this.prefAccount, this.deviceId, this.runtimeId);
    if (next === this.prefBook) {
      return;
    }
    this.prefBook = next;
    this.persistPreference();
  }

  /** 记住当前作用域下的三项选择（用户显式选择时调）。 */
  private rememberSelection(): void {
    const selection: NewSessionSelection = {
      modelId: this.selectedModelId,
      reasoningId: this.selectedReasoningId,
      permissionId: this.selectedPermissionId,
      agentPresetId: this.selectedAgentPresetId
    };
    const next = withSelection(this.prefBook, this.prefAccount, this.deviceId, this.runtimeId, selection);
    if (next === this.prefBook) {
      return;
    }
    this.prefBook = next;
    this.persistPreference();
  }

  /** 目录请求序号：快速连点两个目录时，先发的请求可能后到（上游 `directoryRequestId` 同义）。 */
  private browseRequestId: number = 0;
  /** 运行时配置请求序号：设备或 Runtime 一变就作废旧响应。 */
  private catalogRequestId: number = 0;

  /**
   * 按进入时的目的地决定是不是 `NewProject` 模式。
   *
   * 上游是同一个 `NewSessionScreen` 靠 `AppDestination.NewProject` 复用；本工程用
   * `Router.current().route` 判定，**不需要** Router 端多传参数（`Route.NEW_PROJECT` 已存在）。
   */
  private resolveEntryMode(): void {
    const entry = Router.current();
    this.projectOnly = entry.route === Route.NEW_PROJECT;
  }

  /** store → @State 快照（build 只读这些字段）。 */
  private pull(): void {
    this.devices = this.dashboard.devices.slice();
    this.projects = this.dashboard.projects.slice();
    this.sessions = this.dashboard.activeSessions.slice();
    this.dashboardError = this.dashboard.error;
  }

  /**
   * 选默认设备。R47 起**优先恢复「上次用的设备」**（它仍在列表里才用），否则回落第一个。
   * 恢复必须在设备列表到位之后、且只在这一处做 —— 冷启动时列表是异步来的。
   */
  private selectDefaultDevice(): void {
    if (this.deviceId.length > 0 || this.devices.length === 0) {
      return;
    }
    const ids: string[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      ids.push(this.devices[i].id);
    }
    const remembered = pickRestorableDevice(this.preferenceEntry(), ids);
    this.deviceId = remembered.length > 0 ? remembered : this.devices[0].id;
    this.pickProjectForDevice();
    this.loadRuntimes();
  }

  private pickProjectForDevice(): void {
    const projects = this.projectsForDevice();
    if (projects.length > 0) {
      this.projectId = projects[0].id;
      // 工作目录默认跟着项目走（上游 `selectedWorkspacePath = project?.workspacePath ?: resolved`）。
      if (projects[0].workspacePath.length > 0) {
        this.workspacePath = projects[0].workspacePath;
      }
    } else {
      this.projectId = '';
    }
  }

  private projectsForDevice(): AgentProject[] {
    const out: AgentProject[] = [];
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].connectorId === this.deviceId) {
        out.push(this.projects[i]);
      }
    }
    return out;
  }

  private deviceNameById(deviceId: string): string {
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].id === deviceId) {
        return this.devices[i].name;
      }
    }
    return '未选择';
  }

  private async loadRuntimes(): Promise<void> {
    if (this.deviceId.length === 0) {
      return;
    }
    this.loadingRuntimes = true;
    this.error = '';
    try {
      await this.fetchRuntimes();
    } finally {
      this.loadingRuntimes = false;
    }
    // 有运行时还在启动/停止 → 起一轮退避轮询，等它落定后自动出现在可选列表里。
    // ⚠️ 放在这里而不是 `fetchRuntimes()` 里：轮询自己也会调 `fetchRuntimes()`，
    // 若把调度写在 fetch 内就会 attempt 永远归零、退避失效（见 `scheduleRuntimePoll` 注释）。
    this.scheduleRuntimePoll(0);
    // 设备就绪后解析一次主目录（上游 `LaunchedEffect(selectedDevice?.id, creatingProject)`）。
    if (this.homePath.length === 0) {
      this.resolveHomePath().then(() => {});
    }
  }

  /**
   * 拉一次运行时列表并重算选中项。**不含**轮询调度（轮询走 `scheduleRuntimePoll`）。
   */
  private async fetchRuntimes(): Promise<void> {
    const previousRuntimeId = this.runtimeId;
    try {
      const serverUrl = readServerUrl();
      const token = readAccessToken();
      const list = await AppServices.get().devices.listDeviceRuntimes(serverUrl, token, this.deviceId);
      this.runtimes = list.runtimes;
      // ⚠️ 自动选中必须挑**真正可用**的那个，不能无脑取 `runtimes[0]`。
      // 服务端 create-and-start 会 `require_running=True`（`session_run.py` L176-182 →
      // `device_runtimes.ensure_active_running`），要求运行时 **active 且已配置**；
      // 选中一个没启用的运行时，用户填完消息点「创建并开始」只会收到
      // `runtime instance 'rti_…' is not running (status='stopped')`（真机实测过
      // `status='starting'` 的同款报错）。这里把选择收敛到就绪集合上。
      const ready = this.readyRuntimes();
      const current = this.findRuntime(this.runtimeId);
      const currentUsable = this.runtimeId.length > 0 && runtimeIsReady(current);
      if (!currentUsable && ready.length > 0) {
        // R47：先试「上次用的 Agent」——`pickRestorableRuntime` 已校验它属于**这台设备**且仍就绪，
        // 只有它不可用才回落到「第一个 active 的就绪项」。
        const readyIds: string[] = [];
        for (let i = 0; i < ready.length; i++) {
          readyIds.push(ready[i].runtimeId);
        }
        const rememberedRuntime = pickRestorableRuntime(this.preferenceEntry(), this.deviceId, readyIds);
        let chosen: RemoteDeviceRuntime | undefined = rememberedRuntime.length > 0
          ? this.findRuntime(rememberedRuntime) : undefined;
        if (chosen === undefined) {
          chosen = ready[0];
          for (let i = 0; i < ready.length; i++) {
            if (ready[i].active) {
              chosen = ready[i];
              break;
            }
          }
        }
        this.runtimeId = chosen.runtimeId;
        this.runtimeType = chosen.runtimeType;
      } else if (!currentUsable && this.runtimes.length > 0) {
        // 一个都没就绪：清掉选择，让按钮如实禁用并给出原因，而不是留一个必然失败的选中项。
        this.runtimeId = '';
        this.runtimeType = '';
      }
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    }
    // 自动选中（或清空）了 Runtime → 模型 / 权限目录跟着重载。
    if (previousRuntimeId !== this.runtimeId) {
      this.loadRuntimeConfiguration().then(() => {});
    }
  }

  private findRuntime(runtimeId: string): RemoteDeviceRuntime | undefined {
    for (let i = 0; i < this.runtimes.length; i++) {
      if (this.runtimes[i].runtimeId === runtimeId) {
        return this.runtimes[i];
      }
    }
    return undefined;
  }

  /**
   * 运行时在过渡态时自动轮询，直到就绪（或有结果）。
   *
   * 为什么必须有：运行时从 `starting` 变 `running` 是**服务端/Connector 侧发生**的，
   * 本页只在自己 `aboutToAppear` 时拉过一次列表 —— 不轮询的话，用户看着「启动中」
   * 一直不变、按钮一直不可点，只能退出去重进（真机反馈的「新建不了会话」里
   * 有一半是这个观感问题）。退避间隔与上游一致（[500,1000,2000,4000,8000]）。
   *
   * ⚠️ 递归入口必须是 `fetchRuntimes()` 而**不是** `loadRuntimes()`：
   * `loadRuntimes()` 末尾会 `scheduleRuntimePoll(0)`，两者互调会把 attempt 永远重置回 0，
   * 退避形同虚设、变成每 500ms 一次的无限请求循环 —— 真机上直接把应用拖死
   * （进程被杀，表现为「切页面就退回桌面」）。本工程实测踩过。
   */
  private scheduleRuntimePoll(attempt: number): void {
    const delays: number[] = [500, 1000, 2000, 4000, 8000];
    if (attempt >= delays.length || !this.alive) {
      return;
    }
    // 已经有就绪的运行时且已选中 → 不必再轮询。
    if (this.readyRuntimes().length > 0 && this.runtimeId.length > 0) {
      return;
    }
    if (this.runtimes.length === 0 || !this.runtimeIsSettling()) {
      return;
    }
    setTimeout(() => {
      if (!this.alive) {
        return;
      }
      // 只拉列表、不再触发新一轮调度（调度由这里的 attempt + 1 负责）。
      this.fetchRuntimes().then(() => {
        this.scheduleRuntimePoll(attempt + 1);
      });
    }, delays[attempt]);
  }

  /** 就绪可用的运行时（对应上游 `activeNewSessionRuntimes`：configured && active && running）。 */
  private readyRuntimes(): RemoteDeviceRuntime[] {
    const out: RemoteDeviceRuntime[] = [];
    for (let i = 0; i < this.runtimes.length; i++) {
      if (runtimeIsReady(this.runtimes[i])) {
        out.push(this.runtimes[i]);
      }
    }
    return out;
  }

  /**
   * 当前有没有「正在切换状态」的运行时（启动中/停止中）。
   *
   * 对应上游 `newSessionInventoryNeedsSettling`：此时列表看着有运行时、其实还不能用，
   * 界面必须说清楚「等一下」，否则用户只会看到「选了却建不了」。
   */
  private runtimeIsSettling(): boolean {
    for (let i = 0; i < this.runtimes.length; i++) {
      const runtime = this.runtimes[i];
      if (gatingRuntimeIsSettling(runtime.active, runtime.status)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 第一个处于过渡态的运行时给出的原因（没有就返回空串）。
   *
   * 用于把「为什么还没就绪」写到创建按钮上方 —— 单看「启动中」三个字，
   * 用户无法区分「再等 2 秒」和「本地 DSH 插件没开，等到明天也不会好」。
   */
  private firstRuntimeReason(): string {
    for (let i = 0; i < this.runtimes.length; i++) {
      const runtime = this.runtimes[i];
      if (!gatingRuntimeIsSettling(runtime.active, runtime.status)) {
        continue;
      }
      const reason = runtimeReasonText(runtime);
      if (reason.length > 0) {
        return reason;
      }
    }
    return '';
  }

  // -------------------------------------------------------------------------
  // 就绪判定与引导面板（易错点 1）
  // -------------------------------------------------------------------------

  /** 就绪 = 有设备（非 NewProject 模式还要有可用 Runtime）。 */
  private isReady(): boolean {
    if (this.devices.length === 0) {
      return false;
    }
    if (this.projectOnly) {
      return true;
    }
    return this.readyRuntimes().length > 0;
  }

  /** 未就绪的四种分支：没有设备 / 正在检查 / 没发现 Agent / Agent 没启动（含过渡态）。 */
  private setupKind(): string {
    if (this.devices.length === 0) {
      return 'no-device';
    }
    if (this.loadingRuntimes) {
      return 'loading';
    }
    if (this.runtimes.length === 0) {
      return 'no-runtime';
    }
    if (this.runtimeIsSettling()) {
      return 'settling';
    }
    return 'inactive';
  }

  private setupTitle(): string {
    const kind = this.setupKind();
    if (kind === 'no-device') {
      return '还没有配对的设备';
    }
    if (kind === 'loading') {
      return '正在检查设备上的 Agent…';
    }
    if (kind === 'no-runtime') {
      return '这台设备上还没发现 Agent';
    }
    if (kind === 'settling') {
      return 'Agent 正在启动';
    }
    return 'Agent 还没有启用';
  }

  private setupDescription(): string {
    const kind = this.setupKind();
    if (kind === 'no-device') {
      return '先在工作电脑上运行 Connector，再用配对码把它接到这里。';
    }
    if (kind === 'loading') {
      return '稍候片刻，检查完会自动进入下一步。';
    }
    if (kind === 'no-runtime') {
      return '到设备详情里点「发现 Runtime」，看看这台设备上装了哪些 Agent。';
    }
    if (kind === 'settling') {
      const why = this.firstRuntimeReason();
      return why.length > 0 ? `请稍候，${why}` : '请稍候，就绪后会自动出现在可选列表里。';
    }
    return '到设备详情里点「启动」，启用后就能新建会话了。';
  }

  /** 设置面板主按钮是否可点（上游 NewSessionSetupPanel.kt:69 的 enabled = !retry || !refreshing）。 */
  private setupActionEnabled(): boolean {
    return this.setupActionLabel().length > 0;
  }

  private setupActionLabel(): string {
    const kind = this.setupKind();
    if (kind === 'no-device') {
      return '配对新设备';
    }
    if (kind === 'loading') {
      return '';
    }
    if (kind === 'no-runtime') {
      return '去设备详情';
    }
    if (kind === 'settling') {
      return '重新检查';
    }
    return '去设备详情启动';
  }

  private runSetupAction(): void {
    const kind = this.setupKind();
    if (kind === 'no-device') {
      Router.push(Route.ADD_DEVICE);
      return;
    }
    if (kind === 'settling') {
      this.loadRuntimes();
      return;
    }
    Router.push(Route.DEVICE, this.deviceId);
  }

  // -------------------------------------------------------------------------
  // 目录浏览器（对应上游 NewSessionScreen.kt 的 choosePath + NewSessionPathSection.kt）
  // -------------------------------------------------------------------------

  private deviceOs(): string {
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (device.id === this.deviceId) {
        // ⚠️ ArkTS 不对「重复取同一可选属性」做窄化（`x.a !== undefined ? x.a : ''` 会报
        // string | undefined 不可赋给 string），必须先落到局部变量。
        const deviceOs = device.deviceOs;
        return deviceOs !== undefined ? deviceOs : '';
      }
    }
    return '';
  }

  /** 浏览面板标题：新建项目是「项目目录」，新建会话是「选择路径」（取上游逐字文案）。 */
  private browseTitle(): string {
    return this.projectOnly ? '项目目录' : '选择路径';
  }

  /** 打开浏览面板：起点是「已选工作区（项目路径 / 路径输入框）」，没有才去解析主目录。 */
  private openBrowse(): void {
    if (this.deviceId.length === 0) {
      this.error = '请先选择设备。';
      return;
    }
    this.expandedRow = '';
    this.browseOpen = true;
    this.browseEntries = [];
    this.browseCrumbs = [];
    this.browseError = '';
    this.browseLoading = false;
    const start = this.browseStartPath().trim();
    this.browseRoot = start.length > 0 ? start : HOME_ROOT;
    // 起点为 `.` 时服务端按 root 解析（上游 `if (home == "~") "." else home` 同义）。
    this.browseTo(start.length > 0 ? start : '.').then(() => {});
  }

  /**
   * 浏览起点。
   *  - 新建会话：**主目录**（上游 `onBrowse` 用的是 `homePath ?: "~"`，不跟随当前工作目录）；
   *  - 新建项目：输入框里已填的路径，否则主目录（上游是 `currentPath.ifBlank { homePath ?: "~" }`）。
   */
  private browseStartPath(): string {
    if (this.projectOnly) {
      if (this.pendingWorkspace.trim().length > 0) {
        return this.pendingWorkspace;
      }
      return this.homePath;
    }
    if (this.homePath.length > 0) {
      return this.homePath;
    }
    if (this.workspacePath.trim().length > 0) {
      return this.workspacePath;
    }
    return this.selectedProjectPath();
  }

  /**
   * 解析设备主目录（上游 `onListDirectory(deviceId, "~", ".")` 的 path 即主目录）。
   * 失败静默（上游同样有 8s 超时 + 回落 `~`）：浏览时再用 `~` 试一次。
   */
  private async resolveHomePath(): Promise<void> {
    const deviceId = this.deviceId;
    if (deviceId.length === 0) {
      return;
    }
    const deviceOs = this.deviceOs();
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const directory = await AppServices.get().files.listFiles(
        serverUrl, token, deviceId, HOME_ROOT, '.');
      if (deviceId !== this.deviceId) {
        return;
      }
      const resolved = canonicalRemoteDirectoryPath(
        remoteFileRequest('.', deviceOs, HOME_ROOT), directory.path, deviceOs);
      if (resolved.length > 0 && resolved !== '.') {
        this.homePath = resolved;
      }
    } catch (error) {
      this.homePath = '';
    }
  }

  private selectedProjectPath(): string {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].id === this.projectId) {
        return this.projects[i].workspacePath;
      }
    }
    return '';
  }

  private closeBrowse(): void {
    this.browseOpen = false;
    this.browseError = '';
  }

  /**
   * 列一个目录。
   *
   * 三条口径（都是真实缺陷的判据）：
   *  ① `requestId` 复查：先发后到的响应会把用户已经切走的目录又刷回来；
   *  ② 设备换掉之后旧响应一律丢弃（上游 `selectedDeviceId != device.id` 同义）；
   *  ③ `targetType == 'file'` 要显式报错 —— 上游 `listNewSessionDirectory` 里有
   *  `require(directory.targetType != "file")`，否则用户会「进到一个文件里」看着像空目录。
   */
  private async browseTo(target: string): Promise<void> {
    const deviceId = this.deviceId;
    if (deviceId.length === 0) {
      return;
    }
    const deviceOs = this.deviceOs();
    const root = this.browseRoot.length > 0 ? this.browseRoot : HOME_ROOT;
    const request = remoteFileRequest(target, deviceOs, root);
    this.browseRequestId += 1;
    const requestId = this.browseRequestId;
    this.browseRetryPath = target;
    this.browseLoading = true;
    this.browseError = '';
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const directory = await AppServices.get().files.listFiles(
        serverUrl, token, deviceId, request.root, request.path);
      if (requestId !== this.browseRequestId || deviceId !== this.deviceId) {
        return;
      }
      if (directory.targetType === 'file') {
        this.browseEntries = [];
        this.browseCrumbs = [];
        // 上游 `listNewSessionDirectory` 的 `require(targetType != "file")` 消息就是这句英文，
        // 中文资源里没有对应条目 —— 逐字照上游（不自创中文）。
        this.browseError = 'Choose a directory, not a file.';
        return;
      }
      const nextPath = canonicalRemoteDirectoryPath(request, directory.path, deviceOs);
      this.browsePath = nextPath;
      // ① Windows 设备：浏览根**恒为盘符根**（上游 `DeviceFilesContent.kt:381-383` 的
      //  `resolvedRoot = windowsDriveRoot(nextDirectory.path)`）。
      //  ⚠️ R14 实测：漏了这一步时，root 会停在原始 homePath `C:\Users\<user>`，
      //  于是面包屑只切出末段「<user>」一节（正确应是 `C: / Users / <user>`）——
      //  因为 `isAbsoluteRemotePath('C:\Users\<user>')` 为真，下面那条「非绝对才收敛」根本不触发。
      // ② 其余平台：根还没解析成绝对路径（`~`）时用服务端回话把根定下来：
      //  面包屑必须有「已知根」可切，否则只能显示一节（坑 140 的判据）。
      if (isAbsoluteRemotePath(nextPath)) {
        const driveRoot = isWindowsDeviceOs(deviceOs) ? windowsDriveRoot(nextPath) : undefined;
        if (driveRoot !== undefined) {
          this.browseRoot = driveRoot;
        } else if (!isAbsoluteRemotePath(root)) {
          this.browseRoot = nextPath;
        }
      }
      this.browseEntries = sortDirectoryEntries(directory.entries);
      this.browseCrumbs = breadcrumbSegments(
        this.browseRoot, nextPath, deviceOs, this.browseRootFallbackLabel());
    } catch (error) {
      if (requestId !== this.browseRequestId || deviceId !== this.deviceId) {
        return;
      }
      this.browseEntries = [];
      this.browseCrumbs = breadcrumbSegments(
        this.browseRoot, this.browsePath, deviceOs, this.browseRootFallbackLabel());
      const message = error instanceof Error ? (error as Error).message : String(error);
      // 上游 `loadDirectory` 的 onFailure：优先服务端消息，空则用
      // `new_session_load_directory_failed` =「无法加载这个目录。」。
      this.browseError = message.length > 0 ? message : '无法加载这个目录。';
    } finally {
      if (requestId === this.browseRequestId && deviceId === this.deviceId) {
        this.browseLoading = false;
      }
    }
  }

  /** 面包屑第一节的兜底标签（根是 `~` / `.` 时用）。 */
  private browseRootFallbackLabel(): string {
    return '主目录';
  }

  /** 「上一级」的目标：越界时收敛回根（复用 model/RemotePaths 的判定语义）。 */
  private browseParentTarget(): string | undefined {
    if (this.browsePath.trim().length === 0) {
      return undefined;
    }
    return browseParentPath(this.browsePath, this.browseRoot, this.deviceOs(), true);
  }

  private browseGoParent(): void {
    const parent = this.browseParentTarget();
    if (parent === undefined || this.browseLoading) {
      return;
    }
    this.browseTo(parent).then(() => {});
  }

  private browseInto(entry: RemoteDirectoryEntry): void {
    if (this.browseLoading) {
      return;
    }
    this.browseTo(entry.path).then(() => {});
  }

  private browseToCrumb(segment: DirBreadcrumb): void {
    if (this.browseLoading) {
      return;
    }
    this.browseTo(segment.path).then(() => {});
  }

  private browseRetry(): void {
    const target = this.browseRetryPath.length > 0 ? this.browseRetryPath : this.browsePath;
    this.browseTo(target).then(() => {});
  }

  /** 「完成」是否可点（上游 `canUseCurrentPath && !loading && error == null`）。 */
  private browseCanUseCurrent(): boolean {
    return !this.browseLoading && this.browseError.length === 0
      && isSelectableRemoteDirectory(this.browsePath, this.deviceOs());
  }

  /** 目录条上显示的路径（绝对路径原样、相对路径拼到根后面）。 */
  private browsePathLabel(): string {
    return displayRemotePath(
      this.browseRoot, this.browsePath, this.deviceOs(), WINDOWS_DRIVE_OVERVIEW_LABEL);
  }

  /** 选定当前目录并回填（新建会话 → 工作目录；新建项目 → 路径输入框）。 */
  private browseUseCurrent(): void {
    if (!this.browseCanUseCurrent()) {
      return;
    }
    const chosen = this.browsePath.trim();
    if (chosen.length === 0) {
      return;
    }
    if (this.projectOnly) {
      this.pendingWorkspace = chosen;
      // 上游 NewProject：名字没被手工改过就用目录名（`useDirectoryName = !nameEdited`）。
      if (this.newProjectName.trim().length === 0) {
        this.newProjectName = workspaceProjectName(chosen);
      }
    } else {
      this.workspacePath = chosen;
      this.syncProjectForWorkspace(chosen);
    }
    this.browseOpen = false;
    this.browseError = '';
  }

  /** 把工作目录与已存在的项目对齐（上游 `workspaceProject(...)` 的用途）。 */
  private syncProjectForWorkspace(path: string): void {
    const key = workspacePathKey(path, this.deviceOs());
    if (key.length === 0) {
      return;
    }
    for (let i = 0; i < this.projects.length; i++) {
      const project = this.projects[i];
      if (project.connectorId === this.deviceId
        && workspacePathKey(project.workspacePath, this.deviceOs()) === key) {
        this.projectId = project.id;
        return;
      }
    }
    // R48：目录不属于任何项目时**清掉项目选择** —— 否则会留下「工作目录是 A、项目是 B」的不一致，
    // 而提交时两者都会发给服务端。
    this.projectId = '';
  }

  /** 工作目录是否就是某个项目的目录（决定项目行的高亮）。 */
  private isProjectSelected(project: AgentProject): boolean {
    if (this.projectId === project.id && this.workspacePath.trim().length === 0) {
      return true;
    }
    const current = this.workspacePath.trim().length > 0 ? this.workspacePath : this.selectedProjectPath();
    const key = workspacePathKey(current, this.deviceOs());
    return key.length > 0
      && workspacePathKey(project.workspacePath, this.deviceOs()) === key;
  }

  /** 提交时用的工作目录（浏览选定优先，其次所选项目）。 */
  private effectiveWorkspacePath(): string {
    if (this.workspacePath.trim().length > 0) {
      return this.workspacePath.trim();
    }
    return this.selectedProjectPath().trim();
  }

  // -------------------------------------------------------------------------
  // 运行时配置：模型 / 推理强度 / 权限（对应上游 NewSessionRuntimeSelectionState.kt）
  // -------------------------------------------------------------------------

  /**
   * 设备 / Runtime 变化后重新拉能力与两个目录（上游 `loadRuntimeDetails`）。
   *
   * 与上游一致：先看能力集，只有 `catalog.model` / `catalog.permission` 可用才发起目录请求；
   * 能力不可用是**正常状态**（该 Runtime 不提供），不是错误 —— 界面据此隐藏对应行。
   */
  private async loadRuntimeConfiguration(): Promise<void> {
    const deviceId = this.deviceId;
    const runtimeId = this.runtimeId;
    this.catalogRequestId += 1;
    const requestId = this.catalogRequestId;
    this.modelOptions = [];
    this.reasoningOptions = [];
    this.permissionOptions = [];
    this.selectedModelId = '';
    this.selectedReasoningId = '';
    this.selectedPermissionId = '';
    // R51：Agent 预设随 runtime 一起换（它就在 runtime 描述里，**不需要额外请求**）。
    this.agentPresetOptions = [];
    this.selectedAgentPresetId = '';
    this.applyAgentPreset();
    this.modelCatalogAvailable = false;
    this.permissionCatalogAvailable = false;
    this.catalogError = '';
    // R47：换了设备 / Agent ⇒ 这是新作用域，允许再用它的「上次选择」覆盖一次默认。
    this.prefRestoredModel = false;
    this.prefRestoredPermission = false;
    // R52：Agent 预设同理。
    this.prefRestoredAgentPreset = false;
    if (deviceId.length === 0 || runtimeId.length === 0) {
      this.catalogLoading = false;
      return;
    }
    this.catalogLoading = true;
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const capabilities = await AppServices.get().devices.getDeviceRuntimeCapabilities(
        serverUrl, token, deviceId, runtimeId);
      if (!this.isCurrentCatalogRequest(requestId, deviceId, runtimeId)) {
        return;
      }
      const canModel = capabilityUsable(capabilities.capabilitySet, MODEL_CATALOG_CAPABILITY);
      const canPermission = capabilityUsable(capabilities.capabilitySet, PERMISSION_CATALOG_CAPABILITY);
      this.modelCatalogAvailable = canModel;
      this.permissionCatalogAvailable = canPermission;
      if (canModel) {
        const modelResponse = await AppServices.get().devices.getDeviceRuntimeModelCatalog(
          serverUrl, token, deviceId, runtimeId);
        if (!this.isCurrentCatalogRequest(requestId, deviceId, runtimeId)) {
          return;
        }
        this.applyModelCatalog(modelResponse.catalog);
      }
      if (canPermission) {
        const permissionResponse = await AppServices.get().devices.getDeviceRuntimePermissionCatalog(
          serverUrl, token, deviceId, runtimeId);
        if (!this.isCurrentCatalogRequest(requestId, deviceId, runtimeId)) {
          return;
        }
        this.applyPermissionCatalog(permissionResponse.catalog);
      }
    } catch (error) {
      if (!this.isCurrentCatalogRequest(requestId, deviceId, runtimeId)) {
        return;
      }
      this.catalogError = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      if (this.isCurrentCatalogRequest(requestId, deviceId, runtimeId)) {
        this.catalogLoading = false;
      }
    }
  }

  private isCurrentCatalogRequest(requestId: number, deviceId: string, runtimeId: string): boolean {
    return requestId === this.catalogRequestId
      && deviceId === this.deviceId
      && runtimeId === this.runtimeId;
  }

  private applyModelCatalog(catalog: RemoteRuntimeModelCatalog): void {
    this.modelOptions = catalog.models.slice();
    // R47：首次拿到模型目录时，用「上次选择」里的模型打底（仅当它仍在目录里、且可被选中）。
    // 命中就把它写进 selectedModelId，让下面的 resolveModelSelection 以它为起点；
    // 不命中（换了 Runtime / 服务端下架了该模型）就什么都不做，走原本的默认选择。
    if (!this.prefRestoredModel) {
      this.prefRestoredModel = true;
      const remembered = restoreSelection(this.preferenceEntry(), this.deviceId, this.runtimeId);
      if (remembered !== undefined && remembered.modelId.length > 0) {
        const selectableIds: string[] = [];
        for (let i = 0; i < this.modelOptions.length; i++) {
          const model = this.modelOptions[i];
          if (model.enabled !== false && modelHasValidSelection(model)) {
            selectableIds.push(model.id);
          }
        }
        const restoredModelId = pickExistingId(remembered.modelId, selectableIds);
        if (restoredModelId.length > 0) {
          this.selectedModelId = restoredModelId;
          this.selectedReasoningId = remembered.reasoningId;
        }
      }
    }
    const selection: ModelSelection | undefined = resolveModelSelection(
      this.modelOptions, this.selectedModelId, this.selectedReasoningId);
    if (selection === undefined) {
      this.selectedModelId = '';
      this.selectedReasoningId = '';
      this.reasoningOptions = [];
      return;
    }
    this.selectedModelId = selection.modelId;
    this.selectedReasoningId = selection.reasoningId;
    this.reasoningOptions = reasoningOptionsFor(this.modelOptions, selection.modelId);
  }

  /**
   * 把当前 runtime 的 Agent 预设目录灌进 @State，并解析默认选中项（R51）。
   *
   * ⚠️ **不需要额外请求**：可选项就在 runtime 描述里（`uiSchema.defaultAgentPreset.options`），
   * 而 `this.runtimes` 是设备切换时已经拉过的那一份（`listDeviceRuntimes`）。
   *
   * 选中项解析口径：目录刷新后原选中项可能变 disabled ⇒ 回落默认项
   * （绝不把不可用的值发出去 —— bridge 的 `validatePreset()` 会直接拒）。
   */
  private applyAgentPreset(): void {
    const runtime = this.findRuntime(this.runtimeId);
    this.agentPresetOptions = agentPresetOptions(runtime);
    // R52：先试「上次选择」里的预设（仅当它仍在目录里且可用）——与模型/权限同款口径：
    // 换了 Agent 就是新作用域（`restoreSelection` 按 scope 取，取不到自然回落默认值）。
    if (!this.prefRestoredAgentPreset) {
      this.prefRestoredAgentPreset = true;
      const remembered = restoreSelection(this.preferenceEntry(), this.deviceId, this.runtimeId);
      if (remembered !== undefined && remembered.agentPresetId.length > 0
        && presetStillSelectable(this.agentPresetOptions, remembered.agentPresetId)) {
        this.selectedAgentPresetId = remembered.agentPresetId;
        return;
      }
    }
    if (!presetStillSelectable(this.agentPresetOptions, this.selectedAgentPresetId)) {
      this.selectedAgentPresetId = defaultAgentPreset(runtime);
    }
  }

  /** 预设行是否显示：有这个字段且至少一个选项（别的 runtime 拿不到字段 ⇒ 整行不显示）。 */
  private showAgentPresetRow(): boolean {
    return this.runtimeId.length > 0 && this.agentPresetOptions.length > 0;
  }

  private selectAgentPreset(value: string): void {
    if (!presetStillSelectable(this.agentPresetOptions, value)) {
      return;
    }
    this.selectedAgentPresetId = value;
    this.expandedRow = '';
    // R52：用户显式选择 ⇒ 记住（下次新建同一设备 + Agent 时回填）。
    this.rememberSelection();
  }

  private applyPermissionCatalog(catalog: RemoteRuntimePermissionCatalog): void {
    this.permissionOptions = catalog.permissions.slice();
    // R47：首次拿到权限目录时用「上次选择」打底（真机默认是「仅可查看」，用户改过一次就不该再退回）。
    if (!this.prefRestoredPermission) {
      this.prefRestoredPermission = true;
      const remembered = restoreSelection(this.preferenceEntry(), this.deviceId, this.runtimeId);
      if (remembered !== undefined && remembered.permissionId.length > 0) {
        const selectableIds: string[] = [];
        for (let i = 0; i < this.permissionOptions.length; i++) {
          const permission = this.permissionOptions[i];
          if (permission.enabled !== false && permission.selectionId.length > 0) {
            selectableIds.push(permission.id);
          }
        }
        const restoredPermissionId = pickExistingId(remembered.permissionId, selectableIds);
        if (restoredPermissionId.length > 0) {
          this.selectedPermissionId = restoredPermissionId;
        }
      }
    }
    this.selectedPermissionId = resolvePermissionSelection(
      this.permissionOptions, this.selectedPermissionId);
  }

  private selectedModel(): RemoteRuntimeModel | undefined {
    for (let i = 0; i < this.modelOptions.length; i++) {
      if (this.modelOptions[i].id === this.selectedModelId) {
        return this.modelOptions[i];
      }
    }
    return undefined;
  }

  private selectedReasoning(): RemoteRuntimeReasoning | undefined {
    for (let i = 0; i < this.reasoningOptions.length; i++) {
      if (this.reasoningOptions[i].id === this.selectedReasoningId) {
        return this.reasoningOptions[i];
      }
    }
    return undefined;
  }

  private selectedPermission(): RemoteRuntimePermission | undefined {
    for (let i = 0; i < this.permissionOptions.length; i++) {
      if (this.permissionOptions[i].id === this.selectedPermissionId) {
        return this.permissionOptions[i];
      }
    }
    return undefined;
  }

  private selectModel(modelId: string): void {
    for (let i = 0; i < this.modelOptions.length; i++) {
      const model = this.modelOptions[i];
      if (model.id !== modelId || model.enabled === false || !modelHasValidSelection(model)) {
        continue;
      }
      const options = reasoningOptionsFor(this.modelOptions, model.id);
      this.selectedModelId = model.id;
      this.selectedReasoningId = options.length > 0 ? defaultReasoningId(options) : '';
      this.reasoningOptions = options;
      // R47：用户显式选模型 ⇒ 记住（推理强度会跟着重算，故放在重算之后）。
      this.rememberSelection();
      // 上游 `NewSessionScreen.kt:903-922` 的 `onSelect` **不关弹层**（勾选状态就地更新），
      // 弹层只由「再点一次同一行」或「点弹层外」关闭。旧实现在这里清 `expandedRow`，
      // 点一下就收起来，与安卓不一致（R14 修正）。
      return;
    }
  }

  private selectReasoning(reasoningId: string): void {
    for (let i = 0; i < this.reasoningOptions.length; i++) {
      if (this.reasoningOptions[i].id === reasoningId) {
        this.selectedReasoningId = reasoningId;
        // R47：用户显式选推理强度 ⇒ 记住。
        this.rememberSelection();
        return;
      }
    }
  }

  private selectPermission(permissionId: string): void {
    for (let i = 0; i < this.permissionOptions.length; i++) {
      const permission = this.permissionOptions[i];
      if (permission.id === permissionId && permission.enabled !== false
        && permission.selectionId.length > 0) {
        this.selectedPermissionId = permissionId;
        // R47：用户显式选权限模式 ⇒ 记住。
        this.rememberSelection();
        return;
      }
    }
  }

  /**
   * 配置行是否可操作（上游 NewSessionConfigurationRow 的 active =
   * !field.loading && field.enabled && options.any(enabled)）：
   * 不可操作时值置灰到 50%（上游 ink.copy(alpha = if (active) 1f else 0.5f)）。
   */
  private rowActive(kind: string): boolean {
    if (this.catalogLoading) {
      return false;
    }
    if (kind === 'device') {
      return this.devices.length > 0;
    }
    if (kind === 'runtime') {
      return this.runtimeId.length > 0;
    }
    if (kind === 'model') {
      return this.showModelRow() && this.modelOptions.length > 0;
    }
    if (kind === 'effort') {
      return this.showEffortRow() && this.reasoningOptions.length > 0;
    }
    if (kind === 'permission') {
      return this.showPermissionRow() && this.permissionOptions.length > 0;
    }
    if (kind === 'agentPreset') {
      return this.showAgentPresetRow();
    }
    return true;
  }

  /** 上游 `showModelConfiguration`：能力声称可用、或已经拿到了目录、或正在加载。 */
  private showModelRow(): boolean {
    return this.runtimeId.length > 0
      && (this.catalogLoading || this.modelCatalogAvailable || this.modelOptions.length > 0);
  }

  private showEffortRow(): boolean {
    return this.showModelRow();
  }

  private showPermissionRow(): boolean {
    return this.runtimeId.length > 0
      && (this.catalogLoading || this.permissionCatalogAvailable || this.permissionOptions.length > 0);
  }

  private catalogLoadingLabel(): string {
    return '正在加载实时选项...';
  }

  private modelRowValue(): string {
    if (this.catalogLoading) {
      return this.catalogLoadingLabel();
    }
    const model = this.selectedModel();
    return model !== undefined ? model.displayName : '不可用';
  }
  
  private effortRowValue(): string {
    if (this.catalogLoading) {
      return this.catalogLoadingLabel();
    }
    const reasoning = this.selectedReasoning();
    if (reasoning !== undefined) {
      return reasoning.displayName;
    }
    return this.reasoningOptions.length === 0 ? '默认' : '不可用';
  }

  private permissionRowValue(): string {
    if (this.catalogLoading) {
      return this.catalogLoadingLabel();
    }
    const permission = this.selectedPermission();
    if (permission === undefined) {
      return '不可用';
    }
    return permissionDisplayLabel(this.runtimeType, permission);
  }

  /** 权限目录加载失败时的说明（挂在配置卡下方，与「能力不可用」区分开）。 */
  private catalogNote(): string {
    if (this.catalogError.length === 0) {
      return '';
    }
    return `无法加载实时选项：${this.catalogError}（可重试，或直接创建）`;
  }

  /**
   * R51：DSH 却**没有**预设目录时的说明。
   *
   * 为什么值得说一句：DSH 是**支持** Agent 预设的运行时，但目录是连接器在**发现阶段**
   * 顺带拉的（`connector/runtimes/dsh/discovery.py:102-107` 调 `catalog.listAgentPresets`，
   * 且 **2 秒超时 + 失败静默吞掉**）⇒ 那次没拉到就永远没有选项，
   * 而界面上的表现只是「少了一行」，用户无从判断是「App 没做」还是「连接器没给」。
   * 这里如实说明，并给出可行动的下一步。
   */
  private agentPresetNote(): string {
    if (this.runtimeType !== 'dsh' || this.runtimeId.length === 0) {
      return '';
    }
    if (this.agentPresetOptions.length > 0 || this.catalogLoading) {
      return '';
    }
    return '这个 Connector 没有上报 Agent 预设目录（重启 Connector 后会重新发现）。';
  }

  private retryCatalogs(): void {
    this.loadRuntimeConfiguration().then(() => {});
  }

  // -------------------------------------------------------------------------
  // 提交
  // -------------------------------------------------------------------------

  private headerTitle(): string {
    return this.projectOnly ? '新建项目' : '新建会话';
  }

  /** 上游 `new_session_start_chat` = 开始聊天；新建项目侧沿用上游 `NewProjectScreen` 的「创建项目」。 */
  private submitLabel(): string {
    return this.projectOnly ? '创建项目' : '开始聊天';
  }

  /**
   * 能否提交：`blockReason()` 为空即无阻塞项。
   *
   * 用同一个函数推导「按钮可点」与「为什么不能点」，两者永远不可能互相矛盾
   * （此前的写法把条件抄了两遍，改一处忘一处就会出现「按钮亮着但点不动」
   * 或「能点但必然失败」）。
   */
  private canCreate(): boolean {
    // 创建中也要禁用（旧实现由 `AaPrimaryButton` 的 `loading` 承担；自绘按钮后必须显式判断）。
    return this.blockReason().length === 0 && !this.creating && !this.creatingProject;
  }

  /** 创建按钮点不动时，把原因说清楚（挂在按钮上方）。 */
  private blockReason(): string {
    if (this.deviceId.length === 0) {
      return '请先选择设备。';
    }
    if (this.projectOnly) {
      if (this.newProjectName.trim().length === 0) {
        return '请填写项目名称。';
      }
      if (this.pendingWorkspace.trim().length === 0) {
        return '请填写工作区绝对路径。';
      }
      return '';
    }
    if (this.projectId.length === 0) {
      return '请先选择或新建项目工作区。';
    }
    if (this.loadingRuntimes) {
      return '正在加载 Runtime…';
    }
    if (this.runtimes.length === 0) {
      return '该设备没有可用的 Runtime。请到设备详情里「发现 Runtime」。';
    }
    if (this.readyRuntimes().length === 0) {
      if (this.runtimeIsSettling()) {
        // 把服务端给的原因一起写出来：DSH 的「启动中」可能是「等本地 DSH Bridge」
        // 这类用户自己就能解决的状态，只说「请稍候」会让人一直干等（真机实测卡很久）。
        const why = this.firstRuntimeReason();
        return why.length > 0
          ? `Runtime 正在启动/停止，请稍候再试。（${why}）`
          : 'Runtime 正在启动/停止，请稍候再试。';
      }
      // 设备详情页的按钮已改名为「启动」，这里的引导必须跟着改，
      // 否则会把用户指向一个界面上根本不存在的按钮（原为「设为默认」）。
      return 'Runtime 尚未启用。请到设备详情里点「启动」。';
    }
    // ⚠️ 这里**没有**「首条消息为空」这一项，是刻意的（R13-12 / F-2）：
    // 上游 `canStart`（`NewSessionScreen.kt:635-640`）只判 setupState / 设备 / connectorId /
    // Runtime / workspaceReady / !creatingProject，**不含消息**；上游把这条留到**点下去之后**
    // 由 `validateNewSessionDraft` 报错（见下面的 `submitBlocker()`）。
    // 旧实现把它当成禁用理由 ⇒ 主按钮被提前压成浅灰，正是 F-2 那条像素差异
    // （安卓实心黑 median=10 vs 鸿蒙浅灰 median≈240）的成因。
    return '';
  }

  /**
   * 提交前的**逐字校验**（上游 `validateNewSessionDraft`，`SessionsController.kt:748-766`）。
   *
   * 上游只在这一步才拦「消息为空」，返回的是给用户看的错误串 —— **不是把按钮变灰**。
   * 本工程的 `createSession()` 会把 `content` 作为首条消息发给 `createAndStartSession`，
   * 而 DSH runtime 硬性要求 message 非空（见 `createSession()` 内注释），所以这条拦截
   * 在本工程里**是必需的** —— 只是位置要与上游一致：点下去才报，不预先禁用。
   *
   * 只用于**新建会话**；新建项目（`projectOnly`）不要求首条消息，`submit()` 里已先行返回。
   */
  private submitBlocker(): string {
    if (this.content.trim().length === 0) {
      // R47（用户反馈「无法新建对话」）：这一串原先逐字照上游（`SessionsController.kt:757` 的硬编码英文内联串），
      // 而它恰好是用户点「开始聊天」时**唯一**会看到的反馈 —— 中文用户看到英文串的第一反应就是「建不了」。
      // 裁决口径同 R41「归档提示加恢复路径」：**可用性优先于逐字对照**（上游无对应 string key 可抄）。
      // 顺带更正一条既有判断：这行与 `new_session_message_placeholder`（「描述第一个任务…」）
      // **不是一回事** —— 后者是输入框的 placeholder（本页 `TextArea` 已正确使用），
      // 在安卓端全 `src/main` 只有 strings.xml 两处定义、**没有任何调用点**（孤立字符串）。
      return '请先填写首条消息（或添加一个附件）再开始。';
    }
    return '';
  }

  private submit(): void {
    if (!this.canCreate()) {
      return;
    }
    if (this.projectOnly) {
      this.createProject();
      return;
    }
    const blocked = this.submitBlocker();
    if (blocked.length > 0) {
      this.error = blocked;
      return;
    }
    // R91：作用于会话的指令（/compact 这类）**不能当首条消息发** —— 那会进模型而不是
    // 执行 DSH 命令（见 model/SlashCommand.ets）。这里拦在「开始聊天」之前并给出理由。
    const commandBlocked = this.contentBlockedByDraftCommand();
    if (commandBlocked.length > 0) {
      this.error = commandBlocked;
      this.commandPanelOpen = true;
      return;
    }
    this.createSession();
  }

  // -------------------------------------------------------------------------
  // 视图
  // -------------------------------------------------------------------------

  build() {
    // R65-A（设计规格 §2）：顶栏从正文里**提到 `Navigation` 标题栏**。
    //
    // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏**布局在内容区之上**、占自己一行）而不是 `STACK`：
    //  `STACK` 把标题栏**叠在内容上**，那就必须自己给内容让位（`contentStartOffset` 那套），
    //  而 设计规格 §2 明确要求「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
    //  ⇒ STANDARD 下内容天然落在标题栏下方，首屏不会被顶栏压住（与 R65-B 的三页逐字同款）。
    Navigation() {
      Column() {
        AaErrorBanner({
          message: this.error.length > 0 ? this.error : this.dashboardError,
          onRetry: () => {
            this.loadRuntimes();
          },
          onDismiss: () => {
            this.error = '';
          }
        })

        if (this.isReady()) {
          this.readyBody()
        } else {
          this.setupPanel()
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

  /** 就绪态：滚动内容 + **固定**在滚动区之外的底部动作区（易错点 2）。 */
  @Builder
  readyBody() {
    Column() {
      Scroll() {
        Column({ space: Space.PAGE }) {
          if (this.projectOnly) {
            // NewProject 模式：只显示「项目名称 + 目录」；设备行保留，
            // 因为创建项目必须知道挂到哪台 Connector 上（上游是靠首页上下文隐式带入的）。
            this.deviceCardOnly()
            this.projectFields()
          } else {
            this.configurationCard()
            // ⚠️ R40：**「首条消息」必须排在配置卡之后**（原来它在滚动区最底部、工作目录之后）。
            // 用户反馈「无法新建对话」的现场：底部动作区的「开始聊天」是**固定**的、首屏永远可见，
            // 而输入框被 4 个项目行挤到滚动区最底部、首屏看不到 ⇒ 用户直接点按钮 ⇒
            // 拿到 `submitBlocker()` 那句英文校验错（`Enter a message or attach a file before starting.`）⇒
            // 用户理解成「建不了会话」。把输入框提到首屏可见处，这条歧义就消失了。
            // （上游 `NewSessionScreen.kt` **没有**首条消息输入区，所以这一块的顺序没有上游依据，按可用性定。）
            this.messageSection()
            // 浏览态：工作目录区块整体被目录浏览器取代（上游 `if (choosePath) ChoosePathSection else WorkspaceSection`）。
            if (this.browseOpen) {
              this.browseSection()
            } else {
              this.workspaceSection()
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.M, bottom: Space.L })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      // ⚠️ `align` 是通用属性、默认 `Alignment.Center`：内容比视口短时会被**垂直居中**。
      // 新建项目（projectOnly）实测上下各空 491px（R14 取证）。
      .align(Alignment.Top)

      this.bottomActionBar()
    }
    .width('100%')
    // ⚠️ 必须是 layoutWeight(1) 而不是 height('100%')：本区块的父级是「顶栏 + 错误条 + 本区块」的
    // Column，子级再写 height('100%') 会按**父的整高**解析，于是整体下移一个顶栏的高度，
    // 底部动作区被挤出屏幕（模拟器实测：主按钮只剩顶部一条边可见）。
    // 同页的 setupPanel() 用的就是 layoutWeight(1)，只有这里写错了。
    .layoutWeight(1)
  }

  /** 顶栏（上游 `NewSessionHeader`：行高 46vp（R81）/ 水平 18 / 左返回圆钮 / 中标题 / 右 40vp 等宽占位）。
   *  标题取 `headerTitle()`（「新建会话」/「新建项目」），`this.title` 有值时优先。
   *  ⚠️ **R82 已删除「标题编辑态」**（原上游 `NewSessionHeader.kt:88-127`：210dp 居中输入框 +
   *  142×1.5 下划线 + 右侧铅笔/对勾钮）—— 它只在 `!projectOnly` 时渲染，而那条路已无入口，
   *  真机进不去（见下方 `navTitleBar()` 内注释与 `suite-topbar.mjs` 的回潮闸门）。
   */
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
   * （行高 46vp（R81）/ 水平 18 / 左返回圆钮 / 中标题 / **右 40vp 等宽占位**（R82 起没有编辑钮））。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感（`uiMaterial.ImmersiveMaterial`）自
   * HarmonyOS 7 起有**生效范围约束**（仅对 `targetSdkVersion >= 26.0.0` 的应用生效）：其他组件
   * 只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 中 `barPosition = BarPosition.End`
   * 的底部 TabBar 中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1/§2）。
   */
  @Builder
  navTitleBar() {
    Row() {
      // 上游 `HeaderCircleButton`：40dp 圆 + 底色 + 1dp 描边（`AaCircleIconButton` 同构）。
      // R57（T2b）：玻璃档（本顶栏已是毛玻璃带）。几何 40 / 28 不变。
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
          Router.back();
        }
      })
      // ## R82：**标题编辑态整段删除**（点铅笔 → 居中 `TextInput` + 142×1.5 下划线）。
      // ⚠️ 它原来只在 `!projectOnly` 时渲染，而能进到那种模式的唯一路由 `Route.NEW_SESSION`
      //  **全工程已无 push 点**（只剩常量与 `Index` 的挂载分支）⇒ 真机上根本进不去，
      //  属死代码（R81 真机复验结论）。现在只剩「展示标题」这一支。
      // ⚠️ `this.title` **保留**：它是`submit()` 载荷与标题回退的既有读取点（不再有写入点，
      //  见本文件 R82 记录；要一起收敛需 Lead 另开一轮 —— 本轮只删「死入口 + 死编辑态」）。
      Text(this.title.length > 0 ? this.title : this.headerTitle())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 16, right: 16 })
      // ## R82：右槽的「编辑标题」圆钮（铅笔/对勾双态）已随编辑态一起删除。
      //
      // ⚠️ **这里不再包 `if (this.projectOnly)`**：删掉死路由后本屏**只有** `Route.NEW_PROJECT`
      //  一个入口（`resolveEntryMode()` 里 `this.projectOnly = entry.route === Route.NEW_PROJECT`），
      //  即 `projectOnly` 在真机上**恒为 true** ⇒ 那一支的 `else` 永远不可达，
      //  留成 `if` 只会让「右边到底还有没有按钮」变得难读。
      // ⚠️ 这个 40vp 空占位**必须留**：没有它标题会偏左（上游用 `Spacer(Modifier.width(40.dp))`）。
      // ⚠️ 上游同屏口径：`projectOnly` 分派与它驱动的非 project 分支**有意保留**（见字段声明处注释）。
      Row()
        .width(Control.NAV_BUTTON_LARGE)
        .height(Control.NAV_BUTTON_LARGE)
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），58vp → 252px（低 17px）。
    // ⚠️ 原来这里是字面量 `58`（R53 的「新建族 58dp」），R81 起统一到共享令牌（新建族三页同一条线）。
    //  栏高同样**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: 18, right: 18 })
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：挂材质的栏会画出比正文亮约
    //  +19 的一整条「带」；首页栏本体零材质、同口径 +0.00）。**光效只留在栏内控件上。**
    //  ⚠️ 历史：R66 曾把整条栏改官方材质（本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），
    //  R87 因「有明显分界」撤回；同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  /** 未就绪态：插图 + 标题 + 说明 + 动作（**不是**错误页， 易错点 1）。 */
  @Builder
  setupPanel() {
    // 插图 → 文案 24（Space.XL）、文案 → 动作 28（Space.INDENT），与上游 SetupPanel 一致。
    Column({ space: Space.INDENT }) {
      Column({ space: Space.XL }) {
        // 上游 NewSessionSetupPanel.kt:52-56：插图就是一张 PNG（R.drawable.ic_agent_unavailable），
        // Modifier.size(168.dp)，**没有灰底方块** —— 此前本工程是「灰底圆角 + 矢量显示器图标」，
        // 属于自创形态，R21 起换成与上游**同名**的资源。
        // ⚠️ R56：该资源已由本工程**自绘液态玻璃版**重画，**不再与上游位图逐字节相同**；
        // 上游对照见 开发期验证记录（旧口径的 md5 / 文件大小一律作废）。
        if (this.setupKind() === 'loading') {
          // 加载态上游直接 return（不渲染任何东西）；本工程保留一个指示器，比全白更有信息量。
          // ⚠️ `LoadingProgress` 没有线宽参数（SDK 只有 color / enableLoading / contentModifier）。
          LoadingProgress()
            .width(Control.HERO_ICON)
            .height(Control.HERO_ICON)
            .color(muted())
        } else {
          Image($r('app.media.ic_agent_unavailable'))
            .width(168)
            .height(168)
            .objectFit(ImageFit.Contain)
        }

        Column({ space: Space.S }) {
          Text(this.setupTitle())
            .fontSize(FontSize.ROW_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(ink())
            .textAlign(TextAlign.Center)
          if (this.setupDescription().length > 0) {
            Text(this.setupDescription())
              .fontSize(FontSize.SMALL)
              .fontColor(muted())
              .textAlign(TextAlign.Center)
          }
        }
        .alignItems(HorizontalAlign.Center)
      }
      .alignItems(HorizontalAlign.Center)

      // 上游 NewSessionSetupPanel.kt:66-72：这里是 **StartChatButton**（与底部主按钮同款：
      // 54 高 / 圆角 18 / primaryAction 底 / onPrimaryAction 白字 + 箭头），
      // 且外面套一层 Box(widthIn(max = 224.dp)) —— **不是** AaSecondaryButton。
      if (this.setupActionLabel().length > 0) {
        this.setupPrimaryButton()
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 设置面板的主按钮（上游 NewSessionSetupPanel.kt:67 调的就是 StartChatButton）。
   * 样式与底部 startButton() 一致，只有 label / 禁用条件 / 回调不同；宽度上限 224dp。
   */
  @Builder
  setupPrimaryButton() {
    Stack() {
      Column()
        .width('100%')
        .height(Control.BUTTON_LARGE)
        .borderRadius(Radius.XL)
        .backgroundColor(primaryAction())
        .opacity(this.setupActionEnabled() ? 1 : START_BUTTON_DISABLED_ALPHA)

      Row({ space: Space.S }) {
        Text(this.setupActionLabel())
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(onPrimaryAction())
          .maxLines(1)
        AaIcon({
          d: ICONS['chevron-right'],
          iconSize: START_BUTTON_GLYPH_SIZE,
          color: onPrimaryAction(),
          stroke: START_BUTTON_GLYPH_STROKE
        })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(Control.BUTTON_LARGE)
    }
    .width(224)
    .height(Control.BUTTON_LARGE)
    .onClick(() => {
      if (this.setupActionEnabled()) {
        this.runSetupAction();
      }
    })
  }

  /** NewProject 模式的字段块：项目名称 + 工作区路径。 */
  @Builder
  projectFields() {
    // 字段块间距 12（Space.M）、区块间距 18（Space.PAGE）；输入框 54 / 圆角 18 / 16sp。
    Column({ space: Space.PAGE }) {
      Column({ space: Space.M }) {
        Text('项目名称')
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
        TextInput({ text: this.newProjectName, placeholder: '例如 agents-anywhere' })
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Medium)
          .height(Control.BUTTON_LARGE)
          .padding({ left: Space.L, right: Space.L })
          .borderRadius(Radius.XL)
          .borderWidth(StrokeWidth.HAIRLINE)
          .borderColor(borderColor())
          .backgroundColor(raisedSurface())
          .onChange((value: string) => {
            this.newProjectName = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.browseOpen) {
        // 浏览态：目录浏览器取代手打路径（上游 `NewProjectScreen` 常驻 `ChoosePathSection`）。
        this.browseSection()
      } else {
        Column({ space: Space.M }) {
          Text('工作区路径')
            .fontSize(FontSize.SMALL)
            .fontWeight(FontWeight.Medium)
            .fontColor(ink())
          TextInput({ text: this.pendingWorkspace, placeholder: '/Users/you/code/demo' })
            .fontSize(FontSize.ROW_TITLE)
            .fontWeight(FontWeight.Medium)
            .height(Control.BUTTON_LARGE)
            .padding({ left: Space.L, right: Space.L })
            .borderRadius(Radius.XL)
            .borderWidth(StrokeWidth.HAIRLINE)
            .borderColor(borderColor())
            .backgroundColor(raisedSurface())
            .onChange((value: string) => {
              this.pendingWorkspace = value;
            })
          this.browseActionRow()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** NewProject 模式下的设备卡（只有一行：项目要挂到哪台设备上）。 */
  @Builder
  deviceCardOnly() {
    Column() {
      this.configDeviceRow()
      this.cardOutline()
    }
    .width('100%')
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .clip(true)
  }

  /**
   * 卡片描边（**画在覆盖层上**，不能用 `.borderWidth`）。
   *
   * 上游 `NewSessionScreen.kt:897` 用 Compose 的 `Modifier.border(1.dp, ...)`：描边**画在内容之上、
   * 不参与子节点布局**。ArkUI 的 `.borderWidth` 相反：它会把子节点整体内缩 1dp（实测 3px），
   * 于是配置卡的每一行都从 x=63 变成 x=66 —— 与安卓 dump（卡片 [54,347][1262,1074]、
   * 行内标签 x=102 ⇒ 卡内缩进 16.1dp）对不上。
   * 所以这里改成一个绝对定位的**空覆盖层**：不占布局、不参与命中测试。
   */
  @Builder
  cardOutline() {
    Row()
      .width('100%')
      .height('100%')
      .borderRadius(Radius.XL)
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(borderColor())
      .position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 配置卡：设备 / Agent（+ 模型 / 推理强度 / 权限模式）——圆角 18 / 行高 48 / 标签 13sp / 值 14sp。 */
  @Builder
  configurationCard() {
    Column() {
      this.configDeviceRow()
      this.configDivider()
      this.configRuntimeRow()
      if (this.showModelRow()) {
        this.configDivider()
        this.configModelRow()
        this.configDivider()
        this.configEffortRow()
      }
      if (this.showPermissionRow()) {
        this.configDivider()
        this.configPermissionRow()
      }
      // R51：DSH 的会话级 Agent 预设（别的 runtime 没有这个字段 ⇒ 整行不显示）。
      if (this.showAgentPresetRow()) {
        this.configDivider()
        this.configAgentPresetRow()
      }
      if (this.catalogNote().length > 0) {
        this.catalogNoteRow()
      }
      if (this.agentPresetNote().length > 0) {
        this.agentPresetNoteRow()
      }
      this.cardOutline()
    }
    .width('100%')
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    // 上游 NewSessionScreen.kt:897：浅色下配置卡有 1dp 描边（深色下不画）。
    // 本工程 dark/border 恰为 #00000000（= 透明），所以一支笔两支主题都对。
    // ⚠️ 描边走 cardOutline() 覆盖层，不能用 .borderWidth（会把子节点内缩 1dp）。
    .clip(true)
  }

  /**
   * 配置卡的行分隔线（上游 `NewSessionConfigurationCard.kt:82-88`）：
   * **1dp 高、左右内缩 16/14、色为 `ink` 的 7%（浅色）/ 9%（深色）** ——
   * 不是 `Divider`，也不是 `border` 色（那个在深色下是透明的，分隔线会消失）。
   */
  @Builder
  configDivider() {
    Row()
      .width('100%')
      .height(1)
      .padding({ left: 16, right: 14 })
      .backgroundColor(ink())
      .opacity(0.07)
  }

  /**
   * 配置行下拉弹层的底色（上游 `AADropdownMenu.kt:176 menuSurface`：深色取 `subtle`、浅色取 `raisedSurface`）。
   *
   * ⚠️ R86：本函数**只服务门控回退分支** —— 材质可用时内容根送 `Color.Transparent`（底由官方材质接管），
   *  探针不可用时才逐字回到这里的不透明底。见 `configMenuPopup()` 的 `backgroundColor` 三元。
   */
  private configMenuSurface(): Resource {
    return isDarkAppearance() ? subtle() : raisedSurface();
  }

  /**
   * 配置行的**就地下拉弹层**（上游 `NewSessionConfigurationCard.kt:152-165`：
   * 每行在 `Box(align TopEnd).width(1.dp).height(48.dp)` 里挂一个 `AADropdownMenu`）。
   *
   * 锚定语义：`Placement.BottomRight` ⇒ 弹层右边缘贴触发行的右边缘、上边缘贴行的下边缘 + 4dp
   * （上游 `DropdownMenu(offset = DpOffset(0.dp, MenuGap))`，`MenuGap = 4.dp`）。
   * 容器自身不画任何东西（`popupColor` 透明 / 无模糊 / 零阴影），卡片由 `configMenuPopup()` 自己画。
   *
   * ⚠️ 旧实现是**行内展开**（`if (this.expandedRow === 'model')` 直接插在行下面）——
   * 那会把下方所有行整体推下去，与安卓「浮层不动内容」的观感完全不同（R14 修正）。
   */
  private configMenuPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.configMenuPopup();
      },
      placement: Placement.BottomRight,
      targetSpace: CONFIG_MENU_GAP,
      enableArrow: false,
      autoCancel: true,
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: Control.MENU_WIDTH,
      radius: Radius.XL,
      /**
       * R86：弹层**容器**改挂官方沉浸光感（`CustomPopupOptions.systemMaterial`）。
       *
       * · 官方依据：SDK `common.d.ts:14406`（`CustomPopupOptions.systemMaterial?:
       *  SystemUiMaterial`，接口归属 :13866；`SystemUiMaterial` = `uiMaterial.Material`，:16964）；
       *  另有 `PopupCommonOptions/PopupOptions.systemMaterial`（:12966 / :13824）是同一字段的另一重载。
       * · 生效范围判定：**`bindPopup` 属「弹窗类接口」**，按官方 OS 平台行为变更（仅对
       *  `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）在**页面内全部区域**生效 ——
       *  本弹层锚在配置卡的行上，属生效范围（`坑 245`）；六处调用点共用本构造器
       *  ⇒ 一处改、六处生效（model / effort / permission / agentPreset / device / runtime）。
       * · 关闭姿势：`dialogMaterial()` 在探针不可用时返回 `uiMaterial.Material.empty`（= disable，
       *  `uiMaterial.d.ts:467-472`），**绝不传 `undefined`**（那个语义是「恢复组件默认材质」，`坑 256`）。
       */
      systemMaterial: dialogMaterial(),
      onStateChange: (e: AaPopupStateChange) => {
        if (!e.isVisible) {
          this.expandedRow = '';
        }
      }
    };
  }

  /**
   * 下拉弹层的内容（上游 `AADropdownMenu`：286dp 宽 / 最高 328dp / 圆角 18 / 上下内边距 14 / 1dp 描边）。
   *
   * ⚠️ 选项**不关弹层**：上游 `NewSessionScreen.kt:903-922` 的 `onSelect` 只改选择、不动
   * `expandedConfiguration`，所以勾选状态要能在弹层里就地更新（这里读的 `@State` 会登记元素级依赖）。
   */
  @Builder
  configMenuPopup() {
    // ⚠️ R48 修复（用户反馈「模型弹窗列表无法滑动」）：原先这里是**裸 `Column` + `constraintSize(maxHeight)`**，
    // 超出 328vp 的选项被直接**裁掉、且完全不可滚** —— 12 个模型的列表只能看到最前面几个。
    // 上游是可滚的：`AADropdownMenu` 用 Material `DropdownMenu`（其内容自带 `verticalScroll`）、
    // `AAAnchoredDropdownMenu` 直接用 `LazyColumn`（见 `AADropdownMenu.kt:63-105`）。
    // ⇒ 这里包一层 `Scroll`；圆角 / 底色 / 描边留在**滚动容器**上（内容滚出边界时不会被圆角切到）。
    Scroll() {
      Column() {
        if (this.expandedRow === 'device') {
          ForEach(this.devices, (device: AgentDevice) => {
            this.deviceOptionRow(device)
          }, (device: AgentDevice) => `dev:${device.id}:${device.online}:${this.projectOnly}`)
        } else if (this.expandedRow === 'runtime') {
          ForEach(this.runtimes, (runtime: RemoteDeviceRuntime) => {
            this.runtimeRow(runtime)
          }, (runtime: RemoteDeviceRuntime) => `rt:${runtime.runtimeId}:${runtime.active}:${runtime.status}:${runtime.configured}`)
        } else if (this.expandedRow === 'model') {
          ForEach(this.modelOptions, (model: RemoteRuntimeModel) => {
            this.modelOptionRow(model)
          }, (model: RemoteRuntimeModel) => `md:${model.id}:${model.enabled !== false}`)
        } else if (this.expandedRow === 'effort') {
          ForEach(this.reasoningOptions, (reasoning: RemoteRuntimeReasoning) => {
            this.reasoningOptionRow(reasoning)
          }, (reasoning: RemoteRuntimeReasoning) => `ef:${reasoning.id}:${reasoning.selectionId}:${reasoning.enabled !== false}`)
        } else if (this.expandedRow === 'permission') {
          ForEach(this.permissionOptions, (permission: RemoteRuntimePermission) => {
            this.permissionOptionRow(permission)
          }, (permission: RemoteRuntimePermission) => `pm:${permission.id}:${permission.selectionId}:${permission.enabled !== false}`)
        } else if (this.expandedRow === 'agentPreset') {
          ForEach(this.agentPresetOptions, (preset: AgentPresetOption) => {
            this.agentPresetOptionRow(preset)
          }, (preset: AgentPresetOption) => `ap:${preset.value}:${preset.disabled}`)
        }
      }
      .width(Control.MENU_WIDTH)
      .padding({ top: Control.MENU_PAD_V, bottom: Control.MENU_PAD_V })
      .alignItems(HorizontalAlign.Start)
    }
    .width(Control.MENU_WIDTH)
    .constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })
    // R86：本节点是 `bindPopup` 的**内容根**（材质挂在容器上，见 `configMenuPopupOptions()`），
    // 弹层容器本身全透明（`popupColor` 送 `Color.Transparent`，不上任何容器底）⇒「底」只有这一个来源，故按
    // `immersiveMaterialEnabled()` **门控**（与 R85 `Components#customDialogGeometry()` 同构）：
    //  · 材质可用 ⇒ 透明底 + 0 描边 ⇒ 本节点**零自绘层**，官方材质接管 background / border /
    //  shadow / blur（SDK `common.d.ts:22625-22633`；契约 §1.2 / §1.8，A/B 可归因性不受损）；
    //  · 材质不可用（设备不支持 / 探针 false / 未来关档）⇒ **逐字回到 R86 前**的
    //  `configMenuSurface()` 底 + 1vp 描边 ⇒ 下拉面板不会变成「文字浮在配置卡上」的空壳。
    //  几何（宽 / 限高 / 圆角 / 内边距 / 子节点）一个字未动（契约 §1.4）。
    // ⚠️ 回退：删掉 `configMenuPopupOptions()` 里的 `systemMaterial:` 行即回到 R86 前行为（门控的
    //  不可用分支与 R86 前逐字一致）；彻底回退 = `%TEMP%/aa-hm-r86-before/NewSessionScreen.ets`（契约 §6）。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : this.configMenuSurface())
    .borderRadius(Radius.XL)
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  /** R51：DSH 却没上报预设目录时的说明行（见 `agentPresetNote()` 的注释）。 */
  @Builder
  agentPresetNoteRow() {
    Row() {
      Text(this.agentPresetNote())
        .fontSize(FontSize.CAPTION)
        .fontColor(muted())
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, bottom: Space.M })
  }

  /** 目录加载失败的提示 + 重试（能力不可用不算错误，走 `showXxxRow()` 的隐藏分支）。 */
  @Builder
  catalogNoteRow() {
    Row({ space: Space.M }) {
      Text(this.catalogNote())
        .fontSize(FontSize.CAPTION)
        .fontColor(muted())
        .layoutWeight(1)
      Text('重试')
        .fontSize(FontSize.CAPTION)
        .fontColor(primaryAction())
        .onClick(() => {
          this.retryCatalogs();
        })
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, bottom: Space.M })
  }

  /** 模型行：值取选中模型名，展开后列出模型（不可用的置灰不可点）。 */
  @Builder
  configModelRow() {
    Row({ space: Space.M }) {
      Text('模型')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .opacity(0.72)
      Text(this.modelRowValue())
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .opacity(this.rowActive('model') ? 1 : 0.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 上游 DownGlyph 恒为下箭头（展开时不换成上箭头）—— 换向是本工程旧实现的自创。
      AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.ICON_MD, color: muted() })
    }
    .width('100%')
    .height(Control.FIELD_LARGE)
    .padding({ left: Space.L, right: Space.L })
    // R39：官方按压态。这是**配置入口行**（点开就地选项面板）⇒ 整行可点，与列表行同款。
    // `normal` 透明（本行链式无底色）；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.expandedRow = this.expandedRow === 'model' ? '' : 'model';
    })
    .bindPopup(this.expandedRow === 'model', this.configMenuPopupOptions())
  }

  @Builder
  modelOptionRow(model: RemoteRuntimeModel) {
    // 上游模型选项 = label + enabled，没有「不可用」胶囊（禁用只是文案 α0.42 + 点不动）。
    AaConfigMenuItem({
      label: model.displayName,
      active: this.selectedModelId === model.id,
      usable: this.modelOptionEnabled(model),
      onTap: () => {
        this.selectModel(model.id);
      }
    })
  }

  private modelOptionEnabled(model: RemoteRuntimeModel): boolean {
    return model.enabled !== false && modelHasValidSelection(model);
  }

  /** 推理强度行：只在模型目录可用时出现（上游 Effort 与 Model 同条件）。 */
  @Builder
  configEffortRow() {
    Row({ space: Space.M }) {
      Text('推理强度')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .opacity(0.72)
      Text(this.effortRowValue())
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .opacity(this.rowActive('effort') ? 1 : 0.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.ICON_MD, color: muted() })
    }
    .width('100%')
    .height(Control.FIELD_LARGE)
    .padding({ left: Space.L, right: Space.L })
    // R39：官方按压态。这是**配置入口行**（点开就地选项面板）⇒ 整行可点，与列表行同款。
    // `normal` 透明（本行链式无底色）；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.expandedRow = this.expandedRow === 'effort' ? '' : 'effort';
    })
    .bindPopup(this.expandedRow === 'effort', this.configMenuPopupOptions())
  }

  @Builder
  reasoningOptionRow(reasoning: RemoteRuntimeReasoning) {
    // 上游 `NewSessionScreen.kt:590-597`：副标题取「可用时的 description / 不可用时的 disabledReason」。
    AaConfigMenuItem({
      label: reasoning.displayName,
      detail: this.reasoningDescription(reasoning),
      active: this.selectedReasoningId === reasoning.id,
      usable: this.reasoningOptionEnabled(reasoning),
      onTap: () => {
        this.selectReasoning(reasoning.id);
      }
    })
  }

  /** 上游推理项可用性：`effort.enabled && id.isNotBlank() && selectionId.isNotBlank()`。 */
  private reasoningOptionEnabled(reasoning: RemoteRuntimeReasoning): boolean {
    return reasoning.enabled === true && reasoning.id.length > 0 && reasoning.selectionId.length > 0;
  }

  /** 权限模式行（上游 `session_runtime_permission_mode` = 权限模式）。 */
  @Builder
  configPermissionRow() {
    Row({ space: Space.M }) {
      Text('权限模式')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .opacity(0.72)
      Text(this.permissionRowValue())
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .opacity(this.rowActive('permission') ? 1 : 0.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.ICON_MD, color: muted() })
    }
    .width('100%')
    .height(Control.FIELD_LARGE)
    .padding({ left: Space.L, right: Space.L })
    // R39：官方按压态。这是**配置入口行**（点开就地选项面板）⇒ 整行可点，与列表行同款。
    // `normal` 透明（本行链式无底色）；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.expandedRow = this.expandedRow === 'permission' ? '' : 'permission';
    })
    .bindPopup(this.expandedRow === 'permission', this.configMenuPopupOptions())
  }

  /**
   * **Agent 预设**行（R51）：与「模型 / 推理强度 / 权限模式」同款的就地下拉。
   *
   * 值取选中预设的**显示名**；选项来自 runtime 描述的 `uiSchema.defaultAgentPreset`。
   */
  @Builder
  configAgentPresetRow() {
    Row({ space: Space.M }) {
      Text(AGENT_PRESET_LABEL)
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .opacity(0.72)
      Text(agentPresetRowValue(this.agentPresetOptions, this.selectedAgentPresetId))
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .opacity(this.rowActive('agentPreset') ? 1 : 0.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.ICON_MD, color: muted() })
    }
    .width('100%')
    .height(Control.FIELD_LARGE)
    .padding({ left: Space.L, right: Space.L })
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.expandedRow = this.expandedRow === 'agentPreset' ? '' : 'agentPreset';
    })
    .bindPopup(this.expandedRow === 'agentPreset', this.configMenuPopupOptions())
  }

  @Builder
  agentPresetOptionRow(preset: AgentPresetOption) {
    AaConfigMenuItem({
      // R94：与设置页/对话页同一口径，内置预设在所有入口都显示中文名
      // （本条路径当前无入口，但口径必须一致 —— 将来重新开放入口时不会又冒出一个英文名）。
      label: agentPresetLabel(preset),
      detail: agentPresetDetail(preset),
      active: this.selectedAgentPresetId === preset.value,
      usable: !preset.disabled,
      onTap: () => {
        this.selectAgentPreset(preset.value);
      }
    })
  }

  @Builder
  permissionOptionRow(permission: RemoteRuntimePermission) {
    // 上游 `NewSessionScreen.kt:616-627`：副标题取「可用时的 description / 不可用时的 disabledReason」。
    AaConfigMenuItem({
      label: permissionDisplayLabel(this.runtimeType, permission),
      detail: this.permissionOptionDetail(permission),
      active: this.selectedPermissionId === permission.id,
      usable: this.permissionOptionEnabled(permission),
      onTap: () => {
        this.selectPermission(permission.id);
      }
    })
  }

  /** 上游权限项可用性：`permission.enabled && id.isNotBlank() && selectionId.isNotBlank()`。 */
  private permissionOptionEnabled(permission: RemoteRuntimePermission): boolean {
    return permission.enabled === true && permission.id.length > 0 && permission.selectionId.length > 0;
  }

  /** 权限项的副标题：可用时给说明，不可用时给服务端的原因。 */
  /** 推理项的说明（可缺省 → 空串，避免在 UI 里对可选属性做窄化）。 */
  private reasoningDescription(reasoning: RemoteRuntimeReasoning): string {
    const description = reasoning.description;
    return description !== undefined ? description : '';
  }

  private permissionOptionDetail(permission: RemoteRuntimePermission): string {
    if (permission.enabled === false) {
      const disabledReason = permission.disabledReason;
      return disabledReason !== undefined ? disabledReason : '不可用';
    }
    return permissionDisplayDescription(this.runtimeType, permission);
  }

  @Builder
  configDeviceRow() {
    Row({ space: Space.M }) {
      Text('设备')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .opacity(0.72)
      Text(this.deviceNameById(this.deviceId))
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .opacity(this.rowActive('device') ? 1 : 0.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.ICON_MD, color: muted() })
    }
    .width('100%')
    .height(Control.FIELD_LARGE)
    .padding({ left: Space.L, right: Space.L })
    // R39：官方按压态。这是**配置入口行**（点开就地选项面板）⇒ 整行可点，与列表行同款。
    // `normal` 透明（本行链式无底色）；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.expandedRow = this.expandedRow === 'device' ? '' : 'device';
    })
    .bindPopup(this.expandedRow === 'device', this.configMenuPopupOptions())
  }

  @Builder
  configRuntimeRow() {
    Row({ space: Space.M }) {
      Text('Agent')
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .opacity(0.72)
      Text(this.currentRuntimeLabel())
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Bold)
        .fontColor(ink())
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.ICON_MD, color: muted() })
    }
    .width('100%')
    .height(Control.FIELD_LARGE)
    .padding({ left: Space.L, right: Space.L })
    // R39：官方按压态。这是**配置入口行**（点开就地选项面板）⇒ 整行可点，与列表行同款。
    // `normal` 透明（本行链式无底色）；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.expandedRow = this.expandedRow === 'runtime' ? '' : 'runtime';
    })
    .bindPopup(this.expandedRow === 'runtime', this.configMenuPopupOptions())
  }

  private currentRuntimeLabel(): string {
    const runtime = this.findRuntime(this.runtimeId);
    if (runtime === undefined) {
      return this.loadingRuntimes ? '加载中…' : '未选择';
    }
    // 上游 `NewSessionScreen.kt:545`：`selectedRuntime?.labels?.primary`
    // （displayName == runtimeType 时回落到类型名「DeepSeek Harness」，不是服务端上报的 `DSH`）。
    return deviceRuntimeLabel(runtime.displayName, runtime.runtimeType);
  }

  /** 设备选择行（配置卡展开后）。 */
  @Builder
  deviceOptionRow(device: AgentDevice) {
    // 上游 Agent/Device 选项只有 label + 选中打勾（`NewSessionConfigurationOption(id, label)`）。
    AaConfigMenuItem({
      label: device.name,
      active: this.deviceId === device.id,
      onTap: () => {
        this.deviceId = device.id;
        this.runtimes = [];
        this.runtimeId = '';
        this.runtimeType = '';
        // 换设备一律作废：上一台机器的工作目录、主目录与目录内容对这台机器没有意义。
        this.workspacePath = '';
        this.homePath = '';
        this.browseOpen = false;
        this.browseRoot = '';
        this.browsePath = '';
        this.browseEntries = [];
        this.browseCrumbs = [];
        this.browseError = '';
        this.browseRequestId += 1;
        this.pickProjectForDevice();
        this.loadRuntimes();
        // R47：用户显式换设备 ⇒ 记住「上次用的设备」（Agent 待选中后由 runtime 那处补记）。
        this.rememberTarget();
      }
    })
  }

  /**
   * 「侧边栏显示」偏好（`project` = 项目视图 / `session` = 会话视图）。
   *
   * ⚠️ **R67 修正**：上游 `NewSessionScreen.kt:981` 是
   * `projectMode = sidebarViewMode == HomeSidebarViewMode.Project` ——
   * 新建会话页**工作目录区块的形态由「侧边栏显示」这个偏好决定**，与 `projectOnly`（新建项目模式）**无关**。
   * 本工程此前错用了 `projectOnly` 判分支，而 `workspaceSection()` 只在 `!projectOnly` 时被调用
   * ⇒ 条件恒为 false ⇒ **「项目」标题与项目列表是死代码**，永远走「最近目录」分支。
   * 用户真机（默认就是项目视图）上看到的应是项目列表，却一直是「最近用过的工作目录」。
   * 键与首页共用（`store/AppPreferences.ets` 的 `aaSidebarView`，默认 `project`）。
   */
  @StorageLink('aaSidebarView') sidebarView: string = 'project';

  /** 工作目录区块是否走「项目」形态（上游的 `projectMode`；只认 `session` 为会话视图）。 */
  private workspaceProjectMode(): boolean {
    return this.sidebarView !== 'session';
  }

  /**
   * 工作目录区块（上游 `WorkspaceSection`，`NewSessionWorkspaceSection.kt:53-115`）。
   *
   * 逐项照上游的结构：
   *  标题 `projectMode ? R.string.home_projects(项目) : R.string.new_session_workspace(工作目录)`（`:75-80`）
   *  首行 `projectMode ? 「新建项目」 : 「浏览文件系统」` —— **二选一的动作行**，都是 `Plus` 图标 + `raised`（`:87-95`）
   *  次行 「主目录」（`workspace_home`，`:96-100`）
   *  列表 `projectMode ? 项目列表（空态 new_session_no_projects） : 最近目录列表`（`:101-112`）
   *
   * ⚠️ 上游**没有**在列表末尾再放一次「新建项目」—— 它只在 projectMode 下作为**首行**出现。
   * 本工程此前把「浏览文件系统」钉死在首行、「新建项目」钉死在末尾，两处都与上游不符（R67 一并改正）。
   */
  @Builder
  workspaceSection() {
    Column({ space: Space.M }) {
      Text(this.workspaceProjectMode() ? '项目' : '工作目录')
        .fontSize(FontSize.TITLE)
        .fontColor(ink())
      // 首行动作行（上游 `:87-95` 的三元）：项目模式是「新建项目」，否则是「浏览文件系统」。
      if (this.workspaceProjectMode()) {
        this.newProjectRow()
      } else {
        this.browseActionRow()
      }
      // 上游 home 行（`workspace_home` =「主目录」）：`if (!projectMode || homeProject == null)`。
      // 注：本工程把「主目录始终可见」当近似（`homeProject` 的判定依赖项目与主目录的匹配，见 PROJECT.md）。
      this.homePathRow()
      if (this.workspaceProjectMode()) {
        // 上游 `:101-107`：项目列表；空态用 `new_session_no_projects`（逐字）。
        if (this.projectsForDevice().length === 0) {
          Text('暂无项目，新建一个项目后即可开始会话。')
            .fontSize(FontSize.SMALL)
            .fontColor(muted())
        } else {
          ForEach(this.projectsForDevice(), (project: AgentProject) => {
            this.projectOptionRow(project)
          }, (project: AgentProject) => `${project.id}:${project.updatedAt}`)
        }
      } else if (this.recentWorkspaceList().length === 0) {
        Text('这台设备上还没有用过的工作目录。')
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
      } else {
        // 上游 `:108-112`：最近使用的工作目录（R13-26 补）。
        ForEach(this.recentWorkspaceList(), (path: string) => {
          this.recentWorkspaceRow(path)
        }, (path: string) => path)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 「浏览文件系统」行（上游 `workspace_browse`）：进入远程目录浏览器。 */
  @Builder
  browseActionRow() {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['plus'], iconSize: FontSize.ICON, color: inkSoft() })
      Text('浏览文件系统')
        .fontSize(FontSize.BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(inkSoft())
        .layoutWeight(1)
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.L)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
    // R39：官方按压态。本行是**卡片形态**（常驻 `raisedSurface()` 底）⇒ `normal` 必须与链式逐字同值。
        .stateStyles({
      normal: { .backgroundColor(raisedSurface()) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.openBrowse();
    })
  }

  // -------------------------------------------------------------------------
  // 目录浏览器视图（上游 ChoosePathSection / CurrentDirectoryBar / PathRow）
  // -------------------------------------------------------------------------

  @Builder
  browseSection() {
    Column({ space: Space.M }) {
      Row() {
        Text(this.browseTitle())
          .fontSize(FontSize.TITLE)
          .fontColor(ink())
          .layoutWeight(1)
        // 上游 `NewSessionCommonComponents.kt:31` 的 SmallPill：**固定高 30dp**、水平 padding **10**、
        // 内部间距 **5**、文字 **13sp ExtraBold** —— 本工程此前是用 padding 撑高、且没设字重。
        Row({ space: 5 }) {
          AaIcon({ d: ICONS['chevron-left'], iconSize: 13, color: muted() })
          Text('返回')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(muted())
        }
        .height(30)
        .padding({ left: 10, right: 10 })
        .borderRadius(Radius.PILL)
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .backgroundColor(raisedSurface())
        .onClick(() => {
          this.closeBrowse();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      this.browseCrumbsRow()
      this.browseCurrentBar()
      this.browseList()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 面包屑。
   * ⚠️ 上游 `NewSessionPathSection` 里**没有**面包屑（只有当前目录条 + `..` 行）；
   * 本工程文件页（`FilesScreen.crumbLine`）已有同构能力，这里按同样形态补上，
   * 路径全部来自 `breadcrumbSegments`（归一到已知根，见坑 140）。
   */
  @Builder
  browseCrumbsRow() {
    Scroll() {
      Row({ space: Space.S }) {
        ForEach(this.browseCrumbs, (segment: DirBreadcrumb) => {
          Text(segment.label)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .onClick(() => {
              this.browseToCrumb(segment);
            })
          Text('/')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
        }, (segment: DirBreadcrumb) => segment.path)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    // 横向 Scroll 内容比视口窄时会被水平居中（align 默认 Center）⇒ 显式左对齐。
    .align(Alignment.Start)
  }

  /** 当前目录条（上游 `CurrentDirectoryBar`）：路径 + 上一级 + 完成。 */
  @Builder
  browseCurrentBar() {
    Row({ space: Space.S }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON_MD, color: muted() })
      Text(this.browsePathLabel())
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // 上游 NewSessionCommonComponents.kt:52 的 CircleMiniButton：**36dp 圆 + 底色 + 1dp 边框**，
      // 不是裸图标（此前本工程两个按钮都是无底色的图标，属于自创形态）。
      if (this.browseParentTarget() !== undefined) {
        AaCircleIconButton({
          name: 'chevron-left',
          diameter: 36,
          iconSize: FontSize.ICON_MD,
          filled: true,
          // R63（SPEC §2.3-4）：功能栏圆钮接入沉浸光感玻璃档（几何/图标尺寸/线色一字未改）。
          glass: true,
          tint: ink(),
          onTap: () => {
            this.browseGoParent();
          }
        })
      }
      AaCircleIconButton({
        name: 'check',
        diameter: 36,
        iconSize: FontSize.ICON_MD,
        filled: true,
        // R63（SPEC §2.3-4）：功能栏圆钮接入沉浸光感玻璃档（几何/图标尺寸/线色/可点态一字未改）。
        glass: true,
        interactive: this.browseCanUseCurrent(),
        tint: this.browseCanUseCurrent() ? primaryAction() : muted(),
        onTap: () => {
          this.browseUseCurrent();
        }
      })
    }
    .width('100%')
    .height(Control.BUTTON_LARGE)
    .padding({ left: Space.M, right: Space.XS })
    .borderRadius(Radius.XL)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(subtle())
  }

  /** 目录列表 + 三态（加载中 / 失败可重试 / 空目录），对应上游 `ChoosePathSection` 的 when 分支。 */
  @Builder
  browseList() {
    Column() {
      if (this.browseLoading) {
        Text('正在加载目录...')
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .padding({ top: Space.M, left: Space.XS })
      } else if (this.browseError.length > 0) {
        Column({ space: Space.S }) {
          Text(this.browseError)
            .fontSize(FontSize.SMALL)
            .fontColor(muted())
          Text('重试')
            .fontSize(FontSize.BODY_SMALL)
            .fontColor(primaryAction())
            .onClick(() => {
              this.browseRetry();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: Space.M, left: Space.XS })
      } else {
        if (this.browseParentTarget() !== undefined) {
          this.browseParentRow()
        }
        if (this.browseEntries.length === 0) {
          Text('这个目录是空的。')
            .fontSize(FontSize.SMALL)
            .fontColor(muted())
            .padding({ top: Space.M, left: Space.XS })
        }
        ForEach(this.browseEntries, (entry: RemoteDirectoryEntry) => {
          this.browseEntryRow(entry)
        }, (entry: RemoteDirectoryEntry) => entry.path)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 「..」行（上游 `PathRow(name = "..")`）。 */
  @Builder
  browseParentRow() {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON, color: muted() })
      Text('..')
        .fontSize(FontSize.BODY)
        .fontColor(ink())
        .layoutWeight(1)
      AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.ICON, color: muted() })
    }
    .width('100%')
    .padding({ left: Space.XS, top: Space.M, bottom: Space.M })
    // R39：官方按压态（浏览行：`..` 上一级 / 目录项）。本行链式无底色 ⇒ `normal` 透明。
        .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.browseGoParent();
    })
  }

  /** 目录行（上游 `PathRow`）：点一次进入一级。 */
  @Builder
  browseEntryRow(entry: RemoteDirectoryEntry) {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON, color: muted() })
      Text(entry.name)
        .fontSize(FontSize.BODY)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.ICON, color: muted() })
    }
    .width('100%')
    .padding({ left: Space.XS, top: Space.M, bottom: Space.M })
    // R39：官方按压态（浏览行：`..` 上一级 / 目录项）。本行链式无底色 ⇒ `normal` 透明。
        .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.browseInto(entry);
    })
  }

  /**
   * 最近使用的工作目录（上游 `feature/sessions/NewSessionWorkspaces.kt:8`）。
   * 只有新建**会话**模式用它；新建**项目**模式显示的是项目列表（两套内容不是同一个东西）。
   */
  private recentWorkspaceList(): string[] {
    if (this.projectOnly) {
      return [];
    }
    return recentWorkspacePaths(
      this.deviceId, this.deviceOs(), this.homePath, this.sessions, this.projects);
  }

  /** 「主目录」行（上游 `workspace_home`）：一键回到设备主目录。 */
  @Builder
  homePathRow() {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON, color: muted() })
      Column({ space: Space.XXS }) {
        Text('主目录')
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.homePath.length > 0) {
          Text(this.homePath)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.isHomeSelected()) {
        AaIcon({ d: ICONS['check'], iconSize: FontSize.ICON, color: primaryAction() })
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.L)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .borderWidth(this.isHomeSelected() ? StrokeWidth.HAIRLINE : 0)
    .backgroundColor(this.isHomeSelected() ? raisedSurface() : Color.Transparent)
    // R39：官方按压态。⚠️ 本行底色是**动态的**（选中才亮底）⇒ `normal` 必须写**逐字相同**的表达式，
    // 不能给 `Color.Transparent`（那样会把选中态的底色覆盖掉）。
        .stateStyles({
      normal: { .backgroundColor(this.isHomeSelected() ? raisedSurface() : Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.selectHomePath();
    })
  }

  /** 当前工作目录是否就是主目录（上游用 `workspacePathKey` 比对）。 */
  private isHomeSelected(): boolean {
    if (this.homePath.length === 0) {
      return false;
    }
    const current = this.effectiveWorkspacePath();
    if (current.length === 0) {
      return false;
    }
    return workspacePathKey(current, this.deviceOs()) === workspacePathKey(this.homePath, this.deviceOs());
  }

  /** 选主目录（上游 `onSelect(WorkspaceChoice(homePath, homeProject?.id))`）。 */
  private selectHomePath(): void {
    if (this.homePath.length === 0) {
      return;
    }
    this.workspacePath = this.homePath;
    this.projectId = '';
  }

  /** 最近使用的工作目录行（上游 `WorkspaceOptionRow(workspaceProjectName(dir), dir, …)`）。 */
  @Builder
  recentWorkspaceRow(path: string) {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON, color: muted() })
      Column({ space: Space.XXS }) {
        Text(workspaceProjectName(path))
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(path)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.isRecentSelected(path)) {
        AaIcon({ d: ICONS['check'], iconSize: FontSize.ICON, color: primaryAction() })
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.L)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .borderWidth(this.isRecentSelected(path) ? StrokeWidth.HAIRLINE : 0)
    .backgroundColor(this.isRecentSelected(path) ? raisedSurface() : Color.Transparent)
    // R39：官方按压态。⚠️ 本行底色是**动态的**（选中才亮底）⇒ `normal` 必须写**逐字相同**的表达式，
    // 不能给 `Color.Transparent`（那样会把选中态的底色覆盖掉）。
        .stateStyles({
      normal: { .backgroundColor(this.isRecentSelected(path) ? raisedSurface() : Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.workspacePath = path;
      this.syncProjectForWorkspace(path);
    })
  }

  private isRecentSelected(path: string): boolean {
    const current = this.effectiveWorkspacePath();
    if (current.length === 0) {
      return false;
    }
    return workspacePathKey(current, this.deviceOs()) === workspacePathKey(path, this.deviceOs());
  }

  @Builder
  projectOptionRow(project: AgentProject) {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['folder'], iconSize: FontSize.ICON, color: muted() })
      Column({ space: Space.XXS }) {
        Text(project.name)
          .fontSize(FontSize.BODY)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (project.workspacePath.length > 0) {
          Text(project.workspacePath)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.isProjectSelected(project)) {
        AaIcon({ d: ICONS['check'], iconSize: FontSize.ICON, color: primaryAction() })
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.L)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .borderWidth(this.isProjectSelected(project) ? StrokeWidth.HAIRLINE : 0)
    .backgroundColor(this.isProjectSelected(project) ? raisedSurface() : Color.Transparent)
    // R39：官方按压态。⚠️ 本行底色是**动态的**（选中才亮底）⇒ `normal` 必须写**逐字相同**的表达式，
    // 不能给 `Color.Transparent`（那样会把选中态的底色覆盖掉）。
        .stateStyles({
      normal: { .backgroundColor(this.isProjectSelected(project) ? raisedSurface() : Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      // ⚠️ R48 修复（用户反馈「无法选择工作目录创建新对话」）：原先这里**只改 `projectId`**，
      // 于是工作目录仍是上一次选的那个 —— 而 `isProjectSelected()` 的判据要求
      // 「projectId 命中 **且** 工作目录与该项目的目录一致（或工作目录为空）」，
      // 两条都不成立 ⇒ 点项目行**毫无视觉反馈**、建出来的会话还落在旧目录。
      // 与 `syncProjectForWorkspace()`（工作目录 → 项目）对称：选项目必须把工作目录一起带过去。
      this.projectId = project.id;
      if (project.workspacePath.length > 0) {
        this.workspacePath = project.workspacePath;
      }
    })
  }

  /** 「新建项目」行 → 上游是独立目的地 `NewProject`（复用本屏的 projectOnly 模式）。 */
  @Builder
  newProjectRow() {
    Row({ space: Space.M }) {
      AaIcon({ d: ICONS['plus'], iconSize: FontSize.ICON, color: inkSoft() })
      Text('新建项目')
        .fontSize(FontSize.BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(inkSoft())
        .layoutWeight(1)
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.L)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
    // R39：官方按压态。本行是**卡片形态**（常驻 `raisedSurface()` 底）⇒ `normal` 必须与链式逐字同值。
        .stateStyles({
      normal: { .backgroundColor(raisedSurface()) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      Router.push(Route.NEW_PROJECT);
    })
  }

  /** 首条消息（保留既有能力：标题 + 内容 + 稳定 clientMessageId）。 */
  @Builder
  messageSection() {
    Column({ space: Space.M }) {
      Row({ space: Space.S }) {
        Text('首条消息')
          .fontSize(FontSize.TITLE)
          .fontColor(ink())
          .layoutWeight(1)
        // R91：斜杠指令入口。**不新造风格** —— 与「模型 / 推理强度 / 权限模式」同一枚
        // 图标 + 文字的按钮形态，只是这一次是展开/收起面板。
        Row({ space: Space.XS_PLUS }) {
          AaIcon({ d: ICONS['square-terminal'], iconSize: FontSize.ICON_MD, color: primaryAction() })
          Text('指令')
            .fontSize(FontSize.CAPTION)
            .fontColor(primaryAction())
        }
        .padding({ left: Space.M, right: Space.M, top: Space.XS, bottom: Space.XS })
        .borderRadius(Radius.PILL)
        .backgroundColor(raisedSurface())
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .stateStyles({
          normal: { .backgroundColor(raisedSurface()) },
          pressed: { .backgroundColor(rowPressedSurface()) }
        })
        .onClick(() => {
          this.toggleCommandPanel();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextArea({ text: this.content, placeholder: '描述第一个任务…' })
        .fontSize(FontSize.BODY)
        .constraintSize({ minHeight: 90, maxHeight: 180 })
        .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.S })
        .borderRadius(Radius.M)
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .backgroundColor(raisedSurface())
        .onChange((value: string) => {
          this.content = value;
        })

      if (this.commandPanelOpen) {
        this.commandPanel()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 展开/收起指令面板（目录恒为内置清单，见 commandCatalog 的注释）。 */
  private toggleCommandPanel(): void {
    this.commandPanelOpen = !this.commandPanelOpen;
    this.commandNotice = '';
    if (this.commandPanelOpen) {
      this.commandCatalog = SlashCommandStore.get().draftCatalog();
    }
  }

  /**
   * R91：指令面板 —— 复用 SessionDetailScreen 的面板设计语言（同一套 Design 令牌、
   * 同一套「一行 = 图标 + /id + 说明」的形态），但**来源行必须写出来**：
   * 本页恒为内置目录（会话尚未建立），不能让用户以为是服务端返回的。
   *
   * ⚠️ 失败/不可用一律**如实说明**，不退化成空面板。
   */
  @Builder
  commandPanel() {
    Column({ space: Space.XS }) {
      Row() {
        Text('指令')
          .fontSize(FontSize.CAPTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(muted())
          .layoutWeight(1)
        Text('收起')
          .fontSize(FontSize.CAPTION)
          .fontColor(primaryAction())
          .onClick(() => {
            this.commandPanelOpen = false;
          })
      }
      .width('100%')

      // 来源行：本页恒为草稿态 ⇒ 内置目录（见 catalogSourceLabel 的 draft 分支）。
      Text(catalogSourceLabel(this.commandCatalog, true))
        .fontSize(FontSize.CAPTION)
        .fontColor(muted())
        .width('100%')

      if (this.commandNotice.length > 0) {
        Text(this.commandNotice)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
      }

      if (this.contentBlockedByDraftCommand().length > 0) {
        Text(this.contentBlockedByDraftCommand())
          .fontSize(FontSize.CAPTION)
          .fontColor($r('app.color.error_text'))
          .width('100%')
      }

      if (this.commandCatalog.items.length === 0) {
        Text('没有可用的指令目录：内置清单为空。')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
      } else {
        Scroll() {
          Column({ space: Space.XS }) {
            ForEach(this.commandCatalog.items, (item: SlashCommandItem) => {
              this.commandRow(item)
            }, (item: SlashCommandItem) => `cmd:${item.id}:${item.sessionBound}:${item.enabled}`)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 220 })
        // 纵向 Scroll 必须显式顶对齐（内容短于视口时默认会被垂直居中，本工程有静态判据）。
        .align(Alignment.Top)
        .scrollBar(BarState.Off)

        if (draftUsableCount(this.commandCatalog.items) > 0) {
          Text('草稿态：点指令只会把它填进输入框，随首条消息一起发给 Agent；作用于会话的指令（如 /compact）要等会话建立后才能用。')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .width('100%')
        }
      }
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, top: Space.M, bottom: Space.M })
    .borderRadius(Radius.XL)
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .backgroundColor(raisedSurface())
  }

  /** 指令面板里的一行（与 SessionDetailScreen.commandRow 同形：图标 + /id + 副标题 + 禁用态）。 */
  @Builder
  commandRow(item: SlashCommandItem) {
    Row({ space: Space.S }) {
      AaIcon({
        d: ICONS['hash'],
        iconSize: FontSize.ICON_MD,
        color: slashCommandUsableInDraft(item) ? ink() : muted()
      })
      Column({ space: Space.XXS }) {
        Text(`/${item.id}`)
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(slashCommandUsableInDraft(item) ? ink() : muted())
          .width('100%')
        if (this.commandRowDetail(item).length > 0) {
          Text(this.commandRowDetail(item))
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Space.S, right: Space.S, top: Space.XS, bottom: Space.XS })
    .borderRadius(Radius.M)
    .opacity(slashCommandUsableInDraft(item) ? 1 : 0.5)
    // 按压态：与配置行同款（禁用行不给按压反馈 —— 它本来就点不动）。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(slashCommandUsableInDraft(item) ? rowPressedSurface() : Color.Transparent) }
    })
    .onClick(() => {
      this.tapCommand(item);
    })
  }

  /** 指令行副标题：不可用时顶掉说明显示**原因**（本页恒为草稿态，用草稿态判据）。 */
  private commandRowDetail(item: SlashCommandItem): string {
    const reason = draftCommandDisabledReason(item);
    if (reason.length > 0) {
      return reason;
    }
    const parts: string[] = [];
    if (item.description.length > 0) {
      parts.push(item.description);
    }
    if (item.acceptsArgs && item.hint.length > 0) {
      parts.push(`参数：${item.hint}`);
    }
    // 分隔符用 ASCII 的 ' | '：本文件在 suite-icons 的「残留字形」扫描名单里，
    // 间隔号（U+00B7）不在允许标点集（仅 — 与 •）内，写它会直接红掉那道闸门。
    return parts.join(' | ');
  }

  /** 点选指令：可用的填进首条消息（**不覆盖已输入文字**）；不可用的给一句原因。 */
  private tapCommand(item: SlashCommandItem): void {
    if (!slashCommandUsableInDraft(item)) {
      this.commandNotice = `/${item.id} 暂时不能用：${draftCommandDisabledReason(item)}`;
      return;
    }
    this.content = appendSlashToDraft(this.content, slashInsertionFor(item));
    this.commandNotice = draftSlashNotice(item);
  }

  /**
   * 首条消息里手打了「作用于会话的指令」时的拦截理由（空串 = 放行）。
   *
   * 与 SessionDetailScreen 同一口径：`/compact` 这类指令在草稿态当消息发出去，
   * DSH 会把它当普通文本送进模型 —— 用户以为压缩了其实没有。**拦住并说明理由**。
   */
  private contentBlockedByDraftCommand(): string {
    return draftTypedCommandBlocker(this.commandCatalog.items, this.content);
  }

  /** 固定底部动作区：说明文字 13sp + 主按钮（54 / 圆角 18 / 16sp）。 */
  @Builder
  bottomActionBar() {
    Column({ space: Space.S_PLUS }) {
      if (this.blockReason().length > 0) {
        Text(this.blockReason())
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .width('100%')
      }
      this.startButton()
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.S_PLUS, bottom: Space.S_PLUS })
  }

  /**
   * 主按钮（上游 `StartChatButton`，锚文 `NewSessionCommonComponents.kt:82-111`）。
   *
   * 逐条对齐上游：高 54 / 圆角 18 / 文字 16sp SemiBold / **文字之后 8dp 间隔 + `ForwardGlyph`**；
   * 底色**恒为 `primaryAction`**，禁用时只把**底色**降到 45% 不透明度（见常量注释），
   * 文字**始终**是 `onPrimaryAction`（白）。
   *
   * ⚠️ 两个都不能踩：
   *  ① 旧实现禁用态换 `subtle()` 浅灰 + `muted()` 灰字 —— 上游**没有**这个形态（F-2 的成因之一）；
   *  ② 也**不能**对整个 Row 用 `.opacity()` —— 那会把白字一起洗掉（上游只降底色 alpha）。
   * 正解是把底色单独放一层：`Stack` 底层只画背景、顶层画「文字 + 箭头」。
   * 底层与顶层都**没有** `onClick`，点击统一由 `Stack` 自己接（不会出现坑 29 那种
   * 「铺满的兄弟吃掉点击」—— 那条的前提是**遮挡者自己带 onClick**）。
   */
  @Builder
  startButton() {
    Stack() {
      // 底层：只有底色参与 alpha（上游 `primaryAction.copy(alpha = alpha)`）。
      Column()
        .width('100%')
        .height(Control.BUTTON_LARGE)
        .borderRadius(Radius.XL)
        .backgroundColor(primaryAction())
        .opacity(this.canCreate() ? 1 : START_BUTTON_DISABLED_ALPHA)

      Row({ space: Space.S }) {
        Text(this.creating || this.creatingProject ? '创建中…' : this.submitLabel())
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(onPrimaryAction())
          .maxLines(1)
        // 上游同款箭头（`ForwardGlyph`）：文字之后、8dp 间隔 —— 与 `Row` 的 `space` 同值。
        AaIcon({
          d: ICONS['chevron-right'],
          iconSize: START_BUTTON_GLYPH_SIZE,
          color: onPrimaryAction(),
          stroke: START_BUTTON_GLYPH_STROKE
        })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(Control.BUTTON_LARGE)
    }
    .width('100%')
    .height(Control.BUTTON_LARGE)
    .onClick(() => {
      this.submit();
    })
  }

  // -------------------------------------------------------------------------
  // Runtime 行
  // -------------------------------------------------------------------------

  /**
   * Runtime 行。与通用的选择行不同：**只有就绪的运行时可选**。
   *
   * 未就绪的（没启用/没配置/启动中）依旧**列出来**（用户需要知道它存在、以及为什么不能用），
   * 但置灰且点不动 —— 对应上游把不可用项留在列表里、只禁用交互的做法。
   */
  @Builder
  runtimeRow(runtime: RemoteDeviceRuntime) {
    // 上游 Agent 选项只有 label（`NewSessionScreen.kt:547-552`），选中态是右侧打勾、
    // 不可用的**留在列表里但点不动**（`enabled` 为假 ⇒ 文案 α0.42）。
    // 旧实现自创了圆点 + 「已选」/「不可用」胶囊 + 彩色描边卡片，与上游下拉项不是一个形态（R14 修正）。
    AaConfigMenuItem({
      label: deviceRuntimeLabel(runtime.displayName, runtime.runtimeType),
      active: this.runtimeId === runtime.runtimeId,
      usable: runtimeIsReady(runtime),
      onTap: () => {
        this.runtimeId = runtime.runtimeId;
        this.runtimeType = runtime.runtimeType;
        // R47：用户显式选了 Agent ⇒ 记住「设备 + Agent」这一对。
        this.rememberTarget();
        // 换 Runtime → 模型 / 权限目录重新拉（上游是同一个 LaunchedEffect 的 key 变化）。
        this.loadRuntimeConfiguration().then(() => {});
      }
    })
  }

  // -------------------------------------------------------------------------
  // 提交动作
  // -------------------------------------------------------------------------

  private async createProject(): Promise<void> {
    this.creatingProject = true;
    this.error = '';
    try {
      const serverUrl = readServerUrl();
      const token = readAccessToken();
      await AppServices.get().sessions.createProject(
        serverUrl, token, this.newProjectName.trim(), this.deviceId, this.pendingWorkspace.trim(), true);
      this.newProjectName = '';
      this.pendingWorkspace = '';
      await this.dashboard.refreshAll();
      if (!this.alive) {
        return;
      }
      if (this.projectOnly) {
        // ：projectOnly 模式创建完成后回首页（不留在本屏）。
        Router.back();
        return;
      }
      this.pickProjectForDevice();
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.creatingProject = false;
    }
  }

  private async createSession(): Promise<void> {
    this.creating = true;
    this.error = '';
    // ⚠️ `clientMessageId` 必须带：DSH 运行时**硬性要求**它
    // （`connector/…/runtimes/dsh/runtime.py` L327：「A message and a stable
    // clientMessageId are required」），缺了就返回 runtime_invalid_request →
    // 服务端包成 HTTP 502，表现为「莫名其妙建不了会话」。
    // Codex / Claude 只是不用它做乐观消息对齐（不报错），所以这个坑只在 DSH 上现形。
    // 上游同样强制必填（`SessionsController.kt` L758 还专门校验了一次）。
    // id 在**进入本方法时生成一次**，重试沿用同一个 —— 它本来就是「稳定标识」，
    // 每次重试换新 id 会让服务端无法把重试认成同一条消息。
    if (this.pendingClientMessageId.length === 0) {
      this.pendingClientMessageId = newClientMessageId();
    }
    try {
      const serverUrl = readServerUrl();
      const token = readAccessToken();
      // 模型 / 权限随请求体带上（上游 `NewSessionSelections.toMap()` →
      // `selections = draft.selections.toMap()`，键固定是 `model` / `permission`）。
      // ⚠️ 两个值都取 **selectionId** 而不是 id：模型的（选中推理项时是推理项的
      // selectionId；模型自带推理项却没选中时**不带** model）由纯逻辑给出，见 DirBrowse。
      const selections: Record<string, string> = {};
      const modelSelection = modelSelectionIdFor(
        this.modelOptions, this.selectedModelId, this.selectedReasoningId);
      if (modelSelection.length > 0) {
        selections['model'] = modelSelection;
      }
      const permissionSelection = permissionSelectionIdFor(
        this.permissionOptions, this.selectedPermissionId);
      if (permissionSelection.length > 0) {
        selections['permission'] = permissionSelection;
      }
      const workspace = this.effectiveWorkspacePath();
      // R51：DSH 的会话级 Agent 预设走 `runtimeOptions.agentPreset`。
      // 没选（或该 runtime 不提供预设）时**不带这个字段** —— 连接器会回落到它自己的默认模式。
      const runtimeOptions = runtimeOptionsForPreset(
        this.showAgentPresetRow() ? this.selectedAgentPresetId : '');
      const request: RemoteSessionCreateAndStartRequest = {
        connectorId: this.deviceId,
        projectId: this.projectId,
        runtimeType: this.runtimeType,
        runtimeId: this.runtimeId,
        title: this.title.trim().length > 0 ? this.title.trim() : undefined,
        cwd: workspace.length > 0 ? workspace : undefined,
        content: this.content,
        selections: selections,
        runtimeOptions: runtimeOptions,
        attachments: [],
        clientMessageId: this.pendingClientMessageId
      };
      const response = await AppServices.get().sessions.createAndStartSession(serverUrl, token, request);
      this.content = '';
      this.title = '';
      this.pendingClientMessageId = '';
      await this.dashboard.refreshAll();
      if (this.alive) {
        Router.pop();
        Router.push(Route.SESSION, response.session.id);
      }
    } catch (error) {
      // 保留 pendingClientMessageId：网络类失败可能是「其实建成了但没收到响应」，
      // 沿用同一个 id 重试才不会在服务端建出第二条会话。
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.creating = false;
    }
  }
}

/** 运行时能力 ID：提供模型 / 权限目录（上游 `MODEL_CATALOG_CAPABILITY` 同值）。 */
const MODEL_CATALOG_CAPABILITY: string = 'catalog.model';
const PERMISSION_CATALOG_CAPABILITY: string = 'catalog.permission';

/** 权限项的本地化文案（label + description）。 */
interface PermissionText {
  label: string;
  description: string;
}

/**
 * 权限翻译键 → 中文文案（逐字取自上游 `values-zh-rCN/strings.xml` 的 runtime_permission_* 条目）。
 * 与上游分层一致：键由纯逻辑给出（`model/DirBrowse.ets`），文案留在 UI 层。
 */
function permissionTextFor(key: string): PermissionText | undefined {
  if (key === 'dsh.readOnly') {
    return { label: '仅可查看', description: '' };
  }
  if (key === 'dsh.workspaceWrite') {
    return { label: '工作区内修改', description: '' };
  }
  if (key === 'dsh.fullAccess') {
    return { label: '完全权限', description: '' };
  }
  if (key === 'requestApproval') {
    return { label: '请求批准', description: '编辑外部文件和使用互联网时始终询问' };
  }
  if (key === 'autoReview') {
    return { label: '替我审批', description: '仅对检测到的风险操作请求批准' };
  }
  if (key === 'fullAccess') {
    return { label: '完全访问权限', description: '可不受限制地访问互联网和您电脑上的任何文件' };
  }
  if (key === 'claude.default') {
    return { label: '询问权限', description: '使用 Claude Code 默认的高风险工具确认方式。' };
  }
  if (key === 'claude.acceptEdits') {
    return { label: '接受编辑', description: '自动接受文件编辑；其他高风险工具仍会询问。' };
  }
  if (key === 'claude.plan') {
    return { label: '计划模式', description: '允许规划，但不执行写入或命令。' };
  }
  if (key === 'claude.auto') {
    return { label: '自动模式', description: '使用 Claude Code 的自动分类器判断高风险操作。' };
  }
  if (key === 'claude.dontAsk') {
    return { label: '不询问', description: '拒绝未获批准的工具，不再弹出权限确认。' };
  }
  if (key === 'claude.bypassPermissions') {
    return { label: '完全访问权限', description: '跳过权限确认，允许不受限制地使用工具。' };
  }
  return undefined;
}

function permissionTranslationKeyOf(runtime: string, permission: RemoteRuntimePermission): string {
  // metadata 直接透传（可缺省）：不在这里造空对象字面量 —— ArkTS 会判
  // `arkts-no-untyped-obj-literals`（本工程禁无类型字面量）。
  return runtimePermissionTranslationKey(runtime, permission.id, permission.metadata);
}

/** 权限项的显示名：有本地化文案就用它，否则回落到服务端给的 `displayName`。 */
function permissionDisplayLabel(runtime: string, permission: RemoteRuntimePermission): string {
  const text = permissionTextFor(permissionTranslationKeyOf(runtime, permission));
  return text !== undefined ? text.label : permission.displayName;
}

/** 权限项的说明：本地化文案优先，其次服务端的 `description`。 */
function permissionDisplayDescription(runtime: string, permission: RemoteRuntimePermission): string {
  const text = permissionTextFor(permissionTranslationKeyOf(runtime, permission));
  if (text !== undefined && text.description.length > 0) {
    return text.description;
  }
  const description = permission.description;
  return description !== undefined ? description : '';
}

function runtimeStatusLabel(status: string): string {
  switch (status) {
    case 'running': return '运行中';
    case 'available': return '可用';
    case 'starting': return '启动中';
    case 'error': return '错误';
    case 'unavailable': return '不可用';
    default: return status;
  }
}

/**
 * 运行时是否**可以拿来新建会话**。
 *
 * 口径与上游 `activeNewSessionRuntimes`（`feature/sessions/NewSessionRuntimeInventory.kt` L7-9）
 * 一致：`configured && active && status == Running`（实现在
 * `model/SessionGating.ets`，纯函数、已进 Node 单测）。
 * 服务端在 create-and-start 上做的是同一件事（`ensure_active_running`），但**发令即返回、
 * 不等 running**，所以「active 但 starting」会被放行到 Connector 再报错（真机实测）。
 * 客户端提前用同一口径过滤，才能避免「选中了 → 填完了 → 建不了」这种最伤人的失败路径。
 */
function runtimeIsReady(runtime: RemoteDeviceRuntime | undefined): boolean {
  if (runtime === undefined) {
    return false;
  }
  return gatingRuntimeIsReady(runtime.configured, runtime.active, runtime.status);
}

/**
 * 运行时的可读原因：把 `RemoteDeviceRuntime` 上的 `error` / `discovery` 摊平成标量，
 * 再交给 `model/SessionGating.ets` 的纯函数选优先级（那里已进 Node 单测）。
 *
 * ⚠️ 用 `typeof x === 'string'` 逐字段收窄而不是直接 `as string`：服务端字段是
 * `Record<string, Object>` 形态（`JsonMap`），缺字段或不符类型时强转会在真机上
 * 拿到 `undefined` 拼进文案，显示成 "undefined"。
 */
function runtimeReasonText(runtime: RemoteDeviceRuntime): string {
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

export { DeviceStore };
