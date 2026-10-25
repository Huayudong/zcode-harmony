# 批次24 Spec：shadcn/ui 设计语言转译（UI 重构第一阶段）

用户裁决（2026-10-26）：以 https://ui.shadcn.com/ 的组件设计为基础重构 App UI。
shadcn 是 React/Tailwind 技术栈，不能直接运行在鸿蒙 ArkTS 上——本系列批次做的是
**设计语言转译**：token 体系 + 组件变体规范逐项映射为 ArkTS 实现，不是引包。

## Token 映射表（shadcn CSS 变量 → ZcodeColors/DesignTokens）

| shadcn 变量 | 值（zinc dark） | 鸿蒙落点 |
| --- | --- | --- |
| --background | #09090B (zinc-950) | ZcodeColors.BG |
| --card | 与 bg 弱差 + 1px 边框 | CARD #101014（取原 bg 值保移动端层次） |
| --muted / --secondary | zinc-900 | SURFACE #1C1C1F |
| --foreground | #FAFAFA (zinc-50) | TEXT_PRIMARY |
| --muted-foreground | #A1A1AA (zinc-400) | TEXT_SECONDARY |
| （弱化层） | zinc-500 | TEXT_TERTIARY #71717A |
| --primary | 品牌槽位（可配置） | BRAND #4C7DFF（保留 ZCode 蓝） |
| --primary-foreground | #FFFFFF | BRAND_CONTRAST |
| --border / --input | #27272A (zinc-800) | BORDER（批次24 新增） |
| --accent | ghost 按压底 | ACCENT #26262B（新增） |
| --ring | = primary | RING（新增） |
| --destructive | 红 | DESTRUCTIVE #E05C5C（保留） |
| --radius | 0.5rem | RADIUS_SM 8 / RADIUS_MD 12（已有） |

**存量页面零改动完成色板切换**（ZcodeColors API 不变，仅值更新——批次4 以来所有
引用 background()/card()/textXxx() 的页面自动进入 zinc 暗色系）。

## 组件转译（首批 3 件，uikit 公开面）

- **ZButton**：shadcn Button 的 variant × size 体系。
  variant=default（primary 实底）/secondary/outline（1px BORDER 描边透明底）/ghost/
  destructive；size=sm(32)/md(38)/lg(44)/icon（圆形）。限制：ArkTS 组件无 children
  插槽，label 传文本；图标钮由页面用 ZIcon 组合。
  **ArkUI 命名坑**：@Prop/方法不得与通用属性方法撞名——size/enabled/backgroundColor/
  fontColor/borderWidth/width/height/radius 全部不可用，已改 btnSize/disabled（反向）/
  bgColor/textColor/outlineW/skelWidth/…。
- **ZBadge**：default（brand 淡底）/secondary/outline/success/warning/destructive，
  小号胶囊。
- **ZSkeleton**：脉动占位块（opacity 定时翻转近似 animate-pulse；销毁清 timer）。

## 试点铺开（SessionDetail）

- 审批选项 shadcn 语义：allow 系=default 实底；**deny=outline 描边红字**（原为灰底）；
  custom/fullAccess=**secondary**（原 brand 实底——移除危险授权的视觉诱导）。
- blockKind/子代理徽标 → ZBadge；模式 chips 与思考档位 chips → ZButton sm
  （选中 default / 未选 ghost）；失败卡「重试本轮/修改后重发」→ ZButton ghost sm；
  审批自由文本「发送」→ ZButton default sm。

## 后续阶段（批次25+，视觉铺开未尽项）

- SessionList（列表卡片/新建/长按菜单）、Settings、Pairing 向导各页接入
  ZButton/ZBadge + 裸 hex 清零；
- ZSheet/ZDialog（shadcn Sheet/Dialog 转译，长按菜单与确认弹层用）；
- ZTabs/ZToast/ZAvatar/ZSwitch 按需增补；
- 浅色主题（shadcn light 值）走资源化，token 键名不动（M2）。

## 验证

门禁 33/33（UI 批无新增向量）+ hvigor 构建通过。视觉效果待模拟器解锁后人工验收
（批次23 联调阻塞记录了环境解锁路径）。
