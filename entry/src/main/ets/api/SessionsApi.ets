/**
 * 会话 API（对应 Android `api/SessionsApi.kt`，1032 行）。
 *
 * 覆盖：项目 CRUD、会话列表/归档/已读、快照、时间线（history/changes）、
 * runtime 状态/能力/目录/命令/选型、消息与 steer、中断、接管、审批响应、
 * 附件上传/下载（含 base64 + size + sha256 三重校验）。
 */

import { ApiClient, UploadFilePart } from './ApiClient';
import { urlEncode } from './ApiUrls';
import {
  AttachmentTransferException, AttachmentTransferFailure, RemoteAttachmentRef, RemoteDownloadedAttachment,
  RemoteProject, RemoteProjectCreateResponse, RemoteProjectResponse,
  RemoteRpcResponse, RemoteRuntimeModelCatalogResponse, RemoteRuntimeNoticeListResponse,
  RemoteRuntimePermissionCatalogResponse, RemoteSession, RemoteSessionCommand,
  RemoteSessionCommandListResponse, RemoteSessionCommandResponse, RemoteSessionCreateAndStartRequest,
  RemoteSessionCreateResponse, RemoteSessionPage, RemoteSessionsMutationResponse, RemoteSessionSelectionPatchResponse,
  RemoteSessionShareResponse, RemoteSessionSnapshot, RemoteSessionTimelinePage,
  RemoteSessionRuntimeStateResponse, RemoteTimelineItem, RemoteUploadedAttachment
} from '../model/Types';
import {
  asRawArray, asStringArray, emptyRaw, optRaw, optString, parseAttachmentDownload, parseCapabilitySet,
  parseModelCatalog, parseNotice, parsePermissionCatalog, parseProject, parseRuntimeState, parseSession,
  parseTimelineItem, parseTimelinePage, parseTimelineSnapshot, parseUploadedAttachment,
  Raw, str, toDownloadedAttachment
} from './Parse';
import { base64Decode, sha256Hex } from '../utils/Codec';

const CREATE_AND_START_READ_TIMEOUT_SECONDS: number = 75;
const MAX_ATTACHMENT_DOWNLOAD_BYTES: number = 25 * 1024 * 1024;
const MAX_ATTACHMENT_DOWNLOAD_BASE64_CHARS: number = 34952536;

export class SessionsApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  // -------------------------------------------------------------------------
  // Projects
  // -------------------------------------------------------------------------

  async listProjects(serverUrl: string, token: string): Promise<RemoteProject[]> {
    const raw = await this.client.getJson(serverUrl, '/projects', token) as Raw;
    return asRawArray(raw['projects']).map((item: Raw) => parseProject(item));
  }

  async createProject(
    serverUrl: string, token: string, name: string, connectorId: string, workspacePath: string,
    manuallyCreated: boolean = true
  ): Promise<RemoteProjectCreateResponse> {
    const body: Record<string, Object> = {
      'name': name,
      'connectorId': connectorId,
      'workspacePath': workspacePath,
      'manuallyCreated': manuallyCreated
    };
    const raw = await this.client.postJson(serverUrl, '/projects', body, token) as Raw;
    const response: RemoteProjectCreateResponse = {
      project: parseProject(optRaw(raw, 'project') ?? emptyRaw()),
      attachedSessions: typeof raw['attachedSessions'] === 'number' ? raw['attachedSessions'] as number : 0,
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async updateProject(
    serverUrl: string, token: string, projectId: string, name?: string, pinned?: boolean
  ): Promise<RemoteProjectResponse> {
    const body: Record<string, Object> = emptyRaw();
    if (name !== undefined) {
      body['name'] = name;
    }
    if (pinned !== undefined) {
      body['pinned'] = pinned;
    }
    const raw = await this.client.patchJson(
      serverUrl, `/projects/${urlEncode(projectId)}`, body, token) as Raw;
    const response: RemoteProjectResponse = {
      project: parseProject(optRaw(raw, 'project') ?? emptyRaw()),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async archiveAllProjectSessions(
    serverUrl: string, token: string, projectId: string, archived: boolean, scope: string
  ): Promise<RemoteSession[]> {
    const body: Record<string, Object> = { 'archived': archived, 'scope': scope };
    const raw = await this.client.postJson(
      serverUrl, `/projects/${urlEncode(projectId)}/sessions/archive-all`, body, token) as Raw;
    return asRawArray(raw['sessions']).map((item: Raw) => parseSession(item));
  }

  // -------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------

  /**
   * 会话列表**带分页信息**的版本：`{sessions, hasMore, nextCursor}`。
   *
   * 对应上游 `SessionsApi.kt` 的 `listSessions(): RemoteSessionPage`。
   * `cursor` 是**服务端自定义的不透明串**（真实服务端是 base64url 编码的 JSON 游标，
   * 内含 pinned/sortAt/orderSeq/updatedSeq/sessionId），只原样回传、不解析内部结构 ——
   * 下一页的入参就是响应里的 `nextCursor`；最后一页服务端返回 `hasMore=false` 且 `nextCursor` 为空。
   */
  async listSessionPage(
    serverUrl: string, token: string, archived: boolean, limit: number = 100, cursor?: string
  ): Promise<RemoteSessionPage> {
    const raw = await this.client.getJson(
      serverUrl, this.sessionListPath(archived, limit, cursor), token) as Raw;
    const page: RemoteSessionPage = {
      sessions: asRawArray(raw['sessions']).map((item: Raw) => parseSession(item)),
      hasMore: raw['hasMore'] === true,
      nextCursor: optString(raw, 'nextCursor'),
      serverTime: optString(raw, 'serverTime')
    };
    return page;
  }

  /** 只取会话数组（历史调用点用，签名不变）；要分页信息请用 `listSessionPage`。 */
  async listSessions(
    serverUrl: string, token: string, archived: boolean, limit: number = 100, cursor?: string
  ): Promise<RemoteSession[]> {
    const page = await this.listSessionPage(serverUrl, token, archived, limit, cursor);
    return page.sessions;
  }

  private sessionListPath(archived: boolean, limit: number, cursor?: string): string {
    let path = `/sessions?archived=${archived}&limit=${limit}`;
    if (cursor !== undefined && cursor.length > 0) {
      path += `&cursor=${urlEncode(cursor)}`;
    }
    return path;
  }

  async createAndStartSession(
    serverUrl: string, token: string, request: RemoteSessionCreateAndStartRequest
  ): Promise<RemoteSessionCreateResponse> {
    const body: Record<string, Object> = {
      'connectorId': request.connectorId,
      'projectId': request.projectId,
      'runtime': request.runtimeType,
      'content': request.content
    };
    if (request.runtimeId.length > 0 && request.runtimeId !== request.runtimeType) {
      body['runtimeId'] = request.runtimeId;
    }
    if (request.title !== undefined && request.title.trim().length > 0) {
      body['title'] = request.title;
    }
    if (request.cwd !== undefined && request.cwd.trim().length > 0) {
      body['cwd'] = request.cwd;
    }
    const selectionKeys = Object.keys(request.selections);
    const selections: Record<string, Object> = {};
    let selectionCount = 0;
    for (let i = 0; i < selectionKeys.length; i++) {
      const key = selectionKeys[i];
      if (request.selections[key].length > 0) {
        selections[key] = request.selections[key];
        selectionCount += 1;
      }
    }
    if (selectionCount > 0) {
      body['selections'] = selections;
    }
    // R51：运行时专有选项（目前只有 DSH 的 `agentPreset`）。
    // ⚠️ 空表**不发**：连接器只认 `agentPreset` 这一个键，发个空对象没意义；
    //  而 `{agentPreset: ''}` 会被 bridge 的 `validatePreset()` 判成 INVALID_PARAMS（会话建不出来）。
    if (request.runtimeOptions !== undefined) {
      const optionKeys = Object.keys(request.runtimeOptions);
      const runtimeOptions: Record<string, Object> = {};
      let optionCount = 0;
      for (let i = 0; i < optionKeys.length; i++) {
        const key = optionKeys[i];
        if (request.runtimeOptions[key].length > 0) {
          runtimeOptions[key] = request.runtimeOptions[key];
          optionCount += 1;
        }
      }
      if (optionCount > 0) {
        body['runtimeOptions'] = runtimeOptions;
      }
    }
    if (request.attachments.length > 0) {
      const attachments: Object[] = [];
      for (let i = 0; i < request.attachments.length; i++) {
        const attachment = request.attachments[i];
        const item: Record<string, Object> = {
          'fileId': attachment.fileId,
          'name': attachment.name,
          'mediaType': attachment.mediaType,
          'size': attachment.size,
          'sha256': attachment.sha256,
          'contentBase64': attachment.contentBase64
        };
        attachments.push(item);
      }
      body['attachments'] = attachments;
    }
    if (request.clientMessageId !== undefined && request.clientMessageId.trim().length > 0) {
      body['clientMessageId'] = request.clientMessageId;
    }
    const raw = await this.client.postJson(
      serverUrl, '/sessions/create-and-start', body, token, CREATE_AND_START_READ_TIMEOUT_SECONDS) as Raw;
    const response: RemoteSessionCreateResponse = {
      session: parseSession(optRaw(raw, 'session') ?? emptyRaw())
    };
    return response;
  }

  async patchSession(
    serverUrl: string, token: string, sessionId: string, title?: string, pinned?: boolean,
    archived?: boolean
  ): Promise<RemoteSession> {
    const body: Record<string, Object> = emptyRaw();
    if (title !== undefined) {
      body['title'] = title;
    }
    if (pinned !== undefined) {
      body['pinned'] = pinned;
    }
    if (archived !== undefined) {
      body['archived'] = archived;
    }
    const raw = await this.client.patchJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/meta`, body, token) as Raw;
    return parseSession(optRaw(raw, 'session') ?? emptyRaw());
  }

  async createSessionShare(
    serverUrl: string, token: string, sessionId: string, scope: string, itemIds: string[]
  ): Promise<RemoteSessionShareResponse> {
    const body: Record<string, Object> = { 'scope': scope, 'itemIds': itemIds };
    const raw = await this.client.postJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/shares`, body, token) as Raw;
    const response: RemoteSessionShareResponse = {
      shareId: str(raw, 'shareId', ''),
      sharePath: str(raw, 'sharePath', ''),
      shareUrl: str(raw, 'shareUrl', ''),
      scope: str(raw, 'scope', ''),
      createdAt: str(raw, 'createdAt', '')
    };
    return response;
  }

  async archiveSessions(serverUrl: string, token: string, ids: string[]): Promise<RemoteSessionsMutationResponse> {
    const raw = await this.client.postJsonArray(serverUrl, '/sessions/archive', ids, token) as Raw;
    return this.toMutationResponse(raw);
  }

  async unarchiveSessions(serverUrl: string, token: string, ids: string[]): Promise<RemoteSessionsMutationResponse> {
    const raw = await this.client.postJsonArray(serverUrl, '/sessions/unarchive', ids, token) as Raw;
    return this.toMutationResponse(raw);
  }

  async markSessionsRead(serverUrl: string, token: string, ids: string[]): Promise<RemoteSessionsMutationResponse> {
    const raw = await this.client.postJsonArray(serverUrl, '/sessions/read', ids, token) as Raw;
    return this.toMutationResponse(raw);
  }

  async markSessionRead(serverUrl: string, token: string, sessionId: string): Promise<RemoteSession> {
    const response = await this.markSessionsRead(serverUrl, token, [sessionId]);
    for (let i = 0; i < response.sessions.length; i++) {
      if (response.sessions[i].id === sessionId) {
        return response.sessions[i];
      }
    }
    throw new Error('标记已读的响应里没有该会话。');
  }

  async archiveAllDeviceSessions(
    serverUrl: string, token: string, deviceId: string, archived: boolean, scope: string
  ): Promise<RemoteSession[]> {
    const body: Record<string, Object> = { 'archived': archived, 'scope': scope };
    const raw = await this.client.postJson(
      serverUrl, `/connectors/${urlEncode(deviceId)}/sessions/archive-all`, body, token) as Raw;
    return asRawArray(raw['sessions']).map((item: Raw) => parseSession(item));
  }

  // -------------------------------------------------------------------------
  // Timeline / snapshot
  // -------------------------------------------------------------------------

  async getSessionTimelineHistory(
    serverUrl: string, token: string, sessionId: string, beforeOrderSeq: number, limit: number = 100
  ): Promise<RemoteSessionTimelinePage> {
    const raw = await this.client.getJson(
      serverUrl,
      `/sessions/${urlEncode(sessionId)}/timeline?mode=history&beforeOrderSeq=${beforeOrderSeq}&limit=${limit}`,
      token) as Raw;
    return parseTimelinePage(raw);
  }

  async getSessionSnapshot(
    serverUrl: string, token: string, sessionId: string, limit: number = 100
  ): Promise<RemoteSessionSnapshot> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/snapshot?limit=${limit}`, token) as Raw;
    const session = parseSession(optRaw(raw, 'session') ?? emptyRaw());
    const catalogs = optRaw(raw, 'catalogs');
    const snapshot: RemoteSessionSnapshot = {
      session: session,
      state: optRaw(raw, 'state') !== undefined ? parseRuntimeState(optRaw(raw, 'state') as Raw) : undefined,
      timeline: parseTimelineSnapshot(optRaw(raw, 'timeline')),
      notices: asRawArray(raw['notices']).map((item: Raw) => parseNotice(item)),
      effectiveCapabilities: parseCapabilitySet(optRaw(raw, 'effectiveCapabilities')),
      runtimeCapabilities: parseCapabilitySet(optRaw(raw, 'runtimeCapabilities')),
      eventCursor: str(raw, 'eventCursor', 'seq:0'),
      serverTime: optString(raw, 'serverTime')
    };
    if (catalogs !== undefined) {
      const modelRaw = optRaw(catalogs, 'model');
      const permissionRaw = optRaw(catalogs, 'permission');
      snapshot.catalogs = {
        model: modelRaw !== undefined ? parseModelCatalog(modelRaw, session.runtimeId) : undefined,
        permission: permissionRaw !== undefined ? parsePermissionCatalog(permissionRaw, session.runtimeId) : undefined
      };
    }
    return snapshot;
  }

  // -------------------------------------------------------------------------
  // Runtime state / capabilities / catalogs / commands
  // -------------------------------------------------------------------------

  async getSessionRuntimeState(
    serverUrl: string, token: string, sessionId: string
  ): Promise<RemoteSessionRuntimeStateResponse> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/state`, token) as Raw;
    const response: RemoteSessionRuntimeStateResponse = {
      state: parseRuntimeState(optRaw(raw, 'state') ?? emptyRaw()),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async getSessionRuntimeCapabilities(serverUrl: string, token: string, sessionId: string): Promise<Raw> {
    return await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/capabilities`, token) as Raw;
  }

  async getSessionRuntimeNotices(
    serverUrl: string, token: string, sessionId: string
  ): Promise<RemoteRuntimeNoticeListResponse> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/notices`, token) as Raw;
    const response: RemoteRuntimeNoticeListResponse = {
      notices: asRawArray(raw['notices']).map((item: Raw) => parseNotice(item)),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async getSessionRuntimeModelCatalog(
    serverUrl: string, token: string, sessionId: string
  ): Promise<RemoteRuntimeModelCatalogResponse> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/catalogs/model`, token) as Raw;
    const response: RemoteRuntimeModelCatalogResponse = {
      catalog: parseModelCatalog(optRaw(raw, 'catalog')),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async getSessionRuntimePermissionCatalog(
    serverUrl: string, token: string, sessionId: string
  ): Promise<RemoteRuntimePermissionCatalogResponse> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/catalogs/permission`, token) as Raw;
    const response: RemoteRuntimePermissionCatalogResponse = {
      catalog: parsePermissionCatalog(optRaw(raw, 'catalog')),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async patchSessionRuntimeSelections(
    serverUrl: string, token: string, sessionId: string, selections: Record<string, string>
  ): Promise<RemoteSessionSelectionPatchResponse> {
    const selectionBody: Record<string, Object> = {};
    const keys = Object.keys(selections);
    for (let i = 0; i < keys.length; i++) {
      selectionBody[keys[i]] = selections[keys[i]];
    }
    const body: Record<string, Object> = { 'selections': selectionBody };
    const raw = await this.client.patchJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/selections`, body, token) as Raw;
    const response: RemoteSessionSelectionPatchResponse = {
      ok: raw['ok'] === true,
      state: optRaw(raw, 'state') !== undefined ? parseRuntimeState(optRaw(raw, 'state') as Raw) : undefined,
      connectorResult: optRaw(raw, 'connectorResult'),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async getSessionRuntimeCommands(
    serverUrl: string, token: string, sessionId: string
  ): Promise<RemoteSessionCommandListResponse> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/commands`, token) as Raw;
    const commands: RemoteSessionCommand[] = [];
    const items = asRawArray(raw['commands']);
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const command: RemoteSessionCommand = {
        id: str(item, 'id', ''),
        title: str(item, 'title', ''),
        description: optString(item, 'description'),
        aliases: asStringArray(item['aliases']),
        category: optString(item, 'category'),
        scope: str(item, 'scope', 'session'),
        enabled: item['enabled'] !== false,
        disabledReason: optString(item, 'disabledReason'),
        acceptsArgs: item['acceptsArgs'] === true,
        argsSchema: optRaw(item, 'argsSchema'),
        metadata: optRaw(item, 'metadata') ?? emptyRaw()
      };
      commands.push(command);
    }
    const response: RemoteSessionCommandListResponse = {
      commands: commands,
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async executeSessionRuntimeCommand(
    serverUrl: string, token: string, sessionId: string, command: string, args: string[] = [], raw?: string
  ): Promise<RemoteSessionCommandResponse> {
    const body: Record<string, Object> = { 'command': command };
    if (args.length > 0) {
      body['args'] = args;
    }
    if (raw !== undefined && raw.trim().length > 0) {
      body['raw'] = raw;
    }
    const payload = await this.client.postJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/commands`, body, token) as Raw;
    const response: RemoteSessionCommandResponse = {
      command: str(payload, 'command', ''),
      ok: payload['ok'] !== false,
      code: optString(payload, 'code'),
      message: optString(payload, 'message'),
      result: payload['result'],
      session: optRaw(payload, 'session') !== undefined
        ? parseSession(optRaw(payload, 'session') as Raw) : undefined,
      serverTime: optString(payload, 'serverTime')
    };
    return response;
  }

  // -------------------------------------------------------------------------
  // Messaging
  // -------------------------------------------------------------------------

  private async sendRuntimeContent(
    serverUrl: string, token: string, sessionId: string, endpoint: string, content: string,
    clientMessageId: string, attachments: RemoteAttachmentRef[]
  ): Promise<RemoteRpcResponse> {
    const body: Record<string, Object> = { 'content': content, 'clientMessageId': clientMessageId };
    if (attachments.length > 0) {
      const list: Object[] = [];
      for (let i = 0; i < attachments.length; i++) {
        const ref: Record<string, Object> = { 'fileId': attachments[i].fileId };
        list.push(ref);
      }
      body['attachments'] = list;
    }
    const raw = await this.client.postJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/${endpoint}`, body, token) as Raw;
    return this.toRpcResponse(raw);
  }

  async sendSessionMessage(
    serverUrl: string, token: string, sessionId: string, content: string, clientMessageId: string,
    attachments: RemoteAttachmentRef[] = []
  ): Promise<RemoteRpcResponse> {
    return await this.sendRuntimeContent(
      serverUrl, token, sessionId, 'messages', content, clientMessageId, attachments);
  }

  async steerSession(
    serverUrl: string, token: string, sessionId: string, content: string, clientMessageId: string,
    attachments: RemoteAttachmentRef[] = []
  ): Promise<RemoteRpcResponse> {
    return await this.sendRuntimeContent(
      serverUrl, token, sessionId, 'steer', content, clientMessageId, attachments);
  }

  async interruptSession(serverUrl: string, token: string, sessionId: string): Promise<RemoteRpcResponse> {
    const raw = await this.client.postJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/runtime/interrupt`, emptyRaw(), token) as Raw;
    return this.toRpcResponse(raw);
  }

  async enableTakeover(serverUrl: string, token: string, sessionId: string): Promise<RemoteSession> {
    const raw = await this.client.postJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/takeover`, emptyRaw(), token) as Raw;
    return parseSession(optRaw(raw, 'session') ?? emptyRaw());
  }

  async disableTakeover(serverUrl: string, token: string, sessionId: string): Promise<RemoteSession> {
    const raw = await this.client.deleteJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/takeover`, token) as Raw;
    return parseSession(optRaw(raw, 'session') ?? emptyRaw());
  }

  async respondRuntimeNotice(
    serverUrl: string, token: string, sessionId: string, noticeId: string, actionId: string,
    input?: Record<string, Object>
  ): Promise<RemoteRpcResponse> {
    const body: Record<string, Object> = { 'actionId': actionId };
    if (input !== undefined) {
      body['input'] = input;
    }
    const raw = await this.client.postJson(
      serverUrl,
      `/sessions/${urlEncode(sessionId)}/runtime/notices/${urlEncode(noticeId)}/respond`,
      body, token) as Raw;
    return this.toRpcResponse(raw);
  }

  // -------------------------------------------------------------------------
  // Attachments
  // -------------------------------------------------------------------------

  async uploadSessionAttachments(
    serverUrl: string, token: string, sessionId: string, files: UploadFilePart[]
  ): Promise<RemoteUploadedAttachment[]> {
    const raw = await this.client.postMultipart(
      serverUrl, `/sessions/${urlEncode(sessionId)}/attachments`, files, token) as Raw;
    return asRawArray(raw['attachments']).map((item: Raw) => parseUploadedAttachment(item));
  }

  /**
   * 下载附件并做三重校验：base64 可解、字节数一致、sha256 一致。
   * 任一不过抛 AttachmentTransferException（带 failure 原因）。
   */
  async downloadSessionAttachment(
    serverUrl: string, token: string, sessionId: string, fileId: string
  ): Promise<RemoteDownloadedAttachment> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/attachments/${urlEncode(fileId)}`, token) as Raw;
    const payload = parseAttachmentDownload(raw);
    if (payload.size < 0 || payload.size > MAX_ATTACHMENT_DOWNLOAD_BYTES ||
      payload.contentBase64.length > MAX_ATTACHMENT_DOWNLOAD_BASE64_CHARS) {
      throw new AttachmentTransferException(AttachmentTransferFailure.SizeMismatch);
    }
    let bytes: Uint8Array;
    try {
      bytes = base64Decode(payload.contentBase64);
    } catch (error) {
      throw new AttachmentTransferException(
        AttachmentTransferFailure.InvalidBase64, undefined, String(error));
    }
    if (bytes.length !== payload.size) {
      throw new AttachmentTransferException(AttachmentTransferFailure.SizeMismatch);
    }
    const expected = payload.sha256.toLowerCase();
    const actual = await sha256Hex(bytes);
    if (expected.length !== 64 || actual !== expected) {
      throw new AttachmentTransferException(AttachmentTransferFailure.Sha256Mismatch);
    }
    return toDownloadedAttachment(payload, fileId, sessionId, bytes);
  }

  // -------------------------------------------------------------------------
  // Parsing helpers
  // -------------------------------------------------------------------------

  parseTimelineItem(raw: Raw): RemoteTimelineItem {
    return parseTimelineItem(raw);
  }

  private toMutationResponse(raw: Raw): RemoteSessionsMutationResponse {
    const response: RemoteSessionsMutationResponse = {
      sessions: asRawArray(raw['sessions']).map((item: Raw) => parseSession(item)),
      notFound: asStringArray(raw['notFound']),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  private toRpcResponse(raw: Raw): RemoteRpcResponse {
    const error = optRaw(raw, 'error');
    const response: RemoteRpcResponse = {
      ok: raw['ok'] === true,
      error: error !== undefined
        ? { code: optString(error, 'code'), message: optString(error, 'message') }
        : undefined
    };
    return response;
  }
}
