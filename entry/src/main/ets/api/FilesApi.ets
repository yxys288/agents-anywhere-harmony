/**
 * 远端文件 API（对应 Android `api/FilesApi.kt`）。
 *
 * 走 Connector 的 `fs/*`（经由服务端转发）：列目录 + 读文本文件。
 */

import { ApiClient } from './ApiClient';
import { urlEncode } from './ApiUrls';
import { RemoteDirectory, RemoteTextFile } from '../model/Types';
import { asRawArray, optRaw, parseDirectoryEntry, parseTextFile, Raw, str } from './Parse';

export class FilesApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async listFiles(
    serverUrl: string, token: string, deviceId: string, root: string, path: string = '.'
  ): Promise<RemoteDirectory> {
    const body: Record<string, Object> = { 'root': root, 'path': path };
    const raw = await this.client.postJson(
      serverUrl, `/connectors/${urlEncode(deviceId)}/fs/list`, body, token) as Raw;
    const result = optRaw(raw, 'result') ?? {};
    const resultPath = str(result, 'path', root);
    const directory: RemoteDirectory = {
      path: resultPath.length > 0 ? resultPath : root,
      entries: asRawArray(result['entries']).map((item: Raw) => parseDirectoryEntry(item)),
      truncated: result['truncated'] === true,
      targetType: str(result, 'targetType', 'directory')
    };
    return directory;
  }

  async readTextFile(
    serverUrl: string, token: string, deviceId: string, root: string, path: string,
    maxBytes: number = 1048576
  ): Promise<RemoteTextFile> {
    const body: Record<string, Object> = { 'path': path, 'maxBytes': maxBytes };
    const raw = await this.client.postJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/fs/readText?root=${urlEncode(root)}`,
      body, token) as Raw;
    return parseTextFile(raw);
  }
}
