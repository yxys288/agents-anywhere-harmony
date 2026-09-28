#!/usr/bin/env node
/**
 * aa-hm 工作台会话分页的纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 覆盖 task-2「工作台会话分页」里可离线判定的部分：
 *  首次加载写游标 → 加载更多推进游标 → 追加页去重 → WS 快照合并（保留已加载的后续页）
 *  → 越界 / 环游标 / 脏游标防御 → 失败保留游标可重试。
 *
 * 转译方式照抄 tools/logic-test/run-tests.mjs（DevEco 自带 TypeScript → CommonJS → Node 断言）。
 * 产物落在系统临时目录（不污染工程目录）。
 *
 * 用法：
 *   node tools\logic-test\suite-paging.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-paging');

/** 只挑不 import @kit / ArkUI 的模块。 */
const LOGIC_FILES = [
  'model/Types.ets',
  'model/AppModels.ets',
  'model/SessionPaging.ets',
  'model/ArchivedPaging.ets'
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

const paging = load('model/SessionPaging.js');
const archived = load('model/ArchivedPaging.js');

/** 造一条字段齐全的 AgentSession（排序只看 pinned/sortKey/updatedSeq）。 */
function sess(id, updatedSeq, extra = {}) {
  return {
    id: id,
    connectorId: 'conn-1',
    projectId: 'proj-1',
    deviceName: 'MacBook Pro',
    title: '会话 ' + id,
    summary: '',
    workspaceLabel: 'ws',
    runtime: 'codex',
    runtimeLabel: 'Codex',
    runtimeName: 'codex',
    status: 'idle',
    statusLabel: '空闲',
    updatedAtLabel: '刚刚',
    metaLabel: 'Codex',
    pinned: false,
    archived: false,
    unread: false,
    lastReadSeq: 0,
    takeover: false,
    connectorOnline: true,
    live: false,
    sortKey: '2026-09-15T00:00:00Z',
    updatedSeq: updatedSeq,
    indicator: 'none',
    ...extra
  };
}

function ids(list) {
  return list.map((item) => item.id).join(',');
}

// ---------------------------------------------------------------------------
// 1. 首次加载（refreshAll 拿到首页）
// ---------------------------------------------------------------------------

group('首次加载：写游标 + 记首页 id');
const firstPage = [sess('s1', 10), sess('s2', 9), sess('s3', 8)];
const fresh = paging.applyFirstPage(paging.emptyPagingState(), false, true, 'offset:100', firstPage);
eq('首页后 hasMore 为真', fresh.active.hasMore, true);
eq('首页后游标写入', fresh.active.nextCursor, 'offset:100');
eq('首页后不在加载态', fresh.active.loading, false);
eq('首页后错误清空', fresh.active.error, '');
eq('首页 id 集合记录正确', fresh.active.firstPageIds.join(','), 's1,s2,s3');
eq('另一侧不受影响', fresh.archived.hasMore, false);
check('首页后可加载更多', paging.canLoadMore(fresh, false) === true);
check('底部入口应显示', paging.shouldShowLoadMore(fresh, false) === true);
const noMore = paging.applyFirstPage(paging.emptyPagingState(), true, false, 'offset:100', firstPage);
eq('没有更多时 hasMore 为假', noMore.archived.hasMore, false);
eq('没有更多时游标清空（即便服务端给了）', noMore.archived.nextCursor, '');
check('没有更多时不显示入口', paging.shouldShowLoadMore(noMore, true) === false);
check('不可加载时 beginLoadMore 原样返回', paging.beginLoadMore(noMore, true) === noMore);
check('applyFirstPage 不可变（原状态未被改写）', fresh.active.hasMore === true && paging.emptyPagingState().active.firstPageIds.length === 0);

// ---------------------------------------------------------------------------
// 2. 加载更多：进入加载态 → 追加 → 推进游标
// ---------------------------------------------------------------------------

group('加载更多：加载态与游标推进');
const loading = paging.beginLoadMore(fresh, false);
eq('进入加载态 loading=true', loading.active.loading, true);
eq('加载中不清游标', loading.active.nextCursor, 'offset:100');
check('加载中不可重复触发', paging.canLoadMore(loading, false) === false);
const page2 = [sess('s4', 7), sess('s5', 6)];
const afterMore = paging.applyMorePage(loading, false, 'offset:100', true, 'offset:200');
eq('追加后退出加载态', afterMore.active.loading, false);
eq('追加后游标推进', afterMore.active.nextCursor, 'offset:200');
eq('追加后仍可继续加载', afterMore.active.hasMore, true);
check('追加后可加载更多', paging.canLoadMore(afterMore, false) === true);
eq('追加不改首页 id 集合', afterMore.active.firstPageIds.join(','), 's1,s2,s3');
const merged = paging.mergeSessionLists(firstPage, page2);
eq('追加页合并后 5 条', merged.length, 5);
eq('合并结果按 updatedSeq 倒序', ids(merged), 's1,s2,s3,s4,s5');
eq('空页合并保持原样', paging.mergeSessionLists(merged, []).length, 5);
// R38：合并结果与 current 逐项渲染相同时**保留原引用**（差分更新的核心，消除刷新闪烁）；
// 「内容真的变了 ⇒ 换新引用」这一相反情形由 R38 组的断言覆盖。
check('合并结果与 current 相同时返回原引用（R38 差分）', paging.mergeSessionLists(merged, []) === merged);

// ---------------------------------------------------------------------------
// 3. 去重：重复页 / 旧数据 / 同 id 取 updatedSeq 大者
// ---------------------------------------------------------------------------

group('去重：重复页与字节回流');
eq('整页重复不新增', paging.mergeSessionLists(firstPage, firstPage).length, 3);
const newerDup = sess('s2', 99, { title: '会话 s2（新标题）' });
const deduped = paging.mergeSessionLists(firstPage, [newerDup, sess('s6', 5)]);
eq('重复页带新数据时条数正确', deduped.length, 4);
eq('同 id 以 updatedSeq 大者为准', (deduped.filter((item) => item.id === 's2')[0] || {}).title, '会话 s2（新标题）');
const staleDup = sess('s2', 1, { title: '会话 s2（旧数据）' });
const kept = paging.mergeSessionLists(firstPage, [staleDup]);
eq('同 id 的旧数据不覆盖新数据', (kept.filter((item) => item.id === 's2')[0] || {}).title, '会话 s2');
eq('同 id 重复不新增行', kept.length, 3);

// ---------------------------------------------------------------------------
// 4. WS 全量快照合并：覆盖首页、保留已加载的后续页
// ---------------------------------------------------------------------------

group('WS 快照合并：覆盖首页 + 保留后续页');
const local = paging.mergeSessionLists(firstPage, page2);
const snapshotFirst = [sess('s1', 11, { title: '会话 s1（快照）' }), sess('s2', 9), sess('s3', 8)];
const snapshotIds = snapshotFirst.map((item) => item.id);
const keptAll = paging.mergeWithSnapshot(local, snapshotFirst, snapshotIds);
eq('快照覆盖后仍保留已加载的后续页', ids(keptAll), 's1,s2,s3,s4,s5');
eq('快照里的会话以快照为准', (keptAll.filter((item) => item.id === 's1')[0] || {}).title, '会话 s1（快照）');
const localNewer = [sess('s1', 50, { title: '会话 s1（本地更新）' }), sess('s2', 9), sess('s3', 8)];
const keptNewer = paging.mergeWithSnapshot(localNewer, [sess('s1', 11, { title: '会话 s1（快照旧）' })], ['s1']);
eq('本地 updatedSeq 更大时保留本地', (keptNewer.filter((item) => item.id === 's1')[0] || {}).title, '会话 s1（本地更新）');
const shrunk = paging.mergeWithSnapshot(local, [sess('s1', 11)], ['s1', 's2', 's3']);
eq('快照覆盖过的 id 里被删掉的会话要丢弃', ids(shrunk), 's1,s4,s5');
const emptySnapshot = paging.mergeWithSnapshot(local, [], []);
eq('空快照（未覆盖任何 id）不动本地列表', ids(emptySnapshot), 's1,s2,s3,s4,s5');

// ---------------------------------------------------------------------------
// 5. 快照的分页信息：权威但「不放走」已翻过的页
// ---------------------------------------------------------------------------

group('快照 sessionPages：只在必要时保留本地游标');
const afterSnapKept = paging.applySnapshotPage(
  afterMore, false, false, null, snapshotFirst, 2);
eq('快照说没有更多但本地还有后续页 → 保留本地游标', afterSnapKept.active.nextCursor, 'offset:200');
eq('保留游标时 hasMore 仍为真', afterSnapKept.active.hasMore, true);
eq('firstPageIds 换成快照里的 id', afterSnapKept.active.firstPageIds.join(','), 's1,s2,s3');
const afterSnapFull = paging.applySnapshotPage(afterMore, false, false, null, snapshotFirst, 0);
eq('本地没有后续页 → 采用快照（没有更多）', afterSnapFull.active.hasMore, false);
eq('本地没有后续页 → 游标清空', afterSnapFull.active.nextCursor, '');
const afterSnapMore = paging.applySnapshotPage(fresh, false, true, 'cursor-xyz', snapshotFirst, 0);
eq('快照给出更多 → 采用快照游标', afterSnapMore.active.nextCursor, 'cursor-xyz');
eq('快照加载态不被覆盖（进行中的请求不受影响）', paging.applySnapshotPage(loading, false, false, null, snapshotFirst, 0).active.loading, true);

// ---------------------------------------------------------------------------
// 6. 越界 / 环 / 脏游标防御
// ---------------------------------------------------------------------------

group('越界、环游标与脏游标');
const outOfRange = paging.applyMorePage(paging.beginLoadMore(afterMore, false), false, 'offset:200', false, null);
eq('越界游标（空页 + hasMore=false）→ 停止', outOfRange.active.hasMore, false);
eq('越界后游标清空', outOfRange.active.nextCursor, '');
eq('越界后列表不变', paging.mergeSessionLists(merged, []).length, 5);
check('越界后不再显示入口', paging.shouldShowLoadMore(outOfRange, false) === false);
const loop = paging.applyMorePage(paging.beginLoadMore(afterMore, false), false, 'offset:200', true, 'offset:200');
eq('服务端原地打转 → 停止（防无限加载）', loop.active.hasMore, false);
const dirty = paging.applyMorePage(paging.beginLoadMore(afterMore, false), false, 'offset:200', true, '');
eq('hasMore 为真但游标为空 → 停止', dirty.active.hasMore, false);
check('脏数据下不显示入口', paging.shouldShowLoadMore(dirty, false) === false);

// ---------------------------------------------------------------------------
// 7. 失败与重试
// ---------------------------------------------------------------------------

group('加载更多失败：保留游标，可重试');
const failed = paging.failLoadMore(paging.beginLoadMore(afterMore, false), false, '网络不可达');
eq('失败后退出加载态', failed.active.loading, false);
eq('失败后错误可见', failed.active.error, '网络不可达');
eq('失败后游标保留（下次用同一游标重试）', failed.active.nextCursor, 'offset:200');
eq('失败后 hasMore 保留', failed.active.hasMore, true);
check('失败后仍可重试', paging.canLoadMore(failed, false) === true);
check('失败后按钮变「重试」', paging.canRetryLoadMore(failed, false) === true);
check('失败后入口仍显示', paging.shouldShowLoadMore(failed, false) === true);
const retried = paging.applyMorePage(paging.beginLoadMore(failed, false), false, 'offset:200', true, 'offset:300');
eq('重试成功后清错误', retried.active.error, '');
eq('重试成功后游标推进到第三页', retried.active.nextCursor, 'offset:300');
check('重试成功后不再显示「重试」', paging.canRetryLoadMore(retried, false) === false);
const archivedFailed = paging.failLoadMore(paging.emptyPagingState(), true, '归档侧失败');
eq('归档侧错误独立记录', archivedFailed.archived.error, '归档侧失败');
eq('归档侧失败不影响进行中侧', archivedFailed.active.error, '');

// ---------------------------------------------------------------------------
// 8. 已归档页：归档时间兜底（§J.1.2 易错点 1）
// ---------------------------------------------------------------------------

group('已归档页：归档时间 archivedAt ?: sortKey + 解析失败兜底');
eq('archivedAt 优先', archived.archivedTimeSource('2026-09-10T00:00:00Z', '2026-09-14T00:00:00Z'), '2026-09-10T00:00:00Z');
eq('archivedAt 为空串 → 回退 sortKey', archived.archivedTimeSource('', '2026-09-14T00:00:00Z'), '2026-09-14T00:00:00Z');
eq('archivedAt 为 undefined → 回退 sortKey', archived.archivedTimeSource(undefined, '2026-09-14T00:00:00Z'), '2026-09-14T00:00:00Z');
eq('archivedAt 全空白 → 回退 sortKey', archived.archivedTimeSource('   ', '2026-09-14T00:00:00Z'), '2026-09-14T00:00:00Z');
eq('两边都空 → 空串（调用方走兜底文案）', archived.archivedTimeSource(undefined, ''), '');
check('合法 ISO 可解析', archived.archivedTimeParsable('2026-09-14T00:00:00Z') === true);
check('空串不可解析', archived.archivedTimeParsable('') === false);
check('乱码不可解析', archived.archivedTimeParsable('???') === false);
// R20：由「相对时间」改为上游的**绝对时间** —— `yyyy-MM-dd HH:mm` + 「归档于 」前缀
// （`ArchivedSessionsScreen.kt:57` 的 `DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")`、
//  `archive_archived_at`「归档于 %1$s」、`archived_time_unavailable`「暂无时间」）。
// ⚠️ 断言用**本地时间构造**的 ISO，避免依赖运行环境的时区。
const localIso = new Date(2026, 8, 14, 9, 5).toISOString();
eq('格式化成 yyyy-MM-dd HH:mm', archived.formatArchiveTimestamp(localIso), '2026-09-14 09:05');
eq('个位数的月/日/时/分补零',
  archived.formatArchiveTimestamp(new Date(2026, 0, 3, 7, 8).toISOString()), '2026-01-03 07:08');
eq('午夜是 00:00 而不是空',
  archived.formatArchiveTimestamp(new Date(2026, 11, 31, 0, 0).toISOString()), '2026-12-31 00:00');
eq('不可解析 → 空串（调用方走兜底）', archived.formatArchiveTimestamp('???'), '');
eq('空串 → 空串', archived.formatArchiveTimestamp(''), '');
eq('标签带「归档于 」前缀', archived.archivedTimeLabel(localIso, ''), '归档于 2026-09-14 09:05');
eq('archivedAt 优先于 sortKey',
  archived.archivedTimeLabel(localIso, new Date(2020, 0, 1).toISOString()), '归档于 2026-09-14 09:05');
eq('archivedAt 缺失 → 回落 sortKey', archived.archivedTimeLabel(undefined, localIso), '归档于 2026-09-14 09:05');
eq('archivedAt 为空串 → 回落 sortKey', archived.archivedTimeLabel('', localIso), '归档于 2026-09-14 09:05');
eq('两边都不可解析 → 兜底文案', archived.archivedTimeLabel('???', '???'), archived.ARCHIVED_TIME_FALLBACK);
eq('两个字段都空 → 兜底文案', archived.archivedTimeLabel(undefined, ''), archived.ARCHIVED_TIME_FALLBACK);
eq('兜底文案逐字等于上游 archived_time_unavailable', archived.ARCHIVED_TIME_FALLBACK, '暂无时间');
check('标签里不再出现相对时间单位（1w / 5h / now）',
  archived.archivedTimeLabel(localIso, '').indexOf('w') < 0
  && archived.archivedTimeLabel(localIso, '').indexOf('h') < 0
  && archived.archivedTimeLabel(localIso, '').indexOf('now') < 0);

// ---------------------------------------------------------------------------
// 9. 已归档页：状态分派（§J.1.1 的五分支 when）
// ---------------------------------------------------------------------------

group('已归档页：五状态分派（list → loading → error → more → empty）');
const stateOf = (input) => archived.archivedStateOf({
  groupCount: 0, loading: false, errorText: '', hasMore: false, filtered: false, ...input
});
eq('有分组 → list', stateOf({ groupCount: 2 }).kind, 'list');
check('list 形态三个文案都为空', stateOf({ groupCount: 1 }).title === '' && stateOf({ groupCount: 1 }).description === '' && stateOf({ groupCount: 1 }).actionLabel === '');
eq('空 + 加载中 → loading', stateOf({ loading: true }).kind, 'loading');
check('加载中优先于错误', stateOf({ loading: true, errorText: 'boom' }).kind === 'loading');
eq('空 + 有错 → error', stateOf({ errorText: 'boom' }).kind, 'error');
eq('error 给「重试」', stateOf({ errorText: 'boom' }).actionLabel, '重试');
eq('空 + hasMore → more（独立状态）', stateOf({ hasMore: true }).kind, 'more');
eq('more 的标题', stateOf({ hasMore: true }).title, '当前没有可显示的会话');
eq('more 给「加载更多」（上游 archived_load_more）', stateOf({ hasMore: true }).actionLabel, '加载更多');
eq('more 的说明（上游 archive_more_hint）', stateOf({ hasMore: true }).description, '继续加载，查看更早的归档会话。');
check('更多优先于真空', stateOf({ hasMore: true }).kind !== 'empty');
// ⚠️ R21：以下四条曾经是本工程的自由发挥（「尚未归档」等），现按上游逐字对齐。
eq('真空（未筛选）→ 暂无已归档会话（上游 archived_empty）', stateOf({}).title, '暂无已归档会话');
eq('真空（已筛选项目）→ 这个项目还没有归档会话（上游 archive_project_empty）',
  stateOf({ filtered: true }).title, '这个项目还没有归档会话');
check('真空不给动作按钮', stateOf({}).actionLabel === '');
// 上游 `ArchivedSessionsScreen.kt:149-152` 的真空分支**只传 title** ⇒ 没有副文，页面据此不渲染那一行。
eq('真空（未筛选）没有副文', stateOf({}).description, '');
eq('真空（已筛选）也没有副文', stateOf({ filtered: true }).description, '');
// 其余两组也逐字对齐上游（修前是「加载失败」「正在加载已归档会话…」…）。
eq('loading 文案（上游 archive_loading）', stateOf({ loading: true }).title, '正在加载归档会话…');
eq('error 标题（上游 archive_load_failed）', stateOf({ errorText: 'boom' }).title, '暂时无法加载归档会话');
eq('error 说明（上游 archive_retry_hint）', stateOf({ errorText: 'boom' }).description, '检查网络连接后再试一次。');
// ⚠️ 注意别把**上游文案**当禁忌词：上游 `archived_empty` 本身就是「暂无已归档会话」。
// 这里只拦本工程修前的自造词。
const allStates = [stateOf({ loading: true }), stateOf({ errorText: 'x' }), stateOf({ hasMore: true }), stateOf({}), stateOf({ filtered: true })];
check('修前的自造词已全部消失（尚未归档 / 该项目尚未归档 / 还没有已归档的会话 / 加载失败）',
  allStates.every((s) => s.title.indexOf('尚未归档') < 0
    && s.title.indexOf('加载失败') < 0
    && s.description.indexOf('还没有已归档的会话') < 0
    && s.description.indexOf('请检查网络或服务器地址') < 0));

// ---------------------------------------------------------------------------

console.log('');
console.log('通过 ' + passed + ' 项，失败 ' + failures.length + ' 项');
if (failures.length > 0) {
  console.log('');
  console.log('失败明细：');
  for (const item of failures) {
    console.log('  x ' + item);
  }
  process.exit(1);
}
console.log('全部分页逻辑断言通过。');
