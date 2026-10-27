/**
 * 把原包仓的 workspace 包联接到测试用的 node_modules。
 *
 * 背景：一致性门禁要加载原包仓源码（如 packages/shared/src/model-config.ts），
 * 而这些源码 import 的是同仓的 workspace 包（如 @zcode/model-option-map）——
 * npm 装不上（非公开包），没有 pnpm workspace 链接就会 ERR_MODULE_NOT_FOUND。
 *
 * 做法：扫描本门禁实际加载的原包源（rpc/src、shared/src），收集其中的
 * `@zcode/*` 裸导入，在原包仓 packages/ 里定位同名包，逐个建目录联接
 * （Windows 用 junction，免管理员权限；POSIX 退化为普通目录符号链接）。
 *
 * 只链「被引用」的包而不是全部 —— 其余的留在原地，npm install 也不会误删。
 * 已在位则跳过，重复执行安全。
 */
import fs from 'node:fs';
import path from 'node:path';

import { ORIGIN_ROOT, ORIGIN_RPC, ORIGIN_SHARED } from './origin-paths.mjs';

const NODE_MODULES = path.resolve(import.meta.dirname, 'node_modules');
const PACKAGES_DIR = path.join(ORIGIN_ROOT, 'packages');

/** 递归收集 .ts 源里的裸 @zcode/* 导入名。 */
function collectImportedPackages(dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      collectImportedPackages(full, out);
      continue;
    }
    if (!entry.name.endsWith('.ts')) {
      continue;
    }
    let source;
    try {
      source = fs.readFileSync(full, 'utf8');
    } catch {
      continue; // 加密驱动等导致读不动 → 跳过该文件
    }
    const matches = source.matchAll(/['"]@zcode\/[a-z0-9-]+['"]/g);
    for (const m of matches) {
      out.add(m[0].slice(1, -1));
    }
  }
  return out;
}

/** 原包仓里是否有该 workspace 包。 */
function findPackageDir(name) {
  if (!fs.existsSync(PACKAGES_DIR)) {
    return null;
  }
  for (const entry of fs.readdirSync(PACKAGES_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory()) {
      continue;
    }
    const manifestPath = path.join(PACKAGES_DIR, entry.name, 'package.json');
    if (!fs.existsSync(manifestPath)) {
      continue;
    }
    try {
      const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
      if (manifest.name === name) {
        return path.join(PACKAGES_DIR, entry.name);
      }
    } catch {
      // manifest 读不动 → 跳过
    }
  }
  return null;
}

/** 目标已可解析（链接或实体目录）则无需处理。 */
function isResolvable(linkPath) {
  try {
    return fs.existsSync(path.join(linkPath, 'package.json'));
  } catch {
    return false;
  }
}

const imported = collectImportedPackages(ORIGIN_RPC, new Set());
collectImportedPackages(ORIGIN_SHARED, imported);

const linked = [];
const skipped = [];
const missing = [];
for (const name of [...imported].sort()) {
  const linkPath = path.join(NODE_MODULES, ...name.split('/'));
  if (isResolvable(linkPath)) {
    skipped.push(name);
    continue;
  }
  const pkgDir = findPackageDir(name);
  if (!pkgDir) {
    missing.push(name);
    continue;
  }
  fs.mkdirSync(path.dirname(linkPath), { recursive: true });
  try {
    // 'junction' 在 Windows 上免管理员权限；POSIX 上退化为目录符号链接
    fs.symlinkSync(pkgDir, linkPath, 'junction');
    linked.push(name);
  } catch (error) {
    console.error(`  ⚠️ 链接失败 ${name}：${error?.message ?? error}`);
  }
}

if (linked.length > 0) {
  console.log(`已链接原包 workspace 包（${linked.length}）：${linked.join(', ')}`);
}
if (skipped.length > 0) {
  console.log(`已在位，跳过（${skipped.length}）：${skipped.join(', ')}`);
}
if (missing.length > 0) {
  // 这些包没被门禁加载到（多在未加载的源里），缺失不影响本次运行
  console.log(`原包仓未提供（不影响门禁）：${missing.join(', ')}`);
}
