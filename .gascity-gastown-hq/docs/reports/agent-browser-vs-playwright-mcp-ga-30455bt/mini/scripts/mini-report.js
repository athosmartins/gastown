'use strict';
// Agrega as rodadas r1..rN do mini (run-task.js macOS): mediana de tokens/latencia/footprint + o mesmo modelo de custo (ITE) do report.js.
// K = 1,44 vem da calibracao do no Hetzner (3 amostras); NAO foi recalibrado no mini (a razao entre formatos varia ~4%, o absoluto escala por K).
const fs = require('fs');
const S = process.env.EVAL_S;
const ROUNDS = (process.env.ROUNDS || 'r1,r2,r3').split(',');
const K = 1.44;
const cfgs = ['pw-A', 'pw-B', 'pw-B2', 'pw-npx', 'ab-full-A', 'ab-c-A', 'ab-i-A', 'ab-i-B', 'ab-batch'];
const STATIC = { 'pw-A': 3764, 'pw-B': 3764, 'pw-B2': 3764, 'ab-full-A': 8571, 'ab-c-A': 8571, 'ab-i-A': 8571, 'ab-i-B': 8571, 'ab-batch': 8571 };
const PRICE = { read: 0.1, write: 1.25, out: 5 };
const med = (a) => { const s = a.slice().sort((x, y) => x - y); const n = s.length; return n ? (n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2) : NaN; };
const load = (r, c) => { try { return JSON.parse(fs.readFileSync(`${S}/out/${r}/task-${c}.json`, 'utf8')); } catch (e) { return null; } };

function cost(steps, base, withStatic, cfg) {
  let ctx = base + (withStatic ? Math.round(STATIC[cfg] * K) : 0), ite = 0, prevNew = 0;
  for (const s of steps) {
    const out = Math.round(s.callTok * K), res = Math.round(s.respTok * K);
    ite += PRICE.read * ctx + PRICE.write * prevNew + PRICE.out * out;
    prevNew = out + res; ctx += prevNew;
  }
  ite += PRICE.read * ctx + PRICE.write * prevNew;
  return Math.round(ite);
}

const rows = {};
for (const c of cfgs) {
  const runs = ROUNDS.map((r) => load(r, c)).filter(Boolean);
  if (!runs.length) { console.log(`(sem dados: ${c})`); continue; }
  const steps = runs[0].steps; // payload deterministico: os passos da 1a rodada representam o fluxo
  rows[c] = { n: runs.length, calls: runs[0].calls, respTok: med(runs.map((r) => r.respTok)), respTokMin: Math.min(...runs.map((r) => r.respTok)), respTokMax: Math.max(...runs.map((r) => r.respTok)),
    msTot: runs.map((r) => r.steps.reduce((a, s) => a + (s.ms || 0), 0)), steps, runs };
}
const ref30 = cost(rows['pw-A'].steps, 30000, true, 'pw-A'), ref200 = cost(rows['pw-A'].steps, 200000, true, 'pw-A');
console.log(`rodadas: ${ROUNDS.join(',')} | K=${K} (calibracao do no)\n`);
console.log('| fluxo | n | chamadas | resultado (o200k, mediana [min-max]) | ITE B=30k (+estatico) | vs pw-A | ITE B=200k (+estatico) | vs pw-A | latencia do fluxo (s, mediana [min-max]) |');
console.log('|---|---|---|---|---|---|---|---|---|');
for (const c of cfgs) {
  const r = rows[c]; if (!r || !STATIC[c]) continue;
  const a = cost(r.steps, 30000, true, c), b = cost(r.steps, 200000, true, c);
  console.log(`| ${c} | ${r.n} | ${r.calls} | ${r.respTok} [${r.respTokMin}-${r.respTokMax}] | ${a} | ${(100 * a / ref30).toFixed(0)}% | ${b} | ${(100 * b / ref200).toFixed(0)}% | ${(med(r.msTot) / 1000).toFixed(1)} [${(Math.min(...r.msTot) / 1000).toFixed(1)}-${(Math.max(...r.msTot) / 1000).toFixed(1)}] |`);
}
console.log('\nLatencia por chamada (ms, mediana entre rodadas), passo a passo:');
for (const c of cfgs) {
  const r = rows[c]; if (!r) continue;
  const per = r.steps.map((s, i) => Math.round(med(r.runs.map((x) => (x.steps[i] || {}).ms).filter((v) => v !== undefined))));
  console.log(`  ${c.padEnd(10)} ${r.steps.map((s, i) => `${s.step}=${per[i]}`).join('  ')}`);
}
console.log('\nMemoria no macOS: footprint (phys_footprint) x RSS do ps, MB, mediana entre rodadas');
const memKeys = ['afterInit', 'afterFirstSnapshot', 'afterTask'];
for (const c of cfgs) {
  const r = rows[c]; if (!r) continue;
  const parts = [];
  for (const k of memKeys) {
    const vs = r.runs.map((x) => x.mem && x.mem[k]).filter(Boolean);
    if (vs.length) parts.push(`${k}: footprint ${med(vs.map((v) => v.fpMB)).toFixed(1)} MB (rss ${(med(vs.map((v) => v.rssKB)) / 1024).toFixed(1)} MB, ${vs[0].procs} proc)`);
  }
  console.log(`  ${c.padEnd(10)} ${parts.join(' | ') || '-'}`);
}
