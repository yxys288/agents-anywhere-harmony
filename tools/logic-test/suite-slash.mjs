#!/usr/bin/env node
/**
 * aa-hm「斜杠指令目录」的纯逻辑断言（R91 新增）。
 *
 * 被测代码：`model/SlashCommand.ets`（只 import 纯类型，可单独转译）。
 * 触发这轮改动的是用户诉求：「新建对话时也要能用斜杠指令（/goal /plan 等）」。
 *
 * 为什么需要这一套：本工程原先只有「已建会话」那条服务端指令通道
 * （`GET/POST /sessions/{id}/runtime/commands`，能力 `session.commands`），
 * 而该能力在现役 DSH 上**必然不可用**（bridge 补丁未打）⇒ 客户端必须有内置目录，
 * 且**执行语义必须按场景分派**：
 *   · 已建会话：`POST /runtime/commands`（DSH 的指令是服务调用，不进模型）；
 *   · 草稿态 / 新建会话页：作用于会话的指令（compact / export / file）**必须禁用** ——
 *     当首条消息发出去会被 DSH 当普通文本送进模型，用户以为压缩了其实没有
 *     （开发期验证记录里有明确警示）。
 *
 * 本套件锁住的就是上面这两条正确性口径，以及「回执不谎称已执行」这条措辞硬约束。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-slash.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-slash');
const LOGIC_FILES = ['model/SlashCommand.ets'];
const SRC_FILE = 'model/SlashCommand.ets';
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
const M = require(path.join(OUT_DIR, 'model/SlashCommand.js'));

/** 服务端条目夹具（形状对齐 `RemoteSessionCommand`；`tools/mock-server/server.mjs` 同款）。 */
function serverCommand(over) {
  const base = {
    id: 'compact', title: '/compact', description: 'Compact older conversation history',
    aliases: [], scope: 'session', enabled: true, acceptsArgs: false
  };
  return Object.assign(base, over === undefined ? {} : over);
}

const built = M.builtInCatalog();

group('① 内置清单（DSH 真实注册的 7 条，且不含 /help）');
eq('恰好 7 条', built.items.length, 7);
eq('id 顺序与 DSH 注册顺序一致', built.items.map((i) => i.id).join(','),
  'compact,export,file,feedback,goal,permission,plan');
eq('没有 /help（app.asar 里不存在该指令）', built.items.filter((i) => i.id === 'help').length, 0);
eq('全部 enabled', built.items.filter((i) => i.enabled !== true).length, 0);
eq('内置条目的 disabledReason 恒为空串', built.items.filter((i) => i.disabledReason.length > 0).length, 0);
eq('hint 逐字保留英文原文（goal）',
  M.findSlashCommand(built.items, 'goal').hint, '[<objective>|clear|edit <objective>|pause|resume]');
eq('无参数指令的 hint 为空串（compact）', M.findSlashCommand(built.items, 'compact').hint, '');
eq('需要参数的恰好 4 条', built.items.filter((i) => i.acceptsArgs).length, 4);
eq('作用于会话的恰好 3 条', built.items.filter((i) => i.sessionBound).length, 3);
check('isArgCommandId 与清单一致',
  built.items.every((i) => M.isArgCommandId(i.id) === i.acceptsArgs));
eq('builtInCatalog 来源是内置', built.source, M.SlashCommandSource.BUILT_IN);
eq('builtInCatalog 不声称服务端可用', built.serverAvailable, false);
eq('builtInCatalog 没有失败原因（草稿态本来就是内置）', built.serverError, '');

group('② 返回的是副本（调用方污染不了模块级常量）');
const first = M.builtInSlashCommands();
first[0].id = 'mutated';
first[0].aliases.push('x');
const second = M.builtInSlashCommands();
eq('改副本的 id 不影响下一次调用', second[0].id, 'compact');
eq('改副本的 aliases 不影响下一次调用', second[0].aliases.length, 0);

group('③ 草稿态可用性（compact/export/file 必须禁用）');
for (const id of ['compact', 'export', 'file']) {
  const item = M.findSlashCommand(built.items, id);
  check(id + ' 标记为作用于会话', item.sessionBound === true);
  eq(id + ' 草稿态不可用', M.slashCommandUsableInDraft(item), false);
  eq(id + ' 的禁用理由', M.draftCommandDisabledReason(item), '需要先建立会话后使用。');
}
for (const id of ['goal', 'plan', 'permission', 'feedback']) {
  const item = M.findSlashCommand(built.items, id);
  eq(id + ' 草稿态可用', M.slashCommandUsableInDraft(item), true);
  eq(id + ' 可用时没有禁用理由', M.draftCommandDisabledReason(item), '');
}
eq('草稿态可用条数 = 4', M.draftUsableCount(built.items), 4);
const disabledItem = serverCommand({ id: 'broken', enabled: false, disabledReason: '示例不可用' });
eq('enabled=false ⇒ 草稿态不可用', M.slashCommandUsableInDraft(M.slashCommandFromServer(disabledItem)), false);
eq('enabled=false 且服务端给了原因 ⇒ 用服务端原因',
  M.draftCommandDisabledReason(M.slashCommandFromServer(disabledItem)), '示例不可用');
eq('enabled=false 且没给原因 ⇒ 兜底文案',
  M.draftCommandDisabledReason(M.slashCommandFromServer(serverCommand({ id: 'x', enabled: false }))),
  '这条指令当前不可用。');

group('④ 插入语义（空草稿直接填、非空换行追加，绝不覆盖）');
eq('需要参数 ⇒ 带尾随空格', M.slashInsertionFor(M.findSlashCommand(built.items, 'goal')), '/goal ');
eq('不需要参数 ⇒ 不带空格', M.slashInsertionFor(M.findSlashCommand(built.items, 'compact')), '/compact');
const compact = M.findSlashCommand(built.items, 'compact');
const goal = M.findSlashCommand(built.items, 'goal');
eq('空草稿 ⇒ 直接填入', M.appendSlashToDraft('', M.slashInsertionFor(goal)), '/goal ');
eq('纯空白草稿 ⇒ 直接填入', M.appendSlashToDraft('   ' + String.fromCharCode(10), M.slashInsertionFor(goal)), '/goal ');
eq('有正文 ⇒ 换行追加，原文一字不丢',
  M.appendSlashToDraft('帮我看看登录', M.slashInsertionFor(goal)), '帮我看看登录' + NL + '/goal ');
eq('多行正文 ⇒ 去掉尾部空白再追加',
  M.appendSlashToDraft('a' + NL + 'b  ', '/plan'), 'a' + NL + 'b' + NL + '/plan');
check('追加结果一定包含用户原文',
  M.appendSlashToDraft('原有内容', '/compact').indexOf('原有内容') === 0);
check('非空草稿不会被覆盖（长度必然增加）',
  M.appendSlashToDraft('原有内容', '/compact').length > '原有内容'.length);

group('⑤ 手打指令行的拦截（draftTypedCommandBlocker）');
check('/compact 在草稿态被拦下', M.draftTypedCommandBlocker(built.items, '/compact').length > 0);
eq('/compact 的拦截理由', M.draftTypedCommandBlocker(built.items, '/compact'), '需要先建立会话后使用。');
check('/export 被拦下', M.draftTypedCommandBlocker(built.items, '/export').length > 0);
check('/file 被拦下', M.draftTypedCommandBlocker(built.items, '/file').length > 0);
eq('/goal 放行（意图类，可作为首条消息）', M.draftTypedCommandBlocker(built.items, '/goal 修好登录'), '');
eq('/plan 放行', M.draftTypedCommandBlocker(built.items, '/plan off'), '');
eq('/permission 放行', M.draftTypedCommandBlocker(built.items, '/permission fullAccess'), '');
eq('feedback 放行', M.draftTypedCommandBlocker(built.items, '/feedback 好用'), '');
eq('未知斜杠（/foobar）放行（可能是正文里的路径）', M.draftTypedCommandBlocker(built.items, '/foobar x'), '');
eq('普通文本放行', M.draftTypedCommandBlocker(built.items, '你好 /compact'), '');
eq('空串放行', M.draftTypedCommandBlocker(built.items, ''), '');
eq('单个斜杠放行（解析不出 id）', M.draftTypedCommandBlocker(built.items, '/'), '');

group('⑥ 解析边界（parseSlashCommandLine）');
const parsedCompact = M.parseSlashCommandLine('/compact');
eq('无参数：id', parsedCompact.id, 'compact');
eq('无参数：args 为空数组', parsedCompact.args.length, 0);
eq('无参数：raw 是整行', parsedCompact.raw, '/compact');
const parsedGoal = M.parseSlashCommandLine('/goal  修好 登录  ');
eq('带参数：id', parsedGoal.id, 'goal');
eq('带参数：多余空白收敛成 2 个参数', parsedGoal.args.join('|'), '修好|登录');
eq('带参数：raw 已 trim', parsedGoal.raw, '/goal  修好 登录');
eq('正文不以斜杠开头 ⇒ undefined', M.parseSlashCommandLine('你好 /goal'), undefined);
eq('空串 ⇒ undefined', M.parseSlashCommandLine(''), undefined);
eq('纯空白 ⇒ undefined', M.parseSlashCommandLine('   '), undefined);
eq('只有斜杠 ⇒ undefined（空 id）', M.parseSlashCommandLine('/'), undefined);
eq('斜杠 + 空白 ⇒ undefined（空 id）', M.parseSlashCommandLine('/   '), undefined);
const parsedUpper = M.parseSlashCommandLine('/Goal 目标');
eq('id 大小写原样保留（查表时才归一）', parsedUpper.id, 'Goal');
check('大小写不敏感查得到', M.findSlashCommand(built.items, 'Goal') !== undefined);
eq('查表：前后空白无所谓', M.findSlashCommand(built.items, '  compact  ').id, 'compact');
eq('查表：空串 ⇒ undefined', M.findSlashCommand(built.items, ''), undefined);
eq('查表：未知名 ⇒ undefined', M.findSlashCommand(built.items, 'nope'), undefined);

group('⑦ 目录来源标注（三态必须各不相同，且如实）');
eq('草稿态：明说服务端目录未请求',
  M.catalogSourceLabel(built, true), '内置指令目录（草稿态还没有会话，服务端目录未请求）');
eq('服务端可用：明说是服务端目录', M.catalogSourceLabel(M.serverCatalog([serverCommand()]), false), '服务端指令目录');
const down = M.unavailableCatalog('session capability is unavailable: session.commands');
check('不可用：明说是内置目录', M.catalogSourceLabel(down, false).indexOf('内置指令目录') >= 0);
check('不可用：带上服务端原话', M.catalogSourceLabel(down, false).indexOf('session.commands') >= 0);
check('不可用：写清是「通道不可用」', M.catalogSourceLabel(down, false).indexOf('服务端指令通道不可用') >= 0);
eq('三态文案互不相同', new Set([
  M.catalogSourceLabel(built, true),
  M.catalogSourceLabel(M.serverCatalog([serverCommand()]), false),
  M.catalogSourceLabel(down, false)
]).size, 3);

group('⑧ 服务端不可用时的回落（绝不能是空列表）');
check('回落条目非空', down.items.length > 0);
eq('回落 = 内置 7 条', down.items.length, 7);
eq('回落来源标为内置', down.source, M.SlashCommandSource.BUILT_IN);
eq('回落不声称服务端可用', down.serverAvailable, false);
eq('保留失败原因原文', down.serverError, 'session capability is unavailable: session.commands');
eq('无原因时也回落内置', M.unavailableCatalog('').items.length, 7);
eq('无原因时的来源文案', M.catalogSourceLabel(M.unavailableCatalog(''), false), '内置指令目录（服务端指令通道不可用）');

group('⑨ 服务端条目归一化（serverCatalog / slashCommandFromServer）');
const srv = M.serverCatalog([
  serverCommand({ id: 'compact', argsSchema: { hint: '压缩范围' } }),
  serverCommand({ id: 'zed', title: '/zed', description: undefined, aliases: ['z', 'ZED'], enabled: false, disabledReason: '示例不可用', acceptsArgs: true })
]);
eq('来源标为服务端', srv.source, M.SlashCommandSource.SERVER);
eq('声称服务端可用', srv.serverAvailable, true);
eq('服务端目录没有错误', srv.serverError, '');
eq('argsSchema.hint 被读出来', srv.items[0].hint, '压缩范围');
eq('compact 仍被判为作用于会话（判据是 id，不由服务端给）', srv.items[0].sessionBound, true);
eq('description 缺失 ⇒ 回落到 title', srv.items[1].description, '/zed');
eq('disabledReason 原样保留', srv.items[1].disabledReason, '示例不可用');
eq('enabled!==false 视为可用', srv.items[0].enabled, true);
eq('别名查得到（大写）', M.findSlashCommand(srv.items, 'Z').id, 'zed');
eq('无 argsSchema ⇒ hint 空串', srv.items[1].hint, '');
eq('argsSchema 里 hint 不是字符串 ⇒ 空串',
  M.slashCommandFromServer(serverCommand({ argsSchema: { hint: 123 } })).hint, '');
eq('空目录 ⇒ 空条目（服务端说了算，不硬塞内置）', M.serverCatalog([]).items.length, 0);

group('⑩ 回执措辞（草稿态绝不谎称「已执行」）');
check('草稿态（无参数）：不含「已执行」', M.draftSlashNotice(compact).indexOf('已执行') < 0);
check('草稿态（无参数）：写的是「已填入」', M.draftSlashNotice(compact).indexOf('已填入') >= 0);
check('草稿态（无参数）：说明会作为首条消息', M.draftSlashNotice(compact).indexOf('首条消息') >= 0);
check('草稿态（有参数 goal）：不含「已执行」', M.draftSlashNotice(goal).indexOf('已执行') < 0);
check('草稿态（有参数 goal）：带上参数提示', M.draftSlashNotice(goal).indexOf('参数：') >= 0);
check('草稿态（有参数 goal）：带上 DSH hint 原文',
  M.draftSlashNotice(goal).indexOf('[<objective>|clear|edit <objective>|pause|resume]') >= 0);
check('已建会话（无参数）：报「正在执行」', M.sessionSlashNotice(compact).indexOf('正在执行 /compact') >= 0);
check('已建会话（无参数）：不含「已执行」', M.sessionSlashNotice(compact).indexOf('已执行') < 0);
check('已建会话（有参数）：只填入、不声称执行', M.sessionSlashNotice(goal).indexOf('已填入 /goal') >= 0);
check('已建会话（有参数）：不含「已执行」', M.sessionSlashNotice(goal).indexOf('已执行') < 0);
check('草稿态回执与已建会话回执不是同一句话', M.draftSlashNotice(goal) !== M.sessionSlashNotice(goal));

group('⑪ 变异测试（把关键分支改坏必须变红）');
function mutate(replacements, name, shouldFail) {
  const source = fs.readFileSync(path.join(SRC_ETS, SRC_FILE), 'utf8');
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
  let broken = false;
  try { broken = shouldFail(Mut); } catch (error) { broken = true; }
  check(name + '：变异后行为确实变坏', broken === true);
}
mutate([['  return item.enabled && !item.sessionBound;', '  return item.enabled;']],
  '去掉草稿态的「作用于会话就禁用」守卫', (Mut) => {
    const it = Mut.findSlashCommand(Mut.builtInCatalog().items, 'compact');
    return Mut.slashCommandUsableInDraft(it) !== false;
  });
mutate([['  if (draft.trim().length === 0) {', '  if (false) {']],
  '插入不再区分空草稿（会覆盖/污染用户原文）', (Mut) => {
    return Mut.appendSlashToDraft('', '/goal ') !== '/goal ';
  });
mutate([['  const item = findSlashCommand(items, parsed.id);', '  const item = undefined;']],
  '手打指令行不再被识别（/compact 会漏放给模型）', (Mut) => {
    return Mut.draftTypedCommandBlocker(Mut.builtInCatalog().items, '/compact') === '';
  });
mutate([['    serverError: reason', "    serverError: ''"]],
  '不可用回落丢掉服务端原因', (Mut) => {
    return Mut.catalogSourceLabel(Mut.unavailableCatalog('boom'), false).indexOf('boom') < 0;
  });
mutate([['已填入', '已执行']],
  '草稿态回执谎称「已执行」', (Mut) => {
    const it = Mut.findSlashCommand(Mut.builtInCatalog().items, 'goal');
    return Mut.draftSlashNotice(it).indexOf('已执行') >= 0;
  });

if (failures.length > 0) {
  console.error('suite-slash: ' + failures.length + ' 条断言失败');
  for (const f of failures) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-slash: ' + passed + ' 条断言全绿（含 5 组变异测试）。');
