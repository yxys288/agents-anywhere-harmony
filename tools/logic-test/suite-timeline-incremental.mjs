#!/usr/bin/env node
/**
 * aa-hm 时间线**增量投影**等价性与开销自测（R42 性能轮新增）。
 *
 * 背景：`SessionDetailStore` 原先有 4 处 `this.messages = projectTimeline(this.items)` ——
 * 流式期间每收到一批增量就把整个时间线重新投影一遍（一轮回复 M 次更新 × N 条历史）。
 * R42 把它换成 `feature/TimelineView.ets` 的增量视图（`TimelineProjectionCache` + `TimelineMessageView`）。
 *
 * 本套件要证明改完**仍然等价**，并且开销确实降下来了：
 *   ① 随机事件序列下，增量投影结果与 `projectTimeline(items)` 逐项全等；
 *   ② 视图结果 == 全量投影 + 未回执的乐观消息（条数 / 顺序 / 字段全等）；
 *   ③ 乐观消息的增删、以及「服务端回执后消失」的行为正确（含一条阳性对照，证明断言不是恒真）；
 *   ④ 真正执行投影的 item 次数从「条目数 × 轮数」降到「条目数 + 变更数」，并附耗时对比。
 *
 * 转译方式照抄 tools/logic-test/run-tests.mjs（DevEco 自带 TypeScript → CommonJS → Node 断言）。
 * 产物落在系统临时目录（不污染工程目录）。
 *
 * 用法：
 *   node tools/logic-test/suite-timeline-incremental.mjs
 */

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, requireTypeScript, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-timeline-incremental');

/** 只挑不 import @kit / ArkUI 的模块。 */
const LOGIC_FILES = [
  'api/Parse.ets',
  'model/Types.ets',
  'feature/TimelineProjection.ets',
  'feature/TimelineView.ets'
];

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
        removeComments: false
      },
      fileName: rel
    });
    const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, output.outputText, 'utf8');
  }
}

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
  } else {
    failures.push(detail === undefined ? name : name + ' — ' + detail);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

function group(title) {
  console.log('');
  console.log('== ' + title);
}

build();

const require = createRequire(import.meta.url);
const load = (rel) => require(path.join(OUT_DIR, rel));

const projection = load('feature/TimelineProjection.js');
const timelineView = load('feature/TimelineView.js');

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

/** 造一条字段齐全的 RemoteTimelineItem。 */
function item(id, orderSeq, type, extra) {
  const base = {
    id: id, sessionId: 's1', type: type, status: 'done', text: '',
    content: {}, source: {}, orderSeq: orderSeq,
    revision: 1, updatedSeq: orderSeq, createdAt: '2026-09-22T00:00:00Z'
  };
  return Object.assign(base, extra || {});
}

/**
 * 13 种 item 形态，覆盖 `projectTimeline` 的每一条分支，
 * 含两类边界：assistant 空消息（产出 0 条）与 user 空消息（产出 1 条诊断行）。
 */
const SHAPES = [
  (id, seq, round) => item(id, seq, 'message', { role: 'user', text: '用户第 ' + round + ' 条' }),
  // assistant 正文按真实流式回复的量级给（几百字符）——投影里的 `stripInjectedMentions` 是全量正则扫描,
  // 正文太短会让「单次投影成本」失真，性能判据就没有意义了。
  (id, seq, round) => item(id, seq, 'message', { role: 'assistant', text: '助手回复 ' + round + '：' + '内容片段。'.repeat(60) }),
  (id, seq, round) => item(id, seq, 'message', { role: 'assistant', text: '' }),
  (id, seq, round) => item(id, seq, 'message', { role: 'user', text: '' }),
  (id, seq, round) => item(id, seq, 'tool', { content: { kind: 'command', command: 'npm test ' + round, exitCode: 0, output: 'ok' } }),
  (id, seq, round) => item(id, seq, 'tool', { content: { kind: 'file_change', changes: [{ path: 'src/a' + round + '.ts', kind: 'update', added: 3, removed: 1 }] } }),
  (id, seq, round) => item(id, seq, 'tool', { content: { kind: 'web_search', query: 'q' + round } }),
  (id, seq, round) => item(id, seq, 'tool', { content: { kind: 'mcp', server: 'srv', tool: 'tool' + round } }),
  (id, seq, round) => item(id, seq, 'tool', { content: { kind: 'agent_call', agent: 'sub' + round } }),
  (id, seq, round) => item(id, seq, 'artifact', { content: { title: '产物 ' + round, text: 'body', mediaType: 'text/plain' } }),
  (id, seq, round) => item(id, seq, 'marker', { text: '标记 ' + round, content: { title: 'M' + round } }),
  (id, seq, round) => item(id, seq, 'system', { content: { kind: 'reasoning', summaries: [{ text: '摘要 ' + round }, { text: '   ' }], rawText: '原文 ' + round } }),
  (id, seq, round) => item(id, seq, 'system', { text: '系统提示 ' + round }),
  (id, seq, round) => item(id, seq, 'mystery', { text: 'x' + round })
];

/** 固定种子的伪随机（可复跑：同种子必然同序列）。 */
function rng(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// ---------------------------------------------------------------------------
// ① 随机事件序列：增量投影必须与全量投影逐项全等
// ---------------------------------------------------------------------------

group('随机事件序列：增量投影 vs 全量投影');

function randomSequence(seed, steps) {
  const next = rng(seed);
  const cache = new timelineView.TimelineProjectionCache();
  let items = [];
  let mismatches = 0;
  let firstMismatch = '';
  for (let step = 0; step < steps; step++) {
    const incoming = [];
    const count = 1 + Math.floor(next() * 2);
    for (let k = 0; k < count; k++) {
      const reuse = items.length > 0 && next() < 0.55;
      if (reuse) {
        // 同 id 的新版本 —— 流式增量最常见的形态（正文变长、revision/updatedSeq 递增）
        const existing = items[Math.floor(next() * items.length)];
        const fresh = SHAPES[Math.floor(next() * SHAPES.length)](existing.id, existing.orderSeq, step);
        fresh.revision = existing.revision + 1;
        fresh.updatedSeq = existing.updatedSeq + 1;
        incoming.push(fresh);
      } else {
        // 新条目，orderSeq 随机 —— 覆盖「历史分页前置」「同序按 id 排」两种乱序
        const seq = Math.floor(next() * (steps * 2));
        incoming.push(SHAPES[Math.floor(next() * SHAPES.length)]('it-' + step + '-' + k, seq, step));
      }
    }
    items = projection.mergeTimelineItems(items, incoming, false);
    const fast = cache.project(items);
    const slow = projection.projectTimeline(items);
    if (!same(fast, slow)) {
      mismatches += 1;
      if (firstMismatch === '') {
        firstMismatch = 'step ' + step;
      }
    }
  }
  return { mismatches: mismatches, items: items, cache: cache, firstMismatch: firstMismatch };
}

const SEEDS = [7, 20260922, 424242];
const STEPS = 400;
for (const seed of SEEDS) {
  const run = randomSequence(seed, STEPS);
  eq('seed ' + seed + '：' + STEPS + ' 步随机序列下增量 == 全量（不一致步数）',
    run.mismatches, 0);
  check('seed ' + seed + '：序列真的产生了条目', run.items.length > 100, 'items=' + run.items.length);
  check('seed ' + seed + '：增量确实复用了缓存', run.cache.reusedItems > 0);
}

const longRun = randomSequence(20260922, STEPS);
const fullCost = longRun.items.length * STEPS;
check('增量投影次数远小于全量路径', longRun.cache.projectedItems <= longRun.items.length + STEPS,
  'projected=' + longRun.cache.projectedItems + '，上限=' + (longRun.items.length + STEPS));
console.log('   随机序列（seed 20260922，' + STEPS + ' 步）：条目 ' + longRun.items.length
  + '，实际投影 ' + longRun.cache.projectedItems + ' 次；全量路径同序列约 ' + fullCost + ' 次');

// ---------------------------------------------------------------------------
// ② 单项边界
// ---------------------------------------------------------------------------

group('单项边界');

const emptyCache = new timelineView.TimelineProjectionCache();
eq('空 items 投影为空', emptyCache.project([]).length, 0);
check('空 items 与全量一致', same(emptyCache.project([]), projection.projectTimeline([])));

const zeroCache = new timelineView.TimelineProjectionCache();
const zeroItems = [item('z0', 1, 'message', { role: 'assistant', text: '' })];
eq('产出为空的 item 不产生消息', zeroCache.project(zeroItems).length, 0);
check('产出为空时仍与全量一致', same(zeroCache.project(zeroItems), projection.projectTimeline(zeroItems)));
eq('产出为空也要计入投影次数（不能被误当成复用）', zeroCache.projectedItems, 1);

const dupCache = new timelineView.TimelineProjectionCache();
const dupItems = [
  item('dup', 1, 'message', { role: 'user', text: 'a' }),
  item('dup', 1, 'message', { role: 'user', text: 'b' })
];
check('items 里有重复 id 时（未去重的防御场景）仍与全量一致',
  same(dupCache.project(dupItems), projection.projectTimeline(dupItems)));
eq('重复 id 两条都产出', dupCache.project(dupItems).length, 2);

const orderCache = new timelineView.TimelineProjectionCache();
const orderItems = [
  item('z', 5, 'message', { role: 'user', text: '5' }),
  item('a', 5, 'message', { role: 'user', text: '5b' }),
  item('m', 1, 'message', { role: 'user', text: '1' })
];
eq('orderSeq 升序 + 同序按 id 升序',
  projection.projectTimeline(orderItems).map((m) => m.id).join(','), 'm#0,a#0,z#0');
eq('增量投影在乱序输入下同序', orderCache.project(orderItems).map((m) => m.id).join(','), 'm#0,a#0,z#0');

const hitCache = new timelineView.TimelineProjectionCache();
const hitA = [item('a', 1, 'message', { role: 'user', text: 'x' })];
hitCache.project(hitA);
eq('首次全部投影', hitCache.projectedItems, 1);
eq('首次无复用', hitCache.reusedItems, 0);
hitCache.project(hitA);
eq('同一数组再投影：不新增投影', hitCache.projectedItems, 1);
eq('复用 1 条', hitCache.reusedItems, 1);
eq('复用时不报告 changed', hitCache.changedItems.length, 0);
const hitB = hitA.concat([item('b', 2, 'message', { role: 'assistant', text: 'y' })]);
hitCache.project(hitB);
eq('追加一条只投影 1 条', hitCache.projectedItems, 2);
eq('复用了原有的 1 条', hitCache.reusedItems, 1);
eq('changed 只含新增条目', hitCache.changedItems.length, 1);
eq('changed 里的就是新条目', hitCache.changedItems[0].id, 'b');
eq('reset 后计数归零', (hitCache.reset(), hitCache.projectedItems), 0);
eq('reset 后复用计数归零', hitCache.reusedItems, 0);

const refCache = new timelineView.TimelineProjectionCache();
const refItems = [item('r1', 1, 'message', { role: 'user', text: 'a' })];
const refFirst = refCache.project(refItems);
const refSecond = refCache.project(refItems);
check('命中缓存时复用同一个 message 对象（不再重复分配）', refFirst[0] === refSecond[0]);
const fullFirst = projection.projectTimeline(refItems);
const fullSecond = projection.projectTimeline(refItems);
check('阳性对照：全量投影每次都新建对象（这就是被省掉的那批分配）', fullFirst[0] !== fullSecond[0]);

// ---------------------------------------------------------------------------
// ③ 视图：全量投影 + 乐观消息
// ---------------------------------------------------------------------------

group('乐观消息构造（与旧 appendOptimistic 逐字段一致）');

const built = timelineView.buildOptimisticMessage('cm-1', '在途消息', ['f1', 'f2'], '2026-09-22T10:00:00Z');
eq('渲染 id', built.id, 'optimistic:cm-1#0');
eq('sourceItemId', built.sourceItemId, 'optimistic:cm-1');
eq('orderSeq 排到最后', built.orderSeq, Number.MAX_SAFE_INTEGER);
eq('author', built.author, 'user');
eq('kind', built.kind, 'message');
eq('status', built.status, 'sending');
eq('body', built.body, '在途消息');
eq('createdAt 由调用方给定', built.createdAt, '2026-09-22T10:00:00Z');
eq('附件数量', built.attachments.length, 2);
eq('附件 fileId', built.attachments[0].fileId, 'f1');
eq('附件 name 回落 fileId', built.attachments[0].name, 'f1');
eq('附件 mediaType 空', built.attachments[0].mediaType, '');
eq('附件 size 0', built.attachments[0].size, 0);
eq('推理段为空', built.reasoningSegments.length, 0);
eq('默认不折叠', built.collapsedByDefault, false);
eq('messageId 常量与构造一致', timelineView.optimisticMessageId('cm-1'), built.id);

group('视图不变量：messages == 全量投影 + 未回执乐观消息');

const v = new timelineView.TimelineMessageView();
let items5 = [
  item('u1', 1, 'message', { role: 'user', text: '历史提问' }),
  item('a1', 2, 'message', { role: 'assistant', text: '历史回答' })
];
v.setItems(items5);
check('无乐观消息时视图 == 全量投影', same(v.messages(), projection.projectTimeline(items5)));
eq('乐观条数 0', v.optimisticCount(), 0);

const pendingA = timelineView.buildOptimisticMessage('cm-a', '刚发出的消息', [], 't');
v.addOptimistic(pendingA);
check('追加乐观消息后视图 == 全量投影 + 乐观消息',
  same(v.messages(), projection.projectTimeline(items5).concat([pendingA])));
eq('乐观条数 1', v.optimisticCount(), 1);
eq('乐观消息在最后一行', v.messages()[v.messages().length - 1].id, pendingA.id);

const pendingB = timelineView.buildOptimisticMessage('cm-b', '第二条', [], 't');
v.addOptimistic(pendingB);
eq('两条乐观消息按加入顺序排在末尾',
  v.messages().slice(-2).map((m) => m.id).join(','), pendingA.id + ',' + pendingB.id);

// 服务端推来的是**别的** item（不含 clientMessageId）：在途的乐观消息必须还在
items5 = projection.mergeTimelineItems(items5, [
  item('t9', 9, 'tool', { content: { kind: 'command', command: 'ls' } })
], false);
v.setItems(items5);
eq('无关 item 到达后乐观条数不变', v.optimisticCount(), 2);
check('无关 item 到达后在途消息仍在视图里',
  v.messages().some((m) => m.id === pendingA.id) && v.messages().some((m) => m.id === pendingB.id));
check('此时视图仍 == 全量投影 + 乐观消息',
  same(v.messages(), projection.projectTimeline(items5).concat([pendingA, pendingB])));
// 阳性对照：旧写法（每次刷新直接 messages = projectTimeline(items)）在这条序列下会丢掉在途消息
const legacyOverwrite = projection.projectTimeline(items5);
check('阳性对照：旧写法（全量投影直接覆盖）确实会丢掉在途消息',
  legacyOverwrite.every((m) => m.id !== pendingA.id && m.id !== pendingB.id));

// 服务端回执到达：含 clientMessageId 的 item 进时间线 ⇒ 乐观消息换成服务端行
items5 = projection.mergeTimelineItems(items5, [
  item('echo-a', 10, 'message', { role: 'user', text: '刚发出的消息', content: { clientMessageId: 'cm-a' } })
], false);
v.setItems(items5);
eq('回执后乐观条数减 1', v.optimisticCount(), 1);
check('回执后只剩未回执的那条', v.messages().some((m) => m.id === pendingB.id) && v.messages().every((m) => m.id !== pendingA.id));
check('回执后视图 == 全量投影 + 剩余乐观消息',
  same(v.messages(), projection.projectTimeline(items5).concat([pendingB])));

// 发送失败（撤回）
v.removeOptimistic('cm-b');
eq('撤回后乐观条数 0', v.optimisticCount(), 0);
check('撤回后视图 == 全量投影', same(v.messages(), projection.projectTimeline(items5)));

// 换会话 / 重新拉全量快照
v.addOptimistic(timelineView.buildOptimisticMessage('cm-c', 'x', [], 't'));
v.reset();
eq('reset 后视图为空', v.messages().length, 0);
eq('reset 后乐观条数 0', v.optimisticCount(), 0);
v.setItems(items5);
check('reset 后重新投影仍 == 全量投影', same(v.messages(), projection.projectTimeline(items5)));
eq('reset 清掉回执索引：旧 clientMessageId 不再吞掉新乐观消息',
  (v.addOptimistic(timelineView.buildOptimisticMessage('cm-a', '重发', [], 't')), v.optimisticCount()), 1);

// ---------------------------------------------------------------------------
// ④ 开销：投影次数与耗时
// ---------------------------------------------------------------------------

group('开销：300 条历史 + 200 轮增量');

const HISTORY = [];
for (let i = 0; i < 300; i++) {
  HISTORY.push(SHAPES[i % SHAPES.length]('h-' + i, i, i));
}
const ROUNDS = [];
const roundRng = rng(2026);
for (let i = 0; i < 200; i++) {
  const fresh = SHAPES[Math.floor(roundRng() * SHAPES.length)]('r-' + i, 300 + i, i);
  fresh.content = Object.assign({}, fresh.content, { clientMessageId: 'auto-' + i });
  ROUNDS.push([fresh]);
}

/** 每轮 merge 之后的 items 快照（两条路径共用同一批快照，耗时只反映投影差异）。 */
function snapshots() {
  const out = [];
  let items = HISTORY;
  for (let i = 0; i < ROUNDS.length; i++) {
    items = projection.mergeTimelineItems(items, ROUNDS[i], false);
    out.push(items);
  }
  return out;
}
const SNAPS = snapshots();
const TOTAL_ITEMS = HISTORY.length + ROUNDS.length;

const cache4 = new timelineView.TimelineProjectionCache();
const t0 = Date.now();
cache4.project(HISTORY);
for (let i = 0; i < SNAPS.length; i++) {
  cache4.project(SNAPS[i]);
}
const incrementalMs = Date.now() - t0;
eq('增量：首屏 300 次 + 200 轮各 1 次 = 500 次投影', cache4.projectedItems, TOTAL_ITEMS);

const t1 = Date.now();
for (let i = 0; i < SNAPS.length; i++) {
  projection.projectTimeline(SNAPS[i]);
}
const fullMs = Date.now() - t1;
let fullProjectionCount = HISTORY.length;
for (let i = 0; i < SNAPS.length; i++) {
  fullProjectionCount += SNAPS[i].length;
}

console.log('   增量：投影 ' + cache4.projectedItems + ' 次，耗时 ' + incrementalMs + ' ms');
console.log('   全量：投影 ' + fullProjectionCount + ' 次，耗时 ' + fullMs + ' ms');
console.log('   投影次数下降 ' + (fullProjectionCount / cache4.projectedItems).toFixed(1) + ' 倍');
eq('末次视图与全量投影一致',
  same(cache4.project(SNAPS[SNAPS.length - 1]), projection.projectTimeline(SNAPS[SNAPS.length - 1])), true);
check('增量投影的投影次数 ≤ 条目数 + 轮数',
  cache4.projectedItems <= TOTAL_ITEMS, 'projected=' + cache4.projectedItems);
check('全量路径的累计投影次数是增量的 50 倍以上',
  fullProjectionCount > cache4.projectedItems * 50,
  'full=' + fullProjectionCount + '，incremental=' + cache4.projectedItems);
check('增量路径的实际耗时不超过全量路径的一半（宽松阈值，防抖动）',
  incrementalMs * 2 <= fullMs, 'incremental=' + incrementalMs + ' ms，full=' + fullMs + ' ms');

// 端到端（含 mergeTimelineItems 的 O(N) 合并 —— 这一步 R42 未改，仍是每轮全量）
function endToEnd(incremental) {
  const cache = new timelineView.TimelineProjectionCache();
  let items = HISTORY;
  const t = Date.now();
  if (incremental) { cache.project(items); } else { projection.projectTimeline(items); }
  for (let i = 0; i < ROUNDS.length; i++) {
    items = projection.mergeTimelineItems(items, ROUNDS[i], false);
    if (incremental) { cache.project(items); } else { projection.projectTimeline(items); }
  }
  return Date.now() - t;
}
const e2eFull = endToEnd(false);
const e2eIncremental = endToEnd(true);
console.log('   端到端（含每轮 merge）：全量 ' + e2eFull + ' ms，增量 ' + e2eIncremental + ' ms');
check('端到端也不劣化（增量 ≤ 全量）', e2eIncremental <= e2eFull,
  'incremental=' + e2eIncremental + ' ms，full=' + e2eFull + ' ms');

// 规模扫描：会话越长，全量重投影的代价越大；增量对 N 不敏感（每轮只投影变化的条目）
function scaleScan(historySize, rounds) {
  const hist = [];
  for (let i = 0; i < historySize; i++) {
    hist.push(SHAPES[i % SHAPES.length]('s-' + i, i, i));
  }
  const incoming = [];
  for (let i = 0; i < rounds; i++) {
    incoming.push([SHAPES[i % SHAPES.length]('sr-' + i, historySize + i, i)]);
  }
  const snaps = [];
  let items = hist;
  for (let i = 0; i < rounds; i++) {
    items = projection.mergeTimelineItems(items, incoming[i], false);
    snaps.push(items);
  }
  const t0 = Date.now();
  for (let i = 0; i < snaps.length; i++) {
    projection.projectTimeline(snaps[i]);
  }
  const fullMs = Date.now() - t0;
  const cache = new timelineView.TimelineProjectionCache();
  const t1 = Date.now();
  cache.project(hist);
  for (let i = 0; i < snaps.length; i++) {
    cache.project(snaps[i]);
  }
  const incrementalMs = Date.now() - t1;
  const last = snaps[snaps.length - 1];
  const ok = same(cache.project(last), projection.projectTimeline(last));
  return {
    historySize: historySize, rounds: rounds, fullMs: fullMs, incrementalMs: incrementalMs,
    projected: cache.projectedItems, fullProjected: historySize * rounds, ok: ok
  };
}
console.log('   规模扫描（200 轮增量，正文约 0.4 KB/条）：');
console.log('     历史条数   全量投影次数   全量耗时   增量耗时   (增量投影次数)');
for (const size of [300, 1000, 3000]) {
  const s = scaleScan(size, 200);
  console.log('     ' + String(s.historySize).padStart(7) + '   ' + String(s.fullProjected).padStart(12)
    + '   ' + String(s.fullMs + ' ms').padStart(8) + '   ' + String(s.incrementalMs + ' ms').padStart(8)
    + '   (' + s.projected + ')');
  check('规模 ' + size + '：末次结果仍与全量一致', s.ok);
  check('规模 ' + size + '：增量耗时 ≤ 全量耗时', s.incrementalMs <= s.fullMs,
    'incremental=' + s.incrementalMs + ' ms，full=' + s.fullMs + ' ms');
}

// ---------------------------------------------------------------------------
// ⑤ store 接线（静态判据：防「优化被改回去」）
// ---------------------------------------------------------------------------

group('SessionDetailStore 接线（静态判据）');

const storeSrc = fs.readFileSync(path.join(SRC_ETS, 'feature', 'SessionDetailStore.ets'), 'utf8');
// ⚠️ 只看**代码行**：注释里会写「原来这里是 this.messages.concat(...)」这类历史说明，
// 直接对整份源码做 indexOf 会把注释当成代码（本套件首版就是这么假红过一次）。
const storeCode = storeSrc.split(/\r?\n/)
  .map((l) => l.trim())
  .filter((l) => l.length > 0 && !l.startsWith('//') && !l.startsWith('*') && !l.startsWith('/*'))
  .join('\n');
const countMatches = (text, re) => {
  const found = text.match(re);
  return found === null ? 0 : found.length;
};
eq('全量重投影调用已清零（不许再出现 projectTimeline(this.items)）',
  countMatches(storeCode, /projectTimeline\(/g), 0);
eq('增量视图 setItems 调用点 = 4（open / loadMoreHistory / flushBatch / recoverFrom）',
  countMatches(storeCode, /this\.view\.setItems\(/g), 4);
check('换会话时视图归零', storeCode.indexOf('this.view.reset();') >= 0);
const messageAssignments = storeCode.split(/\r?\n/)
  .map((l) => l.trim())
  .filter((l) => /^this\.messages\s*=/.test(l));
check('messages 的每一处赋值都来自增量视图（或清空）',
  messageAssignments.every((l) => l === 'this.messages = this.view.messages();' || l === 'this.messages = [];'),
  messageAssignments.join(' | '));
check('乐观消息不再复制整个 messages 数组（只看代码行）',
  storeCode.indexOf('this.messages.concat(') < 0 && storeCode.indexOf('this.messages.filter(') < 0);
check('乐观消息构造走纯逻辑（TimelineView.buildOptimisticMessage）',
  storeCode.indexOf('buildOptimisticMessage(') >= 0);
check('乐观消息条数由视图统一给出',
  countMatches(storeCode, /this\.optimisticCount = this\.view\.optimisticCount\(\);/g) >= 4);

// ---------------------------------------------------------------------------
// ⑥ B1 边界补齐（任务要求覆盖：空数组 / 单条 / 流式追加 / 流式内容替换 /
//    删除 / 乱序到达 / 重复 id）—— 上面 ①~④ 只走了「只增」这一条路径
// ---------------------------------------------------------------------------

group('B1 边界：单条 / 流式内容替换 / 删除 / 乱序');

const oneCache = new timelineView.TimelineProjectionCache();
const oneItems = [item('one', 1, 'message', { role: 'user', text: '单条' })];
check('单条：增量 == 全量', same(oneCache.project(oneItems), projection.projectTimeline(oneItems)));
eq('单条：投影 1 次', oneCache.projectedItems, 1);
eq('单条：复用 0 次', oneCache.reusedItems, 0);

// 流式**内容替换**：同一 id、revision/updatedSeq 都不变，但对象换了 ⇒ 必须重投影拿新正文
const swapCache = new timelineView.TimelineProjectionCache();
const swapA = [item('swap', 1, 'message', { role: 'assistant', text: '流式第一帧' })];
eq('流式替换：首帧正文', swapCache.project(swapA)[0].body, '流式第一帧');
const swapB = [item('swap', 1, 'message', { role: 'assistant', text: '流式第一帧 + 更长' })];
eq('流式替换：revision 没变也要拿到新正文', swapCache.project(swapB)[0].body, '流式第一帧 + 更长');
check('流式替换：与全量一致', same(swapCache.project(swapB), projection.projectTimeline(swapB)));
eq('流式替换：计入投影次数', swapCache.projectedItems, 2);
// 阳性对照：只换正文、**不换对象引用**时增量缓存查不到变化 ⇒ 这正是「item 不可变（只换引用）」
// 这条前提的代价。写成断言固定住，免得后来者给 mergeTimelineItems 加上原地赋值。
const mutateCache = new timelineView.TimelineProjectionCache();
const mutateItems = [item('mut', 1, 'message', { role: 'user', text: '原始' })];
mutateCache.project(mutateItems);
mutateItems[0].text = '原地改写';
eq('前提固定器：原地改写 item 时缓存按契约不刷新（⇒ 上游必须只换引用）',
  mutateCache.project(mutateItems)[0].body, '原始');

// 删除（items 收缩）—— mergeTimelineItems 没有删除路径，但 open()/resetState() 会让 items 变短
const cutCache = new timelineView.TimelineProjectionCache();
const cutItems = [
  item('c1', 1, 'message', { role: 'user', text: '1' }),
  item('c2', 2, 'message', { role: 'assistant', text: '2' }),
  item('c3', 3, 'message', { role: 'user', text: '3' })
];
eq('删除前 3 条', cutCache.project(cutItems).length, 3);
const cutAfter = [cutItems[0], cutItems[2]];
const cutOut = cutCache.project(cutAfter);
eq('删掉中间一条后剩 2 条', cutOut.length, 2);
check('被删条目不残留', cutOut.every((m) => m.sourceItemId !== 'c2'));
check('删除后仍与全量一致', same(cutOut, projection.projectTimeline(cutAfter)));
eq('全部删除后为空', cutCache.project([]).length, 0);
check('全部删除后仍与全量一致', same(cutCache.project([]), projection.projectTimeline([])));

// 乱序到达：数组顺序与 orderSeq 解耦（历史分页 / 同序按 id 排）
const shuffled = [
  item('o3', 30, 'message', { role: 'user', text: '30' }),
  item('o1', 10, 'message', { role: 'user', text: '10' }),
  item('o2', 20, 'message', { role: 'user', text: '20' })
];
const shuffleCache = new timelineView.TimelineProjectionCache();
eq('乱序到达：按 orderSeq 排好', shuffleCache.project(shuffled).map((m) => m.id).join(','), 'o1#0,o2#0,o3#0');
check('乱序到达：增量 == 全量', same(shuffleCache.project(shuffled), projection.projectTimeline(shuffled)));

/** 增 / 改 / 删 / 倒置 四种事件混合的随机序列（覆盖「收缩」这条原套件没走的路径）。 */
function randomCrudSequence(seed, steps) {
  const next = rng(seed);
  const cache = new timelineView.TimelineProjectionCache();
  let items = [];
  let prevLen = 0;
  let mismatches = 0;
  let firstMismatch = '';
  let deletes = 0;
  let shrinks = 0;
  let mutations = 0;
  for (let step = 0; step < steps; step++) {
    const roll = next();
    if (roll < 0.45 || items.length === 0) {
      const seq = Math.floor(next() * (steps * 2));
      items = items.concat([SHAPES[Math.floor(next() * SHAPES.length)]('c-' + step, seq, step)]);
    } else if (roll < 0.75) {
      const at = Math.floor(next() * items.length);
      const fresh = SHAPES[Math.floor(next() * SHAPES.length)](items[at].id, items[at].orderSeq, step);
      fresh.revision = items[at].revision + 1;
      fresh.updatedSeq = items[at].updatedSeq + 1;
      items = items.slice();
      items[at] = fresh;
      mutations += 1;
    } else if (roll < 0.9) {
      const at = Math.floor(next() * items.length);
      items = items.slice();
      items.splice(at, 1);
      deletes += 1;
    } else if (items.length > 1) {
      items = items.slice().reverse();
    }
    if (items.length < prevLen) {
      shrinks += 1;
    }
    prevLen = items.length;
    const fast = cache.project(items);
    const slow = projection.projectTimeline(items);
    if (!same(fast, slow)) {
      mismatches += 1;
      if (firstMismatch === '') {
        firstMismatch = 'step ' + step;
      }
    }
  }
  return { mismatches: mismatches, deletes: deletes, shrinks: shrinks, mutations: mutations, firstMismatch: firstMismatch, items: items };
}

for (const seed of [11, 20260923, 987654]) {
  const run = randomCrudSequence(seed, 400);
  eq('CRUD seed ' + seed + '：400 步增/改/删混合下增量 == 全量（不一致步数）',
    run.mismatches, 0);
  check('CRUD seed ' + seed + '：真的发生了删除（阳性对照，防序列空转）',
    run.deletes > 20, 'deletes=' + run.deletes);
  check('CRUD seed ' + seed + '：真的发生了收缩（阳性对照）',
    run.shrinks > 10, 'shrinks=' + run.shrinks);
  check('CRUD seed ' + seed + '：真的发生了内容替换（阳性对照）',
    run.mutations > 20, 'mutations=' + run.mutations);
}

// ---------------------------------------------------------------------------
// ⑦ 渲染单元（TimelineRenderItem）的增量 diff —— LazyForEach 数据源的通知口径
//
// 时间线在 LazyForEach 下不再「整数组重发」，而是按 index 发 change / add / delete。
// 这里证明：把 diff 出的 ops **顺序回放**到 prev 上，必须逐项得到 next（不漏报、不错位）。
// ---------------------------------------------------------------------------

group('渲染单元增量 diff：ops 回放后必须逐项等于 next');

/** 走真实管线（增量投影 → 分组），保证「未变的项」在引用上也未变。 */
function renderPipeline() {
  const cache = new timelineView.TimelineProjectionCache();
  return {
    step: function (items) {
      return projection.groupTimelineMessages(cache.project(items));
    }
  };
}

/** 顺序回放 ops（ADD 升序 / DELETE 降序 / CHANGE 直接替换 / reload 整表）。 */
function applyOps(prev, ops, next) {
  if (ops.length === 1 && ops[0].kind === 'reload') {
    return next.slice();
  }
  const cur = prev.slice();
  for (let i = 0; i < ops.length; i++) {
    const op = ops[i];
    if (op.kind === 'change') {
      cur[op.index] = next[op.index];
    } else if (op.kind === 'add') {
      cur.splice(op.index, 0, next[op.index]);
    } else if (op.kind === 'delete') {
      cur.splice(op.index, 1);
    } else {
      return next.slice();
    }
  }
  return cur;
}

function sameRenderItems(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (!projection.sameTimelineRenderItem(a[i], b[i])) {
      return false;
    }
  }
  return true;
}

function opKinds(ops) {
  return ops.map((o) => o.kind).join(',');
}

function isReload(ops) {
  return ops.length === 1 && ops[0].kind === 'reload';
}

// 空 ↔ 空 / 空 → 非空 / 非空 → 空
eq('空表到空表：无操作', projection.diffTimelineRenderItems([], []).length, 0);
const pipeEmpty = renderPipeline();
const someItems = [
  item('ra', 1, 'message', { role: 'user', text: 'a' }),
  item('rb', 2, 'message', { role: 'assistant', text: 'b' })
];
const fromEmpty = pipeEmpty.step(someItems);
const opsEmptyToSome = projection.diffTimelineRenderItems([], fromEmpty);
eq('空 → 2 条：两条 add', opKinds(opsEmptyToSome), 'add,add');
check('空 → 2 条：回放后等于 next', sameRenderItems(applyOps([], opsEmptyToSome, fromEmpty), fromEmpty));
const opsSomeToEmpty = projection.diffTimelineRenderItems(fromEmpty, []);
eq('2 条 → 空：两条 delete（降序，先删后面的）', opKinds(opsSomeToEmpty), 'delete,delete');
check('2 条 → 空：删除索引降序', opsSomeToEmpty[0].index > opsSomeToEmpty[1].index,
  JSON.stringify(opsSomeToEmpty));
check('2 条 → 空：回放后等于 next', sameRenderItems(applyOps(fromEmpty, opsSomeToEmpty, []), []));

// 内容完全没变（新数组、同一批消息对象）⇒ 一条通知都不许发
const noopOps = projection.diffTimelineRenderItems(fromEmpty, fromEmpty.slice());
eq('内容没变：零通知（不许整表 reload）', noopOps.length, 0);

// 只增（流式尾插）
const pipeGrow = renderPipeline();
const grow1 = pipeGrow.step(someItems);
const grow2 = pipeGrow.step(someItems.concat([item('rc', 3, 'tool', { content: { kind: 'command', command: 'ls' } })]));
const opsGrow = projection.diffTimelineRenderItems(grow1, grow2);
eq('尾插一条：只有一条 add', opKinds(opsGrow), 'add');
eq('尾插一条：add 的索引是尾部', opsGrow[0].index, grow1.length);
check('尾插一条：回放后等于 next', sameRenderItems(applyOps(grow1, opsGrow, grow2), grow2));

// 流式正文增长（同一渲染单元，内容换新对象）
const pipeStream = renderPipeline();
const stream1 = pipeStream.step([item('st', 1, 'message', { role: 'assistant', text: '第一帧' })]);
const stream2 = pipeStream.step([item('st', 1, 'message', { role: 'assistant', text: '第一帧 + 第二帧' })]);
const opsStream = projection.diffTimelineRenderItems(stream1, stream2);
eq('流式正文增长：一条 change', opKinds(opsStream), 'change');
eq('流式正文增长：change 的索引是 0', opsStream[0].index, 0);
check('流式正文增长：回放后等于 next（正文确实换了）',
  sameRenderItems(applyOps(stream1, opsStream, stream2), stream2));

// 中间删除
// ⚠️ 这里**必须复用同一批 item 对象**（真实 store 的语义：mergeTimelineItems 只换引用，
//    没变的 item 引用不变 ⇒ 增量投影复用同一批 message 对象 ⇒ diff 才能证明「内容相同」）。
//    若换成一组新造的 item（同一 id、新对象），diff 会保守地报 change/reload —— 那是**允许**的多报。
const pipeCut = renderPipeline();
const cutItems3 = [
  item('k1', 1, 'message', { role: 'user', text: '1' }),
  item('k2', 2, 'message', { role: 'user', text: '2' }),
  item('k3', 3, 'message', { role: 'user', text: '3' })
];
const cut3 = pipeCut.step(cutItems3);
const cut2 = pipeCut.step([cutItems3[0], cutItems3[2]]);
const opsCut = projection.diffTimelineRenderItems(cut3, cut2);
eq('中间删一条：一条 delete', opKinds(opsCut), 'delete');
eq('中间删一条：索引 1', opsCut[0].index, 1);
check('中间删一条：回放后等于 next', sameRenderItems(applyOps(cut3, opsCut, cut2), cut2));

// 头部插入（loadMoreHistory 的历史前置）
const pipePrepend = renderPipeline();
const body = [
  item('h1', 10, 'message', { role: 'user', text: '1' }),
  item('h2', 20, 'message', { role: 'assistant', text: '2' })
];
const afterPrepend = pipePrepend.step([
  item('h0', 5, 'message', { role: 'user', text: '0' })
].concat(body));
const beforePrepend = pipePrepend.step(body);
const opsPrepend = projection.diffTimelineRenderItems(beforePrepend, afterPrepend);
eq('头部插入一条：一条 add', opKinds(opsPrepend), 'add');
eq('头部插入一条：索引 0', opsPrepend[0].index, 0);
check('头部插入一条：回放后等于 next',
  sameRenderItems(applyOps(beforePrepend, opsPrepend, afterPrepend), afterPrepend));

// 工具组边界翻转（single ⇄ toolRun）——分组边界变了，索引没变
const pipeGroup = renderPipeline();
const oneTool = [item('t1', 1, 'tool', { content: { kind: 'command', command: 'ls' } })];
const twoTools = oneTool.concat([item('t2', 2, 'tool', { content: { kind: 'command', command: 'pwd' } })]);
const g1 = pipeGroup.step(oneTool);
const g2 = pipeGroup.step(twoTools);
const g3 = pipeGroup.step(oneTool);
eq('单条工具：groupKind=single', g1[0].groupKind, 'single');
eq('两条工具：合并成 toolRun', g2[0].groupKind, 'toolRun');
const opsGroupIn = projection.diffTimelineRenderItems(g1, g2);
eq('single → toolRun：一条 change（不是 reload）', opKinds(opsGroupIn), 'change');
check('single → toolRun：回放后等于 next', sameRenderItems(applyOps(g1, opsGroupIn, g2), g2));
const opsGroupOut = projection.diffTimelineRenderItems(g2, g3);
eq('toolRun → single：一条 change', opKinds(opsGroupOut), 'change');
check('toolRun → single：回放后等于 next', sameRenderItems(applyOps(g2, opsGroupOut, g3), g3));

// 无法按 key 对齐（整表换掉）⇒ reload
const pipeReset = renderPipeline();
const whole1 = pipeReset.step([
  item('z1', 1, 'message', { role: 'user', text: '1' }),
  item('z2', 2, 'message', { role: 'user', text: '2' }),
  item('z3', 3, 'message', { role: 'user', text: '3' })
]);
const whole2 = pipeReset.step([
  item('y1', 1, 'message', { role: 'user', text: '1' }),
  item('y2', 2, 'message', { role: 'user', text: '2' })
]);
check('对不齐（3 → 2 条且前置位不同）⇒ reload', isReload(projection.diffTimelineRenderItems(whole1, whole2)));
check('reload 回放后等于 next',
  sameRenderItems(applyOps(whole1, projection.diffTimelineRenderItems(whole1, whole2), whole2), whole2));

// 阳性对照：判断函数不是恒真
check('阳性对照：把所有项换成新对象（无缓存）时会报 change，而不是「无操作」',
  projection.diffTimelineRenderItems(g1, projection.groupTimelineMessages(projection.projectTimeline(oneTool))).length > 0);

// 随机 CRUD 全流程：每一步都回放验证 + 统计通知构成
function randomRenderSequence(seed, steps) {
  const next = rng(seed);
  const pipe = renderPipeline();
  let items = [];
  // 每条 item 的形态（SHAPES 下标）固定：真实会话里一个 item 的 type 不会跳变，
  // 只有「内容 / 连板 / 删除」在变。形态跳变会让分组整体重排 ⇒ 必然 reload，那是测不出「按需通知」的。
  let shapes = [];
  let prev = [];
  let mismatches = 0;
  let reloads = 0;
  let adds = 0;
  let deletes = 0;
  let changes = 0;
  let noop = 0;
  for (let step = 0; step < steps; step++) {
    const roll = next();
    if (roll < 0.55 || items.length === 0) {
      const shape = Math.floor(next() * SHAPES.length);
      items = items.concat([SHAPES[shape]('rr-' + step, step, step)]);
      shapes = shapes.concat([shape]);
    } else if (roll < 0.8) {
      const at = Math.floor(next() * items.length);
      const fresh = SHAPES[shapes[at]](items[at].id, items[at].orderSeq, step);
      fresh.revision = items[at].revision + 1;
      fresh.updatedSeq = items[at].updatedSeq + 1;
      items = items.slice();
      items[at] = fresh;
    } else if (roll < 0.92) {
      const at = Math.floor(next() * items.length);
      items = items.slice();
      items.splice(at, 1);
      shapes = shapes.slice();
      shapes.splice(at, 1);
    }
    const cur = pipe.step(items);
    const ops = projection.diffTimelineRenderItems(prev, cur);
    if (!sameRenderItems(applyOps(prev, ops, cur), cur)) {
      mismatches += 1;
    }
    if (ops.length === 0) {
      noop += 1;
    }
    for (let i = 0; i < ops.length; i++) {
      if (ops[i].kind === 'reload') { reloads += 1; }
      else if (ops[i].kind === 'add') { adds += 1; }
      else if (ops[i].kind === 'delete') { deletes += 1; }
      else { changes += 1; }
    }
    prev = cur;
  }
  return { mismatches: mismatches, reloads: reloads, adds: adds, deletes: deletes, changes: changes, noop: noop };
}

for (const seed of [7, 20260923, 424242]) {
  const run = randomRenderSequence(seed, 400);
  eq('渲染 diff seed ' + seed + '：400 步下 ops 回放**逐项**等于 next（不一致步数）', run.mismatches, 0);
  check('渲染 diff seed ' + seed + '：真的产生过 add/delete/change（阳性对照）',
    run.adds > 0 && run.deletes > 0 && run.changes > 0,
    'add=' + run.adds + '，delete=' + run.deletes + '，change=' + run.changes);
}
const renderRun = randomRenderSequence(20260923, 400);
// ⚠️ reload 的**唯一**来源是「分组结构变了、按 key 对不齐」：一次删除可能把
//    「single + toolRun」并成「toolRun」（render item 数一次掉 2），这种整段重排只能 reload。
//    400 步里 2 步（0.5%）落在这里 —— 它不是「每次都整表 reload」。
check('渲染 diff：reload 只出现在分组结构对不齐的少数步（≤ 5/400）',
  renderRun.reloads <= 5, 'reloads=' + renderRun.reloads);
check('渲染 diff：确有无变化步（内容没变时一条通知都不发）', renderRun.noop > 0, 'noop=' + renderRun.noop);

/** 真实流式形态：300 条历史 + N 轮「追加一条 assistant，然后原地长出来」。 */
function streamingRenderSequence(historySize, rounds, deltasPerRound) {
  const pipe = renderPipeline();
  let items = [];
  for (let i = 0; i < historySize; i++) {
    items.push(SHAPES[i % SHAPES.length]('hs-' + i, i, i));
  }
  let prev = pipe.step(items);
  let reloads = 0;
  let adds = 0;
  let changes = 0;
  let deletes = 0;
  let steps = 0;
  let mismatches = 0;
  for (let r = 0; r < rounds; r++) {
    const id = 'sr-' + r;
    const seq = historySize + r * 2;
    let stepItems = items.concat([SHAPES[1](id, seq, r)]);
    for (let d = 0; d <= deltasPerRound; d++) {
      if (d > 0) {
        const at = stepItems.length - 1;
        const fresh = SHAPES[1](id, seq, r);
        fresh.text = '增量第 ' + d + ' 帧。'.repeat(40);
        fresh.revision = d + 1;
        fresh.updatedSeq = seq + d;
        fresh.status = 'streaming';
        stepItems = stepItems.slice();
        stepItems[at] = fresh;
      }
      const cur = pipe.step(stepItems);
      const ops = projection.diffTimelineRenderItems(prev, cur);
      steps += 1;
      if (!sameRenderItems(applyOps(prev, ops, cur), cur)) {
        mismatches += 1;
      }
      for (let i = 0; i < ops.length; i++) {
        if (ops[i].kind === 'reload') { reloads += 1; }
        else if (ops[i].kind === 'add') { adds += 1; }
        else if (ops[i].kind === 'delete') { deletes += 1; }
        else { changes += 1; }
      }
      prev = cur;
    }
    items = stepItems;
  }
  return { reloads: reloads, adds: adds, changes: changes, deletes: deletes, steps: steps, mismatches: mismatches };
}

const streamRun = streamingRenderSequence(300, 200, 5);
eq('流式长会话（300 条历史 + 200 轮 × 5 帧）：ops 回放逐项等于 next（不一致步数）', streamRun.mismatches, 0);
eq('流式长会话：**零** reload（每一帧都是按需 change）', streamRun.reloads, 0);
eq('流式长会话：change 次数 == 增量帧数（每帧只动尾部那一个渲染单元）',
  streamRun.changes, 200 * 5);
eq('流式长会话：每一步恰好产出 1 条通知（add 或 change），没有整表重发',
  streamRun.adds + streamRun.changes, streamRun.steps);
eq('流式长会话：add 次数 == 轮数', streamRun.adds, 200);
eq('流式长会话：delete 次数 0（流式里没有删除）', streamRun.deletes, 0);
console.log('   流式长会话（' + 300 + ' 条历史 + 200 轮 × 5 帧，共 ' + streamRun.steps + ' 步）：change '
  + streamRun.changes + ' / add ' + streamRun.adds + ' / delete ' + streamRun.deletes + ' / reload ' + streamRun.reloads);

// UI 层每帧成本：`groupTimelineMessages`（改前/改后都要付）vs `diffTimelineRenderItems`（R55 新增的那一步）。
// 用 hrtime 计到纳秒级：Date.now() 只有 1ms 分辨率，这类亚毫秒操作量不出来。
group('时间线 UI 层的每帧成本（LazyForEach 新增的 diff 步）');
function uiLayerCost(historySize, rounds, deltasPerRound) {
  const cache = new timelineView.TimelineProjectionCache();
  let items = [];
  for (let i = 0; i < historySize; i++) {
    items.push(SHAPES[i % SHAPES.length]('uc-' + i, i, i));
  }
  let prev = [];
  let groupNs = 0;
  let diffNs = 0;
  let frames = 0;
  for (let r = 0; r < rounds; r++) {
    const id = 'usr-' + r;
    const seq = historySize + r * 2;
    let stepItems = items.concat([SHAPES[1](id, seq, r)]);
    for (let d = 0; d <= deltasPerRound; d++) {
      if (d > 0) {
        const at = stepItems.length - 1;
        const fresh = SHAPES[1](id, seq, r);
        fresh.text = '增量第 ' + d + ' 帧。'.repeat(40);
        fresh.revision = d + 1;
        fresh.updatedSeq = seq + d;
        stepItems = stepItems.slice();
        stepItems[at] = fresh;
      }
      const messages = cache.project(stepItems);
      const t0 = process.hrtime.bigint();
      const cur = projection.groupTimelineMessages(messages);
      const t1 = process.hrtime.bigint();
      projection.diffTimelineRenderItems(prev, cur);
      const t2 = process.hrtime.bigint();
      groupNs += Number(t1 - t0);
      diffNs += Number(t2 - t1);
      frames += 1;
      prev = cur;
    }
    items = stepItems;
  }
  return { frames: frames, groupMs: groupNs / 1e6, diffMs: diffNs / 1e6 };
}
const uiCost = uiLayerCost(300, 200, 5);
console.log('   300 条历史 / 200 轮 × 5 帧（' + uiCost.frames + ' 帧）：groupTimelineMessages '
  + uiCost.groupMs.toFixed(1) + ' ms，diffTimelineRenderItems ' + uiCost.diffMs.toFixed(1) + ' ms'
  + ' ⇒ 每帧 group ' + (uiCost.groupMs * 1000 / uiCost.frames).toFixed(1) + ' µs + diff '
  + (uiCost.diffMs * 1000 / uiCost.frames).toFixed(1) + ' µs');
// 宽松阈值（+5ms 余量）只为挡住「diff 比分组还贵一个数量级」这种结构性退化，不做性能门禁。
check('LazyForEach 新增的 diff 步与分组同数量级（不引入新的热点）',
  uiCost.diffMs <= uiCost.groupMs * 2 + 5,
  'diff=' + uiCost.diffMs.toFixed(2) + ' ms，group=' + uiCost.groupMs.toFixed(2) + ' ms');
console.log('   渲染 diff（seed 20260923，400 步）：add ' + renderRun.adds + ' / delete ' + renderRun.deletes
  + ' / change ' + renderRun.changes + ' / reload ' + renderRun.reloads + ' / 无变化步 ' + renderRun.noop);

// LazyForEach 的 key 口径：稳定唯一 + 含会变字段 + 不含 @State 标记（@State 标记进 key 反而不刷新）
group('LazyForEach key（timelineRenderItemKey）');
const keyBase = projection.groupTimelineMessages(projection.projectTimeline([
  item('kk', 1, 'message', { role: 'assistant', text: '正文' })
]))[0];
eq('同一内容重复求 key：稳定', projection.timelineRenderItemKey(keyBase), projection.timelineRenderItemKey(keyBase));
const keyRev = projection.groupTimelineMessages(projection.projectTimeline([
  Object.assign(item('kk', 1, 'message', { role: 'assistant', text: '正文' }), { revision: 2, updatedSeq: 2 })
]))[0];
check('revision/updatedSeq 变了 ⇒ key 变（含会变字段）',
  projection.timelineRenderItemKey(keyRev) !== projection.timelineRenderItemKey(keyBase));
const keyStatus = projection.groupTimelineMessages(projection.projectTimeline([
  Object.assign(item('kk', 1, 'message', { role: 'assistant', text: '正文' }), { status: 'streaming' })
]))[0];
check('status 变了 ⇒ key 变', projection.timelineRenderItemKey(keyStatus) !== projection.timelineRenderItemKey(keyBase));
const keyOther = projection.groupTimelineMessages(projection.projectTimeline([
  item('kz', 9, 'message', { role: 'user', text: '别的' })
]))[0];
check('不同渲染单元 ⇒ key 不同（唯一性）',
  projection.timelineRenderItemKey(keyOther) !== projection.timelineRenderItemKey(keyBase));
const keyOtherSameRev = projection.groupTimelineMessages(projection.projectTimeline([
  Object.assign(item('kz', 9, 'message', { role: 'user', text: '别的' }), { revision: 2, updatedSeq: 2 })
]))[0];
check('阳性对照：只改 revision 不足以让两条不同 id 撞 key',
  projection.timelineRenderItemKey(keyOtherSameRev) !== projection.timelineRenderItemKey(keyRev));

// ---------------------------------------------------------------------------
// ⑧ LazyForEach 接线（静态判据：防「优化被改回去」，口径同 ⑤）
// ---------------------------------------------------------------------------

group('LazyForEach 接线（静态判据）');

function stripComments(src) {
  return src.split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith('//') && !l.startsWith('*') && !l.startsWith('/*'))
    .join('\n');
}

const screenSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'SessionDetailScreen.ets'), 'utf8');
const screenCode = stripComments(screenSrc);
eq('时间线走 LazyForEach', countMatches(screenCode, /LazyForEach\(/g), 1);
eq('时间线的 ForEach(this.renderItems) 已消失', countMatches(screenCode, /ForEach\(this\.renderItems/g), 0);
check('数据源实现 IDataSource', screenCode.indexOf('implements IDataSource') >= 0);
check('IDataSource.totalCount 已实现', screenCode.indexOf('totalCount(): number') >= 0);
check('IDataSource.getData 已实现', screenCode.indexOf('getData(index: number)') >= 0);
check('IDataSource.registerDataChangeListener 已实现', screenCode.indexOf('registerDataChangeListener(listener: DataChangeListener)') >= 0);
check('IDataSource.unregisterDataChangeListener 已实现', screenCode.indexOf('unregisterDataChangeListener(listener: DataChangeListener)') >= 0);
check('pull() 把新数组喂给数据源', screenCode.indexOf('this.timelineSource.setItems(') >= 0);
check('数据源走增量 diff 发通知（不是每次 reload）', screenCode.indexOf('diffTimelineRenderItems(') >= 0);
check('keyGenerator 走纯逻辑 timelineRenderItemKey（可单测）', screenCode.indexOf('timelineRenderItemKey(item)') >= 0);
check('数据源不是 @State（必须是稳定对象，靠自己的通知刷新）',
  screenCode.indexOf('private timelineSource: TimelineRenderDataSource') >= 0);
const projectionCode = stripComments(fs.readFileSync(path.join(SRC_ETS, 'feature', 'TimelineProjection.ets'), 'utf8'));
check('key 生成里没有 @State 标记（expandedIds / turnActions）',
  projectionCode.indexOf('expandedIds') < 0 && projectionCode.indexOf('turnActions') < 0);
check('diff 只在纯逻辑层实现（页面不自己算 diff）',
  countMatches(screenCode, /diffTimelineRenderItems\(/g) === 1);


// ---------------------------------------------------------------------------

console.log('');
if (failures.length > 0) {
  console.log('失败 ' + failures.length + ' 项：');
  for (const f of failures) {
    console.log('  ✗ ' + f);
  }
  console.log('suite-timeline-incremental: ' + passed + ' 通过 / ' + failures.length + ' 失败');
  process.exit(1);
}
console.log('suite-timeline-incremental: ' + passed + ' 条断言全绿。');
