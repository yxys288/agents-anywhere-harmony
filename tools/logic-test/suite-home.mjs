#!/usr/bin/env node
/**
 * aa-hm 首页「项目视图」的纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 覆盖第九轮 task-8（首页结构对齐安卓端）里可离线判定的部分：
 *  筛选档归一化 → 会话归属筛选（置顶单列语义）→ 会话排序（运行中在前）
 *  → 项目活动度排序（空项目沉底）→ 项目行组装（置顶/普通分组、展开态、会话数）
 *  → 展开集合的增删/裁剪/序列化往返 → 设备名回填。
 *
 * 转译方式照抄 tools/logic-test/run-tests.mjs（DevEco 自带 TypeScript → CommonJS → Node 断言）。
 * 产物落在系统临时目录（不污染工程目录）。
 *
 * 用法：
 *   node tools\logic-test\suite-home.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-home');

/** 只挑不 import @kit / ArkUI 的模块。 */
/**
 * 只挑不 import @kit / ArkUI 的模块。
 *
 * ⚠️ `ui/Router.ets` 只依赖全局 `AppStorage`（Node 侧在 require 之前注入一个 Map 版 stub），
 * 所以它能进这个清单 —— R11 的「14 个目的地 + 返回语义」正好可以在这里断言。
 */
const LOGIC_FILES = [
  'ui/Router.ets',
  'model/Types.ets',
  'model/AppModels.ets',
  'model/HomeGrouping.ets'
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

// `ui/Router.ets` 用 `AppStorage.get` / `AppStorage.setOrCreate`（ArkUI 全局对象）：注入 Map 版 stub。
const fakeStorage = new Map();
globalThis.AppStorage = {
  get: (key) => fakeStorage.get(key),
  setOrCreate: (key, value) => {
    fakeStorage.set(key, value);
  }
};

const require = createRequire(import.meta.url);
const load = (rel) => require(path.join(OUT_DIR, rel));

const grouping = load('model/HomeGrouping.js');
const F = grouping.ProjectSessionFilter;
const router = load('ui/Router.js');
const Route = router.Route;
const Router = router.Router;

// ---------------------------------------------------------------------------
// 夹具：字段齐全的 AgentProject / AgentSession
// ---------------------------------------------------------------------------

function proj(id, extra = {}) {
  return {
    id: id,
    userId: 'u1',
    connectorId: 'conn-1',
    name: '项目 ' + id,
    workspacePath: '/home/me/' + id,
    pinned: false,
    activeSessionCount: 0,
    createdAt: '2026-09-01T00:00:00Z',
    updatedAt: '2026-09-01T00:00:00Z',
    manuallyCreated: false,
    ...extra
  };
}

function sess(id, extra = {}) {
  return {
    id: id,
    connectorId: 'conn-1',
    projectId: 'p1',
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
    updatedSeq: 0,
    indicator: 'none',
    ...extra
  };
}

function ids(list) {
  return list.map((item) => item.id).join(',');
}

// ---------------------------------------------------------------------------
// 1. 筛选档归一化与标签
// ---------------------------------------------------------------------------

group('筛选档：归一化与标签（对齐上游 ProjectSessionStatusFilter）');
eq('archived 保真', grouping.normalizeProjectSessionFilter('archived'), 'archived');
eq('all 保真', grouping.normalizeProjectSessionFilter('all'), 'all');
eq('空串回落到 active', grouping.normalizeProjectSessionFilter(''), 'active');
eq('脏值回落到 active', grouping.normalizeProjectSessionFilter('bogus'), 'active');
eq('active 标签', grouping.projectSessionFilterLabel(F.ACTIVE), '活跃会话');
eq('archived 标签', grouping.projectSessionFilterLabel(F.ARCHIVED), '已归档');
eq('all 标签', grouping.projectSessionFilterLabel(F.ALL), '全部');
eq('分页侧：活跃档走活跃侧', grouping.pagingSideIsArchived(F.ACTIVE), false);
eq('分页侧：归档档走归档侧', grouping.pagingSideIsArchived(F.ARCHIVED), true);
eq('分页侧：全部档仍走活跃侧', grouping.pagingSideIsArchived(F.ALL), false);

// ---------------------------------------------------------------------------
// 2. 时间解析
// ---------------------------------------------------------------------------

group('时间解析：缺失 / 非法一律 0（对齐上游 timestampMillis）');
eq('undefined → 0', grouping.parseTimestampMillis(undefined), 0);
eq('空串 → 0', grouping.parseTimestampMillis(''), 0);
eq('非法串 → 0', grouping.parseTimestampMillis('not-a-date'), 0);
check('合法 ISO 解析为正数', grouping.parseTimestampMillis('2026-09-15T00:00:00Z') > 0,
  String(grouping.parseTimestampMillis('2026-09-15T00:00:00Z')));
check('后一天更大',
  grouping.parseTimestampMillis('2026-09-16T00:00:00Z') > grouping.parseTimestampMillis('2026-09-15T00:00:00Z'));

// ---------------------------------------------------------------------------
// 3. 会话归属筛选（置顶单列语义）
// ---------------------------------------------------------------------------

group('会话筛选：active 排除置顶与归档（置顶会话在顶部单列）');
const plain = sess('s-plain');
const pinnedSess = sess('s-pinned', { pinned: true });
const archivedSess = sess('s-archived', { archived: true });
const archivedPinned = sess('s-archived-pinned', { archived: true, pinned: true });
eq('active 收普通会话', grouping.sessionMatchesProjectFilter(plain, F.ACTIVE), true);
eq('active 排除置顶会话', grouping.sessionMatchesProjectFilter(pinnedSess, F.ACTIVE), false);
eq('active 排除归档会话', grouping.sessionMatchesProjectFilter(archivedSess, F.ACTIVE), false);
eq('archived 只收归档会话', grouping.sessionMatchesProjectFilter(archivedSess, F.ARCHIVED), true);
eq('archived 排除活跃会话', grouping.sessionMatchesProjectFilter(plain, F.ARCHIVED), false);
eq('all 收归档会话', grouping.sessionMatchesProjectFilter(archivedSess, F.ALL), true);
eq('all 收普通会话', grouping.sessionMatchesProjectFilter(plain, F.ALL), true);
eq('all 仍排除置顶会话（不重复出现）', grouping.sessionMatchesProjectFilter(pinnedSess, F.ALL), false);
eq('all 收归档且置顶的会话', grouping.sessionMatchesProjectFilter(archivedPinned, F.ALL), true);

// ---------------------------------------------------------------------------
// 4. 会话排序
// ---------------------------------------------------------------------------

group('会话排序：置顶 → 运行中 → 最近活动 → id');
const slow = sess('s-slow', { sortKey: '2026-09-10T00:00:00Z' });
const fresh = sess('s-fresh', { sortKey: '2026-09-20T00:00:00Z' });
const running = sess('s-running', { status: 'running', sortKey: '2026-09-01T00:00:00Z' });
const runningB = sess('s-running-b', { status: 'running', sortKey: '2026-09-01T00:00:00Z' });
const pinnedFirst = sess('s-top', { pinned: true, sortKey: '2026-09-01T00:00:00Z' });
eq('运行中排在空闲之前',
  ids(grouping.sortSessionsForProject([slow, running])), 's-running,s-slow');
eq('两个运行中按 id 升序',
  ids(grouping.sortSessionsForProject([runningB, running])), 's-running,s-running-b');
eq('空闲按最近活动倒序',
  ids(grouping.sortSessionsForProject([slow, fresh])), 's-fresh,s-slow');
eq('置顶排在运行中之前',
  ids(grouping.sortSessionsForProject([running, pinnedFirst])), 's-top,s-running');
const sortInput = [slow, fresh];
grouping.sortSessionsForProject(sortInput);
eq('排序不改入参数组', ids(sortInput), 's-slow,s-fresh');

// ---------------------------------------------------------------------------
// 5. 按项目取会话 / 分组
// ---------------------------------------------------------------------------

group('按项目取会话与分组');
const p1a = sess('p1-a', { projectId: 'p1' });
const p1b = sess('p1-b', { projectId: 'p1', sortKey: '2026-09-19T00:00:00Z' });
const p2a = sess('p2-a', { projectId: 'p2' });
const orphan = sess('orphan', { projectId: undefined });
eq('只取该项目的会话', grouping.sessionsOfProject([p1a, p2a, p1b], 'p1', F.ACTIVE).length, 2);
eq('项目内会话有序', ids(grouping.sessionsOfProject([p1a, p2a, p1b], 'p1', F.ACTIVE)), 'p1-b,p1-a');
eq('未绑项目的会话不计入任何项目', grouping.sessionsOfProject([orphan], 'p1', F.ACTIVE).length, 0);
eq('空 projectId 直接返回空', grouping.sessionsOfProject([p1a], '', F.ACTIVE).length, 0);
const buckets = grouping.visibleSessionsByProject([p1a, p1b, p2a, orphan], F.ACTIVE);
eq('分组项目数', buckets.size, 2);
eq('p1 分组内会话数', buckets.get('p1').length, 2);
eq('p2 分组内会话数', buckets.get('p2').length, 1);
eq('未绑项目的会话不进分组', buckets.get(undefined) === undefined, true);
eq('归档档下分组为空', grouping.visibleSessionsByProject([p1a, p1b], F.ARCHIVED).size, 0);
eq('归档档下能拿到归档会话',
  grouping.visibleSessionsByProject([p1a, sess('p1-z', { projectId: 'p1', archived: true })], F.ARCHIVED).get('p1').length, 1);

// ---------------------------------------------------------------------------
// 6. 项目可见性与空项目
// ---------------------------------------------------------------------------

group('项目可见性与「空项目」判定');
eq('手动创建的项目恒可见（即便还没会话）',
  grouping.projectHasVisibleSessions(proj('p9', { manuallyCreated: true }), [], F.ACTIVE), true);
eq('自动采集且无会话的项目不可见',
  grouping.projectHasVisibleSessions(proj('p9'), [], F.ACTIVE), false);
eq('自动采集且有会话则可见',
  grouping.projectHasVisibleSessions(proj('p1'), [p1a], F.ACTIVE), true);
eq('活跃档下只有归档会话的项目不可见',
  grouping.projectHasVisibleSessions(proj('p1'), [sess('z', { projectId: 'p1', archived: true })], F.ACTIVE), false);
eq('空项目判定：手动 + 无会话 + 无活动 → true', grouping.isBlankProject(proj('p9', { manuallyCreated: true }), []), true);
eq('空项目判定：有活动时间 → false',
  grouping.isBlankProject(proj('p9', { manuallyCreated: true, lastActivityAt: '2026-09-18T00:00:00Z' }), []), false);
eq('空项目判定：有会话 → false',
  grouping.isBlankProject(proj('p9', { manuallyCreated: true }), [sess('s', { projectId: 'p9' })]), false);
eq('空项目判定：非手动 → false', grouping.isBlankProject(proj('p9'), []), false);
eq('空项目判定：服务端会话计数 > 0 → false',
  grouping.isBlankProject(proj('p9', { manuallyCreated: true, activeSessionCount: 3 }), []), false);

// ---------------------------------------------------------------------------
// 7. 项目排序
// ---------------------------------------------------------------------------

group('项目排序：非空在前 → 最近活动倒序 → 创建时间 → 名称');
const oldProj = proj('p-old', { lastActivityAt: '2026-09-01T00:00:00Z' });
const newProj = proj('p-new', { lastActivityAt: '2026-09-20T00:00:00Z' });
const blankProj = proj('p-blank', { manuallyCreated: true });
eq('空项目沉底', ids(grouping.sortProjectsByActivity([blankProj, oldProj, newProj], [])), 'p-new,p-old,p-blank');
eq('会话活动能顶起项目',
  ids(grouping.sortProjectsByActivity(
    [proj('p-a', { lastActivityAt: '2026-09-02T00:00:00Z' }), proj('p-b', { lastActivityAt: '2026-09-03T00:00:00Z' })],
    [sess('x', { projectId: 'p-a', sortKey: '2026-09-25T00:00:00Z' })])),
  'p-a,p-b');
eq('同活动时间按创建时间倒序',
  ids(grouping.sortProjectsByActivity([
    proj('p-x', { createdAt: '2026-09-01T00:00:00Z' }),
    proj('p-y', { createdAt: '2026-09-10T00:00:00Z' })
  ], [])), 'p-y,p-x');
eq('同创建时间按名称',
  ids(grouping.sortProjectsByActivity([
    proj('p-b', { name: 'Beta' }),
    proj('p-a', { name: 'Alpha' })
  ], [])), 'p-a,p-b');

// ---------------------------------------------------------------------------
// 8. 项目行组装
// ---------------------------------------------------------------------------

group('项目行组装：置顶/普通分组 + 会话数 + 展开态');
const projects = [
  proj('p1', { lastActivityAt: '2026-09-20T00:00:00Z', name: '工作区' }),
  proj('p2', { pinned: true, lastActivityAt: '2026-09-10T00:00:00Z', name: '置顶项目' }),
  proj('p3', { manuallyCreated: true, name: '空项目' })
];
const sessions = [
  sess('a1', { projectId: 'p1', sortKey: '2026-09-18T00:00:00Z' }),
  sess('a2', { projectId: 'p1', sortKey: '2026-09-17T00:00:00Z' }),
  sess('b1', { projectId: 'p2', sortKey: '2026-09-16T00:00:00Z' }),
  sess('pin', { projectId: 'p1', pinned: true })
];
const rows = grouping.buildProjectRows(projects, sessions, F.ACTIVE, ['p2']);
eq('可见项目总数', rows.visibleCount, 3);
eq('置顶区项目数', rows.pinned.length, 1);
eq('置顶区项目 id', rows.pinned[0].projectId, 'p2');
eq('普通区项目数', rows.regular.length, 2);
eq('普通区首个 = 活动最新的普通项目', rows.regular[0].projectId, 'p1');
eq('空项目排在普通区末尾', rows.regular[1].projectId, 'p3');
eq('p1 会话数（不含置顶会话）', rows.regular[0].sessionCount, 2);
// R38：第 4 个参数语义反转为「手动折叠集合」。原来传 ['p1'] 是「展开 p1」，现在传 ['p2'] 才是同一场景。
eq('p1 展开态被识别（p2 被手动折叠，p1 不在折叠集合里）', rows.regular[0].expanded, true);
eq('被手动折叠的项目为收起（p2 在折叠集合里）', rows.pinned[0].expanded, false);
eq('p1 行内会话有序', ids(rows.regular[0].sessions), 'a1,a2');
eq('空项目会话数为 0', rows.regular[1].sessionCount, 0);
eq('项目名透传', rows.regular[0].name, '工作区');
eq('工作区路径透传', rows.regular[0].workspacePath, '/home/me/p1');
const archivedRows = grouping.buildProjectRows(projects, sessions, F.ARCHIVED, []);
eq('归档档下只剩手动创建的空项目', archivedRows.visibleCount, 1);
eq('归档档下项目为手动创建的那个', archivedRows.regular[0].projectId, 'p3');
const allRows = grouping.buildProjectRows(projects, sessions, F.ALL, []);
eq('全部档下 p1 会话数仍不含置顶会话', allRows.regular[0].sessionCount, 2);

// ---------------------------------------------------------------------------
// 9. 置顶区
// ---------------------------------------------------------------------------

group('顶部「置顶」区');
eq('置顶区只含置顶且未归档',
  ids(grouping.pinnedSessionsOf([pinnedSess, plain, archivedPinned], F.ACTIVE)), 's-pinned');
eq('归档档下置顶区为空', grouping.pinnedSessionsOf([pinnedSess], F.ARCHIVED).length, 0);
eq('全部档下置顶区仍列出置顶会话', grouping.pinnedSessionsOf([pinnedSess], F.ALL).length, 1);
eq('项目行会话数与置顶区不重叠',
  grouping.sessionsOfProject([plain, pinnedSess], 'p1', F.ACTIVE).length, 1);

// ---------------------------------------------------------------------------
// 8.5 「最近」区（会话视图）
// ---------------------------------------------------------------------------

group('会话视图的「最近」区：当前档下非置顶会话');
eq('活跃档下排除置顶会话',
  ids(grouping.recentSessionsOf([plain, pinnedSess], F.ACTIVE)), 's-plain');
eq('活跃档下排除归档会话',
  ids(grouping.recentSessionsOf([plain, archivedSess], F.ACTIVE)), 's-plain');
eq('全部档下收活跃会话与归档会话',
  ids(grouping.recentSessionsOf([plain, archivedSess], F.ALL)), 's-plain,s-archived');
eq('全部档下仍排除置顶会话',
  ids(grouping.recentSessionsOf([plain, pinnedSess, archivedSess], F.ALL)).indexOf('s-pinned'), -1);
eq('归档档下只剩归档的非置顶会话',
  ids(grouping.recentSessionsOf([plain, archivedSess, archivedPinned], F.ARCHIVED)), 's-archived');
eq('置顶区与最近区不重叠',
  grouping.pinnedSessionsOf([plain, pinnedSess], F.ACTIVE).length
    + grouping.recentSessionsOf([plain, pinnedSess], F.ACTIVE).length, 2);
eq('最近区有序（运行中在前）',
  ids(grouping.recentSessionsOf([slow, running], F.ACTIVE)), 's-running,s-slow');

// ---------------------------------------------------------------------------
// 9.5 活跃 / 归档两侧合并去重
// ---------------------------------------------------------------------------

group('两侧会话合并：按 id 去重、活跃侧优先');
const dupActive = sess('dup', { title: '活跃侧那条' });
const dupArchived = sess('dup', { title: '归档侧那条', archived: true });
const merged = grouping.mergeSessionsById([dupActive, p1a], [dupArchived, sess('only-arch', { archived: true })]);
eq('合并后总条数', merged.length, 3);
eq('同 id 时保留活跃侧那份', merged[0].title, '活跃侧那条');
eq('归档侧独有仍保留', ids(merged), 'dup,p1-a,only-arch');
eq('一侧为空时原样返回', grouping.mergeSessionsById([], [dupArchived]).length, 1);

// ---------------------------------------------------------------------------
// 10. 展开集合与文案
// ---------------------------------------------------------------------------

group('展开集合的增删 / 裁剪 / 持久化往返');
eq('新增展开项', grouping.toggleExpandedId([], 'p1', true).join(','), 'p1');
eq('重复展开不重复入列', grouping.toggleExpandedId(['p1'], 'p1', true).join(','), 'p1');
eq('收起移除', grouping.toggleExpandedId(['p1', 'p2'], 'p1', false).join(','), 'p2');
eq('收起不存在的项无副作用', grouping.toggleExpandedId(['p2'], 'p1', false).join(','), 'p2');
const before = ['p1'];
grouping.toggleExpandedId(before, 'p2', true);
eq('toggle 不改入参数组', before.join(','), 'p1');
eq('裁剪掉已删除的项目', grouping.pruneExpandedIds(['p1', 'gone', 'p2'], projects).join(','), 'p1,p2');
eq('空集合裁剪仍为空', grouping.pruneExpandedIds([], projects).length, 0);
eq('解析：去空项', grouping.parseExpandedIds('p1,,p2,').join(','), 'p1,p2');
eq('解析：去重', grouping.parseExpandedIds('p1,p1,p2').join(','), 'p1,p2');
eq('解析：空串 → 空数组', grouping.parseExpandedIds('').length, 0);
eq('序列化往返', grouping.parseExpandedIds(grouping.serializeExpandedIds(['p1', 'p2'])).join(','), 'p1,p2');
eq('会话数文案：0 留空', grouping.projectSessionCountLabel(0), '');
eq('会话数文案：正数', grouping.projectSessionCountLabel(3), '3');
eq('设备名回填', grouping.projectDeviceLabel(proj('p1'), [{ id: 'conn-1', name: 'MacBook Pro' }]), 'MacBook Pro');
eq('设备缺失时的回落', grouping.projectDeviceLabel(proj('p1'), []), '未命名设备');

// ---------------------------------------------------------------------------
// 11. 骨架：目的地常量（对齐安卓 14 个目的地）
// ---------------------------------------------------------------------------

group('骨架：目的地常量与安卓 AppDestination 的 14 项一一对应');
eq('LoginMethods', Route.LOGIN, 'login');
eq('ServerSetup', Route.SERVER_SETUP, 'server_setup');
eq('QrLogin', Route.QR_LOGIN, 'qr_login');
eq('QrWaiting', Route.QR_WAITING, 'qr_waiting');
eq('Sessions（首页）', Route.HOME, 'home');
// ⚠️ **R82 删除**了这条 `NewSession / Route.NEW_SESSION === 'new_session'`：
// 该目的地全工程**已无 push 点**（只剩常量与 `Index` 的挂载分支），R82 把常量与死分支一起删掉了。
// 上游 `NewSession` 那个目的地在本工程**由 `NEW_PROJECT` 承担**（同一屏的 `projectOnly` 模式），
// 所以这里少一条**不是能力缺失**；若要重新开放，回潮闸门在 `suite-topbar.mjs`（会先红）。
eq('NewProject（上游 NewSession 与 NewProject 共用同一屏）', Route.NEW_PROJECT, 'new_project');
eq('Devices', Route.DEVICES, 'devices');
eq('Terminal', Route.TERMINAL, 'terminal');
eq('Files', Route.FILES, 'files');
eq('DeviceDetail', Route.DEVICE, 'device');
eq('SessionDetail', Route.SESSION, 'session');
eq('ArchivedSessions', Route.ARCHIVED, 'archived');
eq('DeviceSetup', Route.ADD_DEVICE, 'add_device');
eq('本工程特有的设置目的地', Route.SETTINGS, 'settings');
check('既有常量名一个都没改（回归保护）',
  Route.LOGIN === 'login' && Route.HOME === 'home' && Route.SESSION === 'session'
    && Route.FILES === 'files' && Route.TERMINAL === 'terminal'
    && Route.SETTINGS === 'settings' && Route.DEVICE === 'device' && Route.ARCHIVED === 'archived'
    && Route.ADD_DEVICE === 'add_device');

// ---------------------------------------------------------------------------
// 12. 骨架：返回语义 = 回首页（不是回上一页）
// ---------------------------------------------------------------------------

group('骨架：返回语义（上游把返回目标硬编码为 Sessions）');
Router.reset(Route.HOME);
Router.push(Route.DEVICES);
Router.push(Route.DEVICE, 'd1');
eq('压了两层后栈深为 3', Router.depth(), 3);
eq('back() 报告已处理', Router.back(), true);
eq('back() 后当前是首页（不是 Devices）', Router.current().route, Route.HOME);
eq('back() 后栈被压成一项', Router.depth(), 1);
eq('已在首页时 back() 返回 false（交回系统退出）', Router.back(), false);
eq('首页back 后仍在首页', Router.current().route, Route.HOME);

group('骨架：BackTo / push / pop 的既有语义保持不变');
Router.reset(Route.DEVICES);
Router.push(Route.ADD_DEVICE);
Router.backTo(Route.DEVICES);
eq('backTo 切到指定目的地（DeviceSetup 记来源用）', Router.current().route, Route.DEVICES);
eq('backTo 后栈深 1', Router.depth(), 1);
Router.reset(Route.HOME);
Router.push(Route.SESSION, 's1');
eq('push 带参数', Router.current().param, 's1');
eq('pop 仍逐级返回', Router.pop(), true);
eq('pop 后回到首页', Router.current().route, Route.HOME);
eq('pop 到根后返回 false', Router.pop(), false);
eq('replace 只换栈顶', (() => {
  Router.reset(Route.HOME);
  Router.push(Route.SESSION, 'a');
  Router.replace(Route.SESSION, 'b');
  return Router.depth() === 2 && Router.current().param === 'b';
})(), true);

// ---------------------------------------------------------------------------
// 13. 首页的两处专用色（R11 task-22）：上游是组件内联值，本工程给了专用资源色
// ---------------------------------------------------------------------------

group('首页专用色：icon_muted / row_divider（资源双值 + 页面确实在用）');
const homeSrc = fs.readFileSync(path.join(SRC_ETS, 'ui/screens/HomeScreen.ets'), 'utf8');
/**
 * 剥掉**整行注释**后的 HomeScreen 源码。
 *
 * 为什么需要它：下面几条断言扫的是「源码里不该出现某个字面量」，而注释里出现同一个词
 * 是**合法且有益**的（例如 R37 八改解释「时间会变成 5m」时写了「几分钟」）。
 * 用全文扫描会把注释误判成行为缺陷 —— R38 就是这么误伤出一条假失败的。
 * ⚠️ 剥注释**不降低检验力**：被检查的字符串（时间格式化文案、控件参数）只会出现在代码里，
 *    它们出现在注释中恰恰说明它们不再参与渲染 —— 那正是本条断言要放行的情形。
 */
const homeNoComment = homeSrc.split('\n').filter((line) => !/^\s*(\*|\/\/)/.test(line)).join('\n');
const baseColors = fs.readFileSync(
  path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'), 'utf8');
const darkColors = fs.readFileSync(
  path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'), 'utf8');
check('快捷卡片图标走 icon_muted（上游 #8E8E8E / #9A9A9A）',
  homeSrc.indexOf("$r('app.color.icon_muted')") >= 0);
check('列表行下划走 row_divider（上游 #E9E8E5 / #27272A）',
  homeSrc.indexOf("$r('app.color.row_divider')") >= 0);
check('base 主题有 icon_muted', /"name":\s*"icon_muted"/.test(baseColors));
check('dark 主题有 icon_muted', /"name":\s*"icon_muted"/.test(darkColors));
check('base 主题有 row_divider', /"name":\s*"row_divider"/.test(baseColors));
check('dark 主题有 row_divider', /"name":\s*"row_divider"/.test(darkColors));
check('卡片与圆钮边框仍走 borderColor()（上游只差 2 个 hex 位，裁定不新增）',
  homeSrc.indexOf('.borderColor(borderColor())') >= 0);
check('行分隔线不再混用 borderColor()',
  homeSrc.indexOf('Divider().color(borderColor())') < 0);

// ---------------------------------------------------------------------------
// 相对时间标签（R13-8 裁决：改成上游 `SessionMappers.kt:110-130` 的英文紧凑格式）
// 首页会话行显示的就是 `session.updatedAtLabel`（= `relativeTimeLabel`），所以这一块断言在首页套件里。
// ---------------------------------------------------------------------------

group('相对时间标签（首页会话行显示的就是它）');
const appModels = load('model/AppModels.js');
const agoMs = (ms) => new Date(Date.now() - ms).toISOString();
eq('小于 1 分钟 → now', appModels.relativeTimeLabel(agoMs(20000)), 'now');
eq('5 分钟 → 5m', appModels.relativeTimeLabel(agoMs(5 * 60000 + 5000)), '5m');
eq('1 小时 → 1h', appModels.relativeTimeLabel(agoMs(61 * 60000)), '1h');
eq('3 小时 → 3h', appModels.relativeTimeLabel(agoMs(3 * 3600000 + 60000)), '3h');
eq('30 小时 → Yest.', appModels.relativeTimeLabel(agoMs(30 * 3600000)), 'Yest.');
eq('4 天 → 4d', appModels.relativeTimeLabel(agoMs(4 * 86400000 + 3600000)), '4d');
eq('16 天 → 2w', appModels.relativeTimeLabel(agoMs(16 * 86400000)), '2w');
eq('400 天 → 1y', appModels.relativeTimeLabel(agoMs(400 * 86400000)), '1y');
check('首页渲染的仍是 updatedAtLabel（调用链没被改）',
  homeSrc.indexOf('session.updatedAtLabel') >= 0);
// R38 修正：原来扫的是 homeSrc（**全文，含注释**），R37 八改在 HomeScreen.ets 里加的
// 「活跃会话跑上几分钟后时间会变成 5m」这句**解释性注释**把它误伤成假失败。
// 改成扫 homeNoComment（剥掉整行注释）—— 断言原意（用户可见的时间格式化文案不得中文化）
// 一字未改，检验力反而更强：现在只有**真正参与渲染的代码**里出现中文时间词才算失败。
check('首页不再自己格式化时间（没有中文本地化残留，已剥注释）',
  homeNoComment.indexOf('小时') < 0 && homeNoComment.indexOf('分钟') < 0);

// ---------------------------------------------------------------------------
// R13-9（task-17）：首页「会话状态」菜单改就地弹窗（F-6）+ 去全页遮罩（F-5）
// 上游锚文：`HomeProjectMenus.kt:24 HomeProjectFilterMenu` → `AADropdownMenu.kt:94 AAAnchoredDropdownMenu`（286 宽 /
// 圆角 18 / 上下内边距 14 / 行高 48 / 标签 12sp）；项目「…」→ `HomeProjectComponents.kt:452 HomeProjectActionOverlay`
// + `:544 HomeProjectActionCard`（252×168 / 圆角 22 / 上下 7 / 行 50）。
// 几何再与安卓 dump 对账：`r12-android-baseline/android-06-view-menu.dump.json` 的菜单容器 [298,743]-[1149,1376]、
// 行 [298,905]/[298,1048]/[298,1191]、标签项 743→905。
// ---------------------------------------------------------------------------

group('R13-9 F-6/F-5：就地弹窗（上游 AADropdownMenu / AAAnchoredPopup）');
const designSrc = fs.readFileSync(path.join(SRC_ETS, 'ui/Design.ets'), 'utf8');
const componentsSrc = fs.readFileSync(path.join(SRC_ETS, 'ui/Components.ets'), 'utf8');
const CARD_DPR = 2.975;
/** 取 `static readonly <name>: number = <值>;` 的数值（Design 令牌）。 */
const numToken = (src, name) => {
  const key = 'static readonly ' + name + ': number =';
  const at = src.indexOf(key);
  if (at < 0) { return NaN; }
  let i = at + key.length;
  while (i < src.length && ' ='.indexOf(src.charAt(i)) >= 0) { i++; }
  let digits = '';
  while (i < src.length && /[0-9.]/.test(src.charAt(i))) { digits += src.charAt(i); i++; }
  return digits.length > 0 ? Number(digits) : NaN;
};

check('「项目」分组头外层 Row 无 space（上游 HomeListSectionHeader 外层没有 horizontalArrangement）',
  /Row\(\) \{\s+Row\(\{ space: Space\.XS_PLUS \}\) \{\s+Text\('项目'\)/.test(homeSrc));
check('筛选菜单不再走底部弹层（SHEET_PROJECT_FILTER 已删）', homeSrc.indexOf('SHEET_PROJECT_FILTER') < 0);
eq('根节点仍然只有一个 bindSheet（EXPERIENCE §34）', homeSrc.split('.bindSheet(').length - 1, 1);
eq('两处分组头（项目/会话视图）都绑了就地弹窗',
  homeSrc.split('.bindPopup(this.filterMenuOpen, this.filterMenuPopupOptions())').length - 1, 2);
eq('项目行的「…」也绑了就地弹窗（按行 id 判定开关）',
  homeSrc.split('.bindPopup(this.projectMenuRowKey === row.projectId, this.projectMenuPopupOptions())').length - 1, 1);
check('间距常量：菜单 4（上游 MenuGap）/ 卡片 6（上游 AAAnchoredPopup 默认 gap）',
  homeSrc.indexOf('const MENU_GAP: number = 4;') >= 0 && homeSrc.indexOf('const CARD_GAP: number = 6;') >= 0);

const filterOpts = homeSrc.substring(homeSrc.indexOf('private filterMenuPopupOptions()'),
  homeSrc.indexOf('private projectMenuPopupOptions()'));
check('筛选弹窗：右下角对齐触发按钮（上游 x = anchor.right - 286dp）',
  filterOpts.indexOf('placement: Placement.BottomRight,') >= 0);
check('筛选弹窗：无箭头（上游 DropdownMenu 没有箭头）', filterOpts.indexOf('enableArrow: false,') >= 0);
check('筛选弹窗：**透明**遮罩 —— 只吃掉外部点击，不压暗整页（F-5 的正解）',
  filterOpts.indexOf('mask: { color: Color.Transparent },') >= 0);
check('筛选弹窗：容器自身不画底/不模糊/无阴影（卡片自己画）',
  filterOpts.indexOf('popupColor: Color.Transparent,') >= 0
    && filterOpts.indexOf('backgroundBlurStyle: BlurStyle.NONE,') >= 0
    && filterOpts.indexOf('radius: 0, color: Color.Transparent') >= 0);
check('筛选弹窗宽度取 Design 令牌 MENU_WIDTH', filterOpts.indexOf('width: Control.MENU_WIDTH,') >= 0);
check('弹窗关闭时状态回写（onStateChange）', filterOpts.indexOf('if (!e.isVisible) {') >= 0);

eq('令牌 MENU_WIDTH = 286（上游 MenuWidth = 286.dp）', numToken(designSrc, 'MENU_WIDTH'), 286);
eq('令牌 MENU_ITEM_MIN = 48（上游 heightIn(min = 48.dp)）', numToken(designSrc, 'MENU_ITEM_MIN'), 48);
eq('令牌 MENU_PAD_V = 14（上游 MenuVerticalPadding = 14.dp）', numToken(designSrc, 'MENU_PAD_V'), 14);
eq('令牌 MENU_MAX_HEIGHT = 328（上游 MenuMaxHeight）', numToken(designSrc, 'MENU_MAX_HEIGHT'), 328);
eq('令牌 MENU_CARD_W = 252（上游 HomeProjectActionCard）', numToken(designSrc, 'MENU_CARD_W'), 252);
eq('令牌 MENU_CARD_H = 168（上游 HomeProjectActionCard）', numToken(designSrc, 'MENU_CARD_H'), 168);
check('286dp 在 dpr 2.975 下 = 851px，与安卓 dump 菜单宽 [298..1149] 一致（±1.5px）',
  Math.abs(numToken(designSrc, 'MENU_WIDTH') * CARD_DPR - 851) < 1.5);
check('48dp 行 = 142.8px，与安卓 dump 行距 143px 一致（±1.5px）',
  Math.abs(numToken(designSrc, 'MENU_ITEM_MIN') * CARD_DPR - 143) < 1.5);
check('首行起点 = 上内边距 14 + 标签项 40 = 54dp = 160.7px，安卓 dump 743→905 = 162px（±2.5px）',
  Math.abs((numToken(designSrc, 'MENU_PAD_V') + numToken(designSrc, 'MENU_LABEL_H')) * CARD_DPR - 162) < 2.5);

check('筛选卡片几何照抄上游（286 / 圆角 18 / 上下 14 / 最大高 328）',
  homeSrc.indexOf('.width(Control.MENU_WIDTH)') >= 0
    && homeSrc.indexOf('.padding({ top: Control.MENU_PAD_V, bottom: Control.MENU_PAD_V })') >= 0
    && homeSrc.indexOf('.constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })') >= 0
    && homeSrc.indexOf('.borderRadius(Radius.XL)') >= 0);
eq('三个选项行都按 48dp（上游 heightIn(min = 48.dp)）',
  homeSrc.split('rowHeight: Control.MENU_ITEM_MIN,').length - 1, 3);
eq('三个选项行的选中打勾都用 ink（上游 Icon(Check, tint = textColor)，不是品牌绿）',
  homeSrc.split('activeTint: ink(),').length - 1, 3);
check('标签项 12sp + 显式高 40dp（安卓 dump 实测该项 40.5dp）',
  homeSrc.indexOf('.fontSize(FontSize.MENU_LABEL)') >= 0 && homeSrc.indexOf('.height(Control.MENU_LABEL_H)') >= 0);
/**
 * R86 口径更新（**Lead 授权只改这一条**，改动原文对照见 R86 回执）：
 * 三处弹窗内容根的底改成「官方材质 / 自绘玻璃」**二选一**，由**同一个探针** `immersiveMaterialEnabled()`
 * 门控 —— 材质可用 ⇒ 该根 `Color.Transparent`（零自绘层，底由 `dialogMaterial()` 画，``）；
 * 不可用 ⇒ 逐字回到 R84 的 `menuSurface()` 玻璃。弹窗容器自身是 `popupColor: Color.Transparent`，
 * 底只能由内容根提供 ⇒ 两条支路必须都在，缺一支就是「面板全透明」或「材质+自绘双保险」。
 * ⚠️ 比旧断言**更严**（旧版要求的是一处**未门控**的 `menuSurface()` 底色调用，只证明「底还在」，
 *    证明不了「材质档已经让位」；将来有人把门控拆掉它照样绿）：
 *    ① 回退路径仍在（`menuSurface()` 的玻璃令牌定义）；
 *    ② **恰好三处**内容根都写着「材质档 `Color.Transparent` + 不可用档 `this.menuSurface()`」的门控三元。
 *    ⇒ 只留 `menuSurface()` 而拆掉门控、改错任一分支、漏掉三处中的一处，都会红。
 * ⚠️ 判据跑在 `homeNoComment`（整行注释已剥）上：注释里提到这套写法**不算**实现。
 */
check('卡片底色按上游 menuSurface（深色 subtle / 浅色 raisedSurface），且三处内容根由 immersiveMaterialEnabled() 门控成「材质档零自绘层 / 不可用档玻璃」',
  homeNoComment.indexOf('return isDarkAppearance() ? subtle() : raisedSurface();') >= 0
    && (homeNoComment.match(/\.backgroundColor\(immersiveMaterialEnabled\(\)\s*\?\s*Color\.Transparent\s*:\s*this\.menuSurface\(\)\)/g) || []).length === 3);
check('项目「…」卡 = 252×168 / 圆角 22 / 上下 7dp（上游 HomeProjectActionCard）',
  homeSrc.indexOf('.width(Control.MENU_CARD_W)') >= 0 && homeSrc.indexOf('.height(Control.MENU_CARD_H)') >= 0
    && homeSrc.indexOf('.padding({ top: CARD_PAD_V, bottom: CARD_PAD_V })') >= 0
    && homeSrc.indexOf('.borderRadius(Radius.XXL)') >= 0);
check('项目「…」卡里不再有项目名/路径头（上游动作卡没有；旧弹层那一版是本工程自加的）',
  homeSrc.indexOf('  projectMenuPopup() {') >= 0
    && homeSrc.substring(homeSrc.indexOf('projectMenuPopup() {') + 20,
      homeSrc.indexOf('projectArchiveSheet() {')).indexOf('projectSheetPath') < 0);
check('归档二次确认仍在弹层（上游 HomeArchiveProjectDialog 是 Dialog，保留遮罩）',
  homeSrc.indexOf('this.projectArchiveSheet()') >= 0 && homeSrc.indexOf('if (this.sheetKind === SHEET_PROJECT)') >= 0);
check('AaMenuActionRow 新增 rowHeight / activeTint 两个可选参数（默认值不变，其它页面不受影响）',
  componentsSrc.indexOf('@Prop rowHeight: number = Control.MENU_ROW;') >= 0
    && componentsSrc.indexOf("@Prop activeTint: Resource = $r('app.color.session_status_accent');") >= 0);

// ---------------------------------------------------------------------------
// R13-16（task-23）：首页项目行改平铺 56dp + 去会话计数（用户「底部内容」的根因）
// 上游锚文：`HomeProjectComponents.kt:296 HomeProjectRow`（`.height(56.dp)` + `.padding(vertical = 4.dp)`，
// 无背景 / 无边框 / 无计数列）；展开子行 `HomeProjectSessionRow.kt:32`（44dp、无下划线、start 34dp）；
// 真机 dump 实测改前 205px（≈69vp）—— 比 56dp 的 166.6px 大 23%，一屏因此少 3 行。
// ---------------------------------------------------------------------------

group('R13-16：项目行 56dp 平铺 + 去计数列 + 子行 44dp');
const rowSrc = homeSrc.substring(homeSrc.indexOf('  projectRow(row: ProjectRow) {'),
  homeSrc.indexOf('  /** 底部入口：正常时「加载更多」'));
check('项目行区段能取到（源码结构未变形）', rowSrc.length > 100, 'len=' + rowSrc.length);
check('项目行是平铺的：无内边距 / 无圆角 / 无背景 / 无边框',
  rowSrc.indexOf('.padding(Space.M)') < 0 && rowSrc.indexOf('.borderRadius(Radius.XL)') < 0
    && rowSrc.indexOf('.backgroundColor(raisedSurface())') < 0 && rowSrc.indexOf('.borderColor(borderColor())') < 0);
check('行高 = Control.ROW_PROJECT 且上下内边距各 4dp（上游 height(56.dp) + padding(vertical = 4.dp)）',
  rowSrc.indexOf('.height(Control.ROW_PROJECT)') >= 0
    && rowSrc.indexOf('.padding({ top: Space.XS, bottom: Space.XS })') >= 0);
eq('令牌 ROW_PROJECT = 56（上游 HomeProjectRow.height(56.dp)）', numToken(designSrc, 'ROW_PROJECT'), 56);
check('56dp 在 dpr 2.975 下 = 166.6px，与安卓 ≈167px 一致（±2px）',
  Math.abs(numToken(designSrc, 'ROW_PROJECT') * CARD_DPR - 166.6) < 2);
check('行高比 205/166.6 = 1.230 ⇒ 同样一屏 10 行变 12.3 行（安卓用户图 = 13 行）',
  Math.abs(205 / (numToken(designSrc, 'ROW_PROJECT') * CARD_DPR) - 1.230) < 0.01);
check('会话计数列已删除（上游 HomeProjectRow 没有它；全仓 sessionCount 只在设备详情页出现）',
  homeSrc.indexOf('projectSessionCountLabel') < 0);
check('展开/收起图标：FolderOpen / Folder 21dp（上游 :328 `if (expanded) Lucide.FolderOpen else Lucide.Folder`）',
  rowSrc.indexOf("row.expanded ? ICONS['folder-open'] : ICONS['folder']") >= 0 && rowSrc.indexOf('iconSize: 21') >= 0);
eq('令牌 ROW_PROJECT_SESSION = 44（上游 HomeProjectSessionRow.height(44.dp)）',
  numToken(designSrc, 'ROW_PROJECT_SESSION'), 44);
eq('令牌 PROJECT_SESSION_INSET = 34（上游 padding(start = 34.dp)）',
  numToken(designSrc, 'PROJECT_SESSION_INSET'), 34);
const subSrc = homeSrc.substring(homeSrc.indexOf('  projectSessionRow(session: AgentSession, inset: boolean) {'),
  homeSrc.indexOf('  /** 最近会话行'));
check('展开子行：44dp + 无行下划线（上游 HomeProjectSessionRow 里没有 Divider）',
  subSrc.length > 100 && subSrc.indexOf('.height(Control.ROW_PROJECT_SESSION)') >= 0
    && subSrc.indexOf('Divider()') < 0);
check('展开子行：左侧 34dp 缩进，`inset = false` 时不给（项目视图置顶区就是后者）',
  subSrc.indexOf('left: inset ? Control.PROJECT_SESSION_INSET : 0') >= 0);
eq('项目展开的子项改用 44dp 子行（不再复用 52dp 的「最近」行）',
  homeSrc.split('this.projectSessionRow(session, true)').length - 1, 1);
eq('项目视图的置顶会话用 inset=false 的同款子行（上游 HomeProjectSessionRow(inset = false)）',
  homeSrc.split('this.projectSessionRow(session, false)').length - 1, 1);
check('「最近」行仍是 52dp 的 HomeRecentSessionRow 形态、会话视图置顶行仍是 66dp（两者未被动到）',
  homeSrc.indexOf('.height(Control.ROW)') >= 0 && homeSrc.indexOf('.height(Control.ROW_TALL)') >= 0);


// ---------------------------------------------------------------------------
// R23：会话操作的**成功反馈** + 重命名校验（上游 `HomeScreen.kt` 的 showToast 系列）
// ---------------------------------------------------------------------------
// 修前：会话的置顶 / 归档 / 重命名**点了没有任何反馈** —— 只有 `project*` 那三条有提示
//（上游 `HomeScreen.kt` 里 home_session_pinned / home_session_unpinned /
//  home_session_archived / home_session_restored / home_session_renamed 五条 Toast，本工程一条都没有）。
// 失败侧不用补 —— `mutate()` 会把原因写进 `store.error`，页面渲染成错误横幅。
group('R23：会话操作的成功反馈（上游五条 Toast）');
check('会话置顶 / 取消置顶两条文案都在',
  homeSrc.indexOf("'会话已置顶。'") >= 0 && homeSrc.indexOf("'会话已取消置顶。'") >= 0);
// R41：归档提示补上了恢复路径（用户容易以为「归档 = 删掉了」）。
// **原意保住**：本条原本断言「R23 补的归档/恢复两条成功反馈存在」——改后仍然断言两条都在，
// 且**更强**（额外钉住恢复路径指引，防止后人把它删回光秃秃的「会话已归档。」）。
check('会话归档 / 恢复两条文案都在（R41 起归档提示带恢复路径）',
  homeSrc.indexOf("'会话已归档，可在「已归档」里恢复。'") >= 0 && homeSrc.indexOf("'会话已恢复。'") >= 0);
check('会话重命名文案在', homeSrc.indexOf("'会话已重命名。'") >= 0);
check('三条操作都按返回的 boolean 决定是否提示（不是无条件提示）',
  /setSessionPinned\(id, next\)\.then\(\(ok: boolean\) => \{[\s\S]{0,120}?if \(ok\)/.test(homeSrc)
  && /setSessionArchived\(id, next\)\.then\(\(ok: boolean\) => \{[\s\S]{0,120}?if \(ok\)/.test(homeSrc)
  && /renameSession\(id, value\)\.then\(\(ok: boolean\) => \{[\s\S]{0,120}?if \(ok\)/.test(homeSrc));
check('提示走页面既有的 showNotice（4 秒自动消失，与上游 Toast 等价）',
  homeSrc.indexOf('private showNotice(text: string): void') >= 0);

group('R23：重命名校验（上游 HomeSessionActions.kt:296-302 的 submit()）');
check('标题为空 → 提示「标题不能为空。」且**不提交**',
  /value\.length === 0\) \{[\s\S]{0,120}?this\.showNotice\('标题不能为空。'\)[\s\S]{0,80}?return;/.test(homeSrc));
check('没有改动 → 什么都不做（不白发一次 PATCH）',
  /value === this\.actionSheetTitle\) \{[\s\S]{0,160}?return;/.test(homeSrc));
check('两种早退都排在真正提交之前',
  homeSrc.indexOf("this.showNotice('标题不能为空。')") < homeSrc.indexOf('this.store.renameSession(id, value).then'));
// ---------------------------------------------------------------------------
// R25：首页两个弹层的行样式必须与上游逐项一致
// ---------------------------------------------------------------------------
// 上游锚文：
//   下拉菜单项 `AADropdownMenu.kt:108-163` `AADropdownMenuItem`：`heightIn(min = 48.dp)`、
//     `padding(horizontal = 16.dp, vertical = 8.dp)`、文案 **14.sp / lineHeight 19.sp / SemiBold**；
//   **Material 的 Column 没有 spacing ⇒ 行紧挨着排**（安卓 dump 行距 143px ÷ 2.975 = 48.07dp）。
//   动作卡行 `HomeProjectComponents.kt:576-605` `HomeProjectActionRow`：`height(50.dp)`、
//     `padding(horizontal = 20.dp)`、文案 **16.sp / Bold**、图标 21dp。
// ⚠️ 本工程这两行共用 `AaMenuActionRow`，R25 之前字号是折中的 15sp、且菜单容器多给了 4vp spacing
//   ⇒ 行距 52dp（多 4dp）、文案 17.7dp 行框（上游 19.2dp）。
const menuCompSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Components.ets'), 'utf8');
const menuDesignSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8');
group('R25：会话状态菜单（上游 AADropdownMenu）');
const filterSeg = homeNoComment.slice(homeNoComment.indexOf('filterMenuPopup() {'), homeNoComment.indexOf('filterMenuPopup() {') + 1600);
check('菜单容器**不带** Column spacing（上游行是 48dp 紧挨着排）',
  filterSeg.includes('Column() {') && filterSeg.includes('Column({ space') === false);
check('三行都按上游 AADropdownMenuItem 传 14sp',
  (homeNoComment.match(/textSize: FontSize\.BODY_SMALL/g) || []).length >= 3);
check('行高仍取 48（上游 heightIn(min = 48.dp)）',
  (homeNoComment.match(/rowHeight: Control\.MENU_ITEM_MIN/g) || []).length >= 3);

group('R25：项目「…」动作卡（上游 HomeProjectActionRow）');
check('三行都按上游传 16sp / Bold / 左右 20dp',
  (homeNoComment.match(/textSize: FontSize\.ROW_TITLE,\n\s+padH: Space\.L_PLUS,\n\s+boldText: true,/g) || []).length >= 3);
check('Space.L_PLUS = 20（上游 padding(horizontal = 20.dp)）',
  menuDesignSrc.includes('static readonly L_PLUS: number = 20;'));

group('R25：AaMenuActionRow 的三个样式开关');
check('组件有 textSize 开关', menuCompSrc.includes('@Prop textSize: number = FontSize.BODY;'));
check('组件有 padH 开关', menuCompSrc.includes('@Prop padH: number = Space.L;'));
check('组件有 boldText 开关', menuCompSrc.includes('@Prop boldText: boolean = false;'));
check('三个值真的接进了 build',
  menuCompSrc.includes('.fontSize(this.textSize)')
  && menuCompSrc.includes('.padding({ left: this.padH, right: this.padH })')
  && menuCompSrc.includes('.fontWeight(this.boldText ? FontWeight.Bold : FontWeight.Medium)'));


// ---------------------------------------------------------------------------
// R38：项目分组「默认全部加载」（展开集合语义反转）+ 差分更新判定
//
// 用户需求原文：「项目默认全部加载」。改前是「展开白名单 + 初始空」= 全部折叠；
// 改成「手动折叠黑名单 + 初始空」= 全部展开，同时保留用户手动折叠的意图。
// 锚文：model/HomeGrouping.ets 的 ProjectCollapseState / migrateCollapsedIds /
//       buildProjectRows 第 4 参 / projectRowsEqual / projectRowListsEqual / deviceListsEqual
// ---------------------------------------------------------------------------

group('R38-1：展开语义反转（默认全部展开）');
const r38Projects = [proj('p1'), proj('p2'), proj('p3', { manuallyCreated: true })];
const r38Sessions = [
  sess('a1', { projectId: 'p1' }),
  sess('a2', { projectId: 'p1', updatedSeq: 3 }),
  sess('b1', { projectId: 'p2' })
];
const r38Default = grouping.buildProjectRows(r38Projects, r38Sessions, F.ACTIVE, []);
eq('R38 空折叠集合：3 个项目全部可见', r38Default.visibleCount, 3);
check('R38 空折叠集合 ⇒ 每个项目都展开（默认全部加载）',
  r38Default.regular.every((row) => row.expanded === true));
// 组内排序与上游 sessionListComparator 一致：同 sortKey 时按 id 倒序（见 sortSessionsForProject）。
eq('R38 展开时带出组内会话（p1 两条，按 id 倒序）', ids(r38Default.regular.filter((r) => r.projectId === 'p1')[0].sessions), 'a2,a1');
eq('R38 展开时带出组内会话（p2 一条）', ids(r38Default.regular.filter((r) => r.projectId === 'p2')[0].sessions), 'b1');

const r38Collapsed = grouping.buildProjectRows(r38Projects, r38Sessions, F.ACTIVE, ['p2']);
eq('R38 手动折叠 p2 后仍可见（折叠 ≠ 隐藏）', r38Collapsed.visibleCount, 3);
eq('R38 被折叠的 p2 expanded=false',
  r38Collapsed.regular.filter((r) => r.projectId === 'p2')[0].expanded, false);
eq('R38 未被折叠的 p1 仍 expanded=true',
  r38Collapsed.regular.filter((r) => r.projectId === 'p1')[0].expanded, true);
check('R38 折叠不影响其它项目', r38Collapsed.regular.filter((r) => r.projectId !== 'p2')
  .every((row) => row.expanded === true));

group('R38-2：折叠集合的解析 / 序列化往返与裁剪');
eq('R38 折叠集合往返', grouping.parseProjectCollapsed(
  grouping.serializeProjectCollapsed(['p1', 'p2'])).join(','), 'p1,p2');
eq('R38 空串解析为空集合', grouping.parseProjectCollapsed('').length, 0);
eq('R38 往返保留顺序并去掉空格', grouping.serializeProjectCollapsed(
  grouping.parseProjectCollapsed('p2, p1')), 'p2,p1');
eq('R38 裁剪掉已不存在的项目', grouping.pruneUnknownProjectIds(['p1', 'ghost'], r38Projects).join(','), 'p1');
eq('R38 旧名 pruneExpandedIds 仍是别名',
  grouping.pruneExpandedIds(['p1', 'ghost'], r38Projects).join(','), 'p1');
eq('R38 stringListsEqual 判相同', grouping.stringListsEqual(['p1', 'p2'], ['p1', 'p2']), true);
eq('R38 stringListsEqual 判顺序不同', grouping.stringListsEqual(['p1', 'p2'], ['p2', 'p1']), false);
eq('R38 stringListsEqual 判长度不同', grouping.stringListsEqual(['p1'], ['p1', 'p2']), false);

group('R38-3：老用户一次性迁移（旧白名单 → 新黑名单）');
eq('R38 迁移：旧白名单 {p1} + 项目 {p1,p2} ⇒ 折叠 {p2}',
  grouping.migrateCollapsedIds('', 'p1', ['p1', 'p2']).join(','), 'p2');
eq('R38 迁移：旧白名单为空串 ⇒ 全部展开（不推成全部折叠）',
  grouping.migrateCollapsedIds('', '', ['p1', 'p2']).length, 0);
eq('R38 迁移：旧白名单覆盖全部项目 ⇒ 折叠集合为空',
  grouping.migrateCollapsedIds('', 'p1,p2', ['p1', 'p2']).length, 0);
eq('R38 迁移：新键已有值时以新键为准（不重复迁移）',
  grouping.migrateCollapsedIds('p2', 'p1', ['p1', 'p2']).join(','), 'p2');
eq('R38 迁移：旧白名单含已删项目时不报错',
  grouping.migrateCollapsedIds('', 'ghost', ['p1']).join(','), 'p1');

group('R38-4：增量展开（服务端后续新增的项目）');
const r38AfterNewProject = grouping.buildProjectRows(
  r38Projects.concat([proj('p4')]), r38Sessions.concat([sess('d1', { projectId: 'p4' })]),
  F.ACTIVE, ['p2']);
eq('R38 新增项目 p4 自动展开',
  r38AfterNewProject.regular.filter((r) => r.projectId === 'p4')[0].expanded, true);
eq('R38 新增项目后原有折叠意图不变',
  r38AfterNewProject.regular.filter((r) => r.projectId === 'p2')[0].expanded, false);

group('R38-5：差分更新的相等判定（内容相等 ⇒ 可保留旧引用）');
const rowsA = grouping.buildProjectRows(r38Projects, r38Sessions, F.ACTIVE, []);
const rowsB = grouping.buildProjectRows(r38Projects, r38Sessions, F.ACTIVE, []);
check('R38 同一输入两次组装：数组不是同一引用（证明"总换引用"属实）', rowsA.regular !== rowsB.regular);
check('R38 但内容判等为真 ⇒ 页面可跳过赋值', grouping.projectRowListsEqual(rowsA.regular, rowsB.regular) === true);
check('R38 置顶区同样判等', grouping.projectRowListsEqual(rowsA.pinned, rowsB.pinned) === true);

const rowsCollapsedB = grouping.buildProjectRows(r38Projects, r38Sessions, F.ACTIVE, ['p1']);
check('R38 正对照：仅折叠态不同 ⇒ 判不等（灵敏度）',
  grouping.projectRowListsEqual(rowsA.regular, rowsCollapsedB.regular) === false);
const rowsFilteredB = grouping.buildProjectRows(r38Projects, r38Sessions, F.ARCHIVED, []);
check('R38 正对照：仅筛选档不同 ⇒ 判不等', grouping.projectRowListsEqual(rowsA.regular, rowsFilteredB.regular) === false);
const rowsRenamedB = grouping.buildProjectRows(r38Projects, [sess('a1', { projectId: 'p1', title: '改过标题' })], F.ACTIVE, []);
check('R38 正对照：仅会话标题不同 ⇒ 判不等', grouping.projectRowListsEqual(rowsA.regular, rowsRenamedB.regular) === false);
const rowsSeqB = grouping.buildProjectRows(r38Projects, [sess('a1', { projectId: 'p1', updatedSeq: 42 })], F.ACTIVE, []);
check('R38 正对照：仅 updatedSeq 不同 ⇒ 判不等', grouping.projectRowListsEqual(rowsA.regular, rowsRenamedB.regular) === false
  || grouping.projectRowListsEqual(rowsA.regular, rowsSeqB.regular) === false);
const rowsTimeB = grouping.buildProjectRows(r38Projects, [sess('a1', { projectId: 'p1', updatedAtLabel: '5m' })], F.ACTIVE, []);
check('R38 正对照：仅相对时间文案不同 ⇒ 判不等（时间会自己走）',
  grouping.projectRowListsEqual(rowsA.regular, rowsTimeB.regular) === false);
const rowsIndicatorB = grouping.buildProjectRows(r38Projects, [sess('a1', { projectId: 'p1', indicator: 'unread' })], F.ACTIVE, []);
check('R38 正对照：仅状态点不同 ⇒ 判不等（未读点要能消失）',
  grouping.projectRowListsEqual(rowsA.regular, rowsIndicatorB.regular) === false);
const rowsMetaB = grouping.buildProjectRows(r38Projects, [sess('a1', { projectId: 'p1', metaLabel: '别的设备' })], F.ACTIVE, []);
check('R38 正对照：仅 metaLabel 不同 ⇒ 判不等（设备改名要能刷新）',
  grouping.projectRowListsEqual(rowsA.regular, rowsMetaB.regular) === false);

group('R38-6：会话列表 / 设备列表的相等判定');
check('R38 sameSessionList：同内容不同引用判等', grouping.sameSessionList([sess('s1')], [sess('s1')]) === true);
check('R38 sameSessionList：长度不同判不等', grouping.sameSessionList([sess('s1')], []) === false);
check('R38 sameSessionList：标题不同判不等',
  grouping.sameSessionList([sess('s1')], [sess('s1', { title: 'x' })]) === false);
check('R38 sameSessionList：indicator 不同判不等',
  grouping.sameSessionList([sess('s1')], [sess('s1', { indicator: 'busy' })]) === false);
check('R38 deviceListsEqual：同内容判等', grouping.deviceListsEqual(
  [{ id: 'd1', name: 'Mac', online: true }], [{ id: 'd1', name: 'Mac', online: true }]) === true);
check('R38 deviceListsEqual：在线态变化判不等', grouping.deviceListsEqual(
  [{ id: 'd1', name: 'Mac', online: true }], [{ id: 'd1', name: 'Mac', online: false }]) === false);
check('R38 deviceListsEqual：改名判不等', grouping.deviceListsEqual(
  [{ id: 'd1', name: 'Mac', online: true }], [{ id: 'd1', name: 'MacBook', online: true }]) === false);

group('R38-7：页面接线（HomeScreen / HomeGrouping 源码锚文）');
const groupingSrc = fs.readFileSync(path.join(SRC_ETS, 'model', 'HomeGrouping.ets'), 'utf8');
// 键名字面量现在只有一处来源（AppPreferences），HomeScreen 引用它 —— 断言也跟着改，
// 但**原意不变**：磁盘上的键必须仍叫 aaProjectCollapsed（改名的代价持久化键改名 = 老数据全丢）。
check('R38 折叠键字面量是 aaProjectCollapsed（在 AppPreferences 里）',
  fs.readFileSync(path.join(SRC_ETS, 'store', 'AppPreferences.ets'), 'utf8')
    .includes("export const PROJECT_COLLAPSED_KEY: string = 'aaProjectCollapsed';"));
check('R38 HomeScreen 的 COLLAPSED_KEY 引用该常量（不再各写一份字面量）',
  homeSrc.includes('const COLLAPSED_KEY: string = PROJECT_COLLAPSED_KEY;'));
check('R38 @State 初值为空数组（= 全部展开）',
  homeSrc.includes('@State collapsedIds: string[] = [];'));
check('R38 pull() 先做一次老键迁移', homeSrc.includes('this.migrateCollapsePreferenceOnce();'));
check('R38 迁移完成后旧键写哨兵（不重复迁移）',
  homeSrc.includes('AppStorage.setOrCreate(EXPANDED_KEY, MIGRATED_SENTINEL);'));
check('R38 折叠集合走 pruneUnknownProjectIds', homeSrc.includes('pruneUnknownProjectIds(this.collapsedIds'));
// R55：调用点新增第 5 参（上次的顺序）——本锚文的**原意不变**（传的仍是折叠集合），
// 只跟着调用形态更新，别把它删掉：漏传 collapsedIds 会立刻退化回「全部展开」。
check('R38 buildProjectRows 传的是 collapsedIds',
  homeSrc.includes('this.filter, this.collapsedIds,'));
check('R38 toggleProject 写新键',
  homeSrc.includes('AppStorage.setOrCreate(COLLAPSED_KEY, serializeProjectCollapsed(this.collapsedIds));'));
check('R38 折叠判定是黑名单语义（不在集合里 = 展开）',
  groupingSrc.includes('expanded: collapsedIds.indexOf(project.id) < 0,'));
check('R38 差分：devices 相等则跳过赋值',
  homeSrc.includes('if (!deviceListsEqual(devices, this.devices)) {'));
check('R38 差分：pinnedRows 相等则跳过赋值',
  homeSrc.includes('if (!projectRowListsEqual(rows.pinned, this.pinnedRows)) {'));
check('R38 差分：regularRows 相等则跳过赋值',
  homeSrc.includes('if (!projectRowListsEqual(rows.regular, this.regularRows)) {'));
check('R38 差分：pinnedSessionRows 相等则跳过赋值',
  homeSrc.includes('if (!sameSessionList(pinnedSessions, this.pinnedSessionRows)) {'));
check('R38 差分：recentRows 相等则跳过赋值',
  homeSrc.includes('if (!sameSessionList(recentSessions, this.recentRows)) {'));
check('R38 差分：折叠集合相等则跳过赋值',
  homeSrc.includes('if (!stringListsEqual(collapsed, this.collapsedIds)) {'));
check('R38 sessionKey 补了相对时间文案（否则永远停在 now）',
  homeSrc.includes('${session.updatedAtLabel}'));
check('R38 sessionKey 补了状态点（否则未读点不消失）',
  homeSrc.includes('${session.indicator}'));
check('R38 sessionKey 补了 metaLabel（否则设备改名不刷新）',
  homeSrc.includes('${session.metaLabel}'));

// ⚠️ 集成验收实测抓到过一个真 bug：toggleProject 把 present 传成了「当前未展开」
// （= 当前折叠）而不是「用户想要折叠」，双向都退化成空操作 —— 点项目行毫无反应。
// 下面这组断言就是为它补的：行为单测钉住纯函数，源码锚文钉住调用点不许自己算 present。
group('R38-8：点击项目行的集合变化（toggleCollapsedId —— 真 bug 的回归防线）');
eq('R38 点击一个**未折叠**的项目 ⇒ 进入折叠集合',
  grouping.toggleCollapsedId([], 'p1').join(','), 'p1');
eq('R38 点击一个**已折叠**的项目 ⇒ 移出折叠集合（展开）',
  grouping.toggleCollapsedId(['p1'], 'p1').join(','), '');
eq('R38 点击不影响其它项目的折叠态',
  grouping.toggleCollapsedId(['p1'], 'p2').join(','), 'p1,p2');
eq('R38 已折叠集合里点别的项目 ⇒ 两个都折叠',
  grouping.toggleCollapsedId(['p1', 'p2'], 'p3').join(','), 'p1,p2,p3');
eq('R38 连续点同一个项目两次 ⇒ 回到原状',
  grouping.toggleCollapsedId(grouping.toggleCollapsedId(['p1'], 'p2'), 'p2').join(','), 'p1');
const r38ToggleSource = ['p1', 'p2'];
const r38ToggleResult = grouping.toggleCollapsedId(r38ToggleSource, 'p3');
check('R38 返回新数组（不原地改，否则 @State 不刷新）', r38ToggleResult !== r38ToggleSource);
eq('R38 入参数组未被修改（纯函数）', r38ToggleSource.join(','), 'p1,p2');
check('R38 点击前后集合确实变了（防空操作 —— 这正是 bug 的形态）',
  grouping.toggleCollapsedId([], 'p1').length === 1
  && grouping.toggleCollapsedId(['p1'], 'p1').length === 0);

group('R38-9：调用点不许自己算 present（源码锚文）');
const toggleSeg = homeSrc.slice(homeSrc.indexOf('private toggleProject(projectId: string): void {'));
const toggleBody = toggleSeg.slice(0, toggleSeg.indexOf('\n  }'));
check('R38 toggleProject 走纯函数 toggleCollapsedId',
  toggleBody.includes('toggleCollapsedId(this.collapsedIds, projectId)'));
check('R38 toggleProject 不再自己算 present（错误组合必须消失）',
  toggleBody.indexOf('toggleExpandedId(this.collapsedIds, projectId, !expanded)') < 0);
check('R38 toggleProject 函数体内不出现 !expanded',
  toggleBody.indexOf('!expanded') < 0);
check('R38 toggleProject 仍写新键（持久化不能丢）',
  toggleBody.includes('AppStorage.setOrCreate(COLLAPSED_KEY, serializeProjectCollapsed(this.collapsedIds));'));
check('R38 HomeScreen 已不再 import toggleExpandedId（改由纯函数内部调用）',
  homeSrc.indexOf('toggleExpandedId') < 0);
check('R38 HomeGrouping 里 toggleCollapsedId 用 present = !collapsed 的正确语义',
  groupingSrc.includes('return toggleExpandedId(collapsedIds, projectId, !collapsed);'));

// ---------------------------------------------------------------------------
// R38-10：折叠偏好必须**真的能持久化**
//
// 真机实测（模拟器）抓到：只写 AppStorage 是**内存**的，注册到 PersistentStorage 才会落盘。
// 现象是「折叠一个项目 → 杀进程重进」弹回全部展开 —— 而冷启动读到的 storedCollapsed 为空，
// 迁移逻辑于是回落到「全部展开」。这是本键（以及 R38 之前的旧键）从未真正持久化过的既有缺陷。
// ---------------------------------------------------------------------------

const prefsSrc = fs.readFileSync(path.join(SRC_ETS, 'store', 'AppPreferences.ets'), 'utf8');
check('R38 AppPreferences 导出 PROJECT_COLLAPSED_KEY',
  prefsSrc.includes("export const PROJECT_COLLAPSED_KEY: string = 'aaProjectCollapsed';"));
check('R38 install() 把折叠键交给 PersistentStorage（漏了就会冷启动丢折叠）',
  prefsSrc.includes('PersistentStorage.persistProp<string>(PROJECT_COLLAPSED_KEY,'));
check('R38 HomeScreen 的 COLLAPSED_KEY 引用同一常量（键名只有一个来源，避免两处漂移）',
  homeSrc.includes('const COLLAPSED_KEY: string = PROJECT_COLLAPSED_KEY;'));

// ---------------------------------------------------------------------------
// R55：项目行顺序固定（首页「项目频繁跳动」）
//
// 用户报的 bug（原话）：「当有多个工作区多个对话时，手机软件首页项目会频繁跳动闪屏，应该是
// 刷新会话导致，尝试将项目和 DSH 本地对齐固定，避免频繁跳动」。
//
// 根因：项目行顺序 = `sortProjectsByActivity`（最近活动倒序），而活动时间由服务端在**每次会话
// 更新**时推进；客户端在**每次 notify**（WS 全量快照 / HTTP 刷新）都重算一次 ⇒ 两个及以上
// 工作区**交替**产生活动时，行就会来回换位（模拟器 + mock 轮转夹具实测：9 次采样里换了 4 次）。
//
// 锚文：model/HomeGrouping.ets 的 stabilizeProjectOrder / buildProjectRows 第 5 参；
//       ui/screens/HomeScreen.ets 的 projectOrder / pull() / onRefresh()。
// ---------------------------------------------------------------------------

/** 项目行的 id 字段叫 `projectId`（不是 `id`）—— `ids()` 是会话行用的，别混。 */
function r55RowIds(rows) {
  return rows.map((row) => row.projectId).join(',');
}

group('R55-1：stabilizeProjectOrder —— 固定顺序的规则');
const r55P1 = proj('p1');
const r55P2 = proj('p2');
const r55P3 = proj('p3');
eq('R55 空 previousOrder ⇒ 完全按规范顺序（= 改前行为，老调用方不受影响）',
  ids(grouping.stabilizeProjectOrder([], [r55P1, r55P2, r55P3])), 'p1,p2,p3');
eq('R55 已有项目保持上次的相对顺序',
  ids(grouping.stabilizeProjectOrder(['p2', 'p1'], [r55P1, r55P2])), 'p2,p1');
eq('R55 规范顺序整体反转后，固定顺序逐项不变',
  ids(grouping.stabilizeProjectOrder(['p2', 'p1'], [r55P2, r55P1])), 'p2,p1');
eq('R55 新项目（规范序最前）插到最前',
  ids(grouping.stabilizeProjectOrder(['p1', 'p2'], [r55P3, r55P1, r55P2])), 'p3,p1,p2');
eq('R55 新项目（规范序居中）插到中间',
  ids(grouping.stabilizeProjectOrder(['p1', 'p2'], [r55P1, r55P3, r55P2])), 'p1,p3,p2');
eq('R55 新项目（规范序最后）追加到末尾',
  ids(grouping.stabilizeProjectOrder(['p1', 'p2'], [r55P1, r55P2, r55P3])), 'p1,p2,p3');
eq('R55 previousOrder 里的幽灵 id 被忽略（不占位）',
  ids(grouping.stabilizeProjectOrder(['ghost', 'p2', 'p1'], [r55P1, r55P2])), 'p2,p1');
eq('R55 previousOrder 有重复 id 时不报错',
  ids(grouping.stabilizeProjectOrder(['p2', 'p2', 'p1'], [r55P1, r55P2])), 'p2,p1');
const r55PrevIds = ['p2', 'p1'];
const r55CanonProjects = [r55P1, r55P2];
grouping.stabilizeProjectOrder(r55PrevIds, r55CanonProjects);
eq('R55 入参不被修改（纯函数）', r55PrevIds.join(',') + '|' + ids(r55CanonProjects), 'p2,p1|p1,p2');

group('R55-2：buildProjectRows 的顺序往返（页面接线用的就是这一条）');
const r55Sessions = [
  sess('a1', { projectId: 'p1', sortKey: '2026-09-20T00:00:00Z' }),
  sess('b1', { projectId: 'p2', sortKey: '2026-09-21T00:00:00Z' })
];
const r55Projects = [
  proj('p1', { lastActivityAt: '2026-09-20T00:00:00Z' }),
  proj('p2', { lastActivityAt: '2026-09-21T00:00:00Z' })
];
const r55First = grouping.buildProjectRows(r55Projects, r55Sessions, F.ACTIVE, []);
eq('R55 首次（previousOrder 空）按活动倒序：p2 在前', r55RowIds(r55First.regular), 'p2,p1');
eq('R55 返回的 order 覆盖全部项目', r55First.order.join(','), 'p2,p1');
// 活动翻转（等价于服务端推来一份「p1 刚更新过」的快照）
const r55Rotated = [
  proj('p1', { lastActivityAt: '2026-09-22T00:00:00Z' }),
  proj('p2', { lastActivityAt: '2026-09-21T00:00:00Z' })
];
const r55Naive = grouping.buildProjectRows(r55Rotated, r55Sessions, F.ACTIVE, []);
eq('R55 正对照：不传 previousOrder 时顺序**真的会**按活动翻转（固定不是「数据没变」）',
  r55RowIds(r55Naive.regular), 'p1,p2');
const r55Frozen = grouping.buildProjectRows(r55Rotated, r55Sessions, F.ACTIVE, [], r55First.order);
eq('R55 传回 order 后：活动翻转也不换位', r55RowIds(r55Frozen.regular), 'p2,p1');
eq('R55 传回后 order 仍是原顺序（可继续往下一轮传）', r55Frozen.order.join(','), 'p2,p1');
let r55Stable = r55First.order;
let r55Moved = false;
for (let i = 0; i < 5; i++) {
  const r55Flip = i % 2 === 0 ? r55Rotated : r55Projects;
  const r55Next = grouping.buildProjectRows(r55Flip, r55Sessions, F.ACTIVE, [], r55Stable);
  if (r55Next.order.join(',') !== r55Stable.join(',')) { r55Moved = true; }
  r55Stable = r55Next.order;
}
check('R55 交替活动连推 5 次：顺序一次都没变', r55Moved === false);

group('R55-3：切筛选档不打乱顺序（本档不渲染的项目也在 order 里）');
const r55MixedProjects = [proj('p1'), proj('p2'), proj('p3')];
const r55MixedSessions = [
  sess('a1', { projectId: 'p1', sortKey: '2026-09-20T00:00:00Z' }),
  sess('b1', { projectId: 'p2', sortKey: '2026-09-21T00:00:00Z' }),
  sess('c1', { projectId: 'p3', archived: true, sortKey: '2026-09-19T00:00:00Z' })
];
const r55Active = grouping.buildProjectRows(r55MixedProjects, r55MixedSessions, F.ACTIVE, []);
eq('R55 活跃档不渲染只有归档会话的 p3', r55RowIds(r55Active.regular), 'p2,p1');
eq('R55 但 p3 仍在 order 里（切回去时回到原位）', r55Active.order.join(','), 'p2,p1,p3');
const r55Archived = grouping.buildProjectRows(
  r55MixedProjects, r55MixedSessions, F.ARCHIVED, [], r55Active.order);
eq('R55 已归档档只渲染 p3', r55RowIds(r55Archived.regular), 'p3');
eq('R55 两档共用同一份 order', r55Archived.order.join(','), 'p2,p1,p3');

group('R55-4：页面接线（源码锚文 —— 漏任何一处都会退回「每次快照重排」）');
check('R55 HomeScreen 有 projectOrder 字段（非渲染依赖）',
  homeSrc.includes('private projectOrder: string[] = [];'));
check('R55 pull() 把上次顺序传回 buildProjectRows',
  homeSrc.includes('this.filter, this.collapsedIds,\n      this.projectOrder);'));
check('R55 pull() 记下本次顺序', homeSrc.includes('this.projectOrder = rows.order;'));
check('R55 下拉刷新清掉固定顺序（用户主动要求重排的唯一入口）',
  homeSrc.includes('this.projectOrder = [];'));
check('R55 HomeGrouping 暴露 stabilizeProjectOrder',
  groupingSrc.includes('export function stabilizeProjectOrder('));
check('R55 buildProjectRows 第 5 参默认空数组（老调用方语义不变）',
  groupingSrc.includes('previousOrder: string[] = []'));

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-home: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-home: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ✗ ' + item);
}
process.exit(1);
