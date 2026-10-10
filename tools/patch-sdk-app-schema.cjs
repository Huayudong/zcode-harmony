#!/usr/bin/env node
/**
 * 放宽本机 SDK 对 app.json5 的 schema 校验，允许 app 节点携带 appIdentifier。
 *
 * 背景：NEXT 7.0 真机强制校验签名 profile 内 app-identifier 与 HAP app.json5 的
 * appIdentifier 一致，缺失即 9568341 install parse bad profile。但 SDK 的
 * modulecheck/app.json 各 bundleType 分支的 propertyNames.enum 均不含该键，
 * hvigor PreBuild 会报 00303038 Schema validate failed。
 *
 * DevEco Studio / SDK 每次升级都会重置该文件，重跑本脚本即可：
 *   node tools/patch-sdk-app-schema.cjs
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DEVECO_DIRS = [
  process.env.DEVECOSTUDIO_HOME,
  'D:/Huawei/DevEco Studio',
  'C:/Program Files/Huawei/DevEco Studio',
].filter(Boolean);

const SCHEMA_RELPATHS = [
  ['sdk', 'default', 'hms', 'toolchains', 'modulecheck', 'app.json'],
  ['sdk', 'default', 'openharmony', 'toolchains', 'modulecheck', 'app.json'],
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

function patch(schemaPath) {
  const raw = fs.readFileSync(schemaPath, 'utf8');
  const schema = JSON.parse(raw);
  const app = schema.properties && schema.properties.app;
  if (!app) {
    console.log(`SKIP  ${schemaPath} (无 app 节点)`);
    return false;
  }
  const enums = [];
  collectAppEnums(app, enums);
  if (enums.length === 0) {
    console.log(`SKIP  ${schemaPath} (app 节点无 propertyNames 枚举，可能已无需放宽)`);
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
    console.log(`PATCH ${schemaPath} (已注入 appIdentifier)`);
  } else {
    console.log(`OK    ${schemaPath} (已包含 appIdentifier)`);
  }
  return changed;
}

const root = findDevecoRoot();
if (!root) {
  console.error(`未找到 DevEco Studio 安装目录，请设置 DEVECOSTUDIO_HOME 后重试。`);
  process.exit(1);
}
console.log(`DevEco: ${root}`);
let failed = false;
for (const rel of SCHEMA_RELPATHS) {
  const p = path.join(root, ...rel);
  if (!fs.existsSync(p)) {
    console.log(`MISS  ${p}`);
    failed = true;
    continue;
  }
  try {
    patch(p);
  } catch (e) {
    console.error(`FAIL  ${p}: ${e.message}`);
    failed = true;
  }
}
process.exit(failed ? 1 : 0);
