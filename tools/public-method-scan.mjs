#!/usr/bin/env node
// aa-hm 类内 public 方法零调用扫描器（R43 精简轮新增）
//
// 为什么需要它：三个既有扫描器都不覆盖这一格 ——
//   - tools/dead-code-scan.mjs 只看 export 出去的东西（导入面）；
//   - tools/private-member-scan.mjs 只看 private/protected 成员；
//   - tools/local-decl-scan.mjs 只看**模块顶层**的非导出声明。
// 于是「public 方法、全工程没人调用」不会被任何工具报出来。R39 曾用一次性脚本删过 26 个；
// 本工具把那次的判据固化下来（R43 实测：非 ui/ 的 433 条 public 方法里有 8 条真零调用）。
//
// 用法：node tools/public-method-scan.mjs [--json]
//
// 判据（写在这里，避免下一个人重新猜）：
// - 只扫 entry/src/main/ets 下**非 ui/** 的 .ets，且文件里出现过 class 声明。
//   为什么排除 ui/：那里是 struct 世界，方法（build / aboutToAppear / @Builder 等）由 ArkUI 框架调用，
//   文本零引用属正常 —— 与 private-member-scan.mjs 同一条口径。
// - 只认**恰好 2 空格缩进**的 `name(` 方法声明：4 空格（嵌套类）与 getter/setter 都不匹配；
//   private/protected/constructor 不纳入（前者归 private-member-scan.mjs）。
// - 生命周期白名单（aboutToAppear / onPageShow / onDestroy / onCreate / onForeground ...）直接跳过：
//   它们由框架或系统调用，零文本引用是设计使然。
// - 「零调用」= ① 本文件外（含 ui/**）零词边界命中；② 本文件内除声明行外零命中；
//   两条同时成立才算候选。
// - E1 = tools/**.mjs 里也零命中 ⇒ 真死代码候选；
//   E2 = tools/**.mjs 里有同名命中 ⇒ **不能直接删**（可能是 suite 正在调用的测试专用 API，
//        也可能是同名不同物），列出来由人裁决。
// - 方向是安全的一侧：注释、字符串、同名符号都会算成「有人用」（漏报，不误删）。
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\//, '');
const SRC = join(ROOT, 'entry', 'src', 'main', 'ets');
const JSON_OUT = process.argv.includes('--json');

const LIFECYCLE = new Set(['aboutToAppear', 'aboutToDisappear', 'onPageShow', 'onPageHide',
  'onBackPress', 'onCreate', 'onDestroy', 'onWindowStageCreate', 'onWindowStageDestroy',
  'onForeground', 'onBackground', 'onNewWant', 'onConfigurationUpdate', 'build', 'onChange']);

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

function walkExt(dir, exts, out) {
  let entries = [];
  try {
    entries = readdirSync(dir);
  } catch (error) {
    return out;
  }
  for (const name of entries) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      walkExt(full, exts, out);
    } else if (exts.some((e) => name.endsWith(e))) {
      out.push(full);
    }
  }
  return out;
}

function walkAll(dir, out) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      walkAll(full, out);
    } else if (name.endsWith('.ets') || name.endsWith('.ts')) {
      out.push(full);
    }
  }
  return out;
}

const scoped = walk(SRC, []).filter((f) => /\bclass\s/.test(readFileSync(f, 'utf8')));
const everything = walkAll(SRC, []).map((f) => readFileSync(f, 'utf8'));
const toolTexts = walkExt(join(ROOT, 'tools'), ['.mjs', '.js'], []).map((f) => ({
  name: relative(ROOT, f).replace(/\\/g, '/'),
  text: readFileSync(f, 'utf8')
}));

const METHOD_RE = /^  (?!private |protected |constructor|static private |static protected )([A-Za-z_$][\w$]*)\s*\(/gm;

function countWord(text, word) {
  const re = new RegExp('\\b' + word.replace(/[$]/g, '\\$') + '\\b', 'g');
  const found = text.match(re);
  return found === null ? 0 : found.length;
}

const e1 = [];
const e2 = [];
let declarations = 0;

for (const file of scoped) {
  const text = readFileSync(file, 'utf8');
  const rel = relative(ROOT, file).replace(/\\/g, '/');
  const rows = text.split(/\r?\n/);
  let m;
  METHOD_RE.lastIndex = 0;
  while ((m = METHOD_RE.exec(text)) !== null) {
    const name = m[1];
    if (LIFECYCLE.has(name)) { continue; }
    declarations++;
    const declLine = text.slice(0, m.index).split('\n').length;
    let outside = 0;
    for (const other of everything) {
      if (other === text) { continue; }
      outside += countWord(other, name);
    }
    if (outside > 0) { continue; }
    let inner = 0;
    for (let i = 0; i < rows.length; i++) {
      if (i === declLine - 1) { continue; }
      inner += countWord(rows[i], name);
    }
    if (inner > 0) { continue; }
    const hits = [];
    for (const t of toolTexts) {
      if (t.name.endsWith('public-method-scan.mjs')) { continue; }
      if (countWord(t.text, name) > 0) { hits.push(t.name); }
    }
    if (hits.length === 0) {
      e1.push({ file: rel, line: declLine, name: name });
    } else {
      e2.push({ file: rel, line: declLine, name: name, hits: hits });
    }
  }
}

if (JSON_OUT) {
  console.log(JSON.stringify({ realDead: e1, toolReferenced: e2 }, null, 2));
} else {
  console.log('== E1. public 方法零调用（真死代码候选，' + e1.length + '）==');
  for (const d of e1) console.log('  ' + d.file + ':' + d.line + '  ' + d.name + '()');
  console.log('');
  console.log('== E2. public 方法零调用，但 tools/ 里有同名（测试专用 API，先核对再动，' + e2.length + '）==');
  for (const d of e2) console.log('  ' + d.file + ':' + d.line + '  ' + d.name + '()  <- ' + d.hits.join(', '));
  console.log('');
  console.log('共扫描 ' + scoped.length + ' 个含 class 的源文件（不含 ui/），public 方法声明 ' + declarations + ' 条。');
}
