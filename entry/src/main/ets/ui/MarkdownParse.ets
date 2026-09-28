/**
 * 轻量 Markdown 的**纯解析**部分（不依赖 ArkUI，可进 Node 侧逻辑自测）。
 *
 * 渲染组件在 `ui/Markdown.ets`；这里只做「字符串 → 块/行内标记」，
 * 与 `vt/*` 一样按「纯逻辑单独放」的原则组织。
 */

import { SyntaxToken } from './SyntaxHighlight';

export enum MdBlockKind {
  PARAGRAPH = 'paragraph',
  HEADING = 'heading',
  BULLET = 'bullet',
  ORDERED = 'ordered',
  QUOTE = 'quote',
  CODE = 'code',
  /** 任务项 `- [ ] / - [x]`。 */
  TASK = 'task',
  /** 表格：`rows[0]` 是表头。 */
  TABLE = 'table',
  /** 分隔线 `---` / `***` / `___`。 */
  RULE = 'rule',
  /** 独立成段的图片 `![alt](url)`。 */
  IMAGE = 'image',
  /** 块级数学公式 `$$ ... $$`（原样等宽展示，不做 KaTeX 渲染）。 */
  MATH = 'math'
}

export interface MdBlock {
  kind: MdBlockKind;
  /** 标题层级 1~6；列表项＝缩进层级（0 起）；其它块为 0。 */
  level: number;
  /** 有序列表的序号。 */
  index: number;
  text: string;
  language: string;
  /** 任务项是否勾选（仅 `TASK`）。 */
  checked?: boolean;
  /** 表格内容，`rows[0]` 为表头（仅 `TABLE`）。 */
  rows?: string[][];
  /** 图片地址（仅 `IMAGE`）。 */
  url?: string;
  /** 图片替代文本（仅 `IMAGE`）；加载失败时降级显示它。 */
  alt?: string;
  /** 用于 ForEach 的稳定 key（含内容指纹，内容变了要重建）。 */
  key: string;
}

export interface MdInline {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  strike: boolean;
  /** 链接目标（`[文字](url)`）；非链接为 undefined。 */
  link?: string;
  /** 图片地址（`![alt](url)`）；非图片为 undefined。 */
  image?: string;
  /** 行内公式 `$...$`：内容已剥掉定界符，渲染时原样等宽显示、不再套粗斜体。 */
  math?: boolean;
}

const FENCE = '```';

/** 图片行：整行只有一个 `![alt](url)`（alt 可空，URL 不许含空白；允许 `![alt](url "title")` 的标题写法，标题忽略）。 */
const IMAGE_LINE = /^!\[([^\]]*)\]\(\s*([^\s)]+)(?:\s+"[^"]*")?\s*\)$/;

/**
 * 行内公式 `$...$` 的配对判定：返回剥掉定界符后的内容，判不成公式则 null。
 *
 * 特别防「钱数」误判：`价 $5 与 $10` 里两个 `$` 都紧贴数字，直接配对会把
 * 中间的正文吞成公式，所以额外要求右侧定界符后面**不紧跟数字**。
 */
function readInlineMath(text: string, from: number): string | null {
  let skip = text.charAt(from) === '$' && text.charAt(from + 1) === '$' ? 2 : 1;
  if (text.charAt(from - 1) === '$') {
    skip = 1; // 已在 `$$` 的第二个 `$` 上（前一个 `$` 没能配对），只按单 `$` 处理
  } else if (text.charAt(from - 1) === '\\') {
    return null; // \$ 是转义，交给调用方当普通字符
  }
  const open = from + skip;
  const close = text.indexOf('$', open);
  if (close < 0) {
    return null;
  }
  const content = text.substring(open, close);
  if (content.length === 0 || content.indexOf('\n') >= 0 || content !== content.trim()) {
    return null;
  }
  const after = close + 1 < text.length ? text.charAt(close + 1) : '';
  if (after >= '0' && after <= '9') {
    return null;
  }
  return content;
}

/** 行首空格/制表符折算成缩进层级（2 空格 = 1 级，制表符 = 1 级），上限 5 级。 */
function indentLevel(line: string): number {
  let spaces = 0;
  for (let i = 0; i < line.length; i++) {
    const ch = line.charAt(i);
    if (ch === ' ') {
      spaces += 1;
    } else if (ch === '\t') {
      spaces += 2;
    } else {
      break;
    }
  }
  const level = Math.floor(spaces / 2);
  return level > 5 ? 5 : level;
}

/** 分隔行：只由 `|`、`-`、`:`、空格组成，且至少有一个 `-`。 */
function isTableSeparator(line: string): boolean {
  const trimmed = line.trim();
  if (!trimmed.startsWith('|') || trimmed.indexOf('-') < 0) {
    return false;
  }
  for (let i = 0; i < trimmed.length; i++) {
    const ch = trimmed.charAt(i);
    if (ch !== '|' && ch !== '-' && ch !== ':' && ch !== ' ') {
      return false;
    }
  }
  return true;
}

/** 把 `| a | b |` 切成单元格（去掉首尾竖线与单元内空白）。 */
function splitTableRow(line: string): string[] {
  let body = line.trim();
  if (body.startsWith('|')) {
    body = body.substring(1);
  }
  if (body.endsWith('|')) {
    body = body.substring(0, body.length - 1);
  }
  return body.split('|').map((cell: string) => cell.trim());
}

/** 解析块级结构。 */
export function parseMarkdown(source: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = source.split('\n');
  let index = 0;
  let paragraph: string[] = [];
  let order = 0;
  let seq = 0;

  const pushImage = (alt: string, url: string): void => {
    blocks.push({
      kind: MdBlockKind.IMAGE, level: 0, index: 0, text: alt, language: '',
      url: url, alt: alt,
      key: `i${seq}:${url.length}:${url.substring(0, 32)}`
    });
    seq += 1;
  };

  const pushParagraph = (): void => {
    if (paragraph.length === 0) {
      return;
    }
    // 段落里**独立成行**的图片要拆成自己的 IMAGE 块：一则渲染宽度与文本不同，
    // 二则图片有异步加载失败状态（失败降级为 alt 文本），放在段落里表达不了。
    const runs: string[] = [];
    for (let i = 0; i < paragraph.length; i++) {
      const candidate = IMAGE_LINE.exec(paragraph[i].trim());
      if (candidate !== null) {
        if (runs.length > 0) {
          const body = runs.join('\n');
          blocks.push({
            kind: MdBlockKind.PARAGRAPH, level: 0, index: 0, text: body, language: '',
            key: `p${seq}:${body.length}:${body.substring(0, 24)}`
          });
          seq += 1;
          runs.length = 0;
        }
        pushImage(candidate[1], candidate[2]);
        continue;
      }
      runs.push(paragraph[i]);
    }
    if (runs.length > 0) {
      const text = runs.join('\n');
      blocks.push({
        kind: MdBlockKind.PARAGRAPH, level: 0, index: 0, text: text, language: '',
        key: `p${seq}:${text.length}:${text.substring(0, 24)}`
      });
      seq += 1;
    }
    paragraph = [];
  };

  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();

    // 围栏代码块（含未闭合的情况：一直吃到结尾）
    if (trimmed.startsWith(FENCE)) {
      pushParagraph();
      order = 0;
      const language = trimmed.substring(FENCE.length).trim();
      index += 1;
      const code: string[] = [];
      while (index < lines.length && !lines[index].trim().startsWith(FENCE)) {
        code.push(lines[index]);
        index += 1;
      }
      index += 1; // 跳过收尾的 ```
      const body = code.join('\n');
      blocks.push({
        kind: MdBlockKind.CODE, level: 0, index: 0, text: body, language: language,
        key: `c${seq}:${body.length}`
      });
      seq += 1;
      continue;
    }

    // 块级数学公式 `$$ ... $$`（已放在行内标记之前识别，公式内容不再参与粗斜体解析）
    if (trimmed.startsWith('$$')) {
      pushParagraph();
      order = 0;
      const inline = trimmed.endsWith('$$') && trimmed.length > 4
        ? trimmed.substring(2, trimmed.length - 2) : '';
      if (inline.length > 0) {
        blocks.push({
          kind: MdBlockKind.MATH, level: 0, index: 0, text: inline.trim(), language: '',
          key: `m${seq}:${inline.length}:${inline.substring(0, 24)}`
        });
        seq += 1;
        index += 1;
        continue;
      }
      index += 1;
      const formula: string[] = [];
      while (index < lines.length && lines[index].trim() !== '$$') {
        formula.push(lines[index]);
        index += 1;
      }
      index += 1; // 跳过收尾的 $$（未闭合时越界，循环自然结束）
      const body = formula.join('\n').trim();
      blocks.push({
        kind: MdBlockKind.MATH, level: 0, index: 0, text: body, language: '',
        key: `m${seq}:${body.length}:${body.substring(0, 24)}`
      });
      seq += 1;
      continue;
    }

    if (trimmed.length === 0) {
      pushParagraph();
      order = 0;
      index += 1;
      continue;
    }

    // 标题
    if (trimmed.startsWith('#')) {
      let level = 0;
      while (level < trimmed.length && trimmed.charAt(level) === '#') {
        level += 1;
      }
      if (level >= 1 && level <= 6 && level < trimmed.length && trimmed.charAt(level) === ' ') {
        pushParagraph();
        order = 0;
        const text = trimmed.substring(level + 1).trim();
        blocks.push({
          kind: MdBlockKind.HEADING, level: level, index: 0, text: text, language: '',
          key: `h${seq}:${level}:${text.substring(0, 24)}`
        });
        seq += 1;
        index += 1;
        continue;
      }
    }

    // 引用
    if (trimmed.startsWith('>')) {
      pushParagraph();
      order = 0;
      const text = trimmed.substring(1).trim();
      blocks.push({
        kind: MdBlockKind.QUOTE, level: 0, index: 0, text: text, language: '',
        key: `q${seq}:${text.substring(0, 24)}`
      });
      seq += 1;
      index += 1;
      continue;
    }

    // 表格：当前行以 `|` 开头，且下一行是分隔行（`|---|:--:|`）
    if (trimmed.startsWith('|') && index + 1 < lines.length && isTableSeparator(lines[index + 1])) {
      pushParagraph();
      order = 0;
      const rows: string[][] = [splitTableRow(trimmed)];
      index += 2; // 跳过表头与分隔行
      while (index < lines.length && lines[index].trim().startsWith('|')) {
        rows.push(splitTableRow(lines[index].trim()));
        index += 1;
      }
      const width = rows.length > 0 ? rows[0].length : 0;
      blocks.push({
        kind: MdBlockKind.TABLE, level: 0, index: 0, text: `${rows.length}x${width}`,
        language: '', rows: rows,
        key: `t${seq}:${rows.length}:${rows.length > 0 ? rows[0].join('|').substring(0, 24) : ''}`
      });
      seq += 1;
      continue;
    }

    // 分隔线
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      pushParagraph();
      order = 0;
      blocks.push({
        kind: MdBlockKind.RULE, level: 0, index: 0, text: '', language: '',
        key: `r${seq}`
      });
      seq += 1;
      index += 1;
      continue;
    }

    // 任务项（先于无序列表判定：`- [x] ` 也以 `- ` 开头）
    const taskMatch = /^[-*+]\s+\[([ xX])\]\s*(.*)$/.exec(trimmed);
    if (taskMatch !== null) {
      pushParagraph();
      order = 0;
      const checked = taskMatch[1].toLowerCase() === 'x';
      const text = taskMatch[2];
      blocks.push({
        kind: MdBlockKind.TASK, level: indentLevel(line), index: 0, text: text, language: '',
        checked: checked,
        key: `k${seq}:${checked}:${text.substring(0, 24)}`
      });
      seq += 1;
      index += 1;
      continue;
    }

    // 无序列表
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
      pushParagraph();
      order = 0;
      const text = trimmed.substring(2).trim();
      const level = indentLevel(line);
      blocks.push({
        kind: MdBlockKind.BULLET, level: level, index: 0, text: text, language: '',
        key: `b${seq}:${level}:${text.substring(0, 24)}`
      });
      seq += 1;
      index += 1;
      continue;
    }

    // 有序列表
    const orderedMatch = /^(\d{1,3})\.\s+(.*)$/.exec(trimmed);
    if (orderedMatch !== null) {
      pushParagraph();
      order += 1;
      const text = orderedMatch[2];
      const level = indentLevel(line);
      blocks.push({
        kind: MdBlockKind.ORDERED, level: level, index: order, text: text, language: '',
        key: `o${seq}:${level}:${order}:${text.substring(0, 24)}`
      });
      seq += 1;
      index += 1;
      continue;
    }

    order = 0;
    paragraph.push(line);
    index += 1;
  }
  pushParagraph();
  return blocks;
}

/** 解析行内标记。手写扫描而不是正则替换，避免双星号与单星号互相吃掉。 */
export function parseInline(text: string): MdInline[] {
  const out: MdInline[] = [];
  let buffer = '';
  let bold = false;
  let italic = false;
  let code = false;
  let strike = false;

  const flush = (): void => {
    if (buffer.length === 0) {
      return;
    }
    out.push({ text: buffer, bold: bold, italic: italic, code: code, strike: strike });
    buffer = '';
  };
  const flushLink = (label: string, url: string): void => {
    out.push({ text: label, bold: bold, italic: italic, code: false, strike: strike, link: url });
  };
  const flushImage = (alt: string, url: string): void => {
    // 图片用 `image` 而不是 `link` 标记：渲染层要 <Image> 与 <Text> 两种截然不同的处理
    out.push({ text: alt, bold: false, italic: false, code: false, strike: false, image: url });
  };
  const flushMath = (formula: string): void => {
    out.push({ text: formula, bold: false, italic: false, code: false, strike: false, math: true });
  };

  let i = 0;
  while (i < text.length) {
    // 行内代码优先级最高：内部不再解析其它标记
    if (text.charAt(i) === '`') {
      flush();
      code = !code;
      i += 1;
      continue;
    }
    // 图片 `![alt](url)`：必须优先于链接判定（`!` 之后紧跟的是 `[`）
    if (!code && text.charAt(i) === '!' && text.charAt(i + 1) === '[') {
      const imageClose = text.indexOf('](', i + 2);
      if (imageClose > i) {
        const imageEnd = text.indexOf(')', imageClose + 2);
        if (imageEnd > imageClose) {
          const alt = text.substring(i + 2, imageClose);
          const url = text.substring(imageClose + 2, imageEnd).trim();
          if (url.length > 0) {
            flush();
            flushImage(alt, url);
            i = imageEnd + 1;
            continue;
          }
        }
      }
    }
    // 行内公式 `$...$`：整段吃进来，内部字符不再参与 `*`/`_` 的粗斜体配对
    if (!code && text.charAt(i) === '$') {
      const formula = readInlineMath(text, i);
      if (formula !== null) {
        flush();
        flushMath(formula);
        i = text.indexOf('$', i + 1) + 1;
        continue;
      }
    }
    // 链接 `[文字](url)`：`]` 后必须紧跟 `(` 才算，避免把普通方括号吃掉
    if (!code && text.charAt(i) === '[') {
      const close = text.indexOf('](', i + 1);
      if (close > i) {
        const end = text.indexOf(')', close + 2);
        if (end > close) {
          const label = text.substring(i + 1, close);
          const url = text.substring(close + 2, end).trim();
          if (label.length > 0 && url.length > 0) {
            flush();
            flushLink(label, url);
            i = end + 1;
            continue;
          }
        }
      }
    }
    if (!code && text.startsWith('**', i)) {
      flush();
      bold = !bold;
      i += 2;
      continue;
    }
    if (!code && text.startsWith('~~', i)) {
      flush();
      strike = !strike;
      i += 2;
      continue;
    }
    if (!code && text.charAt(i) === '*') {
      flush();
      italic = !italic;
      i += 1;
      continue;
    }
    if (!code && text.charAt(i) === '_' && (i === 0 || text.charAt(i - 1) === ' ')) {
      flush();
      italic = !italic;
      i += 1;
      continue;
    }
    buffer += text.charAt(i);
    i += 1;
  }
  flush();
  if (out.length === 0) {
    out.push({ text: '', bold: false, italic: false, code: false, strike: false });
  }
  return out;
}

/** 去掉行内标记后的纯文本（复制/搜索用）。 */
export function plainText(text: string): string {
  const tokens = parseInline(text);
  let out = '';
  for (let i = 0; i < tokens.length; i++) {
    out += tokens[i].text;
  }
  return out;
}

/** 按行切分后的 token 行（一行代码 = 一组 Span）。 */
export interface TokenLine {
  tokens: SyntaxToken[];
  /** 该行原文长度，用来判「空行」并给渲染层一个稳定的 key 指纹。 */
  size: number;
}

/**
 * 把切词结果按 `\n` 拆成「一行一组」。
 *
 * 为什么要拆：**横向滚动要求每行独立成行**。若把整块代码塞进一个 `Text`，
 * 超长行会被硬折行（缩进对齐全毁）；拆行后每行自己按内容宽度撑开，
 * 外层再套一个横向 `Scroll`，长行就变成可滚动而不是折行。
 *
 * 放在这里而不是渲染层：它是纯函数、能进 Node 侧自测（渲染层无法实例化）。
 */
export function splitTokenLines(tokens: SyntaxToken[], source: string): TokenLine[] {
  const lines: SyntaxToken[][] = [[]];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const nl = token.text.indexOf('\n');
    if (nl < 0) {
      lines[lines.length - 1].push(token);
      continue;
    }
    const pieces = token.text.split('\n');
    for (let p = 0; p < pieces.length; p++) {
      if (p > 0) {
        lines.push([]);
      }
      if (pieces[p].length > 0) {
        lines[lines.length - 1].push({ text: pieces[p], kind: token.kind });
      }
    }
  }
  // 末尾空行只可能来自「代码以换行结尾」，而 parseMarkdown 已经把它去掉了，
  // 这里兜底一次，避免代码块底部多一条空白。
  if (lines.length > 1 && lines[lines.length - 1].length === 0) {
    lines.pop();
  }
  const out: TokenLine[] = [];
  const raw = source.split('\n');
  for (let i = 0; i < lines.length; i++) {
    out.push({ tokens: lines[i], size: i < raw.length ? raw[i].length : 0 });
  }
  return out;
}

/**
 * 代码块行号列文本：`1\n2\n…`（渲染层与正文共用同一个 lineHeight，逐行对齐）。
 *
 * 行号用**一整段** Text 而不是逐行组件：逐行组件时行号字号（CAPTION）与正文（SMALL）的
 * 默认行高不同，几十行之后就会明显错位。
 */
export function gutterText(lineCount: number): string {
  let out = '';
  for (let i = 1; i <= lineCount; i++) {
    out += i === 1 ? `${i}` : `\n${i}`;
  }
  return out.length > 0 ? out : '1';
}
