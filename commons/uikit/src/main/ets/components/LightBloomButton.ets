/**
 * 光感主行动按钮（HSD 沉浸光感，PRD 5.4）。
 * L1 结构：底色渐变 + 顶部内高光 + 外辉光；destructive 变体走描边。
 * 触感振动（Vibrator）在后续批次接入；本版本先完成视觉与按压状态机。
 */
import { ZcodeColors } from '../theme/ZcodeColors';

@Component
export struct LightBloomButton {
  @Prop label: string = '确认';
  @Prop destructive: boolean = false;
  @Prop enabled: boolean = true;
  @State private pressed: boolean = false;
  onAction: () => void = () => {};

  build() {
    Stack() {
      // 内容层
      Text(this.label)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.destructive
          ? ZcodeColors.destructive()
          : (this.enabled ? ZcodeColors.BRAND_CONTRAST : ZcodeColors.textTertiary()))
        .opacity(this.enabled ? 1 : 0.6)
    }
    .constraintSize({ minWidth: 160 })
    .height(48)
    .padding({ left: 32, right: 32 })
    .borderRadius(24)
    .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
    .animation({ duration: 120, curve: Curve.EaseOut })
    .backgroundColor(this.destructive || !this.enabled ? Color.Transparent : Color.Transparent)
    .linearGradient(this.destructive || !this.enabled
      ? undefined
      : {
          angle: 135,
          colors: [[ZcodeColors.BRAND, 1], [ZcodeColors.BRAND_LIGHT, 1]]
        })
    .border({
      width: this.destructive ? 1.5 : 0,
      color: this.destructive ? ZcodeColors.DESTRUCTIVE : Color.Transparent
    })
    .shadow(this.destructive || !this.enabled
      ? undefined
      : {
          radius: this.pressed ? 16 : 24,
          color: this.destructive ? ZcodeColors.DESTRUCTIVE : ZcodeColors.BRAND,
          offsetY: 4
        })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (this.pressed && this.enabled) {
          this.onAction();
        }
        this.pressed = false;
      }
    })
    .opacity(this.enabled ? 1 : 0.5)
  }
}
