/**
 * ZCode 语义色 token（PRD 5.2 表，深色为默认主题）。
 * 事实源：zcode 仓库 packages/ui 的 CSS token；此处为鸿蒙侧映射。
 * 约束：语义色只用于真实语义；光感效果仅保留给主行动与确认类动作。
 */
export class ZcodeColors {
  static readonly BG: string = '#101014';
  static readonly CARD: string = '#17171C';
  static readonly SURFACE: string = '#1E1E24';
  static readonly TEXT_PRIMARY: string = '#F2F2F5';
  static readonly TEXT_SECONDARY: string = '#A8A8B3';
  static readonly TEXT_TERTIARY: string = '#6C6C78';
  static readonly BRAND: string = '#4C7DFF';
  static readonly BRAND_LIGHT: string = '#7AA0FF';
  static readonly BRAND_CONTRAST: string = '#FFFFFF';
  static readonly SUCCESS: string = '#3FBF6E';
  static readonly WARNING: string = '#E0A83A';
  static readonly DESTRUCTIVE: string = '#E05C5C';
  static readonly DIFF_ADD: string = '#1F3A2A';
  static readonly DIFF_DEL: string = '#3A1F24';
  static readonly TRACE: string = '#2A3A55';
  static readonly CONFIRM: string = '#3FBF6E';

  static background(): string {
    return ZcodeColors.BG;
  }

  static card(): string {
    return ZcodeColors.CARD;
  }

  static textPrimary(): string {
    return ZcodeColors.TEXT_PRIMARY;
  }

  static textSecondary(): string {
    return ZcodeColors.TEXT_SECONDARY;
  }

  static textTertiary(): string {
    return ZcodeColors.TEXT_TERTIARY;
  }

  static brand(): string {
    return ZcodeColors.BRAND;
  }

  static destructive(): string {
    return ZcodeColors.DESTRUCTIVE;
  }
}
