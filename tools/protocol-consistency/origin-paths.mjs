/**
 * 原包（@zcode/rpc + @zcode/shared 源码）路径解析。
 *
 * 一致性门禁要把「移植层」与「原包源」喂同一组向量，因此门禁依赖原包仓库在位。
 * 仓库搬迁过两次（F: 盘 → E:\program\ → 当前目录），路径写死会让门禁在换机后
 * 直接 ERR_MODULE_NOT_FOUND 挂掉——所以集中到这里解析，测试文件只 import 结果。
 *
 * 优先级：
 *   1. 细粒度环境变量 ZCODE_RPC_SRC / ZCODE_SHARED_SRC（指向各自 src 目录，历史接口）
 *   2. 仓库级环境变量 ZCODE_ORIGIN_ROOT（指向 ZCode 仓根目录）
 *   3. 同级目录探测（与本仓同层的 ZCode / zcode / zcode-build）
 *   4. 历史默认位置 E:/program/zcode（仅在目录确实存在时采用）
 * 都不命中时抛错并给出可执行提示，而不是让 import 以 ERR_MODULE_NOT_FOUND 失败。
 */
import fs from 'node:fs';
import path from 'node:path';

/** 本仓根目录（tools/protocol-consistency → ../../）。 */
const REPO_ROOT = path.resolve(import.meta.dirname, '../..');

/** 历史默认位置（F: 盘残缺安装已弃用，此处仅作最后兜底）。 */
const LEGACY_ROOT = 'E:/program/zcode';

/** 同级目录候选名（按优先级）。 */
const SIBLING_CANDIDATES = ['ZCode', 'zcode', 'zcode-build'];

/** 原包仓库的判定标志文件。 */
function isOriginRoot(dir) {
  return fs.existsSync(path.join(dir, 'packages', 'rpc', 'src', 'channelServer.ts'));
}

/** 同级目录探测：与本仓同层的 ZCode 仓。 */
function probeSiblingRoot() {
  const parent = path.dirname(REPO_ROOT);
  for (const name of SIBLING_CANDIDATES) {
    const candidate = path.join(parent, name);
    if (isOriginRoot(candidate)) {
      return candidate;
    }
  }
  return null;
}

/** 解析原包仓根目录。 */
function resolveOriginRoot() {
  const fromEnv = process.env.ZCODE_ORIGIN_ROOT;
  if (fromEnv) {
    const abs = path.resolve(fromEnv);
    if (!isOriginRoot(abs)) {
      throw new Error(
        `ZCODE_ORIGIN_ROOT 指向的目录不是 ZCode 原包仓（缺 packages/rpc/src/channelServer.ts）：${abs}`,
      );
    }
    return abs;
  }
  const sibling = probeSiblingRoot();
  if (sibling) {
    return sibling;
  }
  if (isOriginRoot(LEGACY_ROOT)) {
    return LEGACY_ROOT;
  }
  throw new Error(
    [
      '找不到 ZCode 原包仓（@zcode/rpc 源码），一致性门禁无法比对移植层。',
      '解决办法（任选其一）：',
      '  a) 设置 ZCODE_ORIGIN_ROOT 指向 ZCode 仓根目录（含 packages/rpc/src）；',
      '  b) 把 ZCode 仓放在本仓同级目录（目录名 ZCode / zcode / zcode-build）；',
      '  c) 分别设置 ZCODE_RPC_SRC（packages/rpc/src）与 ZCODE_SHARED_SRC（packages/shared/src）。',
    ].join('\n'),
  );
}

const ORIGIN_ROOT = resolveOriginRoot();

/** 原包仓根目录（诊断输出用）。 */
export { ORIGIN_ROOT };

/** 原包 rpc 源目录（@zcode/rpc）。 */
export const ORIGIN_RPC = process.env.ZCODE_RPC_SRC
  ? path.resolve(process.env.ZCODE_RPC_SRC)
  : path.join(ORIGIN_ROOT, 'packages', 'rpc', 'src');

/** 原包 shared 源目录（@zcode/shared，含 zcode-protocol-v4）。 */
export const ORIGIN_SHARED = process.env.ZCODE_SHARED_SRC
  ? path.resolve(process.env.ZCODE_SHARED_SRC)
  : path.join(ORIGIN_ROOT, 'packages', 'shared', 'src');
