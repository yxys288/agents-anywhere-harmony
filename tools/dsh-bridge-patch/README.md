# DSH 侧补丁：上下文用量 + 原生指令（R52）+ 压缩标记成键（R81）

aa-hm 的「上下文圆环」与「指令按钮」需要两项数据，而它们**只存在于 DSH 侧**。
本目录的脚本把这两项接到 AA 的官方链路上。

## 为什么必须动 DSH 侧

| 项 | 缺在哪 |
| --- | --- |
| 上下文用量 | DSH 自己算好了（`contextPressure` / `tokenUsage` 两个投影），但 bridge 插件**从没放进 `session.getState`** |
| 指令目录/执行 | AA 服务端**有**官方通道（能力 `session.commands` + `/sessions/{id}/runtime/commands`），但 bridge 把它声明成 unsupported 且无 RPC 分支；连接器的 DSH runtime 也没实现 `list_commands`/`execute_command` |
| 为什么不能绕 | DSH 的指令**不是发消息执行的**（`dsh-commands.execute()`：*without sending it to the model*）⇒ 只能走 RPC |

完整调查见开发期验证记录（`verify-*` 证据目录**不随本仓库分发**）。

## 改了什么（9 条）

| 文件 | 内容 |
| --- | --- |
| `node_modules/@agents-anywhere/dsh-bridge-next/lib/index.js` | 读两个用量投影 → 放进 `session.getState` 的 metadata；`session.commands` 置为 supported + 注册 RPC 分支 + 实现（列目录/执行，转发 DSH `commands` 服务） |
| `.../lib/bundled-connector/connector/runtimes/dsh/runtime.py` | 实现 `list_commands` / `execute_command`（转发 `session.commands` RPC） |
| `.../lib/index.js`（R81） | 压缩标记的 business key：`String(event.seq)` → `String(event.data?.compactionId ?? event.seq)` ⇒ 一次压缩一个 item（见下） |

⚠️ 连接器是**可编辑安装**（`_editable_impl_anywhere_cli.pth` 指向 `bundled-connector`），
所以改 `runtime.py` 后**重启连接器**即可；而 `index.js` 是 **DSH 插件进程内**的代码，
必须**重启 DSH 桌面端**才加载。

## R81 第 9 条：压缩标记按「压缩身份」成键（一次压缩只出一个条目）

**症状**（用户 R80 报的）：「压缩上下文会显示多条『上下文压缩』信息」。

**根因**：`index.js` 里 marker 的 business key 原来是 `String(event.seq)`，而 DSH 对**每一次**压缩会写
`compaction/start` + `compaction/summary` + `compaction/end`（外加若干 `compaction/prune`）**多条记录** ⇒
**每条记录各出一个 item**。真机会话日志实测：**4 次压缩 = 24 条记录 = 24 行**。

**改法**：有 `data.compactionId` 的记录共用同一个 key ⇒ `put()` 命中同一个 item id
（`orderSeq` 由 `previous?.orderSeq` 保住位置、`revision` 随 seq 递增）⇒ **一次压缩一个 item**。
无 id 的 `compaction/prune` 回落到 `seq`（它们在日志里紧贴在所服务那次 `start` **之前**，
归组交给 App 侧 `collapseCompactMarkers` 的「向后归并」）⇒ 两层各自独立成立。

**效果**（开发期验证脚本跑真机会话日志实测）：
24 条记录 → **16 个 item**（12 条压缩记录塌成 **4 个身份** + 12 条 prune 各占一个），
再经 App 侧归并 ⇒ 时间线上 **4 行**（= 真实压缩次数）。

⚠️ **生效时机**：`index.js` 是 DSH 进程启动时加载的 ⇒ **改完必须重启 DSH 桌面端**，
当前这个进程里跑的还是旧代码（所以补丁打完之后，运行期行为**暂时不变**）。
⚠️ 这一步**不是必需的**：R80 起 App 侧已经对 bridge 的任何粒度免疫（无论一个压缩出 1 条还是 4 条 marker，
都会归成 1 行）—— 打这条补丁是为了**把根因也修掉**（其它客户端、以及不带 R80 归并的旧版本都受益）。

## 用法

```powershell
# 看当前状态（不改任何文件）
node tools/dsh-bridge-patch/patch.mjs --check

# 应用（幂等：已打过就跳过）
node tools/dsh-bridge-patch/patch.mjs

# 撤销
node tools/dsh-bridge-patch/patch.mjs --revert

# DSH 装在别处时
node tools/dsh-bridge-patch/patch.mjs --app="<DSH 安装目录>"   # 或设环境变量 DSH_APP
```

打完**重启 DSH 桌面端**（会一并重启 bridge 插件与连接器）。

## 维护提醒

DSH 升级会覆盖这两个文件 ⇒ **升级后重跑一次**（脚本幂等，且会在锚点对不上时**明确报错**
而不是改坏文件）。锚点是按 DSH 当前版本写的；若某天报「找不到锚点」，
说明 DSH 改过那几行，需要重新定位（脚本会告诉你是哪一条）。

## 实现细节（踩过的坑）

1. **换行风格不一致**：`index.js` 是 LF，`runtime.py` 是 **CRLF** ⇒ 锚点按目标文件风格转换后再匹配。
2. **增量补丁的判定顺序**：`to` = `from` + 若干行 ⇒ 打完 `from` 仍命中，必须**先判 `to`**，
   否则刚打完就自报「无法判断」（第一版就是这个毛病）。
3. **别把重复块留在文件里**：中途改过 `to` 文本又 `--revert`，旧块没被撤掉 → 出现两份
   `list_commands`。脚本现在对每条补丁都做「已打/未打/找不到」三态判定，跑完请 `--check` 复核。
