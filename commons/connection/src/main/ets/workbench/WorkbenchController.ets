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
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ConversationModel,
  Emitter,
  SessionsIndexModel,
  type ConversationRowView,
  type Event,
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
/** 会话快照缓存写穿的去抖窗口（流式期间高频 delta 不逐条落盘）。 */
const CONVERSATION_FLUSH_DEBOUNCE_MS: number = 1500;

/** 连接三要素之一不可用时的停机态详情（UI 据此给重试/重新配对入口）。 */
type StartupFailure = 'no-profile' | 'no-token' | 'unreachable' | 'no-workspace';

/** 会话页可观察的对话面（行视图 + 标题 + 是否有流式工作）。 */
export interface ConversationUpdate {
  sessionId: string;
  rows: ConversationRowView[];
  hasLiveWork: boolean;
  title: string;
}

interface SendTextPayload {
  text: string;
}

interface StopPayload {
  expectedForegroundExecutionId?: string;
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

  private profile: ConnectionProfile | null = null;
  private engine: ConnectionEngine | null = null;
  private cache: SessionCache | null = null;
  private readonly sessionsModel = new SessionsIndexModel();
  private readonly conversationModels = new Map<string, ConversationModel>();
  private readonly pendingConversations = new Set<string>();
  private readonly conversationFlushTimers = new Map<string, number>();
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
      }
      return;
    }
    if (frame.topic.startsWith('conversation/')) {
      const sessionId = frame.topic.substring('conversation/'.length);
      const model = this.conversationModels.get(sessionId);
      if (model !== undefined && model.applyFrame(frame)) {
        this.scheduleConversationFlush(sessionId);
        this.fireConversation(sessionId);
      }
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

  async sendText(sessionId: string, text: string): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const payload: SendTextPayload = { text: text };
    await engine.sendCommand(sessionId, 'sendText', payload);
  }

  async stopSession(sessionId: string): Promise<void> {
    const engine = this.engine;
    if (engine === null) {
      throw new Error('未连接');
    }
    const payload: StopPayload = {};
    await engine.sendCommand(sessionId, 'stop', payload);
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
    };
    this.conversationEmitter.fire(update);
  }
}
