#!/usr/bin/env node
/**
 * aa-hm「Scroll 顶部对齐」契约自测（R13-17）。
 *
 * 根因：ArkUI 的 `align` 是**通用属性**，SDK 默认值是 `Alignment.Center`
 *   （`common.d.ts`：align(value: Alignment) Default value: Alignment.Center），
 *   它管的是「组件内容在其绘制区内的对齐」⇒ **Scroll 的内容比视口短时会被垂直居中**。
 *   实证两处：设置页 F-10（内容 1739px < 视口 2408px ⇒ 上下各空 334px）、
 *   文件预览页 R13-17（正文首行 y 1656，与 chips 底边相距 603px）。
 *   两处都靠 `.align(Alignment.Top)` 修好。
 *
 * ⚠️ 断言必须检查**参数值**，不能只检查属性名存在。
 *   本套件的第一版只判 `.align` 出现过，于是把 `.align(Alignment.Center)`（= 未修的形态）
 *   也判成 PASS —— 变异测试当场抓出这个假绿。现在比对 `align` 的实参里是否含 `Top`。
 *
 * 用法（workdir = projects/aa-hm）：node tools/logic-test/suite-scroll-align.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'ets');
const NL = String.fromCharCode(10);
const WS = ' ' + NL + String.fromCharCode(13) + String.fromCharCode(9);

let pass = 0;
const fails = [];
function ok(cond, msg) { if (cond) { pass++; } else { fails.push(msg); } }
function read(p) { return fs.readFileSync(p, 'utf8'); }

/** 跳过空白与注释（块注释与行注释），返回第一个非空白非注释字符的下标。 */
function skipTrivia(src, j) {
  while (j < src.length) {
    const c = src.charAt(j);
    if (WS.indexOf(c) >= 0) { j += 1; continue; }
    if (src.substr(j, 2) === '/*') { const k = src.indexOf('*/', j + 2); j = k < 0 ? src.length : k + 2; continue; }
    if (src.substr(j, 2) === '//') { const k = src.indexOf(NL, j); j = k < 0 ? src.length : k + 1; continue; }
    break;
  }
  return j;
}

/** j 指向 '('，返回配对 ')' 之后的下标。 */
function skipCall(src, j) {
  let depth = 0;
  while (j < src.length) {
    const c = src.charAt(j);
    if (c === '(') { depth += 1; } else if (c === ')') { depth -= 1; if (depth === 0) { return j + 1; } }
    j += 1;
  }
  return j;
}

/** 收集 `Scroll() {…}` 之后的连续属性，返回 [{ name, arg }]。 */
function attrsOf(src, braceIdx) {
  let i = braceIdx, depth = 0;
  while (i < src.length) {
    const c = src.charAt(i);
    if (c === '{') { depth += 1; } else if (c === '}') { depth -= 1; if (depth === 0) { break; } }
    i += 1;
  }
  let j = skipTrivia(src, i + 1);
  const attrs = [];
  while (j < src.length && src.charAt(j) === '.') {
    let k = j + 1;
    while (k < src.length && /[A-Za-z0-9_]/.test(src.charAt(k))) { k += 1; }
    if (k === j + 1) { break; }
    const name = src.slice(j + 1, k);
    const open = src.indexOf('(', k);
    let arg = '';
    let after = k;
    if (open >= 0 && open - k < 3) {
      after = skipCall(src, open);
      arg = src.slice(open + 1, after - 1);
    }
    attrs.push({ name: name, arg: arg });
    j = skipTrivia(src, after);
  }
  return attrs;
}

/** 找出 src 里所有 `Scroll() {` 的 `{` 下标。 */
function scrollSpots(src) {
  const spots = [];
  let i = 0;
  while (true) {
    const k = src.indexOf('Scroll()', i);
    if (k < 0) { break; }
    const b = src.indexOf('{', k);
    if (b > k && b - k < 20) { spots.push(b); }
    i = k + 8;
  }
  return spots;
}

/** ⚠️ 关键：比对**参数值**，不是属性名。`.align(Alignment.Center)` 必须判为不合格。 */
function hasTopAlign(src, braceIdx) {
  for (const a of attrsOf(src, braceIdx)) {
    if (a.name === 'align' && a.arg.indexOf('Top') >= 0) { return true; }
  }
  return false;
}

function isHorizontal(src, braceIdx) {
  for (const a of attrsOf(src, braceIdx)) {
    if (a.name === 'scrollable' && a.arg.indexOf('Horizontal') >= 0) { return true; }
  }
  return false;
}

// ---- ① 配对页 ----
const addDevice = read(path.join(SRC, 'ui', 'screens', 'AddDeviceScreen.ets'));
const adSpots = scrollSpots(addDevice);
ok(adSpots.length >= 1, 'AddDeviceScreen 里找不到 Scroll()');
ok(adSpots.length > 0 && hasTopAlign(addDevice, adSpots[0]),
   'AddDeviceScreen 的 Scroll 缺 .align(Alignment.Top) —— 内容短于视口时会被垂直居中');

// ---- ② 设置页 ----
const settings = read(path.join(SRC, 'ui', 'screens', 'SettingsScreen.ets'));
const stSpots = scrollSpots(settings);
ok(stSpots.length >= 1, 'SettingsScreen 里找不到 Scroll()');
ok(stSpots.length > 0 && hasTopAlign(settings, stSpots[0]),
   'SettingsScreen 的 Scroll 缺 .align(Alignment.Top)（F-10 的根因）');

// ---- ③ 文件预览面板：锚文定位（行号会漂）----
const files = read(path.join(SRC, 'ui', 'screens', 'FilesScreen.ets'));
const sheetAt = files.indexOf('previewSheet() {');
ok(sheetAt >= 0, 'FilesScreen 里找不到 previewSheet() {（锚文失效）');
if (sheetAt >= 0) {
  const next = files.indexOf('@Builder', sheetAt + 20);
  const body = next < 0 ? files.slice(sheetAt) : files.slice(sheetAt, next);
  const fsSpots = scrollSpots(body);
  ok(fsSpots.length >= 1, 'previewSheet() 里找不到 Scroll()');
  ok(fsSpots.length > 0 && hasTopAlign(body, fsSpots[0]),
     'previewSheet() 的内容 Scroll 缺 .align(Alignment.Top) —— R13-17 的根因（正文被推到中间）');
}

// ---- ④ 全工程：每个 Scroll 都必须显式声明对齐（对齐轴随方向不同）----
//
// R14 教训：本套件原先只判「已经写了 align 的地方参数是不是 Top」，于是**完全没写 align**
// 的 Scroll 全部漏过 —— 新建项目页实测内容被垂直居中（上下各空 491px）却一直是绿的。
// 现在反过来：纵向 Scroll 必须有 `Top*`，横向 Scroll 必须有 `*Start`。
//
// ⚠️ 扫描前必须**去掉注释**：FilesScreen 里有一句注释写着「改前是 Scroll(){ … }」，
// 不去注释会把它当成一处真实 Scroll（假阳性）。
function stripComments(src) {
  let out = '';
  let i = 0;
  while (i < src.length) {
    if (src.substr(i, 2) === '/*') { const k = src.indexOf('*/', i + 2); i = k < 0 ? src.length : k + 2; out += ' '; continue; }
    if (src.substr(i, 2) === '//') { const k = src.indexOf(NL, i); i = k < 0 ? src.length : k; out += ' '; continue; }
    out += src.charAt(i);
    i += 1;
  }
  return out;
}

let scanned = 0;
let vertMissing = 0;
let horizMissing = 0;
const offenders = [];
function walk(d) {
  for (const f of fs.readdirSync(d)) {
    const p = path.join(d, f);
    if (fs.statSync(p).isDirectory()) { walk(p); continue; }
    if (!f.endsWith('.ets')) { continue; }
    const s = stripComments(read(p));
    for (const b of scrollSpots(s)) {
      scanned += 1;
      const attrs = attrsOf(s, b);
      const horiz = isHorizontal(s, b);
      let arg = null;
      for (const a of attrs) { if (a.name === 'align') { arg = a.arg; } }
      const good = arg !== null && (horiz ? arg.indexOf('Start') >= 0 : arg.indexOf('Top') >= 0);
      if (!good) {
        if (horiz) { horizMissing += 1; } else { vertMissing += 1; }
        offenders.push(path.relative(SRC, p).replace(/\\/g, '/') + (horiz ? ' (横向，需 Alignment.Start)' : ' (纵向，需 Alignment.Top)'));
      }
    }
  }
}
walk(path.join(SRC, 'ui'));
ok(scanned >= 10, '全工程 Scroll 数量异常（扫描到 ' + scanned + ' 处，预期 ≥ 10）');
ok(vertMissing === 0, '有 ' + vertMissing + ' 处纵向 Scroll 没写 .align(Alignment.Top) —— 内容短于视口时会被垂直居中：' + offenders.join('; '));
ok(horizMissing === 0, '有 ' + horizMissing + ' 处横向 Scroll 没写 .align(Alignment.Start) —— 内容窄于视口时会被水平居中：' + offenders.join('; '));

// ---- ⑤ 回归锚点：新建项目（projectOnly）的滚动内容必须顶对齐 ----
// 现场证据：模拟器 61-new-project dump，视口 [0,339][1316,2485]、内容 [0,830][1316,1994]，
// 上下各空 491px —— 正是 align 默认 Center 造成的。
const newSession = read(path.join(SRC, 'ui', 'screens', 'NewSessionScreen.ets'));
const rbAt = newSession.indexOf('readyBody() {');
ok(rbAt >= 0, 'NewSessionScreen 里找不到 readyBody() {（锚文失效）');
if (rbAt >= 0) {
  const next = newSession.indexOf('@Builder', rbAt + 20);
  const body = next < 0 ? newSession.slice(rbAt) : newSession.slice(rbAt, next);
  const nsSpots = scrollSpots(body);
  ok(nsSpots.length >= 1, 'readyBody() 里找不到 Scroll()');
  ok(nsSpots.length > 0 && hasTopAlign(body, nsSpots[0]),
     'readyBody() 的 Scroll 缺 .align(Alignment.Top) —— 新建项目页内容会被垂直居中（R14 实证）');
}

if (fails.length > 0) {
  console.error('suite-scroll-align: ' + fails.length + ' 条断言失败');
  for (const f of fails) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-scroll-align: ' + pass + ' 条断言全绿（扫过 ' + scanned + ' 处 Scroll）。');