# Medição no mini (ga-g7zyxc3)

## Contents

• O que é · Como reproduzir no mini · O que cada arquivo faz · O que NÃO está aqui

Evidência e ferramenta de re-medida do §11 do relatório (`../../agent-browser-vs-playwright-mcp-ga-30455bt.md`, na main). Medido em 28/10/2026 no mini (macOS arm64, Chrome 156.0.8078.49 descartável em headless, node 22, `@playwright/mcp` 0.0.83, agent-browser v0.40.0 darwin-arm64). Extensão do harness do nó (`../scripts/`): os scripts de `scripts/` daqui são as versões macOS e os novos; o resto (`fixtures.js`, `server.js`, `share-test.js`, `pin-test.js`, `run-micro.js`) é copiado sem mudança para a pasta ser autossuficiente.

## Como reproduzir no mini

Mesmo passo a passo do `../README.md` (EVAL_S, binário agent-browser com sha256 conferido contra o digest publicado pelo GitHub, `npm install --ignore-scripts`, fixtures, Chrome descartável em `--headless=new` com `--host-resolver-rules='MAP * ~NOTFOUND , EXCLUDE 127.0.0.1'`), mais:

```bash
export EVAL_S=<pasta> PATH=/opt/homebrew/bin:$PATH
node $EVAL_S/scripts/server.js 47811 &                 # fixtures
node $EVAL_S/scripts/idp-server.js 47901 47902 &       # IdP e relying party de TESTE (demo-user / demo-pass), só loopback
bash $EVAL_S/sweep.sh $EVAL_S                          # 3 rodadas x 9 configs (tokens, latência, footprint)
ROUNDS=r1,r2,r3 node $EVAL_S/scripts/mini-report.js    # tabelas
RUN_TAG=mini1 node $EVAL_S/scripts/share-test.js; RUN_TAG=mini1 node $EVAL_S/scripts/pin-test.js
RUN_TAG=mini1 node $EVAL_S/scripts/share-mitigation.js # browser_tabs{new}: isola dois MCPs?
RUN_TAG=idp2 node $EVAL_S/scripts/idp-flows.js pw      # redirect, popup, iframe
RUN_TAG=idp3 node $EVAL_S/scripts/idp-flows.js ab
node $EVAL_S/scripts/startup-latency.js @playwright/mcp@latest 3   # spawn -> initialize via npx
node $EVAL_S/scripts/startup-direct.js <cli.js> 5                  # o mesmo, node direto
python3 -I $EVAL_S/scripts/usage-baseline.py 9                     # uso real nos transcritos, SÓ agregados
```

`pin-real.sh <porta> <rótulo> <EVAL_S>` roda UMA sessão `--pin-tab` com UMA aba `data:` e fecha no fim; mostra as abas antes/durante/depois (sem query string). Rode-o no `:9222` real só com a bead autorizando e olhando antes o footprint do Chrome (o `chrome_cdp_watchdog` recicla o Chrome inteiro acima de 4096 MB por 900 s). `bin/fp.sh` soma o `phys_footprint` de uma lista de pids.

## O que cada arquivo faz

| arquivo | papel |
|---|---|
| `scripts/mcpc.js`, `scripts/run-task.js` | versão macOS: node do Homebrew no PATH limpo; memória por `footprint -p` (com o RSS do `ps` ao lado) em vez de `/proc`; latência por chamada |
| `scripts/mini-report.js`, `sweep.sh` | agregação (mediana entre rodadas, mesmo modelo de custo ITE, K=1,44 do nó) e o laço das 3 rodadas |
| `scripts/idp-server.js`, `scripts/idp-flows.js` | IdP e RP de teste em duas origens (portas) + os três fluxos nas duas stacks |
| `scripts/share-mitigation.js` | `browser_tabs{new}` isola dois MCPs do Playwright no mesmo Chrome? |
| `scripts/startup-latency.js`, `scripts/startup-direct.js` | tempo de spawn até o `initialize` |
| `scripts/usage-baseline.py` | contagem de `mcp__playwright-cdp__*` por dia e ferramenta nos transcritos (agregados) |
| `pin-real.sh`, `bin/fp.sh` | teste do `--pin-tab` num Chrome real e soma de footprint |
| `results/` | saídas medidas (abaixo) |

`results/`: `mini-report.txt` (tabelas do §11), `sweep.log`, `r1..r3/task-*.json` (por passo: tokens, ms, footprint), `micro.json`, `share-test.txt`, `pin-test.txt`, `share-mitigation.txt`, `idp-pw/`, `idp-ab/` (um log por fluxo + `idp-summary.json`), `startup-latency.txt`, `usage-baseline.txt`, `pin-real-9222.txt` (títulos das abas dos agentes omitidos).

## O que NÃO está aqui

- As respostas brutas por passo (`out/<rodada>/<config>/NN-*.txt`): têm conteúdo de páginas de terceiros (GitHub, HN, Wikipédia).
- Login federado REAL, passkey virtual, `--pin-tab` no `:9223` (túnel sem backend: o Chrome CDP do MBP estava desligado) e agente-com-LLM no laço. O motivo de cada um está no §11 do relatório.
