# Spec：WSS 之上的 RPC 会话层与重连引擎（Batch 6 / PRD CONN-3、计划 §1.4、§5-L1~L5）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 6） |
| 对应计划 | `PLAN-ZCode-Harmony.md` §4-A4（重连引擎）、§5（协议移植 L1 收尾/L2/L3/L4/L5） |
| 模块 | `commons/protocol`（PersistentProtocol / Channels / ChannelClient / v4 子集 / AgentV4Client / PendingCommandQueue）+ `commons/connection`（WebSocketTransport / ConnectionEngine / PullSessions） |
| 服务端契约 | zcode 仓 `packages/server/src/http.ts`（/ws 上 ChannelServer + IZCodeAgentService connection scope，web-remote-replayable 为 terminal-client）；v4 线协议以原包 schema 为事实源 |
| 范围外 | A5 工作台 UI（会话列表页、渲染管线、SQLite 缓存）、OUT-3/4 批准卡片、ONB-2 相机扫码、AssetKit 不可用环境的进一步降级 |

## 1. 行为

配对完成后，App 与桌面 server 建立 WSS 长连接并订阅 v4 会话数据：连接（证书固定 + Bearer）→ v4 握手（hello 版本 fail-fast → clientHello `mobileApp`）→ 订阅 sessions-index / conversation → 下行 wire 帧装配（complete/fragment，crc32 校验，ordinal 去重）→ 水位记账。断线后按指数退避自动重连，网络恢复事件可抢先退避定时器立即重试；重连成功后带水位重订阅（服务端回 snapshot 或 resume 增量），期间积压的命令按幂等 commandId 依次 flush。

## 2. 分层与所有者

```text
commons/protocol（纯逻辑，node/设备双端可运行；一致性门禁覆盖）
  rpc/PersistentProtocol   L1 收尾：ACK 确认、5s 心跳、20s ACK 超时、重放缓冲（8MiB/45s）上限、拥塞水位信号
  rpc/Channels+ChannelClient L2：请求/响应/事件复用同一 request id 空间；连接终结时挂起 Promise fail-closed
  v4/*                     L4：zcode-protocol-v4 子集（43 文件，见 §3）+ wire 装配器 + apply/coalesce + 命令信封
  v4/AgentV4Stub           L3：显式服务桩（ES6 Proxy 不可用 → 方法名+参数数组；onDynamic* 动态事件 listen(事件名, 参数)）
  v4/AgentV4Client         会话编排：握手（helloMessageSchema 版本锁）→ 订阅 → TopicWireFrameAssembler 装配 → 帧分发与水位 → resync → sendCommand（信封 schema 校验）
  v4/PendingCommandQueue   断线命令队列：同 commandId 幂等入队、TTL 24h、上限 32 条
commons/connection（ArkTS 适配层）
  ws/WebSocketTransport    L5：@ohos.net.webSocket → ISocket；二进制帧→VSBuffer；wss 走 caPath 证书固定；升级请求带 Authorization: Bearer
  session/ConnectionEngine A4 状态机（§1.4 状态机落地，见 §4）
  session/PullSessions     ONB-5 第③步真实化：一次性连接拉取 sessions-index snapshot
所有者边界：档案与 token 的写入路径仍是 ProfileStore/AssetTokenStore（批次5）；ConnectionEngine 是连接状态的唯一所有者（每档案一份，M1 单活）；命令的 commandId 由 Engine 生成，队列是唯一积压场所。
```

## 3. L4 移植范围与 zod 类型边界

- 闭包取自 `zcode-protocol-v4`：core / transport（帧信封、hello、subscribe/ack） / sessions-index / snapshot / rows / delta / command（信封、ACK、resolveInteraction、sendText/stop）/ wire*（physical frame、crc32 base64、codec、reassembly、assembler）/ apply / coalesce / workflow-runs 及其类型依赖，共 43 文件。移植由 `tools/port-v4-deps.cjs`（闭包拷贝+导入改写）与 `tools/prune-v4.cjs`（可达性剪枝）辅助完成，产物入库。
- **zod 类型边界（本批关键决策）**：spike 阶段 2 动态验证发现 ArkTS 编译器无法消费 zod@4 的 d.ts——复杂泛型在调用点坍缩为 any 并级联报错（首轮构建 452 错误中的绝大部分）。处置：`v4/zod-ambient.ts` 把 z 的**类型域**收敛为 any（运行时仍加载真实 zod，node 与设备同包同行为），v4 源文件统一 `import { z } from "./zod-ambient"`；类型位（z.infer/z.ZodType/z.ZodError 等）改写为 any/unknown。`.ets` 消费端不依赖 zod 推导类型，使用手写本地接口（如 `ConnectionEngine` 的信封形状、`PullSessions` 的帧形状）。协议行为正确性由 §6 一致性门禁兜底（黄金测试对 zod 类型无依赖）。
- 设备侧依赖：`commons/protocol/oh-package.json5` 以 `file:./libs/zod-4.6.5.tgz` 引入（ohpm 官方源无 npm 包且该版本 ohpm 无 npm_registry 回退配置；tarball 自 zcode 仓锁定的 zod@4.6.5 打包）。

## 4. ConnectionEngine（A4 / §1.4 状态机）

```text
[offline] ──start()──▶ [connecting] ──WSS 握手 + hello 成功 + 重订阅──▶ [online]
    ▲                        │ 失败
    └──── stop() 用户手动 ── [backoff] 1s→2s→4s→8s→15s→30s（指数退避）◀──┘
                               │ @ohos.net.connection netAvailable 抢先取消定时器 → 立即重试
```

- **断线恢复语义**：重连 = 新建传输 + 新 AgentV4Client，随后**带水位重订阅**（`subscribe(base={logEpoch, seq})`）：服务端按 (connectionId, topic) 替换旧订阅并按水位回 snapshot 或 resume 增量——与 same-sub resync 同语义且服务端契约已定义；`AgentV4Client.resync` 保留给同连接内的静默恢复（A5 用）。
- **水位记账**：ACK 的 logEpoch + 帧的 toSeq（单调取 max）；epoch 为空的订阅不得声明水位（重订阅回退全量 snapshot）。
- **命令可靠性**：非 online 状态一律入队（`PendingCommandQueue`）；online 后按序 flush；发送失败（断线竞态）回队重发，服务端按 commandId 幂等去重（duplicate ACK 视为送达）。TTL 24h 对齐 `PROTOCOL_V4_LIMITS.commandPendingTtlMs`。
- **链路形态**：`WebSocketTransport → SocketProtocol → ChannelClient`，与 web 客户端同构（/ws 服务端是 ChannelServer）。PersistentProtocol 已移植并通过互操作一致性测试，但**不在本链路**（服务端 /ws 不消费其 ACK/心跳帧）；字节级可靠性由 WS + v4 水位重订阅承担。
- **资源回收**：断开/重建路径上 dispose 顺序 = 客户端事件上游 → ChannelClient → 传输；网络侦听在 stop 时注销。

## 5. 不变量

1. hello 协议版本锁：`protocolVersion !== V4_WIRE_PROTOCOL_VERSION(3)` 时 connect fail-fast（不重试）。
2. 客户端身份：clientKind=`mobileApp`；clientId 为设备级持久 UUID（由调用方生成传入；自检的一次性拉取允许用一次性 UUID）。
3. 架构铁律：手机不新起 Agent——sessions-index 订阅带 `runtimePolicy: "existing-only"`；conversation 订阅才允许 `start-if-needed`。
4. workspace 身份统一 `workspaceIdentity?.trim() || workspacePath`（订阅 topic 与之对偶）。
5. token 只进内存与 Asset Store，不入日志/沙箱明文；WSS 升级请求通过 Authorization 头携带（E1 Bearer 通道）。
6. 命令信封 commandId 客户端生成、重试不变；sessionId 为 null 仅限全局命令。
7. 帧装配 fail-close：checksum/UTF-8/JSON/schema 任一失败产出 typed fault（`proto.frameAssembly*`），不静默丢弃整条订阅流；迟到旧 ordinal 静默淘汰。

## 6. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| S-1 | 一致性：通道层环回（移植 ChannelClient ↔ 原包 ChannelServer + ProxyChannel） | call/listen/fail-closed 语义一致 | ✅ |
| S-2 | 一致性：持久层互操作（移植 PersistentProtocol ↔ 原包） | 收帧/未确认字节记账/replaceSocket 重放 | ✅ |
| S-3 | 黄金测试：`applyAll(s, coalesce(ds))` ≡ 逐条 apply，双实现互证 | 逐字节一致 | ✅ |
| S-4 | 一致性：同一组分片喂双实现 TopicWireFrameAssembler | 逻辑帧一致 + ordinal 去重 + typed fault | ✅ |
| S-5 | 端到端：移植 AgentV4Client ↔ 原包 ChannelServer 假 host | 握手版本锁→订阅→帧装配→水位→resync→幂等命令全链 | ✅ |
| S-6 | hvigor 构建（含 ohpm zod 打包） | assembleHap 成功 | ✅ BUILD SUCCESSFUL |
| S-7 | 设备联调：预览器/真机 | 真机网络路径（WSS 证书固定 + 自检三步全绿 + 断网重连恢复） | ⏳ 待真机（预览器无网络；本批仅改自检页逻辑、无新页面） |

运行方式：`cd tools/protocol-consistency && npm test`（13/13；原包路径 `ZCODE_RPC_SRC`/`ZCODE_SHARED_SRC` 可覆盖；F: 盘残缺安装需把 `@zcode/model-option-map` vendor 到测试 node_modules——见 tsconfig paths）。

## 7. 风险与后续

- zod 类型边界使本 HAR 内静态类型退化（运行时行为不受影响）；若后续 ArkTS 工具链支持 zod4 d.ts，可在迁移脚本反向上恢复强类型。
- `@zcode/model-option-map` 的 vendor 副本仅用于 node 测试侧解析（原包 F: 盘为残缺安装）；仓库安装完整后可用 tsconfig paths 指回。
- 设备联调项（真机）：证书固定 WSS 握手、断网重连恢复 ≤2s（PRD 6.3 P0）、命令 flush 幂等实测。
