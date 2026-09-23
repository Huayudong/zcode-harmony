// v4 schema 子集移植冒烟：导入闭环 + 关键 schema 解析（批次6）。
// 运行：cd tools/protocol-consistency && npx tsx v4-smoke.test.mjs
import assert from 'node:assert/strict';

const V4 = '../../commons/protocol/src/main/ets/v4/index.js';

// 冒烟 1：核心常量与版本锁
const core = await import(V4.replace('index.js', 'core.js'));
assert.equal(core.V4_WIRE_PROTOCOL_VERSION, 3);
assert.equal(core.PROTOCOL_V4_LIMITS.attachmentChunkMaxBytes, 512 * 1024);
console.log('smoke 1 core constants OK');

// 冒烟 2：hello / clientHello（transport 子集）
const transport = await import(V4.replace('index.js', 'transport.js'));
const hello = {
  kind: 'hello',
  protocolVersion: 3,
  connectionId: 'conn-1',
  clientMode: 'web-remote-replayable',
  deliveryProfile: 'replayable',
  serverTime: 1_726_000_000_000,
  capabilities: {
    nativeDialogs: false,
    localTerminal: false,
    binaryFrames: true,
    compression: 'none',
  },
  auth: {},
};
const helloParsed = transport.helloMessageSchema.parse(hello);
assert.equal(helloParsed.kind, 'hello');
// 版本 fail-fast：协议版本不是 3 必须抛错
assert.throws(() =>
  transport.helloMessageSchema.parse({ ...hello, protocolVersion: 2 }),
);
console.log('smoke 2 hello/clientHello OK');

// 冒烟 3：subscribe/ack + 帧 envelope（wire 完整帧）
const wire = await import(V4.replace('index.js', 'wire.js'));
const transportMod = await import(V4.replace('index.js', 'transport.js'));
const sessionsIndex = await import(V4.replace('index.js', 'sessions-index.js'));
const frame = {
  topic: 'sessions-index/ws-1',
  subscriptionId: 'sub-1',
  fromSeq: 0,
  toSeq: 5,
  sentAt: 1_726_000_000_000,
  payload: {
    kind: 'snapshot',
    snapshot: {
      protocolVersion: 1,
      workspaceId: 'ws-1',
      logEpoch: 'epoch-1',
      sessions: [
        {
          sessionId: 's-1',
          workspaceId: 'ws-1',
          title: '示例会话',
          phase: 'running',
          sessionEnded: false,
          hasBackgroundWork: false,
          lastActivityAt: 1_726_000_000_000,
          createdAt: 1_726_000_000_000,
        },
      ],
    },
  },
};
const complete = {
  wireVersion: 3,
  kind: 'complete',
  deliveryKind: 'initial',
  logicalFrameId: 'lf-1',
  logicalFrameOrdinal: 1,
  topic: frame.topic,
  subscriptionId: frame.subscriptionId,
  frame,
};
const parsedFrame = wire.createTopicWireFrameSchema(transportMod.sessionsIndexTopicFrameSchema).parse(complete);
assert.equal(parsedFrame.kind, 'complete');
assert.equal(parsedFrame.frame.payload.snapshot.sessions[0].title, '示例会话');
console.log('smoke 3 wire frame + sessions-index OK');

// 冒烟 4：conversation 行 + delta + apply/coalesce
const rows = await import(V4.replace('index.js', 'rows.js'));
const row = {
  rowId: 1,
  turnId: 't-1',
  createdAt: 1,
  createdAtSeq: 1,
  kind: 'userInput',
  text: '你好',
  origin: 'realUser',
};
assert.equal(rows.conversationRowSchema.parse(row).kind, 'userInput');
const apply = await import(V4.replace('index.js', 'apply.js'));
const coalesce = await import(V4.replace('index.js', 'coalesce.js'));
const snapshot0 = {
  protocolVersion: 1,
  revision: 0,
  rows: { window: [], totalCount: 0, firstRowId: null },
};
const deltas = [
  { op: 'row.appended', row },
  { op: 'row.appended', row: { ...row, rowId: 2, text: '第二条' } },
  { op: 'row.removed', fromRowId: 2 },
];
const a = apply.applyConversationDeltas(snapshot0, deltas);
const b = apply.applyConversationDeltas(snapshot0, coalesce.coalesceConversationDeltas(deltas));
assert.deepEqual(a, b);
console.log('smoke 4 rows/apply/coalesce OK');

// 冒烟 5：command envelope（resolveInteraction 幂等面）
const commandMod = await import(V4.replace('index.js', 'command.js'));
assert.ok(commandMod.commandEnvelopeSchema, 'commandEnvelopeSchema 应导出');
console.log('smoke 5 command schema OK');

console.log('v4 smoke: all OK');
