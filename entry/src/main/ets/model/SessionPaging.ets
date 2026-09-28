/**
 * 工作台会话分页的纯逻辑（不依赖 ArkUI / Kit，可进 Node 逻辑自测）。
 *
 * 对应 Android「feature/sessions/SessionsState.kt」里的
 * 「withAppendedSessionPage()」/「replacedByDashboardSnapshot()」那一族函数，
 * 以及「AgentsAnywhereApp.loadMoreSessions()」的守卫条件。
 *
 * 服务端契约（上游 api/SessionsApi.kt 的 listSessions() 与
 * server/agent_server/infra/repositories/sessions.py 的 list_sessions_page()）：
 *  GET /sessions?archived=&limit=&cursor= → {sessions, hasMore, nextCursor}；
 *  nextCursor 是**服务端自定义的不透明串**（真实服务端是 base64url 编码的 JSON 游标，
 *  内含 pinned/sortAt/orderSeq/updatedSeq/sessionId），客户端只原样回传、**不解析内部结构** ——
 *  上游客户端同样只做 response.optNullableString("nextCursor")。
 *
 * 三条合并规则（与上游对齐）：
 *  1. 追加下一页按 id 去重；同一会话以 updatedSeq 更大的一方为准；
 *  2. WS dashboard.snapshot 只负责「快照里出现过的那些会话」（上游 activeFirstPageIds 语义），
 *  不在快照里的本地会话要保留 —— 否则已加载的后续页会被整片抹掉；
 *  3. 快照说「没有更多」但本地还留着不在快照里的会话时，保留本地游标 ——
 *  否则用户翻过的页再也接不上（服务端快照的 sessionPages 目前恒为 false）。
 *
 * 全部函数都是**不可变**的：入参不被修改，返回新对象 / 新数组。
 */

import { AgentSession, compareSessions } from './AppModels';

/** 单侧（进行中 / 已归档）的分页状态。nextCursor 用空串表示「没有下一页」。 */
export interface SessionPageState {
  hasMore: boolean;
  nextCursor: string;
  loading: boolean;
  error: string;
  /** 最近一次「首页（HTTP 首屏或 WS 快照）」里出现过的会话 id —— 快照合并时用它划界。 */
  firstPageIds: string[];
}

/** 两侧分页状态（与 DashboardStore 的两个列表一一对应）。 */
export interface SessionPagingState {
  active: SessionPageState;
  archived: SessionPageState;
}

function emptyPageState(): SessionPageState {
  const state: SessionPageState = {
    hasMore: false,
    nextCursor: '',
    loading: false,
    error: '',
    firstPageIds: []
  };
  return state;
}

export function emptyPagingState(): SessionPagingState {
  const state: SessionPagingState = {
    active: emptyPageState(),
    archived: emptyPageState()
  };
  return state;
}

export function pageStateOf(paging: SessionPagingState, archived: boolean): SessionPageState {
  return archived ? paging.archived : paging.active;
}

function withPageState(
  paging: SessionPagingState, archived: boolean, page: SessionPageState
): SessionPagingState {
  const next: SessionPagingState = {
    active: archived ? paging.active : page,
    archived: archived ? page : paging.archived
  };
  return next;
}

export function idsOf(sessions: AgentSession[]): string[] {
  const ids: string[] = [];
  for (let i = 0; i < sessions.length; i++) {
    ids.push(sessions[i].id);
  }
  return ids;
}

/** 首屏（refreshAll）拿到首页后写入分页状态：游标换成首页的，错误清掉。 */
export function applyFirstPage(
  paging: SessionPagingState, archived: boolean, hasMore: boolean, nextCursor: string,
  sessions: AgentSession[]
): SessionPagingState {
  const cursor = nextCursor !== undefined && nextCursor !== null ? nextCursor : '';
  const page: SessionPageState = {
    hasMore: hasMore && cursor.length > 0,
    nextCursor: hasMore ? cursor : '',
    loading: false,
    error: '',
    firstPageIds: idsOf(sessions)
  };
  return withPageState(paging, archived, page);
}

/**
 * 能否发起「加载更多」：还有更多 **且** 游标可用 **且** 不在加载中。
 * （游标为空串时即便 hasMore 为真也不能请求 —— 那会原地打转。）
 */
export function canLoadMore(paging: SessionPagingState, archived: boolean): boolean {
  const page = pageStateOf(paging, archived);
  return page.hasMore && page.nextCursor.length > 0 && !page.loading;
}

/** 上一次「加载更多」失败且游标仍在 → 底部的按钮要变成「重试」。 */
export function canRetryLoadMore(paging: SessionPagingState, archived: boolean): boolean {
  const page = pageStateOf(paging, archived);
  return page.error.length > 0 && page.hasMore && page.nextCursor.length > 0 && !page.loading;
}

/** 底部是否要显示入口（能加载 或 上次失败可重试）。 */
export function shouldShowLoadMore(paging: SessionPagingState, archived: boolean): boolean {
  return canLoadMore(paging, archived) || canRetryLoadMore(paging, archived);
}

/** 进入加载态；不可加载时原样返回（调用方据此直接 return，不发请求）。 */
export function beginLoadMore(paging: SessionPagingState, archived: boolean): SessionPagingState {
  if (!canLoadMore(paging, archived)) {
    return paging;
  }
  const current = pageStateOf(paging, archived);
  const page: SessionPageState = {
    hasMore: current.hasMore,
    nextCursor: current.nextCursor,
    loading: true,
    error: '',
    firstPageIds: current.firstPageIds
  };
  return withPageState(paging, archived, page);
}

/**
 * 追加页返回后更新游标。
 *
 * 两种「服务端没给出可推进的游标」都要停手，否则底部入口会一直转：
 *  - hasMore 为真但 nextCursor 是空串（脏数据）；
 *  - nextCursor 与本次请求用的游标**相同**（服务端原地打转 / 环游标）。
 */
export function applyMorePage(
  paging: SessionPagingState, archived: boolean, requestedCursor: string, hasMore: boolean,
  nextCursor: string
): SessionPagingState {
  const cursor = nextCursor !== undefined && nextCursor !== null ? nextCursor : '';
  let keepMore = hasMore;
  if (keepMore && (cursor.length === 0 || cursor === requestedCursor)) {
    keepMore = false;
  }
  const current = pageStateOf(paging, archived);
  const page: SessionPageState = {
    hasMore: keepMore,
    nextCursor: keepMore ? cursor : '',
    loading: false,
    error: '',
    firstPageIds: current.firstPageIds
  };
  return withPageState(paging, archived, page);
}

/** 加载更多失败：退出加载态、记下错误，**游标保留** —— 底部按钮因此变成「重试」。 */
export function failLoadMore(
  paging: SessionPagingState, archived: boolean, message: string
): SessionPagingState {
  const current = pageStateOf(paging, archived);
  const page: SessionPageState = {
    hasMore: current.hasMore,
    nextCursor: current.nextCursor,
    loading: false,
    error: message,
    firstPageIds: current.firstPageIds
  };
  return withPageState(paging, archived, page);
}

/**
 * WS dashboard.snapshot 到来时更新分页状态。
 *
 * 快照的 sessionPages.{active,archived} 是权威来源，但它**只覆盖快照自身那份列表**：
 * 若快照说「没有更多」而本地仍保留着不在快照里的会话（keptLocalCount > 0，
 * 说明这份快照只含首页、或本地翻过页），就保留本地游标，
 * 否则已加载的后续页会「永远接不上」。
 *
 * firstPageIds 一律换成快照里的 id 集合 —— 下次快照合并仍以「最新快照覆盖过的 id」划界。
 */
export function applySnapshotPage(
  paging: SessionPagingState, archived: boolean, hasMore: boolean, nextCursor: string,
  sessions: AgentSession[], keptLocalCount: number
): SessionPagingState {
  const current = pageStateOf(paging, archived);
  const cursor = nextCursor !== undefined && nextCursor !== null ? nextCursor : '';
  if (!hasMore && cursor.length === 0 && keptLocalCount > 0) {
    const kept: SessionPageState = {
      hasMore: current.hasMore && current.nextCursor.length > 0,
      nextCursor: current.nextCursor,
      loading: current.loading,
      error: current.error,
      firstPageIds: idsOf(sessions)
    };
    return withPageState(paging, archived, kept);
  }
  const page: SessionPageState = {
    hasMore: hasMore && cursor.length > 0,
    nextCursor: hasMore ? cursor : '',
    loading: current.loading,
    error: current.error,
    firstPageIds: idsOf(sessions)
  };
  return withPageState(paging, archived, page);
}

/**
 * 会话列表的「关键字段」是否逐项相同 —— R38 差分更新用。
 *
 * 比较的是**会进渲染的字段**（列表行的标题 / 状态 / 时间文案 / meta / 状态点），
 * 不是对象全等（`sortAt` 之类不参与渲染的字段变了不该触发重绘）。
 */
export function sessionListsEqual(left: AgentSession[], right: AgentSession[]): boolean {
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
 * 追加下一页（或刷新首页）时的列表合并。
 * 同 id 以 updatedSeq 更大的一方为准；返回按列表排序规则排好的新数组。
 *
 * ⚠️ R38：合并结果与 `current` **逐项渲染相同**时返回 `current` **原引用**（而不是新建数组）。
 * 这是「消除刷新闪烁」的关键一步：`@State` 对数组赋新引用一律视为变化，
 * 即使内容一模一样也会让整页重跑一遍 diff；返回原引用则这次 notify 完全静默。
 */
export function mergeSessionLists(current: AgentSession[], incoming: AgentSession[]): AgentSession[] {
  const byId: Map<string, AgentSession> = new Map<string, AgentSession>();
  for (let i = 0; i < current.length; i++) {
    byId.set(current[i].id, current[i]);
  }
  for (let i = 0; i < incoming.length; i++) {
    const observed = incoming[i];
    const existing = byId.get(observed.id);
    if (existing === undefined || observed.updatedSeq >= existing.updatedSeq) {
      byId.set(observed.id, observed);
    }
  }
  const merged = sortedSessions(byId);
  return sessionListsEqual(merged, current) ? current : merged;
}

/**
 * WS 快照与本地列表的合并。
 * replacedIds 是快照覆盖到的会话 id（= 快照里出现过的 id）：
 *  - 在 replacedIds 里的：由快照说了算（除非本地 updatedSeq 更大，那是刚被事件更新过的）；
 *  - 不在 replacedIds 里的本地会话：**保留**（已加载的后续页）；
 *  - 在 replacedIds 里但快照没带回来的会话：丢弃（服务端首页已不含它）。
 */
export function mergeWithSnapshot(
  current: AgentSession[], snapshot: AgentSession[], replacedIds: string[]
): AgentSession[] {
  const replaced: Set<string> = new Set<string>();
  for (let i = 0; i < replacedIds.length; i++) {
    replaced.add(replacedIds[i]);
  }
  const localById: Map<string, AgentSession> = new Map<string, AgentSession>();
  for (let i = 0; i < current.length; i++) {
    localById.set(current[i].id, current[i]);
  }
  // 种子：快照没覆盖到的本地会话（= 已加载的后续页）先留下，之后不会被快照挤掉。
  const byId: Map<string, AgentSession> = new Map<string, AgentSession>();
  for (let i = 0; i < current.length; i++) {
    const local = current[i];
    if (!replaced.has(local.id)) {
      byId.set(local.id, local);
    }
  }
  for (let i = 0; i < snapshot.length; i++) {
    const observed = snapshot[i];
    const local = localById.get(observed.id);
    // 本地 updatedSeq 更大 = 它刚被实时事件更新过，这一份比快照新 → 保留本地（与上游一致）。
    if (local !== undefined && local.updatedSeq > observed.updatedSeq) {
      byId.set(observed.id, local);
    } else {
      byId.set(observed.id, observed);
    }
  }
  const merged = sortedSessions(byId);
  // R38：快照内容与本地逐项相同时保留原引用 —— WS 每次 dashboard.changed 都推全量快照，
  // 绝大多数推送的内容其实没变，新建数组会让页面白重绘一遍（用户看到的就是「闪一下」）。
  return sessionListsEqual(merged, current) ? current : merged;
}

function sortedSessions(byId: Map<string, AgentSession>): AgentSession[] {
  const out: AgentSession[] = [];
  byId.forEach((value: AgentSession): void => {
    out.push(value);
  });
  out.sort(compareSessions);
  return out;
}
