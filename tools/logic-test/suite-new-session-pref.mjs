#!/usr/bin/env node
/**
 * 新建会话「上次选择」记忆的纯逻辑断言（R47 新增）。
 *
 * 被测代码：`model/NewSessionPreference.ets`（零 import，可单独转译）。
 * 触发这轮改动的是用户反馈：「无法新建对话，且新建能保留默认设置」——
 * 真机上默认权限模式是「仅可查看」，每次新建都要手动改，忘了就建出一个只能读的会话。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-new-session-pref.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-new-session-pref');
const LOGIC_FILES = ['model/NewSessionPreference.ets'];
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
const P = require(path.join(OUT_DIR, 'model/NewSessionPreference.js'));

const ACC = 'http://127.0.0.1:8787|user-1';
const DEV_A = 'conn-a';
const DEV_B = 'conn-b';
const RT_X = 'rt-x';
const RT_Y = 'rt-y';

group('账号键（服务器/用户任一为空 ⇒ 不落盘）');
eq('正常账号键', P.newSessionAccountKey('http://127.0.0.1:8787', 'user-1'), ACC);
eq('服务器尾部斜杠被归一', P.newSessionAccountKey('http://127.0.0.1:8787/', 'user-1'), ACC);
eq('服务器为空 ⇒ 空串', P.newSessionAccountKey('', 'user-1'), '');
eq('用户为空 ⇒ 空串', P.newSessionAccountKey('http://127.0.0.1:8787', '  '), '');

group('作用域键');
eq('scope 拼接', P.newSessionScope(DEV_A, RT_X), DEV_A + '|' + RT_X);
eq('scope 去空白', P.newSessionScope(' ' + DEV_A + ' ', ' ' + RT_X + ' '), DEV_A + '|' + RT_X);

group('解码容错（坏数据必须退化成空书，绝不抛）');
eq('空串 ⇒ 空书', P.decodePreferenceBook('').entries.length, 0);
eq('非法 JSON ⇒ 空书', P.decodePreferenceBook('{oops').entries.length, 0);
eq('数组根 ⇒ 空书', P.decodePreferenceBook('[1,2]').entries.length, 0);
eq('null 根 ⇒ 空书', P.decodePreferenceBook('null').entries.length, 0);
const partial = P.decodePreferenceBook('{"entries":[{"account":"a"},{"deviceId":"d"},{"account":"b","selections":[{"scope":"s"}]}]}');
eq('半损坏：无 account 的条目被丢', partial.entries.length, 2);
eq('半损坏：保留有 account 的', partial.entries[0].account, 'a');
eq('半损坏：缺字段回落空串', partial.entries[0].deviceId, '');
eq('半损坏：selections 里的 scope 保留', partial.entries[1].selections[0].scope, 's');

group('写入：不可变 + 叠加（模型/推理/权限分别保存后都在）');
const empty = P.emptyBook();
const t1 = P.withTarget(empty, ACC, DEV_A, RT_X);
eq('原书未被改动（不可变）', empty.entries.length, 0);
eq('写入后有 1 条', t1.entries.length, 1);
eq('target 落盘', t1.entries[0].deviceId + '|' + t1.entries[0].runtimeId, DEV_A + '|' + RT_X);
const s1 = P.withSelection(t1, ACC, DEV_A, RT_X, { modelId: 'm1', reasoningId: '', permissionId: '', agentPresetId: '' });
eq('只写模型 ⇒ permissionId 仍为空', s1.entries[0].selections[0].permissionId, '');
const s2 = P.withSelection(s1, ACC, DEV_A, RT_X, { modelId: 'm1', reasoningId: '', permissionId: 'read-only', agentPresetId: '' });
eq('再写权限 ⇒ 同一 scope 只有一条', s2.entries[0].selections.length, 1);
eq('权限已更新', s2.entries[0].selections[0].permissionId, 'read-only');
eq('模型仍在', s2.entries[0].selections[0].modelId, 'm1');
const s3 = P.withSelection(s2, ACC, DEV_A, RT_Y, { modelId: 'm2', reasoningId: 'high', permissionId: 'write', agentPresetId: '' });
eq('换 Agent ⇒ 新增一个 scope', s3.entries[0].selections.length, 2);
eq('新 scope 的内容', s3.entries[0].selections[1].modelId + '/' + s3.entries[0].selections[1].reasoningId, 'm2/high');
const s4 = P.withSelection(s3, ACC, DEV_A, RT_X, { modelId: '', reasoningId: '', permissionId: '', agentPresetId: '' });
eq('四项全空 ⇒ 不覆盖既有值', s4.entries[0].selections.length, 2);
// ⚠️ R52 的关键分支：**只改了 Agent 预设**（模型/推理/权限都没动）也必须落盘 ——
// 判空里漏掉 agentPresetId 的话，这一笔会被当成「还没选」而整条丢弃。
const s4b = P.withSelection(s4, ACC, DEV_A, RT_X, { modelId: '', reasoningId: '', permissionId: '', agentPresetId: 'minimal' });
// ⚠️ 按 **scope 查**而不是按下标：withSelection 重建 kept 时会把「其它 scope」排在前面，
// 下标 0 不一定是 RT_X（这个坑当场踩了一次）。
const backX = P.restoreSelection(P.readPreferenceEntry(s4b, ACC), DEV_A, RT_X);
eq('只改预设也落盘', backX.agentPresetId, 'minimal');
// ⚠️ withSelection 对该 scope 是**整体替换**（不是逐字段合并）——所以调用方必须把四项一起传进来；
// 页面侧就是 rememberSelection() 从 @State 一次性取齐四项。这里把这条语义钉住，
// 免得以后有人以为「只传改动的那个字段就行」。
eq('整体替换语义：没传的字段会被清空', backX.modelId + '|' + backX.permissionId, '|');
eq('只改预设不影响其它 scope', P.restoreSelection(P.readPreferenceEntry(s4b, ACC), DEV_A, RT_Y).modelId, 'm2');
eq('从 s4b 恢复得到预设', P.restoreSelection(P.readPreferenceEntry(s4b, ACC), DEV_A, RT_X).agentPresetId, 'minimal');

group('多账号隔离');
const multi = P.withTarget(s4, 'http://other|user-2', DEV_B, RT_Y);
eq('第二个账号也入册', multi.entries.length, 2);
eq('账号 1 的选择没被搅动', P.readPreferenceEntry(multi, ACC).selections.length, 2);
eq('账号 2 独立', P.readPreferenceEntry(multi, 'http://other|user-2').deviceId, DEV_B);
eq('空账号不写入', P.withTarget(multi, '', DEV_A, RT_X).entries.length, 2);
eq('半截 target（无 runtime）不写入', P.withTarget(multi, ACC, DEV_A, '').entries.length, 2);

group('恢复：作用域匹配才给值');
const entry = P.readPreferenceEntry(multi, ACC);
eq('同 scope 恢复模型', P.restoreSelection(entry, DEV_A, RT_X).modelId, 'm1');
eq('同 scope 恢复权限', P.restoreSelection(entry, DEV_A, RT_X).permissionId, 'read-only');
eq('同设备换 Agent ⇒ 预设各记各的（entry 里 RT_Y 没记过 ⇒ 空串）', P.restoreSelection(entry, DEV_A, RT_Y).agentPresetId, '');
eq('同设备换 Agent ⇒ 用该 Agent 自己的记忆', P.restoreSelection(entry, DEV_A, RT_Y).modelId, 'm2');
eq('同设备换 Agent ⇒ 权限也各记各的', P.restoreSelection(entry, DEV_A, RT_Y).permissionId, 'write');
eq('换设备 ⇒ undefined', P.restoreSelection(entry, DEV_B, RT_X) === undefined, true);
eq('没有条目 ⇒ undefined', P.restoreSelection(undefined, DEV_A, RT_X) === undefined, true);

group('恢复设备/Agent：先校验可用性再恢复');
eq('设备仍在 ⇒ 用它', P.pickRestorableDevice(entry, [DEV_B, DEV_A]), DEV_A);
eq('设备已离线 ⇒ 空串（回落到第一个）', P.pickRestorableDevice(entry, [DEV_B]), '');
eq('无条目 ⇒ 空串', P.pickRestorableDevice(undefined, [DEV_A]), '');
eq('Agent 仍就绪 ⇒ 用它', P.pickRestorableRuntime(entry, DEV_A, [RT_Y, RT_X]), RT_X);
eq('Agent 未就绪 ⇒ 空串', P.pickRestorableRuntime(entry, DEV_A, [RT_Y]), '');
eq('设备不匹配 ⇒ 空串', P.pickRestorableRuntime(entry, DEV_B, [RT_X]), '');
eq('目录里仍在 ⇒ 保留', P.pickExistingId('m1', ['m0', 'm1']), 'm1');
eq('目录里没了 ⇒ 空串', P.pickExistingId('m9', ['m0', 'm1']), '');
eq('空偏好 ⇒ 空串', P.pickExistingId('', ['m1']), '');

group('往返：编码 → 解码逐项等价');
const round = P.decodePreferenceBook(P.encodePreferenceBook(multi));
eq('条目数一致', round.entries.length, multi.entries.length);
eq('账号一致', round.entries[0].account, multi.entries[0].account);
eq('scope 数一致', round.entries[0].selections.length, multi.entries[0].selections.length);
eq('深层值一致', round.entries[0].selections[1].permissionId, multi.entries[0].selections[1].permissionId);

group('默认构造');
eq('emptySelection 三项为空', P.emptySelection().modelId + P.emptySelection().reasoningId + P.emptySelection().permissionId, '');
eq('emptyBook 无条目', P.emptyBook().entries.length, 0);

// ---------------------------------------------------------------------------
console.log(NL + '== 汇总 ============');
if (failures.length === 0) {
  console.log('suite-new-session-pref: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('失败 ' + failures.length + ' 条：');
for (const f of failures) { console.log('  - ' + f); }
process.exit(1);
