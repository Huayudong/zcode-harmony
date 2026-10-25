/**
 * HSD × ZCode 设计 token（PRD 5.2 的鸿蒙侧落点，批次21 起）。
 *
 * 分层：DesignTokens（本文件，静态深色值 + 几何/字体/动效常量）→ ZcodeColors
 * （语义色 API，保持存量页面零改动）。浅色主题属 M2：届时把颜色常量改为资源
 * （$color + dark 限定词）或运行时主题对象，token 键名与几何量不动。
 *
 * 纪律：页面/组件不再写裸 hex 与魔法数（本批起新代码一律取 token；存量随
 * 批次22 视觉铺开收敛）。光感效果只给主行动与确认类动作（PRD 5.2 约束）。
 */
export class DesignTokens {
  // ── 颜色（深色默认主题；浅色 M2 经资源化接入，键名不变）──
  static readonly COLOR_BG: string = '#101014';
  static readonly COLOR_CARD: string = '#17171C';
  static readonly COLOR_SURFACE: string = '#1E1E24';
  static readonly COLOR_TEXT_PRIMARY: string = '#F2F2F5';
  static readonly COLOR_TEXT_SECONDARY: string = '#A8A8B3';
  static readonly COLOR_TEXT_TERTIARY: string = '#6C6C78';
  static readonly COLOR_BRAND: string = '#4C7DFF';
  static readonly COLOR_BRAND_LIGHT: string = '#7AA0FF';
  static readonly COLOR_BRAND_CONTRAST: string = '#FFFFFF';
  static readonly COLOR_SUCCESS: string = '#3FBF6E';
  static readonly COLOR_WARNING: string = '#E0A83A';
  static readonly COLOR_DESTRUCTIVE: string = '#E05C5C';
  static readonly COLOR_DIFF_ADD: string = '#1F3A2A';
  static readonly COLOR_DIFF_DEL: string = '#3A1F24';
  static readonly COLOR_TRACE: string = '#2A3A55';
  static readonly COLOR_CONFIRM: string = '#3FBF6E';
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
