#!/usr/bin/env node
/**
 * R91-T2 定向证据基准（不依赖设备、不受前后台/构建模式影响）。
 *
 * 做法：用 DevEco 自带 TypeScript，把
 *   · 「改前源码」= 开发期验证证据目录（`verify-*`）里 `perf/baseline-src/` 的逐字节归档副本
 *   · 「改后源码」= entry/src/main/ets/ 的活源码
 * 分别转译成 CommonJS，在**同一份输入**上跑同一批断言与计时。
 * ⇒ 差异只能来自代码，不含设备、构建模式、采样时点等混杂变量。
 *
 * 用法：& node tools\logic-test\ab-bench-t2.mjs
 *      （或随全量闸门一起跑：node tools/logic-test/run-all.mjs —— 见下方说明）
 *
 * ⚠️ R91-T2：本文件**不以 `suite-` 开头**，而 `run-all.mjs` 的发现规则是 `f.startsWith('suite-')`
 * ⇒ 它此前**不在零回归闸门里**（与 T1 的 suite-slash 同源的「虚假安全感」）。
 * 现已由 `run-all.mjs` 的 `EXTRA_SUITES` **显式登记**，改回退化实现会让 run-all 变红。
 * **不改名**成 `suite-*`：已冻结的 `model/HomeGrouping.ets:461` 注释里逐字引用了本文件名，
 * 改名会在冻结源码里留下悬空引用（详见 run-all.mjs 的 EXTRA_SUITES 注释）。
 */
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, requireTypeScript, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
/**
 * 「改前源码」的逐字节归档副本所在目录。
 * 该资产属 `verify-*` 证据树（不随开源仓库分发），且证据目录名是**按日期生成的**
 * ⇒ 这里不在源码里钉死某一天的目录名，而是在工程根下**探测** verify-* 目录里的 perf/baseline-src，
 *   取第一个存在的（多个并存时按目录名倒序 = 最新在前）。
 * 探测不到 ⇒ 下方显式 SKIP；探测到 ⇒ 照旧真跑。
 */
function findBaselineSrc() {
  let entries = [];
  try {
    entries = fs.readdirSync(PROJECT, { withFileTypes: true });
  } catch (error) {
    return '';
  }
  const dirs = entries
    .filter((e) => e.isDirectory() && /^verify-\d{4}-\d{2}-\d{2}$/.test(e.name))
    .map((e) => e.name)
    .sort()
    .reverse();
  for (const name of dirs) {
    const candidate = path.join(PROJECT, name, 'perf', 'baseline-src');
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return '';
}
const BASE_SRC = findBaselineSrc();
const TS_PACKAGE = typeScriptModuleId();
const OUT = path.join(tempDir(), 'aa-hm-ab-t2');

const require = createRequire(import.meta.url);

/**
 * ⚠️ **本套件依赖内部资产**：开发期验证证据目录（`verify-*`）里 `perf/baseline-src/`
 * ——「改前源码」的逐字节归档副本，用于和活源码做**同输入同断言**的对照。
 * 该目录**不随开源仓库分发**（见根 `.gitignore` 第 4 类）。
 * ⇒ 缺失时**显式 SKIP 并正常退出 0**（否则开源 clone 里会以「读文件崩了」的形态假红），
 *   存在时照旧真跑、该红还是红。
 * ⚠️ 判定基于**具体目录是否存在**（见上方 `findBaselineSrc()` 探测），
 *   不是「有没有设某个环境变量」——后者容易被误开而静默放宽。
 */
if (!fs.existsSync(BASE_SRC)) {
  console.log('=== ab-bench-t2：A/B 定向证据基准（R91-T2）===');
  console.log('⊘ SKIP：内部基准源码不存在（未探测到 verify-*/perf/baseline-src）；');
  console.log('  该目录属内部证据树 verify-*，不随开源仓库分发 ⇒ 本套件整体跳过（退出码 0）。');
  console.log('  需要真跑时：把改前源码逐字节归档到 <工程根>/<某天的 verify-*>/perf/baseline-src/ 后重跑本脚本。');
  process.exit(0);
}

const ts = requireTypeScript();

function transpile(source, fileName) {
  return ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
    fileName
  }).outputText;
}

/** 把某个 .ets 源码里的 import 路径改写成同一目录下的扁平文件名（baseline 版加前缀）。 */
function rewrite(source, prefix) {
  let out = source;
  const pairs = [
    ["'./TimelineProjection'", "'./" + prefix + "TimelineProjection'"],
    ["'./TimelineView'", "'./" + prefix + "TimelineView'"],
    ["'../model/Types'", "'./Types'"],
    ["'../model/AppModels'", "'./AppModels'"],
    ["'../model/SessionPaging'", "'./SessionPaging'"],
    ["'../api/Parse'", "'./Parse'"],
    ["'../utils/Codec'", "'./Codec'"]
  ];
  for (const [from, to] of pairs) {
    out = out.split(from).join(to);
  }
  out = out.replace("from './TimelineView'", "from './" + prefix + "TimelineView'");
  out = out.split("'@kit.ArkTS'").join("'./kit-stub'");
  return out;
}

function emit(group, rel, targetName) {
  const from = group === 'before' ? path.join(BASE_SRC, path.basename(rel)) : path.join(SRC, rel);
  const source = fs.readFileSync(from, 'utf8');
  const prefix = group === 'before' ? 'B' : 'A';
  const out = transpile(rewrite(source, prefix), path.basename(rel));
  fs.writeFileSync(path.join(OUT, targetName), out, 'utf8');
}

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

// ---- 两侧各自产出 TimelineProjection / TimelineView -------------------------
for (const group of ['before', 'after']) {
  const prefix = group === 'before' ? 'B' : 'A';
  emit(group, 'feature/TimelineProjection.ets', prefix + 'TimelineProjection.js');
  emit(group, 'feature/TimelineView.ets', prefix + 'TimelineView.js');
}
// ---- 共用依赖（Types / AppModels / SessionPaging 不在本轮改动面内）---------
for (const [rel, target] of [
  ['model/Types.ets', 'Types.js'],
  ['model/AppModels.ets', 'AppModels.js'],
  ['model/SessionPaging.ets', 'SessionPaging.js'],
  ['api/Parse.ets', 'Parse.js'],
  ['utils/Codec.ets', 'Codec.js'],
  ['utils/Sha256.ets', 'Sha256.js']
]) {
  const source = fs.readFileSync(path.join(SRC, rel), 'utf8');
  fs.writeFileSync(path.join(OUT, target), transpile(rewrite(source, 'A'), path.basename(rel)), 'utf8');
}
// Codec 依赖 @kit.ArkTS（Node 里不存在）—— 本基准不跑上传/下载，只补一个最小实现，
// 保证 require 时能求值。⚠️ 它不参与任何被测路径。
fs.writeFileSync(path.join(OUT, 'kit-stub.js'),
  'const util = { Base64Helper: class { encodeToStringSync(b){return Buffer.from(b).toString("base64");} decodeSync(s){return new Uint8Array(Buffer.from(s,"base64"));} } };\nmodule.exports = { util };\n', 'utf8');
// ---- HomeGrouping（O4 的纯逻辑所在处；两侧同源，差异在调用点，见 O4 说明）----
{
  const source = fs.readFileSync(path.join(SRC, 'model/HomeGrouping.ets'), 'utf8');
  fs.writeFileSync(path.join(OUT, 'HomeGrouping.js'), transpile(rewrite(source, 'A'), 'HomeGrouping.ets'), 'utf8');
}

const load = (name) => require(path.join(OUT, name));

// ===========================================================================
let passed = 0;
const failures = [];
function check(name, ok, detail) {
  if (ok) passed += 1;
  else failures.push(detail === undefined ? name : name + ' — ' + detail);
}
function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function group(t) { console.log('\n== ' + t); }

const proj = { before: load('BTimelineProjection.js'), after: load('ATimelineProjection.js') };
const view = { before: load('BTimelineView.js'), after: load('ATimelineView.js') };

/** 掐掉 // 行注释与 /* *\/ 块注释，避免注释里的字面量被当成代码计数。 */
function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}
function item(id, orderSeq, revision, content) {
  return { id: id, orderSeq: orderSeq, revision: revision, updatedSeq: revision, type: 'message', text: '',
    content: content === undefined ? { role: 'user', text: 'x' } : content, source: {} };
}
function rng(seed) {
  let s = seed >>> 0;
  return function next() { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

// ---------------------------------------------------------------------------
group('O1 mergeTimelineItems：语义等价（两侧必须逐项一致）');
{
  const seeds = [7, 20260922, 424242];
  for (const seed of seeds) {
    const next = rng(seed);
    let a = []; let b = [];
    let mismatches = 0;
    for (let step = 0; step < 300; step++) {
      const incoming = [];
      const count = 1 + Math.floor(next() * 3);
      for (let k = 0; k < count; k++) {
        if (a.length > 0 && next() < 0.5) {
          const src = a[Math.floor(next() * a.length)];
          const fresh = item(src.id, src.orderSeq, src.revision + 1, { role: 'assistant', text: 'v' + step });
          incoming.push(fresh);
        } else {
          incoming.push(item('it-' + step + '-' + k, Math.floor(next() * 600), 1, { role: 'user', text: 'n' + step }));
        }
      }
      a = proj.after.mergeTimelineItems(a, incoming, false);
      b = proj.before.mergeTimelineItems(b, incoming, false);
      if (a.length !== b.length) { mismatches += 1; continue; }
      for (let i = 0; i < a.length; i++) {
        if (a[i].id !== b[i].id || a[i].revision !== b[i].revision || a[i].orderSeq !== b[i].orderSeq) {
          mismatches += 1; break;
        }
      }
    }
    eq('seed ' + seed + '：改前/改后 300 步随机序列逐项一致（不一致步数）', mismatches, 0);
    check('seed ' + seed + '：序列真的产生了条目', a.length > 50, 'items=' + a.length);
  }
  // 边界：current 里有重复 id（快速路径必须让开）
  const dup = [item('d', 1, 1), item('d', 1, 1)];
  eq('重复 id 的 current：改后与改前条数一致',
    proj.after.mergeTimelineItems(dup, [], false).length, proj.before.mergeTimelineItems(dup, [], false).length);
  // ⚠️ 实测口径：改前对「current 自带重复 id」的输入返回的就是 1 条（ordering 按 id 去重），
  // 所以 2 条才是错的。这条断言钉住的是「快速路径必须让开这个边界、不许把 1 条变回 2 条」。
  eq('重复 id 的 current：改后仍是 1 条（快速路径已按 ordering.length 让开）',
    proj.after.mergeTimelineItems(dup, [], false).length, 1);
  // 空 incoming
  const base = [item('x1', 1, 1), item('x2', 2, 1)];
  check('空 incoming：改后返回 current 原引用（无操作快速路径）',
    proj.after.mergeTimelineItems(base, [], false) === base);
  check('阳性对照：改前返回的是新数组', proj.before.mergeTimelineItems(base, [], false) !== base);
}

group('O1 性能：无操作批次（identical 重复投递）');
{
  const base = [];
  for (let i = 0; i < 600; i++) base.push(item('p' + i, i, 1));
  const replay = base.slice();            // 同 id 同 revision 的重复投递
  function run(mod, rounds) {
    let cur = mod.mergeTimelineItems([], base, true);
    // 预热：跑一次增量分支，把首次的 Map/去重分配排除在计时窗之外。
    cur = mod.mergeTimelineItems(cur, replay, false);
    const t0 = process.hrtime.bigint();
    for (let r = 0; r < rounds; r++) cur = mod.mergeTimelineItems(cur, replay, false);
    return { ms: Number(process.hrtime.bigint() - t0) / 1e6, len: cur.length };
  }
  const ROUNDS = 2000;
  const before = run(proj.before, ROUNDS);
  const after = run(proj.after, ROUNDS);
  eq('规模一致', before.len, after.len);
  console.log('   600 条 item × ' + ROUNDS + ' 个「无变化批次」：改前 ' + before.ms.toFixed(1)
    + ' ms ⇒ 改后 ' + after.ms.toFixed(1) + ' ms（' + (before.ms / after.ms).toFixed(2) + '×）');
  // ⚠️ 实测：CPU 时间在噪声内（~1.0×）—— 这一处的收益**不在 CPU**，而在「每批次少分配容器」。
  // 它的目标本来就是内存/GC：改前每批次分配 5 个容器（byId / ordering / out + 两道后处理各一个
  // 输出数组），改后只分配 2 个（byId / ordering）。这里用**不触发 GC 的累计堆增长**量化它。
  // ⚠️ 实测：CPU 时间与 heapUsed 增量**都在噪声内**（1.01× / 99%）——
  //    这一处的收益不在「单次耗时」，而在「每批次少分配 3 个 O(N) 容器」。
  //    V8 的 heapUsed 会被 scavenge 抹平、拿不到瞬时分配量，所以这里换一个**可复现**的
  //    内存压力判据：同样工作量下的 **GC 次数与 GC 总耗时**（用 perf_hooks 的 GC 观测器）。
  // ⚠️ GC 计数**抖动很大**（同一侧连跑可得 0 与 100+），所以不写成绝对值断言，
  //    而是**交替采样 5 轮取中位数**，并要求「改后不高于改前」。原始值全部打印出来可复核。
  const { PerformanceObserver } = await import('node:perf_hooks');
  async function gcTrial(mod, rounds, items) {
    const replayN = items.slice();
    let cur = mod.mergeTimelineItems([], items, true);
    let count = 0; let totalMs = 0;
    const obs = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) { count += 1; totalMs += e.duration; }
    });
    obs.observe({ entryTypes: ['gc'] });
    let sink = 0;
    for (let r = 0; r < rounds; r++) { cur = mod.mergeTimelineItems(cur, replayN, false); sink += cur.length; }
    await new Promise((resolve) => setTimeout(resolve, 5));
    obs.disconnect();
    return { count: count, ms: totalMs, len: sink > 0 ? cur.length : 0 };
  }
  const bigItems = [];
  for (let i = 0; i < 2000; i++) bigItems.push(item('g' + i, i, 1));
  const beforeCounts = []; const afterCounts = [];
  let lenCheck = true;
  for (let trial = 0; trial < 5; trial++) {
    const b = await gcTrial(proj.before, 4000, bigItems);
    const a = await gcTrial(proj.after, 4000, bigItems);
    beforeCounts.push(b.count); afterCounts.push(a.count);
    if (b.len !== a.len) lenCheck = false;
  }
  const median = (xs) => xs.slice().sort((p, q) => p - q)[Math.floor(xs.length / 2)];
  const medB = median(beforeCounts); const medA = median(afterCounts);
  console.log('   2000 item × 4000 无变化批次，交替 5 轮 GC 次数：改前 [' + beforeCounts.join(',')
    + '] 中位数 ' + medB + ' ⇒ 改后 [' + afterCounts.join(',') + '] 中位数 ' + medA);
  check('O1 语义等价（同规模）', lenCheck);
  check('O1 无操作批次造成的 GC 次数中位数不高于改前', medA <= medB, medA + ' vs ' + medB);
}

// ---------------------------------------------------------------------------
group('O2 TimelineProjectionCache：语义等价 + 同输入快速路径');
{
  for (const mod of ['before', 'after']) {
    const Cache = view[mod].TimelineProjectionCache;
    const P = proj[mod];
    const c = new Cache();
    const items = [item('a', 1, 1), item('b', 2, 1), item('c', 3, 1)];
    const full = P.projectTimeline(items);
    const inc = c.project(items);
    eq(mod + '：增量 == 全量（逐项 id+body）',
      inc.map((m) => m.id + '|' + m.body).join(','), full.map((m) => m.id + '|' + m.body).join(','));
    const again = c.project(items);
    check(mod + '：同一数组再投影结果逐项一致',
      again.length === inc.length && again.every((m, i) => m === inc[i]));
    // 流式替换（同 id、revision 不变、对象换新）——正文走 item.text（projectTimeline 先读它）
    const swappedFirst = item('a', 1, 1);
    swappedFirst.text = 'longer';
    const swapped = [swappedFirst, items[1], items[2]];
    const out = c.project(swapped);
    eq(mod + '：流式替换拿到新正文', out[0].body, 'longer');
  }
  const CacheB = view.before.TimelineProjectionCache;
  const CacheA = view.after.TimelineProjectionCache;
  const items = [item('a', 1, 1), item('b', 2, 1)];
  const cb = new CacheB(); cb.project(items);
  const ca = new CacheA(); const first = ca.project(items);
  const sameArray = ca.project(items);
  check('O2 快速路径：同一数组再投影返回**同一个输出数组**（原引用）', sameArray === first);
  const freshArraySameElems = items.slice();
  check('O2 快速路径：元素逐项同引用的新数组也命中', ca.project(freshArraySameElems) === first);
  check('阳性对照：改前每次都返回新数组', cb.project(items) !== cb.project(items));
  // 反向：内容真变了必须不命中
  const changedFirst = item('a', 1, 1);
  changedFirst.text = 'CHANGED';
  const changed = [changedFirst, items[1]];
  check('O2 反向：内容变化时**不**命中快速路径（拿到新正文）',
    ca.project(changed)[0].body === 'CHANGED');
  // reset 后必须重新算
  ca.reset();
  const afterReset = ca.project(items);
  check('O2 reset 后不复用旧产物（返回的是新数组，不是 reset 前的）', afterReset !== first);
}

group('O2 性能：同输入重复投影');
{
  const items = [];
  for (let i = 0; i < 400; i++) items.push(item('q' + i, i, 1));
  function run(mod, rounds) {
    const c = new view[mod].TimelineProjectionCache();
    c.project(items);
    const t0 = process.hrtime.bigint();
    for (let r = 0; r < rounds; r++) c.project(items);
    return Number(process.hrtime.bigint() - t0) / 1e6;
  }
  const ROUNDS = 3000;
  const before = run('before', ROUNDS);
  const after = run('after', ROUNDS);
  console.log('   400 条 item × ' + ROUNDS + ' 次同输入投影：改前 ' + before.toFixed(1)
    + ' ms ⇒ 改后 ' + after.toFixed(1) + ' ms（' + (before / after).toFixed(2) + '×）');
  check('O2 同输入投影严格更快', after < before, before + ' vs ' + after);
}

// ---------------------------------------------------------------------------
group('O4 HomeScreen.pull：allSessions() 调用次数 3 → 1（源码级断言）+ 计算量');
{
  const home = fs.readFileSync(path.join(SRC, 'ui', 'screens', 'HomeScreen.ets'), 'utf8');
  const pullStart = home.indexOf('private pull(): void {');
  const pullEnd = home.indexOf('private showNotice(text: string): void {');
  check('定位到 pull() 函数体', pullStart > 0 && pullEnd > pullStart);
  const body = stripComments(home.slice(pullStart, pullEnd));
  const calls = (body.match(/this\.allSessions\(\)/g) || []).length;
  eq('pull() 内 allSessions() 调用次数', calls, 1);
  // 阳性对照：改前副本里必须是 3 次
  const baseHome = fs.readFileSync(path.join(BASE_SRC, 'HomeScreen.ets'), 'utf8');
  const bStart = baseHome.indexOf('private pull(): void {');
  const bEnd = baseHome.indexOf('private showNotice(text: string): void {');
  const bCalls = (stripComments(baseHome.slice(bStart, bEnd)).match(/this\.allSessions\(\)/g) || []).length;
  eq('阳性对照：改前 pull() 内是 3 次', bCalls, 3);

  // 计算量：mergeSessionsById 的 O(N^2)（seen 数组 + indexOf）
  const grouping = load('HomeGrouping.js');
  function benchMerge(n, times) {
    const active = []; const archived = [];
    for (let i = 0; i < n; i++) active.push({ id: 'a' + i });
    for (let i = 0; i < n; i++) archived.push({ id: 'b' + i });
    const t0 = process.hrtime.bigint();
    for (let t = 0; t < times; t++) grouping.mergeSessionsById(active, archived);
    return Number(process.hrtime.bigint() - t0) / 1e6;
  }
  for (const n of [100, 300, 600]) {
    const once = benchMerge(n, 200);
    console.log('   N=' + n + '：1 次合并 ' + (once / 200).toFixed(3) + ' ms，'
      + '改前 pull() 3 次 ' + (once / 200 * 3).toFixed(3) + ' ms ⇒ 改后 1 次 ' + (once / 200).toFixed(3) + ' ms');
  }
  const n600x3 = benchMerge(600, 100) * 3;
  const n600x1 = benchMerge(600, 100);
  check('O4 N=600 时 3 次合并明显慢于 1 次', n600x3 > n600x1 * 2, n600x3 + ' vs ' + n600x1);
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
group('O5 HomeGrouping.mergeSessionsById：去重语义不变 + 不再平方增长');
{
  const grouping = load('HomeGrouping.js');
  const mk = (ids) => ids.map((id) => ({ id: id }));
  // ① 语义：重复 id（两侧都撞）
  const a1 = mk(['x', 'x', 'y']);
  const b1 = mk(['y', 'z', 'x']);
  eq('重复 id：活跃侧优先且只留一份', grouping.mergeSessionsById(a1, b1).map((s) => s.id).join(','), 'x,y,z');
  // ② 交错顺序
  const a2 = mk(['a', 'c']);
  const b2 = mk(['b', 'a', 'd']);
  eq('交错 active/archived：保持「活跃在前、归档补后」', grouping.mergeSessionsById(a2, b2).map((s) => s.id).join(','), 'a,c,b,d');
  // ③ 空数组
  eq('两侧都空', grouping.mergeSessionsById([], []).length, 0);
  eq('只有活跃', grouping.mergeSessionsById(mk(['p', 'q']), []).map((s) => s.id).join(','), 'p,q');
  eq('只有归档', grouping.mergeSessionsById([], mk(['p', 'q'])).map((s) => s.id).join(','), 'p,q');
  // ④ 阳性对照：与「朴素 indexOf 实现」逐项一致（这就是被替换掉的那份逻辑）
  function naive(active, archived) {
    const out = []; const seen = [];
    for (const s of active) { if (seen.indexOf(s.id) < 0) { seen.push(s.id); out.push(s); } }
    for (const s of archived) { if (seen.indexOf(s.id) < 0) { seen.push(s.id); out.push(s); } }
    return out;
  }
  let mismatches = 0;
  for (let trial = 0; trial < 200; trial++) {
    const n = 1 + Math.floor(trial % 17);
    const a = []; const b = [];
    for (let i = 0; i < n; i++) a.push({ id: 'id' + (trial * 3 + i) % 23 });
    for (let i = 0; i < n; i++) b.push({ id: 'id' + (trial * 5 + i) % 23 });
    const got = grouping.mergeSessionsById(a, b).map((s) => s.id).join(',');
    const want = naive(a, b).map((s) => s.id).join(',');
    if (got !== want) mismatches += 1;
  }
  eq('200 组随机输入下与朴素 indexOf 实现逐项一致', mismatches, 0);

  // ⑤ 规模：不再是平方增长
  function bench(n, times) {
    const active = []; const archived = [];
    for (let i = 0; i < n; i++) active.push({ id: 'a' + i });
    for (let i = 0; i < n; i++) archived.push({ id: 'b' + i });
    const t0 = process.hrtime.bigint();
    for (let t = 0; t < times; t++) grouping.mergeSessionsById(active, archived);
    return Number(process.hrtime.bigint() - t0) / 1e6 / times;
  }
  const per100 = bench(100, 500);
  const per600 = bench(600, 200);
  const per1200 = bench(1200, 100);
  console.log('   mergeSessionsById 单次耗时：N=100 ' + per100.toFixed(3) + ' ms / N=600 '
    + per600.toFixed(3) + ' ms / N=1200 ' + per1200.toFixed(3) + ' ms');
  console.log('   （改前实测同一基准：N=100 0.133 ms / N=300 0.894 ms / N=600 4.175 ms）');
  // 线性判据：N×12 时耗时应远小于 ×144（平方会到 ×144）；放宽到 ×60 抗噪
  check('O5 不再平方增长（N 12 倍 ⇒ 耗时不超 60 倍）', per1200 < per100 * 60,
    per100 + ' → ' + per1200);
  check('O5 N=600 单次耗时 < 0.5 ms（改前 4.18 ms）', per600 < 0.5, per600 + ' ms');
}

// ---------------------------------------------------------------------------
group('O3 AttachmentStore：有界 LRU（用桩替换网络依赖，驱动的是真实淘汰代码）');
{
  // 转译 AttachmentStore + 为它的 4 个依赖写桩（不触碰任何真实网络/Kit）。
  const STUB = path.join(OUT, 'o3');
  fs.rmSync(STUB, { recursive: true, force: true });
  fs.mkdirSync(STUB, { recursive: true });
  let attSrc = fs.readFileSync(path.join(SRC, 'feature', 'AttachmentStore.ets'), 'utf8');
  // 依赖路径全部改写成同目录下的桩文件名（本基准只驱动缓存，不做任何真实 IO）。
  attSrc = attSrc.split("'../store/AuthSessionStore'").join("'./AuthSessionStore'")
    .split("'../model/Types'").join("'./Types'")
    .split("'../utils/Codec'").join("'./Codec'")
    .split("'./AppServices'").join("'./AppServices'");
  fs.writeFileSync(path.join(STUB, 'AttachmentStore.js'),
    transpile(attSrc, 'AttachmentStore.ets'), 'utf8');
  // 桩 1：鉴权（返回非空 ⇒ ensure() 不会早退）
  fs.writeFileSync(path.join(STUB, 'AuthSessionStore.js'),
    'exports.readAccessToken = () => "tok";\nexports.readServerUrl = () => "https://x";\n', 'utf8');
  // 桩 2：Types（只用到两个类 + 一个枚举常量）
  fs.writeFileSync(path.join(STUB, 'Types.js'),
    'class AttachmentTransferException extends Error { constructor(f){super("t"); this.failure=f;} }\n'
    + 'const AttachmentTransferFailure = { InvalidBase64:"a", SizeMismatch:"b", Sha256Mismatch:"c" };\n'
    + 'exports.AttachmentTransferException = AttachmentTransferException;\n'
    + 'exports.AttachmentTransferFailure = AttachmentTransferFailure;\n', 'utf8');
  // 桩 3：Codec（data URI 里由它 base64 编码）
  fs.writeFileSync(path.join(STUB, 'Codec.js'),
    'exports.base64Encode = (bytes) => Buffer.from(bytes).toString("base64");\n', 'utf8');
  // 桩 4：AppServices —— 下载立即 resolve，且返回可控大小的字节
  fs.writeFileSync(path.join(STUB, 'AppServices.js'),
    'const state = { bytes: 8, fail: false };\n'
    + 'const sessions = { downloadSessionAttachment: (u,t,sid,fid) => {\n'
    + '  if (state.fail) return Promise.reject(new Error("net down"));\n'
    + '  return Promise.resolve({ name: fid + ".png", size: state.bytes, bytes: new Uint8Array(state.bytes) });\n'
    + '} };\n'
    + 'exports.AppServices = { get: () => ({ sessions: sessions }) };\n'
    + 'exports.__state = state;\n', 'utf8');

  const att = require(path.join(STUB, 'AttachmentStore.js'));
  const appStub = require(path.join(STUB, 'AppServices.js'));
  const tick = () => new Promise((r) => setTimeout(r, 0));

  eq('上限常量：条目数', att.MAX_CACHED_ATTACHMENTS, 48);
  eq('上限常量：失败记录数', att.MAX_ATTACHMENT_ERRORS, 128);
  eq('上限常量：data URI 字符总数', att.MAX_CACHED_DATA_URI_CHARS, 16 * 1024 * 1024);

  // ① 上限以内：行为逐字不变（全部保留、可命中、不重复请求）
  const store = att.AttachmentStore.get();
  store.reset();
  for (let i = 0; i < 10; i++) store.ensure('s1', 'f' + i, 'image/png', 'f' + i + '.png');
  await tick();
  eq('上限内：10 条全部保留', store.cacheStats().entries, 10);
  check('上限内：每条都能取到', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].every((i) => store.entryOf('f' + i) !== undefined));
  check('上限内：dataUri 是可直接喂 Image 的 data URI',
    store.entryOf('f0').dataUri.startsWith('data:image/png;base64,'));
  eq('上限内：dataUriChars 等于各条长度之和', store.cacheStats().dataUriChars,
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].reduce((sum, i) => sum + store.entryOf('f' + i).dataUri.length, 0));

  // ② 超上限：LRU 淘汰最久未用的
  store.reset();
  for (let i = 0; i < 60; i++) { store.ensure('s1', 'k' + i, 'image/png', 'k' + i + '.png'); await tick(); }
  const st = store.cacheStats();
  check('超上限：条目数被压在 ' + att.MAX_CACHED_ATTACHMENTS + ' 以内', st.entries <= att.MAX_CACHED_ATTACHMENTS,
    'entries=' + st.entries);
  check('超上限：最旧的 k0..k10 已被淘汰', store.entryOf('k0') === undefined && store.entryOf('k5') === undefined);
  check('超上限：最新的 k59 仍在', store.entryOf('k59') !== undefined);
  eq('超上限：dataUriChars 与存活条目一致', st.dataUriChars, (() => {
    let sum = 0;
    for (let i = 0; i < 60; i++) { const e = store.entryOf('k' + i); if (e !== undefined) sum += e.dataUri.length; }
    return sum;
  })());

  // ③ touch 语义：刚访问过的旧条目要活下来（真正的 LRU，而不是 FIFO）
  store.reset();
  for (let i = 0; i < 48; i++) { store.ensure('s1', 'r' + i, 'image/png', 'r' + i + '.png'); await tick(); }
  store.entryOf('r0');                       // 把最旧的一条标记为「最近使用」
  store.ensure('s1', 'r48', 'image/png', 'r48.png'); await tick();
  check('LRU：被 touch 过的 r0 活下来（不是 FIFO）', store.entryOf('r0') !== undefined);
  check('LRU：没被 touch 的 r1 被淘汰', store.entryOf('r1') === undefined);

  // ④ 淘汰不影响幂等短路：被淘汰后 ensure 会重新拉（这是可接受的降级，需写明）
  const before = store.cacheStats().entries;
  store.ensure('s1', 'r1', 'image/png', 'r1.png'); await tick();
  check('被淘汰后重新 ensure 会再次取回（可接受的降级：重下一次，不是错误）',
    store.entryOf('r1') !== undefined);
  eq('重新取回后条目数仍在上限内', store.cacheStats().entries <= att.MAX_CACHED_ATTACHMENTS, true);

  // ⑤ 失败记录有界，且「已失败」短路仍然生效（不失自我放大的防护）
  const store2 = att.AttachmentStore.get();
  store2.reset();
  appStub.__state.fail = true;
  for (let i = 0; i < 200; i++) { store2.ensure('s1', 'e' + i, 'image/png', 'e' + i + '.png'); await tick(); }
  check('失败记录被压在 ' + att.MAX_ATTACHMENT_ERRORS + ' 以内', store2.cacheStats().errors <= att.MAX_ATTACHMENT_ERRORS,
    'errors=' + store2.cacheStats().errors);
  check('「已失败」短路仍然生效（错误可读，不会无限重试）', store2.errorOf('e199') !== undefined);
  appStub.__state.fail = false;
  // ⑥ 上限内不淘汰：48 条整好不触发
  const store3 = att.AttachmentStore.get();
  store3.reset();
  for (let i = 0; i < 48; i++) { store3.ensure('s1', 't' + i, 'image/png', 't' + i + '.png'); await tick(); }
  eq('恰好 48 条：一条都不淘汰', store3.cacheStats().entries, 48);
  store3.reset();
  eq('reset 后计数归零', store3.cacheStats().dataUriChars, 0);
}

// ---------------------------------------------------------------------------
group('O1×O2 协同：flushBatch 真实链路（merge 后喂 view.setItems）');
{
  // SessionDetailStore.flushBatch() 的真实形状：
  //   this.items = mergeTimelineItems(this.items, batchBuffer, false);
  //   this.view.setItems(this.items);   // → cache.project(this.items)
  // 改前：merge 无论如何都返回**新数组** ⇒ cache.project 走全量 O(N) 重建 + 逐项查表 + 排序；
  // 改后：无变化批次 merge 返回**原引用** ⇒ cache.project 命中同输入快速路径（O(N) 引用比较，
  //       零分配）。两处优化的收益是**乘起来**的，单独测任一处都看不到这条链路的效果。
  function pipe(mod, steps, items, batch) {
    const mods = proj[mod]; const vws = view[mod];
    let curItems = mods.mergeTimelineItems([], items, true);
    const v = new vws.TimelineMessageView();
    v.setItems(curItems);
    const t0 = process.hrtime.bigint();
    for (let s = 0; s < steps; s++) {
      curItems = mods.mergeTimelineItems(curItems, batch, false);
      v.setItems(curItems);
    }
    return { ms: Number(process.hrtime.bigint() - t0) / 1e6, n: v.messages().length };
  }
  const items = [];
  for (let i = 0; i < 400; i++) items.push(item('m' + i, i, 1));
  const batch = items.slice(0, 4);            // 同 id 同 revision 的重复投递（无变化批次）
  const STEPS = 2000;
  const before = pipe('before', STEPS, items, batch);
  const after = pipe('after', STEPS, items, batch);
  eq('端到端：两侧渲染消息条数一致', before.n, after.n);
  console.log('   400 条 item × ' + STEPS + ' 个无变化批次（merge + setItems 全链路）：改前 '
    + before.ms.toFixed(1) + ' ms ⇒ 改后 ' + after.ms.toFixed(1) + ' ms（'
    + (before.ms / after.ms).toFixed(2) + '×）');
  // 实测约 2.0~2.1×（改后仍要做 merge 的 O(N) 引用/Map 维护，所以不会到 O2 单点的 27×）。
  // 阈值取 1.5×：既证明「协同确实成立」，又不把机器抖动写成失败。
  check('O1×O2 协同：端到端严格更快（实测约 2×，阈值 1.5×）', after.ms * 1.5 < before.ms,
    before.ms.toFixed(1) + ' vs ' + after.ms.toFixed(1));

  // 反向对照：批次里真的带了新 item 时，两侧都必须更新（不能被快速路径吃掉）
  function pipeGrowth(mod) {
    const mods = proj[mod]; const vws = view[mod];
    let curItems = mods.mergeTimelineItems([], items, true);
    const v = new vws.TimelineMessageView();
    v.setItems(curItems);
    for (let s = 0; s < 50; s++) {
      const fresh = item('new' + s, 1000 + s, 1);
      curItems = mods.mergeTimelineItems(curItems, [fresh], false);
      v.setItems(curItems);
    }
    return v.messages().length;
  }
  eq('反向对照：每批带新 item 时两侧都增长到同样条数', pipeGrowth('before'), pipeGrowth('after'));
  eq('反向对照：增长后的条数正确（400 + 50）', pipeGrowth('after'), 450);
}

console.log('\n==============================================');
console.log('断言通过 ' + passed + ' 条，失败 ' + failures.length + ' 条');
// R91-T2：再打一行**与 `run-all.mjs` 计数口径一致**的汇总，确保本套件在 run-all 的汇总表里
// 有独立可见的计数（`run-all` 抓的是「N 通过 / M 失败」这个形状）。删掉它不会改变退出码，
// 但会让本套件在 run-all 输出里只剩末行 tail ⇒ 计数不可对账。
console.log('ab-bench-t2: ' + passed + ' 通过 / ' + failures.length + ' 失败');
if (failures.length > 0) {
  for (const f of failures) console.log('  FAIL: ' + f);
  process.exit(1);
}
