/**
 * Channel 共享词汇（@zcode/rpc channels.shared.ts 的鸿蒙移植，L2）。
 * 手机端是纯客户端：只移植请求/响应词表与 IChannel 客户端面；
 * IServerChannel/ChannelServer 属桌面 host，不在移植范围。
 */

import type { CancellationToken, Event } from './Foundation.js';

export interface IChannel {
  call<T>(command: string, arg?: object | null, cancellationToken?: CancellationToken): Promise<T>;
  listen<T>(event: string, arg?: object | null): Event<T>;
}

// const enum → 普通对象常量（ArkTS 不支持 const enum）。
export const RequestType = {
  Promise: 100,
  PromiseCancel: 101,
  EventListen: 102,
  EventDispose: 103,
} as const;
export type RequestType = (typeof RequestType)[keyof typeof RequestType];

export const ResponseType = {
  Initialize: 200,
  PromiseSuccess: 201,
  PromiseError: 202,
  PromiseErrorObj: 203,
  EventFire: 204,
} as const;
export type ResponseType = (typeof ResponseType)[keyof typeof ResponseType];

/** PromiseError 携带的结构化远端错误（错误白名单键，原包 channelClient.ts 同款）。 */
export interface IRemoteErrorData {
  message: string;
  name: string;
  stack: string[] | undefined;
  code?: unknown;
  kind?: unknown;
  status?: unknown;
  retryAfterMs?: unknown;
  data?: unknown;
  detail?: unknown;
  details?: unknown;
  taskId?: unknown;
  traceId?: unknown;
}

export type IRawResponse =
  | { type: typeof ResponseType.Initialize }
  | { type: typeof ResponseType.PromiseSuccess; id: number; data: object | null }
  | { type: typeof ResponseType.PromiseError; id: number; data: IRemoteErrorData }
  | { type: typeof ResponseType.PromiseErrorObj; id: number; data: object | null }
  | { type: typeof ResponseType.EventFire; id: number; data: object | null };

export type IHandler = (response: IRawResponse) => void;

export interface IChannelClient {
  getChannel<T extends IChannel>(channelName: string): T;
}
