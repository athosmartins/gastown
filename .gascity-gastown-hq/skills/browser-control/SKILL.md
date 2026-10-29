---
name: browser-control
description: Use when an agent/crew needs to drive a real Chrome over CDP from the mini — either the mini's own Chrome (127.0.0.1:9222) or the MacBook Pro's Chrome via the persistent tunnel (127.0.0.1:9223). Documents both endpoints, ready-to-run playwright-core and puppeteer-core connection snippets, how the modules resolve on the mini, and the security blast radius of the shared ~/.chrome-cdp profiles. Applies to ALL Gas City agents/crews.
---

# browser-control — dirigir Chrome via CDP (mini + MBP) por qualquer agente

## Contents

• Os dois endpoints CDP · Resolução dos módulos no mini (pré-requisito)
• Conectar — puppeteer-core (universal, recomendado) · Conectar — playwright-core
• Saúde / quando algo não conecta · Blast radius / segurança (LER)
• MCP `playwright-cdp`: higiene de snapshot, aba própria e versão fixa
• Relação com outras peças / fora de escopo · Refs

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

### Abas somem sozinhas em esperas longas (2026-07-14)

Como o perfil é **compartilhado entre agentes concorrentes**, uma aba sua pode
fechar sozinha no meio de uma operação de vários minutos (proteção de memória
do Chrome sob a carga de múltiplos agentes navegando ao mesmo tempo — visto
com `hex cell run`/publish em notebook pesado). Sintoma: `browser_navigate`/
`browser_snapshot` retorna `"Target page, context or browser has been
closed"`. Não é falha sua nem motivo pra abortar a tarefa:

1. `cdp status` — se DOWN, `cdp restart` (a sessão logada **sobrevive** ao
   restart, fica no perfil persistente `~/.chrome-cdp` — não precisa relogar).
2. Navegue de novo pra a mesma URL e retome de onde parou.
3. **Pra esperas de vários minutos** (aguardando um job/preview rodar),
   prefira `sleep` via Bash (não toca o browser) a ficar chamando
   `browser_wait_for` repetidamente — polling ativo parece correlacionar com
   mais fechamentos de aba do que só esperar e checar uma vez no fim.

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

## MCP `playwright-cdp`: higiene de snapshot, aba própria e versão fixa

Medido em 28/10 no mini (Chrome 156, `@playwright/mcp` 0.0.83; bead ga-g7zyxc3,
relatório `docs/reports/agent-browser-vs-playwright-mcp-ga-30455bt.md`). Tokens
são o200k; o custo real no Claude é ≈ ×1,44.

**Snapshot: o que custa e como gastar menos**

- As ações (`browser_click`, `browser_navigate`, `browser_type`…) **não**
  devolvem a página: devolvem um link para `.playwright-mcp/page-*.yml` (~30
  tokens). O snapshot inline só vem de `browser_snapshot` — não o chame a cada
  passo.
- **Orientar-se:** `browser_snapshot` com `depth: 3`. HN: 13.483 → 253 tokens;
  Wikipédia: 70.794 → 329. Em página pequena não ajuda (login 515 → 223; lista
  de 40 linhas 1.722 → 1.722).
- **Confirmar que algo mudou:** `browser_find` com `text` (138–161 tokens), não
  um snapshot novo. `browser_find` com `regex` largo **não** serve de filtro de
  controles: custa o snapshot inteiro.
- **Vários campos de uma vez:** `browser_fill_form` (o login também: usuário e
  senha na mesma chamada).
- **Ref só onde vai agir.** Login + formulário (11 passos): 15.330 tokens de
  resultado com snapshot em todo ponto de observação, 1.713 com snapshot só onde
  precisa de ref + `fill_form` (8 chamadas).

**Aba própria — dois `playwright-cdp` no MESMO Chrome navegam a MESMA aba**

Sem isolamento (medido no mini): o segundo `browser_navigate` troca a página do
primeiro, e o primeiro passa a ver o conteúdo do outro. O `:9222` é compartilhado
por vários crews, então vale mesmo sem nenhuma troca de ferramenta.

- **Primeira ação da sessão:** `browser_tabs` com `{action:"new", url:"…"}` e
  navegue só nessa aba. Medido: dois agentes ficaram isolados, inclusive quando
  um deles já estava trabalhando na aba inicial.
- **`browser_tabs list` lista TODAS as abas do Chrome, as de outros agentes
  também.** Nunca use `select` ou `close` com índice de aba que você não abriu:
  um `select 0` seguido de navegação sequestrou a aba do outro agente.
- **Depois de `browser_tabs close`, a aba "atual" passa para uma vizinha — que
  pode ser de outro agente.** Abra uma aba nova (`new`) antes de navegar de novo.
- No fim, feche a sua: `browser_tabs` com `{action:"close"}` e **sem** `index`
  fecha só a atual.

**Versão fixa**

- O `playwright-cdp` roda `@playwright/mcp` **0.0.83** direto com node, a partir
  de `~/.local/share/playwright-mcp` (instalado pelo `install.sh`): sem `npx`,
  sem consulta ao registry, sem o processo `npm exec` na frente. Antes era
  `npx @playwright/mcp@latest`, sem pin (cada sessão resolvia a versão do
  momento).
- Por que direto e não `npx @playwright/mcp@0.0.83`: com o mini a load 75–82,
  o `npx @playwright/mcp@latest` levou 31–35 s para responder o `initialize`
  (3 de 3 medições) e o `claude mcp get` marcou "Failed to connect — timed out
  after 30000ms"; o node direto levou 2,8–8,9 s (5 de 5). O `npx` com versão
  fixa também ficou lento (23, 45 e 69 s): o custo é o `npm exec` subindo numa
  máquina saturada, não só a consulta ao registry. Footprint por sessão: ~135 MB
  com `npm exec` + node, ~100 MB direto.
- Registrar (ou refazer) no Claude, uma vez por máquina:
  `claude mcp remove playwright-cdp -s user && claude mcp add playwright-cdp -s user -- /opt/homebrew/bin/node ~/.local/share/playwright-mcp/node_modules/@playwright/mcp/cli.js --cdp-endpoint http://127.0.0.1:9222`
  e confira com `claude mcp get playwright-cdp` (`✔ Connected`). Sessão viva só
  troca no restart.
- Trocar a versão: edite `PW_MCP_VERSION` no `install.sh`, rode-o e repita o
  `claude mcp get`. O plugin `playwright@claude-plugins-official` (sessões fora
  dos overlays do `city.toml`) ainda lança `npx @playwright/mcp@latest` sem pin.

## Relação com outras peças / fora de escopo

- **MCP `playwright-cdp`** (`mcp__playwright-cdp__browser_*`) aponta pro mini
  (9222) e carrega no start de sessões Claude novas — é o caminho preferido
  quando disponível (higiene, aba própria e versão: seção acima). Fazer o MCP
  **selecionar 9222 vs 9223** é **Opcional/fora de escopo** desta entrega.
- **Não** altere/crie a infra de browser (já existe e funciona) nem use o
  Chrome pessoal do Athos (o padrão é o perfil dedicado `~/.chrome-cdp`).

## Refs

- Skill irmã: `federated-site-login` (doutrina de uso logado + guardrails).
- Doc: `~/gt/.gascity-gastown-hq/docs/federated-login-cdp.md`.
- Helper mini: `cdp {status|restart|stop|start|open <url>}` (`~/.local/bin/cdp`).
- Driver de exemplo (puppeteer): `~/.local/share/cdp-drive/drive.js`.
- Store de módulos: `~/.local/share/cdp-drive/node_modules` (playwright-core + puppeteer-core).
- Story: `ga-yx2d1`.
