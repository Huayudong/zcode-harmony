/**
 * 配对成功后的会话参数（页面间传递，a3-pairing spec §2）。
 * 仅存内存（router params / AppStorage），不落明文：token 的持久化只在 AssetTokenStore。
 */
export interface PairingSession {
  host: string;
  port: number;
  serverName: string;
  serverId: string;
  certFingerprint: string;
  /** 证书 PEM（内存态；持久副本在沙箱 tls/server-ca.pem）。 */
  caPem: string;
  /** 设备 token（内存态；持久副本在 Asset Kit）。 */
  token: string;
}

/** 深链/粘贴导入时跳转 PairingCodeInput 的路由参数。 */
export interface PairRouteParams {
  /** 整段 zcode://pair 链接；空串表示从欢迎页手动进入。 */
  link: string;
}
