/**
 * 审批卡片的内容派生（批次21，桌面端 PermissionDialog 的鸿蒙侧移植）。
 *
 * 事实源：packages/ui/src/PermissionDialog.tsx + packages/shared/src/permission-request-preview.ts。
 * 移植范围（App 端消费面）：
 * - displayReason：优先工具入参的 description/reason/summary，过滤两条通用策略文案；
 * - 命令文本提取（command/cmd/script/shellcommand + args 拼接，深搜 rawInput/input）；
 * - 文件路径收集（FILE_PATH_KEYS，忽略 cwd/directory）与 changes 收集（path+type）；
 * - blockKind 分流（saveWorkflow/mcp/skill/workflow/search/edit/execute/fallback）；
 * - 选项排序（allowOnce→allowAlways→fullAccess(1.5)→deny 系→custom）与中文 label 映射；
 * - bash 命令前缀 scope（response.permissionUpdates.addRules，":*" 后缀）。
 *
 * 纯逻辑 node/设备双端可运行（一致性门禁逐向量对拍）。
 */

// ── 通用原因过滤（与桌面 NON_USER_FACING_PERMISSION_REASONS 同源）──
const NON_USER_FACING_REASONS: string[] = [
  'High risk tools require explicit approval',
  'Tool has side effects and requires approval',
];

const COMMAND_KEYS: string[] = ['command', 'cmd', 'script', 'shellcommand'];
const ARGUMENT_KEYS: string[] = ['args', 'argv', 'arguments'];
const FILE_PATH_KEYS: string[] = [
  'path', 'paths', 'file', 'file_path', 'filepath', 'files', 'filename', 'filenames',
  'target', 'targets', 'location', 'locations',
];
const IGNORED_DIRECTORY_KEYS: string[] = ['cwd', 'directory', 'workingdirectory'];
const MAX_PERMISSION_FILE_PATHS = 6;
const MAX_SCOPES = 5;
const SCOPE_MAX_CHARS = 160;

/** 内容块类型（桌面 blockKind 子集；workflow/saveWorkflow 桌面走专用窗，App 归并 workflow）。 */
export type ApprovalBlockKind =
  | 'edit'
  | 'mcp'
  | 'skill'
  | 'search'
  | 'workflow'
  | 'execute'
  | 'fallback';

export interface ApprovalPreview {
  /** 用户可读原因（已过滤通用文案；空串 = 无）。 */
  displayReason: string;
  blockKind: ApprovalBlockKind;
  /** execute 块的命令文本（空串 = 无）。 */
  command: string;
  /** 涉及文件路径（去重，≤6）。 */
  filePaths: string[];
  /** edit 块的文件变更（path + add/update，≤16）。 */
  fileChanges: ApprovalFileChange[];
  /** mcp 块：display 或工具名派生的 server/tool 标识。 */
  mcpServerName: string;
  mcpToolName: string;
  /** search 块：URL/query 摘要。 */
  searchUrl: string;
  searchQuery: string;
}

export interface ApprovalFileChange {
  path: string;
  type: string;
}

// ── 防御性取值（与 WorkbenchModel 同风格）──

function isRecord(value: object | null): boolean {
  return value !== null && !Array.isArray(value);
}

/** Record 值的运行时全谱（ArkTS 流类型：索引取值需覆盖 string 才能过 typeof 窄化）。 */
type FieldValue = object | string | null;

function recordOf(value: object | null): Record<string, FieldValue> {
  return value as Record<string, FieldValue>;
}

function readNonEmpty(value: object | null, key: string): string | null {
  if (value === null) {
    return null;
  }
  const raw: FieldValue = recordOf(value)[key] ?? null;
  if (typeof raw !== 'string') {
    return null;
  }
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeInline(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

function normalizeBlock(value: string): string {
  return value.trim().replace(/\r\n/g, '\n');
}

/** 通用策略原因不可读（与桌面 readUserFacingPermissionReason 语义一致）。 */
function userFacingReason(value: string | null): string | null {
  if (value === null) {
    return null;
  }
  for (const generic of NON_USER_FACING_REASONS) {
    if (value === generic) {
      return null;
    }
  }
  return value;
}

/** 桌面 readPermissionInputSource：优先 rawInput，回退 input，再回退本体。 */
function inputSourceOf(detail: object | null): object | null {
  if (detail === null) {
    return null;
  }
  const record = recordOf(detail);
  const rawInput: FieldValue = record['rawInput'] ?? null;
  if (rawInput !== null && typeof rawInput === 'object') {
    return rawInput;
  }
  const input: FieldValue = record['input'] ?? null;
  if (input !== null && typeof input === 'object') {
    return input;
  }
  return detail;
}

/** 深搜命令文本（与桌面 getCommandFromRecord/findFirstCommand 同语义）。 */
function commandFromRecord(record: object | null): string | null {
  if (record === null) {
    return null;
  }
  const entries = Object.entries(recordOf(record));
  for (const entry of entries) {
    const key = entry[0];
    const value = entry[1];
    if (COMMAND_KEYS.indexOf(key.toLowerCase()) < 0 || typeof value !== 'string') {
      continue;
    }
    const command = normalizeBlock(value);
    if (command.length === 0) {
      continue;
    }
    for (const argsEntry of entries) {
      if (ARGUMENT_KEYS.indexOf(argsEntry[0].toLowerCase()) < 0) {
        continue;
      }
      // args 是数组：字符串元素拼接回命令行
      if (Array.isArray(argsEntry[1])) {
        const list: string[] = [];
        for (const item of argsEntry[1]) {
          if (typeof item === 'string' && item.trim().length > 0) {
            list.push(item.trim());
          }
        }
        if (list.length > 0) {
          return `${command} ${list.join(' ')}`;
        }
      }
    }
    return command;
  }
  return null;
}

function isObject(value: FieldValue | undefined): boolean {
  return value !== null && value !== undefined && !Array.isArray(value) && typeof value !== 'string';
}

function findFirstCommand(value: object | null, seen: Set<object>, allowBareString: boolean): string | null {
  if (typeof value === 'string') {
    if (!allowBareString) {
      return null;
    }
    const command = normalizeBlock(value);
    return command.length > 0 ? command : null;
  }
  if (Array.isArray(value)) {
    if (seen.has(value)) {
      return null;
    }
    seen.add(value);
    for (const item of value) {
      const nested = findFirstCommand(isObject(item) || Array.isArray(item) ? item as object : null, seen, false);
      if (nested !== null) {
        return nested;
      }
    }
    return null;
  }
  if (!isRecord(value) || seen.has(value)) {
    return null;
  }
  seen.add(value);
  const direct = commandFromRecord(value);
  if (direct !== null) {
    return direct;
  }
  const nestedKeys = ['rawInput', 'input', 'params', 'toolCall'];
  for (const key of nestedKeys) {
    const raw: FieldValue = recordOf(value)[key] ?? null;
    if (raw === null) {
      continue;
    }
    const nested = findFirstCommand(isObject(raw) || Array.isArray(raw) ? raw as object : null, seen,
      key === 'rawInput' || key === 'input' || key === 'params');
    if (nested !== null) {
      return nested;
    }
  }
  for (const key of Object.keys(recordOf(value))) {
    const nestedValue = recordOf(value)[key];
    if (!isObject(nestedValue) && !Array.isArray(nestedValue)) {
      continue;
    }
    const nested = findFirstCommand(nestedValue as object, seen, false);
    if (nested !== null) {
      return nested;
    }
  }
  return null;
}

// ── 文件路径 / changes 收集（与桌面 collectFilePaths/collectFileChanges 同语义）──

function pushUniquePath(paths: string[], value: string): void {
  const normalized = normalizeInline(value);
  if (normalized.length === 0 || paths.indexOf(normalized) >= 0) {
    return;
  }
  paths.push(normalized);
}

function extractPathsFromCandidate(value: object | string | null, paths: string[], seen: Set<object>): void {
  if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
    return;
  }
  if (typeof value === 'string') {
    pushUniquePath(paths, value);
    return;
  }
  if (value === null) {
    return;
  }
  if (Array.isArray(value)) {
    if (seen.has(value)) {
      return;
    }
    seen.add(value);
    for (const item of value) {
      extractPathsFromCandidate(isObject(item) || Array.isArray(item) || typeof item === 'string' ? item as object : null, paths, seen);
      if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
        return;
      }
    }
    return;
  }
  if (!isRecord(value) || seen.has(value)) {
    return;
  }
  seen.add(value);
  const directPath = readNonEmpty(value, 'path');
  if (directPath !== null) {
    pushUniquePath(paths, directPath);
    if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
      return;
    }
  }
  for (const key of Object.keys(recordOf(value))) {
    const nested = recordOf(value)[key];
    if (!isObject(nested) && !Array.isArray(nested) && typeof nested !== 'string') {
      continue;
    }
    // 候选宽化（object | string | null）后无需 as 跨类型转换
    const nestedCandidate: object | string | null = typeof nested === 'string' ? nested
      : (isObject(nested) || Array.isArray(nested) ? nested : null);
    extractPathsFromCandidate(nestedCandidate, paths, seen);
    if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
      return;
    }
  }
}

function collectFilePaths(value: object | null, paths: string[], seen: Set<object>): void {
  if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
    return;
  }
  if (Array.isArray(value)) {
    if (seen.has(value)) {
      return;
    }
    seen.add(value);
    for (const item of value) {
      collectFilePaths(isObject(item) || Array.isArray(item) ? item as object : null, paths, seen);
      if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
        return;
      }
    }
    return;
  }
  if (!isRecord(value) || seen.has(value)) {
    return;
  }
  seen.add(value);
  for (const key of Object.keys(recordOf(value))) {
    const normalizedKey = key.toLowerCase();
    if (IGNORED_DIRECTORY_KEYS.indexOf(normalizedKey) >= 0) {
      continue;
    }
    const candidate = recordOf(value)[key];
    if (FILE_PATH_KEYS.indexOf(normalizedKey) >= 0) {
      extractPathsFromCandidate(
        isObject(candidate) || Array.isArray(candidate) || typeof candidate === 'string' ? candidate as object : null,
        paths, seen);
      if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
        return;
      }
      continue;
    }
    if (!Array.isArray(candidate) && !isObject(candidate)) {
      continue;
    }
    collectFilePaths(candidate as object, paths, seen);
    if (paths.length >= MAX_PERMISSION_FILE_PATHS) {
      return;
    }
  }
}

function collectFileChanges(value: object | null, changes: ApprovalFileChange[], seen: Set<object>): void {
  if (value === null) {
    return;
  }
  if (Array.isArray(value)) {
    if (seen.has(value)) {
      return;
    }
    seen.add(value);
    for (const item of value) {
      collectFileChanges(isObject(item) || Array.isArray(item) ? item as object : null, changes, seen);
    }
    return;
  }
  if (!isRecord(value) || seen.has(value)) {
    return;
  }
  seen.add(value);
  const changesField = recordOf(value)['changes'];
  if (isObject(changesField)) {
    const changesRecord = recordOf(changesField as object);
    for (const path of Object.keys(changesRecord)) {
      const change = changesRecord[path];
      if (!isObject(change)) {
        continue;
      }
      const type = readNonEmpty(change as object, 'type');
      if (type !== 'add' && type !== 'update') {
        continue;
      }
      let duplicate = false;
      for (const existing of changes) {
        if (existing.path === path && existing.type === type) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) {
        changes.push({ path: path, type: type });
      }
    }
  }
  for (const key of Object.keys(recordOf(value))) {
    const nested = recordOf(value)[key];
    if (!Array.isArray(nested) && !isObject(nested)) {
      continue;
    }
    collectFileChanges(nested as object, changes, seen);
  }
}

// ── 桌面级派生入口 ──

/** 工具族判定（桌面 resolveToolCallIdentity 的最小面：按工具名前缀/词表）。 */
function searchUrlsOf(detail: object | null): { url: string; query: string } {
  const source = inputSourceOf(detail);
  let url = '';
  let query = '';
  if (source !== null) {
    const urlValue = readNonEmpty(source, 'url');
    if (urlValue !== null) {
      url = urlValue;
    }
    const queryValue = readNonEmpty(source, 'query') ?? readNonEmpty(source, 'q');
    if (queryValue !== null) {
      query = queryValue;
    }
  }
  return { url: url, query: query };
}

function mcpIdentityOf(toolName: string, detail: object | null, display: object | null): { server: string; tool: string } {
  // display.mcp_tool 优先（toolCallDisplay 的 serverName/toolName）
  if (display !== null) {
    const server = readNonEmpty(display, 'serverName');
    const tool = readNonEmpty(display, 'toolName');
    if (server !== null || tool !== null) {
      return { server: server ?? '', tool: tool ?? '' };
    }
  }
  // mcp__server__tool 形态拆分
  if (toolName.startsWith('mcp__')) {
    const parts = toolName.split('__');
    if (parts.length >= 3) {
      return { server: parts[1], tool: parts.slice(2).join('__') };
    }
  }
  return { server: '', tool: toolName };
}

/**
 * v4 pendingInteraction(permission) → 审批卡片内容（对齐桌面 PermissionDialog 要素）。
 * @param toolName payload.toolName
 * @param summary payload.summary（CLI reason）
 * @param detail payload.detail（工具完整输入；可空）
 * @param display payload.display（toolCallDisplay；可空）
 */
export function deriveApprovalContent(
  toolName: string,
  summary: string,
  detail: object | null,
  display: object | null,
): ApprovalPreview {
  const source = inputSourceOf(detail);

  // displayReason：detail.description/reason/summary → summary → detail 原因（过滤通用文案）
  const inputReason = userFacingReason(
    userFacingReason(readNonEmpty(source, 'description'))
    ?? userFacingReason(readNonEmpty(source, 'reason'))
    ?? userFacingReason(readNonEmpty(source, 'summary')));
  const displayReason = inputReason ?? userFacingReason(summary) ?? '';

  const filePaths: string[] = [];
  collectFilePaths(detail, filePaths, new Set<object>());
  const fileChanges: ApprovalFileChange[] = [];
  collectFileChanges(detail, fileChanges, new Set<object>());
  if (fileChanges.length > 16) {
    fileChanges.length = 16;
  }
  const command = findFirstCommand(detail, new Set<object>(), true) ?? '';

  // blockKind 分流（桌面 resolvePermissionBlockKind 的 App 面）：
  // workflow/saveWorkflow 按工具名词表；mcp 按前缀；skill/search 按词表；
  // edit 按 changes；execute 按命令；其余 fallback。
  const lowered = toolName.toLowerCase();
  let blockKind: ApprovalBlockKind = 'fallback';
  if (lowered.indexOf('saveworkflow') >= 0 || lowered.indexOf('createworkflow') >= 0
    || lowered.indexOf('amendworkflow') >= 0) {
    blockKind = 'workflow';
  } else if (fileChanges.length > 0) {
    blockKind = 'edit';
  } else if (toolName.startsWith('mcp__')) {
    blockKind = 'mcp';
  } else if (lowered === 'skill') {
    blockKind = 'skill';
  } else if (lowered === 'webfetch' || lowered === 'websearch') {
    blockKind = 'search';
  } else if (command.length > 0) {
    blockKind = 'execute';
  }

  const search = blockKind === 'search' ? searchUrlsOf(detail) : { url: '', query: '' };
  const mcp = blockKind === 'mcp' ? mcpIdentityOf(toolName, detail, display) : { server: '', tool: '' };

  return {
    displayReason: displayReason,
    blockKind: blockKind,
    command: command,
    filePaths: filePaths,
    fileChanges: fileChanges,
    mcpServerName: mcp.server,
    mcpToolName: mcp.tool,
    searchUrl: search.url,
    searchQuery: search.query,
  };
}

// ── 选项排序与中文映射 ──

/** 显示序（桌面 sortPermissionOptions：allowOnce 0 / allowAlways 1 / fullAccess 1.5 / deny 2-3 / custom 4）。 */
export function approvalOptionPriority(optionId: string, kind: string): number {
  if (optionId === 'fullAccess') {
    return 1.5;
  }
  if (kind === 'allowOnce') {
    return 0;
  }
  if (kind === 'allowAlways') {
    return 1;
  }
  if (kind === 'deny') {
    return 2;
  }
  return 4;
}

/** 选项展示名：optionId/词表 → 桌面中文 i18n（zh-CN.ts 同源）；未知回退服务端 label。 */
export function approvalOptionLabel(optionId: string, kind: string, label: string): string {
  if (optionId === 'allow_once') {
    return '允许';
  }
  if (optionId === 'allow_project') {
    return '始终允许本项目';
  }
  if (optionId === 'allowSession') {
    return '允许本会话';
  }
  if (optionId === 'fullAccess') {
    return '完全访问';
  }
  if (optionId === 'deny') {
    return '拒绝';
  }
  // kind 兜底（未知 optionId 时按桌面 displayKind 映射）
  if (kind === 'allowOnce') {
    return '允许';
  }
  if (kind === 'allowAlways') {
    return '始终允许';
  }
  if (kind === 'deny') {
    return '拒绝';
  }
  return label.length > 0 ? label : '确认';
}

/** 选项说明行（桌面 getOptionDescriptionMessageId 的中文面；空串 = 无）。 */
export function approvalOptionDescription(optionId: string, kind: string, scope: string): string {
  if (kind === 'allowOnce') {
    return '仅允许这一次';
  }
  if (kind === 'allowAlways') {
    if (optionId === 'allowSession') {
      return '本会话内不再询问';
    }
    if (scope === 'command') {
      return '后续相同命令不再询问';
    }
    if (scope === 'file') {
      return '后续相同文件操作不再询问';
    }
    return '后续相同权限请求不再询问';
  }
  if (kind === 'deny') {
    return '这次先拒绝';
  }
  if (optionId === 'fullAccess') {
    return '授予 Agent 完全访问权限，不再确认。';
  }
  return '';
}

/**
 * bash 命令前缀 scope（桌面 readPermissionRuleScopes）：
 * response.permissionUpdates.addRules(allow) 中 toolName=bash 且 ruleContent 以 ":*" 结尾的规则，
 * 去掉后缀取首行截断（≤160 字符，超长补 " …"）。
 */
export function approvalOptionScopes(response: object | null): string[] {
  const scopes: string[] = [];
  if (response === null) {
    return scopes;
  }
  const updates = recordOf(response)['permissionUpdates'];
  if (!Array.isArray(updates)) {
    return scopes;
  }
  for (const update of updates) {
    if (!isObject(update)) {
      continue;
    }
    if (readNonEmpty(update, 'type') !== 'addRules' || readNonEmpty(update, 'behavior') !== 'allow') {
      continue;
    }
    const rules = recordOf(update)['rules'];
    if (!Array.isArray(rules)) {
      continue;
    }
    for (const rule of rules) {
      if (!isObject(rule)) {
        continue;
      }
      const toolName = readNonEmpty(rule, 'toolName');
      if (toolName === null || toolName.toLowerCase() !== 'bash') {
        continue;
      }
      const content = (readNonEmpty(rule, 'ruleContent') ?? '').trim();
      if (!content.endsWith(':*')) {
        continue;
      }
      const prefix = content.slice(0, content.length - 2);
      const lineBreak = prefix.search(/\r?\n/);
      const firstLine = lineBreak < 0 ? prefix : prefix.slice(0, lineBreak);
      const truncated = lineBreak >= 0 || firstLine.length > SCOPE_MAX_CHARS;
      const visible = firstLine.slice(0, SCOPE_MAX_CHARS - 2).trimEnd();
      scopes.push(truncated ? `${visible} …` : visible);
      if (scopes.length >= MAX_SCOPES) {
        return scopes;
      }
    }
  }
  return scopes;
}
