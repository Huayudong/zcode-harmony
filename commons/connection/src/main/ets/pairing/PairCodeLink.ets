/**
 * 配对深链解析（a3-pairing spec §1.1/§2）。
 * 链接格式（桌面 UI 拼装，各值 encodeURIComponent）：
 *   zcode://pair?host=…&port=…&token=<pairCode>&name=<serverName>&fp=<certFingerprint>&cert=<base64 DER>
 * 纯函数、无 IO，供粘贴导入与深链入口共用。
 */

export interface PairLinkData {
  host: string;
  port: number;
  pairCode: string;
  /** 桌面 server 名称，可能为空串。 */
  name: string;
  /** 自签证书 SPKI SHA-256 hex 小写，可能为空串（纯 HTTP 部署）。 */
  fingerprint: string;
  /** base64 编码的证书 DER，可能为空串（纯 HTTP 部署 / 旧桌面）。 */
  certBase64: string;
}

export const PAIR_LINK_SCHEME: string = 'zcode://pair';

export function isPairLink(raw: string): boolean {
  return raw.trim().startsWith(PAIR_LINK_SCHEME);
}

/** 解析失败返回 null，调用方给出格式错误提示（不抛异常）。 */
export function parsePairLink(raw: string): PairLinkData | null {
  const text = raw.trim();
  if (!text.startsWith(PAIR_LINK_SCHEME)) {
    return null;
  }
  const queryStart = text.indexOf('?');
  if (queryStart < 0) {
    return null;
  }
  const params: Map<string, string> = new Map();
  const segments = text.substring(queryStart + 1).split('&');
  for (const segment of segments) {
    const eq = segment.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key = segment.substring(0, eq).trim();
    if (key.length === 0) {
      continue;
    }
    let value = segment.substring(eq + 1);
    try {
      value = decodeURIComponent(value);
    } catch {
      // 桌面端已 encodeURIComponent；解码失败按原值使用，不让坏值崩掉整个解析。
    }
    params.set(key, value);
  }
  const host = params.get('host') ?? '';
  const portRaw = params.get('port') ?? '';
  const pairCode = params.get('token') ?? '';
  const port = Number.parseInt(portRaw, 10);
  if (host.length === 0 || portRaw.length === 0 || Number.isNaN(port) || port <= 0 || port > 65535) {
    return null;
  }
  if (pairCode.length === 0) {
    return null;
  }
  return {
    host: host,
    port: port,
    pairCode: pairCode,
    name: params.get('name') ?? '',
    fingerprint: (params.get('fp') ?? '').toLowerCase(),
    certBase64: params.get('cert') ?? '',
  };
}
