/**
 * WebSocketTransport（L5）：@ohos.net.webSocket → protocol 层 ISocket。
 * 对齐原包 @zcode/client wrapBrowserWebSocket 语义：
 * - 二进制帧 → VSBuffer（onData）；close/error → onClose+onEnd
 * - write 在 OPEN 态发送；end/dispose 关闭连接
 * 扩展：wss 走 caPath 证书固定（a3-pairing §1.1），WS 升级请求带
 * Authorization: Bearer <deviceToken>（SRV-2 Bearer 通道）。
 */
import webSocket from '@ohos.net.webSocket';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BusinessError } from '@ohos.base';
import { VSBuffer, Emitter, type ISocket, type Event, type IDisposable } from 'protocol';
import { PinnedHttpTarget } from '../http/PinnedHttpClient';

export class WebSocketTransport implements ISocket {
  private readonly ws: webSocket.WebSocket = webSocket.createWebSocket();
  private readonly dataEmitter = new Emitter<VSBuffer>();
  private readonly closeEmitter = new Emitter<void>();
  private readonly endEmitter = new Emitter<void>();
  private closed = false;

  readonly onData: Event<VSBuffer> = this.dataEmitter.event;
  readonly onClose: Event<void> = this.closeEmitter.event;
  readonly onEnd: Event<void> = this.endEmitter.event;

  /**
   * 建立 WSS/WS 连接。caFilePath 非空且 target.caPem 非空时启用证书固定；
   * bearerToken 非空时升级请求携带 Authorization 头。
   */
  async connect(target: PinnedHttpTarget, bearerToken: string, caFilePath: string): Promise<void> {
    const scheme = target.caPem.length > 0 ? 'wss' : 'ws';
    const url = `${scheme}://${target.host}:${target.port}/ws`;
    const options: webSocket.WebSocketRequestOptions = {};
    if (target.caPem.length > 0 && caFilePath.length > 0) {
      options.caPath = caFilePath;
    }
    const header: Record<string, string> = {};
    if (bearerToken.length > 0) {
      header['Authorization'] = `Bearer ${bearerToken}`;
    }
    if (Object.keys(header).length > 0) {
      options.header = header;
    }

    this.ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
      // /ws 只走二进制帧（socket 协议 13 字节分帧）；文本帧忽略
      const raw: object = value as object;
      hilog.info(0x0000, 'ZCodeWs', 'frame in type=%{public}s len=%{public}d', typeof value, (value as ArrayBuffer).byteLength);
      try {
        if (raw instanceof ArrayBuffer) {
          this.dataEmitter.fire(VSBuffer.wrap(new Uint8Array(raw)));
        } else if (raw instanceof Uint8Array) {
          this.dataEmitter.fire(VSBuffer.wrap(raw));
        } else {
          hilog.warn(0x0000, 'ZCodeWs', 'frame in 非二进制: %{public}s', String(value).slice(0, 40));
        }
      } catch (e) {
        hilog.error(0x0000, 'ZCodeWs', 'dispatch throw: %{public}s', String(e).slice(0, 250));
      }
    });
    this.ws.on('close', (_err: BusinessError, _value: webSocket.CloseResult) => {
      this.fireClosed();
    });
    this.ws.on('error', (_err: BusinessError) => {
      this.fireClosed();
    });

    await this.ws.connect(url, options);
    hilog.info(0x0000, 'ZCodeWs', 'transport connect resolved');
  }

  private fireClosed(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.closeEmitter.fire();
    this.endEmitter.fire();
  }

  private toArrayBuffer(buffer: VSBuffer): ArrayBuffer {
    const u8: Uint8Array = buffer.buffer;
    return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
  }

  write(buffer: VSBuffer): void {
    if (this.closed) {
      return;
    }
    hilog.info(0x0000, 'ZCodeWs', 'frame out %{public}d: %{public}s', buffer.byteLength, JSON.stringify(Array.from(buffer.buffer.slice(0, 20))));
    this.ws.send(this.toArrayBuffer(buffer)).catch(() => {
      this.fireClosed();
    });
  }

  end(): void {
    this.fireClosed();
    this.ws.close().catch(() => {
      // 未完成握手时 close 会失败，语义上已结束
    });
  }

  drain(): Promise<void> {
    return Promise.resolve();
  }

  dispose(): void {
    this.end();
  }
}
