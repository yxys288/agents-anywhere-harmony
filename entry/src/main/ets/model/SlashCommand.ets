/**
 * 斜杠指令目录（R91，对应 DSH 原生指令服务）。
 *
 * 上游契约：DSH 的指令**不是发消息执行的** —— `dsh-commands.execute()` 原文
 * "without sending it to the model"；AA 服务端为此开了官方通道
 * （能力 `session.commands` + `GET/POST /sessions/{id}/runtime/commands`，
 * 见 `specs/01-api-spec.md` §指令）。连接器侧形状见
 * `connector/connector/server/runtime_turn_rpc.py` 的 `dispatch_session_commands`。
 *
 * ⚠️ **为什么需要「内置目录」**（本文件的主体）：
 *  `session.commands` 这条能力依赖 DSH 桌面端的 bridge 补丁
 *  （`tools/dsh-bridge-patch/patch.mjs`）。补丁未打 / DSH 被升级覆盖时，
 *  服务端会直接回 `session capability is unavailable: session.commands`，
 *  于是「新建对话时看不到任何指令」——**而不是**「这台 Agent 没有指令」。
 *  所以草稿态（还没有 sessionId，根本无从请求服务端目录）与通道不可用时，
 *  一律回落到本文件维护的内置清单，并在 UI 上**如实标注来源**。
 *
 * ⚠️ 内置清单只解决「**看得到、点得动**」。执行语义仍分场景（见 `SlashCommandItem.sessionBound`
 * 与 `slashCommandUsableInDraft`）：作用于已有会话的指令（compact / export / file）
 * 在草稿态**必须禁用** —— 把它们当首条消息发出去会被 DSH 当普通文本送进模型，
 * 用户以为压缩了其实没有（开发期验证记录 明确警示）。
 *
 * 本文件零 ArkUI / 零 @kit 依赖，可被 Node 侧直接转译断言。
 */

import { RemoteSessionCommand } from './Types';

/** 目录来源：客户端内置 / 服务端 `GET /sessions/{id}/runtime/commands`。 */
export enum SlashCommandSource {
  BUILT_IN = 'builtin',
  SERVER = 'server'
}

/** 一条斜杠指令（UI 渲染所需的全部字段，来自内置清单或服务端条目）。 */
export interface SlashCommandItem {
  /** 不含斜杠的指令 id（服务端 `command.id`，如 `compact`）。 */
  id: string;
  /** 一句话说明（内置清单为中文译文；服务端为原样 `description`）。 */
  description: string;
  /** 参数提示（DSH 的 `input.hint` 原文），空串 = 无需参数。 */
  hint: string;
  /** 是否需要补参数（true ⇒ 只能把 `/id ` 插进草稿，让用户自己补）。 */
  acceptsArgs: boolean;
  /** 是否作用于**已存在的会话**（草稿态没有会话 ⇒ 必须禁用）。 */
  sessionBound: boolean;
  /** 服务端条目的可用性（内置清单恒 true）。 */
  enabled: boolean;
  /** 不可用原因（服务端 `disabledReason`；内置清单为空串）。 */
  disabledReason: string;
  /** 别名（服务端 `aliases`；内置清单为空数组）。 */
  aliases: string[];
}

/** 一份可渲染的指令目录 + 它的**来源**（UI 必须把来源显示出来）。 */
export interface SlashCommandCatalog {
  items: SlashCommandItem[];
  source: SlashCommandSource;
  /** 服务端目录是否可用（false ⇒ 当前是内置回落）。 */
  serverAvailable: boolean;
  /** 服务端目录的失败原因原文（空串 = 没失败）。 */
  serverError: string;
}

/** 解析用户输入的 `/id args...` 行。 */
export interface SlashCommandParse {
  id: string;
  args: string[];
  /** 原样整行（执行走 `raw` 时用得到）。 */
  raw: string;
}

/**
 * **作用于已有会话**的指令 id（草稿态禁用它们）。
 *
 * 判据不是「谁是危险操作」，而是 DSH 侧的语义：这三条都读写**当前会话的产物**
 * （上下文、日志、文件），草稿态还没有会话可作用。
 */
const SESSION_BOUND_COMMAND_IDS: string[] = ['compact', 'export', 'file'];

/** 需要补参数的指令 id（内置清单用；服务端条目以 `acceptsArgs` 字段为准）。 */
const ARG_COMMAND_IDS: string[] = ['goal', 'plan', 'permission', 'feedback'];

/**
 * 内置指令清单 —— **DSH 当前真实注册的那 7 条**。
 *
 * 来源：DSH 安装包 `app.asar` 里全部 `ctx.commands.register({...})` 调用点
 * （由 Lead 于 R91 抽取；本文件不重复猜测）。`description` 是这些英文原文的中文译文，
 * `hint` 逐字保留原文（用户要照着补参数，不能译）。
 *
 * ⚠️ **没有 `/help`** —— 全文搜索 app.asar 不存在该指令；放进来会让用户点了必然失败。
 */
const BUILT_IN_SLASH_COMMANDS: SlashCommandItem[] = [
  {
    id: 'compact',
    description: '压缩较早的对话历史（缩短上下文占用）',
    hint: '',
    acceptsArgs: false,
    sessionBound: true,
    enabled: true,
    disabledReason: '',
    aliases: []
  },
  {
    id: 'export',
    description: '把这次会话的日志导出为 ZIP 下载',
    hint: '',
    acceptsArgs: false,
    sessionBound: true,
    enabled: true,
    disabledReason: '',
    aliases: []
  },
  {
    id: 'file',
    description: '会话文件操作（DSH 原生 file 指令）',
    hint: '',
    acceptsArgs: false,
    sessionBound: true,
    enabled: true,
    disabledReason: '',
    aliases: []
  },
  {
    id: 'feedback',
    description: '记录一条关于本次会话的反馈',
    hint: '<text>',
    acceptsArgs: true,
    sessionBound: false,
    enabled: true,
    disabledReason: '',
    aliases: []
  },
  {
    id: 'goal',
    description: '设置或查看长期任务的目标（不带参数 = 查看当前目标）',
    hint: '[<objective>|clear|edit <objective>|pause|resume]',
    acceptsArgs: true,
    sessionBound: false,
    enabled: true,
    disabledReason: '',
    aliases: []
  },
  {
    id: 'permission',
    description: '切换权限预设（沙箱模式 + 审批策略）',
    hint: '<preset>',
    acceptsArgs: true,
    sessionBound: false,
    enabled: true,
    disabledReason: '',
    aliases: []
  },
  {
    id: 'plan',
    description: '进入或退出计划模式（/plan off 退出）',
    hint: '[off|message]',
    acceptsArgs: true,
    sessionBound: false,
    enabled: true,
    disabledReason: '',
    aliases: []
  }
];

/** 指令是否作用于已有会话（内置清单与服务端目录共用同一条判据）。 */
export function isSessionBoundCommand(id: string): boolean {
  return SESSION_BOUND_COMMAND_IDS.indexOf(id) >= 0;
}

/** 内置清单的**副本**（调用方改不动模块级常量里的对象）。 */
export function builtInSlashCommands(): SlashCommandItem[] {
  const out: SlashCommandItem[] = [];
  for (let i = 0; i < BUILT_IN_SLASH_COMMANDS.length; i++) {
    const item = BUILT_IN_SLASH_COMMANDS[i];
    const copy: SlashCommandItem = {
      id: item.id,
      description: item.description,
      hint: item.hint,
      acceptsArgs: item.acceptsArgs,
      sessionBound: item.sessionBound,
      enabled: item.enabled,
      disabledReason: item.disabledReason,
      aliases: item.aliases.slice()
    };
    out.push(copy);
  }
  return out;
}

/** 内置目录（服务端目录不可用 / 草稿态时的回落）。 */
export function builtInCatalog(): SlashCommandCatalog {
  const catalog: SlashCommandCatalog = {
    items: builtInSlashCommands(),
    source: SlashCommandSource.BUILT_IN,
    serverAvailable: false,
    serverError: ''
  };
  return catalog;
}

/** 服务端 `RemoteSessionCommand` → 可渲染条目。 */
export function slashCommandFromServer(command: RemoteSessionCommand): SlashCommandItem {
  const item: SlashCommandItem = {
    id: command.id,
    description: command.description !== undefined ? command.description : command.title,
    hint: argsHintOf(command),
    acceptsArgs: command.acceptsArgs,
    sessionBound: isSessionBoundCommand(command.id),
    enabled: command.enabled !== false,
    disabledReason: command.disabledReason !== undefined ? command.disabledReason : '',
    aliases: command.aliases.slice()
  };
  return item;
}

/**
 * 服务端条目的参数提示。
 *
 * 线格式里没有独立 hint 字段，约定放在 `argsSchema.hint`（mock 服务端就是这么写的，
 * 见 `tools/mock-server/server.mjs` 的 `/runtime/commands` 夹具）。
 */
function argsHintOf(command: RemoteSessionCommand): string {
  const schema = command.argsSchema;
  if (schema === undefined) {
    return '';
  }
  const hint = schema['hint'];
  if (typeof hint === 'string') {
    return hint as string;
  }
  return '';
}

/** 服务端目录（可用）。 */
export function serverCatalog(commands: RemoteSessionCommand[]): SlashCommandCatalog {
  const items: SlashCommandItem[] = [];
  for (let i = 0; i < commands.length; i++) {
    items.push(slashCommandFromServer(commands[i]));
  }
  const catalog: SlashCommandCatalog = {
    items: items,
    source: SlashCommandSource.SERVER,
    serverAvailable: true,
    serverError: ''
  };
  return catalog;
}

/**
 * 服务端目录**不可用**时的目录：内置清单 + 失败原因。
 *
 * ⚠️ 这里刻意**不返回空列表** —— 「空面板」会被用户读成「这个 App 没做指令」，
 * 而真实原因是「服务端指令通道不可用」（见文件头注释）。
 */
export function unavailableCatalog(reason: string): SlashCommandCatalog {
  const catalog: SlashCommandCatalog = {
    items: builtInSlashCommands(),
    source: SlashCommandSource.BUILT_IN,
    serverAvailable: false,
    serverError: reason
  };
  return catalog;
}

/** 目录来源的一句话标注（UI 第一行就显示它，不能让用户误以为是服务端返回的）。 */
export function catalogSourceLabel(catalog: SlashCommandCatalog, draft: boolean): string {
  if (draft) {
    return '内置指令目录（草稿态还没有会话，服务端目录未请求）';
  }
  if (catalog.serverAvailable) {
    return '服务端指令目录';
  }
  if (catalog.serverError.length > 0) {
    return `内置指令目录（服务端指令通道不可用：${catalog.serverError}）`;
  }
  return '内置指令目录（服务端指令通道不可用）';
}

/** 草稿态这条指令能不能用（作用于会话的三条禁用）。 */
export function slashCommandUsableInDraft(item: SlashCommandItem): boolean {
  return item.enabled && !item.sessionBound;
}

/** 这条指令在草稿态为什么不能用（可用时返回空串）。 */
export function draftCommandDisabledReason(item: SlashCommandItem): string {
  if (!item.enabled) {
    return item.disabledReason.length > 0 ? item.disabledReason : '这条指令当前不可用。';
  }
  if (item.sessionBound) {
    return '需要先建立会话后使用。';
  }
  return '';
}

/** 点选一条指令时要插入草稿的文本（需要参数的带一个尾随空格，方便直接补参数）。 */
export function slashInsertionFor(item: SlashCommandItem): string {
  return item.acceptsArgs ? `/${item.id} ` : `/${item.id}`;
}

/**
 * 把指令插入已有草稿 —— **绝不覆盖用户已输入的文字**（内容为空才直接填入，
 * 否则换行追加）。
 */
export function appendSlashToDraft(draft: string, insertion: string): string {
  if (draft.trim().length === 0) {
    return insertion;
  }
  const trimmed = draft.replace(/\s+$/, '');
  return `${trimmed}\n${insertion}`;
}

/**
 * 点选指令后给用户的一句话回执。
 *
 * ⚠️ 措辞是硬要求：草稿态**没有**执行任何 DSH 指令（会话还不存在），
 * 不能写「已执行 /compact」——那是在骗用户（见文件头注释）。
 */
export function draftSlashNotice(item: SlashCommandItem): string {
  if (item.acceptsArgs) {
    const hint = item.hint.length > 0 ? `（参数：${item.hint}）` : '';
    return `已填入 /${item.id}${hint}，补完参数后点「开始聊天」发送 —— 它会作为首条消息交给 Agent。`;
  }
  return `已填入 /${item.id}，点「开始聊天」发送 —— 它会作为首条消息交给 Agent（不是执行 DSH 指令）。`;
}

/** 已建会话里点选指令后的回执（这条才是真正的命令执行）。 */
export function sessionSlashNotice(item: SlashCommandItem): string {
  if (item.acceptsArgs) {
    const hint = item.hint.length > 0 ? `（参数：${item.hint}）` : '';
    return `已填入 /${item.id}${hint}，补完参数后发送。`;
  }
  return `正在执行 /${item.id}…`;
}

/** 按 id（或别名，大小写不敏感）查一条指令。 */
export function findSlashCommand(items: SlashCommandItem[], id: string): SlashCommandItem | undefined {
  const needle = id.trim().toLowerCase();
  if (needle.length === 0) {
    return undefined;
  }
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.id.toLowerCase() === needle) {
      return item;
    }
    for (let j = 0; j < item.aliases.length; j++) {
      if (item.aliases[j].toLowerCase() === needle) {
        return item;
      }
    }
  }
  return undefined;
}

/**
 * 解析一行 `/id args…`（不是指令行 ⇒ undefined）。
 *
 * 供「用户手打指令直接发送」这条路径判定：只有**已建会话**才会拿它去执行，
 * 草稿态仍然按普通首条消息处理（见文件头注释）。
 */
export function parseSlashCommandLine(text: string): SlashCommandParse | undefined {
  const raw = text.trim();
  if (raw.length === 0 || raw.charAt(0) !== '/') {
    return undefined;
  }
  const parts = raw.split(/\s+/);
  const head = parts[0].slice(1);
  if (head.length === 0) {
    return undefined;
  }
  const args: string[] = [];
  for (let i = 1; i < parts.length; i++) {
    if (parts[i].length > 0) {
      args.push(parts[i]);
    }
  }
  const parsed: SlashCommandParse = { id: head, args: args, raw: raw };
  return parsed;
}

/** 目录里是否有任何一条能在草稿态用（面板据此决定要不要显示「需要先建立会话」那行）。 */
export function draftUsableCount(items: SlashCommandItem[]): number {
  let count = 0;
  for (let i = 0; i < items.length; i++) {
    if (slashCommandUsableInDraft(items[i])) {
      count += 1;
    }
  }
  return count;
}

/** 内置清单里「需要补参数」的 id 集合（服务端目录不经此判据，它与 ARG_COMMAND_IDS 同源，仅作自检）。 */
export function isArgCommandId(id: string): boolean {
  return ARG_COMMAND_IDS.indexOf(id) >= 0;
}

/**
 * **草稿态**手打了指令行时的拦截理由（空串 = 放行）。
 *
 * ⚠️ 这是「不假装成功」的关键一环：草稿态没有服务端会话，`/compact` 这类作用于会话的指令
 * 如果被当普通文本发出去，DSH 会把它送进模型 —— 用户以为压缩了其实没有。所以**在这里拦住**
 * 并给出可操作的理由（先建立会话），而不是默默发出去。
 *
 * 未知的 `/xxx`（不在目录里）放行：那可能只是用户正文里以斜杠开头的内容（如路径），
 * 客户端不该替模型做这个判断。
 */
export function draftTypedCommandBlocker(items: SlashCommandItem[], text: string): string {
  const parsed = parseSlashCommandLine(text);
  if (parsed === undefined) {
    return '';
  }
  const item = findSlashCommand(items, parsed.id);
  if (item === undefined) {
    return '';
  }
  return draftCommandDisabledReason(item);
}
