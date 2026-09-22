# ZCode Harmony

ZCode 本地 Server 的鸿蒙原生遥控工作台：AI Agent 在你自己的电脑上执行，手机/平板随时接手控制——批准工具调用、审查代码 diff、推进任务，数据全程不出本机。

对应产品文档：`zcode` 仓库 `docs/PRD-ZCode-Harmony.md`；开发计划与批次记录：`docs/PLAN-ZCode-Harmony.md`。

## 工程结构（PRD 7.1）

```
zcode-harmony/
├─ AppScope/              # 应用级配置
├─ entry/                 # 主入口：工作台、会话、设置
├─ commons/
│  ├─ protocol/           # @zcode/rpc + v4 协议移植（HAR）
│  ├─ uikit/              # 光感按钮、状态灯、主题 token（HAR）
│  └─ utils/              # 断点等工具（HAR）
├─ features/              # pairing / workspace / connection / account（后续批次）
├─ tools/protocol-consistency/  # 协议一致性测试（node 运行，移植层 vs 原包逐字节比对）
└─ docs/                  # spike 与技术决策记录
```

## 打开与构建

1. 用 **DevEco Studio**（5.0+，API 12+）打开本目录，首次打开执行 Sync（自动生成 hvigor wrapper 与 local.properties）；
2. 连接真机或启动模拟器，Run `entry`。

## 协议一致性测试（无需 DevEco）

移植层与原包（`zcode` 仓库 `@zcode/rpc`）跑同一套向量，**逐字节比对**编码结果：

```bash
cd tools/protocol-consistency
npm install
# 默认原包路径 F:/program/zcode/packages/rpc/src，可用环境变量覆盖：
# set ZCODE_RPC_SRC=<zcode 仓库>/packages/rpc/src
npm test
```

## 模块边界

- `commons/protocol` 只依赖 Web 标准 API（Uint8Array/TextEncoder/JSON）+ 纯 TS base64，无 Node API、无 ArkUI 依赖，可在 node 与鸿蒙双端运行；
- `commons/uikit` 与 `entry` 为 ArkTS（.ets），遵守 ArkTS 严格模式（显式类型、禁 any、对象字面量须有类型）。
