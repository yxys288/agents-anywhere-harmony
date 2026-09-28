/**
 * 字符显示宽度（`wcwidth` 的工程化实现，对应 termux `WcWidth.java`）。
 *
 * 说明：ArkTS 没有 Unicode 通用类别查询 API，所以这里用**显式区间表**近似：
 * - 零宽：组合附加符号、变体选择符、零宽连接/非连接符、方向控制符；
 * - 双宽：东亚 Wide/Fullwidth（CJK 汉字、假名、谚文、全角形式、CJK 扩展）、
 *  以及常见 emoji 区段。
 * 覆盖终端实际会遇到的字符集；未收录的边界码位按单宽处理（与多数终端一致）。
 */

export const WIDTH_ZERO: number = 0;
const WIDTH_NARROW: number = 1;
export const WIDTH_WIDE: number = 2;

interface Range {
  start: number;
  end: number;
}

/** 零宽：组合符号与控制类格式字符。 */
const ZERO_WIDTH_RANGES: Range[] = [
  { start: 0x0300, end: 0x036F },   // Combining Diacritical Marks
  { start: 0x0483, end: 0x0489 },
  { start: 0x0591, end: 0x05BD },
  { start: 0x05BF, end: 0x05BF },
  { start: 0x05C1, end: 0x05C2 },
  { start: 0x05C4, end: 0x05C5 },
  { start: 0x05C7, end: 0x05C7 },
  { start: 0x0610, end: 0x061A },
  { start: 0x064B, end: 0x065F },
  { start: 0x0670, end: 0x0670 },
  { start: 0x06D6, end: 0x06DC },
  { start: 0x06DF, end: 0x06E4 },
  { start: 0x06E7, end: 0x06E8 },
  { start: 0x06EA, end: 0x06ED },
  { start: 0x0711, end: 0x0711 },
  { start: 0x0730, end: 0x074A },
  { start: 0x07A6, end: 0x07B0 },
  { start: 0x07EB, end: 0x07F3 },
  { start: 0x0816, end: 0x0819 },
  { start: 0x081B, end: 0x0823 },
  { start: 0x0825, end: 0x0827 },
  { start: 0x0829, end: 0x082D },
  { start: 0x0859, end: 0x085B },
  { start: 0x08E3, end: 0x0902 },
  { start: 0x093A, end: 0x093A },
  { start: 0x093C, end: 0x093C },
  { start: 0x0941, end: 0x0948 },
  { start: 0x094D, end: 0x094D },
  { start: 0x0951, end: 0x0957 },
  { start: 0x0962, end: 0x0963 },
  { start: 0x0981, end: 0x0981 },
  { start: 0x09BC, end: 0x09BC },
  { start: 0x09C1, end: 0x09C4 },
  { start: 0x09CD, end: 0x09CD },
  { start: 0x0A01, end: 0x0A02 },
  { start: 0x0A3C, end: 0x0A3C },
  { start: 0x0A41, end: 0x0A42 },
  { start: 0x0A47, end: 0x0A48 },
  { start: 0x0A4B, end: 0x0A4D },
  { start: 0x0A70, end: 0x0A71 },
  { start: 0x0B01, end: 0x0B01 },
  { start: 0x0B3C, end: 0x0B3C },
  { start: 0x0B3F, end: 0x0B3F },
  { start: 0x0B41, end: 0x0B44 },
  { start: 0x0B4D, end: 0x0B4D },
  { start: 0x0C3E, end: 0x0C40 },
  { start: 0x0C46, end: 0x0C48 },
  { start: 0x0C4A, end: 0x0C4D },
  { start: 0x0D41, end: 0x0D44 },
  { start: 0x0D4D, end: 0x0D4D },
  { start: 0x0E31, end: 0x0E31 },
  { start: 0x0E34, end: 0x0E3A },
  { start: 0x0E47, end: 0x0E4E },
  { start: 0x0EB1, end: 0x0EB1 },
  { start: 0x0EB4, end: 0x0EB9 },
  { start: 0x0EBB, end: 0x0EBC },
  { start: 0x0EC8, end: 0x0ECD },
  { start: 0x0F18, end: 0x0F19 },
  { start: 0x0F35, end: 0x0F35 },
  { start: 0x0F37, end: 0x0F37 },
  { start: 0x0F39, end: 0x0F39 },
  { start: 0x0F71, end: 0x0F7E },
  { start: 0x0F80, end: 0x0F84 },
  { start: 0x0F86, end: 0x0F87 },
  { start: 0x0F8D, end: 0x0F97 },
  { start: 0x0F99, end: 0x0FBC },
  { start: 0x0FC6, end: 0x0FC6 },
  { start: 0x102D, end: 0x1030 },
  { start: 0x1032, end: 0x1037 },
  { start: 0x1039, end: 0x103A },
  { start: 0x1058, end: 0x1059 },
  { start: 0x1160, end: 0x11FF },   // Hangul Jamo medial/final
  { start: 0x135D, end: 0x135F },
  { start: 0x1712, end: 0x1714 },
  { start: 0x1732, end: 0x1734 },
  { start: 0x1752, end: 0x1753 },
  { start: 0x1772, end: 0x1773 },
  { start: 0x17B4, end: 0x17B5 },
  { start: 0x17B7, end: 0x17BD },
  { start: 0x17C6, end: 0x17C6 },
  { start: 0x17C9, end: 0x17D3 },
  { start: 0x180B, end: 0x180E },
  { start: 0x18A9, end: 0x18A9 },
  { start: 0x1920, end: 0x1922 },
  { start: 0x1927, end: 0x1928 },
  { start: 0x1932, end: 0x1932 },
  { start: 0x1939, end: 0x193B },
  { start: 0x1A17, end: 0x1A18 },
  { start: 0x1B00, end: 0x1B03 },
  { start: 0x1B34, end: 0x1B34 },
  { start: 0x1B36, end: 0x1B3A },
  { start: 0x1B3C, end: 0x1B3C },
  { start: 0x1B42, end: 0x1B42 },
  { start: 0x1B6B, end: 0x1B73 },
  { start: 0x1DC0, end: 0x1DFF },   // Combining Diacritical Marks Supplement
  { start: 0x200B, end: 0x200F },   // ZWSP / ZWNJ / ZWJ / LRM / RLM
  { start: 0x202A, end: 0x202E },   // 方向控制
  { start: 0x2060, end: 0x2064 },   // Word Joiner 等
  { start: 0x2066, end: 0x206F },
  { start: 0x20D0, end: 0x20F0 },   // Combining Diacritical Marks for Symbols
  { start: 0x2CEF, end: 0x2CF1 },
  { start: 0x2D7F, end: 0x2D7F },
  { start: 0x2DE0, end: 0x2DFF },
  { start: 0x302A, end: 0x302D },
  { start: 0x3099, end: 0x309A },   // 浊点/半浊点
  { start: 0xA66F, end: 0xA672 },
  { start: 0xA674, end: 0xA67D },
  { start: 0xA69E, end: 0xA69F },
  { start: 0xA6F0, end: 0xA6F1 },
  { start: 0xA802, end: 0xA802 },
  { start: 0xA806, end: 0xA806 },
  { start: 0xA80B, end: 0xA80B },
  { start: 0xA825, end: 0xA826 },
  { start: 0xA8C4, end: 0xA8C5 },
  { start: 0xA8E0, end: 0xA8F1 },
  { start: 0xA926, end: 0xA92D },
  { start: 0xA947, end: 0xA951 },
  { start: 0xA980, end: 0xA982 },
  { start: 0xA9B3, end: 0xA9B3 },
  { start: 0xA9B6, end: 0xA9B9 },
  { start: 0xA9BC, end: 0xA9BC },
  { start: 0xAA29, end: 0xAA2E },
  { start: 0xAA31, end: 0xAA32 },
  { start: 0xAA35, end: 0xAA36 },
  { start: 0xAA43, end: 0xAA43 },
  { start: 0xAA4C, end: 0xAA4C },
  { start: 0xAAB0, end: 0xAAB0 },
  { start: 0xAAB2, end: 0xAAB4 },
  { start: 0xAAB7, end: 0xAAB8 },
  { start: 0xAABE, end: 0xAABF },
  { start: 0xAAC1, end: 0xAAC1 },
  { start: 0xAAEC, end: 0xAAED },
  { start: 0xAAF6, end: 0xAAF6 },
  { start: 0xABE5, end: 0xABE5 },
  { start: 0xABE8, end: 0xABE8 },
  { start: 0xABED, end: 0xABED },
  { start: 0xFB1E, end: 0xFB1E },
  { start: 0xFE00, end: 0xFE0F },   // 变体选择符
  { start: 0xFE20, end: 0xFE2F },   // Combining Half Marks
  { start: 0xFEFF, end: 0xFEFF },   // BOM / ZWNBSP
  { start: 0x101FD, end: 0x101FD },
  { start: 0x10A01, end: 0x10A03 },
  { start: 0x10A05, end: 0x10A06 },
  { start: 0x10A0C, end: 0x10A0F },
  { start: 0x10A38, end: 0x10A3A },
  { start: 0x10A3F, end: 0x10A3F },
  { start: 0x11001, end: 0x11001 },
  { start: 0x11038, end: 0x11046 },
  { start: 0x1D165, end: 0x1D169 },
  { start: 0x1D16D, end: 0x1D182 },
  { start: 0x1D185, end: 0x1D18B },
  { start: 0x1D1AA, end: 0x1D1AD },
  { start: 0x1D242, end: 0x1D244 },
  { start: 0xE0100, end: 0xE01EF }  // 变体选择符补充
];

/** 双宽：东亚 Wide / Fullwidth + emoji。 */
const WIDE_RANGES: Range[] = [
  { start: 0x1100, end: 0x115F },   // Hangul Jamo initial
  { start: 0x231A, end: 0x231B },
  { start: 0x2329, end: 0x232A },
  { start: 0x23E9, end: 0x23EC },
  { start: 0x23F0, end: 0x23F0 },
  { start: 0x23F3, end: 0x23F3 },
  { start: 0x25FD, end: 0x25FE },
  { start: 0x2614, end: 0x2615 },
  { start: 0x2648, end: 0x2653 },
  { start: 0x267F, end: 0x267F },
  { start: 0x2693, end: 0x2693 },
  { start: 0x26A1, end: 0x26A1 },
  { start: 0x26AA, end: 0x26AB },
  { start: 0x26BD, end: 0x26BE },
  { start: 0x26C4, end: 0x26C5 },
  { start: 0x26CE, end: 0x26CE },
  { start: 0x26D4, end: 0x26D4 },
  { start: 0x26EA, end: 0x26EA },
  { start: 0x26F2, end: 0x26F3 },
  { start: 0x26F5, end: 0x26F5 },
  { start: 0x26FA, end: 0x26FA },
  { start: 0x26FD, end: 0x26FD },
  { start: 0x2705, end: 0x2705 },
  { start: 0x270A, end: 0x270B },
  { start: 0x2728, end: 0x2728 },
  { start: 0x274C, end: 0x274C },
  { start: 0x274E, end: 0x274E },
  { start: 0x2753, end: 0x2755 },
  { start: 0x2757, end: 0x2757 },
  { start: 0x2795, end: 0x2797 },
  { start: 0x27B0, end: 0x27B0 },
  { start: 0x27BF, end: 0x27BF },
  { start: 0x2B1B, end: 0x2B1C },
  { start: 0x2B50, end: 0x2B50 },
  { start: 0x2B55, end: 0x2B55 },
  { start: 0x2E80, end: 0x2E99 },   // CJK Radicals
  { start: 0x2E9B, end: 0x2EF3 },
  { start: 0x2F00, end: 0x2FD5 },   // Kangxi Radicals
  { start: 0x2FF0, end: 0x2FFB },
  { start: 0x3000, end: 0x303E },   // CJK 符号与标点（含全角空格）
  { start: 0x3041, end: 0x3096 },   // 平假名
  { start: 0x3099, end: 0x30FF },   // 浊点 + 片假名
  { start: 0x3105, end: 0x312D },   // 注音
  { start: 0x3131, end: 0x318E },   // 谚文字母
  { start: 0x3190, end: 0x31BA },
  { start: 0x31C0, end: 0x31E3 },
  { start: 0x31F0, end: 0x321E },
  { start: 0x3220, end: 0x3247 },
  { start: 0x3250, end: 0x32FE },
  { start: 0x3300, end: 0x4DBF },   // CJK 兼容 + 扩展 A
  { start: 0x4E00, end: 0x9FFF },   // CJK 统一表意文字
  { start: 0xA000, end: 0xA48C },   // 彝文
  { start: 0xA490, end: 0xA4C6 },
  { start: 0xA960, end: 0xA97C },   // 谚文字母扩展 A
  { start: 0xAC00, end: 0xD7A3 },   // 谚文音节
  { start: 0xF900, end: 0xFAFF },   // CJK 兼容表意文字
  { start: 0xFE10, end: 0xFE19 },   // 竖排形式
  { start: 0xFE30, end: 0xFE52 },   // CJK 兼容形式
  { start: 0xFE54, end: 0xFE66 },
  { start: 0xFE68, end: 0xFE6B },
  { start: 0xFF00, end: 0xFF60 },   // 全角 ASCII
  { start: 0xFFE0, end: 0xFFE6 },   // 全角符号
  { start: 0x16FE0, end: 0x16FE4 },
  { start: 0x17000, end: 0x187F7 },
  { start: 0x18800, end: 0x18CD5 },
  { start: 0x1B000, end: 0x1B152 },
  { start: 0x1F004, end: 0x1F004 },
  { start: 0x1F0CF, end: 0x1F0CF },
  { start: 0x1F18E, end: 0x1F18E },
  { start: 0x1F191, end: 0x1F19A },
  { start: 0x1F200, end: 0x1F320 },
  { start: 0x1F32D, end: 0x1F335 },
  { start: 0x1F337, end: 0x1F37C },
  { start: 0x1F37E, end: 0x1F393 },
  { start: 0x1F3A0, end: 0x1F3CA },
  { start: 0x1F3CF, end: 0x1F3D3 },
  { start: 0x1F3E0, end: 0x1F3F0 },
  { start: 0x1F3F4, end: 0x1F3F4 },
  { start: 0x1F3F8, end: 0x1F43E },
  { start: 0x1F440, end: 0x1F440 },
  { start: 0x1F442, end: 0x1F4FC },
  { start: 0x1F4FF, end: 0x1F53D },
  { start: 0x1F54B, end: 0x1F54E },
  { start: 0x1F550, end: 0x1F567 },
  { start: 0x1F57A, end: 0x1F57A },
  { start: 0x1F595, end: 0x1F596 },
  { start: 0x1F5A4, end: 0x1F5A4 },
  { start: 0x1F5FB, end: 0x1F64F },
  { start: 0x1F680, end: 0x1F6C5 },
  { start: 0x1F6CC, end: 0x1F6CC },
  { start: 0x1F6D0, end: 0x1F6D2 },
  { start: 0x1F6EB, end: 0x1F6EC },
  { start: 0x1F6F4, end: 0x1F6FC },
  { start: 0x1F7E0, end: 0x1F7EB },
  { start: 0x1F90C, end: 0x1F93A },
  { start: 0x1F93C, end: 0x1F945 },
  { start: 0x1F947, end: 0x1F9FF },
  { start: 0x1FA70, end: 0x1FAFF },
  { start: 0x20000, end: 0x2FFFD }, // CJK 扩展 B~
  { start: 0x30000, end: 0x3FFFD }
];

function inRanges(codePoint: number, ranges: Range[]): boolean {
  let low = 0;
  let high = ranges.length - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    const range = ranges[mid];
    if (codePoint < range.start) {
      high = mid - 1;
    } else if (codePoint > range.end) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/** 组合符号/格式字符 → true（宽度 0）。 */
function isZeroWidth(codePoint: number): boolean {
  if (codePoint < 0x0300) {
    return false;
  }
  return inRanges(codePoint, ZERO_WIDTH_RANGES);
}

/** 东亚宽字符/emoji → true（宽度 2）。 */
export function isWide(codePoint: number): boolean {
  if (codePoint < 0x1100) {
    return false;
  }
  return inRanges(codePoint, WIDE_RANGES);
}

/** 终端列宽：0 / 1 / 2。 */
export function codePointWidth(codePoint: number): number {
  if (codePoint === 0) {
    return WIDTH_NARROW;
  }
  if (codePoint < 32 || (codePoint >= 0x7F && codePoint < 0xA0)) {
    return WIDTH_ZERO;
  }
  if (isZeroWidth(codePoint)) {
    return WIDTH_ZERO;
  }
  if (isWide(codePoint)) {
    return WIDTH_WIDE;
  }
  return WIDTH_NARROW;
}
