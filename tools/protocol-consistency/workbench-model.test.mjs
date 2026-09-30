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
const transportMod = await import(V4.replace('index.js', 'transport.js'));

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

// ── 5. 输入区模式（批次9 / INP-6）：sendText 按次提交 mode 信封 ──
test('sendText.mode 信封：build/plan 与缺省过 schema，词表外拒绝', () => {
  const base = { commandId: 'cmd-m1', clientId: 'client-1', sessionId: 's-1', type: 'sendText', issuedAt: 1_726_000_000_000 };
  assert.equal(commandMod.parseCommandEnvelope({ ...base, payload: { text: '你好', mode: 'build' } }).ok, true);
  assert.equal(commandMod.parseCommandEnvelope({ ...base, commandId: 'cmd-m2', payload: { text: '你好', mode: 'plan' } }).ok, true);
  // 缺 mode = 跟随服务端会话当前模式
  assert.equal(commandMod.parseCommandEnvelope({ ...base, commandId: 'cmd-m3', payload: { text: '你好' } }).ok, true);
  // 词表外（"问答"档尚未映射，Q3 开放中）必须拒绝
  assert.equal(commandMod.parseCommandEnvelope({ ...base, commandId: 'cmd-m4', payload: { text: '你好', mode: 'ask' } }).ok, false);
});

// ── 6. 变更 Tab（批次10 / OUT-5）：fileChanges 报告投影 + turnHeader 聚合 ──
test('fileChanges 投影与 turnHeader 聚合、快照水位取值', () => {
  // 报告 fixture 先过移植的 result schema
  const result = transportMod.v4ConversationFileChangesResultSchema.parse({
    files: 2,
    additions: 12,
    deletions: 3,
    state: 'active',
    items: [
      {
        path: 'src/app.ts',
        additions: 9,
        deletions: 1,
        writeCount: 2,
        toolNames: ['Edit'],
        patches: [
          { oldStart: 1, oldLines: 3, newStart: 1, newLines: 4, lines: [' context', '-old', '+new1', '+new2'] },
        ],
      },
      {
        path: 'README.md',
        additions: 3,
        deletions: 2,
        writeCount: 1,
        toolNames: ['Write', 'Edit'],
        patches: [],
      },
    ],
  });
  const view = workbench.parseFileChangesResult(result);
  assert.equal(view.files, 2);
  assert.equal(view.additions, 12);
  assert.equal(view.deletions, 3);
  assert.equal(view.state, 'active');
  assert.equal(view.items.length, 2);
  assert.equal(view.items[0].path, 'src/app.ts');
  assert.equal(view.items[0].hunks.length, 1);
  assert.equal(view.items[0].hunks[0].lines.length, 4);
  assert.equal(view.items[0].hunks[0].lines[1], '-old');
  assert.equal(view.items[1].toolNames, 'Write · Edit');
  assert.equal(view.items[1].hunks.length, 0);

  // turnHeader 聚合与 entityId 进 RowView；快照水位/纪元可取（fileChanges 查询参数）
  const turnRow = rows.conversationRowSchema.parse({
    ...rowBase,
    rowId: 10,
    kind: 'turnHeader',
    entityId: 'turn-ent-1',
    origin: 'userInput',
    state: 'completedSuccess',
    startedAt: 1_726_000_000_000,
    fileChanges: { additions: 12, deletions: 3, files: 2 },
  });
  const model = new workbench.ConversationModel('s-1');
  model.applyFrame({
    payload: {
      kind: 'snapshot',
      snapshot: {
        rows: { window: [turnRow], totalCount: 1, firstRowId: 10 },
        logEpoch: 'epoch-1',
        revision: 7,
      },
    },
  });
  const rowView = model.rows()[0];
  assert.equal(rowView.entityId, 'turn-ent-1');
  assert.equal(rowView.fileCount, 2);
  assert.equal(rowView.fileAdditions, 12);
  assert.equal(rowView.fileDeletions, 3);
  assert.equal(model.revision(), 7);
  assert.equal(model.logEpoch(), 'epoch-1');
});

// ── 7. 会话管理命令（批次19 / M1 抽屉「新建按钮」+ OUT-7 原生重试）──
test('createSession/deleteSession/retryTurn 信封：合法载荷过 schema', () => {
  const FENCE = '```';
  const mk = (commandId, type, payload, sessionId) => ({
    commandId, clientId: 'client-1', sessionId, type, payload, issuedAt: 1_726_000_000_000,
  });
  // createSession：全局命令（sessionId=null）+ workspaceId 载荷
  const r1 = commandMod.parseCommandEnvelope(mk('cmd-n1', 'createSession', { workspaceId: 'ws-1' }, null));
  assert.equal(r1.ok, true);
  // 缺 workspaceId 拒绝
  const r1b = commandMod.parseCommandEnvelope(mk('cmd-n1b', 'createSession', {}, null));
  assert.equal(r1b.ok, false);
  // deleteSession：会话级空载荷
  const r2 = commandMod.parseCommandEnvelope(mk('cmd-n2', 'deleteSession', {}, 's-1'));
  assert.equal(r2.ok, true);
  // retryTurn：行定位命令走 CAS——信封必须带 baseRevision+baseLogEpoch，载荷 target 成对
  const mkCas = (commandId, payload) => ({
    ...mk(commandId, 'retryTurn', payload, 's-1'), baseRevision: 7, baseLogEpoch: 'epoch-1',
  });
  const r3 = commandMod.parseCommandEnvelope(mkCas('cmd-n3', { target: { rowId: 5, entityId: 'e-5' } }));
  assert.equal(r3.ok, true);
  // 缺 CAS 字段 → 拒绝（服务端防过期重试）
  const r3cas = commandMod.parseCommandEnvelope(mk('cmd-n3c', 'retryTurn', { target: { rowId: 5, entityId: 'e-5' } }, 's-1'));
  assert.equal(r3cas.ok, false);
  // target 字段不完整 → 拒绝
  const r3b = commandMod.parseCommandEnvelope(mkCas('cmd-n3b', { target: { rowId: 5 } }));
  assert.equal(r3b.ok, false);
  void FENCE;
});
