#!/usr/bin/env node
/**
 * aa-hm「上下文圆环」数据层的纯逻辑断言（R52 新增）。
 *
 * 被测代码：`model/ContextUsage.ets`（零 import，可单独转译）。
 * 触发这轮改动的是用户要求：「对话框发送按钮左边增加上下文圆环」。
 *
 * 数据形状出处（不是猜的）：
 *  · DSH `dsh-token-meter/lib/types/usage-projection.js:68-78` 的 `contextPressureStateSchema`：
 *    `{ contextWindow?, pressureTokens?, surfaceTokens, sampledSurfaceTokens? }`；
 *  · 经 DSH bridge 补丁（`tools/dsh-bridge-patch/patch.mjs`）放进 `session.getState` 的 metadata，
 *    AA 服务端原样透传 ⇒ 客户端读 `runtimeState.metadata.contextPressure`。
 *
 * 用法（workdir = projects/aa-hm）：
 *   node tools/logic-test/suite-context-usage.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-context-usage');
const LOGIC_FILES = ['model/ContextUsage.ets'];
const NL = String.fromCharCode(10);

function build() {
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const require = createRequire(import.meta.url);
  const ts = requireTypeScript();
  for (const rel of LOGIC_FILES) {
    const source = fs.readFileSync(path.join(SRC_ETS, rel), 'utf8');
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, removeComments: false },
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
  if (condition) { passed += 1; } else { failures.push(detail === undefined ? name : name + ' — ' + detail); }
}
function eq(name, actual, expected) {
  check(name, actual === expected, name + ' — expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function group(title) { console.log(NL + '== ' + title); }

build();
const require = createRequire(import.meta.url);
const M = require(path.join(OUT_DIR, 'model/ContextUsage.js'));

function meta(pressure) {
  return { contextPressure: pressure };
}

group('① 正常解析');
const basic = M.contextUsageFrom(meta({ contextWindow: 200000, surfaceTokens: 12000 }));
eq('窗口', basic.windowTokens, 200000);
eq('占用取 surfaceTokens', basic.usedTokens, 12000);
eq('占比', basic.ratio, 0.06);
eq('已知', basic.known, true);
eq('档位 ok', basic.level, 'ok');
eq('pressureTokens 优先于 surfaceTokens', M.contextUsageFrom(meta({ contextWindow: 1000, surfaceTokens: 10, pressureTokens: 700 })).usedTokens, 700);

group('② 缺数据一律「未知」，绝不猜分母');
eq('没有 metadata', M.contextUsageFrom(undefined).known, false);
eq('metadata 为空对象', M.contextUsageFrom({}).known, false);
eq('没有 contextPressure', M.contextUsageFrom({ other: 1 }).known, false);
eq('contextPressure 不是对象', M.contextUsageFrom(meta('x')).known, false);
eq('没有 contextWindow ⇒ 未知（不猜分母）', M.contextUsageFrom(meta({ surfaceTokens: 5000 })).known, false);
eq('contextWindow=0 ⇒ 未知', M.contextUsageFrom(meta({ contextWindow: 0, surfaceTokens: 5000 })).known, false);
eq('contextWindow 负数 ⇒ 未知', M.contextUsageFrom(meta({ contextWindow: -1, surfaceTokens: 5 })).known, false);
eq('未知时占比恒 0', M.contextUsageFrom(meta({ surfaceTokens: 5 })).ratio, 0);
eq('未知时文字为空串', M.contextUsageLabel(M.contextUsageFrom(meta({ surfaceTokens: 5 }))), '');

group('③ 噪声与越界');
eq('占用超过窗口 ⇒ 夹到 1', M.contextUsageFrom(meta({ contextWindow: 100, surfaceTokens: 250 })).ratio, 1);
eq('占用为负 ⇒ 夹到 0', M.contextUsageFrom(meta({ contextWindow: 100, surfaceTokens: -5 })).ratio, 0);
eq('占用缺失 ⇒ 0', M.contextUsageFrom(meta({ contextWindow: 100 })).usedTokens, 0);
eq('NaN 窗口 ⇒ 未知', M.contextUsageFrom(meta({ contextWindow: NaN, surfaceTokens: 1 })).known, false);

group('④ 档位阈值');
eq('69% ⇒ ok', M.contextLevel(0.69), 'ok');
eq('70% ⇒ warn', M.contextLevel(0.7), 'warn');
eq('89% ⇒ warn', M.contextLevel(0.89), 'warn');
eq('90% ⇒ critical', M.contextLevel(0.9), 'critical');
eq('100% ⇒ critical', M.contextLevel(1), 'critical');

group('⑤ 文字');
eq('千以内原样', M.compactTokens(999), '999');
eq('四位数压成 k', M.compactTokens(12000), '12k');
eq('小数保留一位', M.compactTokens(1234), '1.2k');
eq('大数取整', M.compactTokens(123456), '123k');
eq('0 ⇒ 0', M.compactTokens(0), '0');
eq('负数 ⇒ 0', M.compactTokens(-3), '0');
eq('完整文字', M.contextUsageLabel(M.contextUsageFrom(meta({ contextWindow: 200000, surfaceTokens: 12000 }))), '12k / 200k（6%）');

group('⑥ 变异测试（把关键分支改坏必须变红）');
function mutate(replacements, name, shouldFail) {
  const source = fs.readFileSync(path.join(SRC_ETS, 'model/ContextUsage.ets'), 'utf8');
  let out = source;
  for (const [from, to] of replacements) { out = out.replace(from, to); }
  check(name + '：变异确实改到了源码', out !== source);
  const dir = path.join(OUT_DIR, 'mutant');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const ts = requireTypeScript();
  const js = ts.transpileModule(out, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: 'm.ets'
  }).outputText;
  const file = path.join(dir, 'm.js');
  fs.writeFileSync(file, js, 'utf8');
  delete require.cache[require.resolve(file)];
  const Mut = require(file);
  let failed = false;
  try { failed = shouldFail(Mut); } catch (error) { failed = true; }
  check(name + '：变异后行为确实变坏', failed === true);
}
mutate([[`  if (windowTokens <= 0) {
    return emptyContextUsage();
  }`, '']], '去掉「没有窗口就不画」的守卫', (Mut) => {
  return Mut.contextUsageFrom(meta({ surfaceTokens: 5000 })).known !== false;
});
mutate([[`  return value >= 1 ? 1 : value;`, '  return value;']], '占比不再夹到 1', (Mut) => {
  return Mut.contextUsageFrom(meta({ contextWindow: 100, surfaceTokens: 250 })).ratio !== 1;
});
mutate([[`  if (ratio >= CONTEXT_CRITICAL_RATIO) {
    return 'critical';
  }`, '']], '去掉 critical 档', (Mut) => {
  return Mut.contextLevel(0.95) !== 'critical';
});
mutate([[`  const usedTokens = pressureTokens > 0 ? pressureTokens : surfaceTokens;`,
  '  const usedTokens = surfaceTokens;']], '不再优先用 pressureTokens', (Mut) => {
  return Mut.contextUsageFrom(meta({ contextWindow: 1000, surfaceTokens: 10, pressureTokens: 700 })).usedTokens !== 700;
});

if (failures.length > 0) {
  console.error('suite-context-usage: ' + failures.length + ' 条断言失败');
  for (const f of failures) { console.error('  FAIL ' + f); }
  process.exit(1);
}
console.log('suite-context-usage: ' + passed + ' 条断言全绿（含 4 组变异测试）。');
