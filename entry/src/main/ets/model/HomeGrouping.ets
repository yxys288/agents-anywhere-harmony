/**
 * 首页「项目视图」的纯逻辑（对应 Android `feature/sessions/SidebarSelectors.kt` 的
 * `ProjectSessionStatusFilter` / `projectSessionMatchesStatus` / `projectHasVisibleSessions` /
 * `sortProjectsByActivity` / `sessionListComparator`）。
 *
 * ⚠️ 本文件被 `ui/screens/HomeScreen.ets` 与 Node 侧自测 `tools/logic-test/suite-home.mjs`
 * **共用**，因此**绝不能 import 任何 `@kit.*` / ArkUI 符号** —— 一 import，
 * Node 侧转译产物 require 时就会炸（工程惯例见 `feature/TimelineProjection.ets`）。
 *
 * 把它单独拆出来的理由（第一轮起的老教训）：首页的分组/排序/筛选是「会出错但看不见」的那部分
 * （顺序错、筛选漏项、置顶重复出现都只在特定数据下暴露），拆成纯函数后能在不装设备的情况下逐条断言。
 */

import { AgentDevice, AgentProject, AgentSession, SessionStatus } from './AppModels';

// ---------------------------------------------------------------------------
// 筛选档
// ---------------------------------------------------------------------------

/**
 * 「项目会话状态」筛选档（上游 `ProjectSessionStatusFilter`）。
 *
 * ⚠️ 用字符串常量而不是 `enum`：本工程 ArkTS 约束禁用 `enum`/`namespace`
 * （既有枚举如 `SessionStatus` 是历史遗留，新代码一律按 `Route` 那套静态常量写）。
 */
export class ProjectSessionFilter {
  static readonly ACTIVE: string = 'active';
  static readonly ARCHIVED: string = 'archived';
  static readonly ALL: string = 'all';
}

/** 把任意输入归一到三个合法档位（默认 `active`，与上游 `HomeProjectPreferences` 的兜底一致）。 */
export function normalizeProjectSessionFilter(value: string): string {
  if (value === ProjectSessionFilter.ARCHIVED) {
    return ProjectSessionFilter.ARCHIVED;
  }
  if (value === ProjectSessionFilter.ALL) {
    return ProjectSessionFilter.ALL;
  }
  return ProjectSessionFilter.ACTIVE;
}

/** 筛选档中文标签（对应上游 `home_project_filter_active|archived|all`）。 */
export function projectSessionFilterLabel(filter: string): string {
  if (filter === ProjectSessionFilter.ARCHIVED) {
    return '已归档';
  }
  if (filter === ProjectSessionFilter.ALL) {
    return '全部';
  }
  return '活跃会话';
}

/**
 * 「加载更多」在当前筛选档下应该对哪一侧翻页。
 *
 * 返回 `true` = 归档侧。`all` 档以**活跃侧**为准：归档侧本身没有与活跃侧合并的游标，
 * 强行合并会让两侧的 `hasMore` 互相覆盖（见 `model/SessionPaging.ets` 的按侧分状态设计）。
 */
export function pagingSideIsArchived(filter: string): boolean {
  return filter === ProjectSessionFilter.ARCHIVED;
}

// ---------------------------------------------------------------------------
// 时间与排序
// ---------------------------------------------------------------------------

/** ISO 时间 → 毫秒；缺失 / 非法一律 0（对齐上游 `timestampMillis`）。 */
export function parseTimestampMillis(value: string | undefined): number {
  if (value === undefined || value.length === 0) {
    return 0;
  }
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** 会话是否「正在跑」（上游 `status == Running || optimisticTopUntil > now`）。 */
function isRunningSession(session: AgentSession): boolean {
  return session.status === SessionStatus.Running || session.live;
}

/**
 * 项目内会话排序（对齐上游 `sessionListComparator`）：
 * 置顶 → 运行中 → 运行中按 id 升序 → 其余按最近活动倒序 → id 倒序。
 *
 * ⚠️ 与 `AppModels.compareSessions` **不是**同一个口径：后者是全局列表排序（置顶 → sortKey → updatedSeq），
 * 上游在项目树里用的是「运行中的排最前」，两者刻意保留差异。
 */
export function sortSessionsForProject(sessions: AgentSession[]): AgentSession[] {
  const copy = sessions.slice();
  copy.sort((left: AgentSession, right: AgentSession): number => {
    if (left.pinned !== right.pinned) {
      return left.pinned ? -1 : 1;
    }
    const leftRunning = isRunningSession(left);
    const rightRunning = isRunningSession(right);
    if (leftRunning !== rightRunning) {
      return leftRunning ? -1 : 1;
    }
    if (leftRunning) {
      return left.id < right.id ? -1 : (left.id > right.id ? 1 : 0);
    }
    const leftAt = parseTimestampMillis(left.sortKey);
    const rightAt = parseTimestampMillis(right.sortKey);
    if (leftAt !== rightAt) {
      return rightAt - leftAt;
    }
    return left.id < right.id ? 1 : (left.id > right.id ? -1 : 0);
  });
  return copy;
}

// ---------------------------------------------------------------------------
// 筛选
// ---------------------------------------------------------------------------

/**
 * 会话是否属于当前筛选档（对齐上游 `projectSessionMatchesStatus`）。
 *
 * ⚠️ `active` 档**排除置顶会话**：置顶会话在列表顶部的「置顶」区单列，
 * 不在项目树下重复出现 —— 这是上游刻意设计的，去掉就会出现「同一条会话两处都在」。
 */
export function sessionMatchesProjectFilter(session: AgentSession, filter: string): boolean {
  if (filter === ProjectSessionFilter.ARCHIVED) {
    return session.archived;
  }
  if (filter === ProjectSessionFilter.ALL) {
    return session.archived || !session.pinned;
  }
  return !session.archived && !session.pinned;
}

/** 某个项目在当前筛选档下的会话（已排序；未绑项目的会话返回空数组）。 */
export function sessionsOfProject(
  all: AgentSession[], projectId: string, filter: string
): AgentSession[] {
  const out: AgentSession[] = [];
  if (projectId.length === 0) {
    return out;
  }
  for (let i = 0; i < all.length; i++) {
    const session = all[i];
    const sessionProjectId = session.projectId !== undefined ? session.projectId : '';
    if (sessionProjectId === projectId && sessionMatchesProjectFilter(session, filter)) {
      out.push(session);
    }
  }
  return sortSessionsForProject(out);
}

/** 项目 id → 当前筛选档下的会话（只含至少有一条会话的项目）。 */
export function visibleSessionsByProject(
  all: AgentSession[], filter: string
): Map<string, AgentSession[]> {
  const buckets: Map<string, AgentSession[]> = new Map<string, AgentSession[]>();
  for (let i = 0; i < all.length; i++) {
    const session = all[i];
    const projectId = session.projectId !== undefined ? session.projectId : '';
    if (projectId.length === 0 || !sessionMatchesProjectFilter(session, filter)) {
      continue;
    }
    const bucket = buckets.get(projectId);
    if (bucket === undefined) {
      buckets.set(projectId, [session]);
    } else {
      bucket.push(session);
    }
  }
  const out: Map<string, AgentSession[]> = new Map<string, AgentSession[]>();
  buckets.forEach((bucket: AgentSession[], projectId: string) => {
    out.set(projectId, sortSessionsForProject(bucket));
  });
  return out;
}

/**
 * 项目在当前筛选档下是否要出现在列表里（对齐上游 `projectHasVisibleSessions`）。
 *
 * 上游优先用服务端给的 `sidebarSessionCounts`，本工程线格式里没有该字段，
 * 因此一律回落到「按已加载会话判断」；但**手动创建的项目即便还没有会话也保留**
 * （`manuallyCreated`）—— 否则用户刚在「+」里建好的项目建完就消失，看起来像失败了。
 */
export function projectHasVisibleSessions(
  project: AgentProject, all: AgentSession[], filter: string
): boolean {
  if (project.manuallyCreated) {
    return true;
  }
  return sessionsOfProject(all, project.id, filter).length > 0;
}

// ---------------------------------------------------------------------------
// 项目排序
// ---------------------------------------------------------------------------

/** 某项目下所有已知会话里最近的活动时间（毫秒）；没有则 0。 */
function latestActivityOf(projectId: string, sessions: AgentSession[]): number {
  let latest = 0;
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    const sessionProjectId = session.projectId !== undefined ? session.projectId : '';
    if (sessionProjectId !== projectId) {
      continue;
    }
    const at = parseTimestampMillis(session.sortKey);
    if (at > latest) {
      latest = at;
    }
  }
  return latest;
}

/**
 * 项目是否「空」（人工建好、但既没有会话也没有活动过的项目）。
 * 对齐上游 `empty()`：这类项目排序时**沉底**，避免刚建好的空项目把有会话的项目挤下去。
 */
export function isBlankProject(project: AgentProject, sessions: AgentSession[]): boolean {
  if (!project.manuallyCreated) {
    return false;
  }
  if (project.activeSessionCount > 0) {
    return false;
  }
  const lastActivity = project.lastActivityAt;
  if (lastActivity !== undefined && lastActivity.length > 0) {
    return false;
  }
  for (let i = 0; i < sessions.length; i++) {
    const projectId = sessions[i].projectId;
    if (projectId !== undefined && projectId === project.id) {
      return false;
    }
  }
  return true;
}

/**
 * 项目排序（对齐上游 `sortProjectsByActivity`）：
 * 非空项目在前 → 最近活动（`lastActivityAt` 与项目内会话 sortKey 取最大）倒序
 * → 创建时间倒序 → 名称 → id。
 */
export function sortProjectsByActivity(
  projects: AgentProject[], sessions: AgentSession[]
): AgentProject[] {
  const copy = projects.slice();
  copy.sort((left: AgentProject, right: AgentProject): number => {
    const leftBlank = isBlankProject(left, sessions);
    const rightBlank = isBlankProject(right, sessions);
    if (leftBlank !== rightBlank) {
      return leftBlank ? 1 : -1;
    }
    const leftAt = Math.max(parseTimestampMillis(left.lastActivityAt), latestActivityOf(left.id, sessions));
    const rightAt = Math.max(parseTimestampMillis(right.lastActivityAt), latestActivityOf(right.id, sessions));
    if (leftAt !== rightAt) {
      return rightAt - leftAt;
    }
    const leftCreated = parseTimestampMillis(left.createdAt);
    const rightCreated = parseTimestampMillis(right.createdAt);
    if (leftCreated !== rightCreated) {
      return rightCreated - leftCreated;
    }
    const byName = left.name.localeCompare(right.name);
    if (byName !== 0) {
      return byName;
    }
    return left.id < right.id ? -1 : (left.id > right.id ? 1 : 0);
  });
  return copy;
}

// ---------------------------------------------------------------------------
// 项目行（页面直接消费的数据结构）
// ---------------------------------------------------------------------------

/** 一行项目（左侧文件夹图标 + 项目名 + 会话数，右侧「…」+ 编辑入口）。 */
export interface ProjectRow {
  projectId: string;
  name: string;
  workspacePath: string;
  pinned: boolean;
  /** 当前筛选档下的会话数。 */
  sessionCount: number;
  /** 该行是否已展开（展开后原地列出会话）。 */
  expanded: boolean;
  /** 展开时要渲染的会话（已排序；未展开时同样带出，便于「展开即见」无二次请求）。 */
  sessions: AgentSession[];
}

/**
 * 项目行的**稳定顺序**（R55「项目行固定」）。
 *
 * 背景（用户报的 bug）：`sortProjectsByActivity` 的口径是「最近活动倒序」，而活动时间由服务端在
 * **每次会话更新**时推进；客户端又在**每次 notify**（WS 的 `dashboard.changed` 全量快照、下拉刷新、
 * 写操作后的 `refreshAll`）都重算一遍项目顺序 ⇒ 只要有两个及以上工作区**交替**产生活动，
 * 项目行就会来回换位，用户看到的就是「首页项目频繁跳动」。
 *
 * 规则（用户要求「固定」）：
 *  - 已经出现过的项目：**保持上一次的相对顺序**（活动再新也不换位）；
 *  - 新出现的项目：按规范顺序插到它该在的位置（排在首个「规范序比它靠后」的老项目之前），
 *  于是「新建会话的那个工作区」仍然落在靠上的位置，而不是无脑追加到末尾；
 *  - 本档不渲染（但服务端仍然存在）的项目：仍在返回的 `order` 里 ⇒ 切回该档时回到原位；
 *  服务端已删除的项目自然从 `order` 消失（不占位、也不会回来）。
 *
 * ⚠️ 传空数组 = 完全按规范顺序（= R55 之前的行为），因此老调用方语义不变。
 */
export function stabilizeProjectOrder(
  previousOrder: string[], canonical: AgentProject[]
): AgentProject[] {
  const canonicalRank: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < canonical.length; i++) {
    canonicalRank.set(canonical[i].id, i);
  }
  const previousRank: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < previousOrder.length; i++) {
    const id = previousOrder[i];
    if (previousRank.get(id) === undefined) {
      previousRank.set(id, i);
    }
  }
  const kept: AgentProject[] = [];
  const added: AgentProject[] = [];
  for (let i = 0; i < canonical.length; i++) {
    const project = canonical[i];
    if (previousRank.get(project.id) !== undefined) {
      kept.push(project);
    } else {
      added.push(project);
    }
  }
  kept.sort((left: AgentProject, right: AgentProject): number => {
    return rankOf(previousRank, left.id) - rankOf(previousRank, right.id);
  });
  // 新项目按规范顺序插入（`added` 本身已是规范序）。
  for (let i = 0; i < added.length; i++) {
    const project = added[i];
    const rank = rankOf(canonicalRank, project.id);
    let insertAt = kept.length;
    for (let j = 0; j < kept.length; j++) {
      if (rankOf(canonicalRank, kept[j].id) > rank) {
        insertAt = j;
        break;
      }
    }
    kept.splice(insertAt, 0, project);
  }
  return kept;
}

/** `Map` 取值 + 缺省（`Map.get` 返回 `number | undefined`，直接参与减法在 ArkTS 下不合法）。 */
function rankOf(rank: Map<string, number>, id: string): number {
  const value = rank.get(id);
  return value !== undefined ? value : -1;
}

/** 分组结果：置顶项目 / 普通项目 / 可见项目总数。 */
export interface ProjectRows {
  pinned: ProjectRow[];
  regular: ProjectRow[];
  visibleCount: number;
  /**
   * 全部项目的**稳定顺序**（含当前筛选档下没渲染出来的项目）。
   *
   * ⚠️ 调用方必须把它存下来、下次原样传回 `previousOrder` —— 这是「项目行不随刷新跳动」的
   *  全部机制（见 `stabilizeProjectOrder`）。漏了这一步 = 顺序又回到「每次刷新按活动重排」。
   */
  order: string[];
}

/**
 * 组装项目行 —— 首页「项目」分组的**唯一**数据入口。
 *
 * @param projects 服务端返回的全部项目
 * @param sessions 已加载的全部会话（活跃 + 归档合并后的集合）
 * @param filter `ProjectSessionFilter` 三档
 * @param collapsedIds **被用户手动折叠**的项目 id（R38 起是黑名单语义，见 `ProjectCollapseState`）。
 *  空数组 = 全部展开（= 用户需求「项目默认全部加载」）。持久化在 `@State` / AppStorage 里。
 * @param previousOrder 上一次返回的 `ProjectRows.order`（R55「项目行固定」）。
 *  空数组 = 首次进入，按规范顺序（最近活动）排；非空 = **沿用上一次的顺序**，
 *  只有新项目才按规范顺序插入（见 `stabilizeProjectOrder`）。
 */
export function buildProjectRows(
  projects: AgentProject[], sessions: AgentSession[], filter: string, collapsedIds: string[],
  previousOrder: string[] = []
): ProjectRows {
  const byProject = visibleSessionsByProject(sessions, filter);
  const ordered = stabilizeProjectOrder(previousOrder, sortProjectsByActivity(projects, sessions));
  const pinnedRows: ProjectRow[] = [];
  const regularRows: ProjectRow[] = [];
  for (let i = 0; i < ordered.length; i++) {
    const project = ordered[i];
    const bucket = byProject.get(project.id);
    const members: AgentSession[] = bucket !== undefined ? bucket : [];
    if (!projectHasVisibleSessions(project, sessions, filter) && members.length === 0) {
      continue;
    }
    const row: ProjectRow = {
      projectId: project.id,
      name: project.name,
      workspacePath: project.workspacePath,
      pinned: project.pinned,
      sessionCount: members.length,
      // R38：黑名单语义 —— 不在「手动折叠」集合里就展开（含服务端后续新增的项目）。
      expanded: collapsedIds.indexOf(project.id) < 0,
      sessions: members
    };
    if (project.pinned) {
      pinnedRows.push(row);
    } else {
      regularRows.push(row);
    }
  }
  // 稳定顺序要带上**全部**项目（包括本档没渲染的）—— 否则它在别的档里消失一次就等于丢了位置。
  const order: string[] = [];
  for (let i = 0; i < ordered.length; i++) {
    order.push(ordered[i].id);
  }
  const result: ProjectRows = {
    pinned: pinnedRows,
    regular: regularRows,
    visibleCount: pinnedRows.length + regularRows.length,
    order: order
  };
  return result;
}

/**
 * 顶部「置顶」区的会话（上游 `pinnedSessions`）：置顶且未归档，单独成一区。
 * 当前筛选档为「已归档」时不显示置顶区（归档档里置顶会话没有意义）。
 */
export function pinnedSessionsOf(sessions: AgentSession[], filter: string): AgentSession[] {
  const out: AgentSession[] = [];
  if (filter === ProjectSessionFilter.ARCHIVED) {
    return out;
  }
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (session.pinned && !session.archived) {
      out.push(session);
    }
  }
  return sortSessionsForProject(out);
}

/**
 * 合并「活跃 + 归档」两侧会话并按 id 去重（对齐上游 `associateBy { it.id }` 的合并口径）。
 *
 * 两侧会撞 id：服务端把某条会话从活跃切到归档后，`dashboard.changed` 推送的快照里
 * 它只出现在归档侧，但本地活跃页里那份**已经被翻出来的**副本仍在 —— 不去重就会
 * 在「全部」档下同一条会话出现两次。活跃侧优先（先加入者胜），与上游一致。
 */
export function mergeSessionsById(
  active: AgentSession[], archived: AgentSession[]
): AgentSession[] {
  const out: AgentSession[] = [];
  // R91-T2：`seen` 由**数组 + indexOf** 换成 `Set`（has/add）—— **纯等价替换**，
  // 两段循环的判据、加入顺序、活跃侧优先的语义一字未动。
  //
  // 为什么：`indexOf` 对每个元素线性扫描 ⇒ 整体 O(N²)。而本函数是**首页每次 pull()**
  // 都要走的路径（pull 挂在 DashboardStore 的每次 notify 上：WS 的 dashboard.changed
  // 全量快照、下拉刷新、写操作后的 refreshAll 都会触发），分页把会话加载到几百条时，
  // 每一次刷新都要在主线程烧掉几毫秒。实测（tools/logic-test/ab-bench-t2.mjs）：
  //  N=100 → 0.13 ms，N=300 → 0.89 ms，**N=600 → 4.18 ms**（平方增长）。
  // 换成 Set 后同一基准降到 O(N) 量级。
  //
  // 等价性依据：Set.has/add 与 Array.indexOf/push 在**字符串 id** 上的判等语义完全一致
  // （都是 SameValueZero / 严格相等），且 `out` 的推入顺序、条件判断的短路行为都不变。
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < active.length; i++) {
    const session = active[i];
    if (!seen.has(session.id)) {
      seen.add(session.id);
      out.push(session);
    }
  }
  for (let i = 0; i < archived.length; i++) {
    const session = archived[i];
    if (!seen.has(session.id)) {
      seen.add(session.id);
      out.push(session);
    }
  }
  return out;
}

/**
 * 「最近」区的会话（会话视图用，对齐上游 `SessionsState.recentSessions = sessions.filterNot { it.pinned }`）：
 * 当前筛选档下**非置顶**的会话（置顶的在上面那个区，两处不重叠）。
 */
export function recentSessionsOf(sessions: AgentSession[], filter: string): AgentSession[] {
  const out: AgentSession[] = [];
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (!session.pinned && sessionMatchesProjectFilter(session, filter)) {
      out.push(session);
    }
  }
  return sortSessionsForProject(out);
}

/** 项目行右侧的会话数文案（0 时留空，由展开区显示「暂无会话。」）。 */
export function projectSessionCountLabel(count: number): string {
  return count > 0 ? String(count) : '';
}

/** 展开集合的增删；返回**新数组**，便于直接赋给 `@State`（原地改不触发刷新）。 */
export function toggleExpandedId(ids: string[], id: string, present: boolean): string[] {
  const next = ids.slice();
  const index = next.indexOf(id);
  if (present && index < 0) {
    next.push(id);
  } else if (!present && index >= 0) {
    next.splice(index, 1);
  }
  return next;
}

/**
 * **点击项目行**之后的新折叠集合（R38）。
 *
 * 为什么要有这个函数：R38 把集合语义从「展开白名单」反转成「折叠黑名单」时，
 * 调用点只换了变量名、没换 `present` 的语义 —— `toggleExpandedId` 的第 3 参是
 * 「**想要的结果态**」，而当时传的是「当前不是展开」=「当前折叠」，与「想要折叠」正好相反，
 * 于是双向都退化成空操作（点击项目行毫无反应，集成验收实测抓到）。
 *
 * 现在把「点击 ⇒ 集合怎么变」收进这个纯函数，语义只有一个入口，Node 侧可直接断言：
 *  - 当前**已折叠**（在集合里）⇒ 用户想要展开 ⇒ 从集合移除；
 *  - 当前**未折叠**（不在集合里）⇒ 用户想要折叠 ⇒ 加入集合。
 *
 * ⚠️ 页面侧**不要**再自己算 `present` —— 一律走这里（调用点自己算正是上一个 bug 的来源）。
 */
export function toggleCollapsedId(collapsedIds: string[], projectId: string): string[] {
  const collapsed = collapsedIds.indexOf(projectId) >= 0;
  // present = 「用户想要的结果态」= 想要的折叠态 = 当前**未**折叠。
  return toggleExpandedId(collapsedIds, projectId, !collapsed);
}

/**
 * 清掉集合里已经不存在的项目 id（换账号 / 项目被删后残留的 id 会永远留在偏好里）。
 *
 * ⚠️ R38 起该集合的语义是「手动折叠」而不是「展开」，所以函数名改成中性的
 *  `pruneUnknownProjectIds`；旧名 `pruneExpandedIds` 保留为别名以免既有调用点一次性全改。
 */
export function pruneUnknownProjectIds(ids: string[], projects: AgentProject[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    for (let j = 0; j < projects.length; j++) {
      if (projects[j].id === ids[i]) {
        out.push(ids[i]);
        break;
      }
    }
  }
  return out;
}

/** `pruneUnknownProjectIds` 的旧名（语义已从「展开集合」变为「折叠集合」，仅作兼容）。 */
export function pruneExpandedIds(ids: string[], projects: AgentProject[]): string[] {
  return pruneUnknownProjectIds(ids, projects);
}

/** 从字符串里解析展开集合（`AppStorage` 只能存原始类型，惯例是逗号分隔）。 */
export function parseExpandedIds(raw: string): string[] {
  if (raw.length === 0) {
    return [];
  }
  const parts = raw.split(',');
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const item = parts[i].trim();
    if (item.length > 0 && out.indexOf(item) < 0) {
      out.push(item);
    }
  }
  return out;
}

/** 展开集合 → 可持久化的字符串（与 `parseExpandedIds` 成对）。 */
export function serializeExpandedIds(ids: string[]): string {
  return ids.join(',');
}

/** 项目行「所属设备」的展示名；找不到设备时回落到 `未命名设备`。 */
export function projectDeviceLabel(project: AgentProject, devices: AgentDevice[]): string {
  for (let i = 0; i < devices.length; i++) {
    if (devices[i].id === project.connectorId) {
      return devices[i].name;
    }
  }
  return '未命名设备';
}

// ---------------------------------------------------------------------------
// R38：展开集合的语义反转（默认全部展开）+ 内容相等判定
// ---------------------------------------------------------------------------

/**
 * 项目分组的展开集合 —— **R38 起语义反转**：从「展开白名单」改为「折叠黑名单」。
 *
 * 用户需求原文：「项目默认全部加载」。改前是白名单语义（集合里 = 展开，初始空 = 全部折叠），
 * 所以任何项目在用户手动点开之前都不渲染会话；改成黑名单后，初始空集合 = **全部展开**。
 *
 * ⚠️ 持久化键也随之换成新键（见 HomeScreen 的 `COLLAPSED_KEY`）：旧键存的是白名单，
 *  直接当黑名单读会把「用户展开过的项目」判成「用户折叠过的项目」，语义 180 度反转。
 *  旧键只作为一次性迁移的**依据**（见 `migrateCollapsedIds`）。
 */
export interface ProjectCollapseState {
  /** 被用户**手动折叠**的项目 id。空数组 = 全部展开。 */
  collapsedIds: string[];
}

/** 从字符串里解析折叠集合（`AppStorage` 只能存原始类型，惯例是逗号分隔；与 parseExpandedIds 同款）。 */
export function parseProjectCollapsed(raw: string): string[] {
  return parseExpandedIds(raw);
}

/** 折叠集合 → 可持久化的字符串（与 `parseProjectCollapsed` 成对）。 */
export function serializeProjectCollapsed(ids: string[]): string {
  return serializeExpandedIds(ids);
}

/**
 * 老用户升级时的**一次性迁移**：旧「展开白名单」→ 新「折叠黑名单」。
 *
 * 规则（写死在这里而不是散在页面里，好让它能进 Node 断言）：
 *  - 新键已有值（`storedCollapsed` 非空串）⇒ 已经迁移过或本来就是新用户 ⇒ 直接用新值；
 *  - 旧白名单为**空串** ⇒ 用户从未展开过任何项目 = **没有历史折叠意图** ⇒ 判空集合（全部展开）。
 *  ⚠️ 这一条是刻意的：按「白名单之外都算折叠」推下去会把从未点开过的项目全判成折叠，
 *  与「默认全部加载」的需求正好相反；
 *  - 否则 ⇒ 折叠集合 = 当前项目里「**不在**旧白名单中的那些」：
 *  用户上次展开过的仍然展开、上次折叠过的仍然折叠（语义保留），从未点开过的变为展开。
 *
 * @param storedCollapsed 新键当前值（空串 = 还没有新值）
 * @param legacyExpandedRaw 旧键当前值（`aaProjectExpanded`）
 * @param projectIds 当前全部项目 id
 */
export function migrateCollapsedIds(
  storedCollapsed: string, legacyExpandedRaw: string, projectIds: string[]
): string[] {
  if (storedCollapsed.length > 0) {
    return parseProjectCollapsed(storedCollapsed);
  }
  if (legacyExpandedRaw.length === 0) {
    return [];
  }
  const expanded = parseExpandedIds(legacyExpandedRaw);
  const collapsed: string[] = [];
  for (let i = 0; i < projectIds.length; i++) {
    if (expanded.indexOf(projectIds[i]) < 0) {
      collapsed.push(projectIds[i]);
    }
  }
  return collapsed;
}

/** 两个字符串数组内容是否相同（顺序敏感）—— 用于「相等就不换引用」的差分。 */
export function stringListsEqual(left: string[], right: string[]): boolean {
  if (left === right) {
    return true;
  }
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) {
      return false;
    }
  }
  return true;
}

/** 会话列表的「关键字段」是否逐项相同（id 序列 + 会渲染的字段）。 */
function sessionListsEqual(left: AgentSession[], right: AgentSession[]): boolean {
  if (left === right) {
    return true;
  }
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    const a = left[i];
    const b = right[i];
    if (a.id !== b.id || a.title !== b.title || a.status !== b.status
      || a.updatedSeq !== b.updatedSeq || a.pinned !== b.pinned || a.archived !== b.archived
      || a.unread !== b.unread || a.indicator !== b.indicator
      || a.updatedAtLabel !== b.updatedAtLabel || a.metaLabel !== b.metaLabel) {
      return false;
    }
  }
  return true;
}

/**
 * 两个项目行是否「渲染结果相同」—— R38 差分更新用。
 *
 * 比较口径是**会进渲染的字段**（`projectRow()` / `rowKey()` 读到的那些），
 * 不是对象全等：`sessions` 数组里每条只比关键字段（`sessionListsEqual`）。
 * 只要判等为真，调用方就可以**保留旧引用**、跳过 `@State` 赋值，
 * 从而让这次 notify 不触发重绘。
 */
export function projectRowsEqual(left: ProjectRow, right: ProjectRow): boolean {
  if (left === right) {
    return true;
  }
  return left.projectId === right.projectId
    && left.name === right.name
    && left.workspacePath === right.workspacePath
    && left.pinned === right.pinned
    && left.sessionCount === right.sessionCount
    && left.expanded === right.expanded
    && sessionListsEqual(left.sessions, right.sessions);
}

/** 两个项目行数组是否逐项渲染相同（见 `projectRowsEqual`）。 */
export function projectRowListsEqual(left: ProjectRow[], right: ProjectRow[]): boolean {
  if (left === right) {
    return true;
  }
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    if (!projectRowsEqual(left[i], right[i])) {
      return false;
    }
  }
  return true;
}

/** 会话列表是否逐项渲染相同（供页面差分复用，语义同 `projectRowsEqual`）。 */
export function sameSessionList(left: AgentSession[], right: AgentSession[]): boolean {
  return sessionListsEqual(left, right);
}

/** 设备列表是否逐项渲染相同（首页只读 id / name / online）。 */
export function deviceListsEqual(left: AgentDevice[], right: AgentDevice[]): boolean {
  if (left === right) {
    return true;
  }
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    const a = left[i];
    const b = right[i];
    if (a.id !== b.id || a.name !== b.name || a.online !== b.online || a.deviceOs !== b.deviceOs) {
      return false;
    }
  }
  return true;
}
