/* 等待 Previewer 引擎出现 → 自动发现其 127.0.0.1 监听端口 → 连接抓帧 → 保存 JPEG。
 * 用法: node wait-and-grab.js <outJpg> [collectMs]
 * 先于引擎启动本脚本（引擎第一帧在监听后 ~2s 发出，静态页之后不再有帧）。 */
const fs = require('fs');
const { execSync } = require('child_process');
const out = process.argv[2];
const collectMs = Number(process.argv[3] || 6000);

function findEnginePort() {
  let pids = [];
  try {
    const tl = execSync('tasklist /FI "IMAGENAME eq Previewer.exe" /FO CSV', { encoding: 'utf8' });
    for (const line of tl.split('\n')) {
      const m = line.match(/^"Previewer\.exe","(\d+)"/);
      if (m) pids.push(m[1]);
    }
  } catch {
    return null;
  }
  if (pids.length === 0) return null;
  try {
    const ns = execSync('netstat -ano -p TCP', { encoding: 'utf8' });
    for (const line of ns.split('\n')) {
      for (const pid of pids) {
        const m = line.match(new RegExp(`^\\s*TCP\\s+127\\.0\\.0\\.1:(\\d+)\\s+.*LISTENING\\s+${pid}\\s*$`));
        if (m) return m[1];
      }
    }
  } catch {
    return null;
  }
  return null;
}

function connectOnce(port) {
  return new Promise((resolve) => {
    try {
      const w = new WebSocket(`ws://127.0.0.1:${port}`);
      w.binaryType = 'arraybuffer';
      w.addEventListener('open', () => resolve(w));
      w.addEventListener('error', () => resolve(null));
    } catch {
      resolve(null);
    }
  });
}

(async () => {
  let ws = null;
  for (let i = 0; i < 200 && !ws; i++) {
    const port = findEnginePort();
    if (port !== null) {
      ws = await connectOnce(port);
    }
    if (!ws) await new Promise((r) => setTimeout(r, 250));
  }
  if (!ws) {
    console.log('WS-CONNECT-FAIL');
    process.exit(1);
  }
  const frames = [];
  ws.addEventListener('message', (e) => {
    if (typeof e.data === 'string') { return; }
    frames.push(Buffer.from(e.data));
  });
  setTimeout(() => {
    if (frames.length === 0) {
      console.log('NO-FRAMES');
      process.exit(1);
    }
    const last = frames[frames.length - 1];
    fs.writeFileSync(out, last.slice(40));
    console.log(`frames=${frames.length} saved=${last.length - 40}B -> ${out}`);
    process.exit(0);
  }, collectMs);
})();
