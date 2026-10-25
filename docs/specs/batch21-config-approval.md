# 批次21 Spec：审批卡片桌面级内容 + 会话配置切换 + 用量面板

范围：OUT-3/4 批准卡片对齐桌面 PermissionDialog 的内容要素（blockKind 分流/命令文本/文件
变更/选项排序与中文映射）；workspace-config topic 订阅与会话级模式/模型/思考档位切换
（switchCollaborationMode / switchModelConfig，CAS）；usage-stats 通道的套餐余额面板；
输入舱 emoji 图标全面替换为 HSD SymbolGlyph（ZIcon）。设计基座三件（DesignTokens /
Motion / ZIcon）本批落地并接入 uikit 公开面。

## 数据面（协议层）

- `approvalPreview.ts`：桌面 `permission-request-preview.ts` 的 App 侧移植。派生入口
  `deriveApprovalContent(toolName, summary, detail, display)` → blockKind
  （execute/edit/mcp/skill/search/workflow/fallback）+ displayReason（过滤两条通用策略
  文案）+ command（command/cmd/script 深搜 + args 数组拼回命令行）+ filePaths（
  FILE_PATH_KEYS 收集 ≤6，忽略 cwd/directory）+ fileChanges（changes 映射 add/update
  ≤16）+ mcp 标识（display 优先，mcp__server__tool 拆分）+ search url/query。
  选项面：`approvalOptionPriority`（allowOnce 0 → allowAlways 1 → fullAccess 1.5 →
  deny 2 → custom 4）、`approvalOptionLabel`（中文映射，未知回退服务端 label）、
  `approvalOptionDescription`、`approvalOptionScopes`（response.permissionUpdates
  .addRules(allow) 中 bash `prefix:*` 规则去后缀 ≤160 字符）。
- `usageEntitlement.ts`：channels RPC `usage-stats.getEntitlementSnapshot` 原始返回的
  防御性投影（UsageEntitlementView）。口径：quota.limits[].percentage 是**已使用占比**。
- `WorkbenchModel.ts`：
  - `PendingInteractionView` 增量：approval（permission 专用派生内容）、originKind/
    originAgentType（**从 payload.origin 投影**——上游 zcodeInteractionRequestOriginSchema
    在 payload 上，不在 interaction 根上）、anchorRowId、autoState/autoDeadlineAt、
    questionIndex/questionCount/questionHeader/multiSelect（AskUserQuestion 多问题进度）。
  - 选项视图增 scopes（permission 的 bash 前缀）/ description（userInput 题面说明）；
    fullAccessOption 作为独立 additive 面并入 options 后按桌面优先级稳定排序。
  - `ConversationModel.sessionConfig()`：snapshot.config → SessionConfigView（provider/
    model/thought/thoughtLevels/mode/planEnabled/followupMode；旧快照缺省 mode=build）。
  - `WorkspaceConfigModel`：workspace-config topic 归约器。**快照形状：
    `{protocolVersion, workspaceId, logEpoch, config:{configOptions, slashCommands}}`——
    configOptions 嵌套在 config 下**（首版直接读快照根导致永远空目录，门禁回归向量逼出）。

## 引擎/控制器面

- ConnectionEngine：`subscribeWorkspaceConfig()`（幂等；重连重订；topic 键
  `workspace-config:*` 由帧流按前缀归位）；CommandType +2（switchCollaborationMode /
  switchModelConfig）；usage-stats 直连 RPC `getEntitlementSnapshot`（不走命令队列）。
- WorkbenchController：`onConfigChanged` 事件 + `getConfigOptions()`；`ConversationUpdate`
  增 `config: SessionConfigView | null`；`switchCollaborationMode` / `switchModelConfig`
  **必须携带快照 CAS 水位**（baseRevision + baseLogEpoch——两命令在
  COMMANDS_REQUIRING_BASE_REVISION 词表内，缺 baseRevision 服务端/信封校验直接拒）；
  `getUsageEntitlement()`。workspace-config 订阅失败降级：配置面板只读当前值。

## UI 面（SessionDetail）

- ApprovalCard：blockKind 中文徽标（执行命令/文件修改/MCP 工具/技能/网络搜索/工作流）；
  子代理来源徽标（originKind=subagent）；displayReason 次行；execute 命令等宽块（横向
  滚动）；edit 文件变更行（新增/更新徽标 + 路径）；无 changes 时文件路径 chips；mcp
  `server · tool` 头部；search url/query 行；AskUserQuestion「第 X/Y 题 · header · 可多选」
  进度行；选项按钮 = 中文 label + 描述行；allowAlways 选项下方列 bash 前缀 scope。
- 配置面板（输入舱当前模式 chip 展开；内联面板，与 AtPanel 同模式）：
  - 模式四档 chips（Agent/问答/编辑/自动 → build/plan/edit/yolo），当前值来自
    sessionConfig.mode，点击发 switchCollaborationMode。
  - 模型列表（workspace-config 目录 id=model 候选，名称+供应商分组；当前项高亮），
    点击发 switchModelConfig(provider, model, defaultThoughtLevel)。目录未就绪时降级
    只读当前值行。
  - 思考档位 chips（当前模型候选；目录回退快照 thoughtLevels）。
- 用量面板（输入舱卡片图标展开；打开即拉取）：剩余次数/剩余百分比（≤20% 警示色）/
  重置时间；额度桶进度条（已用占比 ≥80% 警示）；订阅身份掩码与上下文名；未登录时
  unavailableReason 中文映射。
- 输入舱：拍照/相册/文档 emoji → ZIcon（sys.symbol）；模式行重做——发送不再带按次
  mode（sendText payload 无 mode = 跟随服务端会话模式；「问答」本地概念由会话级
  plan 模式承接，Q3 产品复核口径不变）。

## 门禁（tools/protocol-consistency，32/32）

新增 `batch21-config-usage.test.mjs` 9 组：
1. 审批派生 execute/通用文案过滤/文件路径收集；
2. edit changes / mcp 拆分与 display 优先 / search 摘要；
3. 选项优先级（含 fullAccess 1.5 插序）/ label / 描述 / bash 前缀 scope；
4. pendingInteractions permission 投影（origin 从 payload、fullAccess 排序、autoResolution、
   scopes、派生内容）；
5. AskUserQuestion 多问题进度（optionId 回退 value、description 透出）；
6. workspace-config 快照嵌套回归 + delta 整体替换 + wire 帧过 topic schema；
7. 会话配置投影（全量/旧形状缺省）；
8. 用量投影全量/团队标注/未登录/空载荷；
9. switch 信封：词表内过、**缺 baseRevision 拒**、auto/ask 拒、thought 三元组必填。

配套：workbench-model.test.mjs 选项 deepEqual 断言更新（+scopes/description 字段）；
`@ohos.util` node 侧 stub（stubs/ohos-util.ts + tsconfig paths——批次20 Buffer.ts 引入
后 rpc/session 一致性测试在 node 下无法加载的存量回归）。

## 本批修复的缺陷（数据面先行批次遗留）

1. WorkspaceConfigModel 快照分支读 `body.configOptions`（实际嵌套在 `body.config` 下）
   → 目录永远为空；
2. pendingFrom 从 interaction 根读 origin（上游在 payload 上）→ 子代理徽标永不显示；
3. usageEntitlement `isObj` 不防 undefined → 缺键载荷（如无 provider 的返回）直接抛
   TypeError；
4. switch 两命令未带 CAS 水位（信封校验必拒，运行时才会暴露）；
5. （存量）rpc/session 一致性测试自批次20 起在 node 下无法加载（@ohos.util）。

## 真机批遗留

- 审批卡片内容派生与桌面 PermissionDialog 的逐向量一致性（对拍 fixtures 来自源码移植，
  真实 CLI 工具入参形状需联调抽查）；
- workspace-config 目录在真实 server 的 configOptions id 集（model/mode/thought_level
  是否齐备）与 switch 命令 ACK 语义；
- usage-stats 通道在 standalone server /ws 上的可用性与未登录返回形状；
- 配置切换的 UX（面板高度/模型列表滚动）与用量面板刷新节奏。
