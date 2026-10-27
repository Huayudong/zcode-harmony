import router from '@ohos.router';
import preferences from '@ohos.data.preferences';
import { WorkbenchController, type ConnectionStateEvent } from 'connection';
import type { IDisposable } from 'protocol';
import type { SessionSummaryView } from 'protocol';
import {
  LightBloomButton,
  ZcodeColors,
  DesignTokens,
  StatusDot,
  StatusTone,
  ZBadge,
  ZBadgeVariant,
  ZButton,
  ZButtonSize,
  ZButtonVariant,
  ZDialog,
  ZInput,
  ZSheet,
  ZToast,
} from 'uikit';

/** 会话列表 → 会话页的路由参数。 */
export interface SessionRouteParams {
  sessionId: string;
  title: string;
}

interface SessionGroup {
  label: string;
  items: SessionSummaryView[];
}

/** 轻提示走 shadcn/Sonner 语义的全局 Toast（批次28）。 */
function showToast(message: string): void {
  ZToast.show(message);
}

/**
 * 工作台首页（A5 + A9 批次14 增强）：CONN-2 下拉刷新重试、本地搜索、
 * 今天/近7天/更早分组、置顶（本地偏好）、重命名（renameSession 幂等命令）。
 * 数据源 = WorkbenchController 的 sessions-index 订阅归约；离线先画 SQLite 缓存。
 */
@Entry
@Component
struct SessionList {
  @State sessions: SessionSummaryView[] = [];
  @State stateEvent: ConnectionStateEvent = { state: 'offline', detail: '正在启动…' } as ConnectionStateEvent;
  @State fromCache: boolean = true;
  @State controllerReady: boolean = false;
  @State refreshing: boolean = false;
  @State searchQuery: string = '';
  @State pinnedIds: string[] = [];
  @State actionsSessionId: string = '';
  @State actionsTitle: string = '';
  @State actionsPinned: boolean = false;
  @State renamingId: string = '';
  @State renameText: string = '';
  @State deleteId: string = '';
  private controller: WorkbenchController | null = null;
  private disposables: IDisposable[] = [];
  private pinnedPrefs: preferences.Preferences | null = null;
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.disposables = [];
  }

  private async bootstrap(): Promise<void> {
    try {
      const controller = await WorkbenchController.shared(getContext(this));
      this.controller = controller;
      this.stateEvent = controller.getStateEvent();
      this.sessions = controller.getSessionList();
      this.fromCache = controller.isFromCache();
      this.disposables.push(controller.onStateChange((event: ConnectionStateEvent) => {
        this.stateEvent = event;
        if (this.refreshing && (event.state === 'online' || event.state === 'backoff' || event.state === 'offline')) {
          this.refreshing = false;
          if (this.refreshTimer >= 0) {
            clearTimeout(this.refreshTimer);
            this.refreshTimer = -1;
          }
        }
      }));
      this.disposables.push(controller.onSessionsChanged((list: SessionSummaryView[]) => {
        this.sessions = list;
        this.fromCache = controller.isFromCache();
      }));
      try {
        this.pinnedPrefs = await preferences.getPreferences(getContext(this), { name: 'zcode-pinned' });
        const raw = await this.pinnedPrefs.get('pinned', '[]') as string;
        const parsed: string[] = JSON.parse(raw);
        this.pinnedIds = Array.isArray(parsed) ? parsed : [];
      } catch (error) {
        this.pinnedIds = [];
      }
      this.controllerReady = true;
    } catch (error) {
      // shared() 不应失败；防御性兜底（预览器异常环境）保持空态。
      this.controllerReady = false;
    }
  }

  private retryConnection(): void {
    if (this.controller !== null) {
      this.controller.retry();
    }
  }

  private startRefresh(): void {
    if (this.controller === null) {
      return;
    }
    this.refreshing = true;
    this.controller.retry();
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout((): void => {
      this.refreshing = false;
      this.refreshTimer = -1;
    }, 5000);
  }

  private openPairing(): void {
    router.pushUrl({ url: 'pages/pairing/PairingWelcome' }).catch(() => {});
  }

  private openSession(summary: SessionSummaryView): void {
    const params: SessionRouteParams = { sessionId: summary.sessionId, title: summary.title };
    router.pushUrl({ url: 'pages/workbench/SessionDetail', params: params }).catch(() => {});
  }

  // ── 搜索 / 分组 / 置顶 ──

  private filteredSessions(): SessionSummaryView[] {
    const query = this.searchQuery.trim().toLowerCase();
    const pinned: SessionSummaryView[] = [];
    const rest: SessionSummaryView[] = [];
    for (const summary of this.sessions) {
      if (query.length > 0
        && summary.title.toLowerCase().indexOf(query) < 0
        && summary.lastAssistantPreview.toLowerCase().indexOf(query) < 0) {
        continue;
      }
      if (this.pinnedIds.indexOf(summary.sessionId) >= 0) {
        pinned.push(summary);
      } else {
        rest.push(summary);
      }
    }
    return pinned.concat(rest);
  }

  private buildGroups(): SessionGroup[] {
    const startOfDay = new Date();
    startOfDay.setHours(0, 0, 0, 0);
    const todayFloor = startOfDay.getTime();
    const weekFloor = todayFloor - 7 * 24 * 60 * 60 * 1000;
    const all = this.filteredSessions();
    const groups: SessionGroup[] = [
      { label: '今天', items: [] },
      { label: '近 7 天', items: [] },
      { label: '更早', items: [] },
    ];
    for (const summary of all) {
      if (summary.lastActivityAt >= todayFloor) {
        groups[0].items.push(summary);
      } else if (summary.lastActivityAt >= weekFloor) {
        groups[1].items.push(summary);
      } else {
        groups[2].items.push(summary);
      }
    }
    return groups.filter((group: SessionGroup) => group.items.length > 0);
  }

  private isPinned(sessionId: string): boolean {
    return this.pinnedIds.indexOf(sessionId) >= 0;
  }

  private async togglePin(sessionId: string): Promise<void> {
    const next: string[] = [];
    let removed = false;
    for (const id of this.pinnedIds) {
      if (id === sessionId) {
        removed = true;
      } else {
        next.push(id);
      }
    }
    if (!removed) {
      next.push(sessionId);
    }
    this.pinnedIds = next;
    this.actionsSessionId = '';
    if (this.pinnedPrefs !== null) {
      try {
        await this.pinnedPrefs.put('pinned', JSON.stringify(this.pinnedIds));
        await this.pinnedPrefs.flush();
      } catch (error) {
        // 置顶仅本地偏好，失败不阻塞
      }
    }
  }

  /** M1 抽屉「新建按钮」：createSession draft → 直达新会话页。 */
  private async createNewSession(): Promise<void> {
    if (this.controller === null) {
      return;
    }
    try {
      const sessionId = await this.controller.createSession();
      const params: SessionRouteParams = { sessionId: sessionId, title: '' };
      router.pushUrl({ url: 'pages/workbench/SessionDetail', params: params }).catch(() => {});
    } catch (error) {
      showToast(`新建会话失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  /** 删除会话：服务端权威删除，列表经 sessions-index delta 自愈。 */
  private async confirmDelete(sessionId: string): Promise<void> {
    if (this.controller === null) {
      return;
    }
    this.actionsSessionId = '';
    this.deleteId = '';
    try {
      await this.controller.deleteSession(sessionId);
      showToast('已提交删除');
    } catch (error) {
      showToast(`删除失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  /** 打开长按菜单（记录标题/置顶态供菜单展示）。 */
  private openActions(summary: SessionSummaryView): void {
    if (this.actionsSessionId === summary.sessionId) {
      this.actionsSessionId = '';
      return;
    }
    this.actionsSessionId = summary.sessionId;
    this.actionsTitle = this.titleOf(summary);
    this.actionsPinned = this.isPinned(summary.sessionId);
  }

  private startRename(sessionId: string, title: string): void {
    this.actionsSessionId = '';
    this.renamingId = sessionId;
    this.renameText = title;
  }

  private async confirmRename(): Promise<void> {
    const sessionId = this.renamingId;
    const title = this.renameText.trim();
    this.renamingId = '';
    if (sessionId.length === 0 || title.length === 0 || this.controller === null) {
      return;
    }
    try {
      await this.controller.renameSession(sessionId, title);
      showToast('已提交重命名');
    } catch (error) {
      showToast(`重命名失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  // ── 视图辅助 ──

  private stateTone(): StatusTone {
    if (this.stateEvent.state === 'online') {
      return StatusTone.Success;
    }
    if (this.stateEvent.state === 'connecting') {
      return StatusTone.Running;
    }
    return StatusTone.Offline;
  }

  private stateLabel(): string {
    if (this.stateEvent.state !== 'online' && this.sessions.length > 0 && this.fromCache) {
      return `离线 · 显示缓存（${this.stateEvent.detail}）`;
    }
    return this.stateEvent.detail;
  }

  private phaseLabel(summary: SessionSummaryView): string {
    if (summary.pendingInteractionCount > 0) {
      return `${summary.pendingInteractionCount} 个待处理`;
    }
    if (summary.phase === 'running' || summary.phase === 'prewarming' || summary.phase === 'draft') {
      return '进行中';
    }
    if (summary.phase === 'completedSuccess') {
      return '已完成';
    }
    if (summary.phase === 'completedInterrupted') {
      return '已中断';
    }
    if (summary.phase === 'error') {
      return '出错了';
    }
    return '';
  }

  private phaseTone(summary: SessionSummaryView): StatusTone {
    if (summary.pendingInteractionCount > 0) {
      return StatusTone.PendingConfirm;
    }
    if (summary.phase === 'running' || summary.phase === 'prewarming' || summary.phase === 'draft') {
      return StatusTone.Running;
    }
    if (summary.phase === 'completedSuccess') {
      return StatusTone.Success;
    }
    if (summary.phase === 'error') {
      return StatusTone.Failed;
    }
    if (summary.phase === 'completedInterrupted') {
      return StatusTone.Warning;
    }
    return StatusTone.Offline;
  }

  private relativeTime(epochMs: number): string {
    if (epochMs <= 0) {
      return '';
    }
    const delta = Date.now() - epochMs;
    const minute = 60_000;
    if (delta < minute) {
      return '刚刚';
    }
    if (delta < 60 * minute) {
      return `${Math.floor(delta / minute)} 分钟前`;
    }
    if (delta < 24 * 60 * minute) {
      return `${Math.floor(delta / (60 * minute))} 小时前`;
    }
    const date = new Date(epochMs);
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    return `${month}-${day}`;
  }

  private titleOf(summary: SessionSummaryView): string {
    return summary.title.length > 0 ? summary.title : '未命名会话';
  }

  private emptyHint(): string {
    if (this.controllerReady && this.controller !== null && this.controller.getStartupFailure() === 'no-profile') {
      return '还没有配对的电脑，先完成配对';
    }
    if (this.stateEvent.state === 'connecting') {
      return '正在连接电脑…';
    }
    if (this.stateEvent.state === 'online') {
      if (this.searchQuery.trim().length > 0) {
        return '没有匹配的会话';
      }
      return '电脑上还没有会话，发起一个任务后这里会出现';
    }
    return '未连接电脑，连接后显示会话列表';
  }

  // ── Builders ──

  @Builder
  SessionCard(summary: SessionSummaryView) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (this.isPinned(summary.sessionId)) {
          Text('📌')
            .fontSize(11)
        }
        Text(this.titleOf(summary))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.relativeTime(summary.lastActivityAt))
          .fontSize(11)
          .fontColor(ZcodeColors.textTertiary())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        if (this.phaseLabel(summary).length > 0) {
          Row({ space: 5 }) {
            StatusDot({ tone: this.phaseTone(summary), dotSize: 7 })
            ZBadge({
              label: this.phaseLabel(summary),
              variant: ZBadgeVariant.SECONDARY,
            })
          }
          .alignItems(VerticalAlign.Center)
        }
        if (summary.lastAssistantPreview.length > 0) {
          Text(summary.lastAssistantPreview)
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .padding(14)
    .borderRadius(14)
    .backgroundColor(ZcodeColors.card())
    .border({ width: 1, color: ZcodeColors.BORDER })
    .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
      this.openActions(summary);
    }))
    .onClick(() => {
      if (this.actionsSessionId.length === 0) {
        this.openSession(summary);
      } else {
        this.actionsSessionId = '';
      }
    })
  }

  /** 长按菜单内容（shadcn Sheet 内的条目列表）。 */
  @Builder
  ActionMenu() {
    Column() {
      Text(this.actionsTitle.length > 0 ? this.actionsTitle : '会话')
        .fontSize(12)
        .fontColor(ZcodeColors.textTertiary())
        .width('100%')
        .margin({ bottom: 4 })

      Text(this.actionsPinned ? '取消置顶' : '置顶')
        .fontSize(15)
        .fontColor(ZcodeColors.textPrimary())
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          void this.togglePin(this.actionsSessionId);
        })

      Text('重命名')
        .fontSize(15)
        .fontColor(ZcodeColors.textPrimary())
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.startRename(this.actionsSessionId, this.actionsTitle);
        })

      Text('删除')
        .fontSize(15)
        .fontColor(ZcodeColors.destructive())
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.deleteId = this.actionsSessionId;
        })

      Text('归档请用桌面端（v4 协议暂无归档命令）')
        .fontSize(11)
        .fontColor(ZcodeColors.textTertiary())
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SessionGroups() {
    ForEach(this.buildGroups(), (group: SessionGroup) => {
      ListItem() {
        Column({ space: 8 }) {
          Text(group.label)
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())
            .width('100%')
            .margin({ top: 6 })
          ForEach(group.items, (summary: SessionSummaryView) => {
            this.SessionCard(summary)
          }, (summary: SessionSummaryView) => `${summary.sessionId}-${summary.lastActivityAt}-${summary.phase}`)
        }
        .width('100%')
      }
    }, (group: SessionGroup) => `${group.label}-${group.items.length}`)
  }

  build() {
    Stack() {
      Column() {
        // 头部：档案名 + 连接状态 + 设置入口
        Row({ space: 10 }) {
          StatusDot({ tone: this.stateTone(), dotSize: 10 })
          Column({ space: 2 }) {
            Text(this.controller !== null && this.controller.getServerName().length > 0
              ? this.controller.getServerName() : '我的电脑')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textPrimary())
            Text(this.stateLabel())
              .fontSize(11)
              .fontColor(this.stateEvent.state === 'online' ? ZcodeColors.textTertiary() : ZcodeColors.WARNING)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.stateEvent.state !== 'online') {
            ZButton({
              label: '重试',
              variant: ZButtonVariant.SECONDARY,
              btnSize: ZButtonSize.SM,
              onTap: () => {
                this.retryConnection();
              },
            })
          }

          ZButton({
            label: '＋',
            variant: ZButtonVariant.GHOST,
            btnSize: ZButtonSize.ICON,
            iconExtent: 36,
            fontSize: 22,
            onTap: () => {
              void this.createNewSession();
            },
          })
          .margin({ right: 6 })

          ZButton({
            label: '⚙',
            variant: ZButtonVariant.GHOST,
            btnSize: ZButtonSize.ICON,
            iconExtent: 36,
            fontSize: 18,
            onTap: () => {
              router.pushUrl({ url: 'pages/settings/Settings' }).catch(() => {});
            },
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        // A9：本地搜索（shadcn Input 语义：聚焦时描边切 ring）
        ZInput({
          placeholder: '搜索会话标题…',
          value: this.searchQuery,
          fontSize: 13,
          onValueChange: (value: string) => {
            this.searchQuery = value;
          },
        })
        .margin({ left: 16, right: 16, bottom: 8 })

        if (this.sessions.length === 0) {
          Column({ space: 12 }) {
            StatusDot({ tone: this.stateEvent.state === 'connecting' ? StatusTone.Running : StatusTone.Offline, dotSize: 12 })
            Text(this.emptyHint())
              .fontSize(13)
              .fontColor(ZcodeColors.textSecondary())
              .textAlign(TextAlign.Center)
            if (this.controllerReady && this.controller !== null && this.controller.getStartupFailure() === 'no-profile') {
              LightBloomButton({
                label: '连接你的电脑',
                destructive: false,
                onAction: (): void => {
                  this.openPairing();
                }
              })
            }
          }
          .width('100%')
          .padding({ top: 120, left: 40, right: 40 })
        } else {
          // CONN-2 下拉刷新（重试连接，带水位重订阅即刷新数据）
          Refresh({ refreshing: this.refreshing }) {
            List({ space: 8 }) {
              this.SessionGroups()
            }
            .width('100%')
            .height('100%')
            .padding({ left: 16, right: 16 })
          }
          .onRefreshing(() => {
            this.startRefresh();
          })
          .width('100%')
          .layoutWeight(1)
        }

        Blank()

        Text('ZCode Harmony · 工作台')
          .fontSize(10)
          .fontColor(ZcodeColors.textTertiary())
          .margin({ bottom: 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ZcodeColors.background())
      .alignItems(HorizontalAlign.Center)

      // 重命名浮层（shadcn Dialog 语义：遮罩 + 居中面板 + 动作区）
      if (this.renamingId.length > 0) {
        ZDialog({
          title: '重命名会话',
          confirmLabel: '保存',
          cancelLabel: '取消',
          onConfirm: () => {
            void this.confirmRename();
          },
          onCancel: () => {
            this.renamingId = '';
          },
        }) {
          ZInput({
            placeholder: '新的会话标题',
            value: this.renameText,
            onValueChange: (value: string) => {
              this.renameText = value;
            },
          })
          .margin({ top: 12 })
        }
      }

      // 长按操作菜单（shadcn Sheet 语义：底部抽屉 + 条目列表）
      // 包裹层用原生 Stack：ArkUI 里自定义组件在 Stack 中的百分比高度解析为内容高度，
      // 原生容器能拿到确定尺寸，overlay 才能铺满整屏（遮罩 + 贴底面板）。
      if (this.actionsSessionId.length > 0) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(DesignTokens.SCRIM)
            .onClick(() => {
              this.actionsSessionId = '';
            })
          ZSheet({
            title: '会话操作',
            onClose: () => {
              this.actionsSessionId = '';
            },
          }) {
            this.ActionMenu()
          }
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Bottom)
      }

      // 删除确认（shadcn AlertDialog 语义：破坏性动作二次确认）
      if (this.deleteId.length > 0) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(DesignTokens.SCRIM)
            .onClick(() => {
              this.deleteId = '';
            })
          ZDialog({
            title: '删除会话',
            message: '删除后不可恢复，确认删除该会话？',
            confirmLabel: '删除',
            cancelLabel: '取消',
            destructive: true,
            onConfirm: () => {
              void this.confirmDelete(this.deleteId);
            },
            onCancel: () => {
              this.deleteId = '';
            },
          }) {
          }
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
