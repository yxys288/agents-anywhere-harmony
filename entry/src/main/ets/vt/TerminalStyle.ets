/**
 * 终端颜色与文本样式（对应 termux `TextStyle.java` / `TerminalColors.java` / `TerminalColorScheme.java`）。
 *
 * 颜色统一编码成一个 number：
 *  -1 → 默认色（跟随主题）
 *  0 .. 255 → 256 色调色板索引
 *  0x1RRGGBB (带 0x1000000 标志) → 24 位真彩色
 */

export const COLOR_DEFAULT: number = -1;
const TRUECOLOR_FLAG: number = 0x1000000;

export function rgbColor(r: number, g: number, b: number): number {
  return TRUECOLOR_FLAG | (clampByte(r) << 16) | (clampByte(g) << 8) | clampByte(b);
}

function isIndexedColor(color: number): boolean {
  return color >= 0 && color < 256;
}

function isDefaultColor(color: number): boolean {
  return color < 0;
}

function clampByte(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 255) {
    return 255;
  }
  return Math.floor(value);
}

function trueColorRed(color: number): number {
  return (color >> 16) & 0xFF;
}

function trueColorGreen(color: number): number {
  return (color >> 8) & 0xFF;
}

function trueColorBlue(color: number): number {
  return color & 0xFF;
}

/** 样式效果位（可叠加）。 */
export class TextStyleFlags {
  static readonly NORMAL: number = 0;
  static readonly BOLD: number = 1 << 0;
  static readonly DIM: number = 1 << 1;
  static readonly ITALIC: number = 1 << 2;
  static readonly UNDERLINE: number = 1 << 3;
  static readonly BLINK: number = 1 << 4;
  static readonly INVERSE: number = 1 << 5;
  static readonly INVISIBLE: number = 1 << 6;
  static readonly STRIKETHROUGH: number = 1 << 7;
  static readonly DOUBLE_UNDERLINE: number = 1 << 8;
  static readonly CURLY_UNDERLINE: number = 1 << 9;
  static readonly DOTTED_UNDERLINE: number = 1 << 10;
  static readonly DASHED_UNDERLINE: number = 1 << 11;
  static readonly SUPERSCRIPT: number = 1 << 12;
  static readonly SUBSCRIPT: number = 1 << 13;
  static readonly OVERLINE: number = 1 << 14;
  static readonly PROTECTED: number = 1 << 15;
}

/** ArkTS 不允许一元 `~`，用等价的位掩码异或实现「清除若干效果位」。 */
export function withoutFlags(flags: number, mask: number): number {
  return flags & (0xFFFF ^ mask);
}

export function hasUnderline(flags: number): boolean {
  return (flags & (TextStyleFlags.UNDERLINE | TextStyleFlags.DOUBLE_UNDERLINE |
    TextStyleFlags.CURLY_UNDERLINE | TextStyleFlags.DOTTED_UNDERLINE |
    TextStyleFlags.DASHED_UNDERLINE)) !== 0;
}

/** 一条样式记录：前景 + 背景 + 效果位。用值相等做驻留，避免每格存对象。 */
export class TerminalStyle {
  readonly foreground: number;
  readonly background: number;
  readonly flags: number;

  constructor(foreground: number, background: number, flags: number) {
    this.foreground = foreground;
    this.background = background;
    this.flags = flags;
  }

  key(): string {
    return `${this.foreground},${this.background},${this.flags}`;
  }
}

/** 样式池：把样式驻留成索引，行内按列存索引。 */
export class TerminalStylePool {
  private styles: TerminalStyle[] = [];
  private index: Map<string, number> = new Map<string, number>();

  constructor() {
    this.intern(COLOR_DEFAULT, COLOR_DEFAULT, TextStyleFlags.NORMAL);
  }

  intern(foreground: number, background: number, flags: number): number {
    const style = new TerminalStyle(foreground, background, flags);
    const key = style.key();
    const existing = this.index.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const id = this.styles.length;
    this.styles.push(style);
    this.index.set(key, id);
    return id;
  }

  get(id: number): TerminalStyle {
    if (id < 0 || id >= this.styles.length) {
      return this.styles[0];
    }
    return this.styles[id];
  }

  size(): number {
    return this.styles.length;
  }
}

/** 主题色：默认前景/背景/光标 + 16 个 ANSI 基本色。 */
export interface TerminalColorScheme {
  foreground: number;
  background: number;
  cursor: number;
  /** 索引 0..15：black red green yellow blue magenta cyan white + bright 版 */
  ansi: number[];
}

export function defaultColorScheme(dark: boolean): TerminalColorScheme {
  const ansi: number[] = dark ? [
    rgbColor(0x1a, 0x1a, 0x1a), rgbColor(0xef, 0x6b, 0x6b), rgbColor(0x8c, 0xc2, 0x65),
    rgbColor(0xe8, 0xc5, 0x5a), rgbColor(0x6c, 0x9c, 0xf0), rgbColor(0xc0, 0x7c, 0xe0),
    rgbColor(0x5a, 0xc8, 0xc8), rgbColor(0xd8, 0xd8, 0xd8),
    rgbColor(0x7a, 0x7a, 0x7a), rgbColor(0xff, 0x8f, 0x8f), rgbColor(0xa8, 0xd8, 0x84),
    rgbColor(0xf5, 0xd6, 0x7a), rgbColor(0x8e, 0xb6, 0xf5), rgbColor(0xd8, 0x9c, 0xf0),
    rgbColor(0x7a, 0xdc, 0xdc), rgbColor(0xff, 0xff, 0xff)
  ] : [
    rgbColor(0x24, 0x29, 0x2e), rgbColor(0xc0, 0x39, 0x2b), rgbColor(0x27, 0xae, 0x60),
    rgbColor(0xb8, 0x86, 0x00), rgbColor(0x2b, 0x6c, 0xb0), rgbColor(0x8e, 0x44, 0xad),
    rgbColor(0x0e, 0x7c, 0x86), rgbColor(0x7f, 0x8c, 0x8d),
    rgbColor(0x5d, 0x6d, 0x7e), rgbColor(0xe7, 0x4c, 0x3c), rgbColor(0x2e, 0xcc, 0x71),
    rgbColor(0xf3, 0x9c, 0x12), rgbColor(0x34, 0x98, 0xdb), rgbColor(0x9b, 0x59, 0xb6),
    rgbColor(0x16, 0xa0, 0x85), rgbColor(0x2c, 0x3e, 0x50)
  ];
  // R20：浅色侧三色对齐上游 `applyTerminalColors`（锚文 `SessionAgentFilesScreen.kt:745-750`）——
  // 深色 `0xFF09090B / 0xFFFAFAFA / 0xFFFAFAFA`、浅色 `0xFFFEFDFB / 0xFF20211E / 0xFF20211E`。
  // 修前浅色侧写的是 `#FDFCFB / #0A0A0B`，与「页面底色」同值但不等于终端的编辑器底色。
  return {
    foreground: dark ? rgbColor(0xfa, 0xfa, 0xfa) : rgbColor(0x20, 0x21, 0x1e),
    background: dark ? rgbColor(0x09, 0x09, 0x0b) : rgbColor(0xfe, 0xfd, 0xfb),
    cursor: dark ? rgbColor(0xfa, 0xfa, 0xfa) : rgbColor(0x20, 0x21, 0x1e),
    ansi: ansi
  };
}

function cubeValue(index: number): number {
  // xterm 6x6x6 色立方：0,95,135,175,215,255
  if (index === 0) {
    return 0;
  }
  return 55 + index * 40;
}

/** 索引色 → 真彩色（0..15 用主题色，16..231 色立方，232..255 灰阶）。 */
function indexedColorToRgb(index: number, scheme: TerminalColorScheme): number {
  if (index < 16) {
    return scheme.ansi[index];
  }
  if (index < 232) {
    const value = index - 16;
    const r = Math.floor(value / 36);
    const g = Math.floor((value % 36) / 6);
    const b = value % 6;
    return rgbColor(cubeValue(r), cubeValue(g), cubeValue(b));
  }
  const level = 8 + (index - 232) * 10;
  return rgbColor(level, level, level);
}

/** 把任意颜色编码解析成 rgb 编码（默认色走主题值）。 */
export function resolveColor(color: number, scheme: TerminalColorScheme, isForeground: boolean): number {
  if (isDefaultColor(color)) {
    return isForeground ? scheme.foreground : scheme.background;
  }
  if (isIndexedColor(color)) {
    return indexedColorToRgb(color, scheme);
  }
  return color;
}

/** `#RRGGBB`（ArkUI 用）。 */
export function colorToHex(color: number): string {
  const r = trueColorRed(color);
  const g = trueColorGreen(color);
  const b = trueColorBlue(color);
  return `#${byteHex(r)}${byteHex(g)}${byteHex(b)}`;
}

function byteHex(value: number): string {
  const text = clampByte(value).toString(16);
  return text.length === 1 ? `0${text}` : text;
}
