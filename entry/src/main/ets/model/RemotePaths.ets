/**
 * 远程工作区的路径判定（**纯逻辑，无 Kit 依赖**，可直接进 Node 自测）。
 *
 * 为什么独立成模块：这两条判定都对应真实缺陷，而且是「纯字符串运算」——
 * 放在 `FilesStore` 里就跟着 AppServices/Kit 一起被挡在自测之外了
 * （FilesStore 依赖 `@kit.NetworkKit`，Node 侧跑不起来）。
 *
 * 对应 Android 端 `FileBrowserViewModel` 里对工作区根的处理。
 */

/**
 * 父目录。`.` / 空 / `/` 视为已是根（返回 `.`）。
 *
 * ⚠️ 注意：服务端返回的 `path` 是**绝对路径**（如 `/Users/me/code/demo/src`），
 * 所以「根」到这里只会退化成绝对路径的上一级 —— 是否越界由 `isOutsideRoot` 判。
 */
export function parentPath(path: string): string {
  const normalized = path.replace(/\\/g, '/');
  if (normalized === '.' || normalized.length === 0 || normalized === '/') {
    return '.';
  }
  const index = normalized.lastIndexOf('/');
  if (index <= 0) {
    return '.';
  }
  return normalized.substring(0, index);
}

/**
 * 目标路径是否已经跑到工作区根**之外**。
 *
 * 真机/验收踩过的坑：文件页在根目录点「上一级」时，`parentPath('/Users/me/code/demo')`
 * 会给出 `/Users/me/code` —— 它既会去请求工作区之外的目录，
 * 又会让面包屑退回「绝对路径切片」的老 bug（坑 140：面包屑里冒出 `Users`）。
 *
 * @param root 工作区根（`.` 或空表示「没有固定根」，永远不算越界）
 * @param path 待判定的路径
 */
export function isOutsideRoot(root: string, path: string): boolean {
  const rootNorm = trimTrailingSlash(root.replace(/\\/g, '/'));
  if (rootNorm.length === 0 || rootNorm === '.') {
    return false;
  }
  const target = trimTrailingSlash(path.replace(/\\/g, '/'));
  if (target === rootNorm) {
    return false;
  }
  return !target.startsWith(`${rootNorm}/`);
}

/**
 * 把「上一级」的目标收敛到工作区根之内：越界时回到根（`.`）。
 *
 * @param current 当前目录
 * @param root 工作区根
 */
export function parentWithinRoot(current: string, root: string): string {
  const parent = parentPath(current);
  return isOutsideRoot(root, parent) ? '.' : parent;
}

function trimTrailingSlash(value: string): string {
  let end = value.length;
  while (end > 0 && value.charAt(end - 1) === '/') {
    end -= 1;
  }
  return value.substring(0, end);
}
