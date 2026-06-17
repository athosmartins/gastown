---
name: browser-control
description: Use when an agent/crew needs to drive a real Chrome over CDP from the mini — either the mini's own Chrome (127.0.0.1:9222) or the MacBook Pro's Chrome via the persistent tunnel (127.0.0.1:9223). Documents both endpoints, ready-to-run playwright-core and puppeteer-core connection snippets, how the modules resolve on the mini, and the security blast radius of the shared ~/.chrome-cdp profiles. Applies to ALL Gas City agents/crews.
---

# browser-control — dirigir Chrome via CDP (mini + MBP) por qualquer agente

A infra de dois browsers reais já existe e é durável. Esta skill é o **padrão
único** de como qualquer agente/crew no mini conecta e dirige os dois — sem
reinventar conexão e sabendo o risco de segurança.

Para **logar/operar sites COMO o Athos** (OAuth "Entrar com Google", checkout,
etc.) use a skill **`federated-site-login`** — ela é a doutrina de _uso_ logado
e guardrails. Esta skill é a camada de _transporte_: como attachar no CDP e em
quais endpoints.

## Os dois endpoints CDP

| Endpoint              | O que é                                    | Serviço (launchd)                      | Perfil           |
|-----------------------|--------------------------------------------|----------------------------------------|------------------|
| `127.0.0.1:9222`      | Chrome do **mini** (local, direto)         | `com.athos.chrome-cdp`                 | `~/.chrome-cdp` (no mini) |
| `127.0.0.1:9223`      | Chrome do **MBP** via túnel SSH persistente | `com.athos.chrome-cdp-tunnel-mbp` → MBP `:9222` | `~/.chrome-cdp` (no MBP)  |

- Ambos são **localhost-only** no mini. O túnel é `ssh -L 127.0.0.1:9223:localhost:9222 athos@athoss-macbook-pro.local`, gerenciado por launchd (`RunAtLoad` + `KeepAlive`, sobrevive a reboot/queda).
- Cada Chrome roda num **perfil dedicado** `~/.chrome-cdp` (na sua respectiva máquina). Perfil dedicado é obrigatório: Chrome ≥136 bloqueia debug no perfil padrão.
- Confirme que estão no ar antes de usar (veja "Saúde" abaixo).

## Resolução dos módulos no mini (pré-requisito)

`playwright-core` e `puppeteer-core` ficam num **store compartilhado** já provido:

```
~/.local/share/cdp-drive/node_modules/{playwright-core,puppeteer-core}
```

Node **não** procura módulos globais por padrão. Para um script de agente
resolver os dois de **qualquer diretório, sem config extra**, prefixe com
`NODE_PATH`:

```bash
NODE_PATH="$HOME/.local/share/cdp-drive/node_modules" node meu-script.js
```

Alternativa: colocar o script dentro de `~/.local/share/cdp-drive/` (o
`require` sobe até o `node_modules/` daquele diretório — é assim que o
`drive.js` da federated-site-login resolve `puppeteer-core`).

Se o store sumir (máquina nova), rode o `install.sh` desta skill — ele garante
os dois pacotes (idempotente, sem baixar binários de browser).

## Conectar — puppeteer-core (universal, recomendado)

Funciona uniformemente nos **dois** endpoints (incl. o túnel do MBP). É o
cliente que o `drive.js` da federated-site-login já usa.

```js
// NODE_PATH=~/.local/share/cdp-drive/node_modules node este.js
const puppeteer = require('puppeteer-core');

const ENDPOINT = process.env.CDP_ENDPOINT || 'http://127.0.0.1:9222'; // mini
// ...ou 'http://127.0.0.1:9223' para o Chrome do MBP

const browser = await puppeteer.connect({ browserURL: ENDPOINT, defaultViewport: null });
const page = await browser.newPage();
await page.goto('https://example.com', { waitUntil: 'domcontentloaded' });
console.log(await page.title());
await page.close();
await browser.disconnect();   // disconnect NÃO mata o Chrome (é gerenciado por launchd)
```

## Conectar — playwright-core

```js
// NODE_PATH=~/.local/share/cdp-drive/node_modules node este.js
const { chromium } = require('playwright-core');

const ENDPOINT = process.env.CDP_ENDPOINT || 'http://127.0.0.1:9222'; // ou :9223
const browser = await chromium.connectOverCDP(ENDPOINT);
const context = browser.contexts()[0] || await browser.newContext();
const page = context.pages()[0] || await context.newPage();
await page.goto('https://example.com');
console.log(await page.title());
await browser.close();        // fecha só a conexão CDP; o Chrome segue vivo
```

**Caveat playwright + endpoint sem abas:** `chromium.connectOverCDP` exige
**≥1 page target** no browser. Os Chromes gerenciados sobem sempre com uma aba,
então na prática funciona; mas se **todas as abas foram fechadas** (0 targets),
o connect falha com `Browser context management is not supported`. Garanta uma
aba antes (`cdp open about:blank`, ou abra via puppeteer) — ou use puppeteer,
que não tem esse requisito. (Verificado: mini=ok; MBP funciona com aba aberta,
falha com 0 abas.)

## Saúde / quando algo não conecta

```bash
cdp status                                            # mini (9222): UP/DOWN + abas
curl -s --max-time 5 http://127.0.0.1:9222/json/version   # mini
curl -s --max-time 5 http://127.0.0.1:9223/json/version   # MBP via túnel
```

- Mini down → `cdp restart`.
- MBP (9223) não responde mas mini ok → o **túnel** caiu. Reinicie:
  `launchctl kickstart -k gui/$(id -u)/com.athos.chrome-cdp-tunnel-mbp`
  (log em `~/Library/Logs/chrome-cdp-tunnel-mbp.log`). Se persistir, o Chrome
  CDP do **MBP** pode estar down — precisa de ação na máquina MBP.

## Blast radius / segurança (LER)

- O perfil `~/.chrome-cdp` carrega as **sessões reais logadas do Athos** e
  **qualquer extensão** instalada nele. **Qualquer agente que dirige o CDP
  (9222 ou 9223) age COMO o Athos** naquele perfil — credenciais, cookies,
  OAuth, tudo acessível. Não há isolamento entre agentes no mesmo perfil.
- Isso vale para os **dois** endpoints: 9223 dá o mesmo poder sobre o perfil
  dedicado do **MBP**.
- As portas são **localhost-only** (9222 no mini; 9223 é o túnel local) — só
  processos locais alcançam. Não exponha nem faça forward dessas portas pra
  fora do localhost.
- **Ações irreversíveis/financeiras** (finalizar compra, pagar, postar,
  excluir, enviar) **exigem confirmação explícita do Athos.** Navegar, ler,
  preencher e montar carrinho é livre. Regras completas de uso logado,
  endereço de entrega e pagamento: skill **`federated-site-login`**.
- Sessão expirada → peça re-login interativo ao Athos; não tente burlar.

## Relação com outras peças / fora de escopo

- **MCP `playwright-cdp`** (`mcp__playwright-cdp__browser_*`) aponta pro mini
  (9222) e carrega no start de sessões Claude novas — é o caminho preferido
  quando disponível. Fazer o MCP **selecionar 9222 vs 9223** é **Opcional/fora
  de escopo** desta entrega.
- **Não** altere/crie a infra de browser (já existe e funciona) nem use o
  Chrome pessoal do Athos (o padrão é o perfil dedicado `~/.chrome-cdp`).

## Refs

- Skill irmã: `federated-site-login` (doutrina de uso logado + guardrails).
- Doc: `~/gt/.gascity-gastown-hq/docs/federated-login-cdp.md`.
- Helper mini: `cdp {status|restart|stop|start|open <url>}` (`~/.local/bin/cdp`).
- Driver de exemplo (puppeteer): `~/.local/share/cdp-drive/drive.js`.
- Store de módulos: `~/.local/share/cdp-drive/node_modules` (playwright-core + puppeteer-core).
- Story: `ga-yx2d1`.
