/**
 * ZDialog（shadcn/ui Dialog 与 AlertDialog 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn：
 * - 遮罩 + 居中面板（--card 底 + 1px --border），内容 = title / description / actions
 * - destructive 变体：确认按钮走 destructive 红底（AlertDialog 的破坏性确认）
 * - 动作区右对齐，取消=ghost、确认=default（shadcn 默认 ghost + primary）
 *
 * ArkTS 限制：ArkUI 无 children 插槽，用 @BuilderParam 充当内容插槽
 * （等同 shadcn DialogContent）；面板对齐用 Stack 子节点的 .align()，Stack 本身无对齐属性。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';
import { Motion } from '../theme/Motion';
import { ZButton, ZButtonVariant } from './ZButton';

@Component
export struct ZDialog {
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop confirmLabel: string = '确定';
  @Prop cancelLabel: string = '取消';
  @Prop showCancel: boolean = true;
  @Prop destructive: boolean = false;

  /** 内容插槽（shadcn DialogContent）：父组件以尾随闭包传入。 */
  @BuilderParam content: () => void;
  onConfirm: () => void = (): void => {};
  onCancel: () => void = (): void => {};

  build() {
    Column() {
        if (this.title.length > 0) {
          Text(this.title)
            .fontSize(DesignTokens.FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(ZcodeColors.textPrimary())
            .margin({ bottom: DesignTokens.SPACE_SM })
        }
        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor(ZcodeColors.textSecondary())
            .lineHeight(20)
        }
        this.content()

        Row() {
          if (this.showCancel) {
            ZButton({
              label: this.cancelLabel,
              variant: ZButtonVariant.GHOST,
              btnSize: 'sm',
              onTap: () => {
                this.onCancel();
              },
            })
          }
          ZButton({
            label: this.confirmLabel,
            variant: this.destructive ? ZButtonVariant.DESTRUCTIVE : ZButtonVariant.DEFAULT,
            btnSize: 'sm',
            onTap: () => {
              this.onConfirm();
            },
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: DesignTokens.SPACE_LG })
      }
      .constraintSize({ maxWidth: '88%' })
      .padding(DesignTokens.SPACE_LG)
      .backgroundColor(ZcodeColors.CARD)
      .borderRadius(DesignTokens.RADIUS_LG)
      .border({ width: 1, color: ZcodeColors.BORDER })
      .animation({ duration: Motion.DUR_MICRO, curve: Curve.EaseOut })
  }
}
