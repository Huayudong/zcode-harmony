/**
 * 证书固定工具（a3-pairing spec §1.1）。
 * 指纹口径与 server.tls spec 唯一对齐：SHA-256(SPKI DER) hex 小写。
 * SPKI DER 通过 cryptoFramework 公钥编码获得（X509 Cert.getPublicKey().getEncoded() 即 SubjectPublicKeyInfo）。
 */
import cert from '@ohos.security.cert';
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';

const PEM_BODY_LINE_LENGTH: number = 64;
const HEX_CHARS: string = '0123456789abcdef';

export function isBase64Der(text: string): boolean {
  if (text.length === 0 || text.length % 4 !== 0) {
    return false;
  }
  const base64Pattern = /^[A-Za-z0-9+/]+={0,2}$/;
  return base64Pattern.test(text);
}

/** base64 DER → PEM（http caPath/证书解析都需要 PEM 形态）。 */
export function pemFromDerBase64(base64Der: string): string {
  const compact = base64Der.replace(/\s+/g, '');
  let pem = '-----BEGIN CERTIFICATE-----\n';
  for (let offset = 0; offset < compact.length; offset += PEM_BODY_LINE_LENGTH) {
    pem += compact.substring(offset, offset + PEM_BODY_LINE_LENGTH);
    pem += '\n';
  }
  pem += '-----END CERTIFICATE-----\n';
  return pem;
}

/** PEM → base64 DER（与桌面端 QR 的 cert 参数同形态）。 */
export function derBase64FromPem(pem: string): string {
  return pem
    .replace(/-----BEGIN CERTIFICATE-----/, '')
    .replace(/-----END CERTIFICATE-----/, '')
    .replace(/\s+/g, '');
}

function bytesToHex(bytes: Uint8Array): string {
  let hex = '';
  for (const byte of bytes) {
    hex += HEX_CHARS[byte >> 4];
    hex += HEX_CHARS[byte & 0x0f];
  }
  return hex;
}

/**
 * 计算证书的 SPKI SHA-256 hex。解析失败抛 Error（调用方归一为 PemInvalid）。
 */
export async function computeSpkiSha256Hex(pem: string): Promise<string> {
  const encoder = new util.TextEncoder();
  const encoded = encoder.encodeInto(pem);
  const blob: cert.EncodingBlob = {
    data: encoded,
    encodingFormat: cert.EncodingFormat.FORMAT_PEM,
  };
  const x509Cert: cert.X509Cert = await cert.createX509Cert(blob);
  const publicKey: cryptoFramework.PubKey = x509Cert.getPublicKey();
  const der: cryptoFramework.DataBlob = publicKey.getEncoded();
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  await md.update({ data: der.data });
  const digest: cryptoFramework.DataBlob = await md.digest();
  return bytesToHex(digest.data);
}
