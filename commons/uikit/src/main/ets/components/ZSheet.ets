/**
 * ZSheet（shadcn/ui Sheet 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn Sheet：底部抽屉面板（--card 底 + 顶部 --border），可带标题与
 * 关闭态；内容用 @BuilderParam 插槽传入（等同 SheetContent），页面据此放长按
 * 菜单项、详情行、表单等。
 *
 * ArkTS 限制：Stack 自身无对齐属性，底对齐用子节点 .align(Alignment.Bottom)。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';
import { Motion } from '../theme/Motion';

@Component
export struct ZSheet {
  @Prop title: string = '';
  @Prop showClose: boolean = true;

  /** 内容插槽（shadcn SheetContent）：父组件以尾随闭包传入。 */
  @BuilderParam content: () => void;
  onClose: () => void = (): void => {};

  build() {
    Column() {
        if (this.title.length > 0) {
          Row() {
            Text(this.title)
              .fontSize(DesignTokens.FONT_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(ZcodeColors.textPrimary())
              .layoutWeight(1)
            if (this.showClose) {
              Text('✕')
                .fontSize(16)
                .fontColor(ZcodeColors.textTertiary())
                .width(28)
                .height(28)
                .textAlign(TextAlign.Center)
                .borderRadius(14)
                .backgroundColor(ZcodeColors.ACCENT)
                .onClick(() => {
                  this.onClose();
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: DesignTokens.SPACE_SM })
        }
        this.content()
      }
      .width('100%')
      .padding({
        left: DesignTokens.SPACE_LG,
        right: DesignTokens.SPACE_LG,
        top: DesignTokens.SPACE_LG,
        bottom: 40,
      })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(ZcodeColors.CARD)
      .borderRadius({ topLeft: DesignTokens.RADIUS_XL, topRight: DesignTokens.RADIUS_XL })
      .border({ width: 1, color: ZcodeColors.BORDER })
      .animation({ duration: Motion.DUR_MICRO, curve: Curve.EaseOut })
  }
}
