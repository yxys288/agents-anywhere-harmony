/**
 * 会话「能不能发消息」的纯判定（不依赖 ArkUI / Kit，可进 Node 侧单测）。
 *
 * 为什么单独抽出来：这是**本轮缺陷的核心**，也是全工程最容易改错的地方 ——
 * 它同时涉及四个来源（接管状态、能力表、运行时状态、会话状态），
 * 而这四个来源在真机上很难组合复现（要服务端配合造出「未接管」「能力被禁」
 * 「运行时卡在 starting」等状态）。抽成纯函数后，全部组合都能在 Node 里断言，
 * 不必每次靠真机试。
 *
 * 对应上游 Android：
 * - `SessionRuntimeState.kt` L535-541 `sessionComposerEnabled`
 * - `SessionRuntimeState.kt` L93-118 `messageAction`
 * - `SessionDetailScreen.kt` L1333 `takeoverEnabled`、L1541-1558 placeholder 优先级
 */

/** 发送动作：`send` 走 `/runtime/messages`，`steer` 走 `/runtime/steer`，`none` 不能发。 */
export class MessageAction {
  static readonly SEND: string = 'send';
  static readonly STEER: string = 'steer';
  static readonly NONE: string = 'none';
}

/** 上游 `SESSION_*` 能力 id（`SessionRuntimeState.kt` L8-16，精确字符串）。 */
export const CAP_SEND_MESSAGE: string = 'session.send_message';
export const CAP_STEER: string = 'session.steer';
// R39 精简：上游 `SESSION_*` 清单里还有两个能力 id，但本工程**从未查询**它们（全码零引用）。
// 需要时按上游原文补回：CAP_INTERRUPT = 'session.interrupt'
// 、CAP_ATTACHMENT = 'runtime.attachment'。

/** 单条能力的可用性（与 `api/Parse.ets` 的 `RemoteRuntimeCapability` 形状对齐）。 */
export interface GatingCapability {
  capabilityId: string;
  supported: boolean;
  available: boolean;
  allowed: boolean;
}

/** 运行时状态里属于「活动」的那些（上游 `ACTIVE_RUNTIME_STATUSES`）。 */
const ACTIVE_STATUSES: string[] = [
  'waiting', 'pending', 'running', 'stopping', 'waiting_approval', 'blocked'
];

/**
 * 能力是否被**显式**声明为不可用。
 *
 * ⚠️ 与「能力表里没有这一条」是两回事，必须分开：
 * `specs/01-api-spec.md` §4 明确 `effectiveCapabilities` 可以是
 * `{revision: 0, capabilities: []}`（精简实现 / 老部署），此时能力表是**未知**而非**禁止**。
 * 把「未知」当成「禁止」，会让这类服务端上的**所有**会话永久不可发消息 ——
 * 这正是最容易被误判成「应用坏了」的失败模式。
 *
 * 上游 `isUsable()` 取的是严格版（没这条就是不可用）。本工程要兼容空表，
 * 故只把「显式 false」当约束；`supported/available/allowed` 三者任一为 false 即禁用。
 */
export function capabilityBlocked(capabilities: GatingCapability[], capabilityId: string): boolean {
  for (let i = 0; i < capabilities.length; i++) {
    const capability = capabilities[i];
    if (capability.capabilityId === capabilityId) {
      return !(capability.supported && capability.available && capability.allowed);
    }
  }
  return false;
}

/**
 * 有效运行时状态：runtime state 非 unknown 时优先，否则回落到会话状态。
 * 对应上游 `effectiveRuntimeStatus()`（`SessionDetailScreen.kt` L1856-1868）。
 *
 * 两个来源确实会不一致（会话状态是服务端视角的粗粒度值、runtime state 是
 * Connector 上报的细粒度值）；只看会话状态会在两端点之间选错
 * —— 服务端 `steer` 要求 `running`、`messages` 要求 `idle|error`。
 */
export function effectiveRuntimeStatus(runtimeStatus: string, sessionStatus: string): string {
  if (runtimeStatus.length > 0 && runtimeStatus !== 'unknown') {
    return runtimeStatus;
  }
  return sessionStatus.length > 0 ? sessionStatus : 'unknown';
}

/** 是否为「活动」运行时状态（这些状态下发送应优先走 steer）。 */
export function isActiveRuntimeStatus(status: string): boolean {
  return ACTIVE_STATUSES.indexOf(status) >= 0;
}

/**
 * 会话是否只读（未接管）。
 *
 * 上游 composer 的第一道闸（`SessionDetailScreen.kt` L1333）。服务端对未接管的会话
 * 一律 409（`server/agent_service/services/session_run.py` L397：
 * 「session is read-only until takeover is enabled」），messages / steer / selections 三处都拦。
 *
 * `loaded` 为 false（会话还没拉出来）时返回 false —— 不在加载态闪一下只读。
 */
export function isReadOnly(loaded: boolean, takeover: boolean): boolean {
  return loaded && !takeover;
}

/**
 * 运行时当前能接受的发送动作。
 *
 * 顺序与上游 `messageAction`（L93-118）一致：**能力驱动 + 状态兜底**，不是纯看状态。
 * 之前的实现只看 `running|waiting|pending` 三个状态，于是 `stopping` /
 * `waiting_approval` / `blocked` 会被判成「空闲」而走 `messages`，
 * 而服务端对这几个状态的 `messages` 一律 409（`session_run.py` L402 只放行 idle|error）。
 */
export function messageActionFor(
  loaded: boolean,
  takeover: boolean,
  capabilities: GatingCapability[],
  runtimeStatus: string,
  sessionStatus: string
): string {
  if (isReadOnly(loaded, takeover)) {
    return MessageAction.NONE;
  }
  const canSend = !capabilityBlocked(capabilities, CAP_SEND_MESSAGE);
  const canSteer = !capabilityBlocked(capabilities, CAP_STEER);
  if (!canSend && !canSteer) {
    return MessageAction.NONE;
  }
  const status = effectiveRuntimeStatus(runtimeStatus, sessionStatus);
  if (canSteer && (!canSend || isActiveRuntimeStatus(status))) {
    return MessageAction.STEER;
  }
  return canSend ? MessageAction.SEND : MessageAction.STEER;
}

/** 判定输入区文案所需的全部事实（都是标量，便于逐条构造用例）。 */
export interface ComposerFacts {
  loaded: boolean;
  takeover: boolean;
  connectorOnline: boolean;
  hasNotices: boolean;
  runtimeReason: string;
  runtimeStatus: string;
  sessionStatus: string;
  /** 未接管时用户能否直接接管（设备在线才行）。 */
  action: string;
  /** 「回复 X」里的 X：上游取会话运行时的标签，为空时用「Agent」兜底。 */
  replyTarget: string;
}

/** 上游 `session_agent_fallback`：「回复 X」里 X 的兜底值。 */
export const DEFAULT_REPLY_TARGET: string = 'Agent';

/**
 * 上游 `SessionDetailScreen.kt` L1539-1540：`runtimeLabel` 为空时用 `session_agent_fallback` 兜底。
 * 会话没拉到（`loaded === false`）时同样兜底，免得占位文案里出现一段空白。
 */
export function resolveReplyTarget(runtimeLabel: string): string {
  return runtimeLabel.length > 0 ? runtimeLabel : DEFAULT_REPLY_TARGET;
}

/** 上游 `session_reply_to`：「回复 %1$s」。 */
export function replyToText(replyTarget: string): string {
  return '回复 ' + replyTarget;
}

/**
 * 上游 `session_read_only_placeholder`。
 *
 * 必须只有一个来源：接管后的输入框 placeholder 与只读态的**一行提示条**
 * （R10 的折叠形态，见 `ui/screens/SessionDetailScreen.ets` 的 `composerCollapsed()`）共用它，
 * 两边各写一份字符串迟早会漂。
 */
const READ_ONLY_PLACEHOLDER: string = '只读模式-开启接管后可发送消息';

/**
 * 输入区占位文案。判定顺序**照抄上游**（`SessionDetailScreen.kt` L1541-1558）。
 *
 * 输入框是用户唯一一定会看的地方，上游把「为什么现在不能发」直接写在这里；
 * 本工程此前无论什么状态都只显示「给 Agent 发消息…」，于是用户只会在点下发送之后
 * 收到一句英文 409 —— 观感就是「不能正常发起对话」。
 *
 * ⚠️ R9 起各分支文案**逐字取上游中文资源**
 * （`android/app/src/main/res/values-zh-rCN/strings.xml`），不再自创措辞：
 * 只读 / 离线 / 待审批 / 排队 / 运行中 / 出错 / 不可用 / 默认「回复 X」。
 * 改文案前先去那份 strings.xml 抄原值，别按印象写。
 */
export function composerPlaceholder(facts: ComposerFacts): string {
  if (isReadOnly(facts.loaded, facts.takeover)) {
    return READ_ONLY_PLACEHOLDER;
  }
  if (facts.loaded && !facts.connectorOnline) {
    return '设备已离线，暂时不能聊天。';
  }
  if (facts.hasNotices) {
    return '等待你在下方处理交互…';
  }
  if (facts.runtimeReason.length > 0) {
    return facts.runtimeReason;
  }
  const status = effectiveRuntimeStatus(facts.runtimeStatus, facts.sessionStatus);
  if (status === 'waiting' || status === 'pending') {
    return '等待运行时接收任务…';
  }
  if (status === 'running' || status === 'stopping') {
    return '发送中断，或等待当前回合结束';
  }
  if (status === 'waiting_approval' || status === 'blocked') {
    return '等待你在下方处理交互…';
  }
  if (status === 'error') {
    return '这个会话有错误，发送后会重试';
  }
  if (facts.action === MessageAction.NONE) {
    return '当前运行时状态下不可发送消息。';
  }
  return replyToText(facts.replyTarget);
}

/**
 * 运行时能否用来**新建会话**。
 *
 * 口径与上游 `activeNewSessionRuntimes`（`feature/sessions/NewSessionRuntimeInventory.kt` L7-9）
 * 一致：`configured && active && status == running`。
 *
 * 服务端在 create-and-start 上做的是同一件事（`ensure_active_running`：先查 `active`、
 * 再查 `configured`、最后把非 running 的拉起来，但**发令即返回、不等 running**），
 * 于是「active 但 status=starting」的运行时会被服务端放行到 Connector，
 * 再由 Connector 报 `runtime instance 'rti_…' is not running (status='starting')`（真机实测）。
 * 客户端提前用同一口径过滤，才能消灭「选中了 → 填完了 → 建不了」这条最伤人的路径。
 *
 * ⚠️ 收**标量**而不是收 `RemoteDeviceRuntime` 对象：ArkTS 不支持结构化类型
 * （`arkts-no-structural-typing`），传对象会编译失败；收标量同时也让本函数
 * 完全不依赖 `model/Types.ets`，Node 侧单测不必构造完整 DTO。
 */
export function runtimeIsReady(configured: boolean, active: boolean, status: string): boolean {
  return configured && active && status === 'running';
}

/** 运行时是否处于过渡态（启动/停止/校验/发现中）——此时值得轮询等它落定。 */
export function runtimeIsSettling(active: boolean, status: string): boolean {
  return active && (status === 'starting' || status === 'stopping' ||
    status === 'validating' || status === 'discovering');
}

/**
 * 从服务端返回的运行时 `error` / `discovery` 里挑一条**给人看**的原因。
 *
 * 服务端 `DeviceRuntimeView` 带 `error: {code, message}` 与 `discovery.reason`
 * （`server/agent_server/core/device_runtime.py` L171/L182）；DSH 的 `starting`
 * 常常是「等本地 Bridge」这类**用户可自行解决**的状态，文案由 Connector 给
 * （`connector/runtimes/dsh/runtime.py` L83/L92：`正在连接 DSH 并同步会话…` /
 * `正在等待本地 DSH Bridge；请启动 DSH 并启用手机连接插件。`）。
 * 只写死一句「稍候会自动出现在这里」会把这些线索全吞掉。
 *
 * 入参用 `JsonMap`-like 的可空对象 + 下标取值（ArkTS 不支持结构化类型，
 * 也拿不到 `RemoteDeviceRuntime` 的定义，所以这里收 `Object` 形态的字段）。
 */
/**
 * 上游 `SessionShareScope`（`SessionDetailScreen.kt` L1871-1874）的两个取值 ——
 * 服务端 `/sessions/{id}/shares` 的 `scope` 字段就是这两个字符串（`SessionsApi.createSessionShare`）。
 */
export const SHARE_SCOPE_MESSAGE: string = 'message';
export const SHARE_SCOPE_SESSION: string = 'session';

export function runtimeReasonText(
  errorMessage: string,
  errorCode: string,
  discoveryReason: string
): string {
  if (errorMessage.length > 0) {
    return errorMessage;
  }
  if (errorCode.length > 0) {
    return errorCode;
  }
  if (discoveryReason.length > 0) {
    return discoveryReason;
  }
  return '';
}
