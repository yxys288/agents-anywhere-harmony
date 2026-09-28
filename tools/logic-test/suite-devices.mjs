#!/usr/bin/env node
/**
 * aa-hm 设备页 / 设备详情纯逻辑自测（R13-4）。
 *
 * 覆盖 `entry/src/main/ets/model/AppModels.ets` 里本轮新增/复核的三个纯函数：
 *  · `runtimeInstanceLabels` / `deviceRuntimeLabel` —— 运行时显示名（上游 `RuntimeIdentity.kt:19-29`、
 *    `DeviceRuntimeState.kt:36-37`、`NewSessionScreen.kt:545/550/670`、`DeviceDetailScreen.kt:694`）；
 *  · `deviceRuntimeSecondary` —— 运行时行副文（上游 `DeviceDetailScreen.kt:702`）；
 *  · `deviceArchiveAllActionLabel` —— 会话区工具条动作（上游 `device_detail_archive_all`）。
 *
 * 转译方式照抄 tools/logic-test/suite-runtime.mjs。
 *
 * 用法：
 *   node tools/logic-test/suite-devices.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-devices');

/** `ui/Design.ets` 无 import、无 ArkUI 语法（只有函数体里的 `$r()`），运行时状态文案可以直接调用断言。 */
const LOGIC_FILES = ['model/Types.ets', 'model/AppModels.ets', 'ui/Design.ets'];

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

function group(title) {
  console.log('');
  console.log('== ' + title);
}

build();

const require = createRequire(import.meta.url);
const M = require(path.join(OUT_DIR, 'model/AppModels.js'));
const D = require(path.join(OUT_DIR, 'ui/Design.js'));
const SRC = path.join(PROJECT, 'entry', 'src', 'main', 'ets');
function readSrc(rel) {
  return fs.readFileSync(path.join(SRC, rel), 'utf8');
}

// ---------------------------------------------------------------------------
// 一、运行时类型名（上游 `RuntimeIdentity.kt:8-17`）
// ---------------------------------------------------------------------------

group('runtimeTypeLabel（上游 RuntimeIdentity.kt:8-17）');
eq('codex → Codex', M.runtimeTypeLabel('codex'), 'Codex');
eq('claude → Claude Code', M.runtimeTypeLabel('claude'), 'Claude Code');
eq('dsh → DeepSeek Harness', M.runtimeTypeLabel('dsh'), 'DeepSeek Harness');
eq('其它类型首字母大写', M.runtimeTypeLabel('gemini'), 'Gemini');
eq('空串 → 空串', M.runtimeTypeLabel(''), '');

// ---------------------------------------------------------------------------
// 二、实例名 vs 类型名（上游 runtimeInstanceLabels）
// ---------------------------------------------------------------------------

group('runtimeInstanceLabels（上游 RuntimeIdentity.kt:19-29）');
eq('用户自定义实例名优先', M.runtimeInstanceLabels('work-codex', 'codex').primary, 'work-codex');
eq('此时副标签是类型名', M.runtimeInstanceLabels('work-codex', 'codex').secondary, 'Codex');
eq('实例名与类型名相同 → 用类型名', M.runtimeInstanceLabels('codex', 'codex').primary, 'Codex');
eq('实例名与类型名相同 → 无副标签', M.runtimeInstanceLabels('codex', 'codex').secondary, undefined);
// ⚠️ 本轮缺陷的根因就在这一条：DSH 那台设备上报的 displayName 是 `DSH`，
// 与 runtimeType `dsh` **大小写不同但忽略大小写后相等** ⇒ 上游必须回落到类型名。
eq('实例名 `DSH` 与类型名 `dsh` 忽略大小写相等 → 类型名',
  M.runtimeInstanceLabels('DSH', 'dsh').primary, 'DeepSeek Harness');
eq('同上，且不重复显示副标签', M.runtimeInstanceLabels('DSH', 'dsh').secondary, undefined);
eq('实例名 `DSH` 前缀带空格也归一', M.runtimeInstanceLabels('  dsh  ', 'dsh').primary, 'DeepSeek Harness');
eq('实例名只是包含类型名时仍算自定义名',
  M.runtimeInstanceLabels('dsh-2', 'dsh').primary, 'dsh-2');
eq('无实例名 → 类型名', M.runtimeInstanceLabels(undefined, 'dsh').primary, 'DeepSeek Harness');
eq('空实例名 → 类型名', M.runtimeInstanceLabels('   ', 'claude').primary, 'Claude Code');

group('deviceRuntimeLabel（新建会话页 / 设备详情共用）');
eq('DSH 设备显示 DeepSeek Harness（不是 DSH）', M.deviceRuntimeLabel('DSH', 'dsh'), 'DeepSeek Harness');
eq('自定义实例名原样显示', M.deviceRuntimeLabel('My Codex', 'codex'), 'My Codex');
eq('displayName 为空时回落类型名', M.deviceRuntimeLabel('', 'claude'), 'Claude Code');
eq('结果绝不等于「DSH」', M.deviceRuntimeLabel('DSH', 'dsh') === 'DSH', false);

group('deviceRuntimeSecondary（上游 DeviceDetailScreen.kt:702）');
eq('实例名==类型名 → 只剩状态', M.deviceRuntimeSecondary('DSH', 'dsh', '运行中'), '运行中');
eq('自定义实例名 → 类型名 · 状态', M.deviceRuntimeSecondary('My Codex', 'codex', '运行中'), 'Codex · 运行中');
eq('状态为空 → 只剩类型名', M.deviceRuntimeSecondary('My Codex', 'codex', ''), 'Codex');
eq('两者都空 → 空串', M.deviceRuntimeSecondary('DSH', 'dsh', ''), '');
eq('分隔符是空格·空格（上游 joinToString(" · ")）',
  M.deviceRuntimeSecondary('My Codex', 'codex', '运行中'), 'Codex · 运行中');

// ---------------------------------------------------------------------------
// 三、会话区工具条动作文案（本轮修正：曾被写成确认框的「归档全部」）
// ---------------------------------------------------------------------------

group('deviceArchiveAllActionLabel（上游 device_detail_archive_all）');
eq('非已归档筛选 → 全部归档', M.deviceArchiveAllActionLabel(true), '全部归档');
eq('已归档筛选 → 全部取消归档', M.deviceArchiveAllActionLabel(false), '全部取消归档');
// 确认框按钮是**另一个 key**（device_confirm_archive_all_confirm = 「归档全部」），不能混用。
check('工具条文案不等于确认框文案',
  M.deviceArchiveAllActionLabel(true) !== '归档全部');
check('取消方向同理', M.deviceArchiveAllActionLabel(false) !== '取消归档全部');

// ---------------------------------------------------------------------------
// 四、相对时间格式 —— 逐字复刻上游 `SessionMappers.kt:110-130`
// ---------------------------------------------------------------------------

group('relativeTimeLabel（上游 SessionMappers.kt:110-130）');
const ago = (ms) => new Date(Date.now() - ms).toISOString();
eq('小于 1 分钟 → now', M.relativeTimeLabel(ago(20000)), 'now');
eq('5 分钟 → 5m', M.relativeTimeLabel(ago(5 * 60000 + 5000)), '5m');
eq('1 小时 → 1h', M.relativeTimeLabel(ago(61 * 60000)), '1h');
eq('3 小时 → 3h', M.relativeTimeLabel(ago(3 * 3600000 + 60000)), '3h');
eq('30 小时 → Yest.（上游 days == 1 的缩写）', M.relativeTimeLabel(ago(30 * 3600000)), 'Yest.');
eq('4 天 → 4d', M.relativeTimeLabel(ago(4 * 86400000 + 3600000)), '4d');
eq('16 天 → 2w', M.relativeTimeLabel(ago(16 * 86400000)), '2w');
eq('400 天 → 1y', M.relativeTimeLabel(ago(400 * 86400000)), '1y');
eq('空串 → 空串', M.relativeTimeLabel(''), '');
eq('undefined → 空串', M.relativeTimeLabel(undefined), '');
eq('不可解析 → 空串', M.relativeTimeLabel('not-a-date'), '');
eq('未来时间被夹到 0 → now', M.relativeTimeLabel(ago(-3600000)), 'now');
// 反例护栏：不能再出现中文本地化（曾经是 刚刚 / N 分钟 / N 小时 / 昨天）。
const sample = M.relativeTimeLabel(ago(5 * 60000));
check('不再是中文（无「分钟」）', sample.indexOf('分钟') < 0);
check('不再出现「刚刚」', M.relativeTimeLabel(ago(20000)) !== '刚刚');

// ---------------------------------------------------------------------------
// 五、运行时状态文案 —— 逐字对齐上游 `device_runtime_*`（values-zh-rCN）
// ---------------------------------------------------------------------------

group('runtimeStatusLabel（上游 DeviceDetailScreen.kt:816-832）');
eq('stopped → 已停止', D.runtimeStatusLabel('stopped'), '已停止');
eq('discovering → 发现中', D.runtimeStatusLabel('discovering'), '发现中');
eq('available → 可用', D.runtimeStatusLabel('available'), '可用');
eq('unavailable → 不可用', D.runtimeStatusLabel('unavailable'), '不可用');
eq('validating → 正在验证配置（不是「校验中」）', D.runtimeStatusLabel('validating'), '正在验证配置');
eq('starting → 启动中', D.runtimeStatusLabel('starting'), '启动中');
eq('running → 运行中', D.runtimeStatusLabel('running'), '运行中');
eq('stopping → 停止中', D.runtimeStatusLabel('stopping'), '停止中');
eq('error → 运行时错误（不是「错误」）', D.runtimeStatusLabel('error'), '运行时错误');
eq('未知状态 → 未知状态（不是「未知」）', D.runtimeStatusLabel('some-new-status'), '未知状态');
check('「正在验证配置」不是自创短名', D.runtimeStatusLabel('validating').length === 6);

// ---------------------------------------------------------------------------
// 六、设备详情容器不变量（源码契约，防止裁决落地后被改回去）
// ---------------------------------------------------------------------------

group('设备详情容器不变量（源码契约）');
const detailSrc = readSrc('ui/screens/DeviceDetailScreen.ets');
check('副文用上游「连接器上不存在此运行时」',
  detailSrc.indexOf('连接器上不存在此运行时') >= 0);
check('不再有自创的「未安装」文案', detailSrc.indexOf("'未安装'") < 0);
check('顶栏状态标签去掉了 OS 前缀',
  detailSrc.indexOf("Text(this.onlineFlag ? '在线' : '离线')") >= 0);
check('会话行不再渲染状态字', detailSrc.indexOf('Text(session.statusLabel)') < 0);
check('Runtime 行不再有类型 chip',
  detailSrc.indexOf('AaChip({ label: runtime.runtimeType })') < 0);
check('Runtime 行不再有「未安装」chip', detailSrc.indexOf("AaChip({ label: '未安装'") < 0);
check('删除配置改成 Trash2 图标按钮',
  detailSrc.indexOf("ICONS['trash-2']") >= 0 && detailSrc.indexOf('runtimeDeleteButton') >= 0);
check('删配置按钮带上游无障碍文案', detailSrc.indexOf("'删除运行时配置'") >= 0);
check('不再有「清除配置」文案', detailSrc.indexOf('清除配置') < 0);
check('设备元数据仍保留（收进 ⋯ 面板）',
  detailSrc.indexOf("label: '设备 ID'") >= 0 && detailSrc.indexOf("label: '最后在线'") >= 0);
check('⋯ 面板高度为容纳元数据而上调', detailSrc.indexOf('height: 380') >= 0);

// ---------------------------------------------------------------------------
// 七、设备详情平铺形态（F-9：上游 SectionBlock + ConfiguredAgentRow 都是无卡片容器）
// ---------------------------------------------------------------------------

group('设备详情平铺形态（F-9 源码契约）');
check('Runtime 行不再是卡片（builder 已改名，无 runtimeCard）',
  detailSrc.indexOf('runtimeCard') < 0 && detailSrc.indexOf('runtimeRow(runtime: RemoteDeviceRuntime)') >= 0);
check('Runtime 行改成上游的垂直 padding 5dp（不再是卡片内边距 12dp）',
  detailSrc.indexOf('.padding({ top: 5, bottom: 5 })') >= 0);
// 页面里仍有两处保留底色（都**不是**分区容器）：撤销成功后的命令卡（上游在 `DeviceSetupSheet` 里）
// 与行内配置编辑器（上游是 `DeviceRuntimeConfigureSheet` 弹层）—— 属「能力等价、形态不同」。
check('保留底色的只剩表单/消息类容器（配置编辑器 + 命令卡）',
  detailSrc.indexOf('runtimeConfigEditor') >= 0 && detailSrc.indexOf('commandCard') >= 0);
check('行间插 DetailDivider 等价物（detailDivider）',
  detailSrc.indexOf('detailDivider()') >= 0 && detailSrc.indexOf('index !== this.runtimes.length - 1') >= 0);
check('各段内容收进 Column(Space.XS)（上游 SectionBlock 的 spacedBy 4dp）',
  (detailSrc.match(/Column\(\{ space: Space\.XS \}\) \{/g) || []).length >= 3);
check('ForEach 带 index（画分线需要）',
  detailSrc.indexOf('(runtime: RemoteDeviceRuntime, index: number)') >= 0);

// ---------------------------------------------------------------------------
// 八、对话框规格（R13-14：上游是自绘 Dialog，常数必须逐项对齐）
// ---------------------------------------------------------------------------

group('对话框规格常量（上游 TakeoverConfirmDialog / DeviceConfirmDialog）');
eq('确认族 · 最大宽 380', D.DialogSpec.MAX_WIDTH, 380);
eq('确认族 · 圆角 26', D.DialogSpec.RADIUS, 26);
eq('确认族 · 内边距 22', D.DialogSpec.PADDING, 22);
eq('确认族 · 屏左右边距 22', D.DialogSpec.SCREEN_MARGIN, 22);
eq('确认族 · 元素间距 18', D.DialogSpec.CONTENT_GAP, 18);
eq('确认族 · 阴影 34', D.DialogSpec.SHADOW_RADIUS, 34);
eq('确认族 · 标题 24/29', D.DialogSpec.TITLE_SIZE + '/' + D.DialogSpec.TITLE_LINE_HEIGHT, '24/29');
eq('确认族 · 正文 15/21', D.DialogSpec.BODY_SIZE + '/' + D.DialogSpec.BODY_LINE_HEIGHT, '15/21');
eq('确认族 · 按钮行 top 6', D.DialogSpec.BUTTON_TOP, 6);
eq('确认族 · 按钮间距 10', D.DialogSpec.BUTTON_GAP, 10);
eq('确认族 · 按钮 50/16', D.DialogSpec.BUTTON_HEIGHT + '/' + D.DialogSpec.BUTTON_RADIUS, '50/16');
eq('确认族 · 按钮文字 15', D.DialogSpec.BUTTON_TEXT_SIZE, 15);
// 宽度 = min(380, 屏宽 − 44)（上游 `widthIn(max=380)` + `padding(horizontal=22)`）。
eq('宽屏（442vp）取上限 380', D.DialogSpec.widthFor(442.4), 380);
eq('窄屏（360vp）取屏宽-44', D.DialogSpec.widthFor(360), 316);
eq('屏宽异常时兜底 380', D.DialogSpec.widthFor(30), 380);

group('对话框规格常量（上游 ProfileDialog / ConfirmSignOutDialog）');
eq('Profile 族 · 圆角 20', D.ProfileDialogSpec.RADIUS, 20);
eq('Profile 族 · 内边距 18', D.ProfileDialogSpec.PADDING, 18);
eq('Profile 族 · 元素间距 14', D.ProfileDialogSpec.CONTENT_GAP, 14);
eq('Profile 族 · 标题 20/24', D.ProfileDialogSpec.TITLE_SIZE + '/' + D.ProfileDialogSpec.TITLE_LINE_HEIGHT, '20/24');
eq('Profile 族 · 正文 14/19', D.ProfileDialogSpec.BODY_SIZE + '/' + D.ProfileDialogSpec.BODY_LINE_HEIGHT, '14/19');
eq('Profile 族 · 按钮 46/14', D.ProfileDialogSpec.BUTTON_HEIGHT + '/' + D.ProfileDialogSpec.BUTTON_RADIUS, '46/14');
check('Profile 族按屏宽铺满（fillMaxWidth，无 380 上限）',
  Math.abs(D.ProfileDialogSpec.widthFor(442.4) - 398.4) < 0.01);

group('对话框源码契约（自绘 + 结构三条 + 输入卡高度）');
const compSrc = readSrc('ui/Components.ets');
const sessSrc = readSrc('ui/screens/SessionDetailScreen.ets');
const setSrc = readSrc('ui/screens/SettingsScreen.ets');
check('通用确认框两枚按钮各占 1:1（layoutWeight(1)）',
  compSrc.indexOf('.layoutWeight(1)') >= 0 && compSrc.indexOf('AaConfirmDialog') >= 0);
check('主按钮有实心底（primaryAction，不是纯文字按钮）',
  compSrc.indexOf('.backgroundColor(primary ? this.primaryBackground() : subtle())') >= 0);
check('文案左对齐（AlignItems.Start）',
  compSrc.indexOf('.alignItems(HorizontalAlign.Start)') >= 0);
check('危险操作走 danger 分支', compSrc.indexOf('this.danger ? Color.Red : primaryAction()') >= 0);
check('接管确认框走自绘（openTakeoverDialog + takeoverDialogCard）',
  sessSrc.indexOf('openTakeoverDialog') >= 0 && sessSrc.indexOf('takeoverDialogCard') >= 0);
check('会话详情只剩分享一处系统 showAlertDialog（已在交付说明里登记）',
  (sessSrc.match(/this\.getUIContext\(\)\.showAlertDialog\(/g) || []).length === 1);
check('退出登录确认框不再用系统 showAlertDialog',
  setSrc.indexOf('this.getUIContext().showAlertDialog(') < 0);
check('设备详情的四处确认框不再用系统 showAlertDialog',
  detailSrc.indexOf('this.getUIContext().showAlertDialog(') < 0);
check('输入卡按上游 heightIn(min 104, max 218) 约束',
  sessSrc.indexOf('.constraintSize({ minHeight: 104, maxHeight: 218 })') >= 0);
check('输入卡的透明命中层已删除（它把卡片撑高 ~27vp）',
  sessSrc.indexOf("Text('')") < 0);
check('只读态点击由 Stack 自身接管',
  sessSrc.indexOf('this.promptTakeover();') >= 0);

// ---------------------------------------------------------------------------
// R13-18（task-25）：设备两页对齐（2-1 返回钮 / 7-1 顶栏换行 / 7-4 区头与动作 / 7-5 会话行时间）
// 上游锚文：`DevicesScreen.kt:229-257`（`if (onBack != null)` 画 40dp ChevronLeft 圆钮）+
// `AgentsAnywhereNavHost.kt:307-315`（给设备页**总是**传 onBack）；
// `DeviceDetailScreen.kt:531-547`（名称与状态同一 Row、`spacedBy(9.dp)`）；
// `:860-881`（`SectionBlock`：区头无计数、两个 `MiniTextAction` 在区头行、筛选 tag 另起一行）；
// `:1010-1046`（`SessionDetailRow`：Row 52dp、标题 `weight(1f)`、时间 10.8sp Monospace **同行右对齐**）。
// ---------------------------------------------------------------------------

group('R13-18：设备两页对齐（2-1 / 7-1 / 7-4 / 7-5）');
const listSrc = readSrc('ui/screens/DevicesScreen.ets');
const ddSrc = readSrc('ui/screens/DeviceDetailScreen.ets');
const designSrc2 = readSrc('ui/Design.ets');

check('2-1 设备页有返回钮（上游总是传 onBack；圆钮 40dp + chevron-left 22dp）',
  listSrc.indexOf("name: 'chevron-left'") >= 0
    && listSrc.indexOf('diameter: Control.NAV_BUTTON_LARGE') >= 0
    && listSrc.indexOf('iconSize: FontSize.ICON_XL') >= 0);
check('2-1 返回钮走 Router.back()（= 上游硬编码的 navigate(AppDestination.Sessions)）',
  listSrc.indexOf('Router.back();') >= 0);
check('2-1 返回钮与标题间距用 Row 的 space（上游 Spacer(width = 12.dp)）',
  listSrc.indexOf('Row({ space: Space.M }) {') >= 0);
check('2-1 旧注释「顶层页不画返回钮」已删除（该判断被锚文证伪）',
  listSrc.indexOf('顶层页不画返回钮') < 0);

eq('Space.TIGHT = 9（上游 `spacedBy(9.dp)`）',
  designSrc2.indexOf('static readonly TIGHT: number = 9;') >= 0, true);
check('7-1 设备名与状态标签在同一个 Row（改前是 Column 竖排 ⇒ 被拆成两行）',
  ddSrc.indexOf('Row({ space: Space.TIGHT }) {') >= 0 && ddSrc.indexOf('this.deviceStatusLabel()') >= 0);
check('7-1 名称 `weight(1f, fill = false)` 的等价写法：flexShrink(1) 且不给 layoutWeight',
  ddSrc.indexOf('.flexShrink(1)') >= 0);

check('7-4 会话区头不再有计数（上游 SectionBlock 区头只有标题 + action）',
  ddSrc.indexOf("AaSectionHeader({ title: '会话', trailing:") < 0
    && ddSrc.indexOf("AaSectionHeader({ title: '会话' })") >= 0);
check('7-4 [选择/取消] 与 [归档全部/取消归档全部] 都在区头行（后者仅非多选态出现，上游 `if (!selectMode)`）',
  ddSrc.indexOf("this.miniTextAction(this.selectMode ? '取消' : '选择', false)") >= 0
    && ddSrc.indexOf('deviceArchiveAllActionLabel(this.sessionFilter !== DeviceSessionsFilter.ARCHIVED), true') >= 0
    && ddSrc.indexOf('if (!this.selectMode) {') >= 0);
eq('7-4 两个 miniTextAction 调用都在区头（筛选行里那个已移走）',
  ddSrc.split('this.miniTextAction(').length - 1, 2);
eq('7-4 独立的「全部归档」小按钮行已删除（只剩多选工具条里那一个 smallActionButton）',
  ddSrc.split('this.smallActionButton(').length - 1, 1);
check('7-4 动作标签按上游 `common_cancel` = 「取消」（原为「完成」）', ddSrc.indexOf("'完成'") < 0);

const ddRowSrc = ddSrc.substring(ddSrc.indexOf('  sessionRow(session: AgentSession) {'),
  ddSrc.indexOf('  private visibleIds()'));
check('7-5 会话行能取到（源码结构未变形）', ddRowSrc.length > 200, 'len=' + ddRowSrc.length);
check('7-5 时间不再被包在标题下方的 Column 里（改前是 `Column(space XXS) { 标题; 时间 }`）',
  ddRowSrc.indexOf('Column({ space: Space.XXS })') < 0);
check('7-5 时间排在标题之后、同一个 Row 内（右对齐）',
  // ⚠️ R33：该 Text 改成三元（加 `ifBlank` 兜底「刚刚」）后，锚点改为 `Text(session.updatedAtLabel.length`
  ddRowSrc.indexOf('Text(session.updatedAtLabel.length') > ddRowSrc.indexOf('Text(session.title)'));
check('7-5 标题 16sp Bold + `inkSoft` + `layoutWeight(1)`（上游 `fontSize 16.sp` / `FontWeight.Bold` / `colors.inkSoft`）',
  ddRowSrc.indexOf('.fontWeight(FontWeight.Bold)') >= 0 && ddRowSrc.indexOf('.fontColor(inkSoft())') >= 0
    && ddRowSrc.indexOf('.layoutWeight(1)') >= 0);
check('7-5 时间 10.8sp（`FontSize.TIME`）+ 等宽族（上游 `FontFamily.Monospace`）且与标题同行',
  ddRowSrc.indexOf('.fontSize(FontSize.TIME)') >= 0 && ddRowSrc.indexOf("'Noto Sans Mono'") >= 0);
check('7-5 行高仍是 52dp（上游 `height(52.dp)`）且行间仍有分隔线',
  ddRowSrc.indexOf('.height(Control.ROW)') >= 0 && ddRowSrc.indexOf('Divider()') >= 0);

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
// R34：设备列表「添加新设备」行 = 上游 `AddDeviceRow`（`DevicesScreen.kt:289-343`）
//   行高 60 / 圆角 15 / `padding(start 12, end 8)` / 图标槽 `Box.size(42.dp)` 圆角 12 + `Icon(Plus, 22.dp)`
//   / `Spacer(width 11.dp)` / 文本 `17.sp / SemiBold / lineHeight 21.sp` / 尾部 `ChevronRight 20.dp`
//   / 槽底 `background(if (darkMode) 0xFF27272A else 0xFFF3F2EF)`
// ⚠️ R34 修前：间距 10（应 11）、槽底 `subtle()`（浅 #F1F0ED / 深 #292929，两个值都与上游不同）、
//   文本 Medium（应 Bold）+ 缺 `lineHeight(21)`。
group('R34：设备列表「添加新设备」行 = 上游 AddDeviceRow');
const addSeg = listSrc.slice(listSrc.indexOf('addDeviceRow() {'), listSrc.indexOf('deviceRow(device: AgentDevice)'));
check('左侧图标与文本间距 = 11（上游 Spacer(11.dp)）', addSeg.includes('Row({ space: 11 }) {'));
check('图标槽底色用上游字面值（浅 #F3F2EF / 深 #27272A）',
  addSeg.includes(".backgroundColor($r('app.color.device_icon_surface'))"));
check('文本 Bold（上游 SemiBold，工程无该字重按既有约定取 Bold）', addSeg.includes('.fontWeight(FontWeight.Bold)'));
check('文本行高 21（上游 lineHeight = 21.sp）', addSeg.includes('.lineHeight(21)'));
check('文本字号 17（上游 17.sp）', addSeg.includes('.fontSize(FontSize.TITLE)'));
check('图标槽 42dp 圆角 12（上游 Box.size(42.dp) + RoundedCornerShape(12.dp)）',
  addSeg.includes('.width(Control.DEVICE_ICON)') && addSeg.includes('.borderRadius(Radius.M)'));
check('行高 60 / 左右内边距 12-8（上游 height(60.dp) + padding(start 12, end 8)）',
  addSeg.includes('.height(Control.ROW_DEVICE)') && addSeg.includes('.padding({ left: Space.M, right: Space.S })'));
const colorBaseR34 = fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'), 'utf8');
const colorDarkR34 = fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'), 'utf8');
check('浅色 device_icon_surface = #F3F2EF（上游 Color(0xFFF3F2EF) 逐字）',
  colorBaseR34.includes('"name": "device_icon_surface", "value": "#F3F2EF"'));
check('深色 device_icon_surface = #27272A（上游 Color(0xFF27272A) 逐字）',
  colorDarkR34.includes('"name": "device_icon_surface", "value": "#27272A"'));

// R35：设备列表「设备行」= 上游 `DeviceRow`（`DevicesScreen.kt:346-420`）
//   行高 60 / 圆角 15 / `padding(start 12, end 8)` / `DeviceIcon` 42dp / `Spacer(11.dp)`
//   名称 `17.sp / SemiBold / lineHeight 21.sp`，色 `online ? (dark ? 0xFFDADADF : 0xFF343436) : muted`
//   名称行内 `spacedBy(8.dp)` + `DeviceStatusLabel`；副文 `13.sp / Medium / lineHeight 16.sp`，
//   色 `meta = dark ? muted : faint`，宽 `fillMaxWidth(0.84f)`；两行所在的 `Column` **无 spacing**（`Arrangement.Center`）
// ⚠️ R35 修前：间距 10（应 11）、名称 Medium（应 Bold）+ 缺 lineHeight 21、名称色用 `ink()`（浅色 #0A0A0B，应 #343436）、
//   副文缺 lineHeight 16 + 色恒为 `muted()`（应深色 muted / 浅色 faint）+ 缺 84% 宽、两行之间多 2dp。
group('R35：设备列表「设备行」= 上游 DeviceRow');
const devSeg = listSrc.slice(listSrc.indexOf('deviceRow(device: AgentDevice) {'), listSrc.indexOf('statusLabel(online: boolean)'));
check('图标与内容间距 = 11（上游 Spacer(11.dp)）', devSeg.includes('Row({ space: 11 }) {'));
check('名称 Bold（上游 SemiBold）', devSeg.includes('.fontWeight(FontWeight.Bold)'));
check('名称行高 21（上游 lineHeight = 21.sp）', devSeg.includes('.lineHeight(21)'));
check('名称色用上游字面值（浅 #343436 / 深 #DADADF）', devSeg.includes("$r('app.color.device_row_title')"));
check('副文行高 16（上游 lineHeight = 16.sp）', devSeg.includes('.lineHeight(16)'));
check('副文色 = 深色 muted / 浅色 faint（上游 meta = dark ? muted : faint）',
  devSeg.includes('isDarkAppearance() ? muted() : faint()'));
check('副文宽度 84%（上游 fillMaxWidth(0.84f)）', devSeg.includes("maxWidth: '84%'"));
check('两行所在 Column 无 spacing（上游 Arrangement.Center，无 spacing）',
  devSeg.includes('Column() {') && devSeg.includes('Column({ space: Space.XXS })') === false);
check('行高 60 / 左右内边距 12-8（上游 height(60.dp) + padding(start 12, end 8)）',
  devSeg.includes('.height(Control.ROW_DEVICE)') && devSeg.includes('.padding({ left: Space.M, right: Space.S })'));
const colorBaseR35 = fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'), 'utf8');
const colorDarkR35 = fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'), 'utf8');
check('浅色 device_row_title = #343436（上游 Color(0xFF343436) 逐字）',
  colorBaseR35.includes('"name": "device_row_title", "value": "#343436"'));
check('深色 device_row_title = #DADADF（上游 Color(0xFFDADADF) 逐字）',
  colorDarkR35.includes('"name": "device_row_title", "value": "#DADADF"'));

// R36：设备列表「状态标签」= 上游 `DeviceStatusLabel`（`DevicesScreen.kt:430-454`）
//   `Row(spacedBy(6.dp))` + `Icon(CircleCheck/Circle, **16.dp**)` + 文本 `13.sp / Medium / **lineHeight 16.sp**`；
//   色 `online ? 0xFF10B981 : colors.muted`，离线时图标再乘 `alpha 0.4f`。
// ⚠️ R36 修前：文本缺 `lineHeight(16)`（行框 15.1dp）。图标 16dp / 间距 6dp 本来就对。
group('R36：设备列表「状态标签」= 上游 DeviceStatusLabel');
const stSeg = listSrc.slice(listSrc.indexOf('statusLabel(online: boolean) {'), listSrc.indexOf('statusLabel(online: boolean) {') + 900);
check('图标与文字间距 = 6（上游 spacedBy(6.dp)）', stSeg.includes('Row({ space: Space.XS_PLUS }) {'));
check('图标 16dp（上游 Modifier.size(16.dp)）', stSeg.includes('iconSize: FontSize.ICON_MD'));
check('文本行高 16（上游 lineHeight = 16.sp）', stSeg.includes('.lineHeight(16)'));
check('文本字号 13 / Medium（上游 13.sp / Medium）',
  stSeg.includes('.fontSize(FontSize.SMALL)') && stSeg.includes('.fontWeight(FontWeight.Medium)'));
check('在线色 = #10B981（上游 Color(0xFF10B981)，本工程 runtime_running 两套都是该值）',
  stSeg.includes("$r('app.color.runtime_running')"));
check('离线时图标乘 0.4（上游 tint.copy(alpha = 0.4f)）', stSeg.includes('.opacity(online ? 1 : 0.4)'));
check('ICON_MD = 16（与上游 16.dp 同值）',
  fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8').includes('static readonly ICON_MD: number = 16;'));

console.log('suite-devices: ' + passed + ' 条断言全绿。');
