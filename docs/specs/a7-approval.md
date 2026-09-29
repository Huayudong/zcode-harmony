# Spec：OUT-3/4 批准卡片（Batch 8 / 计划 §4-A7 首片、M1 准出 S2 的 App 侧）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 8） |
| 对应计划 | §4-A7（OUT-3 工具卡片 + OUT-4 批准/拒绝）、§1.3（批准链路，零协议新增） |
| 模块 | `commons/protocol`（WorkbenchModel 增 pendingInteractions 投影）+ `commons/connection`（ConnectionEngine 词表扩展 resolveInteraction；WorkbenchController 增应答命令面）+ `entry`（SessionDetail 吸底卡片） |
| 服务端契约 | 快照 `pendingInteractions`（permission/userInput/workspaceHookReview）+ 幂等命令 `resolveInteraction {interactionId, answer{optionId/freeText}}`；事实源为原包 schema |
| 范围外 | OUT-4 左滑手势与坍缩动画（本批为按钮 + 状态条）、Vibrator 触感、OUT-3 卡片内 diff/审批预览展开、workspaceHookReview 的手机端决策（仅提示去桌面处理）、AskUserQuestion 多题分步导航（只显示当前题） |

## 1. 行为

会话页收到 `pendingInteractions`（snapshot 或 state.updated delta 整体替换）后，输入面上方吸底出现批准卡片：permission 类显示工具名 + summary + **服务端下发的选项词表按钮**（allowOnce/allowAlways 品牌色实心、deny 红字描边、custom 灰）；userInput 类显示 prompt（多问题取 `questions[currentQuestionIndex]`）与题面选项，`freeText` 时附输入行（`sensitive` 占位提示不进历史）；workspaceHookReview 仅提示在桌面处理。点选即发 `resolveInteraction`（interactionId 幂等），期间按钮锁定并显示「已应答，等待电脑确认…」，服务端投影移除该交互后卡片消失（多端竞态以 CLI 准入为准，App 不做本地裁决）。

## 2. 分层与所有者

```text
commons/protocol
  v4/WorkbenchModel   +PendingInteractionView/OptionView：permission 取 summary/toolName/options；
                      userInput 单问题取 prompt+顶层 options，多问题取当前题；fixture 过原 schema 门禁。
commons/connection
  ConnectionEngine    CommandType 词表 +resolveInteraction（信封仍由 Engine 生成 commandId，幂等排队不变）。
  WorkbenchController +resolveInteraction(sessionId, interactionId, answer)；
                      ConversationUpdate 增 pending 字段（随会话事件下发，页面零协议接触）。
entry
  SessionDetail       ApprovalCard 吸底卡片；resolvingId 锁定应答按钮；服务端投影移除即解锁/坍缩。
所有者边界：应答命令的唯一入口是 controller.resolveInteraction；卡片状态只来自投影（不做本地乐观移除）。
```

## 3. 关键决策

- **按钮词表 = 服务端下发**：permission 不自造「允许/拒绝」，按 `options[]` 渲染（服务端可下发自定义选项），颜色仅按 kind 映射——协议演进不破坏 UI。
- **应答不加本地乐观移除**：卡片消失以服务端投影为准（CLI 准入是唯一事实源）；应答中按钮禁用防重复。
- **离线语义**：resolveInteraction 走 engine 幂等队列，离线入队、重连按序投递（与 sendText 同语义）。
- **投影零新语义**：字段全部防御性提取，多问题 AskUserQuestion 只取当前题（分步导航列入后续）。

## 4. 不变量

1. interactionId 幂等；App 不本地裁决批准结果，CLI 准入为准（计划 §1.3）。
2. 卡片数据唯一来源是 `ConversationModel.pendingInteractions()`（state.updated 整体替换语义与 delta 黄金测试同源）。
3. 应答信封由 Engine 生成 commandId；controller/页面不自行重试。
4. workspaceHookReview 不在手机端出决策按钮（协议要求专用命令，本批范围外）。

## 5. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| P-1 | 一致性：pendingInteractions 投影（permission/userInput/多问题）+ state.updated 坍缩 + resolveInteraction 信封校验（optionId/freeText 过原 schema、缺 answer 拒绝），fixture 先过 `pendingInteractionSchema` | 全绿 | ✅ |
| P-2 | 全套一致性门禁 `npm test` | 17/17 | ✅ |
| P-3 | hvigor 构建 | assembleHap BUILD SUCCESSFUL | ✅ |
| P-4 | 真机联调：S2 外出批准全链路（桌面请求 → 手机卡片 → 应答 → CLI 生效 → 卡片坍缩） | 与 server 端 E2 配对服务联测 | ⏳ 待真机（依赖 W-5 通道） |

运行方式：`cd tools/protocol-consistency && npm test`。

## 6. 风险与后续

- userInput 多题（questions.length>1）只渲染当前题且无法翻题；后续补分步导航与 answerDrafts。
- 左滑手势、坍缩动画、Vibrator 触感（PRD 5.4）未做——OUT-4 的完整交互形态留待 UI 打磨批。
- permission.detail / display（确认预览）未展示，详情展开列入 OUT-3 完整卡片批。
