#!/usr/bin/env node
/**
 * aa-hm「终端按键行」契约自测。
 *
 * 上游规格：SessionAgentFilesScreen.kt:785 的 TerminalShortcutDeck ——
 *   两行 × 7 键，容器 height(88.dp) / padding(h14,v6) / spacedBy(3.dp)，
 *   键 height(34.dp) + weight(1f) + RoundedCornerShape(8.dp)，键底**透明**、
 *   仅 Ctrl/Alt 武装时上色；文字 14.sp。
 *   第 1 行 Esc / - Home ↑ End PGUP，第 2 行 Tab Ctrl Alt ← ↓ → PGDN。
 *
 * 为什么值得单列：鸿蒙端一度是「一行 18 键 + 横向滚动 + 每键灰底」，
 * 真机/模拟器截图里最后一个键被右边缘裁掉，观感与安卓完全不同，
 * 而当时 17 个套件没有任何一条能发现它。
 *
 * 用法（workdir = projects/aa-hm）：node tools/logic-test/suite-keydeck.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'ets');
const KEYHANDLER = path.join(SRC, 'vt', 'KeyHandler.ets');
const SCREEN = path.join(SRC, 'ui', 'screens', 'TerminalScreen.ets');

let pass = 0;
const fails = [];
function ok(cond, msg) { if (cond) { pass++; } else { fails.push(msg); } }

const kh = fs.readFileSync(KEYHANDLER, 'utf8');
const sc = fs.readFileSync(SCREEN, 'utf8');

// ---- 1. TERMINAL_KEY_ROWS 存在且为两行 ----
const decl = kh.indexOf('export const TERMINAL_KEY_ROWS');
ok(decl >= 0, 'KeyHandler.ets 缺少 TERMINAL_KEY_ROWS 导出');
const body = decl >= 0 ? kh.slice(decl, kh.indexOf('];', decl) + 1) : '';
// 去掉行注释，避免注释里的示例键被当成真实键（踩坑：源码断言必须先剥注释）
const code = body.split(String.fromCharCode(10)).map((l) => l.replace(/\/\/.*$/, '')).join(String.fromCharCode(10));
const labels = [];
const re = /label:\s*'([^']*)'/g;
let m;
while ((m = re.exec(code)) !== null) { labels.push(m[1]); }
ok(labels.length === 14, '按键总数应为 14，实际 ' + labels.length + '：' + labels.join(','));

// ---- 2. 顺序与上游逐项一致 ----
const ROW1 = ['ESC', '/', '-', 'HOME', '\u2191', 'END', 'PGUP'];
const ROW2 = ['TAB', 'CTRL', 'ALT', '\u2190', '\u2193', '\u2192', 'PGDN'];
const want = ROW1.concat(ROW2);
ok(JSON.stringify(labels) === JSON.stringify(want),
   '按键顺序与上游不符。\n  期望: ' + want.join(',') + '\n  实际: ' + labels.join(','));

// ---- 3. 渲染侧真的是两行（两个 Row，分别取 [0] / [1]）----
const extra = sc.indexOf('extraKeys() {');
const extraBody = extra >= 0 ? sc.slice(extra, sc.indexOf('private handleExtraKey', extra)) : '';
ok(extraBody.indexOf('TERMINAL_KEY_ROWS[0]') >= 0, 'extraKeys 未渲染第 1 行 TERMINAL_KEY_ROWS[0]');
ok(extraBody.indexOf('TERMINAL_KEY_ROWS[1]') >= 0, 'extraKeys 未渲染第 2 行 TERMINAL_KEY_ROWS[1]');
ok(extraBody.indexOf('ScrollDirection.Horizontal') < 0, '按键行不应再是横向 Scroll（上游是两行铺满）');

// ---- 4. 尺寸与上游对齐 ----
ok(/\.height\(88\)/.test(extraBody), '容器高度应为 88（上游 88.dp）');
ok(/\.height\(34\)/.test(extraBody), '键高应为 34（上游 34.dp）');
ok(extraBody.indexOf('left: 14, right: 14, top: 6, bottom: 6') >= 0, '容器内边距应为 h14/v6（上游 padding(horizontal=14.dp, vertical=6.dp)）');
ok(/\.layoutWeight\(1\)/.test(extraBody), '键应按 weight(1f) 等宽铺满');
ok(/\.borderRadius\(8\)/.test(extraBody), '键圆角应为 8（上游 RoundedCornerShape(8.dp)）');
ok(extraBody.indexOf('Color.Transparent') >= 0, '未武装的键底应为透明（上游 Color.Transparent）');

// ---- 5. 激活色来自主题资源，且深浅两套都定义了 ----
const base = fs.readFileSync(path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'), 'utf8');
const dark = fs.readFileSync(path.join(projectRoot({ up: 2, scriptUrl: import.meta.url }), 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'), 'utf8');
ok(extraBody.indexOf('app.color.terminal_key_active') >= 0, '激活文字色未走 terminal_key_active 资源');
ok(extraBody.indexOf('app.color.terminal_key_active_surface') >= 0, '激活底色未走 terminal_key_active_surface 资源');
ok(base.indexOf('terminal_key_active') >= 0 && dark.indexOf('terminal_key_active') >= 0, 'terminal_key_active 未同时定义浅色/深色两套');

if (fails.length > 0) {
  console.error('suite-keydeck: ' + fails.length + ' 条断言失败');
  for (const f of fails) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-keydeck: ' + pass + ' 条断言全绿。');