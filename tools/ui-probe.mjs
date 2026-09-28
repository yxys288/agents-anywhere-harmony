// ui-probe.mjs —— 真机 dumpLayout 解析助手（避免 PowerShell 内联 node 的路径转义坑）。
//
// 用法：
//   node tools/ui-probe.mjs has   <layout.json> <text>         → 打印 1/0
//   node tools/ui-probe.mjs center <layout.json> <text>        → 打印 "x y"
//   node tools/ui-probe.mjs clickable <layout.json> <yMin> <yMax>  → 打印可点节点
//   node tools/ui-probe.mjs texts <layout.json>                → 打印全部文本
//
// ⚠️ 为什么单独一个文件：在 PowerShell 里用 `node -e "...$path..."` 拼 JSON 路径时，
//    `\t` 会被当转义（路径里的 `\t` 会变成 TAB），
//    于是路径断成 `E:` + TAB + `mp\...`，报 `Cannot find module`。写成文件即无此问题。
import { readFileSync } from 'node:fs';

const [, , cmd, file, ...rest] = process.argv;

function walk(node, fn) {
  fn(node);
  (node.children || []).forEach((c) => walk(c, fn));
}

function parseBounds(b) {
  const m = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(b || '');
  if (!m) return null;
  return { x0: +m[1], y0: +m[2], x1: +m[3], y1: +m[4] };
}

const root = JSON.parse(readFileSync(file, 'utf8'));

if (cmd === 'has') {
  const want = rest[0];
  let found = false;
  walk(root, (n) => {
    const a = n.attributes || {};
    if (String(a.text ?? '') === want) found = true;
  });
  console.log(found ? '1' : '0');
} else if (cmd === 'center') {
  const want = rest[0];
  let hit = null;
  walk(root, (n) => {
    if (hit) return;
    const a = n.attributes || {};
    if (String(a.text ?? '') === want) hit = a.bounds;
  });
  if (!hit) {
    console.log('');
  } else {
    const b = parseBounds(hit);
    console.log(Math.round((b.x0 + b.x1) / 2) + ' ' + Math.round((b.y0 + b.y1) / 2));
  }
} else if (cmd === 'clickable') {
  const yMin = +rest[0];
  const yMax = +rest[1];
  walk(root, (n) => {
    const a = n.attributes || {};
    if (a.clickable !== 'true') return;
    const b = parseBounds(a.bounds);
    if (b && b.y0 >= yMin && b.y1 <= yMax) {
      console.log(JSON.stringify([a.type, a.bounds, String(a.text ?? '').slice(0, 16)]));
    }
  });
} else if (cmd === 'texts') {
  const out = [];
  walk(root, (n) => {
    const a = n.attributes || {};
    if (a.text !== undefined && String(a.text).length > 0) out.push(String(a.text));
  });
  console.log(JSON.stringify(out));
} else {
  console.error('unknown cmd: ' + cmd);
  process.exit(1);
}
