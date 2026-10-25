/**
 * 系统符号图标封装（HSD SymbolGlyph，批次21 起 emoji 图标的替代面）。
 * 名字清单取自 SDK sysResource（3846 个 sys.symbol.*），全部为已验证存在名；
 * 语义键集中在此映射，页面不直接写 $r('sys.symbol.*')。
 * SymbolGlyph 无字符内边距控制，尺寸由 fontSize 驱动（HSD 符号字号=图标尺寸）。
 */
import { ZcodeColors } from '../theme/ZcodeColors';

/** 语义图标键 → sys.symbol 名（新增图标先在 sysResource 清单里验证名字）。 */
export enum ZIconName {
  Plus = 0,
  Camera,
  Picture,
  Folder,
  Doc,
  Send,
  Stop,
  Mode,
  Model,
  Thought,
  Usage,
  Clock,
  Checkmark,
  Close,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  ChevronDown,
  Person,
  Warning,
  Refresh,
  Sparkle,
}

function symbolResourceOf(name: ZIconName): Resource {
  if (name === ZIconName.Camera) {
    return $r('sys.symbol.camera');
  }
  if (name === ZIconName.Picture) {
    return $r('sys.symbol.picture');
  }
  if (name === ZIconName.Folder) {
    return $r('sys.symbol.folder');
  }
  if (name === ZIconName.Doc) {
    return $r('sys.symbol.doc_plaintext');
  }
  if (name === ZIconName.Send) {
    return $r('sys.symbol.arrow_up');
  }
  if (name === ZIconName.Stop) {
    return $r('sys.symbol.stop_circle_fill');
  }
  if (name === ZIconName.Mode) {
    return $r('sys.symbol.slider_horizontal_2');
  }
  if (name === ZIconName.Model) {
    return $r('sys.symbol.waveform');
  }
  if (name === ZIconName.Thought) {
    return $r('sys.symbol.gauge_with_dots_needle_33percent');
  }
  if (name === ZIconName.Usage) {
    return $r('sys.symbol.creditcard');
  }
  if (name === ZIconName.Clock) {
    return $r('sys.symbol.clock');
  }
  if (name === ZIconName.Checkmark) {
    return $r('sys.symbol.checkmark');
  }
  if (name === ZIconName.Close) {
    return $r('sys.symbol.xmark');
  }
  if (name === ZIconName.ChevronLeft) {
    return $r('sys.symbol.chevron_left');
  }
  if (name === ZIconName.ChevronRight) {
    return $r('sys.symbol.chevron_right');
  }
  if (name === ZIconName.ChevronUp) {
    return $r('sys.symbol.chevron_up');
  }
  if (name === ZIconName.ChevronDown) {
    return $r('sys.symbol.chevron_down');
  }
  if (name === ZIconName.Person) {
    return $r('sys.symbol.person');
  }
  if (name === ZIconName.Warning) {
    return $r('sys.symbol.exclamationmark_triangle');
  }
  if (name === ZIconName.Refresh) {
    return $r('sys.symbol.arrow_clockwise');
  }
  if (name === ZIconName.Sparkle) {
    return $r('sys.symbol.wand_and_stars');
  }
  return $r('sys.symbol.plus');
}

@Component
export struct ZIcon {
  @Prop name: ZIconName = ZIconName.Plus;
  @Prop iconSize: number = 20;
  @Prop color: string = ZcodeColors.textSecondary();

  build() {
    SymbolGlyph(symbolResourceOf(this.name))
      .fontSize(this.iconSize)
      .fontColor([this.color])
  }
}
