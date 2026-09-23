import router from '@ohos.router';
import { ConnectionProfile, ProfileStore } from 'connection';
import { LightBloomButton, ZcodeColors, StatusDot, StatusTone } from 'uikit';

/**
 * 首页：未连接态（ONB-1 入口）与已配对档案态。
 * 会话工作台在 A5 批次替换本页；档案存在时本批仅展示连接信息。
 */
@Entry
@Component
struct Index {
  @State profile: ConnectionProfile | null = null;
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.loadProfile();
  }

  private async loadProfile(): Promise<void> {
    this.loading = true;
    try {
      const store = await ProfileStore.open(getContext(this));
      this.profile = await store.activeProfile();
    } catch (error) {
      // 档案读取失败按未连接处理（首启/预览器环境），不阻塞页面。
      this.profile = null;
    }
    this.loading = false;
  }

  private openPairing(): void {
    router.pushUrl({ url: 'pages/pairing/PairingWelcome' }).catch(() => {});
  }

  build() {
    Column() {
      Text('ZCode Harmony')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ZcodeColors.textPrimary())
        .margin({ top: 72, bottom: 8 })

      Text('Agent 在你的电脑上干活，手机随时接管')
        .fontSize(14)
        .fontColor(ZcodeColors.textSecondary())
        .margin({ bottom: 48 })

      if (this.loading) {
        Row({ space: 8 }) {
          StatusDot({ tone: StatusTone.PendingConfirm, dotSize: 10 })
          Text('正在读取连接档案…')
            .fontSize(14)
            .fontColor(ZcodeColors.textSecondary())
        }
        .margin({ bottom: 48 })
      } else if (this.profile !== null) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            StatusDot({ tone: StatusTone.Success, dotSize: 10 })
            Text(this.profile.name.length > 0 ? this.profile.name : '我的电脑')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textPrimary())
          }
          .alignItems(VerticalAlign.Center)

          Text(`${this.profile.host}:${this.profile.port}`)
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())

          Text('已配对 · 会话工作台建设中（A5 批次接入）')
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor(ZcodeColors.card())
        .margin({ bottom: 48 })

        LightBloomButton({
          label: '重新配对',
          destructive: true,
          onAction: () => {
            this.openPairing();
          }
        })
      } else {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            StatusDot({ tone: StatusTone.Offline, dotSize: 10 })
            Text('尚未连接电脑')
              .fontSize(14)
              .fontColor(ZcodeColors.textSecondary())
          }
          .alignItems(VerticalAlign.Center)
        }
        .margin({ bottom: 48 })

        LightBloomButton({
          label: '连接你的电脑',
          destructive: false,
          onAction: () => {
            this.openPairing();
          }
        })
      }

      Blank()

      Text('v0.1.0 · 配对向导已就绪')
        .fontSize(11)
        .fontColor(ZcodeColors.textTertiary())
        .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
    .alignItems(HorizontalAlign.Center)
  }
}
