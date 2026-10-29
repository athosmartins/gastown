'use strict';
// --pin-tab happy path + failure modes, with FRESH session names (a reused name keeps a stale tab binding).
const { S, AB, scrubbedEnv, fs } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const http = require('http');
const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = [];
const say = (...a) => { const s = a.join(' '); log.push(s); console.log(s); };
const cdpHttp = (method, path) => new Promise((res, rej) => { const rq = http.request({ host: '127.0.0.1', port: CDP, path, method }, (r) => { let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => res(b)); }); rq.on('error', rej); rq.end(); });
const tabs = async () => JSON.parse(await cdpHttp('GET', '/json/list')).filter((t) => t.type === 'page').map((t) => `${t.id.slice(0, 6)}:${t.url.replace(BASE, '')}`);
async function resetBrowser() {
  const first = JSON.parse(await cdpHttp('PUT', '/json/new?about:blank'));
  for (const t of JSON.parse(await cdpHttp('GET', '/json/list'))) if (t.id !== first.id) await cdpHttp('GET', '/json/close/' + t.id);
  await sleep(500);
}
const ab = (sess, args) => {
  try { return execFileSync(AB, ['--session', sess, '--cdp', String(CDP), ...args], { env, cwd: S + '/work', timeout: 60000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
  catch (e) { return `[exit ${e.status}] ` + ((e.stdout || '') + (e.stderr || '')).trim().replace(/\n/g, ' | '); }
};
const one = (s) => s.replace(/\s+/g, ' ').slice(0, 260);

(async () => {
  const run = Date.now().toString(36).slice(-4), a = 'pa' + run, b = 'pb' + run; // short: socket path limit
  await resetBrowser();
  say('## AB WITH --pin-tab, fresh sessions', a, b, '; start tabs =', JSON.stringify(await tabs()));
  say(a, 'open A1 ->', one(ab(a, ['--pin-tab', 'open', BASE + '/tab/A1'])));
  say(b, 'open B1 ->', one(ab(b, ['--pin-tab', 'open', BASE + '/tab/B1'])));
  say('tabs now', JSON.stringify(await tabs()));
  say(a, 'title:', ab(a, ['get', 'title']), '|', b, 'title:', ab(b, ['get', 'title']));
  say(b, 're-open B2 ->', one(ab(b, ['open', BASE + '/tab/B2'])));
  say('after', b, 're-open: ', a, 'title:', ab(a, ['get', 'title']), '|', b, 'title:', ab(b, ['get', 'title']), '| tabs', JSON.stringify(await tabs()));
  const tl = ab(b, ['tab', 'list', '--json']);
  let ids = [];
  try { ids = JSON.parse(tl).data.tabs.map((t) => ({ id: t.targetId, url: t.url, active: t.active })); } catch (e) { say('tab list parse failed:', one(tl)); }
  say(b, 'tab list ->', JSON.stringify(ids.map((t) => `${t.id.slice(0, 6)}:${t.url.replace(BASE, '')}${t.active ? '*' : ''}`)));
  const aTab = ids.find((t) => /A1/.test(t.url));
  if (aTab) say(b, 'tries to take', a, 'tab ->', one(ab(b, ['tab', aTab.id])));
  // a human/another tool opens a tab: must not steal the pinned session's active tab
  await cdpHttp('PUT', '/json/new?' + BASE + '/tab/HUMAN');
  await sleep(500);
  say('human opens a tab -> tabs', JSON.stringify(await tabs()), '|', a, 'title:', ab(a, ['get', 'title']), '|', b, 'title:', ab(b, ['get', 'title']));
  // close a's tab from outside -> strict pin must fail loudly, never act on another tab
  const victim = JSON.parse(await cdpHttp('GET', '/json/list')).find((t) => /A1/.test(t.url));
  if (victim) { await cdpHttp('GET', '/json/close/' + victim.id); await sleep(800); }
  say(a, 'tab closed externally; get title ->', one(ab(a, ['get', 'title'])));
  say(a, 'click-like action on a gone tab (eval) ->', one(ab(a, ['eval', 'document.title'])));
  say(b, 'unaffected ->', ab(b, ['get', 'title']));
  say(a, 'recover with tab new ->', one(ab(a, ['tab', 'new', BASE + '/tab/A2'])), '|', a, 'title:', ab(a, ['get', 'title']));
  ab(a, ['close']); ab(b, ['close']); await sleep(1500);
  say('after both close -> tabs', JSON.stringify(await tabs()), '| chrome alive:', !!(await cdpHttp('GET', '/json/version')));
  fs.writeFileSync(`${S}/out/${process.env.RUN_TAG || 'v2'}/pin-test.txt`, log.join('\n') + '\n');
  process.exit(0);
})().catch((e) => { console.error('PIN-ERROR', e); process.exit(1); });
