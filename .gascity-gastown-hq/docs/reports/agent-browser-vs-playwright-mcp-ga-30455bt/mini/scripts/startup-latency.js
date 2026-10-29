'use strict';
// Tempo de spawn -> resposta do `initialize` do MCP, com o npx REAL do mini (cache real ~/.npm/_npx), para @latest x versao fixa.
const { McpClient } = require('./mcpc.js');
const spec = process.argv[2], n = Number(process.argv[3] || 3);
(async () => {
  const out = [];
  for (let i = 0; i < n; i++) {
    const t0 = Date.now();
    const c = new McpClient('/opt/homebrew/bin/npx', [spec, '--cdp-endpoint', 'http://127.0.0.1:47222'], { env: Object.assign({}, process.env), cwd: process.env.EVAL_S + '/work' });
    try { await c.init(); out.push(Date.now() - t0); } catch (e) { out.push('ERR:' + e.message); }
    c.close(); await new Promise((r) => setTimeout(r, 2500));
  }
  console.log(JSON.stringify({ spec, ms: out }));
  process.exit(0);
})();
