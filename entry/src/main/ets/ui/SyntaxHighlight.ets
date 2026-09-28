/**
 * 轻量语法高亮（对应上游 sora-editor + TextMate + Oniguruma 那部分职责的收敛版）。
 *
 * 上游用 TextMate 语法文件 + 原生 Oniguruma 正则做全量高亮（30+ 语言）。鸿蒙端不引这些依赖：
 * 用**单趟扫描 + 语言档（profile）**把每段代码切成带类型的小片，渲染层按类型上色。
 * 目标是「常见的 Agent 输出代码块看着像样」，不是逐语法完备。
 *
 * 纯逻辑、不依赖 ArkUI，因此可以直接进 Node 侧逻辑自测。
 *
 * 已知取舍：
 * - 不做跨行状态（模板字符串里的 `${}`、JSX 的标签嵌套、Markdown 内嵌代码块都按最简单规则处理）；
 * - 不做 heredoc / 复杂正则字面量区分；
 * - 未知语言退化为「类 C」通用档（注释 //、/* *\/、字符串引号、数字、标识符）。
 */

export enum TokenKind {
  PLAIN = 'plain',
  KEYWORD = 'keyword',
  TYPE = 'type',
  STRING = 'string',
  NUMBER = 'number',
  COMMENT = 'comment',
  FUNCTION = 'function',
  CONSTANT = 'constant',
  OPERATOR = 'operator',
  PUNCTUATION = 'punctuation',
  PROPERTY = 'property',
  TAG = 'tag',
  ATTRIBUTE = 'attribute'
}

export interface SyntaxToken {
  text: string;
  kind: TokenKind;
}

interface LanguageProfile {
  /** 语言名（归一化后）。 */
  name: string;
  keywords: string[];
  types: string[];
  constants: string[];
  /** 单行注释前缀，按长度从长到短尝试。 */
  lineComments: string[];
  blockComment?: string[];
  /** 字符串定界符（成对）。 */
  quotes: string[];
  /** 是否支持反引号模板串（JS/TS）。 */
  templateString: boolean;
  /** 是否把 `#` 当注释（python/yaml/sh）。 */
  hashComment: boolean;
  /** 关键字是否大小写不敏感（SQL 是；其余语言区分大小写）。 */
  caseInsensitive?: boolean;
}

// ---------------------------------------------------------------------------
// 语言关键字表（按需扩；覆盖上游最常出现的那些语言）
// ---------------------------------------------------------------------------

const JS_KEYWORDS: string[] = [
  'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger', 'default', 'delete', 'do',
  'else', 'enum', 'export', 'extends', 'finally', 'for', 'function', 'if', 'import', 'in',
  'instanceof', 'let', 'new', 'return', 'static', 'super', 'switch', 'this', 'throw', 'try',
  'typeof', 'var', 'void', 'while', 'with', 'yield', 'async', 'await', 'of', 'as', 'from',
  'interface', 'type', 'implements', 'public', 'private', 'protected', 'readonly', 'declare',
  'namespace', 'abstract', 'satisfies', 'keyof', 'infer'
];

const JS_TYPES: string[] = [
  'any', 'boolean', 'number', 'string', 'symbol', 'object', 'undefined', 'never', 'unknown',
  'bigint', 'Array', 'Object', 'String', 'Number', 'Boolean', 'Promise', 'Map', 'Set', 'Date',
  'Record', 'Partial', 'Readonly', 'Function', 'Error', 'JSON', 'Math', 'console'
];

const PY_KEYWORDS: string[] = [
  'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def', 'del', 'elif',
  'else', 'except', 'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda',
  'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield', 'match', 'case'
];

const PY_TYPES: string[] = [
  'bool', 'bytes', 'dict', 'float', 'int', 'list', 'object', 'set', 'str', 'tuple', 'type',
  'None', 'self', 'cls', 'Any', 'Optional', 'List', 'Dict'
];

const SH_KEYWORDS: string[] = [
  'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'do', 'done', 'case', 'esac', 'function',
  'in', 'return', 'export', 'local', 'readonly', 'declare', 'source', 'alias', 'set', 'unset',
  'echo', 'cd', 'exit', 'shift', 'trap', 'eval', 'exec', 'printf', 'test'
];

const GO_KEYWORDS: string[] = [
  'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else', 'fallthrough', 'for',
  'func', 'go', 'goto', 'if', 'import', 'interface', 'map', 'package', 'range', 'return', 'select',
  'struct', 'switch', 'type', 'var'
];

const GO_TYPES: string[] = [
  'bool', 'byte', 'complex64', 'complex128', 'error', 'float32', 'float64', 'int', 'int8',
  'int16', 'int32', 'int64', 'rune', 'string', 'uint', 'uint8', 'uint16', 'uint32', 'uint64', 'any'
];

const RUST_KEYWORDS: string[] = [
  'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn', 'else', 'enum', 'extern',
  'fn', 'for', 'if', 'impl', 'in', 'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref',
  'return', 'self', 'static', 'struct', 'super', 'trait', 'type', 'unsafe', 'use', 'where', 'while'
];

const RUST_TYPES: string[] = [
  'bool', 'char', 'f32', 'f64', 'i8', 'i16', 'i32', 'i64', 'i128', 'isize', 'str', 'String',
  'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'Vec', 'Option', 'Result', 'Box', 'Rc', 'Arc'
];

const JVM_KEYWORDS: string[] = [
  'abstract', 'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do',
  'else', 'enum', 'extends', 'final', 'finally', 'for', 'fun', 'if', 'implements', 'import',
  'in', 'instanceof', 'interface', 'internal', 'is', 'new', 'object', 'open', 'override',
  'package', 'private', 'protected', 'public', 'return', 'sealed', 'static', 'super', 'switch',
  'this', 'throw', 'throws', 'try', 'val', 'var', 'void', 'when', 'while', 'typeof', 'suspend',
  'data', 'companion', 'init', 'lateinit', 'vararg'
];

const JVM_TYPES: string[] = [
  'boolean', 'byte', 'char', 'double', 'float', 'int', 'long', 'short', 'String', 'Any', 'Unit',
  'Int', 'Long', 'Double', 'Float', 'Boolean', 'List', 'Map', 'Set', 'Array'
];

const C_KEYWORDS: string[] = [
  'auto', 'break', 'case', 'const', 'continue', 'default', 'do', 'else', 'enum', 'extern', 'for',
  'goto', 'if', 'inline', 'register', 'restrict', 'return', 'sizeof', 'static', 'struct', 'switch',
  'typedef', 'union', 'volatile', 'while', 'class', 'namespace', 'template', 'typename', 'public',
  'private', 'protected', 'virtual', 'override', 'new', 'delete', 'using', 'nullptr', 'true',
  'false', 'bool', 'constexpr', 'noexcept', 'auto'
];

const C_TYPES: string[] = [
  'char', 'double', 'float', 'int', 'long', 'short', 'signed', 'unsigned', 'void', 'size_t',
  'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'int8_t', 'int16_t', 'int32_t', 'int64_t',
  'string', 'vector', 'map', 'set', 'std'
];

const SQL_KEYWORDS: string[] = [
  'select', 'from', 'where', 'insert', 'into', 'values', 'update', 'set', 'delete', 'create',
  'table', 'alter', 'drop', 'index', 'view', 'join', 'left', 'right', 'inner', 'outer', 'on',
  'group', 'by', 'order', 'having', 'limit', 'offset', 'union', 'all', 'distinct', 'as', 'and',
  'or', 'not', 'null', 'is', 'in', 'between', 'like', 'case', 'when', 'then', 'else', 'end',
  'primary', 'key', 'foreign', 'references', 'default', 'unique', 'constraint', 'if', 'exists',
  'with', 'asc', 'desc', 'returning'
];

const SQL_TYPES: string[] = [
  'int', 'integer', 'bigint', 'smallint', 'serial', 'text', 'varchar', 'char', 'boolean', 'bool',
  'date', 'timestamp', 'timestamptz', 'numeric', 'decimal', 'real', 'double', 'json', 'jsonb',
  'uuid', 'bytea'
];

const YAML_CONSTANTS: string[] = ['true', 'false', 'null', 'yes', 'no', 'on', 'off', '~'];

const GENERIC: LanguageProfile = {
  name: 'generic',
  keywords: JS_KEYWORDS,
  types: JS_TYPES,
  constants: ['true', 'false', 'null', 'undefined', 'nil', 'None'],
  lineComments: ['//'],
  blockComment: ['/*', '*/'],
  quotes: ['"', "'"],
  templateString: false,
  hashComment: false
};

const PROFILES: LanguageProfile[] = [
  {
    name: 'typescript', keywords: JS_KEYWORDS, types: JS_TYPES,
    constants: ['true', 'false', 'null', 'undefined', 'NaN', 'Infinity'],
    lineComments: ['//'], blockComment: ['/*', '*/'], quotes: ['"', "'"],
    templateString: true, hashComment: false
  },
  {
    name: 'python', keywords: PY_KEYWORDS, types: PY_TYPES,
    constants: ['True', 'False', 'None', 'NotImplemented', 'Ellipsis'],
    lineComments: ['#'], quotes: ['"', "'"], templateString: false, hashComment: true
  },
  {
    name: 'shell', keywords: SH_KEYWORDS, types: [],
    constants: ['true', 'false'],
    lineComments: ['#'], quotes: ['"', "'"], templateString: false, hashComment: true
  },
  {
    name: 'go', keywords: GO_KEYWORDS, types: GO_TYPES,
    constants: ['true', 'false', 'nil', 'iota'],
    lineComments: ['//'], blockComment: ['/*', '*/'], quotes: ['"', '`'],
    templateString: false, hashComment: false
  },
  {
    name: 'rust', keywords: RUST_KEYWORDS, types: RUST_TYPES,
    constants: ['true', 'false', 'None', 'Some', 'Ok', 'Err'],
    lineComments: ['//'], blockComment: ['/*', '*/'], quotes: ['"'],
    templateString: false, hashComment: false
  },
  {
    name: 'jvm', keywords: JVM_KEYWORDS, types: JVM_TYPES,
    constants: ['true', 'false', 'null'],
    lineComments: ['//'], blockComment: ['/*', '*/'], quotes: ['"', "'"],
    templateString: false, hashComment: false
  },
  {
    name: 'c', keywords: C_KEYWORDS, types: C_TYPES,
    constants: ['true', 'false', 'NULL', 'nullptr'],
    lineComments: ['//'], blockComment: ['/*', '*/'], quotes: ['"', "'"],
    templateString: false, hashComment: false
  },
  {
    name: 'sql', keywords: SQL_KEYWORDS, types: SQL_TYPES,
    constants: ['true', 'false', 'null'],
    lineComments: ['--'], blockComment: ['/*', '*/'], quotes: ["'", '"'],
    templateString: false, hashComment: false, caseInsensitive: true
  },
  {
    name: 'yaml', keywords: [], types: [],
    constants: YAML_CONSTANTS,
    lineComments: ['#'], quotes: ['"', "'"], templateString: false, hashComment: true
  },
  {
    name: 'json', keywords: [], types: [],
    constants: ['true', 'false', 'null'],
    lineComments: [], quotes: ['"'], templateString: false, hashComment: false
  },
  {
    name: 'ini', keywords: [], types: [],
    constants: ['true', 'false'],
    lineComments: ['#', ';'], quotes: ['"', "'"], templateString: false, hashComment: true
  },
  {
    name: 'markup', keywords: [], types: [],
    constants: [],
    lineComments: [], blockComment: ['<!--', '-->'], quotes: ['"', "'"],
    templateString: false, hashComment: false
  },
  {
    name: 'css', keywords: ['important', 'media', 'import', 'keyframes', 'supports', 'from', 'to'],
    types: [], constants: ['inherit', 'initial', 'unset', 'auto', 'none'],
    lineComments: [], blockComment: ['/*', '*/'], quotes: ['"', "'"],
    templateString: false, hashComment: false
  },
  {
    name: 'markdown', keywords: [], types: [], constants: [],
    lineComments: [], quotes: [], templateString: false, hashComment: false
  },
  {
    name: 'diff', keywords: [], types: [], constants: [],
    lineComments: [], quotes: [], templateString: false, hashComment: false
  }
];

const ALIASES: Map<string, string> = new Map<string, string>([
  ['ts', 'typescript'], ['tsx', 'typescript'], ['typescript', 'typescript'],
  ['js', 'typescript'], ['jsx', 'typescript'], ['javascript', 'typescript'],
  ['mjs', 'typescript'], ['cjs', 'typescript'], ['ets', 'typescript'], ['arkts', 'typescript'],
  ['json', 'json'], ['json5', 'json'], ['jsonc', 'json'],
  ['py', 'python'], ['python', 'python'], ['python3', 'python'],
  ['sh', 'shell'], ['bash', 'shell'], ['zsh', 'shell'], ['shell', 'shell'], ['console', 'shell'],
  ['shellscript', 'shell'], ['fish', 'shell'],
  ['go', 'go'], ['golang', 'go'],
  ['rs', 'rust'], ['rust', 'rust'],
  ['java', 'jvm'], ['kt', 'jvm'], ['kts', 'jvm'], ['kotlin', 'jvm'], ['scala', 'jvm'], ['groovy', 'jvm'],
  ['c', 'c'], ['h', 'c'], ['cpp', 'c'], ['c++', 'c'], ['cc', 'c'], ['hpp', 'c'], ['cs', 'c'],
  ['csharp', 'c'], ['objc', 'c'], ['swift', 'c'],
  ['sql', 'sql'], ['postgres', 'sql'], ['mysql', 'sql'], ['sqlite', 'sql'],
  ['yaml', 'yaml'], ['yml', 'yaml'],
  ['ini', 'ini'], ['toml', 'ini'], ['conf', 'ini'], ['cfg', 'ini'], ['env', 'ini'], ['dotenv', 'ini'],
  ['properties', 'ini'],
  ['html', 'markup'], ['xml', 'markup'], ['svg', 'markup'], ['vue', 'markup'], ['markup', 'markup'],
  ['css', 'css'], ['scss', 'css'], ['less', 'css'], ['sass', 'css'],
  ['md', 'markdown'], ['markdown', 'markdown'],
  ['diff', 'diff'], ['patch', 'diff']
]);

/** 把代码块的语言标签归一化成内部档名。 */
export function normalizeLanguage(label: string): string {
  const key = label.trim().toLowerCase();
  if (key.length === 0) {
    return 'generic';
  }
  const mapped = ALIASES.get(key);
  return mapped !== undefined ? mapped : 'generic';
}

/**
 * 按**文件名**猜语言档（文件预览用；代码块走 `normalizeLanguage`）。
 *
 * 特殊文件名优先（`Dockerfile` / `Makefile` / `.gitignore` 这类没有扩展名或用 dotfile 形式），
 * 再看最后一个 `.` 之后的扩展名，扩展名同样过 `ALIASES`（所以 `Main.kt` 与 ``` ```kotlin ```
 * 落到同一档）。认不出来返回 `generic`（通用档仍然着色，只是关键字表最宽）。
 */
const FILE_NAMES: Map<string, string> = new Map<string, string>([
  ['dockerfile', 'shell'], ['containerfile', 'shell'], ['makefile', 'shell'],
  ['cmakelists.txt', 'shell'], ['gemfile', 'shell'], ['rakefile', 'shell'],
  ['bashrc', 'shell'], ['zshrc', 'shell'], ['profile', 'shell'], ['bash_profile', 'shell'],
  ['.gitignore', 'shell'], ['.dockerignore', 'shell'], ['.env', 'ini'],
  ['package.json', 'json'], ['tsconfig.json', 'json'], ['oh-package.json5', 'json'],
  ['build-profile.json5', 'json'], ['module.json5', 'json'], ['app.json5', 'json'],
  ['cargo.toml', 'ini'], ['pyproject.toml', 'ini'], ['go.mod', 'shell']
]);

export function languageFromFileName(name: string): string {
  const lower = name.trim().toLowerCase();
  const lastSlash = lower.lastIndexOf('/');
  const base = lastSlash >= 0 ? lower.substring(lastSlash + 1) : lower;
  const special = FILE_NAMES.get(base);
  if (special !== undefined) {
    return special;
  }
  const dot = base.lastIndexOf('.');
  if (dot <= 0 || dot === base.length - 1) {
    return 'generic';
  }
  return normalizeLanguage(base.substring(dot + 1));
}

function profileFor(name: string): LanguageProfile {
  for (let i = 0; i < PROFILES.length; i++) {
    if (PROFILES[i].name === name) {
      return PROFILES[i];
    }
  }
  return GENERIC;
}

/**
 * 语言档的词表缓存（R57 性能轮）。
 *
 * 改前：`tokenizeCode` 每调一次就为该语言建 3 个 `Set` + `lower()` 复制数组
 * （typescript 档约 120 个词），同一语言的不同代码块各付一次；
 * 会话里几十个代码块同语言时这笔分配是纯浪费。
 *
 * 改后：按归一化语言名建一次 `{keywords, types, constants}` 三元组缓存。
 * `LanguageProfile` 本身是模块级常量、永不修改，所以缓存**无界也安全**
 * （键空间只有 PROFILES + 'generic' 这 16 个，不会随用户输入增长）。
 *
 * 语义不变：大小写折叠（`caseInsensitive`）仍在建 Set 时完成，查找路径与改前逐字相同。
 */
interface ProfileWordSets {
  keywords: Set<string>;
  types: Set<string>;
  constants: Set<string>;
}

const PROFILE_WORD_SETS: Map<string, ProfileWordSets> = new Map<string, ProfileWordSets>();

function wordSetsFor(profile: LanguageProfile): ProfileWordSets {
  const cached = PROFILE_WORD_SETS.get(profile.name);
  if (cached !== undefined) {
    return cached;
  }
  const fold = profile.caseInsensitive === true;
  const lower = (list: string[]): Set<string> => {
    const out: Set<string> = new Set<string>();
    for (let k = 0; k < list.length; k++) {
      out.add(fold ? list[k].toLowerCase() : list[k]);
    }
    return out;
  };
  const sets: ProfileWordSets = {
    keywords: lower(profile.keywords),
    types: lower(profile.types),
    constants: lower(profile.constants)
  };
  PROFILE_WORD_SETS.set(profile.name, sets);
  return sets;
}

function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

function isIdentifierStart(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch === '_' || ch === '$';
}

function isIdentifierPart(ch: string): boolean {
  return isIdentifierStart(ch) || isDigit(ch);
}

function isUpper(ch: string): boolean {
  return ch >= 'A' && ch <= 'Z';
}

const OPERATORS: string[] = [
  '===', '!==', '>>>', '**=', '<<=', '>>=', '...', '=>', '==', '!=', '<=', '>=', '&&', '||',
  '??', '?.', '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>', '::',
  '->', '**', '?:'
];

const PUNCTUATION: string[] = ['(', ')', '[', ']', '{', '}', ',', ';', ':', '.', '@', '#'];

function pushToken(out: SyntaxToken[], text: string, kind: TokenKind): void {
  if (text.length === 0) {
    return;
  }
  const last = out.length > 0 ? out[out.length - 1] : undefined;
  if (last !== undefined && last.kind === kind) {
    last.text += text;
    return;
  }
  out.push({ text: text, kind: kind });
}

/**
 * 把代码切成带类型的小片。
 *
 * 单趟扫描：在每个位置按「注释 → 字符串 → 数字 → 标识符 → 运算符 → 标点」的优先级匹配，
 * 命中的整段吃进去，避免逐字符反复试探。
 */
export function tokenizeCode(code: string, language: string): SyntaxToken[] {
  const profile = profileFor(normalizeLanguage(language));

  // diff 档按行首字符上色，最直观
  if (profile.name === 'diff') {
    return tokenizeDiff(code);
  }
  // markdown 档只在代码块内被调用，做最简处理（标题/强调/行内代码）
  if (profile.name === 'markdown') {
    return tokenizeMarkdownBlock(code);
  }

  const wordSets = wordSetsFor(profile);
  const fold = profile.caseInsensitive === true;
  const keywords: Set<string> = wordSets.keywords;
  const types: Set<string> = wordSets.types;
  const constants: Set<string> = wordSets.constants;
  const out: SyntaxToken[] = [];
  let i = 0;

  while (i < code.length) {
    const ch = code.charAt(i);

    // ---- 注释 ----
    let matchedComment = false;
    if (profile.blockComment !== undefined && code.startsWith(profile.blockComment[0], i)) {
      const close = code.indexOf(profile.blockComment[1], i + profile.blockComment[0].length);
      const end = close < 0 ? code.length : close + profile.blockComment[1].length;
      pushToken(out, code.substring(i, end), TokenKind.COMMENT);
      i = end;
      matchedComment = true;
    }
    if (!matchedComment && profile.hashComment && ch === '#') {
      const end = lineEnd(code, i);
      pushToken(out, code.substring(i, end), TokenKind.COMMENT);
      i = end;
      matchedComment = true;
    }
    if (!matchedComment) {
      for (let c = 0; c < profile.lineComments.length; c++) {
        const prefix = profile.lineComments[c];
        if (code.startsWith(prefix, i)) {
          const end = lineEnd(code, i);
          pushToken(out, code.substring(i, end), TokenKind.COMMENT);
          i = end;
          matchedComment = true;
          break;
        }
      }
    }
    if (matchedComment) {
      continue;
    }

    // ---- 字符串 ----
    let matchedString = false;
    for (let q = 0; q < profile.quotes.length; q++) {
      const quote = profile.quotes[q];
      if (ch === quote) {
        const end = scanString(code, i, quote);
        pushToken(out, code.substring(i, end), TokenKind.STRING);
        i = end;
        matchedString = true;
        break;
      }
    }
    if (!matchedString && profile.templateString && ch === '`') {
      const end = scanTemplate(code, i);
      pushToken(out, code.substring(i, end), TokenKind.STRING);
      i = end;
      matchedString = true;
    }
    if (matchedString) {
      continue;
    }

    // ---- 数字 ----
    if (isDigit(ch)) {
      let j = i;
      if (ch === '0' && i + 1 < code.length &&
        (code.charAt(i + 1) === 'x' || code.charAt(i + 1) === 'X' ||
          code.charAt(i + 1) === 'b' || code.charAt(i + 1) === 'o')) {
        j = i + 2;
        while (j < code.length && /[0-9a-fA-F_]/.test(code.charAt(j))) {
          j += 1;
        }
      } else {
        while (j < code.length && (isDigit(code.charAt(j)) || code.charAt(j) === '_')) {
          j += 1;
        }
        if (j < code.length && code.charAt(j) === '.') {
          j += 1;
          while (j < code.length && (isDigit(code.charAt(j)) || code.charAt(j) === '_')) {
            j += 1;
          }
        }
        if (j < code.length && (code.charAt(j) === 'e' || code.charAt(j) === 'E')) {
          let k = j + 1;
          if (k < code.length && (code.charAt(k) === '+' || code.charAt(k) === '-')) {
            k += 1;
          }
          if (k < code.length && isDigit(code.charAt(k))) {
            j = k;
            while (j < code.length && isDigit(code.charAt(j))) {
              j += 1;
            }
          }
        }
      }
      if (j < code.length && (code.charAt(j) === 'n' || code.charAt(j) === 'L' ||
        code.charAt(j) === 'f' || code.charAt(j) === 'u' || code.charAt(j) === 'i')) {
        j += 1;
      }
      pushToken(out, code.substring(i, j), TokenKind.NUMBER);
      i = j;
      continue;
    }

    // ---- 标识符 / 关键字 ----
    if (isIdentifierStart(ch)) {
      let j = i;
      while (j < code.length && isIdentifierPart(code.charAt(j))) {
        j += 1;
      }
      const word = code.substring(i, j);
      const lookup = fold ? word.toLowerCase() : word;
      let kind = TokenKind.PLAIN;
      if (constants.has(lookup)) {
        kind = TokenKind.CONSTANT;
      } else if (keywords.has(lookup)) {
        kind = TokenKind.KEYWORD;
      } else if (types.has(lookup)) {
        kind = TokenKind.TYPE;
      } else if (isUpper(ch) && word.length > 1 && !isAllUpper(word)) {
        // 首字母大写且不是全大写常量 → 当作类型/类名
        kind = TokenKind.TYPE;
      } else {
        // 后面紧跟 `(` 视为函数调用
        let k = j;
        while (k < code.length && code.charAt(k) === ' ') {
          k += 1;
        }
        if (k < code.length && code.charAt(k) === '(') {
          kind = TokenKind.FUNCTION;
        }
      }
      pushToken(out, word, kind);
      i = j;
      continue;
    }

    // ---- 运算符 ----
    let matchedOperator = false;
    for (let o = 0; o < OPERATORS.length; o++) {
      if (code.startsWith(OPERATORS[o], i)) {
        pushToken(out, OPERATORS[o], TokenKind.OPERATOR);
        i += OPERATORS[o].length;
        matchedOperator = true;
        break;
      }
    }
    if (matchedOperator) {
      continue;
    }

    // ---- 标点 / 其它 ----
    if (PUNCTUATION.includes(ch)) {
      pushToken(out, ch, TokenKind.PUNCTUATION);
      i += 1;
      continue;
    }
    if (ch === '=' || ch === '+' || ch === '-' || ch === '*' || ch === '/' ||
      ch === '%' || ch === '<' || ch === '>' || ch === '!' || ch === '&' ||
      ch === '|' || ch === '^' || ch === '~' || ch === '?') {
      pushToken(out, ch, TokenKind.OPERATOR);
      i += 1;
      continue;
    }

    pushToken(out, ch, TokenKind.PLAIN);
    i += 1;
  }
  return out;
}

function lineEnd(code: string, from: number): number {
  const nl = code.indexOf('\n', from);
  return nl < 0 ? code.length : nl;
}

function isAllUpper(word: string): boolean {
  for (let i = 0; i < word.length; i++) {
    const ch = word.charAt(i);
    if (ch >= 'a' && ch <= 'z') {
      return false;
    }
  }
  return true;
}

/** 扫描一个字符串字面量，返回结束位置（含闭引号）。处理反斜杠转义；未闭合则吃到行尾/结尾。 */
function scanString(code: string, start: number, quote: string): number {
  let i = start + 1;
  while (i < code.length) {
    const ch = code.charAt(i);
    if (ch === '\\') {
      i += 2;
      continue;
    }
    if (ch === quote) {
      return i + 1;
    }
    if (ch === '\n') {
      return i; // 未闭合：不跨行（避免把后面整段吞掉）
    }
    i += 1;
  }
  return code.length;
}

/** 模板字符串：允许跨行，识别 `${}` 并跳过内部（简化：不做内部再高亮）。 */
function scanTemplate(code: string, start: number): number {
  let i = start + 1;
  while (i < code.length) {
    const ch = code.charAt(i);
    if (ch === '\\') {
      i += 2;
      continue;
    }
    if (ch === '`') {
      return i + 1;
    }
    i += 1;
  }
  return code.length;
}

/** diff 档：`+` 行绿、`-` 行红、`@@` 青、其余平淡。 */
function tokenizeDiff(code: string): SyntaxToken[] {
  const out: SyntaxToken[] = [];
  const lines = code.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let kind = TokenKind.PLAIN;
    if (line.startsWith('+')) {
      kind = TokenKind.STRING;
    } else if (line.startsWith('-')) {
      kind = TokenKind.KEYWORD;
    } else if (line.startsWith('@@') || line.startsWith('diff ') ||
      line.startsWith('index ') || line.startsWith('---') || line.startsWith('+++')) {
      kind = TokenKind.COMMENT;
    }
    pushToken(out, line, kind);
    if (i < lines.length - 1) {
      out.push({ text: '\n', kind: TokenKind.PLAIN });
    }
  }
  return out;
}

/** markdown 档（仅在代码块内使用）：标题、强调、行内代码、引用、列表。 */
function tokenizeMarkdownBlock(code: string): SyntaxToken[] {
  const out: SyntaxToken[] = [];
  const lines = code.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let kind = TokenKind.PLAIN;
    if (line.startsWith('#')) {
      kind = TokenKind.KEYWORD;
    } else if (line.startsWith('>')) {
      kind = TokenKind.COMMENT;
    } else if (line.startsWith('- ') || line.startsWith('* ') || line.startsWith('+ ')) {
      kind = TokenKind.PUNCTUATION;
    } else if (line.startsWith('```')) {
      kind = TokenKind.COMMENT;
    }
    pushToken(out, line, kind);
    if (i < lines.length - 1) {
      out.push({ text: '\n', kind: TokenKind.PLAIN });
    }
  }
  return out;
}
