/**
 * 斜杠指令目录的**进程内缓存**（R91）。
 *
 * 为什么需要它：同一个会话的指令目录会被两处读到 ——
 *  ① 会话详情页打开指令面板（`SessionDetailScreen.loadSessionCommands()`）；
 *  ② 同一会话再次打开面板 / 从草稿态建会话后落到真会话页。
 * 两次都打一次 `GET /sessions/{id}/runtime/commands` 没有必要，而且服务端通道
 * 不可用时会**反复**拿到同一句错误（`session capability is unavailable: session.commands`）。
 *
 * ⚠️ 缓存的是**结果**，包括「不可用」这个结果（带原因），这样面板第二次打开时能
 * **立刻**如实显示「服务端指令通道不可用」+ 内置目录，而不是先白一下再报错。
 * ⚠️ 刻意**不落盘**（不要 preferences）：指令目录是运行时的、随时可能变，
 * 跨进程缓存住会变成「显示的还是上个版本 Agent 的指令」。
 *
 * 目录渲染所需的纯逻辑全在 `model/SlashCommand.ets`；本文件只管「记住哪一份」。
 */

import { RemoteSessionCommand } from '../model/Types';
import {
  SlashCommandCatalog, builtInCatalog, serverCatalog, unavailableCatalog
} from '../model/SlashCommand';

export class SlashCommandStore {
  private static instance?: SlashCommandStore;

  /**
   * 每个会话最近的目录结果（含「不可用」）。
   *
   * ⚠️ 键是 sessionId；草稿态（sessionId 为空串）**不进这张表** —— 草稿态永远用
   * `draftCatalog()`，见 `model/SlashCommand.ets` 文件头对「为什么草稿态不请求服务端」的说明。
   */
  private serverBySession: Map<string, SlashCommandCatalog> = new Map<string, SlashCommandCatalog>();

  static get(): SlashCommandStore {
    if (SlashCommandStore.instance === undefined) {
      SlashCommandStore.instance = new SlashCommandStore();
    }
    return SlashCommandStore.instance;
  }

  /** 草稿态目录（内置清单，不依赖服务端）。 */
  draftCatalog(): SlashCommandCatalog {
    return builtInCatalog();
  }

  /** 服务端通道不可用时的目录（内置清单 + 原因）。 */
  unavailable(reason: string): SlashCommandCatalog {
    return unavailableCatalog(reason);
  }

  /** 某个会话上次拿到的目录（没有则 undefined）。 */
  cached(sessionId: string): SlashCommandCatalog | undefined {
    if (sessionId.length === 0) {
      return undefined;
    }
    return this.serverBySession.get(sessionId);
  }

  /** 记下服务端返回的目录。 */
  remember(sessionId: string, commands: RemoteSessionCommand[]): SlashCommandCatalog {
    const catalog = serverCatalog(commands);
    if (sessionId.length > 0) {
      this.serverBySession.set(sessionId, catalog);
    }
    return catalog;
  }

  /** 记下「服务端通道不可用」这个结果（连同原因）。 */
  rememberUnavailable(sessionId: string, reason: string): SlashCommandCatalog {
    const catalog = unavailableCatalog(reason);
    if (sessionId.length > 0) {
      this.serverBySession.set(sessionId, catalog);
    }
    return catalog;
  }

  /** 丢掉某个会话的缓存（发送指令后目录可能变化时调用）。 */
  forget(sessionId: string): void {
    if (sessionId.length > 0) {
      this.serverBySession.delete(sessionId);
    }
  }
}
