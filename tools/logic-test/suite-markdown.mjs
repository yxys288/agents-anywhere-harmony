#!/usr/bin/env node
/**
 * aa-hm Markdown 解析/渲染的专项自测（第八轮：图片 / 公式 / 代码块横滚行号）。
 *
 * 与 `run-tests.mjs` 同源：用 DevEco 自带的 TypeScript 把**不依赖 ArkUI 的纯逻辑**
 * （`ui/MarkdownParse.ets`）转译成 CommonJS 后在 Node 里跑断言，
 * 让「解析层是否按预期工作」在拿到签名 HAP 之前就有可复现证据。
 *
 * 渲染层（`ui/Markdown.ets`）无法在 Node 里实例化 ArkUI 组件，所以对它的检查是
 * **源码级约定检查**：断言「图片必须要 `constraintSize` 上限、必须有 onError 降级、
 * 代码块必须横向 `Scroll`」这类**结构性回归约束**（踩过的坑都是结构写错，不是算错）。
 *
 * 用法（workdir = 工程根，即本仓库根目录）：
 *   node tools/logic-test/suite-markdown.mjs
 * 产物落在系统临时目录，不污染工程目录。
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-markdown');

/** 只挑不 import @kit / ArkUI 的模块。 */
const LOGIC_FILES = ['ui/MarkdownParse.ets', 'ui/SyntaxHighlight.ets'];

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
    failures.push(detail === undefined ? name : `${name} — ${detail}`);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function group(title) {
  console.log(`\n== ${title}`);
}

const NL = String.fromCharCode(10);

// ---------------------------------------------------------------------------

build();

const require = createRequire(import.meta.url);
const md = require(path.join(OUT_DIR, 'ui/MarkdownParse.js'));
const hl = require(path.join(OUT_DIR, 'ui/SyntaxHighlight.js'));
const renderSrc = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Markdown.ets'), 'utf8');

// ---------------------------------------------------------------------------
// 一、图片解析
// ---------------------------------------------------------------------------

group('Markdown 图片解析（ui/MarkdownParse）');
const imageLine = md.parseMarkdown('![架构图](https://cdn.example.com/a.png)');
eq('独立成行的图片是 IMAGE 块', imageLine[0].kind, 'image');
eq('图片 alt 保留', imageLine[0].alt, '架构图');
eq('图片地址保留', imageLine[0].url, 'https://cdn.example.com/a.png');
eq('图片块正文＝alt（供降级显示）', imageLine[0].text, '架构图');
check('图片块的 ForEach key 含地址指纹', imageLine[0].key.indexOf('cdn.example.com') >= 0);

const imageTitle = md.parseMarkdown('![图](u.png "标题")');
eq('带 title 的图片 URL 只取地址', imageTitle[0].url, 'u.png');

const imagePair = md.parseMarkdown(['![一](1.png)', '![二](2.png)'].join(NL));
eq('相邻图片各成一块', imagePair.length, 2);
eq('第二张图片地址', imagePair[1].url, '2.png');

const mixed = md.parseMarkdown(['说明文字', '![图](u.png)', '结尾文字'].join(NL));
eq('图文混排切成三块', mixed.length, 3);
eq('中间是图片块', mixed[1].kind, 'image');
eq('图片前是段落', mixed[0].kind, 'paragraph');
eq('图片后是段落', mixed[2].kind, 'paragraph');

const brokenImage = md.parseMarkdown('![图](u.png');
eq('括号未闭合的图片行不算图片块', brokenImage[0].kind, 'paragraph');

const inlineImage = md.parseInline('见 ![架构图](https://a.com/x.png) 后面');
const inlineImageToken = inlineImage.filter((t) => t.image !== undefined);
eq('行内图片产生一个图片 token', inlineImageToken.length, 1);
eq('行内图片地址', inlineImageToken[0].image, 'https://a.com/x.png');
eq('行内图片文本＝alt', inlineImageToken[0].text, '架构图');
eq('图片 token 不再当链接', inlineImageToken[0].link, undefined);

const linkOnly = md.parseInline('见 [架构图](https://a.com/x.png)');
eq('普通链接不产生图片 token', linkOnly.filter((t) => t.image !== undefined).length, 0);
eq('普通链接仍是链接', linkOnly.filter((t) => t.link !== undefined).length, 1);
eq('图片链接的纯文本只剩 alt', md.plainText('前 ![图](u.png) 后'), '前 图 后');
eq('空地址的行内图片不识别', md.parseInline('![x]()').filter((t) => t.image !== undefined).length, 0);

// ---------------------------------------------------------------------------
// 二、数学公式解析
// ---------------------------------------------------------------------------

group('Markdown 数学公式解析（ui/MarkdownParse）');
const blockMath = md.parseMarkdown('$$a^2 + b^2 = c^2$$');
eq('单行 $$..$$ 是 MATH 块', blockMath[0].kind, 'math');
eq('公式内容剥掉定界符', blockMath[0].text, 'a^2 + b^2 = c^2');
eq('单行公式只产生一块', blockMath.length, 1);

const multiMath = md.parseMarkdown(['$$', '\\frac{1}{2}', '\\sum_i x_i', '$$'].join(NL));
eq('多行公式是 MATH 块', multiMath[0].kind, 'math');
eq('多行公式内容按原样保留', multiMath[0].text, '\\frac{1}{2}' + NL + '\\sum_i x_i');
check('公式换行没被吃掉', multiMath[0].text.indexOf(NL) > 0);

const unclosedMath = md.parseMarkdown(['$$', 'x + y'].join(NL));
eq('未闭合公式不丢内容', unclosedMath[0].kind, 'math');
eq('未闭合公式文本保留', unclosedMath[0].text, 'x + y');

const inlineMath = md.parseInline('勾股 $a^2+b^2$ 成立');
const mathTokens = inlineMath.filter((t) => t.math === true);
eq('行内公式产生一个 token', mathTokens.length, 1);
eq('行内公式内容剥掉 $', mathTokens[0].text, 'a^2+b^2');
check('公式 token 不带斜体标记', mathTokens[0].italic === false);

const mathStar = md.parseInline('$a*b$ 之后');
eq('公式里的 * 不会被当斜体标记', mathStar.filter((t) => t.italic === true).length, 0);
eq('公式里的 * 原样留在公式里', mathStar[0].text, 'a*b');
eq('公式后面仍是普通文本', mathStar[1].text, ' 之后');

const money = md.parseInline('价 $5 与 $10 都不贵');
eq('钱数不会被误判成公式', money.filter((t) => t.math === true).length, 0);
eq('钱数原文完整保留', md.plainText('价 $5 与 $10 都不贵'), '价 $5 与 $10 都不贵');

const codeMath = md.parseInline('代码 `$x$` 不算公式');
eq('行内代码里的 $ 不算公式', codeMath.filter((t) => t.math === true).length, 0);
eq('行内代码仍是代码', codeMath[1].code, true);

eq('孤立 $ 原样保留', md.plainText('只要 $ 一个'), '只要 $ 一个');
eq('未配对 $ 原样保留', md.parseInline('$a 未闭合')[0].text, '$a 未闭合');

const dollarPair = md.parseInline('公式 $$x$$ 结束');
eq('行内 $$ 也当公式（双定界符）', dollarPair[1].text, 'x');
check('双定界符公式标记正确', dollarPair[1].math === true);

const escDollar = md.parseInline('转义 \\$a 之后');
eq('转义 $ 不会被当公式', escDollar.filter((t) => t.math === true).length, 0);
eq('转义 $ 原样保留', md.plainText('转义 \\$a 之后'), '转义 \\$a 之后');

const twoMath = md.parseInline('$x$ 与 $y$');
eq('一行里两个公式各自成 token', twoMath.filter((t) => t.math === true).length, 2);
eq('两个公式之间的文本保留', twoMath[1].text, ' 与 ');

eq('公式的纯文本不含 $', md.plainText('结果 $a^2$ 结束'), '结果 a^2 结束');

const hashMath = md.parseMarkdown('head $x$ tail');
eq('公式不改变段落块类型', hashMath[0].kind, 'paragraph');
eq('段落里的公式仍可被行内解析', md.parseInline(hashMath[0].text).filter((t) => t.math === true).length, 1);

// ---------------------------------------------------------------------------
// 三、代码块按行切分与行号（ui/MarkdownParse 的纯函数）
// ---------------------------------------------------------------------------

group('代码块按行切分与行号（splitTokenLines / gutterText）');
const codeTokens = hl.tokenizeCode('const a = 1;' + NL + 'return a;', 'ts');
const codeLines = md.splitTokenLines(codeTokens, 'const a = 1;' + NL + 'return a;');
eq('两行代码切成两行', codeLines.length, 2);
eq('第一行非空', codeLines[0].tokens.length > 0, true);
eq('第一行去掉了换行符', codeLines[0].tokens.map((t) => t.text).join('').indexOf(NL), -1);
eq('第一行文本还原', codeLines[0].tokens.map((t) => t.text).join(''), 'const a = 1;');
eq('行长度用于空行判定', codeLines[0].size, 'const a = 1;'.length);

const blankTokens = hl.tokenizeCode('a' + NL + NL + 'b', 'ts');
const blankLines = md.splitTokenLines(blankTokens, 'a' + NL + NL + 'b');
eq('中间空行也算一行', blankLines.length, 3);
eq('空行 tokens 为空', blankLines[1].tokens.length, 0);
eq('空行 size 为 0', blankLines[1].size, 0);

const tailTokens = hl.tokenizeCode('a' + NL, 'ts');
eq('末尾换行不产生多余空行', md.splitTokenLines(tailTokens, 'a' + NL).length, 1);

eq('行号从 1 连续到 n', md.gutterText(3), '1' + NL + '2' + NL + '3');
eq('单行行号为 1', md.gutterText(1), '1');
eq('0 行兜底为 1（不留空列）', md.gutterText(0), '1');

// ---------------------------------------------------------------------------
// 三、渲染层的结构性约定（源码级检查）
// ---------------------------------------------------------------------------

group('渲染层结构约定（ui/Markdown.ets 源码检查）');
check('图片走 ArkUI Image 组件', renderSrc.indexOf('Image(this.urlOf(block))') >= 0);
check('图片宽度有上限常量', renderSrc.indexOf('const IMAGE_MAX_WIDTH: number = 240;') >= 0);
check('图片用 constraintSize 限制宽度（不用百分比宽度）',
  renderSrc.indexOf('.constraintSize({ maxWidth: IMAGE_MAX_WIDTH, maxHeight: IMAGE_MAX_WIDTH })') >= 0);
check('图片带圆角与底色（加载中不至于突兀）',
  renderSrc.indexOf('.borderRadius(Radius.M)') >= 0 && renderSrc.indexOf("app.color.session_code_surface") >= 0);
check('图片来源加 onError 回调',
  renderSrc.indexOf('.onError(() => {') >= 0 && renderSrc.indexOf('markImageFailed(this.urlOf(block))') >= 0);
check('加载失败降级为 alt 文本',
  renderSrc.indexOf('imageFallbackText(block)') >= 0 && renderSrc.indexOf('◧') >= 0);
check('失败地址只登记一次（避免 onError 反复触发）',
  renderSrc.indexOf('this.failedImages.includes(url)') >= 0 &&
  renderSrc.indexOf('this.failedImages = next;') >= 0);
check('图片地址走 http/https 白名单（openExternalLink）',
  renderSrc.indexOf("!url.startsWith('http://') && !url.startsWith('https://')") >= 0);

check('代码块横向可滚动',
  renderSrc.indexOf('.scrollable(ScrollDirection.Horizontal)') >= 0 &&
  renderSrc.indexOf('.scrollBar(BarState.Auto)') >= 0);
check('代码块逐行渲染', renderSrc.indexOf('private codeLines(block: MdBlock): TokenLine[]') >= 0);
check('行号与正文共用同一个 lineHeight',
  renderSrc.indexOf('const CODE_LINE_HEIGHT: number = 19;') >= 0 &&
  renderSrc.indexOf('.lineHeight(CODE_LINE_HEIGHT)') >= 0);
check('代码块显示行数', renderSrc.indexOf('this.codeLines(block).length} 行') >= 0);
check('长行有横滚兜底上限', renderSrc.indexOf('const CODE_LINE_MAX_WIDTH: number = 2000;') >= 0);
check('代码块行数过多时退化渲染', renderSrc.indexOf('const MAX_CODE_LINES: number = 400;') >= 0);
check('空白行用空格占位（行号不错行）', renderSrc.indexOf("line.size > 0 ? this.lineText(line) : ' '") >= 0);

check('数学块走等宽字体',
  renderSrc.indexOf('mathBlock(block)') >= 0 && renderSrc.indexOf("fontFamily('Noto Sans Mono')") >= 0);
check('图片与公式块都进了 build 分派',
  renderSrc.indexOf('MdBlockKind.IMAGE') >= 0 && renderSrc.indexOf('MdBlockKind.MATH') >= 0);
check('行内渲染支持图片/公式 token',
  renderSrc.indexOf('spanText(token)') >= 0 && renderSrc.indexOf('spanLink(token)') >= 0);

// ---------------------------------------------------------------------------

console.log(`\n通过 ${passed} 项，失败 ${failures.length} 项`);
if (failures.length > 0) {
  console.log('\n失败明细：');
  for (const f of failures) {
    console.log(`  ✗ ${f}`);
  }
  process.exit(1);
}
console.log('Markdown 专项断言全部通过。');

