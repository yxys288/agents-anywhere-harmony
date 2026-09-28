/**
 * 终端屏幕的一行（对应 termux `TerminalRow.java`）。
 *
 * 每列存一个 Unicode 码位 + 一个样式 id；宽字符占两列（第 2 列码位为 0，渲染时跳过）。
 * `spaceUsed` 记录“用到的最右列 + 1”，避免整行遍历，是终端渲染性能的关键。
 */

import { WIDTH_WIDE, codePointWidth } from './WcWidth';

const NULL_CHAR: number = 0;

export class TerminalRow {
  text: Uint32Array;
  style: Int32Array;
  spaceUsed: number = 0;
  /** 该行是否因自动换行而结束（回绕续行的标记，复制文本时用）。 */
  lineWrap: boolean = false;
  columns: number;

  constructor(columns: number) {
    this.columns = columns;
    this.text = new Uint32Array(columns);
    this.style = new Int32Array(columns);
  }

  clear(styleId: number): void {
    this.text.fill(NULL_CHAR);
    this.style.fill(styleId);
    this.spaceUsed = 0;
    this.lineWrap = false;
  }

  /** 写入一个码位；宽字符会同时占用 col+1（置 0）。 */
  setChar(column: number, codePoint: number, styleId: number): void {
    if (column < 0 || column >= this.columns) {
      return;
    }
    if (codePoint !== NULL_CHAR && codePointWidth(codePoint) === WIDTH_WIDE) {
      if (column + 1 < this.columns) {
        this.text[column + 1] = NULL_CHAR;
        this.style[column + 1] = styleId;
      }
    }
    this.text[column] = codePoint;
    this.style[column] = styleId;
    if (column + 1 > this.spaceUsed) {
      this.spaceUsed = column + 1;
    }
  }

  getChar(column: number): number {
    if (column < 0 || column >= this.columns) {
      return NULL_CHAR;
    }
    return this.text[column];
  }

  getStyle(column: number): number {
    if (column < 0 || column >= this.columns) {
      return 0;
    }
    return this.style[column];
  }

  /** 该列是否是宽字符的“后半格”。 */
  isWideContinuation(column: number): boolean {
    if (column <= 0 || column >= this.columns) {
      return false;
    }
    const previous = this.text[column - 1];
    return previous !== NULL_CHAR && codePointWidth(previous) === WIDTH_WIDE;
  }

  isBlank(): boolean {
    return this.spaceUsed === 0;
  }

  copyFrom(other: TerminalRow): void {
    this.text.set(other.text);
    this.style.set(other.style);
    this.spaceUsed = other.spaceUsed;
    this.lineWrap = other.lineWrap;
  }

  /** 从右向左填充样式（用于 ICH/DCH 后的补白）。 */
  fillStyle(from: number, to: number, styleId: number): void {
    for (let i = from; i <= to && i < this.columns; i++) {
      if (i >= 0) {
        this.style[i] = styleId;
      }
    }
  }

  /** 重新计算 spaceUsed（清空/删除列之后调用）。 */
  recomputeSpaceUsed(): void {
    let used = 0;
    for (let i = this.columns - 1; i >= 0; i--) {
      if (this.text[i] !== NULL_CHAR) {
        used = i + 1;
        break;
      }
    }
    this.spaceUsed = used;
  }

  /** 该行转成纯文本（去掉尾随空白；宽字符后半格跳过）。 */
  toText(): string {
    let out = '';
    for (let i = 0; i < this.spaceUsed; i++) {
      const codePoint = this.text[i];
      if (codePoint === NULL_CHAR) {
        if (this.isWideContinuation(i)) {
          continue;
        }
        out += ' ';
        continue;
      }
      out += String.fromCodePoint(codePoint);
    }
    return out.replace(/\s+$/, '');
  }
}
