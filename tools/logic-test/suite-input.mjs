#!/usr/bin/env node
/**
 * aa-hm 输入链路纯逻辑自测（第八轮 task-3）。
 *
 * 覆盖三块**不依赖 ArkUI / @kit** 的逻辑：
 *  1. store/ComposerDraftStore.ets   —— 草稿编解码与存取策略（空草稿、损坏数据、会话隔离、后端降级）
 *     ＋ **恢复判定**（task-6 的 D1 回归：后端迟注入仍要读得回来、读过同一会话不重复读、
 *     后端未就绪时不许把会话记成「已恢复」）
 *  2. feature/AttachmentStore.ets    —— 上传体积上限判定（不必真的选文件也能断言）
 *  3. ui/screens/TerminalScreen.ets  —— 组合态守卫 + 「上屏文本 → 序列」映射
 *     （UI 文件本身进不了 Node，按源码里的 AA-PURE-LOGIC 标记把纯逻辑区切出来转译）
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-input.mjs
 * 产物全部落在系统临时目录（不污染工程目录）。
 */

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-input');

/** 需要转译的纯逻辑模块。依赖链上不能被 Node 解析的模块（AppServices / AuthSessionStore / Codec）用桩替换。 */
const LOGIC_FILES = [
  'vt/WcWidth.ets',
  'vt/TerminalStyle.ets',
  'vt/TerminalRow.ets',
  'vt/TerminalBuffer.ets',
  'vt/TerminalEmulator.ets',
  'vt/KeyHandler.ets',
  'model/Types.ets',
  'store/ComposerDraftStore.ets',
  'feature/AttachmentStore.ets'
];

/** 桩：这些模块要么依赖 @kit（preferences / util），要么是网络层，纯逻辑测试用不到。 */
const STUBS = [
  ['feature/AppServices.js', [
    "'use strict';",
    'exports.AppServices = {',
    '  get: function () {',
    "    throw new Error('stub: AppServices 不参与纯逻辑测试');",
    '  }',
    '};'
  ].join(String.fromCharCode(10))],
  ['store/AuthSessionStore.js', [
    "'use strict';",
    'exports.readAccessToken = function () { return ""; };',
    'exports.readServerUrl = function () { return ""; };'
  ].join(String.fromCharCode(10))],
  ['utils/Codec.js', [
    "'use strict';",
    'exports.base64Encode = function () { return ""; };',
    'exports.base64Decode = function () { return new Uint8Array(0); };'
  ].join(String.fromCharCode(10))]
];

const require0 = createRequire(import.meta.url);

function transpile(source, fileName) {
  const ts = require0(TS_PACKAGE);
  return ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
      removeComments: false
    },
    fileName: fileName
  }).outputText;
}

function writeModule(relative, source) {
  const target = path.join(OUT_DIR, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, source, 'utf8');
}

/** TerminalScreen.ets 的纯逻辑区：按标记切片（切片内不允许有 import / ArkUI 符号）。 */
const PURE_BEGIN = '// >>> AA-PURE-LOGIC-BEGIN';
const PURE_END = '// <<< AA-PURE-LOGIC-END';

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    writeModule(rel.replace(/\.ets$/, '.js'), transpile(source, rel));
  }
  for (const stub of STUBS) {
    writeModule(stub[0], stub[1]);
  }
  const termSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'TerminalScreen.ets'), 'utf8');
  const begin = termSource.indexOf(PURE_BEGIN);
  const end = termSource.indexOf(PURE_END);
  if (begin < 0 || end <= begin) {
    throw new Error('TerminalScreen.ets 里找不到纯逻辑标记（' + PURE_BEGIN + ' / ' + PURE_END + '）：标记被删或改名了？');
  }
  const slice = termSource.slice(begin + PURE_BEGIN.length, end);
  if (slice.indexOf('import ') >= 0) {
    throw new Error('TerminalScreen.ets 的纯逻辑区出现了 import —— 该区必须零依赖');
  }
  writeModule(path.join('ui', 'screens', 'TerminalInputPolicy.js'), transpile(slice, 'TerminalInputPolicy.ets'));
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
  console.log(String.fromCharCode(10) + '== ' + title);
}

/** 内存版持久化后端（模拟 preferences；store 侧只认 read/write/remove 三个函数）。 */
function memoryStorage() {
  const map = new Map();
  return {
    map: map,
    read: function (key) {
      const value = map.get(key);
      return value === undefined ? '' : value;
    },
    write: function (key, value) {
      map.set(key, value);
    },
    remove: function (key) {
      map.delete(key);
    }
  };
}

// ---------------------------------------------------------------------------

build();

const load = function (rel) {
  return require0(path.join(OUT_DIR, rel));
};

const draft = load('store/ComposerDraftStore.js');
const attachments = load('feature/AttachmentStore.js');
const keys = load('vt/KeyHandler.js');
const policy = load(path.join('ui', 'screens', 'TerminalInputPolicy.js'));

const ESC = String.fromCharCode(27);
const ENTER_TEXT = String.fromCharCode(13);
const CTRL_C = String.fromCharCode(3);

function flat(list) {
  return list.join('|');
}

function modState(ctrl, alt) {
  return { ctrl: ctrl, alt: alt };
}

group('草稿编解码（store/ComposerDraftStore）');
eq('偏好键带前缀', draft.draftKey('sess-1'), 'composer_draft:sess-1');
eq('空串算空草稿', draft.isDraftEmpty('', []), true);
eq('纯空白算空草稿', draft.isDraftEmpty('   ' + String.fromCharCode(10), []), true);
eq('有文本不算空', draft.isDraftEmpty('hi', []), false);
eq('只有附件也不算空', draft.isDraftEmpty('', [{ fileId: 'f1', name: 'a.txt' }]), false);
eq('空串解码为 undefined', draft.decodeDraft('') === undefined, true);
eq('坏 JSON 解码为 undefined', draft.decodeDraft('{不是 json') === undefined, true);
eq('纯文本记录可解出文本', draft.decodeDraft('{"text":"你好","attachments":[]}').text, '你好');
eq('纯空白记录解码为 undefined', draft.decodeDraft('{"text":"   "}') === undefined, true);
const messy = draft.decodeDraft('{"text":"x","attachments":[{"fileId":"f1","name":"报告.pdf"},{"name":"没有 id"},{"fileId":""},{"fileId":"f2"},{"fileId":"f3","name":""}]}');
eq('无 fileId 的附件被丢弃', messy.attachments.length, 3);
eq('缺 name 时用 fileId 兜底', messy.attachments[1].name, 'f2');
eq('空 name 时也用 fileId 兜底', messy.attachments[2].name, 'f3');
const roundTrip = draft.decodeDraft(draft.encodeDraft('要发的消息', [{ fileId: 'f9', name: '日志.txt' }]));
eq('编码再解码：文本一致', roundTrip.text, '要发的消息');
eq('编码再解码：附件一致', roundTrip.attachments[0].fileId + '/' + roundTrip.attachments[0].name, 'f9/日志.txt');
const emoji = draft.decodeDraft(draft.encodeDraft('中英混排 abcd 🚀', []));
eq('中文与 emoji 往返不丢', emoji.text, '中英混排 abcd 🚀');

group('草稿存取策略（会话隔离 / 清除 / 后端降级）');
const storageA = memoryStorage();
const storeA = new draft.ComposerDraftStore();
storeA.attachStorage(storageA);
storeA.save('s1', '草稿内容', [{ fileId: 'f1', name: '报告.pdf' }]);
eq('save 写进了后端', storageA.map.size, 1);
check('后端键就是带前缀的会话 id', storageA.map.has('composer_draft:s1'));
const storeB = new draft.ComposerDraftStore();
storeB.attachStorage(storageA);
const restored = storeB.restore('s1');
eq('新实例（模拟重启）读回文本', restored.text, '草稿内容');
eq('新实例读回附件数', restored.attachments.length, 1);
eq('新实例读回附件名', restored.attachments[0].name, '报告.pdf');
storeB.clear('s1');
eq('clear 删掉了后端记录', storageA.map.size, 0);
eq('clear 后恢复为空草稿', storeB.restore('s1').text, '');
storeA.save('sA', 'A 的内容', []);
storeA.save('sB', 'B 的内容', []);
eq('两个会话互不覆盖（A）', storeA.restore('sA').text, 'A 的内容');
eq('两个会话互不覆盖（B）', storeA.restore('sB').text, 'B 的内容');
storeA.save('sA', '   ', []);
eq('文本变空白即清除记录', storageA.map.has('composer_draft:sA'), false);
const storeC = new draft.ComposerDraftStore();
storeC.attachStorage(memoryStorage());
let threw = false;
storeC.save('s9', 'hello', []);
try {
  storeC.restore('s9');
} catch (error) {
  threw = true;
}
check('空会话 id / 正常写入都不抛异常', threw === false);
eq('无后端时草稿仍在本进程可用', storeC.restore('s9').text, 'hello');
const storeD = new draft.ComposerDraftStore();
const storageD = memoryStorage();
storageD.map.set('composer_draft:bad', '{截断的 json');
storeD.attachStorage(storageD);
eq('损坏记录按「没有草稿」处理', storeD.restore('bad').text, '');
const storageE = memoryStorage();
const storeE = new draft.ComposerDraftStore();
storeE.attachStorage(storageE);
storeE.attachStorage(memoryStorage());
storeE.save('s5', 'x', []);
eq('重复 attach 不换后端（幂等）', storeE.restore('s5').text, 'x');
eq('空 sessionId 不写后端', storageE.map.has('composer_draft:'), false);
eq('空 sessionId 读出空草稿', storeD.restore('').text, '');

group('草稿恢复判定（R8 冒烟 D1 回归：杀进程重启后不恢复）');
// 判定规则本身就是那次缺陷的产物：后端没就绪时必须「不读、也不锁定」，成功读过同一会话才跳过
eq('后端未就绪时不读（也不把会话记成已恢复）', draft.shouldRestoreDraft('s1', '', false), false);
eq('首次进入 / 二次进入（新实例 restoredFor 为空）都要读', draft.shouldRestoreDraft('s1', '', true), true);
eq('同一实例内重复 pull 不再读（免得覆盖用户刚敲进去的内容）', draft.shouldRestoreDraft('s1', 's1', true), false);
eq('切到另一个会话要读', draft.shouldRestoreDraft('s2', 's1', true), true);
eq('空会话 id 不读', draft.shouldRestoreDraft('', '', true), false);

// 迟注入时序：页面第一次 pull 发生在 attach 之前，正是 D1 的真实时序
const lateStore = new draft.ComposerDraftStore();
eq('未注入后端时 hasStorage 为 false', lateStore.hasStorage(), false);
const lateStorage = memoryStorage();
lateStorage.map.set('composer_draft:s-late', '{"text":"迟注入也要读回来","attachments":[]}');
eq('后端未就绪时 restore 只返回空草稿', lateStore.restore('s-late').text, '');
let lateRestoredFor = '';
if (draft.shouldRestoreDraft('s-late', lateRestoredFor, lateStore.hasStorage())) {
  lateRestoredFor = 's-late';
}
eq('后端未就绪的那一次不会把会话记成「已恢复」', lateRestoredFor, '');
lateStore.attachStorage(lateStorage);
eq('注入后端后 hasStorage 为 true', lateStore.hasStorage(), true);
let lateText = '';
if (draft.shouldRestoreDraft('s-late', lateRestoredFor, lateStore.hasStorage())) {
  lateRestoredFor = 's-late';
  lateText = lateStore.restore('s-late').text;
}
eq('迟注入之后仍能把草稿读回来', lateText, '迟注入也要读回来');
eq('读成之后同一会话不再重复读', draft.shouldRestoreDraft('s-late', lateRestoredFor, lateStore.hasStorage()), false);

// 杀进程重启的完整模拟：内存缓存随进程消失，只剩持久化后端里的字符串
const restartStorage = memoryStorage();
restartStorage.map.set('composer_draft:sess-mock-0001', '{"text":"draft-verify2","attachments":[]}');
const restartedStore = new draft.ComposerDraftStore();
restartedStore.attachStorage(restartStorage);
eq('重启后 hasStorage 为 true', restartedStore.hasStorage(), true);
eq('重启后读回上次没发出去的草稿', restartedStore.restore('sess-mock-0001').text, 'draft-verify2');

group('草稿恢复提示的显示条件（R8 第二轮复验：提示 6 帧 0 命中）');
// 显示条件 = 「当前草稿 === 恢复时的原文」，不是「显示过就置位」的开关：
// 开关会被「程序回填 text 触发的 onChange」清掉，比较式不会 —— 页面里没有任何一处把提示置空。
eq('恢复后未改动 → 显示提示', draft.shouldShowRestoredNotice('d1-fix-0920', 'd1-fix-0920'), true);
eq('用户自己输入的草稿 → 不显示（不能谎称「已恢复」）', draft.shouldShowRestoredNotice('用户打的字', ''), false);
eq('恢复后用户改过内容 → 提示消失', draft.shouldShowRestoredNotice('d1-fix-0920 追加', 'd1-fix-0920'), false);
eq('发送成功 / 用户清空 → 提示消失', draft.shouldShowRestoredNotice('', 'd1-fix-0920'), false);
eq('没有草稿的会话 → 不显示', draft.shouldShowRestoredNotice('', ''), false);
// 完整链路：恢复（snapshot 与 draft 同时赋值）→ 程序回填 → 用户输入 → 发送清空
let noticeSnapshot = 'd1-fix-0920';
let noticeDraft = 'd1-fix-0920';
eq('回填之后提示仍在（上一版就是丢在这一步）', draft.shouldShowRestoredNotice(noticeDraft, noticeSnapshot), true);
noticeDraft = 'd1-fix-0920x';
eq('用户追加字符后提示消失', draft.shouldShowRestoredNotice(noticeDraft, noticeSnapshot), false);
noticeDraft = 'd1-fix-0920';
eq('改回原样时又按「未改动」处理（罕见、无害）', draft.shouldShowRestoredNotice(noticeDraft, noticeSnapshot), true);
noticeDraft = '';
eq('发送成功清空草稿后提示消失', draft.shouldShowRestoredNotice(noticeDraft, noticeSnapshot), false);
// 快照为空 + 页面里已有文本（用户自己打的）绝不能被当成「已恢复」
eq('空快照 + 非空草稿 → 不显示', draft.shouldShowRestoredNotice('draft-verify2', ''), false);

group('附件上传体积上限（feature/AttachmentStore）');
eq('上限常量是 25MB', attachments.MAX_ATTACHMENT_UPLOAD_BYTES, 25 * 1024 * 1024);
eq('小文件放行', attachments.checkUploadSize('a.txt', 1024).ok, true);
eq('恰好 25MB 放行（边界含等号）', attachments.checkUploadSize('a.txt', 25 * 1024 * 1024).ok, true);
eq('25MB + 1 字节被拦', attachments.checkUploadSize('big.bin', 25 * 1024 * 1024 + 1).ok, false);
eq('被拦时提示含文件名', attachments.checkUploadSize('big.bin', 30 * 1024 * 1024).message.indexOf('big.bin') >= 0, true);
eq('被拦时提示含 25.0MB 上限', attachments.checkUploadSize('big.bin', 30 * 1024 * 1024).message.indexOf('25.0MB') >= 0, true);
eq('被拦时提示含真实体积', attachments.checkUploadSize('big.bin', Math.round(30.5 * 1024 * 1024)).message.indexOf('30.5MB') >= 0, true);
eq('0 字节文件放行', attachments.checkUploadSize('empty.txt', 0).ok, true);
eq('读不到大小（负数）被拦', attachments.checkUploadSize('x', -1).ok, false);
eq('读不到大小时提示可读', attachments.checkUploadSize('x', -1).message.indexOf('读不到') >= 0, true);
eq('空文件名有兜底文案', attachments.checkUploadSize('', 30 * 1024 * 1024).message.indexOf('未命名文件') >= 0, true);
eq('放行时没有提示文案', attachments.checkUploadSize('a.txt', 10).message, '');
eq('formatMegabytes 保留一位小数', attachments.formatMegabytes(Math.round(1.5 * 1024 * 1024)), '1.5');
eq('formatMegabytes 25MB 显示 25.0', attachments.formatMegabytes(25 * 1024 * 1024), '25.0');

group('终端 IME 组合态守卫（TerminalScreen 纯逻辑区）');
check('切片导出了守卫函数', typeof policy.shouldTrustChangeEvent === 'function');
check('切片导出了序列组合函数', typeof policy.composeKeySequence === 'function');
eq('没见过上屏回调时 onChange 可信', policy.shouldTrustChangeEvent(false), true);
eq('上屏回调出现过则 onChange 不可信', policy.shouldTrustChangeEvent(true), false);
eq('英文逐字符直送', flat(policy.composeKeySequence('abc', modState(false, false), keys.enterKey, keys.ctrlSequence)), 'a|b|c');
const newlineState = modState(false, false);
eq('换行映射成回车（CR 而非 LF）', flat(policy.composeKeySequence('hi' + String.fromCharCode(10), newlineState, keys.enterKey, keys.ctrlSequence)), 'h|i|' + ENTER_TEXT);
const ctrlState = modState(true, false);
eq('CTRL 武装时首字符变控制码', flat(policy.composeKeySequence('c', ctrlState, keys.enterKey, keys.ctrlSequence)), CTRL_C);
eq('CTRL 武装被消费掉', ctrlState.ctrl, false);
const ctrlOnceState = modState(true, false);
eq('CTRL 只作用于紧邻的一个字符', flat(policy.composeKeySequence('cx', ctrlOnceState, keys.enterKey, keys.ctrlSequence)), CTRL_C + '|x');
const ctrlEnterState = modState(true, false);
eq('CTRL 武装下回车仍是回车', flat(policy.composeKeySequence(String.fromCharCode(10), ctrlEnterState, keys.enterKey, keys.ctrlSequence)), ENTER_TEXT);
eq('回车不消费 CTRL 武装（与老实现一致）', ctrlEnterState.ctrl, true);
const ctrlSymbolState = modState(true, false);
eq('CTRL 映射不出控制码时留空串（调用方跳过）', flat(policy.composeKeySequence('1', ctrlSymbolState, keys.enterKey, keys.ctrlSequence)), '');
const altState = modState(false, true);
eq('ALT 武装时加 ESC 前缀', flat(policy.composeKeySequence('x', altState, keys.enterKey, keys.ctrlSequence)), ESC + 'x');
eq('ALT 武装被消费掉', altState.alt, false);
const altOnceState = modState(false, true);
eq('ALT 只作用于紧邻的一个字符', flat(policy.composeKeySequence('ab', altOnceState, keys.enterKey, keys.ctrlSequence)), ESC + 'a|b');
const bothState = modState(true, true);
eq('CTRL 优先于 ALT（与老实现的分支顺序一致）', flat(policy.composeKeySequence('d', bothState, keys.enterKey, keys.ctrlSequence)), String.fromCharCode(4));
eq('CTRL 消费后 ALT 仍武装', bothState.alt, true);
eq('含空格的上屏文本逐字符保留', flat(policy.composeKeySequence('ls -l ', modState(false, false), keys.enterKey, keys.ctrlSequence)), 'l|s| |-|l| ');

// ---------------------------------------------------------------------------

console.log(String.fromCharCode(10) + '--------------------------------------------');
console.log('PASS ' + passed + ' / FAIL ' + failures.length);
if (failures.length > 0) {
  console.log(String.fromCharCode(10) + 'FAIL 明细：');
  for (const item of failures) {
    console.log('  - ' + item);
  }
  process.exit(1);
}
console.log('suite-input: 全绿');
