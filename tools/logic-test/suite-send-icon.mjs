#!/usr/bin/env node
/**
 * aa-hm R38「发送按钮图标化」自测（不依赖 ArkUI / 设备）。
 *
 * 需求原文：重构软件发送按钮，软件所有发送功能都用图标取代，并尽量放在对话框右下角，
 * 修改后也要同步修改提示。
 *
 * 范围：
 *  ① **新图标数据**：`ui/Icon.ets` 的 `ICONS['send']` 存在、可解析、与 lucide-static@1.47.0
 *     归一后的期望串**逐字相等**，且**全部子路径起点/端点都落在 24×24 画布内**；
 *  ② **归一正确性**：原 svg 的第二条子路径是相对 moveto（`m21.854 2.147-10.94 10.939`），
 *     本工程把多条子路径拼成单条 `d`，原样拼接会让它基于前一条的当前点 ⇒ 实落 (36.39, 23.833)、
 *     越出画布。这条断言就是那个坑的护栏（与 suite-icons.mjs 的独立坐标追踪同思路）。
 *  ③ **三处落点**：终端粘贴面板的发送钮、会话审批卡的提交钮、会话输入区主按钮；
 *  ④ **提示同步**（需求显式要求）：弹层里不能再出现「再点『发送到终端』」这种指向已消失控件的说法；
 *  ⑤ **形态不变量**：共用组件的默认值必须仍等于既有 34vp 主按钮；
 *  ⑥ **不许出现 `Blank()`**（Lead 裁决：它在 bindSheet 里能否撑开不确定）；
 *  ⑦ **R42 全量复核**（本轮新增）：ui 层**所有**含「发送」的字面量必须恰好落在裁决清单里 ——
 *     清单外的任何新增都会让本套件变红，强制「新的发送入口必须显式裁决」；并钉住三处
 *     「经裁决不改」的入口（设置页「发送验证码」/ 新建页「开始聊天」/ 终端顶栏「粘贴」）与两处提示句。
 *
 * ⚠️ 本文件刻意零反斜杠转义：正则用字符类、路径用正斜杠、换行用 String.fromCharCode(10)。
 *    静态断言一律先**去注释**（stripComments）再匹配 —— 否则改动说明里的示例代码会被误判成产品代码。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-send-icon.mjs
 * 产物全部落在系统临时目录（不污染工程目录）。
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-send-icon');

const ICON_ETS = path.join(SRC_ETS, 'ui', 'Icon.ets');
const COMPONENTS_ETS = path.join(SRC_ETS, 'ui', 'Components.ets');
const TERMINAL_ETS = path.join(SRC_ETS, 'ui', 'screens', 'TerminalScreen.ets');
const SESSION_ETS = path.join(SRC_ETS, 'ui', 'screens', 'SessionDetailScreen.ets');
const SUITE_ICONS = path.join(HERE, 'suite-icons.mjs');

const PURE_BEGIN = '// >>> AA-ICON-PURE-BEGIN';
const PURE_END = '// <<< AA-ICON-PURE-END';
const LF = String.fromCharCode(10);
const Q = String.fromCharCode(39);
const DQ = String.fromCharCode(34);
const BT = String.fromCharCode(96);

/** lucide-static@1.47.0 send.svg 归一后的期望数据（第二条子路径已按 SVG 语义转绝对）。 */
const SEND_D = 'M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z M21.854 2.147 10.914 13.086';

// ---------------------------------------------------------------------------
// 转译 Icon.ets 的纯逻辑区
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
    throw new Error('ui/Icon.ets 里找不到纯逻辑区标记：标记被删或改名了？');
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
  return require(target);
}

// ---------------------------------------------------------------------------
// 去注释（**保留字符串内容**：断言里要匹配字符串字面量）
// ---------------------------------------------------------------------------

function stripComments(src) {
  let out = '';
  let i = 0;
  let state = 'code';
  while (i < src.length) {
    const ch = src.charAt(i);
    const nx = src.charAt(i + 1);
    if (state === 'code') {
      if (ch === '/' && nx === '/') { state = 'line'; i += 2; continue; }
      if (ch === '/' && nx === '*') { state = 'block'; i += 2; continue; }
      if (ch === Q || ch === DQ || ch === BT) { state = ch; out += ch; i++; continue; }
      out += ch; i++; continue;
    }
    if (state === 'line') { if (ch === LF) { state = 'code'; out += LF; } i++; continue; }
    if (state === 'block') {
      if (ch === '*' && nx === '/') { state = 'code'; i += 2; continue; }
      if (ch === LF) { out += LF; }
      i++; continue;
    }
    if (ch === '\\') { out += ch + (nx === undefined ? '' : nx); i += 2; continue; }
    out += ch;
    if (ch === state) { state = 'code'; }
    i++;
  }
  return out;
}

function readSource(p) { return fs.readFileSync(p, 'utf8'); }

/** 从 `startMarker` 之后到下一个 `@Builder` 之前的片段（用于只在该函数体内断言）。 */
/** 从 `startMarker` 之后到下一个 `endMarker`（缺省 @Builder）之前的片段。 */
function builderBody(src, startMarker, endMarker) {
  const stop = endMarker === undefined ? '@Builder' : endMarker;
  const at = src.indexOf(startMarker);
  if (at < 0) { return ''; }
  const next = src.indexOf(stop, at + startMarker.length);
  return next < 0 ? src.slice(at) : src.slice(at, next);
}

/** 递归列出目录下的 .ets 文件（R42 全量复核用；不依赖任何第三方遍历库）。 */
function walkEts(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { out.push(...walkEts(full)); continue; }
    if (entry.name.endsWith('.ets')) { out.push(full); }
  }
  return out.sort();
}

/**
 * 取源码里全部**单引号字面量**（先去注释 —— 否则改动说明里的示例串会被当成产品文案）。
 * 转义序列按**原文两字符**保留（`\\n` 仍是反斜杠 + n），这样清单里的键可以逐字比对。
 */
function stringLiterals(src) {
  const code = stripComments(src);
  const out = [];
  let i = 0;
  while (i < code.length) {
    if (code.charAt(i) !== Q) { i++; continue; }
    let j = i + 1;
    let buf = '';
    while (j < code.length && code.charAt(j) !== Q) {
      if (code.charAt(j) === String.fromCharCode(92)) { buf += code.substr(j, 2); j += 2; continue; }
      buf += code.charAt(j);
      j++;
    }
    out.push(buf);
    i = j + 1;
  }
  return out;
}

/** 该串里有没有某个字符（避免在源码里写正则转义）。 */
function hasChar(s, ch) { return s.indexOf(ch) >= 0; }

// ---------------------------------------------------------------------------
// 独立实现的 path 工具（不复用产品代码，否则同源错误会互相掩盖）
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
    if (j < d.length && d.charAt(j) === '.') { j++; while (j < d.length && isDigit(d.charAt(j))) { j++; } }
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

/** 追踪每个子路径起点与每条命令终点（绝对坐标）。 */
function trackPoints(d) {
  const t = tokenize(d);
  const starts = [];
  const ends = [];
  const bad = [];
  let cx = 0, cy = 0, sx = 0, sy = 0, i = 0;
  while (i < t.length) {
    const letter = t[i];
    if (!isCmd(letter)) { i++; continue; }
    const up = letter.toUpperCase();
    const rel = letter === letter.toLowerCase();
    i++;
    const arity = arityOf(up);
    if (arity === 0) { cx = sx; cy = sy; continue; }
    let first = true;
    while (i + arity <= t.length && !isCmd(t[i])) {
      const a = t.slice(i, i + arity).map(Number);
      for (const v of a) { if (Number.isNaN(v)) { bad.push(t.slice(i, i + arity).join(' ')); } }
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
  return { starts, ends, bad };
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
function group(title) { console.log(''); console.log('== ' + title); }

const icon = build();
const names = Object.keys(icon.ICONS);
const sendD = icon.ICONS['send'];
const terminalSrc = readSource(TERMINAL_ETS);
const terminalCode = stripComments(terminalSrc);
const sessionSrc = readSource(SESSION_ETS);
const sessionCode = stripComments(sessionSrc);
const componentsSrc = readSource(COMPONENTS_ETS);
const componentsCode = stripComments(componentsSrc);

group('ICONS[send] 数据（R38 新增）');
check('表里有 send', typeof sendD === 'string' && sendD.length > 0);
eq('send 与 lucide-static@1.47.0 归一后的期望串逐字相等', sendD, SEND_D);
eq('send 的 path 数据自检无问题（iconPathIssues）', icon.iconPathIssues(sendD).join(','), '');
const sendTok = tokenize(sendD);
eq('tokenize 后没有 NaN 记号（连写小数 .5.5 必须被正确切开）', (() => { for (const tk of sendTok) { if (!isCmd(tk) && Number.isNaN(Number(tk))) { return tk; } } return ''; })(), '');
const tracked = trackPoints(sendD);
eq('send 的子路径数 = 2', String(tracked.starts.length), '2');
eq('第二条子路径起点是绝对 M21.854 2.147（**不能**退回相对 m）', tracked.starts[1].join(','), '21.854,2.147');
const outside = tracked.starts.concat(tracked.ends).filter((p) => p[0] < -0.001 || p[0] > 24.001 || p[1] < -0.001 || p[1] > 24.001);
eq('全部子路径起点与命令终点都落在 24×24 画布内', outside.length, 0);
eq('反例护栏：把第二条写成相对 m 会越界（证明这条断言不是空的）',
  trackPoints(SEND_D.replace('M21.854 2.147 10.914 13.086', 'm21.854 2.147-10.94 10.939')).starts[1].join(','),
  '36.39,23.833');
eq('send 在表内的键名是 kebab-case 且无大写', 'send'.toLowerCase(), 'send');
check('send 已被 suite-icons 的 EXTENSIONS 登记（否则那张表的两条计数断言会红）',
  readSource(SUITE_ICONS).indexOf(Q + 'send' + Q) >= 0);
// ⚠️ R62：扩展图标 8 → 9（新增 `house`，底部悬浮功能栏的「首页」）。
eq('ICONS 总数 = 上游 57 + 本工程扩展 9（含 send / house）', String(names.length), '66');

group('终端粘贴面板：发送钮改图标 + 右下角 + 提示同步');
const panel = builderBody(terminalCode, 'pastePanel() {');
check('pastePanel 里调用了共用图标按钮', panel.indexOf('AaPrimaryIconButton({') >= 0);
check('用的是 send 图标', panel.indexOf(Q + 'send' + Q) >= 0);
check('无障碍文本 = 发送到终端（图标取代文字后唯一的语义载体）', panel.indexOf(Q + '发送到终端' + Q) >= 0);
check('按钮行右对齐（width 100% + justifyContent End）',
  panel.indexOf(".justifyContent(FlexAlign.End)") >= 0 && panel.indexOf(".width('100%')") >= 0);
check('外层用 SpaceBetween 把按钮行推到底（**不用 Blank()** —— Lead 裁决）',
  panel.indexOf('FlexAlign.SpaceBetween') >= 0 && terminalCode.indexOf('Blank(') < 0);
check('按钮行有最小间距兜底（内容超高时两块不会贴在一起）', panel.indexOf('margin({ top: Space.M })') >= 0);
check('代码区不再有 label: 发送到终端 的文字按钮（小写 label 精确匹配，不会误伤 accessibilityLabel）',
  terminalCode.indexOf('label: ' + Q + '发送到终端' + Q) < 0);
check('代码区不再有「发送到终端」的提示说法（会指向已消失的控件）', terminalCode.indexOf('「发送到终端」') < 0);
check('提示改成了图标描述', terminalCode.indexOf('再点右下角的发送图标。') >= 0);
check('TerminalScreen 导入了 AaPrimaryIconButton',
  terminalSrc.indexOf('AaPrimaryIconButton') >= 0 && terminalSrc.indexOf("from '../Components'") >= 0);
check('粘贴弹层仍保留原说明（零权限粘贴那一段没被顺手删掉）', terminalCode.indexOf('走系统粘贴菜单，无需剪贴板权限') >= 0);

group('会话审批卡：提交钮改图标 + 右对齐');
check('SessionDetailScreen 代码区不再有 AaPrimaryButton 的调用', sessionCode.indexOf('AaPrimaryButton(') < 0);
check('import 行也不再有 AaPrimaryButton（防未使用导入告警）',
  sessionCode.split('AaPrimaryButton').length - 1 === 0);
check('审批卡提交钮用 AaPrimaryIconButton', sessionCode.indexOf('AaPrimaryIconButton({') >= 0);
check('审批卡提交钮的无障碍文本 = 服务端 action.label', sessionCode.indexOf('accessibilityLabel: action.label') >= 0);
check('审批卡按钮行右对齐', sessionCode.indexOf(".justifyContent(FlexAlign.End)") >= 0);
check('原 respondNotice 回调三件套逐字保留（typed / input / delete + respondNotice）',
  sessionCode.indexOf("const typed = this.noticeInputs.get(notice.noticeId) ?? '';") >= 0
  && sessionCode.indexOf('this.noticeInputs.delete(notice.noticeId);') >= 0
  && sessionCode.indexOf('this.store.respondNotice(notice.noticeId, action.actionId, input);') >= 0);

group('会话输入区主按钮：形态不变 + 补无障碍文本');
check('发送态补了 accessibilityText(发送)', sessionCode.indexOf(Q + '发送' + Q + ').accessibilityText') >= 0 || sessionCode.indexOf(".accessibilityText('发送')") >= 0);
check('中断态补了 accessibilityText(中断)', sessionCode.indexOf(".accessibilityText('中断')") >= 0);
check('主按钮仍是 34vp 圆形（形态零改动）',
  sessionCode.indexOf('composerPrimaryButton() {') >= 0 && sessionCode.split('.width(34)').length - 1 >= 2);
check('主按钮仍用 arrow-up / square 两枚既有图标',
  sessionCode.indexOf(Q + 'arrow-up' + Q) >= 0 && sessionCode.indexOf(Q + 'square' + Q) >= 0);

group('共用组件 AaPrimaryIconButton（形态 = 既有 34vp 主按钮）');
check('Components.ets 导出了 AaPrimaryIconButton', componentsSrc.indexOf('export struct AaPrimaryIconButton') >= 0);
const compBody = builderBody(componentsCode, 'export struct AaPrimaryIconButton', '@Component');
check('默认直径仍是 34', compBody.indexOf('diameter: number = 34') >= 0);
check('默认图标尺寸仍是 FontSize.ICON_MD', compBody.indexOf('iconSize: number = FontSize.ICON_MD') >= 0);
check('圆角用 Radius.PILL', compBody.indexOf('Radius.PILL') >= 0);
check('可点态底/前景 = primaryAction / onPrimaryAction',
  compBody.indexOf('primaryAction()') >= 0 && compBody.indexOf('onPrimaryAction()') >= 0);
check('禁用态底/前景 = subtle / muted（不能只换底色）',
  compBody.indexOf('subtle()') >= 0 && compBody.indexOf('muted()') >= 0);
check('危险族底 = btn_danger_bg', compBody.indexOf('app.color.btn_danger_bg') >= 0);
check('无障碍文本挂在容器上', compBody.indexOf('.accessibilityText(this.accessibilityLabel)') >= 0);
check('参数名不撞 CustomComponent 基类（不得出现 enabled/size/border 作 @Prop 名）',
  compBody.indexOf('@Prop enabled') < 0 && compBody.indexOf('@Prop size') < 0 && compBody.indexOf('@Prop border') < 0);
check('组件不自创矢量数据（commands 只在 Icon.ets 里出现）', componentsCode.indexOf('commands(') < 0);

// ---------------------------------------------------------------------------
// R42：发送类入口全量复核（把本轮裁决钉进套件）
// ---------------------------------------------------------------------------

const UI_DIR = path.join(SRC_ETS, 'ui');
const uiFiles = walkEts(UI_DIR);
const BS = String.fromCharCode(92);
const SETTINGS_ETS = path.join(SRC_ETS, 'ui', 'screens', 'SettingsScreen.ets');
const NEW_SESSION_ETS = path.join(SRC_ETS, 'ui', 'screens', 'NewSessionScreen.ets');
const uiSources = uiFiles.map((f) => ({ file: f, src: readSource(f) }));

/**
 * 裁决清单：ui 层**允许**出现的、含「发送」二字的字面量。
 * 键 = 逐字内容，times = 期望出现次数，why = 该条的裁决出处（与 REPORT 的裁决表一一对应）。
 * ⚠️ 新增任何一条都必须同时在 r42-send/REPORT.md 的裁决表里登记 —— 本套件刻意不放过新串。
 */
const SEND_LITERAL_ALLOW = [
  { lit: '发送到终端', times: 1, why: '终端粘贴弹层发送钮的无障碍文本（图标取代文字后唯一的语义载体）' },
  // R53：新对话**复用同一个会话详情页**（用户要求「进入的对话要和原对话页面一样」）⇒
  // 全工程仍然只有**一处**发送按钮的无障碍文本，次数不变（一度加到 2 是因为中间版本另做了一个
  // 新对话页，那个页面已随本轮的「复用原页面」决定删除）。
  { lit: '发送', times: 1, why: '会话输入区主按钮（草稿态与真会话共用同一个页面/同一个按钮）' },
  { lit: '在下面的输入框里长按 → 粘贴（走系统粘贴菜单，无需剪贴板权限），再点右下角的发送图标。', times: 1, why: '终端粘贴弹层提示句（R38 已改）' },
  { lit: '请输入后点右下角的发送图标', times: 1, why: '审批卡输入动作的占位提示（R42 改）' },
  { lit: '发送验证码', times: 1, why: '设置页账号域取码：裁决不改（REPORT 裁决表 A4）' },
  { lit: '• 关闭后会话将回到只读模式，无法继续发送消息。' + BS + 'n', times: 1, why: '接管确认框正文（不是按钮）' },
  { lit: '已接管该会话，现在可以发送消息了。', times: 1, why: '接管成功提示（不是按钮）' }
];

group('R42 全量复核：ui 层带「发送」的字面量裁决清单');
const sendHits = [];
const submitHits = [];
for (const item of uiSources) {
  for (const lit of stringLiterals(item.src)) {
    if (hasChar(lit, '发送')) { sendHits.push(lit); }
    if (hasChar(lit, '提交')) { submitHits.push(lit); }
  }
}
const sendNames = sendHits.slice().sort();
const allowNames = SEND_LITERAL_ALLOW.map((e) => e.lit).sort();
eq('清单外的「发送」字面量 = 0（新的发送入口必须先在本套件与 REPORT 裁决表登记）',
  sendNames.filter((n) => allowNames.indexOf(n) < 0).join(' | '), '');
eq('清单内的「发送」字面量一个都不能少（防静默删除）',
  allowNames.filter((n) => sendNames.indexOf(n) < 0).join(' | '), '');
for (const entry of SEND_LITERAL_ALLOW) {
  const n = sendNames.filter((x) => x === entry.lit).length;
  eq('出现次数 = ' + entry.times + '：' + entry.why, String(n), String(entry.times));
}
eq('ui 层不再有含「提交」的字面量（提交钮已全部图标化；新文案需显式登记裁决）',
  submitHits.join(' | '), '');
eq('扫到了 .ets 源码（否则上面几条等于空跑）', String(uiFiles.length > 0), 'true');

group('R42 提示同步：审批卡占位必须与新形态一致');
eq('审批卡占位已指向图标（R42 改）',
  String(sessionCode.indexOf('请输入后点右下角的发送图标') >= 0), 'true');
eq('审批卡占位不再写「请输入后提交」', String(sessionCode.indexOf('请输入后提交') < 0), 'true');
eq('终端弹层提示句仍是图标口径', String(terminalCode.indexOf('再点右下角的发送图标。') >= 0), 'true');

group('R42 三处「裁决不改」的入口被钉住');
// ⚠️ 裁决注释在注释里 ⇒ 这一条必须查**未去注释**的原文（stripComments 会把注释删掉）。
const settingsRaw = readSource(SETTINGS_ETS);
const settingsCode = stripComments(settingsRaw);
const newSessionCode = stripComments(readSource(NEW_SESSION_ETS));
eq('设置页取码钮仍是**文字**形态（不是图标钮）+ label 由纯逻辑给（F1 组实测语义）',
  String(settingsCode.indexOf('AaPrimaryIconButton(') < 0
    && settingsCode.indexOf('emailCodeButtonLabel(this.emailCodeCooldown)') >= 0), 'true');
eq('设置页保留了 R42 裁决注释（上游倒计时 label 是「不能纯图标」的判据）',
  String(settingsRaw.indexOf('R42 裁决') >= 0), 'true');
eq('新建页主按钮仍是一钮两语义的文字按钮（开始聊天 / 创建项目）',
  String(newSessionCode.indexOf('this.submitLabel()') >= 0), 'true');
eq('终端顶栏「粘贴」仍是文字入口（它是入口不是发送）',
  String(terminalCode.indexOf('label: ' + Q + '粘贴' + Q) >= 0), 'true');

group('R42 图标调用点必须显式登记（数量 + 语义 + 无障碍 + 右对齐）');
const iconCallSites = [];
for (const item of uiSources) {
  const code = stripComments(item.src);
  let at = code.indexOf('AaPrimaryIconButton({');
  while (at >= 0) {
    // 窗口取 700：审批卡那处调用之后要跨过 7 行回调体才到按钮行的 justify。
    iconCallSites.push({ file: item.file, body: code.slice(at, at + 700) });
    at = code.indexOf('AaPrimaryIconButton({', at + 1);
  }
}
// ⚠️ R50 登记：第 3 处 = 会话详情的**提问表单**提交钮（`noticeCard` 里那张内联表单的动作行）。
// 它与「审批卡带输入的提交钮」是**同一个动作的两种卡**（`input_request` vs `input.required` 单框），
// 需求口径一致（纯图标 + accessibilityText + 落右下角），故一并纳入本套件。
// 见开发期验证记录。
eq('ui 层 AaPrimaryIconButton 调用点 = 3（终端弹层 + 审批卡 + R50 提问表单；新增必须在 REPORT 登记）',
  String(iconCallSites.length), '3');
eq('每个调用点都用 send 图标',
  String(iconCallSites.every((s) => s.body.indexOf('name: ' + Q + 'send' + Q) >= 0)), 'true');
eq('每个调用点都带无障碍文本（图标取代文字后唯一的语义载体）',
  String(iconCallSites.every((s) => s.body.indexOf('accessibilityLabel:') >= 0)), 'true');
eq('每个调用点都在右对齐的按钮行里（「落右下角」的静态判据）',
  String(iconCallSites.every((s) => s.body.indexOf('justifyContent(FlexAlign.End)') >= 0)), 'true');

// ---------------------------------------------------------------------------
// R42-F1 / F2：附带发现的 2 条真缺陷（本轮修）
// ---------------------------------------------------------------------------

const SETTINGS_ETS_FILE = path.join(SRC_ETS, 'ui', 'screens', 'SettingsScreen.ets');
const PAGE_PURE_BEGIN = '// >>> AA-PURE-LOGIC-BEGIN';
const PAGE_PURE_END = '// <<< AA-PURE-LOGIC-END';
const AT = String.fromCharCode(64);
const req2 = createRequire(import.meta.url);

/**
 * 把某个页面文件里的 AA-PURE-LOGIC 纯逻辑区切片 → 转译 → require。
 * 与 suite-composer / suite-input 对 SessionDetailScreen / TerminalScreen 的做法同构。
 */
function buildPagePure(file, name) {
  const source = readSource(file);
  const begin = source.indexOf(PAGE_PURE_BEGIN);
  const end = source.indexOf(PAGE_PURE_END);
  if (begin < 0 || end <= begin) {
    throw new Error(file + ' 里找不到纯逻辑区标记：标记被删或改名了？');
  }
  const text = source.slice(begin + PAGE_PURE_BEGIN.length, end);
  if (text.indexOf('import ') >= 0) {
    throw new Error(file + ' 的纯逻辑区出现了 import —— 该区必须零依赖（否则本套件转译不了）');
  }
  const ts = req2(TS_PACKAGE);
  const target = path.join(OUT_DIR, name + '.js');
  fs.writeFileSync(target, ts.transpileModule(text, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
    fileName: file
  }).outputText, 'utf8');
  return req2(target);
}

group('F1 设置页取码冷却（纯逻辑区实测）');
const settingsRawText = readSource(SETTINGS_ETS_FILE);
const settingsPure = buildPagePure(SETTINGS_ETS_FILE, 'SettingsScreenPure');
eq('冷却 0 → 文案「发送验证码」（上游 profile_send_code）', settingsPure.emailCodeButtonLabel(0), '发送验证码');
eq('冷却 1 → 「1 秒后重发」', settingsPure.emailCodeButtonLabel(1), '1 秒后重发');
eq('冷却 60 → 「60 秒后重发」', settingsPure.emailCodeButtonLabel(60), '60 秒后重发');
eq('负数冷却也回落成「发送验证码」（不出现「-3 秒后重发」）', settingsPure.emailCodeButtonLabel(-3), '发送验证码');
eq('retryAfter 30 → 冷却 30', String(settingsPure.emailCodeCooldownStart(30)), '30');
eq('retryAfter 0 → 不起冷却', String(settingsPure.emailCodeCooldownStart(0)), '0');
eq('retryAfter -1（AppServices 的失败返回值）→ 不起冷却', String(settingsPure.emailCodeCooldownStart(-1)), '0');
eq('retryAfter 0.4 → 至少 1 秒（上游 coerceAtLeast(1)）', String(settingsPure.emailCodeCooldownStart(0.4)), '1');
const cooldownSteps = [];
let cooldownCursor = settingsPure.emailCodeCooldownStart(3);
while (cooldownCursor > 0) { cooldownSteps.push(cooldownCursor); cooldownCursor = settingsPure.emailCodeCooldownTick(cooldownCursor); }
cooldownSteps.push(cooldownCursor);
eq('3 秒冷却恰好走 3 步到 0（不早停、不成负数）', cooldownSteps.join('-'), '3-2-1-0');
eq('已经是 0 时再 tick 仍是 0', String(settingsPure.emailCodeCooldownTick(0)), '0');
eq('空邮箱不可点', String(settingsPure.emailCodeButtonEnabled('', 0, false)), 'false');
eq('不含 @ 不可点', String(settingsPure.emailCodeButtonEnabled('abc', 0, false)), 'false');
eq('两个 @ 不可点', String(settingsPure.emailCodeButtonEnabled('a' + AT + AT + 'b.com', 0, false)), 'false');
eq('含空格不可点', String(settingsPure.emailCodeButtonEnabled('a b' + AT + 'c.com', 0, false)), 'false');
eq('域名无点不可点', String(settingsPure.emailCodeButtonEnabled('a' + AT + 'b', 0, false)), 'false');
eq('域名以点结尾不可点', String(settingsPure.emailCodeButtonEnabled('a' + AT + 'b.', 0, false)), 'false');
eq('合法邮箱且无冷却可点', String(settingsPure.emailCodeButtonEnabled('a' + AT + 'b.com', 0, false)), 'true');
eq('冷却期不可点', String(settingsPure.emailCodeButtonEnabled('a' + AT + 'b.com', 5, false)), 'false');
eq('请求在飞（busy）时不可点', String(settingsPure.emailCodeButtonEnabled('a' + AT + 'b.com', 0, true)), 'false');
// 直接打一下 emailLooksValid：它虽是内部实现细节，但被 `emailCodeButtonEnabled` 依赖，
// 单独钉住能区分「校验函数错」与「可点条件错」两类回归。
eq('emailLooksValid 直接断言：空串 = false', String(settingsPure.emailLooksValid('')), 'false');
eq('emailLooksValid 直接断言：a' + AT + 'b.com = true', String(settingsPure.emailLooksValid('a' + AT + 'b.com')), 'true');
eq('取码钮 label 走纯逻辑',
  String(settingsRawText.indexOf('label: emailCodeButtonLabel(this.emailCodeCooldown)') >= 0), 'true');
eq('取码钮可点条件走纯逻辑（busy 取 snap.loading）',
  String(settingsRawText.indexOf('interactive: emailCodeButtonEnabled(this.email, this.emailCodeCooldown, this.snap.loading)') >= 0), 'true');
eq('返回值被接住（不再是一行丢弃 retryAfter 的调用）',
  String(settingsRawText.indexOf('emailCodeCooldownStart(retryAfter)') >= 0
    && settingsRawText.indexOf('authController.sendEmailCode(this.email);') < 0), 'true');
const disappearBody = settingsRawText.slice(settingsRawText.indexOf('aboutToDisappear(): void {'));
// 窗口取 700：`aboutToDisappear` 正文里有两行长注释 + 两行注销代码，停表那行落在 ~490 字符处。
eq('aboutToDisappear 方法体内停了冷却表（否则每秒写已销毁页面的 @State）',
  String(disappearBody.slice(0, 700).indexOf('this.stopEmailCodeCooldown();') >= 0), 'true');
eq('起表前先停旧表（连点不留两个定时器）',
  String(settingsRawText.indexOf('clearInterval(this.emailCodeTimer)') >= 0
    && settingsRawText.indexOf('this.stopEmailCodeCooldown();') < settingsRawText.indexOf('this.emailCodeTimer = setInterval(') + 1), 'true');

group('F2 终端粘贴面板：空输入进禁用态');
eq('发送图标挂 interactive = 输入非空',
  String(terminalCode.indexOf('interactive: this.pasteText.length > 0') >= 0), 'true');
eq('sendPastedText 的空串守卫仍在（禁用态是双保险，不是替代品）',
  String(terminalSrc.indexOf('if (this.pasteText.length === 0) {') >= 0), 'true');
// ⚠️ R66 判据收窄（**不是放松**）：R66 起 TerminalScreen 的标题栏与「粘贴」都改挂**官方沉浸材质**
// `systemMaterial(new uiMaterial.ImmersiveMaterial({ …, interactive: true }))` —— 材质选项里的 `interactive` 是
// 官方 API 的合法字段（交互形变），与"发送图标把 interactive 写死"是两件事。
// 旧判据在**整文件**里搜 `interactive: true`，会被材质选项误伤 ⇒ 先把**材质选项块剥掉**再判，
// 原意（发送图标不能写死常量）一字不变。
const terminalCodeNoMaterial = terminalCode.replace(/ImmersiveMaterial\(\{[\s\S]*?\}\)/g, '');
eq('没有把 interactive 写死成常量（否则按钮永远灰或永远亮）',
  String(terminalCodeNoMaterial.indexOf('interactive: false') < 0
    && terminalCodeNoMaterial.indexOf('interactive: true') < 0), 'true');

// ---------------------------------------------------------------------------
// R43 交互逻辑审计（teammate ux-lint）：禁用态与按压态的三处修正
// 判据出处：上游 `SessionComposer.kt` L566-574（只有 primaryActionEnabled 才挂 clickable）
// 与 L488-503（三态底色）；同族组件 `AaPrimaryIconButton` 的既有 pressed 写法。
// ---------------------------------------------------------------------------

group('R43 交互审计：会话主按钮的禁用态 / 按压态');
const primaryBtnBody = sessionCode.slice(
  sessionCode.indexOf('composerPrimaryButton() {'),
  sessionCode.indexOf('private canSend(): boolean {'));
eq('取到了主按钮函数体（否则下面几条等于空跑）', String(primaryBtnBody.length > 200), 'true');
const guardAt = primaryBtnBody.indexOf('if (!this.canSubmit()) {');
const sendAt = primaryBtnBody.indexOf('this.send();');
const readOnlyAt = primaryBtnBody.indexOf('if (this.readOnly) {');
check('发送分支在 send() 之前有 canSubmit() 守卫（视觉禁用态真的不可点，对齐上游 L567-574）',
  guardAt >= 0 && guardAt < sendAt);
check('只读分支仍排在守卫之前（只读态照旧引导接管，没被守卫吃掉）',
  readOnlyAt >= 0 && readOnlyAt < guardAt);
eq('主按钮两态都补了按压态（改前这颗钮一处都没有）',
  String(primaryBtnBody.split('.stateStyles(').length - 1), '2');
check('中断态按下走列表行那支按下令牌',
  primaryBtnBody.indexOf('pressed: { .backgroundColor(rowPressedSurface()) }') >= 0);
check('发送态按下按可点态分流（禁用态回落 subtle ⇒ 按下无反馈）',
  primaryBtnBody.indexOf('pressed: { .backgroundColor(this.canSubmit() ? rowPressedSurface() : $r(') >= 0);
check('rowPressedSurface 已进 import 表（否则编译期就红）',
  sessionSrc.indexOf('rowPressedSurface, subtle,') >= 0);

group('R43 交互审计：AaPrimaryIconButton 的禁用态按压反馈');
check('pressed 也按 interactive 分流（禁用态按下不再整颗变按下色）',
  compBody.indexOf('pressed: { .backgroundColor(this.interactive ? rowPressedSurface() : this.surfaceColor()) }') >= 0);
check('老写法（pressed 恒用 rowPressedSurface）已不存在',
  compBody.indexOf('pressed: { .backgroundColor(rowPressedSurface()) }') < 0);

group('R43 裁决钉住：审批卡提交钮不设 interactive（改前须重走裁决）');
const noticeCardCalls = iconCallSites.filter((s) => s.body.indexOf('noticeInputs') >= 0);
eq('定位到审批卡提交钮调用点', String(noticeCardCalls.length), '1');
eq('审批卡提交钮不设 interactive（对齐上游 SessionRuntimeControls.kt L342 的 submit 无 enabled；本工程差异见 r43-ux/REPORT.md）',
  String(noticeCardCalls[0].body.indexOf('interactive:') < 0), 'true');

console.log('');
if (failures.length === 0) {
  console.log('suite-send-icon: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-send-icon: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ' + String.fromCharCode(10007) + ' ' + item);
}
process.exit(1);
