// 从种子文件出发做 import 可达性剪枝：删除 v4 目录中未被引用的文件。
// 运行：node tools/prune-v4.cjs
const fs = require('fs');
const path = require('path');
const DEST = 'commons/protocol/src/main/ets/v4';
const SEED = [
  'apply.ts', 'coalesce.ts', 'command.ts', 'core.ts', 'delta.ts', 'rows.ts',
  'snapshot.ts', 'sessions-index.ts', 'sessions-index-workflow-activity.ts',
  'shared-context-import.ts', 'toolDisplay.ts', 'transport.ts',
  'wire-assembler.ts', 'wire-binary.ts', 'wire-codec.ts', 'wire-reassembly.ts',
  'wire.ts', 'workflow-observation-display.ts', 'workflow-row-meta.ts',
  'workflow-runs.ts',
];

function importsOf(file) {
  const text = fs.readFileSync(file, 'utf8');
  const re = /(?:from|import)\s*['"]\.\/([^'"]+)\.js['"]/g;
  const out = new Set();
  let m;
  while ((m = re.exec(text)) !== null) out.add(m[1] + '.ts');
  return out;
}

const keep = new Set();
const queue = [...SEED];
while (queue.length) {
  const name = queue.shift();
  if (keep.has(name) || !fs.existsSync(path.join(DEST, name))) continue;
  keep.add(name);
  for (const dep of importsOf(path.join(DEST, name))) queue.push(dep);
}

const removed = [];
for (const f of fs.readdirSync(DEST)) {
  if (f.endsWith('.ts') && !keep.has(f)) {
    fs.unlinkSync(path.join(DEST, f));
    removed.push(f);
  }
}
console.log(`kept ${keep.size}, removed ${removed.length}:`);
console.log(removed.sort().join('\n'));
