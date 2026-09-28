/**
 * 远端文件浏览状态（对应 Android `feature/files/FilesController.kt` +
 * `RemoteFileNavigation.kt`，UI 对应 `ui/screens/files/FilesScreen.kt`）。
 *
 * 语义：一次只列一个目录（`/connectors/{id}/fs/list`），点目录进入、点文件预览
 * （`/connectors/{id}/fs/readText?root=`）。根目录由调用方给定（通常是项目工作区）。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl } from '../store/AuthSessionStore';
import { RemoteDirectoryEntry, RemoteTextFile } from '../model/Types';
// `~` 的单一事实来源与路径域纯模块同源（第十一轮 D1：顶层文件页的 root 契约）。
// R13-3：盘符总览（这台电脑）的判定与请求拆分**全部复用** model/DirBrowse（上游 RemoteFileNavigation 的移植），
// 本 store 只负责把结果落进字段 —— 不要在页面里另写一套字符串运算。
import {
  HOME_ROOT, RemoteFileRequest, WINDOWS_DRIVE_OVERVIEW_LABEL, browseParentPath,
  canonicalRemoteDirectoryPath, isWindowsDeviceOs, isWindowsDriveOverview, remoteFileRequest,
  windowsDriveRoot
} from '../model/DirBrowse';

export interface BreadcrumbSegment {
  label: string;
  path: string;
}

export class FilesStore {
  private static instance?: FilesStore;

  deviceId: string = '';
  /**
   * 设备的系统标识（`windows` / `macos` / `linux`，来自 `AgentDevice.deviceOs`）。
   *
   * ⚠️ 这不是装饰字段：Windows 的**起始路径是空串**（盘符总览），请求的 root 还要按盘符切。
   * 判定全部走 `model/DirBrowse` 的纯函数，页面只负责把字段串进来。
   */
  deviceOs: string = '';
  root: string = '.';
  currentPath: string = '.';
  entries: RemoteDirectoryEntry[] = [];
  truncated: boolean = false;
  loading: boolean = false;
  error: string = '';

  preview?: RemoteTextFile;
  previewLoading: boolean = false;
  previewError: string = '';
  /** 预览请求序号：用于丢弃「先发后到」的过期响应。 */
  private previewRequest: number = 0;

  showHidden: boolean = false;
  query: string = '';

  private listeners: Array<() => void> = [];

  static get(): FilesStore {
    if (FilesStore.instance === undefined) {
      FilesStore.instance = new FilesStore();
    }
    return FilesStore.instance;
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  async open(
    deviceId: string, root: string, path: string = '.', deviceOs: string = ''
  ): Promise<void> {
    const changed = this.deviceId !== deviceId || this.root !== root || this.deviceOs !== deviceOs;
    this.deviceId = deviceId;
    this.root = root;
    this.deviceOs = deviceOs;
    if (changed) {
      this.entries = [];
      this.preview = undefined;
      this.query = '';
    }
    await this.navigate(path);
  }

  async navigate(path: string): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || this.deviceId.length === 0) {
      this.error = '缺少设备信息。';
      this.notify();
      return;
    }
    // 请求的 (root, path) 由上游移植过来的纯函数拆：Windows 下目标路径带盘符时
    // **根要切到盘符**（root=C:/, path=C:/Users），空路径则是「盘符总览」（root 沿用兜底、path 为空）。
    const request: RemoteFileRequest = remoteFileRequest(path, this.deviceOs, this.root);
    this.loading = true;
    this.error = '';
    this.preview = undefined;
    this.previewError = '';
    this.notify();
    try {
      const directory = await AppServices.get().files.listFiles(
        serverUrl, token, this.deviceId, request.root, request.path);
      // 服务端回话归一（`.` / 空串 / 盘符形态）走上游 canonicalRemoteDirectoryPath。
      const canonical = canonicalRemoteDirectoryPath(request, directory.path, this.deviceOs);
      this.currentPath = canonical;
      // ⚠️ 顺序要紧：先把未解析的根（`~`）收敛成服务端回的绝对路径，再算面包屑/上一级。
      this.adoptResolvedRoot(canonical);
      this.entries = this.sortEntries(directory.entries);
      this.truncated = directory.truncated;
    } catch (error) {
      this.error = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      this.loading = false;
      this.notify();
    }
  }

  async refresh(): Promise<void> {
    await this.navigate(this.currentPath);
  }

  /**
   * 「上一级」的目标路径（`undefined` = 已经没有上一级）。
   *
   * 对应上游 `FileListContent` 里那个 `..` 行（`SessionAgentFilesScreen.kt:920-942`）：
   *
   * ```kotlin
   * val parent = remoteParentPath(directory.path, deviceOs,
   *  allowWindowsDriveOverview = isWindowsDeviceOs(deviceOs))
   * if (parent != null) item("..") { FolderRow(name = "..", ...) }
   * ```
   *
   * ⚠️ 根目录再往上会**越出 root**：真机上 `.` 的父级被算成绝对路径
   * （如 root=`/Users/me/code/demo` → parent=`/Users/me/code`），
   * 既会请求工作区之外的目录，又会让面包屑退回「绝对路径切片」的老 bug（坑 140）。
   * 判定收敛到纯模块 model/DirBrowse.browseParentPath（内部复用 RemotePaths，可 Node 自测）。
   *
   * R13-3（Windows）：盘符根（`C:`）的上一级是**盘符总览**（空路径 → 「这台电脑」）；
   * 总览态本身没有上一级（返回 undefined）。
   *
   * ⚠️ 返回空串与返回 `undefined` **不是一回事**：前者是「上一级 = 盘符总览」这个**真实目标**
   * （页面必须画 `..` 行），后者是「没有上一级」（不画）。调用方一律判 `=== undefined`，别判真值。
   */
  parentPath(): string | undefined {
    return browseParentPath(this.currentPath, this.root, this.deviceOs, true);
  }

  /** 返回上一级（没有上一级时什么都不做）。页面那颗常驻按钮已按上游移除，见 `parentPath()`。 */
  async up(): Promise<void> {
    const target = this.parentPath();
    if (target === undefined) {
      return;
    }
    await this.navigate(target);
  }

  /**
   * 把**未解析的浏览根**（`~` / 空 / `.`）收敛成服务端返回的绝对路径。
   *
   * 上游 `DeviceFilesContent` 用 `resolvedRoot` 干这件事（`SessionAgentFilesScreen.kt:378-388`）：
   * 第一次以 `fallbackRoot = "~"` 请求成功后，把 `resolvedRoot` 置成返回的 `directory.path`，
   * 之后的列目录 / 上一级 / 读文件都以它为根。
   *
   * 为什么必须做（第十一轮真机 P0 的根因链）：
   *  - 顶层入口（首页「文件」卡片）不带路由参数，root 是空串 ⇒ 服务端直接 `root is required`；
   *  所以 `FilesScreen` 先把它归一成 `~`（上游的 `fallbackRoot`）；
   *  - 但 `~` 是**相对表达**，若不解析：面包屑的根标签会显示成字面量 `~`，
   *  且 `parentWithinRoot(currentPath, '~')` 会把「上一级」判成越界、收敛回 `.`
   *  —— 而 `.` 又被服务端拒绝（死循环回到同一个 P0）。
   *  - 解析成绝对路径后这三件事同时自洽。
   */
  private adoptResolvedRoot(returnedPath: string): void {
    if (isWindowsDeviceOs(this.deviceOs)) {
      // 上游 `DeviceFilesContent`：`resolvedRoot = windowsDriveRoot(nextDirectory.path)`。
      // 盘符总览态（返回空路径）拿到 undefined → **保留原 root**，
      // 这样从总览再进任何盘符时 `remoteFileRequest` 仍能把根切过去。
      const drive = windowsDriveRoot(returnedPath);
      if (drive !== undefined) {
        this.root = drive;
      }
      return;
    }
    const current = this.root.trim();
    if (current.length > 0 && current !== '.' && current !== HOME_ROOT) {
      return;
    }
    const resolved = returnedPath.trim();
    if (resolved.length === 0 || resolved === '.' || resolved === HOME_ROOT) {
      return;
    }
    this.root = resolved;
  }

  private sortEntries(entries: RemoteDirectoryEntry[]): RemoteDirectoryEntry[] {
    const copy = entries.slice();
    copy.sort((a: RemoteDirectoryEntry, b: RemoteDirectoryEntry): number => {
      const aDir = a.type === 'directory';
      const bDir = b.type === 'directory';
      if (aDir !== bDir) {
        return aDir ? -1 : 1;
      }
      return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    });
    return copy;
  }

  visibleEntries(): RemoteDirectoryEntry[] {
    const query = this.query.trim().toLowerCase();
    const out: RemoteDirectoryEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const entry = this.entries[i];
      if (!this.showHidden && entry.name.startsWith('.')) {
        continue;
      }
      if (query.length > 0 && !entry.name.toLowerCase().includes(query)) {
        continue;
      }
      out.push(entry);
    }
    return out;
  }

  /** 当前是否处在 Windows 的**盘符总览**态（「这台电脑」：path 为空）。 */
  isDriveOverview(): boolean {
    return isWindowsDriveOverview(this.currentPath, this.deviceOs);
  }

  breadcrumbs(): BreadcrumbSegment[] {
    // R13-3（Windows 盘符总览）：path 为空 = 「这台电脑」态。
    // 此时**不能**去算根标签 —— root 还是上一次的兜底根（比如 `C:\\` 或 `~`），
    // 显示出来会是「C: /」这种与安卓不一致的东西；面包屑就应该是孤零零一节「这台电脑」。
    if (this.isDriveOverview()) {
      return [{ label: WINDOWS_DRIVE_OVERVIEW_LABEL, path: '' }];
    }
    // ⚠️ 服务端返回的目录 `path` 可能是**绝对路径**（真机实测：`/Users/mock/code/agents-anywhere/src`），
    // 而 store 的根也是调用方给的绝对根。老实现直接把 currentPath 按 `/` 切开，
    // 于是「根」那一节被算成 `Users`、标签又显示整条绝对路径 —— 真机上表现为面包屑又长又重复，
    // 点第一节还会跳到不存在的相对路径 `Users`。正解：先剥掉根前缀，只对相对根的余下部分切片；
    // 根那一节固定 path='.'（store 的 navigate('.') 就是「回到根目录」）。
    const rootNorm = this.root.replace(/\\/g, '/').replace(/\/+$/, '');
    // 「根还没解析成绝对路径」的三种形态：空串 / `.` / `~`。
    // 未解析时**不能**把 `~` 当目录名用：那会冒出一节标签为 `~` 的面包屑，
    // 也会让 `relative.startsWith(rootNorm)` 拿 `~` 去切 currentPath。
    const unresolvedRoot = rootNorm.length === 0 || rootNorm === '.' || rootNorm === HOME_ROOT;
    let rootLabel = '工作区';
    if (!unresolvedRoot) {
      const slash = rootNorm.lastIndexOf('/');
      rootLabel = slash >= 0 ? rootNorm.substring(slash + 1) : rootNorm;
      if (rootLabel.length === 0) {
        rootLabel = rootNorm;
      }
    }
    const segments: BreadcrumbSegment[] = [{ label: rootLabel, path: '.' }];
    // Windows：盘符之上还有一层「这台电脑」（上游 `remoteParentPath(C:\\…, allowWindowsDriveOverview=true)`
    // 会给出空路径 = 总览）。补这一节才有回退入口，且与安卓的面包屑层级一致。
    if (isWindowsDeviceOs(this.deviceOs)) {
      segments.unshift({ label: WINDOWS_DRIVE_OVERVIEW_LABEL, path: '' });
    }
    let relative = this.currentPath.replace(/\\/g, '/');
    if (!unresolvedRoot && relative.startsWith(rootNorm)) {
      relative = relative.substring(rootNorm.length);
    }
    relative = relative.replace(/^\/+/, '');
    const parts = relative.split('/');
    let accumulated = '';
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      if (part.length === 0 || part === '.') {
        continue;
      }
      accumulated = accumulated.length === 0 ? part : `${accumulated}/${part}`;
      segments.push({ label: part, path: accumulated });
    }
    return segments;
  }

  /** 预览文本文件（图片/二进制由页面决定是否下载）。 */
  async openPreview(path: string): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    // 请求序号：快速连点两个文件时，先发的请求可能后到 —— 没有序号就会
    // 「点 A 弹出 B 的内容」（验收类缺陷，见坑 139）。
    this.previewRequest += 1;
    const request = this.previewRequest;
    this.previewLoading = true;
    this.previewError = '';
    this.preview = undefined;
    this.notify();
    try {
      const file = await AppServices.get().files.readTextFile(
        serverUrl, token, this.deviceId, this.root, path);
      if (request !== this.previewRequest) {
        return;
      }
      this.preview = file;
    } catch (error) {
      if (request !== this.previewRequest) {
        return;
      }
      this.previewError = error instanceof Error ? (error as Error).message : String(error);
    } finally {
      if (request === this.previewRequest) {
        this.previewLoading = false;
        this.notify();
      }
    }
  }

  closePreview(): void {
    this.previewRequest += 1;
    this.preview = undefined;
    this.previewError = '';
    this.previewLoading = false;
    this.notify();
  }
}

/**
 * 路径判定统一收敛到纯模块 `model/RemotePaths.ets`（无 Kit 依赖，可 Node 自测）。
 * 这里 re-export，保持既有调用方的 import 路径不变。
 */
export { parentPath, isOutsideRoot, parentWithinRoot } from '../model/RemotePaths';

/** 常见可预览的文本扩展名。 */
// 「能不能当文本预览」的判定收敛到 model/TextFiles.ets（纯逻辑、可 Node 自测）。
// 这里 re-export，保持 FilesScreen 等调用方的 import 路径不变。
export { isTextPreviewable } from '../model/TextFiles';

export function formatBytes(size: number | undefined): string {
  if (size === undefined || size < 0) {
    return '';
  }
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  if (size < 1024 * 1024 * 1024) {
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(size / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
