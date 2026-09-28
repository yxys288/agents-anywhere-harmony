/**
 * 公告（`RemoteRuntimeNotice`）的**分类与投放位置**判定（R50）。
 *
 * 对应上游 Android `feature/sessiondetail/SessionRuntimeState.kt:180-205`：
 * ```kotlin
 * val respondable = type == "interaction" && responseRequired && status in {open, failed} && actions.any { actionId.isNotBlank() }
 * val openInteraction = type == "interaction" && status in {open, responding, response_accepted, resolving, failed}
 * val openNotification= type == "notification" && status == "open"
 * fun blocksSession(sessionId) = blocking?.scope == "session" && blocking.targetId == sessionId
 * ```
 * 以及两个**投放位置**（上游 `SessionDetailScreen.kt:1353-1361` 与 `SessionMessages.kt:278-285`）：
 *  · **阻塞公告**（`openInteraction && blocksSession`）→ 钉在**输入区上方**的 `BlockingRuntimeNoticeStack`；
 *  · 其余（`openInteraction && !blocksSession` + `openNotification`）→ 进**时间线**。
 *
 * ⚠️ 本工程原先只做了 `status === 'open'` 一个条件，把**所有**公告都塞进时间线**顶部** ——
 * 而时间线默认停在最新消息（R37 十改），于是「Agent 提问」这种阻塞公告**在屏幕外**，
 * 用户看到的就是「手机没弹窗 / 不显示提问框」（真机实测）。
 *
 * ⚠️ 本文件零 ArkUI / 零 @kit 依赖，可被 `tools/logic-test/suite-notice-gating.mjs` 直接断言。
 */

import { RemoteRuntimeNotice } from './Types';

/** 公告类型：交互（审批 / 提问）。 */
export const NOTICE_TYPE_INTERACTION: string = 'interaction';
/** 公告类型：通知（纯告知，无动作）。 */
export const NOTICE_TYPE_NOTIFICATION: string = 'notification';
/** 「还开着」的交互状态（上游 `OPEN_INTERACTION_STATUSES`）。 */
export const OPEN_INTERACTION_STATUSES: string[] = [
  'open', 'responding', 'response_accepted', 'resolving', 'failed'
];
/** 「可以响应」的状态（上游 `RESPONDABLE_NOTICE_STATUSES`）。 */
export const RESPONDABLE_NOTICE_STATUSES: string[] = ['open', 'failed'];

/** 是不是**还开着**的交互公告（审批 / 提问）。 */
export function isOpenInteraction(notice: RemoteRuntimeNotice): boolean {
  return notice.type === NOTICE_TYPE_INTERACTION && OPEN_INTERACTION_STATUSES.indexOf(notice.status) >= 0;
}

/** 是不是还开着的通知公告。 */
export function isOpenNotification(notice: RemoteRuntimeNotice): boolean {
  return notice.type === NOTICE_TYPE_NOTIFICATION && notice.status === 'open';
}

/**
 * 这条公告是否**阻塞整个会话**（`blocking.scope === 'session'` 且目标就是本会话）。
 *
 * 连接器给审批与提问都带 `blocking = {scope:'session', targetId: sessionId}`（见
 * `connector/connector/runtimes/claude/domain/input_requests.py` 的 `input_request_notice`）。
 */
export function blocksSession(notice: RemoteRuntimeNotice, sessionId: string): boolean {
  const blocking = notice.blocking;
  if (blocking === undefined) {
    return false;
  }
  return blocking.scope === 'session' && blocking.targetId === sessionId;
}

/** 这条公告现在能不能响应（上游 `respondable`）。 */
export function isRespondable(notice: RemoteRuntimeNotice): boolean {
  if (notice.type !== NOTICE_TYPE_INTERACTION || !notice.responseRequired) {
    return false;
  }
  if (RESPONDABLE_NOTICE_STATUSES.indexOf(notice.status) < 0) {
    return false;
  }
  for (let i = 0; i < notice.actions.length; i++) {
    if (notice.actions[i].actionId.length > 0) {
      return true;
    }
  }
  return false;
}

/**
 * **钉在输入区上方**的那些公告（上游 `blockingNotices`）：
 * `openInteraction && blocksSession`，按 `updatedSeq` 再按 `noticeId` 升序。
 *
 * 排序不是装饰：上游 `BlockingRuntimeNoticeStack` 只渲染**第一个**（`notices.first()`），
 * 其余作为「压在后面的卡片」做视觉堆叠 ⇒ 顺序决定用户先看到哪一条。
 */
export function blockingNotices(notices: RemoteRuntimeNotice[], sessionId: string): RemoteRuntimeNotice[] {
  const result: RemoteRuntimeNotice[] = [];
  for (let i = 0; i < notices.length; i++) {
    const notice = notices[i];
    if (isOpenInteraction(notice) && blocksSession(notice, sessionId)) {
      result.push(notice);
    }
  }
  return sortNotices(result);
}

/** 进**时间线**的那些公告（上游 `SessionMessages` 的 `detachedNotices` 口径）。 */
export function timelineNotices(notices: RemoteRuntimeNotice[], sessionId: string): RemoteRuntimeNotice[] {
  const result: RemoteRuntimeNotice[] = [];
  for (let i = 0; i < notices.length; i++) {
    const notice = notices[i];
    if (isOpenInteraction(notice)) {
      if (!blocksSession(notice, sessionId)) {
        result.push(notice);
      }
    } else if (isOpenNotification(notice)) {
      result.push(notice);
    }
  }
  return sortNotices(result);
}

/** 上游的排序：`compareBy { updatedSeq }.thenBy { noticeId }`。 */
function sortNotices(list: RemoteRuntimeNotice[]): RemoteRuntimeNotice[] {
  const copy: RemoteRuntimeNotice[] = list.slice();
  copy.sort((a: RemoteRuntimeNotice, b: RemoteRuntimeNotice) => {
    if (a.updatedSeq !== b.updatedSeq) {
      return a.updatedSeq - b.updatedSeq;
    }
    return a.noticeId < b.noticeId ? -1 : (a.noticeId > b.noticeId ? 1 : 0);
  });
  return copy;
}
