/**
 * 「直接开新对话」的草稿会话（prepared session）纯逻辑 —— R53 新增。
 *
 * 用户原话：「新建对话逻辑改为直接在指定工作区开启对话，不需要先选模型，
 * 发首条对话等才启动，逻辑看能不能做成和 DSH 电脑端一样」。
 *
 * ## 为什么要「草稿会话」这一层
 *
 * DSH 电脑端（以及本工程复刻的上游 Android 端）里，点「新建对话」**立刻**就是一个
 * 可输入的对话界面：工作区已经定好、输入框就在眼前，模型不必事先挑。真正的**服务端会话**
 * 是在用户发出**第一条消息**那一刻才创建的 —— 上游把这件事写死在
 * `NewSessionDraft.kt:6-9`：「The Server session and runtime thread are created only when
 * the user sends the first real message from the conversation screen.」
 *
 * 本工程此前必须先过「新建会话」表单（选设备 / Agent / 工作区 / 模型 / 权限，还要填首条消息），
 * 用户把它读成「新建对话很麻烦」。R53 改成草稿会话后：
 *  ① 点「+」直接进对话页 —— 设备 / Agent / 工作区按**记忆与最近使用**自动定好，可就地切换；
 *  ② 模型 / 权限 / Agent 预设**不要求先选**（有记忆就沿用记忆，没有就用服务端默认，
 *  会话建好后还能在 ⚙ 里改）；
 *  ③ 首条消息才触发 `create-and-start`（这也是服务端契约：DSH 运行时要求
 *  `content` 非空 —— `connector/runtimes/dsh/runtime.py:327`，空内容建会话会先在服务端
 *  落一条失败会话，是个更差的结果）。
 *
 * ## 为什么单独抽成模块
 *
 * 「默认选哪台设备 / 哪个 Agent / 哪个工作区」是一串有优先级的回落链，而且在真机上很难把
 * 各种组合（记忆失效、设备离线、运行时卡在 starting、设备下没有项目）都造出来。抽成
 * 零依赖纯函数后，全部组合都能在 Node 里断言（`tools/logic-test/suite-new-chat.mjs`）。
 *
 * ⚠️ ArkTS **不支持结构化类型**（`arkts-no-structural-typing`，见 `SessionGating.runtimeIsReady`
 * 的注释）：本模块不直接收 `AgentDevice` / `RemoteDeviceRuntime` 这类 UI 侧对象，
 * 而是收本文件里定义的**窄接口**，由页面显式映射（多写几行 `{ id: … }` 字面量，
 * 换来「可以在 Node 里构造夹具」）。
 */

import { NewSessionPreferenceEntry, pickRestorableDevice, pickRestorableRuntime } from './NewSessionPreference';

/** 路由参数分隔符（与 `pages/Index.ets` 的 `paramAt()` 同一约定）。 */
export const NEW_CHAT_ENTRY_SEPARATOR: string = '|';

/**
 * 进入「新对话」时可选带上的**指定工作区**提示（目前只有 `connectorId|projectId`）。
 *
 * 目前首页 FAB 不带参数（工作区在工作区内就地切换）；这个参数是为「从某个项目行直接开对话」
 * 这类入口预留的 —— 带参数时优先用它，解析不出来就当作没带。
 */
export interface NewChatEntry {
  connectorId: string;
  projectId: string;
}

export function emptyNewChatEntry(): NewChatEntry {
  return { connectorId: '', projectId: '' };
}

export function encodeNewChatEntry(connectorId: string, projectId: string): string {
  const connector = connectorId.trim();
  const project = projectId.trim();
  if (connector.length === 0 && project.length === 0) {
    return '';
  }
  return connector + NEW_CHAT_ENTRY_SEPARATOR + project;
}

/** 解析路由参数；任何缺段 / 空段都退化成空串（**不抛异常** —— 它只是「省一次点击」）。 */
export function parseNewChatEntry(raw: string): NewChatEntry {
  const entry = emptyNewChatEntry();
  if (raw.length === 0) {
    return entry;
  }
  const parts = raw.split(NEW_CHAT_ENTRY_SEPARATOR);
  if (parts.length >= 1) {
    entry.connectorId = parts[0].trim();
  }
  if (parts.length >= 2) {
    entry.projectId = parts[1].trim();
  }
  return entry;
}

// ---------------------------------------------------------------------------
// 窄接口（页面从 AgentDevice / AgentProject / AgentSession / RemoteDeviceRuntime 映射）
// ---------------------------------------------------------------------------

export interface NewChatDevice {
  id: string;
  name: string;
  online: boolean;
}

export interface NewChatProject {
  id: string;
  connectorId: string;
  name: string;
  workspacePath: string;
  pinned: boolean;
}

export interface NewChatSession {
  id: string;
  connectorId: string;
  projectId: string;
  cwd: string;
  sortKey: string;
}

export interface NewChatRuntime {
  runtimeId: string;
  runtimeType: string;
  displayName: string;
  configured: boolean;
  active: boolean;
  status: string;
}

/**
 * 草稿页的「库存」快照 —— 未就绪分支的判定输入。
 *
 * `readyRuntimeCount` / `settling` 由页面用 `SessionGating.runtimeIsReady` /
 * `runtimeIsSettling`（同一口径，已是既有纯函数）算好后传进来，本模块不重复实现一份。
 */
export interface NewChatInventory {
  deviceCount: number;
  loadingRuntimes: boolean;
  runtimeCount: number;
  readyRuntimeCount: number;
  settling: boolean;
  projectCount: number;
}

/** 未就绪分支的枚举（用类常量而不是 `enum`：ArkTS 的 `enum` 在本工程一律避免）。 */
export class DraftSetupKind {
  /** 设备 / Agent / 工作区都齐了，可以输入。 */
  static readonly READY: string = 'ready';
  /** 一台设备都没配对。 */
  static readonly NO_DEVICE: string = 'no-device';
  /** 正在拉运行时列表。 */
  static readonly LOADING: string = 'loading';
  /** 设备在线，但这台设备上没发现任何 Agent。 */
  static readonly NO_RUNTIME: string = 'no-runtime';
  /** Agent 在启动 / 停止的过渡态。 */
  static readonly SETTLING: string = 'settling';
  /** 有 Agent 但没启用（未激活）。 */
  static readonly INACTIVE: string = 'inactive';
  /** Agent 就绪，但这台设备上还没有工作区。 */
  static readonly NO_PROJECT: string = 'no-project';
}

/**
 * 判定草稿页当前处于哪个分支。
 *
 * 顺序有讲究（与 `NewSessionScreen.setupKind` 同序）：**先设备、再加载中、再没有 Agent、
 * 再过渡态、再未启用**，最后才轮到工作区 —— 前几项是用户无从绕过的前置条件，
 * 先说工作区会把人指向一个点进去还是不能用的按钮。
 */
export function draftSetupKind(inventory: NewChatInventory): string {
  if (inventory.deviceCount === 0) {
    return DraftSetupKind.NO_DEVICE;
  }
  if (inventory.loadingRuntimes) {
    return DraftSetupKind.LOADING;
  }
  if (inventory.runtimeCount === 0) {
    return DraftSetupKind.NO_RUNTIME;
  }
  if (inventory.settling && inventory.readyRuntimeCount === 0) {
    return DraftSetupKind.SETTLING;
  }
  if (inventory.readyRuntimeCount === 0) {
    return DraftSetupKind.INACTIVE;
  }
  if (inventory.projectCount === 0) {
    return DraftSetupKind.NO_PROJECT;
  }
  return DraftSetupKind.READY;
}

/** 分支标题（文案逐字取 `NewSessionScreen.setupTitle`，两处页面不能各说一套）。 */
export function draftSetupTitle(kind: string): string {
  if (kind === DraftSetupKind.NO_DEVICE) {
    return '还没有配对的设备';
  }
  if (kind === DraftSetupKind.LOADING) {
    return '正在检查设备上的 Agent…';
  }
  if (kind === DraftSetupKind.NO_RUNTIME) {
    return '这台设备上还没发现 Agent';
  }
  if (kind === DraftSetupKind.SETTLING) {
    return 'Agent 正在启动';
  }
  if (kind === DraftSetupKind.NO_PROJECT) {
    return '这台设备上还没有工作区';
  }
  return 'Agent 还没有启用';
}

/** 分支正文；`reason` 是过渡态时服务端给的原话（没有就退回通用句）。 */
export function draftSetupDescription(kind: string, reason: string): string {
  if (kind === DraftSetupKind.NO_DEVICE) {
    return '先在工作电脑上运行 Connector，再用配对码把它接到这里。';
  }
  if (kind === DraftSetupKind.LOADING) {
    return '稍候片刻，检查完会自动进入下一步。';
  }
  if (kind === DraftSetupKind.NO_RUNTIME) {
    return '到设备详情里点「发现 Runtime」，看看这台设备上装了哪些 Agent。';
  }
  if (kind === DraftSetupKind.SETTLING) {
    return reason.length > 0 ? '请稍候，' + reason : '请稍候，就绪后会自动出现在可选列表里。';
  }
  if (kind === DraftSetupKind.NO_PROJECT) {
    return '工作区就是 Agent 干活的那个目录。先新建一个，再回来开始对话。';
  }
  return '到设备详情里点「启动」，启用后就能新建会话了。';
}

/** 分支主按钮文案（空串 = 该分支没有可执行动作，按钮不显示）。 */
export function draftSetupActionLabel(kind: string): string {
  if (kind === DraftSetupKind.NO_DEVICE) {
    return '配对新设备';
  }
  if (kind === DraftSetupKind.LOADING) {
    return '';
  }
  if (kind === DraftSetupKind.NO_RUNTIME) {
    return '去设备详情';
  }
  if (kind === DraftSetupKind.SETTLING) {
    return '重新检查';
  }
  if (kind === DraftSetupKind.NO_PROJECT) {
    return '新建工作区';
  }
  return '去设备详情启动';
}

// ---------------------------------------------------------------------------
// 默认选择：设备 → Agent → 工作区
// ---------------------------------------------------------------------------

/**
 * 选设备：**记忆里那台还在列表里就用它**（R47 口径），否则第一台**在线**设备，最后才是第一台。
 *
 * 「在线优先」是刻意的：设备全部离线时列表里第一台可能正好是坏掉的那台，
 * 直接选它会让人在对话页里等着一个永远连不上的 Agent。
 */
export function pickDraftDevice(entry: NewSessionPreferenceEntry | undefined,
  preferredDeviceId: string, devices: NewChatDevice[]): string {
  if (devices.length === 0) {
    return '';
  }
  const ids: string[] = [];
  for (let i = 0; i < devices.length; i++) {
    ids.push(devices[i].id);
  }
  const preferred = preferredDeviceId.trim();
  if (preferred.length > 0 && ids.indexOf(preferred) >= 0) {
    return preferred;
  }
  const remembered = pickRestorableDevice(entry, ids);
  if (remembered.length > 0) {
    return remembered;
  }
  for (let i = 0; i < devices.length; i++) {
    if (devices[i].online) {
      return devices[i].id;
    }
  }
  return devices[0].id;
}

/** 该设备下的工作区（保持服务端给的顺序）。 */
export function projectsForDevice(connectorId: string, projects: NewChatProject[]): NewChatProject[] {
  const out: NewChatProject[] = [];
  for (let i = 0; i < projects.length; i++) {
    if (projects[i].connectorId === connectorId) {
      out.push(projects[i]);
    }
  }
  return out;
}

export function findProject(projects: NewChatProject[], projectId: string): NewChatProject | undefined {
  for (let i = 0; i < projects.length; i++) {
    if (projects[i].id === projectId) {
      return projects[i];
    }
  }
  return undefined;
}

export function findRuntime(runtimes: NewChatRuntime[], runtimeId: string): NewChatRuntime | undefined {
  for (let i = 0; i < runtimes.length; i++) {
    if (runtimes[i].runtimeId === runtimeId) {
      return runtimes[i];
    }
  }
  return undefined;
}

/**
 * 某个会话所在的工作区 id（查不到 / 未绑定项目 / 会话已不在列表里都返回空串）。
 *
 * 调用方用它实现 DSH 回退链的第 ②级 —— 「当前会话所属工作区」
 * （`dsh-client-ui-workspace/lib/client.js:887-901`：`workspaceId ?? currentWorkspaceId ?? recent`）：
 * 页面把「最后打开过的会话 id」传进来，得到它所属的工作区作为**优先项**。
 */
export function projectIdOfSession(sessions: NewChatSession[], sessionId: string): string {
  const id = sessionId.trim();
  if (id.length === 0) {
    return '';
  }
  for (let i = 0; i < sessions.length; i++) {
    if (sessions[i].id === id) {
      return sessions[i].projectId;
    }
  }
  return '';
}

/**
 * 选工作区（= 会话的 `cwd`）—— 四级回退，与 DSH 电脑端同序：
 *  ① 显式指定 / 最后打开的那个会话所在的工作区（`preferredProjectId`）；
 *  ② **这台设备最近更新过的那条会话所在的工作区**；
 *  ③ 该设备下的第一个工作区。
 *
 * 第 ② 条是「和 DSH 电脑端一样」的关键：新开对话默认落回你上次干活的那个目录，
 * 而不是项目列表里的第一个。本工程不额外存「上次项目」——最近会话的 `projectId` 就是这件事的
 * 现成证据（`DashboardStore.activeSessions` 里带着服务端排好序的 `sortKey`）。
 */
export function pickDraftProject(connectorId: string, preferredProjectId: string,
  projects: NewChatProject[], sessions: NewChatSession[]): string {
  const candidates = projectsForDevice(connectorId, projects);
  if (candidates.length === 0) {
    return '';
  }
  const preferred = preferredProjectId.trim();
  if (preferred.length > 0 && findProject(candidates, preferred) !== undefined) {
    return preferred;
  }
  let recentProjectId = '';
  let recentSortKey = '';
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (session.connectorId !== connectorId || session.projectId.length === 0) {
      continue;
    }
    if (findProject(candidates, session.projectId) === undefined) {
      continue;
    }
    if (session.sortKey > recentSortKey) {
      recentSortKey = session.sortKey;
      recentProjectId = session.projectId;
    }
  }
  if (recentProjectId.length > 0) {
    return recentProjectId;
  }
  return candidates[0].id;
}

/**
 * 选 Agent：① 记忆里的那个（仍属于这台设备且就绪）；② 第一个 **active** 的就绪项；③ 第一个就绪项。
 *
 * 与 `NewSessionScreen.fetchRuntimes` 的收敛口径一致 —— **只从就绪集合里挑**：
 * 服务端 `create-and-start` 会 `require_running=True`，挑一个没启用的 Agent，
 * 用户填完消息点发送只会收到 `runtime instance 'rti_…' is not running`（真机实测过）。
 */
export function pickDraftRuntime(entry: NewSessionPreferenceEntry | undefined,
  connectorId: string, runtimes: NewChatRuntime[]): string {
  const ready: NewChatRuntime[] = [];
  for (let i = 0; i < runtimes.length; i++) {
    const runtime = runtimes[i];
    if (runtime.configured && runtime.active && runtime.status === 'running') {
      ready.push(runtime);
    }
  }
  if (ready.length === 0) {
    return '';
  }
  const readyIds: string[] = [];
  for (let i = 0; i < ready.length; i++) {
    readyIds.push(ready[i].runtimeId);
  }
  const remembered = pickRestorableRuntime(entry, connectorId, readyIds);
  if (remembered.length > 0) {
    return remembered;
  }
  for (let i = 0; i < ready.length; i++) {
    if (ready[i].active) {
      return ready[i].runtimeId;
    }
  }
  return ready[0].runtimeId;
}

/** 工作区显示名：有项目名就用项目名，否则取路径末段，再否则原样。 */
export function workspaceLabelFor(projectName: string, cwd: string): string {
  const name = projectName.trim();
  if (name.length > 0) {
    return name;
  }
  let trimmed = cwd.trim();
  while (trimmed.endsWith('/') || trimmed.endsWith('\\')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.length === 0) {
    return '';
  }
  let cut = trimmed.lastIndexOf('/');
  const back = trimmed.lastIndexOf('\\');
  if (back > cut) {
    cut = back;
  }
  const tail = cut >= 0 ? trimmed.substring(cut + 1) : trimmed;
  return tail.length > 0 ? tail : trimmed;
}

/**
 * 草稿页顶栏副标题：「设备 · Agent · 工作区」。
 *
 * 与 `AgentSession.metaLabel` 同序（会话详情顶栏用的是同一个顺序），
 * 目的是「新建时看到的那行字」与「建好后详情页顶栏那行字」是同一个形状，切换不突兀。
 */
export function draftSubtitle(deviceName: string, runtimeLabel: string, workspaceLabel: string): string {
  const parts: string[] = [];
  if (deviceName.trim().length > 0) {
    parts.push(deviceName.trim());
  }
  if (runtimeLabel.trim().length > 0) {
    parts.push(runtimeLabel.trim());
  }
  if (workspaceLabel.trim().length > 0) {
    parts.push(workspaceLabel.trim());
  }
  let out = '';
  for (let i = 0; i < parts.length; i++) {
    out = i === 0 ? parts[i] : out + ' · ' + parts[i];
  }
  return out;
}
