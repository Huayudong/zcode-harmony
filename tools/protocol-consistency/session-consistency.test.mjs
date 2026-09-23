/**
 * 会话链路一致性门禁（批次6，开发计划 §5.3）：
 * 通道层：移植 ChannelClient ↔ 原包 ChannelServer 环回；
 * 持久层：移植 PersistentProtocol ↔ 原包 PersistentProtocol 互操作（ACK/重放）；
 * v4 语义：delta apply/coalesce 黄金比对（applyAll(s, coalesce(ds)) === 逐条 apply）；
 * 装配层：同一组分片喂移植/原包 TopicWireFrameAssembler，产出逻辑帧一致；
 * 端到端：移植 AgentV4Client 对接原包 ChannelServer 假 host（握手/订阅/帧/水位/resync/命令幂等）。
 *
 * 原包路径默认 F:/program/zcode/{packages/rpc/src,packages/shared/src}，环境变量可覆盖。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const ORIGIN_RPC = process.env.ZCODE_RPC_SRC ?? 'F:/program/zcode/packages/rpc/src';
const ORIGIN_SHARED = process.env.ZCODE_SHARED_SRC ?? 'F:/program/zcode/packages/shared/src';
const PORT_RPC = path.resolve(import.meta.dirname, '../../commons/protocol/src/main/ets/rpc');
const PORT_V4 = path.resolve(import.meta.dirname, '../../commons/protocol/src/main/ets/v4');

async function load(dir, file) {
  return import(pathToFileURL(path.join(dir, file)).href);
}

const [oServer, oProxy, oFnd, oPersist, oTransport, oApply, oCoalesce, oAssembler, oCommand] =
  await Promise.all([
    load(ORIGIN_RPC, 'channelServer.ts'),
    load(ORIGIN_RPC, 'proxy-channel.ts'),
    load(ORIGIN_RPC, 'foundation.ts'),
    load(ORIGIN_RPC, 'persistent-protocol.ts'),
    load(path.join(ORIGIN_SHARED, 'zcode-protocol-v4'), 'transport.ts'),
    load(path.join(ORIGIN_SHARED, 'zcode-protocol-v4'), 'apply.ts'),
    load(path.join(ORIGIN_SHARED, 'zcode-protocol-v4'), 'coalesce.ts'),
    load(path.join(ORIGIN_SHARED, 'zcode-protocol-v4'), 'wire-assembler.ts'),
    load(path.join(ORIGIN_SHARED, 'zcode-protocol-v4'), 'command.ts'),
  ]);

const [pBuffer, pClient, pAgentV4Stub, pAgentV4Client, pQueue, pPersist, pProtocol, pV4Transport, pApply, pCoalesce, pAssembler, pWireBinary] =
  await Promise.all([
    load(PORT_RPC, 'Buffer.ts'),
    load(PORT_RPC, 'ChannelClient.ts'),
    load(PORT_V4, 'AgentV4Stub.ts'),
    load(PORT_V4, 'AgentV4Client.ts'),
    load(PORT_V4, 'PendingCommandQueue.ts'),
    load(PORT_RPC, 'PersistentProtocol.ts'),
    load(PORT_RPC, 'Protocol.ts'),
    load(PORT_V4, 'transport.ts'),
    load(PORT_V4, 'apply.ts'),
    load(PORT_V4, 'coalesce.ts'),
    load(PORT_V4, 'wire-assembler.ts'),
    load(PORT_V4, 'wire-binary.ts'),
  ]);

// ---------------------------------------------------------------------------
// 测试装置
// ---------------------------------------------------------------------------

/** 内存双工 ISocket 对：write 同步投递到对端 onData。 */
function liveSocketPair() {
  function makeEnd() {
    const data = new oFnd.Emitter();
    const close = new oFnd.Emitter();
    const end = {
      peer: null,
      __dataEmitter: data,
      onData: data.event,
      onClose: close.event,
      onEnd: close.event,
      __closeEmitter: close,
      write(buffer) {
        this.peer.__dataEmitter.fire(buffer);
      },
      end() {},
      drain() {
        return Promise.resolve();
      },
      dispose() {
        this.__closeEmitter.fire();
      },
    };
    return end;
  }
  const a = makeEnd();
  const b = makeEnd();
  a.peer = b;
  b.peer = a;
  return [a, b];
}

/** 等待 queuePair 的 setTimeout(0) 投递完成。 */
function settle(ms = 10) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function fakeAgentService() {
  const frameEmitter = new oFnd.Emitter();
  const calls = [];
  const service = {
    calls,
    helloCount: 0,
    initClientHello: null,
    workspace: null,
    acksOfCommands: new Map(),
    helloConversationV4() {
      service.helloCount += 1;
      return Promise.resolve({
        kind: 'hello',
        protocolVersion: 3,
        connectionId: 'conn-test-1',
        clientMode: 'web-remote-replayable',
        deliveryProfile: 'replayable',
        serverTime: 1_726_000_000_000,
        capabilities: { nativeDialogs: false, localTerminal: false, binaryFrames: true, compression: 'none' },
        auth: {},
      });
    },
    initializeConversationV4(clientHello) {
      service.initClientHello = clientHello;
      return Promise.resolve();
    },
    subscribeSessionsIndexV4(params) {
      calls.push({ method: 'subscribeSessionsIndexV4', params });
      service.workspace = params;
      return Promise.resolve({ ack: { subscriptionId: 'sub-si-1', mode: 'snapshot', logEpoch: 'epoch-si-1' } });
    },
    resyncSessionsIndexV4(params) {
      calls.push({ method: 'resyncSessionsIndexV4', params });
      return Promise.resolve({ ack: { subscriptionId: 'sub-si-1', mode: params.base ? 'resume' : 'snapshot', logEpoch: 'epoch-si-2' } });
    },
    unsubscribeSessionsIndexV4() {
      calls.push({ method: 'unsubscribeSessionsIndexV4' });
      return Promise.resolve();
    },
    subscribeConversationV4() {
      return Promise.resolve({ ack: { subscriptionId: 'sub-conv-1', mode: 'snapshot', logEpoch: 'epoch-conv-1' } });
    },
    resyncConversationV4(params) {
      calls.push({ method: 'resyncConversationV4', params });
      return Promise.resolve({ ack: { subscriptionId: 'sub-conv-1', mode: 'snapshot', logEpoch: 'epoch-conv-2' } });
    },
    unsubscribeConversationV4() {
      return Promise.resolve();
    },
    conversationRowsRangeV4() {
      return Promise.resolve({ rows: [], atSeq: 0, atRevision: 0, atLogEpoch: 'e', hasMore: false });
    },
    sendConversationCommandV4(params) {
      calls.push({ method: 'sendConversationCommandV4', params });
      // 服务端用原包 zod 校验移植层生成的信封与 payload
      const parsed = oCommand.parseCommandEnvelope(params.envelope);
      assert.equal(parsed.ok, true, '服务端应接受移植层生成的命令信封');
      return Promise.resolve(
        service.acksOfCommands.get(params.envelope.commandId) ?? {
          commandId: params.envelope.commandId,
          status: 'accepted',
          revisionAtDecision: 1,
        },
      );
    },
    queryConversationCommandsV4() {
      return Promise.resolve({ commands: [] });
    },
    hangCall() {
      return new Promise(() => {});
    },
    onDynamicSessionsIndexFrame(target) {
      calls.push({ method: 'onDynamicSessionsIndexFrame', target });
      return (listener) => frameEmitter.event((w) => { if (String(w && w.topic).startsWith('sessions-index/')) listener(w); });
    },
    onDynamicConversationFrame() {
      return (listener) => frameEmitter.event((w) => { if (String(w && w.topic).startsWith('conversation/')) listener(w); });
    },
    fire(wire) {
      frameEmitter.fire(wire);
    },
  };
  return service;
}

function completeWire(topic, subscriptionId, frame, ordinal = 1) {
  return {
    wireVersion: 3,
    kind: 'complete',
    deliveryKind: 'initial',
    logicalFrameId: `lf-${ordinal}`,
    logicalFrameOrdinal: ordinal,
    topic,
    subscriptionId,
    frame,
  };
}

function sessionsIndexFrameJson(subscriptionId, fromSeq, toSeq, sessions) {
  return {
    topic: 'sessions-index/ws-key',
    subscriptionId,
    fromSeq,
    toSeq,
    sentAt: 1_726_000_000_000,
    payload: {
      kind: 'snapshot',
      snapshot: {
        protocolVersion: 1,
        workspaceId: 'ws-1',
        logEpoch: 'epoch-si-1',
        sessions,
      },
    },
  };
}

function fragmentWire(frameJson, bytes, ordinal, logicalFrameId, parts) {
  const fragSize = Math.ceil(bytes.length / parts);
  return Array.from({ length: parts }, (_, i) => ({
    wireVersion: 3,
    kind: 'fragment',
    deliveryKind: 'online',
    logicalFrameId,
    logicalFrameOrdinal: ordinal,
    topic: frameJson.topic,
    subscriptionId: frameJson.subscriptionId,
    fragmentIndex: i,
    fragmentCount: parts,
    logicalBytes: bytes.length,
    checksum: { algorithm: 'crc32', value: pBuffer.__crc ?? crcOf(bytes) },
    dataBase64: pWireBinary.encodeWireBytesBase64(bytes.slice(i * fragSize, (i + 1) * fragSize)),
  }));
}

function crcOf(bytes) {
  return pWireBinary.crc32WireBytes(bytes);
}

const TARGET = { workspacePath: 'F:/demo/project', workspaceIdentity: 'ws-key' };

// ---------------------------------------------------------------------------
// 1. 通道层：移植 ChannelClient ↔ 原包 ChannelServer
// ---------------------------------------------------------------------------

test('通道层环回：移植 ChannelClient ↔ 原包 ChannelServer + ProxyChannel', async () => {
  const [endA, endB] = new pProtocol.createQueuePair();
  const service = fakeAgentService();
  const server = new oServer.ChannelServer(endA, 'test');
  server.registerChannel('zcode-agent', oProxy.ProxyChannel.fromService(service));

  const client = new pClient.ChannelClient(endB);
  const stub = new pAgentV4Stub.ZCodeAgentStub(client.getChannel(pAgentV4Stub.ZCODE_AGENT_CHANNEL));

  // call：参数数组约定 + 返回值
  const ack = await stub.subscribeSessionsIndexV4({ ...TARGET, runtimePolicy: 'existing-only' });
  assert.deepEqual(ack, { ack: { subscriptionId: 'sub-si-1', mode: 'snapshot', logEpoch: 'epoch-si-1' } });
  assert.equal(service.workspace.workspacePath, 'F:/demo/project');

  // 动态事件：listen(事件名, target 原样单参)；请求经队列异步到达，先等落地再 fire
  const received = [];
  const d = stub.onDynamicSessionsIndexFrame(TARGET)((wire) => received.push(wire));
  await settle();
  service.fire(completeWire('sessions-index/ws-key', 'sub-si-1', sessionsIndexFrameJson('sub-si-1', 0, 3, []), 1));
  await settle();
  assert.equal(received.length, 1);
  assert.equal(received[0].kind, 'complete');

  // 事件取消后不再接收
  d.dispose();
  await settle();
  service.fire(completeWire('sessions-index/ws-key', 'sub-si-1', sessionsIndexFrameJson('sub-si-1', 0, 4, []), 2));
  await settle();
  assert.equal(received.length, 1);

  // 连接终结 fail-closed：挂起 Promise 请求必须 reject（hangCall 永不 resolve）
  const hangChannel = client.getChannel(pAgentV4Stub.ZCODE_AGENT_CHANNEL);
  const pending = hangChannel.call('hangCall').catch((e) => e);
  await new Promise((r) => setTimeout(r, 10));
  client.dispose();
  const err = await pending;
  assert.equal(err.name, 'ConnectionClosed');
});

// ---------------------------------------------------------------------------
// 2. 持久层：移植 PersistentProtocol ↔ 原包 PersistentProtocol
// ---------------------------------------------------------------------------

test('持久层互操作：A(移植)→B(原包) 收帧，未 ACK 字节记账', async () => {
  const [sockA, sockB] = liveSocketPair();
  const persistentA = new pPersist.PersistentProtocol(sockA);
  const persistentB = new oPersist.PersistentProtocol(sockB);
  try {
    const gotB = [];
    persistentB.onMessage((m) => gotB.push(Buffer.from(m.buffer).toString('utf8')));

    persistentA.send(pBuffer.VSBuffer.fromString('hello-v4'));
    assert.equal(gotB.length, 1);
    assert.equal(gotB[0], 'hello-v4');
    // B 不回发任何帧 → A 的消息保持未确认（ACK 搭载在 B 的出帧/心跳上）
    assert.ok(persistentA.unacknowledgedBytes > 0);
  } finally {
    persistentA.dispose();
    persistentB.dispose();
  }
});

test('持久层重放：replaceSocket 后未确认帧重发（v4 层按 seq 幂等）', async () => {
  const [sockA1, sockB1] = liveSocketPair();
  const persistentA = new pPersist.PersistentProtocol(sockA1);
  const persistentB = new oPersist.PersistentProtocol(sockB1);
  try {
    const gotB = [];
    persistentB.onMessage((m) => gotB.push(Buffer.from(m.buffer).toString('utf8')));
    persistentA.send(pBuffer.VSBuffer.fromString('msg-1'));
    assert.equal(gotB.length, 1);

    // 线路切换：先接好 B 的新 socket，再让 A replaceSocket（重放即时发生）
    const [sockA2, sockB2] = liveSocketPair();
    persistentB.replaceSocket(sockB2);
    const gotB2 = [];
    persistentB.onMessage((m) => gotB2.push(Buffer.from(m.buffer).toString('utf8')));
    persistentA.replaceSocket(sockA2);

    assert.equal(gotB2.length, 1);
    assert.equal(gotB2[0], 'msg-1');
    assert.ok(persistentA.unacknowledgedBytes > 0, '重放后仍未确认（等待新链路上的 ACK）');
  } finally {
    persistentA.dispose();
    persistentB.dispose();
  }
});

// ---------------------------------------------------------------------------
// 3. v4 黄金测试：apply / coalesce 与原包逐语义一致
// ---------------------------------------------------------------------------

test('delta 黄金测试：applyAll(s, coalesce(ds)) 与逐条 apply 一致（双实现互证）', () => {
  const row = (rowId, text, state) => ({
    rowId, turnId: `t-${rowId}`, createdAt: 1, createdAtSeq: rowId,
    kind: 'assistantText', text, state,
  });
  const base = { protocolVersion: 1, revision: 0, rows: { window: [], totalCount: 0, firstRowId: null } };
  const deltas = [
    { op: 'row.appended', row: row(1, '你', 'streaming') },
    { op: 'row.delta', rowId: 1, path: 'text', append: '好' },
    { op: 'row.delta', rowId: 1, path: 'text', append: '，世界' },
    { op: 'row.appended', row: row(2, '', 'streaming') },
    { op: 'row.upserted', row: row(2, 'done', 'complete') },
    { op: 'state.updated', patch: { revision: 5 } },
    { op: 'state.updated', patch: { revision: 6, queue: { state: 'idle', items: [] } } },
    { op: 'row.removed', fromRowId: 2 },
    { op: 'row.appended', row: row(3, '第三条', 'complete') },
  ];

  // 黄金不变量：coalesce 语义保持（移植层）
  const appliedAll = pApply.applyConversationDeltas(base, deltas);
  const appliedCoalesced = pApply.applyConversationDeltas(base, pCoalesce.coalesceConversationDeltas(deltas));
  assert.deepEqual(appliedCoalesced, appliedAll);

  // 双实现互证：原包与移植层结果一致
  const oAll = oApply.applyConversationDeltas(base, deltas);
  const oCoalesced = oApply.applyConversationDeltas(base, oCoalesce.coalesceConversationDeltas(deltas));
  assert.deepEqual(appliedAll, oAll);
  assert.deepEqual(appliedCoalesced, oCoalesced);

  // row.removed 屏障：coalesce 不跨越
  const withBarrier = [
    { op: 'row.appended', row: row(1, 'a', 'streaming') },
    { op: 'row.removed', fromRowId: 1 },
    { op: 'row.delta', rowId: 9, path: 'text', append: 'x' },
    { op: 'row.delta', rowId: 9, path: 'text', append: 'y' },
  ];
  const coalesced = pCoalesce.coalesceConversationDeltas(withBarrier);
  assert.equal(coalesced.length, 3, '屏障后的同 rowId delta 不得被 removed 吞并');
  assert.deepEqual(coalesced, oCoalesce.coalesceConversationDeltas(withBarrier));
});

// ---------------------------------------------------------------------------
// 4. 装配层：分片重组双实现一致 + ordinal 去重
// ---------------------------------------------------------------------------

test('wire 装配：同一组分片喂双实现产出一致；旧 ordinal 迟到被淘汰', () => {
  const frame = sessionsIndexFrameJson('sub-si-1', 0, 2, [
    {
      sessionId: 's-1', workspaceId: 'ws-1', title: '装配测试', phase: 'running',
      sessionEnded: false, hasBackgroundWork: false,
      lastActivityAt: 1, createdAt: 1,
    },
  ]);
  const bytes = new TextEncoder().encode(JSON.stringify(frame));
  const fragSize = Math.ceil(bytes.length / 3);
  const crc = pWireBinary.crc32WireBytes(bytes);
  const fragments = [0, 1, 2].map((i) => ({
    wireVersion: 3,
    kind: 'fragment',
    deliveryKind: 'initial',
    logicalFrameId: 'lf-frag-1',
    logicalFrameOrdinal: 7,
    topic: frame.topic,
    subscriptionId: frame.subscriptionId,
    fragmentIndex: i,
    fragmentCount: 3,
    logicalBytes: bytes.length,
    checksum: { algorithm: 'crc32', value: crc },
    dataBase64: pWireBinary.encodeWireBytesBase64(bytes.slice(i * fragSize, (i + 1) * fragSize)),
  }));

  const a = new pAssembler.TopicWireFrameAssembler(pV4Transport.sessionsIndexTopicFrameSchema);
  const b = new oAssembler.TopicWireFrameAssembler(oTransport.sessionsIndexTopicFrameSchema);
  let pa = null;
  let pb = null;
  for (const frag of fragments) {
    for (const ev of a.accept(frag)) {
      if (ev.kind === 'complete') pa = ev.frame;
    }
    for (const ev of b.accept(frag)) {
      if (ev.kind === 'complete') pb = ev.frame;
    }
  }
  assert.ok(pa && pb, '双实现都应产出逻辑帧');
  assert.deepEqual(pa, pb);
  assert.equal(pa.payload.snapshot.sessions[0].title, '装配测试');
  assert.deepEqual(pa, frame, '重组结果与原始逻辑帧逐字段一致');

  // 迟到旧片（同 ordinal 异 id）→ typed fault；更低 ordinal → 静默淘汰
  const lateBad = { ...fragments[0], logicalFrameId: 'lf-frag-IMPOSTER' };
  const eventsLate = a.accept(lateBad);
  assert.equal(eventsLate.length, 1);
  assert.equal(eventsLate[0].kind, 'fault');
  const olderOrdinal = { ...fragments[0], logicalFrameOrdinal: 6 };
  assert.equal(a.accept(olderOrdinal).length, 0, '更低 ordinal 直接淘汰');
});

// ---------------------------------------------------------------------------
// 5. 端到端：移植 AgentV4Client ↔ 原包 ChannelServer 假 host
// ---------------------------------------------------------------------------

test('端到端：握手版本锁 → 订阅 → 帧装配 → 水位 → resync → 幂等命令', async () => {
  const [endA, endB] = new pProtocol.createQueuePair();
  const service = fakeAgentService();
  const server = new oServer.ChannelServer(endA, 'test');
  server.registerChannel('zcode-agent', oProxy.ProxyChannel.fromService(service));

  // 5.1 握手：clientHello 携带 mobileApp 与协议版本 3
  const client = await pAgentV4Client.AgentV4Client.connect(endB, TARGET, { clientId: randomUUID(), appVersion: '0.1.0' });
  assert.equal(service.helloCount, 1);
  assert.equal(service.initClientHello.kind, 'clientHello');
  assert.equal(service.initClientHello.protocolVersion, 3);
  assert.equal(service.initClientHello.clientKind, 'mobileApp');

  // 5.2 订阅 + complete 帧 → 逻辑帧分发 + 水位记账
  const frames = [];
  client.onFrame((f) => frames.push(f));
  const ack = await client.subscribeSessionsIndex();
  assert.equal(ack.subscriptionId, 'sub-si-1');
  service.fire(completeWire('sessions-index/ws-key', 'sub-si-1', sessionsIndexFrameJson('sub-si-1', 0, 5, []), 1));
  await settle();
  assert.equal(frames.length, 1);
  assert.equal(frames[0].payload.kind, 'snapshot');

  // 5.3 分片帧：装配后进入同一管线
  const bigFrame = sessionsIndexFrameJson('sub-si-1', 5, 9, [
    { sessionId: 's-9', workspaceId: 'ws-1', title: '分片', phase: 'running', sessionEnded: false, hasBackgroundWork: false, lastActivityAt: 2, createdAt: 2 },
  ]);
  const bytes = new TextEncoder().encode(JSON.stringify(bigFrame));
  const fragSize = Math.ceil(bytes.length / 2);
  const crc = pWireBinary.crc32WireBytes(bytes);
  [0, 1].forEach((i) => service.fire({
    wireVersion: 3, kind: 'fragment', deliveryKind: 'online',
    logicalFrameId: 'lf-2', logicalFrameOrdinal: 2,
    topic: bigFrame.topic, subscriptionId: 'sub-si-1',
    fragmentIndex: i, fragmentCount: 2, logicalBytes: bytes.length,
    checksum: { algorithm: 'crc32', value: crc },
    dataBase64: pWireBinary.encodeWireBytesBase64(bytes.slice(i * fragSize, (i + 1) * fragSize)),
  }));
  await settle();
  assert.equal(frames.length, 2);
  assert.equal(frames[1].payload.snapshot.sessions[0].title, '分片');
  assert.deepEqual(client.watermarks(), [
    { topic: 'sessions-index/ws-key', subscriptionId: 'sub-si-1', logEpoch: 'epoch-si-1', lastSeq: 9 },
  ]);

  // 5.4 pre-ACK 缓冲：帧先于 subscribe ACK 到达 → bind 后按序放行
  const serviceB = fakeAgentService();
  const [endA2, endB2] = new pProtocol.createQueuePair();
  const serverB = new oServer.ChannelServer(endA2, 'test');
  serverB.registerChannel('zcode-agent', oProxy.ProxyChannel.fromService(serviceB));
  const clientB = new pClient.ChannelClient(endB2);
  const stubB = new pAgentV4Stub.ZCodeAgentStub(clientB.getChannel(pAgentV4Stub.ZCODE_AGENT_CHANNEL));
  // 直接在 stub 层订阅之前先发一帧（服务端实现里 ACK 前帧可能先行到达）
  serviceB.fire(completeWire('sessions-index/ws-key', 'sub-si-1', sessionsIndexFrameJson('sub-si-1', 0, 2, []), 1));
  const framesB = [];
  const clientB2 = await pAgentV4Client.AgentV4Client.connect(endB2, TARGET, { clientId: randomUUID(), appVersion: '0.1.0' });
  clientB2.onFrame((f) => framesB.push(f));
  await settle(); // EventListen 在服务端落地
  serviceB.fire(completeWire('sessions-index/ws-key', 'sub-si-1', sessionsIndexFrameJson('sub-si-1', 0, 3, []), 2)); // pre-ACK orphan
  await settle();
  await clientB2.subscribeSessionsIndex(); // bind 放行 orphan
  serviceB.fire(completeWire('sessions-index/ws-key', 'sub-si-1', sessionsIndexFrameJson('sub-si-1', 0, 4, []), 3));
  await settle();
  assert.equal(framesB.length, 2, 'connect 后与 ACK 后各收到一帧');
  clientB.dispose();
  clientB2.close();

  // 5.5 resync：带水位续传，服务端收到 base
  const ack2 = await client.resync('sessions-index', 'sub-si-1', { logEpoch: 'epoch-si-1', seq: 9 });
  assert.equal(ack2.mode, 'resume');
  const resyncCall = service.calls.filter((c) => c.method === 'resyncSessionsIndexV4').pop();
  assert.deepEqual(resyncCall.params.base, { logEpoch: 'epoch-si-1', seq: 9 });

  // 5.6 幂等命令：信封通过服务端原包 zod 校验；断线排队 → 逐条 flush
  const queue = new pQueue.PendingCommandQueue();
  const mkEnvelope = (id) => ({
    commandId: id,
    clientId: 'client-test',
    sessionId: 's-1',
    type: 'resolveInteraction',
    payload: { interactionId: `i-${id}`, answer: { optionId: 'allow' } },
    issuedAt: 1_726_000_001_000,
  });
  queue.enqueue(mkEnvelope(randomUUID()));
  queue.enqueue(mkEnvelope(randomUUID()));
  queue.enqueue(mkEnvelope(randomUUID()));
  assert.equal(queue.size, 3);
  queue.enqueue(queue.peekAll()[0].envelope);
  assert.equal(queue.size, 3, '同 commandId 幂等入队');

  const acks = [];
  for (const item of queue.peekAll()) {
    queue.markAttempt(item.envelope.commandId);
    const commandAck = await client.sendCommand(item.envelope);
    queue.settle(item.envelope.commandId);
    acks.push(commandAck);
  }
  assert.equal(acks.length, 3);
  assert.ok(acks.every((a) => a.status === 'accepted' || a.status === 'duplicate'));
  assert.equal(queue.size, 0);
  assert.equal(service.calls.filter((c) => c.method === 'sendConversationCommandV4').length, 3);

  // 5.7 TTL 清理
  const stale = mkEnvelope(randomUUID());
  stale.issuedAt = 0;
  queue.enqueue(stale);
  const expired = queue.dropExpired(1_800_000_000_000);
  assert.equal(expired.length, 1);

  client.close();
});

test('握手版本锁：hello protocolVersion ≠ 3 时 connect fail-fast', async () => {
  const [endA, endB] = new pProtocol.createQueuePair();
  const service = fakeAgentService();
  const staleHello = {
    kind: 'hello',
    protocolVersion: 2,
    connectionId: 'c',
    clientMode: 'web-remote-replayable',
    deliveryProfile: 'replayable',
    serverTime: 1,
    capabilities: { nativeDialogs: false, localTerminal: false, binaryFrames: true, compression: 'none' },
    auth: {},
  };
  const server = new oServer.ChannelServer(endA, 'test');
  server.registerChannel('zcode-agent', oProxy.ProxyChannel.fromService({
    ...service,
    helloConversationV4() {
      return Promise.resolve(staleHello);
    },
  }));
  await assert.rejects(
    () => pAgentV4Client.AgentV4Client.connect(endB, TARGET, { clientId: randomUUID(), appVersion: '0.1.0' }),
    (error) => /expected|literal|invalid_literal/i.test(String(error?.message ?? error)),
    '协议版本不符必须 fail-fast（V4_WIRE_PROTOCOL_VERSION=3 锁）',
  );
});
