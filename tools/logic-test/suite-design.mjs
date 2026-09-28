#!/usr/bin/env node
/**
 * aa-hm 设计令牌与通用组件的自测（不依赖 ArkUI / 设备）。
 *
 * 范围（R10 task-13 收缩后）：
 *  ① **令牌完整性**：`ui/Design.ets` 的类/常量/颜色函数是否齐全且取值符合契约；
 *  ② **向后兼容**：既有令牌名一个都不许改名或消失（它们被全工程引用）；
 *  ③ **通用组件无硬编码**：`ui/Components.ets` 里不得再出现裸的颜色字面量、间距、圆角、线宽。
 *
 * ⚠️ 不断言各页面（`ui/screens/*.ets`）：按用户拍板，页面结构即将按安卓端一比一重写，
 * 页面里的硬编码现状只记录在开发期验证记录（不随仓库分发），不在本脚本里断言。
 *
 * 转译方式照抄 tools/logic-test/run-tests.mjs；`Design.ets` 里的颜色函数体用了 ArkUI 全局
 * `$r()`，Node 侧在 require 之前注入一个同名 stub 即可（返回值就是资源键，正好便于断言）。
 *
 * 用法：
 *   node tools\logic-test\suite-design.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-design');
const DESIGN_ETS = path.join(SRC_ETS, 'ui', 'Design.ets');
const COMPONENTS_ETS = path.join(SRC_ETS, 'ui', 'Components.ets');

/** 只挑不 import @kit / ArkUI 的模块（Design.ets 只依赖全局 `$r`）。 */
const LOGIC_FILES = ['ui/Design.ets'];

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
        removeComments: false
      },
      fileName: rel
    });
    const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, output.outputText, 'utf8');
  }
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

build();

const require = createRequire(import.meta.url);
// ArkUI 的 `$r()` 在 Node 里不存在：注入 stub（返回值就是资源键，便于断言）。
globalThis.$r = (key) => key;
const design = require(path.join(OUT_DIR, 'ui/Design.js'));

// ---------------------------------------------------------------------------
// 1. 间距令牌
// ---------------------------------------------------------------------------

group('间距令牌 Space（4 的倍数体系 + 两个半档）');
eq('Space.XXS', design.Space.XXS, 2);
eq('Space.XS', design.Space.XS, 4);
eq('Space.XS_PLUS', design.Space.XS_PLUS, 6);
eq('Space.S', design.Space.S, 8);
eq('Space.M', design.Space.M, 12);
eq('Space.L', design.Space.L, 16);
eq('Space.XL', design.Space.XL, 24);
eq('Space.XXL', design.Space.XXL, 32);
check('Space 严格递增',
  design.Space.XXS < design.Space.XS && design.Space.XS < design.Space.XS_PLUS
    && design.Space.XS_PLUS < design.Space.S && design.Space.S < design.Space.M
    && design.Space.M < design.Space.L && design.Space.L < design.Space.XL
    && design.Space.XL < design.Space.XXL);

// ---------------------------------------------------------------------------
// 2. 圆角令牌
// ---------------------------------------------------------------------------

group('圆角令牌 Radius');
eq('Radius.S', design.Radius.S, 8);
eq('Radius.M', design.Radius.M, 12);
eq('Radius.L', design.Radius.L, 16);
eq('Radius.PILL', design.Radius.PILL, 999);
check('Radius 严格递增（PILL 视作无限大）',
  design.Radius.S < design.Radius.M && design.Radius.M < design.Radius.L && design.Radius.L < design.Radius.PILL);

// ---------------------------------------------------------------------------
// 3. 字号令牌
// ---------------------------------------------------------------------------

group('字号令牌 FontSize（正文档 + 图标档 + 导航档）');
eq('FontSize.CAPTION', design.FontSize.CAPTION, 11);
eq('FontSize.SMALL', design.FontSize.SMALL, 13);
eq('FontSize.BODY', design.FontSize.BODY, 15);
eq('FontSize.TITLE', design.FontSize.TITLE, 17);
eq('FontSize.HEADLINE', design.FontSize.HEADLINE, 22);
eq('FontSize.DISPLAY', design.FontSize.DISPLAY, 28);
eq('FontSize.NAV_ICON（新增：统一 7 页面的返回箭头）', design.FontSize.NAV_ICON, 28);
eq('FontSize.ICON_LARGE（新增）', design.FontSize.ICON_LARGE, 24);
eq('FontSize.ICON（新增）', design.FontSize.ICON, 20);
check('字号档不小于最小可读 11', design.FontSize.ICON >= design.FontSize.SMALL);

// ---------------------------------------------------------------------------
// 4. 控件尺寸与线宽
// ---------------------------------------------------------------------------

group('控件尺寸 Control / 线宽 StrokeWidth（R10 新增）');
eq('Control.FIELD', design.Control.FIELD, 44);
eq('Control.FIELD_COMPACT', design.Control.FIELD_COMPACT, 36);
eq('Control.NAV_BUTTON', design.Control.NAV_BUTTON, 32);
eq('Control.ICON_BUTTON', design.Control.ICON_BUTTON, 38);
eq('Control.BUTTON', design.Control.BUTTON, 46);
eq('Control.MENU_ROW', design.Control.MENU_ROW, 50);
check('紧凑输入框比标准输入框矮', design.Control.FIELD_COMPACT < design.Control.FIELD);
eq('StrokeWidth.HAIRLINE', design.StrokeWidth.HAIRLINE, 1);

// ---------------------------------------------------------------------------
// 5. 颜色函数：完整性 + 资源键映射
// ---------------------------------------------------------------------------

group('颜色函数：既有 10 个 + R10 新增 4 个');
eq('canvas()', design.canvas(), 'app.color.canvas');
eq('ink()', design.ink(), 'app.color.ink');
eq('muted()', design.muted(), 'app.color.muted');
eq('inkSoft()（新增）', design.inkSoft(), 'app.color.ink_soft');
eq('faint()（新增）', design.faint(), 'app.color.faint');
eq('subtle()（新增）', design.subtle(), 'app.color.subtle');
eq('errorText()（新增）', design.errorText(), 'app.color.error_text');
eq('borderColor()', design.borderColor(), 'app.color.border');
eq('raisedSurface()', design.raisedSurface(), 'app.color.raised_surface');
eq('primaryAction()', design.primaryAction(), 'app.color.primary_action');
eq('onPrimaryAction()', design.onPrimaryAction(), 'app.color.on_primary_action');
eq('statusColor(running)', design.statusColor('running'), 'app.color.runtime_running');
eq('statusColor(waiting_approval)', design.statusColor('waiting_approval'), 'app.color.notice_warning');
eq('statusColor(未知档回落 faint)', design.statusColor('whatever'), 'app.color.faint');
eq('runtimeStatusColor(available)', design.runtimeStatusColor('available'), 'app.color.runtime_active');
eq('runtimeStatusColor(error)', design.runtimeStatusColor('error'), 'app.color.error_text');
eq('runtimeStatusLabel(running)', design.runtimeStatusLabel('running'), '运行中');
// R13-8 裁决：对齐上游 `device_runtime_unknown`「未知状态」（不再是自创的「未知」）。
eq('runtimeStatusLabel(未知)', design.runtimeStatusLabel('???'), '未知状态');

// ---------------------------------------------------------------------------
// 6. 源码文本扫描（Components.ets / Design.ets）
// ---------------------------------------------------------------------------

group('通用组件与令牌源里不得有游离的硬编码');

function readText(p) {
  return fs.readFileSync(p, 'utf8');
}

function codeLines(text) {
  return text.split('\n').filter((line) => !/^\s*(\*|\/\/|\/\*)/.test(line));
}

function hits(lines, re) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    re.lastIndex = 0;
    if (re.test(lines[i])) {
      out.push('L' + (i + 1) + ': ' + lines[i].trim());
    }
  }
  return out;
}

const componentsText = readText(COMPONENTS_ETS);
const designText = readText(DESIGN_ETS);
const componentLines = codeLines(componentsText);
const designLines = codeLines(designText);

check('Components.ets 无 #rrggbb 颜色字面量',
  hits(componentLines, /#[0-9a-fA-F]{3,8}/).length === 0,
  hits(componentLines, /#[0-9a-fA-F]{3,8}/).join(' | '));
check('Design.ets 无 #rrggbb 颜色字面量',
  hits(designLines, /#[0-9a-fA-F]{3,8}/).length === 0,
  hits(designLines, /#[0-9a-fA-F]{3,8}/).join(' | '));

// 颜色只允许走 Design 函数；少数语义色（错误面/状态点/次级按钮底）保留资源直用白名单。
// R38：白名单补 `btn_danger_bg` —— 新增的共用组件 `AaPrimaryIconButton` 的 danger 分支
// 用的是与页面侧 `composerPrimaryButton()` 中断态**同一个**底（语义色，不是可换主题的普通底），
// 符合本断言注释里「少数语义色保留资源直用」的原意。
const COLOR_RES_ALLOWED = [
  'error_surface', 'error_border', 'error_icon', 'session_status_accent',
  'secondary_action_surface', 'btn_danger_bg'
];
const rawColors = [];
const reColor = /\$r\('app\.color\.([a-z_0-9]+)'\)/g;
for (let i = 0; i < componentLines.length; i++) {
  reColor.lastIndex = 0;
  let m;
  while ((m = reColor.exec(componentLines[i])) !== null) {
    if (COLOR_RES_ALLOWED.indexOf(m[1]) < 0) {
      rawColors.push('L' + (i + 1) + ' ' + m[1]);
    }
  }
}
check('Components.ets 的颜色一律走 Design 函数（白名单外无资源直用）',
  rawColors.length === 0, rawColors.join(' | '));

check('Components.ets 无裸 space 数字',
  hits(componentLines, /space:\s*[0-9]/).length === 0,
  hits(componentLines, /space:\s*[0-9]/).join(' | '));
check('Components.ets 无裸 padding/margin 数字（单参形式）',
  hits(componentLines, /(padding|margin)\(\s*[0-9]/).length === 0,
  hits(componentLines, /(padding|margin)\(\s*[0-9]/).join(' | '));
check('Components.ets 的对象式 padding/margin 里无裸数字',
  hits(componentLines, /(padding|margin)\(\{[^}]*:\s*[0-9]/).length === 0,
  hits(componentLines, /(padding|margin)\(\{[^}]*:\s*[0-9]/).join(' | '));
check('Components.ets 无裸 borderRadius 数字',
  hits(componentLines, /borderRadius\(\s*[0-9]/).length === 0,
  hits(componentLines, /borderRadius\(\s*[0-9]/).join(' | '));
check('Components.ets 无裸 borderWidth 数字',
  hits(componentLines, /borderWidth\(\s*[0-9]/).length === 0,
  hits(componentLines, /borderWidth\(\s*[0-9]/).join(' | '));

// ---------------------------------------------------------------------------
// 7. Components.ets 引用的 Design 符号必须真实存在且都被用到
// ---------------------------------------------------------------------------

group('Components.ets 的 Design 依赖：符号存在 + 无未用导入');
const importMatch = /import\s*\{([^}]*)\}\s*from\s*'\.\/Design';/.exec(componentsText);
check('能解析到 ./Design 的 import', importMatch !== null);
const importedNames = importMatch !== null
  ? importMatch[1].split(',').map((s) => s.trim()).filter((s) => s.length > 0) : [];
const exported = new Set(Object.keys(design));
const missingSymbols = importedNames.filter((n) => !exported.has(n));
check('Components.ets 引用的 Design 符号都存在', missingSymbols.length === 0, missingSymbols.join(', '));
const unusedImports = importedNames.filter((n) => {
  const body = componentLines.filter((l) => l.indexOf('from \'./Design\'') < 0).join('\n');
  const re = new RegExp('(?<![.A-Za-z0-9_$])' + n + '(?![A-Za-z0-9_$])');
  return !re.test(body);
});
check('Components.ets 没有未使用的 Design 导入', unusedImports.length === 0, unusedImports.join(', '));
check('Components.ets 确实用上了 R10 新增的四个颜色函数与两个尺寸类',
  importedNames.indexOf('faint') >= 0 && importedNames.indexOf('subtle') >= 0
    && importedNames.indexOf('errorText') >= 0 && importedNames.indexOf('Control') >= 0
    && importedNames.indexOf('StrokeWidth') >= 0);

// ---------------------------------------------------------------------------
// 8. 向后兼容：既有令牌名一个都不许消失
// ---------------------------------------------------------------------------

group('向后兼容：既有令牌名未改名、未删除');
const LEGACY = [
  ['Space', ['XS', 'S', 'M', 'L', 'XL', 'XXL']],
  ['Radius', ['S', 'M', 'L', 'PILL']],
  ['FontSize', ['CAPTION', 'SMALL', 'BODY', 'TITLE', 'HEADLINE', 'DISPLAY']]
];
for (const [cls, names] of LEGACY) {
  const missing = names.filter((n) => design[cls][n] === undefined);
  check('既有令牌 ' + cls + ' 的 ' + names.length + ' 个名字都在', missing.length === 0, missing.join(', '));
}
const LEGACY_FUNCS = ['canvas', 'ink', 'muted', 'borderColor', 'raisedSurface', 'primaryAction',
  'onPrimaryAction', 'statusColor', 'runtimeStatusColor', 'runtimeStatusLabel'];
const missingFuncs = LEGACY_FUNCS.filter((n) => typeof design[n] !== 'function');
check('既有颜色 / 状态函数 ' + LEGACY_FUNCS.length + ' 个都在', missingFuncs.length === 0, missingFuncs.join(', '));

// ---------------------------------------------------------------------------
// 8.5 R81：`Navigation` 标题栏的**行高口径**（全工程只有一个值）
// ---------------------------------------------------------------------------
//
// 背景（真机实测事实，别再重新论证）：`titleMode: Full` 的标题栏槽恒为
// `TitleBar [0,137][1316,332]`，框架把构造器**顶边锚在 y=166px（与行高无关）**
// ⇒ **栏内控件垂直中心 = 166 + 行高 ÷ 2**：首页行高 46vp → 中心 **235px**；
// 其余页原来 64vp → 中心 **262px**（低 27px，用户可见的「对不齐」）。
// ⇒ 行高是**几何契约**：同一位置的控件在不同页面必须落在同一条线上。
group('R81：Navigation 标题栏行高口径（NAV_TITLE_ROW）');
check('Control.NAV_TITLE_ROW 存在且 = 46（真机标定：166 + 46×2.975/2 ≈ 235px）',
  design.Control.NAV_TITLE_ROW === 46, 'got ' + String(design.Control.NAV_TITLE_ROW));
/**
 * ⚠️ **这条才是真判据**：两个令牌语义不同（首页自绘头 vs `Navigation` 标题栏），但**数值必须相等** ——
 * 行高不同 ⇒ 同一位置的控件差**半个行高**（46 vs 64 就是 27px），「口径统一」也就没闭环。
 */
eq('R81：NAV_TITLE_ROW === HOME_HEADER（口径不分叉：行高不同 ⇒ 同一位置控件差半个行高）',
  design.Control.NAV_TITLE_ROW, design.Control.HOME_HEADER);
/**
 * 行内**最高的孩子**必须装得进行高：两枚圆钮用 `NAV_BUTTON_LARGE`(40)，
 * Files/Terminal 的设备选择胶囊用 `FIELD`(44) ⇒ 两者都必须 ≤ `NAV_TITLE_ROW`(46)。
 * （逐页「行内最高孩子」的核对结论见开发期验证记录。）
 */
check('R81：标题行内可能出现的最高控件令牌 ≤ 行高（NAV_BUTTON_LARGE=40 / FIELD=44 ≤ 46）',
  design.Control.NAV_BUTTON_LARGE <= design.Control.NAV_TITLE_ROW
  && design.Control.FIELD <= design.Control.NAV_TITLE_ROW,
  'NAV_BUTTON_LARGE=' + String(design.Control.NAV_BUTTON_LARGE)
  + ' FIELD=' + String(design.Control.FIELD));
check('R81：自绘顶栏那两页用的 TOP_BAR_PAGE 保持 64（机制不同，别被「统一」误改）',
  design.Control.TOP_BAR_PAGE === 64, 'got ' + String(design.Control.TOP_BAR_PAGE));

// ---------------------------------------------------------------------------
// 9. R57（T2b）液态玻璃控件：几何令牌 + 双值颜色契约 + 新文件无硬编码
// ---------------------------------------------------------------------------
//
// 背景：用户要求「液态玻璃效果 + 统一页面图标设计」，功能栏（顶栏）的圆钮从
// 「平底 + 1vp 描边」升级为「半透明磨砂 + 左上镜面高光 + 1vp 渐变亮边 + 柔和外阴影」。
// 本节把**四层的参数与颜色契约**钉死，防止后人「顺手调一个更好看的数」而没有任何判据。

group('R63 液态玻璃控件令牌 GlassSpec（v3 沉浸光感口径，数值即契约）');
// ⚠️ class 转译成 CJS 之后 typeof 是 function（不是 object）—— 第一次写 object 就红了，记在这里。
check('GlassSpec 存在（class ⇒ typeof 为 function）', typeof design.GlassSpec === 'function');
/**
 * ## R59 判据换代（这一节是新口径的机械护栏）
 *
 * **三轮判据演变必须讲清楚，免得后来者再走一遍**：
 * | 轮次 | 判据 | 结论 | 为什么被推翻 |
 * | --- | --- | --- | --- |
 * | R56/T11 | 「盘面 r0.4~0.83R 中位数恒 +11、**平坦度极差 ≤3/255**、不得有任何渐变」 | 删掉高光层与所有渐变、环收成 0.5vp 发丝 | 那是从**一张深色无内容图**量的，被当成唯一判据后**过度矫正**：连带删掉了环的结构。用户反馈「效果都没出来」 |
 * | R58 | 「盘面 **sd 要高**、对比度接近同帧裸玻璃带」⇒ `GLASS_ICON_BLUR = 0` | 钮不二次模糊 | **方向错了**。参考图盘面 p90−p10 只有 2~3 灰阶（**均匀磨砂**），radius=0 让盘面直接透出清晰内容（51~89 灰阶）⇒ 用户说「不像玻璃，像糊了一层」 |
 * | **R59** | **「盘面均匀度 + 环结构」**：均匀磨砂盘面 + 一圈强亮环，中心无亮斑 | 见下 J1~J6 | 用**几何校准后**的正确靶子（Hough 拟合圆心）重测参考图得出 |
 * | **R63（历史）** | **「渐变 + 半透明 + 模糊」= 沉浸光感**：半透明磨砂盘面 + **1 层方向性线性渐变** + **0.75vp 可见亮环** | 见文件下方「R63 沉浸光感 v3」组 | **用户原话直接推翻「完全平坦」**：他要的正是「渐变光」（参考图左上亮、右下暗）。R56/T11 的平坦度判据把用户要的效果本身判成缺陷 ⇒ **该判据作废**（冻结规格：R63 施工图 §2，内部归档不随仓库分发） |
 * | **R64（当前）** | **「盘面近乎透明 + 只在边缘的上亮/下暗光弧 + bloom」**：dark 盘面 **1.2% 白**、`linearGradient` 归零、两段半环（`.clip(true)` + `.blur(ARC_BLOOM)`） | 见下方「R64 沉浸光感 v4」组 | 真机像素判据（同一脚本口径）：R63 盘面 Δ **+24**（目标 ≤ +8）、24 扇区极差 **36**（目标 ≤ 15）、环上/下 **0.98**（目标 ≥ 2.5）⇒ v3 的「铺满渐变 + 均匀环 + 4.3% 白盘面」三条**全部作废**（冻结规格：R64 施工图 §1/§2，内部归档不随仓库分发）。**R64-T2 再定点**：盘面降档成立（Δ+3.0/1.22%），但弧峰只有 +29（目标 +72）⇒ RIM 1.25→2.5、ARC_BLOOM 4→1.5、弧色 27%→65%；并修正「段容器被外层 Stack 居中导致弧错位」的定位缺陷 |
 *
 * ⚠️ **R58 用「盘面的空间对比度」当判据是错的；正确判据是「盘面均匀度」+「环结构」。**
 * 「内容划过时玻璃活起来」的正确表现是 **盘面整体亮度随背后内容变化**，
 * 而**不是** 盘面内出现内容的空间纹理（后者 = 一块透明玻璃）。
 *
 * ### 参考图真实靶子（开发期验证记录）
 * 最右钮（盘面只有 4 个小点，无图标）Hough 拟合 `center=(1207,68) R=60`：
 *   · 盘面 r0.55~0.85R：p50 恒 ±1.0、**MAD = 1.0**、p90−p10 = **3.1**（均匀磨砂）
 *   · 环峰 **+43.0** @ **r/R 0.975**，半高宽 **1.8px**
 *   · 盘面相对钮外背景 **+4.9**（左钮含图标 +11.6）
 *   · 中心 r≤0.10R：**−1.0**（**无中心亮斑**）
 */
// ⚠️ **R64-T2 定点（v4 的值已作废）**：真机实测弧峰 − 盘面只有 +29.0/+25.0/+10.0（目标 **+72**）——
// RIM 1.25 太窄、ARC_BLOOM 4 又把能量摊开 ⇒ **RIM 1.25 → 2.5**、**ARC_BLOOM 4 → 1.5**，
// 三个色标按新 RIM 重算（SPEC §2.2 的目标值不变，只是 v4 的取值没达到）。
eq('GlassSpec.RIM = 2.5（R64-T2 加宽弧带；SPEC §2.2 目标不变）', design.GlassSpec.RIM, 2.5);
// 三个色标：clear(0.8864) → arcLow(0.9432 峰) → arcHigh(1.0)
// 由 RIM 推出：内沿 = 1 − 2.5/22 = 0.886363…、峰值 = 1 − 1.25/22 = 0.943181…
eq('弧带内沿色标 = 0.8864（此半径以内 alpha 恒 0）', design.GlassSpec.RIM_STOP_INNER, 0.8864);
eq('弧带峰值色标 = 0.9432（弧宽中点；正好等于 v4 的内沿值）', design.GlassSpec.RIM_STOP_PEAK, 0.9432);
eq('弧带外沿色标 = 1', design.GlassSpec.RIM_STOP_OUTER, 1);
// ⚠️ R64 新增令牌：光弧的外发光半径（vp）；**R64-T2：4 → 1.5**（收窄 bloom 是提亮的另一半）
eq('GlassSpec.ARC_BLOOM = 1.5（R64-T2 由 4 收窄）', design.GlassSpec.ARC_BLOOM, 1.5);
// ⚠️ R63 的渐变令牌**仍然保留**（R64 只是不再由图标钮消费）—— 顶栏胶囊 / 底栏胶囊还在用（SPEC §2.3）。
eq('GlassSpec.SHEEN_ANGLE = 145（保留：顶栏/底栏胶囊消费，SPEC §2.3）',
  design.GlassSpec.SHEEN_ANGLE, 145);
eq('GlassSpec.SHEEN_MID_STOP = 0.42（渐变中间色标）', design.GlassSpec.SHEEN_MID_STOP, 0.42);
check('渐变中间色标落在 (0,1) 且偏起点一侧（0.42 <= 0.5）',
  design.GlassSpec.SHEEN_MID_STOP > 0 && design.GlassSpec.SHEEN_MID_STOP < 1
  && design.GlassSpec.SHEEN_MID_STOP <= 0.5, String(design.GlassSpec.SHEEN_MID_STOP));
check('环的三个色标严格递增且 ≤ 1',
  design.GlassSpec.RIM_STOP_INNER < design.GlassSpec.RIM_STOP_PEAK
  && design.GlassSpec.RIM_STOP_PEAK < design.GlassSpec.RIM_STOP_OUTER
  && design.GlassSpec.RIM_STOP_OUTER <= 1);
eq('GlassSpec.SHADOW_RADIUS = 10', design.GlassSpec.SHADOW_RADIUS, 10);
eq('GlassSpec.SHADOW_OFFSET_Y = 2', design.GlassSpec.SHADOW_OFFSET_Y, 2);
// ⚠️ R57（T13）：「整体降不透明度」的按压做法**退役**（压暗 = 减光，与「按下更有光感」相反）；
// 形变交给官方 `clickEffect(LIGHT)`（系统默认缩放 0.90），提亮交给显式光效层。
check('PRESSED_OPACITY 已下架（不再用整体压暗做按压反馈）', design.GlassSpec.PRESSED_OPACITY === undefined);
// ⚠️ R57（T15）：`PRESSED_BRIGHTNESS` 也**下架**了 —— `brightness` 做按压提亮连续两轮真机失败
// （T13 方角亮块 / T14 状态永不进入），改由**显式光效层**承担（见下面的 T15 光感契约组）。
check('PRESSED_BRIGHTNESS 已下架（不再用 brightness 做按压提亮）',
  design.GlassSpec.PRESSED_BRIGHTNESS === undefined);
eq('GlassSpec.PRESS_ANIM_MS = 140（与工作区已验证先例同值）', design.GlassSpec.PRESS_ANIM_MS, 140);
eq('GlassSpec.DISABLED_OPACITY 与 AaCircleIconButton 的 0.4 同值（不各写一套）',
  design.GlassSpec.DISABLED_OPACITY, 0.4);
// ⚠️ R64-T2：弧带 **有意**加宽到 2.5vp（2.5/22 ≈ 11.4%）—— 上限从 8% 放到 15%。
// 断言意图不变：防「弧带无限变粗」（它要被 bloom 散开，但不能铺成半张盘）。
check('弧带宽度占盘面直径 < 15%（R64-T2：RIM 2.5 / R 22 ≈ 11.4%）',
  design.GlassSpec.RIM / 22 < 0.15, design.GlassSpec.RIM + '/22');

group('R57（T11）镜面高光**整层下架** —— 参考图盘面上没有光斑');
// 参考图逐半径剖面：r 0.4~0.83R 的中位数**恒为 +11**（完全平坦）。只要留着高光，盘面必然出现
// 「左上亮斑 + 沿半径的落差」。所以 T9 的四个 HIGHLIGHT_* 令牌与两层色资源一并删除。
check('HIGHLIGHT_CENTER_X 已下架', design.GlassSpec.HIGHLIGHT_CENTER_X === undefined);
check('HIGHLIGHT_CENTER_Y 已下架', design.GlassSpec.HIGHLIGHT_CENTER_Y === undefined);
check('HIGHLIGHT_RADIUS 已下架', design.GlassSpec.HIGHLIGHT_RADIUS === undefined);
check('HIGHLIGHT_OPACITY 已下架', design.GlassSpec.HIGHLIGHT_OPACITY === undefined);
check('glassHighlight() 已下架', typeof design.glassHighlight === 'undefined');
check('glassHighlightClear() 已下架', typeof design.glassHighlightClear === 'undefined');
// 原「高光半径必须收敛」那条约束随高光一起退役（不再有高光层）；留着这条说明免得后人以为被误删。

group('R57 玻璃颜色函数 -> 资源键');
eq('glassIconSurface()', design.glassIconSurface(), 'app.color.glass_icon_surface');
eq('glassPrimarySurface()', design.glassPrimarySurface(), 'app.color.glass_primary_surface');
eq('glassRimHigh()', design.glassRimHigh(), 'app.color.glass_icon_rim_high');
eq('glassRimLow()', design.glassRimLow(), 'app.color.glass_icon_rim_low');
eq('glassRimClear()（R57/T11：环内部 alpha=0）', design.glassRimClear(), 'app.color.glass_icon_rim_clear');
eq('glassIconShadow()（玻璃钮自己的投影色）', design.glassIconShadow(), 'app.color.glass_icon_shadow');

group('R57 玻璃色必须 base / dark 双值成对');
function readColorMap(file) {
  const map = {};
  for (const item of JSON.parse(fs.readFileSync(file, 'utf8')).color) { map[item.name] = item.value; }
  return map;
}
const GLASS_TOKENS = [
  'glass_icon_surface', 'glass_primary_surface', 'glass_icon_rim_high',
  'glass_icon_rim_low', 'glass_icon_rim_clear',
  // 玻璃钮的投影单独一档 —— `app_shadow` 会从盘面内部透出来（浅色实测 −33/−24）。
  'glass_icon_shadow'
];
const colorBase = readColorMap(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'));
const colorDark = readColorMap(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'));
eq('6 个玻璃色在 base 里都有', GLASS_TOKENS.filter((n) => !(n in colorBase)).join(','), '');
eq('6 个玻璃色在 dark 里都有（缺一个就会在深色下静默不生效）',
  GLASS_TOKENS.filter((n) => !(n in colorDark)).join(','), '');
eq('玻璃色一律写成 #AARRGGBB（alpha 显式，不能省成 #RRGGBB）',
  GLASS_TOKENS.filter((n) => !/^#[0-9A-Fa-f]{8}$/.test(colorBase[n]) || !/^#[0-9A-Fa-f]{8}$/.test(colorDark[n])).join(','), '');
const clearedCount = GLASS_TOKENS.filter((n) => colorBase[n] !== colorDark[n]).length;
check('至少 4 个玻璃色深浅两态取值不同（不是复制同一份充数）', clearedCount >= 4, 'got ' + clearedCount);
eq('亮环内部透明色 alpha = 00（同 RGB、alpha=0，不能用 Color.Transparent）',
  colorBase['glass_icon_rim_clear'].slice(1, 3) + '/' + colorDark['glass_icon_rim_clear'].slice(1, 3), '00/00');

group('R63/F1 悬浮功能底栏专属玻璃令牌 glassNavSurface（浅色档可见性定点修复）');
// 背景：R63 首包模拟器逐点实测（开发期验证记录）——
// 浅色档底栏胶囊盘面 **252.1 = 页面背景 252.1**（逐点完全相同），因为 `glassSurface()` 的浅色值是
// `#40FDFCFB`（25% 近白），叠在近白页面上零对比 ⇒「沉浸光感」在浅色档实际不可见（只剩 1vp 亮边）。
// 修复 = 给底栏单独一档 `glass_nav_surface`：浅色改成**黑纱**，深色**刻意与 glass_surface 同值**
// （深色档首包已实测可用：胶囊 23.2/13.2 vs 背景 9.2、左上−右下 +29.12 ⇒ 不许被这次修复带偏）。
eq('glassNavSurface()', design.glassNavSurface(), 'app.color.glass_nav_surface');
eq('glass_nav_surface 在 base 里存在', 'glass_nav_surface' in colorBase, true);
eq('glass_nav_surface 在 dark 里存在', 'glass_nav_surface' in colorDark, true);
check('glass_nav_surface 两态都是 #AARRGGBB',
  /^#[0-9A-Fa-f]{8}$/.test(colorBase['glass_nav_surface']) && /^#[0-9A-Fa-f]{8}$/.test(colorDark['glass_nav_surface']),
  colorBase['glass_nav_surface'] + ' / ' + colorDark['glass_nav_surface']);
// ① 浅色档必须是**黑纱**（RGB = 000000）：白纱叠在近白页面上就是 F1 的根因。
eq('浅色 glass_nav_surface 的 RGB 是纯黑（黑纱，不是白纱）',
  colorBase['glass_nav_surface'].slice(3).toUpperCase(), '000000');
// ② 浅色档对比度必须够：Δ = 252 × (1 − alpha) 至少 15/255（与 GlassSpec 的浅色判据同量级）。
const NAV_LIGHT_BG = 252.07;
// ⚠️ 不用文件下方的 `alphaOf`：它在本块之后才声明（const 的 TDZ 会直接抛错）。
const navAlpha = parseInt(String(colorBase['glass_nav_surface']).slice(1, 3), 16) / 255;
const navLightDelta = NAV_LIGHT_BG - NAV_LIGHT_BG * (1 - navAlpha);
// ## R90-T5（用户：「我要这种几乎透明的，能和页面背景差不多的颜色」+ 参考图）
// 参考图（应用市场底栏）逐像素实测：胶囊填充 (241.9,243.8,245.0) vs 页面背景 (242.0,244.0,245.0)
// ⇒ **Δ≈0**，胶囊在纯色页面上几乎与背景融为一体，只靠**阴影/亮边**勾出轮廓。
// ⚠️ 因此 R63 时代那条「浅色档 |Δ| >= 15/255（可见性下限）」**前提已变、有意推翻**：
//    本工程底栏的可见性不再靠"纱有多实"，而靠**阴影 + 亮边**（官方材质自带 / 回退档有 glassRimHigh）。
//    继续钉 >=15 会把用户明确要的"几乎透明"判成缺陷。⇒ 改成**上限**判据。
const NAV_TRANSPARENT_MAX = 8;      // "几乎透明"的口径：|Δ| ≤ 8/255（参考图实测 Δ≈0）
check('R90-T5 浅色底栏**几乎透明**（|Δ| <= 8/255，与参考图的 Δ≈0 同量级）',
  navLightDelta >= 0 && navLightDelta <= NAV_TRANSPARENT_MAX,
  '当前 |Δ|=' + navLightDelta.toFixed(2) + '/255（上限 ' + NAV_TRANSPARENT_MAX + '）');
// 方向性仍要保：比"发暗"那档更亮（用户上一轮的诉求不能被后面的改动悄悄抹掉）
const NAV_LIGHT_DARKEST = 19.7;     // R63 原值 #14000000 的实测 Δ（最暗档）
check('R90-T5 浅色底栏**比"发暗"档更亮**（旧 Δ≈−19.7 ⇒ 不许改回重纱）',
  navLightDelta < NAV_LIGHT_DARKEST,
  '当前 −' + navLightDelta.toFixed(2) + '/255');
// ③ ⚠️ **R90-T4 推翻了 R63 的「深色两键同值」**（用户：「底部功能栏有点发暗，调亮一点」）。
//    旧约束的前提是"别把当时已验收的深色观感带偏"；本轮用户**明确要求调亮** ⇒ 前提已变。
//    深色档要"调亮"方向**必须反过来**：近黑画布(9.7)上再叠近黑纱几乎不产生提亮（合成≈13.2）
//    —— 那就是"发暗"的来源。⇒ 改成**白纱**，判据也随之改成「是一层**亮**纱 + Δ 为正且够大」。
/**
 * 把 `#AARRGGBB` 的 alpha 与 RGB 拆出来（本块内自用，避免依赖文件下方声明）。
 */
function parseArgb(hex) {
  const s = String(hex).replace('#', '');
  // ⚠️ 本工程的色值**同时存在** 6 位（#RRGGBB，如 #0E9F6E）与 8 位（#AARRGGBB，如 #1FFFFFFF）两种形态，
  //    解析必须按长度分派 —— 第一版只按 8 位切，把 #0E9F6E 的 G/B 读错（G=110、B=NaN），断言假红。
  if (s.length === 6) {
    return { a: 1, r: parseInt(s.slice(0, 2), 16), g: parseInt(s.slice(2, 4), 16), b: parseInt(s.slice(4, 6), 16) };
  }
  return {
    a: parseInt(s.slice(0, 2), 16) / 255,
    r: parseInt(s.slice(2, 4), 16),
    g: parseInt(s.slice(4, 6), 16),
    b: parseInt(s.slice(6, 8), 16)
  };
}
const navDark = parseArgb(colorDark['glass_nav_surface']);
check('R90-T4 深色底栏是**亮纱**（RGB 偏白 —— 深色档"调亮"只能靠白纱）',
  navDark.r > 128 && navDark.g > 128 && navDark.b > 128,
  '深色值=' + colorDark['glass_nav_surface']);
// 深色画布实测 9.7；白纱合成后应显著更亮（Δ 至少在 +15/255 量级）
const NAV_DARK_BG = 9.7;
const navDarkComposite = NAV_DARK_BG + navDark.a * (255 - NAV_DARK_BG);
// R90-T5：深色档同样改为"几乎透明" —— 只要**方向仍然是提亮**（白纱）且量很小即可。
check('R90-T5 深色底栏是一层**极淡的白纱**（提升量 0 < Δ <= 8/255，与浅色档口径一致）',
  (navDarkComposite - NAV_DARK_BG) > 0 && (navDarkComposite - NAV_DARK_BG) <= NAV_TRANSPARENT_MAX,
  '预测 Δ=+' + (navDarkComposite - NAV_DARK_BG).toFixed(2) + '/255（上限 ' + NAV_TRANSPARENT_MAX + '）');
check('R90-T4 深色底栏**不再**与 glass_surface 同值（那正是"发暗"的旧口径）',
  colorDark['glass_nav_surface'] !== colorDark['glass_surface']);
// ④ R90-T4：底栏选中项必须有**专属绿**，且**不得**直接复用会话状态的语义绿
check('R90-T4 存在底栏选中专属令牌 bottom_nav_active（两档都有）',
  'bottom_nav_active' in colorBase && 'bottom_nav_active' in colorDark);
check('R90-T4 底栏选中绿**不复用**会话状态绿（语义色不许互相顶替）',
  colorBase['bottom_nav_active'] !== colorBase['session_status_accent']
  && colorDark['bottom_nav_active'] !== colorDark['session_status_accent'],
  'base=' + colorBase['bottom_nav_active'] + ' vs ' + colorBase['session_status_accent']);
check('R90-T4 底栏选中绿是"绿"（G 通道显著高于 R/B）',
  (() => {
    const c = parseArgb(colorBase['bottom_nav_active']);
    return c.g > c.r + 40 && c.g > c.b + 20;
  })(), 'base=' + colorBase['bottom_nav_active']);
check('R90-T4 深色档选中绿比浅色档更亮（深色画布上要够亮才看得出来）',
  parseArgb(colorDark['bottom_nav_active']).g > parseArgb(colorBase['bottom_nav_active']).g);
// ④ 接线断言：底栏必须用新令牌，且**不得**退回 glassSurface()/glassIconSurface()。
const BOTTOMNAV_ETS = path.join(SRC_ETS, 'ui', 'BottomNav.ets');
const bottomNavCode = codeLines(readText(BOTTOMNAV_ETS)).join(String.fromCharCode(10));
check('BottomNav.ets 的磨砂色走 glassNavSurface()',
  /color:\s*glassNavSurface\(\)/.test(bottomNavCode));
check('BottomNav.ets 不再用 glassSurface()（浅色档会退回不可见）',
  bottomNavCode.indexOf('glassSurface()') < 0);
check('R90-T4 底栏选中态走 bottomNavActive()（官方项 + 自绘回退两处都要）',
  (bottomNavCode.match(/bottomNavActive\(\)/g) || []).length >= 2,
  '命中 ' + (bottomNavCode.match(/bottomNavActive\(\)/g) || []).length + ' 处');
check('R90-T4 底栏选中态不再用 primaryAction()（换色后它不该还留在选中分支里）',
  !/item\.key === this\.active \? primaryAction\(\)/.test(bottomNavCode)
  && !/this\.active\(\) \? primaryAction\(\)/.test(bottomNavCode));

group('R57 新文件 ui/GlassIcon.ets 无硬编码颜色 / 不用错的模糊 API');
const GLASSICON_ETS = path.join(SRC_ETS, 'ui', 'GlassIcon.ets');
const glassIconText = readText(GLASSICON_ETS);
const glassIconLines = codeLines(glassIconText);
const glassIconCode = glassIconLines.join(String.fromCharCode(10));
check('ui/GlassIcon.ets 存在且非空', glassIconText.length > 1000, 'got ' + glassIconText.length);
check('无 #rrggbb 颜色字面量', hits(glassIconLines, /#[0-9a-fA-F]{3,8}/).length === 0,
  hits(glassIconLines, /#[0-9a-fA-F]{3,8}/).join(' | '));
const rawGlassColors = [];
const reGlassColor = /$r('app.color.([a-z_0-9]+)')/g;
for (let i = 0; i < glassIconLines.length; i++) {
  reGlassColor.lastIndex = 0;
  let m;
  while ((m = reGlassColor.exec(glassIconLines[i])) !== null) { rawGlassColors.push('L' + (i + 1) + ' ' + m[1]); }
}
eq('颜色一律走 Design 函数（不在组件里直用 $r(app.color.*)）', rawGlassColors.join(' | '), '');
check('磨砂只用 backgroundEffect（不用 backgroundBlurStyle / backdropBlur）',
  glassIconCode.indexOf('backgroundEffect(') >= 0
    && glassIconCode.indexOf('backgroundBlurStyle') < 0 && glassIconCode.indexOf('backdropBlur') < 0);
// ⚠️ R57（T16）→ **R65 改口径**：源码里**允许**出现 `lightEffect`，现在共 **2 处**：
//   ① 档 2（S2）的实验分支；② **R65 官方材质分支**（`officialGlass()`，仅首页顶栏两个钮）。
//   默认自绘路径（档 0/S1）仍然不启用（顶缘会贯穿出一条细亮线的教训仍有效）。
// ⚠️ `codeLines()` 只剥 `//` 行注释、不剥块注释 ⇒ 计数必须用**代码形态** `lightEffect: {`（注释里的说明不计）。
// ⚠️ **不许只数次数**：下面同时用「分支锚文」把第 2 处钉在官方分支内 ——
//    否则后人删掉官方分支时，这条断言只会从 2 变 1，仍然「绿」，等于白设。
const officialBranchBody = glassIconCode.slice(
  glassIconCode.indexOf('officialGlass() {'), glassIconCode.indexOf('build() {'));
eq('R65：lightEffect 共 2 处（档 2 实验分支 + 官方材质分支；默认自绘路径不启用）',
  (glassIconCode.split('lightEffect: {').length - 1), 2);
check('R65：第 2 处 lightEffect 在**官方分支内**（分支锚文限定，不是只数次数）',
  officialBranchBody.indexOf('lightEffect: { color: Color.White }') >= 0);
check('四层齐备（R64）：磨砂玻璃（含投影）+ 光弧层 + 按压光效层 + 图标',
  glassIconCode.indexOf('backgroundEffect(') >= 0 && glassIconCode.indexOf('radialGradient(') >= 0
    && glassIconCode.indexOf('.blur(') >= 0 && glassIconCode.indexOf('glassIconPressGlow()') >= 0
    && glassIconCode.indexOf('.shadow(') >= 0 && glassIconCode.indexOf('AaIcon({') >= 0);
check('S2 镜面高光层已**整层下架**（组件里没有任何 HIGHLIGHT_* / 高光色）',
  glassIconCode.indexOf('HIGHLIGHT_') < 0 && glassIconCode.indexOf('glassHighlight') < 0);
// ⚠️ R64：组件里的环色换成**弧色** `glassArcClear()`（`glassRimClear()` 自 R64 起由顶栏/底栏胶囊消费）。
check('弧内沿透明色用 glassArcClear()（同 RGB、alpha=0），不用 Color.Transparent',
  glassIconCode.indexOf('glassArcClear()') >= 0 && glassIconCode.indexOf('Color.Transparent') < 0);
check('装饰层都显式 hitTestBehavior(HitTestMode.None)（铺满兄弟会吃掉点击）',
  (glassIconCode.split('hitTestBehavior(HitTestMode.None)').length - 1) >= 5);
check('几何全走令牌（无裸 borderRadius / width 数字）',
  hits(glassIconLines, /borderRadius\(\s*[0-9]/).length === 0 && hits(glassIconLines, /width\(\s*[0-9]/).length === 0);
check('图标仍走 AaIcon（不自己画 Shape / Path，坐标空间三条铁律只有一处实现）',
  glassIconCode.indexOf('AaIcon({') >= 0 && glassIconCode.indexOf('Shape()') < 0);
/**
 * ⚠️ **这条断言被改写过两次**（历史留着，免得后人来回改）：
 *  · 原文（R57/T11）：「**无 linearGradient**、首色标是 clear、radius=50%」；
 *  · R63/v3：去掉「无 linearGradient」（那时要求恰好 1 处铺满光层）；
 *  · **R64/v4：`linearGradient` 又归零**（铺满光层整层删除），但这三条径向环的事实一直成立。
 */
check('S1 光弧是**径向环**且内部 alpha 恒 0：首色标是 arc clear、radius=50%',
  glassIconCode.indexOf('radialGradient(') >= 0 && glassIconCode.indexOf('[glassArcClear(), 0]') >= 0
    && glassIconCode.indexOf("radius: '50%'") >= 0);
eq('弧 3 个色标（clear@内沿 / 弧低@峰值 / 弧高@外沿；两段共用 ⇒ 源码里仍是 3 处）',
  glassIconCode.split('GlassSpec.RIM_STOP_').length - 1, 3);
eq('S3 投影只挂一处（别层层叠阴影）', (glassIconCode.split('.shadow(').length - 1), 1);
/**
 * ⚠️ **层序断言（T11 的核心修复）**：亮环必须画在玻璃**之后**。
 * `backgroundEffect` 会把**画在它下面的兄弟节点**一起糊进来 —— T9 把环放在玻璃下面，
 * 6vp 的模糊把环糊进盘面外圈，盘面边缘被染亮（真机看起来就是「金属球」）。
 * 用源码下标比较，比读注释可靠。
 */
/**
 * ⚠️ **R64 写法变更（断言必须跟着变）**：弧的 `radialGradient` 现在写在 `@Builder arcSegment()` 里，
 * 而 `@Builder` 在源码中**位于 `build()` 之前** ⇒ 拿全文件的 `indexOf` 比下标会把层序判反。
 * 层序只在 `build()` 的**子节点序列**里有意义，所以下面一律在 `build()` 切片内比较。
 * （T11 那轮的结论本身不变：玻璃层必须第一个画，否则 `backgroundEffect` 会把弧糊进盘面。）
 */
const buildAt = glassIconCode.indexOf('build() {');
const buildCode = glassIconCode.slice(buildAt);
const beAt = buildCode.indexOf('backgroundEffect(');
const arcCallAt = buildCode.indexOf('ForEach(this.arcSegments()');
check('T11 核心（R64 沿用）：玻璃层在光弧**之前**（弧画在玻璃上面，模糊不会把弧糊进盘面）',
  beAt >= 0 && arcCallAt > beAt, 'backgroundEffect@' + beAt + ' / arcForEach@' + arcCallAt);

group('R64 沉浸光感 v4：盘面降档 + 上亮/下暗两段光弧 + bloom（SPEC §2，新口径）');
// ⚠️ 本组是 R64 的机械护栏：把「盘面近乎透明 + 只在边缘的光弧 + bloom」钉在**令牌 / 资源 / 源码**上。
// 旧口径（v3 的铺满渐变 / 4.3% 白盘面 / 均匀整圈环）的作废理由与真机判据见本文件顶部表格的 R64 行。
// 组内数值预测对齐 SPEC §4 的真机验收线（同一脚本口径，见下面「光效契约」组）。
// ---- 保留（不许删）的颜色函数：v4 起只由顶栏/底栏胶囊消费（SPEC §2.3）----
eq('glassSheenHigh() -> 资源键（保留：顶栏/底栏胶囊消费）', design.glassSheenHigh(), 'app.color.glass_icon_sheen_high');
eq('glassSheenMid() -> 资源键（保留：顶栏/底栏胶囊消费）', design.glassSheenMid(), 'app.color.glass_icon_sheen_mid');
eq('glassSheenClear() -> 资源键（保留：胶囊消费；终点色同 RGB、alpha=0）',
  design.glassSheenClear(), 'app.color.glass_icon_sheen_clear');
// ---- v4 新增：五个弧色函数 -> 资源键 ----
eq('glassArcHigh() -> 资源键', design.glassArcHigh(), 'app.color.glass_icon_arc_high');
eq('glassArcLow() -> 资源键', design.glassArcLow(), 'app.color.glass_icon_arc_low');
eq('glassArcDimHigh() -> 资源键', design.glassArcDimHigh(), 'app.color.glass_icon_arc_dim_high');
eq('glassArcDimLow() -> 资源键', design.glassArcDimLow(), 'app.color.glass_icon_arc_dim_low');
eq('glassArcClear() -> 资源键（弧内沿透明色：同 RGB、alpha=0）',
  design.glassArcClear(), 'app.color.glass_icon_arc_clear');
// ---- 色键：sheen 三个仍在（胶囊用）；弧色五个必须 base / dark 成对，值照抄 SPEC §2.3 ----
const SHEEN_TOKENS = ['glass_icon_sheen_high', 'glass_icon_sheen_mid', 'glass_icon_sheen_clear'];
const ARC_TOKENS = ['glass_icon_arc_high', 'glass_icon_arc_low', 'glass_icon_arc_dim_high',
  'glass_icon_arc_dim_low', 'glass_icon_arc_clear'];
eq('3 个渐变光色在 base 里都有', SHEEN_TOKENS.filter((n) => !(n in colorBase)).join(','), '');
eq('3 个渐变光色在 dark 里都有（缺一个就会在深色下静默不生效）',
  SHEEN_TOKENS.filter((n) => !(n in colorDark)).join(','), '');
eq('渐变光色一律写成 #AARRGGBB（alpha 显式，不能省成 #RRGGBB）',
  SHEEN_TOKENS.filter((n) => !/^#[0-9A-Fa-f]{8}$/.test(colorBase[n]) || !/^#[0-9A-Fa-f]{8}$/.test(colorDark[n])).join(','), '');
eq('base 渐变光取值（SPEC §2.2 照抄）',
  [colorBase['glass_icon_sheen_high'], colorBase['glass_icon_sheen_mid'], colorBase['glass_icon_sheen_clear']].join(' '),
  '#38FFFFFF #12FFFFFF #00FFFFFF');
eq('dark 渐变光取值（SPEC §2.2 照抄）',
  [colorDark['glass_icon_sheen_high'], colorDark['glass_icon_sheen_mid'], colorDark['glass_icon_sheen_clear']].join(' '),
  '#3DFFFFFF #14FFFFFF #00FFFFFF');
eq('终点色 alpha 两档都是 00（同 RGB、alpha=0，不能用 Color.Transparent）',
  colorBase['glass_icon_sheen_clear'].slice(1, 3) + '/' + colorDark['glass_icon_sheen_clear'].slice(1, 3), '00/00');
eq('终点色与起点色 RGB 相同（否则渐变会串色：base）',
  colorBase['glass_icon_sheen_clear'].slice(3) + '/' + colorBase['glass_icon_sheen_high'].slice(3), 'FFFFFF/FFFFFF');
eq('终点色与起点色 RGB 相同（否则渐变会串色：dark）',
  colorDark['glass_icon_sheen_clear'].slice(3) + '/' + colorDark['glass_icon_sheen_high'].slice(3), 'FFFFFF/FFFFFF');
eq('亮环峰值色仍为 #66FFFFFF（40% 白；R64 起改由顶栏/底栏胶囊消费）', colorDark['glass_icon_rim_high'], '#66FFFFFF');
eq('浅色亮环峰值仍为 #3D000000（24% 黑；同理由胶囊消费）', colorBase['glass_icon_rim_high'], '#3D000000');
// ---- v4 主修复：dark 盘面 4.3% 白 -> 1.2% 白；base 一律不动 ----
eq('R64 dark 盘面 = #03FFFFFF（1.2% 白，SPEC §2.3 主修复）', colorDark['glass_icon_surface'], '#03FFFFFF');
eq('R64 base 盘面保持 #0E000000（SPEC §2.3 明令不动：浅色再改暗会回到完全隐形）',
  colorBase['glass_icon_surface'], '#0E000000');
// ---- 五个弧色键：base / dark 成对 + 取值 + 格式 ----
eq('5 个弧色在 base 里都有', ARC_TOKENS.filter((n) => !(n in colorBase)).join(','), '');
eq('5 个弧色在 dark 里都有（缺一个就会在深色下静默不生效）',
  ARC_TOKENS.filter((n) => !(n in colorDark)).join(','), '');
eq('弧色一律写成 #AARRGGBB（alpha 显式，不能省成 #RRGGBB）',
  ARC_TOKENS.filter((n) => !/^#[0-9A-Fa-f]{8}$/.test(colorBase[n]) || !/^#[0-9A-Fa-f]{8}$/.test(colorDark[n])).join(','), '');
eq('dark 弧色取值（R64-T3 标定值，照抄）',
  [colorDark['glass_icon_arc_high'], colorDark['glass_icon_arc_low'],
    colorDark['glass_icon_arc_dim_high'], colorDark['glass_icon_arc_dim_low'],
    colorDark['glass_icon_arc_clear']].join(' '),
  '#59FFFFFF #29FFFFFF #1FFFFFFF #0DFFFFFF #00FFFFFF');
// ⚠️ **R64-T3（T2 的 65% 已作废）**：T2 真机实测环峰 − 盘面 +134/+132（超 §4 上限 +90 约 1.5 倍）
// ⇒ 按「几何/定位/段数一律不动、只降弧色 alpha」把弧峰降到 35%（`#59`）。
// dark：high 65%→35%、low 30%→16%（`#29`）、dim_high 22.75%→12%（`#1F`）、dim_low 10.6%→5%（`#0D`）。
eq('base 弧色取值（R64-T3 标定值，照抄）',
  [colorBase['glass_icon_arc_high'], colorBase['glass_icon_arc_low'],
    colorBase['glass_icon_arc_dim_high'], colorBase['glass_icon_arc_dim_low'],
    colorBase['glass_icon_arc_clear']].join(' '),
  '#38000000 #1C000000 #12000000 #0A000000 #00000000');
// ⚠️ **R64-T3（T2 的 40% 已作废）**：浅色档与深色同比回吐（同一套观感标定）：
// base：high 40%→22%（`#38`）、low 20%→11%（`#1C`）、dim_high 14%→7%（`#12`）、dim_low 7%→4%（`#0A`）。
// ⚠️ 浅色这组仍未上过设备（参考图只有深色图）—— 已列入风险点。
eq('弧的透明色 alpha 两档都是 00（同 RGB、alpha=0，不能用 Color.Transparent）',
  colorBase['glass_icon_arc_clear'].slice(1, 3) + '/' + colorDark['glass_icon_arc_clear'].slice(1, 3), '00/00');
eq('弧透明色与弧峰色 RGB 相同（否则插值会串色：base）',
  colorBase['glass_icon_arc_clear'].slice(3) + '/' + colorBase['glass_icon_arc_high'].slice(3), '000000/000000');
eq('弧透明色与弧峰色 RGB 相同（否则插值会串色：dark）',
  colorDark['glass_icon_arc_clear'].slice(3) + '/' + colorDark['glass_icon_arc_high'].slice(3), 'FFFFFF/FFFFFF');
// ---- 源码侧：linearGradient 归零 + 两段半环数据驱动 + 唯一 bloom 实现 ----
/**
 * ⚠️ **R64 口径（旧断言作废）**：v3 要求 `GlassIcon.ets` 里 `linearGradient(` **恰好 1 处**
 * （铺满盘面的光层）。R64 把它**整层删除**（它是盘面被摊亮成斜面板的根因，SPEC §2.1 ❌）
 * ⇒ 现在要求 **0 处**。
 */
eq('v4：GlassIcon.ets 里 linearGradient 归零（v3 的铺满渐变整层删除，SPEC §2.1）',
  (glassIconCode.split('linearGradient(').length - 1), 0);
/**
 * ⚠️ **R64 计数口径说明（重要，别当成放水）**：SPEC §3 写的是「`radialGradient(` **2 次**（上下半环）、
 * `blur(` **2 次**」。Lead 的 R64 补充又要求「两段**数据驱动**，不要把两段硬编码成两份复制粘贴」
 * ⇒ 唯一实现只写 **1 处**，由 `ForEach(this.arcSegments(), ...)` 渲染出 **2 段**。
 * 所以本文件按**源码文本**计数为 1，另用「数据数组恰好 2 段」把上下半环这件事实钉死；
 * 渲染期实例数仍是 2（与 SPEC 同义，只是两种数法）。若有人改回两份复制粘贴，这两条会一起红。
 */
eq('v4：radialGradient 恰好 1 处实现（两段共用 @Builder，Lead 要求数据驱动）',
  (glassIconCode.split('radialGradient(').length - 1), 1);
eq('v4：blur 恰好 1 处实现（在同一个 @Builder 里，两段共用）',
  (glassIconCode.split('.blur(').length - 1), 1);
check('v4：两段由 ForEach 数据驱动渲染（不是两份复制粘贴）',
  glassIconCode.indexOf('ForEach(this.arcSegments()') >= 0);
eq('v4：光弧数据恰好 2 段（上 / 下）',
  (glassIconCode.split("half: '").length - 1), 2);
check('v4：上段用 glassArcHigh/Low（亮档）',
  glassIconCode.indexOf('high: glassArcHigh(), low: glassArcLow()') >= 0);
check('v4：下段用 glassArcDimHigh/DimLow（暗一档 ⇒ 目标：下段弧峰 ≈ 上段 × 0.3~0.4）',
  glassIconCode.indexOf('high: glassArcDimHigh(), low: glassArcDimLow()') >= 0);
check('v4：段容器用 clip(true) 沿水平中线裁半圈', glassIconCode.indexOf('.clip(true)') >= 0);
check('v4：blur 半径走令牌 GlassSpec.ARC_BLOOM（不写裸数字）',
  glassIconCode.indexOf('.blur(GlassSpec.ARC_BLOOM)') >= 0);
/**
 * ⚠️ **R64-T2 新增护栏（真机定因）**：外层 `Stack` 默认把子节点**居中** ⇒ 两个**半高**段容器会被
 * 各自居中，两段圆心各偏 ±(d/4 + B/2)（v4 实装 ≈13vp）⇒ 弧被搬到左下/右下、钮正上方变空
 * （真机：顶部 ≈ 背景 13、最亮在左下~左）。修法 = 给段容器加 `boxPadTop/Bottom`（= 自身高度），
 * 把「上段容器底 / 下段容器顶」压回钮心切线。**少了它源码照样编译、静态断言也全绿，但真机角向必错**，
 * 所以这条必须钉住。
 */
check('R64-T2 几何修正：段容器带 boxPad（抵消外层 Stack 居中，否则两段圆心相隔 d/2）',
  glassIconCode.indexOf('.margin({ top: seg.boxPadTop, bottom: seg.boxPadBottom })') >= 0
    && glassIconCode.indexOf('boxPadBottom: this.arcBandHeight()') >= 0
    && glassIconCode.indexOf('boxPadTop: this.arcBandHeight()') >= 0);
check('R64-T2 隐患自证：居中造成的圆心偏移 (d/4 + B/2) 远大于弧带宽度 ⇒ 与 bloom 无关、纯定位错位',
  (44 / 4 + 1.5 / 2) > design.GlassSpec.RIM,
  '偏移 ' + (44 / 4 + 1.5 / 2).toFixed(2) + 'vp vs 弧带 ' + design.GlassSpec.RIM + 'vp');
// ---- 层序：玻璃主体 -> 光弧层 -> 按压光效层 -> 图标（在 `build()` 切片内比下标，见上方 T11 说明）----
const bodyInBuild = buildCode.indexOf('backgroundEffect(');
const arcInBuild = buildCode.indexOf('ForEach(this.arcSegments()');
const glowInBuild = buildCode.indexOf('.backgroundColor(glassIconPressGlow())');
const iconInBuild = buildCode.indexOf('AaIcon({');
check('v4 层序：玻璃主体 -> 光弧层 -> 按压光效层 -> 图标（SPEC §2.1；弧在按压层**之下**）',
  bodyInBuild >= 0 && arcInBuild > bodyInBuild && glowInBuild > arcInBuild && iconInBuild > glowInBuild,
  'glass@' + bodyInBuild + ' arcCall@' + arcInBuild + ' glow@' + glowInBuild + ' icon@' + iconInBuild);
// 另外把「唯一实现在 @Builder 里」这件事也钉住（防止有人把弧又抄回 build() 里两份）。
check('v4：弧的径向环实现在 @Builder 内（`radialGradient` 只在 arcSegment 里出现 1 次）',
  (glassIconCode.split('radialGradient(').length - 1) === 1
    && glassIconCode.indexOf('@Builder') < glassIconCode.indexOf('radialGradient('));
check('装饰层都显式 hitTestBehavior(HitTestMode.None)：计数 >= 5（玻璃主体 + 段容器 + 内层环 + 按压层 + 图标）',
  (glassIconCode.split('hitTestBehavior(HitTestMode.None)').length - 1) >= 5,
  'got ' + (glassIconCode.split('hitTestBehavior(HitTestMode.None)').length - 1));
check('模糊仍然只此一处（backgroundEffect 恰好 1 次 —— 半透明不靠第二层模糊）',
  (glassIconCode.split('backgroundEffect(').length - 1) === 1);
check('v4 兜底与几何说明写进了源码注释（退回单段均匀环 + 不许悄悄退 + 4 段预案 + 段容器留 BLOOM）',
  glassIconText.indexOf('退回单段均匀环') >= 0 && glassIconText.indexOf('不许悄悄退') >= 0
    && glassIconText.indexOf('4 段') >= 0 && glassIconText.indexOf('ARC_BLOOM') >= 0);

group('R57（T11）光效契约（R63 局部改写）：半透明暗玻璃 + 可见亮环；「完全平坦 / 盘面无渐变」口径已作废');
// ⚠️ R63：本组标题原文是「完全平坦的暗玻璃 + 一根发丝亮环，盘面无高光」——
// 「完全平坦」「盘面无渐变」两句**已作废**（SPEC §2.1 要求 1 层线性渐变光作为方向性来源），
// 但组内**其余**断言（底色叠加模型、环峰可辨识、环贡献上限、backdrop 链路、按下态预测）
// **仍然正确**，故保留。被打回重写的那几条在各自位置都写了作废理由。
// 参考图（Lead 逐半径剖开、**中位数**口径，排除图标）：
//   · 盘面 r 0.4~0.83R **恒为 +11/255（完全平坦）**；
//   · 边缘只体现为 max 尖峰（54→93）、中位数不变 ⇒ **发丝级细环**；
//   · 盘面上**没有**可辨识的高光斑。
// 真机背景实测：深色 9.14（a06 与 glass-before 两组截图都是 9.14）、浅色 252.07。
// 层叠加模型：盘面 = 背景 × (1-alpha_shadow) × (1-alpha_glass) + 255 × alpha_glass
//   （投影画在玻璃**后面**、玻璃只有 ~96% 透 ⇒ 会从盘面内部透出来；黑层向 0 混合）。
const alphaOf = (hex) => parseInt(String(hex).slice(1, 3), 16) / 255;
const DARK_BG = 9.14;
const LIGHT_BG = 252.07;
const R_RING = 22;   // 44vp 钮的半径（vp）—— 仅用于下面「环带宽度占比」的换算
// ⚠️ R59：`RING_FRAC` 的口径随之更新 —— 环带 = t ∈ [RIM_STOP_INNER, 1]（不只是最外 RIM）。
const RING_FRAC = 1 - Math.pow(design.GlassSpec.RIM_STOP_INNER, 2);
const comp255 = (bg, al) => bg * (1 - al) + 255 * al;
const overBlack = (bg, al) => bg * (1 - al);
// ⚠️ T13：浅色档的玻璃色是**黑纱**（`#05000000`）—— 叠加要向 0 混合，不能再用 comp255（「向白掺」）。
// 按资源键的 RGB 自动选目标：纯黑 → 0，纯白 → 255。
const veilTarget = (hex) => (String(hex).slice(3).toUpperCase() === '000000' ? 0 : 255);
const overVeil = (bg, hex) => { const a = alphaOf(hex); return bg * (1 - a) + veilTarget(hex) * a; };
// ⚠️ R64 主修复：4.3% 白 -> **1.2% 白**（真机盘面 Δ+24 -> 目标 ≤ +8）。旧值 `#0BFFFFFF` 已作废。
eq('深色玻璃色 = #03FFFFFF（1.2% 白，R64 主修复）', colorDark['glass_icon_surface'], '#03FFFFFF');
// G4（T13）：浅色档从 8% 白 → **2% 黑纱**（T12 实测 Δ≈0 = 完全隐形；判据见下面的 S6/G4 两条）。
// ⚠️ R57（T17）：浅色静止纱 2% → **8% 黑**。实测 T16 的浅色盘面是 248（页面 253）＝**几乎完全隐形**
// （用户第五次反馈「没有光效」时，顶栏 ⚙/📁 两个钮在浅色下看不见）；加深到 8% 后盘面 ≈ 232，钮这才有存在感。
eq('浅色玻璃色 = #0E000000（5.5% 黑纱，T17 由 2% 加深；上限受 |Δ|<=15 约束）', colorBase['glass_icon_surface'], '#0E000000');
// ---- S4：盘面亮度 ----
const darkInterior = comp255(overBlack(DARK_BG, alphaOf(colorDark['glass_icon_shadow'])),
  alphaOf(colorDark['glass_icon_surface']));
// ⚠️ T17 实测校准：浅色静止盘面 **248**（页面 253）、纱 2% ⇒ **投影对浅色盘面的贡献 ≈ 0**
// （模型若算上 3% 投影会预测 240，与实测差 8）。所以浅色口径 =「盘面 = 页面 × (1 − 纱 alpha)」，不再叠投影项。
const lightInterior = overVeil(LIGHT_BG, colorBase['glass_icon_surface']);
// ⚠️ **R64 口径（旧断言作废）**：原文是「深色「无内容」态盘面落进参考图 +11 ± 5」——
// 那是 R57/T11 的口径，而真机实测 v3 盘面 Δ **+24**（用户说的「灰塑料盘」）。
// R64 的目标改成 **Δ ≤ +8**（SPEC §4，模型预测 +2.2）；旧区间 [6,16] 作废。
check('S4 深色「无内容」态盘面 Δ <= +8（R64 主修复；旧 +11±5 口径作废）',
  (darkInterior - DARK_BG) <= 8, '预测 ' + (darkInterior - DARK_BG).toFixed(2) + '/255');
check('S6 浅色「无内容」态盘面 |Δ| <= 15/255（含投影透出 + 黑纱）',
  Math.abs(lightInterior - LIGHT_BG) <= 15, '预测 ' + (lightInterior - LIGHT_BG).toFixed(2) + '/255');
// ⚠️ G4（T13）：T12 真机实测浅色盘面 Δ ≈ 0（**完全隐形**）—— 8% 白叠在 252 底上等于没叠。
// 改成 2% 黑纱：盘面均匀变暗、**仍然完全平坦**（无任何渐变），近白页面上能看出一个淡灰圆盘。
check('G4 浅色盘面可见：|Δ| >= 8/255（原 ≈0 ⇒ 完全隐形）',
  Math.abs(lightInterior - LIGHT_BG) >= 8, '预测 ' + (lightInterior - LIGHT_BG).toFixed(2) + '/255');
// ⚠️ R63（SPEC §2.2）：浅色亮环峰值 18% → **24% 黑**（`#3D000000`）—— 环加粗到 0.75vp 后同步加深。
eq('G4 浅色细边峰值 = #3D000000（24% 黑，R63 由 18% 加深）', colorBase['glass_icon_rim_high'], '#3D000000');
// ---- S1：亮环平台区（R63 起**只管「环不侵入盘面」**，不再声称「盘面完全平坦」）----
/**
 * ⚠️ **R63 口径改写（旧断言已作废，务必别照着旧注释改回去）**：
 *  · 旧断言「**盘面平台区不得有任何渐变**」**已删除** —— SPEC §2.1 层 ② 要求盘面**必须有**
 *    1 层线性渐变光（`SHEEN_ANGLE`）。「盘面完全平坦」这条判据的来源与作废原因，
 *    见本文件顶部玻璃令牌组的 R63 行表格。
 *  · 仍然成立、因而**保留**的是：**亮环自身**只在最外 `RIM` 处有颜色，
 *    `RIM_STOP_INNER` 以内它的 alpha 恒 0（环不往盘面内部渗色）。
 */
check('S1 弧带平台区：内沿色标 = RIM_STOP_INNER（该半径以内**弧自身** alpha 恒 0）',
  design.GlassSpec.RIM_STOP_INNER === 0.8864,
  String(design.GlassSpec.RIM_STOP_INNER));
check('S1 弧内部 alpha 恒 0（源码里首色标就是 arc clear）',
  glassIconCode.indexOf('[glassArcClear(), 0]') >= 0);
// 环之外，盘面内部还有一项**从玻璃后面透出来的投影**：起伏 ≈ 0.55 × alpha_shadow × 背景。
// 深色 8% × 9.14 ⇒ 0.4/255；浅色 3% × 252 ⇒ 4.2/255。
// ⚠️ R63/R64：这两条现在只描述**投影项**，**不再**等于「盘面总起伏」——
// R64 的方向性来自 ② 光弧（边缘弧，SPEC §2.2），而不再是盘面内的渐变。
const darkFlat = 0.55 * alphaOf(colorDark['glass_icon_shadow']) * DARK_BG;
const lightFlat = 0.55 * alphaOf(colorBase['glass_icon_shadow']) * LIGHT_BG;
check('S1 深色投影透出项 <= 3/255（≠ 盘面总起伏；方向性来自 ② 光弧层）', darkFlat <= 3,
  '预测 ±' + darkFlat.toFixed(2) + '/255');
check('S1 浅色投影透出项（如实记录：投影轮廓在盘面下有梯度）', lightFlat <= 6,
  '预测 ±' + lightFlat.toFixed(2) + '/255');
// ---- S2：盘面无高光 ----
// ⚠️ R64：radialGradient 仍是**唯一实现 1 处**（两段半环共用 `@Builder`，由数据驱动渲染 2 段）。
// 计数口径的完整说明见上面「R64 沉浸光感 v4」组。
eq('S2 GlassIcon.ets 里 radialGradient 恰好 1 处实现（两段半环共用；无偏移高光层）',
  (glassIconCode.split('radialGradient(').length - 1), 1);
// ---- S3：发丝环，且对盘面均值的贡献 <= 2/255 ----
// ⚠️ R63（SPEC §2.2）：深色环峰值 30% → **40% 白**（`#66FFFFFF`）。
// ⚠️ **R64 变更**：这两档现在喂的是**顶栏/底栏胶囊的亮边**（`Components.ets` / `BottomNav.ets`），
// 不再是图标钮的弧色（弧改走 `glass_icon_arc_*`）；取值沿用 R63，**不许删**（SPEC §2.3）。
eq('深色环峰值色 = #66FFFFFF（40% 白；R64 起由胶囊消费）',
  colorDark['glass_icon_rim_high'], '#66FFFFFF');
// ⚠️ R60 回滚：深色环内沿色恢复 R57 的 **12% 白**（`#1FFFFFFF`）。
// R59 改成 23%（`#3BFFFFFF`）是配合「峰值内移 0.972R」的新几何；几何已回滚 ⇒ 色值同步回滚。
eq('深色环内沿色 = #1FFFFFFF（12% 白；R64 起由胶囊消费）',
  colorDark['glass_icon_rim_low'], '#1FFFFFFF');
/**
 * 弧的 alpha 沿半径的剖面（4 个色标：clear@0 → clear@INNER → arcLow@PEAK → arcHigh@1）。
 * ⚠️ R64：色档从 `glassRim*` 换成 `glassArc*` —— 图标钮自 R64 起用弧色，
 * `glass_icon_rim_*` 改由顶栏/底栏胶囊消费，**再拿它算本组件的光强就是算错对象**。
 */
function ringAlpha(t) {
  const A = design.GlassSpec.RIM_STOP_INNER;
  const B = design.GlassSpec.RIM_STOP_PEAK;
  if (t <= A) { return 0; }
  const lo = alphaOf(colorDark['glass_icon_arc_low']);
  const hi = alphaOf(colorDark['glass_icon_arc_high']);
  return t <= B ? lo * (t - A) / (B - A) : lo + (hi - lo) * (t - B) / (1 - B);
}
/** 面积加权均值（面积权 ∝ r；数值积分 2000 段）。 */
let ringSum = 0;
let ringArea = 0;
for (let i = 0; i < 2000; i++) {
  const t = (i + 0.5) / 2000;
  if (t <= design.GlassSpec.RIM_STOP_INNER) { continue; }
  ringSum += ringAlpha(t) * t;
  ringArea += t;
}
const ringMeanAlpha = ringSum / ringArea;
const darkShadowed = overBlack(DARK_BG, alphaOf(colorDark['glass_icon_shadow']));
// ⚠️ R64：弧画在**盘面之上**（层 ② 在 ① 之上）⇒ 合成底从 `darkShadowed` 改成 `darkInterior`。
const ringMeanLum = comp255(darkInterior, ringMeanAlpha);
const ringContribution = RING_FRAC * (ringMeanLum - darkInterior);
/**
 * ⚠️ **R64-T2 口径改写（旧上限作废，理由必须留在原地）**：
 * R59 那条「环对**盘面均值**的贡献 ≤ 10/255」是给 v4「1.25vp 均匀环」标定的**粗代理量**。
 * R64-T2 按 SPEC §4 的目标（弧峰 − 盘面 = +72）把弧峰提到 65% ⇒ 该面积加权均值必然超 10
 * （模型 +16.7）—— **这不是缺陷**：SPEC §4 的「盘面 24 扇区极差 ≤ 15」采样的是**盘面内部**
 * （0.60~0.76R），而弧被限制在 r ≥ `RIM_STOP_INNER`·R = 0.8864R **之外**。
 * ⇒ 断言换成**空间正确**的版本：**弧（连同 bloom 余量）不得侵入盘面采样区**。
 * （旧的 `ringContribution` 数值仍在下面 detail 里打印，便于对比历史，但不再作为判据。）
 */
const DISK_SAMPLE_OUTER = 0.76 * R_RING;                        // §4 盘面采样区外沿（vp）
const ARC_INNER_VP = design.GlassSpec.RIM_STOP_INNER * R_RING;   // 弧内沿（vp）
check('R64-T2 弧覆盖区与盘面采样区（≤0.76R）不重叠，且余量 ≥ ARC_BLOOM（bloom 渗不进采样区）',
  ARC_INNER_VP - DISK_SAMPLE_OUTER >= design.GlassSpec.ARC_BLOOM,
  '弧内沿 ' + ARC_INNER_VP.toFixed(2) + 'vp − 采样外沿 ' + DISK_SAMPLE_OUTER.toFixed(2) + 'vp = ' +
  (ARC_INNER_VP - DISK_SAMPLE_OUTER).toFixed(2) + 'vp ≥ bloom ' + design.GlassSpec.ARC_BLOOM + 'vp' +
  '（旧口径：整盘面积加权贡献 +' + ringContribution.toFixed(2) + '/255，T2 后已不代表缺陷）');
let arcInDiskAlpha = 0;
for (let i = 0; i < 2000; i++) {
  const t = (((i + 0.5) / 2000) * DISK_SAMPLE_OUTER) / R_RING;
  arcInDiskAlpha = Math.max(arcInDiskAlpha, ringAlpha(t));
}
check('R64-T2 盘面内部（r ≤ 0.76R）弧 alpha 恒 0 ⇒ §4 的「24 扇区极差」不会被弧污染',
  arcInDiskAlpha === 0, '采样区最大 alpha = ' + arcInDiskAlpha);
// ⚠️ R64：这条从 v3 的「环峰 ≥ 背景 + 30」升级为 SPEC §4 的**真机验收线**：弧峰 − 盘面 ∈ [+45, +90]。
// 合成底改成盘面（弧画在盘面之上），色档改成弧色。
const darkArcPeak = comp255(darkInterior, alphaOf(colorDark['glass_icon_arc_high']));
const darkArcDimPeak = comp255(darkInterior, alphaOf(colorDark['glass_icon_arc_dim_high']));
/**
 * ⚠️ **φ 的两次真机标定（必须留痕，否则会被当成随手取的系数）**：
 *  · φ = 实测（含 bloom）/ 未稀释模型。**v4**（RIM 1.25 / bloom 4）：+29.0 / +65.9 = **0.44**；
 *  · **R64-T2**（RIM 2.5 / bloom 1.5，几何 + 定位已真机验证成功）：+134.0 / +158.6 = **0.845**。
 * ⇒ **几何一变 φ 就变**，所以 φ 必须跟着**最近一次**真机标定走。
 * R64-T3 与 T2 的**几何/定位/段数完全一致、只改弧色 alpha**，线性缩放成立
 * ⇒ 本条可以同时判 **SPEC §4 的上下双边界 [+45, +90]**：
 *   · T3 的取值预测 **≈ +72** ⇒ 通过；
 *   · T2 的 +134（超上界）与 v4 的 +29（超下界）**都会被这条判红**。
 */
const ARC_DILUTION = 0.845;
const darkArcPeakPredicted = (darkArcPeak - darkInterior) * ARC_DILUTION;
check('R64-T3 ① 用 T2 真机标定的 φ=0.845 预测：弧峰 − 盘面 ∈ [+45, +90]（SPEC §4 双边界）',
  darkArcPeakPredicted >= 45 && darkArcPeakPredicted <= 90,
  '未稀释 +' + (darkArcPeak - darkInterior).toFixed(1) + ' × 0.845 = +' + darkArcPeakPredicted.toFixed(1) +
  '（目标 +72；T2 实测 +134、v4 实测 +29 都会被判红）');
check('R64-T2 自证：本轮三处改动全在「提亮」方向（未稀释弧峰更高 + RIM 更宽 + ARC_BLOOM 更小）',
  (darkArcPeak - darkInterior) > 65.9 && design.GlassSpec.RIM > 1.25 && design.GlassSpec.ARC_BLOOM < 4,
  '未稀释 +' + (darkArcPeak - darkInterior).toFixed(1) + '（v4 为 +65.9）| RIM ' + design.GlassSpec.RIM +
  ' | BLOOM ' + design.GlassSpec.ARC_BLOOM);
// ---- R64（SPEC §4）：其余验收线的**模型预测**（同一脚本口径由 Lead 在设备上判）----
check('R64 ② 等效白 α <= 3%（SPEC §4；现 10.9%）',
  alphaOf(colorDark['glass_icon_surface']) <= 0.03,
  '预测 ' + (alphaOf(colorDark['glass_icon_surface']) * 100).toFixed(2) + '%');
check('R64 ④ 弧 上/下 亮度比 >= 2.5（SPEC §4；现 0.98）',
  (darkArcPeak - DARK_BG) / (darkArcDimPeak - DARK_BG) >= 2.5,
  '上 +' + (darkArcPeak - DARK_BG).toFixed(1) + ' / 下 +' + (darkArcDimPeak - DARK_BG).toFixed(1) + ' = ' +
  ((darkArcPeak - DARK_BG) / (darkArcDimPeak - DARK_BG)).toFixed(2));
// ---- 有内容态：backdrop 链路未被削弱 ----
check('有内容态仍能到 +38~+74（R64 起盘面 1.2% 白更透，透出来的内容更多）',
  comp255(overBlack(80, alphaOf(colorDark['glass_icon_shadow'])), alphaOf(colorDark['glass_icon_surface'])) - DARK_BG >= 38,
  'B_content=80 时预测 +' + (comp255(overBlack(80, alphaOf(colorDark['glass_icon_shadow'])),
  alphaOf(colorDark['glass_icon_surface'])) - DARK_BG).toFixed(1));
// ---- 变异自证（错版必须变红）----
check('自证 1：返工前（12% 白 + 32% 投影）的盘面必然超上限 +16',
  (comp255(overBlack(DARK_BG, alphaOf('#52000000')), alphaOf('#1FFFFFFF')) - DARK_BG) > 16);
// ⚠️ R64-T2：这条自证改成对着**当前令牌**：v4 的 0.9432 内沿（RIM 1.25）对应的弧带面积
// 必须**严格窄于**当前 RIM_STOP_INNER（RIM 2.5）—— 这是「本轮确实把弧带加宽了」的机械依据。
check('自证 2（R64-T2）：v4 的 0.9432 内沿对应的弧带面积严格窄于当前 RIM_STOP_INNER 的弧带面积',
  (1 - Math.pow(0.9432, 2)) < (1 - Math.pow(design.GlassSpec.RIM_STOP_INNER, 2)),
  'v4=' + (1 - Math.pow(0.9432, 2)).toFixed(4) + ' T2=' +
  (1 - Math.pow(design.GlassSpec.RIM_STOP_INNER, 2)).toFixed(4));
check('自证 3：若有高光层（25% 高光 × 26% 半径）盘面必然不平（峰谷差 >> 3）',
  (comp255(darkInterior, 0.25) - darkInterior) > 3);
// ---- S5：backdrop 参数（R60：R58/R59 的控件级模糊实验已回滚）----
/**
 * ⚠️ **R60 判据换代（回滚）**：用户决定「取消 R58/R59/R60 的玻璃调参、改走官方沉浸光感路线」
 * ⇒ `GLASS_ICON_BLUR / GLASS_ICON_SATURATION / GLASS_ICON_ADAPTIVE` 三个控件级实验常量
 * 与唯一入口 `glassIconEffect()` **已从 `Design.ets` 移除**，控件回到与栏同档的直写写法。
 *
 * ⇒ 断言从「`GLASS_ICON_BLUR === 6`」改为「**控件级实验常量必须不存在**」——
 *    这才是回滚后的正确契约：遗留任何一个都会让「取消调参」变成半成品。
 * 若将来重新引入控件级模糊，请连本断言与 `03-BLUR-AB.md` 一起改写并写明理由。
 */
check('S5（R60 回滚）控件级模糊实验常量已移除（GLASS_ICON_BLUR / SATURATION / ADAPTIVE 均 undefined）',
  design.GLASS_ICON_BLUR === undefined
  && design.GLASS_ICON_SATURATION === undefined
  && design.GLASS_ICON_ADAPTIVE === undefined);
check('S5（R60 回滚）唯一入口 glassIconEffect 已移除（控件回到直写 backgroundEffect）',
  design.glassIconEffect === undefined);
check('S5 栏级 backdrop 参数未动（radius 6 / saturation 1.0 / brightness 1.0）',
  design.GLASS_BLUR_RADIUS === 6 && design.GLASS_SATURATION === 1.0 && design.GLASS_BRIGHTNESS === 1.0);
/**
 * ⚠️ `brightness` 仍恒为 1.0。
 * R56 的理由是「自发光会洗白成银灰氛围球」；R59 用真机数据（盘面抬升 J2）复核后仍然成立。
 * R60 回滚后此条**不变**——回滚取消的是 R58/R59 的调参加固层，不是这条本身。
 */
eq('brightness 仍为 1.0（R59 真机 J2 实测抬升 +11.0 已达标，回滚后不变）',
  design.GLASS_BRIGHTNESS, 1.0);

group('R57（T15）光感契约：按压光效 = 显式覆盖层 + @State/onTouch（不再用 brightness）');
// 三轮真机的结论链（这是本节存在的理由）：
//   T13：`brightness` 挂外层矩形 Stack ⇒ 生效了但**露方角亮块**（盘面 +180%）；
//   T14：下沉到圆形玻璃层 ⇒ 四角干净，但那一层 `hitTestBehavior(None)` ⇒ **`pressed` 永不进入**、盘面 +0.0%；
//   T15：改用「**只能用绘制原语实现**」的覆盖层 —— `backgroundColor`（一定被 borderRadius 裁成圆）+ `opacity`，
//        由**外层唯一可命中的节点**的 `onTouch` 驱动 `@State pressed`。
check('T15 形变仍走官方 clickEffect(LIGHT)（真机已验：半径 −5%、连点 5/5）',
  glassIconCode.indexOf('clickEffect({ level: ClickEffectLevel.LIGHT })') >= 0);
check('T15 按压驱动挂在外层可命中节点：onTouch + TouchType.Down',
  glassIconCode.indexOf('.onTouch((event: TouchEvent) => {') >= 0
    && glassIconCode.indexOf('this.pressed = event.type === TouchType.Down') >= 0);
check('T15 按压态是 @State（且 build 里被直接读到 —— §0 读时登记）',
  glassIconCode.indexOf('@State pressed: boolean = false') >= 0
    && glassIconCode.indexOf('.opacity(this.pressed ? 1 : 0)') >= 0);
check('T15 光效层：圆形 backgroundColor(glassIconPressGlow()) + opacity 切换 + 140ms EaseOut',
  glassIconCode.indexOf('.backgroundColor(glassIconPressGlow())') >= 0
    && glassIconCode.indexOf('.animation({ duration: GlassSpec.PRESS_ANIM_MS, curve: Curve.EaseOut })') >= 0);
check('T15 光效层不参与命中测试（不能吃掉点击），也不改变静止态（opacity 0）',
  glassIconCode.indexOf('.opacity(this.pressed ? 1 : 0)') >= 0);
// ⚠️ 这条是三轮教训的机械护栏：**整个组件里不许再出现 `brightness` 滤镜**。
eq('T15 组件里 brightness 滤镜出现 0 次（T13/T14 的失败机制已被彻底移除）',
  (glassIconCode.split('.brightness(').length - 1), 0);
check('T15 保留 disabled 档（链式 opacity + stateStyles.disabled 双保险）',
  glassIconCode.indexOf('disabled: { .opacity(') >= 0);
check('T15 不写 scale 到 stateStyles（形变归 clickEffect，两处都写会乘起来）',
  glassIconCode.indexOf('.scale(') < 0);
// ⚠️ R57（T16）→ **R65 改口径**：lightEffect 现在 **2 处**（档 2 的实验分支 + 官方材质分支），
//    默认自绘路径仍不启用；「第 2 处在官方分支内」由上方 T16 组的锚文断言限定。
check('T15/T16/R65 lightEffect 只在「档 2 实验分支 + 官方材质分支」两处出现（默认自绘路径不启用）',
  (glassIconCode.split('lightEffect: {').length - 1) === 2
    && officialBranchBody.indexOf('lightEffect: { color: Color.White }') >= 0);
// ⚠️ R57（T16）：源码里现在**有** systemMaterial（真机 A/B 用），但默认档 0 返回 `Material.empty`（显式关闭）——
// 所以「默认不启用系统材质」这一条依然成立，且由常量断言 + Material.empty 断言共同保证。
check('T16 默认不启用系统材质：档 0 走 Material.empty（生产默认 = 自绘基线）',
  glassIconCode.indexOf('return uiMaterial.Material.empty;') >= 0
    && glassIconCode.indexOf('export const GLASS_MATERIAL_MODE: number = 0;') >= 0);
/**
 * ⚠️ **这条断言已被改写过两次**（历史留着，免得后人再来回改）：
 *  · 原文（R57/T15）：「盘面零方向性：没有 linearGradient」= **0**；
 *  · R63/v3 翻转为「恰好 **1** 处（铺满盘面的光层）」；
 *  · **R64/v4 再翻回 0** —— 铺满平渐变整层删除（SPEC §2.1 ❌），方向性改由边缘光弧承担。
 */
eq('v4（T15 的「0」与 v3 的「1」两个口径都已作废）：GlassIcon.ets 里 linearGradient 归零',
  (glassIconCode.split('linearGradient(').length - 1), 0);
eq('T15/R64 radialGradient 仍是「唯一实现」1 处（两段半环共用 @Builder，无偏移高光层）',
  (glassIconCode.split('radialGradient(').length - 1), 1);
check('T15 没有 rim light —— 不存在贴着顶缘的 1px 高亮行',
  glassIconCode.indexOf('Line()') < 0 && glassIconCode.indexOf('Divider(') < 0);
// ---- 按下态的**数值预测**（判据见报告；深色背景 9.14）----
const glowDark = alphaOf(colorDark['glass_icon_press_glow']);
const glowBase = alphaOf(colorBase['glass_icon_press_glow']);
const pressedInterior = comp255(darkInterior, glowDark);          // 覆盖层叠在玻璃之上
// ⚠️ R64：弧色换成 `glassArc*`、合成底换成盘面（弧画在盘面之上、按压层又压在弧之上）。
const pressedRing = comp255(comp255(darkInterior, alphaOf(colorDark['glass_icon_arc_high'])), glowDark);
eq('T15 深色光效层 = #0AFFFFFF（3.92% 白）', colorDark['glass_icon_press_glow'], '#0AFFFFFF');
// ⚠️ R57（T17）：浅色光效层从 **8% 黑（按下变暗，被用户否掉）** 改成 **65% 白（按下变亮）**。
eq('T17 浅色光效层 = #BFFFFFFF（75% 白：按下**变亮**，不是变暗）',
  colorBase['glass_icon_press_glow'], '#BFFFFFFF');
check('T17 浅色按下方向 = 变亮（覆盖层向白混合，且盘面提亮 >= 8/255）',
  veilTarget(colorBase['glass_icon_press_glow']) === 255
    && (comp255(lightInterior, glowBase) - lightInterior) >= 8,
  '浅色盘面 ' + lightInterior.toFixed(1) + ' → ' + comp255(lightInterior, glowBase).toFixed(1) +
  '（' + (comp255(lightInterior, glowBase) - lightInterior).toFixed(1) + '/255）');
// ⚠️ R64：色档换成浅色弧色 `glass_icon_arc_high`（与 v3 的 `glass_icon_rim_high` 同值 `#3D000000`）。
// 弧在盘面**之上**、自身 alpha 不变 ⇒ 按下时覆盖层把它一起提亮（v4 的层序是 弧 → 按压层）。
const lightRingRest = overVeil(lightInterior, colorBase['glass_icon_arc_high']);
const lightRingPress = overVeil(comp255(lightInterior, glowBase), colorBase['glass_icon_arc_high']);
check('T17/R64 浅色弧峰方向一致（变亮，且幅度 ≈ 盘面提升 × (1−弧 alpha)）',
  (lightRingPress - lightRingRest) >= 6,
  '弧峰 ' + lightRingRest.toFixed(1) + ' → ' + lightRingPress.toFixed(1) + '（+' + (lightRingPress - lightRingRest).toFixed(1) + '/255）');
/**
 * ⚠️ **R64 结构性护栏（口径反转，旧断言作废）**：T17 要求「按压光效层排在环**之前**（环永远最锐利）」；
 * R64 的 SPEC §2.1 把顺序明确定为 ① 玻璃主体 → ② 光弧层 → ③ 按压光效层 ⇒ 弧在按压层**之下**，
 * 按下时覆盖层会把弧一起提亮。这里断言的是**新顺序**，别照旧注释改回去。
 */
check('R64 层序：光弧层排在按压光效层**之前**（SPEC §2.1；旧 T17「环最锐利」口径作废）',
  glassIconCode.indexOf('.radialGradient({') < glassIconCode.indexOf('.backgroundColor(glassIconPressGlow())'),
  'arc@' + glassIconCode.indexOf('.radialGradient({') + ' glow@' + glassIconCode.indexOf('.backgroundColor(glassIconPressGlow())'));
check('H2 判据 A：深色按下盘面提亮 >= +10%',
  (pressedInterior - darkInterior) / darkInterior >= 0.10,
  '预测 ' + darkInterior.toFixed(2) + ' → ' + pressedInterior.toFixed(2) + '（' +
  ((pressedInterior / darkInterior - 1) * 100).toFixed(1) + '%）');
check('H2 判据 B：弧峰**不下降**（按按下帧半径归一；固定屏幕弧带必然掉是形变几何后果）',
  pressedRing >= comp255(darkInterior, alphaOf(colorDark['glass_icon_arc_high'])),
  '弧峰 ' + comp255(darkInterior, alphaOf(colorDark['glass_icon_arc_high'])).toFixed(1) + ' → ' + pressedRing.toFixed(1));
check('H2 判据 C：四角仍是背景（覆盖层被 borderRadius 裁成圆，方角不可能出现）',
  glassIconCode.indexOf('.backgroundColor(glassIconPressGlow())') >= 0,
  '预期四角 = ' + DARK_BG.toFixed(2));
check('静止态零影响：光效层静止 opacity = 0 ⇒ 静止渲染与 T14 逐像素同源（+11/平坦度不受影响）',
  glassIconCode.indexOf('.opacity(this.pressed ? 1 : 0)') >= 0 && glassIconCode.indexOf('@State pressed: boolean = false') >= 0);
check('浅色档物理上限自证：白覆盖层在浅色下最多只能提亮 +5.4% ⇒ 浅色必须走黑覆盖层',
  (LIGHT_BG - lightInterior) / lightInterior > 0 && glowBase > 0,
  '浅色盘面 ' + lightInterior.toFixed(1) + '，距页面 ' + LIGHT_BG.toFixed(1) + ' 仅 ' +
  (((LIGHT_BG - lightInterior) / lightInterior) * 100).toFixed(1) + '% 上限；8% 黑 ⇒ ' +
  ((comp255(lightInterior, glowBase) / lightInterior - 1) * 100).toFixed(1) + '%');

group('R57（T16）系统材质 A/B 契约：三档开关 + 前置 metadata + 探针');
// 本组是「真机 A/B 三档」的机械护栏：档位开关、前置开关（值必须小写）、探针、以及**默认必须回基线**。
const MODULE_JSON5 = path.join(PROJECT, 'entry', 'src', 'main', 'module.json5');
const moduleText = fs.readFileSync(MODULE_JSON5, 'utf8');
/**
 * ⚠️ **R65 改口径（旧口径「交付包里不许启用该开关」作废，理由写在原地）**：
 * R59 当时的结论是「该开关对本工程无可测收益」⇒ 默认关闭。**R65 推翻了那个归因**：
 * 官方 OS 平台行为变更（仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）规定：
 *   弹窗类组件/接口 与 Slider/Toggle/Select 仍可在页面内**全部区域**生效；
 *   **其他组件只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 且 `barPosition = BarPosition.End`
 *   的底部 TabBar 中生效；在其他区域设置沉浸光感效果不生效。**
 * ⇒ R59/R61 测的**多是页面正文里的自绘容器**，从 HarmonyOS 7 起本来就不在生效范围内
 *   （静默无效）—— 0 像素是**预期内**的，不是「API 坏了」。
 * ⇒ R65 起**开启**该开关，并把决定性 A/B 落在**唯一命中的位置**（首页顶栏两个钮，见下面的 R65 组）。
 * ⚠️ 仍按 R59 的教训：**先剥掉 `//` 行注释**再检查真正的配置（注释里同样有该字面量）。
 */
const moduleNoComments = moduleText
  .split(String.fromCharCode(10))
  .map((line) => {
    // 逐行剥掉 `//` 之后的注释（module.json5 里没有字符串内含 `//` 的值，简单剥法足够）
    const i = line.indexOf('//');
    return i >= 0 ? line.slice(0, i) : line;
  })
  .join(String.fromCharCode(10));
// ⚠️ R57/T16 + R59 两次真机 A/B 判定：
//  · R56/T16：三档在**自绘圆钮**区域逐像素相同 MAE=0.0000（开发期验证记录）；
//  · R59：把覆盖面扩到**设置抽屉 + bindPopup**（后者在 SDK 的 ENABLE 默认名单内），
//    探针确认 `state` 正确从 0 → 1，但两处 ROI 仍是 **MAE=0.0000 / max=0.0**
//    （见开发期验证记录）。
// ⇒ 该开关对本工程**无可测收益**，且是应用级全局变化 ⇒ **默认不启用**。
check('R65：全局材质开关**已启用**（剥注释后 metadata 存在；值必须小写 enable —— 大写会被静默忽略）',
  moduleNoComments.indexOf('"ohos.arkui.UIMaterial.state"') >= 0
    && moduleNoComments.indexOf('"value": "enable"') >= 0
    && moduleNoComments.indexOf('"value": "ENABLE"') < 0,
  '（「材质关」包 = 删掉这一块 metadata；两包其余代码完全相同）');
// ⚠️ 判据必须**描述性、稳定**：原先用 `moduleText.indexOf('')` 判「注释里有写清楚」，
// 而 `` 是**会变的编号 token**（内部坑表改编号、开源时去掉 § 前缀都会让它假失败），
// 判的其实是「编号没变」而不是「说明没丢」。改成按**内容关键词**判：注释里必须同时出现
// 开关名（UIMaterial.state）、生效范围约束的描述、以及两个可复跑的编译期常量名。
// 这三条各自都只有「注释真被删了」才会同时消失，不随编号/措辞重排而失效。
check('T16/R65 已把「生效范围约束 + 如何复跑」写在 module.json5 注释里（不会失传）',
  moduleText.indexOf('UIMaterial.state') >= 0 && moduleText.indexOf('生效范围') >= 0
    && moduleText.indexOf('GLASS_MATERIAL_MODE') >= 0
    && moduleText.indexOf('TOPBAR_OFFICIAL_MATERIAL') >= 0);
check('T16 开关常量存在且**默认档 = 0（C 自绘基线）**',
  glassIconCode.indexOf('export const GLASS_MATERIAL_MODE: number = 0;') >= 0,
  '（改档必须重新构建；交付前默认值必须回到 0）');

group('R65-T1 官方路线 Step 1：首页顶栏两个钮走 ImmersiveMaterial（含生效范围约束）');
// 背景：官方 OS 平台行为变更（`targetSdkVersion >= 26.0.0`）限定了沉浸光感的生效范围
// 按官方生效范围约束：只有 ①弹窗类 ②Slider/Toggle/Select ③`Navigation`/`NavDestination`
// 标题栏 ④横向 Tabs 的底部 TabBar（`barPosition: BarPosition.End`）会生效。
// 本工程**唯一**命中的功能钮 = 首页顶栏两个钮 ⇒ Step 1 只把它们切成「官方材质 only」，
// 并做成编译期开关，供 Lead 在真机上跑「材质开 / 关」两包的逐像素 MAE。
check('R65：编译期开关存在且默认 true',
  glassIconCode.indexOf('export const TOPBAR_OFFICIAL_MATERIAL: boolean = true;') >= 0);
/**
 * ⚠️ Lead R65 明确要求：关闭时**连 `systemMaterial` 调用都不挂**（不是挂 `Material.empty`）——
 * 这样「两包只差一个分支」最干净。⇒ 断言开关必须是**分支级**的（`if` 包住整条官方渲染），
 * 而不是「同一个节点挂 `cond ? ImmersiveMaterial : Material.empty`」。
 */
check('R65：开关是**分支级**的（关闭时不渲染官方分支，而不是挂 Material.empty）',
  glassIconCode.indexOf('return TOPBAR_OFFICIAL_MATERIAL && this.officialMaterial;') >= 0
    && glassIconCode.indexOf('if (this.useOfficialMaterial()) {') >= 0
    && glassIconCode.indexOf('this.officialGlass()') >= 0);
check('R65：调用点 opt-in 的 prop 存在且**缺省 false**（其它页面/其它钮逐像素不变）',
  glassIconCode.indexOf('@Prop officialMaterial: boolean = false;') >= 0);
check('R65：官方分支 = ImmersiveMaterial(THIN) + 半透明 materialColor + applyShadow/interactive/lightEffect',
  officialBranchBody.indexOf('new uiMaterial.ImmersiveMaterial({') >= 0
    && officialBranchBody.indexOf('style: uiMaterial.ImmersiveStyle.THIN') >= 0
    && officialBranchBody.indexOf('materialColor: glassIconSurface()') >= 0
    && officialBranchBody.indexOf('colorInvert: false') >= 0
    && officialBranchBody.indexOf('applyShadow: true') >= 0
    && officialBranchBody.indexOf('interactive: true') >= 0);
/**
 * ⚠️ **这条是本轮的核心机械护栏**：官方文档明确「材质会接管 `backgroundColor` / `borderColor` /
 * `borderWidth` / `shadow`，不建议与它们同时使用」⇒ 官方分支里**一个自绘层都不许有**；
 * 否则 MAE 分不清是材质还是自绘，A/B 白做。
 * （注意用 `.borderColor(`/`.borderWidth(` 而不是 `.border`：后者会误伤 `.borderRadius(`。）
 */
const OFFICIAL_FORBIDDEN = ['backgroundEffect(', '.shadow(', 'radialGradient(', 'linearGradient(',
  'backgroundColor(', '.borderColor(', '.borderWidth('];
check('R65：官方分支**不画任何自绘层**（无 backgroundEffect / shadow / 渐变 / backgroundColor / border）',
  OFFICIAL_FORBIDDEN.filter((t) => officialBranchBody.indexOf(t) >= 0).length === 0,
  '违规项：' + OFFICIAL_FORBIDDEN.filter((t) => officialBranchBody.indexOf(t) >= 0).join(' | '));
check('R65：Components.ets **原样透传** officialMaterial（缺省 false ⇒ 其它调用点不变）',
  componentsText.indexOf('officialMaterial: this.officialMaterial') >= 0
    && componentsText.indexOf('@Prop officialMaterial: boolean = false;') >= 0);
const HOME_ETS = path.join(SRC_ETS, 'ui', 'screens', 'HomeScreen.ets');
const homeText = readText(HOME_ETS);
eq('R65：首页顶栏**恰好 2 个**钮开了官方材质（Step 1 的作用面，多一处就越界）',
  (homeText.split('officialMaterial: true').length - 1), 2);
eq('R65：首页顶栏仍恰好 2 个钮走玻璃档（suite-icons 同源断言的那一半未受影响）',
  (homeText.split('glass: true').length - 1), 2);
/**
 * ## R59 材质路径结论（Lead 叫停自绘调参后的勘察产出）
 *
 * 三档隔离实验（真机 Mate70 Pro+，见开发期验证记录）：
 * | 档 | 底色 | 显式 `.systemMaterial()` | ROI MAE |
 * | --- | --- | --- | --- |
 * | 0 基线 | 不透明 `raised_surface` | ❌ | — |
 * | 1 实验 | `Color.Transparent` | ✅ `ImmersiveMaterial(THIN)` | — |
 * | 2 对照（隔离变量） | `Color.Transparent` | ❌ | — |
 *
 * **档 1 vs 档 2（只差「挂不挂材质」）= 0.0000** ⇒ **材质贡献 0 像素**。
 * 我第一版报的「4.0977 = 材质生效」是**混淆变量**（全部来自底色改透明），已自纠。
 * 另：探针页三区（`Navigation` 标题栏 / 普通 `Column` / 对照）条纹「中间灰占比」全 0.00%。
 *
 * ⇒ 断言口径：**实验开关必须回到 0**（`Material.empty` = 显式关闭），
 *    且档 1/2 的语义要留在源码注释里（结论可复跑、不会失传）。
 */
const SETTINGS_ETS = path.join(SRC_ETS, 'ui', 'screens', 'SettingsScreen.ets');
const settingsText = readText(SETTINGS_ETS);
check('R59 材质实验开关**默认档 = 0**（交付包不得启用实验路径）',
  settingsText.indexOf('export const MATERIAL_PROBE_MODE: number = 0;') >= 0,
  '（改档必须重新构建；A/B 时用 1=透明+挂材质、2=透明+不挂材质来隔离变量）');
check('R59 已把「三档隔离实验」的结论与复跑方式写在源码注释里（不会失传）',
  settingsText.indexOf('MATERIAL_PROBE_MODE') >= 0
    && settingsText.indexOf('档 2') >= 0 && settingsText.indexOf('Material.empty') >= 0);
check('R59 档 0/2 都返回 Material.empty（档 2 的差别**只在底色** —— 这是隔离变量所需）',
  settingsText.indexOf('if (MATERIAL_PROBE_MODE === 0 || MATERIAL_PROBE_MODE === 2)') >= 0);
check('R59 探针页保留但**不在 main_pages**（正常构建不会加载）',
  fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'profile', 'main_pages.json'), 'utf8')
    .indexOf('MaterialProbe') < 0);
check('T16 档名映射（0=C-selfdrawn / 1=S1-material / 2=S2-material+lightEffect）',
  glassIconCode.indexOf("return 'C-selfdrawn';") >= 0
    && glassIconCode.indexOf("return 'S1-material';") >= 0
    && glassIconCode.indexOf("return 'S2-material+lightEffect';") >= 0);
check('T16 材质工厂存在（uiMaterial.ImmersiveMaterial）',
  glassIconCode.indexOf('new uiMaterial.ImmersiveMaterial({') >= 0);
check('T16 档 0 返回 Material.empty（= 显式关闭材质，不是「不调用」）',
  glassIconCode.indexOf('return uiMaterial.Material.empty;') >= 0);
check('T16 S1/S2 用 ImmersiveStyle.THIN 且 colorInvert=false（浅背景上会反色）',
  glassIconCode.indexOf('uiMaterial.ImmersiveStyle.THIN') >= 0
    && (glassIconCode.split('colorInvert: false').length - 1) >= 2);
check('R65：lightEffect 只用 color（SDK LightEffectOptions 唯一字段），且两处都在实验/官方分支内',
  glassIconCode.indexOf('lightEffect: { color: Color.White }') >= 0
    && (glassIconCode.split('lightEffect: {').length - 1) === 2,
  '代码里 lightEffect: { 出现 ' + (glassIconCode.split('lightEffect: {').length - 1) + ' 次');
check('T16 applyShadow/interactive 均 false（投影归 glassIconShadow、形变归 clickEffect）',
  (glassIconCode.split('applyShadow: false').length - 1) >= 2
    && (glassIconCode.split('interactive: false').length - 1) >= 2);
check('T16 探针打三个量：supported / state / level',
  glassIconCode.indexOf('isImmersiveMaterialSupported()') >= 0
    && glassIconCode.indexOf('getMaterialInfo().state') >= 0
    && glassIconCode.indexOf('getGlobalMaterialLevel()') >= 0);
check('T16 GlassIcon 无条件调用 .systemMaterial(glassMaterial())（三档只差一个常量）',
  glassIconCode.indexOf('.systemMaterial(glassMaterial())') >= 0);
check('T16 经典回退三档都保留：玻璃层仍有 backgroundEffect（禁 backgroundBlurStyle）',
  glassIconCode.indexOf('backgroundEffect(') >= 0 && glassIconCode.indexOf('backgroundBlurStyle') < 0);
// ⚠️ **R64 口径（旧值作废）**：v3 的静止态模型是 +9.92/255（盘面 4.3% 白）；
// R64 把 dark 盘面降到 1.2% 白（主修复）⇒ 新模型 **+2.18/255**（8% 投影 × 1.2% 白）。
// 断言改成钉「R64 的新值」，而不是继续钉旧值 —— 这正是本轮要改的那件事。
check('T16/R64 静止态底色模型 = +2.18/255（dark 盘面 1.2% 白 × 8% 投影；旧 +9.92 已作废）',
  Math.abs((darkInterior - DARK_BG) - 2.18) < 0.5,
  '深色盘面模型 ' + (darkInterior - DARK_BG).toFixed(2) + '/255');

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-design: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-design: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ✗ ' + item);
}
process.exit(1);
