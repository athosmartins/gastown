'use strict';
// Smoke test: look at the REAL response shapes of both stacks on the login fixture.
const { S, AB, PWMCP, McpClient, scrubbedEnv, resultText, measure, fs } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const head = (t, n) => t.slice(0, n).replace(/\n/g, '\n    ');

function abRun(session, args) {
  try {
    const out = execFileSync(AB, ['--session', session, '--cdp', String(CDP), ...args], { env, cwd: S + '/work', timeout: 60000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return out;
  } catch (e) { return 'ERR rc=' + e.status + ' stdout=' + (e.stdout || '') + ' stderr=' + (e.stderr || ''); }
}

(async () => {
  // ---- PW-MCP default
  for (const mode of (process.env.SKIP_PW ? [] : ['full', 'none'])) {
    const c = new McpClient(process.execPath, [PWMCP, '--cdp-endpoint', 'http://127.0.0.1:' + CDP, '--snapshot-mode', mode], { env });
    await c.init();
    const r1 = resultText(await c.call('browser_navigate', { url: BASE + '/login' }));
    console.log(`\n=== PW-MCP snapshot-mode=${mode} navigate /login: ${JSON.stringify(measure(r1.text))} items=${r1.items} err=${r1.isError}`);
    console.log('    ' + head(r1.text, 1800));
    fs.writeFileSync(`${S}/out/smoke-pw-${mode}-navigate.txt`, r1.text);
    if (mode === 'none') {
      const r2 = resultText(await c.call('browser_snapshot', {}));
      console.log(`--- PW-MCP none: explicit browser_snapshot: ${JSON.stringify(measure(r2.text))}`);
      fs.writeFileSync(`${S}/out/smoke-pw-none-snapshot.txt`, r2.text);
      console.log('    ' + head(r2.text, 900));
    }
    c.close();
    await new Promise((r) => setTimeout(r, 2000));
  }
  // ---- AB CLI
  const s = 'smoke1';
  console.log('\n=== AB open: ', JSON.stringify(abRun(s, ['open', BASE + '/login'])).slice(0, 400));
  for (const [label, a] of [['snapshot', ['snapshot']], ['-i', ['snapshot', '-i']], ['-c', ['snapshot', '-c']], ['-i -c', ['snapshot', '-i', '-c']], ['-i --delta', ['snapshot', '-i', '--delta']], ['get title', ['get', 'title']]]) {
    const t = abRun(s, a);
    console.log(`--- AB ${label}: ${JSON.stringify(measure(t))}`);
    fs.writeFileSync(`${S}/out/smoke-ab-${label.replace(/[^a-z]+/gi, '_')}.txt`, t);
    if (label === '-i' || label === 'get title') console.log('    ' + head(t, 1500));
  }
  console.log('=== AB close', JSON.stringify(abRun(s, ['close'])).slice(0, 200));
  process.exit(0);
})().catch((e) => { console.error('SMOKE-ERROR', e); process.exit(1); });
