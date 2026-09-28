/**
 * HTTP 客户端（对应 Android `api/ApiClient.kt`，OkHttp → @kit.NetworkKit http）。
 *
 * 与 Android 的行为差异：
 * - 不做连接池复用，每次请求 createHttp()/destroy()（鸿蒙 http 模块自带连接复用，避免句柄泄漏）；
 * - 多部分上传自行拼 body（`multipart/form-data`），因为 ArkTS 没有现成的 FormBody；
 * - 错误体解析规则与 Android 完全一致（detail 为 string / {message,code} / [{msg}]）。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { apiUrlCandidates, rememberApiUrl, urlEncode } from './ApiUrls';
import { ApiException } from '../model/Types';
import { utf8Bytes } from '../utils/Sha256';

const CONNECT_TIMEOUT_MS: number = 10000;
const DEFAULT_READ_TIMEOUT_MS: number = 15000;

export interface UploadFilePart {
  name: string;
  mediaType: string;
  bytes: Uint8Array;
}

export interface HttpTextResponse {
  statusCode: number;
  text: string;
  contentType: string;
}

export type UnauthorizedHandler = (accessToken: string) => void;

function isJsonContentType(contentType: string): boolean {
  const lower = contentType.toLowerCase();
  return lower.includes('application/json') || lower.includes('+json');
}

function looksLikeHtml(contentType: string, text: string): boolean {
  if (contentType.toLowerCase().includes('text/html')) {
    return true;
  }
  const head = text.trimStart().substring(0, 16).toLowerCase();
  return head.startsWith('<!doctype') || head.startsWith('<html');
}

function toStringResult(result: string | Object | ArrayBuffer): string {
  if (typeof result === 'string') {
    return result as string;
  }
  if (result instanceof ArrayBuffer) {
    return bufferToUtf8(result as ArrayBuffer);
  }
  if (result === undefined || result === null) {
    return '';
  }
  return JSON.stringify(result);
}

function bufferToUtf8(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i += 1;
    } else if (b0 >= 0xC0 && b0 < 0xE0) {
      out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if (b0 >= 0xE0 && b0 < 0xF0) {
      out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      const codePoint = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
        ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      const adjusted = codePoint - 0x10000;
      out += String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF));
      i += 4;
    }
  }
  return out;
}

function defaultErrorMessage(statusCode: number): string {
  if (statusCode === 401) {
    return '未授权：登录已失效，请重新登录。';
  }
  if (statusCode === 404) {
    return '该服务器上找不到这个接口。';
  }
  return `请求失败（HTTP ${statusCode}）。`;
}

/** 从错误响应体里取人类可读消息，规则同 Android。 */
function parseErrorMessage(responseText: string): string | undefined {
  if (responseText.trim().length === 0) {
    return undefined;
  }
  try {
    const body = JSON.parse(responseText) as Record<string, Object>;
    const detail = body['detail'];
    if (detail === undefined || detail === null) {
      return undefined;
    }
    if (typeof detail === 'string') {
      const text = detail as string;
      return text.length > 0 ? text : undefined;
    }
    if (Array.isArray(detail)) {
      const list = detail as Record<string, Object>[];
      if (list.length > 0) {
        const msg = list[0]['msg'];
        if (typeof msg === 'string' && (msg as string).length > 0) {
          return msg as string;
        }
      }
      return undefined;
    }
    if (typeof detail === 'object') {
      const obj = detail as Record<string, Object>;
      const message = obj['message'];
      if (typeof message === 'string' && (message as string).length > 0) {
        return message as string;
      }
      const code = obj['code'];
      if (typeof code === 'string' && (code as string).length > 0) {
        return code as string;
      }
      return JSON.stringify(detail);
    }
    return undefined;
  } catch (error) {
    return undefined;
  }
}

function parseErrorCode(responseText: string): string | undefined {
  if (responseText.trim().length === 0) {
    return undefined;
  }
  try {
    const body = JSON.parse(responseText) as Record<string, Object>;
    let target: Record<string, Object> = body;
    const detail = body['detail'];
    if (detail !== undefined && detail !== null && typeof detail === 'object' && !Array.isArray(detail)) {
      target = detail as Record<string, Object>;
    }
    const code = target['code'];
    if (typeof code === 'string' && (code as string).length > 0) {
      return code as string;
    }
    return undefined;
  } catch (error) {
    return undefined;
  }
}

/**
 * 把底层异常统一成 ApiException。
 *
 * ⚠️ 必须幂等：`sendRaw` 已经包过一次，`requestJson` 的 catch 还会再包一次，
 * 不判类型就会出现「无法连接服务器…（无法连接服务器…（Failed to connect…））」这种双层嵌套
 * （真机验收时抓到过）。已经是 ApiException 就原样返回。
 */
function toApiException(error: Object): ApiException {
  if (error instanceof ApiException) {
    return error as ApiException;
  }
  const be = error as BusinessError;
  const message = be !== undefined && be.message !== undefined ? be.message : String(error);
  return new ApiException(`无法连接服务器，请检查地址与网络。（${message}）`);
}

export class ApiClient {
  private onUnauthorized: UnauthorizedHandler;

  constructor(onUnauthorized?: UnauthorizedHandler) {
    if (onUnauthorized !== undefined) {
      this.onUnauthorized = onUnauthorized;
    } else {
      this.onUnauthorized = (token: string) => {
      };
    }
  }

  async getJson(serverUrl: string, path: string, authorizationToken?: string): Promise<Object> {
    return await this.requestJson(serverUrl, path, http.RequestMethod.GET, undefined, authorizationToken);
  }

  async postJson(
    serverUrl: string, path: string, body: Record<string, Object> | undefined, authorizationToken?: string,
    readTimeoutSeconds?: number
  ): Promise<Object> {
    return await this.requestJson(
      serverUrl, path, http.RequestMethod.POST, body, authorizationToken, readTimeoutSeconds);
  }

  /** POST 一个 JSON 数组体（`/sessions/archive` 等批量接口用）。 */
  async postJsonArray(
    serverUrl: string, path: string, body: Object[], authorizationToken?: string
  ): Promise<Object> {
    return await this.requestJson(
      serverUrl, path, http.RequestMethod.POST, body as Object, authorizationToken);
  }

  async patchJson(
    serverUrl: string, path: string, body: Record<string, Object>, authorizationToken?: string
  ): Promise<Object> {
    return await this.requestJson(serverUrl, path, http.RequestMethod.PATCH, body, authorizationToken);
  }

  async putJson(
    serverUrl: string, path: string, body: Record<string, Object>, authorizationToken?: string
  ): Promise<Object> {
    return await this.requestJson(serverUrl, path, http.RequestMethod.PUT, body, authorizationToken);
  }

  async deleteJson(serverUrl: string, path: string, authorizationToken?: string): Promise<Object> {
    return await this.requestJson(serverUrl, path, http.RequestMethod.DELETE, undefined, authorizationToken);
  }

  /** `application/x-www-form-urlencoded`（OAuth token 交换用）。 */
  async postForm(serverUrl: string, path: string, fields: Record<string, string>): Promise<Object> {
    const pairs: string[] = [];
    const keys = Object.keys(fields);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      pairs.push(`${urlEncode(key)}=${urlEncode(fields[key])}`);
    }
    const text = pairs.join('&');
    const candidates = apiUrlCandidates(serverUrl, path);
    let lastError: ApiException | undefined = undefined;
    for (let index = 0; index < candidates.length; index++) {
      const url = candidates[index];
      try {
        const response = await this.sendRaw(
          url, http.RequestMethod.POST, utf8Bytes(text).buffer as ArrayBuffer, undefined, DEFAULT_READ_TIMEOUT_MS,
          { 'Content-Type': 'application/x-www-form-urlencoded' }, true);
        if (!this.isSuccess(response.statusCode)) {
          this.notifyUnauthorized(response.statusCode, undefined);
          throw new ApiException(
            parseErrorMessage(response.text) ?? defaultErrorMessage(response.statusCode),
            response.statusCode, parseErrorCode(response.text));
        }
        rememberApiUrl(serverUrl, url);
        return this.parseObject(response.text);
      } catch (error) {
        if (error instanceof ApiException) {
          lastError = error as ApiException;
          if ((error as ApiException).statusCode !== undefined && !this.shouldTryLegacy(error as ApiException)) {
            throw error;
          }
        } else {
          throw toApiException(error as Object);
        }
      }
    }
    throw lastError ?? new ApiException('服务器返回了无效响应。');
  }

  /** `multipart/form-data` 上传（自行拼包体）。 */
  async postMultipart(
    serverUrl: string, path: string, files: UploadFilePart[], authorizationToken?: string
  ): Promise<Object> {
    const boundary = `AA-${Date.now()}`;
    const chunks: Uint8Array[] = [];
    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      const mediaType = file.mediaType.length > 0 ? file.mediaType : 'application/octet-stream';
      const headerText = `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="files"; filename="${httpQuote(file.name)}"\r\n` +
        `Content-Type: ${mediaType}\r\n\r\n`;
      chunks.push(utf8Bytes(headerText));
      chunks.push(file.bytes);
      chunks.push(utf8Bytes('\r\n'));
    }
    chunks.push(utf8Bytes(`--${boundary}--\r\n`));

    let total = 0;
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].length;
    }
    const body = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      body.set(chunks[i], offset);
      offset += chunks[i].length;
    }

    const candidates = apiUrlCandidates(serverUrl, path);
    let lastError: ApiException | undefined = undefined;
    for (let index = 0; index < candidates.length; index++) {
      const url = candidates[index];
      try {
        const response = await this.sendRaw(
          url, http.RequestMethod.POST, body.buffer as ArrayBuffer, authorizationToken, 60000,
          { 'Content-Type': `multipart/form-data; boundary=${boundary}` }, true);
        if (!this.isSuccess(response.statusCode)) {
          this.notifyUnauthorized(response.statusCode, authorizationToken);
          throw new ApiException(
            parseErrorMessage(response.text) ?? defaultErrorMessage(response.statusCode),
            response.statusCode, parseErrorCode(response.text));
        }
        rememberApiUrl(serverUrl, url);
        return this.parseObject(response.text);
      } catch (error) {
        if (error instanceof ApiException) {
          lastError = error as ApiException;
          if (!this.shouldTryLegacy(error as ApiException)) {
            throw error;
          }
        } else {
          throw toApiException(error as Object);
        }
      }
    }
    throw lastError ?? new ApiException('服务器返回了无效响应。');
  }

  private async requestJson(
    serverUrl: string, path: string, method: http.RequestMethod, body: Object | undefined,
    authorizationToken?: string, readTimeoutSeconds?: number
  ): Promise<Object> {
    const readTimeout = readTimeoutSeconds !== undefined ? readTimeoutSeconds * 1000 : DEFAULT_READ_TIMEOUT_MS;
    let bodyBuffer: ArrayBuffer | undefined = undefined;
    if (body !== undefined) {
      bodyBuffer = utf8Bytes(JSON.stringify(body)).buffer as ArrayBuffer;
    } else if (method === http.RequestMethod.POST || method === http.RequestMethod.PUT ||
      method === http.RequestMethod.PATCH) {
      bodyBuffer = new ArrayBuffer(0);
    }

    const candidates = apiUrlCandidates(serverUrl, path);
    let lastError: ApiException | undefined = undefined;
    for (let index = 0; index < candidates.length; index++) {
      const url = candidates[index];
      let response: HttpTextResponse;
      try {
        response = await this.sendRaw(
          url, method, bodyBuffer, authorizationToken, readTimeout,
          { 'Content-Type': 'application/json; charset=utf-8' }, true);
      } catch (error) {
        throw toApiException(error as Object);
      }

      const canTryLegacy = index < candidates.length - 1 && this.shouldTryLegacyResponse(response);
      if (canTryLegacy) {
        continue;
      }
      if (!this.isSuccess(response.statusCode)) {
        this.notifyUnauthorized(response.statusCode, authorizationToken);
        throw new ApiException(
          parseErrorMessage(response.text) ?? defaultErrorMessage(response.statusCode),
          response.statusCode, parseErrorCode(response.text));
      }
      rememberApiUrl(serverUrl, url);
      return this.parseObject(response.text);
    }
    throw lastError ?? new ApiException('服务器返回了无效响应。');
  }

  private parseObject(text: string): Object {
    if (text.trim().length === 0) {
      const empty: Record<string, Object> = {};
      return empty;
    }
    try {
      return JSON.parse(text) as Object;
    } catch (error) {
      throw new ApiException('服务器返回了无效响应。');
    }
  }

  private isSuccess(statusCode: number): boolean {
    return statusCode >= 200 && statusCode <= 299;
  }

  private shouldTryLegacy(error: ApiException): boolean {
    return error.statusCode === 405 || error.statusCode === 404;
  }

  /** 405、非 JSON 内容类型、或 404 时回退 legacy 路径。 */
  private shouldTryLegacyResponse(response: HttpTextResponse): boolean {
    if (response.statusCode === 405) {
      return true;
    }
    if (isJsonContentType(response.contentType)) {
      return false;
    }
    if (response.statusCode === 404) {
      return true;
    }
    return this.isSuccess(response.statusCode) && looksLikeHtml(response.contentType, response.text);
  }

  private notifyUnauthorized(statusCode: number, authorizationToken?: string): void {
    if (statusCode !== 401 || authorizationToken === undefined || authorizationToken.length === 0) {
      return;
    }
    try {
      this.onUnauthorized(authorizationToken);
    } catch (error) {
      // 回调失败不影响主流程
    }
  }

  private async sendRaw(
    url: string, method: http.RequestMethod, body: ArrayBuffer | undefined,
    authorizationToken: string | undefined, readTimeoutMs: number,
    extraHeaders: Record<string, string>, noDefaultAccept?: boolean
  ): Promise<HttpTextResponse> {
    const headers: Record<string, string> = {};
    headers['ngrok-skip-browser-warning'] = 'true';
    if (noDefaultAccept !== true) {
      headers['Accept'] = 'application/json';
    }
    const headerKeys = Object.keys(extraHeaders);
    for (let i = 0; i < headerKeys.length; i++) {
      headers[headerKeys[i]] = extraHeaders[headerKeys[i]];
    }
    if (authorizationToken !== undefined && authorizationToken.length > 0) {
      headers['Authorization'] = `Bearer ${authorizationToken}`;
    }

    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: readTimeoutMs,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      const response = await request.request(url, options);
      let contentType = '';
      if (response.header !== undefined && response.header !== null) {
        const headerObj = response.header as Record<string, Object>;
        const raw = headerObj['content-type'] ?? headerObj['Content-Type'];
        if (typeof raw === 'string') {
          contentType = raw as string;
        }
      }
      return {
        statusCode: response.responseCode as number,
        text: toStringResult(response.result),
        contentType: contentType
      };
    } catch (error) {
      throw toApiException(error as Object);
    } finally {
      request.destroy();
    }
  }
}

function httpQuote(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r/g, '').replace(/\n/g, '');
}
