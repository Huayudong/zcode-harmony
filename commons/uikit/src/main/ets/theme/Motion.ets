/**
 * 统一动效 token（PRD 5.5：入场 120ms / 状态切换 250ms / 1s 心跳）。
 * reduceMotion 打开时页面应用把时长压到 0（结构照常，动效退场）——
 * 系统级「减弱动效」开关的读取属 M2，先提供应用内总闸（Settings 可挂）。
 */
export class Motion {
  /** 微反馈（按压 scale、chip 切换）。 */
  static readonly DUR_MICRO: number = 120;
  /** 状态切换（按钮位变、面板入场）。 */
  static readonly DUR_STATE: number = 250;
  /** 强调过渡（卡片入场、吸靠动画）。 */
  static readonly DUR_EMPHASIS: number = 350;
  /** 心跳周期（StatusDot 脉冲；半周期 500ms 翻转）。 */
  static readonly PULSE_HALF_MS: number = 500;

  static readonly EASE_OUT: Curve = Curve.EaseOut;
  static readonly EASE_IN_OUT: Curve = Curve.EaseInOut;

  private static reduceMotion: boolean = false;

  /** 应用级减弱动效总闸（Settings 页接入前默认关）。 */
  static setReduceMotion(value: boolean): void {
    Motion.reduceMotion = value;
  }

  static isReduceMotion(): boolean {
    return Motion.reduceMotion;
  }

  /** 取实际时长：减弱动效时归零。 */
  static dur(base: number): number {
    return Motion.reduceMotion ? 0 : base;
  }
}
