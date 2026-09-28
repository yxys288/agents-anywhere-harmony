#!/usr/bin/env node
/**
 * aa-hm 设备域纯逻辑自测（R8 · task-5：A1 配对 / A2 设备会话区 / A5 撤销令牌 / B4 Runtime 配置）。
 *
 * 只测 `feature/DeviceStore.ets` 里的**纯函数**（不经过任何 @kit / ArkUI 调用）。
 * 转译法照抄 `tools/logic-test/run-tests.mjs`：DevEco 自带的 TypeScript 把 .ets 转成 CJS，
 * 在 Node 里 require 后跑断言；产物落在系统临时目录（不污染工程目录）。
 *
 * DeviceStore 是页面级 store，它 import 了会话/服务组装层（那些要 @kit.NetworkKit）——
 * 这里给它们写最小替身（见 STUBS），被测的纯函数一行都不经过它们。
 *
 * 用法：
 *   node tools/logic-test/suite-device.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-device-logic');

/** 只挑不 import @kit / ArkUI 的模块（DeviceStore 的间接依赖由 STUBS 顶上）。 */
const LOGIC_FILES = [
  'model/Types.ets',
  'api/Parse.ets',
  'feature/DeviceStore.ets'
];

/** DeviceStore 里只有这两个 import 会拉进 @kit（preferences / http），用替身顶掉。 */
const STUBS = {
  'feature/AppServices.js': [
    '// 测试替身：真模块要 @kit.NetworkKit，Node 里加载不了。',
    'exports.AppServices = {',
    "  get() { throw new Error('logic-test stub: AppServices 在 Node 单测里不可用'); }",
    '};',
    ''
  ].join('\n'),
  'store/AuthSessionStore.js': [
    '// 测试替身：真模块读 preferences，这里只要求「不抛」。',
    'exports.readAccessToken = function () { return ""; };',
    'exports.readServerUrl = function () { return ""; };',
    ''
  ].join('\n')
};

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
  for (const rel of Object.keys(STUBS)) {
    const target = path.join(OUT_DIR, rel);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, STUBS[rel], 'utf8');
  }
}

// ---------------------------------------------------------------------------
// 断言（逐条打印 PASS / FAIL）
// ---------------------------------------------------------------------------

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    console.log(`PASS  ${name}`);
  } else {
    const line = detail === undefined ? name : `${name} — ${detail}`;
    failures.push(line);
    console.log(`FAIL  ${line}`);
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

const types = load('model/Types.js');
const dev = load('feature/DeviceStore.js');

/** 造一条够用的会话（纯函数只读 id / connectorId / archived / sortKey）。 */
function session(id, connectorId, archived, sortKey) {
  return {
    id: id,
    connectorId: connectorId,
    archived: archived,
    sortKey: sortKey === undefined ? '2026-09-20T00:00:00Z' : sortKey,
    title: `T-${id}`,
    statusLabel: '空闲',
    runtimeLabel: 'codex',
    updatedAtLabel: '刚刚',
    updatedSeq: 1
  };
}

// ---------------------------------------------------------------------------
// A1 配对码
// ---------------------------------------------------------------------------

group('A1 配对码规范化与校验');
eq('PAIR_CODE_LENGTH = 6', dev.PAIR_CODE_LENGTH, 6);
eq('去空白 + 大写', dev.normalizePairCode('  ab12cd '), 'AB12CD');
eq('已经是规范形态则不变', dev.normalizePairCode('6F3K2P'), '6F3K2P');
eq('空串报「请输入」', dev.pairCodeError(''), '请输入设备上显示的配对码。');
check('短于 6 位报长度', dev.pairCodeError('ABC').indexOf('6 位') >= 0);
check('长于 6 位报长度', dev.pairCodeError('ABCDEFG').indexOf('6 位') >= 0);
eq('正好 6 位通过', dev.pairCodeError('ABCDEF'), '');
eq('小写 6 位通过（已归一）', dev.pairCodeError('abc123'), '');
check('连字符判非法', dev.pairCodeError('ABC-12').indexOf('数字与大写字母') >= 0);
check('中文判非法（复制粘贴常见）', dev.pairCodeError('ABCDE中').indexOf('数字与大写字母') >= 0);
eq('canSubmitPairCode 通过', dev.canSubmitPairCode('ABCDEF'), true);
eq('canSubmitPairCode 拦截', dev.canSubmitPairCode('ABCDE'), false);

group('A1 错误码 → 文案映射');
const exPairing = new types.ApiException('invalid_pairing_code', 404, 'invalid_pairing_code');
const exNet = new types.ApiException('无法连接服务器', 0);
eq('apiErrorStatus 取到状态码', dev.apiErrorStatus(exPairing), 404);
eq('非 ApiException → -1', dev.apiErrorStatus(new Error('boom')), -1);
eq('apiErrorStatus 无状态码 → -1', dev.apiErrorStatus(new types.ApiException('x')), -1);
eq('apiErrorMessage 透出服务端消息', dev.apiErrorMessage(exPairing), 'invalid_pairing_code');
check('404 → 配对码无效/过期', dev.pairingErrorText(404, '').indexOf('配对码无效或已过期') >= 0);
check('409 → 已用过', dev.pairingErrorText(409, '').indexOf('已经用过') >= 0);
check('401 → 重新登录', dev.pairingErrorText(401, '').indexOf('重新登录') >= 0);
check('429 → 稍后重试', dev.pairingErrorText(429, '').indexOf('稍后重试') >= 0);
check('5xx → 服务端不可用', dev.pairingErrorText(503, '').indexOf('服务端暂时不可用') >= 0);
check('0 → 网络不可达', dev.pairingErrorText(0, '').indexOf('网络不可达') >= 0);
eq('未知状态码保留服务端消息', dev.pairingErrorText(-1, '服务端原话'), '服务端原话');
check('未知状态码且无消息时给兜底', dev.pairingErrorText(-1, '').length > 0);

group('A1 配对 / 启动命令拼接');
eq('https 默认端口省略', dev.pairingAddress('https://web.agents-anywhere.com'), 'web.agents-anywhere.com');
eq('显式 443 也省略', dev.pairingAddress('https://a.example.com:443'), 'a.example.com');
eq('非 443 端口保留', dev.pairingAddress('https://a.example.com:8443'), 'a.example.com:8443');
eq('http 局域网地址保留端口', dev.pairingAddress('http://192.168.1.10:8787/'), '192.168.1.10:8787');
eq('路径被丢掉', dev.pairingAddress('https://a.example.com/api/v2'), 'a.example.com');
eq('裸地址原样返回', dev.pairingAddress('192.168.1.10:8787'), '192.168.1.10:8787');
eq('空地址 → 空串', dev.pairingAddress('   '), '');
eq('配对命令', dev.pairingCommand('https://web.agents-anywhere.com'), 'uvx anywhere-cli pair web.agents-anywhere.com');
eq('令牌命令逐段拼接',
  dev.tokenCommand('https://a.example.com', 'dev-1', 'tok-1'),
  'uvx anywhere-cli start --server-url a.example.com --connector-id dev-1 --connector-token tok-1');
check('含空格的令牌被单引号包住',
  dev.tokenCommand('https://a.example.com', 'dev 1', 'tok-1').indexOf("--connector-id 'dev 1'") >= 0);

group('A1 随机设备名');
eq('同 seed 同名（可复现）', dev.randomPairingDeviceName(7), dev.randomPairingDeviceName(7));
check('形态是 adjective-noun', /^[a-z]+-[a-z]+$/.test(dev.randomPairingDeviceName(7)));
check('不同 seed 会给出不同名字',
  dev.randomPairingDeviceName(1) !== dev.randomPairingDeviceName(29));
check('seed 为负也能给出名字', dev.randomPairingDeviceName(-3).length > 0);

// ---------------------------------------------------------------------------
// A2 设备会话区
// ---------------------------------------------------------------------------

group('A2 设备会话筛选与排序');
const a1 = session('s-1', 'dev-1', false, '2026-09-20T10:00:00Z');
const a2 = session('s-2', 'dev-1', false, '2026-09-19T10:00:00Z');
const a3 = session('s-3', 'dev-1', true, '2026-09-18T10:00:00Z');
const other = session('s-9', 'dev-2', false, '2026-09-21T10:00:00Z');
const ids = (list) => list.map((item) => item.id);
eq('活跃档只给未归档', JSON.stringify(ids(dev.sessionsForDevice([a1, a2], [a3], 'dev-1', 'active'))),
  JSON.stringify(['s-1', 's-2']));
eq('已归档档只给归档的', JSON.stringify(ids(dev.sessionsForDevice([a1, a2], [a3], 'dev-1', 'archived'))),
  JSON.stringify(['s-3']));
eq('全部档给两条', JSON.stringify(ids(dev.sessionsForDevice([a1, a2], [a3], 'dev-1', 'all'))),
  JSON.stringify(['s-1', 's-2', 's-3']));
eq('别的设备的会话被排除', dev.sessionsForDevice([a1], [other], 'dev-1', 'all').length, 1);
eq('按 sortKey 倒序（最新在前）',
  dev.sessionsForDevice([a2, a1], [], 'dev-1', 'all')[0].id, 's-1');
eq('同一 id 出现两次只算一条',
  dev.sessionsForDevice([a1], [a1], 'dev-1', 'all').length, 1);
check('三档空态文案互不相同',
  dev.deviceSessionsEmptyText('active') !== dev.deviceSessionsEmptyText('archived') &&
  dev.deviceSessionsEmptyText('archived') !== dev.deviceSessionsEmptyText('all'));

group('A2 批量归档目标计算');
const activeSessions = [a1, a2];
const archivedSessions = [a3];
const allSessions = [a1, a2, a3];
eq('选中里有未归档 → 目标是归档', dev.selectionTargetArchived(allSessions, ['s-3', 's-1']), true);
eq('选中全是已归档 → 目标是取消归档', dev.selectionTargetArchived(allSessions, ['s-3']), false);
eq('空选中 → 取消归档（按钮本来就不可点）', dev.selectionTargetArchived(allSessions, []), false);
eq('归档所选文案', dev.bulkActionLabel(activeSessions, ['s-1']), '归档所选');
eq('取消归档所选文案', dev.bulkActionLabel(archivedSessions, ['s-3']), '取消归档所选');
eq('只需发变化的 id（归档）',
  JSON.stringify(dev.archiveTargetIds(allSessions, ['s-1', 's-3'], true)), JSON.stringify(['s-1']));
eq('只需发变化的 id（取消归档）',
  JSON.stringify(dev.archiveTargetIds(allSessions, ['s-1', 's-3'], false)), JSON.stringify(['s-3']));
eq('全都已是目标状态 → 空数组（不发请求）',
  dev.archiveTargetIds(allSessions, ['s-3'], true).length, 0);

group('A2 选择集合切换');
eq('勾上一条', JSON.stringify(dev.toggleSelected([], 's-1')), JSON.stringify(['s-1']));
eq('再点一次取消', JSON.stringify(dev.toggleSelected(['s-1'], 's-1')), JSON.stringify([]));
const before = ['s-1'];
const afterToggle = dev.toggleSelected(before, 's-2');
eq('原数组不被改动（@State 必须换引用）', JSON.stringify(before), JSON.stringify(['s-1']));
eq('返回的是新数组', JSON.stringify(afterToggle), JSON.stringify(['s-1', 's-2']));
eq('未全选 → 全选', JSON.stringify(dev.toggleSelectAll(['s-1', 's-2'], ['s-1'])), JSON.stringify(['s-1', 's-2']));
eq('全选后再点 → 清空', JSON.stringify(dev.toggleSelectAll(['s-1', 's-2'], ['s-1', 's-2'])), JSON.stringify([]));
eq('空列表不误判成全选', JSON.stringify(dev.toggleSelectAll([], [])), JSON.stringify([]));

group('A2 全部归档文案');
eq('作用域：活跃', dev.archiveScopeLabel('active'), '所有活跃会话');
eq('作用域：已归档', dev.archiveScopeLabel('archived'), '所有已归档会话');
eq('作用域：全部', dev.archiveScopeLabel('all'), '所有会话');
eq('归档标题', dev.archiveAllTitle(true, 'active'), '归档这台设备上的所有活跃会话？');
eq('取消归档标题', dev.archiveAllTitle(false, 'archived'), '取消归档这台设备上的所有已归档会话？');
check('正文带设备名', dev.archiveAllBody('MyPC', true).indexOf('MyPC') >= 0);
check('取消归档正文说明会移回活跃', dev.archiveAllBody('MyPC', false).indexOf('移回活跃') >= 0);
eq('确认按钮：归档', dev.archiveAllConfirmLabel(true), '归档全部');
eq('确认按钮：取消归档', dev.archiveAllConfirmLabel(false), '取消归档全部');

// ---------------------------------------------------------------------------
// A5 撤销令牌确认状态机
// ---------------------------------------------------------------------------

group('A5 撤销令牌确认状态机');
eq('IDLE + request → 弹确认', dev.confirmNext('idle', 'request'), 'confirming');
eq('IDLE + 别的 → 仍是 IDLE', dev.confirmNext('idle', 'cancel'), 'idle');
eq('CONFIRMING + cancel → 回到 IDLE', dev.confirmNext('confirming', 'cancel'), 'idle');
eq('CONFIRMING + confirm → 请求在飞', dev.confirmNext('confirming', 'confirm'), 'busy');
eq('BUSY + 再次 confirm → 仍是 BUSY（防重复提交）', dev.confirmNext('busy', 'confirm'), 'busy');
eq('BUSY + cancel → 仍是 BUSY（请求已发出，不许取消掉）', dev.confirmNext('busy', 'cancel'), 'busy');
eq('BUSY + settled → 完成', dev.confirmNext('busy', 'settled'), 'done');
eq('BUSY + failed → 退回确认态（可重试）', dev.confirmNext('busy', 'failed'), 'confirming');
eq('DONE + reset → 复位', dev.confirmNext('done', 'reset'), 'idle');
eq('DONE + request → 仍是 DONE（必须先 reset）', dev.confirmNext('done', 'request'), 'done');
eq('未知相位 + request → 弹确认（兜底）', dev.confirmNext('??', 'request'), 'confirming');
eq('确认框标题', dev.revokeConfirmTitle(), '撤销这台设备的令牌？');
check('确认框正文带设备名', dev.revokeConfirmBody('MyPC').indexOf('MyPC') >= 0);
check('确认框正文说明会断开', dev.revokeConfirmBody('MyPC').indexOf('断开连接') >= 0);
check('完成文案带设备名', dev.revokeDoneText('MyPC').indexOf('MyPC') >= 0);

// ---------------------------------------------------------------------------
// B4 Runtime 配置
// ---------------------------------------------------------------------------

group('B4 Runtime 配置草稿');
const schema = {
  properties: {
    executablePath: { type: 'string', default: '/usr/local/bin/codex' },
    environment: { type: 'object' }
  }
};
eq('schema 声明了 executablePath', dev.runtimeSupportsField(schema, 'executablePath'), true);
eq('schema 没声明的字段 → false', dev.runtimeSupportsField(schema, 'other'), false);
eq('没有 schema → false', dev.runtimeSupportsField(undefined, 'executablePath'), false);
const draft1 = dev.runtimeConfigDraft({ executablePath: '/opt/x' }, schema);
eq('config 里的路径优先', draft1.executablePath, '/opt/x');
const draft2 = dev.runtimeConfigDraft({}, schema);
eq('缺省时取 schema 默认值', draft2.executablePath, '/usr/local/bin/codex');
const draft3 = dev.runtimeConfigDraft({ environment: { FOO: 'bar', BAZ: null } }, schema);
eq('environment 解析出两条', draft3.environment.length, 2);
eq('字符串值 → 普通条目', draft3.environment[0].value, 'bar');
eq('字符串值 → unset=false', draft3.environment[0].unset, false);
eq('null 值 → unset=true（移除继承值）', draft3.environment[1].unset, true);
eq('unset 条目的值清空', draft3.environment[1].value, '');
eq('无 config 时环境变量为空', dev.runtimeConfigDraft(undefined, schema).environment.length, 0);

group('B4 环境变量校验');
eq('合法', dev.environmentError([{ name: 'PATH', value: '/a', unset: false }]), '');
check('空名报错', dev.environmentError([{ name: '  ', value: '', unset: false }]).indexOf('不能为空') >= 0);
check('含 = 报错', dev.environmentError([{ name: 'A=B', value: '', unset: false }]).indexOf('不能包含') >= 0);
check('重名报错', dev.environmentError([
  { name: 'A', value: '1', unset: false },
  { name: 'A', value: '2', unset: false }
]).indexOf('不能重复') >= 0);
eq('空列表合法', dev.environmentError([]), '');

group('B4 配置载荷');
const base = { unknownKey: 'keep', executablePath: '/old', environment: { A: '1' } };
const payload = dev.runtimeConfigPayload(
  base,
  { executablePath: '/new', environment: [{ name: 'B', value: '2', unset: false }] },
  true, true);
eq('保留不认识的字段', payload.unknownKey, 'keep');
eq('路径被新值覆盖', payload.executablePath, '/new');
eq('旧环境变量被整体替换', payload.environment.A, undefined);
eq('新环境变量写入', payload.environment.B, '2');
const payloadEmptyPath = dev.runtimeConfigPayload(
  base, { executablePath: '   ', environment: [] }, true, true);
eq('路径留空 → 该键被移除', payloadEmptyPath.executablePath, undefined);
eq('未知字段仍在', payloadEmptyPath.unknownKey, 'keep');
const payloadUnset = dev.runtimeConfigPayload(
  base, { executablePath: '', environment: [{ name: 'C', value: '', unset: true }] }, true, true);
eq('unset 条目写成 null（不是空串）', payloadUnset.environment.C, null);
check('序列化后确实是 JSON null', JSON.stringify(payloadUnset).indexOf('"C":null') >= 0);
const payloadUnsupported = dev.runtimeConfigPayload(base, { executablePath: '/x', environment: [] }, false, false);
eq('schema 不支持时不写路径', payloadUnsupported.executablePath, undefined);
eq('schema 不支持时不写环境变量', payloadUnsupported.environment, undefined);
eq('schema 不支持时也不丢未知字段', payloadUnsupported.unknownKey, 'keep');


// ---------------------------------------------------------------------------
// R11 复刻新增：设备页（DevicesScreen）与配对向导步骤机
// ---------------------------------------------------------------------------

group('R11 设备页排序（sortedForDevicesPage）');
const device = (id, name, online, createdAt) => ({
  id: id, name: name, online: online, deviceOs: 'linux', lastSeenAt: undefined,
  createdAt: createdAt
});
const d1 = device('d1', 'beta', true, '2026-09-02T00:00:00Z');
const d2 = device('d2', 'Alpha', true, '2026-09-01T00:00:00Z');
const d3 = device('d3', 'gamma', false, '2026-08-01T00:00:00Z');
const ordered = dev.sortedForDevicesPage([d3, d1, d2]);
eq('在线优先（离线沉到最后）', ordered[2].id, 'd3');
eq('在线之间按 createdAt 升序', ordered[0].id, 'd2');
eq('createdAt 相同再看名称（忽略大小写）',
  dev.sortedForDevicesPage([device('x', 'b', true, '2026-09-01T00:00:00Z'),
    device('y', 'A', true, '2026-09-01T00:00:00Z')])[0].id, 'y');
eq('缺 createdAt 当空串处理（排最前）',
  dev.sortedForDevicesPage([device('x', 'z', true, '2026-09-01T00:00:00Z'), device('y', 'z', true, undefined)])[0].id,
  'y');
const original = [d3, d1];
dev.sortedForDevicesPage(original);
eq('不改动入参数组', original[0].id, 'd3');

group('R11 Agent 预览文案与计数');
eq('离线 → 离线', dev.deviceAgentPreviewLabel(false, 'loaded', 9), '离线');
eq('在线已加载 → N 个 Agent 在线', dev.deviceAgentPreviewLabel(true, 'loaded', 3), '3 个 Agent 在线');
eq('在线取不到 → Agent 状态不可用', dev.deviceAgentPreviewLabel(true, 'unavailable', 0), 'Agent 状态不可用');
eq('在线加载中 → 正在获取 Agent 状态...',
  dev.deviceAgentPreviewLabel(true, 'loading', 0), '正在获取 Agent 状态...');
eq('未传状态时按加载中处理', dev.deviceAgentPreviewLabel(true, 'none', 0), '正在获取 Agent 状态...');
const runtimeRow = (configured, active, status) => ({ configured: configured, active: active, status: status });
eq('已配置 + 已启用 + running 才算在线 Agent', dev.onlineAgentCount([
  runtimeRow(true, true, 'running'),
  runtimeRow(true, false, 'running'),
  runtimeRow(false, true, 'running'),
  runtimeRow(true, true, 'starting')
]), 1);
eq('空列表 → 0', dev.onlineAgentCount([]), 0);

group('R11 配对向导步骤机（previous）');
eq('命令 → 上一步是配对方式', dev.pairingPreviousStep('command'), 'cli_method');
eq('配对码 → 上一步是配对方式', dev.pairingPreviousStep('pair_code'), 'cli_method');
eq('配对方式 → 上一步是命名', dev.pairingPreviousStep('cli_method'), 'name');
eq('命名 → 上一步是连接方式', dev.pairingPreviousStep('name'), 'connection_method');
eq('桌面安装 → 上一步是连接方式', dev.pairingPreviousStep('desktop_install'), 'connection_method');
eq('命令行确认 → 上一步是连接方式', dev.pairingPreviousStep('cli_confirm'), 'connection_method');

group('R11 配对向导步骤机（落点与顶栏）');
eq('没凭据时点「配对码」→ 先落命名（先有名字才能往下）',
  dev.pairingStepTarget('pair_code', false), 'name');
eq('没凭据时点「令牌命令」→ 先落命名', dev.pairingStepTarget('command', false), 'name');
eq('有凭据时点「令牌命令」→ 直达', dev.pairingStepTarget('command', true), 'command');
eq('有凭据时点「配对码」→ 直达', dev.pairingStepTarget('pair_code', true), 'pair_code');
eq('命名步不受影响', dev.pairingStepTarget('name', false), 'name');
eq('第一步不画关闭钮（用 40dp 占位）', dev.pairingShowsCloseButton('connection_method'), false);
eq('命名步画关闭钮', dev.pairingShowsCloseButton('name'), true);
eq('配对码步画关闭钮', dev.pairingShowsCloseButton('pair_code'), true);

group('R11 配对向导底部动作');
eq('命名步：空名不可点', dev.pairingPrimaryEnabled('name', '   ', ''), false);
eq('命名步：有名字可点', dev.pairingPrimaryEnabled('name', 'amber-finch', ''), true);
eq('配对码步：6 位可点', dev.pairingPrimaryEnabled('pair_code', 'x', '123456'), true);
eq('配对码步：不足 6 位不可点', dev.pairingPrimaryEnabled('pair_code', 'x', '12345'), false);
eq('连接方式步没有主按钮（返回空串）', dev.pairingPrimaryLabel('connection_method'), '');
eq('命名步主按钮文案', dev.pairingPrimaryLabel('name'), '继续');
eq('配对码步主按钮文案', dev.pairingPrimaryLabel('pair_code'), '认领');
eq('桌面安装步主按钮文案', dev.pairingPrimaryLabel('desktop_install'), '完成');
eq('命令行确认步主按钮文案', dev.pairingPrimaryLabel('cli_confirm'), '继续使用命令行');
eq('步骤常量：连接方式', dev.PairingStep.CONNECTION_METHOD, 'connection_method');
eq('步骤常量：配对码', dev.PairingStep.PAIR_CODE, 'pair_code');
// ---------------------------------------------------------------------------
// R13-12：F-4 配对向导外链图标 + F-2 主按钮（StartChatButton）形态
// ---------------------------------------------------------------------------

const ADD_DEVICE = path.join(SRC_ETS, 'ui', 'screens', 'AddDeviceScreen.ets');
const NEW_SESSION = path.join(SRC_ETS, 'ui', 'screens', 'NewSessionScreen.ets');
const ICON_ETS = path.join(SRC_ETS, 'ui', 'Icon.ets');
const addDeviceText = fs.readFileSync(ADD_DEVICE, 'utf8');
const newSessionText = fs.readFileSync(NEW_SESSION, 'utf8');
const iconText = fs.readFileSync(ICON_ETS, 'utf8');
group('F-4 配对向导「前往官网下载」外链图标');
// ICONS 表里那一行的形状：一个方框 + 从右上飞出的箭头（Lucide external-link）。
const externalLinkLine = iconText.split(String.fromCharCode(10))
  .filter((line) => line.indexOf("'external-link':") >= 0)[0];
check('ICONS 表里有 external-link 键', externalLinkLine !== undefined);
check('external-link 是「方框 + 外飞箭头」那一支（含方框段 M18 13v6a2 2… 与外飞段 M10 14 21 3）',
  externalLinkLine !== undefined
  && externalLinkLine.includes('M10 14 21 3')
  && externalLinkLine.includes('M15 3h6v6'));
check('actionButton 增加了 iconName 形参',
  addDeviceText.includes('actionButton(label: string, primary: boolean, interactive: boolean, loading: boolean, iconName: string)'));
check('桌面程序分支的下载按钮带 external-link（上游 icon = Lucide.ExternalLink）',
  addDeviceText.includes("this.actionButton('前往官网下载', false, true, false, 'external-link')"));
check('图标渲染在文字之后（上游 Spacer(8.dp) + Icon 在 Text 之后）',
  addDeviceText.indexOf('Text(label)') > 0
  && addDeviceText.indexOf('Text(label)') < addDeviceText.indexOf('d: ICONS[iconName]'));
check('图标尺寸走 17vp（上游 Modifier.size(17.dp)）',
  addDeviceText.includes('iconSize: FontSize.BUTTON_ICON'));
check('其余动作按钮都不带图标（上游只有 DesktopInstall 那一颗传了 icon）',
  addDeviceText.includes("this.actionButton('完成', true, true, false, '') ")
  || addDeviceText.includes("this.actionButton('完成', true, true, false, '')"));
check('图标走矢量 AaIcon（不再有字符图标）',
  addDeviceText.includes("import { AaIcon, ICONS } from '../Icon';"));

group('F-2 主按钮（上游 StartChatButton）');
check('禁用不透明度常量 = 0.45（上游 val alpha = if (enabled) 1f else 0.45f）',
  newSessionText.includes('START_BUTTON_DISABLED_ALPHA: number = 0.45'));
check('底色恒为主色、只有底色参与 alpha（Stack 底层 + opacity）',
  newSessionText.includes('.backgroundColor(primaryAction())')
  && newSessionText.includes('.opacity(this.canCreate() ? 1 : START_BUTTON_DISABLED_ALPHA)'));
check('不再用 subtle 浅灰做禁用底（上游没有这个形态）',
  newSessionText.includes("backgroundColor(this.canCreate() ? primaryAction() : subtle())") === false);
// 断言要**限定在主按钮这一段源码里**：整文件里别处仍有 `: muted()`（选型行等）。
// 取 `startButton() {` 到下一个 `@Builder` 之间的片段（锚文是函数名，不钉行号）。
const startBtnFrom = newSessionText.indexOf('startButton() {');
const startBtnTo = newSessionText.indexOf('@Builder', startBtnFrom + 1);
const startBtnText = startBtnFrom >= 0 && startBtnTo > startBtnFrom
  ? newSessionText.substring(startBtnFrom, startBtnTo)
  : '';
check('主按钮源码片段可定位（锚文 startButton() {）', startBtnText.length > 0);
// 旧实现的禁用文字色是 muted()；上游永远是 onPrimaryAction()。
check('文字色恒为 onPrimaryAction（上游永远白字，不随启用态变灰）',
  startBtnText.includes('.fontColor(onPrimaryAction())')
  && startBtnText.includes('muted()') === false);
check('主按钮带回上游同款箭头 ForwardGlyph（chevron-right，22vp）',
  newSessionText.includes("d: ICONS['chevron-right']")
  && newSessionText.includes('iconSize: START_BUTTON_GLYPH_SIZE'));
check('箭头线宽按 24 单位口径换算（3.2dp/22dp → 3.5）',
  newSessionText.includes('START_BUTTON_GLYPH_STROKE: number = 3.5'));
check('「首条消息为空」不再预先禁用按钮（上游 canStart 不含它）',
  newSessionText.includes('private submitBlocker()'));
check('该判定已从 blockReason 移出（点下去才报，与上游 validateNewSessionDraft 同位置）',
  newSessionText.indexOf('submitBlocker') > 0
  && newSessionText.indexOf('请填写首条消息') < 0);
// R47：这条文案已**本地化** —— 用户反馈「无法新建对话」，而它就是点「开始聊天」时唯一会看到的反馈，
// 中文用户看到英文串的第一反应就是「建不了」。裁决口径同 R41（可用性优先于逐字对照）。
check('错误文案已本地化（R47；原为上游英文内联串）',
  newSessionText.includes('请先填写首条消息（或添加一个附件）再开始。'));
check('新建项目不受首条消息约束（submit 里 projectOnly 先行返回）',
  newSessionText.indexOf('if (this.projectOnly) {') < newSessionText.indexOf('const blocked = this.submitBlocker();'));
check('首条消息输入框的 placeholder 未被改（= new_session_message_placeholder「描述第一个任务…」）',
  newSessionText.includes("placeholder: '描述第一个任务…'"));

// ---------------------------------------------------------------------------

console.log(`\n通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('\n失败明细：');
  for (const f of failures) {
    console.log(`  ✗ ${f}`);
  }
  process.exit(1);
}

group('R13-21 / 8-1：配对页顶部留白（Scroll 短内容被垂直居中）');
const addDeviceSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'AddDeviceScreen.ets'), 'utf8');
check('配对页滚动容器顶对齐（否则短内容居中，顶部多出 ~100vp 空白）',
  /\.scrollBar\(BarState\.Off\)[\s\S]*?\n\s*\.align\(Alignment\.Top\)/.test(addDeviceSource));
check('…该判据能被变异证伪（去掉 align 后不再成立）',
  /\.scrollBar\(BarState\.Off\)[\s\S]*?\n\s*\.align\(Alignment\.Top\)/
    .test(addDeviceSource.split('.align(Alignment.Top)').join('')) === false);

group('R28：配对「桌面程序」三步的间距与行高 = 上游');
// 上游 `DevicePairingSteps.kt:55-61`：`PairingStepHeading` + `Column(spacedBy(12.dp)) { 3 × PairingInstructionCard }`
//   —— 卡片之间是 **12dp**，而外层 `AddDeviceScreen.kt:190-191` 是 `spacedBy(20.dp)`。
//   `DevicePairingComponents.kt:89` 卡片标题是 `15.sp / lineHeight 21.sp`。
// ⚠️ R28 修前：三张卡平铺在外层 20dp 上（每步多 8dp）+ 标题缺行高（卡片矮 3dp）
//   ⇒ 实测步距 123.4dp，安卓基线 118dp；修后 118.9dp。
check('三张说明卡嵌在 Column({ space: 12 }) 里（上游 spacedBy(12.dp)）',
  /Column\(\{ space: 12 \}\) \{[\s\S]{0,900}?instructionCard\('下载并安装'/.test(addDeviceSource));
check('三张卡都在内层容器里（不再平铺在外层 spacedBy(20)）',
  (addDeviceSource.match(/this\.instructionCard\(/g) || []).length === 3
  && addDeviceSource.indexOf("instructionCard('下载并安装'") > addDeviceSource.indexOf('Column({ space: 12 }) {'));
check('说明卡标题补上 lineHeight 21（上游 lineHeight = 21.sp）',
  /instructionCard\(title: string, description: string\) \{[\s\S]{0,500}?\.lineHeight\(21\)/.test(addDeviceSource));

group('R33：设备详情会话行的相对时间 = 上游 ifBlank 兜底');
// 上游 `DeviceDetailScreen.kt:1039`：`session.updatedAtLabel.ifBlank { stringResource(R.string.common_now) }`
//   —— `common_now` =「刚刚」；`fontSize = 10.8.sp` / `FontFamily.Monospace` / SemiBold（本工程取 Medium）。
// ⚠️ R33 修前：本工程原样渲染空串 ⇒ 该位置留白。
const ddSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'DeviceDetailScreen.ets'), 'utf8');
const designSrcR33 = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8');
check('空值兜底「刚刚」（上游 ifBlank { common_now }）',
  ddSrc.includes("session.updatedAtLabel.length > 0 ? session.updatedAtLabel : '刚刚'"));
check('时间字号 = 10.8（上游 fontSize = 10.8.sp）', designSrcR33.includes('static readonly TIME: number = 10.8;'));
check('时间用等宽族（上游 FontFamily.Monospace）', ddSrc.includes(".fontFamily('Noto Sans Mono')"));

console.log('设备域逻辑断言全部通过。');
