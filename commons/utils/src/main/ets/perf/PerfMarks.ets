import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * PerfMarks —— 6.3 性能 P0 指标的自埋点（A10 离线部分）。
 * mark(name) 记锚点；measure(name, fromTag) 输出「6.3 <指标>: N ms」日志，
 * 真机跑 S 场景时 hilog 过滤 PerfMarks 即可逐项核对 6.3 表。
 * 高频段（chunk 上屏）用 sampleIntervalMs 限流防日志洪泛。
 * 口径说明：应用内埋点与系统口径（点击图标→首帧）存在固有差值，真机批以 Profiler 对照。
 */
const marks = new Map<string, number>();
const lastLogged = new Map<string, number>();

export class PerfMarks {
  static mark(tag: string): void {
    marks.set(tag, Date.now());
  }

  static clear(tag: string): void {
    marks.delete(tag);
  }

  /** 从锚点测耗时并记日志；无锚点返回 -1（不记日志）。 */
  static measure(name: string, fromTag: string, sampleIntervalMs: number = 0): number {
    const start = marks.get(fromTag);
    if (start === undefined) {
      return -1;
    }
    const now = Date.now();
    const ms = now - start;
    if (sampleIntervalMs > 0) {
      const last = lastLogged.get(name) ?? 0;
      if (now - last < sampleIntervalMs) {
        return ms;
      }
    }
    lastLogged.set(name, now);
    hilog.info(0, 'PerfMarks', '6.3 %{public}s: %{public}d ms', name, ms);
    return ms;
  }
}
