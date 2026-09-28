// aa-hm 真机自动化小工具（第三轮新增）
//
// 为什么需要它：`uitest uiInput click <x> <y>` 用的是**设备像素坐标**，
// 而截图里量出来的坐标与 dumpLayout 的 bounds 不一定一一对应（差 3px 就会静默点空，
// 表现为「点了没反应」，极易误判成应用缺陷）。所以统一走：
//   dumpLayout → 解析真实 bounds → 取中心点 → 点击 → 截图 → 回读服务端写记录。
//
// 另外两个使用要点：
//  ① `dumpLayout` 每调用一次都要重新 dump（界面会变，别复用旧坐标）；
//  ② **弹层是否打开要先用 `has <标签>` 确认**，否则下一次点击可能点在遮罩上把它关掉
//     （第三轮踩过：以为面板没开，其实上一轮遗留的弹层正开着，一点就把自己关了）。
//
// 用法（workdir = 工程根，即 projects/aa-hm）:
//   node tools/device-ctl.mjs dump                   读取控件树到 <临时目录>/ui.json
//   node tools/device-ctl.mjs find <text>            输出首个匹配控件的中心坐标 "x y"
//   node tools/device-ctl.mjs click <text>           点首个匹配控件
//   node tools/device-ctl.mjs has <text>             输出 true/false
//   node tools/device-ctl.mjs shot <文件名>           截图到 <项目根>\<证据目录>\<文件名>
//                                                    证据目录默认 verify-YYYY-MM-DD（今天），可用 AA_EVIDENCE 覆盖
//   node tools/device-ctl.mjs text <字符串>           向已聚焦控件合成键入
//   node tools/device-ctl.mjs key <keyID>            注入按键（2055=DEL, 2082=MOVE_END）
//   node tools/device-ctl.mjs tap <x> <y>            按坐标点击
//   node tools/device-ctl.mjs debug                  打印 mock 服务端写操作记录
//
// 环境变量（全部可选）：
//   AA_DEVICE_SN / AA_DEVICE  目标设备序列号（**必填**；真机 sn，或模拟器 127.0.0.1:5555）
//   HDC                       hdc 完整路径（默认 <DEVECO_HOME>/sdk/default/openharmony/toolchains/hdc.exe）
//   DEVECO_HOME               DevEco Studio 安装根（默认探测常见安装位置）
//   AA_PROJECT_ROOT           工程根（默认由本脚本位置推导）
//   AA_TMP                    dumpLayout 临时文件目录（默认系统临时目录）
//   AA_EVIDENCE               截图落盘目录（默认「今天」的 verify-YYYY-MM-DD）
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import { deviceSerial, env, devecoHome, projectRoot, tempDir } from './lib/env.mjs';

const DEVECO = devecoHome();
const HDC = env('HDC') || path.join(DEVECO, 'sdk', 'default', 'openharmony', 'toolchains', 'hdc.exe');
// 目标设备可用环境变量切换：真机 sn 或模拟器 `127.0.0.1:5555`
//   AA_DEVICE_SN=127.0.0.1:5555 node tools/device-ctl.mjs texts
/** 目标设备序列号：**必须显式提供**（真机 sn，或模拟器 `127.0.0.1:5555`）。 */
const SN = deviceSerial();
if (!SN) {
  console.error('未指定目标设备序列号。');
  console.error('  · 请设置环境变量 AA_DEVICE_SN=<设备序列号>（多设备在线时必填，否则 hdc 可能打到另一台）；');
  console.error('  · 查看在线设备：' + HDC + ' list targets');
  console.error('  · 用法：AA_DEVICE_SN=<sn> node tools/device-ctl.mjs <命令>');
  process.exit(2);
}
const PROJ = projectRoot({ up: 1, scriptUrl: import.meta.url });
const TMP = path.join(tempDir(), 'ui.json');
// 截图落盘目录：默认「今天」的证据目录（verify-YYYY-MM-DD），可用 AA_EVIDENCE 覆盖。
// 早期版本把目录硬编码成某个固定日期目录，跨轮次跑会把新证据混进旧目录。
const EVIDENCE_DIR = env('AA_EVIDENCE') || (() => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return 'verify-' + d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
})();

if (!existsSync(HDC)) {
  console.error('未找到 hdc：' + HDC);
  console.error('  · 请设置环境变量 HDC=<hdc 完整路径>，或设置 DEVECO_HOME=<DevEco Studio 安装目录>');
  console.error('    （默认从 <DEVECO_HOME>/sdk/default/openharmony/toolchains/hdc.exe 取）。');
  process.exit(1);
}

function hdc(args) {
  return execFileSync(HDC, ['-t', SN, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function ui(args) {
  hdc(['shell', 'uitest', 'uiInput', ...args]);
}

function dump() {
  hdc(['shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/aa.json']);
  execFileSync(HDC, ['-t', SN, 'file', 'recv', '/data/local/tmp/aa.json', TMP], { stdio: 'ignore' });
  return JSON.parse(readFileSync(TMP, 'utf8'));
}

function walk(node, fn) {
  fn(node);
  (node.children || []).forEach((c) => walk(c, fn));
}

function allTexts(node) {
  const out = [];
  walk(node, (n) => {
    const t = n.attributes && n.attributes.text;
    if (t !== undefined && String(t).length > 0) out.push(String(t));
  });
  return out;
}

function center(bounds) {
  const m = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(bounds || '');
  if (!m) return null;
  return [Math.round((+m[1] + +m[3]) / 2), Math.round((+m[2] + +m[4]) / 2)];
}

function findByText(node, text, exact) {
  let hit = null;
  walk(node, (n) => {
    if (hit) return;
    const a = n.attributes || {};
    const t = a.text === undefined ? '' : String(a.text);
    if (!t) return;
    if (exact ? t === text : t.includes(text)) hit = n;
  });
  return hit;
}

const [cmd, ...rest] = process.argv.slice(2);
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

switch (cmd) {
  case 'find':
  case 'has':
  case 'click': {
    const node = dump();
    const hit = findByText(node, rest[0], rest[1] === 'exact');
    if (!hit) {
      if (cmd === 'has') console.log('false');
      else {
        console.log('NOT_FOUND ' + rest[0]);
        console.log('现有文本: ' + JSON.stringify(allTexts(node).slice(0, 40)));
        process.exit(2);
      }
      break;
    }
    if (cmd === 'has') {
      console.log('true');
      break;
    }
    const c = center(hit.attributes.bounds);
    console.log(c.join(' '));
    if (cmd === 'click') {
      ui(['click', String(c[0]), String(c[1])]);
    }
    break;
  }
  case 'findtype': {
    const node = dump();
    let hit = null;
    walk(node, (n) => {
      const a = n.attributes || {};
      if (!hit && a.type && String(a.type).includes(rest[0])) hit = n;
    });
    if (!hit) {
      console.log('NOT_FOUND type ' + rest[0]);
      break;
    }
    const c = center(hit.attributes.bounds);
    console.log(c.join(' '));
    if (rest[1] === 'click') ui(['click', String(c[0]), String(c[1])]);
    break;
  }
  case 'nodes': {
    // 列出所有 type 含指定片段的控件（查输入框/按钮用），带中心坐标。
    const node = dump();
    let count = 0;
    walk(node, (n) => {
      const a = n.attributes || {};
      if (a.type && String(a.type).includes(rest[0])) {
        const c = center(a.bounds);
        console.log(String(a.type).padEnd(18), JSON.stringify(a.text ?? ''), a.bounds, c ? c.join(' ') : '');
        count++;
      }
    });
    console.log('共 ' + count + ' 个');
    break;
  }
  case 'del': {
    const n = Number(rest[0] || 40);
    for (let i = 0; i < n; i++) {
      ui(['keyEvent', '2055']);
      sleep(40);
    }
    break;
  }
  case 'tap':
    ui(['click', rest[0], rest[1]]);
    break;
  case 'swipe':
    // 例：node device-ctl.mjs swipe 658 2000 658 700（向上滑 = 内容往下翻）
    ui(['swipe', rest[0], rest[1], rest[2], rest[3], rest[4] || '600']);
    break;
  case 'fling':
    // direction: 0 左 / 1 右 / 2 上 / 3 下
    ui(['dircFling', rest[0], rest[1] || '2000']);
    break;
  case 'key':
    ui(['keyEvent', rest[0]]);
    break;
  case 'text':
    ui(['text', rest.join(' ')]);
    break;
  case 'shot': {
    hdc(['shell', 'snapshot_display', '-f', '/data/local/tmp/aa.jpeg']);
    execFileSync(HDC, ['-t', SN, 'file', 'recv', '/data/local/tmp/aa.jpeg', path.join(PROJ, EVIDENCE_DIR, rest[0])], {
      stdio: 'ignore'
    });
    console.log('saved ' + EVIDENCE_DIR + '/' + rest[0]);
    break;
  }
  case 'texts': {
    console.log(JSON.stringify(allTexts(dump()), null, 0));
    break;
  }
  case 'debug': {
    const res = execFileSync('curl.exe', ['-s', '-m', '5', 'http://127.0.0.1:8787/api/v2/debug/state'], {
      encoding: 'utf8'
    });
    console.log(JSON.stringify(JSON.parse(res), null, 1));
    break;
  }
  case 'sleep':
    sleep(Number(rest[0]));
    break;
  default:
    console.log('unknown command: ' + cmd);
    process.exit(1);
}
rmSync(TMP, { force: true });
