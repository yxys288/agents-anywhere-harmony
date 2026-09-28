#!/usr/bin/env node
/**
 * aa-hm「DSH Agent 预设」的纯逻辑断言（R51 新增）。
 *
 * 被测代码：`model/AgentPreset.ets`（零 import，可单独转译）。
 * 触发这轮改动的是用户反馈：「新建对话无法选择 DSH agent 预设，要加上」。
 *
 * 协议形状**不是猜的**：
 *  · 可选项：runtime 描述的 `uiSchema.defaultAgentPreset`（`connector/connector/runtimes/dsh/provider.py:156`），
 *    条目形状 `{value,label,description?,disabled?,disabledReason?}`
 *    （bridge `dsh-bridge-next/lib/index.js:4614-4623` 的 `uiField.options`）；
 *  · 默认值：`schema.properties.defaultAgentPreset.default`（同处 `configField.default`）；
 *  · 提交：`runtimeOptions.agentPreset`（`connector/connector/runtimes/dsh/runtime.py:304-311`：
 *    **只认这一个键**，缺省回落连接器配置；bridge `validatePreset()` 拒空串/未知 id）。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-agent-preset.mjs
 */

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, requireTypeScript, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-agent-preset');
const LOGIC_FILES = ['model/AgentPreset.ets'];
const NL = String.fromCharCode(10);

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
      fileName: rel
    });
    const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, output.outputText, 'utf8');
  }
}

let passed = 0;
const failures = [];
function check(name, condition, detail) {
  if (condition) { passed += 1; } else { failures.push(detail === undefined ? name : detail); }
}
function eq(name, actual, expected) {
  check(name, actual === expected, name + ' — expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function group(title) { console.log(NL + '== ' + title); }

build();
const require = createRequire(import.meta.url);
const M = require(path.join(OUT_DIR, 'model/AgentPreset.js'));

/** 一个 DSH runtime 描述（字段名与 `DeviceRuntimeView` 的线格式一致：顶层 `schema` / `uiSchema`）。 */
function dshRuntime(over) {
  const base = {
    connectorId: 'conn-1', runtimeId: 'rti_dsh', runtimeType: 'dsh', displayName: 'DeepSeek Harness',
    present: true, configured: true, active: true, status: 'running',
    schema: {
      type: 'object',
      properties: {
        defaultAgentPreset: { type: 'string', title: '新会话默认模式', default: 'standard', enum: ['standard', 'review'] }
      }
    },
    uiSchema: {
      order: ['defaultAgentPreset', 'dshHome'],
      defaultAgentPreset: {
        component: 'select',
        options: [
          { value: 'standard', label: '标准' },
          { value: 'review', label: '只读审查', description: '不改文件' },
          { value: 'broken', label: '坏掉的模式', disabled: true, disabledReason: '预设加载失败' }
        ]
      }
    }
  };
  return Object.assign(base, over === undefined ? {} : over);
}

group('① 目录解析（只有 component=select 且带 options 才算）');
eq('DSH 有 3 个预设', M.agentPresetOptions(dshRuntime()).length, 3);
eq('首个预设', M.agentPresetOptions(dshRuntime())[0].value + '|' + M.agentPresetOptions(dshRuntime())[0].label, 'standard|标准');
eq('description 保留', M.agentPresetOptions(dshRuntime())[1].description, '不改文件');
eq('disabled + 原因保留', String(M.agentPresetOptions(dshRuntime())[2].disabled) + '|' + M.agentPresetOptions(dshRuntime())[2].disabledReason, 'true|预设加载失败');
eq('component 不是 select ⇒ 空（不显示整行）', M.agentPresetOptions(dshRuntime({
  uiSchema: { defaultAgentPreset: { component: 'text', options: [{ value: 'a', label: 'A' }] } }
})).length, 0);
eq('没有 uiSchema ⇒ 空', M.agentPresetOptions(dshRuntime({ uiSchema: undefined })).length, 0);
eq('没有该字段 ⇒ 空（别的 runtime 就是这个形态）', M.agentPresetOptions(dshRuntime({
  uiSchema: { order: ['dshHome'], dshHome: { component: 'path' } }
})).length, 0);
eq('options 不是数组 ⇒ 空', M.agentPresetOptions(dshRuntime({
  uiSchema: { defaultAgentPreset: { component: 'select', options: 'x' } }
})).length, 0);
eq('runtime 为 undefined ⇒ 空', M.agentPresetOptions(undefined).length, 0);
eq('坏条目被跳过、好条目保留', M.agentPresetOptions(dshRuntime({
  uiSchema: {
    defaultAgentPreset: {
      component: 'select',
      options: [{ value: 'ok', label: '好' }, { value: '', label: '空值' }, { value: 'nolabel' }, 'x', { value: 'ok', label: '重复' }]
    }
  }
})).length, 1);
eq('重复 value 去重后保留首次', M.agentPresetOptions(dshRuntime({
  uiSchema: { defaultAgentPreset: { component: 'select', options: [{ value: 'a', label: '首' }, { value: 'a', label: '次' }] } }
}))[0].label, '首');

group('② 默认值（schema.default 优先，但必须是可用项；否则第一个可用项）');
eq('schema.default 命中 ⇒ 用它', M.defaultAgentPreset(dshRuntime()), 'standard');
eq('schema.default 指向 disabled ⇒ 跳过它取第一个可用', M.defaultAgentPreset(dshRuntime({
  schema: { properties: { defaultAgentPreset: { default: 'broken' } } }
})), 'standard');
eq('没有 schema.default ⇒ 第一个可用', M.defaultAgentPreset(dshRuntime({ schema: undefined })), 'standard');
eq('第一个可用之前有 disabled ⇒ 仍然取可用的那个', M.defaultAgentPreset(dshRuntime({
  uiSchema: {
    defaultAgentPreset: {
      component: 'select',
      options: [{ value: 'x', label: 'X', disabled: true }, { value: 'y', label: 'Y' }]
    }
  },
  schema: undefined
})), 'y');
eq('全部 disabled ⇒ 空串（不硬塞一个不可用的）', M.defaultAgentPreset(dshRuntime({
  uiSchema: { defaultAgentPreset: { component: 'select', options: [{ value: 'x', label: 'X', disabled: true }] } },
  schema: undefined
})), '');
eq('没有预设 ⇒ 空串', M.defaultAgentPreset(dshRuntime({ uiSchema: undefined })), '');

group('③ 行上显示的值与副标题');
const options = M.agentPresetOptions(dshRuntime());
eq('命中选项 ⇒ 显示 label', M.agentPresetRowValue(options, 'review'), '只读审查');
eq('未选 ⇒ 占位', M.agentPresetRowValue(options, ''), '（未选择）');
eq('目录里没有该 id ⇒ 原样显示（不崩）', M.agentPresetRowValue(options, 'gone'), 'gone');
eq('可用项副标题取 description', M.agentPresetDetail(options[1]), '不改文件');
eq('不可用项副标题取 disabledReason', M.agentPresetDetail(options[2]), '预设加载失败');
eq('不可用且无原因 ⇒ 「不可用」', M.agentPresetDetail({ value: 'a', label: 'A', disabled: true }), '不可用');
eq('可用且无描述 ⇒ 空串', M.agentPresetDetail({ value: 'a', label: 'A', disabled: false }), '');

group('④ 可用性判定（目录刷新后原选中项可能失效）');
eq('可用项 ⇒ true', M.presetStillSelectable(options, 'standard'), true);
eq('disabled 项 ⇒ false', M.presetStillSelectable(options, 'broken'), false);
eq('不在目录里 ⇒ false', M.presetStillSelectable(options, 'gone'), false);
eq('空串 ⇒ false', M.presetStillSelectable(options, ''), false);


// ---------------------------------------------------------------------------
// R94：DSH **内置预设**的中文名（用户：「将系统内置预设都改成中文名」）
// ---------------------------------------------------------------------------
// 背景：预设显示名来自连接器上报（bridge `label: preset.name || preset.id`）。
// DSH 的**内置**预设没给 name ⇒ 回落成 `standard` 这种 id ⇒ App 上显示英文（用户截图的现象）。
// 处置：App 侧加一张 id→中文名兜底表，**连接器给了一律优先**。
group('⑦ R94 内置预设中文名（连接器没给 name 时兜底）');
eq('standard ⇒ 标准模式', M.builtinPresetName('standard'), '标准模式');
eq('ptc ⇒ PTC 模式', M.builtinPresetName('ptc'), 'PTC 模式');
eq('minimal ⇒ 极简模式', M.builtinPresetName('minimal'), '极简模式');
eq('cordis ⇒ 创造模式', M.builtinPresetName('cordis'), '创造模式');
eq('非内置 ⇒ 空串（不硬编「未知预设」）', M.builtinPresetName('my-own-preset'), '');
eq('空串 ⇒ 空串', M.builtinPresetName(''), '');

// ⚠️ 判据是「label 与 value **是否相同**」，不是「label 是不是英文」——
//    后者会把用户自建的英文名预设也一起改掉（那是用户的取名）。下面四条把这条口径钉死：
eq('连接器没给名（label === value）⇒ 用中文名',
  M.agentPresetLabel({ value: 'standard', label: 'standard', disabled: false }), '标准模式');
eq('连接器给了中文名 ⇒ **原样用**（内置表不覆盖）',
  M.agentPresetLabel({ value: 'standard', label: '标准模式_bash', disabled: false }), '标准模式_bash');
eq('用户自建的英文名 ⇒ **原样用**（不许被当成内置改掉）',
  M.agentPresetLabel({ value: 'mine', label: 'My Own', disabled: false }), 'My Own');
eq('非内置且没给名 ⇒ 回落 id（不猜）',
  M.agentPresetLabel({ value: 'unknown-x', label: 'unknown-x', disabled: false }), 'unknown-x');

eq('按 id 取显示名：目录里有 ⇒ 走同一口径',
  M.agentPresetDisplayName([{ value: 'ptc', label: 'ptc', disabled: false }], 'ptc'), 'PTC 模式');
eq('按 id 取显示名：目录里没有 ⇒ 内置表兜底',
  M.agentPresetDisplayName([], 'minimal'), '极简模式');
eq('按 id 取显示名：全都没有 ⇒ 回落 id',
  M.agentPresetDisplayName([], 'zzz'), 'zzz');
eq('按 id 取显示名：空 id ⇒ 空串（调用点据此不占位）',
  M.agentPresetDisplayName([], ''), '');

// 行显示名（`agentPresetRowValue`）是**设置页卡右侧摘要**与新建会话行的共同入口 ⇒ 它必须也走中文名。
eq('行显示名走中文名口径（内置 id ⇒ 中文）',
  M.agentPresetRowValue([{ value: 'cordis', label: 'cordis', disabled: false }], 'cordis'), '创造模式');
eq('行显示名：目录里没有但 id 是内置 ⇒ 仍给中文名', M.agentPresetRowValue([], 'standard'), '标准模式');
eq('行显示名：目录里没有且非内置 ⇒ 裸露 id（与改前一致）', M.agentPresetRowValue([], 'gone'), 'gone');

group('⑤ 提交载荷（连接器只认 agentPreset 这一个键）');
eq('选了 ⇒ 一个键', JSON.stringify(M.runtimeOptionsForPreset('standard')), '{"agentPreset":"standard"}');
eq('没选 ⇒ **空对象**（绝不发空串：bridge validatePreset 会拒）', JSON.stringify(M.runtimeOptionsForPreset('')), '{}');

group('⑥ 变异测试（把关键分支改坏必须变红）');
function mutate(replacements, name, shouldFail) {
  const source = fs.readFileSync(path.join(SRC_ETS, 'model/AgentPreset.ets'), 'utf8');
  let out = source;
  for (const [from, to] of replacements) { out = out.replace(from, to); }
  check(name + '：变异确实改到了源码', out !== source);
  const dir = path.join(OUT_DIR, 'mutant');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const ts = requireTypeScript();
  const js = ts.transpileModule(out, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: 'm.ets'
  }).outputText;
  const file = path.join(dir, 'm.js');
  fs.writeFileSync(file, js, 'utf8');
  delete require.cache[require.resolve(file)];
  const Mut = require(file);
  let failed = false;
  try { failed = shouldFail(Mut); } catch (error) { failed = true; }
  check(name + '：变异后行为确实变坏', failed === true);
}
mutate([[`if (nonEmptyText(field['component']) !== AGENT_PRESET_COMPONENT) {
    return undefined;
  }`, '']], '去掉 component=select 守卫', (Mut) => {
  const got = Mut.agentPresetOptions(dshRuntime({
    uiSchema: { defaultAgentPreset: { component: 'text', options: [{ value: 'a', label: 'A' }] } }
  }));
  return got.length !== 0;
});
mutate([[`if (options[i].value === declared && !options[i].disabled) {`, 'if (options[i].value === declared) {']],
  '默认值不再检查 disabled', (Mut) => {
  const got = Mut.defaultAgentPreset(dshRuntime({ schema: { properties: { defaultAgentPreset: { default: 'broken' } } } }));
  return got !== 'standard';
});
mutate([[`if (preset.length > 0) {
    result['agentPreset'] = preset;
  }`, `result['agentPreset'] = preset;`]], '空串也发出去', (Mut) => {
  return Object.keys(Mut.runtimeOptionsForPreset('')).length !== 0;
});
mutate([[`if (seen.indexOf(value) >= 0) {
      continue;
    }`, '']], '不去重 value', (Mut) => {
  const got = Mut.agentPresetOptions(dshRuntime({
    uiSchema: { defaultAgentPreset: { component: 'select', options: [{ value: 'a', label: '首' }, { value: 'a', label: '次' }] } }
  }));
  return got.length !== 1;
});

if (failures.length > 0) {
  console.error('suite-agent-preset: ' + failures.length + ' 条断言失败');
  for (const f of failures) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-agent-preset: ' + passed + ' 条断言全绿（含 4 组变异测试）。');
