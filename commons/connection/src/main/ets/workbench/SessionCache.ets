/**
 * 会话缓存（A5）：sessions-index 列表与各会话快照的 SQLite 落盘。
 *
 * 目的只有一个——离线/冷启动时工作台仍有内容可画（PRD A5「缓存优先渲染」）。
 * 写入路径：WorkbenchController 在每帧归约后写穿；读取路径：控制器启动与会话页
 * 打开时各读一次。缓存任何失败都不阻塞在线路径（捕获后按无缓存处理并记日志）。
 */
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import common from '@ohos.app.ability.common';

const DOMAIN: number = 0x0000;
const TAG: string = 'SessionCache';

const TABLE_SESSIONS: string = 'sessions';
const TABLE_CONVERSATIONS: string = 'conversations';

export interface CachedConversation {
  sessionId: string;
  snapshotJson: string;
  updatedAt: number;
}

export class SessionCache {
  private readonly store: relationalStore.RdbStore;

  private constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  /** 打开数据库并建表；预览器等不支持环境抛错，由调用方降级为无缓存。 */
  static async open(context: common.Context): Promise<SessionCache> {
    const config: relationalStore.StoreConfig = {
      name: 'workbench-cache.db',
      securityLevel: relationalStore.SecurityLevel.S1,
    };
    const store = await relationalStore.getRdbStore(context, config);
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS ${TABLE_SESSIONS} (`
      + 'workspaceKey TEXT NOT NULL PRIMARY KEY, listJson TEXT NOT NULL, updatedAt INTEGER NOT NULL)');
    await store.executeSql(
      `CREATE TABLE IF NOT EXISTS ${TABLE_CONVERSATIONS} (`
      + 'sessionId TEXT NOT NULL PRIMARY KEY, snapshotJson TEXT NOT NULL, updatedAt INTEGER NOT NULL)');
    return new SessionCache(store);
  }

  /** 保存某工作区的整张会话列表（JSON 视图数组；整行替换）。 */
  async saveSessions(workspaceKey: string, listJson: string): Promise<void> {
    try {
      await this.store.executeSql(
        `INSERT OR REPLACE INTO ${TABLE_SESSIONS} (workspaceKey, listJson, updatedAt) VALUES (?, ?, ?)`,
        [workspaceKey, listJson, Date.now()]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveSessions failed: %{public}s', String(error));
    }
  }

  /** 读取某工作区的会话列表 JSON；无记录返回空串。 */
  async loadSessions(workspaceKey: string): Promise<string> {
    try {
      const resultSet = await this.store.querySql(
        `SELECT listJson FROM ${TABLE_SESSIONS} WHERE workspaceKey = ?`, [workspaceKey]);
      let json: string = '';
      if (resultSet.goToNextRow()) {
        json = resultSet.getString(resultSet.getColumnIndex('listJson'));
      }
      resultSet.close();
      return json;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadSessions failed: %{public}s', String(error));
      return '';
    }
  }

  /** 保存会话快照 JSON（整行替换）。 */
  async saveConversation(sessionId: string, snapshotJson: string): Promise<void> {
    try {
      await this.store.executeSql(
        `INSERT OR REPLACE INTO ${TABLE_CONVERSATIONS} (sessionId, snapshotJson, updatedAt) VALUES (?, ?, ?)`,
        [sessionId, snapshotJson, Date.now()]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveConversation %{public}s failed: %{public}s', sessionId, String(error));
    }
  }

  /** 读取会话快照；无记录返回 null。 */
  async loadConversation(sessionId: string): Promise<CachedConversation | null> {
    try {
      const resultSet = await this.store.querySql(
        `SELECT snapshotJson, updatedAt FROM ${TABLE_CONVERSATIONS} WHERE sessionId = ?`, [sessionId]);
      let cached: CachedConversation | null = null;
      if (resultSet.goToNextRow()) {
        cached = {
          sessionId: sessionId,
          snapshotJson: resultSet.getString(resultSet.getColumnIndex('snapshotJson')),
          updatedAt: resultSet.getLong(resultSet.getColumnIndex('updatedAt')),
        };
      }
      resultSet.close();
      return cached;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadConversation %{public}s failed: %{public}s', sessionId, String(error));
      return null;
    }
  }

  /** 会话删除后的缓存收缩（列表 delta 已带 removal，这里清快照）。 */
  async dropConversation(sessionId: string): Promise<void> {
    try {
      await this.store.executeSql(
        `DELETE FROM ${TABLE_CONVERSATIONS} WHERE sessionId = ?`, [sessionId]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'dropConversation %{public}s failed: %{public}s', sessionId, String(error));
    }
  }
}
