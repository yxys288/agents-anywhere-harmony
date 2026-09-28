#!/usr/bin/env node
/**
 * aa-hm 设置页「偏好与展示逻辑」的纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 覆盖 R9 task-9（设置页对齐安卓端）里可离线判定的部分：
 *  语言 / 侧边栏显示的归一化与文案 → 账号行（显示名、头像首字母、服务标签、角色）→ 版本行
 *  → 检查更新行的状态文案 → `AppPreferences` 门面与 **AppStorage 联动契约**（首页据此分组）
 *  → 模块顶层安装持久化。
 *
 * 两个全局对象（`AppStorage` / `PersistentStorage`）在测试里用假实现替换：
 * 被测模块刻意零 @kit 依赖（见 `store/AppPreferences.ets` 头部注释），所以这条链路能整条断言。
 *
 * 转译方式照抄 tools/logic-test/run-tests.mjs（DevEco 自带 TypeScript → CommonJS → Node 断言）。
 * 产物落在系统临时目录（不污染工程目录）。
 *
 * 用法：
 *   node tools\\logic-test\\suite-settings.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-settings');

/**
 * 只挑不 import @kit / ArkUI、也不含 `struct` 的模块。
 * 注意 `ui/screens/SettingsScreen.ets` **不能**进来：`struct` 不是 TypeScript 语法，
 * 对它的检查只能是「静态契约 / 锚点存在性」（见下面的源码契约组）。
 */
const LOGIC_FILES = ['store/AppPreferences.ets', 'ui/BackHandler.ets'];

const require = createRequire(import.meta.url);
const ts = requireTypeScript();

/** 转译全部逻辑模块；返回 [{rel, message}] 形式的语法问题清单（空数组 = 全部通过）。 */
function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const problems = [];
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
      fileName: rel,
      reportDiagnostics: true
    });
    const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, output.outputText, 'utf8');
    for (const item of (output.diagnostics || [])) {
      problems.push({ rel: rel, message: '[' + item.code + '] ' + ts.flattenDiagnosticMessageText(item.messageText, ' ') });
    }
  }
  return problems;
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
  console.log('');
  console.log('== ' + title);
}

// ---------------------------------------------------------------------------
// 0. 源码契约
// ---------------------------------------------------------------------------

group('源码契约（逻辑模块可转译 / 零 @kit 依赖 / 设置页行锚点）');
const problems = build();
for (const rel of LOGIC_FILES) {
  const own = problems.filter((item) => item.rel === rel);
  check(rel + ' 可被 TypeScript 转译（无语法错误）',
    own.length === 0,
    own.map((item) => item.message).join(' | '));
}
const emitted = fs.readFileSync(path.join(OUT_DIR, 'store/AppPreferences.js'), 'utf8');
check('转译产物不含 require(@kit.*)（偏好模块零 @kit 依赖）',
  !/require\(['"]@kit[./]/.test(emitted), '源码里出现了对 @kit 的运行时 import');

const settingsSource = fs.readFileSync(path.join(SRC_ETS, 'ui/screens/SettingsScreen.ets'), 'utf8');
/** 设置页必须逐行覆盖的锚点（对应用户截图上的 7 行 + 两个子页标题）。 */
const SETTINGS_ANCHORS = [
  '外观', '语言', '侧边栏显示', '版本', '检查更新', '已归档会话', '退出登录',
  '跟随系统', '浅色', '深色', '项目视图', '会话视图', '账号', 'English', '简体中文'
];
for (const anchor of SETTINGS_ANCHORS) {
  check('设置页含行锚点「' + anchor + '」', settingsSource.indexOf("'" + anchor + "'") >= 0);
}
check('设置页优先读偏好模块（而不是自己写死键名）',
  settingsSource.indexOf('AppPreferences.get()') >= 0 && settingsSource.indexOf('preferences.install()') >= 0);

// ---------------------------------------------------------------------------
// 假的全局对象（必须在 require 被测模块之前装好）
// ---------------------------------------------------------------------------

const appStorage = new Map();
globalThis.AppStorage = {
  setOrCreate: (key, value) => {
    appStorage.set(key, value);
    return true;
  },
  get: (key) => appStorage.get(key),
  has: (key) => appStorage.has(key)
};
const persisted = [];
globalThis.PersistentStorage = {
  persistProp: (key, defaultValue) => {
    persisted.push(key);
    // 真实语义：AppStorage 里没有这个键时用默认值播种（磁盘有值时由平台覆盖）
    if (!appStorage.has(key)) {
      appStorage.set(key, defaultValue);
    }
  }
};

const prefs = require(path.join(OUT_DIR, 'store/AppPreferences.js'));

// ---------------------------------------------------------------------------
// 1. 语言
// ---------------------------------------------------------------------------

group('语言（对应 Android AALanguageMode）');
eq('zh-CN 原样保留', prefs.normalizeLanguage('zh-CN'), prefs.LANGUAGE_CHINESE);
eq('en 原样保留', prefs.normalizeLanguage('en'), prefs.LANGUAGE_ENGLISH);
eq('system 原样保留', prefs.normalizeLanguage('system'), prefs.LANGUAGE_SYSTEM);
eq('空串回落 system', prefs.normalizeLanguage(''), prefs.LANGUAGE_SYSTEM);
eq('未知值回落 system', prefs.normalizeLanguage('fr-FR'), prefs.LANGUAGE_SYSTEM);
eq('中文标签', prefs.languageLabel(prefs.LANGUAGE_CHINESE), '简体中文');
eq('英文标签', prefs.languageLabel(prefs.LANGUAGE_ENGLISH), 'English');
eq('跟随系统标签', prefs.languageLabel(prefs.LANGUAGE_SYSTEM), '跟随系统');
eq('脏值标签也回落跟随系统', prefs.languageLabel('nope'), '跟随系统');

// ---------------------------------------------------------------------------
// 2. 侧边栏显示
// ---------------------------------------------------------------------------

group('侧边栏显示（对应 Android HomeSidebarViewMode）');
eq('session 原样保留', prefs.normalizeSidebarView('session'), prefs.SIDEBAR_VIEW_SESSION);
eq('project 原样保留', prefs.normalizeSidebarView('project'), prefs.SIDEBAR_VIEW_PROJECT);
eq('空串回落 project', prefs.normalizeSidebarView(''), prefs.SIDEBAR_VIEW_PROJECT);
eq('未知值回落 project', prefs.normalizeSidebarView('list'), prefs.SIDEBAR_VIEW_PROJECT);
eq('会话视图标签', prefs.sidebarViewLabel(prefs.SIDEBAR_VIEW_SESSION), '会话视图');
eq('项目视图标签', prefs.sidebarViewLabel(prefs.SIDEBAR_VIEW_PROJECT), '项目视图');
eq('脏值标签也回落项目视图', prefs.sidebarViewLabel('zzz'), '项目视图');

// ---------------------------------------------------------------------------
// 3. 账号行 / 版本行
// ---------------------------------------------------------------------------

group('账号行与版本行（对应 ProfileAvatar / accountLabel / prettyRole）');
eq('昵称优先', prefs.accountLabel('张三', 'z@example.com'), '张三');
eq('昵称两侧空白被裁掉', prefs.accountLabel('  张三  ', 'z@example.com'), '张三');
eq('昵称空白时回退邮箱', prefs.accountLabel('   ', 'z@example.com'), 'z@example.com');
eq('都没有时回退「账号」', prefs.accountLabel('', ''), '账号');
eq('头像取首字符', prefs.avatarLetter('张三'), '张');
eq('头像首字母大写', prefs.avatarLetter(' alice '), 'A');
eq('空显示名的头像兜底 A', prefs.avatarLetter(''), 'A');
check('官方域判为官方服务', prefs.isOfficialServer('https://web.agents-anywhere.com') === true);
check('尾部斜杠不影响判定', prefs.isOfficialServer('https://web.agents-anywhere.com/') === true);
check('大小写不影响判定', prefs.isOfficialServer('HTTPS://WEB.AGENTS-ANYWHERE.COM') === true);
check('自建域不是官方服务', prefs.isOfficialServer('https://my.example.com') === false);
eq('官方服务标签', prefs.serviceLabel('https://web.agents-anywhere.com'), '官方服务');
eq('自建服务标签', prefs.serviceLabel('https://my.example.com'), 'Self-host 服务');
eq('admin 角色中文', prefs.roleLabel('admin'), '管理员');
eq('member 角色中文', prefs.roleLabel('member'), '成员');
eq('角色大小写不敏感', prefs.roleLabel('Admin'), '管理员');
eq('其它角色首字母大写', prefs.roleLabel('owner'), 'Owner');
eq('空角色回退成员', prefs.roleLabel(''), '成员');
eq('版本号补 v 前缀', prefs.versionLabel('2.0.0'), 'v2.0.0');
eq('已带 v 前缀不重复', prefs.versionLabel('v1.2.3'), 'v1.2.3');
eq('空版本号给占位', prefs.versionLabel('    '), '—');

// ---------------------------------------------------------------------------
// 4. 检查更新行的状态
// ---------------------------------------------------------------------------

group('检查更新行（对应 AppUpdateUiState 的简化投影）');
eq('未检查时无文案（页面显示 ›）', prefs.updateStatusLabel(prefs.UPDATE_IDLE, ''), '');
eq('检查中文案', prefs.updateStatusLabel(prefs.UPDATE_CHECKING, ''), '检查中…');
eq('已是最新文案', prefs.updateStatusLabel(prefs.UPDATE_LATEST, ''), '已是最新');
eq('有新版本时带服务端版本', prefs.updateStatusLabel(prefs.UPDATE_AVAILABLE, '服务端 2.1.0'), '服务端 2.1.0');
eq('有新版本但没有细节时的兜底文案', prefs.updateStatusLabel(prefs.UPDATE_AVAILABLE, ''), '有新版本');
eq('失败时兜底文案', prefs.updateStatusLabel(prefs.UPDATE_FAILED, ''), '检查失败');
eq('有新版用警告色', prefs.updateStatusTone(prefs.UPDATE_AVAILABLE), 'warning');
eq('失败用错误色', prefs.updateStatusTone(prefs.UPDATE_FAILED), 'error');
eq('已最新用成功色', prefs.updateStatusTone(prefs.UPDATE_LATEST), 'success');
eq('未检查无强调色', prefs.updateStatusTone(prefs.UPDATE_IDLE), '');

// ---------------------------------------------------------------------------
// 5. 偏好门面与 AppStorage 联动契约（首页按 aaSidebarView 分组）
// ---------------------------------------------------------------------------

group('偏好门面与 AppStorage 联动契约');
eq('键名契约：侧边栏显示', prefs.SIDEBAR_VIEW_KEY, 'aaSidebarView');
eq('键名契约：语言', prefs.LANGUAGE_KEY, 'aaLanguage');
// R38：持久化键从 2 个变 3 个（新增 `aaProjectCollapsed`）；R47：变 4 个（新增 `aaNewSessionPref`，
// 新建会话的「上次选择」—— 用户原话「新建能保留默认设置」）。
// ⚠️ 这条断言的**原意是「键必须真的被托管」**，不是「恰好 N 个」—— 所以随实现一起更新，
//    且每新增一个键都在这里一并钉住（漏注册的表现：只写 AppStorage 不持久化，杀进程即丢）。
// R53：变 5 个（新增 `aaLastSessionId`，最后打开过的会话 —— 只服务于新对话的默认工作区）。
eq('模块 import 即安装五个持久化键', persisted.join(','),
  'aaSidebarView,aaLanguage,aaProjectCollapsed,aaNewSessionPref,aaLastSessionId');
check('AppPreferences 是单例', prefs.AppPreferences.get() === prefs.AppPreferences.get());
eq('未设置时侧边栏默认项目视图', prefs.AppPreferences.get().sidebarView, 'project');
eq('未设置时语言默认跟随系统', prefs.AppPreferences.get().language, 'system');
prefs.AppPreferences.get().setSidebarView(prefs.SIDEBAR_VIEW_SESSION);
eq('选会话视图后 AppStorage 立刻更新（首页联动判据）', appStorage.get('aaSidebarView'), 'session');
eq('门面读回的也是会话视图', prefs.AppPreferences.get().sidebarView, 'session');
prefs.AppPreferences.get().setSidebarView('bogus');
eq('脏输入被归一化后再写入', appStorage.get('aaSidebarView'), 'project');
prefs.AppPreferences.get().setLanguage(prefs.LANGUAGE_ENGLISH);
eq('语言写入同一个 AppStorage 键', appStorage.get('aaLanguage'), 'en');
appStorage.set('aaSidebarView', 'unknown');
eq('外部写入脏值时门面读回归一化结果', prefs.AppPreferences.get().sidebarView, 'project');
prefs.AppPreferences.get().install();
prefs.AppPreferences.get().install();
// R47：新增第 4 个托管键 `aaNewSessionPref`（新建会话的「上次选择」）⇒ 期望值 3 → 4。
// R53：新增第 5 个托管键 `aaLastSessionId`（最后打开过的会话，只服务于新对话的默认工作区）⇒ 4 → 5。
// 断言的**语义**没变：调两次 install 只应产生「每个键一次」的 persistProp 记录。
eq('install 幂等（不会重复 persistProp）', persisted.length, 5);

// ---------------------------------------------------------------------------
// 6. 返回键消费链（task-11）
// ---------------------------------------------------------------------------

group('返回键消费链（ui/BackHandler）');
const back = require(path.join(OUT_DIR, 'ui/BackHandler.js'));
eq('未注册消费者时不消费返回键', back.consumeBackPress(), false);
back.registerBackConsumer(() => true);
eq('消费者返回 true 时消费返回键', back.consumeBackPress(), true);
back.registerBackConsumer(() => false);
eq('消费者返回 false 时不消费（交回路由栈）', back.consumeBackPress(), false);
let consumerCalls = 0;
back.registerBackConsumer(() => {
  consumerCalls += 1;
  return true;
});
back.consumeBackPress();
eq('消费链确实把返回键交给了消费者', consumerCalls, 1);
back.registerBackConsumer(undefined);
eq('注销后不再消费（防悬空回调吞返回键）', back.consumeBackPress(), false);

// ---------------------------------------------------------------------------
// 8. 抽屉形态（task-17：设置从独立页面改成抽屉）
// ---------------------------------------------------------------------------

group('抽屉形态（SettingsDrawerPanel / 上游 ProfileSettingsDrawer.kt）');
/** SettingsDrawerPanel 的组件体。 */
const drawerPanelBody = (settingsSource.match(/export struct SettingsDrawerPanel \{([\s\S]*?)\n\}/) || ['', ''])[1];
check('能定位 SettingsDrawerPanel 组件体（后续断言的作用域）', drawerPanelBody.length > 0);
check('导出 SettingsDrawerPanel，对外接口固定为 @Prop open + onClose?',
  /@Component\s*\nexport struct SettingsDrawerPanel \{\s*@Prop open: boolean = false;\s*\n\s*onClose\?: \(\) => void;/.test(settingsSource));
check('关闭态整体卸载（否则铺满的这层会一直挡住首页）', /if \(this\.open\) \{/.test(drawerPanelBody));
check('铺满（上游 Box.fillMaxSize()）',
  /\.width\('100%'\)/.test(drawerPanelBody)
  && /\.height\('100%'\)/.test(drawerPanelBody));
check('抽屉外壳用 profile_page_surface（上游 profilePageBackground：base #F4F3EF / dark #09090B）',
  /\.backgroundColor\(\$r\('app\.color\.profile_page_surface'\)\)/.test(drawerPanelBody));
check('内容层按形态选底色（抽屉 → profile 色，独立页 → canvas）—— 内容层必须不透明，否则会盖掉外壳色',
  /this\.drawer \? \$r\('app\.color\.profile_page_surface'\) : canvas\(\)/.test(settingsSource));
check('从左滑入，位移量 = 自身宽度（上游 slideInHorizontally(initialOffsetX = { -it })）',
  /TransitionEffect\.translate\(\{ x: '-100%' \}\)/.test(drawerPanelBody));
check('带淡入淡出（上游 fadeIn() / fadeOut()）', /TransitionEffect\.OPACITY/.test(drawerPanelBody));
check('无圆角、无阴影 —— 上游就只有 fillMaxSize + 背景色，没有这两样',
  drawerPanelBody.indexOf('borderRadius') < 0 && drawerPanelBody.indexOf('shadow') < 0);
check('没有用 bindSheet 实现（同一页面只允许一个 bindSheet）—— 只看调用形式，注释里的说明不算',
  /\.bindSheet\(/.test(settingsSource) === false);
check('独立页面入口仍保留（SettingsScreen → SettingsContent({ drawer: false })）',
  /@Component\s*\nexport struct SettingsScreen \{\s*build\(\) \{\s*SettingsContent\(\{ drawer: false \}\)\s*\}\s*\}/.test(settingsSource));
check('两个宿主共用同一份内容实现（SettingsContent 只定义一次，两处引用）',
  (settingsSource.match(/struct SettingsContent \{/g) || []).length === 1
  && settingsSource.indexOf('SettingsContent({ drawer: false })') >= 0
  && settingsSource.indexOf('SettingsContent({ drawer: true, onClose: this.onClose })') >= 0);
/** Design.ets 源码：用来核对「令牌值 == 上游值」，避免只换名字、值悄悄变了。 */
const designSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8');
check('三个数值走 Space 令牌，且令牌值仍等于上游（PAGE=18 / S_PLUS=10 / PAGE_BOTTOM=28）',
  /static readonly PAGE: number = 18;/.test(designSource)
  && /static readonly S_PLUS: number = 10;/.test(designSource)
  && /static readonly PAGE_BOTTOM: number = 28;/.test(designSource));
group('沉浸 R13-15：底部避让下放到三处固定底部元素');
const bottomExpr = '.margin({ bottom: this.getUIContext().px2vp(this.safeAreaBottomPx) })';
// R37 起 SessionDetailScreen 的底部避让改成 `composerBottomInset()` = `max(下限, min(安全区, 上限))`
// （用户要求「对话框下移，只避开手势条就行」；⚠️ 不能写成 max(安全区, 目标)），
// 不再是直接 margin。
//
// ⚠️ **R65-D（回退）：本组恢复为「三页各自让位」的正向断言，TerminalScreen 回到本组**。
// 经过：R65-C 曾把自绘悬浮底栏换成官方 `Tabs`（`barPosition: BarPosition.End`，即 
// 的生效范围④），底部安全区避让随之**上移到** `pages/Index.ets` 的 `barBottomMargin`，当时把 TerminalScreen
// 改成反向断言（该页必须**不再**出现这条 margin）。**R65-D 已整条回退**：真机实测官方 Tabs 底栏在
// 本机型这个位置**画不出任何表面**（底栏区 p50 9.2 vs 带外 9.2 = Δ+0.0；而顶栏位置同一次构建有 5.16~8.44），
// 底栏恢复为四页各自挂载的自绘悬浮胶囊 ⇒ **避让重新由页面自己承担**：
// TerminalScreen 的功能键行是它自己的底部固定元素，必须自己让出手势条，否则会压在底栏 / 手势条上。
// （反向断言已删除，不是被绕过：删掉它是因为它描述的形态在 R65-D 之后不再存在。）
// ⚠️ **R79：本判据放宽了一档，但仍是正向断言**（把 `composerBottomInset()` 从 bottom 槽删掉照样会红）。
// 原因：会话页的底部避让 R79 从「输入区外壳的 `padding.bottom`」下移到**底部那条全宽玻璃带自己的
//       `padding.bottom`**，并且**去掉了 `Space.M +`** —— 带上多这 12vp 会把输入卡整体顶高 12vp，
//      破坏用户要求的「对话框和没改前位置一样」（实测只允许 0.7vp 以内）。
//      安全语义（让出手势条）**一个字没变**，变的是这个内边距挂在哪一层、以及要不要额外留白。
const COMPOSER_INSET_EXPR = /bottom:\s*(?:Space\.\w+\s*\+\s*)?this\.composerBottomInset\(\)/;
for (const name of ['SessionDetailScreen', 'TerminalScreen', 'AddDeviceScreen']) {
  const pageSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', name + '.ets'), 'utf8');
  check(name + ' 的底部固定元素让出了底部安全区（手势条）',
    pageSource.indexOf(bottomExpr) >= 0 || COMPOSER_INSET_EXPR.test(pageSource));
  check(name + ' 通过 @StorageLink 读安全区高度（不写死像素）',
    pageSource.indexOf('@StorageLink(SAFE_AREA_BOTTOM_PX) safeAreaBottomPx: number = 0;') >= 0);
}
check('…该判据能被变异证伪（把三页的 margin 全去掉后不再成立）',
  ['SessionDetailScreen', 'TerminalScreen', 'AddDeviceScreen']
    .map((name) => fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', name + '.ets'), 'utf8'))
    .map((src) => src.split(bottomExpr).join(''))
    .every((src) => src.indexOf(bottomExpr) < 0));

check('设置页确实用上了这三个令牌，且没留下局部常量',
  // R13 F-10：这里多了一个 `top: Space.S_PLUS`（上游 `spacedBy(10.dp)` 落在 header 与首卡之间），
  // 三个令牌本身没变，断言跟着写实即可。
  /\.padding\(\{ left: Space\.PAGE, right: Space\.PAGE, top: Space\.S_PLUS \}\)/.test(settingsSource)
  && /Column\(\{ space: Space\.S_PLUS \}\)/.test(settingsSource)
  && /Blank\(\)\.height\(Space\.PAGE_BOTTOM\)/.test(settingsSource)
  && settingsSource.indexOf('CONTENT_H_PADDING') < 0
  && settingsSource.indexOf('CARD_GAP') < 0
  && settingsSource.indexOf('CONTENT_BOTTOM_PADDING') < 0);

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// 7. 设置页接入的静态契约（含 struct，无法转译，只能查源码形状）
// ---------------------------------------------------------------------------

group('设置页接入返回键消费链（静态契约）');
check('从 ../BackHandler 导入 registerBackConsumer 与 unregisterBackConsumer',
  /import \{ registerBackConsumer, unregisterBackConsumer \} from '\.\.\/BackHandler';/.test(settingsSource));
// ⚠️ 必须限定在 aboutToAppear 体里：`unregisterBackConsumer(this.backConsumer)` 里**含有**
// `registerBackConsumer(this.backConsumer)` 这个子串，用全文件搜会把注销当成注册（这条一开始就是这么假通过的）。
const aboutToAppearBody = (settingsSource.match(/aboutToAppear\(\): void \{([\s\S]*?)\n  \}\n/) || ['', ''])[1];
check('能定位 aboutToAppear 方法体（后续断言的作用域）', aboutToAppearBody.length > 0);
check('aboutToAppear 里注册消费者',
  /registerBackConsumer\(this\.backConsumer\)/.test(aboutToAppearBody)
  && aboutToAppearBody.indexOf('unregisterBackConsumer') < 0);
check('aboutToDisappear 里**按身份**注销（unregisterBackConsumer(this.backConsumer)）',
  /aboutToDisappear\(\): void \{[\s\S]*?unregisterBackConsumer\(this\.backConsumer\)/.test(settingsSource));
check('不再用 registerBackConsumer(undefined) 注销（那会误清首页自己的消费者）',
  /registerBackConsumer\(undefined\)/.test(settingsSource) === false);
check('消费者存成字段（可被注销，不是匿名一次性闭包）',
  /private backConsumer: \(\) => boolean = \(\) => this\.consumeBack\(\);/.test(settingsSource));
check('有存活守卫（防僵尸消费者吞返回键）',
  /private alive: boolean = false;/.test(settingsSource)
  && /if \(!this\.alive\) \{\s*return false;\s*\}/.test(settingsSource)
  && /this\.alive = true;\s*\n\s*registerBackConsumer\(this\.backConsumer\);/.test(settingsSource)
  && /this\.alive = false;\s*\n\s*unregisterBackConsumer\(this\.backConsumer\);/.test(settingsSource));
/** consumeBack 的方法体：后面几条断言都限定在它里面，避免跨方法误匹配。 */
const consumeBackBody = (settingsSource.match(/private consumeBack\(\): boolean \{([\s\S]*?)\n  \}\n/) || ['', ''])[1];
check('能定位 consumeBack 方法体（后续断言的作用域）', consumeBackBody.length > 0);
check('存活守卫在方法体里（僵尸消费者不吞键）',
  /if \(!this\.alive\) \{\s*return false;\s*\}/.test(consumeBackBody));
check('非根页：回根页并消费',
  /if \(this\.page !== PAGE_ROOT\) \{\s*this\.page = PAGE_ROOT;\s*return true;\s*\}/.test(consumeBackBody));
check('抽屉形态根页：关抽屉并消费（上游 BackHandler 的 else onClose()）',
  /if \(this\.drawer\) \{[\s\S]*?this\.onClose\(\);[\s\S]*?return true;[\s\S]*?\}/.test(consumeBackBody));
// ⚠️ 「不存在」类断言必须盯**语句**而不是子串：方法体的注释里正好写着 Router.pop() 作说明，
// 用 indexOf 会假阳性（这条一开始就是这么挂的）。行首锚定 + 分号能只命中真正的调用。
check('抽屉形态下绝不 pop 路由（漏接 onClose 时也只会吞掉返回键，不会弹掉首页）',
  /(^|\n)\s*Router\.pop\(\);/.test(consumeBackBody) === false
  && /private exitRoot\(\): void \{[\s\S]*?if \(this\.drawer\) \{[\s\S]*?return;[\s\S]*?Router\.pop\(\);/.test(settingsSource));
/** 「页面形态根页不消费」的判据：方法体以 return false; 收尾。 */
function endsWithNotConsumed(body) {
  const index = body.lastIndexOf('return false;');
  return index >= 0 && body.slice(index).trim() === 'return false;';
}
/** 变异：把方法体最后一个 return false; 改成 return true;（用来证明上一条断言能被证伪）。 */
function replaceLastReturnFalse(body) {
  const index = body.lastIndexOf('return false;');
  if (index < 0) {
    return body;
  }
  return body.slice(0, index) + 'return true;' + body.slice(index + 'return false;'.length);
}
check('页面形态根页不消费（consumeBack 以 return false 收尾）', endsWithNotConsumed(consumeBackBody));
check('…该判据能被变异证伪（尾部 return false 改成 true 后不再成立）',
  replaceLastReturnFalse(consumeBackBody) !== consumeBackBody
  && endsWithNotConsumed(replaceLastReturnFalse(consumeBackBody)) === false);
check('两个展开区在返回键里先被收起',
  /if \(this\.appearanceOpen\) \{\s*this\.appearanceOpen = false;\s*return true;\s*\}/.test(settingsSource)
  && /if \(this\.sidebarOpen\) \{\s*this\.sidebarOpen = false;\s*return true;\s*\}/.test(settingsSource));
check('进子页时顺手收起展开区（免得返回键要多按一次）',
  /private openSubPage\(page: string\): void \{[\s\S]*?this\.appearanceOpen = false;[\s\S]*?this\.sidebarOpen = false;[\s\S]*?this\.page = page;/.test(settingsSource));
check('左上角「‹」根页按形态分流（抽屉 → onClose / 页面 → Router.pop）',
  /private goBack\(\): void \{[\s\S]*?this\.exitRoot\(\)/.test(settingsSource)
  && /private exitRoot\(\): void \{[\s\S]*?if \(this\.drawer\) \{[\s\S]*?this\.onClose\(\);[\s\S]*?return;[\s\S]*?Router\.pop\(\);/.test(settingsSource));

group('静态断言的鉴别力自检（在内存副本上做变异，不碰文件）');
/** [名称, 正则, 变异函数] —— 变异只作用于内存里的字符串副本，用来证明上面的断言不是恒真。 */
const MUTATIONS = [
  ['从 ../BackHandler 导入', /import \{ registerBackConsumer, unregisterBackConsumer \} from '\.\.\/BackHandler';/,
    (s) => s.replace("import { registerBackConsumer, unregisterBackConsumer } from '../BackHandler';", '')],
  // ⚠️ 负向预测把搜索限制在 aboutToAppear 体内：`unregisterBackConsumer(this.backConsumer)`
  // 含有 `registerBackConsumer(this.backConsumer)` 子串，不加限制就会假通过（同上面那条断言）。
  ['aboutToAppear 里注册', /aboutToAppear\(\): void \{(?:(?!\n  \})[\s\S])*?registerBackConsumer\(this\.backConsumer\)/,
    // 连前置行一起替换，避免把 aboutToDisappear 里的 unregister... 也当成命中点（它含同样子串）
    (s) => s.replace('this.alive = true;\n    registerBackConsumer(this.backConsumer);', 'this.alive = true;')],
  ['aboutToDisappear 里按身份注销', /aboutToDisappear\(\): void \{[\s\S]*?unregisterBackConsumer\(this\.backConsumer\)/,
    (s) => s.replace('unregisterBackConsumer(this.backConsumer)', '')],
  ['抽屉形态根页关抽屉', /if \(this\.drawer\) \{[\s\S]*?this\.onClose\(\);[\s\S]*?return true;/,
    // 该条件在 exitRoot 与 consumeBack 里各有一处，必须全量替换，否则只改掉一半、断言仍命中
    (s) => s.split('if (this.drawer) {').join('if (false) {')]
];
for (const item of MUTATIONS) {
  const mutated = item[2](settingsSource);
  check('「' + item[0] + '」断言命中真实源码', item[1].test(settingsSource));
  check('「' + item[0] + '」断言能被变异证伪', mutated !== settingsSource && item[1].test(mutated) === false);
}

// ---------------------------------------------------------------------------
// 9. 外观模式：深色/浅色切换是否真的下发到系统（R13 task-9，P0 修复）
// ---------------------------------------------------------------------------
//
// 下面两组是**行为断言**而不是文本匹配：把真实 .ets 转译成 CJS 后用桩模块加载
// （`@kit.*` 打桩、相对 import 用真实源码），再调用导出函数观察副作用。
// 起因：R12 真机复核发现「设置选深色后整机仍按浅色渲染」，而改前的本套件只断言了设置页
// 存在「深色」这个字符串 —— 字符串在、链路断，正是这次漏检的形态。

group('外观模式（store）：模式字符串的持久化与归一化');

const prefBuckets = new Map();
const arkDataStub = {
  preferences: {
    getPreferencesSync: (context, options) => {
      const name = options.name;
      if (!prefBuckets.has(name)) {
        prefBuckets.set(name, new Map());
      }
      const bucket = prefBuckets.get(name);
      return {
        getSync: (key, fallback) => (bucket.has(key) ? bucket.get(key) : fallback),
        putSync: (key, value) => { bucket.set(key, value); },
        deleteSync: (key) => { bucket.delete(key); },
        clearSync: () => { bucket.clear(); },
        flush: () => {}
      };
    }
  }
};
/** `store/AuthSessionStore` 只用到 normalizeServerOrigin，桩保持它的最小语义。 */
const apiUrlsStub = {
  normalizeServerOrigin: (value) => {
    const text = String(value === undefined || value === null ? '' : value).trim();
    if (text.length === 0) {
      return null;
    }
    if (text.indexOf('https://') !== 0 && text.indexOf('http://') !== 0) {
      return null;
    }
    return text;
  }
};
/** AbilityKit 桩：只提供运行期真正被读到的两个值（ColorMode 的取值与 SDK 一致：-1/0/1）。 */
function abilityKitStub() {
  return {
    common: {},
    ConfigurationConstant: {
      ColorMode: { COLOR_MODE_NOT_SET: -1, COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 }
    }
  };
}
/** 用桩模块加载真实 .ets；未打桩的 import 直接抛错，避免静默 undefined 式假通过。 */
function loadWithStubs(rel, stubs) {
  const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
    fileName: rel
  }).outputText;
  const module = { exports: {} };
  const requireStub = (id) => {
    if (Object.prototype.hasOwnProperty.call(stubs, id)) {
      return stubs[id];
    }
    throw new Error('未打桩的 import：' + id + '（来自 ' + rel + '）');
  };
  const fn = new Function('require', 'exports', 'module', code);
  fn(requireStub, module.exports, module);
  return module.exports;
}

const storeModule = loadWithStubs('store/AuthSessionStore.ets', {
  '@kit.ArkData': arkDataStub,
  '@kit.AbilityKit': abilityKitStub(),
  '../api/ApiUrls': apiUrlsStub
});
storeModule.initAppPrefs({});
eq('未设置时外观默认跟随系统', storeModule.readAppearanceMode(), 'system');
storeModule.saveAppearanceMode('dark');
eq('「深色」写盘后可读回', storeModule.readAppearanceMode(), 'dark');
storeModule.saveAppearanceMode('bogus');
eq('脏值读回时归一到跟随系统', storeModule.readAppearanceMode(), 'system');

group('外观模式（feature）：下发系统 colorMode + isDarkAppearance');

/** setColorMode 的调用记录 + 可控的系统 colorMode（模拟 `context.config`）。 */
const modeCalls = [];
let contextColorMode = 1;
const fakeAbilityContext = {
  getApplicationContext: () => ({
    setColorMode: (colorMode) => { modeCalls.push(colorMode); }
  }),
  get config() {
    return { colorMode: contextColorMode };
  }
};
const appServicesModule = loadWithStubs('feature/AppServices.ets', {
  '@kit.AbilityKit': abilityKitStub(),
  '../store/AuthSessionStore': storeModule,
  '../api/ApiUrls': apiUrlsStub,
  '../api/ApiClient': { ApiClient: class ApiClient {} },
  '../api/AuthApi': { AuthApi: class AuthApi {} },
  '../api/DevicesApi': { DevicesApi: class DevicesApi {} },
  '../api/FilesApi': { FilesApi: class FilesApi {} },
  '../api/SessionsApi': { SessionsApi: class SessionsApi {} },
  '../api/TerminalApi': { TerminalApi: class TerminalApi {} },
  '../api/RealtimeApi': { RealtimeApi: class RealtimeApi {}, newRealtimeClientId: () => 'test-client-id' },
  '../api/Parse': { str: () => '', optString: () => undefined },
  '../model/Types': {}
});
const appearance = appServicesModule.AppearanceController;

// ## R90-T3（用户：「时间栏内容没有适配深浅色模式，根本看不见信息」）
// 状态栏图标色的判定链上有一个**静默错误**：`context.config.colorMode` 在"跟随系统"下可能是
// `COLOR_MODE_NOT_SET(-1)`，而旧写法 `=== COLOR_MODE_DARK` 会把 -1 判成 **false（= 浅色）**
// ⇒ 深色系统画**深色图标**、落在深色画布上一片看不见。下面把这条钉住。

appearance.set('dark');
eq('未注册 Ability 上下文时下发降级为空（不炸）', modeCalls.length, 0);
eq('未注册上下文时模式依然落盘', storeModule.readAppearanceMode(), 'dark');

appearance.attach(fakeAbilityContext);
appearance.set('dark');
eq('选「深色」→ setColorMode(COLOR_MODE_DARK=0)', modeCalls[modeCalls.length - 1], 0);
appearance.set('light');
eq('选「浅色」→ setColorMode(COLOR_MODE_LIGHT=1)', modeCalls[modeCalls.length - 1], 1);
appearance.set('system');
eq('选「跟随系统」→ setColorMode(COLOR_MODE_NOT_SET=-1)', modeCalls[modeCalls.length - 1], -1);
eq('脏模式按下发口径也等同跟随系统', appServicesModule.appearanceColorMode('zzz'), -1);

appearance.set('dark');
eq('外观=深色 → isDarkAppearance() 为真', appServicesModule.isDarkAppearance(), true);
appearance.set('light');
eq('外观=浅色 → isDarkAppearance() 为假', appServicesModule.isDarkAppearance(), false);
appearance.set('system');
contextColorMode = 1;
eq('外观=跟随系统 + 系统浅色 → 为假', appServicesModule.isDarkAppearance(), false);
contextColorMode = 0;
eq('外观=跟随系统 + 系统深色 → 为真（改前硬编码 false）', appServicesModule.isDarkAppearance(), true);
contextColorMode = 1;

// ⚠️ 真机抓到的**矛盾帧**（改前的日志）：
//   ctxColorMode=1（浅） 但推送 cachedDark=true（深）—— 切换瞬间 context **滞后约 1ms** 且报反。
// 旧代码"优先信 context" ⇒ 画出与页面明暗相反的图标 = 用户报的「根本看不见」。
// 现行规则：**推送优先**；context 只在"还没收到过推送"时兜底，且 NOT_SET 不许当浅色。
appearance.syncSystemColorMode(0);   // 推送：深色
contextColorMode = 1;                // 同时 context 仍滞后地报"浅色"
eq('R90-T3 推送=深色 + context 滞后报浅色 → 仍判**深色**（推送优先，不被滞后源带偏）',
  appServicesModule.isDarkAppearance(), true);
appearance.syncSystemColorMode(1);   // 推送：浅色
contextColorMode = 0;                // context 又滞后地报"深色"
eq('R90-T3 推送=浅色 + context 滞后报深色 → 判**浅色**（推送优先）',
  appServicesModule.isDarkAppearance(), false);
contextColorMode = -1;               // NOT_SET：不许当浅色
appearance.syncSystemColorMode(0);
eq('R90-T3 context=NOT_SET 时仍以推送为准（深色）',
  appServicesModule.isDarkAppearance(), true);
contextColorMode = 1;

storeModule.saveAppearanceMode('dark');
modeCalls.length = 0;
const initApplied = appearance.init();
eq('冷启动 init() 读到持久化的「深色」', appearance.current, 'dark');
eq('冷启动 init() 立刻下发一次 COLOR_MODE_DARK', modeCalls[modeCalls.length - 1], 0);
eq('冷启动下发成功返回 true', initApplied, true);

// ⚠️ R90-T3：先"预热"一次，把 systemDarkKnown 置真并把"当前"定成浅色，
// 这样下面三次调用的计数只反映**真实变化**，不受"首次学到系统深浅"影响。
appearance.syncSystemColorMode(0);   // 预热：known=true，当前=浅色
let appearanceNotified = 0;
const appearanceListener = () => { appearanceNotified += 1; };
appearance.onChange(appearanceListener);
appearance.syncSystemColorMode(1);   // 真实变化①：浅→深 ⇒ 通知
appearance.syncSystemColorMode(1);   // 重复值 ⇒ 静默
appearance.syncSystemColorMode(0);   // 真实变化②：深→浅 ⇒ 通知
appearance.offChange(appearanceListener);
appearance.syncSystemColorMode(1);   // 已摘监听 ⇒ 不再计数
eq('系统深浅只对「真实变化」广播（两种变化 = 两次通知）', appearanceNotified, 2);

group('外观下发：静态锚点与鉴别力自检');
const appServicesSource = fs.readFileSync(path.join(SRC_ETS, 'feature', 'AppServices.ets'), 'utf8');
const entryAbilitySource = fs.readFileSync(path.join(SRC_ETS, 'entryability', 'EntryAbility.ets'), 'utf8');
/** 取函数体最后一个 return 语句（判「兜底分支读什么」比整段匹配稳）。 */
function tailReturn(body) {
  return body.slice(body.lastIndexOf('return ')).trim();
}
const darkFnBody = (appServicesSource.match(/export function isDarkAppearance\(\): boolean \{([\s\S]*?)\n\}/) || ['', ''])[1];
check('能定位 isDarkAppearance 函数体（后续断言的作用域）', darkFnBody.length > 0);
check('isDarkAppearance 的兜底分支读系统深浅（不再硬编码 false）',
  tailReturn(darkFnBody) === 'return AppearanceController.systemIsDark;',
  '尾部实际是：' + tailReturn(darkFnBody));
const mutatedDarkFnBody = darkFnBody.replace('return AppearanceController.systemIsDark;', 'return false;');
check('…该判据能被变异证伪（改回 return false 后不再成立）',
  mutatedDarkFnBody !== darkFnBody
  && tailReturn(mutatedDarkFnBody) !== 'return AppearanceController.systemIsDark;');
const setBody = (appServicesSource.match(/static set\(mode: string\): void \{([\s\S]*?)\n  \}/) || ['', ''])[1];
check('能定位 AppearanceController.set 方法体（后续断言的作用域）', setBody.length > 0);
check('set() 真的把模式下发到系统（R12 根因①）', setBody.indexOf('AppearanceController.apply();') >= 0);
// R90-T3：readContextDark 必须**显式区分三态**，不能把"未知"混进"浅色"
const rcdBody = (appServicesSource.match(/private static readContextDark\(\): boolean \{([\s\S]*?)\n  \}/) || ['', ''])[1];
check('R90-T3 能定位 readContextDark 方法体', rcdBody.length > 0);
check('R90-T3 readContextDark 显式判 COLOR_MODE_LIGHT（不再只判 DARK ⇒ 未知被误判成浅色）',
  rcdBody.indexOf('COLOR_MODE_LIGHT') >= 0,
  '缺少 LIGHT 分支 ⇒ COLOR_MODE_NOT_SET(-1) 会落进"非深色"= 浅色');
check('R90-T3 readContextDark **以推送为准**（context 在切换瞬间会滞后且报反）',
  /if \(AppearanceController\.systemDarkKnown\) \{\s*\r?\n\s*return AppearanceController\.systemDark;/.test(rcdBody),
  '没有"推送优先"分支 ⇒ 会被滞后的 context.config 带偏');
check('R90-T3 readContextDark 对未知/异常**回退缓存**（return AppearanceController.systemDark）',
  rcdBody.indexOf('return AppearanceController.systemDark;') >= 0);
check('R90-T3 收到推送时置 systemDarkKnown（此后 context 只兜底）',
  appServicesSource.indexOf('AppearanceController.systemDarkKnown = true;') >= 0);
check('R90-T3 attach 不得把 systemDarkKnown 置真（注册上下文 ≠ 收到权威推送）',
  !/static attach[\s\S]{0,900}?systemDarkKnown = true/.test(appServicesSource));
check('R90-T3 冷启动 init() 不得把 NOT_SET 覆写成浅色（读法必须走 readContextDark）',
  appServicesSource.indexOf('AppearanceController.systemDark = AppearanceController.readContextDark();') >= 0);
check('R90-T3 attach() 仅在拿到具体值时才更新缓存（未知保留 onConfigurationUpdate 的值）',
  appServicesSource.indexOf('if (resolved !== undefined) {') >= 0);
check('…该判据能被变异证伪',
  setBody.replace('AppearanceController.apply();', '').indexOf('AppearanceController.apply();') < 0);
check('apply() 真的调用 ApplicationContext.setColorMode',
  /\.getApplicationContext\(\)\.setColorMode\(appearanceColorMode\(/.test(appServicesSource));
check('EntryAbility.onCreate 注册上下文并冷启动下发一次',
  entryAbilitySource.indexOf('AppearanceController.attach(this.context)') >= 0
  && entryAbilitySource.indexOf('AppearanceController.init()') >= 0);
check('EntryAbility.onConfigurationUpdate 同步系统深浅（跟随系统要跟着变）',
  /onConfigurationUpdate\(newConfig: Configuration\): void \{([\s\S]*?)syncSystemColorMode\(colorMode\)/.test(entryAbilitySource));
check('EntryAbility 在窗口就绪后补一次下发（SDK 要求窗口已建 + 页面已加载）',
  /loadContent\('pages\/Index'[\s\S]*?AppearanceController\.apply\(\)/.test(entryAbilitySource));
group('沉浸式全屏（R13 task-14）：系统栏透明 + 图标色随深浅 + 页面通底通顶');
const indexSource = fs.readFileSync(path.join(SRC_ETS, 'pages', 'Index.ets'), 'utf8');

check('开沉浸式全屏（改前的 setWindowLayoutFullScreen(false) 是灰带根因）',
  /setWindowLayoutFullScreen\(true\)/.test(entryAbilitySource)
  && entryAbilitySource.indexOf('setWindowLayoutFullScreen(false)') < 0);
check('…该判据能被变异证伪',
  entryAbilitySource.replace('setWindowLayoutFullScreen(true)', 'setWindowLayoutFullScreen(false)')
    .indexOf('setWindowLayoutFullScreen(false)') >= 0);
/** 解析资源：把某个限定目录的 color.json 读成 name -> value 映射。 */
function readColorMap(qualifier) {
  const file = qualifier === 'dark'
    ? path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json')
    : path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json');
  const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  const map = {};
  for (const entry of parsed.color) {
    map[entry.name] = entry.value;
  }
  return map;
}
const baseColors = readColorMap('base');
const darkColors = readColorMap('dark');
// ⚠️ R13-12 第三次真机返工：沉浸**只能**由「系统栏底色 = 页面画布色」承担。
// 透明系统栏 + 页面自己画 = 那条死路（内容会跟着进系统栏，见下面 expandSafeArea 的断言）。
check('系统栏底色透明（铺满交给页面背景层）',
  /statusBarColor: SYSTEM_BAR_TRANSPARENT/.test(entryAbilitySource)
  && /navigationBarColor: SYSTEM_BAR_TRANSPARENT/.test(entryAbilitySource)
  && /const bottomPx: number = systemBottomPx > indicatorBottomPx/.test(entryAbilitySource));
check('画布色随深浅两套取值，不是写死一个',
  /const CANVAS_COLOR_LIGHT: string = '#FFFDFCFB';/.test(entryAbilitySource)
  && /const CANVAS_COLOR_DARK: string = '#FF09090B';/.test(entryAbilitySource));
check('浅色画布常量与资源 canvas 一致（常量是资源的镜像）',
  entryAbilitySource.indexOf("'#FF" + baseColors.canvas.slice(1) + "'") >= 0, '资源值 ' + baseColors.canvas);
check('深色画布常量与资源 canvas 一致',
  entryAbilitySource.indexOf("'#FF" + darkColors.canvas.slice(1) + "'") >= 0, '资源值 ' + darkColors.canvas);
// （「不再用透明系统栏」已删除：R13-14 起系统栏**就是**透明的，铺满交给背景层。）
check('系统栏图标色随深浅色（浅色页面→深色图标、深色页面→浅色图标）',
  /statusBarContentColor: iconColor/.test(entryAbilitySource)
  && /navigationBarContentColor: iconColor/.test(entryAbilitySource)
  && /const dark: boolean = isDarkAppearance\(\);/.test(entryAbilitySource)
  && /const iconColor: string = dark \? SYSTEM_BAR_ICON_ON_DARK : SYSTEM_BAR_ICON_ON_LIGHT;/.test(entryAbilitySource));
check('外观变化时重设系统栏配色（静态设置会让深色页面留浅色图标）',
  /AppearanceController\.onChange\(\(\) => \{\n      this\.syncSystemBarColors\(\);/.test(entryAbilitySource));
// ⚠️ R13-12 显式避让（沉浸态下 ArkUI **不会**自动避让，expandSafeArea 只能「取消」避让）。
const designSource2 = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8');
check('Design 导出避让高度的 AppStorage 键（EntryAbility ↔ 页面 的契约）',
  /export const SAFE_AREA_TOP_PX: string = 'aaSafeAreaTopPx';/.test(designSource2)
  && /export const SAFE_AREA_BOTTOM_PX: string = 'aaSafeAreaBottomPx';/.test(designSource2));
check('EntryAbility 读系统避让区（TYPE_SYSTEM 的 topRect/bottomRect）',
  /const area: window\.AvoidArea = mainWindow\.getWindowAvoidArea\(\window\.AvoidAreaType\.TYPE_SYSTEM\);/.test(entryAbilitySource)
  && /const topPx: number = area\.topRect\.height;/.test(entryAbilitySource)
  && /const systemBottomPx: number = area\.bottomRect\.height;/.test(entryAbilitySource));
check('…并把实测值写进 AppStorage（页面据此 padding）',
  /AppStorage\.setOrCreate\(SAFE_AREA_TOP_PX, topPx\)/.test(entryAbilitySource)
  && /AppStorage\.setOrCreate\(SAFE_AREA_BOTTOM_PX, bottomPx\)/.test(entryAbilitySource));
check('底部避让取 max(系统栏, 手势条) —— 手势导航下 TYPE_SYSTEM.bottomRect 可能为 0',
  /getWindowAvoidArea\(window\.AvoidAreaType\.TYPE_NAVIGATION_INDICATOR\)/.test(entryAbilitySource)
  && /const bottomPx: number = systemBottomPx > indicatorBottomPx/.test(entryAbilitySource));
check('避让值有四个刷新触发点（设完全屏 / 载入后 / 配置变化 / avoidAreaChange）',
  (entryAbilitySource.match(/this\.pushSafeAreaInsets\(\)/g) || []).length >= 4
  && entryAbilitySource.indexOf("mainWindow.on('avoidAreaChange'") >= 0);
check('页面用 @StorageLink 读避让高度',
  /@StorageLink\(SAFE_AREA_TOP_PX\) safeAreaTopPx: number = 0;/.test(indexSource)
  && /@StorageLink\(SAFE_AREA_BOTTOM_PX\) safeAreaBottomPx: number = 0;/.test(indexSource));
// ⚠️ R37 五改：**顶部避让也从 Index 根节点下放到各页顶栏了**（改前是根节点 `.padding({ top: … })`）。
// 用户要求「最上面系统状态栏那条也要和上方功能栏一样的模糊」⇒ 状态栏必须能被内容**穿过**，
// 根节点一 padding 就把页面顶栏推到状态栏之下、那一条永远是纯色画布色。
// 现在的判据是**两条合取**：根节点不再 padding + 各页顶栏自己 topInset()。
const ROOT_TOP_PADDING = '.padding({ top: this.getUIContext().px2vp(this.safeAreaTopPx) })';
check('根节点不再替页面避让顶部（R37 五改：下放到各页顶栏）', indexSource.indexOf(ROOT_TOP_PADDING) < 0);
/**
 * ⚠️ **R65 口径换代（不是放宽，是把「固定名单」换成「按页面形态自洽」）**。
 *
 * 旧判据是「这 9 个页面都必须把 `topInset()` 用在 top 上」——它把**某一时刻的页面形态**写成了名单。
 * R65 起顶栏逐步迁入 `Navigation` 的**自定义标题栏**（官方沉浸光感的生效范围，见
 * ），而进框架标题栏后**框架已经让出状态栏** ⇒ 页面再 `topInset()`
 * 就是**重复避让**（R62 HomeScreen 实测重复 137px，且该值来自非响应的 `AppStorage.get`、
 * 会随冷启动时序在 `0 / 46vp` 之间跳）。所以名单式判据在迁移期必然假红。
 *
 * 新判据 = **每个页面各自自洽**：
 *   · 顶栏已在框架标题栏内（源码同时含 `Navigation(` 与 `.title(`）⇒ **不许**再出现 `this.topInset()`；
 *   · 顶栏仍自绘（无 `Navigation.title`）⇒ **必须**仍用 `this.topInset()`。
 * 好处：任何一页在**迁移前 / 迁移后**都自洽，不需要维护一张会随轮次漂移的名单；
 * 且它仍是**双向**护栏（重复避让与漏避让都会红），不是"少判一条"。
 */
const ALL_TOP_BAR_PAGES = [
  // HomeScreen：R62 起就是 Navigation 自定义标题栏（已迁）；其余随 R65 逐步迁入。
  'HomeScreen', 'SessionDetailScreen', 'TerminalScreen', 'FilesScreen', 'SettingsScreen',
  'DevicesScreen', 'DeviceDetailScreen', 'AddDeviceScreen', 'ArchivedSessionsScreen', 'NewSessionScreen'
];
// 写法有两类都合法：`top: this.topInset()`（多数页）与 `top: Space.X + this.topInset()`
// （SessionDetailScreen：顶栏自带内边距，避让值叠加上去）。用正则同时接受。
const TOP_INSET_USED = /top:\s*[^,\n]*this\.topInset\(\)/;
const MIGRATED_TO_NAV_TITLE = (src) => src.indexOf('Navigation(') >= 0 && src.indexOf('.title(') >= 0;
/**
 * ⚠️ **R75 实现修正（判据原意一字未改）** —— 与下面 `expandSafeArea` 那条同因：
 * 本断言也是**裸扫源码全文**，于是**解释性注释**里写到 `top: this.topInset()` 就会被判成「真的在避让」。
 * R75 实测撞到：`SessionDetailScreen` 的新注释里引用了**旧写法**（"原来写 `top: this.topInset()`"）
 * ⇒ 该页被误判「重复避让」，30 套件假红。
 * 这是本工程**第四次**「注释被当代码」（另三次：suite-files 的 Kit import 计数、
 * suite-send-icon 的 `interactive: true`、suite-settings 自己的 `expandSafeArea`）。
 * 统一口径：**先剥注释再判**。`STRIP_COMMENTS` 因此提到了本处之前（原先定义在本断言之下）。
 */
const STRIP_COMMENTS = (s) => s.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
const insetDouble = [];
const insetMissing = [];
const insetChecked = [];
for (const name of ALL_TOP_BAR_PAGES) {
  const pagePath = path.join(SRC_ETS, 'ui', 'screens', name + '.ets');
  if (!fs.existsSync(pagePath)) { continue; }
  const src = fs.readFileSync(pagePath, 'utf8');
  const migrated = MIGRATED_TO_NAV_TITLE(src);
  const hasInset = TOP_INSET_USED.test(STRIP_COMMENTS(src));
  insetChecked.push(name);
  if (migrated && hasInset) { insetDouble.push(name); }
  if (!migrated && !hasInset) { insetMissing.push(name); }
}
check('状态栏避让自洽（R65）：顶栏进框架标题栏的页面不再 topInset()，自绘顶栏的页面仍 topInset()',
  insetChecked.length >= 8 && insetDouble.length === 0 && insetMissing.length === 0,
  '扫描 ' + insetChecked.length + ' 页 | 重复避让：' + insetDouble.join(',') + ' | 漏避让：' + insetMissing.join(','));
// ⚠️ R66 实现修正（**判据原意一字未改，只是把"注释也算"这个实现缺陷补上**）：
// 该断言是**裸扫源码全文**，于是任何一句**解释性注释**里提到 `expandSafeArea` 都会被判红 ——
// R66 已实测撞到一次（r66-topbar 在注释里写「不再叠任何安全区 API」时用了这个词，30 套件假红，
// 它只能改注释绕开，因为 tools/ 不在它的写入面）。
// 这是本工程第三次遇到「注释被当代码」（另两次：suite-files 的 Kit import 计数、suite-send-icon 的
// `interactive: true`），统一口径：**先剥注释再判**。
// ⚠️ R75：`STRIP_COMMENTS` 已上移到「状态栏避让自洽」那条断言之前（它现在也用它）——
// 这里**不要**再声明一次（会触发 `Identifier 'STRIP_COMMENTS' has already been declared`）。
check('五页根节点都不自带 expandSafeArea（避让只由 Index 的 padding 统一做）',
  ['HomeScreen', 'SessionDetailScreen', 'TerminalScreen', 'FilesScreen', 'SettingsScreen'].every((name) =>
    STRIP_COMMENTS(fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', name + '.ets'), 'utf8'))
      .indexOf('expandSafeArea') < 0));
check('不再调 setWindowBackgroundColor（ArkTS 判其在 phone/tablet 不可用，会破零告警）',
  /\.setWindowBackgroundColor\(/.test(entryAbilitySource) === false);
check('Configuration.colorMode 缺省时不再当成浅色（SDK 类型是可选项，误判会让图标色跟着错）',
  /const colorMode: ConfigurationConstant\.ColorMode \| undefined = newConfig\.colorMode;/.test(entryAbilitySource));
/** 根节点属性区（路由分支之后到文件尾）——用来断言「根节点自己没有 expandSafeArea」。 */
const indexTail = indexSource.slice(indexSource.lastIndexOf('} else {'));
const EXPAND_EXPR = '.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])';
// ⚠️ R13-11 / R13-12 两次真机返工的结论：**页面侧不要用 expandSafeArea 做沉浸**。
// 它在百分比尺寸下会把容器自身一起扩掉，内容跟着进系统栏（挂根节点 5865 墨点；改成分层仍 5897，安卓 2150）。
// ⚠️ R13-14：expandSafeArea 只允许出现在**背景层**（它会把容器撑大，所以内容层必须靠 padding 避让）。
check('expandSafeArea 只挂在背景层上，且 Index 里只此一处',
  (indexSource.match(/\.expandSafeArea\(/g) || []).length === 1,
  'expandSafeArea 出现次数应为 1');
check('背景层按**路由**取页面底色（终端页深色，不能写死画布色）',
  /this\.route === Route\.TERMINAL[\s\S]{0,120}?\$r\('app\.color\.terminal_background'\)/.test(indexSource));
check('…该判据能被变异证伪（把路由判断去掉、退回固定画布色后不再成立）',
  /this\.route === Route\.TERMINAL[\s\S]{0,120}?\$r\('app\.color\.terminal_background'\)/
    .test(indexSource.split('this.route === Route.TERMINAL').join('false')) === false);
// ⚠️ R13-11 真机返工：把 expandSafeArea 挂在**根节点**上会让内容也顶进状态栏
// （真机实证：状态栏时间与「Agents Anywhere」叠印、顶部 0-135 行亮度 246.0 → 222.1）。
// 所以它只能挂在**背景层**这一个 `Column` 上，根节点必须没有。
check('根节点自身**不**expandSafeArea（否则内容层跟着长、顶进状态栏）',
  indexTail.indexOf('.expandSafeArea(') < 0);
// （「全工程 0 处 expandSafeArea」已删除：R13-14 起背景层重新使用它，改由「只允许背景层用」那条守住。）
check('…该判据能被变异证伪（给根节点补一条 expandSafeArea 后不再成立）',
  (function () {
    // 变异：先把背景层的 expandSafeArea 全删掉，再把它贴到**最后一次** `.backgroundColor(canvas())` 之后
    // （= 根节点的属性区）。用 lastIndexOf 定位而不是匹配行尾，避免被 CRLF/LF 差异搞成假通过。
    const anchor = '.backgroundColor(canvas())';
    const mutated = indexSource.split(EXPAND_EXPR).join('');
    const at = mutated.lastIndexOf(anchor) + anchor.length;
    const rootMutated = mutated.slice(0, at) + EXPAND_EXPR + mutated.slice(at);
    return rootMutated.slice(rootMutated.lastIndexOf('} else {')).indexOf('.expandSafeArea(') >= 0;
  })());
check('启动页底色资源存在且与画布同名同值（冷启动首帧不闪灰底）',
  /\$color:start_window_background/.test(fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'module.json5'), 'utf8'))
  && /start_window_background/.test(fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'), 'utf8'))
  && /start_window_background/.test(fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'), 'utf8')));

/**
 * 启动页底色 = ？两条读法（浅色 canvas / 深色 canvas）都必须成立：
 * 启动页与页面画布不同色时，冷启动第一帧就会看到一条异色带。
 */
function readCanvasColor(qualifier) {
  const file = qualifier === 'dark'
    ? path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json')
    : path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json');
  const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  const map = {};
  for (const entry of parsed.color) {
    map[entry.name] = entry.value;
  }
  return map;
}
eq('浅色：启动页底色 == 画布色', readCanvasColor('base').start_window_background, readCanvasColor('base').canvas);
eq('深色：启动页底色 == 画布色', readCanvasColor('dark').start_window_background, readCanvasColor('dark').canvas);
check('深浅两套画布确实不同色（否则「深色不生效」这类缺陷会被这套断言掩盖）',
  readCanvasColor('base').canvas !== readCanvasColor('dark').canvas);


// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 10. F-10：设置页返回钮圆底 + 顶部留白（R13 task-18）
// ---------------------------------------------------------------------------
//
// 背景：device-baseline 用像素判据坐实两条 ——
//  ① 返回区 x60-230/y190-300 的「≥250 近白」像素 安卓 8707 / 鸿蒙 156（鸿蒙是裸箭头，没有白圆盘）；
//  ② 首个白卡顶端 y 安卓 361 / 鸿蒙 662（低 301px ≈ 101vp），标题行两侧都是 y≈202-266 ⇒ 空白全在「标题→首卡」之间。
// 根因（本包查证）：**`Scroll` 的通用属性 `align` 默认值是 `Alignment.Center`** ⇒ 内容比视口短时被垂直居中。
// 真机 dump：`Scroll`[0,326][1316,2734] 的子 `Column`[0,660][1316,2399]，660-326 = 334 = (2408-1739)/2，底部同样空 335px。

group('F-10：设置页返回钮圆底 + 顶部留白（R13 task-18）');
const componentsSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Components.ets'), 'utf8');

// ① 返回钮：复用 AaCircleIconButton（上游 `Components.kt:38 BackIconButton`：40dp 圆 + raisedSurface 底 + 1dp 描边 + 22dp ChevronLeft）
//
// ⚠️ **R65 尾窗 200 → 400**（放宽的是"窗口"，不是判据本身；三个锚点 `AaCircleIconButton(` / `name: 'chevron-left'` /
//    `filled: true` 与整体形态一字未改）：
//    R65-A 给这个返回钮合规地补了 `glass: true` / `officialMaterial: true` / `accessibilityLabel` / `tint` / `onTap`
//    等行（官方沉浸光感的生效范围），
//    `filled: true` → `})` 的实测距离由 <200 变成 **274** ⇒ 旧窗口被合规新增行挤破而假红。
//    **窗口超限不是功能缺陷**，据此放宽并留证；下方本体断言与 `裸箭头已消失` 一条仍是硬判据。
check('返回钮用带底色的圆形按钮（不是裸箭头）',
  /AaCircleIconButton\(\{[\s\S]{0,400}?name: 'chevron-left'[\s\S]{0,400}?filled: true[\s\S]{0,400}?\}\)/.test(settingsSource));
check('裸箭头写法已消失（改前 AaIcon(chevron-left, 28) 直接放进 Column，无底色无描边）',
  settingsSource.indexOf("AaIcon({ d: ICONS['chevron-left'], iconSize: 28") < 0);
check('直径与图标尺寸照上游（40dp 圆 + 22dp ChevronLeft）',
  /diameter: Control\.NAV_BUTTON_LARGE/.test(settingsSource)
  && /iconSize: FontSize\.ICON_XL/.test(settingsSource));
check('…尺寸令牌确实是 40 / 22（防令牌值被改而不自知）',
  /static readonly NAV_BUTTON_LARGE: number = 40;/.test(designSource)
  && /static readonly ICON_XL: number = 22;/.test(designSource));
check('AaCircleIconButton 自身是「圆底 + 描边」实现',
  /\.borderRadius\(this\.diameter \/ 2\)/.test(componentsSource)
  && /\.backgroundColor\(this\.filled \? this\.surface : Color\.Transparent\)/.test(componentsSource));
/** 白圆盘面积（px²）：40vp 直径、dpr 2.975（本机实测）—— 要覆盖安卓的 8707px 判据。 */
const DISC_PX = 40 * 2.975;
const DISC_AREA = Math.PI * (DISC_PX / 2) * (DISC_PX / 2);
check('白圆盘面积达到安卓量级（≥ 8707 px²）', DISC_AREA >= 8707, '预测 ' + Math.round(DISC_AREA));

// ② 顶部留白：Scroll 内容顶对齐（align 默认 Center 会把短内容垂直居中）
check('滚动内容顶对齐（去掉 Scroll 的默认垂直居中）',
  // ⚠️ 要求 `.align(Alignment.Top)` **独占一行**：改成任意位置匹配的话，上面那段解释性注释里
  // 提到的 `.align(Alignment.Top)` 就会让这条断言变成恒真（本工程已有同类假通过的先例）。
  /\.scrollBar\(BarState\.Off\)[\s\S]*?\n\s*\.align\(Alignment\.Top\)/.test(settingsSource));
check('…该判据能被变异证伪（去掉 align 后不再成立）',
  /\.scrollBar\(BarState\.Off\)[\s\S]*?\n\s*\.align\(Alignment\.Top\)/.test(
    settingsSource.split('.align(Alignment.Top)').join('')) === false);
check('首卡上方补 10vp（上游 header 与 IdentityCard 之间的 spacedBy(10.dp)）',
  /\.padding\(\{ left: Space\.PAGE, right: Space\.PAGE, top: Space\.S_PLUS \}\)/.test(settingsSource));
/**
 * 首卡顶端预测：状态栏底 137px（真机 dump 的内容区起点）+ header 64vp + 10vp 间距，dpr 2.975。
 * 预测 ≈357px，安卓实测 361px ⇒ 差 4px，落在验收判据 ±20px 内。
 */
const PREDICTED_CARD_TOP = 137 + 64 * 2.975 + 10 * 2.975;
check('首卡顶端预测落在安卓判据 ±20px 内（y≈361）',
  Math.abs(PREDICTED_CARD_TOP - 361) <= 20, '预测 ' + Math.round(PREDICTED_CARD_TOP));

// ③ 顺带落盘的 R13-2 补丁：品牌字标字体在**首次渲染前**注册
check('EntryAbility 在 loadContent 之前注册品牌字标字体',
  entryAbilitySource.indexOf('ensureWordmarkFont(this.mainWindow.getUIContext())') >= 0
  && entryAbilitySource.indexOf('ensureWordmarkFont(') < entryAbilitySource.indexOf("loadContent('pages/Index'"));
check('该 import 来自 ui/Components',
  /import \{ ensureWordmarkFont \} from '\.\.\/ui\/Components';/.test(entryAbilitySource));
check('HomeScreen 的兜底注册仍在（Ability 侧取不到窗口时兜底）',
  /ensureWordmarkFont\(this\.getUIContext\(\)\)/.test(
    fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'HomeScreen.ets'), 'utf8')));

group('R13-21 / 4-x：设置页与语言页对齐上游');
check('4-1 检查更新行行首图标改成 server（下载是行尾 trailingIcon）',
  settingsSource.indexOf("this.rowIcon('server', $r('app.color.ink_soft'))") >= 0);
check('4-1 有新版时行尾出现下载图标（上游 trailingIcon = Lucide.Download）',
  /this\.updateStatus === UPDATE_AVAILABLE[\s\S]{0,260}?ICONS\['download'\]/.test(settingsSource));
// ## R92-T3（用户：「将设置页的『语言』栏、『Agent 预设』栏的展开标签换成上下三角，统一一下逻辑」）
// ⚠️ **本条判据被有意演进**：计数 2 → 4（断言演进允许，绕断言不允许）。改前只有「外观」「侧边栏显示」
// 是双向箭头，「语言」与「Agent 预设」还是 `chevron-right` / 20vp —— R63 曾把那个不一致当成契约钉在这里；
// 本轮用户明确要求四张入口卡统一（四者本是**同一个交互语义**：点开弹小窗选值）。
// 判据本身没变（「本页的双向箭头就是这几处、一处不多一处不少」），只是分母从 2 变成 4。
check('4-2 外观 / 侧边栏 / 语言 / Agent 预设四行行尾都是双向箭头（上游 Lucide.ChevronsUpDown；R92 计数 2→4）',
  (settingsSource.match(/ICONS\['chevrons-up-down'\]/g) || []).length === 4);
/**
 * 取「某张卡的行内锚文之后第一个 `AaIcon({…})` 那一行」= 该卡的行尾图标。
 *
 * ⚠️ 用**位置切片**而不是正则窗口：锚文到行尾图标之间隔着 258~395 个字符
 * （中间是 `layoutWeight` / `maxLines` 等五条链式属性 + 本轮新加的一行注释），
 * 写死 `[\s\S]{0,N}` 既容易太窄（变异时抓不住、判据恒真）、又容易太宽（跨到下一张卡，把邻卡的图标误算进来）。
 * 切片版对「只改一半」「改错尺寸」两种变异都能证伪（见下面紧随的自检）。
 */
function trailingIconOf(source, anchor) {
  const at = source.indexOf(anchor);
  if (at < 0) {
    return '';
  }
  const next = source.indexOf('AaIcon({', at);
  if (next < 0) {
    return '';
  }
  const eol = source.indexOf('\n', next);
  return source.slice(next, eol < 0 ? source.length : eol).trim();
}

function mutateTrailingIcon(source, anchor, from, to) {
  const at = source.indexOf(anchor);
  if (at < 0) {
    return source;
  }
  const next = source.indexOf('AaIcon({', at);
  if (next < 0) {
    return source;
  }
  return source.slice(0, next) + source.slice(next).replace(from, to);
}

/** 四张「点开弹小窗选值」的入口卡（R92 统一后行尾图标必须逐字一致）。 */
const TRAILING_ICON_ANCHORS = [
  'Text(this.appearanceLabelText())',
  'Text(languageLabel(this.languageMode))',
  'Text(sidebarViewLabel(this.sidebarView))',
  'Text(this.presetSummary())'
];
/** 统一后的行尾图标：同一枚双向箭头 + 同一尺寸 16vp（Lucide `chevrons-up-down`）。 */
const TRAILING_ICON_EXPECTED = "AaIcon({ d: ICONS['chevrons-up-down'], iconSize: 16, color: $r('app.color.faint') })";

// R92 正向判据：四张卡**逐卡**比行尾那一行的字面量（不只比全页计数）——
// 计数相等档不住「两张卡互换图标」这类错误，逐卡字面量能。
check('R92 四张入口卡的行尾图标逐字一致（外观 / 语言 / 侧边栏显示 / Agent 预设 = 同一枚图标 + 同尺寸 16vp）',
  TRAILING_ICON_ANCHORS.every((anchor) => trailingIconOf(settingsSource, anchor) === TRAILING_ICON_EXPECTED),
  TRAILING_ICON_ANCHORS.map((a) => a + ' → ' + trailingIconOf(settingsSource, a)).join(' | '));
// ⚠️ 这里**只**对四张卡各自的那一行做字面量比对，不去数全页 `chevron-right`：
// 账号行(585) / 检查更新行(839) / 已归档会话行(870) 三处的单向 chevron 是「整页跳转」语义，属合法保留。

/** 鉴别力自检（内存变异，不碰文件）：对**每一张卡**做两种变异，逐卡断言都必须失效。 */
let trailingMutationOk = true;
const trailingMutationDetail = [];
for (const anchor of TRAILING_ICON_ANCHORS) {
  const iconReverted = mutateTrailingIcon(settingsSource, anchor,
    "ICONS['chevrons-up-down'], iconSize: 16", "ICONS['chevron-right'], iconSize: 20");
  const sizeDegraded = mutateTrailingIcon(settingsSource, anchor, 'iconSize: 16', 'iconSize: 20');
  const revertCaught = iconReverted !== settingsSource
    && trailingIconOf(iconReverted, anchor) !== TRAILING_ICON_EXPECTED;
  const sizeCaught = sizeDegraded !== settingsSource
    && trailingIconOf(sizeDegraded, anchor) !== TRAILING_ICON_EXPECTED;
  if (!revertCaught || !sizeCaught) {
    trailingMutationOk = false;
    trailingMutationDetail.push(anchor + '(还原' + revertCaught + '/尺寸' + sizeCaught + ')');
  }
}
check('…该判据能被变异证伪（四张卡 × 图标还原 / 尺寸退化 共 8 次变异全部被抓）',
  trailingMutationOk, trailingMutationDetail.join(' '));
check('4-2 不再用随展开态翻转的单向 chevron',
  settingsSource.indexOf("this.appearanceOpen ? ICONS['chevron-up']") < 0
  && settingsSource.indexOf("this.sidebarOpen ? ICONS['chevron-up']") < 0);
// ## R90-T5（用户：「将设置里语言弹窗中的 Follow system 改为跟随系统」）
// ⚠️ **本条断言被有意翻转**（原判据是 4b-1："首项必须是英文 Follow system"）。
// 翻转理由：R13-21 当年照抄"语言列表用语言自称"这条上游依据，副作用是全中文设置页里
// 唯一一项是英文 —— 用户直接报了这条。上游其实有**两个** key：
// [[BT]]profile_follow_system[[BT]] =「跟随系统」（真正的中文文案）与 [[BT]]profile_language_follow_system[[BT]] = "Follow system"。
// 取前者同样是**有据可依的上游文案**，且与本工程 [[BT]]languageLabel()[[BT]]（行右侧早就写「跟随系统」）**一致**。
check('R90-T5 语言页首项改用中文「跟随系统」（不再用英文 Follow system）',
  settingsSource.indexOf("this.languageOption(LANGUAGE_SYSTEM, '跟随系统')") >= 0
  && settingsSource.indexOf("this.languageOption(LANGUAGE_SYSTEM, 'Follow system')") < 0,
  '首项又回到英文，或中文没生效');
// 一致性：弹窗首项文案必须与「语言」行右侧的 languageLabel() 同源同字
// 一致性：弹窗首项文案必须与「语言」行右侧的 languageLabel() 同源同字。
// ⚠️ 这里**自己读一次** AppPreferences 源码 —— 复用一个"在本块之后才声明"的变量会踩 const 的 TDZ。
const appPrefsSource = fs.readFileSync(path.join(SRC_ETS, 'store/AppPreferences.ets'), 'utf8');
check('R90-T5 语言弹窗首项与 languageLabel() 的文案一致（改前是"弹窗英文/行中文"的割裂态）',
  appPrefsSource.indexOf("return '跟随系统';") >= 0,
  'languageLabel() 没写「跟随系统」');
check('…该判据能被变异证伪（把行右侧改回英文后不再成立）',
  appPrefsSource.replace("return '跟随系统';", "return 'Follow system';").indexOf("return '跟随系统';") < 0);
check('4b-2 上游没有的自写说明行已删除',
  settingsSource.indexOf('语言偏好已保存在本机') < 0);


group('R13-22 / 4-3：选值改锚定弹层（bindPopup）');
check('外观行挂 bindPopup（不再行内手风琴）',
  settingsSource.indexOf('.bindPopup(this.appearanceOpen, this.appearancePopupOptions())') >= 0);
check('侧边栏行同样改成弹层',
  settingsSource.indexOf('.bindPopup(this.sidebarOpen, this.sidebarPopupOptions())') >= 0);
check('行内手风琴的实现已删除（appearanceOption / sidebarOption 不再存在）',
  settingsSource.indexOf('appearanceOption(') < 0 && settingsSource.indexOf('sidebarOption(') < 0);
// ⚠️ R63：本页的锚定弹层从 2 处（外观 / 侧边栏）变成 **4 处** —— 多出来的两处是
// 「语言」小窗与「Agent 预设」小窗（用户要求「点击后以小窗形式展开」）。
// 计数仍然是「本页所有锚定弹层都必须复用同一套参数」这条判据，只是分母变了。
check('弹层参数复用 R13-9 那套（BottomRight / 无箭头 / 透明遮罩 / 透明容器）',
  (settingsSource.match(/placement: Placement\.BottomRight/g) || []).length === 4
  && (settingsSource.match(/enableArrow: false/g) || []).length === 4
  && (settingsSource.match(/mask: \{ color: Color\.Transparent \}/g) || []).length === 4
  && (settingsSource.match(/popupColor: Color\.Transparent/g) || []).length === 4);
check('弹层宽度/圆角/间距对齐上游（MenuWidth 286 / MenuShape 18 / MenuGap 4）',
  (settingsSource.match(/width: Control\.MENU_WIDTH/g) || []).length === 4
  && (settingsSource.match(/targetSpace: DROPDOWN_GAP/g) || []).length === 4
  && /const DROPDOWN_GAP: number = 4;/.test(settingsSource));
check('选中态由 onStateChange 关闭（点外部/返回键都能收起）',
  (settingsSource.match(/isVisible\) \{\n\s*this\.(appearance|sidebar)Open = false;/g) || []).length === 0
  || settingsSource.indexOf('if (!e.isVisible)') >= 0);
check('弹层内的单选行是独立组件（图标在左，与 AaMenuActionRow 的图标在右区分开）',
  componentsSource.indexOf('export struct AaDropdownMenuItem') >= 0
  && /AaDropdownMenuItem[\s\S]{0,400}?ICONS\[this\.iconName\][\s\S]{0,400}?Text\(this\.label\)/.test(componentsSource));


// ---------------------------------------------------------------------------
// R22：账号子页的结构（上游 `AccountDetailPage`）
// ---------------------------------------------------------------------------
// 上游是「头像 + 资料卡（3 行）→ 动作卡（3 个动作行 + 行间分隔线）→ 退出登录卡」，
// 点击动作行打开 Dialog。本工程此前把三项做成了**常驻的内联表单**（三个输入区一直摊在页面上），
// 开发期并排图上一眼可见结构不同。
// 现在：静态结构 = 上游的三个动作行；点击 → 动作卡**下方内联展开**对应表单
//（避开弹层不吃键盘避让的问题，见 EXPERIENCE §29）。
const iconSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Icon.ets'), 'utf8');

group('R22：账号子页 = 动作卡 + 点开内联表单 + 退出登录卡');
check('三个动作行的常量在',
  settingsSource.indexOf("const FORM_NICKNAME: string = 'nickname';") >= 0
  && settingsSource.indexOf("const FORM_EMAIL: string = 'email';") >= 0
  && settingsSource.indexOf("const FORM_PASSWORD: string = 'password';") >= 0);
check('展开态是一个 @State（否则点了不刷新）',
  /@State accountForm: string = '';/.test(settingsSource));
check('动作卡按上游顺序排三个动作行（修改昵称 / 绑定或修改邮箱 / 修改密码）',
  /accountActionRow\(FORM_NICKNAME, 'user-round-arrow-left', '修改昵称'\)[\s\S]{0,260}?accountActionRow\(FORM_EMAIL, 'mail-check', '绑定或修改邮箱'\)[\s\S]{0,260}?accountActionRow\(FORM_PASSWORD, 'key-round', '修改密码'\)/.test(settingsSource));
check('动作行之间画分隔线（上游 ProfileDivider）',
  (settingsSource.match(/Divider\(\)\.color\(borderColor\(\)\)\.strokeWidth\(1\)\.margin\(\{ left: DIVIDER_START \}\)/g) || []).length >= 2);
check('表单是**条件渲染**的（不再是常驻卡片）',
  /if \(this\.accountForm === FORM_NICKNAME\) \{[\s\S]{0,200}?this\.nicknameForm\(\)/.test(settingsSource)
  && /else if \(this\.accountForm === FORM_EMAIL\) \{[\s\S]{0,200}?this\.emailForm\(\)/.test(settingsSource)
  && /else if \(this\.accountForm === FORM_PASSWORD\) \{[\s\S]{0,200}?this\.passwordForm\(\)/.test(settingsSource));
check('旧的常驻卡片名已不存在（nicknameCard / emailCard / passwordCard）',
  settingsSource.indexOf('nicknameCard') < 0
  && settingsSource.indexOf('emailCard') < 0
  && settingsSource.indexOf('passwordCard') < 0);
check('账号子页底部有退出登录卡（上游 AccountDetailPage 的最后一张 ProfileCard）',
  /accountForm === FORM_PASSWORD\) \{[\s\S]{0,240}?this\.signOutCard\(\)/.test(settingsSource));
check('动作行可再次点击收起（同一套心智，与设备详情的「配置/收起配置」一致）',
  settingsSource.indexOf("this.accountForm = this.accountForm === form ? '' : form;") >= 0);
check('图标取自上游：user-round-arrow-left 已登记进 ICONS',
  iconSource.indexOf("'user-round-arrow-left'") >= 0);
// R29：语言子页的三行 = 上游 `LanguageRow`
// 上游 `ProfileSettingsDetails.kt:192-219`：`height(56.dp)` + `padding(start/end 16.dp)` +
//   文本 `16.sp / lineHeight 20.sp / SemiBold` + 选中时 `Icon(Lucide.Check, size(20.dp))`；
//   行间 `ProfileDivider(start = 12.dp, end = 12.dp)`（`ProfileSettingsComponents.kt:265-273`）。
// ⚠️ R29 修前：文本 15sp / Medium / 无行高（行框 17.7dp）、勾 16dp。修后实测 行框 20.0dp、勾 20.0dp、行距 56.9dp。
group('R29：语言行的字号/行高/勾 = 上游 LanguageRow');
const langSeg = settingsSource.slice(settingsSource.indexOf('languageOption(mode: string, label: string) {'),
  settingsSource.indexOf('languageOption(mode: string, label: string) {') + 900);
check('文本字号 = 16（上游 16.sp）', langSeg.includes('.fontSize(FontSize.ROW_TITLE)'));
check('文本有行高 20（上游 lineHeight = 20.sp）', langSeg.includes('.lineHeight(20)'));
check('文本 Bold（上游 SemiBold，本工程无该字重按既有约定取 Bold）', langSeg.includes('.fontWeight(FontWeight.Bold)'));
check('勾图标 20dp（上游 Icon size(20.dp)）', langSeg.includes("AaIcon({ d: ICONS['check'], iconSize: 20, color: ink() })"));
check('行高仍是 56（上游 height(56.dp)）', settingsSource.includes('const ROW_HEIGHT: number = 56;'));
check('行左右内边距 16（上游 padding(start/end 16.dp)）', langSeg.includes('.padding({ left: Space.L, right: Space.L })'));
check('行间分割线左右各缩进 12（上游 ProfileDivider start/end = 12.dp）',
  /flatDivider\(\) \{[\s\S]{0,200}?\.margin\(\{ left: Space\.M, right: Space\.M \}\)/.test(settingsSource));

// ---------------------------------------------------------------------------
// R54：设置菜单新增「Agent 预设」（用户要求）
// ---------------------------------------------------------------------------
// 背景：用户原话「顺带解决 Agent 预设问题，让设置菜单增加 Agent 预设选项」。
// 这一页的数据链与对话页**同源**（runtime 描述的 `uiSchema.defaultAgentPreset`），
// 选中项写进**同一本**「上次选择」记忆（`aaNewSessionPref`，作用域 deviceId|runtimeId），
// 所以「在设置里选的预设」与「在对话页里选的预设」是同一件事。
// 解析根因也在这里：连接器不上报目录时，靠 `POST /connectors/{id}/runtimes/discover` 让它重新上报。
group('R54 / R63：设置页「Agent 预设」（子页 → 小窗）');
check('第四个子页常量在（PAGE_AGENT_PRESET）',
  settingsSource.indexOf("const PAGE_AGENT_PRESET: string = 'agent_preset';") >= 0);
check('根页有入口卡（agentPresetCard）',
  /this\.identityCard\(\)[\s\S]{0,200}?this\.agentPresetCard\(\)/.test(settingsSource));
check('入口卡的标题就是「Agent 预设」', settingsSource.indexOf("Text('Agent 预设')") >= 0);
check('子页标题分支保留（R63 只是入口改小窗，常量与渲染分支不删 —— SPEC §4）',
  /if \(this\.page === PAGE_AGENT_PRESET\) \{\s*return 'Agent 预设';/.test(settingsSource));
// ---------------------------------------------------------------------------
// R63（用户原话「将设置中的语言功能栏和 agent 预设功能栏改为点击后以小窗形式展开」）：
// 两张入口卡**不再整页切子页**，改为在当前页用 `bindPopup` 弹出**小窗**（浮层小卡片）。
// 断言按实际实现更新：入口点击开小窗 / 小窗 builder 与参数存在 / `loadPresets()` 仍被调用 /
// 点小窗外的遮罩可关（autoCancel + onStateChange 回落）/ 预设小窗可滚动 / 玻璃令牌 / 返回键不退化。
// ---------------------------------------------------------------------------
// ⚠️ **R94 演进**：原文断言「开窗 + `this.loadPresets()`」。R94 用户要求删掉手动「刷新目录」行、
// 改成**每次打开弹窗自动刷新** ⇒ 入口改调 `autoRefreshPresets()`（内部 `store.autoRefresh()`：
// 先 `load()` 拿设备列表、再逐台在线设备重新发现）。断言随之演进为守新语义，
// 并**额外**要求「旧的手动刷新入口确实没了」—— 否则等于把用户要求删的东西又放回来。
check('R94 点卡片开**小窗**并**自动刷新目录**（不再 openSubPage、不再手动刷新行）',
  /this\.agentPresetOpen = true;\s*\n\s*this\.autoRefreshPresets\(\);/.test(settingsSource));
// ⚠️ **R92-T5 演进**：本条原先还有 `&& settingsSource.indexOf('this.openSubPage(PAGE_LANGUAGE)') < 0` 一半。
// T5 把 `PAGE_LANGUAGE` 常量连同整套死代码删掉之后，那半条**恒真**了（标识符不存在 ⇒ 该串永远匹配不到），
// 留着只会让人以为「这里还在防着语言入口退回整页子页」。判据本身没丢 —— 由 R92-T5 那组
// 「`PAGE_LANGUAGE` 已从代码里消失」接管，且那条带 6 次变异自检、比字符串比对更强。
check('R63 预设入口不再整页切子页（PAGE_AGENT_PRESET 不再被 openSubPage 进入）',
  settingsSource.indexOf('this.openSubPage(PAGE_AGENT_PRESET)') < 0);
check('R63 语言入口点开的也是小窗（@State 开关 + 小窗参数 + 入口卡挂 bindPopup）',
  /@State languageOpen: boolean = false;/.test(settingsSource)
  && /this\.languageOpen = true;/.test(settingsSource)
  && settingsSource.indexOf('.bindPopup(this.languageOpen, this.languagePopupOptions())') >= 0);
check('R63 预设入口卡挂着预设小窗',
  settingsSource.indexOf('.bindPopup(this.agentPresetOpen, this.agentPresetPopupOptions())') >= 0);
check('R63 两个小窗内容 builder 存在（语言三选一 / 预设沿用 agentPresetPage）',
  settingsSource.indexOf('languageWindow() {') >= 0
  && settingsSource.indexOf('agentPresetWindow() {') >= 0
  && settingsSource.indexOf('this.languageRows()') >= 0
  && settingsSource.indexOf('this.agentPresetPage()') >= 0);
check('R63 点小窗外的遮罩可关（两个小窗的 onStateChange 都把开关回落）',
  /onStateChange: \(e: AaPopupStateChange\) => \{\s*\n\s*if \(!e\.isVisible\) \{\s*\n\s*this\.languageOpen = false;/.test(settingsSource)
  && /onStateChange: \(e: AaPopupStateChange\) => \{\s*\n\s*if \(!e\.isVisible\) \{\s*\n\s*this\.agentPresetOpen = false;/.test(settingsSource));
check('R63 返回键先关小窗（不退化：小窗开着按返回只关窗，不退出设置页）',
  /if \(this\.languageOpen\) \{\s*this\.languageOpen = false;\s*return true;\s*\}/.test(settingsSource)
  && /if \(this\.agentPresetOpen\) \{\s*this\.agentPresetOpen = false;\s*return true;\s*\}/.test(settingsSource));
check('R63 语言小窗点选后关闭（pickLanguage 里收窗）',
  /private pickLanguage\(mode: string\): void \{[\s\S]*?this\.languageOpen = false;[\s\S]*?\n  \}/.test(settingsSource));
check('R63 预设小窗限高 + 可滚动（限高容器里必须有 Scroll —— EXPERIENCE §62.3）',
  /agentPresetWindow\(\) \{[\s\S]{0,200}?Scroll\(\) \{[\s\S]{0,400}?constraintSize\(\{ maxHeight: Control\.MENU_MAX_HEIGHT \}\)/.test(settingsSource));
// ⚠️ R86 口径更新（Lead 改）：小窗的「底」改由官方沉浸材质接管
//（`languagePopupOptions()` / `agentPresetPopupOptions()` 的 `systemMaterial: dialogMaterial()`，
// 官方依据：`CustomPopupOptions.systemMaterial`，SDK `common.d.ts:14406`；生效范围见 ``）。
// 内容根的自绘玻璃**不删净**，而是按 `immersiveMaterialEnabled()` **门控**保留：
//   材质可用 ⇒ 零自绘层（材质接管 background/border/blur/shadow）；
//   材质不可用 ⇒ 逐字回到 R86 前的自绘玻璃（这几个弹层的容器本身是全透明的
//   —— `popupColor: Color.Transparent` —— 删净回退层会让面板变全透明 = 功能缺陷）。
// ⇒ 断言从「字面量必须长这样」改成「**回退路径仍在 + 门控存在**」：
//   删掉回退玻璃、或把门控拆成无条件 `Color.Transparent` 都会翻红。
check('R63/R86 小窗的玻璃回退令牌仍在，且由 immersiveMaterialEnabled() 门控',
  settingsSource.indexOf('glassPanelSurface()') >= 0
  && settingsSource.indexOf('radius: GLASS_PANEL_BLUR,') >= 0
  && settingsSource.indexOf('color: appShadow()') >= 0
  && /\?\s*Color\.Transparent\s*:\s*glassPanelSurface\(\)/.test(settingsSource)
  && settingsSource.indexOf('immersiveMaterialEnabled()') >= 0);
check('build 的页面开关里仍能渲染该子页（SPEC §4：保留渲染分支）',
  /else if \(this\.page === PAGE_AGENT_PRESET\) \{\s*this\.agentPresetPage\(\)/.test(settingsSource));
// ---------------------------------------------------------------------------
// R63-F1（真机定点修复）：预设小窗「刷新目录」被挤到小窗底缘 ⇒ 点它就关窗。
// 真机原始证据（开发期验证记录，不随仓库分发）：
//   · 小窗内滚动容器 Scroll [412,1411][1263,2387]（clip=true）
//   · 卡尾「刷新目录」行 Row [451,2323][1224,2387]（行高 56vp 被切）、其 Text [578,2382][1177,2387]（**只剩 5px**，贴窗底 2387）
//   · 同帧其它完整可见的选项行高 143px（如 [451,1749][1224,1892]）⇒ 卡尾那行确系被 clip 切掉
// 三条修法（下面逐条钉住）：① 刷新行上移到卡头之下、选项之前；② 滚动容器消费窗内点击（只剩窗外遮罩能关窗）；
// ③ 滚动容器底部留内边距（滚到底时最后一行不贴窗底）。
// ---------------------------------------------------------------------------
const cardAt = settingsSource.indexOf('agentPresetDeviceCard(row: AgentPresetRow) {');
const cardBody = cardAt < 0 ? '' : settingsSource.slice(cardAt, settingsSource.indexOf('@Builder', cardAt + 20));
check('R63-F1 能定位设备卡 builder（顺序断言的作用域）', cardBody.length > 0);
const refreshAt = cardBody.indexOf('this.presetRefreshRow(row)');
const optionsAt = cardBody.indexOf('ForEach(row.options');
const emptyAt = cardBody.indexOf('这个连接器没有上报');
// ⚠️ **R94 演进（整条删除手动刷新行）**：原文三条断言守的是「刷新行摆在哪（卡头之下、只出现一次）」
// 与「空态文案说『点上面的』」。R94 用户要求**把这一行整行删掉**、改成开窗自动刷新 ⇒
// 「摆位」这个命题**不再有对象**，三条断言随之退役；替换为**等价强度、且针对新形态**的两条：
//   ① **手动刷新入口确实消失了**（`presetRefreshRow` / `'刷新目录'` 都不在）—— 这是用户要求本身；
//   ② **能力没丢**：改由 `store.autoRefresh()` 承担（先 load 再逐台重新发现），
//      且开窗入口确实调它（上一条断言已钉，这里再钉 store 侧的实现存在）。
// ⚠️ 特别说明：**没有**把它改成「refreshAt 不再存在」这种恒真判据（原断言是 `refreshAt >= 0 && ...`，
//    删行后第一项就假 ⇒ 若只删后半段会变成「只要前面为假就通过」的反向恒真，那才是真隐患）。
check('R94 手动「刷新目录」行已整行删除（用户要求：改为自动刷新）',
  refreshAt < 0 && settingsSource.indexOf("'刷新目录'") < 0
  && settingsSource.indexOf('this.presetRefreshRow(') < 0);
check('R94 能力没丢：自动刷新走 store.autoRefresh（先 load 再逐台重新发现）',
  settingsSource.indexOf('this.autoRefreshPresets()') >= 0
  && settingsSource.indexOf('AgentPresetStore.get().autoRefresh()') >= 0);
const winAt = settingsSource.indexOf('agentPresetWindow() {');
const winBody = winAt < 0 ? '' : settingsSource.slice(winAt, settingsSource.indexOf('private agentPresetPopupOptions', winAt));
/** ⚠️ 注释里正好提到 hitTestBehavior（说明为什么不能用 Block）⇒ 先去掉整行注释再查代码。 */
const winCode = winBody.split('\n').filter((line) => !/^\s*(\/\/|\*|\/\*)/.test(line)).join('\n');
check('R63-F1 小窗内容根节点消费窗内点击（空 onClick ⇒ 只有点窗外遮罩才关窗）',
  /\.onClick\(\(\) => \{\s*\n\s*\/\//.test(winBody)
  && winCode.indexOf('hitTestBehavior') < 0,
  '（不能用 HitTestMode.Block 代替 —— 那个连子节点一起挡）');
check('R63-F1 滚动容器底部留内边距（滚到底时最后一行不贴窗底）',
  winBody.indexOf('.padding({ left: Space.M, right: Space.M, top: Space.M, bottom: Space.L })') >= 0);
// ⚠️ **R94 演进**：原文守的是「刷新行里读 `presetRefreshingDeviceId` + 转圈」。
// 刷新行删掉后，过程态改由**小窗内容**承担（`presetLoading` 那条分支：转圈 + 「正在刷新 Agent 预设…」），
// 断言随之改成守**新的过程态承载处** —— 否则「转圈提示」这件事就没有任何护栏了。
check('R94 过程态仍有承载（开窗自动刷新期间显示转圈）',
  /if \(this\.presetLoading\) \{[\s\S]{0,220}?LoadingProgress\(\)/.test(settingsSource));
check('R94 `presetRefreshingDeviceId` 仍被消费（「同一台设备只允许一个在跑」的闸还在）',
  settingsSource.indexOf('this.presetRefreshingDeviceId') >= 0);
check('选项行复用 AaConfigMenuItem（与运行时面板同一形态）',
  settingsSource.indexOf('AaConfigMenuItem({') >= 0 && settingsSource.indexOf('AaChip({ label: \'上次使用\' })') >= 0);
// ⚠️ **R94 演进**：原文「『刷新目录』行在（连接器没上报时的自救路径）」。
// 用户要求把这行删掉 ⇒ 判据改为守**两件更要紧的事**：
//   ① 自救能力仍在（自动刷新会重新发现，见 `AgentPresetStore.autoRefresh` 的两步）；
//   ② **失败必须提示**（用户原话「若失败则提示」）—— 失败要落到 `presetError`，
//      而弹窗顶部那条 `AaErrorBanner` 正是读它（判据一并钉住这条链的末端）。
check('store 监听器按身份注销（不留悬空回调）',
  /AgentPresetStore\.get\(\)\.onChange\(this\.presetListener\)/.test(settingsSource)
  && /AgentPresetStore\.get\(\)\.offChange\(this\.presetListener\)/.test(settingsSource));
const presetStoreSource = fs.readFileSync(path.join(SRC_ETS, 'feature', 'AgentPresetStore.ets'), 'utf8');
// ⚠️ `presetStoreSource` 的声明在下面（原 R54 那段）⇒ 这两条 R94 判据必须放在**它之后**，
//    否则 `const` 的 TDZ 会让整个套件直接抛 ReferenceError（本轮踩过）。
check('R94 自救能力仍在（autoRefresh 有「先 load 再逐台 refreshDevice」两步）',
  /async autoRefresh\(\): Promise<void> \{[\s\S]{0,700}?await this\.load\(\)[\s\S]{0,1400}?await this\.refreshDevice\(/.test(presetStoreSource));
// ⚠️ R94 真机实测抓到的缺陷：第一版在「没有任何在线设备」时**直接 return**、一句提示都不给，
// 而连接器停掉后设备正好变「设备离线」⇒ 用户开窗看到旧列表却不知道这次没刷新成功。
// 用户原话是「若失败则提示」⇒ **离线必须也算失败**。下面两条把这条口径钉住。
check('R94 离线设备也算自动刷新失败（不再静默 return）',
  presetStoreSource.indexOf('offline.push(row.deviceId)') >= 0
  && presetStoreSource.indexOf('失败（') >= 0);
check('R94 离线失败有人话兜底（不拼出空尾巴的「失败（LYW）：」）',
  presetStoreSource.indexOf('设备离线，请确认 DSH 与连接器正在运行。') >= 0);
check('R94 失败有提示（autoRefresh 写 error ⇒ 弹窗顶部错误横幅读 presetError）',
  presetStoreSource.indexOf('自动刷新预设目录失败') >= 0
  && /message: this\.presetError/.test(settingsSource));
// ⚠️ DevicesApi 里那个路径是模板字符串（`/connectors/${urlEncode(deviceId)}/runtimes/discover`），
// 所以按**特征片段**查，而不是按拼接写法查（第一版就是这么假红的）。
const devicesApiSource = fs.readFileSync(path.join(SRC_ETS, 'api', 'DevicesApi.ets'), 'utf8');
const discoverFnBody = (devicesApiSource.match(/async discoverDeviceRuntimes\([\s\S]*?\n  \}/) || [''])[0];
check('DevicesApi 的发现端点是 POST .../runtimes/discover（上游 Android DevicesApi.kt:112 同款）',
  discoverFnBody.indexOf('/runtimes/discover') >= 0 && discoverFnBody.indexOf('postJson') >= 0);
check('store 调的就是它（而不是自己拼 HTTP）',
  presetStoreSource.indexOf('discoverDeviceRuntimes') >= 0
  && presetStoreSource.indexOf('postJson') < 0);
check('store 只认 DSH（预设是 DSH 专有能力）', presetStoreSource.indexOf("runtime.runtimeType !== 'dsh'") >= 0);
check('选中项写进「上次选择」记忆（与对话页同一本，readNewSessionSelection 先读后写）',
  presetStoreSource.indexOf('readNewSessionSelection') >= 0
  && presetStoreSource.indexOf('writeNewSessionSelection') >= 0);
check('先读后写：改预设不能把模型/权限选择冲掉（四项一起带上）',
  /modelId: base\.modelId,[\s\S]{0,120}?agentPresetId: value/.test(presetStoreSource));

// ---------------------------------------------------------------------------
// R92-T5（P2 收口）：两个真缺陷的**回归护栏**
//
// 来源：R92-T3 的越界发现，Lead 复核确认为真问题后开的 T5。
//  ① `ArchivedSessionsScreen` 的 `restoreSession()/restoreProject()` 里 `if (!this.alive) { return; }`
//     卡在状态清理**之前** ⇒ await 期间页面被销毁则 `mutating` 永久为 true ⇒ 筛选器永久灰掉且不可点；
//  ② `SettingsScreen` 的 `PAGE_LANGUAGE` 整套（常量 / build 分发 / `languagePage()` / `titleText` 分支）
//     自 R63 起不可达 ⇒ 删除。
//
// ⚠️ 这两条都**必须**带变异自检：本工程已有**四次**「注释被当代码」的假红/假绿先例
//    （suite-settings:754-759 记着其中一次），而本组要判的恰好是「某段代码长什么样」。
// ---------------------------------------------------------------------------

/**
 * 去掉 `//` 行注释、`/* *\/` 块注释与字符串字面量，只留**可执行代码**。
 *
 * ⚠️ 为什么必须有它：本组要断言「`PAGE_LANGUAGE` 已从代码里消失」「`await` 与 `finally` 之间没有 `return`」——
 * 而**解释性注释里必然会写出这些标识符**（R92-T5 自己就在 §1 的注释里逐字引用了删掉的那段代码）。
 * 裸扫全文的话，注释会把死代码「复活」成命中 ⇒ 断言恒假；反过来也会让判据在真退回时仍然绿。
 * 本文件 1199 行那处 `filter` 只能滤掉**整行**注释，滤不掉「代码后面跟 `// …`」与块注释，故这里做完整版。
 */
function stripComments(source) {
  let out = '';
  let state = 'code';
  let quote = '';
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    const d = i + 1 < source.length ? source[i + 1] : '';
    if (state === 'code') {
      if (c === '/' && d === '/') { state = 'line'; i += 1; continue; }
      if (c === '/' && d === '*') { state = 'block'; i += 1; continue; }
      if (c === "'" || c === '"' || c === '`') { state = 'string'; quote = c; out += c; continue; }
      out += c;
      continue;
    }
    if (state === 'line') {
      if (c === '\n') { state = 'code'; out += '\n'; }
      continue;
    }
    if (state === 'block') {
      if (c === '*' && d === '/') { state = 'code'; i += 1; continue; }
      if (c === '\n') { out += '\n'; }
      continue;
    }
    // state === 'string'：保留字面量（含转义），只记住进出
    if (c === '\\') { out += c + d; i += 1; continue; }
    if (c === quote) { state = 'code'; }
    out += c;
  }
  return out;
}

/**
 * 取「以 `signature` 开头、花括号配平」的那一段方法体（含最外层大括号）。
 * 作用在**已剥注释**的源码上，避免注释里的 `{}` 把配平算错。
 */
function methodBodyOf(source, signature) {
  const at = source.indexOf(signature);
  if (at < 0) { return ''; }
  const open = source.indexOf('{', at + signature.length - 1);
  if (open < 0) { return ''; }
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') { depth += 1; } else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) { return source.slice(open, i + 1); }
    }
  }
  return '';
}

/** 取方法体里 `finally` 那一块（含大括号）；没有 finally 返回空串。 */
function finallyBlockOf(body) {
  const at = body.indexOf('finally');
  if (at < 0) { return ''; }
  const open = body.indexOf('{', at);
  if (open < 0) { return ''; }
  let depth = 0;
  for (let i = open; i < body.length; i++) {
    if (body[i] === '{') { depth += 1; } else if (body[i] === '}') {
      depth -= 1;
      if (depth === 0) { return body.slice(open, i + 1); }
    }
  }
  return '';
}

/**
 * 核心不变式：`mutating` 的复位是**无条件**的。
 *
 * 三条同时成立才算过：
 *  ① 存在 `finally` 块，且块内 `this.mutating = false;`；
 *  ② 顺序是 try → await → finally（await 真被 try 包住）；
 *  ③ **`await` 与 `finally` 之间没有任何 `return`** —— 这正是原缺陷的形态
 *     （`await …; if (!this.alive) { return; } …`），换个写法（比如把清理挪出 finally）必须同样被抓。
 */
function cleanupIsUnconditional(body) {
  const fin = finallyBlockOf(body);
  if (fin.length === 0 || fin.indexOf('this.mutating = false;') < 0) { return false; }
  const tryAt = body.indexOf('try');
  const awaitAt = body.indexOf('await');
  const finAt = body.indexOf('finally');
  if (tryAt < 0 || awaitAt < 0 || finAt < 0) { return false; }
  if (!(tryAt < awaitAt && awaitAt < finAt)) { return false; }
  return body.slice(awaitAt, finAt).indexOf('return') < 0;
}

const archivedScreenSource = fs.readFileSync(
  path.join(SRC_ETS, 'ui', 'screens', 'ArchivedSessionsScreen.ets'), 'utf8');
const archivedCode = stripComments(archivedScreenSource);
const settingsCode = stripComments(settingsSource);
const RESTORE_SESSION_SIG = 'private async restoreSession(';
const RESTORE_PROJECT_SIG = 'private async restoreProject(';

// 前置：剥注释后确实还能取到这两个方法（否则下面的断言会靠「找不到」而假绿）
check('R92-T5 能定位 restoreSession / restoreProject 的方法体（剥注释后）',
  methodBodyOf(archivedCode, RESTORE_SESSION_SIG).length > 80
  && methodBodyOf(archivedCode, RESTORE_PROJECT_SIG).length > 80);

check('R92-T5 restoreSession 的 mutating 复位是无条件的（try/finally + await 与 finally 之间无 return）',
  cleanupIsUnconditional(methodBodyOf(archivedCode, RESTORE_SESSION_SIG)),
  '改前形态：`await …; if (!this.alive) { return; } this.mutating = false;` ⇒ 提前 return 时永久卡死');
check('R92-T5 restoreProject 的 mutating 复位同样无条件（两处必须成对，只改一处等于没修）',
  cleanupIsUnconditional(methodBodyOf(archivedCode, RESTORE_PROJECT_SIG)));

// 死代码删除的正向判据：**在剥注释后的代码里**，这两个标识符必须彻底消失。
check('R92-T5 PAGE_LANGUAGE 常量/分支已从代码里删除（注释里的提及不算）',
  settingsCode.indexOf('PAGE_LANGUAGE') < 0,
  '代码里仍在：' + (settingsCode.match(/.*PAGE_LANGUAGE.*/g) || []).slice(0, 3).join(' / '));
check('R92-T5 languagePage() 已删除（语言小窗走的是 languageRows()）',
  settingsCode.indexOf('languagePage') < 0);
// ⚠️ 反向护栏：删的时候**不能**连累这两个 —— 它们是活的。
check('R92-T5 删对了东西：PAGE_AGENT_PRESET 与 agentPresetPage() 仍在（预设小窗复用后者）',
  settingsCode.indexOf('PAGE_AGENT_PRESET') >= 0
  && settingsCode.indexOf('this.agentPresetPage()') >= 0);
check('R92-T5 删对了东西：languageRows() 仍在（语言小窗的三个选项就是它）',
  settingsCode.indexOf('this.languageRows()') >= 0);

/**
 * 鉴别力自检：6 次内存变异，每一次都必须让上面**至少一条**断言失效。
 * （只做「改动生效」不够 —— 必须验证判据真的红了，否则等于没有护栏。）
 */
function spliceMethodBody(source, signature, newBody) {
  const at = source.indexOf(signature);
  if (at < 0) { return source; }
  const open = source.indexOf('{', at + signature.length - 1);
  if (open < 0) { return source; }
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') { depth += 1; } else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) { return source.slice(0, open) + newBody + source.slice(i + 1); }
    }
  }
  return source;
}
const BUGGY_RESTORE_SESSION = '{ if (this.mutating) { return; } this.mutating = true;'
  + ' this.busySessionId = session.id;'
  + ' await this.store.setSessionArchived(session.id, false);'
  + ' if (!this.alive) { return; } this.mutating = false; this.busySessionId = \'\'; }';
const BUGGY_RESTORE_PROJECT = '{ if (this.mutating || group.projectId.length === 0) { return; }'
  + ' this.mutating = true; this.busyProjectId = group.projectId;'
  + ' await this.store.archiveAllForProject(group.projectId, false);'
  + ' if (!this.alive) { return; } this.mutating = false; this.busyProjectId = \'\'; }';
const CLEANUP_OUTSIDE_FINALLY = '{ if (this.mutating || !this.alive) { return; } this.mutating = true;'
  + ' this.busySessionId = session.id;'
  + ' try { await this.store.setSessionArchived(session.id, false); }'
  + ' finally { this.busySessionId = \'\'; } this.mutating = false; }';
const EMPTY_FINALLY = '{ if (this.mutating || !this.alive) { return; } this.mutating = true;'
  + ' this.busySessionId = session.id;'
  + ' try { await this.store.setSessionArchived(session.id, false); } finally { }'
  + ' this.mutating = false; }';

const T5_MUTATIONS = [
  ['变异A 还原成原始 bug（alive 守卫卡在清理之前）', 'archived',
    (s) => spliceMethodBody(s, RESTORE_SESSION_SIG, BUGGY_RESTORE_SESSION)],
  ['变异B 只还原 restoreProject（改一半 ⇒ 另一处仍是死的）', 'archived',
    (s) => spliceMethodBody(s, RESTORE_PROJECT_SIG, BUGGY_RESTORE_PROJECT)],
  ['变异C 清理被移出 finally（finally 里只剩 busy 复位）', 'archived',
    (s) => spliceMethodBody(s, RESTORE_SESSION_SIG, CLEANUP_OUTSIDE_FINALLY)],
  ['变异D finally 块为空', 'archived',
    (s) => spliceMethodBody(s, RESTORE_SESSION_SIG, EMPTY_FINALLY)],
  ['变异E 死代码回流：重新插入 PAGE_LANGUAGE 常量', 'settings',
    (s) => s.replace('const PAGE_ROOT', "const PAGE_LANGUAGE: string = 'language';\nconst PAGE_ROOT")],
  ['变异F 死代码回流：重新调用 languagePage()', 'settings',
    (s) => s.replace('this.accountPage()', 'this.accountPage(); this.languagePage()')]
];
for (const item of T5_MUTATIONS) {
  const origin = item[1] === 'archived' ? archivedScreenSource : settingsSource;
  const mutated = item[2](origin);
  const code = stripComments(mutated);
  let caught;
  if (item[1] === 'archived') {
    caught = cleanupIsUnconditional(methodBodyOf(code, RESTORE_SESSION_SIG)) === false
      || cleanupIsUnconditional(methodBodyOf(code, RESTORE_PROJECT_SIG)) === false;
  } else {
    caught = code.indexOf('PAGE_LANGUAGE') >= 0 || code.indexOf('languagePage') >= 0;
  }
  check('R92-T5「' + item[0] + '」改变生效且判据能证伪', mutated !== origin && caught);
}

// ---------------------------------------------------------------------------
// R93（用户：「设置里的预设，选择时前面用☑️，统一下 ui」＋「去掉预设的描述，只留名字」）
// ---------------------------------------------------------------------------
// ## 判据为什么写「紧口径」而不是「体内有某字符串」
// 本轮（R92）刚沉淀过一条教训：源码闸门的恒真有三种形态（距离窗口够不到 / 宽口径命中别处 /
// 变异改了自己，见 ）。所以这里：
//   · **不用** `[\s\S]{0,N}` 距离窗口 —— 只认「同一处、成对出现」的属性；
//   · 判据在**剥注释后**的源码上跑（`stripComments`）—— 本轮的注释里逐字引用了旧写法 `● `，
//     裸扫会把已删掉的字符标记「复活」成命中；
//   · 每个变异都断言 `mutated !== origin && caught`（**判据真的红了**，不是「改动生效」就算）。
group('R93：预设选项「☑️ 矢量勾 + 只留名字」的统一');
const presetRowSeg = (stripComments(settingsSource).match(/ForEach\(row\.options[\s\S]*?\}\)/) || [''])[0];
check('R93-1 设置页预设项关掉副标题（hideDetail: true）',
  presetRowSeg.indexOf('hideDetail: true') >= 0);
check('R93-2 副标题的**数据**仍传（不可用点击要靠它报原因，不能连数据一起删）',
  presetRowSeg.indexOf('detail: agentPresetDetail(option)') >= 0);
check('R93-3 不可用项点了要报原因（不是静默无反应）',
  presetRowSeg.indexOf('option.disabled') >= 0 && presetRowSeg.indexOf('presetNotice =') >= 0);
// ⚠️ `componentsSource` 在本文件 866 行已读过（同名重声明会 SyntaxError ⇒ 直接复用，别再来一遍）。
const componentsCode = stripComments(componentsSource);
const menuItemSeg = (componentsCode.match(/export struct AaConfigMenuItem[\s\S]*?\n\}/) || [''])[0];
check('R93-4 AaConfigMenuItem 有 hideDetail 开关（默认 false ⇒ 其余 8 个调用点逐字不变）',
  menuItemSeg.indexOf('@Prop hideDetail: boolean = false;') >= 0);
check('R93-5 副标题渲染受开关门控（!this.hideDetail && this.detail.length > 0）',
  menuItemSeg.indexOf('if (!this.hideDetail && this.detail.length > 0) {') >= 0);
check('R93-6 选中标记仍是既有矢量勾（☑️ 落地形态 = ICONS[check] + 未选中 18dp 等宽占位）',
  menuItemSeg.indexOf("AaIcon({ d: ICONS['check'], iconSize: 18, color: ink() })") >= 0
  && menuItemSeg.indexOf('Row().width(18).height(18)') >= 0);
const r93SessionSource = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'SessionDetailScreen.ets'), 'utf8');
const r93SessionCode = stripComments(r93SessionSource);
// ⚠️ 锚点**不能用注释里的字样**（`stripComments` 已经把注释剥掉了 ⇒ 匹配必然失败 = 恒真判据）。
// 用代码里真实出现的 `AGENT_PRESET_LABEL`：它出现 2 次，**第 2 次**才是渲染处（第 1 次是 import）。
const r93PresetIdx = r93SessionCode.indexOf('AGENT_PRESET_LABEL', r93SessionCode.indexOf('AGENT_PRESET_LABEL') + 1);
const presetSection = r93SessionCode.slice(r93PresetIdx, r93PresetIdx + 2000);
check('R93-0 预设段锚点定位成功（切片非空且含 ForEach）—— 防「定位失败 ⇒ 判据恒真」',
  r93PresetIdx > 0 && presetSection.indexOf('ForEach(this.preparedPresetOptions') >= 0);
check('R93-7 会话详情页预设段已无字符 `●` 标记（旧写法彻底清掉）',
  presetSection.indexOf("'● ") < 0);
check('R93-8 会话详情页预设段改为「占位列 + 矢量勾」形态（与模型/权限两处同款）',
  presetSection.indexOf("AaIcon({ d: ICONS['check'], iconSize: FontSize.SMALL, color: primaryAction() })") >= 0
  && presetSection.indexOf('.width(Control.ROW_LEADING)') >= 0);
check('R93-9 会话详情页预设段不再渲染副标题（去掉描述、只留名字）',
  presetSection.indexOf('agentPresetDetail(option)') < 0
  || presetSection.indexOf('Text(agentPresetDetail(option))') < 0);
check('R93-10 会话详情页预设段保留了「不可用原因」提示通道（去掉描述后不能连解释一起丢）',
  presetSection.indexOf('this.actionHint = agentPresetDetail(option)') >= 0);

// 变异自检：4 组，每组都必须「改动生效」且「判据真的红」。
const R93_MUTATIONS = [
  ['变异A 预设项恢复显示副标题（hideDetail 撤掉）', 'settings',
    (s) => s.replace('hideDetail: true,', '')],
  // ⚠️ 变异**必须打在判据看的那一处、且只能打中那一处**（这是 R92/R93 记的「变异改到了别处」形态，
  //    本轮又踩了一次，教训升级如下）：
  //    `Text(option.label)` 这个**裸串在预设段切片内就有两处** —— 预设行（`AgentPresetOption`）
  //    与权限行（`RuntimeSelectionOption`，切片尾部还在同一个 2000 字符窗里）。
  //    第一版用 `replace(...)` 只改第一处 ⇒ 切内还留着第二处 `Text(option.label)`，
  //    而变异要制造的 `'● '` 却没进去 ⇒ 判据抓不到 = 假绿。
  //    ⇒ 判据侧的锚点必须**唯一**：这里用「预设段特有的形态」`agentPresetLabel(option)` 作锚
  //      （权限/审批两处用的是裸 `option.label`，永远不会命中它）。
  ['变异B 会话详情页预设段回潮字符 `●` 标记', 'session',
    (s) => s.replace('Text(agentPresetLabel(option))', "Text('● ' + agentPresetLabel(option))")],
  ['变异C 会话详情页预设段恢复渲染副标题', 'session',
    (s) => s.replace('.layoutWeight(1)\n                }', '.layoutWeight(1)\n                }\n                if (agentPresetDetail(option).length > 0) { Text(agentPresetDetail(option)) }')],
  ['变异D AaConfigMenuItem 的副标题门控被拆掉（hideDetail 失效）', 'components',
    (s) => s.replace('if (!this.hideDetail && this.detail.length > 0) {', 'if (this.detail.length > 0) {')]
];
for (const item of R93_MUTATIONS) {
  const origin = item[1] === 'settings' ? settingsSource
    : (item[1] === 'session' ? r93SessionSource : componentsSource);
  const mutated = item[2](origin);
  const code = stripComments(mutated);
  let caught;
  if (item[1] === 'settings') {
    const seg = (code.match(/ForEach\(row\.options[\s\S]*?\}\)/) || [''])[0];
    caught = seg.indexOf('hideDetail: true') < 0;
  } else if (item[1] === 'session') {
    const k = code.indexOf('AGENT_PRESET_LABEL', code.indexOf('AGENT_PRESET_LABEL') + 1);
    const seg = k > 0 ? code.slice(k, k + 2000) : '';
    caught = seg.indexOf("'● ") >= 0 || seg.indexOf('Text(agentPresetDetail(option))') >= 0;
  } else {
    const seg = (code.match(/export struct AaConfigMenuItem[\s\S]*?\n\}/) || [''])[0];
    caught = seg.indexOf('if (!this.hideDetail && this.detail.length > 0) {') < 0;
  }
  check('R93「' + item[0] + '」改变生效且判据能证伪', mutated !== origin && caught);
}
console.log('');console.log('通过 ' + passed + ' 项，失败 ' + failures.length + ' 项');
if (failures.length > 0) {
  console.log('');
  console.log('失败明细：');
  for (const item of failures) {
    console.log('  x ' + item);
  }
  process.exit(1);
}
console.log('全部设置页逻辑断言通过。');
