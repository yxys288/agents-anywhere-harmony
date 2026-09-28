/**
 * 「Agent 向用户提问」的**纯逻辑层**（R50）。
 *
 * 对应上游 Android：
 *  - `feature/sessiondetail/SessionRuntimeState.kt`：`RuntimeInputRequestForm` / `RuntimeInputRequestQuestion` /
 *  `RuntimeInputRequestOption` / `RuntimeInputRequestDraft`，以及 `inputRequestForm()` /
 *  `initialDrafts()` / `isComplete()` / `buildPayload()`；
 *  - `ui/screens/sessiondetail/SessionRuntimeControls.kt`：`RuntimeInputRequestFields` /
 *  `RuntimeInputRequestQuestionFields` / `RuntimeInputRequestCustomAnswer` / `RuntimeInputRequestSelectionIndicator`。
 *
 * ⚠️ 本文件**零 ArkUI、零 @kit 依赖**（只 import 同目录的纯类型 `./Types`），
 * 因此可以被 `tools/logic-test/suite-input-request.mjs` 转译到 Node 里直接断言。
 *
 * ⚠️ 协议形状以**连接器源码**为准，不是照抄上游 UI 层的猜测：
 *  `connector/connector/runtime_protocol/interactions.py` 的 `InputRequestForm.action()` 产出
 *  `{ actionId:'submit', label:'Submit', style:'primary',
 *  input:{ required:true, schema:{...}, uiSchema:{ component:'inputRequest', version:1, questions:[...] } } }`；
 *  答案载荷 `{ answers: { <qid>: { optionIds:[...], customText? } } }` 由
 *  `connector/tests/dsh_question_probe.py` 端到端断言过。
 *
 * 为什么单独一层：本工程原先**只**实现了 `input.required` 的「单框兜底」（上游 `inputFields()` 的 fallback 分支），
 * 而 `input_request` 的提问表单**一条都没实现** ⇒ 真机上「Agent 提问时看不到提问框」。
 */

import { JsonMap, RemoteRuntimeNotice, RemoteRuntimeNoticeAction } from './Types';

/** `uiSchema.component` 的约定值（上游 `inputRequestForm()` 里逐字比较）。 */
export const INPUT_REQUEST_COMPONENT: string = 'inputRequest';
/** `uiSchema.version` 的约定值（只认 1；未知版本一律不渲染，避免把新协议渲染成半成品）。 */
export const INPUT_REQUEST_VERSION: number = 1;
/** `notice.interactionType` 的约定值。 */
export const INPUT_REQUEST_INTERACTION: string = 'input_request';

/** 一个可选项（上游 `RuntimeInputRequestOption`）。 */
export interface InputRequestOption {
  id: string;
  label: string;
  description?: string;
}

/** 一道题（上游 `RuntimeInputRequestQuestion`）。 */
export interface InputRequestQuestion {
  id: string;
  prompt: string;
  /** 题面上方的小标题（可选，12sp muted）。 */
  header?: string;
  /** 是否多选（决定指示器是方框还是圆圈，也决定能否多选）。 */
  multiple: boolean;
  /** 是否允许「其他」自由输入（连接器目前恒为 true）。 */
  allowCustom: boolean;
  options: InputRequestOption[];
}

/** 一张提问表单（上游 `RuntimeInputRequestForm`：动作 + 题目）。 */
export interface InputRequestForm {
  actionId: string;
  questions: InputRequestQuestion[];
}

/** 一道题的作答草稿（上游 `RuntimeInputRequestDraft`）。 */
export interface InputRequestDraft {
  optionIds: string[];
  customText: string;
  useCustom: boolean;
}

// ---------------------------------------------------------------------------
// 取值助手（JsonMap 里每个值都是 Object，逐层判型）
// ---------------------------------------------------------------------------

/** 非空字符串；其余（含空串 / 非字符串）返回 undefined。 */
function nonEmptyText(value: Object | undefined): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const text = value as string;
  return text.trim().length > 0 ? text : undefined;
}

/** 是「对象」（非 null、非数组）时返回它，否则 undefined。 */
function asMap(value: Object | undefined): JsonMap | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return undefined;
  }
  return value as JsonMap;
}

/** 是数组时返回它，否则 undefined。 */
function asList(value: Object | undefined): Object[] | undefined {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return undefined;
  }
  return value as Object[];
}

/** 取布尔；只有真的 `true` 才算 true（上游 `question["multiple"] == true`）。 */
function boolOrFalse(value: Object | undefined): boolean {
  return value === true;
}

// ---------------------------------------------------------------------------
// 表单解析（逐条对齐上游 `inputRequestForm()` 的**拒绝**语义）
// ---------------------------------------------------------------------------

/**
 * 从公告里取提问表单；不是提问请求（或形状不合规）时返回 `undefined`。
 *
 * ⚠️ 上游对**任何一个**不合规的题目 / 选项都是「整张表单一律不渲染」（Kotlin 里是 `return null` 的非局部返回），
 * 不是「跳过那一题」。这里保持同一语义：宁可退回「无表单」，也不要渲染一张少了一题的表单 ——
 * 少一题会让用户提交出去的 `answers` 缺键，服务端按 JSON Schema 直接 400。
 */
export function inputRequestForm(notice: RemoteRuntimeNotice): InputRequestForm | undefined {
  if (notice.interactionType !== INPUT_REQUEST_INTERACTION) {
    return undefined;
  }
  for (let i = 0; i < notice.actions.length; i++) {
    const action: RemoteRuntimeNoticeAction = notice.actions[i];
    const input = action.input;
    if (input === undefined) {
      continue;
    }
    const uiSchema = input.uiSchema;
    if (uiSchema === undefined) {
      continue;
    }
    // component / version 不匹配 ⇒ 换下一个 action（上游是 `return@forEach`，与「整表单作废」不同）。
    if (nonEmptyText(uiSchema['component']) !== INPUT_REQUEST_COMPONENT) {
      continue;
    }
    const version = uiSchema['version'];
    if (typeof version !== 'number' || version !== INPUT_REQUEST_VERSION) {
      continue;
    }
    const rawQuestions = asList(uiSchema['questions']);
    if (rawQuestions === undefined || rawQuestions.length === 0) {
      return undefined;
    }
    const questions = parseQuestions(rawQuestions);
    if (questions === undefined) {
      return undefined;
    }
    return { actionId: action.actionId, questions: questions };
  }
  return undefined;
}

/** 解析全部题目；任何一处不合规返回 undefined（= 整张表单作废）。 */
function parseQuestions(rawQuestions: Object[]): InputRequestQuestion[] | undefined {
  const questions: InputRequestQuestion[] = [];
  const seenQuestionIds: string[] = [];
  for (let i = 0; i < rawQuestions.length; i++) {
    const raw = asMap(rawQuestions[i]);
    if (raw === undefined) {
      return undefined;
    }
    const id = nonEmptyText(raw['id']);
    const prompt = nonEmptyText(raw['prompt']);
    if (id === undefined || prompt === undefined) {
      return undefined;
    }
    if (seenQuestionIds.indexOf(id) >= 0) {
      return undefined;
    }
    seenQuestionIds.push(id);
    const rawOptions = asList(raw['options']);
    if (rawOptions === undefined) {
      return undefined;
    }
    const options = parseOptions(rawOptions);
    if (options === undefined) {
      return undefined;
    }
    const question: InputRequestQuestion = {
      id: id,
      prompt: prompt,
      header: nonEmptyText(raw['header']),
      multiple: boolOrFalse(raw['multiple']),
      // 上游 `allowCustom = question["allowCustom"] != false`：**缺省视为允许**。
      allowCustom: raw['allowCustom'] !== false,
      options: options
    };
    questions.push(question);
  }
  return questions;
}

/** 解析一题的选项；id/label 缺失或重复返回 undefined。 */
function parseOptions(rawOptions: Object[]): InputRequestOption[] | undefined {
  const options: InputRequestOption[] = [];
  const seenOptionIds: string[] = [];
  for (let i = 0; i < rawOptions.length; i++) {
    const raw = asMap(rawOptions[i]);
    if (raw === undefined) {
      return undefined;
    }
    const id = nonEmptyText(raw['id']);
    const label = nonEmptyText(raw['label']);
    if (id === undefined || label === undefined) {
      return undefined;
    }
    if (seenOptionIds.indexOf(id) >= 0) {
      return undefined;
    }
    seenOptionIds.push(id);
    options.push({ id: id, label: label, description: nonEmptyText(raw['description']) });
  }
  return options;
}

// ---------------------------------------------------------------------------
// 草稿 / 完整性 / 载荷（逐条对齐上游同名函数）
// ---------------------------------------------------------------------------

/** 空草稿。 */
export function emptyDraft(): InputRequestDraft {
  return { optionIds: [], customText: '', useCustom: false };
}

/** 初始草稿：每题一份空草稿（上游 `initialDrafts()`）。 */
export function initialDrafts(form: InputRequestForm): Map<string, InputRequestDraft> {
  const drafts: Map<string, InputRequestDraft> = new Map<string, InputRequestDraft>();
  for (let i = 0; i < form.questions.length; i++) {
    drafts.set(form.questions[i].id, emptyDraft());
  }
  return drafts;
}

/**
 * 这张表单是否**可以提交**（上游 `isComplete()`）：
 * 每题都要「至少选中一个选项」**或**「选了其他且填了字」，且单选最多一个选项。
 */
export function isComplete(form: InputRequestForm, drafts: Map<string, InputRequestDraft>): boolean {
  for (let i = 0; i < form.questions.length; i++) {
    const question = form.questions[i];
    const draft = drafts.get(question.id);
    if (draft === undefined) {
      return false;
    }
    const optionCount = draft.optionIds.length;
    if (!question.multiple && optionCount > 1) {
      return false;
    }
    const hasOption = optionCount > 0;
    const hasCustom = draft.useCustom && draft.customText.trim().length > 0;
    if (!hasOption && !hasCustom) {
      return false;
    }
  }
  return true;
}

/**
 * 提交载荷（上游 `buildPayload()`）：
 * `{ answers: { <qid>: { optionIds: [...], customText? } } }` —— 与连接器
 * `InputRequestForm.parse_answers()` 的入参形状逐字一致（`customText` 只在「选了其他且非空」时出现）。
 */
export function buildPayload(form: InputRequestForm, drafts: Map<string, InputRequestDraft>): Record<string, Object> {
  const answers: Record<string, Object> = {};
  for (let i = 0; i < form.questions.length; i++) {
    const question = form.questions[i];
    const draft = drafts.get(question.id) ?? emptyDraft();
    const entry: Record<string, Object> = { 'optionIds': draft.optionIds.slice() };
    const custom = draft.customText.trim();
    if (draft.useCustom && custom.length > 0) {
      entry['customText'] = custom;
    }
    answers[question.id] = entry;
  }
  return { 'answers': answers };
}

// ---------------------------------------------------------------------------
// 交互（逐条对齐上游 `RuntimeInputRequestQuestionFields` 的 onClick / onChange）
// ---------------------------------------------------------------------------

/**
 * 点一个选项后的新草稿。
 *
 * ⚠️ 单选时**必须**把 `customText` 清空、`useCustom` 置回 false —— 连接器 `parse_answers()` 明确拒绝
 * 「单选同时给了 optionIds 和 customText」（`choose an option or custom text`），不清就会 400。
 */
export function toggleOption(question: InputRequestQuestion, draft: InputRequestDraft, optionId: string): InputRequestDraft {
  if (question.multiple) {
    const selected = draft.optionIds.indexOf(optionId) >= 0;
    const next: string[] = [];
    for (let i = 0; i < draft.optionIds.length; i++) {
      if (draft.optionIds[i] !== optionId) {
        next.push(draft.optionIds[i]);
      }
    }
    if (!selected) {
      next.push(optionId);
    }
    return { optionIds: next, customText: draft.customText, useCustom: draft.useCustom };
  }
  return { optionIds: [optionId], customText: '', useCustom: false };
}

/** 点「其他」那一行：单选要清掉已选选项，多选保留。 */
export function selectCustom(question: InputRequestQuestion, draft: InputRequestDraft): InputRequestDraft {
  return {
    optionIds: question.multiple ? draft.optionIds.slice() : [],
    customText: draft.customText,
    useCustom: true
  };
}

/** 在「其他」里打字：单选同样要清掉已选选项。 */
export function updateCustomText(question: InputRequestQuestion, draft: InputRequestDraft, text: string): InputRequestDraft {
  return {
    optionIds: question.multiple ? draft.optionIds.slice() : [],
    customText: text,
    useCustom: true
  };
}

/** 「其他」输入框的占位文案（上游 `R.string.session_input_request_other`）。 */
export const INPUT_REQUEST_OTHER_LABEL: string = '其他';
