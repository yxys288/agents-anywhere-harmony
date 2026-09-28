/**
 * 实时通道（对应 Android `api/RealtimeApi.kt` + `feature/realtime/*`）。
 *
 * 两条 WS：
 * - 工作台：`/api/v2/dashboard/ws?ticket=` → 连接即收到一份 `dashboard.snapshot`；
 * - 会话：`/api/v2/sessions/{id}/ws?ticket=` → `session.subscribed` + 增量事件，
 *  断线后用 `GET /sessions/{id}/events?after=seq:N` 做游标恢复。
 *
 * 票据由 `POST /api/v2/ws-ticket` 颁发（body: clientId + scope）。
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiClient } from './ApiClient';
import { urlEncode, webSocketApiUrl } from './ApiUrls';
import {
  RemoteDashboardSnapshot, RemoteEventRecoveryResponse, RemoteSessionEventEnvelope, RemoteWsTicket,
  SessionEventType
} from '../model/Types';
import { parseDashboardSnapshot, parseEventRecovery, parseSessionEvent, parseWsTicket, Raw } from './Parse';

export interface SocketHandlers {
  onOpen: () => void;
  onText: (text: string) => void;
  onBinary: (data: ArrayBuffer) => void;
  onClosed: () => void;
  onError: (message: string) => void;
}

/** WebSocket 包装：统一回调 + 幂等 close。 */
export class RealtimeSocket {
  private socket?: webSocket.WebSocket;
  private closed: boolean = false;
  private handlers: SocketHandlers;

  constructor(handlers: SocketHandlers) {
    this.handlers = handlers;
  }

  connect(url: string): void {
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('open', (err: BusinessError, value: Object) => {
      if (this.closed) {
        return;
      }
      if (err !== undefined && err !== null && err.code !== 0) {
        this.handlers.onError(`WebSocket 打开失败：${err.message}`);
        return;
      }
      this.handlers.onOpen();
    });
    socket.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (this.closed) {
        return;
      }
      if (typeof value === 'string') {
        this.handlers.onText(value as string);
      } else if (value instanceof ArrayBuffer) {
        this.handlers.onBinary(value as ArrayBuffer);
      }
    });
    socket.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (this.closed) {
        return;
      }
      this.closed = true;
      this.handlers.onClosed();
    });
    socket.on('error', (err: BusinessError) => {
      if (this.closed) {
        return;
      }
      const message = err !== undefined && err !== null ? err.message : '未知错误';
      this.handlers.onError(`WebSocket 错误：${message}`);
    });
    socket.connect(url, (err: BusinessError, value: boolean) => {
      if (err !== undefined && err !== null && err.code !== 0) {
        this.handlers.onError(`WebSocket 连接失败：${err.message}`);
      }
    });
  }

  sendText(text: string): void {
    const socket = this.socket;
    if (socket === undefined) {
      return;
    }
    socket.send(text, (err: BusinessError) => {
      if (err !== undefined && err !== null && err.code !== 0) {
        this.handlers.onError(`WebSocket 发送失败：${err.message}`);
      }
    });
  }

  close(): void {
    const socket = this.socket;
    this.closed = true;
    this.socket = undefined;
    if (socket === undefined) {
      return;
    }
    socket.off('message');
    socket.off('open');
    socket.off('error');
    socket.off('close');
    socket.close((err: BusinessError) => {
      // 关闭失败无需上报
    });
  }
}

export class RealtimeApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async createDashboardTicket(serverUrl: string, token: string, clientId: string): Promise<RemoteWsTicket> {
    return await this.createTicket(serverUrl, token, clientId, { 'dashboard': true });
  }

  async createSessionTicket(
    serverUrl: string, token: string, clientId: string, sessionId: string
  ): Promise<RemoteWsTicket> {
    return await this.createTicket(serverUrl, token, clientId, { 'sessionId': sessionId });
  }

  dashboardWebSocketUrl(serverUrl: string, ticket: string): string {
    return webSocketApiUrl(serverUrl, `/dashboard/ws?ticket=${urlEncode(ticket)}`);
  }

  sessionWebSocketUrl(serverUrl: string, sessionId: string, ticket: string): string {
    return webSocketApiUrl(serverUrl, `/sessions/${urlEncode(sessionId)}/ws?ticket=${urlEncode(ticket)}`);
  }

  async recoverSessionEvents(
    serverUrl: string, token: string, sessionId: string, after: string
  ): Promise<RemoteEventRecoveryResponse> {
    const raw = await this.client.getJson(
      serverUrl, `/sessions/${urlEncode(sessionId)}/events?after=${urlEncode(after)}`, token) as Raw;
    return parseEventRecovery(raw, after);
  }

  parseDashboardMessage(text: string): RemoteDashboardSnapshot | undefined {
    const raw = safeParse(text);
    if (raw === undefined) {
      return undefined;
    }
    return parseDashboardSnapshot(raw);
  }

  parseSessionMessage(text: string): RemoteSessionEventEnvelope | undefined {
    const raw = safeParse(text);
    if (raw === undefined) {
      return undefined;
    }
    if (raw['type'] === SessionEventType.KEEPALIVE) {
      return undefined;
    }
    try {
      return parseSessionEvent(raw);
    } catch (error) {
      return undefined;
    }
  }

  openWebSocket(url: string, handlers: SocketHandlers): RealtimeSocket {
    const socket = new RealtimeSocket(handlers);
    socket.connect(url);
    return socket;
  }

  private async createTicket(
    serverUrl: string, token: string, clientId: string, scope: Record<string, Object>
  ): Promise<RemoteWsTicket> {
    const body: Record<string, Object> = { 'clientId': clientId, 'scope': scope };
    const raw = await this.client.postJson(serverUrl, '/ws-ticket', body, token) as Raw;
    return parseWsTicket(raw);
  }
}

function safeParse(text: string): Raw | undefined {
  try {
    const parsed = JSON.parse(text) as Object;
    if (parsed === null || parsed === undefined || Array.isArray(parsed)) {
      return undefined;
    }
    return parsed as Raw;
  } catch (error) {
    return undefined;
  }
}

/** 指数退避 + 抖动（对应 Android `reconnectDelayMillis`）。 */
export function reconnectDelayMillis(attempt: number, randomUnit: number): number {
  const capped = attempt < 0 ? 0 : (attempt > 5 ? 5 : attempt);
  const base = Math.min(1000 * Math.pow(2, capped), 30000);
  const jitter = Math.floor(base * 0.25 * Math.min(Math.max(randomUnit, 0), 1));
  return Math.min(base + jitter, 30000);
}

/** 生成并持久化实时连接 id（对应 Android `RealtimeClientIdStore`，前缀改为 harmony-）。 */
export function newRealtimeClientId(): string {
  const rand = Math.floor(Math.random() * 0xFFFFFFFF).toString(16);
  const rand2 = Math.floor(Math.random() * 0xFFFFFFFF).toString(16);
  return `harmony-${Date.now().toString(16)}-${rand}${rand2}`;
}
