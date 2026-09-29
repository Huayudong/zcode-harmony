import router from '@ohos.router';
import preferences from '@ohos.data.preferences';
import { WorkbenchController, type ConversationUpdate, type ResolveAnswer } from 'connection';
import type { ConnectionStateEvent } from 'connection';
import type { ConversationRowView, PendingInteractionView, PendingInteractionOptionView, IDisposable } from 'protocol';
import { ZcodeColors, StatusDot, StatusTone } from 'uikit';

/** 会话列表 → 会话页的路由参数（与 SessionList 侧同构）。 */
interface SessionRouteParams {
  sessionId: string;
  title: string;
}

/** 内置快捷指令（PRD INP-5 的 4 个内置 chips；用户自定义模板 P1）。 */
const QUICK_CHIPS: string[] = ['继续', '跑测试', '解释这段 diff', '换个思路'];

/**
 * 会话页（A5 渲染管线 + 批次8 OUT-3/4 批准卡片 + 批次9 A6 输入区）：
 * 行视图 = ConversationModel 投影；待批交互吸底卡片按服务端词表应答；
 * 输入舱 TextArea 1→6 行 + 聚焦泛光 + 草稿保护 + 模式选择 + 快捷 chips；
 * 发送/停止同位形变（停止需二次长按防误触），全部命令走 engine 幂等队列。
 */
@Entry
@Component
struct SessionDetail {
  @State rows: ConversationRowView[] = [];
  @State hasLiveWork: boolean = false;
  @State sessionTitle: string = '';
  @State inputText: string = '';
  @State sending: boolean = false;
  @State stateEvent: ConnectionStateEvent = { state: 'offline', detail: '' } as ConnectionStateEvent;
  @State expandedRowIds: number[] = [];
  @State sendHint: string = '';
  @State pending: PendingInteractionView[] = [];
  @State resolvingId: string = '';
  @State pendingFreeText: string = '';
  @State inputFocused: boolean = false;
  @State sendMode: string = 'build';
  @State stopArmed: boolean = false;
  private controller: WorkbenchController | null = null;
  private sessionId: string = '';
  private disposables: IDisposable[] = [];
  private draftTimer: number = -1;

  aboutToAppear(): void {
    const params = router.getParams() as SessionRouteParams | null;
    if (params !== null) {
      this.sessionId = params.sessionId;
      this.sessionTitle = params.title;
    }
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables = [];
    if (this.controller !== null && this.sessionId.length > 0) {
      void this.controller.closeSession(this.sessionId);
    }
    // INP-8 草稿保护：离页即存
    void this.persistDraft();
  }

  private async bootstrap(): Promise<void> {
    const controller = await WorkbenchController.shared(getContext(this));
    this.controller = controller;
    this.stateEvent = controller.getStateEvent();
    this.disposables.push(controller.onStateChange((event: ConnectionStateEvent) => {
      this.stateEvent = event;
    }));
    this.disposables.push(controller.onConversationChanged((update: ConversationUpdate) => {
      if (update.sessionId !== this.sessionId) {
        return;
      }
      this.rows = update.rows;
      this.hasLiveWork = update.hasLiveWork;
      this.pending = update.pending;
      if (this.resolvingId.length > 0
        && update.pending.findIndex((item: PendingInteractionView) => item.interactionId === this.resolvingId) < 0) {
        this.resolvingId = '';
      }
      if (update.title.length > 0) {
        this.sessionTitle = update.title;
      }
    }));
    if (this.sessionId.length > 0) {
      this.rows = await controller.openSession(this.sessionId);
    }
    await this.loadDraft();
  }

  // ── INP-8 草稿保护（按会话持久；切换/重启不丢）──

  private draftKey(): string {
    return `draft_${this.sessionId}`;
  }

  private async loadDraft(): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(getContext(this), { name: 'zcode-drafts' });
      const saved = await prefs.get(this.draftKey(), '') as string;
      if (this.inputText.length === 0 && saved.length > 0) {
        this.inputText = saved;
      }
    } catch (error) {
      // 预览器等环境无草稿不阻塞
    }
  }

  private scheduleDraftSave(): void {
    if (this.draftTimer >= 0) {
      clearTimeout(this.draftTimer);
    }
    this.draftTimer = setTimeout((): void => {
      this.draftTimer = -1;
      void this.persistDraft();
    }, 500);
  }

  private async persistDraft(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    try {
      const prefs = await preferences.getPreferences(getContext(this), { name: 'zcode-drafts' });
      await prefs.put(this.draftKey(), this.inputText);
      await prefs.flush();
    } catch (error) {
      // 同上
    }
  }

  private toggleReasoning(rowId: number): void {
    const next: number[] = [];
    let removed = false;
    for (const id of this.expandedRowIds) {
      if (id === rowId) {
        removed = true;
      } else {
        next.push(id);
      }
    }
    if (!removed) {
      next.push(rowId);
    }
    this.expandedRowIds = next;
  }

  private isExpanded(rowId: number): boolean {
    return this.expandedRowIds.indexOf(rowId) >= 0;
  }

  private toolTone(status: string): StatusTone {
    if (status === 'success') {
      return StatusTone.Success;
    }
    if (status === 'error') {
      return StatusTone.Failed;
    }
    if (status === 'pendingApproval') {
      return StatusTone.PendingConfirm;
    }
    if (status === 'running' || status === 'inputStreaming') {
      return StatusTone.Running;
    }
    return StatusTone.Offline;
  }

  private async send(): Promise<void> {
    const text = this.inputText.trim();
    if (text.length === 0 || this.sending || this.controller === null || this.sessionId.length === 0) {
      return;
    }
    this.sending = true;
    this.sendHint = '';
    try {
      await this.controller.sendText(this.sessionId, text, this.sendMode);
      this.inputText = '';
      this.stopArmed = false;
      void this.persistDraft();
      if (this.stateEvent.state !== 'online') {
        this.sendHint = '当前离线：已入队，重连后自动发送';
      }
    } catch (error) {
      this.sendHint = `发送失败：${error instanceof Error ? error.message : String(error)}`;
    }
    this.sending = false;
  }

  private async stop(): Promise<void> {
    if (this.controller === null || this.sessionId.length === 0) {
      return;
    }
    this.stopArmed = false;
    try {
      await this.controller.stopSession(this.sessionId);
    } catch (error) {
      this.sendHint = `停止失败：${error instanceof Error ? error.message : String(error)}`;
    }
  }

  /** INP-7：停止需二次长按（防误触）；第一次长按进入待确认态，超时自动解除。 */
  private armStop(): void {
    if (this.stopArmed) {
      void this.stop();
      return;
    }
    this.stopArmed = true;
    this.sendHint = '再长按一次确认停止';
    setTimeout((): void => {
      if (this.stopArmed) {
        this.stopArmed = false;
        this.sendHint = '';
      }
    }, 2500);
  }

  /** 批准/应答（OUT-4）：interactionId 幂等，竞态以 CLI 准入为准。 */
  private async resolve(item: PendingInteractionView, answer: ResolveAnswer): Promise<void> {
    if (this.resolvingId.length > 0 || this.controller === null || this.sessionId.length === 0) {
      return;
    }
    this.resolvingId = item.interactionId;
    try {
      await this.controller.resolveInteraction(this.sessionId, item.interactionId, answer);
      this.sendHint = '';
      this.pendingFreeText = '';
    } catch (error) {
      this.sendHint = `应答失败：${error instanceof Error ? error.message : String(error)}`;
      this.resolvingId = '';
    }
  }

  private optionFontColor(item: PendingInteractionOptionView): string {
    if (item.kind === 'deny') {
      return ZcodeColors.DESTRUCTIVE;
    }
    if (item.kind === 'allowOnce' || item.kind === 'allowAlways') {
      return '#FFFFFF';
    }
    return ZcodeColors.textSecondary();
  }

  private optionBackground(item: PendingInteractionOptionView): string {
    if (item.kind === 'allowOnce' || item.kind === 'allowAlways') {
      return ZcodeColors.BRAND;
    }
    return ZcodeColors.SURFACE;
  }

  private secondsOf(ms: number): string {
    return ms > 0 ? `${Math.max(1, Math.round(ms / 1000))}s` : '';
  }

  @Builder
  ModeChip(label: string, value: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.sendMode === value ? '#FFFFFF' : ZcodeColors.textSecondary())
      .backgroundColor(this.sendMode === value ? ZcodeColors.BRAND : Color.Transparent)
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .borderRadius(999)
      .onClick(() => {
        this.sendMode = value;
      })
  }

  @Builder
  ApprovalCard(item: PendingInteractionView) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        StatusDot({ tone: StatusTone.PendingConfirm, dotSize: 10 })
        if (item.toolName.length > 0) {
          Text(item.toolName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ZcodeColors.textPrimary())
        }
        Text(item.kind === 'permission' ? '待批准' : (item.kind === 'userInput' ? '待回答' : '待审核'))
          .fontSize(11)
          .fontColor(ZcodeColors.textTertiary())
        Blank()
        if (this.resolvingId === item.interactionId) {
          Text('已应答，等待电脑确认…')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(item.title)
        .fontSize(14)
        .fontColor(ZcodeColors.textPrimary())
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (item.kind === 'workspaceHookReview') {
        Text('工作区 Hook 审核请在桌面端处理')
          .fontSize(12)
          .fontColor(ZcodeColors.textTertiary())
      } else {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(item.options, (option: PendingInteractionOptionView) => {
            Button(option.label)
              .fontSize(13)
              .fontColor(this.optionFontColor(option))
              .backgroundColor(this.optionBackground(option))
              .borderRadius(10)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .margin({ right: 8, bottom: 8 })
              .enabled(this.resolvingId.length === 0)
              .onClick(() => {
                const answer: ResolveAnswer = { optionId: option.optionId };
                void this.resolve(item, answer);
              })
          }, (option: PendingInteractionOptionView) => `${item.interactionId}-${option.optionId}`)
        }
        .width('100%')

        if (item.freeText) {
          Row({ space: 8 }) {
            TextInput({
              text: this.pendingFreeText,
              placeholder: item.sensitive ? '输入敏感内容（不进历史）…' : '输入自定义答复…',
            })
              .fontSize(13)
              .fontColor(ZcodeColors.textPrimary())
              .placeholderColor(ZcodeColors.textTertiary())
              .backgroundColor(ZcodeColors.background())
              .borderRadius(10)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.pendingFreeText = value;
              })
            Button('发送')
              .fontSize(13)
              .fontColor(this.pendingFreeText.trim().length > 0 ? '#FFFFFF' : ZcodeColors.textTertiary())
              .backgroundColor(this.pendingFreeText.trim().length > 0 ? ZcodeColors.BRAND : ZcodeColors.SURFACE)
              .borderRadius(10)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .enabled(this.resolvingId.length === 0 && this.pendingFreeText.trim().length > 0)
              .onClick(() => {
                const answer: ResolveAnswer = { freeText: this.pendingFreeText.trim() };
                void this.resolve(item, answer);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .border({ width: 1, color: ZcodeColors.WARNING })
    .backgroundColor(ZcodeColors.card())
    .margin({ top: 6 })
  }

  @Builder
  RowView(row: ConversationRowView) {
    if (row.kind === 'userInput') {
      Row() {
        Blank()
        Text(row.text)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius(14)
          .backgroundColor(ZcodeColors.BRAND)
          .constraintSize({ maxWidth: '82%' })
      }
      .width('100%')
      .margin({ top: 6, bottom: 6 })
    } else if (row.kind === 'assistantText') {
      Column({ space: 2 }) {
        Text(row.text)
          .fontSize(15)
          .fontColor(ZcodeColors.textPrimary())
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6, bottom: 6 })
    } else if (row.kind === 'reasoning') {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(`思考过程${row.durationMs > 0 ? ` · ${this.secondsOf(row.durationMs)}` : ''}`)
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())
          Text(this.isExpanded(row.rowId) ? '收起' : '展开')
            .fontSize(12)
            .fontColor(ZcodeColors.BRAND_LIGHT)
        }
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.toggleReasoning(row.rowId);
        })
        if (this.isExpanded(row.rowId)) {
          Text(row.text)
            .fontSize(13)
            .fontColor(ZcodeColors.textSecondary())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 4, bottom: 4 })
    } else if (row.kind === 'toolCall') {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          StatusDot({ tone: this.toolTone(row.state), dotSize: 8 })
          Text(row.toolName)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ZcodeColors.textPrimary())
          if (row.inputText.length > 0) {
            Text(row.inputText.replace(/\r?\n/g, ' '))
              .fontSize(12)
              .fontColor(ZcodeColors.textTertiary())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (row.errorMessage.length > 0) {
          Text(row.errorMessage)
            .fontSize(12)
            .fontColor(ZcodeColors.DESTRUCTIVE)
            .maxLines(3)
        } else if (row.outputText.length > 0) {
          Text(row.outputText)
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .borderRadius(12)
      .backgroundColor(ZcodeColors.SURFACE)
      .margin({ top: 4, bottom: 4 })
    } else if (row.kind === 'subagent') {
      Row({ space: 8 }) {
        StatusDot({ tone: row.state === 'running' ? StatusTone.Running
          : (row.state === 'failed' ? StatusTone.Failed : StatusTone.Success), dotSize: 8 })
        Text(`子代理 · ${row.subagentType}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
        Text(row.summaryText)
          .fontSize(12)
          .fontColor(ZcodeColors.textTertiary())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 4, bottom: 4 })
    } else if (row.kind === 'artifact') {
      Row({ space: 8 }) {
        Text('📄')
          .fontSize(14)
        Text(`${row.displayName}（${row.artifactType}）`)
          .fontSize(13)
          .fontColor(ZcodeColors.BRAND_LIGHT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(10)
      .borderRadius(12)
      .backgroundColor(ZcodeColors.SURFACE)
      .margin({ top: 4, bottom: 4 })
    } else if (row.kind === 'turnHeader') {
      Row({ space: 10 }) {
        Divider()
          .color(ZcodeColors.TEXT_TERTIARY)
          .strokeWidth(1)
          .width(56)
        Text(this.secondsOf(row.durationMs))
          .fontSize(10)
          .fontColor(ZcodeColors.textTertiary())
        Divider()
          .color(ZcodeColors.TEXT_TERTIARY)
          .strokeWidth(1)
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10, bottom: 6 })
    } else {
      // timelineMarker / hookInvocation / 未知类型：居中弱化行
      Text(row.kind === 'timelineMarker' ? row.text : `· ${row.kind} ·`)
        .fontSize(11)
        .fontColor(ZcodeColors.textTertiary())
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 4, bottom: 4 })
    }
  }

  build() {
    Column() {
      // 头部
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(22)
          .fontColor(ZcodeColors.textSecondary())
          .onClick(() => {
            router.back();
          })
        Text(this.sessionTitle.length > 0 ? this.sessionTitle : '会话')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.hasLiveWork) {
          Row({ space: 5 }) {
            StatusDot({ tone: StatusTone.Running, dotSize: 7 })
            Text('进行中')
              .fontSize(11)
              .fontColor(ZcodeColors.textSecondary())
          }
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 20, top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.stateEvent.state !== 'online') {
        Text(this.stateEvent.state === 'connecting' ? '正在连接电脑…' : `离线（${this.stateEvent.detail}）`)
          .fontSize(11)
          .fontColor(ZcodeColors.WARNING)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(4)
      }

      // 对话行
      List({ space: 0 }) {
        ForEach(this.rows, (row: ConversationRowView) => {
          ListItem() {
            this.RowView(row)
          }
        }, (row: ConversationRowView) => `${row.rowId}-${row.kind}-${row.state}-${row.text.length}-${row.summaryText.length}`)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 4 })
      .scrollBar(BarState.Off)

      // OUT-3/4：吸底待批卡片
      Column() {
        ForEach(this.pending, (item: PendingInteractionView) => {
          this.ApprovalCard(item)
        }, (item: PendingInteractionView) => `${item.interactionId}-${item.options.length}-${item.title.length}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      // 发送提示
      if (this.sendHint.length > 0) {
        Text(this.sendHint)
          .fontSize(11)
          .fontColor(ZcodeColors.WARNING)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(3)
      }

      // INP-5：快捷指令 chips（横滑）
      Scroll() {
        Row({ space: 8 }) {
          ForEach(QUICK_CHIPS, (chip: string) => {
            Text(chip)
              .fontSize(12)
              .fontColor(ZcodeColors.textSecondary())
              .backgroundColor(ZcodeColors.SURFACE)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(999)
              .onClick(() => {
                this.inputText = this.inputText.length > 0 ? `${this.inputText} ${chip}` : chip;
                this.scheduleDraftSave();
              })
          }, (chip: string) => chip)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
      .padding({ left: 16, right: 16, top: 6 })
      .scrollBar(BarState.Off)

      // INP-1/6/7：输入舱（胶囊容器 + 模式选择 + 发送/停止同位形变）
      Row({ space: 10 }) {
        Column({ space: 6 }) {
          TextArea({
            text: this.inputText,
            placeholder: this.stateEvent.state === 'online' ? '给 Agent 发消息…' : '离线中，消息将排队…',
          })
            .fontSize(14)
            .fontColor(ZcodeColors.textPrimary())
            .placeholderColor(ZcodeColors.textTertiary())
            .backgroundColor(Color.Transparent)
            .constraintSize({ maxHeight: 156 })
            .padding({ left: 4, right: 4 })
            .onFocus(() => {
              this.inputFocused = true;
            })
            .onBlur(() => {
              this.inputFocused = false;
            })
            .onChange((value: string) => {
              this.inputText = value;
              this.scheduleDraftSave();
            })

          Row({ space: 6 }) {
            Text('模式')
              .fontSize(10)
              .fontColor(ZcodeColors.textTertiary())
            this.ModeChip('Agent', 'build')
            this.ModeChip('Plan', 'plan')
            Blank()
            if (this.inputFocused) {
              Text('')
                .fontSize(1)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(20)
        .backgroundColor(ZcodeColors.SURFACE)
        .border({
          width: this.inputFocused ? 1.5 : 0,
          color: ZcodeColors.BRAND,
        })
        .layoutWeight(1)
        // INP-1：聚焦时边缘泛品牌色光
        .shadow(this.inputFocused ? {
          radius: 18,
          color: 'rgba76, 125, 255, 0.35',
          offsetX: 0,
          offsetY: 0,
        } : {
          radius: 0,
          color: Color.Transparent,
          offsetX: 0,
          offsetY: 0,
        })

        if (this.hasLiveWork) {
          // INP-7：生成中 → 停止（destructive 描边，二次长按防误触）
          Button(this.stopArmed ? '停止?' : '⏹')
            .fontSize(this.stopArmed ? 12 : 16)
            .fontColor(ZcodeColors.DESTRUCTIVE)
            .backgroundColor(Color.Transparent)
            .border({ width: 1.5, color: ZcodeColors.DESTRUCTIVE })
            .width(48)
            .height(48)
            .borderRadius(24)
            .animation({ duration: 800, curve: Curve.EaseInOut })
            .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
              this.armStop();
            }))
        } else {
          Button(this.sending ? '…' : '↑')
            .fontSize(20)
            .fontColor(this.inputText.trim().length > 0 && !this.sending ? '#FFFFFF' : ZcodeColors.textTertiary())
            .backgroundColor(this.inputText.trim().length > 0 && !this.sending ? ZcodeColors.BRAND : ZcodeColors.SURFACE)
            .width(48)
            .height(48)
            .borderRadius(24)
            .animation({ duration: 300, curve: Curve.EaseOut })
            .onClick(() => {
              void this.send();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 16 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
  }
}
