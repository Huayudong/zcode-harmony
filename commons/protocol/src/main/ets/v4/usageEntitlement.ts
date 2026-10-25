/**
 * 套餐权益快照投影（批次21 输入栏「用量」面板的数据面）。
 * 事实源：packages/shared/src/usage-stats.ts 的 UsageEntitlementSnapshot +
 * usage-quota.ts 的 UsageQuotaSnapshot；channels RPC `usage-stats.getEntitlementSnapshot`
 * 原始返回经本文件防御性投影成 .ets 可消费的视图（node/设备双端可运行）。
 *
 * 口径注意：quota.limits[].percentage 是**已使用占比**（桌面同源注释），
 * UI 显示「剩余」时自行取 100-percentage。
 */

export interface UsageQuotaLimitView {
  /** 限额类型（如 5h / weekly / MCP_USAGE_LIMIT；空串 = 未标注）。 */
  type: string;
  /** 已使用占比（0-100；-1 = 未披露）。 */
  percentage: number;
  /** 剩余绝对值（-1 = 未披露）。 */
  remaining: number;
  /** 下次重置时间（毫秒；0 = 未披露）。 */
  nextResetTime: number;
  /** 周期（daily/one_time/…；空串 = 未标注）。 */
  period: string;
}

export interface UsageEntitlementView {
  /** false = 未登录/未配置/无套餐（看 unavailableReason）。 */
  authenticated: boolean;
  /** not_authenticated/not_configured/no_plan/unavailable；空串 = 可用。 */
  unavailableReason: string;
  /** 个人/团队上下文显示名（空串 = 无）。 */
  contextName: string;
  /** 供应商名（空串 = 无）。 */
  providerName: string;
  /** 剩余次数（-1 = 未披露）。 */
  remainingCount: number;
  /** 剩余百分比（-1 = 未披露）。 */
  remainingPercentage: number;
  /** 下次重置（毫秒；0 = 未披露）。 */
  nextResetTime: number;
  /** 订阅账号掩码（邮箱/手机号；空串 = 无）。 */
  identityMasked: string;
  /** 额度桶（可能多个周期；空数组 = 无）。 */
  limits: UsageQuotaLimitView[];
}

/** Record 值的运行时全谱（ArkTS 流类型：索引取值需覆盖标量才能过 typeof/=== 窄化）。 */
type FieldValue = object | string | number | boolean | null;

function isObj(value: FieldValue | undefined): boolean {
  // typeof 先行：缺键在运行时是 undefined（类型面看不见），typeof 能同时挡 null/undefined/标量
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function strAt(source: Record<string, FieldValue>, key: string): string {
  const value: FieldValue = source[key] ?? null;
  return typeof value === 'string' ? value : '';
}

function numAt(source: Record<string, FieldValue>, key: string): number {
  const value: FieldValue = source[key] ?? null;
  return typeof value === 'number' && Number.isFinite(value) ? value : -1;
}

function boolAt(source: Record<string, FieldValue>, key: string): boolean {
  const value: FieldValue = source[key] ?? null;
  return value === true;
}

function childAt(source: Record<string, FieldValue>, key: string): Record<string, FieldValue> | null {
  const value: FieldValue = source[key] ?? null;
  return isObj(value) ? value as Record<string, FieldValue> : null;
}

/** channels RPC 原始返回 → 视图（防御性；任何缺字段都落默认值而不是抛错）。 */
export function parseEntitlementSnapshot(raw: object | null): UsageEntitlementView {
  const view: UsageEntitlementView = {
    authenticated: false,
    unavailableReason: 'unavailable',
    contextName: '',
    providerName: '',
    remainingCount: -1,
    remainingPercentage: -1,
    nextResetTime: 0,
    identityMasked: '',
    limits: [],
  };
  if (!isObj(raw)) {
    return view;
  }
  const root = raw as Record<string, FieldValue>;
  view.authenticated = boolAt(root, 'authenticated');
  view.unavailableReason = strAt(root, 'unavailableReason');
  const context = childAt(root, 'context');
  if (context !== null) {
    const name = strAt(context, 'displayName');
    const scope = strAt(context, 'scope');
    view.contextName = name.length > 0 ? (scope === 'team' ? `${name}（团队）` : name) : scope;
  }
  const provider = childAt(root, 'provider');
  if (provider !== null) {
    view.providerName = strAt(provider, 'name');
  }
  const remaining = childAt(root, 'remaining');
  if (remaining !== null) {
    view.remainingCount = numAt(remaining, 'count');
    view.remainingPercentage = numAt(remaining, 'percentage');
    view.nextResetTime = numAt(remaining, 'nextResetTime') > 0 ? numAt(remaining, 'nextResetTime') : 0;
  }
  const subscription = childAt(root, 'subscription');
  if (subscription !== null) {
    view.identityMasked = strAt(subscription, 'identityMasked');
  }
  const quota = childAt(root, 'quota');
  if (quota !== null && Array.isArray(quota['limits'])) {
    for (const item of quota['limits'] as object[]) {
      if (!isObj(item)) {
        continue;
      }
      const limit = item as Record<string, FieldValue>;
      const limitView: UsageQuotaLimitView = {
        type: strAt(limit, 'type'),
        percentage: numAt(limit, 'percentage'),
        remaining: numAt(limit, 'remaining'),
        nextResetTime: numAt(limit, 'nextResetTime') > 0 ? numAt(limit, 'nextResetTime') : 0,
        period: strAt(limit, 'period'),
      };
      view.limits.push(limitView);
    }
  }
  return view;
}
