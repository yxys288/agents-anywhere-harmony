#!/usr/bin/env node
/**
 * aa-hm 会话详情输入区（composer）自测 —— 第九轮 task-10。
 *
 * 覆盖三块**不依赖 ArkUI / @kit** 的东西：
 *  1. model/SessionGating.ets 的 composerPlaceholder() —— 只读 / 离线 / 待审批 / 排队 /
 *     运行中 / 出错 / 不可用 / 默认「回复 X」八条分支，文案**逐字**取上游中文资源
 *     （android/app/src/main/res/values-zh-rCN/strings.xml）；
 *  2. 同模块的 resolveReplyTarget / replyToText —— 上游的 replyTarget（runtimeLabel，空则 Agent）；
 *  3. ui/screens/SessionDetailScreen.ets 的纯逻辑区（AA-PURE-LOGIC 标记切出）——
 *     动作行次序、只读态显示串、主按钮三态、接管开关的可交互性与目标状态。
 *
 * 另有几条**源码结构闸门**：页面只允许一个 bindSheet、输入框必须经
 * composerInputText 包装（只读时清显示，否则只读提示会被上次的草稿盖住）、
 * 三个控件都必须挂在动作行里（而不是退回与输入框同排）。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-composer.mjs
 * 产物全部落在系统临时目录（不污染工程目录）。
 */

import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot, tempDir, typeScriptModuleId } from '../lib/env.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = projectRoot({ up: 2, scriptUrl: import.meta.url });
const SRC_ETS = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
const TS_PACKAGE = typeScriptModuleId();
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-composer');

/** 纯逻辑依赖链：SessionGating 自身零 import，可直接转译。 */
const LOGIC_FILES = ['model/SessionGating.ets'];

/** UI 文件里的纯逻辑区标记（与 TerminalScreen.ets 同一套约定）。 */
const PURE_BEGIN = '// >>> AA-PURE-LOGIC-BEGIN';
const PURE_END = '// <<< AA-PURE-LOGIC-END';

const require0 = createRequire(import.meta.url);

function transpile(source, fileName) {
  const ts = require0(TS_PACKAGE);
  return ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
      removeComments: false
    },
    fileName: fileName
  }).outputText;
}

function writeModule(relative, source) {
  const target = path.join(OUT_DIR, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, source, 'utf8');
}

/** 去掉扩展名换成 .js（不写正则，脚本里一个反斜杠都不出现）。 */
function jsName(relative) {
  return relative.slice(0, -4) + '.js';
}

const SCREEN_REL = path.join('ui', 'screens', 'SessionDetailScreen.ets');

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    writeModule(jsName(rel), transpile(source, rel));
  }
  const screenSource = fs.readFileSync(path.join(SRC_ETS, SCREEN_REL), 'utf8');
  const begin = screenSource.indexOf(PURE_BEGIN);
  const end = screenSource.indexOf(PURE_END);
  if (begin < 0 || end <= begin) {
    throw new Error('SessionDetailScreen.ets 里找不到纯逻辑标记：标记被删或改名了？');
  }
  const slice = screenSource.slice(begin + PURE_BEGIN.length, end);
  if (slice.indexOf('import ') >= 0) {
    throw new Error('SessionDetailScreen.ets 的纯逻辑区出现了 import —— 该区必须零依赖');
  }
  writeModule(path.join('ui', 'screens', 'ComposerLayoutPolicy.js'), transpile(slice, 'ComposerLayoutPolicy.ets'));
  return screenSource;
}

// ---------------------------------------------------------------------------
// 断言
// ---------------------------------------------------------------------------

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

function group(title) {
  console.log(String.fromCharCode(10) + '== ' + title);
}

// ---------------------------------------------------------------------------

const screenSource = build();

const load = function (rel) {
  return require0(path.join(OUT_DIR, rel));
};

const gating = load('model/SessionGating.js');
const layout = load(path.join('ui', 'screens', 'ComposerLayoutPolicy.js'));

/** 判定所需的全部事实（与 ComposerFacts 同形，默认「一切正常」）。 */
function facts(over) {
  return Object.assign({
    loaded: true,
    takeover: true,
    connectorOnline: true,
    hasNotices: false,
    runtimeReason: '',
    runtimeStatus: 'idle',
    sessionStatus: 'idle',
    action: 'send',
    replyTarget: 'Agent'
  }, over);
}

group('只读态提示（上游 session_read_only_placeholder）');
eq('未接管 → 逐字上游文案',
  gating.composerPlaceholder(facts({ takeover: false })), '只读模式-开启接管后可发送消息');
check('文案里不再指向那个已被开关取代的按钮',
  gating.composerPlaceholder(facts({ takeover: false })).indexOf('接管此会话') < 0);
check('会话还没拉出来时不闪只读文案',
  gating.composerPlaceholder(facts({ loaded: false, takeover: false })).indexOf('只读') < 0);
eq('只读优先于设备离线（上游顺序不能颠倒）',
  gating.composerPlaceholder(facts({ takeover: false, connectorOnline: false })),
  '只读模式-开启接管后可发送消息');

group('非只读态的普通占位（上游 strings.xml 同款）');
eq('一切正常 → 回复 Agent',
  gating.composerPlaceholder(facts({})), '回复 Agent');
eq('运行时标签非空 → 回复 Codex',
  gating.composerPlaceholder(facts({ replyTarget: 'Codex' })), '回复 Codex');
eq('设备离线 → 设备已离线，暂时不能聊天。',
  gating.composerPlaceholder(facts({ connectorOnline: false })), '设备已离线，暂时不能聊天。');
eq('有阻塞审批 → 等待你在下方处理交互…',
  gating.composerPlaceholder(facts({ hasNotices: true })), '等待你在下方处理交互…');
eq('运行时原因优先透出',
  gating.composerPlaceholder(facts({ runtimeReason: '等待本地 DSH Bridge' })), '等待本地 DSH Bridge');
eq('排队（waiting）→ 等待运行时接收任务…',
  gating.composerPlaceholder(facts({ runtimeStatus: 'waiting' })), '等待运行时接收任务…');
eq('排队（pending）→ 等待运行时接收任务…',
  gating.composerPlaceholder(facts({ runtimeStatus: 'pending' })), '等待运行时接收任务…');
eq('运行中 → 发送中断，或等待当前回合结束',
  gating.composerPlaceholder(facts({ runtimeStatus: 'running' })), '发送中断，或等待当前回合结束');
eq('停止中与运行中同文案',
  gating.composerPlaceholder(facts({ runtimeStatus: 'stopping' })), '发送中断，或等待当前回合结束');
eq('等待审批 → 等待你在下方处理交互…',
  gating.composerPlaceholder(facts({ runtimeStatus: 'waiting_approval' })), '等待你在下方处理交互…');
eq('阻塞 → 等待你在下方处理交互…',
  gating.composerPlaceholder(facts({ runtimeStatus: 'blocked' })), '等待你在下方处理交互…');
eq('出错 → 这个会话有错误，发送后会重试',
  gating.composerPlaceholder(facts({ runtimeStatus: 'error' })), '这个会话有错误，发送后会重试');
eq('能力不可用 → 当前运行时状态下不可发送消息。',
  gating.composerPlaceholder(facts({ action: 'none' })), '当前运行时状态下不可发送消息。');
eq('会话说 busy 但运行时已 idle → 仍按 idle 回落（走默认文案）',
  gating.composerPlaceholder(facts({ runtimeStatus: 'unknown', sessionStatus: 'running' })),
  '发送中断，或等待当前回合结束');

group('判定优先级（改动文案时最容易破坏的一环）');
check('只读 > 离线',
  gating.composerPlaceholder(facts({ takeover: false, connectorOnline: false })).indexOf('只读') >= 0);
check('有审批 > 运行时原因',
  gating.composerPlaceholder(facts({ hasNotices: true, runtimeReason: '某个原因' })).indexOf('交互') >= 0);
check('运行时原因 > 状态文案',
  gating.composerPlaceholder(facts({ runtimeReason: '某个原因', runtimeStatus: 'running' })) === '某个原因');
check('状态文案 > 能力不可用',
  gating.composerPlaceholder(facts({ runtimeStatus: 'running', action: 'none' })).indexOf('中断') >= 0);

group('replyTarget / replyToText（上游 session_agent_fallback + session_reply_to）');
eq('兜底常量就是上游的 Agent', gating.DEFAULT_REPLY_TARGET, 'Agent');
eq('空标签回落 Agent', gating.resolveReplyTarget(''), 'Agent');
eq('非空标签原样用', gating.resolveReplyTarget('Codex'), 'Codex');
eq('「回复 X」拼装', gating.replyToText('Codex'), '回复 Codex');
eq('拼装用得上兜底', gating.replyToText(gating.resolveReplyTarget('')), '回复 Agent');

group('输入区动作行次序（对齐上游 ComposerActions）');
eq('三个控件恰好三个位置', layout.COMPOSER_ACTION_ORDER.length, 3);
eq('最左是附件 +', layout.COMPOSER_ACTION_ORDER[0], 'attach');
eq('左侧第二位是接管开关', layout.COMPOSER_ACTION_ORDER[1], 'takeover');
eq('最右是主按钮（发送 / 中断）', layout.COMPOSER_ACTION_ORDER[2], 'primary');
check('接管开关排在附件之后',
  layout.COMPOSER_ACTION_ORDER.indexOf('takeover') > layout.COMPOSER_ACTION_ORDER.indexOf('attach'));

group('输入框：可编辑性与只读时的显示串');
eq('只读 → 不可编辑', layout.composerInputEnabled(true), false);
eq('已接管 → 可编辑', layout.composerInputEnabled(false), true);
eq('只读时显示串恒为空（占位文案才看得见）', layout.composerInputText('没发出去的草稿', true), '');
eq('已接管时显示串就是草稿', layout.composerInputText('没发出去的草稿', false), '没发出去的草稿');
eq('空草稿在只读态仍是空', layout.composerInputText('', true), '');

group('主按钮三态（composerPrimaryKind）');
eq('运行中且可提交 → 中断优先', layout.composerPrimaryKind(true, true), 'interrupt');
eq('运行中且不可提交 → 仍是中断', layout.composerPrimaryKind(true, false), 'interrupt');
eq('不在运行且可提交 → 发送', layout.composerPrimaryKind(false, true), 'send');
eq('不在运行且不可提交 → 发送（禁用）', layout.composerPrimaryKind(false, false), 'send-disabled');

group('接管开关（目标状态与可交互性）');
eq('关 → 点一下是开', layout.takeoverSwitchTarget(false), true);
eq('开 → 点一下是关', layout.takeoverSwitchTarget(true), false);
eq('设备在线且不在请求中 → 可点', layout.takeoverSwitchInteractive(true, false), true);
eq('设备离线 → 不可点（与上游 takeoverBusy 含 !connectorOnline 一致）',
  layout.takeoverSwitchInteractive(false, false), false);
eq('请求在飞 → 不可重复点', layout.takeoverSwitchInteractive(true, true), false);

group('页面结构闸门（防回退）');
eq('页面只挂一个 bindSheet', screenSource.split('bindSheet(').length - 1, 1);
check('输入框显示串经 composerInputText 包装（只读时清显示）',
  screenSource.indexOf('composerInputText(this.draft, this.readOnly)') >= 0);
check('输入框可编辑性经 composerInputEnabled 判',
  screenSource.indexOf('composerInputEnabled(this.readOnly)') >= 0);
// ⚠️ R52 口径变更（用户要求「左下角添加文件按钮替换成 DSH 原生指令按钮」）：
// 动作行左侧第一位由 `attachButton()` 换成 `commandButton()`；
// **「添加文件」必须仍然可达** —— 它现在是指令面板里的第一行，仍然调 `pickAttachment()`。
check('指令按钮挂在动作行里（R52 取代附件按钮）', screenSource.indexOf('this.commandButton()') >= 0);
check('附件入口没丢：指令面板里仍能添加文件',
  screenSource.indexOf("this.commandRow('添加文件'") >= 0 && screenSource.indexOf('this.pickAttachment();') >= 0);
check('接管开关挂在动作行里', screenSource.indexOf('this.takeoverSwitch()') >= 0);
check('上下文圆环挂在主按钮左边（R52）',
  screenSource.indexOf('this.contextRing()') >= 0
    && screenSource.indexOf('this.contextRing()' + String.fromCharCode(10) + '          this.composerPrimaryButton()') >= 0);
check('主按钮挂在动作行里', screenSource.indexOf('this.composerPrimaryButton()') >= 0);
check('主按钮形态走 composerPrimaryKind', screenSource.indexOf('composerPrimaryKind(this.canInterrupt') >= 0);
check('运行时设置仍是页面内联区块（没有回到弹层）', screenSource.indexOf('runtimePanel()') >= 0);
check('运行时面板里的第二个接管入口已移除', screenSource.indexOf('接管此会话') < 0);
check('IME 发送动作仍在（运行中唯一的发送入口）',
  screenSource.indexOf('EnterKeyType.Send') >= 0 && screenSource.indexOf('.onSubmit(') >= 0);
check('附件 25MB 闸门仍接在选文件链路上', screenSource.indexOf('checkUploadSize') >= 0);
check('草稿恢复提示仍由比较式推导（不是显示过就置位的开关）',
  screenSource.indexOf('shouldShowRestoredNotice') >= 0);

group('消息复制（上游 copyMessageText / MessageCopyButton）');
eq('尾部换行被裁掉', layout.copyableText('正文' + String.fromCharCode(10) + String.fromCharCode(10)), '正文');
eq('只裁尾部，不动正文前端空白', layout.copyableText('  正文' + String.fromCharCode(10)), '  正文');
eq('纯空白不可复制', layout.copyableText('  ' + String.fromCharCode(10)), '');
eq('普通消息只复制正文', layout.copyPayload('', '正文'), '正文');
eq('工具消息连标题一起复制', layout.copyPayload('npm test', 'ok'), 'npm test' + String.fromCharCode(10) + 'ok');
eq('正文为空时只剩标题', layout.copyPayload('ls -l', ''), 'ls -l');
eq('都为空则结果为空串', layout.copyPayload('', ''), '');
eq('有内容才给复制入口', layout.copyableMessage('', 'x'), true);
eq('空消息不给复制入口', layout.copyableMessage('', '   '), false);

group('分享范围常量（上游 SessionShareScope，SessionDetailScreen.kt:1871-1874）');
eq('回复范围 = message', gating.SHARE_SCOPE_MESSAGE, 'message');
eq('会话范围 = session', gating.SHARE_SCOPE_SESSION, 'session');

group('复制 / 分享 / 顶栏 / 输入区的结构闸门');
check('用户气泡左侧有常驻复制按钮（不是长按才出）',
  screenSource.indexOf('this.messageCopyButton(message)') >= 0);
// R13-19 起：动作行**不再**挂在每条消息上（上游 `AgentReplyActions` 只在回合末尾出一行，
// `SessionMessages.kt:494-503`）⇒ 判据改成「回合末尾动作行 + 工具折组」。
check('回合末尾才有动作行（不再是每条消息一行）',
  screenSource.indexOf('this.turnActionRow(item.key)') >= 0
    && screenSource.indexOf('this.messageActionRow(message)') < 0);
check('工具行折成组（groupTimelineMessages + toolRunGroup）',
  screenSource.indexOf('groupTimelineMessages(this.messages)') >= 0
    && screenSource.indexOf('toolRunGroup(item)') >= 0);
check('动作行里有分享入口', screenSource.indexOf("Text('分享')") >= 0);
check('分享走 SessionsApi.createSessionShare', screenSource.indexOf('createSessionShare(') >= 0);
check('系统分享接不上时降级为复制链接',
  screenSource.indexOf('分享链接已复制到剪贴板。') >= 0);
check('ShareKit 只做运行期 dynamic import（静态导入会让页面进崩溃导入图）',
  screenSource.indexOf("await import('@kit.ShareKit')") >= 0 && screenSource.indexOf("from '@kit.ShareKit'") < 0);
check('有 canIUse 守卫',
  screenSource.indexOf("canIUse('SystemCapability.Collaboration.SystemShare')") >= 0);
check('剪贴板写的是 pasteboard 系统剪贴板',
  screenSource.indexOf('pasteboard.getSystemPasteboard().setData(') >= 0);
/**
 * ⚠️ **R75 判据改写**（原文两条：`顶栏行高 58dp` + `胶囊标题宽度上限 224dp`）。
 *
 * 那是「自绘形态③顶栏」的规格：58dp 行 + 224dp 宽的**自绘白胶囊标题**。
 * R75 用户要求「改为官方标题栏样式，取消自绘部分」⇒ 这两样都**故意删除**了：
 *  · 行高改 `.height('50%')`（`Mini` 的 56vp 槽里垂直居中；写死 58 会向下溢出）；
 *  · 胶囊标题整段删除（标题槽交回框架）。
 * 判据语义随之修正为「**该页不许再出现这两样自绘形态**」—— 若哪天它们被加回来，
 * 说明「取消自绘」这件事被回滚了，应当红。断言方向与原来相反，是**有意的**。
 *
 * ⚠️ **R80 判据再修正**（原文写死 `Control.TOP_BAR_PAGE`）：用户「**标题栏距时间栏较远**，修复一下」。
 * 真机三份 dump 实测出病根 —— 框架把标题栏构造器的**顶边锚在 y=166**（与行高无关），
 * 控件中心 = 166 + 行高 ÷ 2 ⇒ 行高 64 时中心 262，而**首页**（`HOME_HEADER`=46）是 235：
 * 同一条栏本页低了 **27px**。R80 把行高收到 `Control.HOME_HEADER`，对齐 R76 起「与首页效果一致」的口径。
 * 判据跟着改到新档位（仍然守着同一个意图：**高度走 Control 令牌、不许写死 58、左右走 Space.PAGE**）。
 */
check('R75/R80/R81：顶栏行高走 Control.NAV_TITLE_ROW（= 与首页同档；不再写死 58vp、也不再是 64vp 档）',
  screenSource.indexOf('.height(58)') < 0
    && screenSource.indexOf('.height(Control.NAV_TITLE_ROW)') >= 0
    && screenSource.indexOf('.height(Control.TOP_BAR_PAGE)') < 0
    && screenSource.indexOf('.padding({ left: Space.PAGE, right: Space.PAGE })') >= 0);
check('R75：自绘胶囊标题已删除（不再有 constraintSize maxWidth 224）',
  screenSource.indexOf('.constraintSize({ maxWidth: 224 })') < 0);
check('输入区卡片圆角走 Radius.XXL（22dp 档）+ 阴影走 Shadow.CARD（28dp 档）（§E.5.1）',
  screenSource.indexOf('.borderRadius(Radius.XXL)') >= 0
    && screenSource.indexOf('.shadow({ radius: Shadow.CARD') >= 0);
check('文本域 16sp / 行高 21sp（§E.5.1）',
  screenSource.indexOf('.fontSize(16)') >= 0 && screenSource.indexOf('.lineHeight(21)') >= 0);
check('顶栏水平边距走 Space.PAGE（18dp 令牌）',
  screenSource.indexOf('.padding({ left: Space.PAGE, right: Space.PAGE })') >= 0);
check('动作行间距走 Space.TIGHT（9dp 令牌）',
  screenSource.indexOf('Row({ space: Space.TIGHT })') >= 0);
// ⚠️ R50 收紧口径：原先只认「字面量以 `Radius.` 开头」，于是**三元表达式**
// （`.borderRadius(multiple ? Radius.XS : Radius.PILL)`）会被误判成裸数值。
// 现在改成**逐个取实参**，要求实参里出现 `Radius.` —— 既容得下三元，又照样拦住裸数字。
check('本页所有 borderRadius 都走 Radius 令牌（零裸数值圆角）', (() => {
  const bad = [];
  let at = screenSource.indexOf('.borderRadius(');
  while (at >= 0) {
    const open = at + '.borderRadius('.length;
    let depth = 1;
    let i = open;
    while (i < screenSource.length && depth > 0) {
      const c = screenSource.charAt(i);
      if (c === '(') { depth += 1; } else if (c === ')') { depth -= 1; }
      i += 1;
    }
    const arg = screenSource.slice(open, i - 1);
    if (arg.indexOf('Radius.') < 0) { bad.push(arg.trim()); }
    at = screenSource.indexOf('.borderRadius(', at + 1);
  }
  if (bad.length > 0) { console.log('  裸数值圆角：' + bad.join(' | ')); }
  return bad.length === 0;
})());
check('本页所有 shadow 扩散半径都走 Shadow 令牌（零裸数值 —— 阴影不是圆角，见 Design.ets Shadow 组）',
  screenSource.split('.shadow(').length - 1 === screenSource.split('.shadow({ radius: Shadow.').length - 1);

// ---------------------------------------------------------------------------
// R27：输入区动作行的两个按钮**不带自加底**
// ---------------------------------------------------------------------------
// 上游锚文：`SessionComposer.kt:479-480` 的 `surface = dark ? raisedSurface : Color.White`、
//   `border = dark ? 0xFF27272A : Color.Transparent`；
//   `:505-513` `plusModifier`（深色 `size(30.dp)` 裸 / 浅色 `size(30.dp) + background(White) + border(1.dp, Transparent)`）；
//   `:514-523` `takeoverModifier`（深色 `height(28.dp)` 裸 / 浅色 `height(28.dp) + background(White)
//   + border(Transparent) + padding(start = 4.dp, end = 9.dp)`）；`:537-539` 只读态**只摘 `clickable`**、不改透明度。
// ⇒ 两处**视觉上都不可见底**。本工程原给两处都写了 `backgroundColor($r('app.color.subtle'))`（浅灰实底），
//    并排图上（`r27-session-bottom/zoom-composer-readonly.png`）一眼就能看出多出圆底。
const attachSeg = screenSource.slice(screenSource.indexOf('attachButton() {'), screenSource.indexOf('takeoverSwitch() {'));
const takeoverSeg = screenSource.slice(screenSource.indexOf('takeoverSwitch() {'), screenSource.indexOf('主按钮（动作行最右）'));

group('R27：输入区动作行的按钮不带自加底');
check('附件钮没有 backgroundColor（上游浅色白底 + 透明边 = 不可见）',
  attachSeg.length > 0 && attachSeg.includes('.backgroundColor(') === false);
check('附件钮不按只读态降透明度（上游只摘 clickable）', attachSeg.includes('.opacity(') === false);
check('附件钮仍是 30dp（上游 size(30.dp)）',
  attachSeg.includes('.width(30)') && attachSeg.includes('.height(30)'));
check('接管开关外层没有实底（轨道色在开关自身）',
  takeoverSeg.length > 0 && takeoverSeg.includes('.backgroundColor($r(') === false);
check('接管开关左右内边距 = 上游 padding(start = 4.dp, end = 9.dp)',
  takeoverSeg.includes('.padding({ left: 4, right: 9, top: 5, bottom: 5 })'));
check('开关与「接管」文字间距 = 5（上游 spacedBy(5.dp)）', takeoverSeg.includes('Row({ space: 5 }) {'));
check('动作行左侧两钮之间仍是 9dp（上游 spacedBy(9.dp)）',
  screenSource.includes('Row({ space: Space.TIGHT }) {'));

// ---------------------------------------------------------------------------

console.log(String.fromCharCode(10) + '--------------------------------------------');
console.log('PASS ' + passed + ' / FAIL ' + failures.length);
if (failures.length > 0) {
  console.log(String.fromCharCode(10) + 'FAIL 明细：');
  for (const item of failures) {
    console.log('  - ' + item);
  }
  process.exit(1);
}
console.log('suite-composer: 全绿');
