/**
 * 文件页的「搜索 / 过滤 / 复制载荷」纯逻辑（**无 Kit 依赖**，可直接进 Node 自测）。
 *
 * 对应 Android 端三处（锚文为准）：
 *  ① `ui/screens/sessiondetail/SessionAgentFilesScreen.kt` 的 `FileActionMenu`（长按行弹出）
 *  与 `PreviewCardHeader` —— 复制路径（`files_copy_path` / `files_copied_path`）、
 *  复制代码（`files_copy_code` / `files_copied_code`，`copyEnabled = !binary && content 非空白`）；
 *  ② 同文件 `FilePreviewContent` -> `InlineFileSearchControls` 加上 `CodeBlockPreview.kt` 的
 *  `SoraFileSearchResult` / `SoraFileSearchController` —— **在文件内容里搜索**
 *  （面板显示 `当前/总数`，上一条/下一条按 `setCyclicJumping(true)` 循环跳转）；
 *  ③ 文件**名**过滤：上游 `FilesScreen.kt` 的 `FileListContent` 只列目录、**没有**文件名过滤框
 *  （全仓 grep `files_filter` / `entries.filter` 零命中），所以这一项是本工程既有能力，
 *  这里只把它的判定抽成纯函数，明确约定：大小写不敏感、分隔符无关、空查询等价于不过滤。
 *
 * 为什么独立成模块：这些判定全是纯字符串运算，而 `FilesStore` 依赖 `@kit.NetworkKit`，
 * Node 侧跑不起来（与 `model/RemotePaths.ets` 同样的理由）—— 抽出来才能进
 * `tools/logic-test/suite-files.mjs` 自测。
 */

import { RemoteDirectoryEntry } from './Types';
// 浏览根 `~` 的单一事实来源：路径域纯模块 `model/DirBrowse.ets`（第十一轮 W3/B5）。
import { HOME_ROOT } from './DirBrowse';

/** 复制按钮的「已复制」闪示时长（上游 `PreviewCard.onCopy` 里 `delay(1100)`，毫秒）。 */
export const COPY_FLASH_MILLIS: number = 1100;

/** 内容搜索最多列出多少条命中（与上游不同：上游由编辑器自己分页，本工程用列表，需自设上限）。 */
export const MATCH_LIST_LIMIT: number = 200;

/** 命中行在结果列表里的显示宽度（字符数），超出以省略号截断。 */
const MATCH_PREVIEW_CHARS: number = 60;

/**
 * 复制路径失败的提示。
 *
 * ⚠️ **与上游的差异 · 平台必需新增（上游无对应 key，也无对应通道）—— 不可被后续轮次误判为自创文案。**
 *  - 上游对应物之**有无**：上游 `LocalClipboardManager.setText(...)` **没有失败回调**
 *  （`SessionAgentFilesScreen.kt:1725` 写完即结束），失败不可观测；
 *  - 鸿蒙 `pasteboard.getSystemPasteboard().setData()` 返回 Promise 且会 reject，
 *  不落文案就是**静默失败**（与交付要求「成功/失败都要有可观察反馈」冲突）。
 *  - 评审口径：第十一轮 lead 已拍板**保留**。
 */
export const COPY_PATH_FAILED_HINT: string = '复制路径失败，请稍后重试。';

/**
 * 复制代码失败的提示。
 *
 * ⚠️ 同上：**与上游的差异 · 平台必需新增（上游无对应 key）**——
 * 上游复制代码同样只有 `clipboard.setText(...)`（无失败通道，见 `SessionAgentFilesScreen.kt:1112-1121`），
 * 鸿蒙侧 `setData` 可 reject，必须有可见反馈。**不要删**。
 */
export const COPY_CODE_FAILED_HINT: string = '复制代码失败，请稍后重试。';

// ---------------------------------------------------------------------------
// 1. 文本归一化（大小写 / 分隔符）
// ---------------------------------------------------------------------------

/** 比较基准：分隔符统一成 `/`、去首尾空白、转小写（大小写不敏感）。 */
export function normalizeSearchText(value: string): string {
  return value.replace(/\\/g, '/').trim().toLowerCase();
}

/**
 * 查询串归一化：分隔符统一、去首尾空白、去掉用户从路径里粘贴时常见的 `./` 前缀、转小写。
 *
 * ⚠️ 只做归一化，**不**改 `\` 的语义 —— `src\a.ts` 与 `src/a.ts` 归一后都是 `src/a.ts`，
 * 这正是「支持路径分隔符差异」要的结果。
 */
export function normalizeQuery(query: string): string {
  let out = query.replace(/\\/g, '/').trim();
  while (out.startsWith('./')) {
    out = out.substring(2);
  }
  return out.toLowerCase();
}

/** 是否处于「过滤中」（只有空白也算没过滤）。 */
export function hasActiveQuery(query: string): boolean {
  return normalizeQuery(query).length > 0;
}

// ---------------------------------------------------------------------------
// 1.5 浏览根 / 初始目录的归一（第十一轮真机 P0：顶层文件页 root is required）
// ---------------------------------------------------------------------------

/**
 * 生效的浏览根：把「入口没带参数」的情况统一收敛到上游的 `~`。
 *
 * 上游锚文（`SessionAgentFilesScreen.kt`）：
 *  - `DeviceFilesContent` 的 `remoteFileRequest(..., fallbackRoot = resolvedRoot?.takeIf { it.isNotBlank() } ?: "~")`（364 行）
 *  —— 顶层文件页就是走这一条，fallback 后 root 是 `~`、path 是 `.`；
 *  - 383 行 `else if (request.root == "~")` 再把 `~` 解析成服务端返回的绝对路径。
 *
 * 本工程的三个入口分别传：
 *  - 首页「文件」卡片 → **空串**（`Index.paramAt(1)` 对缺失参数返回空串）；
 *  - 设备详情「浏览该设备的文件」→ 项目的 `workspacePath`，取不到时是 `.`；
 *  - 会话详情顶栏 🗀 → 会话 `cwd`（绝对路径）。
 *
 * 空串 / `.` 都会被服务端判成「没给 root」（`fs/list` 的 body 是 `{root,path}`，
 * 见 `specs/01-api-spec.md:80`；真机错误文案就是 `root is required`），故一律归一成 `~`。
 */
export function effectiveBrowseRoot(root: string): string {
  const trimmed = root.trim();
  if (trimmed.length === 0 || trimmed === '.') {
    return HOME_ROOT;
  }
  return trimmed;
}

/** 生效的初始目录：上游 `remoteFileRequest` 里 `path = normalizedPath.ifBlank { "." }`。 */
export function effectiveInitialPath(path: string): string {
  const trimmed = path.trim();
  return trimmed.length > 0 ? trimmed : '.';
}

// ---------------------------------------------------------------------------
// 2. 文件名过滤
// ---------------------------------------------------------------------------

/**
 * 单条目录项是否命中查询。
 *
 * 规则（两条，都可测）：
 *  ① 查询**不含**分隔符：与 `name` 归一化后做子串匹配（大小写不敏感）。
 *  ② 查询**含**分隔符：再退一步与整条 `path` 归一化后做子串匹配
 *  —— 这样用户粘贴 `src\utils/a.ts` 时，`\` 与 `/` 的差异不会让他查到空。
 *
 * 注意：命中判定**不**看 `type`，目录与文件一视同仁（过滤后目录仍可进入）。
 */
export function matchesEntry(name: string, path: string, query: string): boolean {
  const needle = normalizeQuery(query);
  if (needle.length === 0) {
    return true;
  }
  if (normalizeSearchText(name).includes(needle)) {
    return true;
  }
  if (needle.includes('/')) {
    return normalizeSearchText(path).includes(needle);
  }
  return false;
}

/**
 * 目录项过滤：先按「显示点文件」开关隐藏 `.` 开头的项，再按查询串过滤。
 *
 * 返回**新数组**（不复用入参引用）：`@State` 字段换新引用才会触发 ArkUI 重渲染。
 */
export function filterEntries(
  entries: RemoteDirectoryEntry[],
  query: string,
  showHidden: boolean
): RemoteDirectoryEntry[] {
  const out: RemoteDirectoryEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (!showHidden && entry.name.startsWith('.')) {
      continue;
    }
    if (!matchesEntry(entry.name, entry.path, query)) {
      continue;
    }
    out.push(entry);
  }
  return out;
}

/**
 * 列表为空时的说明文案。
 *
 * 空查询那一支要与上游 `files_empty_directory`（「这个目录是空的。」，strings.xml:596）**逐字一致**；
 * 「过滤后为空」那一支回显用户关键字（否则用户会以为目录真的空了）。
 *
 * ⚠️ **与上游的差异 · 功能必需新增（上游无对应 key）—— 不可被后续轮次误判为自创文案，也不要顺手删。**
 *  - 上游对应物之**有无**：上游**没有文件名过滤功能**（`FilesScreen.kt` 的 `FileListContent` 只列目录；
 *  全仓 grep `entries.filter` / `files_filter` 零命中）⇒「过滤后零命中」这一态上游根本不存在，
 *  自然没有文案 key；
 *  - 且此处**不能**回落 `files_empty_directory`：目录并不空，复用即失真；
 *  - 追加的「（点文件已隐藏）」后缀对应本工程既有的「显示点文件」开关（上游同样没有该开关）。
 *  - 评审口径：第十一轮 lead 已拍板**保留**。
 */
export function filterEmptyHint(query: string, showHidden: boolean): string {
  const raw = query.trim();
  const hiddenSuffix = showHidden ? '' : '（点文件已隐藏）';
  if (raw.length === 0) {
    return '这个目录是空的。' + hiddenSuffix;
  }
  return '没有匹配「' + raw + '」的文件。' + hiddenSuffix;
}

/** 过滤计数文案（`3 / 12`）。只在过滤中显示，让用户知道被筛掉了多少项。 */
export function filterCountLabel(visible: number, total: number): string {
  return visible + ' / ' + total;
}

// ---------------------------------------------------------------------------
// 3. 远程路径显示（复制路径用）
// ---------------------------------------------------------------------------

/**
 * 复刻上游 `displayRemotePath(root, rawPath, deviceOs, windowsDriveOverviewLabel)`
 * （`feature/files/RemoteFileNavigation.kt:100-113`）：
 *  - 绝对路径（`/...`）与 Windows 盘符路径（`C:/...`）**原样返回**；
 *  - 相对路径才与 `root` 拼起来。
 *
 * 本工程的 `RemoteDirectoryEntry.path` 实测就是服务端返回的**绝对**路径，所以「复制路径」
 * 复制到的就是那条完整远程路径（坑 140 那条坑说的是**层级显示**要归一到已知根，
 * 而复制路径的语义恰恰是「复制完整远程路径」，两者不冲突）。
 *
 * 已知差异：上游还支持 Windows「这台电脑」总览（`windowsDriveOverviewLabel`），
 * 本工程的设备模型里没有 `deviceOs`，该分支未实现，所以这里把空路径回落到 `root`。
 */
export function displayRemotePath(root: string, rawPath: string): string {
  const base = trimTrailingSlashes(root.trim());
  const path = rawPath.replace(/\\/g, '/').trim();
  if (path.length === 0 || path === '.') {
    return base.length > 0 ? base : '.';
  }
  if (path === '/') {
    return '/';
  }
  if (path.startsWith('/') || /^[A-Za-z]:\//.test(path)) {
    return path;
  }
  let rest = path;
  while (rest.startsWith('/')) {
    rest = rest.substring(1);
  }
  return base.length === 0 ? path : base + '/' + rest;
}

function trimTrailingSlashes(value: string): string {
  let end = value.length;
  while (end > 0 && value.charAt(end - 1) === '/') {
    end -= 1;
  }
  return value.substring(0, end);
}

// ---------------------------------------------------------------------------
// 4. 文件内容搜索（上游 CodeBlockPreview.kt 的 SoraFileSearch*）
// ---------------------------------------------------------------------------

/** 单条命中。`index` 是 0 基序号，便于与 `current - 1` 对齐。 */
export interface FileMatch {
  index: number;
  /** 1 基行号。 */
  line: number;
  /** 1 基列号（UTF-16 码元，与本文件内所有下标口径一致）。 */
  column: number;
  /** 截取过的行文本（结果列表显示用）。 */
  text: string;
}

/** 上游 `SoraFileSearchResult(current, total)` 的等价物。 */
export interface FileSearchResult {
  current: number;
  total: number;
}

/** 搜索前把查询串按大小写策略归一（空串表示没在搜）。 */
function prepareQuery(query: string, caseSensitive: boolean): string {
  const trimmed = query.trim();
  return caseSensitive ? trimmed : trimmed.toLowerCase();
}

/**
 * 命中次数（非重叠计数，与编辑器里「找下一个」的推进方式一致）。
 *
 * ⚠️ 大小写不敏感用的是整串 `toLowerCase()` 后比较：对土耳其语 `İ` 这类
 * 「小写后长度变化」的字符会偏一位，但远端源码场景下可忽略（上游同样是小写折叠）。
 */
export function countMatches(content: string, query: string, caseSensitive: boolean): number {
  const needle = prepareQuery(query, caseSensitive);
  if (needle.length === 0) {
    return 0;
  }
  const haystack = caseSensitive ? content : content.toLowerCase();
  let count = 0;
  let from = 0;
  while (from + needle.length <= haystack.length) {
    const hit = haystack.indexOf(needle, from);
    if (hit < 0) {
      break;
    }
    count += 1;
    from = hit + needle.length;
  }
  return count;
}

/**
 * 以 `column` 为中心截一段行文本：两端被截到时各补一个省略号。
 * 命中在很长的压缩行（min.js 之类）中间时，列表里也要能看见命中附近的字。
 */
export function clipAround(text: string, column: number, maxChars: number): string {
  if (maxChars <= 0 || text.length <= maxChars) {
    return text;
  }
  const half = Math.floor(maxChars / 2);
  let start = column - half;
  if (start < 0) {
    start = 0;
  }
  let end = start + maxChars;
  if (end > text.length) {
    end = text.length;
    start = end - maxChars;
    if (start < 0) {
      start = 0;
    }
  }
  const head = start > 0 ? '...' : '';
  const tail = end < text.length ? '...' : '';
  return head + text.substring(start, end) + tail;
}

/**
 * 取出全部命中（0 基 `index` 顺序即文档顺序）。
 *
 * `limit > 0` 时最多取 `limit` 条；行号靠预先算好的「每行起始偏移」二分不成，用线性推进
 * ——命中本身已经按偏移递增，指针只前进不回头，整体仍是 O(命中数 + 行数)。
 */
export function findMatches(
  content: string,
  query: string,
  caseSensitive: boolean,
  limit: number
): FileMatch[] {
  const out: FileMatch[] = [];
  const needle = prepareQuery(query, caseSensitive);
  if (needle.length === 0) {
    return out;
  }
  const haystack = caseSensitive ? content : content.toLowerCase();
  const lines = content.split('\n');
  const lineStarts: number[] = [];
  let offset = 0;
  for (let i = 0; i < lines.length; i++) {
    lineStarts.push(offset);
    offset += lines[i].length + 1;
  }
  let index = 0;
  let from = 0;
  while (from + needle.length <= haystack.length) {
    const hit = haystack.indexOf(needle, from);
    if (hit < 0) {
      break;
    }
    let lineIndex = 0;
    while (lineIndex + 1 < lineStarts.length && lineStarts[lineIndex + 1] <= hit) {
      lineIndex += 1;
    }
    const column = hit - lineStarts[lineIndex];
    const rawLine = lines[lineIndex].replace(/\r$/, '');
    const row: FileMatch = {
      index: index,
      line: lineIndex + 1,
      column: column + 1,
      text: clipAround(rawLine, column, MATCH_PREVIEW_CHARS)
    };
    out.push(row);
    index += 1;
    if (limit > 0 && index >= limit) {
      break;
    }
    from = hit + needle.length;
  }
  return out;
}

/**
 * 上游 `SoraFileSearchController.report()` 的 `current` 归一：
 * 总数为 0 -> `current=0`；序号 `<1` -> 1；越界 -> 夹到 `total`。
 */
export function searchResultOf(current: number, total: number): FileSearchResult {
  if (total <= 0) {
    const empty: FileSearchResult = { current: 0, total: 0 };
    return empty;
  }
  let value = current;
  if (value < 1) {
    value = 1;
  }
  if (value > total) {
    value = total;
  }
  const result: FileSearchResult = { current: value, total: total };
  return result;
}

/** 上游 `setCyclicJumping(true)` 的循环跳转：末条再往下回到第 1 条，第 1 条再往上回到末条。 */
export function stepSearchMatch(current: number, total: number, forward: boolean): number {
  if (total <= 0) {
    return 0;
  }
  if (current < 1 || current > total) {
    return forward ? 1 : total;
  }
  if (forward) {
    return current >= total ? 1 : current + 1;
  }
  return current <= 1 ? total : current - 1;
}

/** 上游 `InlineFileSearchControls` 的 `"${result.current}/${result.total}"` 显示。 */
export function searchCountLabel(result: FileSearchResult): string {
  return result.current + '/' + result.total;
}


// ---------------------------------------------------------------------------
// 5. 复制载荷
// ---------------------------------------------------------------------------

export interface CopyPayload {
  /** 要写进剪贴板的文本（`enabled=false` 时为空串）。 */
  text: string;
  enabled: boolean;
  /**
   * 成功提示：**逐字取自上游 strings.xml**。
   *  - 复制路径 -> `files_copied_path`（已复制路径）；
   *  - 复制代码 -> `files_copied_code`（已复制代码）；
   *  - `enabled=false` 时为空串 —— 上游此时是把按钮**置灰**（`copyEnabled`），不发提示。
   */
  hint: string;
  /** 内容是否已被服务端截断（上游 `TextFile.truncated`，卡片上用「已截断」标签呈现）。 */
  truncated: boolean;
}

/**
 * 复制代码的载荷。
 *
 * 与上游一致（`SessionAgentFilesScreen.kt:1110-1122`）：
 *  - 可复制条件 = `!binary && content 非空白`（上游 `copyEnabled`）；
 *  - **照抄预览内容，不额外截断** —— 上游就是 `clipboard.setText(AnnotatedString(preview.content))`，
 *  超大文件的截断发生在**服务端**（`TextFile.truncated`），预览卡片上已用「已截断」标签标出。
 *  这里把这个事实直接写进成功提示，用户按下去就知道剪贴板里是整份还是片段。
 */
export function codeCopyPayload(content: string, binary: boolean, truncated: boolean): CopyPayload {
  const enabled = !binary && content.trim().length > 0;
  if (!enabled) {
    // 上游此时按钮就是置灰的（`copyEnabled = !binary && content 非空白`），
    // 没有任何文案 —— 这里也**不编**文案，`hint` 留空，由 UI 的 `interactive` 表达。
    const blocked: CopyPayload = { text: '', enabled: false, hint: '', truncated: truncated };
    return blocked;
  }
  const payload: CopyPayload = {
    text: content,
    enabled: true,
    // 逐字取自 `files_copied_code`。**不加**任何后缀说明：
    // 截断这件事上游用预览卡片上的标签表达（`truncated` 标志随载荷一起交出去）。
    hint: '已复制代码',
    truncated: truncated
  };
  return payload;
}

/** 复制路径的载荷（空路径不给复制入口反馈成功，避免「复制了个空串」）。 */
export function pathCopyPayload(path: string): CopyPayload {
  const text = path.trim();
  if (text.length === 0) {
    const blocked: CopyPayload = { text: '', enabled: false, hint: '', truncated: false };
    return blocked;
  }
  // 逐字取自 `files_copied_path`。
  const payload: CopyPayload = { text: text, enabled: true, hint: '已复制路径', truncated: false };
  return payload;
}

/**
 * 复制按钮的文案：上游 `contentDescription` 在「复制路径 / 已复制路径」之间切
 * （`files_copy_path` / `files_copied_path`，以及 `files_copy_code` / `files_copied_code`），
 * 中文文案就是在前面加一个「已」字。
 */
export function copyButtonLabel(base: string, copied: boolean): string {
  return copied ? '已' + base : base;
}
