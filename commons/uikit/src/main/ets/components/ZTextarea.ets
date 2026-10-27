/**
 * ZTextarea（shadcn/ui Textarea 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn Textarea：--card 底 + 1px --input 描边，聚焦切 --ring，
 * 最小两行高度（shadcn 的 min-h-16）并允许纵向滚动。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct ZTextarea {
  @Prop placeholder: string = '';
  @Prop value: string = '';
  @Prop disabled: boolean = false;
  @Prop minHeight: number = 64;
  @Prop fontSize: number = DesignTokens.FONT_BODY;
  @State focused: boolean = false;
  onValueChange: (value: string) => void = (value: string): void => {};

  build() {
    TextArea({ text: this.value, placeholder: this.placeholder })
      .constraintSize({ minHeight: this.minHeight })
      .fontSize(this.fontSize)
      .fontColor(ZcodeColors.textPrimary())
      .placeholderColor(ZcodeColors.textTertiary())
      .backgroundColor(ZcodeColors.CARD)
      .borderRadius(DesignTokens.RADIUS_SM)
      .border({ width: 1, color: this.focused ? ZcodeColors.RING : ZcodeColors.BORDER })
      .opacity(this.disabled ? 0.5 : 1)
      .onFocus(() => {
        this.focused = true;
      })
      .onBlur(() => {
        this.focused = false;
      })
      .onChange((value: string) => {
        this.onValueChange(value);
      })
  }
}
