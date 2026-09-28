/**
 * 终端 API（对应 Android `api/TerminalApi.kt`）。
 *
 * 终端是 **Connector 级**（不是 session 级）：`/connectors/{id}/terminals-v2`。
 * 输出走 WebSocket：`/connectors/{id}/terminals-v2/{terminalId}/stream?fromSeq=&token=`。
 */

import { ApiClient } from './ApiClient';
import { urlEncode, webSocketApiUrl } from './ApiUrls';
import { RemoteTerminal } from '../model/Types';
import { optRaw, parseTerminal, Raw } from './Parse';

export class TerminalApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async createTerminal(
    serverUrl: string, token: string, deviceId: string, root: string, cols: number, rows: number,
    ephemeralGroupId: string, cwd: string = '.', label: string = 'Agents Anywhere'
  ): Promise<RemoteTerminal> {
    const body: Record<string, Object> = {
      'cols': cols,
      'rows': rows,
      'cwd': cwd,
      'ephemeralGroupId': ephemeralGroupId,
      'label': label
    };
    const raw = await this.client.postJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/terminals-v2?root=${urlEncode(root)}`,
      body, token) as Raw;
    return parseTerminal(optRaw(raw, 'result') ?? {});
  }

  async closeTerminal(
    serverUrl: string, token: string, deviceId: string, terminalId: string
  ): Promise<void> {
    await this.client.deleteJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/terminals-v2/${urlEncode(terminalId)}`,
      token);
  }

  /** 终端输出流地址；`fromSeq` 用于断线续传。 */
  streamUrl(
    serverUrl: string, token: string, deviceId: string, terminalId: string, fromSeq: number = 0
  ): string {
    return webSocketApiUrl(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/terminals-v2/${urlEncode(terminalId)}/stream` +
      `?fromSeq=${fromSeq}&token=${urlEncode(token)}`);
  }
}
