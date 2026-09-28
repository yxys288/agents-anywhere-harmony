/**
 * 编译覆盖探针：ArkTS 只对「被入口可达」的模块做类型检查，
 * 未被引用的文件即使有类型错误也不会报错。本文件把所有模块都引用一遍，
 * 保证 `assembleHap` 能真正校验全量源码。新增模块后请在此登记。
 */

import { ApiClient } from '../api/ApiClient';
import { apiPath, apiUrl, apiUrlCandidates, normalizeServerOrigin, usesLocalNetworkHost, webSocketApiUrl } from '../api/ApiUrls';
import { AuthApi, accountLabel } from '../api/AuthApi';
import { DevicesApi } from '../api/DevicesApi';
import { FilesApi } from '../api/FilesApi';
import { SessionsApi } from '../api/SessionsApi';
import { TerminalApi } from '../api/TerminalApi';
import { RealtimeApi, reconnectDelayMillis, newRealtimeClientId } from '../api/RealtimeApi';
import { eventCursorSequence, capabilityUsable, parseSession } from '../api/Parse';
import { compareProjects, compareSessions, relativeTimeLabel, runtimeTypeLabel } from '../model/AppModels';
import { isTextPreviewable as isPreviewableText, textExtensionCount } from '../model/TextFiles';
import { base64Decode, base64Encode, newClientMessageId, sha256Hex } from '../utils/Codec';
import { base64UrlNoPadding, sha256, utf8Bytes } from '../utils/Sha256';
import { initAppPrefs, hasAuthSession, readServerUrl, clearAuthSession } from '../store/AuthSessionStore';
import { TerminalEmulator, TerminalOutput } from '../vt/TerminalEmulator';
import { TerminalBuffer } from '../vt/TerminalBuffer';
import { TerminalRow } from '../vt/TerminalRow';
import { TerminalStylePool, defaultColorScheme } from '../vt/TerminalStyle';
import { codePointWidth, isWide } from '../vt/WcWidth';
import { DEFAULT_EXTRA_KEYS, ctrlSequence, resolveExtraKey } from '../vt/KeyHandler';
import { AppServices, AppearanceController, authController, parseMobileLoginQr } from '../feature/AppServices';
import { DashboardStore } from '../feature/DashboardStore';
import { AttachmentStore } from '../feature/AttachmentStore';
import { SessionPagingState, emptyPagingState, canLoadMore } from '../model/SessionPaging';
import { ComposerDraftStore, ComposerDraft, draftKey, isDraftEmpty, decodeDraft } from '../store/ComposerDraftStore';
import { SessionDetailStore } from '../feature/SessionDetailStore';
import { TerminalStore } from '../feature/TerminalStore';
import { FilesStore, parentPath, isTextPreviewable, formatBytes } from '../feature/FilesStore';
import { DeviceStore } from '../feature/DeviceStore';
import { projectTimeline, mergeTimelineItems, splitCodeBlocks } from '../feature/TimelineProjection';
import {
  connectionStatusLabel, messageStatusFailed, messageStatusLabel, runtimeStateStatusLabel
} from '../model/StatusLabels';

export interface CompileProbeReport {
  entries: number;
  summary: string;
}

/** 只做数据类型层面的引用，不产生副作用；用于构建期自检。 */
export function compileProbe(client: ApiClient): CompileProbeReport {
  const auth = new AuthApi(client);
  const devices = new DevicesApi(client);
  const files = new FilesApi(client);
  const sessions = new SessionsApi(client);
  const terminal = new TerminalApi(client);
  const realtime = new RealtimeApi(client);

  // 函数引用（不能对 class 取 typeof，见 arkts-no-classes-as-obj）
  const functions: Function[] = [
    auth.me, devices.listDevices, files.listFiles, sessions.listSessions,
    terminal.createTerminal, realtime.createSessionTicket, accountLabel,
    apiPath, apiUrl, apiUrlCandidates, normalizeServerOrigin,
    usesLocalNetworkHost, webSocketApiUrl, reconnectDelayMillis,
    newRealtimeClientId, eventCursorSequence, capabilityUsable,
    parseSession, compareSessions, compareProjects, relativeTimeLabel,
    runtimeTypeLabel, base64Decode, base64Encode, sha256Hex,
    newClientMessageId, initAppPrefs, hasAuthSession, readServerUrl,
    clearAuthSession, defaultColorScheme, codePointWidth, isWide,
    ctrlSequence, resolveExtraKey, parseMobileLoginQr,
    projectTimeline, mergeTimelineItems, splitCodeBlocks,
    parentPath, isTextPreviewable, formatBytes, authController.markSignedOut,
    sha256, sha256Hex, utf8Bytes, base64UrlNoPadding,
    isPreviewableText, textExtensionCount,
    canLoadMore, draftKey, isDraftEmpty, decodeDraft,
    messageStatusLabel, messageStatusFailed, connectionStatusLabel, runtimeStateStatusLabel
  ];
  // 类引用：放进一个**从不调用**的函数体里实例化，模块照样被编译与类型检查
  if (probeNeverCalled()) {
    probeInstantiate(probeOutput());
    probeAttachmentStore();
  }
  const report: CompileProbeReport = {
    entries: functions.length + DEFAULT_EXTRA_KEYS.length,
    summary: `probe ok (${functions.length} fns)`
  };
  return report;
}

/** 把附件 store 也拖进类型检查图（它的类型错误同样必须在构建期暴露）。 */
function probeAttachmentStore(): void {
  const store = AttachmentStore.get();
  store.onChange(() => {
  });
  store.ensure('sess', 'file', 'image/png', 'a.png');
  store.reset();
}

/** 恒返回 false：让下面的实例化分支永远不执行，只用于拉入类型检查。 */
function probeNeverCalled(): boolean {
  return false;
}

function probeOutput(): TerminalOutput {
  const write = (data: string): void => {
  };
  const titleChanged = (title: string): void => {
  };
  const clipboardCopy = (text: string): void => {
  };
  const bell = (): void => {
  };
  const invalidate = (): void => {
  };
  const output: TerminalOutput = {
    write: write,
    titleChanged: titleChanged,
    clipboardCopy: clipboardCopy,
    bell: bell,
    invalidate: invalidate
  };
  return output;
}

function probeInstantiate(output: TerminalOutput): void {
  const pool = new TerminalStylePool();
  const row = new TerminalRow(80);
  const buffer = new TerminalBuffer(80, 24);
  const emulator = new TerminalEmulator(80, 24, output, true);
  const services = AppServices.get();
  const dashboard = DashboardStore.get();
  const detail = SessionDetailStore.get();
  const terminalStore = TerminalStore.get();
  const filesStore = FilesStore.get();
  const deviceStore = DeviceStore.get();
  AppearanceController.init();
  if (pool.size() < 0 || row.spaceUsed < 0 || buffer.screenRows < 0 || emulator.columns < 0 ||
    services.realtimeClientId.length < 0 || dashboard.error.length < 0 || detail.sessionId.length < 0 ||
    terminalStore.cols < 0 || filesStore.root.length < 0 || deviceStore.deviceId.length < 0) {
    return;
  }
  resolveExtraKey(DEFAULT_EXTRA_KEYS[0], emulator, false, false);
  probeRound8Stores();
}

/** 第八轮新增模块：分页状态机（model/SessionPaging）与输入草稿存储（store/ComposerDraftStore）。 */
function probeRound8Stores(): void {
  const paging: SessionPagingState = emptyPagingState();
  if (canLoadMore(paging, false)) {
    return;
  }
  const drafts = new ComposerDraftStore();
  const restored: ComposerDraft = drafts.restore('probe-session');
  if (restored.text.length < 0 || isDraftEmpty(restored.text, restored.attachments)) {
    return;
  }
}
