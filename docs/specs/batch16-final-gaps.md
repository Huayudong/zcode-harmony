# Spec：V1 收尾补全——问答模式（Q3）/ 拍照直拍 / TaskPool 投递（Batch 16）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 16，V1 可离线实现项的最后一批） |
| 对应计划 | INP-6 问答档（§9-Q3 推荐映射落地）、INP-3 拍照直拍（三入口补全）、OUT-1 TaskPool 投递切换（§6.2/A10） |
| 模块 | `commons/connection`（sendText 的 ask→plan 映射）+ `entry`（问答 chips、📸 CameraPicker、MdParserTask 分块预计算） |
| 服务端契约 | 无新增（ask 档上线为 `mode:'plan'`；cameraPicker 为系统安全组件；TaskPool 为设备并发框架） |

## 1. 行为

- **问答档（INP-6/Q3）**：输入舱模式行新增「问答」第三档。发送时控制器把 `ask` 映射为 `plan` 执行语义（计划 §9-Q3 的推荐方案：问答是 App 端本地概念，落到 plan + 受限提交）；UI 与日志保留 ask 语义。**待产品复核**：Q3 正式定案若与此不同，改动点只有这一处映射。
- **拍照直拍（INP-3）**：输入舱页脚新增 📸——`cameraPicker.pick`（系统安全组件，无需自管相机权限；BACK_CAMERA + PHOTO；本 SDK 形状为三参 pick + PickerProfile 必填 cameraPosition + 单数 resultUri）。拍摄结果走与相册/文件一致的附件上传链。
- **TaskPool 投递（OUT-1）**：`MdParserTask.ets` 以 `@Concurrent` 纯函数投递块级解析（引用导入函数为 API 11+ 能力）；会话页在会话事件路径做**分块预计算**（逐行 taskpool 解析 + 代际守卫丢弃过期填充），渲染取块优先缓存、首帧同步兜底；预览器等不支持环境 catch 后自动降级同步（与设备路径同一纯函数，产出一致）。

## 2. 决策与不变量

1. ask 档是唯一一处 Q3 假设落地点（映射集中在 sendText 一行），产品复核的返工面被刻意最小化。
2. 拍照复用附件上传编排与进度事件，无新状态机；拍照产物与相册产物在服务端不可区分。
3. 分块预计算代际守卫：会话切换/新帧到达使旧填充作废，杜绝乱序写回；渲染兜底（无缓存即同步解析）保证首帧永远有内容。
4. TaskPool 失败自动降级同步——功能可用性不依赖设备并发框架。

## 3. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| F-1 | 一致性门禁（sendText mode 词表回归：plan 合法/ask 不入线级词表） | 22/22 | ✅ |
| F-2 | hvigor 构建（cameraPicker/taskpool ArkTS 收敛，按 SDK d.ts 实际形状） | assembleHap BUILD SUCCESSFUL | ✅ |
| F-3 | 真机验收：拍照→上传→CLI 收图；问答档发送的实际执行语义；TaskPool 并发帧率收益 | 随 S 系列场景联调与性能批 | ⏳ 待真机 |

## 4. 事件记录

本批提交时加密驱动第三次复发且首次**带病推送**（`git add -A` 卷入调试残留 + 9 个密文文件；守卫表达式 `&&…||…&&` 优先级错误形同虚设）。处置：7 个明文文件 stdin 重新入库、3 个杂项条目移出索引、amend 后 force-with-lease 强推修正。教训入长期记忆：扫描/修复/提交严禁 `;` 链无条件执行；`git add -A` 禁用，改为显式文件清单暂存。
