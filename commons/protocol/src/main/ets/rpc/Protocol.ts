/**
 * Layer 2 传输协议（@zcode/rpc protocol.ts 的鸿蒙移植，L2 子集）：
 * ChunkStream（分片/粘包）+ 消息帧（13 字节头）+ SocketProtocol + createQueuePair 测试装置。
 * MessagePortProtocol / PersistentProtocol 按计划在后续批次移植。
 */

import { VSBuffer } from './Buffer.js';
import { DisposableStore, Emitter, type Event, type IDisposable } from './Foundation.js';

// ============================================================================
// 核心传输接口
// ============================================================================

export interface IMessagePassingProtocol {
  send(buffer: VSBuffer): void;
  readonly onMessage: Event<VSBuffer>;
  drain?(): Promise<void>;
}

export interface ISocket extends IDisposable {
  onData: Event<VSBuffer>;
  onClose: Event<void>;
  onEnd: Event<void>;
  write(buffer: VSBuffer): void;
  end(): void;
  drain(): Promise<void>;
}

// ============================================================================
// ChunkStream —— 处理流式传输的分片和粘包
// ============================================================================

export class ChunkStream {
  private chunks: VSBuffer[] = [];
  private totalLength = 0;

  public get byteLength(): number {
    return this.totalLength;
  }

  public acceptChunk(chunk: VSBuffer): void {
    this.chunks.push(chunk);
    this.totalLength += chunk.byteLength;
  }

  /** 预览前 byteCount 字节，但不消费底层缓冲。 */
  public peek(byteCount: number): VSBuffer | null {
    if (this.totalLength < byteCount) {
      return null;
    }

    if (this.chunks[0].byteLength >= byteCount) {
      return this.chunks[0].slice(0, byteCount);
    }

    const result = VSBuffer.alloc(byteCount);
    let offset = 0;
    for (const chunk of this.chunks) {
      if (offset >= byteCount) {
        break;
      }

      const remaining = byteCount - offset;
      const copyLength = Math.min(chunk.byteLength, remaining);
      result.set(copyLength === chunk.byteLength ? chunk : chunk.slice(0, copyLength), offset);
      offset += copyLength;
    }

    return result;
  }

  /** 丢弃前 byteCount 字节 */
  public skip(byteCount: number): void {
    const discarded = this.read(byteCount);
    if (!discarded) {
      throw new Error(`ChunkStream.skip(${byteCount}) 超出可读范围`);
    }
  }

  /** 读取 byteCount 字节，不够就返回 null */
  public read(byteCount: number): VSBuffer | null {
    if (this.totalLength < byteCount) {
      return null;
    }

    if (this.chunks[0].byteLength === byteCount) {
      const result = this.chunks.shift();
      this.totalLength -= byteCount;
      return result ?? null;
    }

    if (this.chunks[0].byteLength > byteCount) {
      const result = this.chunks[0].slice(0, byteCount);
      this.chunks[0] = this.chunks[0].slice(byteCount);
      this.totalLength -= byteCount;
      return result;
    }

    // 需要跨多个 chunk 拼接
    const result = VSBuffer.alloc(byteCount);
    let offset = 0;
    while (offset < byteCount) {
      const chunk = this.chunks[0];
      const needed = byteCount - offset;
      if (chunk.byteLength <= needed) {
        result.set(chunk, offset);
        offset += chunk.byteLength;
        this.chunks.shift();
      } else {
        result.set(chunk.slice(0, needed), offset);
        this.chunks[0] = chunk.slice(needed);
        offset += needed;
      }
    }
    this.totalLength -= byteCount;
    return result;
  }
}

// ============================================================================
// 消息帧（13 字节头）
// ============================================================================

export enum ProtocolMessageType {
  None = 0,
  Regular = 1,
  Control = 2,
  Ack = 3,
  Disconnect = 5,
  ReplayRequest = 6,
  Pause = 7,
  Resume = 8,
  KeepAlive = 9
}

export const HEADER_SIZE = 13; // type(1) + id(4) + ack(4) + length(4)

export class ProtocolMessage {
  public readonly type: ProtocolMessageType;
  public readonly id: number;
  public readonly ack: number;
  public readonly data: VSBuffer;

  constructor(type: ProtocolMessageType, id: number, ack: number, data: VSBuffer) {
    this.type = type;
    this.id = id;
    this.ack = ack;
    this.data = data;
  }

  public get byteLength(): number {
    return HEADER_SIZE + this.data.byteLength;
  }
}

export function writeProtocolMessage(msg: ProtocolMessage): VSBuffer {
  const result = VSBuffer.alloc(HEADER_SIZE + msg.data.byteLength);
  result.writeUInt8(msg.type, 0);
  result.writeUInt32BE(msg.id, 1);
  result.writeUInt32BE(msg.ack, 5);
  result.writeUInt32BE(msg.data.byteLength, 9);
  result.set(msg.data, HEADER_SIZE);
  return result;
}

// ============================================================================
// SocketProtocol —— 在 ISocket 上加消息分帧
// ============================================================================

export class SocketProtocol implements IMessagePassingProtocol {
  private readonly _onMessage = new Emitter<VSBuffer>();
  public readonly onMessage: Event<VSBuffer> = this._onMessage.event;

  private readonly chunkStream = new ChunkStream();
  private readonly disposables = new DisposableStore();
  private readonly socket: ISocket;

  constructor(socket: ISocket) {
    this.socket = socket;
    this.disposables.add(
      socket.onData((data: VSBuffer) => {
        this.chunkStream.acceptChunk(data);
        this.readMessages();
      })
    );
  }

  public send(buffer: VSBuffer): void {
    this.writeMessage(new ProtocolMessage(ProtocolMessageType.Regular, 0, 0, buffer));
  }

  private writeMessage(msg: ProtocolMessage): void {
    this.socket.write(writeProtocolMessage(msg));
  }

  private readMessages(): void {
    while (true) {
      const header = this.chunkStream.peek(HEADER_SIZE);
      if (!header) {
        break;
      }

      const type = header.readUInt8(0) as ProtocolMessageType;
      const length = header.readUInt32BE(9);

      const totalFrameLength = HEADER_SIZE + length;
      if (this.chunkStream.byteLength < totalFrameLength) {
        // 不能在 body 未到齐时提前消费 header（原包同款防卡死语义）。
        break;
      }

      this.chunkStream.skip(HEADER_SIZE);

      if (length === 0) {
        if (type === ProtocolMessageType.Regular) {
          this._onMessage.fire(VSBuffer.alloc(0));
        }
        continue;
      }

      const body = this.chunkStream.read(length);
      if (!body) {
        throw new Error('SocketProtocol 读取到完整帧长度后 body 不应为空');
      }

      if (type === ProtocolMessageType.Regular) {
        this._onMessage.fire(body);
      }
    }
  }

  public async drain(): Promise<void> {
    return this.socket.drain();
  }

  public dispose(): void {
    this.disposables.dispose();
    this._onMessage.dispose();
  }
}

// ============================================================================
// QueueProtocol —— 内存中的协议对，用于测试
// ============================================================================

export function createQueuePair(): [IMessagePassingProtocol, IMessagePassingProtocol] {
  const emitterA = new Emitter<VSBuffer>();
  const emitterB = new Emitter<VSBuffer>();

  const protocolA: IMessagePassingProtocol = {
    send: (buffer: VSBuffer) => {
      // A 发送的消息 → B 收到
      setTimeout(() => emitterB.fire(buffer), 0);
    },
    onMessage: emitterA.event
  };

  const protocolB: IMessagePassingProtocol = {
    send: (buffer: VSBuffer) => {
      // B 发送的消息 → A 收到
      setTimeout(() => emitterA.fire(buffer), 0);
    },
    onMessage: emitterB.event
  };

  return [protocolA, protocolB];
}
