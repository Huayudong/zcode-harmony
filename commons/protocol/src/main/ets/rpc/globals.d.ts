/**
 * 纯 TS 层（rpc/）的运行时全局：node 与 ArkTS 运行时都提供 Web 标准的
 * TextEncoder/TextDecoder，但 ArkTS 编译的默认 lib 不含 DOM 类型，这里给出最小声明。
 */

declare const TextEncoder: {
  new (): { encode(input: string): Uint8Array };
};

declare const TextDecoder: {
  new (): { decode(input: Uint8Array): string };
};
