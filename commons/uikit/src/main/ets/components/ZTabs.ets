/**
 * ZTabs（shadcn/ui Tabs 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn Tabs（underline 变体）：标签文字用 --muted-foreground，
 * 选中态切 --foreground 并在下方画 2px --primary 指示条；未选中无底色。
 * 值由页面持有（受控）：onIndexChange 回传新下标。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';
import { Motion } from '../theme/Motion';

@Component
export struct ZTabs {
  @Prop labels: string[] = [];
  @Prop activeIndex: number = 0;
  @Prop fontSize: number = DesignTokens.FONT_TITLE;
  onIndexChange: (index: number) => void = (index: number): void => {};

  build() {
    Row() {
      ForEach(this.labels, (label: string, index: number) => {
        Column() {
          Text(label)
            .fontSize(this.fontSize)
            .fontWeight(index === this.activeIndex ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(index === this.activeIndex ? ZcodeColors.textPrimary() : ZcodeColors.textTertiary())
          if (index === this.activeIndex) {
            Column()
              .width(22)
              .height(2)
              .margin({ top: DesignTokens.SPACE_XS })
              .backgroundColor(ZcodeColors.BRAND)
              .borderRadius(1)
              .animation({ duration: Motion.DUR_MICRO, curve: Curve.EaseOut })
          } else {
            Column()
              .width(22)
              .height(2)
              .margin({ top: DesignTokens.SPACE_XS })
          }
        }
        .margin({ right: DesignTokens.SPACE_XL })
        .onClick(() => {
          this.onIndexChange(index);
        })
      }, (label: string, index: number): string => `${index}_${label}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }
}
