import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import {
  WorkbenchController,
  ProfileStore,
  type ConnectionProfile,
  type ConnectionStateEvent,
  type NotificationLevel
} from 'connection';
import { ZcodeColors, StatusDot, StatusTone } from 'uikit';

/**
 * 设置页（A9 基础项，PRD 4.7 P0）：通知分级 / Server 档案管理 / 连接诊断 / 缓存清理。
 * 主题为深色优先（浅色主题属 M2）；诊断 = 连接状态与队列水位的只读视图 + 手动重连。
 */
@Entry
@Component
struct Settings {
  @State stateEvent: ConnectionStateEvent = { state: 'offline', detail: '' } as ConnectionStateEvent;
  @State notifyLevel: NotificationLevel = 'approval-only';
  @State profiles: ConnectionProfile[] = [];
  @State activeProfileId: string = '';
  @State pendingCommands: number = 0;
  @State watermarkCount: number = 0;
  @State busy: boolean = false;
  private controller: WorkbenchController | null = null;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const controller = await WorkbenchController.shared(getContext(this));
    this.controller = controller;
    this.stateEvent = controller.getStateEvent();
    this.notifyLevel = controller.getNotificationLevel();
    this.pendingCommands = controller.getPendingCommandCount();
    this.watermarkCount = controller.getWatermarkCount();
    const store = await ProfileStore.open(getContext(this));
    this.profiles = await store.listProfiles();
    const active = await store.activeProfile();
    this.activeProfileId = active !== null ? active.id : '';
  }

  private async setLevel(level: NotificationLevel): Promise<void> {
    this.notifyLevel = level;
    if (this.controller !== null) {
      await this.controller.setNotificationLevel(level);
    }
    promptAction.showToast({ message: '通知分级已更新' });
  }

  private async activateProfile(profile: ConnectionProfile): Promise<void> {
    if (this.busy || profile.id === this.activeProfileId) {
      return;
    }
    this.busy = true;
    try {
      const store = await ProfileStore.open(getContext(this));
      await store.saveProfile(profile);
      this.activeProfileId = profile.id;
      if (this.controller !== null) {
        await this.controller.restart();
        this.stateEvent = this.controller.getStateEvent();
      }
      promptAction.showToast({ message: `已切换到 ${profile.name}` });
    } catch (error) {
      promptAction.showToast({ message: `切换失败：${String(error)}` });
    }
    this.busy = false;
  }

  private async clearCache(): Promise<void> {
    if (this.controller === null) {
      return;
    }
    await this.controller.clearLocalCache();
    promptAction.showToast({ message: '本地会话缓存与草稿已清除' });
  }

  private levelLabel(level: NotificationLevel): string {
    if (level === 'approval-only') {
      return '仅等待确认';
    }
    if (level === 'all') {
      return '全部';
    }
    return '关闭';
  }

  @Builder
  LevelChip(value: NotificationLevel) {
    Text(this.levelLabel(value))
      .fontSize(13)
      .fontColor(this.notifyLevel === value ? '#FFFFFF' : ZcodeColors.textSecondary())
      .backgroundColor(this.notifyLevel === value ? ZcodeColors.BRAND : ZcodeColors.SURFACE)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(999)
      .onClick(() => {
        void this.setLevel(value);
      })
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(22)
          .fontColor(ZcodeColors.textSecondary())
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 20, top: 14, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 12 }) {
          // 连接与诊断
          Column({ space: 8 }) {
            Text('连接与诊断')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textSecondary())
              .width('100%')
            Row({ space: 8 }) {
              StatusDot({ tone: this.stateEvent.state === 'online' ? StatusTone.Success
                : (this.stateEvent.state === 'connecting' ? StatusTone.Running : StatusTone.Offline), dotSize: 10 })
              Column({ space: 2 }) {
                Text(`${this.stateEvent.state} · ${this.stateEvent.detail}`)
                  .fontSize(13)
                  .fontColor(ZcodeColors.textPrimary())
                Text(`订阅水位 ${this.watermarkCount} 条 · 待发命令 ${this.pendingCommands} 条`)
                  .fontSize(11)
                  .fontColor(ZcodeColors.textTertiary())
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('重连')
                .fontSize(12)
                .fontColor('#FFFFFF')
                .backgroundColor(ZcodeColors.BRAND)
                .borderRadius(8)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .onClick(() => {
                  if (this.controller !== null) {
                    this.controller.retry();
                  }
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .padding(14)
          .borderRadius(14)
          .backgroundColor(ZcodeColors.card())

          // Server 档案管理
          Column({ space: 10 }) {
            Text('Server 管理')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textSecondary())
              .width('100%')
            ForEach(this.profiles, (profile: ConnectionProfile) => {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(profile.name.length > 0 ? profile.name : profile.host)
                    .fontSize(14)
                    .fontColor(ZcodeColors.textPrimary())
                  Text(`${profile.host}:${profile.port}`)
                    .fontSize(11)
                    .fontColor(ZcodeColors.textTertiary())
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (profile.id === this.activeProfileId) {
                  Text('当前活跃')
                    .fontSize(11)
                    .fontColor(ZcodeColors.SUCCESS)
                } else {
                  Text('设为活跃')
                    .fontSize(12)
                    .fontColor(ZcodeColors.BRAND_LIGHT)
                    .onClick(() => {
                      void this.activateProfile(profile);
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(10)
              .borderRadius(10)
              .backgroundColor(ZcodeColors.SURFACE)
            }, (profile: ConnectionProfile) => profile.id)

            Text('重新配对新电脑 ›')
              .fontSize(12)
              .fontColor(ZcodeColors.BRAND_LIGHT)
              .onClick(() => {
                router.pushUrl({ url: 'pages/pairing/PairingWelcome' }).catch(() => {});
              })
              .width('100%')
          }
          .padding(14)
          .borderRadius(14)
          .backgroundColor(ZcodeColors.card())

          // 通知分级
          Column({ space: 10 }) {
            Text('通知分级')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textSecondary())
              .width('100%')
            Row({ space: 8 }) {
              this.LevelChip('approval-only')
              this.LevelChip('all')
              this.LevelChip('off')
              Blank()
            }
            .width('100%')
            Text('前台在线时本地提醒；Push 推送属后续版本')
              .fontSize(10)
              .fontColor(ZcodeColors.textTertiary())
              .width('100%')
          }
          .padding(14)
          .borderRadius(14)
          .backgroundColor(ZcodeColors.card())

          // 外观与缓存
          Column({ space: 10 }) {
            Text('外观与存储')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textSecondary())
              .width('100%')
            Row() {
              Text('主题')
                .fontSize(14)
                .fontColor(ZcodeColors.textPrimary())
              Blank()
              Text('深色（默认）· 浅色主题后续版本')
                .fontSize(11)
                .fontColor(ZcodeColors.textTertiary())
            }
            .width('100%')
            Button('清除本地会话缓存与草稿')
              .fontSize(13)
              .fontColor(ZcodeColors.DESTRUCTIVE)
              .backgroundColor(ZcodeColors.SURFACE)
              .borderRadius(10)
              .width('100%')
              .onClick(() => {
                void this.clearCache();
              })
          }
          .padding(14)
          .borderRadius(14)
          .backgroundColor(ZcodeColors.card())

          Text('ZCode Harmony v0.1.0 · 数据全程不出你的电脑')
            .fontSize(10)
            .fontColor(ZcodeColors.textTertiary())
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ bottom: 20 })
        }
        .padding({ left: 16, right: 16, top: 4 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
  }
}
