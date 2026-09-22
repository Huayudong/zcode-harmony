/**
 * 三态状态灯（PRD OUT-3 / CONN-2）：
 * 离线（灰）→ 运行（品牌色脉冲，1s 心跳周期）→ 成功 / 失败 / 等待确认（语义色）。
 */
import { ZcodeColors } from '../theme/ZcodeColors';

export enum StatusTone {
  Offline,
  Running,
  Success,
  Warning,
  Failed,
  PendingConfirm
}

@Component
export struct StatusDot {
  @Prop tone: StatusTone = StatusTone.Offline;
  // 避开基类 CustomComponent 的通用属性 size（.size() 是通用样式方法），命名 dotSize
  @Prop dotSize: number = 10;
  @State private pulse: boolean = false;

  private toneColor(): string {
    switch (this.tone) {
      case StatusTone.Running:
        return ZcodeColors.brand();
      case StatusTone.Success:
        return ZcodeColors.SUCCESS;
      case StatusTone.Warning:
        return ZcodeColors.WARNING;
      case StatusTone.Failed:
        return ZcodeColors.destructive();
      case StatusTone.PendingConfirm:
        return ZcodeColors.CONFIRM;
      default:
        return ZcodeColors.textTertiary();
    }
  }

  build() {
    Circle()
      .width(this.dotSize)
      .height(this.dotSize)
      .fill(this.toneColor())
      .opacity(this.tone === StatusTone.Running && !this.pulse ? 0.55 : 1)
      .onAppear(() => {
        if (this.tone === StatusTone.Running) {
          // 统一心跳节奏（1s 周期，PRD 5.5）
          setInterval(() => {
            this.pulse = !this.pulse;
          }, 500);
        }
      })
  }
}
