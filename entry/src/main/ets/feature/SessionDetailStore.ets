/**
 * 会话详情状态（对应 Android `feature/sessiondetail/SessionDetailController.kt` +
 * `feature/realtime/SessionRealtimeController.kt`）。
 *
 * 生命周期：
 * 1. `load()` 拉 `/sessions/{id}/snapshot`（会话元数据 + 时间线 + 运行时状态 + 公告 + 能力 + 目录）；
 * 2. `startRealtime()` 取票据 → 连 `/sessions/{id}/ws`；
 * 3. 收到 `session.subscribed` 后做一次 `/events?after=` 游标恢复并刷新运行时状态；
 * 4. 增量事件按 34ms 窗口批量落地（对应 Android 的 30Hz 合批）。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl, readUserId } from '../store/AuthSessionStore';
import {
  AgentDevice, AgentProject, AgentSession, deviceRuntimeLabel, toAgentSession
} from '../model/AppModels';
import {
  RemoteAttachmentRef, RemoteDeviceRuntime, RemoteInlineAttachmentRef, RemoteRuntimeCapabilitySet,
  RemoteRuntimeModelCatalog, RemoteRuntimeNotice, RemoteRuntimePermissionCatalog, RemoteSession,
  RemoteSessionCreateAndStartRequest, RemoteSessionEventPayload, RemoteSessionCommand,
  RemoteSessionRuntimeState, RemoteTimelineItem, SessionEventType
} from '../model/Types';
import { RealtimeSocket, SocketHandlers, reconnectDelayMillis } from '../api/RealtimeApi';
import {
  capabilityUsable, emptyRaw, parseCapabilitySet, parseModelCatalog, parsePermissionCatalog
} from '../api/Parse';
// R42 性能轮：时间线投影改由 `feature/TimelineView.ets` 的增量视图承担
// （只在 item 新出现 / 引用变化时才真正投影，见该文件的不变量说明）。
import { TimelineMessage, mergeTimelineItems } from './TimelineProjection';
import { TimelineMessageView, buildOptimisticMessage } from './TimelineView';
import { DashboardStore } from './DashboardStore';
import { newClientMessageId } from '../utils/Codec';
// R53：草稿会话（新对话）—— 纯逻辑在 `model/NewChatDraft.ets`，这里只做编排。
import {
  NewChatDevice, NewChatProject, NewChatRuntime, NewChatSession,
  DraftSetupKind, NewChatInventory, draftSetupKind, parseNewChatEntry,
  pickDraftDevice, pickDraftProject, pickDraftRuntime, projectIdOfSession, projectsForDevice
} from '../model/NewChatDraft';
import {
  NewSessionPreferenceEntry, NewSessionSelection, decodePreferenceBook, encodePreferenceBook,
  newSessionAccountKey, readPreferenceEntry, restoreSelection, withSelection
} from '../model/NewSessionPreference';
import { LAST_SESSION_KEY, NEW_SESSION_PREF_KEY } from '../store/AppPreferences';
import {
  RUNTIME_MODEL_CAPABILITY, RUNTIME_PERMISSION_CAPABILITY, RUNTIME_MODEL_KEY, RUNTIME_PERMISSION_KEY,
  RuntimeSelectionOption, modelSelectionOptions, permissionSelectionOptions
} from '../model/RuntimeSelection';
import {
  AgentPresetOption, agentPresetOptions, defaultAgentPreset, presetStillSelectable, runtimeOptionsForPreset
} from '../model/AgentPreset';
// R54：草稿态的**首条消息附件**（内联 base64）—— 纯逻辑与闸门在 model/InlineAttachment.ets。
import {
  LocalAttachment, RUNTIME_ATTACHMENT_CAPABILITY, inlineAttachmentUnavailableText
} from '../model/InlineAttachment';
import {
  modelSelectionIdFor, modelSelectionTargetOf, permissionSelectionIdFor
} from '../model/DirBrowse';
import {
  runtimeIsReady as gatingRuntimeIsReady, runtimeIsSettling as gatingRuntimeIsSettling,
  runtimeReasonText as gatingRuntimeReasonText
} from '../model/SessionGating';
// 发送动作与能力 id 都来自 `model/SessionGating.ets`（纯逻辑，已进 Node 单测）。
// ⚠️ ArkTS 要求所有 import 排在其它语句**之前**（`arkts-no-misplaced-imports`），
// 所以这里只 import、不在这里 `export … from`（那句会被当成普通语句）。
import {
  MessageAction, isReadOnly as gatingIsReadOnly, messageActionFor,
  effectiveRuntimeStatus as gatingEffectiveStatus
} from '../model/SessionGating';

export enum ConnectionState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  RECOVERING = 'recovering',
  OFFLINE = 'offline'
}


/**
 * R53：草稿会话的目标（服务端会话**还不存在**时的「预览态」）。
 *
 * 由来：用户要求「新建对话直接进入**原对话**界面」，而服务端的 `create-and-start` 又要求
 * 首条消息非空（DSH 运行时，见 `connector/runtimes/dsh/runtime.py:327`）。两者合起来的唯一解是：
 * **本店持有一张本地预览会话**，界面照常渲染（标题 / 元信息 / 输入区 / 运行时设置面板全都能用），
 * 第一条消息发出时才真正 `create-and-start`。上游 Android 的 `NewSessionDraft.previewSession()`
 * 就是这个东西（`NewSessionDraft.kt:26-55`）。
 */
export interface PreparedChatDraft {
  connectorId: string;
  deviceName: string;
  runtimeId: string;
  runtimeType: string;
  runtimeName: string;
  projectId: string;
  projectName: string;
  cwd: string;
  /** 本地会话 id（界面与草稿存储都用它；创建成功后换成服务端 id）。 */
  localSessionId: string;
}

/**
 * 把「上次选择」写回持久化（与 `NewSessionScreen.rememberSelection` 同语义、同一把键）。
 *
 * 放在模块级而不是类里：它不碰任何实例状态，只是「读整本 → 替换该作用域 → 写回」
 * —— 草稿态创建成功后调一次，让下一次新建仍然沿用这次的选择。
 */
export function writeNewSessionSelection(deviceId: string, runtimeId: string,
  selection: NewSessionSelection): void {
  const raw = AppStorage.get<string>(NEW_SESSION_PREF_KEY);
  const book = decodePreferenceBook(raw !== undefined ? raw : '');
  const account = newSessionAccountKey(readServerUrl(), readUserId());
  if (account.length === 0) {
    return;
  }
  const next = withSelection(book, account, deviceId, runtimeId, selection);
  if (next === book) {
    return;
  }
  AppStorage.setOrCreate<string>(NEW_SESSION_PREF_KEY, encodePreferenceBook(next));
}

/**
 * 读某个作用域下记住的选择（设置页的「Agent 预设」要**在既有选择上改一项**，不能整条覆盖）。
 *
 * 与 `writeNewSessionSelection` 同一把键、同一个账号分桶；没有记录时返回 undefined。
 */
export function readNewSessionSelection(deviceId: string,
  runtimeId: string): NewSessionSelection | undefined {
  const raw = AppStorage.get<string>(NEW_SESSION_PREF_KEY);
  const book = decodePreferenceBook(raw !== undefined ? raw : '');
  const account = newSessionAccountKey(readServerUrl(), readUserId());
  if (account.length === 0) {
    return undefined;
  }
  return restoreSelection(readPreferenceEntry(book, account), deviceId, runtimeId);
}

export class SessionDetailStore {
  private static instance?: SessionDetailStore;

  sessionId: string = '';
  session?: AgentSession;
  runtimeState?: RemoteSessionRuntimeState;
  notices: RemoteRuntimeNotice[] = [];
  messages: TimelineMessage[] = [];
  capabilities: RemoteRuntimeCapabilitySet = { revision: 0, capabilities: [] };
  modelCatalog?: RemoteRuntimeModelCatalog;
  permissionCatalog?: RemoteRuntimePermissionCatalog;
  commands: RemoteSessionCommand[] = [];

  loading: boolean = false;
  sending: boolean = false;
  error: string = '';
  notice: string = '';

  connection: ConnectionState = ConnectionState.IDLE;
  cursor: string = 'seq:0';
  hasMoreHistory: boolean = false;
  optimisticCount: number = 0;

  // ---- R53：草稿会话（新对话） ----------------------------------------------------
  /** 非空 = 当前处于草稿态（服务端会话还没建）。 */
  prepared?: PreparedChatDraft;
  /** 草稿态的就绪分支（`DraftSetupKind`），未就绪时页面据此显示引导面板。 */
  preparedKind: string = DraftSetupKind.READY;
  /** 过渡态的原始原因（服务端/连接器给的那句话）。 */
  preparedReason: string = '';
  /** 草稿态的工作区面板 / 切换设备要用到的三份**窄快照**。 */
  preparedDevices: NewChatDevice[] = [];
  preparedProjects: NewChatProject[] = [];
  preparedSessions: NewChatSession[] = [];
  /** 原始运行时描述（Agent 预设目录就在它里面，不需要额外请求）。 */
  private preparedRuntimeDtos: RemoteDeviceRuntime[] = [];
  /** DSH 的会话级 Agent 预设（目录就在 runtime 描述里）。 */
  preparedPreset: string = '';
  preparedPresetOptions: AgentPresetOption[] = [];
  /** R54：草稿态暂存的**本地附件**（还没有 fileId，创建会话时才编码成内联附件）。 */
  preparedAttachments: LocalAttachment[] = [];
  /**
   * R54：该 runtime 是否上报了 `runtime.attachment`（服务端带附件创建时**硬性要求**它可用，
   * 见 `server/agent_server/services/session_run.py:185-193`）。
   */
  preparedAttachmentsAllowed: boolean = false;
  /** R54：这次草稿是否已经补过一次「实时发现」（见 `refreshPreparedInventory`），最多一次。 */
  private preparedDiscoveryDone: boolean = false;
  /** 创建成功后服务端给的会话 id（页面据此 replace 到真会话）。 */
  createdSessionId: string = '';

  private items: RemoteTimelineItem[] = [];
  /** 增量投影 + 乐观消息叠加；`messages` 由它产出（R42，见 `feature/TimelineView.ets`）。 */
  private view: TimelineMessageView = new TimelineMessageView();
  private listeners: Array<() => void> = [];
  private socket?: RealtimeSocket;
  private subscribed: boolean = false;
  private reconnectAttempt: number = 0;
  private reconnectTimer: number = -1;
  private batchBuffer: RemoteTimelineItem[] = [];
  private batchTimer: number = -1;
  private eventBatch: string[] = [];
  private lastSnapshotRequiredCursor: string = '';

  static get(): SessionDetailStore {
    if (SessionDetailStore.instance === undefined) {
      SessionDetailStore.instance = new SessionDetailStore();
    }
    return SessionDetailStore.instance;
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  // -------------------------------------------------------------------------
  // 首屏
  // -------------------------------------------------------------------------

  async open(sessionId: string): Promise<void> {
    if (this.sessionId !== sessionId) {
      this.resetState(sessionId);
    }
    this.loading = true;
    this.error = '';
    this.notify();
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      this.loading = false;
      this.error = '未登录。';
      this.notify();
      return;
    }
    try {
      const services = AppServices.get();
      const snapshot = await services.sessions.getSessionSnapshot(serverUrl, token, sessionId, 100);
      this.session = this.mapSession(snapshot.session);
      this.runtimeState = snapshot.state;
      this.notices = snapshot.notices;
      this.capabilities = snapshot.effectiveCapabilities;
      if (snapshot.catalogs !== undefined) {
        this.modelCatalog = snapshot.catalogs.model;
        this.permissionCatalog = snapshot.catalogs.permission;
      }
      // ⚠️ **R80 真机复验补的漏点**：这里原来是 `this.items = snapshot.timeline.items;` —— **直接赋值**，
      //  绕过了 `mergeTimelineItems` 的两道 items 层后处理（业务身份去重 + 压缩标记归并）。
      //  后果是**真机实测到的**：进会话 / 整体刷新这条路径上「上下文压缩」标记**不归并**，
      //  同一次压缩的 start / summary / end 各占一行 —— R80 首版在 `sess_kSzCGOaVpXjYNg` 上仍是 3 行。
      //  ⇒ 改走 `mergeTimelineItems([], items, true)`（= replace 分支：latestById + 两道后处理），
      //  与增量路径（下面的 `mergeTimelineItems(this.items, ...)`）**同一套**。
      //  空数组 + replace 与「直接赋值」在语义上等价：replace 分支只对入参本身做后处理，不读 current。
      this.items = mergeTimelineItems([], snapshot.timeline.items, true);
      // 全量快照 = 视图整体重建（投影缓存与在途乐观消息一起归零，与原「覆盖 messages」语义一致）。
      this.view.reset();
      this.view.setItems(this.items);
      this.messages = this.view.messages();
      this.optimisticCount = this.view.optimisticCount();
      this.hasMoreHistory = snapshot.timeline.hasMore;
      this.cursor = snapshot.eventCursor;
      this.lastSnapshotRequiredCursor = '';
      await this.refreshRuntimeState();
      await this.loadCommands();
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.loading = false;
      this.notify();
    }
  }

  private resetState(sessionId: string): void {
    this.stopRealtime();
    this.sessionId = sessionId;
    this.session = undefined;
    this.runtimeState = undefined;
    this.notices = [];
    this.items = [];
    this.messages = [];
    this.view.reset();
    this.commands = [];
    this.modelCatalog = undefined;
    this.permissionCatalog = undefined;
    this.cursor = 'seq:0';
    this.hasMoreHistory = false;
    this.optimisticCount = 0;
    this.error = '';
    this.notice = '';
  }


  // -------------------------------------------------------------------------
  // R53：草稿会话（新对话）
  // -------------------------------------------------------------------------

  isPrepared(): boolean {
    return this.prepared !== undefined;
  }

  draft(): PreparedChatDraft | undefined {
    return this.prepared;
  }

  /**
   * 进入草稿态：解析「设备 → Agent → 工作区」，装好**本地预览会话**与两套目录。
   *
   * 每一步失败都**停下并把原因写进 `preparedKind`**（页面显示引导面板，而不是白屏）——
   * 这与旧的新建会话页同一套口径（`NewSessionScreen.setupKind`），文案也共用 `draftSetupTitle` 等。
   */
  async beginPrepared(entryParam: string): Promise<void> {
    this.stopRealtime();
    this.resetState('');
    this.prepared = undefined;
    this.createdSessionId = '';
    this.preparedPreset = '';
    this.preparedPresetOptions = [];
    this.preparedAttachments = [];
    this.preparedAttachmentsAllowed = false;
    this.preparedDiscoveryDone = false;
    this.preparedKind = DraftSetupKind.LOADING;
    this.preparedReason = '';
    this.loading = true;
    this.notify();
    const entry = parseNewChatEntry(entryParam);
    const dashboard = DashboardStore.get();
    // 冷启动时设备 / 项目可能还没到：等一次首屏刷新（与首页同一条链路）。
    if (dashboard.devices.length === 0) {
      await dashboard.refreshAll();
    }
    this.syncPreparedInventory();
    if (this.preparedDevices.length === 0) {
      this.finishPrepared(DraftSetupKind.NO_DEVICE);
      return;
    }
    let deviceId = pickDraftDevice(this.preferenceEntry(), entry.connectorId, this.preparedDevices);
    // 「指定工作区」属于另一台设备时**以工作区为准**（用户点的是那个目录，不是那台设备）。
    const presetProject = this.projectOf(entry.projectId);
    if (presetProject !== undefined && presetProject.connectorId !== deviceId) {
      deviceId = presetProject.connectorId;
    }
    await this.resolveAgentFor(deviceId, entry.projectId);
  }

  /** 引导面板的「重新检查」：按当前选择重解析一次（Agent 可能刚从 starting 变成 running）。 */
  async reloadPrepared(): Promise<void> {
    const draft = this.prepared;
    if (draft !== undefined) {
      await this.resolveAgentFor(draft.connectorId, draft.projectId);
      return;
    }
    this.preparedKind = DraftSetupKind.LOADING;
    this.loading = true;
    this.notify();
    this.syncPreparedInventory();
    if (this.preparedDevices.length === 0) {
      this.finishPrepared(DraftSetupKind.NO_DEVICE);
      return;
    }
    const deviceId = pickDraftDevice(this.preferenceEntry(), '', this.preparedDevices);
    await this.resolveAgentFor(deviceId, '');
  }

  /** 在工作区面板里选了另一台设备（还没选工作区）。 */
  async selectPreparedDevice(deviceId: string): Promise<void> {
    await this.resolveAgentFor(deviceId, '');
  }

  /** 在工作区面板里选了一个工作区（可能属于另一台设备）。 */
  async selectPreparedWorkspace(projectId: string): Promise<void> {
    const project = this.projectOf(projectId);
    if (project === undefined) {
      return;
    }
    const draft = this.prepared;
    if (draft === undefined || draft.connectorId !== project.connectorId) {
      // 换设备 ⇒ Agent 与目录都要重解析，工作区作为「优先项」带过去。
      await this.resolveAgentFor(project.connectorId, project.id);
      return;
    }
    draft.projectId = project.id;
    draft.projectName = project.name;
    draft.cwd = project.workspacePath;
    this.prepared = draft;
    this.notify();
  }

  /** Agent 预设（DSH）：草稿态是**本地选择**，随创建请求的 `runtimeOptions` 一起发出去。 */
  setPreparedPreset(value: string): void {
    if (!presetStillSelectable(this.preparedPresetOptions, value)) {
      return;
    }
    this.preparedPreset = value;
    this.notice = '已选择 Agent 预设（发第一条消息时生效）。';
    this.notify();
  }

  /**
   * 草稿态：暂存一个**本地**附件。
   *
   * ⚠️ 这里**不调** `POST /sessions/{id}/attachments` —— 那条链要先有 sessionId，
   * 草稿态会话还不存在；字节在创建会话那一刻才被读出来编码成内联附件。
   */
  addPreparedAttachment(attachment: LocalAttachment): void {
    this.preparedAttachments = this.preparedAttachments.concat([attachment]);
    this.notify();
  }

  /** 草稿态：清空本地附件（输入卡上的「清空」）。 */
  clearPreparedAttachments(): void {
    if (this.preparedAttachments.length === 0) {
      return;
    }
    this.preparedAttachments = [];
    this.notify();
  }

  /** 离开草稿页（没有创建会话）：清干净，免得下一次进真会话时看到草稿的残留。 */
  cancelPrepared(): void {
    if (this.prepared === undefined) {
      return;
    }
    this.preparedAttachments = [];
    this.preparedAttachmentsAllowed = false;
    this.resetState('');
    this.notify();
  }

  /** 草稿态的窄快照（页面 build 只读这些，不直接读 dashboard）。 */
  private syncPreparedInventory(): void {
    const dashboard = DashboardStore.get();
    const devices: NewChatDevice[] = [];
    for (let i = 0; i < dashboard.devices.length; i++) {
      const device: AgentDevice = dashboard.devices[i];
      devices.push({ id: device.id, name: device.name, online: device.online });
    }
    const projects: NewChatProject[] = [];
    for (let i = 0; i < dashboard.projects.length; i++) {
      const project: AgentProject = dashboard.projects[i];
      projects.push({
        id: project.id,
        connectorId: project.connectorId,
        name: project.name,
        workspacePath: project.workspacePath,
        pinned: project.pinned
      });
    }
    const sessions: NewChatSession[] = [];
    for (let i = 0; i < dashboard.activeSessions.length; i++) {
      const session: AgentSession = dashboard.activeSessions[i];
      sessions.push({
        id: session.id,
        connectorId: session.connectorId,
        projectId: session.projectId !== undefined ? session.projectId : '',
        cwd: session.cwd !== undefined ? session.cwd : '',
        sortKey: session.sortKey
      });
    }
    this.preparedDevices = devices;
    this.preparedProjects = projects;
    this.preparedSessions = sessions;
  }

  private async resolveAgentFor(deviceId: string, preferredProjectId: string): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    this.preparedKind = DraftSetupKind.LOADING;
    this.loading = true;
    this.notify();
    try {
      const response = await AppServices.get().devices.listDeviceRuntimes(serverUrl, token, deviceId);
      const narrow: NewChatRuntime[] = [];
      let ready = 0;
      let settling = false;
      let reason = '';
      for (let i = 0; i < response.runtimes.length; i++) {
        const runtime = response.runtimes[i];
        narrow.push({
          runtimeId: runtime.runtimeId,
          runtimeType: runtime.runtimeType,
          displayName: deviceRuntimeLabel(runtime.displayName, runtime.runtimeType),
          configured: runtime.configured,
          active: runtime.active,
          status: runtime.status
        });
        if (gatingRuntimeIsReady(runtime.configured, runtime.active, runtime.status)) {
          ready += 1;
        }
        if (gatingRuntimeIsSettling(runtime.active, runtime.status)) {
          settling = true;
          if (reason.length === 0) {
            const errorMessage = runtime.error !== undefined && typeof runtime.error['message'] === 'string'
              ? runtime.error['message'] as string : '';
            const errorCode = runtime.error !== undefined && typeof runtime.error['code'] === 'string'
              ? runtime.error['code'] as string : '';
            const discoveryReason = runtime.discovery !== undefined && typeof runtime.discovery['reason'] === 'string'
              ? runtime.discovery['reason'] as string : '';
            reason = gatingRuntimeReasonText(errorMessage, errorCode, discoveryReason);
          }
        }
      }
      this.preparedRuntimeDtos = response.runtimes.slice();
      const inventory: NewChatInventory = {
        deviceCount: this.preparedDevices.length,
        loadingRuntimes: false,
        runtimeCount: narrow.length,
        readyRuntimeCount: ready,
        settling: settling,
        projectCount: projectsForDevice(deviceId, this.preparedProjects).length
      };
      const kind = draftSetupKind(inventory);
      if (kind !== DraftSetupKind.READY) {
        this.prepared = undefined;
        this.preparedReason = reason;
        this.finishPrepared(kind);
        return false;
      }
      const runtimeId = pickDraftRuntime(this.preferenceEntry(), deviceId, narrow);
      const runtime = this.runtimeDtoOf(runtimeId);
      const preferred = preferredProjectId.length > 0 ? preferredProjectId : this.preferredProjectId();
      const projectId = pickDraftProject(deviceId, preferred, this.preparedProjects, this.preparedSessions);
      const project = this.projectOf(projectId);
      if (runtime === undefined || project === undefined) {
        this.prepared = undefined;
        this.finishPrepared(DraftSetupKind.NO_PROJECT);
        return false;
      }
      const deviceName = this.deviceNameOf(deviceId);
      const draft: PreparedChatDraft = {
        connectorId: deviceId,
        deviceName: deviceName,
        runtimeId: runtime.runtimeId,
        runtimeType: runtime.runtimeType,
        runtimeName: deviceRuntimeLabel(runtime.displayName, runtime.runtimeType),
        projectId: project.id,
        projectName: project.name,
        cwd: project.workspacePath,
        localSessionId: 'local:new-session:' + newClientMessageId()
      };
      this.prepared = draft;
      this.sessionId = draft.localSessionId;
      this.session = this.previewSession(draft, deviceId);
      this.preparedPresetOptions = agentPresetOptions(runtime);
      await this.loadPreparedCatalogs(runtime);
      // R54：服务端 runtime 行里的 `uiSchema` / 能力是**上一次发现**的快照。DSH 的预设目录
      // （`catalog.listAgentPresets`）与 `runtime.attachment` 能力都来自那次发现 —— 若快照是
      // 「插件还没起来」时写的，用户就会看到「这个 Connector 没有上报 Agent 预设目录」并永远
      // 选不到预设。这里补一次**实时发现**（`POST /connectors/{id}/runtimes/discover`，上游
      // Android 的 DevicesApi.kt:112 也在用同一个端点），每张草稿最多补一次。
      if (runtime.runtimeType === 'dsh'
        && (this.preparedPresetOptions.length === 0 || !this.preparedAttachmentsAllowed)) {
        const refreshed = await this.refreshPreparedInventory(deviceId);
        const fresh = refreshed ? this.runtimeDtoOf(runtimeId) : undefined;
        if (fresh !== undefined) {
          this.preparedPresetOptions = agentPresetOptions(fresh);
          await this.loadPreparedCatalogs(fresh);
        }
      }
      this.finishPrepared(DraftSetupKind.READY);
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.prepared = undefined;
      this.finishPrepared(DraftSetupKind.NO_RUNTIME);
      return false;
    }
  }

  /**
   * 草稿态的「预览会话」（上游 `NewSessionDraft.previewSession()`）。
   *
   * `takeover = true` + `connectorOnline = true` 是刻意的：草稿态**没有**服务端会话可接管，
   * 而输入区必须先能用（否则用户看到的是「只读模式」这句毫无意义的提示）。
   */
  private previewSession(draft: PreparedChatDraft, deviceId: string): AgentSession {
    const remote: RemoteSession = {
      id: draft.localSessionId,
      connectorId: deviceId,
      projectId: draft.projectId,
      connectorStatus: 'online',
      runtime: draft.runtimeType,
      title: '',
      cwd: draft.cwd,
      status: 'idle',
      takeover: true,
      pinned: false,
      archived: false,
      unread: false,
      lastReadSeq: 0,
      updatedSeq: 0,
      runtimeId: draft.runtimeId,
      runtimeType: draft.runtimeType,
      runtimeName: draft.runtimeName
    };
    return toAgentSession(remote, draft.deviceName);
  }

  /**
   * R54：补一次**实时发现**，把服务端那份「上次发现」的快照刷新掉。
   *
   * 为什么需要：`uiSchema`（DSH 预设目录）与运行时的能力表都是**发现时刻**的产物 ——
   * 连接器执行 `runtime.discover` 时会向 bridge 要 `catalog.listAgentPresets` 与
   * `runtime.getCapabilities`（`connector/connector/runtimes/dsh/discovery.py:102-107`），
   * 失败就**静默跳过**（老插件/插件没起来）；服务端把那次结果落库后，客户端只能看到空目录。
   * 上游客户端就是靠 `POST /connectors/{id}/runtimes/discover` 这个端点手动刷新的
   * （Android `api/DevicesApi.kt:112`）。
   *
   * 约束：每张草稿**最多一次**（`preparedDiscoveryDone`），且失败不抛 —— 目录空不该让新对话进不去。
   */
  private async refreshPreparedInventory(deviceId: string): Promise<boolean> {
    if (this.preparedDiscoveryDone) {
      return false;
    }
    this.preparedDiscoveryDone = true;
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      return false;
    }
    try {
      const list = await AppServices.get().devices.discoverDeviceRuntimes(serverUrl, token, deviceId);
      if (list.runtimes.length === 0) {
        return false;
      }
      this.preparedRuntimeDtos = list.runtimes.slice();
      return true;
    } catch (error) {
      // 发现失败（连接器离线 / 桥没起来）不是致命错：目录保持空态，由页面如实说明。
      return false;
    }
  }

  /**
   * 草稿态的目录：走**连接器级**的 `/connectors/{id}/runtimes/{rid}/catalogs/*`
   * （会话级那个端点要 sessionId，草稿态还没有）。
   *
   * 选中项口径与旧表单页一致：记忆打底（仍在且可用才用）→ 目录里标 default 的 → 第一个可用项。
   */
  private async loadPreparedCatalogs(runtime: RemoteDeviceRuntime): Promise<void> {
    const draft = this.prepared;
    if (draft === undefined) {
      return;
    }
    this.modelCatalog = undefined;
    this.permissionCatalog = undefined;
    // R54：能力表同样是「上次发现」的快照 ⇒ 取不到时按**不可用**处理（宁可不给入口，
    // 也不要让用户选完文件、发出去才收到 409 runtime capability is unavailable）。
    this.preparedAttachmentsAllowed = false;
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    const remembered: NewSessionPreferenceEntry | undefined = this.preferenceEntry();
    const selection = restoreSelection(remembered, draft.connectorId, draft.runtimeId);
    this.preparedPreset = selection !== undefined && selection.agentPresetId.length > 0
      && presetStillSelectable(this.preparedPresetOptions, selection.agentPresetId)
      ? selection.agentPresetId : defaultAgentPreset(runtime);
    const selections: Record<string, string> = {};
    try {
      const capabilities = await AppServices.get().devices.getDeviceRuntimeCapabilities(
        serverUrl, token, draft.connectorId, draft.runtimeId);
      this.preparedAttachmentsAllowed = capabilityUsable(
        capabilities.capabilitySet, RUNTIME_ATTACHMENT_CAPABILITY);
      if (capabilityUsable(capabilities.capabilitySet, RUNTIME_MODEL_CAPABILITY)) {
        const response = await AppServices.get().devices.getDeviceRuntimeModelCatalog(
          serverUrl, token, draft.connectorId, draft.runtimeId);
        this.modelCatalog = response.catalog;
        let restored = '';
        if (selection !== undefined && selection.modelId.length > 0) {
          restored = modelSelectionIdFor(response.catalog.models, selection.modelId, selection.reasoningId);
        }
        const options = modelSelectionOptions(response.catalog);
        const chosen = this.selectableOr(options, restored, true);
        if (chosen.length > 0) {
          selections[RUNTIME_MODEL_KEY] = chosen;
        }
      }
      if (capabilityUsable(capabilities.capabilitySet, RUNTIME_PERMISSION_CAPABILITY)) {
        const response = await AppServices.get().devices.getDeviceRuntimePermissionCatalog(
          serverUrl, token, draft.connectorId, draft.runtimeId);
        this.permissionCatalog = response.catalog;
        let restored = '';
        if (selection !== undefined && selection.permissionId.length > 0) {
          restored = permissionSelectionIdFor(response.catalog.permissions, selection.permissionId);
        }
        const options = permissionSelectionOptions(response.catalog);
        const chosen = this.selectableOr(options, restored, false);
        if (chosen.length > 0) {
          selections[RUNTIME_PERMISSION_KEY] = chosen;
        }
      }
    } catch (error) {
      // 目录拉不到不是错误：面板会显示空态，创建时用服务端默认值。
    }
    const state: RemoteSessionRuntimeState = {
      sessionId: draft.localSessionId,
      runtime: draft.runtimeType,
      status: 'idle',
      selections: selections,
      updatedSeq: 0,
      runtimeId: draft.runtimeId,
      runtimeType: draft.runtimeType,
      runtimeName: draft.runtimeName
    };
    this.runtimeState = state;
  }

  /** 记忆里的候选值可用就用它，否则取目录默认项（default 优先）。 */
  private selectableOr(options: RuntimeSelectionOption[], restored: string, preferDefault: boolean): string {
    if (restored.length > 0) {
      for (let i = 0; i < options.length; i++) {
        if (options[i].selectionId === restored && options[i].enabled) {
          return restored;
        }
      }
    }
    if (preferDefault) {
      for (let i = 0; i < options.length; i++) {
        if (options[i].isDefault && options[i].enabled) {
          return options[i].selectionId;
        }
      }
    }
    for (let i = 0; i < options.length; i++) {
      if (options[i].enabled) {
        return options[i].selectionId;
      }
    }
    return '';
  }

  /** 记忆作用域里的「上次设备」→ 该设备上最近一条会话所在的工作区。 */
  private preferredProjectId(): string {
    const lastSessionId = AppStorage.get<string>(LAST_SESSION_KEY);
    return projectIdOfSession(this.preparedSessions, lastSessionId !== undefined ? lastSessionId : '');
  }

  private preferenceEntry(): NewSessionPreferenceEntry | undefined {
    const raw = AppStorage.get<string>(NEW_SESSION_PREF_KEY);
    const book = decodePreferenceBook(raw !== undefined ? raw : '');
    const account = newSessionAccountKey(readServerUrl(), readUserId());
    return readPreferenceEntry(book, account);
  }

  /** 把用户显式选的三项写回 R47 记忆（草稿态创建成功时调一次）。 */
  private rememberPreparedSelection(draft: PreparedChatDraft,
    selections: Record<string, string>): void {
    if (this.permissionCatalog === undefined && this.modelCatalog === undefined) {
      return;
    }
    const modelSelection = selections[RUNTIME_MODEL_KEY] !== undefined ? selections[RUNTIME_MODEL_KEY] : '';
    const target = this.modelCatalog !== undefined
      ? modelSelectionTargetOf(this.modelCatalog.models, modelSelection) : undefined;
    let permissionId = '';
    if (this.permissionCatalog !== undefined) {
      const permissionSelection = selections[RUNTIME_PERMISSION_KEY] !== undefined
        ? selections[RUNTIME_PERMISSION_KEY] : '';
      for (let i = 0; i < this.permissionCatalog.permissions.length; i++) {
        const permission = this.permissionCatalog.permissions[i];
        if (permission.selectionId.trim() === permissionSelection) {
          permissionId = permission.id;
          break;
        }
      }
    }
    writeNewSessionSelection(draft.connectorId, draft.runtimeId, {
      modelId: target !== undefined ? target.modelId : '',
      reasoningId: target !== undefined ? target.reasoningId : '',
      permissionId: permissionId,
      agentPresetId: this.preparedPreset
    });
  }

  private finishPrepared(kind: string): void {
    this.preparedKind = kind;
    this.loading = false;
    this.notify();
  }

  private deviceNameOf(deviceId: string): string {
    for (let i = 0; i < this.preparedDevices.length; i++) {
      if (this.preparedDevices[i].id === deviceId) {
        return this.preparedDevices[i].name;
      }
    }
    return '';
  }

  private projectOf(projectId: string): NewChatProject | undefined {
    for (let i = 0; i < this.preparedProjects.length; i++) {
      if (this.preparedProjects[i].id === projectId) {
        return this.preparedProjects[i];
      }
    }
    return undefined;
  }

  private runtimeDtoOf(runtimeId: string): RemoteDeviceRuntime | undefined {
    // 草稿态只需要 runtime 描述里的几个字段；列表在 `resolveAgentFor` 里拿过，这里按 id 找回来。
    for (let i = 0; i < this.preparedRuntimeDtos.length; i++) {
      if (this.preparedRuntimeDtos[i].runtimeId === runtimeId) {
        return this.preparedRuntimeDtos[i];
      }
    }
    return undefined;
  }

  /**
   * **首条消息**：这一刻才真正创建服务端会话（`create-and-start`）。
   *
   * 成功后把服务端 id 放进 `createdSessionId`，页面据此 `Router.replace` 到真会话；
   * 失败时**保留草稿**（页面把消息还给输入框），并给出服务端原话。
   */
  private async createPreparedSession(content: string,
    attachments: RemoteInlineAttachmentRef[]): Promise<boolean> {
    const draft = this.prepared;
    if (draft === undefined) {
      return false;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    this.sending = true;
    this.error = '';
    this.notify();
    // ⚠️ 不能写成「三元 + 空对象字面量」：ArkTS 的 arkts-no-untyped-obj-literals 不认
    // 无上下文的 {}（分层写法与 SessionsApi 里那几处同款）。
    const state = this.runtimeState;
    let current: Record<string, string> = {};
    if (state !== undefined && state.selections !== undefined) {
      current = state.selections;
    }
    const selections: Record<string, string> = {};
    const model = current[RUNTIME_MODEL_KEY];
    const permission = current[RUNTIME_PERMISSION_KEY];
    if (model !== undefined && model.length > 0) {
      selections[RUNTIME_MODEL_KEY] = model;
    }
    if (permission !== undefined && permission.length > 0) {
      selections[RUNTIME_PERMISSION_KEY] = permission;
    }
    const request: RemoteSessionCreateAndStartRequest = {
      connectorId: draft.connectorId,
      projectId: draft.projectId,
      runtimeType: draft.runtimeType,
      runtimeId: draft.runtimeId,
      cwd: draft.cwd,
      content: content,
      selections: selections,
      runtimeOptions: runtimeOptionsForPreset(this.preparedPreset),
      // R54：草稿态的附件只能走**内联**（base64 随创建请求一起发）—— 已上传那条链要 sessionId。
      attachments: attachments,
      // DSH 运行时**硬性要求**稳定的 clientMessageId（缺了就是 502）。
      clientMessageId: newClientMessageId()
    };
    // R54：**只有附件、没有正文**时，服务端推不出标题 —— 它取的是首条**用户消息的文本**
    // （`server/agent_server/infra/repositories/sessions.py:1829-1848`），文本为空就没有标题，
    // DSH 侧会把外部会话 id 当标题回传（真机实测标题是 `aa_9e9011cbb9b97bf5_sess_…`）。
    // 这里用**附件名**兜一个，用户至少能认出这条会话是什么。
    if (content.length === 0 && attachments.length > 0) {
      request.title = attachments[0].name;
    }
    try {
      const created = await AppServices.get().sessions.createAndStartSession(serverUrl, token, request);
      const sessionId = created.session.id;
      if (sessionId.length === 0) {
        throw new Error('服务端没有返回会话 id。');
      }
      this.rememberPreparedSelection(draft, selections);
      this.createdSessionId = sessionId;
      this.prepared = undefined;
      this.sending = false;
      this.notify();
      return true;
    } catch (error) {
      this.sending = false;
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  private mapSession(remote: RemoteSession): AgentSession {
    const device = DashboardStore.get().deviceById(remote.connectorId);
    return toAgentSession(remote, device !== undefined ? device.name : undefined);
  }

  async refreshRuntimeState(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || this.sessionId.length === 0) {
      return;
    }
    try {
      const services = AppServices.get();
      const response = await services.sessions.getSessionRuntimeState(serverUrl, token, this.sessionId);
      this.runtimeState = response.state;
      const capabilitiesRaw = await services.sessions.getSessionRuntimeCapabilities(serverUrl, token, this.sessionId);
      this.capabilities = parseCapabilitySet(
        (capabilitiesRaw['capabilitySet'] !== undefined ? capabilitiesRaw['capabilitySet'] : emptyRaw()) as Record<string, Object>);
      const noticesResponse = await services.sessions.getSessionRuntimeNotices(serverUrl, token, this.sessionId);
      this.notices = noticesResponse.notices;
      this.notify();
    } catch (error) {
      // 运行时状态非关键路径，失败不阻塞
    }
  }

  /** 能力是否可用于当前会话（决定按钮是否可点）。 */
  can(capabilityId: string): boolean {
    return capabilityUsable(this.capabilities, capabilityId);
  }

  /**
   * 会话是否处于**只读态**（尚未接管）。
   *
   * 这是上游 composer 的第一道闸（`SessionDetailScreen.kt` L1333 `takeoverEnabled`）：
   * 服务端对未接管的会话一律 409（`session_run.py` L397「session is read-only until
   * takeover is enabled」），messages / steer / selections 三处都拦。客户端不提前门控，
   * 用户就会「输入了、点了发送、只收到一句英文报错」——正是本轮要修的缺陷。
   *
   * 判定逻辑在 `model/SessionGating.ets`（纯函数，已进 Node 单测）。
   */
  isReadOnly(): boolean {
    const session = this.session;
    return gatingIsReadOnly(session !== undefined, session !== undefined && session.takeover);
  }

  /**
   * 运行时当前能接受的发送动作（上游 `messageAction` 的等价物）。
   * 供 UI 决定占位文案与按钮是否可点，也供 `send()` 选端点。
   */
  messageAction(): string {
    const session = this.session;
    const runtime = this.runtimeState;
    return messageActionFor(
      session !== undefined,
      session !== undefined && session.takeover,
      this.capabilities.capabilities,
      runtime !== undefined ? runtime.status : '',
      session !== undefined ? session.status : '');
  }

  /**
   * 有效运行时状态：**优先**取 runtime state，未知时回落到会话状态。
   * 对应上游 `effectiveRuntimeStatus()`（`SessionDetailScreen.kt` L1856-1868）。
   */
  effectiveRuntimeStatus(): string {
    const runtime = this.runtimeState;
    const session = this.session;
    return gatingEffectiveStatus(
      runtime !== undefined ? runtime.status : '',
      session !== undefined ? session.status : '');
  }

  async loadCommands(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || this.sessionId.length === 0) {
      return;
    }
    try {
      const response = await AppServices.get().sessions.getSessionRuntimeCommands(
        serverUrl, token, this.sessionId);
      this.commands = response.commands;
      this.notify();
    } catch (error) {
      this.commands = [];
    }
  }

  async loadMoreHistory(): Promise<void> {
    if (!this.hasMoreHistory || this.items.length === 0) {
      return;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    const firstOrderSeq = this.items[0].orderSeq;
    try {
      const page = await AppServices.get().sessions.getSessionTimelineHistory(
        serverUrl, token, this.sessionId, firstOrderSeq, 100);
      this.items = mergeTimelineItems(this.items, page.items, false);
      this.view.setItems(this.items);
      this.messages = this.view.messages();
      this.optimisticCount = this.view.optimisticCount();
      this.hasMoreHistory = page.hasMore;
      this.notify();
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
    }
  }

  // -------------------------------------------------------------------------
  // 发送 / 控制
  // -------------------------------------------------------------------------

  /**
   * 发送消息：按能力与运行状态选 `steer` 或 `messages`（见 `messageAction`）。
   *
   * `inlineAttachments` 只在**草稿态**有意义（R54）：首条消息的附件必须随 `create-and-start`
   * 内联发出（base64），因为那时还没有 sessionId 可挂已上传的附件。
   */
  async send(content: string, attachments: string[] = [],
    inlineAttachments: RemoteInlineAttachmentRef[] = []): Promise<boolean> {
    if (content.trim().length === 0 && attachments.length === 0 && inlineAttachments.length === 0) {
      return false;
    }
    // R53：草稿态 ⇒ 这条消息就是**首条消息**，它负责把服务端会话建出来（见 createPreparedSession）。
    if (this.prepared !== undefined) {
      // 连接器允许「只有附件、没有正文」的首条消息（`connector/.../dsh/runtime.py:327`
      // 判的是 `not content.strip() and not attachments`），所以正文可以为空。
      if (content.trim().length === 0 && inlineAttachments.length === 0) {
        return false;
      }
      if (inlineAttachments.length > 0 && !this.preparedAttachmentsAllowed) {
        this.error = inlineAttachmentUnavailableText();
        this.notify();
        return false;
      }
      return this.createPreparedSession(content.trim(), inlineAttachments);
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0) {
      this.error = '未登录。';
      this.notify();
      return false;
    }
    // ⚠️ 本地先拦只读态：服务端对未接管会话一律 409，放行过去只会让用户
    // 收到一句英文报错（真机实测的原话是 "session is read-only until takeover is enabled"），
    // 既看不懂也不知道该做什么。这里给出可操作的中文指引。
    if (this.isReadOnly()) {
      this.error = '这个会话是只读的：需要先「接管此会话」才能发送消息。';
      this.notify();
      return false;
    }
    const action = this.messageAction();
    if (action === MessageAction.NONE) {
      this.error = '运行时当前无法接收消息（发送能力不可用）。';
      this.notify();
      return false;
    }
    const clientMessageId = newClientMessageId();
    this.sending = true;
    this.error = '';
    this.appendOptimistic(clientMessageId, content, attachments);
    this.notify();

    const refs: RemoteAttachmentRef[] = attachments.map((fileId: string): RemoteAttachmentRef => {
      const ref: RemoteAttachmentRef = { fileId: fileId };
      return ref;
    });
    try {
      const services = AppServices.get();
      const response = action === MessageAction.STEER
        ? await services.sessions.steerSession(serverUrl, token, this.sessionId, content, clientMessageId, refs)
        : await services.sessions.sendSessionMessage(serverUrl, token, this.sessionId, content, clientMessageId, refs);
      if (!response.ok) {
        const message = response.error !== undefined && response.error.message !== undefined
          ? response.error.message : '发送失败';
        throw new Error(message);
      }
      this.sending = false;
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.removeOptimistic(clientMessageId);
      this.sending = false;
      this.notify();
      return false;
    }
  }

  /**
   * 追加一条本地乐观消息。
   *
   * R42：消息构造搬到 `feature/TimelineView.ets`（纯逻辑、可进 Node 断言），这里只同步 store 的对外字段；
   * 同时**不再复制整个 messages 数组**（原来这里是 `this.messages.concat([message])`）。
   */
  private appendOptimistic(clientMessageId: string, content: string, attachments: string[]): void {
    this.view.addOptimistic(
      buildOptimisticMessage(clientMessageId, content, attachments, new Date().toISOString()));
    this.messages = this.view.messages();
    this.optimisticCount = this.view.optimisticCount();
  }

  /** 撤回乐观消息（发送失败）。同上：只动视图里的乐观层，不复制整个 messages。 */
  private removeOptimistic(clientMessageId: string): void {
    this.view.removeOptimistic(clientMessageId);
    this.messages = this.view.messages();
    this.optimisticCount = this.view.optimisticCount();
  }

  async interrupt(): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    this.error = '';
    try {
      const response = await AppServices.get().sessions.interruptSession(serverUrl, token, this.sessionId);
      if (!response.ok) {
        this.error = response.error !== undefined && response.error.message !== undefined
          ? response.error.message : '中断失败';
        this.notify();
        return false;
      }
      this.notice = '已发送中断。';
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  async setTakeover(enabled: boolean): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const remote = enabled
        ? await AppServices.get().sessions.enableTakeover(serverUrl, token, this.sessionId)
        : await AppServices.get().sessions.disableTakeover(serverUrl, token, this.sessionId);
      this.session = this.mapSession(remote);
      // R37：**释放接管不再弹提示**（用户反馈：对话区那行「已释放接管。」多余 ——
      // 状态本身由上方功能栏与输入区的「接管」开关体现，不必再占一行对话区文案）。
      // 「已接管该会话。」保留：那是进入可写模式的确认，与「能发消息了」直接相关。
      this.notice = enabled ? '已接管该会话。' : '';
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  async setSelections(selections: Record<string, string>): Promise<boolean> {
    // R53：草稿态没有服务端会话可打（打过去就是 session not found）——选型先落在**本地**，
    // 由 create-and-start 随首条消息一起提交（上游同一处也是 `preparedSelections` 的本地态）。
    if (this.prepared !== undefined) {
      this.applyPreparedSelections(selections);
      this.notice = '已选择（发第一条消息时生效）。';
      this.error = '';
      this.notify();
      return true;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const response = await AppServices.get().sessions.patchSessionRuntimeSelections(
        serverUrl, token, this.sessionId, selections);
      if (response.state !== undefined) {
        this.runtimeState = response.state;
      }
      this.notice = response.ok ? '运行时选型已更新。' : '运行时选型更新未生效。';
      this.notify();
      return response.ok;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }


  /**
   * 草稿态的选型落地：只改本地的 `runtimeState.selections`（界面照常回显），不发任何请求。
   *
   * ⚠️ 必须**换一份新对象**再赋给 `runtimeState`：@State 对同一引用的原地修改不触发重绘
   * （本工程在 `noticeInputs` / `attachmentUris` 上踩过同一个坑）。
   */
  private applyPreparedSelections(incoming: Record<string, string>): void {
    const state = this.runtimeState;
    const next: Record<string, string> = {};
    if (state !== undefined && state.selections !== undefined) {
      const keys = Object.keys(state.selections);
      for (let i = 0; i < keys.length; i++) {
        next[keys[i]] = state.selections[keys[i]];
      }
    }
    const incomingKeys = Object.keys(incoming);
    for (let i = 0; i < incomingKeys.length; i++) {
      next[incomingKeys[i]] = incoming[incomingKeys[i]];
    }
    const draft = this.prepared;
    const updated: RemoteSessionRuntimeState = {
      sessionId: draft !== undefined ? draft.localSessionId : this.sessionId,
      runtime: draft !== undefined ? draft.runtimeType : '',
      status: state !== undefined ? state.status : 'idle',
      selections: next,
      updatedSeq: state !== undefined ? state.updatedSeq : 0,
      runtimeId: draft !== undefined ? draft.runtimeId : '',
      runtimeType: draft !== undefined ? draft.runtimeType : '',
      runtimeName: draft !== undefined ? draft.runtimeName : ''
    };
    this.runtimeState = updated;
  }

  /** 响应审批/输入请求（`/runtime/notices/{id}/respond`）。 */
  async respondNotice(noticeId: string, actionId: string, input?: Record<string, Object>): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    this.error = '';
    try {
      const response = await AppServices.get().sessions.respondRuntimeNotice(
        serverUrl, token, this.sessionId, noticeId, actionId, input);
      if (!response.ok) {
        this.error = response.error !== undefined && response.error.message !== undefined
          ? response.error.message : '提交失败';
        this.notify();
        return false;
      }
      this.notices = this.notices.filter((notice: RemoteRuntimeNotice) => notice.noticeId !== noticeId);
      this.notice = '已提交。';
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  async executeCommand(command: string, args: string[] = []): Promise<string> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const response = await AppServices.get().sessions.executeSessionRuntimeCommand(
        serverUrl, token, this.sessionId, command, args);
      if (response.session !== undefined) {
        this.session = this.mapSession(response.session);
        this.notify();
      }
      return response.ok ? (response.message !== undefined ? response.message : '命令已执行') :
        (response.message !== undefined ? response.message : '命令失败');
    } catch (error) {
      return error instanceof Error ? (error as Error).message : String(error);
    }
  }

  async loadModelCatalog(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const response = await AppServices.get().sessions.getSessionRuntimeModelCatalog(
        serverUrl, token, this.sessionId);
      this.modelCatalog = response.catalog;
      this.notify();
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
    }
  }

  async loadPermissionCatalog(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const response = await AppServices.get().sessions.getSessionRuntimePermissionCatalog(
        serverUrl, token, this.sessionId);
      this.permissionCatalog = response.catalog;
      this.notify();
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
    }
  }

  /** 未读清零（进入会话时调用）。 */
  async markRead(): Promise<void> {
    await DashboardStore.get().markSessionRead(this.sessionId);
  }

  // -------------------------------------------------------------------------
  // 实时通道
  // -------------------------------------------------------------------------

  startRealtime(): void {
    if (this.subscribed || this.sessionId.length === 0) {
      return;
    }
    this.subscribed = true;
    this.connectRealtime();
  }

  stopRealtime(): void {
    this.subscribed = false;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.flushBatch();
    const socket = this.socket;
    this.socket = undefined;
    if (socket !== undefined) {
      socket.close();
    }
    this.connection = ConnectionState.IDLE;
  }

  private async connectRealtime(): Promise<void> {
    if (!this.subscribed) {
      return;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      this.subscribed = false;
      return;
    }
    this.connection = ConnectionState.CONNECTING;
    this.notify();
    const services = AppServices.get();
    const sessionId = this.sessionId;
    try {
      const ticket = await services.realtime.createSessionTicket(
        serverUrl, token, services.realtimeClientId, sessionId);
      if (!this.subscribed || this.sessionId !== sessionId) {
        return;
      }
      const url = services.realtime.sessionWebSocketUrl(serverUrl, sessionId, ticket.ticket);
      const handlers: SocketHandlers = {
        onOpen: () => {
          this.connection = ConnectionState.CONNECTED;
          this.reconnectAttempt = 0;
          this.notify();
        },
        onText: (text: string) => {
          this.handleWireMessage(text);
        },
        onBinary: (data: ArrayBuffer) => {
        },
        onClosed: () => {
          this.connection = ConnectionState.OFFLINE;
          this.notify();
          this.scheduleReconnect();
        },
        onError: (message: string) => {
          this.connection = ConnectionState.OFFLINE;
          this.notify();
          this.scheduleReconnect();
        }
      };
      this.socket = services.realtime.openWebSocket(url, handlers);
    } catch (error) {
      this.connection = ConnectionState.OFFLINE;
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (!this.subscribed) {
      return;
    }
    const delay = reconnectDelayMillis(this.reconnectAttempt, Math.random());
    this.reconnectAttempt = this.reconnectAttempt < 30 ? this.reconnectAttempt + 1 : 30;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connectRealtime();
    }, delay);
  }

  private handleWireMessage(text: string): void {
    const services = AppServices.get();
    const event = services.realtime.parseSessionMessage(text);
    if (event === undefined) {
      return;
    }
    if (event.type === SessionEventType.SUBSCRIBED) {
      // 首订阅：做一次游标恢复 + 运行时刷新
      this.recoverFrom(this.cursor);
      this.refreshRuntimeState();
      return;
    }
    if (event.type === SessionEventType.SESSION_REFETCH_REQUIRED) {
      if (this.lastSnapshotRequiredCursor !== this.cursor) {
        this.lastSnapshotRequiredCursor = this.cursor;
        this.reloadSnapshot();
      }
      return;
    }
    if (event.type === SessionEventType.RUNTIME_REFETCH_REQUIRED) {
      this.refreshRuntimeState();
      return;
    }
    this.enqueueEvent(event.type, event.payload);
  }

  private enqueueEvent(type: string, payload: RemoteSessionEventPayload | undefined): void {
    this.eventBatch.push(type);
    if (payload !== undefined) {
      if (payload.item !== undefined) {
        this.batchBuffer.push(payload.item);
      }
      if (payload.items !== undefined) {
        for (let i = 0; i < payload.items.length; i++) {
          this.batchBuffer.push(payload.items[i]);
        }
      }
      if (payload.session !== undefined) {
        this.session = this.mapSession(payload.session);
      }
      if (payload.state !== undefined) {
        this.runtimeState = payload.state;
      }
      if (payload.notice !== undefined) {
        this.upsertNotice(payload.notice);
      }
      if (payload.notices !== undefined) {
        for (let i = 0; i < payload.notices.length; i++) {
          this.upsertNotice(payload.notices[i]);
        }
      }
      if (payload.capabilitySet !== undefined) {
        this.capabilities = payload.capabilitySet;
      }
      if (payload.eventCursor !== undefined) {
        this.cursor = payload.eventCursor;
      }
      if (payload.catalogType === 'model' && payload.catalog !== undefined) {
        this.modelCatalog = parseModelCatalog(payload.catalog);
      }
      if (payload.catalogType === 'permission' && payload.catalog !== undefined) {
        this.permissionCatalog = parsePermissionCatalog(payload.catalog);
      }
    }
    if (this.batchTimer < 0) {
      this.batchTimer = setTimeout(() => {
        this.batchTimer = -1;
        this.flushBatch();
      }, 34);
    }
  }

  private flushBatch(): void {
    if (this.batchBuffer.length === 0 && this.eventBatch.length === 0) {
      return;
    }
    if (this.batchBuffer.length > 0) {
      this.items = mergeTimelineItems(this.items, this.batchBuffer, false);
      this.batchBuffer = [];
      // 增量投影：只对新到 / 变化的 item 真正投影（仍会摘掉已被服务端回执的乐观消息）。
      this.view.setItems(this.items);
      this.messages = this.view.messages();
      this.optimisticCount = this.view.optimisticCount();
    }
    this.eventBatch = [];
    this.connection = this.connection === ConnectionState.RECOVERING
      ? ConnectionState.CONNECTED : this.connection;
    this.notify();
  }

  private upsertNotice(notice: RemoteRuntimeNotice): void {
    if (notice.status !== 'open') {
      this.notices = this.notices.filter((item: RemoteRuntimeNotice) => item.noticeId !== notice.noticeId);
      return;
    }
    let replaced = false;
    const next: RemoteRuntimeNotice[] = [];
    for (let i = 0; i < this.notices.length; i++) {
      const existing = this.notices[i];
      if (existing.noticeId === notice.noticeId) {
        next.push(notice);
        replaced = true;
      } else {
        next.push(existing);
      }
    }
    if (!replaced) {
      next.push(notice);
    }
    this.notices = next;
  }

  private async reloadSnapshot(): Promise<void> {
    await this.open(this.sessionId);
  }

  /** 游标恢复：最多 8 页，直到追上 nextCursor。 */
  private async recoverFrom(initialCursor: string): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    const sessionId = this.sessionId;
    this.connection = ConnectionState.RECOVERING;
    this.notify();
    let after = initialCursor;
    try {
      for (let page = 0; page < 8; page++) {
        const response = await AppServices.get().realtime.recoverSessionEvents(
          serverUrl, token, sessionId, after);
        if (!this.subscribed || this.sessionId !== sessionId) {
          return;
        }
        if (response.snapshotRequired) {
          await this.reloadSnapshot();
          return;
        }
        if (response.events.length > 0) {
          const items: RemoteTimelineItem[] = [];
          for (let i = 0; i < response.events.length; i++) {
            const event = response.events[i];
            if (event.payload !== undefined) {
              if (event.payload.item !== undefined) {
                items.push(event.payload.item);
              }
              if (event.payload.items !== undefined) {
                for (let j = 0; j < event.payload.items.length; j++) {
                  items.push(event.payload.items[j]);
                }
              }
              if (event.payload.session !== undefined) {
                this.session = this.mapSession(event.payload.session);
              }
              if (event.payload.state !== undefined) {
                this.runtimeState = event.payload.state;
              }
            }
          }
          if (items.length > 0) {
            this.items = mergeTimelineItems(this.items, items, false);
            this.view.setItems(this.items);
            this.messages = this.view.messages();
            this.optimisticCount = this.view.optimisticCount();
          }
        }
        const next = response.nextCursor;
        this.cursor = next;
        let lastSequence = 0;
        for (let i = 0; i < response.events.length; i++) {
          if (response.events[i].sequence > lastSequence) {
            lastSequence = response.events[i].sequence;
          }
        }
        if (next === after) {
          break;
        }
        after = next;
      }
      this.connection = ConnectionState.CONNECTED;
      this.notify();
    } catch (error) {
      this.connection = ConnectionState.OFFLINE;
      this.notify();
    }
  }

  /** 未处理的公告（阻塞式优先）。 */
  openNotices(): RemoteRuntimeNotice[] {
    return this.notices.filter((notice: RemoteRuntimeNotice) => notice.status === 'open');
  }
}
