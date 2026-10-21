# ps-worker no nó Hetzner: bead de código do property_scrapers, sem banco real, credencial nem rede viva · runbook

## Contents

• Estado e o que ele muda · O que há no repositório · Como o classificador decide · O que o classificador manda ao nó hoje (calibração) · A escada de modos do Pilot e a sessão
• O gate-done do nó para outro rig · Como ligar, passo a passo · Devolver uma bead ao mini · Como desligar · O que depende de outras histórias · O que não foi provado

Bead ga-2hd02v.4 (filha de ga-2hd02v, "Hetzner 100%"). Athos, 20/10: "o que não pode é ficar menos do que 100% ocupado" e "foque nas beads que vão fazer a gente usar o hetzner 100% da capacidade 24/7". Antes desta entrega nenhuma bead do `property_scrapers` (PS) rodava no nó: o pool `ps-worker` do mini tem teto 1 e a fila de PS esperava 12–20 h. É o irmão de `docs/runbooks/hetzner-wa-node.md` (WA): mesmo desenho, rig e classificador próprios, e uma diferença de fundo na sessão (abaixo).

## Estado e o que ele muda

**Estado: construído, testado e DESLIGADO.** Nada aqui muda o despacho até alguém seguir "Como ligar", passo 6. Com o gancho desligado (`PILOT_PS_NODE_ROUTE`, padrão `off`) a função volta antes de ler qualquer coisa; nenhuma bead leva o dono `ps-worker-remote-1`; o agente `ps-worker-remote` tem `min_active_sessions = 0` (não nasce sessão sozinho).

Já vale, e já está vivo (passos 1–5 de "Como ligar", feitos em 20/10 de forma aditiva): o espelho git do `property_scrapers` no mini e no servidor, o papel `ps-worker` em `worktree_rigs` do host, o `identity_pattern` do atalho e o `gate-done-remote.py` multi-rig (mergeado). Desligado de verdade fica o que decide e despacha: o gancho do Pilot.

## O que há no repositório

| Peça | Arquivo | O que faz |
|---|---|---|
| Classificador | `scripts/ps-node-classify.py` (+ `.selftest.sh`) | Lê o `bd show --json` da bead no stdin e responde `node`, `mini` ou `unknown`. Só lê. Cópia adaptada do `wa-node-classify.py`. |
| Filtro do nó | `scripts/hetzner-rsync-filter.ps.txt` | O que o nó pode TER do PS (lista branca: código, testes, doc em texto, config listada). A Seção 1 é cópia byte a byte da do WA (o selftest confere). |
| Lista mac-only | `scripts/hetzner-mac-only.ps.txt` | Testes do PS que não rodam em Linux. **Semente inferida por texto, nunca medida no nó.** |
| Despachante | `scripts/ps-node-dispatch.sh` (+ `.selftest.sh`) | Casca sobre `scripts/wa-node-dispatch.sh`: fixa alias `ps-worker-remote-1`, classificador, log `ps-node-route.jsonl` e o **modo pilot**, e só aceita bead `ps-*`. Não há segunda cópia da lógica de escrita. |
| Agente | `agents/ps-worker-remote/` | O pool do nó: 0..1 sessão, `idle_timeout` 15 min, prompt de worker remoto (usa `bd -C property_scrapers`). |
| Gancho do Pilot | `_pilot_ps_node_decide`, `_pilot_ps_node_open`, `_pilot_ps_node_settle`, `_pilot_node_only_ps_pre` em `packs/town-deltas/assets/pilot-dispatcher.sh` (+ `pilot-dispatcher.ps-node-route.selftest.sh`) | Decide, atribui e **abre a sessão** (com as peças genéricas `_pilot_node_remote_open/_rollback` do ga-2hd02v.3). Padrão `off`. |
| gate-done do nó | `scripts/gate-done-remote.py` (tabela `RIGS`) | Submete ao gate a bead `ps-*` (e `wa-*`) entregue pelo nó. |

Registros que a entrega tocou por consequência: `e12-crew-doctrine.sh` (o prompt novo menciona `gate-done`, então é alvo da região E12: 13 alvos) e `pool-prompt-skill-mention.selftest.sh` (o template novo entra na lista que confere o prompt).

## Como o classificador decide

A primeira regra que casa vale; o texto da bead nunca é gravado de volta. As regras e os três estados são os do WA (`hetzner-wa-node.md`, "Como o classificador decide"). O que muda para PS:

1. **Duras** (nem `node:ok` vence): caminho citado que o filtro do PS ou a lista mac-only do PS não deixam chegar ao nó; caminho absoluto fora do repo, `..`, `~/…`, `$VAR/…`; telefone ou CPF no texto da bead; etiqueta `node:mini`; **bead que o worker do nó já devolveu** (`athos.node_recusa` preenchido: volta ao mini e fica lá, senão o modo `label` a mandaria de novo ao nó a cada varredura). O prefixo `/Users/athos/gt/property_scrapers/` e o de um worktree de crew (`…/crew/<nome>/`) são normalizados para o caminho relativo; qualquer outro `/Users/…` continua sendo host Mac.
2. **Moles** (`node:ok` as ignora e o motivo `moles-ignoradas` fica na resposta): banco real (MotherDuck, duckdb, sqlite, parquet, `~/.property-scrapers`, `shared/`), credencial (token, login, senha, cookie, `.env`), host Mac (launchd, plist, osascript, `/Users/`) e **rede viva** (proxy, IP residencial, Cloudflare, captcha, "ao vivo", "na rodada"). A rede viva é a regra do Mayor: raspador que precisa de IP residencial BR ou de proxy fica no mini.
3. **Prova positiva**: ao menos um teste citado (`tests/`, `lib/tests/`, `test_*.py`) e ao menos um arquivo de código citado, ambos pelo filtro → `node` (basis `text`); `node:ok` dispensa a prova → `node` (basis `label`).
4. **Informativas** (não bloqueiam; vão para o jsonl da sombra): produção, raspagem, dado de anúncio, tela e `raspador-fora-do-no:<pasta>` quando a bead cita `scrapers/<pasta>/…` e a lista `scripts/hetzner-scrape-eligible.txt` não libera aquele raspador no nó. Editar o código de um raspador e testá-lo com fixture não é raspar.

**Três estados, sempre.** Filtro ou lista mac-only ilegível (ou sem o `- *` final), lista de raspadores ilegível ou vazia, `rsync` mudo, canário errado, metadata que não é objeto, exceção qualquer → `unknown` (fica no mini). Nenhuma falha de leitura vira `node`.

## O que o classificador manda ao nó hoje (calibração)

Medido em 20/10 sobre as **391 beads** do store do PS (380 fechadas, 11 abertas; `bd list --all`, só leitura): **3 `node`, 179 `mini`, 209 `unknown`**. Todas as 11 abertas ficam no mini (raspagem viva, MotherDuck, launchd).

Leitura honesta: **o ganho por texto é pequeno (3 de 391)**. As 209 `unknown` são beads sem teste e código citados no texto; para essas o caminho é o `node:ok` posto por humano em bead de código de baixo risco (modo `label`) e, depois, provar pelo diff planejado em vez de pelo texto (a mesma pendência do WA). Quem quer o nó mais cheio de PS precisa de beads de PS que sejam só código: isso é trabalho de quem escreve a bead, não do classificador.

Reproduzir a calibração (só leitura): `bd -C /Users/athos/gt/property_scrapers list --all --limit 0 --json | jq -c '.[] | select(.issue_type!="convoy")' | while read -r b; do printf '%s' "$b" | python3 -I scripts/ps-node-classify.py; echo; done` e contar o campo `verdict`.

## A escada de modos do Pilot e a sessão

`PILOT_PS_NODE_ROUTE`, lida a cada chamada; qualquer valor fora dos quatro (vazio, "on", "AUTO") vale `off`. Os modos são os do WA: `off` · `shadow` (só `check` e uma linha em `$GC_CITY/.gc/ps-node-route.jsonl`; nunca muda o despacho) · `label` (a bead com `node:ok` vai ao nó) · `auto` (também a que se prova só pelo texto). O gancho só age quando o alvo da bead é `ps-worker`.

**A diferença para o WA: não existe o modo `pool`.** A bead do PS mora na loja do rig e o pool de um template sem `dir` só lê a cidade: ele nunca a veria. Por isso o `ps-node-dispatch.sh` fixa `WA_NODE_SPAWN=pilot` (um `WA_NODE_SPAWN=pool` herdado do ambiente não vale): o `apply` escreve só o dono `ps-worker-remote-1` e a marca `pilot.wa_node_alias` (sem `gc.routed_to`), e quem abre a sessão é o **Pilot**, com a receita que o `dog-remote` provou (`gc session new ps-worker-remote --alias ps-worker-remote-1 --no-attach`, ou `session wake` se o alias dorme, e um nudge). Qualquer falha ao abrir desfaz a atribuição (fecha a sessão só se tocou nela, solta a bead com `--if-assignee` e **confirma lendo**); desfazer que não se confirma é "segura" (a bead pode estar com o alias; o Pilot não a manda ao mini). Uma sessão lenta (prazo ou `PILOT_SLOW_SPAWN_SECS`) gasta o orçamento de spawn do sweep.

O `apply` também consulta o **oráculo de capacidade do nó** (`hetzner-capacity.py verdict`, o mesmo do WA): só `node` com vaga livre deixa a bead passar; `local`, ilegível ou ausente → fica no mini. Resíduo conhecido: as beads atribuídas cuja sessão ainda não subiu são descontadas **por loja de alias**; uma bead do WA e uma do PS aceitas na mesma varredura podem ver a mesma última vaga. O pior caso é uma sessão a mais, que o teto do provider recusa e o Pilot desfaz.

Os três retornos do gancho: `0` bead já atribuída ao nó e sessão aberta e avisada; `1` nada ficou escrito, a bead segue o caminho do mini; `2` **segura** — a bead já é do nó, ou o gancho não consegue relê-la, ou a escrita pode ter pegado sem confirmação (rc 13, prazo, sinal), ou o desfazer não se confirmou. No `2` o Pilot solta a claim e não despacha nesta varredura. Num `rc` incerto do `apply` o gancho desfaz sozinho **só** o que tem a cara do que o `apply` escreve (`in_progress`, dono `ps-worker-remote-<1-9>`, marca igual ao dono), nunca a bead de outro dono.

**Passada só-nó do disk floor (`ga-8okir7`).** Com `PILOT_NODE_FIRST=on` e o mini no piso de disco, a passada só-nó também leva ao gancho a bead `ps-*` do store do PS (uma sonda `apply --dry-run` por candidata, teto `PILOT_PS_NODE_ONLY_PROBES`, padrão 6). O `elif` do bloco do WA que solta a bead quando o gancho não a levou ganhou um guarda (`$_SLING_TARGET != ps-worker-remote`) para não soltar a bead que o PS acabou de levar.

## O gate-done do nó para outro rig

`scripts/gate-done-remote.py` (o executável por trás do `gate-done` da sessão remota) só atendia o rig `gascity`. Sem isso **nenhuma bead entregue pelo nó, de WA ou de PS, chegava ao gate pelo atalho**. Agora há a tabela `RIGS` (prefixo → rig, papel da sessão, rotas aceitas numa volta do gate):

| prefixo | rig | papel da sessão | rotas aceitas numa volta do gate |
|---|---|---|---|
| `ga` | gascity | `dog-remote` | `gastown.dog`, `dog-remote` |
| `ps` | property_scrapers | `ps-worker-remote` | `ps-worker`, `ps-worker-remote` |
| `wa` | whatsapp_automation | `wa-worker-remote` | `wa-worker`, `wa-worker-remote` |

* O **papel da sessão** (pelo nome) limita o rig: `ps-worker-remote-*` só submete bead `ps-*`; `dog-remote-*`, só `ga-*`. Alias e sessão têm de ser do **mesmo papel**: identidade mista recusa (Stop rc 2). Nome de sessão sem papel (`gate-reviewer-remote`, nomes de teste) vale como o HQ, o comportamento de antes. O controle primário continua sendo a bead estar atribuída ao alias.
* A **bead** é lida e solta na loja do rig (`bd -C <rig>`; o caminho vem de `.beads/routes.jsonl`, com a pasta conferida contra o nome do rig e o repositório lido pelo git). O **marcador** do gate continua na loja da cidade.
* O **worktree descartável** nasce sob `<rig>/.gc-worktrees/gate-done-remote/` e o espelho lido é `<cidade>/.gc/hetzner-mirror/repos/<rig>.git`.
* A **soltura** tira dono e a marca `pilot.wa_node_alias` e **relê**: só diz "solta" se a releitura devolve a bead pedida sem dono nem marca; releitura vazia, ilegível ou de outro id é "NÃO ficou solta".
* `wa-*` entrou na tabela porque o código é o mesmo, mas **a bateria dele não foi exercida com WA real** (só o PS tem fixture); não é parte da prova desta bead.

## Como ligar, passo a passo

Decisão do Mayor, não de quem constrói. Código mergeado e vivo no caminho mergeado (`Mergeado ≠ vivo`: confira o processo, não o arquivo).

1. **Espelho git do rig. FEITO em 20/10.** `hetzner-mirror.sh init property_scrapers … --seed /Users/athos/gt/property_scrapers/.repo.git --prefix fix/ --prefix feat/` e `sync` (`pronto=sim`; 47 caminhos negados pela varredura de conteúdo: `.pyc`, `node_modules`, binários do `.bare`). Varredura de segredo no `main` e no histórico: nada achado.
2. **Servidor. FEITO em 20/10.** `hetzner-remote-git.sh bootstrap property_scrapers ssh://athos@127.0.0.1:2293/property_scrapers.git …` e `scan` → `limpo`.
3. **Host. FEITO em 20/10.** `.gc/session-ssh.json`, host `hetzner`: `"ps-worker": "property_scrapers"` em `worktree_rigs` (backup `.bak-<ts>-pre-ga-2hd02v.4` ao lado).
4. **Identidade do atalho. FEITO em 20/10.** `~/.gastown/remote-shim.json` (`identity_pattern`) igual à linha `IDENTITY_PATTERN=` de `gc-session-ssh.md` (inclui `ps-worker`; backup ao lado).
5. **Agente. CONFERIDO em 20/10.** `gc config show` lista `ps-worker-remote` com o `prompt_template` do caminho mergeado.
6. **`shadow`.** `PILOT_PS_NODE_ROUTE=shadow` no `EnvironmentVariables` do plist do Pilot (`~/Library/LaunchAgents/com.gascity.pilot.plist`, e o versionado `scripts/com.gascity.pilot.plist`) e recarregar o Pilot. Deixar rodar e ler `$GC_CITY/.gc/ps-node-route.jsonl`: quantas `node`, por que base, e o campo `info`. Nenhuma bead muda.
7. **Primeira prova (`label`).** Alguém (Athos ou Mayor) põe `node:ok` em **uma** bead real de PS que seja só código e teste (sem as palavras moles). `PILOT_PS_NODE_ROUTE=label`. Acompanhar, na ordem: atribuição ao `ps-worker-remote-1` (+ a marca `pilot.wa_node_alias`), sessão aberta pelo Pilot (`gc session list`), worktree no nó, `git push` ao espelho, `gate-done` (o marcador nasce, a bead fica solta), o gate e o merge. Antes disso, rodar no nó `python3 -m pytest lib/tests` para **medir** a lista `hetzner-mac-only.ps.txt` (hoje semente inferida): teste que falha por ser do Mac entra na lista.
8. **Varredura do nó.** Depois da entrega: `hetzner-remote-git.sh scan` e `hetzner-audit.sh` (`hetzner-hardening.md`). Critério: nenhum arquivo de dado.
9. **`auto`** só depois de várias entregas sem `athos.node_recusa` e com a taxa de acerto medida no `shadow`.

## Devolver uma bead ao mini

O worker remoto não consegue devolver sozinho (o atalho não deixa mudar dono nem status): ele comenta, grava `athos.node_recusa` e avisa o Mayor. Quem despachou faz as duas coisas, nesta ordem, porque o `release` **não** põe o status de volta em `open`:

1. `scripts/ps-node-dispatch.sh release <bead>` — solta dono e marca (só toca bead cujo dono é `ps-worker-remote-<1-9>` **e** cuja marca é a do próprio alias, nunca a de outro dono).
2. `bd -C /Users/athos/gt/property_scrapers update <bead> --status open`.

O `athos.node_recusa` fica na bead e o classificador a mantém no mini (regra dura), mesmo com `node:ok`. Para dar outra chance ao nó, apague a chave de propósito.

## Como desligar

`PILOT_PS_NODE_ROUTE=off` (ou tirar a variável) e recarregar o Pilot. Para cada bead ainda no nó: o passo acima. A sessão ociosa se encerra em 15 min. Tirar `"ps-worker"` de `worktree_rigs` faz o provider recusar o `start` do papel.

## O que depende de outras histórias

* **ga-2hd02v.3** (WA no nó, outro dog): dono do `wa-node-dispatch.sh` (modo pilot, N slots, marca `pilot.wa_node_alias`, oráculo de capacidade, `WA_NODE_SELF/WA_NODE_STORY`) e das peças genéricas `_pilot_node_remote_open/_rollback`. O `ps-node-dispatch.sh` depende do contrato de variáveis `WA_NODE_*` (alias, rota, classificador, log, `SPAWN`, `SELF`, `STORY`, `CAPACITY`); o selftest de integração dele quebra se o contrato mudar.
* **ga-2hd02v.2 / .5 / .6** (degrau de capacidade, lastro de baixa prioridade, vigia por CPU): o nó cheio de trabalho de PS depende de haver bead de PS elegível; o lastro (`.5`) é o que mantém a CPU ocupada quando não há.

## O que não foi provado

Dito sem enfeite, porque os selftests passam sem nenhuma destas:

* **Nenhuma bead de PS foi ao nó.** A "prova" da bead (1 bead de PS construída no nó, passando no gate) é o passo 7 acima.
* O `_pilot_node_remote_open` com o **PS** nunca rodou contra o `gc` de verdade (os selftests usam `gc` e `bd` falsos; a receita é a do `dog-remote`, provada em produção).
* A lista `hetzner-mac-only.ps.txt` é inferida por texto; o `pytest` do PS **nunca rodou no nó**.
* O oráculo de capacidade foi exercido só pelos falsos do selftest do despachante.
