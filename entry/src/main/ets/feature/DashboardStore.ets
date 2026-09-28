/**
 * 工作台状态（对应 Android `feature/sessions/SessionsController.kt` +
 * `feature/devices/DevicesController.kt` + `feature/realtime/DashboardRealtimeController.kt`）。
 *
 * 数据来源有两条：
 * 1. HTTP 首屏：`/connectors` + `/projects` + `/sessions?archived=`；
 * 2. WebSocket `/dashboard/ws`：连接即收到全量 `dashboard.snapshot`，
 *  之后每次 `dashboard.changed` 都会推一份新的全量快照（服务端做了去抖）。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl } from '../store/AuthSessionStore';
import {
  AgentDevice, AgentProject, AgentSession, compareProjects, compareSessions, toAgentProject, toAgentSession
} from '../model/AppModels';
import { RemoteDevice, RemoteProject, RemoteSession, RemoteSessionPage } from '../model/Types';
import {
  RealtimeSocket, SocketHandlers, reconnectDelayMillis
} from '../api/RealtimeApi';
import { RemoteDashboardSnapshot } from '../model/Types';
import {
  SessionPagingState, applyFirstPage, applyMorePage, applySnapshotPage, beginLoadMore,
  canLoadMore as pagingCanLoadMore, emptyPagingState, failLoadMore, idsOf, mergeSessionLists,
  mergeWithSnapshot, pageStateOf, shouldShowLoadMore as pagingShouldShowLoadMore
} from '../model/SessionPaging';

/** 会话列表每页条数（与上游 `listSessions(limit = 100)` 一致）。 */
const PAGE_SIZE: number = 100;

/** 分页游标是可选字段；内部统一用空串表示「没有下一页」。 */
function cursorOrEmpty(cursor: string | undefined): string {
  return cursor !== undefined ? cursor : '';
}

export type DashboardListener = () => void;

export class DashboardStore {
  private static instance?: DashboardStore;

  devices: AgentDevice[] = [];
  projects: AgentProject[] = [];
  activeSessions: AgentSession[] = [];
  archivedSessions: AgentSession[] = [];
  /** 两侧的翻页状态（游标 / 加载中 / 上次失败原因 / 首页 id 集合）。 */
  paging: SessionPagingState = emptyPagingState();
  loading: boolean = false;
  error: string = '';
  lastSyncedAt: string = '';
  realtimeConnected: boolean = false;

  private listeners: DashboardListener[] = [];
  private socket?: RealtimeSocket;
  private reconnectAttempt: number = 0;
  private reconnectTimer: number = -1;
  private subscribed: boolean = false;

  static get(): DashboardStore {
    if (DashboardStore.instance === undefined) {
      DashboardStore.instance = new DashboardStore();
    }
    return DashboardStore.instance;
  }

  onChange(listener: DashboardListener): void {
    this.listeners.push(listener);
  }

  offChange(listener: DashboardListener): void {
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
  // HTTP 首屏
  // -------------------------------------------------------------------------

  async refreshAll(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      return;
    }
    this.loading = true;
    this.error = '';
    this.notify();
    try {
      const services = AppServices.get();
      const devicesRaw = await services.devices.listDevices(serverUrl, token);
      const projectsRaw = await services.sessions.listProjects(serverUrl, token);
      // ⚠️ 必须用带分页信息的版本：只取首页时超过一页的会话永远翻不到。
      const activePage = await services.sessions.listSessionPage(serverUrl, token, false, PAGE_SIZE);
      const archivedPage = await services.sessions.listSessionPage(serverUrl, token, true, PAGE_SIZE);
      this.applySnapshot(devicesRaw, projectsRaw, activePage, archivedPage);
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.loading = false;
      this.lastSyncedAt = new Date().toISOString();
      this.notify();
    }
  }

  /** 只刷新设备列表（设备详情页改完名字后调用）。 */
  async refreshDevices(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      return;
    }
    const devicesRaw = await AppServices.get().devices.listDevices(serverUrl, token);
    this.devices = devicesRaw.map((device: RemoteDevice) => this.toAgentDevice(device));
    this.remapSessions();
    this.notify();
  }

  private toAgentDevice(remote: RemoteDevice): AgentDevice {
    const device: AgentDevice = {
      id: remote.id,
      name: remote.name,
      deviceOs: remote.deviceOs,
      online: remote.status === 'online',
      lastSeenAt: remote.lastSeenAt,
      createdAt: remote.createdAt
    };
    return device;
  }

  private applySnapshot(
    devicesRaw: RemoteDevice[], projectsRaw: RemoteProject[], activePage: RemoteSessionPage,
    archivedPage: RemoteSessionPage
  ): void {
    this.devices = devicesRaw.map((device: RemoteDevice) => this.toAgentDevice(device));
    this.projects = projectsRaw.map((project: RemoteProject) => toAgentProject(project)).sort(compareProjects);
    this.activeSessions = this.mapSessions(activePage.sessions);
    this.archivedSessions = this.mapSessions(archivedPage.sessions);
    // 首页刷新：游标换成服务端给的新游标（首页总是从第一页重新开始）。
    this.paging = applyFirstPage(
      this.paging, false, activePage.hasMore, cursorOrEmpty(activePage.nextCursor), this.activeSessions);
    this.paging = applyFirstPage(
      this.paging, true, archivedPage.hasMore, cursorOrEmpty(archivedPage.nextCursor), this.archivedSessions);
  }

  private mapSessions(raw: RemoteSession[]): AgentSession[] {
    const sessions = raw.map((session: RemoteSession) => {
      const device = this.deviceById(session.connectorId);
      return toAgentSession(session, device !== undefined ? device.name : undefined);
    });
    return sessions.sort(compareSessions);
  }

  private remapSessions(): void {
    // 设备名变化后刷新已映射会话的 meta 标签
    for (let i = 0; i < this.activeSessions.length; i++) {
      const session = this.activeSessions[i];
      const device = this.deviceById(session.connectorId);
      if (device !== undefined) {
        session.deviceName = device.name;
        session.connectorOnline = device.online;
      }
    }
  }

  deviceById(deviceId: string): AgentDevice | undefined {
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].id === deviceId) {
        return this.devices[i];
      }
    }
    return undefined;
  }

  projectById(projectId: string | undefined): AgentProject | undefined {
    if (projectId === undefined) {
      return undefined;
    }
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].id === projectId) {
        return this.projects[i];
      }
    }
    return undefined;
  }

  // -------------------------------------------------------------------------
  // 会话分页（列表底部「加载更多」）
  // -------------------------------------------------------------------------

  /**
   * 追加下一页会话（按 id 去重）。失败**保留游标**，底部入口因此变成「重试」。
   *
   * 守卫与上游 `AgentsAnywhereApp.loadMoreSessions()` 一致：没有更多 / 游标为空 /
   * 正在加载时直接返回，不发请求。
   */
  async loadMore(archived: boolean): Promise<void> {
    if (!pagingCanLoadMore(this.paging, archived)) {
      return;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      return;
    }
    const cursor = pageStateOf(this.paging, archived).nextCursor;
    this.paging = beginLoadMore(this.paging, archived);
    this.notify();
    try {
      const page = await AppServices.get().sessions.listSessionPage(
        serverUrl, token, archived, PAGE_SIZE, cursor);
      // ⚠️ await 之后必须复查登录态：翻页途中登出 / 换服务器时结果要丢掉，
      // 否则会把上一个账号的会话写进新账号的列表（同 connectRealtime 的处理）。
      if (readServerUrl() !== serverUrl || readAccessToken() !== token) {
        this.paging = failLoadMore(this.paging, archived, '登录状态已变化，已取消本次加载。');
        this.notify();
        return;
      }
      const incoming = this.mapSessions(page.sessions);
      if (archived) {
        this.archivedSessions = mergeSessionLists(this.archivedSessions, incoming);
      } else {
        this.activeSessions = mergeSessionLists(this.activeSessions, incoming);
      }
      this.paging = applyMorePage(
        this.paging, archived, cursor, page.hasMore, cursorOrEmpty(page.nextCursor));
      this.lastSyncedAt = new Date().toISOString();
    } catch (error) {
      const message = error instanceof Error ? (error as Error).message : String(error);
      this.paging = failLoadMore(this.paging, archived, message);
    }
    this.notify();
  }

  /** 底部「加载更多」入口是否显示（还能加载 或 上次失败可重试）。 */
  showLoadMore(archived: boolean): boolean {
    return pagingShouldShowLoadMore(this.paging, archived);
  }

  /** 当前是否能发起加载更多（按钮禁用态用）。 */
  canLoadMore(archived: boolean): boolean {
    return pagingCanLoadMore(this.paging, archived);
  }

  /** 该侧是否正在加载更多。 */
  loadingMore(archived: boolean): boolean {
    return pageStateOf(this.paging, archived).loading;
  }

  /** 该侧「加载更多」的上次失败原因（空串 = 没有失败）。 */
  loadMoreError(archived: boolean): string {
    return pageStateOf(this.paging, archived).error;
  }

  // -------------------------------------------------------------------------
  // 写入操作
  // -------------------------------------------------------------------------

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.patchSession(serverUrl, token, sessionId, title);
    }, '重命名失败');
  }

  async setSessionPinned(sessionId: string, pinned: boolean): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.patchSession(serverUrl, token, sessionId, undefined, pinned);
    }, '置顶操作失败');
  }

  async setSessionArchived(sessionId: string, archived: boolean): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      if (archived) {
        await AppServices.get().sessions.archiveSessions(serverUrl, token, [sessionId]);
      } else {
        await AppServices.get().sessions.unarchiveSessions(serverUrl, token, [sessionId]);
      }
    }, '归档操作失败');
  }

  async markSessionRead(sessionId: string): Promise<void> {
    await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.markSessionsRead(serverUrl, token, [sessionId]);
    }, '标记已读失败');
  }

  async archiveAllForProject(projectId: string, archived: boolean): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.archiveAllProjectSessions(serverUrl, token, projectId, archived, 'all');
    }, '批量归档失败');
  }

  async archiveAllForDevice(deviceId: string, archived: boolean): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.archiveAllDeviceSessions(serverUrl, token, deviceId, archived, 'all');
    }, '批量归档失败');
  }

  async renameDevice(deviceId: string, name: string): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().devices.updateDevice(serverUrl, token, deviceId, name);
      await this.refreshDevices();
    }, '重命名设备失败');
  }

  async deleteDevice(deviceId: string): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().devices.deleteDevice(serverUrl, token, deviceId);
      await this.refreshDevices();
    }, '删除设备失败');
  }

  async renameProject(projectId: string, name: string): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.updateProject(serverUrl, token, projectId, name);
    }, '重命名项目失败');
  }

  async setProjectPinned(projectId: string, pinned: boolean): Promise<boolean> {
    return await this.mutate(async (serverUrl: string, token: string): Promise<void> => {
      await AppServices.get().sessions.updateProject(serverUrl, token, projectId, undefined, pinned);
    }, '置顶项目失败');
  }

  private async mutate(action: (serverUrl: string, token: string) => Promise<void>, failureLabel: string): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      this.error = '未登录。';
      this.notify();
      return false;
    }
    try {
      await action(serverUrl, token);
      await this.refreshAll();
      return true;
    } catch (error) {
      this.error = `${failureLabel}：${error instanceof Error ? (error as Error).message : String(error)}`;
      this.notify();
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 工作台实时通道
  // -------------------------------------------------------------------------

  startRealtime(): void {
    if (this.subscribed) {
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
    const socket = this.socket;
    this.socket = undefined;
    if (socket !== undefined) {
      socket.close();
    }
    this.realtimeConnected = false;
    this.notify();
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
    const services = AppServices.get();
    try {
      const ticket = await services.realtime.createDashboardTicket(serverUrl, token, services.realtimeClientId);
      // ⚠️ await 之后必须复查：登出会调 `stopRealtime()`（subscribed=false），
      // 但票据请求可能还在飞 —— 不复查就会在**登出之后**仍然建立一条已鉴权的
      // dashboard WS，而且这条连接再也没人能关掉（stopRealtime 已经跑过了）。
      if (!this.subscribed) {
        return;
      }
      const url = services.realtime.dashboardWebSocketUrl(serverUrl, ticket.ticket);
      const handlers: SocketHandlers = {
        onOpen: () => {
          this.realtimeConnected = true;
          this.reconnectAttempt = 0;
          this.notify();
        },
        onText: (text: string) => {
          const snapshot = services.realtime.parseDashboardMessage(text);
          if (snapshot !== undefined) {
            this.applyDashboardSnapshot(snapshot);
          }
        },
        onBinary: (data: ArrayBuffer) => {
        },
        onClosed: () => {
          this.realtimeConnected = false;
          this.notify();
          this.scheduleReconnect();
        },
        onError: (message: string) => {
          this.realtimeConnected = false;
          this.notify();
        }
      };
      this.socket = services.realtime.openWebSocket(url, handlers);
    } catch (error) {
      if (!this.subscribed) {
        return;
      }
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

  /**
   * WS 全量快照。
   *
   * ⚠️ 快照**只负责它自己带回来的那些会话**（= 首页，上游 `activeFirstPageIds` 语义）：
   * 本地已加载的后续页要保留，否则用户翻过的页码会在下一次 `dashboard.changed` 时凭空消失。
   * 分页游标同样只在「快照确实带来更多」时替换，见 `applySnapshotPage`。
   */
  private applyDashboardSnapshot(snapshot: RemoteDashboardSnapshot): void {
    this.devices = snapshot.devices.map((device: RemoteDevice) => this.toAgentDevice(device));
    this.projects = snapshot.projects.map((project: RemoteProject) => toAgentProject(project)).sort(compareProjects);
    const activeIncoming = this.mapSessions(
      snapshot.sessions.filter((session: RemoteSession) => !session.archived));
    const archivedIncoming = this.mapSessions(
      snapshot.sessions.filter((session: RemoteSession) => session.archived));
    const activeIds = idsOf(activeIncoming);
    const archivedIds = idsOf(archivedIncoming);
    this.activeSessions = mergeWithSnapshot(this.activeSessions, activeIncoming, activeIds);
    this.archivedSessions = mergeWithSnapshot(this.archivedSessions, archivedIncoming, archivedIds);
    this.paging = applySnapshotPage(
      this.paging, false, snapshot.activePage.hasMore, cursorOrEmpty(snapshot.activePage.nextCursor),
      activeIncoming, this.activeSessions.length - activeIncoming.length);
    this.paging = applySnapshotPage(
      this.paging, true, snapshot.archivedPage.hasMore, cursorOrEmpty(snapshot.archivedPage.nextCursor),
      archivedIncoming, this.archivedSessions.length - archivedIncoming.length);
    this.lastSyncedAt = new Date().toISOString();
    this.error = '';
    this.notify();
  }

  /** 会话列表按项目分组（未绑定项目的会话归到「未分组」）。 */
  groupedSessions(archived: boolean): SessionGroup[] {
    const source = archived ? this.archivedSessions : this.activeSessions;
    const groups: SessionGroup[] = [];
    const byProject: Map<string, SessionGroup> = new Map<string, SessionGroup>();
    for (let i = 0; i < source.length; i++) {
      const session = source[i];
      const projectId = session.projectId !== undefined ? session.projectId : '';
      let group = byProject.get(projectId);
      if (group === undefined) {
        const project = this.projectById(session.projectId);
        group = {
          projectId: projectId,
          title: project !== undefined ? project.name : '未分组会话',
          workspacePath: project !== undefined ? project.workspacePath : '',
          pinned: project !== undefined ? project.pinned : false,
          sessions: []
        };
        byProject.set(projectId, group);
        groups.push(group);
      }
      group.sessions.push(session);
    }
    groups.sort((a: SessionGroup, b: SessionGroup): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      const aTime = a.sessions.length > 0 ? a.sessions[0].sortKey : '';
      const bTime = b.sessions.length > 0 ? b.sessions[0].sortKey : '';
      if (aTime !== bTime) {
        return aTime < bTime ? 1 : -1;
      }
      return a.title.localeCompare(b.title);
    });
    return groups;
  }
}

export interface SessionGroup {
  projectId: string;
  title: string;
  workspacePath: string;
  pinned: boolean;
  sessions: AgentSession[];
}
