// 批次6移植辅助：把 zcode 仓 shared 的 v4 schema 闭包拷进 commons/protocol/src/main/ets/v4，
// 相对导入改写为本目录 ./xxx.js；记录每个文件的源目录以正确解析 ../。
// zcode-protocol barrel 导入按符号拆到深源文件。可重复运行（先清空输出目录）。
// 运行：node tools/port-v4-deps.cjs
const fs = require('fs');
const path = require('path');

const SRC = 'F:/program/zcode/packages/shared/src';
const DEST = 'commons/protocol/src/main/ets/v4';

// 初始种子：zcode-protocol-v4 的移植目标文件（闭包自动补齐其余）
const SEED = [
  'apply', 'coalesce', 'command', 'core', 'delta', 'rows', 'snapshot',
  'sessions-index', 'sessions-index-workflow-activity', 'shared-context-import',
  'toolDisplay', 'transport', 'wire-assembler', 'wire-binary', 'wire-codec',
  'wire-reassembly', 'wire', 'workflow-observation-display', 'workflow-row-meta',
  'workflow-runs',
];

fs.rmSync(DEST, { recursive: true, force: true });
fs.mkdirSync(DEST, { recursive: true });

// destName -> 源绝对路径（解析该文件的相对导入时用其真实来源目录）
const origin = new Map();
const queue = [];

for (const name of SEED) {
  const src = path.join(SRC, 'zcode-protocol-v4', name + '.ts');
  const destName = name + '.ts';
  fs.copyFileSync(src, path.join(DEST, destName));
  origin.set(destName, src);
  queue.push(destName);
}

function resolveFrom(spec, sourceDir) {
  const bare = spec.replace(/\.js$/, '');
  const candidate = path.resolve(sourceDir, bare + '.ts');
  if (fs.existsSync(candidate)) return { file: candidate, isIndex: path.basename(candidate) === 'index.ts' };
  const candidateIndex = path.resolve(sourceDir, bare, 'index.ts');
  if (fs.existsSync(candidateIndex)) return { file: candidateIndex, isIndex: true };
  return null;
}

function findSymbolDef(symbol) {
  const root = path.join(SRC, 'zcode-protocol');
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) { stack.push(full); continue; }
      if (!e.name.endsWith('.ts')) continue;
      const text = fs.readFileSync(full, 'utf8');
      const re = new RegExp('export\\s+(?:const|function|class|type|interface|enum)\\s+' + symbol + '\\b');
      if (re.test(text)) return full;
    }
  }
  return null;
}

let barrelRewrites = 0;
const processed = new Set();

while (queue.length) {
  const destName = queue.shift();
  if (processed.has(destName)) continue;
  processed.add(destName);
  const srcPath = origin.get(destName);
  const sourceDir = path.dirname(srcPath);
  const destPath = path.join(DEST, destName);
  let text = fs.readFileSync(destPath, 'utf8');

  function ensureCopied(resolvedFile) {
    const localName = path.basename(resolvedFile).replace(/\.ts$/, '') + '.ts';
    const destFile = path.join(DEST, localName);
    if (!fs.existsSync(destFile)) {
      fs.copyFileSync(resolvedFile, destFile);
      origin.set(localName, resolvedFile);
      queue.push(localName);
    } else if (!origin.has(localName)) {
      origin.set(localName, resolvedFile);
    }
    return localName;
  }

  const importRe = /(from\s*['"])([^'"]+)(['"])/g;
  const edits = [];
  let m;
  while ((m = importRe.exec(text)) !== null) {
    const spec = m[2];
    if (!spec.startsWith('.')) continue; // zod 等外部
    // 先按 DEST 本地解析（已移植文件互相引用）
    const localBare = path.join(DEST, spec.replace(/\.js$/, '') + '.ts');
    if (fs.existsSync(localBare)) continue;
    const resolved = resolveFrom(spec, sourceDir);
    if (!resolved) {
      console.warn(`  ? unresolved: ${spec} (from ${destName}, src ${sourceDir})`);
      continue;
    }
    if (resolved.isIndex) {
      const stmtStart = text.lastIndexOf('import', m.index);
      const stmtEnd = m.index + m[0].length;
      const stmt = text.slice(stmtStart, stmtEnd);
      const namesMatch = stmt.match(/\{([\s\S]*?)\}/);
      if (!namesMatch) continue;
      const symbols = namesMatch[1].split(',').map(s => s.trim().split(/\s+as\s+/)[0].replace(/^type\s+/, '')).filter(Boolean);
      const byFile = new Map();
      let ok = true;
      for (const sym of symbols) {
        const def = findSymbolDef(sym);
        if (!def) { console.warn(`  ! barrel symbol not found: ${sym} (in ${destName})`); ok = false; continue; }
        const local = ensureCopied(def);
        if (!byFile.has(local)) byFile.set(local, new Set());
        byFile.get(local).add(sym);
      }
      if (!ok) continue;
      const lines = [];
      for (const [local, syms] of byFile) lines.push(`import { ${[...syms].join(', ')} } from "./${local.replace(/\.ts$/, '.js')}";`);
      edits.push({ start: stmtStart, end: stmtEnd, text: lines.join('\n') });
      barrelRewrites += 1;
      continue;
    }
    const localRef = ensureCopied(resolved.file);
    edits.push({ start: m.index + m[1].length, end: m.index + m[1].length + spec.length, text: `./${localRef.replace(/\.ts$/, '.js')}` });
  }

  if (edits.length) {
    edits.sort((a, b) => b.start - a.start);
    for (const e of edits) text = text.slice(0, e.start) + e.text + text.slice(e.end);
    fs.writeFileSync(destPath, text);
  }
}

console.log(`closure complete: ${processed.size} files, barrel rewrites: ${barrelRewrites}`);
