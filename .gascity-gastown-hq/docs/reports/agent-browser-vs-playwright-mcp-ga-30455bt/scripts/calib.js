'use strict';
// Real Claude token cost of three tool results = growth of the request context between consecutive assistant
// messages (usage.input + cache_creation + cache_read), minus the same growth for a trivial `echo` call.
const fs = require('fs');
const S = process.env.EVAL_S;
const T = process.env.TRANSCRIPT;
const O200 = require(S + '/tok/node_modules/gpt-tokenizer/cjs/encoding/o200k_base.js');
const CL100 = require(S + '/tok/node_modules/gpt-tokenizer/cjs/encoding/cl100k_base.js');

const rows = fs.readFileSync(T, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const order = [], byId = new Map();
for (const r of rows) {
  if (r.type !== 'assistant') continue;
  const m = r.message;
  if (!byId.has(m.id)) { byId.set(m.id, { id: m.id, usage: m.usage, cmds: [] }); order.push(m.id); }
  const e = byId.get(m.id); e.usage = m.usage;
  for (const c of m.content || []) if (c.type === 'tool_use' && c.name === 'Bash') e.cmds.push(c.input.command);
}
const msgs = order.map((id) => byId.get(id));
const tot = (u) => u.input_tokens + u.cache_creation_input_tokens + u.cache_read_input_tokens;
const find = (key) => { let hit = -1; msgs.forEach((m, i) => { if (m.cmds.some((c) => c.includes(key))) hit = i; }); return hit; };
const delta = (key) => { const i = find(key); if (i < 0 || i + 1 >= msgs.length) return null; return tot(msgs[i + 1].usage) - tot(msgs[i].usage); };

const base = ['echo base0', 'echo base1', 'echo base2', 'echo base3'].map(delta);
console.log('baseline deltas (tool_use + tiny result + framing):', JSON.stringify(base));
const samples = [
  { name: 'PW YAML snapshot (HN, first 24000 B)', key: 'pw-A/06-snap-dash', file: `${S}/out/v2/pw-A/06-snap-dash.txt`, head: 24000, before: 0, after: 1 },
  { name: 'AB snapshot -i (HN, whole file)', key: 'ab-i-A/07-snap-dash', file: `${S}/out/v2/ab-i-A/07-snap-dash.txt`, head: null, before: 1, after: 2 },
  { name: 'AB full snapshot (HN, first 24000 B)', key: 'ab-full-A/07-snap-dash', file: `${S}/out/v2/ab-full-A/07-snap-dash.txt`, head: 24000, before: 2, after: 3 },
];
const out = [];
for (const s of samples) {
  let buf = fs.readFileSync(s.file);
  if (s.head) buf = buf.subarray(0, s.head);
  const text = buf.toString('utf8');
  const d = delta(s.key);
  // base0 is contaminated (long reasoning block kept in context right before it): the floor is the mean of the 3 clean bases
  const floor = (base[1] + base[2] + base[3]) / 3;
  const real = d - floor;
  const o = O200.encode(text).length, c = CL100.encode(text).length;
  const row = { sample: s.name, bytes: buf.length, delta: d, baselineFloor: floor, realClaudeTok: real, o200k: o, cl100k: c, real_over_o200k: +(real / o).toFixed(3), real_over_cl100k: +(real / c).toFixed(3), bytesPerRealTok: +(buf.length / real).toFixed(2) };
  out.push(row);
  console.log(JSON.stringify(row));
}
fs.writeFileSync(`${S}/out/v2/calibration.json`, JSON.stringify({ base, out }, null, 1));
