# Spec：配对向导与最小连接层（A3 / PRD ONB-1/4/5、CONN-5）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 5） |
| 对应计划 | `PLAN-ZCode-Harmony.md` §4-A3（服务端依赖 E1/E2/E3 已就绪） |
| 模块 | `commons/connection`（新 HAR）+ `entry` 配对页面与深链路由 |
| 服务端契约 | zcode 仓 `docs/specs/harmony/pairing.md`（本批增补 `GET /api/pairing/cert`） |
| 范围外 | ONB-2 相机扫码 UI（Scan Kit 需真机，深链入口先行）、A4 重连引擎、WSS 之上的 RPC 会话（L3/L4，下一批） |

## 1. 行为

手机与桌面建立信任并完成首次连接：桌面出码 → 手机获取 `zcode://pair` 链接（扫码/粘贴/深链）→ 解析 → **证书带外校验** → claim 换取设备 token → 三步连接自检 → 档案落盘。

### 1.1 信任链（本批核心决策：证书带外分发）

自签 TLS 下首次接触存在"信任锚从哪来"的问题：ohos TLS 栈（http/webSocket/TLSSocket）在 `ca` 未提供时用系统 CA 校验，自签证书握手必败；而指纹校验必须拿到证书字节。QR 深链是唯一先于连接建立的可信带外信道（桌面屏幕 → 相机/人眼），因此：

```text
桌面 Web 出码（浏览器与 server 同源，已人工信任）
  → GET /api/pairing/cert 取 certPem（新增公共端点）
  → 深链追加 cert=<base64(DER)>（PEM 去头尾行即 base64 DER，~900 字节）
  → 手机解析链接得到 { host, port, pairCode, name, fp, cert }
  → App 本地校验：SHA-256(SPKI DER of cert) === fp   ← QR 的 fp 来自桌面屏幕，MITM 无法伪造匹配的证书
  → 通过：DER 落沙箱 files/tls/server-ca.pem，作为所有后续请求的 caPath（证书固定）
  → 失败：中止配对，提示"网络中存在风险，请重新出码"
```

- `fp`（SHA-256(SPKI DER) hex 小写）口径与 server.tls spec 一致；SPKI 通过 `cert.createX509Cert(PEM).getPublicKey().getEncoded()` 获得（cryptoFramework 公钥编码即 X.509 SubjectPublicKeyInfo DER）。
- 深链无 `cert` 参数（纯 HTTP server / 旧桌面）：跳过证书固定，http 不带 caPath 走系统校验；若 server 实为自签 HTTPS 会在握手层失败并给出对应建议文案。
- claim 之后 server 下发的 `certFingerprint` 与 `fp` 比对，不一致即中止（双通道一致性）。

### 1.2 页面流（@ohos.router，A5 工作台时迁移系统 Navigation）

| 页面 | PRD | 行为 |
| --- | --- | --- |
| `pages/Index`（改造） | — | 未连接态：价值标语 + 「连接你的电脑」主按钮 → PairingWelcome；已存在档案 → 「进入」按钮（本批仅展示档案名，工作台属 A5） |
| `pages/pairing/PairingWelcome` | ONB-1 | 一屏价值说明 + 「扫码配对」按钮（本批置灰 + "相机扫码即将可用"，深链/粘贴已可用）+ 「手动添加」按钮 → PairingCodeInput |
| `pages/pairing/PairingCodeInput` | ONB-4 | 顶部粘贴框：整段 `zcode://pair?...` 链接自动解析填充；或手填 名称/地址(host:port)/配对码；展示解析结果（名称/host/fp 摘要）；「开始连接」→ claim → SelfCheck |
| `pages/pairing/PairingSelfCheck` | ONB-5 | 三步逐项点亮：①HTTPS+claim（真实：POST claim → GET server-info 带设备 token）②WSS 握手（真实：webSocket(caPath) 连 `/ws` 收 101 即通过）③会话列表拉取（本批占位态：文案"等待会话协议层接入"）；失败给可执行建议（§4 表） |

### 1.3 深链入口

EntryAbility `onCreate`/`onNewWant` 解析 `zcode://pair` want uri（module.json5 skills 已于 Batch 4 注册）→ `AppStorage` 写入链接串 + 路由到 PairingCodeInput 并预填。解析失败的深链弹提示不崩溃。

## 2. 模块与状态所有者

```text
commons/connection（新 HAR，纯逻辑 + 薄 IO 适配，不依赖页面）
  PairCodeLink      深链/手填解析与校验（纯函数，可单测）
  CertPinning       base64 DER↔PEM、SPKI SHA-256 hex（cryptoFramework，可单测比对向量）
  PinnedHttpClient  @ohos.net.http + caPath 的 JSON GET/POST；错误归一为 PinnedHttpError{kind}
  WsProbe           @ohos.net.webSocket + caPath 的握手探针（仅 101 判定，不做帧协议）
  PairingClient     claim / server-info 调用（组合 PinnedHttpClient）
  ConnectionProfile { id, name, host, port, certFingerprint?, certFileName? }
  ProfileStore      @ohos.data.preferences：档案列表 + 活跃档案 id
  TokenStore        @ohos.security.asset：设备 token（不落明文沙箱；别名 zcode_device_token_<serverId>）
所有者边界：页面只持有 UI 状态；档案与 token 的唯一写入路径是 ProfileStore/TokenStore；PairingClient 不落盘。
```

- 事件顺序（一次配对）：解析 → 证书校验 → caPath 落盘 → claim → token 入 Asset → 档案落盘 → 自检。claim 成功但 Asset 写入失败视为配对失败（提示重试，pairCode 已消费需重新出码——与服务端 spec §2 一致）。
- `token` 只出现在内存与 Asset；不进日志、不进 preferences、不进错误文案。

## 3. 不变量

1. 证书固定是默认路径：`fp` 与证书 SPKI 不匹配必须中止；`fp` 缺失且无 `cert` 参数才允许系统校验。
2. claim 请求体 `{ pairCode, deviceName }`；`deviceName` 默认 `<机型> 上的 Harmony`（可改，trim ≤64）。
3. PinnedHttpError.kind 封闭枚举：`PemInvalid` / `FingerprintMismatch` / `ConnectFailed` / `HandshakeFailed` / `Timeout` / `Http(status)` / `BadPayload` —— 页面据此映射建议文案，不做字符串匹配。
4. 自检三步相互独立可重试；任一步失败不阻塞后续步骤的显示（逐项红绿）。
5. ProfileStore 写入原子（先写数据后切活跃指针）；多档案数据结构本批就绪，UI 单档案入口。

## 4. 失败语义 → 可执行建议（ONB-5 文案表）

| kind / 状态码 | 用户文案 |
| --- | --- |
| ConnectFailed | 连不上电脑：检查手机与电脑是否同一网络；电脑端 ZCode 是否在运行 |
| HandshakeFailed / FingerprintMismatch | 安全校验未通过：请重新出码再试（可能有人拦截网络） |
| Http 401 | 配对码无效或已过期：请重新出码 |
| Http 429 | 尝试太频繁：请一分钟后再试 |
| Http 409 | 设备数量已达上限：请在桌面端移除一台设备 |
| Timeout | 网络超时：检查 Wi-Fi 与防火墙是否放行端口 |

## 5. 验收场景

| # | 场景 | 期望 |
| --- | --- | --- |
| A3-1 | 粘贴合法深链 → 解析填充 → claim → 自检 ①② 绿 | 档案落盘、桌面设备列表出现新设备 |
| A3-2 | 篡改 cert 字节（fp 不匹配） | FingerprintMismatch，不发起 claim |
| A3-3 | 粘贴非 `zcode://pair` 文本 | 输入框提示格式错误，不跳转 |
| A3-4 | 错误 pairCode | 自检页 Http 401 文案 |
| A3-5 | 深链冷启动/热启动进入 | 两者都路由到 PairingCodeInput 且预填 |
| A3-6 | 预览器渲染三个新页面 | 布局完整、深浅主题可读（预览器无网络，真实请求路径以单测 + 真机联调覆盖） |
| A3-7 | Asset Kit 不可用环境（预览器/CI） | TokenStore 抛封闭错误，页面显示明确失败，不静默降级为明文落盘 |
