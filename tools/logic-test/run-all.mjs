#!/usr/bin/env node
/**
 * aa-hm 逻辑自测**全量**入口（R12 集成轮新增）。
 *
 * 为什么需要它：本工程的逻辑层断言按包分散在多个文件里 ——
 *   · `run-tests.mjs`        主套件（协议归一化 / DTO / 时间线投影 / VT / Markdown / 语法高亮 …）
 *   · `suite-<包名>.mjs`     各开发包自带的专项套件（composer / design / device / dirbrowse / files /
 *                            home / icons / input / login / markdown / paging / reasoning / runtime /
 *                            settings / terminal）
 * 这些套件此前只能**逐个手敲**，于是「跑通全量」这句话没有单一可复现的判据 ——
 * R12 的独立验证者实测：`run-tests.mjs` 的 420 项**不含**新加的 suite-icons(65) / suite-reasoning(79)，
 * 若只看它就会漏判。本脚本把两者合并成一条命令，作为「零回归」的统一护栏。
 *
 * 用法：
 *   node tools\logic-test\run-all.mjs
 *   （Git Bash： "/d/DevEco Studio/tools/node/node.exe" tools/logic-test/run-all.mjs）
 *
 * 退出码：全部套件通过 = 0；只要有任一失败 = 1（可直接当 CI 判据）。
 * 产物：全部落在系统临时目录（各套件自己管理），本脚本不写工程目录。
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const NODE = process.execPath;

/** 主套件固定排在最前，其余按文件名排序，输出稳定可对账。 */
const MAIN = 'run-tests.mjs';

/**
 * ⚠️ R91-T2：**非 `suite-` 前缀的套件必须在这里显式登记**，否则不会被本脚本发现。
 *
 * 由来（与 T1 的 `suite-slash` 同源的「虚假安全感」）：本脚本的发现规则是
 * `f.startsWith('suite-')`，而 `ab-bench-t2.mjs`（T2 的 A/B 定向证据基准，60 条断言）
 * **不以 `suite-` 开头** ⇒ 它此前**从未进过零回归闸门**：任何一轮把 O1/O2/O3/O4/O5 改回退化实现，
 * `run-all` 照样全绿。这与「run-all 全绿但零覆盖新逻辑」是同一类问题。
 *
 * **为什么选「显式登记」而不是把它改名成 `suite-perf-ab.mjs`**：
 * 已冻结的 `entry/src/main/ets/model/HomeGrouping.ets:461` 的注释里**逐字引用**了
 * `tools/logic-test/ab-bench-t2.mjs` 这个文件名，而该文件属于本轮冻结面（md5 不得变）。
 * 改名会让冻结源码里留下**悬空引用**；显式登记既让断言进闸门，又不动任何冻结文件。
 * ⚠️ 将来新增非 `suite-` 前缀的套件时，也必须加到 `EXTRA_SUITES` —— 这是本规则的全部入口。
 */
const EXTRA_SUITES = ['ab-bench-t2.mjs'];

const suites = fs.readdirSync(HERE)
  .filter((f) => f.endsWith('.mjs') && f !== MAIN && f !== 'run-all.mjs')
  .filter((f) => f.startsWith('suite-') || EXTRA_SUITES.includes(f))
  .sort();
const files = [MAIN, ...suites];

// 启动前自检：显式登记的套件必须真实存在（防止登记了名字却没这个文件 ⇒ 静默漏跑）。
for (const extra of EXTRA_SUITES) {
  if (!fs.existsSync(path.join(HERE, extra))) {
    console.error(`❌ EXTRA_SUITES 登记的套件不存在：${extra}`);
    process.exit(1);
  }
}

console.log(`\n=== aa-hm 逻辑自测全量：${files.length} 个套件 ===\n`);

const results = [];
let failed = 0;
let skippedCount = 0;

for (const f of files) {
  const started = Date.now();
  let out = '';
  let ok = true;
  try {
    out = execFileSync(NODE, [path.join(HERE, f)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    ok = false;
    out = String((e && e.stdout) || '') + String((e && e.stderr) || '');
  }
  const ms = Date.now() - started;
  // 抓「通过 N 项」或「N 条断言全绿」这样的计数行，便于汇总对账
  const lines = out.split(/\r?\n/).filter((l) => l.trim().length > 0);
  const count = lines.filter((l) => /通过 \d+ 项|\d+ 条断言全绿|\d+ 通过 \/ \d+ 失败|跳过 \d+ 项/.test(l)).pop() || '';
  const tail = lines.slice(-1)[0] || '';
  /**
   * 套件自报的 SKIP：内部资产（`verify-*` 证据树等）不随开源仓库分发时，
   * 套件会打印 `⊘ SKIP：…` 并以退出码 0 结束。这里把它单独计一档，
   * **既不算 PASS 也不算 FAIL，但必须在汇总里显式列出**（静默跳过 = 虚假安全感）。
   */
  const skipLines = lines.filter((l) => l.indexOf('⊘ SKIP') >= 0);
  // 「整套件跳过」= 有 SKIP 行且一条断言都没跑（例如 ab-bench-t2 缺内部基准源码）；
  // 「部分跳过」= 真跑了断言、只有依赖内部资产的那几条被跳过（例如 suite-material）。
  const wholeSkipped = skipLines.length > 0 && !/通过 \d+ 项|\d+ 条断言全绿|\d+ 通过 \/ \d+ 失败/.test(out);
  results.push({ f, ok, wholeSkipped, skipLines, ms, count: count.trim(), tail: tail.trim() });
  skippedCount += skipLines.length;
  if (!ok) failed += 1;
  const tag = !ok ? 'FAIL' : (wholeSkipped ? 'SKIP' : 'PASS');
  console.log(`${tag}  ${f.padEnd(24)} ${String(ms).padStart(6)} ms  ${(count || tail).slice(0, 90)}`);
}

console.log('\n=== 汇总 ===');
for (const r of results) {
  if (!r.ok) console.log(`  ✗ ${r.f}：${r.tail.slice(0, 160)}`);
}
// SKIP 必须**显式列出**：静默跳过 = 虚假安全感（与「判据恒真」同一类问题）。
for (const r of results) {
  for (const line of r.skipLines) console.log(`  ${line.slice(0, 200)}   ← ${r.f}`);
}
console.log(`套件 ${results.length} 个，失败 ${failed} 个`
  + (skippedCount > 0 ? `，跳过 ${skippedCount} 处（内部资产缺失，非失败）` : ''));

if (failed > 0) {
  console.log('\n逻辑自测未全绿。');
  process.exit(1);
}
console.log('\n全部逻辑套件通过。');
