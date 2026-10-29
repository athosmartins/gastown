'use strict';
// A mitigacao "cada agente abre a PROPRIA aba com browser_tabs{action:new} antes de navegar" isola dois MCPs do Playwright
// no MESMO Chrome? (share-test.js mostrou que sem isso os dois navegam a mesma aba; a bead ga-g7zyxc3 pede medir antes de ensinar.)
const { S, PWMCP, McpClient, scrubbedEnv, resultText, fs } = require('./mcpc.js');
const http = require('http');
const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = [];
const say = (...a) => { const s = a.join(' '); log.push(s); console.log(s); };
function cdpHttp(method, path) {
  return new Promise((res, rej) => { const rq = http.request({ host: '127.0.0.1', port: CDP, path, method }, (r) => { let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => res(b)); }); rq.on('error', rej); rq.end(); });
}
const tabs = async () => JSON.parse(await cdpHttp('GET', '/json/list')).filter((t) => t.type === 'page').map((t) => `${t.id.slice(0, 5)}:${t.url.replace(BASE, '') || 'blank'}`);
async function resetBrowser() {
  const first = JSON.parse(await cdpHttp('PUT', '/json/new?about:blank'));
  for (const t of JSON.parse(await cdpHttp('GET', '/json/list'))) if (t.type === 'page' && t.id !== first.id) await cdpHttp('GET', '/json/close/' + t.id);
  await sleep(500);
}
const title = (t) => ((t.match(/Page Title: (.*)/) || [])[1] || '?').trim();
const T = async (c, n, a) => { try { return resultText(await c.call(n, a)).text; } catch (e) { return '[rpc error] ' + e.message; } };
const mk = async () => { const c = new McpClient(process.execPath, [PWMCP, '--cdp-endpoint', 'http://127.0.0.1:' + CDP], { env }); await c.init(); return c; };

(async () => {
  // ===== M1: os dois abrem aba propria ANTES de navegar
  await resetBrowser();
  say('## M1: PW1 e PW2 comecam com browser_tabs{new}; abas iniciais =', JSON.stringify(await tabs()));
  let p1 = await mk(), p2 = await mk();
  const n1 = await T(p1, 'browser_tabs', { action: 'new', url: BASE + '/tab/A1' });
  say('PW1 tabs new /tab/A1 -> abas', JSON.stringify(await tabs()));
  const n2 = await T(p2, 'browser_tabs', { action: 'new', url: BASE + '/tab/B1' });
  say('PW2 tabs new /tab/B1 -> abas', JSON.stringify(await tabs()));
  say('PW1 ve:', title(await T(p1, 'browser_snapshot', {})), '| PW2 ve:', title(await T(p2, 'browser_snapshot', {})));
  await T(p2, 'browser_navigate', { url: BASE + '/tab/B2' });
  say('PW2 navega B2 -> PW1 ve:', title(await T(p1, 'browser_snapshot', {})), '| PW2 ve:', title(await T(p2, 'browser_snapshot', {})));
  await T(p1, 'browser_navigate', { url: BASE + '/tab/A2' });
  say('PW1 navega A2 -> PW1 ve:', title(await T(p1, 'browser_snapshot', {})), '| PW2 ve:', title(await T(p2, 'browser_snapshot', {})));
  say('PW1 browser_tabs list ->', (await T(p1, 'browser_tabs', { action: 'list' })).replace(/\n/g, ' ').slice(0, 420));
  say('PW2 browser_tabs list ->', (await T(p2, 'browser_tabs', { action: 'list' })).replace(/\n/g, ' ').slice(0, 420));
  say('PW1 browser_tabs close (sem index) ->', (await T(p1, 'browser_tabs', { action: 'close' })).replace(/\n/g, ' ').slice(0, 260));
  say('  abas agora', JSON.stringify(await tabs()), '| PW2 ainda ve:', title(await T(p2, 'browser_snapshot', {})));
  say('PW2 browser_close ->', (await T(p2, 'browser_close', {})).replace(/\n/g, ' ').slice(0, 200));
  say('  abas agora', JSON.stringify(await tabs()));
  p1.close(); p2.close(); await sleep(2000);

  // ===== M2: PW1 ja trabalhava na aba inicial (sem new); PW2 chega e abre aba propria. A aba nova de PW2 "rouba" o foco de PW1?
  await resetBrowser();
  say('\n## M2: PW1 ja navegando na aba inicial; PW2 chega e usa tabs{new}');
  p1 = await mk();
  await T(p1, 'browser_navigate', { url: BASE + '/tab/A1' });
  say('PW1 navega A1 (aba inicial) -> abas', JSON.stringify(await tabs()));
  p2 = await mk();
  await T(p2, 'browser_tabs', { action: 'new', url: BASE + '/tab/B1' });
  say('PW2 tabs new B1 -> abas', JSON.stringify(await tabs()));
  say('PW1 ve (depois da aba nova de PW2):', title(await T(p1, 'browser_snapshot', {})), '| PW2 ve:', title(await T(p2, 'browser_snapshot', {})));
  await T(p1, 'browser_navigate', { url: BASE + '/tab/A2' });
  say('PW1 navega A2 -> abas', JSON.stringify(await tabs()), '| PW2 ve:', title(await T(p2, 'browser_snapshot', {})));
  say('PW2 browser_tabs list ->', (await T(p2, 'browser_tabs', { action: 'list' })).replace(/\n/g, ' ').slice(0, 420));
  p1.close(); p2.close(); await sleep(2000);

  // ===== M3: PW2 chega e SO usa tabs{list}/{select 0} como um agente ingenuo faria (o risco real do "select")
  await resetBrowser();
  say('\n## M3: PW1 em A1; PW2 faz tabs{list} e tabs{select,index 0} (agente que "volta para a primeira aba")');
  p1 = await mk(); await T(p1, 'browser_navigate', { url: BASE + '/tab/A1' });
  p2 = await mk();
  say('PW2 tabs list ->', (await T(p2, 'browser_tabs', { action: 'list' })).replace(/\n/g, ' ').slice(0, 300));
  await T(p2, 'browser_tabs', { action: 'select', index: 0 });
  await T(p2, 'browser_navigate', { url: BASE + '/tab/B1' });
  say('PW2 select 0 + navega B1 -> PW1 ve:', title(await T(p1, 'browser_snapshot', {})), '| abas', JSON.stringify(await tabs()));
  p1.close(); p2.close(); await sleep(1500);
  say('\nchrome vivo:', !!(await cdpHttp('GET', '/json/version')), '| abas finais', JSON.stringify(await tabs()));
  fs.writeFileSync(`${S}/out/${process.env.RUN_TAG || 'mit1'}/share-mitigation.txt`, log.join('\n') + '\n');
  process.exit(0);
})().catch((e) => { console.error('MIT-ERROR', e); process.exit(1); });
