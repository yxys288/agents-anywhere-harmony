#!/usr/bin/env node
/**
 * aa-hm 图标体系自测（不依赖 ArkUI / 设备）。
 *
 * 范围（R12 task-2）：
 *  ① **表完整性**：`ui/Icon.ets` 的 `ICONS` 是否 = 上游 Android 端用到的 57 个 + 本工程扩展的 5 个，
 *     每个 `d` 是否与 lucide-static 逐字一致（关键图标硬编码比对）；
 *  ② **数据合法性 + 坐标不变量**：全部以 M/m 开头、只含合法字符、**所有子路径起点与端点都落在 24×24 画布内**
 *     （独立实现一套坐标追踪，不复用产品代码 —— 这正是「多子路径拼接时相对 m 会被算错」那类 bug 的护栏）；
 *  ③ **`scaleIconPath()` 的等比缩放语义**：命令序列不变、A 命令的旋转角/大小弧/方向标志位原样保留、
 *     相对与绝对命令一视同仁、隐式重复（M→L / m→l）、连写负数与小数、幂等性；
 *  ④ **两个 UI 文件里不再有字符图标**（按**真机渲染**清点：'✎' '☰' '▾' '★' '▣' '✓' '🔍' '🖥' '🗀' '>_' … 都在列）
 *     以及「用到的图标名都在表里」（写错名字 = 设备上一块空白，必须有断言兜住）；
 *  ⑤ **悬浮按钮遮挡的数值闭环**：列表尾部留白 ≥ 悬浮按钮占据的高度 + 安全间距，且**两个列表视图都改了**。
 *
 * 转译方式照抄 `tools/logic-test/run-tests.mjs`：把 `Icon.ets` 的纯逻辑区
 * （`// >>> AA-ICON-PURE-BEGIN` … `// <<< AA-ICON-PURE-END`，零 import）切出来单独转译。
 *
 * ⚠️ 本文件刻意**零反斜杠转义**：正则一律用字符类写法，路径用正斜杠，换行用 fromCharCode。
 *    （历史事故：把带反斜杠的文本经脚本落盘时被转义污染。）
 *
 * 用法：
 *   用 DevEco 自带 node 执行本文件：tools/logic-test/suite-icons.mjs
 */

import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import zlib from 'node:zlib';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, requireTypeScript, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-icons');

const ICON_ETS = path.join(SRC_ETS, 'ui', 'Icon.ets');
const COMPONENTS_ETS = path.join(SRC_ETS, 'ui', 'Components.ets');
const HOME_ETS = path.join(SRC_ETS, 'ui', 'screens', 'HomeScreen.ets');
const DESIGN_ETS = path.join(SRC_ETS, 'ui', 'Design.ets');

const PURE_BEGIN = '// >>> AA-ICON-PURE-BEGIN';
const PURE_END = '// <<< AA-ICON-PURE-END';
const LF = String.fromCharCode(10);

/** 上游 Android 端实际用到的 57 个 Lucide 标识符（kebab-case；Trash2→trash-2、ListIcon→list 已归一）。 */
const REQUIRED = [
  'arrow-down', 'arrow-left', 'archive', 'archive-restore', 'bot', 'braces', 'check', 'check-check',
  'chevron-down', 'chevron-left', 'chevron-right', 'chevron-up', 'chevrons-up-down', 'circle',
  'circle-alert', 'circle-check', 'clock', 'copy', 'download', 'ellipsis', 'external-link',
  'file-code', 'file-pen-line', 'file-text', 'folder', 'folder-open', 'globe', 'hammer', 'hash',
  'info', 'key-round', 'list', 'log-out', 'mail-check', 'monitor', 'monitor-up', 'moon',
  'package-check', 'pencil', 'pin', 'plus', 'qr-code', 'refresh-cw', 'search', 'server',
  'shield-check', 'sparkles', 'square-arrow-out-up-right', 'square-pen', 'square-terminal', 'sun',
  'terminal', 'trash-2', 'triangle-alert', 'user-round', 'wifi-off', 'x'
];

/**
 * 本工程在上游 57 个 `Lucide.*` 之外**额外引入**的图标 ——
 * 上游对应位置用的是**位图 / 自绘 drawable 资源**，不在 `Lucide.XXX` 引用里，所以统计不到。
 * 形状同样逐字取自 lucide-static@1.47.0（或上游自己的 drawable，见逐项注释），非自创。
 */
export const EXTENSIONS = [
  'arrow-up', 'lock', 'paperclip', 'settings', 'square', 'square-check',
  // R22：上游 `drawable/ic_user_round_arrow_left.xml`（账号页「修改昵称」动作行的图标，
  // 该文件头注明它就是 Lucide `user-round-arrow-left` 的官方 SVG）。
  'user-round-arrow-left',
  // R38（用户需求「软件所有发送功能都用图标取代」）：发送类按钮统一用 send。
  // 上游的会话输入区主按钮用的是自绘 `ForwardGlyph`/箭头，终端与本工程新加的发送钮
  // 上游没有对应引用，故登记为扩展；形状逐字取自 lucide-static@1.47.0 的 send.svg。
  'send',
  // R62（用户指定的底部悬浮功能栏需要「首页」）：上游没有「回首页」这个入口图标
  //（上游首页就是会话列表本身，不存在回首页的 tab），故登记为扩展。
  // 形状逐字取自 lucide-static 的 house.svg；两条子路径都以**绝对** `M` 起头，
  // 拼接顺序不影响起点计算（不会踩「相对 m 被算错」那条护栏）。
  'house'
];

/** 与 lucide-static@1.47.0 逐字一致的样本（防止有人手改表里的数据）。 */
const EXACT = {
  'check': 'M20 6 9 17l-5-5',
  'chevron-down': 'm6 9 6 6 6-6',
  'chevron-right': 'm9 18 6-6-6-6',
  'plus': 'M5 12h14 M12 5v14',
  'terminal': 'M12 19h8 M4 17l6 -6 -6 -6',
  'folder': 'M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z',
  'lock': 'M5 11H19a2 2 0 0 1 2 2V20a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V13a2 2 0 0 1 2 -2Z M7 11V7a5 5 0 0 1 10 0v4',
  'settings': 'M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915 M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0',
  'arrow-up': 'm5 12 7-7 7 7 M12 19V5',
  'square': 'M5 3H19a2 2 0 0 1 2 2V19a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z',
  'square-check': 'M5 3H19a2 2 0 0 1 2 2V19a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z M16 9l-5.5 5.5 L 8 12',
  'paperclip': 'm16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551',
  // R62 新增（底栏「首页」）。原 svg 的 `.709` / `-1.528` 在本表里补成 `0.709` / 带空格的 `-1.528`。
  'house': 'M15 21v-8a1 1 0 0 0 -1 -1h-4a1 1 0 0 0 -1 1v8 M3 10a2 2 0 0 1 0.709 -1.528l7 -5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2Z'
};

/** 改前用字符 / emoji 画的图标（按真机渲染清点，见开发期验证记录）。 */
const GLYPHS = [
  String.fromCodePoint(0x1F5A5), String.fromCodePoint(0x1F5C0), String.fromCodePoint(0x1F5C1),
  String.fromCodePoint(0x1F50D), String.fromCodePoint(0x270E), String.fromCodePoint(0x2630),
  String.fromCodePoint(0x25BE), String.fromCodePoint(0x25B8), String.fromCodePoint(0x22EF),
  String.fromCodePoint(0x2605), String.fromCodePoint(0x25A3), String.fromCodePoint(0x2713),
  String.fromCodePoint(0x2039), String.fromCodePoint(0xD7), '>_'
];

// ---------------------------------------------------------------------------
// 转译纯逻辑区
// ---------------------------------------------------------------------------

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  const source = fs.readFileSync(ICON_ETS, 'utf8');
  const begin = source.indexOf(PURE_BEGIN);
  const end = source.indexOf(PURE_END);
  if (begin < 0 || end <= begin) {
    throw new Error('ui/Icon.ets 里找不到纯逻辑区标记（' + PURE_BEGIN + ' / ' + PURE_END + '）：标记被删或改名了？');
  }
  const text = source.slice(begin + PURE_BEGIN.length, end);
  if (text.indexOf('import ') >= 0) {
    throw new Error('ui/Icon.ets 的纯逻辑区出现了 import —— 该区必须零依赖');
  }
  const target = path.join(OUT_DIR, 'Icon.js');
  fs.writeFileSync(target, ts.transpileModule(text, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
    fileName: 'ui/Icon.ets'
  }).outputText, 'utf8');
}

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------

let passed = 0;
const failures = [];
function check(name, condition, detail) {
  if (condition) { passed += 1; } else { failures.push(detail === undefined ? name : name + ' — ' + detail); }
}
function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function group(title) {
  console.log('');
  console.log('== ' + title);
}

// ---------------------------------------------------------------------------
// 独立实现的 path 工具（**不复用产品代码**，否则同源错误会被互相掩盖）
// ---------------------------------------------------------------------------

const isCmd = (ch) => 'MmLlHhVvCcSsQqTtAaZz'.indexOf(ch) >= 0;
const isDigit = (ch) => ch >= '0' && ch <= '9';

function tokenize(d) {
  const out = [];
  let i = 0;
  while (i < d.length) {
    const ch = d.charAt(i);
    if (ch === ' ' || ch === ',' || ch === LF || ch === String.fromCharCode(9) || ch === String.fromCharCode(13)) { i++; continue; }
    if (isCmd(ch)) { out.push(ch); i++; continue; }
    let j = i;
    if (d.charAt(j) === '-' || d.charAt(j) === '+') { j++; }
    while (j < d.length && isDigit(d.charAt(j))) { j++; }
    // 小数点只吃一个：Lucide 里有 `c0 1.1.9 2 2 2` 这种写法（= 1.1 与 .9 两个数）。
    if (j < d.length && d.charAt(j) === '.') {
      j++;
      while (j < d.length && isDigit(d.charAt(j))) { j++; }
    }
    if (j === i) { j = i + 1; }
    out.push(d.substring(i, j));
    i = j;
  }
  return out;
}

function arityOf(up) {
  if (up === 'M' || up === 'L' || up === 'T') { return 2; }
  if (up === 'H' || up === 'V') { return 1; }
  if (up === 'C') { return 6; }
  if (up === 'S' || up === 'Q') { return 4; }
  if (up === 'A') { return 7; }
  return 0;
}

function commandLetters(d) {
  return tokenize(d).filter((t) => isCmd(t)).join('');
}

/** A 命令里的「旋转角 大小弧标志 方向标志」三元组（这三项不该被缩放）。 */
function arcTriples(d) {
  const t = tokenize(d);
  const out = [];
  let i = 0;
  while (i < t.length) {
    const letter = t[i];
    if (!isCmd(letter)) { i++; continue; }
    const up = letter.toUpperCase();
    i++;
    const arity = arityOf(up);
    if (arity === 0) { continue; }
    while (i + arity <= t.length && !isCmd(t[i])) {
      if (up === 'A') { out.push(t.slice(i + 2, i + 5).join(' ')); }
      i += arity;
    }
  }
  return out.join('|');
}

/** 追踪每个子路径的起点与每条命令的终点（绝对坐标）。 */
function trackPoints(d) {
  const t = tokenize(d);
  const starts = [];
  const ends = [];
  let cx = 0, cy = 0, sx = 0, sy = 0, i = 0;
  while (i < t.length) {
    const letter = t[i];
    if (!isCmd(letter)) { i++; continue; }
    const up = letter.toUpperCase();
    i++;
    const rel = letter === letter.toLowerCase();
    const arity = arityOf(up);
    if (arity === 0) { cx = sx; cy = sy; continue; }
    let first = true;
    while (i + arity <= t.length && !isCmd(t[i])) {
      const a = t.slice(i, i + arity).map(Number);
      i += arity;
      const eff = (up === 'M' && !first) ? 'L' : up;
      if (eff === 'H') { cx = rel ? cx + a[0] : a[0]; }
      else if (eff === 'V') { cy = rel ? cy + a[0] : a[0]; }
      else { const px = a[a.length - 2], py = a[a.length - 1]; cx = rel ? cx + px : px; cy = rel ? cy + py : py; }
      if (eff === 'M') { sx = cx; sy = cy; starts.push([cx, cy]); }
      ends.push([cx, cy]);
      first = false;
    }
  }
  return { starts, ends };
}

const inCanvas = (p) => p[0] >= -0.001 && p[0] <= 24.001 && p[1] >= -0.001 && p[1] <= 24.001;

/** 全部子路径起点 + 全部命令终点（几何指纹）。 */
function pointsOf(d) {
  const p = trackPoints(d);
  return p.starts.concat(p.ends);
}

/** 两组点是否逐点一致（容差内）。 */
function samePoints(a, b, tol) {
  if (a.length !== b.length) { return false; }
  for (let i = 0; i < a.length; i++) {
    if (Math.abs(a[i][0] - b[i][0]) > tol || Math.abs(a[i][1] - b[i][1]) > tol) { return false; }
  }
  return true;
}

/** 把 path 文本归一成可比较的记号（数字统一成 Number 再输出）。 */
function canonical(d) {
  return tokenize(d).map((t) => (isCmd(t) ? t : String(Number(t)))).join(' ');
}

const readSource = (file) => fs.readFileSync(file, 'utf8');

/** 去掉注释后的代码文本（手写扫描器：避免把文档注释里提到的字符当成残留图标）。 */
function codeOnly(src) {
  let out = '';
  let i = 0;
  while (i < src.length) {
    const ch = src.charAt(i);
    const next = src.charAt(i + 1);
    if (ch === '/' && next === '*') {
      const end = src.indexOf('*/', i + 2);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    if (ch === '/' && next === '/') {
      const end = src.indexOf(LF, i + 2);
      i = end < 0 ? src.length : end;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

// ---------------------------------------------------------------------------

build();
const require = createRequire(import.meta.url);
const icons = require(path.join(OUT_DIR, 'Icon.js'));

const TABLE = icons.ICONS;
const names = Object.keys(TABLE);
const iconSource = readSource(ICON_ETS);
const componentsSrc = readSource(COMPONENTS_ETS);
const homeSrc = readSource(HOME_ETS);
const componentsCode = codeOnly(componentsSrc);
const homeCode = codeOnly(homeSrc);
const designSrc = readSource(DESIGN_ETS);

group('ICONS 表完整性（upstream 57 个 Lucide 标识符）');
check('ICONS 不是空表（至少 57 项）', names.length >= REQUIRED.length, 'got ' + names.length);
eq('ICONS = 上游 57 个 + 本工程扩展 ' + EXTENSIONS.length + ' 个', names.length, REQUIRED.length + EXTENSIONS.length);
eq('上游必需图标一个不缺', REQUIRED.filter((n) => !names.includes(n)).join(','), '');
eq('表里没有清单以外的图标（上游 ' + REQUIRED.length + ' + 扩展 ' + EXTENSIONS.length + '）',
  names.filter((n) => !REQUIRED.includes(n) && !EXTENSIONS.includes(n)).join(','), '');
eq('扩展键与上游清单不重叠', EXTENSIONS.filter((n) => REQUIRED.includes(n)).join(','), '');
for (const key of Object.keys(EXACT)) {
  eq('与 lucide-static 逐字一致：' + key, TABLE[key], EXACT[key]);
}
check('key-round 的填充小圆已按文档归一成圆点线段', TABLE['key-round'].includes('M16.5 7.5h0.01'), TABLE['key-round'].slice(-30));
const keyOccurrences = iconSource.split(': ').length > 0
  ? iconSource.split(LF).filter((l) => l.startsWith("  '") && l.indexOf("': '") > 0).length : 0;
eq('源码里没有重复键（键的条数 = 对象条数）', keyOccurrences, names.length);

group('数据合法性（全表遍历）');
eq('全部以 M/m 开头', names.filter((n) => 'Mm'.indexOf(TABLE[n].charAt(0)) < 0).join(','), '');
const LEGAL = /^[MmLlHhVvCcSsQqTtAaZz0-9 .,+-]+$/;
eq('全部只含 SVG path 合法字符', names.filter((n) => !LEGAL.test(TABLE[n])).join(','), '');
eq('全部不含 XML 残留', names.filter((n) => /[<>&"/]/.test(TABLE[n])).join(','), '');
eq('全部不含科学计数法', names.filter((n) => /[eE]/.test(TABLE[n])).join(','), '');
eq('iconPathIssues() 对所有图标都返回空', names.filter((n) => icons.iconPathIssues(TABLE[n]).length > 0).join(','), '');
check('iconPathIssues() 能识别坏数据（非空返回）', icons.iconPathIssues('L1 1').length > 0);
check('iconPathIssues() 能识别空串', icons.iconPathIssues('').length > 0);
check('所有 d 至少 10 个字符', names.every((n) => TABLE[n].length >= 10));

group('坐标不变量（独立实现，不用产品代码）');
const outOfCanvas = [];
const noStart = [];
for (const n of names) {
  const p = trackPoints(TABLE[n]);
  if (p.starts.length === 0) { noStart.push(n); continue; }
  if (!p.starts.every(inCanvas) || !p.ends.every(inCanvas)) {
    outOfCanvas.push(n + ':' + JSON.stringify(p.starts.concat(p.ends).filter((q) => !inCanvas(q))));
  }
}
eq('每个图标都有子路径起点', noStart.join(','), '');
eq('所有子路径起点与端点都落在 24×24 画布内（多子路径相对 m 拼接的护栏）', outOfCanvas.join(' | '), '');
check('护栏不是空转：故意喂一条越界的拼接路径会被判越界',
  trackPoints('M12 19h8 m4 17 6-6').starts.some((p) => !inCanvas(p)));
const arcIcons = names.filter((n) => /[Aa]/.test(TABLE[n])).length;
check('至少 20 个图标含圆弧命令（归一没把 circle/rect 丢掉）', arcIcons >= 20, 'got ' + arcIcons);

group('scaleIconPath（等比缩放）');
const scale = icons.scaleIconPath;
eq('ICON_VIEW 是 24', icons.ICON_VIEW, 24);
eq('ICON_STROKE 是 2', icons.ICON_STROKE, 2);
eq('size=24 时全表所有端点与原件完全一致（缩放系数为 1）',
  names.filter((n) => !samePoints(pointsOf(TABLE[n]), pointsOf(scale(TABLE[n], 24)), 1e-9)).join(','), '');
eq('size=12 时 folder 首点 20 → 10', scale(TABLE['folder'], 12).indexOf('M10 10'), 0);
eq('非整数尺寸（14）的首点按 14/24 精确换算', scale(TABLE['folder'], 14).indexOf('M11.667 11.667'), 0);
eq('相对命令同样缩放（chevron-down，隐式重复被展开成显式 l）', scale(TABLE['chevron-down'], 12), 'm3 4.5l3 3l3 -3');
eq('H/V 也缩放（plus）', scale(TABLE['plus'], 12), 'M2.5 6h7M6 2.5v7');
eq('子路径个数不变（folder）', trackPoints(scale(TABLE['folder'], 14)).starts.length, trackPoints(TABLE['folder']).starts.length);
eq('全表在 size=14 下的端点 = 原端点 × 14/24（等比缩放的硬判据）',
  names.filter((n) => !samePoints(pointsOf(scale(TABLE[n], 14)), pointsOf(TABLE[n]).map((p) => [p[0] * 14 / 24, p[1] * 14 / 24]), 0.002)).join(','), '');
eq('A 命令的旋转角与大小弧/方向标志位原样保留（folder）', arcTriples(scale(TABLE['folder'], 12)), arcTriples(TABLE['folder']));
eq('全表在缩放后 A 命令的标志位都不变',
  names.filter((n) => arcTriples(scale(TABLE[n], 12)) !== arcTriples(TABLE[n])).join(','), '');
check('至少 20 个图标的圆弧标志位参与比对（断言不是空转）',
  names.filter((n) => arcTriples(TABLE[n]).length > 0).length >= 20);
eq('key-round 的圆点线段在缩放后仍是非零长度', scale(TABLE['key-round'], 12).includes('h0.005'), true);
eq('隐式重复：M 的后续参数组变成 L', scale('M0 0 1 1', 24), 'M0 0L1 1');
eq('隐式重复：m 的后续参数组变成 l', scale('m0 0 1 1', 24), 'm0 0l1 1');
eq('连写负数被正确切开（l2-2）', scale('M0 0l2-2', 12), 'M0 0l1 -1');
eq('连写小数被正确切开（.5.5）', scale('M0 0l.5.5', 24), 'M0 0l0.5 0.5');
eq('Z 不产生参数', scale('M0 0Z', 12), 'M0 0Z');
eq('空串仍返回空串', scale('', 12), '');
eq('未知命令字被跳过：既不死循环也不产生 NaN', scale('M0 0B9 9', 12), 'M0 0');
eq('连写两个小数（1.1.9 = 1.1 与 .9 两个数）', scale('M0 0l1.1.9', 12), 'M0 0l0.55 0.45');
eq('全表在多个尺寸下缩放都不产生 NaN（数字扫描的硬护栏）',
  names.filter((n) => [12, 14, 20, 24].some((s) => scale(TABLE[n], s).indexOf('NaN') >= 0)).join(','), '');
eq('幂等性：缩到 12 之后在 24 下再缩一次，结果不变（第二次的缩放系数是 1）',
  canonical(scale(scale(TABLE['search'], 12), 24)), canonical(scale(TABLE['search'], 12)));
check('全部图标在 14 下都能缩放且结果非空', names.every((n) => scale(TABLE[n], 14).length > 5));

group('坐标空间不变量（R12-7：Path.commands 是 px、Shape 的盒子是 vp）');
const iconCode = codeOnly(iconSource);
check('AaIcon 的路径缩放目标来自 sidePx()（而不是裸的 vp 值）',
  iconCode.indexOf('commands(scaleIconPath(this.d, this.sidePx()))') >= 0);
check('sidePx() 走 UIContext.vp2px（全局 vp2px 自 API 18 起废弃）',
  iconCode.indexOf('this.getUIContext().vp2px(this.iconSize)') >= 0);
eq('改前的错误写法（路径直接用 vp 值）已不存在',
  iconCode.split('scaleIconPath(this.d, this.iconSize)').length - 1, 0);
check('命令用 px 数值、viewPort 用 vp 数值（两者相差一个 dpr）',
  iconCode.indexOf('.viewPort({ x: 0, y: 0, width: this.iconSize, height: this.iconSize })') >= 0);
eq('viewPort 里不再出现 sidePx()（那是 R12-7 第一次修正的错法：会把放大抵消）',
  iconCode.split('width: this.sidePx()').length - 1, 0);
check('组件盒子仍用 vp（.width(this.iconSize) / .height(this.iconSize)）',
  iconCode.indexOf('.width(this.iconSize)') >= 0 && iconCode.indexOf('.height(this.iconSize)') >= 0);
check('线宽按 vp 给（stroke * iconSize / ICON_VIEW）',
  iconCode.indexOf('.strokeWidth(this.stroke * this.iconSize / ICON_VIEW)') >= 0);
eq('线宽里不再出现 sidePx()（那是 R12-7 的错法：线会粗 dpr 倍）',
  iconCode.split('strokeWidth(this.stroke * this.sidePx()').length - 1, 0);
const pureSlice = iconSource.slice(iconSource.indexOf(PURE_BEGIN), iconSource.indexOf(PURE_END));
eq('纯逻辑区不依赖 vp2px（Node 侧仍可单测）', pureSlice.split('vp2px').length - 1, 0);

/** 同一个文件里两行 Icon 导入会直接编译失败（`Duplicate identifier`）—— R12-9 踩过一次。 */
const dupIconImports = [];
(function collectEts(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { collectEts(p); continue; }
    if (!e.name.endsWith('.ets')) { continue; }
    const src = readSource(p);
    const n = (src.split("from '../Icon'").length - 1) + (src.split("from './Icon'").length - 1);
    if (n > 1) { dupIconImports.push(e.name + '×' + n); }
  }
})(SRC_ETS);
eq('没有文件重复导入 Icon 模块（重复会直接编译失败）', dupIconImports.join(','), '');
/** 端点在某一轴上的跨度。 */
const span = (d) => {
  const pts = pointsOf(d);
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  return [Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys)];
};
eq('scaleIconPath(d, S) 把 24 单位画布映射到 0..S（S 就是物理像素边长）',
  Math.abs(span(scale(TABLE['folder'], 65.45))[0] - (20 / 24) * 65.45) < 0.02, true);
eq('线性：S 翻倍则所有端点坐标翻倍（3 位小数舍入的累积误差 < 0.05 单位）',
  names.filter((n) => !samePoints(pointsOf(scale(TABLE[n], 40)), pointsOf(scale(TABLE[n], 20)).map((p) => [p[0] * 2, p[1] * 2]), 0.05)).join(','), '');
// ⚠️ R12-7 曾在这里写过一个「设备卡 60px / 与安卓 59px 相差 <5%」的预测断言 ——
// 那个模型（线宽与命令同空间）**已被真机量测证伪**（详见开发期验证记录），
// 现由下面的『真机像素量测口径（R12-10 校准）』分组按**实测反推的口径**取代。
const brokenInkPx = 20 + (2 * 22) / 24;
check('改前口径会得到 ≈ 22px，与取证实测 23px 一致 ⇒ 第一处单位错（路径空间）确认',
  Math.abs(brokenInkPx - 23) < 3, 'got ' + brokenInkPx.toFixed(1));

group('真机像素量测口径（R12-10 校准，Lead 实测值）');
/** 真机 Mate70 Pro+ 的 dpr（ICON-FORENSICS.md 实测）。 */
const DEVICE_DPR = 2.975;
/**
 * 墨迹物理像素的预测式（R12-10 真机校准后的口径）：
 *   命令坐标是 px ⇒ 路径跨度按 iconSize×dpr 缩放；
 *   线宽是 vp（裸数字）⇒ 渲染时再乘 dpr。
 * 反过来说：线宽若按 px 给（×dpr 两次），就会大 ≈dpr 倍 —— 这正是 R12-10 修掉的缺陷。
 */
const predInkPx = (name, iconSize) => (span(TABLE[name])[0] / 24) * iconSize * DEVICE_DPR + (2 * iconSize / 24) * DEVICE_DPR;
const wrongInkPx = (name, iconSize) => (span(TABLE[name])[0] / 24) * iconSize * DEVICE_DPR + (2 * iconSize * DEVICE_DPR / 24) * DEVICE_DPR;
const NEAR = (a, b, tol) => Math.abs(a - b) <= tol;
check('设备卡 monitor(22vp) 预测 ≈60px，安卓实测 59px（±1）', NEAR(predInkPx('monitor', 22), 59, 1), predInkPx('monitor', 22).toFixed(1));
check('顶栏搜索 search(24vp) 预测 ≈59.5px，安卓实测 59px（±1）', NEAR(predInkPx('search', 24), 59, 1), predInkPx('search', 24).toFixed(1));
check('顶栏头像 user-round(21vp) 预测 ≈46.9px，安卓实测 46px（±1）', NEAR(predInkPx('user-round', 21), 46, 1), predInkPx('user-round', 21).toFixed(1));
check('FAB plus(24vp) 预测 ≈47.6px，安卓实测 48px（±1）', NEAR(predInkPx('plus', 24), 48, 1), predInkPx('plus', 24).toFixed(1));
check('项目头 ⋯ ellipsis(19vp) 预测 ≈42.4px，安卓实测 43px（±1）', NEAR(predInkPx('ellipsis', 19), 43, 1), predInkPx('ellipsis', 19).toFixed(1));
check('复现 R12-10 缺陷：线宽按 px 会给设备卡 ≈70.8px（超安卓 59 的 1.19 倍）',
  wrongInkPx('monitor', 22) > 59 * 1.15, wrongInkPx('monitor', 22).toFixed(1));
/** R13-2：同一套口径用来定标「终端卡该用哪个字形」。 */
const predInkPxH = (name, iconSize) => (span(TABLE[name])[1] / 24) * iconSize * DEVICE_DPR + (2 * iconSize / 24) * DEVICE_DPR;
check('R13-2 终端卡 terminal(22vp) 预测 ≈49.1×43.6px，安卓实测 49×43（±1）',
  NEAR(predInkPx('terminal', 22), 49, 1) && NEAR(predInkPxH('terminal', 22), 43, 1),
  predInkPx('terminal', 22).toFixed(1) + '×' + predInkPxH('terminal', 22).toFixed(1));
check('R13-2 缺陷复现：square-terminal(22vp) 预测 ≈54.5×54.5px（真机实测 55×55），比安卓 49×43 宽 5.5px / 高 11.5px',
  NEAR(predInkPx('square-terminal', 22), 55, 1) && predInkPx('square-terminal', 22) - 49 > 4 && predInkPxH('square-terminal', 22) - 43 > 4,
  predInkPx('square-terminal', 22).toFixed(1) + '×' + predInkPxH('square-terminal', 22).toFixed(1));
check('R13-2 选型判据：terminal 在两轴上到安卓实测的总偏差都小于 square-terminal',
  Math.abs(predInkPx('terminal', 22) - 49) + Math.abs(predInkPxH('terminal', 22) - 43)
    < Math.abs(predInkPx('square-terminal', 22) - 49) + Math.abs(predInkPxH('square-terminal', 22) - 43));

check('线宽按 px 与按 vp 相差正好 dpr 倍（同一条线宽两种口径）',
  NEAR(wrongInkPx('monitor', 22) - predInkPx('monitor', 22), (2 * 22 / 24) * DEVICE_DPR * (DEVICE_DPR - 1), 0.01));

group('UI 文件交叉校验（图标名与残留字符）');
const usedKeys = (src) => src.split("ICONS['").slice(1)
  .map((part) => part.substring(0, part.indexOf("']")))
  .filter((k) => /^[a-z0-9-]+$/.test(k));
const compKeys = usedKeys(componentsCode);
const homeKeys = usedKeys(homeCode);
check('Components.ets 用到了矢量图标（至少 5 处）', compKeys.length >= 5, 'got ' + compKeys.length);
check('HomeScreen.ets 用到了矢量图标（至少 15 处）', homeKeys.length >= 15, 'got ' + homeKeys.length);
eq('Components.ets 用到的图标名都在表里', compKeys.filter((k) => !names.includes(k)).join(','), '');
eq('HomeScreen.ets 用到的图标名都在表里', homeKeys.filter((k) => !names.includes(k)).join(','), '');
eq('Components.ets 有一行 AaIcon 导入', componentsSrc.split("import { AaIcon, ICONS } from './Icon';").length - 1, 1);
eq('HomeScreen.ets 有一行 AaIcon 导入', homeSrc.split("import { AaIcon, ICONS } from '../Icon';").length - 1, 1);
const residual = [];
for (const g of GLYPHS) {
  const quoted = "'" + g + "'";
  for (const pair of [['Components.ets', componentsCode], ['HomeScreen.ets', homeCode]]) {
    if (pair[1].indexOf(quoted) >= 0) { residual.push(pair[0] + ':' + g); }
  }
}
eq('两个文件里不再有字符 / emoji 图标（含非 emoji 码位的符号）', residual.join(','), '');
eq('两个页面里没有内联 path（commands 只用一次，且在 Icon.ets）',
  (componentsCode.split('commands(').length - 1) + (homeCode.split('commands(').length - 1), 0);

group('悬浮按钮遮挡（首页列表尾部留白）');
const numAfter = (src, marker) => {
  const at = src.indexOf(marker);
  if (at < 0) { return NaN; }
  let i = at + marker.length;
  while (i < src.length && ' ='.indexOf(src.charAt(i)) >= 0) { i++; }
  let digits = '';
  while (i < src.length && src.charAt(i) >= '0' && src.charAt(i) <= '9') { digits += src.charAt(i); i++; }
  return digits.length > 0 ? Number(digits) : NaN;
};
const fabInset = numAfter(designSrc, 'static readonly XXL: number =');
const pageBottom = numAfter(designSrc, 'static readonly PAGE_BOTTOM: number =');
const tail = numAfter(designSrc, 'static readonly HOME_LIST_BOTTOM: number =');
eq('Design 令牌：Space.XXL = 32（悬浮按钮 insetBottom 用的就是它）', fabInset, 32);
eq('Design 令牌：Space.PAGE_BOTTOM = 28（改前两个列表用的值）', pageBottom, 28);
check('HomeScreen 定义了 HOME_LIST_BOTTOM 常量', Number.isFinite(tail) && tail > 0, 'got ' + tail);
const fabOccupied = 54 + fabInset;
eq('悬浮按钮占据屏幕底部 54 + 32 = 86vp', fabOccupied, 86);
check('尾部留白 ≥ 按钮占据高度 + 8vp 安全间距', tail >= fabOccupied + 8, 'tail=' + tail + ' occupied=' + fabOccupied);
// R38 修正（lead 裁决，W1 执行）：本条的**写法**随 R37 变了 —— HomeScreen 已从
// `.padding({ bottom: Space.HOME_LIST_BOTTOM })` 改为 `.contentEndOffset(Space.HOME_LIST_BOTTOM)`
// （项目视图与会话视图各一处，锚文「尾部留白：避开右下悬浮按钮」），旧写法计数因此恒为 0。
// **原意不变**：两个列表视图都做了尾部留白，且留白值来自 Design 令牌（不是各自写死的数字）。
// 用 `homeCode`（去注释）计数，避免注释里提到该串时把计数抬高。
eq('项目视图与会话视图**都**用了 Space.HOME_LIST_BOTTOM（当前写法 = contentEndOffset）',
  homeCode.split('.contentEndOffset(Space.HOME_LIST_BOTTOM)').length - 1, 2);
eq('首页里不再有页面级 HOME_LIST_BOTTOM 常量（已收编进 Design.ets）',
  homeCode.split('const HOME_LIST_BOTTOM').length - 1, 0);
eq('两个列表都不再直接用 PAGE_BOTTOM 收尾',
  homeSrc.split('bottom: Space.PAGE_BOTTOM').length - 1, 0);
eq('悬浮按钮直径仍是上游的 54', componentsCode.split('diameter: number = 54').length - 1, 1);
// ⚠️ R62（用户指定形态）：首页的悬浮「+」已**取消**（新建对话动作迁到顶栏右侧钮），
// 所以首页不再传 `insetBottom`。`AaFloatingButton` 组件本身保留（有别的潜在调用点/便于回退），
// 但**首页已无调用点** —— 这条断言的语义随之从「传 1 次」改成「不传」。
eq('悬浮按钮不再被首页调用（R62 取消悬浮「+」）', homeCode.split('insetBottom: Space.XXL').length - 1, 0);

group('全页面残留字形扫描（R12-5：其余 10 个页面）');
/** R12-5 覆盖的 10 个页面 + R12-2 已收口的两处（共 12 个用矢量图标的 UI 文件）。 */
const SCREEN_DIR = path.join(SRC_ETS, 'ui', 'screens');
const ALL_UI_FILES = [
  path.join(SRC_ETS, 'ui', 'Components.ets'),
  path.join(SRC_ETS, 'ui', 'Icon.ets'),
  // R57（T2b）：液态玻璃功能钮的唯一实现 —— 它也用 AaIcon，必须同样进「残留字形」扫描。
  path.join(SRC_ETS, 'ui', 'GlassIcon.ets'),
  path.join(SCREEN_DIR, 'HomeScreen.ets'),
  path.join(SCREEN_DIR, 'AddDeviceScreen.ets'),
  path.join(SCREEN_DIR, 'ArchivedSessionsScreen.ets'),
  path.join(SCREEN_DIR, 'DeviceDetailScreen.ets'),
  path.join(SCREEN_DIR, 'DevicesScreen.ets'),
  path.join(SCREEN_DIR, 'FilesScreen.ets'),
  path.join(SCREEN_DIR, 'LoginScreen.ets'),
  path.join(SCREEN_DIR, 'NewSessionScreen.ets'),
  path.join(SCREEN_DIR, 'QrWaitingScreen.ets'),
  path.join(SCREEN_DIR, 'SettingsScreen.ets'),
  path.join(SCREEN_DIR, 'TerminalScreen.ets')
];
/** 允许保留的非图标字形：纯文本标点。 */
const PUNCT_OK = ['..', '/', '.', String.fromCodePoint(0x2014), String.fromCodePoint(0x2022), ''];
const WORD_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_%.:/ ';
/** R12-8 起设备 OS 图标改用上游位图资源（`Image` + `app.media.device_icon_*`），不再有逐文件例外。 */
const FILE_ALLOW = {};
const isWordOnly = (s) => {
  for (const ch of s) { if (WORD_CHARS.indexOf(ch) < 0) { return false; } }
  return true;
};
const hasCJK = (s) => {
  for (const ch of s) { const c = ch.codePointAt(0); if (c >= 0x4E00 && c <= 0x9FFF) { return true; } }
  return false;
};
/** 允许出现的非 ASCII 码位：省略号 / 破折号 / 间隔号（纯文本标点）。 */
const isAllowedChar = (ch) => {
  const c = ch.codePointAt(0);
  return c <= 0x7E || c === 0x2026 || c === 0x2014 || c === 0x2022;
};
/** 已删除的 ASCII 图标字面量（真机上也当图标用）。 */
const ASCII_ICON_LITS = ['+', '!', '>_'];
const Q = String.fromCharCode(39);
/** 逐字符扫描单引号字面量（正则 `'[^']{1,4}'` 会把相邻字符串之间的内容也吃进来）。 */
function singleQuotedLiterals(line) {
  const out = [];
  let i = 0;
  while (i < line.length) {
    if (line.charAt(i) !== Q) { i++; continue; }
    let j = i + 1;
    let value = '';
    while (j < line.length && line.charAt(j) !== Q) { value += line.charAt(j); j++; }
    out.push(value);
    i = j + 1;
  }
  return out;
}
const leftoverGlyphs = [];
const missingImports = [];
let scannedScreens = 0;
for (const file of ALL_UI_FILES) {
  // Icon.ets 是图标体系自身（其中的 '+' / ',' 是 path 解析代码，不是图标），只统计它的 import，不扫字形。
  const isIconModule = file.endsWith('Icon.ets');
  const cut = Math.max(file.lastIndexOf('/'), file.lastIndexOf(String.fromCharCode(92)));
  const base = file.substring(cut + 1);
  const raw = readSource(file);
  const code = codeOnly(raw);
  if (code.indexOf('AaIcon({') >= 0) {
    scannedScreens += 1;
    if (raw.indexOf('from ' + Q + './Icon' + Q) < 0 && raw.indexOf('from ' + Q + '../Icon' + Q) < 0) {
      missingImports.push(base);
    }
  }
  for (const line of (isIconModule ? [] : code.split(LF))) {
    for (const inner of singleQuotedLiterals(line)) {
      if (inner.length === 0 || inner.length > 6) { continue; }
      if (hasCJK(inner)) { continue; }
      if (ASCII_ICON_LITS.indexOf(inner) >= 0) { leftoverGlyphs.push(base + ':' + inner); continue; }
      const allow = FILE_ALLOW[base] || [];
      let bad = '';
      for (const ch of inner) {
        if (isAllowedChar(ch)) { continue; }
        if (allow.indexOf(ch) >= 0) { continue; }
        bad = ch;
        break;
      }
      if (bad.length > 0) { leftoverGlyphs.push(base + ':' + bad); }
    }
  }
}
check('扫描到 12 个使用矢量图标的 UI 文件', scannedScreens >= 12, 'got ' + scannedScreens);
eq('用 AaIcon 的文件都导入了 Icon 模块', missingImports.join(','), '');
eq('12 个 UI 文件里不再有字符 / emoji 图标（纯文本标点与设备 OS 位图除外）', leftoverGlyphs.join(','), '');
const devicesCode = codeOnly(readSource(path.join(SCREEN_DIR, 'DevicesScreen.ets')));
check('设备行图标改用上游位图（Image + deviceIconRes 查表）',
  devicesCode.indexOf('Image(this.deviceIconRes(device))') >= 0
  && devicesCode.indexOf('private deviceIconRes(device: AgentDevice): Resource') >= 0);
eq('设备行的 OS emoji 已删除',
  [String.fromCodePoint(0x1F5A5), String.fromCodePoint(0x1FA9F), String.fromCodePoint(0x1F427), String.fromCodePoint(0x1F4BB)]
    .filter((g) => devicesCode.indexOf(g) >= 0).join(','), '');
const MEDIA = path.join(SRC_ETS, '..', 'resources');
const MEDIA_NAMES = [];
for (const os of ['macos', 'windows', 'linux']) { for (const st of ['online', 'offline']) { MEDIA_NAMES.push('device_icon_' + os + '_' + st + '.png'); } }
const mediaMissing = [];
for (const n of MEDIA_NAMES) {
  for (const theme of ['base', 'dark']) {
    const f = path.join(MEDIA, theme, 'media', n);
    if (!fs.existsSync(f)) { mediaMissing.push(theme + '/' + n); continue; }
    if (fs.readFileSync(f).length < 1000) { mediaMissing.push(theme + '/' + n + '(太小)'); }
  }
}
eq('12 张设备位图（base + dark 各 6）都在且非空', mediaMissing.join(','), '');
/**
 * ## R80-4：设备图标改线性简笔画 —— 判据升级（旧断言在此被**改写**，不是删掉）
 * 旧断言：「深浅两版字节必须不同（不是复制同一个文件充数）」。
 * **新设计下它对『在线』不再成立**：在线色取既有令牌 `runtime_running`（#10B981），该令牌
 * 深浅两档**同值**（它与 DevicesScreen 的状态点 / 状态文字同色，是刻意的统一）⇒ base 与 dark 的
 * 在线图标**本就该逐字节相同**。
 * 于是把判据换成更硬的两条（直接解 PNG，而不是比字节）：
 *   ① **真·单色描边**：不透明像素的 RGB 唯一值必须 = 1（防渐变色 / 彩色杂边混进简笔画）；
 *   ② **颜色 = 既有令牌**：在线 `runtime_running`、离线 `muted`，按主题各自的取值逐字比对。
 * 另保留两条结构性护栏：离线两版必须不同（muted 有双值）、12 张里恰好 6 种内容。
 * 生成脚本见开发期验证记录（幂等、离线）。
 */
function readPngRGBA(file) {
  const buf = fs.readFileSync(file);
  let off = 8; let w = 0; let h = 0;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('latin1', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); }
    else if (type === 'IDAT') { idat.push(data); }
    else if (type === 'IEND') { break; }
    off += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const bpp = 4; const stride = w * bpp;
  const out = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y++) {
    const ft = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const prev = y === 0 ? Buffer.alloc(stride) : out.subarray((y - 1) * stride, y * stride);
    const cur = out.subarray(y * stride, (y + 1) * stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? cur[i - bpp] : 0;
      const b = prev[i];
      const c = i >= bpp ? prev[i - bpp] : 0;
      let v = line[i];
      if (ft === 1) { v = (v + a) & 255; }
      else if (ft === 2) { v = (v + b) & 255; }
      else if (ft === 3) { v = (v + ((a + b) >> 1)) & 255; }
      else if (ft === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a); const pb = Math.abs(p - b); const pc = Math.abs(p - c);
        v = (v + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))) & 255;
      }
      cur[i] = v;
    }
  }
  return { w: w, h: h, data: out };
}
/** 取 color.json 里某个既有令牌的 RGB（返回 6 位大写 hex；8 位值取后 6 位，丢掉 alpha）。 */
function tokenRgbHex(colorFile, name) {
  const text = fs.readFileSync(colorFile, 'utf8');
  const key = '"name": "' + name + '"';
  const at = text.indexOf(key);
  if (at < 0) { return ''; }
  const seg = text.slice(at, at + 120);
  const vAt = seg.indexOf('"value": "#');
  if (vAt < 0) { return ''; }
  const hex = seg.slice(vAt + 10, vAt + 10 + 8).replace(/[^0-9A-Fa-f]/g, '');
  return hex.slice(-6).toUpperCase();
}
const iconColorFails = [];
const iconSameFails = [];
const iconUniq = new Set();
for (const n of MEDIA_NAMES) {
  const isOnline = n.indexOf('_online') > 0;
  const tokenName = isOnline ? 'runtime_running' : 'muted';
  const raw = {};
  for (const theme of ['base', 'dark']) {
    const f = path.join(MEDIA, theme, 'media', n);
    const buf = fs.readFileSync(f);
    iconUniq.add(createHash('md5').update(buf).digest('hex'));
    const img = readPngRGBA(f);
    const rgb = new Set();
    for (let i = 0; i < img.data.length; i += 4) {
      if (img.data[i + 3] > 0) { rgb.add(img.data[i] + ',' + img.data[i + 1] + ',' + img.data[i + 2]); }
    }
    if (rgb.size !== 1) { iconColorFails.push(n + ':' + theme + ' RGB 有 ' + rgb.size + ' 种（应 1）'); }
    const want = tokenRgbHex(path.join(MEDIA, theme, 'element', 'color.json'), tokenName);
    let got = '';
    if (rgb.size === 1) {
      const one = rgb.values().next().value.split(',');
      got = one.map((x) => Number(x).toString(16).padStart(2, '0')).join('').toUpperCase();
    }
    if (want !== got) { iconColorFails.push(n + ':' + theme + ' 期望令牌 ' + tokenName + '=' + want + ' 实得 ' + got); }
    raw[theme] = buf;
  }
  if (!isOnline && raw.base.equals(raw.dark)) { iconSameFails.push(n); }
}
eq('R80-4 12 张设备图标都是单色描边（不透明像素 RGB 唯一值 = 1）', iconColorFails.join(','), '');
eq('R80-4 离线两版必须不同（muted 双值 #777777 / #A3A3A3）', iconSameFails.join(','), '');
// 12 张 = 在线 3（两档同色 ⇒ 3 种）+ 离线 3×2 主题（muted 双值 ⇒ 6 种）= **9** 种内容。
eq('R80-4 12 张里恰好 9 种内容（在线 3 + 离线 6；在线两档同色，允许 base 与 dark 同图）', String(iconUniq.size), '9');

group('AaSecondaryButton 的可选矢量图标（R12-5 新增）');
check('AaSecondaryButton 有可选 iconName（不传即旧行为）', componentsCode.indexOf('@Prop iconName: string') >= 0);
check('iconName 分支与纯文字分支并存（向后兼容）',
  componentsCode.indexOf('if (this.iconName.length > 0) {') >= 0 && componentsCode.indexOf('Text(this.label)') >= 0);
eq('文件页搜索上下步按钮用矢量图标（不再用文字箭头）',
  (readSource(path.join(SCREEN_DIR, 'FilesScreen.ets')).match(/iconName: 'chevron-(up|down)'/g) || []).length, 2);

group('R13-2：终端卡字形 / 字标字体 / 分组头 chevron');
const homeR13 = codeOnly(readSource(path.join(SCREEN_DIR, 'HomeScreen.ets')));
check('终端卡用 Lucide `terminal`（上游 HomeScreen.kt:687 `Lucide.Terminal`，无外框 >_）',
  homeR13.indexOf("this.quickEntryCard('终端', 'terminal', Route.TERMINAL)") >= 0);
eq('终端卡不再用 square-terminal（多一圈方框，真机 55×55 vs 安卓 49×43）',
  homeR13.split("'square-terminal'").length - 1, 0);
check('`terminal` 数据是上游那一条（`M12 19h8` 开头的下划线 + `m4 17` 折线）',
  TABLE['terminal'].indexOf('M12 19h8') === 0 && TABLE['terminal'].indexOf('M4 17l6') > 0 && TABLE['terminal'].indexOf('17Z') < 0);
check('`square-terminal` 仍保留在表里（其它入口/后续可能用）', TABLE['square-terminal'] !== undefined);
check('字标应用 Caveat 字体（.fontFamily(WORDMARK_FAMILY)）', homeR13.indexOf('.fontFamily(WORDMARK_FAMILY)') >= 0);
check('首页在首次渲染前注册字体（aboutToAppear 里的 ensureWordmarkFont()）',
  homeR13.indexOf('ensureWordmarkFont(this.getUIContext())') >= 0);
const componentsR13 = codeOnly(readSource(COMPONENTS_ETS));
check('字体注册走 font.registerFont + $rawfile（ArkUI 官方写法）',
  componentsR13.indexOf("ui.getFont().registerFont({ familyName: WORDMARK_FAMILY, familySrc: $rawfile('fonts/caveat_wght.ttf') })") >= 0);
check('字标字重按上游改用 Medium（AAWordmark.kt 的 FontWeight.Medium）',
  homeR13.indexOf('.fontWeight(FontWeight.Medium)') >= 0);
eq('字体注册一律走 UIContext.Font#registerFont（旧的全局 font.registerFont 已废弃，会破坏零告警基线）',
  (componentsR13.match(/\.registerFont\(/g) || []).length,
  (componentsR13.match(/getFont\(\)\.registerFont\(/g) || []).length);
check('字标字体注册按 UIContext 去重（WeakSet，Ability 重建后能重注册）',
  componentsR13.indexOf('new WeakSet<UIContext>()') >= 0);
const caveatPath = path.join(SRC_ETS, '..', 'resources', 'rawfile', 'fonts', 'caveat_wght.ttf');
check('Caveat 字体在位且与上游逐字节同尺寸（403648 B）',
  fs.existsSync(caveatPath) && fs.statSync(caveatPath).size === 403648);
check('分组头用 Lucide chevron（chevron-down / 收起时 chevron-right），与上游 HomeProjectComponents.kt:403 一致',
  homeR13.indexOf("ICONS['chevron-down']") >= 0 && homeR13.indexOf("ICONS['chevron-right']") >= 0);
eq('分组头不再用实心三角 ▾（R12 之前的字符近似）',
  homeR13.split(String.fromCodePoint(0x25BE)).length - 1, 0);

group('全工程 emoji 残留（allowlist = 已知待办，R12-8 扫描）');
/**
 * 白名单现已**清空**：R12-10 收掉会话详情最后 2 处 `Text('✓')` 之后，全工程 65 个 `.ets` 里已经没有字符/emoji 图标。
 * 若将来确实需要例外（例如上游就是位图/彩色），在这里登记并写明理由 —— 别把断言放宽成永远为真。
 */
const KNOWN_GLYPH_FILES = {};
const SYMBOL_CPS = [0x2611, 0x2610, 0x2713, 0x2715, 0x25A6, 0x24D8, 0x2699, 0x23FB, 0x22EF, 0x25BE, 0x25B8, 0x25B4, 0x2303, 0x2304, 0x2605, 0x25A3, 0x2630, 0x29C9, 0x2B07, 0xFF0B, 0x2039, 0x203A, 0x25A0, 0x25B6, 0x00D7];
const isGlyphChar = (ch) => {
  const c = ch.codePointAt(0);
  return c > 0xFFFF || SYMBOL_CPS.indexOf(c) >= 0;
};
function etsFiles(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { etsFiles(p, out); } else if (e.name.endsWith('.ets')) { out.push(p); }
  }
  return out;
}
const glyphFiles = {};
for (const file of etsFiles(SRC_ETS, [])) {
  const cut = Math.max(file.lastIndexOf('/'), file.lastIndexOf(String.fromCharCode(92)));
  const base = file.substring(cut + 1);
  for (const line of codeOnly(readSource(file)).split(LF)) {
    for (const lit of singleQuotedLiterals(line)) {
      for (const ch of lit) {
        if (isGlyphChar(ch)) { glyphFiles[base] = (glyphFiles[base] || 0) + 1; break; }
      }
    }
  }
}
const glyphFileNames = Object.keys(glyphFiles).sort();
eq('全工程 .ets 里没有字符 / emoji 字形（白名单为空）',
  glyphFileNames.filter((n) => !(n in KNOWN_GLYPH_FILES)).join(','), '');
const allowedGlyphFiles = Object.keys(KNOWN_GLYPH_FILES).sort().join(',');
eq('白名单与实际情况一致（多一个就红，少一个也红 —— 防陈旧白名单）',
  glyphFileNames.join(','), allowedGlyphFiles);

group('R57（T2b）：液态玻璃功能钮（唯一实现 + 功能栏落地）');
const GLASSICON_ETS = path.join(SRC_ETS, 'ui', 'GlassIcon.ets');
const glassIconSrc = readSource(GLASSICON_ETS);
const glassIconCode = codeOnly(glassIconSrc);
check('新增 ui/GlassIcon.ets，且只导入一次 Icon 模块（重复导入直接编译失败）',
  (glassIconSrc.split("from './Icon'").length - 1) === 1);
check('玻璃钮不内联 path（图标数据只有 Icon.ets 一处）',
  (glassIconCode.split('commands(').length - 1) === 0);
check('图标仍走 AaIcon（不自己画 Shape / Path，坐标空间三条铁律只有一处实现）',
  glassIconCode.indexOf('AaIcon({') >= 0 && glassIconCode.indexOf('Shape()') < 0);
// ⚠️ R57（T9）：亮边从 linearGradient（整盘，会透过 96% 透明的玻璃层把盘面整片点亮）
// 改为 radialGradient（环，内部 alpha=0）—— 见 GlassIcon.ets 文件头与 Design.ets 的 GlassSpec 注释。
// ⚠️ R57（T11）：镜面高光**整层下架**（参考图盘面无光斑）⇒ 从四层变三层；
// 亮环仍是径向环（内部 alpha=0），且必须画在玻璃**上面**（否则会被背景模糊糊进盘面）。
// ⚠️ R64（v4）：v3 的铺满 `linearGradient` **整层删除**，改为**上亮/下暗两段半环 + `.blur()` 外发光**
// （`.clip(true)` 裁半圈）。两段由 `arcSegments()` **数据驱动**、共用 `@Builder arcSegment()` ⇒
// 源码里 `radialGradient(` 仍是 **1 处实现**（渲染 2 段），`linearGradient(` 归零。
/**
 * ⚠️ **这条断言被改写过两次**（历史留着）：
 *  · 原文（R57/T9）要求 `linearGradient(` **= 0**（整盘渐变会把盘面整片点亮）；
 *  · R63/v3 改成「允许且恰好 1 次」；
 *  · **R64/v4 再翻回 0** —— 铺满渐变整层删除（SPEC §2.1 ❌），方向性改由**边缘弧**承担。
 * 与 `suite-design` 的「R64 沉浸光感 v4」组同源：**唯一实现仍在 GlassIcon.ets**，
 * 别处再加一套 = 红（Components.ets 的 radialGradient 已被同文件另一条断言钉死为 0）。
 */
check('四层合成只在 GlassIcon.ets（R64）：磨砂玻璃（含投影）+ 光弧层（含 bloom）+ 按压光效层 + 图标',
  glassIconCode.indexOf('radialGradient(') >= 0 && glassIconCode.indexOf('backgroundEffect(') >= 0
    && glassIconCode.indexOf('.shadow(') >= 0
    && (glassIconCode.split('linearGradient(').length - 1) === 0
    && glassIconCode.indexOf('.blur(GlassSpec.ARC_BLOOM)') >= 0
    && glassIconCode.indexOf('glassIconPressGlow()') >= 0
    && glassIconCode.indexOf('HIGHLIGHT_') < 0);
check('T13 光感：形变走官方 clickEffect(LIGHT)（系统默认缩放 0.90）',
  glassIconCode.indexOf('clickEffect({ level: ClickEffectLevel.LIGHT })') >= 0);
// ⚠️ T15：`brightness` 做按压提亮连续两轮真机失败（T13 方角亮块 / T14 状态永不进入）⇒ **整组移除**，
// 改由圆形覆盖层（backgroundColor + opacity）承担，@State 由**外层可命中节点**的 onTouch 驱动。
check('T15 光感：按压光效 = 显式覆盖层（backgroundColor + opacity），组件里 brightness 归零',
  glassIconCode.indexOf('.backgroundColor(glassIconPressGlow())') >= 0
    && glassIconCode.split('.brightness(').length - 1 === 0);
check('T15 光感：@State pressed 由外层 onTouch 驱动（装饰层收不到按压事件）',
  glassIconCode.indexOf('this.pressed = event.type === TouchType.Down') >= 0
    && glassIconCode.indexOf('.opacity(this.pressed ? 1 : 0)') >= 0);
check('T15 保留 disabled 档', glassIconCode.indexOf('disabled: { .opacity(') >= 0);
// ⚠️ R57（T16）→ **R65 改口径**：`lightEffect` 现在共 **2 处** ——
//   ① 档 2（S2）的实验分支；② **R65 官方沉浸光感分支**（`officialGlass()`，仅首页顶栏两个钮）。
//   默认自绘路径（档 0/S1）仍不启用（顶缘会贯穿出一条细亮线的教训仍有效）。
// ⚠️ Lead 要求：**不许只数次数** —— 第 2 处必须用**分支锚文**钉在官方分支内，
//   否则后人删掉官方分支时这条只会从 2 变 1、仍然绿（等于白设）。
const glassOfficialBody = glassIconCode.slice(
  glassIconCode.indexOf('officialGlass() {'), glassIconCode.indexOf('build() {'));
check('R65：lightEffect 共 2 处，且第 2 处在官方材质分支内（分支锚文限定）',
  (glassIconCode.split('lightEffect: {').length - 1) === 2
    && glassOfficialBody.indexOf('lightEffect: { color: Color.White }') >= 0);
/**
 * ⚠️ **R64 写法变更（断言必须跟着变）**：弧的 `radialGradient` 现在写在 `@Builder arcSegment()` 里，
 * 而 `@Builder` 在源码中位于 `build()` **之前** ⇒ 全文件 `indexOf` 比下标会把层序判反。
 * 层序只在 `build()` 的子节点序列里有意义 ⇒ 下面在 `build()` 切片内比较（T11 的结论本身不变）。
 */
const glassBuildAt = glassIconCode.indexOf('build() {');
const glassBuildCode = glassIconCode.slice(glassBuildAt);
check('T11 层序：玻璃层在光弧之前（在 build() 切片内比下标，比读注释可靠）',
  glassBuildCode.indexOf('backgroundEffect(') >= 0
    && glassBuildCode.indexOf('ForEach(this.arcSegments()') > glassBuildCode.indexOf('backgroundEffect('));
check('磨砂只用 backgroundEffect（不用 backgroundBlurStyle / backdropBlur）',
  glassIconCode.indexOf('backgroundBlurStyle') < 0 && glassIconCode.indexOf('backdropBlur') < 0);
/**
 * ⚠️ **R63 改写**（原文：两者合计必须 = 0 ——「三份实现 -> 一份」）。
 * 新口径（冻结规格 SPEC §2.3）：task-2 要给**顶栏 actionLabel 胶囊 / BottomNav 悬浮胶囊**
 * 加**同源**的渐变光层 ⇒ `linearGradient(` 在 Components.ets 里**允许**（同一套令牌 `glassSheen*`）。
 * 但**亮环的唯一实现仍在 `GlassIcon.ets`** ⇒ `radialGradient(` 在 Components.ets 里必须**恰好 0**：
 * 需要亮边的胶囊/圆钮请复用 `AaGlassIconButton` 的 `cornerRadius` 档（参数映射），
 * 自己再画一圈径向亮环 = 第二套玻璃实现，直接红。
 */
eq('v3：Components.ets 不许内联第二套径向亮环（radialGradient 恰好 0；linearGradient 允许，见上）',
  (componentsCode.split('radialGradient(').length - 1), 0);
eq('Components.ets 里玻璃钮只有 3 个落地点（顶栏返回钮 + 圆形钮玻璃档 + 悬浮钮玻璃档）',
  componentsCode.split('AaGlassIconButton({').length - 1, 3);
const topBarGlassAt = componentsCode.indexOf('AaGlassIconButton({');
const topBarChevronAt = componentsCode.indexOf("name: 'chevron-left'", topBarGlassAt);
check('AaTopBar 的返回钮改用共用的玻璃组件（32vp 圆 + chevron-left）',
  topBarGlassAt >= 0 && topBarChevronAt > topBarGlassAt && topBarChevronAt - topBarGlassAt < 400
  && componentsCode.indexOf('diameter: Control.NAV_BUTTON,', topBarGlassAt) > topBarGlassAt);
check('悬浮「+」的玻璃档用主色玻璃底（25% 白玻璃会让白图标糊掉）',
  componentsCode.indexOf('surface: glassPrimarySurface()') >= 0);
check('圆形钮的玻璃档不是第二套实现（参数映射里带着 tint / diameter）',
  componentsCode.indexOf('tint: this.tint,') >= 0 && componentsCode.indexOf('diameter: this.diameter,') >= 0);
/**
 * 功能栏落地清单（**去注释后**计数，避免说明性注释把计数抬高）：逐个文件钉住，
 * 缺一处或偷偷多开一处都会红。
 */
const glassOn = (rel) => codeOnly(readSource(path.join(SCREEN_DIR, rel))).split('glass: true').length - 1;
// ⚠️ R62：首页顶栏右侧的搜索钮已按用户要求换成**新建对话**钮，且悬浮「+」取消
// ⇒ 首页顶栏只剩 2 个玻璃钮（左头像 + 右新建对话）。这条断言的数字随之 3 → 2。
eq('首页顶栏两个钮都开了玻璃档（R62 起不再有悬浮「+」）', glassOn('HomeScreen.ets'), 2);
eq('设置页返回钮开了玻璃档', glassOn('SettingsScreen.ets'), 1);
eq('设备页返回钮开了玻璃档', glassOn('DevicesScreen.ets'), 1);
eq('选择工作区页返回钮开了玻璃档', glassOn('NewChatWorkspaceScreen.ets'), 1);
// ⚠️ R63：这条断言的数字 **2 → 4**。SPEC §2.3 第 4 条要求把 NewSessionScreen 的**两个功能栏圆钮**
// （源码锚 `diameter: 36` 那两处，原 2463/2474）也加上 `glass: true`；加上原有的顶栏两钮（40vp）
// ⇒ 该文件共 **4** 处玻璃档。
// ⚠️ **R82：数字 4 → 3**。R82 删掉了死代码「标题编辑态」（根因：能进 `!projectOnly` 模式的唯一路由
// `Route.NEW_SESSION` 全工程已无 push 点，铅笔钮在真机上永远渲染不到）——**顶栏的「编辑标题」铅笔钮
// 也是 `glass: true`**，它与编辑态一起被删 ⇒ **顶栏圆钮数 = 1（返回）**。
// 加上文件列表的 2 个 36vp 紧凑圆钮 = **3** 处。判据语义**一个字都没改**：
// **功能栏/顶栏圆钮一律走玻璃档**，缺一处/偷偷多开一处都会红。
eq('新建会话页 3 处玻璃档：顶栏返回钮 1 个（40vp，R82 起铅笔钮已随死编辑态删除）+ 功能栏/文件列表 2 个（36vp，SPEC §2.3-4）',
  glassOn('NewSessionScreen.ets'), 3);
/**
 * ⚠️ **R75 判据改写**（原文：会话详情页「本包只读」⇒ 玻璃档恰好 **0**）。
 *
 * R65-A 之后该页顶栏就已在 `Navigation` 标题栏内、两枚钮本来就该走官方材质；R75 用户明确要求
 * 「改为官方标题栏样式，取消自绘部分，确保视觉统一」⇒ 该页原来自绘的 **44vp `AaGlassIconButton`**
 * 换成与其余 8 页**同一套**的 `AaCircleIconButton` 玻璃档（40vp），因此 `glass: true` 由 0 → **2**。
 * 判据语义随之修正为「恰好两枚功能钮（⚙ 运行时设置 / 🗀 会话文件）」，多一处少一处仍然红。
 * ⚠️ R75 起本页**不再 import `AaGlassIconButton`**（走 `AaCircleIconButton` 的转发），
 * 所以这里的计数是**唯一**钉住该页玻璃落地点的断言。
 */
eq('会话详情页两枚功能钮走玻璃档（R75：由自绘 44vp 换成共用的 40vp 档）',
  glassOn('SessionDetailScreen.ets'), 2);
/**
 * ⚠️ **R63 判据改写**：这条断言原名叫「文件列表行内的两个小圆钮**有意保留**非玻璃档
 * （它们在实底卡片里，磨砂无内容可糊）」—— 那个理由**已被用户需求推翻**（SPEC §2.3 第 4 条
 * 明确要求这两处也开玻璃档）。**结构计数仍然成立**（恰好 2 个 36vp 紧凑圆钮），故保留；
 * 「它们现在是不是玻璃档」由上一条 `glassOn('NewSessionScreen.ets') === 3`（R82 起）统一钉住，
 * 不在本处重复计数（避免同一事实两处各写一遍、改一处忘一处）。
 */
eq('文件列表行内的 2 个紧凑圆钮（36vp）结构计数不变（R63 起它们已按 SPEC §2.3-4 开玻璃档）',
  codeOnly(readSource(path.join(SCREEN_DIR, 'NewSessionScreen.ets'))).split('diameter: 36').length - 1, 2);
// ⚠️ R64：`radialGradient` 仍是**唯一实现 1 处**（两段半环共用 @Builder，渲染 2 段）——计数口径见 suite-design。
eq('光弧只画一次实现（GlassIcon.ets 里 radialGradient 恰好 1 处 —— 两段半环共用 @Builder）',
  (glassIconCode.split('radialGradient(').length - 1), 1);
/**
 * ⚠️ **R64 改写（v3 的「恰好 1 次」已作废）**：v3 要求 `linearGradient(` 在 `GlassIcon.ets` 里 = 1
 * （铺满盘面的光层，对应 SPEC §2.1 v3 的层 ②）。**R64 把它整层删除** —— 真机实测它把光摊到盘面内部
 * （盘面 Δ+24、24 扇区极差 36），SPEC §2.1 明写 ❌ ⇒ 现在要求 **0 次**。
 * 方向性改由**两段半环 + bloom** 承担（细节在 suite-design 的 v4 组逐条钉住）。
 */
eq('v4：GlassIcon.ets 里 linearGradient 归零（原 v3「恰好 1 次」口径作废，SPEC §2.1）',
  (glassIconCode.split('linearGradient(').length - 1), 0);
check('v4：光弧是两段半环 + 外发光（数据驱动 ForEach + clip(true) + blur 走 ARC_BLOOM 令牌）',
  glassIconCode.indexOf('ForEach(this.arcSegments()') >= 0
    && glassIconCode.indexOf('.clip(true)') >= 0
    && glassIconCode.indexOf('.blur(GlassSpec.ARC_BLOOM)') >= 0);
check('v4：上段亮档 / 下段暗一档（同源弧色，下段弱一档 ⇒ 方向性）',
  glassIconCode.indexOf('high: glassArcHigh(), low: glassArcLow()') >= 0
    && glassIconCode.indexOf('high: glassArcDimHigh(), low: glassArcDimLow()') >= 0);
eq('磨砂只挂一次（backgroundEffect 恰好 1 处）',
  (glassIconCode.split('backgroundEffect(').length - 1), 1);

// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-icons: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-icons: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ' + String.fromCharCode(10007) + ' ' + item);
}
process.exit(1);
