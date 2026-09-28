/**
 * 通用 UI 组件（对应 Android `ui/designsystem/Components.kt` +
 * `ui/screens/common/AppEmptyState.kt` + `AAToast.kt`）。
 */

import { display, UIContext, uiMaterial } from '@kit.ArkUI';
import { DialogSpec, FontSize, GLASS_BLUR_RADIUS, GLASS_BRIGHTNESS, GLASS_SATURATION, GlassSpec,
  ProfileDialogSpec, Radius, Space, Control, StrokeWidth, appShadow,
  borderColor, dialogSurface, ink, inkSoft, muted, faint, subtle, errorText, onPrimaryAction,
  primaryAction, raisedSurface, rowPressedSurface, glassCardSurface, glassIconSurface, glassPanelSurface, glassPrimarySurface,
  glassRimHigh, glassSheenClear, glassSheenHigh, glassSheenMid } from './Design';
import { AaIcon, ICONS } from './Icon';
import { AaGlassIconButton, TOPBAR_OFFICIAL_MATERIAL } from './GlassIcon';

/**
 * 品牌字标（首页顶栏「Agents Anywhere」）用的字体族名。
 *
 * 上游 `ui/designsystem/AAWordmark.kt` 用 **Caveat 手写体**（`FontFamily(Font(R.font.caveat_wght))`，
 * `fontWeight = Medium`）；本工程把同一份 `caveat_wght.ttf` **原样复制**到
 * `entry/src/main/resources/rawfile/fonts/caveat_wght.ttf`（md5 与上游一致，见 开发期验证记录 §11）。
 *
 * ⚠️ 该 TTF 是**可变字体**（含 `fvar`/`gvar`/`HVAR`/`STAT` 表）。ArkUI 的 `UIContext.Font#registerFont` 没有字重轴参数，
 *  `.fontWeight()` 是否作用到 wght 轴**未验证**（本机无设备）；最坏情况是渲染该字体的默认实例，
 *  「手写体形状」一致而字重可能不等于 Medium —— 已作为平台差异记录，待真机确认。
 */
export const WORDMARK_FAMILY: string = 'Caveat';

/**
 * 已注册过字标的 UIContext。
 *
 * 旧的全局 `font.registerFont` **已废弃**（编译期报 `'registerFont' has been deprecated`，破坏本工程
 * 「零 ArkTS 告警」基线）；替代品 `UIContext.Font#registerFont` 是**按 UIContext 注册**的 —— 所以不能
 * 用一个模块级 boolean 一劳永逸：Ability 重建会带来新的 UIContext，那时必须重新注册。这里用 WeakSet
 * 既能去重，又不会把 UIContext/窗口实例的引用长期留住。
 */
const wordmarkFontContexts: WeakSet<UIContext> = new WeakSet<UIContext>();

/**
 * 注册字标字体（幂等；必须在首次渲染前调用）。
 *
 * ⚠️ SDK 文档写明 `registerFont` 是**异步**的，所以「注册完立即首帧」可能仍拿系统字体；若真机上
 * 首次进入首页字标不是手写体，就把它挪到 Ability 的 `onWindowStageCreate`（那里 UIContext 已就绪）。
 */
export function ensureWordmarkFont(ui: UIContext): void {
  if (wordmarkFontContexts.has(ui)) {
    return;
  }
  ui.getFont().registerFont({ familyName: WORDMARK_FAMILY, familySrc: $rawfile('fonts/caveat_wght.ttf') });
  wordmarkFontContexts.add(ui);
}

/**
 * R66：**标题栏（功能栏）官方沉浸材质实例** —— 本工程**唯一构造入口**（SPEC §2）。
 *
 * ⚠️ 签名由 lead 裁决冻结：`officialBarMaterial(color: ResourceColor): uiMaterial.ImmersiveMaterial` ——
 * **页面不得直接 `import uiMaterial`**（Kit 依赖收口在本文件；`suite-files.mjs` 有依赖卫生断言），
 * 上层页面/组件只传一个**半透明**令牌。
 *
 * ## 为什么抽成函数（而不是各页各写一遍 `new uiMaterial.ImmersiveMaterial({...})`）
 * ① 「功能栏采用官方方案」本轮要落到**十余处**（5 页的栏本体 + 各页标题栏内的胶囊 + 次按钮的两个分支），
 *  同一份参数抄十几遍，将来调一档（例如 `THIN` → 别的档）必然漏改；
 * ② 调用方**不必各自 `import { uiMaterial } from '@kit.ArkUI'`** —— Kit 依赖收口在本文件
 *  （`suite-files.mjs`「FilesScreen 只许引 BasicServicesKit 一个 Kit」）。
 *
 * ## 参数与语义（与 `GlassIcon.ets#officialGlass()` 同一套口径）
 * · `style: THIN`；`materialColor` 必须是**带透明度**的既有令牌（完全 opaque 会挡死材质滤镜）；
 * · `applyShadow: true` / `interactive: true` —— 投影与按压反馈都交给官方材质（调用点不再画自绘投影/按压层）；
 * · `lightEffect` 只用 `color`（SDK `LightEffectOptions` 的唯一字段）。
 *
 * ⚠️ 官方文档：材质会接管 `backgroundColor` / `borderColor` / `borderWidth` / `shadow`，
 * **不建议与它们同时使用** ⇒ 调用点必须把这几层自绘样式**整组删掉**（本工程口径 = 零自绘层）。
 * ⚠️ 生效范围（`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效）：只有
 * `Navigation`/`NavDestination` 标题栏、或横向 Tabs 底部 TabBar 里的节点才生效 ——
 * **正文里的节点传了也是静默无效**（还会丢掉自绘层 ⇒ 变空壳）。
 */
export function officialBarMaterial(color: ResourceColor): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: color,
    colorInvert: false,
    applyShadow: true,
    interactive: true,
    lightEffect: { color: Color.White }
  });
}

/**
 * R85：**弹窗类（在官方生效范围内的）沉浸光感** —— 本工程第二个官方材质构造入口。
 *
 * ## 官方依据（先查文档再动手）
 * · 官方「生效范围」行为变更（仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）：
 *  **弹窗类组件 / 弹窗类接口在页面内全部区域生效**（`坑 245`）。
 * · SDK 里 `systemMaterial` 字段在弹窗类选项上的落点（本轮逐个接上的就是这些）：
 *  `SheetOptions.systemMaterial`（`common.d.ts:12155`，归属 `declare interface SheetOptions` :11753）、
 *  `ContextMenuOptions.systemMaterial`（`:15594`，归属 :14963）、
 *  `CustomPopupOptions.systemMaterial`（`:14406`，归属 :13866）、
 *  `PopupCommonOptions/PopupOptions.systemMaterial`（`:12966` / `:13824`）、
 *  `TipsOptions.systemMaterial`（`:13167`）；
 *  `promptAction` 的 `ShowToastOptions/ShowDialogOptions/BaseDialogOptions/ActionMenuOptions`（`@ohos.promptAction.d.ts:327/752/1263/1796`）；
 *  `AlertDialog` / `ActionSheet` / `CustomDialogController` 的参数对象（`alert_dialog.d.ts:894` / `action_sheet.d.ts:834` / `custom_dialog_controller.d.ts:681`）。
 * · 字段类型 `SystemUiMaterial` = `uiMaterial.Material`（`common.d.ts:16964`）⇒ 本函数返回**基类**。
 *
 * ## 应用级开关的镜像值（必须与 `entry/src/main/module.json5` 逐字一致）
 * `module.json5` 里写的是 `{"name":"ohos.arkui.UIMaterial.state","value":"enable"}`
 * ⚠️ **值必须小写**：大写 `ENABLE` 会被系统**静默忽略**（`坑 2`）。
 */
const MATERIAL_STATE: string = 'enable';

/** 探针结果缓存：应用级开关不会在运行期变（改它要重装包），所以只探一次。 */
let immersiveProbeCache: boolean | undefined = undefined;

/**
 * 沉浸光感是否真的可用 = 应用级开关已开 **且** 设备支持（探针值 `state=1(ENABLE)` 在真机/模拟器都实证过）。
 *
 * 任一环节抛错或缺失 ⇒ 返回 `false`（保守：宁可走既有玻璃回退，也不要在设备不支持时把回退层删掉）。
 */
export function immersiveMaterialEnabled(): boolean {
  if (immersiveProbeCache !== undefined) {
    return immersiveProbeCache;
  }
  let enabled: boolean = false;
  try {
    enabled = uiMaterial.isImmersiveMaterialSupported() && uiMaterial.getMaterialInfo().state === 1;
  } catch (error) {
    enabled = false;
  }
  // 交叉核对：SDK 探针说支持，但应用级 metadata 不是 enable ⇒ 依坑 2 会被静默忽略 ⇒ 一律当不可用。
  if (MATERIAL_STATE !== 'enable') {
    enabled = false;
  }
  immersiveProbeCache = enabled;
  return enabled;
}

/**
 * 弹窗类**小面板**（下拉菜单 / 语言小窗 / Agent 预设小窗）的官方材质：`REGULAR` 档。
 *
 * · 关档返回 `uiMaterial.Material.empty`（SDK 原文 = **disable**）而**不是** `undefined`：
 *  `CommonMethod.systemMaterial(undefined)` 的语义是「**恢复组件默认材质**」，与本工程的"关闭"意图不同
 *  （`uiMaterial.d.ts:467-472` / `common.d.ts:22632-22633`）。
 * · `materialColor` 用 `glassCardSurface()` —— 与既有自绘玻璃回退**同一个令牌**（带透明度；官方：
 *  完全不透明会挡死材质滤镜），且 base/dark 双值 ⇒ 深浅色都不需要另造色。
 * · **不设 `lightEffect`**：官方 `LightEffectOptions` 会在玻璃顶缘合成一条锐利贯穿亮线
 * （`坑 13`，另一工程首次实证）⇒ 本工程一律不用。
 * · `interactive: false`：面板不是按钮，按压反馈由面板内的行组件自己承担。
 */
export function dialogMaterial(): uiMaterial.Material {
  if (!immersiveMaterialEnabled()) {
    return uiMaterial.Material.empty;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.REGULAR,
    materialColor: glassCardSurface(),
    colorInvert: false,
    applyShadow: true,
    interactive: false
  });
}

/**
 * **紧贴正文内容**的半模态面板（`bindSheet`）的官方材质：`THIN` 档。
 *
 * 比 {@link dialogMaterial} 更薄：面板背后就是正文（长列表 / 会话时间线），
 * 面板本身又承载用户要读的正文（Runtime 配置 / 附件 / 粘贴框）⇒ 取薄档保可读性，
 * 与 R84 底栏、既有标题栏同一档（`THIN`）。
 * 其余语义（`Material.empty` 关档 / 无 `lightEffect` / `interactive: false`）与 {@link dialogMaterial} 完全一致。
 */
export function panelMaterial(): uiMaterial.Material {
  if (!immersiveMaterialEnabled()) {
    return uiMaterial.Material.empty;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: glassPanelSurface(),
    colorInvert: false,
    applyShadow: true,
    interactive: false
  });
}

/** 顶部标题栏。 */
@Component
export struct AaTopBar {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = true;
  @Prop actionLabel: string = '';
  /**
   * R65（官方生效范围约束）：true = 本顶栏**位于 `Navigation`/`NavDestination` 标题栏内**，
   * 其内的玻璃控件改走**官方沉浸材质**（`uiMaterial.ImmersiveMaterial`）。
   *
   * ⚠️ 依据（华为 OS 平台行为变更，仅对 `targetSdkVersion >= 26.0.0` 生效，见 `坑 245`）：
   * **其他组件仅在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 的底部 TabBar 中生效；
   * 在页面正文里设置沉浸光感效果不生效。** ⇒ 只有把顶栏放进 `.title(...)` 的页面才能传 true；
   * 页面正文里的顶栏**必须**保持 false（传 true 只会静默无效，还会丢掉自绘层 ⇒ 钮变空壳）。
   */
  @Prop officialMaterial: boolean = false;
  onBack?: () => void;
  onAction?: () => void;

  /**
   * R65（设计规格 §2）：本次顶栏的玻璃控件是否走**官方沉浸光感**。
   *
   * 与 `ui/GlassIcon.ets` 的 `useOfficialMaterial()` **逐字同源**：编译期常量
   * `TOPBAR_OFFICIAL_MATERIAL` × 调用点 opt-in。关掉常量时官方分支**整个不渲染**
   * （不是挂 `Material.empty`）⇒「材质开 / 关」两包只差这些分支，A/B 的逐像素 MAE 才可归因。
   *
   * ⚠️ 生效范围（华为 OS 平台行为变更，仅对 `targetSdkVersion >= 26.0.0` 生效）：
   * **其他组件仅在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 的底部 TabBar 中生效；
   * 在页面正文里设置沉浸光感效果不生效**（`坑 245`）。
   */
  private useOfficialPill(): boolean {
    return TOPBAR_OFFICIAL_MATERIAL && this.officialMaterial;
  }

  /**
   * R65：`actionLabel` 胶囊的**官方权威分支**（材质 only）。
   *
   * 与自绘分支**互斥**（`useOfficialPill()`），同一时刻只渲染一个。
   * ⚠️ 本分支**故意不画任何自绘层**：官方文档写明材质会接管 `backgroundColor` / `borderColor` /
   * `borderWidth` / `shadow`，且**不建议与它们同时使用** ⇒ 这里没有 `backgroundEffect`、
   * 没有 `linearGradient`、没有 `.border*(`；几何（字号 / 内边距 / 圆角）与自绘分支**逐字相同**，
   * 这样 A/B 只差「哪一层在画底」。按压反馈交给材质的 `interactive: true`。
   *
   * `materialColor` 复用 `glassIconSurface()`（base/dark 都带透明度；完全 opaque 会挡死滤镜），
   * 与 `GlassIcon.ets#officialGlass()` 同一档、不新造资源键。
   */
  @Builder
  actionPillOfficial() {
    Text(this.actionLabel)
      .fontSize(FontSize.SMALL)
      .fontColor(ink())
      .padding({ left: Space.M, right: Space.M, top: Space.XS, bottom: Space.XS })
      .borderRadius(Radius.PILL)
      .systemMaterial(officialBarMaterial(glassIconSurface()))
      .onClick(() => {
        if (this.onAction !== undefined) {
          this.onAction();
        }
      })
  }

  build() {
    Row({ space: Space.S }) {
      if (this.showBack) {
        // 上游是 Lucide.ChevronLeft 22dp（`ui/designsystem/Components.kt` 的圆返回钮）。
        // R57（T2b「功能栏液态玻璃化」）：由「内联 Column + 图标」改为**液态玻璃圆钮** ——
        // 四层（磨砂 / 1vp 渐变亮边 / 左上镜面高光 / 柔和外阴影）只在 `ui/GlassIcon.ets` 里定义一次，
        // 这里、`AaCircleIconButton` 的玻璃档、`AaFloatingButton` 的玻璃档共用同一个实现。
        // ⚠️ 直径/图标尺寸沿用原值（Control.NAV_BUTTON=32 / FontSize.ICON_XL=22），只换**材质**不换几何。
        AaGlassIconButton({
          name: 'chevron-left',
          diameter: Control.NAV_BUTTON,
          iconSize: FontSize.ICON_XL,
          tint: ink(),
          officialMaterial: this.officialMaterial,
          accessibilityLabel: '返回',
          onTap: () => {
            if (this.onBack !== undefined) {
              this.onBack();
            }
          }
        })
      }
      Column({ space: Space.XXS }) {
        Text(this.title)
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.actionLabel.length > 0) {
        // ⚠️ **R65（设计规格 §2）分支**：顶栏在 `Navigation` 标题栏内时改走**官方沉浸光感**。
        //  官方生效范围（HarmonyOS 7 / targetSdk ≥ 26.0.0，见 `坑 245`）只认
        //  「弹窗类 / Slider·Toggle·Select / `Navigation`·`NavDestination` 标题栏 / 横向 Tabs 底部 TabBar」，
        //  页面正文里的普通容器**静默无效** ⇒ 正文顶栏必须保持 `officialMaterial: false`（否则钮变空壳）。
        //  开关与 `ui/GlassIcon.ets` 同源（编译期常量 `TOPBAR_OFFICIAL_MATERIAL` × 调用点 opt-in）：
        //  关掉常量时**整条官方分支都不渲染** ⇒「材质开 / 关」两包只差这一个分支。
        if (this.useOfficialPill()) {
          this.actionPillOfficial()
        } else {
          // R63（SPEC §2.3-1）：由「`subtle()` 纯色底」改为**同源玻璃小胶囊** ——
          // 磨砂档 = 功能栏圆钮那一档（`GLASS_BLUR_RADIUS / GLASS_SATURATION / GLASS_BRIGHTNESS` + `glassIconSurface()`），
          // 渐变光层 = `ui/GlassIcon.ets` ② 层**逐字同源**的色标（`GlassSpec.SHEEN_ANGLE` / `SHEEN_MID_STOP`
          // + `glassSheenHigh/Mid/Clear()`，终点是同 RGB、alpha=0 的 clear 色），亮边 = 圆钮亮环的峰值档
          // `glassRimHigh()`。**不新造色值、不新造资源键、不写径向环**（亮环的唯一实现在 GlassIcon.ets）。
          // ⚠️ 三层**挂在同一个 `Text` 节点**上，而不是再叠铺满型装饰兄弟节点：
          //  胶囊宽度由文案自适应，`Stack` 里 `width('100%')` 的装饰层会按**父级可用宽度**解算（把胶囊撑满整行）；
          //  同节点的 background → linearGradient → border 绘制序天然给出「模糊底 + 光层 + 亮边」的层序，
          //  也不引入命中测试问题（本节点就是唯一可点节点，没有需要 `hitTestBehavior(None)` 的装饰兄弟）。
          Text(this.actionLabel)
            .fontSize(FontSize.SMALL)
            .fontColor(ink())
            .padding({ left: Space.M, right: Space.M, top: Space.XS, bottom: Space.XS })
            .borderRadius(Radius.PILL)
            .backgroundEffect({
              radius: GLASS_BLUR_RADIUS,
              saturation: GLASS_SATURATION,
              brightness: GLASS_BRIGHTNESS,
              color: glassIconSurface()
            })
            .linearGradient({
              angle: GlassSpec.SHEEN_ANGLE,
              colors: [
                [glassSheenHigh(), 0.0],
                [glassSheenMid(), GlassSpec.SHEEN_MID_STOP],
                [glassSheenClear(), 1.0]
              ]
            })
            .borderWidth(StrokeWidth.HAIRLINE)
            .borderColor(glassRimHigh())
            .onClick(() => {
              if (this.onAction !== undefined) {
                this.onAction();
              }
            })
        }
      }
    }
    .width('100%')
    .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.S })
  }
}

/** 主按钮（深色实心，对应 Android primaryAction）。 */
@Component
export struct AaPrimaryButton {
  @Prop label: string = '';
  @Prop interactive: boolean = true;
  @Prop loading: boolean = false;
  onTap?: () => void;

  build() {
    Row({ space: Space.S }) {
      if (this.loading) {
        LoadingProgress().width(16).height(16).color(this.actionable() ? onPrimaryAction() : muted())
      }
      // ⚠️ 禁用态只把底色换成 `subtle`（浅灰 #F1F0ED）会把白字洗掉：
      // 真机实测「创建并开始」禁用时整块按钮的亮度对比度只有 13/255，字几乎看不见，
      // 用户以为按钮坏了/页面没渲染完。正解是前景色跟着状态走 ——
      // 可点 → on_primary_action（白字压深底），禁用 → muted（灰字压浅底），
      // 且不叠 opacity（叠了会把两者的对比度同时压低）。深浅色主题都成立。
      Text(this.label)
        .fontSize(FontSize.BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.actionable() ? onPrimaryAction() : muted())
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(Control.BUTTON)
    .borderRadius(Radius.M)
    .backgroundColor(this.actionable() ? primaryAction() : subtle())
    // R39：官方按压态（`stateStyles`）。`normal` 与链式**同源同值** ⇒ 静止态渲染结果逐像素不变；
    // `pressed` 复用列表行那支按下态令牌（`rowPressedSurface()`），**不新增颜色资源**。
    // 依据：`FilesScreen` 的两处同款写法已验收（R20/R21，含 `uinput -T -d` 真触摸两态）；
    // 它同时证明 `stateStyles` 是**逐属性覆盖**而非全接管 —— 该处链式的 height/padding/borderRadius
    // 在 normal 态仍生效（R26 量过行高 60dp、圆角 16dp）。
    .stateStyles({
      normal: { .backgroundColor(this.actionable() ? primaryAction() : subtle()) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      if (this.actionable() && this.onTap !== undefined) {
        this.onTap();
      }
    })
  }

  /**
   * 「可点」的完整口径：交互开启且不在加载中。
   *
   * ⚠️ 名字**不能**叫 `enabled`：`CustomComponent` 基类已有 `enabled(value: boolean)`，
   * 撞名会报 `Property 'enabled' … is not assignable to the same property in base type`
   * （本工程第一轮就踩过一次，见坑 12；此处是同一个坑的复现）。
   */
  private actionable(): boolean {
    return this.interactive && !this.loading;
  }
}

/**
 * 次按钮（描边）。
 *
 * R12-5 起支持**可选矢量图标** `iconName`（纯新增、向后兼容）：不传则与旧版完全等价；
 * 传了就渲染「图标 [+ 文字]」，供搜索命中的上/下一处这类**图标按钮**使用
 * （上游 `FilesScreen` 的 `SearchStepButton(icon = Lucide.ChevronUp/Down)`）。
 */
@Component
export struct AaSecondaryButton {
  @Prop label: string = '';
  /** 矢量图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）。 */
  @Prop iconName: string = '';
  @Prop iconSize: number = FontSize.BUTTON_ICON;
  @Prop interactive: boolean = true;
  @Prop compact: boolean = false;
  /**
   * R66（SPEC §2，用户真机缺陷 ②「功能栏未采用官方方案」）：true = 本按钮**位于 `Navigation` 标题栏内**，
   * 其自绘的 `borderWidth` / `borderColor` / `backgroundColor`（含 `stateStyles` 的按压底）整组换成
   * **官方沉浸光感** `systemMaterial(ImmersiveMaterial)`。
   *
   * ⚠️ 依据（华为 OS 平台行为变更，仅对 `targetSdkVersion >= 26.0.0` 生效，见 `坑 245`）：
   * **其他组件仅在 `Navigation`/`NavDestination` 标题栏、或横向 Tabs 的底部 TabBar 中生效；
   * 在页面正文里设置沉浸光感效果不生效。** ⇒ **只有把按钮放进 `.title(...)` 的页面才能传 true**；
   * 正文里的调用点**必须**保持 false（传 true 只会静默无效，还会丢掉自绘底 ⇒ 钮变空壳）。
   *
   * ⚠️ **缺省 false ⇒ 既有调用点逐像素不变**（R12-5 起的所有调用点都没传它）。
   * ⚠️ 官方文档同时说明：材质会接管 `backgroundColor` / `borderColor` / `borderWidth` / `shadow`，
   * **不建议与它们同时使用** ⇒ 官方分支里这些自绘层**一个都不留**（与 `GlassIcon.ets#officialGlass()` 同口径）。
   */
  @Prop officialMaterial: boolean = false;
  onTap?: () => void;

  /**
   * R66：本按钮是否走官方沉浸光感。
   *
   * 与 `ui/GlassIcon.ets` 的 `useOfficialMaterial()` / `AaTopBar.useOfficialPill()` **逐字同源**：
   * 编译期常量 `TOPBAR_OFFICIAL_MATERIAL`（**跟随既有开关，不新造开关**，SPEC「硬约束」）
   * × 调用点 opt-in。关掉常量时官方分支**整个不渲染** ⇒「材质开 / 关」两包只差这些分支。
   */
  private useOfficialMaterial(): boolean {
    return TOPBAR_OFFICIAL_MATERIAL && this.officialMaterial;
  }

  build() {
    // R66：官方分支**只换「谁在画底」**，几何（高度/圆角/内边距/字号）与自绘分支逐字相同。
    if (this.useOfficialMaterial()) {
      this.officialBody()
    } else if (this.iconName.length > 0) {
      Row({ space: this.label.length > 0 ? Space.XS_PLUS : 0 }) {
        AaIcon({ d: ICONS[this.iconName], iconSize: this.iconSize, color: ink() })
        if (this.label.length > 0) {
          Text(this.label)
            .fontSize(this.compact ? FontSize.SMALL : FontSize.BODY)
            .fontColor(ink())
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: this.compact ? Space.M : Space.L,
        right: this.compact ? Space.M : Space.L,
        top: this.compact ? 6 : 11,
        bottom: this.compact ? 6 : 11
      })
      .borderRadius(Radius.M)
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor(borderColor())
      .backgroundColor($r('app.color.secondary_action_surface'))
      .opacity(this.interactive ? 1 : 0.5)
      // R39：官方按压态。`normal` 只声明底色（未声明的属性回落链式）；`pressed` 用按下态令牌。
      .stateStyles({
        // ⚠️ R39 修正：`stateStyles` 里**一个状态只能写一个链式属性**（多属性用逗号会报
        // 「An object literal cannot have multiple properties with the same name」+「.stateStyles doesn't conform standard」）。
        // 禁用态的 `opacity(0.5)` 不写进 `normal`：`stateStyles` 是**逐属性覆盖**，未声明的属性回落链式（FilesScreen 已验收）。
        normal: { .backgroundColor($r('app.color.secondary_action_surface')) },
        pressed: { .backgroundColor(rowPressedSurface()) }
      })
      .onClick(() => {
        if (this.interactive && this.onTap !== undefined) {
          this.onTap();
        }
      })
    } else {
      Text(this.label)
        .fontSize(this.compact ? FontSize.SMALL : FontSize.BODY)
        .fontColor(ink())
        .textAlign(TextAlign.Center)
        .padding({
          left: this.compact ? Space.M : Space.L,
          right: this.compact ? Space.M : Space.L,
          top: this.compact ? 6 : 11,
          bottom: this.compact ? 6 : 11
        })
        .borderRadius(Radius.M)
        .borderWidth(StrokeWidth.HAIRLINE)
        .borderColor(borderColor())
        .backgroundColor($r('app.color.secondary_action_surface'))
        .opacity(this.interactive ? 1 : 0.5)
        // R39：官方按压态（同带图标那一分支，两处必须一致，否则两种形态手感不同）。
        .stateStyles({
          normal: { .backgroundColor($r('app.color.secondary_action_surface')) },
          pressed: { .backgroundColor(rowPressedSurface()) }
        })
        .onClick(() => {
          if (this.interactive && this.onTap !== undefined) {
            this.onTap();
          }
        })
    }
  }

  /**
   * R66：**官方沉浸光感 only** 的次按钮（零自绘层）。
   *
   * ⚠️ 与上面两个自绘分支**互斥**（`useOfficialMaterial()`），同一时刻只渲染一个；两处几何
   * （`padding` 的 `compact ? 6 : 11` / `borderRadius(Radius.M)` / 字号 / 图标尺寸 / `space`）
   * **逐字复制**，只把「边框 + 实底 + 按压底」换成一层材质 —— 这样「材质开 / 关」两包的差异可以
   * 逐像素归因给材质本身。
   * ⚠️ 自绘分支的 R39 按压态（`stateStyles` 改 `backgroundColor`）在这里**故意不写**：
   * 官方材质自带的 `interactive: true` 就是按压反馈，再叠 backgroundColor 会与材质打架。
   * `opacity(this.interactive ? 1 : 0.5)` 保留 —— 它表达「不可点」，不是底色层。
   */
  @Builder
  officialBody() {
    if (this.iconName.length > 0) {
      Row({ space: this.label.length > 0 ? Space.XS_PLUS : 0 }) {
        AaIcon({ d: ICONS[this.iconName], iconSize: this.iconSize, color: ink() })
        if (this.label.length > 0) {
          Text(this.label)
            .fontSize(this.compact ? FontSize.SMALL : FontSize.BODY)
            .fontColor(ink())
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: this.compact ? Space.M : Space.L,
        right: this.compact ? Space.M : Space.L,
        top: this.compact ? 6 : 11,
        bottom: this.compact ? 6 : 11
      })
      .borderRadius(Radius.M)
      .systemMaterial(officialBarMaterial(glassCardSurface()))
      .opacity(this.interactive ? 1 : 0.5)
      .onClick(() => {
        if (this.interactive && this.onTap !== undefined) {
          this.onTap();
        }
      })
    } else {
      Text(this.label)
        .fontSize(this.compact ? FontSize.SMALL : FontSize.BODY)
        .fontColor(ink())
        .textAlign(TextAlign.Center)
        .padding({
          left: this.compact ? Space.M : Space.L,
          right: this.compact ? Space.M : Space.L,
          top: this.compact ? 6 : 11,
          bottom: this.compact ? 6 : 11
        })
        .borderRadius(Radius.M)
        .systemMaterial(officialBarMaterial(glassCardSurface()))
        .opacity(this.interactive ? 1 : 0.5)
        .onClick(() => {
          if (this.interactive && this.onTap !== undefined) {
            this.onTap();
          }
        })
    }
  }
}

/**
 * 主图标按钮（34vp 圆形）—— 发送类动作的统一形态。
 *
 * R38 新增（用户需求「软件所有发送功能都用图标取代，并尽量放在对话框右下角」）：
 * 把会话输入区那颗主按钮的形态抽成共用组件，供**终端粘贴弹层的发送**与**会话审批卡的提交**复用。
 * 三处各写一遍必然漂移（坑 216 的反面用法：这里的默认值**等于既有外观**，不是折中值）。
 *
 * 形态逐项对齐既有实现（锚文 `private composerPrimaryButton()`，`ui/screens/SessionDetailScreen.ets`）：
 *  · 边长 34 / 圆角 PILL / 图标 `FontSize.ICON_MD`(16)；
 *  · 可点 → `primaryAction` 底 + `onPrimaryAction` 图标；
 *  · 不可点 → `subtle` 底 + `muted` 图标（**不能**只换底色、图标仍旧用白 —— 真机实测白线压
 *  浅灰底的对比度只有 13/255，箭头等于消失）；
 *  · `danger` → `btn_danger_bg` 底 + `onPrimaryAction` 图标（中断族那个红底方块用的是同一个底）。
 *
 * ⚠️ 参数名不得叫 `enabled` / `size` / `border`：`CustomComponent` 基类已占用这些名字，撞名会报
 * «Property 'x' … is not assignable to the same property in base type»（与 `AaPrimaryButton` 的
 * `actionable`、`AaCircleIconButton` 的 `ringColor` 是同一类坑）。
 */
@Component
export struct AaPrimaryIconButton {
  /** 图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）。 */
  @Prop name: string = '';
  /** 直径（vp）—— 默认即上游主按钮的 34dp。 */
  @Prop diameter: number = 34;
  @Prop iconSize: number = FontSize.ICON_MD;
  @Prop interactive: boolean = true;
  /** true = 危险族红底（中断），false = 主色底（发送）。 */
  @Prop danger: boolean = false;
  /** 无障碍文本 —— 图标取代文字之后，这是 dumpLayout / 读屏唯一的语义载体。 */
  @Prop accessibilityLabel: string = '';
  onTap?: () => void;

  /** 底色：危险族 > 可点 > 禁用。 */
  private surfaceColor(): Resource {
    if (this.danger) {
      return $r('app.color.btn_danger_bg');
    }
    return this.interactive ? primaryAction() : subtle();
  }

  /** 图标线色：危险族恒用主前景色；其余跟可点态走。 */
  private iconColor(): Resource {
    if (this.danger) {
      return onPrimaryAction();
    }
    return this.interactive ? onPrimaryAction() : muted();
  }

  build() {
    Row() {
      AaIcon({ d: ICONS[this.name], iconSize: this.iconSize, color: this.iconColor() })
    }
    .width(this.diameter)
    .height(this.diameter)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.PILL)
    .backgroundColor(this.surfaceColor())
    // R39：官方按压态（`normal` 走同一个 `surfaceColor()` ⇒ 静止态不变）。
    // R43 审计修正（F2 同族）：`pressed` 也必须按可点态分流 —— `stateStyles` 是布局层属性，
    // 不受 `onClick` 里那句 `interactive` 守卫的约束，禁用态按下去照样整颗变按下色，
    // 于是「灰按钮按下去有反馈、抬手却什么也没发生」。禁用时回落 `surfaceColor()`
    // （同 `normal` ⇒ 视觉上完全无按压反馈），可点态保持原样。
    .stateStyles({
      normal: { .backgroundColor(this.surfaceColor()) },
      pressed: { .backgroundColor(this.interactive ? rowPressedSurface() : this.surfaceColor()) }
    })
    .accessibilityText(this.accessibilityLabel)
    .onClick(() => {
      if (this.interactive && this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}

/** 小圆角标签（状态 / Runtime 名 / 工作区）。 */
@Component
export struct AaChip {
  @Prop label: string = '';
  @Prop emphasized: boolean = false;
  @Prop color: Resource = faint();

  build() {
    Row({ space: Space.XS }) {
      if (this.emphasized) {
        Circle().width(6).height(6).fill(this.color)
      }
      Text(this.label)
        .fontSize(FontSize.CAPTION)
        .fontColor(this.emphasized ? ink() : muted())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding({ left: Space.M, right: Space.M, top: Space.XXS, bottom: Space.XXS })
    .borderRadius(Radius.PILL)
    .backgroundColor(subtle())
  }
}

/** 空状态。 */
@Component
export struct AaEmptyState {
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop actionLabel: string = '';
  onAction?: () => void;

  build() {
    Column({ space: Space.M }) {
      Text(this.title)
        .fontSize(FontSize.TITLE)
        .fontColor(ink())
      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(FontSize.SMALL)
          .fontColor(muted())
          .textAlign(TextAlign.Center)
      }
      if (this.actionLabel.length > 0) {
        AaSecondaryButton({ label: this.actionLabel, onTap: this.onAction })
      }
    }
    .width('100%')
    .padding(Space.XL)
    .justifyContent(FlexAlign.Center)
  }
}

/** 错误条（可点重试）。 */
@Component
export struct AaErrorBanner {
  @Prop message: string = '';
  @Prop retryLabel: string = '重试';
  onRetry?: () => void;
  onDismiss?: () => void;

  build() {
    if (this.message.length > 0) {
      Row({ space: Space.S }) {
        // 上游 `Components.kt` 的 AuthErrorNotice：Lucide.CircleAlert 20dp。
        Column() {
          AaIcon({ d: ICONS['circle-alert'], iconSize: 20, color: $r('app.color.error_icon') })
        }
        .width(20)
        .alignItems(HorizontalAlign.Center)
        Text(this.message)
          .fontSize(FontSize.SMALL)
          .fontColor(errorText())
          .layoutWeight(1)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.onRetry !== undefined) {
          Text(this.retryLabel)
            .fontSize(FontSize.SMALL)
            .fontColor(errorText())
            .onClick(() => {
              if (this.onRetry !== undefined) {
                this.onRetry();
              }
            })
        }
        if (this.onDismiss !== undefined) {
          Column() {
            AaIcon({ d: ICONS['x'], iconSize: 16, color: errorText() })
          }
          .onClick(() => {
            if (this.onDismiss !== undefined) {
              this.onDismiss();
            }
          })
        }
      }
      .width('100%')
      .padding(Space.M)
      .borderRadius(Radius.M)
      .backgroundColor($r('app.color.error_surface'))
      .borderWidth(StrokeWidth.HAIRLINE)
      .borderColor($r('app.color.error_border'))
      .margin({ left: Space.M, right: Space.M, bottom: Space.S })
    }
  }
}

/** 键值信息行。 */
@Component
export struct AaInfoRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop selectable: boolean = false;

  build() {
    Row({ space: Space.M }) {
      Text(this.label)
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .width(88)
      // `selectable` 之前是两个分支写了同一个枚举值（等于参数完全失效），
      // 而且长值统一 `maxLines(4)+Ellipsis`：设备 ID / 用户 ID / 服务器地址
      // 既被截断、又没法选中复制。现在：可选中 → FOCUSABLE（触摸即获焦，出选择手柄与复制菜单）
      // 且不截断；不可选中 → UNSELECTABLE。
      if (this.selectable) {
        Text(this.value.length > 0 ? this.value : '—')
          .fontSize(FontSize.SMALL)
          .fontColor(ink())
          .layoutWeight(1)
          .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
          .copyOption(CopyOptions.InApp)
      } else {
        Text(this.value.length > 0 ? this.value : '—')
          .fontSize(FontSize.SMALL)
          .fontColor(ink())
          .layoutWeight(1)
          .textSelectable(TextSelectableMode.UNSELECTABLE)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ top: Space.XS, bottom: Space.XS })
    .alignItems(VerticalAlign.Top)
  }
}

/** 分组标题。 */
@Component
export struct AaSectionHeader {
  @Prop title: string = '';
  @Prop trailing: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(muted())
        .layoutWeight(1)
      if (this.trailing.length > 0) {
        Text(this.trailing)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
      }
    }
    .width('100%')
    .padding({ left: Space.M, right: Space.M, top: Space.M, bottom: Space.XS })
  }
}
// ---------------------------------------------------------------------------
// 第九轮（首页结构对齐安卓端）新增：顶栏图标按钮 / 快捷卡片 / 分组头 / 悬浮按钮 / 菜单行
// ---------------------------------------------------------------------------

/**
 * 圆形图标按钮（对应 Android `ui/screens/home/HomeScreen.kt` 的 `RoundLucideButton`）。
 *
 * 上游用 Lucide 矢量图标（`RoundLucideButton`：42 圆 + 21dp 图标 / 搜索位 24dp）。
 * R12 起本工程也有矢量图标体系（`ui/Icon.ets`），这里直接渲染 `AaIcon` —— 不再用字符近似。
 *
 * ⚠️ 参数名**不能**叫 `enabled`：`CustomComponent` 基类已占用该名字，撞名会报
 * `Property 'enabled' … is not assignable to the same property in base type`（EXPERIENCE §5）。
 */
@Component
export struct AaCircleIconButton {
  /** 图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）。 */
  @Prop name: string = '';
  @Prop diameter: number = 42;
  @Prop iconSize: number = 20;
  /** true = 带底色与描边（上游头像位）；false = 透明（上游搜索位）。 */
  @Prop filled: boolean = true;
  @Prop interactive: boolean = true;
  @Prop tint: Resource = ink();
  @Prop surface: Resource = raisedSurface();
  /**
   * ⚠️ 不能叫 border：CustomComponent 基类已有同名通用属性方法，
   * 自定义组件里定义同名成员会报 «Property 'border' ... is not assignable to the same property in base type 'CustomComponent'»（第九轮首次构建实测）。
   */
  @Prop ringColor: Resource = borderColor();
  /**
   * R57（T2b「功能栏液态玻璃化」）：true = 走**玻璃档**。
   *
   * 玻璃档把渲染整体委托给 `ui/GlassIcon.ets` 的 `AaGlassIconButton`（磨砂 + 1vp 渐变亮边 +
   * 左上镜面高光 + 柔和外阴影）—— **不是**在本文件里再拼一套。此时 `filled` /
   * `surface` / `ringColor` 三个参数不参与（玻璃盘自带底与亮边），`tint` / `diameter` /
   * `iconSize` / `interactive` 照旧生效。
   *
   * 缺省 false ⇒ 既有调用点**逐像素不变**（suite-settings 的 F-10「圆底 + 描边」断言正是按
   * 非玻璃档那两条链式写法校验的，别把它们删了）。
   */
  @Prop glass: boolean = false;
  /**
   * R65-T1：玻璃档下是否走**官方沉浸光感**（**原样透传**给 `AaGlassIconButton.officialMaterial`）。
   *
   * ⚠️ 缺省 false ⇒ 既有调用点**逐像素不变**（本轮硬约束：只有首页顶栏两个钮传 true）。
   * 生效范围（官方只认 `Navigation` 标题栏等四类位置）见 `坑 245`。
   */
  @Prop officialMaterial: boolean = false;
  /** 玻璃档的无障碍文本（非玻璃档忽略；纯图标钮在 dumpLayout / 读屏里只有这一个语义载体）。 */
  @Prop accessibilityLabel: string = '';
  onTap?: () => void;

  build() {
    if (this.glass) {
      // 玻璃档：四层合成只定义一次（`ui/GlassIcon.ets`）。这里只做**参数映射**。
      AaGlassIconButton({
        name: this.name,
        diameter: this.diameter,
        iconSize: this.iconSize,
        tint: this.tint,
        interactive: this.interactive,
        // R65-T1：官方材质 opt-in **原样透传**（缺省 false ⇒ 其它页面逐像素不变）。
        officialMaterial: this.officialMaterial,
        accessibilityLabel: this.accessibilityLabel,
        onTap: this.onTap
      })
    } else {
      this.flatButton()
    }
  }

  /** 非玻璃档（R12 起的原实现，逐字保留 —— 见 `glass` 的注释）。⚠️ `@Builder` 不带 `private`（本工程 245 个 builder 一致）。 */
  @Builder
  flatButton() {
    Column() {
      AaIcon({ d: ICONS[this.name], iconSize: this.iconSize, color: this.tint })
    }
    .width(this.diameter)
    .height(this.diameter)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(this.diameter / 2)
      .backgroundColor(this.filled ? this.surface : Color.Transparent)
      // R39：官方按压态。`normal` 与链式**逐字同一个表达式** ⇒ 静止态不变；
      // ⚠️ `filled = false` 时静止态本来就是 `Color.Transparent`，按下时给底色是**新增**的反馈
      //  （上游 Compose 的 `clickable` 带 ripple，本工程原先完全没有这一层）。
      .stateStyles({
        normal: { .backgroundColor(this.filled ? this.surface : Color.Transparent) },
        pressed: { .backgroundColor(rowPressedSurface()) }
      })
      .borderWidth(this.filled ? 1 : 0)
      .borderColor(this.ringColor)
      .opacity(this.interactive ? 1 : 0.4)
      .onClick(() => {
        if (this.interactive && this.onTap !== undefined) {
          this.onTap();
        }
      })
  }
}

/**
 * 右下角悬浮按钮（对应 Android `FloatingHomeButton`）：深色实心圆 + 「+」。
 *
 * ⚠️ 它是 `Stack` 里的**悬浮层**，尺寸只有 diameter×diameter、不铺满，
 * 因此不会挡住下层列表的点击（铺满的兄弟容器才会，见坑 29）。
 *
 * ⚠️ 外边距写成 `insetRight` / `insetBottom` **参数**而不是让调用方挂 `.margin()`：
 * 「自定义组件后接通用属性」虽然在 SDK 里可用（`BaseCustomComponent extends CommonAttribute`），
 * 但本工程此前零先例，参数化后不再依赖那条不确定的语法。
 */
@Component
export struct AaFloatingButton {
  /** 图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）；上游是 Lucide.Plus 24dp。 */
  @Prop name: string = 'plus';
  @Prop diameter: number = 54;
  /** 距屏幕右侧的内缩（vp）。 */
  @Prop insetRight: number = 0;
  /** 距屏幕底部的内缩（vp）。 */
  @Prop insetBottom: number = 0;
  /**
   * R57（T2b「功能栏液态玻璃化」）：true = 玻璃档。
   *
   * 与圆形图标钮的玻璃档**共用同一个实现**（`ui/GlassIcon.ets` 的 `AaGlassIconButton`），
   * 差别只在玻璃底：这里传 `glassPrimarySurface()`（主色 85%）。
   * 为什么不用那档 25% 的白玻璃：悬浮「+」是页面上最强的动作，白玻璃配白图标直接糊掉
   * （浅色下近不可读）⇒ 用主色 85% 既留住 15% 的透光，又保住图标对比度。
   * 缺省 false ⇒ 老调用点（深色实心圆）逐像素不变。
   */
  @Prop glass: boolean = false;
  /** 无障碍文本（纯图标钮在 dumpLayout / 读屏里的唯一语义载体）。 */
  @Prop accessibilityLabel: string = '';
  onTap?: () => void;

  build() {
    if (this.glass) {
      // ⚠️ 外缩仍走 `margin`，但它挂在**外层 Column** 上而不是「自定义组件后接通用属性」——
      //  本工程对那条语法零先例（见本组件原注释），且 `Column` 的盒子 = 钮的盒子，
      //  玻璃层仍在子节点里画，不会像铺满容器那样吃掉点击。
      Column() {
        AaGlassIconButton({
          name: this.name,
          diameter: this.diameter,
          iconSize: FontSize.ICON_LARGE,
          tint: onPrimaryAction(),
          surface: glassPrimarySurface(),
          accessibilityLabel: this.accessibilityLabel,
          onTap: this.onTap
        })
      }
      .margin({ right: this.insetRight, bottom: this.insetBottom })
    } else {
      this.solidButton()
    }
  }

  /** 非玻璃档（R9 起的原实现：深色实心圆 + 主前景色图标）。同上：`@Builder` 不带 `private`。 */
  @Builder
  solidButton() {
    Column() {
      AaIcon({ d: ICONS[this.name], iconSize: 24, color: onPrimaryAction() })
    }
    .width(this.diameter)
    .height(this.diameter)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(this.diameter / 2)
      .backgroundColor(primaryAction())
      .accessibilityText(this.accessibilityLabel)
      .margin({ right: this.insetRight, bottom: this.insetBottom })
      .onClick(() => {
        if (this.onTap !== undefined) {
          this.onTap();
        }
      })
  }
}

/**
 * 弹层内的整行操作项（对应 Android `HomeProjectActionRow`：文案在左、图标在右）。
 *
 * `active` 用于筛选菜单的当前选项打勾（上游 `AADropdownMenuItem.selected`）。
 */
@Component
export struct AaMenuActionRow {
  @Prop label: string = '';
  /** 矢量图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）；留空则回退到字符图标。 */
  @Prop iconName: string = '';
  /** 字符图标（R12 之前的历史写法，其它页面仍在用；新代码请用 iconName）。 */
  @Prop icon: string = '';
  @Prop danger: boolean = false;
  @Prop active: boolean = false;
  /**
   * 选中打勾的颜色。上游 `AADropdownMenu.kt:160` 是 `Icon(Lucide.Check, tint = textColor)`（= ink）；
   * 「会话状态」就地弹窗（R13-9）按上游传 `ink()`，其它调用点保持历史默认值（品牌绿）不动。
   */
  @Prop activeTint: Resource = $r('app.color.session_status_accent');
  /**
   * 行高。下拉菜单项 = 48（上游 `heightIn(min = 48.dp)`，安卓 dump 行距 143px = 48.07dp）；
   * 动作卡里的行 = 50（上游 `HomeProjectActionRow.height(50.dp)`）＝ 本默认值。
   */
  @Prop rowHeight: number = Control.MENU_ROW;
  @Prop interactive: boolean = true;
  /**
   * 文案字号。**两种上游行不一样，别用同一个值糊过去**（R25 实测缺陷）：
   *  · 下拉菜单项 `AADropdownMenuItem`（`AADropdownMenu.kt:143`）= **14.sp**；
   *  · 项目动作卡行 `HomeProjectActionRow`（`HomeProjectComponents.kt:602`）= **16.sp**。
   * 默认沿用本组件历史值（`FontSize.BODY` = 15），调用点按上游显式传。
   */
  @Prop textSize: number = FontSize.BODY;
  /**
   * 文案左右内边距。上游下拉项 `padding(horizontal = 16.dp)`、动作卡行 `horizontal = 20.dp`。
   */
  @Prop padH: number = Space.L;
  /**
   * 文案是否加粗。上游下拉项是 `SemiBold`、动作卡行是 `Bold`；二者在中文字重上的差别
   * 在本工程不可用（**没有 `FontWeight.SemiBold`**，见 `Components.ets:775` 的既有约定）⇒ 统一取 `Bold`。
   * 默认 `false` 保持本组件历史外观，调用点按上游显式传。
   */
  @Prop boldText: boolean = false;
  onTap?: () => void;

  build() {
    Row({ space: Space.M }) {
      Text(this.label)
        .fontSize(this.textSize)
        .fontWeight(this.boldText ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.danger ? errorText() : ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.active) {
        // 上游 `AADropdownMenu.kt:160`：Lucide.Check 18dp。
        AaIcon({ d: ICONS['check'], iconSize: 18, color: this.activeTint })
      }
      if (this.iconName.length > 0) {
        // 上游 `HomeProjectComponents.kt:603`：动作行图标 21dp。
        AaIcon({ d: ICONS[this.iconName], iconSize: 21, color: this.danger ? errorText() : muted() })
      } else if (this.icon.length > 0) {
        Text(this.icon)
          .fontSize(FontSize.ICON)
          .fontColor(this.danger ? errorText() : muted())
      }
    }
    .width('100%')
    .height(this.rowHeight)
    .padding({ left: this.padH, right: this.padH })
    .opacity(this.interactive ? 1 : 0.5)
    // R39：官方按压态。本组件链式**没有** backgroundColor（弹层里靠卡片自身底色），
    // 所以 `normal` 显式给 `Color.Transparent`（= 与改前完全等价），`pressed` 才给底色 ——
    // 与上游 `FileListRow` 的「静止态透明、按下才着色」同款语义。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      if (this.interactive && this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}

/**
 * 锚定弹层里的**单选行**（对应 Android `AADropdownMenuItem`：`icon` 在**左**、文案居中偏左、选中时右侧打勾）。
 *
 * ⚠️ 与 `AaMenuActionRow` 的区别（**别混用**）：后者是「文案在左、图标在右」的动作行（上游 `HomeProjectActionRow`），
 * 这个是设置页选值用的单选行（上游 `AADropdownMenuItem(text, icon, selected)`），
 * 两者图标位置相反 —— 上游就是两个不同组件，不是同一套样式。
 *
 * 逐项对齐上游 `AADropdownMenu.kt:108-138`：行高 min 48 / 左右内边距 16 / 图标 20dp / 间距 12 /
 * 文案 14sp SemiBold / 选中打勾 18dp（`:160` `Icon(Lucide.Check, tint = textColor)`）。
 */
@Component
export struct AaDropdownMenuItem {
  @Prop label: string = '';
  /** 矢量图标名（kebab-case，见 `ui/Icon.ets` 的 ICONS）。 */
  @Prop iconName: string = '';
  @Prop active: boolean = false;
  onTap?: () => void;

  build() {
    Row({ space: Space.M }) {
      if (this.iconName.length > 0) {
        AaIcon({ d: ICONS[this.iconName], iconSize: 20, color: ink() })
      }
      Text(this.label)
        .fontSize(FontSize.BODY_SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.active) {
        AaIcon({ d: ICONS['check'], iconSize: 18, color: ink() })
      }
    }
    .width('100%')
    .height(Control.MENU_ITEM_MIN)
    .padding({ left: Space.L, right: Space.L })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}

/**
 * 配置卡下拉菜单里的**带副标题单选行**（上游 `AADropdownMenuItem` 带 `supportingText` / `enabled` 的形态）。
 *
 * 与 `AaDropdownMenuItem` 的差别：多了 11sp 副标题、禁用态（文案 α0.42）、未选中时右侧留 18dp 占位。
 * 逐项对齐上游 `AADropdownMenu.kt:108-162`：行高 min 48 / 左右内边距 16 / 上下 8 / 文字列与打勾间距 12 /
 * 文案 14sp SemiBold（ArkTS 无 SemiBold，取 Bold）/ 副标题 11sp inkSoft α0.72 / 打勾 18dp。
 */
@Component
export struct AaConfigMenuItem {
  @Prop label: string = '';
  /** 副标题：可用时是说明，不可用时是服务端给的原因（上游 `disabledReason`）。留空则不占位。 */
  @Prop detail: string = '';
  @Prop active: boolean = false;
  /**
   * 是否可点（上游 `AADropdownMenuItem.enabled`）。
   *
   * ⚠️ 名字**不能叫 `enabled`**：`CustomComponent` 基类已有 `enabled`，同名会报
   * `Property 'enabled' ... is not assignable to the same property in base type 'CustomComponent'`。
   */
  @Prop usable: boolean = true;
  /**
   * **只显示名字、不显示副标题**（R93 用户：「去掉预设的描述，只留名字」）。
   *
   * ⚠️ **必须做成开关而不是直接删掉 `detail`**：本组件有 9 个调用点（模型 / 推理强度 / 权限 /
   *  设备 / 新建会话预设 / 设置页预设 …），副标题对模型与权限是**必要信息**（模型靠它区分同族
   *  档位、权限靠它显示不可用原因）。用户的要求只针对**预设**这一处 ⇒ 加可选开关，其余调用点
   *  逐字未变（`detail` 传了也照常渲染）。
   * ⚠️ 关掉时**不可用原因不能跟着丢**：调用点要用自己的提示通道把它说出来（见 SettingsScreen /
   *  SessionDetailScreen 的 `actionHint` 用法）。
   */
  @Prop hideDetail: boolean = false;
  onTap?: () => void;

  build() {
    Row({ space: Space.M }) {
      Column({ space: Space.XXS }) {
        Text(this.label)
          .fontSize(FontSize.BODY_SMALL)
          .fontWeight(FontWeight.Bold)
          .fontColor(ink())
          .opacity(this.usable ? 1 : 0.42)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // R93：`hideDetail` 只对**预设**这一处开启（见该字段的注释）。
        if (!this.hideDetail && this.detail.length > 0) {
          Text(this.detail)
            .fontSize(FontSize.CAPTION)
            .fontColor(inkSoft())
            .opacity(this.usable ? 0.72 : 0.42)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.active) {
        AaIcon({ d: ICONS['check'], iconSize: 18, color: ink() })
      } else {
        Row().width(18).height(18)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: Control.MENU_ITEM_MIN })
    .padding({ left: Space.L, right: Space.L, top: Space.S, bottom: Space.S })
    // R39：官方按压态。本行是配置卡下拉里的**选项行**（`NewSessionScreen` 的 model / reasoning /
    // permission / device 四类选项都包这个组件）⇒ 按压态加在**组件内**一处，调用点不用各写一遍
    // （与坑 216 的「共用组件就该在组件内收口」同一个道理）。
    // `normal` 透明（本行链式无底色）；禁用态靠**文案** opacity，不受影响；单属性约束见坑 227。
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(rowPressedSurface()) }
    })
    .onClick(() => {
      if (this.usable && this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}

/** 弹层内的只读字段（对应 Android `ProjectReadOnlyField`）。 */
@Component
export struct AaReadOnlyField {
  @Prop value: string = '';
  @Prop mono: boolean = false;

  build() {
    Row() {
      Text(this.value.length > 0 ? this.value : '—')
        .fontSize(this.mono ? FontSize.SMALL : FontSize.BODY)
        .fontColor(faint())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(Control.FIELD)
    .padding({ left: Space.M, right: Space.M })
    .borderRadius(Radius.M)
    .backgroundColor(subtle())
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
  }
}

/** 对话框几何族：`confirm` = 上游 `DeviceConfirmDialog` / `TakeoverConfirmDialog`；`profile` = 上游 `ProfileDialog`。 */
export const DIALOG_VARIANT_CONFIRM: string = 'confirm';
export const DIALOG_VARIANT_PROFILE: string = 'profile';

/**
 * 通用确认框**内容**（R13-14）：标题 + 正文 + 可选错误行 + 两枚等宽按钮。
 *
 * 外层几何（宽 / 圆角 / 边框 / 阴影 / 底色）由 `openAaConfirmDialog()` 通过
 * `promptAction.CustomDialogOptions` 给 —— 与上游「自绘 Dialog + `usePlatformDefaultWidth = false`」同构：
 * 尺寸在**外层**定死，内容只负责内边距与排布。
 */
@Component
export struct AaConfirmDialog {
  @Prop variant: string = DIALOG_VARIANT_CONFIRM;
  @Prop title: string = '';
  @Prop body: string = '';
  @Prop confirmLabel: string = '';
  @Prop dismissLabel: string = '取消';
  @Prop danger: boolean = false;
  @Prop busy: boolean = false;
  @Prop errorMessage: string = '';
  onConfirm?: () => void;
  onDismiss?: () => void;

  private isProfile(): boolean {
    return this.variant === DIALOG_VARIANT_PROFILE;
  }

  build() {
    Column({ space: this.isProfile() ? ProfileDialogSpec.CONTENT_GAP : DialogSpec.CONTENT_GAP }) {
      Text(this.title)
        .fontSize(this.isProfile() ? ProfileDialogSpec.TITLE_SIZE : DialogSpec.TITLE_SIZE)
        // 上游：确认族是 ExtraBold，Profile 族是 SemiBold。
        .fontWeight(this.isProfile() ? FontWeight.Medium : FontWeight.Bolder)
        .lineHeight(this.isProfile() ? ProfileDialogSpec.TITLE_LINE_HEIGHT : DialogSpec.TITLE_LINE_HEIGHT)
        .fontColor(ink())
        .width('100%')
      Text(this.body)
        .fontSize(this.isProfile() ? ProfileDialogSpec.BODY_SIZE : DialogSpec.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .lineHeight(this.isProfile() ? ProfileDialogSpec.BODY_LINE_HEIGHT : DialogSpec.BODY_LINE_HEIGHT)
        .fontColor(muted())
        .width('100%')
      if (this.errorMessage.length > 0) {
        // 上游 `DeviceConfirmDialog.kt:171-179`：错误行 13sp SemiBold / lineHeight 17 / errorText。
        Text(this.errorMessage)
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .lineHeight(17)
          .fontColor(errorText())
          .width('100%')
      }
      Row({ space: this.isProfile() ? ProfileDialogSpec.BUTTON_GAP : DialogSpec.BUTTON_GAP }) {
        this.dialogButton(this.dismissLabel, false)
        this.dialogButton(this.confirmLabel, true)
      }
      .width('100%')
      .padding({ top: this.isProfile() ? 0 : DialogSpec.BUTTON_TOP })
    }
    .width('100%')
    .padding(this.isProfile() ? ProfileDialogSpec.PADDING : DialogSpec.PADDING)
    .alignItems(HorizontalAlign.Start)
  }

  /** 按钮（确认族：高 50 / 圆角 16 / 15fp Bold；Profile 族：高 46 / 圆角 14 / 14fp SemiBold）。 */
  @Builder
  dialogButton(label: string, primary: boolean) {
    Text(label)
      .fontSize(this.isProfile() ? ProfileDialogSpec.BUTTON_TEXT_SIZE : DialogSpec.BUTTON_TEXT_SIZE)
      .fontWeight(this.isProfile() ? FontWeight.Medium : FontWeight.Bold)
      .lineHeight(this.isProfile() ? 0 : DialogSpec.BUTTON_TEXT_LINE_HEIGHT)
      .fontColor(primary ? onPrimaryAction() : ink())
      .height(this.isProfile() ? ProfileDialogSpec.BUTTON_HEIGHT : DialogSpec.BUTTON_HEIGHT)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(this.isProfile() ? ProfileDialogSpec.BUTTON_RADIUS : DialogSpec.BUTTON_RADIUS)
      .backgroundColor(primary ? this.primaryBackground() : subtle())
      .opacity(this.busy ? 0.55 : 1)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .onClick(() => {
        if (primary) {
          if (this.onConfirm !== undefined) {
            this.onConfirm();
          }
        } else if (this.onDismiss !== undefined) {
          this.onDismiss();
        }
      })
  }

  /** 主按钮底色：`danger` 用上游 `DeviceConfirmDialog.kt:141` 的 `#EF4444`，否则主色。 */
  private primaryBackground(): ResourceColor {
    return this.danger ? Color.Red : primaryAction();
  }
}

/**
 * R85：**对话框是否走官方沉浸光感**（编译期常量，一键回退用）。
 *
 * `true` = 外层几何交给官方材质（`backgroundColor` / `borderWidth` / `borderColor` / `shadow` 整组不下发）；
 * `false` = 逐字回到 R84 的自绘玻璃几何（`dialogSurface()` + 描边 + 投影）。
 *
 * ⚠️ 回退只改这一行：改回 `false` 后重新构建即可，其余代码不用动。
 */
export const R85_DIALOG_OFFICIAL_MATERIAL: boolean = true;

/** 对话框外层几何（自绘档的值；官方材质档下四层全部为 `undefined`）。 */
interface DialogGeometry {
  width: number;
  cornerRadius: number;
  backgroundColor: ResourceColor | undefined;
  // ⚠️ 必须是 `Dimension`（= PX|VP|FP|LPX|Percentage|Resource），**不能**用 `Length`：
  //  `Length = string | number | Resource`（SDK `units.d.ts:94`）比 `Dimension` 多一个裸 `string`，
  //  而 `promptAction.CustomDialogOptions.borderWidth` 的签名是 `Dimension | EdgeWidths`
  //  （SDK `@ohos.promptAction.d.ts:1362`）⇒ 用 `Length` 会让整个对象字面量**匹配不上重载**，
  //  报错还伪装成 `Type 'Length' is not assignable to type 'EdgeWidths | Dimension'`（R85 集成构建实测）。
  //  R84 之所以没踩到，是因为当时该值**内联**在字面量里（number 直接命中 VP 档），没有中间接口。
  borderWidth: Dimension | undefined;
  borderColor: ResourceColor | undefined;
  shadow: ShadowOptions | undefined;
}

/**
 * 对话框外层几何：**官方材质档下发几何为 `undefined`，自绘档逐字返回 R84 的值**。
 *
 * ## 为什么官方档要把四层设成 `undefined`（而不是干脆不写这几个字段）
 * 这两个选项对象里 `backgroundColor` 等字段**本身是可选**的，但 `promptAction.CustomDialogOptions`
 * 的缺省值**不是**"透明"——R84 的几何就是靠显式下发这几个字段才成立的。
 * 官方约束（材质**接管** `backgroundColor` / `borderColor` / `borderWidth` / `shadow`，
 * `SDK common.d.ts:22625-22633`）要求：要开材质，就**不能**再自己画这四层。
 * 于是官方档显式传 `undefined` —— 语义 = "本属性不设置"，正是"整组不下发"的可读表达，
 * 也比 `if/else` 两份选项字面量更不容易漏字段（两份字面量最容易在将来漏同步一处）。
 *
 * ⚠️ 与 `systemMaterial` 的 `undefined` **不是一回事**：那个字段的 `undefined` = 「恢复组件默认材质」
 * （`SDK common.d.ts:22632-22633`），所以本工程关档一律显式传 `uiMaterial.Material.empty`
 * （= disable，`SDK uiMaterial.d.ts:467-472`；`坑 245` 第 5 条）。
 */
function customDialogGeometry(variant: string, width: number): DialogGeometry {
  if (R85_DIALOG_OFFICIAL_MATERIAL && immersiveMaterialEnabled()) {
    return {
      width: width,
      cornerRadius: variant === DIALOG_VARIANT_PROFILE ? ProfileDialogSpec.RADIUS : DialogSpec.RADIUS,
      backgroundColor: undefined,
      borderWidth: undefined,
      borderColor: undefined,
      shadow: undefined
    };
  }
  return {
    width: width,
    cornerRadius: variant === DIALOG_VARIANT_PROFILE ? ProfileDialogSpec.RADIUS : DialogSpec.RADIUS,
    backgroundColor: dialogSurface(),
    borderWidth: DialogSpec.BORDER_WIDTH,
    borderColor: borderColor(),
    shadow: variant === DIALOG_VARIANT_PROFILE
      ? undefined
      : { radius: DialogSpec.SHADOW_RADIUS, color: appShadow() }
  };
}


/**
 * 打开通用确认框（几何 + 遮罩语义在这里统一定死，避免每处各写一遍）。
 *
 * @param ui `this.getUIContext()`
 * @param content 内容 builder（通常是 `() => { AaConfirmDialog({...}) }`）
 * @param variant `DIALOG_VARIANT_CONFIRM` / `DIALOG_VARIANT_PROFILE`
 * @returns dialogId（交给 `closeAaConfirmDialog()`）
 */
export function openAaConfirmDialog(
  ui: UIContext, content: CustomBuilder, variant: string
): Promise<number> {
  const width = dialogWidthVp(variant);
  // ⚠️ `openCustomDialog` 被 ArkTS 判为「可能抛异常」，必须显式处理（零告警要求，见 [坑 144]）。
  // 同步抛出的情况转成 **reject**：调用方各自 `.catch()` 决定降级语义
  // （设备确认框是「拒绝执行 + 提示重试」，退出登录是「照常退出」）。
  //
  // ## R85：外层几何改由**官方沉浸光感**接管（本函数是**唯一入口** ⇒ 一处开、11 个确认框全开）
  // · 官方依据：`PromptAction.openCustomDialog` 的 `CustomDialogOptions.systemMaterial`
  //  （SDK `@ohos.promptAction.d.ts:1796`，类型 `SystemUiMaterial` = `uiMaterial.Material`，
  //  `common.d.ts:16964`）；且「弹窗类接口」按官方「生效范围」**在页面内全部区域生效**
  // （`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）。
  // · 硬约束 2（材质与自绘层不共存）：`backgroundColor` / `borderWidth` / `borderColor` / `shadow`
  //  官方不建议与材质同用（材质会接管这四者，SDK `common.d.ts:22625-22633`）⇒ 材质可用时
  //  这四层**整组不下发**（用 `undefined` 表达"不传"，见 `customDialogGeometry()` 的注释）。
  // · ⚠️ **关档 ≠ 不传**：`systemMaterial(undefined)` 的语义是「恢复组件默认材质」，
  //  「关闭」必须显式传 `uiMaterial.Material.empty`（SDK `uiMaterial.d.ts:467-472`）——
  //  见 `R85_DIALOG_OFFICIAL_MATERIAL` 关档分支与 `坑 245` 第 5 条。
  // · ⚠️ `lightEffect` 一律不设：官方会在玻璃顶缘合成一条锐利贯穿亮线（`坑 13`）。
  // · 回退：把 `R85_DIALOG_OFFICIAL_MATERIAL` 改成 `false` ⇒ 几何与底色逐字回到 R84 行为。
  const geometry: DialogGeometry = customDialogGeometry(variant, width);
  const material: uiMaterial.Material =
    R85_DIALOG_OFFICIAL_MATERIAL && immersiveMaterialEnabled()
      ? dialogMaterial()
      : uiMaterial.Material.empty;
  try {
    if (variant === DIALOG_VARIANT_PROFILE) {
      return ui.getPromptAction().openCustomDialog({
        builder: content,
        width: geometry.width,
        cornerRadius: geometry.cornerRadius,
        backgroundColor: geometry.backgroundColor,
        borderWidth: geometry.borderWidth,
        borderColor: geometry.borderColor,
        systemMaterial: material,
        autoCancel: true,
        alignment: DialogAlignment.Center
      });
    }
    // 确认族多一层 34dp 阴影（上游 `.shadow(34.dp, shape, ambient/spot = appShadow)`）。
    return ui.getPromptAction().openCustomDialog({
      builder: content,
      width: geometry.width,
      cornerRadius: geometry.cornerRadius,
      backgroundColor: geometry.backgroundColor,
      borderWidth: geometry.borderWidth,
      borderColor: geometry.borderColor,
      shadow: geometry.shadow,
      systemMaterial: material,
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
  } catch (error) {
    return Promise.reject(new Error('openCustomDialog failed'));
  }
}

/** 关闭通用确认框（`closeCustomDialog` 被判为可能抛异常 ⇒ 必须包 try/catch，见 [坑 144]）。 */
export function closeAaConfirmDialog(ui: UIContext, dialogId: number): void {
  if (dialogId <= 0) {
    return;
  }
  try {
    ui.getPromptAction().closeCustomDialog(dialogId);
  } catch (error) {
    // 关不掉不影响功能：`autoCancel` 与随后的重开都会收敛。
  }
}

/**
 * 对话框宽度（vp）：`min(380, 屏宽 − 44)` —— 上游 `widthIn(max = 380.dp)` 叠加 `padding(horizontal = 22.dp)`。
 * `display.getDefaultDisplaySync()` 会抛，必须包 try/catch（零 ArkTS 告警要求）。
 */
function dialogWidthVp(variant: string): number {
  const profile = variant === DIALOG_VARIANT_PROFILE;
  try {
    const metrics = display.getDefaultDisplaySync();
    const density = metrics.densityPixels > 0 ? metrics.densityPixels : 1;
    const screen = metrics.width / density;
    return profile ? ProfileDialogSpec.widthFor(screen) : DialogSpec.widthFor(screen);
  } catch (error) {
    return profile ? ProfileDialogSpec.FALLBACK_WIDTH : DialogSpec.MAX_WIDTH;
  }
}
