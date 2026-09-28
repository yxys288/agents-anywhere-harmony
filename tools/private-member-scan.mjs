#!/usr/bin/env node
// aa-hm 类内私有成员零使用扫描器（R42 精简轮新增）
//
// 为什么需要它：`tools/dead-code-scan.mjs`（R38）只报两类 —— ① 导出但零引用；② import 未使用。
// 它**不报类内私有成员**，而 R39 的批次里方法级零调用曾达 32 条。本脚本补这一格：
// 找出「class 里声明了 private/protected 成员，但全工程除声明处外再无任何出现」的候选。
//
// 用法：node tools/private-member-scan.mjs [--json]
//
// 判据（写在这里，避免下一个人重新猜）：
// - 只扫 `entry/src/main/ets` 下**非 ui/** 的 .ets（ui 层是 struct 世界，字段常由 ArkUI 框架读，
//   零文本引用属正常，不在本工具判定范围）；
// - 「零使用」= 该标识符在全工程 .ets 里的出现次数，**减去各个声明行自身**后为 0；
// - 方向是安全的一侧：注释、字符串、类型注解里的同名文本都会算成『有人用』（漏报，不误删）；
// - 本工具给的是**候选**，删之前必须人工复核（例如框架回调、纯逻辑自带 API 面）。
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\//, '');
const SRC = join(ROOT, 'entry', 'src', 'main', 'ets');
const JSON_OUT = process.argv.includes('--json');

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      if (name === 'ui') { continue; }
      walk(full, out);
    } else if (name.endsWith('.ets') || name.endsWith('.ts')) {
      out.push(full);
    }
  }
  return out;
}

const files = walk(SRC, []);
const sources = new Map();
for (const f of files) {
  sources.set(f, readFileSync(f, 'utf8'));
}

const DECL_RE = /^\s+(private|protected)\s+(.+)$/;

/** 从 private/protected 声明行里取出成员名。 */
function memberName(text) {
  let rest = text;
  for (;;) {
    const stripped = rest.replace(/^(static|readonly|async|override|declare)\s+/, '');
    if (stripped === rest) { break; }
    rest = stripped;
  }
  const accessor = /^(get|set)\s+([A-Za-z_$][\w$]*)/.exec(rest);
  if (accessor !== null) { return accessor[2]; }
  const plain = /^([A-Za-z_$][\w$]*)\s*[:(=<]/.exec(rest);
  if (plain !== null) { return plain[1]; }
  return '';
}

function countWord(text, word) {
  const re = new RegExp('\\b' + word.replace(/[$]/g, '\\$') + '\\b', 'g');
  const found = text.match(re);
  return found === null ? 0 : found.length;
}

const declarations = [];
for (const [file, text] of sources.entries()) {
  const rows = text.split(/\r?\n/);
  for (let i = 0; i < rows.length; i++) {
    const match = DECL_RE.exec(rows[i]);
    if (match === null) { continue; }
    const name = memberName(match[2]);
    if (name === '' || name === 'constructor') { continue; }
    declarations.push({
      file: file, line: i + 1, name: name, text: rows[i].trim(),
      visibility: match[1],
      isMethod: /\{\s*$/.test(rows[i]) && match[2].includes('(')
    });
  }
}

const candidates = [];
for (const decl of declarations) {
  // ⚠️ 判定必须**限定在声明所在文件内**：private/protected 只能被同类访问，而本工程一类一文件。
  // 按全工程计数会被别的文件里的同名成员洗白 —— 实测首版就是这么漏掉
  // `SessionDetailStore.pending` 的（被 `AttachmentStore.pending` 的 8 次使用洗掉）。
  const rows = sources.get(decl.file).split(/\r?\n/);
  let used = 0;
  for (let i = 0; i < rows.length; i++) {
    if (i === decl.line - 1) { continue; }
    used += countWord(rows[i], decl.name);
  }
  if (used === 0) {
    candidates.push(decl);
  }
}

const byFile = new Map();
for (const c of candidates) {
  const rel = c.file.slice(ROOT.length).replace(/\\/g, '/');
  if (!byFile.has(rel)) { byFile.set(rel, []); }
  byFile.get(rel).push(c);
}

if (JSON_OUT) {
  console.log(JSON.stringify(candidates.map((c) => ({
    file: c.file.slice(ROOT.length + 1), line: c.line, name: c.name, text: c.text
  })), null, 2));
} else {
  console.log('== 类内私有成员零使用候选（' + candidates.length + '）==');
  for (const [rel, list] of byFile.entries()) {
    console.log('  ' + rel);
    for (const c of list) {
      console.log('     :' + c.line + '  ' + c.text);
    }
  }
  console.log('');
  console.log('共扫描 ' + files.length + ' 个源文件（不含 ui/），私有成员声明 ' + declarations.length + ' 条。');
}
