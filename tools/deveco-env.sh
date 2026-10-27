#!/bin/bash
# DevEco Studio / SDK 环境解析（被 build-hap.sh、render-page.sh 复用）。
#
# 导出：
#   DEVECO_HOME    DevEco Studio 安装根
#   DEVECO_NODE    DevEco 自带 node（系统 node 20 跑不动 ohpm：uuid 是 ESM-only）
#   HVIGORW        hvigor 入口脚本
#   OHPM           ohpm 入口脚本
#   DEVECO_SDK_HOME  构建用 SDK 根（优先影子 SDK，见 patch-sdk-app-schema.cjs --shadow）
#
# 用法：source tools/deveco-env.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 影子 SDK 位置：SDK 目录通常只对管理员可写，影子版用联接镜像 + 可写的 modulecheck
SHADOW_SDK_ROOT="${ZCODE_SHADOW_SDK:-D:/deveco-shadow}"

find_deveco() {
  if [ -n "${DEVECO_HOME:-}" ] && [ -d "${DEVECO_HOME}" ]; then
    echo "${DEVECO_HOME}"; return
  fi
  for c in "D:/DevEco Studio" "D:/Huawei/DevEco Studio" "C:/Program Files/Huawei/DevEco Studio" "C:/Program Files/DevEco Studio" "$HOME/Huawei/DevEco Studio"; do
    if [ -d "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

DEVECO_HOME="$(find_deveco)"
if [ -z "$DEVECO_HOME" ]; then
  echo "❌ 未找到 DevEco Studio（设 DEVECO_HOME 指向安装目录）" >&2
  return 1 2>/dev/null || exit 1
fi

DEVECO_NODE="$DEVECO_HOME/tools/node/node.exe"
HVIGORW="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
OHPM="$DEVECO_HOME/tools/ohpm/bin/pm-cli.js"

# SDK 根：影子优先（app.json5 schema 已注入 appIdentifier），否则用真实 SDK
if [ -f "$SHADOW_SDK_ROOT/sdk/default/sdk-pkg.json" ]; then
  DEVECO_SDK_HOME="$SHADOW_SDK_ROOT/sdk"
elif [ -f "$DEVECO_HOME/sdk/default/sdk-pkg.json" ]; then
  DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
else
  echo "❌ 未找到 SDK（$DEVECO_HOME/sdk 或影子 $SHADOW_SDK_ROOT）" >&2
  return 1 2>/dev/null || exit 1
fi

export DEVECO_HOME DEVECO_NODE HVIGORW OHPM DEVECO_SDK_HOME REPO_ROOT
