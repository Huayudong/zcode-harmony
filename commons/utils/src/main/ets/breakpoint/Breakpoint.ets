/**
 * 断点工具（PRD 5.6 一多）：sm(≤600) 单列 / md(601–840) 双栏-抽屉收起 / lg(>840) 双栏常驻。
 * ArkTS 不允许 enum/class 同名声明合并，枚举值与判定逻辑统一收敛在本文件：
 * BreakpointLevel 是取值枚举，Breakpoint 是唯一Owner（阈值与同步状态都在它身上）。
 */
export enum BreakpointLevel {
  Sm = 'sm',
  Md = 'md',
  Lg = 'lg'
}

const MD_MIN_VP: number = 601;
const LG_MIN_VP: number = 841;

/**
 * Batch4 占位实现：真实断点需由页面在 onWindowSizeChange 中喂入宽度。
 * 这里的 isWide/current 读取全局显示规格，脚手架期给出合理默认。
 */
export class Breakpoint {
  private static lastWidthVp: number = 0;

  static syncFromDisplay(widthVp: number): void {
    Breakpoint.lastWidthVp = widthVp;
  }

  static fromWidth(widthVp: number): BreakpointLevel {
    if (widthVp >= LG_MIN_VP) {
      return BreakpointLevel.Lg;
    }
    if (widthVp >= MD_MIN_VP) {
      return BreakpointLevel.Md;
    }
    return BreakpointLevel.Sm;
  }

  static isWide(): boolean {
    return Breakpoint.lastWidthVp === 0 || Breakpoint.lastWidthVp >= MD_MIN_VP;
  }

  static current(): string {
    const level: BreakpointLevel = Breakpoint.fromWidth(
      Breakpoint.lastWidthVp === 0 ? 360 : Breakpoint.lastWidthVp
    );
    switch (level) {
      case BreakpointLevel.Lg:
        return 'lg';
      case BreakpointLevel.Md:
        return 'md';
      default:
        return 'sm';
    }
  }
}
