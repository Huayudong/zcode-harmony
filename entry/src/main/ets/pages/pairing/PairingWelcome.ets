import router from '@ohos.router';
import type { PairRouteParams } from 'connection';
import { LightBloomButton, ZcodeColors, StatusDot, StatusTone } from 'uikit';

/**
 * 配对欢迎页（ONB-1）：一屏讲清价值，进入手动导入。
 * 相机扫码（ONB-2，Scan Kit）待真机联调批次启用，本批深链/粘贴入口已可用。
 */
@Entry
@Component
struct PairingWelcome {
  private startManual(): void {
    const params: PairRouteParams = { link: '' };
    router.pushUrl({
      url: 'pages/pairing/PairingCodeInput',
      params: params
    }).catch(() => {});
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor(ZcodeColors.textSecondary())
          .onClick(() => {
            router.back();
          })
      }
      .width('100%')
      .padding({ left: 20, top: 16 })
      .alignItems(VerticalAlign.Center)

      Text('连接你的电脑')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(ZcodeColors.textPrimary())
        .margin({ top: 40, bottom: 12 })

      Text('在电脑端 ZCode 网页设置里打开「移动端配对」，\n用手机相机或复制链接，3 秒完成绑定。')
        .fontSize(14)
        .fontColor(ZcodeColors.textSecondary())
        .textAlign(TextAlign.Center)
        .margin({ bottom: 48 })

      Column({ space: 12 }) {
        Row({ space: 8 }) {
          StatusDot({ tone: StatusTone.PendingConfirm, dotSize: 10 })
          Text('相机扫码即将可用 · 现在可粘贴链接或手动填写')
            .fontSize(12)
            .fontColor(ZcodeColors.textTertiary())
        }
        .alignItems(VerticalAlign.Center)
      }
      .padding(14)
      .borderRadius(12)
      .backgroundColor(ZcodeColors.card())
      .margin({ bottom: 40 })

      Column({ space: 16 }) {
        LightBloomButton({
          label: '扫码配对',
          destructive: false,
          isEnabled: false,
          onAction: () => {
          }
        })

        LightBloomButton({
          label: '手动添加 / 粘贴链接',
          destructive: false,
          onAction: () => {
            this.startManual();
          }
        })
      }

      Blank()

      Text('需要电脑与手机处于同一网络')
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
