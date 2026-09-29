# Spec：A6 输入区主体（Batch 9 / 计划 §4-A6、PRD 4.3.2）

| 项 | 内容 |
| --- | --- |
| 状态 | 本批实现（Batch 9） |
| 对应计划 | §4-A6：INP-1 输入舱、INP-5 快捷指令、INP-6 模式选择、INP-7 发送/停止、INP-8 草稿保护 |
| 模块 | `commons/connection`（sendText 增按次 mode）+ `entry`（SessionDetail 输入舱重构） |
| 服务端契约 | `sendText` payload 的 `mode: build/edit/plan/yolo`（submission.ts 词表，按次提交）；信封仍由 Engine 生成幂等 commandId |
| 范围外 | INP-2 语音（M2）、INP-3 附件（v4 分块上传，需先补上传通道）、INP-4 @ 引用（需 workspaceFileSearch 服务通道）、问答模式（Q3 开放：v4 无同名档位）、聚焦上浮动画（只做泛光） |

## 1. 行为

输入舱为底部胶囊容器：TextArea 1 行起、最高 6 行（≈156vp）后内部滚动，聚焦时边缘泛品牌色光（1.5px 描边 + 品牌色 shadow）。舱内左下为模式选择（Agent=build / Plan=plan，当前档高亮、发送前显性可见），发送按次携带 `mode`（缺省 build；词表外值被信封 schema 拒绝）。输入舱上方横滑快捷 chips（继续 / 跑测试 / 解释这段 diff / 换个思路），点击追加进输入框。生成中发送按钮同位形变为停止按钮（品牌实心 → destructive 描边圆钮，800ms 过渡），**二次长按**才真正停止（首次长按进入待确认态并提示，2.5s 超时自动解除）。草稿按会话持久（preferences `zcode-drafts`/`draft_<sessionId>`，500ms 去抖 + 离页即存），切换会话/杀 App 不丢，发送成功即清。

## 2. 关键决策

- **模式走按次提交而非 switchCollaborationMode**：sendText payload 原生支持 `mode`，不改服务端会话状态、无额外命令词表；后续若需持久切换再加该命令。
- **问答档不做**：计划 §9-Q3 未决（v4 无同名模式），UI 只出 Agent/Plan 两档；词表外值（如 'ask'）由信封 schema 拒绝——一致性测试覆盖。
- **停止防误触用"二次长按"**：PRD 要求"杜绝误触需二次长按"；首次长按 arm + 提示、超时自动解除，比对话框轻。
- **草稿存页面域**：preferences 直连（UI 态，不入 controller 连接域）；空输入不覆盖已存草稿（先读后写）。

## 3. 不变量

1. 全部发送/停止/应答仍走 engine 幂等队列（本批未新增命令通道）。
2. `mode` 词表以 submission.ts 为事实源；UI 词表（build/plan）是其子集。
3. 草稿失败（预览器等）静默降级，不阻塞输入。
4. 停止按钮只在 hasLiveWork 时出现；空闲态恒为发送。

## 4. 验证与门禁

| # | 验证 | 期望 | 结果 |
| --- | --- | --- | --- |
| I-1 | 一致性：sendText.mode 信封（build/plan/缺省过 schema；'ask' 拒绝） | 全绿 | ✅ |
| I-2 | 全套一致性门禁 `npm test` | 18/18 | ✅ |
| I-3 | hvigor 构建 | assembleHap BUILD SUCCESSFUL | ✅ |
| I-4 | 真机体验：6 行滚动/聚焦泛光/长按停止/草稿恢复 | 随 W-5 通道恢复一并验收 | ⏳ 待真机 |

## 5. 风险与后续

- TextArea 多行高度自适应在不同 API 容器上表现需真机确认（constraintSize 方案为当前实现）。
- chips 点击是"填入"而非"直接发送"——保守选择，用户可改后发；反馈后再评估。
- INP-3 附件与 INP-4 @ 引用共享"服务通道缺口"（v4 分块上传 / workspaceFileSearch），建议合成一个批次做 L3 stub 扩展后一起上。
