#!/usr/bin/env node
// aa-hm 模块级本地声明零使用扫描器（R43 精简轮新增）
//
// 为什么需要它：既有两个扫描器都不覆盖这一格 ——
//   - tools/dead-code-scan.mjs 只看 export 出去的东西（导入面）；
//   - tools/private-member-scan.mjs 只看 class 内 private/protected 成员。
// 于是「模块顶层、没有 export 的 function / const / interface 零使用」不会被任何工具报出来
// （R43 实测：一次扫出 8 条候选，其中 3 条是真死代码）。
//
// 用法：node tools/local-decl-scan.mjs [--json]
//
// 判据（写在这里，避免下一个人重新猜）：
// - 只认**行首无缩进**的顶层声明：function / const / let / class / interface / type / enum；
//   带 export 的不算（交给 dead-code-scan.mjs，避免两个工具重复报同一件事）。
// - 「零使用」= 该标识符在**声明所在文件内**（排除声明行本身）的词边界计数为 0。
//   为什么限定文件内：非导出声明只在本模块可见，按全工程计数会被别的文件里的同名符号洗白
//   （与 private-member-scan.mjs 同理 —— 那边实测被别的类的同名成员洗掉过一条真死字段）。
// - D1 = 代码内零使用 **且** tools/ 脚本里也零文本引用 ⇒ 真死代码候选。
// - D2 = 代码内零使用，但 tools/**.mjs 里有同名文本 ⇒ **不能直接删**：
//   本工程的逻辑 suite 会用正则断言源码文本（实例：suite-settings.mjs 断言 EntryAbility.ets 的
//   CANVAS_COLOR_LIGHT 声明）。但同名不等于同一物（suite 里的 runtimeStatusLabel 指的是
//   model/ 里的那个，不是 ui/screens/NewSessionScreen.ets 里的本地函数），所以 D2 会列出
//   命中的脚本名，由人裁决。
// - 方向是安全的一侧：注释、字符串、类型注解里的同名文本都算「有人用」（漏报，不误删）。
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

// tools/ 下的脚本会读源码文本做断言，必须一起算（详见文件头 D2 说明）。
const toolsFiles = walkExt(join(ROOT, 'tools'), ['.mjs', '.js'], []);
const toolTexts = toolsFiles.map((f) => ({
  name: relative(ROOT, f).replace(/\\/g, '/'),
  text: readFileSync(f, 'utf8')
}));

const DECL_RE = /^(?!export)(?:declare\s+)?(?:abstract\s+)?(function|const|let|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)/gm;

function countWord(text, word) {
  const re = new RegExp('\\b' + word.replace(/[$]/g, '\\$') + '\\b', 'g');
  const found = text.match(re);
  return found === null ? 0 : found.length;
}

const d1 = [];
const d2 = [];
let declarations = 0;

for (const [file, text] of sources) {
  const rel = relative(ROOT, file).replace(/\\/g, '/');
  const rows = text.split(/\r?\n/);
  let m;
  DECL_RE.lastIndex = 0;
  while ((m = DECL_RE.exec(text)) !== null) {
    declarations++;
    const kind = m[1];
    const name = m[2];
    const declLine = text.slice(0, m.index).split('\n').length;
    if (name === 'constructor') { continue; }
    let selfUses = 0;
    for (let i = 0; i < rows.length; i++) {
      if (i === declLine - 1) { continue; }
      selfUses += countWord(rows[i], name);
    }
    if (selfUses > 0) { continue; }
    const hits = [];
    for (const t of toolTexts) {
      if (countWord(t.text, name) > 0) { hits.push(t.name); }
    }
    if (hits.length === 0) {
      d1.push({ file: rel, line: declLine, kind: kind, name: name });
    } else {
      d2.push({ file: rel, line: declLine, kind: kind, name: name, hits: hits });
    }
  }
}

if (JSON_OUT) {
  console.log(JSON.stringify({ realDead: d1, toolLocked: d2 }, null, 2));
} else {
  console.log('== D1. 模块级本地声明零使用（真死代码候选，' + d1.length + '）==');
  for (const d of d1) console.log('  ' + d.file + ':' + d.line + '  ' + d.kind + ' ' + d.name);
  console.log('');
  console.log('== D2. 代码内零使用，但 tools/ 里有同名文本（测试锁定，先核对再动，' + d2.length + '）==');
  for (const d of d2) console.log('  ' + d.file + ':' + d.line + '  ' + d.kind + ' ' + d.name + '  <- ' + d.hits.join(', '));
  console.log('');
  console.log('共扫描 ' + files.length + ' 个源文件，顶层本地声明 ' + declarations + ' 条。');
}
