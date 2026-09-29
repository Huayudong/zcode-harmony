// WorkbenchModel 投影层一致性门禁（批次7 / A5）。
// 契约锚定：fixture 行/delta/会话摘要先过原 schema（移植子集即事实源），
// 再喂投影模型断言视图形状与归并语义；缓存 JSON 往返必须无损。
// 运行：cd tools/protocol-consistency && node --import tsx --test workbench-model.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';

const V4 = '../../commons/protocol/src/main/ets/v4/index.js';
const workbench = await import(V4.replace('index.js', 'WorkbenchModel.js'));
const rows = await import(V4.replace('index.js', 'rows.js'));
const delta = await import(V4.replace('index.js', 'delta.js'));
const sessionsIndex = await import(V4.replace('index.js', 'sessions-index.js'));
const snapshotMod = await import(V4.replace('index.js', 'snapshot.js'));
const commandMod = await import(V4.replace('index.js', 'command.js'));

// ── fixtures（先过 schema，保证测的是契约形状而非自造形状）──

const summaryA = sessionsIndex.sessionSummarySchema.parse({
  sessionId: 's-a',
  workspaceId: 'ws-1',
  title: '修复登录 bug',
  phase: 'running',
  sessionEnded: false,
  hasBackgroundWork: true,
  pendingInteractionSummary: { permissionCount: 1, userInputCount: 0 },
  lastActivityAt: 1_726_000_010_000,
  createdAt: 1_726_000_000_000,
  lastAssistantPreview: '正在查看 auth 模块…',
});
const summaryB = sessionsIndex.sessionSummarySchema.parse({
  sessionId: 's-b',
  workspaceId: 'ws-1',
  title: '重构数据库层',
  phase: 'completedSuccess',
  sessionEnded: true,
  hasBackgroundWork: false,
  lastActivityAt: 1_726_000_020_000,
  createdAt: 1_726_000_000_000,
});

const rowBase = { turnId: 'turn-1', createdAt: 1_726_000_000_000, createdAtSeq: 1 };
const snapshotRows = [
  rows.conversationRowSchema.parse({ ...rowBase, rowId: 1, kind: 'userInput', text: '帮我看看构建为什么挂了', origin: 'realUser' }),
  rows.conversationRowSchema.parse({ ...rowBase, rowId: 2, kind: 'assistantText', text: '我先检查构建日志', state: 'streaming' }),
  rows.conversationRowSchema.parse({
    ...rowBase, rowId: 3, kind: 'toolCall', toolCallId: 'tc-1', toolName: 'Bash',
    status: 'running', inputText: 'npm run build',
  }),
];
const snapshotPayload = {
  kind: 'snapshot',
  snapshot: {
    rows: { window: snapshotRows, totalCount: 3, firstRowId: 1 },
    meta: { title: '修复登录 bug' },
  },
};
const deltas = [
  delta.conversationDeltaSchema.parse({ op: 'row.delta', rowId: 2, path: 'text', append: '，第 42 行有类型错误' }),
  delta.conversationDeltaSchema.parse({
    op: 'row.appended',
    row: rows.conversationRowSchema.parse({
      ...rowBase, rowId: 4, kind: 'reasoning', text: '错误指向未导入的类型', state: 'complete', durationMs: 1200,
    }),
  }),
  delta.conversationDeltaSchema.parse({
    op: 'row.upserted',
    row: rows.conversationRowSchema.parse({
      ...rowBase, rowId: 3, kind: 'toolCall', toolCallId: 'tc-1', toolName: 'Bash',
      status: 'success', inputText: 'npm run build',
      output: { text: 'BUILD SUCCESSFUL' },
    }),
  }),
  delta.conversationDeltaSchema.parse({ op: 'state.updated', patch: { meta: { title: '新标题', titleSource: 'generated' } } }),
  // 正文流收口（同 rowId 原位整行替换）
  delta.conversationDeltaSchema.parse({
    op: 'row.upserted',
    row: rows.conversationRowSchema.parse({
      ...rowBase, rowId: 2, kind: 'assistantText',
      text: '我先检查构建日志，第 42 行有类型错误', state: 'complete',
    }),
  }),
];

// ── 1. sessions-index：snapshot → 排序列表 → delta 增删 → 缓存往返 ──
test('sessions-index 投影：snapshot 排序、delta 增删、JSON 往返', () => {
  const model = new workbench.SessionsIndexModel();
  assert.equal(model.applyFrame({ payload: { kind: 'snapshot', snapshot: { sessions: [summaryA, summaryB] } } }), true);
  assert.equal(model.size(), 2);
  // 按最近活跃降序：s-b(020s) 在 s-a(010s) 前
  assert.deepEqual(model.list().map((s) => s.sessionId), ['s-b', 's-a']);
  const a = model.summaryOf('s-a');
  assert.equal(a.title, '修复登录 bug');
  assert.equal(a.phase, 'running');
  assert.equal(a.pendingInteractionCount, 1);
  assert.equal(a.hasBackgroundWork, true);
  assert.equal(a.lastAssistantPreview, '正在查看 auth 模块…');

  // delta：upsert 更新 s-a 活跃时间 → 排序翻转；remove 删除 s-b
  const updated = sessionsIndex.sessionSummarySchema.parse({ ...summaryA, lastActivityAt: 1_726_000_030_000 });
  assert.equal(model.applyFrame({
    payload: {
      kind: 'deltas',
      deltas: [
        { op: 'session.upserted', session: updated },
        { op: 'session.removed', sessionId: 's-b' },
      ],
    },
  }), true);
  assert.deepEqual(model.list().map((s) => s.sessionId), ['s-a']);
  assert.equal(model.summaryOf('s-b'), null);

  // JSON 往返无损
  const restored = workbench.SessionsIndexModel.parse(model.toJSON());
  assert.deepEqual(restored.list(), model.list());
});

// ── 2. conversation：snapshot → 行视图 → deltas 归并（复用 apply 语义）──
test('conversation 投影：行视图、delta 归并、state.updated、hasLiveWork', () => {
  const model = new workbench.ConversationModel('s-1');
  assert.equal(model.applyFrame({ payload: snapshotPayload }), true);
  const rowsView = model.rows();
  assert.equal(rowsView.length, 3);
  assert.equal(rowsView[0].kind, 'userInput');
  assert.equal(rowsView[0].text, '帮我看看构建为什么挂了');
  assert.equal(rowsView[1].state, 'streaming');
  assert.equal(rowsView[2].toolName, 'Bash');
  assert.equal(rowsView[2].state, 'running');
  assert.equal(model.title(), '修复登录 bug');
  assert.equal(model.hasLiveWork(), true);

  assert.equal(model.applyFrame({ payload: { kind: 'deltas', deltas } }), true);
  const after = model.rows();
  assert.equal(after.length, 4);
  // row.delta 追加进 assistantText 正文
  assert.equal(after[1].text, '我先检查构建日志，第 42 行有类型错误');
  // row.upserted 整行替换（原位）：toolCall 终态 + 输出文本
  assert.equal(after[2].state, 'success');
  assert.equal(after[2].outputText, 'BUILD SUCCESSFUL');
  // row.appended 追加 reasoning 行（durationMs 提取）
  assert.equal(after[3].kind, 'reasoning');
  assert.equal(after[3].durationMs, 1200);
  // state.updated：A 区键级整体替换
  assert.equal(model.title(), '新标题');
  // 无流式工作（正文 complete、工具 success、reasoning complete）
  assert.equal(model.hasLiveWork(), false);
});

// ── 3. 对话缓存往返 + 空帧/坏帧防御 ──
test('conversation 缓存往返与防御', () => {
  const model = new workbench.ConversationModel('s-1');
  model.applyFrame({ payload: snapshotPayload });
  model.applyFrame({ payload: { kind: 'deltas', deltas } });

  const restored = workbench.ConversationModel.parse(model.toJSON());
  assert.notEqual(restored, null);
  assert.equal(restored.sessionId, 's-1');
  assert.deepEqual(restored.rows(), model.rows());
  assert.equal(restored.title(), model.title());

  // 坏 JSON / 缺快照 → null，不抛
  assert.equal(workbench.ConversationModel.parse('not-json'), null);
  assert.equal(workbench.ConversationModel.parse('{"sessionId":"s-1"}'), null);
  // 未知 payload kind 与 deltas 空数组：无变化、不抛
  assert.equal(model.applyFrame({ payload: { kind: 'unknown' } }), false);
  assert.equal(model.applyFrame({ payload: { kind: 'deltas', deltas: [] } }), false);
  // 快照未就绪时 deltas 帧 no-op
  const cold = new workbench.ConversationModel('s-2');
  assert.equal(cold.applyFrame({ payload: { kind: 'deltas', deltas } }), false);
  assert.equal(cold.rows().length, 0);
});

// ── 4. 批准链路（批次8 / OUT-3/4）：pendingInteractions 投影 + resolveInteraction 信封 ──

const pendingPermission = snapshotMod.pendingInteractionSchema.parse({
  interactionId: 'i-1',
  kind: 'permission',
  anchorRowId: 3,
  createdAt: 1_726_000_000_000,
  payload: {
    kind: 'permission',
    toolCallId: 'tc-1',
    toolName: 'Bash',
    summary: '运行 npm test',
    detail: null,
    options: [
      { optionId: 'allow_once', label: '允许一次', kind: 'allowOnce' },
      { optionId: 'deny', label: '拒绝', kind: 'deny' },
    ],
  },
});
const pendingAsk = snapshotMod.pendingInteractionSchema.parse({
  interactionId: 'i-2',
  kind: 'userInput',
  anchorRowId: null,
  createdAt: 1_726_000_000_000,
  payload: {
    kind: 'userInput',
    prompt: '选择协作模式',
    freeText: false,
    options: [{ optionId: 'plan', label: 'Plan 模式' }],
  },
});
const pendingQuestion = snapshotMod.pendingInteractionSchema.parse({
  interactionId: 'i-3',
  kind: 'userInput',
  anchorRowId: null,
  createdAt: 1_726_000_000_000,
  payload: {
    kind: 'userInput',
    prompt: '请确认执行方式',
    freeText: true,
    sensitive: true,
    questions: [
      { question: '使用哪个模型？', header: '模型', options: [{ value: 'glm', label: 'GLM' }] },
    ],
    currentQuestionIndex: 0,
  },
});

test('批准链路：pendingInteractions 投影、state.updated 坍缩、resolveInteraction 信封', () => {
  const model = new workbench.ConversationModel('s-1');
  model.applyFrame({
    payload: {
      kind: 'snapshot',
      snapshot: { rows: { window: [], totalCount: 0, firstRowId: null }, pendingInteractions: [pendingPermission, pendingAsk, pendingQuestion] },
    },
  });

  const pending = model.pendingInteractions();
  assert.equal(pending.length, 3);
  // permission：summary + 工具名 + 服务端选项词表
  assert.equal(pending[0].kind, 'permission');
  assert.equal(pending[0].toolName, 'Bash');
  assert.equal(pending[0].title, '运行 npm test');
  assert.deepEqual(pending[0].options, [
    { optionId: 'allow_once', label: '允许一次', kind: 'allowOnce' },
    { optionId: 'deny', label: '拒绝', kind: 'deny' },
  ]);
  // userInput 单问题：prompt + 顶层 options
  assert.equal(pending[1].kind, 'userInput');
  assert.equal(pending[1].title, '选择协作模式');
  assert.deepEqual(pending[1].options, [{ optionId: 'plan', label: 'Plan 模式', kind: '' }]);
  // AskUserQuestion 多问题：取当前问题与其选项；freeText/sensitive 透出
  assert.equal(pending[2].title, '使用哪个模型？');
  assert.deepEqual(pending[2].options, [{ optionId: 'glm', label: 'GLM', kind: '' }]);
  assert.equal(pending[2].freeText, true);
  assert.equal(pending[2].sensitive, true);

  // state.updated{pendingInteractions:[]} → 卡片坍缩（键级整体替换）
  model.applyFrame({
    payload: {
      kind: 'deltas',
      deltas: [delta.conversationDeltaSchema.parse({ op: 'state.updated', patch: { pendingInteractions: [] } })],
    },
  });
  assert.equal(model.pendingInteractions().length, 0);

  // resolveInteraction 信封：optionId / freeText 两种应答都过原 schema；缺 answer 拒绝
  const base = { commandId: 'cmd-1', clientId: 'client-1', sessionId: 's-1', type: 'resolveInteraction', issuedAt: 1_726_000_000_000 };
  assert.equal(commandMod.parseCommandEnvelope({
    ...base,
    payload: { interactionId: 'i-1', answer: { optionId: 'allow_once' } },
  }).ok, true);
  assert.equal(commandMod.parseCommandEnvelope({
    ...base,
    commandId: 'cmd-2',
    payload: { interactionId: 'i-3', answer: { freeText: '自定义答复' } },
  }).ok, true);
  assert.equal(commandMod.parseCommandEnvelope({
    ...base,
    commandId: 'cmd-3',
    payload: { interactionId: 'i-1' },
  }).ok, false);
});
