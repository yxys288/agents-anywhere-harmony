/**
 * 会话详情（对应 Android `ui/screens/sessiondetail/SessionDetailScreen.kt` +
 * `SessionMessages.kt` + `SessionComposer.kt` + `SessionRuntimeControls.kt`）。
 *
 * 组成：状态条 → 审批/输入请求卡 → 消息时间线 → 输入区（含附件与运行时设置）。
 */

import { display } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences, uniformTypeDescriptor } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { SessionDetailStore, ConnectionState } from '../../feature/SessionDetailStore';
import {
  ComposerFacts, MessageAction, SHARE_SCOPE_MESSAGE, SHARE_SCOPE_SESSION, composerPlaceholder,
  replyToText, resolveReplyTarget
} from '../../model/SessionGating';
import { AttachmentStore, checkUploadSize } from '../../feature/AttachmentStore';
import {
  MessageAuthor, MessageKind, TimelineAttachment, TimelineMessage, TimelineRenderItem,
  TimelineRenderOp, TimelineTurnAction, buildTurnActions,
  diffTimelineRenderItems, groupTimelineMessages, timelineRenderItemKey, toolRunSummary, turnActionForKey
} from '../../feature/TimelineProjection';
// ⚠️ R37：`sessionStatusFromWire` / `sessionStatusLabel` / `SessionStatus` 随功能栏那行状态胶囊
// 一起删掉了 —— 状态现在直接渲染 `session.statusLabel`（在 `pull()` 里取好），页面不再自己拼状态文案。
import {
  connectionStatusLabel, messageStatusFailed, messageStatusLabel, runtimeStateStatusLabel
} from '../../model/StatusLabels';
import { formatBytes } from '../../feature/FilesStore';
import {
  RemoteInlineAttachmentRef, RemoteRuntimeModel, RemoteRuntimeNotice, RemoteRuntimeNoticeAction,
  RemoteRuntimePermission, RemoteSessionCommand, RemoteSessionCommandListResponse,
  RemoteSessionCommandResponse
} from '../../model/Types';
import {
  ModelOptionGroup, RUNTIME_MODEL_CAPABILITY, RUNTIME_MODEL_KEY, RUNTIME_PERMISSION_CAPABILITY,
  RUNTIME_PERMISSION_KEY, RUNTIME_SECTION_EMPTY, RUNTIME_SECTION_ERROR, RUNTIME_SECTION_LOADING,
  RuntimeSelectionOption, RuntimeText, catalogRefreshKey, catalogSectionState, disabledEffortNotes,
  displayOptionForGroup, effortDisplayLabel, effortOptionsForGroup, effortSectionTitle,
  groupByModelLabel, isGroupSelected, modelGroupKey, modelGroupSupportingText,
  modelSelectionOptions, optionRowKey, optionSelectable, permissionSelectionOptions,
  permissionSupportingText, selectedEffortLabel, selectedModelGroup, selectedPermissionLabel,
  selectionOf, validatedSelection
} from '../../model/RuntimeSelection';
import {
  effectiveReasoningSegments, inlineSummaryFor, isReasoningExpandable, reasoningTitle
} from '../../model/ReasoningText';
// R50：「Agent 向用户提问」的提问表单（纯逻辑层，可单测）。
import {
  INPUT_REQUEST_OTHER_LABEL, InputRequestDraft, InputRequestForm, InputRequestOption, InputRequestQuestion,
  buildPayload, emptyDraft, inputRequestForm, isComplete, selectCustom, toggleOption, updateCustomText
} from '../../model/InputRequest';
// R50：公告的**投放位置**判定（阻塞公告钉在输入区上方，其余进时间线）—— 上游同款口径。
import { blockingNotices, timelineNotices } from '../../model/NoticeGating';
// R52：上下文圆环的数据层（读 `runtimeState.metadata.contextPressure`）。
import {
  ContextUsage, contextUsageFrom, contextUsageLabel, emptyContextUsage
} from '../../model/ContextUsage';
import { UploadFilePart } from '../../api/ApiClient';
import { AppServices } from '../../feature/AppServices';
import { readAccessToken, readServerUrl } from '../../store/AuthSessionStore';
import { base64Encode, sha256Hex } from '../../utils/Codec';
import { LAST_SESSION_KEY } from '../../store/AppPreferences';
import {
  ComposerDraftStore, DraftAttachment, DraftStorage, shouldRestoreDraft, shouldShowRestoredNotice
} from '../../store/ComposerDraftStore';
import {
  // ⚠️ `errorText` 必须用别名：本页有一个 `@State errorText: string` 字段，
  // 直接 import 同名符号会让 `errorText()` 被解析成实例成员（编译器原话：
  // "Did you mean the instance member 'this.errorText'?"），这是 assembleHap 才暴露的类型错。
  Control, FontSize, Radius, Shadow, Space, StrokeWidth, borderColor, canvas, errorText as designErrorText, faint,
  DialogSpec, ink, muted, onPrimaryAction, primaryAction, raisedSurface, rowPressedSurface, subtle,
  SAFE_AREA_BOTTOM_PX, SAFE_AREA_TOP_PX,
  // 毛玻璃令牌（顶栏 / 输入区 / 悬浮滚动按钮共用同一套半径与玻璃色）
  GLASS_BLUR_RADIUS, GLASS_BRIGHTNESS, GLASS_PANEL_BLUR, GLASS_SATURATION, glassButtonSurface, glassCardSurface,
  glassPanelSurface, glassSurface, deepseekAccent
} from '../Design';
import {
  AaChip, AaCircleIconButton, AaConfigMenuItem, AaEmptyState, AaErrorBanner, AaPrimaryIconButton,
  AaSecondaryButton,
  // R86：弹层类的两个**官方沉浸光感**入口（半模态 `panelMaterial()`=THIN；系统 AlertDialog 取 `dialogMaterial()`=REGULAR）。
  // ⚠️ 本页**不得**自己 `import { uiMaterial }`（契约 §1.6：Kit 依赖收口在 `ui/Components.ets`）；
  //  也**不要**把 R77 撤掉的 `officialBarMaterial` 顺手加回来（本页标题栏按 R77 裁决不挂材质）。
  dialogMaterial, panelMaterial
} from '../Components';
// R53：草稿态（新对话）—— 纯逻辑在 `model/NewChatDraft.ets`，选项与真会话同源。
import {
  DraftSetupKind, NewChatDevice, NewChatProject, draftSetupActionLabel, draftSetupDescription,
  draftSetupTitle, projectsForDevice
} from '../../model/NewChatDraft';
import {
  AGENT_PRESET_LABEL, AgentPresetOption, agentPresetDetail, agentPresetLabel, presetStillSelectable
} from '../../model/AgentPreset';
// R54：草稿态的**首条消息附件**（内联 base64）—— 闸门与引用组装都在纯逻辑层。
import {
  LocalAttachment, canStageAttachment, inlineAttachmentRefFor, inlineAttachmentRowDetail,
  inlineAttachmentUnavailableText, localAttachmentKey, localAttachmentLabel, localAttachmentSummary
} from '../../model/InlineAttachment';
// R91：斜杠指令目录（内置清单 + 服务端目录）。草稿态没有 sessionId ⇒ 只能走内置，
// 服务端通道不可用时也回落到内置并**如实标注来源**（见 model/SlashCommand.ets 文件头）。
import {
  SlashCommandCatalog, SlashCommandItem, SlashCommandParse, appendSlashToDraft, builtInCatalog,
  catalogSourceLabel, draftCommandDisabledReason, draftSlashNotice, draftTypedCommandBlocker,
  draftUsableCount, findSlashCommand, parseSlashCommandLine, sessionSlashNotice,
  slashCommandUsableInDraft, slashInsertionFor
} from '../../model/SlashCommand';
import { SlashCommandStore } from '../../feature/SlashCommandStore';
import { Route, Router } from '../Router';
import { AaMarkdown } from '../Markdown';
import { AaIcon, ICONS } from '../Icon';
// ⚠️ R75：本页**不再**直接 import `AaGlassIconButton`。原来那两枚 44vp 自绘玻璃钮已换成与其余 8 页
// 同一套的 `AaCircleIconButton`（玻璃档，由 `ui/Components.ets` 转发到 `ui/GlassIcon.ets`），
// 因此 `../GlassIcon` 这条依赖在本页归零 —— 不要为了「少一层转发」把它加回来：
// 从 `../GlassIcon` 直接 import 是合法的，但会绕过 `AaCircleIconButton` 的统一档位。
// ⚠️ **R77：本页不再 import `officialBarMaterial`**。R66~R76 那三处（标题栏行 / 元信息行）
// 都改成了「不挂材质、只靠框架标题栏模糊」，本页再无官方材质的落点 —— 留着会变成无用 import。
// （材质入口 `officialBarMaterial` 本身仍在 `ui/Components.ets`，其余 8 页照旧使用。）

/**
 * 「推理强度」那一段的段标识。
 *
 * ⚠️ 它**不是** selection 键：选推理档提交的仍然是 `model` —— 上游的档位 selectionId 本身就是
 * 模型选型值，`EffortSegments` 的回调走的是 `onSelectModel`。
 */
const RUNTIME_EFFORT_SECTION: string = 'effort';

/** 推理段折叠行的最小高度（上游 `heightIn(min = 34.dp)`）。 */
const REASONING_ROW_MIN_HEIGHT: number = 34;
/** 推理段展开正文的左缩进（上游 `Box(Modifier.padding(start = 30.dp, end = 6.dp))`）。 */
const REASONING_BODY_INDENT: number = 30;
/** 等宽字体族（与 `ui/Markdown.ets`、`ui/screens/FilesScreen.ets` 同一处取值）。 */
const REASONING_MONO_FAMILY: string = 'Noto Sans Mono';

/**
 * 输入区（「对话框」）底部的避让上限 / 下限（vp）。
 *
 * 用户要求：「将对话框下移，只避开手势条就行」。
 * 改前这里让的是**整个底部安全区**（真机实测约 59vp），而手势条的可见高度只有约 12vp ——
 * 于是卡片被顶上去近 50vp，屏幕底部空出一大块。
 *
 * 按 [坑 180] 的口径：**不能**写成 `max(安全区, 目标)`（安全区一大就退化成取安全区），
 * 要写成 `max(下限, min(设备上报避让, 目标))` —— 小安全区机型照让、大安全区机型封顶。
 * 两个值都不写死像素：设备上报值由 `EntryAbility` 实测（横竖屏 / 手势条显隐都会变）。
 */
const COMPOSER_BOTTOM_MIN: number = 10;
const COMPOSER_BOTTOM_MAX: number = 18;

/**
 * 「滑到顶部 / 滑到底部」两个定位钮在**停手之后**多久自动隐藏（毫秒）。
 *
 * 用户要求：「默认隐藏，只有在滑动时出现」—— 它们是长对话的临时导航，不是常驻控件。
 */
const SCROLL_BUTTON_HIDE_MS: number = 1200;

/**
 * **标题栏让位量（vp）** —— 时间线 `contentStartOffset`、「滑到顶部」圆钮、提示条浮层共用的那一个数。
 *
 * ## 为什么用**标定常量**而不是实测的 `headerHeight`
 * R76 第一版用 `margin({ top: this.headerHeight })` 给元信息行让位，真机实测**自我压缩**：
 * 元信息行被压到 8px（`Text [53,137][740,145]`）。根因是一个**布局反馈环**：
 * `headerHeight` 由元信息行自己的 `onAreaChange` 写；而元信息行的位置又依赖 `headerHeight`
 * ⇒ 收敛到「让位量 = 0、行高 = 0」的退化不动点。
 * ⇒ 让位量必须是**不依赖被让位元素自身**的值：标题栏高度是框架常量（不随内容变），
 *  所以取标定常量。`HomeScreen` 的 `TITLE_BAR_VP`（=66）就是这个思路，本页照用同值。
 *
 * ⚠️ R78 起 `headerHeight` **已整条删除**（元信息行搬到了输入卡下方，原来那两处消费者都不再需要它）。
 *  本常量与 `titleBarBottomVp()` 仍然保留 —— 它们服务的是**标题栏下沿**这个位置。
 * ⚠️ 66vp 的来源：真机 `TitleBar [0,137][1316,332]` ⇒ 332−137 = 195px ÷ 2.975 = **65.5vp**，
 *  取整 66（与 `HomeScreen.TITLE_BAR_VP` 同值 —— 同一个框架给的栏高，没有理由不同）。
 */
const TITLE_BAR_VP: number = 66;

// ⚠️ 让位量的算法（`状态栏 + TITLE_BAR_VP`）写成结构体上的 `private titleBarBottomVp()`，
//  不放模块级函数 —— 它需要 `this.getUIContext()` 与 `@StorageLink(SAFE_AREA_TOP_PX)`。

/**
 * 「深度求索中...」的**逐字跳动**动画参数（R37 十改，用户要求「字体逐个循环跳动」）。
 *
 * 拆成单字后逐个上抬一下再落回，形成从左到右循环的波浪。
 * ⚠️ 字符数组写成常量（而不是运行时 split）：`ForEach` 的 key 用下标，数组长度必须稳定。
 */
const BUSY_LABEL_CHARS: string[] = ['深', '度', '求', '索', '中', '.', '.', '.'];
/** 每跳一步的间隔（毫秒）。 */
const BUSY_WAVE_STEP_MS: number = 160;
/**
 * R39：接管开关的滑块位移 / 轨道换色时长。
 *
 * 与 `BUSY_WAVE_STEP_MS` 同族（160ms + `Curve.EaseInOut`）—— 本工程 `Curve` 只用两个值
 * （`FastOutSlowIn` 转场类 / `EaseInOut` 循环类），不为一个开关引入第三个。
 */
const TAKEOVER_ANIM_MS: number = 160;
/** 跳动时的上抬距离（vp，负值向上）。 */
const BUSY_WAVE_LIFT: number = -3;

/** 已上传、待随消息发出的附件（chip 要显示真实文件名，所以不能只存 id）。 */
interface PendingAttachment {
  fileId: string;
  name: string;
}

/**
 * `@kit.ShareKit` 的 `systemShare.SharedRecord` 的**最小形状**。
 *
 * ⚠️ 为什么不直接 import 它的类型：ShareKit 是 HSP 型 kit，**任何**静态导入（连 `import type`）
 * 都可能把它带进页面的导入图（坑 30：HSP 不存在时 `PageRouterManager::CreatePage` 直接崩，
 * 而 `canIUse` 仍返回 true）。所以模块只用 `await import()` 取，类型自备形状。
 */
interface ShareRecordShape {
  utd: string;
  content: string;
  title: string;
}

/** `systemShare.ShareControllerOptions` 的最小形状（同上：不静态导入类型）。 */
interface ShareOptionsShape {
  selectionMode: number;
}

/** 待发附件 → 草稿附件（两者字段一致，分开是怕将来只改一处）。 */
function toDraftAttachments(files: PendingAttachment[]): DraftAttachment[] {
  const out: DraftAttachment[] = [];
  for (let i = 0; i < files.length; i++) {
    const item: DraftAttachment = { fileId: files[i].fileId, name: files[i].name };
    out.push(item);
  }
  return out;
}

/** 草稿附件 → 待发附件。 */
function toPendingAttachments(files: DraftAttachment[]): PendingAttachment[] {
  const out: PendingAttachment[] = [];
  for (let i = 0; i < files.length; i++) {
    const item: PendingAttachment = { fileId: files[i].fileId, name: files[i].name };
    out.push(item);
  }
  return out;
}

/**
 * picker 返回的 URI 尾段是 percent-encoded 的（真机实测：`文本.txt` → `%E6%96%87%E6%9C%AC.txt`）。
 * 解码失败就退回原串，绝不让一个坏名字把整条上传链路打断。
 */
function decodeFileName(raw: string): string {
  if (raw.indexOf('%') < 0) {
    return raw;
  }
  try {
    const decoded = decodeURIComponent(raw);
    return decoded.length > 0 ? decoded : raw;
  } catch (error) {
    return raw;
  }
}

// >>> AA-PURE-LOGIC-BEGIN
/**
 * 输入区（composer）的纯逻辑区。
 *
 * 与 `ui/screens/TerminalScreen.ets` 同一套约定：本区**零 import、零 ArkUI 符号**，
 * 由 `tools/logic-test/suite-composer.mjs` 按标记切出来单独转译，在 Node 里断言。
 * UI 文件本身进不了 Node（依赖 @kit / ArkUI），这是让「排布与文案的决策」可被
 * 无设备复现的唯一办法。
 */

/**
 * 输入区动作行里各控件**从左到右**的次序。
 *
 * 对应上游 `SessionComposer.kt` L525-592 的 `ComposerActions`：
 * 左侧 `Row` 依次是「+ 附件」「接管开关」，两端用 `Arrangement.SpaceBetween` 撑开，
 * 主按钮（发送 / 中断）单独贴最右。
 * 取值与 `composer()` 里的实际排布一一对应，改排布必须同时改这里，否则单测会红。
 */
export const COMPOSER_ACTION_ORDER: string[] = ['attach', 'takeover', 'primary'];

/** 输入区是否可编辑：只读（未接管）时禁输入，上游 `enabled = inputEnabled`（L164）。 */
export function composerInputEnabled(readOnly: boolean): boolean {
  return !readOnly;
}

/**
 * 输入框里**显示**的文本：只读时恒为空串。
 *
 * 上游 `SessionComposer.kt` L1686 写的是 `draft = if (takeoverEnabled) draft else ""`：
 * 只读时先把上次没发出去的草稿藏起来，好让「只读模式-开启接管后可发送消息」
 * 这条占位文案一定看得见（`TextArea` 有文本时不显示 placeholder）。
 * 草稿本身不丢 —— 它仍在页面状态里，接管之后立刻回来。
 */
export function composerInputText(draft: string, readOnly: boolean): string {
  return readOnly ? '' : draft;
}

/**
 * 主按钮形态：`interrupt`（运行中，红底方块）/ `send`（可发）/ `send-disabled`（灰）。
 *
 * 上游 `ComposerActions` 的 `primaryActionSurface` 就是这三态（L488-503），
 * 且**运行中优先**：能中断时按钮是中断，发送只能走输入法动作（坑 143）。
 */
export function composerPrimaryKind(showInterrupt: boolean, canSubmit: boolean): string {
  if (showInterrupt) {
    return 'interrupt';
  }
  return canSubmit ? 'send' : 'send-disabled';
}

/** 接管开关点击后的目标状态（开与关共用同一条确认链路，纯取反）。 */
export function takeoverSwitchTarget(current: boolean): boolean {
  return !current;
}

/**
 * 接管开关能否交互。
 *
 * 口径同上游 `takeoverBusy`（`SessionDetailScreen.kt` L1689）：设备离线或请求在飞时
 * 开关不可点 —— 离线这件事由输入框的「设备已离线，暂时不能聊天。」来讲，
 * 不需要再给一个点了没反应的开关。
 */
export function takeoverSwitchInteractive(connectorOnline: boolean, busy: boolean): boolean {
  return connectorOnline && !busy;
}

/**
 * 复制前的归一（上游 `copyMessageText`：先 `text.trimEnd('\r', '\n')` 再判空白）。
 * 全是空白时返回空串 —— 调用方据此跳过复制（复制一个空串比不给入口更迷惑）。
 */
export function copyableText(raw: string): string {
  const value = trimTrailingNewlines(raw);
  return value.trim().length > 0 ? value : '';
}

/**
 * 一条消息「复制」时该拿到的全文。
 *
 * 上游按**回合**聚合复制（`AgentReplyActions` 用 `joinToString('\n\n')` 拼整轮回复、
 * `UserBubble` 给该条正文）；本工程的消息模型是扁平的、没有回合聚合，所以按**单条消息**复制，
 * 并把工具类消息的标题（命令名 / 工具名）一起带上 —— 否则复制出来是没有出处的裸输出。
 */
export function copyPayload(title: string, body: string): string {
  const head = title.trim();
  const content = copyableText(body);
  if (head.length === 0) {
    return content;
  }
  return content.length === 0 ? head : head + '\n' + content;
}

/** 该条消息是否给「复制」入口（内容为空就不给 —— 上游也是先判非空再渲染按钮）。 */
export function copyableMessage(title: string, body: string): boolean {
  return copyPayload(title, body).length > 0;
}

/**
 * 复制一层「题 → 草稿」的表（`@State` 里的嵌套 Map 必须 copy-on-write，原地 `set` 不触发重绘）。
 */
function copyDrafts(source: Map<string, InputRequestDraft>): Map<string, InputRequestDraft> {
  const result: Map<string, InputRequestDraft> = new Map<string, InputRequestDraft>();
  source.forEach((draft: InputRequestDraft, questionId: string) => {
    result.set(questionId, draft);
  });
  return result;
}

/** 裁掉尾部换行（手写而不是 trimEnd：把语义钉在「只裁尾部」，正文前端的空白要原样保留）。 */
function trimTrailingNewlines(raw: string): string {
  let end = raw.length;
  while (end > 0) {
    const ch = raw.charAt(end - 1);
    if (ch !== '\n' && ch !== '\r') {
      break;
    }
    end = end - 1;
  }
  return raw.substring(0, end);
}

// <<< AA-PURE-LOGIC-END

/**
 * 时间线渲染单元的 **LazyForEach 数据源**（R55 性能轮）。
 *
 * 为什么需要它：时间线此前是 `ForEach(this.renderItems, ...)` —— ArkUI 会**一次性建出全部子组件**，
 * 300 条消息的会话首帧就要建 300 个 item 子树（首帧慢、内存峰值高、滚出可视区不回收）。
 * `LazyForEach` 要求数据源实现 `IDataSource`，于是有了这个类。
 *
 * 三条纪律（对应 SDK `lazy_for_each.d.ts` 的明文要求）：
 * 1. **key 稳定唯一**：keyGenerator 走 `timelineRenderItemKey()`（组 id + 会变字段），
 *  内容没变的项 key 逐字符不变（SDK：「Keys must remain unchanged for unmodified data items」）；
 * 2. **变化走通知**：`setItems()` 用 `diffTimelineRenderItems()` 算出「哪几个索引真的变了」，
 *  按需发 `onDataChange / onDataAdd / onDataDelete`，只有整段对不齐时才 `onDataReloaded`；
 * 3. **`onDataDelete` 之前数据源必须已经删掉**（SDK 原话：「Before onDataDelete is called, ensure that the
 *  corresponding data in dataSource has been deleted. Otherwise, undefined behavior will occur」）
 *  ⇒ 先换 `this.items`，再发通知。
 *
 * ⚠️ 本类**不能**是 `@State`：它必须在页面整个生命周期里是同一个对象（`LazyForEach` 只认注册进来的那个
 *  引用），刷新完全靠它自己发出的通知。
 */
class TimelineRenderDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: TimelineRenderItem[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): TimelineRenderItem {
    // 索引由 LazyForEach 保证落在 [0, totalCount) 内；这里仍夹逼一次，坏索引返回末项而不是 undefined。
    const safe = index < 0 ? 0 : (index >= this.items.length ? this.items.length - 1 : index);
    return this.items[safe];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 全量快照 → 只发**必要**的通知（diff 口径见 `diffTimelineRenderItems` 的注释）。 */
  setItems(next: TimelineRenderItem[]): void {
    const prev = this.items;
    if (prev === next) {
      return;
    }
    // ⚠️ 先换数据、再发通知（`onDataDelete` 的 SDK 前提，见类注释第 3 条）。
    this.items = next;
    // 空 ↔ 非空：一条 reload 比 N 条 add 便宜（首屏 300 条就是 300 次插入）。
    if (prev.length === 0 || next.length === 0) {
      this.emitReload();
      return;
    }
    const ops = diffTimelineRenderItems(prev, next);
    for (let i = 0; i < ops.length; i++) {
      const op = ops[i];
      if (op.kind === TimelineRenderOp.RELOAD) {
        this.emitReload();
        return;
      } else if (op.kind === TimelineRenderOp.ADD) {
        this.emitAdd(op.index);
      } else if (op.kind === TimelineRenderOp.DELETE) {
        this.emitDelete(op.index);
      } else if (op.kind === TimelineRenderOp.CHANGE) {
        this.emitChange(op.index);
      }
    }
  }

  private emitReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  private emitAdd(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(index);
    }
  }

  private emitDelete(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataDelete(index);
    }
  }

  private emitChange(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index);
    }
  }
}

@Component
export struct SessionDetailScreen {
  @Prop sessionId: string = '';
  /**
   * R53：草稿态路由参数（`connectorId|projectId`，可空）。
   *
   * 非空 / 或路由本身是 `Route.NEW_CHAT` 时，本页进入**草稿态**：服务端会话还没建，
   * store 持一张本地预览会话，界面（标题 / 元信息 / 输入区 / 运行时设置面板）照常可用，
   * 首条消息发出时才 `create-and-start`，然后 `Router.replace` 到真会话的同一页。
   */
  @Prop draftParam: string = '';
  /** 是否处于草稿态（由路由判定，见 `resolveDraftEntry()`）。 */
  @State prepared: boolean = false;
  @State preparedKind: string = '';
  @State preparedReason: string = '';
  @State preparedDevices: NewChatDevice[] = [];
  @State preparedProjects: NewChatProject[] = [];
  @State preparedPresetOptions: AgentPresetOption[] = [];
  @State preparedPreset: string = '';
  /** R54：草稿态暂存的本地附件（没有 fileId；创建会话时才编码成内联附件随请求发出）。 */
  @State preparedAttachments: LocalAttachment[] = [];
  /** R54：该 Agent 是否上报了 `runtime.attachment`（不可用时「添加文件」明确禁用）。 */
  @State preparedAttachmentsAllowed: boolean = false;
  /** R54：正在读文件（选完 → 读字节前的短暂窗口，防连点）。 */
  @State preparedAttachBusy: boolean = false;
  /** 草稿态的「选择工作区」面板是否展开（内联区块，与运行时设置同一套做法）。 */
  @State workspacePanelOpen: boolean = false;
  /** 草稿态当前指向的设备 / 工作区（面板里比 active 用）。 */
  @State preparedConnectorId: string = '';
  @State preparedProjectId: string = '';
  // ⚠️ 见 HomeScreen 顶部注释：状态必须在 build 里被真正读到才会触发刷新。
  @State messages: TimelineMessage[] = [];
  /** 渲染单元（连续工具调用折成组；上游 `groupTimelineMessages`）。快照更新时算一次，不在 build 里算。 */
  @State renderItems: TimelineRenderItem[] = [];
  /**
   * 时间线 `LazyForEach` 的数据源（R55）。⚠️ **不是** `@State`：它必须在页面生命周期内是同一个对象，
   * 刷新靠它自己发的 `onDataChange / onDataAdd / onDataDelete / onDataReloaded`（见类注释）。
   */
  private timelineSource: TimelineRenderDataSource = new TimelineRenderDataSource();
  /** 回合末尾动作（上游 `agentActionsByTurnEnd`）：`复制 / 分享` 只在回合末尾出一次。 */
  @State turnActions: TimelineTurnAction[] = [];
  /**
   * 底部安全区高度（px，`EntryAbility.pushSafeAreaInsets()` 实测写入）。
   * R13-15：底部避让由**本页自己的底部元素**承担（根节点只避让顶部，否则列表底部会多一条空白）。
   */
  @StorageLink(SAFE_AREA_BOTTOM_PX) safeAreaBottomPx: number = 0;
  /**
   * 顶部安全区高度（px，`EntryAbility.pushSafeAreaInsets()` 实测写入）。
   *
   * ## R76 新增本字段的原因（**不是**为了页面自己避让状态栏）
   * `margin` 与 `List.contentStartOffset` 的坐标系都是**窗口顶（y=0）**，不是「内容区顶」——
   * 真机实测：`margin({ top: 66 })` 把元信息行放到 y=196px（= 66×2.975），
   * **不是** 137+196=332px。这与 `HomeScreen.listTopOffsetVp()` 的记录完全一致
   * （那边写死 `px2vp(safeTopPx) + TITLE_BAR_VP`，66vp 那档实测首项钻到栏底下）。
   * ⇒ 要把东西放到「标题栏下沿 = 332px」，必须传 `状态栏 46vp + 标题栏 66vp = 112vp`。
   *  本字段就是那个 46vp 的来源（与首页同源同值）。
   * ⚠️ **不改动页面根节点的安全区**：仍由 `pages/Index.ets` 的 padding 统一做
   *  （`suite-settings` 有断言守着「本页不许自己 `expandSafeArea` / `topInset()`」）。
   */
  @StorageLink(SAFE_AREA_TOP_PX) safeTopPx: number = 0;
  @State notices: RemoteRuntimeNotice[] = [];
  /**
   * 公告按**投放位置**分好桶（R50）：`blockingNotices` 钉在输入区上方、`timelineNotices` 进时间线。
   *
   * ⚠️ 分桶的理由（真机实测）：本工程原先把**所有**公告都当时间线的第一项，而时间线默认停在最新消息
   * （R37 十改）⇒ 阻塞式提问**在屏幕外**，用户看到的就是「Agent 提问但手机没弹窗」。
   * 上游 `SessionDetailScreen.kt:1353-1361` 与 `SessionMessages.kt:278-285` 就是分开放的。
   */
  @State blockingNoticeList: RemoteRuntimeNotice[] = [];
  @State timelineNoticeList: RemoteRuntimeNotice[] = [];
  @State sessionTitle: string = '会话';
  @State sessionSubtitle: string = '';
  /**
   * 会话状态（「空闲」「运行中」「待审批」…）。
   *
   * R37：改前它拼在 `sessionSubtitle` 的开头（「空闲 · DeepSeek Harness · LYW · <工作区路径>」），
   * 功能栏里同一状态还会在下一行再出现一次（「● 空闲」胶囊）。现在**只留这一处**，
   * 且渲染在「已连接」左边。
   */
  @State sessionStatusText: string = '';
  /** 会话工作区：用于「在这个会话的工作目录里浏览文件」（对应上游 `SessionAgentFilesScreen`）。 */
  @State sessionConnectorId: string = '';
  @State sessionCwd: string = '';
  /** 附件缓存快照（fileId → data URI）；build 只读它，不直接读 store（见 HomeScreen 顶部注释）。 */
  @State attachmentUris: Map<string, string> = new Map<string, string>();
  @State attachmentNames: Map<string, string> = new Map<string, string>();
  @State attachmentErrors: Map<string, string> = new Map<string, string>();
  /**
   * 附件图片的最大宽度（vp）。
   *
   * ⚠️ 图片**不能**只写 `width('100%')`：气泡是按内容撑开的（只有 `maxWidth: 86%`），
   * 子节点要 100% 会解析成一个比气泡更宽的值 —— 真机/模拟器实测：整条气泡向右溢出屏幕，
   * 左侧文字被裁掉、图片右半边看不见（同坑 141 的成因）。
   * 这里按屏幕宽度算出上限（屏幕宽 vp × 0.72，再留出气泡内边距），跨设备都成立。
   */
  @State imageMaxWidth: number = 240;
  /**
   * 用户气泡的宽度上限（vp）与气泡**内容**的宽度上限（vp）。
   *
   * ⚠️ R49 真机缺陷的修复点。改前气泡写的是 `constraintSize({ maxWidth: '86%' })` ——
   * ArkUI 对「按内容撑开 + 只有百分比上限」的容器**不会**先减掉上限再量孩子：孩子（Markdown 正文）
   * 的 `width('100%')` 按「可用宽度 − 左内边距」解析（连气泡自己的右内边距都不减），
   * 于是正文比气泡宽、一路顶到**屏幕右边缘**，用户消息的尾部整段看不见
   * （模拟器 dump 实测：气泡 `[218,1305][1278,1451]`、里面的正文 `[260,1347][1316,1409]`，
   * 右边界 1316 = 屏宽）。数值上限在**测量阶段**就参与约束，不受这条解析规则影响。
   *
   * 取值对齐上游 `SessionMessages.kt:1296` 的 `maxBubbleWidth = maxWidth * 0.78f`
   * （`maxWidth` 是消息行的可用宽度）；内容上限再扣掉气泡自身的左右内边距。
   */
  @State bubbleMaxWidth: number = 300;
  @State bubbleContentWidth: number = 276;
  /**
   * 时间线**每一项**的宽度（vp）= 屏宽 − 两侧 12vp 内边距。
   *
   * ⚠️ 它只负责定**项自己的宽度**（让每一项严格落在 `[42,1274]`），**不是**「让里面的 `width('100%')` 变正确」的手段 ——
   * 那个做法 R49 实测**无效**：`renderItem` 的 `Column` 已经是这个数值宽度，它孙子的 `100%` 照样解析成
   * 「**窗口**右边缘 − 自身左偏移」（`Text "协议层"` 仍 `[123,…][1316,…]`）。
   * 列表子树里 `Row` 内的正文必须用 `layoutWeight(1)`，见 `AaMarkdown.listItemText()`。
   */
  @State timelineContentWidth: number = 352;
  /** 屏幕高度（vp）—— 阻塞公告卡的限高按屏高比例算（上游 `screenHeightDp * 0.58 / 0.38`）。 */
  @State screenHeightVp: number = 800;
  /** 点开的附件（大图查看用的 data URI 与标题）。 */
  @State viewerUri: string = '';
  @State viewerTitle: string = '';
  @State viewerOpen: boolean = false;
  @State runtimeStatus: string = '';
  @State runtimeReason: string = '';
  @State errorText: string = '';
  @State noticeText: string = '';
  @State connection: string = ConnectionState.IDLE;
  @State loading: boolean = false;
  @State hasMoreHistory: boolean = false;
  @State models: RemoteRuntimeModel[] = [];
  @State permissions: RemoteRuntimePermission[] = [];
  @State commands: RemoteSessionCommand[] = [];

  // -------------------------------------------------------------------------
  // 运行时选型（模型 / 推理强度 / 权限模式）
  // -------------------------------------------------------------------------
  // ⚠️ 全部是 @State 快照、由 `pull()` 从 store 拷贝（数组每次都换新引用）：
  // build 只读这些字段，不读 store —— 否则 `@State` 登记不到渲染依赖，数据变了界面不动。

  /** 模型目录展开后的全部选项（每个推理档一个选项）。`catalogSectionState` 要用它判三态。 */
  @State runtimeModelOptions: RuntimeSelectionOption[] = [];
  /** 模型选项按「模型名」分组的快照（ForEach 直接遍历它）。 */
  @State runtimeModelGroups: ModelOptionGroup[] = [];
  /** 权限目录选项快照。 */
  @State runtimePermissionOptions: RuntimeSelectionOption[] = [];
  /** 当前模型分组的推理档（多于 1 个才显示，见 `effortOptionsForGroup`）。 */
  @State runtimeEffortOptions: RuntimeSelectionOption[] = [];
  /** 被禁用的推理档 + 原因，拼成一段说明文（上游 EffortSelectionSection 末尾那几行）。 */
  @State runtimeEffortNotes: string[] = [];
  /** 推理强度段的标题（`<模型名> 的推理强度`，拿不到模型名时回退运行时名）。 */
  @State runtimeEffortTitle: string = '';
  /** 推理强度分段条的轨道宽度（vp），由 `onAreaChange` 量得 —— 拖动按落点换算档位要用。 */
  @State runtimeEffortTrackWidth: number = 0;
  /** 拖动过程中临时选中的档位（空串 = 没在拖）；松手才提交（上游 `dragSelectionId`）。 */
  @State runtimeEffortDragId: string = '';
  /** 当前生效的模型 selectionId（由服务端 state.selections 校验得出；空串 = 没有）。 */
  @State runtimeSelectedModel: string = '';
  /** 当前生效的权限模式 selectionId。 */
  @State runtimeSelectedPermission: string = '';
  /** 当前推理档的显示标签（无档位时回退到「默认」）。 */
  @State runtimeEffortLabel: string = '';
  /** 当前权限模式的显示名。 */
  @State runtimePermissionLabel: string = '';
  /** 模型目录是否在加载（加载中显示转圈而不是「暂无可用设置」）。 */
  @State runtimeModelLoading: boolean = false;
  @State runtimePermissionLoading: boolean = false;
  /** 目录加载失败的原话（空串表示没有失败）。 */
  @State runtimeModelError: string = '';
  @State runtimePermissionError: string = '';
  /** 选型提交进行中：期间所有选项不可点（上游 `busy`）。 */
  @State runtimeBusy: boolean = false;
  @State takeover: boolean = false;
  @State canInterrupt: boolean = false;
  /**
   * 只读态（未接管）：输入区禁输入、按钮不可点、占位文案给出「怎么才能发」的指引。
   *
   * ⚠️ 这是上游 composer 的**第一道闸**（`SessionDetailScreen.kt` L1333/L1543）。
   * 服务端对未接管的会话一律 409（`session_run.py` L397），客户端不提前门控，
   * 用户就会「能打字、能点发送、只收到一句英文 409 报错」——真机实测的原话是
   * `session is read-only until takeover is enabled`。用户把它复述成「仅可读」。
   */
  @State readOnly: boolean = false;
  /** 运行时当前能接收的动作（`send` / `steer` / `none`），决定按钮与端点。 */
  @State messageAction: string = MessageAction.SEND;
  /** 输入区占位文案：按上游优先级逐条判定，替用户把「为什么不能发」说清楚。 */
  @State composerPlaceholder: string = replyToText('Agent');
  /** 设备是否在线（`showInterrupt` 的第一项）。 */
  @State connectorOnline: boolean = false;
  @State draft: string = '';
  /**
   * 恢复草稿时的**原文快照**（没从后端恢复过草稿时是空串）。
   *
   * ⚠️ 它不是「显示过就置位」的开关，而是显示条件的比较基准：提示该不该显示由
   * `shouldShowRestoredNotice(draft, draftRestoreSnapshot)` 推导 —— 整个页面**没有任何一处
   * 把提示置空**，所以不存在被误清的路径。R8 第二轮复验的根因正是老实现用了 @State 字符串开关：
   * `TextArea({ text: this.draft })` 被程序回填时**也会触发 onChange**，那句 `draftNotice = ''`
   * 把刚设好的提示在同一帧清掉了（6 帧全 0 命中）。
   */
  @State draftRestoreSnapshot: string = '';
  @State showRuntimeSheet: boolean = false;
  /**
   * 审批卡里「需要输入」的文本，**按 noticeId 分行存**。
   * 共用一个字段会让多张审批卡互相清空、甚至把 A 卡的文字提交给 B 卡。
   */
  @State noticeInputs: Map<string, string> = new Map<string, string>();
  /**
   * **提问表单**的作答草稿（R50）：`noticeId → (questionId → draft)`。
   *
   * ⚠️ 与 `noticeInputs` 一样**按 noticeId 分桶** —— 多张提问卡同时在场时共用一个字段会互相清空。
   * ⚠️ 写的时候**两层都换新引用**（copy-on-write）：`@State` 里的 Map 原地 `set` 不会触发重绘
   * （与 `attachmentUris` 那批快照同一个道理）。
   */
  @State inputRequestDrafts: Map<string, Map<string, InputRequestDraft>> =
    new Map<string, Map<string, InputRequestDraft>>();
  /** 待发送的附件：id + 展示名（只存 id 时 chip 只能显示一串十六进制）。 */
  @State attachedFiles: PendingAttachment[] = [];
  @State attaching: boolean = false;
  /**
   * 接管请求进行中（开关不可重复点）。
   *
   * 上游对应的是 `takeoverBusy = isPreparedSession || state.takeoverInFlight || !connectorOnline`
   * （`SessionDetailScreen.kt` L1689）；本工程的离线那一半由 `takeoverSwitchInteractive()` 承担。
   */
  @State takeoverBusy: boolean = false;
  /** 确认框要问的方向（`true` = 开启接管）；自绘弹层是**异步**打开的，不能靠闭包传参。 */
  @State takeoverPending: boolean = false;
  /** 自绘确认框的 dialogId（`closeCustomDialog` 用）；0 表示当前没开。 */
  private takeoverDialogId: number = 0;
  /** 分享请求进行中（分享按钮与选择范围的对话框在请求期间不可重复触发）。 */
  @State shareBusy: boolean = false;
  /**
   * 最近一次「复制 / 分享」的结果提示，显示在**输入区正上方**一行。
   *
   * ⚠️ 单独一个 @State 而不是复用 `noticeText`：`pull()` 每次都用 `store.notice` 覆盖它，
   * 消息流一来（WS 推事件）刚弹的提示就没了。也不走 `promptAction.showToast` ——
   * 本工程统一用**节点**做提示（同 HomeScreen 的顶栏提示条：便于 dumpLayout 验证且零告警）。
   */
  @State actionHint: string = '';
  @State expandedIds: string[] = [];

  private store: SessionDetailStore = SessionDetailStore.get();
  private attachments: AttachmentStore = AttachmentStore.get();
  private draftStore: ComposerDraftStore = ComposerDraftStore.get();
  /**
   * 当前 `@State draft` 归属的会话 id：切会话时先把旧内容落回**它自己的**会话、
   * 再载入新会话的草稿（见 `syncDraftSession`）。显式路由栈下同一个页面组件可能被复用，
   * 所以不能只靠 `aboutToAppear`。
   */
  private draftSessionId: string = '';
  /**
   * 上一次**成功**从持久化后端恢复过草稿的会话 id（新页面实例为空串）。
   *
   * ⚠️ 必须与 `draftSessionId` 分开：前者只记「读过」，后者记「当前归属」。
   * 合成一个就会出现 D1 那个缺陷 —— 后端还没就绪时先跑过一次，
   * 「没读成」被记成「已恢复」，之后再也不会重读（杀进程重启后草稿永远回不来）。
   */
  private draftRestoredFor: string = '';
  /** 存成字段才能被 `offChange` 摘除（单例 store 的监听器数组只增不减）。 */
  private storeListener: () => void = () => {
    this.pull();
  };
  private attachmentListener: () => void = () => {
    this.pull();
  };
  /** 页面是否还活着：`open()` 等长链路返回后要复查，避免给已离开的页面建 WS。 */
  private alive: boolean = false;
  /**
   * 运行时设置面板内层 Scroll 的控制器。
   *
   * ⚠️ 为什么需要它：面板是**固定高度 + 内部滚动**，真机基线里展开后第一个模型按钮被裁掉一半
   * （内容比视口高，视口停在中途）。展开时显式把滚动位置归零，首项才必然完整。
   */
  private runtimeScroller: Scroller = new Scroller();
  /** 上一次触发目录刷新的幂等键（空串 = 没触发过），防止「缺失 → 刷新 → 仍缺失」反复打转。 */
  private runtimeModelRefreshKey: string = '';
  private runtimePermissionRefreshKey: string = '';

  /** 时间线的滚动控制器 —— 「滑到顶部 / 滑到底部」两个悬浮按钮用它。 */
  private timelineScroller: Scroller = new Scroller();
  /**
   * 是否**跟随最新消息**（true = 当前停在底部）。
   *
   * R37 十改（用户要求「点击会话时默认显示最新结果，且随会话进行自动显示最新消息」）：
   * 进页面先无条件到底（见 `tailJumpPending`），之后只在**本来就停在底部**时才跟随 ——
   * 用户上翻看历史时，新消息不会把他拽回底部。
   */
  @State followTail: boolean = true;
  /** 页面刚打开时的那次「无条件到底」还没做（做完置 false，后续走 `followTail`）。 */
  private tailJumpPending: boolean = true;
  /**
   * 两个定位钮当前是否可见（默认 **false** = 隐藏）。
   *
   * 用户要求：「默认隐藏，只有在滑动时出现」。由 `List.onScroll` / `onScrollStop` 驱动，
   * 停手 `SCROLL_BUTTON_HIDE_MS` 之后自动隐藏。
   */
  @State showScrollButtons: boolean = false;
  /**
   * 「深度求索中… N秒」已执行的秒数（R37 九改，用户要求）。
   *
   * ⚠️ 计时**从本页检测到「执行中」的那一刻**开始（本地时钟），不是服务端给的任务开始时间 ——
   * 服务端没有暴露这个字段，近似即可（参考图上那个「17秒」也是这个量级）。
   */
  @State busySeconds: number = 0;
  /** 计时起点（毫秒）；0 表示当前没有在计时。 */
  private busyStartedAt: number = 0;
  /** 每秒刷新的定时器句柄（-1 = 没在跑）。 */
  private busyTimer: number = -1;
  /** 「深度求索中...」波浪当前抬到哪一位（0..BUSY_LABEL_CHARS.length-1，循环）。 */
  @State waveStep: number = 0;
  /** 波浪定时器句柄（-1 = 没在跑）；与 `busyTimer` 同生共死（都挂在「执行中」状态上）。 */
  private waveTimer: number = -1;
  /** 自动隐藏的定时器句柄（-1 = 没有在跑）。页面销毁时必须清掉，否则会写已销毁页面的 @State。 */
  private scrollHideTimer: number = -1;
  /**
  * **底部输入区（含元信息行）的实测高度**（vp）—— `composer()` 那个 Column 的 `onAreaChange` 写入。
  *
  * ## R78：量的是「输入卡 + 元信息行」整条
  * 元信息行本轮搬到了输入卡下方、且在**同一个 Column 里** ⇒ 本值天然含它，不需要再单独量一次。
  * 消费者两处，都跟着一起走：① 时间线的 `contentEndOffset(composerHeight + Space.S)`；
  * ② 「滑到底部」圆钮的 `margin.bottom`。
  *
  * ⚠️ 末端让位仍走 `contentEndOffset`：输入区**保持浮层**，
  *  「内容从下方对话框背后穿过」是用户明确要的效果（R37），**未动**。
  * ⚠️ 实测而非写死：输入区会随附件条 / 指令面板变化，元信息行会随状态原因行增减。
  *
  * ⚠️ **`@State headerHeight` 已在 R78 删除**（元信息行的独立实测高度）——
  *  它唯一的消费者是「提示条/面板浮层」的让位，而那一层现在贴标题栏下沿、不吃这个值了。
  *  它当年踩过的坑仍然成立、要留着：**用「被测元素自身的实测尺寸」给它自己让位会形成布局反馈环**，
  *  真机实测行高被压成 8px（见 `TITLE_BAR_VP` 与 `坑 248`）。
  */
  @State composerHeight: number = 0;

  /**
   * **输入卡（composerCard）自身的实测高度**（vp，不含它外面的左右 `Space.M`）。
   *
   * ## R92 新增（消费者只有一处）
   * 「从卡片上沿到屏幕底」那一段高度 = 本值 + `composerBottomSpan()`
   * ⇒ 见 `composerGlassBlockHeightVp()`。它同时喂：① 「滑到底部」圆钮的 `margin.bottom`；
   * ② 模糊块的高度（块顶边由此**恰好落在卡片上沿**）。
   *
   * ## 为什么必须**实测**而不是写死
   * 卡片的真实高度是内容撑出来的：附件条（`composerFileCount() > 0`）、`TextArea` 的
   * 28..92 自适应、附件态收到 40 上限……都会改它；`constraintSize` 只给了 `[104, 218]`
   * 的上下界，界内是浮动的（R13-14 真机实测过只读态 406px ≈ 137vp）。
   *
   * ## ⚠️ 没有布局反馈环
   * `踩坑记录 [坑 248]` 记的是「**用被测元素自身的实测尺寸给它自己让位**」——
   * 当年元信息行的 `margin-top` 由它自己的高度给，于是收敛到「让位 0 / 行高 0」的退化不动点。
   * 本值的消费者**都不改变卡片的宽高**：
   * · 模糊块的高度只决定**块自己**画多大（它在 `Stack` 里，不去测量卡片、也不约束卡片）；
   * · 圆钮的 `margin.bottom` 在**另一个容器**（`build()` 内容层的 `Stack`）里，与卡片无关。
   * ⇒ 单调收敛。
   *
   * ⚠️ 首帧为 0（`onAreaChange` 要等第一次布局完）：那一帧模糊块只有兜底的 8vp 那一点高度、
   *  第二帧就补到卡片上沿（与 `composerHeight` 同一个首帧现象，肉眼不可见）。
   */
  @State composerCardHeight: number = 0;

  /**
   * **「卡片下沿 → 屏幕底」那一段的实测高度**（vp）：元信息行 + 手势条避让。
   *
   * ## R92 新增（为什么量这一整段、而不是只量元信息行）
   * 卡片要用它做**块内的 `margin.bottom`**（把卡片从块底推上去那么高）。
   * ⚠️ R92 首版曾只量元信息行、再与 `composerBottomInset()` 相加 —— **那是错的**：
   *  元信息行容器的 `padding.bottom` 里**已经含**了 `composerBottomInset()`，
   *  量出来的行高里就有它 ⇒ 再加一次等于**重复计一遍手势条避让**。
   *  现在只量一个量、**只减不加**，手势条避让只出现在这一个地方。
   *
   * ## 消费者两处
   * ① `composerGlassBlockHeightVp()`（= 卡片高 + 本值）⇒ 圆钮的 `margin.bottom` 与模糊块的高度；
   * ② 卡片自己的 `margin.bottom = composerBottomSpanHeight` ⇔ **同一个量、只做赋值** ——
   *  卡片下沿**永远**落在「元信息行 + 手势条避让」之上，与 R79 逐字同位置。
   *
   * ## ⚠️ 本值没有布局反馈环（坑 248 要区分开）
   * 本值是**块底那个与卡片无关的盒子**（元信息行 + 手势条避让）撑出来的，卡片的
   * `margin.bottom` 又**恒等于**它 ⇒ 不动点唯一、没有自压；R76 那次踩的坑是
   * 「让位量本身进了被测量元素的盒子」（`margin-top` 被算进行高）—— 这里不是：
   * 卡片的下外边距在卡片**外面**，不进卡片的盒子、也不改变本值。
   * ⚠️ 量测**必须挂在一个真有高度的盒子上**（R92 试过挂空的 `Column` ⇒ 恒量到 0）。
   *
   * ⚠️ 首帧为 0：卡片会临时贴在块底，第二帧补上（`composerBottomSpan()` 兜 8vp 那一帧）。
   */
  @State composerBottomSpanHeight: number = 0;

  // ---- R52：上下文圆环 + DSH 原生指令面板 --------------------------------------------
  /** 上下文用量（`runtimeState.metadata.contextPressure` 推导；`known=false` 时不画圆环）。 */
  @State contextUsage: ContextUsage = emptyContextUsage();
  /** 指令面板是否展开（**内联区块**，不用 bindSheet —— 根节点只能挂一个，见 `runtimePanel` 注释）。 */
  @State commandPanelOpen: boolean = false;
  @State sessionCommands: RemoteSessionCommand[] = [];
  /**
   * R91：当前可渲染的**整套**目录（含来源与「服务端通道不可用」的原因）。
   *
   * 与 `sessionCommands` 的关系：后者是服务端返回的原始条目（保留给既有逻辑），
   * 本字段是**给 UI 用的那一份** —— 草稿态 = 内置清单；服务端可用 = 服务端目录；
   * 服务端不可用 = 内置清单 + 失败原因。三者都由 `refreshCommandCatalog()` 收口。
   */
  @State commandCatalog: SlashCommandCatalog = builtInCatalog();
  @State commandLoading: boolean = false;
  @State commandError: string = '';
  /** 指令执行结果的一句话回执（成功/失败都显示在面板里，不弹 toast）。 */
  @State commandNotice: string = '';
  /** 指令目录请求序号：切会话时作废旧响应。 */
  private commandRequestId: number = 0;

  aboutToAppear(): void {
    this.alive = true;
    // R53：记住「最后打开过的会话」—— **只**服务于新对话页的默认工作区
    // （DSH 那条回退链的第 ②级「当前会话所属工作区 ＞ 最近更新的工作区」，
    //  见 `model/NewChatDraft.pickDraftProject`）。写在这里而不是路由层：
    // 「真的打开了某个会话」只有本页知道（路由参数可能指向一个已被删除的会话）。
    if (this.sessionId.length > 0) {
      AppStorage.setOrCreate<string>(LAST_SESSION_KEY, this.sessionId);
    }
    // R37 十改：每次进页面都重新做一次「无条件到底」（用户要求默认显示最新结果）。
    this.tailJumpPending = true;
    this.followTail = true;
    // 取屏幕尺寸要 try/catch：`display.getDefaultDisplaySync()` 会被 ArkTS 判为
    // 「可能抛异常」，不处理就是一条构建告警（本工程保持零告警）。
    try {
      const metrics = display.getDefaultDisplaySync();
      const density = metrics.densityPixels > 0 ? metrics.densityPixels : 1;
      const widthVp = metrics.width / density;
      // 消息行的可用宽度 = 屏幕宽 − 时间线每一项的左右内边距（见 `timeline()` 尾部注释）。
      const rowWidth = widthVp > 0 ? widthVp - Space.M * 2 : 0;
      const heightVp = density > 0 ? metrics.height / density : 0;
      if (heightVp > 0) {
        this.screenHeightVp = heightVp;
      }
      if (rowWidth > 0) {
        this.timelineContentWidth = rowWidth;
        // 上游 `SessionMessages.kt:1296`：`maxBubbleWidth = maxWidth * 0.78f`
        const bubble = Math.floor(rowWidth * 0.78);
        this.bubbleMaxWidth = bubble;
        this.bubbleContentWidth = bubble - Space.M * 2;
        // 图片上限跟着气泡内容宽走：改前是「屏宽 × 0.72」，比气泡内容宽还大 20vp，
        // 在窄屏/大字号下会直接把气泡顶破（同 `imageMaxWidth` 原来的注释）。
        this.imageMaxWidth = this.bubbleContentWidth;
      } else {
        this.imageMaxWidth = 240;
      }
    } catch (error) {
      this.imageMaxWidth = 240;
    }
    // ⚠️ 这几步的顺序就是 D1（杀进程重启后草稿不恢复）的修复点，别调换：
    //  ① 先恢复草稿 —— `syncDraftSession()` 内部会**先装好草稿后端**（幂等）再读，
    //  而且后端没就绪时不会把「没读成」记成「已恢复」（见 shouldRestoreDraft）；
    //  ② 再注册监听器 / 调 `attachments.reset()`，因为它们会**同步**触发 `pull()`
    //  → `syncDraftSession()`。老顺序把 attach 排在 `reset()` 之后，而 `reset()`
    //  内部会 `notify()` ⇒ 那一次恢复发生在后端就绪之前，读回空草稿却把会话记成
    //  「已恢复」，于是永远不再重读（真机现象：杀进程重启后草稿不回来；
    //  同一进程内还能恢复，只是命中了 `ComposerDraftStore` 的内存缓存）。
    this.syncDraftSession();
    this.store.onChange(this.storeListener);
    // 附件缓存到货/失败后也要刷新界面（否则图片永远不出现）
    this.attachments.onChange(this.attachmentListener);
    this.attachments.reset();
    if (this.isDraftEntry()) {
      // R53 草稿态：解析「设备 → Agent → 工作区」并装好本地预览会话。
      // **不**开会话级 WS、**不**标记已读 —— 服务端会话此刻还不存在。
      this.store.beginPrepared(this.draftParam).then(() => {
        if (this.alive) {
          this.pull();
        }
      });
      return;
    }
    this.store.open(this.sessionId).then(() => {
      // open() 是 5 个串行请求；期间用户可能已经返回上一级（aboutToDisappear 已 stopRealtime）。
      // 不复查就会给「已经离开的会话」重新开一条 WS 并无限重连。
      if (!this.alive) {
        return;
      }
      this.store.startRealtime();
      this.store.markRead();
    });
  }

  aboutToDisappear(): void {
    this.alive = false;
    // 定位钮的自动隐藏定时器：页面销毁后必须停掉（否则回调会写已销毁页面的 @State）。
    this.cancelScrollButtonTimer();
    // 「深度求索中…」的秒表同理：留着会每秒写一次已销毁页面的 @State。
    this.syncBusyTimer(false);
    this.store.offChange(this.storeListener);
    this.attachments.offChange(this.attachmentListener);
    this.store.stopRealtime();
    // R53：草稿态下**没有创建会话**就离开（返回了首页）⇒ 把预览态清干净。
    // 用 store 自己的判断而不是本页的 prepared 标志：创建成功跳转时本页 @State 还是 true，
    // 而 store 那一份已经被清掉了 —— 再清一次会把刚落地的 createdSessionId 抹掉。
    if (this.store.isPrepared()) {
      this.store.cancelPrepared();
    }
  }

  /** 本次进入是不是「新对话」草稿态（按路由判定，参数为空也算）。 */
  private isDraftEntry(): boolean {
    return Router.current().route === Route.DRAFT_SESSION;
  }

  /** store → @State 快照（build 只读这些字段）。 */
  private pull(): void {
    this.messages = this.store.messages.slice();
    // 分组与「回合末尾动作」都是纯函数（见 `feature/TimelineProjection.ets`，已进 Node 断言）：
    // 上游 `SessionMessages.kt:288-293` 也是在 `displayMessages` 变化时才重算这两样。
    this.renderItems = groupTimelineMessages(this.messages);
    // R55：这一版分组结果喂给 `LazyForEach` 的数据源 —— 由它 diff 出「哪几个索引真的变了」再按需通知，
    // 不再让 ArkUI 按整个数组重建时间线（`renderItems` 仍保留：`buildTurnActions` 与其它读点要用）。
    this.timelineSource.setItems(this.renderItems);
    this.turnActions = buildTurnActions(this.renderItems);
    this.notices = this.store.openNotices();
    // R52：上下文圆环的数据 —— DSH 的 `contextPressure` 经 bridge 补丁放进 runtimeState.metadata。
    // 拿不到就 `known=false`（不画圆环，也绝不猜一个分母出来）。
    const runtimeState = this.store.runtimeState;
    this.contextUsage = contextUsageFrom(runtimeState === undefined ? undefined : runtimeState.metadata);
    // R50：按投放位置分桶 —— 阻塞公告（审批 / 提问）钉在输入区上方，其余才进时间线。
    // 判据是纯函数（`model/NoticeGating.ets`，已进 Node 断言），与上游 `blocksSession` 同口径。
    this.blockingNoticeList = blockingNotices(this.notices, this.sessionId);
    this.timelineNoticeList = timelineNotices(this.notices, this.sessionId);
    const session = this.store.session;
    this.sessionTitle = session !== undefined ? session.title : '会话';
    // R37：状态从副标题里**拆出来**（它现在渲染在功能栏右侧「已连接」的左边，见 headerMeta()）——
    // 一个状态在一屏里只出现一次，副标题只留「运行时 · 设备 · 工作区」。
    this.sessionSubtitle = session !== undefined ? session.metaLabel : '';
    this.sessionStatusText = session !== undefined ? session.statusLabel : '';
    this.sessionConnectorId = session !== undefined ? session.connectorId : '';
    this.sessionCwd = session !== undefined && session.cwd !== undefined ? session.cwd : '';
    this.takeover = session !== undefined ? session.takeover : false;
    this.connectorOnline = session !== undefined ? session.connectorOnline : false;
    // ⚠️ 先存旧值再赋值：`canInterrupt` 从 false→true 的那一刻要**开启计时**（R37 九改），
    // 之后每次 pull() 都重启一次的话，秒数会永远停在 0。
    const wasBusy = this.canInterrupt;
    this.canInterrupt = session !== undefined &&
      (session.status === 'running' || session.status === 'waiting' || session.status === 'pending');
    if (this.canInterrupt !== wasBusy) {
      this.syncBusyTimer(this.canInterrupt);
    }
    this.readOnly = this.store.isReadOnly();
    this.messageAction = this.store.messageAction();
    const runtime = this.store.runtimeState;
    this.runtimeStatus = runtime !== undefined ? runtime.status : '';
    this.runtimeReason = runtime !== undefined && runtime.statusReason !== undefined
      ? runtime.statusReason : '';
    // ⚠️ 必须放在 `runtimeReason` **之后**：`computePlaceholder()` 会读
    // `this.runtimeReason` 与 `this.runtimeStatus` 来分派文案，提前算会永远拿到上一帧的值
    // （本工程第二轮在终端度量上踩过同一个坑：赋值顺序错了，界面显示的是滞后一帧的数据）。
    this.composerPlaceholder = this.computePlaceholder();
    this.models = this.store.modelCatalog !== undefined ? this.store.modelCatalog.models : [];
    this.permissions = this.store.permissionCatalog !== undefined
      ? this.store.permissionCatalog.permissions : [];
    this.syncRuntimeSelections();
    this.commands = this.store.commands.slice();
    this.errorText = this.store.error;
    this.noticeText = this.store.notice;
    this.connection = this.store.connection;
    this.loading = this.store.loading;
    this.hasMoreHistory = this.store.hasMoreHistory;
    this.syncAttachments();
    // ⚠️ 放在最后：它可能写 noticeText（「已恢复上次未发送的草稿」），
    // 不能被上面那句 `this.noticeText = this.store.notice` 盖掉。
    this.syncDraftSession();
    // ---- R53：草稿态快照 ----
    // ⚠️ 全部走 store → @State 拷贝：build 只读 @State（见 HomeScreen 顶部那条纪律）。
    this.prepared = this.store.isPrepared();
    this.preparedKind = this.store.preparedKind;
    this.preparedReason = this.store.preparedReason;
    this.preparedDevices = this.store.preparedDevices.slice();
    this.preparedProjects = this.store.preparedProjects.slice();
    this.preparedPresetOptions = this.store.preparedPresetOptions.slice();
    this.preparedPreset = this.store.preparedPreset;
    this.preparedAttachments = this.store.preparedAttachments.slice();
    this.preparedAttachmentsAllowed = this.store.preparedAttachmentsAllowed;
    const preparedDraft = this.store.draft();
    this.preparedConnectorId = preparedDraft !== undefined ? preparedDraft.connectorId : '';
    this.preparedProjectId = preparedDraft !== undefined ? preparedDraft.projectId : '';
    if (this.prepared) {
      // store.session 是一张**本地预览会话**：takeover=true ⇒ readOnly 已经是 false、
      // messageAction 已经是 send、metaLabel 已经是「Agent · 设备 · 工作区」。
      // 只有标题要改 —— 预览会话没有标题，toAgentSession 会兜底成「未命名会话」。
      this.sessionTitle = '新对话';
    }
    // R37 十改：让时间线停在最新消息（首屏无条件到底，之后按 `followTail` 跟随）。
    this.syncTimelineTail();
  }

  /**
   * 附件：先按当前可见消息**发起按需下载**（幂等），再把缓存拷成 @State 快照。
   * ⚠️ 不能在 `build()` 里拉：build 会因滚动/状态变化反复执行，必须在这里做一次。
   */
  private syncAttachments(): void {
    for (let i = 0; i < this.messages.length; i++) {
      const list = this.messages[i].attachments;
      for (let j = 0; j < list.length; j++) {
        const attachment = list[j];
        this.attachments.ensure(
          this.store.sessionId, attachment.fileId, attachment.mediaType, attachment.name);
      }
    }
    const uris: Map<string, string> = new Map<string, string>();
    const names: Map<string, string> = new Map<string, string>();
    const errors: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < this.messages.length; i++) {
      const list = this.messages[i].attachments;
      for (let j = 0; j < list.length; j++) {
        const fileId = list[j].fileId;
        const entry = this.attachments.entryOf(fileId);
        if (entry !== undefined) {
          if (entry.dataUri.length > 0) {
            uris.set(fileId, entry.dataUri);
          }
          names.set(fileId, entry.name);
        }
        const error = this.attachments.errorOf(fileId);
        if (error !== undefined) {
          errors.set(fileId, error);
        }
      }
    }
    this.attachmentUris = uris;
    this.attachmentNames = names;
    this.attachmentErrors = errors;
  }

  build() {
    // 三层结构（用户要求「内容从上方功能栏 / 下方对话框背后穿过」）：
    //  ① 内容层 = **元信息行（真实占位，R72）** + 时间线 + 输入区浮层；
    //  ② 输入区：仍是浮层（`contentEndOffset` 让位）⇒ 正文从**下方对话框背后穿过**（用户明确要的效果）；
    //  ③ 上层 = 提示条 + 错误条 + 运行时面板（只占自身高度，不铺满，所以不挡内容区的点击）。
    // ⚠️ 输入区**不能**和内容层做兄弟排布（改前就是），那样内容永远到不了它背后，
    //  毛玻璃底下只有一块纯色画布 —— 糊不出任何东西，等于没加。
    // ⚠️ **R76：上方也恢复「内容穿过玻璃」了**（用户本轮要求「功能栏与时间栏沉浸，与首页一致」）——
    //  标题栏改 `BarStyle.STACK`（叠在内容上）+ 元信息行改回**浮层**，正文从两处背后滚过。
    // ⚠️ 根 Stack 用 `Alignment.Top`（**水平居中 + 贴顶**）而不是 `TopStart`：
    // 「滑到顶部」那个圆钮要挂在对话顶端并**水平居中**，而它不能靠铺满宽度的容器来居中
    // （那就是用户说的「横条遮罩」）—— 只能靠容器的 `alignContent` 对齐（坑 215：
    // 子节点上的 `.align()` 在本 SDK 不生效）。内容层与顶栏浮层都是 `width('100%')`，不受影响。
    // R65-A（设计规格 §2）：顶栏从正文里**提到 `Navigation` 标题栏**。
    //
    // ⚠️ **R76：改用 `BarStyle.STACK`**（标题栏**叠在内容上**），与**首页逐字同款**。
    //  R65-A 当年用缺省的 `STANDARD`（栏占自己一行、内容被排在栏下方），代价是正文**永远
    //  滚不到标题栏背后** ⇒ 官方材质背后只有纯色画布 ⇒ 糊不出东西（用户说的「没沉浸」）。
    //  ⇒ `STACK` + 列表 `contentStartOffset` 是首页那套（`HomeScreen` 的 `.title(..., {barStyle: STACK})`
    //  + 各列表的 `.contentStartOffset(this.listTopOffsetVp())`），本轮照搬。
    //  ⚠️ 设计规格 §2 那句「让位由框架接管、原来手写的那套不能照搬」**针对的是安全区/滚动让位**，
    //  不是说不能用 `contentStartOffset` —— 那个 API 正是官方为「内容穿过标题栏」提供的让位手段。
    Navigation() {
      Stack({ alignContent: Alignment.Top }) {
        // ## R76：内容层 = **时间线（铺满，含顶部让位）** + 元信息行（浮层，压在时间线之上）
        //
        // ## 为什么把 R72 的结构**反过来**（本轮用户诉求：「功能栏与时间栏沉浸，与首页效果一致」）
        // R72 当时解决的是「元信息行**遮挡**正文」——它把元信息行改成内容层里真实占位的一行，
        // 代价是**正文顶端被永久排在元信息行之下** ⇒ 正文**永远滚不到元信息行背后**
        // ⇒ 元信息行那块玻璃**背后只有纯色画布**，糊不出任何东西（用户说的「没沉浸」就是这个）。
        //
        // 本轮用户的诉求变了：要的是**沉浸**（与首页一致）。首页的做法是
        // `barStyle: STACK` + 列表 `contentStartOffset` —— **让内容滚到栏背后**，材质才有东西可糊。
        // ⇒ 本页照同一套重做，用**官方 API** 解决 R72 那个「遮挡」，而不是靠「让内容缩到下面」：
        //
        // · 时间线 = 内容层里**铺满**的那一节（不再被元信息行挤到下面）；
        // · 元信息行 = **浮层**（本层之后的那个 `Column`），压在时间线之上；
        // · 让位 = 时间线的 `contentStartOffset(titleBarBottomVp() + Space.S)`（官方 API，SDK `list.d.ts:1038-1054`：
        //  「offset from the start of the list content to the boundary of the list display area」）。
        //
        // ⚠️ **R72 观察到的「首条消息被遮」在新结构下不成立**，理由与当年相反：
        //  R72 的实测是「浮层底 393px、首条消息段起点 332px ⇒ 遮 1~1.5 行」。但那个 332px 是
        //  **没有** `contentStartOffset` 时的落点 —— 恰恰证明了**偏移是真起作用的**
        //  （那时视口顶 = 内容区顶 = 0，正文当然从 332 起、当然被压在 393 的浮层下）。
        //  加上 `contentStartOffset(titleBarBottomVp() + Space.S)` 之后，列表视口**顶边**就落在
        //  标题栏下沿 + 8vp（= 357px）⇒ 正文紧贴标题栏开始，中间不再隔着任何浮层。
        //  ⚠️ ~~真机复核判据：contentStartOffset = 417px 时首条消息段顶边应 ≥ 417px~~
        //  **该判据已作废**（R76 起让位量就换成了 `titleBarBottomVp()`，不再是 `headerHeight`）。
        //  ⚠️ **R78 更新**：元信息行搬走后，这条偏移的**目的变了** ——
        //  它不再"给元信息行让位"，只是让正文**从标题栏下沿 + 8vp 起步**（这就是用户要的"缩小距离"）。
        //  正文往下滚时仍会从标题栏底下穿过（那是 R76 起的"沉浸"，未动）。
        // ⚠️ **为什么 R72 当年没走这条路**（记录在案，避免来回翻）：
        //  R72 的诉求是「**任何滚动位置**都不能被盖」。而 `contentStartOffset` 是**起始偏移**、
        //  不是遮挡屏障 —— 用户往下滚时，`scrollOffset` 变大，内容仍会移动到视口顶**之上**、
        //  从浮层底下穿过去。R72 因此判断「沉浸」与「不遮挡」不可兼得，选了后者。
        //  **R76 的本轮诉求明确是「沉浸」** ⇒ 改选前者，并把「遮挡」交给偏移量 + 浮层自身位置控制。
        // ⚠️ 这不是坑 217 说的那种「用容器 `padding` 让位」：`List` 的让位走的是**官方
        //  `contentStartOffset`**（不是给它加 padding），元信息行是浮层、不占内容层的位。
        // 内容层：**只有时间线 + 输入区**（元信息行已移到下面那层浮层）。
        // 内层 Stack 负责把输入区钉在底部；Stack 只有一个 alignContent，上下两种对齐只能靠嵌套表达
        // —— 子节点上的 `.align()` 在本 SDK **不生效**（坑 215，R24 实测按钮落进容器正中）。
        Column() {
          Stack({ alignContent: Alignment.Bottom }) {
            this.timelineArea()
            // R50：**阻塞公告钉在输入区上方**（上游 `BlockingRuntimeNoticeStack`，`SessionDetailScreen.kt:1657`）。
            // ⚠️ 这是「Agent 提问时手机没弹窗」的真正修法：原先公告只是时间线的第一项，
            // 而时间线默认停在最新消息 ⇒ 提问卡在屏幕外。声明在 `composer()` **之后** ⇒ 压在输入区上方。
            if (this.blockingNoticeList.length > 0) {
              this.noticeStack()
            }
            this.composer()
            // 「滑到底部」：**悬浮在输入区之上**（不是放进输入区里面）。
            //
            // ⚠️ R37 三改（用户反馈「底部滑动按钮仍有横条遮罩」）：二改时这个钮放在输入区
            // `Column` 里 —— 而那个 `Column` 整条挂着毛玻璃（需求 1 要的「下方对话框加模糊」），
            // 于是钮被**包在那条玻璃横条里**，看起来就是「横条上长了一个按钮」。
            // 现在移出输入区：贴底 + 一个实测出来的偏移量 ⇒ 它悬在输入区**上方**，
            // 背后是滚动的正文（由它自己那 38vp 的玻璃底糊化），周围没有任何横条。
            //
            // ## R92 一改（用户：「将上下滑动的滑块分别设在标题栏下边缘和**对话框上边缘**，
            //  且『深度求索中』信息出来时，下方滑块**不需要向上避让**」）
            // 改前是 `margin.bottom = this.composerHeight + Space.S`，而 `composerHeight` 量的是
            // 「输入区 + 底部带」**整条** —— 里面**含**忙碌行与指令面板 ⇒ 状态行一出现，整条变高，
            // 圆钮就被顶上去（真机 dump 可复现：圆钮 y 随「深度求索中…」出现而改变）。
            // ⇒ 改成 `composerGlassBlockHeightVp()`：它 = 卡片高 + 元信息行高 + 手势条避让，
            //  **量的是「卡片上沿 → 屏幕底」**，一个不随 busy 行/指令面板变化的量
            //  （推导见那个函数；判据：busy 行出现/消失时本钮 y 坐标逐像素不变）。
            // ⚠️ 用户这两条是**一个坐标系里的两件事**：上圆钮钉「标题栏下沿」，
            //  下圆钮钉「卡片上沿」，两者都由这条 `Stack` 的边界定义（顶 = 标题栏槽底、底 = 屏幕底）。
            if (this.showScrollButtons) {
              Column() {
                this.scrollButton(ICONS['arrow-down'], '滑到底部', () => {
                  this.timelineScroller.scrollEdge(Edge.Bottom);
                })
              }
              // 宽度由子节点撑开（38vp），**不铺满** ⇒ 只吃自己那一小块命中区。
              .margin({ bottom: this.composerGlassBlockHeightVp() })
            }
          }
          .width('100%')
          .layoutWeight(1)
          // ⚠️ **R76：这里没有 `margin.top`，也没有 `this.headerMeta()`**。
          //  改前（R72）这里是 two 段：元信息行真实占位 + `margin.top: Space.S`，把时间线挤到
          //  元信息行**下方** —— 那样正文永远滚不到元信息行背后，玻璃没东西可糊（就是「没沉浸」）。
          //  现在顶部让位改由**时间线自己的** `contentStartOffset` 承担（见 `timeline()`），
          //  本层铺满内容区，正文可以滚到元信息行背后。
        }
        .width('100%')
        .height('100%')

        // ## R78：**元信息行那一层已经删掉**（R76/R77 它挂在这里守「时间栏沉浸」）
        // 用户本轮要求「把标题栏下方的小字内容**都转移**到对话框下方」⇒ 它搬进了
        // `composer()` 那个 Column 里（输入卡下面），本层不再存在。
        // ⚠️ 连带效果：标题栏下沿到时间线正文之间**不再隔着 84px 的元信息带** ——
        //  「标题栏距时间栏过远」这条自动消失（正文起点仍由 `contentStartOffset` 定在栏下沿 +8vp）。
        // ⚠️ 那段「为什么它要单独一层」的 R76 记录**不要删**（它是真实踩过的坑：给
        //  `height 100%` 的铺满容器加 `margin.top` 会被按溢出处理、实测偏 138px）——
        //  现在没有容器需要那个让位量了，但下次谁要往这条 Stack 里加浮层还得知道。

        // ## R76：**提示条 / 错误条 / 草稿提示 / 两个内联面板**（临时层，压在时间线之上）。
        // ⚠️ **R78：让位量改成「标题栏下沿 + Space.S」**（原来是 `+ this.headerHeight`，
        //  因为那时元信息行还挂在标题栏正下方）。现在那行搬到输入卡下面去了 ⇒
        //  提示条应该紧贴标题栏，不能再往下多让一个元信息行的高度（实测 84px）。
        // ⚠️ 本层是**铺满型兄弟容器**（`width/height 100%`）⇒ 必须 `hitTestBehavior(HitTestMode.None)`，
        //  否则它会把整屏手势（列表拖拽 / 输入区点击）全吃掉（坑 29 真机踩过）。
        Column() {
        // 复制 / 分享的轻提示 —— 位置与卡片数值按上游实现 的 Toast 规范：
        // **顶部居中**、最大宽 340dp、圆角 18dp、阴影 14dp(0x22000000)、水平 18 / 垂直 12、正文 15sp。
        // ⚠️ 差异：上游 `AAToast` 是 1600ms 自动消失 + 成功图标；本工程没有统一 Toast 组件，
        // 用一个**常驻可手关**的提示条承担 —— 常驻是为了让 dumpLayout 能稳定抓到它（验证判据）。
        if (this.actionHint.length > 0) {
          Row() {
            Text(this.actionHint)
              .fontSize(15)
              .lineHeight(19)
              .fontWeight(FontWeight.Medium)
              .fontColor(ink())
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 上游 `AAToast` 的关闭图标（本工程是常驻可手关的提示条）
            Row() {
              AaIcon({ d: ICONS['x'], iconSize: FontSize.TITLE, color: muted() })
            }
            .padding({ left: Space.S, right: Space.S })
              .onClick(() => {
                this.actionHint = '';
              })
          }
          .constraintSize({ maxWidth: 340 })
          .padding({ left: Space.PAGE, right: Space.PAGE, top: Space.M, bottom: Space.M })
          .borderRadius(Radius.XL)
          .backgroundColor(raisedSurface())
          .borderWidth(1)
          .borderColor(borderColor())
          // 阴影的扩散半径走 Shadow 令牌（**不是圆角**，见 Design.ets 里 Shadow 组的注释）
          // ⚠️ R57 Lead 裁决：**保留**这里的字面量 `#22000000`，不改 `appShadow()`。
          // 原因：`app_shadow` 深色档是 `#52000000`（32% 黑），换过去会让深色下这条提示条的阴影
          // 从 13% 跳到 32% —— 那是所有深色浮层的统一档，对「一条细提示条」过重。本工程这三处
          // 阴影本来就是**逐控件调过**的，不是漏写令牌（用户本轮也只要图标/玻璃，不含阴影重定档）。
          .shadow({ radius: Shadow.TOAST, color: '#22000000' })
          .margin({ left: Space.PAGE, right: Space.PAGE, top: Space.S })
        }
        AaErrorBanner({
          message: this.errorText,
          onDismiss: () => {
            this.store.error = '';
            this.errorText = '';
          }
        })
        if (this.noticeText.length > 0 || shouldShowRestoredNotice(this.draft, this.draftRestoreSnapshot)) {
          Row() {
            // 草稿恢复提示优先显示：它可以被 dumpLayout 直接读到，是「恢复逻辑真的从持久化后端
            // 读到了东西」的稳定锚点（验证判据）。显示条件纯由 @State 推导 ——
            // 页面里没有任何一处把它置空，所以不会被「程序回填 text 触发的 onChange」误清。
            Text(shouldShowRestoredNotice(this.draft, this.draftRestoreSnapshot)
              ? '已恢复这个会话上次没发出去的草稿。'
              : this.noticeText)
              .fontSize(FontSize.CAPTION)
              .fontColor($r('app.color.session_status_accent_text'))
          }
          .width('100%')
          .padding({ left: Space.M, right: Space.M, bottom: Space.XS })
        }
        // 运行时设置：**页面内联区块**（原来是 bindSheet，根因见 runtimePanel 的注释）。
        // 内联之后它就是一个普通节点 —— dumpLayout 必然可见、必然可点，
        // 不再受「同一节点挂多个 bindSheet 互相覆盖」这种未定义行为摆布。
        if (this.showRuntimeSheet) {
          this.runtimePanel()
        }
        // R53：草稿态的「选择工作区」（与运行时设置同为**页面内联区块**，
        // 根节点上只挂得下一个 bindSheet —— 那个名额归附件大图）。
        if (this.workspacePanelOpen) {
          this.preparedWorkspacePanel()
        }
        }
        .width('100%')
        // R78：紧贴标题栏下沿（元信息行已搬走，不再叠加它的高度）。
        .margin({ top: this.titleBarBottomVp() + Space.S })
        .hitTestBehavior(HitTestMode.None)

        // 「滑到顶部」：挂在**对话顶端**（顶栏之下）、水平居中、只在滚动时出现。
        // 声明在顶栏浮层**之后** ⇒ 位于最上层，不会被顶栏的毛玻璃盖住。
        if (this.showScrollButtons) {
          Column() {
            this.scrollButton(ICONS['arrow-up'], '滑到顶部', () => {
              this.timelineScroller.scrollEdge(Edge.Top);
            })
          }
          // 宽度由子节点撑开（38vp），**不铺满** ⇒ 只吃自己那一小块命中区。
          // ## R92 一改（用户：「将上下滑动的滑块分别设在**标题栏下边缘**和对话框上边缘」）
          // 改前是 `titleBarBottomVp() + Space.S` —— 与时间线的 `contentStartOffset` 同源同值，
          // 好处是「圆钮正好落在时间线视口顶那一行」，代价是它**离标题栏还差一个 Space.S(8vp)**。
          // 用户本轮明确要「设在标题栏**下边缘**」⇒ 把那个 8vp 去掉，圆钮**贴住**栏的下沿。
          // · 锚点仍是 `titleBarBottomVp()`（**不新造量**）⇒ 与时间线起始偏移同源，
          //  标题栏几何一变（`TITLE_BAR_VP` / 安全区）两边一起走，不会错位；
          // · ⚠️ 不会钻到标题栏底下：`BarStyle.STACK` 下标题槽恒为 `[0, 137][1316, 332]`，
          //  而 `Space.S`(8vp) ≈ 24px 的余量本身就是「圆形玻璃钮外圈 4vp + 阴影」的呼吸区
          //  —— 去掉它后钮顶边正好落在栏的下沿上（真机复核判据见 R92 报告）。
          // · 层级（未动）：本 `Column` 声明在提示条/错误条浮层**之后** ⇒ 位于最上层，
          //  不会被任何浮层的玻璃盖住。
          .margin({ top: this.titleBarBottomVp() })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(canvas())
      // ⚠️ 这个根节点上**只能挂一个** `bindSheet`：ArkUI 的属性方法是「后写覆盖先写」，
      // 同一节点挂两个时只有最后那个能生效 —— R8 冒烟 D2 就是这么来的
      // （「⚙ 运行时设置」被后声明的「附件大图」覆盖：点了只发请求、界面毫无反应，
      //  dumpLayout 里连「运行时设置」文本都找不到）。
      // 运行时设置已改成页面内联区块（见 build 里的 `runtimePanel()`），这里只剩大图查看器。
      .bindSheet($$this.viewerOpen, this.attachmentViewer(), {
        height: '80%',
        dragBar: true,
        // R37 六改：系统关闭按钮真机实测**点不动**（见 DeviceDetailScreen 的注释）⇒ 统一关掉。
        // 面板另有「下滑关闭 / 点面板外关闭」两个入口。
        showClose: false,
        // ## R86：大图查看器半模态的**底**改由官方沉浸光感接管（本行是这处唯一变化，几何一字未动）
        // · 官方依据：`SheetOptions.systemMaterial`（SDK `common.d.ts:12155`）。
        // · 生效范围：`bindSheet` 属**弹窗类接口** ⇒ 依官方「生效范围」在**页面内全部区域**生效
        // （`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）；
        //  本页正文那几块玻璃面板（composer / commandPanel / runtimePanel / scrollButton）**不在**本条内。
        // · 档位 `panelMaterial()`（THIN）：面板背后是会话时间线的大图，取薄档保可读性。
        // · 关闭姿势 = `uiMaterial.Material.empty`（= disable，SDK `uiMaterial.d.ts:467-472`），由
        //  `panelMaterial()` 在探针不可用时自己返回；**不得**改传 `undefined`（官方语义 =
        //  「恢复组件默认材质」，`common.d.ts:22632-22633` / `坑 256`）。
        // · 保留 `blurStyle`：官方只不建议材质与底色/描边/描边宽/投影同用（`common.d.ts:22625-22630`），
        //  未禁止模糊；它也是材质不可用时本面板唯一的底。回退 = 删掉下面这一行。
        systemMaterial: panelMaterial(),
        blurStyle: BlurStyle.Thin,
        onDisappear: () => {
          this.viewerOpen = false;
        }
      })
    }
    // ## R76：**标题栏与首页逐字同一套**（用户诉求「用官方材质重写，功能栏与时间栏沉浸，与首页效果一致」）
    //
    // ## 演进
    // · R75：撤掉本页的自绘白胶囊 / 自绘 44vp 玻璃钮，几何对齐到其它 8 页（64vp 行 / 40vp 钮 / 裸标题）；
    // · **R76（本轮）**：把 `.title(...)` 的 options 也拉成**与首页完全同款**，并让标题栏**叠在内容上**
    //  （`BarStyle.STACK`）⇒ **正文滚到标题栏背后时被官方材质糊化**，这才是用户看到的「首页效果」。
    //
    // ## 三项与首页逐字对齐（`HomeScreen.ets` 的 `.title(this.homeTitleBar(), {...})`）
    // | 项 | 首页 | 本页 R76 |
    // | --- | --- | --- |
    // | `barStyle` | `BarStyle.STACK` | 同左（R75 曾是 `STANDARD` ⇒ 内容被排在栏下方，**永远滚不到栏背后**） |
    // | `backgroundColor` | `Color.Transparent` | 同左（不透明底会把材质那层整个盖住） |
    // | `scrollEffectOptions` | `{ scrollEffectType: ScrollEffectType.GRADUAL_BLUR }` | ⚠️ **R77 有意撤销**（见下） |
    // ⇒ `barStyle` 这一条是「效果一致」的**结构性前提**：`STANDARD` 下标题栏**不叠在内容上**，
    //  正文顶端永远被排在栏下方，材质背后是纯色画布 ⇒ **糊不出任何东西**（等于没加）。
    //
    // ## R77（用户：「**标题栏和时间栏有明显分界**……**只让按钮具备光效**，**标题栏用官方组件模糊**，
    //  且**和时间栏保持沉浸**」）
    //
    // ### 1 · 分界的来源已实测定位
    // R75/R76 在 `navTitleBar()` 那行末尾挂了 `.systemMaterial(officialBarMaterial(...))`。
    // 真机截图（1316px 宽）在**没有按钮/文字的空白列**扫竖直剖面，那层材质画出来的是
    // **一条带硬边的圆角带**：`y=167` 一条 255 的**顶缘高光**、`y=356` 一条 254 的**底缘高光**，
    // 带内 ~238、带外 243 —— 用户说的「明显分界」就是这两条缘。
    // ⇒ **删除那层材质**（`officialBarMaterial` 的 import 也一并撤掉）。
    //
    // ### 2 · 但只删材质会出更大的问题：静止时**完全不模糊**（已实测）
    // 只留 `scrollEffectOptions` 的效果是：**滚动事件没发生过 ⇒ 栏就是全透明**。
    // 本页与首页不同 —— 首页列表停在顶部、栏背后本来就没内容；本页进页面就 `scrollEdge(Edge.Bottom)`，
    // **栏背后一直有正文**。R77 首版真机截图：正文「在 Navigation 标题栏上根本不成立……」**清晰地**
    // 压在会话标题上，标题读不出来，元信息行同样被正文压住。
    //
    // ### 3 · 修法：栏的模糊改由**官方组件自己的属性**常开供给
    // `NavigationTitleOptions.backgroundEffect`（SDK `navigation.d.ts:1745-1758`，API 19 起；
    // 同族还有 `backgroundBlurStyle`/`backgroundBlurStyleOptions` `1719-1744`）——
    // 官方文档原话：「Title bar background properties, including **blur radius, brightness,
    // saturation, and color**」⇒ **正是用户要的「标题栏用官方组件模糊」**。
    // · 它由**框架自己**画在那条带上（不是我们挂一个节点）⇒ **没有缘高光、没有分界**；
    // · 它是**常开**的（不像 `scrollEffectOptions` 要等滚动）⇒ 静止时标题也读得出来；
    // · 参数取**本工程同一套玻璃令牌**（`GLASS_BLUR_RADIUS` / `GLASS_SATURATION` /
    //  `GLASS_BRIGHTNESS` / `glassSurface()`），与元信息行**逐字同值** ⇒ 两段糊化观感一致、
    //  接缝消失（这就是「和时间栏保持沉浸」）。
    // ⚠️ 官方文档要求 `backgroundEffect` **不要**与 `backgroundBlurStyleOptions` 同时用 —— 本页只用前者。
    // ⚠️ `scrollEffectOptions` **保留**（与首页逐字同款，滚动时叠一层渐变）：它与 `backgroundEffect`
    //  是**不同维度**（前者是滚动驱动的遮罩渐变，后者是常驻背景模糊），不冲突。
    // ⚠️ **光效仍然只在按钮上**：本页只有两枚 `AaCircleIconButton({ officialMaterial: true })`
    //  带官方沉浸光感；栏本体与元信息行都**只是模糊，没有光效**。
    .title(this.navTitleBar(), {
      barStyle: BarStyle.STACK,
      backgroundColor: Color.Transparent,
      backgroundEffect: {
        radius: GLASS_BLUR_RADIUS,
        saturation: GLASS_SATURATION,
        brightness: GLASS_BRIGHTNESS,
        color: glassSurface()
      },
      // ## R77：**删掉 `scrollEffectOptions`** —— 它与常驻 `backgroundEffect` 重复，而且真机实测有害
      //
      // 真机实测（同一页面、同一滚动位置，只差这一条）：
      // · **留着它**：框架会生成一层 `TitleBarMaskBlur [0,137][1316,428]`（底边 428px **越过**了
      //  元信息行底 416px）⇒ 滚动一层上去后，元信息行那行字被**糊成半透明**
      //  （放大对照 `R77-metarow-zoom.png`：静止时清晰可读，滚动后明显发虚）；
      // · **删掉它**：官方常驻 `backgroundEffect` 已经把"正文滚到栏背后被糊化"这件事做完了
      //  ⇒ 沉浸一点没少，而元信息行的字不再被洗掉。
      //
      // ⚠️ 也就是说：**「与首页逐字同款」这条在 R77 被有意放弃**（R76 曾照抄首页那条 `scrollEffectOptions`）。
      //  原因：首页的列表停在顶部、栏背后本来就没内容，滚动遮罩只负责"滚起来才糊"；
      //  而**本页进页面就 `scrollEdge(Edge.Bottom)`、栏背后一直有正文**，本就需要常驻模糊，
      //  再叠一层滚动遮罩只会把那层遮罩范围内的东西（含元信息行）一起洗淡。
      //  ⇒ 两条路只能选一条，R77 选**常驻**。
      // ⚠️ `ScrollEffectType` 因此在本页不再被引用；若日后要恢复，把下面这行加回来即可：
      //  `scrollEffectOptions: { scrollEffectType: ScrollEffectType.GRADUAL_BLUR }`
    })
    .mode(NavigationMode.Stack)
    // ## R75 真机复核（**Mini 已被本轮的干净实验再次证伪 ⇒ 回到 Full**）
    //
    // ⚠️ 本轮我先试了 `Mini`（理由：「官方标准标题栏 56vp，本页已无自绘栏，不必占 Full 的 112vp」），
    //  并在真机 R75 上实测 —— **结论：Mini 不可用**，R66-2 当年的观察**是对的**，
    //  我中途写下的「R66-2 结论做废」那条判断**已被这次实测推翻**（一并记在这里，防止再翻案）。
    //
    // ## 真机 dump 对照（同一台机、同一个页面、除 titleMode 外一切相同）
    // | 档 | 框架给的 `TitleBar` bounds | 状态栏之下**可用**的高度 |
    // | --- | --- | --- |
    // | **Full**（R74 与 R75 回退后） | `[0,137][1316,332]` | **195px = 65.5vp** ✅ |
    // | **Mini**（R75 首版） | `[0,137][1316,166]` | **29px = 9.7vp** ❌ |
    // 关键在**两档都从窗口顶 y=0 起算**，而不是从状态栏底 y=137 起算：
    // · Full：112vp × 2.975 = **333px** ≈ 332 ⇒ 总高 0..332，扣掉状态栏 137 ⇒ 剩 195px；
    // · Mini：56vp × 2.975 = **167px** ≈ 166 ⇒ 总高 0..166，扣掉状态栏 137 ⇒ **只剩 29px**。
    // Mini 实测截图（开发期验证记录）：栏里那枚 40vp 钮**直接压在
    // 状态栏的时钟上**（构造器被钳到 29px 后溢出）。**任何自绘栏/无自绘栏都救不了它** ——
    // 病根是「`Mini` 的 56vp 从 y=0 起算」，与构造器里放了什么**无关**（本轮构造器里已经
    // 只剩两枚 40vp 钮、零自绘层，仍被钳）⇒ 这正好是**干净的单变量实验**。
    // ⇒ **Full 是本页唯一可用档**（SDK 常量与真机一致；Free 会随滚动改标题位置，见 R66-2）。
    // ⚠️ 副作用（可接受）：Full 的 112vp 槽比官方「标准」标题栏高，两枚 40vp 钮居中后
    //  上下各留 ~12vp；本工程其余 8 页用同一个槽，所以**这才是「视觉统一」**。
    .titleMode(NavigationTitleMode.Full)
    .hideToolBar(true)
    .width('100%')
    .height('100%')
  }

  // -------------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------------

  /**
   * **R75：本页标题栏构造器** —— `Navigation.title(...)` 的自定义构造器，内容**只剩左右两枚功能钮**。
   *
   * ## 演进（R65-A → R75）
   * · R65-A：首行（⚙ + 自绘胶囊标题 + 🗀）走 `.title(...)`；
   * · **R75（用户诉求「改为官方标题栏样式，取消自绘部分，确保视觉统一」）**：自绘胶囊标题**整段删除**，
   *  标题交给**官方 `Navigation` 标题**（`.title(...)` 的第一参数仍是本构造器，标题由框架按
   *  「start | 标题 | end」三槽排布 —— 本工程此时没有传 `ResourceStr` 标题，见下面「已知代价」）。
   *
   * ⚠️ **本构造器里不许再出现任何铺满型自绘容器**（栏底/描边/胶囊/阴影）：
   *  · 栏目**不挂材质**（R77 删除；模糊改由框架标题栏的 `scrollEffectOptions` 供给）；
   *  · 行高 = `Control.TOP_BAR_PAGE`(64) + 水平 `Space.PAGE` —— **与其余 8 页逐字同值**
   *  （不要写回本页原来的 58：那是自绘形态③的高度，本页已并入统一顶栏）。
   *
   * ⚠️ 生效范围（官方沉浸光感自 HarmonyOS 7 起，仅对 `targetSdkVersion >= 26.0.0` 生效）：
   * 两枚钮在 `Navigation` 标题栏里 ⇒ 命中官方允许的位置；**页面正文里静默无效**
   * （`坑 245`）。
   *
   * ⚠️ 标题是**与其余 8 页同款的裸 `Text`**（`FontSize.TITLE` / Medium / 居中 / 左右 `Space.M`），
   * 不是自绘胶囊，也不是框架的 `NavigationCommonTitle` —— 三者取「与全工程统一」这一支。
   */
  @Builder
  navTitleBar() {
    // ## R75（用户真机截图：「将图中部分改为官方标题栏样式，取消自绘部分，确保视觉统一」）
    //
    // 本页原来**整条自绘**：58vp 行 + 两枚**自绘液态玻璃**圆钮（光弧/亮边/按压层）+ 一枚
    // 222×42vp **自绘白胶囊**（`systemMaterial` 只是挂在胶囊上，胶囊本身还有 42vp 高、圆角、内边距）。
    // 真机截图（R74，1316px 宽）逐像素实测出三处与官方栏不一致：
    //  · **胶囊比官方标题突出**：胶囊实测高 **42vp（140px，y=164..304）**，而官方标题字形顶/底在
    //  **59.9..94.5vp** —— 胶囊上下各多伸出 12.5vp / 10.5vp，看起来是「白色药丸」而不是标题；
    //  · **两枚自绘钮比官方栏内控件大**：直径 44vp（132px），官方栏内控件几何是 **40vp**；
    //  且自绘盘的亮环+投影在栏上画出两片明显光晕（截图 x≈0..430 / 1030..1316 的低频起伏）。
    //  ⇒ 本轮按用户要求**取消自绘**，改成官方标题栏样式（官方几何）：
    //  · 栏本体 = **零材质、零自绘底/边**（R77）；模糊由框架标题栏的 `scrollEffectOptions` 供给，
    //  · 行高/边距 = **与其余 8 页逐字同值**（`Control.TOP_BAR_PAGE` 64vp + `Space.PAGE`），
    //  不再是本页专属的 58vp / 18vp；
    //  · 左右功能钮 = 与其余 8 页**同一套**（`AaCircleIconButton` 玻璃档 / 官方材质），
    //  直径由本页专属的 44 收到官方的 `Control.NAV_BUTTON_LARGE`(40)。
    // ⚠️ 与首页/设备页/文件页等的口径**就此统一**：官方标题栏材质 + 40vp 玻璃钮 + `BarStyle.STANDARD`。
    // ⚠️ `titleMode` 保持 **Full**（`Mini` 已在本轮真机实测中**证伪**，见 `build()` 里 titleMode 那段表）。
    // ⚠️ 系统返回仍可用（返回手势 / 返回键），不依赖栏内按钮（R37 七改的既定口径）。
    // ⚠️ R37 七改（用户要求「将后退按钮取消，设置按钮移到返回按钮位置」）**继续有效**：
    // 左 = ⚙（运行时设置）、右 = 🗀（会话文件）。返回仍可用：**系统返回键 / 返回手势**
    // 走自研路由栈（`Router.back()`），不依赖栏内按钮。
    // ⚠️ R75 起两枚钮之间是**裸标题 Text**（与其余 8 页同款），那枚自绘白胶囊已删。
    Row({ space: Space.M }) {
      // ⚙ 运行时设置 —— R75 起与其余 8 页顶栏**同一套**控件：`AaCircleIconButton` 的玻璃档
      // （内部委托 `ui/GlassIcon.ets#officialGlass()` 的**官方材质 only** 分支 ⇒ 零自绘层）。
      // 直径由本页原来专属的 44 收到官方栏内控件档 `Control.NAV_BUTTON_LARGE`(40) ——
      // 与首页/设备页/文件页/终端页/设置页… 逐字同值。
      AaCircleIconButton({
        name: 'settings',
        diameter: Control.NAV_BUTTON_LARGE,
        // 图标 21：与 `SettingsScreen` / `DevicesScreen` / `FilesScreen` 的返回钮同档（原是本页的 18）。
        iconSize: 21,
        glass: true,
        tint: this.showRuntimeSheet ? $r('app.color.primary_action') : ink(),
        // R65-A：本顶栏已在 `Navigation` 标题栏内 ⇒ 落在官方沉浸光感的生效范围内（`坑 245`），
        // 本钮改走官方 `ImmersiveMaterial`（官方分支零自绘层：无 backgroundEffect / 渐变 / 描边）。
        officialMaterial: true,
        accessibilityLabel: '运行时设置',
        onTap: () => {
          // 再点一次收起（面板现在是页面内联区块，不占系统弹层）
          this.showRuntimeSheet = !this.showRuntimeSheet;
          if (!this.showRuntimeSheet) {
            return;
          }
          // 大图查看器是页面唯一的系统弹层，展开面板前先关掉它，免得两层叠在一起
          this.viewerOpen = false;
          // 草稿态的目录是**连接器级**端点拉的（store.beginPrepared 里已装好），
          // 这里再调会话级目录会拿一个不存在的 sessionId 去打接口。
          if (!this.prepared) {
            this.reloadRuntimeCatalogs();
          }
          // 面板是「固定高度 + 内部滚动」：上一次若停在标题之外的位置，展开后首项会被裁掉一半
          // （真机基线 baseline-02-home.jpeg 就是这个现象）。展开后把内层视口显式归零。
          setTimeout(() => {
            try {
              this.runtimeScroller.scrollEdge(Edge.Top);
            } catch (error) {
              // 归位失败不影响功能：面板仍可用，只是可能停在旧位置
            }
          }, 0);
        }
      })

      // ⚠️ **R75：自绘白胶囊整段删除**（那枚 42vp 高的圆角白药丸 —— 用户截图里最刺眼的自绘件）。
      //  逐像素实测：胶囊高 42vp（140px，y=164..304），而官方标题字形只占 59.9..94.5vp ⇒
      //  上下各多伸出 12.5vp / 10.5vp，视觉上就是「标题栏里嵌了一颗药丸」。
      //  ⇒ 改成**与其余 8 页完全同款**的裸标题 `Text`：字号 `FontSize.TITLE`(17) / Medium /
      //  `layoutWeight(1)` / **零底、零描边、零圆角、零材质**。这就是「官方标题栏样式」。
      Text(this.sessionTitle)
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
        .layoutWeight(1)
        .padding({ left: Space.M, right: Space.M })
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 与 `SettingsScreen` / `DevicesScreen` / `ArchivedSessionsScreen` 的裸标题**逐字同款**：
        // 居中 + 左右 `Space.M`。零底 / 零描边 / 零圆角 / 零材质 —— 这就是「取消自绘」的落点。

      // 会话工作区文件：以本会话的 cwd 为根打开，省得从设备详情再找一遍目录。
      // R75：同左 —— 与其余页面顶栏功能钮**同一套**控件与几何（40vp 玻璃盘 / 官方材质）。
      AaCircleIconButton({
        name: 'folder',
        diameter: Control.NAV_BUTTON_LARGE,
        iconSize: FontSize.ICON_MD,
        glass: true,
        tint: this.sessionCwd.length > 0 ? ink() : muted(),
        // R65-A：同左（本顶栏已在 `Navigation` 标题栏内）。
        officialMaterial: true,
        accessibilityLabel: '浏览会话文件',
        onTap: () => {
          if (this.sessionCwd.length === 0) {
            this.noticeText = '这个会话没有工作目录信息，无法浏览文件。';
            this.pull();
            return;
          }
          Router.push(Route.FILES, `${this.sessionConnectorId}|${this.sessionCwd}|.`);
        }
      })
    }
    .width('100%')
    // ## R80（用户：「**标题栏距时间栏较远**，修复一下」）：行高 TOP_BAR_PAGE(64) → HOME_HEADER(46)
    //
    // 真机实测（三份 dump 对照，见 开发期验证记录）：Navigation 的 Full 槽是
    // TitleBar [0,137][1316,332]，而框架把构造器的**顶边锚在 y=166**（= 状态栏底 137 + 29，
    // 29 是框架按「标准栏 46vp」在 195px 槽里居中算出的余量）—— 顶边**与行高无关**，
    // 行高只决定行内控件落在哪：**控件中心 y = 166 + 行高 ÷ 2**。
    //
    // | 页 | 行高 | 构造器实测 bounds | 40vp 钮 / 标题中心 |
    // | --- | --- | --- | --- |
    // | 首页 header() | HOME_HEADER(46) | [0,166][1316,303] | **235** |
    // | 本页 R75..R79 | TOP_BAR_PAGE(64) | [0,166][1316,332]（190px 的行被 195px 槽裁到 166） | **262** |
    // ⇒ 同一条栏，本页的标题与两枚钮比**首页低 27px（9vp）**，观感就是「标题栏离状态栏（时间栏）更远」。
    //
    // ⇒ 收到 46：与 R76 起本页的既定口径「**与首页效果一致**」对齐（首页才是本页的参照物）。
    // ⚠️ 本轮**只动行高**：左右内边距仍是 Space.PAGE、两枚钮仍是 NAV_BUTTON_LARGE(40) 的官方材质档。
    // ⚠️ R81 起改用 `Control.NAV_TITLE_ROW`（与 `HOME_HEADER` **同值 46**，语义是「Navigation 标题栏那一行」）；
    //  其余 7 页同一轮跟进 —— 「标题栏口径」现在**全工程只有一个值**（`design.NAV_TITLE_ROW`），
    //  断在 `suite-design`（同值断言）+ `suite-topbar`（9 个页面都必须用它）两处。
    .height(Control.NAV_TITLE_ROW)
    .padding({ left: Space.PAGE, right: Space.PAGE })
    .justifyContent(FlexAlign.SpaceBetween)
    // ## R77（用户：「**标题栏和时间栏有明显分界**……改为**只让按钮具备光效**，
    //  **标题栏用官方组件模糊，且和时间栏保持沉浸**」）
    //
    // ⛔ **本行不再挂任何材质**（R75/R76 那版 `.systemMaterial(officialBarMaterial(glassSurface()))` 已删）。
    //
    // ## 为什么删：真机逐像素量出了那道「分界」
    // 用户截图（1316px 宽）在**没有按钮 / 文字的空白列**上扫竖直剖面，本行材质画出来的是
    // **一条带硬边的圆角带**：
    // ```
    //  y=167 ← 一条 255 的**亮边**（材质的顶缘高光）
    //  y=170..350 带内 ~228..238（比页面底色 243 更暗 ⇒ 一片可见的灰带）
    //  y=356 ← 又一条 254 的**亮边**（材质的底缘高光） ← 用户说的「明显分界」就是它
    //  y=359..431 元信息行区 ~216..248（另一套观感 ⇒ 上下两块明显不是一体）
    // ```
    // ⇒ 那条带 = **我们自己画的一层材质**，它的两条缘高光把「标题栏 / 时间栏」切成了两块。
    //
    // ## 改法（照用户原话逐条落）
    // · **只让按钮具备光效**：两枚钮仍走 `officialMaterial: true`（官方沉浸光感的圆盘），
    //  本行**不再**有第二层光效；
    // · **标题栏用官方组件模糊**：改由 **`NavigationTitleOptions.backgroundEffect`**（框架属性，
    //  常驻模糊）供给 —— 见 `build()` 里 `.title(...)` 那段，本行只负责放控件；
    // · **和时间栏保持沉浸**：本行与元信息行都**不挂材质**，两段模糊的参数**逐字同值**
    //  ⇒ 一片连续的糊化、没有接缝。
    //
    // ⚠️ **不要**把材质加回来「让它看起来更像玻璃」：那会重新画出上下两道缘高光 = 分界复现
    // （通用条目：`坑 250`）。
    // ⚠️ **也不要**只删材质就收工：真机实测那样会让整条栏**静止时完全透明**
    //  （`scrollEffectOptions` 要等滚动事件才生效），失败态见
    //  开发期验证记录。
  }

  /**
   * **元信息行** —— 运行时 · 设备 · 工作区 + 会话状态 + WS 连接态（+ 可选状态原因行）。
   *
   * ## 它搬了 5 次家（R65-A → R72 → R76/R77 → R78 → R79）
   * | 轮次 | 本行位置 | 底 | 备注 |
   * | --- | --- | --- | --- |
   * | R65-A | 标题栏下的浮层 | 自绘毛玻璃 | 能滚到它背后 |
   * | R72 | 内容层里**真实占位**的第 1 行 | 自绘毛玻璃 | 不能穿过 ⇒「没沉浸」 |
   * | R76/R77 | 标题栏下的独立浮层 | 官方材质 → 官方同参模糊 | 与标题栏同参 |
   * | R78 | 输入卡**下方**的独立小条 | 与输入卡同参 | 标题栏下沿腾空 |
   * | **R79** | 卡下方，**由一条全宽底部带承载** | **底部带给**（带子与卡片同令牌） | 见下 |
   *
   * ⚠️ **R79 用户口径**：「**对话框和没改前位置一样**，只把文字移到底部，
   *  再在底部加上**和对话框一样的模糊**，**覆盖到整个底部区域**」。
   *  ⇒ 卡片**一个字没动**；本行下移到**屏幕最底**；模糊由 `composer()` 里那条
   *  **全宽、无圆角、一路铺到屏幕底**的带子给（与卡片同一套令牌）。
   * ⚠️ R79 中途试过「**把本行并进卡片**当成一个整体」，被用户否决（会让卡片变高、位置上移）。
   *  **不要再并进去**。
   *
   * ⚠️ **R72 ↔ R76 那个两难在 R78 之后就自然消解了**：当年争的是「正文能不能滚到它背后」，
   *  现在它在**屏幕最底**、和输入卡一起浮在时间线之上 ⇒ 正文本来就从它背后穿过（R37 起的设计）。
   *
   * ⚠️ **本 `@Builder` 现在只画字**：底 / 模糊 / 圆角 / 描边**全部**由外面那条带子给
   *  （用户「不要加外框」）。它自己的上下内边距是 **0** ⇒ 小字紧贴卡片下沿。
   * ⚠️ **R78：本 `@Builder` 不再挂 `onAreaChange`** —— 它原来把实测高度写给 `headerHeight`，
   *  而那个值 R78 已随「消费者搬走」整条删除。本行的高度现在由 `composer()` 那层的
   *  `onAreaChange`（写 `composerHeight`）一起量进去。
   */
  @Builder
  headerMeta() {
    Column({ space: Space.XS }) {
      // 第二行：元信息（运行时 · 设备 · 工作区）+ 会话状态 + WS 连接态。
      //
      // ⚠️ 本轮按用户要求重排（改前是「空闲 · DeepSeek Harness · LYW · <工作区路径>」+「已连接」，
      // 下面再单独一行「● 空闲」胶囊）：
      //  ① 会话状态从副标题**开头**挪到「已连接」**左边**（同一个状态在一屏里只出现一次）；
      //  ② 那一行状态胶囊整行去掉 ⇒ 功能栏少一行、少占一条竖向空间。
      Row({ space: Space.S }) {
        Row({ space: Space.XS }) {
          Text(this.sessionSubtitle)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .onClick(() => {
          if (this.prepared) {
            this.workspacePanelOpen = !this.workspacePanelOpen;
            if (this.workspacePanelOpen) {
              this.showRuntimeSheet = false;
            }
          }
        })
        if (this.sessionStatusText.length > 0) {
          Text(this.sessionStatusText)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
        }
        Text(this.connectionText())
          .fontSize(FontSize.CAPTION)
          .fontColor(this.connection === ConnectionState.CONNECTED
            ? $r('app.color.runtime_running') : muted())
      }
      .width('100%')
      .padding({ left: Space.PAGE, right: Space.PAGE })

      // 状态胶囊那一行整行去掉（R37 用户要求），只保留服务端给的状态原因 ——
      // 那是排查用的原文，没有它就只能看到「出错」两个字（R11 的 P0 教训），所以不能一起删。
      if (this.runtimeReason.length > 0) {
        Row({ space: Space.S }) {
          Text(this.runtimeReason)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: Space.PAGE, right: Space.PAGE })
      }
    }
    .width('100%')
    // ## R79：**本行自己不带任何「外框」**（用户：「**不要加外框**」）
    //
    // 底 / 模糊 / 圆角 / 描边 **全部移交给**外面那条**全宽底部带**（见 `composer()`）：
    // 那样它和输入卡才是「**和对话框一样的模糊**」的一个整体，而不是"卡片 + 挂件"。
    // | 项 | 谁给 |
    // | --- | --- |
    // | 底色 / 模糊 | `composer()` 的底部带（`glassCardSurface()` + `GLASS_BLUR_RADIUS`，与卡片同令牌） |
    // | 圆角 / 描边 | **没有** —— 带子是**铺满屏宽、铺到屏幕底**的一条（圆角会让它像第二张卡） |
    // | 横向内边距 | 带子给 `Space.M`；本行各行自己还给 `Space.PAGE`(18) ⇒ 左起 30vp |
    // | 上下内边距 | 本行**上下都为 0** ⇒ 小字紧贴卡片下沿、紧凑地压在带子里 |
    // ⚠️ 横向 30vp vs 输入卡内正文起点 12+16=28vp ⇒ 差 2vp，**视觉上就是对齐的**，不需要再调。
    // ⚠️ R77 记下的「两端都不挂底 ⇒ 静止完全不模糊」那条失败仍然成立（见
    //  开发期验证记录）——
    //  但那条说的是**标题栏**那一段；本行的底现在由底部带承担，依然**有底**。
    .padding({ top: 0, bottom: 0 })
    // ## R78：**本行不再实测自身高度**（`headerHeight` 与它的 `onAreaChange` 一并删除）
    // 理由：它当初被实测出来只为**一处**消费 —— 「提示条 / 面板浮层」的 `margin.top`。
    // R78 把本行搬走之后，那一层改成贴标题栏下沿（`titleBarBottomVp() + Space.S`）⇒ 没有消费者了。
    // ⚠️ 本行的高度**不再需要单独知道**：它在 `composer()` 那个 Column 里，已经被那层的
    //  `onAreaChange`（写 `composerHeight`）一起量进去 ⇒ 时间线的 `contentEndOffset` 自动正确。
    // ⚠️ 留一条 R58 的教训给后人：当年这个值是**多处写入**的，值会在两个数之间跳；
    //  收口成唯一写入点是修对了 —— 现在整体删掉是因为**消费者没了**，不是因为多写入点无害。
  }

  // -------------------------------------------------------------------------
  // 时间线
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // 渲染单元（R13-19：工具折成组 + 复制/分享移到回合末尾）
  // -------------------------------------------------------------------------

  /**
   * 时间线的 key（`ForEach` 时代沿用至今）：把组内每条消息的会变字段都带上
   * （[坑 138]：key 不含会变内容就不重绘）。
   *
   * R55：实现搬到 `feature/TimelineProjection.ets` 的 `timelineRenderItemKey()`（纯函数、进 Node 断言），
   * 这里只做转发 —— 于是「key 稳定唯一 / 含会变字段 / 不含 @State 标记」这三条口径有了可复跑的判据。
   */
  private renderItemKey(item: TimelineRenderItem): string {
    return timelineRenderItemKey(item);
  }

  /** 该渲染单元是不是「回合末尾」——是就返回这一回合的可复制正文（空串 = 不出动作行）。 */
  private turnCopyText(key: string): string {
    const action = turnActionForKey(this.turnActions, key);
    return action !== undefined ? action.copyText : '';
  }

  /** 该回合参与复制的消息 id（分享用，上游 `AgentReplyAction.itemIds`）。 */
  private turnItemIds(key: string): string[] {
    const action = turnActionForKey(this.turnActions, key);
    return action !== undefined ? action.itemIds : [];
  }

  /**
   * 一个渲染单元的渲染（上游 `TimelineRenderItem` 的 when 分支，`SessionMessages.kt:460-504`）：
   * 单条 → `messageRow`；工具组 → 折叠组；重连组 → 折叠组；最后按回合末尾补一行 `复制 / 分享`。
   */
  @Builder
  renderItem(item: TimelineRenderItem) {
    Column({ space: Space.XS }) {
      if (item.groupKind === 'toolRun') {
        this.toolRunGroup(item)
      } else if (item.groupKind === 'reconnect') {
        this.reconnectGroup(item)
      } else {
        this.messageRow(item.messages[0])
      }
      if (this.turnCopyText(item.key).length > 0) {
        this.turnActionRow(item.key)
      }
    }
    // 显式宽度（不是 `width('100%')`）：让每一项严格落在列表内容框里。
    // ⚠️ 它**不能**顺带修好里面 `Row` 的百分比问题（实测无效）—— 见 `timelineContentWidth` 的注释。
    .width(this.timelineContentWidth)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 工具组（上游 `ToolRunGroup`，`SessionMessages.kt:782-908`）：
   * 折叠态一行 = [chevron][图标][汇总文案 13sp Monospace]（`heightIn(min = 34.dp)` + 8dp 圆角 + 活动底色）；
   * 展开态把组内每条按原来的工具行渲染。
   *
   * 汇总文案由 `toolRunSummary()` 给（上游 `toolRunSummary()` :1014-1030）。
   */
  @Builder
  toolRunGroup(item: TimelineRenderItem) {
    Column({ space: Space.XS }) {
      Row({ space: Space.S }) {
        AaIcon({
          d: this.expandedIds.includes(item.key) ? ICONS['chevron-down'] : ICONS['chevron-right'],
          iconSize: FontSize.ICON_MD,
          color: muted()
        })
        AaIcon({ d: ICONS['hammer'], iconSize: FontSize.ICON_MD, color: muted() })
        Text(toolRunSummary(item.messages))
          .fontSize(FontSize.SMALL)
          .fontFamily(REASONING_MONO_FAMILY)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .constraintSize({ minHeight: 34 })
      .padding({ left: Space.XS_PLUS, right: Space.XS_PLUS, top: Space.XS_PLUS, bottom: Space.XS_PLUS })
      .borderRadius(Radius.S)
      .backgroundColor($r('app.color.session_timeline_activity_surface'))
      .onClick(() => {
        const index = this.expandedIds.indexOf(item.key);
        if (index >= 0) {
          this.expandedIds.splice(index, 1);
        } else {
          this.expandedIds.push(item.key);
        }
        this.expandedIds = this.expandedIds.slice();
      })

      if (this.expandedIds.includes(item.key)) {
        ForEach(item.messages, (message: TimelineMessage) => {
          this.messageRow(message)
        }, (message: TimelineMessage) => `${message.id}:${message.revision}:${message.updatedSeq}:${message.status}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 重连失败组（上游 `ReconnectGroup`，`SessionMessages.kt:1033-`）：折叠一行 + 展开明细。 */
  @Builder
  reconnectGroup(item: TimelineRenderItem) {
    Column({ space: Space.XS }) {
      Row({ space: Space.S }) {
        AaIcon({
          d: this.expandedIds.includes(item.key) ? ICONS['chevron-down'] : ICONS['chevron-right'],
          iconSize: FontSize.ICON_MD,
          color: muted()
        })
        AaIcon({ d: ICONS['wifi-off'], iconSize: FontSize.ICON_MD, color: muted() })
        Text(`${item.messages.length} 次重连失败`)
          .fontSize(FontSize.SMALL)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .constraintSize({ minHeight: 34 })
      .padding({ left: Space.XS_PLUS, right: Space.XS_PLUS, top: Space.XS_PLUS, bottom: Space.XS_PLUS })
      .borderRadius(Radius.S)
      .backgroundColor($r('app.color.session_timeline_activity_surface'))
      .onClick(() => {
        const index = this.expandedIds.indexOf(item.key);
        if (index >= 0) {
          this.expandedIds.splice(index, 1);
        } else {
          this.expandedIds.push(item.key);
        }
        this.expandedIds = this.expandedIds.slice();
      })
      if (this.expandedIds.includes(item.key)) {
        ForEach(item.messages, (message: TimelineMessage) => {
          this.messageRow(message)
        }, (message: TimelineMessage) => `${message.id}:${message.revision}:${message.updatedSeq}:${message.status}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 回合末尾的 `复制 / 分享`（上游 `AgentReplyActions`，`SessionMessages.kt:555-600`）：
   * 一条 1dp 分隔线 + 一行两个动作，复制的是**整回合**的 agent 正文。
   */
  @Builder
  turnActionRow(key: string) {
    Column({ space: Space.XS }) {
      Divider()
        .strokeWidth(1)
        .color($r('app.color.border'))
      Row({ space: Space.XS }) {
        Text('复制')
          .fontSize(12)
          .fontColor(muted())
          .height(30)
          .padding({ left: Space.S, right: Space.M })
          .borderRadius(Radius.PILL)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.copyTextToBoard(this.turnCopyText(key), '已复制这条回复。');
          })
        Text('分享')
          .fontSize(12)
          .fontColor(muted())
          .height(30)
          .padding({ left: Space.S, right: Space.M })
          .borderRadius(Radius.PILL)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.promptShareIds(this.turnItemIds(key));
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.XS, right: Space.XS, top: 3 })
  }

  /**
   * 时间线区（加载态 / 草稿引导 / 时间线三选一）。
   *
   * ⚠️ 这里的 `height('100%')` 是相对**它的父 Stack**（`build()` 里那个 `layoutWeight(1)` 的内层 Stack）——
   * 即它铺满的是「元信息行之下、输入区之上」那块内容区。
   *
   * ⚠️ **R72 口径变更**：原文写的是「必须铺满整屏，只有它铺满滚动内容才会从顶栏 / 输入区背后穿过」——
   *  上方那条已经不成立了（顶栏进了框架标题栏、元信息行改成真实占位，上方不再有重叠），
   *  现在**只有下方输入区**是浮层，正文仍从它背后穿过（`contentEndOffset` 让位，未动）。
   */
  @Builder
  timelineArea() {
    if (this.loading && this.messages.length === 0) {
      Column() {
        LoadingProgress().width(28).height(28).color(muted())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else if (this.prepared && this.preparedKind !== DraftSetupKind.READY) {
      // R53：草稿态未就绪（没设备 / 没 Agent / 没工作区）——引导面板，**不是**错误页
      // （文案与旧的新建会话页共用，见 model/NewChatDraft 的 draftSetup* 一族）。
      Column() {
        AaEmptyState({
          title: draftSetupTitle(this.preparedKind),
          message: draftSetupDescription(this.preparedKind, this.preparedReason),
          actionLabel: draftSetupActionLabel(this.preparedKind),
          onAction: () => {
            this.runPreparedSetupAction();
          }
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    } else {
      // ⚠️ R53：草稿态**不加**任何自创的空态文案 —— 用户明确要求「进入的对话要和原对话页面一样，
      // 不要再搞一个页面设计」：一条还没有消息的真会话本来也就是这样（时间线空白 + 输入区可用）。
      this.timeline()
    }
  }

  /** 未就绪引导面板的动作（与旧新建会话页的 runSetupAction 同款分支）。 */
  private runPreparedSetupAction(): void {
    const draft = this.store.draft();
    const kind = this.preparedKind;
    if (kind === DraftSetupKind.NO_DEVICE) {
      Router.push(Route.ADD_DEVICE);
      return;
    }
    if (kind === DraftSetupKind.NO_PROJECT) {
      Router.push(Route.NEW_PROJECT);
      return;
    }
    if (kind === DraftSetupKind.SETTLING) {
      this.store.reloadPrepared().then(() => {
        this.pull();
      });
      return;
    }
    Router.push(Route.DEVICE, draft !== undefined ? draft.connectorId : '');
  }

  @Builder
  timeline() {
    List({ space: Space.M, scroller: this.timelineScroller }) {
      if (this.hasMoreHistory) {
        ListItem() {
          Row() {
            AaSecondaryButton({
              label: '加载更早的消息',
              onTap: () => {
                this.store.loadMoreHistory();
              }
            })
          }
          .width(this.timelineContentWidth)
          .justifyContent(FlexAlign.Center)
        }
      }

      ForEach(this.timelineNoticeList, (notice: RemoteRuntimeNotice) => {
        ListItem() {
          Column() {
            this.noticeCard(notice)
          }
          .width(this.timelineContentWidth)
        }
      }, (notice: RemoteRuntimeNotice) => `notice-${notice.noticeId}:${notice.revision}`)

      // 按**渲染单元**迭代（上游 `items(timelineItems)`，`SessionMessages.kt:458-505`）：
      // 连续的工具调用在这里已经折成一组，`复制 / 分享` 由 `renderItem` 在回合末尾补一行。
      // R55：`ForEach` → `LazyForEach`（按需建/回收子组件，见 `TimelineRenderDataSource` 的类注释）。
      // key 仍走 `renderItemKey`（稳定唯一 + 含 revision/updatedSeq/status 这些会变字段）；
      // 内容变化由数据源的 `onDataChange` 通知驱动，**不是**靠整表 reload ([坑 138] / [坑 152②])。
      LazyForEach(this.timelineSource, (item: TimelineRenderItem) => {
        ListItem() {
          this.renderItem(item)
        }
      }, (item: TimelineRenderItem) => this.renderItemKey(item))
    }
    .width('100%')
    .height('100%')
    // ## R76：上下让位 —— **起始走官方 `contentStartOffset`，末端保持 `contentEndOffset`**
    //
    // ### 起始让位（R76 从「结构性占位」改回「偏移」）
    // `contentStartOffset(titleBarBottomVp() + Space.S)`：把列表**视口顶边**推到元信息行浮层之下。
    // · API 原文（SDK `list.d.ts:1038-1054`）：「Sets the offset from the start of the list content to
    //  the boundary of the list display area」⇒ 正是「让内容从浮层背后滚过、同时起始不贴边」。
    // · 数值与「滑到顶部」圆钮、元信息行浮层的 `margin.top` **同源同值**（三者都走
    //  `titleBarBottomVp()`），彼此不可能错位。
    //
    // ⚠️ **R72 当年弃用它、R76 又改回来**，两轮的诉求不同，都要记清楚：
    //  · R72 的诉求是「**任何滚动位置**都不能被盖」。`contentStartOffset` 只管**起点**——
    //  用户往下滚时内容仍会移动到视口顶之上、从浮层底下穿过 ⇒ 当时判「做不到」而改用真实占位；
    //  · **R76 的诉求是「沉浸」**（用户：「功能栏与时间栏沉浸，与首页效果一致」）。真实占位会让
    //  正文顶端**永久**排在元信息行下方 ⇒ 玻璃背后只有纯色画布 ⇒ 糊不出东西 = 没沉浸。
    //  ⇒ 改回偏移。
    //  ⚠️ 副作用（如实记录）：**用户往下滚时，正文仍会从元信息行浮层底下穿过**（那是"沉浸"的
    //  必然代价，首页的列表也一样）。若哪天用户反过来要求「不许穿」，就得回到 R72 的真实占位。
    // ⚠️ `List` 依然**没有** padding（坑 217 禁的是"用容器 padding 让内容永远穿不过去"）。
    // ### 末端让位（未动）
    // 输入区仍是浮层，`contentEndOffset` 让它"内容从下方对话框背后穿过"（用户明确要的效果）。
    // 高度取实测值（输入区随附件条变化），不写死。
    .contentStartOffset(this.titleBarBottomVp() + Space.S)
    .contentEndOffset(this.composerHeight + Space.S)
    // ⚠️ R49：水平内边距留在 `List` 上（它能把 ListItem 正确摆到 `[42,1274]`）。
    // 但要知道：列表子树里 `width('100%')` 解析出来的**不是**父容器的剩余宽度 ——
    // dump 实测 `Text "协议层" [123,1669][1316,1731]`（父容器只有 `[42,1274]`），右边界 1316 = 屏宽。
    // ⚠️ 这条**不能**靠「把内边距下放到项上」或「给项一个显式数值宽度」解决（两种修法都实测无效：
    //  前者 ListItem 摆对了但孩子的 `100%` 逐字节不变，后者项本身已是数值宽度、孙子照样越界）。
    // `Row` 里必须改用 `layoutWeight(1)`（见 `AaMarkdown.listItemText()` 的注释）。
    // 这里的 `timelineContentWidth` 只负责定**项自己的宽度**，不是上面那条的修法。
    .padding({ left: Space.M, right: Space.M })
    .scrollBar(BarState.Off)
    // 两个定位钮**默认隐藏**，只在这一刻出现（用户要求「只有在滑动时出现」）。
    // `onDidScroll` 在拖动/惯性过程中连续触发，`onScrollStop` 是停手那一刻 —— 两个都调，
    // 于是「停手 1.2 秒后自动消失」这个行为对两种收尾都成立。
    // ⚠️ 用 `onDidScroll` 而不是 `onScroll`：后者在 API 26 已废弃（构建期 ArkTS:WARN，
    //  本工程保持零告警）。
    .onDidScroll(() => {
      this.revealScrollButtons();
      // 顺手刷新「是否在底部」：用户上翻后新消息就不该再把他拽回去（R37 十改）。
      this.syncFollowTail();
    })
    .onScrollStop(() => {
      this.revealScrollButtons();
    })
  }

  // R20：状态文案表统一在 `model/StatusLabels.ets`（纯字符串映射、零依赖 ⇒ 可进逻辑自测）。
  // 修前页面把服务端枚举**原样**渲染 —— 并排图上一眼就能看到 `connected` / `waiting_approval`
  // 这类下划线英文。三张表：消息状态 / 会话级 Runtime 状态 / WS 连接态。

  private runtimeStateText(): string {
    const state = this.store.runtimeState;
    return state === undefined ? '' : runtimeStateStatusLabel(state.status);
  }

  /** WS 连接态文案（表在 `StatusLabels.ets`）；枚举 → 字符串在这一处做。 */
  private connectionText(): string {
    return connectionStatusLabel(`${this.connection}`);
  }

  /**
   * 输入区底部避让（vp）= `max(下限, min(设备上报的安全区, 上限))`。
   *
   * 见 `COMPOSER_BOTTOM_MIN/MAX` 的注释：用户要求「对话框下移，只避开手势条就行」。
   * ⚠️ 顺序不能反 —— 写成 `max(安全区, 目标)` 时，安全区一大就退化成取安全区（[坑 180]）。
   */
  private composerBottomInset(): number {
    const safe = this.getUIContext().px2vp(this.safeAreaBottomPx);
    return Math.max(COMPOSER_BOTTOM_MIN, Math.min(safe, COMPOSER_BOTTOM_MAX));
  }

  /**
   * **「标题栏下沿」在窗口坐标系里的 vp 值** —— = `状态栏高度 + TITLE_BAR_VP`。
   *
   * ⚠️ **为什么不能只传 `TITLE_BAR_VP`**（R76 真机实测两次）：`margin` 与
   * `List.contentStartOffset` 的基准都是**窗口顶 y=0**，不是「内容区顶 y=137px」。
   * · 传 66（只有标题栏）⇒ 元信息行 / 首项落在 **y=196px**，钻到标题栏**底下**（实测）；
   * · 传 112（46 状态栏 + 66 标题栏）⇒ **y=332px** = `TitleBar [0,137][1316,332]` 的下沿 ✓。
   * 与 `HomeScreen.listTopOffsetVp()`（那边是 `px2vp(safeTopPx) + TITLE_BAR_VP`）**同源同值**；
   * 那边的注释逐字记着同一个现象：「66vp ⇒ 首项 196px，钻到栏底下」。
   *
   * ⚠️ 读的是**响应式**的 `@StorageLink(SAFE_AREA_TOP_PX)`，不是冷启动时读一次的
   * `AppStorage.get` —— 后者在 R61 实测过「同一包两次冷启动读到 0 / 46vp，顶栏跳 137px」。
   */
  private titleBarBottomVp(): number {
    return this.getUIContext().px2vp(this.safeTopPx) + TITLE_BAR_VP;
  }

  /**
   * **「从输入卡片上边缘 → 屏幕底」这一段的高度**（vp）—— R92 新增，**两个消费者同源同值**：
   *
   * ① 「整体模糊块」的高度（见 `composer()` 里那个 `Stack`）：
   *  用户要「**从对话框上边缘往下统一模糊**」⇒ 那块底的上沿必须**正好压在卡片上沿**；
   * ② 「滑到底部」圆钮的 `margin.bottom`：圆钮要「设在**对话框上边缘**」。
   *
   * ## 为什么这两件事是**同一个数**
   * 圆钮与模糊块都挂在**同一条贴底的 `Stack`** 上（内容层那条，底边 = 屏幕底）：
   * ```
   *  margin.bottom = 本值 ⇒ 节点底边落在「屏幕底 − 本值」= 卡片上沿
   *  （模糊块自己撑出同样高度）⇒ 节点顶边落在「屏幕底 − 本值」= 卡片上沿
   * ```
   * ⇒ 一边定的是模糊块的**顶边**、一边定的是圆钮的**底边**，两者必然是同一个 y。
   *
   * ## 怎么算的（**线性、无反馈环**）
   * ```
   *  composerCardHeight ← 卡片自己（实测，只跟卡片内容有关）
   * + composerBottomSpan() ← 卡片下沿 → 屏幕底（实测，只跟元信息行/手势条避让有关）
   * ```
   * 两项**互不影响**（卡片的高度不含它下面的元信息行；元信息行的位置由卡片的下外边距给，
   * 而那个外边距恒等于第二项 ⇒ 本式恒等）⇒ 没有 `坑 248` 那种「自己给自己让位」的环。
   * ⚠️ 首帧两个实测值都是 0，`composerBottomSpan()` 会兜 8vp，圆钮因此最多贴到「卡片 + 8vp」
   *  的位置一帧 —— 而 `showScrollButtons` 默认 false，首帧根本看不见它。
   *
   * ## ⚠️ 为什么**不**再用 `composerHeight`（圆钮改前的写法是 `margin.bottom = composerHeight + Space.S`）
   * `composerHeight` 量的是「输入区 + 模糊块」**整条**，里面**含**忙碌行与指令面板 ——
   * 于是「深度求索中…」一出现，整条变高、圆钮就被**顶上去**了。这正是用户本轮报的现象。
   * 本值量的是「**卡片上沿 → 屏幕底**」那一段，**不含**忙碌行 / 指令面板（它们在卡片**上方**）⇒
   * 状态行出现、消失、指令面板展开收起，本值**逐帧相同** ⇒ 圆钮钉在原地、模糊块上沿也不动。
   * ⚠️ `composerHeight` 的语义因此**一个字没动**（它继续只喂 `contentEndOffset` 与阻塞公告的
   *  `margin.bottom`），圆钮只是**不再消费**它 —— 见 `composer()` 尾部的实测注释。
   *
   * ⚠️ 首帧两者都还是 0 ⇒ 圆钮贴在屏幕底。但 `showScrollButtons` 默认 false、
   *  且只在滚动时短暂为 true，首帧根本看不见圆钮；下一帧实测值就到位。
   */
  private composerGlassBlockHeightVp(): number {
    return this.composerCardHeight + this.composerBottomSpan();
  }

  /**
   * **「卡片下沿 → 屏幕底」那一段**（vp）= `composerBottomSpanHeight()`，只在首帧兜 8vp。
   *
   * ## 为什么需要这个兜底（**只影响首帧**）
   * 模糊块里那个「下段」盒子自己撑出来的高度，与卡片的下外边距是**同一个量**（恒等），
   * 所以本函数在稳态下**就是实测值**；只有首帧（`onAreaChange` 还没回调）是 0 —— 那时：
   * · 卡片的下外边距会是 0 ⇒ 卡片贴在块底、块高 = 卡片高 ⇒ 模糊块的顶边落在**卡片下沿**
   *  （卡片左右那两条缝会露一帧）；
   * · 兜成 8vp 后，块至少比卡片高一点点，圆钮也不会落进卡片里。
   * ⚠️ 兜底量取 `Space.S`(8)：与元信息行同档的视觉量级；它**不进任何稳态布局**
   *  （稳态下实测值 ≫ 8），改它只影响第一帧。
   */
  private composerBottomSpan(): number {
    return Math.max(this.composerBottomSpanHeight, Space.S);
  }

  /**
   * 滚动时**短暂显示**两个定位钮（用户要求「默认隐藏，只有在滑动时出现」）。
   *
   * 每次滚动 / 滚动停止都重置计时器；停手 `SCROLL_BUTTON_HIDE_MS` 之后自动隐藏。
   * ⚠️ 定时器必须能被 `cancelScrollButtonTimer()` 取消 —— 页面销毁后再写 `@State` 是无效写入。
   */
  private revealScrollButtons(): void {
    if (!this.showScrollButtons) {
      this.showScrollButtons = true;
    }
    this.cancelScrollButtonTimer();
    this.scrollHideTimer = setTimeout(() => {
      this.scrollHideTimer = -1;
      this.showScrollButtons = false;
    }, SCROLL_BUTTON_HIDE_MS);
  }

  /**
   * ⚠️ **R65-A 删除本页的 `topInset()`**（理由保留在这里，防止后人再加回来）。
   *
   * R37 五改的本意是「顶栏背景铺到屏幕顶、状态栏那一条也一起糊」。但顶栏首行一旦进入
   * `Navigation` 标题栏，**高度与位置由框架接管**：真机 `dumpLayout` 实测标题栏落在
   * `[0,137][1316,332]`（`HomeScreen` R62 的实测记录）—— 页面根节点**已经在状态栏之下**，
   * 顶栏再避让一次就是**重复避让 137px**。而且原来读的是 `AppStorage.get(SAFE_AREA_TOP_PX)`
   * 这个**非响应**读取，值随冷启动时序在 `0 / 46vp` 之间跳（R61 实测：同一份包两次冷启动顶栏行高
   * 136px / 274px）⇒ 本页按 R65-A 固定**不避让**，与 `HomeScreen`（R62）/ `DevicesScreen`（R65-B）
   * 同一口径。
   *
   * ⚠️ **底部避让不受影响**：`composerBottomInset()` 走的是 `SAFE_AREA_BOTTOM_PX`，仍在自己算。
   */

  /**
   * 「执行中」状态翻转时开关计时器（R37 九改）。
   *
   * 由 `pull()` 在 `canInterrupt` 前后值不同时调用 —— 只在**翻转那一刻**动，
   * 不然后续每次 `pull()` 都会把计时清零。
   */
  private syncBusyTimer(on: boolean): void {
    if (on) {
      this.busyStartedAt = Date.now();
      this.busySeconds = 0;
      if (this.busyTimer >= 0) {
        clearInterval(this.busyTimer);
      }
      this.busyTimer = setInterval(() => {
        if (this.busyStartedAt > 0) {
          this.busySeconds = Math.floor((Date.now() - this.busyStartedAt) / 1000);
        }
      }, 1000);
      // 波浪动画与秒表同生共死：一起开（用户要求「活跃时显示」），也一起停。
      this.waveStep = 0;
      if (this.waveTimer >= 0) {
        clearInterval(this.waveTimer);
      }
      this.waveTimer = setInterval(() => {
        this.waveStep = (this.waveStep + 1) % BUSY_LABEL_CHARS.length;
      }, BUSY_WAVE_STEP_MS);
      return;
    }
    if (this.busyTimer >= 0) {
      clearInterval(this.busyTimer);
      this.busyTimer = -1;
    }
    if (this.waveTimer >= 0) {
      clearInterval(this.waveTimer);
      this.waveTimer = -1;
    }
    this.waveStep = 0;
    this.busyStartedAt = 0;
    this.busySeconds = 0;
  }

  /**
   * 把时间线停在**最新消息**上（R37 十改）。
   *
   * 两种触发：① 页面刚打开（`tailJumpPending`）—— 无条件到底；
   * ② 之后每次 `pull()` —— 只在用户本来就在底部（`followTail`）时跟随。
   *
   * ⚠️ 必须 `setTimeout(0)` 延到下一帧：`pull()` 里消息刚写进 `@State`，列表还没渲染完，
   * 立刻 `scrollEdge` 会停在旧位置（真机表现：进了页面还停在中间）。
   */
  private syncTimelineTail(): void {
    if (!this.tailJumpPending && !this.followTail) {
      return;
    }
    // ⚠️ R44 真机实测：本行的「重试几次」方案**无效**（首次看似生效 0.0594，复测两次仍 0.0040），已回退。
    // 现象与判据见 开发期验证记录：长会话进入后 `Text` bounds = `[0,0][0,0]`，
    // 需要一次**大幅**滑动才恢复（小滚 100px 与等待 30s 都无效）⇒ 不是时机问题，待下一轮定位。
    setTimeout(() => {
      try {
        this.timelineScroller.scrollEdge(Edge.Bottom);
      } catch (error) {
        // 首帧列表还没挂上会抛，忽略即可 —— 下一次 pull() 还会再试
      }
      this.tailJumpPending = false;
    }, 0);
  }

  /** 滚动后刷新「是否在底部」（`isAtEnd()` 由 Scroller 给；未挂载时会抛）。 */
  private syncFollowTail(): void {
    try {
      this.followTail = this.timelineScroller.isAtEnd();
    } catch (error) {
      this.followTail = true;
    }
  }

  /** 取消自动隐藏定时器（滚动中会反复调用，所以先清再设，避免堆一串定时器）。 */
  private cancelScrollButtonTimer(): void {
    if (this.scrollHideTimer >= 0) {
      clearTimeout(this.scrollHideTimer);
      this.scrollHideTimer = -1;
    }
  }

  /**
   * 审批卡里**不带输入**的动作（「允许 / 拒绝」这类；上游 `notice.actions` 里 `input == null` 的那些）。
   *
   * 用显式循环而不是 `filter` + 箭头：ArkTS **不对「重复取同一可选属性」做窄化**
   * （EXPERIENCE §39.2 那张表里的第三条），先取局部变量再判最稳。
   */
  private noticePlainActions(notice: RemoteRuntimeNotice): RemoteRuntimeNoticeAction[] {
    const result: RemoteRuntimeNoticeAction[] = [];
    for (let i = 0; i < notice.actions.length; i++) {
      const action: RemoteRuntimeNoticeAction = notice.actions[i];
      const input = action.input;
      if (input === undefined || !input.required) {
        result.push(action);
      }
    }
    return result;
  }

  /** 带**必填输入**的动作（要配输入框 + 提交按钮，保持纵向）。 */
  private noticeInputActions(notice: RemoteRuntimeNotice): RemoteRuntimeNoticeAction[] {
    const result: RemoteRuntimeNoticeAction[] = [];
    for (let i = 0; i < notice.actions.length; i++) {
      const action: RemoteRuntimeNoticeAction = notice.actions[i];
      const input = action.input;
      if (input !== undefined && input.required) {
        result.push(action);
      }
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // 提问表单（R50）
  // -------------------------------------------------------------------------

  /**
   * 这张公告是不是**提问请求**（上游 `notice.inputRequestForm() != null`）。
   *
   * ⚠️ 不能用「`input.required == true`」代替：审批卡的「改一下再执行」也是 `required == true`，
   * 但它是**单框**语义（上游 `inputFields()` 的兜底分支），不是提问表单。
   * 两者的判据分别是 `interactionType === 'input_request'` 与 `uiSchema.component === 'inputRequest'`。
   */
  private formOf(notice: RemoteRuntimeNotice): InputRequestForm | undefined {
    return inputRequestForm(notice);
  }

  /** 本题的表单是不是提问表单（@Builder 里不能声明局部变量，所以走方法）。 */
  private isInputRequest(notice: RemoteRuntimeNotice): boolean {
    return inputRequestForm(notice) !== undefined;
  }

  /** 提问表单的题目（供 `ForEach` 用；不是提问表单时给空数组）。 */
  private formQuestions(notice: RemoteRuntimeNotice): InputRequestQuestion[] {
    const form = inputRequestForm(notice);
    return form !== undefined ? form.questions : [];
  }

  /**
   * 取本题的草稿快照（缺省项补空草稿）。
   *
   * ⚠️ 必须**每次新建一个 Map**再喂给 `isComplete` / `buildPayload`：那两个函数是纯函数，
   * 而 `@State` 里只存用户真正动过的题 —— 直接传原 Map 会「少题」被判成不完整。
   */
  private draftsFor(notice: RemoteRuntimeNotice): Map<string, InputRequestDraft> {
    const form = inputRequestForm(notice);
    const result: Map<string, InputRequestDraft> = new Map<string, InputRequestDraft>();
    if (form === undefined) {
      return result;
    }
    const stored = this.inputRequestDrafts.get(notice.noticeId);
    for (let i = 0; i < form.questions.length; i++) {
      const questionId = form.questions[i].id;
      const draft = stored !== undefined ? stored.get(questionId) : undefined;
      result.set(questionId, draft !== undefined ? draft : emptyDraft());
    }
    return result;
  }

  /** 某一题当前的草稿（渲染时读它 —— 读的是 `@State`，变化会重绘这一行）。 */
  private draftOf(notice: RemoteRuntimeNotice, questionId: string): InputRequestDraft {
    const stored = this.inputRequestDrafts.get(notice.noticeId);
    const draft = stored !== undefined ? stored.get(questionId) : undefined;
    return draft !== undefined ? draft : emptyDraft();
  }

  /** 写入某一题的草稿（两层都换新引用，否则 `@State` 不重绘）。 */
  private setDraft(noticeId: string, questionId: string, draft: InputRequestDraft): void {
    const next: Map<string, Map<string, InputRequestDraft>> = new Map<string, Map<string, InputRequestDraft>>();
    this.inputRequestDrafts.forEach((value: Map<string, InputRequestDraft>, key: string) => {
      next.set(key, key === noticeId ? copyDrafts(value) : value);
    });
    if (!next.has(noticeId)) {
      next.set(noticeId, new Map<string, InputRequestDraft>());
    }
    const bucket = next.get(noticeId) as Map<string, InputRequestDraft>;
    bucket.set(questionId, draft);
    this.inputRequestDrafts = next;
  }

  /** 这张表单是否已答完（决定提交钮是否可点）。 */
  private formComplete(notice: RemoteRuntimeNotice): boolean {
    const form = inputRequestForm(notice);
    if (form === undefined) {
      return false;
    }
    return isComplete(form, this.draftsFor(notice));
  }

  /** 提交提问表单：载荷形状 `{ answers: { <qid>: { optionIds, customText? } } }`（连接器契约）。 */
  private submitInputRequest(notice: RemoteRuntimeNotice, action: RemoteRuntimeNoticeAction): void {
    const form = inputRequestForm(notice);
    if (form === undefined) {
      return;
    }
    const payload = buildPayload(form, this.draftsFor(notice));
    // 提交后把草稿清掉：同一 noticeId 再次出现（重开一问）时不该带上上一轮的答案。
    const next: Map<string, Map<string, InputRequestDraft>> = new Map<string, Map<string, InputRequestDraft>>();
    this.inputRequestDrafts.forEach((value: Map<string, InputRequestDraft>, key: string) => {
      if (key !== notice.noticeId) {
        next.set(key, value);
      }
    });
    this.inputRequestDrafts = next;
    this.store.respondNotice(notice.noticeId, action.actionId, payload);
  }

  /**
   * 公告卡：审批 / 输入请求 / **提问表单**（R50）。
   *
   * ⚠️ 提问表单的标记**全部内联在本 `@Builder` 里**，不要再拆成下一层「带值参数的 `@Builder`」——
   * 本工程已记录过这条（坑 38，同 `runtimeSectionBody` 的注释）：值参数 `@Builder` 的**函数体不会因
   * `@State` 变化而重跑**，于是选中态/提交钮禁用态全都「看着点了没反应」。
   * 判据（R50 实测）：选项行拆成 `inputRequestOptionRow(...)` 之后，点击后指示器底色**逐字节不变**
   * （仍是 `#FFF1F0ED`），而把标记内联回来立刻生效。
   *
   * 上游对照 `SessionRuntimeControls.kt`：
   *  · `:248` 的 if/else —— **有表单时不再渲染**「图标 + 标题 + 说明」那行表头（题面本身就是正文，
   *  再压一行连接器给的英文标题 `Claude needs your input` 纯属噪音）；
   *  · `RuntimeInputRequestQuestionFields`：题面 + 选项行 + 「其他」；
   *  · `RuntimeInputRequestSelectionIndicator`：多选 6dp 圆角方框 / 单选圆形，20dp，选中填主色 + 勾；
   *  · `:307-329` 的动作行：有表单时右对齐，且**未答完时提交钮不可点**（`form.isComplete`）。
   */
  /**
   * 阻塞公告栈（上游 `BlockingRuntimeNoticeStack`，`SessionRuntimeControls.kt:726-776`）：
   * 钉在**输入区上方**，只渲染**第一条**（上游 `notices.first()`）。
   *
   * ⚠️ 与上游的两处差异（如实记录，供后续对齐）：
   *  · 上游把后面的最多 3 条画成「压着的空卡片」（`offset -7dp` + scale/alpha 递减）——本工程只渲染当前这条
   *  （阻塞公告同时多条属罕见路径，本轮先保证「看得见 + 能用」）；
   *  · 上游对**非提问**公告挂 `verticalScroll`、对提问表单不挂（表单自己滚）；本工程统一套一层限高 `Scroll`
   *  —— 提问表单可能很长，统一处理更稳。
   */
  @Builder
  noticeStack() {
    Column() {
      Scroll() {
        Column() {
          this.noticeCard(this.blockingNoticeList[0])
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: this.noticeStackMaxHeight() })
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, bottom: Space.XS })
    // 贴在输入区**上沿**：高度用实测值（输入区会随附件条变化）。
    .margin({ bottom: this.composerHeight })
  }

  /** 阻塞公告卡的最大高度：提问表单给 58% 屏高、其余 38%（上游 `:739-740` 的同一口径）。 */
  private noticeStackMaxHeight(): number {
    const ratio = this.isInputRequest(this.blockingNoticeList[0]) ? 0.58 : 0.38;
    return Math.floor(this.screenHeightVp * ratio);
  }

  @Builder
  noticeCard(notice: RemoteRuntimeNotice) {
    Column({ space: Space.S }) {
      if (this.isInputRequest(notice)) {
        // ---- 提问表单本体（上游 `RuntimeInputRequestFields`：Column(spacedBy 16.dp) + 逐题）----
        Column({ space: Space.L }) {
          ForEach(this.formQuestions(notice), (question: InputRequestQuestion) => {
            Column({ space: Space.S }) {
              if (question.header !== undefined) {
                Text(question.header)
                  .fontSize(FontSize.CAPTION)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(muted())
              }
              Text(question.prompt)
                .fontSize(FontSize.BODY)
                .lineHeight(19)
                .fontWeight(FontWeight.Medium)
                .fontColor(ink())
                .width('100%')

              // 选项行：整行圆角 12、底色 `subtle`（选中 100% / 未选 68%）、内边距 11/10、间距 10。
              ForEach(question.options, (option: InputRequestOption) => {
                Row({ space: Space.S_PLUS }) {
                  Row() {
                    if (this.draftOf(notice, question.id).optionIds.indexOf(option.id) >= 0) {
                      AaIcon({ d: ICONS['check'], iconSize: FontSize.CAPTION_PLUS, color: onPrimaryAction() })
                    }
                  }
                  .width(20)
                  .height(20)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)
                  .borderRadius(question.multiple ? Radius.XS : Radius.PILL)
                  .backgroundColor(this.draftOf(notice, question.id).optionIds.indexOf(option.id) >= 0
                    ? primaryAction() : $r('app.color.subtle'))

                  Column({ space: Space.XXS }) {
                    Text(option.label)
                      .fontSize(FontSize.SMALL)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(ink())
                      .width('100%')
                    if (option.description !== undefined) {
                      Text(option.description)
                        .fontSize(FontSize.CAPTION)
                        .lineHeight(16)
                        .fontColor(muted())
                        .width('100%')
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .padding({ left: 11, right: 11, top: Space.S_PLUS, bottom: Space.S_PLUS })
                .borderRadius(Radius.M)
                .backgroundColor($r('app.color.subtle'))
                .opacity(this.draftOf(notice, question.id).optionIds.indexOf(option.id) >= 0 ? 1 : 0.68)
                .onClick(() => {
                  const current = this.draftOf(notice, question.id);
                  this.setDraft(notice.noticeId, question.id, toggleOption(question, current, option.id));
                })
              }, (option: InputRequestOption) => `${notice.noticeId}-q-${question.id}-o-${option.id}`)

              // 「其他」：指示器 + 输入框同一行（上游 `RuntimeInputRequestCustomAnswer`）。
              if (question.allowCustom) {
                Row({ space: Space.S_PLUS }) {
                  Row() {
                    if (this.draftOf(notice, question.id).useCustom) {
                      AaIcon({ d: ICONS['check'], iconSize: FontSize.CAPTION_PLUS, color: onPrimaryAction() })
                    }
                  }
                  .width(20)
                  .height(20)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(VerticalAlign.Center)
                  .borderRadius(question.multiple ? Radius.XS : Radius.PILL)
                  .backgroundColor(this.draftOf(notice, question.id).useCustom
                    ? primaryAction() : $r('app.color.subtle'))

                  TextInput({
                    text: this.draftOf(notice, question.id).customText,
                    placeholder: INPUT_REQUEST_OTHER_LABEL
                  })
                    .fontSize(FontSize.SMALL)
                    .placeholderFont({ size: FontSize.SMALL })
                    .placeholderColor(muted())
                    .fontColor(ink())
                    .backgroundColor(Color.Transparent)
                    .padding(0)
                    .height(24)
                    .layoutWeight(1)
                    // ⚠️ 聚焦即「选中其他」：上游是 `onFocusChanged { if (it.isFocused) selectCustom() }`。
                    .onFocus(() => {
                      const current = this.draftOf(notice, question.id);
                      if (!current.useCustom) {
                        this.setDraft(notice.noticeId, question.id, selectCustom(question, current));
                      }
                    })
                    .onChange((value: string) => {
                      const current = this.draftOf(notice, question.id);
                      this.setDraft(notice.noticeId, question.id, updateCustomText(question, current, value));
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: 11, right: 11, top: Space.TIGHT, bottom: Space.TIGHT })
                .borderRadius(Radius.M)
                .backgroundColor($r('app.color.subtle'))
                .opacity(this.draftOf(notice, question.id).useCustom ? 1 : 0.68)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (question: InputRequestQuestion) => `${notice.noticeId}-q-${question.id}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 动作行：提交是右下角 34vp 圆形图标钮（沿用 R38/R42 的「发送入口图标化」口径），
        // 其余动作（连接器固定给一个 `cancel`）走文字胶囊；未答完时提交钮置灰。
        // ⚠️ **整行右对齐**（上游 `SessionRuntimeControls.kt:310-313`：有表单时 `Alignment.End`）
        // —— 这里不用 `Blank()` 撑开，因为「发送入口落右下角」在本工程有一条**静态判据**
        // （`suite-send-icon.mjs` 要求每个 `AaPrimaryIconButton` 调用点都在 `justifyContent(FlexAlign.End)` 的行里）。
        Row({ space: Space.S }) {
          ForEach(this.noticePlainActions(notice), (action: RemoteRuntimeNoticeAction) => {
            AaSecondaryButton({
              label: action.label,
              compact: true,
              onTap: () => {
                this.store.respondNotice(notice.noticeId, action.actionId);
              }
            })
          }, (action: RemoteRuntimeNoticeAction) => `${notice.noticeId}-req-${action.actionId}`)
          ForEach(this.noticeInputActions(notice), (action: RemoteRuntimeNoticeAction) => {
            AaPrimaryIconButton({
              name: 'send',
              interactive: this.formComplete(notice),
              accessibilityLabel: action.label,
              onTap: () => {
                this.submitInputRequest(notice, action);
              }
            })
          }, (action: RemoteRuntimeNoticeAction) => `${notice.noticeId}-req-submit-${action.actionId}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      } else {
        Row({ space: Space.S }) {
        Text(notice.severity === 'warning' ? '⚠' : (notice.severity === 'error' ? '⛔' : 'ℹ'))
          .fontSize(FontSize.BODY)
          .fontColor(notice.severity === 'error' ? $r('app.color.error_text') : $r('app.color.notice_warning'))
        Text(notice.title)
          .fontSize(FontSize.BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .layoutWeight(1)
      }
      .width('100%')

      if (notice.message !== undefined && notice.message.length > 0) {
        Text(notice.message)
          .fontSize(FontSize.SMALL)
          .fontColor(ink())
          .width('100%')
      }

      // 不带输入的动作（允许 / 拒绝…）**横向**排布 —— 上游 `SessionRuntimeControls.kt:307-329` 用
      // `FlowRow(horizontalArrangement = spacedBy(8.dp, Alignment.CenterHorizontally))`。
      // ⚠️ R20 修正：本工程原来把**每个** action 逐个塞进本 `Column(space 8dp)` ⇒ 按钮**纵向堆叠**，
      // 并排图上一眼可见（安卓是两个并排的胶囊，鸿蒙是两个上下摞的方块）。
      // ArkUI 没有 FlowRow；审批动作通常 1~3 个、`AaSecondaryButton` 按内容占宽，一行放得下
      // ⇒ 用不换行的 `Row(spacedBy 8dp)` 与上游表现相同（极端窄屏 + 大量动作会挤压，属已知边界）。
      if (this.noticePlainActions(notice).length > 0) {
        Row({ space: Space.S }) {
          ForEach(this.noticePlainActions(notice), (action: RemoteRuntimeNoticeAction) => {
            AaSecondaryButton({
              label: action.label,
              onTap: () => {
                this.store.respondNotice(notice.noticeId, action.actionId);
              }
            })
          }, (action: RemoteRuntimeNoticeAction) => `${notice.noticeId}-${action.actionId}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 带输入的动作：上游是「字段区 + `TextButton(submit)`」（`:331-345`）—— 输入与提交是一对，保持纵向。
      // R38：submit 那一枚由**文字块**改为**图标按钮**（见下），纵向结构与字段无关项一概不变。
      ForEach(this.noticeInputActions(notice), (action: RemoteRuntimeNoticeAction) => {
        Column({ space: Space.S }) {
          TextInput({
            text: this.noticeInputs.get(notice.noticeId) ?? '',
            // R42（需求原文：「…修改后也要同步修改提示」）：R38 把提交钮改成**纯图标**之后，
            // 这张卡里再也找不到「提交」两个字 —— 占位是此处唯一还能给用户指路的文案。
            // 口径与终端粘贴弹层那句一致（锚文 `再点右下角的发送图标。`）。
            // ⚠️ 占位属本工程自造（上游这里是服务端给的字段 label，见 `SessionRuntimeControls.kt:336`
            // 的 `label = { Text(field.label) }`），因此可以按 R41 的先例把「点哪里」写进来
            // （同 `SettingsScreen.ets` 的「新密码（至少 6 位）」）。
            placeholder: '请输入后点右下角的发送图标'
          })
            .fontSize(FontSize.SMALL)
            .height(42)
            .borderRadius(Radius.M)
            .borderWidth(1)
            .borderColor(borderColor())
            .backgroundColor(canvas())
            .onChange((value: string) => {
              // ⚠️ 必须**按 noticeId 分行存**：多张审批卡同时在场时（多设备并发审批），
              // 共用一个 `noticeInput` 会出现「在 A 卡输入被 B 卡清空」，
              // 更糟的是在 A 卡点提交却把 B 卡最后输入的内容发出去。
              this.noticeInputs.set(notice.noticeId, value);
            })
          // R38（用户需求「软件所有发送功能都用图标取代，并尽量放在对话框右下角」）：
          // 提交按钮由**全宽文字主按钮**改为「字段下方**右对齐**的 34vp 圆形图标按钮」。
          // 输入框就在它正上方，上下文足够；动作语义由无障碍文本 `action.label` 承载
          // （Lead 裁决：采用「纯图标 + accessibilityText」，不退回全宽文字按钮）。
          Row() {
            AaPrimaryIconButton({
              name: 'send',
              accessibilityLabel: action.label,
              onTap: () => {
                const typed = this.noticeInputs.get(notice.noticeId) ?? '';
                const input: Record<string, Object> = { 'value': typed };
                this.noticeInputs.delete(notice.noticeId);
                this.store.respondNotice(notice.noticeId, action.actionId, input);
              }
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
      }, (action: RemoteRuntimeNoticeAction) => `${notice.noticeId}-${action.actionId}`)
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.L)
    .backgroundColor($r('app.color.error_surface'))
    .borderWidth(1)
    .borderColor($r('app.color.error_border'))
  }

  /**
   * 消息附件：图片内联渲染（可点开看大图），其它类型显示「文件名 + 体积」条。
   * 对应上游 `AttachmentImages.kt`：图片直接画在消息里，非图片给一条可点的文件行。
   */
  @Builder
  attachmentList(message: TimelineMessage) {
    Column({ space: Space.XS }) {
      ForEach(message.attachments, (attachment: TimelineAttachment) => {
        if (this.attachmentUris.has(attachment.fileId)) {
          Image(this.uriOf(attachment.fileId))
            .constraintSize({ maxWidth: this.imageMaxWidth })
            .height(160)
            .objectFit(ImageFit.Contain)
            .borderRadius(Radius.M)
            .backgroundColor($r('app.color.session_code_surface'))
            .onClick(() => {
              this.viewerUri = this.uriOf(attachment.fileId);
              this.viewerTitle = this.nameOf(attachment);
              this.showRuntimeSheet = false;
              this.viewerOpen = true;
            })
        } else {
          // ⚠️ 这个 Row **不能**写 `.width('100%')`：外层气泡是「按内容撑开」的
          // （`constraintSize({maxWidth:'86%'})` + 无固定宽），子节点再要 100% 会解析成
          // 一个比气泡更宽的值 —— 真机实测：整行向右溢出，最后一格「体积」被推到裁剪区外，
          // 于是 `dumpLayout` 里连节点都查不到（看起来像「没渲染」）。
          // 正解：不给固定宽，改用内容宽度 + 给文件名一个上限。
          Row({ space: Space.S }) {
            AaIcon({ d: ICONS['paperclip'], iconSize: FontSize.CAPTION, color: muted() })
            Text(this.nameOf(attachment))
              .fontSize(FontSize.CAPTION)
              .fontColor(ink())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 200 })
            Text(this.attachmentState(attachment))
              .fontSize(FontSize.CAPTION)
              .fontColor(muted())
          }
          .padding({ left: Space.S, right: Space.S, top: 6, bottom: 6 })
          .borderRadius(Radius.S)
          .backgroundColor($r('app.color.subtle'))
          // 下载失败后 `AttachmentStore.ensure` 会短路该 fileId（否则失败 → notify →
          // pull → ensure 会无限重试），所以必须给用户一个显式的重试入口。
          .onClick(() => {
            if (this.attachmentErrors.has(attachment.fileId)) {
              this.attachments.retry(
                this.store.sessionId, attachment.fileId, attachment.mediaType, attachment.name);
            }
          })
        }
      }, (attachment: TimelineAttachment) => `${message.id}-att-${attachment.fileId}`)
    }
    // ⚠️ R49：宽度上限必须是**数值**。气泡是按内容撑开的，里面的 `width('100%')` 会被解析成
    // 「窗口右边缘 − 自身左偏移」（dump 实测这一层 `[357,137][1316,538]`，而气泡只有 `[315,1274]`）——
    // 挂一个数值上限就把它收敛回气泡内容框（同 `bubbleContentWidth` 的注释）。
    .width('100%')
    .constraintSize({ maxWidth: this.bubbleContentWidth })
    .alignItems(HorizontalAlign.Start)
  }

  private uriOf(fileId: string): string {
    const uri = this.attachmentUris.get(fileId);
    return uri !== undefined ? uri : '';
  }

  private nameOf(attachment: TimelineAttachment): string {
    const cached = this.attachmentNames.get(attachment.fileId);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    return attachment.name.length > 0 ? attachment.name : attachment.fileId;
  }

  /** 非图片附件右侧的状态字：体积 / 加载中 / 失败原因。 */
  private attachmentState(attachment: TimelineAttachment): string {
    const error = this.attachmentErrors.get(attachment.fileId);
    if (error !== undefined) {
      return '加载失败，点此重试';
    }
    if (attachment.size > 0) {
      return formatBytes(attachment.size);
    }
    return '加载中…';
  }

  @Builder
  attachmentViewer() {
    Column({ space: Space.S }) {
      Row({ space: Space.S }) {
        Text(this.viewerTitle)
          .fontSize(FontSize.TITLE)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        AaSecondaryButton({
          label: '关闭',
          compact: true,
          onTap: () => {
            this.viewerOpen = false;
          }
        })
      }
      .width('100%')

      Image(this.viewerUri)
        .width('100%')
        .layoutWeight(1)
        .objectFit(ImageFit.Contain)
    }
    .width('100%')
    .height('100%')
    .padding(Space.L)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  messageRow(message: TimelineMessage) {
    if (message.kind === MessageKind.MARKER) {
      Row() {
        Text(`— ${message.title} —`)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    } else if (message.kind === MessageKind.REASONING) {
      // 推理段（思考过程）—— 上游 `SessionMessages.kt` 的 `TimelineMessageKind.Reasoning ->` 分支
      // **只**有 `ReasoningSection`：没有作者行、没有状态徽标、没有复制 / 分享动作行。
      this.reasoningSection(message)
    } else if (message.author === MessageAuthor.USER) {
      // 用户气泡 —— 复刻上游 `SessionMessages.kt:1326-1343`：
      // `Row(spacedBy 6.dp, Alignment.Bottom) { MessageCopyButton; Bubble }`，
      // **复制按钮常驻**在气泡左侧（不是长按才出），气泡圆角 22dp。
      Row({ space: Space.XS_PLUS }) {
        if (copyableMessage(message.title, message.body)) {
          this.messageCopyButton(message)
        }
        Column({ space: Space.XS }) {
          this.userMessageBody(message)
          if (message.attachments.length > 0) {
            this.attachmentList(message)
          }
        }
        .padding(Space.M)
        .borderRadius(Radius.XXL)
        .backgroundColor($r('app.color.session_status_neutral_surface'))
        // ⚠️ R49：上限必须是**数值**（改前是 `'86%'`，会把正文顶出屏幕 —— 见 `bubbleMaxWidth` 的注释）。
        // 值 = 消息行可用宽度 × 0.78（对齐上游），已经给左侧「复制」按钮留出了余量。
        .constraintSize({ maxWidth: this.bubbleMaxWidth })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Bottom)
    } else {
      Column({ space: Space.XS }) {
        Row({ space: Space.S }) {
          Text(this.authorLabel(message))
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
          if (messageStatusLabel(message.status).length > 0) {
            Text(messageStatusLabel(message.status))
              .fontSize(FontSize.CAPTION)
              .fontColor(messageStatusFailed(message.status)
                ? $r('app.color.error_text') : $r('app.color.notice_warning'))
          }
        }
        if (message.kind === MessageKind.MESSAGE || message.kind === MessageKind.SYSTEM) {
          this.messageBody(message)
        } else {
          this.toolMessage(message)
        }
        // ⚠️ `复制 / 分享` **不再**挂在每条消息上：上游 `AgentReplyActions`（`SessionMessages.kt:494-503`）
        // 只在**回合末尾**出一行，由 `renderItem()` 统一补（本行原来在此处）。
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 复制按钮（上游 `MessageCopyButton`，`SessionMessages.kt:1397-1432`）：高 **30dp**、常驻可见。
   *
   * ⚠️ 上游是 30dp 圆形的**矢量图标**按钮（17dp 图标、tint `muted`）；本工程没有图标资源
   * （上游实现 已把图标列为本轮硬缺口），改用同高的 12sp 文字按钮 ——
   * 高度、位置、可见性一致，只有图标换成文字；这也满足「必须有可见入口」（第三轮真机
   * 验证过合成长按不可靠）。
   */
  @Builder
  messageCopyButton(message: TimelineMessage) {
    Text('复制')
      .fontSize(12)
      .fontColor(muted())
      .height(30)
      .padding({ left: Space.S, right: Space.M })
      .borderRadius(Radius.PILL)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.copyMessage(message);
      })
  }

  /**
   * 消息动作行 —— 对应上游 `AgentReplyActions`（`SessionMessages.kt:554-587`）：
   * 先一条 **1dp** 分隔线（`border` 半透明），再一行 [复制][分享]（间距 4dp）。
   *
   * ⚠️ 与上游的两处差异：
   *  · 上游按**回合**聚合（一轮 Agent 回复只在回合末尾出一行，复制的是整轮拼接文本）；
   *  本工程消息模型是扁平的、没有回合聚合，改为**每条** Agent / 工具消息下方一行，复制该条；
   *  · 同 `messageCopyButton`：矢量图标 → 文字（本工程无图标资源）。
   */
  @Builder
  messageActionRow(message: TimelineMessage) {
    Column({ space: Space.XS }) {
      Divider()
        .strokeWidth(1)
        .color($r('app.color.border'))
      Row({ space: Space.XS }) {
        this.messageCopyButton(message)
        Text('分享')
          .fontSize(12)
          .fontColor(muted())
          .height(30)
          .padding({ left: Space.S, right: Space.M })
          .borderRadius(Radius.PILL)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.promptShare(message);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Space.XS, right: Space.XS, top: 3 })
  }

  private authorLabel(message: TimelineMessage): string {
    switch (message.author) {
      case MessageAuthor.AGENT: return 'Agent';
      case MessageAuthor.TOOL: return message.kind === MessageKind.COMMAND ? '终端' : '工具';
      default: return '系统';
    }
  }

  @Builder
  messageBody(message: TimelineMessage) {
    // 走轻量 Markdown 渲染（标题/列表/引用/粗斜体/行内代码/围栏代码块）
    AaMarkdown({ text: message.body, baseSize: FontSize.BODY })
  }

  /**
   * 用户气泡里的正文：与 `messageBody` 唯一的不同是带上**数值**宽度上限。
   *
   * 气泡是按内容撑开的（只有一个宽度上限），里面的 `width('100%')` 会解析成比气泡更宽的值 ——
   * 必须用数值上限把正文约束在气泡内容框里（见 `bubbleContentWidth` 的注释）。
   * Agent / 工具 / 推理段走的是铺满宽度的列，不受影响，仍用 `messageBody`。
   */
  @Builder
  userMessageBody(message: TimelineMessage) {
    AaMarkdown({
      text: message.body,
      baseSize: FontSize.BODY,
      maxWidth: this.bubbleContentWidth
    })
  }


  @Builder
  toolMessage(message: TimelineMessage) {
    Column({ space: Space.XS }) {
      Row({ space: Space.S }) {
        // 上游 `TimelineChevron`（`SessionMessages.kt:2096` = Lucide.ChevronDown 16dp，折叠时旋转 -90°）
        AaIcon({
          d: this.expandedIds.includes(message.id) ? ICONS['chevron-down'] : ICONS['chevron-right'],
          iconSize: FontSize.ICON_MD,
          color: muted()
        })
        Text(message.title)
          .fontSize(FontSize.SMALL)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (message.exitCode !== undefined) {
          Text(`exit ${message.exitCode}`)
            .fontSize(FontSize.CAPTION)
            .fontColor(message.exitCode === 0
              ? $r('app.color.runtime_running') : $r('app.color.error_text'))
        }
      }
      .width('100%')

      if (message.subtitle.length > 0 && this.expandedIds.includes(message.id)) {
        Text(message.subtitle)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      }
      if (this.expandedIds.includes(message.id)) {
        AaMarkdown({ text: message.body, baseSize: FontSize.SMALL })
      }
    }
    .width('100%')
    .padding(Space.M)
    .borderRadius(Radius.M)
    .backgroundColor($r('app.color.session_timeline_activity_surface'))
    .onClick(() => {
      const index = this.expandedIds.indexOf(message.id);
      if (index >= 0) {
        this.expandedIds.splice(index, 1);
      } else {
        this.expandedIds.push(message.id);
      }
      this.expandedIds = this.expandedIds.slice();
    })
  }

  // -------------------------------------------------------------------------
  // 推理段（思考过程）
  // -------------------------------------------------------------------------

  /** 参与渲染的段：投影层已算好，这里再补一次上游折叠行右侧的回落（段为空但正文非空白）。 */
  private reasoningSegments(message: TimelineMessage): string[] {
    return effectiveReasoningSegments(message.reasoningSegments, message.body);
  }

  /** 折叠行标题的三态（上游 `val title = when { inlineSummary != null … }`）。 */
  private reasoningLabel(message: TimelineMessage): string {
    const segments = this.reasoningSegments(message);
    return reasoningTitle(segments, inlineSummaryFor(segments));
  }

  /** 能否展开（上游 `segments.isNotEmpty() && inlineSummary == null`）：能一眼总结完的就不给展开。 */
  private reasoningExpandable(message: TimelineMessage): boolean {
    const segments = this.reasoningSegments(message);
    return isReasoningExpandable(segments, inlineSummaryFor(segments));
  }

  /**
   * 推理段 —— 对应上游 `SessionMessages.kt:1530` 的 `ReasoningSection`。
   *
   * 折叠态一行：`heightIn(min = 34.dp)` + `padding(horizontal = 6.dp, vertical = 6.dp)`，内容 =
   * [chevron（仅可展开时）] [Lucide Sparkles 图标 16dp / tint muted] [13sp Monospace 单行标题 / Ellipsis / weight(1)]；
   * 展开态：左缩进 30dp 内用 Markdown 渲染 `segments.join('\n\n')`（上游 `AgentMarkdownText(compact = true)`）。
   *
   * ⚠️ 与上游的一处**已知差异**（如实记录，不自创形态）：
   *  · 上游展开时用 `listState.dispatchRawDelta(delta)` 锁住滚动位置防跳动；本工程是 ArkUI `List`，
   *  展开发生在**列表项内部**（该项上方兄弟项的位置不变），没有对应的锚定动作可加。
   */
  @Builder
  reasoningSection(message: TimelineMessage) {
    Column({ space: Space.S }) {
      Row({ space: Space.S }) {
        if (this.reasoningExpandable(message)) {
          // 上游 `TimelineChevron`（`SessionMessages.kt:2096` = Lucide.ChevronDown 16dp，折叠时旋转 -90°）
          AaIcon({
            d: this.expandedIds.includes(message.id) ? ICONS['chevron-down'] : ICONS['chevron-right'],
            iconSize: FontSize.ICON_MD,
            color: muted()
          })
        }
        // 上游 `Icon(imageVector = Lucide.Sparkles, tint = muted, modifier = Modifier.size(16.dp))`
        AaIcon({ d: ICONS['sparkles'], iconSize: FontSize.ICON_MD, color: muted() })
        Text(this.reasoningLabel(message))
          .fontSize(FontSize.SMALL)
          .fontFamily(REASONING_MONO_FAMILY)
          .fontColor(ink())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .constraintSize({ minHeight: REASONING_ROW_MIN_HEIGHT })
      .padding({
        left: Space.XS_PLUS, right: Space.XS_PLUS, top: Space.XS_PLUS, bottom: Space.XS_PLUS
      })
      // 上游只在 `expandable` 时挂 `noRippleClickable`；ArkUI 无法在链式调用里条件挂修饰符，
      // 所以常挂、在回调里先判 —— 对用户等价（不可展开时点了没有任何变化）。
      .onClick(() => {
        if (!this.reasoningExpandable(message)) {
          return;
        }
        const index = this.expandedIds.indexOf(message.id);
        if (index >= 0) {
          this.expandedIds.splice(index, 1);
        } else {
          this.expandedIds.push(message.id);
        }
        this.expandedIds = this.expandedIds.slice();
      })

      if (this.reasoningExpandable(message) && this.expandedIds.includes(message.id)) {
        Column() {
          AaMarkdown({
            text: this.reasoningSegments(message).join('\n\n'),
            baseSize: FontSize.SMALL
          })
        }
        .width('100%')
        .padding({ left: REASONING_BODY_INDENT, right: Space.XS_PLUS })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------------------------------
  // 输入区
  // -------------------------------------------------------------------------

  /**
   * 单个定位圆钮（「滑到顶部」挂在**对话顶端**、「滑到底部」挂在**对话框上边**）。
   *
   * ⚠️ 这里前后改过两轮，两轮的坑不一样，都记下来：
   *  · **二改**（「设计不对」）：原先是**一个铺满宽度的 `Row` 装两个钮**，用户看到的就是
   *  「一条横条遮罩」，而且两个钮并排在同一处，与「到顶 / 到底」两个方向该出现的位置对不上。
   *  · **三改**（「底部按钮仍有横条遮罩」）：二改把底部那个钮放进了输入区 `Column` ——
   *  而那个 `Column` **整条挂着毛玻璃**（需求 1 要的「下方对话框加模糊」），钮被包在里面，
   *  视觉上就是「横条上长了一个按钮」。现在它**移出输入区**，悬浮在输入区**上方**。
   *
   * ⇒ 最终形态：两个钮都是**独立节点**，宽度只有 38vp，不铺满、不遮罩、各自只吃自己那一小块
   * 命中区；顶部那个放页面根 `Stack`（`Alignment.Top` 居中），底部那个放内容层（贴底 +
   * `margin.bottom = 输入区高度 + 间距`）。
   *
   * **判据**：凡是「悬浮小控件」，**不要把它放进任何一个带背景/毛玻璃的容器里** ——
   * 那个容器的底会跟着它一起被看见，用户看到的就是「控件 + 一条横条」。
   *
   * 观感：与顶栏、输入区同一套毛玻璃（玻璃色比那两块**实一些**，保证箭头压在任意内容上都看得清）。
   * 可见性：**默认隐藏**，只在滚动时短暂出现（见 `showScrollButtons`）。
   */
  @Builder
  scrollButton(iconPath: string, label: string, onTap: () => void) {
    Row() {
      AaIcon({ d: iconPath, iconSize: FontSize.ICON_MD, color: ink() })
    }
    .width(Control.ICON_BUTTON)
    .height(Control.ICON_BUTTON)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.PILL)
    .backgroundEffect({
      radius: GLASS_BLUR_RADIUS,
      saturation: GLASS_SATURATION,
      brightness: GLASS_BRIGHTNESS,
      color: glassButtonSurface()
    })
    .accessibilityText(label)
    .onClick(onTap)
  }

  @Builder
  composer() {
    // ⚠️ 「滑到底部」那个钮**不在这里**：它在输入区**上方**独立悬浮（见 build 的内容层），
    // 因为本 `Column` 挂着毛玻璃 —— 把钮放进来就会被包成「横条上长了个按钮」。
    //
    // ## R79（用户：「**对话框和没改前位置一样**，只把文字移到底部，
    //  再在底部加上**和对话框一样的模糊**，**覆盖到整个底部区域**」）
    //
    // ## R92 一改（用户：「将对话时对话框和下方文字的**模糊融合**，即从**对话框上边缘往下统一模糊**，
    //  现在对话框和下方内容有一些**漏出来的部分**，不够美观」）
    //
    // ### 病根（R79 那套的两个盲区）
    // R79 起是**两块各管一段**的玻璃：① 卡片自己（圆角 22 的那一块）+ ② 卡片下方的底部带。
    // 两块的 `y` 区间**不连**：
    //  · **卡片左右 Space.L(16vp) 宽的那两条缝**（卡片在输入区里还有 16vp 的左右内边距，
    //  而圆角外侧那一段既不在卡片里、也不在底部带里）⇒ 时间线正文原样露出来；
    //  · 忙碌行出现时，卡片被往下推，**卡片与底部带之间**还会再裂开一段。
    // 用户看到的「漏出来的部分」就是这两处。
    //
    // ### 修法：把两块合并成**一整块连续底**
    // ```
    // Column ← 全宽，**没有左右内边距**
    //  Column({space}) ← ① 输入区：左右 Space.M、**透明**
    //  忙碌提示行 / 指令面板 / composerCard() ← （卡片自己也已改透明）
    //  Stack({alignContent: Bottom}) ← ② **一整块模糊底**（全宽、无圆角、铺到屏幕最底）
    //  Column(){ headerMeta() } ← 钉在块底 ← 元信息行（`.padding.bottom` = 手势条避让）
    //  Column(){ headerMeta() } ← 量「下段」实高 ← 卡片的下外边距**直接取这个量**（恒等）
    //  Column(){ composerCard() } ← 卡片浮在同一块底上：
    //  .margin.bottom = 下段高（恒等，只兜首帧） ⇒ 卡片位置与 R79 逐字相同
    // ```
    // · 块内**从卡片上沿开始**（顶上没有别的孩子）⇒ 用户要的「从对话框上边缘往下统一模糊」；
    // · 块只负责**画玻璃**，里面三个孩子负责**占位** ⇒ 位置全由 padding / margin 精确摆，
    //  不再依赖「两块各自的高度凑巧接得上」；
    // · 卡片与元信息行在 `Stack` 里**都没有上下内边距** ⇒ 小字仍紧贴卡片下沿（R79 的「不要间隔」保持）。
    //
    // ### ⚠️ 这不是推翻 R37 四改
    // R37 四改否决的是「在**这一层**挂一整条**横跨全宽、把卡片左右留白和上下留白全糊进去**」的玻璃带。
    // R79 的读法（本轮沿用）是「玻璃可以是全宽的，只要它**不跑到卡片顶上去**」：
    // 块的顶边**恰好压在卡片上沿**（它里面最上面那个孩子就是卡片）⇒ 不存在「把卡片顶上那一截
    // 也糊了」的横带 —— 忙碌行与指令面板都在块**上方**，一个字都没被糊。
    //
    // ### ⚠️ 位置**没有动**（R79 的硬约束「对话框和没改前位置一样」逐字未变）
    //  改前：卡片 = 输入区（上 padding Space.M）+ 底部带（元信息行 + `composerBottomInset()`）两盒摞起来；
    //  现在：卡片的下外边距**就等于**块底「下段」的实高（元信息行 + 手势条），
    //  卡片下沿之下仍然是那同一段 ⇒ y 逐字相同（实测读数由真机 dump 复核）。
    // ⚠️ 稳态下卡片的下外边距 = 下段的实测高（元信息行 + 手势条避让）⇒ 上面那段推演逐字成立；
    //  只有**首帧**（实测值还没到）走 `composerBottomSpan()` 兜的 8vp。
    //
    // ⚠️ 块的模糊与底色取**卡片同一套令牌**（`glassCardSurface()` + `GLASS_BLUR_RADIUS`）——
    //  「和对话框一样的模糊」；卡片自身的两条同名属性本轮**撤掉**（见 `composerCard()`），
    //  由这一块统一供给 ⇒ 只有**一层**模糊、同一半径，卡片圆角外与卡片下方不会再有色差/接缝。
    // ⚠️ **不动**卡片的描边与阴影（R79 起就在卡片上）：它们描述的是「卡片这个形状」；
    //  块是铺满全宽、直通屏幕底的一条，给它描边/圆角会让它看起来像第二张卡（R79 的判据）。
    Column() {
      // ① 输入区（位置/尺寸与改前逐字一致）
      Column({ space: Space.S }) {
      // ⚠️ R37 九改（用户要求「对话在模型执行任务时，在对话框左上方显示『深度求索中...』」）：
      // 输入卡**上方靠左**一行状态 —— 蓝字（`deepseekAccent()`，与用户给的参考图同色）+
      // 灰色秒数。只在模型执行中（`canInterrupt` = running / waiting / pending）出现。
      // 秒数由 `syncBusyTimer()` 每秒刷新，起止点在 `pull()` 里按状态翻转驱动。
      if (this.canInterrupt) {
        Row() {
          Row({ space: Space.XS }) {
            // ⚠️ R37 十改（用户要求「字体逐个循环跳动」）：文字拆成**单字**逐个上抬再落回，
            // 形成从左到右的循环波浪。`waveStep` 由 `syncBusyTimer()` 里的 160ms 定时器推进，
            // 与秒表同生共死 —— 会话空闲时定时器停、整条提示也随之消失（用户要求「空闲时自动消失」）。
            Row({ space: 0 }) {
              ForEach(BUSY_LABEL_CHARS, (ch: string, index: number) => {
                Text(ch)
                  .fontSize(FontSize.SMALL)
                  .fontColor(deepseekAccent())
                  // 抬起来的永远是**当前那一位**，其余落回 0 ⇒ 逐个跳。
                  .translate({ y: index === this.waveStep ? BUSY_WAVE_LIFT : 0 })
                  // 隐式动画：状态一变就补间，不用自己写 animateTo。
                  .animation({ duration: BUSY_WAVE_STEP_MS, curve: Curve.EaseInOut })
              }, (ch: string, index: number) => `busy-ch-${index}`)
            }
            .alignItems(VerticalAlign.Center)
            Text(`${this.busySeconds}秒`)
              .fontSize(FontSize.SMALL)
              .fontColor(muted())
          }
          // ⚠️ 必须给个**够实**的底：输入区这一层是浮层，背后是滚动的正文。
          // 首版没加底 —— 真机实测这行字与背后的正文叠在一起、根本读不出来（坑 217 同源）；
          // 第二版用 70% 的玻璃色仍偏透，最终取 `glassPanelSurface()`（alpha ≈ 85%）+ 1px 描边，
          // 做成一个小药丸：既能看清字，也不像一颗实心按钮那么抢眼。
          .padding({ left: Space.M, right: Space.M, top: 5, bottom: 5 })
          .borderRadius(Radius.PILL)
          .backgroundColor(glassPanelSurface())
          .borderWidth(StrokeWidth.HAIRLINE)
          .borderColor(borderColor())
          .backgroundEffect({
            radius: GLASS_BLUR_RADIUS,
            saturation: GLASS_SATURATION,
            brightness: GLASS_BRIGHTNESS,
            color: glassPanelSurface()
          })
        }
        .width('100%')
        // 靠左：`Column` 默认 `alignItems = Center`，不显式声明会被居中。
        .justifyContent(FlexAlign.Start)
      }
      // R52：指令面板（内联在输入卡**上方**）—— 打开时把卡片往上顶，不遮正文。
      if (this.commandPanelOpen) {
        this.commandPanel()
      }
      // ## R92：输入卡片**搬进了模糊块**（本层里没有卡片了）
      //
      // 卡片原来挂在这里（输入区 `Column` 里、底部带的上方）。R92 要「从卡片上沿往下统一模糊」：
      // 底块必须与卡片**同处一个 `Stack`**，才能把它包进去（块的顶边 = 卡片上沿、
      // 且右侧铺满屏宽、圆角外与卡片下方连成一片）。卡片留在这儿就只能是一块**独立**的玻璃。
      // ⇒ 卡片改为渲染在下面那个 `Stack` 里。
      //
      // ⚠️ **本层不需要留等高的空位**：卡片的高度原样出现在下面 `Stack` 的高度里
      //  （块高 = 卡片高 + 下段高）⇒「输入区高度 + 模糊块高度」与改前的
      //  「输入区 + 卡片 + 底部带」**逐字相同** ⇒ `composerHeight`（本层实测总高）继续
      //  反映真实遮挡高度、`contentEndOffset` 自动正确。留空位反而会把卡片高度算两遍。
      // ⚠️ **只读（未接管）时卡片也保持完整形态**（与安卓一致），这条口径**未变** ——
      //  卡片只是换了渲染位置，内部一个字没动（仍见 `composerCard()`）。
      }
      .width('100%')
      // 左右/上内边距仍在**输入区**这一层（与改前逐字一致）；**底边距为 0** ⇒
      // 它下沿正好接上模糊块的上沿（用户「不要间隔」）。
      // ⚠️ 底部避让必须走 **padding 而不是 margin**：margin 会在毛玻璃之外留一条缝，
      //  时间线内容就从那道缝里**直接露出来**（真机首轮截图可见「未被手势条压住 ✓…」那行）。
      //  现在这条避让挂在**模糊块里元信息行容器的下内边距**上（见下），效果相同。
      // ⚠️ R92：这一层**没有底、没有模糊**（R79 起就没有，本轮继续保持）—— 它只是个摆位容器；
      //  它下方紧跟着的模糊块从卡片上沿起画，两者在同一坐标系里严丝合缝。
      .padding({ left: Space.M, right: Space.M, top: Space.M })

      // ② **一整块模糊底**（R92 起取代 R79 的「底部模糊带」）：全宽 + 无圆角 + 无描边，
      //  从**输入卡片上沿**一路铺到屏幕最底。
      //
      // ## 为什么是 `Stack` 而不是 R79 那条 `Column`
      // R79 那条是**内容块**：元信息行把它撑多高、它就多高，卡片在它**外面**（上面的兄弟）——
      // 于是「卡片四周」与「卡片下方」是两块各自独立画的玻璃，接缝与圆角外的空档都露着正文。
      // 现在反过来：这块底只负责**画玻璃**，高度由**内容自己撑**；
      // 里面两个孩子负责**占位**，用 padding / margin 精确摆到该在的位置。
      // ⚠️ 它就是 `Column` 的直接孩子、而外层 `Column` **没有左右内边距** ⇒ 天然铺满屏宽。
      // ⚠️ **它从卡片上沿开始画**（用户：「从对话框上边缘往下统一模糊」）：
      //  块内只有「卡片」与「下段（元信息行）」两个孩子，顶上没有任何东西 ⇒ 玻璃的顶边 = 卡片上沿。
      //  「糊到卡片顶上去」的横带是 R37 四改否决的形态，见上面那段 —— 本形态不是它。
      Stack({ alignContent: Alignment.Bottom }) {
        // ---- 下段：卡片下沿 → 屏幕底（元信息行 + 手势条避让） ----
        // ⚠️ 它是 `Stack` 里**卡片之外唯一有高度**的孩子，卡片的下外边距**直接等于它的实测高度**
        //  ⇒ 一个稳定的不动点：卡片被推上去多少、块就长出多少，块底永远贴着屏幕底、
        //  卡片上沿永远在同一个 y。
        //  （R92 首版让卡片用「块高 − 卡片高」做 margin ⇒ 方程变成 `块高 = 块高 + 手柄档`，
        //  **没有不动点、每帧涨 8vp**；再早一版把量测挂在**空的** `Column` 上 ⇒ 恒量到 0。
        //  两个坑都记在这里：**量测必须挂在一个真有高度的盒子上**。）
        Column() {
          this.headerMeta()
        }
        .width('100%')
        // 下内边距 = `composerBottomInset()`：让出**手势条**（不是全额安全区，见 `COMPOSER_BOTTOM_*`
        // 的注释与 [坑 180]，口径 R13-15 / R37 起逐字未变，本轮只换了个挂点）。
        .padding({ left: Space.M, right: Space.M, bottom: this.composerBottomInset() })
        // 实测**下段**高度（元信息行 + 手势条避让）—— 卡片的下外边距**直接用它**，
        // 不做任何加减 ⇒ 没有 `坑 248` 那种「让位量进了被测量元素盒子」的环：
        // 本盒子在卡片**外面**，它的高度与卡片的高度互不相干（也不含卡片的下外边距）。
        // ⚠️ `padding.bottom` **已经量在里面**了 ⇒ 卡片侧只做「赋值」、绝不再加一次
        //  `composerBottomInset()`（R92 首版就是那么重复计了一遍，卡片被顶高 ~16vp）。
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const next = Number.parseFloat(`${newValue.height}`);
          if (next > 0 && Math.abs(next - this.composerBottomSpanHeight) > 0.5) {
            this.composerBottomSpanHeight = next;
          }
        })

        // ---- 输入卡片：浮在**同一块**底上（`Stack` 最后一个孩子 ⇒ 画在最上层） ----
        Column() {
          this.composerCard()
        }
        .width('100%')
        // 左右内边距与 R79 **逐字一致**（卡片原来在输入区里就是左右 `Space.M`）⇒ 卡片宽度未变。
        .padding({ left: Space.M, right: Space.M })
        // ⚠️ **恒等于上面那个盒子的实测高度**（同一个量，只做赋值）：卡片下沿因此**永远**落在
        //  「元信息行 + 手势条避让」之上，与 R79 逐字同位置；而块高 = 卡片高 + 本值 ⇒
        //  块顶边**恰好落在卡片上沿**（用户：「从对话框上边缘往下统一模糊」）。
        .margin({ bottom: this.composerBottomSpanHeight })
        // 实测卡片自身高度 ⇒ `composerGlassBlockHeightVp()` 据它算「卡片上沿 → 屏幕底」。
        // ⚠️ 量的是**卡片自己**（本 `Column` 的高度就由它撑出）——它只影响「卡片自己多高」，
        //  与块高/自身位置无关 ⇒ 不构成反馈环。
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const next = Number.parseFloat(`${newValue.height}`);
          if (next > 0 && Math.abs(next - this.composerCardHeight) > 0.5) {
            this.composerCardHeight = next;
          }
        })
      }
      .width('100%')
      // 高度**不写死**：由「卡片 + 卡片的下外边距」撑出来，而那个外边距又恒等于块底的「下段」，
      // 于是块高 = 卡片高 + 下段高 = `composerGlassBlockHeightVp()` ⇒ 顶边恰好落在卡片上沿。
      // ⚠️ 不能用 `layoutWeight`：那样它会吃掉 `Column` 的剩余高度、把块拉到整屏高。
      // ⚠️ `padding.bottom` 一个字都**不**加：卡片的下外边距已经把「下段」让出来了，
      //  再加一次会重复计。
      // —— 与 `composerCard()` 改前**逐字同一套**：用户要的「和对话框一样的模糊」——
      //  R92 起卡片自己那两条同名属性撤掉，改由这一块统一供给（同一半径、同一底色 ⇒ 无接缝）。
      .backgroundColor(glassCardSurface())
      .backgroundEffect({
        radius: GLASS_BLUR_RADIUS,
        saturation: GLASS_SATURATION,
        brightness: GLASS_BRIGHTNESS,
        color: glassCardSurface()
      })
    }
    .width('100%')
    // ⚠️ **R79 起这一层是「空壳」**：没有任何内边距、没有底、没有模糊 —— 两个孩子在管：
    //  ① 输入区那层管左右/上内边距；② 模糊块管自己的高度、模糊与下内边距。
    //
    // ⚠️ **R37 四改的结论仍然有效，别推翻**：当年用户反馈「底部对话框的模糊效果不对」——
    //  原因是把毛玻璃挂**在这一层**，于是画出一条**横跨全宽、把输入卡左右两侧和上下留白
    //  全糊进去**的玻璃带。所以：**本层不许挂玻璃**（R79 至今未变）。
    //  R92 的整块底**不是**推翻它：它是 `Column` 里的一个**普通孩子**，上推量 = 卡片高度
    //  ⇒ 它的顶边**恰好落在卡片上沿**，卡片的**上方**（忙碌行、指令面板）一个字也没被糊。
    //  ⚠️ 与 R79 那条底部带的区别只在于「它现在把卡片那一截也盖上了（卡片自己不再画玻璃）」——
    //  这正是用户本轮要的「融合」；「不跑到卡片顶上」这条约束两边一致。
    //
    // ⚠️ 底部避让（手势条）现在挂在**模糊块里那个元信息行容器的 `padding.bottom`**：
    //  R13-15 让出安全区、R37「只避开手势条就行」的口径（见 `COMPOSER_BOTTOM_*` 与 [坑 180]：
    //  **不要**写成 `max(安全区, 目标)`）**都逐字未变**，只是换了个挂点。
    // ⚠️ 走 **padding 而不是 margin**：margin 会在玻璃之外留一条缝，时间线内容会从那道缝里
    //  **直接露出来**（真机首轮截图可见「未被手势条压住 ✓…」那行）。
    //
    // ## R92：`composerHeight` 的语义**一个字没动**
    // 它继续是「本层实测总高（输入区 + 模糊块）」，继续只喂 `contentEndOffset` 与阻塞公告的
    // `margin.bottom` —— 那两处要的正是「整条遮挡有多高」，不能改。
    // ⚠️ 圆钮**不再消费它**（改前 `margin.bottom = composerHeight + Space.S` 正是 busy 行顶动
    //  圆钮的根因），改用同源的 `composerGlassBlockHeightVp()`。
    // ⚠️ 实测自身高度交给时间线做 `contentEndOffset`（同顶栏，只在真的变了才写 @State）——
    //  它现在量的是**输入区 + 模糊块**整条（与 R79 逐字同一个量）。
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const next = Number.parseFloat(`${newValue.height}`);
      if (next > 0 && Math.abs(next - this.composerHeight) > 0.5) {
        this.composerHeight = next;
      }
    })
  }

  /**
   * 输入卡片（上排输入框、下排动作行）：对应上游 `SessionComposer.kt` L140-151 那层圆角容器
   * （`heightIn(min = 104.dp, max = 218.dp)` + 22dp 圆角），内部三段同序：
   * 附件条 / `BasicTextField` / `ComposerActions`。
   */
  @Builder
  composerCard() {
    // 子元素间距 10dp（上游 `Arrangement.spacedBy(10.dp)`，L150）
    // ⚠️ **R79 试过「把元信息行并进卡片」并被用户否决**（原话：「对话框和没改前位置一样」）——
    //  并进去会让卡片变高 ⇒ 卡片位置上移。现在卡片**一个字没动**，元信息行挂在 `composer()`
    //  那层的**整块模糊底**里（`Stack` 里、卡片下方；见那里的结构与几何推演）。
    Column({ space: Space.S_PLUS }) {
      if (this.composerFileCount() > 0) {
        Row({ space: Space.S }) {
          if (this.prepared) {
            // R54：草稿态的附件只有**本地 URI**（还没上传、自然也没有 fileId）。
            ForEach(this.preparedAttachments, (file: LocalAttachment) => {
              AaChip({ label: localAttachmentLabel(file) })
            }, (file: LocalAttachment) => localAttachmentKey(file))
          } else {
            ForEach(this.attachedFiles, (file: PendingAttachment) => {
              AaChip({ label: file.name })
            }, (file: PendingAttachment) => file.fileId)
          }
          Text('清空')
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .onClick(() => {
              if (this.prepared) {
                this.store.clearPreparedAttachments();
                this.pull();
                return;
              }
              this.attachedFiles = [];
            })
        }
        .width('100%')
      }

      // ⚠️ 只读态下 `TextArea` 被 `.enabled(false)` 禁用，**它不再接收点击事件** ——
      // 把 `onClick` 直接挂在它身上是无效的（真机实测：点了没反应，接管弹窗永远不出现）。
      // 早期做法是在输入框上盖一层「空文本 + 100% 宽高」的透明命中层；
      // R13-14 真机量测证明**那一层把 Stack 撑高了约 27vp**（输入卡总高 406px vs 安卓 310px），
      // 所以改成：`onClick` 挂在 `Stack` 自己身上（禁用子节点不消费事件，父层收得到），
      // 命中层删掉 —— 点击语义不变，高度回到内容高度。
      Stack() {
        TextArea({
          text: composerInputText(this.draft, this.readOnly),
          placeholder: this.composerPlaceholder
        })
          // 数值逐条对齐上游 `SessionComposer.kt` L167-175：正文 16sp Medium、行高 21sp、
          // 高度 min 28dp、max 92dp（**有附件时收到 40dp**，给附件条让位 —— L126 的 textFieldMaxHeight）。
          .fontSize(16)
          .lineHeight(21)
          .fontWeight(FontWeight.Medium)
          .constraintSize({ minHeight: 28, maxHeight: this.composerFileCount() > 0 ? 40 : 92 })
          .width('100%')
          .borderRadius(Radius.M)
          // 描边由卡片那一层负责（上游的 `BasicTextField` 也没有边框），这里再画一圈会是双线
          .borderWidth(0)
          .backgroundColor(Color.Transparent)
          // 只读态禁用输入：**不能**只把发送按钮变灰 —— 用户仍会打字、点发送、
          // 然后收到一条看不懂的英文 409（真机实测）。上游同样在只读时
          // `enabled = inputEnabled`（`SessionComposer.kt` L164）并只读时把显示串置空（L1686）。
          .enabled(composerInputEnabled(this.readOnly))
          .onChange((value: string) => {
            // ⚠️ 只读时 `text` 被 `composerInputText()` 恒定成空串，而**程序改 text 同样会触发
            // 这个回调**（R8 复验 6 帧 0 命中的原根因就是「程序回填也走 onChange」）。
            // 那一次不是用户输入，绝不能让它把 `this.draft` 写没了 —— 草稿要原样等着接管后回来。
            if (this.readOnly) {
              return;
            }
            this.draft = value;
            // ⚠️ 这里**不要**去清草稿恢复提示：程序把恢复出来的文本回填进输入框时也会走到这个回调，
            // 在这里清提示等于把提示清在同一次重绘里（R8 复验 6 帧 0 命中的根因）。
            // 提示的显示条件由 `draft` 与 `draftRestoreSnapshot` 的比较推导，见 build 里的用法。
            // 每敲一个字就落盘：数据量很小（一条草稿几 KB），换来「切会话/被杀都不丢」
            this.saveDraft(value, this.attachedFiles);
          })
          // 运行中主按钮是「中断」（与上游一致：`showInterrupt` 只看运行时状态），
          // 此时**唯一的发送入口就是输入法的发送键** —— 上游 Android 用的是
          // `KeyboardOptions(imeAction = ImeAction.Send)` + `KeyboardActions(onSend = …)`。
          // 少了这一条，Agent 跑起来之后就没法 steer 了（真机实测：只能等它跑完）。
          .enterKeyType(EnterKeyType.Send)
          .onSubmit(() => {
            if (this.canSubmit()) {
              this.send();
            }
          })

      }
      .width('100%')
      .constraintSize({ minHeight: 28, maxHeight: this.composerFileCount() > 0 ? 40 : 92 })
      // 只读时点输入区 = 请求接管（上游的双击手势在手机上既不可发现、又容易和「选中文字」撞车，
      // 这里改成单击直接给确认框）。挂在这一层是刻意的：`TextArea` 被禁用后不吃事件，父层收得到。
      .onClick(() => {
        if (this.readOnly) {
          this.promptTakeover();
        }
      })

      // 动作行：与上游 `ComposerActions`（`SessionComposer.kt` L525-532）同构 ——
      // 两端 `SpaceBetween`，左侧从左到右依次是「指令」「接管开关」（两者间距 9dp，L533），
      // 主按钮（发送 / 中断）单独贴最右。次序与 `COMPOSER_ACTION_ORDER` 一一对应。
      //
      // ⚠️ R52：左侧第一位**由「+ 附件」改成「指令」**（用户要求）——「添加文件」移进指令面板，
      // 不再单独占一个按钮。主按钮左边新增**上下文圆环**（拿不到用量时不占位）。
      Row() {
        Row({ space: Space.TIGHT }) {
          // R53：草稿态**不复用另一套动作行**（用户明确要求「进入的对话要和原对话页面一样，
          // 不要再搞一个页面设计」）。两个按钮照常渲染，只是草稿态下点不动：
          //  · 接管开关：takeoverBusy 在草稿态恒真（上游 preparedSession 同款）⇒ 组件自己是禁用态；
          //  · 指令按钮：目录要 sessionId，草稿态点它只给一句提示（不弹空面板）。
          this.commandButton()
          this.takeoverSwitch()
        }
        .alignItems(VerticalAlign.Center)

        Row({ space: Space.S }) {
          this.contextRing()
          this.composerPrimaryButton()
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // 卡片数值对齐上游 `SessionComposer.kt` L143-150：
    // 圆角 22dp、阴影 28dp（0x12000000）、内边距 start16/top16/end16/bottom12、子元素间距 10dp。
    // ⚠️ 22 / 10 / 28 在 Design.ets 里都没有档位（圆角只有 8/12/16/PILL、间距只有 4/8/12/16/24/32），
    //  按 Lead 的「dp→vp 1:1 照抄」写数值，档位缺口已报给 Lead。
    .padding({ left: Space.L, right: Space.L, top: Space.L, bottom: Space.M })
    // 上游 `SessionComposer.kt:143` 的 `heightIn(min = 104.dp, max = 218.dp)`：
    // 只读态实测过 406px（≈137vp）—— 内容撑出来偏高，这里按上游把上下界钉死。
    .constraintSize({ minHeight: 104, maxHeight: 218 })
    .borderRadius(Radius.XXL)
    .borderWidth(1)
    .borderColor(borderColor())
    // —— 毛玻璃（R37 四改：从输入区那层搬到这里；**R92 起又搬出去**）——
    //
    // ## R92：底色 / 模糊**撤掉**，移交 `composer()` 里那块「从卡片上沿铺到屏幕底」的整块底
    // 理由（用户：「将对话框和下方文字的模糊**融合**……现在有一些**漏出来的部分**」）：
    // 卡片这块玻璃原先**只覆盖圆角 22 的内侧**，圆角外、以及卡片与下方底部带之间没有任何
    // 模糊层 ⇒ 时间线正文从那些缝里原样露出来。两块独立玻璃也各画各的边，
    // 观感上是「卡片 + 挂件」而不是一个整体。
    // ⇒ 现在**只有一层**玻璃（整块底的），卡片与元信息行都浮在它上面，圆角内外的糊化程度
    //  **完全相同** —— 这就是「模糊融合」。
    // ⚠️ 卡片位置/尺寸**一个字没动**：它仍然在原来那个 y、仍然是 `Radius.XXL` 的圆角 + 1px 描边
    //  + 阴影（`padding.left/right/top = Space.L`、`bottom = Space.M`、左右外再各让 `Space.M`）。
    // ⚠️ 描边与阴影**保留在卡片上**（没有下放到底块）：它们描述的是**卡片这个形状**；
    //  底块是「铺满全宽、直通屏幕底」的一条，给它描边/圆角会让它看起来像第二张卡（R79 的判据）。
    // 阴影的扩散半径走 Shadow 令牌（**不是圆角**）
    // ⚠️ R57 Lead 裁决：输入卡阴影**保留**字面量 `#12000000`（7% 黑，深浅同值）。
    // 换 `appShadow()` 会让深色下从 7% 跳到 32%（4.5 倍）—— 输入卡本来就靠 70% 玻璃底立形，
    // 再加一档重阴影会把「毛玻璃」压成「实心卡片」，与 R37 四改的初衷相反。
    .shadow({ radius: Shadow.CARD, color: '#12000000' })
  }

  /**
   * R52：**指令按钮**（动作行左侧第一位，取代原来的「+ 附件」）。
   *
   * 上游没有这个按钮（上游只有「打 `/` 出建议」那条路）—— 这是用户要求的形态：
   * 左下角一个按钮，点开列出**该会话可用的指令**（DSH 原生 `/compact`、`/plan`… 与「添加文件」）。
   * 数据走官方接口 `GET /sessions/{id}/runtime/commands`（能力 `session.commands`）。
   *
   * ⚠️ 面板是**内联区块**（见 `commandPanel()`），不是 `bindSheet`：
   * 根节点上只能挂一个 `bindSheet`，而附件大图已经占着它（开发期冒烟 D2 的根因）。
   */
  @Builder
  commandButton() {
    Row() {
      AaIcon({ d: ICONS['square-terminal'], iconSize: FontSize.ICON, color: ink() })
    }
    .width(30)
    .height(30)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Radius.PILL)
    .backgroundColor(this.commandPanelOpen ? rowPressedSurface() : Color.Transparent)
    .onClick(() => {
      if (this.readOnly) {
        this.promptTakeover();
        return;
      }
      this.toggleCommandPanel();
    })
  }

  /**
   * R52：**上下文圆环**（主按钮左边）。
   *
   * 数据：`runtimeState.metadata.contextPressure`（DSH token-meter 投影，经 bridge 补丁透传）。
   * ⚠️ **拿不到就不画**（`known=false`）—— 宁可没有，也不要给一个瞎猜的分母。
   */
  @Builder
  contextRing() {
    if (this.contextUsage.known) {
      Stack() {
        Progress({
          value: this.contextUsage.ratio * 100,
          total: 100,
          type: ProgressType.Ring
        })
          .width(22)
          .height(22)
          .color(this.contextRingColor())
          .backgroundColor(subtle())
          .style({ strokeWidth: 3 })
        Text(`${Math.round(this.contextUsage.ratio * 100)}`)
          .fontSize(9)
          .fontColor(muted())
      }
      .width(22)
      .height(22)
      .accessibilityText(`上下文用量 ${contextUsageLabel(this.contextUsage)}`)
    }
  }

  /** 圆环颜色：ok 走主色、warn/critical 走告警/错误色（档位判据在 `model/ContextUsage.ets`）。 */
  private contextRingColor(): ResourceColor {
    if (this.contextUsage.level === 'critical') {
      return $r('app.color.error_text');
    }
    if (this.contextUsage.level === 'warn') {
      return $r('app.color.notice_warning');
    }
    return primaryAction();
  }

  /**
   * R52：指令面板（内联在输入卡上方）。
   *
   * 组成：标题 + 「添加文件」本地动作 + 官方指令目录（`session.commands`）。
   * 能力不可用 / 目录为空时**如实说明**（不假装有指令，也不静默给个空面板）。
   */
  @Builder
  commandPanel() {
    Column({ space: Space.XS }) {
      Row() {
        Text('指令')
          .fontSize(FontSize.CAPTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(muted())
          .layoutWeight(1)
        Text('收起')
          .fontSize(FontSize.CAPTION)
          .fontColor(primaryAction())
          .onClick(() => {
            this.commandPanelOpen = false;
          })
      }
      .width('100%')

      if (this.commandNotice.length > 0) {
        Text(this.commandNotice)
          .fontSize(FontSize.CAPTION)
          .fontColor(muted())
          .width('100%')
      }

      Scroll() {
        Column({ space: Space.XS }) {
          // R91：**来源行放在最上面** —— 用户必须一眼看出目录是服务端返回的还是客户端内置的
          //（见 model/SlashCommand.ets 的 catalogSourceLabel），否则会把「通道不可用」
          // 误读成「这个 App 有这些指令」。
          Text(catalogSourceLabel(this.commandCatalog, this.prepared))
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .width('100%')
            .padding({ left: Space.S, top: Space.XS })

          // 「添加文件」：本地动作（原来的「+」按钮做的事），放第一位保持肌肉记忆。
          // R54：草稿态它改成**只暂存本地**（首条消息随创建请求内联发出），可用性由
          // `runtime.attachment` 能力决定（服务端带附件创建时硬性要求它可用）。
          this.commandRow('添加文件',
            this.prepared ? inlineAttachmentRowDetail(this.preparedAttachmentsAllowed) : '图片 / 文件附件',
            ICONS['paperclip'],
            () => {
              this.commandPanelOpen = false;
              if (this.prepared) {
                this.pickDraftAttachment();
                return;
              }
              this.pickAttachment();
            },
            this.prepared ? this.preparedAttachmentsAllowed : true)

          if (this.commandLoading) {
            Text('正在读取指令…')
              .fontSize(FontSize.CAPTION)
              .fontColor(muted())
              .width('100%')
              .padding({ left: Space.S, top: Space.XS, bottom: Space.XS })
          } else if (this.commandCatalog.items.length === 0) {
            // R91：**不再有空面板**。服务端返回空目录时会用内置清单兜底（见
            // refreshCommandCatalog），所以走到这里只有「内置也空」这种理论分支。
            Text('没有可用的指令目录：内置清单为空，且服务端未返回任何指令。')
              .fontSize(FontSize.CAPTION)
              .fontColor(muted())
              .width('100%')
              .padding({ left: Space.S, top: Space.XS, bottom: Space.XS })
          } else {
            // R91：目录条目统一走 commandCatalog.items（内置 or 服务端，来源见上面那行）。
            ForEach(this.commandCatalog.items, (item: SlashCommandItem) => {
              this.commandRow(
                `/${item.id}`,
                this.commandRowDetail(item),
                ICONS['hash'],
                () => {
                  this.tapCommand(item);
                },
                this.commandUsable(item)
              )
            }, (item: SlashCommandItem) => `cmd:${item.id}:${item.sessionBound}:${item.enabled}:${this.prepared}`)
          }

          // R52/R91：服务端目录读取失败 ⇒ 给一条**可点的自救路径**（重试）。
          // 内置回落下它**仍然显示** —— 重试是把「内置清单」换成真目录的唯一出口。
          if (!this.prepared && this.commandError.length > 0) {
            this.commandRow('重新读取指令目录', this.commandError, ICONS['refresh'], () => {
              this.loadSessionCommands();
            }, true)
          }

          // R91 草稿态脚注：说清「这里点出来的指令走哪条路」——会话还不存在，
          // 所以只会填进输入框、随**首条消息**发给 Agent，不是 DSH 命令执行
          //（与已建会话那条 POST /runtime/commands 是两回事）。
          if (this.prepared && draftUsableCount(this.commandCatalog.items) > 0) {
            Text('草稿态：点指令只会把它填进输入框，随首条消息一起发给 Agent；作用于会话的指令（如 /compact）要等会话建立后才能用。')
              .fontSize(FontSize.CAPTION)
              .fontColor(muted())
              .width('100%')
              .padding({ left: Space.S, top: Space.XS, bottom: Space.XS })
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 220 })
      // 纵向 Scroll 必须显式顶对齐：内容短于视口时默认会被垂直居中（本工程有静态判据）。
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({ left: Space.L, right: Space.L, top: Space.M, bottom: Space.M })
    .borderRadius(Radius.XL)
    .backgroundColor(glassCardSurface())
    // —— R80：与 composerCard() **逐字同一套**毛玻璃（用户：「对话时点击添加弹窗背景比较透明，
    //  导致内容显示不清晰，优化」）——
    //
    // 根因：本面板原来**只有** glassCardSurface()（alpha ≈ 70%）而**没有 backgroundEffect**。
    // 70% 的半透明底挡不住背后**清晰的**时间线正文：真机上面板里的 /compact、/export…
    // 与被压住的正文字形互相竞争，面板自己的内容读不出来。
    // composerCard() 从 R37 四改起就是「底色 + 模糊」**两件套**（见该处注释），所以卡片背后的
    // 正文是**糊的**、卡片内的字清楚 —— 面板缺的正是这一层。
    // ⚠️ 参数**逐字**取卡片那四个令牌，颜色也取同一个 glassCardSurface() ⇒ 同一种玻璃，
    //  不引入第二套观感（与底部那条带、输入卡三者一致）。
    .backgroundEffect({
      radius: GLASS_BLUR_RADIUS,
      saturation: GLASS_SATURATION,
      brightness: GLASS_BRIGHTNESS,
      color: glassCardSurface()
    })
    .borderWidth(StrokeWidth.HAIRLINE)
    .borderColor(borderColor())
  }

  /** 指令面板里的一行（label 用等宽感的 `/id`，副标题是官方 description）。 */
  @Builder
  commandRow(label: string, detail: string, icon: string, onTap: () => void, usable: boolean) {
    Row({ space: Space.S }) {
      AaIcon({ d: icon, iconSize: FontSize.ICON_MD, color: usable ? ink() : muted() })
      Column({ space: 2 }) {
        Text(label)
          .fontSize(FontSize.SMALL)
          .fontWeight(FontWeight.Medium)
          .fontColor(usable ? ink() : muted())
          .width('100%')
        if (detail.length > 0) {
          Text(detail)
            .fontSize(FontSize.CAPTION)
            .fontColor(muted())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: Space.S, right: Space.S, top: Space.XS, bottom: Space.XS })
    .borderRadius(Radius.M)
    .opacity(usable ? 1 : 0.5)
    .onClick(() => {
      if (usable) {
        onTap();
      }
    })
  }

  /**
   * 开/关指令面板；打开时确保目录就绪。
   *
   * R91 修正：草稿态**也有目录**了（内置清单），所以这里不再分叉成「草稿态只开面板」——
   * 两种态都走 `refreshCommandCatalog()`：草稿态恒用内置目录（无网络请求），
   * 已建会话先看缓存、没有才打服务端。
   */
  private toggleCommandPanel(): void {
    this.commandPanelOpen = !this.commandPanelOpen;
    this.commandNotice = '';
    if (this.commandPanelOpen) {
      this.refreshCommandCatalog(false);
    }
  }

  /**
   * 刷新「当前该显示哪一份目录」——**双源收口点**。
   *
   * 三种结果（都会被如实显示，绝不退化成空面板）：
   *  ① 草稿态（`prepared`）：内置清单（`SlashCommandStore.draftCatalog()`）—— 没有 sessionId，
   *  打服务端只会拿到 404/能力错误，所以**一个请求都不发**；
   *  ② 已建会话 + 服务端可用：服务端目录（`remember()`）；
   *  ③ 已建会话 + 服务端不可用：内置清单 + **失败原因**（`rememberUnavailable()`）。
   *
   * `force` = true 时忽略缓存重新请求（「重新读取指令目录」那条自救路径）。
   */
  private refreshCommandCatalog(force: boolean): void {
    if (this.prepared) {
      this.commandCatalog = SlashCommandStore.get().draftCatalog();
      this.commandError = '';
      this.commandLoading = false;
      return;
    }
    if (!force) {
      const cached = SlashCommandStore.get().cached(this.sessionId);
      if (cached !== undefined) {
        this.commandCatalog = cached;
        this.commandError = cached.serverAvailable ? '' : cached.serverError;
        this.commandLoading = false;
        return;
      }
    }
    this.loadSessionCommands();
  }

  /** 一条指令此刻能不能点（草稿态额外拦`sessionBound`，见 model/SlashCommand.ets）。 */
  private commandUsable(item: SlashCommandItem): boolean {
    if (!item.enabled) {
      return false;
    }
    if (this.prepared) {
      return slashCommandUsableInDraft(item);
    }
    return true;
  }

  /** 指令行的副标题：不可用时用**服务端/内置给的原因**顶掉说明（用户要知道为什么点不动）。 */
  private commandRowDetail(item: SlashCommandItem): string {
    const unusableReason = this.prepared ? draftCommandDisabledReason(item) : '';
    if (unusableReason.length > 0) {
      return unusableReason;
    }
    if (!item.enabled && item.disabledReason.length > 0) {
      return item.disabledReason;
    }
    const parts: string[] = [];
    if (item.description.length > 0) {
      parts.push(item.description);
    }
    // 需要参数的指令把 DSH 原文 hint 显示出来（用户要照着它补参数，不能译）。
    if (item.acceptsArgs && item.hint.length > 0) {
      parts.push(`参数：${item.hint}`);
    }
    return parts.join(' · ');
  }

  /**
   * 点选一条指令 —— **两个场景分派点**。
   *
   * · 草稿态（`prepared`）：会话还不存在 ⇒ 只把指令**填进输入框**，随首条消息发给 Agent。
   *  作用于会话的指令（compact / export / file）在 `commandUsable()` 已被拦下，走不到这里。
   * · 已建会话：沿用 R52 的两种形态 —— 需要参数只插草稿，否则走 `POST /runtime/commands`。
   */
  private tapCommand(item: SlashCommandItem): void {
    if (!this.commandUsable(item)) {
      // 禁用态点不动（`commandRow` 也不派发），这里是双保险 + 给一句原因。
      this.commandNotice = this.prepared
        ? `/${item.id} 暂时不能用：${draftCommandDisabledReason(item)}`
        : `/${item.id} 暂时不能用：${item.disabledReason.length > 0 ? item.disabledReason : '服务端标记为不可用'}`;
      return;
    }
    if (this.prepared) {
      this.insertCommandIntoDraft(item);
      return;
    }
    this.runCommand(item);
  }

  /**
   * 草稿态：把指令插进输入框（**已输入的文字一字不丢**，见 `appendSlashToDraft`），
   * 并给出如实回执 —— 这里**没有执行任何 DSH 指令**，只是填了文本。
   */
  private insertCommandIntoDraft(item: SlashCommandItem): void {
    this.draft = appendSlashToDraft(this.draft, slashInsertionFor(item));
    this.saveDraft(this.draft, this.attachedFiles);
    this.commandNotice = draftSlashNotice(item);
  }

  /**
   * 拉该会话的**官方**指令目录（`GET /sessions/{id}/runtime/commands`）。
   *
   * ⚠️ 能力不可用时服务端会拒（DSH bridge 补丁未打时就是这个状态，原话
   * `session capability is unavailable: session.commands`）⇒ 把原因**如实显示**，
   * 并回落到内置清单；**绝不**退化成「空面板」（用户会以为是 App 没做）。
   */
  private loadSessionCommands(): void {
    this.commandRequestId += 1;
    const requestId = this.commandRequestId;
    this.commandLoading = true;
    this.commandError = '';
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    AppServices.get().sessions.getSessionRuntimeCommands(serverUrl, token, this.sessionId)
      .then((response: RemoteSessionCommandListResponse) => {
        if (requestId !== this.commandRequestId || !this.alive) {
          return;
        }
        this.sessionCommands = response.commands.slice();
        this.commandCatalog = SlashCommandStore.get().remember(this.sessionId, this.sessionCommands);
        this.commandLoading = false;
      })
      .catch((error: Object) => {
        if (requestId !== this.commandRequestId || !this.alive) {
          return;
        }
        this.commandLoading = false;
        const message = error instanceof Error ? (error as Error).message : String(error);
        // 回落内置清单 + 原因：面板照样有内容可点，且来源行会写明「服务端指令通道不可用」。
        this.commandCatalog = SlashCommandStore.get().rememberUnavailable(this.sessionId, message);
        this.commandError = message;
      });
  }

  /**
   * **已建会话**里手打了完整指令行 ⇒ 按运行时指令语义执行（携带参数）。
   *
   * 与 `runCommand()` 的差别：那条走面板点选（无参数），只传 `command`；
   * 这条带着用户敲的参数，走 `executeSessionRuntimeCommand(..., args, raw)`。
   *
   * ⚠️ **绝不**把指令行当普通消息发出去 —— 那会进模型（见 `runCommand()` 的注释）。
   * ⚠️ 失败时**不静默**：既写面板回执，也把草稿原样还回输入框，让用户能改。
   */
  private runTypedCommand(item: SlashCommandItem, parsed: SlashCommandParse): void {
    const line = this.draft;
    this.commandNotice = `正在执行 /${item.id}…`;
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    AppServices.get().sessions.executeSessionRuntimeCommand(
      serverUrl, token, this.sessionId, item.id, parsed.args, line)
      .then((response: RemoteSessionCommandResponse) => {
        if (!this.alive) {
          return;
        }
        if (response.ok) {
          this.draft = '';
          this.draftStore.clear(this.sessionId);
          this.commandNotice = `已执行 /${item.id}${response.message !== undefined ? '：' + response.message : ''}`;
        } else {
          this.draft = line;
          this.commandNotice = `/${item.id} 失败：${response.message !== undefined ? response.message : (response.code !== undefined ? response.code : '未知原因')}`;
          this.errorText = this.commandNotice;
        }
        this.store.refreshRuntimeState().then(() => {}).catch(() => {});
      })
      .catch((error: Object) => {
        if (!this.alive) {
          return;
        }
        this.draft = line;
        const message = error instanceof Error ? (error as Error).message : String(error);
        this.commandNotice = `/${item.id} 失败：${message}`;
        this.errorText = this.commandNotice;
      });
  }

  /**
   * **已建会话**执行一条指令。
   *
   * 两种形态（与 DSH 自己的输入框一致）：
   *  · 需要参数（`acceptsArgs`）⇒ **只把 `/id ` 插进草稿**，让用户补参数后自己发；
   *  · 不需要参数 ⇒ 直接走官方执行接口 `POST /sessions/{id}/runtime/commands`。
   * ⚠️ **绝不**把 `/compact` 当普通消息发出去：DSH 的指令是服务调用
   * （`dsh-commands.execute()` 注释："without sending it to the model"），当消息发只会进模型。
   */
  private runCommand(item: SlashCommandItem): void {
    if (item.acceptsArgs) {
      // R91：不再直接 `this.draft = ...` —— 那会**覆盖用户已输入的文字**（数据丢失）。
      // ⚠️ 回执走 `noticeText` 而不是 `commandNotice`：下面一行就把面板收起来了，
      //  写在面板里的回执用户根本看不到（`noticeText` 渲染在输入卡上方那条横幅）。
      this.draft = appendSlashToDraft(this.draft, slashInsertionFor(item));
      this.saveDraft(this.draft, this.attachedFiles);
      this.commandPanelOpen = false;
      this.noticeText = sessionSlashNotice(item);
      return;
    }
    this.commandNotice = sessionSlashNotice(item);
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    AppServices.get().sessions.executeSessionRuntimeCommand(serverUrl, token, this.sessionId, item.id)
      .then((response: RemoteSessionCommandResponse) => {
        if (!this.alive) {
          return;
        }
        if (response.ok) {
          this.commandNotice = `已执行 /${item.id}${response.message !== undefined ? '：' + response.message : ''}`;
        } else {
          this.commandNotice = `/${item.id} 失败：${response.message !== undefined ? response.message : (response.code !== undefined ? response.code : '未知原因')}`;
        }
        this.store.refreshRuntimeState().then(() => {}).catch(() => {});
      })
      .catch((error: Object) => {
        if (!this.alive) {
          return;
        }
        const message = error instanceof Error ? (error as Error).message : String(error);
        this.commandNotice = `/${item.id} 失败：${message}`;
      });
  }

  /**
   * 「+」附件按钮（动作行左侧第一位，上游 `SessionComposer.kt` L536-543）。
   *
   * 上游是 30dp 圆形描边按钮，附件不可用时只是不可点、不消失。本工程保留原有的
   * 「只读时点了先引导接管」这一层 —— 输入区、这个按钮、发送按钮三处都给同一条出路。
   */
  @Builder
  attachButton() {
    Row() {
      // 上游 `plusModifier = Modifier.size(30.dp)` + `PlusMiniGlyph(sizeDp = 20)`（L505-513 / L15-18）
      AaIcon({ d: ICONS['plus'], iconSize: FontSize.ICON, color: ink() })
    }
    .width(30)
    .height(30)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
      .borderRadius(Radius.PILL)
      // ⚠️ R27：**不要给这里加底色、也不要按只读态降透明度**。
      // 上游 `plusModifier`（`SessionComposer.kt:505-513`）是**主题分支**的：
      //  深色 `size(30.dp)` 裸图标；浅色 `size(30.dp) + background(White) + border(1.dp, Transparent)`
      // 而同一处的 `surface = White`、`border = Transparent`（`:479-480`）⇒ **浅色下视觉同样不可见**。
      // 本工程原写 `backgroundColor(subtle())`（浅灰实底），并排图上一眼就多出一个圆底。
      // 只读态上游只摘 `clickable`（`:537-539`），**不改透明度**。
      .onClick(() => {
        if (this.readOnly) {
          this.promptTakeover();
          return;
        }
        this.pickAttachment();
      })
  }

  /**
   * 「接管」开关（动作行左侧第二位）。
   *
   * 对应上游 `SessionComposer.kt` L544-559 的 `Row { TakeoverSwitch(...) + Text("接管") }`：
   * 30×18 胶囊 + 12dp 圆点的**自绘**开关，整条（开关或文字）都可点。
   *
   * ⚠️ 这里刻意**不用** ArkUI 的 `Toggle`：`Toggle` 被点击后内部状态先翻，而本开关要等
   * 确认弹窗 + 接口回来才允许变（上游同理 —— `TakeoverSwitch` 的 `enabled` 来自服务端真值）。
   * 用 `Toggle` 时用户一旦在确认框上点「取消」或点空白关闭，开关会停在用户点过的样子，
   * 与 `this.takeover` 不一致（假开关）；自绘则由 `this.takeover` 单一驱动，不存在这个分叉。
   */
  @Builder
  takeoverSwitch() {
    Row({ space: 5 }) {
      Row() {
        Circle()
          .width(12)
          .height(12)
          .fill(this.takeover
            ? $r('app.color.runtime_switch_checked_thumb')
            : $r('app.color.runtime_switch_unchecked_thumb'))
      }
      .width(30)
      .height(18)
      .padding(3)
      // 上游是 `CircleShape`（胶囊）—— 30×18 的半高就是 9，走 PILL 语义更准
      .borderRadius(Radius.PILL)
      .justifyContent(this.takeover ? FlexAlign.End : FlexAlign.Start)
      // 轨道用工程里既有的开关语义色（深浅色双值），不必再新增资源
      .backgroundColor(this.takeover
        ? $r('app.color.runtime_switch_checked_track')
        : $r('app.color.runtime_switch_unchecked_track'))
      // R39：隐式动画 —— `takeover` 翻转时，圆点从一端滑到另一端、轨道同时换色。
      // ⚠️ `.animation()` 只对**它之前**声明的属性生效，所以必须挂在链式末尾（此处正好覆盖
      //  `justifyContent`（圆点位置）与 `backgroundColor`（轨道色）两者）。
      // ⚠️ 静态零变化：两个端态的几何/颜色表达式一字未改，动画只在**变化瞬间**补间。
      // ⚠️ 待实测（PLAN 的 C3）：`justifyContent` 是容器排布属性，`.animation()` 是否对「由它
      //  导致的子节点位移」补间**未经验证**。若不补间，回退方案见 PLAN §B-5（改 `translate` 驱动，
      //  但那条会改布局方式，需先逐像素复核静态态）。
      .animation({ duration: TAKEOVER_ANIM_MS, curve: Curve.EaseInOut })

      Text('接管')
        .fontSize(FontSize.SMALL)
        .fontColor(this.takeover ? ink() : muted())
    }
    // 上游 `takeoverModifier`（`SessionComposer.kt:514-523`）同样是主题分支：
    // 浅色 `height(28.dp) + background(White) + border(Transparent) + padding(start = 4.dp, end = 9.dp)`，
    // 深色只有 `height(28.dp)` ⇒ **没有可见底**（R27 删掉了本工程自加的 `subtle()` 实底）。
    .padding({ left: 4, right: 9, top: 5, bottom: 5 })
    .borderRadius(Radius.PILL)
    // R53：草稿态没有服务端会话可接管 ⇒ 恒按「忙」处理（半透明 + 点不动），
    // 与上游 preparedSession 的 takeoverBusy 同语义；外观仍是**原页面那一套**。
    .opacity(takeoverSwitchInteractive(this.connectorOnline, this.takeoverBusy || this.prepared) ? 1 : 0.5)
    .enabled(takeoverSwitchInteractive(this.connectorOnline, this.takeoverBusy || this.prepared))
    .onClick(() => {
      // 开与关共用同一条确认链路；目标状态由纯逻辑区取反（点开关 = 切到对面）
      this.confirmTakeover(takeoverSwitchTarget(this.takeover));
    })
  }

  /**
   * 主按钮（动作行最右）：运行中是「中断」（红底方块），否则是「发送」（↑）。
   *
   * 三态由纯逻辑区的 `composerPrimaryKind()` 给出（对应上游 `ComposerActions` 的
   * `primaryActionSurface` 三态）；运行中**发送只能走输入法动作**，见坑 143。
   */
  @Builder
  composerPrimaryButton() {
    if (composerPrimaryKind(this.canInterrupt, this.canSubmit()) === 'interrupt') {
      // 上游主按钮 `Modifier.size(34.dp)`（L563），中断态是 10dp 圆角方块（L583-588）
      Row() {
        AaIcon({ d: ICONS['square'], iconSize: FontSize.ICON_MD, color: $r('app.color.on_primary_action') })
      }
      .width(34)
      .height(34)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
        .borderRadius(Radius.PILL)
        .backgroundColor($r('app.color.btn_danger_bg'))
        // R43 审计补漏：这颗钮此前**没有任何按压态**（同族 34vp 圆形钮 `AaPrimaryIconButton` 有，
        // R39/R41/R42 三批按压态也都漏了它）。`normal` 走同一个底 ⇒ 静止态零变化。
        .stateStyles({
          normal: { .backgroundColor($r('app.color.btn_danger_bg')) },
          pressed: { .backgroundColor(rowPressedSurface()) }
        })
        // R38：图标取代文字后，无障碍文本是 dumpLayout / 读屏定位这颗钮的唯一语义载体
        // （先例：TerminalScreen.ets 的「清空终端」钮）。**形态零改动**。
        .accessibilityText('中断')
        .onClick(() => {
          this.store.interrupt();
        })
    } else {
      // ⚠️ 禁用态**不能**只换背景色、文字仍用 on_primary_action（白）：
      // `subtle` 是浅灰（#F1F0ED），白字压上去对比度只有 13/255，箭头等于消失
      // （真机实测）。正解是前景色也跟着换 —— 禁用 → muted 灰字 + subtle 底，
      // 深浅色主题下都读得出来。
      Row() {
        AaIcon({
          d: ICONS['arrow-up'],
          iconSize: FontSize.ICON_MD,
          color: this.canSubmit() ? onPrimaryAction() : muted()
        })
      }
      .width(34)
      .height(34)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
        .borderRadius(Radius.PILL)
        .backgroundColor(this.canSubmit() ? primaryAction() : $r('app.color.subtle'))
        // R43 审计补漏：同中断态 —— 这颗钮此前没有按压态。禁用态（`canSubmit() === false`）
        // 回落成 `subtle`（与 `normal` 同色 ⇒ 按下无反馈），口径与 `AaPrimaryIconButton` 一致。
        .stateStyles({
          normal: { .backgroundColor(this.canSubmit() ? primaryAction() : $r('app.color.subtle')) },
          pressed: { .backgroundColor(this.canSubmit() ? rowPressedSurface() : $r('app.color.subtle')) }
        })
        // R38：同上 —— 发送态补无障碍文本，形态不变（R37 已定稿，不动 34/PILL/配色/位置）。
        .accessibilityText('发送')
        .onClick(() => {
          if (this.readOnly) {
            this.promptTakeover();
            return;
          }
          // ⚠️ R43 审计修正：**视觉禁用态必须真的不可点**。
          // 上游 `SessionComposer.kt` L566-574：只有 `primaryActionEnabled`（= 非运行中时的
          // `canSend`）为真才挂 `noRippleClickable`，否则整个 Modifier 不挂点击 —— 禁用即无响应。
          // 改前这里无条件调 `send()`：当发送能力被阻断（`messageAction === NONE`、按钮已是
          // 灰底 muted 图标）时，点下去仍会真的走一次 `store.send()`，只是被 store 拦下并弹一条
          //「运行时当前无法接收消息（发送能力不可用）。」的错误横幅 —— 观感是「灰按钮点了还报错」。
          if (!this.canSubmit()) {
            return;
          }
          this.send();
        })
    }
  }

  /**
   * 输入卡上方附件条的**条数**（草稿态数本地待发文件，真会话数已上传附件）。
   *
   * R54：草稿态两者**互斥** —— 本地文件在创建会话那一刻才变成内联附件，
   * 所以草稿态永远只有 `preparedAttachments`，`attachedFiles` 属于真会话那条链。
   */
  private composerFileCount(): number {
    return this.prepared ? this.preparedAttachments.length : this.attachedFiles.length;
  }

  private canSend(): boolean {
    return this.draft.trim().length > 0 || this.composerFileCount() > 0;
  }

  /**
   * 能否提交（发送 / 输入法发送键的闸门）。
   *
   * ⚠️ 必须同时看**只读态与运行时状态**，不能只看草稿非空：
   * 之前只判 `canSend()`，于是「未接管」和「运行时不接受消息」两种情况下
   * 按钮依旧是实心可点的，点了必然失败（服务端 409）。上游对应的是
   * `canSend` 那一长串合取式（`SessionDetailScreen.kt` L1386-1396）。
   */
  private canSubmit(): boolean {
    if (this.readOnly || this.messageAction === MessageAction.NONE) {
      return false;
    }
    return this.canSend();
  }

  /**
   * 只读态下请求接管（输入区、附件按钮、发送按钮三处共用）。
   *
   * 上游用「双击输入区」触发确认弹窗（`handleReadOnlyComposerClick`，L527-538），
   * 双击在手机上既不可发现、也容易和「选中文字」撞车；这里改成单击直接弹确认框 ——
   * 用户在哪儿点都能看到同一条出路。
   */
  private promptTakeover(): void {
    this.confirmTakeover(true);
  }

  /**
   * 接管开关的确认链路（**开与关共用**）。
   *
   * 上游两个方向都要确认：`SessionDetailScreen.kt` L1698-1700 把
   * `takeoverConfirm = !takeoverEnabled` 交给 `TakeoverConfirmDialog`（L2052-2126），
   * 正文里的 `%1$s` 是运行时标签（本工程取 `session.runtimeLabel`）。
   * 文案逐字取上游 `session_enable_takeover_*` / `session_disable_takeover_*` /
   * `common_enable` / `common_disable`。
   */
  private confirmTakeover(enabled: boolean): void {
    if (!takeoverSwitchInteractive(this.connectorOnline, this.takeoverBusy || this.prepared)) {
      if (!this.connectorOnline) {
        this.noticeText = '设备离线，无法接管。请先让 Connector 上线。';
      }
      return;
    }
    this.takeoverPending = enabled;
    try {
      this.openTakeoverDialog();
    } catch (error) {
      // 弹窗失败不能把功能一起带走：退回直接提交。
      this.commitTakeover(enabled);
    }
  }

  /** 确认框正文（上游 `session_enable_takeover_body` / `session_disable_takeover_body` 的逐字文案）。 */
  private takeoverMessage(): string {
    const target = this.replyTargetLabel();
    return this.takeoverPending
      ? '• 开启后可在网页上接管这个会话。\n'
        + '• 消息可能不会立即同步到 ' + target
        + ' 客户端，通常重启它们后即可刷新同步。\n'
        + '• 如果你同时在 Agents Anywhere 和 ' + target
        + ' 客户端中操作此会话，可能导致意料外的结果。'
      : '• 关闭后会话将回到只读模式，无法继续发送消息。\n'
        + '• 这里产生的会话记录可能不会立即同步到 ' + target
        + ' 客户端，通常重启它们后即可刷新同步。';
  }

  /**
   * 屏宽（vp）。`display.getDefaultDisplaySync()` 会抛，必须包 try/catch
   * —— 不包就是一条 ArkTS 告警（[坑 144]），而「零 ArkTS 告警」是本工程硬要求。
   */
  private screenWidthVp(): number {
    try {
      // ⚠️ 字段名是 `densityPixels`（不是 `density`）—— 与 `aboutToAppear` 里 imageMaxWidth 的算法同源。
      const info = display.getDefaultDisplaySync();
      const density = info.densityPixels > 0 ? info.densityPixels : 1;
      return info.width / density;
    } catch (error) {
      // 取不到就当作「够宽」：这样 widthFor 直接给出 380 上限。
      return DialogSpec.MAX_WIDTH + DialogSpec.SCREEN_MARGIN * 2;
    }
  }

  /**
   * 打开**自绘**的接管确认框（规格 = 上游 `TakeoverConfirmDialog`，见 `DialogSpec`）。
   *
   * 为什么用 `promptAction.openCustomDialog`，而不是 `@CustomDialog` + `CustomDialogController`：
   *  ① **尺寸可控且在外层**：`CustomDialogOptions` 直接吃 `width` / `cornerRadius` / `borderWidth` /
   *  `borderColor` / `backgroundColor` / `shadow` —— 正好一一对应上游那 6 个常数，且不受内容影响；
   *  `@CustomDialog` 只能把尺寸写在自定义组件内部，还要额外开 `customStyle` 才不吃系统默认。
   *  ② **没有 controller 的构造期绑定问题**：本页文案随 `enabled` 变（开启/关闭两套），
   *  `CustomDialogController` 必须在字段初始化时绑定 builder，动态值要靠额外状态绕；
   *  `openCustomDialog` 是**调用时才取 builder**，天然带最新状态。
   *  ③ 关闭用返回的 dialogId（`closeCustomDialog`），语义与系统弹窗「点按钮即关」一致。
   */
  private openTakeoverDialog(): void {
    const width = DialogSpec.widthFor(this.screenWidthVp());
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => {
        this.takeoverDialogCard()
      },
      width: width,
      cornerRadius: DialogSpec.RADIUS,
      backgroundColor: $r('app.color.dialog_surface'),
      borderWidth: DialogSpec.BORDER_WIDTH,
      borderColor: borderColor(),
      shadow: {
        radius: DialogSpec.SHADOW_RADIUS,
        color: $r('app.color.app_shadow')
      },
      autoCancel: true,
      alignment: DialogAlignment.Center
    }).then((id: number) => {
      this.takeoverDialogId = id;
    }).catch(() => {
      // 弹层打不开不能把功能一起带走：退回直接提交（与替换前的兜底一致）。
      this.commitTakeover(this.takeoverPending);
    });
  }

  /** 关闭自绘确认框（按钮回调里调；`autoCancel` 点空白由系统关）。 */
  private closeTakeoverDialog(): void {
    const id = this.takeoverDialogId;
    if (id <= 0) {
      return;
    }
    this.takeoverDialogId = 0;
    try {
      // `closeCustomDialog` 被 ArkTS 判为「可能抛异常」，必须显式处理（零告警要求，见 [坑 144]）。
      this.getUIContext().getPromptAction().closeCustomDialog(id);
    } catch (error) {
      // 关不掉不影响功能：`autoCancel` 与随后的重开都会收敛。
    }
  }

  /**
   * 确认框内容（上游 `TakeoverConfirmDialog` 的 `Column`）：
   * 内边距 22 / 元素间距 18 / 标题 24fp ExtraBold·行高 29 / 正文 15fp Medium·行高 21 /
   * 按钮行 top 6、间距 10、两按钮各 `layoutWeight(1)`（上游 `weight(1f)` ⇒ 1:1）。
   */
  @Builder
  takeoverDialogCard() {
    Column({ space: DialogSpec.CONTENT_GAP }) {
      Text(this.takeoverPending ? '开启接管？' : '关闭接管？')
        .fontSize(DialogSpec.TITLE_SIZE)
        .fontWeight(FontWeight.Bolder)
        .lineHeight(DialogSpec.TITLE_LINE_HEIGHT)
        .fontColor(ink())
        .width('100%')
      Text(this.takeoverMessage())
        .fontSize(DialogSpec.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .lineHeight(DialogSpec.BODY_LINE_HEIGHT)
        .fontColor(muted())
        .width('100%')
      Row({ space: DialogSpec.BUTTON_GAP }) {
        this.takeoverDialogButton('取消', false)
        this.takeoverDialogButton(this.takeoverPending ? '开启' : '关闭', true)
      }
      .width('100%')
      .padding({ top: DialogSpec.BUTTON_TOP })
    }
    .width('100%')
    .padding(DialogSpec.PADDING)
    .alignItems(HorizontalAlign.Start)
  }

  /** 确认框按钮（上游 `TakeoverDialogButton`：高 50 / 圆角 16 / 15fp Bold / 次要=subtle 底）。 */
  @Builder
  takeoverDialogButton(label: string, primary: boolean) {
    Text(label)
      .fontSize(DialogSpec.BUTTON_TEXT_SIZE)
      .fontWeight(FontWeight.Bold)
      .lineHeight(DialogSpec.BUTTON_TEXT_LINE_HEIGHT)
      .fontColor(primary ? onPrimaryAction() : ink())
      .height(DialogSpec.BUTTON_HEIGHT)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      // 上游 `TakeoverDialogButton` 是 `RoundedCornerShape(16.dp)` = `Radius.L`（本页契约要求圆角走 Radius 令牌）。
      .borderRadius(Radius.L)
      .backgroundColor(primary ? primaryAction() : subtle())
      .opacity(this.takeoverBusy ? 0.55 : 1)
      .onClick(() => {
        this.closeTakeoverDialog();
        if (primary) {
          this.commitTakeover(this.takeoverPending);
        }
      })
  }

  /**
   * 真正打接口的那一步：请求期间开关不可点（`takeoverBusy`），回来后用 store 的真值回灌。
   * 刻意**不做乐观更新** —— 开关显示的必须是服务端认下来的状态，否则会出现
   * 「界面已开、实际仍只读」的假开关（发送时照样 409）。
   */
  private commitTakeover(enabled: boolean): void {
    this.takeoverBusy = true;
    this.store.setTakeover(enabled).then((ok: boolean) => {
      this.takeoverBusy = false;
      this.pull();
      if (ok) {
        this.noticeText = enabled
          ? '已接管该会话，现在可以发送消息了。'
          : '已释放接管，会话回到只读模式。';
      }
    });
  }

  /**
   * 输入区占位文案。判定顺序在 `model/SessionGating.ets` 的 `composerPlaceholder()`
   * 里（纯函数、已进 Node 单测），顺序**照抄上游**（`SessionDetailScreen.kt` L1541-1558）：
   * 只读 → 设备离线 → 待审批 → 运行时错误 → 状态相关 → 能力不可用 → 正常。
   *
   * 为什么值得单列：输入框是用户唯一会看的地方。上游把「为什么现在不能发」
   * 直接写在 placeholder 里，本工程此前无论什么状态都只显示「给 Agent 发消息…」，
   * 于是用户只会在点下发送之后收到一句英文 409 —— 观感就是「不能正常发起对话」。
   */
  private computePlaceholder(): string {
    const facts: ComposerFacts = {
      loaded: this.store.session !== undefined,
      takeover: this.takeover,
      connectorOnline: this.connectorOnline,
      hasNotices: this.notices.length > 0,
      runtimeReason: this.runtimeReason,
      runtimeStatus: this.runtimeStatus,
      sessionStatus: this.store.session !== undefined ? this.store.session.status : '',
      action: this.messageAction,
      replyTarget: this.replyTargetLabel()
    };
    return composerPlaceholder(facts);
  }

  /**
   * 上游 `SessionDetailScreen.kt` L1539-1540 的 `replyTarget`：会话运行时标签，
   * 为空（或会话没拉出来）时用 `session_agent_fallback` 的「Agent」兜底 ——
   * 占位文案「回复 X」与接管确认弹窗的正文共用它。
   */
  private replyTargetLabel(): string {
    const session = this.store.session;
    return resolveReplyTarget(session !== undefined ? session.runtimeLabel : '');
  }

  private async send(): Promise<void> {
    if (!this.canSend()) {
      return;
    }
    // R91：**已建会话**里手打的指令行（`/compact`、`/goal 目标`）必须走运行时指令语义，
    // 绝不能当普通消息塞给模型（DSH 的指令是服务调用，见 runCommand 的注释）。
    // 草稿态**不做**这个拦截：那时还没有服务端会话，指令行只能作为首条消息发出去。
    if (!this.prepared) {
      const parsed = parseSlashCommandLine(this.draft);
      if (parsed !== undefined) {
        const known = findSlashCommand(this.commandCatalog.items, parsed.id);
        if (known !== undefined && this.commandUsable(known)) {
          this.runTypedCommand(known, parsed);
          return;
        }
      }
    } else {
      // 草稿态：作用于会话的指令行（`/compact` 这类）**拦住**并说明理由 ——
      // 当普通消息发出去只会进模型，用户却以为指令执行了（见 model/SlashCommand.ets）。
      const draftBlocked = draftTypedCommandBlocker(this.commandCatalog.items, this.draft);
      if (draftBlocked.length > 0) {
        this.errorText = draftBlocked;
        return;
      }
    }
    const content = this.draft;
    const files: string[] = [];
    for (let i = 0; i < this.attachedFiles.length; i++) {
      files.push(this.attachedFiles[i].fileId);
    }
    const pendingFiles = this.attachedFiles.slice();
    // R53：草稿态下这条就是**首条消息** —— store 会用 create-and-start 把服务端会话建出来。
    const wasPrepared = this.prepared;
    // R54：草稿态的附件在**这一刻**才被读成字节、编码成内联附件（见 `model/InlineAttachment`）。
    // 读文件失败（被删/被移走）不静默吞：给一句中文提示，并且**保留**草稿与附件让用户重试。
    let inlineRefs: RemoteInlineAttachmentRef[] = [];
    if (wasPrepared && this.preparedAttachments.length > 0) {
      try {
        inlineRefs = this.buildInlineAttachments();
      } catch (error) {
        this.store.error = `读取附件失败：${error instanceof Error ? (error as Error).message : String(error)}`;
        this.pull();
        return;
      }
    }
    this.draft = '';
    this.attachedFiles = [];
    const ok = await this.store.send(content, files, inlineRefs);
    if (ok && wasPrepared) {
      const created = this.store.createdSessionId;
      this.draftStore.clear(this.sessionId);
      // 用 replace：草稿页不该留在返回路径上（返回键要回首页，而不是回一个「再发一次会再建一条」的空壳）。
      if (created.length > 0) {
        Router.replace(Route.SESSION, created);
      }
      return;
    }
    if (!ok) {
      // 发送失败（弱网 / 401 / 会话已结束）时把草稿与待发附件还回去，
      // 否则用户重打一遍、附件也要重选一次。仅在用户没有新输入时回填，避免覆盖。
      if (this.draft.length === 0) {
        this.draft = content;
      }
      if (this.attachedFiles.length === 0) {
        this.attachedFiles = pendingFiles;
      }
      // 回填后立刻同步落盘：否则「发送失败 → 直接返回上一级」会把草稿丢掉
      this.saveDraft(this.draft, this.attachedFiles);
    } else {
      // 发送成功才清草稿（上游同样是发送成功之后才 clear）
      this.draftStore.clear(this.sessionId);
    }
  }

  /**
   * 注入草稿的持久化后端（preferences）。
   *
   * `store/ComposerDraftStore` 刻意保持**零 @kit 依赖**（存取策略要能在 Node 里断言），
   * preferences 这一类平台能力由页面装配进去；`attachStorage` 幂等，重复进页面不会重复打开。
   */
  private attachDraftStorage(): void {
    if (this.draftStore.hasStorage()) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const storage = new DraftPrefsStorage(context);
      // 只注入真的打开成功的后端：注入一个「哑后端」会让 hasStorage() 变 true，
      // 之后就再也不会重试，草稿会永久读不出来（见 DraftPrefsStorage.ready）。
      if (storage.ready) {
        this.draftStore.attachStorage(storage);
      }
    } catch (error) {
      // 拿不到上下文就退化为「本次运行内有效」：草稿功能降级，但输入本身不受影响。
    }
  }

  /** 保存当前草稿（附件一起存，与上游 `save` 同构）。 */
  private saveDraft(text: string, files: PendingAttachment[]): void {
    this.draftStore.save(this.sessionId, text, toDraftAttachments(files));
  }

  /**
   * 草稿按会话隔离：进入页面 / 切会话时，先把手头的内容落回它自己的会话，再载入新草稿。
   * 「要不要读」由 `shouldRestoreDraft` 决定（纯函数，Node 断言守着），
   * 所以它在 `pull()` 里被反复调用也很便宜、且不会覆盖用户正在输入的内容。
   */
  private syncDraftSession(): void {
    // 幂等 + 可重试：后端已就绪时立即返回；未就绪则再试一次（每次 pull 都会走到这里）。
    // 这样即使第一次调用发生在拿到 UIContext 之前，也不会永久失去草稿后端。
    this.attachDraftStorage();
    if (this.draftSessionId !== this.sessionId) {
      // 切会话：先把当前内容落回**它自己的**会话，再换 id
      if (this.draftSessionId.length > 0) {
        this.saveDraft(this.draft, this.attachedFiles);
      }
      this.draftSessionId = this.sessionId;
    }
    // 「要不要读」与「后端没就绪时不许锁定」的规则都在纯函数里（suite-input.mjs 有断言守着）
    if (!shouldRestoreDraft(this.sessionId, this.draftRestoredFor, this.draftStore.hasStorage())) {
      return;
    }
    const restored = this.draftStore.restore(this.sessionId);
    // 只有真的读过一次（后端已就绪）才记下这个会话 —— 避免把「后端没准备好」当成「没有草稿」
    this.draftRestoredFor = this.sessionId;
    // 恢复原文 = 「要不要显示恢复提示」的比较基准（空串 = 这个会话没有草稿，提示不显示）
    this.draftRestoreSnapshot = restored.text;
    this.draft = restored.text;
    this.attachedFiles = toPendingAttachments(restored.attachments);
  }

  /** 选文件 → 上传 → 收集 fileId。 */
  private async pickAttachment(): Promise<void> {
    this.attaching = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select({ maxSelectNumber: 5 });
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const parts: UploadFilePart[] = [];
      const names: string[] = [];
      const rejected: string[] = [];
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        try {
          const stat = fileIo.statSync(file.fd);
          // ⚠️ picker 返回的 URI 尾段是 **percent-encoded** 的（真机实测：`文本.txt`
          // 变成 `%E6%96%87%E6%9C%AC.txt`），必须解码后再当文件名上传，
          // 否则服务端存的是乱码、消息里的附件名也是乱码。
          const name = decodeFileName(uri.substring(uri.lastIndexOf('/') + 1));
          // ⚠️ 体积闸门必须在 `readSync` **之前**：上传是把整个文件读进内存再 base64
          // （`new ArrayBuffer(size)` → `Uint8Array` → multipart），超大文件会直接 OOM。
          // 超限的文件**一个请求都不发**，只把提示攒起来一次性讲给用户。
          const sizeCheck = checkUploadSize(name, stat.size);
          if (!sizeCheck.ok) {
            rejected.push(sizeCheck.message);
            continue;
          }
          const buffer = new ArrayBuffer(stat.size);
          fileIo.readSync(file.fd, buffer);
          const part: UploadFilePart = {
            name: name,
            mediaType: guessMediaType(name),
            bytes: new Uint8Array(buffer)
          };
          parts.push(part);
          names.push(name);
        } finally {
          fileIo.closeSync(file);
        }
      }
      if (rejected.length > 0) {
        this.store.error = rejected.join(' ');
        this.pull();
      }
      if (parts.length === 0) {
        return;
      }
      const serverUrl = readServerUrl();
      const token = readAccessToken();
      const uploaded = await AppServices.get().sessions.uploadSessionAttachments(serverUrl, token, this.sessionId, parts);
      const pending: PendingAttachment[] = [];
      for (let i = 0; i < uploaded.length; i++) {
        const uploadedName = uploaded[i].name.length > 0 ? uploaded[i].name : names[i];
        pending.push({ fileId: uploaded[i].fileId, name: uploadedName });
      }
      this.attachedFiles = this.attachedFiles.concat(pending);
    } catch (error) {
      this.store.error = `上传附件失败：${error instanceof Error ? (error as Error).message : String(error)}`;
      this.pull();
    } finally {
      this.attaching = false;
    }
  }

  /**
   * R54：草稿态选文件 —— **只暂存在本机**，不上传。
   *
   * 为什么不复用上面的 `pickAttachment()`：那条链的第一步就是
   * `POST /sessions/{id}/attachments`（multipart），**必须先有 sessionId**；
   * 草稿态服务端会话还不存在 ⇒ 首条消息的附件只能走 `create-and-start` 的**内联附件**
   * （base64 随创建请求一起发，见 `model/InlineAttachment.ets` 的契约注释）。
   *
   * 两处闸门都在 **`readSync` 之前**：① `runtime.attachment` 能力（服务端硬性要求）；
   * ② 单文件 10MB + 最多 10 个（`canStageAttachment`）。
   */
  private async pickDraftAttachment(): Promise<void> {
    if (this.preparedAttachBusy) {
      return;
    }
    if (!this.preparedAttachmentsAllowed) {
      this.store.notice = inlineAttachmentUnavailableText();
      this.pull();
      return;
    }
    this.preparedAttachBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select({ maxSelectNumber: 5 });
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const rejected: string[] = [];
      let staged = 0;
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        try {
          const stat = fileIo.statSync(file.fd);
          // ⚠️ picker 的 URI 尾段是 percent-encoded 的（与 `pickAttachment` 同一条实测结论），
          // 不解码的话服务端与时间线上显示的文件名都是乱码。
          const name = decodeFileName(uri.substring(uri.lastIndexOf('/') + 1));
          const gate = canStageAttachment(this.store.preparedAttachments, stat.size, name);
          if (!gate.ok) {
            rejected.push(gate.message);
            continue;
          }
          const stagedFile: LocalAttachment = {
            uri: uri,
            name: name,
            mediaType: guessMediaType(name),
            size: stat.size
          };
          this.store.addPreparedAttachment(stagedFile);
          staged += 1;
        } finally {
          fileIo.closeSync(file);
        }
      }
      if (rejected.length > 0) {
        this.store.error = rejected.join(' ');
      } else if (staged > 0) {
        this.store.notice = '已添加 ' + localAttachmentSummary(this.store.preparedAttachments)
          + '，随首条消息一起发出。';
      }
      this.pull();
    } catch (error) {
      this.store.error = `读取附件失败：${error instanceof Error ? (error as Error).message : String(error)}`;
      this.pull();
    } finally {
      this.preparedAttachBusy = false;
    }
  }

  /**
   * R54：把暂存的本地附件读成字节 → `sha256` + base64 → 内联附件引用。
   *
   * ⚠️ `size` / `sha256` 都必须**与内容一致**：服务端 `_decode_inline_attachment`
   * （`server/agent_server/services/session_run.py:1049-1066`）对不上就直接拒。
   * 读取失败（文件被删/被移走）会抛错，由 `send()` 捕成一句中文提示。
   */
  private buildInlineAttachments(): RemoteInlineAttachmentRef[] {
    const refs: RemoteInlineAttachmentRef[] = [];
    const pending = this.store.preparedAttachments;
    for (let i = 0; i < pending.length; i++) {
      const local = pending[i];
      try {
        const file = fileIo.openSync(local.uri, fileIo.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(local.size);
          fileIo.readSync(file.fd, buffer);
          const bytes = new Uint8Array(buffer);
          refs.push(inlineAttachmentRefFor(local, i, sha256Hex(bytes), base64Encode(bytes)));
        } finally {
          fileIo.closeSync(file);
        }
      } catch (error) {
        // 文件被删/被移走：转成一句可读的原话抛给 `send()`（那里会包成中文提示并保留草稿）。
        const message = error instanceof Error ? (error as Error).message : String(error);
        throw new Error(localAttachmentLabel(local) + '：' + message);
      }
    }
    return refs;
  }

  // -------------------------------------------------------------------------
  // 复制 / 分享（上游 `copyMessageText` 与 `createShare`）
  // -------------------------------------------------------------------------

  /** 复制一条消息的全文（上游 `copyMessageText`，`SessionDetailScreen.kt:281-286`）。 */
  private copyMessage(message: TimelineMessage): void {
    this.copyTextToBoard(copyPayload(message.title, message.body), '已复制这条消息。');
  }

  /**
   * 写系统剪贴板 + 轻提示。
   *
   * 写剪贴板不需要权限，但 SDK 标了 `@throws`，必须包 try（与 `DeviceDetailScreen.copyText` 同构）。
   */
  private copyTextToBoard(text: string, successHint: string): void {
    if (text.length === 0) {
      this.actionHint = '这条消息没有可复制的文本。';
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.actionHint = successHint;
      }).catch(() => {
        this.actionHint = '复制失败，请长按正文手动复制。';
      });
    } catch (error) {
      this.actionHint = '复制失败，请长按正文手动复制。';
    }
  }

  /**
   * 分享入口（上游 `MessageShareButton` → `SessionShareDialog`，`SessionDetailScreen.kt:1877-2001`）。
   *
   * 上游先弹一个对话框选「当前回复 / 整个会话」、再点确认，然后生成链接并用
   * `Intent.ACTION_SEND` 拉起系统分享。鸿蒙侧用 `showAlertDialog` 的**两个按钮**直接承担
   * 「选范围 + 确认」两步（本工程没有等价的自绘范围选择器），语义一致、少一次点击。
   */
  private promptShare(message: TimelineMessage): void {
    this.promptShareIds([message.sourceItemId]);
  }

  /** 分享一组消息（回合末尾的「分享」用的是整回合的 itemIds，上游 `onShareReply(replyItemIds)`）。 */
  private promptShareIds(replyIds: string[]): void {
    if (this.shareBusy) {
      return;
    }
    const replyItems: string[] = replyIds.slice();
    const sessionItems: string[] = [];
    try {
      this.getUIContext().showAlertDialog({
        title: '分享',
        message: '选择分享范围：整个会话，或这一条回复。',
        autoCancel: true,
        // ## R86：系统 AlertDialog 的**底**改由官方沉浸光感接管（参数对象新增本字段，其余一字未动）
        // · 官方依据：`AlertDialogParam.systemMaterial`（SDK `alert_dialog.d.ts:894`，接口 :340；
        //  本处用的是 `AlertDialogParamWithButtons`，`:965` 直接 extends 它 ⇒ 字段可用）。
        // · 生效范围：系统 AlertDialog 属**弹窗类接口** ⇒ 依官方「生效范围」在**页面内全部区域**生效
        // （`坑 245`，仅对 `targetSdkVersion >= 26.0.0` 生效，本工程 = 26.0.0）。
        // · 档位 `dialogMaterial()`（REGULAR）：小面板，与 `AaConfirmDialog`（R85）同一档同一入口。
        // · 关闭姿势 = `uiMaterial.Material.empty`（= disable，SDK `uiMaterial.d.ts:467-472`），由
        //  `dialogMaterial()` 在探针不可用时自己返回；**不得**改传 `undefined`（官方语义 =
        //  「恢复组件默认材质」，`common.d.ts:22632-22633` / `坑 256`）。回退 = 删掉下面这一行。
        systemMaterial: dialogMaterial(),
        primaryButton: {
          value: '整个会话',
          action: () => {
            this.createShare(SHARE_SCOPE_SESSION, sessionItems);
          }
        },
        secondaryButton: {
          value: '这条回复',
          action: () => {
            this.createShare(SHARE_SCOPE_MESSAGE, replyItems);
          }
        }
      });
    } catch (error) {
      // 弹窗失败不能把功能一起带走：退回直接分享整个会话
      this.createShare(SHARE_SCOPE_SESSION, sessionItems);
    }
  }

  /**
   * 生成分享链接并交给系统分享；**接不上就降级为复制链接**（本轮硬要求）。
   *
   * 上游 `createShare`（`SessionDetailScreen.kt:294-320`）：`controller.createShare(...)`
   * → 成功拿 `shareUrl` → `Intent.ACTION_SEND`；打开失败时提示 `session_share_open_failed`。
   * 鸿蒙侧的等价物是 `@kit.ShareKit` 的系统分享面板；它接不上时退回剪贴板 ——
   * 分享链接本身已经由服务端生成，两条路径对用户都可用。
   */
  private async createShare(scope: string, itemIds: string[]): Promise<void> {
    if (this.shareBusy) {
      return;
    }
    this.shareBusy = true;
    this.actionHint = '正在生成分享链接…';
    try {
      const response = await AppServices.get().sessions.createSessionShare(
        readServerUrl(), readAccessToken(), this.sessionId, scope, itemIds);
      const url = response.shareUrl;
      if (url.length === 0) {
        this.actionHint = '服务端没有返回分享链接。';
      } else {
        const opened = await this.openSystemShare(url);
        if (opened) {
          this.actionHint = '已打开系统分享。';
        } else {
          this.copyTextToBoard(url, '系统分享不可用，分享链接已复制到剪贴板。');
        }
      }
    } catch (error) {
      this.actionHint = `生成分享链接失败：${error instanceof Error ? (error as Error).message : String(error)}`;
    }
    this.shareBusy = false;
  }

  /**
   * 尝试拉起 HarmonyOS 系统分享面板；**任何一步失败都返回 false**（调用方降级为复制链接）。
   *
   * ⚠️ `@kit.ShareKit` 是 **HSP 型 kit**（实现挂在系统侧 hms 包里），静态导入有把页面拖进
   * 崩溃导入图的风险（坑 30 / 坑 34：`canIUse` 为 true **不代表** HSP 存在）。所以：
   *  ① 只用 `await import()` 运行期取模块 —— 静态导入图里没有它；
   *  ② `canIUse(syscap)` 先挡一层（坑 32：`canIUse` 是 ArkTS 全局内置函数，不能 import）；
   *  ③ 模块对象用 `ESObject` 承接 —— 工程里另一工程对 WeatherServiceKit / PDFKit /
   *  AccountKit 用的就是这套写法，因此不依赖 ShareKit 的 d.ts 才能编译；
   *  ④ 全程 try/catch。
   */
  private async openSystemShare(url: string): Promise<boolean> {
    if (!canIUse('SystemCapability.Collaboration.SystemShare')) {
      return false;
    }
    try {
      const kit: ESObject = await import('@kit.ShareKit');
      const record: ShareRecordShape = {
        utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
        content: url,
        title: '会话分享链接'
      };
      const data: ESObject = new kit.systemShare.SharedData(record);
      const controller: ESObject = new kit.systemShare.ShareController(data);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // `SelectionMode.SINGLE = 0`（SDK d.ts 实证），`selectionMode` 本身是可选项
      const options: ShareOptionsShape = { selectionMode: 0 };
      await controller.show(context, options);
      return true;
    } catch (error) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 运行时设置
  // -------------------------------------------------------------------------

  /**
   * ⚠️ 本段是 R10 截断事故后的**重建版**（非逐字还原）：
   * 依据是 task-10 版源码在本次会话里的逐字读取，与构建缓存 `.ts` 的编译行号交叉核对过。
   * 待 input-ux 的原件到位后应逐字替换（见 R10 交付说明的「重建段落」清单）。
   */
  /**
   * R53：草稿态的「选择工作区」面板（**页面内联区块**）。
   *
   * 工作区就是会话的 cwd。列表来源与旧的新建会话页同一个（dashboard.projects 按设备过滤），
   * 每行显示项目名 + 完整路径；选到别的设备上的工作区时，Agent 会跟着重新解析。
   *
   * ⚠️ 入口是顶栏那一行**元信息**（草稿态下它可点，真会话里它只是文字）——
   * 页面外观因此与真会话**完全一致**（用户要求「不要再搞一个页面设计」），
   * 不多出任何按钮或提示行。
   */
  @Builder
  preparedWorkspacePanel() {
    Column({ space: Space.S }) {
      Row({ space: Space.S }) {
        Text('选择工作区')
          .fontSize(FontSize.TITLE)
          .fontColor(ink())
          .layoutWeight(1)
        AaSecondaryButton({
          label: '收起',
          compact: true,
          onTap: () => {
            this.workspacePanelOpen = false;
          }
        })
      }
      .width('100%')

      if (this.preparedDevices.length > 1) {
        Scroll() {
          Row({ space: Space.S }) {
            ForEach(this.preparedDevices, (device: NewChatDevice) => {
              Text(device.name)
                .fontSize(FontSize.CAPTION)
                .fontColor(this.preparedConnectorId === device.id ? onPrimaryAction() : ink())
                .padding({ left: Space.M, right: Space.M, top: Space.XS, bottom: Space.XS })
                .borderRadius(Radius.PILL)
                .backgroundColor(this.preparedConnectorId === device.id ? primaryAction() : raisedSurface())
                .borderWidth(StrokeWidth.HAIRLINE)
                .borderColor(borderColor())
                .maxLines(1)
                .onClick(() => {
                  this.store.selectPreparedDevice(device.id).then(() => {
                    this.pull();
                  });
                })
            }, (device: NewChatDevice) => device.id)
          }
          .padding({ left: Space.PAGE, right: Space.PAGE })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        // 横向 Scroll 必须显式 Start（见 suite-scroll-align）。
        .align(Alignment.Start)
      }

      Scroll() {
        Column() {
          ForEach(projectsForDevice(this.preparedConnectorId, this.preparedProjects),
            (project: NewChatProject) => {
              AaConfigMenuItem({
                label: project.name,
                detail: project.workspacePath,
                active: project.id === this.preparedProjectId,
                onTap: () => {
                  this.store.selectPreparedWorkspace(project.id).then(() => {
                    this.workspacePanelOpen = false;
                    this.pull();
                  });
                }
              })
            }, (project: NewChatProject) => project.id)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 320 })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      AaSecondaryButton({
        label: '新建工作区',
        onTap: () => {
          this.workspacePanelOpen = false;
          Router.push(Route.NEW_PROJECT);
        }
      })
    }
    .width('100%')
    .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.S })
    .backgroundColor(canvas())
  }

  /**
   * 运行时设置面板（**页面内联区块**，不是系统弹层）。
   *
   * ⚠️ R8 冒烟 D2 的根因就在它原来那行 `bindSheet`：同一个根节点上还挂着「附件大图」的
   * `bindSheet`，而 ArkUI 的属性方法是**后写覆盖先写** —— 于是点 ⚙ 时服务端请求确实发了、
   * `showRuntimeSheet` 也置成了 true，但那个 sheet 永远不呈现（dumpLayout 里连
   * 「运行时设置」文本都找不到）。改成内联后它是一个普通节点：必然进 dump 树、必然可点，
   * 键盘避让（全局 RESIZE）也照常生效。
   */
  @Builder
  runtimePanel() {
    Column({ space: Space.S }) {
      Row({ space: Space.S }) {
        Text('运行时设置')
          .fontSize(FontSize.TITLE)
          .fontColor(ink())
          .layoutWeight(1)
        AaSecondaryButton({
          label: '收起',
          compact: true,
          onTap: () => {
            this.showRuntimeSheet = false;
          }
        })
      }
      .width('100%')

      // 内容可能比面板高（模型/权限/会话命令都是列表），所以固定面板高度 + 内部滚动，
      // 免得把时间线与输入区一路挤下去。
      // ⚠️ 控制器不是可选项：面板是「固定高度 + 内部滚动」，展开时视口可能停在半路 ——
      // 真机基线 baseline-02-home.jpeg 里第一个模型按钮就是这样被裁掉一半的。
      // 展开那一下会显式把视口归零（见 ⚙ 的 onClick），首项因此必然完整。
      Scroll(this.runtimeScroller) {
        Column({ space: Space.M }) {
          if (this.store.runtimeState !== undefined) {
            // R20：原来直接 `状态：${...status}` ⇒ 界面上是 `idle` / `running` 这种英文枚举。
            // 上游 `SessionRuntimeSettingsSheet` 里没有这一行（是本工程自加的诊断信息），
            // 按「不丢信息、但不裸露枚举」处理：已知取值给中文，未知取值**不显示**。
            if (this.runtimeStateText().length > 0) {
              Text(`状态：${this.runtimeStateText()}`)
                .fontSize(FontSize.SMALL)
                .fontColor(muted())
                .width('100%')
            }
          }

          // ---- 模型 + 推理强度 ----
          // 上游把「推理强度」挂在模型下面（`SessionRuntimeSettingsSheet.kt` 的 ModelPage →
          // ModeEffortPage → EffortSelectionSection）：模型只列一行，档位在它下面成组出现，
          // 且**多于 1 个档位才出现** —— 只有一个档位的模型本来就没有可选的强度。
          // ⚠️ 段本身**不按能力位隐藏**：上游 sheet 的 modelOptions / permissionOptions 直接来自
          // `state.catalogs`（`SessionDetailScreen.kt:1423` 的 `state.catalogs.permission?.let`），
          // 能力位只决定「要不要去拉目录」（同文件 1449-1498 的 LaunchedEffect）。
          // 拉不到就是空态「暂无可用设置」——藏掉整段会让用户连「为什么没有」都看不到。
          this.runtimeSectionLabel(RUNTIME_MODEL_KEY)
          this.runtimeSectionBody(RUNTIME_MODEL_KEY)
          if (this.runtimeEffortOptions.length > 1) {
            this.runtimeSectionLabel(RUNTIME_EFFORT_SECTION)
            this.runtimeEffortSegments()
            if (this.runtimeEffortNotes.length > 0) {
              Text(this.runtimeEffortNotes.join('\n'))
                .fontSize(FontSize.CAPTION_PLUS)
                .fontColor(muted())
                .width('100%')
            }
          }

          // ---- 权限模式 ----
          this.runtimeSectionLabel(RUNTIME_PERMISSION_KEY)
          this.runtimeSectionBody(RUNTIME_PERMISSION_KEY)

          // ---- Agent 预设（R53：**只**在草稿态出现）----
          // 真会话的 Agent 预设是**创建时**定下的（R51：随 create-and-start 的 runtimeOptions 发出），
          // 事后改不了；草稿态还没创建，所以这里必须给一个入口，否则用户就没有地方选它了。
          //
          // ## R93（用户：「设置里的预设，选择时前面用☑️，统一下 ui」＋「去掉预设的描述，只留名字」）
          // ### 1 · 选中标记换矢量勾，并入**同一面板**已有的形态
          // 改前是 `AaSecondaryButton` + 标签前缀 `● `（字符圆点）—— 与**同一面板**的模型 / 权限
          // 两个选择器不一致：那两处早在 R12-10 就统一成「左置 `ICONS['check']` 矢量勾 +
          // `Control.ROW_LEADING` 占位列 + 选中 `subtle()` 底色 + 不可用 `opacity 0.45`」
          // （见本文件 `runtimeSectionBody()` 的 R12-10 注释）。本轮把预设段**并入同一形态**，
          // 而不是另创一套 —— 这才是用户说的「统一下 ui」。
          // ⚠️ 矢量勾正是 R12-10 的既定口径（「勾选态从字符 ✓ 换成 Lucide 矢量」）；
          //  用户说的「☑️」在本工程的落地形态就是 `ICONS['check']`，改前那个 `● ` 是全工程唯一残留。
          // ### 2 · 去掉描述，只留名字
          // 改前每项下面挂一行 `agentPresetDetail(option)`（可用取 description、不可用取 disabledReason）。
          // ⚠️ `agentPresetDetail()` 本身**不删** —— 设置页的预设小窗仍在用它（那是另一处 UI，本轮不动）。
          // ⚠️ **不可用原因不能跟着一起丢**：改前用户能从副标题看到「为什么不可用」，去掉后就没有解释了
          //  ⇒ 点不可用项时用 `actionHint` 把那句原因**显式提示**出来（与模型/权限两处同构）。
          if (this.prepared && this.preparedPresetOptions.length > 0) {
            Text(AGENT_PRESET_LABEL)
              .fontSize(FontSize.SMALL)
              .fontColor(muted())
              .width('100%')
            Column({ space: Space.XXS }) {
              ForEach(this.preparedPresetOptions, (option: AgentPresetOption) => {
                Row({ space: Space.S }) {
                  // 与模型 / 权限两处**逐字同款**：空分支用 `Column` + `if` 保住占位宽度，
                  // 否则选中与否会让名字左右跳动（R12-10 定下的写法）。
                  Column() {
                    if (option.value === this.preparedPreset) {
                      AaIcon({ d: ICONS['check'], iconSize: FontSize.SMALL, color: primaryAction() })
                    }
                  }
                    .width(Control.ROW_LEADING)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                  // R94：走显示名口径 —— 内置预设（连接器只给 id，如 standard）在这里显示中文名「标准模式」。
                  // ⚠️ 只有预设段用 `agentPresetLabel()`：本文件另外两处 `Text(option.label)` 分别是
                  //  **审批选项**与**权限选项**（不同的接口，label 本身就是服务端给的显示名），不许一起改。
                  Text(agentPresetLabel(option))
                    .fontSize(FontSize.BODY_SMALL)
                    .fontColor(ink())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: Space.S, right: Space.S, top: Space.S, bottom: Space.S })
                .borderRadius(Radius.S)
                .backgroundColor(option.value === this.preparedPreset ? subtle() : Color.Transparent)
                .opacity(presetStillSelectable(this.preparedPresetOptions, option.value) ? 1 : 0.45)
                .onClick(() => {
                  if (!presetStillSelectable(this.preparedPresetOptions, option.value)) {
                    this.actionHint = agentPresetDetail(option).length > 0
                      ? agentPresetDetail(option) : '该预设当前不可用。';
                    return;
                  }
                  this.store.setPreparedPreset(option.value);
                  this.pull();
                })
              }, (option: AgentPresetOption) => option.value)
            }
            .width('100%')
          }

          // 接管入口按上游挪到了输入区的动作行（`SessionComposer.kt` 的 `ComposerActions`），
          // 这里不再放第二个开关 —— 同一件事有两个入口就会各说各话
          // （上游的运行时设置面板里也没有接管项）。

          if (this.commands.length > 0) {
            Text('会话命令')
              .fontSize(FontSize.SMALL)
              .fontColor(muted())
              .width('100%')
            ForEach(this.commands, (command: RemoteSessionCommand) => {
              AaSecondaryButton({
                label: command.title.length > 0 ? command.title : command.id,
                interactive: command.enabled,
                onTap: () => {
                  this.store.executeCommand(command.id);
                  this.showRuntimeSheet = false;
                }
              })
            }, (command: RemoteSessionCommand) => command.id)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height(430)
    .padding({ left: Space.M, right: Space.M, top: Space.S, bottom: Space.S })
    // ⚠️ R37 七改（用户反馈「设置弹窗的模糊度提高，有点看不清字了」）：
    // 改前只有一层 `session_code_surface`（浅色 alpha 72% 的白）—— 背后成片的正文透出 28%，
    // 两行字叠在一起，面板里的模型名/状态几乎读不出来。
    // 现在两层一起上：**更强的模糊**（`GLASS_PANEL_BLUR` = 24，顶栏那层只有 6）+
    // **更实的底**（`glassPanelSurface()`，alpha ≈ 85%）—— 保住毛玻璃质感的同时让字清楚。
    .backgroundColor(glassPanelSurface())
    .backgroundEffect({
      radius: GLASS_PANEL_BLUR,
      saturation: GLASS_SATURATION,
      brightness: GLASS_BRIGHTNESS,
      color: glassPanelSurface()
    })
    .borderWidth({ top: 1, bottom: 1 })
    .borderColor(borderColor())
  }

  /** 段标题（传的是**常量**段标识，标题文本在内部按当前状态取 —— @Builder 的值参数不会随内容重建）。 */
  @Builder
  runtimeSectionLabel(section: string) {
    Row({ space: Space.S }) {
      Text(this.runtimeSectionTitle(section))
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .layoutWeight(1)
      if (this.runtimeSectionValue(section).length > 0) {
        Text(this.runtimeSectionValue(section))
          .fontSize(FontSize.CAPTION)
          .fontColor(faint())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ top: Space.XS, bottom: Space.XXS })
  }

  /**
   * 目录段的三态 + 列表。
   *
   * 与上游 `ModelOptions` / `PermissionSection` 的 when 分支一一对应：
   * 加载中（转圈 + 「正在加载模型…」）/ 失败（文案 + 原话 + 「重试」）/ 空（「暂无可用设置」）/ 有内容。
   * 判定在 `RuntimeSelection.catalogSectionState`（纯函数，已进 Node 单测）。
   *
   * ⚠️ 行渲染一律**内联**在这个 @Builder 里读 `this.xxx`：
   * 若改成「把行数据当值参数传给另一个 @Builder」，内容变化不会重建（坑 38）。
   */
  @Builder
  runtimeSectionBody(section: string) {
    if (this.runtimeSectionState(section) === RUNTIME_SECTION_LOADING) {
      // 上游 SheetLoading（`SessionRuntimeSettingsSheet.kt:424-440`）只有转圈、**没有文字**
      Row() {
        LoadingProgress()
          .width(Control.SPINNER)
          .height(Control.SPINNER)
          .color(muted())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: Space.XL, bottom: Space.XL })
    } else if (this.runtimeSectionState(section) === RUNTIME_SECTION_ERROR) {
      // 上游 SheetError（`SessionRuntimeSettingsSheet.kt:443-463`）：
      // `AABottomSheetItem(text = common_retry, errorMessage = message, enabled = !busy && !loading)`
      // —— 一个「重试」按钮 + 一行错误消息（message 是服务端/请求层给的原话）。
      Column({ space: Space.S }) {
        AaSecondaryButton({
          label: RuntimeText.RETRY,
          compact: true,
          interactive: !this.runtimeSelectionBusy() && !this.runtimeSectionLoading(section),
          onTap: () => {
            this.retryRuntimeCatalog(section);
          }
        })
        Text(this.runtimeSectionError(section))
          .fontSize(FontSize.CAPTION)
          .fontColor(designErrorText())
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.runtimeSectionState(section) === RUNTIME_SECTION_EMPTY) {
      Text(RuntimeText.NO_SETTINGS)
        .fontSize(FontSize.SMALL)
        .fontColor(muted())
        .width('100%')
        .padding({ top: Space.S, bottom: Space.S })
    } else if (section === RUNTIME_MODEL_KEY) {
      Column({ space: Space.XXS }) {
        ForEach(this.runtimeModelGroups, (group: ModelOptionGroup) => {
          Row({ space: Space.S }) {
            // R12-10：勾选态从字符 ✓ 换成 Lucide 矢量（空分支用 Column + if 保住占位宽度）。
            Column() {
              if (isGroupSelected(group, this.runtimeSelectedModel)) {
                AaIcon({ d: ICONS['check'], iconSize: FontSize.SMALL, color: primaryAction() })
              }
            }
              .width(Control.ROW_LEADING)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            Column({ space: Space.XXS }) {
              Text(group.label)
                .fontSize(FontSize.BODY_SMALL)
                .fontColor(ink())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (modelGroupSupportingText(group, this.runtimeSelectedModel).length > 0) {
                Text(modelGroupSupportingText(group, this.runtimeSelectedModel))
                  .fontSize(FontSize.CAPTION)
                  .fontColor(muted())
                  .maxLines(2)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: Space.S, right: Space.S, top: Space.S, bottom: Space.S })
          .borderRadius(Radius.S)
          .backgroundColor(isGroupSelected(group, this.runtimeSelectedModel) ? subtle() : Color.Transparent)
          .opacity(this.modelRowInteractive(group) ? 1 : 0.45)
          .onClick(() => {
            // 上游 onSelectModel（`SessionDetailScreen.kt:1815-1822`）：可用才提交，
            // 不可用则 `showError(disabledReason ?: session_selection_update_failed)`。
            const option = displayOptionForGroup(group, this.runtimeSelectedModel);
            if (option === undefined || !this.modelRowInteractive(group)) {
              this.actionHint = option !== undefined && option.disabledReason !== undefined
                ? option.disabledReason : RuntimeText.UPDATE_FAILED;
              return;
            }
            this.applyRuntimeSelection(RUNTIME_MODEL_KEY, option.selectionId);
          })
        }, (group: ModelOptionGroup) => modelGroupKey(group))
      }
      .width('100%')
    } else {
      Column({ space: Space.XXS }) {
        ForEach(this.runtimePermissionOptions, (option: RuntimeSelectionOption) => {
          Row({ space: Space.S }) {
            // R12-10：勾选态从字符 ✓ 换成 Lucide 矢量（空分支用 Column + if 保住占位宽度）。
            Column() {
              if (this.runtimeSelectedPermission === option.selectionId) {
                AaIcon({ d: ICONS['check'], iconSize: FontSize.SMALL, color: primaryAction() })
              }
            }
              .width(Control.ROW_LEADING)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            Column({ space: Space.XXS }) {
              Text(option.label)
                .fontSize(FontSize.BODY_SMALL)
                .fontColor(ink())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (permissionSupportingText(option).length > 0) {
                Text(permissionSupportingText(option))
                  .fontSize(FontSize.CAPTION)
                  .fontColor(muted())
                  .maxLines(2)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: Space.S, right: Space.S, top: Space.S, bottom: Space.S })
          .borderRadius(Radius.S)
          .backgroundColor(this.runtimeSelectedPermission === option.selectionId ? subtle() : Color.Transparent)
          .opacity(this.permissionRowInteractive(option) ? 1 : 0.45)
          .onClick(() => {
            if (!this.permissionRowInteractive(option)) {
              this.actionHint = option.disabledReason !== undefined
                ? option.disabledReason : RuntimeText.UPDATE_FAILED;
              return;
            }
            this.applyRuntimeSelection(RUNTIME_PERMISSION_KEY, option.selectionId);
          })
        }, (option: RuntimeSelectionOption) => optionRowKey(option))
      }
      .width('100%')
    }
  }

  /**
   * 推理强度分段条（上游 `EffortSegments`）。
   *
   * ⚠️ 上游还支持拖动整条来选（`draggable` + `onSizeChanged` 量轨道宽再换算按下位置）；
   * 鸿蒙端只做点选 —— 拖动省下的那一下点击，抵不过多一条「轨道宽度换算」的易错路径。
   * 每一项等宽（`layoutWeight(1)`），选中态在行内读 `this.runtimeSelectedModel`（@State 标记不进 key）。
   */
  @Builder
  runtimeEffortSegments() {
    Row({ space: Space.XS }) {
      ForEach(this.runtimeEffortOptions, (option: RuntimeSelectionOption) => {
        Text(effortDisplayLabel(option, RuntimeText.EFFORT_DEFAULT))
          .fontSize(FontSize.CAPTION)
          .fontWeight(this.effortHighlightId() === option.selectionId ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.effortHighlightId() === option.selectionId ? ink() : muted())
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .layoutWeight(1)
          .height(Control.ACTION_ROW)
          .borderRadius(Radius.S_PLUS)
          .backgroundColor(this.effortHighlightId() === option.selectionId ? raisedSurface() : Color.Transparent)
          .opacity(this.runtimeOptionSelectable(option, this.runtimeModelLoading) ? 1 : 0.45)
          .onClick(() => {
            if (!this.runtimeOptionSelectable(option, this.runtimeModelLoading)) {
              this.actionHint = option.disabledReason !== undefined
                ? option.disabledReason : RuntimeText.UPDATE_FAILED;
              return;
            }
            this.applyRuntimeSelection(RUNTIME_MODEL_KEY, option.selectionId);
          })
      }, (option: RuntimeSelectionOption) => optionRowKey(option))
    }
    .width('100%')
    .padding(Space.XS)
    .borderRadius(Radius.M_PLUS)
    .backgroundColor(subtle())
    .onAreaChange((oldArea: Area, newArea: Area) => {
      // 拖动换算要用的轨道宽度（上游同款：`onSizeChanged { trackWidthPx = it.width }`）。
      // ⚠️ 只在布局变化时回调，所以必须在拖动开始前就先量到，不能等到手势里再取。
      // 取值写法照 TerminalScreen 的先例（模板串 + parseFloat），不对 Length 做类型断言。
      const width = Number.parseFloat(`${newArea.width}`);
      this.runtimeEffortTrackWidth = Number.isFinite(width) ? width : 0;
    })
    .gesture(
      PanGesture({ fingers: 1, distance: 5 })
        .onActionStart((event: GestureEvent) => {
          // 上游 onDragStarted：先清掉拖动选择，再按按下位置选一次
          this.runtimeEffortDragId = '';
          this.effortSelectAt(event);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.effortSelectAt(event);
        })
        .onActionEnd(() => {
          // 上游 onDragStopped：只有真的换了档位才提交（同一个值不重复发请求）
          const selection = this.runtimeEffortDragId;
          this.runtimeEffortDragId = '';
          if (selection.length > 0 && selection !== this.runtimeSelectedModel) {
            this.applyRuntimeSelection(RUNTIME_MODEL_KEY, selection);
          }
        })
    )
  }

  /** 拖动中高亮的档位：拖动优先，否则是当前生效值（上游 `(dragSelectionId ?: selectedId)`）。 */
  private effortHighlightId(): string {
    return this.runtimeEffortDragId.length > 0 ? this.runtimeEffortDragId : this.runtimeSelectedModel;
  }

  /**
   * 按手势落点选档位（上游 `EffortSegments.selectAt`）：
   * `index = (position / trackWidth) * options.size`，越界夹到 `[0, lastIndex]`；
   * 只有**可用**的档位才会被记为拖动选择（上游 `if (option.enabled) dragSelectionId = ...`）。
   */
  private effortSelectAt(event: GestureEvent): void {
    const options = this.runtimeEffortOptions;
    const width = this.runtimeEffortTrackWidth;
    if (width <= 0 || options.length === 0 || event.fingerList.length === 0) {
      return;
    }
    if (this.runtimeSelectionBusy() || this.runtimeModelLoading) {
      return;
    }
    let index = Math.floor((event.fingerList[0].localX / width) * options.length);
    if (index < 0) {
      index = 0;
    }
    if (index > options.length - 1) {
      index = options.length - 1;
    }
    const option = options[index];
    if (this.runtimeOptionSelectable(option, this.runtimeModelLoading)) {
      this.runtimeEffortDragId = option.selectionId;
    }
  }

  /**
   * store → @State 快照（只在 `pull()` 里调）。
   *
   * ⚠️ 选中项一律由**服务端 state.selections** 经 `validatedSelection` 校验得出，
   * 不做本地乐观状态：本地先亮、服务端拒绝后不还原，用户看到的就是假回显。
   */
  private syncRuntimeSelections(): void {
    const modelOptions = modelSelectionOptions(this.store.modelCatalog);
    const permissionOptions = permissionSelectionOptions(this.store.permissionCatalog);
    const state = this.store.runtimeState;
    const selections = state !== undefined ? state.selections : undefined;
    const selectedModel = validatedSelection(modelOptions, selectionOf(selections, RUNTIME_MODEL_KEY));
    const selectedPermission = validatedSelection(
      permissionOptions, selectionOf(selections, RUNTIME_PERMISSION_KEY));
    const groups = groupByModelLabel(modelOptions);
    const activeGroup = selectedModelGroup(groups, selectedModel);
    const runtimeLabel = state !== undefined
      ? (state.runtimeName !== undefined ? state.runtimeName : state.runtime) : '';

    this.runtimeModelOptions = modelOptions;
    this.runtimeModelGroups = groups;
    this.runtimePermissionOptions = permissionOptions;
    this.runtimeEffortOptions = effortOptionsForGroup(activeGroup);
    this.runtimeEffortNotes = disabledEffortNotes(this.runtimeEffortOptions, RuntimeText.EFFORT_DEFAULT);
    this.runtimeEffortTitle = effortSectionTitle(activeGroup, runtimeLabel);
    this.runtimeSelectedModel = selectedModel;
    this.runtimeSelectedPermission = selectedPermission;
    this.runtimeEffortLabel = selectedEffortLabel(activeGroup, selectedModel, RuntimeText.EFFORT_DEFAULT);
    this.runtimePermissionLabel = selectedPermissionLabel(permissionOptions, selectedPermission);
  }

  private runtimeSectionTitle(section: string): string {
    if (section === RUNTIME_EFFORT_SECTION) {
      return this.runtimeEffortTitle;
    }
    if (section === RUNTIME_PERMISSION_KEY) {
      return RuntimeText.PERMISSION_MODE;
    }
    return RuntimeText.SELECT_MODEL;
  }

  /**
   * 段标题右侧的「当前值」。
   *
   * 上游对应的是 ModelPage 那个二级入口行的副文本（`SessionRuntimeSettingsSheet.kt:168` 的
   * `listOfNotNull(permissionLabel, effortLabel).joinToString(" · ")`）—— 鸿蒙端是内联展开、
   * 没有二级入口可以承载它，于是就近挂在对应段标题的右侧（信息不丢，位置变）。
   * 模型段没有对应项：上游那份摘要里本来就没有模型名（模型名在推理强度段的标题里）。
   */
  private runtimeSectionValue(section: string): string {
    if (section === RUNTIME_EFFORT_SECTION) {
      return this.runtimeEffortLabel;
    }
    if (section === RUNTIME_PERMISSION_KEY) {
      return this.runtimePermissionLabel;
    }
    return '';
  }

  private runtimeSectionLoading(section: string): boolean {
    return section === RUNTIME_PERMISSION_KEY ? this.runtimePermissionLoading : this.runtimeModelLoading;
  }

  private runtimeSectionError(section: string): string {
    return section === RUNTIME_PERMISSION_KEY ? this.runtimePermissionError : this.runtimeModelError;
  }

  private runtimeSectionState(section: string): string {
    const isModel = section !== RUNTIME_PERMISSION_KEY;
    const options = isModel ? this.runtimeModelOptions : this.runtimePermissionOptions;
    const loading = isModel ? this.runtimeModelLoading : this.runtimePermissionLoading;
    return catalogSectionState(options, loading, this.runtimeSectionError(section));
  }

  /**
   * 上游的 `busy`（`SessionDetailScreen.kt:1811`）：
   * `state.selectionUpdating || state.takeoverInFlight` —— 选型提交与接管请求期间都不许再点。
   */
  private runtimeSelectionBusy(): boolean {
    return this.runtimeBusy || this.takeoverBusy;
  }

  /** 一项此刻能不能点：`!busy && !loading && option.enabled`（上游三处 enabled 是同一式子）。 */
  private runtimeOptionSelectable(option: RuntimeSelectionOption, loading: boolean): boolean {
    return optionSelectable(option, loading, this.runtimeSelectionBusy());
  }

  private modelRowInteractive(group: ModelOptionGroup): boolean {
    const option = displayOptionForGroup(group, this.runtimeSelectedModel);
    return option !== undefined && this.runtimeOptionSelectable(option, this.runtimeModelLoading);
  }

  private permissionRowInteractive(option: RuntimeSelectionOption): boolean {
    return this.runtimeOptionSelectable(option, this.runtimePermissionLoading);
  }

  /** 展开面板时按需拉目录（能力位不可用 / 已在加载 / 同一个键刷过，都不重复发）。 */
  private reloadRuntimeCatalogs(): void {
    this.ensureRuntimeCatalog(RUNTIME_MODEL_KEY);
    this.ensureRuntimeCatalog(RUNTIME_PERMISSION_KEY);
  }

  /**
   * 上游在 `LaunchedEffect` 里做的两件事合成一次判定：
   * ① 能力位可用但目录还没有 → 拉一次；
   * ② 目录已有、但服务端给的选中值已经不在目录里（目录换了一版）→ 也拉一次。
   * 幂等键由 `catalogRefreshKey` 生成，同一个键只刷一次，
   * 否则「缺失 → 刷新 → 仍缺失」会无限打转。
   */
  private ensureRuntimeCatalog(section: string): void {
    const isModel = section !== RUNTIME_PERMISSION_KEY;
    const capability = isModel ? RUNTIME_MODEL_CAPABILITY : RUNTIME_PERMISSION_CAPABILITY;
    if (!this.store.can(capability)) {
      return;
    }
    if (isModel ? this.runtimeModelLoading : this.runtimePermissionLoading) {
      return;
    }
    const modelCatalog = this.store.modelCatalog;
    const permissionCatalog = this.store.permissionCatalog;
    const defined = isModel ? modelCatalog !== undefined : permissionCatalog !== undefined;
    let revision = 0;
    if (isModel) {
      revision = modelCatalog !== undefined ? modelCatalog.revision : 0;
    } else {
      revision = permissionCatalog !== undefined ? permissionCatalog.revision : 0;
    }
    const selection = isModel ? this.runtimeSelectedModel : this.runtimeSelectedPermission;
    const options = isModel ? this.runtimeModelOptions : this.runtimePermissionOptions;
    const key = catalogRefreshKey(
      defined, true, selection, options, this.store.capabilities.revision, revision);
    if (key.length === 0 || key === this.runtimeRefreshKey(section)) {
      return;
    }
    this.setRuntimeRefreshKey(section, key);
    this.reloadRuntimeCatalog(section);
  }

  /**
   * 拉一次目录，并维护三态所需的「在途 / 失败」标志。
   *
   * 失败判定：`store.loadModelCatalog()` 内部把异常**吞掉写进 `store.error`**（不抛），
   * 所以「调用后目录引用没变」就等价于这次没拿到新目录；此时若 store 里留了错误原话，
   * 就当作加载失败（三态里的 error）；否则是服务端这次没给目录（三态里的 empty）。
   */
  private async reloadRuntimeCatalog(section: string): Promise<void> {
    const isModel = section !== RUNTIME_PERMISSION_KEY;
    const before = isModel ? this.store.modelCatalog : this.store.permissionCatalog;
    if (isModel) {
      this.runtimeModelLoading = true;
      this.runtimeModelError = '';
    } else {
      this.runtimePermissionLoading = true;
      this.runtimePermissionError = '';
    }
    this.store.error = '';
    let failure = '';
    try {
      if (isModel) {
        await this.store.loadModelCatalog();
      } else {
        await this.store.loadPermissionCatalog();
      }
      const after = isModel ? this.store.modelCatalog : this.store.permissionCatalog;
      if (after === before && this.store.error.length > 0) {
        failure = this.store.error;
      }
    } catch (error) {
      failure = error instanceof Error ? (error as Error).message : String(error);
    }
    if (isModel) {
      this.runtimeModelLoading = false;
      this.runtimeModelError = failure;
    } else {
      this.runtimePermissionLoading = false;
      this.runtimePermissionError = failure;
    }
    this.pull();
  }

  private runtimeRefreshKey(section: string): string {
    return section === RUNTIME_PERMISSION_KEY ? this.runtimePermissionRefreshKey : this.runtimeModelRefreshKey;
  }

  private setRuntimeRefreshKey(section: string, key: string): void {
    if (section === RUNTIME_PERMISSION_KEY) {
      this.runtimePermissionRefreshKey = key;
    } else {
      this.runtimeModelRefreshKey = key;
    }
  }

  /** 「重试」：先清掉幂等键再拉一次，否则同一个键会被去重挡掉。 */
  private retryRuntimeCatalog(section: string): void {
    this.setRuntimeRefreshKey(section, '');
    this.reloadRuntimeCatalog(section);
  }

  /**
   * 提交选型（上游 `updateSelection`）：点选即发 `/runtime/selections`，
   * **不做本地乐观更新** —— 回显一律等服务端返回的 state
   * （`store.setSelections` 把它落进 `runtimeState` 后再 notify）。
   */
  private async applyRuntimeSelection(key: string, selectionId: string): Promise<void> {
    if (this.runtimeBusy || selectionId.length === 0) {
      return;
    }
    this.runtimeBusy = true;
    const selections: Record<string, string> = {};
    selections[key] = selectionId;
    try {
      await this.store.setSelections(selections);
    } catch (error) {
      // store 内部已把失败写进 error / notice，这里只需要复位在途标志
    }
    this.runtimeBusy = false;
    this.pull();
  }

}

function guessMediaType(name: string): string {
  const dot = name.lastIndexOf('.');
  const extension = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  if (extension === 'png') {
    return 'image/png';
  }
  if (extension === 'jpg' || extension === 'jpeg') {
    return 'image/jpeg';
  }
  if (extension === 'gif') {
    return 'image/gif';
  }
  if (extension === 'webp') {
    return 'image/webp';
  }
  if (extension === 'pdf') {
    return 'application/pdf';
  }
  if (extension === 'json') {
    return 'application/json';
  }
  if (extension === 'txt' || extension === 'md' || extension === 'log') {
    return 'text/plain';
  }
  return 'application/octet-stream';
}

/**
 * 草稿的 preferences 后端。
 *
 * 为什么放在页面文件里、而不是 `store/ComposerDraftStore.ets` 里：
 * store 刻意保持**零 @kit 依赖**（整份存取策略因此能在 Node 里直接断言，
 * 见 `tools/logic-test/suite-input.mjs`），preferences 这类平台能力由页面装配进来。
 * `getPreferencesSync` 对同名 store 返回同一个实例，所以重复构造没有额外开销。
 */
class DraftPrefsStorage implements DraftStorage {
  /**
   * 后端是否真的可用（preferences 打开成功）。
   * ⚠️ 页面只 attach `ready === true` 的后端 —— 把一个「哑后端」注入进去也会让
   * `hasStorage()` 变 true，之后就再也不会重试注入，草稿会永久读不出来。
   */
  ready: boolean = false;
  private store?: preferences.Preferences;

  constructor(context: common.Context) {
    try {
      const options: preferences.Options = { name: 'agents_anywhere_composer_drafts' };
      this.store = preferences.getPreferencesSync(context, options);
      this.ready = this.store !== undefined;
    } catch (error) {
      // 打不开就退化为「本次运行内有效」：不能因为存不了草稿让输入本身不可用
      this.store = undefined;
      this.ready = false;
    }
  }

  read: (key: string) => string = (key: string): string => {
    const store = this.store;
    if (store === undefined) {
      return '';
    }
    try {
      const value = store.getSync(key, '');
      return typeof value === 'string' ? value as string : '';
    } catch (error) {
      return '';
    }
  };

  write: (key: string, value: string) => void = (key: string, value: string): void => {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (error) {
      // 落盘失败不阻塞输入
    }
  };

  remove: (key: string) => void = (key: string): void => {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.deleteSync(key);
      store.flush();
    } catch (error) {
    }
  };
}
