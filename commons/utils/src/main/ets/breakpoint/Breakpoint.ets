/**
 * 断点工具（PRD 5.6 一多）：sm(≤600) 单列 / md(601–840) 双栏-抽屉收起 / lg(>840) 双栏常驻。
 */
export enum Breakpoint {
  Sm = 'sm',
  Md = 'md',
  Lg = 'lg'
}

const MD_MIN_VP: number = 601;
const LG_MIN_VP: number = 841;

export class BreakpointUtil {
  static fromWidth(widthVp: number): Breakpoint {
    if (widthVp >= LG_MIN_VP) {
      return Breakpoint.Lg;
    }
    if (widthVp >= MD_MIN_VP) {
      return Breakpoint.Md;
    }
    return Breakpoint.Sm;
  }
}

/**
 * Batch4 占位实现：真实断点需由页面在 onWindowSizeChange 中喂入宽度。
 * 这里的 isWide/current 读取全局显示规格，脚手架期给出合理默认。
 */
export class Breakpoint {
  private static lastWidthVp: number = 0;

  static syncFromDisplay(widthVp: number): void {
    Breakpoint.lastWidthVp = widthVp;
  }

  static isWide(): boolean {
    return Breakpoint.lastWidthVp === 0 || Breakpoint.lastWidthVp >= MD_MIN_VP;
  }

  static current(): string {
    if (Breakpoint.lastWidthVp === 0) {
      return 'sm(默认)';
    }
    return BreakpointUtil.fromWidth(Breakpoint.lastWidthVp);
  }
}
