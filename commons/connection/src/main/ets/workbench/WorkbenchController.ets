/**
 * WorkbenchController —— A5 工作台的唯一所有者（每档案一份，M1 单活）。
 *
 * 职责链：档案/token/CA 重建连接三要素 → server-info 换 workspace target →
 * ConnectionEngine（A4）建立 WSS+v4 → 订阅分发：sessions-index 帧归约进
 * SessionsIndexModel，conversation 帧按会话归约进 ConversationModel（复用协议层
 * apply 语义），全程写穿 SQLite 缓存；离线/冷启动时先画缓存再等在线覆盖。
 *
 * 不变量（a5 spec）：
 * - 页面不直接触碰 engine/协议对象，只消费本类的视图事件与查询面；
 * - 命令一律走 engine.sendCommand（幂等排队），本类不做自己的重试；
 * - 缓存任何失败都不影响在线路径（SessionCache 内部已兜底）。
 */
import preferences from '@ohos.data.preferences';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  ConversationModel,
  Emitter,
  PROTOCOL_V4_LIMITS,
  SessionsIndexModel,
  parseFileChangesResult,
  type ConversationRowView,
  type Event,
  type FileChangesReportView,
  type PendingInteractionView,
  type SessionSummaryView,
  type V4Fault,
  type V4TopicFrame,
  type WorkbenchFrameLike,
  type WorkspaceTarget,
} from 'protocol';
import { AssetTokenStore, ProfileStore, type ConnectionProfile } from '../profile/ConnectionProfile';
import { PinnedHttpClient, PinnedHttpTarget, caFilePathIn } from '../http/PinnedHttpClient';
import { fetchServerInfo, type ServerInfoCheck } from '../pairing/PairingClient';
import {
  ConnectionEngine,
  type ConnectionState,
  type ConnectionStateEvent,
  type EngineOptions
} from '../session/ConnectionEngine';
import { SessionCache } from './SessionCache';

const DOMAIN: number = 0x0000;
const TAG: string = 'Workbench';
const APP_VERSION: string = '0.1.0';
const PREFS_NAME: string = 'zcode-workbench';
const KEY_CLIENT_ID: string = 'clientId';
const KEY_NOTIFY_LEVEL: string = 'notifyLevel';
/** 会话快照缓存写穿的去抖窗口（流式期间高频 delta 不逐条落盘）。 */
const CONVERSATION_FLUSH_DEBOUNCE_MS: number = 1500;

/** 连接三要素之一不可用时的停机态详情（UI 据此给重试/重新配对入口）。 */
type StartupFailure = 'no-profile' | 'no-token' | 'unreachable' | 'no-workspace';

/** 会话页可观察的对话面（行视图 + 标题 + 是否有流式工作 + 待批交互）。 */
export interface ConversationUpdate {
  sessionId: string;
  rows: ConversationRowView[];
  hasLiveWork: boolean;
  title: string;
  pending: PendingInteractionView[];
}

interface SendTextPayload {
  text: string;
  /** 按次提交的协作模式（build/plan；问答档待 Q3 澄清）。缺省走服务端会话当前模式。 */
  mode?: string;
  /** 已就绪附件的引用集（ref 只在 commit 后产生）。 */
  attachments?: SendAttachmentRef[];
}

interface SendAttachmentRef {
  ref: string;
  fileName: string;
  mime: string;
  bytes: number;
}

interface RawFileEntry {
  name?: string;
  relativePath?: string;
  type?: string;
}

/** 服务端 begin/chunk/commit 结果的运行时形状（已过协议 schema 校验）。 */
interface AttachmentBeginLike {
  state?: string;
  ref?: string;
}

interface AttachmentChunkLike {
  nextChunkIndex?: number;
}

interface AttachmentCommitLike {
  ref?: string;
}

/** 全量字节的 SHA-256（cryptoFramework 增量喂入，512KiB 一批）。 */
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const md = cryptoFramework.createMd('SHA-256');
  const blockSize = 512 * 1024;
  for (let start = 0; start < bytes.length; start += blockSize) {
    const block = bytes.subarray(start, Math.min(start + blockSize, bytes.length));
    const blob: cryptoFramework.DataBlob = { data: block };
    await md.update(blob);
  }
  const digest = await md.digest();
  const parts: string[] = [];
  for (const byte of digest.data) {
    parts.push(byte.toString(16).padStart(2, '0'));
  }
  return `sha256:${parts.join('')}`;
}

interface StopPayload {
  expectedForegroundExecutionId?: string;
}

/** 批准/应答选择（OUT-4）：选项 id 或自由文本，二者至多一。 */
export interface ResolveAnswer {
  optionId?: string;
  freeText?: string;
}

/** 附件编排状态（INP-3）：uploading→ready（commit 得 ref）/failed；ref 只在 ready 后非空。 */
export interface AttachmentItem {
  uploadId: string;
  fileName: string;
  mime: string;
  bytes: number;
  localUri: string;
  isImage: boolean;
  state: 'uploading' | 'ready' | 'failed';
  sentChunks: number;
  totalChunks: number;
  ref: string;
  error: string;
}

/** 附件列表事件（任一状态变化整表下发）。 */
export interface AttachmentUpdate {
  sessionId: string;
  items: AttachmentItem[];
}

/** @ 引用的文件候选（file 通道 searchWorkspaceFiles 投影）。 */
export interface WorkspaceFileView {
  name: string;
  relativePath: string;
  type: string;
}

/** 本地通知分级（NTY-4 基础档；M1 前台长连接驱动，Push 属 M2）。 */
export type NotificationLevel = 'approval-only' | 'all' | 'off';

interface ResolveInteractionPayload {
  interactionId: string;
  answer: ResolveAnswer;
}

interface RenameSessionPayload {
  title: string;
}

/** 缓存装载用的快照载荷形状（与服务端 sessions-index snapshot 同构的最小集）。 */
interface CachedSessionsSnapshot {
  sessions: object[];
}

export class WorkbenchController {
  private static instance: WorkbenchController | null = null;
  private static starting: Promise<WorkbenchController> | null = null;

  /** 进程级单例（M1 单档案单连接；引擎生命周期跨页面）。 */
  static shared(context: common.Context): Promise<WorkbenchController> {
    if (WorkbenchController.instance !== null) {
      return Promise.resolve(WorkbenchController.instance);
    }
    if (WorkbenchController.starting === null) {
      const created = new WorkbenchController(context);
      WorkbenchController.starting = created.initialize().then((): WorkbenchController => {
        WorkbenchController.instance = created;
        WorkbenchController.starting = null;
        return created;
      });
    }
    return WorkbenchController.starting;
  }

  private readonly context: common.Context;
  private readonly stateEmitter = new Emitter<ConnectionStateEvent>();
  private readonly sessionsEmitter = new Emitter<SessionSummaryView[]>();
  private readonly conversationEmitter = new Emitter<ConversationUpdate>();
  private readonly faultEmitter = new Emitter<V4Fault>();
  private readonly attachmentEmitter = new Emitter<AttachmentUpdate>();

  private profile: ConnectionProfile | null = null;
  private engine: ConnectionEngine | null = null;
  private cache: SessionCache | null = null;
  private readonly sessionsModel = new SessionsIndexModel();
  private readonly conversationModels = new Map<string, ConversationModel>();
  private readonly attachmentsBySession = new Map<string, AttachmentItem[]>();
  private readonly notifiedInteractions = new Set<string>();
  private readonly lastPhaseBySession = new Map<string, string>();
  private workbenchPrefs: preferences.Preferences | null = null;
  private notifyLevel: NotificationLevel = 'approval-only';
  private notifySeq = 0;
  private readonly pendingConversations = new Set<string>();
  private readonly conversationFlushTimers = new Map<string, number>();
  private readonly conversationFireTimers = new Map<string, number>();
  private readonly pendingConversationFire = new Set<string>();
  private sessionsIndexPending = true;

  private currentState: ConnectionStateEvent = { state: 'offline', detail: '尚未连接' };
  private serverName: string = '';
  private workspaceKey: string = '';
  private hasLiveData = false;
  private startupFailure: StartupFailure | null = null;

  private constructor(context: common.Context) {
    this.context = context;
  }

  // ── 事件面 ──
  get onStateChange(): Event<ConnectionStateEvent> {
    return this.stateEmitter.event;
  }

  get onSessionsChanged(): Event<SessionSummaryView[]> {
    return this.sessionsEmitter.event;
  }

  get onConversationChanged(): Event<ConversationUpdate> {
    return this.conversationEmitter.event;
  }

  get onFault(): Event<V4Fault> {
    return this.faultEmitter.event;
  }

  get onAttachmentChanged(): Event<AttachmentUpdate> {
    return this.attachmentEmitter.event;
  }

  // ── 查询面 ──
  getState(): ConnectionState {
    return this.currentState.state;
  }

  getStateEvent(): ConnectionStateEvent {
    return this.currentState;
  }

  getServerName(): string {
    return this.serverName;
  }

  /** 当前列表是否只来自缓存（从未收到过在线帧）。 */
  isFromCache(): boolean {
    return !this.hasLiveData;
  }

  getStartupFailure(): StartupFailure | null {
    return this.startupFailure;
  }

  getSessionList(): SessionSummaryView[] {
    return this.sessionsModel.list();
  }

  /** A9 诊断：待发命令数（断线积压）。 */
  getPendingCommandCount(): number {
    return this.engine !== null ? this.engine.pendingCommandCount : 0;
  }

  /** A9 诊断：活跃订阅水位条数。 */
  getWatermarkCount(): number {
    return this.engine !== null ? this.engine.currentWatermarks().length : 0;
  }

  // ── 启动链 ──

  /** 档案读取 →（异步）连接链。永不 reject：失败都落成 offline 态供 UI 呈现。 */
  private async initialize(): Promise<void> {
    try {
      const store = await ProfileStore.open(this.context);
      const active = await store.activeProfile();
      this.profile = active;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'profile load failed: %{public}s', String(error));
      this.profile = null;
    }
    if (this.profile === null) {
      this.startupFailure = 'no-profile';
      this.currentState = { state: 'offline', detail: '尚未配对' };
      return;
    }
    this.serverName = this.profile.name;
    await this.connectChain();
  }

  /** 连接三要素 → server-info → 引擎。失败按档落 offline 态，可 retry() 重走。 */
  private async connectChain(): Promise<void> {
    const profile = this.profile;
    if (profile === null) {
      return;
    }
    if (this.engine !== null) {
      this.engine.start();
      return;
    }
    this.currentState = { state: 'connecting', detail: '正在连接' };
    this.stateEmitter.fire(this.currentState);

    // ① 设备 token（Asset Kit；预览器/CI 不可用 → 显式停机，不静默降级）
    let token: string;
    try {
      const serverId = profile.id.startsWith('p_') ? profile.id.substring(2) : profile.id;
      token = await new AssetTokenStore().load(serverId);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'token load failed: %{public}s', String(error));
      this.startupFailure = 'no-token';
      this.currentState = { state: 'offline', detail: '设备凭证不可用，请重新配对' };
      this.stateEmitter.fire(this.currentState);
      return;
    }

    // ② CA 持久副本（配对时写入；缺失按无证书目标，PinnedHttpClient 自行降 http）
    let caPem: string = '';
    try {
      const caPath = caFilePathIn(this.context.filesDir);
      if (fs.accessSync(caPath)) {
        caPem = fs.readTextSync(caPath);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'ca read failed: %{public}s', String(error));
    }

    // ③ server-info 换 workspace target（v4 订阅的身份与 workspacePath 都来自这里）
    let info: ServerInfoCheck;
    try {
      const client = new PinnedHttpClient(this.context.filesDir);
      const target: PinnedHttpTarget = { host: profile.host, port: profile.port, caPem: caPem };
      info = await fetchServerInfo(client, target, token, profile.certFingerprint);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'server-info failed: %{public}s', String(error));
      this.startupFailure = 'unreachable';
      this.currentState = { state: 'offline', detail: '连不上电脑，检查网络后重试' };
      this.stateEmitter.fire(this.currentState);
      return;
    }
    if (info.workspacePath.length === 0) {
      this.startupFailure = 'no-workspace';
      this.currentState = { state: 'offline', detail: '服务端未下发工作区' };
      this.stateEmitter.fire(this.currentState);
      return;
    }
    const workspace: WorkspaceTarget = { workspacePath: info.workspacePath };
    if (info.workspaceIdentity.length > 0) {
      workspace.workspaceIdentity = info.workspaceIdentity;
    }
    this.workspaceKey = info.workspaceIdentity.length > 0 ? info.workspaceIdentity : info.workspacePath;

    // ④ clientId（设备级持久 UUID；preferences 失败退一次性 id，仅影响幂等归属）
    let clientId: string;
    try {
      const prefs = await preferences.getPreferences(this.context, { name: PREFS_NAME });
      const stored = await prefs.get(KEY_CLIENT_ID, '') as string;
      if (stored.length > 0) {
        clientId = stored;
      } else {
        clientId = util.generateRandomUUID();
        await prefs.put(KEY_CLIENT_ID, clientId);
        await prefs.flush();
      }
      this.workbenchPrefs = prefs;
      this.notifyLevel = await prefs.get(KEY_NOTIFY_LEVEL, 'approval-only') as NotificationLevel;
    } catch (error) {
      clientId = util.generateRandomUUID();
    }

    // ⑤ 缓存（失败 = 无缓存，页面走空态）
    try {
      this.cache = await SessionCache.open(this.context);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'cache open failed: %{public}s', String(error));
      this.cache = null;
    }

    // ⑥ 引擎：帧归约/状态/故障全部经本类事件面外发
    const httpTarget: PinnedHttpTarget = { host: profile.host, port: profile.port, caPem: caPem };
    const options: EngineOptions = {
      target: workspace,
      bearerToken: token,
      target_http: httpTarget,
      caFilePath: caFilePathIn(this.context.filesDir),
      clientId: clientId,
      appVersion: APP_VERSION,
    };
    const engine = new ConnectionEngine(options);
    engine.onStateChange((event: ConnectionStateEvent) => {
      this.currentState = event;
      if (event.state === 'online') {
        this.ensureSubscriptions();
      }
      this.stateEmitter.fire(event);
    });
    engine.onFault((fault: V4Fault) => {
      this.faultEmitter.fire(fault);
    });
    engine.onFrame((frame: V4TopicFrame) => {
      this.handleFrame(frame);
    });
    this.engine = engine;

    // ⑦ 缓存先行渲染，再等在线帧覆盖
    await this.loadCachedSessions();
    this.startupFailure = null;
    engine.start();
  }

  /** 用户点击重试：连接链失败重走；引擎在退避则立即重连。 */
  retry(): void {
    if (this.engine !== null) {
      this.engine.stop();
      this.engine.start();
      return;
    }
    void this.connectChain();
  }

  private async loadCachedSessions(): Promise<void> {
    if (this.cache === null || this.workspaceKey.length === 0) {
      return;
    }
    const json = await this.cache.loadSessions(this.workspaceKey);
    if (json.length === 0) {
      return;
    }
    const restored = SessionsIndexModel.parse(json);
    if (restored.size() > 0) {
      // 缓存里存的就是视图数组；按帧形状喂回归约器，走同一条覆盖路径。
      const snapshotBody: CachedSessionsSnapshot = { sessions: JSON.parse(json) as object[] };
      const cachedFrame: WorkbenchFrameLike = { payload: { kind: 'snapshot', snapshot: snapshotBody } };
      this.sessionsModel.applyFrame(cachedFrame);
      this.fireSessions();
    }
  }

  // ── 订阅 ──

  /** online 后补挂未完成的订阅（首订与断线重订共用 engine 的带水位语义）。 */
  private ensureSubscriptions(): void {
    const engine = this.engine;
    if (engine === null || engine.getState() !== 'online') {
      return;
    }
    if (this.sessionsIndexPending) {
      engine.subscribeSessionsIndex().then((): void => {
        this.sessionsIndexPending = false;
      }).catch((): void => {
        // 保持 pending；下一个 online 事件（重连）再试
      });
    }
    const pending: string[] = [];
    this.pendingConversations.forEach((sessionId: string) => {
      pending.push(sessionId);
    });
    for (const sessionId of pending) {
      engine.subscribeConversation(sessionId).then((): void => {
        this.pendingConversations.delete(sessionId);
      }).catch((): void => {
        // 同上
      });
    }
  }

  /** 会话页打开：先画缓存（如有），再订阅在线流。返回立即可用的行视图。 */
  async openSession(sessionId: string): Promise<ConversationRowView[]> {
    let model = this.conversationModels.get(sessionId);
    if (model === undefined) {
      model = new ConversationModel(sessionId);
      this.conversationModels.set(sessionId, model);
      if (this.cache !== null) {
        const cached = await this.cache.loadConversation(sessionId);
        if (cached !== null) {
          const parsed = ConversationModel.parse(cached.snapshotJson);
          if (parsed !== null) {
            this.conversationModels.set(sessionId, parsed);
          }
        }
      }
    }
    this.pendingConversations.add(sessionId);
    this.ensureSubscriptions();
    this.fireConversation(sessionId);
    const current = this.conversationModels.get(sessionId);
    return current !== undefined ? current.rows() : [];
  }

  /** 会话页关闭：收尾落盘并收缩订阅（水位清空，下次打开回全量 snapshot）。 */
  async closeSession(sessionId: string): Promise<void> {
    this.pendingConversations.delete(sessionId);
    this.flushConversationCache(sessionId);
    if (this.engine !== null) {
      this.engine.unsubscribeConversation(sessionId);
    }
  }

  // ── 帧归约与缓存写穿 ──

  private handleFrame(frame: V4TopicFrame): void {
    if (frame.topic.startsWith('sessions-index/')) {
      if (this.sessionsModel.applyFrame(frame)) {
        this.hasLiveData = true;
        if (this.cache !== null && this.workspaceKey.length > 0) {
          void this.cache.saveSessions(this.workspaceKey, this.sessionsModel.toJSON());
        }
        this.fireSessions();
        this.notifyPhaseTransitions();
      }
      return;
    }
    if (frame.topic.startsWith('conversation/')) {
      const sessionId = frame.topic.substring('conversation/'.length);
      const model = this.conversationModels.get(sessionId);
      if (model !== undefined && model.applyFrame(frame)) {
        this.scheduleConversationFlush(sessionId);
        // OUT-1 16ms 合帧：一帧一绘，flush 窗口内的连发帧合并为单次视图事件
        this.fireConversationThrottled(sessionId);
        this.notifyNewInteractions(sessionId, model.pendingInteractions());
      }
    }
  }

  /** 16ms 前沿+尾沿合帧：首帧立即绘，窗口内的后续帧合并到尾沿一次绘。 */
  private fireConversationThrottled(sessionId: string): void {
    if (this.conversationFireTimers.has(sessionId)) {
      this.pendingConversationFire.add(sessionId);
      return;
    }
    this.fireConversation(sessionId);
    const timer = setTimeout((): void => {
      this.conversationFireTimers.delete(sessionId);
      if (this.pendingConversationFire.delete(sessionId)) {
        this.fireConversationThrottled(sessionId);
      }
    }, 16);
    this.conversationFireTimers.set(sessionId, timer);
  }

  // ── A8 前台本地通知（NTY-1/2 简化 + NTY-4 基础分级；Push 属 M2）──

  getNotificationLevel(): NotificationLevel {
    return this.notifyLevel;
  }

  async setNotificationLevel(level: NotificationLevel): Promise<void> {
    this.notifyLevel = level;
    if (this.workbenchPrefs !== null) {
      try {
        await this.workbenchPrefs.put(KEY_NOTIFY_LEVEL, level);
        await this.workbenchPrefs.flush();
      } catch (error) {
        hilog.warn(0, 'Workbench', 'notify level persist failed: %{public}s', String(error));
      }
    }
  }

  /** 新出现的待批/待答交互 → 按分级发本地通知（每个 interactionId 只发一次）。 */
  private notifyNewInteractions(sessionId: string, pending: PendingInteractionView[]): void {
    if (this.notifyLevel === 'off' || pending.length === 0) {
      return;
    }
    for (const item of pending) {
      if (this.notifiedInteractions.has(item.interactionId)) {
        continue;
      }
      this.notifiedInteractions.add(item.interactionId);
      const isPermission = item.kind === 'permission';
      if (this.notifyLevel === 'approval-only' && !isPermission) {
        continue;
      }
      const action = isPermission ? '等待你的批准' : '等待你的输入';
      void this.publishNotification(action, `${this.sessionTitleOf(sessionId)}：${item.title}`);
    }
  }

  /** 会话阶段迁移到终态 → 'all' 分级下通知完成/出错（首个快照不补发历史）。 */
  private notifyPhaseTransitions(): void {
    if (this.notifyLevel !== 'all') {
      return;
    }
    for (const summary of this.sessionsModel.list()) {
      const prev = this.lastPhaseBySession.get(summary.sessionId);
      this.lastPhaseBySession.set(summary.sessionId, summary.phase);
      if (prev === undefined || prev === summary.phase) {
        continue;
      }
      if (summary.phase === 'completedSuccess') {
        void this.publishNotification('任务完成', this.sessionTitleOf(summary.sessionId));
      } else if (summary.phase === 'error') {
        void this.publishNotification('任务出错', this.sessionTitleOf(summary.sessionId));
      } else if (summary.phase === 'completedInterrupted') {
        void this.publishNotification('任务已中断', this.sessionTitleOf(summary.sessionId));
      }
    }
  }

  private sessionTitleOf(sessionId: string): string {
    const summary = this.sessionsModel.summaryOf(sessionId);
    if (summary !== null && summary.title.length > 0) {
      return summary.title;
    }
    const model = this.conversationModels.get(sessionId);
    if (model !== undefined && model.title().length > 0) {
      return model.title();
    }
    return '会话';
  }

  private async publishNotification(title: string, text: string): Promise<void> {
    try {
      this.notifySeq += 1;
      const request: notificationManager.NotificationRequest = {
        id: this.notifySeq,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text.length > 0 ? text : 'ZCode',
            additionalText: '',
          },
        },
      };
      await notificationManager.publish(request);
    } catch (error) {
      // 通知未授权等场景静默（用户可在系统设置开启；直达卡片属 M2 Push 批）
      hilog.warn(0, 'Workbench', 'notify publish failed: %{public}s', String(error));
    }
  }

  private scheduleConversationFlush(sessionId: string): void {
    if (this.conversationFlushTimers.has(sessionId)) {
      return;
    }
    const timer = setTimeout((): void => {
      this.conversationFlushTimers.delete(sessionId);
      this.flushConversationCache(sessionId);
    }, CONVERSATION_FLUSH_DEBOUNCE_MS);
    this.conversationFlushTimers.set(sessionId, timer);
  }

  private flushConversationCache(sessionId: string): void {
    const timer = this.conversationFlushTimers.get(sessionId);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.conversationFlushTimers.delete(sessionId);
    }
    if (this.cache === null) {
      return;
    }
    const model = this.conversationModels.get(sessionId);
    if (model !== undefined) {
      void this.cache.saveConversation(sessionId, model.toJSON());
    }
  }

  // ── 命令面（全部走 engine 幂等队列）──

  /** 发送文本；mode 为按次协作模式（'build'|'plan'，空串 = 跟随服务端会话当前模式）；
   *  attachments 传当前会话的附件集，只有 ready 状态的会随信封引用发送，发送成功后整组清除。 */
  async sendText(sessionId: string, text: string, mode: string, attachments: AttachmentItem[]): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const ready: SendAttachmentRef[] = [];
    for (const item of attachments) {
      if (item.state === 'ready' && item.ref.length > 0) {
        ready.push({ ref: item.ref, fileName: item.fileName, mime: item.mime, bytes: item.bytes });
      }
    }
    let payload: SendTextPayload;
    if (mode.length > 0 && ready.length > 0) {
      payload = { text: text, mode: mode, attachments: ready };
    } else if (mode.length > 0) {
      payload = { text: text, mode: mode };
    } else if (ready.length > 0) {
      payload = { text: text, attachments: ready };
    } else {
      payload = { text: text };
    }
    await engine.sendCommand(sessionId, 'sendText', payload);
    if (ready.length > 0) {
      this.attachmentsBySession.delete(sessionId);
      this.fireAttachments(sessionId);
    }
  }

  // ── INP-3 附件编排（begin → chunk×N → commit；失败/取消 → abort）──

  attachmentsOf(sessionId: string): AttachmentItem[] {
    const items = this.attachmentsBySession.get(sessionId);
    return items !== undefined ? items : [];
  }

  /**
   * 选取结果入队上传：全量读入的文件字节 → begin（总量 + sha256）→ 顺序 chunk
   * （≤512KiB/块，nextChunkIndex 以服务端 ACK 为准）→ commit 换 ref。
   * 超限（20MiB / 64 块）与离线直接 failed，不做排队（附件不是命令）。
   */
  async attachFile(sessionId: string, fileName: string, mime: string, bytes: Uint8Array,
    localUri: string, isImage: boolean): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    if (bytes.length > PROTOCOL_V4_LIMITS.attachmentMaxBytes) {
      throw new Error(`附件超过 ${Math.round(PROTOCOL_V4_LIMITS.attachmentMaxBytes / 1024 / 1024)}MiB 上限`);
    }
    const totalChunks = Math.ceil(bytes.length / PROTOCOL_V4_LIMITS.attachmentChunkMaxBytes);
    if (totalChunks > PROTOCOL_V4_LIMITS.attachmentUploadMaxChunks) {
      throw new Error('附件分块数超限');
    }
    const uploadId = util.generateRandomUUID();
    const item: AttachmentItem = {
      uploadId: uploadId,
      fileName: fileName,
      mime: mime,
      bytes: bytes.length,
      localUri: localUri,
      isImage: isImage,
      state: 'uploading',
      sentChunks: 0,
      totalChunks: totalChunks,
      ref: '',
      error: '',
    };
    let items = this.attachmentsBySession.get(sessionId);
    if (items === undefined) {
      items = [];
      this.attachmentsBySession.set(sessionId, items);
    }
    items.push(item);
    this.fireAttachments(sessionId);

    try {
      const checksum = await sha256Hex(bytes);
      const beginRaw = await engine.attachmentBegin(sessionId, uploadId, fileName, mime,
        bytes.length, totalChunks, checksum);
      const begin = beginRaw as AttachmentBeginLike;
      if ((begin.state ?? '') === 'committed') {
        item.ref = begin.ref ?? '';
        item.state = 'ready';
        item.sentChunks = totalChunks;
        this.fireAttachments(sessionId);
        return;
      }
      const base64 = new util.Base64Helper();
      for (let index = 0; index < totalChunks; index += 1) {
        const start = index * PROTOCOL_V4_LIMITS.attachmentChunkMaxBytes;
        const block = bytes.subarray(start, Math.min(start + PROTOCOL_V4_LIMITS.attachmentChunkMaxBytes, bytes.length));
        const chunkRaw = await engine.attachmentChunk(sessionId, uploadId, index, base64.encodeToStringSync(block));
        const next = (chunkRaw as AttachmentChunkLike).nextChunkIndex ?? 0;
        item.sentChunks = next > 0 ? next : index + 1;
        this.fireAttachments(sessionId);
      }
      const commitRaw = await engine.attachmentCommit(sessionId, uploadId);
      item.ref = (commitRaw as AttachmentCommitLike).ref ?? '';
      item.state = item.ref.length > 0 ? 'ready' : 'failed';
      if (item.state === 'failed') {
        item.error = 'commit 未返回引用';
      }
    } catch (error) {
      item.state = 'failed';
      item.error = error instanceof Error ? error.message : String(error);
      // 半上传尽力回收（TTL 5min 兜底，失败无副作用）
      try {
        await engine.attachmentAbort(sessionId, uploadId);
      } catch (abortError) {
        hilog.warn(0, 'Workbench', 'attachment abort failed: %{public}s', String(abortError));
      }
    }
    this.fireAttachments(sessionId);
  }

  /** 移除附件（uploading 中先 abort，服务端按 TTL 兜底）。 */
  async removeAttachment(sessionId: string, uploadId: string): Promise<void> {
    const items = this.attachmentsBySession.get(sessionId);
    if (items === undefined) {
      return;
    }
    const target = items.find((item: AttachmentItem) => item.uploadId === uploadId);
    this.attachmentsBySession.set(sessionId, items.filter((item: AttachmentItem) => item.uploadId !== uploadId));
    this.fireAttachments(sessionId);
    if (target !== undefined && target.state === 'uploading' && this.engine !== null) {
      try {
        await this.engine.attachmentAbort(sessionId, uploadId);
      } catch (error) {
        // 尽力回收
      }
    }
  }

  /** @ 引用（INP-4）：Host 索引模糊搜索，返回有界候选。 */
  async searchWorkspaceFiles(query: string, limit: number): Promise<WorkspaceFileView[]> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const entries = await engine.searchWorkspaceFiles(query, limit);
    const out: WorkspaceFileView[] = [];
    for (const entry of entries) {
      const record = entry as RawFileEntry;
      const relativePath = record.relativePath ?? '';
      if (relativePath.length === 0) {
        continue;
      }
      out.push({
        name: record.name ?? relativePath,
        relativePath: relativePath,
        type: record.type ?? 'file',
      });
    }
    return out;
  }

  private fireAttachments(sessionId: string): void {
    const items = this.attachmentsBySession.get(sessionId);
    const update: AttachmentUpdate = {
      sessionId: sessionId,
      items: items !== undefined ? items : [],
    };
    this.attachmentEmitter.fire(update);
  }

  async stopSession(sessionId: string): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const payload: StopPayload = {};
    await engine.sendCommand(sessionId, 'stop', payload);
  }

  /**
   * 批准/应答（OUT-4）：按服务端词表回 optionId（permission 的允许/拒绝、
   * userInput 的题面选项）或自由文本；interactionId 幂等，多端竞态以 CLI 准入为准。
   */
  async resolveInteraction(sessionId: string, interactionId: string, answer: ResolveAnswer): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const payload: ResolveInteractionPayload = { interactionId: interactionId, answer: answer };
    await engine.sendCommand(sessionId, 'resolveInteraction', payload);
  }

  /** 变更 Tab（OUT-5）：拉取某轮（turnHeader 行）的文件变更报告。 */
  async loadFileChanges(sessionId: string, turnRowId: number, turnEntityId: string): Promise<FileChangesReportView> {
    const engine = this.engine;
    const model = this.conversationModels.get(sessionId);
    if (engine === null || model === undefined) {
      throw new Error('未连接');
    }
    const baseLogEpoch = model.logEpoch();
    if (baseLogEpoch.length === 0) {
      throw new Error('会话快照未就绪');
    }
    const raw = await engine.queryFileChanges(sessionId, turnRowId, turnEntityId, model.revision(), baseLogEpoch);
    return parseFileChangesResult(raw);
  }

  /** 会话改名（A9 列表重命名；title 走 renameSession 幂等命令，服务端落 meta.title）。 */
  async renameSession(sessionId: string, title: string): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const payload: RenameSessionPayload = { title: title };
    await engine.sendCommand(sessionId, 'renameSession', payload);
  }

  /** A9：按当前活跃档案重建连接链（切换档案/诊断重连共用）。 */
  async restart(): Promise<void> {
    if (this.engine !== null) {
      this.engine.stop();
      this.engine = null;
    }
    this.profile = null;
    this.workspaceKey = '';
    this.hasLiveData = false;
    this.sessionsIndexPending = true;
    this.startupFailure = null;
    this.currentState = { state: 'offline', detail: '正在重连' };
    this.stateEmitter.fire(this.currentState);
    this.conversationModels.clear();
    this.attachmentsBySession.clear();
    await this.initialize();
  }

  /** A9：清本地缓存（会话列表/对话快照/草稿；不动档案与凭证）。 */
  async clearLocalCache(): Promise<void> {
    if (this.cache !== null) {
      await this.cache.clearAll();
    }
    try {
      const drafts = await preferences.getPreferences(this.context, { name: 'zcode-drafts' });
      await drafts.clear();
      await drafts.flush();
    } catch (error) {
      hilog.warn(0, 'Workbench', 'draft clear failed: %{public}s', String(error));
    }
  }

  // ── 视图事件 ──

  private fireSessions(): void {
    this.sessionsEmitter.fire(this.sessionsModel.list());
  }

  private fireConversation(sessionId: string): void {
    const model = this.conversationModels.get(sessionId);
    if (model === undefined) {
      return;
    }
    const update: ConversationUpdate = {
      sessionId: sessionId,
      rows: model.rows(),
      hasLiveWork: model.hasLiveWork(),
      title: model.title(),
      pending: model.pendingInteractions(),
    };
    this.conversationEmitter.fire(update);
  }
}
