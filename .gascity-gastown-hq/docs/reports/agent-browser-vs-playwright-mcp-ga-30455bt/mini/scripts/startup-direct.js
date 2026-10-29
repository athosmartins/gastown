'use strict';
const { McpClient } = require('./mcpc.js');
const cli = process.argv[2], n = Number(process.argv[3] || 3);
(async () => {
  const out = [];
  for (let i = 0; i < n; i++) {
    const t0 = Date.now();
    const c = new McpClient('/opt/homebrew/bin/node', [cli, '--cdp-endpoint', 'http://127.0.0.1:47222'], { env: Object.assign({}, process.env), cwd: process.env.EVAL_S + '/work' });
    try { await c.init(); out.push(Date.now() - t0); } catch (e) { out.push('ERR:' + e.message); }
    c.close(); await new Promise((r) => setTimeout(r, 2000));
  }
  console.log(JSON.stringify({ direct: cli.replace(process.env.EVAL_S, '$EVAL_S'), ms: out }));
  process.exit(0);
})();
