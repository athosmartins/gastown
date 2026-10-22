# Node.js no nó Hetzner · runbook

## Contents
• O que é e por que existe · Comandos · Como o hash foi autenticado · Estado vivo e o que foi MEDIDO
• Como atualizar a versão · Como desfazer · O que NÃO foi testado · Limites · jsdom dos testes do WA (ga-yoyyj1)

Bead ga-2hd02v.4.9 (filha da ga-2hd02v.4, ps-worker remoto). Decisão do Mayor (comentário em ga-2hd02v.4, 2026-10-21T02:40:06Z): instalar o Node no nó **em nível de usuário** (tarball fixado em `~/.local`, sem sudo, sem mexer no sistema), só para os testes do PS.

## O que é e por que existe
Cinco arquivos de teste do property_scrapers (`tests/test_blow_*.py`, `tests/test_scraper_status_blow_probe.py`) chamam o binário `node` (`shutil.which("node")`) e afirmam "node não está no PATH" quando ele falta. No nó eles reprovavam por **ambiente**, não por código: 242 dos 245 problemas da rodada do PS no nó vinham dessa causa única. Enquanto isso, qualquer bead de PS que citasse um deles ia ao mini (`so-no-mac`, `scripts/hetzner-mac-only.ps.txt`).

O nó é **aarch64** (Ubuntu 24.04, glibc 2.39), então o tarball é `linux-arm64`, não x64. A versão é a do mini (v22.22.3): teste no nó significa o mesmo que no mini. Só o binário `node` entra no PATH (`~/.local/bin/node`); npm e npx ficam dentro do diretório da versão, sem link, porque os testes não instalam pacote.

## Comandos
Rodam no **mini**; o nó é alcançado por ssh (`HETZNER_NODE_HOST`, padrão `hetzner-teste`).

```bash
bash scripts/hetzner-nodejs.sh check     # só lê. rc 0 igual ao pin · 1 ausente/quebrado/outra versão · 2 não consegui saber · 3 nó que o pin não cobre
bash scripts/hetzner-nodejs.sh install   # idempotente: igual ao pin = não baixa nada. rc 4 recusado (hash, binário, arquivo comum no lugar do link, diretório da versão que não é o certo) · 5 download falhou · 64 uso errado. Termina com a MESMA conferência do check: se depois de instalar não consegue ler o nó = rc 2, se lê e não está ok = rc 1 (e rc 3 se o nó fosse de outra arquitetura, o que não acontece na prática porque o instalador remoto já recusa)
bash scripts/hetzner-nodejs.selftest.sh  # hermético, ~40 s: ssh/curl/uname são stubs, o script remoto roda de verdade num HOME temporário; 20 mutantes
```

O que o `install` faz no nó, nesta ordem: baixa o tarball de `https://nodejs.org/dist/v<V>/` para um diretório temporário em `~/.local` · confere o sha256 contra o hash do pin (que **vem do mini**, não de arquivo baixado pelo nó) · extrai · roda o binário e exige que ele diga `v<V>` · move para `~/.local/node-v<V>-linux-arm64` · **só então** troca os links `~/.local/node` e `~/.local/bin/node`. Qualquer recusa antes dessa última etapa deixa o nó como estava; o diretório temporário é limpo na saída normal e na saída por erro (trap de EXIT). **SIGKILL, falta de memória ou queda de energia não rodam o trap** e podem deixar um `~/.local/.nodejs-install.*` (uns 230 MB: o tarball de 30 MB mais a extração de 201 MB) que nada varre: com nenhum `install` em curso, apague à mão (`ssh hetzner-teste 'rm -rf ~/.local/.nodejs-install.*'`).

## Como o hash foi autenticado
`scripts/hetzner-nodejs.pin` guarda a versão e o sha256 do `node-v22.22.3-linux-arm64.tar.xz`. A linha veio do `SHASUMS256.txt` oficial, autenticado com a assinatura destacada (`.sig`) **e** com a clearsigned (`.asc`): as duas deram `GOODSIG`/`VALIDSIG` da chave `CC68F5A3106FF448322E48ED27F5E38D5B0A215F` (Marco Ippolito), que consta em `nodejs/release-keys` (`keys.list`) e no README do `nodejs/node`. O pin é **dado**: o script o lê por `grep`, nunca com `source`, e versão e hash passam por regex antes de ir ao ssh.

## Estado vivo e o que foi MEDIDO
Instalado em 21/10/2026 03:01Z (00:01 -03), 12 s, pelo `install` acima. Conferido direto no nó, não pela saída do script:
- `node --version` = `v22.22.3`, `process.arch` = `arm64`, `process.platform` = `linux`, executa JS; `~/.local/bin/node` → `../node/bin/node` → `node-v22.22.3-linux-arm64`; 201 MB; nenhum `.nodejs-install.*` sobrou; segundo `install` não baixa nada.
- **A/B no mesmo worktree do espelho do PS** (main `b2643aa`, `venv-ps`, os 5 arquivos juntos): **sem** `node` no PATH, 31 falharam + 211 erraram + 1 passou (242 problemas, igual à rodada anterior); **com** `~/.local/bin` no PATH, **243 passaram** em 46 s.
- Dentro de `gt-iso-run` (isolamento de rede da bateria noturna) o PATH tem `~/.local/bin` e o `node` resolve.
- `hetzner-audit.sh` roda e nada do que ele acusa está sob `~/.local` (o topo `.local` não é auditado por dados, e o Node não é dado).

## Como atualizar a versão
Receita no cabeçalho de `scripts/hetzner-nodejs.pin`: baixar `SHASUMS256.txt` e a assinatura da versão nova, conferir com `gpg --verify` usando a chave do release-keys, copiar **só** a linha `linux-arm64.tar.xz`, trocar as duas linhas do pin de uma vez, rodar o selftest e o `install`. A versão antiga continua em `~/.local` (cada diretório de versão é imutável).

## Como desfazer
Tudo mora em `~/.local` do usuário `runner` no nó; nada fora dele foi tocado.

```bash
# desligar o node (tira só os dois links; os testes do PS voltam a ver "node não está no PATH"):
ssh hetzner-teste 'rm -f ~/.local/bin/node ~/.local/node'
# voltar a uma versão que continua em ~/.local, sem apagar nada:
ssh hetzner-teste 'ln -sfn node-v<antiga>-linux-arm64 ~/.local/node'
# liberar os 201 MB da versão (depois de desligar):
ssh hetzner-teste 'rm -rf ~/.local/node-v22.22.3-linux-arm64'
```
**Passo obrigatório depois de desligar o Node:** os testes do PS que chamam o node **já NÃO estão** em `scripts/hetzner-mac-only.ps.txt` (os 5 saíram na ga-2hd02v.4.10, merge `94091be13`; `tests/test_blow_cycle.py` nasceu depois da medição e também exige o node, e nunca esteve na lista), então precisam ser recolocados lá, sob o comentário do binário `node`: `tests/test_blow_rate_limit.py`, `tests/test_blow_budget.py`, `tests/test_blow_property_ids.py`, `tests/test_blow_scraper_ids_wiring.py`, `tests/test_scraper_status_blow_probe.py` **e `tests/test_blow_cycle.py`**. A lista EXATA de hoje é a que `bash scripts/hetzner-nodejs-guard.sh` nomeia quando falha: ela é derivada do repositório do PS, então inclui qualquer teste novo que chame o node. Sem isso, bead de PS que cite um deles vai ao nó e reprova com "node não está no PATH" (a falha de ambiente original).

## O que NÃO foi testado
- **A lista mac-only é estática; o Node é estado vivo do host.** Se o nó for refeito sem Node, bead que cite um teste que precisa do node vai ao nó e reprova alto em vez de ficar no mini. O detector é `scripts/hetzner-nodejs-guard.sh` (ga-2hd02v.4.11 e .4.14), chamado pelo prod test da história ga-2hd02v.4: ele DERIVA do repositório do PS os testes que chamam `shutil.which("node")` (6 hoje, incluindo `tests/test_blow_cycle.py`, que nasceu depois da medição dos 5) e FALHA se ALGUM está fora da lista e o nó não tem o Node. Quando não consegue saber (nó inalcançável, lista ilegível, repositório do PS ilegível com tudo coberto), o guarda devolve rc 2 e o prod test passa com AVISO e a última linha diz "NÃO verificado"; quando todos estão cobertos pela lista, a linha diz "não se aplica". **Limite:** a derivação só enxerga teste que acha o node por `shutil.which("node")`; um teste que chame o node por caminho fixo, por `subprocess` sem `which` ou por fixture em outro arquivo não entra no conjunto e o guarda não o vê.
- npm, `npm install` e puppeteer: de propósito fora de escopo. `scrapers/blow/package.json` depende de puppeteer; os 5 testes só precisam do binário (provado acima), mas um teste futuro que rode o scraper de verdade vai precisar de pacote e de navegador.
- ssh caindo durante o `check` e durante o `install` (antes de o install rodar, depois de ele rodar com a saída completa, sem a sentinela `FIM`, e na conferência final): o selftest cobre, sempre rc 2; cada ramo tem caso, e os mutantes provam o 255 depois de o install rodar, a falta de FIM e a conferência final. O "cai ANTES de o install rodar" é guardado em duas camadas (o 255 e a falta de FIM), por isso nenhum mutante único o derruba. Nada disso foi provocado ao vivo, e o nó desligado de verdade também não.

## Limites
- Um symlink que já exista em `~/.local/node` ou `~/.local/bin/node` é tratado como nosso e trocado (o nó não tinha nenhum); só arquivo ou diretório comum é recusado.
- Duas instalações simultâneas não são serializadas (não há lock): quem chega depois do `mv` da outra confere a versão e reaproveita o diretório; numa corrida estrita o perdedor pode deixar um diretório aninhado inofensivo dentro do da versão. Rode um `install` por vez.
- A troca `ln -sfn` de dois links não é uma transação única: há microssegundos entre `~/.local/node` e `~/.local/bin/node`. Aceitável: o nó só roda teste e a troca só acontece quando o pin muda.
- A auditoria de dados do nó (`hetzner-audit.sh`) agora pula qualquer filho `gt-remote/venv-*` por padrão de nome (antes só `venv-wa`, e o `venv-ps` da ga-2hd02v.4.8 aparecia como 33 achados `GRANDE` de pacotes). É o que o cabeçalho dela já dizia em LIMITES (`venv*` não é lido por conteúdo); a linha `LIMPO` de dados continua dizendo o que ficou de fora.

## jsdom dos testes do WA (ga-yoyyj1)
Achado da ga-00unl0 (pulos do `gate-pytest` no remoto). Seis arquivos de teste do WA montam a tela real em jsdom (`test_termo_chamariz_wa_7x7gdh.py`, `test_app_como_funciona_wa_fdxr7o.py`, `test_superlike_baralho_wa_awicsu_2.py`, `test_superlike_acomp_wa_awicsu_3.py`, `test_hetzner_resumo_painel_wa_7ykup6_3.py`, `test_teto_liberados_wa_1d97lb_5.py`) e **pulavam** no nó com `jsdom indisponível (npm i jsdom)`. Pulo não reprova, mas é cobertura que o remoto não dava. O nó tinha o Node (seções acima) e não tinha o jsdom.

**Duas pontas, e nenhuma substitui a outra.** Os testes do WA acham o jsdom de dois jeitos:
- Os seis da bead (e mais ~24 arquivos) usam `_node_modules()`, que olha três pastas fixas (`ROOT/node_modules`, `/Users/athos/gt/whatsapp_automation/node_modules`, `~/.local/share/cdp-drive/node_modules`) e só então passa `NODE_PATH=<a pasta>` ao `node` que chamam. O `skipif` testa a **pasta**, não a variável. A primeira some no espelho (o rsync apaga `node_modules`) e a segunda é do mini, então no nó só a terceira serve: é o que o `install jsdom` monta (a mesma pasta que o mini usa no `vitest.config.js` e na skill browser-control).
- Outros ~20 arquivos (um deles é um helper) fazem `require('jsdom')` num `node` **sem** NODE_PATH e só pulam se faltar o próprio `node`. No mini acham o módulo no `node_modules` do repositório; no nó ele não existe, e eles reprovavam com `Cannot find module 'jsdom'` desde que o Node foi instalado (ga-2hd02v.4.9). Para eles o `mbp-run.sh` exporta `NODE_PATH=$HOME/.local/share/cdp-drive/node_modules` nos jobs do nó, e o `gt-iso-run` a repassa à bateria noturna (o helper roda o comando com `env -i`, que a descartaria).

**Comandos** (no mini). `jsdom` é um componente à parte: o `check` sem a palavra continua falando só do node, que é o que o `hetzner-nodejs-guard.sh` do PS lê (um rc 1 por falta de jsdom o faria acusar "sem Node" com o Node presente).

```bash
bash scripts/hetzner-nodejs.sh check jsdom     # só lê. rc 0 igual ao pin e carregando · 1 ausente/quebrado/diferente · 2 não consegui saber · 3 nó que o pin não cobre
bash scripts/hetzner-nodejs.sh install jsdom   # idempotente. rc 4 recusado · 5 npm ci falhou · 64 uso errado. Termina com a MESMA conferência do check
```

O pin ganhou `JSDOM_VERSION` e `JSDOM_LOCK_SHA256`; o lock mora em `scripts/hetzner-nodejs-libs/` (`package.json` com o jsdom em versão exata e `package-lock.json` com 60 pacotes por sha512). Versão **25.0.1**, a última 25.x, porque o rig WA do mini carrega jsdom 25.x; o patch exato do mini não é legível do nó (confira com o `node -p` do cabeçalho do pin).

**O que o `install jsdom` faz no nó, nesta ordem:** exige o node do pin ok (senão rc 4: rode `install` antes) · o mini confere o sha256 do lock contra o pin antes de abrir o ssh · o nó decodifica o `package.json` e o lock recebidos e confere de novo o sha256 · `npm ci --ignore-scripts` num diretório temporário de `~/.local/share` (registry oficial fixo; cache do npm dentro do temporário, nada em `~/.npm`) · exige que o jsdom instalado diga a versão do pin e **carregue** · move para `~/.local/share/cdp-drive-jsdom-<V>-<12 hex do lock>` · **só então** liga `~/.local/share/cdp-drive` (`ln -sfn`). Qualquer recusa antes deixa o nó como estava; o diretório temporário sai no trap de EXIT (SIGKILL ou queda de energia deixam um `~/.local/share/.jsdom-install.*` de algumas dezenas de MB para apagar à mão). Um `~/.local/share/cdp-drive` que seja diretório comum é recusado (rc 4): o `npm ci` apagaria um repositório de módulos que não é nosso.

**Estado vivo e o que foi MEDIDO** (22/10/2026, 06:19Z a 07:10Z, no próprio nó):
- O `install jsdom` rodou de verdade aqui por um ssh de mentira (um script que ignora as opções e o host e executa o comando remoto como o mesmo usuário: `MBP_SSH=<script> HETZNER_NODE_HOST=local`): 3,4 s, rc 0, `~/.local/share/cdp-drive` → `cdp-drive-jsdom-25.0.1-715f1221ea01` (19 MB), `~/.npm` não foi criado. Um segundo `install` e o `check jsdom` dizem ok sem baixar nada; o `check` do node segue rc 0 com a mesma linha de antes.
- `npm audit signatures` na árvore do lock: 60 pacotes com assinatura do registro verificada, 1 com atestado de proveniência.
- Selftest `hetzner-nodejs.selftest.sh`: 197 verificações, 0 falha, em bash 5.2 **e** num bash 3.2.57 de verdade; 41 mutantes mortos; contra o script ANTIGO o mesmo selftest dá 76 falhas em 12 s. `hetzner-iso-run.selftest.sh` 46/46 (12 mutantes, um novo: W7); `hetzner-nodejs-guard.selftest.sh` 67/0.
- Os seis arquivos da bead (cópia privada do slot wa-1 do espelho, main de 05:20Z, venv-wa, node v22.22.3): sem o jsdom, 87 passaram e 8 pularam; com a pasta, 94 passaram e 1 reprovou (item 1 abaixo).
- Os 89 arquivos do WA que citam jsdom, mesmo conjunto nos três estados (falhas / passam / pulos / erros): **sem jsdom** 292 / 1214 / 194 / 109 · **com a pasta** 294 / 1244 / 162 / 109 (32 pulos a menos: 30 viraram passes e 2 viraram falhas) · **com a pasta e o NODE_PATH** 175 / 1664 / 27 / 104. O NODE_PATH corrige 122 falhas e 5 erros em 15 arquivos e faz rodar 135 testes que ainda pulavam; traz 3 falhas novas (itens 3 e 4).
- O que o jsdom **expõe** (o pulo escondia; pelo que o espelho mostra, nenhum é defeito do jsdom nem do nó, e sim do estado da main do WA). Nenhum foi posto na lista mac-only: sem acesso ao mini não dá para dizer se lá passam, e se não passarem a lista só mudaria o vermelho de lugar; a confirmação é de quem enxerga o mini:
  1. `test_teto_liberados_wa_1d97lb_5.py::test_telas_em_jsdom[test_teto_global_painel_wa_1d97lb_5.cjs]`: o `.cjs` não existe em nenhum slot do espelho desde pelo menos 20/10, embora o filtro do rsync o levaria (conferido em dry-run).
  2. `test_prioridade_azul_botao_wa_taez1x_1.py::test_prioridade_azul_e_botao_no_computador_em_jsdom`: asserção de conteúdo (`o hex do azul só na definição do token`, 8 !== 1).
  3. `test_ficha360_localize_nome_contrato_front_wa_3dysn.py::test_o_front_renderiza_a_faixa_e_o_aviso_no_jsdom`: `fixture ausente` (`tests/fixtures/ficha360_ln_busca_wa_3dysn.json` não está no espelho, o vizinho `ficha360_ln_vinculado_wa_3dysn.json` está, e o filtro levaria o arquivo, conferido em dry-run).
  4. `test_map_viewer_selecao_remover_register_wa_5460ap.py::test_cenario[...]` (2 cenários): `ReferenceError: REG_VIVO is not defined` no harness que extrai funções do template.
- O que as duas pontas **não** mudam: o erro de coleta de `test_viewer_secoes_colapsaveis_wa_kybk4a.py` (lê `viewer/index.html`, que o espelho não leva), os testes de Playwright (sem Chromium no nó: uns 100 erros de setup e dezenas de falhas), sqlite e lxml.

**Como atualizar o jsdom.** Receita no cabeçalho do pin (`JSDOM: COMO ATUALIZAR`): trocar a versão no `package.json`, `npm install --package-lock-only --ignore-scripts` com o npm do Node do pin, `npm ci` + `npm audit signatures` numa pasta de teste, trocar as duas chaves do pin de uma vez (`shasum -a 256 package-lock.json`), rodar o selftest e o `install jsdom`. O diretório da versão antiga continua em `~/.local/share`.

**Como desfazer o jsdom.** Tudo mora em `~/.local/share` do usuário `runner`:

```bash
# desligar o jsdom (tira só o link; os testes do WA voltam a pular com "jsdom indisponível"):
ssh hetzner-teste 'rm -f ~/.local/share/cdp-drive'
# voltar a uma instalação que continua em ~/.local/share, sem apagar nada:
ssh hetzner-teste 'ln -sfn cdp-drive-jsdom-<V>-<12 hex do lock> ~/.local/share/cdp-drive'
# liberar os 19 MB de uma instalação (depois de desligar):
ssh hetzner-teste 'rm -rf ~/.local/share/cdp-drive-jsdom-<V>-<12 hex do lock>'
```
Para tirar só o NODE_PATH, reverta a linha `pathline` do `mbp-run.sh` e o `NODE_PATH=` do `exec sudo` do `hetzner-iso-run.sh`.

**O que NÃO foi testado no jsdom.** O ssh de verdade entre o mini e o nó (a prova ao vivo usou o ssh de mentira acima: o texto remoto é o mesmo, o transporte não); o macOS (o selftest só rodou em Linux, bash 5.2 e o bash 3.2.57 da GNU; há atalhos para `timeout`, `base64 -d` e `sha256sum` que o macOS não tem, não exercitados lá); a bateria do gate e a noturna de ponta a ponta com o NODE_PATH (os selftests do `mbp-run.sh` e do `hetzner-iso-run.sh` cobrem a **forma** da chamada; o `sudo` do helper não roda sem root); os números acima vêm de uma cópia do slot wa-1 rodada à mão com `nice 19`, não de um job real do gate. O `mbp-run.selftest.sh` tem 45 falhas que já existiam neste nó antes da mudança (presença/ioreg do macOS, `date`/`stat` do BSD e o jq do `hoje`); o conjunto de falhas é idêntico depois.

**Limites do jsdom.** Rode um `install jsdom` por vez (não há lock, como no node). O `install jsdom` não repara um diretório de versão que existe e não carrega: ele recusa (rc 4) e o conserto é apagar o diretório à mão. Não rode `skills/browser-control/install.sh` no nó: ele faz `npm install` dentro de `~/.local/share/cdp-drive` e, atravessando o link, mexeria no diretório imutável do jsdom.
