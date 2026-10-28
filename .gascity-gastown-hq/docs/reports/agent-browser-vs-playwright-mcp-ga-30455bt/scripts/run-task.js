'use strict';
// Canonical task "login + 1 formulario" on the shared Chromium, same 11 steps on every stack.
// Usage: node run-task.js <config>    configs: pw-A pw-B pw-npx ab-full-A ab-i-A ab-c-A ab-i-B ab-delta-A
//   policy A = re-snapshot at every observation point (nav login, after sign-in, nav form, after submit)
//   policy B = snapshot only where refs are needed; verification by the cheap signal (URL/title)
const { S, AB, PWMCP, McpClient, scrubbedEnv, resultText, measure, fs, NODE_BIN } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const http = require('http');

const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const config = process.argv[2];
const TAG = process.env.RUN_TAG || 'v2'; // one output tree per round, nothing is ever deleted
const outdir = `${S}/out/${TAG}/${config}`;
fs.mkdirSync(outdir, { recursive: true });
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe', npm_config_cache: S + '/npm-cache' });

// ---------- helpers
function findRef(text, role, nameRe) {
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*- (\w+)(?: "((?:[^"\\]|\\.)*)")?/);
    if (!m || m[1] !== role || !nameRe.test(m[2] || '')) continue;
    const r = line.match(/ref=([A-Za-z0-9]+)/);
    if (r) return r[1];
  }
  throw new Error(`no ref for ${role} ${nameRe}`);
}
function cdpHttp(method, path) {
  return new Promise((res, rej) => {
    const rq = http.request({ host: '127.0.0.1', port: CDP, path, method }, (r) => { let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => res(b)); });
    rq.on('error', rej); rq.end();
  });
}
async function resetBrowser() { // leave exactly one about:blank tab, like the managed Chromes on the mini
  const first = JSON.parse(await cdpHttp('PUT', '/json/new?about:blank'));
  for (const t of JSON.parse(await cdpHttp('GET', '/json/list'))) if (t.id !== first.id) await cdpHttp('GET', '/json/close/' + t.id);
}
const pids = () => fs.readdirSync('/proc').filter((x) => /^\d+$/.test(x));
function kv(file) { try { const o = {}; for (const l of fs.readFileSync(file, 'utf8').split('\n')) { const m = l.match(/^(\w+):\s+(\d+) kB/); if (m) o[m[1]] = +m[2]; } return o; } catch (e) { return null; } }
function procMem(pid) {
  const st = kv(`/proc/${pid}/status`), sm = kv(`/proc/${pid}/smaps_rollup`);
  if (!st) return null;
  let cmd = ''; try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').join(' ').slice(0, 90); } catch (e) { /* gone */ }
  return { pid, cmd, rss: st.VmRSS, hwm: st.VmHWM, pss: sm && sm.Pss, priv: sm && (sm.Private_Dirty + sm.Private_Clean) };
}
function descendants(root) {
  const ppid = {};
  for (const p of pids()) { try { const m = fs.readFileSync(`/proc/${p}/stat`, 'utf8').match(/^\d+ \(.*\) \S (\d+)/); if (m) ppid[p] = m[1]; } catch (e) { /* gone */ } }
  const out = [], st = [String(root)];
  while (st.length) { const c = st.pop(); out.push(c); for (const p in ppid) if (ppid[p] === c) st.push(p); }
  return out;
}
const abPids = () => pids().filter((p) => { try { return fs.readlinkSync(`/proc/${p}/exe`) === AB; } catch (e) { return false; } });
function sumMem(list) {
  const rows = list.map(procMem).filter(Boolean);
  const s = (k) => rows.reduce((a, r) => a + (r[k] || 0), 0);
  return { procs: rows.length, rssKB: s('rss'), pssKB: s('pss'), privKB: s('priv'), hwmKB: s('hwm'), rows };
}

class Run {
  constructor() { this.steps = []; this.mem = {}; }
  rec(step, name, input, text) {
    const m = measure(text), c = measure(JSON.stringify({ name, input }));
    this.steps.push({ n: this.steps.length + 1, step, tool: name, callTok: c.o200k, respBytes: m.bytes, respTok: m.o200k, respTokCl: m.cl100k });
    fs.writeFileSync(`${outdir}/${String(this.steps.length).padStart(2, '0')}-${step}.txt`, text);
  }
}

// ---------- Playwright MCP driver
async function runPW(policy, viaNpx) {
  const args = ['--cdp-endpoint', 'http://127.0.0.1:' + CDP];
  const c = viaNpx
    ? new McpClient(NODE_BIN + '/npx', ['--no-install', 'playwright-mcp', ...args], { env, cwd: S + '/pw-mcp' })
    : new McpClient(process.execPath, [PWMCP, ...args], { env });
  const run = new Run();
  await c.init();
  run.mem.afterInit = sumMem(descendants(c.pid));
  let snapText = '';
  const call = async (step, name, input) => {
    const r = resultText(await c.call(name, input));
    run.rec(step, name, input, r.text);
    if (r.isError) throw new Error(`${step}: ${r.text.slice(0, 300)}`);
    return r.text;
  };
  const snap = async (step) => { snapText = await call(step, 'browser_snapshot', {}); return snapText; };
  await call('nav-login', 'browser_navigate', { url: BASE + '/login' });
  await snap('snap-login');
  run.mem.afterFirstSnapshot = sumMem(descendants(c.pid));
  if (viaNpx) { c.close(); return finish(run, c, 'pw-npx'); }
  if (policy === 'B2') { // fewest turns: both login fields in ONE fill_form call
    await call('fill-login', 'browser_fill_form', { fields: [
      { target: findRef(snapText, 'textbox', /Username or email/i), name: 'Username', type: 'textbox', value: 'demo-user' },
      { target: findRef(snapText, 'textbox', /^Password/i), name: 'Password', type: 'textbox', value: 'demo-pass' }] });
  } else {
    await call('fill-user', 'browser_type', { target: findRef(snapText, 'textbox', /Username or email/i), text: 'demo-user' });
    await call('fill-pass', 'browser_type', { target: findRef(snapText, 'textbox', /^Password/i), text: 'demo-pass' });
  }
  const t = await call('click-signin', 'browser_click', { target: findRef(snapText, 'button', /^Sign in$/i), element: 'Sign in button' });
  if (!/\/dashboard/.test(t)) throw new Error('sign-in did not land on /dashboard: ' + t.slice(0, 200));
  if (policy === 'A') await snap('snap-dash');
  await call('nav-form', 'browser_navigate', { url: BASE + '/form' });
  await snap('snap-form');
  const R = (role, re) => findRef(snapText, role, re);
  await call('fill-form', 'browser_fill_form', { fields: [
    { target: R('textbox', /Customer name/i), name: 'Customer name', type: 'textbox', value: 'Ana Silva' },
    { target: R('textbox', /Telephone/i), name: 'Telephone', type: 'textbox', value: '555-0100' },
    { target: R('textbox', /E-mail/i), name: 'E-mail', type: 'textbox', value: 'ana@example.invalid' },
    { target: R('radio', /Medium/i), name: 'Size medium', type: 'radio', value: 'true' },
    { target: R('checkbox', /Cheese/i), name: 'Extra cheese', type: 'checkbox', value: 'true' }] });
  const d = await call('click-submit', 'browser_click', { target: R('button', /Submit order/i), element: 'Submit order button' });
  if (!/Order received/.test(d)) throw new Error('submit did not land on thanks page: ' + d.slice(0, 200));
  if (policy === 'A') await snap('snap-done');
  run.mem.afterTask = sumMem(descendants(c.pid));
  c.close();
  return finish(run, c, 'pw-' + policy);
}

// ---------- agent-browser CLI driver
function abCmd(args) {
  try { return execFileSync(AB, ['--session', 'tsk', '--cdp', String(CDP), ...args], { env, cwd: S + '/work', timeout: 90000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); }
  catch (e) { return (e.stdout || '') + (e.stderr || '') + `\n[exit ${e.status}]`; }
}
async function runAB(snapArgs, policy, label) {
  const run = new Run();
  let snapText = '', first = true;
  const q = (a) => (/[\s"]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a);
  const sh = (step, args) => {
    const shown = (first ? ['--cdp', String(CDP)] : []).concat(args); first = false; // the model passes --cdp once, the session then stays attached
    const t = abCmd(args);
    run.rec(step, 'Bash', { command: 'agent-browser ' + shown.map(q).join(' ') }, t);
    if (/\[exit [1-9]/.test(t) || /^✗/m.test(t)) throw new Error(`${step}: ${t.slice(0, 300)}`);
    return t;
  };
  const snap = (step) => { snapText = sh(step, snapArgs); };
  sh('nav-login', ['open', BASE + '/login']);
  snap('snap-login');
  run.mem.afterFirstSnapshot = sumMem(abPids());
  sh('fill-user', ['fill', '@' + findRef(snapText, 'textbox', /Username or email/i), 'demo-user']);
  sh('fill-pass', ['fill', '@' + findRef(snapText, 'textbox', /^Password/i), 'demo-pass']);
  sh('click-signin', ['click', '@' + findRef(snapText, 'button', /^Sign in$/i)]);
  sh('wait-dash', ['wait', '--url', '**/dashboard']); // click returns before the navigation ends (Playwright's click waits for it)
  if (policy === 'A') snap('snap-dash');
  else if (!/Hacker News/.test(sh('check-dash', ['get', 'title']))) throw new Error('sign-in did not land on dashboard');
  sh('nav-form', ['open', BASE + '/form']);
  snap('snap-form');
  const R = (role, re) => '@' + findRef(snapText, role, re);
  sh('fill-form', ['batch', `fill ${R('textbox', /Customer name/i)} "Ana Silva"`, `fill ${R('textbox', /Telephone/i)} "555-0100"`,
    `fill ${R('textbox', /E-mail/i)} "ana@example.invalid"`, `click ${R('radio', /Medium/i)}`, `check ${R('checkbox', /Cheese/i)}`]);
  sh('click-submit', ['click', R('button', /Submit order/i)]);
  sh('wait-done', ['wait', '--url', '**/submit']);
  if (policy === 'A') snap('snap-done');
  else if (!/Order received/.test(sh('check-done', ['get', 'title']))) throw new Error('submit did not land on thanks page');
  run.mem.afterTask = sumMem(abPids());
  abCmd(['close']);
  return finish(run, null, label);
}

// agent-browser using its own turn-saving feature: ONE `batch` per phase (open+snapshot / act+wait+verify)
async function runABBatch(label) {
  const run = new Run();
  let first = true;
  const q = (a) => (/[\s"]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a);
  const sh = (step, args) => {
    const shown = (first ? ['--cdp', String(CDP)] : []).concat(args); first = false;
    const t = abCmd(args);
    run.rec(step, 'Bash', { command: 'agent-browser ' + shown.map(q).join(' ') }, t);
    if (/\[exit [1-9]/.test(t) || /^✗/m.test(t)) throw new Error(`${step}: ${t.slice(0, 300)}`);
    return t;
  };
  const s1 = sh('nav-snap-login', ['batch', `open ${BASE}/login`, 'snapshot -i']);
  const U = '@' + findRef(s1, 'textbox', /Username or email/i), P = '@' + findRef(s1, 'textbox', /^Password/i), G = '@' + findRef(s1, 'button', /^Sign in$/i);
  const s2 = sh('login-wait-verify', ['batch', '--bail', `fill ${U} "demo-user"`, `fill ${P} "demo-pass"`, `click ${G}`, 'wait --url **/dashboard', 'get title']);
  if (!/Hacker News/.test(s2)) throw new Error('sign-in did not land on dashboard: ' + s2.slice(0, 200));
  const s3 = sh('nav-snap-form', ['batch', `open ${BASE}/form`, 'snapshot -i']);
  const R = (role, re) => '@' + findRef(s3, role, re);
  const s4 = sh('form-submit-verify', ['batch', '--bail', `fill ${R('textbox', /Customer name/i)} "Ana Silva"`, `fill ${R('textbox', /Telephone/i)} "555-0100"`,
    `fill ${R('textbox', /E-mail/i)} "ana@example.invalid"`, `click ${R('radio', /Medium/i)}`, `check ${R('checkbox', /Cheese/i)}`, `click ${R('button', /Submit order/i)}`, 'wait --url **/submit', 'get title']);
  if (!/Order received/.test(s4)) throw new Error('submit did not land on thanks page: ' + s4.slice(0, 200));
  run.mem.afterTask = sumMem(abPids());
  abCmd(['close']);
  return finish(run, null, label);
}

function finish(run, c, label) {
  const tot = (k) => run.steps.reduce((a, s) => a + s[k], 0);
  const out = { config: label, calls: run.steps.length, respTok: tot('respTok'), respTokCl: tot('respTokCl'), respBytes: tot('respBytes'), callTok: tot('callTok'), steps: run.steps, mem: run.mem };
  fs.writeFileSync(`${S}/out/${TAG}/task-${config}.json`, JSON.stringify(out, null, 1));
  console.log(JSON.stringify({ config: label, calls: out.calls, respTok: out.respTok, respTokCl: out.respTokCl, respBytes: out.respBytes, callTok: out.callTok,
    mem: Object.fromEntries(Object.entries(run.mem).map(([k, v]) => [k, `${v.procs}p rss=${v.rssKB} pss=${v.pssKB} priv=${v.privKB} hwm=${v.hwmKB}`])) }));
}

(async () => {
  await resetBrowser();
  const m = { 'pw-A': () => runPW('A', false), 'pw-B': () => runPW('B', false), 'pw-B2': () => runPW('B2', false), 'pw-npx': () => runPW('B', true),
    'ab-batch': () => runABBatch('ab-batch'),
    'ab-full-A': () => runAB(['snapshot'], 'A', 'ab-full-A'), 'ab-i-A': () => runAB(['snapshot', '-i'], 'A', 'ab-i-A'),
    'ab-c-A': () => runAB(['snapshot', '-c'], 'A', 'ab-c-A'), 'ab-i-B': () => runAB(['snapshot', '-i'], 'B', 'ab-i-B'),
    'ab-delta-A': () => runAB(['snapshot', '-i', '--delta'], 'A', 'ab-delta-A') };
  if (!m[config]) throw new Error('unknown config ' + config);
  await m[config]();
  process.exit(0);
})().catch((e) => { console.error('TASK-ERROR', config, e.message); process.exit(1); });
