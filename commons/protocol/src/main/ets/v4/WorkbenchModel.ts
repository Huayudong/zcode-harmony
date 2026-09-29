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

/** 对话行视图（conversation 投影；字段按 kind 取用，未涉及的为空值）。 */
export interface ConversationRowView {
  rowId: number;
  /** turnHeader/userInput/assistantText/reasoning/toolCall/subagent/artifact/hookInvocation/timelineMarker/other。 */
  kind: string;
  /** userInput/assistantText/reasoning 的正文；timelineMarker 的标签。 */
  text: string;
  /** 行状态（streaming/complete/...；toolCall 为 status 词表）。 */
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
  createdAt: number;
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

  /** 应用一帧；返回列表是否变化。 */
  applyFrame(frame: WorkbenchFrameLike): boolean {
    const { kind, body } = payloadOf(frame);
    if (kind === "snapshot" && body !== null) {
      this.bySessionId.clear();
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
  return {
    rowId: num(source, "rowId"),
    kind: str(source, "kind"),
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
    createdAt: num(source, "createdAt"),
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
