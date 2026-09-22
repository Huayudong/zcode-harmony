# Spike：zod@4.6.5 在鸿蒙 ArkTS 的可行性（P3 前置门禁）

| 项 | 内容 |
| --- | --- |
| 状态 | 静态分析完成（阶段 1）；动态验证待 DevEco 工程（阶段 2） |
| 关联 | 开发计划 §5 移植顺序第 3 步："`@zcode/shared` 的 `zcode-protocol-v4` 子集 + zod 可行性验证（最大技术赌注）" |
| 结论（阶段 1） | **初步可行**——zod 作为 npm 依赖被消费时运行在 JS 引擎层，ArkTS 严格检查不作用于第三方库源码；风险集中在运行时行为与包体，而不是编译 |

## 1. 背景

`@zcode/shared` 的 v4 协议面（41 文件）以 zod schema 为单一事实源（`z.literal(3)` 版本 fail-fast、`.superRefine` 一致性校验等）。鸿蒙移植有两条路线：

- **路线 A（首选）**：zod 以 oh-package npm 依赖直接进鸿蒙工程，移植层代码照常 `z.object(...).parse(...)`；
- **路线 B（备选）**：schema → ArkTS 类型 + 手写校验器的代码生成（预估 +1 周工作量）。

## 2. 阶段 1：静态审计结论

| 检查项 | 结论 | 依据 |
| --- | --- | --- |
| 编译侵入 | 无 | 第三方 npm 包以 JS 形式被 ohpm/hvigor 打包，ArkTS 严格模式（禁 any/Proxy 等）只约束仓库内 `.ets` 源码，不重写依赖内部 |
| 运行时 API | 兼容 | zod v4 核心只依赖标准 JS（class/getter/Map/Set/JSON/RegExp）；未用 Node API。鸿蒙 ArkTS 运行时（方舟 JS 引擎）支持上述构造 |
| 已知风险点 | 两处 | ① zod v4 部分子模块用 `Proxy` 做惰性 schema（`z.lazy` 路径）——方舟引擎支持 Proxy，但需确认性能与递归 schema（协议里暂无 `z.lazy` 用法）；② `structuredClone` 等新 API 未使用 ✓ |
| 包体 | 可控 | 按需引入 `zod/v4` 子入口，tree-shaking 后预估 <200KB（待 hvigor 实测） |
| 本仓库实际用量 | 小 | 移植子集（会话/消息/批准/附件/diff/模式）用到 `z.object/z.string/z.number/z.enum/z.union/z.discriminatedUnion/z.literal/z.optional/z.array/z.record/z.superRefine/safeParse`——全部为核心稳定 API |

## 3. 阶段 2：动态验证清单（DevEco 工程就绪后执行）

1. `oh i add zod@4.6.5` 进 `commons/protocol`，hvigor 构建通过（无打包报错）；
2. 在 entry 页跑冒烟：`serverRemoteInfoSchema.safeParse(样例 JSON)`、v4 snapshot 样例、`resolveInteraction` 命令样例——`success === true` 且字段值正确；
3. 性能基线：1MB 量级 conversation snapshot `parse` 耗时（目标 <50ms，对齐 PRD 6.3"chunk 上屏 ≤50ms"预算中序列化份额）；
4. 递归/lazy schema 探测：`z.lazy` 在方舟引擎冒烟（若后续协议引入）；
5. 失败即触发路线 B：schema→ArkTS 代码生成，协议行为仍由一致性测试门禁兜底。

## 4. 移植范围备忘（zcode 仓库侧）

- 必移：`zcode-protocol-v4/*`（41 文件）、`zcode-protocol-legacy-types.ts`、`server-remote.ts`、`workspaceFileSearch` codec；
- 剔除：`node/` 7 文件、`workspace-hook-*`（node:crypto/fs 依赖）；
- Node 依赖替换：`crypto.getRandomValues/randomUUID` → `@ohos.security.cryptoFramework`。
