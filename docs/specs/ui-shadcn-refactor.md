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

---

# 批次28 Spec：shadcn 组件补全 + 全页铺开（第二阶段）

> 批次24 只做了 token 层 + 3 个组件 + 1 页试点。本批把组件层补到覆盖交互与
> 表单件，并把 SessionList / Settings / Pairing 三页 / Index 全部铺开，
> 裸 hex 收敛到「只存在于 token 定义文件」。

## 新增组件（uikit 公开面）

| 组件 | shadcn 对位 | 关键语义 |
| --- | --- | --- |
| ZDialog | Dialog / AlertDialog | 遮罩 + 居中面板（--card + --border）；动作区右对齐（取消 ghost / 确认 default）；destructive 变体走红底确认 |
| ZSheet | Sheet | 底部抽屉（顶部圆角 + --border）；标题栏带关闭态；内容走插槽 |
| ZSwitch | Switch | 覆写 Toggle 系统外观为 --primary 轨道 + 白拇指 |
| ZInput / ZTextarea | Input / Textarea | --card 底 + --input 描边，聚焦切 --ring（focus-visible ring） |
| ZTabs | Tabs（underline 变体） | 选中 --foreground + 2px --primary 指示条，未选中无底色 |
| ZToast + ZToastHost | Sonner | AppStorage 全局，2.6s 自动消失；宿主挂在页面根 |

DesignTokens 补：SCRIM（遮罩）/ TRANSPARENT / SHADOW / BADGE_INFO_BG /
BADGE_WARNING_BG。

## 页面铺开

- **SessionList**：长按菜单 → ZSheet（原先是卡片内联文字行）；删除会话 → 新增
  AlertDialog 二次确认（原先直接提交，不可撤销）；重命名浮层 → ZDialog + ZInput；
  会话卡片补 --border 描边；阶段徽标 → ZBadge；头部三按钮 → ZButton；搜索框 →
  ZInput；轻提示 → ZToast。
- **Settings**：根节点 Column → Stack（overlay 需 Stack 才能盖满并居中）；通知
  分级三档 → ZButton ToggleGroup 语义（选中 default / 未选 outline）；重连/
  设为活跃/重新配对 → ZButton；当前活跃 → ZBadge(success)；清除缓存 →
  ZButton(outline) + AlertDialog 破坏性确认。
- **Pairing 三页**：返回/组网指引 → ZButton(ghost)；主行动保留 LightBloomButton
  （PRD 5.4 光感只给主行动），次要行动 → ZButton(secondary)；推荐卡片补描边 +
  ZBadge；四个输入框 → ZInput。
- **Index**：挂 ZToastHost，全 App 轻提示统一走 AppStorage。
- **SessionDetail**：10 处裸 hex 清零（批次24 遗留）。

## ArkUI 转译坑（实测，跨批复用）

1. 装饰器名是 **`@BuilderParam`**（不是 `@PropBuilderParam`）。写错名字会退化成
   普通未初始化字段并报 10605999「no initializer」。
2. `@Prop`/方法不得与**通用属性**撞名：`onChange`（TextInput/Toggle 通用属性）→
   `onValueChange`；Tabs 的 `onChange` → `onIndexChange`（批次24 已记 size/enabled
   一类，同类坑）。
3. `Stack` **没有** alignItems/justifyContent（那是 Flex/Column 的）；定位用子节点
   `.align(Alignment.*)`，Stack 整体对齐用 `.alignContent(Alignment.*)`。
4. **自定义组件在 Stack 中按内容尺寸布局**：组件内部的百分比高度会解析成内容高度，
   overlay 无法自行铺满整屏（实测：加了 `.width('100%').height('100%')` 仍只按
   内容高，且面板不贴底）。解法：**overlay 组件只渲染面板**，遮罩与对齐交给宿主
   侧的原生容器（原生子节点的百分比高度才生效）。
5. 带尾随闭包的组件调用（`Xxx({...}) { ... }`）之后**不能链式调用属性**——要用
   插槽就改用 init 对象传 builder。
6. `@Builder` 内**不能写语句**（如 `const x = ...`），且 null 对象在 @Builder 里取
   字段不可靠 → 状态字段改用基本类型（id/text/flag）。

## 验证

- 门禁 33/33 + v4 smoke 5/5；
- hvigor 构建 BUILD SUCCESSFUL（ArkTS 零错误）；
- 模拟器实测截图：`docs/preview-批次28-会话长按Sheet.jpg` /
  `docs/preview-批次28-设置页-ToggleGroup语义.jpg` /
  `docs/preview-批次28-破坏性AlertDialog.jpg`；
- 裸 hex 审计：全仓仅 DesignTokens / ZcodeColors 两个 token 定义文件含 hex。

## 遗留（批次29+）

- ZTabs 尚未接入页面（SessionDetail 的三 Tab 仍是页面内自绘 TabButton）；
- ZSwitch/ZTextarea 组件已备但暂无对应设置项（M2 的浅色主题与字体档位会用）；
- 浅色主题（shadcn light 值）走资源化，token 键名不动（M2）；
- 剩余 shadcn 组件（DropdownMenu / Select / Checkbox / Tooltip / Popover /
  Card / Avatar / Progress / Separator / ScrollArea / Command 等）按需增补。
