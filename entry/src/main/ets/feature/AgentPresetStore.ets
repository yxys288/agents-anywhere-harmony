/**
 * **Agent 预设（设置页）** 的状态（R54）。
 *
 * 由来：用户要求「设置菜单增加 Agent 预设选项」。会话页的运行设置面板里虽然能选预设，
 * 但那是**每一次新建**的临时入口；设置页这一份回答的是「默认用哪个 / 这台机器的连接器到底
 * 上报了哪些预设」。
 *
 * 数据链**没有新协议**：
 *  · 设备：`DashboardStore.devices`（首页同一份）；
 *  · 每台设备的 Agent：`GET /connectors/{id}/runtimes`（与设备详情同一条）；
 *  · 预设目录：runtime 描述的 `uiSchema.defaultAgentPreset`（`model/AgentPreset.ets`）；
 *  · 「目录是空的」时用户能自救：`POST /connectors/{id}/runtimes/discover`（上游 Android
 *  `api/DevicesApi.kt:112` 用的同一个端点）——它会让连接器重新向 DSH 插件要一次目录。
 *
 * 选中项写在**同一本**「上次选择」记忆里（`aaNewSessionPref`，作用域 `deviceId|runtimeId`），
 * 所以设置页选完，新建对话（草稿态）会直接沿用它 —— 与在对话页里选是**同一个效果**。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl } from '../store/AuthSessionStore';
import { AgentDevice } from '../model/AppModels';
import { RemoteDeviceRuntime } from '../model/Types';
import { DashboardStore } from './DashboardStore';
import { readNewSessionSelection, writeNewSessionSelection } from './SessionDetailStore';
import {
  AgentPresetOption, agentPresetOptions, agentPresetRowValue, defaultAgentPreset, presetStillSelectable
} from '../model/AgentPreset';
import { NewSessionSelection, emptySelection } from '../model/NewSessionPreference';

/** 一台设备上**一个 DSH Agent** 的预设情况（设置页一行/一卡的数据源）。 */
export interface AgentPresetRow {
  deviceId: string;
  deviceName: string;
  online: boolean;
  runtimeId: string;
  runtimeName: string;
  status: string;
  /** 连接器上报的预设目录（空数组 = 没上报 / 该 runtime 不给预设）。 */
  options: AgentPresetOption[];
  /** 当前默认（记忆里的，或目录默认值）。 */
  selected: string;
  /** `selected` 是否来自「上次选择」记忆（界面据此显示「上次使用」）。 */
  fromMemory: boolean;
  /** 该 runtime 的目录拉取失败原因（空串 = 成功）。 */
  error: string;
}

export class AgentPresetStore {
  private static instance?: AgentPresetStore;

  rows: AgentPresetRow[] = [];
  loading: boolean = false;
  /** 正在「刷新目录」的设备 id（空串 = 没有在刷）。 */
  refreshingDeviceId: string = '';
  error: string = '';
  notice: string = '';

  private listeners: Array<() => void> = [];

  static get(): AgentPresetStore {
    if (AgentPresetStore.instance === undefined) {
      AgentPresetStore.instance = new AgentPresetStore();
    }
    return AgentPresetStore.instance;
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
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

  /** 拉一遍设备与各自的 Agent（进页面/`刷新`都用它；幂等）。 */
  async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    // ⚠️ 每次进页面都清掉上一次的提示：store 是单例，不清的话重进子页会看到
    // 上一轮「已把 X 设为默认预设」的旧提示（真机实测）。
    this.notice = '';
    this.notify();
    try {
      const dashboard = DashboardStore.get();
      if (dashboard.devices.length === 0) {
        await dashboard.refreshAll();
      }
      const devices = dashboard.devices.slice();
      await this.loadDevices(devices);
      if (this.rows.length === 0 && this.error.length === 0) {
        this.notice = devices.length === 0
          ? '还没有已配对的设备。'
          : '这些设备上没有已配置的 DeepSeek Harness Agent。';
      }
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.loading = false;
      this.notify();
    }
  }

  private async loadDevices(devices: AgentDevice[]): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    const collected: AgentPresetRow[] = [];
    for (let i = 0; i < devices.length; i++) {
      const device = devices[i];
      try {
        const list = await AppServices.get().devices.listDeviceRuntimes(serverUrl, token, device.id);
        const rows = this.rowsFor(device, list.runtimes);
        for (let j = 0; j < rows.length; j++) {
          collected.push(rows[j]);
        }
      } catch (error) {
        // 单台设备拉不到不该让整页空掉：跳过它，其余设备照常展示。
      }
    }
    this.rows = collected;
  }

  /** 把一台设备的 runtime 列表折成行（只保留 DSH —— 预设是 DSH 专有能力）。 */
  private rowsFor(device: AgentDevice, runtimes: RemoteDeviceRuntime[]): AgentPresetRow[] {
    const rows: AgentPresetRow[] = [];
    for (let i = 0; i < runtimes.length; i++) {
      const runtime = runtimes[i];
      if (runtime.runtimeType !== 'dsh') {
        continue;
      }
      const options = agentPresetOptions(runtime);
      // `readNewSessionSelection` 直接给出**该作用域**的选择（内部已按 deviceId|runtimeId 查过）。
      const remembered = readNewSessionSelection(device.id, runtime.runtimeId);
      const rememberedId = remembered !== undefined ? remembered.agentPresetId : '';
      const fromMemory = rememberedId.length > 0 && presetStillSelectable(options, rememberedId);
      rows.push({
        deviceId: device.id,
        deviceName: device.name,
        online: device.online,
        runtimeId: runtime.runtimeId,
        runtimeName: runtime.displayName.length > 0 ? runtime.displayName : 'DeepSeek Harness',
        status: runtime.status,
        options: options,
        selected: fromMemory ? rememberedId : defaultAgentPreset(runtime),
        fromMemory: fromMemory,
        error: ''
      });
    }
    return rows;
  }

  /**
   * 刷新某台设备的目录：`POST /connectors/{id}/runtimes/discover`。
   *
   * 这是「连接器没有上报预设目录」的**唯一**自救路径 —— 服务端那份 `uiSchema` 是上一次
   * 发现的快照，只有重新发现才会去问 DSH 插件要 `catalog.listAgentPresets`。
   */
  async refreshDevice(deviceId: string): Promise<void> {
    if (this.refreshingDeviceId.length > 0) {
      return;
    }
    this.refreshingDeviceId = deviceId;
    this.error = '';
    this.notice = '正在让连接器重新上报…';
    this.notify();
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const list = await AppServices.get().devices.discoverDeviceRuntimes(serverUrl, token, deviceId);
      const device = this.deviceOf(deviceId);
      if (device !== undefined) {
        const fresh = this.rowsFor(device, list.runtimes);
        const kept: AgentPresetRow[] = [];
        for (let i = 0; i < this.rows.length; i++) {
          if (this.rows[i].deviceId !== deviceId) {
            kept.push(this.rows[i]);
          }
        }
        for (let i = 0; i < fresh.length; i++) {
          kept.push(fresh[i]);
        }
        this.rows = kept;
      }
      let presets = 0;
      for (let i = 0; i < this.rows.length; i++) {
        if (this.rows[i].deviceId === deviceId) {
          presets += this.rows[i].options.length;
        }
      }
      this.notice = presets > 0
        ? '已取到 ' + String(presets) + ' 个预设。'
        : '连接器仍然没有上报预设目录：请确认 DSH 正在运行、且手机连接插件已启用。';
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.refreshingDeviceId = '';
      this.notify();
    }
  }


  /**
   * **打开弹窗时的自动刷新**（R94）：重新发现**每一台在线设备**的 runtime 目录。
   *
   * 用户原话：「将设置页的 Agent 预设弹窗中的『刷新目录』删掉，改为每次打开弹窗自动刷新，若失败则提示」。
   *
   * ## 为什么不能只调 `load()`
   * `load()` 读的是服务端**上一次发现结果的快照**（`uiSchema` 里那份 options）。
   * 连接器没上报预设目录时，那份快照就是空的 —— 唯一自救路径是重新发现
   * （`POST /connectors/{id}/runtimes/discover`，正是原「刷新目录」行做的事）。
   * ⇒ 自动刷新必须**先 `load()` 拿设备列表、再对每台在线设备重新发现**，两步缺一不可。
   *
   * ## 失败语义（与 `refreshDevice()` 一致，但**逐个设备**收集）
   *  · 服务端把「重新发现」实现成给连接器发 RPC；设备离线 / 连接器没跑 ⇒ 该设备失败；
   *  · **一台失败不该让整轮失败**：失败的设备名收集起来写进 `error`，成功的照常出新目录；
   *  · `error` 非空 ⇒ 弹窗顶部那条 `AaErrorBanner` 自动显示（调用点不用另加控件）。
   *
   * ## ⚠️ 与手动刷新共用「同一台设备只允许一个在跑」的闸
   * `refreshingDeviceId` 仍是同一个字段（服务端同一设备并发 discovery 无意义），
   * 所以本方法进入时若已在刷新中就直接返回（幂等，连点开窗不会叠加请求）。
   */
  async autoRefresh(): Promise<void> {
    await this.load();
    if (this.refreshingDeviceId.length > 0) {
      return;
    }
    const targets: string[] = [];
    const offline: string[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const row = this.rows[i];
      if (targets.indexOf(row.deviceId) >= 0 || offline.indexOf(row.deviceId) >= 0) {
        continue;
      }
      if (row.online) {
        targets.push(row.deviceId);
      } else {
        offline.push(row.deviceId);
      }
    }
    // ## ⚠️ R94 真机实测暴露的一个**真缺陷**（第一版就是这么漏的）
    // 第一版在 `targets.length === 0` 时**直接 return**（不提示）。真机验证时把连接器停掉：
    // 设备变「设备离线」⇒ targets 空 ⇒ 开窗后**列表照旧显示上一次的目录、却一句解释都没有**，
    // 用户完全不知道「这次没刷新成功」。而用户的原话恰恰是「**若失败则提示**」——
    // 「设备离线所以刷不了」正是最需要提示的一类失败。
    // ⇒ 现在把离线设备也算作失败，并且**在没有任何可刷新设备时也照样给出提示**。
    const failed: string[] = [];
    for (let i = 0; i < offline.length; i++) {
      failed.push(this.nameOfDevice(offline[i]));
    }
    for (let i = 0; i < targets.length; i++) {
      const deviceId = targets[i];
      await this.refreshDevice(deviceId);
      if (this.error.length > 0) {
        failed.push(this.nameOfDevice(deviceId));
      }
    }
    // 全部成功时 refreshDevice 会把 error 清空并留下它自己的 notice（「已取到 N 个预设。」）⇒ 不覆盖。
    // 有失败时用一句**说明是自动刷新失败**的话覆盖掉（否则用户看到的是「正在让连接器重新上报…」这类过程态）。
    if (failed.length > 0) {
      // 离线设备的失败原因是「连不上」，不是服务端返回的错；这时 `this.error` 可能为空（离线设备根本没发请求）
      // ⇒ 兜一句人话，别拼出「失败（LYW）：」这种尾巴空着的文案。
      const detail = this.error.length > 0 ? this.error : '设备离线，请确认 DSH 与连接器正在运行。';
      this.error = '自动刷新预设目录失败（' + failed.join('、') + '）：' + detail;
    }
    this.notify();
  }

  /** 设备显示名（错误文案里点名是哪台失败）；找不到时回落 id。 */
  private nameOfDevice(deviceId: string): string {
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].deviceId === deviceId) {
        return this.rows[i].deviceName;
      }
    }
    return deviceId;
  }

  /** 选中一个预设 ⇒ 写进「上次选择」记忆（作用域 `deviceId|runtimeId`，与对话页同一本）。 */
  select(row: AgentPresetRow, value: string): void {
    if (!presetStillSelectable(row.options, value)) {
      this.error = '这个预设当前不可用。';
      this.notify();
      return;
    }
    const remembered = readNewSessionSelection(row.deviceId, row.runtimeId);
    const base: NewSessionSelection = remembered !== undefined ? remembered : emptySelection();
    const next: NewSessionSelection = {
      modelId: base.modelId,
      reasoningId: base.reasoningId,
      permissionId: base.permissionId,
      agentPresetId: value
    };
    writeNewSessionSelection(row.deviceId, row.runtimeId, next);
    const updated: AgentPresetRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const item = this.rows[i];
      if (item.deviceId === row.deviceId && item.runtimeId === row.runtimeId) {
        updated.push({
          deviceId: item.deviceId,
          deviceName: item.deviceName,
          online: item.online,
          runtimeId: item.runtimeId,
          runtimeName: item.runtimeName,
          status: item.status,
          options: item.options,
          selected: value,
          fromMemory: true,
          error: item.error
        });
      } else {
        updated.push(item);
      }
    }
    this.rows = updated;
    this.error = '';
    this.notice = '已把「' + agentPresetRowValue(row.options, value) + '」设为该 Agent 的默认预设。';
    this.notify();
  }

  private deviceOf(deviceId: string): AgentDevice | undefined {
    const devices = DashboardStore.get().devices;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].id === deviceId) {
        return devices[i];
      }
    }
    return undefined;
  }
}
