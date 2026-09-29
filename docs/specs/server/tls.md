# Spec：Server 自签 TLS 与证书固定（E3 / PRD SRV-3）

| 项 | 内容 |
| --- | --- |
| 状态 | 已评审（随 Batch 3 实现） |
| 对应计划 | `docs/PLAN-ZCode-Harmony.md` §4-E3 |
| 模块 | `server.tls`（新增 managed 模块）+ `packages/server/src/http.ts` 接线 |
| 事实源 | 本 spec + `architecture-policy.yaml` |

## 1. 行为

ZCode Server 支持局域网 HTTPS/WSS，并把证书指纹下发给鸿蒙 App 做证书固定（防局域网 MITM）。

### TLS 材料供给（三种方式，按优先级）

| 方式 | 触发 | 行为 |
| --- | --- | --- |
| 用户提供 PEM | env `ZCODE_SERVER_TLS_CERT` + `ZCODE_SERVER_TLS_KEY`（文件路径） | 加载并计算指纹；解析失败 → **启动失败**（fail-fast，错误含文件路径） |
| 自签 | env `ZCODE_SERVER_TLS_SELF_SIGNED=1` | `<appConfigDir>/tls/server-cert.pem`、`server-key.pem` 不存在则生成（node-forge，RSA 2048，CN=hostname，SAN=hostname + 全部非内部 IPv4，有效期 10 年）；已存在则直接加载（幂等） |
| 未配置 | — | 维持纯 HTTP（现状不变） |

- 自签私钥文件权限尽力 0600（POSIX）；明文密钥路径与内容不入日志。
- 绑定非 loopback + 已配 token + **未配 TLS** 时启动 `warn` 一条明文传输风险提示（不强拦，兼容既有部署）。

### HTTPS 接入

- 有 TLS 材料时：`https.createServer({ cert, key }, getRequestListener(app.fetch))` + `injectWebSocket(server)`（WSS 同源升级不受影响）；否则走既有 `serve()`。
- `server-info.capabilities.certFingerprint`（additive 可选）：证书 **SPKI SHA-256 hex**，仅 TLS 启用时下发；`POST /api/pairing/code`、`POST /api/pairing/claim` 响应携带同一 `certFingerprint`（App 端 QR 的 `fp` 与其一致，实现证书固定）。

### 文档（SRV-3 托管方案）

`docs/harmony-networking.md`（新增）：Tailscale 组网（推荐默认）、反向代理（Caddy/Nginx）两种方案 + "不要端口映射裸奔"告诫；自签模式的使用步骤。

## 2. 状态所有者

```text
TLS 材料解析（env → PEM → 指纹） → server.tls 模块（纯解析，无长期状态）
证书文件（自签）→ 文件系统 <appConfigDir>/tls/（生成一次，进程只读加载）
http.ts 持有解析结果并负责 server 创建；模块不持有 server 实例。
```

## 3. 不变量

1. **指纹口径唯一**：`certFingerprint` ≡ SHA-256(SPKI DER)，hex 小写；server-info、配对响应、自签生成三处同源。
2. **fail-fast**：显式配置的 TLS（PEM 路径或自签）解析/生成失败必须阻止启动，绝不静默降级为 HTTP。
3. **自签幂等**：已存在的证书文件直接复用（不轮换；轮换属 M2 设备管理范围）。
4. 私钥不入日志；错误信息只含路径与原因。
5. `capabilities.certFingerprint` 为 additive 可选字段：老客户端忽略；新客户端对缺失字段按"无证书固定"处理。

## 4. 验收场景

| # | 场景 | 期望 |
| --- | --- | --- |
| T1 | 自签材料生成 | cert/key PEM 可解析；用 node `X509Certificate` 独立计算的 SPKI SHA-256 与模块输出一致 |
| T2 | TLS 起 server → `https://…/api/server-info`（信任自签） | 200 且 `capabilities.certFingerprint` 等于 T1 独立指纹 |
| T3 | 配对 claim 响应携带同一 `certFingerprint` | 与 T2 一致 |
| T4 | PEM 路径指向坏文件 → 启动抛错（fail-fast） |
| T5 | 未配 TLS → 行为与 Batch 2 完全一致（回归） |
