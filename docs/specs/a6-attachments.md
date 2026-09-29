# Spec：A6 补全——附件（INP-3）与 @ 引用（INP-4）（Batch 11 / 计划 §4-A6、L3 stub 扩展）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 11） |
| 对应计划 | INP-3 附件（v4 分块上传）、INP-4 @ 引用（workspaceFileSearch）；§5.2 服务桩扩展 |
| 模块 | `commons/protocol`（AgentV4Stub +attachment 四方法/WorkspaceFileStub；AgentV4Client 透传含 connectionId 注入与结果 schema 校验）+ `commons/connection`（Engine 查询/上传透传；Controller 上传编排与进度事件、sendText 带 attachments）+ `entry`（📎 选图/选文件、上传 chips、@ 面板） |
| 服务端契约 | zcode-agent 通道 `attachmentBeginV4/attachmentChunkV4/attachmentCommitV4/attachmentAbortV4`（schema 批次6已移植：≤512KiB/块、20MiB 总量、64 块上限、sha256 校验和）；file 通道 `searchWorkspaceFiles`（Host 索引模糊检索，返回有界候选）——/ws 上全服务暴露 |
| 范围外 | 拍照直拍（CameraKit 流程，待真机验证后补）、图片缩略图预览（chips 暂为文件名徽标）、@ 面板的会话/模式分组（本批仅文件档）、mention 的目录尾斜杠归一化完整规则 |

## 1. 行为

**附件（INP-3）**：输入舱页脚 📷/📄 分别唤起系统相册选择器（PhotoViewPicker，图片多选）与文件选择器（DocumentViewPicker，多选）；选中之文件全量读入沙箱字节（20MiB 上限读取时即拦截）→ 控制器编排上传：`begin`（客户端生成 uploadId=UUID、总量、分块数、`sha256:<hex>` 校验和，cryptoFramework 增量计算）→ 顺序 `chunk`（≤512KiB/块 base64，nextChunkIndex 以服务端 ACK 为准）→ `commit` 换 `ref`。上传期间 chip 显示 `上传 n/N` 进度，失败红框标错并尽力 `abort`（TTL 5min 兜底）；✕ 可移除（上传中先 abort）。发送时只有 ready 附件随 `sendText.attachments`（attachmentRef：ref/fileName/mime/bytes）提交，发送成功整组清除；有 uploading 附件时发送被守卫拦截。

**@ 引用（INP-4）**：主输入框以 `@` 结尾即弹出面板（记录前缀锚点）；面板内 TextInput 300ms 去抖调 file 通道模糊搜索（≤30 条：文件名 + 相对路径 + 类型图标），点选插入标准 mention 转译 `[basename](relativePath)`（目录补尾斜杠、标签/目标做基本转义），主输入框改动超出前缀锚点自动关面板。

## 2. 关键决策

- **上传是服务调用不是命令**：不进 commandId 幂等队列（与原包同族语义：只读/无状态、TTL 兜底）；离线直接 failed，不做断点续传（M1）。
- **connectionId 由客户端层自动注入**（取 hello.connectionId），编排层不接触连接细节；三个结果 schema（begin/chunk/commit）在客户端层 `parse` 校验。
- **mention 转译与桌面同格式** `[label](path)`（桌面 fileMentionProvider 的标准转译），保证 CLI 侧识别一致；目录补 `/`。
- **全量读入内存**：20MiB 上限内可行，避免分片读文件的复杂度；超限在选择器读取阶段即报错。
- **进度用整表事件**（AttachmentUpdate{sessionId, items[]}）：附件组通常 ≤5 个，整表下发最简单且与批次7/8 的事件风格一致。

## 3. 不变量

1. 上传/搜索与命令通道分离（不入 PendingCommandQueue、无 commandId）；发送本身仍走幂等队列。
2. 只有 `state=ready && ref 非空` 的附件才会进入信封 attachments。
3. 分块大小/总量/块数上限以 PROTOCOL_V4_LIMITS 为唯一事实源。
4. 页面不直接调用 stub/engine 上传方法，一律经 controller 编排（进度事件驱动 UI）。

## 4. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| A-1 | 一致性：端到端/版本锁（AgentV4Client 构造路径覆盖新桩接线） | 依旧全绿 | ✅ |
| A-2 | 全套一致性门禁 `npm test` | 19/19 | ✅ |
| A-3 | hvigor 构建（含 picker/_cryptoFramework/Base64Helper ArkTS 收敛） | assembleHap BUILD SUCCESSFUL | ✅ |
| A-4 | 真机验收：相册/文件选择→上传进度→发送→CLI 收到附件；@ 搜索命中与 mention 转译 | 与 server 端联测 | ⏳ 待真机（picker 在预览器不可用） |

## 5. 风险与后续

- 拍照直拍未做（CameraKit 权限/保存位流程需真机调试），PRD INP-3 的三入口缺一——列入真机批补齐。
- 上传无断点续传/并发多文件排队（顺序 await）；20MiB 内体验可接受，后续按需增强。
- mention 目录归一化只做了尾斜杠，桌面 normalizeFileMentionRelativePath 的完整规则（反斜杠等）未移植。
