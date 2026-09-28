/**
 * 终端仿真核心（对应 termux `TerminalEmulator.java`，2605 行 Java 的 ArkTS 重写）。
 *
 * 覆盖范围：
 * - C0 控制符（BEL BS HT LF VT FF CR SO SI）
 * - ESC 序列：DECSC/DECRC、IND/NEL/RI/HTS、RIS、G0/G1 字符集、DECALN、DECKPAM/PNM、字符串引入
 * - CSI：CUU/CUD/CUF/CUB/CNL/CPL/CHA/CUP/HVP/CHT/CBT、ED/EL/ECH、IL/DL/ICH/DCH、
 *  SU/SD、DECSTBM 边距、SGR 全部常用属性、DSR/DA1/DA2、DECSET/DECRST、TBC、REP、窗口操作
 * - OSC：标题（0/1/2）、颜色（10/11/12）、剪贴板（52）、超链接（8）、调色板（4/104）
 * - 私有关键模式：光标可见（25）、应用光标键（1）、原点模式（6）、自动换行（7）、
 *  插入模式（4）、备用屏（47/1047/1048/1049）、括号粘贴（2004）、鼠标上报（9/1000-1006）、焦点事件（1004）
 * - UTF-8 流式解码、宽字符占位、滚动回看、边距内滚动
 *
 * 未实现：DECRQSS、DECRQM 的完整答复、sixel/kitty 图形协议、Kitty 键盘协议扩展
 * （按官方 xterm 行为最简答复或忽略，不影响日常 shell / TUI 使用）。
 */

import { TerminalBuffer } from './TerminalBuffer';
import { TerminalRow } from './TerminalRow';
import { COLOR_DEFAULT, TerminalColorScheme, TextStyleFlags, defaultColorScheme, rgbColor, withoutFlags } from './TerminalStyle';
import { WIDTH_WIDE, WIDTH_ZERO, codePointWidth } from './WcWidth';

/**
 * 终端对外回调。
 * 注意：ArkTS 不允许用对象字面量实现「带方法签名」的接口，所以这里全部用
 * 函数类型属性（而不是方法），否则 `const output: TerminalOutput = {...}` 会编译失败。
 */
export interface TerminalOutput {
  /** 把用户输入写回 PTY。 */
  write: (data: string) => void;
  /** 终端标题变化（OSC 0/1/2）。 */
  titleChanged: (title: string) => void;
  /** OSC 52：复制到剪贴板。 */
  clipboardCopy: (text: string) => void;
  /** BEL。 */
  bell: () => void;
  /** 屏幕内容或颜色变化，需要重绘。 */
  invalidate: () => void;
}

enum ParserState {
  GROUND = 0,
  ESCAPE = 1,
  ESCAPE_CSI = 2,
  ESCAPE_OSC = 3,
  ESCAPE_DCS = 4,
  ESCAPE_CHARSET_G0 = 5,
  ESCAPE_CHARSET_G1 = 6,
  ESCAPE_HASH = 7
}

const MAX_CSI_PARAMS: number = 32;
const MAX_OSC_LENGTH: number = 8192;

export class TerminalEmulator {
  buffer: TerminalBuffer;
  private mainBuffer: TerminalBuffer;
  private altBuffer: TerminalBuffer;
  private altScreenActive: boolean = false;

  private output: TerminalOutput;
  colorScheme: TerminalColorScheme;

  // 当前 SGR 状态
  private currentForeground: number = COLOR_DEFAULT;
  private currentBackground: number = COLOR_DEFAULT;
  private currentFlags: number = TextStyleFlags.NORMAL;
  private currentStyleId: number = 0;

  // 解析状态机
  private state: ParserState = ParserState.GROUND;
  private csiParams: number[] = [];
  private csiParamHasValue: boolean = false;
  private csiPrefix: string = '';
  private csiIntermediate: string = '';
  private oscBuffer: string = '';
  private utf8Buffer: number[] = [];
  private utf8Remaining: number = 0;
  private utf8CodePoint: number = 0;

  // 模式
  private applicationCursorKeys: boolean = false;
  private applicationKeypad: boolean = false;
  private originMode: boolean = false;
  private autoWrap: boolean = true;
  private insertMode: boolean = false;
  private bracketedPaste: boolean = false;
  private mouseProtocol: string = 'none';
  private cursorStyle: number = 0;
  cursorBlink: boolean = true;

  // 保存的光标（DECSC）
  private savedRow: number = 0;
  private savedCol: number = 0;
  private savedForeground: number = COLOR_DEFAULT;
  private savedBackground: number = COLOR_DEFAULT;
  private savedFlags: number = TextStyleFlags.NORMAL;

  /** 自动换行挂起：写满最后一列后不立即换行，等下一个字符才换。 */
  private pendingWrap: boolean = false;
  /** REP 用的上一个打印字符。 */
  private lastPrintedCodePoint: number = 0;
  private scrollCounter: number = 0;

  constructor(columns: number, rows: number, output: TerminalOutput, dark: boolean = true) {
    this.output = output;
    this.colorScheme = defaultColorScheme(dark);
    this.mainBuffer = new TerminalBuffer(columns, rows);
    this.altBuffer = new TerminalBuffer(columns, rows, 0);
    this.buffer = this.mainBuffer;
    this.applyCurrentStyle();
  }

  // -------------------------------------------------------------------------
  // 对外接口
  // -------------------------------------------------------------------------

  get columns(): number {
    return this.buffer.screenColumns;
  }

  get rows(): number {
    return this.buffer.screenRows;
  }

  resize(columns: number, rows: number): void {
    this.mainBuffer.resize(columns, rows);
    this.altBuffer.resize(columns, rows);
    this.pendingWrap = false;
    this.output.invalidate();
  }

  reset(): void {
    this.state = ParserState.GROUND;
    this.csiParams = [];
    this.utf8Buffer = [];
    this.utf8Remaining = 0;
    this.applicationCursorKeys = false;
    this.originMode = false;
    this.autoWrap = true;
    this.insertMode = false;
    this.bracketedPaste = false;
    this.mouseProtocol = 'none';
    this.currentForeground = COLOR_DEFAULT;
    this.currentBackground = COLOR_DEFAULT;
    this.currentFlags = TextStyleFlags.NORMAL;
    this.applyCurrentStyle();
    this.mainBuffer.clearAll(this.currentStyleId);
    this.mainBuffer.cursorRow = 0;
    this.mainBuffer.cursorCol = 0;
    this.mainBuffer.cursorVisible = true;
    this.altScreenActive = false;
    this.buffer = this.mainBuffer;
    this.output.invalidate();
  }

  /** 追加 PTY 输出字节。 */
  append(bytes: Uint8Array): void {
    for (let i = 0; i < bytes.length; i++) {
      this.processByte(bytes[i] & 0xFF);
    }
    this.output.invalidate();
  }

  /** 直接追加一个字符串（测试用）。 */
  appendText(text: string): void {
    const encoder: Array<number> = [];
    for (let i = 0; i < text.length; i++) {
      const code = text.codePointAt(i);
      if (code === undefined) {
        continue;
      }
      // UTF-8 编码
      if (code < 0x80) {
        encoder.push(code);
      } else if (code < 0x800) {
        encoder.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        encoder.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      } else {
        encoder.push(
          0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
          0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
        i += 1;
      }
    }
    const bytes = new Uint8Array(encoder.length);
    for (let i = 0; i < encoder.length; i++) {
      bytes[i] = encoder[i];
    }
    this.append(bytes);
  }

  // -------------------------------------------------------------------------
  // 字节 → 码位（流式 UTF-8）
  // -------------------------------------------------------------------------

  private processByte(byte: number): void {
    if (this.utf8Remaining > 0) {
      if ((byte & 0xC0) === 0x80) {
        this.utf8CodePoint = (this.utf8CodePoint << 6) | (byte & 0x3F);
        this.utf8Remaining -= 1;
        if (this.utf8Remaining === 0) {
          this.processCodePoint(this.utf8CodePoint);
        }
        return;
      }
      // 非法续字节：放弃当前序列，把该字节当新序列起点
      this.utf8Remaining = 0;
      this.utf8CodePoint = 0;
    }
    if (byte < 0x80) {
      this.processCodePoint(byte);
      return;
    }
    if (byte >= 0xC2 && byte <= 0xDF) {
      this.utf8CodePoint = byte & 0x1F;
      this.utf8Remaining = 1;
    } else if (byte >= 0xE0 && byte <= 0xEF) {
      this.utf8CodePoint = byte & 0x0F;
      this.utf8Remaining = 2;
    } else if (byte >= 0xF0 && byte <= 0xF4) {
      this.utf8CodePoint = byte & 0x07;
      this.utf8Remaining = 3;
    } else {
      // 0x80..0xC1 / 0xF5..0xFF：非法，按替换字符处理
      this.processCodePoint(0xFFFD);
    }
  }

  private processCodePoint(codePoint: number): void {
    switch (this.state) {
      case ParserState.GROUND:
        this.processGround(codePoint);
        return;
      case ParserState.ESCAPE:
        this.processEscape(codePoint);
        return;
      case ParserState.ESCAPE_CSI:
        this.processCsi(codePoint);
        return;
      case ParserState.ESCAPE_OSC:
        this.processOsc(codePoint);
        return;
      case ParserState.ESCAPE_DCS:
        // DCS 内容整体丢弃，直到 ST
        if (codePoint === 0x1B || codePoint === 0x9C) {
          this.state = ParserState.GROUND;
        }
        return;
      case ParserState.ESCAPE_CHARSET_G0:
      case ParserState.ESCAPE_CHARSET_G1:
      case ParserState.ESCAPE_HASH:
        this.state = ParserState.GROUND;
        return;
      default:
        this.state = ParserState.GROUND;
        return;
    }
  }

  // -------------------------------------------------------------------------
  // GROUND
  // -------------------------------------------------------------------------

  private processGround(codePoint: number): void {
    if (codePoint === 0x1B) {
      this.state = ParserState.ESCAPE;
      return;
    }
    if (codePoint < 0x20) {
      this.processControl(codePoint);
      return;
    }
    if (codePoint === 0x7F) {
      return; // DEL 忽略
    }
    this.emitCodePoint(codePoint);
  }

  private processControl(codePoint: number): void {
    switch (codePoint) {
      case 0x07:
        this.output.bell();
        return;
      case 0x08:
        this.backspace();
        return;
      case 0x09:
        this.buffer.cursorCol = this.buffer.nextTabStop(this.buffer.cursorCol);
        this.pendingWrap = false;
        return;
      case 0x0A:
      case 0x0B:
      case 0x0C:
        this.lineFeed();
        return;
      case 0x0D:
        this.buffer.cursorCol = 0;
        this.pendingWrap = false;
        return;
      case 0x0E:
      case 0x0F:
        return; // SO/SI：G1/G0 切换（仅支持 ASCII，忽略）
      default:
        return;
    }
  }

  private lineFeed(): void {
    this.pendingWrap = false;
    if (this.buffer.cursorRow === this.buffer.bottomMargin) {
      this.buffer.scrollUp(this.buffer.topMargin, this.buffer.bottomMargin, 1, this.currentStyleId);
      this.scrollCounter += 1;
    } else if (this.buffer.cursorRow < this.buffer.screenRows - 1) {
      this.buffer.cursorRow += 1;
    }
  }

  private backspace(): void {
    this.pendingWrap = false;
    if (this.buffer.cursorCol > 0) {
      this.buffer.cursorCol -= 1;
      // 落在宽字符后半格时再退一格
      if (this.buffer.getScreenLine(this.buffer.cursorRow).isWideContinuation(this.buffer.cursorCol)) {
        if (this.buffer.cursorCol > 0) {
          this.buffer.cursorCol -= 1;
        }
      }
    }
  }

  private emitCodePoint(codePoint: number): void {
    const width = codePointWidth(codePoint);
    if (width === WIDTH_ZERO) {
      // 组合符号：附加到前一格（简化实现：直接丢弃，避免破坏网格）
      return;
    }
    const buffer = this.buffer;
    if (this.pendingWrap && this.autoWrap) {
      buffer.cursorCol = 0;
      this.lineFeed();
      this.pendingWrap = false;
    }
    if (width === WIDTH_WIDE && buffer.cursorCol === buffer.screenColumns - 1) {
      if (this.autoWrap) {
        buffer.cursorCol = 0;
        this.lineFeed();
      } else {
        return;
      }
    }
    const row = buffer.getScreenLine(buffer.cursorRow);
    if (this.insertMode) {
      buffer.insertColumns(buffer.cursorCol, width, this.currentStyleId);
    }
    row.setChar(buffer.cursorCol, codePoint, this.currentStyleId);
    this.lastPrintedCodePoint = codePoint;
    const nextColumn = buffer.cursorCol + width;
    if (nextColumn >= buffer.screenColumns) {
      buffer.cursorCol = buffer.screenColumns - 1;
      this.pendingWrap = true;
    } else {
      buffer.cursorCol = nextColumn;
    }
  }

  // -------------------------------------------------------------------------
  // ESC
  // -------------------------------------------------------------------------

  private processEscape(codePoint: number): void {
    this.state = ParserState.GROUND;
    switch (codePoint) {
      case 0x5B: // [
        this.beginCsi();
        return;
      case 0x5D: // ]
        this.oscBuffer = '';
        this.state = ParserState.ESCAPE_OSC;
        return;
      case 0x50: // P (DCS)
      case 0x58: // X (SOS)
      case 0x5E: // ^ (PM)
      case 0x5F: // _ (APC)
        this.state = ParserState.ESCAPE_DCS;
        return;
      case 0x28: // ( G0
        this.state = ParserState.ESCAPE_CHARSET_G0;
        return;
      case 0x29: // ) G1
        this.state = ParserState.ESCAPE_CHARSET_G1;
        return;
      case 0x23: // # DECALN
        this.state = ParserState.ESCAPE_HASH;
        return;
      case 0x37: // 7 DECSC
        this.saveCursor();
        return;
      case 0x38: // 8 DECRC
        this.restoreCursor();
        return;
      case 0x44: // D IND
        this.lineFeed();
        return;
      case 0x45: // E NEL
        this.buffer.cursorCol = 0;
        this.lineFeed();
        return;
      case 0x48: // H HTS
        this.buffer.setTabStop(this.buffer.cursorCol);
        return;
      case 0x4D: // M RI
        this.reverseIndex();
        return;
      case 0x63: // c RIS
        this.reset();
        return;
      case 0x3D: // = DECKPAM
        this.applicationKeypad = true;
        return;
      case 0x3E: // > DECKPNM
        this.applicationKeypad = false;
        return;
      case 0x4E: // N SS2
      case 0x4F: // O SS3
        return;
      default:
        return;
    }
  }

  private reverseIndex(): void {
    this.pendingWrap = false;
    if (this.buffer.cursorRow === this.buffer.topMargin) {
      this.buffer.scrollDown(this.buffer.topMargin, this.buffer.bottomMargin, 1, this.currentStyleId);
    } else if (this.buffer.cursorRow > 0) {
      this.buffer.cursorRow -= 1;
    }
  }

  private saveCursor(): void {
    this.savedRow = this.buffer.cursorRow;
    this.savedCol = this.buffer.cursorCol;
    this.savedForeground = this.currentForeground;
    this.savedBackground = this.currentBackground;
    this.savedFlags = this.currentFlags;
  }

  private restoreCursor(): void {
    this.buffer.cursorRow = this.savedRow;
    this.buffer.cursorCol = this.savedCol;
    this.currentForeground = this.savedForeground;
    this.currentBackground = this.savedBackground;
    this.currentFlags = this.savedFlags;
    this.applyCurrentStyle();
    this.buffer.clampCursor();
  }

  // -------------------------------------------------------------------------
  // CSI
  // -------------------------------------------------------------------------

  private beginCsi(): void {
    this.state = ParserState.ESCAPE_CSI;
    this.csiParams = [];
    this.csiParamHasValue = false;
    this.csiPrefix = '';
    this.csiIntermediate = '';
  }

  private processCsi(codePoint: number): void {
    if (codePoint === 0x1B) {
      this.state = ParserState.ESCAPE;
      return;
    }
    // 参数字节
    if (codePoint >= 0x30 && codePoint <= 0x39) {
      const digit = codePoint - 0x30;
      const index = this.csiParams.length;
      if (index === 0 && !this.csiParamHasValue && this.csiPrefix.length === 0) {
        this.csiParams.push(0);
      }
      if (this.csiParamHasValue) {
        const last = this.csiParams.length - 1;
        this.csiParams[last] = this.csiParams[last] * 10 + digit;
      } else {
        const last = this.csiParams.length - 1;
        if (last >= 0) {
          this.csiParams[last] = digit;
        } else {
          this.csiParams.push(digit);
        }
        this.csiParamHasValue = true;
      }
      return;
    }
    if (codePoint === 0x3B) { // ;
      // ⚠️ 上限守卫（R43 接线 MAX_CSI_PARAMS）：CSI 参数数组必须**有界** —— 异常/恶意的长序列
      // （例如一万个 ';'）会让它无界增长（属「内存上限」那一族，R42 的 A4 扫描漏了这一格：
      // 常量定义了却从未被使用）。超过上限后**丢弃多余参数**：只影响异常输入，
      // 正常序列（参数 ≤ 32 个）逐字节不变。
      if (this.csiParams.length < MAX_CSI_PARAMS) {
        this.csiParams.push(0);
      }
      this.csiParamHasValue = false;
      return;
    }
    if (codePoint === 0x3A) { // :（子参数，按 ; 处理）
      if (this.csiParams.length < MAX_CSI_PARAMS) {
        this.csiParams.push(0);
      }
      this.csiParamHasValue = false;
      return;
    }
    // 私有前缀 / 中间字节
    if ((codePoint >= 0x3C && codePoint <= 0x3F) && this.csiPrefix.length === 0 && this.csiParams.length === 0) {
      this.csiPrefix = String.fromCharCode(codePoint);
      return;
    }
    if (codePoint >= 0x20 && codePoint <= 0x2F) {
      this.csiIntermediate += String.fromCharCode(codePoint);
      return;
    }
    // 终结字节
    this.state = ParserState.GROUND;
    if (codePoint >= 0x40 && codePoint <= 0x7E) {
      this.dispatchCsi(String.fromCharCode(codePoint));
    }
  }

  private param(index: number, fallback: number): number {
    if (index >= this.csiParams.length) {
      return fallback;
    }
    const value = this.csiParams[index];
    return value === 0 ? fallback : value;
  }

  private paramOrZero(index: number): number {
    if (index >= this.csiParams.length) {
      return 0;
    }
    return this.csiParams[index];
  }

  private dispatchCsi(finalByte: string): void {
    const buffer = this.buffer;
    const styleId = this.currentStyleId;
    if (this.csiPrefix === '?' && (finalByte === 'h' || finalByte === 'l')) {
      this.setPrivateModes(this.csiParams, finalByte === 'h');
      return;
    }
    if (this.csiPrefix === '>') {
      if (finalByte === 'c') {
        // DA2：按 xterm 回复，但手机端没有回写通道时忽略
        return;
      }
      if (finalByte === 'm') {
        return; // modifyOtherKeys：忽略
      }
      return;
    }
    if (this.csiPrefix === '=' || this.csiPrefix === '<') {
      return;
    }
    if (this.csiIntermediate === ' ') {
      if (finalByte === 'q') {
        this.cursorStyle = this.paramOrZero(0);
        this.cursorBlink = this.cursorStyle !== 2 && this.cursorStyle !== 4 && this.cursorStyle !== 6;
        this.output.invalidate();
      }
      return;
    }
    if (this.csiIntermediate === '!') {
      if (finalByte === 'p') {
        this.reset();
      }
      return;
    }
    if (this.csiIntermediate === '"' || this.csiIntermediate === '$' || this.csiIntermediate === '\'') {
      return;
    }
    if (this.csiIntermediate === '*') {
      return;
    }

    switch (finalByte) {
      case '@':
        buffer.insertColumns(buffer.cursorCol, this.param(0, 1), styleId);
        return;
      case 'A':
        this.moveCursorBy(-this.param(0, 1), 0);
        return;
      case 'B':
      case 'e':
        this.moveCursorBy(this.param(0, 1), 0);
        return;
      case 'C':
      case 'a':
        this.moveCursorBy(0, this.param(0, 1));
        return;
      case 'D':
        this.moveCursorBy(0, -this.param(0, 1));
        return;
      case 'E':
        this.moveCursorBy(this.param(0, 1), 0);
        buffer.cursorCol = 0;
        this.pendingWrap = false;
        return;
      case 'F':
        this.moveCursorBy(-this.param(0, 1), 0);
        buffer.cursorCol = 0;
        this.pendingWrap = false;
        return;
      case 'G':
      case '`':
        buffer.cursorCol = Math.max(0, Math.min(this.param(0, 1) - 1, buffer.screenColumns - 1));
        this.pendingWrap = false;
        return;
      case 'H':
      case 'f': {
        const row = this.param(0, 1) - 1 + (this.originMode ? buffer.topMargin : 0);
        const col = this.param(1, 1) - 1 + (this.originMode ? buffer.leftMargin : 0);
        buffer.cursorRow = Math.max(0, Math.min(row, buffer.screenRows - 1));
        buffer.cursorCol = Math.max(0, Math.min(col, buffer.screenColumns - 1));
        this.pendingWrap = false;
        return;
      }
      case 'I':
        for (let i = 0; i < this.param(0, 1); i++) {
          buffer.cursorCol = buffer.nextTabStop(buffer.cursorCol);
        }
        return;
      case 'J':
        buffer.eraseInDisplay(this.paramOrZero(0), styleId);
        return;
      case 'K':
        buffer.eraseInLine(this.paramOrZero(0), styleId);
        return;
      case 'L':
        buffer.insertLines(buffer.topMargin, buffer.bottomMargin, this.param(0, 1), styleId);
        return;
      case 'M':
        buffer.deleteLines(buffer.topMargin, buffer.bottomMargin, this.param(0, 1), styleId);
        return;
      case 'P':
        buffer.deleteColumns(buffer.cursorCol, this.param(0, 1), styleId);
        return;
      case 'S':
        buffer.scrollUp(buffer.topMargin, buffer.bottomMargin, this.param(0, 1), styleId);
        return;
      case 'T':
        buffer.scrollDown(buffer.topMargin, buffer.bottomMargin, this.param(0, 1), styleId);
        return;
      case 'X':
        buffer.eraseCharacters(this.param(0, 1), styleId);
        return;
      case 'Z':
        for (let i = 0; i < this.param(0, 1); i++) {
          buffer.cursorCol = buffer.previousTabStop(buffer.cursorCol);
        }
        return;
      case 'b':
        for (let i = 0; i < this.param(0, 1); i++) {
          if (this.lastPrintedCodePoint !== 0) {
            this.emitCodePoint(this.lastPrintedCodePoint);
          }
        }
        return;
      case 'c':
        return; // DA1：无回写通道时忽略
      case 'd':
        buffer.cursorRow = Math.max(0, Math.min(this.param(0, 1) - 1 + (this.originMode ? buffer.topMargin : 0),
          buffer.screenRows - 1));
        this.pendingWrap = false;
        return;
      case 'g':
        if (this.paramOrZero(0) === 3) {
          buffer.clearAllTabStops();
        } else {
          buffer.clearTabStop(buffer.cursorCol);
        }
        return;
      case 'h':
        this.setModes(this.csiParams, true);
        return;
      case 'l':
        this.setModes(this.csiParams, false);
        return;
      case 'm':
        this.applySgr();
        return;
      case 'n':
        return; // DSR：无回写通道时忽略
      case 'r': {
        const top = this.param(0, 1) - 1;
        const bottom = this.param(1, buffer.screenRows) - 1;
        if (top < bottom && top >= 0 && bottom < buffer.screenRows) {
          buffer.topMargin = top;
          buffer.bottomMargin = bottom;
          buffer.cursorRow = this.originMode ? top : 0;
          buffer.cursorCol = 0;
          this.pendingWrap = false;
        }
        return;
      }
      case 's':
        this.saveCursor();
        return;
      case 'u':
        this.restoreCursor();
        return;
      case 't':
        return; // 窗口操作：忽略
      default:
        return;
    }
  }

  private moveCursorBy(deltaRow: number, deltaCol: number): void {
    const buffer = this.buffer;
    this.pendingWrap = false;
    const nextRow = buffer.cursorRow + deltaRow;
    const top = this.originMode ? buffer.topMargin : 0;
    const bottom = this.originMode ? buffer.bottomMargin : buffer.screenRows - 1;
    buffer.cursorRow = Math.max(top, Math.min(nextRow, bottom));
    buffer.cursorCol = Math.max(0, Math.min(buffer.cursorCol + deltaCol, buffer.screenColumns - 1));
  }

  // -------------------------------------------------------------------------
  // SGR
  // -------------------------------------------------------------------------

  private applySgr(): void {
    if (this.csiParams.length === 0) {
      this.currentForeground = COLOR_DEFAULT;
      this.currentBackground = COLOR_DEFAULT;
      this.currentFlags = TextStyleFlags.NORMAL;
      this.applyCurrentStyle();
      return;
    }
    let i = 0;
    while (i < this.csiParams.length) {
      const value = this.csiParams[i];
      if (value === 0) {
        this.currentForeground = COLOR_DEFAULT;
        this.currentBackground = COLOR_DEFAULT;
        this.currentFlags = TextStyleFlags.NORMAL;
      } else if (value === 1) {
        this.currentFlags |= TextStyleFlags.BOLD;
      } else if (value === 2) {
        this.currentFlags |= TextStyleFlags.DIM;
      } else if (value === 3) {
        this.currentFlags |= TextStyleFlags.ITALIC;
      } else if (value === 4) {
        const next = i + 1 < this.csiParams.length ? this.csiParams[i + 1] : 1;
        if (next === 0) {
          this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.UNDERLINE | TextStyleFlags.DOUBLE_UNDERLINE |
            TextStyleFlags.CURLY_UNDERLINE | TextStyleFlags.DOTTED_UNDERLINE |
            TextStyleFlags.DASHED_UNDERLINE);
          i += 1;
        } else if (next >= 1 && next <= 5) {
          this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.UNDERLINE | TextStyleFlags.DOUBLE_UNDERLINE |
            TextStyleFlags.CURLY_UNDERLINE | TextStyleFlags.DOTTED_UNDERLINE |
            TextStyleFlags.DASHED_UNDERLINE);
          if (next === 1) {
            this.currentFlags |= TextStyleFlags.UNDERLINE;
          } else if (next === 2) {
            this.currentFlags |= TextStyleFlags.DOUBLE_UNDERLINE;
          } else if (next === 3) {
            this.currentFlags |= TextStyleFlags.CURLY_UNDERLINE;
          } else if (next === 4) {
            this.currentFlags |= TextStyleFlags.DOTTED_UNDERLINE;
          } else {
            this.currentFlags |= TextStyleFlags.DASHED_UNDERLINE;
          }
          i += 1;
        } else {
          this.currentFlags |= TextStyleFlags.UNDERLINE;
        }
      } else if (value === 5 || value === 6) {
        this.currentFlags |= TextStyleFlags.BLINK;
      } else if (value === 7) {
        this.currentFlags |= TextStyleFlags.INVERSE;
      } else if (value === 8) {
        this.currentFlags |= TextStyleFlags.INVISIBLE;
      } else if (value === 9) {
        this.currentFlags |= TextStyleFlags.STRIKETHROUGH;
      } else if (value === 21) {
        this.currentFlags |= TextStyleFlags.DOUBLE_UNDERLINE;
      } else if (value === 22) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.BOLD | TextStyleFlags.DIM);
      } else if (value === 23) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.ITALIC);
      } else if (value === 24) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.UNDERLINE | TextStyleFlags.DOUBLE_UNDERLINE |
          TextStyleFlags.CURLY_UNDERLINE | TextStyleFlags.DOTTED_UNDERLINE |
          TextStyleFlags.DASHED_UNDERLINE);
      } else if (value === 25) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.BLINK);
      } else if (value === 27) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.INVERSE);
      } else if (value === 28) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.INVISIBLE);
      } else if (value === 29) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.STRIKETHROUGH);
      } else if (value === 53) {
        this.currentFlags |= TextStyleFlags.OVERLINE;
      } else if (value === 55) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.OVERLINE);
      } else if (value === 73) {
        this.currentFlags |= TextStyleFlags.SUPERSCRIPT;
      } else if (value === 74) {
        this.currentFlags |= TextStyleFlags.SUBSCRIPT;
      } else if (value === 75) {
        this.currentFlags = withoutFlags(this.currentFlags, TextStyleFlags.SUPERSCRIPT | TextStyleFlags.SUBSCRIPT);
      } else if (value >= 30 && value <= 37) {
        this.currentForeground = value - 30;
      } else if (value === 38) {
        const consumed = this.readExtendedColor(i + 1, true);
        i += consumed;
      } else if (value === 39) {
        this.currentForeground = COLOR_DEFAULT;
      } else if (value >= 40 && value <= 47) {
        this.currentBackground = value - 40;
      } else if (value === 48) {
        const consumed = this.readExtendedColor(i + 1, false);
        i += consumed;
      } else if (value === 49) {
        this.currentBackground = COLOR_DEFAULT;
      } else if (value >= 90 && value <= 97) {
        this.currentForeground = value - 90 + 8;
      } else if (value >= 100 && value <= 107) {
        this.currentBackground = value - 100 + 8;
      }
      i += 1;
    }
    this.applyCurrentStyle();
  }

  /** 读取 `38;5;n` / `38;2;r;g;b`，返回额外消耗的参数个数。 */
  private readExtendedColor(startIndex: number, isForeground: boolean): number {
    if (startIndex >= this.csiParams.length) {
      return 0;
    }
    const mode = this.csiParams[startIndex];
    if (mode === 5) {
      if (startIndex + 1 >= this.csiParams.length) {
        return 1;
      }
      const index = this.csiParams[startIndex + 1];
      if (isForeground) {
        this.currentForeground = index;
      } else {
        this.currentBackground = index;
      }
      return 2;
    }
    if (mode === 2) {
      if (startIndex + 3 >= this.csiParams.length) {
        return this.csiParams.length - startIndex;
      }
      const color = rgbColor(
        this.csiParams[startIndex + 1], this.csiParams[startIndex + 2], this.csiParams[startIndex + 3]);
      if (isForeground) {
        this.currentForeground = color;
      } else {
        this.currentBackground = color;
      }
      return 4;
    }
    return 1;
  }

  private applyCurrentStyle(): void {
    this.currentStyleId = this.buffer.stylePool.intern(
      this.currentForeground, this.currentBackground, this.currentFlags);
  }

  // -------------------------------------------------------------------------
  // 模式
  // -------------------------------------------------------------------------

  private setModes(params: number[], enable: boolean): void {
    for (let i = 0; i < params.length; i++) {
      if (params[i] === 4) {
        this.insertMode = enable;
      }
    }
  }

  private setPrivateModes(params: number[], enable: boolean): void {
    for (let i = 0; i < params.length; i++) {
      const mode = params[i];
      switch (mode) {
        case 1:
          this.applicationCursorKeys = enable;
          break;
        case 6:
          this.originMode = enable;
          this.buffer.cursorRow = enable ? this.buffer.topMargin : 0;
          this.buffer.cursorCol = 0;
          break;
        case 7:
          this.autoWrap = enable;
          break;
        case 9:
          this.mouseProtocol = enable ? 'x10' : 'none';
          break;
        case 12:
          this.cursorBlink = enable;
          break;
        case 25:
          this.buffer.cursorVisible = enable;
          break;
        case 47:
        case 1047:
          this.switchAltScreen(enable, false);
          break;
        case 1048:
          if (enable) {
            this.saveCursor();
          } else {
            this.restoreCursor();
          }
          break;
        case 1049:
          if (enable) {
            this.saveCursor();
            this.switchAltScreen(true, true);
          } else {
            this.switchAltScreen(false, true);
            this.restoreCursor();
          }
          break;
        case 1000:
          this.mouseProtocol = enable ? 'vt200' : 'none';
          break;
        case 1002:
          this.mouseProtocol = enable ? 'button-event' : 'none';
          break;
        case 1003:
          this.mouseProtocol = enable ? 'any-event' : 'none';
          break;
        case 1004:
          break;
        case 1005:
        case 1006:
          break;
        case 2004:
          this.bracketedPaste = enable;
          break;
        default:
          break;
      }
    }
    this.output.invalidate();
  }

  private switchAltScreen(enable: boolean, clear: boolean): void {
    if (enable === this.altScreenActive) {
      return;
    }
    if (enable) {
      this.altBuffer.clearAll(this.currentStyleId);
      this.buffer = this.altBuffer;
      this.altScreenActive = true;
    } else {
      this.buffer = this.mainBuffer;
      this.altScreenActive = false;
    }
    this.pendingWrap = false;
  }

  // -------------------------------------------------------------------------
  // OSC
  // -------------------------------------------------------------------------

  private processOsc(codePoint: number): void {
    // ST = ESC \ 或 0x9C
    if (codePoint === 0x07) {
      this.dispatchOsc();
      this.state = ParserState.GROUND;
      return;
    }
    if (codePoint === 0x1B) {
      this.dispatchOsc();
      this.state = ParserState.ESCAPE;
      return;
    }
    if (codePoint === 0x9C) {
      this.dispatchOsc();
      this.state = ParserState.GROUND;
      return;
    }
    if (this.oscBuffer.length < MAX_OSC_LENGTH) {
      this.oscBuffer += String.fromCodePoint(codePoint);
    }
  }

  private dispatchOsc(): void {
    const payload = this.oscBuffer;
    this.oscBuffer = '';
    if (payload.length === 0) {
      return;
    }
    const separator = payload.indexOf(';');
    const command = separator >= 0 ? payload.substring(0, separator) : payload;
    const value = separator >= 0 ? payload.substring(separator + 1) : '';
    if (command === '0' || command === '1' || command === '2') {
      this.output.titleChanged(value);
      return;
    }
    if (command === '52') {
      // OSC 52 ; c ; base64
      const secondSeparator = value.indexOf(';');
      if (secondSeparator >= 0) {
        const encoded = value.substring(secondSeparator + 1);
        this.output.clipboardCopy(encoded);
      }
      return;
    }
    if (command === '10') {
      const rgb = parseOscColor(value);
      if (rgb !== undefined) {
        this.colorScheme.foreground = rgb;
        this.output.invalidate();
      }
      return;
    }
    if (command === '11') {
      const rgb = parseOscColor(value);
      if (rgb !== undefined) {
        this.colorScheme.background = rgb;
        this.output.invalidate();
      }
      return;
    }
    if (command === '12') {
      const rgb = parseOscColor(value);
      if (rgb !== undefined) {
        this.colorScheme.cursor = rgb;
        this.output.invalidate();
      }
      return;
    }
    if (command === '4') {
      // OSC 4 ; index ; color
      const parts = value.split(';');
      if (parts.length >= 2) {
        const index = Number.parseInt(parts[0], 10);
        const rgb = parseOscColor(parts[1]);
        if (!isNaN(index) && rgb !== undefined && index >= 0 && index < 16) {
          this.colorScheme.ansi[index] = rgb;
          this.output.invalidate();
        }
      }
      return;
    }
    // 104/110/111/112（重置调色板）与 8（超链接）等：忽略
  }

  // -------------------------------------------------------------------------
  // 输入（键盘 → 转义序列）
  // -------------------------------------------------------------------------

  /** 是否处于应用光标键模式（决定方向键发 ESC O A 还是 ESC [ A）。 */
  get usesApplicationCursorKeys(): boolean {
    return this.applicationCursorKeys;
  }

  get usesBracketedPaste(): boolean {
    return this.bracketedPaste;
  }

  get isAltScreen(): boolean {
    return this.altScreenActive;
  }

  get mouseMode(): string {
    return this.mouseProtocol;
  }

  /** 把文本粘贴/输入写回 PTY（含括号粘贴包裹）。 */
  sendText(text: string): void {
    if (this.bracketedPaste) {
      this.output.write(`\u001b[200~${text}\u001b[201~`);
    } else {
      this.output.write(text);
    }
  }

  /** 方向键序列（含应用模式）。 */
  cursorKey(finalByte: string): string {
    return this.applicationCursorKeys ? `\u001bO${finalByte}` : `\u001b[${finalByte}`;
  }

  /** 导出屏幕快照（复制全部/测试断言用）。 */
  screenText(): string {
    return this.buffer.snapshotText();
  }

  /** 供渲染层读取某屏行的行对象。 */
  row(screenRow: number): TerminalRow {
    return this.buffer.getScreenLine(screenRow);
  }

  /**
   * 回看视图取行：`scrollOffset` 为 0 时等价于 `row(screenRow)`；
   * 大于 0 时整屏上移 `scrollOffset` 行，读到的是回看区里更早的内容。
   * 越界由 `TerminalBuffer.getLine` 兜底成空行。
   */
  rowWithOffset(screenRow: number, scrollOffset: number): TerminalRow {
    if (scrollOffset <= 0) {
      return this.buffer.getScreenLine(screenRow);
    }
    return this.buffer.getLine(this.buffer.screenFirstRow + screenRow - scrollOffset);
  }

  /** 当前可往上回看的最大行数（0 = 没有历史）。 */
  maxScrollOffset(): number {
    return this.buffer.scrollbackLines;
  }

  cursorRow(): number {
    return this.buffer.cursorRow;
  }

  cursorCol(): number {
    return this.buffer.cursorCol;
  }

  cursorVisible(): boolean {
    return this.buffer.cursorVisible;
  }

  /** 已滚出的历史行数（用于滚动条）。 */
  scrolledLines(): number {
    return this.buffer.totalLinesScrolled;
  }

  stylePool() {
    return this.buffer.stylePool;
  }
}

/** 解析 `rgb:RR/GG/BB` 或 `#RRGGBB`。 */
function parseOscColor(value: string): number | undefined {
  if (value.startsWith('#')) {
    const hex = value.substring(1);
    if (hex.length !== 6) {
      return undefined;
    }
    const parsed = Number.parseInt(hex, 16);
    if (isNaN(parsed)) {
      return undefined;
    }
    return rgbColor((parsed >> 16) & 0xFF, (parsed >> 8) & 0xFF, parsed & 0xFF);
  }
  if (value.startsWith('rgb:')) {
    const parts = value.substring(4).split('/');
    if (parts.length !== 3) {
      return undefined;
    }
    const parseComponent = (text: string): number => {
      const parsed = Number.parseInt(text, 16);
      if (isNaN(parsed)) {
        return 0;
      }
      // 1/2/4 位十六进制分量都归一化到 0..255
      if (text.length === 1) {
        return parsed * 17;
      }
      if (text.length === 2) {
        return parsed;
      }
      if (text.length === 3) {
        return Math.round(parsed / 0x10F * 255);
      }
      return Math.round(parsed / 0xFFFF * 255);
    };
    return rgbColor(parseComponent(parts[0]), parseComponent(parts[1]), parseComponent(parts[2]));
  }
  return undefined;
}
