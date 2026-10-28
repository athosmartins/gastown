'use strict';
// Static cost per stack: size of tools/list (what sits in the model context while the server is loaded).
const { S, AB, PWMCP, McpClient, scrubbedEnv, measure, fs } = require('./mcpc.js');

async function probe(label, cmd, args, env) {
  const c = new McpClient(cmd, args, { env });
  try {
    const info = await c.init();
    const tools = await c.listTools();
    // The model sees name + description + input schema per tool.
    const model = tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.inputSchema }));
    const json = JSON.stringify(model);
    const m = measure(json);
    fs.writeFileSync(`${S}/out/tools-${label}.json`, JSON.stringify(model, null, 1));
    console.log(JSON.stringify({ label, server: info.serverInfo, protocol: info.protocolVersion, tools: tools.length, bytes: m.bytes, o200k: m.o200k, cl100k: m.cl100k, names: tools.map((t) => t.name).join(',') }));
  } catch (e) {
    console.log(JSON.stringify({ label, error: String(e.message), stderr: c.stderr.slice(0, 400) }));
  } finally { c.close(); }
}

(async () => {
  const home = S + '/home-ab';
  const env = scrubbedEnv(home);
  await probe('pw-mcp-default', process.execPath, [PWMCP, '--cdp-endpoint', 'http://127.0.0.1:1'], env);
  await probe('ab-mcp-core', AB, ['mcp'], env);
  await probe('ab-mcp-all', AB, ['mcp', '--tools', 'all'], env);
  process.exit(0);
})();
