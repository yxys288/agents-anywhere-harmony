/**
 * 新建会话 / 新建项目的**远程目录浏览纯逻辑**（无 Kit、无 ArkUI 依赖，可直接进 Node 自测）。
 *
 * 逐条对齐上游 Android（锚文为准）：
 *  - `feature/files/RemoteFileNavigation.kt`：remoteFileRequest / canonicalRemoteDirectoryPath /
 *  remoteParentPath / isSelectableRemoteDirectory / displayRemotePath / normalizeRemotePath /
 *  isWindowsDriveOverview / windowsDriveRoot / posixParentPath / windowsParentPath；
 *  - `feature/sessions/WorkspaceProjects.kt`：workspacePathKey / workspaceProjectName；
 *  - `feature/sessions/SessionsController.kt` 的 `listNewSessionDirectory`（L243-283）：
 *  只留 `type == 'directory'`、按 `name.lowercase()` 排序、`targetType == 'file'` 要报错。
 *
 * **为什么独立成模块**：这些判定全是纯字符串运算，却在真机上各踩过一次大坑 ——
 * 「在根目录点上一级会跑出工作区」「面包屑里冒出 Users / 点它请求不存在的相对路径」
 * （坑 140）。放进页面里就只能靠手点验证，抽到此处即可在 Node 里逐条断言。
 *
 * 父目录与越界的**判定语义复用 `model/RemotePaths.ets`**（parentPath / isOutsideRoot），
 * 这里只负责「远程路径的形态归一 + 目录项筛选 + 面包屑切片」，不另立一套。
 *
 * 另外承载**新建会话配置选项的解析**（模型 / 推理强度 / 权限的默认值与 wire 取值）：
 * 那部分同样是纯逻辑，且直接决定请求体里的 `selections`，放页面里就只能在真机上试 ——
 * 对应上游 `feature/sessions/NewSessionRuntimeSelectionState.kt`（resolveSelection /
 * selectPermission / selectedModelSelectionId）。
 */

import {
  JsonMap, RemoteDirectoryEntry, RemoteRuntimeModel, RemoteRuntimePermission,
  RemoteRuntimeReasoning
} from './Types';
import { AgentProject, AgentSession, SessionStatus } from './AppModels';
import { isOutsideRoot } from './RemotePaths';

/** 上游在 posix 下解析主目录用的哨兵根（`onListDirectory(deviceId, "~", ".")`）。 */
export const HOME_ROOT: string = '~';
/** Windows 设备上的「这台电脑」（盘符总览）标签，对应 `files_windows_drives`。 */
export const WINDOWS_DRIVE_OVERVIEW_LABEL: string = '这台电脑';

/** 一次 fs/list 请求的 (root, path) 形态（对应上游 `RemoteFileRequest`）。 */
export interface RemoteFileRequest {
  root: string;
  path: string;
}

/** 面包屑的一节：`label` 给用户看，`path` 是可直接回传给浏览器的目标路径。 */
export interface DirBreadcrumb {
  label: string;
  path: string;
}

/**
 * 去掉服务端把盘符当成路径段写出来的前导斜杠（`/C:/Users` → `C:/Users`）。
 * 对应上游 `normalizeRemotePath`。
 */
export function normalizeRemotePath(rawPath: string): string {
  return rawPath.replace(/^\/([A-Za-z]:)(?=$|[\\/])/, '$1');
}

export function isWindowsDeviceOs(deviceOs: string): boolean {
  return deviceOs.toLowerCase() === 'windows';
}

/**
 * 浏览的**起始路径**。对应上游 `initialRemoteFilePath(deviceOs)`
 * （`feature/files/RemoteFileNavigation.kt:12-14`）：
 *
 *  - Windows 设备 → **空串**，即「盘符总览 / 这台电脑」态。
 *  服务端（`connector/local/file_ops.py` 的 `read_dir`）只在 `path == ""` 时返回
 *  `_windows_drive_entries()`（`C:` `D:` `E:` …），给 `"."` 就只会列主目录 ——
 *  这正是 R12 真机对照里鸿蒙端「直接进 `工作区 /`、没有 `C:/D:/E:`」的直接原因。
 *  - 其余平台 → `"."`（由服务端按 root 解析，与上游逐字一致）。
 */
export function initialRemoteFilePath(deviceOs: string): string {
  return isWindowsDeviceOs(deviceOs) ? '' : '.';
}

/**
 * 绝对路径（posix 根 / 盘符 / UNC）。面包屑切片与越界判定都以它为前提。
 *
 * ⚠️ 盘符**裸根**（`C:`，不带分隔符）也算绝对路径 —— R14 实测踩到：
 * `breadcrumbSegments` 拿到的浏览根经 `trimTrailingSlash` 后正是 `C:` 这种形态，
 * 若判为「非绝对」，就会走「归不到已知根 → 只显示根一节」的分支，
 * 面包屑于是只剩一个 `C:`（正确应为 `C: / Users / <user>`）。
 * `windowsDriveRoot()` 的正则本来就接受 `C:`，两处口径在这里对齐。
 */
export function isAbsoluteRemotePath(rawPath: string): boolean {
  const path = normalizeRemotePath(rawPath).trim();
  return path.startsWith('/') || /^[A-Za-z]:([\\/]|$)/.test(path) || path.startsWith('\\\\');
}

/** 盘符根（`C:` 或 `C:/x` → `C:\\`），非盘符路径返回 undefined。 */
export function windowsDriveRoot(rawPath: string): string | undefined {
  const normalized = normalizeRemotePath(rawPath).trim();
  const match = /^([A-Za-z]:)(?:[\\/].*)?$/.exec(normalized);
  if (match === null) {
    return undefined;
  }
  return match[1] + '\\';
}

/**
 * 把「想去的路径」拆成一次 fs/list 的 (root, path)。对应上游 `remoteFileRequest`。
 *
 * @param targetPath 目标目录（绝对或相对浏览根）
 * @param deviceOs 设备系统（windwos 时按盘符切根）
 * @param fallbackRoot 兜底根（通常是已选工作区 / 已解析的主目录）
 */
export function remoteFileRequest(
  targetPath: string, deviceOs: string, fallbackRoot: string
): RemoteFileRequest {
  const normalizedPath = normalizeRemotePath(targetPath);
  const rootFallback = fallbackRoot.trim().length > 0 ? fallbackRoot : HOME_ROOT;
  if (isWindowsDeviceOs(deviceOs) && normalizedPath.trim().length === 0) {
    return { root: rootFallback, path: '' };
  }
  const driveRoot = isWindowsDeviceOs(deviceOs) ? windowsDriveRoot(normalizedPath) : undefined;
  const root = driveRoot !== undefined ? driveRoot : rootFallback;
  const path = normalizedPath.trim().length > 0 ? normalizedPath : '.';
  return { root: root, path: path };
}

/**
 * 服务端回话里的目录路径归一成「可以继续拿来做 targetPath」的形态。
 * 对应上游 `canonicalRemoteDirectoryPath`：服务端可能回 `.`、空串或带盘符的绝对路径。
 */
export function canonicalRemoteDirectoryPath(
  request: RemoteFileRequest, returnedPath: string, deviceOs: string
): string {
  const requested = normalizeRemotePath(request.path).trim();
  const returned = normalizeRemotePath(returnedPath).trim();
  if (isWindowsDeviceOs(deviceOs)) {
    if (requested.length === 0) {
      return '';
    }
    const value = returned.length === 0 || returned === '.' ? requested : returned;
    return canonicalWindowsPath(value);
  }
  if (requested === '/') {
    return '/';
  }
  if (requested.startsWith('/') && (returned.length === 0 || returned === '.')) {
    return requested;
  }
  if (returned.length === 0) {
    return requested.length > 0 ? requested : '.';
  }
  if (returned === '.' && requested !== '.') {
    return requested;
  }
  return returned;
}

/** 盘符总览（Windows 上 path 为空）：此时**不能**被当成可选的目录。 */
export function isWindowsDriveOverview(rawPath: string, deviceOs: string): boolean {
  return isWindowsDeviceOs(deviceOs) && normalizeRemotePath(rawPath).trim().length === 0;
}

/** 「完成」按钮能不能点：非空且不是盘符总览。对应上游 `isSelectableRemoteDirectory`。 */
export function isSelectableRemoteDirectory(rawPath: string, deviceOs: string): boolean {
  return normalizeRemotePath(rawPath).trim().length > 0 && !isWindowsDriveOverview(rawPath, deviceOs);
}

/**
 * 上一级的目标路径（没有上一级时返回 undefined）。对应上游 `remoteParentPath`。
 *
 * ⚠️ 这里**不夹带**越界收敛 —— 越界收敛在 `browseParentPath` 里做（它复用 RemotePaths）。
 */
export function remoteParentPath(
  rawPath: string, deviceOs: string, allowWindowsDriveOverview: boolean
): string | undefined {
  const normalized = normalizeRemotePath(rawPath).trim();
  if (normalized.length === 0) {
    return undefined;
  }
  if (isWindowsDeviceOs(deviceOs)) {
    return windowsParentPath(normalized, allowWindowsDriveOverview);
  }
  return posixParentPath(normalized);
}

/**
 * 浏览态下「上一级」实际该去哪儿：先取上一级，再把它收敛到**浏览根之内**。
 *
 * 越界时返回 `'.'` —— 在 `remoteFileRequest(root, '.')` 语境下 `'.'` 就是浏览根本身
 * （服务端会以 root 解析），因此不会去列工作区之外的目录，也不会让面包屑退回绝对路径切片。
 */
export function browseParentPath(
  rawPath: string, root: string, deviceOs: string, allowWindowsDriveOverview: boolean
): string | undefined {
  const parent = remoteParentPath(rawPath, deviceOs, allowWindowsDriveOverview);
  if (parent === undefined) {
    return undefined;
  }
  if (isWindowsDeviceOs(deviceOs)) {
    // Windows **必须**在这里短路，不能走下面的 posix 越界收敛：盘符语义自带边界
    // （C:/Users → C:/ → 空串=盘符总览 → undefined），而
    // isOutsideRoot(root="C:/", parent="") 判定为**真**，会把「回到这台电脑」
    // 错收敛成 "."（→ 变成再列一次 C: 根，盘符总览永远回不去）。
    return parent;
  }
  const rootNorm = normalizeRemotePath(root).trim();
  const currentNorm = normalizeRemotePath(rawPath).trim();
  if (!isAbsoluteRemotePath(currentNorm)) {
    // 当前路径是相对形态（`.` / `src/deep`）：沿用父级语义，越界由服务端按 root 解析收敛。
    return parent;
  }
  if (!isAbsoluteRemotePath(rootNorm)) {
    // 浏览根还没解析成绝对路径（`~`）：**无法证明**父级仍在根内 —— 一律收敛回根，
    // 宁可「点上一级没反应」，也不去列工作区之外的目录。
    return '.';
  }
  return isOutsideRoot(rootNorm, parent) ? '.' : parent;
}

/**
 * 目录条上显示的路径。对应上游 `displayRemotePath`：相对根拼成绝对，绝对路径原样。
 */
export function displayRemotePath(
  root: string, rawPath: string, deviceOs: string, windowsDriveOverviewLabel: string
): string {
  if (isWindowsDriveOverview(rawPath, deviceOs)) {
    return windowsDriveOverviewLabel;
  }
  const base = root.trim().replace(/[\\/]+$/, '');
  const path = normalizeRemotePath(rawPath).trim().replace(/\\/g, '/');
  if (path.length === 0 || path === '.') {
    return base.length > 0 ? base : '.';
  }
  if (path === '/') {
    return '/';
  }
  if (path.startsWith('/') || /^[A-Za-z]:\/.*$/.test(path)) {
    return path;
  }
  return base.length === 0 ? path : base + '/' + trimLeadingSlash(path);
}

/** 面包屑第一节的标签：取根的最后一段；根是 `.` / `~` / 空时用兜底文案（如「主目录」）。 */
export function rootLabel(root: string, fallbackLabel: string): string {
  const norm = trimTrailingSlash(normalizeRemotePath(root).trim().replace(/\\/g, '/'));
  if (norm.length === 0 || norm === '.' || norm === HOME_ROOT) {
    return fallbackLabel;
  }
  const slash = norm.lastIndexOf('/');
  const label = slash >= 0 ? norm.substring(slash + 1) : norm;
  return label.length > 0 ? label : fallbackLabel;
}

/** 路径比较键：去 `.` / `..` / 重复斜杠，Windows 下大小写不敏感（对应 `workspacePathKey`）。 */
export function workspacePathKey(path: string, deviceOs: string): string {
  const trimmed = path.trim();
  const windows = isWindowsDeviceOs(deviceOs) || /^[a-zA-Z]:[\\/]/.test(trimmed) || trimmed.startsWith('\\\\');
  const slashes = windows ? trimmed.replace(/\\/g, '/') : trimmed;
  const parts: string[] = [];
  const raw = slashes.split('/');
  for (let i = 0; i < raw.length; i++) {
    const part = raw[i];
    if (part.length === 0 || part === '.') {
      continue;
    }
    if (!windows && part === '..') {
      if (parts.length > 0) {
        parts.pop();
      }
      continue;
    }
    parts.push(part);
  }
  let prefix = '';
  if (slashes.startsWith('//') && !slashes.startsWith('///')) {
    prefix = '//';
  } else if (slashes.startsWith('/')) {
    prefix = '/';
  }
  const key = prefix + parts.join('/');
  return windows ? key.toLowerCase() : key;
}

/** 目录名（对应 `workspaceProjectName`：末段，空则 Workspace）。 */
export function workspaceProjectName(path: string): string {
  // 上游 `workspaceProjectName(path)` 无 deviceOs 参数，只按路径特征判 Windows。
  const trimmed = path.trim();
  const windows = /^[a-zA-Z]:[\\/]/.test(trimmed) || trimmed.startsWith('\\\\');
  const normalized = (windows ? path.trim().replace(/\\/g, '/') : path.trim()).replace(/\/+$/, '');
  if (windows && (/^[a-zA-Z]:$/.test(normalized) || /^\/\/[^/]+\/[^/]+$/.test(normalized))) {
    return 'Workspace';
  }
  const slash = normalized.lastIndexOf('/');
  const name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
  return name.length > 0 ? name : 'Workspace';
}

/**
 * 目录列表项：只留目录、按名字小写排序。
 * 对应上游 `listNewSessionDirectory` 里的 `.filter { type == "directory" }.sortedBy { name.lowercase() }`。
 */
export function sortDirectoryEntries(entries: RemoteDirectoryEntry[]): RemoteDirectoryEntry[] {
  const directories: RemoteDirectoryEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    if (entry.type !== 'directory') {
      continue;
    }
    // 上游同时对每个条目的 path 做一次 normalizeRemotePath（`/C:/x` → `C:/x`）——
    // 否则 Windows 设备上点进去会带一个假的前导目录段。
    const normalized: RemoteDirectoryEntry = {
      name: entry.name,
      path: normalizeRemotePath(entry.path),
      type: entry.type
    };
    const size = entry.size;
    if (size !== undefined) {
      normalized.size = size;
    }
    directories.push(normalized);
  }
  directories.sort((left: RemoteDirectoryEntry, right: RemoteDirectoryEntry): number => {
    const a = left.name.toLowerCase();
    const b = right.name.toLowerCase();
    if (a < b) {
      return -1;
    }
    if (a > b) {
      return 1;
    }
    return 0;
  });
  return directories;
}

/**
 * 面包屑切片：第一节固定是浏览根，其后只切「相对浏览根余下的部分」。
 *
 * ⚠️ 不能直接把绝对路径按 `/` 切开（坑 140）：那样「根」那一节会变成 `Users`，
 * 标签显示宿主机目录名、点它还会去请求一个不存在的相对路径。归不到已知根时**只显示根一节**，
 * 宁可少显示，也不冒出宿主机目录名。
 */
export function breadcrumbSegments(
  root: string, currentPath: string, deviceOs: string, fallbackLabel: string
): DirBreadcrumb[] {
  const rootNorm = trimTrailingSlash(normalizeRemotePath(root).trim().replace(/\\/g, '/'));
  const current = trimTrailingSlash(normalizeRemotePath(currentPath).trim().replace(/\\/g, '/'));
  const absoluteRoot = isAbsoluteRemotePath(rootNorm) && !isWindowsDriveOverview(root, deviceOs);
  const first: DirBreadcrumb = {
    label: rootLabel(rootNorm, fallbackLabel),
    path: absoluteRoot ? rootNorm : '.'
  };
  if (current.length === 0 || current === '.' || current === HOME_ROOT) {
    return [first];
  }
  let relative = '';
  let base = '';
  if (absoluteRoot && current === rootNorm) {
    return [first];
  } else if (absoluteRoot && current.startsWith(rootNorm + '/')) {
    relative = current.substring(rootNorm.length + 1);
    base = rootNorm;
  } else if (!absoluteRoot) {
    if (isAbsoluteRemotePath(current)) {
      // 浏览根还没解析成绝对路径（`~`）而服务端回了绝对路径：归不到已知根，只显示根一节。
      // 绝不能让 `home` / `Users` 这类宿主机目录名出现在面包屑上（坑 140）。
      return [first];
    }
    relative = current;
    base = '';
  } else {
    return [first];
  }
  const segments: DirBreadcrumb[] = [first];
  const parts = relative.split('/');
  let accumulated = '';
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.length === 0 || part === '.') {
      continue;
    }
    accumulated = accumulated.length === 0 ? part : accumulated + '/' + part;
    segments.push({
      label: part,
      path: base.length > 0 ? base + '/' + accumulated : accumulated
    });
  }
  return segments;
}

// ---------------------------------------------------------------------------
// 新建会话配置选项：模型 / 推理强度 / 权限
// ---------------------------------------------------------------------------

/** 选中的模型与推理强度（`reasoningId` 为空串 = 该模型没有可选项）。 */
export interface ModelSelection {
  modelId: string;
  reasoningId: string;
}

/**
 * 这个模型是否**自带**推理强度选项（不看 enabled）。
 * 对应上游 `NewSessionModel.hasReasoningSelections()`。
 */
function hasReasoningSelections(model: RemoteRuntimeModel): boolean {
  for (let i = 0; i < model.reasoningItems.length; i++) {
    const item = model.reasoningItems[i];
    if (item.id.length > 0 && item.selectionId.length > 0) {
      return true;
    }
  }
  return false;
}

/**
 * 模型能不能被选中（上游 `hasValidSelection`）：
 * 有推理项的模型必须有至少一个可用推理项；没有推理项的模型自己得有 `selectionId`。
 */
export function modelHasValidSelection(model: RemoteRuntimeModel): boolean {
  if (hasReasoningSelections(model)) {
    for (let i = 0; i < model.reasoningItems.length; i++) {
      const item = model.reasoningItems[i];
      if (item.enabled !== false && item.id.length > 0 && item.selectionId.length > 0) {
        return true;
      }
    }
    return false;
  }
  const modelSelectionId = model.selectionId;
  return modelSelectionId !== undefined && modelSelectionId.trim().length > 0;
}

/** 指定模型的可用推理项（enabled 且 id / selectionId 齐全）。对应上游 `reasoningOptions`。 */
export function reasoningOptionsFor(models: RemoteRuntimeModel[], modelId: string): RemoteRuntimeReasoning[] {
  const out: RemoteRuntimeReasoning[] = [];
  for (let i = 0; i < models.length; i++) {
    if (models[i].id !== modelId) {
      continue;
    }
    const items = models[i].reasoningItems;
    for (let j = 0; j < items.length; j++) {
      const item = items[j];
      if (item.enabled !== false && item.id.length > 0 && item.selectionId.length > 0) {
        out.push(item);
      }
    }
    break;
  }
  return out;
}

/**
 * 解析默认模型 / 推理强度（上游 `NewSessionModelCatalog.resolveSelection` 去掉跨会话 hint 的版本）：
 *  ① 当前选择仍有效 → 原样保留（推理项也在其中挑 default / 第一个）；
 *  ② 否则取标记 `default` 的可用模型，再退到第一个可用模型；
 *  ③ 一个可用的都没有 → undefined（界面显示「不可用」且不阻塞创建）。
 */
export function resolveModelSelection(
  models: RemoteRuntimeModel[], currentModelId: string, currentReasoningId: string
): ModelSelection | undefined {
  for (let i = 0; i < models.length; i++) {
    const model = models[i];
    if (model.id !== currentModelId || model.enabled === false || model.id.length === 0) {
      continue;
    }
    if (!modelHasValidSelection(model)) {
      continue;
    }
    const options = reasoningOptionsFor(models, model.id);
    if (options.length === 0) {
      const withoutReasoning: ModelSelection = { modelId: model.id, reasoningId: '' };
      return withoutReasoning;
    }
    for (let j = 0; j < options.length; j++) {
      if (options[j].id === currentReasoningId) {
        const kept: ModelSelection = { modelId: model.id, reasoningId: options[j].id };
        return kept;
      }
    }
    const withDefault: ModelSelection = {
      modelId: model.id,
      reasoningId: defaultReasoningId(options)
    };
    return withDefault;
  }
  const available: RemoteRuntimeModel[] = [];
  for (let i = 0; i < models.length; i++) {
    const model = models[i];
    if (model.enabled !== false && model.id.length > 0 && modelHasValidSelection(model)) {
      available.push(model);
    }
  }
  if (available.length === 0) {
    return undefined;
  }
  let chosen = available[0];
  for (let i = 0; i < available.length; i++) {
    if (available[i].default) {
      chosen = available[i];
      break;
    }
  }
  const options = reasoningOptionsFor(models, chosen.id);
  const fallbackSelection: ModelSelection = {
    modelId: chosen.id,
    reasoningId: options.length > 0 ? defaultReasoningId(options) : ''
  };
  return fallbackSelection;
}

/** 默认推理强度：标记 `default` 的优先，其次第一个。 */
export function defaultReasoningId(options: RemoteRuntimeReasoning[]): string {
  for (let i = 0; i < options.length; i++) {
    if (options[i].default) {
      return options[i].id;
    }
  }
  return options.length > 0 ? options[0].id : '';
}

/**
 * 解析默认权限（上游 `applyPermissionCatalog` 的顺序：保留当前 → default → 第一个可用）。
 * 返回权限项的 `id`；空串表示没有可用权限。
 */
export function resolvePermissionSelection(
  permissions: RemoteRuntimePermission[], currentPermissionId: string
): string {
  for (let i = 0; i < permissions.length; i++) {
    const item = permissions[i];
    if (item.enabled !== false && item.id === currentPermissionId && item.selectionId.length > 0) {
      return item.id;
    }
  }
  for (let i = 0; i < permissions.length; i++) {
    const item = permissions[i];
    if (item.enabled !== false && item.id.length > 0 && item.selectionId.length > 0 && item.default) {
      return item.id;
    }
  }
  for (let i = 0; i < permissions.length; i++) {
    const item = permissions[i];
    if (item.enabled !== false && item.id.length > 0 && item.selectionId.length > 0) {
      return item.id;
    }
  }
  return '';
}

/**
 * 请求体里 `selections.model` 的取值（上游 `selectedModelSelectionId`，**极易写错**）：
 *  - 选中了推理项 → 用**推理项的** `selectionId`；
 *  - 模型自带推理项但一个都没选中 → **不带** model（返回空串）；
 *  - 模型没有推理项 → 用模型自己的 `selectionId`。
 */
export function modelSelectionIdFor(
  models: RemoteRuntimeModel[], modelId: string, reasoningId: string
): string {
  for (let i = 0; i < models.length; i++) {
    const model = models[i];
    if (model.id !== modelId) {
      continue;
    }
    const options = reasoningOptionsFor(models, model.id);
    for (let j = 0; j < options.length; j++) {
      if (options[j].id === reasoningId) {
        return options[j].selectionId.trim();
      }
    }
    if (hasReasoningSelections(model)) {
      return '';
    }
    const modelSelectionId = model.selectionId;
    return modelSelectionId !== undefined ? modelSelectionId.trim() : '';
  }
  return '';
}

/**
 * `modelSelectionIdFor` 的**反查**：把一个 `selectionId` 还原成 `(modelId, reasoningId)`。
 *
 * 为什么需要它（R53）：新对话页的运行时设置面板按**服务端给的 selectionId**组织选项
 * （与已有会话详情页的 ⚙ 面板同一套 `RuntimeSelectionOption`），而 R47「记住上次选择」的记忆
 * 存的是 `modelId / reasoningId` —— 用户点完选项要回写记忆，就得把 selectionId 反解回来。
 * 反解不出来的（服务端换了 id 体系）返回 undefined，调用方**不写记忆**即可（不必报错）。
 */
export function modelSelectionTargetOf(
  models: RemoteRuntimeModel[], selectionId: string
): ModelSelection | undefined {
  const target = selectionId.trim();
  if (target.length === 0) {
    return undefined;
  }
  for (let i = 0; i < models.length; i++) {
    const model = models[i];
    const options = reasoningOptionsFor(models, model.id);
    if (options.length > 0) {
      for (let j = 0; j < options.length; j++) {
        if (options[j].selectionId.trim() === target) {
          return { modelId: model.id, reasoningId: options[j].id };
        }
      }
      continue;
    }
    const own = model.selectionId !== undefined ? model.selectionId.trim() : '';
    if (own.length > 0 && own === target) {
      return { modelId: model.id, reasoningId: '' };
    }
  }
  return undefined;
}

/** 请求体里 `selections.permission` 的取值（上游 `selectedPermissionSelectionId`）。 */
export function permissionSelectionIdFor(
  permissions: RemoteRuntimePermission[], permissionId: string
): string {
  for (let i = 0; i < permissions.length; i++) {
    const item = permissions[i];
    if (item.id === permissionId && item.enabled !== false) {
      return item.selectionId.trim();
    }
  }
  return '';
}

/**
 * 权限项的**翻译键**，逐条对齐上游 `feature/sessiondetail/SessionRuntimeState.kt` 的
 * `runtimePermissionTranslation`（上游分层同构：纯逻辑给键、UI 层的 localizer 给中文）。
 *
 * 返回空串 = 没有本地化文案，界面回落到服务端给的 `displayName` / `description`。
 */
export function runtimePermissionTranslationKey(
  runtime: string, permissionId: string, metadata: JsonMap | undefined
): string {
  const fromLabelKey = permissionKeyFromLabelKey(labelKeyOf(metadata));
  if (fromLabelKey.length > 0) {
    return fromLabelKey;
  }
  const normalizedId = permissionId.trim().toLowerCase();
  const runtimeName = runtime.trim().toLowerCase();
  if (runtimeName === 'dsh') {
    const preset = presetOf(metadata);
    const key = preset.length > 0 ? preset : normalizedId;
    if (key === 'read-only') {
      return 'dsh.readOnly';
    }
    if (key === 'workspace-write') {
      return 'dsh.workspaceWrite';
    }
    if (key === 'danger-full-access') {
      return 'dsh.fullAccess';
    }
    return '';
  }
  if (normalizedId === 'request_approval') {
    return 'requestApproval';
  }
  if (normalizedId === 'auto_review') {
    return 'autoReview';
  }
  if (normalizedId === 'full_access') {
    return 'fullAccess';
  }
  if (runtimeName.includes('claude')) {
    if (normalizedId === 'default') {
      return 'claude.default';
    }
    if (normalizedId === 'acceptedits') {
      return 'claude.acceptEdits';
    }
    if (normalizedId === 'plan') {
      return 'claude.plan';
    }
    if (normalizedId === 'auto') {
      return 'claude.auto';
    }
    if (normalizedId === 'dontask') {
      return 'claude.dontAsk';
    }
    if (normalizedId === 'bypasspermissions') {
      return 'claude.bypassPermissions';
    }
  }
  return '';
}

// ---------------------------------------------------------------------------
// 内部工具（与上游同名私有函数一一对应）
// ---------------------------------------------------------------------------

// ⚠️ ArkTS 的窄化对「同一表达式重复取可选属性」不成立（`x.a !== undefined ? x.a : ''` 会报
// `Type 'string | undefined' is not assignable to type 'string'`），一律先落到局部变量。
function labelKeyOf(metadata: JsonMap | undefined): string {
  if (metadata === undefined) {
    return '';
  }
  const i18n = metadata['i18n'];
  if (i18n === undefined || typeof i18n !== 'object') {
    return '';
  }
  const raw = (i18n as JsonMap)['labelKey'];
  return typeof raw === 'string' ? raw : '';
}

function presetOf(metadata: JsonMap | undefined): string {
  if (metadata === undefined) {
    return '';
  }
  const raw = metadata['preset'];
  return typeof raw === 'string' ? raw : '';
}

function permissionKeyFromLabelKey(labelKey: string): string {
  if (labelKey === 'dashboard.new.permissionModes.dsh.readOnly.label') {
    return 'dsh.readOnly';
  }
  if (labelKey === 'dashboard.new.permissionModes.dsh.workspaceWrite.label') {
    return 'dsh.workspaceWrite';
  }
  if (labelKey === 'dashboard.new.permissionModes.dsh.fullAccess.label') {
    return 'dsh.fullAccess';
  }
  if (labelKey === 'dashboard.new.permissionModes.requestApproval.label') {
    return 'requestApproval';
  }
  if (labelKey === 'dashboard.new.permissionModes.autoReview.label') {
    return 'autoReview';
  }
  if (labelKey === 'dashboard.new.permissionModes.fullAccess.label') {
    return 'fullAccess';
  }
  if (labelKey === 'dashboard.new.permissionModes.claude.default.label') {
    return 'claude.default';
  }
  if (labelKey === 'dashboard.new.permissionModes.claude.acceptEdits.label') {
    return 'claude.acceptEdits';
  }
  if (labelKey === 'dashboard.new.permissionModes.claude.plan.label') {
    return 'claude.plan';
  }
  if (labelKey === 'dashboard.new.permissionModes.claude.auto.label') {
    return 'claude.auto';
  }
  if (labelKey === 'dashboard.new.permissionModes.claude.dontAsk.label') {
    return 'claude.dontAsk';
  }
  if (labelKey === 'dashboard.new.permissionModes.claude.bypassPermissions.label') {
    return 'claude.bypassPermissions';
  }
  return '';
}

function trimTrailingSlash(value: string): string {
  let end = value.length;
  while (end > 0 && value.charAt(end - 1) === '/') {
    end -= 1;
  }
  return value.substring(0, end);
}

function trimLeadingSlash(value: string): string {
  let start = 0;
  while (start < value.length && value.charAt(start) === '/') {
    start += 1;
  }
  return value.substring(start);
}

function canonicalWindowsPath(value: string): string {
  const normalized = normalizeRemotePath(value).trim().replace(/\//g, '\\');
  const drive = /^([A-Za-z]:)\\?$/.exec(normalized);
  if (drive !== null) {
    return drive[1] + '\\';
  }
  return normalized;
}

function posixParentPath(rawPath: string): string | undefined {
  const clean = rawPath.trim().replace(/\/+$/, '');
  const target = clean.length > 0 ? clean : '.';
  if (target === '.' || target === '/' || target === HOME_ROOT) {
    return undefined;
  }
  const slash = target.lastIndexOf('/');
  if (slash < 0) {
    return '.';
  }
  if (slash === 0) {
    return '/';
  }
  return target.substring(0, slash);
}

function windowsParentPath(rawPath: string, allowDriveOverview: boolean): string | undefined {
  const clean = rawPath.replace(/\\/g, '/').replace(/\/+$/, '');
  const target = clean.length > 0 ? clean : '.';
  if (target === '.' || target === HOME_ROOT) {
    return undefined;
  }
  if (/^[A-Za-z]:$/.test(target)) {
    return allowDriveOverview ? '' : undefined;
  }
  if (!/^[A-Za-z]:\//.test(target)) {
    const parent = posixParentPath(target);
    return parent === undefined ? undefined : parent.replace(/\//g, '\\');
  }
  const slash = target.lastIndexOf('/');
  if (slash < 0) {
    return undefined;
  }
  if (slash === 2) {
    return target.substring(0, 2) + '\\';
  }
  return target.substring(0, slash).replace(/\//g, '\\');
}

/**
 * 「最近使用的工作目录」（上游 `feature/sessions/NewSessionWorkspaces.kt:8` 的 `recentWorkspacePaths`）。
 *
 * **它属于新建「会话」模式**：上游 `WorkspaceSection(projectMode = false)` 的主体内容就是这份列表，
 * 而**项目列表只在 `projectMode = true`（新建项目）时显示** —— 两套内容不是同一个东西。
 * 本工程此前两种模式都渲染项目列表，于是「浏览选定目录」后界面看不出任何变化（R13-26）。
 *
 * 算法逐条对齐上游：
 *  ① 按 `id` 去重会话，保留 `updatedSeq` 最大的那份；
 *  ② 会话按「运行中优先 → sortAt 倒序 → id 倒序」排序后取 `cwd`（空 cwd 丢弃）；
 *  ③ 项目按「置顶优先 → 时间倒序 → 名称 → id」排序后取 `workspacePath`；
 *  ④ 拼接（会话在前）→ 去空白 → 按 `workspacePathKey` 去重 → 去掉等于 homePath 的那条。
 *
 * ⚠️ 上游比较器还用到 `optimisticTopUntil`（本地乐观置顶），本工程没有该字段，
 * 这里退化为「`status` 为 `running` 即视为运行中」—— 只影响并列排序，不影响哪些路径会进列表。
 */
export function recentWorkspacePaths(
  connectorId: string | undefined,
  deviceOs: string,
  homePath: string | undefined,
  sessions: AgentSession[],
  projects: AgentProject[]
): string[] {
  const device = connectorId === undefined ? '' : connectorId.trim();
  if (device.length === 0) {
    return [];
  }
  const byId = new Map<string, AgentSession>();
  for (const session of sessions) {
    if (session.connectorId !== device) {
      continue;
    }
    const current = byId.get(session.id);
    if (current === undefined || session.updatedSeq >= current.updatedSeq) {
      byId.set(session.id, session);
    }
  }
  const ordered: AgentSession[] = Array.from(byId.values());
  ordered.sort((left: AgentSession, right: AgentSession): number => {
    const leftRunning = left.status === SessionStatus.Running;
    const rightRunning = right.status === SessionStatus.Running;
    if (leftRunning !== rightRunning) {
      return leftRunning ? -1 : 1;
    }
    if (leftRunning) {
      return left.id < right.id ? -1 : (left.id > right.id ? 1 : 0);
    }
    const delta = isoMillis(right.sortAt) - isoMillis(left.sortAt);
    if (delta !== 0) {
      return delta;
    }
    return left.id < right.id ? 1 : (left.id > right.id ? -1 : 0);
  });
  const all: string[] = [];
  for (const session of ordered) {
    const cwd = session.cwd;
    if (cwd !== undefined && cwd.trim().length > 0) {
      all.push(cwd);
    }
  }
  const owned = projects.filter((p: AgentProject): boolean => p.connectorId === device);
  owned.sort((left: AgentProject, right: AgentProject): number => {
    if (left.pinned !== right.pinned) {
      return left.pinned ? -1 : 1;
    }
    const delta = projectMillis(right) - projectMillis(left);
    if (delta !== 0) {
      return delta;
    }
    const byName = left.name < right.name ? -1 : (left.name > right.name ? 1 : 0);
    if (byName !== 0) {
      return byName;
    }
    return left.id < right.id ? -1 : (left.id > right.id ? 1 : 0);
  });
  for (const project of owned) {
    if (project.workspacePath.trim().length > 0) {
      all.push(project.workspacePath);
    }
  }
  const homeKey = workspacePathKey(homePath === undefined ? '' : homePath, deviceOs);
  const seen = new Set<string>();
  const result: string[] = [];
  for (const path of all) {
    if (path.trim().length === 0) {
      continue;
    }
    const key = workspacePathKey(path, deviceOs);
    if (key === homeKey || seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(path);
  }
  return result;
}

/** ISO 时间 → 毫秒；缺失/非法一律 0（对齐上游 `timestampMillis`）。 */
function isoMillis(value: string | undefined): number {
  if (value === undefined || value.length === 0) {
    return 0;
  }
  const parsed = Date.parse(value);
  return isNaN(parsed) ? 0 : parsed;
}

/** 项目排序时间：lastActivityAt → updatedAt（上游 workspaceProjectComparator）。 */
function projectMillis(project: AgentProject): number {
  if (project.lastActivityAt !== undefined && project.lastActivityAt.length > 0) {
    return isoMillis(project.lastActivityAt);
  }
  return isoMillis(project.updatedAt);
}