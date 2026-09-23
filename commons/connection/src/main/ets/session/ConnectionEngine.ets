/**
 * ConnectionEngine —— A4 重连引擎（开发计划 §1.4 状态机的落地）。
 *
 * [offline] ──start()──▶ [connecting] ──WSS 握手+hello 成功──▶ [online]
 *    ▲                        │ 失败
 *    └──── stop() 用户手动 ── [backoff] 1s→2s→4s→…→30s（指数退避）◀──┘
 *                               │ 网络恢复事件抢先取消定时器 → 立即重试
 *
 * 不变量（plan §1.4 / CONN-3）：
 * - 断线恢复用「带水位重订阅」：重连后 subscribe(base={logEpoch,seq})，
 *   服务端按水位回 snapshot 或 resume 增量——与 same-sub resync 同语义，
 *   且 (connectionId, topic) 重订替换是服务端已定义的行为。
 * - 重连期间不发送新 command：一律入队（幂等 commandId），online 后按序 flush；
 *   服务端 CommandInbox 按 commandId 去重，重复 ACK（duplicate）视为送达。
 * - 状态所有者：每档案一个 engine；M1 单活连接（PRD Q2）。
 */
import connection from '@ohos.net.connection';
import util from '@ohos.util';
import {
  AgentV4Client,
  PendingCommandQueue,
  SocketProtocol,
  type SubscribeBase,
  type V4Fault,
  type V4TopicFrame,
  type WorkspaceTarget,
} from 'protocol';
import { Emitter, type Event, type IDisposable } from 'protocol';
import { WebSocketTransport } from '../ws/WebSocketTransport';
import { PinnedHttpTarget } from '../http/PinnedHttpClient';

export type ConnectionState = 'offline' | 'connecting' | 'online' | 'backoff';

export interface ConnectionStateEvent {
  state: ConnectionState;
  /** 面向用户的简述（失败原因/下一次重试等待）。 */
  detail: string;
}

export interface EngineOptions {
  target: WorkspaceTarget;
  bearerToken: string;
  /** HTTP 目标（host/port/caPem），决定 ws/wss 与证书固定。 */
  target_http: PinnedHttpTarget;
  /** 沙箱内 CA 文件路径（caPem 非空时必填）。 */
  caFilePath: string;
  /** 客户端持久 id（preferences 落盘，重装前不变）。 */
  clientId: string;
  appVersion: string;
}

/** v4 命令信封（.ets 侧本地形状；协议侧 schema 校验由一致性门禁覆盖）。 */
interface EngineCommandEnvelope {
  commandId: string;
  clientId: string;
  sessionId: string | null;
  type: CommandType;
  payload: object;
  issuedAt: number;
}

/** v4 命令词表（本批使用面；OUT-4 批准时扩展 resolveInteraction）。 */
export type CommandType = 'sendText' | 'stop';

const BACKOFF_SCHEDULE_MS: number[] = [1000, 2000, 4000, 8000, 15000, 30000];

export class ConnectionEngine {
  private readonly options: EngineOptions;
  private readonly queue = new PendingCommandQueue();
  private readonly stateEmitter = new Emitter<ConnectionStateEvent>();
  private readonly frameEmitter = new Emitter<V4TopicFrame>();
  private readonly faultEmitter = new Emitter<V4Fault>();

  private state: ConnectionState = 'offline';
  private client: AgentV4Client | null = null;
  private transport: WebSocketTransport | null = null;
  private clientUpstreams: IDisposable[] = [];

  /** topic → 最近确认水位（跨重连保留；epoch 由订阅 ACK 覆盖）。 */
  private readonly watermarks = new Map<string, SubscribeBase>();
  /** 已激活会话订阅（重连后重订）。 */
  private readonly activeConversations = new Set<string>();
  private sessionsIndexActive = false;

  private attempts = 0;
  private backoffTimer: number | null = null;
  private manualStop = false;
  private netConnection: connection.NetConnection | null = null;

  constructor(options: EngineOptions) {
    this.options = options;
  }

  // ── 事件面 ──
  get onStateChange(): Event<ConnectionStateEvent> {
    return this.stateEmitter.event;
  }

  get onFrame(): Event<V4TopicFrame> {
    return this.frameEmitter.event;
  }

  get onFault(): Event<V4Fault> {
    return this.faultEmitter.event;
  }

  /** 最近确认水位快照（诊断用）。 */
  currentWatermarks(): SubscribeBase[] {
    const out: SubscribeBase[] = [];
    this.watermarks.forEach((base: SubscribeBase) => out.push(base));
    return out;
  }

  getState(): ConnectionState {
    return this.state;
  }

  get pendingCommandCount(): number {
    return this.queue.size;
  }

  // ── 生命周期 ──

  /** 启动并注册网络恢复事件（CONN-3：网络恢复抢先退避定时器立即重试）。 */
  start(): void {
    this.manualStop = false;
    this.registerNetworkWatch();
    void this.connectNow();
  }

  /** 用户手动停止：进 offline 且不再自动重试。 */
  stop(): void {
    this.manualStop = true;
    this.cancelBackoff();
    this.teardownTransport();
    this.setState('offline', '已断开');
  }

  private registerNetworkWatch(): void {
    if (this.netConnection !== null) {
      return;
    }
    const netConnection = connection.createNetConnection();
    netConnection.on('netAvailable', () => {
      if (this.state === 'backoff') {
        this.cancelBackoff();
        void this.connectNow();
      }
    });
    netConnection.register(() => {
      // 注册完成即可，无 netHandle 用途
    });
    this.netConnection = netConnection;
  }

  private unregisterNetworkWatch(): void {
    if (this.netConnection !== null) {
      this.netConnection.unregister(() => {});
      this.netConnection = null;
    }
  }

  private setState(state: ConnectionState, detail: string): void {
    this.state = state;
    const event: ConnectionStateEvent = { state: state, detail: detail };
    this.stateEmitter.fire(event);
  }

  private cancelBackoff(): void {
    if (this.backoffTimer !== null) {
      clearTimeout(this.backoffTimer);
      this.backoffTimer = null;
    }
  }

  private scheduleBackoff(): void {
    if (this.manualStop) {
      this.setState('offline', '已断开');
      return;
    }
    const index = Math.min(this.attempts, BACKOFF_SCHEDULE_MS.length - 1);
    const delay = BACKOFF_SCHEDULE_MS[index];
    this.attempts += 1;
    this.setState('backoff', `${Math.round(delay / 1000)} 秒后重试`);
    this.cancelBackoff();
    this.backoffTimer = setTimeout(() => {
      this.backoffTimer = null;
      void this.connectNow();
    }, delay);
  }

  /** 单次连接尝试（WSS → v4 握手 → 重订阅 → flush 命令队列）。 */
  private async connectNow(): Promise<void> {
    if (this.manualStop) {
      return;
    }
    this.setState('connecting', '正在连接');
    let transport: WebSocketTransport | null = null;
    try {
      transport = new WebSocketTransport();
      await transport.connect(this.options.target_http, this.options.bearerToken, this.options.caFilePath);

      // 与 web 客户端同链路：SocketProtocol（13 字节分帧）直连 /ws；
      // 可靠性由 v4 水位重订阅（snapshot/resume）承担，PersistentProtocol 不在此链路。
      const protocol = new SocketProtocol(transport);
      const client = await AgentV4Client.connect(protocol, this.options.target, {
        clientId: this.options.clientId,
        appVersion: this.options.appVersion,
      });

      this.transport = transport;
      this.client = client;
      this.attempts = 0;

      // 帧流水线：更新水位 → 转发
      this.clientUpstreams.push(client.onFrame((frame: V4TopicFrame) => {
        this.recordWatermark(frame);
        this.frameEmitter.fire(frame);
      }));
      this.clientUpstreams.push(client.onFault((fault: V4Fault) => {
        this.faultEmitter.fire(fault);
      }));

      await this.resubscribeAll();
      await this.flushQueue();
      this.setState('online', '已连接');
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      // 半建状态一并回收（客户端可能未建完，socket 必须先关）
      if (transport !== null) {
        transport.dispose();
      }
      this.client = null;
      this.transport = null;
      this.scheduleBackoff();
    }
  }

  private handleDrop(detail: string): void {
    void detail;
    this.teardownTransport();
    if (this.manualStop) {
      this.setState('offline', '已断开');
      return;
    }
    this.scheduleBackoff();
  }

  private teardownTransport(): void {
    for (const up of this.clientUpstreams) {
      up.dispose();
    }
    this.clientUpstreams = [];
    if (this.client !== null) {
      this.client.close();
      this.client = null;
    }
    if (this.transport !== null) {
      this.transport.dispose();
      this.transport = null;
    }
  }

  // ── 订阅与水位 ──

  private recordWatermark(frame: V4TopicFrame): void {
    const known = this.watermarks.get(frame.topic);
    const seq = known !== undefined && known.seq > frame.toSeq ? known.seq : frame.toSeq;
    const base: SubscribeBase = { logEpoch: known !== undefined ? known.logEpoch : '', seq: seq };
    this.watermarks.set(frame.topic, base);
  }

  private baseFor(topic: string): SubscribeBase | undefined {
    const base = this.watermarks.get(topic);
    // epoch 为空说明从未收到过 ACK，不能声明水位
    return base !== undefined && base.logEpoch.length > 0 ? base : undefined;
  }

  /** 订阅 sessions-index（重连后带水位 → 服务端可回 resume 增量）。 */
  async subscribeSessionsIndex(): Promise<string> {
    if (this.client === null) {
      throw new Error('未连接');
    }
    const topic = `sessions-index/${this.options.target.workspaceIdentity?.trim() || this.options.target.workspacePath}`;
    const base = this.baseFor(topic);
    const ack = base !== undefined
      ? await this.client.subscribeSessionsIndex({ base: base, visibility: 'foreground' })
      : await this.client.subscribeSessionsIndex({ visibility: 'foreground' });
    this.watermarks.set(topic, { logEpoch: ack.logEpoch, seq: this.watermarks.get(topic)?.seq ?? 0 });
    this.sessionsIndexActive = true;
    return ack.subscriptionId;
  }

  /** 订阅会话 topic（工作台打开会话页时调用；A5 消费）。 */
  async subscribeConversation(sessionId: string): Promise<string> {
    if (this.client === null) {
      throw new Error('未连接');
    }
    const topic = `conversation/${sessionId}`;
    const base = this.baseFor(topic);
    const ack = base !== undefined
      ? await this.client.subscribeConversation(sessionId, { base: base, visibility: 'foreground' })
      : await this.client.subscribeConversation(sessionId, { visibility: 'foreground' });
    this.watermarks.set(topic, { logEpoch: ack.logEpoch, seq: this.watermarks.get(topic)?.seq ?? 0 });
    this.activeConversations.add(sessionId);
    return ack.subscriptionId;
  }

  /** 重连后的重订（带水位：服务端 snapshot 或 resume）。 */
  private async resubscribeAll(): Promise<void> {
    if (this.client === null) {
      return;
    }
    if (this.sessionsIndexActive) {
      await this.subscribeSessionsIndex();
    }
    const sessionIds: string[] = [];
    this.activeConversations.forEach((sessionId: string) => sessionIds.push(sessionId));
    for (const sessionId of sessionIds) {
      await this.subscribeConversation(sessionId);
    }
  }

  // ── 命令面（幂等排队）──

  /** 发送命令；非 online 或发送失败时入队，重连后按序 flush（commandId 幂等）。 */
  async sendCommand(sessionId: string, type: CommandType, payload: object): Promise<void> {
    const envelope: EngineCommandEnvelope = {
      commandId: util.generateRandomUUID(),
      clientId: this.options.clientId,
      sessionId: sessionId.length > 0 ? sessionId : null,
      type: type,
      payload: payload,
      issuedAt: Date.now(),
    };
    await this.deliverOrQueue(envelope);
  }

  private async deliverOrQueue(envelope: EngineCommandEnvelope): Promise<void> {
    if (this.state !== 'online' || this.client === null) {
      this.queue.enqueue(envelope);
      return;
    }
    try {
      await this.client.sendCommand(envelope);
    } catch {
      // 发送失败（含断线竞态）：入队，重连后重发（同一 commandId 幂等）
      this.queue.enqueue(envelope);
    }
  }

  private async flushQueue(): Promise<void> {
    if (this.client === null) {
      return;
    }
    const items = this.queue.peekAll();
    for (const item of items) {
      try {
        this.queue.markAttempt(item.envelope.commandId);
        await this.client.sendCommand(item.envelope);
        this.queue.settle(item.envelope.commandId);
      } catch {
        // 单条失败留在队列，下一轮重连再试
        break;
      }
    }
  }

  /** 会话结束后的订阅收缩（A5 会话页关闭时调用）。 */
  unsubscribeConversation(sessionId: string): void {
    this.activeConversations.delete(sessionId);
    this.watermarks.delete(`conversation/${sessionId}`);
  }
}
