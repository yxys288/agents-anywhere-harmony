#!/usr/bin/env node
/**
 * aa-hm **串行化构建**（Lead 建立的握手件，团队成员共用）。
 *
 * ## 为什么需要它
 * hvigor 的 `.hvigor/` 缓存与 `entry/build/` 产物是**共享可变状态**：两个 teammate 同时
 * 跑 `assembleHap` 会互相覆盖中间产物，最坏情况是「本次构建报成功，但产物是上一次的」
 * —— 这正是工作区里记录过的「命中缓存 UP-TO-DATE 的假成功」的翻版。
 * 所以本轮所有构建一律走本脚本：**拿锁 → 构建 → 释放**。
 *
 * ## 用法
 *   node tools/build-locked.mjs                  # 构建并打印产物路径 + md5
 *   node tools/build-locked.mjs --timeout-min 25 # 等锁上限（默认 20 分钟）
 *   node tools/build-locked.mjs --no-freeze      # 不冻结到 <临时目录>/aa-hm-haps
 *   node tools/build-locked.mjs --help           # 只打印解析后的路径与用法（不构建）
 *
 * ## 可移植化（环境变量优先，全部可选）
 *   AA_PROJECT_ROOT   工程根（默认：由本脚本位置上溯一层 = tools/ 的父目录）
 *   AA_TMP            临时目录（默认：系统临时目录 os.tmpdir()，锁与冻结产物都落这里）
 *   DEVECO_HOME       DevEco Studio 安装根（默认探测常见安装位置，如 D:/DevEco Studio）
 *   DEVECO_SDK_HOME   HarmonyOS SDK 根（默认 <DEVECO_HOME>/sdk，原样传给 hvigor）
 *   NODE_EXE          跑 hvigorw 的 node（默认：当前进程的 node = process.execPath）
 *   HVIGOR            hvigorw.js 路径（默认 <DEVECO_HOME>/tools/hvigor/bin/hvigorw.js）
 * 缺 hvigorw.js 时给出清晰中文报错，而不是静默失败。
 *
 * ## 判定
 * 只有 `BUILD SUCCESSFUL` **且** 脚本自己算出 md5 才算成功（退出码 0）。
 * 退出码 2 = 等锁超时（不是构建失败），直接重跑即可。
 */
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { env, devecoHome, projectRoot, tempDir } from './lib/env.mjs';

// ---------------------------------------------------------------------------
// 路径解析：环境变量优先 → 由脚本位置推导 → 常见安装位置兜底（详见文件头注释）
// ---------------------------------------------------------------------------
const PROJ = projectRoot({ up: 1, scriptUrl: import.meta.url });
const TMP = tempDir();
const LOCK = path.join(TMP, 'aa-hm-build.lock');
const HAPDIR = path.join(TMP, 'aa-hm-haps');
const DEVECO = devecoHome();
const SDK_HOME = env('DEVECO_SDK_HOME') || path.join(DEVECO, 'sdk');
const NODE_EXE = env('NODE_EXE') || process.execPath;
const HVIGOR = env('HVIGOR') || path.join(DEVECO, 'tools', 'hvigor', 'bin', 'hvigorw.js');

const args = process.argv.slice(2);
function argNum(name, dflt) {
  const i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return dflt;
  const v = Number(args[i + 1]);
  return Number.isFinite(v) ? v : dflt;
}
const TIMEOUT_MS = argNum('--timeout-min', 20) * 60 * 1000;
const FREEZE = args.indexOf('--no-freeze') < 0;

/** `--help`：只打印解析后的路径与用法，不拿锁、不构建（跨机器排查配置用）。 */
if (args.indexOf('--help') >= 0 || args.indexOf('-h') >= 0) {
  console.log('用法：node tools/build-locked.mjs [--timeout-min N] [--no-freeze] [--help]');
  console.log('  --timeout-min N  等锁上限（分钟，默认 20）；退出码 2 = 等锁超时，不是构建失败');
  console.log('  --no-freeze      不把签名 HAP 冻结到 <临时目录>/aa-hm-haps');
  console.log('解析后的路径（环境变量优先，其次常见安装位置）：');
  console.log('  AA_PROJECT_ROOT  ' + PROJ);
  console.log('  AA_TMP           ' + TMP);
  console.log('  DEVECO_HOME      ' + DEVECO);
  console.log('  DEVECO_SDK_HOME  ' + SDK_HOME);
  console.log('  NODE_EXE         ' + NODE_EXE);
  console.log('  HVIGOR           ' + HVIGOR + (existsSync(HVIGOR) ? '' : '   ← 不存在'));
  process.exit(0);
}

if (!existsSync(HVIGOR)) {
  console.error('未找到 hvigorw.js：' + HVIGOR);
  console.error('  · 请设置环境变量 HVIGOR=<hvigorw.js 完整路径>，或设置 DEVECO_HOME=<DevEco Studio 安装目录>（默认从 <DEVECO_HOME>/tools/hvigor/bin/hvigorw.js 取）；');
  console.error('  · 也可用 node tools/build-locked.mjs --help 查看当前解析结果。');
  process.exit(1);
}

if (!existsSync(TMP)) mkdirSync(TMP, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function acquire() {
  const deadline = Date.now() + TIMEOUT_MS;
  for (;;) {
    try {
      writeFileSync(LOCK, JSON.stringify({ pid: process.pid, at: Date.now() }), { flag: 'wx' });
      return;
    } catch (e) {
      // 锁存在：判断是否过期（>25 分钟视为残留，可抢占）
      try {
        const age = Date.now() - statSync(LOCK).mtimeMs;
        if (age > 25 * 60 * 1000) {
          console.log('[lock] 抢占用时过久的锁（age=' + Math.round(age / 1000) + 's）');
          unlinkSync(LOCK);
          continue;
        }
      } catch (_) { /* 锁刚被释放，下一轮重试即可 */ }
      if (Date.now() > deadline) {
        console.error('[lock] 等锁超时（' + Math.round(TIMEOUT_MS / 60000) + ' 分钟）—— 这不是构建失败，直接重跑');
        process.exit(2);
      }
      console.log('[lock] 已有构建在跑，等待 15s…');
      await sleep(15000);
    }
  }
}

function release() {
  try { unlinkSync(LOCK); } catch (_) { /* 已经不在了 */ }
}

function md5(file) {
  return createHash('md5').update(readFileSync(file)).digest('hex');
}

await acquire();
let rc = 1;
try {
  console.log('[build] hvigor assembleHap (cwd=' + PROJ + ')');
  // DEVECO_SDK_HOME 必须显式传给 hvigor；PATH 里补上 DevEco 自带 jbr（hvigor 会找 java）。
  const buildEnv = Object.assign({}, process.env, {
    DEVECO_SDK_HOME: SDK_HOME,
    PATH: path.join(DEVECO, 'jbr', 'bin') + path.delimiter + (process.env.PATH || ''),
  });
  const res = spawnSync(NODE_EXE, [HVIGOR, '--mode', 'module', '-p', 'product=default', '-p', 'buildMode=debug', 'assembleHap', '--no-daemon'], { cwd: PROJ, env: buildEnv, encoding: 'utf8' });
  process.stdout.write(res.stdout || '');
  process.stderr.write(res.stderr || '');
  const out = (res.stdout || '') + (res.stderr || '');
  const ok = out.indexOf('BUILD SUCCESSFUL') >= 0 && res.status === 0;
  if (!ok) {
    console.error('[build] FAILED (rc=' + res.status + ')');
    rc = 1;
  } else {
    const hap = path.join(PROJ, 'entry', 'build', 'default', 'outputs', 'default', 'entry-default-signed.hap');
    if (!existsSync(hap)) {
      console.error('[build] BUILD SUCCESSFUL 但找不到 ' + hap);
      rc = 1;
    } else {
      const sum = md5(hap);
      const bytes = statSync(hap).size;
      console.log('[build] OK hap=' + hap);
      console.log('[build] md5=' + sum + ' bytes=' + bytes);
      if (FREEZE) {
        if (!existsSync(HAPDIR)) mkdirSync(HAPDIR, { recursive: true });
        const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12);
        const dst = path.join(HAPDIR, 'dev-debug-' + stamp + '.hap');
        try {
          copyFileSync(hap, dst);
          writeFileSync(path.join(HAPDIR, 'last-frozen.txt'), dst + '  md5=' + md5(dst) + '\n');
          console.log('[build] frozen=' + dst + ' (md5=' + md5(dst) + ')');
        } catch (e) {
          console.error('[build] freeze failed: ' + e.message);
        }
      }
      rc = 0;
    }
  }
} finally {
  release();
}
process.exit(rc);
