/**
 * 线格式 → 强类型模型的归一化（对应 Android `api/*Api.kt` 里的 `toXxx()` 私有扩展函数）。
 *
 * ArkTS 没有 Kotlin 的 `optString(name, default)`，所以这里集中提供一组读取助手，
 * 并把 Android 端所有的**别名回退与默认值**规则 1:1 搬过来（例如 session 的
 * runtime/runtimeType/runtimeId/runtimeName 四级回退）。
 */

import {
  JsonMap, RemoteDashboardSnapshot, RemoteDevice, RemoteDeviceRuntime, RemoteDirectoryEntry,
  RemoteDownloadedAttachment, RemoteEventRecoveryResponse, RemoteProject,
  RemoteRuntimeCapability, RemoteRuntimeCapabilitySet, RemoteRuntimeModel, RemoteRuntimeModelCatalog,
  RemoteRuntimeNotice, RemoteRuntimeNoticeAction, RemoteRuntimeNoticeBlocking, RemoteRuntimePermission,
  RemoteRuntimePermissionCatalog, RemoteRuntimeReasoning, RemoteSession, RemoteSessionEventEnvelope,
  RemoteSessionEventPayload, RemoteSessionRuntimeState, RemoteSessionTimelinePage, RemoteSessionTimelineSnapshot,
  RemoteTerminal, RemoteTextFile, RemoteTimelineItem, RemoteUploadedAttachment, RemoteWsTicket
} from '../model/Types';

export type Raw = Record<string, Object>;

// ---------------------------------------------------------------------------
// 读取助手
// ---------------------------------------------------------------------------

/** 类型化的空 Raw（ArkTS 禁止无类型对象字面量，直接写 `?? {}` 会编译失败）。 */
export function emptyRaw(): Raw {
  const raw: Raw = {};
  return raw;
}

export function asRaw(value: Object | undefined | null): Raw | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (Array.isArray(value)) {
    return undefined;
  }
  if (typeof value === 'object') {
    return value as Raw;
  }
  return undefined;
}

export function asRawArray(value: Object | undefined | null): Raw[] {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const list = value as Object[];
  const out: Raw[] = [];
  for (let i = 0; i < list.length; i++) {
    const item = asRaw(list[i]);
    if (item !== undefined) {
      out.push(item);
    }
  }
  return out;
}

export function asStringArray(value: Object | undefined | null): string[] {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const list = value as Object[];
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    if (typeof item === 'string') {
      out.push(item as string);
    }
  }
  return out;
}

export function optString(raw: Raw, key: string): string | undefined {
  const value = raw[key];
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === 'string') {
    return (value as string).length > 0 ? (value as string) : undefined;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  return undefined;
}

export function str(raw: Raw, key: string, fallback: string): string {
  const value = optString(raw, key);
  return value !== undefined ? value : fallback;
}

export function optNumber(raw: Raw, key: string): number | undefined {
  const value = raw[key];
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const parsed = Number.parseFloat(value as string);
    return isNaN(parsed) ? undefined : parsed;
  }
  return undefined;
}

function num(raw: Raw, key: string, fallback: number): number {
  const value = optNumber(raw, key);
  return value !== undefined ? value : fallback;
}

function optBool(raw: Raw, key: string): boolean | undefined {
  const value = raw[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  return undefined;
}

export function bool(raw: Raw, key: string, fallback: boolean): boolean {
  const value = optBool(raw, key);
  return value !== undefined ? value : fallback;
}

export function optRaw(raw: Raw, key: string): Raw | undefined {
  return asRaw(raw[key]);
}

function mapOf(raw: Raw | undefined): JsonMap {
  if (raw === undefined) {
    return emptyRaw();
  }
  return raw as JsonMap;
}

/** 字符串 → 字符串映射（`selections` 用，null 值被丢弃）。 */
function stringMapOf(raw: Raw | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === undefined) {
    return out;
  }
  const keys = Object.keys(raw);
  for (let i = 0; i < keys.length; i++) {
    const value = raw[keys[i]];
    if (typeof value === 'string') {
      out[keys[i]] = value as string;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

export function parseDevice(raw: Raw): RemoteDevice {
  const device: RemoteDevice = {
    id: str(raw, 'id', ''),
    name: str(raw, 'name', 'Device'),
    deviceOs: optString(raw, 'deviceOs'),
    status: str(raw, 'status', 'offline'),
    lastSeenAt: optString(raw, 'lastSeenAt'),
    createdAt: optString(raw, 'createdAt'),
    updatedAt: optString(raw, 'updatedAt')
  };
  return device;
}

/**
 * runtime 三段式回退（与 Android `toRemoteDeviceRuntime` 一致）：
 * `runtime`（legacy 字段）优先；否则若 runtimeId 本身就是合法 runtimeType 就用它，再否则用 runtimeType。
 */
export function parseDeviceRuntime(raw: Raw, fallbackConnectorId: string): RemoteDeviceRuntime {
  const legacyRuntime = optString(raw, 'runtime');
  const runtimeId = optString(raw, 'runtimeId') ?? (legacyRuntime ?? '');
  const reportedRuntimeType = optString(raw, 'runtimeType');
  let runtimeType = '';
  if (legacyRuntime !== undefined) {
    runtimeType = legacyRuntime;
  } else if (isValidRuntimeType(runtimeId)) {
    runtimeType = runtimeId;
  } else {
    runtimeType = reportedRuntimeType ?? '';
  }
  const connectorId = str(raw, 'connectorId', fallbackConnectorId);
  const displayName = optString(raw, 'displayName') ?? optString(raw, 'name') ?? runtimeType;
  const runtime: RemoteDeviceRuntime = {
    connectorId: connectorId.length > 0 ? connectorId : fallbackConnectorId,
    runtimeId: runtimeId,
    runtimeType: runtimeType,
    displayName: displayName,
    present: bool(raw, 'present', false),
    configured: bool(raw, 'configured', false),
    active: bool(raw, 'active', false),
    status: normaliseRuntimeStatus(str(raw, 'status', 'unknown')),
    discovery: optRaw(raw, 'discovery'),
    metadata: optRaw(raw, 'metadata'),
    schema: optRaw(raw, 'schema'),
    uiSchema: optRaw(raw, 'uiSchema'),
    config: optRaw(raw, 'config'),
    error: optRaw(raw, 'error'),
    lastDiscoveredAt: optString(raw, 'lastDiscoveredAt'),
    updatedAt: optString(raw, 'updatedAt')
  };
  return runtime;
}

const RUNTIME_STATUSES: string[] = [
  'stopped', 'discovering', 'available', 'unavailable', 'validating',
  'starting', 'running', 'stopping', 'error', 'unknown'
];

function normaliseRuntimeStatus(value: string): string {
  return RUNTIME_STATUSES.includes(value) ? value : 'unknown';
}

const RUNTIME_TYPE_PATTERN: RegExp = new RegExp('^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
const RUNTIME_INSTANCE_PATTERN: RegExp = new RegExp('^rti_[A-Za-z0-9_-]{1,124}$');

function isValidRuntimeType(value: string): boolean {
  return value.length >= 1 && value.length <= 64 && !value.startsWith('rti_') &&
    RUNTIME_TYPE_PATTERN.test(value);
}

function isValidRuntimeInstanceId(runtimeId: string, runtimeType: string): boolean {
  return runtimeId === runtimeType ||
    (runtimeId.length <= 128 && RUNTIME_INSTANCE_PATTERN.test(runtimeId));
}

/** `/connectors/{id}/runtimes` 响应：过滤掉 runtimeType/runtimeId 非法的条目。 */
export function parseDeviceRuntimeList(raw: Raw, fallbackConnectorId: string): RemoteDeviceRuntime[] {
  const connectorIdRaw = str(raw, 'connectorId', fallbackConnectorId);
  const connectorId = connectorIdRaw.length > 0 ? connectorIdRaw : fallbackConnectorId;
  const parsed = asRawArray(raw['runtimes']).map((item: Raw) => parseDeviceRuntime(item, connectorId));
  const out: RemoteDeviceRuntime[] = [];
  for (let i = 0; i < parsed.length; i++) {
    const runtime = parsed[i];
    if (isValidRuntimeType(runtime.runtimeType) &&
      isValidRuntimeInstanceId(runtime.runtimeId, runtime.runtimeType)) {
      out.push(runtime);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

export function parseProject(raw: Raw): RemoteProject {
  const counts = optRaw(raw, 'sidebarSessionCounts');
  const project: RemoteProject = {
    id: str(raw, 'id', ''),
    userId: str(raw, 'userId', ''),
    connectorId: str(raw, 'connectorId', ''),
    name: str(raw, 'name', ''),
    workspacePath: str(raw, 'workspacePath', ''),
    pinned: bool(raw, 'pinned', false),
    pinnedAt: optString(raw, 'pinnedAt'),
    activeSessionCount: num(raw, 'activeSessionCount', 0),
    lastActivityAt: optString(raw, 'lastActivityAt'),
    createdAt: str(raw, 'createdAt', ''),
    updatedAt: str(raw, 'updatedAt', ''),
    manuallyCreated: bool(raw, 'manuallyCreated', false)
  };
  if (counts !== undefined) {
    project.sidebarSessionCounts = { active: num(counts, 'active', 0), archived: num(counts, 'archived', 0) };
  }
  return project;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

export function parseSession(raw: Raw): RemoteSession {
  const runtime = optString(raw, 'runtime') ?? optString(raw, 'runtimeType') ?? 'codex';
  const runtimeType = optString(raw, 'runtimeType') ?? runtime;
  const runtimeId = optString(raw, 'runtimeId') ?? runtime;
  const runtimeName = optString(raw, 'runtimeName')
    ?? optString(raw, 'runtimeDisplayName')
    ?? optString(raw, 'displayName')
    ?? optString(raw, 'name')
    ?? runtimeId;
  const session: RemoteSession = {
    id: str(raw, 'id', ''),
    connectorId: str(raw, 'connectorId', ''),
    projectId: optString(raw, 'projectId'),
    connectorStatus: str(raw, 'connectorStatus', 'offline'),
    runtime: runtimeType,
    externalSessionId: optString(raw, 'externalSessionId'),
    title: optString(raw, 'title'),
    cwd: optString(raw, 'cwd'),
    status: str(raw, 'status', 'idle'),
    takeover: bool(raw, 'takeover', false),
    pinned: bool(raw, 'pinned', false),
    pinnedAt: optString(raw, 'pinnedAt'),
    archived: bool(raw, 'archived', false),
    archivedAt: optString(raw, 'archivedAt'),
    unread: bool(raw, 'unread', false),
    lastReadSeq: num(raw, 'lastReadSeq', 0),
    lastSyncedAt: optString(raw, 'lastSyncedAt'),
    sourceObservedAt: optString(raw, 'sourceObservedAt'),
    lastActivityAt: optString(raw, 'lastActivityAt'),
    lastItemAt: optString(raw, 'lastItemAt'),
    lastItemOrderSeq: optNumber(raw, 'lastItemOrderSeq'),
    sortAt: optString(raw, 'sortAt'),
    updatedSeq: num(raw, 'updatedSeq', 0),
    runtimeId: runtimeId,
    runtimeType: runtimeType,
    runtimeName: runtimeName
  };
  return session;
}

export function parseTimelineItem(raw: Raw): RemoteTimelineItem {
  const content = optRaw(raw, 'content') ?? emptyRaw();
  const text = optString(content, 'text')
    ?? optString(content, 'message')
    ?? optString(content, 'description')
    ?? '';
  const item: RemoteTimelineItem = {
    id: str(raw, 'id', ''),
    sessionId: str(raw, 'sessionId', ''),
    type: str(raw, 'type', 'message'),
    status: str(raw, 'status', 'done'),
    role: optString(raw, 'role'),
    text: text,
    content: mapOf(content),
    source: mapOf(optRaw(raw, 'source')),
    orderSeq: num(raw, 'orderSeq', 0),
    revision: num(raw, 'revision', 1),
    updatedSeq: num(raw, 'updatedSeq', 0),
    createdAt: str(raw, 'createdAt', ''),
    updatedAt: optString(raw, 'updatedAt'),
    contentHash: str(raw, 'contentHash', '')
  };
  return item;
}

export function parseTimelinePage(raw: Raw): RemoteSessionTimelinePage {
  const page: RemoteSessionTimelinePage = {
    sessionId: str(raw, 'sessionId', ''),
    items: asRawArray(raw['items']).map((item: Raw) => parseTimelineItem(item)),
    nextSeq: num(raw, 'nextSeq', 0),
    hasMore: bool(raw, 'hasMore', false),
    serverTime: optString(raw, 'serverTime')
  };
  return page;
}

export function parseTimelineSnapshot(raw: Raw | undefined): RemoteSessionTimelineSnapshot {
  if (raw === undefined) {
    return { items: [], nextSeq: 0, hasMore: false };
  }
  const snapshot: RemoteSessionTimelineSnapshot = {
    items: asRawArray(raw['items']).map((item: Raw) => parseTimelineItem(item)),
    nextSeq: num(raw, 'nextSeq', 0),
    hasMore: bool(raw, 'hasMore', false)
  };
  return snapshot;
}

export function parseRuntimeState(raw: Raw): RemoteSessionRuntimeState {
  const runtime = optString(raw, 'runtime') ?? optString(raw, 'runtimeType') ?? '';
  const runtimeType = optString(raw, 'runtimeType') ?? runtime;
  const runtimeId = optString(raw, 'runtimeId') ?? runtime;
  const runtimeName = optString(raw, 'runtimeName')
    ?? optString(raw, 'runtimeDisplayName')
    ?? optString(raw, 'displayName')
    ?? optString(raw, 'name')
    ?? runtimeId;
  const rawStatus = str(raw, 'status', 'unknown');
  const state: RemoteSessionRuntimeState = {
    sessionId: str(raw, 'sessionId', ''),
    runtime: runtimeType,
    externalSessionId: optString(raw, 'externalSessionId'),
    status: rawStatus.length > 0 ? rawStatus : 'unknown',
    selections: stringMapOf(optRaw(raw, 'selections')),
    statusReason: optString(raw, 'statusReason'),
    error: optRaw(raw, 'error'),
    metadata: optRaw(raw, 'metadata') ?? emptyRaw(),
    updatedSeq: num(raw, 'updatedSeq', 0),
    createdAt: optString(raw, 'createdAt'),
    updatedAt: optString(raw, 'updatedAt'),
    runtimeId: runtimeId,
    runtimeType: runtimeType,
    runtimeName: runtimeName
  };
  return state;
}

function parseNoticeAction(raw: Raw): RemoteRuntimeNoticeAction {
  const input = optRaw(raw, 'input');
  const action: RemoteRuntimeNoticeAction = {
    actionId: str(raw, 'actionId', ''),
    label: str(raw, 'label', ''),
    style: str(raw, 'style', 'secondary'),
    input: {
      required: input !== undefined ? bool(input, 'required', false) : false,
      schema: input !== undefined ? optRaw(input, 'schema') : undefined,
      uiSchema: input !== undefined ? optRaw(input, 'uiSchema') : undefined
    }
  };
  return action;
}

export function parseNotice(raw: Raw): RemoteRuntimeNotice {
  const blocking = optRaw(raw, 'blocking');
  const notice: RemoteRuntimeNotice = {
    noticeId: str(raw, 'noticeId', ''),
    type: str(raw, 'type', 'unknown'),
    sessionId: str(raw, 'sessionId', ''),
    source: optRaw(raw, 'source') ?? emptyRaw(),
    title: str(raw, 'title', ''),
    message: optString(raw, 'message'),
    severity: str(raw, 'severity', 'info'),
    status: str(raw, 'status', 'open'),
    interactionType: optString(raw, 'interactionType'),
    responseRequired: bool(raw, 'responseRequired', false),
    actions: asRawArray(raw['actions']).map((action: Raw) => parseNoticeAction(action)),
    context: optRaw(raw, 'context') ?? emptyRaw(),
    metadata: optRaw(raw, 'metadata') ?? emptyRaw(),
    expiresAt: optString(raw, 'expiresAt'),
    revision: num(raw, 'revision', 1),
    updatedSeq: num(raw, 'updatedSeq', 0),
    createdAt: optString(raw, 'createdAt'),
    updatedAt: optString(raw, 'updatedAt'),
    resolvedAt: optString(raw, 'resolvedAt')
  };
  if (blocking !== undefined) {
    const value: RemoteRuntimeNoticeBlocking = {
      scope: str(blocking, 'scope', ''),
      targetId: str(blocking, 'targetId', '')
    };
    notice.blocking = value;
  }
  return notice;
}

function parseCapability(raw: Raw): RemoteRuntimeCapability {
  const runtime = optString(raw, 'runtime');
  const capability: RemoteRuntimeCapability = {
    capabilityId: str(raw, 'capabilityId', ''),
    version: str(raw, 'version', '1'),
    scope: str(raw, 'scope', 'runtime'),
    runtime: runtime,
    sessionId: optString(raw, 'sessionId'),
    supported: bool(raw, 'supported', true),
    available: bool(raw, 'available', true),
    allowed: bool(raw, 'allowed', true),
    unavailableReason: optString(raw, 'unavailableReason'),
    parameters: optRaw(raw, 'parameters') ?? emptyRaw(),
    runtimeId: optString(raw, 'runtimeId'),
    runtimeType: optString(raw, 'runtimeType') ?? runtime
  };
  return capability;
}

export function parseCapabilitySet(raw: Raw | undefined): RemoteRuntimeCapabilitySet {
  if (raw === undefined) {
    return { revision: 0, capabilities: [] };
  }
  const set: RemoteRuntimeCapabilitySet = {
    revision: num(raw, 'revision', 0),
    capabilities: asRawArray(raw['capabilities']).map((item: Raw) => parseCapability(item))
  };
  return set;
}

/** 能力是否可用（supported && available && allowed）。 */
export function capabilityUsable(set: RemoteRuntimeCapabilitySet, capabilityId: string): boolean {
  for (let i = 0; i < set.capabilities.length; i++) {
    const capability = set.capabilities[i];
    if (capability.capabilityId === capabilityId) {
      return capability.supported && capability.available && capability.allowed;
    }
  }
  return false;
}

function catalogItemEnabled(raw: Raw, metadata: Raw | undefined): boolean {
  const direct = optBool(raw, 'enabled');
  if (direct !== undefined) {
    return direct;
  }
  if (metadata !== undefined) {
    const fromMetadata = optBool(metadata, 'enabled');
    if (fromMetadata !== undefined) {
      return fromMetadata;
    }
  }
  return true;
}

function catalogItemDisabledReason(raw: Raw, metadata: Raw | undefined): string | undefined {
  const direct = optString(raw, 'disabledReason');
  if (direct !== undefined) {
    return direct;
  }
  return metadata !== undefined ? optString(metadata, 'disabledReason') : undefined;
}

function parseReasoning(raw: Raw): RemoteRuntimeReasoning {
  const metadata = optRaw(raw, 'metadata');
  const reasoning: RemoteRuntimeReasoning = {
    id: str(raw, 'id', ''),
    selectionId: str(raw, 'selectionId', ''),
    fullModelId: optString(raw, 'fullModelId'),
    displayName: str(raw, 'displayName', ''),
    description: optString(raw, 'description'),
    default: bool(raw, 'default', false),
    metadata: metadata ?? emptyRaw(),
    enabled: catalogItemEnabled(raw, metadata),
    disabledReason: catalogItemDisabledReason(raw, metadata)
  };
  return reasoning;
}

function parseModel(raw: Raw): RemoteRuntimeModel {
  const metadata = optRaw(raw, 'metadata');
  const model: RemoteRuntimeModel = {
    id: str(raw, 'id', ''),
    selectionId: optString(raw, 'selectionId'),
    displayName: str(raw, 'displayName', ''),
    description: optString(raw, 'description'),
    default: bool(raw, 'default', false),
    reasoningItems: asRawArray(raw['reasoningItems']).map((item: Raw) => parseReasoning(item)),
    metadata: metadata ?? emptyRaw(),
    enabled: catalogItemEnabled(raw, metadata),
    disabledReason: catalogItemDisabledReason(raw, metadata)
  };
  return model;
}

export function parseModelCatalog(raw: Raw | undefined, fallbackRuntimeId?: string): RemoteRuntimeModelCatalog {
  if (raw === undefined) {
    return { runtime: '', revision: 0, models: [] };
  }
  const runtime = optString(raw, 'runtime') ?? optString(raw, 'runtimeType') ?? '';
  const runtimeType = optString(raw, 'runtimeType') ?? runtime;
  const fromFallback = fallbackRuntimeId !== undefined && fallbackRuntimeId.length > 0 ? fallbackRuntimeId : undefined;
  const runtimeId = optString(raw, 'runtimeId') ?? fromFallback ?? runtime;
  const catalog: RemoteRuntimeModelCatalog = {
    runtime: runtimeType,
    revision: num(raw, 'revision', 0),
    models: asRawArray(raw['models']).map((item: Raw) => parseModel(item)),
    runtimeId: runtimeId,
    runtimeType: runtimeType
  };
  return catalog;
}

function parsePermission(raw: Raw): RemoteRuntimePermission {
  const metadata = optRaw(raw, 'metadata');
  const permission: RemoteRuntimePermission = {
    id: str(raw, 'id', ''),
    selectionId: str(raw, 'selectionId', ''),
    displayName: str(raw, 'displayName', ''),
    description: optString(raw, 'description'),
    default: bool(raw, 'default', false),
    metadata: metadata ?? emptyRaw(),
    enabled: catalogItemEnabled(raw, metadata),
    disabledReason: catalogItemDisabledReason(raw, metadata)
  };
  return permission;
}

export function parsePermissionCatalog(
  raw: Raw | undefined, fallbackRuntimeId?: string
): RemoteRuntimePermissionCatalog {
  if (raw === undefined) {
    return { runtime: '', revision: 0, permissions: [] };
  }
  const runtime = optString(raw, 'runtime') ?? optString(raw, 'runtimeType') ?? '';
  const runtimeType = optString(raw, 'runtimeType') ?? runtime;
  const fromFallback = fallbackRuntimeId !== undefined && fallbackRuntimeId.length > 0 ? fallbackRuntimeId : undefined;
  const runtimeId = optString(raw, 'runtimeId') ?? fromFallback ?? runtime;
  const catalog: RemoteRuntimePermissionCatalog = {
    runtime: runtimeType,
    revision: num(raw, 'revision', 0),
    permissions: asRawArray(raw['permissions']).map((item: Raw) => parsePermission(item)),
    runtimeId: runtimeId,
    runtimeType: runtimeType
  };
  return catalog;
}

// ---------------------------------------------------------------------------
// Realtime
// ---------------------------------------------------------------------------

function parseSessionEventPayload(raw: Raw | undefined): RemoteSessionEventPayload {
  const payload: RemoteSessionEventPayload = {};
  if (raw === undefined) {
    return payload;
  }
  const session = optRaw(raw, 'session');
  if (session !== undefined) {
    payload.session = parseSession(session);
  }
  const item = optRaw(raw, 'item');
  if (item !== undefined) {
    payload.item = parseTimelineItem(item);
  }
  payload.items = asRawArray(raw['items']).map((entry: Raw) => parseTimelineItem(entry));
  const state = optRaw(raw, 'state');
  if (state !== undefined) {
    payload.state = parseRuntimeState(state);
  }
  const notice = optRaw(raw, 'notice');
  if (notice !== undefined) {
    payload.notice = parseNotice(notice);
  }
  payload.notices = asRawArray(raw['notices']).map((entry: Raw) => parseNotice(entry));
  const capabilitySet = optRaw(raw, 'capabilitySet');
  if (capabilitySet !== undefined) {
    payload.capabilitySet = parseCapabilitySet(capabilitySet);
  }
  payload.catalogType = optString(raw, 'catalogType');
  payload.catalog = optRaw(raw, 'catalog');
  payload.eventCursor = optString(raw, 'eventCursor');
  return payload;
}

export function parseSessionEvent(raw: Raw): RemoteSessionEventEnvelope {
  const envelope: RemoteSessionEventEnvelope = {
    protocolVersion: str(raw, 'protocolVersion', ''),
    eventId: str(raw, 'eventId', ''),
    sequence: num(raw, 'sequence', 0),
    cursor: str(raw, 'cursor', ''),
    type: str(raw, 'type', ''),
    sessionId: str(raw, 'sessionId', ''),
    emittedAt: optString(raw, 'emittedAt'),
    payload: parseSessionEventPayload(optRaw(raw, 'payload'))
  };
  return envelope;
}

export function parseWsTicket(raw: Raw): RemoteWsTicket {
  const ticket: RemoteWsTicket = {
    ticket: str(raw, 'ticket', ''),
    expiresAt: str(raw, 'expiresAt', ''),
    serverTime: str(raw, 'serverTime', '')
  };
  return ticket;
}

export function parseDashboardSnapshot(raw: Raw): RemoteDashboardSnapshot | undefined {
  if (str(raw, 'type', '') !== 'dashboard.snapshot') {
    return undefined;
  }
  const sessionPages = optRaw(raw, 'sessionPages');
  if (sessionPages === undefined) {
    return undefined;
  }
  const activePage = optRaw(sessionPages, 'active');
  const archivedPage = optRaw(sessionPages, 'archived');
  if (activePage === undefined || archivedPage === undefined) {
    return undefined;
  }
  const snapshot: RemoteDashboardSnapshot = {
    devices: asRawArray(raw['connectors']).map((item: Raw) => parseDevice(item)),
    projects: asRawArray(raw['projects']).map((item: Raw) => parseProject(item)),
    sessions: asRawArray(raw['sessions']).map((item: Raw) => parseSession(item)),
    activePage: { hasMore: bool(activePage, 'hasMore', false), nextCursor: optString(activePage, 'nextCursor') },
    archivedPage: { hasMore: bool(archivedPage, 'hasMore', false), nextCursor: optString(archivedPage, 'nextCursor') },
    serverTime: optString(raw, 'serverTime')
  };
  return snapshot;
}

export function parseEventRecovery(raw: Raw, fallbackCursor: string): RemoteEventRecoveryResponse {
  const response: RemoteEventRecoveryResponse = {
    events: asRawArray(raw['events']).map((item: Raw) => parseSessionEvent(item)),
    nextCursor: str(raw, 'nextCursor', fallbackCursor),
    snapshotRequired: bool(raw, 'snapshotRequired', false),
    serverTime: optString(raw, 'serverTime')
  };
  return response;
}

/** 游标 `seq:N` → N；非法返回 undefined。 */
export function eventCursorSequence(cursor: string | undefined): number | undefined {
  if (cursor === undefined || !cursor.startsWith('seq:')) {
    return undefined;
  }
  const value = cursor.substring(4);
  if (value.length === 0 || (value.length > 1 && value.startsWith('0'))) {
    return undefined;
  }
  if (!/^\d+$/.test(value)) {
    return undefined;
  }
  return Number.parseInt(value, 10);
}

// ---------------------------------------------------------------------------
// Files / terminal / attachments
// ---------------------------------------------------------------------------

export function parseDirectoryEntry(raw: Raw): RemoteDirectoryEntry {
  const entry: RemoteDirectoryEntry = {
    name: str(raw, 'name', 'Untitled'),
    path: str(raw, 'path', ''),
    type: str(raw, 'type', 'other'),
    size: optNumber(raw, 'size')
  };
  return entry;
}

export function parseTextFile(raw: Raw): RemoteTextFile {
  const file: RemoteTextFile = {
    path: str(raw, 'path', ''),
    name: str(raw, 'name', 'Untitled'),
    size: num(raw, 'size', 0),
    sha256: str(raw, 'sha256', ''),
    encoding: str(raw, 'encoding', 'utf8'),
    content: str(raw, 'content', ''),
    truncated: bool(raw, 'truncated', false),
    binary: bool(raw, 'binary', false),
    serverTime: str(raw, 'serverTime', '')
  };
  return file;
}

export function parseTerminal(raw: Raw): RemoteTerminal {
  const label = str(raw, 'label', 'zsh');
  const terminal: RemoteTerminal = {
    terminalId: str(raw, 'terminalId', ''),
    sessionId: str(raw, 'sessionId', ''),
    label: label.length > 0 ? label : 'zsh',
    cwd: str(raw, 'cwd', ''),
    cols: num(raw, 'cols', 80),
    rows: num(raw, 'rows', 24),
    purpose: str(raw, 'purpose', 'user'),
    pid: optNumber(raw, 'pid'),
    status: str(raw, 'status', 'starting'),
    exitCode: optNumber(raw, 'exitCode'),
    scrollbackBytes: num(raw, 'scrollbackBytes', 0),
    scrollbackSeq: num(raw, 'scrollbackSeq', 0)
  };
  return terminal;
}

export function parseUploadedAttachment(raw: Raw): RemoteUploadedAttachment {
  const attachment: RemoteUploadedAttachment = {
    fileId: str(raw, 'fileId', ''),
    name: str(raw, 'name', 'attachment'),
    mediaType: str(raw, 'mediaType', ''),
    size: num(raw, 'size', 0),
    sha256: optString(raw, 'sha256')
  };
  return attachment;
}

export interface AttachmentDownloadPayload {
  fileId: string;
  sessionId: string;
  path: string;
  name: string;
  size: number;
  sha256: string;
  contentBase64: string;
  createdAt?: string;
  serverTime?: string;
}

export function parseAttachmentDownload(raw: Raw): AttachmentDownloadPayload {
  const payload: AttachmentDownloadPayload = {
    fileId: str(raw, 'fileId', ''),
    sessionId: str(raw, 'sessionId', ''),
    path: str(raw, 'path', ''),
    name: str(raw, 'name', ''),
    size: num(raw, 'size', -1),
    sha256: str(raw, 'sha256', ''),
    contentBase64: str(raw, 'contentBase64', ''),
    createdAt: optString(raw, 'createdAt'),
    serverTime: optString(raw, 'serverTime')
  };
  return payload;
}

export function toDownloadedAttachment(
  payload: AttachmentDownloadPayload, fileId: string, sessionId: string, bytes: Uint8Array
): RemoteDownloadedAttachment {
  const name = payload.name.length > 0 ? payload.name : fileId;
  const result: RemoteDownloadedAttachment = {
    fileId: payload.fileId.length > 0 ? payload.fileId : fileId,
    sessionId: payload.sessionId.length > 0 ? payload.sessionId : sessionId,
    path: payload.path,
    name: name,
    size: payload.size,
    sha256: payload.sha256,
    bytes: bytes,
    createdAt: payload.createdAt,
    serverTime: payload.serverTime
  };
  return result;
}
