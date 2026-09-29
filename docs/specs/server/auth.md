# Spec：Server 访问鉴权（E1 / PRD SRV-2）

| 项 | 内容 |
| --- | --- |
| 状态 | 已评审（随 Batch 1 实现） |
| 对应计划 | `docs/PLAN-ZCode-Harmony.md` §4-E1 |
| 模块 | `server.auth`（新增 managed 模块）+ `packages/server/src/http.ts` 中间件接线 + `@zcode/server-cli` server-core |
| 事实源 | 本 spec + `architecture-policy.yaml` |

## 1. 行为

ZCode HTTP Server（`packages/server` entry-http 形态）对 `/api/*`、`/ws`、`/ws/*` 提供全局 token 鉴权：

1. **凭证通道（三路，优先级从高到低）**：
   - `Authorization: Bearer <token>` 请求头（本 spec 新增，鸿蒙 App 的一等通道）；
   - `?token=<token>` 查询参数（既有通道，命中后种 `zcode_lite_token` HttpOnly cookie，Web SPA 兼容）；
   - `zcode_lite_token` cookie（既有通道）。
2. **凭证比对对象（两级）**：
   - **管理员 token**：`options.authToken`，或 env `ZCODE_SERVER_AUTH_TOKEN`（`options` 未显式提供时的回退），或已弃用 env `ZCODE_SERVER_TOKEN`（最后回退，进程内警告一次）；命中即放行，拥有全部接口权限（含配对管理、host capability 签发）。
   - **设备 token**：`server.auth` 模块管理的多设备 token 表中处于活跃状态（未吊销）的记录；命中即放行普通业务面（权限与管理面在 E2 配对 spec 中进一步收窄）。
3. **`server-info` 如实反映**：`authRequired` = 显式 `options.authRequired` ?? 「存在有效管理员 token 或存在设备 token 表」；`capabilities.authSchemes` = 启用鉴权时 `["bearer", "cookie", "query"]`（additive 可选字段，旧客户端不受影响）。
4. **server-core（`@zcode/server-cli`）**：新增 `authToken` 选项；提供时对同样的受保护路径启用**仅管理员 token**的同语义中间件（Bearer/query/cookie 三路），`authRequired` 随之置真；未提供时维持现状——非 loopback 监听 fail-closed、loopback 放行。

### 已修复的缺陷（回归锚点）

- 修复前：`createServerInfo` 读 `ZCODE_SERVER_TOKEN` 判定 `authRequired`，而中间件实际启用依据是 `entry-http.ts` 传入的 `ZCODE_SERVER_AUTH_TOKEN`。两个变量名不一致导致"实际有鉴权但 server-info 谎报未开启"。修复后单一解析函数同时供中间件与 `server-info` 使用（唯一事实源）。

## 2. 状态所有者

```text
输入（HTTP 请求凭证） → 唯一所有者：createHttpServer 内的鉴权中间件
                        ├─ 管理员 token：进程内字符串（env/options 解析一次）
                        └─ 设备 token：server.auth 的 DeviceTokenRegistry（模块内内存缓存 + 文件持久化）
                      → 状态迁移：registry.issue/revoke（写路径唯一，经文件 store 原子落盘）
                      → 合同/事件：无广播；verify 为即席查询
```

- **DeviceTokenRegistry 是设备 token 状态的唯一所有者**；中间件只调用 `verify`，不缓存结果，不保存第二份 token 表。
- 管理员 token 与设备 token 并存且互不派生；管理员 token 不进设备表。
- server-core 不接设备 token 表（SSH 隧道形态的访问者是人不是多设备），仅管理员 token——这是刻意边界，不是缺失；两形态共用"三路提取 + 比对"语义但不共享代码（server-cli 不依赖 @zcode/server，避免把部署工具链依赖拖进无头发行包）。

## 3. 不变量

1. **Fail-closed**：设备 token 表读取/写入 IO 失败时，`verify` 返回 false（拒绝）并 `error` 日志；绝不因存储异常放行。
2. **明文 token 不落盘、不入日志**：持久化只存 SHA-256 hex；日志只出现 token id 与设备名；异常信息不携带凭证。
3. **明文 token 只在签发响应中出现一次**，之后不可从任何接口取回。
4. **吊销立即生效**：`revoke` 落盘成功后，后续 `verify` 必须拒绝；不保证已建立的 WS 立即断开（M2 设备管理页提供"吊销并断开"增强）。
5. **同 hash 唯一**：签发时若与现有活跃记录 hash 相同则复用该记录（不重复发同值 token 的场景天然不存在，因 token 含随机数）。
6. 鉴权中间件先于全部路由注册（含 WS upgrade）；`/ws/host` 的一次性 capability 校验保持叠加不变。
7. 设备名经 trim + 长度上限（≤64 字符）与控制字符过滤；记录数上限 64，超出时签发失败并给出可读错误。

## 4. 失败语义

| 场景 | 行为 |
| --- | --- |
| 无凭证访问受保护路径 | 401 JSON `{ error: "Unauthorized" }` |
| 凭证不匹配（管理/设备均未命中） | 401，同上，无额外提示（不泄露存在性） |
| 设备表文件损坏（坏 JSON） | 启动后首次加载时 `warn` 日志并按空表处理；下一次 `issue/revoke` 以空表为基线覆写（与 `settingService` 容错一致，见 §3.1 迁移边界） |
| 设备表写入失败 | `issue/revoke` 拒绝（抛错给调用方），`verify` 继续按内存态工作但保持 fail-closed 原则不变（内存态只增不减时吊销不可信 → 写失败时 revoke 返回 false） |
| `Authorization` 头非 Bearer 方案 | 忽略该头，落到 query/cookie 通道 |

## 5. 事件顺序（verify 路径）

```text
请求 → 提取凭证（Bearer → query → cookie，取第一个非空）
     → 管理员比对（字符串常量时间比较）
     → 未命中且 registry 存在 → registry.verify(token)
         → 内存缓存查找 hash（缓存未命中时先同步加载文件一次）
         → 命中活跃记录 → 更新 lastUsedAt（异步、尽力而为、不阻塞应答）
     → 放行 / 401
```

- `lastUsedAt` 更新失败只 `debug` 日志，不影响鉴权结果。
- 查询通道命中时保留既有 Set-Cookie 行为（Bearer 命中不种 cookie）。

## 6. 迁移边界

1. `ZCODE_SERVER_TOKEN` → `ZCODE_SERVER_AUTH_TOKEN`：旧变量继续生效但进程内警告一次（首次解析时）；不设删除时间表，Q4 决策时一并处理。
2. `?token=` 通道保留（Web SPA 依赖其种 cookie）；鸿蒙 App 一律使用 Bearer。
3. 设备表文件路径：`join(getAppConfigDir(), "access-tokens.json")`，由调用方（entry-http）解析传入，模块不依赖 services 的路径工具。entry-http **仅在已配置管理员 token 时**接线设备注册表——设备 token 扩展一个已鉴权的 server，绝不把默认开放的本机 dev server 变成"谁都无法访问"。
4. `server-info.capabilities.authSchemes` 为 additive 可选字段：旧客户端（zod 非 strict 对象）解析时忽略新键；新客户端对旧 server（字段缺失）必须按"仅 query/cookie"兜底。
5. server-core（`@zcode/server-cli`）通过 fork 继承的 env 获取管理员 token；其鉴权是"仅管理员 token"子集，刻意不跨包复用 `@zcode/server/auth`（避免把部署工具链依赖拖进无头发行包）。

## 7. 验收场景

| # | 场景 | 期望 |
| --- | --- | --- |
| A1 | 无 token 请求 `/api/server-info`（配置了管理员 token） | 401 |
| A2 | `Authorization: Bearer <管理员token>` 请求 `/api/server-info` | 200，`authRequired=true`，`authSchemes` 含 `bearer` |
| A3 | `?token=<管理员token>` 请求 | 200 且响应 Set-Cookie |
| A4 | 带 `zcode_lite_token` cookie 请求 | 200 |
| A5 | 仅配置 `ZCODE_SERVER_AUTH_TOKEN`（复现原 bug 场景） | `authRequired=true`（修复回归） |
| A6 | 仅配置旧 `ZCODE_SERVER_TOKEN` | 鉴权生效 + `authRequired=true` + 警告日志一次 |
| A7 | registry.issue 后用新设备 token Bearer 访问 | 200 |
| A8 | revoke 后同一 token 访问 | 401 |
| A9 | 设备表文件写入非法 JSON 后 verify 合法管理 token | 200（表损坏不影响管理员通道） |
| A10 | token 文件落盘 | 内容只含 `tokenHash`，无明文（结构断言） |
| A11 | server-core：提供 authToken 时无凭证 → 401，Bearer → 200 |
| A12 | server-core：无 authToken 且非 loopback host | 启动抛错（保持 fail-closed） |
