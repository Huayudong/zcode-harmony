/**
 * 基础设施：Event / Disposable（@zcode/rpc foundation.ts 的最小移植子集）。
 * 仅移植 protocol 层用到的 Emitter / DisposableStore / toDisposable。
 */

export interface IDisposable {
  dispose(): void;
}

export function toDisposable(fn: () => void): IDisposable {
  return { dispose: fn };
}

export interface Event<T> {
  (listener: (e: T) => void): IDisposable;
}

export interface EmitterOptions {
  onWillAddFirstListener?(): void;
  onDidRemoveLastListener?(): void;
}

export class Emitter<T> implements IDisposable {
  private listeners = new Set<(e: T) => void>();
  private disposed = false;
  private options?: EmitterOptions;

  constructor(options?: EmitterOptions) {
    this.options = options;
  }

  get event(): Event<T> {
    return (listener: (e: T) => void): IDisposable => {
      if (this.disposed) {
        return toDisposable(() => {});
      }

      const isFirst = this.listeners.size === 0;
      this.listeners.add(listener);

      if (isFirst) {
        this.options?.onWillAddFirstListener?.();
      }

      return toDisposable(() => {
        this.listeners.delete(listener);
        if (this.listeners.size === 0) {
          this.options?.onDidRemoveLastListener?.();
        }
      });
    };
  }

  public fire(event: T): void {
    if (this.disposed) {
      return;
    }
    for (const listener of [...this.listeners]) {
      listener(event);
    }
  }

  public dispose(): void {
    this.disposed = true;
    this.listeners.clear();
  }
}

export class DisposableStore implements IDisposable {
  private items = new Set<IDisposable>();
  private isDisposed = false;

  public add<T extends IDisposable>(item: T): T {
    if (this.isDisposed) {
      console.warn('Adding to a disposed DisposableStore');
      item.dispose();
      return item;
    }
    this.items.add(item);
    return item;
  }

  public dispose(): void {
    if (this.isDisposed) {
      return;
    }
    this.isDisposed = true;
    for (const item of [...this.items]) {
      item.dispose();
    }
    this.items.clear();
  }
}


// ── 取消令牌（@zcode/rpc foundation.ts 的最小移植子集）──

export interface CancellationToken {
  readonly isCancellationRequested: boolean;
  readonly onCancellationRequested: Event<void>;
}

const cancellationNone: CancellationToken = {
  isCancellationRequested: false,
  onCancellationRequested: (): IDisposable => toDisposable(() => {}),
};

export const CancellationToken = {
  None: cancellationNone,
};

/** 等待事件首次触发（ChannelClient whenInitialized 用）。 */
export function eventToPromise<T>(event: Event<T>): Promise<T> {
  return new Promise<T>((resolve) => {
    const d = event((e: T) => {
      d.dispose();
      resolve(e);
    });
  });
}
