/**
 * zod 类型边界（批次6）：ArkTS 编译器无法消费 zod@4 的 .d.ts（复杂泛型在调用点级联报错，
 * 见 docs/specs/a4-session.md §风险）。本文件把 z 的【类型域】收敛为 any：
 * 运行时仍然是真实 zod（node 与设备同包同行为，一致性门禁覆盖）；静态类型仅在本 HAR 内退化。
 * .ets 消费端禁止依赖 zod 推导类型，须手写本地接口。
 */
import * as zodRuntime from 'zod';

export const z: any = (zodRuntime as unknown as { z: object }).z;
