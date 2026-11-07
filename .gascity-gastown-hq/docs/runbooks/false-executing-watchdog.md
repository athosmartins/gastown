# false-executing-watchdog — bead in_progress que ninguém executa (ga-9exarbg)

## Contents

• O problema · O que o vigia faz · O que ele NÃO faz · Como ligar (dry-run primeiro) · Como desligar · Conferir os alertas (a semana) · Como provar que funciona · Limites conhecidos

## O problema
Medido em 07/11 ~08:20 (o Athos: "16 em execução, metade há ≥1 dia"): de ~31 beads `in_progress` só ~6 andavam. As outras:

| forma | o que é | por que ninguém pegava |
|---|---|---|
| `idle-holder` | crew parada no prompt (ou dormindo/suspensa) segurando N beads: batista-wa 8, a mais velha 176 h sem update | O `inflight-reclaim-guard` nunca age em `in_progress` de crew sem marca do Pilot (comentário `SCOPE-CRITICAL` do código: só `story:in-flight` / `pilot:dispatched` e dono de pool) e segura de propósito as de crew suspensa; o `gate-orphaned-label-watchdog` (ga-eiaidn) conta dono com sessão VIVA como ativo, e viva ≠ trabalhando. O `stuck-exec` do `production-stall-watchdog` chama `bd list` sem `-C` com `WorkingDirectory` no HQ: lê só o store do HQ (lido no código, não conferido ao vivo), então nunca viu uma `wa-*` |
| `athos-turn` | bead que espera o Athos (`next-action:athos*`, `athos.acao`) mas manteve o dono-worker | some da fila dele e infla o painel; o guard e o stall-watchdog tratam bead estacionada como vez de OUTRO |
| `delivered` | `story:done` e ainda `in_progress` | o ramo "commit no main" é do `merged-bead-janitor` (ga-tijv5); o rótulo sozinho escapa dele |

## O que o vigia faz
`scripts/false-executing-watchdog.py`, a cada 899 s, em todas as lojas (HQ + `gc rig list --json`, com lista estática de reserva). Lê as `in_progress` e o roster (`gc session list --json`) e classifica, nesta ordem de precedência:

| achado | condição | ação |
|---|---|---|
| `delivered` | `story:done` (sem `delivery:partial` / `delivery:pending-restart` / `scope:needs-review`) há ≥ 1 h | mail |
| `athos-turn` | rótulo `next-action:athos*` ou vez do Athos pelo `bead_state` (`story:needs-approval`, `blocked-reason:decision`, `gate:needs-human:product`…) há ≥ 1 h | mail |
| `idle-holder` | dono é crew nomeada (`agents/*/agent.toml`: `work_dir` `…/crew/<slug>`, slug ≠ worker, `max_active_sessions` ≤ 1), a vez é dela pelo `bead_state.derive` (nem estacionada nem no gate), pane parado ≥ 2 h (`last_active`) ou sessão dormindo/ausente, bead sem update ≥ 6 h | nudge à crew só se a sessão está ativa e parada (1 a cada 6 h, até 4 por rodada) + mail; ≥ 24 h sai marcada "candidata a devolver" |

Mail: UM por rodada, ao `mayor` com `--notify`, com a lista toda quando algo é novo ou passaram 24 h do último. Estado: `.gc/state/false-executing-watchdog.json`. O nudge diz à crew o que fazer com cada bead (retomar, fechar, devolver, ou estacionar com `next-action:athos` + `athos.acao`).

## O que ele NÃO faz
- **Não muda bead nenhuma.** Devolver ao pool / a open-sem-dono é a próxima fatia, só depois de 1 semana de alertas conferidos (ordem do Mayor).
- Crew dormindo ou sem sessão: só mail (acordar crew custa RAM; quem decide é o Mayor).
- Só olha `feature` / `bug` / `task` / `chore`: épico é contêiner, e marker / molécula / step têm dono próprio.
- Não chuta. "Não sei" = nada acontece: roster ilegível ou vazio, `agents/` ilegível (o ramo `idle-holder` desliga; os outros seguem), `last_active` ilegível ou zero, sessão anexada a humano, `updated_at` ou rótulos ilegíveis, loja ilegível (pulada e contada; rc 1 se nenhuma pôde ser lida), estado ilegível (nada é enviado; o arquivo é posto de lado e a rodada seguinte recomeça limpa).

## Como ligar (dry-run primeiro)
O plist não está carregado: mergeado ≠ vivo. Fica em `scripts/` DE PROPÓSITO: o deploy (`skill-integrity-install.sh`) instala e inicia todo `com.gascity.*.plist` novo de `packs/town-deltas/assets/`, mas não olha `scripts/`. Vem com `FALSE_EXEC_DRY_RUN=1`.
```bash
FALSE_EXEC_DRY_RUN=1 python3 scripts/false-executing-watchdog.py        # na mão: lê tudo, não envia, não grava
cp scripts/com.gascity.false-executing-watchdog.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.false-executing-watchdog.plist
```
Registrar no `daemon-presence-watchdog.sh` na MESMA mudança: nome em `DPW_CRITICAL` e `com.gascity.false-executing-watchdog|$HQ/.gc/logs/false-executing-watchdog.out|2700` no mapa de heartbeat (3× o `StartInterval`; o `.out` ganha uma linha `start` por rodada). Depois de ler um log de dry-run (as linhas `ALERT` fazem sentido? as crews citadas estão mesmo paradas?), troque `FALSE_EXEC_DRY_RUN` para `0` no plist e recarregue: o primeiro mail lista tudo que existe hoje.

## Como desligar
`FALSE_EXEC_ENABLED=0` no plist (recarregar): vira no-op e ainda loga `start` / `kill-switch`, então o DPW não grita. Ou `launchctl bootout gui/$(id -u)/com.gascity.false-executing-watchdog` (e tirar do `DPW_CRITICAL` na mesma mudança). Outros ajustes por env: `FALSE_EXEC_IDLE_SEC` (7200), `FALSE_EXEC_STALE_SEC` (21600), `FALSE_EXEC_RETURN_SEC` (86400), `FALSE_EXEC_GRACE_SEC` (3600), `FALSE_EXEC_MAX_NUDGES` (4).

## Conferir os alertas (a semana)
O registro são as linhas `ALERT <achado> <loja>/<bead> dono=… idade=…` do `.out` (uma por achado novo): `grep ALERT .gc/logs/false-executing-watchdog.out`. Um alerta está "conferido" quando o Mayor olhou a bead e confirmou que ninguém a executava (`gc session peek <crew> --lines 40`, `bd show`). Falso positivo = anote o motivo na própria bead: ele vira o próximo filtro. Só depois de 1 semana sem falso positivo a devolução automática (pilot-manual-reclaim / open-sem-dono) entra, atrás de uma chave própria.

## Como provar que funciona
```bash
python3 scripts/false-executing-watchdog.selftest.py     # 155 checagens, ~1,5 s, sem tocar em bd/gc
```
Mundo falso para `bd`/`gc` que falha de todo jeito (rc 1, lixo, vazio, estouro de tempo, mail que não sai, nudge `queued`/ilegível, estado corrompido, pasta sem permissão, roster vazio) e o script de verdade como subprocesso (linha de comando exata, lock, kill-switch). Passa no 3.12 e no 3.9 (o `/usr/bin/python3` do mini). 81 mutantes (fronteiras de 1 h / 2 h / 6 h / 24 h, os três estados de cada leitura, precedência, argv de nudge e mail, lock, kill-switch): os 81 reprovam o selftest. Contra as `in_progress` reais do HQ (5 beads: o worker e 4 revisores do gate) o planejador não acha nada, como esperado.

## Limites conhecidos
- Crew suspensa de propósito: o guard segura as beads dela até a volta (caso wa-wbub / digo-wa). Este vigia só AVISA delas (mail); a devolução automática, quando vier, não pode tocar bead de crew suspensa.
- `gate:queued` / `gate:reviewing` são lidos pelo rótulo (como o `bead_state`): rótulo velho esconde um achado, e bead no gate sem rótulo pode aparecer (o nudge ressalva que bead já entregue ao gate fica como está).
- `bd comment` e `bd label` não movem `updated_at` (só `bd update` move): crew que só comenta parece parada na bead; por isso o achado exige também 2 h de pane parado.
- O `stuck-exec` do `production-stall-watchdog` continua só no HQ (ampliá-lo é outra mudança); `delivered` é só o rótulo `story:done` ("commit no main + gate ok" fica com o `merged-bead-janitor`).
