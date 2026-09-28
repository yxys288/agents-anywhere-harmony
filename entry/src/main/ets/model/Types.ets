/**
 * Agents Anywhere v2 线格式类型（wire DTO）。
 *
 * 本文件是 Android 端 `api/*Dtos.kt` 的 1:1 移植，字段名与 JSON 键保持完全一致，
 * 以便 `JSON.parse(text) as Xxx` 直接落型。改字段名前请先核对服务端
 * `server/agent_server/api/*.py`。
 */

/** 动态 JSON 对象（对应 Kotlin 的 `Map<String, Any?>` / `JSONObject`）。 */
export type JsonMap = Record<string, Object>;

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

export interface AuthResponse {
  userId: string;
  role: string;
  accessToken: string;
  tokenType: string;
  serverTime: string;
  email?: string;
  displayName?: string;
  emailVerified?: boolean;
}

export interface AuthMeResponse {
  userId: string;
  role: string;
  disabled: boolean;
  avatar?: string;
  serverTime: string;
  email?: string;
  displayName?: string;
  emailVerified?: boolean;
}

export interface AuthConfigResponse {
  needsBootstrap: boolean;
  registrationOpen: boolean;
  oauthRegistrationOpen: boolean;
  oauthEnabled: boolean;
  oauthProviderLabel?: string;
  setupTokenExpiresAt?: string;
  serverTime: string;
  emailVerificationRequired?: boolean;
}

export interface OAuthTokenResponse {
  access_token: string;
  token_type?: string;
  expires_in: number;
  scope?: string;
  refresh_token?: string;
}

export interface MobileLoginStatusResponse {
  status: string;
  userId?: string;
  deviceName?: string;
  expiresAt?: string;
  requestedAt?: string;
  approvedAt?: string;
  serverTime: string;
}

export interface MobileLoginExchangeResponse {
  auth: AuthResponse;
  refreshToken: string;
  expiresAt: string;
  serverTime: string;
}

export interface EmailCodeResponse {
  expiresIn: number;
  retryAfter: number;
}

// ---------------------------------------------------------------------------
// Devices（服务端叫 connector，客户端一律称 device）
// ---------------------------------------------------------------------------

export interface RemoteDevice {
  id: string;
  name: string;
  deviceOs?: string;
  status: string;
  lastSeenAt?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface RemoteDeviceRuntime {
  connectorId: string;
  runtimeId: string;
  runtimeType: string;
  displayName: string;
  present: boolean;
  configured: boolean;
  active: boolean;
  status: string;
  discovery?: JsonMap;
  metadata?: JsonMap;
  schema?: JsonMap;
  uiSchema?: JsonMap;
  config?: JsonMap;
  error?: JsonMap;
  lastDiscoveredAt?: string;
  updatedAt?: string;
}

export interface RemoteDeviceRuntimeList {
  connectorId: string;
  runtimes: RemoteDeviceRuntime[];
  serverTime?: string;
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

export interface ProjectSessionCounts {
  active: number;
  archived: number;
}

export interface RemoteProject {
  id: string;
  userId: string;
  connectorId: string;
  name: string;
  workspacePath: string;
  pinned: boolean;
  pinnedAt?: string;
  activeSessionCount: number;
  lastActivityAt?: string;
  createdAt: string;
  updatedAt: string;
  manuallyCreated?: boolean;
  sidebarSessionCounts?: ProjectSessionCounts;
}

export interface RemoteProjectResponse {
  project: RemoteProject;
  serverTime?: string;
}

export interface RemoteProjectCreateResponse {
  project: RemoteProject;
  attachedSessions: number;
  serverTime?: string;
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

export interface RemoteSession {
  id: string;
  connectorId: string;
  projectId?: string;
  connectorStatus: string;
  runtime: string;
  externalSessionId?: string;
  title?: string;
  cwd?: string;
  status: string;
  takeover: boolean;
  pinned: boolean;
  pinnedAt?: string;
  archived: boolean;
  archivedAt?: string;
  unread: boolean;
  lastReadSeq: number;
  lastSyncedAt?: string;
  sourceObservedAt?: string;
  lastActivityAt?: string;
  lastItemAt?: string;
  lastItemOrderSeq?: number;
  sortAt?: string;
  updatedSeq: number;
  runtimeId?: string;
  runtimeType?: string;
  runtimeName?: string;
  runtimeDisplayName?: string;
  displayName?: string;
  name?: string;
}

export interface RemoteSessionPage {
  sessions: RemoteSession[];
  hasMore: boolean;
  nextCursor?: string;
  serverTime?: string;
}

export interface RemoteSessionsMutationResponse {
  sessions: RemoteSession[];
  notFound: string[];
  serverTime?: string;
}

export interface RemoteInlineAttachmentRef {
  fileId: string;
  name: string;
  mediaType: string;
  size: number;
  sha256: string;
  contentBase64: string;
}

export interface RemoteSessionCreateAndStartRequest {
  connectorId: string;
  projectId: string;
  runtimeType: string;
  runtimeId: string;
  title?: string;
  cwd?: string;
  content: string;
  selections: Record<string, string>;
  /**
   * 运行时**专有**选项（R51）。
   *
   * 目前只有一个键：DSH 的 `agentPreset`（会话级 Agent 预设 / 模式）。
   * 契约：`connector/connector/runtimes/dsh/runtime.py:304-311` ——
   * **只认 `agentPreset`**（其它键直接 `RuntimeUnsupportedError`），缺省时回落到连接器配置的
   * `defaultAgentPreset`；bridge 侧 `validatePreset()` 会拒空串/未知 id。
   * ⇒ 没选预设时**不要带这个字段**（见 `model/AgentPreset.runtimeOptionsForPreset`）。
   */
  runtimeOptions?: Record<string, string>;
  attachments: RemoteInlineAttachmentRef[];
  clientMessageId?: string;
}

export interface RemoteSessionCreateResponse {
  session: RemoteSession;
}

export interface RemoteSessionShareResponse {
  shareId: string;
  sharePath: string;
  shareUrl: string;
  scope: string;
  createdAt: string;
}

export interface RemoteTimelineItem {
  id: string;
  sessionId: string;
  type: string;
  status: string;
  role?: string;
  text: string;
  content: JsonMap;
  source: JsonMap;
  orderSeq: number;
  revision: number;
  updatedSeq: number;
  createdAt: string;
  updatedAt?: string;
  contentHash?: string;
}

export interface RemoteSessionTimelinePage {
  sessionId: string;
  items: RemoteTimelineItem[];
  nextSeq: number;
  hasMore: boolean;
  serverTime?: string;
}

export interface RemoteSessionRuntimeState {
  sessionId: string;
  runtime: string;
  externalSessionId?: string;
  status: string;
  selections?: Record<string, string>;
  statusReason?: string;
  error?: JsonMap;
  metadata?: JsonMap;
  updatedSeq: number;
  createdAt?: string;
  updatedAt?: string;
  runtimeId?: string;
  runtimeType?: string;
  runtimeName?: string;
  runtimeDisplayName?: string;
  displayName?: string;
  name?: string;
}

export interface RemoteSessionRuntimeStateResponse {
  state: RemoteSessionRuntimeState;
  serverTime?: string;
}

export interface RemoteRuntimeNoticeBlocking {
  scope: string;
  targetId: string;
}

export interface RemoteRuntimeNoticeActionInput {
  required: boolean;
  schema?: JsonMap;
  uiSchema?: JsonMap;
}

export interface RemoteRuntimeNoticeAction {
  actionId: string;
  label: string;
  style: string;
  input?: RemoteRuntimeNoticeActionInput;
}

export interface RemoteRuntimeNotice {
  noticeId: string;
  type: string;
  sessionId: string;
  source?: JsonMap;
  title: string;
  message?: string;
  severity: string;
  status: string;
  interactionType?: string;
  blocking?: RemoteRuntimeNoticeBlocking;
  responseRequired: boolean;
  actions: RemoteRuntimeNoticeAction[];
  context?: JsonMap;
  metadata?: JsonMap;
  expiresAt?: string;
  revision: number;
  updatedSeq: number;
  createdAt?: string;
  updatedAt?: string;
  resolvedAt?: string;
}

export interface RemoteRuntimeNoticeListResponse {
  notices: RemoteRuntimeNotice[];
  serverTime?: string;
}

export interface RemoteSessionTimelineSnapshot {
  items: RemoteTimelineItem[];
  nextSeq: number;
  hasMore: boolean;
}

export interface RemoteSessionRuntimeCatalogs {
  model?: RemoteRuntimeModelCatalog;
  permission?: RemoteRuntimePermissionCatalog;
}

export interface RemoteSessionSnapshot {
  session: RemoteSession;
  state?: RemoteSessionRuntimeState;
  timeline: RemoteSessionTimelineSnapshot;
  notices: RemoteRuntimeNotice[];
  effectiveCapabilities: RemoteRuntimeCapabilitySet;
  runtimeCapabilities: RemoteRuntimeCapabilitySet;
  catalogs?: RemoteSessionRuntimeCatalogs;
  eventCursor: string;
  serverTime?: string;
}

export interface RemoteRpcResponse {
  ok: boolean;
  error?: RemoteRpcError;
}

export interface RemoteRpcError {
  code?: string;
  message?: string;
}

export interface RemoteSessionSelectionPatchResponse {
  ok: boolean;
  state?: RemoteSessionRuntimeState;
  connectorResult?: JsonMap;
  serverTime?: string;
}

export interface RemoteSessionCommand {
  id: string;
  title: string;
  description?: string;
  aliases: string[];
  category?: string;
  scope: string;
  enabled: boolean;
  disabledReason?: string;
  acceptsArgs: boolean;
  argsSchema?: JsonMap;
  metadata?: JsonMap;
}

export interface RemoteSessionCommandListResponse {
  commands: RemoteSessionCommand[];
  serverTime?: string;
}

export interface RemoteSessionCommandResponse {
  command: string;
  ok: boolean;
  code?: string;
  message?: string;
  result?: Object;
  session?: RemoteSession;
  serverTime?: string;
}

export interface RemoteUploadedAttachment {
  fileId: string;
  name: string;
  mediaType: string;
  size: number;
  sha256?: string;
}

export interface RemoteAttachmentRef {
  fileId: string;
}

export interface RemoteDownloadedAttachment {
  fileId: string;
  sessionId: string;
  path: string;
  name: string;
  size: number;
  sha256: string;
  bytes: Uint8Array;
  createdAt?: string;
  serverTime?: string;
}

// ---------------------------------------------------------------------------
// Runtime capabilities / catalogs
// ---------------------------------------------------------------------------

export interface RemoteRuntimeCapability {
  capabilityId: string;
  version: string;
  scope: string;
  runtime?: string;
  sessionId?: string;
  supported: boolean;
  available: boolean;
  allowed: boolean;
  unavailableReason?: string;
  parameters?: JsonMap;
  runtimeId?: string;
  runtimeType?: string;
}

export interface RemoteRuntimeCapabilitySet {
  revision: number;
  capabilities: RemoteRuntimeCapability[];
}

export interface RemoteRuntimeCapabilities {
  connectorId: string;
  capabilitySet: RemoteRuntimeCapabilitySet;
  serverTime?: string;
}

export interface RemoteRuntimeReasoning {
  id: string;
  selectionId: string;
  fullModelId?: string;
  displayName: string;
  description?: string;
  default: boolean;
  metadata?: JsonMap;
  enabled?: boolean;
  disabledReason?: string;
}

export interface RemoteRuntimeModel {
  id: string;
  selectionId?: string;
  displayName: string;
  description?: string;
  default: boolean;
  reasoningItems: RemoteRuntimeReasoning[];
  metadata?: JsonMap;
  enabled?: boolean;
  disabledReason?: string;
}

export interface RemoteRuntimeModelCatalog {
  runtime: string;
  revision: number;
  models: RemoteRuntimeModel[];
  runtimeId?: string;
  runtimeType?: string;
}

export interface RemoteRuntimeModelCatalogResponse {
  catalog: RemoteRuntimeModelCatalog;
  serverTime?: string;
}

export interface RemoteRuntimePermission {
  id: string;
  selectionId: string;
  displayName: string;
  description?: string;
  default: boolean;
  metadata?: JsonMap;
  enabled?: boolean;
  disabledReason?: string;
}

export interface RemoteRuntimePermissionCatalog {
  runtime: string;
  revision: number;
  permissions: RemoteRuntimePermission[];
  runtimeId?: string;
  runtimeType?: string;
}

export interface RemoteRuntimePermissionCatalogResponse {
  catalog: RemoteRuntimePermissionCatalog;
  serverTime?: string;
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

export interface RemoteDirectoryEntry {
  name: string;
  path: string;
  type: string;
  size?: number;
}

export interface RemoteDirectory {
  path: string;
  entries: RemoteDirectoryEntry[];
  truncated: boolean;
  targetType?: string;
}

export interface RemoteTextFile {
  path: string;
  name: string;
  size: number;
  sha256: string;
  encoding: string;
  content: string;
  truncated: boolean;
  binary: boolean;
  serverTime: string;
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

export interface RemoteTerminal {
  terminalId: string;
  sessionId: string;
  label: string;
  cwd: string;
  cols: number;
  rows: number;
  purpose: string;
  pid?: number;
  status: string;
  exitCode?: number;
  scrollbackBytes: number;
  scrollbackSeq: number;
}

// ---------------------------------------------------------------------------
// Realtime
// ---------------------------------------------------------------------------

export interface RemoteWsTicket {
  ticket: string;
  expiresAt: string;
  serverTime: string;
}

export interface RemoteSessionPageInfo {
  hasMore: boolean;
  nextCursor?: string;
}

export interface RemoteDashboardSnapshot {
  devices: RemoteDevice[];
  projects: RemoteProject[];
  sessions: RemoteSession[];
  activePage: RemoteSessionPageInfo;
  archivedPage: RemoteSessionPageInfo;
  serverTime?: string;
}

export interface RemoteSessionEventPayload {
  session?: RemoteSession;
  item?: RemoteTimelineItem;
  items?: RemoteTimelineItem[];
  state?: RemoteSessionRuntimeState;
  notice?: RemoteRuntimeNotice;
  notices?: RemoteRuntimeNotice[];
  capabilitySet?: RemoteRuntimeCapabilitySet;
  catalogType?: string;
  catalog?: JsonMap;
  eventCursor?: string;
}

export interface RemoteSessionEventEnvelope {
  protocolVersion?: string;
  eventId: string;
  sequence: number;
  cursor: string;
  type: string;
  sessionId: string;
  emittedAt?: string;
  payload?: RemoteSessionEventPayload;
}

export interface RemoteEventRecoveryResponse {
  events: RemoteSessionEventEnvelope[];
  nextCursor: string;
  snapshotRequired: boolean;
  serverTime?: string;
}

// ---------------------------------------------------------------------------
// 服务端事件类型常量（docs/api/realtime.md）
// ---------------------------------------------------------------------------

export class SessionEventType {
  static readonly SUBSCRIBED: string = 'session.subscribed';
  static readonly META_UPDATED: string = 'session.meta.updated';
  static readonly TIMELINE_ITEM_CREATED: string = 'timeline.item_created';
  static readonly TIMELINE_ITEM_UPDATED: string = 'timeline.item_updated';
  static readonly TIMELINE_SNAPSHOT: string = 'timeline.snapshot';
  static readonly RUNTIME_STATE_UPDATED: string = 'runtime.state.updated';
  static readonly RUNTIME_NOTICE_SNAPSHOT: string = 'runtime.notice.snapshot';
  static readonly RUNTIME_NOTICE_UPDATED: string = 'runtime.notice.updated';
  static readonly RUNTIME_CAPABILITY_UPDATED: string = 'runtime.capability.updated';
  static readonly RUNTIME_CATALOG_UPDATED: string = 'runtime.catalog.updated';
  static readonly RUNTIME_REFETCH_REQUIRED: string = 'runtime.refetch_required';
  static readonly SESSION_REFETCH_REQUIRED: string = 'session.refetch_required';
  // 兼容期旧事件名
  static readonly LEGACY_STATUS_CHANGED: string = 'session.status_changed';
  static readonly LEGACY_NOTICE_CREATED: string = 'notice.created';
  static readonly LEGACY_NOTICE_UPDATED: string = 'notice.updated';
  static readonly LEGACY_NOTICE_SNAPSHOT: string = 'notice.snapshot';
  static readonly KEEPALIVE: string = 'keepalive';
  static readonly DASHBOARD_SNAPSHOT: string = 'dashboard.snapshot';
}

/** 附件下载完整性校验的失败原因（对应 Kotlin 的 AttachmentTransferFailure）。 */
export enum AttachmentTransferFailure {
  InvalidBase64 = 'InvalidBase64',
  IncompleteUpload = 'IncompleteUpload',
  SizeMismatch = 'SizeMismatch',
  Sha256Mismatch = 'Sha256Mismatch'
}

export class AttachmentTransferException extends Error {
  failure: AttachmentTransferFailure;
  attachmentName?: string;

  constructor(failure: AttachmentTransferFailure, attachmentName?: string, cause?: string) {
    super(cause !== undefined ? `${failure}: ${cause}` : failure);
    this.failure = failure;
    this.attachmentName = attachmentName;
  }
}

export class ApiException extends Error {
  statusCode?: number;
  errorCode?: string;

  constructor(message: string, statusCode?: number, errorCode?: string) {
    super(message);
    this.statusCode = statusCode;
    this.errorCode = errorCode;
  }
}
