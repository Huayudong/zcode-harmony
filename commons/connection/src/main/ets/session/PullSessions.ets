/**
 * 会话列表拉取（ONB-5 第③步的真实实现，批次6）。
 * 一次性连接：WSS(证书固定)+Bearer → v4 握手 → subscribeSessionsIndex →
 * 等待首个 snapshot 帧 → 返回会话数后立即收尾。不做重连（重连引擎属 ConnectionEngine）。
 */
import util from '@ohos.util';
import {
  AgentV4Client,
  SocketProtocol,
  type WorkspaceTarget,
} from 'protocol';
import { WebSocketTransport } from '../ws/WebSocketTransport';
import { PinnedHttpTarget } from '../http/PinnedHttpClient';

export interface SessionsPullResult {
  /** snapshot 中的会话数（0 也算成功）。 */
  count: number;
  logEpoch: string;
}

export class SessionsPullError extends Error {
  readonly detail: string;

  constructor(detail: string, message: string) {
    super(message);
    this.name = 'SessionsPullError';
    this.detail = detail;
  }
}

export async function pullSessionsSnapshot(target: PinnedHttpTarget, bearerToken: string,
  caFilePath: string, workspace: WorkspaceTarget, timeoutMs: number = 12000): Promise<SessionsPullResult> {
  const transport = new WebSocketTransport();
  let client: AgentV4Client | null = null;
  try {
    await transport.connect(target, bearerToken, caFilePath);
    // 与 web 客户端同链路：SocketProtocol 直连 /ws（可靠性由 v4 水位重订阅承担）
    const protocol = new SocketProtocol(transport);
    // 自检为一次性动作：clientId 用一次性 UUID 即可（设备级持久 id 属 A5 工作台）
    client = await AgentV4Client.connect(protocol, workspace, {
      clientId: util.generateRandomUUID(),
      appVersion: '0.1.0',
    });
    const ack = await client.subscribeSessionsIndex({ visibility: 'foreground' });

    // 首帧（snapshot）到达即视为成功；超时按失败收尾
    return await new Promise<SessionsPullResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new SessionsPullError('超时', '会话列表未在时限内到达'));
      }, timeoutMs);
      interface SnapshotPayloadShape {
        kind?: string;
        snapshot?: SnapshotShape;
      }
      interface SnapshotShape {
        sessions?: object[];
      }
      interface SnapshotFrameShape {
        topic: string;
        subscriptionId: string;
        toSeq: number;
        payload: SnapshotPayloadShape;
      }
      const disposeFrame = client!.onFrame((frame) => {
        const shaped = frame as SnapshotFrameShape;
        const snapshot = shaped.payload?.snapshot;
        if (snapshot === undefined || snapshot.sessions === undefined) {
          return;
        }
        clearTimeout(timer);
        disposeFrame.dispose();
        const rows: object[] = snapshot.sessions;
        resolve({ count: rows.length, logEpoch: ack.logEpoch });
      });
    });
  } finally {
    if (client !== null) {
      client.close();
    }
    transport.dispose();
  }
}
