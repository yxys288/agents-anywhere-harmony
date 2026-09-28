/**
 * 已归档会话页的纯逻辑（不依赖 ArkUI / Kit，可进 Node 逻辑自测）。
 *
 * 复刻口径见 开发期验证记录，两条易错点：
 *  ① 归档时间用 `archivedAt ?: sortKey`，**解析失败要显示兜底文案**（不是空白、也不崩）；
 *  ② 「列表为空但服务端说还有更多」是一种**独立状态**（文案「当前没有可显示的会话」+
 *  「继续加载」），与「真的没有归档」不是一回事。
 *
 * 抽到 model 层的理由：页内逻辑在 Node 侧测不了（`.ets` 的 `@Component struct` 语法
 * 过不了标准 TypeScript 转译），等于没测。
 */

/** 状态面板的五种形态（对应上游 `when { … }` 的分支；**顺序即优先级**，不可换）。 */
export class ArchivedStateKind {
  /** 有分组 → 直接渲染列表。 */
  static readonly LIST: string = 'list';
  /** 空 + 首屏加载中。 */
  static readonly LOADING: string = 'loading';
  /** 空 + 有错误。 */
  static readonly ERROR: string = 'error';
  /** 空 + 服务端还有更多（**易错点 2**）。 */
  static readonly MORE: string = 'more';
  /** 真空（真的没有归档会话）。 */
  static readonly EMPTY: string = 'empty';
}

/** 归档时间无法解析时的兜底文案。 */
/**
 * 归档时间不可用时的兜底文案 —— 上游 `archived_time_unavailable`（`values-zh-rCN/strings.xml`）
 * =「暂无时间」。⚠️ R20 勘误：本工程此前写的是「归档时间未知」，与上游不一致，已改。
 */
export const ARCHIVED_TIME_FALLBACK: string = '暂无时间';

/** 状态面板的判定输入（页面的 @State 摊平后的标量）。 */
export interface ArchivedStateInput {
  /** 当前可见分组数（0 = 列表为空）。 */
  groupCount: number;
  /** 首屏加载中。 */
  loading: boolean;
  /** 首屏错误文案（空串 = 没有错误）。 */
  errorText: string;
  /** 已归档侧是否还有下一页（分页游标仍在）。 */
  hasMore: boolean;
  /** 是否处于「按项目筛选」状态（决定空态文案是「尚未归档」还是「该项目尚未归档」）。 */
  filtered: boolean;
}

/** 状态面板要显示的内容（list 形态下三个文案都是空串，页面直接渲染列表）。 */
export interface ArchivedStateText {
  kind: string;
  title: string;
  description: string;
  actionLabel: string;
}

/**
 * 状态分派：list → loading → error → more → empty（顺序与上游一致）。
 *
 * ⚠️ 「空 + hasMore」必须排在「真空」之前 —— 它是独立状态，不是「没有归档」。
 */
export function archivedStateOf(input: ArchivedStateInput): ArchivedStateText {
  if (input.groupCount > 0) {
    const list: ArchivedStateText = {
      kind: ArchivedStateKind.LIST, title: '', description: '', actionLabel: ''
    };
    return list;
  }
  // ⚠️ R21：以下五组文案**逐字**对齐上游 `values-zh-rCN/archive_strings.xml` 与 `strings.xml`。
  // 修前这一整块是本工程的自由发挥（「尚未归档」「加载失败」「继续加载」…），与上游全不一致。
  if (input.loading) {
    // 上游 `archive_loading`「正在加载归档会话…」（**没有副文**，`:130-133`）。
    const loading: ArchivedStateText = {
      kind: ArchivedStateKind.LOADING, title: '正在加载归档会话…', description: '', actionLabel: ''
    };
    return loading;
  }
  if (input.errorText.length > 0) {
    // 上游 `Archive_load_failed` + `archive_retry_hint` + `archived_retry`（`:134-140`）。
    const failed: ArchivedStateText = {
      kind: ArchivedStateKind.ERROR,
      title: '暂时无法加载归档会话',
      description: '检查网络连接后再试一次。',
      actionLabel: '重试'
    };
    return failed;
  }
  if (input.hasMore) {
    // 上游 `archive_page_empty` + `archive_more_hint` + `archived_load_more`（`:141-148`）。
    const more: ArchivedStateText = {
      kind: ArchivedStateKind.MORE,
      title: '当前没有可显示的会话',
      description: '继续加载，查看更早的归档会话。',
      actionLabel: '加载更多'
    };
    return more;
  }
  const empty: ArchivedStateText = {
    kind: ArchivedStateKind.EMPTY,
    // 上游 `ArchivedSessionsScreen.kt:149-152`：只有 title，**没有副文** ——
    // 所以 `description` 必须是空串（页面据此不渲染那一行）。
    title: input.filtered ? '这个项目还没有归档会话' : '暂无已归档会话',
    description: '',
    actionLabel: ''
  };
  return empty;
}

/**
 * 归档时间取哪个字段：`archivedAt ?: sortKey`（易错点 1）。
 * 返回空串表示两个字段都没有可用值。
 */
export function archivedTimeSource(archivedAt: string | undefined, sortKey: string): string {
  if (archivedAt !== undefined && archivedAt.trim().length > 0) {
    return archivedAt;
  }
  if (sortKey === undefined || sortKey === null) {
    return '';
  }
  return sortKey;
}

/** 时间串能否被解析（false → 调用方要用兜底文案，而不是渲染空白）。 */
export function archivedTimeParsable(iso: string): boolean {
  if (iso.length === 0) {
    return false;
  }
  return !isNaN(Date.parse(iso));
}

/**
 * 归档时间标签：能解析就用调用方给的相对时间函数，否则给兜底文案。
 *
 * `relative` 由调用方注入（页面传 `model/AppModels.ets` 的 `relativeTimeLabel`）——
 * 这样本模块**零 import**，Node 侧转译与断言都不需要额外依赖。
 */
/**
 * 归档时间的显示格式 —— 上游 `ArchivedSessionsScreen.kt:57`：
 * `DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm").withZone(ZoneId.systemDefault())`。
 *
 * ⚠️ R20 勘误：本工程此前显示的是**相对时间**（`1w` 这种），上游是**绝对时间**「归档于 2026-09-20 19:15」。
 * 不可解析时返回空串，由调用方走兜底文案。
 */
export function formatArchiveTimestamp(iso: string): string {
  if (!archivedTimeParsable(iso)) {
    return '';
  }
  const date = new Date(iso);
  const year: number = date.getFullYear();
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
  return `${year}-${pad(month)}-${pad(day)} ${pad(hour)}:${pad(minute)}`;
}

/**
 * 归档时间标签：`archivedAt ?: sortKey` → `yyyy-MM-dd HH:mm` → 前缀「归档于 」。
 *
 * 上游 `archive_archived_at`（`values-zh-rCN/archive_strings.xml`）=「归档于 %1$s」；
 * 不可解析时用 `ARCHIVED_TIME_FALLBACK`（「暂无时间」）。
 */
export function archivedTimeLabel(archivedAt: string | undefined, sortKey: string): string {
  const text = formatArchiveTimestamp(archivedTimeSource(archivedAt, sortKey));
  return text.length > 0 ? `归档于 ${text}` : ARCHIVED_TIME_FALLBACK;
}
