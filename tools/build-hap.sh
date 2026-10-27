#!/bin/bash
# 一步构建 HAP（依赖安装 → 影子 SDK → hvigor assembleHap → 产物路径）。
#
# 用法：
#   bash tools/build-hap.sh              # 按当前 build-profile.json5 的签名配置构建
#   bash tools/build-hap.sh --unsigned   # 忽略签名配置（产物 entry-default-unsigned.hap）
#
# 说明：
# - ohpm 必须用 DevEco 自带 node 跑（系统 node 20 无法 require ESM-only 的 uuid）
# - SDK 目录通常只对管理员可写 → 用影子 SDK（联接镜像 + 可写 modulecheck）承载
#   app.json5 的 appIdentifier schema 放宽，见 tools/patch-sdk-app-schema.cjs --shadow
# - 签名材料路径是机器相关的（旧机路径写死在 build-profile.json5）：
#   真机安装需在 DevEco 里 File → Project Structure → Signing Configs 自动生成签名
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=tools/deveco-env.sh
source "$REPO_ROOT/tools/deveco-env.sh" || exit 1

UNSIGNED=0
for arg in "$@"; do
  [ "$arg" = "--unsigned" ] && UNSIGNED=1
done

echo "== 1. 依赖（ohpm）=="
if [ ! -d "$REPO_ROOT/oh_modules" ] || [ ! -d "$REPO_ROOT/commons/protocol/oh_modules/zod" ]; then
  "$DEVECO_NODE" "$OHPM" install || exit 1
else
  echo "  ✅ oh_modules 已在位"
fi

echo "== 2. SDK schema（appIdentifier 放宽）=="
if [ ! -f "$DEVECO_SDK_HOME/default/openharmony/toolchains/modulecheck/app.json" ]; then
  echo "  ❌ SDK 路径异常：$DEVECO_SDK_HOME"; exit 1
fi
if grep -q '"appIdentifier"' "$DEVECO_SDK_HOME/default/openharmony/toolchains/modulecheck/app.json"; then
  echo "  ✅ SDK schema 已含 appIdentifier（$DEVECO_SDK_HOME）"
else
  echo "  ❌ SDK schema 未含 appIdentifier，重跑：node tools/patch-sdk-app-schema.cjs --shadow \"$SHADOW_SDK_ROOT\""; exit 1
fi

echo "== 3. 构建 =="
PROFILE_BACKUP=""
if [ "$UNSIGNED" = "1" ]; then
  PROFILE_BACKUP="$(mktemp)"
  cp "$REPO_ROOT/build-profile.json5" "$PROFILE_BACKUP"
  node -e "
const fs=require('fs');
const p='build-profile.json5';
let s=fs.readFileSync(p,'utf8');
s=s.replace(/\"signingConfigs\": \[[\s\S]*?\n    \],/, '\"signingConfigs\": [],');
fs.writeFileSync(p,s);
"
  echo "  （--unsigned：已临时清空 signingConfigs，构建后自动还原）"
fi

"$DEVECO_NODE" "$HVIGORW" --mode module -p module=entry@default -p product=default assembleHap --no-daemon
BUILD_RC=$?

if [ -n "$PROFILE_BACKUP" ]; then
  cp "$PROFILE_BACKUP" "$REPO_ROOT/build-profile.json5"
  rm -f "$PROFILE_BACKUP"
  echo "  （已还原 build-profile.json5）"
fi

echo
echo "== 4. 产物 =="
ls -la "$REPO_ROOT"/entry/build/default/outputs/default/*.hap 2>/dev/null || echo "  无 HAP 产物"
exit $BUILD_RC
