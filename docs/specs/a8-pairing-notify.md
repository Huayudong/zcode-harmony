# Spec：配对收口与前台通知（Batch 13 / ONB-2 扫码、CONN-4 指引页、A8 NTY-1/2/4 前台部分）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 13） |
| 对应计划 | ONB-2 扫码配对（Scan Kit）、CONN-4 组网指引页（P0 只指引不集成）、A8 通知（M1 = 前台长连接 + 本地通知；NTY-4 基础分级） |
| 模块 | `entry`（PairingWelcome 扫码入口、NetworkGuide 新页）+ `commons/connection`（WorkbenchController 通知策略与分级持久化） |
| 服务端契约 | 无新增（通知数据全部来自既有订阅流：pendingInteractions 与 sessions-index phase） |
| 范围外 | Push 全链路（M2/E5）、点击直达卡片（wantAgent 路由，随 M2）、实况窗（M2）、通知夜间静默时段（M2）、拍照配对之外的相机能力 |

## 1. 行为

**ONB-2 扫码**：欢迎页「扫码配对」首选入口 → Scan Kit 系统扫码页（`scanBarcode.startScanForResult`，QR_CODE；系统页自管相机权限，App 无需申请）→ 结果经 `isPairLink` 校验：是配对码 → 带 link 进手动导入页预填（复用 ONB-4 流程与指纹校验）；非配对码 toast 提示；取消扫码（错误码 1001）静默。

**CONN-4 指引页**：欢迎页底部「无法直连？查看组网指引」进入图文页：局域网直连条件（首选）/ Tailscale 组网（跨网推荐）/ FRP 反代（自有 VPS）/ 常见问题，四节手风琴折叠。只做指引，App 不代改系统设置。

**A8 前台通知**（NTY-1/2 简化 + NTY-4 基础分级）：
- 分级三档 `approval-only`（默认）/`all`/`off`，preferences 持久化（`zcode-workbench/notifyLevel`），控制器暴露 get/set（设置页批次14接 UI）。
- **等待确认/输入（NTY-1）**：conversation 帧归约后对比 `pendingInteractions`，新 interactionId 去重后按分级发本地通知（approval-only 只推 permission；all 额外推 userInput）。
- **完成通知（NTY-2）**：sessions-index 帧归约后检测阶段迁移到终态（completedSuccess/error/completedInterrupted），仅在 `all` 分级下通知，首个快照不补发历史。
- 通知为前台长连接驱动（控制器只在线时收帧，天然满足"在线抑制"）；publish 失败（未授权）静默记日志，点击直达卡片属 M2。

## 2. 决策与不变量

1. 扫码用 Scan Kit 系统页而非自研相机页：零相机权限管理、系统级扫码体验；isPairLink 校验不通过的一律不进导入页。
2. 通知去重键 = interactionId（幂等，重连后快照重放不重复打扰）；阶段通知键 = sessionId 上一阶段（首见不通知）。
3. 通知策略唯一所有者是 WorkbenchController（事实源：pendingInteractions/phase），页面零参与。
4. 分级默认 approval-only：宁缺勿扰，符合"批准是最高优先级"的产品语义。

## 3. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| N-1 | 一致性门禁（无协议改动回归） | 19/19 | ✅ |
| N-2 | hvigor 构建（Scan Kit/promptAction/notificationManager ArkTS 收敛） | assembleHap BUILD SUCCESSFUL | ✅ |
| N-3 | 真机验收：扫码→预填→配对；指引页四节内容；真机上通知授权/弹出/分级生效 | 随 S1 场景联调 | ⏳ 待真机（扫码/通知硬件路径） |
