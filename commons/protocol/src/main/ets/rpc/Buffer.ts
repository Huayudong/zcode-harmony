/// <reference path="./globals.d.ts" />
/**
 * Layer 0 基础设施：VSBuffer（@zcode/rpc buffer.ts 的鸿蒙移植）。
 * 移植原则：逐行为对齐原实现，编码字节必须与原包一致（一致性测试门禁）。
 * 纯 Web 标准 API，无 Node 依赖；ArkTS 兼容（显式类型、无 any）。
 */

export class VSBuffer {
  readonly buffer: Uint8Array;
  readonly byteLength: number;

  private constructor(buffer: Uint8Array) {
    this.buffer = buffer;
    this.byteLength = buffer.byteLength;
  }

  /** 分配指定大小的空 buffer */
  public static alloc(byteLength: number): VSBuffer {
    return new VSBuffer(new Uint8Array(byteLength));
  }

  /** 包装已有的 Uint8Array */
  public static wrap(buffer: Uint8Array): VSBuffer {
    return new VSBuffer(buffer);
  }

  /** 从字符串创建 buffer (UTF-8) */
  public static fromString(str: string): VSBuffer {
    const encoder = new TextEncoder();
    return new VSBuffer(encoder.encode(str));
  }

  /** 拼接多个 buffer */
  public static concat(buffers: VSBuffer[], totalLength?: number): VSBuffer {
    const len = totalLength ?? buffers.reduce((sum: number, b: VSBuffer) => sum + b.byteLength, 0);
    const result = VSBuffer.alloc(len);
    let offset = 0;
    for (const buf of buffers) {
      result.set(buf, offset);
      offset += buf.byteLength;
    }
    return result;
  }

  /** 转为 UTF-8 字符串 */
  public toString(): string {
    const decoder = new TextDecoder();
    return decoder.decode(this.buffer);
  }

  /** 切片 */
  public slice(start: number, end?: number): VSBuffer {
    return new VSBuffer(this.buffer.slice(start, end));
  }

  /** 拷贝数据到 this buffer 的指定位置 */
  public set(source: VSBuffer | Uint8Array, offset: number = 0): void {
    const raw = source instanceof VSBuffer ? source.buffer : source;
    this.buffer.set(raw, offset);
  }

  public readUInt8(offset: number): number {
    return this.buffer[offset];
  }

  public writeUInt8(value: number, offset: number): void {
    this.buffer[offset] = value;
  }

  public readUInt32BE(offset: number): number {
    return (
      ((this.buffer[offset] << 24) |
        (this.buffer[offset + 1] << 16) |
        (this.buffer[offset + 2] << 8) |
        this.buffer[offset + 3]) >>>
      0
    );
  }

  public writeUInt32BE(value: number, offset: number): void {
    this.buffer[offset] = (value >>> 24) & 0xff;
    this.buffer[offset + 1] = (value >>> 16) & 0xff;
    this.buffer[offset + 2] = (value >>> 8) & 0xff;
    this.buffer[offset + 3] = value & 0xff;
  }
}
