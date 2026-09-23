/* 一步到位的页面预览渲染：spawn 引擎 → 发现端口 → 连接 WS → 收帧 → 存 JPEG → 杀引擎。
 * 用法: node render-page.js <pageUrl> <outJpg> [waitForMs=12000] [buildRoot=.preview]
 * 前提：PreviewBuild 已按目标页重生成 FakeUIAbility；产物根内 res 的 main_pages.json 含目标页。
 * 已知坑：引擎第一帧在 WS 监听后 ~2s 推送且静态页不再补发，本脚本需尽早连接；
 *        预览产物的路由表（res/.../main_pages.json）可能因增量缓存过期，需与源码核对。
 */
const fs = require('fs');
const { spawn, execSync } = require('child_process');

const PAGE = process.argv[2];
const OUT = process.argv[3];
const WAIT_MS = Number(process.argv[4] || 12000);
const BUILD_ROOT = process.argv[5] || '.preview';
const ENGINE = 'D:/Huawei/DevEco Studio/sdk/default/openharmony/previewer/common/bin/Previewer.exe';
const ROOT = 'E:/program/zcode-harmony';
const P = ROOT + '/entry/' + BUILD_ROOT;
const ENGINE_LOG = ROOT + '/entry/' + BUILD_ROOT + '/engine.log';

function engineArgs(pageUrl) {
  return [
    '-refresh', 'region', '-projectID', 'zctool', '-ts', 'trace_zctool_commandPipe',
    '-rt', P + '/default/intermediates/res/default/ResourceTable.txt',
    '-rp', P + '/default/intermediates/res/default',
    '-cjp', P + '/config/buildConfig.json',
    '-r', 'Module',
    '-j', P + '/default/intermediates/assets/default/ets',
    '-ljPath', P + '/default/intermediates/loader/default/loader.json',
    '-s', 'zctool_pipe', '-device', 'phone', '-shape', 'rect', '-sd', '480',
    '-or', '1080', '2340', '-cr', '360', '780',
    '-n', 'entry', '-url', pageUrl, '-av', 'ACE_2_0', '-pm', 'Stage', '-pages', 'main_pages',
    '-d', '', '-abn', 'FakeUIAbility',
    '-abp', '@normalized:N&&&entry/' + BUILD_ROOT + '/fakeuiability/FakeUIAbility&',
    '-arp', P + '/default/intermediates/res/default',
    '-hsp', 'D:/Huawei/DevEco Studio/sdk/default/hms/previewer',
    '-cpm', 'false',
  ];
}

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
        const m = line.match(new RegExp('\\sTCP\\s+127\\.0\\.0\\.1:(\\d+)\\s+.*LISTENING\\s+' + pid + '\\s*'));
        if (m) return m[1];
      }
    }
  } catch {
    return null;
  }
  return null;
}

(async () => {
  try { execSync('taskkill /IM Previewer.exe /F', { stdio: 'ignore' }); } catch {}
  const engine = spawn(ENGINE, engineArgs(PAGE), {
    stdio: ['ignore', fs.openSync(ENGINE_LOG, 'w'), fs.openSync(ENGINE_LOG, 'a')],
  });
  console.log('engine spawned pid=' + engine.pid + ' page=' + PAGE + ' root=' + BUILD_ROOT);
  let ws = null;
  for (let i = 0; i < 240 && !ws; i++) {
    const port = findEnginePort();
    if (i % 8 === 0) console.log('poll ' + i + ': port=' + port);
    if (port !== null) {
      ws = await new Promise((resolve) => {
        try {
          const w = new WebSocket('ws://127.0.0.1:' + port);
          w.binaryType = 'arraybuffer';
          w.addEventListener('open', () => resolve(w));
          w.addEventListener('error', () => resolve(null));
        } catch {
          resolve(null);
        }
      });
    }
    if (!ws) await new Promise((r) => setTimeout(r, 250));
  }
  if (!ws) {
    console.log('WS-CONNECT-FAIL');
    try { engine.kill(); } catch {}
    console.log('--- engine log tail ---');
    try { console.log(fs.readFileSync(ENGINE_LOG, 'utf8').split('\n').slice(-12).join('\n')); } catch {}
    process.exit(1);
  }
  console.log('ws connected');
  const frames = [];
  ws.addEventListener('message', (e) => {
    if (typeof e.data === 'string') {
      console.log('TEXT: ' + String(e.data).slice(0, 120));
      return;
    }
    frames.push(Buffer.from(e.data));
  });
  setTimeout(() => {
    try { engine.kill(); } catch {}
    if (frames.length === 0) {
      console.log('NO-FRAMES');
      process.exit(1);
    }
    const last = frames[frames.length - 1];
    fs.writeFileSync(OUT, last.slice(40));
    console.log('frames=' + frames.length + ' saved=' + (last.length - 40) + 'B -> ' + OUT);
    process.exit(0);
  }, WAIT_MS);
})();
