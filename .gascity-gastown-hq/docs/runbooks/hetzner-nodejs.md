# Node.js no nó Hetzner · runbook

## Contents
• O que é e por que existe · Comandos · Como o hash foi autenticado · Estado vivo e o que foi MEDIDO
• Como atualizar a versão · Como desfazer · O que NÃO foi testado · Limites

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
**Passo obrigatório depois de desligar o Node:** os 5 arquivos **já NÃO estão** em `scripts/hetzner-mac-only.ps.txt` (saíram na ga-2hd02v.4.10, merge `94091be13`), então precisam ser recolocados lá, sob o comentário do binário `node`: `tests/test_blow_rate_limit.py`, `tests/test_blow_budget.py`, `tests/test_blow_property_ids.py`, `tests/test_blow_scraper_ids_wiring.py` e `tests/test_scraper_status_blow_probe.py`. Sem isso, bead de PS que cite um deles vai ao nó e reprova com "node não está no PATH" (a falha de ambiente original).

## O que NÃO foi testado
- **Nada mecânico liga "os 5 arquivos estão fora da lista mac-only" a "o nó tem o Node".** A lista já foi atualizada (ga-2hd02v.4.10) e é estática; o Node é estado vivo do host. Se o nó for refeito sem Node, bead que cite esses arquivos vai ao nó e reprova alto em vez de ficar no mini. Guarda (ga-2hd02v.4.11): `scripts/hetzner-nodejs-guard.sh`, chamado pelo prod test da história ga-2hd02v.4; falha se os 5 arquivos estão fora da lista e o nó não tem o Node, e avisa (nunca fica verde) quando não consegue saber.
- npm, `npm install` e puppeteer: de propósito fora de escopo. `scrapers/blow/package.json` depende de puppeteer; os 5 testes só precisam do binário (provado acima), mas um teste futuro que rode o scraper de verdade vai precisar de pacote e de navegador.
- ssh caindo durante o `check` e durante o `install` (antes de o install rodar, depois de ele rodar com a saída completa, sem a sentinela `FIM`, e na conferência final): o selftest cobre, sempre rc 2; cada ramo tem caso, e os mutantes provam o 255 depois de o install rodar, a falta de FIM e a conferência final. O "cai ANTES de o install rodar" é guardado em duas camadas (o 255 e a falta de FIM), por isso nenhum mutante único o derruba. Nada disso foi provocado ao vivo, e o nó desligado de verdade também não.

## Limites
- Um symlink que já exista em `~/.local/node` ou `~/.local/bin/node` é tratado como nosso e trocado (o nó não tinha nenhum); só arquivo ou diretório comum é recusado.
- Duas instalações simultâneas não são serializadas (não há lock): quem chega depois do `mv` da outra confere a versão e reaproveita o diretório; numa corrida estrita o perdedor pode deixar um diretório aninhado inofensivo dentro do da versão. Rode um `install` por vez.
- A troca `ln -sfn` de dois links não é uma transação única: há microssegundos entre `~/.local/node` e `~/.local/bin/node`. Aceitável: o nó só roda teste e a troca só acontece quando o pin muda.
- A auditoria de dados do nó (`hetzner-audit.sh`) agora pula qualquer filho `gt-remote/venv-*` por padrão de nome (antes só `venv-wa`, e o `venv-ps` da ga-2hd02v.4.8 aparecia como 33 achados `GRANDE` de pacotes). É o que o cabeçalho dela já dizia em LIMITES (`venv*` não é lido por conteúdo); a linha `LIMPO` de dados continua dizendo o que ficou de fora.
