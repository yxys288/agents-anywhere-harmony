#!/usr/bin/env node
/**
 * aa-hm 顶层「终端」页 root 契约自测（第十一轮 · P0）。
 *
 * 被测代码：`ui/screens/TerminalScreen.ets` 末尾「设备选择（纯逻辑）」区里的
 * `effectiveTerminalRoot()`（该区被 `run-tests.mjs` / `suite-device.mjs` 一起切出来转译，
 * 本 suite 用同一套切法，断言不依赖 ArkUI / 设备）。
 *
 * 为什么这两条断言值得单列一个 suite：
 *   真机现象 —— 首页点「终端」卡片 → 顶栏显示「终端 · 56x43 · 出错」。
 *   根因 —— 首页快捷卡片 `Router.push(target)` **不带路由参数**，
 *   `Index.ets` 的 `paramAt(1)` 于是返回空串；而 `@Prop root` 一旦被传参就不启用默认值，
 *   空串被 `TerminalApi` 拼成 `?root=` → 服务端 `root: str = Query(..., min_length=1)` 直接 422。
 *   上游设备级终端的 root 是**硬编码**的 `"~"`（`feature/terminal/TerminalController.kt:72`
 *   的 `openDeviceTerminal` → `root = "~"`；会话级才用 `session.cwd`，同文件第 23 行）。
 *   修复 = 默认值改 `HOME_ROOT` + 入口再走一次 `effectiveTerminalRoot()` 归一。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-terminal.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-terminal');
const TERMINAL_SCREEN = path.join(SRC_ETS, 'ui', 'screens', 'TerminalScreen.ets');
/** R20：终端配色随主题切换的落点（`applyAppearance`）。 */
const TERMINAL_STORE = path.join(SRC_ETS, 'feature', 'TerminalStore.ets');

/**
 * HOME_ROOT 住在 DirBrowse 里，DirBrowse 又依赖 RemotePaths / Types —— 三个一起转译。
 * `vt/TerminalStyle.ets` 零 import，可独立转译：它的 `defaultColorScheme(dark)` 就是终端底色/前景/光标。
 */
const LOGIC_FILES = ['model/Types.ets', 'model/AppModels.ets', 'model/RemotePaths.ets', 'model/DirBrowse.ets', 'vt/TerminalStyle.ets'];

/** TerminalScreen.ets 的「设备选择（纯逻辑）」区：按标记切片（切片内不允许有 import）。 */
const PURE_BEGIN = '// >>> AA-DEVICE-PURE-BEGIN';
const PURE_END = '// <<< AA-DEVICE-PURE-END';

const NL = String.fromCharCode(10);

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
      fileName: rel
    });
    const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, output.outputText, 'utf8');
  }
  const source = fs.readFileSync(TERMINAL_SCREEN, 'utf8');
  const begin = source.indexOf(PURE_BEGIN);
  const end = source.indexOf(PURE_END);
  if (begin < 0 || end <= begin) {
    throw new Error('TerminalScreen.ets 里找不到纯逻辑标记（' + PURE_BEGIN + ' / ' + PURE_END + '）：标记被删或改名了？');
  }
  const slice = source.slice(begin + PURE_BEGIN.length, end);
  if (slice.indexOf('import ') >= 0) {
    throw new Error('TerminalScreen.ets 的纯逻辑区出现了 import —— 该区必须零依赖');
  }
  const target = path.join(OUT_DIR, 'ui', 'screens', 'TerminalDevice.js');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, ts.transpileModule(slice, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
    fileName: 'TerminalDevice.ets'
  }).outputText, 'utf8');
}

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
  } else {
    failures.push(detail === undefined ? name : name + ' — ' + detail);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

function group(title) {
  console.log(NL + '== ' + title);
}

build();

const require = createRequire(import.meta.url);
const load = (rel) => require(path.join(OUT_DIR, rel));
const device = load('ui/screens/TerminalDevice.js');
const dir = load('model/DirBrowse.js');

// ---------------------------------------------------------------------------
// 1. 常量：设备级终端的 root 就是上游硬编码的 ~
// ---------------------------------------------------------------------------

group('设备级终端 root 常量（锚 TerminalController.kt:72 root = "~"）');
eq('HOME_ROOT 就是上游的 ~', dir.HOME_ROOT, '~');
eq('TerminalScreen 与文件页共用同一个常量值', dir.HOME_ROOT, '~');

// ---------------------------------------------------------------------------
// 2. effectiveTerminalRoot：空串 / 纯空白 / '.' → '~'，其余原样（去首尾空白）
// ---------------------------------------------------------------------------

group('root 归一（effectiveTerminalRoot）');
eq('空串（首页「终端」卡片不带参数）→ ~', device.effectiveTerminalRoot('', dir.HOME_ROOT), '~');
eq('纯空白 → ~', device.effectiveTerminalRoot('   ', dir.HOME_ROOT), '~');
eq('设备详情取不到工作区时的 . → ~', device.effectiveTerminalRoot('.', dir.HOME_ROOT), '~');
eq('显式 ~ 原样保留', device.effectiveTerminalRoot('~', dir.HOME_ROOT), '~');
eq('POSIX 绝对路径去首尾空白后保留',
  device.effectiveTerminalRoot('  /Users/me/code/demo  ', dir.HOME_ROOT), '/Users/me/code/demo');
eq('Windows 盘符路径原样保留', device.effectiveTerminalRoot('C:/Users/me', dir.HOME_ROOT), 'C:/Users/me');
eq('带盘符的反斜杠路径原样保留',
  device.effectiveTerminalRoot('C:' + String.fromCharCode(92) + 'Users' + String.fromCharCode(92) + 'me', dir.HOME_ROOT),
  'C:' + String.fromCharCode(92) + 'Users' + String.fromCharCode(92) + 'me');
// 关键回归：归一之后**不可能**再拼出 `?root=`（服务端 min_length=1 会直接 422）
eq('归一结果永不为空串', device.effectiveTerminalRoot('', dir.HOME_ROOT).length > 0, true);
eq('归一结果永不为单个点', device.effectiveTerminalRoot('.', dir.HOME_ROOT) === '.', false);

// ---------------------------------------------------------------------------
// 3. 源码守卫：接线真的是这两处（纯函数对但没接上等于没修）
// ---------------------------------------------------------------------------

const screenText = fs.readFileSync(TERMINAL_SCREEN, 'utf8');
const screenLines = screenText.split(/\r?\n/);

group('TerminalScreen.ets 源码守卫');
check('@Prop root 的默认值不再是 .' , screenText.includes("@Prop root: string = '.';") === false);
check('@Prop root 的默认值是 HOME_ROOT', screenText.includes('@Prop root: string = HOME_ROOT;'));
check('连终端前走 effectiveTerminalRoot 归一',
  screenText.includes('effectiveTerminalRoot(this.root, HOME_ROOT)'));
check('HOME_ROOT 从 model/DirBrowse 引入（与文件页同一份）',
  screenText.includes("import { HOME_ROOT } from '../../model/DirBrowse';"));
check('没有把 ~ 写成第二个字面量默认值', screenText.includes("@Prop root: string = '~';") === false);

group('错误态原文（锚 TerminalContent 的 terminalState.message）');
check('页面把 store.error 拷进 @State', screenText.includes('this.errorText = this.store.error;'));
check('页面渲染 AaErrorBanner', screenText.includes('AaErrorBanner({'));
check('错误条挂在 build 的页面主体里', screenText.includes('this.errorBanner()'));
check('没有用自造文案替换服务端原文', screenText.includes('message: this.errorText'));

group('红线：零新增 Kit 依赖 / 不用 any');
check('TerminalScreen.ets 未引入 @kit.BasicServicesKit（本轮不做终端复制）',
  screenText.includes('@kit.BasicServicesKit') === false);
check('TerminalScreen.ets 未引入 pasteboard', screenText.includes('pasteboard') === false);
check('TerminalScreen.ets 不用 any',
  /(^|[^A-Za-z0-9_$])any([^A-Za-z0-9_$]|$)/.test(
    screenLines.filter((line) => !/^\s*(\*|\/\/)/.test(line)).join(NL)) === false);
check('纯逻辑区仍然零 import（切片时已校验，这里只留痕）', true);

// ---------------------------------------------------------------------------
// 4. 终端配色必须**随主题**（R20：浅色主题下终端曾经永远是黑底）
// ---------------------------------------------------------------------------
// 上游 `applyTerminalColors(controller, darkMode)`（锚 `SessionAgentFilesScreen.kt:745-750`）：
//   深色 bg/fg/cursor = 0xFF09090B / 0xFFFAFAFA / 0xFFFAFAFA
//   浅色 bg/fg/cursor = 0xFFFEFDFB / 0xFF20211E / 0xFF20211E
// 本工程修前把 `dark = true` 硬编码在 `TerminalStore` 的构造里且再无第二次赋值 ⇒ 浅色主题下黑底。

const style = load('vt/TerminalStyle.js');
const light = style.defaultColorScheme(false);
const dark = style.defaultColorScheme(true);
const rgb = (r, g, b) => style.rgbColor(r, g, b);

group('VT 配色表（锚 applyTerminalColors）');
eq('浅色背景 = 上游 0xFFFEFDFB', light.background, rgb(0xfe, 0xfd, 0xfb));
eq('浅色前景 = 上游 0xFF20211E', light.foreground, rgb(0x20, 0x21, 0x1e));
eq('浅色光标 = 上游 0xFF20211E', light.cursor, rgb(0x20, 0x21, 0x1e));
eq('深色背景 = 上游 0xFF09090B', dark.background, rgb(0x09, 0x09, 0x0b));
eq('深色前景 = 上游 0xFFFAFAFA', dark.foreground, rgb(0xfa, 0xfa, 0xfa));
eq('深色光标 = 上游 0xFFFAFAFA', dark.cursor, rgb(0xfa, 0xfa, 0xfa));
check('深浅两套底色必须不同（相等就等于某一侧没接主题）', light.background !== dark.background);
check('深浅两套前景必须不同', light.foreground !== dark.foreground);
eq('ANSI 16 色齐备', light.ansi.length, 16);
eq('深色 ANSI 也是 16 色', dark.ansi.length, 16);
check('默认色解析到该侧的主题色（前景走 foreground、背景走 background）',
  style.resolveColor(style.COLOR_DEFAULT, light, true) === light.foreground
  && style.resolveColor(style.COLOR_DEFAULT, light, false) === light.background
  && style.resolveColor(style.COLOR_DEFAULT, dark, true) === dark.foreground
  && style.resolveColor(style.COLOR_DEFAULT, dark, false) === dark.background);

group('接线守卫：换主题真的会重设 VT 配色（纯函数对但没接上等于没修）');
const storeText = fs.readFileSync(TERMINAL_STORE, 'utf8');
check('TerminalStore 有 applyAppearance(dark)',
  storeText.includes('applyAppearance(dark: boolean): void'));
check('applyAppearance 换的是 emulator 的色表（不重建，回看区不能丢）',
  storeText.includes('this.emulator.colorScheme = defaultColorScheme(dark);'));
check('TerminalStore 引入了 defaultColorScheme',
  storeText.includes("import { defaultColorScheme } from '../vt/TerminalStyle';"));
check('页面在首次绘制前就按当前外观定色',
  screenText.includes('this.store.applyAppearance(isDarkAppearance());'));
check('页面注册了外观监听并在销毁时摘掉（静态数组只增不减就是泄漏）',
  screenText.includes('AppearanceController.onChange(this.appearanceListener)')
  && screenText.includes('AppearanceController.offChange(this.appearanceListener)'));
check('外观监听里重设配色 + 重绘',
  screenText.includes('this.store.applyAppearance(isDarkAppearance());')
  && screenText.includes('this.draw();'));

// ---------------------------------------------------------------------------
// 5. 「清空终端」悬浮钮（R24：顶栏文字胶囊 → 上游的圆形悬浮钮，且语义改成 restart）
// ---------------------------------------------------------------------------
// 上游锚文：`SessionAgentFilesScreen.kt:608-618` 的调用点
//   `TerminalClearButton(enabled = terminalKey != null, onClick = { onClear() })`
//   `Modifier.align(TopEnd).padding(top = 10.dp, end = 18.dp).zIndex(1f)`
// + 713-745 的实现（`.size(34.dp)` 圆、1dp 描边、17dp `Lucide.Trash2`、四组颜色）。
// `onClear` → `TerminalScreen.kt:108` → `RemoteTerminalController.kt:272` 的 `restart(device)`
//   = `close()`（断流 + 删远端终端 + 清本地屏）+ `ensureStarted(device)`（重建）。

group('清空终端（R24）');
check("文案落在无障碍上（画面上只有图标）", screenText.includes(".accessibilityText('清空终端')"));
check("图标 = Lucide Trash2 的路径", screenText.includes("d: ICONS['trash-2'],"));
check('几何逐字取上游：34dp / 顶 10dp / 右 18dp',
  screenText.includes('export const CLEAR_BUTTON_SIZE: number = 34;')
  && screenText.includes('export const CLEAR_BUTTON_TOP: number = 10;')
  && screenText.includes('export const CLEAR_BUTTON_END: number = 18;'));
check('对齐写在 Stack 的 alignContent 上（子节点 .align() 在本 SDK 不生效 —— R24 模拟器实测按钮落到屏幕正中 [567,1381][686,1500]）',
  screenText.includes('Stack({ alignContent: Alignment.TopEnd })')
  // 只在**非注释行**里找：注释里正解释这段实测，别把说明文字当代码
  && screenLines.filter((line) => !/^\s*(\*|\/\/)/.test(line)).join(NL).includes('.align(Alignment.TopEnd)') === false);
check('点击走 store.restart()（上游 = close + ensureStarted，不是只清本地缓冲）',
  screenText.includes('this.store.restart();'));
check('顶栏不再有「清屏」文字胶囊', screenText.includes("label: '清屏'") === false);
check('按钮挂在终端主体里（不是顶栏）',
  screenText.lastIndexOf('this.store.restart();') > screenText.indexOf('terminalBody()'));
check('「有没有终端」存进 @State（直接读 store 不登记渲染依赖）',
  screenText.includes('this.hasTerminal = this.store.terminal !== undefined;'));
check('TerminalStore 提供 restart()，且 clearLocal() 已删除',
  storeText.includes('async restart(): Promise<void>') && storeText.includes('clearLocal(): void') === false);
check('restart 先 close 再重建（顺序反了会把刚建的终端删掉）',
  /this\.close\(\);[\s\S]{0,400}await this\.open\(/.test(storeText));
check('restart 复用当前网格与 cwd（重建成 80x24 会让画面跳回默认列宽）',
  storeText.includes('await this.open(deviceId, root, cols, rows, cwd);'));

group('清空钮的四组颜色 = 上游 TerminalClearButton 的字面值');
const colorTokens = (rel) => JSON.parse(fs.readFileSync(
  path.join(PROJECT, 'entry', 'src', 'main', 'resources', rel, 'element', 'color.json'), 'utf8')).color;
const tokenValue = (list, name) => {
  const hit = list.filter((c) => c.name === name)[0];
  return hit === undefined ? 'MISSING' : hit.value;
};
const baseColorList = colorTokens('base');
const darkColorList = colorTokens('dark');
eq('浅色底 = 上游 0xEEFFFFFF', tokenValue(baseColorList, 'terminal_clear_surface'), '#EEFFFFFF');
eq('浅色描边 = 上游 0xFFE7E5E0', tokenValue(baseColorList, 'terminal_clear_border'), '#E7E5E0');
eq('浅色图标 = 上游 0xFFB42318', tokenValue(baseColorList, 'terminal_clear_icon'), '#B42318');
eq('浅色禁用图标 = 上游 0xFFA7A5A0', tokenValue(baseColorList, 'terminal_clear_icon_off'), '#A7A5A0');
eq('深色底 = 上游 0xDD18181B', tokenValue(darkColorList, 'terminal_clear_surface'), '#DD18181B');
eq('深色描边 = 上游 0xFF3F3F46', tokenValue(darkColorList, 'terminal_clear_border'), '#3F3F46');
eq('深色图标 = 上游 0xFFFCA5A5', tokenValue(darkColorList, 'terminal_clear_icon'), '#FCA5A5');
eq('深色禁用图标 = 上游 0xFF71717A', tokenValue(darkColorList, 'terminal_clear_icon_off'), '#71717A');
check('四组都随主题不同（相等就等于有一侧没接主题）',
  tokenValue(baseColorList, 'terminal_clear_surface') !== tokenValue(darkColorList, 'terminal_clear_surface')
  && tokenValue(baseColorList, 'terminal_clear_icon') !== tokenValue(darkColorList, 'terminal_clear_icon')
  && tokenValue(baseColorList, 'terminal_clear_border') !== tokenValue(darkColorList, 'terminal_clear_border'));

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-terminal: ' + passed + ' 条断言全绿。');
  process.exit(0);
} else {
  console.log('suite-terminal: ' + failures.length + ' 条断言失败（通过 ' + passed + '）：');
  for (const f of failures) {
    console.log('  FAIL ' + f);
  }
  process.exit(1);
}
