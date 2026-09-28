// 越界扫描器（R49 新增）：在 uitest dumpLayout 的树里找「横向溢出屏幕 / 溢出父容器」的节点。
//
// 为什么需要它：用户反馈「消息气泡被屏幕边缘裁掉（左右溢出）」—— 这类缺陷在截图上只能"看个大概"，
// 而 dump 的 bounds 是逐节点精确值，可以直接算「右边界 − 屏宽」「子节点右边界 − 父节点右边界」。
//
// 用法：
//   node tools/overflow-scan.mjs <dump.json> [屏宽px]
// 不传屏宽时从根节点 bounds 推。
import { readFileSync } from 'node:fs';

const file = process.argv[2];
if (file === undefined) {
  console.error('用法: node tools/overflow-scan.mjs <dump.json> [屏宽]');
  process.exit(1);
}
const tree = JSON.parse(readFileSync(file, 'utf8'));

function bounds(node) {
  const raw = node.attributes && node.attributes.bounds;
  const m = /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/.exec(raw || '');
  if (!m) return null;
  return { l: +m[1], t: +m[2], r: +m[3], b: +m[4] };
}

const root = bounds(tree);
const screenW = process.argv[3] !== undefined ? Number(process.argv[3]) : (root ? root.r : 0);
const screenH = root ? root.b : 0;

let nodeCount = 0;
const overflowScreen = [];
const overflowParent = [];

function label(node) {
  const a = node.attributes || {};
  const text = a.text === undefined ? '' : String(a.text);
  const short = text.length > 28 ? text.slice(0, 28) + '…' : text;
  return `${a.type}${short.length > 0 ? ' "' + short + '"' : ''} ${a.bounds}`;
}

function walk(node, path, parentBox) {
  nodeCount++;
  const box = bounds(node);
  const children = node.children || [];
  if (box !== null) {
    if (box.l < 0 || box.r > screenW) {
      overflowScreen.push({ path, label: label(node), box });
    }
    if (parentBox !== null && (box.l < parentBox.l - 1 || box.r > parentBox.r + 1)) {
      overflowParent.push({ path, label: label(node), box, parent: parentBox });
    }
  }
  for (let i = 0; i < children.length; i++) {
    walk(children[i], `${path}/${i}`, box !== null ? box : parentBox);
  }
}

walk(tree, 'r', null);

console.log(`dump: ${file}`);
console.log(`屏宽 ${screenW}px / 屏高 ${screenH}px，共 ${nodeCount} 个节点`);
console.log('');
console.log(`== 越出屏幕左右边界（${overflowScreen.length} 个）==`);
for (const hit of overflowScreen) {
  console.log(`  ${hit.path}  ${hit.label}`);
}
console.log('');
console.log(`== 越出父容器左右边界（${overflowParent.length} 个）==`);
for (const hit of overflowParent) {
  console.log(`  ${hit.path}  ${hit.label}   父 [${hit.parent.l},${hit.parent.r}]`);
}
