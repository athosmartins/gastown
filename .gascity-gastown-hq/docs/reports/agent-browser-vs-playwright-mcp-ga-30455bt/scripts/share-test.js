'use strict';
// Two "agents" on ONE shared Chromium (like :9222 on the mini): do they trample each other's tab?
const { S, AB, PWMCP, McpClient, scrubbedEnv, resultText, fs } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const http = require('http');
const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = [];
const say = (...a) => { const s = a.join(' '); log.push(s); console.log(s); };

function cdpHttp(method, path) {
  return new Promise((res, rej) => {
    const rq = http.request({ host: '127.0.0.1', port: CDP, path, method }, (r) => { let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => res(b)); });
    rq.on('error', rej); rq.end();
  });
}
async function tabs() { return JSON.parse(await cdpHttp('GET', '/json/list')).filter((t) => t.type === 'page').map((t) => `${t.id.slice(0, 6)}:${t.url.replace(BASE, '')}`); }
async function resetBrowser() {
  const first = JSON.parse(await cdpHttp('PUT', '/json/new?about:blank'));
  for (const t of JSON.parse(await cdpHttp('GET', '/json/list'))) if (t.id !== first.id) await cdpHttp('GET', '/json/close/' + t.id);
  await sleep(500);
}
const ab = (sess, args) => {
  try { return execFileSync(AB, ['--session', sess, '--cdp', String(CDP), ...args], { env, cwd: S + '/work', timeout: 60000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
  catch (e) { return `[exit ${e.status}] ` + ((e.stdout || '') + (e.stderr || '')).trim().replace(/\n/g, ' | '); }
};
const pwTitle = (t) => ((t.match(/Page Title: (.*)/) || [])[1] || '?').trim();

(async () => {
  // ================= Playwright MCP x2
  await resetBrowser();
  say('## PW-MCP: two MCP server processes, same Chrome; start tabs =', JSON.stringify(await tabs()));
  const mk = async () => { const c = new McpClient(process.execPath, [PWMCP, '--cdp-endpoint', 'http://127.0.0.1:' + CDP], { env }); await c.init(); return c; };
  const p1 = await mk(), p2 = await mk();
  const T = async (c, n, a) => resultText(await c.call(n, a)).text;
  await T(p1, 'browser_navigate', { url: BASE + '/tab/A1' });
  say('PW1 navigate /tab/A1 -> tabs', JSON.stringify(await tabs()));
  await T(p2, 'browser_navigate', { url: BASE + '/tab/B1' });
  say('PW2 navigate /tab/B1 -> tabs', JSON.stringify(await tabs()));
  say('PW1 snapshot sees:', pwTitle(await T(p1, 'browser_snapshot', {})), '| PW2 sees:', pwTitle(await T(p2, 'browser_snapshot', {})));
  await T(p2, 'browser_navigate', { url: BASE + '/tab/B2' });
  say('after PW2 navigates again: PW1 sees:', pwTitle(await T(p1, 'browser_snapshot', {})), '| tabs', JSON.stringify(await tabs()));
  const tl = await T(p1, 'browser_tabs', { action: 'list' });
  say('PW1 browser_tabs list ->', tl.replace(/\n/g, ' ').slice(0, 330));
  await T(p1, 'browser_close', {});
  say('after PW1 browser_close -> tabs', JSON.stringify(await tabs()), '| PW2 still sees:', pwTitle(await T(p2, 'browser_snapshot', {})));
  p1.close(); p2.close(); await sleep(2500);
  say('after both MCP processes exit -> tabs', JSON.stringify(await tabs()), '| chrome alive:', !!(await cdpHttp('GET', '/json/version')));

  // ================= agent-browser, NO --pin-tab
  await resetBrowser();
  say('\n## AB without --pin-tab (2 sessions, --cdp); start tabs =', JSON.stringify(await tabs()));
  ab('s1', ['open', BASE + '/tab/A1']); say('s1 open /tab/A1 -> tabs', JSON.stringify(await tabs()));
  ab('s2', ['open', BASE + '/tab/B1']); say('s2 open /tab/B1 -> tabs', JSON.stringify(await tabs()));
  say('s1 get title:', ab('s1', ['get', 'title']), '| s2 get title:', ab('s2', ['get', 'title']));
  ab('s1', ['close']); ab('s2', ['close']); await sleep(1500);
  say('after both close -> tabs', JSON.stringify(await tabs()), '| chrome alive:', !!(await cdpHttp('GET', '/json/version')));

  // ================= agent-browser, WITH --pin-tab
  await resetBrowser();
  say('\n## AB WITH --pin-tab; start tabs =', JSON.stringify(await tabs()));
  say('s1 open:', ab('s1', ['--pin-tab', 'open', BASE + '/tab/A1']).replace(/\n/g, ' | '));
  say('s2 open:', ab('s2', ['--pin-tab', 'open', BASE + '/tab/B1']).replace(/\n/g, ' | '));
  say('tabs now', JSON.stringify(await tabs()));
  say('s1 get title:', ab('s1', ['get', 'title']), '| s2 get title:', ab('s2', ['get', 'title']));
  ab('s2', ['open', BASE + '/tab/B2']);
  say('after s2 re-open B2: s1 get title:', ab('s1', ['get', 'title']), '| s2:', ab('s2', ['get', 'title']));
  const tl2 = ab('s2', ['tab', 'list', '--json']);
  say('s2 tab list --json ->', tl2.slice(0, 420).replace(/\s+/g, ' '));
  // try to steal s1's tab from s2
  let s1id = ''; try { const j = JSON.parse(tl2); const arr = j.data && (j.data.tabs || j.data); const hit = (arr || []).find((t) => /A1/.test(t.url || '')); s1id = hit && (hit.targetId || hit.id); } catch (e) { /* parse miss is reported below */ }
  say('s1 tab targetId parsed from s2 list:', s1id || '(not parsed)');
  if (s1id) say('s2 tries to take s1 tab ->', ab('s2', ['tab', s1id]));
  // close s1's tab from outside -> strict pin must fail loudly
  const victim = JSON.parse(await cdpHttp('GET', '/json/list')).find((t) => /A1/.test(t.url));
  if (victim) { await cdpHttp('GET', '/json/close/' + victim.id); await sleep(800); }
  say('s1 tab closed externally; s1 get title ->', ab('s1', ['get', 'title']));
  say('s2 still fine ->', ab('s2', ['get', 'title']), '| tabs', JSON.stringify(await tabs()));
  ab('s1', ['close']); ab('s2', ['close']); await sleep(1500);
  say('after both close -> tabs', JSON.stringify(await tabs()), '| chrome alive:', !!(await cdpHttp('GET', '/json/version')));
  fs.writeFileSync(`${S}/out/${process.env.RUN_TAG || 'v2'}/share-test.txt`, log.join('\n') + '\n');
  process.exit(0);
})().catch((e) => { console.error('SHARE-ERROR', e); process.exit(1); });
