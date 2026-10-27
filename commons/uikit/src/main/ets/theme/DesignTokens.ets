/**
 * shadcn/ui 设计 token 的鸿蒙侧落点（批次24 对齐 ui.shadcn.com 的 CSS 变量体系）。
 *
 * 分层：DesignTokens（本文件，zinc 暗色静态值 + 几何/字体/动效常量）→ ZcodeColors
 * （语义色 API，保持存量页面零改动）。浅色主题属 M2：届时把颜色常量改为资源
 * （$color + dark 限定词）或运行时主题对象，token 键名与几何量不动。
 *
 * 纪律：页面/组件不再写裸 hex 与魔法数（新代码一律取 token；存量随批次24+ 视觉
 * 铺开收敛）。光感效果只给主行动与确认类动作。
 */
export class DesignTokens {
  // ── 颜色（shadcn zinc 暗色系；与 ZcodeColors 同值同源，token 命名对照注释）──
  static readonly COLOR_BG: string = '#09090B';          // --background (zinc-950)
  static readonly COLOR_CARD: string = '#101014';        // --card
  static readonly COLOR_SURFACE: string = '#1C1C1F';     // --muted / --secondary (zinc-900)
  static readonly COLOR_TEXT_PRIMARY: string = '#FAFAFA';   // --foreground (zinc-50)
  static readonly COLOR_TEXT_SECONDARY: string = '#A1A1AA'; // --muted-foreground (zinc-400)
  static readonly COLOR_TEXT_TERTIARY: string = '#71717A';  // 弱化层 (zinc-500)
  static readonly COLOR_BRAND: string = '#4C7DFF';       // --primary（品牌槽位）
  static readonly COLOR_BRAND_LIGHT: string = '#7AA0FF';
  static readonly COLOR_BRAND_CONTRAST: string = '#FFFFFF'; // --primary-foreground
  static readonly COLOR_SUCCESS: string = '#3FBF6E';
  static readonly COLOR_WARNING: string = '#E0A83A';
  static readonly COLOR_DESTRUCTIVE: string = '#E05C5C'; // --destructive
  static readonly COLOR_BORDER: string = '#27272A';      // --border / --input (zinc-800)
  static readonly COLOR_ACCENT: string = '#26262B';      // --accent（ghost 按压底）
  static readonly COLOR_RING: string = '#4C7DFF';        // --ring（= primary）
  static readonly COLOR_DIFF_ADD: string = '#1F3A2A';
  static readonly COLOR_DIFF_DEL: string = '#3A1F24';
  static readonly COLOR_TRACE: string = '#2A3A55';
  static readonly COLOR_CONFIRM: string = '#3FBF6E';
  /** overlay 遮罩（shadcn Dialog/Sheet 的 overlay 半透黑）。 */
  static readonly SCRIM: string = '#00000099';
  /** 品牌辉光（shadow/粒子用的 rgba 串；ArkTS shadow.color 只收字符串或 Color）。 */
  static readonly GLOW_BRAND: string = 'rgba(76, 125, 255, 0.35)';
  static readonly GLOW_BRAND_SOFT: string = 'rgba(76, 125, 255, 0.18)';

  // ── 圆角（HSD：卡片 16 / 舱体 20-24 / 胶囊 999）──
  static readonly RADIUS_SM: number = 8;
  static readonly RADIUS_MD: number = 12;
  static readonly RADIUS_LG: number = 16;
  static readonly RADIUS_XL: number = 20;
  static readonly RADIUS_PILL: number = 999;

  // ── 间距（4pt 栅格）──
  static readonly SPACE_XS: number = 4;
  static readonly SPACE_SM: number = 8;
  static readonly SPACE_MD: number = 12;
  static readonly SPACE_LG: number = 16;
  static readonly SPACE_XL: number = 20;
  static readonly SPACE_XXL: number = 24;

  // ── 字号 ──
  static readonly FONT_CAPTION: number = 10;
  static readonly FONT_FOOTNOTE: number = 11;
  static readonly FONT_SUB: number = 13;
  static readonly FONT_BODY: number = 14;
  static readonly FONT_TITLE: number = 17;

  // ── 触控目标（HSD 最小 44vp）──
  static readonly HIT_MIN: number = 44;
  static readonly HIT_ICON: number = 48;
}
