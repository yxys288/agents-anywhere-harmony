/**
 * 上下文用量（「上下文圆环」的数据层，R52）。
 *
 * 数据从哪来：DSH 的 token-meter 投影 `contextPressure`，经 **DSH bridge 补丁**放进
 * `session.getState` 的 `metadata`（见 `tools/dsh-bridge-patch/patch.mjs`），
 * 再由 AA 服务端原样透传、客户端 `parseRuntimeState` 解析成 `runtimeState.metadata`。
 *
 * 形状（DSH `dsh-token-meter/lib/types/usage-projection.js:68-78` 的 `contextPressureStateSchema`）：
 *  { contextWindow?: number, pressureTokens?: number, surfaceTokens: number, sampledSurfaceTokens?: number }
 *  · `surfaceTokens`：当前请求实际带上去的上下文 token 数（**一定有**）；
 *  · `pressureTokens`：触发压缩的阈值口径（有就用它，没有就退回 surfaceTokens）；
 *  · `contextWindow`：模型上下文窗口（**可能没有** —— 没拿到窗口就不画圆环，别瞎猜分母）。
 *
 * ⚠️ 本文件零 ArkUI / 零 @kit 依赖，可被 `tools/logic-test/suite-context-usage.mjs` 直接断言。
 */

import { JsonMap } from './Types';

/** `metadata` 里那个键（与 bridge 补丁写入的键名逐字一致）。 */
export const CONTEXT_PRESSURE_KEY: string = 'contextPressure';

/** 圆环的告警档位阈值（占比）。 */
export const CONTEXT_WARN_RATIO: number = 0.7;
export const CONTEXT_CRITICAL_RATIO: number = 0.9;

export interface ContextUsage {
  /** 已知窗口大小；为 0 表示**不知道** ⇒ 调用方不要画圆环。 */
  windowTokens: number;
  /** 已占用 token（`pressureTokens` 优先，否则 `surfaceTokens`）。 */
  usedTokens: number;
  /** 占比，已夹到 [0,1]（服务端给的数据可能有噪声，别让圆环画出界）。 */
  ratio: number;
  /** 'ok' | 'warn' | 'critical'。 */
  level: string;
  /** 是否可用（窗口 > 0 且占用 >= 0）。 */
  known: boolean;
}

function num(value: Object | undefined): number {
  if (typeof value !== 'number' || !isFinite(value as number)) {
    return 0;
  }
  const n = value as number;
  return n > 0 ? n : 0;
}

function asMap(value: Object | undefined): JsonMap | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as JsonMap;
}

/** 空用量（画不出来时用它，`known === false`）。 */
export function emptyContextUsage(): ContextUsage {
  return { windowTokens: 0, usedTokens: 0, ratio: 0, level: 'ok', known: false };
}

/**
 * 从 `runtimeState.metadata` 解析用量。
 *
 * 容错口径（这条数据是**可选**的，任何一环缺失都只该让圆环消失，不该让页面出错）：
 *  · 没有 `contextPressure` ⇒ unknown；
 *  · 没有 `contextWindow` ⇒ unknown（**不猜分母**：猜小了会天天红、猜大了永远绿，都是骗人）；
 *  · 只有 `surfaceTokens`、没有 `pressureTokens` ⇒ 用 surfaceTokens 当占用。
 */
export function contextUsageFrom(metadata: JsonMap | undefined): ContextUsage {
  if (metadata === undefined) {
    return emptyContextUsage();
  }
  const pressure = asMap(metadata[CONTEXT_PRESSURE_KEY]);
  if (pressure === undefined) {
    return emptyContextUsage();
  }
  const windowTokens = num(pressure['contextWindow']);
  if (windowTokens <= 0) {
    return emptyContextUsage();
  }
  const pressureTokens = num(pressure['pressureTokens']);
  const surfaceTokens = num(pressure['surfaceTokens']);
  const usedTokens = pressureTokens > 0 ? pressureTokens : surfaceTokens;
  const ratio = clampRatio(usedTokens / windowTokens);
  return {
    windowTokens: windowTokens,
    usedTokens: usedTokens,
    ratio: ratio,
    level: contextLevel(ratio),
    known: true
  };
}

function clampRatio(value: number): number {
  if (!isFinite(value) || value <= 0) {
    return 0;
  }
  return value >= 1 ? 1 : value;
}

/** 档位：≥90% critical、≥70% warn、其余 ok。 */
export function contextLevel(ratio: number): string {
  if (ratio >= CONTEXT_CRITICAL_RATIO) {
    return 'critical';
  }
  if (ratio >= CONTEXT_WARN_RATIO) {
    return 'warn';
  }
  return 'ok';
}

/** 千分位压缩：1234 ⇒ 1.2k、123456 ⇒ 123k（圆环旁的文字用它）。 */
export function compactTokens(value: number): string {
  if (!isFinite(value) || value <= 0) {
    return '0';
  }
  if (value < 1000) {
    return String(Math.round(value));
  }
  const thousands = value / 1000;
  if (thousands < 100) {
    return (Math.round(thousands * 10) / 10).toString() + 'k';
  }
  return String(Math.round(thousands)) + 'k';
}

/** 圆环旁/无障碍用的文字：`12.3k / 200k（6%）`；未知时返回空串。 */
export function contextUsageLabel(usage: ContextUsage): string {
  if (!usage.known) {
    return '';
  }
  const percent = Math.round(usage.ratio * 100);
  return `${compactTokens(usage.usedTokens)} / ${compactTokens(usage.windowTokens)}（${percent}%）`;
}
