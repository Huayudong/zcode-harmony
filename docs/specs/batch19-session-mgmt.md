# Spec：会话管理命令——新建/删除/原生重试（Batch 19 / 计划 §2.2 抽屉「新建按钮」、OUT-7 正解）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 19） |
| 对应计划 | 会话列表抽屉「新建按钮」（M1，此前误判为不可做）、OUT-7 原生重试（retryTurn 替代"重发上一条"取巧实现）、会话删除（deleteSession） |
| 模块 | `commons/protocol`（SessionsIndexModel +workspaceId()）+ `commons/connection`（Engine 词表+sendCommandAwait+CAS 信封；Controller createSession/deleteSession/retryTurn）+ `entry`（SessionList ＋按钮/长按删除；SessionDetail 失败卡 retryTurn） |
| 服务端契约 | `createSession {workspaceId}`（全局命令 sessionId=null；ACK result 回新 sessionId；draft 空会话）；`deleteSession {}`（会话级）；`retryTurn {target{rowId,entityId}}`（**CAS 命令**：信封必须带 baseRevision+baseLogEpoch，过期重试服务端按 stale 拒绝）——三个命令均为既有 v4 词表，零新协议面 |
| 范围外 | 归档（v4 无 archiveSession 命令，仍需协议演进）、editUserQuery（修改后重发的原生形态，后续替换本地实现）、新建时的首输入直达（本批走 draft 空会话） |

## 1. 行为

**新建（M1 抽屉「新建按钮」）**：列表头「＋」→ `createSession`（载荷 workspaceId 取自 sessions-index 快照新捕获的字段；无 firstInput → 服务端建 draft 空会话）→ ACK result.sessionId → 直接路由进新会话页。Agent 由服务端 runtime 创建，手机仅发命令——架构铁律（手机不新起 Agent）不违。

**删除**：长按会话卡操作行新增「删除」（红字）→ `deleteSession` → 服务端权威删除，列表经 sessions-index delta 回流自愈（session.removed）。

**原生重试（OUT-7 正解）**：失败回复卡片「重试本轮」→ `retryTurn`（target=失败行 rowId+entityId）。**行定位命令走 CAS**：信封携带快照 baseRevision+baseLogEpoch（取自 ConversationModel，与 fileChanges 查询同源）；快照过期时服务端按 stale 拒绝——替代此前"重发上一条"的取巧实现（后者保留于「修改后重发」入口）。

## 2. 关键发现与决策

- **此前误判纠正**：批次14 时我把「新建按钮」与归档一起判为"协议不支持"；本轮复读词表发现 createSession/deleteSession/retryTurn/editUserQuery 都在——归档确实无命令，但新建/删除/重试可做。教训：判定"协议不支持"前必须穷举 commandPayloadSchemas 全键。
- **CAS 语义由测试逼出**：首版 retryTurn 信封缺 baseRevision/baseLogEpoch 被门禁拒绝（parseCommandEnvelope 对 ROW_TARGETING_COMMANDS 强制校验）——这正是门禁的价值：把协议语义错误挡在设备之外。
- createSession 走 sendCommandAwait（仅在线、不入队、读 ACK result）；deleteSession/retryTurn 走幂等队列通道。
- workspaceId 是 createSession 必填载荷：SessionsIndexModel 从快照捕获并暴露；索引未就绪时新建按钮给明确提示。

## 3. 不变量

1. retryTurn 信封的 base 必须取自当前会话快照（revision/logEpoch），不得沿用旧值——过期即 stale 拒绝，由服务端裁决。
2. createSession 为全局命令（sessionId=null）；ACK 未回 sessionId 视为失败。
3. 删除不做本地乐观移除：列表以 sessions-index 的 session.removed 回流为准。
4. sendCommandAwait 仅用于需要读结果的命令，不与幂等队列混用。

## 4. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| G-1 | 一致性：createSession（workspaceId 缺失拒绝）/deleteSession/retryTurn（target 成对、**缺 CAS 拒绝**）信封 | 全绿 | ✅ 23/23 |
| G-2 | hvigor 构建（ArkTS 严格模式收敛：对象展开/内联字面量/any 三类修复） | BUILD SUCCESSFUL | ✅ |
| G-3 | 真机验收：新建 draft→发首条消息、删除回流、CAS 重试（含 stale 拒绝路径） | 随 S 系列场景联调 | ⏳ 待真机 |
