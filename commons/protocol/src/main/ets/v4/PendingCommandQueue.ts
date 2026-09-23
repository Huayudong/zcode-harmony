/**
 * PendingCommandQueue —— 断线期命令排队（A4 重连引擎的纯逻辑面）。
 *
 * 计划 §1.4 不变量：重连期间不得发送新 command（排队到重连成功后按幂等
 * commandId 提交）。commandId 由客户端生成且重试不变，服务端 CommandInbox
 * 按 commandId 幂等去重——因此「发出后未收到 ACK 即断线」的命令重连后
 * 原样重发是安全的（duplicate ACK 视为成功）。
 *
 * 状态所有者：每连接一份；TTL 与条目上限对齐 PROTOCOL_V4_LIMITS
 * （commandPendingTtlMs 24h / pendingCommandsDisplayMax 32）。
 */

import { PROTOCOL_V4_LIMITS } from './core.js';
import type { CommandEnvelope } from './command.js';

export interface QueuedCommand {
  envelope: CommandEnvelope;
  /** 已尝试发送次数（跨重连累计；仅观测用）。 */
  attempts: number;
}

export class PendingCommandQueue {
  private items: QueuedCommand[] = [];

  get size(): number {
    return this.items.length;
  }

  /** 入队；同 commandId 幂等（重连恢复路径重复入队为 no-op）。 */
  enqueue(envelope: CommandEnvelope): void {
    if (this.items.some((item) => item.envelope.commandId === envelope.commandId)) {
      return;
    }
    if (this.items.length >= PROTOCOL_V4_LIMITS.pendingCommandsDisplayMax) {
      // 队满 fail-fast 丢最旧：命令面是用户动作，静默堆积 24h 不如早失败可解释
      this.items.shift();
    }
    this.items.push({ envelope, attempts: 0 });
  }

  /** 取出全部待发命令（不出队；sendFulfilled/逐条 settle 后移除）。 */
  peekAll(): QueuedCommand[] {
    return [...this.items];
  }

  /** 单条发送完成（ACK 到达，含 duplicate/rejected 等终态）后移除。 */
  settle(commandId: string): void {
    this.items = this.items.filter((item) => item.envelope.commandId !== commandId);
  }

  /** 标记一次发送尝试（发出但未收到 ACK；重连后重发同一 commandId）。 */
  markAttempt(commandId: string): void {
    const item = this.items.find((entry) => entry.envelope.commandId === commandId);
    if (item) {
      item.attempts += 1;
    }
  }

  /** 清理超龄命令（TTL 对齐服务端 pendingCommands 24h）。 */
  dropExpired(now: number): CommandEnvelope[] {
    const expired: CommandEnvelope[] = [];
    this.items = this.items.filter((item) => {
      const alive = now - item.envelope.issuedAt <= PROTOCOL_V4_LIMITS.commandPendingTtlMs;
      if (!alive) {
        expired.push(item.envelope);
      }
      return alive;
    });
    return expired;
  }

  /** 主动断开/切换档案时清空（断线重连不清空——重发幂等提交）。 */
  clear(): void {
    this.items = [];
  }
}
