#!/usr/bin/env node
/**
 * DSH 侧补丁（R52）：把「上下文用量」与「原生指令」接到 AA 的官方链路上。
 *
 * 为什么必须动 DSH 侧（三处独立证据，来自开发期验证记录，不随仓库分发）：
 *  · 上下文用量：DSH 自己算好了（`contextPressure` / `tokenUsage` 两个投影），
 *    但 bridge 插件**从没把它放进 `session.getState`**（`grep contextPressure` 在插件里 0 命中）；
 *  · 原生指令：AA 服务端**有**官方通道（`session.commands` 能力 + `/sessions/{id}/runtime/commands`），
 *    但 bridge 把 `session.commands` 声明成 unsupported、也没有对应 RPC 分支；
 *    连接器的 DSH runtime 也没实现 `list_commands` / `execute_command`（基类默认返回空 / 抛 unsupported）。
 *  · 而且 DSH 的指令**不是发消息能执行的**（`dsh-commands.execute()` 注释：
 *    "Parse and execute a known command without sending it to the model"）⇒ 只能走这个 RPC。
 *
 * ⚠️ 补丁打在 **DSH 安装目录**里（不是 aa-hm 仓库）：
 *      <DSH app>/node_modules/@agents-anywhere/dsh-bridge-next/lib/index.js
 *      <DSH app>/node_modules/@agents-anywhere/dsh-bridge-next/lib/bundled-connector/connector/runtimes/dsh/runtime.py
 *   DSH 升级会覆盖这两个文件 ⇒ **升级后重跑本脚本**（幂等：已打过就跳过）。
 *   连接器是**可编辑安装**（`_editable_impl_anywhere_cli.pth` 指向 bundled-connector）⇒ 改完重启连接器即生效。
 *
 * 用法：
 *   node patch.mjs --check                  # 只报告当前状态
 *   node patch.mjs                          # 应用（幂等）
 *   node patch.mjs --revert                 # 撤销
 *   node patch.mjs --app="<DSH 安装目录>"             # 指定 DSH 安装位置（或环境变量 DSH_APP）
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/**
 * ⚠️ **R81：DSH 换过安装形态，插件现在装在「用户 profile」里** —— 这里不再写死某个用户名下的路径，
 * 而是按下面的顺序解析（换用户 / 换机器都不用改脚本）：
 *   ① `--app=<DSH 安装位置>`（最高优先级，参数契约与以前完全一致）；
 *   ② 环境变量 `DSH_APP`；
 *   ③ `<用户主目录>/.dsh/profiles/desktop`（现役形态，2026-09-24 真机实测：补丁在这里生效）；
 *   ④ `%LOCALAPPDATA%\Programs\DSH Desktop Beta\resources\app`（旧安装形态）。
 * 一个都解析不到时报中文错误并提示用 `--app=` 指定；`--check` 会逐条报「已打 / 未打 / 找不到锚点」。
 */
function defaultApp() {
  const candidates = [];
  const home = os.homedir();
  if (home) {
    candidates.push(path.join(home, '.dsh', 'profiles', 'desktop'));
  }
  if (process.env.LOCALAPPDATA) {
    candidates.push(path.join(process.env.LOCALAPPDATA, 'Programs', 'DSH Desktop Beta', 'resources', 'app'));
  }
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return candidates[0] || '';
}
const DEFAULT_APP = defaultApp();
const args = process.argv.slice(2);
const checkOnly = args.includes('--check');
const revert = args.includes('--revert');
const appArg = args.find((a) => a.startsWith('--app='));
const APP = appArg ? appArg.slice('--app='.length).replace(/^"|"$/g, '') : (process.env.DSH_APP || DEFAULT_APP);

if (!APP) {
  console.error('未找到 DSH 安装位置。');
  console.error('  · 请用 --app=<DSH 安装目录> 指定（例如 node patch.mjs --app="C:/path/to/resources/app"），');
  console.error('  · 或设置环境变量 DSH_APP=<DSH 安装目录>。');
  process.exit(2);
}

const BRIDGE = path.join(APP, 'node_modules', '@agents-anywhere', 'dsh-bridge-next', 'lib', 'index.js');
const RUNTIME = path.join(APP, 'node_modules', '@agents-anywhere', 'dsh-bridge-next', 'lib',
  'bundled-connector', 'connector', 'runtimes', 'dsh', 'runtime.py');

/** 每条补丁：file / name / from / to（from 必须**恰好出现一次**；已应用则跳过）。 */
const PATCHES = [
  // ---------------- bridge 插件：会话状态里带上用量 ----------------
  {
    file: BRIDGE,
    name: 'state 读取两个用量投影',
    from: `\t\tconst projected = projections && (live ? projections.snapshot(live, [
\t\t\t"modelSelection",
\t\t\t"permissions",
\t\t\t"agentPreset"
\t\t]) : projections.restore({}, log.events, SessionLogOffset(0), log.session, log.inheritedEventCount).snapshot);`,
    to: `\t\tconst projected = projections && (live ? projections.snapshot(live, [
\t\t\t"modelSelection",
\t\t\t"permissions",
\t\t\t"agentPreset",
\t\t\t// AA-R52: DSH token-meter 的两个投影（上下文占用 / 累计用量）
\t\t\t"contextPressure",
\t\t\t"tokenUsage"
\t\t]) : projections.restore({}, log.events, SessionLogOffset(0), log.session, log.inheritedEventCount).snapshot);`
  },
  {
    file: BRIDGE,
    name: 'state 的 metadata 暴露用量',
    from: `\t\t\tmetadata: {
\t\t\t\tconfigurationSeq: Number(projected?.asOfSeq ?? events.at(-1)?.seq ?? -1),
\t\t\t\tagentPreset: agentPreset ?? null,`,
    to: `\t\t\tmetadata: {
\t\t\t\tconfigurationSeq: Number(projected?.asOfSeq ?? events.at(-1)?.seq ?? -1),
\t\t\t\tagentPreset: agentPreset ?? null,
\t\t\t\t// AA-R52: 上下文圆环的数据源（AA 服务端会原样透传 metadata，客户端读这两个键）。
\t\t\t\t// contextPressure: { contextWindow?, pressureTokens?, surfaceTokens, sampledSurfaceTokens? }
\t\t\t\t// tokenUsage:      { totals: {...}, last: {...} | null }
\t\t\t\tcontextPressure: projected?.values.contextPressure ?? null,
\t\t\t\ttokenUsage: projected?.values.tokenUsage ?? null,`
  },
  // ---------------- bridge 插件：能力声明 + controls ----------------
  {
    file: BRIDGE,
    name: 'capabilities 允许 session.commands',
    from: `\t\t...controls.permission ? ["catalog.permission"] : [],
\t\t...writable && controls.attachments ? ["runtime.attachment"] : []`,
    to: `\t\t...controls.permission ? ["catalog.permission"] : [],
\t\t...controls.commands ? ["session.commands"] : [],
\t\t...writable && controls.attachments ? ["runtime.attachment"] : []`
  },
  {
    file: BRIDGE,
    name: '插件把 commands 服务报给 capabilities',
    from: `\t\t\tpermission: this.configuration.canSelectPermission && (!id || !this.ctx.get("agents")?.get(id) || Boolean(this.ctx.get("commands").find(this.ctx.get("agents").get(id), "permission")))`,
    to: `\t\t\tpermission: this.configuration.canSelectPermission && (!id || !this.ctx.get("agents")?.get(id) || Boolean(this.ctx.get("commands").find(this.ctx.get("agents").get(id), "permission"))),
\t\t\t// AA-R52: DSH 的指令服务在就绪时对外声明 session.commands
\t\t\tcommands: Boolean(this.ctx.get("commands"))`
  },
  // ---------------- bridge 插件：RPC 分支 + 实现 ----------------
  {
    file: BRIDGE,
    name: '注册 session.commands 分支',
    from: `\t\t\tcase "session.getCapabilities": {`,
    to: `\t\t\t// AA-R52: DSH 原生指令（/compact、/plan…）。无 \`command\` 参数 ⇒ 列目录；有 ⇒ 执行。
\t\t\tcase "session.commands": return this.commands(params, signal);
\t\t\tcase "session.getCapabilities": {`
  },
  {
    file: BRIDGE,
    name: '实现 commands(params, signal)',
    from: `\tasync resolve(params, signal, includeUnavailable = false) {`,
    to: `\t/**
\t * AA-R52: DSH 原生指令的目录与执行。
\t *
\t * 描述符形状取自 \`@deepseek-ai/dsh-commands\` 的 \`descriptor\`
\t * （\`{ definitionId?, name, description, input?: { hint, attachments? } }\`），
\t * 映射成连接器 \`runtimes/dsh/bridge/models.py:commands()\` 期待的形状
\t * （\`{id|name, title|name, description, acceptsArgs, argsSchema, enabled}\`）。
\t *
\t * ⚠️ 执行**不走消息**：DSH 的 \`commands.execute(agent, line, …)\` 是服务调用，
\t * 把 \`/compact\` 当普通消息发出去只会进模型。这里直接转给 DSH 的指令服务。
\t */
\tasync commands(params, signal) {
\t\tconst id = await this.resolve(params, signal);
\t\tconst native = this.reader.native;
\t\tconst service = native?.ctx.get("commands");
\t\tif (!service) throw new BridgeError("UNSUPPORTED_OPERATION", "This DSH deployment does not provide commands.");
\t\tconst agent = native.ctx.get("agents")?.get(id);
\t\tif (!agent) throw new BridgeError("UNSUPPORTED_OPERATION", "This DSH session has no live Agent.");
\t\tconst requested = typeof params.command === "string" && params.command.length > 0 ? params.command : void 0;
\t\tif (!requested) {
\t\t\tconst limit = Number.isSafeInteger(params.limit) && params.limit > 0 ? params.limit : 100;
\t\t\tconst query = typeof params.query === "string" ? params.query.trim().toLowerCase() : "";
\t\t\tconst commands = service.list(agent)
\t\t\t\t.filter((descriptor) => query.length === 0 || String(descriptor.name).toLowerCase().includes(query))
\t\t\t\t.slice(0, limit)
\t\t\t\t.map((descriptor) => ({
\t\t\t\t\tid: descriptor.name,
\t\t\t\t\ttitle: "/" + descriptor.name,
\t\t\t\t\tdescription: descriptor.description,
\t\t\t\t\tacceptsArgs: Boolean(descriptor.input),
\t\t\t\t\t...descriptor.input ? { argsSchema: { hint: descriptor.input.hint } } : {},
\t\t\t\t\tenabled: true,
\t\t\t\t\tcategory: "dsh"
\t\t\t\t}));
\t\t\treturn { runtime: "dsh", revision: 1, commands };
\t\t}
\t\t// 执行：把命令名 + 参数拼回一条完整命令行（DSH 的 parseCommand 认这个形状）
\t\tconst rawArgs = Array.isArray(params.args) ? params.args.filter((value) => typeof value === "string") : [];
\t\tconst line = typeof params.raw === "string" && params.raw.length > 0
\t\t\t? params.raw
\t\t\t: "/" + requested + (rawArgs.length > 0 ? " " + rawArgs.join(" ") : "");
\t\tconst settled = await service.execute(agent, line, [], signal);
\t\tif (!settled) throw new BridgeError("INVALID_PARAMS", "Unknown DSH command: " + requested);
\t\tconst result = settled.result ?? {};
\t\treturn {
\t\t\truntime: "dsh",
\t\t\tcommand: requested,
\t\t\tok: result.kind === "success",
\t\t\tcode: result.kind,
\t\t\tmessage: result.text,
\t\t\tresult: { commandId: settled.commandId }
\t\t};
\t}
\tasync resolve(params, signal, includeUnavailable = false) {`
  },
  // ---------------- 连接器：DSH runtime 实现指令方法 ----------------
  {
    file: RUNTIME,
    name: '导入指令模型',
    from: `    RuntimeModelCatalog,
    RuntimePermissionCatalog,`,
    to: `    RuntimeModelCatalog,
    RuntimePermissionCatalog,
    RuntimeCommand,
    RuntimeCommandResult,`
  },
  {
    file: RUNTIME,
    name: '实现 list_commands / execute_command',
    from: `    async def list_sessions(
        self,
        limit: int = 100,`,
    to: `    async def list_commands(
        self,
        session_id: str,
        external_session_id: str | None = None,
        query: str | None = None,
        limit: int = 50,
    ) -> tuple[RuntimeCommand, ...]:
        """AA-R52: DSH 原生指令目录（bridge 的 session.commands）。"""
        return models.commands(await self._request("session.commands", {
            **_session_params(session_id, external_session_id), "query": query, "limit": limit,
        }))

    async def execute_command(
        self,
        session_id: str,
        command: str,
        external_session_id: str | None = None,
        raw: str | None = None,
        args: tuple[str, ...] = (),
    ) -> RuntimeCommandResult:
        """AA-R52: 执行 DSH 原生指令（不是发一条消息 —— DSH 的指令是服务调用）。"""
        return models.command_result(await self._request("session.commands", {
            **_session_params(session_id, external_session_id),
            "command": command, "raw": raw, "args": list(args),
        }), command)

    async def list_sessions(
        self,
        limit: int = 100,`
  },
  // ---------------- bridge 插件：压缩标记按「压缩身份」成键（R81） ----------------
  {
    file: BRIDGE,
    name: "压缩标记按 compactionId 成键（一次压缩只出一个 item）",
    // 改前：business key = String(event.seq) ⇒ compaction/start|summary|end|prune **每条记录各出一个 item**，
    // 一次压缩在时间线上就是 3~4 行「— 上下文压缩 —」（真机会话日志实测：4 次压缩 = 24 条记录 = 24 行）。
    // 改后：有 data.compactionId 的记录（start/summary/end）**共用同一个 key** ⇒ put 命中同一个 item id
    // （orderSeq 由 previous?.orderSeq 保住位置、revision 随 seq 递增）⇒ 一次压缩一个 item。
    // 无 id 的 compaction/prune 回落到 seq（它们在 DSH 日志里紧贴在所服务那次 start **之前**，
    // 归组由 App 侧 collapseCompactMarkers 的「向后归并」完成 —— 两层各自独立成立）。
    from: `\t\t} else if (String(event.type).startsWith("compaction/")) put("event", String(event.seq), event, "marker", "done", "system", {`,
    to: `\t\t} else if (String(event.type).startsWith("compaction/")) put("event", String(event.data?.compactionId ?? event.seq), event, "marker", "done", "system", {`
  }
];

function statusOf(text, patch) {
  const from = eolOf(text, patch.from);
  const to = eolOf(text, patch.to);
  const hasFrom = text.includes(from);
  const hasTo = text.includes(to);
  // ⚠️ 顺序要紧：本补丁是**增量式**的（`to` = `from` + 若干行）⇒ 打完之后 `from` **仍然命中**。
  // 所以先判 `to`：命中就是「已打」。（第一版先判 `from`，于是打完立刻自报「无法判断」。）
  if (hasTo) return 'applied';
  if (hasFrom) return 'todo';
  return 'missing';
}

/**
 * ⚠️ 目标文件的换行风格**不一致**：`index.js` 是纯 LF、`runtime.py` 是 CRLF。
 * 补丁里的锚点一律用 `\n` 写，按目标文件的实际风格转换后再匹配 ——
 * 否则「锚点明明照着源码抄的却找不到」（第一次就踩了这个）。
 */
function eolOf(text, anchor) {
  return text.includes('\r\n') ? anchor.replace(/\n/g, '\r\n') : anchor;
}

const cache = new Map();
function load(file) {
  if (!cache.has(file)) cache.set(file, readFileSync(file, 'utf8'));
  return cache.get(file);
}

let applied = 0;
let already = 0;
const problems = [];

for (const patch of PATCHES) {
  const rel = path.basename(patch.file);
  if (!existsSync(patch.file)) {
    problems.push(`${rel}: 文件不存在（DSH 装在哪？用 --app= 指定）`);
    continue;
  }
  const text = load(patch.file);
  const status = statusOf(text, patch);
  if (status === 'ambiguous') {
    problems.push(`${rel} / ${patch.name}: 原文与目标**同时**存在，无法判断（先 --revert 再重打）`);
    continue;
  }
  if (status === 'missing') {
    problems.push(`${rel} / ${patch.name}: 找不到锚点 —— DSH 版本变了，需要重新定位`);
    continue;
  }
  if (checkOnly) {
    console.log(`[${status === 'applied' ? '已打' : '未打'}] ${rel} · ${patch.name}`);
    continue;
  }
  if (revert) {
    if (status !== 'applied') {
      console.log(`[跳过] ${rel} · ${patch.name}（本来就没打）`);
      already += 1;
      continue;
    }
    cache.set(patch.file, text.replace(eolOf(text, patch.to), eolOf(text, patch.from)));
    applied += 1;
    console.log(`[撤销] ${rel} · ${patch.name}`);
    continue;
  }
  if (status === 'applied') {
    console.log(`[已是] ${rel} · ${patch.name}`);
    already += 1;
    continue;
  }
  cache.set(patch.file, text.replace(eolOf(text, patch.from), eolOf(text, patch.to)));
  applied += 1;
  console.log(`[应用] ${rel} · ${patch.name}`);
}

if (!checkOnly && problems.length === 0) {
  for (const [file, text] of cache.entries()) writeFileSync(file, text, 'utf8');
}

console.log('');
if (problems.length > 0) {
  console.error('补丁未完成：');
  for (const p of problems) console.error('  ✗ ' + p);
  process.exit(1);
}
console.log(checkOnly
  ? '检查完成（未改动任何文件）。'
  : `${revert ? '撤销' : '应用'} ${applied} 条，跳过 ${already} 条。改完请**重启连接器**（DSH 插件会拉起它）。`);
