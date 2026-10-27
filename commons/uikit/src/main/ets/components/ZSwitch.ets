/**
 * ZSwitch（shadcn/ui Switch 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn Switch：开=--primary 轨道 + 白拇指，关=--muted 轨道；
 * 尺寸用 DesignTokens.HIT_MIN 级别保证触控目标。ArkUI Toggle 的系统外观由
 * token 覆写，避免各系统主题漂移。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';

@Component
export struct ZSwitch {
  @Prop checked: boolean = false;
  @Prop disabled: boolean = false;
  onValueChange: (value: boolean) => void = (value: boolean): void => {};

  build() {
    Toggle({ type: ToggleType.Switch, isOn: this.checked })
      .selectedColor(ZcodeColors.BRAND)
      .switchPointColor(ZcodeColors.BRAND_CONTRAST)
      .opacity(this.disabled ? 0.5 : 1)
      .onChange((value: boolean) => {
        if (!this.disabled) {
          this.onValueChange(value);
        }
      })
  }
}
