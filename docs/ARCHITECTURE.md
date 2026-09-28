# 架构

> 本仓库是开源项目 [Agents Anywhere](https://github.com/anywhere-labs/Agents-Anywhere)（[anywhere-labs](https://github.com/anywhere-labs) 维护，MIT，版权标识 Copyright (c) 2026 Agents Anywhere Contributors）的**鸿蒙端适配**。归属、第三方组件与上游许可全文见 [NOTICE.md](../NOTICE.md)。

本文说明这个鸿蒙客户端**怎么分层、数据怎么流动、以及两个关键设计取舍的理由**。

## 1. 总览

工程沿用上游 Android 客户端的分层思路（见 [specs/01-api-spec.md](../specs/01-api-spec.md)），但按 ArkTS / ArkUI 的实际约束做了调整：

```text
entry/src/main/ets/
├── api/        HTTP / WS 传输 + 线格式归一化
├── model/      共享模型与纯逻辑
├── store/      本地持久化（preferences）
├── feature/    功能层：状态机与业务编排（不画 UI）
├── vt/         自研 VT 终端仿真（纯计算，不依赖 ArkUI）
├── ui/         ArkUI 层：设计令牌、通用组件、路由、渲染
├── utils/      Codec（Base64）、SHA-256
├── dev/        构建期全量模块类型检查探针
└── pages/      根页面：登录态门控 + 路由分发
```

依赖方向是**单向**的：`ui → feature → api/model`，`store` 被 `feature` 使用，`vt` 与 `model` 是叶子（谁都可以依赖它们，它们不依赖任何人）。

```text
pages/Index ──► ui/screens/* ──► feature/*Store ──► api/* ──► 服务端
                    │                  │
                    │                  └──► store/*（preferences）
                    ├──► vt/*（终端页）
                    └──► ui/*（令牌 / 组件 / Markdown / 高亮）
```

## 2. 分层职责

### 2.1 `api/`：传输与线格式归一化

| 文件 | 职责 |
| --- | --- |
| `ApiUrls.ets` | origin 归一化、`/api/v2` 与 legacy 两种路由风格的双候选与回退、WS 地址派生 |
| `ApiClient.ets` | 基于 `@kit.NetworkKit` 的 http 客户端：JSON / 表单 / 多部分上传、错误体解析、401 处理 |
| `Parse.ets` | 线格式（`Raw`）→ 强类型：全部别名回退与默认值集中在这里 |
| `AuthApi` / `SessionsApi` / `DevicesApi` / `FilesApi` / `TerminalApi` / `RealtimeApi` | 按域划分的端点封装（`RealtimeApi` 同时管两条 WebSocket） |

三条约定：

1. **宽容解析集中在一处**。服务端字段可能有别名、可能缺省，这些回退全部在 `Parse.ets` 里完成，上层只面对强类型；
2. **路由风格回退只在首次请求发生**。命中后把该 origin 的风格记在内存里，后续只用命中的那个，避免每个请求都试两次；
3. **`api/` 不做业务判断**。它只回答「这个请求成功了没有、返回了什么」。

### 2.2 `model/`：共享模型与纯逻辑

`model/Types.ets` 存放全部 wire DTO（字段名与 JSON 完全一致）；其余文件是**不碰 IO、不碰 UI 的纯逻辑**，例如：

| 文件 | 职责 |
| --- | --- |
| `AppModels.ets` | 会话 / 设备 / 项目模型，以及排序与标签派生 |
| `TextFiles.ets` | 「能否按文本预览」的判定（扩展名 + 无扩展名特例表） |
| `RemotePaths.ets` | 远程路径判定：父目录、是否越出工作区根 |
| `HomeGrouping.ets` / `SessionPaging.ets` / `ArchivedPaging.ets` | 工作台分组与分页的纯状态机 |
| `RuntimeSelection.ets` / `ReasoningText.ets` / `ContextUsage.ets` | 运行时选型、推理段文本、上下文用量 |

把这类判断放进 `model/` 而不是页面里，是因为**它们是可单测的**：逻辑自测直接加载这些文件跑断言，不需要设备。

### 2.3 `store/`：本地持久化

三个文件，全部基于 preferences：`AuthSessionStore`（令牌与账号信息）、`AppPreferences`（界面偏好、语言、外观）、`ComposerDraftStore`（输入草稿，按 sessionId 存）。

原则：**`store/` 只负责读写，不做网络、不做派生**。任何需要联网或计算的东西都属于 `feature/`。

### 2.4 `feature/`：功能层（不画 UI）

这是应用真正「有状态」的地方。每个 Store 持有自己的数据、订阅实时通道、把变化通知给 UI，但不引用任何 ArkUI 组件。

| 文件 | 职责 |
| --- | --- |
| `AppServices.ets` | 单例组装（ArkTS 没有 DI 容器）+ `AuthController` + 外观控制器 + 扫码载荷解析 |
| `DashboardStore.ets` | 工作台：设备 / 项目 / 会话 + `dashboard` WebSocket 全量快照 |
| `SessionDetailStore.ets` | 会话详情：snapshot + 事件合批 + 游标恢复 + 审批响应 |
| `TimelineProjection.ets` | 时间线 item → 可渲染消息（upsert-only 合并，一条 item 可能展开成多条） |
| `TerminalStore.ets` | 终端生命周期 + 流式帧解析 |
| `FilesStore.ets` / `AttachmentStore.ets` / `DeviceStore.ets` / `AgentPresetStore.ets` / `SlashCommandStore.ets` | 文件浏览与文本预览、附件按需下载与缓存、设备与 Runtime 管理、Agent 预设目录、会话指令 |

关键设计：**事件合批**。会话实时通道的事件按约 34ms 的窗口合并后再通知 UI（≈30Hz），避免高频 `timeline.item_updated` 直接触发逐条重绘；时间线合并是 **upsert-only**（同 id 覆盖、不追加、不重排）。

### 2.5 `vt/`：自研 VT 终端仿真

见下文「设计取舍一」。

### 2.6 `ui/`：ArkUI 层

| 文件 | 职责 |
| --- | --- |
| `Design.ets` | 设计令牌：颜色走资源双值（浅色 / 深色各一份），间距、圆角、字阶集中定义 |
| `Components.ets` | 通用组件 |
| `Router.ets` | 显式路由栈（见下文「设计取舍二」） |
| `MarkdownParse.ets` / `Markdown.ets` | 轻量 Markdown 解析（纯函数）与渲染（代码块逐 token 着色） |
| `SyntaxHighlight.ets` | 纯 ArkTS 语法着色器（15 个语言档 + 别名归一 + 按文件名猜语言） |
| `Icon.ets` / `GlassIcon.ets` / `BottomNav.ets` / `BackHandler.ets` | 图标体系、玻璃按钮、底栏、返回键消费链 |
| `screens/*.ets` | 14 个页面与流程屏（登录、工作台、会话详情、新建会话 / 新对话、文件、终端、设备、设备详情、设置、归档会话、添加设备、扫码等待等） |

页面只做两件事：**读 Store 的状态并渲染**、**把用户动作转成 Store 的方法调用**。业务规则不写在 `build()` 里。

### 2.7 `utils/` 与 `dev/`

- `utils/Codec.ets`（Base64）与 `utils/Sha256.ets`（纯 ArkTS 实现，无 Kit 依赖）——放这里的关键理由是它们能被逻辑自测直接验证（含 NIST 向量）；
- `dev/CompileProbe.ets` 是一个**构建期类型检查探针**：显式引用各层模块，让「某个文件因为没有调用点而逃过 `assembleHap` 的类型检查」这件事不再发生。

## 3. 设计取舍一：自研 VT 终端仿真

### 3.1 它是什么

`vt/` 是一套完整的 VT 终端仿真内核，把终端字节流变成一块**可直接渲染的屏幕网格**：

| 文件 | 职责 |
| --- | --- |
| `WcWidth.ets` | 组合符与东亚宽字符的宽度表 |
| `TerminalStyle.ets` | 颜色编码、样式驻留池、256 色调色板 |
| `TerminalRow.ets` | 一行 = 码位数组 + 样式 id 数组 + 已用列数 |
| `TerminalBuffer.ets` | 屏幕 + 回看 + 边距滚动 + 制表位 + resize |
| `TerminalEmulator.ets` | 转义序列状态机（C0 / ESC / CSI / OSC / DCS） |
| `KeyHandler.ets` | 按键 → 字节序列（含应用光标键模式） |

覆盖范围包括 SGR 全量属性、256 色与真彩色、备用屏、边距滚动、制表位、resize、宽字符、括号粘贴与鼠标模式位。

### 3.2 为什么自己写，而不是用现成组件

- **生态位置不同**：上游 Android 端依赖的是成熟终端组件；鸿蒙侧没有可直接对齐的等价物，形态也无法一比一照搬；
- **可控性**：终端行为是「有确定语义的规范」，自己实现才能对每一条转义序列写断言，而不是靠肉眼比对；
- **可测性**：这是关键——见下条。

### 3.3 取舍的核心：**内核不依赖 ArkUI**

`vt/` 里的文件**不引用任何 ArkUI / Kit 模块**。带来的直接好处：

1. 逻辑自测可以在 Node 里加载整个仿真内核，直接喂字节流、断言屏幕内容、光标位置、回看偏移与 resize 不变量，**完全不需要设备**；
2. 渲染层与仿真层可以分别演进：`TerminalScreen` 只负责把网格画到 Canvas、处理输入与手势，不参与任何终端语义；
3. 终端这种「长时间运行、状态复杂」的组件，最有价值的回归恰恰是那些**看不见的边界**（回看取行、收缩进回看区、扩张可逆、宽字符占位），把它们做成纯函数断言，比截图上对比可靠得多。

代价是仿真内核要自己维护（转义序列的覆盖面、性能优化都归自己），换来的是**可验证性**。

### 3.4 渲染层的分工

`TerminalScreen` 持有 `TerminalStore`（生命周期与流式帧），把帧交给 `vt/` 仿真，再把结果画到 Canvas 网格上。附加按键行（ESC / TAB / CTRL / 方向键等）走 `KeyHandler` 生成字节序列，与真实终端的按键语义一致；剪贴板粘贴走括号粘贴模式。

## 4. 设计取舍二：显式路由栈

### 4.1 做法

`ui/Router.ets` 维护一个**自管理的路由栈**，并把「当前路由名」与「当前参数」摊平成两个字符串键放进 `AppStorage`；根页面 `pages/Index.ets` 用 `@StorageLink` 直接读这两个键，据此分发到具体页面。

### 4.2 为什么不用 `Navigation` / `NavPathStack`

1. **层级很浅**：本应用是「根 + 若干详情页」的形态，不需要嵌套导航与复杂路由图；
2. **返回行为要可控**：自管理的栈让「谁消费返回键、退到哪一层」变成显式代码，而不是依赖框架的栈语义；
3. **省掉样板**：不引入目的地注册与参数序列化，页面间传递的参数是显式的字符串编码；
4. **状态可见**：路由与登录态都是 `AppStorage` 里的字符串键，排查「为什么界面没变」时可以直接读。

### 4.3 一个必须遵守的约束

**参与渲染的状态必须在 `build()` 里被读过。** 把整个栈作为对象数组塞进 `AppStorage`、再由页面调 `Router.current()` 取值，是行不通的：ArkUI 的观察是「读时登记」，`build()` 没读过的状态变化不会触发重建，表现为「路由变了但界面不动」。所以栈可以复杂，但**对外暴露给渲染的必须是字符串键并被直读**。

相关的坑（`@State` 依赖登记、`@Builder` 值参数不重建、`ForEach` 的 key 语义）整理在 [ARKTS-PITFALLS.md](ARKTS-PITFALLS.md) 的状态与刷新章节。

## 5. 一条典型的数据流：从服务端事件到屏幕

```text
服务端 WS 事件
   │  RealtimeApi 解析信封（protocolVersion / sequence / cursor / type / payload）
   ▼
SessionDetailStore   合批（≈34ms）→ 应用增量
   │  TimelineProjection   item → 可渲染消息（upsert-only）
   ▼
Store 通知监听者（监听器是页面注册的具名引用，销毁时摘除）
   ▼
页面把结果拷进 @State 字段
   ▼
build() 读 @State → ArkUI 重绘对应节点
```

每一步都有对应的约束：解析必须宽容（字段别名 / 缺省）、合批必须保留顺序、投影必须幂等（同一事件重复到达不产生重复行）、通知必须可摘除（否则已销毁页面继续被回调）、渲染必须让状态真正参与依赖登记。这些约束各自都有对应的自测断言与实战教训。

## 6. 错误处理与边界

- **401 精确清理**：只有当前令牌与回调令牌一致时才清登录态，避免并发请求互相覆盖；
- **网络不可达与未登录区分开**：前者提示网络问题，后者才回登录页（这正是 `GET_NETWORK_INFO` 权限的用途）；
- **失败不放大**：附件下载这类可重试路径要有收敛策略，不做无限重试；
- **错误原文上屏**：终端的错误信息直接显示服务端原文，而不是自造的「出错」——自造文案会让问题无法诊断。

## 7. 相关文档

| 文档 | 内容 |
| --- | --- |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 构建、自测、模拟服务端、设备调试、签名 |
| [ARKTS-PITFALLS.md](ARKTS-PITFALLS.md) | ArkTS / ArkUI 实战踩坑集 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 分支、提交、自测要求与 PR 流程 |
| [specs/01-api-spec.md](../specs/01-api-spec.md) | 上游 v2 API 契约 |
