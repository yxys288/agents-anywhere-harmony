#!/usr/bin/env node
/**
 * 状态文案表 + 「不裸露英文枚举」的源码守卫（R20 新增）。
 *
 * 被测代码：`model/StatusLabels.ets`（零依赖的纯字符串映射）。
 * 触发这轮改动的是并排图：会话详情页把服务端枚举**原样**渲染了出来 ——
 * `connected`（WS 连接态）、`waiting_approval`（状态 chip）、`running`（消息状态）。
 * 页面里本来就有中文化入口（`sessionStatusLabel`），只是这几处漏了。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-status-labels.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-status-labels');
const STATUS_LABELS = path.join(SRC_ETS, 'model', 'StatusLabels.ets');
const SESSION_DETAIL = path.join(SRC_ETS, 'ui', 'screens', 'SessionDetailScreen.ets');
const DEVICE_DETAIL = path.join(SRC_ETS, 'ui', 'screens', 'DeviceDetailScreen.ets');

/** `model/StatusLabels.ets` 零 import，可以单独转译。 */
const LOGIC_FILES = ['model/StatusLabels.ets'];

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
  if (condition) {
    passed += 1;
  } else {
    failures.push(detail === undefined ? name : name + ' — ' + detail);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

function group(title) {
  console.log(NL + '== ' + title);
}

build();

const require = createRequire(import.meta.url);
const labels = require(path.join(OUT_DIR, 'model/StatusLabels.js'));

// ---------------------------------------------------------------------------
// 1. 消息状态
// ---------------------------------------------------------------------------

group('消息状态文案（未知取值必须返回空串 ⇒ 调用方不渲染）');
eq('failed → 失败', labels.messageStatusLabel('failed'), '失败');
eq('error → 出错', labels.messageStatusLabel('error'), '出错');
eq('cancelled → 已取消', labels.messageStatusLabel('cancelled'), '已取消');
eq('interrupted → 已中断', labels.messageStatusLabel('interrupted'), '已中断');
eq('pending → 排队中', labels.messageStatusLabel('pending'), '排队中');
eq('running → 运行中', labels.messageStatusLabel('running'), '运行中');
eq('waiting → 等待中', labels.messageStatusLabel('waiting'), '等待中');
eq('waiting_approval → 待审批', labels.messageStatusLabel('waiting_approval'), '待审批');
eq('done → 空串（不显示）', labels.messageStatusLabel('done'), '');
eq('未知状态 → 空串', labels.messageStatusLabel('whatever_new'), '');
eq('空串 → 空串', labels.messageStatusLabel(''), '');
check('任何已知取值都不含下划线（下划线 = 没本地化的信号）',
  ['failed', 'error', 'cancelled', 'interrupted', 'pending', 'running', 'waiting', 'waiting_approval']
    .every((s) => labels.messageStatusLabel(s).indexOf('_') < 0));

group('失败类判定（上游 SessionMessages.kt:984）');
eq('failed 算失败', labels.messageStatusFailed('failed'), true);
eq('cancelled 算失败', labels.messageStatusFailed('cancelled'), true);
eq('interrupted 算失败', labels.messageStatusFailed('interrupted'), true);
eq('running 不算失败', labels.messageStatusFailed('running'), false);
eq('done 不算失败', labels.messageStatusFailed('done'), false);

// ---------------------------------------------------------------------------
// 2. 连接态 / 会话级 Runtime 状态
// ---------------------------------------------------------------------------

group('WS 连接态文案（本工程自加；用词对齐上游 strings.xml）');
eq('connected → 已连接（device_setup_connected）', labels.connectionStatusLabel('connected'), '已连接');
eq('connecting → 连接中', labels.connectionStatusLabel('connecting'), '连接中');
eq('recovering → 重连中（session_reconnect_summary）', labels.connectionStatusLabel('recovering'), '重连中');
eq('offline → 离线（home_offline）', labels.connectionStatusLabel('offline'), '离线');
eq('idle → 未连接', labels.connectionStatusLabel('idle'), '未连接');
eq('未知 → 未连接（兜底不裸露枚举）', labels.connectionStatusLabel('zzz'), '未连接');

group('会话级 Runtime 状态文案（未知取值返回空串）');
eq('idle → 空闲', labels.runtimeStateStatusLabel('idle'), '空闲');
eq('ready → 就绪', labels.runtimeStateStatusLabel('ready'), '就绪');
eq('running → 运行中', labels.runtimeStateStatusLabel('running'), '运行中');
eq('error → 出错', labels.runtimeStateStatusLabel('error'), '出错');
eq('未知 → 空串', labels.runtimeStateStatusLabel('weird'), '');
check('与设备级 runtimeStatusLabel 的取值域**不重叠**（available/validating 不该在这里有中文）',
  labels.runtimeStateStatusLabel('available') === ''
  && labels.runtimeStateStatusLabel('validating') === '');

// ---------------------------------------------------------------------------
// 3. 源码守卫：页面不能再裸露枚举
// ---------------------------------------------------------------------------

const sessionText = fs.readFileSync(SESSION_DETAIL, 'utf8');
const deviceText = fs.readFileSync(DEVICE_DETAIL, 'utf8');

group('会话详情页：三处裸露枚举都已改掉');
check('不再有 Text(message.status)', sessionText.indexOf('Text(message.status)') < 0);
check('不再有 Text(this.connection)（枚举直出）', sessionText.indexOf('Text(this.connection)') < 0);
check('不再有 状态：${...runtimeState.status}',
  sessionText.indexOf('this.store.runtimeState.status}') < 0);
check('改用了 StatusLabels 的四个入口',
  sessionText.indexOf('messageStatusLabel(message.status)') > 0
  && sessionText.indexOf('messageStatusFailed(message.status)') > 0
  && sessionText.indexOf('connectionStatusLabel(') > 0
  && sessionText.indexOf('runtimeStateStatusLabel(state.status)') > 0);
check('StatusLabels 从 model 引入（不是页面里各写一份表）',
  sessionText.indexOf("from '../../model/StatusLabels'") > 0);
check('页面里不再重复定义这些表',
  sessionText.indexOf('private messageStatusLabel(') < 0
  && sessionText.indexOf('private connectionLabel(') < 0
  && sessionText.indexOf('private runtimeStateLabel(') < 0);

group('设备详情页：AGENT 段与 Runtime 行按上游收口');
check('AGENT 标题不再带计数（上游 AgentsSection 不传 action 槽）',
  deviceText.indexOf("AaSectionHeader({ title: 'AGENT', trailing:") < 0
  && deviceText.indexOf("AaSectionHeader({ title: 'AGENT' })") > 0);
check('不再有「默认」chip（active 由开关开态表达，重复表达要删）',
  deviceText.indexOf("label: '默认'") < 0);
check('配置 / 开关 / 垃圾桶在**同一行**（上游 ConfiguredAgentRow 只有一行）',
  deviceText.indexOf('this.runtimeActionButton(runtime.runtimeId)') > 0
  && deviceText.indexOf('this.runtimeSwitch(runtime.runtimeId)') > 0
  && deviceText.indexOf('this.runtimeDeleteButton(runtime.runtimeId)') > 0);

group('审批动作横向排布（上游 FlowRow）');
check('noticePlainActions / noticeInputActions 分组存在',
  sessionText.indexOf('private noticePlainActions(') > 0
  && sessionText.indexOf('private noticeInputActions(') > 0);
check('不带输入的动作包在 Row(spacedBy 8dp) + 居中里',
  sessionText.indexOf('ForEach(this.noticePlainActions(notice)') > 0
  && sessionText.indexOf('justifyContent(FlexAlign.Center)') > 0);
check('带输入的动作仍走 input+提交 的纵向组合',
  sessionText.indexOf('ForEach(this.noticeInputActions(notice)') > 0);

group('CompileProbe 登记（新模块必须进类型检查图）');
const probeText = fs.readFileSync(path.join(SRC_ETS, 'dev', 'CompileProbe.ets'), 'utf8');
check('StatusLabels 已在 CompileProbe 里引用',
  probeText.indexOf("from '../model/StatusLabels'") > 0
  && probeText.indexOf('messageStatusLabel, messageStatusFailed, connectionStatusLabel, runtimeStateStatusLabel') > 0);

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-status-labels: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-status-labels: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ✗ ' + item);
}
process.exit(1);
