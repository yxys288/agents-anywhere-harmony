import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppearanceController, isDarkAppearance } from '../feature/AppServices';
// 品牌字标字体（Caveat）注册：R13-2 的补丁落在 Ability 侧（页面 aboutToAppear 注册太晚，见 r12-icons/README §11.5）
import { ensureWordmarkFont } from '../ui/Components';
// 系统栏避让高度（px）的 AppStorage 键：读出来 → 页面 padding（R13-12 显式避让方案的契约）
import { SAFE_AREA_BOTTOM_PX, SAFE_AREA_TOP_PX } from '../ui/Design';
import { initAppPrefs } from '../store/AuthSessionStore';

const DOMAIN: number = 0x0100;
const TAG: string = 'AAHm';

/**
 * **页面画布色**（= `resources/{base,dark}/element/color.json` 的 `canvas`）—— 系统栏底色就填它。
 *
 * 为什么不能用「透明 + 让页面画到系统栏」：R13-11/R13-12 两次真机返工证明 `expandSafeArea` 在百分比尺寸下
 * 会把容器自身也扩掉、内容跟着进系统栏（挂根节点 5865 墨点，改成分层仍是 5897，安卓 2150）。
 * 而页面的内容**必须**留在安全区内（顶不被时间栏压、底不被手势条遮）。
 * ⇒ 折中方案：内容照常避让，**系统栏区域由系统自己画成页面底色**（本属性），视觉上就是沉浸。
 *
 * ⚠️ 这两个常量必须与 color.json 的 `canvas` 一致 —— `tools/logic-test/suite-settings.mjs` 会解析资源断言相等。
 */
const CANVAS_COLOR_LIGHT: string = '#FFFDFCFB';
const CANVAS_COLOR_DARK: string = '#FF09090B';
/**
 * 系统栏底色：**透明**（R13-14 真机第四轮返工）。
 *
 * 固定填画布色只在浅色页面上成立 —— 终端页本体是深色（实测页面底色 9.7），填 #FFFDFCFB 会在上下
 * 刷出两条浅色带（用户说的「底部还有遮罩」）。改回透明、由 `pages/Index.ets` 的**背景层**
 * 铺「当前路由的页面底色」（终端页 = `$r('app.color.terminal_background')`）。
 */
const SYSTEM_BAR_TRANSPARENT: string = '#00000000';
/**
 * 系统栏图标色（时间 / 信号 / Wi-Fi / 手势条）：必须与页面底色成对比。
 * 浅色页面（画布 #FDFCFB）用深色图标、深色页面（#09090B）用浅色图标。
 */
const SYSTEM_BAR_ICON_ON_LIGHT: string = '#E5000000';
const SYSTEM_BAR_ICON_ON_DARK: string = '#E5FFFFFF';

export default class EntryAbility extends UIAbility {
  /**
   * 主窗口。存成字段有两个原因：
   *  ① 系统栏配色必须在**外观变化时**重设（浅色图标落到浅色页面上就看不见了）；
   *  ② `AppearanceController.onChange` 回调里拿不到 windowStage。
   */
  private mainWindow?: window.Window;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    // 必须在任何服务单例被构造**之前**打开 preferences：
    // AppServices 的构造函数会读（并落盘）实时连接 id、AuthController 的构造函数会读登录态，
    // 晚于这一步初始化就会拿到空值（连接 id 每次启动都变、登录态读不出来）。
    // ⚠️ R13：外观下发要 import AppServices ⇒ 该模块的求值被提前到本行之前，
    // 其中 `authController` 会以「preferences 未打开」的状态构造一次；根页面 aboutToAppear
    // 紧接着会 `AppServices.get().init(context)` + `authController.reloadFromStorage()` 重读，
    // 实时连接 id 也已由 `AppServices.init()` 补读，两条链路都已兜住。
    initAppPrefs(this.context);
    // 外观（R12 P0 缺陷）：注册 Ability 上下文并**立刻**按持久化值下发一次 colorMode。
    // `setColorMode` 只能从 ApplicationContext 下发，而 feature 层不许 import Ability，
    // 所以上下文在这里注册进去；冷启动不下发的话，用户选的「深色」在重启后就丢。
    AppearanceController.attach(this.context);
    const appearanceApplied: boolean = AppearanceController.init();
    hilog.info(DOMAIN, TAG, 'appearance mode=%{public}s applied=%{public}s',
      AppearanceController.current, String(appearanceApplied));
    // 外观一变（用户在设置里点选，或「跟随系统」时系统切深浅）→ 系统栏**图标色**要跟着重设：
    // 不做这件事的后果是深色页面配深色图标（或反向），时间/信号那一排等于看不清。
    // （系统栏的**底色**不用重设：它一直是透明的，露出来的是页面自己的背景。）
    AppearanceController.onChange(() => {
      this.syncSystemBarColors();
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 沉浸式全屏 + 系统栏透明：**先**设窗口属性、**再**加载内容。
    // 反过来（先 loadContent）冷启动首帧会先按「非全屏 + 系统默认栏底色」画一帧，
    // 用户看到上下两条浅灰带闪一下（真机复核里那条「底部一大块遮罩」就是它）。
    this.attachMainWindow(windowStage);

    // 品牌字标字体（Caveat）：必须在**首次渲染前**注册 —— registerFont 是异步的，
    // 放到页面 aboutToAppear 再注册等于赌首帧（首帧可能仍是系统字体，且字体不会自动重绘）。
    // 此处窗口已就绪（attachMainWindow 刚取到主窗口）⇒ 拿得到 UIContext
    // （window.Window.getUIContext()，SDK @ohos.window.d.ts:5208）。
    // 取不到时（getMainWindowSync 失败走了异步回退）由 HomeScreen.aboutToAppear 兜底；两边都幂等。
    // ⚠️ `getUIContext()` 是 @throws 接口（1300002 window state abnormal），不包 try/catch 就是一条
    // ArkTS 告警（坑 144 的同款形态），会破本工程「零 ArkTS 告警」硬要求 ——
    // 这也是对 r12-icons/README §11.5 原补丁的唯一改动（原样照抄会引入 1 条告警）。
    if (this.mainWindow !== undefined) {
      try {
        ensureWordmarkFont(this.mainWindow.getUIContext());
      } catch (error) {
        // 注册失败只影响字标观感（退回系统字体）；HomeScreen.aboutToAppear 还有一次兜底
        hilog.warn(DOMAIN, TAG, 'register wordmark font failed: %{public}s', JSON.stringify(error));
      }
    }

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
      // ⚠️ 这里**不**调 `setWindowBackgroundColor`（窗口底色）：ArkTS 编译期对它报
      // 「This API is unavailable to phone, tablet」（真机/平板判为不可用），会破坏本工程
      // 「零 ArkTS 告警」的硬要求。它本来要解决的「首帧/系统栏区域露默认底色」由另外两处覆盖：
      //  ① 冷启动首帧露的是**启动页**，由 module.json5 的
      //  startWindowBackground = $color:start_window_background（浅 #FDFCFB / 深 #09090B）决定，
      //  与画布同色；
      //  ② 页面起来后，系统栏那一条由页面自己画（页面根节点的 expandSafeArea(TOP+BOTTOM)）。
      // 窗口已创建、页面已加载 —— 按 SDK 对 setColorMode 的前置要求再下发一次
      // （onCreate 里那次属于尽力而为；两次都是幂等的）。
      const reapplied: boolean = AppearanceController.apply();
      hilog.info(DOMAIN, TAG, 'appearance re-applied after loadContent: %{public}s', String(reapplied));
      // 系统栏底色/图标色再补一次：首次下发可能早于窗口就绪被系统丢弃，
      // 且此时主题（深/浅）一定已经按持久化值定下来了。
      this.syncSystemBarColors();
      // 避让高度同样再量一次（首帧那次可能取到 0），并把结果写回 AppStorage。
      this.pushSafeAreaInsets();
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  /**
   * 系统配置变化（含系统深浅色切换）→ 「跟随系统」时必须让应用跟着变。
   *
   * 这里**只**同步 + 广播，绝不回头再调 `setColorMode` —— 那会和本回调形成来回触发。
   * 系统侧颜色资源由 ArkUI 按新 colorMode 自动重解析，本回调负责的是「按
   * `isDarkAppearance()` 取过色的页面要重渲染」。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    // `Configuration.colorMode` 是可选项（SDK 类型是 `ColorMode | undefined`）：
    // 缺省时**不要**当成浅色同步，否则会把深色系统误判成浅色（图标色随之变错）。
    const colorMode: ConfigurationConstant.ColorMode | undefined = newConfig.colorMode;
    if (colorMode === undefined) {
      hilog.info(DOMAIN, TAG, 'onConfigurationUpdate without colorMode');
      return;
    }
    const changed: boolean = AppearanceController.syncSystemColorMode(colorMode);
    // 旋转/折叠/手势条显隐都会改避让高度，顺手重量一次。
    this.pushSafeAreaInsets();
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate colorMode=%{public}d changed=%{public}s',
      colorMode, String(changed));
  }

  /**
   * 回前台（R90-T3 补）：**重新下发一次系统栏配色**。
   *
   * 为什么必须有这一步：状态栏图标色是**框架**按我们下发的属性画的，
   * 而「应用切后台期间系统深浅色变了 / 系统把我们下发的属性重置了」这两件事，
   * 都不能保证 `onConfigurationUpdate` 一定补到（它只在配置**变化**时来）。
   * 回前台是**唯一**能确保"用户此刻看到的那一帧"重新对上的时机。
   * ⚠️ 幂等、只写窗口属性，不做任何状态迁移 —— 放这里没有副作用。
   */
  onForeground(): void {
    this.syncSystemBarColors();
    this.pushSafeAreaInsets();
  }

  onBackground(): void {
  }

  /** 取主窗口并立刻应用沉浸式布局；同步取不到就退回异步再试一次。 */
  private attachMainWindow(windowStage: window.WindowStage): void {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', JSON.stringify(error));
    }
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      windowStage.getMainWindow().then((resolved: window.Window) => {
        this.mainWindow = resolved;
        this.applyImmersiveLayout(resolved);
      }).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'getMainWindow failed: %{public}s', JSON.stringify(error));
      });
      return;
    }
    this.applyImmersiveLayout(mainWindow);
  }

  /** 全屏布局（与 loadContent 无先后要求，越早越好）+ 系统栏配色。 */
  private applyImmersiveLayout(mainWindow: window.Window): void {
    try {
      mainWindow.setWindowLayoutFullScreen(true).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', JSON.stringify(error));
      });
      // 系统栏区域变化（手势条显隐 / 旋转 / 三键导航切换）→ 重新量避让高度，
      // 否则页面 padding 会停在旧值（内容被压或留白过多）。
      mainWindow.on('avoidAreaChange', () => {
        this.pushSafeAreaInsets();
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen threw: %{public}s', JSON.stringify(error));
    }
    this.syncSystemBarColors();
    // 立即量一次：页面首帧就要用（晚一步内容会先压进状态栏再跳回）
    this.pushSafeAreaInsets();
  }

  /**
   * 系统栏**底色透明** + 图标色随深浅色。可反复调用（外观变化时重设）。
   *
   * 「铺满」由页面侧的背景层承担（`pages/Index.ets`：按路由取色的 Column + expandSafeArea），
   * 本方法只负责两件事：把系统栏刷成透明（别挡页面），以及让图标与页面底色成对比。
   *
   * 用 `setWindowSystemBarProperties` 而不是旧的 `setStatusBarColor` 系列：后者已废弃，
   * 且 SDK 注明系统栏属性**只在全屏/最大化模式下生效** —— 这也是必须先开 FullScreen 的原因之一。
   */
  private syncSystemBarColors(): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    const dark: boolean = isDarkAppearance();
    const iconColor: string = dark ? SYSTEM_BAR_ICON_ON_DARK : SYSTEM_BAR_ICON_ON_LIGHT;
    // R90-T3：状态栏图标色由**框架**画 —— "设了"不等于"生效"，所以把**判定输入**打出来。
    // ⚠️ 这条就是排「图标看不见」的第一现场：若 dark 与页面实际明暗相反，问题在本行上游。
    hilog.info(DOMAIN, TAG, 'systemBar dark=%{public}s icon=%{public}s | %{public}s',
      String(dark), iconColor, AppearanceController.describe());
    // ⚠️ 底色**透明**：系统栏区域交给 `pages/Index.ets` 的背景层（它按当前路由取色，
    // 终端页是深色）。固定画布色会把深色终端刷出两条浅色带（真机第四轮）。
    const properties: window.SystemBarProperties = {
      statusBarColor: SYSTEM_BAR_TRANSPARENT,
      navigationBarColor: SYSTEM_BAR_TRANSPARENT,
      statusBarContentColor: iconColor,
      navigationBarContentColor: iconColor
    };
    try {
      mainWindow.setWindowSystemBarProperties(properties).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties threw: %{public}s', JSON.stringify(error));
    }
  }

  /**
   * 读系统避让区（状态栏 / 手势条高度，单位 px）→ `AppStorage`（见 ui/Design.ets 的 SAFE_AREA_* 注释）。
   *
   * 沉浸态下鸿蒙不替应用避让系统栏，所以内容层的 padding 必须由**实测值**驱动，不能写死像素。
   * 四个触发点：设完全屏后、内容加载后、系统配置变化后、以及 avoidAreaChange 回调（手势条显隐/旋转）。
   */
  private pushSafeAreaInsets(): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    try {
      const area: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const topPx: number = area.topRect.height;
      // ⚠️ 底部取 **max(系统栏, 手势条)**：手势导航下 `TYPE_SYSTEM.bottomRect.height` 可能是 0，
      // 而手势条高度在 `TYPE_NAVIGATION_INDICATOR` 里（真机第四轮：底为零 ⇒ 终端页按键行越界）。
      const indicator: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const systemBottomPx: number = area.bottomRect.height;
      const indicatorBottomPx: number = indicator.bottomRect.height;
      const bottomPx: number = systemBottomPx > indicatorBottomPx ? systemBottomPx : indicatorBottomPx;
      AppStorage.setOrCreate(SAFE_AREA_TOP_PX, topPx);
      AppStorage.setOrCreate(SAFE_AREA_BOTTOM_PX, bottomPx);
      hilog.info(DOMAIN, TAG, 'safe area topPx=%{public}d bottomPx=%{public}d (system=%{public}d indicator=%{public}d)',
        topPx, bottomPx, systemBottomPx, indicatorBottomPx);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea failed: %{public}s', JSON.stringify(error));
    }
  }
}

