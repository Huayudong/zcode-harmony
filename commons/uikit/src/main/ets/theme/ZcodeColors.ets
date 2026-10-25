/**
 * ZCode 语义色 token（shadcn/ui 设计语言 · zinc 暗色系，批次24 对齐）。
 * 事实源：ui.shadcn.com 的 CSS 变量体系（--background/--foreground/--card/--muted/
 * --border/--input/--ring/--primary/--destructive），色彩收敛到 Tailwind zinc 阶；
 * primary 保留 ZCode 品牌蓝（shadcn 的 primary 本就是可配置槽位）。
 * 约束：语义色只用于真实语义；光感效果仅保留给主行动与确认类动作。
 * API 保持批次4 以来形状不变——存量页面零改动即完成色板切换。
 */
export class ZcodeColors {
  // shadcn --background（zinc-950）
  static readonly BG: string = '#09090B';
  // shadcn --card（暗色下与 bg 弱差 + 1px --border 分层，取原 bg 值保持移动端层次）
  static readonly CARD: string = '#101014';
  // shadcn --muted / --secondary（zinc-900 邻域；舱体/嵌块底色）
  static readonly SURFACE: string = '#1C1C1F';
  static readonly TEXT_PRIMARY: string = '#FAFAFA';
  static readonly TEXT_SECONDARY: string = '#A1A1AA';
  static readonly TEXT_TERTIARY: string = '#71717A';
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
  // ── shadcn 补充面（批次24 新增；存量页面按需收敛）──
  /** shadcn --border / --input（zinc-800；卡片描边与输入描线共用）。 */
  static readonly BORDER: string = '#27272A';
  /** shadcn --accent（ghost 态按压/hover 的着色底）。 */
  static readonly ACCENT: string = '#26262B';
  /** shadcn --ring（聚焦环 = primary）。 */
  static readonly RING: string = '#4C7DFF';

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
