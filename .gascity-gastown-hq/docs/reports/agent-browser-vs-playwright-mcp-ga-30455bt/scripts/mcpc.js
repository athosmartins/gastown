'use strict';
// Minimal MCP stdio client (newline-delimited JSON-RPC) + helpers shared by the eval scripts.
// Third-party processes always get a scrubbed env: no session secrets reach them.
const { spawn } = require('child_process');
const fs = require('fs');

const S = process.env.EVAL_S;
const NODE_BIN = process.env.HOME + '/.local/node/bin';
const AB = S + '/bin-ab/agent-browser';
const PWMCP = S + '/pw-mcp/node_modules/@playwright/mcp/cli.js';
const TOK = require(S + '/tok/node_modules/gpt-tokenizer/cjs/encoding/o200k_base.js');
const TOK_CL = require(S + '/tok/node_modules/gpt-tokenizer/cjs/encoding/cl100k_base.js');

function scrubbedEnv(home, extra) {
  return Object.assign({ HOME: home, PATH: '/usr/bin:/bin:' + NODE_BIN, LANG: 'C.UTF-8' }, extra || {});
}

class McpClient {
  constructor(cmd, args, opts) {
    opts = opts || {};
    this.p = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'], env: opts.env, cwd: opts.cwd || S + '/work' });
    this.pid = this.p.pid;
    this.buf = '';
    this.id = 0;
    this.pending = new Map();
    this.stderr = '';
    this.exited = null;
    this.p.on('exit', (c, s) => { this.exited = { code: c, signal: s }; });
    this.p.stdout.on('data', (d) => {
      this.buf += d;
      let i;
      while ((i = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, i);
        this.buf = this.buf.slice(i + 1);
        if (!line.trim()) continue;
        let m;
        try { m = JSON.parse(line); } catch (e) { continue; }
        if (m.id !== undefined && this.pending.has(m.id)) {
          const { res, rej } = this.pending.get(m.id);
          this.pending.delete(m.id);
          if (m.error) rej(Object.assign(new Error(m.error.message), { rpc: m.error })); else res(m.result);
        }
      }
    });
    this.p.stderr.on('data', (d) => { this.stderr += d; });
  }
  request(method, params, timeoutMs) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      const t = setTimeout(() => { this.pending.delete(id); rej(new Error('timeout ' + method)); }, timeoutMs || 90000);
      this.pending.set(id, { res: (v) => { clearTimeout(t); res(v); }, rej: (e) => { clearTimeout(t); rej(e); } });
      this.p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  notify(method, params) { this.p.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n'); }
  async init() {
    const r = await this.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'ab-eval', version: '0' } });
    this.notify('notifications/initialized');
    return r;
  }
  async listTools() {
    let tools = [], cursor;
    do {
      const r = await this.request('tools/list', cursor ? { cursor } : {});
      tools = tools.concat(r.tools);
      cursor = r.nextCursor;
    } while (cursor);
    return tools;
  }
  call(name, args) { return this.request('tools/call', { name, arguments: args || {} }, 120000); }
  close() {
    try { this.p.stdin.end(); } catch (e) { /* already closed */ }
    const p = this.p;
    setTimeout(() => { try { if (this.exited === null) p.kill('SIGTERM'); } catch (e) { /* gone */ } }, 1500);
  }
}

// Text a model would receive from a tool result: every text item, image items counted apart.
function resultText(r) {
  let text = '', imgBytes = 0, items = 0;
  for (const c of (r && r.content) || []) {
    items++;
    if (c.type === 'text') text += c.text + '\n';
    else if (c.data) imgBytes += c.data.length;
  }
  return { text, imgBytes, items, isError: !!(r && r.isError) };
}

function measure(text) {
  return {
    bytes: Buffer.byteLength(text, 'utf8'),
    lines: text ? text.split('\n').length : 0,
    o200k: TOK.encode(text).length,
    cl100k: TOK_CL.encode(text).length,
  };
}

module.exports = { S, AB, PWMCP, McpClient, scrubbedEnv, resultText, measure, fs, NODE_BIN };
