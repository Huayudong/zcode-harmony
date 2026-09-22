/**
 * 协议一致性门禁（开发计划 §5.3 / 移植 P1）：
 * 同一组向量分别喂给 @zcode/rpc 原包（TS 源）与 commons/protocol 移植层，
 * 断言编码结果逐字节一致、解码结果语义一致、分帧行为一致。
 *
 * 原包路径默认 F:/program/zcode/packages/rpc/src，用环境变量 ZCODE_RPC_SRC 覆盖。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const ORIGIN = process.env.ZCODE_RPC_SRC ?? 'F:/program/zcode/packages/rpc/src';
const PORT_DIR = path.resolve(import.meta.dirname, '../../commons/protocol/src/main/ets/rpc');

async function load(dir, file) {
  return import(pathToFileURL(path.join(dir, file)).href);
}

const [origSer, origPro, origFnd, origBuf, portSer, portPro, portFnd, portBuf] = await Promise.all([
  load(ORIGIN, 'serialization.ts'),
  load(ORIGIN, 'protocol.ts'),
  load(ORIGIN, 'foundation.ts'),
  load(ORIGIN, 'buffer.ts'),
  load(PORT_DIR, 'Serialization.ts'),
  load(PORT_DIR, 'Protocol.ts'),
  load(PORT_DIR, 'Foundation.ts'),
  load(PORT_DIR, 'Buffer.ts'),
]);

const toNodeBytes = (vsbuffer) => Buffer.from(vsbuffer.buffer);

function serializeBytes(mod, data) {
  const writer = new mod.BufferWriter();
  mod.serialize(writer, data);
  return writer.buffer;
}

// ---------------------------------------------------------------------------
// 向量组：序列化（覆盖全部类型标签与 VQL 边界）
// ---------------------------------------------------------------------------

test('基础类型向量：逐字节一致', () => {
  const vectors = [
    ['undefined', undefined],
    ['empty string', ''],
    ['ascii', 'hello'],
    ['中文', '在电脑上干活的 Agent'],
    ['emoji', '配对完成 🎉'],
    ['int 0', 0],
    ['int 1', 1],
    ['int 127', 127],
    ['int 128', 128],
    ['int 65535', 65535],
    ['int 2^20', 2 ** 20],
    ['int -1', -1],
    ['int -300', -300],
    ['float（Object fallback）', 3.14],
    ['bool（Object fallback）', true],
    ['null（Object fallback）', null],
  ];
  for (const [name, data] of vectors) {
    const a = serializeBytes(origSer, data);
    const b = serializeBytes(portSer, data);
    assert.ok(toNodeBytes(a).equals(toNodeBytes(b)), `${name} 编码字节不一致`);
    const aBack = origSer.deserialize(new origSer.BufferReader(a));
    const bBack = portSer.deserialize(new portSer.BufferReader(b));
    assert.equal(JSON.stringify(bBack), JSON.stringify(aBack), `${name} 解码语义不一致`);
  }
});

test('Uint8Array 向量（含嵌套 base64 恢复）：逐字节一致', () => {
  const bytes = new Uint8Array(256);
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 37 + 11) & 0xff;
  const a = serializeBytes(origSer, bytes);
  const b = serializeBytes(portSer, bytes);
  assert.ok(toNodeBytes(a).equals(toNodeBytes(b)), 'Uint8Array 编码字节不一致');

  // 嵌套在对象里的 Uint8Array：走 JSON fallback + base64 标记恢复。
  const nestedA = serializeBytes(origSer, { blob: bytes, name: 'x' });
  const nestedB = serializeBytes(portSer, { blob: bytes, name: 'x' });
  assert.ok(toNodeBytes(nestedA).equals(toNodeBytes(nestedB)), '嵌套 Uint8Array 编码字节不一致');
  const restored = portSer.deserialize(new portSer.BufferReader(nestedB));
  assert.ok(restored.blob instanceof Uint8Array);
  assert.ok(Buffer.from(restored.blob).equals(Buffer.from(bytes)));
});

test('数组与嵌套对象向量：逐字节一致', () => {
  const vectors = [
    [],
    [1, 'a', undefined],
    { a: 1, b: 'x', c: { d: [1, 2, { e: '深' }] } },
    { nested: { deep: { list: [true, null, 3.5] } } },
  ];
  for (const [index, data] of vectors.entries()) {
    const a = serializeBytes(origSer, data);
    const b = serializeBytes(portSer, data);
    assert.ok(toNodeBytes(a).equals(toNodeBytes(b)), `向量 ${index} 编码字节不一致`);
  }
});

// ---------------------------------------------------------------------------
// 分帧：writeProtocolMessage 逐字节一致 + 跨实现分片重组
// ---------------------------------------------------------------------------

function fakePayload(size, seed) {
  const bytes = new Uint8Array(size);
  for (let i = 0; i < size; i++) bytes[i] = (i * 31 + seed) & 0xff;
  return bytes;
}

class FakeSocket {
  constructor(EmitterCtor) {
    this.written = [];
    const dataEmitter = new EmitterCtor();
    const closeEmitter = new EmitterCtor();
    const endEmitter = new EmitterCtor();
    this.onData = dataEmitter.event;
    this.onClose = closeEmitter.event;
    this.onEnd = endEmitter.event;
    this._data = dataEmitter;
    this.write = (buffer) => {
      this.written.push(Buffer.from(buffer.buffer));
    };
    this.end = () => {};
    this.drain = async () => {};
    this.dispose = () => {};
  }
}

test('消息帧（13 字节头）：原包与移植层逐字节一致', () => {
  const payloads = [0, 1, 5, 64, 1000].map((size, i) => fakePayload(size, i + 1));
  for (const [i, bytes] of payloads.entries()) {
    const a = origPro.writeProtocolMessage(
      new origPro.ProtocolMessage(origPro.ProtocolMessageType.Regular, i, 7, origBuf.VSBuffer.wrap(bytes)),
    );
    const b = portPro.writeProtocolMessage(
      new portPro.ProtocolMessage(portPro.ProtocolMessageType.Regular, i, 7, portBuf.VSBuffer.wrap(bytes)),
    );
    assert.ok(toNodeBytes(a).equals(toNodeBytes(b)), `帧编码不一致（size=${bytes.length}）`);
  }
});

test('分片重组：奇数边界分片喂入移植层，消息序列与原包一致', async () => {
  const payloads = [fakePayload(37, 1), fakePayload(0, 2), fakePayload(256, 3), fakePayload(13, 4)];

  // 原包侧：正常 send，写出帧流
  const origSocket = new FakeSocket(origFnd.Emitter);
  const origSp = new origPro.SocketProtocol(origSocket);
  for (const bytes of payloads) {
    origSp.send(origBuf.VSBuffer.wrap(bytes));
  }
  await new Promise((resolve) => setTimeout(resolve, 10));

  // 移植层侧：把原包写出的帧流按 1/3/7 字节奇数边界切碎喂入
  const portSocket = new FakeSocket(portFnd.Emitter);
  const portSp = new portPro.SocketProtocol(portSocket);
  const portReceived = [];
  portSp.onMessage((buffer) => portReceived.push(Buffer.from(buffer.buffer)));
  const stream = Buffer.concat(origSocket.written);
  let offset = 0;
  const stepCycle = [1, 3, 7, 2, 11];
  let stepIndex = 0;
  while (offset < stream.length) {
    const step = stepCycle[stepIndex++ % stepCycle.length];
    const chunk = stream.subarray(offset, Math.min(offset + step, stream.length));
    portSocket._data.fire(portBuf.VSBuffer.wrap(new Uint8Array(chunk)));
    offset += chunk.length;
  }
  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(portReceived.length, payloads.length, '重组消息数不一致');
  for (let i = 0; i < payloads.length; i++) {
    assert.ok(portReceived[i].equals(Buffer.from(payloads[i])), `第 ${i} 条消息字节不一致`);
  }
});

test('createQueuePair（移植层）：A→B→A 环回', async () => {
  const [a, b] = portPro.createQueuePair();
  const got = [];
  b.onMessage((buffer) => {
    got.push(Buffer.from(buffer.buffer));
    b.send(buffer);
  });
  a.onMessage((buffer) => got.push(Buffer.from(`reply:${Buffer.from(buffer.buffer).toString('utf8')}`)));
  const payload = portBuf.VSBuffer.fromString('ping');
  a.send(payload);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(got, [Buffer.from('ping'), Buffer.from('reply:ping')]);
});
