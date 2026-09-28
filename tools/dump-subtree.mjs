// dumpLayout 子树打印器（R49 新增）：按路径前缀打印节点树，用来核对「谁在谁里面、谁的框越了谁的界」。
//
// 用法：
//   node tools/dump-subtree.mjs <dump.json> [路径前缀] [最大深度]
// 路径前缀形如 `r/0/0/1`（r=根，其后是子节点下标）；省略则打印全树。
import { readFileSync } from 'node:fs';

const file = process.argv[2];
if (file === undefined) {
  console.error('用法: node tools/dump-subtree.mjs <dump.json> [路径前缀] [最大深度]');
  process.exit(1);
}
const prefix = process.argv[3] !== undefined && process.argv[3].length > 0 ? process.argv[3] : 'r';
const maxDepth = process.argv[4] !== undefined ? Number(process.argv[4]) : 99;
const tree = JSON.parse(readFileSync(file, 'utf8'));

function box(node) {
  const raw = node.attributes && node.attributes.bounds;
  const m = /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/.exec(raw || '');
  return m === null ? null : { l: +m[1], t: +m[2], r: +m[3], b: +m[4] };
}

function describe(node) {
  const a = node.attributes || {};
  const parts = [String(a.type)];
  const text = a.text === undefined ? '' : String(a.text);
  if (text.length > 0) {
    parts.push('"' + (text.length > 24 ? text.slice(0, 24) + '…' : text) + '"');
  }
  const b = box(node);
  if (b !== null) {
    parts.push(`[${b.l},${b.t}][${b.r},${b.b}] 宽${b.r - b.l} 高${b.b - b.t}`);
  }
  const extra = [];
  if (a.backgroundColor !== undefined) extra.push('bg=' + a.backgroundColor);
  if (a.description !== undefined && String(a.description).length > 0) {
    extra.push('desc=' + String(a.description));
  }
  if (extra.length > 0) parts.push('{' + extra.join(' ') + '}');
  return parts.join(' ');
}

function walk(node, path, depth) {
  if (!path.startsWith(prefix) && !prefix.startsWith(path)) return;
  const indent = '  '.repeat(depth);
  console.log(`${indent}${path}  ${describe(node)}`);
  if (depth >= maxDepth) return;
  const children = node.children || [];
  for (let i = 0; i < children.length; i++) {
    walk(children[i], `${path}/${i}`, depth + 1);
  }
}

walk(tree, 'r', 0);
