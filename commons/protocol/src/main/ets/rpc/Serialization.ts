/**
 * Layer 1 二进制序列化（@zcode/rpc serialization.ts 的鸿蒙移植）。
 *
 * 格式: [1 byte 类型标签] [VQL 编码的长度] [数据]
 * VQL (Variable-Length Quantity)：7 bit 数据 + 最高位续传标记。
 *
 * 与原包差异（一致性测试逐字节门禁覆盖）：
 * 1. 去 `any`：入参/出参改 unknown；
 * 2. base64 自带纯 TS 实现，替换 `globalThis.Buffer` / `btoa` 探测（鸿蒙两样都没有）。
 */

import { VSBuffer } from './Buffer.js';

export interface IReader {
  read(bytes: number): VSBuffer;
}

export interface IWriter {
  write(buffer: VSBuffer): void;
}

/** BufferReader: 从一个 VSBuffer 中按顺序读取数据。 */
export class BufferReader implements IReader {
  private pos = 0;
  private buffer: VSBuffer;

  constructor(buffer: VSBuffer) {
    this.buffer = buffer;
  }

  public read(bytes: number): VSBuffer {
    const result = this.buffer.slice(this.pos, this.pos + bytes);
    this.pos += result.byteLength;
    return result;
  }
}

/** BufferWriter: 收集多个写入的 buffer，最后一次性拼接。 */
export class BufferWriter implements IWriter {
  private buffers: VSBuffer[] = [];

  public get buffer(): VSBuffer {
    return VSBuffer.concat(this.buffers);
  }

  public write(buffer: VSBuffer): void {
    this.buffers.push(buffer);
  }
}

// ============================================================================
// VQL 编码
// ============================================================================

function readIntVQL(reader: IReader): number {
  let value = 0;
  for (let n = 0; ; n += 7) {
    const next = reader.read(1);
    value |= (next.buffer[0] & 0b01111111) << n;
    if (!(next.buffer[0] & 0b10000000)) {
      return value;
    }
  }
}

const vqlZero = createOneByteBuffer(0);

function writeInt32VQL(writer: IWriter, value: number): void {
  if (value === 0) {
    writer.write(vqlZero);
    return;
  }
  let len = 0;
  for (let v = value; v !== 0; v = v >>> 7) {
    len++;
  }

  const scratch = VSBuffer.alloc(len);
  for (let i = 0; value !== 0; i++) {
    scratch.buffer[i] = value & 0b01111111;
    value = value >>> 7;
    if (value > 0) {
      scratch.buffer[i] |= 0b10000000;
    }
  }
  writer.write(scratch);
}

// ============================================================================
// 数据类型标签
// ============================================================================

enum DataType {
  Undefined = 0,
  String = 1,
  Buffer = 2,
  VSBuffer = 3,
  Array = 4,
  Object = 5,
  Int = 6
}

function createOneByteBuffer(value: number): VSBuffer {
  const result = VSBuffer.alloc(1);
  result.writeUInt8(value, 0);
  return result;
}

const BufferPresets = {
  Undefined: createOneByteBuffer(DataType.Undefined),
  String: createOneByteBuffer(DataType.String),
  Buffer: createOneByteBuffer(DataType.Buffer),
  VSBuffer: createOneByteBuffer(DataType.VSBuffer),
  Array: createOneByteBuffer(DataType.Array),
  Object: createOneByteBuffer(DataType.Object),
  Int: createOneByteBuffer(DataType.Int)
};

const RPC_NESTED_UINT8_ARRAY_MARKER = '__zcode_rpc_nested_uint8array_v1';
const RPC_NESTED_UINT8_ARRAY_BASE64_KEY = 'base64';

// ============================================================================
// 纯 TS base64（鸿蒙无 Buffer / btoa；与标准 base64 输出一致）
// ============================================================================

const BASE64_TABLE =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function bytesToBase64(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += BASE64_TABLE[(n >>> 18) & 63] + BASE64_TABLE[(n >>> 12) & 63] +
      BASE64_TABLE[(n >>> 6) & 63] + BASE64_TABLE[n & 63];
  }
  const rest = bytes.length - i;
  if (rest === 1) {
    const n = bytes[i] << 16;
    out += BASE64_TABLE[(n >>> 18) & 63] + BASE64_TABLE[(n >>> 12) & 63] + '==';
  } else if (rest === 2) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += BASE64_TABLE[(n >>> 18) & 63] + BASE64_TABLE[(n >>> 12) & 63] +
      BASE64_TABLE[(n >>> 6) & 63] + '=';
  }
  return out;
}

export function base64ToBytes(base64: string): Uint8Array {
  const clean = base64.replace(/[^A-Za-z0-9+/]/g, '');
  const padding = clean.endsWith('==') ? 2 : clean.endsWith('=') ? 1 : 0;
  const byteCount = Math.floor((clean.length * 6) / 8) - padding;
  const bytes = new Uint8Array(byteCount);
  let buffer = 0;
  let bits = 0;
  let outIndex = 0;
  for (let i = 0; i < clean.length && outIndex < byteCount; i++) {
    const value = BASE64_TABLE.indexOf(clean.charAt(i));
    if (value < 0) {
      continue;
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes[outIndex] = (buffer >>> bits) & 0xff;
      outIndex += 1;
    }
  }
  return bytes;
}

// ============================================================================
// serialize / deserialize
// ============================================================================

export function serialize(writer: IWriter, data: unknown): void {
  if (typeof data === 'undefined') {
    writer.write(BufferPresets.Undefined);
  } else if (typeof data === 'string') {
    const buffer = VSBuffer.fromString(data);
    writer.write(BufferPresets.String);
    writeInt32VQL(writer, buffer.byteLength);
    writer.write(buffer);
  } else if (data instanceof VSBuffer) {
    writer.write(BufferPresets.VSBuffer);
    writeInt32VQL(writer, data.byteLength);
    writer.write(data);
  } else if (data instanceof Uint8Array) {
    const buffer = VSBuffer.wrap(data);
    writer.write(BufferPresets.Buffer);
    writeInt32VQL(writer, buffer.byteLength);
    writer.write(buffer);
  } else if (Array.isArray(data)) {
    writer.write(BufferPresets.Array);
    writeInt32VQL(writer, data.length);
    for (const el of data) {
      serialize(writer, el);
    }
  } else if (typeof data === 'number' && (data | 0) === data) {
    // 整数用 VQL 编码，比 JSON 更紧凑
    writer.write(BufferPresets.Int);
    writeInt32VQL(writer, data);
  } else {
    // 对象字段里的 Uint8Array 在 JSON fallback 中加标记，反序列化时恢复为二进制。
    const buffer = VSBuffer.fromString(JSON.stringify(data, encodeRpcJsonValue));
    writer.write(BufferPresets.Object);
    writeInt32VQL(writer, buffer.byteLength);
    writer.write(buffer);
  }
}

export function deserialize(reader: IReader): unknown {
  const type = reader.read(1).readUInt8(0);

  switch (type) {
    case DataType.Undefined:
      return undefined;
    case DataType.String:
      return reader.read(readIntVQL(reader)).toString();
    case DataType.Buffer:
      return reader.read(readIntVQL(reader)).buffer;
    case DataType.VSBuffer:
      return reader.read(readIntVQL(reader));
    case DataType.Array: {
      const length = readIntVQL(reader);
      const result: unknown[] = [];
      for (let i = 0; i < length; i++) {
        result.push(deserialize(reader));
      }
      return result;
    }
    case DataType.Object:
      return JSON.parse(reader.read(readIntVQL(reader)).toString(), decodeRpcJsonValue);
    case DataType.Int:
      return readIntVQL(reader);
    default:
      return undefined;
  }
}

function encodeRpcJsonValue(_key: string, value: unknown): unknown {
  if (value instanceof Uint8Array) {
    const marked: Record<string, unknown> = {};
    marked[RPC_NESTED_UINT8_ARRAY_MARKER] = true;
    marked[RPC_NESTED_UINT8_ARRAY_BASE64_KEY] = bytesToBase64(value);
    return marked;
  }
  return value;
}

function decodeRpcJsonValue(_key: string, value: unknown): unknown {
  if (!isRpcEncodedUint8Array(value)) {
    return value;
  }
  const record = value as Record<string, unknown>;
  return base64ToBytes(record[RPC_NESTED_UINT8_ARRAY_BASE64_KEY] as string);
}

function isRpcEncodedUint8Array(value: unknown): boolean {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const record = value as Record<string, unknown>;
  return (
    record[RPC_NESTED_UINT8_ARRAY_MARKER] === true &&
    typeof record[RPC_NESTED_UINT8_ARRAY_BASE64_KEY] === 'string' &&
    Object.keys(record).length === 2
  );
}
