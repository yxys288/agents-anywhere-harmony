/**
 * 远端文件浏览（对应 Android `ui/screens/files/FilesScreen.kt`）。
 *
 * **顶层目的地**（与首页平级），页内自带设备选择器 —— 与 `TerminalScreen.ets` **结构逐字同构**：
 * 默认选中第一个在线设备、顶栏是「40dp 圆形返回钮 + 44dp 设备选择条」、点开只列在线设备的下拉、
 * 无设备 / 全离线各有专门空态、返回一律回首页（上游 `navigate(Sessions)`）。
 * 设备选择与排序的纯逻辑**直接复用终端页那一份**（见 `TerminalScreen.ets` 末尾的
 * 「设备选择（纯逻辑）」区）—— 两页同构因此是同一份实现，不是两份复制品。
 *
 * 本页保留的项目内能力：面包屑（可点分段）、文本预览（sheet）、预览内的内容搜索与两个复制按钮。
 *
 * **R13-20 按逐页并排判读（开发期验证记录的 3-1~3-4）去掉了
 * 三处「本工程自加、上游没有」的常驻入口 + 改了一处对齐**（每条都有上游锚文，见对应构建器注释）：
 *  ① 顶栏常驻「上一级」按钮 → 归位为上游**列表首项的 `..` 行**（`SessionAgentFilesScreen.kt:920-942`）
 *  —— 这不是删能力，是换形态；
 *  ② 路径条下方的「搜索」输入框 + 「显示点文件」开关 → **删**。上游文件列表里没有这两样：
 *  `Lucide.Search` 只出现在**文件预览**里（`:1192` / `:1256`），显示点文件的开关连 key 都没有，
 *  且全仓 Kotlin 零 dotfile 过滤；
 *  ③ 文件行右侧常驻「⧉」复制图标 → **删**（上游每行只有 `trailing`，复制路径在长按菜单
 *  `FileActionMenu` 里，本工程未移植 —— 该入口的取舍见交付说明）；
 *  ④ 「这台电脑」由**居中**改**左对齐**（上游 `PathBar` 左块是 `contentAlignment = Alignment.CenterStart`）。
 *
 * 第十一轮补的两件事（上游都有、本页此前没有）：
 *  ① **复制完整远程路径** + **复制代码** —— 上游 `FileActionMenu`（长按行弹出）与
 *  `PreviewCardHeader`（`files_copy_path` / `files_copy_code`）。⚠️ 行内那一份已在 R13-20 删除，
 *  现在只剩**路径条方块**（复制当前目录）与**预览面板两个按钮**；
 *  ② **文件内容搜索** —— 上游 `files_search_in_file` + `InlineFileSearchControls` +
 *  `CodeBlockPreview.kt` 的 `SoraFileSearchController`：面板显示「当前/总数」，上一条 / 下一条
 *  **循环**跳转。本工程把它做成命中列表（编辑器内高亮 + 滚动定位在 ArkUI 的 `Text` 上做不到，
 *  列表同样可点、可数、可 dump）。
 *
 * 判定与复制载荷全部收敛到纯模块 `model/FileSearch.ets`（无 Kit 依赖、可 Node 自测，
 * 断言在 `tools/logic-test/suite-files.mjs`）。
 */

// 剪贴板走 `@kit.BasicServicesKit` 的 pasteboard —— 与工程内既有三处（SessionDetailScreen /
// DeviceDetailScreen / AddDeviceScreen）**同一套写法**，不新引任何 Kit。
import { pasteboard } from '@kit.BasicServicesKit';
import { BreadcrumbSegment, FilesStore, isTextPreviewable } from '../../feature/FilesStore';
import { DashboardStore } from '../../feature/DashboardStore';
import { AgentDevice } from '../../model/AppModels';
// 浏览根 `~` 与**盘符总览**的判定都来自 `model/DirBrowse.ets`
// （上游 `RemoteFileNavigation.kt` 的移植；第十一轮 W3/B5 交付，R13-3 接线到本页）。
import {
  HOME_ROOT, WINDOWS_DRIVE_OVERVIEW_LABEL, displayRemotePath, initialRemoteFilePath,
  isWindowsDeviceOs
} from '../../model/DirBrowse';
import { RemoteDirectoryEntry, RemoteTextFile } from '../../model/Types';
import {
  Control, FontSize, Radius, Space, StrokeWidth, borderColor, canvas, faint, filesRowChevron, filesRowIcon,
  filesRowText, ink, inkSoft, muted, onPrimaryAction, primaryAction, raisedSurface, rowPressedSurface, subtle,
  // R66（SPEC §2）：**栏内胶囊**（设备选择条）的官方材质令牌 —— R87 起栏本体已不挂材质。
  glassCardSurface
} from '../Design';
// R66（SPEC §2）：标题栏（功能栏）本体与栏内胶囊的**官方沉浸材质**走本工程唯一构造入口
// `Components.ets#officialBarMaterial(color)` —— 本页**不得**直接引入 `uiMaterial`（它属于 `@kit.ArkUI`）：
// `suite-files.mjs` 有断言「FilesScreen 只引了 BasicServicesKit 这一个 Kit」，判据是**整文件**扫描 Kit 的
// import 片段（**连注释里的提及也会被数进去**）⇒ 材质实例必须由 Components 提供。
// R86：`dialogMaterial()` = 弹窗类小面板的官方材质入口（`REGULAR` 档，见 Components.ets:147）；
// `immersiveMaterialEnabled()` = 可用性探针，用来**门控**内容根的自绘底（材质可用时让位）。
// 与 `officialBarMaterial` 同源收口 ⇒ 本页仍然**只**引 Components，不引 `uiMaterial`（上面的 Kit 断言）。
import { AaChip, AaCircleIconButton, AaErrorBanner, AaSecondaryButton, dialogMaterial,
  immersiveMaterialEnabled, officialBarMaterial } from '../Components';
import { Route, Router } from '../Router';
import { registerBackConsumer, unregisterBackConsumer } from '../BackHandler';
// R13-20：文件名过滤（`filterEntries` / `filterCountLabel` / `filterEmptyHint` / `hasActiveQuery`）
// 已随「搜索 + 显示点文件」那一行一起从本页移除 —— 上游文件列表**没有**这套东西（锚文见 `fileBrowser()`）。
// 那四个纯函数本身留在 model/FileSearch.ets（仍被 suite-files.mjs 覆盖），只是本页不再调用。
import {
  COPY_CODE_FAILED_HINT, COPY_FLASH_MILLIS, COPY_PATH_FAILED_HINT, CopyPayload, FileMatch,
  FileSearchResult, MATCH_LIST_LIMIT, codeCopyPayload,
  findMatches, pathCopyPayload,
  effectiveBrowseRoot, effectiveInitialPath, searchCountLabel, searchResultOf, stepSearchMatch
} from '../../model/FileSearch';
import { AaCodeText } from '../Markdown';
import { languageFromFileName } from '../SyntaxHighlight';
import {
  EMPTY_ILLUSTRATION_SIZE, MENU_LEFT, MENU_TOP,
  onlineDevices, pickDefaultDeviceId, sortDevicesForPage
} from './TerminalScreen';
import { AaIcon, ICONS } from '../Icon';
import { BOTTOM_BAR_RESERVED_VP } from '../BottomNav';

/** 预览面板「复制代码」按钮的「已复制」闪示 key（复制路径用的是条目自己的 path，故只需一个常量）。
 *  R43：同名的 PREVIEW_PATH_KEY 零使用，已删（tools/dead-code-scan 的 D 段候选）。 */
const PREVIEW_CODE_KEY: string = 'preview:code';
/** 命中列表的单行高与最多显示行数（再多由列表自己滚）。 */
const MATCH_ROW_HEIGHT: number = 32;
const MATCH_LIST_ROWS: number = 5;
/**
 * 路径条（对应上游 `PathBar`，锚文 `SessionAgentFilesScreen.kt:1504-1575`）：
 * 左侧铺满的圆角块放路径文本、右侧 52vp 方块是复制按钮，高 52 / 圆角 13 / 1.2dp 描边。
 *
 * ⚠️ 这两个值不落在 `ui/Design.ets`：令牌组里最近的两档是 `Control.FIELD_LARGE`(48)
 * 与 `Radius.M_PLUS`(14)，对不上上游原值；而 Design.ets 在本轮归 R13-4 管，
 * 为形态一比一就地取上游原值（52 / 13），不越界改别人的文件。
 */
const PATH_BAR_HEIGHT: number = 52;
const PATH_BAR_RADIUS: number = 13;
/**
 * 文件列表行的几何（逐字取上游 `FileListRow`，`SessionAgentFilesScreen.kt:1665-1715`）：
 * `Row.height(60.dp)` + `padding(horizontal = 10.dp)` + 图标槽 `Box.size(40.dp)`（圆角 12）+ `Icon.size(22.dp)`。
 * 行与行之间是 `LazyColumn` 的 `spacedBy(1.dp)`（`:913`）—— **不是** 4dp。
 */
const FILE_ROW_HEIGHT: number = 60;
const FILE_ROW_PAD_H: number = 10;
const FILE_ROW_ICON_BOX: number = 40;
/** 行间距（上游 `FileListContent` 的 `LazyColumn(verticalArrangement = spacedBy(1.dp))`）。 */
const FILE_ROW_GAP: number = 1;
/** 路径条复制按钮的「已复制」闪示 key（与列表行的 entry.path 区分开）。 */
const PATH_BAR_COPY_KEY: string = 'pathbar:copy';

/**
 * 行长按菜单（对应上游 `FileActionMenu`，锚文 `SessionAgentFilesScreen.kt:1736-1775`）。
 *
 * 上游尺寸逐条：宽 188dp / 高 54dp / 圆角 16dp / 描边 1dp / 内边距 horizontal 12dp；
 * 左侧 `Box(size 32.dp, CircleShape)` 里放 `Lucide.Copy` size(17.dp)，右侧文案 `files_copy_path`
 * （中文「复制路径」，14sp SemiBold）。
 */
const FILE_MENU_WIDTH: number = 188;
const FILE_MENU_HEIGHT: number = 54;
const FILE_MENU_RADIUS: number = 16;
const FILE_MENU_ICON_BOX: number = 32;
const FILE_MENU_ICON_SIZE: number = 17;
/**
 * 菜单锚点相对行的水平偏移。
 *
 * 上游 `:1647` `menuOffset = IntOffset(54.dp.roundToPx(), 56.dp.roundToPx())`，配
 * `:1718` `Popup(alignment = Alignment.TopStart, offset = menuOffset)`。
 * ArkUI 的 `bindPopup` 用 `placement` + `offset` 表达，这里取**水平那一半**（54）；
 * 垂直方向上游是「从行顶往下 56dp」（小于行高 60dp，即贴着行底内侧），ArkUI 没有等价语义，
 * 故用 `Placement.BottomLeft` + `targetSpace` 贴着行底外沿 —— **已知差异**，见交付说明。
 */
const FILE_MENU_OFFSET_X: number = 54;
/** 菜单与行的间距（上游没有这个量，ArkUI 的 `Placement` 需要一个非负 gap）。 */
const FILE_MENU_GAP: number = 4;
/** `..` 行的菜单 key：它没有 `entry.path`，且**目标路径可能是空串**（盘符总览），不能拿路径当 key。 */
const PARENT_ROW_KEY: string = '..';

/**
 * 预览页路径面包屑的尺寸（上游 `SessionAgentFilesScreen.kt:1043-1075` 的 `PreviewBreadcrumb`，逐项照抄）。
 *
 * 行高 30 / 元素间距 6；左胶囊高 28、左右内边距 10、内部间距 5、`chevron-left` 13dp + 11sp Bold 文案；
 * 中间 `/` 与右侧路径都是 11sp Bold（路径用等宽族、单行省略）。
 */
/** 预览卡头部（上游 `PreviewCardHeader`，`:1173-1181`）：行高 44 / 水平内边距 12 / 元素间距 8 / 文件名 15sp。 */
const PREVIEW_HEAD_H: number = 44;
const PREVIEW_HEAD_PAD: number = 12;
const PREVIEW_HEAD_GAP: number = 8;
const PREVIEW_FILE_FONT: number = 15;
/** 预览头部的图标按钮（上游 `PreviewIconButton`，`:1323-1344`）：34dp 见方、圆角 12、图标 16dp。 */
const PREVIEW_ICON_BTN: number = 34;
const PREVIEW_ICON_BTN_RADIUS: number = 12;
const PREVIEW_ICON_BTN_ICON: number = 16;
const PREVIEW_CRUMB_ROW_H: number = 30;
const PREVIEW_CRUMB_CHIP_H: number = 28;
const PREVIEW_CRUMB_GAP: number = 6;
const PREVIEW_CRUMB_CHIP_GAP: number = 5;
const PREVIEW_CRUMB_CHIP_PAD: number = 10;
const PREVIEW_CRUMB_ICON: number = 13;

/**
 * `CustomPopupOptions.onStateChange` 的入参。
 *
 * SDK 里它是**匿名对象类型**（`common.d.ts` 的 `(event: { isVisible: boolean }) => void`），
 * ArkTS 需要一个具名类型来标注箭头函数参数，故声明等价接口（与 `HomeScreen.ets:63` 同一写法）。
 */
interface AaPopupStateChange {
  isVisible: boolean;
}

@Component
export struct FilesScreen {
  @Prop deviceId: string = '';
  /**
   * 浏览根。**默认 `~`**（不是 `.`）—— 上游顶层文件页 `DeviceFilesContent` 的
   * `fallbackRoot = resolvedRoot?.takeIf { it.isNotBlank() } ?: "~"`
   * （`SessionAgentFilesScreen.kt:364`，同一函数里 `request.root == "~"` 的分支在 383 行）。
   *
   * ⚠️ 真机 P0（第十一轮）：首页「文件」卡片进入时不带任何路由参数
   * （`HomeScreen.quickEntryCard('文件', '🗀', Route.FILES)`），`Index.paramAt(1)` 于是给的是**空串**；
   * 空串当 root 发出去就是服务端那句 `root is required`（`fs/list` 的 body 是 `{root,path}`，
   * 见 `specs/01-api-spec.md:80`）。兜底见 `model/FileSearch.effectiveBrowseRoot()`：空串 / `.` 一律归一成 `~`。
   */
  @Prop root: string = HOME_ROOT;
  /** 初始目录。上游 `remoteFileRequest` 里 `path = normalizedPath.ifBlank { "." }`。 */
  @Prop initialPath: string = '.';

  // ⚠️ 状态必须在 build 里被真正读到才会触发刷新（见 HomeScreen 顶部注释）。
  @State entryList: RemoteDirectoryEntry[] = [];
  @State crumbs: BreadcrumbSegment[] = [];
  @State loadingFlag: boolean = false;
  @State errorText: string = '';
  @State truncatedFlag: boolean = false;
  /**
   * 「上一级」的目标路径 + 有没有上一级（决定列表首项那个 `..` 行画不画）。
   *
   * ⚠️ 两件事必须分开存：`parentPath` 可以是**空串**（= 上一级是盘符总览「这台电脑」），
   * 空串与「没有上一级」不是一回事（后者 `hasParent = false`）。判据见 `FilesStore.parentPath()`。
   */
  @State parentPath: string = '';
  @State hasParent: boolean = false;
  @State previewFile: RemoteTextFile | undefined = undefined;
  @State previewLoadingFlag: boolean = false;
  @State previewErrorText: string = '';
  @State previewOpen: boolean = false;
  /** 预览文件猜出来的语言档（空 = 纯文本显示）。 */
  @State previewLanguage: string = '';
  /** 设备列表（与终端页同一套排序，见 `TerminalScreen.ets` 的纯逻辑区）。 */
  @State devices: AgentDevice[] = [];
  /** 当前选中的设备 id（上游 `selectedDeviceId`：页面内局部状态，不跨页保持）。 */
  @State selectedDeviceId: string = '';
  /** 设备选择下拉是否展开。 */
  @State deviceMenuOpen: boolean = false;

  /** 列表页轻提示（复制路径的成功 / 失败），常驻可手关（与 SessionDetailScreen 的提示条同构）。 */
  @State actionHint: string = '';
  /**
   * 刚复制成功的 key（图标在 `⧉` / `✓` 之间闪一下，上游 `delay(1100)`）。
   * R13-20 起列表行不再有常驻复制钮，这里只剩**路径条方块**与**预览面板两个按钮**用。
   */
  @State copiedKey: string = '';
  /**
   * 长按菜单当前锚定的**行 key**（`''` = 没打开）。
   *
   * ⚠️ 用 key 而不是「行的路径」：`..` 那一行的目标路径**可能是空串**（Windows 盘符根 → 盘符总览），
   * 拿空串当「没打开」会撞车。`..` 行固定用 `PARENT_ROW_KEY`。
   */
  @State menuRowKey: string = '';
  /** 菜单要复制的路径（打开时算一次落进来，避免每帧重算、也让断言可查）。 */
  @State menuCopyPath: string = '';
  /** 预览面板内的轻提示（复制路径 / 复制代码 / 搜索说明）。 */
  @State previewHint: string = '';
  /** 预览面板的内容搜索：开关 / 关键字 / 命中列表 / 当前序号 / 总数。 */
  @State previewSearchOpen: boolean = false;
  @State previewQuery: string = '';
  @State previewMatches: FileMatch[] = [];
  @State previewMatchCurrent: number = 0;
  @State previewMatchTotal: number = 0;

  private store: FilesStore = FilesStore.get();
  /** 工作台 store：设备列表的唯一数据源（对应上游 `state.devices`）。 */
  private dashboard: DashboardStore = DashboardStore.get();
  /** 存成字段才能被 `offChange` 摘除（单例 store 的监听器数组只增不减）。 */
  private storeListener: () => void = () => {
    this.pull();
  };
  private dashboardListener: () => void = () => {
    this.syncDevices();
  };
  /** 「已复制」闪示的定时器句柄（`-1` = 没有在跑）。 */
  private copyFlashTimer: number = -1;

  /**
   * 返回键消费者（R14：预览从 bottom sheet 改成**同页替换**后新增）。
   *
   * 为什么必须有：sheet 时代「返回键先关 sheet」是系统的行为；改成同页替换后，
   * 不注册消费者的话返回键会**直接退出整个文件页**（行为退化）。
   * 优先级：预览态 → 设备浮层 → 交回路由栈。
   * ⚠️ 注册表是单槽、按**函数身份**注销，所以这个引用必须是稳定的实例字段。
   */
  private backConsumer: () => boolean = () => {
    if (this.previewOpen) {
      this.closePreview();
      return true;
    }
    if (this.deviceMenuOpen) {
      this.deviceMenuOpen = false;
      return true;
    }
    return false;
  };

  aboutToAppear(): void {
    this.dashboard.onChange(this.dashboardListener);
    this.store.onChange(this.storeListener);
    this.syncDevices();
    this.openSelected();
    registerBackConsumer(this.backConsumer);
  }

  aboutToDisappear(): void {
    unregisterBackConsumer(this.backConsumer);
    this.store.offChange(this.storeListener);
    this.dashboard.offChange(this.dashboardListener);
    if (this.copyFlashTimer >= 0) {
      clearTimeout(this.copyFlashTimer);
      this.copyFlashTimer = -1;
    }
  }

  // -------------------------------------------------------------------------
  // 顶层页：设备选择（与 TerminalScreen 同构，纯逻辑共用终端页那一份）
  // -------------------------------------------------------------------------

  /** 工作台设备列表 → 页面状态（排序 + 默认选中）；语义与终端页逐字一致。 */
  private syncDevices(): void {
    const sorted = sortDevicesForPage(this.dashboard.devices);
    this.devices = sorted;
    const preferred = this.selectedDeviceId.length > 0 ? this.selectedDeviceId : this.deviceId;
    const next = pickDefaultDeviceId(sorted, preferred);
    if (next === this.selectedDeviceId) {
      return;
    }
    this.selectedDeviceId = next;
    this.deviceMenuOpen = false;
    this.openSelected();
  }

  /**
   * 用当前选中设备打开文件浏览。
   * 顶层入口下 `root` / `initialPath` 都是缺省值（空串 / `.`）——
   * 从会话文件页带参进来时仍按路由参数走（兼容口径，与终端页一致）。
   *
   * 起始路径按设备系统分流（R13-3）：Windows 从**盘符总览**起步，其余从 `.` 起步。
   */
  private openSelected(): void {
    if (this.selectedDeviceId.length === 0) {
      return;
    }
    // 换设备 = 换根 = 换一批文件：预览搜索与轻提示都要一起清掉，
    // 否则切设备后还带着上一台的状态。
    this.resetPreviewSearch();
    // root / initialPath 的归一判定在 model/FileSearch（纯函数，可 Node 自测）：
    // 顶层入口的空串、设备详情的 `.` 都收敛成上游的 `~`，否则服务端回 `root is required`。
    //
    // R13-3（Windows 盘符总览）：**起始路径是空串**，不是 `.`。
    // 上游锚文 `DeviceFilesContent`：`load(if (isWindowsDevice) "" else ".")`
    // （`SessionAgentFilesScreen.kt:408`）+ `initialRemoteFilePath(deviceOs)`。
    // 服务端（connector `local/file_ops.py` 的 `read_dir`）只在 `path == ""` 时回盘符列表
    // `C:` / `D:` / `E:`；给 `.` 就只列主目录 —— 这正是 R12 对照里「直接进 工作区 /」的成因。
    const deviceOs = this.selectedDeviceOs();
    const initialPath = isWindowsDeviceOs(deviceOs)
      ? initialRemoteFilePath(deviceOs)
      : effectiveInitialPath(this.initialPath);
    this.store.open(this.selectedDeviceId, effectiveBrowseRoot(this.root), initialPath, deviceOs);
  }

  /** 当前「真正选中」的设备：必须在线（对齐上游 `firstOrNull { it.id == … && it.online }`）。 */
  private selectedDevice(): AgentDevice | undefined {
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (device.id === this.selectedDeviceId && device.online) {
        return device;
      }
    }
    return undefined;
  }

  /**
   * 当前选中设备的系统标识（`windows` / `macos` / `linux`）；取不到就是空串（按 posix 走）。
   *
   * ⚠️ ArkTS 不对「重复取同一可选属性」做窄化（`x.a !== undefined ? x.a : ''` 报
   * string | undefined 不可赋给 string），必须先落到局部变量 —— 与 `NewSessionScreen.deviceOs()` 同一写法。
   */
  private selectedDeviceOs(): string {
    const device = this.selectedDevice();
    if (device === undefined) {
      return '';
    }
    const deviceOs = device.deviceOs;
    return deviceOs !== undefined ? deviceOs : '';
  }

  private hasOnlineDevice(): boolean {
    return onlineDevices(this.devices).length > 0;
  }

  private selectedDeviceLabel(): string {
    const device = this.selectedDevice();
    return device !== undefined ? device.name : '暂无在线设备';
  }

  private selectedDeviceIdOrEmpty(): string {
    const device = this.selectedDevice();
    return device !== undefined ? device.id : '';
  }

  /** store → @State 快照（build 只读这些字段）。 */
  private pull(): void {
    // ⚠️ 目录项必须换**新数组引用**落进 `@State entryList`，build 只读这个字段才会重渲染；
    // 靠自增 tick 是无效写法（坑 134）。
    //
    // R13-20：这里**不再过滤**（既不按文件名，也不按点文件）—— 上游 `FileListContent` 的
    // `items(directory.entries, key = { it.path })`（锚文 :943-975）就是**原样列全部条目**，
    // 且上游 Kotlin 全仓零 dotfile 过滤（grep `showHidden` / `startsWith(".")` 无命中）。
    this.entryList = this.store.entries.slice();
    this.crumbs = this.store.breadcrumbs();
    // 列表首项那个 `..` 行（上游 :920-942）。`undefined` = 没有上一级 ⇒ 不画。
    const parent = this.store.parentPath();
    this.hasParent = parent !== undefined;
    this.parentPath = parent !== undefined ? parent : '';
    this.loadingFlag = this.store.loading;
    this.errorText = this.store.error;
    this.truncatedFlag = this.store.truncated;
    this.previewFile = this.store.preview;
    this.previewLanguage = this.previewFile !== undefined
      ? languageFromFileName(this.previewFile.name) : '';
    this.previewLoadingFlag = this.store.previewLoading;
    this.previewErrorText = this.store.previewError;
  }

  // -------------------------------------------------------------------------
  // R13-20：本页**没有**文件名过滤，也没有「显示点文件」开关
  // -------------------------------------------------------------------------
  //
  // 这两样都是本工程自加的常驻入口，上游没有：
  //  · 文件名过滤：上游文件列表里根本没有输入框 —— `Lucide.Search` 只出现在**文件预览**里
  //  （`SessionAgentFilesScreen.kt:1192` 是预览头的 `files_search_in_file` 按钮、
  //  `:1256` 是预览内联搜索框的图标）；`FileListContent`（:882-979）只有 PathBar + LazyColumn；
  //  · 「显示点文件」：`values-zh-rCN/strings.xml` 里查不到对应 key，上游 Kotlin 也零 dotfile 过滤。
  // 本工程的**文件预览**里那一套「在文件中搜索」是上游同款能力，保留不动。

  /** 清空预览面板的搜索与提示（换文件、关面板时调用）。 */
  private resetPreviewSearch(): void {
    this.previewSearchOpen = false;
    this.previewQuery = '';
    this.previewMatches = [];
    this.previewMatchCurrent = 0;
    this.previewMatchTotal = 0;
    this.previewHint = '';
    this.flashCopied('');
  }

  // -------------------------------------------------------------------------
  // 复制（剪贴板 + 轻提示）
  // -------------------------------------------------------------------------

  /**
   * 统一写系统剪贴板。
   *
   * 写剪贴板不需要权限，但 SDK 的 `createData` / `setData` 标了 `@throws`，必须包 try
   * —— 与 `SessionDetailScreen.copyTextToBoard` / `DeviceDetailScreen.copyText` 同一套写法。
   * 失败不再静默：`onResult(false)` 由调用方转成可见提示。
   */
  private writeClipboard(text: string, onResult: (ok: boolean) => void): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        onResult(true);
      }).catch(() => {
        onResult(false);
      });
    } catch (error) {
      onResult(false);
    }
  }

  /** 「已复制」闪示 1.1s（上游 `delay(1100)`）。key 为空表示立刻清掉不闪。 */
  private flashCopied(key: string): void {
    this.copiedKey = key;
    if (this.copyFlashTimer >= 0) {
      clearTimeout(this.copyFlashTimer);
      this.copyFlashTimer = -1;
    }
    if (key.length === 0) {
      return;
    }
    this.copyFlashTimer = setTimeout(() => {
      this.copyFlashTimer = -1;
      this.copiedKey = '';
    }, COPY_FLASH_MILLIS);
  }

  /**
   * 目录条当前该显示的路径（上游每次渲染 PathBar 都现算一遍 `displayRemotePath`）。
   *
   * R13-3：改用 `model/DirBrowse.displayRemotePath`（四参版）—— 它多一条
   * 「盘符总览 → 这台电脑」分支（`isWindowsDriveOverview`），这正是本页要补的那一态；
   * `model/FileSearch.displayRemotePath`（两参）没有 deviceOs，算不出这一态。
   */
  private currentDisplayPath(): string {
    return displayRemotePath(
      this.store.root, this.store.currentPath, this.store.deviceOs, WINDOWS_DRIVE_OVERVIEW_LABEL);
  }

  /** 复制路径条上的路径（上游 PathBar 的复制钮就是 `clipboard.setText(path)`）。 */
  private copyCurrentPath(): void {
    const payload: CopyPayload = pathCopyPayload(this.currentDisplayPath());
    if (!payload.enabled) {
      this.actionHint = payload.hint;
      return;
    }
    this.writeClipboard(payload.text, (ok: boolean) => {
      // 失败提示与列表行同源（差异·平台必需新增，见 model/FileSearch.COPY_PATH_FAILED_HINT）。
      this.actionHint = ok ? payload.hint : COPY_PATH_FAILED_HINT;
      this.flashCopied(ok ? PATH_BAR_COPY_KEY : '');
    });
  }

  // -------------------------------------------------------------------------
  // 行长按菜单（R13-23：移植上游 `FileActionMenu`）
  // -------------------------------------------------------------------------
  //
  // 上游这条链路共三段，逐段对应：
  //  ① 触发：`FileListRow` 的 `combinedClickable(onClick, onLongClick)`（`:1673-1690`），
  //  `onLongClick = { onOpenMenu() }`；**单击里也先调 `onDismissMenu()`**（`:1677`）；
  //  ② 弹出：`Popup(alignment = TopStart, offset = menuOffset, onDismissRequest = onDismissMenu)`
  //  （`:1716-1731`）—— Compose 的 `Popup` **默认没有遮罩**，本工程对应地把
  //  `CustomPopupOptions.mask` 设成全透明（下面的 `rowMenuPopupOptions()`），
  //  这也是 F-5「安卓没有 scrim」那条差异在菜单这里必须守住的点；
  //  ③ 本体：`FileActionMenu`（`:1736-1775`）—— **只有一项**「复制路径」，
  //  不按文件类型也不按可写性增减（`..` / 目录 / 文件三种行都走同一个菜单）。
  //
  // 本工程的行既有 `.onClick`（进目录 / 开预览）。长按与单击共存的做法**照抄 `HomeScreen.ets`**
  // （`:1078` `.onClick` + `:1081` `.gesture(LongPressGesture())`，那份是已在用的实现）：
  // 长按走 `LongPressGesture`，单击仍然是原来的 `onClick`，互不吞。

  /** 打开某一行的长按菜单（`key` = 行身份，`copyPath` = 该项要复制的完整远程路径）。 */
  private openRowMenu(key: string, copyPath: string): void {
    this.menuRowKey = key;
    this.menuCopyPath = copyPath;
  }

  /** 关闭行长按菜单（上游 `onDismissMenu`；单击行时也要先关）。 */
  private closeRowMenu(): void {
    if (this.menuRowKey.length > 0) {
      this.menuRowKey = '';
    }
  }

  /**
   * 菜单里「复制路径」的行为（上游 `FileActionMenu` 的 `onCopyPath`，`:1724-1728`）：
   * `clipboard.setText(copyPath)` → 触感 → **关菜单**。
   *
   * ⚠️ 差异·平台必需新增：上游复制**成功没有任何可见反馈**（菜单一关就完了），
   * 而鸿蒙 `pasteboard.setData` 会 reject —— 失败必须有可见反馈（见 `COPY_PATH_FAILED_HINT`）。
   * 本页面已有常驻轻提示条（`actionHint`），成功也一并回显 `files_copied_path`：
   * 与路径条那颗复制钮同构，而且**提示文本在 `dumpLayout` 里可读**，验收能回读。
   */
  private copyMenuPath(): void {
    const payload: CopyPayload = pathCopyPayload(this.menuCopyPath);
    this.closeRowMenu();
    if (!payload.enabled) {
      this.actionHint = payload.hint;
      return;
    }
    this.writeClipboard(payload.text, (ok: boolean) => {
      this.actionHint = ok ? payload.hint : COPY_PATH_FAILED_HINT;
    });
  }

  /** 行长按菜单的弹窗参数（对应上游那一个 `Popup`）。 */
  private rowMenuPopupOptions(): CustomPopupOptions {
    return {
      builder: () => {
        this.rowMenuCard();
      },
      placement: Placement.BottomLeft,
      targetSpace: FILE_MENU_GAP,
      offset: { x: FILE_MENU_OFFSET_X, y: 0 },
      enableArrow: false,
      autoCancel: true,
      // ⚠️ 全透明：上游 Compose 的 `Popup` 默认无遮罩，加 scrim 就是 F-5 那条差异。
      mask: { color: Color.Transparent },
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      shadow: { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 },
      width: FILE_MENU_WIDTH,
      radius: FILE_MENU_RADIUS,
      /**
       * R86：弹层**容器**改挂官方沉浸光感（`CustomPopupOptions.systemMaterial`）。
       *
       * · 官方依据：SDK `common.d.ts:14406`（`declare interface CustomPopupOptions` 的
       *  `systemMaterial?: SystemUiMaterial`，归属见 :13866）；`SystemUiMaterial` = `uiMaterial.Material`
       *  （`common.d.ts:16964`）。
       * · 生效范围判定：**`bindPopup` 属「弹窗类接口」**，按官方 OS 平台行为变更（仅对
       *  `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）在**页面内全部区域**生效 ——
       *  本菜单锚在滚动文件列表的行上，仍属生效范围（不是「页面正文里的普通容器」，见
       *  `坑 245`）。
       * · 关闭姿势：`dialogMaterial()` 在探针不可用（设备不支持 / 应用级 metadata 非 enable）时
       *  返回 `uiMaterial.Material.empty`（SDK 原文 = disable，`uiMaterial.d.ts:467-472`），
       *  **绝不传 `undefined`** —— 那个语义是「恢复组件默认材质」，与本页的"关"不同（`坑 256`）。
       */
      systemMaterial: dialogMaterial(),
      onStateChange: (e: AaPopupStateChange) => {
        // 点空白处 / 返回键关掉时，状态要跟着回落（否则这一行的菜单会「关不掉」）。
        if (!e.isVisible) {
          this.menuRowKey = '';
        }
      }
    };
  }

  /**
   * 菜单卡片本体（逐条复刻上游 `FileActionMenu`，锚文 `:1736-1775`）。
   *
   * ⚠️ 这里**没有**用工程内的 `AaMenuActionRow`：那个组件对应的是上游 `HomeProjectActionRow`
   * （**文案在左、图标在右**、行高 50），而本菜单是上游另一套 `FileActionMenu`
   * （**图标在左且在 32dp 圆底里、文案在右**、188×54、圆角 16）。两者镜像，套上去形态就对不上。
   * 弹窗**机制**仍然与首页/设备页同一套（`bindPopup` + 透明 mask + `onStateChange` 回落）。
   */
  @Builder
  rowMenuCard() {
    Row({ space: Space.M }) {
      Column() {
        AaIcon({ d: ICONS['copy'], iconSize: FILE_MENU_ICON_SIZE, color: ink() })
      }
      .width(FILE_MENU_ICON_BOX)
      .height(FILE_MENU_ICON_BOX)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(Radius.PILL)
      .backgroundColor(subtle())

      Text('复制路径')
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width(FILE_MENU_WIDTH)
    .height(FILE_MENU_HEIGHT)
    .padding({ left: Space.M, right: Space.M })
    .borderRadius(FILE_MENU_RADIUS)
    // R86：本节点是 `bindPopup` 的**内容根**（材质挂在容器上，见 `rowMenuPopupOptions()`），
    // 而弹层容器本身全透明（`popupColor` 送 `Color.Transparent`，不上任何容器底）⇒「底」只有这一个来源，故按
    // `immersiveMaterialEnabled()` **门控**（与 R85 `Components#customDialogGeometry()` 同构）：
    //  · 材质可用 ⇒ 透明底 + 0 描边 ⇒ 本节点**零自绘层**，官方材质接管 background / border /
    //  shadow / blur（SDK `common.d.ts:22625-22633`；契约 §1.2 / §1.8，A/B 可归因性不受损）；
    //  · 材质不可用（设备不支持 / 探针 false / 未来关档）⇒ **逐字回到 R86 前**的
    //  `raisedSurface()` 不透明底 + 1vp 描边 ⇒ 菜单不会变成「文字浮在列表上」的空壳。
    //  几何（宽高 / 圆角 / 内边距 / 子节点）一个字未动（契约 §1.4）。
    // ⚠️ 回退：删掉 `rowMenuPopupOptions()` 里的 `systemMaterial:` 行即回到 R86 前行为（门控的
    //  不可用分支与 R86 前逐字一致）；彻底回退 = `%TEMP%/aa-hm-r86-before/FilesScreen.ets`（契约 §6）。
    .backgroundColor(immersiveMaterialEnabled() ? Color.Transparent : raisedSurface())
    .borderWidth(immersiveMaterialEnabled() ? 0 : StrokeWidth.HAIRLINE)
    .borderColor(immersiveMaterialEnabled() ? Color.Transparent : borderColor())
    .onClick(() => {
      this.copyMenuPath();
    })
  }

  /** 一行要复制的完整远程路径（上游 `FileListRow(copyPath = displayRemotePath(...))`）。 */
  private entryCopyPath(rawPath: string): string {
    return displayRemotePath(
      this.store.root, rawPath, this.store.deviceOs, WINDOWS_DRIVE_OVERVIEW_LABEL);
  }

  /**
   * 预览面板：复制当前预览的文本内容。
   *
   * 与上游一致：可复制条件是 `!binary && 内容非空白`；内容**照抄预览原文、不二次截断**
   * （上游就是 `clipboard.setText(preview.content)`，超大文件的截断发生在服务端，
   * 预览卡片已用「已截断」标签标出，这里再把它写进成功提示）。
   */
  private copyPreviewCode(): void {
    const file = this.previewFile;
    if (file === undefined) {
      // 按钮本身在 file 为空时是置灰的（`interactive: this.previewFile !== undefined`），
      // 这里不编文案，避免出现上游没有的提示语。
      this.previewHint = '';
      return;
    }
    const payload: CopyPayload = codeCopyPayload(file.content, file.binary, file.truncated);
    if (!payload.enabled) {
      this.previewHint = payload.hint;
      return;
    }
    this.writeClipboard(payload.text, (ok: boolean) => {
      // 失败提示同上：差异·平台必需新增（上游无对应 key，见 FileSearch.COPY_CODE_FAILED_HINT）。
      this.previewHint = ok ? payload.hint : COPY_CODE_FAILED_HINT;
      this.flashCopied(ok ? PREVIEW_CODE_KEY : '');
    });
  }

  /** 上游 `copyEnabled`：非二进制且内容非空白（不满足时按钮置灰）。 */
  private copyEnabled(): boolean {
    const file = this.previewFile;
    return file !== undefined && !file.binary && file.content.trim().length > 0;
  }

  /** 当前预览是否是二进制（上游二进制文件不给搜索入口）。 */
  private previewBinary(): boolean {
    const file = this.previewFile;
    return file !== undefined && file.binary;
  }

  // -------------------------------------------------------------------------
  // 预览面板内的内容搜索（上游 InlineFileSearchControls + SoraFileSearchController）
  // -------------------------------------------------------------------------

  /** 打开 / 收起「在文件中搜索」。 */
  private togglePreviewSearch(): void {
    this.previewSearchOpen = !this.previewSearchOpen;
    if (this.previewSearchOpen) {
      this.runPreviewSearch();
    } else {
      this.previewHint = '';
    }
  }

  /** 关键字变化后重算命中（判定在 model/FileSearch.findMatches）。 */
  private runPreviewSearch(): void {
    const file = this.previewFile;
    if (file === undefined || file.binary) {
      this.previewMatches = [];
      this.previewMatchTotal = 0;
      this.previewMatchCurrent = 0;
      return;
    }
    // 大小写策略是 findMatches 的入参（不写死在对内）：这里取手机端更常用的「不区分大小写」。
    // 上游 `SearchOptions(true, false)` 里那个 boolean 的语义在随包源码里查不到
    // （sora-editor 的 `EditorSearcher.SearchOptions` 不在本仓），故按可用性取更宽松的一档。
    const matches = findMatches(file.content, this.previewQuery, false, MATCH_LIST_LIMIT);
    this.previewMatches = matches.slice();
    this.previewMatchTotal = matches.length;
    this.previewMatchCurrent = matches.length > 0 ? 1 : 0;
  }

  /** 上一条 / 下一条（上游 `setCyclicJumping(true)`：到头绕回）。 */
  private stepPreviewMatch(forward: boolean): void {
    if (this.previewMatchTotal <= 0) {
      return;
    }
    this.previewMatchCurrent = stepSearchMatch(this.previewMatchCurrent, this.previewMatchTotal, forward);
  }

  /** 点命中列表某一行：把它设为当前命中（`index` 是 0 基，与 `current - 1` 对齐）。 */
  private selectPreviewMatch(index: number): void {
    const result: FileSearchResult = searchResultOf(index + 1, this.previewMatchTotal);
    this.previewMatchCurrent = result.current;
  }

  /** 「当前/总数」（与上游 InlineFileSearchControls 同形）。 */
  private previewMatchLabel(): string {
    const result: FileSearchResult = searchResultOf(this.previewMatchCurrent, this.previewMatchTotal);
    return searchCountLabel(result);
  }

  /**
   * 某条命中是否是「当前命中」。
   *
   * ⚠️ 这是 `@State` 标记：**只在行内判，绝不进 ForEach 的 key**（坑 152）：
   * `@State` 被 build 读到就登记元素级依赖，塞进 key 反而每次变化都重跑整轮 key 生成。
   */
  private isCurrentMatch(match: FileMatch): boolean {
    return match.index === this.previewMatchCurrent - 1;
  }

  /** 命中列表高度：按条数撑开，最多 MATCH_LIST_ROWS 行（列表必须有确定高度，见坑 141）。 */
  private matchListHeight(): number {
    const rows = this.previewMatches.length < MATCH_LIST_ROWS
      ? this.previewMatches.length : MATCH_LIST_ROWS;
    return rows * MATCH_ROW_HEIGHT;
  }

  build() {
    // 根 Stack：主内容 + 设备下拉浮层（与终端页同构）。
    Stack({ alignContent: Alignment.TopStart }) {
      // R65-B（设计规格 §2）：正文包进 `Navigation`，顶栏改作它的**标题栏**（`this.navTitleBar()`）。
      //
      // ⚠️ 用缺省的 `BarStyle.STANDARD`（标题栏布局在内容**上方**、占自己一行）而不是 `STACK`：
      //  STACK 会把它**叠在内容上**，那就得自己给内容让位（`contentStartOffset` 那套），而
      //  设计规格 §2 明写「内容区的滚动让位/安全区由框架接管，原来手写的那套不能照搬」。
      //
      // ⚠️ 设备下拉浮层仍是本 Stack 的**后一个兄弟**（见下方 `deviceMenuLayer()`）：它的
      //  `.position({ x: MENU_LEFT, y: MENU_TOP })` 以**页面根**为原点 ——
      //  而 R65-B 起标题栏已经**不在页面根的最顶上**了（它在框架标题栏里，行顶边在 `NAV_TITLE_ROW_TOP`
      //  = 56vp 处）⇒ 这个锚点常量**必须**把那一项算进去，见 `MENU_TOP` 的注释（R81 收口）。
      Navigation() {
        Column() {
          // ⚠️ **顶栏与「列表 ↔ 预览」二选一的分工不变**（上游 `FilesScreen.kt:76-107`：`Column { FilesHeader(…) ; … }`，
          //  二选一发生在 `DeviceFilesContent` **内部**，锚文 `SessionAgentFilesScreen.kt:302-326`）。
          //  R65-B 后顶栏在**框架标题栏**里 ⇒ 比原来更靠外，预览态下它照样在（R69 修过的「预览把顶栏
          //  整条吞掉」不会复发，并排图 `../r16-side-by-side/20-file-preview.png`）。
          this.actionHintBar()
          // 预览态 = **内容区替换**（不是整页替换，也不是 bottom sheet）。
          // 返回键行为由 `backConsumer` 兜住（否则会直接退出文件页）。
          if (this.previewOpen) {
            this.previewSheet()
          } else {
            this.pathBar()
            AaErrorBanner({
              message: this.errorText,
              onRetry: () => {
                this.store.refresh();
              },
              onDismiss: () => {
                this.store.error = '';
                this.errorText = '';
              }
            })
            if (this.devices.length === 0) {
              // 上游：`devices.isEmpty()` → AppEmptyState(files_pair_first, 配对新设备)
              this.emptyState('先配对一台设备，再浏览文件。', '配对新设备')
            } else if (this.selectedDevice() === undefined) {
              // 上游：有设备但一台都不在线 → EmptyFilesMessage(files_all_devices_offline)
              this.emptyMessage('先让一台设备上线，再浏览文件。')
            } else {
              this.fileBrowser()
            }
          }

        // R66-3：底栏**已上移到 `pages/Index.ets` 的浮层**，本页不再挂 `AaBottomNav`。
        // 浮层不占布局 ⇒ 文件列表末行必须自己留出底栏那一条（用 `contentEndOffset`，
        // **不是**容器 `padding` —— R37 的教训：List 的 padding 会压掉可视区、末行永远滚不出来）。
        // 见 `fileBrowser()` 里 List 末尾的 `.contentEndOffset(BOTTOM_BAR_RESERVED_VP)`。
        }
        .width('100%')
        .height('100%')
      }
      // 标题栏 = 顶栏一行；底色**透明**，让标题栏自己的**官方材质**（`navTitleBar()` 的 `systemMaterial`）透出页面底色。
      .title(this.navTitleBar(), { backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      // ## R66-1 修正（两轮真机证据 + SDK 逐行核对才定下来）：**必须显式 Full**。
      // · 缺省 ≠ Full：SDK `titleMode` 原文 **Default value: NavigationTitleMode.Free**；R66 SPEC 里
      //  「缺省是 Full」是误判。**Free** 的主标题**随内容滚动收起 / 改变位置**（SDK :224-243）
      //  ⇒ 真机就是用户截图的「顶栏整条消失、状态栏后面留残影」（缺陷 ① 的真因，不是 Full）。
      // · **Mini**（R66-1 第一版）确实钉住了，但真机 dump + 截图实测：它的 56vp **从窗口顶 y=0 起算**
      //  ⇒ 标题栏落在 y≈30..128px，与状态栏带（0..136px 的时钟/信号/电池）**重叠**；框架里的
      //  `TitleBar` 可见部分只剩 `[0,137][1316,166]`（29px），且 56vp < 本页栏高 ⇒ 栏被钳、按钮被压扁。
      //  **Mini / Free 两档都不合用**（⛔ 别再改回 Mini，已证伪）。
      // · **Full**：SDK 原文「The title is **fixed** at full mode」、标题栏高 **112vp**（:244-255）；本工程
      //  R62/R65 真机实测（未加 titleMode 的 Free 静止态 = Full）为 `TitleBar [0,137][1316,332]`
      //  ⇒ 栏内容落在 **46..112vp（状态栏之下）**，正是 R65 那版被验收过的几何，且 112vp 容得下本页栏高。
      //  ⇒ **Full = 常驻钉住 + 落在状态栏之下**，不需要任何安全区补丁（**不再叠任何安全区 API / padding**）。
      .titleMode(NavigationTitleMode.Full)
      .hideToolBar(true)
      .width('100%')
      .height('100%')
      // ⚠️ 设备浮层挂在**顶栏之外**（挂在 Column 里会被顶栏挤下去）。
      if (this.deviceMenuOpen) {
        this.deviceMenuLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(canvas())
  }

  /**
   * **R65-B：本页标题栏** —— `Navigation.title(...)` 的自定义构造器（原 `header()`）。
   * 除返回钮改成共用玻璃钮（见下）外，其余元素逐字未动。
   *
   * 顶栏（与终端页逐字同构；复刻上游 `FilesHeader`，`FilesScreen.kt:129-195`）：
   * 行高 64dp、水平内边距 18dp；左侧 40dp 圆形返回钮（raisedSurface 底 + 1dp 描边）；
   * 中间 44dp 圆角条（圆角 14dp、设备名 16sp SemiBold、右侧 19dp ChevronDown），点开只列在线设备。
   *
   * R13-20 起与上游**逐元素同构**（不再多一个「上一级」按钮）：
   * 返回钮调 `Router.back()` —— 上游 `FilesScreen.kt:68/86` 的返回目标硬编码是 Sessions（首页）。
   *
   * ⚠️ 必须**只**在 `.title(...)` 里挂载。官方沉浸光感自 HarmonyOS 7 起有**生效范围约束**：其他
   * 组件只在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 的底部 TabBar（`barPosition =
   * BarPosition.End`）中生效，**页面正文里静默无效**（`坑 245`、设计规格 §1）。
   *
   * ⚠️ R65-B 同时**删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）：R37 的「顶栏
   * 背景铺到屏幕顶」在顶栏进 `Navigation` 标题栏后已由**框架**接管 —— 真机 `dumpLayout` 实测
   * 标题栏落在 `[0,137][1316,332]`（`HomeScreen` R62 的实测记录），页面根节点**已经在状态栏
   * 之下**，顶栏再避让一次就是**重复避让 137px**；而且原值是 `AppStorage.get` 的**非响应**读取、
   * 会随冷启动时序在 `0 / 46vp` 之间跳（R61 实测同一份包两次冷启动顶栏行高 136px / 274px）。
   * ⇒ 与首页（R62）同一口径：固定**不避让**。
   */
  @Builder
  navTitleBar() {
    Row({ space: Space.M }) {
      // R65-B：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内
      //（`坑 245`）。返回钮由「自绘 Column + `raisedSurface` 圆盘」改成**共用的
      // 玻璃钮**（`AaCircleIconButton` 的玻璃档统一委托 `ui/GlassIcon.ets`，与首页/设备页/终端页同源），
      // 并开官方材质（官方分支零自绘层：无 backgroundEffect / 渐变 / 描边）；几何按原值 40vp / 22vp 不变。
      AaCircleIconButton({
        name: 'chevron-left',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_XL,
        tint: ink(),
        surface: raisedSurface(),
        ringColor: borderColor(),
        glass: true,
        officialMaterial: true,
        accessibilityLabel: '返回',
        onTap: () => {
          Router.back();
        }
      })

      Row({ space: Space.S }) {
        Text(this.selectedDeviceLabel())
          .fontSize(FontSize.ROW_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        AaIcon({ d: ICONS['chevron-down'], iconSize: FontSize.CHEVRON, color: faint() })
      }
      .layoutWeight(1)
      .height(Control.FIELD)
      .padding({ left: Radius.M_PLUS, right: Radius.M_PLUS })
      .borderRadius(Radius.M_PLUS)
      // ## R66（SPEC §2，真机缺陷 ②）：设备选择条原来是**自绘底 + 1vp 描边**
      //  （`backgroundColor(raisedSurface())` + `borderWidth`/`borderColor`），现整段删除，改由官方
      //  `ImmersiveMaterial` 接管（口径 = **零自绘层**，同 `GlassIcon.ets#officialGlass()`）。
      // ⚠️ 几何逐字不变：`layoutWeight(1)` / `height(Control.FIELD)` / `padding` / `borderRadius(Radius.M_PLUS)`
      //  与内部 `Text`(16sp Medium) / `AaIcon`(chevron-down) 全是原值 —— 只换「谁在画底与边」。
      // ⚠️ `materialColor` 取**既有的半透明令牌** `glassCardSurface()`（base/dark 都 alpha ≈ 70%，
      //  与原来那层实底 `raisedSurface()` 观感同档；官方要求完全 opaque 会挡死滤镜）。不新造资源键。
      // ⚠️ 生效范围：本胶囊在 `Navigation.title(...)` 的构造器里 ⇒ 命中官方允许的位置
      // （`坑 245`、SPEC §2）；正文里的胶囊**不许**照抄这一段。
      .systemMaterial(officialBarMaterial(glassCardSurface()))
      .onClick(() => {
        if (!this.hasOnlineDevice()) {
          return;
        }
        this.deviceMenuOpen = !this.deviceMenuOpen;
      })

      // ⚠️ R13-20：这里**不再有**「上一级」常驻按钮。
      // 上游 `FilesHeader`（`FilesScreen.kt:129-195`）只有「圆形返回钮 + 设备药丸」两个元素；
      // 「上一级」在上游是**目录列表首项的 `..` 行**（`SessionAgentFilesScreen.kt:920-942`），
      // 本页已按那个形态归位（见 `fileBrowser()` 的首项）。不是删能力，是换形态。
    }
    .width('100%')
    // ## R81（标题栏口径全工程统一）：行高 = `Control.NAV_TITLE_ROW`(46)。
    // 真机实测：`titleMode: Full` 时框架把构造器**顶边锚在 y=166px（与行高无关）**
    // ⇒ 栏内控件垂直中心 = 166 + 行高/2：46vp → **235px**（与首页同一条线），64vp → 262px（低 27px）。
    // ⚠️ 同时保留 R65 的口径：栏高**不再** `+ this.topInset()` —— 状态栏避让由框架接管。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .alignItems(VerticalAlign.Center)
    // ## R87（用户：「不要让标题栏和时间栏有明显分界线，改成首页这样就好」）：**栏本体撤回零材质**
    // （真机深色读数见 开发期验证记录：栏底色 28.7 vs 正文 9.67
    //  ⇒ 一条比正文亮 +19.0 的带；首页同口径 +0.00）。**光效只留在栏内控件（返回钮、设备选择条）上。**
    //  ⚠️ 历史：R66 曾把整条栏改官方材质（本行那时是 `.systemMaterial(officialBarMaterial(glassSurface()))`），
    //  R87 因「有明显分界」撤回；同源坑 `坑 250`。
    //  ⚠️ 也不加 `scrollEffectOptions`（STANDARD 布局无可糊内容 + R77 实测的 `TitleBarMaskBlur` 越界洗淡，`坑 249`）。
  }

  /**
   * 列表页轻提示条（复制路径的成功 / 失败）。
   *
   * 形状与 `SessionDetailScreen` 的 `actionHint` 提示条一致：**常驻 + 可手关**。
   * 常驻是刻意的 —— 自动消失的 toast 在 `dumpLayout` 里抓不稳，验收就没有判据。
   */
  @Builder
  actionHintBar() {
    if (this.actionHint.length > 0) {
      Row({ space: Space.S }) {
        Text(this.actionHint)
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        AaIcon({ d: ICONS['x'], iconSize: FontSize.TITLE, color: muted() })
          .padding({ left: Space.S, right: Space.S })
          .onClick(() => {
            this.actionHint = '';
          })
      }
      .width('100%')
      .padding({ left: Space.M, right: Space.S, top: Space.S, bottom: Space.S })
      .backgroundColor(raisedSurface())
    }
  }

  /**
   * 路径条（灰底圆角块 + 复制按钮）—— 对应上游 PathBar
   * （锚文 SessionAgentFilesScreen.kt:1504-1575：52dp 高、13dp 圆角、1.2dp 描边、
   * 左块单行 15sp ExtraBold、右侧 52dp 方块放 Lucide.Copy，复制成功切 Lucide.Check
   * 并 delay(1100) 复位）。
   *
   * 与上游的**唯一形态差异**：块内的路径是**可点的面包屑分段**（本页既有能力，不因复刻而回归），
   * 上游是一整条不可点的字符串。盘符总览态只有一节，因此那一态与安卓逐像素同形
   * （安卓 android-04-files.jpeg：灰底块「这台电脑」+ 右侧复制方块）。
   */
  @Builder
  pathBar() {
    Row({ space: Space.S }) {
      // ⚠️ R13-20（3-4 左对齐）：这里**不能再套 `Scroll`**。
      // 改前是 `Scroll(){ Row(){…} }`，并排图上「这台电脑」显示在灰块**正中**，而安卓是**左对齐**
      // （锚文 `PathBar`：`SessionAgentFilesScreen.kt:1525-1544` —— 左块是 `Box(`
      // `contentAlignment = Alignment.CenterStart)`，里面的 `Text` 单行 + `MiddleEllipsis`）。
      // ⚠️ R14 更正：当时写的「ArkUI 的 `Scroll` 没有 `align` 属性」是**错的** ——
      // `align` 是**通用属性**（`common.d.ts`，默认 `Alignment.Center`），横向 Scroll 用
      // `Alignment.Start` 就是左对齐。真正的坑是「不写就被居中」，而不是「没有这个属性」。
      // 结论（去掉 `Scroll`、用普通 `Row` + `justifyContent(Start)`）仍然成立、也不改回：
      // 上游这里本来就是单行 `MiddleEllipsis`、不横向滚动，去掉多余滚动层更贴近上游。
      // 代价：超长路径不再能横向滚动，会被右侧裁掉（与上游同形）。
      Row({ space: Space.S }) {
        ForEach(this.crumbs, (segment: BreadcrumbSegment, index: number) => {
          Text(segment.label)
            .fontSize(FontSize.BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(ink())
            .maxLines(1)
            .onClick(() => {
              this.store.navigate(segment.path);
            })
          // 末节后面不补分隔符：盘符总览就只有「这台电脑」四个字（与安卓一致）。
          if (index < this.crumbs.length - 1) {
            Text('/').fontSize(FontSize.SMALL).fontColor(faint())
          }
        }, (segment: BreadcrumbSegment) => segment.path)
      }
      .justifyContent(FlexAlign.Start)
      .layoutWeight(1)
      .height(PATH_BAR_HEIGHT)
      .clip(true)
      .padding({ left: Space.M, right: Space.M })
      .borderRadius(PATH_BAR_RADIUS)
      .backgroundColor(subtle())
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(borderColor())

      Column() {
        AaIcon({
          d: this.copiedKey === PATH_BAR_COPY_KEY ? ICONS['check'] : ICONS['copy'],
          iconSize: FontSize.ICON,
          color: this.copiedKey === PATH_BAR_COPY_KEY ? primaryAction() : ink()
        })
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width(PATH_BAR_HEIGHT)
      .height(PATH_BAR_HEIGHT)
      .borderRadius(PATH_BAR_RADIUS)
      .backgroundColor(subtle())
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(borderColor())
      .onClick(() => {
        this.copyCurrentPath();
      })
    }
    .width('100%')
    .padding({ left: Space.PAGE, right: Space.PAGE, bottom: Space.S })
  }

  /**
   * 空目录提示。**逐字**取上游 `files_empty_directory`（「这个目录是空的。」）。
   *
   * 上游 `FilesMessage`（锚文 `SessionAgentFilesScreen.kt:1777-1789`）：13sp SemiBold、
   * 浅色 #777777、`padding(horizontal = 8.dp, vertical = 16.dp)` —— 本页 `FontSize.SMALL`/`muted()`
   * 与 `Space.S`/`Space.L` 正好是这几个值。
   */
  @Builder
  emptyDirectoryLine() {
    Text('这个目录是空的。')
      .fontSize(FontSize.SMALL)
      .fontWeight(FontWeight.Medium)
      .fontColor(muted())
      .width('100%')
      .padding({ left: Space.S, right: Space.S, top: Space.L, bottom: Space.L })
  }

  /**
   * 列表首项 `..`（对应上游 `FolderRow(name = "..")`，锚文 `SessionAgentFilesScreen.kt:920-942`）。
   *
   * ⚠️ `this.parentPath` **可能是空串** —— 那是「上一级 = 盘符总览『这台电脑』」这个**真实目标**
   * （Windows 盘符根 `C:` 的上一级），必须照样能点；「没有上一级」由 `this.hasParent` 表达。
   */
  @Builder
  parentRow() {
    Row({ space: Space.M }) {
      Column() {
        AaIcon({ d: ICONS['folder'], iconSize: 22, color: filesRowIcon() })
      }
      .width(FILE_ROW_ICON_BOX)
      .height(FILE_ROW_ICON_BOX)
      .borderRadius(Radius.M)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      Text('..')
        .fontSize(FontSize.BODY)
        .lineHeight(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(filesRowText())
        .layoutWeight(1)
        .maxLines(1)
      AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.ICON, color: filesRowChevron() })
    }
    .width('100%')
    .height(FILE_ROW_HEIGHT)
    .padding({ left: FILE_ROW_PAD_H, right: FILE_ROW_PAD_H })
    .borderRadius(Radius.L)
    // R20：上游 `FileListRow` 的底色是 `pressedSurface.copy(alpha = surfaceAlpha)`，
    // `surfaceAlpha = if (active) 1f else 0f`（`SessionAgentFilesScreen.kt:1652-1672`）
    // ⇒ **静止态透明**。此处原为常驻 `raisedSurface()`（深色下就是一张灰卡），已改为只在按下时着色。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.closeRowMenu();
      this.store.navigate(this.parentPath);
    })
    // `..` 行也带同一个菜单（上游 `:926-941` 的 `FolderRow(name = "..", onOpenMenu = ...)`）。
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.openRowMenu(PARENT_ROW_KEY, this.entryCopyPath(this.parentPath));
        })
    )
    .bindPopup(this.menuRowKey === PARENT_ROW_KEY, this.rowMenuPopupOptions())
  }

  @Builder
  entryRow(entry: RemoteDirectoryEntry) {
    Row({ space: Space.M }) {
      // 上游 `FileListRow`（`SessionAgentFilesScreen.kt:1695-1703`）：40dp 圆角 12 的图标槽，内嵌 22dp 图标。
      Column() {
        AaIcon({
          d: entry.type === 'directory' ? ICONS['folder'] : ICONS['file-text'],
          iconSize: 22,
          color: filesRowIcon()
        })
      }
      .width(FILE_ROW_ICON_BOX)
      .height(FILE_ROW_ICON_BOX)
      .borderRadius(Radius.M)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      Text(entry.name)
        .fontSize(FontSize.BODY)
        .lineHeight(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(filesRowText())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // R26：**删掉了文件大小副标题** —— 上游 `FileRow`（`:1608-1629`）只传 `name / icon / trailing = null`，
      // `FileEntry.size` 在**文件列表里从不渲染**（全仓 `formatBytes` 只服务附件与更新进度）。
      // 安卓基线上也没有任何一张拍到「带大小的文件行」，删掉不损失可对照的信息。
      // R13-20（3-3）：行内那个常驻「⧉」复制钮**已删** —— 上游每行只有 `trailing`：
      // `FolderRow` 给 `Lucide.ChevronRight`（`SessionAgentFilesScreen.kt:1595-1602`），
      // `FileRow` 的 `trailing = null`（`:1626`）。并排图上安卓那三行也确实只有 `›`。
      // 复制路径在上游是**长按弹的行菜单**（`:1686-1689` → `FileActionMenu`），本工程未移植。
      if (entry.type === 'directory') {
        AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.ICON, color: muted() })
      }
    }
    .width('100%')
    .height(FILE_ROW_HEIGHT)
    .padding({ left: FILE_ROW_PAD_H, right: FILE_ROW_PAD_H })
    .borderRadius(Radius.L)
    // R20：见 `parentRow()` 同一处注释 —— 上游 `FileListRow` 静止态透明，只在按下时给底色。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      // 上游 `:1677`：单击里也先 `onDismissMenu()` —— 菜单开着时点行 = 关菜单 + 走单击。
      this.closeRowMenu();
      if (entry.type === 'directory') {
        this.store.navigate(entry.path);
      } else if (isTextPreviewable(entry.name)) {
        // 换文件先把上一份的搜索 / 提示状态清干净，否则会看到上一个文件的关键字与命中数。
        this.resetPreviewSearch();
        this.previewOpen = true;
        this.store.openPreview(entry.path);
      } else {
        this.store.error = '这个文件类型暂不支持预览。';
        this.pull();
      }
    })
    // 长按弹「复制路径」菜单（上游 `:1686-1689` 的 `onLongClick`）。
    // ⚠️ 与 `.onClick` 共存是**照抄 `HomeScreen.ets:1078/1081`** 那份已在用的实现：
    // `LongPressGesture` 只接管长按，单击仍走上面的 `onClick`，不会互相吞。
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.openRowMenu(entry.path, this.entryCopyPath(entry.path));
        })
    )
    // ⚠️ 弹窗挂在**行自身**上（锚点就是这一行）：条件用「key 相等」表达，
    // 全列表同一时刻只有一行为真 ⇒ 不会「一开弹多个」（坑 137 说的是多个弹层共用一个节点）。
    .bindPopup(this.menuRowKey === entry.path, this.rowMenuPopupOptions())
  }

  /**
   * 文件浏览主体（对应上游 `FileListContent`，锚文 `SessionAgentFilesScreen.kt:882-979`）。
   *
   * 上游这一块只有三样东西：`PathBar`（本页放在 `build()` 里）+ `LazyColumn`（首项可选的 `..`
   * + 目录条目 + 尾留白 24dp）+ 空态 `FilesMessage`。
   *
   * R13-20 删掉的两样（本工程自加的常驻入口，上游没有）：
   *  · 文件名过滤输入框 + 清空钮 —— 上游列表里没有输入框，`Lucide.Search` 只在**文件预览**里
   *  （`:1192` 预览头的 `files_search_in_file`、`:1256` 预览内联搜索框）；
   *  · 「显示点文件」开关 —— 上游无此 key，全仓 Kotlin 零 dotfile 过滤。
   */
  @Builder
  fileBrowser() {
    Column() {
      if (this.loadingFlag && this.entryList.length === 0) {
        Column() {
          LoadingProgress().width(28).height(28).color(muted())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: FILE_ROW_GAP }) {
          // 空目录提示：上游是列表**首项**一句 `FilesMessage(files_empty_directory)`（`:918`），
          // 与下面的 `..` 行可以同时出现（空目录也能往上走），所以它属于列表内容、不是整页空态。
          if (this.entryList.length === 0) {
            ListItem() {
              this.emptyDirectoryLine()
            }
          }
          // 首项 `..`（上游 `:920-942`：`if (parent != null) item("..") { FolderRow(name = "..", ...) }`）。
          if (this.hasParent) {
            ListItem() {
              this.parentRow()
            }
          }
          ForEach(this.entryList, (entry: RemoteDirectoryEntry) => {
            ListItem() {
              this.entryRow(entry)
            }
          }, (entry: RemoteDirectoryEntry) => `${entry.path}:${entry.type}:${entry.size}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Space.L, right: Space.L, bottom: Space.L })
        // ⚠️ R66-3：尾部**内容**留白 = 浮层底栏那一条（`contentEndOffset` 只加内容末尾偏移、
        //  不动可视区 ⇒ 末行能完整滚到胶囊上方；用 `padding` 会把它硬裁在留白外，R37 真机踩过）。
        .contentEndOffset(BOTTOM_BAR_RESERVED_VP)
        .scrollBar(BarState.Off)
      }

      if (this.truncatedFlag) {
        Text('目录内容过多，仅显示前一部分。')
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .padding(Space.S)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 无设备空态（复刻上游 `AppEmptyState`：插图 + 16sp 文案 + 44dp 主按钮）。
   *
   * 已知差异：本工程没有空态插图位图（上游是 188×156 的 `ic_sessions_empty`），用字符近似；
   * 按钮自绘 44dp 胶囊（工程既有 `AaPrimaryButton` 是 46dp）。
   */
  @Builder
  emptyState(message: string, buttonLabel: string) {
    Column({ space: Space.L }) {
      AaIcon({ d: ICONS['folder'], iconSize: EMPTY_ILLUSTRATION_SIZE, color: ink() })
      Text(message)
        .fontSize(FontSize.ROW_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: 294 })
        .padding({ left: Space.EMPTY_TEXT, right: Space.EMPTY_TEXT })
      Row({ space: Space.S }) {
        AaIcon({ d: ICONS['monitor'], iconSize: FontSize.BUTTON_ICON, color: onPrimaryAction() })
        Text(buttonLabel)
          .fontSize(FontSize.BODY_SMALL)
          .fontWeight(FontWeight.Bold)
          .fontColor(onPrimaryAction())
      }
      .height(Control.FIELD)
      .padding({ left: Space.PAGE, right: Space.PAGE })
      .borderRadius(Radius.PILL)
      .backgroundColor(primaryAction())
      .onClick(() => {
        // 上游 `onPairDevice` → DeviceSetup（配对页）
        Router.push(Route.ADD_DEVICE);
      })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 有设备但一台都不在线（复刻上游 `EmptyFilesMessage`：14sp、居中、水平 34dp 内边距）。 */
  @Builder
  emptyMessage(text: string) {
    Column() {
      Text(text)
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(inkSoft())
        .textAlign(TextAlign.Center)
        .padding({ left: Space.EMPTY_TEXT, right: Space.EMPTY_TEXT })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 设备下拉浮层：全屏透明遮罩（点它关闭）+ 菜单卡片（与终端页逐字同构）。 */
  @Builder
  deviceMenuLayer() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.deviceMenuOpen = false;
      })
    this.deviceMenuCard()
  }

  /** 下拉卡片（对应上游 `AADropdownMenu` + `DevicePickerMenu`：只列在线设备、选中项打勾）。 */
  @Builder
  deviceMenuCard() {
    Scroll() {
      Column() {
        ForEach(onlineDevices(this.devices), (device: AgentDevice) => {
          Row({ space: Space.M }) {
            Text(device.name)
              .fontSize(FontSize.BODY_SMALL)
              .fontWeight(FontWeight.Medium)
              .fontColor(ink())
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (device.id === this.selectedDeviceIdOrEmpty()) {
              AaIcon({ d: ICONS['check'], iconSize: FontSize.ICON, color: ink() })
            } else {
              Text('')
                .fontSize(FontSize.ICON)
                .width(FontSize.ICON)
            }
          }
          .width('100%')
          .height(Control.MENU_ITEM_MIN)
          .padding({ left: Space.L, right: Space.L })
          .onClick(() => {
            this.selectedDeviceId = device.id;
            this.deviceMenuOpen = false;
            // 换设备 = 换根：顶层入口下 root/initialPath 是 '.'（设备默认根）
            this.openSelected();
          })
        }, (device: AgentDevice) => device.id)
      }
      .width('100%')
    }
    .width(Control.MENU_WIDTH)
    .constraintSize({ maxHeight: Control.MENU_MAX_HEIGHT })
    .scrollBar(BarState.Auto)
    .align(Alignment.Top)
    .borderRadius(Radius.XL)
    .backgroundColor(raisedSurface())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
    .position({ x: MENU_LEFT, y: MENU_TOP })
  }

  /**
   * 关闭预览并回收状态。
   *
   * 这三行原本写在 `bindSheet` 的 `onDisappear` 里（下滑手势 / 点遮罩都会走它）；
   * R14 改成**同页替换**后没有 sheet 生命周期了，改由「关闭」按钮与返回键共同调用本方法 ——
   * 否则 store（单例）里的 `preview` 会留着，下次进文件页先闪出上一个文件的内容。
   */
  private closePreview(): void {
    this.previewOpen = false;
    this.resetPreviewSearch();
    this.store.closePreview();
  }

  /**
   * 预览页顶部的路径面包屑（上游 `SessionAgentFilesScreen.kt:1035-1076` 的 `PreviewBreadcrumb`）。
   *
   * 上游 `FilePreviewContent:1000-1015` 的第一行就是它：左胶囊「‹ 文件」（点它回文件列表），
   * 中间 `/`，右侧**完整路径**（`displayRemotePath(root, file.path, deviceOs)`、等宽字体、单行省略）。
   * 本工程原本只有「文件名 + 关闭」，缺这一行 —— R12 D-27 的残留项，本轮补齐。
   *
   * 颜色走双值资源（`files_preview_chip_text` / `files_preview_slash` / `files_preview_path`），
   * 取值与上游 `PreviewBreadcrumb` 里的 `Color(0xFF…)` 逐一对应 ⇒ 运行时切主题能自动重取色。
   */
  @Builder
  previewBreadcrumb() {
    Row({ space: PREVIEW_CRUMB_GAP }) {
      Row({ space: PREVIEW_CRUMB_CHIP_GAP }) {
        AaIcon({
          d: ICONS['chevron-left'],
          iconSize: PREVIEW_CRUMB_ICON,
          color: $r('app.color.files_preview_chip_text')
        })
        Text('文件')
          .fontSize(FontSize.CAPTION)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.files_preview_chip_text'))
      }
      .height(PREVIEW_CRUMB_CHIP_H)
      .padding({ left: PREVIEW_CRUMB_CHIP_PAD, right: PREVIEW_CRUMB_CHIP_PAD })
      .borderRadius(Radius.PILL)
      .backgroundColor(subtle())
      .onClick(() => {
        this.closePreview();
      })

      Text('/')
        .fontSize(FontSize.CAPTION)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.files_preview_slash'))

      Text(this.previewRemotePath())
        .fontSize(FontSize.CAPTION)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.files_preview_path'))
        .fontFamily('Noto Sans Mono')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(PREVIEW_CRUMB_ROW_H)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 预览头部的「在文件中搜索」按钮（上游 `PreviewIconButton(icon = Lucide.Search)`，`:1191-1199`）。
   * 不可用时置 α0.38 且点不动（上游 `enabled = false` 时分派的是 `Modifier` 而不是 `clickable`）。
   */
  @Builder
  previewSearchButton() {
    Column() {
      AaIcon({ d: ICONS['search'], iconSize: PREVIEW_ICON_BTN_ICON, color: $r('app.color.preview_button_icon') })
    }
    .width(PREVIEW_ICON_BTN)
    .height(PREVIEW_ICON_BTN)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(PREVIEW_ICON_BTN_RADIUS)
    .backgroundColor($r('app.color.preview_button_surface'))
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor($r('app.color.preview_button_ring'))
    .opacity(this.previewSearchEnabled() ? 1 : 0.38)
    .onClick(() => {
      if (this.previewSearchEnabled()) {
        this.togglePreviewSearch();
      }
    })
  }

  /**
   * 预览头部的「复制代码」按钮（上游 `PreviewIconButton(icon = if (copied) Lucide.Check else Lucide.Copy)`，`:1200-1212`）。
   *
   * 上游 `copyEnabled = !binary && content 非空白`：不可复制时按钮直接置灰，
   * 而不是「看着能点、点了只弹一句不能复制」。
   */
  @Builder
  previewCopyButton() {
    Column() {
      AaIcon({
        d: this.copiedKey === PREVIEW_CODE_KEY ? ICONS['check'] : ICONS['copy'],
        iconSize: PREVIEW_ICON_BTN_ICON,
        color: $r('app.color.preview_button_icon')
      })
    }
    .width(PREVIEW_ICON_BTN)
    .height(PREVIEW_ICON_BTN)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(PREVIEW_ICON_BTN_RADIUS)
    .backgroundColor($r('app.color.preview_button_surface'))
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor($r('app.color.preview_button_ring'))
    .opacity(this.copyEnabled() ? 1 : 0.38)
    .onClick(() => {
      if (this.copyEnabled()) {
        this.copyPreviewCode();
      }
    })
  }

  /** 搜索按钮可用性（上游 `enabled = true`，但二进制文件搜不了，这里按本工程既有语义收敛）。 */
  private previewSearchEnabled(): boolean {
    return this.previewFile !== undefined && !this.previewBinary();
  }

  /** 面包屑右侧的路径文本（上游用的是 `displayRemotePath(root, file.path, deviceOs)` 同一份算法）。 */
  private previewRemotePath(): string {
    const file = this.previewFile;
    if (file === undefined) {
      return '';
    }
    return this.entryCopyPath(file.path);
  }

  @Builder
  previewSheet() {
    Column({ space: Space.S }) {
      this.previewBreadcrumb()

      // 预览卡头部（上游 `PreviewCardHeader`，`SessionAgentFilesScreen.kt:1161-1214`）：
      // 行高 44 / 水平内边距 12 / 元素间距 8；文件名 15sp ExtraBold 且 `weight(1f)`；
      // 右侧**两个 34dp 圆角方形图标按钮**（搜索、复制代码）。
      //
      // ⚠️ R69 修正：此前是「文件名 + 一个『关闭』胶囊 + 一行三个文字胶囊（复制路径/复制代码/在文件中搜索）」。
      // 并排图 `../r16-side-by-side/20-file-preview.png` 上，安卓/上游只有**两个图标按钮**、
      // 且**没有『关闭』**（返回走面包屑左侧那颗「‹ 文件」胶囊，见 `previewBreadcrumb()`）。
      // 「复制路径」上游预览页也没有（路径就在面包屑里）⇒ 一并去掉，功能不减。
      Row({ space: PREVIEW_HEAD_GAP }) {
        Text(this.previewFile !== undefined ? this.previewFile.name : '预览')
          .fontSize(PREVIEW_FILE_FONT)
          .fontWeight(FontWeight.Bold)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.previewSearchButton()
        this.previewCopyButton()
      }
      .width('100%')
      .height(PREVIEW_HEAD_H)
      .padding({ left: PREVIEW_HEAD_PAD, right: PREVIEW_HEAD_PAD })
      .alignItems(VerticalAlign.Center)

      // 面板内轻提示（复制成功 / 失败 / 搜索说明）：**面板内**给反馈，
      // 因为面板盖住了 80% 的页面，页面顶部的提示条在面板打开时看不见。
      if (this.previewHint.length > 0) {
        Text(this.previewHint)
          .fontSize(FontSize.SMALL)
          .fontColor(inkSoft())
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.previewSearchOpen) {
        this.previewSearchPanel()
      }

      if (this.previewLoadingFlag) {
        LoadingProgress().width(24).height(24).color(muted())
      } else if (this.previewErrorText.length > 0) {
        Text(this.previewErrorText).fontSize(FontSize.SMALL).fontColor($r('app.color.error_text'))
      } else if (this.previewFile !== undefined) {
        Row({ space: Space.S }) {
          AaChip({ label: this.previewFile.encoding })
          // 代码类文件按文件名猜语言做高亮（对应上游 `CodeBlockPreview`）。
          if (this.previewLanguage.length > 0) {
            AaChip({ label: this.previewLanguage })
          }
          if (this.previewFile.truncated) {
            AaChip({ label: '已截断', emphasized: true, color: $r('app.color.notice_warning') })
          }
          if (this.previewFile.binary) {
            AaChip({ label: '二进制', emphasized: true, color: $r('app.color.error_text') })
          }
        }
        Scroll() {
          if (this.previewLanguage.length > 0 && !this.previewFile.binary) {
            AaCodeText({ code: this.previewFile.content, language: this.previewLanguage })
          } else {
            Text(this.previewFile.content)
              .fontSize(FontSize.SMALL)
              .fontFamily('Noto Sans Mono')
              .fontColor(ink())
              .width('100%')
              .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          }
        }
        .layoutWeight(1)
        .width('100%')
        /**
         * ⚠️ R13 F-11：`align` 是**通用属性**，SDK 默认值是 `Alignment.Center`
         * （`common.d.ts` → `align(value: Alignment)`：Default value: Alignment.Center），
         * 它管的是「组件内容在其绘制区内的对齐」⇒ **`Scroll` 的内容比视口短时会被垂直居中**。
         * 预览一篇短文件时（README.md 约 400px，视口约 1700px）上方白空 566px ——
         * 与设置页 F-10 是**同一个根因**（那次的实测判据：内容 1739px < 视口 2408px ⇒
         * 上下各空 334px，严格对称 ⇒ 是居中而不是 padding）。
         * 真机 dump 佐证：`# agents-anywhere` 首行在 y=1656，而 chips 底边在 y≈1053。
         */
        .align(Alignment.Top)
      }
    }
    .width('100%')
    // ⚠️ 必须是 `layoutWeight(1)` 而不是 `height('100%')`：本区块的父级是「顶栏 + 提示条 + 本区块」的
    // Column，子级再写 `height('100%')` 会按**父的整高**解析 ⇒ 整体下移一个顶栏的高度、底部被挤出去
    // （R13-37 在新建会话页踩过同一个坑）。
    .layoutWeight(1)
    // ⚠️ R66-3：预览态也要让出**浮层底栏**那一条 —— 本区块的底部就是代码 Scroll 的视口底，
    //  不让位的话文件**最后两行会停在胶囊背后**（同类缺陷：R65 真机的「刷新目录」被底缘切掉）。
    //  这里用**容器内边距**（而不是 contentEndOffset）是刻意的：代码阅读器不该让正文从胶囊背后穿过。
    .padding({
      left: Space.L, right: Space.L, top: Space.L,
      bottom: Space.L + BOTTOM_BAR_RESERVED_VP
    })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 预览面板内的内容搜索面板（复刻上游 `InlineFileSearchControls`）。
   *
   * 上游是「编辑器内高亮 + 滚动定位」；ArkUI 的 `AaCodeText` 不支持逐段高亮，
   * 本工程改成**命中列表**：可数（`当前/总数`）、可跳（上一条/下一条循环）、可点选，
   * 而且每一行都在 `dumpLayout` 里可读 —— 比「只画个高亮看不见证据」更可验收。
   */
  @Builder
  previewSearchPanel() {
    Column({ space: Space.S }) {
      TextInput({ text: this.previewQuery, placeholder: '搜索' })
        .fontSize(FontSize.SMALL)
        .height(Control.FIELD_COMPACT)
        .width('100%')
        .borderRadius(Radius.S)
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .backgroundColor(raisedSurface())
        .onChange((value: string) => {
          this.previewQuery = value;
          this.runPreviewSearch();
        })
      Row({ space: Space.S }) {
        Text(this.previewMatchLabel())
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .layoutWeight(1)
        AaSecondaryButton({
          // 上游 `SearchStepButton(icon = Lucide.ChevronUp)` —— 是图标不是文字。
          // ⚠️ R57（T2b）纠正一条**陈旧注释**：这里原先写着「本工程没有图标系统，用字符图标近似」，
          // 但参数其实早就是 `iconName`（R12-5 起走 `ui/Icon.ets` 的矢量表，见 suite-icons 的断言
          // 「文件页搜索上下步按钮用矢量图标」）。全工程的字符图标在 R12 已清零，这条注释是残留，
          // 留着会误导后人以为还能这么写。
          iconName: 'chevron-up',
          compact: true,
          interactive: this.previewMatchTotal > 0,
          onTap: () => {
            this.stepPreviewMatch(false);
          }
        })
        AaSecondaryButton({
          iconName: 'chevron-down',
          compact: true,
          interactive: this.previewMatchTotal > 0,
          onTap: () => {
            this.stepPreviewMatch(true);
          }
        })
      }
      .width('100%')

      // 零命中**不另编文案**：上游 `InlineFileSearchControls` 的反馈就是那个 `当前/总数`
      // 计数（零命中显示 `0/0`），上面那行 Text 已经把它显示出来了。
      if (this.previewMatches.length > 0) {
        List({ space: Space.XXS }) {
          ForEach(this.previewMatches, (match: FileMatch) => {
            ListItem() {
              this.matchRow(match)
            }
          }, (match: FileMatch) => `${match.index}:${match.line}:${match.column}`)
        }
        // 列表必须有**确定高度**：命中条数决定行数，最多 5 行，再多由列表自己滚。
        // （「按内容撑开」的容器里给子节点百分比尺寸会踩坑 141。）
        .height(this.matchListHeight())
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .padding(Space.S)
    .borderRadius(Radius.M)
    .backgroundColor(subtle())
  }

  /**
   * 一条内容命中：`▶ 第 N 行 + 行文本`，当前命中加深底色。
   *
   * ⚠️ 「是否当前命中」是 `@State` 标记，**不进 ForEach 的 key**（坑 152），
   * 行内用 `this.isCurrentMatch(match)` 判 —— 进 key 会让每次跳转都重跑整轮 key 生成。
   */
  @Builder
  matchRow(match: FileMatch) {
    Row({ space: Space.S }) {
      Column() {
        if (this.isCurrentMatch(match)) {
          AaIcon({ d: ICONS['chevron-right'], iconSize: FontSize.CAPTION, color: primaryAction() })
        }
      }
        .width(FontSize.CAPTION)
      // 只显示行号（数据），不编「第 N 行」这种上游没有的文案。
      Text(`${match.line}`)
        .fontSize(FontSize.CAPTION)
        .fontColor(muted())
      Text(match.text)
        .fontSize(FontSize.SMALL)
        .fontFamily('Noto Sans Mono')
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(MATCH_ROW_HEIGHT)
    .padding({ left: Space.S, right: Space.S })
    .borderRadius(Radius.S)
    .backgroundColor(this.isCurrentMatch(match) ? raisedSurface() : Color.Transparent)
    // R39：官方按压态。⚠️ 本行底色是**动态的**（当前命中项才亮底）⇒ `normal` 必须写**逐字相同**的表达式，
    // 不能给 `Color.Transparent`（那样会把「当前命中」的底色覆盖掉）。
    // 与同页 `parentRow()` / `entryRow()`（R20 既有）同款，只是那两处是静态透明。
    .stateStyles({
      normal: { .backgroundColor(this.isCurrentMatch(match) ? raisedSurface() : Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      this.selectPreviewMatch(match.index);
    })
  }

}

export { Route };
