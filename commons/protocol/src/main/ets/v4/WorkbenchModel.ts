/**
 * WorkbenchModel —— A5 工作台的投影层（纯逻辑，node/设备双端可运行）。
 *
 * 职责：把订阅帧（sessions-index / conversation 的 snapshot|deltas 载荷）归约成
 * 具体类型的视图对象，供 ArkTS 页面直接消费。帧载荷在 AgentV4Client 已过 schema
 * 校验，这里只做防御性取值，不再 parse；行归并语义复用 apply.ts（黄金测试背书），
 * 本文件不引入额外分支。
 *
 * 类型边界：v4 源的类型域经 zod-ambient 收敛为 any，本模块对内按 any 搬运、
 * 对外只导出具体接口——.ets 消费端拿到的都是可静态检查的形状。
 */
import { applyConversationDeltas } from "./apply.js";

// ── 视图形状（.ets 消费面）──

/** 会话列表行（sessions-index 投影）。 */
export interface SessionSummaryView {
  sessionId: string;
  /** 空串 = 服务端未给标题（UI 显示「未命名会话」）。 */
  title: string;
  /** draft/prewarming/running/completedSuccess/completedInterrupted/error。 */
  phase: string;
  sessionEnded: boolean;
  hasBackgroundWork: boolean;
  /** 待处理交互数（OUT 卡片入口；0 = 无）。 */
  pendingInteractionCount: number;
  lastActivityAt: number;
  createdAt: number;
  /** 末条助手回复预览（≤120 字符；空串 = 无）。 */
  lastAssistantPreview: string;
}

/** 待处理交互的应答选项（permission 用服务端词表；userInput 为题面选项）。 */
export interface PendingInteractionOptionView {
  optionId: string;
  label: string;
  /** allowOnce/allowAlways/deny/custom；userInput 选项为空串。 */
  kind: string;
}

/** 待处理交互视图（OUT-3/4 吸底卡片的数据面）。 */
export interface PendingInteractionView {
  interactionId: string;
  /** permission/userInput/workspaceHookReview（第三类本批只提示不在手机处理）。 */
  kind: string;
  /** 卡片主文案：permission=summary；userInput=当前问题。 */
  title: string;
  /** permission 的工具名（空串 = 无）。 */
  toolName: string;
  /** 允许自由文本应答（permission.freeText / userInput.freeText）。 */
  freeText: boolean;
  /** userInput 敏感输入（密码类，UI 禁历史）。 */
  sensitive: boolean;
  options: PendingInteractionOptionView[];
  createdAt: number;
}

/** 对话行视图（conversation 投影；字段按 kind 取用，未涉及的为空值）。 */
export interface ConversationRowView {
  rowId: number;
  /** turnHeader/userInput/assistantText/reasoning/toolCall/subagent/artifact/hookInvocation/timelineMarker/other。 */
  kind: string;
  /** 稳定实体 id（turnHeader 作 fileChanges 查询 target 用；空串 = 无）。 */
  entityId: string;
  /** userInput/assistantText/reasoning 的正文；timelineMarker 的标签。 */
  text: string;
  /** 行状态（streaming/complete/...；toolCall/subagent 为 status 词表）。 */
  state: string;
  toolName: string;
  /** 工具入参（单行展示用）。 */
  inputText: string;
  /** 工具输出文本（有输出时非空）。 */
  outputText: string;
  /** status=error 时的错误摘要。 */
  errorMessage: string;
  /** reasoning.durationMs / turnHeader.activeMs（0 = 无）。 */
  durationMs: number;
  subagentType: string;
  summaryText: string;
  /** artifact 显示名。 */
  displayName: string;
  artifactType: string;
  /** assistantText.model。 */
  modelName: string;
  /** turnHeader.fileChanges 聚合（0 = 无）。 */
  fileAdditions: number;
  fileDeletions: number;
  fileCount: number;
  createdAt: number;
}

/** 只读 diff hunk 视图（OUT-5；行首 +/-/空格 语义由服务端 lines 携带）。 */
export interface DiffHunkView {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: string[];
}

/** 单文件变更视图（OUT-5 文件列表行）。 */
export interface FileChangeItemView {
  path: string;
  additions: number;
  deletions: number;
  toolNames: string;
  hunks: DiffHunkView[];
}

/** 一轮的文件变更报告（v4ConversationFileChangesResult 投影）。 */
export interface FileChangesReportView {
  files: number;
  additions: number;
  deletions: number;
  /** active/reverted；空串 = 服务端未标注。 */
  state: string;
  items: FileChangeItemView[];
}

// ── 防御性取值 ──

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" ? value as Record<string, unknown> : null;
}

function str(source: Record<string, unknown> | null, key: string): string {
  const value = source?.[key];
  return typeof value === "string" ? value : "";
}

function num(source: Record<string, unknown> | null, key: string): number {
  const value = source?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function bool(source: Record<string, unknown> | null, key: string): boolean {
  return source?.[key] === true;
}

function arr(source: Record<string, unknown> | null, key: string): unknown[] {
  const value = source?.[key];
  return Array.isArray(value) ? value : [];
}

function child(source: Record<string, unknown> | null, key: string): Record<string, unknown> | null {
  return asRecord(source?.[key]);
}

/** 订阅帧的最小结构（与 AgentV4Client.V4TopicFrame 结构兼容）。 */
export interface WorkbenchFrameLike {
  payload: object;
}

function payloadOf(frame: WorkbenchFrameLike): { kind: string; body: Record<string, unknown> | null } {
  const payload = asRecord(frame.payload);
  if (payload === null) {
    return { kind: "", body: null };
  }
  const kind = str(payload, "kind");
  if (kind === "snapshot") {
    return { kind: kind, body: child(payload, "snapshot") };
  }
  if (kind === "deltas") {
    return { kind: kind, body: payload };
  }
  return { kind: kind, body: payload };
}

// ── sessions-index 投影 ──

function summaryFrom(source: Record<string, unknown>): SessionSummaryView {
  const pending = child(source, "pendingInteractionSummary");
  return {
    sessionId: str(source, "sessionId"),
    title: str(source, "title"),
    phase: str(source, "phase"),
    sessionEnded: bool(source, "sessionEnded"),
    hasBackgroundWork: bool(source, "hasBackgroundWork"),
    pendingInteractionCount: num(pending, "permissionCount") + num(pending, "userInputCount"),
    lastActivityAt: num(source, "lastActivityAt"),
    createdAt: num(source, "createdAt"),
    lastAssistantPreview: str(source, "lastAssistantPreview"),
  };
}

export class SessionsIndexModel {
  private readonly bySessionId = new Map<string, SessionSummaryView>();
  private lastWorkspaceId = '';

  /** 快照携带的 workspaceId（createSession 命令载荷需要；空串 = 尚未收到快照）。 */
  workspaceId(): string {
    return this.lastWorkspaceId;
  }

  /** 应用一帧；返回列表是否变化。 */
  applyFrame(frame: WorkbenchFrameLike): boolean {
    const { kind, body } = payloadOf(frame);
    if (kind === "snapshot" && body !== null) {
      this.bySessionId.clear();
      this.lastWorkspaceId = str(body, "workspaceId");
      for (const item of arr(body, "sessions")) {
        const record = asRecord(item);
        if (record === null) {
          continue;
        }
        const view = summaryFrom(record);
        if (view.sessionId.length > 0) {
          this.bySessionId.set(view.sessionId, view);
        }
      }
      return true;
    }
    if (kind === "deltas" && body !== null) {
      let changed = false;
      for (const item of arr(body, "deltas")) {
        const delta = asRecord(item);
        if (delta === null) {
          continue;
        }
        const op = str(delta, "op");
        if (op === "session.upserted") {
          const session = child(delta, "session");
          if (session !== null) {
            const view = summaryFrom(session);
            if (view.sessionId.length > 0) {
              this.bySessionId.set(view.sessionId, view);
              changed = true;
            }
          }
        } else if (op === "session.removed") {
          const sessionId = str(delta, "sessionId");
          if (this.bySessionId.delete(sessionId)) {
            changed = true;
          }
        }
      }
      return changed;
    }
    return false;
  }

  /** 按最近活跃降序。 */
  list(): SessionSummaryView[] {
    const out: SessionSummaryView[] = [];
    this.bySessionId.forEach((view) => out.push(view));
    out.sort((a: SessionSummaryView, b: SessionSummaryView) => b.lastActivityAt - a.lastActivityAt);
    return out;
  }

  size(): number {
    return this.bySessionId.size;
  }

  summaryOf(sessionId: string): SessionSummaryView | null {
    return this.bySessionId.get(sessionId) ?? null;
  }

  toJSON(): string {
    return JSON.stringify(this.list());
  }

  static parse(json: string): SessionsIndexModel {
    const model = new SessionsIndexModel();
    try {
      const parsed = JSON.parse(json) as unknown;
      // 缓存里存的就是视图（toJSON 的产物），直接按视图字段读回，不再二次派生。
      for (const item of Array.isArray(parsed) ? parsed : []) {
        const record = asRecord(item);
        if (record === null) {
          continue;
        }
        const view: SessionSummaryView = {
          sessionId: str(record, "sessionId"),
          title: str(record, "title"),
          phase: str(record, "phase"),
          sessionEnded: bool(record, "sessionEnded"),
          hasBackgroundWork: bool(record, "hasBackgroundWork"),
          pendingInteractionCount: num(record, "pendingInteractionCount"),
          lastActivityAt: num(record, "lastActivityAt"),
          createdAt: num(record, "createdAt"),
          lastAssistantPreview: str(record, "lastAssistantPreview"),
        };
        if (view.sessionId.length > 0) {
          model.bySessionId.set(view.sessionId, view);
        }
      }
    } catch {
      // 缓存损坏按空列表处理（下次 snapshot 全量覆盖）。
    }
    return model;
  }
}

// ── conversation 投影 ──

function rowViewFrom(source: Record<string, unknown>): ConversationRowView {
  const output = child(source, "output");
  const error = child(source, "error");
  const fileChanges = child(source, "fileChanges");
  return {
    rowId: num(source, "rowId"),
    kind: str(source, "kind"),
    entityId: str(source, "entityId"),
    text: str(source, "text"),
    // 行状态：多数行叫 state，toolCall/subagent 叫 status——归一到同一视图字段。
    state: str(source, "state") || str(source, "status"),
    toolName: str(source, "toolName"),
    inputText: str(source, "inputText"),
    outputText: str(output, "text"),
    errorMessage: str(error, "message"),
    durationMs: num(source, "durationMs") || num(source, "activeMs"),
    subagentType: str(source, "subagentType"),
    summaryText: str(source, "summaryText"),
    displayName: str(source, "displayName"),
    artifactType: str(source, "artifactType"),
    modelName: str(source, "model"),
    fileAdditions: num(fileChanges, "additions"),
    fileDeletions: num(fileChanges, "deletions"),
    fileCount: num(fileChanges, "files"),
    createdAt: num(source, "createdAt"),
  };
}

/** 待处理交互投影（permission/userInput 各取卡片所需的最小面）。 */
function pendingFrom(source: Record<string, unknown>): PendingInteractionView {
  const payload = child(source, "payload");
  const kind = str(source, "kind");
  const view: PendingInteractionView = {
    interactionId: str(source, "interactionId"),
    kind: kind,
    title: "",
    toolName: "",
    freeText: false,
    sensitive: false,
    options: [],
    createdAt: num(source, "createdAt"),
  };
  if (kind === "permission" && payload !== null) {
    view.title = str(payload, "summary");
    view.toolName = str(payload, "toolName");
    view.freeText = bool(payload, "freeText");
    for (const item of arr(payload, "options")) {
      const option = asRecord(item);
      if (option === null) {
        continue;
      }
      view.options.push({ optionId: str(option, "optionId"), label: str(option, "label"), kind: str(option, "kind") });
    }
  } else if (kind === "userInput" && payload !== null) {
    view.freeText = bool(payload, "freeText");
    view.sensitive = bool(payload, "sensitive");
    // AskUserQuestion 多问题：取当前问题与其选项；单问题用 prompt + 顶层 options。
    const questions = arr(payload, "questions");
    const index = num(payload, "currentQuestionIndex");
    const question = questions.length > 0
      ? asRecord(questions[Math.min(Math.max(index, 0), questions.length - 1)])
      : null;
    if (question !== null) {
      view.title = str(question, "question");
      for (const item of arr(question, "options")) {
        const option = asRecord(item);
        if (option === null) {
          continue;
        }
        view.options.push({ optionId: str(option, "value"), label: str(option, "label"), kind: "" });
      }
    } else {
      view.title = str(payload, "prompt");
      for (const item of arr(payload, "options")) {
        const option = asRecord(item);
        if (option === null) {
          continue;
        }
        view.options.push({ optionId: str(option, "optionId"), label: str(option, "label"), kind: "" });
      }
    }
  }
  return view;
}

/** v4ConversationFileChangesResult → 报告视图（防御性提取；入参已经原 schema 校验）。 */
export function parseFileChangesResult(source: unknown): FileChangesReportView {
  const record = asRecord(source);
  const items: FileChangeItemView[] = [];
  for (const item of arr(record, "items")) {
    const file = asRecord(item);
    if (file === null) {
      continue;
    }
    const hunks: DiffHunkView[] = [];
    for (const patch of arr(file, "patches")) {
      const hunk = asRecord(patch);
      if (hunk === null) {
        continue;
      }
      const lines: string[] = [];
      for (const line of arr(hunk, "lines")) {
        if (typeof line === "string") {
          lines.push(line);
        }
      }
      hunks.push({
        oldStart: num(hunk, "oldStart"),
        oldLines: num(hunk, "oldLines"),
        newStart: num(hunk, "newStart"),
        newLines: num(hunk, "newLines"),
        lines: lines,
      });
    }
    const tools: string[] = [];
    for (const tool of arr(file, "toolNames")) {
      if (typeof tool === "string") {
        tools.push(tool);
      }
    }
    items.push({
      path: str(file, "path"),
      additions: num(file, "additions"),
      deletions: num(file, "deletions"),
      toolNames: tools.join(" · "),
      hunks: hunks,
    });
  }
  return {
    files: num(record, "files"),
    additions: num(record, "additions"),
    deletions: num(record, "deletions"),
    state: str(record, "state"),
    items: items,
  };
}

export class ConversationModel {
  readonly sessionId: string;
  private snapshot: Record<string, unknown> | null = null;

  constructor(sessionId: string) {
    this.sessionId = sessionId;
  }

  /** 应用一帧；返回是否产生了可见变化。 */
  applyFrame(frame: WorkbenchFrameLike): boolean {
    const { kind, body } = payloadOf(frame);
    if (kind === "snapshot" && body !== null) {
      this.snapshot = body;
      return true;
    }
    if (kind === "deltas" && body !== null && this.snapshot !== null) {
      const deltas: unknown[] = arr(body, "deltas");
      if (deltas.length === 0) {
        return false;
      }
      this.snapshot = asRecord(applyConversationDeltas(this.snapshot, deltas));
      return true;
    }
    return false;
  }

  /** 行视图（rowId 升序；无快照时空数组）。 */
  rows(): ConversationRowView[] {
    const window = arr(child(this.snapshot, "rows"), "window");
    const out: ConversationRowView[] = [];
    for (const item of window) {
      const record = asRecord(item);
      if (record !== null) {
        out.push(rowViewFrom(record));
      }
    }
    return out;
  }

  /** 服务端写入的会话标题（meta.title；空串 = 无）。 */
  title(): string {
    return str(child(this.snapshot, "meta"), "title");
  }

  /** 待处理交互视图（OUT-3/4 吸底卡片数据面；state.updated{pendingInteractions} 即整体替换）。 */
  pendingInteractions(): PendingInteractionView[] {
    const out: PendingInteractionView[] = [];
    for (const item of arr(this.snapshot, "pendingInteractions")) {
      const record = asRecord(item);
      if (record !== null) {
        out.push(pendingFrom(record));
      }
    }
    return out;
  }

  /** 快照 revision（fileChanges 只读查询的 baseRevision）。 */
  revision(): number {
    return num(this.snapshot, "revision");
  }

  /** 快照日志纪元（fileChanges 查询的 baseLogEpoch；空串 = 未就绪）。 */
  logEpoch(): string {
    return str(this.snapshot, "logEpoch");
  }

  /** 是否有流式中的内容（正文/工具在跑）——停止按钮与「进行中」徽标依据。 */
  hasLiveWork(): boolean {
    for (const row of this.rows()) {
      if (row.kind === "assistantText" && row.state === "streaming") {
        return true;
      }
      if (row.kind === "reasoning" && row.state === "streaming") {
        return true;
      }
      if (row.kind === "toolCall"
        && (row.state === "running" || row.state === "inputStreaming" || row.state === "pendingApproval")) {
        return true;
      }
      if (row.kind === "subagent" && row.state === "running") {
        return true;
      }
    }
    return false;
  }

  toJSON(): string {
    return JSON.stringify({ sessionId: this.sessionId, snapshot: this.snapshot });
  }

  static parse(json: string): ConversationModel | null {
    try {
      const parsed = asRecord(JSON.parse(json));
      const snapshot = parsed === null ? null : child(parsed, "snapshot");
      const sessionId = parsed === null ? "" : str(parsed, "sessionId");
      if (sessionId.length === 0 || snapshot === null) {
        return null;
      }
      const model = new ConversationModel(sessionId);
      model.snapshot = snapshot;
      return model;
    } catch {
      return null;
    }
  }
}
