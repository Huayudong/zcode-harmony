#!/bin/bash
# 逐页预览渲染：重生成 FakeUIAbility(loadContent 指向目标页) → PreviewBuild → 引擎渲染 → 抓帧
set -u
ENGINE="D:/Huawei/DevEco Studio/sdk/default/openharmony/previewer/common/bin/Previewer.exe"
FAKE="E:/program/zcode-harmony/entry/.preview/fakeuiability/FakeUIAbility.ets"

run_preview_build() {
  cd /e/program/zcode-harmony || return 1
  DEVECO_SDK_HOME="D:/Huawei/DevEco Studio/sdk" "D:/Huawei/DevEco Studio/tools/node/node.exe" \
    "D:/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" --mode module -p module=entry@default -p product=default \
    -p pageType=page -p compileResInc=true -p previewMode=true -p buildRoot=.preview PreviewBuild --no-daemon \
    > /e/program/zcode-harmony/entry/.preview/build.log 2>&1
  grep -q "BUILD SUCCESSFUL" /e/program/zcode-harmony/entry/.preview/build.log
}

PAGES=(
  "pages/pairing/PairingWelcome|欢迎页"
  "pages/pairing/PairingCodeInput|输入码页"
  "pages/pairing/PairingSelfCheck|自检页"
)
for entry in "${PAGES[@]}"; do
  URL="${entry%%|*}"; NAME="${entry##*|}"
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
    tail -5 /e/program/zcode-harmony/entry/.preview/build.log
    continue
  fi
  taskkill //IM Previewer.exe //F >/dev/null 2>&1; sleep 1
  ("$ENGINE" -refresh region -projectID zc5 -ts trace_zc5_commandPipe \
    -rt "E:\\program\\zcode-harmony\\entry\\.preview\\default\\intermediates\\res\\default\\ResourceTable.txt" \
    -rp "E:\\program\\zcode-harmony\\entry\\.preview\\default\\intermediates\\res\\default" \
    -cjp "E:\\program\\zcode-harmony\\entry\\.preview\\config\\buildConfig.json" -r Module \
    -j "E:\\program\\zcode-harmony\\entry\\.preview\\default\\intermediates\\assets\\default\\ets" \
    -ljPath "E:\\program\\zcode-harmony\\entry\\.preview\\default\\intermediates\\loader\\default\\loader.json" \
    -s zc5_pipe -device phone -shape rect -sd 480 -or 1080 2340 -cr 360 780 -n entry -url "$URL" \
    -av ACE_2_0 -pm Stage -pages main_pages -d "" -abn FakeUIAbility \
    -abp "@normalized:N&&&entry/.preview/fakeuiability/FakeUIAbility&" \
    -arp "E:\\program\\zcode-harmony\\entry\\.preview\\default\\intermediates\\res\\default" \
    -hsp "D:\\Huawei\\DevEco Studio\\sdk\\default\\hms\\previewer" -cpm false >/dev/null 2>&1 &)
  sleep 13
  PID=$(tasklist //FI "IMAGENAME eq Previewer.exe" 2>/dev/null | tail -1 | awk '{print $2}')
  PORT=$(netstat -ano 2>/dev/null | grep "LISTENING" | grep " $PID" | grep "127.0.0.1" | head -1 | awk '{print $2}' | sed 's/127.0.0.1://')
  echo "== [$NAME] pid=$PID port=$PORT"
  node /e/program/zcode-harmony/.preview-grab.js "$PORT" "E:/program/zcode-harmony/docs/preview-${NAME}.jpg"
  taskkill //PID "$PID" //F >/dev/null 2>&1
  sleep 1
done
echo ALL-DONE
