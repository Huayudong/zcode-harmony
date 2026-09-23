/**
 * 固定 CA 的 JSON HTTP 客户端（a3-pairing spec §2/§3）。
 * caPem 非空 → HTTPS + caPath 指向沙箱内证书文件（证书固定）；空 → 纯 HTTP（无 TLS 部署）。
 * 所有失败归一为 PinnedHttpError（封闭 kind 枚举），页面据此映射建议文案（spec §4）。
 */
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';

export type PinnedHttpErrorKind =
  | 'PemInvalid'
  | 'ConnectFailed'
  | 'HandshakeFailed'
  | 'Timeout'
  | 'BadPayload'
  | 'HttpStatus';

export class PinnedHttpError extends Error {
  readonly kind: PinnedHttpErrorKind;
  readonly statusCode?: number;

  constructor(kind: PinnedHttpErrorKind, message: string, statusCode?: number) {
    super(message);
    this.name = 'PinnedHttpError';
    this.kind = kind;
    this.statusCode = statusCode;
  }
}

export interface PinnedHttpTarget {
  host: string;
  port: number;
  /** 证书 PEM（非空 = HTTPS + 证书固定；空 = 纯 HTTP）。 */
  caPem: string;
}

/** 沙箱内证书文件路径（PinnedHttpClient 与 WsProbe 共用，caPath 事实源）。 */
export function caFilePathIn(filesDir: string): string {
  return `${filesDir}/tls/server-ca.pem`;
}

/** 把证书 PEM 写入沙箱（幂等）。独立导出，供 WSS 探针在握手前确保文件存在。 */
export async function ensureCaFileWritten(filesDir: string, caPem: string): Promise<string> {
  const path = caFilePathIn(filesDir);
  try {
    const dir = `${filesDir}/tls`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, caPem);
    fs.closeSync(file.fd);
  } catch (error) {
    throw new PinnedHttpError('PemInvalid', `无法写入本机证书缓存: ${String(error)}`);
  }
  return path;
}

interface JsonErrorBody {
  error?: string;
}

/** 传输层失败归一（超时/TLS 握手/连接失败），供 HTTP 与 WSS 两路共用语义。 */
export function mapRequestFailure(error: Object): PinnedHttpError {
  const message = error instanceof Error ? error.message : String(error);
  const lowered = message.toLowerCase();
  if (lowered.includes('timeout') || lowered.includes('timed out')) {
    return new PinnedHttpError('Timeout', message);
  }
  if (lowered.includes('ssl') || lowered.includes('certificate') || lowered.includes('handshake')
    || lowered.includes('trust') || lowered.includes('verify')) {
    return new PinnedHttpError('HandshakeFailed', message);
  }
  return new PinnedHttpError('ConnectFailed', message);
}

export class PinnedHttpClient {
  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  private readonly filesDir: string;

  /**
   * JSON 请求。2xx → 解析后的 body；非 2xx → HttpStatus 错误（带状态码与服务端 error 文案）。
   * bearerToken 为空串时不带 Authorization 头。
   */
  async jsonRequest<T>(target: PinnedHttpTarget, method: http.RequestMethod, path: string,
    body: object | null, bearerToken: string, timeoutMs: number = 8000): Promise<T> {
    let caPath: string | undefined = undefined;
    if (target.caPem.length > 0) {
      caPath = await ensureCaFileWritten(this.filesDir, target.caPem);
    }
    const scheme = target.caPem.length > 0 ? 'https' : 'http';
    const url = `${scheme}://${target.host}:${target.port}${path}`;
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (bearerToken.length > 0) {
      headers['Authorization'] = `Bearer ${bearerToken}`;
    }
    const request: http.HttpRequest = http.createHttp();
    let responseBody: string;
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: method,
        header: headers,
        extraData: body === null ? undefined : JSON.stringify(body),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        caPath: caPath,
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        let serverMessage = '';
        try {
          const parsed = JSON.parse(String(response.result)) as JsonErrorBody;
          serverMessage = parsed.error ?? '';
        } catch {
          // 非 JSON 错误体，保留状态码即可。
        }
        throw new PinnedHttpError('HttpStatus',
          serverMessage.length > 0 ? serverMessage : `HTTP ${response.responseCode}`,
          response.responseCode);
      }
      responseBody = String(response.result);
    } catch (error) {
      if (error instanceof PinnedHttpError) {
        throw error;
      }
      throw mapRequestFailure(error);
    } finally {
      request.destroy();
    }
    try {
      return JSON.parse(responseBody) as T;
    } catch (error) {
      throw new PinnedHttpError('BadPayload', `响应不是合法 JSON: ${String(error)}`);
    }
  }
}
