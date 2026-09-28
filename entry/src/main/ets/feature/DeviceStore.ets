/**
 * 设备（Connector）详情状态（对应 Android `feature/devices/DevicesController.kt`）。
 *
 * 覆盖：设备重命名/删除/重新签发凭据、Runtime 发现与配置、
 * 配对码认领（`POST /pairing/claim`）。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl } from '../store/AuthSessionStore';
import {
  ApiException, JsonMap, RemoteDevice, RemoteDeviceRuntime, RemoteRuntimeCapabilitySet
} from '../model/Types';
import { AgentDevice, AgentSession } from '../model/AppModels';
import { asRaw, parseCapabilitySet, parseModelCatalog, parsePermissionCatalog } from '../api/Parse';
import { Raw } from '../api/Parse';

// ---------------------------------------------------------------------------
// 设备域的纯逻辑（无 ArkUI / @kit 依赖，进 `tools/logic-test/suite-device.mjs`）
//
// 上游对应关系：
//  配对流程 → `ui/screens/devices/AddDeviceScreen.kt` + `DevicePairingSteps.kt`
//  设备会话区 → `ui/screens/devices/DeviceDetailScreen.kt` 的 `SessionsSection`
//  撤销令牌 → `ui/screens/devices/DeviceActionsSheet.kt` + `DeviceConfirmDialog.kt`
//  Runtime 配置 → `ui/screens/devices/DeviceRuntimeConfigureSheet.kt`
// ---------------------------------------------------------------------------

/** 配对码长度（上游 `AddDeviceScreen.claimPairCode`：`pairCode.length != 6` 直接返回）。 */
export const PAIR_CODE_LENGTH: number = 6;

/** 设备详情的会话筛选档（对应上游 `DeviceSessionsFilter`）。 */
export class DeviceSessionsFilter {
  static readonly ACTIVE: string = 'active';
  static readonly ARCHIVED: string = 'archived';
  static readonly ALL: string = 'all';
}

/** 破坏性操作的确认状态机相位（撤销令牌 / 删除设备共用）。 */
export class ConfirmPhase {
  static readonly IDLE: string = 'idle';
  static readonly CONFIRMING: string = 'confirming';
  static readonly BUSY: string = 'busy';
  static readonly DONE: string = 'done';
}

/** Runtime 配置里的一个环境变量条目；`unset` = 明确移除继承值（服务端写 null）。 */
export interface RuntimeEnvEntry {
  name: string;
  value: string;
  unset: boolean;
}

/** Runtime 配置的可编辑草稿（对应上游 `DeviceRuntimeConfigDraft`）。 */
export interface RuntimeConfigDraft {
  executablePath: string;
  environment: RuntimeEnvEntry[];
}

/** 配对码规范化：去空白 + 统一大写（上游 `claimDevicePairCode` 的 `code.trim().uppercase()`）。 */
export function normalizePairCode(raw: string): string {
  return raw.trim().toUpperCase();
}

/**
 * 配对码合法性检查；返回**可读原因**，空串表示合法（按钮禁用与错误提示共用一套口径）。
 *
 * 上游只校验长度（6 位）。这里再挡一次明显的粘贴错误：真机上从终端复制配对码时
 * 经常带上多余空白、全角字符或中文标点，直接发给服务端只会换来一句看不懂的报错。
 */
export function pairCodeError(raw: string): string {
  const code = normalizePairCode(raw);
  if (code.length === 0) {
    return '请输入设备上显示的配对码。';
  }
  if (code.length !== PAIR_CODE_LENGTH) {
    return `配对码是 ${PAIR_CODE_LENGTH} 位，请核对后重新输入。`;
  }
  for (let i = 0; i < code.length; i++) {
    const ch = code.charAt(i);
    const isDigit = ch >= '0' && ch <= '9';
    const isUpper = ch >= 'A' && ch <= 'Z';
    if (!isDigit && !isUpper) {
      return '配对码只包含数字与大写字母。';
    }
  }
  return '';
}

/** 「认领」按钮是否可点（与 `pairCodeError` 共用口径）。 */
export function canSubmitPairCode(raw: string): boolean {
  return pairCodeError(raw).length === 0;
}

const PAIRING_SAFE_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=@%+-';

function indexOfAny(value: string, chars: string): number {
  for (let i = 0; i < value.length; i++) {
    if (chars.indexOf(value.charAt(i)) >= 0) {
      return i;
    }
  }
  return -1;
}

function isPairingArgumentSafe(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  for (let i = 0; i < value.length; i++) {
    if (PAIRING_SAFE_CHARS.indexOf(value.charAt(i)) < 0) {
      return false;
    }
  }
  return true;
}

function quotePairingArgument(value: string): string {
  if (isPairingArgumentSafe(value)) {
    return value;
  }
  return "'" + value.split("'").join("'\\''") + "'";
}

/**
 * 服务端地址 → 配对命令里可用的地址（上游 `devicePairingCommand`）：
 * `https://` 且端口是 443 时省略端口，其余原样；路径 / 查询 / 片段一律丢掉。
 */
export function pairingAddress(serverUrl: string): string {
  const trimmed = serverUrl.trim();
  if (trimmed.length === 0) {
    return '';
  }
  let scheme = '';
  let rest = trimmed;
  const schemeAt = trimmed.indexOf('://');
  if (schemeAt >= 0) {
    scheme = trimmed.substring(0, schemeAt).toLowerCase();
    rest = trimmed.substring(schemeAt + 3);
  }
  const cut = indexOfAny(rest, '/?#');
  if (cut >= 0) {
    rest = rest.substring(0, cut);
  }
  if (scheme === 'https') {
    const colon = rest.lastIndexOf(':');
    if (colon > 0 && rest.substring(colon + 1) === '443') {
      return rest.substring(0, colon);
    }
  }
  return rest;
}

/** 需要在设备上运行的配对命令（上游 `device_pairing_pair_command`）。 */
export function pairingCommand(serverUrl: string): string {
  return `uvx anywhere-cli pair ${quotePairingArgument(pairingAddress(serverUrl))}`;
}

/** 用一次性令牌直接启动 Connector 的命令（上游 `deviceTokenCommand`）。 */
export function tokenCommand(serverUrl: string, deviceId: string, deviceToken: string): string {
  const parts: string[] = [
    'uvx anywhere-cli start',
    `--server-url ${quotePairingArgument(pairingAddress(serverUrl))}`,
    `--connector-id ${quotePairingArgument(deviceId)}`,
    `--connector-token ${quotePairingArgument(deviceToken)}`
  ];
  return parts.join(' ');
}

const PAIRING_ADJECTIVES: string[] = [
  'amber', 'azure', 'brisk', 'calm', 'clear', 'clever', 'copper', 'crisp', 'deft', 'eager',
  'fair', 'fleet', 'fresh', 'gentle', 'golden', 'happy', 'honest', 'jade', 'keen', 'lively',
  'lucky', 'lunar', 'mellow', 'nimble', 'noble', 'opal', 'quiet', 'rapid', 'silver', 'smart',
  'solar', 'steady', 'swift', 'tidy', 'vivid', 'warm', 'witty', 'zesty', 'bright', 'cosmic'
];

const PAIRING_NOUNS: string[] = [
  'acorn', 'anchor', 'badger', 'bamboo', 'beacon', 'birch', 'brook', 'cedar', 'clover', 'comet',
  'condor', 'cove', 'falcon', 'finch', 'fjord', 'forest', 'garden', 'grove', 'harbor', 'heron',
  'island', 'juniper', 'lagoon', 'lantern', 'maple', 'meadow', 'meteor', 'nebula', 'otter', 'phoenix',
  'quartz', 'raven', 'ridge', 'river', 'rocket', 'sequoia', 'sparrow', 'summit', 'willow', 'zephyr'
];

/**
 * 随机设备名（上游 `randomPairingDeviceName`）——`amber-finch` 这种好念、好念给别人的名字。
 *
 * 参数是 `seed` 而不是内部 `Math.random()`：纯函数才能进 Node 断言
 * （同一个 seed 必须得到同一个名字，否则测试没法写）。
 */
export function randomPairingDeviceName(seed: number): string {
  const base = Math.abs(Math.floor(seed));
  const adjective = PAIRING_ADJECTIVES[base % PAIRING_ADJECTIVES.length];
  const noun = PAIRING_NOUNS[Math.abs(Math.floor(seed / 7) + 13) % PAIRING_NOUNS.length];
  return `${adjective}-${noun}`;
}

/** 从异常里取 HTTP 状态码（不是 `ApiException` → -1，例如本地抛出的 TypeError）。 */
export function apiErrorStatus(error: Object): number {
  if (error instanceof ApiException) {
    const status = (error as ApiException).statusCode;
    return status !== undefined ? status : -1;
  }
  return -1;
}

/** 异常的人类可读消息。 */
export function apiErrorMessage(error: Object): string {
  return error instanceof Error ? (error as Error).message : String(error);
}

/** 认领配对失败时给用户看的话（HTTP 状态码 → 可执行提示，而不是把服务端错误码甩出去）。 */
export function pairingErrorText(statusCode: number, fallback: string): string {
  if (statusCode === 401 || statusCode === 403) {
    return '登录状态已失效，请重新登录后再配对。';
  }
  if (statusCode === 404) {
    return '配对码无效或已过期，请在设备上重新运行配对命令。';
  }
  if (statusCode === 409) {
    return '这个配对码已经用过了，请在设备上重新生成。';
  }
  if (statusCode === 408 || statusCode === 425 || statusCode === 429) {
    return '服务端正忙，请稍后重试。';
  }
  if (statusCode >= 500) {
    return '服务端暂时不可用，请稍后重试。';
  }
  if (statusCode === 0) {
    return '网络不可达，请检查服务器地址与网络连接。';
  }
  return fallback.length > 0 ? fallback : '无法完成配对，请稍后重试。';
}

/** 设备下的会话：合并「进行中 + 已归档」→ 按设备过滤 → 按筛选档过滤 → 按 sortKey 倒序。 */
export function sessionsForDevice(
  active: AgentSession[], archived: AgentSession[], deviceId: string, filter: string
): AgentSession[] {
  const merged: AgentSession[] = [];
  const seen: string[] = [];
  for (let i = 0; i < active.length; i++) {
    const session = active[i];
    if (seen.indexOf(session.id) < 0) {
      seen.push(session.id);
      merged.push(session);
    }
  }
  for (let i = 0; i < archived.length; i++) {
    const session = archived[i];
    if (seen.indexOf(session.id) < 0) {
      seen.push(session.id);
      merged.push(session);
    }
  }
  const result: AgentSession[] = [];
  for (let i = 0; i < merged.length; i++) {
    const session = merged[i];
    if (session.connectorId !== deviceId) {
      continue;
    }
    if (filter === DeviceSessionsFilter.ACTIVE && session.archived) {
      continue;
    }
    if (filter === DeviceSessionsFilter.ARCHIVED && !session.archived) {
      continue;
    }
    result.push(session);
  }
  result.sort((a: AgentSession, b: AgentSession): number => {
    if (a.sortKey === b.sortKey) {
      return 0;
    }
    return a.sortKey < b.sortKey ? 1 : -1;
  });
  return result;
}

/** 会话区空态文案（上游 `device_detail_no_active_sessions` / `_no_archived_sessions` / `_no_sessions`）。 */
export function deviceSessionsEmptyText(filter: string): string {
  if (filter === DeviceSessionsFilter.ARCHIVED) {
    return '这台设备没有已归档会话。';
  }
  if (filter === DeviceSessionsFilter.ALL) {
    return '这台设备没有会话。';
  }
  return '这台设备没有活跃会话。';
}

/** 批量动作的目标（上游 `targetArchivedForSelection`）：选中里只要有一条未归档 → 目标就是「归档」。 */
export function selectionTargetArchived(sessions: AgentSession[], selectedIds: string[]): boolean {
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (selectedIds.indexOf(session.id) >= 0 && !session.archived) {
      return true;
    }
  }
  return false;
}

/** 批量按钮文案（上游 `bulkActionLabel`）。 */
export function bulkActionLabel(sessions: AgentSession[], selectedIds: string[]): string {
  return selectionTargetArchived(sessions, selectedIds) ? '归档所选' : '取消归档所选';
}

/**
 * 真正需要发给服务端的会话 id：只保留「当前状态与目标不一致」的那些。
 *
 * 上游把整个选中集合原样发给服务端；这里先收敛一次 —— 选中的 10 条里若已有 9 条是目标状态，
 * 就只发那 1 条（服务端结果等价，少一次无意义的写请求）。
 */
export function archiveTargetIds(sessions: AgentSession[], selectedIds: string[], archived: boolean): string[] {
  const result: string[] = [];
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (selectedIds.indexOf(session.id) >= 0 && session.archived !== archived) {
      result.push(session.id);
    }
  }
  return result;
}

/** 单选切换：返回**新数组**（ArkUI 的 @State 数组必须换引用才会重绘）。 */
export function toggleSelected(selectedIds: string[], sessionId: string): string[] {
  const next: string[] = [];
  let found = false;
  for (let i = 0; i < selectedIds.length; i++) {
    if (selectedIds[i] === sessionId) {
      found = true;
    } else {
      next.push(selectedIds[i]);
    }
  }
  if (!found) {
    next.push(sessionId);
  }
  return next;
}

/** 全选切换（上游 `onToggleSelectAll`）：可见项全都已选 → 清空，否则全选。 */
export function toggleSelectAll(visibleIds: string[], selectedIds: string[]): string[] {
  if (visibleIds.length > 0) {
    let all = true;
    for (let i = 0; i < visibleIds.length; i++) {
      if (selectedIds.indexOf(visibleIds[i]) < 0) {
        all = false;
        break;
      }
    }
    if (all) {
      return [];
    }
  }
  return visibleIds.slice();
}

/** 「全部归档」的作用域标签（上游 `archiveScopeLabelRes`）。 */
export function archiveScopeLabel(filter: string): string {
  if (filter === DeviceSessionsFilter.ACTIVE) {
    return '所有活跃会话';
  }
  if (filter === DeviceSessionsFilter.ARCHIVED) {
    return '所有已归档会话';
  }
  return '所有会话';
}

/** 「全部归档」确认框标题（上游 `device_confirm_archive_all_title` / `_unarchive_all_title`）。 */
export function archiveAllTitle(archived: boolean, filter: string): string {
  const scope = archiveScopeLabel(filter);
  return archived ? `归档这台设备上的${scope}？` : `取消归档这台设备上的${scope}？`;
}

/** 「全部归档」确认框正文（上游 `device_confirm_archive_all_body` / `_unarchive_all_body`）。 */
export function archiveAllBody(deviceName: string, archived: boolean): string {
  return archived
    ? `${deviceName} 上的这些会话会移动到已归档，之后可以再取消归档。`
    : `${deviceName} 上的所有已归档会话会移回活跃。`;
}

/** 「全部归档」确认按钮文案（上游 `device_confirm_archive_all_confirm`）。 */
export function archiveAllConfirmLabel(archived: boolean): string {
  return archived ? '归档全部' : '取消归档全部';
}

/**
 * 确认弹层状态机：`request` → 弹层；`confirm` → 请求在飞（**重复点击一律忽略**）；
 * `settled` → 结束；`failed` → 退回弹层（把错误留在弹层里给用户看，便于重试）。
 */
export function confirmNext(state: string, event: string): string {
  if (state === ConfirmPhase.CONFIRMING) {
    if (event === 'cancel') {
      return ConfirmPhase.IDLE;
    }
    if (event === 'confirm') {
      return ConfirmPhase.BUSY;
    }
    return ConfirmPhase.CONFIRMING;
  }
  if (state === ConfirmPhase.BUSY) {
    if (event === 'settled') {
      return ConfirmPhase.DONE;
    }
    if (event === 'failed') {
      return ConfirmPhase.CONFIRMING;
    }
    return ConfirmPhase.BUSY;
  }
  if (state === ConfirmPhase.DONE) {
    return event === 'reset' ? ConfirmPhase.IDLE : ConfirmPhase.DONE;
  }
  return event === 'request' ? ConfirmPhase.CONFIRMING : ConfirmPhase.IDLE;
}

/** 撤销令牌确认框标题（上游 `device_confirm_revoke_title`）。 */
export function revokeConfirmTitle(): string {
  return '撤销这台设备的令牌？';
}

/** 撤销令牌确认框正文（上游 `device_confirm_revoke_body`）。 */
export function revokeConfirmBody(deviceName: string): string {
  return `${deviceName} 当前的连接器令牌将停止工作，设备会断开连接，直到你运行新的设置命令。`;
}

/** 撤销成功后展示新命令时的说明（上游：撤销 = 重新签发凭据，用户要在设备上重跑命令）。 */
export function revokeDoneText(deviceName: string): string {
  return `${deviceName} 的旧令牌已作废。在设备上运行下面的命令，用新令牌重新连上。`;
}

/** `schema.properties` 是否声明了某个字段（决定 Runtime 配置面板显不显示这一项）。 */
export function runtimeSupportsField(schema: JsonMap | undefined, field: string): boolean {
  if (schema === undefined) {
    return false;
  }
  const properties = asRaw(schema['properties']);
  if (properties === undefined) {
    return false;
  }
  return properties[field] !== undefined && properties[field] !== null;
}

function schemaDefaultText(schema: JsonMap | undefined, field: string): string {
  if (schema === undefined) {
    return '';
  }
  const properties = asRaw(schema['properties']);
  if (properties === undefined) {
    return '';
  }
  const entry = asRaw(properties[field]);
  if (entry === undefined) {
    return '';
  }
  const value = entry['default'];
  return typeof value === 'string' ? (value as string) : '';
}

/**
 * 把 `runtime.config` 摊平成可编辑草稿（上游 `DeviceRuntime.toConfigDraft()`）：
 * `environment` 的**值为 null** 表示「移除继承值」，界面上是一个可勾选的条目。
 */
export function runtimeConfigDraft(config: JsonMap | undefined, schema: JsonMap | undefined): RuntimeConfigDraft {
  let executablePath = '';
  const rawPath = config !== undefined ? config['executablePath'] : undefined;
  if (typeof rawPath === 'string') {
    executablePath = rawPath as string;
  } else {
    executablePath = schemaDefaultText(schema, 'executablePath');
  }
  const environment: RuntimeEnvEntry[] = [];
  const rawEnv = config !== undefined ? asRaw(config['environment']) : undefined;
  if (rawEnv !== undefined) {
    const names = Object.keys(rawEnv);
    const holder: Record<string, Object | null> = rawEnv as Record<string, Object | null>;
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const value = holder[name];
      if (value === null) {
        environment.push({ name: name, value: '', unset: true });
      } else if (typeof value === 'string') {
        environment.push({ name: name, value: value as string, unset: false });
      } else {
        environment.push({ name: name, value: '', unset: false });
      }
    }
  }
  const draft: RuntimeConfigDraft = { executablePath: executablePath, environment: environment };
  return draft;
}

/** 环境变量校验（上游 `DeviceRuntimeConfigDraft.validationError`）；返回可读原因，空串表示合法。 */
export function environmentError(entries: RuntimeEnvEntry[]): string {
  const seen: string[] = [];
  const nul = String.fromCharCode(0);
  for (let i = 0; i < entries.length; i++) {
    const name = entries[i].name.trim();
    if (name.length === 0) {
      return '环境变量名称不能为空。';
    }
    if (name.indexOf('=') >= 0 || name.indexOf(nul) >= 0) {
      return '环境变量名称不能包含「=」或空字符。';
    }
    if (seen.indexOf(name) >= 0) {
      return '环境变量名称不能重复。';
    }
    seen.push(name);
  }
  return '';
}

function copyJsonMapExcept(source: JsonMap | undefined, skip: string): JsonMap {
  const out: JsonMap = {};
  if (source === undefined) {
    return out;
  }
  const keys = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== skip) {
      out[keys[i]] = source[keys[i]];
    }
  }
  return out;
}

/**
 * 草稿 → 服务端 `config`（上游 `DeviceRuntimeConfigDraft.toConfig()`）：
 * ① 保留 `baseConfig` 里我们不认识的字段（服务端 schema 可能还有别的项）；
 * ② `executablePath` 为空 = **移除该键**（ArkTS 不支持 `delete`，用「复制时跳过」实现）；
 * ③ `environment` 里 `unset` 的条目写成 **null**（服务端据此删掉继承值）。
 */
export function runtimeConfigPayload(
  base: JsonMap | undefined, draft: RuntimeConfigDraft,
  supportsExecutablePath: boolean, supportsEnvironment: boolean
): JsonMap {
  const kept = copyJsonMapExcept(copyJsonMapExcept(base, 'executablePath'), 'environment');
  const next: JsonMap = {};
  const keptKeys = Object.keys(kept);
  for (let i = 0; i < keptKeys.length; i++) {
    next[keptKeys[i]] = kept[keptKeys[i]];
  }
  if (supportsExecutablePath) {
    const path = draft.executablePath.trim();
    if (path.length > 0) {
      next['executablePath'] = path;
    }
  }
  if (supportsEnvironment) {
    const environment: Record<string, Object | null> = {};
    for (let i = 0; i < draft.environment.length; i++) {
      const entry = draft.environment[i];
      const name = entry.name.trim();
      if (name.length === 0) {
        continue;
      }
      environment[name] = entry.unset ? null : entry.value;
    }
    next['environment'] = environment as Object;
  }
  return next;
}
// ---------------------------------------------------------------------------
// R11 复刻新增：设备页（DevicesScreen）与配对向导步骤机的纯逻辑
// ---------------------------------------------------------------------------

/** Agent 预览状态（上游 `DeviceAgentPreviewState`）。 */
export class DeviceAgentState {
  static readonly LOADING: string = 'loading';
  static readonly LOADED: string = 'loaded';
  static readonly UNAVAILABLE: string = 'unavailable';
}

/**
 * 设备行副文（上游 `deviceAgentPreviewLabel`，`DevicesScreen.kt:504-521`）：
 * 离线 →「离线」；在线按预览状态给「N 个 Agent 在线 / Agent 状态不可用 / 正在获取 Agent 状态...」。
 */
export function deviceAgentPreviewLabel(online: boolean, state: string, onlineCount: number): string {
  if (!online) {
    return '离线';
  }
  if (state === DeviceAgentState.LOADED) {
    return `${onlineCount} 个 Agent 在线`;
  }
  if (state === DeviceAgentState.UNAVAILABLE) {
    return 'Agent 状态不可用';
  }
  return '正在获取 Agent 状态...';
}

/**
 * 在线 Agent 数（上游 `DeviceRuntimeList.onlineAgentCount()`，`DeviceAgentPreviewState.kt:57-63`）：
 * 已配置 + 已启用 + 状态 running 的运行时条数。
 */
export function onlineAgentCount(runtimes: RemoteDeviceRuntime[]): number {
  let count = 0;
  for (let i = 0; i < runtimes.length; i++) {
    const runtime = runtimes[i];
    if (runtime.configured && runtime.active && runtime.status === 'running') {
      count += 1;
    }
  }
  return count;
}

/**
 * 设备页排序（上游 `sortedForDevicesPage`，`DevicesScreen.kt:523-529`）：
 * 在线优先 → `createdAt` 升序（缺省当空串）→ 名称小写升序。
 */
export function sortedForDevicesPage(devices: AgentDevice[]): AgentDevice[] {
  const next = devices.slice();
  next.sort((a: AgentDevice, b: AgentDevice): number => {
    if (a.online !== b.online) {
      return a.online ? -1 : 1;
    }
    const aCreated = a.createdAt !== undefined ? a.createdAt : '';
    const bCreated = b.createdAt !== undefined ? b.createdAt : '';
    if (aCreated !== bCreated) {
      return aCreated < bCreated ? -1 : 1;
    }
    const aName = a.name.toLowerCase();
    const bName = b.name.toLowerCase();
    if (aName === bName) {
      return 0;
    }
    return aName < bName ? -1 : 1;
  });
  return next;
}

/** 配对向导的步骤（上游 `DevicePairingStep`，`DevicePairingFlow.kt:5-13`）。 */
export class PairingStep {
  static readonly CONNECTION_METHOD: string = 'connection_method';
  static readonly DESKTOP_INSTALL: string = 'desktop_install';
  static readonly CLI_CONFIRM: string = 'cli_confirm';
  static readonly NAME: string = 'name';
  static readonly CLI_METHOD: string = 'cli_method';
  static readonly COMMAND: string = 'command';
  static readonly PAIR_CODE: string = 'pair_code';
}

/** 上一步（上游 `DevicePairingStep.previous()`，`DevicePairingFlow.kt:8-12`）。 */
export function pairingPreviousStep(step: string): string {
  if (step === PairingStep.COMMAND || step === PairingStep.PAIR_CODE) {
    return PairingStep.CLI_METHOD;
  }
  if (step === PairingStep.CLI_METHOD) {
    return PairingStep.NAME;
  }
  return PairingStep.CONNECTION_METHOD;
}

/**
 * 切步骤时的**落点**（上游 `showStep(next)`，`AddDeviceScreen.kt:100-116`）：
 * 目标是「令牌命令 / 配对码」这两个**需要凭据**的步骤、而凭据还没建出来时，
 * 一律先落到「命名」步 —— 这就是「先有名字才能往下」那条规则。
 */
export function pairingStepTarget(next: string, hasCredential: boolean): string {
  if ((next === PairingStep.COMMAND || next === PairingStep.PAIR_CODE) && !hasCredential) {
    return PairingStep.NAME;
  }
  return next;
}

/**
 * 顶栏右侧画什么（上游 `AddDeviceScreen.kt:184-188`）：
 * 第一步是 `Spacer(40.dp)` 占位、其余步是 40dp 的 ✕ 关闭钮 —— 两者同宽，标题因此始终居中。
 */
export function pairingShowsCloseButton(step: string): boolean {
  return step !== PairingStep.CONNECTION_METHOD;
}

/** 底部主按钮是否可用（上游 `DevicePairingStepActions`，`AddDeviceScreen.kt:123-135`）。 */
export function pairingPrimaryEnabled(step: string, name: string, code: string): boolean {
  if (step === PairingStep.NAME) {
    return name.trim().length > 0;
  }
  if (step === PairingStep.PAIR_CODE) {
    return code.length === PAIR_CODE_LENGTH;
  }
  return step === PairingStep.DESKTOP_INSTALL || step === PairingStep.CLI_CONFIRM;
}

/** 底部主按钮文案（上游 `DevicePairingStepActions`；无主按钮的步骤返回空串）。 */
export function pairingPrimaryLabel(step: string): string {
  if (step === PairingStep.NAME) {
    return '继续';
  }
  if (step === PairingStep.PAIR_CODE) {
    return '认领';
  }
  if (step === PairingStep.DESKTOP_INSTALL) {
    return '完成';
  }
  if (step === PairingStep.CLI_CONFIRM) {
    return '继续使用命令行';
  }
  return '';
}

export interface DeviceCredential {
  deviceId: string;
  deviceToken: string;
  tokenPrefix: string;
}

export class DeviceStore {
  private static instance?: DeviceStore;

  deviceId: string = '';
  deviceName: string = '';
  deviceOs: string = '';
  online: boolean = false;
  lastSeenAt: string = '';
  runtimes: RemoteDeviceRuntime[] = [];
  loading: boolean = false;
  discovering: boolean = false;
  error: string = '';
  notice: string = '';

  private listeners: Array<() => void> = [];

  static get(): DeviceStore {
    if (DeviceStore.instance === undefined) {
      DeviceStore.instance = new DeviceStore();
    }
    return DeviceStore.instance;
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

  /** 绑定设备信息（从工作台列表带过来）。 */
  bind(deviceId: string, name: string, deviceOs: string, online: boolean, lastSeenAt: string): void {
    this.deviceId = deviceId;
    this.deviceName = name;
    this.deviceOs = deviceOs;
    this.online = online;
    this.lastSeenAt = lastSeenAt;
  }

  async load(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || this.deviceId.length === 0) {
      return;
    }
    this.loading = true;
    this.error = '';
    this.notify();
    try {
      const services = AppServices.get();
      const device = await services.devices.getDevice(serverUrl, token, this.deviceId);
      this.deviceName = device.name;
      this.deviceOs = device.deviceOs !== undefined ? device.deviceOs : '';
      this.online = device.status === 'online';
      this.lastSeenAt = device.lastSeenAt !== undefined ? device.lastSeenAt : '';
      const list = await services.devices.listDeviceRuntimes(serverUrl, token, this.deviceId);
      this.runtimes = list.runtimes;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.loading = false;
      this.notify();
    }
  }

  async discover(): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    this.discovering = true;
    this.error = '';
    this.notify();
    try {
      const list = await AppServices.get().devices.discoverDeviceRuntimes(serverUrl, token, this.deviceId);
      this.runtimes = list.runtimes;
      this.notice = `已发现 ${list.runtimes.length} 个 Runtime。`;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.discovering = false;
      this.notify();
    }
  }

  async setRuntimeActive(runtimeId: string, active: boolean): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const updated = await AppServices.get().devices.setDeviceRuntimeActive(
        serverUrl, token, this.deviceId, runtimeId, active);
      this.replaceRuntime(updated);
      this.notice = active ? '已请求启动该 Runtime。' : '已停止该 Runtime。';
      this.notify();
      // ⚠️ 启动是**异步**的：服务端 `_start_locked` 发令即返回，拿到的是
      // Connector 当时上报的状态（DSH 的 Bridge 没就绪时就是 `starting`），
      // 服务端**不会**等它变成 `running`（`device_runtimes.py` L487-512）。
      // 不轮询的话界面会永远停在「启动中」，用户只能退出重进才看得到结果。
      if (active) {
        this.pollRuntimeUntilSettled(runtimeId, 0);
      }
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  /**
   * 轮询到运行时状态「稳定」为止（running / error / stopped / unavailable）。
   *
   * 退避间隔照抄上游 `NewSessionRuntimeInventory.kt` 的
   * `RECONNECT_DELAYS = [500, 1000, 2000, 4000, 8000]`：启动中的运行时通常在
   * 1~8 秒内落定，前几次密一点体验好，后面的间隔避免空转。
   */
  private pollRuntimeUntilSettled(runtimeId: string, attempt: number): void {
    const delays: number[] = [500, 1000, 2000, 4000, 8000];
    if (attempt >= delays.length) {
      return;
    }
    setTimeout(() => {
      this.refreshRuntimes().then((ok: boolean) => {
        if (!ok) {
          return;
        }
        const runtime = this.findRuntime(runtimeId);
        const stillMoving = runtime !== undefined &&
          (runtime.status === 'starting' || runtime.status === 'validating' ||
            runtime.status === 'discovering' || runtime.status === 'stopping');
        if (stillMoving) {
          this.pollRuntimeUntilSettled(runtimeId, attempt + 1);
        }
      });
    }, delays[attempt]);
  }

  private findRuntime(runtimeId: string): RemoteDeviceRuntime | undefined {
    for (let i = 0; i < this.runtimes.length; i++) {
      if (this.runtimes[i].runtimeId === runtimeId) {
        return this.runtimes[i];
      }
    }
    return undefined;
  }

  /** 只刷新运行时列表（不重拉设备信息），用于启动后的状态轮询。 */
  async refreshRuntimes(): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || this.deviceId.length === 0) {
      return false;
    }
    try {
      const list = await AppServices.get().devices.listDeviceRuntimes(serverUrl, token, this.deviceId);
      this.runtimes = list.runtimes;
      this.notify();
      return true;
    } catch (error) {
      // 轮询失败不覆盖页面上的主错误（只有用户主动操作引起的错误才值得展示）。
      return false;
    }
  }

  async saveRuntimeConfig(runtimeId: string, config: Record<string, Object>): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const updated = await AppServices.get().devices.putDeviceRuntimeConfig(
        serverUrl, token, this.deviceId, runtimeId, config);
      this.replaceRuntime(updated);
      this.notice = 'Runtime 配置已保存。';
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  async clearRuntimeConfig(runtimeId: string): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const updated = await AppServices.get().devices.deleteDeviceRuntimeConfig(
        serverUrl, token, this.deviceId, runtimeId);
      this.replaceRuntime(updated);
      this.notice = 'Runtime 配置已清除。';
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  /**
   * 撤销当前设备的令牌（`POST /connectors/{id}/revoke`；上游 `DeviceActionsSheet` 的「撤销」
   * → `DevicesController.prepareDeviceSetup`）。
   *
   * ⚠️ 语义不是「删设备」：服务端会签发**新**令牌并返回，旧令牌立即失效 ——
   * 设备随即掉线，必须在该设备上重跑新命令才能回来。上游拿到新凭据后打开设置面板展示命令；
   * 本工程由页面用 `tokenCommand` 把新命令展示在弹层里。
   */
  async revokeToken(): Promise<DeviceCredential | undefined> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || this.deviceId.length === 0) {
      this.error = '登录状态或设备信息缺失，无法撤销令牌。';
      this.notify();
      return undefined;
    }
    this.error = '';
    this.notice = '';
    this.notify();
    try {
      const response = await AppServices.get().devices.revokeDevice(serverUrl, token, this.deviceId);
      const credential: DeviceCredential = {
        deviceId: response.device.id,
        deviceToken: response.deviceToken,
        tokenPrefix: response.tokenPrefix !== undefined ? response.tokenPrefix : ''
      };
      this.notice = '已撤销该设备的令牌。';
      this.notify();
      return credential;
    } catch (error) {
      this.error = pairingErrorText(apiErrorStatus(error as Object), apiErrorMessage(error as Object));
      this.notify();
      return undefined;
    }
  }

  /**
   * 批量归档 / 取消归档指定会话（`POST /sessions/archive` / `/sessions/unarchive`）。
   *
   * `DashboardStore.setSessionArchived` 一次只发一个 id、且每次都会 `refreshAll()` ——
   * 设备详情的「归档所选」是多选，逐个发就成了 N 次请求 + N 次刷新。
   * `SessionsApi` 本来就收 id 数组，这里直接走批量接口。
   */
  async setSessionsArchived(ids: string[], archived: boolean): Promise<boolean> {
    if (ids.length === 0) {
      return true;
    }
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    this.error = '';
    try {
      if (archived) {
        await AppServices.get().sessions.archiveSessions(serverUrl, token, ids);
        this.notice = `已归档 ${ids.length} 个会话。`;
      } else {
        await AppServices.get().sessions.unarchiveSessions(serverUrl, token, ids);
        this.notice = `已取消归档 ${ids.length} 个会话。`;
      }
      this.notify();
      return true;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.notify();
      return false;
    }
  }

  async runtimeCapabilities(runtimeId: string): Promise<RemoteRuntimeCapabilitySet> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const response = await AppServices.get().devices.getDeviceRuntimeCapabilities(
        serverUrl, token, this.deviceId, runtimeId);
      return response.capabilitySet;
    } catch (error) {
      return { revision: 0, capabilities: [] };
    }
  }

  private replaceRuntime(updated: RemoteDeviceRuntime): void {
    const next: RemoteDeviceRuntime[] = [];
    let replaced = false;
    for (let i = 0; i < this.runtimes.length; i++) {
      const runtime = this.runtimes[i];
      if (runtime.runtimeId === updated.runtimeId) {
        next.push(updated);
        replaced = true;
      } else {
        next.push(runtime);
      }
    }
    if (!replaced) {
      next.push(updated);
    }
    this.runtimes = next;
  }

  /**
   * 单台设备的在线 Agent 数（设备页预览用；上游 `rememberDeviceAgentPreviews` 走的就是
   * 同一个 `listDeviceRuntimes` —— 每台在线设备一次请求）。
   *
   * 返回 **-1** 表示取不到（网络/权限/设备刚下线），页面据此显示「Agent 状态不可用」。
   */
  static async onlineAgentCountFor(deviceId: string): Promise<number> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const list = await AppServices.get().devices.listDeviceRuntimes(serverUrl, token, deviceId);
      return onlineAgentCount(list.runtimes);
    } catch (error) {
      return -1;
    }
  }

  /**
   * 单台设备此刻是否在线（配对向导的「等待设备上线」轮询用；上游 `DevicePairingMonitor`
   * 也是反复打同一个 `GET /connectors/{id}`）。
   */
  static async isDeviceOnline(deviceId: string): Promise<boolean> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    try {
      const device = await AppServices.get().devices.getDevice(serverUrl, token, deviceId);
      return device.status === 'online';
    } catch (error) {
      return false;
    }
  }

  /** 当前服务器地址下的配对命令（页面直接展示给用户抄到设备上）。 */
  static pairingCommandText(): string {
    return pairingCommand(readServerUrl());
  }

  /** 用新令牌在设备上启动 Connector 的命令（撤销令牌后展示）。 */
  static tokenCommandText(deviceId: string, deviceToken: string): string {
    return tokenCommand(readServerUrl(), deviceId, deviceToken);
  }

  /**
   * 用配对码认领一台**已创建待配对**的设备（`POST /pairing/claim`）。
   *
   * 上游流程（`DevicesController.createDeviceSetup` → `claimDevicePairCode`）：
   * ① 先 `POST /connectors` 建一台设备并拿到一次性 token；
   * ② 在该设备上运行 `uvx anywhere-cli pair <server>` 生成 6 位配对码；
   * ③ 带 `{code, name, serverUrl, connectorId, connectorToken}` 回来认领。
   *
   * 失败时**抛异常**（`ApiException` 带 statusCode），由页面映射成可读文案
   * （`pairingErrorText`）—— 服务端错误码不该原样甩给用户。
   */
  static async claimPairingWithCredential(
    deviceId: string, deviceToken: string, code: string, name: string
  ): Promise<RemoteDevice> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    return await AppServices.get().devices.claimPairing(
      serverUrl, token, normalizePairCode(code), name, deviceId, deviceToken);
  }

  /**
   * 用配对码把一台新设备绑定到当前账号。
   *
   * ⚠️ 这条路径针对「配对码里自带 `connectorId:connectorToken` 或 JSON」的兼容场景；
   * 官方流程是先建后领 —— 见 `claimPairingWithCredential`。
   */
  static async claimPairing(code: string, name: string): Promise<DeviceCredential | undefined> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    const trimmed = code.trim();
    if (trimmed.length === 0) {
      return undefined;
    }
    // 配对码里可能带 connectorId/connectorToken（`id:token` 或 JSON），两种都兼容
    let deviceId = '';
    let deviceToken = '';
    if (trimmed.startsWith('{')) {
      try {
        const raw = JSON.parse(trimmed) as Raw;
        deviceId = typeof raw['connectorId'] === 'string' ? raw['connectorId'] as string : '';
        deviceToken = typeof raw['connectorToken'] === 'string' ? raw['connectorToken'] as string : '';
      } catch (error) {
        deviceId = '';
      }
    } else if (trimmed.includes(':')) {
      const index = trimmed.indexOf(':');
      deviceId = trimmed.substring(0, index);
      deviceToken = trimmed.substring(index + 1);
    }
    const claimed = await AppServices.get().devices.claimPairing(
      serverUrl, token, trimmed, name, deviceId, deviceToken);
    const credential: DeviceCredential = {
      deviceId: claimed.id,
      deviceToken: deviceToken,
      tokenPrefix: ''
    };
    return credential;
  }

  /** 新建一台设备并拿到 token（服务端 `/connectors`）。 */
  static async createDevice(name: string): Promise<DeviceCredential> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    const response = await AppServices.get().devices.createDevice(serverUrl, token, name);
    const credential: DeviceCredential = {
      deviceId: response.device.id,
      deviceToken: response.deviceToken,
      tokenPrefix: response.tokenPrefix !== undefined ? response.tokenPrefix : ''
    };
    return credential;
  }
}

export { parseCapabilitySet, parseModelCatalog, parsePermissionCatalog };
