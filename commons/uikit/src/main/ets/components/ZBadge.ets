/**
 * ZBadge（shadcn/ui Badge 的鸿蒙转译，批次24）。
 * 变体：default（primary 淡底）/ secondary（muted 底）/ outline（描边）/ success /
 * warning / destructive（语义底色）；小号胶囊形态（shadcn Badge = inline-flex 胶囊）。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';

export class ZBadgeVariant {
  static readonly DEFAULT: string = 'default';
  static readonly SECONDARY: string = 'secondary';
  static readonly OUTLINE: string = 'outline';
  static readonly SUCCESS: string = 'success';
  static readonly WARNING: string = 'warning';
  static readonly DESTRUCTIVE: string = 'destructive';
}

@Component
export struct ZBadge {
  @Prop label: string = '';
  @Prop variant: string = ZBadgeVariant.SECONDARY;
  @Prop fontSize: number = 10;

  private bg(): string {
    if (this.variant === ZBadgeVariant.DEFAULT) {
      // primary 淡底（无 alpha 混色工具，用预混 zinc+brand 深）
      return '#1D2A4A';
    }
    if (this.variant === ZBadgeVariant.SUCCESS) {
      return ZcodeColors.DIFF_ADD;
    }
    if (this.variant === ZBadgeVariant.WARNING) {
      return '#3A2F1A';
    }
    if (this.variant === ZBadgeVariant.DESTRUCTIVE) {
      return ZcodeColors.DIFF_DEL;
    }
    // secondary 淡底 / outline 透明
    return this.variant === ZBadgeVariant.OUTLINE ? '#00000000' : ZcodeColors.SURFACE;
  }

  private fg(): string {
    if (this.variant === ZBadgeVariant.DEFAULT) {
      return ZcodeColors.BRAND_LIGHT;
    }
    if (this.variant === ZBadgeVariant.SUCCESS) {
      return ZcodeColors.SUCCESS;
    }
    if (this.variant === ZBadgeVariant.WARNING) {
      return ZcodeColors.WARNING;
    }
    if (this.variant === ZBadgeVariant.DESTRUCTIVE) {
      return ZcodeColors.DESTRUCTIVE;
    }
    return ZcodeColors.textSecondary();
  }

  build() {
    Text(this.label)
      .fontSize(this.fontSize)
      .fontColor(this.fg())
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(DesignTokens.RADIUS_SM)
      .backgroundColor(this.bg())
      .border({
        width: this.variant === ZBadgeVariant.OUTLINE ? 1 : 0,
        color: ZcodeColors.BORDER,
      })
  }
}
