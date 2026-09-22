import { LightBloomButton, ZcodeColors, StatusDot, StatusTone } from "uikit";
import { Breakpoint } from "utils";

/**
 * 首页（Batch4 脚手架）：演示主题 token / 光感按钮 / 状态灯。
 * 会话工作台在后续批次替换本页。
 */
@Entry
@Component
struct Index {
  @State sentCount: number = 0;
  @State running: boolean = true;

  build() {
    Column() {
      Text('ZCode Harmony')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(ZcodeColors.textPrimary())
        .margin({ top: 64, bottom: 8 })

      Text('Agent 在你的电脑上干活，手机随时接管')
        .fontSize(14)
        .fontColor(ZcodeColors.textSecondary())
        .margin({ bottom: 32 })

      Row({ space: 8 }) {
        StatusDot({ tone: this.running ? StatusTone.Running : StatusTone.Offline, dotSize: 10 })
        Text(this.running ? '正在重构模块…' : '空闲')
          .fontSize(14)
          .fontColor(ZcodeColors.textSecondary())
      }
      .margin({ bottom: 48 })

      LightBloomButton({
        label: `发送 ${Breakpoint.isWide() ? '(宽屏)' : ''}`.trim(),
        destructive: false,
        onAction: () => {
          this.sentCount += 1;
        }
      })

      Text(`已发送 ${this.sentCount} 条`)
        .fontSize(12)
        .fontColor(ZcodeColors.textTertiary())
        .margin({ top: 24 })

      Blank()

      Text(`v0.1.0 scaffold · ${Breakpoint.current()}`)
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
