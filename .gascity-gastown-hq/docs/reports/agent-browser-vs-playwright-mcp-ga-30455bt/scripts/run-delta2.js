'use strict';
// Does --delta WITHOUT -i see a NON-interactive change (text appended / validation message)? Cost of the baseline vs the deltas.
const { S, AB, scrubbedEnv, measure, fs } = require('./mcpc.js');
const { execFileSync } = require('child_process');
const BASE = 'http://127.0.0.1:47811', CDP = 47222;
const env = scrubbedEnv(S + '/home-ab', { AGENT_BROWSER_SOCKET_DIR: '/tmp/abe' });
const abCmd = (args) => { try { return execFileSync(AB, ['--session', 'dl2', '--cdp', String(CDP), ...args], { env, cwd: S + '/work', timeout: 120000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 << 20 }); } catch (e) { return (e.stdout || '') + (e.stderr || '') + `\n[exit ${e.status}]`; } };
const tok = (t) => measure(t).o200k;
const refOf = (text, role, re) => { for (const l of text.split('\n')) { const m = l.match(/^\s*- (\w+)(?: "((?:[^"\\]|\\.)*)")?/); if (m && m[1] === role && re.test(m[2] || '')) { const r = l.match(/ref=([A-Za-z0-9]+)/); if (r) return r[1]; } } throw new Error('no ref ' + re); };
const res = {};
// heavy only: the todo page REMOVES the clicked button, so repeating one ref is invalid there (todo deltas live in run-micro.js)
for (const [pg, role, re, seenRe] of [['heavy', 'button', /Add note/, /Note \d saved/]]) {
  for (const flags of [['--delta'], ['-c', '--delta']]) {
    const key = `${pg} snapshot ${flags.join(' ')}`;
    abCmd(['open', `${BASE}/${pg}`]);
    const ref = refOf(abCmd(['snapshot', '-i']), role, re);
    const base = abCmd(['snapshot', ...flags]); // first call with this option set = full baseline
    const seq = [];
    for (let i = 0; i < 3; i++) {
      abCmd(['click', '@' + ref]);
      const d = abCmd(['snapshot', ...flags]);
      seq.push({ tok: tok(d), sawNewText: seenRe.test(d), head: d.slice(0, 200).replace(/\s+/g, ' ') });
    }
    res[key] = { baselineTok: tok(base), deltas: seq };
    console.log(key, JSON.stringify({ baselineTok: tok(base), deltas: seq.map((s) => [s.tok, s.sawNewText]) }));
    console.log('   first delta head:', seq[0].head);
  }
}
abCmd(['close']);
fs.writeFileSync(`${S}/out/${process.env.RUN_TAG || 'v2'}/delta2.json`, JSON.stringify(res, null, 1));
process.exit(0);
