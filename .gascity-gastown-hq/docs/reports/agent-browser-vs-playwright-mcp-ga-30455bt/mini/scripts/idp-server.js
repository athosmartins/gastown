'use strict';
// IdP de TESTE + relying party, so em loopback (ga-g7zyxc3): a MECANICA do login federado sem conta de ninguem.
// Duas origens (portas diferentes) => redirect, popup (window.open + postMessage) e iframe sao de fato cross-origin.
// Credenciais fixas e falsas: demo-user / demo-pass. Nada aqui fala com a internet.
const http = require('http');
const RP_PORT = Number(process.argv[2] || 47901), IDP_PORT = Number(process.argv[3] || 47902);
const RP = `http://127.0.0.1:${RP_PORT}`, IDP = `http://127.0.0.1:${IDP_PORT}`;
const send = (res, body, code, extra) => { res.writeHead(code || 200, Object.assign({ 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }, extra || {})); res.end(body); };
const redir = (res, to, extra) => { res.writeHead(302, Object.assign({ location: to, 'cache-control': 'no-store' }, extra || {})); res.end(); };
const form = (mode, state, redirectUri, err) => `<!doctype html><html lang="pt"><head><meta charset="utf-8"><title>IdP-Teste: Entrar</title></head><body>
<h1>IdP-Teste</h1>${err ? `<p role="alert">${err}</p>` : ''}
<form method="post" action="/token"><input type="hidden" name="mode" value="${mode}"><input type="hidden" name="state" value="${state}"><input type="hidden" name="redirect_uri" value="${redirectUri}">
<label>Usuário <input name="user" type="text" autocomplete="off"></label>
<label>Senha <input name="pass" type="password" autocomplete="off"></label>
<button type="submit">Entrar</button></form></body></html>`;
const readBody = (req) => new Promise((r) => { let b = ''; req.on('data', (d) => { b += d; }); req.on('end', () => r(Object.fromEntries(new URLSearchParams(b)))); });

http.createServer(async (req, res) => {
  const u = new URL(req.url, IDP), p = u.pathname;
  if (p === '/authorize') return send(res, form(u.searchParams.get('mode') || 'redirect', u.searchParams.get('state') || '', u.searchParams.get('redirect_uri') || ''));
  if (p === '/embedded') return send(res, form('iframe', 'I', ''));
  if (p === '/token' && req.method === 'POST') {
    const f = await readBody(req);
    if (f.user !== 'demo-user' || f.pass !== 'demo-pass') return send(res, form(f.mode, f.state, f.redirect_uri, 'Credenciais inválidas'), 401);
    if (f.mode === 'redirect') return redir(res, `${f.redirect_uri}?code=c123&state=${encodeURIComponent(f.state)}`);
    const target = f.mode === 'popup' ? 'window.opener' : 'window.parent';
    const after = f.mode === 'popup' ? 'window.close();' : '';
    return send(res, `<!doctype html><title>IdP-Teste: ok</title><p>Autenticado, pode fechar.</p><script>${target}.postMessage({code:'c123',user:'demo-user',mode:'${f.mode}'},'${RP}');${after}</script>`);
  }
  send(res, '<!doctype html><title>404</title>', 404);
}).listen(IDP_PORT, '127.0.0.1', () => console.log('idp', IDP_PORT));

http.createServer((req, res) => {
  const u = new URL(req.url, RP), p = u.pathname;
  if (p === '/') return send(res, `<!doctype html><html lang="pt"><head><meta charset="utf-8"><title>RP-Teste</title></head><body>
<h1>RP-Teste</h1><p id="status" role="status">Não logado</p>
<p><a href="/login">Entrar com IdP-Teste</a></p>
<p><button id="pop" type="button">Entrar com IdP-Teste (popup)</button></p>
<h2>Login embutido</h2><iframe id="f" title="Login embutido" src="${IDP}/embedded" width="420" height="260"></iframe>
<script>
document.getElementById('pop').addEventListener('click',function(){window.open('${IDP}/authorize?mode=popup&state=P','idp','width=480,height=520');});
window.addEventListener('message',function(e){if(e.origin!=='${IDP}'||!e.data||!e.data.code)return;document.getElementById('status').textContent='Logado via '+e.data.mode+': '+e.data.user;});
</script></body></html>`);
  if (p === '/login') return redir(res, `${IDP}/authorize?mode=redirect&state=R&redirect_uri=${encodeURIComponent(RP + '/callback')}`);
  if (p === '/callback') return u.searchParams.get('code') === 'c123' ? redir(res, '/home', { 'set-cookie': 'rp_session=ok; Path=/; HttpOnly' }) : send(res, '<!doctype html><title>erro</title><p>code inválido</p>', 400);
  if (p === '/home') return send(res, '<!doctype html><title>RP-Teste: home</title><h1>Olá, demo-user</h1><p>Logado via redirect</p>');
  send(res, '<!doctype html><title>404</title>', 404);
}).listen(RP_PORT, '127.0.0.1', () => console.log('rp', RP_PORT));
