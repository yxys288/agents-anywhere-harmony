/**
 * **DSH Agent 预设**（会话级）的纯逻辑层（R51）。
 *
 * 背景：DSH 连接器给每个新会话可以指定一个「Agent 预设 / 模式」（`standard` 等）。
 * 本工程与上游 Android 客户端**都没有**这个入口 ⇒ 用户反馈「新建对话无法选择 DSH agent 预设」。
 *
 * ⚠️ 契约以**连接器 + DSH bridge 源码**为准（不是猜的）：
 *  · **可选项从哪来**：runtime 描述里的 `uiSchema.defaultAgentPreset`（DSH provider 写的
 *  `{"component":"select","options":[…]}`，见 `connector/connector/runtimes/dsh/provider.py:156`），
 *  选项形状 `{value,label,description?,disabled?,disabledReason?}` 由 bridge 的 `agentPresets()` 产出
 *  （`dsh-bridge-next/lib/index.js:4614-4623`）。该字段**只有提供预设的 runtime（目前是 DSH）才有**
 *  ⇒ 别的 runtime 读出来是空数组，行自然不显示。
 *  · **默认值**：`schema.properties.defaultAgentPreset.default`（bridge 的 `configField.default`，
 *  它只在 `standard` 可用时给）。
 *  · **怎么提交**：会话创建的 `runtimeOptions.agentPreset`
 *  （`connector/connector/runtimes/dsh/runtime.py:304-311`：只认 `agentPreset` 这一个键，
 *  缺省时回落到连接器配置里的 `defaultAgentPreset`；再经 `params["agentPreset"]` → bridge `validatePreset()`）。
 *
 * ⚠️ 本文件零 ArkUI / 零 @kit 依赖（只 import 同目录的纯类型），可被
 * `tools/logic-test/suite-agent-preset.mjs` 直接断言。
 */

import { JsonMap, RemoteDeviceRuntime } from './Types';

/** `uiSchema` 里那个字段的键名（DSH provider 与 bridge 两边都是这个字面量）。 */
export const AGENT_PRESET_FIELD: string = 'defaultAgentPreset';
/** 配置行的标签。上游那个字段的 `title` 是「新会话默认模式」（连接器**配置**语义）； */
/** 本行是**本会话**的选择，故用「Agent 预设」，与「模型 / 推理强度 / 权限模式」同一档。 */
export const AGENT_PRESET_LABEL: string = 'Agent 预设';
/** `uiSchema` 里必须等于这个值才认（不是 select 就不是选择器）。 */
export const AGENT_PRESET_COMPONENT: string = 'select';

/** 一个可选的 Agent 预设（对齐 bridge 的 `uiField.options` 条目）。 */
export interface AgentPresetOption {
  /** 提交给 `runtimeOptions.agentPreset` 的值。 */
  value: string;
  label: string;
  description?: string;
  /** 不可用（bridge 的 `disabled`，来自 `preset.broken`）。 */
  disabled: boolean;
  disabledReason?: string;
}

// ---------------------------------------------------------------------------
// 取值助手（JsonMap 的值都是 Object，逐层判型）
// ---------------------------------------------------------------------------

function nonEmptyText(value: Object | undefined): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const text = value as string;
  return text.trim().length > 0 ? text : undefined;
}

function asMap(value: Object | undefined): JsonMap | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as JsonMap;
}

function asList(value: Object | undefined): Object[] | undefined {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return undefined;
  }
  return value as Object[];
}

// ---------------------------------------------------------------------------
// 目录
// ---------------------------------------------------------------------------

/** `uiSchema.defaultAgentPreset` 本身（不是 select、或没有 options 时返回 undefined）。 */
export function agentPresetField(runtime: RemoteDeviceRuntime | undefined): JsonMap | undefined {
  if (runtime === undefined) {
    return undefined;
  }
  const uiSchema = runtime.uiSchema;
  if (uiSchema === undefined) {
    return undefined;
  }
  const field = asMap(uiSchema[AGENT_PRESET_FIELD]);
  if (field === undefined) {
    return undefined;
  }
  if (nonEmptyText(field['component']) !== AGENT_PRESET_COMPONENT) {
    return undefined;
  }
  return field;
}

/**
 * 该 runtime 可选的 Agent 预设；**没有这个字段的 runtime 返回空数组**（调用点据此隐藏整行）。
 *
 * 逐条判型：`value` / `label` 必须是非空字符串，`value` 去重（保留首次出现）——
 * 半个坏条目不该让整个选择器消失，但**重复 value** 会让选中态无法区分，必须去重。
 */
export function agentPresetOptions(runtime: RemoteDeviceRuntime | undefined): AgentPresetOption[] {
  const field = agentPresetField(runtime);
  if (field === undefined) {
    return [];
  }
  const rawOptions = asList(field['options']);
  if (rawOptions === undefined) {
    return [];
  }
  const result: AgentPresetOption[] = [];
  const seen: string[] = [];
  for (let i = 0; i < rawOptions.length; i++) {
    const raw = asMap(rawOptions[i]);
    if (raw === undefined) {
      continue;
    }
    const value = nonEmptyText(raw['value']);
    const label = nonEmptyText(raw['label']);
    if (value === undefined || label === undefined) {
      continue;
    }
    if (seen.indexOf(value) >= 0) {
      continue;
    }
    seen.push(value);
    result.push({
      value: value,
      label: label,
      description: nonEmptyText(raw['description']),
      disabled: raw['disabled'] === true,
      disabledReason: nonEmptyText(raw['disabledReason'])
    });
  }
  return result;
}

/**
 * 该 runtime 的**默认**预设 id；给不出时返回空串。
 *
 * 口径（顺序即优先级）：
 *  ① `schema.properties.defaultAgentPreset.default`，且它**确实是一个可用的选项**；
 *  ② 否则取**第一个可用选项**（bridge 的 `initial` 就是「standard 可用则 standard」，等价于它的兜底）。
 * ⚠️ 绝不返回一个 disabled 的预设 —— 服务端 `validatePreset()` 会直接拒（`INVALID_PARAMS`）。
 */
export function defaultAgentPreset(runtime: RemoteDeviceRuntime | undefined): string {
  const options = agentPresetOptions(runtime);
  if (options.length === 0) {
    return '';
  }
  const declared = declaredDefault(runtime);
  if (declared.length > 0) {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === declared && !options[i].disabled) {
        return declared;
      }
    }
  }
  for (let i = 0; i < options.length; i++) {
    if (!options[i].disabled) {
      return options[i].value;
    }
  }
  return '';
}

/** `schema.properties.defaultAgentPreset.default`（没有就是空串）。 */
function declaredDefault(runtime: RemoteDeviceRuntime | undefined): string {
  if (runtime === undefined) {
    return '';
  }
  const schema = runtime.schema;
  if (schema === undefined) {
    return '';
  }
  const properties = asMap(schema['properties']);
  if (properties === undefined) {
    return '';
  }
  const field = asMap(properties[AGENT_PRESET_FIELD]);
  if (field === undefined) {
    return '';
  }
  const value = nonEmptyText(field['default']);
  return value === undefined ? '' : value;
}


// ---------------------------------------------------------------------------
// R94：DSH **内置预设**的中文名兜底
// ---------------------------------------------------------------------------

/**
 * DSH 内置 Agent 预设的 `id → 中文名` 对照表（R94）。
 *
 * ## 为什么需要它（**根因是连接器没给 name**，不是 App 显示错了）
 * 预设的显示名来自连接器上报：bridge 的 `agentPresets()` 产出
 * `label: preset.name || preset.id`（`dsh-bridge-next/.../catalogs.ts:103`）。
 * DSH 的**内置**预设（standard / ptc / minimal / cordis）在 catalog 里**没有 name** ⇒
 * 回落成 id ⇒ App 上看到的就是 `standard` / `ptc` 这种英文标识符（用户截图里的现象）。
 * 而 DSH 自己的界面显示的是「标准模式 / PTC 模式 / 极简模式 / 创造模式」。
 *
 * ## 优先级（**连接器给的一律优先**）
 * `agentPresetLabel()` 的顺序是：
 *  ① label 与 id **不同** ⇒ 连接器确实给了名字（用户自建预设就是「标准模式_bash」这种中文名）⇒ **原样用**；
 *  ② label 与 id **相同** ⇒ 连接器没给名字 ⇒ 查本表兜底；
 *  ③ 表里也没有 ⇒ 用 id（不猜、不硬编「未知预设」）。
 * ⇒ 本表**只影响「连接器没给名」的那一档**，用户自建/改名过的预设**一个字都不会被覆盖**。
 *
 * ## ⚠️ 取值依据（不是猜的）
 * id 与中文名的对应来自**用户提供的 DSH 预设界面截图**（2026-09-28）：
 * 「标准模式 standard」「PTC 模式 ptc」「极简模式 minimal」「创造模式 cordis」。
 * ⚠️ 这是**DSH 当前版本**的内置清单；DSH 以后新增内置预设时本表不会自动跟上 ——
 * 那种情况下连接器若带了 name 就仍显示正确，没带 name 的会回落显示 id（**降级为改前的行为**，不会显示错名）。
 */
const BUILTIN_PRESET_NAMES: Record<string, string> = {
  'standard': '标准模式',
  'ptc': 'PTC 模式',
  'minimal': '极简模式',
  'cordis': '创造模式'
};

/** 内置预设的中文名；不是内置（或表里没有）时返回空串。 */
export function builtinPresetName(value: string): string {
  const hit = BUILTIN_PRESET_NAMES[value];
  return hit === undefined ? '' : hit;
}

/**
 * 预设的**显示名**（R94 新增，所有 UI 都用它，不要直接读 `option.label`）。
 *
 * 判据：label 与 value **不同** ⇒ 用 label（连接器给了名字，用户自建预设的中文名走这条）；
 * label 与 value **相同** ⇒ 用内置中文名，表里没有则回落 value。
 *
 * ⚠️ 判据是「label 与 value 是否相同」而不是「label 是不是英文」——
 *  后者会把用户自建的英文名预设也一起改掉（**那是用户的取名，不能动**）。
 */
export function agentPresetLabel(option: AgentPresetOption): string {
  if (option.label !== option.value) {
    return option.label;
  }
  const builtin = builtinPresetName(option.value);
  return builtin.length > 0 ? builtin : option.value;
}

/**
 * 按 id 取显示名（给「横条右侧显示当前选择」这类**只有 id** 的场景用）。
 *
 * 在选项列表里找得到 ⇒ 走 `agentPresetLabel()` 的同一套口径；
 * 找不到（目录还没读到 / 选项已消失）⇒ 查内置表，再不行回落 id 本身。
 * ⚠️ 空 id 返回空串（调用点据此不占位）。
 */
export function agentPresetDisplayName(options: AgentPresetOption[], value: string): string {
  if (value.length === 0) {
    return '';
  }
  const option = presetOptionFor(options, value);
  if (option !== undefined) {
    return agentPresetLabel(option);
  }
  const builtin = builtinPresetName(value);
  return builtin.length > 0 ? builtin : value;
}

/** 按 value 找选项。 */
export function presetOptionFor(options: AgentPresetOption[], value: string): AgentPresetOption | undefined {
  for (let i = 0; i < options.length; i++) {
    if (options[i].value === value) {
      return options[i];
    }
  }
  return undefined;
}

/**
 * 行上显示的值：找不到就回落「（未选择）」，不裸露内部 id。
 *
 * ⚠️ R94：内部改走 `agentPresetLabel()` —— 内置预设（连接器只给 id 的那种，如 `standard`）
 *  在这里统一显示中文名「标准模式」。本函数是**新建会话页**与**设置页卡右侧摘要**的共同入口，
 *  收口在这里 ⇒ 两处一起统一，不用各改一遍。
 */
export function agentPresetRowValue(options: AgentPresetOption[], value: string): string {
  const option = presetOptionFor(options, value);
  if (option !== undefined) {
    return agentPresetLabel(option);
  }
  // 目录里没有这个 id（还没读到 / 选项已消失）：仍尽量给中文名，再不行才裸露 id。
  const builtin = builtinPresetName(value);
  if (builtin.length > 0) {
    return builtin;
  }
  return value.length > 0 ? value : '（未选择）';
}

/** 选项行的副标题（可用取 description、不可用取 disabledReason，与模型/权限两行同款）。 */
export function agentPresetDetail(option: AgentPresetOption): string {
  if (option.disabled) {
    return option.disabledReason !== undefined ? option.disabledReason : '不可用';
  }
  return option.description !== undefined ? option.description : '';
}

/**
 * 选中项是否还能用（目录刷新后原选项可能变 disabled）。
 * 返回 false 时调用点要**回落默认项**，别把不可用的值发出去。
 */
export function presetStillSelectable(options: AgentPresetOption[], value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  const option = presetOptionFor(options, value);
  return option !== undefined && !option.disabled;
}

/**
 * 创建会话时要带的 `runtimeOptions`。
 *
 * ⚠️ 空串必须返回**空对象**而不是 `{agentPreset: ''}` ——
 * 连接器只认 `agentPreset` 这一个键，但空串会被 bridge 的 `validatePreset()` 判成
 * `INVALID_PARAMS`（`typeof id !== 'string' || !id`）⇒ 会话直接建不出来。
 * 不带这个键时连接器回落到它自己的 `defaultAgentPreset`，正是我们想要的语义。
 */
export function runtimeOptionsForPreset(preset: string): Record<string, string> {
  const result: Record<string, string> = {};
  if (preset.length > 0) {
    result['agentPreset'] = preset;
  }
  return result;
}
