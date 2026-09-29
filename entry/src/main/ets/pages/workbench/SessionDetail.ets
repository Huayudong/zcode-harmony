import router from '@ohos.router';
import preferences from '@ohos.data.preferences';
import pasteboard from '@ohos.pasteboard';
import fs from '@ohos.file.fs';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { picker } from '@kit.CoreFileKit';
import { cameraPicker, camera } from '@kit.CameraKit';
import { parseBlocks } from './MdParserTask';
import {
  WorkbenchController,
  type AttachmentItem,
  type AttachmentUpdate,
  type ConversationUpdate,
  type ResolveAnswer,
  type WorkspaceFileView
} from 'connection';
import type { ConnectionStateEvent } from 'connection';
import type {
  ConversationRowView,
  DiffHunkView,
  FileChangeItemView,
  FileChangesReportView,
  IDisposable,
  PendingInteractionView,
  PendingInteractionOptionView,
} from 'protocol';
import { ZcodeColors, StatusDot, StatusTone } from 'uikit';
import { mdBlockKey, parseMarkdownBlocks, type MdBlock, type MdSpan } from 'utils';

/** 会话列表 → 会话页的路由参数（与 SessionList 侧同构）。 */
interface SessionRouteParams {
  sessionId: string;
  title: string;
}

/** 内置快捷指令（PRD INP-5 的 4 个内置 chips；用户自定义模板 P1）。 */
const QUICK_CHIPS: string[] = ['继续', '跑测试', '解释这段 diff', '换个思路'];

/**
 * 会话页（三 Tab 骨架 + 批次10 A7 后半）：对话 Tab = 渲染管线 + 批准卡片 + 输入舱；
 * 变更 Tab = 轮次选择 → v4 fileChanges 只读查询 → 文件列表 → diff hunks 着色；
 * 产物 Tab 为占位（P1）。代码块带语言徽标/复制/超20行折叠；长按消息出复制/引用操作行。
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
  @State activeTab: number = 0;
  @State turns: ConversationRowView[] = [];
  @State selectedTurnRowId: number = -1;
  @State changesReport: FileChangesReportView | null = null;
  @State changesLoading: boolean = false;
  @State changesHint: string = '';
  @State expandedFiles: string[] = [];
  @State expandedCodeBlocks: string[] = [];
  @State actionsRowId: number = -1;
  @State attachments: AttachmentItem[] = [];
  @State attachBusy: boolean = false;
  @State atPanelOpen: boolean = false;
  @State atQuery: string = '';
  @State atResults: WorkspaceFileView[] = [];
  @State atLoading: boolean = false;
  @State atHint: string = '';
  @State atPrefix: string = '';
  @State atPosition: number = -1;
  @State atBottom: boolean = true;
  @State timelineExpanded: boolean = false;
  @State timeline: ConversationRowView[] = [];
  private atSearchTimer: number = -1;
  private listScroller: Scroller = new Scroller();
  private blocksByRow: Map<number, MdBlock[]> = new Map();
  private parseGeneration: number = 0;
  @State blocksTick: number = 0;
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
      this.refreshTurns();
      this.refreshTimeline();
      this.precomputeBlocks(update.rows);
      if (this.atBottom && this.activeTab === 0) {
        setTimeout((): void => {
          this.listScroller.scrollEdge(Edge.Bottom);
        }, 50);
      }
    }));
    this.disposables.push(controller.onAttachmentChanged((update: AttachmentUpdate) => {
      if (update.sessionId === this.sessionId) {
        this.attachments = update.items;
      }
    }));
    if (this.sessionId.length > 0) {
      this.rows = await controller.openSession(this.sessionId);
    }
    this.refreshTurns();
    this.refreshTimeline();
    this.precomputeBlocks(this.rows);
    await this.loadDraft();
  }

  /** OUT-1 TaskPool：会话行分块预计算（设备投递线程池，预览器降级同步）；代际守卫丢弃过期填充。 */
  private precomputeBlocks(rows: ConversationRowView[]): void {
    const generation = ++this.parseGeneration;
    void this.parseRowsAsync(rows, generation);
  }

  private async parseRowsAsync(rows: ConversationRowView[], generation: number): Promise<void> {
    for (const row of rows) {
      if (generation !== this.parseGeneration) {
        return;
      }
      try {
        const blocks = await parseBlocks(row.text);
        if (generation !== this.parseGeneration) {
          return;
        }
        this.blocksByRow.set(row.rowId, blocks);
      } catch (error) {
        this.blocksByRow.delete(row.rowId);
      }
    }
    this.blocksTick += 1;
  }

  /** 渲染取块：预计算就绪用缓存，否则同步兜底（首帧）。 */
  private blocksFor(row: ConversationRowView): MdBlock[] {
    const cached = this.blocksByRow.get(row.rowId);
    return cached !== undefined ? cached : parseMarkdownBlocks(row.text);
  }

  /** OUT-6 简版时间线：当前轮（最后一个 turnHeader 之后）的执行步骤。 */
  private refreshTimeline(): void {
    const steps: ConversationRowView[] = [];
    let turnStart = -1;
    for (const row of this.rows) {
      if (row.kind === 'turnHeader') {
        turnStart = row.rowId;
      }
    }
    for (const row of this.rows) {
      if (turnStart >= 0 && row.rowId > turnStart
        && (row.kind === 'toolCall' || row.kind === 'subagent')) {
        steps.push(row);
      }
    }
    this.timeline = steps;
  }

  /** OUT-7：失败回复的重发动作 = 把最近一条用户输入原文重发（新 commandId，服务端幂等）。 */
  private resendLastInput(): void {
    let lastUserInput = '';
    for (const row of this.rows) {
      if (row.kind === 'userInput' && row.text.length > 0) {
        lastUserInput = row.text;
      }
    }
    if (lastUserInput.length === 0) {
      this.sendHint = '没有可重发的输入';
      return;
    }
    this.inputText = lastUserInput;
    void this.send();
  }

  /** 有文件变更聚合的轮次（turnHeader.fileCount>0），保持选中、默认最新。 */
  private refreshTurns(): void {
    const found: ConversationRowView[] = [];
    for (const row of this.rows) {
      if (row.kind === 'turnHeader' && row.fileCount > 0) {
        found.push(row);
      }
    }
    this.turns = found;
    if (found.length === 0) {
      this.selectedTurnRowId = -1;
      return;
    }
    let stillThere = false;
    for (const turn of found) {
      if (turn.rowId === this.selectedTurnRowId) {
        stillThere = true;
        break;
      }
    }
    if (!stillThere) {
      this.selectedTurnRowId = found[found.length - 1].rowId;
      if (this.activeTab === 1) {
        void this.loadChanges();
      }
    }
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

  // ── 变更 Tab（OUT-5）──

  private switchTab(tab: number): void {
    this.activeTab = tab;
    this.actionsRowId = -1;
    if (tab === 1 && this.selectedTurnRowId >= 0 && this.changesReport === null) {
      void this.loadChanges();
    }
  }

  private async loadChanges(): Promise<void> {
    if (this.changesLoading || this.controller === null || this.selectedTurnRowId < 0 || this.sessionId.length === 0) {
      return;
    }
    let entityId = '';
    for (const turn of this.turns) {
      if (turn.rowId === this.selectedTurnRowId) {
        entityId = turn.entityId;
        break;
      }
    }
    if (entityId.length === 0) {
      return;
    }
    this.changesLoading = true;
    this.changesHint = '';
    try {
      this.changesReport =
        await this.controller.loadFileChanges(this.sessionId, this.selectedTurnRowId, entityId);
      this.expandedFiles = [];
    } catch (error) {
      this.changesHint = `加载失败：${error instanceof Error ? error.message : String(error)}`;
    }
    this.changesLoading = false;
  }

  private toggleFile(path: string): void {
    const next: string[] = [];
    let removed = false;
    for (const item of this.expandedFiles) {
      if (item === path) {
        removed = true;
      } else {
        next.push(item);
      }
    }
    if (!removed) {
      next.push(path);
    }
    this.expandedFiles = next;
  }

  private isFileExpanded(path: string): boolean {
    return this.expandedFiles.indexOf(path) >= 0;
  }

  // ── OUT-2 代码块切分与复制 ──

  private codeKey(rowId: number, index: number): string {
    return `${rowId}-${index}`;
  }

  private isCodeExpanded(key: string): boolean {
    return this.expandedCodeBlocks.indexOf(key) >= 0;
  }

  private toggleCode(key: string): void {
    const next: string[] = [];
    let removed = false;
    for (const item of this.expandedCodeBlocks) {
      if (item === key) {
        removed = true;
      } else {
        next.push(item);
      }
    }
    if (!removed) {
      next.push(key);
    }
    this.expandedCodeBlocks = next;
  }

  private async copyText(text: string): Promise<void> {
    try {
      const paste = pasteboard.getSystemPasteboard();
      await paste.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.sendHint = '已复制';
      setTimeout((): void => {
        if (this.sendHint === '已复制') {
          this.sendHint = '';
        }
      }, 2000);
    } catch (error) {
      this.sendHint = `复制失败：${String(error)}`;
    }
  }

  // ── 发送 / 停止 / 应答 ──

  private async send(): Promise<void> {
    const text = this.inputText.trim();
    if (text.length === 0 || this.sending || this.controller === null || this.sessionId.length === 0) {
      return;
    }
    if (this.attachments.findIndex((item: AttachmentItem) => item.state === 'uploading') >= 0) {
      this.sendHint = '附件上传中，稍候…';
      return;
    }
    this.sending = true;
    this.sendHint = '';
    try {
      await this.controller.sendText(this.sessionId, text, this.sendMode, this.attachments);
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

  // ── INP-3 附件（相册/文件 → 读字节 → 控制器编排上传）──

  private async pickImage(): Promise<void> {
    if (this.attachBusy || this.sessionId.length === 0) {
      return;
    }
    const controller = this.controller;
    if (controller === null) {
      return;
    }
    this.attachBusy = true;
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 5,
      };
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(options);
      for (const uri of result.photoUris) {
        const picked = readPickedFile(uri);
        await controller.attachFile(this.sessionId, picked.fileName, picked.mime, picked.bytes, uri, true);
      }
    } catch (error) {
      this.sendHint = `选图失败：${error instanceof Error ? error.message : String(error)}`;
    }
    this.attachBusy = false;
  }

  /** INP-3 拍照直拍：CameraPicker 系统安全组件（无需自管相机权限），拍后即走附件上传链。 */
  private async pickCamera(): Promise<void> {
    if (this.attachBusy || this.sessionId.length === 0) {
      return;
    }
    const controller = this.controller;
    if (controller === null) {
      return;
    }
    this.attachBusy = true;
    try {
      const context = getContext(this);
      const mediaTypes: Array<cameraPicker.PickerMediaType> = [cameraPicker.PickerMediaType.PHOTO];
      const profile: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK };
      const result: cameraPicker.PickerResult = await cameraPicker.pick(context, mediaTypes, profile);
      if (result.resultCode === 0 && result.resultUri.length > 0) {
        const picked = readPickedFile(result.resultUri);
        await controller.attachFile(this.sessionId, picked.fileName, picked.mime, picked.bytes, result.resultUri, true);
      }
    } catch (error) {
      this.sendHint = `拍照失败：${error instanceof Error ? error.message : String(error)}`;
    }
    this.attachBusy = false;
  }

  private async pickDocument(): Promise<void> {
    if (this.attachBusy || this.sessionId.length === 0) {
      return;
    }
    const controller = this.controller;
    if (controller === null) {
      return;
    }
    this.attachBusy = true;
    try {
      const docPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSelectOptions = { maxSelectNumber: 5 };
      const result: string[] = await docPicker.select(options);
      for (const uri of result) {
        const picked = readPickedFile(uri);
        await controller.attachFile(this.sessionId, picked.fileName, picked.mime, picked.bytes, uri, false);
      }
    } catch (error) {
      this.sendHint = `选文件失败：${error instanceof Error ? error.message : String(error)}`;
    }
    this.attachBusy = false;
  }

  private removeAttachment(uploadId: string): void {
    if (this.controller === null || this.sessionId.length === 0) {
      return;
    }
    void this.controller.removeAttachment(this.sessionId, uploadId);
  }

  // ── INP-4 @ 引用面板 ──

  private onMainInputChanged(value: string): void {
    this.inputText = value;
    this.scheduleDraftSave();
    if (value.length > 0 && value.charAt(value.length - 1) === '@') {
      this.openAtPanel();
    } else if (this.atPanelOpen && !value.startsWith(this.atPrefix)) {
      this.closeAtPanel();
    }
  }

  private openAtPanel(): void {
    this.atPosition = this.inputText.length - 1;
    this.atPrefix = this.inputText;
    this.atQuery = '';
    this.atResults = [];
    this.atHint = '';
    this.atPanelOpen = true;
    this.scheduleAtSearch();
  }

  private closeAtPanel(): void {
    this.atPanelOpen = false;
    this.atResults = [];
    if (this.atSearchTimer >= 0) {
      clearTimeout(this.atSearchTimer);
      this.atSearchTimer = -1;
    }
  }

  private scheduleAtSearch(): void {
    if (this.atSearchTimer >= 0) {
      clearTimeout(this.atSearchTimer);
    }
    this.atSearchTimer = setTimeout((): void => {
      this.atSearchTimer = -1;
      void this.runAtSearch();
    }, 300);
  }

  private async runAtSearch(): Promise<void> {
    const controller = this.controller;
    if (controller === null) {
      return;
    }
    this.atLoading = true;
    try {
      this.atResults = await controller.searchWorkspaceFiles(this.atQuery, 30);
      this.atHint = '';
    } catch (error) {
      this.atResults = [];
      this.atHint = `搜索失败：${error instanceof Error ? error.message : String(error)}`;
    }
    this.atLoading = false;
  }

  /** 插入标准 mention 转译：markdown 链接 [basename](relativePath)，目录补尾斜杠。 */
  private insertMention(entry: WorkspaceFileView): void {
    const suffix = entry.type === 'directory' ? '/' : '';
    const label = entry.name.replace(/[\[\]]/g, '');
    const dest = (entry.relativePath + suffix).replace(/[()]/g, '');
    const base = this.inputText.startsWith(this.atPrefix)
      ? this.atPrefix.substring(0, this.atPrefix.length - 1)
      : this.inputText;
    this.inputText = `${base}[${label}](${dest}) `;
    this.closeAtPanel();
    this.scheduleDraftSave();
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

  // ── Builders ──

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
  AttachmentChips() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
      ForEach(this.attachments, (item: AttachmentItem) => {
        Row({ space: 6 }) {
          Text(item.isImage ? '🖼' : '📄')
            .fontSize(12)
          Column({ space: 1 }) {
            Text(item.fileName)
              .fontSize(11)
              .fontColor(ZcodeColors.textPrimary())
              .maxLines(1)
              .constraintSize({ maxWidth: 140 })
            if (item.state === 'uploading') {
              Text(`上传 ${item.sentChunks}/${item.totalChunks}`)
                .fontSize(9)
                .fontColor(ZcodeColors.textTertiary())
            } else if (item.state === 'failed') {
              Text(item.error.length > 0 ? item.error : '上传失败')
                .fontSize(9)
                .fontColor(ZcodeColors.DESTRUCTIVE)
                .maxLines(1)
            } else {
              Text(`${Math.max(1, Math.round(item.bytes / 1024))} KB`)
                .fontSize(9)
                .fontColor(ZcodeColors.textTertiary())
            }
          }
          .alignItems(HorizontalAlign.Start)

          Text('✕')
            .fontSize(10)
            .fontColor(ZcodeColors.textTertiary())
            .onClick(() => {
              this.removeAttachment(item.uploadId);
            })
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(10)
        .backgroundColor(ZcodeColors.card())
        .border({ width: item.state === 'failed' ? 1 : 0, color: ZcodeColors.DESTRUCTIVE })
        .margin({ right: 6, bottom: 4 })
      }, (item: AttachmentItem) => item.uploadId)
    }
    .width('100%')
  }

  @Builder
  AtPanel() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('@ 引用工作区文件')
          .fontSize(11)
          .fontColor(ZcodeColors.textTertiary())
        Blank()
        Text('关闭')
          .fontSize(11)
          .fontColor(ZcodeColors.BRAND_LIGHT)
          .onClick(() => {
            this.closeAtPanel();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ text: this.atQuery, placeholder: '输入文件名模糊搜索…' })
        .fontSize(13)
        .fontColor(ZcodeColors.textPrimary())
        .placeholderColor(ZcodeColors.textTertiary())
        .backgroundColor(ZcodeColors.background())
        .borderRadius(10)
        .onChange((value: string) => {
          this.atQuery = value;
          this.scheduleAtSearch();
        })

      if (this.atLoading) {
        Text('搜索中…')
          .fontSize(11)
          .fontColor(ZcodeColors.textTertiary())
      }
      if (this.atHint.length > 0) {
        Text(this.atHint)
          .fontSize(11)
          .fontColor(ZcodeColors.WARNING)
      }

      List({ space: 2 }) {
        ForEach(this.atResults, (entry: WorkspaceFileView) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(entry.type === 'directory' ? '📁' : '📄')
                .fontSize(12)
              Column({ space: 1 }) {
                Text(entry.name)
                  .fontSize(13)
                  .fontColor(ZcodeColors.textPrimary())
                  .maxLines(1)
                Text(entry.relativePath)
                  .fontSize(10)
                  .fontColor(ZcodeColors.textTertiary())
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(6)
            .borderRadius(8)
            .onClick(() => {
              this.insertMention(entry);
            })
          }
        }, (entry: WorkspaceFileView) => entry.relativePath)
      }
      .height(180)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .padding(10)
    .borderRadius(12)
    .backgroundColor(ZcodeColors.card())
    .border({ width: 1, color: ZcodeColors.BRAND })
    .margin({ left: 16, right: 16, bottom: 4 })
  }

  @Builder
  TabButton(label: string, index: number) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(14)
        .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === index ? ZcodeColors.textPrimary() : ZcodeColors.textTertiary())
      Divider()
        .color(this.activeTab === index ? ZcodeColors.BRAND : Color.Transparent)
        .strokeWidth(2)
        .width(28)
    }
    .onClick(() => {
      this.switchTab(index);
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

  /** 行内片段渲染（粗体/行内代码）。 */
  @Builder
  MdSpans(spans: MdSpan[], size: number, color: string, forceBold: boolean) {
    Text() {
      ForEach(spans, (span: MdSpan) => {
        Span(span.text)
          .fontWeight(span.bold || forceBold ? FontWeight.Bold : FontWeight.Normal)
          .fontFamily(span.code ? 'monospace' : '')
      }, (span: MdSpan) => `${span.text}-${span.bold}-${span.code}`)
    }
    .fontSize(size)
    .fontColor(color)
  }

  /** OUT-1：markdown 块级渲染（段落/标题/列表/引用/代码）。 */
  @Builder
  MdBlockView(block: MdBlock, key: string, rowState: string) {
    if (block.kind === 'code') {
      this.CodeBlock(block.lang, block.spans[0][0].text, block.closed, key)
    } else if (block.kind === 'heading') {
      this.MdSpans(block.spans[0], block.level <= 1 ? 19 : (block.level === 2 ? 17 : 15), ZcodeColors.textPrimary(), true)
    } else if (block.kind === 'list') {
      Column({ space: 3 }) {
        ForEach(block.spans, (line: MdSpan[], lineIndex: number) => {
          Row({ space: 6 }) {
            Text(block.ordered ? `${lineIndex + 1}.` : '•')
              .fontSize(14)
              .fontColor(ZcodeColors.textTertiary())
            this.MdSpans(line, 15, ZcodeColors.textPrimary(), false)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (line: MdSpan[], lineIndex: number) => `${lineIndex}-${line.length}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (block.kind === 'quote') {
      Row({ space: 8 }) {
        Divider()
          .color(ZcodeColors.BRAND)
          .strokeWidth(2)
          .vertical(true)
          .height('100%')
        this.MdSpans(block.spans[0], 14, ZcodeColors.textSecondary(), false)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 8 })
    } else {
      // 段落（失败态降灰）
      this.MdSpans(block.spans[0], 15, rowState === 'failed' ? ZcodeColors.textSecondary() : ZcodeColors.textPrimary(), false)
    }
  }

  /** OUT-2：代码块（语言徽标 + 复制 + 超 20 行折叠；未闭合按暂态标注）。 */
  @Builder
  CodeBlock(lang: string, content: string, closed: boolean, key: string) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(lang.length > 0 ? (closed ? lang : `${lang} · 输出中`) : (closed ? 'code' : 'code · 输出中'))
          .fontSize(10)
          .fontColor(ZcodeColors.textSecondary())
          .backgroundColor(ZcodeColors.background())
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
        Blank()
        Text('复制')
          .fontSize(11)
          .fontColor(ZcodeColors.BRAND_LIGHT)
          .onClick(() => {
            void this.copyText(content);
          })
        if (content.split('\n').length > 20) {
          Text(this.isCodeExpanded(key) ? '收起' : `展开全部 ${content.split('\n').length} 行`)
            .fontSize(11)
            .fontColor(ZcodeColors.BRAND_LIGHT)
            .onClick(() => {
              this.toggleCode(key);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Text(this.isCodeExpanded(key) ? content
          : content.split('\n').slice(0, 20).join('\n'))
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(ZcodeColors.textPrimary())
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .borderRadius(12)
    .backgroundColor(ZcodeColors.background())
    .margin({ top: 4, bottom: 4 })
  }

  /** OUT-8：长按消息操作行（复制 / 引用到输入框）。 */
  @Builder
  MsgActions(row: ConversationRowView) {
    Row({ space: 10 }) {
      Text('复制')
        .fontSize(12)
        .fontColor(ZcodeColors.BRAND_LIGHT)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(8)
        .backgroundColor(ZcodeColors.SURFACE)
        .onClick(() => {
          this.actionsRowId = -1;
          void this.copyText(row.text);
        })
      Text('引用到输入框')
        .fontSize(12)
        .fontColor(ZcodeColors.BRAND_LIGHT)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(8)
        .backgroundColor(ZcodeColors.SURFACE)
        .onClick(() => {
          this.actionsRowId = -1;
          const quote = row.text.length > 400 ? `${row.text.substring(0, 400)}…` : row.text;
          this.inputText = this.inputText.length > 0
            ? `> ${quote}\n${this.inputText}`
            : `> ${quote}\n`;
          this.scheduleDraftSave();
        })
    }
    .margin({ top: 2, bottom: 2 })
  }

  @Builder
  RowView(row: ConversationRowView) {
    if (row.kind === 'userInput') {
      Column({ space: 2 }) {
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
        if (this.actionsRowId === row.rowId) {
          Row() {
            Blank()
            this.MsgActions(row)
          }
          .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 6, bottom: 6 })
      .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
        this.actionsRowId = this.actionsRowId === row.rowId ? -1 : row.rowId;
      }))
    } else if (row.kind === 'assistantText') {
      Column({ space: 4 }) {
        // OUT-1 增量渲染：块级解析 + 稳定 key（前缀块 key 不变 → 组件复用不重建）
        ForEach(this.blocksFor(row), (block: MdBlock, idx: number) => {
          this.MdBlockView(block, this.codeKey(row.rowId, idx), row.state)
        }, (block: MdBlock, idx: number) => `${this.codeKey(row.rowId, idx)}:${mdBlockKey(block)}:${this.blocksTick}`)
        if (row.state === 'failed') {
          // OUT-7：失败回复卡片化 + 重发动作（原文重发，服务端按幂等/上下文处理）
          Row({ space: 10 }) {
            Text('回复生成失败')
              .fontSize(12)
              .fontColor(ZcodeColors.DESTRUCTIVE)
            Text('重发上一条')
              .fontSize(12)
              .fontColor(ZcodeColors.BRAND_LIGHT)
              .onClick(() => {
                this.resendLastInput();
              })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(10)
          .border({ width: 1, color: ZcodeColors.DESTRUCTIVE })
          .margin({ top: 4 })
        }
        if (this.actionsRowId === row.rowId) {
          this.MsgActions(row)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6, bottom: 6 })
      .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
        this.actionsRowId = this.actionsRowId === row.rowId ? -1 : row.rowId;
      }))
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
        if (row.fileCount > 0) {
          Text(`${row.fileCount} 文件 +${row.fileAdditions} −${row.fileDeletions}`)
            .fontSize(10)
            .fontColor(ZcodeColors.BRAND_LIGHT)
        }
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

  /** 单文件 diff（OUT-5 第三级：文件行 → hunks 着色）。 */
  @Builder
  FileChangeCard(item: FileChangeItemView) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(item.path)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(`+${item.additions}`)
          .fontSize(11)
          .fontColor(ZcodeColors.SUCCESS)
        Text(`−${item.deletions}`)
          .fontSize(11)
          .fontColor(ZcodeColors.DESTRUCTIVE)
        Text(this.isFileExpanded(item.path) ? '收起' : '展开')
          .fontSize(11)
          .fontColor(ZcodeColors.BRAND_LIGHT)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.toggleFile(item.path);
      })

      if (item.toolNames.length > 0) {
        Text(`改动来源：${item.toolNames}`)
          .fontSize(10)
          .fontColor(ZcodeColors.textTertiary())
          .width('100%')
      }

      if (this.isFileExpanded(item.path)) {
        ForEach(item.hunks, (hunk: DiffHunkView, hunkIndex: number) => {
          Column({ space: 0 }) {
            Text(`@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@`)
              .fontSize(10)
              .fontColor(ZcodeColors.textTertiary())
              .fontFamily('monospace')
              .width('100%')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(ZcodeColors.SURFACE)
            ForEach(hunk.lines, (line: string, lineIndex: number) => {
              Text(line.length > 0 ? line : ' ')
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor(line.startsWith('+') ? ZcodeColors.SUCCESS
                  : (line.startsWith('-') ? ZcodeColors.DESTRUCTIVE : ZcodeColors.textSecondary()))
                .backgroundColor(line.startsWith('+') ? ZcodeColors.DIFF_ADD
                  : (line.startsWith('-') ? ZcodeColors.DIFF_DEL : Color.Transparent))
                .width('100%')
                .padding({ left: 8, right: 8, top: 1, bottom: 1 })
            }, (line: string, lineIndex: number) => `${hunkIndex}-${lineIndex}-${line}`)
          }
          .width('100%')
          .borderRadius(8)
          .clip(true)
          .margin({ bottom: 6 })
        }, (hunk: DiffHunkView, hunkIndex: number) => `${hunkIndex}-${hunk.newStart}`)
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(12)
    .backgroundColor(ZcodeColors.card())
  }

  /** 变更 Tab（OUT-5）：轮次选择 → 总览条 → 文件列表 → diff。 */
  @Builder
  ChangesTab() {
    Column({ space: 10 }) {
      if (this.turns.length === 0) {
        Column({ space: 8 }) {
          Text('本轮会话还没有文件变更')
            .fontSize(13)
            .fontColor(ZcodeColors.textSecondary())
          Text('Agent 改动文件后，这里会按轮次列出 diff')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
        }
        .width('100%')
        .padding({ top: 80 })
        .alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.turns, (turn: ConversationRowView, index: number) => {
              Text(`变更 ${index + 1}（+${turn.fileAdditions} −${turn.fileDeletions}）`)
                .fontSize(12)
                .fontColor(this.selectedTurnRowId === turn.rowId ? '#FFFFFF' : ZcodeColors.textSecondary())
                .backgroundColor(this.selectedTurnRowId === turn.rowId ? ZcodeColors.BRAND : ZcodeColors.SURFACE)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(999)
                .onClick(() => {
                  if (this.selectedTurnRowId !== turn.rowId) {
                    this.selectedTurnRowId = turn.rowId;
                    this.changesReport = null;
                    void this.loadChanges();
                  }
                })
            }, (turn: ConversationRowView) => `${turn.rowId}-${turn.fileAdditions}-${turn.fileDeletions}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .scrollBar(BarState.Off)

        if (this.changesLoading) {
          Row({ space: 8 }) {
            StatusDot({ tone: StatusTone.Running, dotSize: 9 })
            Text('正在加载该轮变更…')
              .fontSize(12)
              .fontColor(ZcodeColors.textSecondary())
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.changesHint.length > 0) {
          Text(this.changesHint)
            .fontSize(12)
            .fontColor(ZcodeColors.WARNING)
            .width('100%')
            .textAlign(TextAlign.Center)
        } else if (this.changesReport !== null) {
          Text(`${this.changesReport.files} 个文件 · +${this.changesReport.additions} −${this.changesReport.deletions}`
            + `${this.changesReport.state === 'reverted' ? ' · 已回退' : ''}`)
            .fontSize(12)
            .fontColor(ZcodeColors.textSecondary())
            .width('100%')

          if (this.changesReport.items.length === 0) {
            Text('该轮没有文件改动')
              .fontSize(12)
              .fontColor(ZcodeColors.textTertiary())
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 20 })
          }
          List({ space: 8 }) {
            ForEach(this.changesReport.items, (item: FileChangeItemView) => {
              ListItem() {
                this.FileChangeCard(item)
              }
            }, (item: FileChangeItemView) => `${item.path}-${item.additions}-${item.deletions}-${item.hunks.length}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
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
      .padding({ left: 16, right: 20, top: 14, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      // 三 Tab（A5 骨架：对话 / 变更 P0 / 产物占位）
      Row({ space: 28 }) {
        this.TabButton('对话', 0)
        this.TabButton('变更', 1)
        this.TabButton('产物', 2)
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      if (this.activeTab === 0) {
        if (this.stateEvent.state !== 'online') {
          Text(this.stateEvent.state === 'connecting' ? '正在连接电脑…' : `离线（${this.stateEvent.detail}）`)
            .fontSize(11)
            .fontColor(ZcodeColors.WARNING)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(4)
        }

      // OUT-6：当前轮时间线（可折叠，仅对话 Tab）
      if (this.activeTab === 0 && this.timeline.length > 0) {
        Column({ space: 4 }) {
          Row({ space: 8 }) {
            StatusDot({ tone: this.hasLiveWork ? StatusTone.Running : StatusTone.Success, dotSize: 8 })
            Text(`任务步骤 · ${this.timeline.length}`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textPrimary())
            if (this.timeline.length > 0) {
              Text(`最新: ${this.timeline[this.timeline.length - 1].kind === 'toolCall' ? this.timeline[this.timeline.length - 1].toolName : '子代理'}`)
                .fontSize(10)
                .fontColor(ZcodeColors.textTertiary())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            Text(this.timelineExpanded ? '收起' : '展开')
              .fontSize(11)
              .fontColor(ZcodeColors.BRAND_LIGHT)
              .onClick(() => {
                this.timelineExpanded = !this.timelineExpanded;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.timelineExpanded) {
            ForEach(this.timeline, (step: ConversationRowView, index: number) => {
              Row({ space: 8 }) {
                Text(`${index + 1}`)
                  .fontSize(10)
                  .fontColor(ZcodeColors.textTertiary())
                  .width(18)
                StatusDot({ tone: this.toolTone(step.state), dotSize: 7 })
                Text(step.kind === 'toolCall' ? step.toolName : `子代理·${step.subagentType}`)
                  .fontSize(11)
                  .fontColor(ZcodeColors.textSecondary())
                if (step.errorMessage.length > 0) {
                  Text('失败')
                    .fontSize(10)
                    .fontColor(ZcodeColors.DESTRUCTIVE)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 6, top: 2, bottom: 2 })
            }, (step: ConversationRowView) => `${step.rowId}-${step.state}`)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        .margin({ bottom: 2 })
      }

      // 对话行
      List({ space: 0, scroller: this.listScroller }) {
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
        .onReachEnd(() => {
          this.atBottom = true;
        })
        .onScrollIndex((start: number, end: number) => {
          if (this.rows.length > 2 && end < this.rows.length - 2) {
            this.atBottom = false;
          }
        })

        // OUT-1：上滑阅读历史时的「回到底部」浮标
        if (!this.atBottom) {
          Text('↓ 回到底部')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(999)
            .backgroundColor(ZcodeColors.BRAND)
            .shadow({ radius: 12, color: 'rgba(76, 125, 255, 0.45)', offsetX: 0, offsetY: 2 })
            .margin({ bottom: 6 })
            .onClick(() => {
              this.atBottom = true;
              this.listScroller.scrollEdge(Edge.Bottom);
            })
        }

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

        // INP-4：@ 引用面板
        if (this.atPanelOpen) {
          this.AtPanel()
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
            if (this.attachments.length > 0) {
              this.AttachmentChips()
            }
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
                this.onMainInputChanged(value);
              })

            Row({ space: 6 }) {
              Text('📸')
                .fontSize(14)
                .opacity(this.attachBusy ? 0.4 : 1)
                .onClick(() => {
                  void this.pickCamera();
                })
              Text('📷')
                .fontSize(14)
                .opacity(this.attachBusy ? 0.4 : 1)
                .onClick(() => {
                  void this.pickImage();
                })
              Text('📄')
                .fontSize(13)
                .opacity(this.attachBusy ? 0.4 : 1)
                .onClick(() => {
                  void this.pickDocument();
                })
              Text('模式')
                .fontSize(10)
                .fontColor(ZcodeColors.textTertiary())
              this.ModeChip('Agent', 'build')
              this.ModeChip('问答', 'ask')
              this.ModeChip('Plan', 'plan')
              Blank()
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
            color: 'rgba(76, 125, 255, 0.35)',
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
      } else if (this.activeTab === 1) {
        this.ChangesTab()
      } else {
        Column({ space: 8 }) {
          Text('产物预览')
            .fontSize(14)
            .fontColor(ZcodeColors.textSecondary())
          Text('会话生成的文件（图片/文档/网页）网格预览将在后续批次提供（P1）')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 40, right: 40 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
  }
}


/** 选择器取回的一个文件（全量读入字节；20MiB 上限在读取时即拦截）。 */
interface PickedFile {
  fileName: string;
  mime: string;
  bytes: Uint8Array;
  localUri: string;
  isImage: boolean;
}

function guessMime(fileName: string): string {
  const lowered = fileName.toLowerCase();
  if (lowered.endsWith('.jpg') || lowered.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lowered.endsWith('.png')) {
    return 'image/png';
  }
  if (lowered.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lowered.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lowered.endsWith('.pdf')) {
    return 'application/pdf';
  }
  if (lowered.endsWith('.txt') || lowered.endsWith('.md')) {
    return 'text/plain';
  }
  if (lowered.endsWith('.json')) {
    return 'application/json';
  }
  if (lowered.endsWith('.zip')) {
    return 'application/zip';
  }
  return 'application/octet-stream';
}

function readPickedFile(uri: string): PickedFile {
  const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(file.fd);
    if (stat.size > 20 * 1024 * 1024) {
      throw new Error('附件超过 20MiB 上限');
    }
    const bytes = new Uint8Array(stat.size);
    let bufferOffset = 0;
    while (bufferOffset < stat.size) {
      const read = fs.readSync(file.fd, bytes.subarray(bufferOffset), { offset: bufferOffset });
      if (read <= 0) {
        break;
      }
      bufferOffset += read;
    }
    const fileName = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
    const picked: PickedFile = {
      fileName: fileName,
      mime: guessMime(fileName),
      bytes: bytes,
      localUri: uri,
      isImage: false,
    };
    return picked;
  } finally {
    fs.closeSync(file);
  }
}
