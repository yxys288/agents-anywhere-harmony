/**
 * 极简路由（对应 Android `navigation/AppDestination.kt` + `AgentsAnywhereNavHost.kt`）。
 *
 * 用「显式栈 + AppStorage」而不是 `Navigation/NavPathStack`：
 * 本应用的层级很浅（根 + 若干详情页），显式栈更容易控制返回行为，
 * 也避免 NavDestination 注册与参数序列化的样板。
 *
 * ⚠️ 关键：根页面必须用 `@StorageLink('aaRoute')` 直接读**字符串**路由名。
 * 早先版本把整栈存成对象数组、由页面调 `Router.current()` 读取 —— 因为该值不是
 * 状态变量、且 build 里没有读取任何随它变化的 @State，ArkUI 不会登记依赖，
 * 于是「路由变了但界面不刷新」。现在把当前路由/参数单独摊平成两个字符串键，
 * 由 `@StorageLink` 直接参与渲染，依赖关系明确。
 */

/**
 * 目的地常量 —— 与安卓 `navigation/AppDestination.kt` 的 **14 个平级目的地**一一对应。
 *
 * ⚠️ 既有常量名一个都不许改（全工程在引用）；新增的按现有命名风格续写。
 * ⚠️ 上游是**单值状态机**（`destinationName`），不是返回栈 —— 见 `Router.back()` 的说明。
 */
export class Route {
  /** 上游 `LoginMethods`（未登录时的根目的地）。 */
  static readonly LOGIN: string = 'login';
  /** 上游 `ServerSetup`（「连接到你自己的服务实例」）。 */
  static readonly SERVER_SETUP: string = 'server_setup';
  /** 上游 `QrLogin`（扫码登录）。 */
  static readonly QR_LOGIN: string = 'qr_login';
  /** 上游 `QrWaiting`（扫码等待，带 `pendingMobileLoginQr` 参数）。 */
  static readonly QR_WAITING: string = 'qr_waiting';
  /** 上游 `Sessions`（**首页**；已登录时的根目的地，也是绝大多数页面的返回目标）。 */
  static readonly HOME: string = 'home';
  /** 上游 `SessionDetail`（会话详情）。 */
  static readonly SESSION: string = 'session';
  /**
   * **本工程特有 R53**：「直接开新对话」草稿页（`NewChatScreen`）。
   *
   * 上游没有这个目的地 —— 它是把「新建会话表单」拆成两步之后的前半段：
   * 点「+」**立刻**进对话界面（设备/Agent/工作区按记忆与最近使用定好，可就地切换），
   * 首条消息发出时才 `create-and-start`。参数是可选的「指定工作区」（`connectorId|projectId`）。
   *
   * ⚠️ **R82**：原文还写着「旧表单页（`NEW_SESSION`）保留为本页右上角『更多设置』的显式入口」——
   * 那条路早就不存在了：`Route.NEW_SESSION` **全工程无 push 点**，本轮连常量一起删除
   * （见 `NewSessionScreen` 的编辑器清理与 `suite-topbar.mjs` 的回潮闸门）。
   */
  static readonly NEW_CHAT: string = 'new_chat';
  /**
   * **本工程特有 R53**：「新对话」的第二步 —— 在**原对话页**上以草稿态进入某个工作区。
   *
   * 流程（用户拍板）：「新建对话 → **选择工作区** → 进入该工作区对话」：
   * `NEW_CHAT`（选择工作区）→ `replace` 到本目的地 → `SessionDetailScreen` 以草稿态渲染
   * （服务端会话还没建，首条消息才 `create-and-start`）。
   * 参数是 `connectorId|projectId`（`model/NewChatDraft.encodeNewChatEntry`）。
   */
  static readonly DRAFT_SESSION: string = 'draft_session';
  /**
   * 上游 `NewProject`（新建项目）。
   *
   * ⚠️ 第八轮曾删掉它并写下「上游新建项目是弹层不是独立 destination」——本轮核对上游源码后
   * **该结论被推翻**：`AppDestination.NewProject("New Project")` 确实是 14 个目的地之一，
   * 由 `NewSessionScreen` 复用渲染（`HomeScreen.kt` 的 `onCreateProject` 会 navigate 过去）。
   * 现在按复刻口径把它加回来，首页项目区的「+」推它。
   */
  static readonly NEW_PROJECT: string = 'new_project';
  /** 上游 `Devices`（设备列表，**顶层目的地**，由首页快捷卡片进入）。 */
  static readonly DEVICES: string = 'devices';
  /** 上游 `Terminal`（顶层目的地，由首页快捷卡片进入）。 */
  static readonly TERMINAL: string = 'terminal';
  /** 上游 `Files`（顶层目的地，由首页快捷卡片进入）。 */
  static readonly FILES: string = 'files';
  /** 上游 `DeviceDetail`（设备详情；返回目标**可变**，见 `Router.backTo`）。 */
  static readonly DEVICE: string = 'device';
  /** 上游 `ArchivedSessions`（已归档会话）。 */
  static readonly ARCHIVED: string = 'archived';
  /** 上游 `DeviceSetup`（配对 / 添加新设备；返回目标**可变**，见 `Router.backTo`）。 */
  static readonly ADD_DEVICE: string = 'add_device';
  /**
   * 本工程特有：设置抽屉在本工程里是一个独立页面（上游是首页之上的 `ProfileSettingsDrawer`）。
   * 保留它以便「设置」在任何时候都能作为目的地被推入。
   */
  static readonly SETTINGS: string = 'settings';
}

export interface NavEntry {
  route: string;
  param: string;
}

const STACK_KEY: string = 'aaNavStack';
/** 当前路由名（根页面 `@StorageLink` 直读）。 */
export const ROUTE_KEY: string = 'aaRoute';
/** 当前路由参数（根页面 `@StorageLink` 直读）。 */
export const PARAM_KEY: string = 'aaParam';

function currentStack(): NavEntry[] {
  const value = AppStorage.get<NavEntry[]>(STACK_KEY);
  return value !== undefined ? value : [];
}

function commit(stack: NavEntry[]): void {
  AppStorage.setOrCreate(STACK_KEY, stack);
  let top: NavEntry = { route: Route.LOGIN, param: '' };
  if (stack.length > 0) {
    top = stack[stack.length - 1];
  }
  // 顺序很重要：先写栈，再写当前路由/参数（这两个才是渲染依赖）
  AppStorage.setOrCreate(ROUTE_KEY, top.route);
  AppStorage.setOrCreate(PARAM_KEY, top.param);
}

export class Router {
  /** 初始化根路由（登录态变化时调用）。 */
  static reset(route: string, param: string = ''): void {
    commit([{ route: route, param: param }]);
  }

  static push(route: string, param: string = ''): void {
    const stack = currentStack().slice();
    stack.push({ route: route, param: param });
    commit(stack);
  }

  /**
   * 用新页面**替换栈顶**（栈深不变）。
   *
   * 场景：配对成功后要进设备详情，而配对页不该留在返回路径上（返回键应回到设备列表）。
   * `pop() + push()` 在「从设备详情再次进配对」时会把详情压两次（返回键要点两下才退出），
   * 所以补一个 replace。
   */
  static replace(route: string, param: string = ''): void {
    const stack = currentStack().slice();
    if (stack.length === 0) {
      stack.push({ route: route, param: param });
    } else {
      stack[stack.length - 1] = { route: route, param: param };
    }
    commit(stack);
  }

  /** 返回上一级；已在根时返回 false（调用方决定是否退出应用）。 */
  static pop(): boolean {
    const stack = currentStack().slice();
    if (stack.length <= 1) {
      return false;
    }
    stack.pop();
    commit(stack);
    return true;
  }

  /**
   * **统一返回：回首页（Sessions）。**
   *
   * 上游不是一个返回栈：根状态里只有 `destinationName` 一个字符串，`navigate()` 只做副作用清理再赋值；
   * 各处返回钮的目标是**硬编码**的 `navigate(AppDestination.Sessions)`（`DevicesScreen.kt:312`、
   * `TerminalScreen.kt:87`、`FilesScreen.kt:86`、`ArchivedSessionsScreen` 的 `onBack`、`SessionDetailScreen.kt:1214` 等），
   * 也就是「不管从哪来，都回首页」，**不是**「回上一页」。
   *
   * 本工程保留自研栈（`push`/`replace`/`pop` 的行为不变，供确实需要逐级返回的场景使用），
   * 但页面的返回钮一律调本方法，从而与上游语义一致。
   *
   * @returns 当前不在首页时返回 true（已切回首页）；**已经在首页时返回 false**（调用方应交给系统退出应用）。
   */
  static back(): boolean {
    const stack = currentStack();
    if (stack.length === 0) {
      return false;
    }
    if (stack[stack.length - 1].route === Route.HOME) {
      return false;
    }
    commit([{ route: Route.HOME, param: '' }]);
    return true;
  }

  /**
   * 返回到**指定目的地**（供上游那两个「记住来源」的页面用）。
   *
   * 上游只有 `DeviceDetail` 与 `DeviceSetup` 会记住来源：
   * `deviceDetailReturnDestinationName` / `deviceSetupReturnDestinationName`（默认都是 `Devices`，
   * `AgentsAnywhereApp.kt` 的两个 rememberSaveable），进入时由 `navigate()` 记下（`:422-427`）。
   * 其余页面的返回目标一律是首页（见 `back()`）。
   */
  static backTo(route: string, param: string = ''): void {
    commit([{ route: route, param: param }]);
  }

  static current(): NavEntry {
    const stack = currentStack();
    if (stack.length === 0) {
      return { route: Route.LOGIN, param: '' };
    }
    return stack[stack.length - 1];
  }

  static depth(): number {
    return currentStack().length;
  }

  static stack(): NavEntry[] {
    return currentStack();
  }
}
