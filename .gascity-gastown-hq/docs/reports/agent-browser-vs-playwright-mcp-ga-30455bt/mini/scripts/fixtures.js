'use strict';
// Freeze a few public pages (scripts stripped, stylesheets inlined) so both stacks see the SAME real-world DOM
// and the browser never needs the network. Own widgets are injected only into pages we serve locally.
const fs = require('fs');
const S = process.env.EVAL_S;
const UA = 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 gascity-eval/1.0';

async function get(url) {
  const r = await fetch(url, { headers: { 'user-agent': UA, accept: 'text/html,text/css,*/*' }, redirect: 'follow' });
  if (!r.ok) throw new Error(url + ' -> ' + r.status);
  return { text: await r.text(), url: r.url };
}

async function freeze(name, url, rewrite) {
  const { text: html, url: finalUrl } = await get(url);
  let out = html, inlined = 0, dropped = 0, budget = 1500000;
  for (const m of [...out.matchAll(/<link\b[^>]*rel=["']?stylesheet["']?[^>]*>/gi)]) {
    const href = (m[0].match(/href=["']([^"']+)["']/i) || [])[1];
    let css = null;
    if (href) {
      try { css = (await get(new URL(href.replace(/&amp;/g, '&'), finalUrl).href)).text; } catch (e) { css = null; }
    }
    if (css !== null && css.length < budget) {
      budget -= css.length; inlined++;
      out = out.replace(m[0], () => '<style>' + css.replace(/<\/style/gi, '') + '</style>');
    } else { dropped++; out = out.replace(m[0], ''); }
  }
  out = out.replace(/<script\b[\s\S]*?<\/script>/gi, '')
    .replace(/<link\b[^>]*rel=["']?(preload|prefetch|modulepreload|dns-prefetch|preconnect)["']?[^>]*>/gi, '');
  if (rewrite) out = rewrite(out);
  fs.writeFileSync(`${S}/fixtures/${name}.html`, out);
  return { name, src: url, bytes: Buffer.byteLength(out), cssInlined: inlined, cssDropped: dropped };
}

const widget = `<div id="eval-widget"><button id="addnote" type="button">Add note</button><ul id="notes" aria-live="polite"></ul></div>
<script>(function(){var n=0;document.getElementById('addnote').addEventListener('click',function(){n++;var li=document.createElement('li');li.textContent='Note '+n+' saved';document.getElementById('notes').appendChild(li);});})();</script>`;

(async () => {
  fs.mkdirSync(`${S}/fixtures`, { recursive: true });
  const res = [];
  res.push(await freeze('login', 'https://github.com/login', (h) => h.replace(/(<form\b[^>]*action=")[^"]*(")/i, '$1/session$2')));
  res.push(await freeze('dashboard', 'https://news.ycombinator.com/'));
  res.push(await freeze('form', 'https://httpbin.org/forms/post', (h) => h.replace(/action="[^"]*"/i, 'action="/submit"')));
  res.push(await freeze('heavy', 'https://en.wikipedia.org/wiki/Web_browser', (h) => h.replace(/(<body\b[^>]*>)/i, '$1' + widget)));
  // Own medium page: 40 rows, a click changes ONE row (the classic "small change on a medium page" case).
  let rows = '';
  for (let i = 1; i <= 40; i++) rows += `<li id="r${i}"><span class="t">Task ${i}: review item ${i}</span> <button type="button" data-i="${i}">Mark done</button></li>\n`;
  fs.writeFileSync(`${S}/fixtures/todo.html`, `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Todo list</title></head><body><h1>Todo</h1><nav><a href="/login">Login</a> <a href="/form">Form</a> <a href="/heavy">Heavy</a></nav><ul>${rows}</ul><script>document.addEventListener('click',function(e){var b=e.target.closest('button[data-i]');if(!b)return;var li=document.getElementById('r'+b.dataset.i);li.querySelector('.t').textContent='DONE: '+li.querySelector('.t').textContent;b.remove();});</script></body></html>`);
  res.push({ name: 'todo', src: 'own', bytes: fs.statSync(`${S}/fixtures/todo.html`).size });
  for (const r of res) console.log(JSON.stringify(r));
})().catch((e) => { console.error('FIXTURE-ERROR', e.message); process.exit(1); });
