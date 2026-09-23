/**
 * ChannelClient（@zcode/rpc channelClient.ts 的鸿蒙移植，L2）。
 * 纯客户端：请求/响应 + 事件监听复用同一 request id 空间；
 * 连接终结时所有挂起 Promise 请求 fail-closed，事件订阅走 dispose。
 * L3 的服务 stub 直接用 getChannel(...).call/listen，不用 ES6 Proxy。
 */

import { VSBuffer } from './Buffer.js';
import { CancellationToken, Emitter, eventToPromise, toDisposable, type Event, type IDisposable } from './Foundation.js';
import { BufferReader, BufferWriter, deserialize, serialize } from './Serialization.js';
import type { IMessagePassingProtocol } from './Protocol.js';
import {
  type IChannel,
  type IChannelClient,
  type IHandler,
  type IRemoteErrorData,
  type IRawResponse,
  RequestType,
  ResponseType,
} from './Channels.js';

const enum ClientState {
  Uninitialized,
  Idle,
}

/** PromiseError 透传键（与原包 channelClient.ts 白名单一致）。 */
const PASSTHROUGH_KEYS: readonly string[] = [
  'code',
  'kind',
  'status',
  'retryAfterMs',
  'data',
  'detail',
  'details',
  'taskId',
  'traceId',
];

export class ChannelClient implements IChannelClient, IDisposable {
  private state: ClientState = ClientState.Uninitialized;
  private isDisposed = false;
  private activeRequests = new Set<IDisposable>();
  private handlers = new Map<number, IHandler>();
  // Promise 请求和事件监听共用 handlers，但只有前者需要在连接终结时 reject。
  // 单独维护 reject map，避免 dispose 把事件订阅误当成挂起的 RPC 请求。
  private pendingRejections = new Map<number, (error: Error) => void>();
  private lastRequestId = 0;
  private readonly protocol: IMessagePassingProtocol;
  private protocolListener: IDisposable | null;

  private readonly _onDidInitialize = new Emitter<void>();
  readonly onDidInitialize = this._onDidInitialize.event;

  constructor(protocol: IMessagePassingProtocol) {
    this.protocol = protocol;
    this.protocolListener = protocol.onMessage((msg: VSBuffer) => this.onBuffer(msg));
  }

  getChannel<T extends IChannel>(channelName: string): T {
    const client = this;
    const channel: IChannel = {
      call<T>(command: string, arg?: object | null, cancellationToken?: CancellationToken): Promise<T> {
        if (client.isDisposed) {
          return Promise.reject(new Error('ChannelClient is disposed'));
        }
        return client.requestPromise(channelName, command, arg, cancellationToken) as Promise<T>;
      },
      listen<T>(event: string, arg?: object | null): Event<T> {
        if (client.isDisposed) {
          return eventNone<T>();
        }
        return client.requestEvent<T>(channelName, event, arg);
      },
    };
    return channel as T;
  }

  private requestPromise(
    channelName: string,
    name: string,
    arg?: object | null,
    cancellationToken: CancellationToken = CancellationToken.None,
  ): Promise<object | null> {
    const id = this.lastRequestId++;

    if (cancellationToken.isCancellationRequested) {
      return Promise.reject(new Error('Cancelled'));
    }

    let disposable: IDisposable | undefined;
    const result = new Promise<object | null>((resolve, reject) => {
      this.pendingRejections.set(id, reject);
      const doRequest = () => {
        // dispose/cancel 可能发生在 Initialize 之前；此时不能再把已经 rejected
        // 的请求发送到新连接或已终结的传输上。
        if (this.isDisposed || !this.pendingRejections.has(id)) {
          return;
        }

        const handler: IHandler = (response: IRawResponse) => {
          switch (response.type) {
            case ResponseType.PromiseSuccess:
              this.handlers.delete(id);
              this.pendingRejections.delete(id);
              resolve(response.data);
              return;
            case ResponseType.PromiseError: {
              this.handlers.delete(id);
              this.pendingRejections.delete(id);
              const data: IRemoteErrorData = response.data;
              const error = new Error(data.message) as unknown as Error & Record<string, unknown>;
              error.name = data.name;
              if (data.stack) {
                error.stack = data.stack.join('\n');
              }
              for (const key of PASSTHROUGH_KEYS) {
                const value = (data as unknown as Record<string, unknown>)[key];
                if (value !== undefined) {
                  error[key] = value;
                }
              }
              reject(error);
              return;
            }
            case ResponseType.PromiseErrorObj:
              this.handlers.delete(id);
              this.pendingRejections.delete(id);
              reject(response.data);
              return;
          }
        };

        this.handlers.set(id, handler);
        this.sendRequest(RequestType.Promise, id, channelName, name, arg);
      };

      if (this.state === ClientState.Idle) {
        doRequest();
      } else {
        eventToPromise(this.onDidInitialize).then(doRequest);
      }

      disposable = cancellationToken.onCancellationRequested(() => {
        if (!this.pendingRejections.has(id)) {
          return toDisposable(() => {});
        }
        this.sendCancelOrDispose(RequestType.PromiseCancel, id);
        this.handlers.delete(id);
        this.pendingRejections.delete(id);
        reject(new Error('Cancelled'));
        return toDisposable(() => {});
      });
      this.activeRequests.add(disposable);
    });

    return result.finally(() => {
      disposable?.dispose();
      if (disposable) {
        this.activeRequests.delete(disposable);
      }
    });
  }

  private requestEvent<T>(channelName: string, name: string, arg?: object | null): Event<T> {
    const id = this.lastRequestId++;
    const emitter = new Emitter<T>({
      onWillAddFirstListener: () => {
        const doRequest = () => {
          this.activeRequests.add(emitter);
          this.sendRequest(RequestType.EventListen, id, channelName, name, arg);
        };

        if (this.state === ClientState.Idle) {
          doRequest();
        } else {
          eventToPromise(this.onDidInitialize).then(doRequest);
        }
      },
      onDidRemoveLastListener: () => {
        this.activeRequests.delete(emitter);
        this.sendCancelOrDispose(RequestType.EventDispose, id);
        this.handlers.delete(id);
      },
    });

    this.handlers.set(id, (response: IRawResponse) => {
      emitter.fire((response as unknown as { data: T }).data);
    });

    return emitter.event;
  }

  private sendRequest(
    type: RequestType,
    id: number,
    channelName: string,
    name: string,
    arg?: object | null,
  ): void {
    const writer = new BufferWriter();
    serialize(writer, [type, id, channelName, name]);
    serialize(writer, arg);
    try {
      this.protocol.send(writer.buffer);
    } catch {
      /* 发送失败等 socket close 事件兜底 */
    }
  }

  private sendCancelOrDispose(
    type: number,
    id: number,
  ): void {
    const writer = new BufferWriter();
    serialize(writer, [type, id]);
    serialize(writer, undefined);
    try {
      this.protocol.send(writer.buffer);
    } catch {
      /* 发送失败等 socket close 事件兜底 */
    }
  }

  private onBuffer(message: VSBuffer): void {
    const reader = new BufferReader(message);
    const header = deserialize(reader) as unknown[];
    const body = deserialize(reader) as object | null;
    const type = header[0] as ResponseType;

    switch (type) {
      case ResponseType.Initialize:
        this.onResponse({ type: ResponseType.Initialize });
        return;
      case ResponseType.PromiseSuccess:
      case ResponseType.PromiseError:
      case ResponseType.EventFire:
      case ResponseType.PromiseErrorObj:
        this.onResponse({
          type,
          id: header[1] as number,
          data: body,
        } as IRawResponse);
        return;
    }
  }

  private onResponse(response: IRawResponse): void {
    if (response.type === ResponseType.Initialize) {
      this.state = ClientState.Idle;
      this._onDidInitialize.fire();
      return;
    }

    const handler = this.handlers.get(response.id);
    if (handler) {
      handler(response);
    }
  }

  dispose(reason?: Error): void {
    if (this.isDisposed) {
      return;
    }
    this.isDisposed = true;
    this.protocolListener?.dispose();
    this.protocolListener = null;

    const rejection = reason ?? new Error('ChannelClient disposed');
    if (!reason) {
      rejection.name = 'ConnectionClosed';
    }
    // 传输已终结时，所有已发出以及排队等待 Initialize 的 Promise 请求都必须
    // fail-closed。否则上层的 in-flight 去重 Promise 会永久占用 workspace key。
    for (const [id, reject] of this.pendingRejections) {
      this.pendingRejections.delete(id);
      this.handlers.delete(id);
      reject(rejection);
    }
    for (const disposable of this.activeRequests) {
      disposable.dispose();
    }
    this.activeRequests.clear();
    this.pendingRejections.clear();
    this._onDidInitialize.dispose();
  }
}

/** Event.None 等价（已 dispose 的客户端 listen 返回）。 */
function eventNone<T>(): Event<T> {
  return (): IDisposable => ({ dispose: () => {} });
}
