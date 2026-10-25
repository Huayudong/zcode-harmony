// 批次21 门禁：审批内容派生（approvalPreview 桌面级移植）+ workspace-config 目录 +
// 会话配置投影 + 用量权益投影 + 模式/模型切换信封。
// 契约锚定：fixture 先过移植 schema（事实源 = 上游 zcode-protocol-v4），再喂投影断言。
// 运行：cd tools/protocol-consistency && node --import tsx --test batch21-config-usage.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';

const V4 = '../../commons/protocol/src/main/ets/v4/';
const workbench = await import(V4 + 'WorkbenchModel.js');
const approval = await import(V4 + 'approvalPreview.js');
const usage = await import(V4 + 'usageEntitlement.js');
const commandMod = await import(V4 + 'command.js');
const transportMod = await import(V4 + 'transport.js');
const snapshotMod = await import(V4 + 'snapshot.js');
const wc = await import(V4 + 'workspace-config.js');

// ── 1. 审批内容派生（桌面 PermissionDialog 的 App 侧面）──

test('审批派生：execute 命令拼接/通用文案过滤/文件路径收集', () => {
  const bash = approval.deriveApprovalContent('Bash', 'High risk tools require explicit approval',
    { command: 'git', args: ['push', '--force'], description: '推送提交到远端' }, null);
  assert.equal(bash.blockKind, 'execute');
  assert.equal(bash.command, 'git push --force');
  assert.equal(bash.displayReason, '推送提交到远端');

  // 通用策略文案必须被过滤：detail 无用户可读原因时回退 summary，summary 也是通用文案 → 空
  const generic = approval.deriveApprovalContent('Bash', 'Tool has side effects and requires approval',
    { command: 'ls' }, null);
  assert.equal(generic.displayReason, '');
  assert.equal(generic.command, 'ls');

  // 文件路径：FILE_PATH_KEYS 命中（path/file/target…），cwd/directory 忽略
  const files = approval.deriveApprovalContent('Read', '读取文件',
    { path: 'src/a.ts', file: 'src/a.ts', cwd: '/repo', directory: '/repo', target: 'src/b.ts' }, null);
  assert.deepEqual(files.filePaths, ['src/a.ts', 'src/b.ts']);
});

test('审批派生：edit changes / mcp 标识拆分 / search 摘要', () => {
  const edit = approval.deriveApprovalContent('Edit', '编辑文件',
    { changes: { 'a.ts': { type: 'update' }, 'b.ts': { type: 'add' }, 'c.ts': { type: 'delete' } } }, null);
  assert.equal(edit.blockKind, 'edit');
  assert.deepEqual(edit.fileChanges, [
    { path: 'a.ts', type: 'update' },
    { path: 'b.ts', type: 'add' },
  ]);

  const mcp = approval.deriveApprovalContent('mcp__github__create_issue', '调用 MCP 工具', { owner: 'x' }, null);
  assert.equal(mcp.blockKind, 'mcp');
  assert.equal(mcp.mcpServerName, 'github');
  assert.equal(mcp.mcpToolName, 'create_issue');
  // display 投影优先（toolCallDisplay serverName/toolName）
  const mcpDisplay = approval.deriveApprovalContent('mcp__github__create_issue', '调用 MCP 工具', {},
    { serverName: 'gh', toolName: 'issue' });
  assert.equal(mcpDisplay.mcpServerName, 'gh');
  assert.equal(mcpDisplay.mcpToolName, 'issue');

  const search = approval.deriveApprovalContent('WebFetch', '抓取网页', { url: 'https://example.com', query: 'zcode' }, null);
  assert.equal(search.blockKind, 'search');
  assert.equal(search.searchUrl, 'https://example.com');
  assert.equal(search.searchQuery, 'zcode');
});

test('审批选项：排序优先级/中文 label/描述行/bash 前缀 scope', () => {
  assert.equal(approval.approvalOptionPriority('allow_once', 'allowOnce'), 0);
  assert.equal(approval.approvalOptionPriority('x', 'allowAlways'), 1);
  assert.equal(approval.approvalOptionPriority('fullAccess', 'custom'), 1.5);
  assert.equal(approval.approvalOptionPriority('deny', 'deny'), 2);
  // fullAccess 排在 allowAlways 之后、deny 之前
  assert.ok(approval.approvalOptionPriority('x', 'allowAlways') < approval.approvalOptionPriority('fullAccess', 'custom'));
  assert.ok(approval.approvalOptionPriority('fullAccess', 'custom') < approval.approvalOptionPriority('deny', 'deny'));

  assert.equal(approval.approvalOptionLabel('allow_once', 'allowOnce', 'Allow once'), '允许');
  assert.equal(approval.approvalOptionLabel('allow_project', 'allowAlways', 'x'), '始终允许本项目');
  assert.equal(approval.approvalOptionLabel('fullAccess', 'custom', 'x'), '完全访问');
  assert.equal(approval.approvalOptionLabel('deny', 'deny', 'Deny'), '拒绝');
  assert.equal(approval.approvalOptionLabel('unknown-id', 'weird', '服务端文案'), '服务端文案');

  assert.equal(approval.approvalOptionDescription('allow_once', 'allowOnce', ''), '仅允许这一次');
  assert.equal(approval.approvalOptionDescription('allowSession', 'allowAlways', ''), '本会话内不再询问');
  assert.equal(approval.approvalOptionDescription('x', 'allowAlways', 'command'), '后续相同命令不再询问');
  assert.equal(approval.approvalOptionDescription('deny', 'deny', ''), '这次先拒绝');

  // scope：addRules(allow) + bash + "prefix:*" 规则 → 去后缀取前缀
  const scopes = approval.approvalOptionScopes({
    permissionUpdates: [{
      type: 'addRules',
      behavior: 'allow',
      rules: [
        { toolName: 'bash', ruleContent: 'git push:*' },
        { toolName: 'bash', ruleContent: 'npm test:*' },
        { toolName: 'bash', ruleContent: 'no-suffix' },
        { toolName: 'Read', ruleContent: 'x:*' },
      ],
    }],
  });
  assert.deepEqual(scopes, ['git push', 'npm test']);
  assert.deepEqual(approval.approvalOptionScopes(null), []);
});

// ── 2. pendingInteractions 批次21 面（origin 在 payload / fullAccess 排序 / autoResolution / questions）──

const originFixture = {
  kind: 'subagent', agentId: 'a-1', agentType: 'general',
  childSessionId: 'cs-1', parentSessionId: 's-1',
};

test('pendingInteractions：permission 的 origin/fullAccess/派生内容/排序', () => {
  const pending = snapshotMod.pendingInteractionSchema.parse({
    interactionId: 'i-21',
    kind: 'permission',
    anchorRowId: 3,
    createdAt: 1_726_000_000_000,
    autoResolution: {
      state: 'visibleCountdown',
      startedAt: 1_726_000_000_500,
      visibleAt: 1_726_000_001_000,
      deadlineAt: 1_726_000_060_000,
    },
    payload: {
      kind: 'permission',
      toolCallId: 'tc-9',
      toolName: 'Bash',
      summary: 'High risk tools require explicit approval',
      detail: { command: 'git', args: ['status'], reason: '查看仓库状态' },
      origin: originFixture,
      fullAccessOption: { optionId: 'fullAccess', label: 'Full access', kind: 'custom' },
      options: [
        { optionId: 'deny', label: '拒绝', kind: 'deny' },
        { optionId: 'allow_session', label: '允许本会话', kind: 'allowAlways', response: { decision: 'allow', permissionUpdates: [{ type: 'addRules', behavior: 'allow', rules: [{ toolName: 'bash', ruleContent: 'git status:*' }] }] } },
        { optionId: 'allow_once', label: '允许一次', kind: 'allowOnce' },
      ],
    },
  });
  const model = new workbench.ConversationModel('s-1');
  model.applyFrame({
    payload: {
      kind: 'snapshot',
      snapshot: { rows: { window: [], totalCount: 0, firstRowId: null }, pendingInteractions: [pending] },
    },
  });
  const view = model.pendingInteractions()[0];
  // origin 从 payload 投影
  assert.equal(view.originKind, 'subagent');
  assert.equal(view.originAgentType, 'general');
  assert.equal(view.anchorRowId, 3);
  // autoResolution 透出
  assert.equal(view.autoState, 'visibleCountdown');
  assert.equal(view.autoDeadlineAt, 1_726_000_060_000);
  // 桌面排序：allowOnce → allowAlways → fullAccess(1.5) → deny
  assert.deepEqual(view.options.map((o) => o.optionId), ['allow_once', 'allow_session', 'fullAccess', 'deny']);
  // allowAlways 的 bash 前缀 scope 投影
  const allowSession = view.options.find((o) => o.optionId === 'allow_session');
  assert.deepEqual(allowSession.scopes, ['git status']);
  // 内容派生：blockKind execute + command 拼接 + reason 过滤后透出
  assert.equal(view.approval.blockKind, 'execute');
  assert.equal(view.approval.command, 'git status');
  assert.equal(view.approval.displayReason, '查看仓库状态');
});

test('pendingInteractions：AskUserQuestion 多问题进度投影', () => {
  const pending = snapshotMod.pendingInteractionSchema.parse({
    interactionId: 'i-22',
    kind: 'userInput',
    anchorRowId: null,
    createdAt: 1_726_000_000_000,
    payload: {
      kind: 'userInput',
      prompt: '请确认',
      freeText: false,
      questions: [
        { question: '第一题？', header: '风格', options: [{ value: 'a', label: 'A', description: '选项说明' }] },
        { question: '第二题？', header: '范围', multiSelect: true, options: [{ value: 'b', label: 'B' }] },
      ],
      currentQuestionIndex: 1,
    },
  });
  const model = new workbench.ConversationModel('s-2');
  model.applyFrame({
    payload: {
      kind: 'snapshot',
      snapshot: { rows: { window: [], totalCount: 0, firstRowId: null }, pendingInteractions: [pending] },
    },
  });
  const view = model.pendingInteractions()[0];
  assert.equal(view.title, '第二题？');
  assert.equal(view.questionIndex, 1);
  assert.equal(view.questionCount, 2);
  assert.equal(view.questionHeader, '范围');
  assert.equal(view.multiSelect, true);
  // userInput 选项：optionId 回退 value，description 透出
  assert.deepEqual(view.options, [{ optionId: 'b', label: 'B', kind: '', scopes: [], description: '' }]);
});

// ── 3. workspace-config 目录（快照嵌套回归 + delta 整体替换）──

test('workspace-config：快照 configOptions 嵌套在 config 下（回归：曾直接读快照根导致空目录）', () => {
  const snapshotBody = wc.workspaceConfigSnapshotSchema.parse({
    protocolVersion: 1,
    workspaceId: 'ws-1',
    logEpoch: 'wc-e1',
    config: {
      configOptions: [
        {
          id: 'model', name: '模型', type: 'select', currentValue: 'glm-4.7',
          options: [
            {
              value: 'glm-4.7', name: 'GLM-4.7',
              modelProviderId: 'bigmodel', modelProviderName: '智谱',
              modelThoughtLevels: ['low', 'high'], modelDefaultThoughtLevel: 'high',
            },
            { value: 'glm-air', name: 'GLM-Air', modelProviderId: 'bigmodel', modelProviderName: '智谱' },
          ],
        },
        { id: 'mode', name: '模式', type: 'select', currentValue: 'build', options: [] },
      ],
      slashCommands: [],
    },
  });
  // wire 帧也过 topic schema（topic 前缀 + 订阅五件套）
  const wireFrame = transportMod.workspaceConfigTopicFrameSchema.parse({
    topic: 'workspace-config/ws-1',
    subscriptionId: 'sub-wc-1',
    fromSeq: 0,
    toSeq: 0,
    sentAt: 1_726_000_000_000,
    payload: { kind: 'snapshot', snapshot: snapshotBody },
  });
  const model = new workbench.WorkspaceConfigModel();
  assert.equal(model.applyFrame(wireFrame), true);
  assert.equal(model.workspaceId(), 'ws-1');
  assert.equal(model.options().length, 2);
  const modelOption = model.optionOf('model');
  assert.equal(modelOption.currentValue, 'glm-4.7');
  assert.equal(modelOption.values.length, 2);
  assert.deepEqual(modelOption.values[0].thoughtLevels, ['low', 'high']);
  assert.equal(modelOption.values[0].defaultThoughtLevel, 'high');
  assert.equal(modelOption.values[0].providerName, '智谱');
  assert.equal(model.optionOf('nope'), null);

  // delta（config.updated）整体替换目录
  const deltaChanged = model.applyFrame({
    payload: {
      kind: 'deltas',
      deltas: [wc.workspaceConfigDeltaSchema.parse({
        op: 'config.updated',
        config: { configOptions: [{ id: 'mode', name: '模式', type: 'select', currentValue: 'plan', options: [] }], slashCommands: [] },
      })],
    },
  });
  assert.equal(deltaChanged, true);
  assert.equal(model.options().length, 1);
  assert.equal(model.optionOf('mode').currentValue, 'plan');
  assert.equal(model.optionOf('model'), null);
});

// ── 4. 会话配置投影（conversation snapshot.config → SessionConfigView）──

test('会话配置：provider/model/thought/mode/thoughtLevels 投影与缺省', () => {
  const configState = snapshotMod.sessionConfigStateSchema.parse({
    provider: 'bigmodel',
    model: 'glm-4.7',
    thought: 'high',
    thoughtLevels: ['low', 'high'],
    followupMode: 'queue',
    mode: 'plan',
    planEnabled: true,
  });
  const model = new workbench.ConversationModel('s-3');
  model.applyFrame({
    payload: {
      kind: 'snapshot',
      snapshot: {
        rows: { window: [], totalCount: 0, firstRowId: null },
        meta: { title: '', titleSource: 'default' },
        config: configState,
      },
    },
  });
  const config = model.sessionConfig();
  assert.notEqual(config, null);
  assert.equal(config.provider, 'bigmodel');
  assert.equal(config.model, 'glm-4.7');
  assert.equal(config.thought, 'high');
  assert.deepEqual(config.thoughtLevels, ['low', 'high']);
  assert.equal(config.mode, 'plan');
  assert.equal(config.planEnabled, true);
  assert.equal(config.followupMode, 'queue');

  // 旧形状（无 config 键）→ null；mode/thoughtLevels 缺省的 config → build/[]
  const legacy = new workbench.ConversationModel('s-4');
  legacy.applyFrame({
    payload: { kind: 'snapshot', snapshot: { rows: { window: [], totalCount: 0, firstRowId: null } } },
  });
  assert.equal(legacy.sessionConfig(), null);
  const oldConfig = snapshotMod.sessionConfigStateSchema.parse({
    provider: 'p', model: 'm', thought: '', followupMode: 'queue',
  });
  const older = new workbench.ConversationModel('s-5');
  older.applyFrame({
    payload: { kind: 'snapshot', snapshot: { rows: { window: [], totalCount: 0, firstRowId: null }, config: oldConfig } },
  });
  assert.equal(older.sessionConfig().mode, 'build');
  assert.deepEqual(older.sessionConfig().thoughtLevels, []);
});

// ── 5. 用量权益投影（usage-stats 通道原始返回 → 视图）──

test('用量投影：remaining/quota/subscription/context 全量向量', () => {
  const view = usage.parseEntitlementSnapshot({
    authenticated: true,
    unavailableReason: '',
    context: { displayName: '个人版', scope: 'personal' },
    provider: { name: '智谱' },
    remaining: { count: 42, percentage: 65, nextResetTime: 1_726_003_600_000 },
    subscription: { identityMasked: 'us***@example.com' },
    quota: {
      limits: [
        { type: '5h', percentage: 35, remaining: 65, nextResetTime: 1_726_003_600_000, period: 'daily' },
        { type: 'weekly', percentage: 90, remaining: 10, period: 'weekly' },
      ],
    },
  });
  assert.equal(view.authenticated, true);
  assert.equal(view.contextName, '个人版');
  assert.equal(view.providerName, '智谱');
  assert.equal(view.remainingCount, 42);
  assert.equal(view.remainingPercentage, 65);
  assert.equal(view.nextResetTime, 1_726_003_600_000);
  assert.equal(view.identityMasked, 'us***@example.com');
  assert.equal(view.limits.length, 2);
  // 口径：percentage 是已使用占比
  assert.equal(view.limits[0].percentage, 35);
  assert.equal(view.limits[1].remaining, 10);
  assert.equal(view.limits[1].nextResetTime, 0);

  // 团队 scope 标注
  const team = usage.parseEntitlementSnapshot({
    authenticated: true, context: { displayName: '团队A', scope: 'team' },
  });
  assert.equal(team.contextName, '团队A（团队）');

  // 未登录 / 空载荷 → 防御性默认
  const anon = usage.parseEntitlementSnapshot({ authenticated: false, unavailableReason: 'not_authenticated' });
  assert.equal(anon.authenticated, false);
  assert.equal(anon.unavailableReason, 'not_authenticated');
  const empty = usage.parseEntitlementSnapshot(null);
  assert.equal(empty.authenticated, false);
  assert.equal(empty.unavailableReason, 'unavailable');
  assert.deepEqual(empty.limits, []);
});

// ── 6. 模式/模型切换命令信封（批次21 会话级配置面）──

test('switchCollaborationMode/switchModelConfig 信封：CAS 必带 baseRevision，词表外拒', () => {
  const base = { commandId: 'cmd-21a', clientId: 'client-1', sessionId: 's-1', issuedAt: 1_726_000_000_000, baseRevision: 7 };
  for (const mode of ['build', 'edit', 'plan', 'yolo']) {
    assert.equal(commandMod.parseCommandEnvelope({
      ...base, commandId: `cmd-mode-${mode}`, type: 'switchCollaborationMode', payload: { mode },
    }).ok, true, `mode=${mode}`);
  }
  // CAS 命令缺 baseRevision 必须被拒（服务端口径的客户端面）
  assert.equal(commandMod.parseCommandEnvelope({
    commandId: 'cmd-mode-nocas', clientId: 'client-1', sessionId: 's-1', issuedAt: 1_726_000_000_000,
    type: 'switchCollaborationMode', payload: { mode: 'plan' },
  }).ok, false, '缺 baseRevision');
  assert.equal(commandMod.parseCommandEnvelope({
    ...base, commandId: 'cmd-mode-auto', type: 'switchCollaborationMode', payload: { mode: 'auto' },
  }).ok, false, 'auto 非用户可切');
  assert.equal(commandMod.parseCommandEnvelope({
    ...base, commandId: 'cmd-mode-ask', type: 'switchCollaborationMode', payload: { mode: 'ask' },
  }).ok, false, 'ask 是 App 本地概念（Q3）');

  assert.equal(commandMod.parseCommandEnvelope({
    ...base, commandId: 'cmd-model-1', type: 'switchModelConfig',
    payload: { provider: 'bigmodel', model: 'glm-4.7', thought: 'high' },
  }).ok, true);
  assert.equal(commandMod.parseCommandEnvelope({
    ...base, commandId: 'cmd-model-2', type: 'switchModelConfig',
    payload: { provider: 'bigmodel', model: 'glm-4.7' },
  }).ok, false, 'thought 三元组必填');
});
