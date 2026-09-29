# Spec：OUT-1 增量渲染——离线可开发部分（Batch 15 / 计划 §4-A10+OUT-1、PRD 6.2）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 15，OUT-1 的非硬件依赖部分） |
| 对应计划 | OUT-1 流式渲染管线（§6.2）：markdown 增量解析结构、16ms 合帧；TaskPool 为真机批预留 |
| 模块 | `commons/utils`（markdown/MarkdownBlocks.ts 纯函数解析器，node 门禁覆盖）+ `commons/connection`（fireConversation 16ms 合帧）+ `entry`（SessionDetail 分块渲染改造，替代批次10 的 splitCodeBlocks） |
| 服务端契约 | 无新增 |
| 范围外（真机性能批） | TaskPool 调用点切换（解析器已是纯函数可直接投递，但切换需 Profiler 基线对比）、AST 帧间 diff 补丁（当前为块级 key 复用）、长会话虚拟化 |

## 1. 行为

**块级解析结构**（`parseMarkdownBlocks`）：正文 → paragraph / heading(1-6) / list(有序·无序) / quote / code 块；行内一层 **bold** 与 \`code\`（span 化）。**增量语义**：流式尾部追加只影响尾部块，前缀块形状逐字段稳定——`mdBlockKey()` 把形状+内容长度编成 ForEach key，前缀块 key 不变 → ArkUS 组件复用不重建（整表重绘框架下的增量落点）。未闭合围栏 `closed=false` 按暂态代码渲染（语言徽标带「· 输出中」），闭合后自然升级。**渲染改造**：assistantText 从整段 Text 变为分块 builder（标题层级字号 / 列表符与序号 / 引用左标线 / 行内样式 Span / 代码块），失败态降灰逻辑保留。

**16ms 合帧**：`fireConversationThrottled` 前沿+尾沿节流——flush 窗口内连发的 conversation 帧合并为每 16ms 一次视图事件（首帧立即绘，尾沿补一次），对话页整表重绘频率与显示刷新率对齐。

## 2. 决策与不变量

1. 解析器是纯函数、无闭包捕获、无平台 API——双端可运行、node 门禁直接覆盖，且为 TaskPool 就绪（投递点切换留给有 Profiler 基线的真机批）。
2. 增量正确性以测试固化：追加前后「前缀块 deep-equal + key 相等、尾部块 key 变化」是门禁断言，不是注释承诺。
3. 块级渲染的 key 必须含 `mdBlockKey(block)`（形状+内容长度），缺失会退化为全量重建。
4. 合帧只作用于对话页视图事件（16ms 前沿+尾沿）；缓存写穿、通知检测、水位记账不受节流影响（逐帧执行）。
5. 行内嵌套/表格/多级列表刻意不做（纯文本兜底），schema 演进空间留给真实设备上的性能与体验反馈。

## 3. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| M-1 | node 门禁 `markdown-blocks.test.mjs`：块级解析、行内样式、**增量语义（前缀块 deep-equal + key 稳定、尾部块 key 变化）**、未闭合围栏、空输入防御 | 3 组全绿 | ✅ |
| M-2 | 全套一致性门禁 `npm test` | 22/22 | ✅ |
| M-3 | hvigor 构建（utils 新 TS 模块 + Span 行内渲染 ArkTS 收敛） | assembleHap BUILD SUCCESSFUL | ✅ |
| M-4 | 真机性能批：TaskPool 投递切换 + 16ms 合帧帧率实测（6.3 表：chunk 上屏≤50ms、长会话滚动丢帧<1%） | DevEco Profiler 基线对比 | ⏳ 待真机（环境恢复后第一优先） |
