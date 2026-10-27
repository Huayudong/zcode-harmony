#!/bin/bash
# 逐页预览渲染：重生成 FakeUIAbility(loadContent 指向目标页) → PreviewBuild → 引擎渲染 → 抓帧
#
# 仓库路径按脚本自身位置推导；DevEco/SDK 环境复用 tools/deveco-env.sh（含影子 SDK）。
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_WIN="$(cygpath -w "$REPO_ROOT")"

# shellcheck source=../deveco-env.sh
source "$REPO_ROOT/tools/deveco-env.sh" || exit 1

ENGINE="$DEVECO_HOME/sdk/default/openharmony/previewer/common/bin/Previewer.exe"
FAKE="$REPO_ROOT/entry/.preview/fakeuiability/FakeUIAbility.ets"
BUILD_LOG="$REPO_ROOT/entry/.preview/build.log"

# 预览产物根（首次跑没有，必须先建，否则 FakeUIAbility 与 build.log 无处落盘）
mkdir -p "$(dirname "$FAKE")" "$(dirname "$BUILD_LOG")"

run_preview_build() {
  cd "$REPO_ROOT" || return 1
  "$DEVECO_NODE" \
    "$HVIGORW" --mode module -p module=entry@default -p product=default \
    -p pageType=page -p compileResInc=true -p previewMode=true -p buildRoot=.preview PreviewBuild --no-daemon \
    > "$BUILD_LOG" 2>&1
  grep -q "BUILD SUCCESSFUL" "$BUILD_LOG"
}

PAGES=(
  "pages/pairing/PairingWelcome|欢迎页"
  "pages/pairing/PairingCodeInput|输入码页"
  "pages/pairing/PairingSelfCheck|自检页"
  "pages/workbench/SessionList|工作台-会话列表"
  "pages/workbench/SessionDetail|工作台-会话详情"
)
# 只渲染命令行传入的页名（子串匹配）；不传参渲染全部
ONLY="${1:-}"
for entry in "${PAGES[@]}"; do
  URL="${entry%%|*}"; NAME="${entry##*|}"
  if [ -n "$ONLY" ] && [[ "$NAME" != *"$ONLY"* && "$URL" != *"$ONLY"* ]]; then
    continue
  fi
  cat > "$FAKE" <<EOF
import {AbilityConstant, UIAbility, Want} from '@kit.AbilityKit';
import {hilog} from '@kit.PerformanceAnalysisKit';
import {window} from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class FakeUIAbility extends UIAbility {
    onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('${URL}', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
EOF
  echo "== [$NAME] PreviewBuild ($URL)..."
  if ! run_preview_build; then
    echo "BUILD-FAILED for $URL"
    tail -5 "$BUILD_LOG"
    continue
  fi
  taskkill //IM Previewer.exe //F >/dev/null 2>&1; sleep 1
  # SDK 26 预览产物布局：JS 产物在 loader_out/default/ets（modules.abc），
  # 无 config/buildConfig.json（-cjp 已移除）。用旧 SDK 12 布局会报
  # "Launch -j parameters abnormal! Js app path not exist."
  ("$ENGINE" -refresh region -projectID zc5 -ts trace_zc5_commandPipe \
    -rt "${REPO_WIN}\\entry\\.preview\\default\\intermediates\\res\\default\\ResourceTable.txt" \
    -rp "${REPO_WIN}\\entry\\.preview\\default\\intermediates\\res\\default" \
    -r Module \
    -j "${REPO_WIN}\\entry\\.preview\\default\\intermediates\\loader_out\\default\\ets" \
    -ljPath "${REPO_WIN}\\entry\\.preview\\default\\intermediates\\loader\\default\\loader.json" \
    -s zc5_pipe -device phone -shape rect -sd 480 -or 1080 2340 -cr 360 780 -n entry -url "$URL" \
    -av ACE_2_0 -pm Stage -pages main_pages -d "" -abn FakeUIAbility \
    -abp "@normalized:N&&&entry/.preview/fakeuiability/FakeUIAbility&" \
    -arp "${REPO_WIN}\\entry\\.preview\\default\\intermediates\\res\\default" \
    -hsp "$(cygpath -w "$DEVECO_HOME/sdk/default/hms/previewer")" -cpm false >/dev/null 2>&1 &)
  sleep 13
  echo "== [$NAME] grabbing..."
  # 前台抓帧：脚本内部自动发现引擎端口、收集 8s 帧后自退（引擎先起，无需 wait）
  if node "$REPO_ROOT/tools/preview/wait-and-grab.js" \
    "$REPO_ROOT/docs/preview-${NAME}.jpg" 8000; then
    echo "== [$NAME] grabbed"
  else
    echo "== [$NAME] GRAB-FAIL"
  fi
  taskkill //IM Previewer.exe //F >/dev/null 2>&1
  sleep 1
done
echo ALL-DONE
