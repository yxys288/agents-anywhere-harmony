#!/usr/bin/env node
// aa-hm 代码精简扫描器（R38 新增）
//
// 目的：为「精简代码（去除冗余代码）」提供**可复核的候选清单**，而不是直接删。
// 只报两类：① 导出但全工程零引用的符号；② import 了但文件内未使用的符号。
// 误报由人工复核 —— 本工具给的是线索，不是结论。
//
// 用法：node tools/dead-code-scan.mjs [--json]
//
// 判据说明（写在代码里，避免下一个人重新猜）：
// - 「零引用」= 除定义文件外，全工程没有任何 .ets 以词边界出现该标识符。
// - ArkTS 的 @Component struct / @Builder 不是普通函数，扫描器**不**判断它们是否被渲染，
//   只判断标识符有没有被引用；没被引用的报出来由人确认是不是死代码。
// - 类型注解、字符串里的同名文本都可能造成「假引用」（漏报死代码），
//   所以本工具**只会漏报、不会误删**，方向是安全的一侧。
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\//, '');
const SRC = join(ROOT, 'entry', 'src', 'main', 'ets');
const JSON_OUT = process.argv.includes('--json');

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
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

const files = walk(SRC, []);
const sources = new Map();
for (const f of files) {
  sources.set(f, readFileSync(f, 'utf8'));
}

// 消费者：tools/ 下的脚本 —— 逻辑自测 suite 会 import 源码模块并引用导出符号。
// 不把它们算进引用计数，「测试专用导出」会被整片误报成死代码
// （R38 实测：首版没算 consumers，39 条候选里大半是 suite 正在用的符号）。
const consumers = walkExt(join(ROOT, 'tools'), ['.mjs', '.js'], [])
  .map((f) => readFileSync(f, 'utf8'));

const EXPORT_RE = /^export\s+(?:default\s+)?(?:abstract\s+)?(function|const|let|class|interface|type|struct|enum)\s+([A-Za-z_$][\w$]*)/gm;
const IMPORT_RE = /^import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/gm;

function stripImports(text) {
  return text.replace(IMPORT_RE, '');
}

function countWord(haystack, word) {
  const re = new RegExp('(^|[^A-Za-z0-9_$])' + word.replace(/[$]/g, '\\$') + '([^A-Za-z0-9_$]|$)', 'g');
  let n = 0;
  while (re.exec(haystack) !== null) n++;
  return n;
}

const deadExports = [];
const internalOnlyExports = [];
const unusedImports = [];

for (const [file, text] of sources) {
  const rel = relative(ROOT, file).replace(/\\/g, '/');
  const body = stripImports(text);
  let m;
  EXPORT_RE.lastIndex = 0;
  while ((m = EXPORT_RE.exec(text)) !== null) {
    const kind = m[1];
    const name = m[2];
    // 定义处本身会匹配一次，减掉它才是「使用次数」。
    const selfUses = countWord(body, name) - 1;
    let otherUses = 0;
    for (const [other, otherText] of sources) {
      if (other === file) continue;
      otherUses += countWord(otherText, name);
    }
    for (const consumerText of consumers) {
      otherUses += countWord(consumerText, name);
    }
    if (selfUses + otherUses === 0) {
      // 全工程（含定义文件）都没用过 ⇒ 真死代码候选。
      deadExports.push({ file: rel, kind, name });
    } else if (otherUses === 0) {
      // 只在自己文件里用 ⇒ 死不了，但 export 是多余的（可降级为模块私有）。
      internalOnlyExports.push({ file: rel, kind, name, selfUses });
    }
  }
  IMPORT_RE.lastIndex = 0;
  while ((m = IMPORT_RE.exec(text)) !== null) {
    // ⚠️ 先剥行注释再按逗号切：多行 import 里常夹着说明注释，
    // 不剥的话注释文字会被当成符号名（R38 首版就误报了 3 条）。
    const cleaned = m[1].split('\n').map((line) => {
      const idx = line.indexOf('//');
      return idx >= 0 ? line.slice(0, idx) : line;
    }).join(' ');
    const names = cleaned.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
    for (const raw of names) {
      const alias = raw.includes(' as ') ? raw.split(' as ')[1].trim() : raw;
      if (alias.length === 0) continue;
      if (countWord(body, alias) === 0) unusedImports.push({ file: rel, name: alias, from: m[2] });
    }
  }
}

if (JSON_OUT) {
  console.log(JSON.stringify({ deadExports, internalOnlyExports, unusedImports }, null, 2));
} else {
  console.log('== A. 全工程零使用（真死代码候选，' + deadExports.length + '）==');
  for (const d of deadExports) console.log('  ' + d.file + '  ' + d.kind + ' ' + d.name);
  console.log('');
  console.log('== B. 只在本文件内使用（export 多余，' + internalOnlyExports.length + '）==');
  for (const d of internalOnlyExports) console.log('  ' + d.file + '  ' + d.kind + ' ' + d.name + '  (自用 ' + d.selfUses + ' 次)');
  console.log('');
  console.log('== C. import 了但文件内未使用（' + unusedImports.length + '）==');
  for (const u of unusedImports) console.log('  ' + u.file + '  ' + u.name + '  <- ' + u.from);
  console.log('');
  console.log('共扫描 ' + files.length + ' 个源文件。');
}