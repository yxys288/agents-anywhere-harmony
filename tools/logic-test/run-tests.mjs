#!/usr/bin/env node
/**
 * aa-hm 纯逻辑自测（无设备可跑的那部分）。
 *
 * 为什么需要它：鸿蒙工程的 ArkTS 只有在 `assembleHap` 时才会做类型检查，
 * 而**运行期行为**（协议归一化、DTO 映射、时间线投影、VT 转义序列解析）
 * 在拿到签名 HAP 装到设备之前无法验证。这里把这些**不依赖 ArkUI/Kit** 的模块
 * 用 DevEco 自带的 TypeScript 转译成 CommonJS，在 Node 里跑断言，
 * 作为「逻辑层已按预期工作」的可复现证据。
 *
 * 用法：
 *   node tools\logic-test\run-tests.mjs
 * 产物全部落在系统临时目录（不污染工程目录）。
 */

import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, requireTypeScript, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic');

/** 只挑不 import @kit / ArkUI 的模块。 */
const LOGIC_FILES = [
  'api/ApiUrls.ets',
  'api/Parse.ets',
  'model/Types.ets',
  'model/AppModels.ets',
  'model/AppConfig.ets',
  'model/TextFiles.ets',
  'model/RemotePaths.ets',
  'model/SessionGating.ets',
  'feature/TimelineProjection.ets',
  'vt/WcWidth.ets',
  'vt/TerminalStyle.ets',
  'vt/TerminalRow.ets',
  'vt/TerminalBuffer.ets',
  'vt/TerminalEmulator.ets',
  'vt/KeyHandler.ets',
  'utils/Sha256.ets',
  'ui/MarkdownParse.ets',
  'ui/SyntaxHighlight.ets',
  'model/FileSearch.ets',
  'model/RuntimeSelection.ets'
];

/**
 * UI 文件里的「纯逻辑区」：UI 文件带 `struct`，整体转译不了，所以按源码里的标记把纯逻辑段
 * 切出来单独转译。目前只有一处 —— 终端页的「设备选择」区（`TerminalScreen.ets` 与
 * `FilesScreen.ets` **共用**同一份实现，两页因此是真同构而不是两份复制）。
 */
const PURE_SLICES = [
  {
    rel: 'ui/screens/TerminalScreen.ets',
    begin: '// >>> AA-DEVICE-PURE-BEGIN',
    end: '// <<< AA-DEVICE-PURE-END',
    out: 'ui/screens/TerminalDevice.js'
  }
];

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
  for (const slice of PURE_SLICES) {
    const source = fs.readFileSync(path.join(SRC_ETS, slice.rel), 'utf8');
    const begin = source.indexOf(slice.begin);
    const end = source.indexOf(slice.end);
    if (begin < 0 || end <= begin) {
      throw new Error(`${slice.rel} 里找不到纯逻辑标记（${slice.begin} / ${slice.end}）：标记被删或改名了？`);
    }
    const text = source.slice(begin + slice.begin.length, end);
    if (text.indexOf('import ') >= 0) {
      throw new Error(`${slice.rel} 的纯逻辑区出现了 import —— 该区必须零依赖`);
    }
    const target = path.join(OUT_DIR, slice.out);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, ts.transpileModule(text, {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
        removeComments: false
      },
      fileName: slice.rel
    }).outputText, 'utf8');
  }
}

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
  } else {
    failures.push(detail === undefined ? name : `${name} — ${detail}`);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function group(title) {
  console.log(`\n== ${title}`);
}

// ---------------------------------------------------------------------------

build();

const require = createRequire(import.meta.url);
const load = (rel) => require(path.join(OUT_DIR, rel));

const urls = load('api/ApiUrls.js');
const parse = load('api/Parse.js');
const model = load('model/AppModels.js');
const config = load('model/AppConfig.js');
const projection = load('feature/TimelineProjection.js');
const wcwidth = load('vt/WcWidth.js');
const vt = load('vt/TerminalEmulator.js');
const keys = load('vt/KeyHandler.js');
const sha = load('utils/Sha256.js');
const md = load('ui/MarkdownParse.js');
const hl = load('ui/SyntaxHighlight.js');
const textFiles = load('model/TextFiles.js');
const remotePaths = load('model/RemotePaths.js');
const gating = load('model/SessionGating.js');

group('服务器地址归一化（api/ApiUrls）');
eq('裸域名补 https', urls.normalizeServerOrigin('web.agents-anywhere.com'), 'https://web.agents-anywhere.com');
eq('带尾斜杠被裁掉', urls.normalizeServerOrigin('https://a.example.com/'), 'https://a.example.com');
eq('局域网 IP 自动补 http', urls.normalizeServerOrigin('192.168.1.10:8000'), 'http://192.168.1.10:8000');
eq('localhost 自动补 http', urls.normalizeServerOrigin('localhost:5174'), 'http://localhost:5174');
eq('172.16/12 网段算局域网', urls.normalizeServerOrigin('172.20.0.3'), 'http://172.20.0.3');
eq('仅 /api/v2 路径被接受', urls.normalizeServerOrigin('https://a.example.com/api/v2'), 'https://a.example.com');
eq('其它路径判非法', urls.normalizeServerOrigin('https://a.example.com/other'), null);
eq('带 query 判非法', urls.normalizeServerOrigin('https://a.example.com/?x=1'), null);
eq('带 userinfo 判非法', urls.normalizeServerOrigin('https://u:p@a.example.com'), null);
eq('空串判非法', urls.normalizeServerOrigin('   '), null);
eq('大写 scheme 归一', urls.normalizeServerOrigin('HTTPS://A.EXAMPLE.COM'), 'https://a.example.com');
check('公网 IP 不算局域网', urls.usesLocalNetworkHost('8.8.8.8') === false);
check('10 网段算局域网', urls.usesLocalNetworkHost('10.1.2.3') === true);
eq('apiPath 加命名空间', urls.apiPath('/sessions'), '/api/v2/sessions');
eq('apiPath 幂等', urls.apiPath('/api/v2/sessions'), '/api/v2/sessions');
eq('apiPath 保留 query', urls.apiPath('/sessions?archived=false'), '/api/v2/sessions?archived=false');
eq('未定风格时双候选', urls.apiUrlCandidates('https://a.example.com', '/projects').length, 2);
urls.rememberApiUrl('https://a.example.com', 'https://a.example.com/api/v2/projects');
eq('记住 namespaced 后单候选', urls.apiUrlCandidates('https://a.example.com', '/projects').length, 1);
eq('记住后 apiUrl 用命名空间', urls.apiUrl('https://a.example.com', '/projects'), 'https://a.example.com/api/v2/projects');
eq('WS 地址由 https 派生 wss', urls.webSocketApiUrl('https://a.example.com', '/dashboard/ws?ticket=t'),
  'wss://a.example.com/api/v2/dashboard/ws?ticket=t');

group('DTO 归一化（api/Parse）');
const session = parse.parseSession({
  id: 's1', connectorId: 'c1', status: 'running', pinned: true,
  runtimeType: 'claude', runtimeName: 'my-claude', updatedSeq: 7
});
eq('runtime 回退到 runtimeType', session.runtime, 'claude');
eq('runtimeId 回退', session.runtimeId, 'claude');
eq('runtimeName 保留实例名', session.runtimeName, 'my-claude');
eq('connectorStatus 默认 offline', session.connectorStatus, 'offline');
eq('lastReadSeq 默认 0', session.lastReadSeq, 0);

const item = parse.parseTimelineItem({ id: 'i1', type: 'message', role: 'assistant', content: { message: 'hi' } });
eq('timeline text 回退 content.message', item.text, 'hi');
eq('timeline status 默认 done', item.status, 'done');
eq('timeline revision 默认 1', item.revision, 1);
eq('timeline content 保留原始 JSON', item.content.message, 'hi');

const caps = parse.parseCapabilitySet(undefined);
eq('缺能力集时 revision=0', caps.revision, 0);
eq('缺能力集时为空数组', caps.capabilities.length, 0);
const capSet = parse.parseCapabilitySet({
  revision: 3,
  capabilities: [
    { capabilityId: 'session.interrupt', supported: true, available: true, allowed: true },
    { capabilityId: 'session.takeover', supported: true, available: true, allowed: false }
  ]
});
check('允许的能力 usable', parse.capabilityUsable(capSet, 'session.interrupt'));
check('未授权的能力 not usable', parse.capabilityUsable(capSet, 'session.takeover') === false);
check('未知能力 not usable', parse.capabilityUsable(capSet, 'nope') === false);

const rtList = parse.parseDeviceRuntimeList({
  runtimes: [
    { runtimeId: 'codex', runtimeType: 'codex', present: true },
    { runtimeId: 'BAD ID', runtimeType: 'Bad Type' },
    { runtimeId: 'rti_abc123', runtimeType: 'claude', present: true }
  ]
}, 'c1');
eq('过滤非法 runtime 后剩 2 个', rtList.length, 2);
eq('legacy runtime 字段回退', parse.parseDeviceRuntime({ runtime: 'dsh' }, 'c1').runtimeType, 'dsh');
eq('runtimeId 即 runtimeType 时沿用', parse.parseDeviceRuntime({ runtimeId: 'codex' }, 'c1').runtimeType, 'codex');

eq('游标 seq:12 → 12', parse.eventCursorSequence('seq:12'), 12);
eq('游标 seq:0 → 0', parse.eventCursorSequence('seq:0'), 0);
eq('游标前导零非法', parse.eventCursorSequence('seq:012'), undefined);
eq('游标格式非法', parse.eventCursorSequence('12'), undefined);

const dashboard = parse.parseDashboardSnapshot({
  type: 'dashboard.snapshot',
  connectors: [{ id: 'c1', name: 'Mac', status: 'online' }],
  projects: [{ id: 'p1', name: 'demo', connectorId: 'c1' }],
  sessions: [{ id: 's1', connectorId: 'c1', archived: false }],
  sessionPages: { active: { hasMore: false }, archived: { hasMore: true } }
});
check('dashboard.snapshot 可解析', dashboard !== undefined);
eq('快照设备数', dashboard.devices.length, 1);
eq('快照项目数', dashboard.projects.length, 1);
check('归档分页 hasMore', dashboard.archivedPage.hasMore === true);
eq('非 dashboard.snapshot 返回 undefined', parse.parseDashboardSnapshot({ type: 'other' }), undefined);

group('会话模型与排序（model/AppModels）');
eq('runtimeTypeLabel(dsh)', model.runtimeTypeLabel('dsh'), 'DeepSeek Harness');
eq('runtimeTypeLabel(claude)', model.runtimeTypeLabel('claude'), 'Claude Code');
eq('runtimeTypeLabel(其它) 首字母大写', model.runtimeTypeLabel('gemini'), 'Gemini');
eq('实例名优先于类型名', model.runtimeInstanceLabels('work-codex', 'codex').primary, 'work-codex');
eq('实例名等于类型名时不重复', model.runtimeInstanceLabels('codex', 'codex').secondary, undefined);
eq('workspaceName 取末段', model.workspaceName('/home/me/code/demo'), 'demo');
eq('workspaceName 去尾斜杠', model.workspaceName('/srv/app/'), 'app');
eq('状态映射 running', model.sessionStatusFromWire('running'), 'running');
eq('状态映射未知值', model.sessionStatusFromWire('weird'), 'unknown');

const mapped = model.toAgentSession({
  id: 's1', connectorId: 'c1', connectorStatus: 'online', runtime: 'codex', runtimeType: 'codex',
  status: 'waiting_approval', pinned: false, archived: false, unread: true, lastReadSeq: 0,
  updatedSeq: 1, takeover: false, cwd: '/srv/app', title: '修复登录',
  lastActivityAt: new Date(Date.now() - 5 * 60000).toISOString()
}, 'Mac');
eq('标题', mapped.title, '修复登录');
eq('工作区标签', mapped.workspaceLabel, 'app');
eq('审批态 indicator', mapped.indicator, 'waiting_approval');
check('审批态算 live', mapped.live === true);
eq('状态中文标签', mapped.statusLabel, '待审批');
eq('metaLabel 含设备名', mapped.metaLabel.includes('Mac'), true);
// R13-8 裁决：相对时间改为上游 `SessionMappers.kt:110-130` 的英文紧凑格式（夹具是 5 分钟前）。
eq('相对时间 5 分钟 → 5m（上游格式）', mapped.updatedAtLabel, '5m');

const a = model.toAgentSession({ id: 'a', connectorId: 'c', connectorStatus: 'online', runtime: 'codex', status: 'idle', pinned: true, archived: false, unread: false, lastReadSeq: 0, updatedSeq: 1, takeover: false, sortAt: '2026-01-01T00:00:00Z' }, undefined);
const b = model.toAgentSession({ id: 'b', connectorId: 'c', connectorStatus: 'online', runtime: 'codex', status: 'idle', pinned: false, archived: false, unread: false, lastReadSeq: 0, updatedSeq: 2, takeover: false, sortAt: '2026-06-01T00:00:00Z' }, undefined);
eq('置顶排在前', model.compareSessions(a, b) < 0, true);
eq('未命名会话标题', model.toAgentSession({ id: 'x', connectorId: 'c', connectorStatus: 'offline', runtime: 'codex', status: 'idle', pinned: false, archived: false, unread: false, lastReadSeq: 0, updatedSeq: 0, takeover: false }, undefined).title, '未命名会话');
eq('设备离线摘要', model.toAgentSession({ id: 'x', connectorId: 'c', connectorStatus: 'offline', runtime: 'codex', status: 'idle', pinned: false, archived: false, unread: false, lastReadSeq: 0, updatedSeq: 0, takeover: false }, undefined).summary, '设备离线。');

group('版本比较（model/AppConfig）');
eq('2.0.1 > 2.0.0', config.compareVersions('2.0.1', '2.0.0'), 1);
eq('2.0 == 2.0.0', config.compareVersions('2.0', '2.0.0'), 0);
eq('1.9.9 < 2.0.0', config.compareVersions('1.9.9', '2.0.0'), -1);
eq('v 前缀可解析', config.compareVersions('v2.1.0', '2.0.0'), 1);
eq('预发布后缀被忽略', config.compareVersions('2.0.0-beta.1', '2.0.0'), 0);
eq('非法版本返回 undefined', config.compareVersions('abc', '1.0'), undefined);

group('时间线投影（feature/TimelineProjection）');
const timeline = projection.projectTimeline([
  { id: 'm1', type: 'message', role: 'user', text: '跑一下测试', orderSeq: 1, revision: 1, updatedSeq: 1, status: 'done', createdAt: '', content: {}, source: {} },
  { id: 't1', type: 'tool', orderSeq: 2, revision: 1, updatedSeq: 2, status: 'done', createdAt: '', source: {}, content: { kind: 'command', command: 'npm test', exitCode: 0, output: 'ok' } },
  { id: 'f1', type: 'tool', orderSeq: 3, revision: 1, updatedSeq: 3, status: 'done', createdAt: '', source: {}, content: { kind: 'file_change', changes: [{ path: 'src/a.ts', kind: 'update', added: 3, removed: 1 }] } },
  { id: 'a1', type: 'message', role: 'assistant', text: '完成', orderSeq: 4, revision: 1, updatedSeq: 4, status: 'done', createdAt: '', content: {}, source: {} }
]);
eq('投影出 4 条消息', timeline.length, 4);
eq('第一条是用户', timeline[0].author, 'user');
eq('命令类识别为 command', timeline[1].kind, 'command');
eq('命令默认折叠', timeline[1].collapsedByDefault, true);
eq('命令退出码', timeline[1].exitCode, 0);
eq('文件变更摘要含路径', timeline[2].body.includes('src/a.ts'), true);
eq('assistant 作者', timeline[3].author, 'agent');
eq('顺序按 orderSeq', timeline.map((m) => m.orderSeq).join(','), '1,2,3,4');

const merged = projection.mergeTimelineItems(
  [{ id: 'x', type: 'message', text: 'v1', orderSeq: 1, revision: 1, updatedSeq: 1, status: 'done', createdAt: '', content: {}, source: {} }],
  [{ id: 'x', type: 'message', text: 'v2', orderSeq: 1, revision: 2, updatedSeq: 5, status: 'done', createdAt: '', content: {}, source: {} },
   { id: 'y', type: 'message', text: 'new', orderSeq: 2, revision: 1, updatedSeq: 6, status: 'done', createdAt: '', content: {}, source: {} }],
  false
);
eq('upsert 后 2 条', merged.length, 2);
eq('同 id 取 revision 更高者', merged[0].text, 'v2');
eq('replace 语义去重', projection.mergeTimelineItems([], [
  { id: 'z', text: 'a', revision: 1, updatedSeq: 1, orderSeq: 1, type: 'message', status: 'done', createdAt: '', content: {}, source: {} },
  { id: 'z', text: 'b', revision: 2, updatedSeq: 2, orderSeq: 1, type: 'message', status: 'done', createdAt: '', content: {}, source: {} }
], true).length, 1);

const blocks = projection.splitCodeBlocks('说明\n```ts\nconst a=1;\n```\n结尾');
eq('代码块切分 3 段', blocks.length, 3);
eq('代码块语言', blocks[1].language, 'ts');
eq('代码块内容', blocks[1].code, 'const a=1;\n');

group('字符宽度（vt/WcWidth）');
eq('ASCII 宽 1', wcwidth.codePointWidth(0x61), 1);
eq('汉字宽 2', wcwidth.codePointWidth('中'.codePointAt(0)), 2);
eq('全角逗号宽 2', wcwidth.codePointWidth(0xFF0C), 2);
eq('组合符宽 0', wcwidth.codePointWidth(0x0301), 0);
eq('emoji 宽 2', wcwidth.codePointWidth(0x1F600), 2);

group('VT 终端仿真（vt/TerminalEmulator）');
function makeEmulator(cols, rows) {
  const events = { title: '', writes: [], bell: 0, invalidations: 0 };
  const output = {
    write: (data) => events.writes.push(data),
    titleChanged: (title) => { events.title = title; },
    clipboardCopy: () => {},
    bell: () => { events.bell += 1; },
    invalidate: () => { events.invalidations += 1; }
  };
  return { emulator: new vt.TerminalEmulator(cols, rows, output, true), events };
}

let t = makeEmulator(20, 5);
t.emulator.appendText('hello');
eq('普通文本写入', t.emulator.row(0).toText(), 'hello');
eq('光标前进到第 5 列', t.emulator.cursorCol(), 5);
t.emulator.appendText('\r\n');
eq('回车换行后光标行 1', t.emulator.cursorRow(), 1);
eq('换行后光标列 0', t.emulator.cursorCol(), 0);

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[2J\u001b[H');
eq('清屏后为空', t.emulator.row(0).toText(), '');
eq('清屏后光标归位', t.emulator.cursorRow(), 0);

t = makeEmulator(20, 5);
t.emulator.appendText('abc\u0008X');
eq('退格覆盖', t.emulator.row(0).toText(), 'abX');

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[1;3HZ');
eq('CSI H 定位写字符', t.emulator.row(0).toText().startsWith('  Z'), true);

t = makeEmulator(20, 5);
t.emulator.appendText('中');
eq('宽字符占两列', t.emulator.cursorCol(), 2);
t.emulator.appendText('a');
eq('宽字符后接字符', t.emulator.row(0).toText(), '中a');

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[7mX\u001b[0m');
const stylePool = t.emulator.stylePool();
const inverseStyle = stylePool.get(t.emulator.row(0).getStyle(0));
eq('SGR 7 设置反显位', (inverseStyle.flags & 32) !== 0, true);
const normalStyle = stylePool.get(t.emulator.row(0).getStyle(1));
eq('SGR 0 复位', normalStyle.flags, 0);

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[31mR');
eq('SGR 31 前景色=红(1)', t.emulator.stylePool().get(t.emulator.row(0).getStyle(0)).foreground, 1);
t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[38;5;208mP');
eq('SGR 38;5;n 索引色', t.emulator.stylePool().get(t.emulator.row(0).getStyle(0)).foreground, 208);
t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[38;2;10;20;30mQ');
const truecolor = t.emulator.stylePool().get(t.emulator.row(0).getStyle(0)).foreground;
eq('SGR 38;2;r;g;b 真彩色 r', (truecolor >> 16) & 0xFF, 10);
eq('SGR 38;2;r;g;b 真彩色 g', (truecolor >> 8) & 0xFF, 20);
eq('SGR 38;2;r;g;b 真彩色 b', truecolor & 0xFF, 30);

t = makeEmulator(10, 3);
t.emulator.appendText('1234567890AB');
eq('自动换行后第一行满', t.emulator.row(0).toText(), '1234567890');
eq('自动换行后第二行', t.emulator.row(1).toText(), 'AB');

t = makeEmulator(10, 3);
t.emulator.appendText('line1\r\nline2\r\nline3\r\nline4');
eq('满屏滚动后首行为 line2', t.emulator.row(0).toText(), 'line2');
eq('滚动后末行为 line4', t.emulator.row(2).toText(), 'line4');
eq('回看行数累计 1', t.emulator.scrolledLines(), 1);

// --- 回看视图取行（终端页上下拖拽） --------------------------------------
// 终端页用 rowWithOffset(row, offset) 把整屏上移 offset 行来显示历史；
// offset=0 必须与 row() 完全一致（否则「回到最新」会错位）。
eq('回看 offset=0 等价 row(0)', t.emulator.rowWithOffset(0, 0).toText(),
  t.emulator.row(0).toText());
eq('可回看行数=1', t.emulator.maxScrollOffset(), 1);
eq('回看 offset=1 顶行=line1', t.emulator.rowWithOffset(0, 1).toText(), 'line1');
eq('回看 offset=1 次行=line2', t.emulator.rowWithOffset(1, 1).toText(), 'line2');
eq('回看 offset=1 末行=line3', t.emulator.rowWithOffset(2, 1).toText(), 'line3');
// 越界要兜底成空行，不能抛
eq('回看超界返回空行', t.emulator.rowWithOffset(0, 99).toText(), '');
eq('回看负数偏移视作 0', t.emulator.rowWithOffset(0, -5).toText(), t.emulator.row(0).toText());

t = makeEmulator(10, 3);
for (let i = 0; i < 300; i++) {
  t.emulator.appendText(`L${i}\r\n`);
}
eq('大量滚动后可回看行数受上限约束', t.emulator.maxScrollOffset() <= 300, true);
eq('上限处取行不越界',
  t.emulator.rowWithOffset(0, t.emulator.maxScrollOffset()).toText().length >= 0, true);

t = makeEmulator(10, 4);
t.emulator.appendText('\u001b[?1049hALT');
eq('进入备用屏', t.emulator.isAltScreen, true);
eq('备用屏内容', t.emulator.row(0).toText(), 'ALT');
t.emulator.appendText('\u001b[?1049l');
eq('退出备用屏', t.emulator.isAltScreen, false);
eq('主屏内容未受影响', t.emulator.row(0).toText(), '');

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b]0;my-title\u0007');
eq('OSC 0 设置标题', t.events.title, 'my-title');

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[?2004h');
t.emulator.sendText('pasted');
eq('括号粘贴包裹', t.events.writes[0], '\u001b[200~pasted\u001b[201~');

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[?25l');
eq('隐藏光标', t.emulator.cursorVisible(), false);
t.emulator.appendText('\u001b[?25h');
eq('显示光标', t.emulator.cursorVisible(), true);

t = makeEmulator(20, 5);
t.emulator.appendText('abcdef\u001b[3DXY');
eq('CSI D 左移后覆盖', t.emulator.row(0).toText(), 'abcXYf');

t = makeEmulator(20, 5);
t.emulator.appendText('hello\u001b[2K');
eq('CSI 2K 清整行', t.emulator.row(0).toText(), '');

t = makeEmulator(20, 5);
t.emulator.appendText('a\u001b[4hbc');
eq('插入模式插字符', t.emulator.row(0).toText().startsWith('abc'), true);

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[2;4r\u001b[2;1HX');
eq('滚动区域设置后仍可写', t.emulator.row(1).toText().startsWith('X'), true);

t = makeEmulator(20, 5);
t.emulator.appendText('tab\u0009X');
eq('TAB 跳到第 8 列', t.emulator.row(0).getChar(8) === 'X'.codePointAt(0), true);

t = makeEmulator(20, 5);
t.emulator.resize(30, 8);
eq('resize 后列数', t.emulator.columns, 30);
eq('resize 后行数', t.emulator.rows, 8);

// --- resize 的两条不变量（第七轮真机暴露：键盘开合会 resize 网格） -------------
// ① 光标必须跟着内容一起搬，否则真机上表现为「提示符在第 N 行、光标块停在第 0 行」
t = makeEmulator(20, 6);
t.emulator.appendText('L0\r\nL1\r\nL2\r\nL3\r\nL4');
eq('resize 前光标在第 4 行', t.emulator.cursorRow(), 4);
eq('resize 前第 4 行内容', t.emulator.row(4).toText(), 'L4');
t.emulator.resize(20, 3);
// R37 行为变更（真机反馈驱动）：收缩时**优先从光标行之下（底部空行）取行**，
// 不够了才从顶部取并推进回看区。改前一律「顶部丢 drop 行」—— 光标停在第 0 行时
// （终端刚打开只有一行提示符）那一刀正好把唯一有内容的行推出屏幕，用户看到的就是
// 「键盘拉起 / 重开终端后内容跳到屏幕中间或直接没了」。
// 本场景：光标在第 4 行、其下只有 1 行空行 ⇒ 底部丢 1、顶部丢 2 ⇒ 回看区只多 2 行，
// 屏上还留着 L2/L3/L4（改前是顶部丢 3，屏上只剩 L3/L4 加一个空行）。
eq('收缩后光标仍在内容所在行（4-2=2）', t.emulator.cursorRow(), 2);
eq('收缩后光标行内容仍是 L4', t.emulator.row(t.emulator.cursorRow()).toText(), 'L4');
eq('收缩挤掉的行进了回看区', t.emulator.maxScrollOffset(), 2);
eq('回看能取到被挤掉的 L0', t.emulator.rowWithOffset(0, 2).toText(), 'L0');


// ② 扩张要把行从回看区拉回来 ⇒「键盘弹起→收起」是一次可逆往返
t.emulator.resize(20, 6);      // 扩张回原尺寸
eq('扩张后光标回到第 4 行', t.emulator.cursorRow(), 4);
eq('扩张后第 4 行内容还是 L4', t.emulator.row(4).toText(), 'L4');
eq('扩张后第 0 行内容还原为 L0', t.emulator.row(0).toText(), 'L0');
eq('扩张后回看区被还空', t.emulator.maxScrollOffset(), 0);

// ③ 收缩丢行不能让内容凭空消失（旧实现是直接 splice 掉）
t = makeEmulator(10, 4);
t.emulator.appendText('A\r\nB\r\nC\r\nD');
t.emulator.resize(10, 2);
eq('收缩后屏上是 C/D', t.emulator.row(0).toText() + t.emulator.row(1).toText(), 'CD');
eq('收缩后 A/B 在回看区', t.emulator.rowWithOffset(0, 2).toText(), 'A');
t.emulator.resize(10, 4);
eq('还原后 A 回到第 0 行', t.emulator.row(0).toText(), 'A');
eq('还原后 D 回到第 3 行', t.emulator.row(3).toText(), 'D');

// ④ 回看区上限在 resize 后依然生效（不能因为搬移就无限增长）
t = makeEmulator(10, 3);
for (let i = 0; i < 50; i++) {
  t.emulator.appendText(`x${i}\r\n`);
}
t.emulator.resize(10, 2);
eq('resize 后回看行数不超上限', t.emulator.maxScrollOffset() <= 200, true);

// ⑤ R37 新增不变量：**内容在屏幕顶部时收缩/扩张都不许挪动它**（用户反馈的那个现象）
t = makeEmulator(20, 6);
t.emulator.appendText('PS>');
eq('R37 起点：光标在第 0 行', t.emulator.cursorRow(), 0);
t.emulator.resize(20, 3);        // 键盘拉起 → 收缩
eq('R37 收缩后光标仍在第 0 行', t.emulator.cursorRow(), 0);
eq('R37 收缩后内容还在屏上', t.emulator.row(0).toText(), 'PS>');
eq('R37 收缩没往回看区塞内容', t.emulator.maxScrollOffset(), 0);
t.emulator.resize(20, 6);        // 键盘收起 → 扩张
eq('R37 扩张后内容仍在第 0 行', t.emulator.row(0).toText(), 'PS>');
eq('R37 扩张后光标仍在第 0 行', t.emulator.cursorRow(), 0);

// ⑥ R37：`clearAll` 必须把**光标**也归零 —— 否则「清屏后新输出从哪一行开始」取决于
// 上一屏光标停在哪，重开终端时新 shell 的提示符就会落在屏幕中间。
t = makeEmulator(20, 6);
t.emulator.appendText('a\r\nb\r\nc');
t.emulator.buffer.clearAll(0);
eq('清屏后光标回到左上角', t.emulator.cursorRow(), 0);
eq('清屏后首行是空的', t.emulator.row(0).toText(), '');

t = makeEmulator(20, 5);
t.emulator.appendText('\u001b[31mX');
t.emulator.appendText('\u001b7\u001b[0m\u001b[5;5HY\u001b8Z');
eq('DECSC/DECRC 恢复光标与样式', t.emulator.row(0).getChar(1) === 'Z'.codePointAt(0), true);

t = makeEmulator(20, 5);
t.emulator.appendText('\u0007');
eq('BEL 触发回调', t.events.bell, 1);

group('按键映射（vt/KeyHandler）');
eq('Ctrl+C', keys.ctrlSequence('C'), '\u0003');
eq('Ctrl+[ → ESC', keys.ctrlSequence('['), '\u001b');
eq('小写也映射', keys.ctrlSequence('d'), '\u0004');
const kt = makeEmulator(20, 5);
eq('普通模式方向键 CSI', kt.emulator.cursorKey('A'), '\u001b[A');
kt.emulator.appendText('\u001b[?1h');
eq('应用模式方向键 SS3', kt.emulator.cursorKey('A'), '\u001bOA');
eq('PageUp', keys.pageUpKey(), '\u001b[5~');
eq('Delete', keys.deleteKey(), '\u001b[3~');
eq('Shift+Tab', keys.shiftTabKey(), '\u001b[Z');
eq('F5', keys.functionKey(5), '\u001b[15~');
eq('退格是 DEL(0x7f)', keys.backspaceKey(), '\u007f');
const extraEscape = keys.resolveExtraKey({ label: 'ESC', sequence: '\u001b' }, kt.emulator, false, false);
eq('额外键行 ESC 直发', extraEscape, '\u001b');
const extraWithCtrl = keys.resolveExtraKey({ label: 'C', sequence: 'c' }, kt.emulator, true, false);
eq('额外键行 CTRL+C', extraWithCtrl, '\u0003');

group('\u7ec8\u7aef\u56de\u653e\u89e3\u6790\uff08\u6a21\u62df\u670d\u52a1\u7aef replay \u5185\u5bb9\uff09');
// \u4e0e tools/mock-server/server.mjs \u7684 terminalReplay() \u4fdd\u6301\u540c\u6784\uff1a
// \u6e05\u5c4f / \u989c\u8272 / \u5c5e\u6027 / 256 \u8272 / \u771f\u5f69\u8272 / \u5bbd\u5b57\u7b26\u5bf9\u9f50 / \u5236\u8868\u4f4d
const R = '\u001b[';
const replay = [
  R + '2J' + R + 'H',
  R + '1;32m\u279c' + R + '0m  ' + R + '1;36m~/code/agents-anywhere' + R + '0m ' + R + '1;33mgit:(main)' + R + '0m',
  '',
  R + '1m$ npm test' + R + '0m',
  '',
  R + '32m\u2713' + R + '0m render.spec.ts        ' + R + '90m(12 ms)' + R + '0m',
  R + '31m\u2717' + R + '0m legacy-route.spec.ts  ' + R + '90m(3 ms)' + R + '0m',
  '',
  R + '1mTests:' + R + '0m ' + R + '32m2 passed' + R + '0m, ' + R + '31m1 failed' + R + '0m, 3 total',
  '',
  R + '7m \u53cd\u663e ' + R + '0m ' + R + '4m\u4e0b\u5212\u7ebf' + R + '0m ' + R + '9m\u5220\u9664\u7ebf' + R + '0m',
  R + '38;5;208m208' + R + '0m ' + R + '38;2;255;120;40m\u6a59\u8272' + R + '0m',
  '',
  '\u5bbd\u5b57\u7b26\u5bf9\u9f50\uff1a',
  '\u250c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u252c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510',
  '\u2502 \u540d\u79f0     \u2502 \u72b6\u6001   \u2502',
  '\u251c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u253c\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2524',
  '\u2502 \u5de5\u4f5c\u53f0   \u2502 \u5c31\u7eea   \u2502',
  '\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2534\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518',
  '',
  '\u5236\u8868\u4f4d:\ta\tb'
];
const rt = makeEmulator(80, 24);
rt.emulator.appendText(replay.join('\r\n'));
eq('replay \u7b2c 0 \u884c\u4e3a\u7a7a\uff08\u6e05\u5c4f\u540e\u5148\u6362\u884c\uff09', rt.emulator.row(0).toText(), '');
check('replay \u7b2c 1 \u884c\u662f\u63d0\u793a\u7b26\uff08\u542b\u8def\u5f84\uff09',
  rt.emulator.row(1).toText().includes('~/code/agents-anywhere'));
check('replay \u7b2c 1 \u884c\u542b git \u5206\u652f', rt.emulator.row(1).toText().includes('git:(main)'));
eq('replay \u7b2c 3 \u884c\u662f\u547d\u4ee4', rt.emulator.row(3).toText(), '$ npm test');
// \u4e0d\u786c\u7f16\u7801\u884c\u53f7\uff1a\u6309\u5185\u5bb9\u53cd\u67e5\uff0c\u907f\u514d\u56de\u653e\u5185\u5bb9\u4e00\u6539\u5c31\u8ddf\u7740\u4fee\u6d4b\u8bd5
const findRow = (needle) => {
  for (let i = 0; i < rt.emulator.rows; i++) {
    if (rt.emulator.row(i).toText().includes(needle)) {
      return i;
    }
  }
  return -1;
};
const colOfInRow = (rowIndex, needle) => rt.emulator.row(rowIndex).toText().indexOf(needle);
const styleAt = (rowIndex, column) => rt.emulator.stylePool().get(rt.emulator.row(rowIndex).getStyle(column));

check('\u2705 \u884c\u4e3a\u7eff\u8272\uff08\u524d\u666f=2\uff09', styleAt(findRow('render.spec.ts'), 0).foreground === 2);
check('\u274c \u884c\u4e3a\u7ea2\u8272\uff08\u524d\u666f=1\uff09', styleAt(findRow('legacy-route'), 0).foreground === 1);
const colorRow = findRow('208');
check('256 \u8272\u7d22\u5f15 208 \u88ab\u8bb0\u5f55', styleAt(colorRow, 0).foreground === 208);
const truecolorColumn = colOfInRow(colorRow, '\u6a59\u8272');
const truecolorStyle = styleAt(colorRow, truecolorColumn);
eq('\u771f\u5f69\u8272 R', (truecolorStyle.foreground >> 16) & 0xFF, 255);
eq('\u771f\u5f69\u8272 G', (truecolorStyle.foreground >> 8) & 0xFF, 120);
eq('\u771f\u5f69\u8272 B', truecolorStyle.foreground & 0xFF, 40);
const inverseRow = findRow('\u53cd\u663e');
check('\u53cd\u663e\u5c5e\u6027\u843d\u5728\u8be5\u884c\u7b2c\u4e00\u5217', (styleAt(inverseRow, 0).flags & 32) !== 0);
const tabRow = findRow('\u5236\u8868\u4f4d');
eq('\u5236\u8868\u4f4d\u8df3\u5230\u7b2c 8 \u5217', rt.emulator.row(tabRow).getChar(8) === 'a'.codePointAt(0), true);

// \u5bbd\u5b57\u7b26\u5bf9\u9f50\uff1a\u6bd4\u7684\u5fc5\u987b\u662f**\u7ec8\u7aef\u5217**\uff08\u4e0d\u662f JS \u5b57\u7b26\u4e32\u4e0b\u6807\uff09\u2014\u2014
// \u4e00\u4e2a\u6c49\u5b57\u5728 JS \u4e32\u91cc\u662f 1 \u4e2a code unit\uff0c\u4f46\u5360 2 \u4e2a\u7ec8\u7aef\u5217\uff0c\u4e24\u8005\u4e0d\u80fd\u76f4\u63a5\u6bd4\u3002
const columnOfNth = (rowIndex, ch, nth) => {
  const row = rt.emulator.row(rowIndex);
  const cp = ch.codePointAt(0);
  let seen = 0;
  for (let c = 0; c < rt.emulator.columns; c++) {
    if (row.getChar(c) === cp) {
      seen += 1;
      if (seen === nth) {
        return c;
      }
    }
  }
  return -1;
};
const borderRow = findRow('\u250c');
const nameRowIndex = findRow('\u540d\u79f0');
const nameRow = rt.emulator.row(nameRowIndex).toText();
const borderRowText = rt.emulator.row(borderRow).toText();
eq('\u76d2\u5b50\u5185\u5bb9\u884c\u9996\u5217\u662f\u7ad6\u7ebf', nameRow.startsWith('\u2502'), true);
eq('\u9876\u8fb9\u6846\u9996\u5217\u662f\u7b2a', borderRowText.startsWith('\u250c'), true);
eq('\u5185\u5bb9\u884c\u4e0e\u8fb9\u6846\u884c\u7684\u7b2c\u4e00\u6839\u7ad6\u7ebf\u540c\u5217',
  columnOfNth(nameRowIndex, '\u2502', 1), columnOfNth(borderRow, '\u250c', 1));
eq('\u5bbd\u5b57\u7b26\u540e\u7684\u5206\u9694\u7ebf\u4ecd\u5bf9\u9f50\uff08\u5185\u5bb9\u884c\u7b2c\u4e8c\u6839 = \u8fb9\u6846\u7684 \u252c\uff09',
  columnOfNth(nameRowIndex, '\u2502', 2), columnOfNth(borderRow, '\u252c', 1));
check('\u5bbd\u5b57\u7b26\u6b63\u786e\u843d\u5e03\uff08\u542b\u4e2d\u6587\u5355\u5143\u683c\uff09',
  nameRow.includes('\u540d\u79f0') && nameRow.includes('\u72b6\u6001'));
check('\u76d2\u5b50\u5e95\u8fb9\u4e5f\u5bf9\u9f50\uff08\u81f3\u5c11 5 \u884c\u6846\u7ebf\uff09',
  findRow('\u2514') > borderRow);

// \u5bbd\u5b57\u7b26\u5360\u4e24\u5217\uff1a\u300c\u540d\u79f0\u300d\u540e\u7684\u7a7a\u683c\u6570\u5fc5\u987b\u662f\u5355\u5bbd\u5b57\u7b26\u7684\u4e24\u500d\u624d\u80fd\u5bf9\u9f50
const wideCheck = makeEmulator(20, 2);
wideCheck.emulator.appendText('\u4e2d\u6587ab');
eq('\u4e24\u4e2a\u6c49\u5b57\u5360 4 \u5217', wideCheck.emulator.cursorCol(), 6);
eq('\u5bbd\u5b57\u7b26\u540e\u7b2c\u4e94\u5217\u662f a', wideCheck.emulator.row(0).getChar(4) === 'a'.codePointAt(0), true);

group('Markdown 轻量解析（ui/MarkdownParse）');
const mdBlocks = md.parseMarkdown([
  '# 标题一',
  '',
  '正常段落，包含 **粗体** 与 `代码`。',
  '',
  '- 项一',
  '- 项二',
  '',
  '1. 第一',
  '2. 第二',
  '',
  '> 引用一句',
  '',
  '```ts',
  'const a = 1;',
  '```'
].join('\n'));
// 注意：每个列表项是独立的一个块（便于逐项渲染与打点）
eq('块数量', mdBlocks.length, 8);
eq('块 0 = 一级标题', mdBlocks[0].kind, 'heading');
eq('标题层级', mdBlocks[0].level, 1);
eq('标题文本', mdBlocks[0].text, '标题一');
eq('块 1 = 段落', mdBlocks[1].kind, 'paragraph');
eq('块 2 = 无序列表项', mdBlocks[2].kind, 'bullet');
eq('块 2 文本', mdBlocks[2].text, '项一');
eq('块 3 = 第二个无序列表项', mdBlocks[3].kind, 'bullet');
eq('块 4 = 有序列表第 1 项', mdBlocks[4].kind, 'ordered');
eq('有序列表序号从 1 开始', mdBlocks[4].index, 1);
eq('块 5 = 有序列表第 2 项', mdBlocks[5].index, 2);
eq('块 6 = 引用', mdBlocks[6].kind, 'quote');
eq('引用文本', mdBlocks[6].text, '引用一句');
eq('块 7 = 代码块', mdBlocks[7].kind, 'code');
eq('代码块语言', mdBlocks[7].language, 'ts');
eq('代码块内容', mdBlocks[7].text, 'const a = 1;');
eq('堆叠空行不产生空段落', mdBlocks.filter((b) => b.kind === 'paragraph').length, 1);

const inline = md.parseInline('前 **粗** 中 `代码` 后 ~~删~~ *斜*');
// 分片：'前 ' / 粗 / ' 中 ' / 代码 / ' 后 ' / 删 / ' ' / 斜
eq('行内分片数', inline.length, 8);
eq('分片 0 纯文本', inline[0].text, '前 ');
eq('分片 1 为粗体', inline[1].bold, true);
eq('粗体文本不含星号', inline[1].text, '粗');
eq('分片 3 为行内代码', inline[3].code, true);
eq('行内代码文本', inline[3].text, '代码');
eq('分片 5 为删除线', inline[5].strike, true);
eq('分片 7 为斜体', inline[7].italic, true);
eq('去标记后的纯文本',
  md.plainText('前 **粗** 中 `代码` 后'), '前 粗 中 代码 后');
eq('未闭合代码块不丢内容',
  md.parseMarkdown('```\nabc').length, 1);
eq('未闭合代码块保留正文',
  md.parseMarkdown('```\nabc')[0].text, 'abc');
eq('纯文本不会误判为标题', md.parseMarkdown('#hashtag')[0].kind, 'paragraph');
eq('行内代码里的星号不被当作粗体',
  md.parseInline('`a**b`')[0].text, 'a**b');

group('语法高亮（ui/SyntaxHighlight）');
eq('ts 别名归一化', hl.normalizeLanguage('ts'), 'typescript');
eq('kt 别名归一化', hl.normalizeLanguage('kt'), 'jvm');
eq('bash 别名归一化', hl.normalizeLanguage('bash'), 'shell');
eq('未知语言退化为 generic', hl.normalizeLanguage('brainfuck'), 'generic');
eq('空标签退化为 generic', hl.normalizeLanguage(''), 'generic');
eq('大小写不敏感', hl.normalizeLanguage('TypeScript'), 'typescript');

// 把 token 列表压成 "kind:text" 便于断言，并去掉纯空白片
const kindsOf = (tokens) => tokens.filter((t) => t.text.trim().length > 0).map((t) => t.kind);
const textOfKind = (tokens, kind) => tokens.filter((t) => t.kind === kind).map((t) => t.text);
const flat = (tokens) => tokens.map((t) => t.text).join('');

const ts = hl.tokenizeCode('const n: number = 42; // 计数', 'ts');
eq('ts: 关键字 const', textOfKind(ts, 'keyword').includes('const'), true);
eq('ts: 内建类型 number', textOfKind(ts, 'type').includes('number'), true);
eq('ts: 数字 42', textOfKind(ts, 'number').includes('42'), true);
eq('ts: 行注释整段', textOfKind(ts, 'comment').join(''), '// 计数');
eq('ts: 还原后与原文一致', flat(ts), 'const n: number = 42; // 计数');

const tsFn = hl.tokenizeCode('doThing(1) + Thing', 'ts');
eq('ts: 调用名识别为函数', textOfKind(tsFn, 'function').includes('doThing'), true);
eq('ts: 大写开头识别为类型', textOfKind(tsFn, 'type').includes('Thing'), true);

const tsStr = hl.tokenizeCode("const s = 'a\\'b';", 'ts');
eq('ts: 转义引号不提前结束', textOfKind(tsStr, 'string').join(''), "'a\\'b'");
eq('ts: 字符串后代码仍被切出', textOfKind(tsStr, 'keyword').includes('const'), true);

const tsUnclosed = hl.tokenizeCode("const s = 'abc\nconst t = 1;", 'ts');
check('ts: 未闭合字符串不跨行吞掉后续', textOfKind(tsUnclosed, 'keyword').filter((w) => w === 'const').length === 2,
  'expected 2 const, got ' + textOfKind(tsUnclosed, 'keyword').filter((w) => w === 'const').length);

const tsTemplate = hl.tokenizeCode('const s = `a\nb`;', 'ts');
eq('ts: 模板串可跨行', textOfKind(tsTemplate, 'string').length, 1);
check('ts: 模板串含换行', textOfKind(tsTemplate, 'string')[0].includes('\n'));

const tsBlock = hl.tokenizeCode('/* a\nb */ const x = 1;', 'ts');
eq('ts: 块注释为一整片', textOfKind(tsBlock, 'comment').length, 1);
eq('ts: 块注释内容完整', textOfKind(tsBlock, 'comment')[0], '/* a\nb */');

const py = hl.tokenizeCode('# 注释\ndef f(x):\n    return None', 'python');
eq('python: # 行注释', textOfKind(py, 'comment').join(''), '# 注释');
eq('python: def 关键字', textOfKind(py, 'keyword').includes('def'), true);
eq('python: return 关键字', textOfKind(py, 'keyword').includes('return'), true);
eq('python: None 常量', textOfKind(py, 'constant').includes('None'), true);

const sh = hl.tokenizeCode('echo "hi" # 注释', 'bash');
eq('shell: echo 视为关键字', textOfKind(sh, 'keyword').includes('echo'), true);
eq('shell: # 注释', textOfKind(sh, 'comment').join(''), '# 注释');

const sql = hl.tokenizeCode('SELECT id FROM t -- 注释', 'sql');
eq('sql: 大写关键字命中（SQL 大小写不敏感）', textOfKind(sql, 'keyword').includes('SELECT'), true);
eq('sql: 小写关键字同样命中', textOfKind(hl.tokenizeCode('select 1', 'sql'), 'keyword').includes('select'), true);
eq('sql: 类型也大小写不敏感', textOfKind(hl.tokenizeCode('CAST(x AS INTEGER)', 'sql'), 'type').includes('INTEGER'), true);
eq('其它语言关键字区分大小写（IF 不算关键字）', textOfKind(hl.tokenizeCode('IF', 'ts'), 'keyword').includes('IF'), false);

const json = hl.tokenizeCode('{"a": 1, "b": true}', 'json');
eq('json: 键与值都是字符串', textOfKind(json, 'string').length, 2);
eq('json: true 为常量', textOfKind(json, 'constant').includes('true'), true);
eq('json: 数字', textOfKind(json, 'number').includes('1'), true);

const diff = hl.tokenizeCode('-old line\n+new line\n@@ hunk @@', 'diff');
eq('diff: 减号行', diff[0].kind, 'keyword');
eq('diff: 加号行', diff[2].kind, 'string');
eq('diff: hunk 头', diff[4].kind, 'comment');

const yaml = hl.tokenizeCode('key: value\nflag: true # 注', 'yaml');
eq('yaml: true 为常量', textOfKind(yaml, 'constant').includes('true'), true);
eq('yaml: # 注释', textOfKind(yaml, 'comment').join(''), '# 注');

const unknown = hl.tokenizeCode('foo(1) // c', 'whatever');
eq('未知语言仍走通用档（能切出注释）', textOfKind(unknown, 'comment').join(''), '// c');
eq('未知语言仍能切出函数', textOfKind(unknown, 'function').includes('foo'), true);

const mdBlock = hl.tokenizeCode('# 标题\n> 引用\n- 项', 'markdown');
eq('markdown 块：标题', mdBlock[0].kind, 'keyword');
eq('markdown 块：引用', mdBlock[2].kind, 'comment');
eq('markdown 块：列表', mdBlock[4].kind, 'punctuation');

check('高亮不改变文本内容（拼接后与原文一致）',
  flat(hl.tokenizeCode('a = "x" + 1 // c\n', 'ts')) === 'a = "x" + 1 // c\n');
check('空代码返回空数组', hl.tokenizeCode('', 'ts').length === 0);
check('大块代码可切分（性能冒烟）', hl.tokenizeCode(('const a = 1;\n').repeat(500), 'ts').length > 1000);

// R57 性能轮：语言档词表模块级缓存 —— 同一语言两次切词必须逐项相等、关键字命中一致。
{
  const code = 'const n: number = 42; // 计数\ndoThing(1) + Thing';
  const first = hl.tokenizeCode(code, 'ts');
  const second = hl.tokenizeCode(code, 'ts');
  eq('词表缓存：同语言两次切词条数一致', second.length, first.length);
  let identical = first.length === second.length;
  for (let k = 0; k < first.length && identical; k++) {
    identical = first[k].text === second[k].text && first[k].kind === second[k].kind;
  }
  check('词表缓存：同语言两次切词逐项相等', identical);
  eq('词表缓存：关键字仍命中', textOfKind(second, 'keyword').includes('const'), true);
  // 大小写不敏感档（SQL）缓存后仍折叠
  eq('词表缓存：SQL 大写仍命中', textOfKind(hl.tokenizeCode('SELECT 1', 'sql'), 'keyword').includes('SELECT'), true);
  eq('词表缓存：SQL 小写仍命中', textOfKind(hl.tokenizeCode('select 1', 'sql'), 'keyword').includes('select'), true);
  // 别名归一化后走同一档（ts/typescript 共享缓存）
  const aliasA = hl.tokenizeCode('let x = 1;', 'ts');
  const aliasB = hl.tokenizeCode('let x = 1;', 'typescript');
  let aliasSame = aliasA.length === aliasB.length;
  for (let k = 0; k < aliasA.length && aliasSame; k++) {
    aliasSame = aliasA[k].text === aliasB[k].text && aliasA[k].kind === aliasB[k].kind;
  }
  check('词表缓存：别名 ts/typescript 结果一致', aliasSame);
}

group('文本可预览判定（model/TextFiles）');
eq('普通代码文件可预览', textFiles.isTextPreviewable('main.ts'), true);
eq('无扩展名的 Dockerfile 可预览', textFiles.isTextPreviewable('Dockerfile'), true);
eq('Makefile 可预览', textFiles.isTextPreviewable('Makefile'), true);
eq('LICENSE 可预览', textFiles.isTextPreviewable('LICENSE'), true);
eq('README（无扩展名）可预览', textFiles.isTextPreviewable('README'), true);
eq('.gitignore 可预览', textFiles.isTextPreviewable('.gitignore'), true);
eq('.env.local 可预览', textFiles.isTextPreviewable('.env.local'), true);
eq('patch 可预览（新补）', textFiles.isTextPreviewable('change.patch'), true);
eq('diff 可预览（新补）', textFiles.isTextPreviewable('x.diff'), true);
eq('csv 可预览', textFiles.isTextPreviewable('data.csv'), true);
eq('大小写不敏感', textFiles.isTextPreviewable('MAIN.TS'), true);
eq('带目录的路径只看文件名', textFiles.isTextPreviewable('src/deep/Util.py'), true);
eq('Windows 分隔符同样处理', textFiles.isTextPreviewable('src\deep\Util.py'), true);
eq('二进制不可预览', textFiles.isTextPreviewable('app.hap'), false);
eq('压缩包不可预览', textFiles.isTextPreviewable('release.zip'), false);
eq('点结尾不可预览', textFiles.isTextPreviewable('weird.'), false);
eq('空串不可预览', textFiles.isTextPreviewable(''), false);

group('远程路径判定（model/RemotePaths）');
// parentPath 基本形态
eq('父目录', remotePaths.parentPath('/a/b/c'), '/a/b');
eq('根斜杠的父级是 .', remotePaths.parentPath('/'), '.');
eq('点目录的父级是 .', remotePaths.parentPath('.'), '.');
eq('空串的父级是 .', remotePaths.parentPath(''), '.');
eq('相对路径父级', remotePaths.parentPath('src/deep'), 'src');
eq('Windows 分隔符同处理', remotePaths.parentPath('src\\deep'), 'src');

// isOutsideRoot：这是「在根目录点上一级会跑到工作区外」的判据
eq('根自身不算越界', remotePaths.isOutsideRoot('/Users/me/code/demo', '/Users/me/code/demo'), false);
eq('根下的子目录不算越界', remotePaths.isOutsideRoot('/Users/me/code/demo', '/Users/me/code/demo/src'), false);
eq('根的父级算越界', remotePaths.isOutsideRoot('/Users/me/code/demo', '/Users/me/code'), true);
eq('完全无关的绝对路径算越界', remotePaths.isOutsideRoot('/Users/me/code/demo', '/etc'), true);
eq('根为 . 时永不越界', remotePaths.isOutsideRoot('.', '/anything/at/all'), false);
eq('根为空串时永不越界', remotePaths.isOutsideRoot('', '/etc'), false);
eq('尾部斜杠不影响判定', remotePaths.isOutsideRoot('/a/b/', '/a/b/src/'), false);
eq('前缀相似但不同目录算越界', remotePaths.isOutsideRoot('/a/b', '/a/bc'), true);

// parentWithinRoot：把「上一级」收敛到根之内
eq('根目录上一级回到 .', remotePaths.parentWithinRoot('/Users/me/code/demo', '/Users/me/code/demo'), '.');
eq('子目录上一级正常', remotePaths.parentWithinRoot('/Users/me/code/demo/src', '/Users/me/code/demo'),
  '/Users/me/code/demo');
eq('孙子目录上一级到子目录', remotePaths.parentWithinRoot('/a/b/c', '/a/b'), '/a/b');
eq('根为 . 时沿用 parentPath', remotePaths.parentWithinRoot('src/deep', '.'), 'src');

group('Markdown 富块：表格 / 任务 / 分隔线 / 嵌套（ui/MarkdownParse）');
const tableMd = md.parseMarkdown(['| 模块 | 状态 | 备注 |', '| --- | :--: | --- |', '| 登录 | 完成 | 已复验 |', '| 终端 | 进行中 | 宽字符 |', '', '结尾段落'].join(String.fromCharCode(10)));
eq('表格识别为 table', tableMd[0].kind, 'table');
eq('表格行数（含表头）', tableMd[0].rows.length, 3);
eq('表头单元格', tableMd[0].rows[0].join('/'), '模块/状态/备注');
eq('表体第一行', tableMd[0].rows[1].join('/'), '登录/完成/已复验');
eq('表格后仍能解析段落', tableMd[1].kind, 'paragraph');
eq('表格后段落文本', tableMd[1].text, '结尾段落');

const noTable = md.parseMarkdown(['| 这不是表格 |', '| 因为没有分隔行 |'].join(String.fromCharCode(10)));
eq('缺分隔行不识别为表格', noTable[0].kind, 'paragraph');

const tasks = md.parseMarkdown(['- [x] 已完成项', '- [ ] 待办项', '- 普通项'].join(String.fromCharCode(10)));
eq('任务项', tasks[0].kind, 'task');
eq('勾选状态 true', tasks[0].checked, true);
eq('勾选项文本', tasks[0].text, '已完成项');
eq('未勾选状态 false', tasks[1].checked, false);
eq('未勾选项文本', tasks[1].text, '待办项');
eq('普通无序项不受影响', tasks[2].kind, 'bullet');

const nested = md.parseMarkdown(['- 一级', '  - 二级', '    - 三级', '- 回到一级'].join(String.fromCharCode(10)));
eq('嵌套层级 0', nested[0].level, 0);
eq('嵌套层级 1', nested[1].level, 1);
eq('嵌套层级 2', nested[2].level, 2);
eq('回到一级', nested[3].level, 0);
eq('嵌套有序项层级', md.parseMarkdown(['1. 一', '  1. 二'].join(String.fromCharCode(10)))[1].level, 1);

const rules = md.parseMarkdown(['上一段', '', '---', '', '下一段'].join(String.fromCharCode(10)));
eq('分隔线识别为 rule', rules[1].kind, 'rule');
eq('星号分隔线', md.parseMarkdown('***')[0].kind, 'rule');
eq('下划线分隔线', md.parseMarkdown('___')[0].kind, 'rule');
eq('两连字符不是分隔线', md.parseMarkdown('--')[0].kind, 'paragraph');

const linkTokens = md.parseInline(['见 [文档](https://example.com/a) 与 **重点**'].join(String.fromCharCode(10)));
const linkToken = linkTokens.filter((t) => t.link !== undefined);
eq('链接分片数', linkToken.length, 1);
eq('链接文字', linkToken[0].text, '文档');
eq('链接地址', linkToken[0].link, 'https://example.com/a');
eq('链接之后的粗体仍被解析', linkTokens.filter((t) => t.bold === true).length, 1);
eq('方括号无地址时不当链接', md.parseInline('[不是链接] 文本').filter((t) => t.link !== undefined).length, 0);
eq('链接纯文本化', md.plainText('见 [文档](https://example.com/a)'), '见 文档');

group('按文件名猜语言（ui/SyntaxHighlight · 文件预览用）');
eq('Main.kt → jvm', hl.languageFromFileName('Main.kt'), 'jvm');
eq('index.ts → typescript', hl.languageFromFileName('index.ts'), 'typescript');
eq('app.ets → typescript', hl.languageFromFileName('app.ets'), 'typescript');
eq('run.sh → shell', hl.languageFromFileName('run.sh'), 'shell');
eq('conf.yaml → yaml', hl.languageFromFileName('conf.yaml'), 'yaml');
eq('query.SQL 大小写不敏感 → sql', hl.languageFromFileName('query.SQL'), 'sql');
eq('README.md → markdown', hl.languageFromFileName('README.md'), 'markdown');
eq('change.patch → diff', hl.languageFromFileName('change.patch'), 'diff');
eq('Dockerfile（无扩展名，按名字）→ shell', hl.languageFromFileName('Dockerfile'), 'shell');
eq('Makefile → shell', hl.languageFromFileName('Makefile'), 'shell');
eq('package.json → json', hl.languageFromFileName('package.json'), 'json');
eq('带目录的路径只看文件名', hl.languageFromFileName('src/deep/util.py'), 'python');
eq('.gitignore（dotfile）→ shell', hl.languageFromFileName('.gitignore'), 'shell');
eq('无扩展名的普通文件 → generic', hl.languageFromFileName('LICENSE'), 'generic');
eq('以点结尾 → generic', hl.languageFromFileName('weird.'), 'generic');
eq('未知扩展名 → generic', hl.languageFromFileName('data.xyzzy'), 'generic');

group('纯 ArkTS SHA-256（utils/Sha256）');
const enc = (t) => sha.utf8Bytes(t);
eq('NIST: 空串', sha.sha256Hex(enc('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
eq('NIST: abc', sha.sha256Hex(enc('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
eq('NIST: 448-bit 消息', sha.sha256Hex(enc('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
  '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
eq('NIST: 896-bit 消息',
  sha.sha256Hex(enc('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu')),
  'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1');
eq('NIST: 一百万个 a', sha.sha256Hex(enc('a'.repeat(1000000))),
  'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
eq('UTF-8 中文', sha.sha256Hex(enc('中文')), '72726d8818f693066ceb69afa364218b692e62ea92b385782363780f47529c21');
eq('输出长度 64', sha.sha256Hex(enc('x')).length, 64);
eq('base64url 无填留', sha.base64UrlNoPadding(sha.sha256(enc('abc'))), 'ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0');

// ---------------------------------------------------------------------------
// 第八轮：会话「能不能发消息」的闸门（本轮核心缺陷，真机上极难造出全部组合）
// ---------------------------------------------------------------------------

group('只读态判定（model/SessionGating · isReadOnly）');
check('已加载 + 未接管 = 只读', gating.isReadOnly(true, false) === true);
check('已加载 + 已接管 ≠ 只读', gating.isReadOnly(true, true) === false);
// 会话还没拉出来时不能闪一下只读（否则进页面瞬间输入框会先灰一下）
check('未加载（会话为 undefined）≠ 只读', gating.isReadOnly(false, false) === false);

group('有效运行时状态回落（effectiveRuntimeStatus）');
eq('runtime 明确时优先用 runtime', gating.effectiveRuntimeStatus('running', 'idle'), 'running');
eq('runtime 为 unknown 时回落会话状态', gating.effectiveRuntimeStatus('unknown', 'running'), 'running');
eq('runtime 为空串时回落会话状态', gating.effectiveRuntimeStatus('', 'pending'), 'pending');
eq('两边都空 → unknown', gating.effectiveRuntimeStatus('', ''), 'unknown');

group('活动态集合（isActiveRuntimeStatus）');
for (const s of ['waiting', 'pending', 'running', 'stopping', 'waiting_approval', 'blocked']) {
  check(`${s} 属于活动态`, gating.isActiveRuntimeStatus(s) === true);
}
for (const s of ['idle', 'error', 'disconnected', 'unknown']) {
  check(`${s} 不属于活动态`, gating.isActiveRuntimeStatus(s) === false);
}

group('能力闸门（capabilityBlocked）');
// ⚠️ 名字不能叫 `caps`：上面 DTO 归一化那一段已经用 `caps` 存过 `parseCapabilitySet` 的结果。
const capRows = (rows) => rows.map(([capabilityId, ok]) => ({
  capabilityId,
  supported: ok,
  available: ok,
  allowed: ok
}));
// ⚠️ 最要紧的一条：空能力表 = "未知" 而不是 "禁止"。
// 若按严格版实现（没这条就是不可用），空表服务端上所有会话都会永久不可发消息。
check('空能力表 → 不拦（未知≠禁止）',
  gating.capabilityBlocked(capRows([]), gating.CAP_SEND_MESSAGE) === false);
check('显式 allowed=true → 不拦',
  gating.capabilityBlocked(capRows([['session.send_message', true]]), gating.CAP_SEND_MESSAGE) === false);
check('显式 allowed=false → 拦',
  gating.capabilityBlocked(capRows([['session.send_message', false]]), gating.CAP_SEND_MESSAGE) === true);
check('只禁 send 不影响 steer 判定',
  gating.capabilityBlocked(capRows([['session.send_message', false]]), gating.CAP_STEER) === false);
check('capabilities 里没有这条 → 不拦',
  gating.capabilityBlocked(capRows([['session.interrupt', true]]), gating.CAP_SEND_MESSAGE) === false);

group('发送动作路由（messageActionFor）');
const noCaps = capRows([]);
eq('未接管 → none（本地就拦住，不发出去吃 409）',
  gating.messageActionFor(true, false, noCaps, 'idle', 'idle'), 'none');
eq('空闲 + 能力未知 → send',
  gating.messageActionFor(true, true, noCaps, 'idle', 'idle'), 'send');
eq('运行中 → steer（服务端 messages 此时会 409）',
  gating.messageActionFor(true, true, noCaps, 'running', 'running'), 'steer');
eq('排队中 → steer（属活动态）',
  gating.messageActionFor(true, true, noCaps, 'pending', 'pending'), 'steer');
// 这一条是修掉的老 bug：stopping/waiting_approval/blocked 原先被判成"空闲"走 messages，
// 而服务端 messages 只放行 idle|error（session_run.py L402），必然 409。
eq('停止中 → steer（老实现会误走 messages）',
  gating.messageActionFor(true, true, noCaps, 'stopping', 'stopping'), 'steer');
eq('待审批 → steer（老实现会误走 messages）',
  gating.messageActionFor(true, true, noCaps, 'waiting_approval', 'waiting_approval'), 'steer');
eq('阻塞 → steer（老实现会误走 messages）',
  gating.messageActionFor(true, true, noCaps, 'blocked', 'blocked'), 'steer');
eq('出错 → send（服务端 messages 放行 error）',
  gating.messageActionFor(true, true, noCaps, 'error', 'error'), 'send');
eq('会话说 busy 但运行时已 idle → send（回落生效）',
  gating.messageActionFor(true, true, noCaps, 'unknown', 'idle'), 'send');
eq('send 被禁但 steer 可用 → steer',
  gating.messageActionFor(true, true, capRows([['session.send_message', false], ['session.steer', true]]),
    'idle', 'idle'), 'steer');
eq('两个能力都被禁 → none',
  gating.messageActionFor(true, true, capRows([['session.send_message', false], ['session.steer', false]]),
    'idle', 'idle'), 'none');
eq('只读态优先于一切（运行中也不算 steer）',
  gating.messageActionFor(true, false, noCaps, 'running', 'running'), 'none');

group('输入区占位文案（composerPlaceholder）');
// ⚠️ R9 起各分支文案**逐字取上游** values-zh-rCN/strings.xml，断言跟着换成新文案里的等价
// 关键词（保留原意：运行中要提「中断/等待」、不可用要说「不可发送」、默认是「回复 X」）。
// 输入区文案的完整用例见 tools/logic-test/suite-composer.mjs。
const facts = (over) => Object.assign({
  loaded: true,
  takeover: true,
  connectorOnline: true,
  hasNotices: false,
  runtimeReason: '',
  runtimeStatus: 'idle',
  sessionStatus: 'idle',
  action: 'send',
  replyTarget: 'Agent'
}, over);
check('只读态给出「怎么才能发」的出路',
  gating.composerPlaceholder(facts({ takeover: false })).includes('接管'));
check('未加载时不显示只读文案',
  gating.composerPlaceholder(facts({ loaded: false, takeover: false })).includes('接管') === false);
check('设备离线有专门文案',
  gating.composerPlaceholder(facts({ connectorOnline: false })).includes('离线'));
check('待审批有专门文案',
  gating.composerPlaceholder(facts({ hasNotices: true })).includes('交互'));
check('运行时错误原因被透出来',
  gating.composerPlaceholder(facts({ runtimeReason: '等待本地 DSH Bridge' })) === '等待本地 DSH Bridge');
check('运行中提示发送中断或等当前回合',
  gating.composerPlaceholder(facts({ runtimeStatus: 'running' })).includes('中断'));
check('能力不可用时不谎称可以发',
  gating.composerPlaceholder(facts({ action: 'none' })).includes('不可发送'));
eq('一切正常 → 默认文案',
  gating.composerPlaceholder(facts({})), '回复 Agent');
// 优先级：只读 > 设备离线（上游顺序，不能颠倒）
check('只读优先于设备离线',
  gating.composerPlaceholder(facts({ takeover: false, connectorOnline: false })).includes('接管'));

group('新建会话的运行时可用性（runtimeIsReady / runtimeIsSettling）');
check('configured+active+running → 可用', gating.runtimeIsReady(true, true, 'running') === true);
// 真机实测的失败路径：active 但停在 starting，服务端会放行到 Connector 再报
// 「runtime instance 'rti_…' is not running (status='starting')」。
check('active 但 starting → 不可用（真机踩过的那个）',
  gating.runtimeIsReady(true, true, 'starting') === false);
check('未 active → 不可用', gating.runtimeIsReady(true, false, 'running') === false);
check('未 configured → 不可用', gating.runtimeIsReady(false, true, 'running') === false);
check('error 态 → 不可用', gating.runtimeIsReady(true, true, 'error') === false);
check('stopped 态 → 不可用', gating.runtimeIsReady(true, true, 'stopped') === false);
check('starting 属过渡态（值得轮询）', gating.runtimeIsSettling(true, 'starting') === true);
check('validating 属过渡态', gating.runtimeIsSettling(true, 'validating') === true);
check('running 不属过渡态（轮询该停）', gating.runtimeIsSettling(true, 'running') === false);
check('未 active 的 stopped 不属过渡态', gating.runtimeIsSettling(false, 'stopped') === false);

group('运行时原因文案（runtimeReasonText）');
check('优先 error.message', gating.runtimeReasonText('等待本地 DSH Bridge', 'runtime_unavailable', '发现原因')
  === '等待本地 DSH Bridge');
check('无 message 时退回 error.code',
  gating.runtimeReasonText('', 'runtime_unavailable', '发现原因') === 'runtime_unavailable');
check('无 error 时退回 discovery.reason',
  gating.runtimeReasonText('', '', '请启动 DSH，并启用手机连接插件。') === '请启动 DSH，并启用手机连接插件。');
check('三者皆空 → 空串（调用方走兜底文案）', gating.runtimeReasonText('', '', '') === '');
// DSH 实际的「启动中」文案（connector/runtimes/dsh/runtime.py L83/L92）要能原样透出，
// 否则用户看到的就只是「稍候会自动出现在这里」，拿不到「去启 DSH 插件」这条线索。
check('DSH 同步中文案可透出',
  gating.runtimeReasonText('正在连接 DSH 并同步会话…', 'runtime_initializing', '').startsWith('正在连接 DSH'));
check('DSH 等 Bridge 文案可透出',
  gating.runtimeReasonText('正在等待本地 DSH Bridge；请启动 DSH 并启用手机连接插件。', '', '')
    .includes('启用手机连接插件'));

group('顶层终端/文件页的设备选择（sortDevicesForPage / onlineDevices / pickDefaultDeviceId）');
// 纯逻辑区在 UI 文件里（TerminalScreen.ets 的 AA-DEVICE-PURE 标记段），两页共用同一份实现
const devicePolicy = load('ui/screens/TerminalDevice.js');
const deviceFixture = [
  { id: 'd-offline-late', name: 'Zeta', online: false, createdAt: '2026-09-02T00:00:00Z' },
  { id: 'd-online-b', name: 'beta', online: true, createdAt: '2026-09-02T00:00:00Z' },
  { id: 'd-online-a', name: 'Alpha', online: true, createdAt: '2026-09-01T00:00:00Z' },
  { id: 'd-offline-early', name: 'aaa', online: false, createdAt: '2026-08-31T00:00:00Z' }
];
const sortedDevices = devicePolicy.sortDevicesForPage(deviceFixture);
check('排序：在线设备排在最前（上游 sortedForDevicesPage 的第一关键字）',
  sortedDevices[0].online === true && sortedDevices[1].online === true);
check('排序：同为在线时按 createdAt 升序', sortedDevices[0].id === 'd-online-a');
check('排序：离线组里 createdAt 早的在前', sortedDevices[2].id === 'd-offline-early');
check('排序：createdAt 相同时按 name（忽略大小写）', sortedDevices[1].id === 'd-online-b');
check('排序：返回副本，不原地改数组', deviceFixture[0].id === 'd-offline-late');
check('下拉只列在线设备（DevicePickerMenu 的 filter { it.online }）',
  devicePolicy.onlineDevices(deviceFixture).length === 2);
check('一台在线的都没有时下拉为空',
  devicePolicy.onlineDevices([{ id: 'x', name: 'x', online: false }]).length === 0);
check('路由带来的设备在线 → 沿用它（兼容设备详情 / 会话文件页的入口）',
  devicePolicy.pickDefaultDeviceId(deviceFixture, 'd-online-b') === 'd-online-b');
check('路由带来的设备已离线 → 退回第一个在线设备',
  devicePolicy.pickDefaultDeviceId(sortedDevices, 'd-offline-late') === 'd-online-a');
check('没带路由参数 → 第一个在线设备（首页快捷卡片入口）',
  devicePolicy.pickDefaultDeviceId(sortedDevices, '') === 'd-online-a');
// 契约：这个函数按**传入顺序**取第一个在线设备，排序由调用方（`syncDevices()`）先做 ——
// 页面里两处都是 `pickDefaultDeviceId(sortDevicesForPage(...), …)`，所以下面这条断言就是「忘了排序」的护栏。
check('传入顺序决定「第一个在线设备」（页面调用前已排序）',
  devicePolicy.pickDefaultDeviceId(deviceFixture, '') === 'd-online-b');
check('全离线 → 空串（界面走「先让一台设备上线」空态）',
  devicePolicy.pickDefaultDeviceId([{ id: 'x', name: 'x', online: false }], '') === '');
check('没有任何设备 → 空串（界面走「先配对一台设备」空态）',
  devicePolicy.pickDefaultDeviceId([], '') === '');

// ---------------------------------------------------------------------------

console.log(`\n通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('\n失败明细：');
  for (const f of failures) {
    console.log(`  ✗ ${f}`);
  }
  process.exit(1);
}
console.log('全部逻辑断言通过。');
