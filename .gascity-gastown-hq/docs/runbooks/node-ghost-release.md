# node-ghost-release — bead de alias do nó sem sessão volta ao Pilot (ga-moq226t)

## Contents

• O problema, medido · O que o job faz e o que não faz · Ligar (ensaio primeiro), desligar, conferir, provar · Limites e o que fica para outra bead

## O problema, medido
O nó recebe a bead JÁ atribuída ao alias (`wa-worker-remote-<1-9>` / `ps-worker-remote-<1-9>`, marca `pilot.wa_node_alias`); o Pilot abre a sessão; a bead só é solta na entrega (`wa-node-dispatch.sh release`, à mão). Se a sessão não nasce ou morre antes, nada olha a aresta bead→sessão: a bead fica «Em execução» e o slot do nó fica preso. Lido em 07/11 nas beads de sessão (`bd show ga-wisp-<cauda>`) e nas transcrições do nó (UTC):

| forma | bead / alias | o que o artefato mostra |
|---|---|---|
| create-falhou | wa-2f3l1s / -1 | sessão `b618w` criada 11:36:46, `failed-create` 11:49:03 («aborted before creation_complete», «lease expired and no live runtime»); nenhum worktree no nó: o `start` nunca chegou lá |
| limite-conta | wa-6assfn / -3 | `1fw36` trabalhou 70 min; transcrição: `rate_limit You've hit your weekly limit` às 01:25:53 (4×); idle-timeout 01:46; a bead ficou 32 h |
| idle-timeout | wa-4vjmkn.4.2 / -2 | `u43v0` publicou WIP (`worker/…-wip1/-wip2`), última fala 13:06 «Aguardando o término da varredura do JS (o próprio comando em segundo plano avisa)», morta pelo idle_timeout 13:24; a bead segue in_progress |
| reuso-perdido | wa-4vjmkn.4.2 / -5 (06/11) | `37jx8` terminou a bead dela às 23:34; o apply a reaproveitou às 23:50; o idle_timeout a matou 23:51:04; `last_nudge_delivered_at` não andou |

O relato «a sessão do alias jamais sobe» vale só para a 1ª. Latência `session new` → `start` chega ao nó: 1m55, 2m40, 3m51 (hoje à tarde) e 7m20, 7m50, 11m14 (hoje cedo), contra 20–30 s do lado do nó: o atraso é do mini/motor, e o lease do create é ~12 min.
Quem não cobria (rodado sobre o JSON real da wa-4vjmkn.4.2): `false-executing-watchdog` (dono tem de ser crew: `dono-nao-e-crew`), `inflight-reclaim-guard` (`is_reclaimable_inprogress_story` dá False sem `story:in-flight`/`pilot:dispatched`, que a bead real já não tem, e `pilot.dispatched_at`/`pilot.sling_bead` também sumiram: compatível com o NEVERSTARTED, inferido, não visto; só conhece o alias do MBP; `_pool_of("wa-worker-remote-2")` devolve `wa-worker`, o pool do mini), `release` (manual e não reabre). O `bead_state.derive` lê o alias morto como `executing`.

## O que o job faz e o que não faz
`scripts/node-ghost-release.py`, a cada 300 s. Fantasma = dono é alias do nó + marca == dono + `bead_state.derive` com o dono dado como morto diz `stranded` (ou `gate_failed` com `devolver_pro_pool`) + bead sem update há ≥ 900 s + nenhuma sessão não-morta com o alias (nem pelo `gc.session_name` da bead; `creating`/`start-pending`/estado desconhecido contam como viva; viva do template sem alias = «não sei»). Solta com ≥ 2 vistas e ≥ 900 s desde a 1ª (relógio em `.gc/state/node-ghost-release.json`). Antes de escrever relê roster e bead; UMA escrita guardada por dono e status: dono vazio, `open`, sem a marca do nó nem os carimbos do Pilot, `node:ghost-count:N`; a 2ª devolução põe `node:never` (vai ao mini). Confere relendo, comenta na bead, UM mail ao Mayor. Máx. 3 por rodada.
Não toca sessão, worktree nem branch do nó (trabalho não publicado fica lá: `hetzner-remote-git.sh status <rig>` lista o PENDENTE), nem bead com `pilot:dispatching`; não olha dog-remote/kimi (outras marcas), MBP (é do guard) nem a forma `pool`; não decide «viva mas parada». Roster, loja ou estado ilegível = nada acontece.
O Pilot também deixa a bead de dono-nó em paz (ga-59z7oek): com `PILOT_WA_NODE_ROUTE`/`PILOT_PS_NODE_ROUTE` em `label|auto`, `dispatch_lane` a pula ANTES da claim, sem escrever (nota `node_owned_skip` em `refused_by_guard` do `pilot_sweep`; linha `ga-59z7oek: <id> já é do nó` no log do Pilot). Antes, claim + soltura a cada ~21 min mantinham o `updated_at` novo e o job nunca a soltava (wa-7tufg6, 07/11: 30 min sem toque eram impossíveis). Com a rota do nó desligada nada mudou: a bead de dono morto segue readmitida ao pool do mini (gate-f).

## Ligar (ensaio primeiro), desligar, conferir, provar
O plist NÃO é carregado ao mergear (mergeado ≠ vivo; fica em `scripts/`) e vem com `NODE_GHOST_DRY_RUN=1` (loga `WOULD-RELEASE`, guarda o relógio, não escreve nem envia):
```bash
cp scripts/com.gascity.node-ghost-release.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.node-ghost-release.plist
grep -E 'GHOST|WOULD-RELEASE|elapsed' .gc/logs/node-ghost-release.out    # StartInterval tem de ficar acima do elapsed de UMA rodada
```
Registre no `daemon-presence-watchdog.sh` na MESMA mudança (`DPW_CRITICAL` + `com.gascity.node-ghost-release|$HQ/.gc/logs/node-ghost-release.out|900`). Depois de ver `WOULD-RELEASE` só de bead que ninguém executa, ponha `NODE_GHOST_DRY_RUN` em `0` (só `0` exato escreve) e recarregue (o relógio do ensaio vale: o que já venceu sai na 1ª rodada). A 1ª escrita real confirma o `bd update` combinado: as três formas (worker devolve, rollback do Pilot, gate-done-remote) são provadas separadamente, a união não foi vista rodar.
Desligar: `NODE_GHOST_ENABLED=0` no plist (recarregar) ou `touch .gc/node-ghost-release.off` (vale na próxima rodada). Ajustes: `NODE_GHOST_GRACE_SEC` (900, mín. 300), `NODE_GHOST_MAX_PER_RUN` (3), `NODE_GHOST_VETO_AFTER` (2; 0 = nunca veta); valor ilegível volta ao padrão.
Conferir: `GHOST` (por fantasma, toda rodada), `WOULD-RELEASE`/`RELEASE`, `SKIP` (a releitura desmentiu), `LOST` (rc 13), `FAIL` (a escrita não pegou; repete), `UNCONFIRMED` (escreveu e não deu para reler: vai no mail com ATENÇÃO). Falso positivo = bead solta com worker vivo: anote na bead, vira filtro. Provar: `python3 scripts/node-ghost-release.selftest.py` (~3 s, 3.12 e 3.9): mundo falso que APLICA o `bd update` e falha de todo jeito, mais o script real como subprocesso.

## Limites e o que fica para outra bead
- Assume `gc session list` completo (como o guard e o Pilot). Sessão viva mas parada (conta no limite) só vira fantasma depois do idle_timeout de 15 min.
- Recolhe, não cura: (a) reuso: teto superior para a ociosidade reaproveitável (`WA_NODE_IDLE_SECS` só tem piso), no `wa-node-dispatch.sh` E no trecho idêntico de `_pilot_node_remote_open`; (b) prompt do worker remoto: não terminar o turno esperando job em segundo plano (o idle_timeout de 15 min mata); (c) no mini, `session-ssh.log` de 11:36–12:09Z explica por que o `start` leva até 11 min e se `creating` aparece no roster durante o lease.
