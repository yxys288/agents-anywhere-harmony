#!/usr/bin/env node
/**
 * aa-hm「Agent 提问 → 提问框」的纯逻辑断言（R50 新增）。
 *
 * 被测代码：`model/InputRequest.ets`（零 import，可单独转译）。
 * 触发这轮改动的是用户反馈：「修复会话向用户提问时，软件不显示提问框」。
 *
 * 协议形状以**连接器源码**为准（不是照抄上游 UI 层的猜测）：
 *  · `connector/connector/runtime_protocol/interactions.py` 的 `InputRequestForm.action()`
 *    产出 `{actionId:'submit', input:{required:true, schema, uiSchema:{component:'inputRequest', version:1, questions:[…]}}}`
 *    与 `parse_answers()` 的**校验规则**（单选不许同时给 optionIds 和 customText、选项必须属于本题……）；
 *  · `connector/tests/dsh_question_probe.py` 端到端断言过答案载荷 `{answers:{<qid>:{optionIds,customText?}}}`。
 *
 * ⚠️ 断言必须比对**语义**（拒绝什么、产出什么），不能只判「函数存在」——
 * 本套件最后一组是**变异测试**：把关键分支改坏必须变红。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-input-request.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-input-request');
const LOGIC_FILES = ['model/InputRequest.ets'];
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
const M = require(path.join(OUT_DIR, 'model/InputRequest.js'));

// ---- 夹具：与连接器 `InputRequestForm.action()` 逐字同形 ----------------------------------
function question(id, prompt, multiple, options, extra) {
  const q = { id: id, prompt: prompt, multiple: multiple, allowCustom: true, options: options };
  if (extra !== undefined) { Object.assign(q, extra); }
  return q;
}
function option(id, label, description) {
  const o = { id: id, label: label };
  if (description !== undefined) { o.description = description; }
  return o;
}
function notice(interactionType, uiSchema, actionId) {
  return {
    noticeId: 'n1', type: 'interaction', sessionId: 's1', title: 't', severity: 'info', status: 'open',
    interactionType: interactionType, responseRequired: true,
    actions: [{
      actionId: actionId === undefined ? 'submit' : actionId, label: 'Submit', style: 'primary',
      input: { required: true, schema: {}, uiSchema: uiSchema }
    }],
    revision: 1, updatedSeq: 7
  };
}
const UI = {
  component: 'inputRequest', version: 1,
  questions: [
    question('q_0', '这一轮先改哪个页面？', false,
      [option('o_0', '会话详情页', '时间线与输入区'), option('o_1', '首页'), option('o_2', '设置页')],
      { header: '范围' }),
    question('q_1', '顺带一起做的（可多选）', true, [option('o_0', '补逻辑自测'), option('o_1', '更新文档')])
  ]
};

group('① 表单解析：只有「input_request + component/version 都对」才算提问');
const form = M.inputRequestForm(notice('input_request', UI));
check('正常载荷解析出表单', form !== undefined);
eq('动作 id 取自 action', form.actionId, 'submit');
eq('题目数', form.questions.length, 2);
eq('题 1 的 id / 题面 / 小标题', form.questions[0].id + '|' + form.questions[0].prompt + '|' + form.questions[0].header,
  'q_0|这一轮先改哪个页面？|范围');
eq('题 1 单选', form.questions[0].multiple, false);
eq('题 1 选项数与首个选项', form.questions[0].options.length + '|' + form.questions[0].options[0].label + '|' +
  form.questions[0].options[0].description, '3|会话详情页|时间线与输入区');
eq('题 2 多选', form.questions[1].multiple, true);
eq('allowCustom 缺省 = 允许', M.inputRequestForm(notice('input_request', {
  component: 'inputRequest', version: 1,
  questions: [{ id: 'q_0', prompt: 'p', multiple: false, options: [option('o_0', 'a')] }]
})).questions[0].allowCustom, true);
eq('allowCustom 显式 false 生效', M.inputRequestForm(notice('input_request', {
  component: 'inputRequest', version: 1,
  questions: [{ id: 'q_0', prompt: 'p', multiple: false, allowCustom: false, options: [option('o_0', 'a')] }]
})).questions[0].allowCustom, false);

group('② 拒绝语义（逐条对齐上游 inputRequestForm 的 return null）');
eq('interactionType 不是 input_request ⇒ 无表单', M.inputRequestForm(notice('approval', UI)), undefined);
eq('component 不是 inputRequest ⇒ 无表单', M.inputRequestForm(notice('input_request',
  { component: 'other', version: 1, questions: UI.questions })), undefined);
eq('version 不是 1 ⇒ 无表单（不把新协议渲染成半成品）', M.inputRequestForm(notice('input_request',
  { component: 'inputRequest', version: 2, questions: UI.questions })), undefined);
eq('questions 空数组 ⇒ 无表单', M.inputRequestForm(notice('input_request',
  { component: 'inputRequest', version: 1, questions: [] })), undefined);
eq('questions 不是数组 ⇒ 无表单', M.inputRequestForm(notice('input_request',
  { component: 'inputRequest', version: 1, questions: 'x' })), undefined);
eq('题缺 prompt ⇒ 整表单作废', M.inputRequestForm(notice('input_request', {
  component: 'inputRequest', version: 1, questions: [question('q_0', 'p', false, [option('o_0', 'a')]), { id: 'q_1', options: [] }]
})), undefined);
eq('题 id 重复 ⇒ 整表单作废', M.inputRequestForm(notice('input_request', {
  component: 'inputRequest', version: 1,
  questions: [question('q_0', 'a', false, [option('o_0', 'x')]), question('q_0', 'b', false, [option('o_0', 'y')])]
})), undefined);
eq('选项 id 重复 ⇒ 整表单作废', M.inputRequestForm(notice('input_request', {
  component: 'inputRequest', version: 1,
  questions: [question('q_0', 'a', false, [option('o_0', 'x'), option('o_0', 'y')])]
})), undefined);
eq('选项缺 label ⇒ 整表单作废', M.inputRequestForm(notice('input_request', {
  component: 'inputRequest', version: 1, questions: [question('q_0', 'a', false, [{ id: 'o_0' }])]
})), undefined);
eq('没有 input ⇒ 无表单', M.inputRequestForm({
  noticeId: 'n', type: 'interaction', sessionId: 's', title: 't', severity: 'info', status: 'open',
  interactionType: 'input_request', responseRequired: true,
  actions: [{ actionId: 'submit', label: 'S', style: 'primary' }], revision: 1, updatedSeq: 1
}), undefined);

group('③ 草稿 / 完整性（上游 isComplete：每题都要有选项或「其他」且非空）');
const f = M.inputRequestForm(notice('input_request', UI));
const drafts = M.initialDrafts(f);
eq('初始草稿每题一份', drafts.size, 2);
check('初始不完整', M.isComplete(f, drafts) === false);
drafts.set('q_0', { optionIds: ['o_0'], customText: '', useCustom: false });
check('只答一题仍不完整', M.isComplete(f, drafts) === false);
drafts.set('q_1', { optionIds: ['o_0', 'o_1'], customText: '', useCustom: true });
check('两题都有选项 ⇒ 完整（多选可多个）', M.isComplete(f, drafts) === true);
drafts.set('q_0', { optionIds: [], customText: '都行', useCustom: true });
check('单选改用「其他」+ 非空文本 ⇒ 完整', M.isComplete(f, drafts) === true);
drafts.set('q_0', { optionIds: [], customText: '   ', useCustom: true });
check('单选「其他」只填空格 ⇒ 不完整', M.isComplete(f, drafts) === false);
drafts.set('q_0', { optionIds: ['o_0', 'o_1'], customText: '', useCustom: false });
check('单选却选了 2 个 ⇒ 不完整（连接器也会拒）', M.isComplete(f, drafts) === false);

group('④ 载荷形状（连接器 parse_answers 的入参）');
const d2 = M.initialDrafts(f);
d2.set('q_0', { optionIds: ['o_0'], customText: '', useCustom: false });
d2.set('q_1', { optionIds: ['o_0'], customText: '', useCustom: false });
const payload = M.buildPayload(f, d2);
eq('顶层只有 answers', Object.keys(payload).join(','), 'answers');
eq('答案按题 id 分键', Object.keys(payload.answers).sort().join(','), 'q_0,q_1');
eq('单选取值', JSON.stringify(payload.answers.q_0), '{"optionIds":["o_0"]}');
check('未选「其他」时**不带** customText', payload.answers.q_0.customText === undefined);
d2.set('q_0', { optionIds: [], customText: '  都行  ', useCustom: true });
const payload2 = M.buildPayload(f, d2);
eq('「其他」文本被 trim 后带上', payload2.answers.q_0.customText, '都行');
eq('单选选「其他」时 optionIds 必须为空', JSON.stringify(payload2.answers.q_0.optionIds), '[]');

group('⑤ 交互：单选/多选与「其他」的互斥（上游 onClick / onChange 同款）');
const single = f.questions[0];
const multi = f.questions[1];
eq('单选点 A', JSON.stringify(M.toggleOption(single, M.emptyDraft(), 'o_0')), '{"optionIds":["o_0"],"customText":"","useCustom":false}');
eq('单选再点 B ⇒ 只剩 B', JSON.stringify(M.toggleOption(single, { optionIds: ['o_0'], customText: '', useCustom: false }, 'o_1')),
  '{"optionIds":["o_1"],"customText":"","useCustom":false}');
eq('单选点已选项 ⇒ 仍是它（单选不可取消到空）',
  JSON.stringify(M.toggleOption(single, { optionIds: ['o_0'], customText: '', useCustom: false }, 'o_0')),
  '{"optionIds":["o_0"],"customText":"","useCustom":false}');
eq('多选点 A 再点 B ⇒ 两个都在',
  JSON.stringify(M.toggleOption(multi, { optionIds: ['o_0'], customText: '', useCustom: false }, 'o_1')),
  '{"optionIds":["o_0","o_1"],"customText":"","useCustom":false}');
eq('多选再点 A ⇒ 取消 A',
  JSON.stringify(M.toggleOption(multi, { optionIds: ['o_0', 'o_1'], customText: '', useCustom: false }, 'o_0')),
  '{"optionIds":["o_1"],"customText":"","useCustom":false}');
eq('单选选「其他」⇒ 清掉已选选项（连接器禁止两者并存）',
  JSON.stringify(M.selectCustom(single, { optionIds: ['o_0'], customText: '', useCustom: false })),
  '{"optionIds":[],"customText":"","useCustom":true}');
eq('多选选「其他」⇒ 保留已选选项',
  JSON.stringify(M.selectCustom(multi, { optionIds: ['o_0'], customText: '', useCustom: false })),
  '{"optionIds":["o_0"],"customText":"","useCustom":true}');
eq('单选在「其他」里打字 ⇒ 同样清掉选项',
  JSON.stringify(M.updateCustomText(single, { optionIds: ['o_0'], customText: '', useCustom: false }, 'x')),
  '{"optionIds":[],"customText":"x","useCustom":true}');
eq('单选先选「其他」再点选项 ⇒ 文本被清空',
  JSON.stringify(M.toggleOption(single, { optionIds: [], customText: 'x', useCustom: true }, 'o_2')),
  '{"optionIds":["o_2"],"customText":"","useCustom":false}');

group('⑥ 变异测试（把关键分支改坏必须变红）');
function mutate(mutator, name, shouldFail) {
  const source = fs.readFileSync(path.join(SRC_ETS, 'model/InputRequest.ets'), 'utf8');
  const out = mutator(source);
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
mutate((s) => s.replace("notice.interactionType !== INPUT_REQUEST_INTERACTION",
  "false"), '摘掉 interactionType 守卫', (Mut) => {
  const g = Mut.inputRequestForm(notice('approval', UI));
  return g !== undefined;   // 审批卡也会被当成提问表单
});
mutate((s) => s.replace("if (typeof version !== 'number' || version !== INPUT_REQUEST_VERSION) {", "if (false) {"),
  '放开 version 守卫', (Mut) => {
  const g = Mut.inputRequestForm(notice('input_request', { component: 'inputRequest', version: 2, questions: UI.questions }));
  return g !== undefined;
});
mutate((s) => s.replace("return { optionIds: [optionId], customText: '', useCustom: false };",
  "return { optionIds: draft.optionIds.concat([optionId]), customText: '', useCustom: false };"), '单选改成可累积', (Mut) => {
  const f2 = Mut.inputRequestForm(notice('input_request', UI));
  const d = Mut.toggleOption(f2.questions[0], { optionIds: ['o_0'], customText: '', useCustom: false }, 'o_1');
  return d.optionIds.length !== 1;   // 期望是「只剩 o_1」
});
mutate((s) => s.replace("optionIds: question.multiple ? draft.optionIds.slice() : [],",
  "optionIds: draft.optionIds.slice(),"), '单选选「其他」时不清选项', (Mut) => {
  const f2 = Mut.inputRequestForm(notice('input_request', UI));
  const d = Mut.selectCustom(f2.questions[0], { optionIds: ['o_0'], customText: '', useCustom: false });
  return d.optionIds.length !== 0;
});
mutate((s) => s.replace("if (!question.multiple && optionCount > 1) {\n      return false;\n    }", ''),
  '去掉单选多选校验', (Mut) => {
  const f2 = Mut.inputRequestForm(notice('input_request', UI));
  const d = Mut.initialDrafts(f2);
  d.set('q_0', { optionIds: ['o_0', 'o_1'], customText: '', useCustom: false });
  d.set('q_1', { optionIds: ['o_0'], customText: '', useCustom: false });
  return Mut.isComplete(f2, d) !== false;
});

if (failures.length > 0) {
  console.error('suite-input-request: ' + failures.length + ' 条断言失败');
  for (const f2 of failures) { console.error('  FAIL ' + f2); }
  process.exit(1);
}
console.log('suite-input-request: ' + passed + ' 条断言全绿（含 5 组变异测试）。');
