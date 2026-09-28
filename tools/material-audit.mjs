#!/usr/bin/env node
/**
 * 材质接入点审计（T2 / task-1）—— 扫出「谁在自绘材质」，供「官方材质接入点清单」使用。
 *
 * 用法：node tools/material-audit.mjs [--json] [--json-popups] [--all] [--check]
 *   · 缺省只统计**代码行**（`//`、`*`、`/*` 开头的行不计）；
 *   · `--all` 连注释行一起统计；
 *   · `--json` 输出令牌行数组（形状未变）；`--json-popups` 输出弹窗类接入点数组；
 *   · `--check` 追加一处**判据**：弹窗类接入点「未接 / 实参不对」时退出码 1（缺省只报数、退出码 0）。
 *
 * 输出：① 每行 `文件 | 行号 | struct | @Builder | 令牌`，末尾按令牌计数（R84 原口径，未改动）；
 *       ② R86-E 扩展：**弹窗类接入点审计**（`bindSheet` / `bindPopup` / `showAlertDialog` 各自
 *          「接了 systemMaterial 的处数 vs 未接处数」，并列出 options 来源、实参表达式、
 *          内容根与内容根上的自绘令牌）—— 供材质接入点清单的决策表逐点对账。
 *
 * 判据（自我约束，不是装饰）：
 *   · 自绘层令牌 = backgroundEffect / linearGradient / radialGradient / .shadow / backgroundBlurStyle / backdropBlur；
 *   · 官方材质令牌 = systemMaterial( / officialBarMaterial( ;
 *   · 玻璃令牌 = glassSurface / glassCardSurface / glassNavSurface / glassIconSurface / glassPanelSurface。
 *
 * ⚠️ 本工具**只读源码**，不做任何判定结论 —— 一个自绘层落在 `Navigation.title(...)` 构造器里
 *    是该被替换的，落在页面正文里则是**应当保留的回退**（官方材质有生效范围约束）。
 *    「在不在生效范围」由人按 `@Builder` 名字与调用点判定，不在这里猜。
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(HERE, '..', 'entry', 'src', 'main', 'ets');

const SELF_DRAWN = ['backgroundEffect(', 'linearGradient(', 'radialGradient(', '.shadow(',
  'backgroundBlurStyle(', 'backdropBlur('];
const OFFICIAL = ['systemMaterial(', 'officialBarMaterial('];
const GLASS_TOKENS = ['glassSurface()', 'glassCardSurface()', 'glassNavSurface()',
  'glassIconSurface()', 'glassPanelSurface()'];
const OPT_IN = ['officialMaterial:', 'officialMaterial: true', 'officialMaterial: false'];

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { out.push(...walk(p)); } else if (e.name.endsWith('.ets')) { out.push(p); }
  }
  return out;
}

/** 逐行扫描；同时维护「当前 struct」与「当前 @Builder」两个上下文锚。 */
export function scan(root = SRC, includeComments = false) {
  const rows = [];
  for (const file of walk(root)) {
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    let struct = '';
    let builder = '';
    let depth = 0;          // 花括号深度（粗算：只数 {}，忽略字符串里的括号 —— 本工程源码无此形态）
    let builderStart = 0;   // 当前 @Builder 起始处的深度
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const sm = line.match(/^\s*(?:@Component\s*)?(?:export\s+)?struct\s+(\w+)/);
      if (sm) { struct = sm[1]; builder = ''; depth = 0; }
      // ⚠️ 归属必须按**花括号深度**收敛：只在「下一个 @Builder」处重置会让上一个 builder 的名字
      //    一直粘到后续若干行（第一版就踩了，会导致清单里归错位）。这里记录该 @Builder 的起始深度，
      //    深度回到起点即视为该 builder 结束。
      if (builder !== '' && depth < builderStart) { builder = ''; }
      if (/^\s*@Builder\s*$/.test(line)) {
        for (let j = i + 1; j < lines.length; j++) {
          const bm = lines[j].match(/^\s*(\w+)\s*\(/);
          if (bm) { builder = bm[1]; builderStart = depth; break; }
          if (lines[j].trim().length > 0) { break; }
        }
      }
      // 缺省只统计**代码行**：注释里的同名令牌不算（与工程既有 suite 的 `codeLines()` 同一口径）。
      // 传 `--all` 才把注释行也算进来（复核注释里提到的旧口径时用）。
      const trimmed = line.trim();
      const isComment = trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*');
      const rel = path.relative(root, file).replace(/\\/g, '/');
      if (isComment && !includeComments) { depth += (line.split('{').length - 1) - (line.split('}').length - 1); continue; }
      const push = (token) => rows.push({
        file: rel, line: i + 1, struct, builder, token, text: trimmed
      });
      for (const t of SELF_DRAWN) { if (line.includes(t)) { push(t); } }
      for (const t of OFFICIAL) { if (line.includes(t)) { push(t); } }
      for (const t of GLASS_TOKENS) { if (line.includes(t)) { push(t); } }
      if (line.includes('.systemMaterial(')) { /* 已由 OFFICIAL 覆盖 */ }
      for (const t of OPT_IN) { if (line.includes(t)) { push(t); } }
      depth += (line.split('{').length - 1) - (line.split('}').length - 1);
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------
// R86-E：弹窗类接入点审计（A4 `bindSheet` / A6·A7 `bindPopup` / A12 `showAlertDialog`）
// ---------------------------------------------------------------------------
/**
 * ## 为什么单独做这一层（而不是复用上面的令牌行扫描）
 * 上面那张表回答的是「**谁在自绘 / 谁挂了材质**」，是**逐行令牌**视角；
 * 契约 §2 决策表要的是「**每个弹窗类调用点各自接没接**」—— 同一处 `bindPopup` 的
 * `systemMaterial` 写在**另一个方法返回的 options 对象**里（本工程 16 处全是这个形态），
 * 逐行令牌表看不出来「这一处接了、那一处没接」。
 *
 * ## 判定口径（可复跑、可反驳）
 * · 注释：本层用**完整状态机**剥注释（行首 + 行尾 + 块注释），比上面的「行首注释」更严
 *   —— 本层要按**括号取实参**，行尾注释里的同名令牌会污染判定；
 *   两种口径的处数一并打印，**不一致即报**（见 `口径分歧` 行）。
 * · `bindSheet(cond, builder, { …options })` → options = 第 **3** 个实参（内联对象）；
 * · `bindPopup(cond, this.xxxPopupOptions())` → options = 第 **2** 个实参，若形态是
 *   `this.<方法>()` 则到**同文件**取该方法的 `return { … }` 对象（取不到就记 `未解析`，不放过）；
 * · `.showAlertDialog({ …options })` → options = 第 **1** 个实参。
 * · `hasField` = options 对象里出现 `systemMaterial:`；`ok` = 出现**且**实参含期望的构造函数
 *   （`bindSheet` → `panelMaterial(`；`bindPopup` → `dialogMaterial(`；`showAlertDialog` → 只要有字段）。
 * · 本层**只做机器计数**：它不判断「该不该接」（那由契约的生效范围决定），也不声称真机生效。
 */
export const POPUP_SPECS = [
  { kind: 'bindSheet', re: /\.bindSheet\s*\(/g, argIndex: 2, expect: 'panelMaterial(',
    scope: 'A4 SheetOptions.systemMaterial @ common.d.ts:12155' },
  { kind: 'bindPopup', re: /\.bindPopup\s*\(/g, argIndex: 1, expect: 'dialogMaterial(',
    scope: 'A6/A7 CustomPopupOptions.systemMaterial @ common.d.ts:14406 / 12966 / 13824' },
  { kind: 'showAlertDialog', re: /\.showAlertDialog\s*\(/g, argIndex: 0, expect: '',
    scope: 'A12 AlertDialog 参数 @ alert_dialog.d.ts:894' },
];
/** 内容根上的「自绘层」令牌（与契约 §1 约束 2 同一组）。 */
export const POPUP_SELF_DRAWN = ['backgroundEffect(', 'backgroundColor(', '.borderColor(',
  '.borderWidth(', '.shadow(', 'backgroundBlurStyle(', 'backdropBlur(', 'linearGradient(', 'radialGradient('];
/** options 对象里的「底/描边/投影」字段（**登记用，不作判据** —— 契约 #3 明确允许保留 `blurStyle`）。 */
const OPTION_PAINT_FIELDS = ['popupColor:', 'backgroundBlurStyle:', 'shadow:', 'blurStyle:',
  'backgroundColor:', 'borderWidth:', 'borderColor:'];

/**
 * 把注释替换成**等长空白**（保留换行 ⇒ 行号与偏移不变）。
 * 手写状态机而非正则：要跳过字符串字面量里的 `//`（如 `'https://…'`）与模板串。
 */
export function stripComments(text) {
  let out = '';
  let state = 'code';
  const close = { sq: "'", dq: '"', bt: '`' };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const d = text[i + 1];
    if (state === 'code') {
      if (c === '/' && d === '/') { state = 'line'; out += '  '; i += 1; continue; }
      if (c === '/' && d === '*') { state = 'block'; out += '  '; i += 1; continue; }
      if (c === "'" || c === '"' || c === '`') { state = c === "'" ? 'sq' : (c === '"' ? 'dq' : 'bt'); }
      out += c; continue;
    }
    if (state === 'line') { out += (c === '\n') ? '\n' : ' '; if (c === '\n') { state = 'code'; } continue; }
    if (state === 'block') {
      if (c === '*' && d === '/') { out += '  '; i += 1; state = 'code'; continue; }
      out += (c === '\n') ? '\n' : ' '; continue;
    }
    // 字符串态：反斜杠转义整体跳过；换行（未闭合兜底）回代码态
    if (c === '\\') { out += c + (d === undefined ? '' : d); i += 1; continue; }
    if (c === close[state]) { state = 'code'; }
    else if (c === '\n') { state = 'code'; }
    out += c;
  }
  return out;
}
/** 从 `(` 的下标起，取到配平 `)` 为止的**实参文本**。 */
export function callArgs(code, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < code.length; i++) {
    const c = code[i];
    if (c === '(') { depth += 1; } else if (c === ')') {
      depth -= 1;
      if (depth === 0) { return code.slice(openIdx + 1, i); }
    }
  }
  return '';
}
/** 顶层逗号切分（括号/方括号/花括号深度 + 字符串态）。 */
export function splitTopLevel(text) {
  const out = [];
  let depth = 0;
  let cur = '';
  let state = 'code';
  const close = { sq: "'", dq: '"', bt: '`' };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (state === 'code') {
      if (c === "'" || c === '"' || c === '`') { state = c === "'" ? 'sq' : (c === '"' ? 'dq' : 'bt'); }
      else if (c === '(' || c === '[' || c === '{') { depth += 1; }
      else if (c === ')' || c === ']' || c === '}') { depth -= 1; }
      else if (c === ',' && depth === 0) { out.push(cur); cur = ''; continue; }
    } else {
      if (c === '\\') { cur += c + (text[i + 1] === undefined ? '' : text[i + 1]); i += 1; continue; }
      if (c === close[state] || c === '\n') { state = 'code'; }
    }
    cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim());
}
/** 取第一个 `{` 起到配平 `}` 的对象字面量文本。 */
export function firstObject(text) {
  const open = text.indexOf('{');
  if (open < 0) { return ''; }
  let depth = 0;
  let state = 'code';
  const close = { sq: "'", dq: '"', bt: '`' };
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (state === 'code') {
      if (c === "'" || c === '"' || c === '`') { state = c === "'" ? 'sq' : (c === '"' ? 'dq' : 'bt'); }
      else if (c === '{') { depth += 1; }
      else if (c === '}') { depth -= 1; if (depth === 0) { return text.slice(open, i + 1); } }
    } else {
      if (c === '\\') { i += 1; continue; }
      if (c === close[state] || c === '\n') { state = 'code'; }
    }
  }
  return '';
}
/** 同文件里按名字取方法体（`@Builder name()` / `private name(): T {` 两种形态）。 */export function methodBody(code, name) {
  const re = new RegExp('(?:^|\\n)[ \\t]*(?:@Builder[ \\t]*\\n[ \\t]*)?(?:export[ \\t]+)?'
    + '(?:private[ \\t]+|public[ \\t]+|protected[ \\t]+|static[ \\t]+)?' + name + '[ \\t]*\\(');
  const m = re.exec(code);
  if (!m) { return ''; }
  const rest = code.slice(m.index + m[0].length);
  // 跳过参数表与返回类型：参数表里可能有 `{}`，所以先配平 `()` 再从其后找第一个 `{`
  const closeParen = rest.indexOf(')');
  if (closeParen < 0) { return ''; }
  const after = rest.slice(closeParen + 1);
  const openBrace = after.indexOf('{');
  if (openBrace < 0) { return ''; }
  let depth = 0;
  for (let i = openBrace; i < after.length; i++) {
    if (after[i] === '{') { depth += 1; } else if (after[i] === '}') {
      depth -= 1;
      if (depth === 0) { return after.slice(openBrace, i + 1); }
    }
  }
  return '';
}
/**
 * 取 `@Builder` 函数体里**根节点自己的属性链**（不含子节点的属性）。
 *
 * 为什么必须单独做：内容根的「谁在画底」只看根节点的链 —— `Row(){ … }.backgroundColor(x)` 里的
 * `.backgroundColor(x)` 若长在**子节点**（图标底、行底）上，与「内容根的底」是两件事。
 * 第一版直接扫整个 builder 体，会把 `FilesScreen#rowMenuCard` 里图标方块的
 * `.backgroundColor(subtle())` 误报成「内容根仍有自绘底」（**假阳性** ⇒ 断言会假红）。
 *
 * 形态：`{ Column(){ …子节点… }.width(…).backgroundColor(…) }`
 *      → 取根组件名后的 `(参数)` 与 children `{}`，**其后**留在 builder 体里的就是根节点属性链。
 * 根节点是 `if` / `ForEach` 等非组件形态时返回 ''（本工程的弹层内容根都是组件）。
 */
export function rootChain(body) {
  if (body.length < 2 || body[0] !== '{') { return ''; }
  const inner = body.slice(1, -1);
  const m = /^\s*([A-Za-z_$][\w$]*)/.exec(inner);
  if (m === null) { return ''; }
  let i = m[0].length;
  const skipSpace = () => { while (i < inner.length && /\s/.test(inner[i])) { i += 1; } };
  skipSpace();
  if (inner[i] === '(') {                       // 跳过组件参数表（内部可能有 `{}`）
    let d = 0;
    for (; i < inner.length; i += 1) {
      if (inner[i] === '(') { d += 1; } else if (inner[i] === ')') { d -= 1; if (d === 0) { i += 1; break; } }
    }
  }
  skipSpace();
  if (inner[i] !== '{') { return ''; }          // 没有 children 块 ⇒ 没有可判定的属性链
  let d = 0;
  for (; i < inner.length; i += 1) {
    if (inner[i] === '{') { d += 1; } else if (inner[i] === '}') { d -= 1; if (d === 0) { i += 1; break; } }
  }
  return inner.slice(i);
}

/**
 * 把一条根链切成**逐属性**片段（在 `()`/`[]`/`{}` 深度为 0 的 `.` 处切）。
 *
 * 为什么必须逐属性：只看「整条链里有没有门控」会**假绿** —— 把
 * `.backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : 原值)` 偷偷改回
 * `.backgroundColor(原值)`，只要同链上的 `.borderWidth(immersiveMaterialEnabled() ? …)` 还在，
 * 链级判定就仍然算「已门控」。**这是 R86-E 变异测试实测出来的洞（M2：链级判定没变红）。**
 */
export function splitChainAttrs(chain) {
  const out = [];
  let cur = '';
  let depth = 0;
  let state = 'code';
  const close = { sq: "'", dq: '"', bt: '`' };
  for (let i = 0; i < chain.length; i++) {
    const c = chain[i];
    if (state === 'code') {
      if (c === "'" || c === '"' || c === '`') { state = c === "'" ? 'sq' : (c === '"' ? 'dq' : 'bt'); }
      else if (c === '(' || c === '[' || c === '{') { depth += 1; }
      else if (c === ')' || c === ']' || c === '}') { depth -= 1; }
      else if (c === '.' && depth === 0) {
        if (cur.trim().length > 0) { out.push(cur.trim()); }
        cur = '';
        continue;
      }
    } else {
      if (c === '\\') { cur += c + (chain[i + 1] === undefined ? '' : chain[i + 1]); i += 1; continue; }
      if (c === close[state] || c === '\n') { state = 'code'; }
    }
    cur += c;
  }
  if (cur.trim().length > 0) { out.push(cur.trim()); }
  return out;
}

/** 探针别名：`const gate = … immersiveMaterialEnabled(…)` 这种「提升成局部布尔」的合法写法也算门控。 */
function gateAliasesOf(code) {
  const out = [];
  const re = /(?:const|let)[ \t]+(\w+)[^;\n]*=[^;\n]*immersiveMaterialEnabled[ \t]*\(/g;
  let m;
  while ((m = re.exec(code)) !== null) { out.push(m[1]); }
  return out;
}

/** 行首注释口径的处数（与上面的状态机口径交叉核对；两口径应当相等）。 */
function lineStartCommentCount(root, spec) {
  let n = 0;
  for (const file of walk(root)) {
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const t = line.trim();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) { continue; }
      if (new RegExp(spec.re.source).test(line)) { n += 1; }
    }
  }
  return n;
}

/** 弹窗类接入点审计主函数（只读源码，返回记录数组）。 */
export function auditPopups(root = SRC) {
  const out = [];
  for (const file of walk(root)) {
    const raw = fs.readFileSync(file, 'utf8');
    const rawLines = raw.split(/\r?\n/);
    const code = stripComments(raw);
    const rel = path.relative(root, file).replace(/\\/g, '/');
    for (const spec of POPUP_SPECS) {
      const re = new RegExp(spec.re.source, 'g');
      let m;
      while ((m = re.exec(code)) !== null) {
        const openIdx = code.indexOf('(', m.index);
        const args = splitTopLevel(callArgs(code, openIdx));
        const optRaw = args[spec.argIndex] === undefined ? '' : args[spec.argIndex];
        const line = code.slice(0, m.index).split('\n').length;
        const rec = {
          file: rel, line, kind: spec.kind, scope: spec.scope, expect: spec.expect,
          optionsFrom: 'inline', optionsResolved: true, optionsText: optRaw,
          hasField: false, materialExpr: '', ok: false, paintFields: [],
          builderRef: '', contentRoot: '', contentResolved: false,
          contentSelfDrawn: [], rootSelfDrawn: [], rootAttrs: [], rootUngatedSelfDrawn: [],
          contentGated: false, contentComponentMaterial: false,
          text: (rawLines[line - 1] || '').trim(),
        };
        const call = optRaw.match(/^this\.(\w+)\s*\(\s*\)$/);
        if (call) {
          rec.optionsFrom = 'method:' + call[1];
          const body = methodBody(code, call[1]);
          if (body === '') { rec.optionsResolved = false; } else {
            const ret = body.indexOf('return');
            rec.optionsText = ret >= 0 ? firstObject(body.slice(ret)) : firstObject(body);
            if (rec.optionsText === '') { rec.optionsResolved = false; rec.optionsText = body; }
          }
        } else if (optRaw.startsWith('{')) {
          rec.optionsText = firstObject(optRaw);
        } else if (optRaw === '') {
          rec.optionsResolved = false;
        }
        const fm = rec.optionsText.match(/systemMaterial\s*:\s*([^,\n}]+)/);
        rec.hasField = fm !== null;
        rec.materialExpr = fm === null ? '' : fm[1].trim();
        rec.ok = rec.hasField && (spec.expect === '' || rec.materialExpr.indexOf(spec.expect) >= 0);
        rec.paintFields = OPTION_PAINT_FIELDS.filter((t) => rec.optionsText.indexOf(t) >= 0);
        // 内容根：**只对 bindSheet / bindPopup 取**（`showAlertDialog` 的参数对象里没有 builder，
        // 硬取会把按钮回调里的 `this.createShare(...)` 误当成内容根 —— 第一版就踩了）。
        if (spec.kind !== 'showAlertDialog') {
          const contentExpr = spec.kind === 'bindSheet' ? args[1] : rec.optionsText;
          // 优先取 `builder: () => { this.xxx(); }` 里的那一个；取不到再退回「options 里第一个 this.x()」。
          const bm = contentExpr === undefined ? null
            : (contentExpr.match(/builder\s*:\s*\([^)]*\)\s*=>\s*\{\s*this\.(\w+)\s*\(/)
              || contentExpr.match(/this\.(\w+)\s*\(/));
          if (bm !== null) {
            rec.builderRef = bm[1];
            const body = methodBody(code, bm[1]);
            if (body !== '') {
              rec.contentResolved = true;
              rec.contentSelfDrawn = POPUP_SELF_DRAWN.filter((t) => body.indexOf(t) >= 0);
              const chain = rootChain(body);
              rec.contentRoot = chain;
              rec.rootSelfDrawn = POPUP_SELF_DRAWN.filter((t) => chain.indexOf(t) >= 0);
              rec.rootAttrs = splitChainAttrs(chain);
              // R86 口径（Lead 2026-09-25 明确）：内容根的自绘层是**门控**不是删除 ——
              // 探针可用 ⇒ 零自绘层；不可用 ⇒ 逐字回到 R86 前的自绘玻璃。
              // 判定**逐属性**做（链级会让「只放回一个属性」假绿，见 splitChainAttrs 注释）。
              const aliases = gateAliasesOf(code);
              const gated = (seg) => seg.indexOf('immersiveMaterialEnabled(') >= 0
                || aliases.some((a) => new RegExp('[^\\w.]' + a + '[^\\w]').test(seg));
              rec.rootUngatedSelfDrawn = [];
              // ⚠️ 逐属性匹配必须把令牌的**前导 `.` 去掉**：`splitChainAttrs()` 是在深度 0 的 `.` 处切分的，
              //    那一个点被吃掉 ⇒ 用 `.borderWidth(` 去 indexOf 永远不命中（第二版踩的坑：
              //    M8 变异把 borderWidth 的门控换成底层 API 时，A6 没报，只有 A7 报了）。
              const bare = (t) => (t.startsWith('.') ? t.slice(1) : t);
              for (const seg of rec.rootAttrs) {
                const tokens = POPUP_SELF_DRAWN.filter((t) => seg.indexOf(bare(t)) >= 0);
                if (tokens.length > 0 && !gated(seg)) {
                  rec.rootUngatedSelfDrawn.push(tokens.join('+') + ' :: ' + seg.slice(0, 80));
                }
              }
              rec.contentGated = rec.rootAttrs.some((seg) => gated(seg));
              rec.contentComponentMaterial = chain.indexOf('systemMaterial(') >= 0;
            }
          }
        }
        out.push(rec);
      }
    }
  }
  return out;
}

// 被别的脚本 import 时**不许**产生输出：只有直接执行才跑 CLI 段。
const isMain = process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
const rows = isMain ? scan(SRC, process.argv.includes('--all')) : [];
const popups = isMain ? auditPopups(SRC) : [];
if (!isMain) {
  // import 场景：什么都不打印（导出 scan() / auditPopups() 供 suite-material 复用）。
} else if (process.argv.includes('--json')) {
  console.log(JSON.stringify(rows, null, 2));
} else if (process.argv.includes('--json-popups')) {
  console.log(JSON.stringify(popups, null, 2));
} else {
  for (const r of rows) {
    console.log([r.file, r.line, r.struct, r.builder, r.token].join(' | '));
  }
  const counts = {};
  for (const r of rows) { counts[r.token] = (counts[r.token] || 0) + 1; }
  console.log('--- 按令牌计数 ---');
  for (const k of Object.keys(counts).sort()) { console.log(`${counts[k]}\t${k}`); }
  console.log('TOTAL ' + rows.length);

  // -------------------------------------------------------------------------
  // R86-E 扩展段（上面的输出逐字未动；以下是新增）
  // -------------------------------------------------------------------------
  console.log('--- 弹窗类接入点审计（A4 bindSheet / A6·A7 bindPopup / A12 showAlertDialog）---');
  console.log(['KIND', '位置', 'options来源', 'systemMaterial', '实参', '期望', '判定']
    .join(' | '));
  for (const p of popups) {
    console.log([p.kind, `${p.file}:${p.line}`, p.optionsFrom,
      p.hasField ? '已接' : '未接', p.materialExpr === '' ? '-' : p.materialExpr,
      p.expect === '' ? '(任一)' : p.expect, p.ok ? 'OK' : (p.optionsResolved ? 'MISS' : 'UNRESOLVED')]
      .join(' | '));
  }
  console.log('--- 弹窗类计数 ---');
  let totOk = 0;
  let totAll = 0;
  for (const spec of POPUP_SPECS) {
    const list = popups.filter((p) => p.kind === spec.kind);
    const ok = list.filter((p) => p.ok).length;
    totOk += ok; totAll += list.length;
    const lineStart = lineStartCommentCount(SRC, spec);
    console.log(`${spec.kind}\t接 ${ok} / 未接 ${list.length - ok} / 合计 ${list.length}`
      + `\t(行首注释口径 ${lineStart}${lineStart === list.length ? '' : ' ⚠️ 口径分歧'})`);
  }
  console.log(`弹窗类合计\t接 ${totOk} / 未接 ${totAll - totOk} / 合计 ${totAll}`);
  const unresolved = popups.filter((p) => !p.optionsResolved);
  if (unresolved.length > 0) {
    console.log('未解析 options 的调用点（不放过，需人工看）：');
    for (const p of unresolved) { console.log(`  ? ${p.file}:${p.line} ${p.kind}`); }
  }
  console.log('--- 弹层内容根登记（根节点属性链 / 门控 / 组件级材质；不作判据）---');
  console.log('  ⚠️ 根链上的自绘层**非空本身不是缺陷**：R86 口径 = 门控（探针可用 ⇒ 零自绘层；'
    + '不可用 ⇒ 回到自绘玻璃）。「根链自绘层非空 **且** 未门控」才是可疑组合。');
  console.log('  · 根链 = `@Builder` 里**根组件自己**的属性链（子节点的 `.backgroundColor()` 不算，'
    + '否则图标方块之类会假阳性）。');
  for (const p of popups) {
    if (p.builderRef === '') { continue; }
    const suspicious = p.rootSelfDrawn.length > 0 && !p.contentGated;
    console.log([`${p.file}:${p.line}`, p.kind, `根=${p.builderRef}`,
      p.contentResolved ? '已解析' : '未解析',
      '根链自绘=[' + p.rootSelfDrawn.join(' ') + ']',
      '门控=' + (p.contentGated ? '是' : '否'),
      '组件级systemMaterial=' + (p.contentComponentMaterial ? '是' : '否'),
      p.paintFields.length > 0 ? 'options底色字段=[' + p.paintFields.join(' ') + ']' : '',
      suspicious ? '⚠️ 根链自绘层未门控' : ''
    ].filter((s) => s !== '').join(' | '));
  }
  if (process.argv.includes('--check')) {
    const bad = totAll - totOk + unresolved.length;
    console.log(`POPUP-CHECK ${bad === 0 ? 'PASS' : 'FAIL'}（未接/实参不对 ${totAll - totOk} + 未解析 ${unresolved.length}）`);
    process.exit(bad === 0 ? 0 : 1);
  }
}
