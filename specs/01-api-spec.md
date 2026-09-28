# Agents Anywhere v2 API 契约（鸿蒙端实现依据）

来源：上游 `Agents-Anywhere/android`（Kotlin）调用点 + `server/agent_server/api/*.py` 路由与
`docs/api/*.md` 交叉核对。本文件是 `aa-hm` 各 `api/*.ets` 的对照契约。

## 1. 服务器寻址

- 所有产品端点挂在 `/api/v2` 下。
- **老部署兼容**：客户端首次请求会同时尝试 `namespaced` 与 `legacy`（去掉 `/api/v2` 前缀）
  两个候选；命中后把该 origin 的路由风格记在内存里，后续只用命中的那个。
  触发回退的条件：HTTP 405、或非 JSON 内容类型且（404 或 成功但返回 HTML）。
- `normalizeServerOrigin` 规则（`api/ApiUrls.ets`）：
  - 去首尾空白、裁掉尾部 `/`；
  - 无 scheme 时：局域网主机或带端口 → `http`，否则 `https`；
  - 只接受 `http`/`https`；带 userinfo / query / fragment 一律非法；
  - 路径只允许为空或 `/api/v2`；输出 `scheme://host[:port]`（host 小写）。
- 局域网判定：`localhost` / `::1` / `*.local` / `10.x` / `127.x` / `192.168.x` / `172.16-31.x`。
- WS 地址由 HTTP 地址派生：`https→wss`、`http→ws`。
- 必带请求头：`Accept: application/json`、`ngrok-skip-browser-warning: true`、
  有 token 时 `Authorization: Bearer <token>`。
- 超时：连接 10s；读 15s（`create-and-start` 为 75s，多部分上传 60s）。

## 2. 端点表（客户端实际调用）

| 方法 | 路径 | 认证 | 说明 |
| --- | --- | --- | --- |
| GET | `/health` | 否 | `{status:"ok", version}` — 也用于更新检查 |
| GET | `/auth/config` | 否 | `needsBootstrap/registrationOpen/oauthEnabled/oauthProviderLabel/emailVerificationRequired` |
| POST | `/auth/login` | 否 | `{email,password}` → `AuthResponse` |
| POST | `/auth/register` | 否 | `{email,password,displayName?}` → `AuthResponse` |
| GET | `/auth/me` | 是 | `{userId,role,disabled,avatar?,email?,displayName,emailVerified,serverTime}` |
| PUT | `/auth/me/profile` | 是 | `{displayName}` |
| PUT | `/auth/me/avatar` / DELETE | 是 | `{avatar}` / 清除 |
| PUT | `/auth/me/email` | 是 | `{email, code?}` |
| POST | `/auth/email-code` | 是 | `{email, purpose:"bind"}` → `{expiresIn,retryAfter}` |
| POST | `/auth/change-password` | 是 | `{newPassword}` |
| POST | `/oauth/token` | 否 | form：`grant_type=authorization_code, code, client_id=agents-anywhere-mobile, redirect_uri=agents-anywhere://oauth/callback, code_verifier` |
| POST | `/auth/mobile-login/request` | 否 | `{userId,loginToken,deviceName?}` → `MobileLoginStatus` |
| POST | `/auth/mobile-login/status` | 否 | `{loginToken}` → `MobileLoginStatus` |
| POST | `/auth/mobile-login/exchange` | 否 | `{userId,loginToken}` → `{auth,refreshToken,expiresAt,serverTime}` |
| POST | `/ws-ticket` | 是 | `{clientId, scope:{dashboard:true}}` 或 `{clientId, scope:{sessionId}}` → `{ticket,expiresAt,serverTime}` |
| GET | `/connectors` | 是 | `{connectors:[...]}`；query 里叫 connector，客户端叫 device |
| GET/PATCH/DELETE | `/connectors/{id}` | 是 | `{connector}` |
| POST | `/connectors` | 是 | `{name}` → `{connector, connectorToken, tokenPrefix?}` |
| POST | `/connectors/{id}/revoke` | 是 | 重新签发 token |
| GET | `/connectors/{id}/runtimes` | 是 | `{connectorId, runtimes:[...]}`（客户端会过滤非法 runtimeType/runtimeId） |
| POST | `/connectors/{id}/runtimes/discover` | 是 | 同上 |
| PUT | `/connectors/{id}/runtimes/{rid}/config` | 是 | `{config}` |
| DELETE | `/connectors/{id}/runtimes/{rid}/config` | 是 | 清除配置 |
| PUT | `/connectors/{id}/runtimes/{rid}/active` | 是 | `{active}` |
| GET | `/connectors/{id}/runtimes/{rid}/capabilities` | 是 | `{connectorId, capabilitySet, serverTime}` |
| GET | `/connectors/{id}/runtimes/{rid}/catalogs/model` \| `/permission` | 是 | `{catalog, serverTime}` |
| POST | `/pairing/claim` | 是 | `{code,name,serverUrl,connectorId,connectorToken}` → `{connector}` |
| GET | `/projects` | 是 | `{projects:[...]}` |
| POST | `/projects` | 是 | `{name,connectorId,workspacePath,manuallyCreated}` → `{project,attachedSessions}` |
| PATCH | `/projects/{id}` | 是 | `{name?,pinned?}` |
| GET | `/projects/{id}/sessions` | 是 | `?archived=&limit=&cursor=` → `{sessions,hasMore,nextCursor}` |
| POST | `/projects/{id}/sessions/archive-all` | 是 | `{archived,scope}` |
| GET | `/sessions` | 是 | `?archived=&limit=&cursor=` |
| POST | `/sessions/create-and-start` | 是 | 见 §3；读超时 75s |
| GET/PATCH | `/sessions/{id}/meta` | 是 | `{session}`；PATCH `{title?,pinned?,archived?}` |
| POST | `/sessions/archive` \| `/unarchive` \| `/read` | 是 | body 为 **字符串数组**（sessionId 列表）→ `{sessions,notFound}` |
| POST | `/connectors/{id}/sessions/archive-all` | 是 | `{archived,scope}` |
| GET | `/sessions/{id}/snapshot` | 是 | `?limit=` → 见 §4 |
| GET | `/sessions/{id}/timeline` | 是 | `?mode=history&beforeOrderSeq=&limit=` 或 `?mode=changes&afterSeq=&limit=` |
| GET | `/sessions/{id}/runtime/state` | 是 | `{state,serverTime}` |
| GET | `/sessions/{id}/runtime/capabilities` | 是 | `{capabilitySet,...}` |
| GET | `/sessions/{id}/runtime/notices` | 是 | `{notices,serverTime}` |
| POST | `/sessions/{id}/runtime/notices/{nid}/respond` | 是 | `{actionId, input?}` → `{ok, error?}` |
| GET | `/sessions/{id}/runtime/catalogs/model` \| `/permission` | 是 | `{catalog}` |
| PATCH | `/sessions/{id}/runtime/selections` | 是 | `{selections:{scope:selectionId}}`（值可为 null） |
| GET/POST | `/sessions/{id}/runtime/commands` | 是 | 列表 / `{command,args?,raw?}` |
| POST | `/sessions/{id}/runtime/messages` \| `/steer` | 是 | `{content, clientMessageId, attachments?:[{fileId}]}` → `{ok,error?}` |
| POST | `/sessions/{id}/runtime/interrupt` | 是 | `{}` → `{ok,error?}` |
| POST/DELETE | `/sessions/{id}/takeover` | 是 | → `{session}` |
| POST | `/sessions/{id}/shares` | 是 | `{scope,itemIds}` |
| POST | `/sessions/{id}/attachments` | 是 | multipart，字段名 `files` → `{attachments:[{fileId,name,mediaType,size,sha256}]}` |
| GET | `/sessions/{id}/attachments/{fid}` | 是 | `{fileId,sessionId,path,name,size,sha256,contentBase64,createdAt}` |
| GET | `/sessions/{id}/attachments/{fid}/open` | 否（走 URL） | 浏览器直开 |
| POST | `/connectors/{id}/fs/list` | 是 | `{root,path}` → `{result:{path,entries:[{name,path,type,size?}],truncated,targetType}}` |
| POST | `/connectors/{id}/fs/readText` | 是 | `?root=` + `{path,maxBytes}` → `{path,name,size,sha256,encoding,content,truncated,binary,serverTime}` |
| POST | `/connectors/{id}/terminals-v2` | 是 | `?root=` + `{cols,rows,cwd,ephemeralGroupId,label}` → `{result:{terminalId,...}}` |
| GET | `/connectors/{id}/terminals-v2` | 是 | → `{result:{terminals:[...]}}` |
| DELETE | `/connectors/{id}/terminals-v2/{tid}` | 是 | 关闭终端 |
| WS | `/connectors/{id}/terminals-v2/{tid}/stream` | token 走 query | `?fromSeq=&token=`，见 §8 |

## 3. `create-and-start` 请求体

```json
{
  "connectorId": "…", "projectId": "…", "runtime": "codex",
  "runtimeId": "rti_…",            // 仅当 != runtime 时带上
  "content": "…", "title": "…", "cwd": "…",
  "selections": { "model": "…" },  // 空串值会被剔除，全空则不带
  "attachments": [ { "fileId","name","mediaType","size","sha256","contentBase64" } ],
  "clientMessageId": "…"
}
```
响应 `{ session }`。

## 4. `snapshot` 响应

```json
{
  "session": { …SessionMeta… },
  "state": { …RuntimeState… },
  "timeline": { "items": [ …TimelineItem… ], "nextSeq": 0, "hasMore": false },
  "notices": [ …Notice… ],
  "effectiveCapabilities": { "revision": 0, "capabilities": [] },
  "runtimeCapabilities": { "revision": 0, "capabilities": [] },
  "catalogs": { "model": {…}, "permission": {…} },   // 兼容壳，可能为空
  "eventCursor": "seq:0",
  "serverTime": "…"
}
```

`TimelineItem`：`{id,sessionId,type,status,role?,content,source,orderSeq,revision,updatedSeq,createdAt,updatedAt?,contentHash?}`。
客户端把正文从 `content.text | content.message | content.description` 三级回退。

## 5. 会话实时通道

- 票据：`POST /ws-ticket`，scope 为 `{sessionId}`。
- WS：`/api/v2/sessions/{id}/ws?ticket=…`
- 事件信封：`{protocolVersion,eventId,sequence,cursor,type,sessionId,emittedAt,payload}`
- 事件类型：
  `session.subscribed`、`session.meta.updated`、`timeline.item_created`、`timeline.item_updated`、
  `timeline.snapshot`、`runtime.state.updated`、`runtime.notice.snapshot`、`runtime.notice.updated`、
  `runtime.capability.updated`、`runtime.catalog.updated`、`runtime.refetch_required`、
  `session.refetch_required`；心跳 `keepalive`（客户端忽略）。
- payload 字段：`session`、`item`、`items`、`state`、`notice`、`notices`、`capabilitySet`、
  `catalogType`+`catalog`、`eventCursor`。
- 恢复：`GET /sessions/{id}/events?after=seq:N` → `{events,nextCursor,snapshotRequired}`；
  最多 8 页；`snapshotRequired=true` 才重新拉 snapshot。
- 客户端重连退避：`base = min(1000 << attempt, 30000)`，加 `base*0.25*rand` 抖动，上限 30s；
  连接成功则 attempt 归零。
- 事件合批窗口 34ms（≈30Hz），时间线 item 为 upsert-only。

## 6. 工作台实时通道

- 票据 scope：`{dashboard:true}`；WS：`/api/v2/dashboard/ws?ticket=…`
- 连接即收到 `dashboard.snapshot`，字段：
  `{type, connectors:[…], projects:[…], sessions:[…], sessionPages:{active:{hasMore,nextCursor},archived:{…}}, serverTime}`。
- 服务端做了去抖，变更时再推一份**全量**快照；客户端不做增量合并。

## 7. 错误约定

- 非 2xx 时按顺序尝试解析 `detail`：字符串 → 直接用；对象 → `message` 优先，其次 `code`；
  数组 → `[{msg}]`。都取不到用状态码兜底文案。
- 401 且请求带了 token ⇒ 触发「清登录态」回调；**只有当回调带回来的 token 与当前存储一致时才清**
  （避免并发请求互相覆盖）。
- HTTP 客户端错误码：`ApiException{message,statusCode?,errorCode?}`。

## 8. 终端线协议

所有帧都是 **JSON 文本**，PTY 字节用 base64 放在 `data` 里。

服务端 → 客户端：

```json
{"type":"replay","data":"<base64>","seq":123}
{"type":"output","data":"<base64>","seq":124}
{"type":"exit","exitCode":0,"reason":"exit"}
{"type":"error","code":500,"message":"…"}
{"type":"pong"}
```

客户端 → 服务端：

```json
{"type":"input","data":"<base64>"}
{"type":"resize","cols":120,"rows":40}
{"type":"ping"}
```

- 连接时用 `fromSeq` 续传；`replay` 是历史回放，之后是 `output` 增量。
- 认证 token 走 query（`?token=`），服务端也接受 `Authorization: Bearer`。

## 9. 更新检查

`GET /health` 的 `version` 与本地版本号做**逐段数值比较**（缺省段补 0）；
支持 `v` 前缀与 `-beta.1` 后缀（后缀忽略）；任一段非数字则判为格式错误。
服务端版本更高才提示更新。

## 10. ArkTS 移植差异

| Android 侧 | 鸿蒙侧 | 原因 |
| --- | --- | --- |
| OkHttp 连接池 | 每次 `http.createHttp()`/`destroy()` | 鸿蒙 http 模块自带连接复用，避免句柄泄漏 |
| OkHttp `FormBody` | 手拼 `x-www-form-urlencoded` | 无对应封装 |
| OkHttp `MultipartBody` | 手拼 `multipart/form-data` 字节流 | 无对应封装 |
| OkHttp WebSocket | `@kit.NetworkKit` `webSocket` | 回调签名不同（`on('open'/'message'/'close'/'error')`） |
| `org.json` 的 `optXxx` | `api/Parse.ets` 的读取助手 | ArkTS 无等价 API，且需显式类型 |
| `SharedPreferences` | `@kit.ArkData` `preferences`（同步接口） | 数据量极小，同步更简单 |
| `SecureRandom` + Base64 | `cryptoFramework` 摘要 + 手写 base64url | PKCE 挑战 |
| Termux `TerminalView` | 自研 `vt/*` + Canvas 网格渲染 | 见 `PROJECT.md` |
