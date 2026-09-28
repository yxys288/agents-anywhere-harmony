#!/usr/bin/env node
/**
 * aa-hm 文件页「搜索 / 过滤 / 复制载荷」纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 被测模块：`model/FileSearch.ets`（第十一轮新增）。它对应上游三处：
 *  ① `SessionAgentFilesScreen.kt` 的 `FileActionMenu` / `PreviewCardHeader`（复制路径 / 复制代码）；
 *  ② 同文件 `InlineFileSearchControls` + `CodeBlockPreview.kt` 的 `SoraFileSearchResult` /
 *     `SoraFileSearchController`（**文件内容**搜索：当前/总数 + 循环跳转）；
 *  ③ 文件**名**过滤（上游 `FilesScreen.kt` 没有这一项，是本工程既有能力，本轮抽成纯函数并定死语义）。
 *
 * 转译方式照抄 tools/logic-test/run-tests.mjs（DevEco 自带 TypeScript -> CommonJS，产物落系统临时目录）。
 * `model/FileSearch.ets` 只 import `./Types`，而 `Types.ets` 零依赖 —— 两个文件一起转译即可 require 到。
 *
 * 用法：
 *   node tools\logic-test\suite-files.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-files');
const FILES_SCREEN = path.join(SRC_ETS, 'ui', 'screens', 'FilesScreen.ets');
const FILE_SEARCH = path.join(SRC_ETS, 'model', 'FileSearch.ets');
const FILES_STORE = path.join(SRC_ETS, 'feature', 'FilesStore.ets');

/** 只挑不 import @kit / ArkUI 的模块。 */
// FileSearch 依赖 DirBrowse（HOME_ROOT）/ Types；DirBrowse 又依赖 RemotePaths —— 四个一起转译。
const LOGIC_FILES = ['model/Types.ets', 'model/AppModels.ets', 'model/RemotePaths.ets', 'model/DirBrowse.ets', 'model/FileSearch.ets'];

/** 反斜杠用码点拼，免得这个脚本自己被转义坑到。 */
const BS = String.fromCharCode(92);
const NL = String.fromCharCode(10);
const CR = String.fromCharCode(13);

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
  console.log('');
  console.log('== ' + title);
}

build();

const require = createRequire(import.meta.url);
const f = require(path.join(OUT_DIR, 'model/FileSearch.js'));
// 源码文本提前读出来：文案逐字对照组（第 5 节）要用到页面的字面量。
const screenText2 = fs.readFileSync(FILES_SCREEN, 'utf8');
const dir = require(path.join(OUT_DIR, 'model/DirBrowse.js'));

// ---------------------------------------------------------------------------
// 1. 归一化（大小写 / 分隔符）
// ---------------------------------------------------------------------------

group('查询串归一化（大小写不敏感 + 路径分隔符差异）');
eq('反斜杠归一成正斜杠 + 转小写', f.normalizeSearchText('Src' + BS + 'A.TS'), 'src/a.ts');
eq('去首尾空白', f.normalizeSearchText('  app.ets  '), 'app.ets');
eq('粘贴路径的 ./ 前缀被剥掉', f.normalizeQuery('  ./SRC' + BS + 'a.ts '), 'src/a.ts');
eq('重复的 ./ 前缀都被剥掉', f.normalizeQuery('././x'), 'x');
eq('不含分隔符的查询只是转小写', f.normalizeQuery('Utils'), 'utils');
eq('单个点前缀不动（只剥 ./）', f.normalizeQuery('.env'), '.env');
check('纯空白不算过滤中', f.hasActiveQuery('   ') === false);
check('有关键字算过滤中', f.hasActiveQuery(' a ') === true);
check('空串不算过滤中', f.hasActiveQuery('') === false);

// ---------------------------------------------------------------------------
// 1.6 浏览根归一（第十一轮真机 P0：顶层文件页 `root is required`）
// ---------------------------------------------------------------------------

group('浏览根 / 初始目录归一（D1）');
eq('HOME_ROOT 就是上游的 ~', dir.HOME_ROOT, '~');
eq('空串（首页「文件」卡片不带参数）→ ~', f.effectiveBrowseRoot(''), '~');
eq('纯空白 → ~', f.effectiveBrowseRoot('   '), '~');
eq('设备详情取不到工作区时的 . → ~', f.effectiveBrowseRoot('.'), '~');
eq('显式 ~ 原样保留', f.effectiveBrowseRoot('~'), '~');
eq('绝对路径原样保留（会话 cwd 这一路）',
  f.effectiveBrowseRoot('  /Users/me/code/demo  '), '/Users/me/code/demo');
eq('Windows 盘符路径原样保留', f.effectiveBrowseRoot('C:/Users/me'), 'C:/Users/me');
eq('初始目录空串 → .', f.effectiveInitialPath(''), '.');
eq('初始目录纯空白 → .', f.effectiveInitialPath('   '), '.');
eq('初始目录原样保留', f.effectiveInitialPath(' /a/b '), '/a/b');
eq('顶层入口组合：root=~、path=.（上游 DeviceFilesContent 的首次请求）',
  f.effectiveBrowseRoot('') + '|' + f.effectiveInitialPath(''), '~|.');
eq('工作区根还没解析成绝对路径时，面包屑只显示根一节（不冒出 ~ 这一节）',
  dir.breadcrumbSegments(dir.HOME_ROOT, '.', 'linux', '工作区').length, 1);
eq('未解析根的标签是「工作区」而不是 ~',
  dir.breadcrumbSegments(dir.HOME_ROOT, '.', 'linux', '工作区')[0].label, '工作区');
eq('根解析成绝对路径后按相对段切片',
  dir.breadcrumbSegments('/Users/me/code/demo', '/Users/me/code/demo/src', 'linux', '工作区')
    .map((c) => c.label).join('|'), 'demo|src');

// ---------------------------------------------------------------------------
// 2. 文件名过滤
// ---------------------------------------------------------------------------

group('单条命中判定 matchesEntry');
check('大小写不敏感（小写查大写名）', f.matchesEntry('App.ets', 'src/App.ets', 'app') === true);
check('大小写不敏感（大写查小写名）', f.matchesEntry('app.ets', 'src/app.ets', 'APP') === true);
check('子串命中（不是前缀限定）', f.matchesEntry('my-component.ets', 'src/my-component.ets', 'comp') === true);
check('不相关关键字不命中', f.matchesEntry('App.ets', 'src/App.ets', 'util') === false);
check('空查询不过滤', f.matchesEntry('App.ets', 'src/App.ets', '   ') === true);
check('查询带分隔符时退一步按归一化路径命中',
  f.matchesEntry('App.ets', 'src/App.ets', 'src' + BS + 'app.ets') === true);
check('路径用反斜杠、查询用斜杠也命中（分隔符差异）',
  f.matchesEntry('b.txt', 'a' + BS + 'b.txt', 'a/b.txt') === true);
check('目录同样参与命中', f.matchesEntry('utils', 'src/utils', 'UTIL') === true);
check('路径命中只在查询含分隔符时生效（防误命中）',
  f.matchesEntry('b.txt', 'dir/other/b.txt', 'other/b') === true);

group('列表过滤 filterEntries');
const entries = [
  { name: 'src', path: 'proj/src', type: 'directory' },
  { name: 'App.ets', path: 'proj/App.ets', type: 'file', size: 120 },
  { name: 'util.ts', path: 'proj/util.ts', type: 'file', size: 30 },
  { name: '.env', path: 'proj/.env', type: 'file', size: 10 }
];
eq('空查询 + 显示点文件 = 全量', f.filterEntries(entries, '', true).length, 4);
eq('空查询 + 隐藏点文件 = 去掉 .env', f.filterEntries(entries, '', false).length, 3);
eq('纯空白查询等价于不过滤', f.filterEntries(entries, '   ', true).length, 4);
eq('过滤 ts 命中两个', f.filterEntries(entries, 'ts', true).length, 2);
eq('过滤 app 命中一个（大小写不敏感）', f.filterEntries(entries, 'APP', true).length, 1);
eq('命中项就是 App.ets', f.filterEntries(entries, 'app', true)[0].name, 'App.ets');
eq('无命中返回空数组', f.filterEntries(entries, 'zzz', true).length, 0);
eq('隐藏点文件优先于过滤', f.filterEntries(entries, 'env', false).length, 0);
eq('显示点文件时点文件查得到', f.filterEntries(entries, 'env', true).length, 1);
eq('目录也能被过滤命中（type=directory）', f.filterEntries(entries, 'src', true)[0].type, 'directory');
check('过滤结果换新引用（@State 才能刷新）', f.filterEntries(entries, '', true) !== entries);
eq('过滤不改动入参数组长度', entries.length, 4);
eq('过滤不修改入参元素', entries[1].name, 'App.ets');
eq('反斜杠查询也能过滤（proj' + BS + 'App.ets）', f.filterEntries(entries, 'proj' + BS + 'App.ets', true).length, 1);

group('空列表提示与计数');
eq('空目录文案与上游 files_empty_directory 逐字一致', f.filterEmptyHint('', true), '这个目录是空的。');
eq('隐藏点文件时补一句', f.filterEmptyHint('', false), '这个目录是空的。（点文件已隐藏）');
eq('有过滤关键字时回显关键字', f.filterEmptyHint('  zzz  ', true), '没有匹配「zzz」的文件。');
eq('有过滤关键字 + 隐藏点文件', f.filterEmptyHint('zzz', false), '没有匹配「zzz」的文件。（点文件已隐藏）');
eq('计数文案', f.filterCountLabel(3, 12), '3 / 12');
eq('零命中计数文案', f.filterCountLabel(0, 12), '0 / 12');

// ---------------------------------------------------------------------------
// 3. 远程路径显示（复制路径用）
// ---------------------------------------------------------------------------

group('displayRemotePath（复刻上游 RemoteFileNavigation.kt:100-113）');
eq('绝对路径原样返回（复制到的就是完整远程路径）',
  f.displayRemotePath('~/code/demo', '/Users/me/code/demo/src/a.ts'), '/Users/me/code/demo/src/a.ts');
eq('Windows 盘符路径原样返回', f.displayRemotePath('~', 'C:/Users/me/a.ts'), 'C:/Users/me/a.ts');
eq('相对路径与 root 拼接', f.displayRemotePath('/Users/me/code/demo', 'src/a.ts'),
  '/Users/me/code/demo/src/a.ts');
eq('root 尾斜杠被裁掉', f.displayRemotePath('/Users/me/code/demo/', 'src'), '/Users/me/code/demo/src');
// 上游 displayRemotePath：以 / 开头的一律当**绝对路径**原样返回（不拼 root），这是刻意的。
  eq('前导斜杠的路径按绝对路径处理（上游语义）', f.displayRemotePath('/root', '/src/a.ts'), '/src/a.ts');
eq('反斜杠相对路径归一后拼接', f.displayRemotePath('/root', 'src' + BS + 'a.ts'), '/root/src/a.ts');
eq('路径为 . 时回落到 root', f.displayRemotePath('/Users/me', '.'), '/Users/me');
eq('路径为空时回落到 root', f.displayRemotePath('/Users/me', ''), '/Users/me');
eq('root 与路径都空时回落 .', f.displayRemotePath('', ''), '.');
eq('无 root 的相对路径原样返回', f.displayRemotePath('', 'src/a.ts'), 'src/a.ts');
eq('根路径 / 原样返回', f.displayRemotePath('/x', '/'), '/');

// ---------------------------------------------------------------------------
// 4. 文件内容搜索（上游 SoraFileSearchController 的口径）
// ---------------------------------------------------------------------------

group('命中计数 countMatches');
eq('三个单字命中', f.countMatches('aaa', 'a', false), 3);
eq('非重叠计数（aaaa 里 2 个 aa）', f.countMatches('aaaa', 'aa', false), 2);
eq('大小写不敏感命中两次', f.countMatches('AbA', 'a', false), 2);
eq('大小写敏感：只数小写的那一个', f.countMatches('aAa', 'a', true), 2);
eq('大小写敏感：AbA 里没有小写 a', f.countMatches('AbA', 'a', true), 0);
eq('大小写敏感：AbA 里有两个大写 A', f.countMatches('AbA', 'A', true), 2);
eq('空查询 0', f.countMatches('abc', '', false), 0);
eq('纯空白查询 0', f.countMatches('abc', '   ', false), 0);
eq('空内容 0', f.countMatches('', 'a', false), 0);
eq('查询比内容长 0', f.countMatches('ab', 'abc', false), 0);
eq('跨行命中', f.countMatches('a' + NL + 'foo' + NL + 'A', 'a', false), 2);
eq('中文子串命中', f.countMatches('中文中文', '中文', false), 2);

group('命中列表 findMatches（行号 / 列号）');
const content = ['line one', 'const foo = 1;', 'foo(); foo();', 'done'].join(NL);
const hits = f.findMatches(content, 'foo', false, 0);
eq('命中三条', hits.length, 3);
eq('第一条行号 2', hits[0].line, 2);
eq('第一条列号 7', hits[0].column, 7);
eq('第二条行号 3', hits[1].line, 3);
eq('第二条列号 1', hits[1].column, 1);
eq('第三条列号 8', hits[2].column, 8);
eq('序号从 0 连续', hits[0].index + ',' + hits[1].index + ',' + hits[2].index, '0,1,2');
eq('命中行文本', hits[0].text, 'const foo = 1;');
eq('limit 生效', f.findMatches(content, 'foo', false, 2).length, 2);
eq('limit=0 表示不限', f.findMatches(content, 'foo', false, 0).length, 3);
eq('空查询返回空数组', f.findMatches(content, '', false, 0).length, 0);
eq('无命中返回空数组', f.findMatches(content, 'zzz', false, 0).length, 0);
const crlf = f.findMatches('a' + CR + NL + 'foo', 'foo', false, 0);
eq('CRLF 内容里命中行号 2', crlf[0].line, 2);
eq('CRLF 的行文本不带回车符', crlf[0].text, 'foo');
eq('大小写不敏感命中两处', f.findMatches('Foo foo', 'foo', false, 0).length, 2);
eq('大小写敏感只命中一处', f.findMatches('Foo foo', 'foo', true, 0).length, 1);
eq('首行首列命中列号 1', f.findMatches('abc', 'a', false, 0)[0].column, 1);
eq('无换行结尾的内容也能正确定位', f.findMatches('abc', 'c', false, 0)[0].line, 1);

group('长行截断 clipAround');
eq('短行原样返回', f.clipAround('abc', 0, 60), 'abc');
eq('刚好等于上限原样返回', f.clipAround('abcd', 0, 4), 'abcd');
check('超长行被截断', f.clipAround('x'.repeat(200) + 'HIT' + 'y'.repeat(200), 200, 60).length <= 66);
check('截断后仍包含命中', f.clipAround('x'.repeat(200) + 'HIT' + 'y'.repeat(200), 200, 60).includes('HIT'));
check('命中在中间时两端都有省略号',
  f.clipAround('x'.repeat(200) + 'HIT' + 'y'.repeat(200), 200, 60).startsWith('...'));
check('maxChars<=0 时不截断', f.clipAround('abcd', 0, 0) === 'abcd');
check('命中在行首时无头省略号', f.clipAround('HIT' + 'y'.repeat(200), 0, 60).startsWith('HIT') === true);

group('搜索结果归一 searchResultOf（上游 report()）');
eq('总数为 0 时 current=0', f.searchResultOf(0, 0).current, 0);
eq('总数为 0 时 total=0', f.searchResultOf(0, 0).total, 0);
eq('序号 -1 -> 1', f.searchResultOf(-1, 5).current, 1);
eq('序号 0 -> 1', f.searchResultOf(0, 5).current, 1);
eq('序号越界 -> 夹到 total', f.searchResultOf(9, 5).current, 5);
eq('正常序号原样', f.searchResultOf(3, 5).current, 3);
eq('total 原样透传', f.searchResultOf(3, 5).total, 5);

group('循环跳转 stepSearchMatch（上游 setCyclicJumping(true)）');
eq('往下 1 -> 2', f.stepSearchMatch(1, 3, true), 2);
eq('往下末条 -> 回到 1', f.stepSearchMatch(3, 3, true), 1);
eq('往上 2 -> 1', f.stepSearchMatch(2, 3, false), 1);
eq('往上第 1 条 -> 回到末条', f.stepSearchMatch(1, 3, false), 3);
eq('只有一条时往下仍是 1', f.stepSearchMatch(1, 1, true), 1);
eq('只有一条时往上仍是 1', f.stepSearchMatch(1, 1, false), 1);
eq('零命中时保持 0', f.stepSearchMatch(0, 0, true), 0);
eq('序号未初始化时往下取 1', f.stepSearchMatch(0, 4, true), 1);
eq('序号未初始化时往上取末条', f.stepSearchMatch(0, 4, false), 4);

group('计数与空态文案');
eq('计数文案与上游 current/total 同形', f.searchCountLabel(f.searchResultOf(2, 7)), '2/7');
eq('零命中计数文案', f.searchCountLabel(f.searchResultOf(0, 0)), '0/0');
// 零命中**不再另编文案**：上游 `InlineFileSearchControls` 的反馈就是 `0/0` 计数本身，
// 故这里断言「该模块不再导出文案函数」（避免后人又把自创文案加回来）。
check('不再有自创的搜索空态文案函数', f.searchEmptyHint === undefined);

// ---------------------------------------------------------------------------
// 5. 复制载荷
// ---------------------------------------------------------------------------

group('复制代码 codeCopyPayload（上游 copyEnabled = !binary && content 非空白）');
const code = f.codeCopyPayload('const a = 1;', false, false);
check('普通代码可复制', code.enabled === true);
eq('复制的就是预览内容原文（不额外截断）', code.text, 'const a = 1;');
eq('成功提示与上游 files_copied_code 一致', code.hint, '已复制代码');
const bigCode = f.codeCopyPayload('x'.repeat(5000), false, true);
eq('已截断时提示仍逐字是 files_copied_code（不编后缀）', bigCode.hint, '已复制代码');
check('已截断标志随载荷交给 UI（由预览卡片的「已截断」标签呈现）', bigCode.truncated === true);
eq('未截断时标志为 false', code.truncated, false);
eq('已截断也照抄内容（不二次截断）', bigCode.text.length, 5000);
check('二进制文件不可复制', f.codeCopyPayload('binary', true, false).enabled === false);
eq('不可复制时不编文案（上游此时按钮置灰）', f.codeCopyPayload('binary', true, false).hint, '');
check('空内容不可复制', f.codeCopyPayload('', false, false).enabled === false);
check('纯空白内容不可复制', f.codeCopyPayload('   ', false, false).enabled === false);
eq('不可复制时 text 是空串（绝不把空串写进剪贴板）', f.codeCopyPayload('', false, false).text, '');
eq('多行内容整体复制', f.codeCopyPayload('a' + NL + 'b', false, false).text.split(NL).length, 2);

group('复制路径 pathCopyPayload');
const pathPayload = f.pathCopyPayload('/Users/me/code/demo/src/a.ts');
check('路径可复制', pathPayload.enabled === true);
eq('文本就是完整远程路径', pathPayload.text, '/Users/me/code/demo/src/a.ts');
eq('成功提示与上游 files_copied_path 一致', pathPayload.hint, '已复制路径');
eq('首尾空白被裁掉', f.pathCopyPayload('  /a/b  ').text, '/a/b');
check('空路径不可复制', f.pathCopyPayload('').enabled === false);
eq('空路径不编文案', f.pathCopyPayload('   ').hint, '');

group('用户可见文案逐字对照上游 strings.xml');
// 每条都写明 key；值直接抄自 android/app/src/main/res/values-zh-rCN/strings.xml
eq('files_copy_path', f.copyButtonLabel('复制路径', false), '复制路径');
eq('files_copied_path', f.copyButtonLabel('复制路径', true), '已复制路径');
eq('files_copy_code', f.copyButtonLabel('复制代码', false), '复制代码');
eq('files_copied_code', f.copyButtonLabel('复制代码', true), '已复制代码');
eq('复制路径成功提示 = files_copied_path', f.pathCopyPayload('/a/b').hint, '已复制路径');
eq('复制代码成功提示 = files_copied_code', f.codeCopyPayload('x', false, false).hint, '已复制代码');
// R69：该入口按上游改成 `Lucide.Search` 图标钮（`PreviewIconButton`）⇒ 判图标 + 无障碍语义，不再判文案。
check('页面上「搜索文件内容」入口 = files_search_in_file（图标钮形态）',
  screenText2.includes("ICONS['search']") && screenText2.includes('togglePreviewSearch()'));
check('过滤框与内容搜索框的占位 = files_search（搜索）',
  screenText2.includes("placeholder: '搜索'") && screenText2.includes("'搜索文件名'") === false);
// R12-5：字符箭头 ↑/↓ 升级为 Lucide 矢量图标（上游 `SearchStepButton(icon = Lucide.ChevronUp/Down)`）。
check('上/下一条是矢量 Chevron 图标（上游是图标，不是文字）',
  screenText2.includes("iconName: 'chevron-up'") && screenText2.includes("iconName: 'chevron-down'")
  && screenText2.includes("label: '↑'") === false && screenText2.includes("label: '↓'") === false
  && screenText2.includes("'上一个'") === false && screenText2.includes("'下一个'") === false);

group('复制按钮文案（上游 contentDescription 的两个态）');
eq('复制路径', f.copyButtonLabel('复制路径', false), '复制路径');
eq('已复制路径', f.copyButtonLabel('复制路径', true), '已复制路径');
eq('复制代码', f.copyButtonLabel('复制代码', false), '复制代码');
eq('已复制代码', f.copyButtonLabel('复制代码', true), '已复制代码');
eq('闪示时长与上游 delay(1100) 一致', f.COPY_FLASH_MILLIS, 1100);
check('失败提示不为空', f.COPY_PATH_FAILED_HINT.length > 0 && f.COPY_CODE_FAILED_HINT.length > 0);
check('命中列表有上限（防超大文件撑爆 UI）', f.MATCH_LIST_LIMIT > 0);

// ---------------------------------------------------------------------------
// 6. 源码扫描：页面真的接上了这套纯逻辑，且踩坑约束都守住了
// ---------------------------------------------------------------------------

group('FilesScreen.ets 接线与约束检查');
const screenText = fs.readFileSync(FILES_SCREEN, 'utf8');
const screenLines = screenText.split(NL);
/**
 * ⚠️ 判「代码里**没有**某样东西」时必须先把**整行注释剥掉**：R13-20 的删除都在注释里写了
 * 「已删 / 上游没有」并点名了那些符号，直接扫 `screenText` 会被自己的注释判成「还在」。
 * 这类假红本套件已经踩过一次（钉字面量的顺序断言），故「不存在」类断言统一走 `codeText`。
 */
const codeText = screenLines.filter((line) => !/^\s*(\*|\/\/)/.test(line)).join(NL);
const searchText = fs.readFileSync(FILE_SEARCH, 'utf8');

check('FilesScreen 引了纯逻辑模块 FileSearch',
  screenText.includes("from '../../model/FileSearch'"));
// R13-20：本页**不再有**文件名过滤 —— 上游文件列表里没有输入框（锚文见 FilesScreen 的注释块）。
// 这四个纯函数仍留在 model/FileSearch.ets 并被本套件覆盖，只是 `FilesScreen` 不再调用它们。
check('FilesScreen 不再做文件名过滤（上游列表没有输入框）',
  screenText.includes('filterEntries(') === false
  && screenText.includes('filterCountLabel(') === false
  && screenText.includes('filterEmptyHint(') === false
  && screenText.includes('hasActiveQuery(') === false);
check('FilesScreen 不再有「显示点文件」开关（上游无此 key、且零 dotfile 过滤）',
  codeText.includes('显示点文件') === false && codeText.includes('showHidden') === false);
check('目录项原样进列表（不再过滤，与上游 items(directory.entries) 一致）',
  screenText.includes('this.entryList = this.store.entries.slice();'));
check('FilesScreen 不再直接用 store.visibleEntries',
  screenText.includes('visibleEntries(') === false);
check('空目录文案逐字取上游 files_empty_directory',
  screenText.includes("'这个目录是空的。'") && codeText.includes('filterEmptyHint') === false);
check('FilesScreen 复制路径走 pathCopyPayload', screenText.includes('pathCopyPayload('));
check('FilesScreen 复制代码走 codeCopyPayload', screenText.includes('codeCopyPayload('));
check('FilesScreen 内容搜索走 findMatches', screenText.includes('findMatches('));
check('FilesScreen 跳转走 stepSearchMatch', screenText.includes('stepSearchMatch('));
// R69：预览头部按上游 `PreviewCardHeader` 改成图标按钮 ⇒ 不再有文字胶囊，也不再用 `copyButtonLabel`。
// 断言改判**功能入口**：搜索图标 + 点击处理；「复制路径」则回到它在长按行菜单里的入口。
check('FilesScreen 的「搜索」入口仍在（图标按钮 + 点击处理）',
  screenText.includes("ICONS['search']") && screenText.includes('togglePreviewSearch()'));
check('FilesScreen 的「复制路径」入口仍在长按菜单里', screenText.includes("Text('复制路径')"));
check('剪贴板写法与工程既有三处同构',
  screenText.includes("import { pasteboard } from '@kit.BasicServicesKit';"));
// ⚠️ R66 实现修正（**判据原意一字未改**）：标题早就写着「注释里的提及不算」，但实现是**裸 split**，
// 于是 R66 在 FilesScreen 里写的一句解释性注释（说明本页**不能** `import { uiMaterial } from '@kit.ArkUI'`，
// 故改走共享工厂）反而被数成第 2、3 个 Kit ⇒ **注释导致的假红**。
// 先把 `//` 行注释与 `/* */` 块注释剥掉再数，才与该断言自己声明的口径一致。
const filesCodeNoComments = screenText.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
const filesKitImports = filesCodeNoComments.split("from '@kit.").length - 1;
check('只引了 BasicServicesKit 这一个 Kit（数 import 语句，注释里的提及不算）',
  filesKitImports === 1,
  'kit imports = ' + filesKitImports);
check('引的正是 BasicServicesKit', screenText.includes("from '@kit.BasicServicesKit'"));
check('复制失败有可见提示（不静默）',
  screenText.includes('COPY_PATH_FAILED_HINT') && screenText.includes('COPY_CODE_FAILED_HINT'));
// R13-20（3-3）：行内常驻「⧉」已删 —— 上游每行只有 trailing（目录给 ChevronRight），
// 复制路径在长按弹的 FileActionMenu 里（本工程未移植，已写进交付说明交 Lead 裁决）。
check('列表行不再有常驻复制钮（entry.path 不再参与图标两态）',
  codeText.includes('=== entry.path ? ICONS') === false
  && codeText.includes('copyEntryPath(') === false);
check('路径条方块仍保留复制能力（copy / check 两态，矢量图标）',
  screenText.includes("ICONS['copy']") && screenText.includes("ICONS['check']")
  && screenText.includes('PATH_BAR_COPY_KEY'));
check('过滤结果存进 @State 数组（build 只读它）', screenText.includes('@State entryList: RemoteDirectoryEntry[]'));

const matchKeyLine = screenLines.filter((line) => line.includes('match.index') && line.includes('match.line'))[0];
check('命中列表的 ForEach key 存在', matchKeyLine !== undefined);
check('命中列表 key 含会变字段（index/line/column）',
  matchKeyLine !== undefined && matchKeyLine.includes('match.index')
  && matchKeyLine.includes('match.line') && matchKeyLine.includes('match.column'));
check('命中列表 key 不含 @State 标记',
  matchKeyLine !== undefined && matchKeyLine.includes('isCurrentMatch') === false);

const entryKeyLine = screenLines.filter((line) => line.includes('entry.path') && line.includes('entry.type'))[0];
check('文件列表 key 含 entry.path', entryKeyLine !== undefined && entryKeyLine.includes('entry.path'));
check('文件列表 key 含 type（目录/文件切换要刷新）',
  entryKeyLine !== undefined && entryKeyLine.includes('entry.type'));

const storeText = fs.readFileSync(FILES_STORE, 'utf8');
check('FilesScreen 的 root 默认是 HOME_ROOT（不再是 .）',
  screenText.includes('@Prop root: string = HOME_ROOT;'));
check('FilesScreen 不再把 . 当 root 默认值', screenText.includes("@Prop root: string = '.';") === false);
check('FilesScreen 打开时走 effectiveBrowseRoot 归一',
  screenText.includes('effectiveBrowseRoot(this.root)'));
check('FilesScreen 打开时走 effectiveInitialPath 归一',
  screenText.includes('effectiveInitialPath(this.initialPath)'));
check('FilesStore 会把未解析的 ~ 收敛成绝对路径', storeText.includes('private adoptResolvedRoot('));
// R13-3：收敛的入参从「服务端原始 path」换成「canonicalRemoteDirectoryPath 归一后的路径」。
// ⚠️ 这条断言**只判语义顺序、不钉死实参字面量**（曾经的写法钉死 `this.adoptResolvedRoot(directory.path);`，
// 被「换了个实参」而不是「顺序错了」打破，制造过一次假红灯 —— 断言要守住的不变量是**顺序**，不是那一行文本）。
const atAdoptRoot = storeText.indexOf('this.adoptResolvedRoot(');
const atCanonical = storeText.indexOf('canonicalRemoteDirectoryPath(');
const atSortEntries = storeText.indexOf('this.sortEntries(');
check('FilesStore 在算面包屑/条目之前先收敛根（语义顺序，不钉实参）',
  atAdoptRoot > 0 && atSortEntries > 0 && atAdoptRoot < atSortEntries);
check('服务端回话先归一（canonicalRemoteDirectoryPath）再收敛根',
  atCanonical > 0 && atCanonical < atAdoptRoot);
// 新语义：收敛收到的是**归一后的路径**，不是服务端原始 `directory.path`。
check('收敛根拿到的是归一后的路径（不是服务端原始 path）',
  storeText.indexOf('this.adoptResolvedRoot(canonical);') > 0
  && storeText.indexOf('this.adoptResolvedRoot(directory.path);') < 0);
check('FilesStore 用 canonicalRemoteDirectoryPath 归一服务端回话',
  storeText.includes('canonicalRemoteDirectoryPath(request, directory.path, this.deviceOs)'));
check('FilesStore 的请求 (root, path) 走 remoteFileRequest（Windows 才会切盘符根）',
  storeText.includes('remoteFileRequest(path, this.deviceOs, this.root)'));
check('FilesStore 的面包屑把未解析根视为「只显示根一节」',
  storeText.includes("rootNorm === HOME_ROOT"));

// ---------------------------------------------------------------------------
// 6.5 R13-3：Windows 盘符总览（「这台电脑」C:/D:/E:）的接线与形态
// ---------------------------------------------------------------------------

group('R13-3 · Windows 盘符总览接线（FilesScreen / FilesStore）');
check('页面按设备系统分流（deviceOs 来自 AgentDevice.deviceOs）',
  screenText.includes('private selectedDeviceOs()') && screenText.includes('const deviceOs = device.deviceOs;'));
check('Windows 起点走 initialRemoteFilePath（空路径=盘符总览）',
  screenText.includes('initialRemoteFilePath(deviceOs)'));
check('非 Windows 仍走本页既有的 effectiveInitialPath',
  screenText.includes(': effectiveInitialPath(this.initialPath);'));
check('open() 把 deviceOs 一起交给 store',
  screenText.includes('effectiveBrowseRoot(this.root), initialPath, deviceOs)'));
check('store 保存 deviceOs 字段', storeText.includes('deviceOs: string = '));
check('store 的上一级走 browseParentPath（盘符根 → 总览）',
  storeText.includes('browseParentPath(this.currentPath, this.root, this.deviceOs, true)'));
check('store 有盘符总览态判定', storeText.includes('isDriveOverview(): boolean'));
check('盘符总览的面包屑是单独一节「这台电脑」',
  storeText.includes('WINDOWS_DRIVE_OVERVIEW_LABEL, path: '));
check('Windows 面包屑补「这台电脑」一节（可回退）',
  storeText.includes('segments.unshift({ label: WINDOWS_DRIVE_OVERVIEW_LABEL, path: '));
check('Windows 的根按盘符收敛（上游 resolvedRoot = windowsDriveRoot(...)）',
  storeText.includes('const drive = windowsDriveRoot(returnedPath);'));
check('路径显示改用四参 displayRemotePath（能算盘符总览那一态）',
  screenText.includes('this.store.currentPath, this.store.deviceOs, WINDOWS_DRIVE_OVERVIEW_LABEL'));
check('页面不再用两参 displayRemotePath（它算不出盘符总览）',
  screenText.includes('displayRemotePath(this.store.root, entry.path)') === false);
check('路径条取代了原来的裸面包屑行',
  screenText.includes('pathBar()') && screenText.includes('this.pathBar()')
  && screenText.includes('crumbLine') === false);
check('路径条是灰底圆角块（上游 52 高 / 13 圆角 / subtle 底 + 描边）',
  screenText.includes('const PATH_BAR_HEIGHT: number = 52;')
  && screenText.includes('const PATH_BAR_RADIUS: number = 13;')
  && screenText.includes('.backgroundColor(subtle())'));
check('路径条右侧是复制按钮（copy / check 两态，矢量图标）',
  screenText.includes("ICONS['copy']") && screenText.includes('PATH_BAR_COPY_KEY')
  && screenText.includes('private copyCurrentPath()'));
check('面包屑末节后不再补分隔符（总览态与安卓同形）',
  screenText.includes('if (index < this.crumbs.length - 1)'));
check('盘符总览态不再是「工作区 /」（文案来自 DirBrowse 单一事实来源）',
  screenText.includes('WINDOWS_DRIVE_OVERVIEW_LABEL') && dir.WINDOWS_DRIVE_OVERVIEW_LABEL === '这台电脑');
// ---------------------------------------------------------------------------
// 6.6 R13-20：文件页对齐 —— 去掉三处自加入口 + 「这台电脑」左对齐
// ---------------------------------------------------------------------------

group('R13-20 · 文件页对齐（3-1 上一级 / 3-2 搜索+点文件 / 3-3 行内复制 / 3-4 左对齐）');

// 3-1：上游的「上一级」是**列表首项的 `..` 行**（SessionAgentFilesScreen.kt:920-942），
// 不是顶栏常驻按钮 —— 所以这条不是「删能力」，是**换成上游形态**。
check('3-1 顶栏不再有常驻「上一级」按钮', screenText.includes("label: '上一级'") === false);
check('3-1 上一级改走上游的 `..` 行（列表首项、仅在有上一级时画）',
  screenText.includes('parentRow()') && screenText.includes('if (this.hasParent)')
  && screenText.includes("Text('..')"));
check('3-1 `..` 行的目标来自 store.parentPath()',
  screenText.includes('this.store.parentPath()')
  && screenText.includes('this.store.navigate(this.parentPath)')
  && storeText.includes('parentPath(): string | undefined'));
check('3-1 空串（= 盘符总览）与 undefined（= 没有上一级）**分开存**',
  screenText.includes('@State hasParent: boolean = false;')
  && screenText.includes('@State parentPath: string ='));
check('3-1 store.parentPath 复用 browseParentPath（盘符边界语义不变）',
  storeText.includes('return browseParentPath(this.currentPath, this.root, this.deviceOs, true);'));

// 3-2：上游文件列表里没有搜索框、也没有「显示点文件」（锚文见 FilesScreen 的注释块）。
check('3-2 列表上方的搜索输入框已删（全页只剩预览面板那一个）',
  screenText.split('TextInput(').length - 1 === 1);
// R69：预览面板的头部按上游 `PreviewCardHeader`（`:1161-1214`）改成了**两个图标按钮**（搜索 / 复制），
// 文字胶囊「在文件中搜索」不再存在 —— 断言改为判**功能入口仍在**（图标 + 点击处理），而不是判那句文案。
check('3-2 预览面板的「搜索」入口保留（上游 files_search_in_file → Lucide.Search 图标钮）',
  screenText.includes("ICONS['search']") && screenText.includes('togglePreviewSearch()'));

// 3-3：上游每行只有 trailing（目录给 ChevronRight），复制路径在长按菜单里。
check('3-3 行内常驻复制钮已删（copyEntryPath 不再存在）',
  codeText.includes('copyEntryPath(') === false);
check('3-3 路径条方块的复制能力**未被殃及**（Lead 明确要求保留）',
  screenText.includes('private copyCurrentPath()') && screenText.includes('PATH_BAR_COPY_KEY')
  && screenText.includes("ICONS['copy']"));

// 3-4：上游 PathBar 左块是 Box(contentAlignment = Alignment.CenterStart)（:1525-1544）。
check('3-4 路径条左对齐：去掉了会居中的 Scroll（上游也没有滚动）',
  screenText.includes('ScrollDirection') === false
  && screenText.includes('justifyContent(FlexAlign.Start)'));
check('3-4 左对齐的上游锚文（Alignment.CenterStart）已写进注释',
  screenText.includes('Alignment.CenterStart'));

// 三条删除都必须在源码注释里留下上游锚文，便于下一轮复核。
check('三处删除都留了上游锚文（FilesHeader / Lucide.Search / FileActionMenu）',
  screenText.includes('FilesScreen.kt:129-195')
  && screenText.includes('files_search_in_file')
  && screenText.includes('FileActionMenu'));

// 目录不隐藏点文件：与上游 items(directory.entries) 一致。
check('列表不再隐藏点文件（showHidden 不再被读）',
  codeText.includes('showHidden') === false);

// ---------------------------------------------------------------------------
// 6.7 R13-23：行长按菜单（移植上游 `FileActionMenu`）
// ---------------------------------------------------------------------------

group('R13-23 · 行长按菜单（上游 FileActionMenu）');

check('菜单卡片按上游 FileActionMenu 的尺寸与构件',
  screenText.includes('const FILE_MENU_WIDTH: number = 188;')
  && screenText.includes('const FILE_MENU_HEIGHT: number = 54;')
  && screenText.includes('const FILE_MENU_RADIUS: number = 16;')
  && screenText.includes('const FILE_MENU_ICON_BOX: number = 32;')
  && screenText.includes('const FILE_MENU_ICON_SIZE: number = 17;'));
check('菜单项文案逐字取上游 files_copy_path', screenText.includes("Text('复制路径')"));
check('菜单项图标是矢量 Lucide.Copy',
  screenText.includes("AaIcon({ d: ICONS['copy'], iconSize: FILE_MENU_ICON_SIZE"));
check('菜单只有一项（上游 FileActionMenu 也只有一项，不按类型/可写性增减）',
  screenText.split("Text('复制路径')").length - 1 === 1);

check('弹窗用 bindPopup + 每行一个锚点',
  screenText.includes('.bindPopup(this.menuRowKey === entry.path, this.rowMenuPopupOptions())'));
check('`..` 行也有同一个菜单（上游 :926-941 的 FolderRow(name = "..") 同样传了 onOpenMenu）',
  screenText.includes('.bindPopup(this.menuRowKey === PARENT_ROW_KEY, this.rowMenuPopupOptions())'));
check('弹窗参数与首页/设备页同一套（placement / autoCancel / onStateChange 回落）',
  screenText.includes('private rowMenuPopupOptions(): CustomPopupOptions')
  && screenText.includes('placement: Placement.BottomLeft')
  && screenText.includes('autoCancel: true')
  && screenText.includes('if (!e.isVisible) {'));
check('弹窗**无遮罩**（F-5：上游 Compose Popup 默认无 scrim）',
  screenText.includes('mask: { color: Color.Transparent }'));
check('锚点水平偏移取上游 menuOffset 的 x（54dp）',
  screenText.includes('const FILE_MENU_OFFSET_X: number = 54;')
  && screenText.includes('offset: { x: FILE_MENU_OFFSET_X, y: 0 }'));

// 走 `codeText`：注释里也点了这个符号名（同 R13-20 那次假红的教训）。
check('长按用 LongPressGesture，且正好两处（entryRow + parentRow）',
  codeText.split('LongPressGesture()').length - 1 === 2);
check('长按**不吃掉单击**：行的 .onClick 仍在、可达目录/预览',
  screenText.includes('this.store.navigate(entry.path);')
  && screenText.includes('this.store.openPreview(entry.path);'));
check('单击时先关菜单（上游 :1677 的 onDismissMenu）',
  screenText.indexOf('this.closeRowMenu();') > 0);

check('复制路径的目标值走 displayRemotePath 四参版（与上游 copyPath 同源）',
  screenText.includes('private entryCopyPath(rawPath: string): string')
  && screenText.includes('this.store.root, rawPath, this.store.deviceOs, WINDOWS_DRIVE_OVERVIEW_LABEL'));

// 断言限定在 `copyMenuPath()` 这一段的源码里（锚文是函数名，不钉行号）。
const copyMenuFrom = screenText.indexOf('private copyMenuPath()');
const copyMenuTo = screenText.indexOf('private rowMenuPopupOptions()', copyMenuFrom);
const copyMenuText = copyMenuFrom >= 0 && copyMenuTo > copyMenuFrom
  ? screenText.substring(copyMenuFrom, copyMenuTo)
  : '';
check('copyMenuPath() 片段可定位', copyMenuText.length > 0);
check('复制走既有的 pathCopyPayload',
  copyMenuText.includes('pathCopyPayload(this.menuCopyPath)'));
check('复制前先关菜单（上游 onCopyPath 里 onDismissMenu）',
  copyMenuText.indexOf('this.closeRowMenu();') > 0
  && copyMenuText.indexOf('this.closeRowMenu();') < copyMenuText.indexOf('this.writeClipboard('));
check('复制失败有可见反馈（差异·平台必需新增）',
  copyMenuText.includes('COPY_PATH_FAILED_HINT'));
check('菜单 key 用行身份而不是路径（`..` 的目标路径可能是空串）',
  screenText.includes("const PARENT_ROW_KEY: string = '..';")
  && screenText.includes('@State menuRowKey: string'));

check('FileSearch.ets 零 Kit 依赖', searchText.split("from '@kit.").length - 1 === 0);
check('FileSearch.ets 不用 any', /(^|[^A-Za-z0-9_$])any([^A-Za-z0-9_$]|$)/.test(searchText) === false);
check('FilesScreen.ets 不用 any', /(^|[^A-Za-z0-9_$])any([^A-Za-z0-9_$]|$)/.test(
  screenLines.filter((line) => !/^\s*(\*|\/\/)/.test(line)).join(NL)) === false);
check('FilesScreen.ets 不读剪贴板（只写）', screenText.includes('getData()') === false);

// ---------------------------------------------------------------------------
// 14. 列表行的**底色**（第二十轮：并排图 04-files-drives 揪出的复刻偏差）
// ---------------------------------------------------------------------------
// 上游 `FileListRow`（`SessionAgentFilesScreen.kt:1652-1672`）的底色是
// `pressedSurface.copy(alpha = surfaceAlpha)`，而 `surfaceAlpha = if (active) 1f else 0f`
// —— 静止态**完全透明**；本工程原来是常驻 `raisedSurface()`（深色下每行都是一张灰卡）。
// 断言钉在**函数体片段**上（锚文是函数名 `entryRow` / `parentRow`，不钉行号）。

group('列表行底色：静止透明 + 按下才着色（上游 FileListRow）');
// ⚠️ 锚文用**真实签名**：两个 builder 都是 `@Builder`，方法上**没有** `private` 修饰符
//（第一版写了 `private entryRow(...)`，5 条断言全红 —— 断言自己写错比测试没覆盖更浪费）。
const ENTRY_ANCHOR = 'entryRow(entry: RemoteDirectoryEntry)';
const PARENT_ANCHOR = 'parentRow() {';
const BROWSER_ANCHOR = 'fileBrowser() {';
check('两个行 builder 的锚文都在源码里',
  screenText.includes(ENTRY_ANCHOR) && screenText.includes(PARENT_ANCHOR));

function rowBody(from, to) {
  const a = codeText.indexOf(from);
  if (a < 0) { return ''; }
  const b = codeText.indexOf(to, a + from.length);
  return b > a ? codeText.substring(a, b) : codeText.substring(a);
}
const entryBody = rowBody(ENTRY_ANCHOR, BROWSER_ANCHOR);
const parentBody = rowBody(PARENT_ANCHOR, ENTRY_ANCHOR);
check('两个行 builder 的片段都能定位', entryBody.length > 200 && parentBody.length > 200);
check('entryRow 不再有常驻 raisedSurface 底色',
  entryBody.includes('.backgroundColor(raisedSurface())') === false);
check('parentRow 不再有常驻 raisedSurface 底色',
  parentBody.includes('.backgroundColor(raisedSurface())') === false);
check('entryRow 静止态透明 + 按下态取 rowPressedSurface',
  entryBody.includes('normal: { .backgroundColor(Color.Transparent) }')
  && entryBody.includes('pressed: { .backgroundColor(rowPressedSurface()) }'));
check('parentRow 静止态透明 + 按下态取 rowPressedSurface',
  parentBody.includes('normal: { .backgroundColor(Color.Transparent) }')
  && parentBody.includes('pressed: { .backgroundColor(rowPressedSurface()) }'));
check('行底色只在 stateStyles 里出现（没有第二处常驻底色）',
  (entryBody.split('backgroundColor').length - 1) === 2
  && (parentBody.split('backgroundColor').length - 1) === 2);

const designText = fs.readFileSync(path.join(SRC_ETS, 'ui', 'Design.ets'), 'utf8');
check('Design.ets 导出 rowPressedSurface()',
  designText.includes('export function rowPressedSurface(): Resource'));
const colorBase = fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'element', 'color.json'), 'utf8');
const colorDark = fs.readFileSync(path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'dark', 'element', 'color.json'), 'utf8');
check('浅色 row_pressed_surface = #EDEBE6（上游 Color(0xFFEDEBE6) 逐字）',
  colorBase.includes('"name": "row_pressed_surface", "value": "#EDEBE6"'));
check('深色 row_pressed_surface = #292929（上游 colors.subtle）',
  colorDark.includes('"name": "row_pressed_surface", "value": "#292929"'));
check('深浅两侧 key 成对（row_pressed_surface 两边都在）',
  colorBase.includes('row_pressed_surface') && colorDark.includes('row_pressed_surface'));

// ---------------------------------------------------------------------------
// R26：文件列表行必须与上游 `FileListRow` 的几何一致
// ---------------------------------------------------------------------------
// 上游锚文：`SessionAgentFilesScreen.kt:1665-1715` 的 `FileListRow`
//   `Row.fillMaxWidth().height(60.dp)` + `padding(horizontal = 10.dp)` + `spacedBy(12.dp)`
//   图标槽 `Box.size(40.dp)`（圆角 12）+ `Icon.size(22.dp)`；文案 15.sp / lineHeight 20.sp / SemiBold
//   `FolderRow` 的 trailing = `Lucide.ChevronRight` 20dp（`:1595-1602`）、`FileRow` 的 trailing = null（`:1626`）
//   列表容器 `FileListContent`（`:896-913`）：`padding(start/end = 16.dp)` + `LazyColumn.spacedBy(1.dp)`
// ⚠️ R26 修前实测（模拟器 dpr 3.5）：行高 44dp / 行距 48dp / 图标 15.1dp / 列表左 12dp —— 四样全不符。
const filesSrcR26 = fs.readFileSync(path.join(SRC_ETS, 'ui', 'screens', 'FilesScreen.ets'), 'utf8');

group('R26：文件行几何 = 上游 FileListRow');
check('行高常量 = 60（上游 height(60.dp)）', filesSrcR26.includes('const FILE_ROW_HEIGHT: number = 60;'));
check('行内左右内边距 = 10（上游 padding(horizontal = 10.dp)）',
  filesSrcR26.includes('const FILE_ROW_PAD_H: number = 10;'));
check('图标槽 = 40（上游 Box.size(40.dp)）', filesSrcR26.includes('const FILE_ROW_ICON_BOX: number = 40;'));
check('行间距 = 1（上游 LazyColumn spacedBy(1.dp)）', filesSrcR26.includes('const FILE_ROW_GAP: number = 1;'));
check('两处行（parentRow / entryRow）都套用行高与左右内边距',
  (filesSrcR26.match(/\.height\(FILE_ROW_HEIGHT\)/g) || []).length >= 2
  && (filesSrcR26.match(/\.padding\(\{ left: FILE_ROW_PAD_H, right: FILE_ROW_PAD_H \}\)/g) || []).length >= 2);
check('22dp 图标装在 40dp 槽里（两处行）',
  (filesSrcR26.match(/iconSize: 22,/g) || []).length >= 2
  && (filesSrcR26.match(/\.width\(FILE_ROW_ICON_BOX\)/g) || []).length >= 2);
check('列表行间距用 FILE_ROW_GAP（不再是 4dp 的 Space.XS）',
  filesSrcR26.includes('List({ space: FILE_ROW_GAP })') && filesSrcR26.includes('List({ space: Space.XS })') === false);
check('列表左右内边距 16dp（上游 Column padding start/end = 16.dp）',
  filesSrcR26.includes('.padding({ left: Space.L, right: Space.L, bottom: Space.L })'));
check('**没有**文件大小副标题（上游 FileRow 不渲染 size）', filesSrcR26.includes('formatBytes(') === false);

group('R26：文件行的三个颜色 = 上游字面值');
check('浅色图标 = #2F302D', colorBase.includes('"name": "files_row_icon", "value": "#2F302D"'));
check('深色图标 = #A1A1AA', colorDark.includes('"name": "files_row_icon", "value": "#A1A1AA"'));
check('浅色文案 = #242521', colorBase.includes('"name": "files_row_text", "value": "#242521"'));
check('深色文案 = #FAFAFA', colorDark.includes('"name": "files_row_text", "value": "#FAFAFA"'));
check('浅色 › = #A8A6A0', colorBase.includes('"name": "files_row_chevron", "value": "#A8A6A0"'));
check('深色 › = #71717A', colorDark.includes('"name": "files_row_chevron", "value": "#71717A"'));
check('两处行都用这三个色（而不是 ink / muted）',
  filesSrcR26.includes('color: filesRowIcon()') && filesSrcR26.includes('.fontColor(filesRowText())')
  && filesSrcR26.includes('color: filesRowChevron()'));

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-files: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-files: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ✗ ' + item);
}
process.exit(1);
