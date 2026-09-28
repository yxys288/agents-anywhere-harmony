/**
 * Lucide 矢量线条图标（ArkUI 实现）—— 对应上游 Android 端的 `com.composables.icons.lucide.*`。
 *
 * ## 为什么有这个文件
 * 上游 Android 端全量用 Lucide 官方矢量图标（57 个唯一标识符）；本工程此前一律用**字符 / emoji 近似**
 * （'🖥' '🗀' '>_' '✎' '☰' '⋯' '▾' '★' '▣' '✓' '🔍' '‹' '×' …）。
 * 真机截图实测（开发期验证记录 vs 开发期验证记录）：
 * ① 彩色 emoji 与线条风格完全不符（🖥 是黑显示器 + 浅蓝支架、🔍 是彩色放大镜）；
 * ② **不是 emoji 码位的符号也会被字体回退渲染成彩色 / 异形**（'✎' U+270E 被渲染成彩色铅笔、
 *  '🗀' U+1F5C0 渲染成没有翻盖斜线的文件夹、'>_' 的两个字符被排成两行）；
 * ③ 悬浮「+」按钮压住了列表最后一行的行内图标（用户原话「图标不要重复添加，搞得都叠加到一起」）。
 *
 * ## 数据来源与归一
 * - 来源：`https://unpkg.com/lucide-static@1.47.0/icons/<name>.svg`（ISC 许可；图标名 = 文件名，kebab-case）；
 * - `<path d>` **原样保留**；`<line>` / `<circle>` / `<rect>` / `<polyline>` / `<ellipse>`
 *  归一成等价的 path 命令，最终**拼成单条 `d` 字符串**（多条子路径，SVG 语义等价）；
 * - 唯一偏差：`key-round` 的钥匙孔在原图里是 `fill="currentColor"` 的小圆（r=0.5），
 *  本工程统一线条风格（fill 透明），故归一成**一条带圆线帽的零长线段**（`L16.51 7.5`，
 *  长度 0.01 而不是严格 0，避免个别渲染器跳过退化线段）—— 圆线帽会把零长线段画成
 *  直径 = 线宽的实心圆点，与「小圆点」视觉一致。除它之外没有任何自创形状。
 * - 归一脚本：`tmp/r12-icons/gen-icons.mjs`（临时区，用后即删；不改工程内任何文件）。
 *
 * ## 尺寸与坐标空间（R12-7 修正：这里曾经写错过）
 * **`Path.commands` 的坐标空间是物理像素 px，而 `Shape` / `Path` 的 `width/height` 与 `viewPort` 是 vp** ——
 * 两者差一个屏幕密度（本机 dpr ≈ 2.975）。这不是文档里明写的约定，是 R12 真机首次验证时才暴露出来的：
 * 改前我们按「path 预缩放到 iconSize、viewPort 也给 iconSize、⇒ 缩放系数恒为 1」来做，结果 path 的 24 个单位
 * 被当成 **24 个物理像素**塞进一个 22vp（= 65px）的盒子里 —— 图标只有安卓版的 1/2.2~1/2.6，而且锚在盒子左上角。
 * 取证：开发期验证记录（鸿蒙侧墨迹 19–24px vs 安卓 48–59px，盒子 65–66px）。
 *
 * 现在的做法：**三个量分别用对空间，一个都不能喂错** ——
 * ```
 * const side = this.getUIContext().vp2px(iconSize) // 盒子的物理像素边长（UIContext 版；全局 vp2px 自 API 18 起废弃）
 * Path().commands(scaleIconPath(d, side)) // 命令坐标是 px ⇒ 24 单位画布放大到 side 个物理像素
 * Shape().viewPort({ x: 0, y: 0, width: iconSize, height: iconSize }) // ⚠️ viewPort 是 vp ⇒ 必须给 vp 数值
 *  .width(iconSize).height(iconSize) // 组件盒子用 vp
 *  .strokeWidth(stroke * iconSize / 24) // ⚠️ 线宽是 **vp**（ArkUI 裸数字默认 vp），不能给 px 数值
 * ```
 * 换算关系（**两次真机量测反推，不是文档结论**）：
 *  `墨迹_px = 命令单位数 × iconSize / viewPort数值 + 线宽数值 × dpr`
 * 前一项里分子分母的 dpr 抵消 ⇒ 命令用 **px 数值**、viewPort 用 **vp 数值**（相差一个 dpr）才让墨迹≈盒子；
 * 后一项说明**线宽是 vp**（裸数字按 vp 解释，渲染时再乘 dpr）—— 若按 px 给（`stroke * sidePx / 24`），
 * 线宽会变成 2.95 倍粗，墨迹因此比安卓大 10%~24%（R12-10 真机像素量测发现的第二处单位错）。
 *
 * **两次真机验证的教训（都记在这里，别再走一遍）**：
 *  ① 两者都给 vp 数值（原实现）⇒ 命令被当成 24px 塞进 65px 盒子 ⇒ 墨迹 23px（应为 ~60px）；
 *  ② 两者都给 px 数值（R12-7 第一次修正）⇒ 放大被 viewPort 抵消 ⇒ 墨迹**仍然** 23px；
 *  ③ 命令/viewPort 修对之后**线宽仍按 px 给** ⇒ 线粗 2.95 倍 ⇒ 墨迹比安卓大 1.10~1.24 倍（R12-10 修正）。
 * 判据来自真机像素量测：开发期验证记录 + Lead 的量测脚本。
 * ⇒ 结论：**只靠推理改不对，必须真机量测**（两次「看起来更自洽」的推理都错了）。
 * ## 用法
 * ```ts
 * AaIcon({ d: ICONS['search'], size: 24, color: ink() })
 * ```
 * 图标名一律走 `ICONS['kebab-case']`（不用点号 —— kebab 名不是合法标识符）。
 * `tools/logic-test/suite-icons.mjs` 会断言「本工程用到的每个名字都在表里」，写错名字会被自测抓住。
 */

import { ink } from './Design';

// >>> AA-ICON-PURE-BEGIN
/** Lucide 原始画布边长（viewBox 0 0 24 24）。 */
export const ICON_VIEW: number = 24;

/** Lucide 原始线宽（24 单位画布下为 2）。 */
export const ICON_STROKE: number = 2;

/**
 * 图标名（kebab-case，与 Lucide 文件名一致）→ 归一后的单条 SVG path `d`。
 *
 * **坐标一律在 24×24 画布里**（照抄 Lucide）；渲染时由 `scaleIconPath()` 等比缩放到目标尺寸。
 * 表里只放上游 Android 端实际用到的 57 个图标，没有多余的。
 */
export const ICONS: Record<string, string> = {
  'archive': 'M3 3H21a1 1 0 0 1 1 1V7a1 1 0 0 1 -1 1H3a1 1 0 0 1 -1 -1V4a1 1 0 0 1 1 -1Z M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8 M10 12h4',
  'archive-restore': 'M3 3H21a1 1 0 0 1 1 1V7a1 1 0 0 1 -1 1H3a1 1 0 0 1 -1 -1V4a1 1 0 0 1 1 -1Z M4 8v11a2 2 0 0 0 2 2h2 M20 8v11a2 2 0 0 1-2 2h-2 M9 15l3 -3 3 3 M12 12v9',
  'arrow-down': 'M12 5v14 M19 12l-7 7 -7 -7',
  'arrow-left': 'm12 19-7-7 7-7 M19 12H5',
  'arrow-up': 'm5 12 7-7 7 7 M12 19V5',
  'bot': 'M12 8V4H8 M6 8H18a2 2 0 0 1 2 2V18a2 2 0 0 1 -2 2H6a2 2 0 0 1 -2 -2V10a2 2 0 0 1 2 -2Z M2 14h2 M20 14h2 M15 13v2 M9 13v2',
  'braces': 'M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5c0 1.1.9 2 2 2h1 M16 21h1a2 2 0 0 0 2-2v-5c0-1.1.9-2 2-2a2 2 0 0 1-2-2V5a2 2 0 0 0-2-2h-1',
  'check': 'M20 6 9 17l-5-5',
  'check-check': 'M18 6 7 17l-5-5 M22 10l-7.5 7.5 L 13 16',
  'chevron-down': 'm6 9 6 6 6-6',
  'chevron-left': 'm15 18-6-6 6-6',
  'chevron-right': 'm9 18 6-6-6-6',
  'chevron-up': 'm18 15-6-6-6 6',
  'chevrons-up-down': 'm7 15 5 5 5-5 M7 9l5 -5 5 5',
  'circle': 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0',
  'circle-alert': 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M12 8L12 12 M12 16L12.01 16',
  'circle-check': 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M16 9l-5.5 5.5 L 8 12',
  'clock': 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M12 6v6l4 2',
  'copy': 'M10 8H20a2 2 0 0 1 2 2V20a2 2 0 0 1 -2 2H10a2 2 0 0 1 -2 -2V10a2 2 0 0 1 2 -2Z M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2',
  'download': 'M12 15V3 M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10l5 5 5 -5',
  'ellipsis': 'M11 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0 M18 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0 M4 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0',
  'external-link': 'M15 3h6v6 M10 14 21 3 M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6',
  'file-code': 'M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z M14 2v5a1 1 0 0 0 1 1h5 M10 12.5 8 15l2 2.5 M14 12.5l2 2.5 -2 2.5',
  'file-pen-line': 'M14.364 13.634a2 2 0 0 0-.506.854l-.837 2.87a.5.5 0 0 0 .62.62l2.87-.837a2 2 0 0 0 .854-.506l4.013-4.009a1 1 0 0 0-3.004-3.004z M14.487 7.858A1 1 0 0 1 14 7V2 M20 19.645V20a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l2.516 2.516 M8 18h1',
  'file-text': 'M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z M14 2v5a1 1 0 0 0 1 1h5 M10 9H8 M16 13H8 M16 17H8',
  'folder': 'M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z',
  'folder-open': 'm6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2',
  'globe': 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20 M2 12h20',
  'hammer': 'm15 12-9.373 9.373a1 1 0 0 1-3.001-3L12 9 M18 15l4 -4 M21.5 11.5l-1.914 -1.914 A 2 2 0 0 1 19 8.172 v -.344 a 2 2 0 0 0 -.586 -1.414 l -1.657 -1.657 A 6 6 0 0 0 12.516 3 H 9 l 1.243 1.243 A 6 6 0 0 1 12 8.485 V 10 l 2 2 h 1.172 a 2 2 0 0 1 1.414 .586 L 18.5 14.5',
  'hash': 'M4 9L20 9 M4 15L20 15 M10 3L8 21 M16 3L14 21',
  // R62（用户指定的悬浮底栏需要「首页」）：形状取自 lucide-static 的 house.svg。
  // ⚠️ 两条子路径都以**绝对** `M` 起头 ⇒ 拼接顺序不影响起点计算（满足 suite-icons 那条
  //  「多子路径拼接时相对 m 会被算错」的护栏）；原 svg 的 `.709` / `-1.528` 已补成
  //  `0.709` / 带空格的 `-1.528`，与本表其余条目的数字写法一致（避免前导点号）。
  'house': 'M15 21v-8a1 1 0 0 0 -1 -1h-4a1 1 0 0 0 -1 1v8 M3 10a2 2 0 0 1 0.709 -1.528l7 -5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2Z',
  'info': 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M12 16v-4 M12 8h.01',
  'key-round': 'M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z M16.5 7.5h0.01',
  'list': 'M3 5h.01 M3 12h.01 M3 19h.01 M8 5h13 M8 12h13 M8 19h13',
  'lock': 'M5 11H19a2 2 0 0 1 2 2V20a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V13a2 2 0 0 1 2 -2Z M7 11V7a5 5 0 0 1 10 0v4',
  'log-out': 'm16 17 5-5-5-5 M21 12H9 M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4',
  'mail-check': 'M22 13V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v12c0 1.1.9 2 2 2h8 M22 7l-8.97 5.7 a 1.94 1.94 0 0 1 -2.06 0 L 2 7 M16 19l2 2 4 -4',
  'monitor': 'M4 3H20a2 2 0 0 1 2 2V15a2 2 0 0 1 -2 2H4a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z M8 21L16 21 M12 17L12 21',
  'monitor-up': 'm9 10 3-3 3 3 M12 13V7 M4 3H20a2 2 0 0 1 2 2V15a2 2 0 0 1 -2 2H4a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z M12 17v4 M8 21h8',
  'moon': 'M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401',
  'package-check': 'M12 22V12 M16 17l2 2 4 -4 M21 11.127V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.729l7 4a2 2 0 0 0 2 .001l1.32-.753 M3.29 7 12 12l8.71-5 M7.5 4.27l8.997 5.148',
  'paperclip': 'm16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551',
  'pencil': 'M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z M15 5l4 4',
  'pin': 'M12 17v5 M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z',
  'plus': 'M5 12h14 M12 5v14',
  'qr-code': 'M4 3H7a1 1 0 0 1 1 1V7a1 1 0 0 1 -1 1H4a1 1 0 0 1 -1 -1V4a1 1 0 0 1 1 -1Z M17 3H20a1 1 0 0 1 1 1V7a1 1 0 0 1 -1 1H17a1 1 0 0 1 -1 -1V4a1 1 0 0 1 1 -1Z M4 16H7a1 1 0 0 1 1 1V20a1 1 0 0 1 -1 1H4a1 1 0 0 1 -1 -1V17a1 1 0 0 1 1 -1Z M21 16h-3a2 2 0 0 0-2 2v3 M21 21v.01 M12 7v3a2 2 0 0 1-2 2H7 M3 12h.01 M12 3h.01 M12 16v.01 M16 12h1 M21 12v.01 M12 21v-1',
  'refresh-cw': 'M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8 M21 3v5h-5 M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16 M8 16H3v5',
  'search': 'm21 21-4.34-4.34 M3 11a8 8 0 1 0 16 0a8 8 0 1 0 -16 0',
  // R38（用户需求「软件所有发送功能都用图标取代」）：发送类按钮统一用这一枚图标。
  // 形状逐字取自 lucide-static@1.47.0 的 send.svg（与原表同源、同版本）。
  // ⚠️ 原 svg 是**两条独立 <path>**，第二条 `m21.854 2.147-10.94 10.939` 用的是**相对** moveto；
  // 本表把多条子路径拼成单条 `d`（见文件头「数据来源与归一」），原样拼接会让第二条的相对起点
  // 基于**前一条的当前点** ⇒ 实落 (36.39, 23.833)，**越出 24×24 画布**（正是 suite-icons 那条
  // 「多子路径拼接时相对 m 会被算错」的护栏要抓的东西）。故按 SVG 语义把第二条**转成绝对**：
  // M21.854 2.147 10.914 13.086（M 的隐式重复由 `parsePath()` 换成 L，与表内其余条目写法一致）。
  'send': 'M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z M21.854 2.147 10.914 13.086',
  'server': 'M4 2H20a2 2 0 0 1 2 2V8a2 2 0 0 1 -2 2H4a2 2 0 0 1 -2 -2V4a2 2 0 0 1 2 -2Z M4 14H20a2 2 0 0 1 2 2V20a2 2 0 0 1 -2 2H4a2 2 0 0 1 -2 -2V16a2 2 0 0 1 2 -2Z M6 6L6.01 6 M6 18L6.01 18',
  'settings': 'M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915 M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0',
  'shield-check': 'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z M9 12l2 2 4 -4',
  'sparkles': 'M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z M20 2v4 M22 4h-4 M2 20a2 2 0 1 0 4 0a2 2 0 1 0 -4 0',
  'square': 'M5 3H19a2 2 0 0 1 2 2V19a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z',
  'square-arrow-out-up-right': 'M21 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h6 M21 3l-9 9 M15 3h6v6',
  'square-check': 'M5 3H19a2 2 0 0 1 2 2V19a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z M16 9l-5.5 5.5 L 8 12',
  'square-pen': 'M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7 M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z',
  'square-terminal': 'm7 11 2-2-2-2 M11 13h4 M5 3H19a2 2 0 0 1 2 2V19a2 2 0 0 1 -2 2H5a2 2 0 0 1 -2 -2V5a2 2 0 0 1 2 -2Z',
  'sun': 'M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M12 2v2 M12 20v2 M4.93 4.93l1.41 1.41 M17.66 17.66l1.41 1.41 M2 12h2 M20 12h2 M6.34 17.66l-1.41 1.41 M19.07 4.93l-1.41 1.41',
  'terminal': 'M12 19h8 M4 17l6 -6 -6 -6',
  'trash-2': 'M10 11v6 M14 11v6 M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6 M3 6h18 M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2',
  'triangle-alert': 'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3 M12 9v4 M12 17h.01',
  'user-round': 'M7 8a5 5 0 1 0 10 0a5 5 0 1 0 -10 0 M20 21a8 8 0 0 0-16 0',
  // 上游 `ic_user_round_arrow_left.xml`（Lucide `user-round-arrow-left`，账号页「修改昵称」行）。
  'user-round-arrow-left': 'M19 16l-3 3 M2 21a8 8 0 0 1 12.664 -6.5 M22 19h-6l3 3 M15 8a5 5 0 1 1 -10 0a5 5 0 1 1 10 0z',
  'wifi-off': 'M12 20h.01 M8.5 16.429a5 5 0 0 1 7 0 M5 12.859a10 10 0 0 1 5.17-2.69 M19 12.859a10 10 0 0 0-2.007-1.523 M2 8.82a15 15 0 0 1 4.177-2.643 M22 8.82a15 15 0 0 0-11.288-3.764 M2 2l20 20',
  'x': 'M18 6 6 18 M6 6l12 12',
};

/** path 命令字（大写绝对 / 小写相对）。 */
function isCommandChar(ch: string): boolean {
  return 'MmLlHhVvCcSsQqTtAaZz'.indexOf(ch) >= 0;
}

/** 数字字符（path 数据里只有数字、小数点与正负号；Lucide 不用科学计数法）。 */
/** 纯数字字符（不含小数点 —— 小数点要单独控制「只能出现一次」）。 */
function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

/** 这个记号是不是一个数字（负号/正号/小数点开头都算）。 */
function isNumberToken(token: string): boolean {
  if (token.length === 0) {
    return false;
  }
  const head = token.charAt(0);
  return isDigit(head) || head === '-' || head === '+' || head === '.';
}
function isNumberChar(ch: string): boolean {
  return (ch >= '0' && ch <= '9') || ch === '.';
}

/** 一类命令的参数个数；未知命令返回 -1。 */
function pathArity(upper: string): number {
  if (upper === 'M' || upper === 'L' || upper === 'T') {
    return 2;
  }
  if (upper === 'H' || upper === 'V') {
    return 1;
  }
  if (upper === 'C') {
    return 6;
  }
  if (upper === 'S' || upper === 'Q') {
    return 4;
  }
  if (upper === 'A') {
    return 7;
  }
  if (upper === 'Z') {
    return 0;
  }
  return -1;
}

/**
 * 把 path 数据切成「命令字 / 数字」记号流。
 *
 * 必须自己切而不是 `split`：SVG 允许 `2-2`（连写负数）与 `.5.5`（连写小数）这类写法，
 * Lucide 的圆形图标就大量使用（`a2 2 0 0 0 2-2`）。
 */
function tokenizePath(d: string): string[] {
  const tokens: string[] = [];
  let i = 0;
  while (i < d.length) {
    const ch = d.charAt(i);
    if (ch === ' ' || ch === ',' || ch === '\n' || ch === '\t' || ch === '\r') {
      i++;
    } else if (isCommandChar(ch)) {
      tokens.push(ch);
      i++;
    } else {
      let j = i;
      if (d.charAt(j) === '-' || d.charAt(j) === '+') {
        j++;
      }
      while (j < d.length && isDigit(d.charAt(j))) {
        j++;
      }
      // ⚠️ 小数点**只能吃一个**：Lucide 的数据里有 `c0 1.1.9 2 2 2` 这种写法 ——
      // 它是 `1.1` 与 `.9` 两个数（SVG 允许小数省略前导 0、也允许数字之间不加分隔符）。
      // 贪婪地吃到第二个小数点会拼出 `1.1.9`，Number() 得到 NaN ⇒ 图标在设备上整条画不出来。
      if (j < d.length && d.charAt(j) === '.') {
        j++;
        while (j < d.length && isDigit(d.charAt(j))) {
          j++;
        }
      }
      if (j === i) {
        // 不认识的字符：跳过一个字符保证前进（未知命令字随后由 parsePath 忽略）。
        j = i + 1;
      }
      tokens.push(d.substring(i, j));
      i = j;
    }
  }
  return tokens;
}

/** 一条命令 + 它的参数。 */
interface PathSegment {
  letter: string;
  args: number[];
}

/**
 * 记号流 → 命令段数组。
 *
 * ⚠️ 一个命令字后面可以跟**多组**参数（隐式重复）。此时 `M` / `m` 的后续组按 SVG 语义是
 * `L` / `l`（直线），不是再次 moveto —— 直接原样重复命令字会**改变图形**，所以这里显式换成 L。
 */
function parsePath(d: string): PathSegment[] {
  const tokens = tokenizePath(d);
  const segments: PathSegment[] = [];
  let i = 0;
  while (i < tokens.length) {
    const letter = tokens[i];
    if (!isCommandChar(letter)) {
      i++;
      continue;
    }
    i++;
    const upper = letter.toUpperCase();
    const arity = pathArity(upper);
    if (arity < 0) {
      continue;
    }
    if (arity === 0) {
      segments.push({ letter: letter, args: [] });
      continue;
    }
    let first = true;
    // ⚠️ 只吃**数字**记号：不能只判「不是命令字」—— 那样一个未认识的字母（如 B）会被当成
    // 参数组，Number() 得到 NaN，整条路径在设备上画不出来。
    while (i + arity <= tokens.length && isNumberToken(tokens[i])) {
      const args: number[] = [];
      for (let a = 0; a < arity; a++) {
        args.push(Number(tokens[i + a]));
      }
      i += arity;
      let effective = letter;
      if (!first && upper === 'M') {
        effective = letter === 'M' ? 'L' : 'l';
      }
      segments.push({ letter: effective, args: args });
      first = false;
    }
  }
  return segments;
}

/**
 * 该命令的第 index 个参数是否参与等比缩放。
 *
 * `A` 的 7 个参数是 `rx ry 旋转角 大弧标志 方向标志 x y` —— 只缩放 rx / ry 与终点，
 * 旋转角与两个标志位必须原样保留（缩放标志位会把圆弧画错）。
 */
function scalesArg(upper: string, index: number): boolean {
  if (upper === 'A') {
    return index === 0 || index === 1 || index === 5 || index === 6;
  }
  return true;
}

/** 保留 3 位小数并去掉多余的 0（矢量图不需要更高精度）。 */
function formatScaled(value: number): string {
  const rounded = Math.round(value * 1000) / 1000;
  return rounded.toString();
}

/**
 * 把 24 单位画布上的 path 数据等比缩放到 `size`（单位与组件尺寸一致）。
 *
 * 相对命令（小写）与绝对命令一样只缩放长度，不需要追踪当前点 —— 这正是等比缩放的性质。
 * 返回的字符串仍是同一条路径（子路径顺序、命令顺序不变），只是坐标乘以 `size / 24`。
 */
export function scaleIconPath(d: string, size: number): string {
  const k = size / ICON_VIEW;
  const segments = parsePath(d);
  const parts: string[] = [];
  for (let s = 0; s < segments.length; s++) {
    const segment = segments[s];
    const upper = segment.letter.toUpperCase();
    // 第一个参数**紧贴**命令字输出（照 Lucide 自己的写法 `M20 20a2 2…`，仍是合法 SVG），
    // 其余参数用空格分隔；段与段之间也留一个空格。
    let text = segment.letter;
    for (let a = 0; a < segment.args.length; a++) {
      const raw = segment.args[a];
      const scaled = formatScaled(scalesArg(upper, a) ? raw * k : raw);
      text += a === 0 ? scaled : ' ' + scaled;
    }
    parts.push(text);
  }
  return parts.join('');
}

/**
 * 图标数据自检：命令字合法、括号外无非法字符、每个数字都能解析。
 *
 * 由 `tools/logic-test/suite-icons.mjs` 对全表调用（Node 侧），把「表里混进了一条坏数据」
 * 变成一条会失败的断言，而不是设备上一块看不见的空白。
 */
export function iconPathIssues(d: string): string[] {
  const issues: string[] = [];
  if (d.length === 0) {
    issues.push('空字符串');
    return issues;
  }
  const first = d.charAt(0);
  if (first !== 'M' && first !== 'm') {
    issues.push('不是以 M/m 开头：' + first);
  }
  const lower = d.toLowerCase();
  for (let i = 0; i < lower.length; i++) {
    const ch = lower.charAt(i);
    const ok = isCommandChar(ch) || isNumberChar(ch) || ch === ' ' || ch === ',' || ch === '-';
    if (!ok) {
      issues.push('非法字符：' + ch);
      break;
    }
  }
  const tokens = tokenizePath(d);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (!isCommandChar(token) && isNaN(Number(token))) {
      issues.push('无法解析的数字：' + token);
      break;
    }
  }
  return issues;
}
// <<< AA-ICON-PURE-END

/**
 * 矢量图标：一条 Lucide stroke 路径渲染成 `size × size`。
 *
 * - `d` 必须是 `ICONS` 里的 24 单位数据（由 `scaleIconPath()` 预缩放到 `size`）；
 * - `stroke` 是 **24 单位画布下的线宽**（Lucide 原图 = 2），实际线宽按比例换算，所以
 *  小图标不会显得比大图标粗；
 * - `fill` 恒为透明：Lucide 是纯线条风格，填色会把图标变成实心块。
 *
 * ⚠️ 尺寸用 `width/height` 显式给死（不用 `layoutWeight`），否则放进 `Row` 会被拉变形；
 * 图标本身不参与点击，命中面由外层容器负责（与 FAB 一样，见坑 29）。
 */
@Component
export struct AaIcon {
  @Prop d: string = '';
  /**
   * 渲染边长（vp）。
   *
   * ⚠️ 参数名**不能**叫 `size`：`CustomComponent` 基类已有 `size(value: SizeOptions)`，
   * 撞名会在构建期报 «Property 'size' in type 'AaIcon' is not assignable to the same property in
   * base type 'CustomComponent'»（与 `enabled` / `border` 是同一类坑，见 Components.ets 的注释）。
   */
  @Prop iconSize: number = 20;
  @Prop color: Resource = ink();
  /** 24 单位画布下的线宽（Lucide 缺省 2）。 */
  @Prop stroke: number = ICON_STROKE;

  /**
   * 组件盒子的**物理像素**边长 —— **只用于缩放「命令坐标」**，不要喂给 `viewPort`，也不要用来算线宽。
   *
   * ⚠️ 两个不同的坐标空间，别把它们喂成一个（R12 真机连踩两次）：
   *  · `Path.commands` 的坐标空间是 **px**，`.width(iconSize)` 是 **vp** ⇒ 路径按 vp 值给会偏小 1/dpr（首验实测 2.2~2.6 倍）；
   *  · `Shape.viewPort` 是 **vp** ⇒ 若把它也按 px 值给，上面那次放大又被**抵消**（第二次真机验证实测：改完仍偏小）。
   * 正解是「**命令用 px 数值、viewPort 用 vp 数值**」，两者差的正好是一个 dpr；
   * 而**线宽也是 vp**（`stroke * iconSize / 24` 直接给，别再乘 dpr —— 见下面的第 ③ 条）。
   */
  private sidePx(): number {
    return this.getUIContext().vp2px(this.iconSize);
  }

  build() {
    Shape() {
      Path()
        .width(this.iconSize)
        .height(this.iconSize)
        .commands(scaleIconPath(this.d, this.sidePx()))
    }
    // viewPort 必须给**vp 数值**（iconSize），不能给 px 数值（sidePx）：
    // Shape 把 viewPort 矩形(vp) 映射到组件矩形(vp)，而命令坐标是 px ⇒ 实际缩放 = 路径单位 × iconSize / viewPortValue
    // （分子分母的 dpr 互相抵消）。给 px 数值会让这条缩放被抵消掉，图标又缩回 1/dpr（R12-7 第二次真机验证实测）。
    .viewPort({ x: 0, y: 0, width: this.iconSize, height: this.iconSize })
    .width(this.iconSize)
    .height(this.iconSize)
    .fill(Color.Transparent)
    .stroke(this.color)
    // ⚠️ 线宽是 **vp**（裸数字默认 vp）：给 px 数值（sidePx）会让线粗 dpr 倍，
    // 墨迹随之比安卓大 10%~24%（R12-10 真机像素量测：改回 vp 后三项预测 60/59.5/46.9 对安卓 59/59/46）。
    .strokeWidth(this.stroke * this.iconSize / ICON_VIEW)
    .strokeLineCap(LineCapStyle.Round)
    .strokeLineJoin(LineJoinStyle.Round)
  }
}
