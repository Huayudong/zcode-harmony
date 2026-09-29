# Spec：A9 设置与列表增强（Batch 14 / 计划 §4-A9、CONN-2、列表抽屉增强的 V1 子集）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 14，V1 收尾批） |
| 对应计划 | A9 设置与诊断（基础项）、CONN-2 下拉刷新、列表增强（搜索/分组/置顶/重命名） |
| 模块 | `commons/connection`（Engine 词表 +renameSession；Controller renameSession/restart/clearLocalCache/诊断只读面；SessionCache.clearAll）+ `entry`（pages/settings/Settings 新页；SessionList 重构） |
| 服务端契约 | `renameSession {title}`（既有 v4 命令词表，meta.title 服务端落库，经 sessions-index delta 回流列表） |
| 范围外 | 归档（v4 协议无对应命令，桌面端语义——需协议演进或桌面集成，本批明示"归档请用桌面端"）、浅色主题（M2）、字体大小/代码字体设置（依赖主题 token 体系改造，M2）、网络诊断的 ping/WS 主动探测（本批为状态/水位/队列只读视图 + 手动重连）、通知夜间静默时段（M2） |

## 1. 行为

**设置页**（列表头部 ⚙ 进入）：连接与诊断卡（状态机档位 + 详情 + 订阅水位条数 + 待发命令数 + 重连按钮）；Server 管理卡（档案列表、活跃标记、设为活跃 = saveProfile 切 activeId + controller.restart() 重建连接链，重新配对入口）；通知分级卡（三档 chips，接批次13 的 setNotificationLevel）；外观与存储卡（主题深色默认说明 + 清除本地会话缓存与草稿：SessionCache 双表清空 + 草稿 preferences clear，不动档案与 Asset 凭证）。

**列表增强**：CONN-2 下拉刷新（Refresh 组件 → controller.retry() 重连重订阅，状态事件/5s 超时双保险收起）；本地搜索（标题 + 末条预览包含匹配）；时间分组（今天/近 7 天/更早，置顶条目全局最前带 📌）；长按会话卡片出操作行（置顶/取消置顶、重命名——浮层 TextInput 确认后走 renameSession 幂等命令，改名经 sessions-index delta 回流列表；归档给出桌面端指引文案）。

## 2. 决策与不变量

1. 重命名走服务端命令而非本地改名：meta.title 是服务端权威（titleSource 语义），列表更新以 sessions-index upsert 回流为准，不做本地乐观改标题。
2. 置顶是纯本地偏好（preferences `zcode-pinned`），不影响服务端排序语义（PRD 未定义跨端置顶同步）。
3. 切换活跃档案 = 档案存储原子落盘 + 连接链整体重建（initialize 重走档案→token→CA→server-info→引擎），不 hot-swap 单件。
4. 缓存清理不触碰档案与 Asset 凭证（破坏性最小化）；清除后列表/会话页走空态直至重新同步。
5. 诊断面只读：水位/队列数来自 engine 既有记账，无新协议查询。

## 3. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| S-1 | 一致性门禁（renameSession 词表扩展后回归） | 19/19 | ✅ |
| S-2 | hvigor 构建 | assembleHap BUILD SUCCESSFUL | ✅ |
| S-3 | 真机验收：下拉刷新、分组/置顶/搜索、重命名回流、切档重连、缓存清理后离线空态 | 随 S 系列场景联调 | ⏳ 待真机 |
