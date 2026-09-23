/**
 * WSS 握手探针（ONB-5 第②步，a3-pairing spec §1.2）。
 * 只判定 TLS+Upgrade 是否成功（open 事件即 101 完成），不做帧协议——RPC 会话属 L3/L4 下一批。
 * caFilePath 为空串时按 ws:// 直连（无 TLS 部署）。
 */
import webSocket from '@ohos.net.webSocket';
import { BusinessError } from '@ohos.base';
import { PinnedHttpError, PinnedHttpTarget } from '../http/PinnedHttpClient';

export async function probeWsHandshake(target: PinnedHttpTarget, path: string,
  caFilePath: string, timeoutMs: number = 8000): Promise<void> {
  const scheme = target.caPem.length > 0 ? 'wss' : 'ws';
  const url = `${scheme}://${target.host}:${target.port}${path}`;
  const ws = webSocket.createWebSocket();
  const options: webSocket.WebSocketRequestOptions = {};
  if (target.caPem.length > 0 && caFilePath.length > 0) {
    options.caPath = caFilePath;
  }
  return new Promise<void>((resolve, reject) => {
    let settled = false;
    const finish = (error: PinnedHttpError | null) => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        ws.off('open');
        ws.off('error');
      } catch {
        // 侦听器可能尚未注册成功，忽略。
      }
      ws.close().catch(() => {
        // 未完成握手时 close 会失败，探针语义下忽略。
      });
      if (error === null) {
        resolve();
      } else {
        reject(error);
      }
    };
    const timer = setTimeout(() => {
      finish(new PinnedHttpError('Timeout', 'WSS 握手超时'));
    }, timeoutMs);
    const settle = (error: PinnedHttpError | null) => {
      clearTimeout(timer);
      finish(error);
    };
    ws.on('open', () => {
      settle(null);
    });
    ws.on('error', (error: BusinessError) => {
      const message = error.message !== undefined ? String(error.message) : JSON.stringify(error);
      const lowered = message.toLowerCase();
      if (lowered.includes('ssl') || lowered.includes('certificate') || lowered.includes('trust')
        || lowered.includes('handshake')) {
        settle(new PinnedHttpError('HandshakeFailed', message));
        return;
      }
      settle(new PinnedHttpError('ConnectFailed', message));
    });
    ws.connect(url, options).catch((error: BusinessError) => {
      const message = error.message !== undefined ? String(error.message) : JSON.stringify(error);
      settle(new PinnedHttpError('ConnectFailed', message));
    });
  });
}
