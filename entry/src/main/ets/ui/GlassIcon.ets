/**
 * 液态玻璃功能钮 —— **本工程玻璃控件的唯一实现**（参考图：深色顶栏上一排半透明磨砂圆钮）。
 *
 * ## ⚠️ 设计原理（R64 沉浸光感 v4 —— 治「灰塑料盘」，把光收回到边缘弧）
 * 用户第二轮反馈（R64）：「**光效差距比较大，继续优化**」（参考图 + 真机截图对照）。
 * 同一脚本口径实测（SPEC §1）：真机盘面 Δ **+24.0**、等效白 α **10.9%** ⇒ 比参考图（+1.5~+3.9 / 0.7~1.8%）
 * **亮约 6 倍**，钮成了「发灰的塑料盘」；v3 的 `linearGradient` 还把光**铺满整盘**
 * （盘面 24 扇区极差 **36** vs 参考 **7**）；环几乎整圈均匀（上/下 **0.98**，参考 **2.9**）且没有外发光。
 * 冻结规格：开发期规格文档。
 * `backgroundEffect` 的 radius / saturation / brightness **一个字都不许动**（6 / 1.0 / 1.0）。
 * ⚠️ **v3 的「铺满盘面的渐变光层」已整层删除**（SPEC §2.1 ❌）：本轮把光收回到**只在边缘**。
 *
 * ## 为什么单独一个文件
 * 四层（磨砂 / 光弧 / 按压光效 / 外阴影）如果让顶栏 / 圆形图标钮 / 悬浮钮各拼一遍，
 * 就会变成三份实现、三个参数、三种观感（正是用户投诉的「图标设计不统一」）。所以**只在这里画一次**，
 * `AaTopBar` 的返回钮、`AaCircleIconButton` 的玻璃档、`AaFloatingButton` 的玻璃档
 * 全部委托到本组件（Components.ets 里那两处只是**参数映射**，不是第二套实现）。
 *
 * ## 四层的叠放顺序（Stack 由下到上）—— **顺序本身就是规格**
 * | 层 | 节点 | 作用 |
 * | --- | --- | --- |
 * | ① 玻璃主体 | `Row` 全尺寸 | `backgroundEffect` 磨砂 + 玻璃色（**自发光降到 1.2% 白**）+ **投影**（唯一一处） |
 * | ② **光弧层**（v4 新增） | 两段半高 `Stack`（上 / 下），各含全尺寸径向环 + `.blur(ARC_BLOOM)` | **上亮 / 下暗**两段半环 + 外发光；`linearGradient` 在本文件归零 |
 * | ③ 按压光效层 | `Row` 全尺寸 + `backgroundColor` | 按下时整块玻璃「亮起来」（`@State pressed` 驱动） |
 * | ④ 图标 | `Column` + `AaIcon` | Lucide 矢量图标（坐标空间铁律见 `ui/Icon.ets` 文件头） |
 *
 * ⚠️ **装饰层必须画在玻璃上面**：`backgroundEffect` 会把**画在它下面的兄弟节点**一起糊进来。
 * T9 把环放在玻璃下面 ⇒ 6vp 的模糊把环糊进盘面外圈，盘面边缘被染亮、看起来像「金属球」。
 * 所以 ② 光弧层 / ③ 按压光效层**全部画在玻璃之上**：玻璃的 backdrop 只剩它背后的页面内容。
 * ⚠️ 层序按 SPEC §2.1：**光弧在按压光效层之下**（v3 是「环在按压层之上」，v4 明确调换）。
 *
 * ## 硬约束（都是工作区/本工程已经实证过的结论，不要「优化」掉）
 * ① **磨砂必须用 `backgroundEffect`**，不能用 `backgroundBlurStyle`（材质，自带近不透明遮罩并接管
 *  `backgroundColor`，坑 74），也不能用 `backdropBlur`（没有深浅色旋钮）。
 * ② **不要 `lightEffect`、不要「顶缘一条 1px 高亮直线」**（坑 13 真机上会合成锐利贯穿亮线），
 *  也**不要镜面高光层**：盘面的方向性**只**由 ② 光弧层的**上下两段亮度差**承担（SPEC §2.2）。
 * ③ **`linearGradient` 在控件里归零**（v3 的铺满渐变整层删除，它是「盘面被摊亮」的根因）；
 *  弧的透明色一律用 `glassArcClear()`（**同 RGB、alpha = 0**），**不用** `Color.Transparent`
 *  —— 后者是「透明黑」，插值会把弧内沿拖出一道灰边。
 * ④ **光弧段的几何**（SPEC §2.2 + Lead R64 几何补充 + **R64-T2 定位修正**）：
 *  段容器 `d + 2×BLOOM` × `d/2 + BLOOM`（四周各留 BLOOM ⇒ 外发光才散得开），内层全尺寸环靠
 *  `ringPadTop/Bottom` 顶到上半 / 下半，容器 `.clip(true)` 沿**水平中线**切成半圈。
 *  ⚠️ **还必须给容器加 `boxPadTop/Bottom`**：外层 `Stack` 默认把子节点**居中**，两个半高容器会被
 *  各自居中 ⇒ 两段圆心各偏 ±(d/4 + B/2)，弧被搬到左下 / 右下（R64-T2 真机实测：顶部 ≈ 背景）。
 *  规则：**上段容器 `{top:0, bottom:H}`、下段容器 `{top:H, bottom:0}`**（H = 容器高度），
 *  让「上段容器底 / 下段容器顶」正好压在钮心那条水平切线上。
 * ⑤ 四层铺满型节点（玻璃主体 + ② 的两段 + ③）都是**铺满型兄弟节点**，必须显式 `hitTestBehavior(HitTestMode.None)`，
 *  否则会把点击吃在装饰层上（坑 29 / 坑 151：铺满的兄弟容器照样参与命中测试）。
 *  ⚠️ 但**驱动按压态的 `onTouch` 必须挂在外层（唯一可命中）节点上** —— 装饰层收不到事件（T15 真机定因）。
 * ⑥ 颜色**一律走 `Design` 的双值资源函数**（`color.json` base/dark 各一份），不在这里写死色值。
 * ⑦ 按压反馈 = 官方 `clickEffect(LIGHT)`（形变 0.90）+ **③ 显式光效层**（`backgroundColor + opacity`）；
 *  不能用「整体降不透明度」代替（那是减光，见 `GlassSpec` 的注释）。
 *  ⚠️ **浅色档的方向是「变亮」，不是「变暗」**（R57/T17，用户第五次反馈「没有光效」的直接原因）：
 *  浅色静止盘面 248、页面 253 ⇒ 「白覆盖层提亮」只剩 +2.8% 天花板，物理上做不出可见提亮；
 *  ⇒ 解法是**先把静止纱加深**（浅色 `glass_icon_surface` 2% 黑 → **5.5% 黑**，盘面 ~248 → ~238、钮这才可见），
 *  按下时用**高不透明度白覆盖层**把纱提回去（`glass_icon_press_glow` `#BFFFFFFF` = 75% 白）
 *  ⇒ 盘面 238 → 251（**+12.6/255，方向为变亮**），环的对比度不变（环在最上面）且随底部一起变亮 +10.3/255。
 *  ⚠️ 纱不能再加深：|Δ| ≤ 15 的浅色判据把它卡在 5.5%（8% 纱会到 −20/255）。
 * ⑧ ⚠️ **不要用 `brightness` 做按压提亮**（T13/T14/T15 三次真机结论）：
 *  · 它是按**节点盒子的矩形区域**作用的 —— 挂在外层矩形 Stack 上 ⇒ 圆盘四角被提亮成**方形亮块**（T13 实测 +180%）；
 *  · 挂到圆形装饰层上虽然方角消失，但那一层 `hitTestBehavior(None)` ⇒ `stateStyles.pressed` **永不进入**（T14 实测 +0.0%）；
 *  · 而 `backgroundColor` 被 `borderRadius` 裁成圆是**本工程已真机验证**的事实 ⇒ 覆盖层方案没有未验证语义。
 *
 * ## 尚未在设备上目视验证（交接给 Lead 的核对项）
 * 本机（Windows）无法渲染 ArkUI，以下只能上设备看：
 *  · `radialGradient` 铺在 `borderRadius` 上是否被正确裁成圆（若不裁，方角会露出来）；圆环的
 *  `radius: '50%'` 百分比语义（按宽度）只在本机模型里验证过；
 *  · **R64 新增（★本轮最大的未验证语义）**：`.clip(true)` 裁半圆 + `.blur(ARC_BLOOM)` 的组合。
 *  SPEC §2.2 列了三种失败形态，**上设备后必须逐条看**：
 *  ① 两段接缝处出现**明显水平接缝 / 台阶**（量化：0°/180° 附近环弧的亮度跳变幅度）；
 *  ② `.blur()` 把**方角 / 矩形边界**露出来（bloom 没被 borderRadius 约束）；
 *  ③ 环被裁成两条直线（`clip` 切错了位置）。
 *  若出现任一形态 ⇒ **退回单段均匀环**（只保留 `.blur()` 的 bloom，牺牲方向性），并在汇报里写实测现象
 *  —— **不许悄悄退**（SPEC §2.2）。若接缝跳变 > 15/255，Lead 要求扩成 **4 段（四象限、四档递变）**，
 *  故两段是**数据驱动**（`arcSegments()`），扩段只需改数组。
 *  · **R64 验收线（深色，SPEC §4，Lead 用同一脚本判）**：盘面 Δ ≤ +8；等效白 α ≤ 3%；
 *  24 扇区极差 ≤ 15；环上/下亮度比 ≥ 2.5；环峰 − 盘面 = +45~+90；弧带 FWHM ≥ 0.10R。
 *  · **R64-T2 定点后的复看项**：① 弧峰 − 盘面是否到了 **+72** 量级（v4 实测只有 +29；本轮三个常量：
 *  `RIM` 1.25→2.5、`ARC_BLOOM` 4→1.5、dark 弧峰 27%→65%）；② 角向是否变成「**上亮下暗**」
 *  （v4 实测顶部 ≈ 背景、最亮在左下/左 —— 根因已定位为「段容器被外层 Stack 各自居中」，
 *  本轮用 `boxPad*` 修正，**没有**去动颜色与上/下的映射，理由见 `ArcSegment.boxPadTop`）；
 *  ③ 2.5vp 的弧带在 dpr 2.975 下 ≈ 7.4px：是否太粗、bloom 还看不看得出外发光。
 *  · 浅色档的弧是**暗弧**（base 24% 黑 / 7.8% 黑）—— 参考图只给了深色图，浅色按「细边勾轮廓」的原理推。
 *  · ★**只能真机判（T15 判据，本轮唯一待闭环项）**：按下帧里
 *  ① 盘面提亮 **≥ +10%**（深色预测 **+84.5%** —— R64 盘面降到 1.2% 白后按模型重算；取盘面内切圆内、排除方角与边缘）；
 *  ② **四角 = 背景**（≤ 背景 + 3，方角不得回来）；
 *  ③ 环峰**按「按下帧自己量出的半径」归一**后**不得下降**（深色预测 **+8.1%**）——
 *  ⚠️ 固定屏幕环带 `0.95~1.05R_rest` 一定会掉到 ~62：那是 `clickEffect` 把环挪到 `0.90R` 的**几何后果**，不是变暗；
 *  ④ 半径仍 **−5%** 左右（`clickEffect` 保留）。
 *  · ★**只能真机判**：`clickEffect` 的缩放（0.90）与缓动在真机上的观感；以及 SDK 明确警告的
 *  「**缩放后触点可能落到控件外 ⇒ 连续点击失效**」——32/36/40/54vp 四档都要试「连点 5 次是否次次有响应」。
 *  模拟器上 `clickEffect` 的时序与真机不同，**必须真机**。
 */
import { FontSize, GLASS_BLUR_RADIUS, GLASS_BRIGHTNESS, GLASS_SATURATION, GlassSpec,
  glassArcClear, glassArcDimHigh, glassArcDimLow, glassArcHigh, glassArcLow,
  glassIconPressGlow, glassIconShadow, glassIconSurface, ink } from './Design';
import { AaIcon, ICONS } from './Icon';
import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * R64 光弧层的一段（**数据驱动**，见 `AaGlassIconButton.arcSegments()`）。
 *
 * ⚠️ 两段共用同一个 `@Builder arcSegment()` 实现，这里只描述「对齐 + 顶开的 margin + 两档颜色」——
 * 不要改回两份复制粘贴的代码：Lead 已预告「若 0°/180° 接缝跳变 > 15/255 就扩成 4 段（四象限、四档递变）」，
 * 扩段时应**只改数组**。
 */
interface ArcSegment {
  /** ForEach 的稳定 key：'top' / 'bottom'。 */
  half: string;
  /** 段容器内子节点的对齐（Top ⇒ 只露上半圈；Bottom ⇒ 只露下半圈）。 */
  align: Alignment;
  /** 内层**环**向下顶开（vp）：上半段 = ARC_BLOOM，下半段 = 0。 */
  ringPadTop: number;
  /** 内层**环**向上顶开（vp）：下半段 = ARC_BLOOM，上半段 = 0。 */
  ringPadBottom: number;
  /**
   * **段容器**在外层 Stack 内的顶开 / 上推（vp）：上段 `{top:0, bottom:H}`、下段 `{top:H, bottom:0}`
   * （H = `arcBandHeight()` = d/2 + BLOOM）。
   *
   * ⚠️ **R64-T2 真机定因（这一条是这个字段存在的唯一理由）**：外层 `Stack` 默认 `alignContent = Center`，
   * 两个**半高**容器会被**各自居中** ⇒ 上段圆心落到钮心**下方** (d/4 + B/2)、下段圆心落到钮心**上方**
   * (d/4 + B/2)（v4 实装 d=44 / B=4 时各偏 13vp）⇒ 两段圆心相隔 d/2，弧被搬到「左下 / 右下」，
   * 钮正上方反而是空的（真机实测：顶部 ≈ 背景 13，最亮在左下~左）。
   * 用「容器 margin = 自身高度」抵消居中，让**上段容器底 / 下段容器顶正好压在钮心那条切线上**。
   */
  boxPadTop: number;
  boxPadBottom: number;
  /** 弧峰（外沿）色。 */
  high: Resource;
  /** 弧内沿色。 */
  low: Resource;
}

/**
 * R65-T1：**首页顶栏两个钮是否走官方沉浸光感**（编译期常量，默认 **true**）。
 *
 * ## 为什么是这两个钮
 * 官方 OS 平台行为变更（仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）：其他组件**只在**
 * `Navigation`/`NavDestination` 标题栏、或横向 Tabs（`barPosition: BarPosition.End`）的底部 TabBar
 * 中才生效；**页面正文里的自绘容器一律不生效**（静默无效）。完整配方见 `坑 245`。
 * 本工程**唯一**命中该范围的功能钮 = 首页顶栏两个钮（`HomeScreen` 的 `Navigation()` + `.title(...)`）。
 *
 * ## A/B 用法（Lead 在真机上跑）
 * · `true` = 首页顶栏两个钮渲染**官方材质 only**（不画任何自绘层）；
 * · `false` = **整条官方分支都不渲染**（不是挂 `Material.empty`）⇒ 与 R64 的包逐像素相同；
 * · 两个包其余代码完全一致 ⇒ 逐像素 MAE 可直接归因给官方材质。
 */
export const TOPBAR_OFFICIAL_MATERIAL: boolean = true;

@Component
export struct AaGlassIconButton {
  /** 图标名（kebab-case，见 `ui/Icon.ets` 的 `ICONS`）。 */
  @Prop name: string = '';
  /** 外径（vp）—— 光环带（`GlassSpec.RIM` = 2.5vp，R64-T2 加宽）与 bloom（`ARC_BLOOM` = 1.5vp）都以此为几何基准。 */
  @Prop diameter: number = 44;
  @Prop iconSize: number = FontSize.ICON;
  /** 图标线色。 */
  @Prop tint: Resource = ink();
  /**
   * 玻璃底（`backgroundEffect` 的 `color`）。
   *
   * 缺省 = `glassIconSurface()`（浅 5.5% 黑纱 / 深 **1.2% 白**（R64 降档），功能栏里的玻璃钮）；
   * 强动作钮（悬浮「+」）传 `glassPrimarySurface()`（主色 85%）—— 那档要保持图标对比度。
   */
  @Prop surface: Resource = glassIconSurface();
  /** false = 不可点：整体压到 `GlassSpec.DISABLED_OPACITY`（与 `AaCircleIconButton` 同值），且不触发回调。 */
  @Prop interactive: boolean = true;
  /** > 0 = 圆角方形（App 标记那类 squircle），单位 vp；缺省 0 = 正圆（半径 = 直径 / 2）。 */
  @Prop cornerRadius: number = 0;
  /** 无障碍文本 —— 纯图标控件在 `dumpLayout` / 读屏里的唯一语义载体。 */
  @Prop accessibilityLabel: string = '';
  /**
   * R65-T1：true = 本钮走**官方沉浸光感（material-only）**。
   * ⚠️ 还要再乘一道编译期常量 `TOPBAR_OFFICIAL_MATERIAL`；当前**只有首页顶栏两个钮**传 true
   * （见 `坑 245` 的生效范围）。缺省 false ⇒ 其它页面/其它钮逐像素不变。
   */
  @Prop officialMaterial: boolean = false;
  onTap?: () => void;
  /**
   * 按压态 —— 由**外层（可命中）节点**的 `onTouch` 驱动：`Down` 置真，`Up / Cancel` 置假。
   *
   * ⚠️ **不要改回 `stateStyles.pressed`**：T15 真机定因 —— `stateStyles` 挂在带
   * `hitTestBehavior(HitTestMode.None)` 的装饰层（① 玻璃层）上时**收不到按压事件**，`pressed`
   * 状态永不进入 ⇒ 提亮恒不生效，按下盘面实测 **+0.0%**（用户「没光效」的直接原因）。
   * ⚠️ 本状态**必须在 `build()` 里被直接读到**（§0 状态「读时登记」）—— 这里直接喂给 ③ 光效层的 `opacity`；
   * 若哪天改成「先存 store 再转一手」，务必确认 build 里真的读了它，否则不登记渲染依赖。
   */
  @State pressed: boolean = false;

  /** R57/T16：挂载时打一次系统材质探针（hilog，tag=`aaGlassMat`）—— 报告要求先验前置开关再谈效果。 */
  aboutToAppear(): void {
    glassMaterialProbe();
  }

  /** 外圈圆角半径：0 ⇒ 正圆。 */
  private outerRadius(): number {
    return this.cornerRadius > 0 ? this.cornerRadius : this.diameter / 2;
  }

  /** 光弧段容器高度（vp）：d/2 + BLOOM —— 四周各留 BLOOM，外发光才有地方散开（Lead R64 几何补充）。 */
  private arcBandHeight(): number {
    return this.diameter / 2 + GlassSpec.ARC_BLOOM;
  }

  /** 光弧段容器宽度（vp）：d + 2×BLOOM（两侧也要留出外发光的余量）。 */
  private arcBandWidth(): number {
    return this.diameter + GlassSpec.ARC_BLOOM * 2;
  }

  /**
   * R65-T1：本钮是否走官方材质分支（编译期开关 × 调用点 opt-in）。
   * ⚠️ 关掉 `TOPBAR_OFFICIAL_MATERIAL` 时**整条官方分支都不渲染**（不是挂 `Material.empty`），
   * 这样「材质开 / 关」两包只差这一个分支，逐像素 MAE 干净可归因。
   */
  private useOfficialMaterial(): boolean {
    return TOPBAR_OFFICIAL_MATERIAL && this.officialMaterial;
  }

  /**
   * 光弧层的两段（**数据驱动**，SPEC §2.2）—— 上亮 / 下暗。
   *
   * ⚠️ 两段**共用** `@Builder arcSegment()`：这里只给「对齐 + margin + 两档颜色」。
   * 不要改回两份复制粘贴的代码 —— 上设备后若接缝跳变 > 15/255，Lead 要求扩成 4 段（四象限），
   * 届时只需改这个数组（段容器几何另议）。
   */
  private arcSegments(): ArcSegment[] {
    return [
      // 上半段（左上最亮）：glassArc*
      { half: 'top', align: Alignment.Top,
        ringPadTop: GlassSpec.ARC_BLOOM, ringPadBottom: 0,
        boxPadTop: 0, boxPadBottom: this.arcBandHeight(),
        high: glassArcHigh(), low: glassArcLow() },
      // 下半段（弱一档）：glassArcDim*
      { half: 'bottom', align: Alignment.Bottom,
        ringPadTop: 0, ringPadBottom: GlassSpec.ARC_BLOOM,
        boxPadTop: this.arcBandHeight(), boxPadBottom: 0,
        high: glassArcDimHigh(), low: glassArcDimLow() }
    ];
  }

  /**
   * 半环段（两段共用）：全尺寸径向环 + `.blur(ARC_BLOOM)` 外发光；外面套**半高**段容器，
   * 靠 `alignContent` 把环顶到上半 / 下半，再由 `.clip(true)` 沿水平中线切成半圈。
   *
   * ⚠️ `alignContent` 是 `Stack` 的**子节点对齐**属性（SPEC 的伪代码写的是 `.align(...)`；
   * `.align()` 管的是「元素内容在自身绘制区内的对齐」，不是 Stack 子节点定位 ⇒ 这里用 `alignContent`）。
   * ⚠️ 内层环用 `margin` 顶开 `ARC_BLOOM`，让 bloom 在容器内散开（否则会被容器边界切掉）。
   * ⚠️ `.blur()` 是**内容模糊**通用属性，只在光弧层用（坑 74 禁的是 `backgroundBlurStyle`/`backdropBlur`）。
   */
  @Builder
  arcSegment(seg: ArcSegment) {
    Stack() {
      Row()
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.outerRadius())
        .radialGradient({
          center: ['50%', '50%'],
          radius: '50%',
          colors: [
            // 弧内沿以内 alpha 恒 0：用「同 RGB、alpha = 0」的 clear 色（**不用** Color.Transparent）
            [glassArcClear(), 0],
            [glassArcClear(), GlassSpec.RIM_STOP_INNER],
            [seg.low, GlassSpec.RIM_STOP_PEAK],
            [seg.high, GlassSpec.RIM_STOP_OUTER]
          ]
        })
        .blur(GlassSpec.ARC_BLOOM)
        .margin({ top: seg.ringPadTop, bottom: seg.ringPadBottom })
        .hitTestBehavior(HitTestMode.None)
    }
    .width(this.arcBandWidth())
    .height(this.arcBandHeight())
    .alignContent(seg.align)
    // ⚠️ 抵消外层 Stack 的居中（R64-T2 真机定因，见 `ArcSegment.boxPadTop`）：
    //  没有这一行，两段圆心会各偏 ±(d/4 + B/2)，弧会被搬到左下/右下、钮正上方变空。
    .margin({ top: seg.boxPadTop, bottom: seg.boxPadBottom })
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * R65-T1：**官方沉浸光感 only**（首页顶栏专用）。
   *
   * 与自绘分支**互斥**（`useOfficialMaterial()`），同一时刻只渲染一个。
   * ⚠️ 本分支**故意不画任何自绘层** —— 官方文档写明材质会接管 `backgroundColor` / `borderColor` /
   * `borderWidth` / `shadow`，且**不建议与它们同时使用**：所以这里没有 `backgroundEffect`、
   * 没有 `.shadow(`、没有 `linearGradient`/`radialGradient`、没有 `.backgroundColor(`/`.border*`。
   * 按压反馈交给材质的 `interactive: true`（官方交互反馈），不再叠自绘按压光效层。
   *
   * `materialColor` 复用 `glassIconSurface()`（dark `#03FFFFFF` / base `#0E000000`，**都带透明度**）：
   * 官方要求「完全 opaque 会挡死滤镜」；不新造资源键。
   */
  @Builder
  officialGlass() {
    Row()
      .width(this.diameter)
      .height(this.diameter)
      .borderRadius(this.outerRadius())
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: glassIconSurface(),
        colorInvert: false,
        applyShadow: true,
        interactive: true,
        lightEffect: { color: Color.White }
      }))
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack() {
      // ⚠️ **R65-T1：官方沉浸光感分支**（仅首页顶栏两个钮，编译期常量 `TOPBAR_OFFICIAL_MATERIAL`）。
      //  官方生效范围（HarmonyOS 7 / targetSdk ≥ 26.0.0）只认「Navigation 标题栏」等四类位置，
      //  本工程唯一命中的功能钮就是首页顶栏这两个 ⇒ 只有它们传 officialMaterial: true。
      //  ⚠️ 该分支**不画任何自绘层**（官方：材质会接管 backgroundColor/borderColor/borderWidth/shadow，
      //  不建议同用）—— 这样「材质开 / 关」两包只差这一个分支，A/B 的 MAE 才有意义。
      if (this.useOfficialMaterial()) {
        this.officialGlass()
      } else {
        // ① 玻璃主体（**最底层**）：磨砂 + 玻璃色 + 投影。
        //  ⚠️ R57（T11）**层序是这一轮的关键**：玻璃层必须是「第一个画的」——
        //  `backgroundEffect` 会把**画在它下面的兄弟节点**一起糊进来。T9 把亮环放在玻璃下面，
        //  于是 6vp 的模糊把环糊进盘面外圈 ⇒ 盘面在边缘变亮、看起来像「球」。
        //  现在 ② 光弧层画在玻璃**上面**，玻璃的 backdrop 只剩它背后的页面内容。
        //  ⚠️ R64：盘面自发光已降到 **1.2% 白**（`glass_icon_surface`）—— 真机 Δ+24 的「灰塑料盘」正是它造成的。
        //  ⚠️ 投影挂在**这一层**（唯一一处，坑 79 别层层叠阴影）；它画在玻璃后面、只有 ~96% 透
        //  ⇒ 会从盘面内部透出来，所以单独用 `glassIconShadow()`（不是 `appShadow()`）。
        Row()
          .width(this.diameter)
          .height(this.diameter)
          // ⚠️ 圆角一律走 `outerRadius()`：缺省 0 时它给 `d/2`（正圆）。
          // 曾经在这里写过「按边长比例算圆角」的分支 —— 默认路径会画成圆角方形（不是圆），已删。
          .borderRadius(this.outerRadius())
          // ⚠️ R60 回滚：R58 曾把这里收成 `glassIconEffect()` 唯一入口并引入
          //  `GLASS_ICON_BLUR / GLASS_ICON_SATURATION / GLASS_ICON_ADAPTIVE` 三个实验常量。
          //  用户已决定「取消前面的玻璃调参、改走官方沉浸光感路线」⇒ 回到 R57 的直写写法，
          //  参数取全局玻璃令牌（与顶栏那条玻璃带**同档**，依据见 `Design.ets` 的 `GLASS_BLUR_RADIUS` 注释）。
          .backgroundEffect({
            radius: GLASS_BLUR_RADIUS,
            saturation: GLASS_SATURATION,
            brightness: GLASS_BRIGHTNESS,
            color: this.surface
          })
          // ⚠️ R57（T16）**系统材质（真机 A/B 专用）**：`glassMaterial()` 按 `GLASS_MATERIAL_MODE` 返回
          // `Material.empty`（档 0 = 基线 = 显式关闭）或 `ImmersiveMaterial(THIN)`（档 1/2）。
          // 无条件调用：档 0 在语义上就是「关」，三档之间只差这一个开关，不再有分支差异。
          // ⚠️ 经典回退（`backgroundEffect` + 光弧 + 投影）**三档都保留**：坑 58 真机上内容区材质可能不生效，
          // 回退必须随时兜住；也正因为保留，A/B 的判据才能是「静止帧与基线**逐像素不同** ⇒ 材质生效了」。
          .systemMaterial(glassMaterial())
          .shadow({
            radius: GlassSpec.SHADOW_RADIUS,
            color: glassIconShadow(),
            offsetX: 0,
            offsetY: GlassSpec.SHADOW_OFFSET_Y
          })
          // ⚠️ R57（T15）**这一层曾挂 `stateStyles.pressed.brightness`，已删除**：
          // 装饰层带 `hitTestBehavior(HitTestMode.None)` ⇒ **收不到按压事件** ⇒ `pressed` 永不进入
          // ⇒ 按下提亮在真机上实测 **+0.0%**（T14 那轮）。提亮改由 ③ 光效层承担（`@State` 驱动），见下。
          .hitTestBehavior(HitTestMode.None)

        // ② **光弧层**（R64 v4 新增，SPEC §2.1/§2.2）—— 沉浸光感的**方向性**来源：
        //  **上亮 / 下暗两段半环 + `.blur()` 外发光**。
        //  ⚠️ v3 那块「铺满盘面的 `linearGradient`」**整层删除**（SPEC §2.1 ❌）：真机实测它把光摊到
        //  盘面内部 ⇒ 盘面 Δ+24、24 扇区极差 36，钮成了「发灰的塑料盘」；R64 只让光留在**边缘**。
        //  ⚠️ 两段由 `arcSegments()` **数据驱动**、共用 `arcSegment()` 这一个实现；
        //  几何（段容器四周留 BLOOM）与兜底见文件头「尚未在设备上目视验证」。
        //  ⚠️ 层序：它在玻璃**之上**（backdrop 不该糊到它）、③ 按压光效层**之下**（SPEC §2.1）。
        ForEach(this.arcSegments(), (seg: ArcSegment) => {
          this.arcSegment(seg)
        }, (seg: ArcSegment) => seg.half)

        // ③ **按压光效层**（R57 / T15；**R64 起压在光弧层之上**）—— 按下时整块玻璃「亮起来」的那一层。
        //  ⚠️ 只用**绘制原语**：`backgroundColor`（**一定**被 `borderRadius` 裁成圆）+ `opacity`。
        //  **不用 `brightness`**：T13 证明它是按「节点盒子的矩形区域」作用（外层矩形 Stack 上会露方角亮块），
        //  而 T14 那轮四角干净是因为 `pressed` **根本没进入**（装饰层不参与命中测试）——
        //  即「滤镜是否遵守圆角裁剪」**至今没有真机证据**；覆盖层则没有任何未验证语义。
        //  ⚠️ **R64 层序变更**：按压光效层现在压在**光弧层之上**（SPEC §2.1 的 ②→③ 顺序），
        //  与 R57/T17「环永远最锐利」相反 —— 按下时覆盖层会把弧一起提亮（方向仍正确，只是弧的对比略降）。
        //  这是 R64 明确指定的顺序，**不要**照旧注释把它挪回弧下面。
        //  ⚠️ 覆盖层仍在**图标之下**（图标是最后一层），图标不被洗白。
        Row()
          .width(this.diameter)
          .height(this.diameter)
          .borderRadius(this.outerRadius())
          .backgroundColor(glassIconPressGlow())
          .opacity(this.pressed ? 1 : 0)
          .animation({ duration: GlassSpec.PRESS_ANIM_MS, curve: Curve.EaseOut })
          .hitTestBehavior(HitTestMode.None)

      }

      // ④ 图标（Lucide 矢量，尺寸/坐标空间由 `AaIcon` 负责）。
      //  ⚠️ **没有镜面高光层**（R57/T11 整层下架，R64 仍不恢复）：参考图盘面上没有半径向的光斑；
      //  盘面的方向性全部来自 ② 光弧层（**不是**盘面内的渐变 —— 那一层已在 R64 整层删除）。
      Column() {
        AaIcon({ d: ICONS[this.name], iconSize: this.iconSize, color: this.tint })
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.diameter)
    .height(this.diameter)
    // ---- 交互反馈 = 形变（clickEffect）+ 按压提亮（③ 层）----
    // ⚠️ R64 更新：盘面的**静态光感**已由 ② 光弧层（边缘弧 + bloom）承担；
    //  本节管的是**按下那一刻**的反馈，两者都不许往盘面加常驻光。
    // ① **形变**走**官方** `clickEffect`：`ClickEffectLevel.LIGHT` 是系统默认档，
    //  SDK 写死的缩放就是 **0.90**（`common.d.ts:15934` / `enums.d.ts:3756`），不自拍数值。
    //  真机已验：半径 −5%、连点 5/5 正常。⚠️ SDK NOTE：缩放后触点可能落到控件外 ⇒ 每次改尺寸都要重验连点。
    // ② **提亮**走 ③ 光效层（`backgroundColor + opacity`），由**本层的 `onTouch` 驱动 `@State pressed`**。
    //  ⚠️ 本层是**唯一可命中的节点**（子层全是 `hitTestBehavior(None)`）——
    //  这也是为什么 `onTouch` 必须挂这里：`stateStyles`/`onTouch` 挂在装饰层上收不到事件（T15 真机定因）。
    // ③ 不可点态：不透明度恒 0.4（链式声明，**所有状态通用**）+ `disabled` 档双保险。
    // ④ `PRESSED_OPACITY`（0.72 整体压暗）已退役：压暗 = 减光，与「按下更有光感」方向相反。
    // ⑤ ⚠️ 本层（矩形 Stack）**绝不能挂 `brightness`**：`borderRadius` 不裁滤镜，
    //  挂在矩形节点上会让圆盘外的四个角一起被提亮成方形亮块（T13 真机实测 +180% 就是这个）。
    .opacity(this.interactive ? 1 : GlassSpec.DISABLED_OPACITY)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .stateStyles({
      normal: { .opacity(this.interactive ? 1 : GlassSpec.DISABLED_OPACITY) },
      disabled: { .opacity(GlassSpec.DISABLED_OPACITY) }
    })
    .accessibilityText(this.accessibilityLabel)
    // 按压驱动：**只有这一个入口**。`event.type === TouchType.Down` 在 Up / Cancel 时求值为假 ⇒ 自动复位（手指划出也回正）。
    // 与 `LoginScreen` 的 `isPressed` 写法完全同源（那是本工程已在真机跑过的模式）。
    .onTouch((event: TouchEvent) => {
      if (!this.interactive) {
        return;
      }
      this.pressed = event.type === TouchType.Down;
    })
    .onClick(() => {
      if (this.interactive && this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}
// ---------------------------------------------------------------------------
// R57 / T16：系统液态玻璃材质（uiMaterial）—— **真机 A/B 实验开关**
// ---------------------------------------------------------------------------
/**
 * 玻璃钮的材质档位（**T16 三档 A/B 实验开关，编译期常量**）：
 *
 * | 值 | 档 | 做法 | 要回答的问题 |
 * | --- | --- | --- | --- |
 * | 0 | **C（基线，默认）** | 自绘玻璃 `backgroundEffect` + 发丝环 + `@State` 按压覆盖层 + `clickEffect(LIGHT)` | 已知：盘面按下 +45%、四角干净、形变 −5% |
 * | 1 | **S1** | 同 C，**外加** `.systemMaterial(THIN, 无 lightEffect)`（叠经典回退） | 真机内容区到底生不生效？半透玻璃钮会不会被洗白？ |
 * | 2 | **S2** | 同 S1 但**开** `lightEffect` | 系统的「光感交互反馈」长什么样？是否复现坑 13 的顶缘贯穿亮线？ |
 *
 * ⚠️ 三档**必须通过改这个常量 + 重新构建**来切换（编译期常量，避免运行期不确定性）。
 * 交付时默认值必须回到 **0**（基线），suite-design 有断言钉住。
 */
export const GLASS_MATERIAL_MODE: number = 0;

/** 三档模式名（报告 / hilog 里打印，避免靠数字认档）。 */
export function glassMaterialModeName(): string {
  if (GLASS_MATERIAL_MODE === 1) {
    return 'S1-material';
  }
  if (GLASS_MATERIAL_MODE === 2) {
    return 'S2-material+lightEffect';
  }
  return 'C-selfdrawn';
}

/**
 * 玻璃钮的系统材质实例（唯一入口，与另一工程 `view/LiquidGlass.ets` 的 `GlassMat` 同构）。
 *
 * · 档 0 返回 `uiMaterial.Material.empty`（SDK 原文：「用于**禁用**某组件的沉浸材质」）⇒
 *  `.systemMaterial(glassMaterial())` 可以**无条件调用**，基线档在语义上就是「显式关闭」。
 * · `materialColor` 必须带透明度（完全 opaque 会挡住材质滤镜）—— 复用 `glassIconSurface()` 的双值 token。
 * · `applyShadow: false`：投影仍由我们的 `glassIconShadow()` 供给（避免双阴影，也让 A/B 只差一个变量）。
 * · `interactive: false`：形变仍由 `clickEffect(LIGHT)` 供给（S1/S2 之间只差 `lightEffect` 一个变量）。
 * · `colorInvert: false`：另一工程真机实测 true 会在浅背景上反色。
 * · `lightEffect` **只在档 2** 打开 —— 它是本轮要证伪/证实的对象（坑 13）。
 */
export function glassMaterial(): uiMaterial.Material {
  if (GLASS_MATERIAL_MODE === 0) {
    return uiMaterial.Material.empty;
  }
  if (GLASS_MATERIAL_MODE === 2) {
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: glassIconSurface(),
      colorInvert: false,
      applyShadow: false,
      interactive: false,
      lightEffect: { color: Color.White }
    });
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: glassIconSurface(),
    colorInvert: false,
    applyShadow: false,
    interactive: false
  });
}

/** 探针只打一次（组件会挂载多次，别刷屏）。 */
let materialProbed: boolean = false;

/**
 * 打印系统材质的三个客观量（报告要求「先打探针再谈效果」）：
 *  · `isImmersiveMaterialSupported()` —— 设备能力；
 *  · `getMaterialInfo().state` —— **1=ENABLE 才说明 module.json5 的 metadata 生效**（坑 2）；
 *  · `getGlobalMaterialLevel()` —— 0=EXQUISITE（材质档位）。
 * 抓取：`hdc shell hilog -x | Select-String aaGlassMat`
 */
export function glassMaterialProbe(): string {
  let supported: boolean = false;
  let state: number = -1;
  let level: number = -1;
  try {
    supported = uiMaterial.isImmersiveMaterialSupported();
    state = uiMaterial.getMaterialInfo().state;
    level = uiMaterial.getGlobalMaterialLevel();
  } catch (error) {
    hilog.error(0x0000, 'aaGlassMat', 'probe failed: %{public}s', JSON.stringify(error));
    return 'probe-failed';
  }
  const line: string = 'mode=' + String(GLASS_MATERIAL_MODE) + '(' + glassMaterialModeName() + ')' +
    ' supported=' + String(supported) + ' state=' + String(state) +
    ' level=' + String(level);
  if (!materialProbed) {
    materialProbed = true;
    hilog.info(0x0000, 'aaGlassMat', 'PROBE %{public}s', line);
  }
  return line;
}
