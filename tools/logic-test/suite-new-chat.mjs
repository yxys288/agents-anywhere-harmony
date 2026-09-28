#!/usr/bin/env node
/**
 * 「直接开新对话」草稿会话的纯逻辑断言（R53 新增）。
 *
 * 被测代码：`model/NewChatDraft.ets`（依赖 `model/NewSessionPreference.ets`，两者都是零 Kit 依赖）。
 * 触发这轮改动的是用户反馈：「新建对话逻辑改为直接在指定工作区开启对话，不需要先选模型，
 * 发首条对话等才启动」。默认值解析是一串有优先级的回落链，真机上很难把各种组合都造出来
 * （记忆失效 / 设备离线 / Agent 卡在 starting / 设备下没有工作区），所以在 Node 里穷举。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-new-chat.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-new-chat');
const LOGIC_FILES = ['model/NewSessionPreference.ets', 'model/NewChatDraft.ets'];
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
  if (condition) { passed += 1; } else { failures.push(detail === undefined ? name : name + ' — ' + detail); }
}
function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function group(title) { console.log(NL + '== ' + title); }

build();
const require = createRequire(import.meta.url);
const D = require(path.join(OUT_DIR, 'model/NewChatDraft.js'));
const P = require(path.join(OUT_DIR, 'model/NewSessionPreference.js'));

const ACC = 'http://127.0.0.1:8787|user-1';
const DEV_A = 'conn-a';
const DEV_B = 'conn-b';
const RT_X = 'rt-x';
const RT_Y = 'rt-y';

function device(id, online) { return { id: id, name: id.toUpperCase(), online: online === true }; }
function project(id, connectorId, name, workspacePath) {
  return { id: id, connectorId: connectorId, name: name, workspacePath: workspacePath, pinned: false };
}
function session(connectorId, projectId, sortKey, id) {
  return {
    id: id === undefined ? 's-' + projectId + '-' + sortKey : id,
    connectorId: connectorId, projectId: projectId, cwd: '', sortKey: sortKey
  };
}
function runtime(runtimeId, status, configured, active) {
  return {
    runtimeId: runtimeId, runtimeType: runtimeId, displayName: runtimeId,
    configured: configured !== false, active: active !== false, status: status
  };
}
function entry(deviceId, runtimeId) {
  return { account: ACC, deviceId: deviceId, runtimeId: runtimeId, selections: [] };
}

// ---------------------------------------------------------------------------
group('路由参数（指定工作区）编解码');
eq('两端都空 ⇒ 空串（不带参数）', D.encodeNewChatEntry('', ''), '');
eq('往返一致', D.parseNewChatEntry(D.encodeNewChatEntry(DEV_A, 'proj-1')).projectId, 'proj-1');
eq('往返：connectorId', D.parseNewChatEntry(D.encodeNewChatEntry(DEV_A, 'proj-1')).connectorId, DEV_A);
eq('只有 connectorId 也能解析', D.parseNewChatEntry(DEV_A + '|').connectorId, DEV_A);
eq('缺第二段 ⇒ projectId 空串', D.parseNewChatEntry(DEV_A).projectId, '');
eq('多余段被忽略', D.parseNewChatEntry(DEV_A + '|p1|junk').projectId, 'p1');
eq('空白被裁掉', D.parseNewChatEntry(' ' + DEV_A + ' | p1 ').projectId, 'p1');
eq('空串解析成空 entry', D.parseNewChatEntry('').connectorId, '');
eq('非法（只有分隔符）不抛且为空', D.parseNewChatEntry('|').connectorId, '');

// ---------------------------------------------------------------------------
group('选设备：指定 → 记忆 → 在线 → 第一个');
const devices = [device('dev-off', false), device(DEV_A, true), device(DEV_B, true)];
eq('指定设备优先（且仍存在）', D.pickDraftDevice(entry(DEV_B, RT_X), DEV_A, devices), DEV_A);
eq('指定设备已不存在 ⇒ 走记忆', D.pickDraftDevice(entry(DEV_B, RT_X), 'dev-gone', devices), DEV_B);
eq('记忆的设备已不在列表 ⇒ 取第一台在线', D.pickDraftDevice(entry('dev-gone', RT_X), '', devices), DEV_A);
eq('无记忆 ⇒ 跳过离线设备', D.pickDraftDevice(undefined, '', devices), DEV_A);
eq('全部离线 ⇒ 取第一个（有总比没有强）',
  D.pickDraftDevice(undefined, '', [device('dev-off', false), device('dev-2', false)]), 'dev-off');
eq('没有设备 ⇒ 空串', D.pickDraftDevice(undefined, '', []), '');
eq('记忆命中离线设备也用它（用户上次真在用）',
  D.pickDraftDevice(entry('dev-off', RT_X), '', devices), 'dev-off');

// ---------------------------------------------------------------------------
group('选工作区：指定 → 最近会话所在 → 第一个');
const projects = [
  project('p-blank', DEV_A, '空白工作区', '/home/u/blank'),
  project('p-work', DEV_A, 'HarmonyOS', '/home/u/HarmonyOS'),
  project('p-b', DEV_B, 'B 的工作区', '/home/b/work')
];
const sessions = [
  session(DEV_A, 'p-blank', '2026-09-20T10:00:00Z'),
  session(DEV_A, 'p-work', '2026-09-22T10:00:00Z'),
  session(DEV_B, 'p-b', '2026-09-23T10:00:00Z'),
  session(DEV_A, 'p-gone', '2026-09-25T10:00:00Z')
];
eq('指定项目优先', D.pickDraftProject(DEV_A, 'p-blank', projects, sessions), 'p-blank');
eq('取该设备最近会话所在的工作区',
  D.pickDraftProject(DEV_A, '', projects, sessions), 'p-work');
eq('最近会话指向已删项目 ⇒ 忽略它',
  D.pickDraftProject(DEV_A, '', projects, [session(DEV_A, 'p-gone', '2026-09-25T10:00:00Z')]), 'p-blank');
eq('指定项目不属于该设备 ⇒ 不当真',
  D.pickDraftProject(DEV_A, 'p-b', projects, []), 'p-blank');
eq('没有会话 ⇒ 取第一个工作区',
  D.pickDraftProject(DEV_B, '', projects, []), 'p-b');
eq('该设备没有工作区 ⇒ 空串',
  D.pickDraftProject('dev-none', '', projects, sessions), '');
eq('多设备互不串台（A 的会话不决定 B 的工作区）',
  D.pickDraftProject(DEV_B, '', projects, sessions), 'p-b');
eq('空 sortKey 不会误当最近',
  D.pickDraftProject(DEV_A, '', projects, [session(DEV_A, 'p-work', ''), session(DEV_A, 'p-blank', 'k')]), 'p-blank');
// R53：DSH 回退链的第 ②级「当前会话所属工作区」——「最后打开过的会话」由页面传进来。
eq('取到会话所属工作区', D.projectIdOfSession(sessions, sessions[1].id), 'p-work');
eq('会话 id 不存在 ⇒ 空串', D.projectIdOfSession(sessions, 'nope'), '');
eq('空 id ⇒ 空串（连查都不查）', D.projectIdOfSession(sessions, '   '), '');
eq('空列表 ⇒ 空串', D.projectIdOfSession([], 's-1'), '');
eq('优先项胜过「最近更新」：最后打开的会话在旧工作区时，新建回到那里',
  D.pickDraftProject(DEV_A, D.projectIdOfSession(sessions, 's-p-blank-2026-09-20T10:00:00Z'), projects, sessions),
  'p-blank');
eq('优先项指向别台设备的工作区 ⇒ 不当真，回落最近更新',
  D.pickDraftProject(DEV_A, 'p-b', projects, sessions), 'p-work');

eq('projectsForDevice 只留本设备', D.projectsForDevice(DEV_A, projects).length, 2);
eq('findProject 命中', D.findProject(projects, 'p-work').name, 'HarmonyOS');
eq('findProject 未命中 ⇒ undefined', D.findProject(projects, 'nope') === undefined, true);

// ---------------------------------------------------------------------------
group('选 Agent：只从就绪集合里挑（configured && active && running）');
const runtimes = [
  runtime('rt-stopped', 'stopped', true, false),
  runtime('rt-starting', 'starting', true, true),
  runtime('rt-ready', 'running', true, true),
  runtime('rt-noconf', 'running', false, true)
];
eq('记忆命中就绪项', D.pickDraftRuntime(entry(DEV_A, 'rt-ready'), DEV_A, runtimes), 'rt-ready');
eq('记忆指向没就绪的 ⇒ 回落到就绪项',
  D.pickDraftRuntime(entry(DEV_A, 'rt-stopped'), DEV_A, runtimes), 'rt-ready');
eq('记忆指向另一台设备的 Agent ⇒ 不当真',
  D.pickDraftRuntime(entry(DEV_B, 'rt-ready'), DEV_A, runtimes), 'rt-ready');
eq('没有记忆 ⇒ 第一个就绪项', D.pickDraftRuntime(undefined, DEV_A, runtimes), 'rt-ready');
eq('一个有就绪的都没有 ⇒ 空串（不许瞎选）',
  D.pickDraftRuntime(undefined, DEV_A, [runtime('rt-starting', 'starting', true, true)]), '');
eq('未配置(configured=false)不算就绪',
  D.pickDraftRuntime(undefined, DEV_A, [runtime('rt-noconf', 'running', false, true)]), '');
eq('未激活(active=false)不算就绪',
  D.pickDraftRuntime(undefined, DEV_A, [runtime('rt-stopped', 'stopped', true, false)]), '');
eq('两个就绪项时取第一个',
  D.pickDraftRuntime(undefined, DEV_A, [runtime('rt-1', 'running'), runtime('rt-2', 'running')]), 'rt-1');
eq('空列表 ⇒ 空串', D.pickDraftRuntime(undefined, DEV_A, []), '');
eq('findRuntime 命中', D.findRuntime(runtimes, 'rt-ready').status, 'running');

// ---------------------------------------------------------------------------
group('分支判定：顺序决定用户先看到哪条出路');
function inv(o) {
  return {
    deviceCount: o.deviceCount === undefined ? 1 : o.deviceCount,
    loadingRuntimes: o.loadingRuntimes === true,
    runtimeCount: o.runtimeCount === undefined ? 1 : o.runtimeCount,
    readyRuntimeCount: o.readyRuntimeCount === undefined ? 1 : o.readyRuntimeCount,
    settling: o.settling === true,
    projectCount: o.projectCount === undefined ? 1 : o.projectCount
  };
}
eq('全齐 ⇒ ready', D.draftSetupKind(inv({})), 'ready');
eq('没设备 ⇒ no-device（即使其它项都缺）',
  D.draftSetupKind(inv({ deviceCount: 0, runtimeCount: 0, projectCount: 0 })), 'no-device');
eq('正在加载 ⇒ loading', D.draftSetupKind(inv({ loadingRuntimes: true })), 'loading');
eq('加载中优先于「没有 Agent」',
  D.draftSetupKind(inv({ loadingRuntimes: true, runtimeCount: 0 })), 'loading');
eq('没有 Agent ⇒ no-runtime', D.draftSetupKind(inv({ runtimeCount: 0 })), 'no-runtime');
eq('过渡态且无就绪 ⇒ settling',
  D.draftSetupKind(inv({ readyRuntimeCount: 0, settling: true })), 'settling');
eq('过渡态但已有就绪项 ⇒ 直接用（不拦人）',
  D.draftSetupKind(inv({ readyRuntimeCount: 1, settling: true })), 'ready');
eq('有 Agent 但没启用 ⇒ inactive',
  D.draftSetupKind(inv({ readyRuntimeCount: 0, settling: false })), 'inactive');
eq('Agent 就绪但没工作区 ⇒ no-project',
  D.draftSetupKind(inv({ projectCount: 0 })), 'no-project');

group('分支文案（空串/缺项都不许崩）');
const kinds = ['ready', 'no-device', 'loading', 'no-runtime', 'settling', 'inactive', 'no-project'];
for (const kind of kinds) {
  if (kind !== 'ready') {
    check(kind + ' 有标题', D.draftSetupTitle(kind).length > 0);
    check(kind + ' 有说明', D.draftSetupDescription(kind, '').length > 0);
  }
}
eq('loading 没有可执行动作 ⇒ 空串', D.draftSetupActionLabel('loading'), '');
eq('过渡态按钮是「重新检查」', D.draftSetupActionLabel('settling'), '重新检查');
eq('没工作区的按钮是「新建工作区」', D.draftSetupActionLabel('no-project'), '新建工作区');
eq('过渡态把服务端原话带出来',
  D.draftSetupDescription('settling', '正在等待本地 DSH Bridge'),
  '请稍候，正在等待本地 DSH Bridge');
eq('过渡态没有原话时用通用句',
  D.draftSetupDescription('settling', ''), '请稍候，就绪后会自动出现在可选列表里。');

// ---------------------------------------------------------------------------
group('工作区显示名与副标题');
eq('有项目名 ⇒ 用项目名', D.workspaceLabelFor('HarmonyOS', '/home/u/x'), 'HarmonyOS');
eq('没项目名 ⇒ 取路径末段', D.workspaceLabelFor('', '/home/u/HarmonyOS'), 'HarmonyOS');
eq('末尾斜杠被裁', D.workspaceLabelFor('', '/home/u/HarmonyOS/'), 'HarmonyOS');
eq('Windows 反斜杠路径', D.workspaceLabelFor('', 'C:\\Users\\me\\projects'), 'projects');
eq('空路径 ⇒ 空串', D.workspaceLabelFor('', ''), '');
eq('纯斜杠不崩', D.workspaceLabelFor('', '///'), '');
eq('副标题三段的串联', D.draftSubtitle('Mate70', 'DeepSeek Harness', 'HarmonyOS'),
  'Mate70 · DeepSeek Harness · HarmonyOS');
eq('副标题跳过空项', D.draftSubtitle('', 'Agent', '工作区'), 'Agent · 工作区');
eq('副标题全空 ⇒ 空串', D.draftSubtitle('', '', ''), '');
eq('副标题裁空白', D.draftSubtitle(' Mate70 ', ' Agent ', ' W '), 'Mate70 · Agent · W');

// ---------------------------------------------------------------------------
group('与记忆模块的联动（默认值真的来自 R47 那本偏好）');
const book = P.withTarget(P.emptyBook(), ACC, DEV_B, RT_Y);
const prefEntry = P.readPreferenceEntry(book, ACC);
eq('记忆里的设备被优先选中', D.pickDraftDevice(prefEntry, '', devices.concat([device(DEV_B, true)])), DEV_B);
eq('记忆里的 Agent 被优先选中',
  D.pickDraftRuntime(prefEntry, DEV_B, [runtime(RT_X, 'running'), runtime(RT_Y, 'running')]), RT_Y);
eq('记忆作用域不匹配时回落默认',
  D.pickDraftRuntime(P.readPreferenceEntry(P.withTarget(P.emptyBook(), ACC, 'dev-other', 'rt-other'), ACC),
    DEV_A, [runtime(RT_X, 'running')]), RT_X);

// ---------------------------------------------------------------------------
console.log(NL + '== 汇总 ============');
if (failures.length === 0) {
  console.log('suite-new-chat: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('失败 ' + failures.length + ' 条');
for (const f of failures) { console.log('  - ' + f); }
process.exit(1);
