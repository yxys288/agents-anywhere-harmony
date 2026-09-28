#!/usr/bin/env node
/**
 * aa-hm「首条消息的内联附件」纯逻辑断言（R54 新增）。
 *
 * 被测代码：`model/InlineAttachment.ets`（只 import 同目录的纯类型，可单独转译）。
 * 触发这轮改动的是用户要求：「首条消息也要能带附件」。
 *
 * 协议形状**不是猜的**（服务端源码为准）：
 *  · `server/agent_server/core/models.py:707-728`：`fileId` 1..64 / `name` 1..512 /
 *    `mediaType` 默认 `application/octet-stream` / `size` 给了必须等于字节数 /
 *    `sha256` 给了必须等于内容 / `attachments` 最多 10 条；
 *  · `server/agent_server/services/session_run.py:185-193`：带附件要求 `runtime.attachment` 可用；
 *  · `connector/connector/runtimes/dsh/runtime.py:327`：`content` 与 `attachments` **至少有一个非空**。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-inline-attachment.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-inline-attachment');
const LOGIC_FILES = ['model/InlineAttachment.ets'];
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
  if (condition) { passed += 1; } else { failures.push(detail === undefined ? name : detail); }
}
function eq(name, actual, expected) {
  check(name, actual === expected, name + ' — expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function group(title) { console.log(NL + '== ' + title); }

build();
const require = createRequire(import.meta.url);
const M = require(path.join(OUT_DIR, 'model/InlineAttachment.js'));

function local(over) {
  const base = { uri: 'file://docs/1/文本.txt', name: '文本.txt', mediaType: 'text/plain', size: 12 };
  return Object.assign(base, over || {});
}

group('契约常量');
eq('能力 id 与服务端同值', M.RUNTIME_ATTACHMENT_CAPABILITY, 'runtime.attachment');
eq('条数上限 = 服务端 max_length', M.MAX_INLINE_ATTACHMENTS, 10);
eq('体积上限 10MB', M.MAX_INLINE_ATTACHMENT_BYTES, 10 * 1024 * 1024);
console.log('  · 能力 id / 10 条 / 10MB 三个常量与源码一致');

group('闸门：条数与体积');
check('空列表可放', M.canStageAttachment([], 1024, 'a.txt').ok);
eq('体积为负：给中文原因', M.canStageAttachment([], -1, 'a.txt').message, '读不到「a.txt」的大小，已跳过。');
eq('无名文件用占位名', M.canStageAttachment([], -1, '').message, '读不到「（未命名文件）」的大小，已跳过。');
check('正好 10MB 放行', M.canStageAttachment([], 10 * 1024 * 1024, 'a.bin').ok);
check('10MB + 1 字节拒绝', !M.canStageAttachment([], 10 * 1024 * 1024 + 1, 'a.bin').ok);
check('超额提示带文件名与体积', M.canStageAttachment([], 11 * 1024 * 1024, '大文件.bin').message.includes('大文件.bin'));
check('超额提示带 10.0MB 上限', M.canStageAttachment([], 11 * 1024 * 1024, 'x.bin').message.includes('10.0MB'));
const ten = [];
for (let i = 0; i < 10; i++) { ten.push(local({ uri: 'file://docs/' + i })); }
check('已有 10 个时拒绝第 11 个', !M.canStageAttachment(ten, 10, 'x.txt').ok);
eq('满员提示与服务端条数一致', M.canStageAttachment(ten, 10, 'x.txt').message, '首条消息最多带 10 个附件，已经放满了。');
check('9 个时仍可放', M.canStageAttachment(ten.slice(0, 9), 10, 'x.txt').ok);

group('附件条与去重键');
eq('key 用 URI', M.localAttachmentKey(local({ uri: 'file://a' })), 'file://a');
eq('空名回落占位', M.localAttachmentLabel(local({ name: '' })), '未命名文件');
eq('有名字就用名字', M.localAttachmentLabel(local({ name: '截图.png' })), '截图.png');
eq('概要：0 个时空串', M.localAttachmentSummary([]), '');
eq('概要：个数 + 体积', M.localAttachmentSummary([local({ size: 1024 * 1024 }), local({ size: 512 * 1024 })]), '2 个附件 · 1.5MB');
// ⚠️ 真机实测：25KB 的图片按「MB 保留一位」会显示成 0.0MB，用户以为附件是空的。
eq('概要：小文件按 KB（不再显示 0.0MB）', M.localAttachmentSummary([local({ size: 25021 })]), '1 个附件 · 24.4KB');
eq('体积：小于 1KB 用 B', M.humanSize(46), '46B');
eq('体积：1KB 边界', M.humanSize(1024), '1.0KB');
eq('体积：1MB 边界', M.humanSize(1024 * 1024), '1.0MB');
eq('体积：10MB 上限的写法', M.humanSize(M.MAX_INLINE_ATTACHMENT_BYTES), '10.0MB');

group('内联附件引用（服务端 InlineAttachmentRef 形状）');
const ref = M.inlineAttachmentRefFor(local({ size: 3 }), 0, 'abc123', 'aGk=');
eq('fileId 占位串', ref.fileId, 'file_aa_inline_1');
check('fileId 长度 1..64', ref.fileId.length >= 1 && ref.fileId.length <= 64);
eq('第二个附件编号递增', M.inlineAttachmentRefFor(local(), 1, 's', 'b').fileId, 'file_aa_inline_2');
eq('name 原样带上', ref.name, '文本.txt');
eq('mediaType 原样带上', ref.mediaType, 'text/plain');
eq('size 原样带上（服务端要它等于字节数）', ref.size, 3);
eq('sha256 原样带上', ref.sha256, 'abc123');
eq('contentBase64 原样带上', ref.contentBase64, 'aGk=');
eq('mediaType 为空时回落 octet-stream',
  M.inlineAttachmentRefFor(local({ mediaType: '' }), 0, 's', 'b').mediaType, 'application/octet-stream');
eq('空名在引用里也补占位', M.inlineAttachmentRefFor(local({ name: '' }), 0, 's', 'b').name, '未命名文件');

group('界面文案');
eq('能力可用时副标题', M.inlineAttachmentRowDetail(true), '图片 / 文件，随首条消息一起发出');
check('能力不可用时副标题解释了原因', M.inlineAttachmentRowDetail(false).includes('不支持'));
check('不可用提示给中文出路', M.inlineAttachmentUnavailableText().includes('对话开始后'));
check('不可用提示不带服务端英文原话', !M.inlineAttachmentUnavailableText().includes('Bridge'));

console.log(NL + '通过 ' + passed + ' 项，失败 ' + failures.length + ' 项。');
if (failures.length > 0) {
  for (const f of failures) { console.log('  ✗ ' + f); }
  process.exit(1);
}
