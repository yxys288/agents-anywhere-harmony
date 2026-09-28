/**
 * 设备（服务端 connector）API（对应 Android `api/DevicesApi.kt`）。
 */

import { ApiClient } from './ApiClient';
import { urlEncode } from './ApiUrls';
import {
  RemoteDevice, RemoteDeviceRuntime, RemoteDeviceRuntimeList, RemoteRuntimeCapabilities,
  RemoteRuntimeModelCatalogResponse, RemoteRuntimePermissionCatalogResponse
} from '../model/Types';
import {
  emptyRaw, optRaw, optString, parseCapabilitySet, parseDevice, parseDeviceRuntime, parseDeviceRuntimeList,
  parseModelCatalog, parsePermissionCatalog, Raw, str
} from './Parse';

export interface RemoteDeviceCredential {
  device: RemoteDevice;
  deviceToken: string;
  tokenPrefix?: string;
}

export class DevicesApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async listDevices(serverUrl: string, token: string): Promise<RemoteDevice[]> {
    const raw = await this.client.getJson(serverUrl, '/connectors', token) as Raw;
    return (raw['connectors'] !== undefined && Array.isArray(raw['connectors']))
      ? (raw['connectors'] as Object[]).map((item: Object) => parseDevice(item as Raw))
      : [];
  }

  async getDevice(serverUrl: string, token: string, deviceId: string): Promise<RemoteDevice> {
    const raw = await this.client.getJson(serverUrl, `/connectors/${urlEncode(deviceId)}`, token) as Raw;
    return parseDevice(optRaw(raw, 'connector') ?? emptyRaw());
  }

  async createDevice(serverUrl: string, token: string, name: string): Promise<RemoteDeviceCredential> {
    const body: Record<string, Object> = { 'name': name };
    const raw = await this.client.postJson(serverUrl, '/connectors', body, token) as Raw;
    return this.toCredential(raw);
  }

  async updateDevice(serverUrl: string, token: string, deviceId: string, name: string): Promise<RemoteDevice> {
    const body: Record<string, Object> = { 'name': name };
    const raw = await this.client.patchJson(
      serverUrl, `/connectors/${urlEncode(deviceId)}`, body, token) as Raw;
    return parseDevice(optRaw(raw, 'connector') ?? emptyRaw());
  }

  async deleteDevice(serverUrl: string, token: string, deviceId: string): Promise<void> {
    await this.client.deleteJson(serverUrl, `/connectors/${urlEncode(deviceId)}`, token);
  }

  async revokeDevice(serverUrl: string, token: string, deviceId: string): Promise<RemoteDeviceCredential> {
    const raw = await this.client.postJson(
      serverUrl, `/connectors/${urlEncode(deviceId)}/revoke`, emptyRaw(), token) as Raw;
    return this.toCredential(raw);
  }

  async listDeviceRuntimes(
    serverUrl: string, token: string, deviceId: string
  ): Promise<RemoteDeviceRuntimeList> {
    const raw = await this.client.getJson(
      serverUrl, `/connectors/${urlEncode(deviceId)}/runtimes`, token) as Raw;
    return this.toRuntimeList(raw, deviceId);
  }

  async discoverDeviceRuntimes(
    serverUrl: string, token: string, deviceId: string
  ): Promise<RemoteDeviceRuntimeList> {
    const raw = await this.client.postJson(
      serverUrl, `/connectors/${urlEncode(deviceId)}/runtimes/discover`, emptyRaw(), token) as Raw;
    return this.toRuntimeList(raw, deviceId);
  }

  async putDeviceRuntimeConfig(
    serverUrl: string, token: string, deviceId: string, runtimeId: string, config: Record<string, Object>
  ): Promise<RemoteDeviceRuntime> {
    const body: Record<string, Object> = { 'config': config };
    const raw = await this.client.putJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/runtimes/${urlEncode(runtimeId)}/config`,
      body, token) as Raw;
    return parseDeviceRuntime(raw, deviceId);
  }

  async setDeviceRuntimeActive(
    serverUrl: string, token: string, deviceId: string, runtimeId: string, active: boolean
  ): Promise<RemoteDeviceRuntime> {
    const body: Record<string, Object> = { 'active': active };
    const raw = await this.client.putJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/runtimes/${urlEncode(runtimeId)}/active`,
      body, token) as Raw;
    return parseDeviceRuntime(raw, deviceId);
  }

  async deleteDeviceRuntimeConfig(
    serverUrl: string, token: string, deviceId: string, runtimeId: string
  ): Promise<RemoteDeviceRuntime> {
    const raw = await this.client.deleteJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/runtimes/${urlEncode(runtimeId)}/config`,
      token) as Raw;
    return parseDeviceRuntime(raw, deviceId);
  }

  async getDeviceRuntimeCapabilities(
    serverUrl: string, token: string, deviceId: string, runtimeId: string
  ): Promise<RemoteRuntimeCapabilities> {
    const raw = await this.client.getJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/runtimes/${urlEncode(runtimeId)}/capabilities`,
      token) as Raw;
    const connectorId = str(raw, 'connectorId', deviceId);
    const result: RemoteRuntimeCapabilities = {
      connectorId: connectorId.length > 0 ? connectorId : deviceId,
      capabilitySet: parseCapabilitySet(optRaw(raw, 'capabilitySet')),
      serverTime: optString(raw, 'serverTime')
    };
    return result;
  }

  async getDeviceRuntimeModelCatalog(
    serverUrl: string, token: string, deviceId: string, runtimeId: string
  ): Promise<RemoteRuntimeModelCatalogResponse> {
    const raw = await this.client.getJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/runtimes/${urlEncode(runtimeId)}/catalogs/model`,
      token) as Raw;
    const response: RemoteRuntimeModelCatalogResponse = {
      catalog: parseModelCatalog(optRaw(raw, 'catalog'), runtimeId),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  async getDeviceRuntimePermissionCatalog(
    serverUrl: string, token: string, deviceId: string, runtimeId: string
  ): Promise<RemoteRuntimePermissionCatalogResponse> {
    const raw = await this.client.getJson(
      serverUrl,
      `/connectors/${urlEncode(deviceId)}/runtimes/${urlEncode(runtimeId)}/catalogs/permission`,
      token) as Raw;
    const response: RemoteRuntimePermissionCatalogResponse = {
      catalog: parsePermissionCatalog(optRaw(raw, 'catalog'), runtimeId),
      serverTime: optString(raw, 'serverTime')
    };
    return response;
  }

  /** 配对码认领：把 Connector 侧生成的配对码绑到当前账号。 */
  async claimPairing(
    serverUrl: string, token: string, code: string, name: string, deviceId: string, deviceToken: string
  ): Promise<RemoteDevice> {
    const body: Record<string, Object> = {
      'code': code,
      'name': name,
      'serverUrl': serverUrl,
      'connectorId': deviceId,
      'connectorToken': deviceToken
    };
    const raw = await this.client.postJson(serverUrl, '/pairing/claim', body, token) as Raw;
    return parseDevice(optRaw(raw, 'connector') ?? emptyRaw());
  }

  private toCredential(raw: Raw): RemoteDeviceCredential {
    const credential: RemoteDeviceCredential = {
      device: parseDevice(optRaw(raw, 'connector') ?? emptyRaw()),
      deviceToken: str(raw, 'connectorToken', ''),
      tokenPrefix: optString(raw, 'tokenPrefix')
    };
    return credential;
  }

  private toRuntimeList(raw: Raw, fallbackConnectorId: string): RemoteDeviceRuntimeList {
    const connectorId = str(raw, 'connectorId', fallbackConnectorId);
    const list: RemoteDeviceRuntimeList = {
      connectorId: connectorId.length > 0 ? connectorId : fallbackConnectorId,
      runtimes: parseDeviceRuntimeList(raw, fallbackConnectorId),
      serverTime: optString(raw, 'serverTime')
    };
    return list;
  }
}
