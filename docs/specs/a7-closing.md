# Spec：A7 收口——滚动体验 / 时间线简版 / 失败重发（Batch 12 / 计划 §4-A7、PRD OUT-1/6/7）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 12） |
| 对应计划 | OUT-1 流式渲染（滚动与浮标部分）、OUT-6 时间线简版、OUT-7 失败重试动作 |
| 模块 | `entry`（SessionDetail：Scroller 滚动控制、时间线、重发） |
| 服务端契约 | 无新增（全部消费既有 rows 投影与 sendText 通道） |
| 范围外 | OUT-1 的增量 markdown AST/16ms 合帧/TaskPool（**待真机性能批**，环境阻塞下无可测目标）、OUT-6 完整 trace 弧线（M2）、OUT-7 的"修改后重发"编辑态 |

## 1. 行为

**滚动（OUT-1 部分）**：对话 List 挂 Scroller；新内容到达时若用户在底部（atBottom）自动滚到底，用户上滑离底（onScrollIndex 判定 end < 末行-2）即暂停自动滚动并显示「↓ 回到底部」品牌色浮标，点击 `scrollEdge(Bottom)` 回底并恢复跟随。

**时间线（OUT-6 简版）**：对话 Tab 顶部常驻可折叠条「任务步骤 · N · 最新: 工具名 状态」；数据 = 当前轮（最后一个 turnHeader 之后）的 toolCall/subagent 行投影，展开后为垂直步骤列表（序号 + 状态灯珠 + 工具名/子代理 + 失败标记）。复用既有 rows 投影，零额外请求。

**失败重发（OUT-7）**：assistantText `state=failed` 的卡片从纯提示升级为「回复生成失败 · 重发上一条」；动作 = 找最近一条 userInput 原文回填输入框语义直接重发（新 commandId，服务端幂等/准入裁决），无可重发输入时提示。

## 2. 决策与不变量

1. 滚动跟随以「用户意图」为准：atBottom 只由 onReachEnd 置真、由 onScrollIndex 判定离底，帧到达本身不改变用户滚动位置。
2. 时间线是 rows 的纯派生（refreshTimeline），不引入第二数据源；当前轮判定 = 最后一个 turnHeader 的 rowId 之后。
3. 重发走 engine.sendCommand 幂等队列（与普通发送同路径），前端不做重试计数/退避。
4. 「修改后重发」需要草稿编辑交互，本批以「原文直发」为 M1 最小可用，编辑态列入 OUT-7 完整版。

## 3. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| R-1 | 一致性门禁（无协议改动回归） | 19/19 | ✅ |
| R-2 | hvigor 构建 | assembleHap BUILD SUCCESSFUL | ✅ |
| R-3 | 真机验收：流式期间的滚动跟随/浮标、时间线步骤推进、失败重发 | 随 S 系列场景联调 | ⏳ 待真机 |
