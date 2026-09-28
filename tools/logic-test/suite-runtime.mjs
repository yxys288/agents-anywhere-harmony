#!/usr/bin/env node
/**
 * aa-hm 运行时选型（模型 / 推理强度 / 权限模式）纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 覆盖 `entry/src/main/ets/model/RuntimeSelection.ets`：
 *  ① 标签切分与 effort 显示标签回退到「默认」；
 *  ② 模型分组（groupByModelLabel 保序）与组的代表项 / 选中判定；
 *  ③ `validatedSelection`：显式 hint 失效不回退、无 hint 时取默认或首个可用；
 *  ④ 「已选值不在目录里」与目录刷新键；
 *  ⑤ 选项可用性 / 禁用原因 / 禁用档位说明；
 *  ⑥ 三态（加载中 / 失败 / 空 / 就绪）；
 *  ⑦ 目录 → 选项（reasoning 展开、distinctBy、空 selectionId 过滤）；
 *  ⑧ ForEach 的刷新 key 含会变的字段。
 *
 * 转译方式照抄 tools/logic-test/suite-design.mjs。
 *
 * 用法：
 *   node tools\logic-test\suite-runtime.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-runtime');

/** RuntimeSelection.ets 只 import 同目录的纯类型 ./Types，两个都要转译（后者供 require 解析兜底）。 */
const LOGIC_FILES = ['model/Types.ets', 'model/RuntimeSelection.ets'];

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
        removeComments: false
      },
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
  if (condition) {
    passed += 1;
  } else {
    failures.push(detail === undefined ? name : name + ' — ' + detail);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

function eqJson(name, actual, expected) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  check(name, a === b, 'expected ' + b + ', got ' + a);
}

function group(title) {
  console.log('');
  console.log('== ' + title);
}

build();

const require = createRequire(import.meta.url);
const R = require(path.join(OUT_DIR, 'model/RuntimeSelection.js'));

// ---------------------------------------------------------------------------
// 测试数据构造
// ---------------------------------------------------------------------------

/** 造一个模型选项（label 形如「模型名 · 档位名」）。 */
function opt(selectionId, label, extra) {
  return Object.assign({ selectionId, label, isDefault: false, enabled: true }, extra === undefined ? {} : extra);
}

/** 造一个推理档（wire 形状）。 */
function reasoning(selectionId, displayName, extra) {
  return Object.assign({
    id: selectionId, selectionId, displayName, default: false, enabled: true
  }, extra === undefined ? {} : extra);
}

/** 造一个模型（wire 形状）。 */
function model(id, displayName, extra) {
  return Object.assign({
    id, displayName, default: false, reasoningItems: [], enabled: true
  }, extra === undefined ? {} : extra);
}

/** 造一个目录。 */
function catalog(models) {
  return { runtime: 'claude', revision: 7, models };
}

function permissionCatalog(permissions) {
  return { runtime: 'claude', revision: 3, permissions };
}

function permission(id, displayName, extra) {
  return Object.assign({
    id, selectionId: id, displayName, default: false, enabled: true
  }, extra === undefined ? {} : extra);
}

// ---------------------------------------------------------------------------
// 1. 文案常量：逐字对齐上游 values-zh-rCN/strings.xml
// ---------------------------------------------------------------------------

group('文案常量（逐字对齐上游 values-zh-rCN/strings.xml，括号里是 key）');
eq('选择模型（session_runtime_select_model）', R.RuntimeText.SELECT_MODEL, '选择模型');
eq('权限模式（session_runtime_permission_mode）', R.RuntimeText.PERMISSION_MODE, '权限模式');
eq('默认（session_runtime_effort_default）', R.RuntimeText.EFFORT_DEFAULT, '默认');
eq('暂无可用设置（session_runtime_no_settings）', R.RuntimeText.NO_SETTINGS, '暂无可用设置');
eq('重试（common_retry）', R.RuntimeText.RETRY, '重试');
eq('无法更新运行时选择。（session_selection_update_failed）', R.RuntimeText.UPDATE_FAILED, '无法更新运行时选择。');
eq('effort 段标题（session_runtime_effort_for，%1$s 占位符展开）',
  R.RuntimeText.effortFor('Opus'), 'Opus 的推理强度');
eq('selection 键名：model', R.RUNTIME_MODEL_KEY, 'model');
eq('selection 键名：permission', R.RUNTIME_PERMISSION_KEY, 'permission');
eq('能力位：catalog.model', R.RUNTIME_MODEL_CAPABILITY, 'catalog.model');
eq('能力位：catalog.permission', R.RUNTIME_PERMISSION_CAPABILITY, 'catalog.permission');
eq('分隔符是前后带空格的「 · 」', R.RUNTIME_LABEL_SEPARATOR, ' · ');
// 上游这几个 key 在 Kotlin 侧**零引用**（grep 实证）：搬过来就等于自创一处安卓端没有的提示。
check('未搬入上游没用到的 key',
  R.RuntimeText.MODEL_LOADING === undefined && R.RuntimeText.PERMISSION_LOADING === undefined
    && R.RuntimeText.MODEL_UNAVAILABLE === undefined && R.RuntimeText.PERMISSION_UNAVAILABLE === undefined
    && R.RuntimeText.CATALOG_EMPTY === undefined && R.RuntimeText.SETTINGS_TITLE === undefined
    && R.RuntimeText.MODE_EFFORT === undefined);
eq('三态标识：loading', R.RUNTIME_SECTION_LOADING, 'loading');
eq('三态标识：error', R.RUNTIME_SECTION_ERROR, 'error');
eq('三态标识：empty', R.RUNTIME_SECTION_EMPTY, 'empty');
eq('三态标识：ready', R.RUNTIME_SECTION_READY, 'ready');

// ---------------------------------------------------------------------------
// 2. 标签切分与 effort 显示标签
// ---------------------------------------------------------------------------

group('标签切分 / effort 显示标签回退');
eq('substringBefore 命中', R.substringBefore('A · B', ' · '), 'A');
eq('substringBefore 未命中返回整串', R.substringBefore('A', ' · '), 'A');
eq('substringAfter 命中', R.substringAfter('A · B', ' · '), 'B');
eq('substringAfter 未命中返回空串', R.substringAfter('A', ' · '), '');
eq('modelLabel：切出模型名', R.splitModelLabel('Opus · high'), 'Opus');
eq('modelLabel：没有档位时是整串', R.splitModelLabel('Opus'), 'Opus');
eq('modelLabel：档位名为空时回退整串（「Opus · 」→ 空头，回退整串）',
  R.splitModelLabel(' · high'), ' · high');
eq('modelLabel：空串仍是空串', R.splitModelLabel(''), '');
eq('effortLabel：有档位', R.effortLabelOf('Opus · high'), 'high');
eq('effortLabel：没有档位是空串', R.effortLabelOf('Opus'), '');
eq('effortLabel：分隔符在中间但尾部为空 → 空串', R.effortLabelOf('Opus · '), '');
eq('effortDisplayLabel：有档位照抄', R.effortDisplayLabel(opt('a', 'Opus · high'), '默认'), 'high');
eq('effortDisplayLabel：无档位回退「默认」', R.effortDisplayLabel(opt('a', 'Opus'), '默认'), '默认');
eq('effortDisplayLabel：档位为空串也回退', R.effortDisplayLabel(opt('a', 'Opus · '), '默认'), '默认');
eq('effortDisplayLabel：自定义回退文案生效', R.effortDisplayLabel(opt('a', 'Opus'), 'DEFAULT'), 'DEFAULT');

// ---------------------------------------------------------------------------
// 3. 分组
// ---------------------------------------------------------------------------

group('模型分组 groupByModelLabel（保序）/ 选中组');
eq('空目录 → 空分组', R.groupByModelLabel([]).length, 0);
const groups = R.groupByModelLabel([
  opt('opus-high', 'Opus · high'),
  opt('opus-low', 'Opus · low'),
  opt('haiku', 'Haiku'),
  opt('opus-min', 'Opus · min')
]);
eq('分组数 = 2（Opus / Haiku）', groups.length, 2);
eq('首组是 Opus（首次出现顺序）', groups[0].label, 'Opus');
eq('次组是 Haiku', groups[1].label, 'Haiku');
eq('Opus 组含 3 个档位', groups[0].options.length, 3);
eq('Haiku 组含 1 个档位', groups[1].options.length, 1);
eq('组内顺序 = 输入顺序', groups[0].options.map((o) => o.selectionId).join(','), 'opus-high,opus-low,opus-min');
eq('单选项也能成组', R.groupByModelLabel([opt('a', 'X')]).length, 1);
eq('选中组：命中第二组', R.selectedModelGroup(groups, 'haiku').label, 'Haiku');
eq('选中组：命中首组', R.selectedModelGroup(groups, 'opus-low').label, 'Opus');
eq('选中组：id 不在任何组里 → 回退首组', R.selectedModelGroup(groups, 'nope').label, 'Opus');
eq('选中组：id 为空串 → 回退首组', R.selectedModelGroup(groups, '').label, 'Opus');
eq('选中组：空分组 → undefined', R.selectedModelGroup([], 'a'), undefined);
check('groupContains：命中', R.groupContains(groups[0], 'opus-min') === true);
check('groupContains：空 id 恒为 false', R.groupContains(groups[0], '') === false);
check('isGroupSelected：组内任一项选中即整组选中', R.isGroupSelected(groups[0], 'opus-min') === true);
check('isGroupSelected：组外 id 不算', R.isGroupSelected(groups[1], 'opus-min') === false);

group('组的代表项 displayOptionForGroup / groupSelectionId');
const repGroup = {
  label: 'Opus',
  options: [
    opt('a', 'Opus · a', { enabled: false }),
    opt('b', 'Opus · b', { isDefault: true }),
    opt('c', 'Opus · c', { isDefault: true })
  ]
};
eq('有当前选中项时用当前项', R.displayOptionForGroup(repGroup, 'c').selectionId, 'c');
eq('无选中项时用首个「可用且默认」', R.displayOptionForGroup(repGroup, '').selectionId, 'b');
const repNoDefault = { label: 'X', options: [opt('a', 'X · a', { enabled: false }), opt('b', 'X · b')] };
eq('没有默认可用的 → 首个可用', R.displayOptionForGroup(repNoDefault, '').selectionId, 'b');
const repAllDisabled = { label: 'Y', options: [opt('a', 'Y · a', { enabled: false }), opt('b', 'Y · b', { enabled: false })] };
eq('全禁用 → 退回首个', R.displayOptionForGroup(repAllDisabled, '').selectionId, 'a');
eq('禁用项即使是当前选中项也照用（上游 current 优先）',
  R.displayOptionForGroup(repGroup, 'a').selectionId, 'a');
eq('空组 → undefined', R.displayOptionForGroup({ label: 'Z', options: [] }, 'a'), undefined);
eq('groupSelectionId：有选中项时是选中项', R.groupSelectionId(repGroup, 'c'), 'c');
eq('groupSelectionId：空组是空串', R.groupSelectionId({ label: 'Z', options: [] }, 'a'), '');

group('段标题与当前值');
eq('effort 段标题用组名', R.effortSectionTitle(groups[0], 'claude'), 'Opus 的推理强度');
eq('effort 段标题：拿不到组时回退运行时名', R.effortSectionTitle(undefined, 'claude'), 'claude 的推理强度');
eq('effort 段标题：组名为空也回退', R.effortSectionTitle({ label: '', options: [] }, 'claude'), 'claude 的推理强度');
eq('selectedEffortLabel：命中档位', R.selectedEffortLabel(groups[0], 'opus-low', '默认'), 'low');
eq('selectedEffortLabel：选中项无档位 → 「默认」', R.selectedEffortLabel(groups[1], 'haiku', '默认'), '默认');
eq('selectedEffortLabel：拿不到组 → 「默认」', R.selectedEffortLabel(undefined, 'haiku', '默认'), '默认');
eq('selectedEffortLabel：组在但 id 不在组内 → 代表项的档位',
  R.selectedEffortLabel(groups[0], '', '默认'), 'high');
eq('selectedPermissionLabel：命中',
  R.selectedPermissionLabel([opt('read-only', 'read-only'), opt('danger', 'danger-full-access')], 'danger'),
  'danger-full-access');
eq('selectedPermissionLabel：未命中是空串', R.selectedPermissionLabel([opt('a', 'A')], 'zzz'), '');

// ---------------------------------------------------------------------------
// 4. 默认选中项
// ---------------------------------------------------------------------------

group('validatedSelection：显式 hint / 默认项 / 首个可用');
const selOptions = [
  opt('a', 'A', { enabled: false }),
  opt('b', 'B', { isDefault: true }),
  opt('c', 'C')
];
eq('hint 命中可用项 → 用它', R.validatedSelection(selOptions, 'c'), 'c');
eq('hint 命中但该项被禁用 → 不回退，给空串', R.validatedSelection(selOptions, 'a'), '');
eq('hint 不在目录里 → 空串（不回退默认）', R.validatedSelection(selOptions, 'zzz'), '');
eq('无 hint → 首个「可用且默认」', R.validatedSelection(selOptions, ''), 'b');
eq('无 hint 且无默认 → 首个可用', R.validatedSelection([opt('x', 'X'), opt('y', 'Y')], ''), 'x');
eq('全禁用 → 空串', R.validatedSelection([opt('x', 'X', { enabled: false })], ''), '');
eq('空目录 → 空串', R.validatedSelection([], ''), '');
eq('空目录 + hint → 空串', R.validatedSelection([], 'a'), '');

group('selectionOf：从服务端 state.selections 取键');
eq('命中', R.selectionOf({ model: 'opus-high' }, 'model'), 'opus-high');
eq('缺键 → 空串', R.selectionOf({ permission: 'p' }, 'model'), '');
eq('selections 本身缺失 → 空串', R.selectionOf(undefined, 'model'), '');
eq('键存在但值为 undefined → 空串', R.selectionOf({ model: undefined }, 'model'), '');

// ---------------------------------------------------------------------------
// 5. 已选值不在目录里 / 刷新键
// ---------------------------------------------------------------------------

group('selectionMissing：已选值不在目录里时要求重刷');
check('目录里有该可用项 → 不需要刷', R.selectionMissing([opt('a', 'A')], 'a') === false);
check('目录里没有 → 需要刷', R.selectionMissing([opt('a', 'A')], 'b') === true);
check('目录里只有它的禁用版本 → 需要刷',
  R.selectionMissing([opt('a', 'A', { enabled: false })], 'a') === true);
check('目录为空 → 不算「不在目录里」（那是还没加载）', R.selectionMissing([], 'a') === false);
check('未选中任何项 → 不需要刷', R.selectionMissing([opt('a', 'A')], '') === false);

group('catalogRefreshKey：刷新去重的幂等键');
eq('目录未定义 + 能力可用 → catalog:<能力版本>',
  R.catalogRefreshKey(false, true, '', [], 5, 0), 'catalog:5');
eq('目录未定义 + 能力不可用 → 空串（不刷）',
  R.catalogRefreshKey(false, false, '', [], 5, 0), '');
eq('目录有但已选值失效 → selection:<值>:<目录版本>',
  R.catalogRefreshKey(true, true, 'gone', [opt('a', 'A')], 5, 7), 'selection:gone:7');
eq('目录有且已选值在位 → 空串',
  R.catalogRefreshKey(true, true, 'a', [opt('a', 'A')], 5, 7), '');
eq('目录有且未选中任何项 → 空串',
  R.catalogRefreshKey(true, true, '', [opt('a', 'A')], 5, 7), '');

// ---------------------------------------------------------------------------
// 6. 可用性 / 禁用原因 / 三态
// ---------------------------------------------------------------------------

group('optionSelectable / 禁用原因');
check('可用项在闲时可选', R.optionSelectable(opt('a', 'A'), false, false) === true);
check('加载中不可选', R.optionSelectable(opt('a', 'A'), true, false) === false);
check('提交中不可选', R.optionSelectable(opt('a', 'A'), false, true) === false);
check('禁用项恒不可选', R.optionSelectable(opt('a', 'A', { enabled: false }), false, false) === false);
eq('权限副文本：禁用原因优先',
  R.permissionSupportingText(opt('a', 'A', { disabledReason: '需要管理员', description: '说明' })), '需要管理员');
eq('权限副文本：无禁用原因时用说明',
  R.permissionSupportingText(opt('a', 'A', { description: '说明' })), '说明');
eq('权限副文本：都没有 → 空串', R.permissionSupportingText(opt('a', 'A')), '');
eq('禁用档位说明：格式「<档位>: <原因>」',
  R.disabledEffortNotes([
    opt('a', 'Opus · high'),
    opt('b', 'Opus · low', { enabled: false, disabledReason: '不支持' })
  ], '默认').join(' | '), 'low: 不支持');
eq('禁用档位说明：禁用但无原因则不出现在列表里',
  R.disabledEffortNotes([opt('b', 'Opus · low', { enabled: false })], '默认').length, 0);
eq('禁用档位说明：没有禁用项 → 空列表',
  R.disabledEffortNotes([opt('a', 'Opus · high')], '默认').length, 0);

group('三态判定 catalogSectionState（加载中优先于错误）');
eq('就绪：有选项', R.catalogSectionState([opt('a', 'A')], false, ''), R.RUNTIME_SECTION_READY);
eq('就绪：有选项时即便在加载也显示列表', R.catalogSectionState([opt('a', 'A')], true, ''), R.RUNTIME_SECTION_READY);
eq('加载中：空目录 + loading', R.catalogSectionState([], true, ''), R.RUNTIME_SECTION_LOADING);
eq('加载中优先于错误', R.catalogSectionState([], true, 'boom'), R.RUNTIME_SECTION_LOADING);
eq('失败：空目录 + 错误 + 不在加载', R.catalogSectionState([], false, 'boom'), R.RUNTIME_SECTION_ERROR);
eq('空：空目录 + 无错误 + 不在加载', R.catalogSectionState([], false, ''), R.RUNTIME_SECTION_EMPTY);
eq('就绪：旧目录 + 刷新失败时列表仍可见', R.catalogSectionState([opt('a', 'A')], false, 'boom'), R.RUNTIME_SECTION_READY);

// ---------------------------------------------------------------------------
// 7. 推理强度段
// ---------------------------------------------------------------------------

group('effortOptionsForGroup：多于 1 个才显示');
eq('空组 → 空列表', R.effortOptionsForGroup(undefined).length, 0);
eq('单档位 → 空列表（整段不显示）', R.effortOptionsForGroup({ label: 'A', options: [opt('a', 'A')] }).length, 0);
eq('两档位 → 全给出', R.effortOptionsForGroup({ label: 'A', options: [opt('a', 'A · 1'), opt('b', 'A · 2')] }).length, 2);
eq('三档位 → 全给出', R.effortOptionsForGroup(groups[0]).length, 3);
check('hasEffortSection：单档位为 false', R.hasEffortSection({ label: 'A', options: [opt('a', 'A')] }) === false);
check('hasEffortSection：两档位为 true',
  R.hasEffortSection({ label: 'A', options: [opt('a', 'A · 1'), opt('b', 'A · 2')] }) === true);
check('effortOptionsForGroup 返回副本（改它不影响原组）', (() => {
  const g = { label: 'A', options: [opt('a', 'A · 1'), opt('b', 'A · 2')] };
  const list = R.effortOptionsForGroup(g);
  list.push(opt('c', 'A · 3'));
  return g.options.length === 2;
})());

// ---------------------------------------------------------------------------
// 8. 刷新 key（ForEach 行复用）
// ---------------------------------------------------------------------------

group('modelGroupKey / optionRowKey：会变的字段都进 key');
const keyGroup = { label: 'A', options: [opt('a', 'A · high'), opt('b', 'A · low')] };
const keyGroup2 = { label: 'A', options: [opt('a', 'A · high'), opt('b', 'A · low')] };
eq('同样的组 → 同样的 key', R.modelGroupKey(keyGroup), R.modelGroupKey(keyGroup2));
const keyGroupEnabled = { label: 'A', options: [opt('a', 'A · high'), opt('b', 'A · low', { enabled: false })] };
check('enabled 变了 → key 变', R.modelGroupKey(keyGroup) !== R.modelGroupKey(keyGroupEnabled));
const keyGroupReason = { label: 'A', options: [opt('a', 'A · high'), opt('b', 'A · low', { disabledReason: 'x' })] };
check('disabledReason 变了 → key 变', R.modelGroupKey(keyGroup) !== R.modelGroupKey(keyGroupReason));
const keyGroupEffort = { label: 'A', options: [opt('a', 'A · medium'), opt('b', 'A · low')] };
check('label（档位名）变了 → key 变', R.modelGroupKey(keyGroup) !== R.modelGroupKey(keyGroupEffort));
const keyGroupLabel = { label: 'B', options: [opt('a', 'B · high'), opt('b', 'B · low')] };
check('组名变了 → key 变', R.modelGroupKey(keyGroup) !== R.modelGroupKey(keyGroupLabel));
check('key 不依赖「当前选中项」（@State 标记不进 key）',
  R.modelGroupKey(keyGroup) === R.modelGroupKey(keyGroup));
eq('optionRowKey：同样内容 → 同样 key', R.optionRowKey(opt('a', 'A')), R.optionRowKey(opt('a', 'A')));
check('optionRowKey：enabled 变化 → key 变',
  R.optionRowKey(opt('a', 'A')) !== R.optionRowKey(opt('a', 'A', { enabled: false })));
check('optionRowKey：disabledReason 变化 → key 变',
  R.optionRowKey(opt('a', 'A')) !== R.optionRowKey(opt('a', 'A', { disabledReason: 'r' })));
check('optionRowKey：description 变化 → key 变',
  R.optionRowKey(opt('a', 'A')) !== R.optionRowKey(opt('a', 'A', { description: 'd' })));

// ---------------------------------------------------------------------------
// 9. 目录 → 选项
// ---------------------------------------------------------------------------

group('modelSelectionOptions：无推理档的模型');
eq('目录为 undefined → 空列表', R.modelSelectionOptions(undefined).length, 0);
eq('空模型列表 → 空列表', R.modelSelectionOptions(catalog([])).length, 0);
const plain = R.modelSelectionOptions(catalog([model('m1', 'Sonnet')]));
eq('无 selectionId 的模型被丢弃', plain.length, 0);
const plain2 = R.modelSelectionOptions(catalog([model('m1', 'Sonnet', { selectionId: 's1', default: true })]));
eq('有 selectionId → 1 个选项', plain2.length, 1);
eq('label 用 displayName', plain2[0].label, 'Sonnet');
eq('isDefault 照抄', plain2[0].isDefault, true);
eq('enabled 默认 true', plain2[0].enabled, true);
eq('displayName 为空时 label 回退 id',
  R.modelSelectionOptions(catalog([model('m9', '', { selectionId: 's9' })]))[0].label, 'm9');
eq('模型 enabled=false 透传',
  R.modelSelectionOptions(catalog([model('m1', 'A', { selectionId: 's1', enabled: false })]))[0].enabled, false);
eq('模型禁用原因透传',
  R.modelSelectionOptions(catalog([model('m1', 'A', { selectionId: 's1', disabledReason: '停用' })]))[0].disabledReason,
  '停用');

group('modelSelectionOptions：带推理档的模型');
const withReasoning = R.modelSelectionOptions(catalog([
  model('m1', 'Opus', {
    selectionId: 'opus', default: true,
    reasoningItems: [reasoning('opus-high', 'high'), reasoning('opus-low', 'low', { default: true })]
  })
]));
eq('两个档位 → 两个选项', withReasoning.length, 2);
eq('label = 模型名 · 档位名', withReasoning[0].label, 'Opus · high');
eq('modelLabel 能切回模型名', R.splitModelLabel(withReasoning[1].label), 'Opus');
eq('effortLabel 能切出档位名', R.effortLabelOf(withReasoning[1].label), 'low');
// 上游 default = item.default || (model.default && reasoning.first() == item)：
// 模型本身是默认模型时，它的**第一个**档位也算默认。
eq('模型默认时首档也算默认', withReasoning[0].isDefault, true);
eq('档位自带 default 生效（第二个是默认）', withReasoning[1].isDefault, true);
const modelDefaultOnly = R.modelSelectionOptions(catalog([
  model('m1', 'Opus', { default: true, reasoningItems: [reasoning('a', 'a'), reasoning('b', 'b')] })
]));
eq('模型默认 + 首档 → 首档继承为默认', modelDefaultOnly[0].isDefault, true);
eq('模型默认不会让第二档也成默认', modelDefaultOnly[1].isDefault, false);
eq('模型 enabled=false 会把档位一起禁掉',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', {
    enabled: false, reasoningItems: [reasoning('a', 'a')]
  })]))[0].enabled, false);
eq('档位 enabled=false 只禁该档',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', {
    reasoningItems: [reasoning('a', 'a'), reasoning('b', 'b', { enabled: false })]
  })]))[1].enabled, false);
eq('档位禁用原因优先于模型原因',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', { disabledReason: '模型原因',
    reasoningItems: [reasoning('a', 'a', { disabledReason: '档位原因' })] })]))[0].disabledReason, '档位原因');
eq('档位无原因时回退模型原因',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', { disabledReason: '模型原因',
    reasoningItems: [reasoning('a', 'a')] })]))[0].disabledReason, '模型原因');
eq('档位说明优先于模型说明',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', { description: '模型说明',
    reasoningItems: [reasoning('a', 'a', { description: '档位说明' })] })]))[0].description, '档位说明');
eq('selectionId 为空的档位被过滤',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', {
    reasoningItems: [reasoning('', ''), reasoning('b', 'b')]
  })])).length, 1);
// 档位全被过滤掉时，上游会回退到模型自己的 selectionId（else 分支）。
eq('档位全部无 selectionId → 回退模型自身 selectionId',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', { selectionId: 'opus',
    reasoningItems: [reasoning('', '')] })])).length, 1);
eq('回退后的 label 是模型名',
  R.modelSelectionOptions(catalog([model('m1', 'Opus', { selectionId: 'opus',
    reasoningItems: [reasoning('', '')] })]))[0].label, 'Opus');
eq('distinctBy：selectionId 重复只留第一个',
  R.modelSelectionOptions(catalog([
    model('m1', 'A', { selectionId: 'dup' }),
    model('m2', 'B', { selectionId: 'dup' })
  ])).length, 1);
eq('distinctBy 留的是第一个（label 是 A）',
  R.modelSelectionOptions(catalog([
    model('m1', 'A', { selectionId: 'dup' }),
    model('m2', 'B', { selectionId: 'dup' })
  ]))[0].label, 'A');

group('permissionSelectionOptions');
eq('目录为 undefined → 空列表', R.permissionSelectionOptions(undefined).length, 0);
eq('空权限列表 → 空列表', R.permissionSelectionOptions(permissionCatalog([])).length, 0);
const perms = R.permissionSelectionOptions(permissionCatalog([
  permission('read-only', 'read-only', { description: '只读' }),
  permission('danger', 'danger-full-access', { default: true }),
  permission('blank', '')
]));
eq('空 selectionId 的权限被丢弃', perms.length, 3);
eq('displayName 为空时 label 回退 id', perms[2].label, 'blank');
eq('isDefault 照抄', perms[1].isDefault, true);
eq('说明透传', perms[0].description, '只读');
const permsDup = R.permissionSelectionOptions(permissionCatalog([
  permission('a', 'A'), permission('a', 'B')
]));
eq('permission 也做 distinctBy', permsDup.length, 1);
eq('permission distinctBy 留第一个', permsDup[0].label, 'A');
eq('permission 禁用原因透传',
  R.permissionSelectionOptions(permissionCatalog([
    permission('a', 'A', { enabled: false, disabledReason: '不支持' })
  ]))[0].disabledReason, '不支持');

group('模型行副文本 modelGroupSupportingText（上游 ModelOptions 只放 disabledReason）');
eq('没有禁用原因 → 空串（不显示副文本行）', R.modelGroupSupportingText(groups[1], 'haiku'), '');
eq('代表项被禁用 → 原样给出原因',
  R.modelGroupSupportingText({ label: 'A', options: [opt('a', 'A · high', { enabled: false, disabledReason: '停用' })] },
    'a'), '停用');
eq('选中项自带禁用原因 → 也给出来（上游 current 优先）',
  R.modelGroupSupportingText({ label: 'A', options: [
    opt('a', 'A · high', { disabledReason: '停用' }), opt('b', 'A · low')
  ] }, 'a'), '停用');
// 代表项优先取「可用」的那个（禁用的 a 不会被选中），所以这里没有副文本。
eq('未选中该组时看代表项（会跳过禁用项）',
  R.modelGroupSupportingText({ label: 'A', options: [
    opt('a', 'A · high', { enabled: false, disabledReason: '停用' }), opt('b', 'A · low')
  ] }, 'zzz'), '');
eq('全组都禁用时，代表项退回第一个并带出原因',
  R.modelGroupSupportingText({ label: 'A', options: [
    opt('a', 'A · high', { enabled: false, disabledReason: '停用' }),
    opt('b', 'A · low', { enabled: false })
  ] }, 'zzz'), '停用');
eq('空组的副文本是空串', R.modelGroupSupportingText({ label: 'A', options: [] }, 'a'), '');

// ---------------------------------------------------------------------------
// 10. 端到端：一棵真实形状的目录走完整链路
// ---------------------------------------------------------------------------

group('端到端：目录 → 选项 → 分组 → 默认选中 → 三态');
const live = catalog([
  model('deepseek-v3', 'DeepSeek Flash(d1)', {
    selectionId: 'claude-model-1', default: true,
    reasoningItems: [reasoning('deepseek-v3-default', '默认', { default: true })]
  }),
  model('step-3.7', 'step-3.7-flash', { selectionId: 'step-model-2' }),
  model('step-5', 'step-5-preview', { selectionId: 'step-model-3' })
]);
const liveOptions = R.modelSelectionOptions(live);
eq('三个模型 → 三个选项', liveOptions.length, 3);
const liveGroups = R.groupByModelLabel(liveOptions);
eq('三个分组', liveGroups.length, 3);
eq('首组名不变（真机截图上的名字）', liveGroups[0].label, 'DeepSeek Flash(d1)');
eq('首组只有一个档位 → 不显示 effort 段', R.hasEffortSection(liveGroups[0]), false);
eq('默认选中 = 首个可用且默认', R.validatedSelection(liveOptions, ''), 'deepseek-v3-default');
eq('服务端给了选中值 → 用它', R.validatedSelection(liveOptions, 'step-model-3'), 'step-model-3');
eq('服务端给的选中值失效 → 空串（等目录刷新）', R.validatedSelection(liveOptions, 'gone'), '');
check('失效值会被判为需要刷新目录', R.selectionMissing(liveOptions, 'gone') === true);
eq('三态：就绪', R.catalogSectionState(liveOptions, false, ''), R.RUNTIME_SECTION_READY);
eq('三态：空目录 + 加载中', R.catalogSectionState([], true, ''), R.RUNTIME_SECTION_LOADING);
eq('三态：空目录 + 失败', R.catalogSectionState([], false, 'HTTP 500'), R.RUNTIME_SECTION_ERROR);
eq('三态：空目录 + 无错（服务端没给）', R.catalogSectionState([], false, ''), R.RUNTIME_SECTION_EMPTY);
const multiEffortGroups = R.groupByModelLabel(R.modelSelectionOptions(catalog([
  model('m', 'Opus', { selectionId: 'o', default: true,
    reasoningItems: [reasoning('o-high', 'high'), reasoning('o-low', 'low')] })
])));
eq('同模型两个档位 → 一个分组', multiEffortGroups.length, 1);
eq('该分组触发 effort 段', R.hasEffortSection(multiEffortGroups[0]), true);
eq('effort 段标题带上模型名', R.effortSectionTitle(multiEffortGroups[0], 'claude'), 'Opus 的推理强度');
eq('effort 段选项数', R.effortOptionsForGroup(multiEffortGroups[0]).length, 2);

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-runtime: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-runtime: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ✗ ' + item);
}
process.exit(1);
