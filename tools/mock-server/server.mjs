#!/usr/bin/env node
/**
 * Agents Anywhere v2 **本地模拟服务端**（零依赖，只用 node 内置模块）。
 *
 * 用途：真机验收。`aa-hm` 是纯原生客户端，登录之后的链路（工作台 → 会话详情 → 审批 →
 * 终端 → 文件）需要账号下有一台在线 Connector 才能走到；没有真实账号时，
 * 用这个模拟服务端把同一套 `/api/v2` 契约在局域网内提供出来，
 * 就能在真机上把**全部核心链路**跑通并截图，且数据是确定性的。
 *
 * 它同时也是「协议实现对不对」的对照物：端点、字段名、实时事件名、终端帧格式
 * 都按 `specs/01-api-spec.md` 写；客户端哪一步解析错了，这里立刻能看出来。
 *
 * 用法：
 *   node tools/mock-server/server.mjs [--host 192.168.100.134] [--port 8787]
 *                                    [--ruler] [--fail-attachments] [--page-size N]
 *   `--ruler`            终端回放改用带行号的刻度内容（核对行列映射）
 *   `--fail-attachments` 附件下载固定返回 500（验收「失败不无限重试」）
 *   `--page-size N`      开启 `GET /sessions` 真分页（夹具）：额外造一批「分页会话 A01…」，
 *                        响应按 limit/cursor 真切片并给 hasMore/nextCursor，WS 快照的
 *                        sessionPages 同步反映「还有更多页」。不传时行为与历史完全一致。
 * 然后把 App 的服务器地址填 `http://<host>:<port>`，登录用任意邮箱 + 任意非空密码。
 *
 * 安全：默认只绑**本机局域网 IP**（不是 0.0.0.0），且只提供假数据、不落盘、
 * 不读本地文件；验收结束请立即停止进程。
 */

import http from 'node:http';
import crypto from 'node:crypto';
import os from 'node:os';

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------

function argValue(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : fallback;
}

function detectLanHost() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const info of interfaces[name] ?? []) {
      if (info.family === 'IPv4' && !info.internal) {
        return info.address;
      }
    }
  }
  return '127.0.0.1';
}

/**
 * `--input-request`：把审批卡换成**提问表单**（见 `questionNotice`）。默认关闭，不传时行为与历史一致。
 */
const INPUT_REQUEST = process.argv.includes('--input-request');

const HOST = argValue('--host', detectLanHost());
const PORT = Number.parseInt(argValue('--port', '8787'), 10);
/** `--ruler`：终端改用带行号的刻度内容，便于核对行列映射。 */
const RULER = process.argv.includes('--ruler');
/**
 * `--fail-attachments`：让附件下载确定性地返回 500。
 * 用于验收「失败后不再无限重试」这条修复（见附件 GET 处理处注释）。
 */
const FAIL_ATTACHMENTS = process.argv.includes('--fail-attachments');
/**
 * `--no-archived`：`GET /sessions?archived=true` 一律返回空。
 *
 * 为什么需要它：已归档页有**两个**空态（未筛选 / 已按项目筛选），文案不同
 * （上游 `archived_empty`「暂无已归档会话」/ `archive_project_empty`「这个项目还没有归档会话」）。
 * 不把归档侧清空就没法在设备上看到它们 —— 而只看代码是证明不了「页面真的渲染了这句」的。
 */
const NO_ARCHIVED = process.argv.includes('--no-archived');
/**
 * `--multi-projects`：额外造 2 个**未置顶**项目与它们的会话。
 *
 * 为什么需要它：默认夹具只有一个**已置顶**项目（`project.pinned = true`），首页「项目」
 * 分组恒为「暂无项目。」—— 「项目分组默认展开（默认全部加载）」这条行为在默认夹具下
 * 根本不可达，截图证明不了任何事。开关默认关，不传时端点行为与历史逐字节一致。
 */
const MULTI_PROJECTS = process.argv.includes('--multi-projects');
/**
 * `--heavy-session N`：给会话时间线追加 N 条**内容很重**的历史消息（R45 新增，默认 0 = 关闭）。
 *
 * 为什么需要它：真机上「几百条消息的会话进入后整屏空白」（见开发期验证记录）
 * 用 `--long-session 300` **复现不了** —— 那个夹具是简单单行消息，300 条一帧就测量完。
 * 本夹具每条含长段落 + 代码块 + 表格，单条高度接近真实回复，才能把「首帧未测量」逼出来。
 * 不传时端点行为与历史逐字节一致。
 */
const HEAVY_SESSION = (() => {
  const i = process.argv.indexOf('--heavy-session');
  if (i < 0) { return 0; }
  const v = Number.parseInt(process.argv[i + 1], 10);
  return Number.isFinite(v) && v > 0 ? v : 0;
})();
/**
 * `--long-session N`：给会话时间线追加 N 条历史消息（R43 新增，默认 0 = 关闭）。
 * 为什么需要它：性能/流畅性基线（用户需求④）必须有一条**几百条历史**的会话来量首帧耗时与内存占用；
 * 默认夹具只有 6 条 item，任何差异都会被噪声淹没。不传时端点行为与历史逐字节一致。
 */
const LONG_SESSION = (() => {
  const i = process.argv.indexOf('--long-session');
  if (i < 0) { return 0; }
  const v = Number.parseInt(process.argv[i + 1], 10);
  return Number.isFinite(v) && v > 0 ? v : 0;
})();
/**
 * `--session-churn N`：会话 WS 握手后按 **N 次/秒**推**内容逐字节相同**的 `timeline.item_updated`。
 *
 * 为什么需要它：客户端对 WS 事件做合批，合批后的重投影路径才是「全量投影（改前）vs 增量投影（改后）」
 * 的差异所在 —— 打开会话那一次投影两者相近，只有**高频更新**才体现得出来。不传时行为与历史一致。
 */
const SESSION_CHURN = (() => {
  const i = process.argv.indexOf('--session-churn');
  if (i < 0) { return 0; }
  const v = Number.parseInt(process.argv[i + 1], 10);
  return Number.isFinite(v) && v > 0 ? v : 0;
})();
/**
 * `--dashboard-churn N`：工作台 WS 握手后，按 **N 次/秒**持续重推**内容完全相同**的
 * `dashboard.snapshot`（客户端把它当 `dashboard.changed` 处理）。
 *
 * 为什么需要它：默认夹具只在握手时推一次快照，于是「刷新时界面闪一下」这类缺陷在设备上
 * **根本复现不出来** —— 没有刷新事件可看。有了它，验收可以断言：
 * 「同一份快照连推 N 次期间，可见行的 bounds 逐字节不变、帧差 MAE 不超阈值」，
 * 并且能配一个阳性对照（改一条会话标题再推，必须测出显著差异），避免「两相都是 0」的假 PASS。
 * 默认 0 = 关闭，不传时端点行为与历史逐字节一致。
 */
const DASHBOARD_CHURN_ARG = Number.parseInt(argValue('--dashboard-churn', '0'), 10);
const DASHBOARD_CHURN = Number.isInteger(DASHBOARD_CHURN_ARG) && DASHBOARD_CHURN_ARG > 0 ? DASHBOARD_CHURN_ARG : 0;
/**
 * `--dashboard-order-churn N`：工作台 WS 握手后，按 **N 次/秒**让两个**未置顶项目**交替
 * 成为「最近活动」并推一份**内容真的在变**的快照（只有活动时间在变）。
 *
 * 为什么需要它：真实服务端 `list_projects()` 按**最近活动倒序**排；客户端首页用同一口径
 * （`sortProjectsByActivity`）在**每次快照**都重算项目行顺序 —— 于是「多个工作区交替产生活动」
 * 时项目行会来回换位（用户报的「首页项目频繁跳动」）。既有夹具复现不出这一类：
 * `--dashboard-churn` 推的是**同一份**内容（数据没变），默认夹具更是只推一次。
 * 需与 `--multi-projects` 同用（否则只有一个未置顶项目、换不出顺序）。
 * 默认 0 = 关闭，不传时端点行为与历史逐字节一致。
 */
const DASHBOARD_ORDER_CHURN_ARG = Number.parseInt(argValue('--dashboard-order-churn', '0'), 10);
const DASHBOARD_ORDER_CHURN =
  Number.isInteger(DASHBOARD_ORDER_CHURN_ARG) && DASHBOARD_ORDER_CHURN_ARG > 0
    ? DASHBOARD_ORDER_CHURN_ARG
    : 0;
/**
 * `--page-size N`：开启 `GET /sessions` 的**真分页**（分页夹具，见下方「分页夹具」一节）。
 * 不传（或非正数）时 `PAGINATED=false`，端点行为与历史逐字节一致，不影响既有冒烟流程。
 */
const PAGE_SIZE_ARG = Number.parseInt(argValue('--page-size', '0'), 10);
const PAGE_SIZE = Number.isInteger(PAGE_SIZE_ARG) && PAGE_SIZE_ARG > 0 ? PAGE_SIZE_ARG : 0;
const PAGINATED = PAGE_SIZE > 0;

// ---------------------------------------------------------------------------
// 固定假数据（确定性，便于截图与断言）
// ---------------------------------------------------------------------------

const NOW = () => new Date().toISOString();
const TOKEN = 'mock-access-token';
const CONNECTOR_ID = 'conn-mock-0001';
const PROJECT_ID = 'proj-mock-0001';
const SESSION_ID = 'sess-mock-0001';
const NOTICE_ID = 'notice-mock-0001';

const connector = {
  id: CONNECTOR_ID,
  name: 'MacBook Pro（模拟）',
  deviceOs: 'macos',
  status: 'online',
  lastSeenAt: NOW(),
  createdAt: '2026-09-01T00:00:00Z',
  updatedAt: NOW()
};

// ---------------------------------------------------------------------------
// Windows 设备夹具（启动加 --win-device 才挂上来）
// ---------------------------------------------------------------------------
// 为什么需要：只有 deviceOs === 'windows' 的设备才会走到「盘符总览（这台电脑）」这条分支 ——
// 上游 `initialRemoteFilePath(deviceOs)`：Windows 的初始 path 是**空串**，服务端在 `path == ''`
// 时返回 `C:` `D:` `E:`（`connector/local/file_ops.py` 的 `_windows_drive_entries()`）。
// 主夹具是 macOS，这条分支在模拟器上**永远走不到**，于是「文件页有没有盘符总览」
// 一直只有安卓侧证据（R12 遗留清单第 4 项）。与 R14 补的运行时能力路由同源：
// 夹具的洞会让一整块 UI 退出验证范围（「页面没报错」不等于「页面验过」）。
//
// 路径一律用**正斜杠**：客户端 `windowsDriveRoot()` 的正则是 `^([A-Za-z]:)(?:[\\/].*)?$`，
// 两种分隔符都吃；正斜杠还能免掉源码里的反斜杠转义。
const WINDOWS_CONNECTOR_ID = 'conn-mock-win';
const windowsConnector = {
  id: WINDOWS_CONNECTOR_ID,
  name: 'Windows 台式机（模拟）',
  deviceOs: 'windows',
  status: 'online',
  lastSeenAt: NOW(),
  createdAt: '2026-09-05T00:00:00Z',
  updatedAt: NOW()
};
const WINDOWS_DRIVES = ['C:', 'D:', 'E:'];
/**
 * 夹具用户名：模拟的是「Windows 上的普通用户」，与任何真实机器无关。
 * 早期版本把作者本机的用户名写死在这里，开源后既无意义、又会把本机信息带出去；
 * 需要换成别的用户名时用环境变量 `AA_MOCK_WIN_USER` 覆盖即可（`~` 展开也走它）。
 */
const WINDOWS_USER = (process.env.AA_MOCK_WIN_USER || 'mock').trim() || 'mock';
const WINDOWS_HOME = 'C:/Users/' + WINDOWS_USER;
const WINDOWS_FILES = new Map([
  [WINDOWS_HOME + '/notes.txt', 'Windows 夹具：C 盘记事本。'],
  [WINDOWS_HOME + '/code/demo.py', 'print("hello from windows fixture")'],
  ['C:/Program Files/7-Zip/7z.exe', 'MZ (binary placeholder)'],
  ['D:/备份/archive-2026.zip', 'PK (binary placeholder)'],
  ['E:/工作区/README.md', '# 工作区（Windows 夹具）']
]);

/** Windows 设备的目录列举。语义逐条对齐上游 `connector/local/file_ops.py` 的 `read_dir`。
 *
 * ⚠️ 两条**参数语义**都不能省（R14 实测踩到）：
 *  ① `path == ''` 才是**盘符总览**（上游只在 path 为空时给 `_windows_drive_entries()`）；
 *  ② `path == '.'` 表示**按 root 解析**（`resolveHomePath()` 发的就是 `{root:'~', path:'.'}`）。
 *     把 `.` 也当成总览 ⇒ 主目录永远解析不出来 ⇒ 页面显示「主目录 ~」、浏览面板目录行 `~/~`；
 *  ③ `~` 要展开成 `C:/Users/<user>`（上游 `os.path.expanduser`）。
 * 夹具**实现了接口但没实现参数语义**时，症状看起来完全像应用缺陷（与上一条同源）。
 */
function windowsEntries(requestPath, rootPath) {
  // 分隔符先全部归一到正斜杠：Windows 客户端回传的是 `C:\Users\mock` 这样的反斜杠形态，
  // 而虚拟树的 key 是正斜杠形态 —— 不归一就会「明明有文件却显示这个目录是空的」。
  const norm = (value) => String(value === undefined || value === null ? '' : value).trim().split('\\').join('/');
  const rawPath = norm(requestPath);
  const rawRoot = norm(rootPath);
  const drives = () => ({
    path: '',
    entries: WINDOWS_DRIVES.map((name) => ({ name: name, path: name + '/', type: 'directory' }))
  });
  if (rawPath.length === 0) {
    return drives();
  }
  let raw = rawPath === '.' ? rawRoot : rawPath;
  if (raw === '~' || raw === '~/') {
    raw = WINDOWS_HOME;
  }
  if (raw.length === 0 || raw === '.') {
    return drives();
  }
  const drive = /^([A-Za-z]):/.exec(raw);
  if (drive === null) {
    return { path: raw, entries: [] };
  }
  const letter = drive[1].toUpperCase();
  const rest = raw.substring(2).replace(/^[\\/]+/, '').replace(/[\\/]+$/, '');
  const prefix = rest.length > 0 ? letter + ':/' + rest + '/' : letter + ':/';
  const base = rest.length > 0 ? letter + ':/' + rest + '/' : letter + ':/';
  const dirs = new Set();
  const files = [];
  for (const key of WINDOWS_FILES.keys()) {
    if (!key.startsWith(prefix)) {
      continue;
    }
    const tail = key.substring(prefix.length);
    const slash = tail.indexOf('/');
    if (slash >= 0) {
      dirs.add(tail.substring(0, slash));
    } else {
      files.push({ name: tail, path: base + tail, type: 'file', size: WINDOWS_FILES.get(key).length });
    }
  }
  files.sort((a, b) => (a.name < b.name ? -1 : 1));
  const entries = [...dirs].sort().map((name) => ({ name: name, path: base + name, type: 'directory' }));
  return { path: rest.length > 0 ? letter + ':/' + rest : letter + ':/', entries: entries.concat(files) };
}

// ---------------------------------------------------------------------------
// 配对新设备夹具（R8）
// ---------------------------------------------------------------------------
// 为什么需要：claimPairing / revokeDevice / archive-all 这三条路径在鸿蒙端
// 第八轮之前没有 UI 调用点，模拟服务端也就一直没有实现，于是「配对新设备」
// 只有 UI 没有后端、无法端到端验收。
// 安全性：只有真的收到 POST /connectors 或 POST /pairing/claim 才会往列表里
// 加东西 ⇒ 不调用时对既有验收零影响（GET /connectors 内容与历史一致）。
const extraConnectors = [];
let pairedCounter = 0;

/**
 * 主设备 + 所有被配对 / 创建出来的设备。
 *
 * `--no-devices` 时返回空数组 —— 用于验收「没有可用设备/Agent」时的**设置面板**
 * （`NewSessionSetupPanel`）：那个分支在正常夹具下永远打不到，因为 mock 总有设备。
 */
function allConnectors() {
  if (process.argv.includes('--no-devices')) {
    return [];
  }
  const list = [connector, ...extraConnectors];
  // `--win-device`：额外挂一台 Windows 设备（默认不开，零影响既有验收）。
  if (process.argv.includes('--win-device')) {
    list.push(windowsConnector);
  }
  return list;
}

function findConnector(id) {
  if (id === connector.id) {
    return connector;
  }
  if (id === WINDOWS_CONNECTOR_ID) {
    return windowsConnector;
  }
  return extraConnectors.find((item) => item.id === id);
}

/** 配对码归一：去空白、转大写（夹具只接受 6 位字母数字）。 */
function normalizePairingCode(raw) {
  return String(raw ?? '').replace(/\s+/g, '').toUpperCase();
}

function isValidPairingCode(code) {
  return /^[A-Z0-9]{6}$/.test(code);
}

const project = {
  id: PROJECT_ID,
  userId: 'user-mock',
  connectorId: CONNECTOR_ID,
  name: 'agents-anywhere',
  workspacePath: '/Users/mock/code/agents-anywhere',
  pinned: true,
  activeSessionCount: 2,
  lastActivityAt: NOW(),
  createdAt: '2026-09-01T00:00:00Z',
  updatedAt: NOW(),
  manuallyCreated: false,
  sidebarSessionCounts: { active: 2, archived: 1 }
};

/** `--multi-projects` 追加的两个**未置顶**项目（首页「项目」分组的默认展开验收用）。 */
const PROJECT_ID_2 = 'proj-mock-0002';
const PROJECT_ID_3 = 'proj-mock-0003';
const extraProjects = MULTI_PROJECTS
  ? [
    {
      id: PROJECT_ID_2,
      userId: 'user-mock',
      connectorId: CONNECTOR_ID,
      name: 'harmony-shell',
      workspacePath: '/Users/mock/code/harmony-shell',
      pinned: false,
      activeSessionCount: 2,
      lastActivityAt: NOW(),
      createdAt: '2026-09-02T00:00:00Z',
      updatedAt: NOW(),
      manuallyCreated: false,
      sidebarSessionCounts: { active: 2, archived: 0 }
    },
    {
      id: PROJECT_ID_3,
      userId: 'user-mock',
      connectorId: CONNECTOR_ID,
      name: 'vt-terminal',
      workspacePath: '/Users/mock/code/vt-terminal',
      pinned: false,
      activeSessionCount: 2,
      lastActivityAt: NOW(),
      createdAt: '2026-09-03T00:00:00Z',
      updatedAt: NOW(),
      manuallyCreated: false,
      sidebarSessionCounts: { active: 2, archived: 0 }
    }
  ]
  : [];

/** `GET /projects` 与 dashboard 快照共用的项目表。 */
const projects = [project, ...extraProjects];

function session(id, title, status, extra = {}) {
  return {
    id,
    connectorId: CONNECTOR_ID,
    projectId: PROJECT_ID,
    connectorStatus: 'online',
    runtime: 'codex',
    runtimeType: 'codex',
    runtimeId: 'codex',
    runtimeName: 'codex',
    externalSessionId: id,
    title,
    cwd: '/Users/mock/code/agents-anywhere',
    status,
    takeover: false,
    pinned: false,
    archived: false,
    unread: false,
    lastReadSeq: 0,
    updatedSeq: 10,
    lastActivityAt: NOW(),
    sortAt: NOW(),
    ...extra
  };
}

const sessions = [
  session(SESSION_ID, '修复登录页闪烁', 'waiting_approval'),
  // R13-27：让这条会话的 cwd **不等于** homePath，用于验证「最近使用的工作目录」列表非空
  // （上游 recentWorkspacePaths 第 ④ 步会把等于 homePath 的那条滤掉）。
  session('sess-mock-0002', '给终端加宽字符支持', 'running',
    { cwd: '/Users/mock/code/agents-anywhere/scripts' }),
  session('sess-mock-0003', '写 API 契约文档', 'idle'),
  session('sess-mock-0004', '已归档：老的构建脚本清理', 'idle',
    { archived: true, archivedAt: '2026-09-10T00:00:00Z' })
];

// `--multi-projects`：两个未置顶项目各配 2 条会话 —— 分组展开后必须**当场看见**会话行，
// 否则「默认展开」与「展开了但没内容」在截图上是同一张图（证据就失去区分力）。
if (MULTI_PROJECTS) {
  sessions.push(
    session('sess-mock-p2-01', '重构发送按钮', 'idle',
      { projectId: PROJECT_ID_2, cwd: '/Users/mock/code/harmony-shell' }),
    session('sess-mock-p2-02', '输入区毛玻璃', 'running',
      { projectId: PROJECT_ID_2, cwd: '/Users/mock/code/harmony-shell/entry' }),
    session('sess-mock-p3-01', 'VT 终端配色', 'idle',
      { projectId: PROJECT_ID_3, cwd: '/Users/mock/code/vt-terminal' }),
    session('sess-mock-p3-02', '宽字符对齐', 'idle',
      { projectId: PROJECT_ID_3, cwd: '/Users/mock/code/vt-terminal/src' })
  );
}

// ---------------------------------------------------------------------------
// 分页夹具（`--page-size N`）
// ---------------------------------------------------------------------------

/** 开了 `--page-size` 时额外造的活动 / 已归档会话条数（各占若干页）。 */
const PAGE_EXTRA_ACTIVE = 8;
const PAGE_EXTRA_ARCHIVED = 5;
const SESSION_CURSOR_PREFIX = 'offset:';

/**
 * 造一条「分页会话 A01 / R01」：标题有规律，验收可以直接断言它出现在第几页。
 * ⚠️ 它们和主夹具一起放进 `sessions`，所以 `/sessions/{id}` / `/meta` / `/snapshot` /
 * `/timeline` 都能命中（从列表点进去不会 404）。
 */
function pageSession(ordinal, archived) {
  const tag = archived ? 'R' : 'A';
  const no = String(ordinal).padStart(2, '0');
  const stamp = '2026-09-' + String(10 + ordinal).padStart(2, '0') + 'T00:00:00Z';
  const extra = {
    archived: archived,
    updatedSeq: 200 + ordinal,
    lastActivityAt: stamp,
    sortAt: stamp
  };
  if (archived) {
    extra.archivedAt = '2026-09-05T00:00:00Z';
  }
  return session('sess-page-' + tag.toLowerCase() + '-' + no, '分页会话 ' + tag + no, 'idle', extra);
}

if (PAGINATED) {
  for (let i = 1; i <= PAGE_EXTRA_ACTIVE; i++) {
    sessions.push(pageSession(i, false));
  }
  for (let i = 1; i <= PAGE_EXTRA_ARCHIVED; i++) {
    sessions.push(pageSession(i, true));
  }
}

/** `limit` 参数：非正数 / 非法一律回落到 100（与上游默认值一致）。 */
function parseSessionLimit(raw) {
  const value = raw === null ? Number.NaN : Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : 100;
}

/** 解析 `cursor=offset:N`；空串 = 第一页；格式不对返回 null（路由回 400，别把坏游标静默吞掉）。 */
function parseSessionCursor(cursor) {
  if (cursor === null || cursor.length === 0) {
    return 0;
  }
  if (!cursor.startsWith(SESSION_CURSOR_PREFIX)) {
    return null;
  }
  const raw = cursor.slice(SESSION_CURSOR_PREFIX.length);
  if (!/^\d+$/.test(raw)) {
    return null;
  }
  return Number.parseInt(raw, 10);
}

/**
 * 一次分页切片的响应体，契约与上游 `SessionsApi.kt` 的 `RemoteSessionPage` 一致：
 * `{sessions, hasMore, nextCursor}`；最后一页 `hasMore=false` 且 `nextCursor=null`。
 */
function sessionPageOf(list, offset, limit) {
  const slice = list.slice(offset, offset + limit);
  const consumed = offset + slice.length;
  const hasMore = consumed < list.length;
  return {
    sessions: slice,
    hasMore: hasMore,
    nextCursor: hasMore ? SESSION_CURSOR_PREFIX + consumed : null,
    total: list.length,
    offset: offset
  };
}

const timelineItems = [
  {
    id: 'item-1', sessionId: SESSION_ID, type: 'message', status: 'done', role: 'user',
    orderSeq: 1, revision: 1, updatedSeq: 1, createdAt: '2026-09-14T10:00:00Z',
    content: { text: '登录页在连接服务器后会闪一下，帮我查一下。' }, source: {}
  },
  {
    id: 'item-2', sessionId: SESSION_ID, type: 'message', status: 'done', role: 'assistant',
    orderSeq: 2, revision: 1, updatedSeq: 2, createdAt: '2026-09-14T10:00:05Z',
    content: {
      text: [
        '我先看一下渲染依赖。ArkUI 的状态是**读时登记**的：',
        '',
        '```ts',
        '// 状态必须在 build 里被读到才会登记依赖',
        'const MAX: number = 42;',
        '@State messages: TimelineMessage[] = [];',
        'private pull(): void {',
        '  this.messages = this.store.messages.slice();',
        '}',
        'build() { ForEach(this.messages, (m) => this.row(m)) }',
        '```',
        '',
        '顺带把构建脚本也核对了：',
        '',
        '```bash',
        '# 直接调 hvigorw，别经 cmd 包装',
        'export DEVECO_SDK_HOME="<DevEco 安装目录>/sdk"',
        'node hvigorw.js --mode module -p product=default assembleHap --no-daemon',
        '```',
        '',
        '这次的补丁：',
        '',
        '```diff',
        '- @State tick: number = 0;',
        '+ @State messages: TimelineMessage[] = [];',
        '@@ -12,3 +12,5 @@',
        '- this.tick = this.tick + 1;',
        '+ this.pull();',
        '```',
        '',
        '数据库那边顺手确认一句：',
        '',
        '```sql',
        'SELECT id, title FROM sessions WHERE archived = false -- 只取活跃会话',
        '```',
        '',
        '正解是把数据拷进 `@State` 字段，build 只读这些字段。'
      ].join('\n')
    },
    source: {}
  },
  {
    id: 'item-3', sessionId: SESSION_ID, type: 'tool', status: 'done',
    orderSeq: 3, revision: 1, updatedSeq: 3, createdAt: '2026-09-14T10:00:10Z',
    source: {},
    content: {
      kind: 'command', command: 'npm test -- --grep "refresh"', cwd: '/Users/mock/code/agents-anywhere',
      exitCode: 0, output: 'PASS  render (12 ms)\nPASS  state-bind (8 ms)\n\nTests: 2 passed, 2 total'
    }
  },
  {
    id: 'item-4', sessionId: SESSION_ID, type: 'tool', status: 'done',
    orderSeq: 4, revision: 1, updatedSeq: 4, createdAt: '2026-09-14T10:00:15Z',
    source: {},
    content: {
      kind: 'file_change',
      changes: [
        { path: 'entry/src/main/ets/ui/screens/LoginScreen.ets', kind: 'update', added: 12, removed: 4 },
        { path: 'entry/src/main/ets/ui/Router.ets', kind: 'update', added: 6, removed: 2 }
      ]
    }
  },
  {
    id: 'item-5', sessionId: SESSION_ID, type: 'message', status: 'done', role: 'assistant',
    orderSeq: 5, revision: 1, updatedSeq: 5, createdAt: '2026-09-14T10:00:20Z',
    content: { text: '改完了。要我把这两个文件提交吗？（需要你确认）' }, source: {}
  },
  {
    // 富 Markdown：表格 / 任务清单 / 嵌套列表 / 分隔线 / 链接 —— 用来验收富块渲染。
    id: 'item-7', sessionId: SESSION_ID, type: 'message', status: 'done', role: 'assistant',
    orderSeq: 7, revision: 1, updatedSeq: 7, createdAt: '2026-09-14T10:00:30Z',
    content: {
      text: [
        '这一轮的验收清单：',
        '',
        '- [x] 核心闭环',
        '- [x] 语法高亮',
        '- [ ] 拍照附件',
        '',
        '改动的模块：',
        '',
        '| 模块 | 状态 | 备注 |',
        '| --- | :--: | --- |',
        '| 登录 | 完成 | 已复验 |',
        '| 终端 | 进行中 | 宽字符 |',
        '| 文件 | 完成 | 可预览 |',
        '',
        '依赖关系：',
        '',
        '- 协议层',
        '  - 会话与工作台',
        '    - 终端 / 文件',
        '- 渲染层',
        '',
        '---',
        '',
        '参考 [验收文档](https://example.com/docs/verify) 与 [接口契约](https://example.com/docs/api)。'
      ].join(String.fromCharCode(10))
    },
    source: {}
  },
  {
    // 带附件的消息：一张图（内联渲染）+ 一个文本文件（文件名条），
    // 用来验收「附件内联渲染」——不需要系统文件选择器参与。
    id: 'item-6', sessionId: SESSION_ID, type: 'message', status: 'done', role: 'user',
    orderSeq: 6, revision: 1, updatedSeq: 6, createdAt: '2026-09-14T10:00:25Z',
    content: {
      text: '这两个附件你看一下：终端截图和构建注意事项。',
      attachments: [
        {
          fileId: 'file-mock-img1', name: 'terminal-screenshot.png', mediaType: 'image/png',
          size: 625
        },
        { fileId: 'file-mock-doc1', name: 'build-notes.txt', mediaType: 'text/plain', size: 68 }
      ]
    },
    source: {}
  }
];

// `--heavy-session N`：追加 N 条**高**消息（长段落 + 代码块 + 表格），单条高度接近真实回复。
// 与 `--long-session` 的区别就在「单条高度」—— 真机缺陷正是被「内容总高度很大」逼出来的。
if (HEAVY_SESSION > 0) {
  const L = String.fromCharCode(10);
  for (let i = 1; i <= HEAVY_SESSION; i++) {
    const seq = 5000 + i;
    const isUser = i % 2 === 1;
    const body = isUser
      ? ('历史消息 ' + i + '：请把第 ' + i + ' 段逻辑再核对一遍，并给出结论。' + L
        + '要求：① 说明根因；② 给判据；③ 给最小修法；④ 标注未验证项。')
      : ('历史回复 ' + i + '：已核对完毕。' + L + L
        + '**根因**：第 ' + i + ' 段在首帧没有登记渲染依赖，build() 读不到它。' + L + L
        + '```ts' + L
        + 'const N' + i + ': number = ' + i + ';' + L
        + 'function f' + i + '(): void {' + L
        + '  // 占位实现，用于把这一条撑到真实回复的高度' + L
        + '}' + L
        + '```' + L + L
        + '| 项 | 值 |' + L
        + '| --- | --- |' + L
        + '| 序号 | ' + i + ' |' + L
        + '| 状态 | 已复验 |' + L
        + '| 结论 | 与全量投影逐项一致 |' + L + L
        + '补充说明：这一段是夹具生成的长文本，把单条消息的高度撑到与真机会话相当' + L
        + '（几百条 × 每条数百 px）。' + L + L
        + '>' + L
        + '> 引用块：本段走 QUOTE 渲染分支 —— 真机「进入长会话整屏空白」的触发点。' + L
        + '>' + L);
    timelineItems.push({
      id: 'heavy-item-' + i, sessionId: SESSION_ID, type: 'message', status: 'done',
      role: isUser ? 'user' : 'assistant',
      orderSeq: seq, revision: 1, updatedSeq: seq, createdAt: '2026-09-14T12:00:00Z',
      content: { text: body },
      source: {}
    });
  }
}

// `--long-session N`：追加 N 条历史消息（user/assistant 交替，assistant 带代码块）。
// 只改夹具数据、不改端点行为；不传时数组与历史逐字节一致。
if (LONG_SESSION > 0) {
  for (let i = 1; i <= LONG_SESSION; i++) {
    const seq = 100 + i;
    const isUser = i % 2 === 1;
    timelineItems.push({
      id: 'long-item-' + i, sessionId: SESSION_ID, type: 'message', status: 'done',
      role: isUser ? 'user' : 'assistant',
      orderSeq: seq, revision: 1, updatedSeq: seq, createdAt: '2026-09-14T11:00:00Z',
      content: {
        text: isUser
          ? ('历史消息 ' + i + '：请把第 ' + i + ' 段逻辑再核对一遍，并给出结论。')
          : ('历史回复 ' + i + '：已核对完毕。' + String.fromCharCode(10) + String.fromCharCode(10)
            + '```ts' + String.fromCharCode(10) + 'const N' + i + ': number = ' + i + ';' + String.fromCharCode(10) + '```'
            + String.fromCharCode(10) + String.fromCharCode(10) + '要点 ' + i + ' 已记录。')
      },
      source: {}
    });
  }
}

// ⚠️ R57（2026-09-23）夹具修正：这里原本写的是 `type: 'tool_approval'` —— **那是本夹具自造的类型，
// 线上契约里没有它**。协议里公告类型只有两个（见 `model/NoticeGating.ets` 头部引的上游 Kotlin：
// `type == "interaction"` 与 `type == "notification"`），审批属 `interaction` + `interactionType: 'approval'`。
// 症状：R50 把门控从「只看 status==='open'」收紧成上游口径（必须 type==='interaction'）之后，
// 本夹具的审批卡就**再也不渲染**了（模拟器实测：页头有「待审批」，但「需要审批 / 允许 / 拒绝」命中 0），
// 而 R39 的 dump（`r39-slim-verify/dumps/s06-session-detail.json`）里同形状卡片是渲染出来的 —— 正对应 R50 之前。
// ⇒ 这是**测试夹具缺陷**，不是产品缺陷：客户端按上游契约过滤是对的，夹具喂了一个不存在的类型。
// 下面的 `questionNotice`（`--input-request`）一直用的是 `interaction`，两者本就该一致。
const notice = {
  noticeId: NOTICE_ID,
  type: 'interaction',
  sessionId: SESSION_ID,
  source: { runtime: 'codex' },
  title: '需要审批：git commit',
  message: 'Agent 想执行 `git commit -m "fix(login): 修复渲染依赖"`，是否允许？',
  severity: 'warning',
  status: 'open',
  interactionType: 'approval',
  blocking: { scope: 'session', targetId: SESSION_ID },
  responseRequired: true,
  actions: [
    { actionId: 'approve', label: '允许', style: 'primary', input: { required: false } },
    { actionId: 'deny', label: '拒绝', style: 'danger', input: { required: false } },
    {
      actionId: 'edit', label: '改一下再执行', style: 'secondary',
      input: { required: true, schema: { type: 'object', properties: { value: { type: 'string' } } } }
    }
  ],
  context: {},
  metadata: {},
  revision: 1,
  updatedSeq: 6,
  createdAt: '2026-09-14T10:00:21Z'
};

/**
 * `--input-request`：把审批卡换成**提问表单**（R50 新增）。
 *
 * 形状**逐字对齐真实链路**，不是自造：
 *  · `interactionType: 'input_request'`、`actions[0].actionId = 'submit'`、
 *    `input.uiSchema = { component: 'inputRequest', version: 1, questions: [...] }`
 *    —— 出处 `connector/connector/runtime_protocol/interactions.py` 的 `InputRequestForm.action()`
 *    （DSH 侧 `connector/runtimes/claude/domain/input_requests.py` 也是同一份）。
 *  · `input.required` 是 **true**（`action()` 里写死的），`input.schema` 同步给一份**真** JSON Schema。
 *  · 答案载荷形状（`{ answers: { q_0: { optionIds, customText? } } }`）由
 *    `connector/tests/dsh_question_probe.py` 断言过：`answer = {"answers": {"mode": {...}, ...}}`。
 *
 * 为什么需要它：本工程原先**只实现了 `input.required` 的单框回退**（上游 `inputFields()` 的兜底分支），
 * 而 `input_request` 的**提问表单**（题面 + 选项 + 其他）一条都没实现 ⇒ 真机上「Agent 提问时看不到提问框」。
 */
const questionNotice = {
  noticeId: 'notice-mock-question',
  type: 'interaction',
  sessionId: SESSION_ID,
  source: { component: 'claude.ask_user_question' },
  title: 'Claude needs your input',
  severity: 'info',
  status: 'open',
  interactionType: 'input_request',
  blocking: { scope: 'session', targetId: SESSION_ID },
  responseRequired: true,
  actions: [
    {
      actionId: 'submit', label: 'Submit', style: 'primary',
      input: {
        required: true,
        schema: {
          type: 'object',
          required: ['answers'],
          properties: {
            answers: {
              type: 'object',
              required: ['q_0', 'q_1'],
              properties: {
                q_0: {
                  type: 'object',
                  properties: {
                    optionIds: { type: 'array', uniqueItems: true, items: { type: 'string', enum: ['o_0', 'o_1', 'o_2'] }, maxItems: 1 },
                    customText: { type: 'string' }
                  },
                  additionalProperties: false
                },
                q_1: {
                  type: 'object',
                  properties: {
                    optionIds: { type: 'array', uniqueItems: true, items: { type: 'string', enum: ['o_0', 'o_1'] } },
                    customText: { type: 'string' }
                  },
                  additionalProperties: false
                }
              },
              additionalProperties: false
            }
          },
          additionalProperties: false
        },
        uiSchema: {
          component: 'inputRequest',
          version: 1,
          questions: [
            {
              id: 'q_0',
              header: '范围',
              prompt: '这一轮先改哪个页面？',
              multiple: false,
              allowCustom: true,
              options: [
                { id: 'o_0', label: '会话详情页', description: '时间线与输入区' },
                { id: 'o_1', label: '首页' },
                { id: 'o_2', label: '设置页' }
              ]
            },
            {
              id: 'q_1',
              prompt: '顺带一起做的（可多选）',
              multiple: true,
              allowCustom: true,
              options: [
                { id: 'o_0', label: '补逻辑自测' },
                { id: 'o_1', label: '更新文档' }
              ]
            }
          ]
        }
      }
    },
    { actionId: 'cancel', label: 'Cancel', style: 'secondary' }
  ],
  context: {
    inputStatus: 'pending', requestKind: 'questionnaire',
    turnId: 'turn-mock-0001', toolName: 'AskUserQuestion'
  },
  metadata: { source: 'claude.ask_user_question' },
  revision: 1,
  updatedSeq: 7,
  createdAt: '2026-09-14T10:00:22Z'
};

/** `--input-request` 时对外暴露的公告列表（默认与历史逐字节一致：只有审批卡）。 */
function activeNotices() {
  return INPUT_REQUEST ? [questionNotice] : [notice];
}

const capabilities = {
  revision: 7,
  capabilities: [
    { capabilityId: 'session.interrupt', version: '1', scope: 'session', supported: true, available: true, allowed: true },
    { capabilityId: 'session.takeover', version: '1', scope: 'session', supported: true, available: true, allowed: true },
    { capabilityId: 'session.selections.update', version: '1', scope: 'session', supported: true, available: true, allowed: true },
    { capabilityId: 'catalog.model', version: '1', scope: 'runtime', supported: true, available: true, allowed: true },
    { capabilityId: 'catalog.permission', version: '1', scope: 'runtime', supported: true, available: true, allowed: true },
    // R52：DSH 原生指令（bridge 补丁之后 DSH 也会声明它）。夹具里恒为可用，
    // 这样「指令按钮 → 面板 → 执行」这条链在模拟器上可重复验证。
    { capabilityId: 'session.commands', version: '1', scope: 'session', supported: true, available: true, allowed: true }
  ]
};

/**
 * 连接器级运行时能力集（GET /connectors/{id}/runtimes/{rid}/capabilities）。
 * 与会话级同源，但含 catalog.model / catalog.permission —— 新建会话页的「实时选项」区
 * 正是按这两个 id 决定要不要渲染模型 / 权限选择器（App 侧 NewSessionScreen.ets:2562 的
 * MODEL_CATALOG_CAPABILITY / PERMISSION_CATALOG_CAPABILITY）。早期夹具没实现该路由，
 * 页面只剩一条「无法加载实时选项」错误横幅，那一整块 UI 从未被渲染（等于没验）。
 */
const runtimeCapabilities = capabilities;

const modelCatalog = {
  runtime: 'codex',
  runtimeType: 'codex',
  runtimeId: 'codex',
  revision: 3,
  models: [
    { id: 'gpt-5-codex', selectionId: 'gpt-5-codex', displayName: 'GPT-5 Codex', default: true, reasoningItems: [], metadata: {} },
    { id: 'gpt-5', selectionId: 'gpt-5', displayName: 'GPT-5', default: false, reasoningItems: [], metadata: {} }
  ]
};

const permissionCatalog = {
  runtime: 'codex',
  runtimeType: 'codex',
  runtimeId: 'codex',
  revision: 2,
  permissions: [
    { id: 'read-only', selectionId: 'read-only', displayName: '只读', default: false, metadata: {} },
    { id: 'workspace-write', selectionId: 'workspace-write', displayName: '可写工作区', default: true, metadata: {} }
  ]
};

const commands = [
  { id: 'status', title: '查看状态', description: '显示当前会话状态', aliases: [], scope: 'session', enabled: true, acceptsArgs: false, metadata: {} },
  { id: 'compact', title: '压缩上下文', description: '压缩历史以节省 token', aliases: [], scope: 'session', enabled: true, acceptsArgs: false, metadata: {} }
];

const runtimes = {
  connectorId: CONNECTOR_ID,
  runtimes: [
    {
      connectorId: CONNECTOR_ID, runtimeId: 'codex', runtimeType: 'codex', displayName: 'Codex',
      present: true, configured: true, active: true, status: 'running',
      discovery: {}, metadata: {}, uiSchema: {}, updatedAt: NOW()
    },
    {
      connectorId: CONNECTOR_ID, runtimeId: 'claude', runtimeType: 'claude', displayName: 'Claude Code',
      present: true, configured: true, active: false, status: 'available',
      discovery: {}, metadata: {}, uiSchema: {}, updatedAt: NOW()
    },
    // R51：带 **Agent 预设**的 DSH runtime（形状照真实链路：
    // `uiSchema.defaultAgentPreset` = `{component:'select', options:[{value,label,description?,disabled?,disabledReason?}]}`
    // 出自 DSH provider / bridge；`schema.properties.defaultAgentPreset.default` 是默认值）。
    // 没有这段夹具，「新建会话 → Agent 预设」这条分支在模拟器上永远走不到。
    {
      connectorId: CONNECTOR_ID, runtimeId: 'dsh', runtimeType: 'dsh', displayName: 'DeepSeek Harness',
      present: true, configured: true, active: false, status: 'available',
      discovery: {}, metadata: {},
      schema: {
        type: 'object',
        properties: {
          defaultAgentPreset: {
            type: 'string', title: '新会话默认模式', default: 'standard',
            enum: ['standard', 'review', 'broken']
          }
        }
      },
      uiSchema: {
        order: ['defaultAgentPreset'],
        defaultAgentPreset: {
          component: 'select',
          options: [
            { value: 'standard', label: '标准' },
            { value: 'review', label: '只读审查', description: '不改文件，只读代码' },
            { value: 'broken', label: '加载失败的模式', disabled: true, disabledReason: '预设文件损坏' }
          ]
        }
      },
      updatedAt: NOW()
    }
  ],
  serverTime: NOW()
};

/**
 * 虚拟文件树（第三轮教训：夹具必须**按请求返回**，不能一个罐头回答应付所有路径）。
 *
 * 之前 `fs/readText` 无论请求什么路径都返回同一个 `README.md` 内容 —— 于是「应用请求对了路径没」
 * 在证据上完全看不出来（真机上点 `package.json` 却显示 README，像是应用点错了行）。
 * 现在按路径返回真实内容，并在 `debugState` 里记下每次 list/read 的路径，验收可以直接断言。
 */
const WORKSPACE_ROOT_LOCAL = '/Users/mock/code/agents-anywhere';

/** key = 相对工作区根的路径（用 `/` 分隔）。 */
const VIRTUAL_FILES = new Map([
  ['README.md', [
    '# agents-anywhere',
    '',
    '这是模拟服务端返回的文本文件内容，用于验证鸿蒙端的文件预览链路。',
    '',
    '- 目录列表 → `POST /connectors/{id}/fs/list`',
    '- 文本读取 → `POST /connectors/{id}/fs/readText?root=`',
    '',
    '```ts',
    'const answer: number = 42;',
    '```'
  ].join('\n')],
  ['package.json', [
    '{',
    '  "name": "agents-anywhere",',
    '  "version": "2.0.0",',
    '  "private": true,',
    '  "scripts": {',
    '    "build": "node tools/build.mjs --mode release",',
    '    "test": "node tools/test.mjs"',
    '  },',
    '  "dependencies": {',
    '    "fastify": "^4.28.1"',
    '  }',
    '}'
  ].join('\n')],
  ['src/main.ts', [
    "import { createServer } from './server';",
    '',
    '// 入口：先解析配置，再起服务',
    'const PORT: number = 8787;',
    '',
    'export function bootstrap(): void {',
    "  const server = createServer({ host: '127.0.0.1', port: PORT });",
    '  server.listen();',
    '}',
    '',
    'bootstrap();'
  ].join('\n')],
  ['scripts/deploy.sh', [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    '',
    '# 直接调 hvigorw，别经 cmd 包装',
    'export DEVECO_SDK_HOME="<DevEco 安装目录>/sdk"',
    'node "$DEVECO_SDK_HOME/../tools/hvigor/bin/hvigorw.js" \\',
    '  --mode module -p product=default assembleHap --no-daemon',
    '',
    'echo "done: $?"'
  ].join('\n')],
  ['python/util.py', [
    'from dataclasses import dataclass',
    '',
    '',
    '@dataclass',
    'class Report:',
    '    title: str',
    '    count: int = 0',
    '',
    '',
    'def summarize(items: list[str]) -> Report:',
    '    """统计条目数。"""',
    '    return Report(title="summary", count=len(items))'
  ].join('\n')],
  ['Dockerfile', [
    'FROM node:22-alpine',
    'WORKDIR /app',
    'COPY package.json ./',
    'RUN npm install --omit=dev',
    'COPY . .',
    'EXPOSE 8787',
    'CMD ["node", "src/main.js"]'
  ].join('\n')],
  ['change.patch', [
    'diff --git a/src/main.ts b/src/main.ts',
    'index 1a2b3c4..5d6e7f8 100644',
    '--- a/src/main.ts',
    '+++ b/src/main.ts',
    '@@ -3,7 +3,7 @@ import { createServer } from "./server";',
    ' // 入口：先解析配置，再起服务',
    '-const PORT = 8080;',
    '+const PORT: number = 8787;',
    ' ',
    ' export function bootstrap(): void {'
  ].join('\n')],
  ['notes.txt', [
    '纯文本备忘（没有扩展名映射，预览应回退为纯文本）。',
    '第二行：确认 monospace 字体与换行。'
  ].join('\n')]
]);

/**
 * 附件夹具：一张 160x100 的 PNG（4 条色带 + 一条白色斜线，便于在真机截图里一眼确认方向），
 * 以及一份文本附件。**必须带正确的 sha256**：客户端的下载路径会做
 * 「base64 可解 / 字节数一致 / sha256 一致」三重校验，摘要给错会直接判失败。
 */
const ATTACHMENT_IMAGE_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAKAAAABkCAIAAACO1KzYAAACOElEQVR42u3csW0DMRBEURXmWOUodhGOFbscl6PEiRM5uFCwsbckgZnhP7AADR4WUPQvz5fvfnsU3/Xrvf1+Pt/a7/rx3X71dRl7L88/PoDDgSvMANsD/28MsAHw/fZ4Fj6AjYGP1zAG2Am4ccoAmwGfZQbYErhuDLArcJ0ZYGPgIjPA3sCLThlgIeAVzADLAc81BlgReCIzwLrAU/58AawOPHjKABsAHz+9xwywDXDPGGAn4AYzwH7ARWaAvYGLpwywMfBqZoAlgNcZA6wCvIgZYC3gIjPA3sATTxlgUeBZzABLA48bA6wOfAxuMwPsAXy8hjHATsCNUwbYDPgsM8CWwHVjgF2B68wAGwMXmQH2Bl50ygDLDZ7LDLDi4InGAOsOnsIMsPrgQWOADQaPnDLANoN7zAA7DW4YA+w3+BQzwK6Di8YAGw9uJ/sAdhq8jhlglcGLjAHWGjydGWDFwRONARYdPOuUAZYePM4MsPrgQWOAPVKGWxXudwTeqnC/L/AmhfutgXco3AMcXrgHOLxwD3B44R7g8MI9wOGFe4DDC/cAhxfuAQ4v3AMcXrgHOLxwD3B44R7g8MI9wOGFe4DDC/cAhxfuAQ4v3AMcXrgHOLxwD3B44R7g8MI9wOGFe4DDC/cAhxfuAQ4v3AMcXrgHOLxwD3B44R7g8MI9wOGFe4DDC/cAhxfuAQ4v3AMcXrgHOLxwD3B44R7g8MI9wOGFe4DDC/cAhxfuAQ4v3AMcXrgHOLxw/wuvnFBzyzDzDgAAAABJRU5ErkJggg==';
const ATTACHMENT_IMAGE_SHA256 = 'a8b4a6892336dce416e8af3e76a0ff8982ebf76aa2a7e12d1c6bef9e9c83668e';

const ATTACHMENTS = new Map(Object.entries({
  'file-mock-img1': {
    fileId: 'file-mock-img1', name: 'terminal-screenshot.png', mediaType: 'image/png',
    path: '/Users/mock/code/agents-anywhere/.agents/terminal-screenshot.png',
    contentBase64: ATTACHMENT_IMAGE_BASE64
  },
  'file-mock-doc1': {
    fileId: 'file-mock-doc1', name: 'build-notes.txt', mediaType: 'text/plain',
    path: '/Users/mock/code/agents-anywhere/.agents/build-notes.txt',
    contentBase64: '5p6E5bu65rOo5oSP5LqL6aG577yaCjEuIOebtOaOpeiwgyBodmlnb3J3CjIuIOWIq+e7jyBjbWQg5YyF6KOFCg=='
  }
}));

/** 从 multipart 原文里抠出第一个 part 的文件名（`filename="..."`）。 */
function uploadedName(raw) {
  const match = /filename="([^"]*)"/.exec(raw);
  return match !== null && match[1].length > 0 ? match[1] : 'upload.bin';
}

/** 从 multipart 原文里抠出第一个 part 的 Content-Type。 */
function uploadedMediaType(raw) {
  const match = /Content-Type:[ \t]*([^;\r\n]+)/i.exec(raw);
  return match !== null ? match[1].trim() : 'application/octet-stream';
}

function attachmentPayload(fileId) {
  const item = ATTACHMENTS.get(fileId);
  if (item === undefined) {
    return undefined;
  }
  const bytes = Buffer.from(item.contentBase64, 'base64');
  return {
    fileId: item.fileId, sessionId: SESSION_ID, path: item.path, name: item.name,
    mediaType: item.mediaType, size: bytes.length,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    contentBase64: item.contentBase64, createdAt: NOW()
  };
}

/** 目录 → 直接子项（按目录名排序，目录在前）。 */
function virtualEntries(dirPath) {
  const prefix = dirPath.length === 0 ? '' : dirPath + '/';
  const dirs = new Set();
  const files = [];
  for (const key of VIRTUAL_FILES.keys()) {
    if (!key.startsWith(prefix)) {
      continue;
    }
    const rest = key.substring(prefix.length);
    const slash = rest.indexOf('/');
    if (slash >= 0) {
      dirs.add(rest.substring(0, slash));
    } else {
      files.push({
        name: rest,
        path: WORKSPACE_ROOT_LOCAL + '/' + key,
        type: 'file',
        size: VIRTUAL_FILES.get(key).length
      });
    }
  }
  const entries = [...dirs].sort().map((name) => ({
    name,
    path: WORKSPACE_ROOT_LOCAL + '/' + prefix + name,
    type: 'directory'
  }));
  files.sort((a, b) => (a.name < b.name ? -1 : 1));
  return entries.concat(files);
}

/** 把请求里的绝对路径或相对路径归一成「相对工作区根」的 key。 */
function relativeKey(requestPath) {
  const raw = (requestPath ?? '.').trim();
  if (raw === '' || raw === '.') {
    return '';
  }
  if (raw.startsWith(WORKSPACE_ROOT_LOCAL)) {
    return raw.substring(WORKSPACE_ROOT_LOCAL.length).replace(/^\/+/, '');
  }
  return raw.replace(/^\.\//, '').replace(/^\/+/, '');
}

// ---------------------------------------------------------------------------
// 终端回放内容：故意覆盖颜色 / 光标定位 / 清屏 / 宽字符 / 制表
// ---------------------------------------------------------------------------

/**
 * 诊断用刻度内容：每行标出真实行号，用来核对「模拟器第 N 行」到底落在屏幕哪个位置，
 * 从而区分「解析错」与「渲染有纵向偏移」。用 `--ruler` 启动时启用。
 */
function terminalRuler() {
  const e = '\u001b[';
  const out = [`${e}2J${e}H`];
  for (let i = 0; i < 20; i++) {
    const tag = String(i).padStart(2, '0');
    out.push(`${e}3${i % 7}mR${tag}${e}0m 左侧刻度 ${'·'.repeat(6)} ${e}1mR${tag}${e}0m`);
  }
  return out.join('\r\n');
}

function terminalReplay() {
  const e = '\u001b[';
  const lines = [
    `${e}2J${e}H`,
    `${e}1;32m➜${e}0m  ${e}1;36m~/code/agents-anywhere${e}0m ${e}1;33mgit:(main)${e}0m`,
    '',
    `${e}1m$ npm test${e}0m`,
    '',
    `${e}32m✓${e}0m render.spec.ts        ${e}90m(12 ms)${e}0m`,
    `${e}32m✓${e}0m state-bind.spec.ts    ${e}90m(8 ms)${e}0m`,
    `${e}31m✗${e}0m legacy-route.spec.ts  ${e}90m(3 ms)${e}0m`,
    '',
    `${e}1mTests:${e}0m ${e}32m2 passed${e}0m, ${e}31m1 failed${e}0m, 3 total`,
    '',
    `${e}7m 反显 ${e}0m ${e}4m下划线${e}0m ${e}9m删除线${e}0m ${e}3m斜体${e}0m`,
    `索引色：${e}38;5;208m208${e}0m ${e}38;5;39m39${e}0m ${e}38;5;201m201${e}0m`,
    `真彩色：${e}38;2;255;120;40m橙色${e}0m ${e}48;2;40;80;160m蓝底${e}0m`,
    '',
    `宽字符对齐：${e}1m中文表格${e}0m`,
    '┌──────────┬────────┐',
    '│ 名称     │ 状态   │',
    '├──────────┼────────┤',
    '│ 工作台   │ 就绪   │',
    '│ 终端     │ 运行中 │',
    '└──────────┴────────┘',
    '',
    '制表位:\ta\tb\tc',
    `${e}1;32m➜${e}0m 输入 `,
    `${e}?25h`
  ];
  return lines.join('\r\n');
}

// ---------------------------------------------------------------------------
// 极简 WebSocket（RFC6455）：只支持文本帧 + ping/pong/close
// ---------------------------------------------------------------------------

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

class WsConnection {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.closed = false;
    this.onText = () => {};
    this.onClose = () => {};
    socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.drain();
    });
    socket.on('close', () => {
      if (!this.closed) {
        this.closed = true;
        this.onClose();
      }
    });
    socket.on('error', () => {
      this.closed = true;
    });
  }

  drain() {
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }
      let mask = null;
      if (masked) {
        if (this.buffer.length < offset + 4) return;
        mask = this.buffer.subarray(offset, offset + 4);
        offset += 4;
      }
      if (this.buffer.length < offset + length) return;
      const payload = Buffer.from(this.buffer.subarray(offset, offset + length));
      if (mask) {
        for (let i = 0; i < payload.length; i++) {
          payload[i] ^= mask[i % 4];
        }
      }
      this.buffer = this.buffer.subarray(offset + length);
      if (opcode === 0x1) {
        this.onText(payload.toString('utf8'));
      } else if (opcode === 0x8) {
        this.close();
        return;
      } else if (opcode === 0x9) {
        this.writeFrame(0xA, payload);
      }
    }
  }

  writeFrame(opcode, payload) {
    if (this.closed || this.socket.destroyed) {
      return;
    }
    const data = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
    const length = data.length;
    let header;
    if (length < 126) {
      header = Buffer.alloc(2);
      header[1] = length;
    } else if (length < 65536) {
      header = Buffer.alloc(4);
      header[1] = 126;
      header.writeUInt16BE(length, 2);
    } else {
      header = Buffer.alloc(10);
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(length), 2);
    }
    header[0] = 0x80 | opcode;
    this.socket.write(Buffer.concat([header, data]));
  }

  sendText(text) {
    this.writeFrame(0x1, text);
  }

  sendJson(value) {
    this.sendText(JSON.stringify(value));
  }

  close() {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      this.writeFrame(0x8, Buffer.alloc(0));
      this.socket.end();
    } catch (error) {
      this.socket.destroy();
    }
    this.onClose();
  }
}

// ---------------------------------------------------------------------------
// HTTP 工具
// ---------------------------------------------------------------------------

function sendJson(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(text)
  });
  response.end(text);
}

/**
 * 最近一次请求的原始 body（文本）。
 * 夹具专用：`multipart/form-data` 不是 JSON，`readBody` 会返回 undefined，
 * 但上传验收需要「文件名 / 体积」这类信息，所以额外留一份原文供 multipart 分支取用。
 * 单进程顺序处理请求，读体在路由之前完成，不存在串用问题。
 */
let rawRequestBody = '';

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    rawRequestBody = '';
    return undefined;
  }
  const text = Buffer.concat(chunks).toString('utf8');
  rawRequestBody = text;
  if (text.trim().length === 0) {
    return undefined;
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    return undefined;
  }
}

function authorization(request) {
  const header = request.headers['authorization'] ?? '';
  return header.startsWith('Bearer ') ? header.slice(7) : '';
}

// ---------------------------------------------------------------------------
// 请求日志（验收证据：证明 App 真的打到了这些端点）
// ---------------------------------------------------------------------------

/** 验收断言用：记录客户端发来的写操作；meta/archive/read 三类同时**真的回写** fixture，
 *  否则「应用没刷新」与「服务端没存」无法区分（2026-09-14 真机踩到）。 */
const debugState = {
  selections: {},
  takeover: false,
  commandsExecuted: [],
  noticesResponded: [],
  /** 审批/提问的**完整响应体**（`{noticeId, actionId, input}`）—— R50 提问表单的验收判据。 */
  noticeResponses: [],
  /** 新建会话的请求体摘要（`{runtime, runtimeId, runtimeOptions, selections}`）—— R51 Agent 预设的验收判据。 */
  sessionCreates: [],
  /** 指令执行记录（`{sessionId, command, args, raw}`）—— R52 指令按钮的验收判据。 */
  commandExecutions: [],
  messagesSent: [],
  /** 每条消息带的附件引用（验收「附件真的随消息发出去了」）。 */
  messageAttachments: [],
  archivedIds: [],
  pinned: {},
  titles: {},
  readIds: [],
  /** 邮箱验证码请求（F1「N 秒后重发」倒计时验收夹具，R42 新增）。 */
  emailCodeRequests: [],
  fsLists: [],
  fsReads: [],
  uploads: [],
  attachmentReads: [],
  metaPatches: [],
  /** 会话分页夹具（--page-size）的每次请求：cursor / offset / 返回了哪些 id / 下一页游标。 */
  sessionPageRequests: [],
  /** 项目顺序抖动夹具（--dashboard-order-churn）推过的快照数 / 每次被抬到「最近活动」的项目 id。 */
  orderChurnTicks: 0,
  orderChurnTargets: [],
  /** 配对新设备夹具（R8）：每次 claim 的配对码与结果（失败也记，验收要断言「错码不产生设备」）。 */
  pairingClaims: [],
  /** POST /connectors 创建出来的设备。 */
  connectorCreates: [],
  /** POST /connectors/{id}/revoke 撤销过的设备 id。 */
  revokedDevices: [],
  /** POST /connectors/{id}/sessions/archive-all 的每次批量归档。 */
  archiveAlls: [],
  /** PUT /connectors/{id}/runtimes/{rid}/config 的每次写入（新建会话 / 设备详情页保存运行时配置）。 */
  runtimeConfigPuts: [],
  /** DELETE /connectors/{id}/runtimes/{rid}/config 的每次删除。 */
  runtimeConfigDeletes: [],
  /** PUT /connectors/{id}/runtimes/{rid}/active 的每次切换。 */
  runtimeActivePuts: []
};

const startedAt = Date.now();
let requestCount = 0;

function log(kind, detail) {
  const elapsed = String(Date.now() - startedAt).padStart(6, ' ');
  requestCount += 1;
  console.log(`[${elapsed}ms] #${String(requestCount).padStart(3, ' ')} ${kind} ${detail}`);
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  const path = url.pathname;
  const method = request.method ?? 'GET';
  const body = await readBody(request);

  // 统一按 /api/v2 前缀匹配；同时兼容 legacy（去掉前缀）
  const route = path.startsWith('/api/v2/') ? path.slice('/api/v2'.length) : path;

  log(method, `${path}${url.search}${body !== undefined ? ' body=' + JSON.stringify(body).slice(0, 160) : ''}`);

  const ok = (payload) => sendJson(response, 200, payload);

  // ---- health / auth -------------------------------------------------------
  if (route === '/debug/state' && method === 'GET') {
    return ok(debugState);
  }
  if (route === '/health') {
    return ok({ status: 'ok', version: '2.0.0', serverTime: NOW() });
  }
  if (route === '/auth/config' && method === 'GET') {
    return ok({
      needsBootstrap: false, registrationOpen: true, oauthRegistrationOpen: true,
      oauthEnabled: true, oauthProviderLabel: '模拟登录', serverTime: NOW(),
      emailVerificationRequired: false
    });
  }
  if (route === '/auth/login' && method === 'POST') {
    if ((body?.password ?? '').length === 0) {
      return sendJson(response, 401, { detail: { code: 'invalid_credentials', message: '密码不能为空。' } });
    }
    return ok({
      userId: 'user-mock', role: 'user', accessToken: TOKEN, tokenType: 'bearer',
      serverTime: NOW(), email: body?.email ?? 'mock@example.com',
      displayName: '模拟用户', emailVerified: true
    });
  }
  if (route === '/auth/register' && method === 'POST') {
    return ok({
      userId: 'user-mock', role: 'user', accessToken: TOKEN, tokenType: 'bearer',
      serverTime: NOW(), email: body?.email ?? 'mock@example.com',
      displayName: body?.displayName ?? '新用户', emailVerified: false
    });
  }
  if (route === '/auth/me' && method === 'GET') {
    if (authorization(request) !== TOKEN) {
      return sendJson(response, 401, { detail: { code: 'unauthorized', message: '登录已失效。' } });
    }
    return ok({
      userId: 'user-mock', role: 'user', disabled: false, serverTime: NOW(),
      email: 'mock@example.com', displayName: '模拟用户', emailVerified: true
    });
  }
  for (const p of ['/auth/me/profile', '/auth/me/email', '/auth/me/avatar']) {
    if (route === p) {
      return ok({
        userId: 'user-mock', role: 'user', disabled: false, serverTime: NOW(),
        email: 'mock@example.com', displayName: '模拟用户', emailVerified: true
      });
    }
  }
  // 邮箱验证码夹具（R42 新增）：真实服务端返回 retryAfter 驱动「N 秒后重发」倒计时，
  // 本 mock 原先未实现该端点，导致 F1 修复无法在设备上验收（旧读数：页面报「模拟服务端没有实现 POST /api/v2/auth/email-code」）。
  if (route === '/auth/email-code' && method === 'POST') {
    const email = typeof body?.email === 'string' ? body['email'] : '';
    debugState.emailCodeRequests.push(email);
    if (email.length === 0 || email.indexOf('@') < 0) {
      return sendJson(response, 400, { detail: { code: 'invalid_email', message: '邮箱格式不正确。' } });
    }
    return ok({ expiresIn: 600, retryAfter: 60, serverTime: NOW() });
  }
  if (route === '/auth/change-password') {
    return ok({ ok: true });
  }

  // 其余端点要求鉴权
  if (route !== '/ws-ticket' && authorization(request) !== TOKEN) {
    return sendJson(response, 401, { detail: { code: 'unauthorized', message: '缺少或错误的 access token。' } });
  }

  if (route === '/ws-ticket' && method === 'POST') {
    return ok({ ticket: 'mock-ticket-' + Date.now(), expiresAt: NOW(), serverTime: NOW() });
  }

  // ---- 工作台 --------------------------------------------------------------
  if (route === '/connectors' && method === 'GET') {
    return ok({ connectors: allConnectors(), serverTime: NOW() });
  }
  // ---- 配对新设备夹具（R8）--------------------------------------------------
  if (route === '/connectors' && method === 'POST') {
    const name = String(body?.name ?? '').trim() || '未命名设备';
    pairedCounter += 1;
    const created = {
      id: 'conn-created-' + String(pairedCounter).padStart(4, '0'),
      name,
      deviceOs: 'harmonyos',
      status: 'online',
      lastSeenAt: NOW(),
      createdAt: NOW(),
      updatedAt: NOW()
    };
    extraConnectors.push(created);
    debugState.connectorCreates.push({ id: created.id, name: created.name });
    return ok({
      connector: created,
      connectorToken: 'mock-connector-token-' + created.id,
      tokenPrefix: 'mock-cr',
      serverTime: NOW()
    });
  }
  if (route === '/pairing/claim' && method === 'POST') {
    const code = normalizePairingCode(body?.code);
    if (!isValidPairingCode(code)) {
      // 失败路径必须留下痕迹：验收要断言「错码不产生设备」。
      debugState.pairingClaims.push({ code, ok: false, reason: 'invalid_pairing_code' });
      return sendJson(response, 400, {
        detail: { code: 'invalid_pairing_code', message: '配对码无效：夹具只接受 6 位字母或数字（例如 ABC123）。' }
      });
    }
    pairedCounter += 1;
    const claimed = {
      id: 'conn-paired-' + String(pairedCounter).padStart(4, '0'),
      name: String(body?.name ?? '').trim() || 'hm-smoke',
      deviceOs: 'harmonyos',
      status: 'online',
      lastSeenAt: NOW(),
      createdAt: NOW(),
      updatedAt: NOW()
    };
    extraConnectors.push(claimed);
    debugState.pairingClaims.push({ code, ok: true, connectorId: claimed.id, name: claimed.name });
    return ok({
      connector: claimed,
      connectorToken: 'mock-connector-token-' + claimed.id,
      tokenPrefix: 'mock-cr',
      serverTime: NOW()
    });
  }
  if (route.startsWith('/connectors/') && route.endsWith('/revoke') && method === 'POST') {
    const targetId = route.slice('/connectors/'.length, route.length - '/revoke'.length);
    const target = findConnector(targetId);
    if (target === undefined) {
      return sendJson(response, 404, { detail: { code: 'connector_not_found', message: '设备不存在：' + targetId } });
    }
    const index = extraConnectors.indexOf(target);
    if (index >= 0) {
      extraConnectors.splice(index, 1);
    } else {
      target.status = 'offline';
    }
    debugState.revokedDevices.push(targetId);
    return ok({ connector: target, connectorToken: '', tokenPrefix: '', serverTime: NOW() });
  }
  if (route.startsWith('/connectors/') && route.endsWith('/sessions/archive-all') && method === 'POST') {
    const targetId = route.slice('/connectors/'.length, route.length - '/sessions/archive-all'.length);
    const archived = body?.archived !== false;
    const touched = [];
    for (const item of sessions) {
      if (item.connectorId === targetId) {
        item.archived = archived;
        item.archivedAt = archived ? NOW() : undefined;
        touched.push(item.id);
      }
    }
    debugState.archiveAlls.push({ connectorId: targetId, archived, ids: touched });
    return ok({
      sessions: sessions.filter((item) => touched.includes(item.id)),
      archived,
      serverTime: NOW()
    });
  }
  // 被配对 / 被创建出来的设备按 id 查详情（主设备仍走下面那条精确路由）。
  if (route.startsWith('/connectors/') && method === 'GET' &&
    route.indexOf('/', '/connectors/'.length) < 0) {
    const target = findConnector(route.slice('/connectors/'.length));
    if (target !== undefined) {
      return ok({ connector: target, serverTime: NOW() });
    }
  }
  if (route === `/connectors/${CONNECTOR_ID}` && method === 'GET') {
    return ok({ connector, serverTime: NOW() });
  }
  // Runtime 列表 / 发现：对**任意已存在设备**生效（第八轮 verifier 实测：配对出来的
  // 新设备若只支持主设备，进详情页会挂一条 404 错误横幅 —— 那是夹具的洞，不是应用缺陷）。
  if (route.startsWith('/connectors/') && route.endsWith('/runtimes') && method === 'GET') {
    const runtimeOwnerId = route.slice('/connectors/'.length, route.length - '/runtimes'.length);
    if (findConnector(runtimeOwnerId) !== undefined) {
      return ok(runtimes);
    }
  }
  if (route.startsWith('/connectors/') && route.endsWith('/runtimes/discover') && method === 'POST') {
    const discoverOwnerId = route.slice('/connectors/'.length, route.length - '/runtimes/discover'.length);
    if (findConnector(discoverOwnerId) !== undefined) {
      return ok(runtimes);
    }
  }
  if (route === `/connectors/${CONNECTOR_ID}/runtimes` && method === 'GET') {
    return ok(runtimes);
  }
  if (route === `/connectors/${CONNECTOR_ID}/runtimes/discover` && method === 'POST') {
    return ok(runtimes);
  }
  // 任意设备的「运行时能力 / 目录 / 配置」子路由（新建会话页「实时选项」与设备详情页都要用）
  const runtimeSub = route.match(/^\/connectors\/([^/]+)\/runtimes\/([^/]+)\/(capabilities|catalogs\/model|catalogs\/permission|config|active)$/);
  if (runtimeSub && findConnector(decodeURIComponent(runtimeSub[1])) !== undefined) {
    const ownerId = decodeURIComponent(runtimeSub[1]);
    const runtimeId = decodeURIComponent(runtimeSub[2]);
    const sub = runtimeSub[3];
    if (sub === 'capabilities' && method === 'GET') {
      return ok({ connectorId: ownerId, runtimeId, capabilitySet: runtimeCapabilities, serverTime: NOW() });
    }
    if (sub === 'catalogs/model' && method === 'GET') {
      return ok({ connectorId: ownerId, runtimeId, catalog: modelCatalog, serverTime: NOW() });
    }
    if (sub === 'catalogs/permission' && method === 'GET') {
      return ok({ connectorId: ownerId, runtimeId, catalog: permissionCatalog, serverTime: NOW() });
    }
    if (sub === 'config' && method === 'PUT') {
      debugState.runtimeConfigPuts.push(JSON.stringify({ runtimeId, config: body?.config ?? {} }));
      const entry = runtimes.runtimes.find((item) => item.runtimeId === runtimeId) ?? runtimes.runtimes[0];
      entry.configured = true;
      return ok({ connector: entry, serverTime: NOW() });
    }
    if (sub === 'config' && method === 'DELETE') {
      debugState.runtimeConfigDeletes.push(runtimeId);
      const entry = runtimes.runtimes.find((item) => item.runtimeId === runtimeId) ?? runtimes.runtimes[0];
      entry.configured = false;
      return ok({ connector: entry, serverTime: NOW() });
    }
    if (sub === 'active' && method === 'PUT') {
      const entry = runtimes.runtimes.find((item) => item.runtimeId === runtimeId) ?? runtimes.runtimes[0];
      entry.active = body?.active === true;
      debugState.runtimeActivePuts.push(JSON.stringify({ runtimeId, active: entry.active }));
      return ok({ connector: entry, serverTime: NOW() });
    }
  }
  if (route === '/projects' && method === 'GET') {
    return ok({ projects, serverTime: NOW() });
  }
  if (route === '/sessions' && method === 'GET') {
    const archived = url.searchParams.get('archived') === 'true';
    // `--no-archived`：归档侧一律返回空 —— 用于验收**已归档页的两个空态**
    // （未筛选 / 已按项目筛选）。默认关，零影响既有验收。
    const list = NO_ARCHIVED && archived
      ? []
      : sessions.filter((item) => Boolean(item.archived) === archived);
    if (!PAGINATED) {
      // 默认（不传 --page-size）与历史行为逐字节一致。
      return ok({ sessions: list, hasMore: false, nextCursor: null, serverTime: NOW() });
    }
    // 夹具**忽略请求里的 limit**，强制用 --page-size 的页大小切页。
    //
    // 原因（第八轮 verifier 实测）：鸿蒙端 DashboardStore 首屏固定 `limit=100`，
    // 若夹具按「请求的 limit」分页，十来条会话一页就全返回了、hasMore 恒 false，
    // 「加载更多」在设备上永远不可达 —— 夹具就失去了逼出分页路径的意义。
    // 要改单页条数请用 `--page-size`，不要依赖请求参数。
    const limit = PAGE_SIZE;
    const cursor = url.searchParams.get('cursor');
    const offset = parseSessionCursor(cursor);
    if (offset === null) {
      return sendJson(response, 400, {
        detail: { code: 'invalid_cursor', message: '无法解析的 cursor（本夹具为 offset:N）：' + cursor }
      });
    }
    const page = sessionPageOf(list, offset, limit);
    // 回写状态：验收可以直接断言「第二页真的被请求过、游标是什么」（EXPERIENCE §17）。
    debugState.sessionPageRequests.push({
      archived: archived,
      limit: limit,
      cursor: cursor,
      offset: offset,
      returned: page.sessions.length,
      ids: page.sessions.map((item) => item.id),
      hasMore: page.hasMore,
      nextCursor: page.nextCursor
    });
    return ok({
      sessions: page.sessions,
      hasMore: page.hasMore,
      nextCursor: page.nextCursor,
      serverTime: NOW()
    });
  }
  if (route.startsWith('/projects/') && route.endsWith('/sessions') && method === 'GET') {
    return ok({ sessions: sessions.filter((item) => !item.archived), hasMore: false, nextCursor: null, serverTime: NOW() });
  }

  // ---- 会话写入 ------------------------------------------------------------
  if (route === '/sessions/read' && method === 'POST') {
    const ids = Array.isArray(body) ? body : [];
    for (const id of ids) {
      debugState.readIds.push(id);
    }
    for (const item of sessions) {
      if (ids.includes(item.id)) {
        item.unread = false;
      }
    }
    return ok({ sessions: sessions.filter((item) => ids.includes(item.id)), notFound: [], serverTime: NOW() });
  }
  if ((route === '/sessions/archive' || route === '/sessions/unarchive') && method === 'POST') {
    const ids = Array.isArray(body) ? body : [];
    const archived = route.endsWith('archive') && !route.endsWith('unarchive');
    for (const item of sessions) {
      if (ids.includes(item.id)) {
        debugState.archivedIds.push(item.id + ':' + archived);
        item.archived = archived;
        item.archivedAt = archived ? NOW() : undefined;
      }
    }
    return ok({ sessions: sessions.filter((item) => ids.includes(item.id)), notFound: [], serverTime: NOW() });
  }
  if (route === '/sessions/create-and-start' && method === 'POST') {
    // R51：把 `runtimeOptions` 记下来 —— 「新建会话带上 Agent 预设」这条验收就靠它
    // （连接器只认 `agentPreset` 这一个键，缺省时回落连接器配置，所以**没选时必须不带这个字段**）。
    debugState.sessionCreates.push({
      runtime: body?.runtime ?? '',
      runtimeId: body?.runtimeId ?? '',
      runtimeOptions: body?.runtimeOptions ?? null,
      selections: body?.selections ?? null
    });
    const created = session('sess-mock-' + Date.now(), body?.title ?? '新会话', 'running');
    sessions.unshift(created);
    return ok({ session: created });
  }

  const sessionMatch = route.match(/^\/sessions\/([^/]+)(\/.*)?$/);
  if (sessionMatch) {
    const id = decodeURIComponent(sessionMatch[1]);
    const rest = sessionMatch[2] ?? '';
    const target = sessions.find((item) => item.id === id) ?? sessions[0];

    if (rest === '' && method === 'GET') {
      return ok({ session: target, serverTime: NOW() });
    }
    if (rest === '/meta' && method === 'GET') {
      return ok({ session: target, serverTime: NOW() });
    }
    if (rest === '/meta' && method === 'PATCH') {
      if (typeof body?.title === 'string') {
        target.title = body.title;
        debugState.titles[target.id] = body.title;
      }
      if (typeof body?.pinned === 'boolean') {
        target.pinned = body.pinned;
        debugState.pinned[target.id] = body.pinned;
      }
      debugState.metaPatches.push(JSON.stringify(body ?? {}));
      return ok({ session: target, serverTime: NOW() });
    }
    if (rest === '/snapshot' && method === 'GET') {
      return ok({
        session: target,
        state: {
          sessionId: target.id, runtime: 'codex', runtimeType: 'codex', runtimeId: 'codex',
          runtimeName: 'codex', status: target.status, selections: { model: 'gpt-5-codex' },
          metadata: {}, updatedSeq: 10, createdAt: '2026-09-14T10:00:00Z'
        },
        timeline: { items: timelineItems, nextSeq: 5, hasMore: false },
        notices: activeNotices(),
        effectiveCapabilities: capabilities,
        runtimeCapabilities: capabilities,
        catalogs: { model: modelCatalog, permission: permissionCatalog },
        eventCursor: 'seq:5',
        serverTime: NOW()
      });
    }
    if (rest.startsWith('/timeline') && method === 'GET') {
      return ok({ sessionId: id, items: timelineItems, nextSeq: 5, hasMore: false, serverTime: NOW() });
    }
    if (rest === '/events' && method === 'GET') {
      return ok({ events: [], nextCursor: url.searchParams.get('after') ?? 'seq:0', snapshotRequired: false, serverTime: NOW() });
    }
    if (rest === '/runtime/state' && method === 'GET') {
      return ok({
        state: {
          sessionId: target.id, runtime: 'codex', runtimeType: 'codex', runtimeId: 'codex',
          runtimeName: 'codex', status: target.status, selections: { model: 'gpt-5-codex' },
          // R52：上下文圆环的数据源 —— DSH 的 `contextPressure` 投影经 bridge 补丁放进 metadata。
          // 夹具给「窗口 200k / 已用 140k（70% ⇒ warn 档）」，正好覆盖档位边界。
          metadata: {
            contextPressure: {
              contextWindow: 200000,
              surfaceTokens: 140000,
              pressureTokens: 140000
            }
          },
          updatedSeq: 10, createdAt: '2026-09-14T10:00:00Z'
        },
        serverTime: NOW()
      });
    }
    // R52：DSH 原生指令（GET 列目录 / POST 执行）。形状照连接器
    // `runtimes/dsh/bridge/models.py:commands()` / `command_result()` 期待的字段。
    if (rest === '/runtime/commands' && method === 'GET') {
      return ok({
        commands: [
          {
            id: 'compact', title: '/compact', description: 'Compact older conversation history',
            aliases: [], category: 'dsh', scope: 'session', enabled: true, acceptsArgs: false
          },
          {
            id: 'goal', title: '/goal', description: 'Set or view the goal for a long-running task',
            aliases: [], category: 'dsh', scope: 'session', enabled: true, acceptsArgs: true,
            argsSchema: { hint: '目标描述' }
          },
          {
            id: 'broken', title: '/broken', description: '这条被禁用（夹具用来看置灰态）',
            aliases: [], category: 'dsh', scope: 'session', enabled: false, disabledReason: '示例不可用'
          }
        ],
        serverTime: NOW()
      });
    }
    if (rest === '/runtime/commands' && method === 'POST') {
      const command = String(body?.command ?? '');
      const args = Array.isArray(body?.args) ? body.args : [];
      debugState.commandExecutions.push({ sessionId: target.id, command, args, raw: body?.raw ?? null });
      const known = command === 'compact' || command === 'goal';
      return ok({
        command,
        ok: known,
        code: known ? 'success' : 'unknown_command',
        message: known ? `已执行 /${command}` : `未知指令 /${command}`,
        result: { commandId: 'cmd-mock-1' },
        serverTime: NOW()
      });
    }
    if (rest === '/runtime/capabilities' && method === 'GET') {
      return ok({ connectorId: CONNECTOR_ID, capabilitySet: capabilities, serverTime: NOW() });
    }
    if (rest === '/runtime/notices' && method === 'GET') {
      return ok({ notices: activeNotices(), serverTime: NOW() });
    }
    if (rest.startsWith('/runtime/notices/') && rest.endsWith('/respond') && method === 'POST') {
      log('  ↳', `审批响应 actionId=${body?.actionId} input=${JSON.stringify(body?.input ?? null)}`);
      debugState.noticesResponded.push(String(body?.actionId ?? ''));
      // ⚠️ 必须按 noticeId 找到**那一张**卡：开了 --input-request 时活动公告不是模块级的 notice。
      // 响应体里的 input 也要记下来 —— 提问表单的验收判据就是它（形状见 questionNotice 的注释）。
      // ⚠️ `rest` 是去掉会话 id 之后的路径：`/runtime/notices/<noticeId>/respond`
      // ⇒ 下标 3 才是 noticeId（下标 1 是字面量 `runtime`，第一版就写错了）。
      const noticeId = String(rest.split('/')[3] ?? '');
      debugState.noticeResponses.push({ noticeId: noticeId, actionId: String(body?.actionId ?? ''), input: body?.input ?? null });
      const target = activeNotices().find((item) => rest.indexOf(item.noticeId) >= 0) ?? notice;
      target.status = 'resolved';
      target.resolvedAt = NOW();
      queueSessionEvent(id, 'runtime.notice.updated', { notice: target });
      return ok({ ok: true, serverTime: NOW() });
    }
    if (rest === '/runtime/catalogs/model' && method === 'GET') {
      return ok({ catalog: modelCatalog, serverTime: NOW() });
    }
    if (rest === '/runtime/catalogs/permission' && method === 'GET') {
      return ok({ catalog: permissionCatalog, serverTime: NOW() });
    }
    if (rest === '/runtime/selections' && method === 'PATCH') {
      debugState.selections = body?.selections ?? {};
      return ok({
        ok: true,
        state: {
          sessionId: target.id, runtime: 'codex', status: target.status,
          selections: body?.selections ?? {}, metadata: {}, updatedSeq: 11
        },
        serverTime: NOW()
      });
    }
    if (rest === '/runtime/commands' && method === 'GET') {
      return ok({ commands, serverTime: NOW() });
    }
    if (rest === '/runtime/commands' && method === 'POST') {
      debugState.commandsExecuted.push(String(body?.command ?? ''));
      return ok({ command: body?.command ?? '', ok: true, message: '命令已执行（模拟）。', result: {}, serverTime: NOW() });
    }
    if ((rest === '/runtime/messages' || rest === '/runtime/steer') && method === 'POST') {
      const text = body?.content ?? '';
      const clientMessageId = body?.clientMessageId ?? '';
      debugState.messagesSent.push(text);
      debugState.messageAttachments.push(body?.attachments ?? []);
      log('  ↳', `发送消息 endpoint=${rest} clientMessageId=${clientMessageId} content=${JSON.stringify(text)} attachments=${JSON.stringify(body?.attachments ?? [])}`);
      const orderSeq = timelineItems.length + 1;
      // ⚠️ 必须把附件**回显**进这条 item：客户端收到 `timeline.item_created` 后会用它
      // 替换本地的乐观消息，条目里没有附件，气泡上的附件就会「发出去之后消失」。
      const echoedAttachments = (Array.isArray(body?.attachments) ? body.attachments : [])
        .map((ref) => {
          const known = ATTACHMENTS.get(ref?.fileId);
          const payload = known !== undefined ? attachmentPayload(ref.fileId) : undefined;
          return {
            fileId: ref?.fileId ?? '', name: payload?.name ?? ref?.fileId ?? '',
            mediaType: payload?.mediaType ?? 'application/octet-stream', size: payload?.size ?? 0
          };
        });
      const userItem = {
        id: 'item-user-' + orderSeq, sessionId: id, type: 'message', status: 'done', role: 'user',
        orderSeq, revision: 1, updatedSeq: 20 + orderSeq, createdAt: NOW(),
        content: { text, clientMessageId, attachments: echoedAttachments }, source: {}
      };
      timelineItems.push(userItem);
      queueSessionEvent(id, 'timeline.item_created', { item: userItem });
      // 1.2s 后推一条助手回复，验证实时增量
      setTimeout(() => {
        const replySeq = timelineItems.length + 1;
        const replyItem = {
          id: 'item-reply-' + replySeq, sessionId: id, type: 'message', status: 'done', role: 'assistant',
          orderSeq: replySeq, revision: 1, updatedSeq: 30 + replySeq, createdAt: NOW(),
          content: { text: `收到：「${text}」。这是模拟服务端的实时回复，用于验证 WebSocket 增量事件。` },
          source: {}
        };
        timelineItems.push(replyItem);
        queueSessionEvent(id, 'timeline.item_created', { item: replyItem });
        queueSessionEvent(id, 'runtime.state.updated', {
          state: { sessionId: id, runtime: 'codex', status: 'idle', selections: {}, metadata: {}, updatedSeq: 40 }
        });
      }, 1200);
      return ok({ ok: true });
    }
    if (rest === '/runtime/interrupt' && method === 'POST') {
      log('  ↳', '中断请求');
      target.status = 'idle';
      queueSessionEvent(id, 'session.meta.updated', { session: target });
      return ok({ ok: true });
    }
    if (rest === '/takeover' && (method === 'POST' || method === 'DELETE')) {
      target.takeover = method === 'POST';
      debugState.takeover = target.takeover;
      return ok({ session: target });
    }
    if (rest === '/attachments' && method === 'POST') {
      // 上传：记录「收到了多大、文件名是什么」，并**真的回写**一个可下载的附件，
      // 这样「上传成功」与「上传后能取回」两件事都能被断言（夹具要按请求变化，见 EXPERIENCE §17/§20）。
      const rawBytes = Buffer.from(rawRequestBody, 'utf8');
      const uploaded = {
        fileId: 'file-mock-up' + (debugState.uploads.length + 1),
        name: uploadedName(rawRequestBody),
        mediaType: uploadedMediaType(rawRequestBody),
        size: rawBytes.length,
        sha256: crypto.createHash('sha256').update(rawBytes).digest('hex')
      };
      debugState.uploads.push({
        fileId: uploaded.fileId, name: uploaded.name, mediaType: uploaded.mediaType,
        bodyBytes: rawBytes.length
      });
      ATTACHMENTS.set(uploaded.fileId, {
        fileId: uploaded.fileId, name: uploaded.name, mediaType: uploaded.mediaType,
        path: '/Users/mock/code/agents-anywhere/.agents/' + uploaded.name,
        contentBase64: rawBytes.toString('base64')
      });
      return ok({ attachments: [uploaded] });
    }
    const attachmentMatch = /^\/attachments\/([^/]+)$/.exec(rest);
    if (attachmentMatch !== null && method === 'GET') {
      const payload = attachmentPayload(decodeURIComponent(attachmentMatch[1]));
      if (payload === undefined) {
        return sendJson(response, 404, {
          detail: { code: 'not_found', message: '附件不存在：' + attachmentMatch[1] }
        });
      }
      // `--fail-attachments`：夹具开关，让附件下载**确定性地失败**。
      // 用途：验收「下载失败后不再无限重试」——`AttachmentStore.ensure` 曾经只看
      // entries/pending，失败 → notify → 页面 pull → ensure → 再请求，会自我放大成
      // 无限请求。打开本开关后 `attachmentReads` 应该只涨一次（每次进页面一次）。
      if (FAIL_ATTACHMENTS) {
        debugState.attachmentReads.push(payload.fileId);
        return sendJson(response, 500, {
          detail: { code: 'fixture_failure', message: '夹具：强制附件下载失败' }
        });
      }
      debugState.attachmentReads.push(payload.fileId);
      return ok(payload);
    }
  }

  // ---- 文件 ----------------------------------------------------------------
  // fs 子路由按**设备**分派：Windows 设备走盘符总览那套树（`--win-device`），其余走 macOS 工作区。
  const fsListMatch = /^\/connectors\/([^/]+)\/fs\/list$/.exec(route);
  if (fsListMatch !== null && method === 'POST' && findConnector(decodeURIComponent(fsListMatch[1])) !== undefined) {
    if (decodeURIComponent(fsListMatch[1]) === WINDOWS_CONNECTOR_ID) {
      const win = windowsEntries(body?.path, body?.root);
      debugState.fsLists.push(win.path.length > 0 ? 'win:' + win.path : 'win:<drives>');
      return ok({ ok: true, result: { path: win.path, entries: win.entries, truncated: false, targetType: 'directory' } });
    }
    const key = relativeKey(body?.path);
    debugState.fsLists.push(key.length > 0 ? key : '.');
    const entries = virtualEntries(key);
    return ok({
      ok: true,
      result: {
        path: WORKSPACE_ROOT_LOCAL + (key.length > 0 ? '/' + key : ''),
        entries, truncated: false, targetType: 'directory'
      }
    });
  }
  const fsReadMatch = /^\/connectors\/([^/]+)\/fs\/readText$/.exec(route);
  if (fsReadMatch !== null && method === 'POST'
    && findConnector(decodeURIComponent(fsReadMatch[1])) !== undefined
    && decodeURIComponent(fsReadMatch[1]) === WINDOWS_CONNECTOR_ID) {
    // Windows 夹具：路径统一成正斜杠、盘符统一大写后再查表。
    const raw = String(body?.path === undefined || body?.path === null ? '' : body.path).trim().replace(/\\/g, '/');
    const key = raw.length > 0 ? raw.charAt(0).toUpperCase() + raw.slice(1) : raw;
    const name = key.split('/').pop() ?? key;
    debugState.fsReads.push('win:' + key);
    const winContent = WINDOWS_FILES.get(key);
    if (winContent === undefined) {
      return ok({
        path: key, name, size: 0, sha256: '0'.repeat(64), encoding: 'utf8', content: '',
        truncated: false, binary: false, serverTime: NOW()
      });
    }
    return ok({
      path: key, name, size: winContent.length, sha256: 'a'.repeat(64), encoding: 'utf8',
      content: winContent, truncated: false, binary: false, serverTime: NOW()
    });
  }
  if (fsReadMatch !== null && method === 'POST'
    && findConnector(decodeURIComponent(fsReadMatch[1])) !== undefined) {
    const key = relativeKey(body?.path);
    debugState.fsReads.push(key);
    const content = VIRTUAL_FILES.get(key);
    if (content === undefined) {
      return ok({
        path: WORKSPACE_ROOT_LOCAL + '/' + key, name: key.split('/').pop() ?? key, size: 0,
        sha256: '0'.repeat(64), encoding: 'utf8', content: '', truncated: false,
        binary: false, serverTime: NOW()
      });
    }
    const name = key.split('/').pop() ?? key;
    return ok({
      path: WORKSPACE_ROOT_LOCAL + '/' + key, name, size: content.length,
      sha256: 'a'.repeat(64), encoding: 'utf8', content, truncated: false,
      binary: false, serverTime: NOW()
    });
  }

  // ---- 终端 ----------------------------------------------------------------
  if (route === `/connectors/${CONNECTOR_ID}/terminals-v2` && method === 'POST') {
    return ok({
      ok: true,
      result: {
        terminalId: 'term-mock-1', sessionId: CONNECTOR_ID, label: 'zsh', cwd: '/Users/mock/code/agents-anywhere',
        cols: body?.cols ?? 80, rows: body?.rows ?? 24, purpose: 'user', pid: 4242, status: 'running',
        scrollbackBytes: 4096, scrollbackSeq: 1
      }
    });
  }
  if (route === `/connectors/${CONNECTOR_ID}/terminals-v2` && method === 'GET') {
    return ok({ ok: true, result: { terminals: [] } });
  }
  if (route.startsWith(`/connectors/${CONNECTOR_ID}/terminals-v2/`) && method === 'DELETE') {
    return ok({ ok: true });
  }

  sendJson(response, 404, { detail: { code: 'not_found', message: `模拟服务端没有实现 ${method} ${path}` } });
});

// ---------------------------------------------------------------------------
// WebSocket 升级
// ---------------------------------------------------------------------------

/** sessionId -> Set<WsConnection> */
const sessionSockets = new Map();
/** terminalId -> Set<WsConnection> */
const terminalSockets = new Map();

function queueSessionEvent(sessionId, type, payload) {
  const sockets = sessionSockets.get(sessionId);
  if (sockets === undefined) {
    return;
  }
  for (const socket of sockets) {
    socket.sendJson({
      protocolVersion: '2', eventId: 'evt-' + Math.random().toString(16).slice(2),
      sequence: Date.now(), cursor: 'seq:' + Date.now(), type, sessionId,
      emittedAt: NOW(), payload
    });
  }
}

server.on('upgrade', (request, socket, head) => {
  const key = request.headers['sec-websocket-key'];
  const url = new URL(request.url, `http://${request.headers.host}`);
  const route = url.pathname.startsWith('/api/v2/') ? url.pathname.slice('/api/v2'.length) : url.pathname;

  if (typeof key !== 'string') {
    socket.destroy();
    return;
  }
  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );
  log('WS  ', `${route}${url.search}`);

  const connection = new WsConnection(socket);

  // 工作台通道：连接即推全量快照
  if (route === '/dashboard/ws') {
    const activeList = sessions.filter((item) => !item.archived);
    const archivedList = sessions.filter((item) => item.archived);
    // 分页模式下快照**只带首页**（正是上游客户端 replacedByDashboardSnapshot 的假设：
    // 快照覆盖 firstPageIds），sessionPages 给出真实的 hasMore/nextCursor，
    // 这样「快照到来后不丢已加载的后续页」这条合并策略才能被端到端验收出来。
    const activePage = PAGINATED ? sessionPageOf(activeList, 0, PAGE_SIZE) : null;
    const archivedPage = PAGINATED ? sessionPageOf(archivedList, 0, PAGE_SIZE) : null;
    // 抽成函数是为了 `--dashboard-churn` 能按固定周期重推**同一份**内容
    // （每次现算，但输入未变 ⇒ 输出逐字节相同，正是「刷新了但数据没变」的场景）。
    const dashboardSnapshot = () => ({
      type: 'dashboard.snapshot',
      connectors: allConnectors(),
      projects,
      sessions: PAGINATED ? activePage.sessions.concat(archivedPage.sessions) : sessions,
      sessionPages: PAGINATED ? {
        active: { hasMore: activePage.hasMore, nextCursor: activePage.nextCursor },
        archived: { hasMore: archivedPage.hasMore, nextCursor: archivedPage.nextCursor }
      } : {
        active: { hasMore: false, nextCursor: null },
        archived: { hasMore: false, nextCursor: null }
      },
      serverTime: NOW()
    });
    connection.sendJson(dashboardSnapshot());
    if (DASHBOARD_CHURN > 0) {
      const period = Math.max(50, Math.round(1000 / DASHBOARD_CHURN));
      const churnTimer = setInterval(() => {
        if (connection.closed) {
          clearInterval(churnTimer);
          return;
        }
        connection.sendJson(dashboardSnapshot());
      }, period);
      connection.onClose = () => {
        clearInterval(churnTimer);
      };
    }
    // `--dashboard-order-churn N`：两个未置顶项目交替成为「最近活动」——项目行顺序因此每次
    // 快照都重排。这正是「多个工作区交替产生活动 ⇒ 首页项目行来回换位」的最小复现。
    if (DASHBOARD_ORDER_CHURN > 0) {
      if (!MULTI_PROJECTS) {
        log('WARN', '--dashboard-order-churn 需要 --multi-projects（否则没有两个未置顶项目可换位）');
      }
      const period = Math.max(50, Math.round(1000 / DASHBOARD_ORDER_CHURN));
      const rotating = [PROJECT_ID_2, PROJECT_ID_3];
      let turn = 0;
      const orderTimer = setInterval(() => {
        if (connection.closed) {
          clearInterval(orderTimer);
          return;
        }
        const targetId = rotating[turn % rotating.length];
        turn += 1;
        for (const item of projects) {
          if (item.id === targetId) {
            item.lastActivityAt = NOW();
          }
        }
        // 夹具自证：真的在轮转（否则「改后界面不动」会退化成假 PASS）。
        debugState.orderChurnTicks += 1;
        debugState.orderChurnTargets.push(targetId);
        connection.sendJson(dashboardSnapshot());
      }, period);
      connection.onClose = () => {
        clearInterval(orderTimer);
      };
    }
    return;
  }

  // 会话通道：先 subscribed，再推一条迟到的时间线更新
  const sessionWs = route.match(/^\/sessions\/([^/]+)\/ws$/);
  if (sessionWs !== null) {
    const sessionId = decodeURIComponent(sessionWs[1]);
    if (!sessionSockets.has(sessionId)) {
      sessionSockets.set(sessionId, new Set());
    }
    sessionSockets.get(sessionId).add(connection);
    // `--session-churn N`：高频推送同内容事件，逼出「合批 → 重投影」这条路径（R43 新增）。
    let sessionChurnTimer = -1;
    if (SESSION_CHURN > 0) {
      sessionChurnTimer = setInterval(() => {
        for (let i = 0; i < SESSION_CHURN; i++) {
          queueSessionEvent(sessionId, 'timeline.item_updated', { item: timelineItems[timelineItems.length - 1] });
        }
      }, 1000);
    }
    connection.onClose = () => {
      sessionSockets.get(sessionId)?.delete(connection);
      if (sessionChurnTimer >= 0) { clearInterval(sessionChurnTimer); }
    };
    connection.sendJson({
      protocolVersion: '2', eventId: 'evt-subscribed', sequence: 1, cursor: 'seq:1',
      type: 'session.subscribed', sessionId, emittedAt: NOW(),
      payload: { sessionId, eventCursor: 'seq:5' }
    });
    return;
  }

  // 终端通道：回放一段带 ANSI 的屏幕
  const terminalWs = route.match(/^\/connectors\/([^/]+)\/terminals-v2\/([^/]+)\/stream$/);
  if (terminalWs !== null) {
    const terminalId = decodeURIComponent(terminalWs[2]);
    if (!terminalSockets.has(terminalId)) {
      terminalSockets.set(terminalId, new Set());
    }
    terminalSockets.get(terminalId).add(connection);
    connection.onClose = () => {
      terminalSockets.get(terminalId)?.delete(connection);
    };
    connection.onText = (text) => {
      let message;
      try {
        message = JSON.parse(text);
      } catch (error) {
        return;
      }
      if (message?.type === 'input') {
        const decoded = Buffer.from(String(message.data ?? ''), 'base64').toString('utf8');
        log('  ↳', `终端输入 ${JSON.stringify(decoded)}`);
        // 把输入回显给所有观察者，形成"可交互"的闭环
        const echo = `\r\n\u001b[36m[echo]\u001b[0m ${decoded.replace(/\r/g, '\r\n')}`;
        for (const viewer of terminalSockets.get(terminalId) ?? []) {
          viewer.sendJson({ type: 'output', data: Buffer.from(echo, 'utf8').toString('base64'), seq: 2 });
        }
      } else if (message?.type === 'resize') {
        log('  ↳', `终端 resize cols=${message.cols} rows=${message.rows}`);
      } else if (message?.type === 'ping') {
        connection.sendJson({ type: 'pong' });
      }
    };
    connection.sendJson({
      type: 'replay',
      data: Buffer.from(RULER ? terminalRuler() : terminalReplay(), 'utf8').toString('base64'),
      seq: 1
    });
    return;
  }

  connection.sendJson({ type: 'error', code: 404, message: `未实现的 WS 路由：${route}` });
});

server.listen(PORT, HOST, () => {
  console.log('Agents Anywhere v2 模拟服务端已启动');
  console.log(`  HTTP/WS 根地址： http://${HOST}:${PORT}`);
  console.log(`  App 里填：       ${HOST}:${PORT}`);
  console.log(`  登录：任意邮箱 + 任意非空密码`);
  console.log(`  健康检查：       http://${HOST}:${PORT}/api/v2/health`);
  if (PAGINATED) {
    const activeTotal = sessions.filter((item) => !item.archived).length;
    const archivedTotal = sessions.filter((item) => item.archived).length;
    console.log(`  分页夹具：       已启用（--page-size ${PAGE_SIZE}）`);
    console.log(`                   活动会话 ${activeTotal} 条 / 已归档 ${archivedTotal} 条（额外会话标题形如「分页会话 A01」）`);
    console.log(`                   首页：  GET /api/v2/sessions?archived=false`);
    console.log(`                   下一页：GET /api/v2/sessions?archived=false&cursor=${SESSION_CURSOR_PREFIX}${PAGE_SIZE}`);
    console.log(`                   注：夹具忽略请求的 limit，页大小只看 --page-size`);
    console.log('                   请求记录：GET /api/v2/debug/state → sessionPageRequests');
  } else {
    console.log('  分页夹具：       未启用（加 --page-size N 可开 GET /sessions 真分页）');
  }
  // `--win-device`：额外挂一台 Windows 设备（默认不开）。
  // 真实环境里的 Connector 往往就是一台 Windows 机器（`C:\Users\<user>` 形态），
  // 不挂这台设备时「盘符总览 / 这台电脑」这条分支在模拟器上永远走不到。
  if (process.argv.includes('--win-device')) {
    console.log('  Windows 设备：   已挂载 conn-mock-win（盘符总览 C:/ D:/ E:）');
  } else {
    console.log('  Windows 设备：   未挂载（加 --win-device 可验「盘符总览/这台电脑」分支）');
  }
  // `--input-request`：公告换成**提问表单**（R50）。
  if (INPUT_REQUEST) {
    console.log('  提问表单夹具：   已启用（公告 = notice-mock-question，2 题：单选 + 多选，均允许「其他」）');
    console.log('                   响应记录：GET /api/v2/debug/state → noticeResponses');
  } else {
    console.log('  提问表单夹具：   未启用（加 --input-request 可验「Agent 提问 → 提问框」）');
  }
  if (DASHBOARD_ORDER_CHURN > 0) {
    console.log('  项目顺序抖动夹具： 已启用（--dashboard-order-churn ' + DASHBOARD_ORDER_CHURN
      + '，两个未置顶项目交替成为最近活动）');
  } else {
    console.log('  项目顺序抖动夹具： 未启用（加 --dashboard-order-churn N --multi-projects 可复现「首页项目跳动」）');
  }
  console.log('  Ctrl+C 停止（验收结束请立刻停止，别把端口长期开着）');
});
