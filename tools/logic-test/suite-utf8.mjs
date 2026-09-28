#!/usr/bin/env node
/**
 * aa-hm「UTF-8 编码」纯逻辑断言（R83 精简轮新增）。
 *
 * 被测代码：`utils/Sha256.ets` 的 `utf8Bytes`（零 import，可单独转译）。
 *
 * 为什么这轮要给它补测试：R83 把**三份复制**收敛成这一份 ——
 *   · `api/ApiClient.ets` 的 `utf8ToBuffer`（POST 表单体 / multipart 头 / JSON 体）
 *   · `feature/TerminalStore.ets` 的 `uint8FromString`（终端按键）
 *   · `utils/Sha256.ets` 的 `utf8Bytes`（OAuth PKCE、附件摘要）
 * 同时把实现从「`number[]` 逐字节 push → 再拷进 `Uint8Array`」改成「先算长度、一次分配写入」。
 * 于是**必须**证明「改写后逐字节等价」，否则三条业务链路一起静默走样。
 *
 * 三层判据（缺一不可）：
 *  ① **差分**：与 `oldUtf8Bytes`（改前实现，原样转抄）逐字节相同；
 *  ② **外部 oracle**：格式良好的字符串与 Node 的 `Buffer.from(s, 'utf8')` 逐字节相同；
 *  ③ **变异**：把新实现的两遍逻辑各改坏一处，断言上面的判据会红（证明测试真的有分辨力）。
 *
 * ⚠️ 孤代理码元（未成对的 D800~DFFF）**不能**拿 `Buffer.from` 当判据：Node 会替换成 U+FFFD，
 * 而本工程按 3 字节原样编码 —— 这是改前后一致的既有行为，用**钉死期望值**的方式锁住。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-utf8.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-utf8');
const SHA256_ETS = path.join(SRC_ETS, 'utils', 'Sha256.ets');
const APICLIENT_ETS = path.join(SRC_ETS, 'api', 'ApiClient.ets');
const TERMINALSTORE_ETS = path.join(SRC_ETS, 'feature', 'TerminalStore.ets');
const NL = String.fromCharCode(10);

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  const rel = 'utils/Sha256.ets';
  const source = fs.readFileSync(SHA256_ETS, 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
    fileName: rel
  });
  const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, output.outputText, 'utf8');
}

let passed = 0;
const failures = [];
function check(name, condition, detail) {
  if (condition) { passed += 1; } else { failures.push(detail === undefined ? name : name + ' — ' + detail); }
}
function eqBytes(name, actual, expected) {
  const a = Array.from(actual);
  check(name, a.length === expected.length && a.every((v, i) => v === expected[i]),
    name + ' — expected [' + expected.join(',') + '], got [' + a.join(',') + ']');
}
function group(title) { console.log(NL + '== ' + title); }

// ---------------------------------------------------------------------------
// 改前实现（R83 收敛前 `utils/Sha256.ets` 的原文，逐字转抄，**只作为差分 oracle**）
// ---------------------------------------------------------------------------
function oldUtf8Bytes(text) {
  const bytes = [];
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        i += 1;
      }
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
      bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
    } else {
      bytes.push(
        0xF0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3F),
        0x80 | ((code >> 6) & 0x3F),
        0x80 | (code & 0x3F)
      );
    }
  }
  const out = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) { out[i] = bytes[i]; }
  return out;
}

build();
const require = createRequire(import.meta.url);
const M = require(path.join(OUT_DIR, 'utils/Sha256.js'));

// 语料：ASCII / 1~4 字节边界 / 中文 / emoji / 孤代理 / 混合长串
const CORPUS = [
  ['空串', ''],
  ['ASCII 单字符', 'a'],
  ['ASCII 整句', 'Agents Anywhere 2026 -_.~'],
  ['1 字节边界 0x7F', String.fromCharCode(0x7F)],
  ['2 字节下界 0x80', String.fromCharCode(0x80)],
  ['2 字节上界 0x7FF', String.fromCharCode(0x7FF, 0x7FF)],
  ['3 字节下界 0x800', String.fromCharCode(0x800)],
  ['3 字节上界 0xFFFF', String.fromCharCode(0xFFFF)],
  ['中文', '中文字节数测试'],
  ['4 字节 emoji', '😀🚀'],
  ['混合', 'a' + String.fromCharCode(0xE9) + '中' + '😀' + ' Z'],
  ['孤高代理', '\uD800'],
  ['孤低代理', '\uDC00'],
  ['孤高代理后接普通字符', '\uD800a'],
  ['普通字符后接孤高代理', 'a\uD800'],
  ['代理对的上界', '\uDBFF\uDFFF'],
  ['长混排（重复 200 次）', 'a中😀'.repeat(200)]
];

group('① 差分：新实现 === 改前实现（逐字节）');
for (const [name, text] of CORPUS) {
  eqBytes('差分 ' + name, M.utf8Bytes(text), Array.from(oldUtf8Bytes(text)));
}

group('② 外部 oracle：格式良好的字符串 === Node Buffer.from(utf8)');
for (const [name, text] of CORPUS) {
  const wellFormed = !/[\uD800-\uDFFF]/.test(text.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, ''));
  if (!wellFormed) { continue; }
  eqBytes('oracle ' + name, M.utf8Bytes(text), Array.from(Buffer.from(text, 'utf8')));
}

group('③ 钉死孤代理的既有行为（3 字节原样编码，Node 会替换成 U+FFFD，故不能当 oracle）');
eqBytes('孤高代理 3 字节', M.utf8Bytes('\uD800'), [0xED, 0xA0, 0x80]);
eqBytes('孤低代理 3 字节', M.utf8Bytes('\uDC00'), [0xED, 0xB0, 0x80]);
eqBytes('代理对按 4 字节', M.utf8Bytes('😀'), [0xF0, 0x9F, 0x98, 0x80]);
eqBytes('中文按 3 字节', M.utf8Bytes('中'), [0xE4, 0xB8, 0xAD]);
eqBytes('ASCII 按 1 字节', M.utf8Bytes('A'), [0x41]);

group('④ 返回值的缓冲区不变量（ApiClient 直接取 `.buffer` 当请求体，多一字节都是坏包）');
for (const [name, text] of CORPUS) {
  const view = M.utf8Bytes(text);
  const expected = Array.from(oldUtf8Bytes(text)).length;
  check('byteOffset 为 0 ' + name, view.byteOffset === 0, 'got ' + view.byteOffset);
  check('buffer.byteLength === length ' + name, view.buffer.byteLength === view.length,
    'length ' + view.length + ' vs buffer ' + view.buffer.byteLength);
  check('长度与改前一致 ' + name, view.length === expected, 'got ' + view.length + ', expected ' + expected);
}

group('⑤ 与 SHA-256 的联动（NIST 向量，确认编码层没把摘要喂坏）');
const e1 = M.sha256Hex(M.utf8Bytes('abc'));
check('sha256("abc")', e1 === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'got ' + e1);
const e2 = M.sha256Hex(M.utf8Bytes('中文'));
check('sha256("中文") 与 Buffer 路径一致', e2 === M.sha256Hex(new Uint8Array(Buffer.from('中文', 'utf8'))), 'got ' + e2);

group('⑥ 源码结构闸门：三份复制必须只剩一份（防回潮）');
const sha256Source = fs.readFileSync(SHA256_ETS, 'utf8');
const apiSource = fs.readFileSync(APICLIENT_ETS, 'utf8');
const terminalSource = fs.readFileSync(TERMINALSTORE_ETS, 'utf8');
check('Sha256.ets 只有一个 export function utf8Bytes',
  (sha256Source.match(/export function utf8Bytes/g) || []).length === 1,
  'got ' + (sha256Source.match(/export function utf8Bytes/g) || []).length);
check('ApiClient.ets 不再自带 utf8ToBuffer', !/function utf8ToBuffer/.test(apiSource));
check('ApiClient.ets 从 utils/Sha256 引 utf8Bytes', /import \{ utf8Bytes \} from '\.\.\/utils\/Sha256';/.test(apiSource));
check('TerminalStore.ets 不再自带 uint8FromString', !/function uint8FromString/.test(terminalSource));
check('TerminalStore.ets 从 utils/Sha256 引 utf8Bytes', /import \{ utf8Bytes \} from '\.\.\/utils\/Sha256';/.test(terminalSource));
const SENTINEL = /0x10000 \+ \(\(code - 0xD800\) << 10\)/g;
check('代理对合成只在一处（哨兵：0x10000 + ((code - 0xD800) << 10)）',
  (sha256Source.match(SENTINEL) || []).length === 1,
  'Sha256.ets 里应恰好出现 1 次（长度那一遍只累加不合成），got ' + (sha256Source.match(SENTINEL) || []).length);
check('ApiClient.ets 里没有第二份编码循环', (apiSource.match(SENTINEL) || []).length === 0);
check('TerminalStore.ets 里没有第二份编码循环', (terminalSource.match(SENTINEL) || []).length === 0);


group('⑦ 变异测试：把新实现改坏，上面几层判据必须变红');
/** 用同一套差分/oracle 判据跑一个候选实现；返回 true = 判据发现它坏了。 */
function predicateFails(mod) {
  for (const [, text] of CORPUS) {
    const got = Array.from(mod.utf8Bytes(text));
    const expected = Array.from(oldUtf8Bytes(text));
    if (got.length !== expected.length || got.some((v, i) => v !== expected[i])) { return true; }
  }
  return false;
}
function mutate(replacements, name) {
  const source = fs.readFileSync(SHA256_ETS, 'utf8');
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
  try { broken = predicateFails(Mut); } catch (error) { broken = true; }
  check(name + '：变异后判据确实变红', broken === true);
}
// ① 长度那一遍不再跳过代理对的低位码元 ⇒ 期望长度比实际写入多 3（尾部多 3 个 0）
mutate([['        i += 1;\n        size += 4;', '        size += 4;']],
  '长度那一遍不再跳过代理对低位');
// ② 3 字节档算成 2 字节 ⇒ 期望长度整体偏小（中文/emoji 全错）
mutate([['      size += 3;', '      size += 2;']], '3 字节档长度算错');
// ③ 写入那一遍不再合成代理对 ⇒ emoji 退化成 6 字节（CESU-8）
mutate([['        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);\n        i += 1;\n', '']],
  '写入那一遍不再合成代理对');
// ④ 2 字节档的首字节写成 0x80 ⇒ 长度对、内容错（只有逐字节比对才抓得住）
mutate([['      out[at] = 0xC0 | (code >> 6);', '      out[at] = 0x80 | (code >> 6);']], '2 字节首字节写错');
if (failures.length > 0) {
  console.error('suite-utf8: ' + failures.length + ' 条断言失败');
  for (const f of failures) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-utf8: ' + passed + ' 条断言全绿（差分 + 外部 oracle + 缓冲区不变量 + 源码闸门 + 4 组变异）。');