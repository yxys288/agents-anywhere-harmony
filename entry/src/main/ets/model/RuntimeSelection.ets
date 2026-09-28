/**
 * 会话运行时选型（模型 / 推理强度 / 权限模式）的**纯逻辑层**。
 *
 * 对应上游 Android：
 *  - `ui/screens/sessiondetail/SessionRuntimeSettingsSheet.kt`：ModelPage / ModeEffortPage /
 *  PermissionSection / EffortSelectionSection / SheetLoading / SheetError / SheetEmpty；
 *  - `feature/sessiondetail/SessionRuntimeState.kt`：`RuntimeSelectionOption`、
 *  `RemoteRuntimeModelCatalog.selectionOptions()`、`groupByModelLabel()`、`validatedSelection()`。
 *
 * ⚠️ 本文件**零 ArkUI、零 @kit 依赖**（只 import 同目录的纯类型 `./Types`），
 * 因此可以被 `tools/logic-test/suite-runtime.mjs` 转译到 Node 里直接断言 ——
 * 「分组 / 默认项 / effort 回退 / 禁用原因 / 三态 / 已选值失效」这些判定在无设备时也能复现。
 */

import {
  RemoteRuntimeModelCatalog, RemoteRuntimePermissionCatalog, RemoteRuntimeReasoning
} from './Types';

/** `/runtime/selections` 里模型那一项的键（上游 `updateSelection("model", ...)`）。 */
export const RUNTIME_MODEL_KEY: string = 'model';
/** `/runtime/selections` 里权限模式那一项的键。 */
export const RUNTIME_PERMISSION_KEY: string = 'permission';
/** 模型目录的能力位（上游 `SESSION_MODEL_CATALOG_CAPABILITY`）。 */
export const RUNTIME_MODEL_CAPABILITY: string = 'catalog.model';
/** 权限目录的能力位（上游 `SESSION_PERMISSION_CATALOG_CAPABILITY`）。 */
export const RUNTIME_PERMISSION_CAPABILITY: string = 'catalog.permission';
/** 模型名与推理档之间的分隔符（上游 `" · "`，前后各一个半角空格）。 */
export const RUNTIME_LABEL_SEPARATOR: string = ' · ';

/** 目录段三态（与上游 `ModelOptions` / `PermissionSection` 的 when 分支一一对应）。 */
export const RUNTIME_SECTION_READY: string = 'ready';
export const RUNTIME_SECTION_LOADING: string = 'loading';
export const RUNTIME_SECTION_ERROR: string = 'error';
export const RUNTIME_SECTION_EMPTY: string = 'empty';

/** 一个可选中的运行时选型项（上游 `feature/sessiondetail/RuntimeSelectionOption`）。 */
export interface RuntimeSelectionOption {
  /** 提交给 `/runtime/selections` 的值。 */
  selectionId: string;
  /** 展示文本。模型项形如「模型名 · 推理档」，无推理档时只有模型名。 */
  label: string;
  description?: string;
  /** 服务端标称的默认项。 */
  isDefault: boolean;
  enabled: boolean;
  disabledReason?: string;
}

/** 同一模型下的所有推理档（上游 `ModelOptionGroup`）。 */
export interface ModelOptionGroup {
  /** 模型显示名（由 `label` 在首个分隔符前切出）。 */
  label: string;
  options: RuntimeSelectionOption[];
}

/**
 * 界面文案：逐字抄自上游 `app/src/main/res/values-zh-rCN/strings.xml`（注释里给的是 key）。
 * 换成别的措辞就是与安卓端不一致，别改。
 *
 * ⚠️ 这里**只放会话详情真的用到的 key**。上游那些没被任何 Kotlin 代码引用的 key
 * （`session_runtime_model_loading` / `session_runtime_permission_loading` /
 * `session_runtime_model_unavailable` / `session_runtime_permission_unavailable` /
 * `session_runtime_catalog_empty` / `session_runtime_catalog_loading` /
 * `session_runtime_settings_title`）一律不搬 —— 搬过来就等于自创一处安卓端不存在的提示。
 * 同理 `session_runtime_mode_effort` 只被用作 sheet 的**页面标题**（`SessionRuntimeSettingsSheet.kt:101`），
 * 鸿蒙端是内联展开、没有 sheet 标题可挂，所以也不需要它（面板标题沿用既有的「运行时设置」）。
 */
export class RuntimeText {
  /** `session_runtime_select_model`（sheet 第一页标题）。 */
  static readonly SELECT_MODEL: string = '选择模型';
  /** `session_runtime_permission_mode`（PermissionSection 的段标题）。 */
  static readonly PERMISSION_MODE: string = '权限模式';
  /** `session_runtime_effort_default`（没有推理档时的显示标签）。 */
  static readonly EFFORT_DEFAULT: string = '默认';
  /** `session_runtime_no_settings`（SheetEmpty；也是入口行副文本为空时的兜底）。 */
  static readonly NO_SETTINGS: string = '暂无可用设置';
  /** `common_retry`（SheetError 里的按钮文本）。 */
  static readonly RETRY: string = '重试';
  /** `session_selection_update_failed`（点到不可用项时的提示，上游 onSelectModel 的兜底）。 */
  static readonly UPDATE_FAILED: string = '无法更新运行时选择。';

  /** 上游 `session_runtime_effort_for` 是带 `%1$s` 占位符的格式化串。 */
  static effortFor(modelLabel: string): string {
    return modelLabel + ' 的推理强度';
  }
}

// ---------------------------------------------------------------------------
// 标签切分
// ---------------------------------------------------------------------------

/** `String.substringBefore(marker)`：找不到 marker 时返回整串。 */
export function substringBefore(text: string, marker: string): string {
  const index = text.indexOf(marker);
  return index >= 0 ? text.substring(0, index) : text;
}

/** `String.substringAfter(marker, "")`：找不到 marker 时返回空串。 */
export function substringAfter(text: string, marker: string): string {
  const index = text.indexOf(marker);
  return index >= 0 ? text.substring(index + marker.length) : '';
}

/** 上游 `RuntimeSelectionOption.modelLabel`：分隔符之前的部分，空则回退整串。 */
export function splitModelLabel(label: string): string {
  const head = substringBefore(label, RUNTIME_LABEL_SEPARATOR);
  return head.length > 0 ? head : label;
}

/** 上游 `RuntimeSelectionOption.effortLabel`：分隔符之后的部分，空串表示没有推理档。 */
export function effortLabelOf(label: string): string {
  const tail = substringAfter(label, RUNTIME_LABEL_SEPARATOR);
  return tail;
}

/**
 * 上游 `effortDisplayLabel(defaultLabel)`：没有推理档时回退到「默认」。
 * 注意参数是**选项**而不是裸 label —— 调用方拿到的通常是目录里的原始选项。
 */
export function effortDisplayLabel(option: RuntimeSelectionOption, defaultLabel: string): string {
  const tail = effortLabelOf(option.label);
  return tail.length > 0 ? tail : defaultLabel;
}

// ---------------------------------------------------------------------------
// 分组与代表项
// ---------------------------------------------------------------------------

/** 上游 `groupByModelLabel()`：按模型名分组，**保持首次出现的顺序**（Kotlin `groupBy` 保序）。 */
export function groupByModelLabel(options: RuntimeSelectionOption[]): ModelOptionGroup[] {
  const groups: ModelOptionGroup[] = [];
  for (let i = 0; i < options.length; i++) {
    const option = options[i];
    const label = splitModelLabel(option.label);
    let target: ModelOptionGroup | undefined = undefined;
    for (let j = 0; j < groups.length; j++) {
      if (groups[j].label === label) {
        target = groups[j];
        break;
      }
    }
    if (target === undefined) {
      target = { label: label, options: [] };
      groups.push(target);
    }
    target.options.push(option);
  }
  return groups;
}

/**
 * 当前选中项所在的组（上游 `selectedModelGroup`）：
 * 先找含选中 id 的组，找不到退回第一组。
 */
export function selectedModelGroup(
  groups: ModelOptionGroup[], selectedId: string
): ModelOptionGroup | undefined {
  for (let i = 0; i < groups.length; i++) {
    if (groupContains(groups[i], selectedId)) {
      return groups[i];
    }
  }
  return groups.length > 0 ? groups[0] : undefined;
}

/** 该组是否含某个 selectionId。 */
export function groupContains(group: ModelOptionGroup, selectionId: string): boolean {
  if (selectionId.length === 0) {
    return false;
  }
  for (let i = 0; i < group.options.length; i++) {
    if (group.options[i].selectionId === selectionId) {
      return true;
    }
  }
  return false;
}

/**
 * 组的**代表项**（上游 `ModelOptions` 里每组挑一个来显示）：
 * 当前项 → 首个「可用且默认」→ 首个可用 → 首个。
 * 组为空时返回 undefined（调用方必须判）。
 */
export function displayOptionForGroup(
  group: ModelOptionGroup, selectedId: string
): RuntimeSelectionOption | undefined {
  if (group.options.length === 0) {
    return undefined;
  }
  for (let i = 0; i < group.options.length; i++) {
    if (group.options[i].selectionId === selectedId) {
      return group.options[i];
    }
  }
  for (let i = 0; i < group.options.length; i++) {
    if (group.options[i].enabled && group.options[i].isDefault) {
      return group.options[i];
    }
  }
  for (let i = 0; i < group.options.length; i++) {
    if (group.options[i].enabled) {
      return group.options[i];
    }
  }
  return group.options[0];
}

/**
 * 组的代表项是否该显示成「选中」（上游 `option.selectionId in selectedIds`）：
 * 只要该组里**任意**一项是当前选中值，整组就算选中。
 */
export function isGroupSelected(group: ModelOptionGroup, selectedId: string): boolean {
  return groupContains(group, selectedId);
}

/** 代表项要提交的 selectionId（组为空或代表项无 id 时是空串）。 */
export function groupSelectionId(group: ModelOptionGroup, selectedId: string): string {
  const option = displayOptionForGroup(group, selectedId);
  return option !== undefined ? option.selectionId : '';
}

/** 组行的刷新 key：label 与组内每一项的可变字段都要进 key（否则行复用后不刷新）。 */
export function modelGroupKey(group: ModelOptionGroup): string {
  const parts: string[] = [group.label];
  for (let i = 0; i < group.options.length; i++) {
    const option = group.options[i];
    parts.push(option.selectionId);
    parts.push(option.enabled ? '1' : '0');
    parts.push(effortLabelOf(option.label));
    parts.push(option.disabledReason !== undefined ? option.disabledReason : '');
  }
  return parts.join('|');
}

/** 单项行的刷新 key（权限行 / 推理档位行用）。 */
export function optionRowKey(option: RuntimeSelectionOption): string {
  const reason = option.disabledReason !== undefined ? option.disabledReason : '';
  const description = option.description !== undefined ? option.description : '';
  return option.selectionId + '|' + (option.enabled ? '1' : '0') + '|' + reason + '|' + description;
}

// ---------------------------------------------------------------------------
// 推理档
// ---------------------------------------------------------------------------

/**
 * 该组要显示的推理档选项（上游 `ModeEffortPage`）：**多于 1 个才显示**，
 * 只有一个时说明这个模型没有可选的推理档，整段不出现。
 */
export function effortOptionsForGroup(group: ModelOptionGroup | undefined): RuntimeSelectionOption[] {
  if (group === undefined || group.options.length <= 1) {
    return [];
  }
  return group.options.slice();
}

/** 推理档段是否需要出现（段标题用当前模型名，所以组为空时也不显示）。 */
export function hasEffortSection(group: ModelOptionGroup | undefined): boolean {
  return effortOptionsForGroup(group).length > 1;
}

/**
 * 推理档段标题（上游 `EffortSelectionSection` 的 `session_runtime_effort_for`）。
 * 拿不到分组时回退到运行时名。
 */
export function effortSectionTitle(group: ModelOptionGroup | undefined, runtimeLabel: string): string {
  const label = group !== undefined && group.label.length > 0 ? group.label : runtimeLabel;
  return RuntimeText.effortFor(label);
}

/**
 * 选中档位当前显示成什么（模型行 / 段标题右侧的当前值）。
 * 与前端分段条上的文案用的是同一套回退规则。
 */
export function selectedEffortLabel(
  group: ModelOptionGroup | undefined, selectedId: string, defaultLabel: string
): string {
  if (group === undefined) {
    return defaultLabel;
  }
  for (let i = 0; i < group.options.length; i++) {
    if (group.options[i].selectionId === selectedId) {
      return effortDisplayLabel(group.options[i], defaultLabel);
    }
  }
  const display = displayOptionForGroup(group, selectedId);
  return display !== undefined ? effortDisplayLabel(display, defaultLabel) : defaultLabel;
}

/**
 * 模型行的副文本（上游 `ModelOptions` 的 `supportingText = option.disabledReason`）。
 *
 * ⚠️ 这里**只放禁用原因**：推理档不在模型行上展示，它归下方的 EffortSegments 段
 * （上游 EffortSegments 才用 `effortDisplayLabel(defaultLabel)`）。
 */
export function modelGroupSupportingText(group: ModelOptionGroup, selectedId: string): string {
  const option = displayOptionForGroup(group, selectedId);
  if (option === undefined) {
    return '';
  }
  return option.disabledReason !== undefined ? option.disabledReason : '';
}

/**
 * 推理档段底部逐条列出的「禁用档位 + 原因」（上游 `EffortSelectionSection` 末尾）。
 * 格式逐字对齐：`<档位显示名>: <原因>`。
 */
export function disabledEffortNotes(
  options: RuntimeSelectionOption[], defaultLabel: string
): string[] {
  const notes: string[] = [];
  for (let i = 0; i < options.length; i++) {
    const option = options[i];
    if (option.enabled) {
      continue;
    }
    const reason = option.disabledReason !== undefined ? option.disabledReason : '';
    if (reason.length > 0) {
      notes.push(effortDisplayLabel(option, defaultLabel) + ': ' + reason);
    }
  }
  return notes;
}

// ---------------------------------------------------------------------------
// 可用性 / 选中值
// ---------------------------------------------------------------------------

/** 找到 selectionId 对应的下标（`onlyEnabled` 为 true 时只认可用项）。 */
function optionIndexById(
  options: RuntimeSelectionOption[], selectionId: string, onlyEnabled: boolean
): number {
  if (selectionId.length === 0) {
    return -1;
  }
  for (let i = 0; i < options.length; i++) {
    const option = options[i];
    if (option.selectionId !== selectionId) {
      continue;
    }
    if (onlyEnabled && !option.enabled) {
      continue;
    }
    return i;
  }
  return -1;
}

/**
 * 当前生效的选中值（上游 `validatedSelection`）：
 * 有明确 hint 时只在**可用项**里认它（认不到就是没有，不回退）；
 * 没有 hint 时取首个可用且默认，再取首个可用。空串表示「没有选中项」。
 */
export function validatedSelection(
  options: RuntimeSelectionOption[], hint: string
): string {
  if (hint.length > 0) {
    const index = optionIndexById(options, hint, true);
    return index >= 0 ? options[index].selectionId : '';
  }
  for (let i = 0; i < options.length; i++) {
    if (options[i].enabled && options[i].isDefault) {
      return options[i].selectionId;
    }
  }
  for (let i = 0; i < options.length; i++) {
    if (options[i].enabled) {
      return options[i].selectionId;
    }
  }
  return '';
}

/** 从服务端 state 的 selections 里取某个键（缺失 / 空值都当空串）。 */
export function selectionOf(selections: Record<string, string> | undefined, key: string): string {
  if (selections === undefined) {
    return '';
  }
  const value = selections[key];
  return value !== undefined ? value : '';
}

/**
 * 已选值在目录里找不到可用项（上游 `selectionMissing`）：说明目录刷过、这个选型已经没了，
 * 需要重新拉一次目录。目录本身为空时不算（那是「还没加载」）。
 */
export function selectionMissing(
  options: RuntimeSelectionOption[], selection: string
): boolean {
  if (selection.length === 0 || options.length === 0) {
    return false;
  }
  return optionIndexById(options, selection, true) < 0;
}

/**
 * 需要刷新目录时的幂等键（上游 `LaunchedEffect` 里的 `refreshKey`）。
 * 空串表示不需要刷新；与上一次的键相同也不该重刷。
 */
export function catalogRefreshKey(
  catalogDefined: boolean,
  capabilitySupported: boolean,
  selection: string,
  options: RuntimeSelectionOption[],
  capabilitiesRevision: number,
  catalogRevision: number
): string {
  if (!catalogDefined && capabilitySupported) {
    return 'catalog:' + capabilitiesRevision;
  }
  if (catalogDefined && selectionMissing(options, selection)) {
    return 'selection:' + selection + ':' + catalogRevision;
  }
  return '';
}

/**
 * 目录段的三态判定（上游 `ModelOptions` 的 when：**加载中优先于错误**）。
 * 目录已有内容时一律走 ready —— 刷新失败不该把已经看得见的列表藏起来。
 */
export function catalogSectionState(
  options: RuntimeSelectionOption[], loading: boolean, errorMessage: string
): string {
  if (options.length > 0) {
    return RUNTIME_SECTION_READY;
  }
  if (loading) {
    return RUNTIME_SECTION_LOADING;
  }
  if (errorMessage.length > 0) {
    return RUNTIME_SECTION_ERROR;
  }
  return RUNTIME_SECTION_EMPTY;
}

/** 某一项此刻能不能点（上游 `enabled = !busy && !loading && option.enabled`）。 */
export function optionSelectable(
  option: RuntimeSelectionOption, loading: boolean, busy: boolean
): boolean {
  return !busy && !loading && option.enabled;
}

/** 权限行的副文本（上游 `PermissionSection`：禁用原因优先于说明）。 */
export function permissionSupportingText(option: RuntimeSelectionOption): string {
  const reason = option.disabledReason !== undefined ? option.disabledReason : '';
  if (reason.length > 0) {
    return reason;
  }
  return option.description !== undefined ? option.description : '';
}

// ---------------------------------------------------------------------------
// 目录 → 选项
// ---------------------------------------------------------------------------

/** 推理档里 selectionId 非空的那几个（上游 `model.reasoningItems.filter { it.selectionId.isNotBlank() }`）。 */
function usableReasoning(modelReasoning: RemoteRuntimeReasoning[]): RemoteRuntimeReasoning[] {
  const out: RemoteRuntimeReasoning[] = [];
  for (let i = 0; i < modelReasoning.length; i++) {
    if (modelReasoning[i].selectionId.length > 0) {
      out.push(modelReasoning[i]);
    }
  }
  return out;
}

function joinLabel(first: string, second: string): string {
  const parts: string[] = [];
  if (first.length > 0) {
    parts.push(first);
  }
  if (second.length > 0) {
    parts.push(second);
  }
  return parts.join(RUNTIME_LABEL_SEPARATOR);
}

function distinctBySelectionId(options: RuntimeSelectionOption[]): RuntimeSelectionOption[] {
  const seen: string[] = [];
  const out: RuntimeSelectionOption[] = [];
  for (let i = 0; i < options.length; i++) {
    const option = options[i];
    if (seen.indexOf(option.selectionId) < 0) {
      seen.push(option.selectionId);
      out.push(option);
    }
  }
  return out;
}

/**
 * `RemoteRuntimeModelCatalog.selectionOptions()` 的等价物。
 * 模型带推理档时**每个档位一个选项**（label 拼成 `模型名 · 档位名`），
 * 不带推理档时模型自己就是一个选项。
 */
export function modelSelectionOptions(
  catalog: RemoteRuntimeModelCatalog | undefined
): RuntimeSelectionOption[] {
  if (catalog === undefined) {
    return [];
  }
  const out: RuntimeSelectionOption[] = [];
  for (let i = 0; i < catalog.models.length; i++) {
    const model = catalog.models[i];
    const reasoning = usableReasoning(model.reasoningItems);
    if (reasoning.length > 0) {
      for (let j = 0; j < reasoning.length; j++) {
        const item = reasoning[j];
        out.push({
          selectionId: item.selectionId,
          label: joinLabel(model.displayName, item.displayName),
          description: item.description ?? model.description,
          isDefault: item.default || (model.default && j === 0),
          enabled: model.enabled !== false && item.enabled !== false,
          disabledReason: item.disabledReason ?? model.disabledReason
        });
      }
    } else {
      const selectionId = model.selectionId !== undefined ? model.selectionId : '';
      if (selectionId.length > 0) {
        out.push({
          selectionId: selectionId,
          label: model.displayName.length > 0 ? model.displayName : model.id,
          description: model.description,
          isDefault: model.default,
          enabled: model.enabled !== false,
          disabledReason: model.disabledReason
        });
      }
    }
  }
  return distinctBySelectionId(out);
}

/** `RemoteRuntimePermissionCatalog.selectionOptions()` 的等价物。 */
export function permissionSelectionOptions(
  catalog: RemoteRuntimePermissionCatalog | undefined
): RuntimeSelectionOption[] {
  if (catalog === undefined) {
    return [];
  }
  const out: RuntimeSelectionOption[] = [];
  for (let i = 0; i < catalog.permissions.length; i++) {
    const permission = catalog.permissions[i];
    if (permission.selectionId.length === 0) {
      continue;
    }
    out.push({
      selectionId: permission.selectionId,
      label: permission.displayName.length > 0 ? permission.displayName : permission.id,
      description: permission.description,
      isDefault: permission.default,
      enabled: permission.enabled !== false,
      disabledReason: permission.disabledReason
    });
  }
  return distinctBySelectionId(out);
}

/** 权限段当前选中项的显示名（上游 `selectedPermissionLabel`）。 */
export function selectedPermissionLabel(
  options: RuntimeSelectionOption[], selectedId: string
): string {
  const index = optionIndexById(options, selectedId, false);
  return index >= 0 ? options[index].label : '';
}

