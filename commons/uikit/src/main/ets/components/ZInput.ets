/**
 * ZInput（shadcn/ui Input 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn Input：--card 底 + 1px --input 描边，聚焦时描边切 --ring
 * （shadcn 的 focus-visible ring），高度 40vp 与 shadcn h-9 一致。
 * 值由页面持有（受控）：onValueChange 回传新值，页面更新自己的 @State。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct ZInput {
  @Prop placeholder: string = '';
  @Prop value: string = '';
  @Prop disabled: boolean = false;
  @Prop fontSize: number = DesignTokens.FONT_BODY;
  @State focused: boolean = false;
  onValueChange: (value: string) => void = (value: string): void => {};

  build() {
    TextInput({ text: this.value, placeholder: this.placeholder })
      .height(40)
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
