#!/usr/bin/env node
/**
 * aa-hm 时间线**重复显示**回归自测（R80 轮新增）。
 *
 * 复现并锁死两个真机缺陷：
 *   ① 长对话里新增的用户消息被渲染成两份 —— 服务端回执键在 `item.source.clientMessageId`，
 *      而视图层原先只查 `item.content.clientMessageId`，导致乐观消息永不摘除；
 *      另外 items 层补一条**业务身份**去重（同 source.clientMessageId + 同 source.itemId）作第二层免疫。
 *   ② 「上下文压缩」出现多条 —— 上游对**每一条** compaction/* 记录各产出一个 marker item
 *      （本会话 4 次压缩共 24 条：start 4 + summary 4 + end 4 + prune 12），标题恒为「上下文压缩」。
 *      App 侧按 content.details.compactionId 归并；无 id 的 prune **优先并入后一个已存在的组**
 *      （日志物理顺序：prune 簇紧贴在它所服务的那次 compaction/start 之前），后面没有组才并入前一个组。
 *
 * 转译方式与 suite-timeline-incremental.mjs 一致（DevEco 自带 TypeScript → CommonJS → Node 断言）。
 * 产物落在系统临时目录（不污染工程目录）。
 *
 * 用法：
 *   node tools\\logic-test\\suite-timeline-dup.mjs
 */

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-timeline-dup');

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
  const requireTs = createRequire(import.meta.url);
  const ts = requireTs(TS_PACKAGE);
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
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

/** 造一条字段齐全的 RemoteTimelineItem。 */
function item(id, orderSeq, type, extra) {
  const base = {
    id: id, sessionId: 's1', type: type, status: 'done', text: '',
    content: {}, source: {}, orderSeq: orderSeq,
    revision: 1, updatedSeq: orderSeq, createdAt: '2026-09-24T00:00:00Z'
  };
  return Object.assign(base, extra || {});
}

function ids(list) {
  return list.map((it) => it.id).join(',');
}

const CM = 'hm-1790233835184-9c51853f';
const NATIVE = '5cac2429-efac-46e9-86c3-35f606a5f261';

function userItem(id, orderSeq, extra) {
  return item(id, orderSeq, 'message', Object.assign({
    role: 'user', text: '1.向上滑动时，功能会被盖住。2.对话页等页面的功能栏未采用官方方案，优化',
    source: { runtime: 'dsh', itemId: NATIVE + ':0', itemType: 'user/message', clientMessageId: CM }
  }, extra || {}));
}

// ---------------------------------------------------------------------------
// ① 乐观消息回执：回执键在 source 上（契约位置）也要能摘掉乐观消息
// ---------------------------------------------------------------------------
group('① 乐观消息回执键：source.clientMessageId（契约位置）');
{
  const view = new timelineView.TimelineMessageView();
  view.setItems([]);
  view.addOptimistic(timelineView.buildOptimisticMessage(CM, '你好', [], '2026-09-24T00:00:00Z'));
  eq('未回执时乐观消息在视图里（既有行为）', view.messages().length, 1);
  // 阴性对照：服务端推来的是别的 item（不带任何 clientMessageId）⇒ 乐观消息必须还在
  view.setItems([item('tl-other', 5, 'message', { role: 'assistant', text: '别的' })]);
  eq('阴性对照：无回执键的 item 不吞乐观消息', view.messages().length, 2);
  eq('阴性对照：optimisticCount 仍为 1', view.optimisticCount(), 1);
  // 阳性：服务端回执只有 source.clientMessageId（线上契约位置）
  const view2 = new timelineView.TimelineMessageView();
  view2.setItems([]);
  view2.addOptimistic(timelineView.buildOptimisticMessage(CM, '你好', [], '2026-09-24T00:00:00Z'));
  view2.setItems([userItem('tl-user', 10)]);
  eq('source.clientMessageId 到达 ⇒ 乐观消息被摘掉', view2.messages().length, 1);
  eq('留下的那条是服务端 item 投影', view2.messages()[0].id, 'tl-user#0');
  eq('optimisticCount 归零', view2.optimisticCount(), 0);
  // 兼容回退：只有 content.clientMessageId 的旧形态仍然要能摘
  const view3 = new timelineView.TimelineMessageView();
  view3.setItems([]);
  view3.addOptimistic(timelineView.buildOptimisticMessage('cm-legacy', '旧', [], '2026-09-24T00:00:00Z'));
  view3.setItems([item('tl-legacy', 11, 'message', { role: 'user', text: '旧', content: { clientMessageId: 'cm-legacy' } })]);
  eq('content.clientMessageId 兼容回退仍生效', view3.optimisticCount(), 0);
  // source 优先：source 与 content 同时存在时，以 source 为准
  const view4 = new timelineView.TimelineMessageView();
  view4.setItems([]);
  view4.addOptimistic(timelineView.buildOptimisticMessage('cm-src-priority', '优先', [], '2026-09-24T00:00:00Z'));
  view4.setItems([item('tl-both', 12, 'message', {
    role: 'user', text: '优先',
    content: { clientMessageId: 'cm-content-other' },
    source: { clientMessageId: 'cm-src-priority' }
  })]);
  eq('source 优先于 content', view4.optimisticCount(), 0);
}
// ---------------------------------------------------------------------------
// ② items 层业务身份去重（同 source.clientMessageId + 同 source.itemId）
// ---------------------------------------------------------------------------
group('② items 层业务身份去重（窄键）');
{
  // 同一条逻辑消息的两条 item（不同 id，同 source.clientMessageId + 同 source.itemId）
  const a = userItem('tl-a', 10);
  const b = userItem('tl-b', 10);
  b.revision = 2;
  b.updatedSeq = 11;
  const merged = projection.mergeTimelineItems([a], [b], false);
  eq('同源同块的两条 item 合成一条（增量分支）', merged.length, 1);
  eq('留下的是 revision 更新者', merged[0].id, 'tl-b');
  const snapshot = projection.mergeTimelineItems([], [a, b], true);
  eq('同源同块的两条 item 合成一条（快照分支）', snapshot.length, 1);
  eq('快照分支留下的也是 revision 更新者', snapshot[0].id, 'tl-b');
  // 窄键守卫 1：同 clientMessageId 但不同内容块（itemId 不同）不许合并
  const block0 = userItem('tl-blk0', 10);
  const block1 = userItem('tl-blk1', 11, { source: { itemId: NATIVE + ':1', clientMessageId: CM } });
  eq('同消息不同块（itemId 不同）不合并', projection.mergeTimelineItems([], [block0, block1], true).length, 2);
  // 窄键守卫 2：没有 clientMessageId 的 item 一律不参与去重（逐字节原行为）
  const asst1 = item('tl-asst1', 20, 'message', { role: 'assistant', text: '回复一' });
  const asst2 = item('tl-asst2', 21, 'message', { role: 'assistant', text: '回复二' });
  eq('无 clientMessageId 的 item 不参与去重', projection.mergeTimelineItems([], [asst1, asst2], true).length, 2);
  // 窄键守卫 3：clientMessageId 相同但 itemId 缺省（空串）—— 视为同一块，仍要合并（契约允许）
  const noNative1 = item('tl-nn1', 30, 'message', { role: 'user', text: 'x', source: { clientMessageId: CM } });
  const noNative2 = item('tl-nn2', 31, 'message', { role: 'user', text: 'x', source: { clientMessageId: CM } });
  eq('同 clientMessageId 且都缺 itemId ⇒ 合并', projection.mergeTimelineItems([], [noNative1, noNative2], true).length, 1);
  // 普通消息序列逐字节原样保留（回归守卫）
  const plain = [item('p1', 1, 'message', { role: 'user', text: 'u1' }), item('p2', 2, 'tool', { content: { kind: 'command', command: 'ls' } })];
  eq('无身份信息的普通 item 逐条保留', ids(projection.mergeTimelineItems([], plain, true)), 'p1,p2');
}

// ---------------------------------------------------------------------------
// ③ 上下文压缩 marker 归并（语料形态取自真机会话：4 次压缩 / 24 条记录）
// ---------------------------------------------------------------------------
group('③ 上下文压缩 marker 归并');

/** 真机会话日志里的 24 条 compaction/* 记录（seq / 类型 / compactionId）——原样照抄。 */
const COMPACTIONS = [
  { seq: 2600, type: 'compaction/prune' },
  { seq: 2602, type: 'compaction/prune' },
  { seq: 2604, type: 'compaction/prune' },
  { seq: 2606, type: 'compaction/prune' },
  { seq: 2608, type: 'compaction/prune' },
  { seq: 2610, type: 'compaction/prune' },
  { seq: 2810, type: 'compaction/start', cid: '7d8f32b7-6f42-4895-91a6-eab6089bc832' },
  { seq: 2811, type: 'compaction/summary', cid: '7d8f32b7-6f42-4895-91a6-eab6089bc832' },
  { seq: 2813, type: 'compaction/end', cid: '7d8f32b7-6f42-4895-91a6-eab6089bc832' },
  { seq: 4040, type: 'compaction/start', cid: '6b2e512c-0000-0000-0000-000000000000' },
  { seq: 4041, type: 'compaction/summary', cid: '6b2e512c-0000-0000-0000-000000000000' },
  { seq: 4043, type: 'compaction/end', cid: '6b2e512c-0000-0000-0000-000000000000' },
  { seq: 6495, type: 'compaction/prune' },
  { seq: 6497, type: 'compaction/prune' },
  { seq: 6499, type: 'compaction/prune' },
  { seq: 6501, type: 'compaction/prune' },
  { seq: 6503, type: 'compaction/prune' },
  { seq: 6505, type: 'compaction/prune' },
  { seq: 6602, type: 'compaction/start', cid: 'f13749b1-0000-0000-0000-000000000000' },
  { seq: 6603, type: 'compaction/summary', cid: 'f13749b1-0000-0000-0000-000000000000' },
  { seq: 6605, type: 'compaction/end', cid: 'f13749b1-0000-0000-0000-000000000000' },
  { seq: 7937, type: 'compaction/start', cid: '5216fc46-0000-0000-0000-000000000000' },
  { seq: 7938, type: 'compaction/summary', cid: '5216fc46-0000-0000-0000-000000000000' },
  { seq: 7940, type: 'compaction/end', cid: '5216fc46-0000-0000-0000-000000000000' }
];

/** 把一条 compaction 记录造成上游产出的 marker item（bridge index.js:3614-3619 的形态）。 */
function compactItem(record) {
  const details = {};
  if (record.cid) { details.compactionId = record.cid; }
  return item('dsh-marker-' + record.seq, record.seq, 'marker', {
    content: { kind: 'compact', title: '上下文压缩', eventType: record.type, details: details },
    source: { runtime: 'dsh', itemId: String(record.seq), itemType: record.type, seq: record.seq }
  });
}
const ALL_COMPACT = COMPACTIONS.map(compactItem);
const compactSnapshot = projection.mergeTimelineItems([], ALL_COMPACT, true);
eq('24 条 compaction 记录归并成 4 个 marker（= 真实压缩次数）', compactSnapshot.length, 4);
const cids = compactSnapshot.filter((it) => it.content.details && it.content.details.compactionId)
  .map((it) => it.content.details.compactionId);
eq('4 个 compactionId 各只留一条', cids.length, 4);
eq('compactionId 去重后无重复', new Set(cids).size, 4);
eq('有 id 的 marker 保留首次出现位置（seq 升序）', cids.length === 4 && cids[0].indexOf('7d8f32b7') === 0 && cids[3].indexOf('5216fc46') === 0, true);
eq('归并后的 marker 仍按 orderSeq 升序', compactSnapshot.every((it, i) => i === 0 || compactSnapshot[i - 1].orderSeq < it.orderSeq), true);
const compactMessages = projection.projectTimeline(compactSnapshot).filter((m) => m.kind === 'marker');
eq('投影出的「上下文压缩」行数 = 4（原来 24）', compactMessages.filter((m) => m.title === '上下文压缩').length, 4);

// 增量到达（分 6 批，replace=false）必须与全量快照逐字一致
{
  let acc = [];
  const batches = [0, 6, 9, 12, 18, 21, 24];
  for (let b = 0; b + 1 < batches.length; b++) {
    acc = projection.mergeTimelineItems(acc, ALL_COMPACT.slice(batches[b], batches[b + 1]), false);
  }
  eq('增量归并 == 全量快照（item id 序列逐字相同）', ids(acc), ids(compactSnapshot));
}

// 单条重复推送（同一组里又来一条）不许增殖
{
  let acc = projection.mergeTimelineItems([], ALL_COMPACT, true);
  const replay = compactItem({ seq: 2812, type: 'compaction/summary', cid: '7d8f32b7-6f42-4895-91a6-eab6089bc832' });
  acc = projection.mergeTimelineItems(acc, [replay], false);
  eq('同组再来一条不增殖', acc.length, 4);
}

// 安全边界 1：与 compaction 无关的 marker 绝不归并
{
  const m1 = item('mk-1', 100, 'marker', { content: { title: 'M1' }, text: '标记 1' });
  const m2 = item('mk-2', 101, 'marker', { content: { title: 'M1' }, text: '标记 1' });
  eq('普通 marker（无 compact 语义）保持逐条显示', projection.mergeTimelineItems([], [m1, m2], true).length, 2);
}

// 安全边界 2：孤立 prune（没有任何 compactionId）不许被吞掉
{
  const lone = compactItem({ seq: 900, type: 'compaction/prune' });
  eq('孤立 prune 自己成组、照常显示', projection.mergeTimelineItems([], [lone], true).length, 1);
  const lone2 = compactItem({ seq: 901, type: 'compaction/prune' });
  eq('连续无 id 的 prune 合成一组（仍可见）', projection.mergeTimelineItems([], [lone, lone2], true).length, 1);
}

// 安全边界 3（R80 裁决）：无 id 的 prune **优先向后**归入紧邻的组；后面没有组时并入前一个组
{
  const start = compactItem({ seq: 1000, type: 'compaction/start', cid: 'cid-x' });
  const prune = compactItem({ seq: 1001, type: 'compaction/prune' });
  const end = compactItem({ seq: 1002, type: 'compaction/end', cid: 'cid-x' });
  const out = projection.mergeTimelineItems([], [start, prune, end], true);
  eq('夹在组中间的 prune 不单独占一行', out.length, 1);
  eq('该组保留同一 compactionId', out[0].content.details.compactionId, 'cid-x');
}

// 安全边界 4（R80 裁决核心）：prune 簇紧贴在其服务的压缩 start 之前 ⇒ 必须**向后**归并
{
  const prunes = [compactItem({ seq: 100, type: 'compaction/prune' }), compactItem({ seq: 101, type: 'compaction/prune' })];
  const grp = [compactItem({ seq: 110, type: 'compaction/start', cid: 'cid-back' }),
    compactItem({ seq: 111, type: 'compaction/summary', cid: 'cid-back' }),
    compactItem({ seq: 112, type: 'compaction/end', cid: 'cid-back' })];
  const forward = projection.mergeTimelineItems([], prunes.concat(grp), true);
  eq('prune 簇向后并入紧随的压缩组（不再独占一行）', forward.length, 1);
  eq('向后归并后组身份仍是该压缩 id', forward[0].content.details.compactionId, 'cid-back');
  const backward = projection.mergeTimelineItems([], grp.concat([compactItem({ seq: 120, type: 'compaction/prune' })]), true);
  eq('后面没有组时并入前一个组', backward.length, 1);
  eq('向前归并后组身份不变', backward[0].content.details.compactionId, 'cid-back');
}
// ---------------------------------------------------------------------------
// ④ R42 硬约束守卫：view.messages() == projectTimeline(items) + 未回执乐观消息
// ---------------------------------------------------------------------------
group('④ R42 等价性：去重/归并必须在 items 层，视图逐项相等');
{
  const steps = [];
  // 一批混合更新：普通消息、压缩 marker、同源重复 item、回执 item
  steps.push([]);
  steps.push([item('h1', 1, 'message', { role: 'user', text: '历史一' }), item('h2', 2, 'message', { role: 'assistant', text: '答一' })]);
  steps.push(ALL_COMPACT.slice(0, 9));
  steps.push(ALL_COMPACT.slice(9, 18));
  steps.push(ALL_COMPACT.slice(18));
  steps.push([userItem('dup-1', 20)]);
  steps.push([userItem('dup-2', 20), item('h3', 21, 'message', { role: 'assistant', text: '答二' })]);
  steps.push([compactItem({ seq: 3000, type: 'compaction/prune' }), item('h4', 22, 'message', { role: 'assistant', text: '答三' })]);

  const view = new timelineView.TimelineMessageView();
  let items = [];
  let mismatch = '';
  view.setItems(items);
  view.addOptimistic(timelineView.buildOptimisticMessage(CM, '在途消息', [], '2026-09-24T00:00:00Z'));
  for (let s = 0; s < steps.length; s++) {
    items = projection.mergeTimelineItems(items, steps[s], false);
    view.setItems(items);
    const expected = projection.projectTimeline(items).concat(view.optimisticCount() > 0 ? [view.messages()[view.messages().length - 1]] : []);
    const actual = view.messages();
    if (JSON.stringify(actual) !== JSON.stringify(expected)) { mismatch = 'step ' + s; break; }
  }
  eq('混合序列下视图 == 全量投影 + 未回执乐观消息', mismatch, '');
  eq('回执到达后乐观消息被摘掉（dup-2 带 source.clientMessageId）', view.optimisticCount(), 0);
  const dupCount = projection.projectTimeline(projection.mergeTimelineItems([], [userItem('d1', 20), userItem('d2', 20)], true))
    .filter((m) => m.author === 'user' && m.body.indexOf('向上滑动时') >= 0).length;
  eq('同源重复 item 投影后只剩 1 条用户消息', dupCount, 1);
}

// ---------------------------------------------------------------------------
// ⑤ 端到端症状：真机现象不再复现
// ---------------------------------------------------------------------------
group('⑤ 端到端：真机两条症状');
{
  // 症状 1：App 发出消息（乐观）→ 服务端回执（source.clientMessageId）到达 ⇒ 只应剩 1 条同样的用户消息
  const view = new timelineView.TimelineMessageView();
  view.setItems([item('hist', 1, 'message', { role: 'assistant', text: '历史' })]);
  view.addOptimistic(timelineView.buildOptimisticMessage(CM, '1.向上滑动时，功能会被盖住。', [], '2026-09-24T00:00:00Z'));
  const beforeFix = view.messages().filter((m) => m.body.indexOf('向上滑动时') >= 0).length;
  view.setItems([item('hist', 1, 'message', { role: 'assistant', text: '历史' }), userItem('tl-user', 10)]);
  const afterFix = view.messages().filter((m) => m.body.indexOf('向上滑动时') >= 0).length;
  eq('回执前后「同一条用户消息」都是 1 份', beforeFix === 1 && afterFix === 1, true);
  // 症状 2：一次会话 24 条 compaction 记录 ⇒ 可见「上下文压缩」行数必须远小于 24
  const markerRows = projection.projectTimeline(projection.mergeTimelineItems([], ALL_COMPACT, true))
    .filter((m) => m.title === '上下文压缩').length;
  check('可见「上下文压缩」行数 < 10（原来 24）', markerRows < 10, 'got ' + markerRows);
  eq('可见「上下文压缩」行数 = 4（= 真实压缩次数）', markerRows, 4);
}

// ---------------------------------------------------------------------------
// ⑥ 结构闸门：**所有**写 items 的路径都必须走后处理（R80 真机复验抓到的漏点）
// ---------------------------------------------------------------------------
group('⑥ 结构闸门：items 写入点不许绕过 mergeTimelineItems');
{
  /**
   * `mergeTimelineItems` 的两道后处理写在函数**内部** ⇒ 只要有任何一处把服务端 items
   * 直接赋给 `this.items`，那条路径就完全不做归并 / 去重。
   *
   * 真机实测（R80 首版）：SessionDetailStore 的**全量快照**路径 `this.items = snapshot.timeline.items;`
   * 就是这么漏的 —— 进会话时「上下文压缩」仍是 **3 行**（同一次压缩的 start / summary / end 各一行），
   * 而增量路径已经归并成 1 行 ⇒ 两条路径结果不一致，肉眼可见。
   *
   * ⚠️ 本闸门是**源码结构**判据（不是纯逻辑），因为「有没有绕过」这件事只存在于调用点。
   */
  const storeRaw = fs.readFileSync(path.join(SRC_ETS, 'feature', 'SessionDetailStore.ets'), 'utf8');
  /**
   * ⚠️ 扫源码前**必须先剥注释**（本工作区既有坑：注释里的示例代码会被当成真代码）。
   * 本文件里那段「改前是这样写的」的说明就原样引用了被禁的写法 —— 不剥注释，闸门会自己红。
   */
  const store = storeRaw.split(String.fromCharCode(10)).map((line) => {
    const cut = line.indexOf('//');
    return cut >= 0 ? line.slice(0, cut) : line;
  }).join(String.fromCharCode(10));
  check('全量快照不再直通赋值给 this.items（R80 真机漏点回归闸门）',
    store.indexOf('this.items = snapshot.timeline.items') < 0, 'found direct assignment');
  check('全量快照走 replace 归并（与增量路径同一套后处理）',
    store.indexOf('this.items = mergeTimelineItems([], snapshot.timeline.items, true);') >= 0);
}

// ---------------------------------------------------------------------------

console.log('');
if (failures.length > 0) {
  console.log('失败 ' + failures.length + ' 项：');
  for (const f of failures) {
    console.log('  x ' + f);
  }
  console.log('suite-timeline-dup: ' + passed + ' 通过 / ' + failures.length + ' 失败');
  process.exit(1);
}
console.log('suite-timeline-dup: ' + passed + ' 条断言全绿。');
