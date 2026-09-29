# Spec：A5 工作台 UI——会话列表、渲染管线与缓存（Batch 7 / 计划 §4-A5）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 7） |
| 对应计划 | `PLAN-ZCode-Harmony.md` §4-A5（工作台最小可用：列表页、渲染管线、SQLite 缓存） |
| 模块 | `commons/protocol`（v4/WorkbenchModel 投影层）+ `commons/connection`（workbench/SessionCache、workbench/WorkbenchController）+ `entry`（pages/workbench/SessionList、pages/workbench/SessionDetail、Index 改造） |
| 服务端契约 | 同批次6：sessions-index / conversation 订阅（带水位）、sendText/stop 命令信封；事实源为原包 schema |
| 范围外 | OUT-3/4 批准卡片（本批仅展示待处理计数徽标，入口与卡片留待下批）、ONB-2 相机扫码、artifact/hookInvocation 的完整展示、子代理下钻（childSessionId 已保留在投影中）、子代理 conversation 内嵌、缓存水位持久化（快照级缓存，重开会话回全量 snapshot） |

## 1. 行为

配对完成后，App 启动即进工作台：Index 检测到活跃档案 → replace 到会话列表页。列表页数据来自 sessions-index 订阅归约（在线实时 upsert/remove），离线或冷启动时先渲染 SQLite 缓存并在头部标明「离线 · 显示缓存」；点击会话进会话页，订阅 conversation 流，行视图随 snapshot/delta 实时重绘；底部输入面发 sendText（离线自动入队、重连按幂等 commandId 投递），会话有流式工作时出现停止按钮（stop）。会话页关闭即收缩订阅并立即落盘缓存。

## 2. 分层与所有者

```text
commons/protocol（纯逻辑，node/设备双端可运行；一致性门禁覆盖）
  v4/WorkbenchModel        投影层：订阅帧 → 具体类型视图（SessionSummaryView/ConversationRowView）。
                           行归并复用 apply.ts（黄金测试同语义源），本层零自研分支；
                           对内 any 搬运、对外具体接口（延续批次6 zod 类型边界决策）。
commons/connection（ArkTS 适配层）
  workbench/SessionCache   SQLite（@ohos.data.relationalStore）两表：sessions(workspaceKey 主键，
                           列表整表 JSON)、conversations(sessionId 主键，快照 JSON)。全部方法兜底，
                           失败按无缓存处理，绝不阻塞在线路径。
  workbench/WorkbenchController 进程级单例，连接链与工作台状态的唯一所有者：
                           档案 → AssetTokenStore(token) → 沙箱 CA 副本 → server-info(workspace target)
                           → clientId(preferences 持久 UUID) → ConnectionEngine；帧按 topic 前缀分发
                           归约，写穿缓存；对外只暴露事件（state/sessions/conversation/fault）与查询面。
entry
  pages/workbench/SessionList     列表页：连接状态头（重试入口）+ 会话卡片（标题/阶段灯/预览/相对时间/
                                  待处理徽标）+ 空态（未配对→配对按钮、在线无会话→引导文案）。
  pages/workbench/SessionDetail   会话页：9 类行视图（userInput 气泡、assistantText 正文、reasoning
                                  折叠展开、toolCall 状态行、subagent、artifact、turnHeader 分隔、
                                  timelineMarker/hookInvocation 弱化行）+ 输入面（TextInput + 发送/停止）。
  pages/Index（改造）             已配对自动 replace 进工作台；未配对保持 ONB-1 原样。
所有者边界：engine 与模型只在控制器内被引用；页面不触碰协议对象；缓存写入只发生在控制器（1.5s 去抖 + 关页即写）。
```

## 3. 关键决策

- **投影层放协议模块**而非 .ets 消费端：保持 node 可测、纳入一致性门禁；.ets 页面拿到的是具体类型视图，不接触 zod any 边界。
- **缓存粒度**：列表按工作区一行（整表 JSON，snapshot 全量覆盖语义与会话列表 delta 天然对齐）；会话按 sessionId 一行快照。delta 高频流式期间 1.5s 去抖写穿，会话页关闭立即落盘——重启后列表缓存直出、会话缓存先行，随后订阅 snapshot 覆盖（引擎侧关闭会话已清水位，重开回全量，不做缓存水位续传）。
- **连接三要素重建**：档案存 host/port/fingerprint（`p_<serverId>`），token 在 Asset Kit、CA 在沙箱 `tls/server-ca.pem`——冷启动从沙箱读回 CA，再经 server-info 换 workspacePath/workspaceIdentity（不落盘，每次启动向服务端取）。任一环节失败落成带原因的 offline 态（no-profile/no-token/unreachable/no-workspace），UI 给重试或重新配对入口。
- **离线输入语义**：sendText/stop 一律 `engine.sendCommand`（非 online 入队、重连 flush、commandId 幂等）；离线发送成功后 UI 明示「已入队」。engine 为 null（连接链失败）时才直接报错。
- **预览器/CI 降级**：Asset Kit 不可用 → 显式「设备凭证不可用」停机态（不静默降级，沿用批次5原则）；SQLite/preferences 失败 → 无缓存空态，页面仍可渲染。

## 4. 不变量

1. 页面不 import engine/协议运行时对象，只消费控制器事件与查询面（渲染层可替换）。
2. 行归并唯一实现是协议层 `applyConversationDeltas`；投影只做字段提取（防御性取值），不引入语义分支。
3. 帧载荷不再二次 schema 校验（AgentV4Client 装配时已过 schema）；投影必须容忍字段缺席。
4. 缓存读写任何异常不得影响在线路径（SessionCache 内部全兜底 + 控制器判空）。
5. `pendingInteractionCount` 读自 `pendingInteractionSummary`（permission+userInput 计数），本批仅作徽标，不构成 OUT 卡片。
6. 命令信封由 Engine 生成 commandId（批次6不变量），控制器与页面不自行重试。

## 5. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| W-1 | 一致性：`workbench-model.test.mjs`——fixture 先过原 schema（sessionSummary/rows/delta），再断言投影、delta 归并、缓存 JSON 往返与坏帧防御 | 3 组全绿 | ✅ |
| W-2 | 全套一致性门禁 `npm test` | 16/16（原 13 项 + 新 3 项） | ✅ |
| W-3 | hvigor 构建（含 ohpm zod 打包与 ArkTS 严格模式） | assembleHap BUILD SUCCESSFUL | ✅ |
| W-4 | 预览渲染：会话列表页 / 会话详情页（tools/preview/render-page.sh，抓帧机制已修复为 render-page.js 单进程编排） | 布局与配色符合 uikit 主题 | ⏳ 环境阻塞：对照实验（未改动的 PairingWelcome 页 + 同一工具链）同样 NO-FRAMES，engine.log 报 `create object instance failed`/`windowstage.abc GetFileBuffer failed`——预览器在本机无法加载自身 SDK 模块（疑与 TSD 加密驱动对 Previewer.exe 的文件读取有关，批次4 的 .preview 产物从终端视角校验为明文）；页面代码已过 W-3 ArkTS 编译，待环境恢复后补渲染 |
| W-5 | 真机联调：在线列表、流式渲染、离线缓存、发送/停止、断网重连 | 与桌面端互操作 | ⏳ 待真机（预览器无网络与 Asset Kit） |

运行方式：`cd tools/protocol-consistency && npm test`。**本批环境迁移**：F: 盘原包安装已残缺（仅剩 .git），一致性测试默认原包路径切到 E 盘完整仓 `E:/program/zcode/packages/{rpc,shared}/src`（`ZCODE_RPC_SRC`/`ZCODE_SHARED_SRC` 可覆盖）；原包 shared 源的 zod 依赖按批次6既定 vendor 模式补齐（协议 HAR 自带 tarball 解入测试 node_modules + tsconfig paths）。

## 6. 风险与后续

- 列表/会话缓存是快照级：重开会话回全量 snapshot，长会话首屏流量偏大；后续可把 (logEpoch, seq) 入缓存做续传。
- 流式期间整表重绘（rows 数组全量替换），长会话滚动位置可能跳动；后续按 rowId 增量更新 + 锚定滚动。
- OUT-3/4 批准卡片（pendingApproval 工具行、pendingInteractions 面板）是下一批自然候选；投影层已保留计数与状态位。
- 子代理行已带 childSessionId，下钻订阅 conversation/<child> 的 UI 未做。
