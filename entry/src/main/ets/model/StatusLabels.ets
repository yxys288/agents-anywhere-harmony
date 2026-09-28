/**
 * 状态枚举 → 中文文案（R20 新增）。
 *
 * 为什么单独成文件：这三张表是**纯字符串映射**，零 ArkUI / 零 Kit 依赖，
 * 因此可以直接进 `tools/logic-test` 转译后断言（页面里的 `private` 方法做不到）。
 *
 * 背景（R20 实测）：并排图上一眼看到会话详情页把服务端枚举**原样**渲染了出来 ——
 * `connected`（WS 连接态）、`waiting_approval`（状态 chip）、`running`（消息状态）。
 * 页面里本来就有中文化入口（`sessionStatusLabel`），只是这几处漏了。
 */

/**
 * 消息状态文案。
 *
 * 上游对用户消息**只**在失败态显示文案、且已本地化（`SessionMessages.kt:1297-1300`：
 * `when (status) { "failed" -> stringResource(R.string.session_status_failed) }` ⇒「失败」）。
 * 本工程保留「活动状态」这层信息（上游用 Agent 活动行 `session_agent_working`
 * 「%1$s 正在处理」表达），但**一律走中文**；未知取值返回空串 ⇒ 调用方不渲染。
 */
export function messageStatusLabel(status: string): string {
  switch (status) {
    case 'failed': return '失败';
    case 'error': return '出错';
    case 'cancelled': return '已取消';
    case 'interrupted': return '已中断';
    case 'pending': return '排队中';
    case 'running': return '运行中';
    case 'waiting': return '等待中';
    case 'waiting_approval': return '待审批';
    default: return '';
  }
}

/** 失败类消息状态（上游 `SessionMessages.kt:984` 的 `failed/cancelled/interrupted`）—— 用错误色。 */
export function messageStatusFailed(status: string): boolean {
  return status === 'failed' || status === 'cancelled' || status === 'interrupted';
}

/**
 * WS 连接态文案（本工程自加的诊断信息；上游没有这条 UI）。
 * 用词对齐上游 `values-zh-rCN/strings.xml`：`device_setup_connected`「已连接」、
 * `home_offline`「离线」、`session_reconnect_summary`「正在重连：%1$s」⇒「重连中」。
 */
export function connectionStatusLabel(state: string): string {
  switch (state) {
    case 'connected': return '已连接';
    case 'connecting': return '连接中';
    case 'recovering': return '重连中';
    case 'offline': return '离线';
    default: return '未连接';
  }
}

/**
 * 会话级 Runtime 状态文案（本工程自加的诊断行；上游 `SessionRuntimeSettingsSheet` 里没有这一行）。
 *
 * ⚠️ 与 `ui/Design.ets:528` 的 `runtimeStatusLabel` **不是同一张表**：那张是**设备级** runtime
 * 的状态（`stopped/available/validating/...`），取值域不同，不能混用。
 * 未知取值返回空串（宁可少显示一行，也不裸露英文枚举）。
 */
export function runtimeStateStatusLabel(status: string): string {
  switch (status) {
    case 'idle': return '空闲';
    case 'ready': return '就绪';
    case 'running': return '运行中';
    case 'starting': return '启动中';
    case 'stopping': return '停止中';
    case 'error': return '出错';
    default: return '';
  }
}
