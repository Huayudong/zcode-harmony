#!/bin/bash
# 联调就绪检查（S1/S2/S4 前置）：设备接入后第一件事跑这个。
# 用法: bash tools/device-readiness.sh
HDC="D:/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc"
FAIL=0

echo "== 1. 一致性门禁 =="
if (cd /e/program/zcode-harmony/tools/protocol-consistency && npm test 2>&1 | grep -q "# fail 0"); then
  echo "  ✅ 全绿"
else
  echo "  ❌ 测试未全绿"; FAIL=1
fi

echo "== 2. HAP 产物 =="
HAP=$(ls /e/program/zcode-harmony/entry/build/default/outputs/default/*.hap 2>/dev/null | head -1)
if [ -n "$HAP" ]; then
  echo "  ✅ $HAP"
else
  echo "  ❌ 无 HAP：先跑 assembleHap"; FAIL=1
fi

echo "== 3. 签名配置 =="
if grep -q '"signingConfigs": \[\]' /e/program/zcode-harmony/build-profile.json5; then
  echo "  ❌ signingConfigs 为空：DevEco → File → Project Structure → Signing Configs 勾选 Automatically generate（需登录华为账号）后重新构建"; FAIL=1
else
  echo "  ✅ 已配置签名"
fi

echo "== 4. 真机接入 =="
TARGETS=$("$HDC" list targets 2>/dev/null | grep -v Empty | head -1)
if [ -n "$TARGETS" ]; then
  echo "  ✅ 设备: $TARGETS"
else
  echo "  ❌ 无设备（hdc list targets 为空）：插真机并在手机上允许 USB 调试"; FAIL=1
fi

echo "== 5. 桌面 Server（S1 前置，人工确认）=="
echo "  ⚠️ 电脑端 ZCode 运行中 + 设置里开启「移动端配对」+ 防火墙放行端口"

echo
if [ $FAIL -eq 0 ]; then
  echo "READY：全部就绪 → 按 docs/scene-checklist.md 执行 S1/S2/S4，hilog 过滤 PerfMarks 读 6.3 指标"
else
  echo "NOT-READY：解决以上 ❌ 项后重跑本脚本"
fi
