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

  /** 只读查询：某轮（target 行）的文件变更与只读 diff hunks。 */
  conversationFileChangesV4(
    params: WorkspaceTarget & {
      sessionId: string;
      target: { rowId: number; entityId: string };
      baseRevision: number;
      baseLogEpoch: string;
    },
  ): Promise<object> {
    return this.call('conversationFileChangesV4', params);
  }

  /** 附件分块上传：begin 声明总量与校验和 → chunk 顺序投喂（≤512KiB/块）→ commit 换 ref。 */
  attachmentBeginV4(params: {
    connectionId: string;
    uploadId: string;
    sessionId: string;
    fileName: string;
    mime: string;
    totalBytes: number;
    totalChunks: number;
    checksum: string;
  }): Promise<object> {
    return this.call('attachmentBeginV4', params);
  }

  attachmentChunkV4(params: {
    connectionId: string;
    uploadId: string;
    sessionId: string;
    chunkIndex: number;
    dataBase64: string;
  }): Promise<object> {
    return this.call('attachmentChunkV4', params);
  }

  attachmentCommitV4(params: { connectionId: string; uploadId: string; sessionId: string }): Promise<object> {
    return this.call('attachmentCommitV4', params);
  }

  attachmentAbortV4(params: { connectionId: string; uploadId: string; sessionId: string }): Promise<void> {
    return this.call('attachmentAbortV4', params);
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

/** IFileService 显式桩（@ 引用的文件搜索；/ws 上与 agent 通道同批暴露）。 */
export const FILE_CHANNEL = 'file';

export interface WorkspaceFileSearchParams {
  rootPath: string;
  workspaceIdentity?: string;
  query: string;
  limit?: number;
  refresh?: boolean;
}

export class WorkspaceFileStub {
  private readonly channel: IChannel;

  constructor(channel: IChannel) {
    this.channel = channel;
  }

  /** Host 端索引检索，返回有界候选（name/path/relativePath/type）。 */
  searchWorkspaceFiles(params: WorkspaceFileSearchParams): Promise<object[]> {
    return this.channel.call<object[]>('searchWorkspaceFiles', [params]);
  }
}
