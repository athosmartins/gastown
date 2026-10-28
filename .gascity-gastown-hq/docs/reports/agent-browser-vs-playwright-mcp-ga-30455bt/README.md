# Harness da avaliação agent-browser × `playwright-cdp` (ga-30455bt)

## Contents

• O que é · Layout do scratch · Passo a passo · Rodar no mini (adaptações) · O que cada script faz
• Armadilhas conhecidas

Relatório: `../agent-browser-vs-playwright-mcp-ga-30455bt.md`. Este diretório é **evidência e ferramenta de re-medida**, não código de produção: nada aqui é importado pela cidade. Os scripts rodam só contra páginas congeladas e um Chromium **descartável** em loopback.

## Layout do scratch

Tudo mora numa pasta que você escolhe (`EVAL_S`); nada é instalado fora dela e o `HOME` dos processos de terceiros é um diretório vazio dentro dela. Os scripts de terceiros recebem ambiente limpo (`scrubbedEnv` em `scripts/mcpc.js`): nenhum segredo da sessão vai para eles.

```
$EVAL_S/{bin-ab, home-ab, pw-mcp, tok, npm-cache, fixtures, work, out/v2, scripts}
```

## Passo a passo

```bash
export EVAL_S=<pasta> PATH=<node>/bin:$PATH RUN_TAG=v2
mkdir -p $EVAL_S/{bin-ab,home-ab,pw-mcp,tok,npm-cache,fixtures,work,out/v2} && mkdir -m 700 -p /tmp/abe
cp scripts/*.js $EVAL_S/scripts/        # (crie $EVAL_S/scripts antes)

# 1. agent-browser: binário oficial, versão fixa; confira o sha256 com o digest da API de releases
curl -sSfL -o $EVAL_S/bin-ab/agent-browser \
  https://github.com/vercel-labs/agent-browser/releases/download/v0.40.0/agent-browser-<linux|darwin>-<arm64|x64>
chmod +x $EVAL_S/bin-ab/agent-browser
#   v0.40.0 linux-arm64 = f33b4dd9bd7707ad952125937f9de18f93548c5d51283b18092fe21ced6b9e53
#   v0.40.0 darwin-arm64 = b064c9107a0431c76d8916e47c2c8ac322f49c2b2720d6c9036ab538ec1ed911  (digest publicado)

# 2. MCP do Playwright (versão fixa, sem scripts de instalação) e o tokenizador
printf '{"name":"x","private":true}\n' | tee $EVAL_S/pw-mcp/package.json > $EVAL_S/tok/package.json
npm --prefix $EVAL_S/pw-mcp --cache $EVAL_S/npm-cache install @playwright/mcp@0.0.83 --ignore-scripts
npm --prefix $EVAL_S/tok    --cache $EVAL_S/npm-cache install gpt-tokenizer --ignore-scripts

# 3. páginas congeladas, servidor local e UM Chromium compartilhado por CDP (sem DNS externo)
node $EVAL_S/scripts/fixtures.js
node $EVAL_S/scripts/server.js 47811 &
<chromium> --remote-debugging-port=47222 --remote-debugging-address=127.0.0.1 --user-data-dir=<dir descartável> \
  --host-resolver-rules='MAP * ~NOTFOUND , EXCLUDE 127.0.0.1' about:blank &
export AGENT_BROWSER_SOCKET_DIR=/tmp/abe   # limite de 103 bytes no caminho do socket

# 4. medir
for c in pw-A pw-B pw-B2 pw-npx ab-full-A ab-c-A ab-i-A ab-i-B ab-batch; do node $EVAL_S/scripts/run-task.js $c; done
node $EVAL_S/scripts/probe-tools.js     # custo estático (tools/list)
node $EVAL_S/scripts/run-micro.js       # snapshot por modo e por página; delta em página média
node $EVAL_S/scripts/run-delta2.js      # --delta na página pesada (com e sem -c)
node $EVAL_S/scripts/share-test.js      # 2 MCPs Playwright e 2 sessões agent-browser sem pin no mesmo Chrome
node $EVAL_S/scripts/pin-test.js        # --pin-tab: caminho feliz e falhas (sessões novas)
node $EVAL_S/scripts/report.js          # tabelas + modelo de custo
```

## Rodar no mini (adaptações)

- **Nunca** aponte `CDP` (`47222` nos scripts) para o `:9222` ou `:9223` reais nem para o perfil `~/.chrome-cdp`: ele carrega as sessões logadas do Athos (skill `browser-control`, "Blast radius"). Suba um Chrome **descartável** (`--user-data-dir` novo, porta própria) e, para o item "pin-tab no Chrome real", só abas descartáveis e só depois de o Mayor autorizar.
- RAM: troque a leitura de `/proc` (`sumMem` em `run-task.js`) por `footprint -p <pid>` (ou o MEM do `top`): no macOS o RSS do `ps` subestima ~10× (ga-e87w1f, `city.toml`).
- Binário: `agent-browser-darwin-arm64`. O Chrome do mini é ≥136; o do teste foi o 145 headless.
- `calib.js` calibra o tokenizador com o `usage` do transcrito **da sessão que o roda** (`TRANSCRIPT=...jsonl`): rode `echo` / amostra / `echo` em chamadas Bash **sequenciais** e sem comentário entre elas (veja o relatório, §1). O fator medido aqui foi ×1,44.
- A linha de base de uso real (item 2 do §9 do relatório) não tem script aqui: contar `mcp__playwright-cdp__*` e o tamanho dos `tool_result` em `~/.claude/projects/*.jsonl`, só agregados, sem copiar conteúdo.

## O que cada script faz

| script | papel |
|---|---|
| `mcpc.js` | cliente MCP mínimo (JSON-RPC/stdio), ambiente limpo, contagem de tokens |
| `fixtures.js`, `server.js` | congela 4 páginas públicas (scripts fora, CSS inline) e serve em loopback, mais uma lista própria |
| `run-task.js` | a tarefa canônica de 11 passos por configuração; grava respostas brutas e amostra memória |
| `run-micro.js`, `run-delta2.js` | tamanho por modo/página e `--delta` |
| `share-test.js`, `pin-test.js` | isolamento de aba no Chrome compartilhado |
| `compact-check.sh` | `-c`/`-i` escondem texto puro? compara cada modo com a verdade do DOM (`eval`) |
| `probe-tools.js` | `tools/list` de cada stack |
| `calib.js`, `report.js` | calibração contra tokens reais e agregação/custo |
| `verify-doc.py` | confere cada número do relatório contra `results/` (71 checagens; saída em `results/verify-doc.out`) |
| `smoke.js` | olhar o formato real das respostas |

## Armadilhas conhecidas

- O `click` do agent-browser não espera a navegação: sem `wait --url`, o snapshot seguinte pode vir `(no interactive elements)`.
- Nome de sessão do agent-browser reaproveitado guarda o vínculo de aba antigo; use nomes novos nos testes de `--pin-tab`.
- A página `todo` **remove** o botão clicado: não repita a mesma ref (por isso `run-delta2.js` só usa a página pesada).
- Não use `rm -rf` no scratch (a regra de aprovação do `rm -rf` trava sessão sem humano): as saídas são versionadas por `RUN_TAG`, nunca apagadas.
