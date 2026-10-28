'use strict';
// Aggregate: tokens per task (o200k and calibrated real-Claude), static overhead, cost model with context re-read, RAM.
const fs = require('fs');
const S = process.env.EVAL_S;
const D = `${S}/out/v2`;
const cal = JSON.parse(fs.readFileSync(`${D}/calibration.json`, 'utf8'));
const K = +(cal.out.reduce((a, r) => a + r.real_over_o200k, 0) / cal.out.length).toFixed(3); // real Claude tokens per o200k token
console.log(`calibration: real/o200k per sample = ${cal.out.map((r) => r.real_over_o200k).join(' / ')}  -> K=${K}`);

const cfgs = ['pw-A', 'pw-B', 'pw-B2', 'ab-full-A', 'ab-c-A', 'ab-i-A', 'ab-i-B', 'ab-batch'];
const T = Object.fromEntries(cfgs.map((c) => [c, JSON.parse(fs.readFileSync(`${D}/task-${c}.json`, 'utf8'))]));
// static overhead that sits in context for the stack (o200k): PW tools/list 3764, AB-CLI core skill 8571, AB-MCP core 16851
const STATIC = { 'pw-A': 3764, 'pw-B': 3764, 'pw-B2': 3764, 'ab-full-A': 8571, 'ab-c-A': 8571, 'ab-i-A': 8571, 'ab-i-B': 8571, 'ab-batch': 8571 };
const PRICE = { read: 0.1, write: 1.25, out: 5 }; // relative to fresh input = 1 (prompt-caching multipliers; output ~5x)

function cost(c, base, includeStatic) {
  const steps = T[c].steps;
  let ctx = base + (includeStatic ? Math.round(STATIC[c] * K) : 0), ite = 0, added = 0, prevNew = 0;
  for (const s of steps) {
    const out = Math.round(s.callTok * K), res = Math.round(s.respTok * K);
    ite += PRICE.read * ctx + PRICE.write * prevNew + PRICE.out * out; // turn: read context, write what the last turn added, emit call
    prevNew = out + res; ctx += prevNew; added += prevNew;
  }
  ite += PRICE.read * ctx + PRICE.write * prevNew; // closing turn reads everything, writes the last result
  return { ite: Math.round(ite), added };
}

console.log('\n| config | calls | tool results (o200k) | calls (o200k) | context added (real) | ITE B=30k | ITE B=30k +static | vs pw-A | ITE B=200k +static | vs pw-A |');
console.log('|---|---|---|---|---|---|---|---|---|---|');
const ref30 = cost('pw-A', 30000, true).ite, ref200 = cost('pw-A', 200000, true).ite;
for (const c of cfgs) {
  const t = T[c], a = cost(c, 30000, false), b = cost(c, 30000, true), d = cost(c, 200000, true);
  console.log(`| ${c} | ${t.calls} | ${t.respTok} | ${t.callTok} | ${a.added} | ${a.ite} | ${b.ite} | ${(100 * b.ite / ref30).toFixed(0)}% | ${d.ite} | ${(100 * d.ite / ref200).toFixed(0)}% |`);
}
console.log('\nsnapshot size per page (o200k)  [real Claude ~ x' + K + ']');
const micro = JSON.parse(fs.readFileSync(`${D}/micro.json`, 'utf8'));
const cols = ['pw snapshot', 'pw snapshot depth=3', 'pw find controls', 'ab snapshot', 'ab -i', 'ab -c', 'ab -d 3'];
console.log('| page | ' + cols.join(' | ') + ' |'); console.log('|' + '---|'.repeat(cols.length + 1));
for (const [p, r] of Object.entries(micro.pages)) console.log(`| ${p} | ${cols.map((k) => r[k]).join(' | ')} |`);
console.log('| reduction ab -i vs pw snapshot | ' + Object.entries(micro.pages).map(([p, r]) => `${p} ${(100 * (1 - r['ab -i'] / r['pw snapshot'])).toFixed(0)}%`).join(', ') + ' |');

console.log('\nRAM (Linux, KB) -- the shared Chromium is excluded (same for both)');
const m = (c, k) => { const v = T[c] && T[c].mem[k]; return v ? `rss=${(v.rssKB / 1024).toFixed(0)}MB pss=${(v.pssKB / 1024).toFixed(0)}MB procs=${v.procs}` : '-'; };
for (const c of ['pw-A', 'pw-B']) console.log(`${c}: init ${m(c, 'afterInit')} | after 1st snapshot ${m(c, 'afterFirstSnapshot')} | after task ${m(c, 'afterTask')}`);
try { const n = JSON.parse(fs.readFileSync(`${D}/task-pw-npx.json`, 'utf8')); const f = (k) => { const v = n.mem[k]; return `rss=${(v.rssKB / 1024).toFixed(0)}MB pss=${(v.pssKB / 1024).toFixed(0)}MB procs=${v.procs}`; }; console.log(`pw via npx: init ${f('afterInit')} | after 1st snapshot ${f('afterFirstSnapshot')}`); console.log('   rows:', n.mem.afterFirstSnapshot.rows.map((r) => `${r.pid}:${(r.rss / 1024).toFixed(0)}MB ${r.cmd.slice(0, 50)}`).join(' ; ')); } catch (e) { console.log('pw-npx missing'); }
for (const c of ['ab-i-B', 'ab-i-A', 'ab-full-A']) console.log(`${c} (daemon): after 1st snapshot ${m(c, 'afterFirstSnapshot')} | after task ${m(c, 'afterTask')}`);
