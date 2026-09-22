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
  type IMessagePassingProtocol,
  type ISocket
} from './src/main/ets/rpc/Protocol';
