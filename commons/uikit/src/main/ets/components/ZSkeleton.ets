/**
 * ZSkeleton（shadcn/ui Skeleton 的鸿蒙转译，批次24）。
 * 加载占位脉动块（shadcn = animate-pulse 灰块；这里用 opacity 定时翻转近似循环脉动）。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';
import { Motion } from '../theme/Motion';

@Component
export struct ZSkeleton {
  @Prop skelWidth: string = '100%';
  @Prop skelHeight: number = 14;
  @Prop skelRadius: number = DesignTokens.RADIUS_SM;
  @State pulsing: boolean = false;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.timerId = setInterval((): void => {
      this.pulsing = !this.pulsing;
    }, Motion.PULSE_HALF_MS);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Row()
      .width(this.skelWidth)
      .height(this.skelHeight)
      .borderRadius(this.skelRadius)
      .backgroundColor(ZcodeColors.SURFACE)
      .opacity(this.pulsing ? 0.45 : 1)
      .animation({ duration: Motion.PULSE_HALF_MS, curve: Curve.EaseInOut })
  }
}
