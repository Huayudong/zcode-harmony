import router from '@ohos.router';
import { WorkbenchController, type ConnectionStateEvent } from 'connection';
import type { IDisposable } from 'protocol';
import type { SessionSummaryView } from 'protocol';
import { LightBloomButton, ZcodeColors, StatusDot, StatusTone } from 'uikit';

/** 会话列表 → 会话页的路由参数。 */
export interface SessionRouteParams {
  sessionId: string;
  title: string;
}

/**
 * 工作台首页（A5）：已配对后的会话列表。
 * 数据源 = WorkbenchController 的 sessions-index 订阅归约；离线时先画 SQLite 缓存，
 * 列表头部给出连接状态与重试入口。
 */
@Entry
@Component
struct SessionList {
  @State sessions: SessionSummaryView[] = [];
  @State stateEvent: ConnectionStateEvent = { state: 'offline', detail: '正在启动…' } as ConnectionStateEvent;
  @State fromCache: boolean = true;
  @State controllerReady: boolean = false;
  private controller: WorkbenchController | null = null;
  private disposables: IDisposable[] = [];

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
      }));
      this.disposables.push(controller.onSessionsChanged((list: SessionSummaryView[]) => {
        this.sessions = list;
        this.fromCache = controller.isFromCache();
      }));
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

  private openPairing(): void {
    router.pushUrl({ url: 'pages/pairing/PairingWelcome' }).catch(() => {});
  }

  private openSession(summary: SessionSummaryView): void {
    const params: SessionRouteParams = { sessionId: summary.sessionId, title: summary.title };
    router.pushUrl({ url: 'pages/workbench/SessionDetail', params: params }).catch(() => {});
  }

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

  build() {
    Column() {
      // 头部：档案名 + 连接状态
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
          Text('重试')
            .fontSize(13)
            .fontColor(ZcodeColors.BRAND_LIGHT)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(10)
            .backgroundColor(ZcodeColors.SURFACE)
            .onClick(() => {
              this.retryConnection();
            })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })
      .alignItems(VerticalAlign.Center)

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
        List({ space: 8 }) {
          ForEach(this.sessions, (summary: SessionSummaryView) => {
            ListItem() {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
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
                      Text(this.phaseLabel(summary))
                        .fontSize(11)
                        .fontColor(ZcodeColors.textSecondary())
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
            }
            .onClick(() => {
              this.openSession(summary);
            })
          }, (summary: SessionSummaryView) => `${summary.sessionId}-${summary.lastActivityAt}-${summary.phase}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
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
  }

  private emptyHint(): string {
    if (this.controllerReady && this.controller !== null && this.controller.getStartupFailure() === 'no-profile') {
      return '还没有配对的电脑，先完成配对';
    }
    if (this.stateEvent.state === 'connecting') {
      return '正在连接电脑…';
    }
    if (this.stateEvent.state === 'online') {
      return '电脑上还没有会话，发起一个任务后这里会出现';
    }
    return '未连接电脑，连接后显示会话列表';
  }
}
