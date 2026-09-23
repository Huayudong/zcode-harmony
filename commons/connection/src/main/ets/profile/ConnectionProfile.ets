/**
 * 连接档案与存储（a3-pairing spec §2）。
 * ProfileStore：preferences 唯一写入路径；TokenStore：设备 token 唯一写入路径（Asset Kit，不落明文沙箱）。
 */
import dataPreferences from '@ohos.data.preferences';
import asset from '@ohos.security.asset';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';

export interface ConnectionProfile {
  id: string;
  name: string;
  host: string;
  port: number;
  /** SPKI SHA-256 hex（空 = 无证书固定）。 */
  certFingerprint: string;
}

const PREFS_NAME: string = 'zcode-connection';
const KEY_PROFILES: string = 'profiles';
const KEY_ACTIVE_ID: string = 'activeId';

export class ProfileStore {
  private readonly prefs: dataPreferences.Preferences;

  private constructor(prefs: dataPreferences.Preferences) {
    this.prefs = prefs;
  }

  static async open(context: common.Context): Promise<ProfileStore> {
    const prefs = await dataPreferences.getPreferences(context, { name: PREFS_NAME });
    return new ProfileStore(prefs);
  }

  async listProfiles(): Promise<ConnectionProfile[]> {
    const raw = await this.prefs.get(KEY_PROFILES, '[]') as string;
    try {
      const parsed = JSON.parse(raw) as ConnectionProfile[];
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  async activeProfile(): Promise<ConnectionProfile | null> {
    const profiles = await this.listProfiles();
    if (profiles.length === 0) {
      return null;
    }
    const activeId = await this.prefs.get(KEY_ACTIVE_ID, '') as string;
    for (const profile of profiles) {
      if (profile.id === activeId) {
        return profile;
      }
    }
    return profiles[0];
  }

  /** 原子落盘：先写档案列表，再切活跃指针（spec §3.5）。返回档案 id。 */
  async saveProfile(profile: ConnectionProfile): Promise<string> {
    const profiles = await this.listProfiles();
    let replaced = false;
    for (let index = 0; index < profiles.length; index += 1) {
      if (profiles[index].id === profile.id) {
        profiles[index] = profile;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      profiles.push(profile);
    }
    await this.prefs.put(KEY_PROFILES, JSON.stringify(profiles));
    await this.prefs.put(KEY_ACTIVE_ID, profile.id);
    await this.prefs.flush();
    return profile.id;
  }
}

function tokenAlias(serverId: string): string {
  return `zcode_device_token_${serverId}`;
}

function bytesFromText(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

function textFromBytes(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeWithStream(bytes);
}

/**
 * 设备 token 存储：Asset Store Kit（PRD CONN-5，不落应用沙箱明文）。
 * Asset Kit 不可用的环境（预览器/CI）抛封闭错误，由页面显式展示失败——不静默降级（spec §3/A3-7）。
 */
export class AssetTokenStore {
  async save(serverId: string, token: string): Promise<void> {
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, bytesFromText(tokenAlias(serverId)));
    attributes.set(asset.Tag.SECRET, bytesFromText(token));
    await asset.add(attributes);
  }

  async load(serverId: string): Promise<string> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, bytesFromText(tokenAlias(serverId)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const results = await asset.query(query);
    if (results.length === 0) {
      throw new Error('token 不存在');
    }
    const secret = results[0].get(asset.Tag.SECRET);
    if (secret === undefined || !(secret instanceof Uint8Array)) {
      throw new Error('token 不存在');
    }
    return textFromBytes(secret as Uint8Array);
  }

  async remove(serverId: string): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, bytesFromText(tokenAlias(serverId)));
    await asset.remove(query);
  }
}
