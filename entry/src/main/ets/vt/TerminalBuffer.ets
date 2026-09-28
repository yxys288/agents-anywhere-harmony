/**
 * 终端缓冲区（对应 termux `TerminalBuffer.java`）。
 *
 * 结构：`lines` 是「历史 + 当前屏」的连续数组，最后 `screenRows` 行是可见屏，
 * 前面的部分是滚动回看（scrollback）。所有编辑操作都作用在屏内，并正确维护
 * 上下边距（DECSTBM）、制表位（HTS/TBC）与滚动计数。
 */

import { TerminalRow } from './TerminalRow';
import { TerminalStylePool } from './TerminalStyle';

const DEFAULT_SCROLLBACK_LINES: number = 2000;

export class TerminalBuffer {
  stylePool: TerminalStylePool;
  lines: TerminalRow[] = [];
  /** 可见屏第一行在 `lines` 中的下标。 */
  screenFirstRow: number = 0;
  screenRows: number;
  screenColumns: number;
  /** 历史行上限（0 表示不留历史）。 */
  maxScrollback: number;

  cursorRow: number = 0;
  cursorCol: number = 0;
  cursorVisible: boolean = true;

  topMargin: number = 0;
  bottomMargin: number;
  leftMargin: number = 0;
  rightMargin: number;

  tabs: boolean[] = [];
  /** 累计向上滚出的行数，用于唯一标识历史行。 */
  totalLinesScrolled: number = 0;

  constructor(columns: number, rows: number, scrollback: number = DEFAULT_SCROLLBACK_LINES) {
    this.screenColumns = columns;
    this.screenRows = rows;
    this.maxScrollback = scrollback;
    this.bottomMargin = rows - 1;
    this.rightMargin = columns - 1;
    this.stylePool = new TerminalStylePool();
    for (let i = 0; i < rows; i++) {
      this.lines.push(new TerminalRow(columns));
    }
    this.screenFirstRow = 0;
    this.initTabs();
  }

  private initTabs(): void {
    this.tabs = [];
    for (let i = 0; i < this.screenColumns; i++) {
      this.tabs.push(i % 8 === 0);
    }
  }

  // -------------------------------------------------------------------------
  // 行访问
  // -------------------------------------------------------------------------

  /** 屏内行（0 = 屏顶）。 */
  getScreenLine(screenRow: number): TerminalRow {
    const index = this.screenFirstRow + screenRow;
    if (index < 0 || index >= this.lines.length) {
      return new TerminalRow(this.screenColumns);
    }
    return this.lines[index];
  }

  /** 包含历史的行（0 = 最旧）。 */
  getLine(index: number): TerminalRow {
    if (index < 0 || index >= this.lines.length) {
      return new TerminalRow(this.screenColumns);
    }
    return this.lines[index];
  }

  get scrollbackLines(): number {
    return this.screenFirstRow;
  }

  // -------------------------------------------------------------------------
  // 清屏
  // -------------------------------------------------------------------------

  clearAll(styleId: number): void {
    this.lines = [];
    for (let i = 0; i < this.screenRows; i++) {
      const row = new TerminalRow(this.screenColumns);
      row.clear(styleId);
      this.lines.push(row);
    }
    this.screenFirstRow = 0;
    this.totalLinesScrolled = 0;
    // ⚠️ R37：**光标也要归零**。改前这里只清行、不动光标，于是「清屏后新输出从哪开始」
    // 取决于上一屏光标停在哪 —— 真机现象：重开终端后新 shell 的提示符落在屏幕**中间**
    // （光标停在旧位置），而不是左上角。
    this.cursorRow = 0;
    this.cursorCol = 0;
  }

  /** 只清屏，保留历史（`CSI 2J` + 光标归位时的常见行为）。 */
  clearScreen(styleId: number): void {
    for (let i = 0; i < this.screenRows; i++) {
      this.getScreenLine(i).clear(styleId);
    }
  }

  // -------------------------------------------------------------------------
  // 滚动
  // -------------------------------------------------------------------------

  /** 屏内 [top,bottom] 区域向上滚 n 行（顶部行出屏）。 */
  scrollUp(top: number, bottom: number, n: number, styleId: number): void {
    if (n <= 0) {
      return;
    }
    const count = Math.min(n, bottom - top + 1);
    for (let i = 0; i < count; i++) {
      this.scrollUpOne(top, bottom, styleId);
    }
  }

  private scrollUpOne(top: number, bottom: number, styleId: number): void {
    const isFullScreen = top === 0 && bottom === this.screenRows - 1;
    if (isFullScreen) {
      // 整屏上滚：把顶行移入历史，末尾新建一行
      const movedIndex = this.screenFirstRow;
      this.screenFirstRow += 1;
      const newRow = new TerminalRow(this.screenColumns);
      newRow.clear(styleId);
      this.lines.push(newRow);
      this.totalLinesScrolled += 1;
      this.trimScrollback(movedIndex);
    } else {
      for (let row = top; row < bottom; row++) {
        this.getScreenLine(row).copyFrom(this.getScreenLine(row + 1));
      }
      const cleared = this.getScreenLine(bottom);
      cleared.clear(styleId);
    }
  }

  /** 屏内 [top,bottom] 区域向下滚 n 行（底部行出屏）。 */
  scrollDown(top: number, bottom: number, n: number, styleId: number): void {
    if (n <= 0) {
      return;
    }
    const count = Math.min(n, bottom - top + 1);
    for (let i = 0; i < count; i++) {
      for (let row = bottom; row > top; row--) {
        this.getScreenLine(row).copyFrom(this.getScreenLine(row - 1));
      }
      this.getScreenLine(top).clear(styleId);
    }
  }

  private trimScrollback(keepFromIndex: number): void {
    if (this.maxScrollback <= 0) {
      const removed = this.lines.splice(0, this.screenFirstRow);
      this.screenFirstRow = 0;
      return;
    }
    const excess = this.screenFirstRow - this.maxScrollback;
    if (excess > 0) {
      this.lines.splice(0, excess);
      this.screenFirstRow -= excess;
    }
  }

  // -------------------------------------------------------------------------
  // 行内编辑
  // -------------------------------------------------------------------------

  /** 在光标行插入 n 个空列（ICH）。 */
  insertColumns(column: number, n: number, styleId: number): void {
    const row = this.getScreenLine(this.cursorRow);
    const count = Math.min(n, this.screenColumns - column);
    for (let i = this.screenColumns - 1; i >= column + count; i--) {
      row.text[i] = row.text[i - count];
      row.style[i] = row.style[i - count];
    }
    for (let i = column; i < column + count; i++) {
      row.text[i] = 0;
      row.style[i] = styleId;
    }
    row.recomputeSpaceUsed();
  }

  /** 删除光标行 n 个列（DCH）。 */
  deleteColumns(column: number, n: number, styleId: number): void {
    const row = this.getScreenLine(this.cursorRow);
    const count = Math.min(n, this.screenColumns - column);
    for (let i = column; i < this.screenColumns - count; i++) {
      row.text[i] = row.text[i + count];
      row.style[i] = row.style[i + count];
    }
    for (let i = this.screenColumns - count; i < this.screenColumns; i++) {
      row.text[i] = 0;
      row.style[i] = styleId;
    }
    row.recomputeSpaceUsed();
  }

  /** 在 [top,bottom] 内光标行处插入 n 行（IL）。 */
  insertLines(top: number, bottom: number, n: number, styleId: number): void {
    this.scrollDown(this.cursorRow, bottom, n, styleId);
  }

  /** 在 [top,bottom] 内光标行处删除 n 行（DL）。 */
  deleteLines(top: number, bottom: number, n: number, styleId: number): void {
    this.scrollUp(this.cursorRow, bottom, n, styleId);
  }

  /** 擦除行的一部分：0=光标到行尾，1=行首到光标，2=整行（EL）。 */
  eraseInLine(mode: number, styleId: number): void {
    const row = this.getScreenLine(this.cursorRow);
    if (mode === 0) {
      for (let i = this.cursorCol; i < this.screenColumns; i++) {
        row.text[i] = 0;
        row.style[i] = styleId;
      }
    } else if (mode === 1) {
      for (let i = 0; i <= this.cursorCol && i < this.screenColumns; i++) {
        row.text[i] = 0;
        row.style[i] = styleId;
      }
    } else {
      row.clear(styleId);
      return;
    }
    row.recomputeSpaceUsed();
  }

  /** 擦除显示区：0=光标到屏尾，1=屏首到光标，2=整屏（ED）。 */
  eraseInDisplay(mode: number, styleId: number): void {
    if (mode === 2) {
      this.clearScreen(styleId);
      return;
    }
    if (mode === 0) {
      this.eraseInLine(0, styleId);
      for (let row = this.cursorRow + 1; row < this.screenRows; row++) {
        this.getScreenLine(row).clear(styleId);
      }
    } else if (mode === 1) {
      this.eraseInLine(1, styleId);
      for (let row = 0; row < this.cursorRow; row++) {
        this.getScreenLine(row).clear(styleId);
      }
    }
  }

  eraseCharacters(n: number, styleId: number): void {
    const row = this.getScreenLine(this.cursorRow);
    const count = Math.min(n, this.screenColumns - this.cursorCol);
    for (let i = this.cursorCol; i < this.cursorCol + count; i++) {
      row.text[i] = 0;
      row.style[i] = styleId;
    }
    row.recomputeSpaceUsed();
  }

  // -------------------------------------------------------------------------
  // 制表位
  // -------------------------------------------------------------------------

  setTabStop(column: number): void {
    if (column >= 0 && column < this.screenColumns) {
      this.tabs[column] = true;
    }
  }

  clearTabStop(column: number): void {
    if (column >= 0 && column < this.screenColumns) {
      this.tabs[column] = false;
    }
  }

  clearAllTabStops(): void {
    for (let i = 0; i < this.screenColumns; i++) {
      this.tabs[i] = false;
    }
  }

  nextTabStop(fromColumn: number): number {
    for (let i = fromColumn + 1; i < this.screenColumns; i++) {
      if (this.tabs[i]) {
        return i;
      }
    }
    return this.screenColumns - 1;
  }

  previousTabStop(fromColumn: number): number {
    for (let i = fromColumn - 1; i >= 0; i--) {
      if (this.tabs[i]) {
        return i;
      }
    }
    return 0;
  }

  // -------------------------------------------------------------------------
  // 光标
  // -------------------------------------------------------------------------

  clampCursor(): void {
    if (this.cursorRow < 0) {
      this.cursorRow = 0;
    }
    if (this.cursorRow >= this.screenRows) {
      this.cursorRow = this.screenRows - 1;
    }
    if (this.cursorCol < 0) {
      this.cursorCol = 0;
    }
    if (this.cursorCol >= this.screenColumns) {
      this.cursorCol = this.screenColumns - 1;
    }
  }

  // -------------------------------------------------------------------------
  // 尺寸变化
  // -------------------------------------------------------------------------

  /** 按新列数复制一行（列变窄时右侧被裁掉，不做回绕重排）。 */
  private cloneRow(row: TerminalRow, columns: number, sourceColumns: number): TerminalRow {
    const copy = new TerminalRow(columns);
    const limit = columns < sourceColumns ? columns : sourceColumns;
    for (let col = 0; col < limit; col++) {
      copy.text[col] = row.text[col];
      copy.style[col] = row.style[col];
    }
    copy.lineWrap = row.lineWrap;
    copy.recomputeSpaceUsed();
    return copy;
  }

  /**
   * 调整屏尺寸（对应 termux `resize`）。
   *
   * ⚠️ 两条不变量，旧实现两条都破了（真机第七轮实测暴露）：
   *
   * ① **光标必须跟着内容一起搬**。屏内容在尺寸变化时是整体位移的（收缩上移、扩张下移），
   *  只对 `cursorRow` 做 clamp 会让光标停在原地、和它所在的那一行分家。
   *  真机现象：键盘收起、网格从 `56x25` 回到 `56x45` 后，提示符落在第 16 行、
   *  光标块却停在第 0 行 —— 看起来像"终端错位了"。
   *
   * ② **收缩时被挤掉的顶部行要进回看区，而不是丢掉**；扩张时再从回看区尾部拉回来。
   *  这样「键盘弹起 → 收起」是一次**可逆往返**，视图能完全还原（终端惯例，同 xterm）。
   *  旧实现收缩时直接丢弃那几行，等于每开一次键盘就吞掉一段输出。
   */
  resize(columns: number, rows: number): void {
    if (columns === this.screenColumns && rows === this.screenRows) {
      return;
    }
    const oldRows = this.screenRows;
    const oldColumns = this.screenColumns;

    const history: TerminalRow[] = [];
    for (let i = 0; i < this.screenFirstRow; i++) {
      history.push(this.cloneRow(this.lines[i], columns, oldColumns));
    }
    const screen: TerminalRow[] = [];
    for (let i = 0; i < oldRows; i++) {
      const row = this.lines[this.screenFirstRow + i];
      screen.push(row !== undefined ? this.cloneRow(row, columns, oldColumns) : new TerminalRow(columns));
    }

    let cursorRow = this.cursorRow;
    if (rows < oldRows) {
      // 收缩：**优先从光标行之下（底部）取行**，不够了才从顶部取并推进回看区。
      //
      // ⚠️ R37：改前一律「顶部 drop 行进回看区，屏内容整体上移」。光标停在第 0 行时
      // （终端刚打开、只有一行提示符），那一刀正好把**唯一有内容的那一行**推出屏幕 ——
      // 真机现象就是「键盘拉起后终端内容跳没了 / 跑到屏幕中间」。
      // 光标下方的行必然是空行（光标总在内容末尾），丢掉它们不损失任何信息。
      const drop = oldRows - rows;
      const belowCursor = oldRows - 1 - this.cursorRow;
      const fromBottom = drop < belowCursor ? drop : belowCursor;
      if (fromBottom > 0) {
        screen.splice(screen.length - fromBottom, fromBottom);
      }
      const fromTop = drop - fromBottom;
      for (let i = 0; i < fromTop; i++) {
        history.push(screen[i]);
      }
      if (fromTop > 0) {
        screen.splice(0, fromTop);
      }
      cursorRow -= fromTop;
    } else {
      // 扩张：优先从回看区尾部拉回同数量的行（键盘开合可逆的关键），不够的**补到底部**。
      // ⚠️ R37：改前补空行用的是 `unshift`（插到**顶部**）—— 每补一行就把内容往下推一行，
      // 这正是「键盘收起 / 页面重开时内容掉到屏幕中间」的来源（43-24=19 行空行全插在顶上）。
      const add = rows - oldRows;
      const pull = add < history.length ? add : history.length;
      for (let i = 0; i < pull; i++) {
        const pulled = history.pop();
        if (pulled !== undefined) {
          screen.unshift(pulled);
        }
      }
      for (let i = pull; i < add; i++) {
        screen.push(new TerminalRow(columns));
      }
      // 只有「拉回来的历史行」才让光标跟着下移；纯补空行不动光标（内容留在原处）。
      cursorRow += pull;
    }

    // 回看区超上限时从最旧的一端裁掉（与 trimScrollback 同语义）
    if (this.maxScrollback <= 0) {
      history.splice(0, history.length);
    } else if (history.length > this.maxScrollback) {
      history.splice(0, history.length - this.maxScrollback);
    }

    this.lines = history.concat(screen);
    this.screenFirstRow = history.length;
    this.screenColumns = columns;
    this.screenRows = rows;
    this.rightMargin = columns - 1;
    this.topMargin = 0;
    this.bottomMargin = rows - 1;
    this.initTabs();
    if (cursorRow < 0) {
      cursorRow = 0;
    }
    if (cursorRow >= rows) {
      cursorRow = rows - 1;
    }
    this.cursorRow = cursorRow;
    if (this.cursorCol < 0) {
      this.cursorCol = 0;
    }
    if (this.cursorCol >= columns) {
      this.cursorCol = columns - 1;
    }
  }

  /** 把当前屏内容快照成纯文本（测试/复制用）。 */
  snapshotText(): string {
    const out: string[] = [];
    for (let i = 0; i < this.screenRows; i++) {
      out.push(this.getScreenLine(i).toText());
    }
    return out.join('\n');
  }

}
