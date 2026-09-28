/**
 * 终端按键映射（对应 termux `KeyHandler.java`）。
 *
 * 给出「按键 → 字节序列」的转换，供虚拟按键行与硬件键盘共用。
 * 方向键/Home/End 会按应用光标键模式（DECSET 1）切换 CSI / SS3 形式。
 */

import { TerminalEmulator } from './TerminalEmulator';

/** 控制键：Ctrl+A..Ctrl+Z 及常用符号。 */
export function ctrlSequence(key: string): string {
  const upper = key.toUpperCase();
  if (upper.length !== 1) {
    return '';
  }
  const code = upper.charCodeAt(0);
  if (code >= 0x40 && code <= 0x5F) {
    return String.fromCharCode(code - 0x40);
  }
  if (key === ' ') {
    return '\u0000';
  }
  if (key === '[') {
    return '\u001b';
  }
  if (key === '\\') {
    return '\u001c';
  }
  if (key === ']') {
    return '\u001d';
  }
  if (key === '^') {
    return '\u001e';
  }
  if (key === '_') {
    return '\u001f';
  }
  if (key === '?') {
    return '\u007f';
  }
  return '';
}

function altSequence(key: string): string {
  return `\u001b${key}`;
}

function arrowUp(emulator: TerminalEmulator, modifiers: number = 0): string {
  return withModifiers(emulator.cursorKey('A'), 'A', modifiers, true);
}

function arrowDown(emulator: TerminalEmulator, modifiers: number = 0): string {
  return withModifiers(emulator.cursorKey('B'), 'B', modifiers, true);
}

function arrowRight(emulator: TerminalEmulator, modifiers: number = 0): string {
  return withModifiers(emulator.cursorKey('C'), 'C', modifiers, true);
}

function arrowLeft(emulator: TerminalEmulator, modifiers: number = 0): string {
  return withModifiers(emulator.cursorKey('D'), 'D', modifiers, true);
}

export function homeKey(emulator: TerminalEmulator): string {
  return emulator.usesApplicationCursorKeys ? '\u001bOH' : '\u001b[H';
}

export function endKey(emulator: TerminalEmulator): string {
  return emulator.usesApplicationCursorKeys ? '\u001bOF' : '\u001b[F';
}

export function pageUpKey(): string {
  return '\u001b[5~';
}

function pageDownKey(): string {
  return '\u001b[6~';
}

export function deleteKey(): string {
  return '\u001b[3~';
}

export function backspaceKey(): string {
  return '\u007f';
}

export function enterKey(): string {
  return '\r';
}

export function shiftTabKey(): string {
  return '\u001b[Z';
}

/** F1..F12。 */
export function functionKey(index: number): string {
  switch (index) {
    case 1: return '\u001bOP';
    case 2: return '\u001bOQ';
    case 3: return '\u001bOR';
    case 4: return '\u001bOS';
    case 5: return '\u001b[15~';
    case 6: return '\u001b[17~';
    case 7: return '\u001b[18~';
    case 8: return '\u001b[19~';
    case 9: return '\u001b[20~';
    case 10: return '\u001b[21~';
    case 11: return '\u001b[23~';
    case 12: return '\u001b[24~';
    default: return '';
  }
}

/**
 * 带修饰键的 CSI 形式：`CSI 1 ; m A`，m = 1 + shift(1) + alt(2) + ctrl(4)。
 * 无修饰时返回基础序列。
 */
function withModifiers(base: string, finalByte: string, modifiers: number, csiForm: boolean): string {
  if (modifiers === 0) {
    return base;
  }
  const parameter = 1 + modifiers;
  return `\u001b[1;${parameter}${finalByte}`;
}

export const MODIFIER_SHIFT: number = 1;
export const MODIFIER_ALT: number = 2;
export const MODIFIER_CTRL: number = 4;

/** 额外按键行上的按键定义（label + 生成序列）。 */
export interface ExtraKey {
  label: string;
  /** 需要 Ctrl 组合时置 true。 */
  ctrl?: boolean;
  sequence?: string;
  /** 特殊行为标识（由 UI 处理，如打开键盘）。 */
  action?: string;
}

export const DEFAULT_EXTRA_KEYS: ExtraKey[] = [
  { label: 'ESC', sequence: '\u001b' },
  { label: 'TAB', sequence: '\t' },
  { label: 'CTRL', action: 'ctrl' },
  { label: 'ALT', action: 'alt' },
  { label: '←', action: 'left' },
  { label: '↑', action: 'up' },
  { label: '↓', action: 'down' },
  { label: '→', action: 'right' },
  { label: 'HOME', action: 'home' },
  { label: 'END', action: 'end' },
  { label: 'PGUP', action: 'pageup' },
  { label: 'PGDN', action: 'pagedown' },
  { label: '^C', sequence: '\u0003' },
  { label: '^D', sequence: '\u0004' },
  { label: '^Z', sequence: '\u001a' },
  { label: '|', sequence: '|' },
  { label: '-', sequence: '-' },
  { label: '/', sequence: '/' }
];

/**
 * 终端按键行：**两行 × 7 键**，顺序与上游 `TerminalShortcutDeck`
 * （`SessionAgentFilesScreen.kt:801` / `:817`）逐项一致。
 * 上游只有这 14 个键，没有 ^C/^D/^Z/|；Ctrl/Alt 是「武装一次」语义，
 * 与字母键组合由软键盘输入路径负责（`composeKeySequence`）。
 */
export const TERMINAL_KEY_ROWS: ExtraKey[][] = [
  [
    { label: 'ESC', sequence: '\u001b' },
    { label: '/', sequence: '/' },
    { label: '-', sequence: '-' },
    { label: 'HOME', action: 'home' },
    { label: '↑', action: 'up' },
    { label: 'END', action: 'end' },
    { label: 'PGUP', action: 'pageup' }
  ],
  [
    { label: 'TAB', sequence: '\t' },
    { label: 'CTRL', action: 'ctrl' },
    { label: 'ALT', action: 'alt' },
    { label: '←', action: 'left' },
    { label: '↓', action: 'down' },
    { label: '→', action: 'right' },
    { label: 'PGDN', action: 'pagedown' }
  ]
];

/** 额外按键行按键 → 序列（需要 emulator 状态的按键在这里解析）。 */
export function resolveExtraKey(
  key: ExtraKey, emulator: TerminalEmulator, ctrlArmed: boolean, altArmed: boolean
): string {
  if (key.action !== undefined) {
    switch (key.action) {
      case 'left': return arrowLeft(emulator);
      case 'up': return arrowUp(emulator);
      case 'down': return arrowDown(emulator);
      case 'right': return arrowRight(emulator);
      case 'home': return homeKey(emulator);
      case 'end': return endKey(emulator);
      case 'pageup': return pageUpKey();
      case 'pagedown': return pageDownKey();
      default: return '';
    }
  }
  let sequence = key.sequence !== undefined ? key.sequence : '';
  if (sequence.length === 0) {
    return '';
  }
  if (ctrlArmed) {
    sequence = ctrlSequence(sequence);
  }
  if (altArmed) {
    sequence = altSequence(sequence);
  }
  return sequence;
}
