/**
 * 新建会话的「上次选择」记忆（对照上游 `NewSessionPreferenceStore.kt`）。
 *
 * 为什么需要它（用户原话「新建能保留默认设置」）：本页每次都把
 * 设备 / Agent / 模型 / 推理强度 / 权限模式重置成「第一个可用项」，用户每次新建都要重选一遍；
 * 而真机上默认权限模式是「仅可查看」，忘了改就会建出一个只能读的会话 ——
 * ⇒ **记住上次选择**比「再给一个更聪明的默认值」可靠得多。
 *
 * 存储形状（**单键 + 按账号分桶**，避免动态键名；见 store/AppPreferences 的 NEW_SESSION_PREF_KEY）：
 *  { entries: [ { account, deviceId, runtimeId, selections: [ { scope, modelId, reasoningId, permissionId } ] } ] }
 *
 * 为什么按 deviceId|runtimeId 再分一层（与上游一致的语义）：模型与权限目录**是随 Runtime 变的**，
 * 在 A 设备 Codex 上选的模型搬到 B 设备 Claude Code 上没有意义。
 *
 * 本文件是**纯逻辑**（无 ArkUI / 无 Kit 依赖）⇒ 可在 Node 里直接断言（见 tools/logic-test/suite-new-session-pref.mjs）。
 */

/** 一个 Runtime 作用域下记住的三项选择。 */
export interface NewSessionSelection {
  modelId: string;
  reasoningId: string;
  permissionId: string;
  /** R52：DSH 的会话级 Agent 预设（别的 runtime 恒为空串）。 */
  agentPresetId: string;
}

/** 某个作用域（设备 + Agent）下的选择，scope = deviceId + 竖线 + runtimeId。 */
export interface NewSessionScopeSelection {
  scope: string;
  modelId: string;
  reasoningId: string;
  permissionId: string;
  agentPresetId: string;
}

/** 一个账号记住的「上次目标 + 各作用域的选择」。 */
export interface NewSessionPreferenceEntry {
  account: string;
  deviceId: string;
  runtimeId: string;
  selections: NewSessionScopeSelection[];
}

/** 整本偏好（多账号）。 */
export interface NewSessionPreferenceBook {
  entries: NewSessionPreferenceEntry[];
}

export function emptySelection(): NewSessionSelection {
  return { modelId: '', reasoningId: '', permissionId: '', agentPresetId: '' };
}

export function emptyBook(): NewSessionPreferenceBook {
  return { entries: [] };
}

/** 账号键：服务器 + 用户。两者任一为空时返回空串（**不落盘**，与上游 key == null 同义）。 */
export function newSessionAccountKey(serverUrl: string, userId: string): string {
  const server = serverUrl.trim().replace(/\/+$/, '');
  const user = userId.trim();
  if (server.length === 0 || user.length === 0) {
    return '';
  }
  return server + '|' + user;
}

export function newSessionScope(deviceId: string, runtimeId: string): string {
  return deviceId.trim() + '|' + runtimeId.trim();
}

// ---- 取值助手（JSON.parse 的结果在 ArkTS 里是 Object，需要显式窄化）----

function asRecord(value: Object | undefined | null): Record<string, Object> | undefined {
  if (value === undefined || value === null || typeof value !== 'object') {
    return undefined;
  }
  return value as Record<string, Object>;
}

function asArray(value: Object | undefined | null): Object[] {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  return value as Object[];
}

function asString(value: Object | undefined | null, fallback: string): string {
  if (typeof value === 'string') {
    return value as string;
  }
  return fallback;
}

/**
 * 解析整本偏好。**任何损坏都退化成空书**（不抛异常）——
 * 这条偏好只是「省一次点击」，绝不能因为它坏掉就让新建页打不开。
 */
export function decodePreferenceBook(raw: string): NewSessionPreferenceBook {
  const book = emptyBook();
  if (raw.length === 0) {
    return book;
  }
  let parsed: Object | undefined = undefined;
  try {
    parsed = JSON.parse(raw) as Object;
  } catch (error) {
    return book;
  }
  const root = asRecord(parsed);
  if (root === undefined) {
    return book;
  }
  const rawEntries = asArray(root['entries']);
  for (let i = 0; i < rawEntries.length; i++) {
    const item = asRecord(rawEntries[i]);
    if (item === undefined) {
      continue;
    }
    const account = asString(item['account'], '');
    if (account.length === 0) {
      continue;
    }
    const selections: NewSessionScopeSelection[] = [];
    const rawSelections = asArray(item['selections']);
    for (let j = 0; j < rawSelections.length; j++) {
      const selection = asRecord(rawSelections[j]);
      if (selection === undefined) {
        continue;
      }
      const scope = asString(selection['scope'], '');
      if (scope.length === 0) {
        continue;
      }
      selections.push({
        scope: scope,
        modelId: asString(selection['modelId'], ''),
        reasoningId: asString(selection['reasoningId'], ''),
        permissionId: asString(selection['permissionId'], ''),
        agentPresetId: asString(selection['agentPresetId'], '')
      });
    }
    book.entries.push({
      account: account,
      deviceId: asString(item['deviceId'], ''),
      runtimeId: asString(item['runtimeId'], ''),
      selections: selections
    });
  }
  return book;
}

export function encodePreferenceBook(book: NewSessionPreferenceBook): string {
  return JSON.stringify(book);
}

/** 取某账号的条目（没有则 undefined）。 */
export function readPreferenceEntry(book: NewSessionPreferenceBook, account: string): NewSessionPreferenceEntry | undefined {
  if (account.length === 0) {
    return undefined;
  }
  for (let i = 0; i < book.entries.length; i++) {
    if (book.entries[i].account === account) {
      return book.entries[i];
    }
  }
  return undefined;
}

function copySelections(source: NewSessionScopeSelection[]): NewSessionScopeSelection[] {
  const out: NewSessionScopeSelection[] = [];
  for (let i = 0; i < source.length; i++) {
    const item = source[i];
    out.push({
      scope: item.scope,
      modelId: item.modelId,
      reasoningId: item.reasoningId,
      permissionId: item.permissionId,
      agentPresetId: item.agentPresetId
    });
  }
  return out;
}

/** 不可变写入：返回新书，不改原书（好让调用方直接赋给 @State）。 */
function withEntry(book: NewSessionPreferenceBook, account: string,
  deviceId: string, runtimeId: string): NewSessionPreferenceBook {
  const next = emptyBook();
  for (let i = 0; i < book.entries.length; i++) {
    const entry = book.entries[i];
    if (entry.account === account) {
      continue;
    }
    next.entries.push({
      account: entry.account,
      deviceId: entry.deviceId,
      runtimeId: entry.runtimeId,
      selections: copySelections(entry.selections)
    });
  }
  const previous = readPreferenceEntry(book, account);
  next.entries.push({
    account: account,
    deviceId: deviceId.trim(),
    runtimeId: runtimeId.trim(),
    selections: previous === undefined ? [] : copySelections(previous.selections)
  });
  return next;
}

/** 记住「上次用的设备 + Agent」。设备或 Agent 为空时原样返回（不记半截状态）。 */
export function withTarget(book: NewSessionPreferenceBook, account: string,
  deviceId: string, runtimeId: string): NewSessionPreferenceBook {
  if (account.length === 0 || deviceId.trim().length === 0 || runtimeId.trim().length === 0) {
    return book;
  }
  return withEntry(book, account, deviceId, runtimeId);
}

/** 记住某作用域下的三项选择（模型 / 推理强度 / 权限模式）。 */
export function withSelection(book: NewSessionPreferenceBook, account: string,
  deviceId: string, runtimeId: string, selection: NewSessionSelection): NewSessionPreferenceBook {
  if (account.length === 0 || deviceId.trim().length === 0 || runtimeId.trim().length === 0) {
    return book;
  }
  const base = withEntry(book, account, deviceId, runtimeId);
  const scope = newSessionScope(deviceId, runtimeId);
  const entry = readPreferenceEntry(base, account);
  if (entry === undefined) {
    return base;
  }
  // ⚠️ 四项全空 = 用户还没做出任何有效选择（本页的选择项一旦选中必有值）⇒
  // **原样保留**该作用域的既有记录 —— 注意不能走下面的「过滤后重建」，那等于把它删掉。
  // （这条是单测抓出来的：先前写成「过滤掉该 scope 后不补回」，于是「切到新 Agent 再切回来」会丢记忆。）
  // ⚠️ R52 加 `agentPresetId` 时**必须同步加进这个判空**：漏掉它的话，只改了预设
  // （模型/推理/权限都没动）会被当成「还没选」而整条丢弃。
  if (selection.modelId.length === 0 && selection.reasoningId.length === 0
    && selection.permissionId.length === 0 && selection.agentPresetId.length === 0) {
    return base;
  }
  const kept: NewSessionScopeSelection[] = [];
  for (let i = 0; i < entry.selections.length; i++) {
    if (entry.selections[i].scope !== scope) {
      kept.push({
        scope: entry.selections[i].scope,
        modelId: entry.selections[i].modelId,
        reasoningId: entry.selections[i].reasoningId,
        permissionId: entry.selections[i].permissionId,
        agentPresetId: entry.selections[i].agentPresetId
      });
    }
  }
  kept.push({
    scope: scope,
    modelId: selection.modelId,
    reasoningId: selection.reasoningId,
    permissionId: selection.permissionId,
    agentPresetId: selection.agentPresetId
  });
  const next = emptyBook();
  for (let i = 0; i < base.entries.length; i++) {
    const item = base.entries[i];
    if (item.account === account) {
      next.entries.push({
        account: item.account,
        deviceId: item.deviceId,
        runtimeId: item.runtimeId,
        selections: kept
      });
    } else {
      next.entries.push({
        account: item.account,
        deviceId: item.deviceId,
        runtimeId: item.runtimeId,
        selections: copySelections(item.selections)
      });
    }
  }
  return next;
}

/**
 * 恢复：给出某作用域上次记住的三项选择。
 * 作用域不匹配（换了设备/Agent）时返回 undefined，由调用方回落到各自目录的默认值。
 */
export function restoreSelection(entry: NewSessionPreferenceEntry | undefined,
  deviceId: string, runtimeId: string): NewSessionSelection | undefined {
  if (entry === undefined) {
    return undefined;
  }
  const scope = newSessionScope(deviceId, runtimeId);
  for (let i = 0; i < entry.selections.length; i++) {
    const item = entry.selections[i];
    if (item.scope === scope) {
      return {
        modelId: item.modelId,
        reasoningId: item.reasoningId,
        permissionId: item.permissionId,
        agentPresetId: item.agentPresetId
      };
    }
  }
  return undefined;
}

/**
 * 恢复设备：上次用的设备**还在可用列表里**才返回它，否则返回空串（由调用方选第一个）。
 * 这条「先校验再恢复」是必须的 —— 用户可能换了设备、或那台机器已离线。
 */
export function pickRestorableDevice(entry: NewSessionPreferenceEntry | undefined, availableIds: string[]): string {
  if (entry === undefined || entry.deviceId.length === 0) {
    return '';
  }
  for (let i = 0; i < availableIds.length; i++) {
    if (availableIds[i] === entry.deviceId) {
      return entry.deviceId;
    }
  }
  return '';
}

/** 恢复 Agent：仅当记的就是这台设备的 Agent 且它仍在**就绪**列表里才返回。 */
export function pickRestorableRuntime(entry: NewSessionPreferenceEntry | undefined,
  deviceId: string, readyRuntimeIds: string[]): string {
  if (entry === undefined || entry.deviceId !== deviceId || entry.runtimeId.length === 0) {
    return '';
  }
  for (let i = 0; i < readyRuntimeIds.length; i++) {
    if (readyRuntimeIds[i] === entry.runtimeId) {
      return entry.runtimeId;
    }
  }
  return '';
}

/** 在某目录里挑一个仍存在的 id（模型目录会随 Runtime 变化）。 */
export function pickExistingId(preferredId: string, availableIds: string[]): string {
  if (preferredId.length === 0) {
    return '';
  }
  for (let i = 0; i < availableIds.length; i++) {
    if (availableIds[i] === preferredId) {
      return preferredId;
    }
  }
  return '';
}
