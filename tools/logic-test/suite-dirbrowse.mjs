#!/usr/bin/env node
/**
 * aa-hm 新建会话 / 新建项目的**远程目录浏览**纯逻辑自测（不依赖 ArkUI / 设备）。
 *
 * 覆盖 `model/DirBrowse.ets`（第十一轮 W3 / B5 交付物）：
 *  ① 路径形态归一（normalizeRemotePath / isAbsoluteRemotePath / 盘符根）；
 *  ② fs/list 请求拆分（remoteFileRequest）；
 *  ③ 服务端回话归一（canonicalRemoteDirectoryPath）；
 *  ④ 「当前目录能不能选」（isSelectableRemoteDirectory / 盘符总览）；
 *  ⑤ 「上一级」（remoteParentPath posix / windows）与**越界收敛**（browseParentPath，复用 RemotePaths）；
 *  ⑥ 路径显示与面包屑切片（displayRemotePath / rootLabel / breadcrumbSegments）；
 *  ⑦ 目录项只留目录 + 按名排序（对应上游 listNewSessionDirectory）；
 *  ⑧ 项目路径键与目录名（workspacePathKey / workspaceProjectName）。
 *
 * 每一条都对应上游 Android 的锚文（见 DirBrowse.ets 顶部注释）；换行写死 windows 期望值，
 * 因为宿主没有 Windows Connector，「上一级到盘符根」这类分支在设备上跑不出来。
 *
 * 用法：
 *   node projects\aa-hm\tools\logic-test\suite-dirbrowse.mjs
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
const OUT_DIR = path.join(tempDir(), 'aa-hm-logic-dirbrowse');

/** DirBrowse 依赖 Types（目录项类型）与 RemotePaths（越界判定），三个都要转译。 */
const LOGIC_FILES = ['model/Types.ets', 'model/AppModels.ets', 'model/RemotePaths.ets', 'model/DirBrowse.ets'];

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
const dir = require(path.join(OUT_DIR, 'model/DirBrowse.js'));
const remotePaths = require(path.join(OUT_DIR, 'model/RemotePaths.js'));

/** 反斜杠：写成 String.fromCharCode(92) 以免本文件自身的转义看不清。 */
const BS = String.fromCharCode(92);
const WIN_USERS = 'C:' + BS + 'Users';

// ---------------------------------------------------------------------------
// 1. 路径形态归一
// ---------------------------------------------------------------------------

group('路径形态归一（normalizeRemotePath / isAbsoluteRemotePath）');
eq('去掉盘符前的假目录段', dir.normalizeRemotePath('/C:/Users'), 'C:/Users');
eq('已是盘符形态则原样', dir.normalizeRemotePath('C:/Users'), 'C:/Users');
eq('posix 绝对路径不受影响', dir.normalizeRemotePath('/home/u'), '/home/u');
eq('单字母盘符也归一', dir.normalizeRemotePath('/d:/work'), 'd:/work');
eq('反斜杠盘符形态也归一', dir.normalizeRemotePath('/C:' + BS + 'Users'), 'C:' + BS + 'Users');
eq('普通相对路径不动', dir.normalizeRemotePath('src/deep'), 'src/deep');
eq('空串不动', dir.normalizeRemotePath(''), '');
check('posix 绝对路径判为绝对', dir.isAbsoluteRemotePath('/home/u') === true);
check('盘符路径判为绝对', dir.isAbsoluteRemotePath('C:/Users') === true);
check('相对路径判为非绝对', dir.isAbsoluteRemotePath('src/deep') === false);
check('点目录判为非绝对', dir.isAbsoluteRemotePath('.') === false);
// R14：盘符**裸根**（不带分隔符）必须算绝对路径 —— `breadcrumbSegments` 拿到的浏览根
// 经 trimTrailingSlash 后正是 `C:` 这个形态；判成「非绝对」会让面包屑退化成只剩一节。
check('盘符裸根判为绝对', dir.isAbsoluteRemotePath('C:') === true);
check('小写盘符裸根判为绝对', dir.isAbsoluteRemotePath('d:') === true);
check('盘符+反斜杠判为绝对', dir.isAbsoluteRemotePath('C:' + BS) === true);
check('windows 设备系统判定', dir.isWindowsDeviceOs('windows') === true && dir.isWindowsDeviceOs('Windows') === true);
check('linux 设备系统判定', dir.isWindowsDeviceOs('linux') === false && dir.isWindowsDeviceOs('') === false);

// ---------------------------------------------------------------------------
// 2. fs/list 请求拆分
// ---------------------------------------------------------------------------

group('fs/list 请求拆分（remoteFileRequest）');
const posixRequest = dir.remoteFileRequest('/home/u/code', 'linux', '/home/u');
eq('posix 根沿用兜底根', posixRequest.root, '/home/u');
eq('posix 目标路径原样传入', posixRequest.path, '/home/u/code');
eq('兜底根为空时退化成 ~', dir.remoteFileRequest('.', 'linux', '').root, '~');
eq('空目标路径退化成 .', dir.remoteFileRequest('', 'linux', '/home/u').path, '.');
eq('盘符路径把根切到盘符', dir.remoteFileRequest('C:/Users/me', 'windows', '~').root, 'C:' + BS);
eq('盘符路径的 path 保留', dir.remoteFileRequest('C:/Users/me', 'windows', '~').path, 'C:/Users/me');
eq('windows 下空路径 = 盘符总览', dir.remoteFileRequest('', 'windows', '~').path, '');
eq('windows 下空路径的根沿用兜底', dir.remoteFileRequest('', 'windows', '~').root, '~');
eq('windows 下相对路径不切盘符根', dir.remoteFileRequest('src', 'windows', 'C:' + BS).root, 'C:' + BS);
eq('windowsDriveRoot 归一', dir.windowsDriveRoot('/C:/x'), 'C:' + BS);
eq('windowsDriveRoot 对非盘符返回 undefined', dir.windowsDriveRoot('/home/u'), undefined);

// ---------------------------------------------------------------------------
// 2.5 浏览起始路径（R13-3：Windows 起点是盘符总览，不是 .）
// ---------------------------------------------------------------------------

group('浏览起始路径（initialRemoteFilePath，上游 RemoteFileNavigation.kt:12-14）');
eq('Windows 起点是空串 = 盘符总览', dir.initialRemoteFilePath('windows'), '');
eq('Windows 大小写不敏感', dir.initialRemoteFilePath('Windows'), '');
eq('macOS 起点是 .', dir.initialRemoteFilePath('macos'), '.');
eq('linux 起点是 .', dir.initialRemoteFilePath('linux'), '.');
eq('设备系统未知（空串）也按 posix 走 .', dir.initialRemoteFilePath(''), '.');
const winStart = dir.remoteFileRequest(dir.initialRemoteFilePath('windows'), 'windows', '~');
eq('Windows 首次请求的 root 沿用兜底根（上游 resolvedRoot ?: ~）', winStart.root, '~');
eq('Windows 首次请求的 path 为空（服务端据此回 C:/D:/E: 盘符表）', winStart.path, '');
check('Windows 首次请求落在盘符总览态', dir.isWindowsDriveOverview(winStart.path, 'windows') === true);
eq('非 Windows 首次请求的 path 是 .', dir.remoteFileRequest(dir.initialRemoteFilePath('linux'), 'linux', '~').path, '.');

// ---------------------------------------------------------------------------
// 3. 服务端回话归一
// ---------------------------------------------------------------------------

group('服务端回话归一（canonicalRemoteDirectoryPath）');
const reqAbs = { root: '/home/u', path: '/home/u/code' };
eq('服务端回 . 时用请求路径', dir.canonicalRemoteDirectoryPath(reqAbs, '.', 'linux'), '/home/u/code');
eq('服务端回空串时用请求路径', dir.canonicalRemoteDirectoryPath(reqAbs, '', 'linux'), '/home/u/code');
eq('服务端回绝对路径时原样', dir.canonicalRemoteDirectoryPath(reqAbs, '/home/u/code/src/', 'linux'), '/home/u/code/src/');
eq('请求 . 时用服务端回的绝对路径', dir.canonicalRemoteDirectoryPath({ root: '~', path: '.' }, '/home/u', 'linux'), '/home/u');
eq('请求 / 时固定为 /', dir.canonicalRemoteDirectoryPath({ root: '/', path: '/' }, '.', 'linux'), '/');
eq('请求 . 且服务端回 . 时仍是 .', dir.canonicalRemoteDirectoryPath({ root: '~', path: '.' }, '.', 'linux'), '.');
eq('windows 盘符根规范成反斜杠结尾',
  dir.canonicalRemoteDirectoryPath({ root: 'C:' + BS, path: 'C:' }, '.', 'windows'), 'C:' + BS);
eq('windows 下请求空路径（盘符总览）仍是空串',
  dir.canonicalRemoteDirectoryPath({ root: '~', path: '' }, 'C:' + BS, 'windows'), '');
eq('windows 下把正斜杠换成反斜杠',
  dir.canonicalRemoteDirectoryPath({ root: 'C:' + BS, path: 'C:/Users' }, '.', 'windows'), WIN_USERS);

// ---------------------------------------------------------------------------
// 4. 当前目录能不能选
// ---------------------------------------------------------------------------

group('当前目录可选择性（isSelectableRemoteDirectory）');
check('普通目录可选', dir.isSelectableRemoteDirectory('/home/u', 'linux') === true);
check('点目录可选（posix 语义）', dir.isSelectableRemoteDirectory('.', 'linux') === true);
check('空路径不可选', dir.isSelectableRemoteDirectory('', 'linux') === false);
check('windows 盘符总览不可选', dir.isSelectableRemoteDirectory('', 'windows') === false);
check('windows 盘符根可选', dir.isSelectableRemoteDirectory('C:' + BS, 'windows') === true);
check('盘符总览判定（windows）', dir.isWindowsDriveOverview('', 'windows') === true);
check('盘符总览判定不影响 linux', dir.isWindowsDriveOverview('', 'linux') === false);

// ---------------------------------------------------------------------------
// 5. 上一级
// ---------------------------------------------------------------------------

group('上一级（remoteParentPath）');
eq('posix 子目录上一级', dir.remoteParentPath('/home/u/code', 'linux', true), '/home/u');
eq('posix 根目录没有上一级', dir.remoteParentPath('/', 'linux', true), undefined);
eq('主目录哨兵没有上一级', dir.remoteParentPath('~', 'linux', true), undefined);
eq('单段相对路径没有上级（上游返回 .）', dir.remoteParentPath('src', 'linux', true), '.');
eq('相对子路径上一级', dir.remoteParentPath('src/deep', 'linux', true), 'src');
eq('windows 子目录上一级', dir.remoteParentPath('C:/Users/me', 'windows', true), WIN_USERS);
eq('windows 盘符根上一级 = 盘符总览', dir.remoteParentPath('C:', 'windows', true), '');
eq('不允许总览时盘符根没有上一级', dir.remoteParentPath('C:', 'windows', false), undefined);
eq('windows 二级目录上一级是盘符根', dir.remoteParentPath('C:/Users', 'windows', true), 'C:' + BS);

group('上一级的越界收敛（browseParentPath · 复用 RemotePaths）');
eq('根内上跳正常', dir.browseParentPath('/home/u/code', '/home/u', 'linux', true), '/home/u');
eq('在浏览根上再往上跳收敛成 .（不跑出根）',
  dir.browseParentPath('/home/u', '/home/u', 'linux', true), '.');
eq('根为 . 时不收敛（沿用父级语义）', dir.browseParentPath('src/deep', '.', 'linux', true), 'src');
eq('根是 ~ 且路径是绝对时收敛成 .',
  dir.browseParentPath('/home/u', '~', 'linux', true), '.');
// 交叉断言：收敛判据必须与 RemotePaths 完全一致（两处一旦漂移，就会出现「点上一级跑到 /etc」）
const escapeTarget = '/etc';
check('越界判据与 RemotePaths.isOutsideRoot 一致（越界）',
  (remotePaths.isOutsideRoot('/home/u', escapeTarget) === true)
    && dir.browseParentPath('/home/u/code', '/home/u', 'linux', true) === '/home/u');
check('越界判据与 RemotePaths.isOutsideRoot 一致（不越界）',
  (remotePaths.isOutsideRoot('/home/u', '/home/u/code') === false));
eq('未知根的父级仍按形态给出', dir.browseParentPath('src/deep', '~', 'linux', true), 'src');

// R13-3：Windows 分支必须在越界收敛**之前**短路。
// 反例（未短路时的真实结果）：isOutsideRoot(root="C:/", parent="") 为 true，
// 于是「回到这台电脑」被错收敛成 "."，点上一级变成再列一次 C: 根、总览永远回不去。
group('上一级 · Windows 盘符边界（R13-3 回归位）');
eq('盘符根上一级 = 盘符总览（空路径）', dir.browseParentPath('C:' + BS, 'C:' + BS, 'windows', true), '');
eq('盘符总览态没有上一级', dir.browseParentPath('', 'C:' + BS, 'windows', true), undefined);
eq('二级目录上一级是盘符根', dir.browseParentPath(WIN_USERS, 'C:' + BS, 'windows', true), 'C:' + BS);
eq('三级目录上一级', dir.browseParentPath('C:' + BS + 'Users' + BS + 'me', 'C:' + BS, 'windows', true), WIN_USERS);
eq('正斜杠形态同样成立', dir.browseParentPath('C:/Users', 'C:/', 'windows', true), 'C:' + BS);
check('盘符根上一级**不是** .（越界收敛必须被跳过）',
  dir.browseParentPath('C:' + BS, 'C:' + BS, 'windows', true) !== '.');
check('交叉断言：isOutsideRoot 确实会把它判成越界（所以必须短路）',
  remotePaths.isOutsideRoot('C:/', '') === true);
check('不允许总览时盘符根没有上一级（与 posix 分支语义一致）',
  dir.browseParentPath('C:' + BS, 'C:' + BS, 'windows', false) === undefined);
eq('posix 分支不受影响（回归位）', dir.browseParentPath('/home/u/code', '/home/u', 'linux', true), '/home/u');

// ---------------------------------------------------------------------------
// 6. 路径显示与面包屑
// ---------------------------------------------------------------------------

group('路径显示（displayRemotePath / rootLabel）');
eq('绝对路径原样显示', dir.displayRemotePath('~', '/home/u', 'linux', '这台电脑'), '/home/u');
eq('相对根显示成根', dir.displayRemotePath('/home/u', '.', 'linux', '这台电脑'), '/home/u');
eq('相对路径拼到根后面', dir.displayRemotePath('/home/u', 'code', 'linux', '这台电脑'), '/home/u/code');
eq('根为空时只显示相对路径', dir.displayRemotePath('', 'code', 'linux', '这台电脑'), 'code');
eq('posix 根斜杠显示为 /', dir.displayRemotePath('/', '/', 'linux', '这台电脑'), '/');
eq('windows 盘符总览显示专用文案', dir.displayRemotePath('', '', 'windows', '这台电脑'), '这台电脑');
eq('面包屑根标签取末段', dir.rootLabel('/home/u', '主目录'), 'u');
eq('面包屑根标签：主目录哨兵用兜底', dir.rootLabel('~', '主目录'), '主目录');
eq('面包屑根标签：点目录用兜底', dir.rootLabel('.', '主目录'), '主目录');
eq('面包屑根标签：盘符根用盘符', dir.rootLabel('C:' + BS, '主目录'), 'C:');

group('面包屑切片（breadcrumbSegments）');
const crumbs = dir.breadcrumbSegments('/home/u', '/home/u/code/demo', 'linux', '主目录');
eq('层级数（根 + 2 级）', crumbs.length, 3);
eq('第一节标签是根名', crumbs[0].label, 'u');
eq('第一节路径指向根本身', crumbs[0].path, '/home/u');
eq('第二节标签', crumbs[1].label, 'code');
eq('第二节路径', crumbs[1].path, '/home/u/code');
eq('第三节标签', crumbs[2].label, 'demo');
eq('第三节路径', crumbs[2].path, '/home/u/code/demo');
eq('已在根上时只有一节', dir.breadcrumbSegments('/home/u', '/home/u', 'linux', '主目录').length, 1);
eq('当前路径为 . 时只有一节', dir.breadcrumbSegments('~', '.', 'linux', '主目录').length, 1);
// 关键防回归：归不到已知根时**绝不允许**把宿主机目录名摆上面包屑
const strayCrumbs = dir.breadcrumbSegments('/home/u', '/etc/ssh', 'linux', '主目录');
eq('归不到根时只保留根一节', strayCrumbs.length, 1);
eq('归不到根时不冒出 etc', strayCrumbs[0].label, 'u');
const unresolvedRoot = dir.breadcrumbSegments('~', '/home/u/code', 'linux', '主目录');
eq('根未解析成绝对路径时只有一节', unresolvedRoot.length, 1);
eq('根未解析时不冒出 home', unresolvedRoot[0].label, '主目录');
const relativeCrumbs = dir.breadcrumbSegments('.', 'src/deep', 'linux', '主目录');
eq('相对根下的相对路径可切片', relativeCrumbs.length, 3);
eq('相对切片第一节路径是 .', relativeCrumbs[0].path, '.');
eq('相对切片末节路径可直接回传', relativeCrumbs[2].path, 'src/deep');
check('面包屑路径去重（无空段）',
  dir.breadcrumbSegments('/home/u/', '/home/u/code/', 'linux', '主目录').map((c) => c.label).join('|') === 'u|code');

// ---------------------------------------------------------------------------
// 7. 目录项筛选排序
// ---------------------------------------------------------------------------

group('目录项：只留目录 + 按名排序（sortDirectoryEntries）');
const rawEntries = [
  { name: 'README.md', path: '/home/u/README.md', type: 'file' },
  { name: 'src', path: '/home/u/src', type: 'directory' },
  { name: 'Apps', path: '/home/u/Apps', type: 'directory' },
  { name: 'link', path: '/home/u/link', type: 'symlink' },
  { name: 'docs', path: '/home/u/docs', type: 'directory' }
];
const sortedEntries = dir.sortDirectoryEntries(rawEntries);
eq('文件与符号链接被滤掉', sortedEntries.length, 3);
eq('排序：大小写不敏感（Apps < docs < src）',
  sortedEntries.map((e) => e.name).join('|'), 'Apps|docs|src');
eq('第一个是目录项本身', sortedEntries[0].path, '/home/u/Apps');
const mixedCase = dir.sortDirectoryEntries([
  { name: 'b', path: '/b', type: 'directory' },
  { name: 'A', path: '/A', type: 'directory' },
  { name: 'a', path: '/a', type: 'directory' }
]);
eq('同字母不同大小写稳定（A 与 a 相邻且 A 在前）', mixedCase.map((e) => e.name).join('|'), 'A|a|b');
eq('空列表返回空数组', dir.sortDirectoryEntries([]).length, 0);
eq('全是文件时返回空数组',
  dir.sortDirectoryEntries([{ name: 'x.txt', path: '/x.txt', type: 'file' }]).length, 0);
check('不改动入参数组', rawEntries.length === 5 && rawEntries[0].name === 'README.md');
const driveEntries = dir.sortDirectoryEntries([
  { name: 'Users', path: '/C:/Users', type: 'directory' }
]);
eq('盘符条目的假前导段被归一（上游 entry.copy(path = normalizeRemotePath(...))）',
  driveEntries[0].path, 'C:/Users');
const sizedEntry = dir.sortDirectoryEntries([{ name: 'x', path: '/x', type: 'directory', size: 12 }]);
eq('可选字段 size 被保留', sizedEntry[0].size, 12);

// ---------------------------------------------------------------------------
// 8. 项目路径键与目录名
// ---------------------------------------------------------------------------

group('路径比较键（workspacePathKey）');
eq('去 ./ 折叠', dir.workspacePathKey('/home/u/./code/', 'linux'), '/home/u/code');
eq('.. 回退一级（只退一级）', dir.workspacePathKey('/home/u/../x', 'linux'), '/home/x');
eq('.. 多级回退', dir.workspacePathKey('/home/u/code/../x', 'linux'), '/home/u/x');
eq('重复斜杠折叠（// 保留 UNC 前导）', dir.workspacePathKey('//home//u', 'linux'), '//home/u');
eq('三斜杠退化成单斜杠', dir.workspacePathKey('///home', 'linux'), '/home');
eq('windows 归一小写', dir.workspacePathKey('C:' + BS + 'Users' + BS + 'Me', 'windows'), 'c:/users/me');
eq('windows 正反斜杠等价',
  dir.workspacePathKey('C:/Users/Me', 'windows'), dir.workspacePathKey('C:' + BS + 'Users' + BS + 'Me', 'windows'));
eq('posix 大小写敏感', dir.workspacePathKey('/Home/U', 'linux'), '/Home/U');
eq('空串键为空', dir.workspacePathKey('', 'linux'), '');

group('目录名（workspaceProjectName）');
eq('末段即名字', dir.workspaceProjectName('/home/u/code'), 'code');
eq('尾斜杠被忽略', dir.workspaceProjectName('/home/u/code/'), 'code');
eq('windows 反斜杠路径', dir.workspaceProjectName('C:' + BS + 'Users' + BS + 'me'), 'me');
// 上游 `workspaceProjectName` 只认「盘符 + 分隔符」为 Windows 路径：裸 `C:` 会原样当名字返回。
eq('裸盘符原样返回（与上游一致）', dir.workspaceProjectName('C:'), 'C:');
eq('盘符根回退成 Workspace', dir.workspaceProjectName('C:' + BS), 'Workspace');
eq('空串回退成 Workspace', dir.workspaceProjectName(''), 'Workspace');

// ---------------------------------------------------------------------------
// 9. 模型 / 权限选择的默认值与 wire 取值
// ---------------------------------------------------------------------------

group('模型默认值解析（resolveModelSelection / reasoningOptionsFor）');
const makeModel = (id, extra) => Object.assign({
  id: id,
  selectionId: id + '-sel',
  displayName: id,
  default: false,
  reasoningItems: [],
  metadata: {},
  enabled: true
}, extra || {});
const makeReasoning = (id, extra) => Object.assign({
  id: id,
  selectionId: id + '-sel',
  displayName: id,
  default: false,
  metadata: {},
  enabled: true
}, extra || {});
const makePermission = (id, extra) => Object.assign({
  id: id,
  selectionId: id + '-sel',
  displayName: id,
  default: false,
  metadata: {},
  enabled: true
}, extra || {});

eq('空目录 → 没有可选的模型', dir.resolveModelSelection([], '', ''), undefined);
const solo = dir.resolveModelSelection([makeModel('m1')], '', '');
eq('无推理项的模型直接选中', solo.modelId, 'm1');
eq('无推理项时推理强度为空串', solo.reasoningId, '');
const withDefault = dir.resolveModelSelection([makeModel('m1'), makeModel('m2', { default: true })], '', '');
eq('default 模型优先', withDefault.modelId, 'm2');
const disabledFirst = dir.resolveModelSelection([makeModel('m1', { enabled: false }), makeModel('m2')], '', '');
eq('被禁用的模型不参与默认化', disabledFirst.modelId, 'm2');
const noSelectionId = dir.resolveModelSelection([makeModel('m1', { selectionId: '' })], '', '');
eq('既无推理项又无 selectionId → 没有可选项', noSelectionId, undefined);
eq('目录里全是禁用项 → 没有可选项',
  dir.resolveModelSelection([makeModel('m1', { enabled: false })], '', ''), undefined);

const reasoningModel = makeModel('m1', {
  reasoningItems: [makeReasoning('low'), makeReasoning('high', { default: true })]
});
const resolvedReasoning = dir.resolveModelSelection([reasoningModel], '', '');
eq('有推理项时选中该模型', resolvedReasoning.modelId, 'm1');
eq('推理强度取 default 项', resolvedReasoning.reasoningId, 'high');
const keptReasoning = dir.resolveModelSelection([reasoningModel], 'm1', 'low');
eq('当前推理项仍有效则保留', keptReasoning.reasoningId, 'low');
const keptModel = dir.resolveModelSelection([makeModel('m1'), makeModel('m2')], 'm1', '');
eq('当前模型仍有效则保留', keptModel.modelId, 'm1');
const staleModel = dir.resolveModelSelection([makeModel('m1', { enabled: false }), makeModel('m2')], 'm1', '');
eq('当前模型被禁用则换掉', staleModel.modelId, 'm2');
const noDefaultReasoning = dir.resolveModelSelection([makeModel('m1', { reasoningItems: [makeReasoning('a'), makeReasoning('b')] })], '', '');
eq('无 default 推理项时取第一个', noDefaultReasoning.reasoningId, 'a');
const disabledReasoningOnly = dir.resolveModelSelection([makeModel('m1', {
  reasoningItems: [makeReasoning('a', { enabled: false }), makeReasoning('b')]
})], '', '');
eq('禁用推理项被跳过', disabledReasoningOnly.reasoningId, 'b');
const brokenReasoning = dir.resolveModelSelection([makeModel('m1', {
  selectionId: '',
  reasoningItems: [makeReasoning('a', { selectionId: '' })]
})], '', '');
eq('推理项缺 selectionId 且模型自身也没有 → 没有可选项', brokenReasoning, undefined);

const optionFilter = dir.reasoningOptionsFor([makeModel('m1', {
  reasoningItems: [makeReasoning('a'), makeReasoning('b', { enabled: false }), makeReasoning('c', { selectionId: '' }), makeReasoning('d')]
})], 'm1');
eq('推理项过滤后剩 2 个', optionFilter.length, 2);
eq('推理项过滤保留 a、d', optionFilter.map((r) => r.id).join('|'), 'a|d');
eq('未知模型没有推理项', dir.reasoningOptionsFor([makeModel('m1')], 'nope').length, 0);

group('selections 的 wire 取值（modelSelectionIdFor / permissionSelectionIdFor）');
eq('选中推理项 → 用推理项的 selectionId',
  dir.modelSelectionIdFor([reasoningModel], 'm1', 'high'), 'high-sel');
eq('模型自带推理项但没选中 → 不带 model',
  dir.modelSelectionIdFor([reasoningModel], 'm1', ''), '');
eq('无推理项的模型 → 用模型的 selectionId',
  dir.modelSelectionIdFor([makeModel('m1')], 'm1', ''), 'm1-sel');
eq('模型不在目录里 → 空串', dir.modelSelectionIdFor([makeModel('m1')], 'gone', ''), '');
eq('推理项 id 对不上且模型有推理项 → 空串',
  dir.modelSelectionIdFor([reasoningModel], 'm1', 'nope'), '');
eq('无推理项且模型 selectionId 缺失 → 空串',
  dir.modelSelectionIdFor([makeModel('m1', { selectionId: '' })], 'm1', ''), '');
eq('权限 wire 取值', dir.permissionSelectionIdFor([makePermission('p1')], 'p1'), 'p1-sel');
eq('权限未命中 → 空串', dir.permissionSelectionIdFor([makePermission('p1')], 'nope'), '');
eq('权限项被禁用 → 空串',
  dir.permissionSelectionIdFor([makePermission('p1', { enabled: false })], 'p1'), '');

group('权限默认值解析（resolvePermissionSelection）');
eq('空权限目录 → 空串', dir.resolvePermissionSelection([], ''), '');
eq('保留当前选择',
  dir.resolvePermissionSelection([makePermission('p1'), makePermission('p2')], 'p2'), 'p2');
eq('当前失效则取 default',
  dir.resolvePermissionSelection([makePermission('p1'), makePermission('p2', { default: true })], 'gone'), 'p2');
eq('没有 default 则取第一个可用',
  dir.resolvePermissionSelection([makePermission('p1'), makePermission('p2')], ''), 'p1');
eq('禁用项被跳过',
  dir.resolvePermissionSelection([makePermission('p1', { enabled: false }), makePermission('p2')], ''), 'p2');
eq('缺 selectionId 的项不可用',
  dir.resolvePermissionSelection([makePermission('p1', { selectionId: '' })], ''), '');

group('权限翻译键（runtimePermissionTranslationKey）');
eq('labelKey 优先（i18n.labelKey 命中）',
  dir.runtimePermissionTranslationKey('unknown', 'whatever', { i18n: { labelKey: 'dashboard.new.permissionModes.claude.plan.label' } }),
  'claude.plan');
eq('labelKey 未知则继续按 id 判',
  dir.runtimePermissionTranslationKey('dsh', 'read-only', { i18n: { labelKey: 'nope' } }), 'dsh.readOnly');
eq('dsh + id', dir.runtimePermissionTranslationKey('dsh', 'read-only', {}), 'dsh.readOnly');
eq('dsh + workspace-write', dir.runtimePermissionTranslationKey('dsh', 'workspace-write', {}), 'dsh.workspaceWrite');
eq('dsh + danger-full-access', dir.runtimePermissionTranslationKey('DSH', 'danger-full-access', {}), 'dsh.fullAccess');
eq('dsh 的 preset 优先于 id',
  dir.runtimePermissionTranslationKey('dsh', 'weird', { preset: 'workspace-write' }), 'dsh.workspaceWrite');
eq('dsh 未知 id → 无本地化文案', dir.runtimePermissionTranslationKey('dsh', 'weird', {}), '');
eq('通用 request_approval', dir.runtimePermissionTranslationKey('codex', 'request_approval', {}), 'requestApproval');
eq('通用 auto_review', dir.runtimePermissionTranslationKey('codex', 'auto_review', {}), 'autoReview');
eq('通用 full_access', dir.runtimePermissionTranslationKey('codex', 'full_access', {}), 'fullAccess');
eq('claude default', dir.runtimePermissionTranslationKey('claude', 'default', {}), 'claude.default');
eq('claude acceptEdits 大小写不敏感',
  dir.runtimePermissionTranslationKey('Claude Code', 'AcceptEdits', {}), 'claude.acceptEdits');
eq('claude bypassPermissions',
  dir.runtimePermissionTranslationKey('claude-code', 'bypassPermissions', {}), 'claude.bypassPermissions');
eq('非 claude 的 default 不误判', dir.runtimePermissionTranslationKey('codex', 'default', {}), '');
eq('空 metadata 不炸', dir.runtimePermissionTranslationKey('dsh', 'read-only', {}), 'dsh.readOnly');

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log('');
if (failures.length === 0) {
  console.log('suite-dirbrowse: ' + passed + ' 条断言全绿。');
  process.exit(0);
}
console.log('suite-dirbrowse: ' + passed + ' 通过 / ' + failures.length + ' 失败');
for (const item of failures) {
  console.log('  ✗ ' + item);
}
process.exit(1);
