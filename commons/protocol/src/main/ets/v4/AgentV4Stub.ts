/**
 * ZCodeAgent 服务显式 stub（L3）。
 * ES6 Proxy 代理（proxy-channel.toService）在 ArkTS 不可用 → 按计划改为
 * 显式方法桩：call 走方法名 + 参数数组；onDynamic* 动态事件走 listen(事件名, 参数)。
 * 通道名与 server 端 ServiceChannels.ZCodeAgent（"zcode-agent"）一致。
 */

import type { Event } from '../rpc/Foundation.js';
import type { IChannel } from '../rpc/Channels.js';

export const ZCODE_AGENT_CHANNEL = 'zcode-agent';

/** 工作区身份（架构铁律：workspaceIdentity?.trim() || workspacePath）。 */
export interface WorkspaceTarget {
  workspacePath: string;
  workspaceIdentity?: string;
}

export interface SubscribeBase {
  logEpoch: string;
  seq: number;
}

/** 显式服务桩：手机所需 IZCodeAgentService v4 会话面子集。 */
export class ZCodeAgentStub {
  private readonly channel: IChannel;

  constructor(channel: IChannel) {
    this.channel = channel;
  }

  private call<T>(method: string, params: object): Promise<T> {
    // ProxyChannel.fromService 约定：args 为参数数组，服务端按 apply 展开
    return this.channel.call<T>(method, [params]);
  }

  private listenDynamic(event: string, arg: object | null): Event<unknown> {
    // 动态事件约定：arg 原样作为 onDynamicXxx(arg) 的首参（不包数组）
    return this.channel.listen<unknown>(event, arg);
  }

  helloConversationV4(): Promise<object> {
    return this.call<object>('helloConversationV4', {});
  }

  initializeConversationV4(clientHello: object): Promise<void> {
    return this.call<void>('initializeConversationV4', clientHello);
  }

  subscribeSessionsIndexV4(
    params: WorkspaceTarget & { runtimePolicy?: 'start-if-needed' | 'existing-only'; base?: SubscribeBase; visibility?: 'foreground' | 'background' },
  ): Promise<{ ack: { subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string } }> {
    return this.call('subscribeSessionsIndexV4', params);
  }

  resyncSessionsIndexV4(
    params: WorkspaceTarget & { subscriptionId: string; base: SubscribeBase | null; runtimePolicy?: 'start-if-needed' | 'existing-only'; forceSnapshot?: boolean },
  ): Promise<{ ack: { subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string } }> {
    return this.call('resyncSessionsIndexV4', params);
  }

  unsubscribeSessionsIndexV4(
    params: WorkspaceTarget & { subscriptionId: string; runtimePolicy?: 'start-if-needed' | 'existing-only' },
  ): Promise<void> {
    return this.call('unsubscribeSessionsIndexV4', params);
  }

  subscribeConversationV4(
    params: WorkspaceTarget & { sessionId: string; runtimePolicy?: 'start-if-needed' | 'existing-only'; base?: SubscribeBase; visibility?: 'foreground' | 'background' },
  ): Promise<{ ack: { subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string } }> {
    return this.call('subscribeConversationV4', params);
  }

  resyncConversationV4(
    params: WorkspaceTarget & { sessionId: string; subscriptionId: string; base: SubscribeBase | null; runtimePolicy?: 'start-if-needed' | 'existing-only'; forceSnapshot?: boolean },
  ): Promise<{ ack: { subscriptionId: string; mode: 'snapshot' | 'resume'; logEpoch: string } }> {
    return this.call('resyncConversationV4', params);
  }

  unsubscribeConversationV4(
    params: WorkspaceTarget & { sessionId: string; subscriptionId: string; runtimePolicy?: 'start-if-needed' | 'existing-only' },
  ): Promise<void> {
    return this.call('unsubscribeConversationV4', params);
  }

  conversationRowsRangeV4(
    params: WorkspaceTarget & { sessionId: string; beforeRowId?: number; limit: number },
  ): Promise<object> {
    return this.call('conversationRowsRangeV4', params);
  }

  sendConversationCommandV4(
    params: WorkspaceTarget & { envelope: object },
  ): Promise<object> {
    return this.call('sendConversationCommandV4', params);
  }

  queryConversationCommandsV4(
    params: WorkspaceTarget & { commands: Array<{ sessionId: string | null; commandId: string }> },
  ): Promise<object> {
    return this.call('queryConversationCommandsV4', params);
  }

  /** workspace 级下行帧流（v4/conversation/frame），按 topic 前缀自行分流。 */
  onDynamicConversationFrame(target: WorkspaceTarget): Event<unknown> {
    return this.listenDynamic('onDynamicConversationFrame', target);
  }

  /** workspace 级 sessions-index 下行帧流（同一通知，按 topic 前缀分流）。 */
  onDynamicSessionsIndexFrame(target: WorkspaceTarget): Event<unknown> {
    return this.listenDynamic('onDynamicSessionsIndexFrame', target);
  }
}
