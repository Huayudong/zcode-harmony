/**
 * 配对客户端：claim 换取设备 token + server-info 自检（a3-pairing spec §1.2/§1.1）。
 * 服务端契约见 zcode 仓 docs/specs/harmony/pairing.md §1。
 */
import http from '@ohos.net.http';
import { PinnedHttpClient, PinnedHttpError, PinnedHttpTarget } from '../http/PinnedHttpClient';

export interface ClaimResponse {
  accessToken: string;
  serverId: string;
  serverName: string;
  certFingerprint: string;
}

export interface ServerInfoCheck {
  serverId: string;
  certFingerprint: string;
  /** 首个工作区（v4 订阅的 workspace target；server-info 未下发时为空串）。 */
  workspacePath: string;
  workspaceIdentity: string;
}

interface ClaimRequestBody {
  pairCode: string;
  deviceName: string;
}

interface ClaimBody {
  accessToken?: string;
  serverId?: string;
  serverName?: string;
  certFingerprint?: string;
}

interface ServerInfoCapabilities {
  certFingerprint?: string;
}

interface ServerInfoWorkspace {
  path?: string;
  workspaceIdentity?: string;
}

interface ServerInfoBody {
  serverId?: string;
  capabilities?: ServerInfoCapabilities;
  workspaces?: ServerInfoWorkspace[];
}

/**
 * claim：POST /api/pairing/claim（公开路径，一次性 pairCode 自身保护）。
 * 响应缺 accessToken/serverId 视为 BadPayload。
 */
export async function claimPairing(client: PinnedHttpClient, target: PinnedHttpTarget,
  pairCode: string, deviceName: string): Promise<ClaimResponse> {
  const requestBody: ClaimRequestBody = {
    pairCode: pairCode,
    deviceName: deviceName,
  };
  const body = await client.jsonRequest<ClaimBody>(target, http.RequestMethod.POST, '/api/pairing/claim', requestBody, '');
  if (body.accessToken === undefined || body.serverId === undefined
    || body.accessToken.length === 0 || body.serverId.length === 0) {
    throw new PinnedHttpError('BadPayload', '配对响应缺少 accessToken/serverId');
  }
  return {
    accessToken: body.accessToken,
    serverId: body.serverId,
    serverName: body.serverName ?? '',
    certFingerprint: (body.certFingerprint ?? '').toLowerCase(),
  };
}

/**
 * 自检第①步：GET /api/server-info（设备 token Bearer）。
 * 服务端下发 certFingerprint 时与深链 fp 比对，不一致抛 FingerprintMismatch（双通道一致性，spec §3.1）。
 */
export async function fetchServerInfo(client: PinnedHttpClient, target: PinnedHttpTarget,
  bearerToken: string, expectedFingerprint: string): Promise<ServerInfoCheck> {
  const body = await client.jsonRequest<ServerInfoBody>(target, http.RequestMethod.GET, '/api/server-info',
    null, bearerToken);
  const serverId = body.serverId ?? '';
  if (serverId.length === 0) {
    throw new PinnedHttpError('BadPayload', 'server-info 缺少 serverId');
  }
  const servedFingerprint = (body.capabilities?.certFingerprint ?? '').toLowerCase();
  if (servedFingerprint.length > 0 && expectedFingerprint.length > 0
    && servedFingerprint !== expectedFingerprint) {
    throw new PinnedHttpError('HandshakeFailed', 'server-info 证书指纹与配对时不一致，可能存在风险');
  }
  return {
    serverId: serverId,
    certFingerprint: servedFingerprint,
    workspacePath: body.workspaces !== undefined && body.workspaces.length > 0
      ? (body.workspaces[0].path ?? '')
      : '',
    workspaceIdentity: body.workspaces !== undefined && body.workspaces.length > 0
      ? (body.workspaces[0].workspaceIdentity ?? '')
      : '',
  };
}
