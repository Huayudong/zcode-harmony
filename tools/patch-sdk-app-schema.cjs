#!/usr/bin/env node
/**
 * 放宽 SDK 对 app.json5 的 schema 校验，允许 app 节点携带 appIdentifier。
 *
 * 背景：NEXT 7.0 真机强制校验签名 profile 内 app-identifier 与 HAP app.json5 的
 * appIdentifier 一致，缺失即 9568341 install parse bad profile。但 SDK 的
 * modulecheck/app.json 各 bundleType 分支的 propertyNames.enum 均不含该键，
 * hvigor PreBuild 会报 00303038 Schema validate failed。
 *
 * 两种模式：
 *   node tools/patch-sdk-app-schema.cjs              # 就地改 SDK（需管理员权限）
 *   node tools/patch-sdk-app-schema.cjs --shadow DIR # 生成影子 SDK（免管理员）：
 *        DIR/sdk/default 下除 modulecheck 外全部用目录联接指向真实 SDK，
 *        modulecheck 复制一份并就地打补丁；构建时把 DEVECO_SDK_HOME 指向 DIR/sdk 即可。
 *
 * DevEco Studio / SDK 每次升级都会重置该文件，重跑本脚本即可。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DEVECO_DIRS = [
  process.env.DEVECOSTUDIO_HOME,
  'D:/DevEco Studio',
  'D:/Huawei/DevEco Studio',
  'C:/Program Files/Huawei/DevEco Studio',
  'C:/Program Files/DevEco Studio',
].filter(Boolean);

/** 需要打补丁的 schema 相对路径（相对 DevEco 根）。 */
const SCHEMA_RELPATHS = [
  ['sdk', 'default', 'hms', 'toolchains', 'modulecheck', 'app.json'],
  ['sdk', 'default', 'openharmony', 'toolchains', 'modulecheck', 'app.json'],
];

/** 影子模式下需要「实体化」（而非联接）的目录相对 SDK default 根。 */
const SHADOW_REAL_DIRS = [
  ['hms', 'toolchains', 'modulecheck'],
  ['openharmony', 'toolchains', 'modulecheck'],
];

function findDevecoRoot() {
  for (const dir of DEVECO_DIRS) {
    const probe = path.join(dir, ...SCHEMA_RELPATHS[0]);
    if (fs.existsSync(probe)) return dir;
  }
  return null;
}

// 递归收集 app 节点 if/then/else 各分支的 propertyNames.enum
function collectAppEnums(node, out) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node.propertyNames && node.propertyNames.enum)) {
    out.push(node.propertyNames.enum);
  }
  for (const key of ['if', 'then', 'else']) {
    if (node[key]) collectAppEnums(node[key], out);
  }
}

/** 就地给 schema 打补丁：把 appIdentifier 注入所有 app 节点属性枚举。 */
function patchFile(schemaPath, quiet = false) {
  const raw = fs.readFileSync(schemaPath, 'utf8');
  const schema = JSON.parse(raw);
  const app = schema.properties && schema.properties.app;
  if (!app) {
    if (!quiet) console.log(`SKIP  ${schemaPath} (无 app 节点)`);
    return false;
  }
  const enums = [];
  collectAppEnums(app, enums);
  if (enums.length === 0) {
    if (!quiet) console.log(`SKIP  ${schemaPath} (app 节点无 propertyNames 枚举，可能已无需放宽)`);
    return false;
  }
  let changed = false;
  for (const list of enums) {
    if (!list.includes('appIdentifier')) {
      list.push('appIdentifier');
      changed = true;
    }
  }
  if (changed) {
    fs.writeFileSync(schemaPath, JSON.stringify(schema, null, 2), 'utf8');
    if (!quiet) console.log(`PATCH ${schemaPath} (已注入 appIdentifier)`);
  } else if (!quiet) {
    console.log(`OK    ${schemaPath} (已包含 appIdentifier)`);
  }
  return changed;
}

/** 建目录联接（Windows junction 免管理员权限；POSIX 退化为目录符号链接）。 */
function linkDir(target, linkPath) {
  if (fs.existsSync(linkPath)) return false;
  fs.mkdirSync(path.dirname(linkPath), { recursive: true });
  try {
    fs.symlinkSync(target, linkPath, 'junction');
  } catch (e) {
    console.error(`  ⚠️ 联接失败 ${target} → ${linkPath}：${e.message}`);
    return false;
  }
  return true;
}

/**
 * 建文件链接：同卷用硬链接（零拷贝、免权限），跨卷退回复制。
 * 注意：不能用 junction 连文件——junction 只对目录有效，会生成坏链。
 */
function linkFile(target, linkPath) {
  if (fs.existsSync(linkPath)) return false;
  fs.mkdirSync(path.dirname(linkPath), { recursive: true });
  try {
    fs.linkSync(target, linkPath);
    return true;
  } catch {
    try {
      fs.copyFileSync(target, linkPath);
      return true;
    } catch (e) {
      console.error(`  ⚠️ 文件链接失败 ${target} → ${linkPath}：${e.message}`);
      return false;
    }
  }
}

/** 复制目录树（用于 modulecheck 这类需要实体改写的小目录）。 */
function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(s, d);
    } else if (entry.isFile()) {
      fs.copyFileSync(s, d);
    }
  }
}

/**
 * 构建影子 SDK：default 下各目录联接指向真实 SDK，
 * 仅 modulecheck 复制为实体目录以便打补丁。
 */
function buildShadow(devecoRoot, shadowDir) {
  const realDefault = path.join(devecoRoot, 'sdk', 'default');
  const shadowDefault = path.join(shadowDir, 'sdk', 'default');
  fs.mkdirSync(shadowDefault, { recursive: true });

  // 需要实体化的路径集合（相对 shadow default）
  const realPaths = new Set(SHADOW_REAL_DIRS.map((p) => p.join('/')));

  /** 递归把真实目录镜像成影子目录：目录走联接、文件走硬链接，需实体化的整目录复制。 */
  function mirror(realDir, shadowDirCur, relPath) {
    fs.mkdirSync(shadowDirCur, { recursive: true });
    for (const entry of fs.readdirSync(realDir, { withFileTypes: true })) {
      const s = path.join(realDir, entry.name);
      const d = path.join(shadowDirCur, entry.name);
      const rel = relPath ? `${relPath}/${entry.name}` : entry.name;
      if (realPaths.has(rel)) {
        copyDir(s, d);
        console.log(`COPY  ${rel}`);
        continue;
      }
      if (entry.isDirectory()) {
        mirror(s, d, rel);
        continue;
      }
      linkFile(s, d);
    }
  }

  mirror(realDefault, shadowDefault, '');
  return path.join(shadowDir, 'sdk');
}

function main() {
  const argv = process.argv.slice(2);
  const shadowIdx = argv.indexOf('--shadow');
  const root = findDevecoRoot();
  if (!root) {
    console.error('未找到 DevEco Studio 安装目录，请设置 DEVECOSTUDIO_HOME 后重试。');
    process.exit(1);
  }
  console.log(`DevEco: ${root}`);

  if (shadowIdx >= 0) {
    const shadowDir = argv[shadowIdx + 1] || path.join(process.env.TEMP || '.', 'deveco-shadow');
    const sdkHome = buildShadow(root, shadowDir);
    for (const rel of SCHEMA_RELPATHS) {
      const relInDefault = rel.slice(2); // 去掉 sdk/default 前缀
      const p = path.join(shadowDir, 'sdk', 'default', ...relInDefault);
      if (!fs.existsSync(p)) {
        console.log(`MISS  ${p}`);
        continue;
      }
      patchFile(p);
    }
    console.log(`\n影子 SDK 就绪：DEVECO_SDK_HOME=${sdkHome}`);
    console.log(`构建时使用：DEVECO_SDK_HOME="${sdkHome}" <hvigorw> ... assembleHap`);
    return;
  }

  let failed = false;
  for (const rel of SCHEMA_RELPATHS) {
    const p = path.join(root, ...rel);
    if (!fs.existsSync(p)) {
      console.log(`MISS  ${p}`);
      failed = true;
      continue;
    }
    try {
      patchFile(p);
    } catch (e) {
      console.error(`FAIL  ${p}: ${e.message}`);
      failed = true;
    }
  }
  if (failed) {
    console.error('\n就地打补丁失败（SDK 目录通常只对管理员可写）。');
    console.error('改用影子模式（免管理员）：node tools/patch-sdk-app-schema.cjs --shadow <目录>');
    process.exit(1);
  }
}

main();
