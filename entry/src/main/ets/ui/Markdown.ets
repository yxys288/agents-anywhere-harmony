/**
 * 轻量 Markdown 渲染组件（对应 Android 端 commonmark 的那部分职责，收敛版）。
 *
 * 上游用 commonmark + GFM 扩展做全量解析；鸿蒙端第一轮只做了「围栏代码块切分 + 纯文本」，
 * 真机验收时 `**读时登记**`、行内代码的反引号会原样显示，观感很差。
 *
 * 解析在 `ui/MarkdownParse.ets`（纯逻辑、可单测），代码高亮在 `ui/SyntaxHighlight.ets`
 * （同样是纯逻辑），这里只负责把块/行内标记画出来。
 * 有意不做：嵌套列表、HTML 透传、脚注 —— 目标不是完备，
 * 而是「Agent 输出的常见排版能正常看」。
 *
 * 第八轮补的三块（对齐上游 a022d92「support math and Mermaid rendering and fix code block
 * scrolling」）：**远程图片**（`![alt](url)`，加载失败降级为 alt 文本）、**块级/行内公式**
 * （`$$..$$` / `$..$`，原样等宽展示，不做 KaTeX 排版）、**代码块横向滚动 + 行号**
 * （长行不再硬折行破坏缩进对齐）。
 */

import { common } from '@kit.AbilityKit';
import { FontSize, Radius, Space, borderColor, ink, muted } from './Design';
import { MdBlock, MdBlockKind, MdInline, TokenLine, gutterText, parseInline, parseMarkdown, splitTokenLines } from './MarkdownParse';
import { SyntaxToken, TokenKind, tokenizeCode } from './SyntaxHighlight';
import { AaIcon, ICONS } from './Icon';

/** 单个代码块逐行渲染的行数上限：超过就退化成单个 `Text`（几千个组件比折行更糟）。 */
const MAX_CODE_LINES: number = 400;

/** Markdown 远程图片的最大显示宽度（vp）—— 不用 `width('100%')`：
 *  外层气泡是「按内容撑开」的，百分比在这里会解析成比气泡更宽的值，
 *  真机恰好没超、模拟器立刻把气泡撑出屏幕（坑 141 第二形态）。 */
const IMAGE_MAX_WIDTH: number = 240;

/** 单行代码的横滚兜底上限（vp）：正常行按内容宽度撑开并横向滚动。 */
const CODE_LINE_MAX_WIDTH: number = 2000;

/**
 * `maxWidth <= 0`（不限宽）时给 `constraintSize` 的替代值（vp）。
 *
 * `constraintSize` 要一个有限数，这里取一个远大于任何屏幕的值 —— 效果等价于「只受 `width('100%')` 约束」，
 * 于是不传 `maxWidth` 的调用点（Agent 消息 / 工具消息 / 推理段 / 文件预览）行为与改前逐字节一致。
 */
const UNBOUNDED_WIDTH: number = 1000000;

/** 代码块行高（vp）：行号列与正文列都显式设它，否则两列默认行高不同、逐行错开。 */
const CODE_LINE_HEIGHT: number = 19;

/**
 * 表格单元格的左右内边距合计（vp）—— 算列宽时要把它算进去（ArkUI 的 `width` 是 border-box）。
 */
const TABLE_CELL_PAD_H: number = 16;
/** 表格列宽的上下限（与改前的 `minWidth` / `maxWidth` 一致）。 */
const TABLE_COL_MIN: number = 96;
const TABLE_COL_MAX: number = 240;

/**
 * 一段文本的「显示宽度」（以字号为单位）：中文 / 全角算 1，其余算 0.55。
 *
 * ⚠️ R37 八改：表格列宽必须**按列**统一（同一列的所有行共用一个宽度），
 * 而统一的前提是先知道每列大概多宽 —— 这里用字符权重估算，够用且零依赖。
 */
function displayWidthOf(text: string): number {
  let width = 0;
  for (let i = 0; i < text.length; i++) {
    width += text.charCodeAt(i) > 0x2E7F ? 1 : 0.55;
  }
  return width;
}

/** 列表缩进（vp）：每级 14vp，最多 5 级。 */
function indentOf(block: MdBlock): number {
  const level = block.level > 0 ? block.level : 0;
  const capped = level > 5 ? 5 : level;
  return capped * 14;
}

function headingSize(level: number): number {
  if (level <= 1) {
    return FontSize.HEADLINE;
  }
  if (level === 2) {
    return FontSize.TITLE;
  }
  return FontSize.BODY + 1;
}

/** 单块代码最多高亮的 token 数；超过就退化为纯文本，避免超长块拖慢渲染。 */
const MAX_HIGHLIGHT_TOKENS: number = 1500;

/** token 类型 → 颜色资源。 */
function tokenColor(kind: TokenKind): Resource {
  switch (kind) {
    case TokenKind.KEYWORD: return $r('app.color.code_keyword');
    case TokenKind.TYPE: return $r('app.color.code_type');
    case TokenKind.STRING: return $r('app.color.code_string');
    case TokenKind.NUMBER: return $r('app.color.code_number');
    case TokenKind.COMMENT: return $r('app.color.code_comment');
    case TokenKind.FUNCTION: return $r('app.color.code_function');
    case TokenKind.CONSTANT: return $r('app.color.code_constant');
    case TokenKind.OPERATOR: return $r('app.color.code_operator');
    case TokenKind.PUNCTUATION: return $r('app.color.code_punctuation');
    default: return $r('app.color.ink');
  }
}

/** 文件预览最多高亮的 token 数（整文件比代码块大得多，超了就退纯文本）。 */
const MAX_FILE_TOKENS: number = 6000;

/**
 * 高亮代码文本（不含外框）。给「文件预览」与代码块共用同一套 token → Span 渲染。
 *
 * ⚠️ 不要在 `build()` 里现切词：切词是 O(文件长度) 的，build 会因滚动/状态变化反复执行。
 * 这里用 `@Watch` 只在 `code`/`language` 真变了时重算一次（ArkUI 的 `@Prop` 变化会触发 watch）。
 */
@Component
export struct AaCodeText {
  @Prop @Watch('recompute') code: string = '';
  @Prop @Watch('recompute') language: string = 'generic';
  /** 字号（默认正文小号，文件预览可传更小的值）。
   *  ⚠️ 名字不能叫 `size`：`CustomComponent` 基类已有同名属性，ArkTS 编译期直接报
   *  `Property 'size' ... is not assignable to the same property in base type`。 */
  @Prop textSize: number = FontSize.SMALL;

  @State tokens: SyntaxToken[] = [];
  @State plain: boolean = true;
  /** 按行切分后的 token（每帧 layout 都读它，切词只在 `recompute` 里做一次）。 */
  @State lines: TokenLine[] = [];

  aboutToAppear(): void {
    this.recompute();
  }

  private recompute(): void {
    const tokens = tokenizeCode(this.code, this.language);
    this.lines = splitTokenLines(tokens, this.code);
    if (tokens.length > MAX_FILE_TOKENS) {
      this.tokens = [];
      this.plain = true;
      return;
    }
    this.tokens = tokens;
    this.plain = false;
  }

  build() {
    // 逐行渲染：每行一个 `Row`，行本身按内容宽度撑开（不再被父宽硬折行）。
    // 行数过多（几千行）时组件数量会拖慢渲染，此时退回单个 `Text`。
    if (this.lines.length > MAX_CODE_LINES) {
      Text(this.code)
        .fontSize(this.textSize)
        .fontFamily('Noto Sans Mono')
        .fontColor(ink())
        .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
    } else {
      Column({ space: 0 }) {
        ForEach(this.lines, (line: TokenLine, lineIndex: number) => {
          Row() {
            if (this.plain) {
              Text(line.size > 0 ? this.codeLine(line) : ' ')
                .fontSize(this.textSize)
                .fontFamily('Noto Sans Mono')
                .fontColor(ink())
                .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
            } else {
              Text() {
                ForEach(line.tokens, (token: SyntaxToken, tokenIndex: number) => {
                  Span(token.text)
                    .fontSize(this.textSize)
                    .fontFamily('Noto Sans Mono')
                    .fontColor(tokenColor(token.kind))
                }, (token: SyntaxToken, tokenIndex: number) => `${lineIndex}:${tokenIndex}:${token.text}`)
              }
              .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
            }
          }
          .constraintSize({ maxWidth: CODE_LINE_MAX_WIDTH })
        }, (line: TokenLine, lineIndex: number) => `l${lineIndex}:${line.size}`)
      }
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 纯文本兜底路径：从原文里取第 n 行（不重新切词，直接用已缓存的切分行数）。 */
  private codeLine(line: TokenLine): string {
    let out = '';
    for (let i = 0; i < line.tokens.length; i++) {
      out += line.tokens[i].text;
    }
    return out;
  }
}

/**
 * 用 `Text() { Span(...) }` 承载行内混排：ArkUI 里只有 Span 能在同一段文字内混样式，
 * 用多个 Text 拼会失去换行与对齐。
 */
@Component
export struct AaMarkdown {
  /**
   * R57 性能轮：`text` 变化才重解析（@Watch），不再在 build() 里每次现调 parseMarkdown。
   * 改前：LazyForEach 下滚动/状态 bump 让整条消息反复重建，build() 每跑一次就全量解析一次
   * （O(消息长度)），606 条长会话里可见窗口 ~10 条消息每次 bump 至少 10 次解析。
   * 改后：text 引用不变 ⇒ 不重解析（`reparse` 里的 === 守卫）。
   */
  @Prop @Watch('reparse') text: string = '';
  @Prop baseSize: number = FontSize.BODY;
  /** 是否对围栏代码块做语法高亮。 */
  @Prop highlight: boolean = true;
  /**
   * 正文的**数值**宽度上限（vp）；`<= 0` = 不限宽（沿用 `width('100%')`）。
   *
   * ⚠️ 为什么需要它（R49 真机缺陷的根因）：用户气泡是「按内容撑开 + 只有一个宽度上限」的容器，
   * ArkUI 在这种容器里**不会**先减掉上限再量孩子 —— 孩子的 `width('100%')` 按
   * 「可用宽度 − 左内边距」解析（连气泡自己的右内边距都不减），于是正文比气泡宽，
   * 一路顶到**屏幕右边缘被裁掉**（模拟器实测：气泡 `[218,1305][1278,1451]`，
   * 里面的正文 `[260,1347][1316,1409]` —— 右边界 1316 = 屏宽，用户消息尾部整段看不见）。
   * 数值上限在**测量阶段**就参与约束，不受这条解析规则影响。
   */
  @Prop maxWidth: number = 0;

  /** 按块缓存切词结果，避免 build 期间重复切词。 */
  private tokenCache: Map<string, SyntaxToken[]> = new Map<string, SyntaxToken[]>();

  /** 按块缓存「按行切分」结果（行号与横向滚动都依赖它，切一次复用）。 */
  private lineCache: Map<string, TokenLine[]> = new Map<string, TokenLine[]>();

  /**
   * 块级解析结果（R57）。`@State` 让重解析后能触发一次重建；
   * 内容本身只在 `reparse()` 里写（`text` 变了才写）。
   */
  @State private blocks: MdBlock[] = [];

  /**
   * 行内 token 缓存（按 block.key），与 tokenCache/lineCache 同构、同 200 条上限 + clear 策略
   * （Lead 裁决：不引入第二个无界缓存）。覆盖 HEADING 与 inlineText 两处 parseInline 调用点。
   */
  private inlineCache: Map<string, MdInline[]> = new Map<string, MdInline[]>();

  /** 上次参与解析的文本（引用相等守卫，避免同值重解析）。 */
  private lastParsedText: string = '';
  /** 是否已经解析过（空文本解析出 0 个块也是「已解析」，不能再靠 blocks.length 判）。 */
  private parsed: boolean = false;

  aboutToAppear(): void {
    this.reparse();
  }

  /**
   * 只在 `text` 引用真变了时重解析（@Watch 守卫）。
   * `text` 是 @Prop：AaMarkdown 是 @Component、text 由父级 @State 驱动（SessionDetailScreen
   * 的 message.body 来自 TimelineView 的增量投影，引用只在内容变化时换），所以守卫有效。
   * ⚠️ 空 body（DIAGNOSTIC「（空消息）」、web_search 工具）parseMarkdown 返回 0 块 ——
   * 必须用 `parsed` 标志而不是 `blocks.length` 判「已解析」，否则这类消息每次 build 都重解析。
   */
  private reparse(): void {
    if (this.parsed && this.text === this.lastParsedText) {
      return;
    }
    this.parsed = true;
    this.lastParsedText = this.text;
    this.blocks = parseMarkdown(this.text);
    // 文本换了 → 块 key 全变 → 行内缓存旧条目全部失效，直接清掉防泄漏。
    this.inlineCache.clear();
  }

  /** 取某块的行内 token（缓存命中就走缓存，未命中才解析一次）。 */
  private inlineTokensOf(block: MdBlock): MdInline[] {
    const cached = this.inlineCache.get(block.key);
    if (cached !== undefined) {
      return cached;
    }
    const tokens = parseInline(block.text);
    if (this.inlineCache.size > 200) {
      this.inlineCache.clear();
    }
    this.inlineCache.set(block.key, tokens);
    return tokens;
  }

  /**
   * 加载失败的图片地址。降级为 alt 文本而不是留一个破图占位 ——
   * Image.alt 只支持**本地**占位图（SDK 写明 online images are not supported），
   * 给远程 URL 配 alt 图等于什么都不显示。
   */
  @State failedImages: string[] = [];

  /**
   * 铺满宽度时用的上限（vp）：给了 `maxWidth` 就用它，否则用一个不可能触发的极大值。
   *
   * 统一写成 `width('100%').constraintSize({ maxWidth: this.upperBound() })` 而不是在
   * `@Builder` 里分两支 —— 分支会让每个块的渲染代码翻倍，而 `constraintSize` 是**后写覆盖**，
   * 取极大值时对结果零影响（不传 `maxWidth` 的调用点行为与改前一致）。
   */
  private upperBound(): number {
    return this.maxWidth > 0 ? this.maxWidth : UNBOUNDED_WIDTH;
  }

  build() {
    Column({ space: Space.S }) {
      ForEach(this.blocks, (block: MdBlock) => {
        if (block.kind === MdBlockKind.CODE) {
          this.codeBlock(block)
        } else if (block.kind === MdBlockKind.IMAGE) {
          this.imageBlock(block)
        } else if (block.kind === MdBlockKind.MATH) {
          this.mathBlock(block)
        } else if (block.kind === MdBlockKind.HEADING) {
          Text() {
            ForEach(this.inlineTokensOf(block), (token: MdInline) => {
              Span(token.text)
                .fontSize(headingSize(block.level))
                .fontWeight(FontWeight.Bold)
                .fontColor(ink())
            }, (token: MdInline, index: number) => `${block.key}-h${index}`)
          }
          .width('100%')
          .constraintSize({ maxWidth: this.upperBound() })
        } else if (block.kind === MdBlockKind.TABLE) {
          this.tableBlock(block)
        } else if (block.kind === MdBlockKind.RULE) {
          Divider().strokeWidth(1).color(borderColor())
            .width('100%')
            .constraintSize({ maxWidth: this.upperBound() })
        } else if (block.kind === MdBlockKind.TASK) {
          Row({ space: Space.S }) {
            // R12-9：勾选框从字符 ☑/☐ 换成 Lucide 矢量（`square-check` / `square`）。
            AaIcon({
              d: block.checked === true ? ICONS['square-check'] : ICONS['square'],
              iconSize: this.baseSize,
              color: block.checked === true ? $r('app.color.runtime_running') : muted()
            })
            this.listItemText(block)
          }
          .width('100%')
          .constraintSize({ maxWidth: this.upperBound() })
          .alignItems(VerticalAlign.Top)
          .padding({ left: indentOf(block) })
        } else if (block.kind === MdBlockKind.BULLET) {
          Row({ space: Space.S }) {
            Text('•').fontSize(this.baseSize).fontColor(muted())
            this.listItemText(block)
          }
          .width('100%')
          .constraintSize({ maxWidth: this.upperBound() })
          .alignItems(VerticalAlign.Top)
          .padding({ left: indentOf(block) })
        } else if (block.kind === MdBlockKind.ORDERED) {
          Row({ space: Space.S }) {
            Text(`${block.index}.`).fontSize(this.baseSize).fontColor(muted())
            this.listItemText(block)
          }
          .width('100%')
          .constraintSize({ maxWidth: this.upperBound() })
          .alignItems(VerticalAlign.Top)
          .padding({ left: indentOf(block) })
        } else if (block.kind === MdBlockKind.QUOTE) {
          // ⚠️ R45 真机修复：原先引用竖线用 `Divider().vertical(true).height('100%')` ——
          // `height('100%')` 在**高度未定的 Row** 里会回退成**父容器/视口高度**（真机 dump 实测 2832px = 整屏），
          // 于是这一条 item 变成一整屏高，把上下文全部挤出可视区 ⇒
          // 「进入长会话整屏空白、只剩一条贯穿全屏的竖线」，且等 30s / 小滚都不恢复（布局已自洽）、
          // 只有一次大幅滑动让 item 回收重建后块高才塌回正常（见 开发期验证记录 §2）。
          // 改用 Row 自身的**左边框**：边框高度天然等于内容高度，不依赖百分比、也不参与循环测量。
          // 左内边距同时补足差额（原为 padding 8 + Divider 3 + space 8 = 文本起点 19vp），保持视觉不变。
          Row({ space: Space.S }) {
            this.listItemText(block)
          }
          .width('100%')
          .constraintSize({ maxWidth: this.upperBound() })
          .alignItems(VerticalAlign.Top)
          .padding({ left: Space.S + Space.S })
          .borderWidth({ left: 3 })
          .borderColor(borderColor())
        } else {
          this.inlineText(block)
        }
      }, (block: MdBlock) => block.key)
    }
    .width('100%')
    .constraintSize({ maxWidth: this.upperBound() })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 列表项 / 引用里的行内正文（`Row` 里带一个前置符号的那种）。
   *
   * ⚠️ R49：**不能**直接把 `inlineText` 放进 `Row` —— 它在 `Row` 里写的是 `width('100%')`，
   * 而在时间线（`List`）子树里这个百分比解析出来的是「**窗口**右边缘 − 自身左偏移」，
   * 不是父容器的剩余宽度：dump 实测 `Text "协议层" [123,1669][1316,1731]`（父容器只有 `[42,1274]`），
   * 右边界 1316 = 屏宽 ⇒ 换行宽度白多 12vp、长列表项的末行会一直写到屏幕边缘。
   * 包一层 `layoutWeight(1)` 的 `Column`：宽度由 `Row` 按**实际剩余宽度**分配，是确定值，
   * 内层 `width('100%')` 于是等于这个确定值（与输入区卡片的形态一致）。
   */
  @Builder
  listItemText(block: MdBlock) {
    Column() {
      this.inlineText(block)
    }
    .layoutWeight(1)
    .constraintSize({ maxWidth: this.upperBound() })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  inlineText(block: MdBlock) {
    Text() {
      ForEach(this.inlineTokensOf(block), (token: MdInline) => {
        Span(this.spanText(token))
          .fontSize(this.spanSize(token))
          .fontFamily(this.spanFamily(token))
          .fontWeight(token.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(token.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration({
            type: token.strike ? TextDecorationType.LineThrough
              : (this.spanLink(token).length > 0 ? TextDecorationType.Underline : TextDecorationType.None),
            color: this.spanLink(token).length > 0 ? $r('app.color.session_status_accent') : ink()
          })
          .fontColor(this.spanLink(token).length > 0 ? $r('app.color.session_status_accent') : ink())
          .onClick(() => {
            // Span 只支持 onClick/onHover 两个通用事件（SDK 明确写了），所以链接直接挂在 Span 上
            this.openExternalLink(this.spanLink(token));
          })
      }, (token: MdInline, index: number) => `${block.key}-t${index}`)
    }
    .width('100%')
    .constraintSize({ maxWidth: this.upperBound() })
    .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
  }

  // -------------------------------------------------------------------------
  // 行内 token 的取值助手（避免把判断堆在 @Builder 里、也便于后续换渲染策略）
  // -------------------------------------------------------------------------

  /** 行内显示文本：图片 token 退化成「◧ alt」标记（真正的图片走 IMAGE 块渲染）。 */
  private spanText(token: MdInline): string {
    if (token.image !== undefined) {
      return token.text.length > 0 ? `◧ ${token.text}` : '◧ 图片';
    }
    return token.text;
  }

  /** 行内公式与行内代码用同一档小字号（等宽字体在小一号时更整齐）。 */
  private spanSize(token: MdInline): number {
    return token.code === true || token.math === true ? this.baseSize - 1 : this.baseSize;
  }

  /** 行内公式与行内代码都要等宽：公式里的上下标、空格才对得上。 */
  private spanFamily(token: MdInline): string {
    return token.code === true || token.math === true ? 'Noto Sans Mono' : 'HarmonyOS Sans';
  }

  /** 该 token 的可点目标：链接优先，其次图片地址（行内图片也允许点开浏览器）。 */
  private spanLink(token: MdInline): string {
    if (token.link !== undefined) {
      return token.link;
    }
    return token.image !== undefined ? token.image : '';
  }

  /**
   * 独立成段的图片。
   *
   * 宽度**只给上限**（constraintSize 而不是 width(100%)）：外层气泡按内容撑开，
   * 百分比宽度会解析成比气泡更宽的值并把气泡撑出屏幕（坑 141）。
   * 加载失败（含 http 被拦、URL 404）就把地址记进 failedImages，下一次重绘退化成 alt 文本。
   */
  @Builder
  imageBlock(block: MdBlock) {
    // 注意：@Builder 体内**不能声明局部变量**（ArkUI 只允许 UI 组件语法），
    // 所以地址统一走 this.urlOf()；判空与失败集合都按「地址字符串」比较。
    if (this.urlOf(block).length > 0 && !this.failedImages.includes(this.urlOf(block))) {
      Image(this.urlOf(block))
        .constraintSize({ maxWidth: IMAGE_MAX_WIDTH, maxHeight: IMAGE_MAX_WIDTH })
        .objectFit(ImageFit.Contain)
        .borderRadius(Radius.M)
        .backgroundColor($r('app.color.session_code_surface'))
        .onError(() => {
          this.markImageFailed(this.urlOf(block));
        })
        .onClick(() => {
          this.openExternalLink(this.urlOf(block));
        })
    } else {
      // 降级：alt 文本 + 地址提示（可点开浏览器）；没有 alt 就显示占位符号
      Text(this.imageFallbackText(block))
        .fontSize(this.baseSize - 1)
        .fontColor(muted())
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        .onClick(() => {
          this.openExternalLink(this.urlOf(block));
        })
    }
  }

  /** 图片地址归一成 string（`MdBlock.url` 是可选字段，直接传会给渲染层带来 undefined 判断）。 */
  private urlOf(block: MdBlock): string {
    return block.url !== undefined ? block.url : '';
  }

  private imageFallbackText(block: MdBlock): string {
    const alt = block.alt !== undefined ? block.alt : '';
    const url = block.url !== undefined ? block.url : '';
    if (alt.length > 0) {
      return `◧ ${alt}`;
    }
    return url.length > 0 ? `◧ 图片 ${url}` : '◧ 图片';
  }

  private markImageFailed(url: string): void {
    if (this.failedImages.includes(url)) {
      return; // 同一地址只记一次，避免 onError 反复触发时列表无限增长
    }
    const next: string[] = this.failedImages.slice();
    next.push(url);
    this.failedImages = next;
  }

  /**
   * 块级公式 `$$ ... $$`：原样等宽展示（本轮不做 KaTeX 排版，只保证不被斜体规则破坏、
   * 缩进与换行与原文一致），横向可滚动以容纳长公式。
   */
  @Builder
  mathBlock(block: MdBlock) {
    Scroll() {
      Row() {
        Text(block.text.length > 0 ? block.text : ' ')
          .fontSize(FontSize.SMALL)
          .fontFamily('Noto Sans Mono')
          .fontColor(ink())
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      }
      .constraintSize({ maxWidth: CODE_LINE_MAX_WIDTH })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .width('100%')
    .constraintSize({ maxWidth: this.upperBound() })
    .align(Alignment.Start)
    .padding({ left: Space.S, right: Space.S, top: Space.XS, bottom: Space.XS })
    .borderRadius(Radius.S)
    .backgroundColor($r('app.color.session_code_surface'))
  }

  /**
   * 表格：横向可滚动，表头加粗并带底色。
   * 手机上表格往往比屏幕宽，所以外层套一个横向 `Scroll` —— 硬挤压会把每格压成省略号。
   *
   * ⚠️ R37 八改（用户反馈「对话有些内容显示不正常」）：改前每个单元格各自
   * `constraintSize({ minWidth: 96, maxWidth: 240 })` —— 宽度**按各自内容算**，
   * 于是同一列在不同行宽度不同：表头「内容」那列窄、数据行那列宽，文字直接跑出表头列的
   * 右边界，看起来就是「列没对齐、边框接不上」。
   * 现在改为**按列统一宽度**（`tableColWidth()` 取该列所有单元格里最宽的那个），
   * 同一列的所有行共用同一个 `width` ⇒ 列对齐、边框连续。
   */
  @Builder
  tableBlock(block: MdBlock) {
    Scroll() {
      Column({ space: 0 }) {
        ForEach(block.rows !== undefined ? block.rows : [], (row: string[], rowIndex: number) => {
          Row({ space: 0 }) {
            ForEach(row, (cell: string, cellIndex: number) => {
              Text(cell.length > 0 ? cell : ' ')
                .fontSize(this.baseSize - 1)
                .fontWeight(rowIndex === 0 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(ink())
                .width(this.tableColWidth(block, cellIndex))
                .padding({ left: Space.S, right: Space.S, top: 6, bottom: 6 })
                .borderWidth({ right: 1 })
                .borderColor(borderColor())
            }, (cell: string, cellIndex: number) => `${block.key}-r${rowIndex}c${cellIndex}`)
          }
          // 横线画在**行**上（贯穿整行宽），竖线画在单元格右侧。
          // 改前单元格自己画 `bottom`：行高由最高的那格决定，矮的那格底线会半路断掉。
          .borderWidth({ top: 1, bottom: 1, left: 1 })
          .borderColor(borderColor())
          .backgroundColor(rowIndex === 0 ? $r('app.color.session_code_surface') : Color.Transparent)
        }, (row: string[], rowIndex: number) => `${block.key}-row${rowIndex}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .constraintSize({ maxWidth: this.upperBound() })
    .align(Alignment.Start)
  }

  /**
   * 表格某一列的**统一宽度**（vp）：取该列所有单元格里最宽的那个，clamp 到
   * `[TABLE_COL_MIN, TABLE_COL_MAX]`，并算上单元格左右内边距。
   *
   * ⚠️ 必须是「按列」而不是「按格」：按格算就是 R37 之前那个 bug（同一列宽窄不一）。
   */
  private tableColWidth(block: MdBlock, colIndex: number): number {
    const rows: string[][] = block.rows !== undefined ? block.rows : [];
    let widest = 0;
    for (let r = 0; r < rows.length; r++) {
      const row: string[] = rows[r];
      if (colIndex < row.length) {
        const width = displayWidthOf(row[colIndex]);
        if (width > widest) {
          widest = width;
        }
      }
    }
    const vp = widest * (this.baseSize - 1) + TABLE_CELL_PAD_H;
    if (vp < TABLE_COL_MIN) {
      return TABLE_COL_MIN;
    }
    if (vp > TABLE_COL_MAX) {
      return TABLE_COL_MAX;
    }
    return vp;
  }

  /**
   * 围栏代码块：语言标签 + 行数 + 行号栏 + 正文。
   *
   * 正文**横向可滚动**：代码的缩进对齐靠空格，硬折行会把缩进关系毁掉，
   * 所以超长行走横向滚动（原先 `width(100%)` 会自动折行）。行号栏固定不随横滚移动，
   * 高亮与纯文本两条路径共用同一个骨架，保证「开/关高亮」时行号与缩进表现一致。
   */
  @Builder
  codeBlock(block: MdBlock) {
    Column({ space: Space.XS }) {
      Row({ space: Space.S }) {
        Text(block.language.length > 0 ? block.language : 'code')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .layoutWeight(1)
        Text(`${this.codeLines(block).length} 行`)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
      }
      .width('100%')
      .constraintSize({ maxWidth: this.upperBound() })

      Scroll() {
        Row({ space: Space.S }) {
          // 行号用**一整段** Text 而不是逐行组件：与代码正文共用同一个 lineHeight，
          // 行与行天然对齐（逐行组件时 CAPTION 与 SMALL 的默认行高不同，会逐行错开）。
          Text(gutterText(this.codeLines(block).length))
            .fontSize(FontSize.CAPTION)
            .fontFamily('Noto Sans Mono')
            .fontColor(muted())
            .textAlign(TextAlign.End)
            .lineHeight(CODE_LINE_HEIGHT)
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)

          Column({ space: 0 }) {
            ForEach(this.codeLines(block), (line: TokenLine, lineIndex: number) => {
              Row() {
                if (this.highlight && this.tokensOf(block).length <= MAX_HIGHLIGHT_TOKENS) {
                  Text() {
                    ForEach(line.tokens, (token: SyntaxToken, tokenIndex: number) => {
                      Span(token.text)
                        .fontSize(FontSize.SMALL)
                        .fontFamily('Noto Sans Mono')
                        .fontColor(tokenColor(token.kind))
                    }, (token: SyntaxToken, tokenIndex: number) => `${block.key}-s${lineIndex}:${tokenIndex}`)
                  }
                  .lineHeight(CODE_LINE_HEIGHT)
                  .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
                } else {
                  Text(line.size > 0 ? this.lineText(line) : ' ')
                    .fontSize(FontSize.SMALL)
                    .fontFamily('Noto Sans Mono')
                    .fontColor(ink())
                    .lineHeight(CODE_LINE_HEIGHT)
                    .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
                }
              }
              .constraintSize({ maxWidth: CODE_LINE_MAX_WIDTH })
            }, (line: TokenLine, lineIndex: number) => `${block.key}-cl${lineIndex}`)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .alignItems(VerticalAlign.Top)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .constraintSize({ maxWidth: this.upperBound() })
      .align(Alignment.Start)
    }
    .width('100%')
    .constraintSize({ maxWidth: this.upperBound() })
    .padding(Space.M)
    .borderRadius(Radius.M)
    .backgroundColor($r('app.color.session_code_surface'))
    .borderWidth(1)
    .borderColor(borderColor())
  }

  /** 代码块按行切分（缓存命中就走缓存，切词只在 build 之外的路径上做）。 */
  private codeLines(block: MdBlock): TokenLine[] {
    const cached = this.lineCache.get(block.key);
    if (cached !== undefined) {
      return cached;
    }
    const lines = splitTokenLines(this.tokensOf(block), block.text);
    if (this.lineCache.size > 200) {
      this.lineCache.clear();
    }
    this.lineCache.set(block.key, lines);
    return lines;
  }

  /** 纯文本路径取第 n 行的原文。 */
  private lineText(line: TokenLine): string {
    let out = '';
    for (let i = 0; i < line.tokens.length; i++) {
      out += line.tokens[i].text;
    }
    return out;
  }

  /**
   * 打开外部链接（对应上游 Markdown 里的可点链接）。
   *
   * 用 `UIAbilityContext.openLink` 交给系统（浏览器）处理；不用已废弃的全局 `getContext()`
   * （那是 ArkTS 告警来源），改用组件的 `getUIContext().getHostContext()`。
   * 失败（无浏览器 / 被策略拦）静默返回 —— 链接点不开不该崩掉整个会话页。
   */
  private openExternalLink(url: string): void {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context === undefined || context === null) {
        return;
      }
      context.openLink(url).catch(() => {
      });
    } catch (error) {
    }
  }

  private tokensOf(block: MdBlock): SyntaxToken[] {
    const cached = this.tokenCache.get(block.key);
    if (cached !== undefined) {
      return cached;
    }
    const tokens = tokenizeCode(block.text, block.language);
    if (this.tokenCache.size > 200) {
      this.tokenCache.clear();
    }
    this.tokenCache.set(block.key, tokens);
    return tokens;
  }
}
