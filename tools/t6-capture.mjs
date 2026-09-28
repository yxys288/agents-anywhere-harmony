#!/usr/bin/env node
/**
 * T6 证据采集：**带就绪门**的模拟器截图（task-6）。
 *
 * 为什么需要它：直接 `aa start` 后固定 sleep 再截图，会采到**启动闪屏**
 * （实测 emp2.jpeg 就是闪屏：整屏只有应用图标）。
 * 各帧的「底栏带亮度剖面」于是差得很大 —— 那不是材质差异，是**页面状态不同**。
 * ⇒ 必须先确认「首页真的渲染出来了」再截图，否则 MAE 全是假的。
 *
 * 判据（两个都要）：
 *  ① 底栏四个入口文字（首页 / 设备 / 终端 / 文件）都在；
 *  ② 字标 "Agents Anywhere" 在（首页顶栏）。
 * 用法：node tools/t6-capture.mjs <hdc> <target> <out.jpeg> [超时秒]
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const [hdc, target, out, timeoutArg] = process.argv.slice(2);
const TIMEOUT_MS = (Number.parseInt(timeoutArg ?? '60', 10)) * 1000;
const DUMP = '/data/local/tmp/t6-dump.json';

const hdcRun = (args) => execFileSync(hdc, ['-t', target, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

function ready() {
  try {
    hdcRun(['shell', 'uitest', 'dumpLayout', '-p', DUMP]);
    const json = hdcRun(['shell', 'cat', DUMP]);
    const need = ['首页', '设备', '终端', '文件', 'Agents Anywhere'];
    return need.every((t) => json.includes(t));
  } catch (e) {
    return false;
  }
}

hdcRun(['shell', 'aa', 'force-stop', 'aa234.luoyaowen.23']);
execFileSync('powershell', ['-Command', 'Start-Sleep -Seconds 2']);
hdcRun(['shell', 'aa', 'start', '-b', 'aa234.luoyaowen.23', '-a', 'EntryAbility']);

const t0 = Date.now();
let ok = false;
while (Date.now() - t0 < TIMEOUT_MS) {
  if (ready()) { ok = true; break; }
  execFileSync('powershell', ['-Command', 'Start-Sleep -Seconds 2']);
}
if (!ok) {
  console.log('NOT_READY after ' + TIMEOUT_MS + 'ms');
  process.exit(2);
}
// 就绪后再等 1.5s 让首帧稳定（写入 AppStorage 的浮层底栏状态、动画收尾）
execFileSync('powershell', ['-Command', 'Start-Sleep -Seconds 2']);
hdcRun(['shell', 'snapshot_display', '-f', '/data/local/tmp/t6-shot.jpeg']);
hdcRun(['file', 'recv', '/data/local/tmp/t6-shot.jpeg', out]);
console.log('READY in ' + (Date.now() - t0) + 'ms -> ' + out + ' (' + fs.statSync(out).size + ' B)');
