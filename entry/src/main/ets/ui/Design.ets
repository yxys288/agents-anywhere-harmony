/**
 * 设计系统（对应 Android `ui/designsystem/Theme.kt` + `Components.kt`）。
 *
 * 颜色全部走资源（`$r('app.color.*')`，base/dark 双值自动跟随深浅色），
 * 间距/圆角/字号用常量，保证与 Android 端视觉一致。
 */

export class Space {
  /**
   * 紧凑行内间距：双行标题的行距、图标与文字的贴合间距。
   *
   * 第九轮各页面里这个值被硬编码了 6 处（`Column({ space: 2 })`），
   * 数值一致但写法不统一 —— 收进令牌后由 `tools/logic-test/suite-design.mjs` 守住。
   */
  static readonly XXS: number = 2;
  static readonly XS: number = 4;
  /** 图标与文字的贴合间距（上游 6.dp）。 */
  static readonly XS_PLUS: number = 6;
  static readonly S: number = 8;
  static readonly M: number = 12;
  static readonly L: number = 16;
  /** 动作卡行的左右内边距（上游 `HomeProjectComponents.kt:598` `padding(horizontal = 20.dp)`）。 */
  static readonly L_PLUS: number = 20;
  static readonly XL: number = 24;
  static readonly XXL: number = 32;
  /** 快捷卡片之间的间距（上游 HomeScreen.kt spacedBy(10.dp)）。 */
  static readonly S_PLUS: number = 10;
  /** 紧凑行间距（输入区动作行 SubcomposerActions spacedBy(9.dp)）。 */
  static readonly TIGHT: number = 9;
  /** 卡片垂直内边距（上游 padding(vertical = 13.dp)）。 */
  static readonly M_PLUS: number = 13;
  /** 首页区块之间的间距（上游 spacedBy(15.dp)）。 */
  static readonly BLOCK: number = 15;
  /** 页面水平边距（上游 padding(start = 18.dp, end = 18.dp)）。 */
  static readonly PAGE: number = 18;
  /** 列表页底部内边距（上游 DevicesScreen contentPadding bottom = 28.dp）。 */
  static readonly PAGE_BOTTOM: number = 28;
  /**
   * 首页列表的尾部留白（vp）—— 避开右下悬浮按钮（用户投诉「图标不要重复添加，搞得都叠加到一起」的修复点）。
   *
   * 悬浮按钮 `AaFloatingButton`（diameter 54 + `insetBottom: Space.XXL` = 32）**恒占屏幕底部 86vp**；
   * 改前两个列表用 `PAGE_BOTTOM`（28）收尾 ⇒ 列表滚到底时最后一行的「⋯ / 铅笔」永远压在按钮下面。
   * 上游四个首页列表统一 `contentPadding = PaddingValues(bottom = 96.dp)`
   * （锚文 `HomeLists.kt:157` / `:264` / `:344`、`HomeProjectComponents.kt:144`），96 = 86 + 10 余量。
   *
   * R12-2 先把常量落在 `HomeScreen.ets`，R12-5 收编进本令牌组。
   */
  static readonly HOME_LIST_BOTTOM: number = 96;
  /** 空态文案的水平内边距（上游 AppEmptyState 34.dp）。 */
  static readonly EMPTY_TEXT: number = 34;
  /** 已归档会话行的垂直内边距（上游 14dp）。 */
  static readonly ROW_PAD_V: number = 14;
  /** 分组副文缩进 / SetupPanel 间距（上游 28dp）。 */
  static readonly INDENT: number = 28;
  /** 分页脚顶部留白（上游 20dp）。 */
  static readonly FOOTER_TOP: number = 20;
  /** 状态面板垂直内边距（上游 40dp）。 */
  static readonly PANEL_V: number = 40;
}

export class Radius {
  static readonly S: number = 8;
  /** 安卓圆角刻度 6（会话区小按钮 / SetupBackButton）。 */
  static readonly XS: number = 6;
  /** 安卓圆角刻度 10（配对向导输入框 / 连接方式选项行 / 命令块）。 */
  static readonly S_PLUS: number = 10;
  /** 设备页「添加新设备」行与设备行圆角（上游 DevicesScreen RoundedCornerShape(15.dp)）。 */
  static readonly DEVICE_ROW: number = 15;
  /** 状态面板插图内层圆角（上游 26dp）。 */
  static readonly HERO_INNER: number = 26;
  static readonly M: number = 12;
  static readonly L: number = 16;
  /** 安卓圆角刻度 14（复刻上游实现）。 */
  static readonly M_PLUS: number = 14;
  /** 快捷卡片 / 项目行圆角（上游 HomeScreen.kt RoundedCornerShape(18.dp)）。 */
  static readonly XL: number = 18;
  /** 安卓圆角刻度 22（会话输入区卡片）。 */
  static readonly XXL: number = 22;
  /** 安卓圆角刻度 28（卡片阴影范围 / 大圆角）。 */
  static readonly XXXL: number = 28;
  static readonly PILL: number = 999;
}

/**
 * 通用控件的固定尺寸（高度 / 边长）。
 *
 * 统一前同一类控件在 6 个页面里出现过 36/38/40/42/44/46 六种高度，
 * 这里只保留「标准」与「紧凑」两档，多行文本域的高度仍由各页面自定（用途差异太大）。
 */
export class Control {
  /** 标准控件行高：单行输入框 / 只读字段 / 分组头 / 列表行。 */
  static readonly FIELD: number = 44;
  /** 列表行内的紧凑输入框（搜索框、环境变量名/值这类行内编辑）。 */
  static readonly FIELD_COMPACT: number = 36;
  /** 顶栏的圆形返回按钮（`'‹'`）边长。 */
  static readonly NAV_BUTTON: number = 32;
  /** 列表行内的圆形图标按钮（`'⋯'` / `'✎'` / 分组头右侧）边长。 */
  static readonly ICON_BUTTON: number = 38;
  /** 主按钮（`AaPrimaryButton`）高度。 */
  static readonly BUTTON: number = 46;
  /** 弹层里的菜单行（`AaMenuActionRow`）高度。 */
  static readonly MENU_ROW: number = 50;
  /** 首页顶栏行高（上游 HomeScreen.kt height(46.dp)）。 */
  static readonly HOME_HEADER: number = 46;
  /**
   * **`Navigation` 标题栏里那一行的高度**（R80 新增，9 个页面共用）。
   *
   * ⚠️ **必须与 `HOME_HEADER` 同值（46）** —— 这不是审美选择，是框架的几何事实：
   * `titleMode: Full` 的槽恒为 `[0,137][1316,332]`，而框架把构造器的**顶边锚在 y=166**（与行高无关）
   * ⇒ **栏内控件垂直中心 = 166 + 行高 ÷ 2**（真机三份 dump 实测，见 `坑 251`）。
   * 行高不同 ⇒ 同一位置的控件差**半个行高**：64vp 的行中心 262，46vp 的行中心 **235（= 首页）**。
   *
   * ⚠️ 与上游 Android 的 64dp（`TOP_BAR_PAGE`）**有意偏离**：上游是自绘顶栏，64dp 从状态栏下沿起算；
   * 本工程 R65 起把顶栏搬进 `Navigation` 标题栏，行位于 195px 的槽里，行高只决定中心 —— 
   * 用户对「标题栏离时间栏多远」的参照物是**首页**（R76 起「与首页效果一致」），故统一取 46。
   */
  static readonly NAV_TITLE_ROW: number = 46;
  /** 首页快捷卡片行高（上游 height(76.dp)）。 */
  static readonly QUICK_ROW: number = 76;
  /** 列表分组头行高（上游 HomeLists.kt height(41.dp)）。 */
  static readonly SECTION_HEADER: number = 41;
  /** 置顶会话行高（上游 HomeLists.kt）。 */
  static readonly ROW_TALL: number = 66;
  /** 普通会话行高（上游 HomeLists.kt）。 */
  static readonly ROW: number = 52;
  /** 会话行首图标槽宽度（上游 20.dp）。 */
  static readonly ROW_LEADING: number = 20;
  /** 通用页顶栏行高（上游 DevicesScreen.kt height(64.dp)）。 */
  static readonly TOP_BAR_PAGE: number = 64;
  /** 通用页顶栏的圆形返回按钮边长（上游 40.dp，比列表行内的 32 大一档）。 */
  static readonly NAV_BUTTON_LARGE: number = 40;
  /** 下拉菜单宽度（上游 AADropdownMenu.MenuWidth = 286.dp）。 */
  static readonly MENU_WIDTH: number = 286;
  /** 下拉菜单最大高度（上游 AADropdownMenu.MenuMaxHeight = 328.dp）。 */
  static readonly MENU_MAX_HEIGHT: number = 328;
  /** 下拉菜单项最小高度（上游 48.dp）。 */
  static readonly MENU_ITEM_MIN: number = 48;
  /** 下拉菜单容器上下内边距（上游 AADropdownMenu.MenuVerticalPadding = 14.dp）。 */
  static readonly MENU_PAD_V: number = 14;
  /**
   * 下拉菜单「标签项」高度。
   * 上游 `AADropdownMenuLabel` 只有 `padding(vertical = 8.dp)` + 12sp 文本；安卓 dump 实测该项
   * 高 40.5dp（743→905 px ÷ dpr 2.975，含 Droid Sans 默认行距）。ArkUI 12sp 行框约 16.5vp，
   * 直接照抄 padding 会短 ~8vp ⇒ 显式给 `MENU_LABEL_H = 40` 以复现安卓的行位（残留 0.5dp）。
   */
  static readonly MENU_LABEL_H: number = 40;
  /** 项目「…」动作卡宽（上游 `HomeProjectActionCard`：252.dp）。 */
  static readonly MENU_CARD_W: number = 252;
  /** 项目「…」动作卡高（上游 `HomeProjectActionCard`：168.dp，内部 3×50 + 上下 7）。 */
  static readonly MENU_CARD_H: number = 168;
  /** 首页项目行高（上游 `HomeProjectComponents.kt:310 HomeProjectRow.height(56.dp)`）。 */
  static readonly ROW_PROJECT: number = 56;
  /** 项目展开后的会话子行高（上游 `HomeProjectSessionRow.kt:41 height(44.dp)`）。 */
  static readonly ROW_PROJECT_SESSION: number = 44;
  /** 项目展开后会话子行的左侧缩进（上游 `HomeProjectSessionRow.kt:51 padding(start = 34.dp)`）。 */
  static readonly PROJECT_SESSION_INSET: number = 34;
  /** 「暂无会话」占位高度（上游 `HomeProjectComponents.kt:272 Box(height 42.dp)`）。 */
  static readonly PROJECT_EMPTY: number = 42;
  /** 大号输入框高度（配对向导名字输入框 48dp）。 */
  static readonly FIELD_LARGE: number = 48;
  /** 面板里的动作行 / 按钮高度（上游 42dp）。 */
  static readonly ACTION_ROW: number = 42;
  /** 连接方式选项行高度（上游 82dp）。 */
  static readonly OPTION_ROW: number = 82;
  /** 筛选 tag / 小按钮高度（上游 34dp）。 */
  static readonly TAG: number = 34;
  /** 小文字动作按钮高度（上游 30dp）。 */
  static readonly MINI_ACTION: number = 30;
  /** Runtime 行最小高度（上游 72dp）。 */
  static readonly ROW_AGENT: number = 72;
  /** 会话多选勾选圈直径（上游 20dp）。 */
  static readonly CHECK_CIRCLE: number = 20;
  /** 状态点槽宽度（上游 14dp）。 */
  static readonly DOT_SLOT: number = 14;
  /** 开关轨宽（上游 32dp）。 */
  static readonly SWITCH_TRACK_W: number = 32;
  /** 开关轨高（上游 20dp）。 */
  static readonly SWITCH_TRACK_H: number = 20;
  /** 开关滑块直径（上游 Runtime 开关 16dp）。 */
  static readonly SWITCH_KNOB: number = 16;
  /** 高输入框（配对向导名字输入框 / 配对码格子 54dp）。 */
  static readonly FIELD_TALL: number = 54;
  /** 配对向导动作按钮最小高（上游 50dp）。 */
  static readonly ACTION_ROW_LARGE: number = 50;
  /** 命令块头行高（上游 SetupSheet 24dp；不做该面板可不用）。 */
  static readonly MINI_ROW: number = 24;
  /** AGENT 区加载行高（上游 56dp）。 */
  static readonly LOADING_ROW: number = 56;
  /** AGENT 区提示行的小图标（上游 15dp）。 */
  static readonly ICON_TINY: number = 15;
  /** 紧凑页顶栏（NewSession / NewProject，上游 58dp；**不是**通用 64dp）。 */
  static readonly TOP_BAR_COMPACT: number = 58;
  /** 大号主按钮 / 项目名输入框（上游 54dp）。 */
  static readonly BUTTON_LARGE: number = 54;
  /** 未就绪态引导插图边长（上游 168dp）。 */
  static readonly ARTWORK: number = 168;
  /** 状态面板插图外圈（上游 128dp）。 */
  static readonly HERO_CIRCLE: number = 128;
  /** 状态面板插图内层（上游 80dp）。 */
  static readonly HERO_INNER: number = 80;
  /** 状态面板插图内图标字号（上游 32dp）。 */
  static readonly HERO_ICON: number = 32;
  /** 状态面板说明文字最大宽（上游 260dp）。 */
  static readonly HERO_TEXT_MAX: number = 260;
  /**
   * 状态面板 loading 转圈直径（上游 26dp）。
   *
   * ⚠️ 上游线宽 2dp，但 ArkUI 的 `LoadingProgress` **没有线宽参数**（SDK 实证：
   * loading_progress.d.ts 的 LoadingProgressAttribute 只有 color/enableLoading/contentModifier），
   * 因此本工程的转圈线宽由系统决定 —— 已列入差异清单，**不要为了对齐它去写一个看起来配了线宽的假样式**
   * （由归档页包在第十轮实证并纠正 Lead 的注释）。
   */
  static readonly HERO_SPINNER: number = 26;
  /** 行内 loading 转圈直径（上游设备详情 AGENT 区 / 配对向导 17dp）。 */
  static readonly SPINNER: number = 17;
  /** 设备页「添加新设备」行与设备行行高（上游 60dp）。 */
  static readonly ROW_DEVICE: number = 60;
  /** 设备行的图标底框边长（上游 size(42.dp)）。 */
  static readonly DEVICE_ICON: number = 42;
  /** 设备页空态高度（上游 height(360.dp)）。 */
  static readonly EMPTY_TALL: number = 360;
  /** Runtime 状态点内点直径（上游 槽 14 / 外点 14 / 内点 8）。 */
  static readonly DOT_INNER: number = 8;
}

/** 描边宽度。 */
export class StrokeWidth {
  /** 卡片 / 输入框的 1vp 细线（统一前各页面写了 20+ 处裸 `1`）。 */
  static readonly HAIRLINE: number = 1;
  /** 强调描边（上游 Runtime 开关轨边框 2dp）。 */
  static readonly EMPHASIS: number = 2;
}

/**
 * 阴影的**扩散半径**（不是圆角 —— 数值恰好与 Radius 的几档相同，但语义完全不同；
 * 由会话详情包在第十轮提出并单独成组，避免后人把阴影值挂到圆角令牌下）。
 */
export class Shadow {
  /** 卡片阴影（上游输入卡片 28.dp）。 */
  static readonly CARD: number = 28;
  /** 胶囊标题 / 顶部提示条阴影（上游 18.dp）。 */
  static readonly PILL: number = 18;
  /** Toast 阴影（上游 AAToast 14.dp）。 */
  static readonly TOAST: number = 14;
}

/**
 * 字号刻度。
 *
 * ⚠️ **命名上的历史妥协**：ICON_SMALL / ICON_MD / ICON / ICON_XL / ICON_LARGE / BUTTON_ICON / CHEVRON / NAV_ICON
 * 这几档承载的其实是「**图标尺寸**」语义 —— 本工程没有矢量图标系统，图标一律用字符符号 + `fontSize()` 近似，
 * 所以它们只能放在字号组里。第十轮设备域包指出过这一点：严格说它们该在 Control 组。
 * 迁移会波及 6+ 个页面（跨多个 owner、回归面大），收益（语义纯正）小于成本，故**保留现值**；
 * 新代码里若要表达「尺寸」，请优先用 Control 组；确实需要控字符图标大小时再用这几档。
 */
export class FontSize {
  static readonly CAPTION: number = 11;
  /** 下拉菜单标签项字号（上游 `AADropdownMenuLabel.fontSize = 12.sp`）。 */
  static readonly MENU_LABEL: number = 12;
  static readonly SMALL: number = 13;
  static readonly BODY: number = 15;
  static readonly TITLE: number = 17;
  static readonly HEADLINE: number = 22;
  static readonly DISPLAY: number = 28;
  /**
   * 页面顶栏的返回箭头 `'‹'`。
   *
   * 统一前：7 个页面写 28、`AaTopBar` 写 30 —— 同一个控件两种字号。
   */
  static readonly NAV_ICON: number = 28;
  /** 大号图标符号（悬浮按钮 / 分组头的 `'+'`）。 */
  static readonly ICON_LARGE: number = 24;
  /** 通用图标符号字号（列表行尾 `'›'`、快捷卡片与菜单行的图标）。 */
  static readonly ICON: number = 20;
  /** 首页字标（上游 AAWordmark fontSize = 31.sp）。 */
  static readonly WORDMARK: number = 31;
  /** 快捷卡片文案（上游 14.sp Bold）。 */
  static readonly BODY_SMALL: number = 14;
  /** 大号图标符号（上游 22.dp 图标槽，ArkUI 用字号近似）。 */
  static readonly ICON_XL: number = 22;
  /** 列表分组头文字（上游 13.2.sp，非整数照抄）。 */
  static readonly SECTION: number = 13.2;
  /** 会话行标题（上游 16.sp Bold）。 */
  static readonly ROW_TITLE: number = 16;
  /** 置顶会话行副标题（上游 11.2.sp）。 */
  static readonly SUBTITLE: number = 11.2;
  /** 行尾时间（上游 10.8.sp Monospace）。 */
  static readonly TIME: number = 10.8;
  /** 会话行首小图标（上游 14.dp）。 */
  static readonly ICON_SMALL: number = 14;
  /** 分组头 ChevronDown（上游 16.dp）。 */
  static readonly ICON_MD: number = 16;
  /** 设备选择条 / 分组头的下拉箭头（上游 19.dp）。 */
  static readonly CHEVRON: number = 19;
  /** 空态按钮内的图标（上游 17.dp）。 */
  static readonly BUTTON_ICON: number = 17;
  /** 设备详情标题（上游 25.sp ExtraBold）。 */
  static readonly DETAIL_TITLE: number = 25;
  /** Runtime 行名称（上游 16.5.sp）。 */
  static readonly ROW_TITLE_LARGE: number = 16.5;
  /** 说明文 / 小按钮文字（上游 12.5.sp）。 */
  static readonly SMALL_PLUS: number = 12.5;
  /** Runtime 副文 / 多选工具条次文字（上游 11.5.sp）。 */
  static readonly CAPTION_PLUS: number = 11.5;
  /** 选项行说明 / 名字标签（上游 12.6.sp）。 */
  static readonly OPTION_TEXT: number = 12.6;
  /** 配对向导提示文（上游 13.6.sp）。 */
  static readonly HINT: number = 13.6;
  /** 配对向导命令块的等宽正文（上游 Monospace 12.sp）。 */
  static readonly MONO_SMALL: number = 12;
  /** NewSession / NewProject 顶栏标题（上游 20.sp）。 */
  static readonly TITLE_MD: number = 20;
}

/** 页面底色（浅色 #FDFCFB / 深色 #09090B）。 */
export function canvas(): Resource {
  return $r('app.color.canvas');
}

export function ink(): Resource {
  return $r('app.color.ink');
}

export function muted(): Resource {
  return $r('app.color.muted');
}

/** 次级正文（比 `ink` 淡、比 `muted` 实）。 */
export function inkSoft(): Resource {
  return $r('app.color.ink_soft');
}

/** 最淡的一档文字 / 图标（占位、次要说明、列表行尾箭头）。 */
export function faint(): Resource {
  return $r('app.color.faint');
}

/** 浅底（chip / 只读字段 / 次级按钮底）。 */
export function subtle(): Resource {
  return $r('app.color.subtle');
}

/** 错误色文字（错误横幅正文、危险操作文案）。 */
export function errorText(): Resource {
  return $r('app.color.error_text');
}

export function borderColor(): Resource {
  return $r('app.color.border');
}

export function raisedSurface(): Resource {
  return $r('app.color.raised_surface');
}

/**
 * 列表行的**按下态**底色（浅色 #EDEBE6 / 深色 #292929）。
 *
 * ⚠️ 只用于**按下时**：上游 `FileListRow`（`SessionAgentFilesScreen.kt:1652-1672`）的底色是
 * `pressedSurface.copy(alpha = surfaceAlpha)`，而 `surfaceAlpha = if (active) 1f else 0f`
 * —— **静止态完全透明**（`active = pressed || flash`）。给列表行常驻底色是复刻偏差，
 * 深色主题下尤其显眼（`raised_surface #1F1F1F` 压在 `canvas #09090B` 上就是一张张灰卡）。
 */
export function rowPressedSurface(): Resource {
  return $r('app.color.row_pressed_surface');
}

/**
 * 文件列表行的三个色（逐字取上游 `FileListRow`，`SessionAgentFilesScreen.kt:1661-1664`）：
 *  · 图标：`dark ? 0xFFA1A1AA : 0xFF2F302D`
 *  · 文案：`dark ? 0xFFFAFAFA : 0xFF242521`
 *  · 尾部 `›`：`FolderRow` 里是 `dark ? 0xFF71717A : 0xFFA8A6A0`（`:1599`）
 * ⚠️ 这三组都**不是** `ink()` / `muted()` 的值 —— 浅色下图标比 `ink` 灰、`›` 比 `muted` 浅，
 * 别拿通用色顶替（R26 并排图核对时发现本工程原先正是这么做的）。
 */
export function filesRowIcon(): Resource {
  return $r('app.color.files_row_icon');
}

export function filesRowText(): Resource {
  return $r('app.color.files_row_text');
}

export function filesRowChevron(): Resource {
  return $r('app.color.files_row_chevron');
}

/**
 * 毛玻璃（顶栏 / 底部输入区 / 悬浮按钮）—— 内容从背后穿过时被高斯糊化。
 *
 * ⚠️ 三条硬约束（同工作区 DeepSeekHm 真机逐像素实测的结论，直接照搬）：
 *  ① **必须用 `backgroundEffect`**，不能用 `backgroundBlurStyle` —— 后者是"材质"，
 *  自带近乎不透明的浅色遮罩并接管 `backgroundColor`（坑 74）；
 *  ② **不要用 `backdropBlur`**：它只有 radius / grayscale 两个旋钮，没法按深浅色分档；
 *  ③ 模糊半径与饱和度/亮度**全工程同值**，深浅色差异**只由玻璃色资源承担**
 *  （真机实测"模糊本身中性"：玻璃色 alpha 归零时模糊区与页面底色完全相等）。
 */
export const GLASS_BLUR_RADIUS: number = 6;
/**
 * **整块面板**（运行时设置那种盖住正文的浮层）用的模糊半径 —— 比顶栏强得多。
 *
 * ⚠️ R37 七改（用户反馈「设置弹窗的模糊度提高，有点看不清字了」）：顶栏那层 6 是给「一条细带」
 * 用的（背后只扫过一两行字）；整块面板背后是**成片的正文**，6 根本压不住 —— 必须更强，
 * 再配一个更实的底色（`glassPanelSurface()`，alpha ≈ 85%）。
 */
export const GLASS_PANEL_BLUR: number = 24;
export const GLASS_SATURATION: number = 1.0;
export const GLASS_BRIGHTNESS: number = 1.0;

/**
 * 液态玻璃**控件**（圆形功能钮 / 圆角玻璃块）的几何与光照常数。
 *
 * 与上面那一组的分工：`GLASS_BLUR_RADIUS` 管「整条功能栏 / 浮层的磨砂底色」，
 * 这一组只管**单个玻璃控件**的外圈亮边、镜面高光与投影。模糊档不另立 ——
 * 控件背面就是功能栏本身，按 EXPERIENCE §5.9 的定档依据（背后有多少内容，不是控件多大），
 * 与栏同档（6）即可。
 *
 * ⚠️ 与坑 13 的关系（**有意偏离，理由写在这里**）：那条禁的是 ①`lightEffect`
 * ②材质胶囊**顶缘**那条 1px 高亮**直线**（真机上会与材质合成一条锐利贯穿亮线）。
 * 这里两者都不用；按压光感由 `@State pressed` 驱动的**显式按压光效层**承担（R57/T13 起，
 * 「整体降不透明度」已退役 —— 那是减光，见本节下方与 `GlassIcon.ets` 的 ③ 层说明）。
 *
 * ## R64 沉浸光感 v4 光效规格（**当前口径**）—— 治「灰塑料盘」，把光收回到边缘弧
 *
 * 用户第二轮反馈：「**光效差距比较大，继续优化**」（参考图 + 真机截图对照，SPEC §0/§1）。
 * 同一脚本口径实测（SPEC §1）：真机盘面 Δ **+24.0**、等效白 α **10.9%** ⇒ 比参考图（+1.5~+3.9 / 0.7~1.8%）
 * **亮了约 6 倍**，钮成了「发灰的塑料盘」；且 v3 的 `linearGradient` 把光**铺满整盘**
 * （盘面 24 扇区极差 **36** vs 参考 **7**）；环几乎整圈均匀（上/下 **0.98**，参考 **2.9**）且没有外发光。
 *
 * ⚠️ **v3 的口径在这一轮被推翻三处**（别照着 v3 的注释改回去）：
 * | v3 做法 | v4 现状 | 为什么作废 |
 * | --- | --- | --- |
 * | 盘面 `linearGradient` **铺满整盘**（1 层，`SHEEN_ANGLE`） | **整层删除** ⇒ `GlassIcon.ets` 里 `linearGradient(` **0 次** | 它把本该只在边缘的光摊到盘面内部：既提亮盘面，又把圆盘染成「斜面板」（极差 36） |
 * | 盘面自发光 4.3% 白（dark `#0BFFFFFF`） | **1.2% 白**（dark `#03FFFFFF`） | 真机盘面 Δ+24 ≈ 参考图的 6 倍；参考图盘面**几乎与背景同亮**，全靠边缘那道光被感知 |
 * | 单段整圈均匀环（0.75vp，硬线） | **上亮 / 下暗两段半环 + `.blur()` 外发光**（'1.25vp' 弧带） | 参考图的环**左上最亮、向下衰减**（上/下 ≈2.9）且带外发光晕；均匀硬线（0.98）不是那个观感 |
 *
 * ⇒ v4 正解 = **盘面近乎透明（1.2% 白）+ 只在边缘的上亮/下暗两段光弧（bloom）+ 同一处投影**。
 * ⚠️ `SHEEN_ANGLE` / `SHEEN_MID_STOP` / `glassSheen*()` **保留不删**：顶栏胶囊（`Components.ets`）
 * 与底栏胶囊（`BottomNav.ets`）仍在消费它们（SPEC §2.3「保留（不许删，别人在用）」）。
 *
 * ## R63 沉浸光感 v3 光效规格 —— 用户明确推翻 R57 的「完全平坦」口径
 * ⚠️ **本节以下（v3）是历史**：其中「盘面加 1 层铺满渐变」的做法已被 R64 整层删除（见上表）。
 *
 * 用户原话（R63）：「用**渐变 + 半透明 + 模糊组合**等方式实现图中按钮的沉浸光感特效」。
 * 参考图（深色顶栏一排圆钮）观感：**半透明暗玻璃圆盘**（背后内容被糊化）
 * ＋ **沿左上到右下的一层柔和渐变光**（左上偏亮、右下偏暗）＋ **一圈可见的发丝亮边**
 * （比 R57 的 0.5vp 更明显）＋ 柔和投影。冻结规格：开发期规格文档。
 *
 * ⚠️ **R57/T11 的旧口径已作废**（它来自「一张深色无内容图」的逐半径中位数）：
 * | 旧断言（R57/T11） | 现状（R63 v3） | 为什么作废 |
 * | --- | --- | --- |
 * | 盘面 r 0.4~0.83R **恒 +11/255、完全平坦** | **允许且要求**方向性渐变光 | 用户明确要求「渐变光」，参考图也是左上亮/右下暗；「绝对平坦」会把用户要的效果本身判成缺陷（SPEC §2.1 层 ②） |
 * | 控件内**不得有任何落在盘面内部的渐变** | 盘面**必须**有 1 层线性渐变 | 同上；R63 起唯一的方向性来源就是这一层 |
 * | 亮边 = **0.5vp 发丝** | **0.75vp** 可见亮边 | 参考图亮边明显可见；0.5vp 在 dpr 2.975 下只有 ~1.5px，观感撑不住轮廓 |
 *
 * ⇒ v3 正解 = **半透明磨砂暗玻璃（blur）＋ 一层方向性渐变光（linearGradient）
 * ＋ 一根 0.75vp 可见亮环（radialGradient）＋ 柔和投影**。据此定死：
 * ① **盘面的方向性只由 ② 渐变光层承担**：`linearGradient` 在控件里**恰好 1 处**，
 *  角度/色标全走令牌（`SHEEN_ANGLE` / `SHEEN_MID_STOP`），终点色必须是**同 RGB、alpha=0**
 *  的 `glassSheenClear()`（透明黑会拖灰尾）。
 * ② **亮环永远最锐利**：径向环（内部 alpha 恒 0）画在**渐变层之上**；它是径向的、
 *  且不是玻璃 `backgroundEffect` 的 backdrop（画在下面的兄弟节点会被 6vp 的模糊糊进盘面
 *  —— T9 的「边亮」就是这么来的）。
 * ③ **仍然不要镜面高光层 / rim light / lightEffect**：参考图盘面上没有**半径向**的高光斑，
 *  方向性全部来自 ②；`HIGHLIGHT_*` 四个令牌保持下架（坑 13 顶缘贯穿亮线也仍在禁）。
 * ④ **模糊只此一处**：`backgroundEffect` 的 6 / 1.0 / 1.0 **一个字不许动**（坑 74 禁
 *  `backgroundBlurStyle` / `backdropBlur`）；「半透明」由玻璃色的 alpha 承担。
 *
 * ⚠️ **T9→T11 的实测依据差异**：T9 那轮我按 `a06-session-dark-top.png` 反推（认为主因是
 * 「亮环整盘渐变透过 96% 透明的玻璃层」）。T11 复核时发现**那张图与 `glass-before/b-dark-nocontent.png`
 * 都是 T9 之前的包**（盘面中位数 +97 / +110、且**盘面比环带更亮** —— 这是「整盘泄漏」的指纹，
 * T9 的径向环不可能这样）。T9 的源码修改本身是对的，但**没有上到设备**；
 * 本轮按 Lead 的参考图实测规格重做，不再依赖那两张图反推。
 * ⚠️ R63 补充：紧接上文那套「完全平坦 / 不许有任何渐变」的口径**已被用户明确推翻**（见本节顶部
 * 的 v3 对照表）。这段历史保留是为了说明**当年为什么删掉高光层**，不是让它复活。
 */
export class GlassSpec {
  /**
   * 光环带的宽度（vp）—— R64 由 0.75 加粗到 1.25，**R64-T2 再加宽到 2.5**。
   *
   * ⚠️ R64（v4）：0.75 → **1.25**（要能被 `.blur(ARC_BLOOM)` 散成有宽度的光带）。
   * ⚠️ **R64-T2 定点**：1.25 → **2.5**。真机实测弧峰只有 +29（目标 +72）⇒ 光弧总能量不足；
   * 加宽弧带（能量 ∝ 宽度）＋ 收窄 bloom（`ARC_BLOOM` 4 → 1.5）双管齐下。
   * 2.5vp ≈ 7.4 物理 px（占直径 11.4%）—— 这是**有意**的宽弧，不再是发丝环（`suite-design` 的上限随之放到 15%）。
   */
  static readonly RIM: number = 2.5;
  /**
   * 光环带的三个色标位置（占**渐变半径**的比例；渐变半径 = 组件宽度的 50% = 圆盘半径 R）。
   *
   * ⚠️ R64（v4）：环带由 `RIM`（1.25vp）推出 —— 内部 alpha 恒 0，只有最外那圈有颜色。
   * 盘面的方向性**不再**由盘面内的渐变承担（v3 的铺满层已删），而是由**两段弧的亮度差**：
   * 上半段用 `glassArc*`，下半段用暗一档的 `glassArcDim*`（SPEC §2.2）。
   *
   * ⚠️ **R64-T2**：弧带加宽到 2.5vp ⇒ 三个色标按新 RIM 重算（弧更宽，峰值要往外推）：
   *  · 内沿 = 1 − 2.5/22 = 0.886363… → 取 0.8864（此半径以内 alpha 恒 0）
   *  · 峰值 = 1 − 1.25/22 = 0.943181… → 取 0.9432（弧宽中点；正好等于 v4 的内沿值）
   *  · 外沿 = 1
   * ⚠️ 三个色标必须仍然**严格递增**（`suite-design` 有机械断言）。
   */
  static readonly RIM_STOP_INNER: number = 0.8864;
  static readonly RIM_STOP_PEAK: number = 0.9432;
  static readonly RIM_STOP_OUTER: number = 1;
  /**
   * 光弧的**外发光**半径（vp）—— `GlassIcon.ets` 里两段弧的 `.blur(ARC_BLOOM)`（SPEC §2.2）。
   *
   * ⚠️ `.blur()` 是**通用属性（内容模糊）**，与 `backgroundBlurStyle` / `backdropBlur` 不是一回事：
   * 后两者是「背景模糊」且被坑 74 禁用；本令牌只在**光弧层**用，把硬线散成有宽度的光带
   * （真机验收：弧带宽度 FWHM ≥ 0.10R）。
   * ⚠️ `.blur()` 只在**节点绘制区内**散开 ⇒ 段容器必须四周各留 `ARC_BLOOM` 的余量，
   * 否则外发光会被容器边界切掉（`GlassIcon.ets` 的 `arcBandWidth/Height()` 就是为此）。
   * ⚠️ **R64-T2 定点**：4 → **1.5**。真机实测（深色档，同一脚本口径）弧峰−盘面只有
   * **+61.8 → +29.0/+25.0/+10.0**（目标 **+72**）—— 根因就是 4vp 的 blur 把 1.25vp 的细弧能量摊开；
   * 收窄到 1.5vp、同时把 `RIM` 加宽到 2.5vp，让弧带在 bloom 之后仍保留可观的峰值。
   */
  static readonly ARC_BLOOM: number = 1.5;
  /**
   * ## 渐变光层（R63 v3 新增）—— **R64 起只由顶栏/底栏胶囊消费**
   *
   * ⚠️ R64 变更（SPEC §2.1/§2.3）：v3 里这块铺满盘面的 `linearGradient` 已从 `GlassIcon.ets`
   * **整层删除**（它是「盘面被摊亮成斜面板」的根因）；**令牌与函数一律保留**，
   * 因为 `Components.ets`（顶栏 actionLabel 胶囊）与 `BottomNav.ets`（底栏悬浮胶囊）仍在消费它们。
   * ⇒ 这两处**不要**跟着删；图标钮的方向性改由边缘光弧承担（见 `RIM_STOP_INNER` 与 `glassArc*`）。
   *
   * ⚠️ **ArkUI 的 `linearGradient({ angle })` 语义**：`0` = 由**下到上**，逆时针为正。
   * `145` 的**预期观感 = 光从左上打来、向右下隐去**（参考图口径）——
   * 本机（Windows）无法渲染 ArkUI，**只能上设备截图确认**；
   * 若上设备后发现左右反了（变成右上亮、左下暗），把角度改成 **325**。
   */
  static readonly SHEEN_ANGLE: number = 145;
  /**
   * 渐变光层的中间色标位置（0~1，沿渐变轴从起点「左上」到终点「右下」）。
   *
   * 0.42 让亮部略偏向起点一侧（参考图左上偏亮、右下沉入背景），
   * 而不是把亮暗过渡放在盘面正中。改它必须同时更新 `suite-design` 的色标断言。
   */
  static readonly SHEEN_MID_STOP: number = 0.42;
  /**
   * ## 镜面高光：**整层下架**（R57 / T11）
   *
   * T9 把高光降到 radius 18% / opacity 0.4（有效白 5.6%），但 Lead 的参考图剖面证明
   * **盘面上根本没有任何可辨识的光斑**：r 0.4~0.83R 的中位数恒为 +11（平坦）。
   * 只要留着高光，盘面就必然出现「左上亮斑 + 沿半径的落差」，与「完全平的暗玻璃」直接冲突。
   * ⇒ `HIGHLIGHT_CENTER_X / Y`、`HIGHLIGHT_RADIUS`、`HIGHLIGHT_OPACITY`
   * 四个令牌与对应的高光层、`glass_icon_highlight` / `glass_icon_highlight_clear` 两个色全部删除。
   * 「有内容时」的玻璃质感**不需要靠自发光**：它来自 backdrop 糊化的内容（参考图有内容态 +38~+74）。
   * ⚠️ R63：**高光层仍然保持删除**，但**理由变了** —— 不再拿「盘面必须完全平坦」当判据
   * （该口径已作废，见上方 v3 对照表），而是：① 参考图盘面上没有**半径向**的光斑；
   * ② 盘面的方向性已经由 ② 渐变光层承担，再叠一层偏移高光会出现**两个方向性来源**、观感打架。
   */
  /**
   * ## 光效 = **交互反馈**，不是把盘面画亮（R57 / T13 定稿）
   *
   * 用户第三次反馈「没光效啊，考察系统光效做法」。T13 先用 `stateStyles.pressed.brightness` 试，
   * **真机实测失效**（盘面 +0.0%）—— T15 定因：`stateStyles` 挂在 `hitTestBehavior(HitTestMode.None)`
   * 的装饰层上时**收不到按压事件**，`pressed` 状态永不进入。现在改成
   * **`@State pressed` + 外层可命中节点的 `onTouch` + 显式按压光效层**（见下），只用「画画」的原语。
   * ⚠️ `坑 13` 仍然有效：系统材质 `ImmersiveMaterial` 的 `lightEffect`、以及手写的 rim light
   * （1px 顶缘高亮行）**都会在顶缘合成一条锐利贯穿亮线**，两者都不用。
   *
   * ⚠️ R64 更新：R63 那句「斜向渐变是规格要求」**又被收回** —— v4 把铺满盘面的线性渐变整层删掉，
   * 盘面的方向性改由**边缘弧两段的亮度差**承担（SPEC §2.1/§2.2）；
   * 「偏移高光层 / rim light / `lightEffect`」继续禁止（坑 13 顶缘贯穿亮线仍在）。
   * ⚠️ T13 的角向剖面（35/35/35/35）与 R63 的 v3 光层各自对应**当时那一轮的包**，不要互相拿当判据。
   *
   * 落地分两半（**T13 定稿**）：
   * ① **形变**交给官方 `clickEffect({ level: ClickEffectLevel.LIGHT })` ——
   *  SDK（`common.d.ts:15934` / `enums.d.ts:3756`）明确写了系统默认缩放：
   *  `LIGHT = 0.90`、`MIDDLE / HEAVY = 0.95`、`undefined / null` 按 LIGHT 处理（0.90）。
   *  **不自己拍一个 scale**（自绘 0.96 与系统默认不是一回事，而且系统那套自带缓动与硬件路径）。
   *  ⚠️ SDK 同处给了两条 NOTE，必须实测：①组件尺寸动态变化时别用；②**缩放后触点可能落到控件外，
   *  导致连续点击失效** ⇒ 32~54vp 的小按钮要实机确认「按一次后还能连续点」。
   * ② **提亮**交给一层**显式按压光效层**（`GlassIcon.ets` 的 ③ 层）：
   *  `backgroundColor(glassIconPressGlow()) + opacity(this.pressed ? 1 : 0)`，
   *  `pressed` 由**外层可命中节点**的 `onTouch` 驱动（`Down` 置真、`Up/Cancel` 置假）。
   *
   *  **为什么用「覆盖层」而不是 `brightness` 滤镜（T15 定稿，两次真机失败的教训）**：
   *  · T13 的方角缺陷证明 `brightness` 会作用到**节点盒子的矩形区域**；
   *  · T14 把 brightness 下沉到圆形玻璃层后四角确实回到背景值，**但那一轮的 `pressed` 从未进入**
   *  （它挂在 `hitTestBehavior(None)` 的层上）⇒ **「滤镜会不会遵守 borderRadius 裁剪」至今没有真机证据**；
   *  · 而 `backgroundColor` 被 `borderRadius` 裁成圆，是本工程**已被真机验证**的事实
   *  （列表行 `rowPressedSurface()` 的按压底色、`AaCircleIconButton` 的圆形实底都是这条）；
   *  `opacity` 的 0/1 切换更是最普通的绘制原语。
   *  ⇒ 覆盖层方案里**没有任何未验证的语义**，「方角」在构造上不可能出现。
   *
   *  ⚠️ 深浅两态**方向相反**，这是物理决定的（不是随手取反）：
   *  · 深色（盘面 19.06、页面 9.14）：白覆盖层 `#0AFFFFFF`（3.92%）⇒ **+48.5%**，玻璃「亮起来」；
   *  · 浅色（盘面 239.4、页面 252.07）：白覆盖层**最多只能提到 252（+5.4%）**，物理上做不出 +10% 的提亮
   *  ⇒ 浅色改取黑覆盖层 `#14000000`（8%）⇒ **−8.0%**，按下时玻璃「沉下去」（也是 iOS 浅色玻璃的约定）。
   */
  static readonly PRESS_ANIM_MS: number = 140;
  /**
   * ⚠️ `PRESSED_OPACITY = 0.72` **已退役**（T13）。
   * 理由：整体降不透明度是把钮「往背景里掺」= **减光**，与「按下要更亮、更有形变」的系统光感**方向相反**；
   * 而且它同时把 backdrop 糊化的内容一起压暗（用户看到的是「按下去变灰」而不是「亮起来」）。
   * 现在按下 = `clickEffect(LIGHT)` 的形变 + ③ 光效层的透明度切换，**本组件的不透明度恒为 1**；
   * 不透明度只留「不可用」一档（与 `AaCircleIconButton` 同值 0.4）。
   */
  /** 不可用态不透明度 —— 与 `AaCircleIconButton` 的 0.4 取同一个值，两档不各写一套。 */
  static readonly DISABLED_OPACITY: number = 0.4;
  /** 柔和外阴影半径 / Y 偏移 —— 只挂在玻璃主体那一层上（坑 79：别层层叠阴影）。 */
  static readonly SHADOW_RADIUS: number = 10;
  static readonly SHADOW_OFFSET_Y: number = 2;
}

/** 毛玻璃层的玻璃色（浅色 #40FDFCFB / 深色 #1F0A0A0C，alpha 即"透不透"的唯一旋钮）。 */
export function glassSurface(): Resource {
  return $r('app.color.glass_surface');
}

/**
 * **悬浮功能底栏**（`ui/BottomNav.ets` 的 `AaBottomNav` 整条胶囊）的玻璃色。
 *
 * ## R63/F1 的原始结论（为什么不能复用 `glassSurface()`）
 * 模拟器逐点实测（开发期验证记录 §9 F1）：R63 首包浅色档底栏胶囊盘面
 * **252.1 = 页面背景 252.1**（逐点相同），只剩 1vp 亮边 —— 沉浸光感在浅色档**实际不可见**。
 * 根因是浅色 `glass_surface` = `#40FDFCFB`（**25% 近白**）叠在近白页面上零对比。
 *
 * ## R90-T4：用户「底部功能栏有点发暗，调亮一点」⇒ 两档都调亮
 *
 * ### 浅色：7.8% 黑纱（`#14`）→ **5.9% 黑纱（`#0F`）**
 * 原值 Δ ≈ **−19.7/255** 偏实（比同屏圆钮那档 −12 更暗），用户观感就是"发暗"。
 * 新值 252.07 × 0.059 ≈ **−14.9/255** ⇒ **刚好压住可见性下限**（`suite-design` 判据 ≥15，
 * 实测 Δ=0 才是真正的缺陷档），既比原来亮、又不至于糊成一片看不见。
 *
 * ### 深色：近黑纱 `#1F0A0A0C` → **白纱 `#1FFFFFFF`**
 * ⚠️ 这是本轮**唯一"推翻旧口径"**的一处，理由写清楚：
 * 深色档要"调亮"，方向**必须反过来** —— 在近黑画布（实测背景 9.7）上叠一层**近黑**纱
 * （`#1F0A0A0C` 合成后 ≈ 13.2）**几乎不产生提亮**，这正是"发暗"的来源。
 * 换成 12% **白**纱后：9.7 + 0.122 × (255 − 9.7) ≈ **39.6 ⇒ Δ ≈ +30/255**，是明确可见的提亮。
 * ⚠️ 旧注释写的「深色观感必须逐像素不变」是**当时**（R63）为了"别把深色带偏"的保护性约束；
 * 本轮用户**明确要求调亮**，该约束的前提已变 ⇒ 有意推翻，并把 `suite-design` 的
 * 「深色两键同值」断言改成「深色底栏是一层**亮**纱（白纱、Δ 为正）」。
 */
export function glassNavSurface(): Resource {
  return $r('app.color.glass_nav_surface');
}

/**
 * R90-T4：底栏**选中项**的强调色（用户：「底部功能栏增加被选中的页面图标变绿」）。
 *
 * ⚠️ **为什么要单独一个令牌，不直接复用 `session_status_accent`**：
 * 工程里原有的绿色（`session_status_accent` / `runtime_running`）是**会话状态**的语义色，
 * `Design.ets` 的 `deepseekAccent()` 注释已明确写过「语义色与品牌/导航色**不要互相顶替**」。
 * 底栏选中是**导航态**，与"会话正在跑"不是一回事 —— 共用会让以后调色互相牵制
 * （把状态绿调深就会连带把底栏调暗）。⇒ 独立令牌，取值也与状态绿**刻意错开**：
 * · 浅色 `#0E9F6E`（比 `session_status_accent` 的 `#18866A` 更鲜、在近白底上更跳）；
 * · 深色 `#34D399`（比状态绿的 `#39A887` 亮一档 —— 深色画布上够亮才看得出来）。
 */
export function bottomNavActive(): Resource {
  return $r('app.color.bottom_nav_active');
}

/** 悬浮玻璃按钮的底（比毛玻璃层实一些，保证图标在任意内容上可读）。 */
export function glassButtonSurface(): Resource {
  return $r('app.color.glass_button_surface');
}

/**
 * 玻璃**卡片**的底（输入框那类「外框围起来一块」的控件，alpha ≈ 70%）。
 *
 * ⚠️ 与 `glassSurface()`（顶栏/浮层那层薄玻璃，alpha 12~25%）**不是一回事**：
 * 卡片里要放正文（输入内容、placeholder），太透就压不住背后的滚动文字。
 */
export function glassCardSurface(): Resource {
  return $r('app.color.glass_card_surface');
}

/**
 * 整块浮层面板的底（alpha ≈ 85%，比卡片更实）。
 *
 * 面板盖住的是**成片正文**，底色太透会让字与背后的文字互相干扰（用户原话「有点看不清字了」）；
 * 85% + `GLASS_PANEL_BLUR` 的组合既能保住毛玻璃质感，又能让面板里的字清楚。
 */
export function glassPanelSurface(): Resource {
  return $r('app.color.glass_panel_surface');
}

/**
 * 液态玻璃**控件**的磨砂底（圆形功能钮 / 圆角玻璃块）。
 *
 * ⚠️ 与 `glassButtonSurface()`（alpha ≈ 70%，给「压在有正文的输入卡上的圆钮」用，
 * 见会话详情页）**不是一回事**：那一档要保证图标压得住背后的正文；这一档是**功能栏里的玻璃钮**，
 * 钮自己的发光**必须近乎为零**，亮度全部交给 backdrop 糊化后的背后内容。
 *
 * ⚠️ R57（T13）：**浅色改成「极淡的深纱」2% 黑**（`#05000000`）。
 * 原因（T12 真机实测）：浅色盘面 Δ ≈ **0**（8% 白叠在 252 底上等于没叠）⇒ 参考图那种「几乎隐形」
 * 在浅色下变成了**完全不可见**，1× 视距只剩那根 0.5vp 环撑着。改成 2% 黑之后：
 * 背景 252 × 0.97（3% 投影）× 0.98（2% 纱）= **239.9 ⇒ Δ = −12.2**（判据 |Δ| ≤ 15），
 * 盘面均匀变暗，近白页面上能看出一个淡灰圆盘。
 * ⚠️ R64（v4，**本轮主修复**）：深色 4.3% 白（`#0BFFFFFF`）→ **1.2% 白（`#03FFFFFF`）**。
 * 依据（SPEC §1/§4，同一脚本口径的真机实测）：v3 盘面 Δ **+24.0**（等效白 α 10.9%），
 * 是参考图（+1.5~+3.9 / 0.7~1.8%）的**约 6 倍** ⇒ 钮看起来像「发灰的塑料盘」。
 * 降到 1.2% 后的模型预测：9.14 × 0.92（8% 投影）= 8.41 ⇒ 8.41 × (1−0.0118) + 255 × 0.0118 = **+2.2/255**
 * （验收线：盘面 Δ ≤ +8、等效白 α ≤ 3%）。**浅色档一律不动**（`#0E000000`）——
 * R63/F1 已按浅色校准，浅色再改暗会回到「完全隐形」，那是另一个议题。
 * ⚠️ 这一档只管「纱有多实」，它本身是均匀的；盘面的方向性由 `GlassIcon.ets` 的**边缘光弧**承担，
 * 不要再往这一档里塞渐变/斜向（v3 的铺满渐变正是本轮要治的缺陷 2）。
 * ⚠️ alpha 是**唯一**的自发光旋钮 —— 想让它更隐形就降这里，**不要**去动 `backgroundEffect`。
 */
export function glassIconSurface(): Resource {
  return $r('app.color.glass_icon_surface');
}

/**
 * 主色玻璃钮的底（悬浮「+」那类**强动作**钮的玻璃档）。
 *
 * 为什么单独一档：主色钮要保持高对比（浅色深底白图标 / 深色浅底深图标），
 * 用 25% 的 `glassIconSurface()` 会让图标直接糊在玻璃上不可读 ⇒ 取主色的 85% 不透明度，
 * 既留住 15% 的透光，又保证图标对比度。
 */
export function glassPrimarySurface(): Resource {
  return $r('app.color.glass_primary_surface');
}

/**
 * 玻璃钮**发丝亮环**的两个色（环的峰值色 / 内沿色）+ 「**同 RGB、alpha = 0**」的环内透明色。
 *
 * ⚠️ R63（v3，SPEC §2.2）：环加粗到 0.75vp，深色峰值随之加亮到参考图口径：
 *  · `glass_icon_rim_high` = 环的**峰值**色，深色 **40% 白**（`#66FFFFFF`，原 30% `#4DFFFFFF`）
 *  —— 参考图的亮边明显可见，30% 在加粗后的宽环上偏弱；
 *  · `glass_icon_rim_low` = 环**内沿**色，深色 12% 白（不动）：从内沿到峰值有个渐入，
 *  免得环出现硬边锯齿；
 *  · `glass_icon_rim_clear` = 环内部的 alpha=0 色。**不能用 `Color.Transparent`**
 *  （透明黑，插值会把环内沿拖出一道灰边）。环内沿以内**必须恒为 0**。
 *
 * ⚠️ 浅色侧这三个值与深色**语义不同**：浅底上白环不可见，所以浅色用**暗环**勾轮廓
 * （R63：峰值 18% 黑 → **24% 黑** `#3D000000` 加粗后同步加深；内沿 4% 黑不动）
 * —— 参考图只给了深色图，浅色按「细边勾轮廓」的原理推，判据是「盘面 |Δ| ≤ 15」而不是「亮边」。
 * ⚠️ R64：图标钮的光环已改走 `glassArc*` 五个新色（见下），本组 `glassRim*` 在 R64 之后由
 * **顶栏胶囊 / 底栏胶囊的亮边**消费（`Components.ets` / `BottomNav.ets`）—— **函数与色键一律保留**，
 * 不要因为图标钮不再引用就顺手删掉（SPEC §2.3「保留（不许删，别人在用）」）。
 */
export function glassRimHigh(): Resource {
  return $r('app.color.glass_icon_rim_high');
}

export function glassRimLow(): Resource {
  return $r('app.color.glass_icon_rim_low');
}

export function glassRimClear(): Resource {
  return $r('app.color.glass_icon_rim_clear');
}

/**
 * ## 边缘光弧的五个色（R64 v4）—— **上亮 / 下暗**两段半环的色标
 *
 * `GlassIcon.ets` 的 ② 光弧层：两段共用同一套径向环几何，只换色档（SPEC §2.2）：
 *  · 上段（左上偏亮）：`glassArcHigh()`（外沿 / 峰值）＋ `glassArcLow()`（内沿）；
 *  · 下段（弱一档）：`glassArcDimHigh()` ＋ `glassArcDimLow()`；
 *  · 两段共用的透明色：`glassArcClear()` —— **同 RGB、alpha = 0**，写在环内沿以内（`RIM_STOP_INNER`）。
 *
 * ⚠️ 透明色**不能**写 `Color.Transparent`（透明黑）：插值会把弧内沿拖出一道灰尾
 * （与 `glassRimClear()` / `glassSheenClear()` 是同一条教训）。
 * ⚠️ **R64-T3 取值（当前，标定自真机）**：R64-T2 把弧色提到 65%/30% 后真机**过冲**
 * —— 环峰 − 盘面实测 **+134/+132**（超 SPEC §4 上限 +90 约 1.5 倍）。按「几何 / 定位 / 段数
 * 一律不动、**只降弧色 alpha**」回吐到标定值：
 *  · 上段弧峰 65% → **35% 白**（`#59FFFFFF`）、内沿 30% → **16% 白**（`#29FFFFFF`）；
 *  · 下段（dim）**12% 白**（`#1FFFFFFF`）/ **5% 白**（`#0DFFFFFF`）
 *  ⇒ 保住「上/下亮度比」在 ≈2.7~2.9 量级（v5 验收线 ≥ 1.8）。
 *  · 浅色档（base）同比回吐：上段 40% → **22% 黑**（`#38000000`）、20% → **11%**（`#1C000000`），
 *  dim `#12000000`（7% 黑）/ `#0A000000`（4% 黑）。
 *  · 预期（用 R64-T2 真机标定的 φ=0.845 换算）：环峰 − 盘面 ≈ **+72**（正是 SPEC §4 目标）。
 *  ⚠️ 浅色这组**仍未上过设备**（参考图只有深色图）—— 已列入 T3 风险点。
 *  ⚠️ 历史：27%/12%（v4）→ 65%/30%（T2）→ **35%/16%（T3，当前）**。
 *  改这组数**只改 `color.json`**，不要动 geometry/定位（否则「是颜色还是几何起作用」就说不清）。
 */
export function glassArcHigh(): Resource {
  return $r('app.color.glass_icon_arc_high');
}

export function glassArcLow(): Resource {
  return $r('app.color.glass_icon_arc_low');
}

export function glassArcDimHigh(): Resource {
  return $r('app.color.glass_icon_arc_dim_high');
}

export function glassArcDimLow(): Resource {
  return $r('app.color.glass_icon_arc_dim_low');
}

export function glassArcClear(): Resource {
  return $r('app.color.glass_icon_arc_clear');
}

/**
 * ## 渐变光层（R63 v3）的三个色 —— 都必须与终点色**同 RGB、alpha 递减到 0**
 *
 * `GlassIcon.ets` 的 ② 层的色标（起点 → 中间 → 终点）：
 *  · `glassSheenHigh()` = 起点（**左上**，光最实的一档）；
 *  · `glassSheenMid()` = 中间色标 `SHEEN_MID_STOP` 处；
 *  · `glassSheenClear()` = **终点**（右下）—— **alpha 必须 = 0 且 RGB 与上面两档相同**。
 *
 * ⚠️ 终点**不能**写 `Color.Transparent`（透明黑）：它在插值时会先把色相拖向黑，
 * 渐变尾部会出现一道灰尾（与 `glassRimClear()` 是同一条教训）。
 * ⚠️ 也不要在控件里直接 `$r('app.color.*')` —— 颜色一律走本文件的函数（`suite-design` 有白名单断言）。
 *
 * 两档取值（SPEC §2.2）：浅色用「亮 + 极淡」两个白档（白纱在近白底上提亮不可见，靠盘面自身的
 * 深纱显出层次）；深色左上的光更实、右下沉入背景。
 */
export function glassSheenHigh(): Resource {
  return $r('app.color.glass_icon_sheen_high');
}

export function glassSheenMid(): Resource {
  return $r('app.color.glass_icon_sheen_mid');
}

export function glassSheenClear(): Resource {
  return $r('app.color.glass_icon_sheen_clear');
}

/**
 * 玻璃钮自己的**投影**色 —— **不要**用 `appShadow()`。
 *
 * ⚠️ `shadow()` 画在组件**后面**，而玻璃主体只有 ~96% 透 ⇒ **投影会从盘面内部透出来**，
 * 它同时决定「盘面亮度」与「投影强度」两件事，所以必须与 `appShadow()` 分开。
 *
 * ⚠️ R57（T11）：参考图的盘面**中位数恒定 35**（完全平坦）⇒ 投影对盘面的影响要尽量小。
 *  · 深色 **8% 黑**（`#14000000`）：9.14 × 0.92 ⇒ 盘面 −0.7，投影本身在深底上也几乎没有代价；
 *  · 浅色 **3% 黑**（`#08000000`）：252 × 0.97 ⇒ 盘面 −6.8（|Δ| ≤ 15 ✓）。
 *  投影在浅色下还会给盘面带来 **±4/255 的径向起伏**（投影的轮廓在盘面下有梯度）——
 *  这是「盘面完全平」在浅色下唯一做不到的地方，如实记在 T11 报告里。
 * 想调「盘面多暗 / 投影多重」就调这一个令牌，别去动坑 79 挂阴影的那一层的位置。
 */
export function glassIconShadow(): Resource {
  return $r('app.color.glass_icon_shadow');
}

/**
 * 按压**光效层**的覆盖色（R57 / T15）。
 *
 * `GlassIcon.ets` 的 ③ 层：一块**圆形**覆盖层，`opacity` 由 `@State pressed` 在 0 / 1 之间切换，
 * `PRESS_ANIM_MS`（140ms EaseOut）淡入淡出。
 *
 * **为什么是覆盖层而不是 `brightness`**：T13 的方角缺陷说明 `brightness` 作用在**节点盒子的矩形区域**上；
 * T14 虽然把四角修回背景值，但那一轮 `pressed` 从未进入（挂在 `hitTestBehavior(None)` 的层上）⇒
 * 「滤镜是否遵守 `borderRadius` 裁剪」**至今没有真机证据**。而 `backgroundColor` 被圆角裁成圆是
 * 本工程**已真机验证**的事实。所以改用「只能被裁成圆」的覆盖层，去掉最后一个未验证语义。
 *
 * ⚠️ 深浅两态方向相反（物理决定）：深色 3.92% 白 ⇒ 盘面 **+48.5%**（亮起来）；
 * 浅色 8% 黑 ⇒ 盘面 **−8.0%**（沉下去）—— 浅色盘面 239.4 距页面 252.07 只有 +5.4% 的提亮天花板，
 * 白覆盖层**在浅色下物理上做不出可见的提亮**。
 */
export function glassIconPressGlow(): Resource {
  return $r('app.color.glass_icon_press_glow');
}

/**
 * DeepSeek 品牌蓝 —— 「深度求索中…」那行状态文字用它（用户给的参考图就是蓝色）。
 *
 * ⚠️ 工程里原有的强调色（`session_status_accent` / `runtime_running`）全是**绿**的，
 * 那是「会话状态」的语义色；这一处是**品牌标识**，两者不要互相顶替。
 * 深色下提亮到 `#7B93FF` 以保证对比度。
 */
export function deepseekAccent(): Resource {
  return $r('app.color.deepseek_accent');
}

export function primaryAction(): Resource {
  return $r('app.color.primary_action');
}

export function onPrimaryAction(): Resource {
  return $r('app.color.on_primary_action');
}

/** 会话状态点颜色。 */
export function statusColor(status: string): Resource {
  if (status === 'running') {
    return $r('app.color.runtime_running');
  }
  if (status === 'waiting_approval') {
    return $r('app.color.notice_warning');
  }
  if (status === 'waiting' || status === 'pending') {
    return $r('app.color.runtime_transitioning');
  }
  if (status === 'error') {
    return $r('app.color.error_text');
  }
  return $r('app.color.faint');
}

export function runtimeStatusColor(status: string): Resource {
  if (status === 'running') {
    return $r('app.color.runtime_running');
  }
  if (status === 'starting' || status === 'validating' || status === 'discovering' || status === 'stopping') {
    return $r('app.color.runtime_transitioning');
  }
  if (status === 'error' || status === 'unavailable') {
    return $r('app.color.error_text');
  }
  if (status === 'available') {
    return $r('app.color.runtime_active');
  }
  return $r('app.color.faint');
}

/**
 * 系统栏避让高度（单位 **px**）在 `AppStorage` 里的键。
 *
 * 数据流：`EntryAbility.pushSafeAreaInsets()` 用 `window.getWindowAvoidArea(TYPE_SYSTEM)` 读到
 * 状态栏 / 手势条高度后写进来；`pages/Index.ets` 用 `@StorageLink` 读出来做根节点的 `padding`
 * （`px2vp()` 换算成 vp）。**不允许写死像素**：横竖屏、手势条显隐、不同机型都会变。
 *
 * 为什么必须显式避让（R13-12 真机返工的结论）：本工程要沉浸（`setWindowLayoutFullScreen(true)`），
 * 而鸿蒙在沉浸态下**不会**替应用避让系统栏；`expandSafeArea` 的语义是「**取消**避让」，
 * 它的反命题（不写它就自动避让）**不成立** —— 真机 dump：搜索图标 y=51、标题被压进状态栏只剩 7px 高。
 * 所以「系统栏区域显示页面底色」与「内容留在安全区内」必须**显式成对**做：
 * 前者由 `EntryAbility.syncSystemBarColors()`（系统栏配色）承担，后者由本键驱动的 padding 承担。
 */
export const SAFE_AREA_TOP_PX: string = 'aaSafeAreaTopPx';
export const SAFE_AREA_BOTTOM_PX: string = 'aaSafeAreaBottomPx';

/**
 * 运行时状态文案 —— 逐字对齐上游 `DeviceDetailScreen.kt:816-832` 的 `runtimeStatusLabel`
 * （中文取自 `values-zh-rCN/strings.xml` 的 `device_runtime_*`）：
 * `已停止` / `发现中` / `可用` / `不可用` / **`正在验证配置`** / `启动中` / `运行中` / `停止中` /
 * **`运行时错误`** / **`未知状态`**。
 *
 * ⚠️ 上游**没有短名机制**，这四条更长的文案是原样使用的；容器放不下时应当换行/省略，
 * 不要为了排版自创短名（`validating` 的 11 个字就是上游原文）。
 * 另外「运行时不存在」不是这里的分支：上游走 `device_runtime_not_present`
 * 「连接器上不存在此运行时」，由调用方在 `!present` 时给（见 `DeviceDetailScreen.runtimeSubtitle`）。
 */

/**
 * 对话框规格（R13-14）—— 逐项对齐上游**自绘** Dialog 的常数，单位 vp（字号 fp）：
 * 取 `SessionDetailScreen.kt:2052-2126` 的 `TakeoverConfirmDialog` + `TakeoverDialogButton`（`:2129-2153`）。
 *
 * 为什么要令牌化：本工程原先一律用系统 `showAlertDialog`（不指定任何尺寸 ⇒ 全走 ArkUI 默认），
 * 安卓是自绘、尺寸是明确规格，于是「只读模式对话框那么大」。令牌化后既能逐项对账，也能进 Node 断言。
 */
export class DialogSpec {
  /** 与屏左右边距（上游 `.padding(horizontal = 22.dp)`）。 */
  static readonly SCREEN_MARGIN: number = 22;
  /** 最大宽度（上游 `.widthIn(max = 380.dp)`）。 */
  static readonly MAX_WIDTH: number = 380;
  /** 圆角（上游 `RoundedCornerShape(26.dp)`）。 */
  static readonly RADIUS: number = 26;
  /** 内边距（上游 `.padding(22.dp)`）。 */
  static readonly PADDING: number = 22;
  /** 元素纵向间距（上游 `Arrangement.spacedBy(18.dp)`）。 */
  static readonly CONTENT_GAP: number = 18;
  /** 阴影半径（上游 `.shadow(34.dp, shape, …)`；色值用 `app.color.app_shadow`）。 */
  static readonly SHADOW_RADIUS: number = 34;
  /** 边框宽度（上游 `.border(1.dp, colors.border, shape)`）。 */
  static readonly BORDER_WIDTH: number = 1;
  /** 标题字号 / 行高（上游 `24.sp / ExtraBold / lineHeight 29.sp`）。 */
  static readonly TITLE_SIZE: number = 24;
  static readonly TITLE_LINE_HEIGHT: number = 29;
  /** 正文字号 / 行高（上游 `15.sp / Medium / lineHeight 21.sp`）。 */
  static readonly BODY_SIZE: number = 15;
  static readonly BODY_LINE_HEIGHT: number = 21;
  /** 按钮行 top（上游 `.padding(top = 6.dp)`）。 */
  static readonly BUTTON_TOP: number = 6;
  /** 两按钮间距（上游 `Arrangement.spacedBy(10.dp)`）；宽度各 `weight(1f)` ⇒ 1:1。 */
  static readonly BUTTON_GAP: number = 10;
  /** 按钮高度 / 圆角（上游 `TakeoverDialogButton`：`height(50.dp)`、`RoundedCornerShape(16.dp)`）。 */
  static readonly BUTTON_HEIGHT: number = 50;
  static readonly BUTTON_RADIUS: number = 16;
  /** 按钮文字（上游 `15.sp / Bold / lineHeight 19.sp`）。 */
  static readonly BUTTON_TEXT_SIZE: number = 15;
  static readonly BUTTON_TEXT_LINE_HEIGHT: number = 19;

  /**
   * 对话框实际宽度 = `min(380, 屏宽 - 44)` ——
   * 上游是 `widthIn(max = 380.dp)` 叠加 `padding(horizontal = 22.dp)`，窄屏时由边距决定。
   * 屏宽拿不到（`display` 抛异常）时返回最大宽，调用方再用兜底屏宽算一次，结果仍是 380。
   */
  static widthFor(screenWidthVp: number): number {
    const available = screenWidthVp - DialogSpec.SCREEN_MARGIN * 2;
    if (available <= 0) {
      return DialogSpec.MAX_WIDTH;
    }
    return available < DialogSpec.MAX_WIDTH ? available : DialogSpec.MAX_WIDTH;
  }
}


/**
 * Profile 族对话框规格（R13-14）—— 取上游 `ui/screens/profile/ProfileSettingsDialogs.kt`：
 * `ProfileDialog`（`:93-124`）+ `ConfirmSignOutDialog`（`:77-91`）+ `ProfileDialogButton`（`:174-200`）。
 * 与确认族（`DialogSpec`）的差别：`fillMaxWidth`（无 380 上限）、圆角 20（非 26）、内边距 18（非 22）、
 * 元素间距 14（非 18）、标题 20sp SemiBold（非 24sp ExtraBold）、按钮 46/14（非 50/16）、**无阴影**。
 */
export class ProfileDialogSpec {
  /** 与屏左右边距（上游 `.padding(horizontal = 22.dp)`）。 */
  static readonly SCREEN_MARGIN: number = 22;
  /** 圆角（上游 `RoundedCornerShape(20.dp)`）。 */
  static readonly RADIUS: number = 20;
  /** 内边距（上游 `.padding(18.dp)`）。 */
  static readonly PADDING: number = 18;
  /** 元素纵向间距（上游 `Arrangement.spacedBy(14.dp)`）。 */
  static readonly CONTENT_GAP: number = 14;
  /** 标题 20sp / lineHeight 24sp（上游 `fontSize = 20.sp, fontWeight = SemiBold`）。 */
  static readonly TITLE_SIZE: number = 20;
  static readonly TITLE_LINE_HEIGHT: number = 24;
  /** 正文 14sp / lineHeight 19sp（上游 `ConfirmSignOutDialog` 的 body）。 */
  static readonly BODY_SIZE: number = 14;
  static readonly BODY_LINE_HEIGHT: number = 19;
  /** 按钮间距（上游 `ConfirmSignOutDialog` 的 `spacedBy(10.dp)`）。 */
  static readonly BUTTON_GAP: number = 10;
  /** 按钮高 46 / 圆角 14 / 14sp SemiBold（上游 `ProfileDialogButton`）。 */
  static readonly BUTTON_HEIGHT: number = 46;
  static readonly BUTTON_RADIUS: number = 14;
  static readonly BUTTON_TEXT_SIZE: number = 14;

  /** 取不到屏宽时的兜底宽度（vp）—— 与 `DialogSpec.MAX_WIDTH` 同量级，窄屏下仍安全。 */
  static readonly FALLBACK_WIDTH: number = 300;

  /** Profile 族按 `fillMaxWidth` 铺满：宽度 = 屏宽 − 两侧 22。 */
  static widthFor(screenWidthVp: number): number {
    const available = screenWidthVp - ProfileDialogSpec.SCREEN_MARGIN * 2;
    return available > 0 ? available : ProfileDialogSpec.FALLBACK_WIDTH;
  }
}

/**
 * 对话框底色（上游 `LocalAAColors.dialogSurface`：浅色 `#FFFFFF` / 深色 `#242424`）。
 * 放在这里而不是在组件里直接 `$r(...)`：`Components.ets` 的颜色契约是**一律走 Design 函数**
 * （`suite-design.mjs` 的白名单断言），直接写资源名会红。
 */
export function dialogSurface(): Resource {
  return $r('app.color.dialog_surface');
}

/** 对话框阴影色（上游 `LocalAAColors.appShadow`：`#22000000` / `#52000000`）。 */
export function appShadow(): Resource {
  return $r('app.color.app_shadow');
}

export function runtimeStatusLabel(status: string): string {
  switch (status) {
    case 'stopped': return '已停止';
    case 'discovering': return '发现中';
    case 'available': return '可用';
    case 'unavailable': return '不可用';
    case 'validating': return '正在验证配置';
    case 'starting': return '启动中';
    case 'running': return '运行中';
    case 'stopping': return '停止中';
    case 'error': return '运行时错误';
    default: return '未知状态';
  }
}
