# 开发指南

> 本仓库是开源项目 [Agents Anywhere](https://github.com/anywhere-labs/Agents-Anywhere)（[anywhere-labs](https://github.com/anywhere-labs) 维护，MIT，版权标识 Copyright (c) 2026 Agents Anywhere Contributors）的**鸿蒙端适配**。归属、第三方组件与上游许可全文见 [NOTICE.md](../NOTICE.md)。

本文覆盖四件事：**把工程跑起来**、**命令行构建到零告警**、**无需设备的逻辑自测**、**上设备调试与签名**。

约定：所有命令都在**工程根目录**（本仓库根）执行；路径示例统一用正斜杠。

## 1. 环境搭建

### 1.1 必需

| 组件 | 说明 |
| --- | --- |
| DevEco Studio | 需要支持 **HarmonyOS 7 / API 26** 的版本。它自带 hvigor 构建工具、Node.js 与 JDK，开箱即可构建 |
| HarmonyOS SDK | API 26（工程里 `compatibleSdkVersion` = `targetSdkVersion` = `26.0.0`，`runtimeOS` = `HarmonyOS`） |
| 设备或模拟器 | 真机需开启开发者模式与 USB 调试；模拟器用 DevEco 的 Device Manager 创建 |
| Node.js | 跑自测与工具脚本用。DevEco 自带一个 Node，也可用系统 Node（工程脚本只用内置模块，无第三方依赖） |

### 1.2 打开工程

用 DevEco Studio 打开**仓库根目录**（不是 `entry/`）。首次打开会执行 Sync，生成 `.hvigor/`、`oh_modules/` 等本地缓存。

### 1.3 构建配置从哪来

| 文件 | 是否入库 | 说明 |
| --- | --- | --- |
| `build-profile.json5` | **不入库**（已被 `.gitignore` 排除） | 本机的构建与签名配置：会被 DevEco 在 Sync / 自动签名时重写，且含本机路径与加密口令 |
| `build-profile.example.json5` | 入库 | 结构参考。复制成本地的 `build-profile.json5` 后，填入自己的签名信息即可 |
| `entry/build-profile.json5` | 入库 | 模块级配置，不含任何密钥 |
| `AppScope/app.json5`、`entry/src/main/module.json5` | 入库 | 应用与模块清单（bundleName、版本、权限、设备类型） |

> 权限只声明两个：`ohos.permission.INTERNET`（访问服务端）与 `ohos.permission.GET_NETWORK_INFO`（区分「未登录」与「网络不可达」）。新增权限请在 PR 里说明用途。

## 2. 命令行构建

### 2.1 推荐入口：串行化构建脚本

```bash
node tools/build-locked.mjs
```

这个脚本做四件事：**拿文件锁 → 构建 → 校验 `BUILD SUCCESSFUL` 且产物存在 → 算出 md5**，并把产物冻结到临时目录。

- hvigor 的 `.hvigor/` 缓存与 `entry/build/` 产物是**共享可变状态**：多终端 / 多进程同时 `assembleHap` 会互相覆盖中间产物，最坏情况是「本次报成功、产物其实是上一次的」；
- 退出码 `2` = 等锁超时，**不是构建失败**，重跑即可；
- `--timeout-min N` 调等锁上限，`--no-freeze` 跳过产物冻结，`--help` 只打印解析后的路径。

> 提示：`tools/` 下的脚本注释里可能引用**不随本仓库分发**的开发期证据路径（如 `verify-*` 目录）。那是开发过程的历史溯源，**不影响脚本运行**——运行所需的一切都来自本仓库内的文件与环境变量。

脚本用环境变量定位工具链，**全部可选**（头部注释有完整清单）：

| 环境变量 | 用途 |
| --- | --- |
| `DEVECO_HOME` | DevEco Studio 安装根目录 |
| `DEVECO_SDK_HOME` | HarmonyOS SDK 根目录（默认取 `<DEVECO_HOME>/sdk`） |
| `HVIGOR` | `hvigorw.js` 的完整路径 |
| `NODE_EXE` | 跑 hvigor 的 Node 可执行文件（默认当前 Node） |
| `AA_PROJECT_ROOT` / `AA_TMP` | 工程根与临时目录（默认按脚本位置与系统临时目录推导） |

### 2.2 直接调用 hvigor

需要自定义参数时可以直接调 `hvigorw`，但要自己准备好 `DEVECO_SDK_HOME`，并把 DevEco 自带的 JDK 加进 `PATH`（打包阶段会调用 `java`，缺失时报 `spawn java ENOENT`）。命令形如：

```bash
node <DEVECO_HOME>/tools/hvigor/bin/hvigorw.js --mode module -p product=default assembleHap --no-daemon
```

不知道自己机器上的 `hvigorw.js` 在哪，可以用 `node tools/build-locked.mjs --help` 打印解析后的路径。

### 2.3 产物与「零告警」口径

产物在 `entry/build/default/outputs/default/` 下：未配置签名时是 **unsigned HAP**，配置后产出 **signed HAP**。

本工程把「零告警」当作构建质量判据：

- 日志里必须出现 `BUILD SUCCESSFUL`；
- 且 `ArkTS:WARN File:` 与 ArkTS ERROR 的出现次数必须为 **0**。

自查方式（把构建日志存成文件后）：

```bash
grep -c 'ArkTS:WARN File:' build.log     # 期望 0
```

> 两个会让人误判「构建成功」的坑见 [ARKTS-PITFALLS.md](ARKTS-PITFALLS.md) 的构建章节：**命中缓存**（编译阶段报 `UP-TO-DATE`，其实根本没编译）与**外部命令退出码为 0 但实际失败**。判断是否真的重新编译过，要看编译阶段是否真的执行了。

## 3. 逻辑自测（无需设备）

### 3.1 一条命令

```bash
node tools/logic-test/run-all.mjs
```

共 **36 个套件**（一个主套件 + 各专项套件）。其中 **2 个套件依赖开发期的内部性能基线与证据文档，在开源仓库中会显式跳过（SKIP）**，其余全部通过。

- 退出码就是判据：全绿 = `0`，任一失败 = `1`，可直接当 CI 门禁；
- 跳过项会明确打印 `SKIP` 与原因，**不是**静默通过；
- 单条断言的条数随版本变化，**以实际输出为准**，不要在文档或 PR 里把它写成硬承诺；
- 只跑主套件用 `node tools/logic-test/run-tests.mjs`，但它会漏掉全部专项套件，**不建议单独使用**。

### 3.2 它为什么能脱离设备跑

工程的逻辑层被刻意与 UI 框架解耦：`api/ApiUrls`、`api/Parse`、`model/*`、`feature/TimelineProjection`、`vt/*`、`utils/Sha256`、`ui/MarkdownParse`、`ui/SyntaxHighlight` 这些模块**不引用 ArkUI、也不引用 Kit**。测试脚本把它们在 Node 里加载后直接跑断言，于是协议归一化、DTO 别名回退、时间线合并、VT 转义序列、宽字符、Markdown 与着色、路径判定、SHA-256 向量这类逻辑全部可以离线验证。

### 3.3 两类断言

| 类型 | 说明 |
| --- | --- |
| 行为断言 | 直接调用纯函数，比较输入输出 |
| 源码闸门 | 扫源码文本断言结构（例如「某个状态必须走 `@State`」「某个 API 只允许出现在指定位置」）。改回旧写法会立刻变红，用来防回潮 |

新增可单测的纯逻辑时，请顺手补一个套件：文件名以 `suite-` 开头即可被 `run-all.mjs` 自动发现（非 `suite-` 前缀的套件需要在 `run-all.mjs` 里显式登记，原因见该文件注释）。

## 4. 模拟服务端

登录之后的界面需要账号下有一台**在线设备**才能走到。没有真实账号时，用仓库里的模拟服务端即可把整条链路跑通：

```bash
node tools/mock-server/server.mjs --port 8787
```

然后把应用的服务器地址填成 `http://<运行模拟服务端的机器地址>:8787`，用**任意邮箱 + 任意非空密码**登录。

| 参数 | 作用 |
| --- | --- |
| `--host` / `--port` | 监听地址与端口（默认绑本机局域网 IP，不是 `0.0.0.0`） |
| `--ruler` | 终端回放改用带行号的刻度内容，便于核对行列映射 |
| `--fail-attachments` | 附件下载固定返回 500，用来验收「失败后请求收敛、不自我放大」 |
| `--page-size N` | 开启会话真分页（额外造一批分页会话，按 `limit` / `cursor` 真切片） |
| `--input-request` | 把审批卡换成提问表单 |

它是**零依赖**实现（只用 Node 内置模块），端点、字段名、实时事件名与终端帧格式都按 [specs/01-api-spec.md](../specs/01-api-spec.md) 编写，因此同时充当「协议实现对不对」的对照物。

安全与使用注意：

- 只提供假数据、不落盘、不读本地文件；验收结束后请**立即停掉进程**；
- 真机通过 USB 访问更稳的方式是端口转发（见下文 5.3），不依赖局域网与 IP 是否漂移。

### 写验收夹具的两条纪律

1. **按请求参数返回**：同一个接口的不同参数必须返回不同内容。用一个罐头响应应付所有路径，会让「应用点错了对象」看起来像「应用是对的」——它骗的不是功能，是证据；
2. **写操作要真的回写状态**：`PATCH`、归档、标记已读这类请求必须落进内存夹具，否则「应用没刷新」与「服务端没存」在证据上无法区分。

## 5. 设备调试

### 5.1 hdc 基本用法

`hdc` 在 SDK 的 `toolchains` 目录下（也可以用 DevEco 自带的终端）。常用命令：

```bash
hdc list targets                                # 列出在线设备
hdc -t <设备> install -r <HAP 路径>              # 覆盖安装（保留登录态）
hdc -t <设备> shell aa force-stop <bundle>       # 停应用
hdc -t <设备> shell aa start -a EntryAbility -b <bundle>
hdc -t <设备> hilog | grep <关键字>              # 看日志
```

三条容易踩的纪律：

1. **同时有多台设备时必须带 `-t <设备>`**：不带时安装 / 取文件可能打到另一台，表现为「改动没生效」；
2. **路径用平台原生形式**：给 `install` / `file recv` 传拼接式路径可能被拼成「工作目录 + 路径」而失败，**而退出码仍可能是 0**（假成功）——失败时请以设备上的实际状态为准，不要只看退出码；
3. **覆盖安装后先 `force-stop` 再启动**：直接拉起可能拿到旧进程状态。

### 5.2 自动化小工具

`tools/device-ctl.mjs` 把「取真实坐标 → 点击 / 键入 → 截图 → 回读记录」串成一条命令，避免凭截图估坐标（几像素的误差就会静默点空，看起来像应用缺陷）。用法与全部环境变量见该脚本头部注释，例如：

```bash
AA_DEVICE_SN=<设备序列号> node tools/device-ctl.mjs find "登录"
AA_DEVICE_SN=<设备序列号> node tools/device-ctl.mjs click "登录"
AA_DEVICE_SN=<设备序列号> node tools/device-ctl.mjs shot home.png
```

### 5.3 让设备访问本机的模拟服务端

```bash
hdc -t <设备> rport tcp:8787 tcp:8787
```

之后在应用里把服务器地址填成 `http://127.0.0.1:8787` 即可——走 USB 通道，不受局域网与 IP 漂移影响。

### 5.4 界面取证

`uitest dumpLayout` 能导出控件树（bounds、文本、类型），是定位布局问题最硬的判据；但要知道它的两条边界：

- 它**只导出可见节点**：节点不在可见区时「读不到」不等于「没渲染」；
- 无障碍字段能否反映当前状态，取决于该元素这次是否被重建；判**动态状态**（选中 / 加载 / 禁用）优先用像素或日志回读。

## 6. 签名流程

**本仓库不含任何签名材料，也不接受把签名材料提交进仓库。** 签名是每个开发者在自己机器上做一次的本地步骤：

1. 用 DevEco Studio 打开工程；
2. 进入 `File > Project Structure > Signing Configs`；
3. 勾选 *Automatically generate signature*，按提示登录华为账号，等待 DevEco 生成证书、密钥库与 Profile；
4. DevEco 会把这些材料的**本机路径与加密口令**写回本地的 `build-profile.json5`（该文件已被 `.gitignore` 排除）；
5. 之后 `assembleHap` 就会产出可直接安装的 signed HAP。

要点：

- **签名材料与口令一律不入库、不写进文档、不贴进 issue / PR / 日志**；CI 需要签名时用流水线的密钥管理或环境变量注入，不要提交到仓库；
- 未签名的 HAP 无法安装，系统会直接拒绝；
- 签名身份决定能否覆盖安装：**换了签名就无法原地升级**，需要先卸载（会清掉登录态）；
- 如果你 fork 了本仓库，请把 bundleName 改成自己的（`AppScope/app.json5`），并在自己的开发者账号下重新签名。

## 7. 排错速查

| 症状 | 先查什么 |
| --- | --- |
| 构建报 `spawn java ENOENT` | `PATH` 里有没有 DevEco 自带的 JDK |
| 构建「成功」但改动没生效 | 编译阶段是不是命中了缓存（`UP-TO-DATE`）；产物时间戳与 md5 |
| 装了包但界面没变 | 是否装到了另一台设备（多设备要 `-t`）；覆盖安装后有没有 `force-stop` |
| 应用连不上服务端 | 服务器地址是否可达（先在设备浏览器里访问 `/health`）；自建实例是否允许该地址；模拟服务端是否还在运行 |
| 终端打不开 | 账号下是否有**在线设备**，且该设备上启用了 Runtime |
| 自测有失败项 | 是 `FAIL` 还是 `SKIP`：`SKIP` 是依赖开发期内部资料的套件在开源仓库中的预期行为 |

更多症状与根因，按主题整理在 [ARKTS-PITFALLS.md](ARKTS-PITFALLS.md)。
