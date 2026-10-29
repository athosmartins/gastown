'use strict';
// Loopback-only static server for the frozen fixtures. Usage: node server.js <port>
const http = require('http');
const fs = require('fs');
const S = process.env.EVAL_S;
const port = Number(process.argv[2]);
const page = (n) => fs.readFileSync(`${S}/fixtures/${n}.html`);
const html = (res, body, code) => { res.writeHead(code || 200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); res.end(body); };

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const p = u.pathname;
  if (p === '/login') return html(res, page('login'));
  if (p === '/session') { res.writeHead(302, { location: '/dashboard' }); return res.end(); }
  if (p === '/dashboard') return html(res, page('dashboard'));
  if (p === '/form') return html(res, page('form'));
  if (p === '/heavy') return html(res, page('heavy'));
  if (p === '/todo') return html(res, page('todo'));
  if (p === '/submit') {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => html(res, `<!doctype html><title>Order received</title><h1>Order received</h1><p>Thank you.</p><pre>${(body || u.search).replace(/[<>&]/g, '')}</pre>`));
    return;
  }
  const m = p.match(/^\/tab\/([A-Za-z0-9_-]+)$/);
  if (m) return html(res, `<!doctype html><title>TAB-${m[1]}</title><h1>TAB ${m[1]}</h1><p>marker-${m[1]}</p><button type="button">Click ${m[1]}</button>`);
  if (p === '/blank') return html(res, '<!doctype html><title>blank</title>');
  html(res, '<!doctype html><title>404</title><h1>404</h1>', 404);
}).listen(port, '127.0.0.1', () => console.log('listening', port));
