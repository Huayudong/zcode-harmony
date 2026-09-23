/**
 * AgentV4Client —— WSS 之上的 v4 会话编排（L3，纯逻辑可 node 单测）。
 *
 * 职责：握手（hello 版本 fail-fast → clientHello mobileApp）→ 订阅
 * （sessions-index / conversation）→ 下行 wire 候选帧装配 → 逻辑帧分发与
 * 水位记账 → same-sub resync。桌面端的 ackActivationBarrier/topicWireDecoder
 * 在此收敛为一个更小的 pre-ACK 缓冲：ACK 前到达的帧按 (topic) 缓冲，
 * subscribe/resync 返回后按序放行——帧与 ACK 走同一有序信道，语义一致。
 */

import { ChannelClient } from '../rpc/ChannelClient.js';
import type { IMessagePassingProtocol } from '../rpc/Protocol.js';
import {
  helloMessageSchema,
  sessionsIndexTopicFrameSchema,
  conversationTopicFrameSchema,
  type HelloMessage,
  type SessionsIndexTopicFrame,
  type ConversationTopicFrame,
} from './transport.js';
import { V4_WIRE_PROTOCOL_VERSION } from './core.js';
import { TopicWireFrameAssembler, type TopicWireAssemblyEvent } from './wire-assembler.js';
import type { TopicWireFrameCandidate } from './wire.js';
import { commandAckSchema, commandEnvelopeSchema, type CommandAck, type CommandEnvelope } from './command.js';
import { ZCodeAgentStub, ZCODE_AGENT_CHANNEL, type SubscribeBase, type WorkspaceTarget } from './AgentV4Stub.js';

export { ZCODE_AGENT_CHANNEL } from './AgentV4Stub.js';
export type { WorkspaceTarget, SubscribeBase } from './AgentV4Stub.js';

export interface AgentV4ConnectOptions {
  /** 客户端持久化 id（设备侧由 @ohos.util.generateRandomUUID 生成并落 preferences）。 */
  clientId: string;
  appVersion: string;
}

export type TopicKind = 'sessions-index' | 'conversation';

export interface SubscriptionWatermark {
  topic: string;
  subscriptionId: string;
  logEpoch: string;
  lastSeq: number;
}

/** .ets 消费端可见的具体帧形状（zod 推导类型在 ArkTS 侧已按 any 边界处理）。 */
export interface V4TopicFrame {
  topic: string;
  subscriptionId: string;
  fromSeq: number;
  toSeq: number;
  payload: object;
}

export interface V4Fault {
  topic: string;
  subscriptionId: string;
  reasonCode: string;
}

type FrameListener = (frame: V4TopicFrame) => void;
type FaultListener = (fault: V4Fault) => void;

interface SubState {
  kind: TopicKind;
  topic: string;
  subscriptionId: string | null;
  logEpoch: string | null;
  lastSeq: number;
  /** ACK 前缓冲的装配事件（complete），bind 时按序放行。 */
  buffered: TopicWireAssemblyEvent<V4TopicFrame>[];
}

function topicOf(kind: TopicKind, target: WorkspaceTarget, sessionId?: string): string {
  if (kind === 'conversation') {
    return `conversation/${sessionId ?? ''}`;
  }
  return `sessions-index/${target.workspaceIdentity?.trim() || target.workspacePath}`;
}

export class AgentV4Client {
  readonly hello: HelloMessage;
  private readonly stub: ZCodeAgentStub;
  private readonly channelClient: ChannelClient;
  private readonly target: WorkspaceTarget;
  private readonly sessionsIndexAssembler = new TopicWireFrameAssembler<SessionsIndexTopicFrame>(
    sessionsIndexTopicFrameSchema,
  );
  private readonly conversationAssembler = new TopicWireFrameAssembler<ConversationTopicFrame>(
    conversationTopicFrameSchema,
  );
  /** key = subscriptionId；orphan 缓冲 key = "orphan:<topic>"。 */
  private readonly subs = new Map<string, SubState>();
  private readonly frameListeners = new Set<FrameListener>();
  private readonly faultListeners = new Set<FaultListener>();
  private readonly upstreamEvents: Array<{ dispose(): void }> = [];
  private closed = false;

  private constructor(
    channelClient: ChannelClient,
    stub: ZCodeAgentStub,
    hello: HelloMessage,
    target: WorkspaceTarget,
  ) {
    this.channelClient = channelClient;
    this.stub = stub;
    this.hello = hello;
    this.target = target;
  }

  /** 连接 + 握手：hello 解析失败/协议版本不符即 fail-fast。 */
  static async connect(
    protocol: IMessagePassingProtocol,
    target: WorkspaceTarget,
    options: AgentV4ConnectOptions,
  ): Promise<AgentV4Client> {
    const channelClient = new ChannelClient(protocol);
    const stub = new ZCodeAgentStub(channelClient.getChannel(ZCODE_AGENT_CHANNEL));
    const helloRaw = await stub.helloConversationV4();
    const hello = helloMessageSchema.parse(helloRaw);
    await stub.initializeConversationV4({
      kind: 'clientHello',
      protocolVersion: V4_WIRE_PROTOCOL_VERSION,
      clientId: options.clientId,
      clientKind: 'mobileApp',
      appVersion: options.appVersion,
      capabilities: { workspaceHookReviewUi: true },
    });
    const client = new AgentV4Client(channelClient, stub, hello, target);
    // workspace 级帧流订阅（两条通知面，按 topic 前缀分流）
    client.upstreamEvents.push(
      client.stub.onDynamicSessionsIndexFrame(target)((wire: unknown) => client.acceptWire('sessions-index', wire)),
      client.stub.onDynamicConversationFrame(target)((wire: unknown) => client.acceptWire('conversation', wire)),
    );
    return client;
  }

  /** 下行逻辑帧监听（已通过 schema 校验并按 ordinal 去重）。 */
  onFrame(listener: FrameListener): { dispose(): void } {
    this.frameListeners.add(listener);
    return {
      dispose: () => {
        this.frameListeners.delete(listener);
      },
    };
  }

  /** 装配故障监听（typed fault：checksum/UTF-8/JSON/schema/ordinal 冲突）。 */
  onFault(listener: FaultListener): { dispose(): void } {
    this.faultListeners.add(listener);
    return {
      dispose: () => {
        this.faultListeners.delete(listener);
      },
    };
  }

  /** 当前活跃订阅的水位（断线重连续传依据）。 */
  watermarks(): SubscriptionWatermark[] {
    const out: SubscriptionWatermark[] = [];
    for (const sub of this.subs.values()) {
      if (sub.subscriptionId !== null && sub.logEpoch !== null) {
        out.push({
          topic: sub.topic,
          subscriptionId: sub.subscriptionId,
          logEpoch: sub.logEpoch,
          lastSeq: sub.lastSeq,
        });
      }
    }
    return out;
  }

  async subscribeSessionsIndex(params?: {
    base?: SubscribeBase;
    visibility?: 'foreground' | 'background';
  }): Promise<{ subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string }> {
    const result = await this.stub.subscribeSessionsIndexV4({
      workspacePath: this.target.workspacePath,
      ...(this.target.workspaceIdentity ? { workspaceIdentity: this.target.workspaceIdentity } : {}),
      runtimePolicy: 'existing-only',
      ...(params?.base ? { base: params.base } : {}),
      ...(params?.visibility ? { visibility: params.visibility } : {}),
    });
    this.bindSubscription('sessions-index', topicOf('sessions-index', this.target), result.ack);
    return result.ack;
  }

  async subscribeConversation(sessionId: string, params?: {
    base?: SubscribeBase;
    visibility?: 'foreground' | 'background';
  }): Promise<{ subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string }> {
    const result = await this.stub.subscribeConversationV4({
      workspacePath: this.target.workspacePath,
      ...(this.target.workspaceIdentity ? { workspaceIdentity: this.target.workspaceIdentity } : {}),
      sessionId,
      runtimePolicy: 'start-if-needed',
      ...(params?.base ? { base: params.base } : {}),
      ...(params?.visibility ? { visibility: params.visibility } : {}),
    });
    this.bindSubscription('conversation', topicOf('conversation', this.target, sessionId), result.ack);
    return result.ack;
  }

  /**
   * same-sub 恢复（断线重连后调用）。
   * base=null 或 forceSnapshot=true 时服务端回全量快照，本地水位由帧流水线重建。
   */
  async resync(kind: TopicKind, subscriptionId: string, base: SubscribeBase | null, forceSnapshot?: boolean): Promise<{ subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string }> {
    const sub = this.subs.get(subscriptionId) ?? null;
    const sessionId = kind === 'conversation'
      ? (sub !== null && sub.topic.startsWith('conversation/') ? sub.topic.slice('conversation/'.length) : null)
      : null;
    if (kind === 'conversation' && sessionId === null) {
      return Promise.reject(new Error('resync(conversation) 需要本客户端已绑定的会话订阅'));
    }
    if (sub) {
      sub.buffered = [];
    }
    const topic = sub ? sub.topic : topicOf('sessions-index', this.target);
    const common = {
      workspacePath: this.target.workspacePath,
      ...(this.target.workspaceIdentity ? { workspaceIdentity: this.target.workspaceIdentity } : {}),
      subscriptionId,
      base,
      ...(forceSnapshot !== undefined ? { forceSnapshot } : {}),
    };
    const result = kind === 'conversation'
      ? await this.stub.resyncConversationV4({ ...common, sessionId, runtimePolicy: 'start-if-needed' })
      : await this.stub.resyncSessionsIndexV4({ ...common, runtimePolicy: 'existing-only' });
    this.bindSubscription(kind, topic, result.ack);
    return result.ack;
  }

  /** 幂等命令提交（commandId 客户端生成，重试不变）。 */
  async sendCommand(envelope: CommandEnvelope): Promise<CommandAck> {
    const parsed = commandEnvelopeSchema.safeParse(envelope);
    if (!parsed.success) {
      throw new Error(`command envelope invalid: ${parsed.error.issues[0]?.message ?? 'unknown'}`);
    }
    const raw = await this.stub.sendConversationCommandV4({
      workspacePath: this.target.workspacePath,
      ...(this.target.workspaceIdentity ? { workspaceIdentity: this.target.workspaceIdentity } : {}),
      envelope,
    });
    return commandAckSchema.parse(raw);
  }

  /** 有序关闭：取消所有事件上游并释放通道客户端。 */
  close(reason?: Error): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    for (const up of this.upstreamEvents) {
      up.dispose();
    }
    this.frameListeners.clear();
    this.faultListeners.clear();
    this.subs.clear();
    this.channelClient.dispose(reason);
  }

  /** ACK 返回后绑定订阅代际并放行 pre-ACK 缓冲帧。 */
  private bindSubscription(kind: TopicKind, topic: string, ack: { subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string }): void {
    // 孤儿缓冲（ACK 未返回前到达的帧）并入新订阅
    const orphanKey = `orphan:${topic}`;
    const orphan = this.subs.get(orphanKey);
    if (orphan) {
      this.subs.delete(orphanKey);
    }
    let sub = this.subs.get(ack.subscriptionId);
    if (!sub) {
      sub = {
        kind,
        topic,
        subscriptionId: ack.subscriptionId,
        logEpoch: ack.logEpoch,
        lastSeq: 0,
        buffered: orphan ? orphan.buffered : [],
      };
    } else {
      sub.logEpoch = ack.logEpoch;
      if (orphan) {
        sub.buffered.push(...orphan.buffered);
      }
    }
    this.subs.set(ack.subscriptionId, sub);
    // 代际更换：同 topic 旧订阅已由新 ack 取代，删除旧键
    for (const [key, other] of [...this.subs.entries()]) {
      if (key !== ack.subscriptionId && other.topic === topic && other.kind === kind) {
        this.subs.delete(key);
      }
    }
    const buffered = sub.buffered;
    sub.buffered = [];
    for (const event of buffered) {
      this.deliverAssembly(sub, event);
    }
  }

  private acceptWire(kind: TopicKind, wire: unknown): void {
    if (this.closed) {
      return;
    }
    const candidate = wire as TopicWireFrameCandidate;
    if (!candidate || typeof candidate !== 'object' || typeof candidate.topic !== 'string') {
      return;
    }
    const topic: string = candidate.topic;
    const assembler = kind === 'conversation' ? this.conversationAssembler : this.sessionsIndexAssembler;
    let events: TopicWireAssemblyEvent<V4TopicFrame>[];
    try {
      events = assembler.accept(candidate);
    } catch {
      // 防御：坏候选不允许打穿帧流
      return;
    }
    for (const event of events) {
      if (event.kind === 'fault') {
        for (const listener of this.faultListeners) {
          listener({ topic: event.fault.topic, subscriptionId: event.fault.subscriptionId, reasonCode: event.fault.reasonCode });
        }
        continue;
      }
      const sub = this.subs.get(event.frame.subscriptionId);
      if (sub) {
        this.deliverAssembly(sub, event);
        continue;
      }
      // 未绑定代际：按 topic 缓冲，bind 时放行；无法归类的直接丢弃
      if (isTopicOf(kind, topic, event.frame)) {
        this.bufferOrphan(kind, topic).buffered.push(event);
      }
    }
  }

  private deliverAssembly(sub: SubState, event: TopicWireAssemblyEvent<V4TopicFrame>): void {
    if (event.kind === 'fault') {
      for (const listener of this.faultListeners) {
        listener({ topic: event.fault.topic, subscriptionId: event.fault.subscriptionId, reasonCode: event.fault.reasonCode });
      }
      return;
    }
    if (event.frame.toSeq > sub.lastSeq) {
      sub.lastSeq = event.frame.toSeq;
    }
    for (const listener of this.frameListeners) {
      listener(event.frame);
    }
  }

  private findSubByTopic(kind: TopicKind, topic: string): SubState | null {
    for (const sub of this.subs.values()) {
      if (sub.kind === kind && sub.topic === topic) {
        return sub;
      }
    }
    return null;
  }

  private bufferOrphan(kind: TopicKind, topic: string): SubState {
    const key = `orphan:${topic}`;
    let sub = this.subs.get(key);
    if (!sub) {
      sub = { kind, topic, subscriptionId: null, logEpoch: null, lastSeq: 0, buffered: [] };
      this.subs.set(key, sub);
    }
    return sub;
  }
}

function isTopicOf(kind: TopicKind, topic: string, frame: V4TopicFrame): boolean {
  return frame.topic === topic || (kind === 'conversation' ? topic.startsWith('conversation/') : topic.startsWith('sessions-index/'));
}
