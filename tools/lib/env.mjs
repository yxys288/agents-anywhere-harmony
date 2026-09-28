/**
 * aa-hm 工具链可移植化公共库 —— 环境变量 / 路径解析 / 外部命令定位。
 *
 * 为什么有这个文件：`tools/` 下的脚本原先普遍把**某台机器的绝对路径**（工程根、DevEco 安装位置、
 * 临时目录）与**真实设备序列号**写死在常量里，换一台机器就必然跑不起来，也没法开源。
 * 这里把「怎么找东西」收敛成一处：
 *   · 一律 **环境变量优先 + 合理默认 + 缺失时清晰中文报错**；
 *   · 项目根用 `import.meta.url` 推导（脚本放在哪都能算对），而不是写死盘符。
 *
 * ⚠️ 本文件只做解析，不改变任何脚本的命令行参数与输出契约。
 *
 * 支持的环境变量（全部可选，未设置时按下面的顺序自动探测）：
 *   AA_PROJECT_ROOT  工程根目录（默认：由脚本位置上溯推出）
 *   AA_TMP           临时目录（默认：os.tmpdir()）
 *   DEVECO_HOME      DevEco Studio 安装根（默认：常见安装位置）
 *   DEVECO_SDK_HOME  HarmonyOS SDK 根（默认：<DEVECO_HOME>/sdk）
 *   HDC              hdc 可执行文件完整路径（默认：<SDK>/default/openharmony/toolchains/hdc.exe）
 *   HVIGOR            hvigorw.js 完整路径（默认：<DEVECO_HOME>/tools/hvigor/bin/hvigorw.js）
 *   NODE_EXE         node 可执行文件（默认：当前进程 process.execPath）
 *   AA_TS_MODULE     提供 typescript 的 node_modules 目录（默认：自动探测）
 *   TS_PACKAGE       提供 typescript 的模块 id 或目录（优先级高于 AA_TS_MODULE）
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

/** env.mjs 自身所在目录（= <项目根>/tools/lib）。 */
const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 读取环境变量；空串 / 全空白视同未设置（避免 CI 里 `VAR=` 把默认值顶掉）。 */
export function env(name) {
  const raw = process.env[name];
  if (raw === undefined || raw === null) {
    return undefined;
  }
  const value = String(raw).trim();
  return value.length > 0 ? value : undefined;
}

/** 判断路径是否存在（文件或目录）。传空值返回 false，不抛。 */
export function exists(target) {
  if (!target) {
    return false;
  }
  try {
    return fs.existsSync(target);
  } catch (error) {
    return false;
  }
}

/**
 * 工程根目录。
 * @param {{up?: number, scriptUrl?: string}} [options] up = 脚本相对工程根要上溯几层（tools/ 下 = 1，tools/logic-test/ 下 = 2）。
 */
export function projectRoot(options) {
  const opts = options || {};
  const override = env('AA_PROJECT_ROOT');
  if (override) {
    return path.resolve(override);
  }
  const base = opts.scriptUrl ? path.dirname(fileURLToPath(opts.scriptUrl)) : HERE;
  return path.resolve(base, ...Array(opts.up === undefined ? 2 : opts.up).fill('..'));
}

/**
 * 临时目录（默认系统临时目录，可用 AA_TMP 覆盖）。
 * 工程纪律：临时产物一律落这里，绝不写进工程目录。
 */
export function tempDir() {
  const override = env('AA_TMP');
  const base = override ? path.resolve(override) : os.tmpdir();
  try {
    fs.mkdirSync(base, { recursive: true });
  } catch (error) {
    /* 已存在或无权创建：交给调用方在使用时报错，这里不吞掉后续异常 */
  }
  return base;
}

/** 默认的 DevEco Studio 安装根（Windows 上的常见位置；其它平台请用 DEVECO_HOME 指定）。 */
function defaultDevecoHome() {
  const candidates = [
    'D:/DevEco Studio',
    'C:/Program Files/Huawei/DevEco Studio',
    'C:/Program Files/DevEco Studio'
  ];
  for (const candidate of candidates) {
    if (exists(candidate)) {
      return candidate;
    }
  }
  return candidates[0];
}

/** DevEco Studio 安装根 */
export function devecoHome() {
  return env('DEVECO_HOME') || defaultDevecoHome();
}

/**
 * 在当前 Node 里**尝试**解析一个模块，成功返回模块对象，失败返回 undefined（不抛）。
 * @param {string} id 模块 id 或绝对路径
 */
function tryRequire(id) {
  try {
    return createRequire(import.meta.url)(id);
  } catch (error) {
    return undefined;
  }
}

/** 模块搜索目录（按优先级）：工程自带 node_modules → DevEco 自带 node_modules。 */
export function moduleSearchPaths() {
  const project = projectRoot();
  const home = devecoHome();
  return [
    path.join(project, 'node_modules'),
    path.join(project, 'tools', 'node_modules'),
    path.join(home, 'tools', 'hvigor', 'hvigor', 'node_modules'),
    path.join(home, 'tools', 'hvigor', 'node_modules'),
    path.join(home, 'tools', 'node', 'node_modules')
  ];
}

/**
 * 取「DevEco 自带 TypeScript」的模块 id / 目录（决定模块能不能被解析）。
 *
 * 优先级：TS_PACKAGE（模块 id 或目录，向后兼容）＞ AA_TS_MODULE（node_modules 目录）＞ 自动探测。
 * 自动探测顺序：工程自带 node_modules 里的 typescript → DevEco 自带 hvigor 的 node_modules
 * → DevEco 自带 node 的 node_modules。有工程自带依赖时优先用它，这样**不装 DevEco 也能跑逻辑套件**。
 *
 * ⚠️ 返回的是「用来 require 的东西」，**不是**已经 require 好的模块对象：
 * 各套件还会把它原样往子进程 / 变异临时文件里透传，先求值会破坏既有用法。
 * 真正的求值走 {@link requireTypeScript}（只在主进程里用）。
 */
export function typeScriptModuleId() {
  const direct = env('TS_PACKAGE');
  if (direct) {
    return direct;
  }
  const moduleDir = env('AA_TS_MODULE');
  const bases = moduleDir ? [path.resolve(moduleDir)] : moduleSearchPaths();
  for (const base of bases) {
    const candidate = path.join(base, 'typescript');
    if (exists(candidate)) {
      return candidate;
    }
  }
  // 都没找到：仍返回一个可读的候选，让真正常用的那台机器（DevEco 自带）先跑，报错交给 requireTypeScript。
  if (moduleDir) {
    return path.join(path.resolve(moduleDir), 'typescript');
  }
  return 'typescript';
}

/**
 * 真正加载 TypeScript（**文件顶部不要调用**：套件在纯 Node 环境下应当只做语法解析，
 * 只有真跑转译时才需要 TS）。加载不到时给出可操作的中文报错。
 */
export function requireTypeScript() {
  const moduleId = typeScriptModuleId();
  const direct = tryRequire(moduleId);
  if (direct) {
    return direct;
  }
  const probes = [];
  for (const base of moduleSearchPaths()) {
    const candidate = path.join(base, 'typescript');
    probes.push(candidate);
    const loaded = tryRequire(candidate);
    if (loaded) {
      return loaded;
    }
  }
  throw new Error(
    '未找到 TypeScript 编译器（逻辑套件用它把 .ets 转译成 CommonJS 后跑断言）。\n' +
    '  · 已尝试：' + [moduleId].concat(probes).join('\n            ') + '\n' +
    '  · 三种解决办法（任选其一）：\n' +
    '      1) 装 DevEco Studio，并设置 DEVECO_HOME=<DevEco 安装目录>；\n' +
    '      2) 在工程根执行 npm i -D typescript，或设置 AA_TS_MODULE=<含 typescript 的 node_modules 目录>；\n' +
    '      3) 设置 TS_PACKAGE=<typescript 模块目录或模块 id>。'
  );
}

/**
 * 依次尝试若干模块 id / 绝对路径，返回第一个能 require 成功的结果。
 * 全失败时抛中文错误（列出尝试过的位置）。
 */
export function requireFirst(ids) {
  const tried = [];
  for (const id of ids) {
    if (!id) {
      continue;
    }
    const loaded = tryRequire(id);
    if (loaded) {
      return loaded;
    }
    tried.push(id);
  }
  for (const id of ids) {
    if (!id || path.isAbsolute(id)) {
      continue;
    }
    for (const base of moduleSearchPaths()) {
      const abs = path.join(base, id);
      if (!exists(abs)) {
        continue;
      }
      const loaded = tryRequire(abs);
      if (loaded) {
        return loaded;
      }
      tried.push(abs);
    }
  }
  throw new Error(
    '未找到需要的 Node 模块：' + ids.join(' / ') + '\n' +
    '  · 已尝试：' + tried.join('\n            ') + '\n' +
    '  · 若这是 DevEco 自带的模块，请设置 DEVECO_HOME=<DevEco 安装目录>；\n' +
    '  · 若是第三方包，请在工程根执行 npm i -D <包名>（或设置 AA_PROJECT_ROOT 指向含 node_modules 的工程根）。'
  );
}

/** 真机 / 模拟器序列号：AA_DEVICE_SN 优先，AA_DEVICE 兼容旧写法。 */
export function deviceSerial() {
  return env('AA_DEVICE_SN') || env('AA_DEVICE');
}

/**
 * 要求显式提供设备序列号，否则抛中文错误。
 * @param {string} [usage] 用法提示，例如 'node tools/device-ctl.mjs shot x.jpeg'
 */
export function requireDeviceSerial(usage) {
  const serial = deviceSerial();
  if (serial) {
    return serial;
  }
  throw new Error(
    '未指定目标设备序列号。\n' +
    '  · 请设置环境变量 AA_DEVICE_SN=<设备序列号>（多设备在线时必填，否则 hdc 可能打到另一台设备）；\n' +
    '  · 查看在线设备：<hdc> list targets' + (usage ? '\n  · 用法：' + usage : '')
  );
}
