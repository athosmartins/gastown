'use strict';
// Mecanica do login federado (redirect / popup / iframe) com as duas stacks, contra o IdP de TESTE local (idp-server.js)
// e um Chrome DESCARTAVEL. Nao ha conta real: demo-user / demo-pass. Registra o que funciona e o que quebra; nao aborta no 1o erro.
const { S, AB, PWMCP, McpClient, scrubbedEnv, resultText, measure, fs } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const RP = 'http://127.0.0.1:47901', CDP = 47222;
const TAG = process.env.RUN_TAG || 'idp1';
const outdir = `${S}/out/${TAG}`; fs.mkdirSync(outdir, { recursive: true });
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const http = require('http');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];

function cdpHttp(method, path) {
  return new Promise((res, rej) => { const rq = http.request({ host: '127.0.0.1', port: CDP, path, method }, (r) => { let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => res(b)); }); rq.on('error', rej); rq.end(); });
}
async function resetBrowser() {
  const first = JSON.parse(await cdpHttp('PUT', '/json/new?about:blank'));
  for (const t of JSON.parse(await cdpHttp('GET', '/json/list'))) if (t.type === 'page' && t.id !== first.id) await cdpHttp('GET', '/json/close/' + t.id);
  await sleep(400);
}
async function pageTabs() { return JSON.parse(await cdpHttp('GET', '/json/list')).filter((t) => t.type === 'page').map((t) => t.url.replace(/127\.0\.0\.1:4790/, ':').slice(0, 60)); }
function findRef(text, role, nameRe) {
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*- (\w+)(?: "((?:[^"\\]|\\.)*)")?/);
    if (!m || m[1] !== role || !nameRe.test(m[2] || '')) continue;
    const r = line.match(/ref=([A-Za-z0-9]+)/); if (r) return r[1];
  }
  return null;
}
class Rec {
  constructor(stack, flow) { this.stack = stack; this.flow = flow; this.calls = 0; this.tok = 0; this.ms = 0; this.notes = []; this.ok = false; this.log = []; }
  add(label, text, ms) { this.calls++; this.tok += measure(text).o200k; this.ms += ms; this.log.push(`--- ${label} (${ms} ms)\n${text.slice(0, 1800)}`); }
  note(s) { this.notes.push(s); }
  done(ok) {
    this.ok = ok; const o = { stack: this.stack, flow: this.flow, ok, calls: this.calls, respTok: this.tok, ms: this.ms, notes: this.notes };
    results.push(o); console.log(JSON.stringify(o));
    fs.writeFileSync(`${outdir}/idp-${this.stack}-${this.flow}.txt`, this.log.join('\n') + '\n\nNOTES: ' + this.notes.join(' | ') + '\n');
  }
}

// ---------------- Playwright MCP
async function pwFlows() {
  for (const flow of ['redirect', 'popup', 'iframe']) {
    await resetBrowser();
    const c = new McpClient(process.execPath, [PWMCP, '--cdp-endpoint', 'http://127.0.0.1:' + CDP], { env });
    await c.init();
    const R = new Rec('pw', flow);
    const call = async (label, name, input) => {
      const t0 = Date.now(); let text;
      try { const r = resultText(await c.call(name, input)); text = (r.isError ? '[tool error] ' : '') + r.text; }
      catch (e) { text = '[rpc error] ' + e.message; }
      R.add(`${label}: ${name} ${JSON.stringify(input).slice(0, 120)}`, text, Date.now() - t0); return text;
    };
    try {
      await call('abrir RP', 'browser_navigate', { url: RP + '/' });
      let snap = await call('snapshot', 'browser_snapshot', {});
      if (flow === 'redirect') {
        const link = findRef(snap, 'link', /Entrar com IdP-Teste$/); if (!link) { R.note('link nao achado'); R.done(false); c.close(); continue; }
        await call('clicar no link', 'browser_click', { target: link, element: 'link Entrar com IdP-Teste' });
        snap = await call('snapshot do IdP', 'browser_snapshot', {});
        const u = findRef(snap, 'textbox', /Usu/), p = findRef(snap, 'textbox', /Senha/), b = findRef(snap, 'button', /^Entrar$/);
        if (!u || !p || !b) { R.note(`refs no IdP: u=${u} p=${p} b=${b}`); R.done(false); c.close(); continue; }
        await call('preencher', 'browser_fill_form', { fields: [{ target: u, name: 'Usuario', type: 'textbox', value: 'demo-user' }, { target: p, name: 'Senha', type: 'textbox', value: 'demo-pass' }] });
        await call('entrar', 'browser_click', { target: b, element: 'botao Entrar' });
        const f = await call('confirmar', 'browser_find', { text: 'Olá, demo-user' });
        R.done(/Olá, demo-user/.test(f));
      } else if (flow === 'popup') {
        const pop = findRef(snap, 'button', /popup/); if (!pop) { R.note('botao popup nao achado'); R.done(false); c.close(); continue; }
        const ck = await call('clicar (abre popup)', 'browser_click', { target: pop, element: 'botao popup' });
        R.note('apos o click o chrome tem: ' + JSON.stringify(await pageTabs()));
        let tl = '', idx;
        for (let k = 0; k < 6 && idx === undefined; k++) { // o popup nasce com URL vazia: espera ele carregar
          if (k) await sleep(500);
          tl = await call('listar abas', 'browser_tabs', { action: 'list' });
          idx = (tl.match(/- (\d+):[^\n]*IdP-Teste/) || tl.match(/- (\d+):[^\n]*authorize/) || [])[1];
        }
        R.note('popup na lista: ' + (idx === undefined ? 'NAO apareceu' : 'indice ' + idx) + (/popup|IdP/i.test(ck) ? ' | o click ja avisou da aba nova' : ''));
        if (idx === undefined) { R.done(false); c.close(); continue; }
        await call('selecionar popup', 'browser_tabs', { action: 'select', index: Number(idx) });
        snap = await call('snapshot do popup', 'browser_snapshot', {});
        const u = findRef(snap, 'textbox', /Usu/), p = findRef(snap, 'textbox', /Senha/), b = findRef(snap, 'button', /^Entrar$/);
        if (!u || !p || !b) { R.note(`refs no popup: u=${u} p=${p} b=${b}`); R.done(false); c.close(); continue; }
        await call('preencher', 'browser_fill_form', { fields: [{ target: u, name: 'Usuario', type: 'textbox', value: 'demo-user' }, { target: p, name: 'Senha', type: 'textbox', value: 'demo-pass' }] });
        await call('entrar (o popup se fecha)', 'browser_click', { target: b, element: 'botao Entrar' });
        await sleep(600);
        R.note('depois do popup fechar o chrome tem: ' + JSON.stringify(await pageTabs()));
        tl = await call('listar abas', 'browser_tabs', { action: 'list' });
        await call('voltar a aba 0', 'browser_tabs', { action: 'select', index: 0 });
        const f = await call('confirmar', 'browser_find', { text: 'Logado via popup' });
        R.done(/Logado via popup/.test(f));
      } else {
        const u = findRef(snap, 'textbox', /Usu/), p = findRef(snap, 'textbox', /Senha/), b = findRef(snap, 'button', /^Entrar$/);
        R.note(`refs no snapshot da pagina (iframe incluso?): u=${u} p=${p} b=${b}`);
        if (!u || !p || !b) { R.done(false); c.close(); continue; }
        await call('preencher (dentro do iframe)', 'browser_fill_form', { fields: [{ target: u, name: 'Usuario', type: 'textbox', value: 'demo-user' }, { target: p, name: 'Senha', type: 'textbox', value: 'demo-pass' }] });
        await call('entrar (no iframe)', 'browser_click', { target: b, element: 'botao Entrar do iframe' });
        const f = await call('confirmar', 'browser_find', { text: 'Logado via iframe' });
        R.done(/Logado via iframe/.test(f));
      }
    } catch (e) { R.note('EXCECAO ' + e.message); R.done(false); }
    c.close(); await sleep(1200);
  }
}

// ---------------- agent-browser CLI
function abRun(session, extra, args) {
  const t0 = Date.now(); let out;
  try { out = execFileSync(AB, ['--session', session, '--cdp', String(CDP), ...extra, ...args], { env, cwd: S + '/work', timeout: 60000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch (e) { out = (e.stdout || '') + (e.stderr || '') + `\n[exit ${e.status}]`; }
  return { out, ms: Date.now() - t0 };
}
async function abFlows() {
  for (const [flow, pin] of [['redirect', false], ['popup', false], ['popup', true], ['iframe', false]]) {
    await resetBrowser();
    const sess = `fed-${flow}-${pin ? 'pin' : 'free'}-${Date.now() % 100000}`, extra = pin ? ['--pin-tab'] : [];
    const R = new Rec('ab' + (pin ? '+pin' : ''), flow);
    const sh = (label, ...args) => { const { out, ms } = abRun(sess, extra, args); R.add(`${label}: ab ${args.join(' ').slice(0, 130)}`, out, ms); return out; };
    try {
      let s = sh('abrir RP + snapshot -i', 'batch', `open ${RP}/`, 'snapshot -i');
      if (flow === 'redirect') {
        const link = findRef(s, 'link', /Entrar com IdP-Teste$/); if (!link) { R.note('link nao achado'); R.done(false); abRun(sess, extra, ['close']); continue; }
        s = sh('clicar + esperar IdP + snapshot -i', 'batch', `click @${link}`, 'wait --url **/authorize*', 'snapshot -i');
        const u = findRef(s, 'textbox', /Usu/), p = findRef(s, 'textbox', /Senha/), b = findRef(s, 'button', /^Entrar$/);
        if (!u || !p || !b) { R.note(`refs no IdP: u=${u} p=${p} b=${b}`); R.done(false); abRun(sess, extra, ['close']); continue; }
        const f = sh('preencher, entrar, esperar, confirmar', 'batch', '--bail', `fill @${u} "demo-user"`, `fill @${p} "demo-pass"`, `click @${b}`, 'wait --url **/home', 'get text body');
        R.done(/Olá, demo-user/.test(f));
      } else if (flow === 'popup') {
        const pop = findRef(s, 'button', /popup/); if (!pop) { R.note('botao popup nao achado'); R.done(false); abRun(sess, extra, ['close']); continue; }
        sh('clicar (abre popup)', 'click', `@${pop}`);
        R.note('apos o click o chrome tem: ' + JSON.stringify(await pageTabs()));
        const tl = sh('listar abas', 'tab', 'list');
        const rpm = tl.match(/\[(t\d+)\][^\n]*:47901\//), rpId = rpm ? rpm[1] : 't1'; // id da aba do RP muda por sessao (com --pin-tab t1 e um about:blank)
        const mm = tl.match(/\[(t\d+)\][^\n]*authorize/);
        const idx = mm && mm[1];
        R.note('popup na lista: ' + (!idx ? 'NAO apareceu' : 'id ' + idx) + (/→ \[t\d+\][^\n]*authorize/.test(tl) ? ' (ja e a aba ATIVA, sem trocar)' : ''));
        if (!idx) { R.done(false); abRun(sess, extra, ['close']); continue; }
        const sw = sh('trocar para o popup', 'tab', idx);
        if (/tab_locked|\[exit [1-9]/.test(sw)) { R.note('TROCA DE ABA RECUSADA' + (pin ? ' pelo --pin-tab' : '')); R.done(false); abRun(sess, extra, ['close']); continue; }
        s = sh('snapshot -i do popup', 'snapshot', '-i');
        const u = findRef(s, 'textbox', /Usu/), p = findRef(s, 'textbox', /Senha/), b = findRef(s, 'button', /^Entrar$/);
        if (!u || !p || !b) { R.note(`refs no popup: u=${u} p=${p} b=${b}`); R.done(false); abRun(sess, extra, ['close']); continue; }
        sh('preencher + entrar (o popup se fecha)', 'batch', '--bail', `fill @${u} "demo-user"`, `fill @${p} "demo-pass"`, `click @${b}`);
        await sleep(600);
        R.note('depois do popup fechar o chrome tem: ' + JSON.stringify(await pageTabs()));
        sh('listar abas', 'tab', 'list');
        sh('voltar para a aba do RP', 'tab', rpId);
        const f = sh('confirmar', 'get', 'text', '#status');
        R.done(/Logado via popup/.test(f));
      } else {
        const u = findRef(s, 'textbox', /Usu/), p = findRef(s, 'textbox', /Senha/), b = findRef(s, 'button', /^Entrar$/);
        R.note(`refs no snapshot -i da pagina (iframe incluso?): u=${u} p=${p} b=${b}`);
        if (!u || !p || !b) { R.done(false); abRun(sess, extra, ['close']); continue; }
        const t1 = sh('preencher + entrar no iframe', 'batch', '--bail', `fill @${u} "demo-user"`, `fill @${p} "demo-pass"`, `click @${b}`);
        if (/outside the viewport|\[exit [1-9]/.test(t1)) {
          R.note('click direto no iframe RECUSADO: ' + (t1.match(/✗[^\n]*/) || ['?'])[0].slice(0, 110));
          sh('scrollintoview + click', 'batch', '--bail', `scrollintoview @${b}`, `click @${b}`);
          if (!/Logado via iframe/.test(sh('checar', 'get', 'text', '#status'))) {
            R.note('scrollintoview NAO resolveu; tentando teclado');
            sh('refill senha + press Enter', 'batch', '--bail', `fill @${p} "demo-pass"`, 'press Enter');
          }
        }
        const f = sh('confirmar', 'get', 'text', '#status');
        R.done(/Logado via iframe/.test(f));
      }
    } catch (e) { R.note('EXCECAO ' + e.message); R.done(false); }
    abRun(sess, extra, ['tab', 'close']); abRun(sess, extra, ['close']);
  }
}

(async () => {
  const which = process.argv[2] || 'all';
  if (which === 'all' || which === 'pw') await pwFlows();
  if (which === 'all' || which === 'ab') await abFlows();
  fs.writeFileSync(`${outdir}/idp-summary.json`, JSON.stringify(results, null, 1));
  process.exit(0);
})().catch((e) => { console.error('IDP-ERROR', e); process.exit(1); });
