// v4 闭包的 zod 边界迁移（批次6）：
// 1) 所有 v4/*.ts 的 `import { z } from "zod"` 改为 `from "./zod-ambient"`；
// 2) 类型位（z.infer / z.output / z.ZodType / z.ZodError / z.ZodTypeAny / z.ZodDiscriminatedUnion）改写为 any/unknown；
// 3) .ets 消费端不能依赖 zod 推导类型（另行手写本地接口）。
// 依据：ArkTS 编译器无法解析 zod4 d.ts 的复杂泛型，调用点级联报错（452 错中的绝大部分）。
// 运行时不受影响：zod-ambient 在 node/设备两端都返回真 zod 的 z。
// 运行：node tools/migrate-zod-boundary.cjs
const fs = require('fs');
const path = require('path');
const DIR = 'commons/protocol/src/main/ets/v4';

const shim = `/**
 * zod 类型边界（批次6）：ArkTS 编译器无法消费 zod@4 的 .d.ts（复杂泛型在调用点级联报错，
 * 见 docs/specs/a4-session.md §风险）。本文件把 z 的【类型域】收敛为 any：
 * 运行时仍然是真实 zod（node 与设备同包同行为，一致性门禁覆盖）；静态类型仅在本 HAR 内退化。
 * .ets 消费端禁止依赖 zod 推导类型，须手写本地接口。
 */
import * as zodRuntime from 'zod';

export const z: any = (zodRuntime as unknown as { z: object }).z;
`;

fs.writeFileSync(path.join(DIR, 'zod-ambient.ts'), shim);

const typeReplacements = [
  [/z\.infer<[^>]*>/g, 'any'],
  [/z\.output<[^>]*>/g, 'any'],
  [/z\.ZodTypeAny/g, 'unknown'],
  [/z\.ZodType<[^>]*>/g, 'any'],
  [/z\.ZodError/g, 'any'],
  [/z\.ZodDiscriminatedUnion<[^>]*>/g, 'any'],
  [/z\.util\.[\w.$]+/g, 'any'],
];

let filesChanged = 0;
for (const f of fs.readdirSync(DIR)) {
  if (!f.endsWith('.ts') || f === 'zod-ambient.ts') continue;
  const p = path.join(DIR, f);
  let text = fs.readFileSync(p, 'utf8');
  const before = text;
  text = text.replace(/from ["']zod["']/g, 'from "./zod-ambient"');
  for (const [re, to] of typeReplacements) {
    text = text.replace(re, to);
  }
  if (text !== before) {
    fs.writeFileSync(p, text);
    filesChanged += 1;
  }
}
console.log(`migrated ${filesChange = filesChanged} files`);
