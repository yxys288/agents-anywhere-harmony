#!/usr/bin/env node
/**
 * aa-hm「对话内容不被屏幕右边缘裁掉」契约自测（R49）。
 *
 * 缺陷（用户原话：「对话时，内容显示不完整，没适配屏幕比例」，自选现象「消息气泡被屏幕边缘裁掉」）：
 * 用户消息的**尾部整段看不见**。模拟器 dump 实测（修复前）：
 *   气泡 `Column [218,1305][1278,1451]`（`constraintSize({maxWidth:'86%'})`）
 *   里面的正文 `Column [260,1347][1316,1409]` —— 右边界 **1316 = 屏宽**，正文比气泡宽 38px。
 * 同族第二处：列表项正文 `Text "协议层" [123,1669][1316,1731]`（父容器只有 `[42,1274]`）。
 *
 * 根因（两条，都是 ArkUI 百分比解析的边界行为，不是「少写了什么属性」）：
 *  ① 内容撑开 + 百分比上限的容器里，ArkUI **不会**先减掉上限再量孩子 ——
 *     孩子的 `width('100%')` 按「可用宽度 − 左内边距」解析（连容器自己的右内边距都不减），
 *     于是内容比容器宽；上限是**测量后**才夹的，夹不回来。
 *  ② 列表子树里 `Row` 内孩子的 `width('100%')` 解析成「**窗口**右边缘 − 自身左偏移」，
 *     不是父容器的剩余宽度。
 * 两条都靠**数值**宽度解决（数值在测量阶段就参与约束）：
 *  `constraintSize({maxWidth: 数值})` / `layoutWeight(1)` / 显式 `width(数值)`。
 *
 * ⚠️ 断言必须比对**参数值**（本工程 suite-scroll-align 的教训：只判属性名存在会把未修的形态判成 PASS）。
 *    这里逐条要求：宽度上限是 `this.xxx` 数值字段、比例字面量 `'86%'` 必须零命中、
 *    `layoutWeight` 的实参必须是 1、`width` 的实参必须是数值字段。
 *
 * 用法（workdir = projects/aa-hm）：node tools/logic-test/suite-bubble-width.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'ets');

let pass = 0;
const fails = [];
function ok(cond, msg) { if (cond) { pass++; } else { fails.push(msg); } }
function read(p) { return fs.readFileSync(p, 'utf8'); }
/** 出现次数（纯字符串计数，避免正则转义歧义）。 */
function countOf(src, needle) { return src.split(needle).length - 1; }

/**
 * 去掉注释后再数。
 *
 * ⚠️ 必须去注释：本工程的注释里大量出现 `width('100%')` / `constraintSize(...)` 这些**锚文**
 * （用来解释缺陷），不去掉就会把注释当成真实调用，计数直接失真（第一版实测 13 ↔ 15 就对不上）。
 */
function stripComments(src) {
  const NL = String.fromCharCode(10);
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

const markdown = stripComments(read(path.join(SRC, 'ui', 'Markdown.ets')));
const markdownRaw = read(path.join(SRC, 'ui', 'Markdown.ets'));
const detail = stripComments(read(path.join(SRC, 'ui', 'screens', 'SessionDetailScreen.ets')));

// ---- ① AaMarkdown 必须提供**数值**宽度上限的入口 ----
ok(/@Prop maxWidth: number = 0;/.test(markdown),
   'AaMarkdown 缺 `@Prop maxWidth: number = 0;` —— 气泡里的正文没有数值上限可用');
ok(markdown.indexOf('private upperBound(): number {') >= 0,
   'AaMarkdown 缺 upperBound()（`maxWidth <= 0` 时要回落到不限宽的极大值）');
ok(/return this\.maxWidth > 0 \? this\.maxWidth : UNBOUNDED_WIDTH;/.test(markdown),
   'upperBound() 的实现变了：必须「给了 maxWidth 用它，否则用极大值」，不能写成固定值');
const unbounded = /const UNBOUNDED_WIDTH: number = (\d+);/.exec(markdown);
ok(unbounded !== null && Number(unbounded[1]) >= 100000,
   'UNBOUNDED_WIDTH 太小 —— 它必须大到任何屏幕都触发不了（等价于只受 width(100%) 约束）');

// ---- ② AaMarkdown 里每一处「铺满宽度」都必须紧跟数值上限 ----
// 逐个配对：`width('100%')` 的下一行必须是 `.constraintSize({ maxWidth: this.upperBound() })`。
// ⚠️ 这是本缺陷最容易回退的地方 —— 新加一个块却忘了挂上限，就会重新出现「内容写到屏幕边缘」。
const fullWidth = countOf(markdown, ".width('100%')");
const bounded = countOf(markdown, '.constraintSize({ maxWidth: this.upperBound() })');
ok(fullWidth >= 10, `AaMarkdown 里 width('100%') 只有 ${fullWidth} 处，扫描口径可能已失效`);
// ⚠️ 用 >= 而不是 ==：`listItemText()` 那层是 `layoutWeight(1)` + 上限（没有 width('100%')），
//    所以上限处数天然会比 width('100%') 处数多 1。真正的判据是下面的**逐点配对**。
ok(bounded >= fullWidth,
   `AaMarkdown 里 width('100%') ${fullWidth} 处，但数值上限只有 ${bounded} 处 —— ` +
   '漏挂的那几处会重新把内容写到屏幕右边缘（R49 缺陷）');

// 逐点核对（不只看总数）：每个 width('100%') 之后 80 个字符内必须出现上限。
{
  const needle = ".width('100%')";
  let i = markdown.indexOf(needle);
  let missed = 0;
  while (i >= 0) {
    const window = markdown.slice(i, i + 120);
    if (window.indexOf('.constraintSize({ maxWidth: this.upperBound() })') < 0) { missed += 1; }
    i = markdown.indexOf(needle, i + needle.length);
  }
  ok(missed === 0, `AaMarkdown 有 ${missed} 处 width('100%') 后面没跟上数值上限（就近 120 字符内）`);
}

// ---- ③ 列表项 / 引用里的正文必须走 layoutWeight（不能用 Row 里的 width('100%')）----
ok(markdown.indexOf('listItemText(block: MdBlock) {') >= 0,
   'AaMarkdown 缺 listItemText() —— 列表项正文在 Row 里用 width(100%) 会被解析成「窗口右边缘 − 左偏移」');
ok(/\.layoutWeight\(1\)/.test(markdown.slice(markdown.indexOf('listItemText(block: MdBlock) {'))),
   'listItemText() 里没有 .layoutWeight(1) —— 宽度就不是 Row 分配的实际剩余宽度，等于没修');
{
  // 四个带前置符号的行（任务 / 无序 / 有序 / 引用）都必须用 listItemText，不能再出现 inlineText。
  const kinds = ['MdBlockKind.TASK', 'MdBlockKind.BULLET', 'MdBlockKind.ORDERED', 'MdBlockKind.QUOTE'];
  for (const kind of kinds) {
    const at = markdown.indexOf(kind);
    ok(at >= 0, `Markdown.ets 里找不到 ${kind} 分支（锚文失效）`);
    if (at < 0) { continue; }
    const next = markdown.indexOf('} else if (block.kind ===', at + 10);
    const body = markdown.slice(at, next < 0 ? at + 900 : next);
    ok(body.indexOf('this.listItemText(block)') >= 0,
       `${kind} 分支没用 listItemText() —— 该行正文会顶到屏幕右边缘（R49 缺陷第二处）`);
  }
}

// ---- ④ 用户气泡：上限必须是**数值字段**，比例字面量必须绝迹 ----
ok(detail.indexOf(".constraintSize({ maxWidth: '86%' })") < 0,
   "SessionDetailScreen 里仍有 `constraintSize({ maxWidth: '86%' })` —— 这就是 R49 被裁掉的根因");
ok(detail.indexOf('.constraintSize({ maxWidth: this.bubbleMaxWidth })') >= 0,
   '用户气泡没用数值上限 `this.bubbleMaxWidth`');
ok(detail.indexOf('@State bubbleMaxWidth: number') >= 0 &&
   detail.indexOf('@State bubbleContentWidth: number') >= 0,
   '缺 bubbleMaxWidth / bubbleContentWidth 这两个 @State 数值字段');
ok(detail.indexOf('maxWidth: this.bubbleContentWidth') >= 0,
   '用户气泡正文没把 bubbleContentWidth 传给 AaMarkdown（正文就还是没有数值上限）');
ok(detail.indexOf('userMessageBody(message: TimelineMessage) {') >= 0,
   '缺 userMessageBody() —— 用户气泡的正文必须与 Agent 侧分开渲染');

// ---- ⑤ 三个宽度值必须真的从屏幕尺寸算出来（不能是写死的常量）----
ok(/const bubble = Math\.floor\(rowWidth \* 0\.78\);/.test(detail),
   '气泡上限不是「消息行可用宽度 × 0.78」（上游 SessionMessages.kt:1296 的口径）');
ok(detail.indexOf('this.timelineContentWidth = rowWidth;') >= 0,
   'timelineContentWidth 没有从屏幕尺寸算出来（写死会在别的屏宽上错位）');
ok(detail.indexOf('const rowWidth = widthVp > 0 ? widthVp - Space.M * 2 : 0;') >= 0,
   '消息行可用宽度的算法变了：必须是「屏宽 − 每一项左右各 12vp」');
ok(detail.indexOf('this.imageMaxWidth = this.bubbleContentWidth;') >= 0,
   '图片上限没跟着气泡内容宽走 —— 改前的「屏宽 × 0.72」比气泡内容宽还大，会把气泡顶破');

// ---- ⑥ 时间线的每一项必须带**显式数值宽度**（不是 width('100%')）----
ok(detail.indexOf('.width(this.timelineContentWidth)') >= 0,
   '时间线项没用显式数值宽度 —— 列表子树里的 width(100%) 会多算 12vp 并顶到屏幕边缘');
{
  // 三个 ListItem（加载更早 / 审批卡 / 渲染单元）都要有；`renderItem` 的那个也必须算在内。
  const spots = countOf(detail, '.width(this.timelineContentWidth)');
  ok(spots >= 3, `显式数值宽度的项只有 ${spots} 处，预期 ≥ 3（加载更早 / 审批卡 / 渲染单元）`);
}
// 附件条也必须收敛在气泡内容框里。
{
  const at = detail.indexOf('attachmentList(message: TimelineMessage) {');
  ok(at >= 0, 'SessionDetailScreen 里找不到 attachmentList()（锚文失效）');
  if (at >= 0) {
    const next = detail.indexOf('@Builder', at + 20);
    const body = detail.slice(at, next < 0 ? at + 2400 : next);
    ok(body.indexOf('.constraintSize({ maxWidth: this.bubbleContentWidth })') >= 0,
       '附件条没有数值宽度上限 —— dump 实测这一层右边界会到 1316（屏宽）而气泡只有 1274');
  }
}

if (fails.length > 0) {
  console.error('suite-bubble-width: ' + fails.length + ' 条断言失败');
  for (const f of fails) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-bubble-width: ' + pass + ' 条断言全绿（AaMarkdown ' + fullWidth + ' 处铺满宽度全部带数值上限）。');
