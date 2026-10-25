// '@ohos.util' 的 node 侧替身（仅一致性门禁用，不入设备构建）。
// 背景：批次20 起 rpc/Buffer.ts 的 UTF-8 编解码走 @ohos.util（ArkTS 运行时无 Web TextEncoder）；
// node 侧用 node:util 的同名实现顶替，编码字节语义一致。
import { TextEncoder as NodeTextEncoder, TextDecoder as NodeTextDecoder } from 'node:util';

class OhosTextDecoder {
  private readonly decoder: NodeTextDecoder;

  constructor(encoding: string = 'utf-8') {
    this.decoder = new NodeTextDecoder(encoding);
  }

  static create(encoding: string = 'utf-8'): OhosTextDecoder {
    return new OhosTextDecoder(encoding);
  }

  decodeToString(bytes: Uint8Array): string {
    return this.decoder.decode(bytes);
  }
}

export default {
  TextEncoder: NodeTextEncoder,
  TextDecoder: OhosTextDecoder,
};
