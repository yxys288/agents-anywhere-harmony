/**
 * App 内部共享模型（对应 Android `model/AgentSession.kt`、`model/AgentProject.kt`、
 * `model/RuntimeIdentity.kt`）与 `feature/sessions/SessionMappers.kt` 的派生逻辑。
 */

import { RemoteProject, RemoteSession } from './Types';

export enum SessionStatus {
  Idle = 'idle',
  Waiting = 'waiting',
  Pending = 'pending',
  Running = 'running',
  Stopping = 'stopping',
  WaitingApproval = 'waiting_approval',
  Error = 'error',
  Blocked = 'blocked',
  Unknown = 'unknown'
}

export interface RuntimeInstanceLabels {
  primary: string;
  secondary?: string;
}

/** `codex` → `Codex`，`claude` → `Claude Code`，`dsh` → `DeepSeek Harness`，其余首字母大写。 */
export function runtimeTypeLabel(runtimeType: string): string {
  if (runtimeType === 'codex') {
    return 'Codex';
  }
  if (runtimeType === 'claude') {
    return 'Claude Code';
  }
  if (runtimeType === 'dsh') {
    return 'DeepSeek Harness';
  }
  if (runtimeType.length === 0) {
    return '';
  }
  const head = runtimeType.substring(0, 1).toUpperCase();
  return head + runtimeType.substring(1);
}

export function runtimeInstanceLabels(name: string | undefined, runtimeType: string): RuntimeInstanceLabels {
  const typeLabel = runtimeTypeLabel(runtimeType);
  const trimmed = name !== undefined ? name.trim() : '';
  const instanceName: string | undefined =
    (trimmed.length > 0 && trimmed.toLowerCase() !== runtimeType.toLowerCase()) ? trimmed : undefined;
  const primary = instanceName !== undefined ? instanceName : typeLabel;
  const secondary: string | undefined =
    typeLabel.toLowerCase() === primary.toLowerCase() ? undefined : typeLabel;
  return { primary: primary, secondary: secondary };
}

/**
 * 运行时**显示名**（上游 `DeviceRuntimeState.kt:36-37` 的 `DeviceRuntime.labels`）。
 *
 * ⚠️ 不能直接用服务端的 `displayName`：DSH 那台设备上报的 displayName 就是 `DSH`，
 * 而它**等于** runtimeType（`dsh`，大小写无关）⇒ 按上游 `runtimeInstanceLabels` 的
 * `takeUnless { it.equals(runtimeType, ignoreCase = true) }` 应当被丢掉，回落到类型名
 * 「DeepSeek Harness」。上游 `home/NewSessionScreen.kt:545/550/670` 与
 * `DeviceDetailScreen.kt:694` 一律走 `labels.primary`，不是 displayName。
 */
export function deviceRuntimeLabel(displayName: string, runtimeType: string): string {
  return runtimeInstanceLabels(displayName, runtimeType).primary;
}

/**
 * 运行时行的副文：上游 `DeviceDetailScreen.kt:702` 的
 * `listOfNotNull(runtime.labels.secondary, runtimeStatusLabel(runtime)).joinToString(" · ")`。
 * 实例名与类型名相同时 secondary 为 undefined（不重复显示）。
 */
export function deviceRuntimeSecondary(
  displayName: string, runtimeType: string, statusLabel: string
): string {
  const labels = runtimeInstanceLabels(displayName, runtimeType);
  const parts: string[] = [];
  if (labels.secondary !== undefined && labels.secondary.length > 0) {
    parts.push(labels.secondary);
  }
  if (statusLabel.length > 0) {
    parts.push(statusLabel);
  }
  return parts.join(' · ');
}

/**
 * 设备详情「会话」区工具条的批量动作文案 —— 上游 `device_detail_archive_all`「全部归档」/
 * `device_detail_unarchive_all`「全部取消归档」。
 *
 * ⚠️ 与确认框按钮文案（`device_confirm_archive_all_confirm`「归档全部」/
 * 「取消归档全部」，见 `DeviceStore.ets` 的 `archiveAllConfirmLabel`）**不是同一个 key**：
 * 之前工具条借用后者，于是界面写成「归档全部」，与安卓的「全部归档」不一致。
 */
export function deviceArchiveAllActionLabel(archived: boolean): string {
  return archived ? '全部归档' : '全部取消归档';
}

export function sessionStatusFromWire(value: string): SessionStatus {
  switch (value) {
    case 'idle': return SessionStatus.Idle;
    case 'waiting': return SessionStatus.Waiting;
    case 'pending': return SessionStatus.Pending;
    case 'running': return SessionStatus.Running;
    case 'stopping': return SessionStatus.Stopping;
    case 'waiting_approval': return SessionStatus.WaitingApproval;
    case 'error': return SessionStatus.Error;
    case 'blocked': return SessionStatus.Blocked;
    default: return SessionStatus.Unknown;
  }
}

export function sessionStatusLabel(status: SessionStatus): string {
  switch (status) {
    case SessionStatus.Idle: return '空闲';
    case SessionStatus.Waiting: return '等待中';
    case SessionStatus.Pending: return '排队中';
    case SessionStatus.Running: return '运行中';
    case SessionStatus.Stopping: return '停止中';
    case SessionStatus.WaitingApproval: return '待审批';
    case SessionStatus.Error: return '出错';
    case SessionStatus.Blocked: return '已阻塞';
    default: return '未知';
  }
}

/** 列表右侧的状态点：审批 > 忙碌 > 未读 > 无。 */
export enum SessionListIndicator {
  None = 'none',
  Busy = 'busy',
  WaitingApproval = 'waiting_approval',
  Unread = 'unread'
}

export interface AgentSession {
  id: string;
  connectorId: string;
  projectId?: string;
  deviceName: string;
  title: string;
  summary: string;
  cwd?: string;
  workspaceLabel: string;
  runtime: string;
  runtimeLabel: string;
  runtimeName: string;
  status: SessionStatus;
  statusLabel: string;
  updatedAtLabel: string;
  metaLabel: string;
  pinned: boolean;
  archived: boolean;
  archivedAt?: string;
  unread: boolean;
  lastReadSeq: number;
  takeover: boolean;
  connectorOnline: boolean;
  live: boolean;
  sortKey: string;
  sortAt?: string;
  updatedSeq: number;
  indicator: SessionListIndicator;
}

export interface AgentDevice {
  id: string;
  name: string;
  deviceOs?: string;
  online: boolean;
  lastSeenAt?: string;
  createdAt?: string;
}

export interface AgentProject {
  id: string;
  userId: string;
  connectorId: string;
  name: string;
  workspacePath: string;
  pinned: boolean;
  activeSessionCount: number;
  lastActivityAt?: string;
  createdAt: string;
  updatedAt: string;
  manuallyCreated: boolean;
}

export function workspaceName(cwd: string | undefined): string {
  if (cwd === undefined) {
    return '';
  }
  let trimmed = cwd.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.length === 0) {
    return '';
  }
  const idx = trimmed.lastIndexOf('/');
  const tail = idx >= 0 ? trimmed.substring(idx + 1) : '';
  return tail.length > 0 ? tail : trimmed;
}

/**
 * 相对时间标签 —— **逐字复刻**上游 `feature/sessions/SessionMappers.kt:110-130`：
 * `now` / `5m` / `3h` / `Yest.` / `4d` / `2w` / `1y`。
 *
 * ⚠️ 上游是**硬编码的英文紧凑格式**（连 `Yest.` 这种缩写、`now` 的小写都是原样），
 * 没有资源化、也没有中文短名机制 —— 所以这里不做本地化，改中文就是与安卓不一致。
 * 展示位置：首页会话行、设备详情的会话行、已归档列表（都读 `AgentSession.updatedAtLabel`）。
 */
export function relativeTimeLabel(iso: string | undefined): string {
  if (iso === undefined || iso.length === 0) {
    return '';
  }
  const parsed = Date.parse(iso);
  if (isNaN(parsed)) {
    return '';
  }
  let elapsedMs = Date.now() - parsed;
  if (elapsedMs < 0) {
    elapsedMs = 0;
  }
  const minutes = Math.floor(elapsedMs / 60000);
  if (minutes < 1) {
    return 'now';
  }
  if (minutes < 60) {
    return `${minutes}m`;
  }
  const hours = Math.floor(elapsedMs / 3600000);
  if (hours < 24) {
    return `${hours}h`;
  }
  const days = Math.floor(elapsedMs / 86400000);
  if (days === 1) {
    return 'Yest.';
  }
  if (days < 7) {
    return `${days}d`;
  }
  if (days < 365) {
    return `${Math.floor(days / 7)}w`;
  }
  return `${Math.floor(days / 365)}y`;
}

function summaryText(status: SessionStatus, cwd: string | undefined, connectorStatus: string): string {
  if (status === SessionStatus.WaitingApproval) {
    return '等待你审批。';
  }
  if (status === SessionStatus.Waiting || status === SessionStatus.Pending || status === SessionStatus.Running) {
    return '正在运行。';
  }
  if (status === SessionStatus.Error) {
    return '需要处理。';
  }
  if (cwd !== undefined && cwd.trim().length > 0) {
    return cwd;
  }
  if (connectorStatus === 'offline') {
    return '设备离线。';
  }
  return '等待下一步更新。';
}

function listIndicator(status: SessionStatus, unread: boolean): SessionListIndicator {
  if (status === SessionStatus.WaitingApproval) {
    return SessionListIndicator.WaitingApproval;
  }
  if (status === SessionStatus.Running || status === SessionStatus.Waiting || status === SessionStatus.Pending) {
    return SessionListIndicator.Busy;
  }
  if (status === SessionStatus.Idle && unread) {
    return SessionListIndicator.Unread;
  }
  return SessionListIndicator.None;
}

export interface ConnectorScoped {
  connectorId: string;
}

export function toAgentDevice(remote: ConnectorScoped): AgentDevice {
  return { id: remote.connectorId, name: remote.connectorId, online: false };
}

/** 对应 `RemoteSession.toAgentSession(devicesById)`。 */
export function toAgentSession(remote: RemoteSession, deviceName: string | undefined): AgentSession {
  const workspace = workspaceName(remote.cwd);
  const statusValue = sessionStatusFromWire(remote.status);
  const titleText = remote.title !== undefined && remote.title.trim().length > 0
    ? remote.title
    : (remote.externalSessionId !== undefined && remote.externalSessionId.trim().length > 0
      ? remote.externalSessionId
      : '未命名会话');
  const runtimeName = remote.runtimeName !== undefined ? remote.runtimeName : remote.runtimeType;
  const runtimeType = remote.runtimeType !== undefined ? remote.runtimeType : remote.runtime;
  const labels = runtimeInstanceLabels(runtimeName, runtimeType);
  const resolvedDeviceName = deviceName !== undefined && deviceName.length > 0
    ? deviceName
    : (remote.connectorId.length > 8 ? remote.connectorId.substring(0, 8) : remote.connectorId);

  const metaParts: string[] = [];
  metaParts.push(labels.primary);
  if (labels.secondary !== undefined) {
    metaParts.push(labels.secondary);
  }
  if (resolvedDeviceName.length > 0) {
    metaParts.push(resolvedDeviceName);
  }
  if (workspace.length > 0) {
    metaParts.push(workspace);
  }

  const activityAt = firstNonBlank([
    remote.sortAt, remote.lastActivityAt, remote.lastItemAt, remote.lastSyncedAt, remote.sourceObservedAt
  ]);
  const sortKey = firstNonBlank([remote.sortAt, remote.lastActivityAt, remote.lastItemAt]) ?? '';

  const session: AgentSession = {
    id: remote.id,
    connectorId: remote.connectorId,
    projectId: remote.projectId,
    deviceName: resolvedDeviceName,
    title: titleText,
    summary: summaryText(statusValue, remote.cwd, remote.connectorStatus),
    cwd: remote.cwd,
    workspaceLabel: workspace,
    runtime: runtimeType,
    runtimeLabel: labels.primary,
    runtimeName: runtimeName !== undefined ? runtimeName : runtimeType,
    status: statusValue,
    statusLabel: sessionStatusLabel(statusValue),
    updatedAtLabel: relativeTimeLabel(activityAt),
    metaLabel: metaParts.join('  ·  '),
    pinned: remote.pinned,
    archived: remote.archived,
    archivedAt: remote.archivedAt,
    unread: remote.unread,
    lastReadSeq: remote.lastReadSeq,
    takeover: remote.takeover,
    connectorOnline: remote.connectorStatus === 'online',
    live: statusValue === SessionStatus.Waiting || statusValue === SessionStatus.Pending ||
      statusValue === SessionStatus.Running || statusValue === SessionStatus.WaitingApproval,
    sortKey: sortKey,
    sortAt: remote.sortAt,
    updatedSeq: remote.updatedSeq,
    indicator: listIndicator(statusValue, remote.unread)
  };
  return session;
}

export function toAgentProject(remote: RemoteProject): AgentProject {
  const project: AgentProject = {
    id: remote.id,
    userId: remote.userId,
    connectorId: remote.connectorId,
    name: remote.name,
    workspacePath: remote.workspacePath,
    pinned: remote.pinned,
    activeSessionCount: remote.activeSessionCount,
    lastActivityAt: remote.lastActivityAt,
    createdAt: remote.createdAt,
    updatedAt: remote.updatedAt,
    manuallyCreated: remote.manuallyCreated === true
  };
  return project;
}

function firstNonBlank(values: (string | undefined)[]): string | undefined {
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (value !== undefined && value.trim().length > 0) {
      return value;
    }
  }
  return undefined;
}

/** 会话列表排序：置顶优先，其次按 sortKey（ISO 时间）倒序，最后按 updatedSeq 倒序。 */
export function compareSessions(a: AgentSession, b: AgentSession): number {
  if (a.pinned !== b.pinned) {
    return a.pinned ? -1 : 1;
  }
  if (a.sortKey !== b.sortKey) {
    return a.sortKey < b.sortKey ? 1 : -1;
  }
  if (a.updatedSeq !== b.updatedSeq) {
    return b.updatedSeq - a.updatedSeq;
  }
  return 0;
}

/** 项目排序：置顶优先，其次按最近活动倒序。 */
export function compareProjects(a: AgentProject, b: AgentProject): number {
  if (a.pinned !== b.pinned) {
    return a.pinned ? -1 : 1;
  }
  const at = a.lastActivityAt ?? '';
  const bt = b.lastActivityAt ?? '';
  if (at !== bt) {
    return at < bt ? 1 : -1;
  }
  return a.name.localeCompare(b.name);
}
