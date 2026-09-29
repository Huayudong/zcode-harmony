import router from '@ohos.router';
import { promptAction } from '@kit.ArkUI';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { isPairLink, type PairRouteParams } from 'connection';
import { LightBloomButton, ZcodeColors, StatusDot, StatusTone } from 'uikit';

/**
 * 配对欢迎页（ONB-1/2）：扫码（Scan Kit 系统扫码页，无需自管相机权限）为首选，
 * 深链/手动导入为兜底；非局域网场景给组网指引页（CONN-4）。
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

  private startScan(): void {
    const context = getContext(this);
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
    };
    scanBarcode.startScanForResult(context, options)
      .then((result: scanBarcode.ScanResult) => {
        const link = result.originalValue ?? '';
        if (!isPairLink(link)) {
          promptAction.showToast({ message: '二维码不是 ZCode 配对码' });
          return;
        }
        const params: PairRouteParams = { link: link };
        router.pushUrl({
          url: 'pages/pairing/PairingCodeInput',
          params: params
        }).catch(() => {});
      })
      .catch((error: Object) => {
        // 用户取消/相机不可用：静默或轻提示（取消错误码 1001 常见）
        const message = String((error as Error).message ?? error);
        if (!message.includes('1001')) {
          promptAction.showToast({ message: `扫码不可用：${message}` });
        }
      });
  }

  private openNetworkGuide(): void {
    router.pushUrl({ url: 'pages/pairing/NetworkGuide' }).catch(() => {});
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
          StatusDot({ tone: StatusTone.Success, dotSize: 10 })
          Text('推荐扫码配对 · 也可粘贴链接或手动填写')
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
          onAction: () => {
            this.startScan();
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

      Column({ space: 8 }) {
        Text('需要电脑与手机处于同一网络；跨网络可用 Tailscale/FRP 组网')
          .fontSize(11)
          .fontColor(ZcodeColors.textTertiary())
          .textAlign(TextAlign.Center)
        Text('无法直连？查看组网指引')
          .fontSize(12)
          .fontColor(ZcodeColors.BRAND_LIGHT)
          .onClick(() => {
            this.openNetworkGuide();
          })
          .margin({ bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
    .alignItems(HorizontalAlign.Center)
  }
}
