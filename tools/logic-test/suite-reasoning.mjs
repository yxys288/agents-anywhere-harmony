#!/usr/bin/env node
/**
 * aa-hm 会话详情「推理段（思考过程）」纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 覆盖两个文件：
 *  · `entry/src/main/ets/model/ReasoningText.ets` —— 折叠行标题三态 / 展开判定 / 段回落 / 去 Markdown；
 *  · `entry/src/main/ets/feature/TimelineProjection.ets` —— `content.kind === 'reasoning'` 分派、
 *    summaries 优先、body = join('\n\n')、不再落成「系统」兜底行。
 *
 * 上游对照（Kotlin，行号为 2026-09-21 快照）：
 *  · `ui/screens/sessiondetail/SessionMessages.kt` 的 `ReasoningSection`（:1530）与
 *    `inlineReasoningSummary`（:1610）；
 *  · `feature/sessiondetail/SessionTimelineProjection.kt` 的 `toSystemMessage()`（:159 起 `if (kind == "reasoning")`）；
 *  · 文案逐字来自 `app/src/main/res/values-zh-rCN/strings.xml`。
 *
 * 转译方式照抄 tools/logic-test/suite-runtime.mjs。
 *
 * 用法：
 *   node tools/logic-test/suite-reasoning.mjs
 */

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, requireTypeScript, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-reasoning');

/** TimelineProjection 依赖 ./Types 与 ../api/Parse，四个都要转译；ReasoningText 零依赖。 */
const LOGIC_FILES = [
  'model/Types.ets',
  'api/Parse.ets',
  'model/ReasoningText.ets',
  'feature/TimelineProjection.ets'
];

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
        removeComments: false
      },
      fileName: rel
    });
    const target = path.join(OUT_DIR, rel.replace(/\.ets$/, '.js'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, output.outputText, 'utf8');
  }
}

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
  } else {
    failures.push(detail === undefined ? name : name + ' — ' + detail);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

function eqJson(name, actual, expected) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  check(name, a === b, 'expected ' + b + ', got ' + a);
}

function group(title) {
  console.log('');
  console.log('== ' + title);
}

build();

const require = createRequire(import.meta.url);
const RT = require(path.join(OUT_DIR, 'model/ReasoningText.js'));
const projection = require(path.join(OUT_DIR, 'feature/TimelineProjection.js'));

/** 服务端发来的推理项就长这样：`type === 'system'` + `content.kind === 'reasoning'`。 */
function reasoningItem(content, extra) {
  const base = {
    id: 'r1',
    type: 'system',
    text: '',
    orderSeq: 1,
    revision: 1,
    updatedSeq: 1,
    status: 'done',
    createdAt: '',
    source: {}
  };
  return Object.assign(base, { content: content }, extra === undefined ? {} : extra);
}

/** 取投影后唯一的那条消息。 */
function only(content, extra) {
  const messages = projection.projectTimeline([reasoningItem(content, extra)]);
  return messages[0];
}

// ---------------------------------------------------------------------------
// 一、文案逐字（values-zh-rCN/strings.xml）
// ---------------------------------------------------------------------------

group('推理段文案（逐字对齐 values-zh-rCN/strings.xml）');
eq('session_reasoning', RT.ReasoningText.REASONING, '推理');
eq('session_reasoning_single_summary 模板', RT.ReasoningText.SINGLE_SUMMARY_TEMPLATE, '推理了 %1$s');
eq('session_reasoning_summary 模板', RT.ReasoningText.SUMMARY_TEMPLATE, '推理过程 · %1$d 条摘要');
eq('session_tool_summary_reasoning 模板', RT.ReasoningText.TOOL_SUMMARY_TEMPLATE, '推理了 %1$d 次');
eq('摘要标题 = 模板替换 %1$s', RT.ReasoningText.singleSummary('先看目录结构'), '推理了 先看目录结构');
eq('多段标题 = 模板替换 %1$d', RT.ReasoningText.segmentSummary(3), '推理过程 · 3 条摘要');
eq('工具汇总文案', RT.ReasoningText.toolSummary(2), '推理了 2 次');
eq('「一眼总结完」上限是上游硬编码的 80', RT.INLINE_SUMMARY_MAX, 80);

// ---------------------------------------------------------------------------
// 二、去 Markdown（上游 inlineReasoningSummary 里那 4 条 replace，顺序不能换）
// ---------------------------------------------------------------------------

group('去 Markdown（stripReasoningMarkdown）');
eq('图片取 alt 文本', RT.stripReasoningMarkdown('![架构图](https://a.example.com/x.png)'), '架构图');
eq('链接取显示文本', RT.stripReasoningMarkdown('见 [文档](https://example.com/a)'), '见 文档');
eq('行内码去反引号', RT.stripReasoningMarkdown('用 `npm test` 跑'), '用 npm test 跑');
eq('删除 * _ ~ # > 记号', RT.stripReasoningMarkdown('## 标题 _重点_ ~~删~~ > 引用'), '标题 重点 删 引用');
eq('空白折叠（含换行）', RT.stripReasoningMarkdown('a   ' + String.fromCharCode(10) + ' b'), 'a b');
eq('组合：粗体 + 行内码 + 链接 + 图片',
  RT.stripReasoningMarkdown('**粗** `x` [a](b) ![c](d)'), '粗 x a c');

// ---------------------------------------------------------------------------
// 三、inlineReasoningSummary：能不能当「一句话摘要」
// ---------------------------------------------------------------------------

group('一句话摘要判定（inlineReasoningSummary）');
eq('普通短句原样返回', RT.inlineReasoningSummary('先看目录结构'), '先看目录结构');
eq('Markdown 剥离后的文本作为摘要', RT.inlineReasoningSummary('**结论**：先看 `README`'), '结论：先看 README');
eq('恰好 80 字符仍算摘要', RT.inlineReasoningSummary('x'.repeat(80)), 'x'.repeat(80));
eq('81 字符不算摘要', RT.inlineReasoningSummary('x'.repeat(81)), null);
eq('含换行不算摘要', RT.inlineReasoningSummary('第一行' + String.fromCharCode(10) + '第二行'), null);
eq('含回车不算摘要', RT.inlineReasoningSummary('a' + String.fromCharCode(13) + 'b'), null);
// 上游 takeIf { it.isNotEmpty() && it.length <= 80 }：剥离后为空串必须返回 null，
// 否则标题会变成「推理了 」（尾随空格）且这一行会被判成不可展开 —— 与上游相反。
eq('全是 Markdown 记号（###）剥离后为空 → null', RT.inlineReasoningSummary('###'), null);
eq('空串 → null', RT.inlineReasoningSummary(''), null);
eq('纯空白 → null', RT.inlineReasoningSummary('   '), null);
// 长度按**剥离后**算：原文远超 80，但全是可剥离记号时必须能当摘要。
eq('长度按剥离后算（原文 200 字符记号、剥离后 3 字符）',
  RT.inlineReasoningSummary('*'.repeat(200) + 'abc'), 'abc');
eq('剥离后 81 字符不算摘要', RT.inlineReasoningSummary('*'.repeat(5) + 'y'.repeat(81)), null);

group('仅单段闸门（inlineSummaryFor）');
eq('空段表 → 无摘要', RT.inlineSummaryFor([]), null);
eq('两段（都短）→ 无摘要', RT.inlineSummaryFor(['a', 'b']), null);
eq('恰好一段 → 走摘要判定', RT.inlineSummaryFor(['先看目录结构']), '先看目录结构');
eq('单段但剥离后为空 → 无摘要', RT.inlineSummaryFor(['###']), null);
eq('单段但过长 → 无摘要', RT.inlineSummaryFor(['y'.repeat(81)]), null);

// ---------------------------------------------------------------------------
// 四、三态标题与展开判定
// ---------------------------------------------------------------------------

group('折叠行标题三态（reasoningTitle）');
eq('有摘要 → session_reasoning_single_summary',
  RT.reasoningTitle(['先看目录结构'], '先看目录结构'), '推理了 先看目录结构');
eq('无摘要但多段 → session_reasoning_summary（%1$d = 段数）',
  RT.reasoningTitle(['a', 'b', 'c'], null), '推理过程 · 3 条摘要');
eq('无摘要仅一段 → 也是「推理过程 · 1 条摘要」',
  RT.reasoningTitle(['y'.repeat(81)], null), '推理过程 · 1 条摘要');
eq('空段表 → session_reasoning', RT.reasoningTitle([], null), '推理');
eq('摘要优先于段数（上游 when 的第一支）', RT.reasoningTitle(['a', 'b'], '摘要'), '推理了 摘要');
// 关键回归：`###` 这一态上游是「推理过程 · 1 条摘要」且**可展开**，绝不是「推理了 」。
eq('单段 `###` → 「推理过程 · 1 条摘要」（不是「推理了 」）',
  RT.reasoningTitle(['###'], RT.inlineSummaryFor(['###'])), '推理过程 · 1 条摘要');

group('展开判定（isReasoningExpandable）');
eq('有段且无摘要 → 可展开', RT.isReasoningExpandable(['a', 'b'], null), true);
eq('能一眼总结完 → 不可展开', RT.isReasoningExpandable(['短句'], '短句'), false);
eq('没有段 → 不可展开', RT.isReasoningExpandable([], null), false);
eq('`###` 单段 → 可展开（与上游一致）',
  RT.isReasoningExpandable(['###'], RT.inlineSummaryFor(['###'])), true);

group('渲染侧段回落（effectiveReasoningSegments）');
eqJson('有段就用段（正文不参与）', RT.effectiveReasoningSegments(['a', 'b'], '正文'), ['a', 'b']);
eqJson('段为空但正文非空白 → 用正文', RT.effectiveReasoningSegments([], '正文'), ['正文']);
eqJson('段与正文都为空 → 空段表', RT.effectiveReasoningSegments([], ''), []);
eqJson('正文只有空白 → 空段表（上游 takeIf(String::isNotBlank)）',
  RT.effectiveReasoningSegments([], '   '), []);

// ---------------------------------------------------------------------------
// 五、时间线投影：content.kind === 'reasoning' 分派
// ---------------------------------------------------------------------------

group('时间线投影：推理段分派（toMessages）');
const twoSummaries = only({
  kind: 'reasoning',
  summaries: [{ text: '第一段摘要' }, { text: '第二段摘要' }],
  rawText: 'raw 兜底文本'
});
eq('kind = reasoning', twoSummaries.kind, 'reasoning');
eqJson('summaries 优先于 rawText', twoSummaries.reasoningSegments, ['第一段摘要', '第二段摘要']);
eq('body = 两段用两个换行拼接',
  twoSummaries.body, '第一段摘要' + String.fromCharCode(10) + String.fromCharCode(10) + '第二段摘要');
eq('title 用上游的英文原样「Reasoning」', twoSummaries.title, 'Reasoning');
eq('作者是 Agent（上游 MessageAuthor.Agent）', twoSummaries.author, 'agent');
eq('status 透传', twoSummaries.status, 'done');
eq('id 带 #0 后缀', twoSummaries.id, 'r1#0');

// 回归判据：改动前推理项落到兜底分支 → kind=system、title='系统'、正文空。
check('不再落成 system 兜底行（回归）', twoSummaries.kind !== 'system');
check('不再叫「系统」（回归）', twoSummaries.title !== '系统');
check('不再是无正文的空行（回归）', twoSummaries.body.length > 0);
check('不是诊断行', twoSummaries.kind !== 'diagnostic');

group('时间线投影：summaries / rawText 的取值细节');
eqJson('summaries 里 text 为空白或缺失的条目被丢掉',
  only({ kind: 'reasoning', summaries: [{ text: '' }, { text: '   ' }, { text: '留下' }, {}] })
    .reasoningSegments, ['留下']);
eqJson('summaries 全被丢掉 → 回落 rawText',
  only({ kind: 'reasoning', summaries: [{ text: '' }], rawText: '兜底' }).reasoningSegments, ['兜底']);
eqJson('summaries 非数组 → 回落 rawText',
  only({ kind: 'reasoning', summaries: '不是数组', rawText: '兜底' }).reasoningSegments, ['兜底']);
eqJson('没有 rawText 时用 text', only({ kind: 'reasoning', text: '思考正文' }).reasoningSegments, ['思考正文']);
eqJson('rawText 优先于 text',
  only({ kind: 'reasoning', rawText: 'raw', text: 'text' }).reasoningSegments, ['raw']);
eqJson('rawText 为空串时回落到 text',
  only({ kind: 'reasoning', rawText: '', text: 'text' }).reasoningSegments, ['text']);
// 上游 `JSONObject.text(name)` 对字符串是 takeIf { it.isNotBlank() }：空白串按**缺失**处理，
// 所以「只有空 rawText」得到的是空段表，而不是一段空串。
eqJson('只有空 rawText → 空段表（不是 [\'\']）',
  only({ kind: 'reasoning', rawText: '' }).reasoningSegments, []);
eqJson('只有空白 text → 空段表', only({ kind: 'reasoning', text: '   ' }).reasoningSegments, []);
eqJson('什么都没有 → 空段表', only({ kind: 'reasoning' }).reasoningSegments, []);
eq('无段时 body 为空串', only({ kind: 'reasoning' }).body, '');
eq('无段时标题走「推理」三态',
  RT.reasoningTitle(only({ kind: 'reasoning' }).reasoningSegments, null), '推理');
eq('无段时不可展开',
  RT.isReasoningExpandable(only({ kind: 'reasoning' }).reasoningSegments, null), false);

group('时间线投影：端到端标题（单段可总结 / 多段折叠）');
const singleSeg = only({ kind: 'reasoning', text: '先看目录结构' }).reasoningSegments;
eq('单段短句 → 标题「推理了 先看目录结构」',
  RT.reasoningTitle(singleSeg, RT.inlineSummaryFor(singleSeg)), '推理了 先看目录结构');
eq('单段短句 → 不可展开',
  RT.isReasoningExpandable(singleSeg, RT.inlineSummaryFor(singleSeg)), false);
const multiSeg = only({
  kind: 'reasoning', summaries: [{ text: 'a' }, { text: 'b' }]
}).reasoningSegments;
eq('两段 → 标题「推理过程 · 2 条摘要」',
  RT.reasoningTitle(multiSeg, RT.inlineSummaryFor(multiSeg)), '推理过程 · 2 条摘要');
eq('两段 → 可展开', RT.isReasoningExpandable(multiSeg, RT.inlineSummaryFor(multiSeg)), true);
const longSeg = only({ kind: 'reasoning', text: 'y'.repeat(120) }).reasoningSegments;
eq('单段超长 → 标题「推理过程 · 1 条摘要」',
  RT.reasoningTitle(longSeg, RT.inlineSummaryFor(longSeg)), '推理过程 · 1 条摘要');

group('时间线投影：与其它 kind 互不影响（回归）');
const mixed = projection.projectTimeline([
  reasoningItem({ kind: 'reasoning', text: '思考一句' }, { id: 'r1', orderSeq: 1 }),
  { id: 's1', type: 'system', text: '运行时已就绪', orderSeq: 2, revision: 1, updatedSeq: 2,
    status: 'done', createdAt: '', source: {}, content: { kind: 'notice' } },
  { id: 'm1', type: 'message', role: 'user', text: '继续', orderSeq: 3, revision: 1, updatedSeq: 3,
    status: 'done', createdAt: '', source: {}, content: {} }
]);
eq('三条消息各就各位', mixed.length, 3);
eq('第 1 条是推理段', mixed[0].kind, 'reasoning');
eq('第 2 条仍走 system 兜底（标题「系统」未被误伤）', mixed[1].title, '系统');
eq('第 2 条仍是 system', mixed[1].kind, 'system');
eq('第 3 条仍是用户消息', mixed[2].author, 'user');
// 非推理项不该无端长出推理段
eqJson('普通 system 项 reasoningSegments 为空', mixed[1].reasoningSegments, []);
eqJson('用户消息 reasoningSegments 为空', mixed[2].reasoningSegments, []);

// ---------------------------------------------------------------------------
// 七、时间线分组与回合末尾动作（R13-19；上游 SessionMessages.kt:603-673 / :680-740）
// ---------------------------------------------------------------------------

group('工具行判定（上游 isToolRunItem :748-755）');
const toolKinds = ['reasoning', 'command', 'file_change', 'tool_call', 'mcp', 'web_search', 'artifact'];
for (const kind of toolKinds) {
  check(kind + ' 属于工具行', projection.isToolRunItem({ kind: kind }) === true);
}
for (const kind of ['message', 'marker', 'system', 'diagnostic']) {
  check(kind + ' 不属于工具行', projection.isToolRunItem({ kind: kind }) === false);
}

group('连续工具行折成组（上游 groupTimelineMessages :603-673）');
const g = (ids, kinds) => projection.groupTimelineMessages(ids.map((id, i) => ({ id: id, kind: kinds[i] })));
eq('单条工具行不成组', g(['t1'], ['tool_call'])[0].groupKind, 'single');
eq('两条连续工具行成组', g(['t1', 't2'], ['tool_call', 'command'])[0].groupKind, 'toolRun');
eq('组内条数', g(['t1', 't2', 't3'], ['tool_call', 'command', 'reasoning'])[0].messages.length, 3);
eq('工具组后接正文 → 正文是单独一条',
  g(['t1', 't2', 'm1'], ['tool_call', 'command', 'message'])[1].groupKind, 'single');
eq('正文把工具组切断 → 2 组',
  g(['t1', 'm1', 't2'], ['tool_call', 'message', 'tool_call']).length, 3);
eq('被正文隔开的两条工具行不再合并（各自 single）',
  g(['t1', 'm1', 't2'], ['tool_call', 'message', 'tool_call'])[0].groupKind, 'single');
eq('空输入 → 空输出', projection.groupTimelineMessages([]).length, 0);
eq('组 key 带 toolrun: 前缀（与单条 id 区分）',
  g(['t1', 't2'], ['tool_call', 'tool_call'])[0].key, 'toolrun:t1');

group('工具组汇总文案（上游 toolRunSummary :1014-1030）');
eq('只有指令', projection.toolRunSummary([{ kind: 'command' }, { kind: 'command' }]), '执行了 2 条指令');
eq('只有推理', projection.toolRunSummary([{ kind: 'reasoning' }]), '推理了 1 次');
eq('推理在前、指令在后（上游 parts 顺序）',
  projection.toolRunSummary([{ kind: 'command' }, { kind: 'reasoning' }]), '推理了 1 次, 执行了 1 条指令');
eq('都不可数 → N 条活动',
  projection.toolRunSummary([{ kind: 'tool_call' }, { kind: 'mcp' }, { kind: 'artifact' }]), '3 条活动');
eq('文案模板逐字（commands）', projection.ToolRunText.COMMANDS, '执行了 %1$d 条指令');
eq('文案模板逐字（reasoning）', projection.ToolRunText.REASONING, '推理了 %1$d 次');

group('回合末尾动作（上游 buildAgentActionsByTurnEnd :680-740）');
const turnItems = (msgs) => projection.groupTimelineMessages(msgs);
const userMsg = (id) => ({ id: id, kind: 'message', author: 'user', body: '问题' });
const agentMsg = (id, body) => ({ id: id, kind: 'message', author: 'agent', body: body });
const toolMsg = (id) => ({ id: id, kind: 'tool_call', author: 'tool', body: '' });
const actions = projection.buildTurnActions(turnItems([userMsg('u1'), agentMsg('a1', '答一'), toolMsg('t1'), agentMsg('a2', '答二')]));
eq('一个回合只出一条动作行', actions.length, 1);
// 上游 `turnEndKey = item.key` 每轮都刷新 ⇒ 最终落在**回合的最后一条**（这里是 a2，不是 t1）。
eq('动作挂在回合最后一个单元上', actions[0].key, 'a2');
eq('复制正文是整回合拼接', actions[0].copyText, '答一\n\n答二');
eq('参与复制的 id 有两条', actions[0].itemIds.length, 2);
const twoTurns = projection.buildTurnActions(turnItems([userMsg('u1'), agentMsg('a1', '甲'), userMsg('u2'), agentMsg('a2', '乙')]));
eq('两个回合 → 两条动作行', twoTurns.length, 2);
eq('第一回合的正文不串到第二回合', twoTurns[0].copyText, '甲');
eq('第二回合的正文', twoTurns[1].copyText, '乙');
eq('回合末尾 key 落在各自最后一条', twoTurns[0].key === 'a1' && twoTurns[1].key === 'a2', true);
eq('没有 agent 正文 → 不出动作行', projection.buildTurnActions(turnItems([userMsg('u1'), toolMsg('t1')])).length, 0);
eq('只有 agent 正文（无 user 行，历史分页中途）也出动作行',
  projection.buildTurnActions(turnItems([agentMsg('a1', '孤儿正文')])).length, 1);
eq('回合末尾查表', projection.turnActionForKey(actions, 'a2') !== undefined, true);
eq('非回合末尾查不到', projection.turnActionForKey(actions, 't1'), undefined);
eq('可复制正文判定 = agent 的普通消息', projection.isCopyableAgentText(agentMsg('a1', 'x')), true);
eq('用户消息不算可复制正文', projection.isCopyableAgentText(userMsg('u1')), false);
eq('工具行不算可复制正文', projection.isCopyableAgentText(toolMsg('t1')), false);

// ---- R13-21 复核①：回合末尾归属（上游 `turnEndKey = item.key` 每轮刷新） ----
group('R13-21 复核①：回合末尾归属');
const groupEndTurn = projection.buildTurnActions(
  turnItems([userMsg('u1'), agentMsg('a1', '答'), toolMsg('t1'), toolMsg('t2')]));
eq('回合以「工具组」收尾时，动作挂到组 key 上', groupEndTurn[0].key, 'toolrun:t1');
eq('组 key 与单条 id 不会撞', groupEndTurn[0].key !== 't1', true);
const twoTurnsWithTools = projection.buildTurnActions(turnItems([
  userMsg('u1'), agentMsg('a1', '甲'), toolMsg('t1'), toolMsg('t2'),
  userMsg('u2'), agentMsg('a2', '乙'), toolMsg('t3'), toolMsg('t4')
]));
eq('两个回合各一条动作', twoTurnsWithTools.length, 2);
eq('第一回合落在它的工具组', twoTurnsWithTools[0].key, 'toolrun:t1');
eq('第二回合落在它的工具组', twoTurnsWithTools[1].key, 'toolrun:t3');
eq('两回合正文不串', twoTurnsWithTools[0].copyText + '/' + twoTurnsWithTools[1].copyText, '甲/乙');

// ---- R13-21 复核②：工具组白名单里**没有** Text（agent 正文绝不并进工具组） ----
group('R13-21 复核②：工具组白名单（上游 isToolRunItem :748-755）');
check('marker 不在白名单', projection.isToolRunItem({ kind: 'marker' }) === false);
check('system 不在白名单', projection.isToolRunItem({ kind: 'system' }) === false);
check('diagnostic 不在白名单', projection.isToolRunItem({ kind: 'diagnostic' }) === false);
const mixedUnits = turnItems([toolMsg('t1'), toolMsg('t2'), agentMsg('a1', '正文'), toolMsg('t3'), toolMsg('t4')]);
eq('两个工具组被正文切开 → 3 个渲染单元', mixedUnits.length, 3);
eq('第 1 单元是工具组', mixedUnits[0].groupKind, 'toolRun');
eq('第 2 单元是正文（单条）', mixedUnits[1].groupKind, 'single');
eq('第 2 单元里就是那条正文', mixedUnits[1].messages[0].id, 'a1');
eq('第 3 单元又是工具组', mixedUnits[2].groupKind, 'toolRun');
check('正文绝不落在任何工具组内',
  mixedUnits.filter((u) => u.groupKind === 'toolRun')
    .every((u) => u.messages.every((m) => m.kind !== 'message')));

// ---------------------------------------------------------------------------

console.log('');
console.log('通过 ' + passed + ' 项，失败 ' + failures.length + ' 项');
if (failures.length > 0) {
  console.log('');
  console.log('失败明细：');
  for (const f of failures) {
    console.log('  ✗ ' + f);
  }
  process.exit(1);
}
console.log('suite-reasoning: ' + passed + ' 条断言全绿。');
