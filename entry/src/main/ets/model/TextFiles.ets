/**
 * 「这个文件能不能当文本预览」的判定（纯逻辑，零依赖，可直接进 Node 自测）。
 *
 * 原先这条判定写在 `feature/FilesStore.ets` 里，有两个问题：
 *  ① 判据是「取最后一个 `.` 之后的扩展名」，于是 **没有扩展名的常见文本文件**
 *  （`Dockerfile` / `Makefile` / `LICENSE` / `README`）一律被判成「不可预览」——
 *  真机上点 `Dockerfile` 只弹一句「这个文件类型暂不支持预览」，而它明明就是纯文本；
 *  ② 它和语言高亮的认识（`ui/SyntaxHighlight.ets` 的别名表）各写一份，容易漂。
 * 这里把「哪些名字/扩展名算文本」收敛到一个 model 层模块，store 与 UI 都从这里取，
 * 顺便让它能进逻辑自测（FilesStore 因为 import 了网络层，跑不了 Node 自测）。
 */

/** 视为纯文本的扩展名（小写，不带点）。 */
const TEXT_EXTENSIONS: string[] = [
  // 文档 / 配置
  'txt', 'text', 'md', 'markdown', 'mdx', 'rst', 'adoc', 'log',
  'json', 'json5', 'jsonc', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env',
  'properties', 'lock', 'csv', 'tsv', 'sql', 'gradle', 'pem', 'crt', 'key', 'pub',
  // 代码
  'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'ets', 'kt', 'kts', 'java', 'scala', 'groovy',
  'py', 'rb', 'go', 'rs', 'php', 'swift', 'dart', 'lua', 'pl', 'r',
  'c', 'h', 'cpp', 'hpp', 'cc', 'hh', 'cs', 'm', 'mm',
  'sh', 'bash', 'zsh', 'fish', 'ps1', 'bat', 'cmd',
  'html', 'htm', 'css', 'scss', 'less', 'sass', 'xml', 'svg', 'vue', 'svelte',
  // 补丁 / diff
  'patch', 'diff'
];

/**
 * 没有扩展名（或以点开头）但公认是文本的文件名 —— 按**小写文件名**比对。
 * `README.md` 这种走扩展名，不在这里。
 */
const TEXT_FILE_NAMES: string[] = [
  'dockerfile', 'containerfile', 'makefile', 'gnumakefile', 'cmakelists.txt',
  'procfile', 'gemfile', 'rakefile', 'brewfile', 'vagrantfile',
  'license', 'licence', 'notice', 'readme', 'changelog', 'changes', 'authors',
  'contributing', 'codeowners', 'todo',
  '.gitignore', '.dockerignore', '.npmignore', '.editorconfig', '.npmrc', '.babelrc',
  '.env', '.env.local', '.env.example', '.gitattributes', '.prettierrc', '.eslintrc',
  '.bashrc', '.zshrc', '.profile', '.bash_profile', '.vimrc', '.inputrc'
];

/** 取路径里的文件名（同时兼容 `/` 与 `\` 两种分隔符）。 */
function baseName(path: string): string {
  const trimmed = path.trim();
  const slash = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'));
  return (slash >= 0 ? trimmed.substring(slash + 1) : trimmed).toLowerCase();
}

/** 该文件名是否可按文本预览（文本类代码/配置/文档）。 */
export function isTextPreviewable(name: string): boolean {
  const base = baseName(name);
  if (base.length === 0) {
    return false;
  }
  if (TEXT_FILE_NAMES.includes(base)) {
    return true;
  }
  const dot = base.lastIndexOf('.');
  if (dot < 0 || dot === base.length - 1) {
    return false;
  }
  return TEXT_EXTENSIONS.includes(base.substring(dot + 1));
}

/** 供文档/排查用：当前认定的文本扩展名个数。 */
export function textExtensionCount(): number {
  return TEXT_EXTENSIONS.length;
}
