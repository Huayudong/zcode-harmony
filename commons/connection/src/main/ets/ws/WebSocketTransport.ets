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

/** server /ws 契约：每 5s 下发一帧 KeepAlive（type 9）。客户端以入站静默判死：
 * 检测间隔 5s，静默 15s（约连丢 3 帧）即视为断线，交由上层退避重连。 */
const HEARTBEAT_CHECK_INTERVAL_MS = 5000;
const HEARTBEAT_SILENCE_TIMEOUT_MS = 15000;

export class WebSocketTransport implements ISocket {
  private readonly ws: webSocket.WebSocket = webSocket.createWebSocket();
  private readonly dataEmitter = new Emitter<VSBuffer>();
  private readonly closeEmitter = new Emitter<void>();
  private readonly endEmitter = new Emitter<void>();
  private closed = false;
  /** 最近一次入站帧时间（心跳活性依据）。 */
  private lastInboundAt = 0;
  private heartbeatTimer: number = -1;

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
    options.proxy = 'no-proxy'; // 同 PinnedHttpClient：钉扎直连不经系统代理
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
      this.lastInboundAt = Date.now();
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
    this.lastInboundAt = Date.now();
    this.startHeartbeat();
    hilog.info(0x0000, 'ZCodeWs', 'transport connect resolved');
  }

  /** 入站静默监测：超阈即判死，上层经 onEnd 触发退避重连。 */
  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.closed) {
        return;
      }
      const silentFor = Date.now() - this.lastInboundAt;
      if (silentFor > HEARTBEAT_SILENCE_TIMEOUT_MS) {
        hilog.error(0x0000, 'ZCodeWs', 'heartbeat timeout: silent %{public}dms, mark dead', silentFor);
        this.fireClosed();
      }
    }, HEARTBEAT_CHECK_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private fireClosed(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.stopHeartbeat();
    this.closeEmitter.fire();
    this.endEmitter.fire();
  }

  private toArrayBuffer(buffer: VSBuffer): ArrayBuffer {
    const u8: Uint8Array = buffer.buffer;
    return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
  }

  write(buffer: VSBuffer): void {
    console.info('ZCodeWs write enter len=' + String(buffer.byteLength) + ' closed=' + String(this.closed));
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
