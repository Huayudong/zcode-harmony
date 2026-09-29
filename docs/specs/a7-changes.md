# Spec：A7 后半——变更 Tab 与 Diff 卡片（Batch 10 / 计划 §4-A7、§4-A5 三 Tab 骨架、PRD 4.3.4 变更 Tab P0）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 10） |
| 对应计划 | OUT-5 Diff 卡片 + 变更 Tab、OUT-2 代码块、OUT-7 错误视觉、OUT-8 长按操作、A5 三 Tab 骨架（对话/变更/产物占位） |
| 模块 | `commons/protocol`（AgentV4Stub/AgentV4Client 增 conversationFileChangesV4 只读查询；WorkbenchModel 增 diff 报告投影）+ `commons/connection`（ConnectionEngine/WorkbenchController 查询面）+ `entry`（SessionDetail 三 Tab 重构） |
| 服务端契约 | `conversationFileChangesV4`（IZCodeAgentService 只读查询，params：sessionId + target{rowId,entityId} + baseRevision + baseLogEpoch；result：files/additions/deletions/state + items[path,±,writeCount,toolNames,patches[readonlyDiffHunk]]）；schema 已随批次6 transport 子集入库，本批零新协议面 |
| 范围外 | 全屏 diff 查看器（第三级钻取）、产物 Tab 网格预览（P1 占位）、OUT-1 流式管线增强（增量 markdown/TaskPool/回到底部浮标）、OUT-7 的"重试/修改后重发"动作（本批只做失败视觉）、OUT-6 时间线 |

## 1. 行为

会话页头部下新增三 Tab（对话 / 变更 / 产物占位）。变更 Tab：横滑轮次 chips（来自 turnHeader 的 fileChanges 聚合，默认选中最新轮）→ 切换即发 `conversationFileChangesV4` 只读查询（baseRevision/baseLogEpoch 取自当前快照，快照未就绪给明确提示）→ 总览条（n 个文件 · +N/−M · 已回退）→ 文件列表（路径 + ± 徽标 + 改动来源工具）→ 点击展开该文件的 hunks（行首 +/- 语义着色，DIFF_ADD/DIFF_DEL 底色，等宽字体）。对话 Tab：assistantText 按 ``` 围栏切分为正文/代码段——代码段带语言徽标、一键复制（pasteboard）、超 20 行折叠；流式中未闭合围栏按暂态代码渲染防闪烁；失败回复卡片化提示；长按消息（userInput/assistantText）弹出内联操作行（复制 / 引用到输入框 `> …`）。

## 2. 关键决策

- **fileChanges 是只读查询不是命令**：与原包同构（rows/range、plans 同族——只读、无状态、超时重发安全），不进 commandId 幂等队列；离线/快照未就绪直接抛错由页面提示，不做缓存（M1）。
- **target = turnHeader 行的 rowId+entityId**：轮次聚合显示用 row 上现成的 `fileChanges` 汇总（files/additions/deletions），点开才拉 hunks——列表零额外请求。
- **代码块渲染在投影后切分**：`splitCodeBlocks` 在页面域按围栏切分（正文的 markdown 语法元素本批仍按纯文本渲染），未闭合围栏按代码暂态渲染——OUT-1 增量管线落地前的过渡方案。
- **长按操作用内联操作行**而非菜单组件：菜单 API 在当前 SDK 的形状未验证，内联行零风险且可扩展。

## 3. 不变量

1. 只读查询与命令通道分离：fileChanges 不入 PendingCommandQueue、不生成 commandId。
2. 变更 Tab 的轮次列表只来自订阅流的 turnHeader 聚合；hunks 只在展开时拉取。
3. 查询参数的 baseRevision/baseLogEpoch 一律取自当前会话快照（ConversationModel.revision()/logEpoch()），页面不自行拼装。
4. 投影零新语义：diff 行内容原样透传（+/-/空格语义由服务端 lines 携带），着色仅按行首字符。

## 4. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| C-1 | 一致性：fileChanges result fixture 过移植 schema → parseFileChangesResult 视图（totals/items/hunk lines/toolNames 合并）；turnHeader.fileChanges 聚合与 entityId 进 RowView；快照 revision/logEpoch 可取 | 全绿 | ✅ |
| C-2 | 全套一致性门禁 `npm test` | 19/19 | ✅ |
| C-3 | hvigor 构建 | assembleHap BUILD SUCCESSFUL | ✅ |
| C-4 | 真机验收：变更 Tab 与桌面实际文件改动一致性、代码块折叠/复制、长按引用 | 随 S 系列场景联调 | ⏳ 待真机 |

## 5. 风险与后续

- 未闭合围栏的暂态代码渲染在流式尾部可能闪一次（闭合瞬间从"暂态代码"切换为"代码+后续正文"）；OUT-1 增量管线会一并解决。
- 大 diff（千行级）无虚拟化，折叠默认收起是当前的止损；全屏查看器与懒加载列入 OUT-5 完整版。
- 产物 Tab 仍为占位（P1，依赖 artifact 分块读取）。
