# Spec：移动端配对服务（E2 / PRD SRV-1）

| 项 | 内容 |
| --- | --- |
| 状态 | 已评审（Batch 2 实现，含下述细化决策） |
| 对应计划 | `docs/PLAN-ZCode-Harmony.md` §4-E2；依赖 E1（`docs/specs/harmony/auth.md`）的设备 token 表 |
| 模块 | `server.pairing`（Batch 2 注册 managed 模块） |

## 1. 行为

桌面（Web UI 形态）出配对二维码 → 鸿蒙 App 扫码 → 一次性 pairCode 换取设备 accessToken，完成绑定。

### REST 契约（Batch 2 实现）

| 端点 | 鉴权 | 请求 | 响应 |
| --- | --- | --- | --- |
| `POST /api/pairing/code` | 管理员 token | `{}` | `{ pairCode, pairCodeId, expiresAt, certFingerprint? }` |
| `POST /api/pairing/claim` | pairCode（body 携带，公开路径） | `{ pairCode, deviceName, pushToken? }` | `{ accessToken, serverId, serverName?, certFingerprint? }` |
| `GET /api/pairing/cert` | 公开（本批增补） | — | `{ certPem }`（TLS 启用时；未启用 404 `{ error: "TLS not enabled" }`） |
| `GET /api/pairing/devices` | 管理员 token | — | `{ devices: DeviceTokenRecord[] }`（复用 auth 模块记录） |
| `DELETE /api/pairing/devices/:id` | 管理员 token | — | `{ ok: true }`（吊销，透传 auth 模块；id 不存在返回 404） |

- **二维码 URL 由桌面 UI 拼装**（Batch 2 细化决策）：server 返回 `pairCode` 明文与 `expiresAt`，Web 设置页用自身 `location.hostname`/`port` 组装 `zcode://pair?host=…&port=…&token=<pairCode>&name=<serverName>&fp=<certFingerprint?>`——server 侧 `options.host` 可能是 `0.0.0.0`/undefined，无法替手机选出正确局域网地址；用户打开 Web 用的主机名才是手机可达地址。`fp` 为自签证书 SPKI SHA-256 hex（E3 提供时携带）；各值 `encodeURIComponent`。
- **证书带外分发（Batch 5 增补，鸿蒙 A3 信任链）**：`GET /api/pairing/cert` 公开端点返回自签证书 PEM（浏览器已与 server 同源，取证书不需要额外信任）；桌面出码时把它转成 `cert=<base64 DER>` 追加进深链——手机端以「SHA-256(证书 SPKI) === fp」本地校验后，将该证书作为后续 HTTPS/WSS 的 `caPath` 固定（信任锚来自桌面屏幕这一带外信道，局域网 MITM 无法伪造匹配 fp 的证书）。纯 HTTP 部署（无 TLS）该端点 404，深链不含 `cert` 参数。设计细节见鸿蒙仓 `docs/specs/a3-pairing.md` §1.1。
- **鉴权分级落在 tokenGuard**（单一守卫路径）：`adminOnlyPaths`（`/api/pairing/code`、`/api/pairing/devices`）——设备 token 命中返回 **403**，无凭证/凭证无效返回 401；`publicPaths`（`/api/pairing/claim`）——免管理员鉴权，由一次性 pairCode 自身保护。
- `pairCode`：CSPRNG 随机（`zpc_` + 32 hex）、TTL 5 分钟、**一次性**；同一时刻未消费 pairCode 至多 1 个（新签发作废旧的）。
- `claim` 成功即调用 auth 模块 `issue({ deviceName })` 签发设备 accessToken；`pushToken` 可选、≤256 字符、仅存内存（E5 消费，不落盘不入日志）。

## 2. 状态所有者

```text
pairCode 生命周期 → 唯一所有者：PairingService（server.pairing 模块，进程内存，单活跃码）
设备 accessToken  → 唯一所有者：server.auth 的 DeviceTokenRegistry（E1 已建）
claim 频控计数    → server.pairing 的固定窗口计数器（进程内存，IP → {count, windowStartMs}）
所有者边界：pairing 只调用 auth 的 issue/list/revoke，不复制 token 表、不缓存 accessToken。
```

事件顺序（claim，原子性关键）：

```text
频控检查 → 同步段（单线程内原子，杜绝并发重放窗口）：
  hash(明文 pairCode) → 与活跃码 codeHash 常量时间比对 → 校验未过期 → 立即消费（活跃码清空）
→ 异步段：auth.issue({ deviceName }) → 返回 accessToken
（签发失败不回滚 pairCode——用户重新出码，避免半配对状态，spec §4）
```

## 3. 不变量

1. pairCode 明文只出现在出码响应（二维码内容）与 claim 请求中；服务端只存 hash（复用 auth 的 sha256TokenHasher）。
2. 过期、已消费、不存在的 pairCode 统一返回 401 `{ error: "Invalid pairing code" }`（不区分原因，防枚举）。
3. 并发 claim 同一 pairCode：仅一个成功——消费在同步段完成（Node 单线程内无 await 间隙），后到者见活跃码已清空。
4. `deviceName` 复用 auth 的 `normalizeDeviceName`（trim、剔控制字符、≤64 字符）；空则 400。`pushToken` trim 后 ≤256 字符，超长 400。
5. claim 频控：同源（IP）固定窗口 60 秒内 ≤10 次，超出 429（含 `Retry-After`）；计数含失败尝试；计数表惰性重置、上限 10000 个 IP（超出整体清空，防无界增长）。
6. 配对管理端点仅管理员 token 可用（guard 的 `adminOnlyPaths`，设备 token → 403）。

## 4. 失败语义

| 场景 | 行为 |
| --- | --- |
| 无凭证/坏凭证访问管理端点 | 401（guard 既有语义） |
| 设备 token 访问管理端点 | 403（合法设备、权限不足） |
| body 非法（缺 deviceName、超长 pushToken、坏 JSON） | 400 `{ error: "Invalid request body: …" }` |
| pairCode 无效/过期/已消费 | 401 `{ error: "Invalid pairing code" }` |
| 频控超限 | 429 `{ error: "Too many pairing attempts" }` + `Retry-After` |
| auth.issue 设备数达上限 | 409 `{ error: "Device limit reached" }`（auth 抛 `DeviceTokenLimitError`） |
| auth.issue 其他落盘失败 | 500 `{ error: "Failed to issue device token" }`，pairCode 已作废 |

## 5. 桌面 UI（packages/ui）

- `settings/MobilePairingSection.tsx` 新分区，按 `settingsNavigation.ts` → `SettingsPage.tsx` → 分区组件三步注册；
- 分区内：出码按钮（调 `POST /api/pairing/code`，需管理员 token——Web 形态下经既有 token cookie 天然具备）、二维码渲染（前端纯 JS 库）、倒计时与过期态、已配对设备列表（`GET /api/pairing/devices`，M2 完善吊销入口）；
- Web 端通过 `fetch` 直访 REST（与 `server-info` 同模式），不新增 RPC channel。

## 6. 迁移边界

- Electron 桌面设置页集成依赖 Q1 决策（Electron 形态不走 HTTP），本期范围外；`zcode://pair` 深链的桌面注册（`desktopDeepLinkUrl.ts` 增 host）随 Q1。
- `pushToken` 字段为 additive；E5 实现前 server 只透传存储于内存（不落盘）。

## 7. 验收场景（Batch 2 实现时落测试）

| # | 场景 | 期望 |
| --- | --- | --- |
| P1 | 管理员出码 → claim → 用 accessToken Bearer 访问 `/api/server-info` | 200 |
| P2 | 同一 pairCode 二次 claim | 401 |
| P3 | TTL 过期后 claim | 401 |
| P4 | 并发 10 个 claim 同码 | 恰 1 个 200 |
| P5 | 设备 token 调 `POST /api/pairing/code` | 403 |
| P6 | S1 场景全链路（App 端联调） | 扫码 3 秒内绑定并进入会话列表 |
