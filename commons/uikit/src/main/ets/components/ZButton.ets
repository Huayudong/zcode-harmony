/**
 * ZButton（shadcn/ui Button 的鸿蒙转译，批次24）。
 *
 * 变体表对齐 shadcn Button（variant × size）：
 * - variant：default（primary 实底）/ secondary（muted 底）/ outline（1px 边框透明底）/
 *   ghost（透明底，按压着 accent）/ destructive（红实底）
 * - size：sm（h=32 紧凑）/ md（默认 h=38）/ lg（h=44 主行动）/ icon（圆形图标钮）
 * token 全部取 ZcodeColors/DesignTokens（zinc 暗色 + 品牌蓝 primary 槽位）。
 * 限制：ArkTS @Component 无 children 插槽，label 传文本（图标钮配合 ZIcon 由页面组合）。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';
import { Motion } from '../theme/Motion';

/** shadcn variant 词表（字符面值：页面直传，避免枚举导入耦合）。 */
export class ZButtonVariant {
  static readonly DEFAULT: string = 'default';
  static readonly SECONDARY: string = 'secondary';
  static readonly OUTLINE: string = 'outline';
  static readonly GHOST: string = 'ghost';
  static readonly DESTRUCTIVE: string = 'destructive';
}

export class ZButtonSize {
  static readonly SM: string = 'sm';
  static readonly MD: string = 'md';
  static readonly LG: string = 'lg';
  static readonly ICON: string = 'icon';
}

/** 尺寸的内边距四元组（ArkTS 无元组，用接口承載）。 */
interface ZButtonPadding {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

@Component
export struct ZButton {
  @Prop label: string = '';
  @Prop variant: string = ZButtonVariant.DEFAULT;
  @Prop btnSize: string = ZButtonSize.MD;
  @Prop disabled: boolean = false;
  @Prop fontSize: number = 14;
  /** icon 尺寸型直接给正方形边长（icon 变体用）。 */
  @Prop iconExtent: number = 40;
  onTap: () => void = (): void => {};

  private textColor(): string {
    if (this.disabled) {
      return ZcodeColors.textTertiary();
    }
    if (this.variant === ZButtonVariant.DEFAULT) {
      return ZcodeColors.BRAND_CONTRAST;
    }
    if (this.variant === ZButtonVariant.DESTRUCTIVE) {
      return ZcodeColors.BRAND_CONTRAST;
    }
    return ZcodeColors.textPrimary();
  }

  private bgColor(): string {
    if (this.disabled) {
      return ZcodeColors.SURFACE;
    }
    if (this.variant === ZButtonVariant.DEFAULT) {
      return ZcodeColors.BRAND;
    }
    if (this.variant === ZButtonVariant.SECONDARY) {
      return ZcodeColors.SURFACE;
    }
    if (this.variant === ZButtonVariant.DESTRUCTIVE) {
      return ZcodeColors.DESTRUCTIVE;
    }
    // outline / ghost：完全透明（8 位 ARGB）
    return DesignTokens.TRANSPARENT;
  }

  private outlineW(): number {
    return this.variant === ZButtonVariant.OUTLINE ? 1 : 0;
  }

  private heightOf(): number {
    if (this.btnSize === ZButtonSize.SM) {
      return 32;
    }
    if (this.btnSize === ZButtonSize.LG) {
      return DesignTokens.HIT_MIN;
    }
    if (this.btnSize === ZButtonSize.ICON) {
      return this.iconExtent;
    }
    return 38;
  }

  private paddingOf(): ZButtonPadding {
    const pad: ZButtonPadding = { left: 16, right: 16, top: 8, bottom: 8 };
    if (this.btnSize === ZButtonSize.ICON) {
      pad.left = 0;
      pad.right = 0;
      pad.top = 0;
      pad.bottom = 0;
    } else if (this.btnSize === ZButtonSize.SM) {
      pad.left = 10;
      pad.right = 10;
      pad.top = 5;
      pad.bottom = 5;
    } else if (this.btnSize === ZButtonSize.LG) {
      pad.left = 22;
      pad.right = 22;
      pad.top = 10;
      pad.bottom = 10;
    }
    return pad;
  }

  build() {
    Text(this.label)
      .fontSize(this.btnSize === ZButtonSize.SM ? Math.max(12, this.fontSize - 1) : this.fontSize)
      .fontWeight(this.variant === ZButtonVariant.DEFAULT ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.textColor())
      .textAlign(TextAlign.Center)
      .height(this.heightOf())
      .padding({
        left: this.paddingOf().left,
        right: this.paddingOf().right,
        top: this.paddingOf().top,
        bottom: this.paddingOf().bottom,
      })
      .borderRadius(this.btnSize === ZButtonSize.ICON ? this.iconExtent / 2 : DesignTokens.RADIUS_MD)
      .backgroundColor(this.bgColor())
      .border({ width: this.outlineW(), color: ZcodeColors.BORDER })
      .opacity(!this.disabled ? 1 : 0.6)
      .animation({ duration: Motion.DUR_MICRO, curve: Curve.EaseOut })
      .onClick(() => {
        if (!this.disabled) {
          this.onTap();
        }
      })
  }
}
