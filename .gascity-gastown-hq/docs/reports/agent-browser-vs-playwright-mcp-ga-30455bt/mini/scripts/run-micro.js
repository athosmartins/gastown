'use strict';
// Micro-benchmarks: snapshot size per mode per page, and --delta on "small change on a big/medium page".
const { S, AB, PWMCP, McpClient, scrubbedEnv, resultText, measure, fs } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const http = require('http');
const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const TAG = process.env.RUN_TAG || 'v2';
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const out = { pages: {}, delta: {} };

function cdpHttp(method, path) {
  return new Promise((res, rej) => {
    const rq = http.request({ host: '127.0.0.1', port: CDP, path, method }, (r) => { let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => res(b)); });
    rq.on('error', rej); rq.end();
  });
}
async function resetBrowser() {
  const first = JSON.parse(await cdpHttp('PUT', '/json/new?about:blank'));
  for (const t of JSON.parse(await cdpHttp('GET', '/json/list'))) if (t.id !== first.id) await cdpHttp('GET', '/json/close/' + t.id);
}
function abCmd(args) {
  try { return execFileSync(AB, ['--session', 'mic', '--cdp', String(CDP), ...args], { env, cwd: S + '/work', timeout: 120000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 << 20 }); }
  catch (e) { return (e.stdout || '') + (e.stderr || '') + `\n[exit ${e.status}]`; }
}
function refsOf(text, role, re) {
  const refs = [];
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*- (\w+)(?: "((?:[^"\\]|\\.)*)")?/);
    if (m && m[1] === role && re.test(m[2] || '')) { const r = line.match(/ref=([A-Za-z0-9]+)/); if (r) refs.push(r[1]); }
  }
  return refs;
}
const tok = (t) => measure(t).o200k;
const PAGES = ['login', 'form', 'todo', 'dashboard', 'heavy'];

(async () => {
  await resetBrowser();
  // ---------- snapshot size per mode per page
  const pw = new McpClient(process.execPath, [PWMCP, '--cdp-endpoint', 'http://127.0.0.1:' + CDP], { env });
  await pw.init();
  const P = async (name, args) => resultText(await pw.call(name, args)).text;
  for (const pg of PAGES) {
    const r = {};
    await P('browser_navigate', { url: `${BASE}/${pg}` });
    r['pw snapshot'] = tok(await P('browser_snapshot', {}));
    r['pw snapshot depth=3'] = tok(await P('browser_snapshot', { depth: 3 }));
    r['pw find controls'] = tok(await P('browser_find', { regex: '- (textbox|button|checkbox|radio|combobox|searchbox|link) ' }));
    abCmd(['open', `${BASE}/${pg}`]);
    for (const [k, a] of [['ab snapshot', []], ['ab -i', ['-i']], ['ab -c', ['-c']], ['ab -i -c', ['-i', '-c']], ['ab -d 3', ['-d', '3']], ['ab -i -d 3', ['-i', '-d', '3']]]) {
      const t = abCmd(['snapshot', ...a]);
      r[k] = tok(t);
      if (/^\[exit|✗/m.test(t)) r[k + ' ERR'] = t.slice(0, 120);
    }
    out.pages[pg] = r;
    console.log(pg.padEnd(10), JSON.stringify(r));
  }

  // ---------- delta: small change on a medium page (todo) and on a very big page (heavy)
  async function deltaFlow(pg, pickRefs, nClicks, verifyText) {
    const d = { ab_i_full_each: [], ab_i_delta: [], pw_snapshot_each: [], pw_find_verify: [], ab_delta_text: [] };
    // agent-browser
    abCmd(['open', `${BASE}/${pg}`]);
    const base = abCmd(['snapshot', '-i']);
    const refs = pickRefs(base).slice(0, nClicks);
    abCmd(['snapshot', '-i', '--delta']); // first --delta = full baseline (counted apart)
    d.ab_baseline_full = tok(base);
    for (const r of refs) {
      abCmd(['click', '@' + r]);
      d.ab_i_full_each.push(tok(abCmd(['snapshot', '-i'])));
      const dt = abCmd(['snapshot', '-i', '--delta']);
      d.ab_i_delta.push(tok(dt));
      d.ab_delta_text.push(dt.slice(0, 160).replace(/\n/g, ' '));
    }
    // playwright
    await P('browser_navigate', { url: `${BASE}/${pg}` });
    const pbase = await P('browser_snapshot', {});
    const prefs = pickRefs(pbase).slice(0, nClicks);
    d.pw_baseline_full = tok(pbase);
    for (let i = 0; i < prefs.length; i++) {
      await P('browser_click', { target: prefs[i], element: 'control' });
      d.pw_snapshot_each.push(tok(await P('browser_snapshot', {})));
      d.pw_find_verify.push(tok(await P('browser_find', { text: verifyText(i + 1) })));
    }
    out.delta[pg] = d;
    console.log('delta', pg, JSON.stringify(d));
  }
  await deltaFlow('todo', (t) => refsOf(t, 'button', /Mark done/), 3, (i) => `DONE: Task ${i}:`);
  await deltaFlow('heavy', (t) => refsOf(t, 'button', /Add note/), 3, (i) => `Note ${i} saved`);

  pw.close(); abCmd(['close']);
  fs.writeFileSync(`${S}/out/${TAG}/micro.json`, JSON.stringify(out, null, 1));
  process.exit(0);
})().catch((e) => { console.error('MICRO-ERROR', e); process.exit(1); });
