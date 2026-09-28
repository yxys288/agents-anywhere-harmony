#!/usr/bin/env node
/**
 * aa-hm「Navigation 标题栏**结构口径**」自测（R81 新增）。
 *
 * 为什么值得单列：R81 把 9 个 `Navigation` 标题栏页面的行高统一到
 * `Control.NAV_TITLE_ROW`(46)（判据/来历见  与
 * 开发期验证记录）。这类「一行一个常量」的口径
 * **最容易在后续轮次被回退**（改一个页面就少一处），而 suite-design 只钉令牌值、
 * 看不到「哪个页面用了哪个写法」⇒ 本套件补的就是这条**结构性闸门**。
 *
 * 三条判据：
 *  ① 顶栏已进框架标题栏的**全部 10 个**页面（R86 起含 `AddDeviceScreen` / `DeviceDetailScreen`，
 *     构造器名按页给出：8 页是 `navTitleBar()`，这两页沿用 `topBar()`）：
 *     `builder` 内必须是 `.height(Control.NAV_TITLE_ROW)`，
 *     且**整页**不得再出现 `.height(Control.TOP_BAR_PAGE)`；
 *  ② R86 迁移完成 ⇒ 两页**不得**再保留自绘顶栏的自我避让 `.height(Control.TOP_BAR_PAGE + this.topInset())`
 *     （框架接管安全区，留着就是**重复避让** 137px，见 ）；
 *  ③ `TerminalScreen` 的 `MENU_TOP`（`FilesScreen` 也 import 它）必须由
 *     `Control.NAV_TITLE_ROW` 推出、不得再引用 `Control.TOP_BAR_PAGE`。
 *  ④ **R82 死代码回潮闸门**：`ui/Router.ets` 不得再出现 `new_session`（死路由），
 *     `NewSessionScreen` 不得再出现 `editingTitle` / `pencil`，其 `navTitleBar()` 内不得再出现 `TextInput`。
 *  ⑤ 本套件自己的**鉴别力自检**（内存变异 + 注释剥离）。
 *
 * ⚠️ 本文件的源码扫描**一律先剥注释**（`//` 行注释 + 块注释）——
 *    本工作区踩过「注释里的示例写法被当成真代码」的坑（KEYDECK 那一轮）。
 *
 * 用法（workdir = projects/aa-hm）：node tools/logic-test/suite-topbar.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCREEN_DIR = path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'ets', 'ui', 'screens');

/** 顶栏已进 `Navigation.title(...)` 的页面：行高一律走 `Control.NAV_TITLE_ROW`。
 *  ⚠️ **R86 起改成「页名 + 构造器名」配对**：`AddDeviceScreen` / `DeviceDetailScreen` 迁入框架标题栏时
 *  沿用它们原本的构造器名 `topBar()`（不为统一而改名 —— 改名只会扩大改动面，语义也无问题）。
 *  ⇒ 断言必须按**页**给构造器名，不能写死 `navTitleBar`。 */
const NAV_TITLE_PAGES = [
  ['ArchivedSessionsScreen', 'navTitleBar'], ['DevicesScreen', 'navTitleBar'],
  ['FilesScreen', 'navTitleBar'], ['TerminalScreen', 'navTitleBar'],
  ['SettingsScreen', 'navTitleBar'], ['NewChatWorkspaceScreen', 'navTitleBar'],
  ['NewSessionScreen', 'navTitleBar'], ['SessionDetailScreen', 'navTitleBar'],
  ['AddDeviceScreen', 'topBar'], ['DeviceDetailScreen', 'topBar'],
];
/** **R86 迁移完成**：不再有「顶栏仍是自绘」的页面（原 `AddDeviceScreen` / `DeviceDetailScreen` 已迁入
 *  框架标题栏）⇒ 这个名单为空是**本轮的目标状态**，不是漏写。若将来某页要退回自绘顶栏，
 *  必须同时把它的「自我避让状态栏」写法加回 ② 组判据，别只改名单。 */
const SELF_DRAWN_PAGES = [];
/** R86 迁入框架标题栏的两页：自绘顶栏那套「自己避让状态栏」的写法**必须消失**（否则重复避让 137px）。 */
const MIGRATED_R86 = ['AddDeviceScreen', 'DeviceDetailScreen'];

const ROW_OK = '.height(Control.NAV_TITLE_ROW)';
const ROW_BAD = '.height(Control.TOP_BAR_PAGE)';
const ROW_SELF_DRAWN = '.height(Control.TOP_BAR_PAGE + this.topInset())';

let pass = 0;
const fails = [];
function ok(cond, msg) { if (cond) { pass++; } else { fails.push(msg); } }

/** 剥注释：块注释 + `//` 行注释（行注释按"整行剩余部分"剥，与本工作区既有套件同款做法）。 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split(String.fromCharCode(10))
    .map((l) => l.replace(/\/\/.*$/, ''))
    .join(String.fromCharCode(10));
}

function readCode(name) {
  return stripComments(fs.readFileSync(path.join(SCREEN_DIR, name + '.ets'), 'utf8'));
}

/** 取某个 `@Builder` 构造器的正文（从 `name() {` 到文件里下一个「两空格缩进的 }」为止）。 */
function builderBody(code, name) {
  const i = code.indexOf(name + '() {');
  if (i < 0) { return ''; }
  const rest = code.slice(i);
  const end = rest.search(/\n  \}\n/);
  return end > 0 ? rest.slice(0, end + 4) : rest;
}

// ---------------------------------------------------------------------------
// ① 10 个「顶栏已进框架标题栏」的页面（R86 起含迁入的两页）
// ---------------------------------------------------------------------------
for (const [name, builder] of NAV_TITLE_PAGES) {
  const file = path.join(SCREEN_DIR, name + '.ets');
  const exists = fs.existsSync(file);
  ok(exists, name + '.ets 不存在（页面被改名/删除？本套件要同步更新名单）');
  if (!exists) { continue; }
  const code = readCode(name);
  const bar = builderBody(code, builder);
  ok(bar.length > 0, name + '：找不到 `' + builder + '()` 构造器');
  ok(bar.indexOf(ROW_OK) >= 0,
    name + '：`' + builder + '()` 里没有 `' + ROW_OK + '`（标题行行高没有走共享令牌）');
  ok(code.indexOf(ROW_BAD) < 0,
    name + '：整页仍出现 `' + ROW_BAD + '`（顶栏已进框架标题栏，行高必须用 NAV_TITLE_ROW）');
}

// ---------------------------------------------------------------------------
// ② R86 迁移完成：两页**不得**再保留自绘顶栏的「自己避让状态栏」
// ---------------------------------------------------------------------------
for (const name of MIGRATED_R86) {
  const file = path.join(SCREEN_DIR, name + '.ets');
  const exists = fs.existsSync(file);
  ok(exists, name + '.ets 不存在（页面被改名/删除？本套件要同步更新名单）');
  if (!exists) { continue; }
  const code = readCode(name);
  ok(code.indexOf(ROW_SELF_DRAWN) < 0,
    name + '：顶栏已迁入框架标题栏，仍出现 `' + ROW_SELF_DRAWN + '` ⇒ **重复避让**一整条状态栏'
    + '（框架标题栏自己让位：可用高 = 112 − 状态栏）');
}
// ②-余：`SELF_DRAWN_PAGES` 为空是本轮目标状态；若将来有人把它加回来，这条会提醒他同步 ② 的判据。
ok(SELF_DRAWN_PAGES.length === 0,
  'R86 起不应再有「顶栏仍是自绘」的页面（原 AddDevice/DeviceDetail 已迁入）；'
  + '若确实要退回自绘顶栏，请同时把「自我避让状态栏」写回 ② 组判据，别只改名单');

// ---------------------------------------------------------------------------
// ③ TerminalScreen 的 MENU_TOP（FilesScreen 也 import 它）：派生量必须跟着行高走
// ---------------------------------------------------------------------------
const terminal = readCode('TerminalScreen');
const decl = terminal.indexOf('export const MENU_TOP');
ok(decl >= 0, 'TerminalScreen：找不到 `export const MENU_TOP`（下拉锚点常量被删/改名？）');
if (decl >= 0) {
  const semi = terminal.indexOf(';', decl);
  const stmt = semi > 0 ? terminal.slice(decl, semi + 1) : terminal.slice(decl);
  ok(stmt.indexOf('Control.NAV_TITLE_ROW') >= 0,
    'TerminalScreen：MENU_TOP 必须基于 `Control.NAV_TITLE_ROW` 推导（行高变了它就得跟着变）');
  ok(stmt.indexOf('Control.TOP_BAR_PAGE') < 0,
    'TerminalScreen：MENU_TOP 不得再引用 `Control.TOP_BAR_PAGE`（旧行高 64 ⇒ 菜单偏 9vp 起）');
}
const files = readCode('FilesScreen');
ok(files.indexOf('MENU_TOP') >= 0,
  'FilesScreen：设备下拉与终端页共用同一套锚点常量，应仍然 import MENU_TOP（收口只留一处）');

// ---------------------------------------------------------------------------
// ④ R82 死代码回潮闸门：删掉的两块**不许再长回来**
// ---------------------------------------------------------------------------
// 背景：R81 真机复验发现 `NewSessionScreen` 的「标题编辑态」（点铅笔 → 居中 `TextInput` +
// 142×1.5 下划线）在真机上**进不去** —— 它只在 `!projectOnly` 时渲染，而能进那种模式的唯一路由
// `Route.NEW_SESSION` **全工程已无 push 点**（只剩常量定义 + `Index` 的挂载分支）
// ⇒ 两块都是死代码，R82 一起删除。这里钉住「不许回潮」（来历见
// 开发期验证记录）。
//
// ⚠️ 本文件顶部已有 `stripComments` —— 上面这段说明本身就写在注释里，不剥注释会变成自我断言。
const ROUTER_ETS = path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'ets', 'ui', 'Router.ets');
const routerCode = stripComments(fs.readFileSync(ROUTER_ETS, 'utf8'));
ok(routerCode.indexOf('new_session') < 0,
  'ui/Router.ets 又出现了 `new_session`：`Route.NEW_SESSION` 是无入口的死路由（R82 删除），不许加回来');
const nsCode = readCode('NewSessionScreen');
ok(nsCode.indexOf('editingTitle') < 0,
  'NewSessionScreen 又出现了 `editingTitle`：标题编辑态是死代码（R82 删除），要恢复必须先有入口');
ok(nsCode.indexOf("'pencil'") < 0 && nsCode.indexOf('"pencil"') < 0,
  'NewSessionScreen 又出现了 `pencil`：那是标题编辑钮的图标（R82 删除）');
ok(builderBody(nsCode, 'navTitleBar').indexOf('TextInput') < 0,
  'NewSessionScreen.navTitleBar() 又出现了 `TextInput`：那是标题编辑态的输入框（R82 删除）');
/**
 * ⚠️ **为什么不同时禁掉 `'check'`**：它在同一文件里还有正当用法（项目行的 `name: 'check'` 与
 * 完成标记的 `ICONS['check']`，共 4 处）—— 一把禁掉会误伤。死编辑态的那一对是
 * `'check'` / `'pencil'` **在 `navTitleBar()` 里成对出现**，所以判据落在
 * 「顶栏内不得有 `pencil` / `TextInput`」+「全文件不得有 `editingTitle`」，既精确又不会误伤。
 */
ok(nsCode.indexOf("'check'") >= 0 || nsCode.indexOf("ICONS['check']") >= 0,
  '自检：NewSessionScreen 里 `check` 仍被别处正当使用（本闸门刻意不禁它，禁的是顶栏那一对）');

// ---------------------------------------------------------------------------
// ⑤ 本套件的**鉴别力自检**（在内存副本上做变异，不碰任何文件）
// ---------------------------------------------------------------------------
// 目的：防止「名单写错 / 正则写松 / 注释剥离失效」让本套件变成恒真。
const probe = readCode('DevicesScreen');
ok(probe.indexOf(ROW_OK) >= 0 && probe.indexOf(ROW_BAD) < 0,
  '自检前提：DevicesScreen 当前处于合规态（否则下面的变异证伪没有意义）');
const mutated = probe.replace(ROW_OK, ROW_BAD);
ok(mutated.indexOf(ROW_OK) < 0 && mutated.indexOf(ROW_BAD) >= 0,
  '变异证伪：一行改回 ' + ROW_BAD + ' 后，①的两条判据都会翻（本套件不是恒真）');
/**
 * ⚠️ 注释剥离的**反向**自检：同一行只写在注释里时**不许**被当成真代码 ——
 * 这正是本工作区踩过的坑（注释里的示例写法被扫描成实现）。
 */
const commentOnly = '// ' + ROW_OK + String.fromCharCode(10) + 'const x = 1;';
ok(stripComments(commentOnly).indexOf(ROW_OK) < 0,
  '注释剥离自检：只写在注释里的 ' + ROW_OK + ' 必须被剥掉');

if (fails.length > 0) {
  console.error('suite-topbar: ' + fails.length + ' 条断言失败');
  for (const f of fails) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-topbar: ' + pass + ' 条断言全绿。');
