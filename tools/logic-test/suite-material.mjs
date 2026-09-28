#!/usr/bin/env node
/**
 * suite-material —— 官方材质接入的**机械护栏**（T2 / task-1 新增）。
 *
 * ## 它守的是什么
 * 用户口径：「软件 UI 优化默认使用官方材质」+「优先查询官方文档再决定怎样优化」。
 * 官方文档给了两条**会导致静默失败**的硬约束（本工程已踩过 R56/R59/R61 三轮 0 像素）：
 *
 *  1. **生效范围**（，仅对 `targetSdkVersion >= 26.0.0` 生效）：
 *     其他组件**只在** `Navigation`/`NavDestination` 标题栏、或横向 `Tabs` 中
 *     `barPosition = BarPosition.End` 的底部 TabBar 中生效；**在页面正文里设置沉浸光感不生效
 *     —— 不报错、不告警**。
 *  2. **不能与自绘层共存**（SDK `@ohos.arkui.uiMaterial.d.ts:19-24`）：材质会接管
 *     `backgroundColor` / `borderColor` / `borderWidth` / `shadow`，不建议与它们同时使用。
 *
 * ⇒ 所以这里只钉两类**可机械判定**的事，不猜「好不好看」：
 *  · **生效范围内的官方分支体内零自绘层**（否则材质与自绘打架，A/B 也失去可归因性）；
 *  · **范围外不许出现 `systemMaterial(`**（挂了也只是静默无效，还会把回退层删掉变成空壳）。
 *
 * ## 输出口径
 * 与其它 `suite-*.mjs` 一致：`通过 N 项 / 失败 M 项`，全绿退出码 0。
 * 判据清单与逐点裁决见开发期验证记录（不随仓库分发）。
 *
 * ## R86 追加（mat-verify，独立验证方）：⑥ 弹窗类接入点（A4/A6/A7/A12）逐点护栏
 * 开发期契约文档把官方四类生效范围里的**弹窗类**
 * （`bindSheet` / `bindPopup` / `showAlertDialog`）整族接上官方材质。§⑥ 逐调用点钉住：
 *   · **A1** 调用点计数（4 / 16 / 2）—— 新增弹层不同轮接材质 ⇒ 红；
 *   · **A2/A3/A4** 每个调用点的 options 出现 `systemMaterial:`，且实参分别是 `panelMaterial()` / `dialogMaterial()`；
 *   · **A5** 实参**不得**是 `undefined`（官方语义 = 恢复默认材质，不是「关闭」）；
 *   · **A6** 弹层内容根的**根链**：自绘层为空 **或** 被 `immersiveMaterialEnabled()` 门控（契约 §1.9）；
 *   · **A7** 门控走同一个探针（不许直调 `isImmersiveMaterialSupported()`）；
 *   · **A8** 生效范围外（正文面板 / 自绘底栏胶囊）零 `systemMaterial(`；
 *   · **A11** 关档语义只许由 helper 内部返回 `Material.empty`，交付代码不得直写。
 * ⚠️ **A6 的判定必须是「根节点自己的属性链」**（`rootChain()`），不能扫整个 `@Builder` 体 ——
 *    后者会把 `FilesScreen#rowMenuCard` 里**图标方块**的 `.backgroundColor(subtle())` 误报成
 *    「内容根仍有自绘底」（第一版就是这么假阳性的）。也**不许**把裸 token
 *    （`backgroundColor(` / `.borderWidth(` / `.borderColor(`）当禁令：「门控 + 材质档取
 *    `Color.Transparent` / `0`」是**正确写法**，必须判绿；某处既无门控也无自绘层（4 处 `bindSheet` 内容根）
 *    则按「根链自绘层零命中即绿」判，不强行要求门控存在。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
/**
 * ⚠️ 复用 `tools/material-audit.mjs` 的解析器（**单一真源**，避免两套解析器各自漂移）：
 * `auditPopups()` 做弹窗类逐调用点解析（含 `this.xxxPopupOptions()` 两跳），`rootChain()` 取根链。
 * 该模块 import 时**零输出**（内部 `isMain` 守卫），`run-all.mjs` 把本套件当子进程跑不会有副作用。
 */
import { auditPopups, rootChain, POPUP_SELF_DRAWN } from '../material-audit.mjs';
import { projectRoot } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC = path.join(PROJECT, 'entry', 'src', 'main', 'ets');

let pass = 0;
const failures = [];
const skipped = [];
function check(name, ok, detail) {
  if (ok) { pass += 1; } else { failures.push(name + (detail ? '  [' + detail + ']' : '')); }
}
/**
 * 显式跳过：内部资产（`verify-*` 证据目录等）**不随开源仓库分发**时用它。
 * ⚠️ 只跳过「依赖该资产是否存在」的那几条判据，**不跳过**任何源码判据：
 * 资产在（作者本机）时下面的检查照旧真跑、该红还是红；详见下方 ⑤ 节。
 */
function skip(name, reason) {
  // 统一标记前缀 `⊘ SKIP：` —— `run-all.mjs` 靠它把「内部资产缺失导致的跳过」单独计数并在汇总里列出。
  skipped.push('⊘ SKIP：' + name + '（' + reason + '）');
}
function eq(name, got, want) { check(name, got === want, 'got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)); }

/** 读源码并**只保留代码行**（`//`、`*`、`/*` 开头的行剥离）—— 与工程既有 suite 同一口径。 */
function codeOf(rel) {
  const abs = path.join(SRC, rel);
  return fs.readFileSync(abs, 'utf8').split(/\r?\n/)
    .filter((l) => {
      const t = l.trim();
      return !(t.startsWith('//') || t.startsWith('*') || t.startsWith('/*'));
    }).join('\n');
}
function exists(rel) { return fs.existsSync(path.join(SRC, rel)); }

const FORBIDDEN = ['backgroundEffect(', '.shadow(', 'radialGradient(', 'linearGradient(',
  'backgroundColor(', '.borderColor(', '.borderWidth('];

// ---------------------------------------------------------------------------
// ① 标题栏（生效范围 ③）：9 个 `Navigation.title(...)` 构造器
// ---------------------------------------------------------------------------
const TITLE_BARS = [
  ['ui/screens/HomeScreen.ets', 'homeTitleBar('],
  ['ui/screens/DevicesScreen.ets', 'navTitleBar('],
  ['ui/screens/FilesScreen.ets', 'navTitleBar('],
  ['ui/screens/TerminalScreen.ets', 'navTitleBar('],
  ['ui/screens/SettingsScreen.ets', 'navTitleBar('],
  ['ui/screens/NewSessionScreen.ets', 'navTitleBar('],
  ['ui/screens/NewChatWorkspaceScreen.ets', 'navTitleBar('],
  ['ui/screens/ArchivedSessionsScreen.ets', 'navTitleBar('],
  ['ui/screens/SessionDetailScreen.ets', 'navTitleBar('],
];
/**
 * 取「某个 `@Builder` 的函数体」—— 从锚文起到**括号配平**处为止。
 * ⚠️ 不能用「到下一个 `@Builder` 为止」：那会把后续代码一起算进来（会让断言假绿）。
 */
function builderBody(code, anchor) {
  const start = code.indexOf(anchor);
  if (start < 0) { return ''; }
  const open = code.indexOf('{', start);
  if (open < 0) { return ''; }
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    const c = code[i];
    if (c === '{') { depth += 1; } else if (c === '}') {
      depth -= 1;
      if (depth === 0) { return code.slice(open, i + 1); }
    }
  }
  return '';
}
/**
 * 取 `Navigation(){ … }` **整条链**（含括号之外链上去的 `.title(…)` / `.margin(…)` 等属性）。
 *
 * 为什么单独要这个：`builderBody()` 只到闭合大括号，而 ArkUI 的组件属性都链在括号**外面**
 * ⇒ 用它判 `.title(...)` 会拿到空串、断言恒真（假绿）。本轮 R90 那条 margin 断言就这么一直假绿过。
 *
 * ⚠️ **收链必须在「链式属性」结束后立刻停**：直接截到分号会把后面**兄弟浮层的代码与注释**全吞进来
 * （实测：首页那段会圈进 `if (this.pullActive || this.refreshing)` 浮层的 `.margin(…)`
 * 与多处注释 ⇒ 假阳性，把「Refresh 不该有 margin」判成「有」）。
 * 判据：逐字符走，只接受「空白后紧跟 `.`」的片段；一旦出现换行 + 非 `.` 开头的实代码即停。
 */
function navigationChain(code) {
  const start = code.indexOf('Navigation() {');
  if (start < 0) { return ''; }
  const body = builderBody(code, 'Navigation() {');
  // ⚠️ 链的起点 = 组件体的**闭合大括号之后**，不是 `start + body.length`：
  //    `builderBody()` 返回的是 `code.slice(open, i+1)`（**从 `{` 起**），
  //    而 `start` 指向 `Navigation` 的 `N` ⇒ 两者差一个「`Navigation() `」的长度（12 字符）。
  //    用 start+len 会落进体内、下一个非空白字符是 `}` ⇒ 立刻 break，链一个字都收不到（实测）。
  const open = code.indexOf('{', start);
  let i = open + body.length;
  const parts = [body];
  while (i < code.length) {
    // 跳过空白
    let j = i;
    while (j < code.length && /\s/.test(code[j])) { j += 1; }
    if (code[j] !== '.') { break; }            // 链到此结束
    // 取一个 .attr(...) 片段（括号配平）
    let k = code.indexOf('(', j);
    if (k < 0) { break; }
    let d = 0, e = -1;
    for (let p = k; p < code.length; p += 1) {
      if (code[p] === '(') { d += 1; } else if (code[p] === ')') { d -= 1; if (d === 0) { e = p; break; } }
    }
    if (e < 0) { break; }
    parts.push(code.slice(i, e + 1));
    i = e + 1;
  }
  return parts.join('');
}

/** 从给定下标起，取第一个 `{` 到配平 `}` 的片段。 */
function bodyFrom(code, from) {
  const open = code.indexOf('{', from);
  if (open < 0) { return ''; }
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '{') { depth += 1; } else if (code[i] === '}') {
      depth -= 1;
      if (depth === 0) { return code.slice(open, i + 1); }
    }
  }
  return '';
}
/**
 * 取 `@Builder name(...) {...}` 的函数体。
 * ⚠️ 必须先定位 **`@Builder` 标记之后再出现的 `name(`** —— 直接 `indexOf(name + '(')`
 *    会命中注释里的说明或同名调用点，取到一段不相干的代码（第一版就是这么假绿的）。
 */
function builderByName(code, rawName) {
  // ⚠️ 调用方传进来的名字可能带尾部 `(`（如 `'navTitleBar('`）—— 必须剥掉再拼正则，
  //    否则 `(` 会被当成正则分组符 ⇒ `Unterminated group`（第一版就踩了）。
  const name = rawName.replace(/\($/, '');
  // 同时覆盖 `@Builder\n  name() {` 与 `private name(): T {` 两种声明形态
  // （Index.ets 的 `floatingBarStyle()` 是**普通私有方法**，不是 @Builder —— 只认 @Builder 会取不到）。
  const re = new RegExp('(?:\\n|^)[ \\t]*(?:@Builder[ \\t]*\\n[ \\t]*)?(?:export[ \\t]+)?(?:private[ \\t]+|public[ \\t]+|protected[ \\t]+)?' + name + '[ \\t]*\\(');
  const m = re.exec(code);
  if (!m) { return ''; }
  return bodyFrom(code, m.index + m[0].length);
}

for (const [file, builder] of TITLE_BARS) {
  check('标题栏文件存在：' + file, exists(file));
  const code = codeOf(file);
  const body = builderByName(code, builder);
  check('取到 ' + file + '#' + builder + ' 的函数体', body.length > 40, 'len=' + body.length);
  // ## R87 口径（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）
  // **全部 10 个标题栏的栏本体一律零材质、零自绘层** —— 与 `HomeScreen` 在 R61/R62 得出的结论统一。
  // 真机深色实测（Mate70 Pro+ / 7.0.0.109）：挂材质的栏本体会画出比正文亮约 **+19** 的一整条「带」
  // （栏底色 28.7 vs 正文 9.67，左右边缘纯底色采样；读数
  // 开发期验证记录），而首页（栏本体零材质）**+0.00** ⇒ 分界肉眼可见。
  // ⚠️ 历史（不要抹掉）：本套件 R84~R86 钉的是「栏本体**恰好一处**官方材质调用」（R66 口径），
  //    R87 因观感投诉**翻转**为「零材质」。同源坑 
  //    （官方材质会画出带缘高光的「带」，相邻两块各挂一层就是肉眼可见的分界）。
  check(file + '#' + builder + ' 栏本体零自绘层（R87）',
    FORBIDDEN.filter((t) => body.indexOf(t) >= 0).length === 0,
    '违规：' + FORBIDDEN.filter((t) => body.indexOf(t) >= 0).join(' | '));
  /**
   * 「栏本体」= **根节点自己的属性链**（`rootChain()`）—— 与 §⑥ A6 判弹层内容根是同一个口径。
   *
   * ⚠️ **R87-E 修正（独立验证方的变异测试实测出来的洞，别改回链尾写法）**：
   *    Lead 的第一版判据取 `body.slice(body.indexOf('alignItems(VerticalAlign.Center)'))` 之后的**链尾**。
   *    ArkUI 的属性顺序**不影响语义**，所以把 `.systemMaterial(...)` 写在
   *    `alignItems(VerticalAlign.Center)` **之前**时，链尾判据**抓不到**（变异 M1b 实测：套件仍 279/0 全绿）。
   *    改成根链口径后：材质写在链上任何位置都会被抓到；而**栏内嵌套控件**（设备选择条 / 「粘贴」钮，
   *    它们长在 children `{}` 块里 ⇒ 不属于根链）**依然不会误伤** —— 两头都保住了。
   */
  const barChain = rootChain(body);
  check(file + '#' + builder + ' 栏本体（根节点自身属性链）未挂整行官方材质（R87：挂回去就会重现分界线）',
    barChain.indexOf('.systemMaterial(') < 0,
    '根链出现 .systemMaterial( ⇒ 分界线会回来；根链前 120 字符=' + barChain.slice(0, 120));
  check(file + '#' + builder + ' 栏本体根链可解析（否则上面的判据会靠「空链」假绿）',
    barChain.length > 0 || body.indexOf('this.') >= 0,
    '根链为空且函数体不是转发调用 ⇒ 需人工确认 rootChain 口径是否仍适用');
}
/**
 * ## 「光效只收回到栏内控件上」怎么钉（R87-E 重写）
 *
 * ⚠️ Lead 的第一版是 `code.indexOf('officialMaterial') >= 0 || code.indexOf('officialBarMaterial(') >= 0`：
 *    · **对 FilesScreen / TerminalScreen 恒真**（这两个文件的栏内胶囊用 `officialBarMaterial(`）——
 *      把该页**全部** `officialMaterial: true` 删掉也照样绿（变异 M2 实测：套件仍 279/0）；
 *    · 且它是「存在性」判据：删掉 9 个控件里的任意 1 个都抓不到（变异 M2b）。
 * ⇒ 改成**逐文件钉死处数**：每个文件里 `officialMaterial: true` 与 `officialBarMaterial(` 的处数必须等于下表。
 *    将来新增/移除栏内控件时**必须同步改这张表**（这是刻意的：改数量要过验证方这一关）。
 * 处数来源：R87 冻结源码实测（`tools/material-audit.mjs` 同口径的剥注释代码行）。
 */
const IN_BAR_MATERIAL = [
  // 文件 | officialMaterial: true 处数 | officialBarMaterial( 处数（栏内胶囊走这条路）
  ['ui/screens/HomeScreen.ets', 2, 0],
  ['ui/screens/DevicesScreen.ets', 1, 0],
  ['ui/screens/FilesScreen.ets', 1, 1],
  ['ui/screens/TerminalScreen.ets', 2, 1],
  ['ui/screens/SettingsScreen.ets', 1, 0],
  ['ui/screens/NewSessionScreen.ets', 1, 0],
  ['ui/screens/NewChatWorkspaceScreen.ets', 1, 0],
  ['ui/screens/ArchivedSessionsScreen.ets', 1, 0],
  ['ui/screens/SessionDetailScreen.ets', 2, 0],
];
for (const [file, wantFlag, wantBar] of IN_BAR_MATERIAL) {
  const c = codeOf(file);
  const gotFlag = (c.match(/officialMaterial:\s*true/g) || []).length;
  const gotBar = (c.match(/officialBarMaterial\(/g) || []).length;
  eq(file + ' 栏内控件的 officialMaterial: true 处数（R87：光效只收回到控件，不许整页取消）', gotFlag, wantFlag);
  eq(file + ' 栏内胶囊的 officialBarMaterial( 处数（R87：栏本体撤回后，胶囊是唯一的整行材质来源）', gotBar, wantBar);
}

// ---------------------------------------------------------------------------
// ①b R87：R86 才迁入 `Navigation.title(...)` 的**两个**栏（`AddDeviceScreen#topBar()` /
//     `DeviceDetailScreen#topBar()`）—— 用户投诉的「标题栏有明显分界线」同样覆盖它们，单独钉住。
//     它们不在 `TITLE_BARS`（那张表是 R84 起的 9 个既有页），所以这里补一段，别让它们成为护栏盲区。
// ---------------------------------------------------------------------------
const R86_MIGRATED_BARS = [
  ['ui/screens/AddDeviceScreen.ets', 'topBar('],
  ['ui/screens/DeviceDetailScreen.ets', 'topBar('],
];
for (const [file, builder] of R86_MIGRATED_BARS) {
  const code = codeOf(file);
  const body = builderByName(code, builder);
  check('R87-①b 取到 ' + file + '#' + builder + ' 的函数体', body.length > 40, 'len=' + body.length);
  const chain = rootChain(body);
  check('R87-①b ' + file + '#' + builder + ' 栏本体（根链）零官方材质',
    chain.indexOf('.systemMaterial(') < 0,
    '根链出现 .systemMaterial(；根链前 120 字符=' + chain.slice(0, 120));
  check('R87-①b ' + file + '#' + builder + ' 栏本体根链可解析',
    chain.length > 0 || body.indexOf('this.') >= 0, 'rootChain 返回空');
}
// 这两个文件的栏内控件同样要留住（处数见下表；来源：R87 冻结源码实测）。
for (const [file, wantFlag] of [['ui/screens/AddDeviceScreen.ets', 2], ['ui/screens/DeviceDetailScreen.ets', 2]]) {
  eq('R87-①b ' + file + ' 栏内控件的 officialMaterial: true 处数',
    (codeOf(file).match(/officialMaterial:\s*true/g) || []).length, wantFlag);
}

// ---------------------------------------------------------------------------
// ② 底栏（生效范围 ④）：Tabs 底部 TabBar + 不叠自绘层
// ---------------------------------------------------------------------------
const IDX = codeOf('pages/Index.ets');
check('Index.ets 的 Tabs 用 barPosition = BarPosition.End（生效范围第 ④ 类）',
  IDX.indexOf('barPosition: BarPosition.End') >= 0);
check('Index.ets 的 Tabs 有 .barOverlap(true)（官方默认 blur 保留 —— R68 的教训：不许中和它）',
  IDX.indexOf('.barOverlap(true)') >= 0);
check('Index.ets 未把 bar 的模糊中和掉（不得出现 barBackgroundBlurStyle(NONE)）',
  IDX.indexOf('.barBackgroundBlurStyle(BlurStyle.NONE)') < 0);
const FLOATING = builderByName(IDX, 'floatingBarStyle');
check('取到 floatingBarStyle() 的函数体', FLOATING.length > 40, 'len=' + FLOATING.length);
check('floatingBarStyle() 里下发了 systemMaterial（底栏走官方材质）',
  FLOATING.indexOf('systemMaterial:') >= 0 && FLOATING.indexOf('bottomBarMaterial()') >= 0);
check('floatingBarStyle() 里**没有**自绘模糊（材质与自绘不共存）',
  FLOATING.indexOf('backgroundEffect(') < 0 && FLOATING.indexOf('barBackgroundEffect(') < 0);
const BN = codeOf('ui/BottomNav.ets');
check('底栏材质开关默认 true（交付路径发官方材质）',
  BN.indexOf('export const BOTTOM_TABS_OFFICIAL_MATERIAL: boolean = true;') >= 0);
check('底栏材质本体：ImmersiveMaterial(THIN) + 半透明 materialColor + interactive',
  BN.indexOf('new uiMaterial.ImmersiveMaterial({') >= 0
    && BN.indexOf('uiMaterial.ImmersiveStyle.THIN') >= 0
    && BN.indexOf('materialColor: glassNavSurface()') >= 0
    && BN.indexOf('interactive: true') >= 0);
check('材质色走带透明度的既有令牌（完全 opaque 会挡死材质滤镜，SDK uiMaterial.d.ts:341 注）',
  BN.indexOf('materialColor: glassNavSurface()') >= 0);
// 自绘胶囊此时只在 BOTTOM_BAR_VIA_TABS === false 时上树 ⇒ 它不得被挂在交付路径上。
check('自绘胶囊 AaBottomNav 只在 !BOTTOM_BAR_VIA_TABS 时上树（交付路径不叠自绘层）',
  IDX.indexOf('if (!BOTTOM_BAR_VIA_TABS && overlayBarShownOn(this.route))') >= 0);

// ---------------------------------------------------------------------------
// ③ 生效范围内零自绘层 —— 两个官方「材质 only」分支的逐一机械核验
// ---------------------------------------------------------------------------
const GI = codeOf('ui/GlassIcon.ets');
const officialGlass = builderBody(GI, 'officialGlass() {');
check('GlassIcon#officialGlass() 取到函数体', officialGlass.length > 40, 'len=' + officialGlass.length);
eq('GlassIcon#officialGlass() 零自绘层', 
  FORBIDDEN.filter((t) => officialGlass.indexOf(t) >= 0).join('|'), '');
check('GlassIcon#officialGlass() 挂的是 systemMaterial', officialGlass.indexOf('.systemMaterial(') >= 0);

const CP = codeOf('ui/Components.ets');
const officialBody = builderBody(CP, 'officialBody() {');
check('Components#AaSecondaryButton.officialBody() 取到函数体', officialBody.length > 40, 'len=' + officialBody.length);
eq('Components#AaSecondaryButton.officialBody() 零自绘层',
  FORBIDDEN.filter((t) => officialBody.indexOf(t) >= 0).join('|'), '');
const pill = builderBody(CP, 'actionPillOfficial() {');
check('Components#AaTopBar.actionPillOfficial() 取到函数体', pill.length > 40, 'len=' + pill.length);
eq('Components#AaTopBar.actionPillOfficial() 零自绘层',
  FORBIDDEN.filter((t) => pill.indexOf(t) >= 0).join('|'), '');

// ---------------------------------------------------------------------------
// ④ 范围外**不得**硬套材质（挂了静默无效，还会把回退层删掉 ⇒ 空壳）
// ---------------------------------------------------------------------------
/**
 * 正文里的玻璃面板白名单：这些 `@Builder` 是**页面正文**（不在 `Navigation` 标题栏里）⇒
 * 依官方生效范围约束必须走自绘回退，**不许**出现 `systemMaterial(`。
 * ⚠️ 例外只有 `SettingsScreen#appearanceMenu`：它是 `bindPopup` 的内容根 ——
 *    **弹窗类接口在生效范围内**，且那里挂的是默认关闭的实验开关 `probeMaterial()`。
 */
const CONTENT_PANELS = [
  ['ui/screens/SessionDetailScreen.ets', ['composerCard', 'composer', 'commandPanel', 'runtimePanel', 'scrollButton']],
];
/**
 * ## R92 契约演进：玻璃回退的**承载 builder 可以不是同名 builder**（登记表）
 *
 * ### 为什么改
 * R92 用户要求「将对话框和下方文字的模糊**融合**，即从**对话框上边缘往下统一模糊**」
 * （原话，见开发期验证记录）。改前是**两块各管一段**的玻璃：
 * `composerCard` 自己一块（只覆盖圆角 22 的内侧）+ 它下方那条底部带 —— 卡片左右 `Space.L`
 * 的圆角外侧与两块之间都露着时间线正文，就是用户说的「漏出来的部分」。
 * ⇒ 本轮把两块合并成**同一块连续模糊底**：由 `composer()` 里那个从**卡片上沿**铺到屏幕底的
 *   `Stack` 承载；`composerCard` 自己的 `backgroundColor` / `backgroundEffect` **撤除**。
 *
 * ### 为什么这是**契约演进**、而不是把护栏绕过
 * 本条的本意是「**正文玻璃面板的自绘回退层不许消失**」（材质是 `Navigation` 标题栏那种
 * 范围外静默无效的东西，正文面板只能靠自绘玻璃）。R92 撤掉的只是**卡片那一份重复的**玻璃：
 * 回退层本身逐字仍在（同一套令牌 `glassCardSurface()` + `GLASS_BLUR_RADIUS`），
 * 只是**承载它的 builder 从 `composerCard` 变成了 `composer`**。
 * 原断言把「回退层必须写在**同名** builder 里」当成了判据 —— 那是**实现细节耦合**。
 * ⇒ 改成**显式登记**：`fallbackOwner` 指名道姓说清「本面板的玻璃由谁供」。
 * ⚠️ 不采用「同页任一 builder 有玻璃就算过」那种宽松判据：那会让护栏失去分辨力。
 *
 * ### 三条机械核对（缺一不可，逐条见下面的断言与变异测试）
 * (a) **承载块体内确实有** `backgroundEffect(` **＋玻璃令牌**（三选一）；
 * (b) **登记的 owner 名字真的存在**于源码里（防止拼错名字就静默通过）；
 * (c) **被登记者体内确实已无** `backgroundEffect(`（否则这条登记是多余的、判据恒真）。
 */
const CONTENT_PANEL_FALLBACK_OWNER = {
  'ui/screens/SessionDetailScreen.ets#composerCard': 'composer'
};
/**
 * 判定一个 builder 体内有没有「自绘玻璃回退层」。
 * ⚠️ **两条都要有**：只有 `backgroundEffect(` 而没有任何玻璃令牌 ⇒ 可能糊的是透明色；
 *    只有令牌而没有 `backgroundEffect(` ⇒ 那是块**实底**、不是毛玻璃（R37 四改前就是这么错的）。
 */
/**
 * ⚠️ `glassButtonSurface()` 也在册：`scrollButton` 用的就是它（注释里写明「玻璃色比那两块**实一些**，
 *    保证箭头压在任意内容上都看得清」—— 那是**有意的**更强底色，不是漏用令牌）。
 *    护栏要守的是「有 `backgroundEffect(` 且糊的是**某个玻璃令牌**」，不是「必须用卡片那一档」。
 */
const GLASS_TOKENS = ['glassCardSurface()', 'glassPanelSurface()', 'glassSurface()', 'glassButtonSurface()'];
/** 宽口径：本体内有 `backgroundEffect(` 且出现任一玻璃令牌（未登记的 `@Builder` 走这条）。 */
function hasGlassFallback(body) {
  return body.indexOf('backgroundEffect(') >= 0
    && GLASS_TOKENS.some((t) => body.indexOf(t) >= 0);
}
/**
 * ## 紧口径：**同一个节点**上既铺了玻璃底色、又挂了 `backgroundEffect`
 *
 * ### 为什么承载块必须用更严的口径（R92 变1 实测出来的假绿）
 * `composer()` 体内**不止一处**玻璃：除了本轮新增的整块模糊底，还有忙碌提示行那个药丸
 * （`.backgroundColor(glassPanelSurface())` + `.borderWidth` + `.borderColor` + `.backgroundEffect({...})`）。
 * ⇒ 用宽口径判「承载块还有没有玻璃」时，**把底块的 `backgroundEffect` 整行删掉它依然为真**
 *   （变1 第一次跑就是这么红的）—— 那正是 dev-settings 本轮踩的「恒真判据」同族缺陷。
 * 紧口径只认「`.backgroundColor(<玻璃>)` 紧跟 `.backgroundEffect(`」这一对，
 * 忙碌药丸中间隔着 `borderWidth`/`borderColor` ⇒ 不会被误算进来。
 *
 * ⚠️ 中间的 `\s*` **只吃空白、不设距离窗口**：「`[\s\S]{0,N}`」那种写法在锚文与目标相距
 *    超过 N 时**恒假**（dev-settings 的坑），去掉上限又会**恒真** —— 只允许空白最稳。
 */
const GLASS_NODE_PAIR = /\.backgroundColor\(\s*glass[A-Za-z]*Surface\(\)\s*\)\s*\.backgroundEffect\(/;
function hasGlassSurfaceNode(body) {
  return GLASS_NODE_PAIR.test(body);
}
for (const [file, builders] of CONTENT_PANELS) {
  const code = codeOf(file);
  for (const b of builders) {
    const body = builderByName(code, b);
    if (body.length <= 40) {
      // ⚠️ 名字对不上不静默放过：报出来（否则护栏会靠「找不到」而假绿）。
      check('取到正文面板 ' + file + '#' + b + ' 的函数体', false, 'len=' + body.length);
      continue;
    }
    check(file + '#' + b + ' 在页面正文里**不挂** systemMaterial（该位置静默无效）',
      body.indexOf('systemMaterial(') < 0);
    const owner = CONTENT_PANEL_FALLBACK_OWNER[file + '#' + b];
    if (owner === undefined) {
      // 没登记的走**老口径**：玻璃必须挂在同名 builder 上。
      check(file + '#' + b + ' 保留自绘回退（backgroundEffect + 玻璃令牌）', hasGlassFallback(body));
      continue;
    }
    // ---- 已登记「玻璃由别的 builder 供」----
    const ownerBody = builderByName(code, owner);
    // (b) owner 名字必须真实存在（拼错 ⇒ 取到空串 ⇒ 红，不许静默通过）
    check('R92 登记表：' + file + '#' + b + ' 的玻璃承载块「' + owner + '」在源码里取得到函数体',
      ownerBody.length > 40, 'len=' + ownerBody.length);
    // (a) 承载块体内确实有回退层 —— ⚠️ 用**紧口径**（同一个节点上成对出现），
    //     宽口径会被该 builder 里别处的玻璃面板顶成恒真（变1 实测，见函数注释）。
    check('R92 登记表：承载块「' + owner + '」保留自绘回退（同一节点上 backgroundColor(玻璃) + backgroundEffect 成对）',
      hasGlassSurfaceNode(ownerBody));
    // (c) 被登记者体内确实已无 backgroundEffect（否则登记多余、断言恒真）
    check('R92 登记表：' + file + '#' + b + ' 本身已无 backgroundEffect（登记才是有意义的）',
      body.indexOf('backgroundEffect(') < 0);
    // 兜底：两处合起来必须仍有一层玻璃（防止「登记了但两边都没有」）
    check('R92 登记表：' + file + '#' + b + ' 的回退层没有凭空消失（被登记者 ∪ 承载块 至少一处）',
      hasGlassSurfaceNode(body) || hasGlassSurfaceNode(ownerBody));
  }
}
/**
 * ## SettingsScreen 的四个小窗是 `bindPopup` 的**内容根** —— 它们**在**生效范围内
 * （官方生效范围第 ① 类：弹窗类接口 `Popup 控制`），与「页面正文」是两个判定。
 *
 * ⚠️ **R86 口径变更**（Lead 2026-09-25 定稿，契约 §1.9）：内容根的自绘层从 R85 的
 * 「必须存在（缺口登记）」改成**门控** —— 探针可用 ⇒ 该节点零自绘层（材质接管
 * background / border / shadow / blur）；探针不可用 ⇒ 逐字回到 R86 前的自绘玻璃。
 * 这是**可用性回退**而非风格选择：这些弹窗容器自身是透明的（`popupColor: Color.Transparent`），
 * 内容根是**唯一**提供「底」的节点 —— 删净会让面板在探针 false 时**完全透明**（文字浮在正文上）。
 * ⇒ 断言**不许**钉死「某字面量必须存在 / 必须消失」：门控写法下 `backgroundEffect(` 等字面量**仍在**，
 *    而无条件零自绘层同样合法。真正的判据在 §⑥ 的 **A6**：按**根链**判「自绘层为空 **或** 被门控」。
 * 这里只留一条**结构性**断言：四个 builder 都取得到函数体（名字对不上不许静默放过）。
 */
const SET = codeOf('ui/screens/SettingsScreen.ets');
for (const b of ['appearanceMenu', 'languageWindow', 'agentPresetWindow', 'sidebarMenu']) {
  const body = builderByName(SET, b);
  check('SettingsScreen#' + b + ' 取到函数体（§⑥ A6 门控判定的前提）', body.length > 40, 'len=' + body.length);
}
const popupMenu = builderByName(SET, 'appearanceMenu');
check('SettingsScreen#appearanceMenu（bindPopup 内容根）仍受**默认关闭**的实验开关控制',
  popupMenu.indexOf('probeMaterial()') >= 0);
check('实验开关默认档 = 0（交付包不得启用实验路径）',
  SET.indexOf('export const MATERIAL_PROBE_MODE: number = 0;') >= 0);

// ---------------------------------------------------------------------------
// ④a 隐藏态材质语义（T6 修复的机械护栏）
// ---------------------------------------------------------------------------
/**
 * ## 这条断言守的是**官方语义**，不是代码风格（T6 / task-6）
 *
 * SDK 原文两条，语义**不同**：
 * · `systemMaterial(material)` —— **Setting it to undefined will make the component return to the
 *   no-material effect**（`common.d.ts:22632-22633`）；
 * · `uiMaterial.Material.empty` —— **used to disable the immersive system material effect for a
 *   component … by setting `systemMaterial(uiMaterial.Material.empty)`**（`uiMaterial.d.ts:467-472`）。
 *
 * 官方 FAQ 另写明：应用级 `MaterialState.ENABLE` 档下，**Tabs 设置 `barFloatingStyle` 并生效悬浮样式时，
 * 页签栏 TabBar 默认开启**（默认材质档 THIN）。本工程 `module.json5` 的
 * `ohos.arkui.UIMaterial.state` = `enable` ⇒ 隐藏态传 `undefined` = **把默认 THIN 材质放回来**，
 * 于是「隐藏态仍可能画出一条材质带」—— 与用户此前投诉的「只塌陷没消失、底下仍留一条」同源。
 * ⇒ 隐藏态**必须**用 `uiMaterial.Material.empty`（显式关闭）。
 *
 * ⚠️ 历史：R70 写的是 `undefined`，理由是「不传它，隐藏态就没有任何可绘制的面」——
 *    那是建立在「`undefined` = 不含材质」这个**错误前提**上的。
 */
const FLOAT_BODY = builderByName(IDX, 'floatingBarStyle');
check('取到 floatingBarStyle() 的函数体（隐藏态材质断言的前提）', FLOAT_BODY.length > 40, 'len=' + FLOAT_BODY.length);
check('底栏隐藏态用 uiMaterial.Material.empty 显式关闭材质（官方唯一关闭方式）',
  FLOAT_BODY.indexOf('uiMaterial.Material.empty') >= 0);
check('底栏隐藏态**不得**把裸 undefined 当作 systemMaterial 的实参（官方：undefined = 恢复默认材质）',
  !/[?]\s*undefined\s*:/.test(FLOAT_BODY) && !/systemMaterial:\s*undefined\b/.test(FLOAT_BODY));
check('底栏可见态仍走 bottomBarMaterial()（T6 只动隐藏态，可见态不变）',
  FLOAT_BODY.indexOf('bottomBarMaterial()') >= 0);
check('Index.ets 已 import uiMaterial（Material.empty 的取值前提）',
  IDX.indexOf("import { uiMaterial } from '@kit.ArkUI';") >= 0);
/**
 * ⚠️ **交付默认路径不许残留实验脚手架**（Lead 明确要求；verifier 会独立复核这一条）。
 * T6 期间用过 T6_FORCE_HIDDEN / T6_HIDDEN_MATERIAL / T6_VISIBLE_MODE 等临时常量做三方对照，
 * 收尾必须清干净 —— 尤其 `T6_HIDDEN_MATERIAL = undefined` 这种「把错误语义藏回交付代码」的写法。
 */
const SCAFFOLD = ['T6_FORCE_HIDDEN', 'T6_HIDDEN_MATERIAL', 'T6_VISIBLE_MODE', 'T6_VISIBLE_OVERRIDE', 't6Hidden'];
eq('交付源码零 T6 实验脚手架残留（Lead 硬要求 + verifier 复核项）',
  SCAFFOLD.filter((t) => IDX.indexOf(t) >= 0).join('|'), '');

// ---------------------------------------------------------------------------
// ④b 交付路径上**只能有一套底栏**（Lead 要求：把推断改成实测断言）
// ---------------------------------------------------------------------------
/**
 * 两条底栏路线的上树条件是**互斥**的，且必须有一条在默认配置下不成立：
 *  · 路线 A（官方 Tabs）：`if (BOTTOM_BAR_VIA_TABS && bottomNavIndex(this.route) >= 0) { this.topLevelTabs() }`
 *  · 路线 B（自绘浮层）：`if (!BOTTOM_BAR_VIA_TABS && overlayBarShownOn(this.route)) { this.bottomBarOverlay() }`
 * ⇒ 断言这条**互斥**在源码里逐字成立（任一处被改写成不互斥，就是「双层底栏 / 双份模糊」缺陷）。
 */
check('路线 A 的上树条件含 BOTTOM_BAR_VIA_TABS（正）',
  IDX.indexOf('if (BOTTOM_BAR_VIA_TABS && bottomNavIndex(this.route) >= 0) {') >= 0);
check('路线 B 的上树条件含 !BOTTOM_BAR_VIA_TABS（负）—— 两条路线互斥',
  IDX.indexOf('if (!BOTTOM_BAR_VIA_TABS && overlayBarShownOn(this.route)) {') >= 0);
check('底栏路线开关为**编译期常量**（同一包内不存在两条底栏）',
  BN.indexOf('export const BOTTOM_BAR_VIA_TABS: boolean = true;') >= 0);
check('自绘胶囊 AaBottomNav 的**唯一挂载点**在路线 B 的构造函数里（不在别处）',
  (IDX.split('AaBottomNav({').length - 1) === 1 && IDX.indexOf('AaBottomNav({') > IDX.indexOf('bottomBarOverlay() {'));
check('默认配置下路线 A 生效 ⇒ 交付路径上底栏只有一套（Tabs bar）',
  BN.indexOf('export const BOTTOM_BAR_VIA_TABS: boolean = true;') >= 0
    && IDX.indexOf('if (BOTTOM_BAR_VIA_TABS && bottomNavIndex(this.route) >= 0) {') >= 0);

// ---------------------------------------------------------------------------
// ⑤ 文档基线：清单必须落盘（verifier 拿它当「生效范围」定义基线）
// ---------------------------------------------------------------------------
/**
 * ⚠️ **该清单属内部资产**：落在开发期验证证据目录（`verify-*`）下，该目录**不随开源仓库分发**
 * （见根 `.gitignore` 第 4 类）。因此这一节按「资产存在与否」分两态：
 *   · 资产**不存在** ⇒ 显式 SKIP（打印原因），套件正常退出 0 —— 否则开源 clone 里必然假红；
 *   · 资产**存在** ⇒ 下列检查**照旧真跑**（作者本机 / 重新生成清单时该红还是红）。
 * ⚠️ 判据基于**具体文件是否存在**，不是「有没有设某个环境变量」—— 后者容易被误开而静默放宽。
 */
/**
 * ⚠️ 文件名**不钉死在某一天的证据目录**（证据目录名按日期生成）：在工程根下探测
 * verify-* 目录里的 MATERIAL-ACCESS-POINTS.md，取第一个存在的（多个并存时按目录名倒序 = 最新在前）。
 */
function findMaterialAccessPoints() {
  let entries = [];
  try {
    entries = fs.readdirSync(PROJECT, { withFileTypes: true });
  } catch (error) {
    return '';
  }
  const dirs = entries
    .filter((e) => e.isDirectory() && /^verify-\d{4}-\d{2}-\d{2}$/.test(e.name))
    .map((e) => e.name)
    .sort()
    .reverse();
  for (const name of dirs) {
    const candidate = path.join(PROJECT, name, 'MATERIAL-ACCESS-POINTS.md');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return '';
}
const DOC = findMaterialAccessPoints();
const DOC_ANCHORS = ['barPosition = BarPosition.End', 'uiMaterial.d.ts', 'navigation.d.ts:1891', 'tabs.d.ts:895', '零自绘层'];
if (fs.existsSync(DOC)) {
  for (const anchor of DOC_ANCHORS) {
    check('材质接入点清单里有官方依据锚文「' + anchor + '」', fs.readFileSync(DOC, 'utf8').indexOf(anchor) >= 0);
  }
} else {
  skip('材质接入点清单基线（' + DOC_ANCHORS.length + ' 条锚文）', '内部证据目录 verify-* 不随开源仓库分发');
}

// ---------------------------------------------------------------------------
// ⑥ R86：弹窗类接入点（A4 `bindSheet` / A6·A7 `bindPopup` / A12 `showAlertDialog`）
// ---------------------------------------------------------------------------
/**
 * ## 为什么这一节按「调用点」而不是按「文件 / 令牌」判
 * 上面几节的粒度是「某个 `@Builder` 里有没有某令牌」；而弹层材质的**下发点**在
 * `*Options()` 返回的**另一个对象**里（本工程 16 处 `bindPopup` 全是这个形态）——
 * 逐行令牌表看不出「这一处接了、那一处没接」。所以这里用 `material-audit.mjs#auditPopups()`
 * 逐调用点解析，**同一份解析器**（单一真源，避免两套实现漂移）。
 *
 * ## 判定口径（与 `INDEPENDENT-R86.md` §4.1 的 A1–A11 一一对应）
 * · **A1** 计数护栏：`bindSheet`=4 / `bindPopup`=16 / `showAlertDialog`=2 —— 将来新增弹层
 *   却忘了接材质，计数会先变，断言当场红（比「靠人 review」可靠）；
 * · **A2/A3/A4** 逐点：options 里必须出现 `systemMaterial:`，实参必须是冻结入口
 *   `panelMaterial()`（sheet）/ `dialogMaterial()`（popup）；
 * · **A5** 实参**不得**是 `undefined` —— 官方语义是「恢复组件默认材质」，不是「关闭」（官方语义 = 恢复默认材质，不是「关闭」）；
 * · **A6** 内容根：**根链**自绘层为空 **或** 被 `immersiveMaterialEnabled()` 门控（契约 §1.9）。
 *   ⚠️ 两条**反假阳性 / 反假阴性**的写法要求（Lead 2026-09-25 明确，别改回去）：
 *   ① 只认**根节点自己的**属性链（`rootChain()`）—— 扫整个 `@Builder` 体会把
 *      `FilesScreen#rowMenuCard` 里**图标方块**的 `.backgroundColor(subtle())` 误判成「内容根自绘底」；
 *   ② **不许**把裸 token（`backgroundColor(` / `.borderWidth(` / `.borderColor(` / `.shadow(`）当**禁令**：
 *      「门控 + 材质档取 `Color.Transparent` / `0`」是**正确写法**，必须判绿；
 *   ③ 「既无门控也无自绘层」（4 处 `bindSheet` 内容根）⇒ 按**零命中即绿**判，不强行要求门控存在；
 * · **A7** 门控只走 `Components.ets#immersiveMaterialEnabled()` 这一个探针；
 * · **A8** 生效范围外（正文面板已在上面钉住 + 自绘底栏胶囊）零 `systemMaterial(`；
 * · **A11** 关档语义只许由 helper 内部返回 `Material.empty`，交付代码不得直写。
 */
const POPUPS = auditPopups(SRC);
const POPUP_WANT = [['bindSheet', 4, 'panelMaterial('], ['bindPopup', 16, 'dialogMaterial('],
  ['showAlertDialog', 2, '']];
/** 真机 A/B-2 的位置级单变量常量（Lead 2026-09-25 加的**唯一**实验脚手架，默认 true）。 */
const AB2_GUARD = 'R86_APPEARANCE_MATERIAL_PROBE';

// ---- A1 计数护栏 ----
for (const [kind, want] of POPUP_WANT) {
  eq('R86-A1 ' + kind + ' 调用点计数 = ' + want + '（新增弹层必须同轮接材质，否则本断言变红）',
    POPUPS.filter((p) => p.kind === kind).length, want);
}
eq('R86-A1 弹窗类调用点合计 = 22', POPUPS.length, 22);

// ---- A2/A3/A4 + A5 + A11：逐调用点 ----
for (const p of POPUPS) {
  const at = p.kind + ' ' + p.file + ':' + p.line;
  const want = POPUP_WANT.filter((w) => w[0] === p.kind)[0][2];
  check('R86-A2/A3/A4 ' + at + ' options 可解析（来源 ' + p.optionsFrom + '）', p.optionsResolved,
    '解不出 ⇒ 人工看，不许当绿');
  check('R86-A2/A3/A4 ' + at + ' options 已下发 systemMaterial', p.hasField,
    'optionsFrom=' + p.optionsFrom);
  if (want !== '') {
    check('R86-A2/A3 ' + at + ' 实参 = ' + want + '…', p.materialExpr.indexOf(want) >= 0,
      'got ' + p.materialExpr);
  }
  check('R86-A5 ' + at + ' 实参不是 undefined（undefined = 恢复默认材质，不是「关闭」）',
    p.materialExpr !== 'undefined', 'got ' + p.materialExpr);
  // ⚠️ A11 的**例外只有一处**：Lead 的真机 A/B-2 位置级单变量脚手架
  // `systemMaterial: R86_APPEARANCE_MATERIAL_PROBE ? dialogMaterial() : uiMaterial.Material.empty`
  // —— 它必须在表达式里带该常量守卫（默认 true = 交付档下发材质），否则就是「把关闭语义藏进交付代码」。
  const compact = p.materialExpr.replace(/\s+/g, '');
  const hasEmpty = compact.indexOf('Material.empty') >= 0;
  check('R86-A11 ' + at + ' 关档语义带守卫（不直写 uiMaterial.Material.empty；A/B 脚手架须带 '
    + AB2_GUARD + '）',
    !(compact === 'uiMaterial.Material.empty' || (hasEmpty && p.materialExpr.indexOf(AB2_GUARD) < 0)),
    'got ' + p.materialExpr);
}

// ---- A6 内容根：根链**逐属性**判「自绘层为空 或 该属性被门控」 ----
const ROOTS = POPUPS.filter((p) => p.kind !== 'showAlertDialog');
eq('R86-A6 有内容根的接入点 = 20（16 popup + 4 sheet）', ROOTS.length, 20);
for (const p of ROOTS) {
  const at = p.kind + ' ' + p.file + ':' + p.line;
  check('R86-A6 ' + at + ' 内容根（' + p.builderRef + '）已解析', p.contentResolved,
    '解不出 ⇒ 人工看，不许当绿');
  const zero = p.rootSelfDrawn.length === 0;
  // 粗判（保留）：整条链上「自绘层为空」或「链里有门控」——用于给出人读的总览。
  check('R86-A6 ' + at + ' 根链自绘层为空 **或** 链上有 immersiveMaterialEnabled() 门控（契约 §1.9）',
    zero || p.contentGated,
    zero ? '' : '根链自绘=[' + p.rootSelfDrawn.join(' ') + '] 门控=' + p.contentGated);
  // 细判（**变异测试 M2 逼出来的**）：逐属性看 —— 只要某个自绘属性的表达式**自己**没被门控就是缺陷。
  // 只判整条链会让「把 backgroundColor 那一路偷偷放回原值、borderWidth 仍带门控」假绿。
  eq('R86-A6 ' + at + ' 每个自绘属性**各自**带门控（逐属性判定，链级会假绿）',
    p.rootUngatedSelfDrawn.join(' || '), '');
}
check('R86-A6 根链口径的令牌集与非空判定一致（防「令牌表被改空 ⇒ 全绿」）',
  POPUP_SELF_DRAWN.indexOf('backgroundEffect(') >= 0 && POPUP_SELF_DRAWN.indexOf('backgroundColor(') >= 0);

// ---- A7 门控只走同一个探针（**作用域 = 弹层所在文件**）----
/**
 * ⚠️ 作用域必须收窄，否则会**误伤既有合法代码**：`ui/GlassIcon.ets` 的 `glassMaterialProbe()`
 * 是 R84 起的**探针读数**函数（给 glass-ball 工装报「设备能力 / 档位 / 应用开关」），
 * 它直调 `uiMaterial.isImmersiveMaterialSupported()` 是**取数**不是**门控** ——
 * 拿一条全局禁令去管它会把这个诊断函数判红（第一版就踩了）。
 * ⇒ 只对**弹层门控**钉这条：弹层所在文件不得绕过 `immersiveMaterialEnabled()` 直调底层探针，
 *    且用了门控的文件必须从 `ui/Components` 统一入口引入。
 */
const POPUP_FILES = [...new Set(ROOTS.map((p) => p.file))].sort();
eq('R86-A7 弹层分布在 6 个文件（Home / Settings / Files / NewSession / SessionDetail / Terminal / DeviceDetail 去重）',
  POPUP_FILES.join(','),
  ['ui/screens/DeviceDetailScreen.ets', 'ui/screens/FilesScreen.ets', 'ui/screens/HomeScreen.ets',
    'ui/screens/NewSessionScreen.ets', 'ui/screens/SessionDetailScreen.ets', 'ui/screens/SettingsScreen.ets',
    'ui/screens/TerminalScreen.ets'].join(','));
const bypassProbe = [];
for (const rel of POPUP_FILES) {
  if (codeOf(rel).indexOf('uiMaterial.isImmersiveMaterialSupported(') >= 0) { bypassProbe.push(rel); }
}
eq('R86-A7 弹层文件不绕过统一探针（零直调 uiMaterial.isImmersiveMaterialSupported()）',
  bypassProbe.join('|'), '');
for (const rel of POPUP_FILES.filter((f) => ROOTS.some((p) => p.file === f && p.contentGated))) {
  check('R86-A7 ' + rel + ' 从 ui/Components 统一引入 immersiveMaterialEnabled（同一探针）',
    /import\s*\{[\s\S]*?immersiveMaterialEnabled[\s\S]*?\}\s*from\s*'[^']*Components'/.test(codeOf(rel)));
}

// ---- A8 生效范围外零材质（SessionDetail 正文面板已在 §④ 钉住，这里补自绘底栏胶囊）----
/** `AaBottomNav` 是 **struct** 不是方法 ⇒ 不能用 `builderByName()`（它按 `name(` 找，第一版取到 len=0）。 */
function structBody(code, name) {
  const re = new RegExp('(?:^|\\n)[ \\t]*(?:@Component[ \\t]*\\n[ \\t]*)?(?:export[ \\t]+)?struct[ \\t]+'
    + name + '[ \\t]*\\{');
  const m = re.exec(code);
  if (m === null) { return ''; }
  const open = code.indexOf('{', m.index + m[0].length - 1);
  if (open < 0) { return ''; }
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '{') { depth += 1; } else if (code[i] === '}') {
      depth -= 1;
      if (depth === 0) { return code.slice(open, i + 1); }
    }
  }
  return '';
}
/** 递归收集 `.ets` 相对路径（A11 的「脚手架扩散面」用）。 */
function walkEts(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) { out.push(...walkEts(abs)); } else if (e.name.endsWith('.ets')) { out.push(abs); }
  }
  return out;
}
const BN_CODE = codeOf('ui/BottomNav.ets');
const NAV_BODY = structBody(BN_CODE, 'AaBottomNav');check('R86-A8 取到 BottomNav#AaBottomNav 的 struct 体', NAV_BODY.length > 40, 'len=' + NAV_BODY.length);
check('R86-A8 BottomNav#AaBottomNav（自绘胶囊，交付路径不在树上）零 systemMaterial(',
  NAV_BODY.indexOf('systemMaterial(') < 0);

// ---- A11 脚手架的默认档与扩散面（关档语义不能藏在交付路径里）----
check('R86-A11 ' + AB2_GUARD + ' 默认 true（交付源码必须下发材质；实验脚手架不得把材质关在默认档）',
  SET.indexOf('export const ' + AB2_GUARD + ': boolean = true;') >= 0);
{
  const holders = walkEts(SRC).map((abs) => path.relative(SRC, abs).replace(/\\/g, '/'))
    .filter((rel) => codeOf(rel).indexOf(AB2_GUARD) >= 0);
  eq('R86-A11 位置级 A/B 脚手架只出现在 SettingsScreen（一次性实验开关，不许扩散）',
    holders.sort().join(','), 'ui/screens/SettingsScreen.ets');
}

// ---------------------------------------------------------------------------
// ⑦ R88：首页「错误条 / 空态 / 加载中」的**标题栏让位**（用户截图：红条压住状态栏与标题）
// ---------------------------------------------------------------------------
/**
 * ## 背景
 * 用户截图：冷启即断网时，首页红色错误条**压在状态栏（0..137px）与标题栏（137..332px）上**。
 * 根因：首页是 `barStyle: BarStyle.STACK`（内容从 **y=0** 起、标题栏叠在内容上）
 * ⇒ **内容流的第一行必须自己让位**。`List` 那一路有 `contentStartOffset(listTopOffsetVp())`（R58 加的）✓，
 * 但「错误条 / 空态 / 加载中」这三块**从来没让位**。
 *
 * ## 判据（三条，都能被机械证伪）
 *  · 让位方法 `contentTopOffsetVp()` 必须存在，且**有错误条时返回 0**（不重复让位）；
 *  · 错误条那一层必须带 `padding({ top: this.listTopOffsetVp() })`；
 *  · 两条 `List` 的 `contentStartOffset` 必须走 `contentTopOffsetVp()`（不许写死 `listTopOffsetVp()`）。
 * ## 另有交付档守卫
 * `R88_ERROR_PROBE` 是**真机验证用的注入探针**（本机 `svc wifi disable` 复现不出断网错误，
 * 只能靠编译期常量确定性打开那条路径）⇒ **交付档必须为空串**，且只许出现在首页。
 */
const HOME = codeOf('ui/screens/HomeScreen.ets');
// ## R90（用户第二期：「我更看重**穿过**效果」）—— R89 的 `margin` 方案**整体反转**：
// R89 用「`Refresh` 整体下移」把指示器挪到标题栏下方，代价是内容**再也穿不过标题栏**；
// R90 撤销那次下移、改用**自绘刷新区域**（`builder: this.refreshArea()`）承载指示器：
// 自绘区顶边恒贴 `Refresh` 顶边、局部坐标 = 屏幕坐标 ⇒ 内容自带 `padding.top = listTopOffsetVp()`
// 就能落到「标题栏下沿 333px」，而 `Refresh` 本体不动（内容重新从标题栏背后穿过）。
// ⇒ 让位**回到内容层**（与 R88 同源）：错误条/空态/加载中走 `contentTopOffsetVp()`、
//   两条 `List` 走 `contentStartOffset(contentTopOffsetVp())`。
/**
 * ## R90 的判据（用户两条反馈：圆圈"位置不对" + "加载不会结束"）
 *
 * 三轮实测把三条路走死之后，现行方案是**两条腿**：
 *  · **关掉框架的默认指示器**：`builder` 给一个**空 `Column`**（`InitChildNode` 见 `isCustomBuilderExist_`
 *    就不再建默认指示器），`Refresh` 本体**留在原位** ⇒ 内容继续从标题栏背后穿过；
 *  · **指示器自绘在外层浮层**：位置 = `listTopOffsetVp()`（与列表首项同值同源）、
 *    去留 = `if (this.pullActive || this.refreshing)`（不再常驻 ⇒ 不存在"停不下来"）。
 *
 * ⚠️ 判据只取**根节点的属性链**（复用 `builderBody()` / `rootChain()`），不扫整个 `@Builder` 体 ——
 *    扫描式匹配会被后续代码污染（第一版把 margin/height 禁令匹配到 Refresh 属性链和内层
 *    `LoadingProgress().height(…)` 上，**两条断言假红**，实测 320 通过 / 2 失败）。
 */
const RA_BODY = builderBody(HOME, 'refreshArea() {');
const RA_ROOT = rootChain(RA_BODY);
check('R90 空自绘区 refreshArea() 的根属性链已取到', RA_ROOT.length > 0);
check('R90 自绘刷新区必须是空的（它的唯一作用是关掉框架默认指示器，不再自绘任何东西）',
  RA_BODY.indexOf('LoadingProgress') < 0,
  '\\u81ea\\u7ed8\\u533a\\u91cc\\u53c8\\u753b\\u4e1c\\u897f\\u4e86 \\u21d2 \\u4f4d\\u7f6e/\\u53bb\\u7559\\u53c8\\u4f1a\\u6709\\u4e00\\u534a\\u4e0d\\u5f52\\u6211\\u4eec\\u7ba1');
check('R90 空自绘区仍接入 Refresh 的 builder（不接 = 框架默认指示器又画回标题栏里）',
  /Refresh\(\{ refreshing: \$\$this\.refreshing, builder: this\.refreshArea\(\) \}\)/.test(HOME));
check('R90 Refresh 本体不得再下移（margin 撤销 ⇒ 内容必须重新从标题栏背后穿过）',
  !/\.margin\(\{ top: this\.listTopOffsetVp\(\) \}\)/.test(navigationChain(HOME)),
  '\\u5b58\\u5728\\u8ba9\\u4f4d margin \\u21d2 \\u5185\\u5bb9\\u53c8\\u7a7f\\u4e0d\\u8fc7\\u6807\\u9898\\u680f\\u4e86');
check('R90 refreshArea() 根链不写死 height（写死会改变框架高度基数、把自绘区往上顶）',
  !/\.height\(/.test(RA_ROOT));
check('R90 refreshArea() 根链不设 position（SDK：给子组件设 position 会把下拉位移钉死）',
  !/\.position\(/.test(RA_ROOT));
check('R90 refreshArea() 根链不设 backgroundColor（自绘区会盖住 Refresh 顶边以下一条）',
  !/\.backgroundColor\(/.test(RA_ROOT));
// ---- 指示器浮层：位置 + 去留 + 不吃手势 ----
// 判据必须**把浮层的整条根链取出来**判：第一版只测「margin 出现在 width(100%) 之后」，
// 漏掉根 Stack 是 alignContent(BottomEnd) 这一条 ⇒ 真机上圆圈被摆到**屏幕底部**
// （实测 [610,2737][706,2832]，被底栏挡着），断言却全绿 —— 这是「断言没抓住真缺陷」的一次实证。
const RING_BODY = builderBody(HOME, 'if (this.pullActive || this.refreshing) {');
check('R90 指示器浮层由「下拉中 或 刷新态」门控（常驻 = 用户读到的"加载不会结束"）',
  RING_BODY.length > 0);
check('R90 指示器浮层位置与列表首项同源（listTopOffsetVp，不写死像素）',
  /\.margin\(\{ top: this\.listTopOffsetVp\(\) \}\)/.test(RING_BODY));
check('R90 指示器浮层必须铺满并对齐顶部（根 Stack 是 BottomEnd，不铺满就会被摆到屏幕底部）',
  /\.height\('100%'\)/.test(RING_BODY) && /\.justifyContent\(FlexAlign\.Start\)/.test(RING_BODY),
  '浮层未铺满 ⇒ 圆圈会落在屏幕底部（真机实测）');
check('R90 指示器浮层不吞手势（铺满型兄弟容器必须 hitTestBehavior(None)）',
  /\.hitTestBehavior\(HitTestMode\.None\)/.test(RING_BODY));
check('R90 下拉反馈接线：onOffsetChange 用滞回布尔驱动 pullActive（不许逐帧写数值）',
  /\.onOffsetChange\(\(offset: number\) => \{[\s\S]{0,400}?this\.pullActive = true;/.test(HOME)
  && /\.onOffsetChange\(\(offset: number\) => \{[\s\S]{0,400}?this\.pullActive = false;/.test(HOME));
check('R90 刷新收尾仍在（try/finally 置回 refreshing=false）',
  /private async onRefresh\(\): Promise<void> \{[\s\S]{0,1200}?this\.refreshing = false;/.test(HOME));
// R90 真机探针（一次性验证脚手架，同 R88 那条的规矩）
check('R90 刷新态探针在交付档必须为空串（非空 = 把假刷新钉进了正式包）',
  /const R90_REFRESH_PROBE: string = '';/.test(HOME),
  '\u63a2\u9488\u88ab\u6539\u6210\u4e86\u975e\u7a7a\u503c \u21d2 \u6b63\u5f0f\u5305\u4f1a\u591a\u505c\u4e00\u6bb5\u5047\u5237\u65b0');
// ---- 内容层让位（与 R88 同源）----
check('R90 内容层让位已恢复：两条 List 都走 contentStartOffset(contentTopOffsetVp())',
  (HOME.match(/\.contentStartOffset\(this\.contentTopOffsetVp\(\)\)/g) || []).length === 2,
  '\\u4e24\\u6761 List \\u5fc5\\u987b\\u5404\\u81ea\\u8ba9\\u4f4d\\u4e00\\u6b21');
check('R90 让位去重方法 contentTopOffsetVp() 存在（有错误条时归 0，不重复让位）',
  HOME.indexOf('private contentTopOffsetVp(): number {') >= 0);
check('R90 错误条 / 空态 / 加载中都带让位（内容流第一行自己让位，别让 R88 缺陷复发）',
  HOME.indexOf('.padding({ top: this.listTopOffsetVp() })') >= 0
  && (HOME.match(/\.padding\(\{ top: this\.contentTopOffsetVp\(\) \}\)/g) || []).length === 2);

// ---------------------------------------------------------------------------
// ⑨ R90-T2：首页标题栏的**模糊口径**（用户：「模糊效果不好，恢复原先模糊效果」）
// ---------------------------------------------------------------------------
/**
 * ## 为什么要钉住「用哪个模糊」
 * R89 把 `Refresh` 整体下移 ⇒ 内容不走标题栏背后 ⇒ 滚动遮罩无可糊之物，观感"干净"。
 * R90 撤销下移、**恢复「穿过」** ⇒ 正文真的从栏背后滚过，那条遮罩第一次显形，用户立刻报「模糊效果不好」。
 *
 * ### 为什么 `GRADUAL_BLUR` 不好看（SDK 原文 + 真机 dump 双证）
 * · SDK 对它的定义是「uniform blur to the title background **with clear boundaries**」
 *   ⇒ **clear boundaries = 硬边界**（真机截图里是一片带硬直底边的灰糊带）。
 * · 它的遮罩点越界：真机 dump 实测 `TitleBarMaskBlur [0,137][1316,428]`，
 *   底边 428px **越过**标题栏底 332px 整整 **96px**（滚动遮罩会越过标题栏向下延伸），
 *   而 R90 的刷新指示器恰好落在 `[610,332][706,427]` ⇒ 正被它洗掉。
 *
 * ### 现行口径：换 `NavigationTitleOptions.backgroundEffect`（官方**常驻**背景模糊）
 * 真机 dump 复核：改用后 `TitleBarMaskBlur` / `TitleBarMask` **两个节点都消失**，
 * 且参数取本工程同一套玻璃令牌（`GLASS_BLUR_RADIUS` / `GLASS_SATURATION` /
 * `GLASS_BRIGHTNESS` / `glassSurface()`）—— 即"原先那层玻璃"的配方。
 * 与 `SessionDetailScreen`（R77）是**同一裁决**：要「穿过」就用常驻，不用滚动遮罩。
 */
/**
 * ⚠️ **必须用 `navigationChain()` 取链，不能用 `builderBody(HOME, 'Navigation() {')`**：
 * 后者在 `Navigation(){…}` 的**闭合大括号**就停了，而 `.title(…)` / `.margin(…)`
 * 这些属性**链在括号之外** ⇒ 取到的是空串，断言会**假绿**。
 * （R90 那条「Refresh 本体不得再下移」就踩了这个：`!test('')` 恒为真 ⇒ 一直绿。
 *  本轮实测：改成真链后它才第一次真正生效。）
 */
const HOME_TITLE = navigationChain(HOME);
check('R90-T2 首页标题栏改用官方**常驻** backgroundEffect（不再用滚动的 GRADUAL_BLUR）',
  HOME_TITLE.indexOf('backgroundEffect:') >= 0 && HOME_TITLE.indexOf('scrollEffectOptions') < 0,
  '\u53c8\u56de\u5230\u4e86\u786c\u8fb9\u754c\u7684\u6eda\u52a8\u906e\u7f69 \u21d2 \u6807\u9898\u680f\u4e0b\u65b9 96px \u4f1a\u88ab\u6d17\u6389');
check('R90-T2 常驻模糊的四个参数取本工程玻璃令牌（与"原先那层玻璃"同配方）',
  /\.radius\(?\s*:?\s*GLASS_BLUR_RADIUS|radius:\s*GLASS_BLUR_RADIUS/.test(HOME_TITLE)
  && /saturation:\s*GLASS_SATURATION/.test(HOME_TITLE)
  && /brightness:\s*GLASS_BRIGHTNESS/.test(HOME_TITLE)
  && /color:\s*glassSurface\(\)/.test(HOME_TITLE));
check('R90-T2 官方约束：backgroundEffect 不与 backgroundBlurStyleOptions 同用',
  HOME_TITLE.indexOf('backgroundBlurStyleOptions') < 0);
check('R90-T2 标题栏底色仍为透明（不透明底会把框架画的模糊层整条盖住）',
  HOME_TITLE.indexOf('backgroundColor: Color.Transparent') >= 0);
// ⚠️ 反向：不许把「刷新指示器」挪进遮罩溢出带（332..428）以外的位置，也不许去掉它的让位
check('R90-T2 刷新指示器仍与列表首项同源让位（换模糊不许动它）',
  /\.margin\(\{ top: this\.listTopOffsetVp\(\) \}\)/.test(builderBody(HOME, 'if (this.pullActive || this.refreshing) {')));

// ---------------------------------------------------------------------------
// ⑧ R89：两页刷新状态的**收尾**（用户「设备页刷新状态不会结束」）
// ---------------------------------------------------------------------------
/**
 * ## 用户诉求（原文）
 * 「**设备页刷新状态不会结束**，排查一下」。
 *
 * ## 根因（两层，缺任何一层圆圈都停不下来）
 * 1. **主因**：`DevicesScreen` 的 `Refresh({ refreshing: $$this.isRefreshing })` 是**双向绑定**，
 *    但**没有 `.onRefreshing`** ⇒ 下拉时框架把状态置 `true`，**没有任何代码置回 `false`**
 *    ⇒ 圆圈**永远转**（全工程两处 `Refresh`：首页有 handler，只有设备页漏了）。
 * 2. **次因**：`refresh()` 旧写法是裸 `.then(…)`（**无 catch**）、首页 `onRefresh()` 是裸 `await`（reject 时抛过那一行）
 *    ⇒ 请求失败时同样收不到指示器（这条路径由 `aboutToAppear` / 下拉触发）。
 */
const DEV = codeOf('ui/screens/DevicesScreen.ets');
check('R89 设备页 Refresh 有 onRefreshing（缺它 = 下拉后无人把 isRefreshing 置回 false）',
  /Refresh\(\{ refreshing: \$\$this\.isRefreshing \}\)[\s\S]{0,1600}?\.onRefreshing\(/.test(DEV),
  '设备页的下拉刷新没有 handler ⇒ 圆圈永不结束（用户报的就是这个）');
check('R89 设备页 refresh() 有失败分支（否则 isRefreshing 永远停在 true）',
  /private refresh\(\): void \{[\s\S]{0,600}?\.finally\(\(\) => \{\s*this\.isRefreshing = false;/.test(DEV),
  'refreshDevices() 失败时收不到指示器');
// ⚠️ R90 后判据放宽成「finally 块里**最终**把 refreshing 置回 false」：
//    R90 在 finally 里插了一段**探针**（交付档为空串的死代码）才置位，硬编码「紧跟 finally」会假红。
check('R89 首页 onRefresh() 有 try/finally（await 抛出时也要收指示器）',
  /private async onRefresh\(\): Promise<void> \{[\s\S]{0,1200}?finally \{[\s\S]{0,600}?this\.refreshing = false;/.test(HOME));
// 全工程：`Refresh` 与 `onRefreshing` 必须**一一配对**。
eq('R89 全工程 Refresh 与 onRefreshing 必须配对（缺一个 = 下拉圆圈永不结束）',
  ['ui/screens/HomeScreen.ets', 'ui/screens/DevicesScreen.ets',
    'ui/screens/FilesScreen.ets', 'ui/screens/SettingsScreen.ets', 'ui/screens/NewSessionScreen.ets']
    .map((f) => (codeOf(f).match(/Refresh\(\{ refreshing:/g) || []).length
      - (codeOf(f).match(/\.onRefreshing\(/g) || []).length)
    .filter((diff) => diff !== 0).length, 0);

// ---------------------------------------------------------------------------
// ④b R92 登记表判据的**变异测试**（证明上面那几条不是恒真）
// ---------------------------------------------------------------------------
/**
 * ## 为什么必须做变异（照抄 dev-settings 本轮的教训）
 * 反向判据最容易写成**恒真**：他们把正则窗口写成 `[\s\S]{0,200}` 而锚文到目标隔着 258 字符 ⇒
 * 永远匹配不上、判据永远「通过」，是靠变异自检才发现的。
 * ⇒ 本节的判据（`hasGlassFallback` / 登记表三条）也用同一套办法验一次分辨力：
 * **把源码改坏 ⇒ 判据必须变红**。
 *
 * ⚠️ 变异在**内存里**做（对 `codeOf()` 返回的字符串做替换），**不落盘、不碰工程源码** ——
 *    与 `suite-utf8.mjs` 的 `mutate()` 同一个口径。
 * ⚠️ 每条变异先断言「确实改到了源码」（`mutated !== source`），否则锚文写错会假绿。
 */
function mutateScreen(replacements) {
  let out = codeOf('ui/screens/SessionDetailScreen.ets');
  for (const [from, to] of replacements) { out = out.split(from).join(to); }
  return out;
}
/**
 * 按**生产代码用的同一套判据**评估一份（可能已被改坏的）源码，返回是否全绿。
 * ⚠️ 与上面 CONTENT_PANELS 循环里的四条断言**逐条同源**（同两个 helper、同四个式子）——
 *    这里只是把它们提成一个可带参数的函数，好让变异能换 owner 名。
 */
function panelGatesOk(src, ownerName) {
  const body = builderByName(src, 'composerCard');
  const ownerBody = builderByName(src, ownerName);
  return ownerBody.length > 40
    && hasGlassSurfaceNode(ownerBody)
    && body.length > 40 && body.indexOf('backgroundEffect(') < 0
    && (hasGlassSurfaceNode(body) || hasGlassSurfaceNode(ownerBody));
}
const REGISTERED_OWNER = CONTENT_PANEL_FALLBACK_OWNER['ui/screens/SessionDetailScreen.ets#composerCard'];
/** 本页源码里**唯一**的两个变异锚文（写入前已逐个核过 count === 1）。 */
/** 块玻璃的**两行**锚（带 `backgroundEffect({`）—— 只在底块出现一次（已核 count === 1）。 */
const MUT_BLOCK_GLASS = '      .backgroundColor(glassCardSurface())' + String.fromCharCode(10) + '      .backgroundEffect({'
const MUT_CARD_TAIL = '.constraintSize({ minHeight: 104, maxHeight: 218 })'

function mutation(name, replacements, expectOk, ownerName) {
  const source = codeOf('ui/screens/SessionDetailScreen.ets');
  const mutated = mutateScreen(replacements);
  const owner = ownerName === undefined ? REGISTERED_OWNER : ownerName;
  // ⚠️ 锚文写错会让 `split/join` 静默什么也没改 ⇒ 判据在**原源码**上跑、结果恒为绿 = 假绿。
  //    所以只要给了替换，就必须证明它真的改到了源码（变3 走 owner 注入，没有替换、跳过本条）。
  if (replacements.length > 0) {
    check(name + '：变异确实改到了源码', mutated !== source);
  }
  check(name + '：判据结果 = ' + (expectOk ? '通过' : '变红'), panelGatesOk(mutated, owner) === expectOk);
}

// ## 变1：抹掉**承载块**的 backgroundEffect ⇒ `hasGlassFallback(owner)` 必须失败。
// 锚文带上它自己那行 `backgroundColor`：缩进（6 空格）在本文件里唯一标识底块，
// 而 `backgroundEffect(` 全页有 5 处（忙碌行/指令面板/底块/输入卡../选项卡）⇒ 不能单用它做锚。
mutation('R92 变1：删掉模糊块(承载块)的 backgroundEffect',
  // ⚠️ 替换成**只留底色**：`hasGlassFallback` 要求 `backgroundEffect(` 与玻璃令牌**同时**在场，
  //    去掉前者必须让判据红（这正是「回退层被删掉」的等价形态）。
  [[MUT_BLOCK_GLASS, '      .backgroundColor(glassCardSurface())']], false);

// ## 变2：把一个 backgroundEffect **加回** composerCard ⇒ 判据 (c)「被登记者本身已无」必须失败。
// 挂点取卡片链尾那行唯一锚文（卡片 `constraintSize` 在全页只出现一次）。
mutation('R92 变2：把 backgroundEffect 加回 composerCard',
  [[MUT_CARD_TAIL, MUT_CARD_TAIL + String.fromCharCode(10)
    + '    .backgroundEffect({' + String.fromCharCode(10) + '      radius: GLASS_BLUR_RADIUS' + String.fromCharCode(10) + '    })']], false);

// ## 变3：把登记的 owner 名字换成一个**不存在**的 builder ⇒ 判据 (b) 必须失败。
// ⚠️ 这条的「变异」改的是**登记表指向谁**、不是源码本身（源码没问题）⇒ 用 `ownerName` 参数注入，
//    `replacements` 给空数组表示「源码一字不动」。
//    必须红：否则「登记了但名字拼错」会静默通过 —— 那正是 (b) 要防的假绿。
mutation('R92 变3：登记字段指向不存在的 builder 名',
  [], false, 'composerGlazzBlockHeightVp');

// ## 顺带把「登记表本身当时是绿的」也钉住（否则上面三条只在坏源码上验过、没验过好源码）
check('R92 登记表：未变异的源码在**登记后的判据**下全绿',
  panelGatesOk(codeOf('ui/screens/SessionDetailScreen.ets'), REGISTERED_OWNER));
// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------
console.log('=== suite-material：官方材质接入护栏 ===');
console.log('通过 ' + pass + ' 项 / 失败 ' + failures.length + ' 项'
  + (skipped.length > 0 ? ' / 跳过 ' + skipped.length + ' 项（内部资产缺失）' : ''));
for (const f of failures) { console.log('  ✗ ' + f); }
// SKIP 行原样打印（已自带 `⊘ SKIP：` 前缀，run-all.mjs 靠该前缀单独计数并在汇总里列出）
for (const s of skipped) { console.log('  ' + s); }
process.exit(failures.length === 0 ? 0 : 1);
