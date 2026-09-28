#!/usr/bin/env node
/**
 * aa-hm 登录流程四屏自测（第十一轮 task-21）。
 *
 * 覆盖三块：
 *  1. `ui/screens/AuthFlow.ets` 的**纯逻辑**（状态机分支 / 返回目标 / 顶部内边距 / 四态标题）——
 *     该文件零 import、零 ArkUI，用 DevEco 自带的 TypeScript 转译成 CommonJS 后直接跑断言；
 *  2. **数值与文案契约**（施工图 §J.4 的表值逐条守住：104/74/32/56/12/62/17/1.2/286/22/128/168、
 *     15.3sp / 12.5sp / 22.5sp 这类小数**不四舍五入**、登录页字标 42 与首页 31 两处都要在）；
 *  3. 两个屏的**源码结构闸门**：既有能力（密码 / 注册 / 扫码三段式 / 网页 OAuth / 换服务器）
 *     一个都不能少、登录页不许套主 App 的 AaTopBar、不许碰路由（Router/Index 由骨架包在改）。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-login.mjs
 * 产物全部落在系统临时目录（不污染工程目录）。
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-login');

/** 纯逻辑模块（零 import，可直接转译）。 */
const LOGIC_FILES = ['ui/screens/AuthFlow.ets'];

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

build();

const require0 = createRequire(import.meta.url);
const flow = require0(path.join(OUT_DIR, 'ui/screens/AuthFlow.js'));
const loginSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'LoginScreen.ets'), 'utf8');
const waitingSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'QrWaitingScreen.ets'), 'utf8');

const Step = flow.LoginStep;
const M = flow.AuthMetrics;
const F = flow.AuthFont;
const LH = flow.AuthLineHeight;
const T = flow.AuthText;

group('状态机分支（AuthFlow）');
eq('没服务器没登录态 → 从 LoginMethods 起步', flow.initialStep(false, false), Step.METHODS);
eq('已有服务器 → 直接进登录表单', flow.initialStep(true, false), Step.PASSWORD);
eq('已有登录态 → 不渲染本页（空串）', flow.initialStep(true, true), '');
eq('QrWaiting 返回 QrLogin', flow.backTargetOf(Step.QR_WAITING), Step.QR_LOGIN);
eq('QrLogin 返回 LoginMethods', flow.backTargetOf(Step.QR_LOGIN), Step.METHODS);
eq('ServerSetup 返回 LoginMethods', flow.backTargetOf(Step.SERVER_SETUP), Step.METHODS);
eq('登录表单返回 ServerSetup', flow.backTargetOf(Step.PASSWORD), Step.SERVER_SETUP);
eq('根步没有返回目标', flow.backTargetOf(Step.METHODS), '');
eq('LoginMethods 是根：不显示返回钮', flow.stepHasBack(Step.METHODS), false);
eq('QrLogin 显示返回钮', flow.stepHasBack(Step.QR_LOGIN), true);
eq('QrWaiting 显示返回钮', flow.stepHasBack(Step.QR_WAITING), true);
eq('空步骤不显示返回钮', flow.stepHasBack(''), false);
eq('LoginMethods 顶部 104', flow.stepTopInset(Step.METHODS), 104);
eq('ServerSetup 顶部 74', flow.stepTopInset(Step.SERVER_SETUP), 74);
eq('QrLogin 顶部 74', flow.stepTopInset(Step.QR_LOGIN), 74);
eq('QrWaiting 顶部 74', flow.stepTopInset(Step.QR_WAITING), 74);

group('四态标题（qrWaitingTitle / qrWaitingTerminal）');
eq('等待网页端确认', flow.qrWaitingTitle(false, ''), '等待网页端确认...');
eq('兑换中显示正在完成登录', flow.qrWaitingTitle(true, 'approved'), '正在完成登录...');
eq('已拒绝（rejected）', flow.qrWaitingTitle(false, 'rejected'), '登录已被拒绝。');
eq('已拒绝（本工程 AuthApi 用 denied）', flow.qrWaitingTitle(false, 'denied'), '登录已被拒绝。');
eq('已过期', flow.qrWaitingTitle(false, 'expired'), '二维码已过期。');
eq('已被使用', flow.qrWaitingTitle(false, 'consumed'), '二维码已被使用。');
eq('approved 后仍在等待文案', flow.qrWaitingTitle(false, 'approved'), '等待网页端确认...');
check('approved 是终止态', flow.qrWaitingTerminal('approved') === true);
check('rejected/denied/expired/consumed 都是终止态',
  flow.qrWaitingTerminal('rejected') === true && flow.qrWaitingTerminal('denied') === true &&
  flow.qrWaitingTerminal('expired') === true && flow.qrWaitingTerminal('consumed') === true);
check('pending_web_confirm 不是终止态（要接着轮询）', flow.qrWaitingTerminal('pending_web_confirm') === false);

group('数值契约：四屏骨架（施工图 §J.4.2 / §J.4.3 / §J.4.4）');
eq('四屏水平内边距 32', M.PAGE_H, 32);
eq('LoginMethods 顶部 104', M.METHODS_TOP, 104);
eq('其余三屏顶部 74', M.SHELL_TOP, 74);
eq('底部 30', M.PAGE_BOTTOM, 30);
eq('LoginMethods 区块间距 30', M.METHODS_GAP, 30);
eq('标题块内间距 6', M.TITLE_GAP, 6);
eq('按钮列间距 24', M.BUTTON_GAP, 24);
eq('ServerSetup 标题块内间距 10', M.HOST_TITLE_GAP, 10);
eq('错误条与按钮列之间 18', M.ERROR_GAP, 18);
eq('LoginMethodButton 高 56', M.BUTTON_H, 56);
eq('LoginMethodButton 圆角 12', M.BUTTON_RADIUS, 12);
eq('LoginMethodButton 水平 padding 18', M.BUTTON_PADDING_H, 18);
eq('图标 22', M.ICON, 22);
eq('图标与文字间距 10', M.ICON_GAP, 10);
eq('AuthInputRow 高 62', M.INPUT_H, 62);
eq('AuthInputRow 圆角 17', M.INPUT_RADIUS, 17);
eq('AuthInputRow 边框 1.2（不是 1）', M.INPUT_BORDER, 1.2);
eq('AuthInputRow 水平 padding 18', M.INPUT_PADDING_H, 18);
eq('AuthInputRow 图标间距 10', M.INPUT_GAP, 10);
eq('自建表单区块间距 12', M.FORM_GAP, 12);
eq('BackPill 高 36', M.BACK_PILL_H, 36);
eq('BackPill 边框 1.2', M.BACK_PILL_BORDER, 1.2);
eq('BackPill 水平 padding 12', M.BACK_PILL_PADDING_H, 12);
eq('BackPill 图标文字间距 7', M.BACK_PILL_GAP, 7);
eq('说明行图标 17', M.HINT_ICON, 17);
eq('说明行图标与文字间距 9', M.HINT_ICON_GAP, 9);
eq('OR 分隔间距 12', M.OR_GAP, 12);

group('数值契约：扫码两屏（含两个刻意视觉重心）');
eq('QrLogin 主区块间距 128（刻意，不是笔误）', M.QR_BLOCK_GAP, 128);
eq('取景框与文字块间距 34', M.QR_TEXT_GAP, 34);
eq('取景框 286 方形', M.QR_FRAME, 286);
eq('取景框圆角 22', M.QR_FRAME_RADIUS, 22);
eq('取景框内提示水平 padding 28', M.QR_FRAME_PADDING_H, 28);
eq('取景框角标 inset 26', M.QR_CORNER_INSET, 26);
eq('取景框角标线长 22', M.QR_CORNER_LENGTH, 22);
eq('取景框角标线宽 2.3', M.QR_CORNER_STROKE, 2.3);
eq('QrWaiting 顶部留白 168（刻意，不是笔误）', M.WAITING_TOP, 168);
eq('QrWaiting 区块间距 42', M.WAITING_GAP, 42);
eq('QrWaiting 文字块间距 18', M.WAITING_TEXT_GAP, 18);
eq('QrWaiting 监控图标宽 64', M.WAITING_ICON_W, 64);
eq('QrWaiting 监控图标高 52', M.WAITING_ICON_H, 52);

group('字号与行高契约：小数不四舍五入');
eq('LoginMethods 标题 24sp', F.TITLE, 24);
eq('登录页字标 42sp', F.WORDMARK, 42);
eq('首页字标 31sp（与登录页不同，两处都要在）', F.WORDMARK_HOME, 31);
check('登录页与首页字标是两个不同的字号', F.WORDMARK !== F.WORDMARK_HOME);
eq('说明 14sp', F.DESC, 14);
eq('按钮 / 输入行文字 15.3sp（不四舍五入成 15）', F.BUTTON, 15.3);
eq('ServerSetup 标题 28sp', F.HOST_TITLE, 28);
eq('说明行 13sp', F.HOST_HINT, 13);
eq('OR 14sp', F.OR, 14);
eq('QrLogin 标题 16sp', F.QR_TITLE, 16);
eq('QrLogin 说明 14sp', F.QR_BODY, 14);
eq('取景框提示 / QrWaiting 副文 12.5sp', F.QR_HINT, 12.5);
eq('QrWaiting 标题 18sp', F.WAITING_TITLE, 18);
eq('错误条正文 13.5sp', F.ERROR, 13.5);
eq('标题行高 26sp', LH.TITLE, 26);
eq('字标行高 44sp', LH.WORDMARK, 44);
eq('按钮行高 18sp', LH.BUTTON, 18);
eq('ServerSetup 标题行高 34sp', LH.HOST_TITLE, 34);
eq('QrWaiting 标题行高 22.5sp（保留小数）', LH.WAITING_TITLE, 22.5);

group('文案契约：逐字取上游 values-zh-rCN/strings.xml');
eq('继续使用', T.CONTINUE_TO, '继续使用');
eq('选择登录方式。', T.CHOOSE_LOGIN, '选择登录方式。');
eq('扫码登录', T.QR_LOGIN, '扫码登录');
eq('账号密码登录', T.PASSWORD_LOGIN, '账号密码登录');
eq('输入服务器', T.ENTER_SERVER, '输入服务器');
eq('返回', T.BACK, '返回');
eq('选择登录服务', T.HOST_TITLE, '选择登录服务');
eq('登录Agents Anywhere Cloud', T.OFFICIAL, '登录Agents Anywhere Cloud');
eq('连接到你自己的服务实例', T.SELF_HOST, '连接到你自己的服务实例');
eq('OR', T.OR, 'OR');
eq('连接服务器', T.CONNECT, '连接服务器');
eq('检查中...', T.CHECKING, '检查中...');
eq('后端地址', T.BACKEND_URL, '后端地址');
eq('正在打开网页登录...', T.OPENING_WEB_LOGIN, '正在打开网页登录...');
eq('Cloud 提示', T.HOST_HINT, '如果你没有私有化部署后端，请选择 Cloud 登录。');
eq('取景框无权限文案', T.QR_CAMERA_ACCESS, '需要相机权限才能扫描。');
eq('扫码帮助标题', T.QR_HELP_TITLE, '如何生成移动端登录二维码？');
check('扫码帮助正文含「设置 - 手机连接」', T.QR_HELP_BODY.indexOf('设置 - 手机连接') > 0);
eq('字标文本', T.WORDMARK, 'Agents Anywhere');

group('源码结构闸门：既有能力不得回归（LoginScreen / QrWaitingScreen）');
check('LoginScreen 仍是无参导出组件（Index.ets 的 LoginScreen() 不用改）',
  loginSrc.indexOf('export struct LoginScreen {') >= 0 &&
  loginSrc.indexOf('export struct LoginScreen {') === loginSrc.lastIndexOf('export struct LoginScreen {'));
check('五步分派齐全（methods / serverSetup / qrLogin / qrWaiting / password）',
  loginSrc.indexOf('this.step === LoginStep.METHODS') >= 0 &&
  loginSrc.indexOf('this.step === LoginStep.SERVER_SETUP') >= 0 &&
  loginSrc.indexOf('this.step === LoginStep.QR_LOGIN') >= 0 &&
  loginSrc.indexOf('this.step === LoginStep.QR_WAITING') >= 0 &&
  loginSrc.indexOf('this.passwordScreen()') >= 0);
check('QrWaiting 由独立子屏渲染（带二维码负载参数）',
  loginSrc.indexOf('QrWaitingScreen({') >= 0 &&
  loginSrc.indexOf('userId: this.qrUserId') >= 0 &&
  loginSrc.indexOf('loginToken: this.qrLoginToken') >= 0);
check('登录页不套主 App 的 AaTopBar（易错点 2）',
  loginSrc.indexOf('AaTopBar({') < 0 && loginSrc.indexOf('AaBackPill({') >= 0);
check('LoginMethods（根）没有返回钮：methodsScreen 里不出现 AaBackPill',
  (function () {
    const start = loginSrc.indexOf('methodsScreen() {');
    const end = loginSrc.indexOf('authErrorNotice() {');
    return start > 0 && end > start && loginSrc.slice(start, end).indexOf('AaBackPill') < 0;
  })());
check('没有引用路由（Router/Route 由骨架包在改）',
  loginSrc.indexOf('Router.') < 0 && loginSrc.indexOf('Route.') < 0);
check('密码登录与注册仍走原有调用链',
  loginSrc.indexOf('authController.loginWithPassword(') >= 0 &&
  loginSrc.indexOf('authController.register(') >= 0 &&
  loginSrc.indexOf('this.registerMode') >= 0);
check('扫码三段式仍走 parseMobileLoginQr + completeQrLogin',
  loginSrc.indexOf('parseMobileLoginQr(') >= 0 &&
  waitingSrc.indexOf('authController.completeQrLogin(') >= 0 &&
  waitingSrc.indexOf('authController.connectServer(this.serverUrl)') >= 0);
check('网页 OAuth 的 PKCE 与回调拦截保留',
  loginSrc.indexOf('pkceChallenge(') >= 0 &&
  loginSrc.indexOf('code_challenge_method=S256') >= 0 &&
  loginSrc.indexOf('handleWebCallback(') >= 0 &&
  loginSrc.indexOf('authController.completeWebLogin(') >= 0 &&
  loginSrc.indexOf("agents-anywhere://oauth/callback") >= 0);
check('state 不匹配仍被拒（不得丢掉回调校验）',
  loginSrc.indexOf('state !== this.webSession.state') >= 0);
check('服务器地址校验与「更换服务器」保留',
  loginSrc.indexOf('authController.connectServer(') >= 0 &&
  loginSrc.indexOf('authController.switchServer()') >= 0);
check('键盘避让（聚焦 + 视口变化时贴底）保留',
  loginSrc.indexOf('this.scroller.scrollEdge(Edge.Bottom)') >= 0 &&
  loginSrc.indexOf('this.passwordFocused = true') >= 0);
check('地址行 / 密码行接了 IME 动作（EnterKeyType.Go → onSubmit）',
  loginSrc.indexOf('enterKeyType(EnterKeyType.Go)') >= 0 &&
  loginSrc.indexOf('.onSubmit(() => {') >= 0);
check('错误条按上游 AuthErrorNotice 复刻（14 / 20 / 13.5），不用 AaErrorBanner',
  loginSrc.indexOf('AuthMetrics.ERROR_RADIUS') >= 0 &&
  loginSrc.indexOf('AuthMetrics.ERROR_ICON') >= 0 &&
  loginSrc.indexOf('AuthMetrics.ERROR_ICON_GAP') >= 0 &&
  loginSrc.indexOf('AaErrorBanner({') < 0);
check('取景框是 286 + 圆角 22 + Canvas 四角角标',
  loginSrc.indexOf('AuthMetrics.QR_FRAME') >= 0 &&
  loginSrc.indexOf('AuthMetrics.QR_FRAME_RADIUS') >= 0 &&
  loginSrc.indexOf('drawScannerCorners()') >= 0 &&
  loginSrc.indexOf('AuthMetrics.QR_CORNER_STROKE') >= 0);
check('QrWaiting 用 168 顶留白 + 42 区块间距 + 64×52 图标',
  waitingSrc.indexOf('AuthMetrics.WAITING_TOP') >= 0 &&
  waitingSrc.indexOf('AuthMetrics.WAITING_GAP') >= 0 &&
  waitingSrc.indexOf('AuthMetrics.WAITING_ICON_W') >= 0 &&
  waitingSrc.indexOf('AuthMetrics.WAITING_ICON_H') >= 0);
check('QrLogin 的 128 间距挂在 BackPill 与内容块之间（主区块 Column 的 space）',
  loginSrc.indexOf('Column({ space: AuthMetrics.QR_BLOCK_GAP })') >= 0);
check('只有 LoginMethods 用 104 顶距，其余屏用 74',
  loginSrc.indexOf('top: AuthMetrics.METHODS_TOP') >= 0 &&
  (loginSrc.match(/top: AuthMetrics.SHELL_TOP/g) || []).length >= 3);
check('取景框排在文字块之前（上游顺序：BackPill → 取景框 → 标题/说明）',
  (function () {
    const frame = loginSrc.indexOf('this.qrFrame()');
    const title = loginSrc.indexOf('AuthText.QR_HELP_TITLE');
    return frame > 0 && title > frame;
  })());
check('LoginMethods 的标题块顺序：继续使用 → 字标 → 选择登录方式',
  (function () {
    const a = loginSrc.indexOf('AuthText.CONTINUE_TO');
    const b = loginSrc.indexOf('AuthText.WORDMARK');
    const c = loginSrc.indexOf('AuthText.CHOOSE_LOGIN');
    return a > 0 && b > a && c > b;
  })());

check('QrWaiting 的登录态只走 @State（不把 controller 读进 build）',
  waitingSrc.indexOf('@State status: string') >= 0 &&
  waitingSrc.indexOf('this.status = status;') >= 0 &&
  waitingSrc.indexOf('qrWaitingTitle(this.exchanging, this.status)') >= 0);
check('异步链路回来后复查页面存活（不写已销毁页面）',
  waitingSrc.indexOf('private alive: boolean') >= 0 &&
  waitingSrc.indexOf('if (!this.alive)') >= 0);

group('构建契约：不与 ArkUI 通用属性撞名、不引用不存在的颜色函数（预构建两处报错的防复发线）');
/** 这些名字在 ArkUI 里已经是通用属性方法，自定义组件成员同名会编译报错。 */
const FORBIDDEN_MEMBERS = ['background', 'backgroundColor', 'backgroundImage', 'border', 'borderWidth',
  'borderColor', 'size', 'width', 'height', 'padding', 'margin', 'enabled', 'focusable', 'opacity',
  'visibility', 'position', 'offset', 'clip', 'shadow', 'id', 'key', 'display', 'scale', 'rotate',
  'translate', 'zIndex', 'direction', 'align', 'constraintSize', 'layoutWeight', 'flexGrow', 'flexShrink',
  'foregroundColor', 'stateStyles', 'gesture', 'animation', 'transition', 'mask', 'shape'];
/** 取出一个 .ets 源码里声明的成员名（@State/@Prop/private 三类）。 */
function declaredMembers(source) {
  const names = [];
  const re = /(?:@State |@Prop |@Link |@Watch\([^)]*\) |private |private async )([a-zA-Z_][a-zA-Z0-9_]*)\s*(?::|\(|=)/g;
  let m = re.exec(source);
  while (m !== null) {
    names.push(m[1]);
    m = re.exec(source);
  }
  return names;
}
const loginMembers = declaredMembers(loginSrc);
const waitingMembers = declaredMembers(waitingSrc);
check('LoginScreen 的成员名不与 ArkUI 通用属性撞名',
  loginMembers.filter((n) => FORBIDDEN_MEMBERS.indexOf(n) >= 0).length === 0,
  loginMembers.filter((n) => FORBIDDEN_MEMBERS.indexOf(n) >= 0).join(','));
check('QrWaitingScreen 的成员名不与 ArkUI 通用属性撞名',
  waitingMembers.filter((n) => FORBIDDEN_MEMBERS.indexOf(n) >= 0).length === 0,
  waitingMembers.filter((n) => FORBIDDEN_MEMBERS.indexOf(n) >= 0).join(','));
check('成员扫描确实扫到了东西（防正则失效后永远绿）',
  loginMembers.length > 20 && waitingMembers.length > 5);
check('LoginMethodButton 的底色 / 前景色方法用避开撞名的名字',
  loginSrc.indexOf('private surfaceColor()') >= 0 &&
  loginSrc.indexOf('private contentColor()') >= 0 &&
  loginSrc.indexOf('private background(') < 0 &&
  loginSrc.indexOf('private foreground(') < 0);

/** 从 Design.ets 里取真实导出的颜色函数名 + 类名（import 白名单的唯一事实来源）。 */
const designSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8');
const designFns = [];
const fnRe = /export function ([a-zA-Z_][a-zA-Z0-9_]*)/g;
let fnMatch = fnRe.exec(designSrc);
while (fnMatch !== null) {
  designFns.push(fnMatch[1]);
  fnMatch = fnRe.exec(designSrc);
}
const designClasses = [];
const clsRe = /export class ([a-zA-Z_][a-zA-Z0-9_]*)/g;
let clsMatch = clsRe.exec(designSrc);
while (clsMatch !== null) {
  designClasses.push(clsMatch[1]);
  clsMatch = clsRe.exec(designSrc);
}
// R38：**补 `export const`** —— Design.ets 里的 `SAFE_AREA_TOP_PX` / `SAFE_AREA_BOTTOM_PX`
// 这类常量同样是合法的 import 目标，而原断言只收 function/class，于是把合法符号
// 误判成「不存在的成员」（既有假失败：LoginScreen 一直在 import SAFE_AREA_TOP_PX，
// 它确实由 Design.ets:492 导出）。
const designConsts = [];
const constRe = /export const ([a-zA-Z_][a-zA-Z0-9_]*)/g;
let constMatch = constRe.exec(designSrc);
while (constMatch !== null) {
  designConsts.push(constMatch[1]);
  constMatch = constRe.exec(designSrc);
}
/** 该名字是否是 Design.ets 真实导出的符号（函数 / 类 / 常量三类）。 */
function designHas(name) {
  return designFns.indexOf(name) >= 0 || designClasses.indexOf(name) >= 0
    || designConsts.indexOf(name) >= 0;
}
check('Design.ets 里确实有颜色函数与令牌类（防止解析失败导致误判）',
  designFns.length >= 10 && designClasses.length >= 5 && designConsts.length >= 5);
/** 把 from ../Design 的 import 列表拆出来。 */
function designImports(source) {
  const anchor = source.indexOf("from '../Design'");
  if (anchor < 0) { return []; }
  const head = source.lastIndexOf('import', anchor);
  const block = source.slice(head + 6, anchor);
  return block.split(',')
    .map((s) => s.replace(/{/g, '').replace(/}/g, '').trim())
    .filter((s) => s.length > 0);
}
const loginDesignImports = designImports(loginSrc);
const waitingDesignImports = designImports(waitingSrc);
check('LoginScreen 只 import Design.ets 真实存在的符号',
  loginDesignImports.filter((n) => !designHas(n)).length === 0,
  loginDesignImports.filter((n) => !designHas(n)).join(','));
check('QrWaitingScreen 只 import Design.ets 真实存在的符号',
  waitingDesignImports.filter((n) => !designHas(n)).length === 0,
  waitingDesignImports.filter((n) => !designHas(n)).join(','));
check('不再引用不存在的 onRaisedSurface（预构建报过 has no exported member）',
  loginSrc.indexOf('onRaisedSurface') < 0 && waitingSrc.indexOf('onRaisedSurface') < 0);
check('import 列表解析确实非空（防解析失效后永远绿）',
  loginDesignImports.length >= 5 && waitingDesignImports.length >= 5);

// ---------------------------------------------------------------------------

console.log(String.fromCharCode(10) + '通过 ' + passed + ' 项，失败 ' + failures.length + ' 项');
if (failures.length > 0) {
  console.log(String.fromCharCode(10) + '失败明细：');
  for (const f of failures) {
    console.log('  ✗ ' + f);
  }
  process.exit(1);
}
console.log('登录流程专项断言全部通过。');
