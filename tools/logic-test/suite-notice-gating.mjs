#!/usr/bin/env node
/**
 * aa-hm「公告该放哪儿」的纯逻辑断言（R50 新增）。
 *
 * 被测代码：`model/NoticeGating.ets`（只 import 纯类型，可单独转译）。
 * 触发这轮改动的是真机反馈：「Agent 提问时手机没弹窗」——
 * 根因是本工程把**所有**公告都当时间线的第一项，而时间线默认停在最新消息 ⇒ 提问卡在屏幕外。
 * 上游是把**阻塞公告**钉在输入区上方的（`SessionDetailScreen.kt:1653-1663` 的
 * `BlockingRuntimeNoticeStack`），时间线只放非阻塞的（`SessionMessages.kt:278-285`）。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-notice-gating.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-notice-gating');
const LOGIC_FILES = ['model/NoticeGating.ets'];
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
const G = require(path.join(OUT_DIR, 'model/NoticeGating.js'));

const SESSION = 'sess-1';
function notice(over) {
  const base = {
    noticeId: 'n1', type: 'interaction', sessionId: SESSION, title: 't', severity: 'info', status: 'open',
    responseRequired: true, actions: [{ actionId: 'submit', label: 'Submit', style: 'primary' }],
    blocking: { scope: 'session', targetId: SESSION }, revision: 1, updatedSeq: 1
  };
  return Object.assign(base, over === undefined ? {} : over);
}

group('① 三个判据（逐条对齐上游 SessionRuntimeState.kt:180-196）');
check('提问公告是 openInteraction', G.isOpenInteraction(notice({ interactionType: 'input_request' })) === true);
check('notification 不是 openInteraction', G.isOpenInteraction(notice({ type: 'notification' })) === false);
for (const status of ['open', 'responding', 'response_accepted', 'resolving', 'failed']) {
  check('交互状态 ' + status + ' 算「还开着」', G.isOpenInteraction(notice({ status: status })) === true);
}
for (const status of ['resolved', 'cancelled', 'expired', 'done']) {
  check('交互状态 ' + status + ' 不算「还开着」', G.isOpenInteraction(notice({ status: status })) === false);
}
check('notification + open 才算 openNotification', G.isOpenNotification(notice({ type: 'notification', status: 'open' })) === true);
check('notification 但已 resolved ⇒ 不算', G.isOpenNotification(notice({ type: 'notification', status: 'resolved' })) === false);
check('interaction 不算 openNotification', G.isOpenNotification(notice({})) === false);
check('scope=session + 目标命中 ⇒ 阻塞', G.blocksSession(notice({}), SESSION) === true);
check('目标不是本会话 ⇒ 不阻塞', G.blocksSession(notice({ blocking: { scope: 'session', targetId: 'other' } }), SESSION) === false);
check('scope 不是 session ⇒ 不阻塞', G.blocksSession(notice({ blocking: { scope: 'turn', targetId: SESSION } }), SESSION) === false);
check('没有 blocking ⇒ 不阻塞', G.blocksSession(notice({ blocking: undefined }), SESSION) === false);
check('可响应（interaction + responseRequired + open + 有动作）', G.isRespondable(notice({})) === true);
check('没有动作 ⇒ 不可响应', G.isRespondable(notice({ actions: [] })) === false);
check('responseRequired=false ⇒ 不可响应', G.isRespondable(notice({ responseRequired: false })) === false);
check('已 resolved ⇒ 不可响应', G.isRespondable(notice({ status: 'resolved' })) === false);

group('② 投放位置：阻塞公告钉输入区上方、其余进时间线');
const blocking = notice({ noticeId: 'b1', updatedSeq: 1 });
const nonBlocking = notice({ noticeId: 'n2', updatedSeq: 2, blocking: { scope: 'turn', targetId: 'x' } });
const notification = notice({ noticeId: 'n3', type: 'notification', status: 'open', updatedSeq: 3, blocking: undefined });
const resolved = notice({ noticeId: 'n4', status: 'resolved', updatedSeq: 4 });
const all = [blocking, nonBlocking, notification, resolved];
eq('钉上方的只有阻塞那条', G.blockingNotices(all, SESSION).map((n) => n.noticeId).join(','), 'b1');
eq('时间线拿到非阻塞交互 + 通知', G.timelineNotices(all, SESSION).map((n) => n.noticeId).join(','), 'n2,n3');
eq('已 resolved 两边都不进', G.blockingNotices([resolved], SESSION).length + G.timelineNotices([resolved], SESSION).length, 0);
eq('两桶不相交且并集 = 全部「还开着」的', (() => {
  const b = G.blockingNotices(all, SESSION).map((n) => n.noticeId);
  const t = G.timelineNotices(all, SESSION).map((n) => n.noticeId);
  const union = b.concat(t).sort().join(',');
  return union;
})(), 'b1,n2,n3');

group('③ 排序（上游 compareBy { updatedSeq }.thenBy { noticeId }）');
const sorted = G.blockingNotices([
  notice({ noticeId: 'z', updatedSeq: 9 }),
  notice({ noticeId: 'a', updatedSeq: 9 }),
  notice({ noticeId: 'm', updatedSeq: 5 })
], SESSION).map((n) => n.noticeId).join(',');
eq('先按 updatedSeq 再按 noticeId', sorted, 'm,a,z');

group('④ 变异测试（把关键判据改坏必须变红）');
function mutate(replacements, name, shouldFail) {
  const source = fs.readFileSync(path.join(SRC_ETS, 'model/NoticeGating.ets'), 'utf8');
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
mutate([[`return blocking.scope === 'session' && blocking.targetId === sessionId;`, 'return true;']],
  '去掉「目标必须是本会话」的判据', (Mut) => Mut.blocksSession(notice({ blocking: { scope: 'session', targetId: 'other' } }), SESSION) !== false);
mutate([[`if (!blocksSession(notice, sessionId)) {\n        result.push(notice);\n      }`, 'result.push(notice);']],
  '把阻塞公告也塞进时间线', (Mut) => Mut.timelineNotices([notice({ noticeId: 'b1' })], SESSION).length !== 0);
mutate([[`if (a.updatedSeq !== b.updatedSeq) {\n      return a.updatedSeq - b.updatedSeq;\n    }`, '']],
  '去掉 updatedSeq 排序', (Mut) => {
  // ⚠️ 这一对**故意让两种排序结果相反**：按 updatedSeq 应是 z(5) 在前，只按 noticeId 则 a 在前。
  const got = Mut.blockingNotices([
    notice({ noticeId: 'a', updatedSeq: 9 }), notice({ noticeId: 'z', updatedSeq: 5 })
  ], SESSION).map((n) => n.noticeId).join(',');
  return got !== 'z,a';
});

if (failures.length > 0) {
  console.error('suite-notice-gating: ' + failures.length + ' 条断言失败');
  for (const f of failures) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-notice-gating: ' + passed + ' 条断言全绿（含 3 组变异测试）。');
