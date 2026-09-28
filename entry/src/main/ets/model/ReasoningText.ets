/**
 * 会话时间线「推理段（思考过程）」的**纯逻辑层**。
 *
 * 对应上游 Android：
 *  - `ui/screens/sessiondetail/SessionMessages.kt` 的 `ReasoningSection`
 *  （锚文 `private fun ReasoningSection(`）与 `inlineReasoningSummary`
 *  （锚文 `private fun inlineReasoningSummary(text: String): String?`）；
 *  - `feature/sessiondetail/SessionTimelineProjection.kt` 的 `toSystemMessage()`
 *  （锚文 `if (kind == "reasoning")`）。
 *
 * ⚠️ 本文件**零 ArkUI、零 @kit 依赖、零 import**，因此可以被 `tools/logic-test/suite-reasoning.mjs`
 * 直接转译到 Node 里断言 ——「多长算能一眼总结完」「三态标题」「这一行能不能展开」
 * 这些判定在没有设备时也能复现。
 */

/**
 * 界面文案：**逐字**抄自上游 `app/src/main/res/values-zh-rCN/strings.xml`（注释里给的是 key）。
 * 换成别的措辞就是与安卓端不一致，别改。
 */
export class ReasoningText {
  /** `session_reasoning`。 */
  static readonly REASONING: string = '推理';
  /** `session_reasoning_single_summary` 的逐字模板（`%1$s` = 摘要文本）。 */
  static readonly SINGLE_SUMMARY_TEMPLATE: string = '推理了 %1$s';
  /** `session_reasoning_summary` 的逐字模板（`%1$d` = 段数）。 */
  static readonly SUMMARY_TEMPLATE: string = '推理过程 · %1$d 条摘要';
  /**
   * `session_tool_summary_reasoning` 的逐字模板（`%1$d` = 次数）。
   * 上游在 `toolRunSummary` 里统计（锚文 `it.kind == TimelineMessageKind.Reasoning`）——
   * 本工程的时间线还没有「工具组」这一层，所以本轮只有文案、没有接线点。
   */
  static readonly TOOL_SUMMARY_TEMPLATE: string = '推理了 %1$d 次';

  /** 单段摘要的标题（上游 `stringResource(R.string.session_reasoning_single_summary, inlineSummary)`）。 */
  static singleSummary(summary: string): string {
    return '推理了 ' + summary;
  }

  /** 多段摘要的标题（上游 `stringResource(R.string.session_reasoning_summary, segments.size)`）。 */
  static segmentSummary(count: number): string {
    return '推理过程 · ' + count + ' 条摘要';
  }

  /** 工具组汇总里的「推理了 N 次」（上游 `stringResource(R.string.session_tool_summary_reasoning, reasoning)`）。 */
  static toolSummary(count: number): string {
    return '推理了 ' + count + ' 次';
  }
}

/**
 * 「能一眼总结完」的长度上限 —— 上游 `it.length <= 80`（硬编码，没有资源化）。
 */
export const INLINE_SUMMARY_MAX: number = 80;

/**
 * 去 Markdown（上游 `inlineReasoningSummary` 里那 4 条 `replace`，**顺序不能换**）：
 * 图片 `![alt](url)` → alt、链接 `[text](url)` → text、行内码 `` `x` `` → x、删除 `* _ ~ # >`、空白折叠。
 */
export function stripReasoningMarkdown(text: string): string {
  return text
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/[*_~#>]+/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * 上游 `inlineReasoningSummary(text)`：能当「一句话摘要」就返回它，否则 null。
 *
 * 注意两点（都有上游锚文）：
 *  · 含 `\n` / `\r` 直接 null（判断的是**原文**，不是去 Markdown 后的结果）；
 *  · 去 Markdown 后**空串也返回 null** —— 否则 `###` 这类「全是标记」的段会得到标题「推理了 」
 *  （尾随空格）且被判成不可展开，而上游此态是「推理过程 · 1 条摘要」且**可展开**。
 */
export function inlineReasoningSummary(text: string): string | null {
  if (text.indexOf('\n') >= 0 || text.indexOf('\r') >= 0) {
    return null;
  }
  const plain = stripReasoningMarkdown(text);
  return plain.length > 0 && plain.length <= INLINE_SUMMARY_MAX ? plain : null;
}

/**
 * 调用处的「仅单段」闸门（上游 `segments.singleOrNull()?.let(::inlineReasoningSummary)`）。
 * 摘要只在**恰好一段**时才有意义；多段一律没有摘要。
 */
export function inlineSummaryFor(segments: string[]): string | null {
  if (segments.length !== 1) {
    return null;
  }
  return inlineReasoningSummary(segments[0]);
}

/**
 * 折叠行标题三态（上游 `val title = when { ... }`）：
 * 有摘要 →「推理了 %1$s」；否则有段 →「推理过程 · %1$d 条摘要」；否则 →「推理」。
 */
export function reasoningTitle(segments: string[], inlineSummary: string | null): string {
  if (inlineSummary !== null) {
    return ReasoningText.singleSummary(inlineSummary);
  }
  if (segments.length > 0) {
    return ReasoningText.segmentSummary(segments.length);
  }
  return ReasoningText.REASONING;
}

/**
 * 能否展开（上游 `val expandable = segments.isNotEmpty() && inlineSummary == null`）：
 * 「能一眼总结完」的就不给展开。
 */
export function isReasoningExpandable(segments: string[], inlineSummary: string | null): boolean {
  return segments.length > 0 && inlineSummary === null;
}

/**
 * 渲染侧的段回落（上游 `message.reasoningSegments.ifEmpty { listOfNotNull(message.text.takeIf(String::isNotBlank)) }`）：
 * 投影层已经算好了段，这里只为「段为空但正文非空白」的历史/外部数据兜底。
 */
export function effectiveReasoningSegments(segments: string[], text: string): string[] {
  if (segments.length > 0) {
    return segments;
  }
  return text.trim().length > 0 ? [text] : [];
}
