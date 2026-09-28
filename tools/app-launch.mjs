#!/usr/bin/env node
// aa-hm 真机「启动本应用」工具（R83 新增）。
//
// 为什么需要它：本机这套真机环境里 `aa start -b <bundle> -a EntryAbility` **恒定失败**
//   10104001 The specified ability does not exist（module.json 的 mainElement/abilities 都正确，
//   `bm dump -a` 也能列出该包 —— 设备侧 aa 命令的既有怪癖，不是工程缺陷）。
// 于是「把应用拉到前台」只能走**桌面图标点击**；而桌面有多页、且 dumpLayout **不暴露图标的 bundleName**
// （实测：图标节点的 bundleName 属性为空，只有 `com.ohos.sceneboard`）⇒ 只能按**应用显示名**匹配。
//
// 用法（workdir = 工程根，即 projects/aa-hm）：
//   node tools/app-launch.mjs [maxPages]     默认 6 页；成功打印 pid，失败 exit 1
//
// 环境变量（全部可选，未设时用下面的默认值）：
//   AA_DEVICE_SN / AA_DEVICE  目标设备序列号（**必填**，多设备在线时不带 -t 可能打到另一台）
//   HDC                       hdc 可执行文件完整路径（默认 <DEVECO_HOME>/sdk/default/openharmony/toolchains/hdc.exe）
//   DEVECO_HOME               DevEco Studio 安装根（默认探测常见安装位置）
//   AA_TMP                    dumpLayout 落盘目录（默认系统临时目录）
//   AA_BUNDLE / AA_LABEL      包名与应用显示名（默认见下）
// 设计要点：
//   · 命中判据 = 图标节点 id 前缀属白名单且含 bundleName（桌面不暴露图标的 bundleName/text，
//     故以 id 为主），另并列两条备用判据：`bundleName` 属性相等、`text` 恰等于应用显示名；
//   · 先向右翻（回首页方向）再用向左翻逐页扫，扫不到就反向再扫一遍；
//   · 每页重新 dumpLayout，不复用旧坐标；
//   · 点完回读 `pidof` 作为**效果判据**（点一下没报错 ≠ 拉起来了）。
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { deviceSerial, env, devecoHome, tempDir } from './lib/env.mjs';

const DEVECO = devecoHome();
const HDC = env('HDC') || path.join(DEVECO, 'sdk', 'default', 'openharmony', 'toolchains', 'hdc.exe');
/** 目标设备序列号：**必须显式提供**（多设备在线时不带 -t 会打到另一台，见 worktree 实证）。 */
let SN = deviceSerial();
if (!SN) {
  console.error('未指定目标设备序列号。');
  console.error('  · 请设置环境变量 AA_DEVICE_SN=<设备序列号>（多设备在线时必填）；');
  console.error('  · 查看在线设备：' + HDC + ' list targets');
  console.error('  · 用法：AA_DEVICE_SN=<sn> node tools/app-launch.mjs [maxPages]');
  process.exit(2);
}
const BUNDLE = env('AA_BUNDLE') || 'aa234.luyaowen.23';
const LABEL = env('AA_LABEL') || 'Agents Anywhere';
const LAYOUT = path.join(tempDir(), 'app-launch-ui.json');
const MAX_PAGES = Number(process.argv[2] || '6');

if (!existsSync(HDC)) {
  console.error('未找到 hdc：' + HDC);
  console.error('  · 请设置环境变量 HDC=<hdc 完整路径>，或设置 DEVECO_HOME=<DevEco Studio 安装目录>');
  console.error('    （默认从 <DEVECO_HOME>/sdk/default/openharmony/toolchains/hdc.exe 取）。');
  process.exit(1);
}

function hdc(args, timeout) {
  return execFileSync(HDC, ['-t', SN, ...args], { encoding: 'utf8', timeout: timeout || 60000, stdio: ['ignore', 'pipe', 'pipe'] });
}
function sleep(ms) { const t = Date.now(); while (Date.now() - t < ms) { /* wait */ } }
function dump() {
  hdc(['shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/app-launch.json']);
  execFileSync(HDC, ['-t', SN, 'file', 'recv', '/data/local/tmp/app-launch.json', LAYOUT], { stdio: 'ignore' });
  return JSON.parse(readFileSync(LAYOUT, 'utf8'));
}
/**
 * 桌面图标的命中判据（实测得出，三条并列）：
 *  ① `id` 形如 `AppIcon_Image_<bundle><Ability>entry0_...` —— 桌面**不暴露图标的 bundleName/text**，
 *     只有把 bundle 编进 `id` 这一条稳定线索（真机 dumpLayout 实测）；
 *  ② 文件夹内层同理，前缀是 `Container_AppIcon_Image_`；
 *  ③ `text` 等于应用显示名（备用：将来系统若把 label 暴露出来）。
 */
function findIcon(node) {
  let hit = null;
  (function walk(n) {
    if (hit) { return; }
    const a = n.attributes || {};
    const id = a.id === undefined ? '' : String(a.id);
    const text = a.text === undefined ? '' : String(a.text);
    // 命中判据：**id 前缀是图标形态** + id 里含 bundleName。真机实测三种形态：
    //   · `AppIcon_Image_<bundle><Ability>entry0_...`
    //   · `Container_AppIcon_Image_<bundle>...`（文件夹 / 堆叠容器内）
    //   · `SwiperPage_GridItem_[<bundle>___<id>___0,2]`（桌面格子）
    // ⚠️ 只判「id 含 bundle」会误命中桌面顶部那些**也带 bundle 字的容器节点**（实测误点到状态栏搜索区
    //    `[385,177][931,294]`）⇒ 前缀白名单是必需的，不是保险。
    const iconId = id.startsWith('AppIcon_Image_') || id.startsWith('Container_AppIcon_Image_')
      || id.startsWith('SwiperPage_GridItem_[');
    const byId = iconId && id.indexOf(BUNDLE) >= 0;
    if (byId || a.bundleName === BUNDLE || text === LABEL) { hit = a.bounds; return; }
    for (const c of (n.children || [])) { walk(c); }
  })(node);
  return hit;
}
function center(bounds) {
  const m = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(bounds || '');
  if (!m) { return null; }
  return [Math.round((+m[1] + +m[3]) / 2), Math.round((+m[2] + +m[4]) / 2)];
}
/**
 * 取应用 pid。
 *
 * ⚠️ **不能用 `pidof`**：本机真机上第三方应用的 `pidof <bundle>` 恒返回空（实测：应用正在前台跑着，
 * `pidof` 也是空，而 `ps -ef | grep` 能拿到）——R83 用 `pidof` 当效果判据时把「启动成功」误判成「没起来」。
 * 用 `ps -ef` 兜底是必需的，不是可选优化。
 */
function pidOf() {
  try {
    const out = hdc(['shell', 'ps -ef | grep ' + BUNDLE + ' | grep -v grep']);
    const line = out.split(/\r?\n/).find((l) => l.indexOf(BUNDLE) >= 0);
    if (!line) { return ''; }
    const parts = line.trim().split(/\s+/);
    return parts.length > 1 ? parts[1] : '';
  } catch (e) { return ''; }
}
/**
 * 翻页的滑动纵坐标：**必须落在空白墙纸上**。
 * ⚠️ 原先写 y=1500，而首页那一带的 y 正好压在「当下可能需要」文件夹上 ⇒ 横滑变成**拖动文件夹**，
 *    页面根本没翻，于是「翻 6 页都没命中图标」（R83 实测：手动 HOME + dump 明明有该图标）。
 * y=1780 在实测的首页/购物页都落在文件夹与底栏之间的空白处。
 */
const SWIPE_Y = '1780';
/** 翻到**下一页**桌面：手指从右往左划（真机实测该方向才是「下一屏」）。 */
function swipeNext() { hdc(['shell', 'uitest', 'uiInput', 'swipe', '1150', SWIPE_Y, '150', SWIPE_Y, '400']); sleep(1000); }
/** 翻到上一页（反向）。 */
function swipePrev() { hdc(['shell', 'uitest', 'uiInput', 'swipe', '150', SWIPE_Y, '1150', SWIPE_Y, '400']); sleep(1000); }

const existing = pidOf();
if (existing.length > 0) { console.log('already running, pid=' + existing.split(/\s+/)[0]); process.exit(0); }

const seen = [];
function attempt(tag) {
  const bounds = findIcon(dump());
  if (!bounds) { seen.push(tag); return false; }
  const c = center(bounds);
  console.log('icon found @ ' + tag + ' bounds=' + bounds + ' -> tap ' + c[0] + ',' + c[1]);
  hdc(['shell', 'uitest', 'uiInput', 'click', String(c[0]), String(c[1])]);
  sleep(4000);
  const pid = pidOf();
  if (pid.length === 0) { console.error('[FAIL] 点了图标但进程没起来（ps -ef 里没有该进程）'); process.exit(1); }
  console.log('[OK] launched, pid=' + pid.split(/\s+/)[0]);
  process.exit(0);
}

// 先用 HOME 键回到桌面首页（不靠滑动猜方向 —— 桌面最左那屏是「负一屏」，
// 向右划会停在资讯页而不是回到首页，R83 第一版扫描就卡死在那里，12 页全没命中）。
hdc(['shell', 'uitest', 'uiInput', 'keyEvent', '1']);
sleep(1500);
for (let p = 1; p <= MAX_PAGES; p++) {
  if (attempt('page ' + p)) { /* exit inside */ }
  console.log('page ' + p + ': 未命中');
  swipeNext();
}
// 反向兜底（万一 HOME 落在的不是第一页）
for (let p = 1; p <= MAX_PAGES; p++) {
  if (attempt('back-page ' + p)) { /* exit inside */ }
  swipePrev();
}
console.error('[FAIL] ' + (MAX_PAGES * 2) + ' 页都没找到「' + LABEL + '」的图标');
process.exit(1);
