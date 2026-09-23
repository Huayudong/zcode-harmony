export { VSBuffer } from './src/main/ets/rpc/Buffer';
export {
  BufferReader,
  BufferWriter,
  serialize,
  deserialize,
  type IReader,
  type IWriter
} from './src/main/ets/rpc/Serialization';
export {
  Emitter,
  DisposableStore,
  toDisposable,
  CancellationToken,
  eventToPromise,
  type IDisposable,
  type Event
} from './src/main/ets/rpc/Foundation';
export {
  ChunkStream,
  SocketProtocol,
  ProtocolMessage,
  ProtocolMessageType,
  HEADER_SIZE,
  createQueuePair,
  writeProtocolMessage,
  ConnectionFlowControl,
  type IMessagePassingProtocol,
  type ISocket
} from './src/main/ets/rpc/Protocol';
export {
  PersistentProtocol,
  type PersistentProtocolOptions
} from './src/main/ets/rpc/PersistentProtocol';
export {
  RequestType,
  ResponseType,
  type IChannel,
  type IChannelClient,
  type IRemoteErrorData,
  type IRawResponse
} from './src/main/ets/rpc/Channels';
export { ChannelClient } from './src/main/ets/rpc/ChannelClient';
export {
  ZCODE_AGENT_CHANNEL,
  ZCodeAgentStub,
  type WorkspaceTarget,
  type SubscribeBase
} from './src/main/ets/v4/AgentV4Stub';
export {
  AgentV4Client,
  type AgentV4ConnectOptions,
  type TopicKind,
  type SubscriptionWatermark,
  type V4TopicFrame,
  type V4Fault
} from './src/main/ets/v4/AgentV4Client';
export { PendingCommandQueue, type QueuedCommand } from './src/main/ets/v4/PendingCommandQueue';
export {
  V4_WIRE_PROTOCOL_VERSION,
  PROTOCOL_V4_LIMITS
} from './src/main/ets/v4/core';
export {
  helloMessageSchema,
  clientHelloSchema,
  subscribeParamsSchema,
  subscribeAckSchema,
  sessionsIndexTopicFrameSchema,
  conversationTopicFrameSchema
} from './src/main/ets/v4/transport';
export { createTopicWireFrameSchema, topicWireFrameCandidateSchema } from './src/main/ets/v4/wire';
export {
  sessionsIndexTopic,
  parseSessionsIndexTopic
} from './src/main/ets/v4/sessions-index';
export {
  conversationTopic,
  parseConversationTopic
} from './src/main/ets/v4/transport';
export {
  sessionsIndexSnapshotSchema,
  sessionsIndexDeltaSchema,
  sessionSummarySchema
} from './src/main/ets/v4/sessions-index';
export {
  conversationRowSchema
} from './src/main/ets/v4/rows';
export { conversationDeltaSchema, statePatchSchema } from './src/main/ets/v4/delta';
export {
  applyConversationDelta,
  applyConversationDeltas,
  createMutableConversationSnapshotAccumulator,
  applyConversationDeltaMutable,
  applyConversationDeltasMutable
} from './src/main/ets/v4/apply';
export {
  coalesceConversationDeltas,
  conflateByKey
} from './src/main/ets/v4/coalesce';
export {
  commandEnvelopeSchema,
  commandAckSchema,
  parseCommandEnvelope
} from './src/main/ets/v4/command';
export { TopicWireFrameAssembler } from './src/main/ets/v4/wire-assembler';
export { crc32WireBytes, encodeWireBytesBase64, decodeWireBase64 } from './src/main/ets/v4/wire-binary';
