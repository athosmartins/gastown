# Job que fecha sessão remota do Hetzner sem bead (hetzner-idle-session-reaper) · runbook

## Contents

• Por que existe · O que fecha e o que nunca fecha · Instalar e conferir · Desligar e retirar · Medido, lido, não testado

Bead ga-mu9k7m (P0, pedido do Mayor, 20/10). **PALIATIVO** até o patch do engine da ga-2hd02v.1.22 entrar na janela. **Mergeado ≠ vivo: nada aqui roda até o Mayor instalar o plist no mini.**

## Por que existe
O engine acorda de novo, 1 a 9 min depois, a sessão manual que o `idle_timeout` acabou de dormir (README em `docs/pending-engine-window/ga-2hd02v.1.22-manual-idle-timeout-stays-asleep.README.md`). Resultado medido pelo Mayor em 20/10: às 06:39 e às 13:0x as 3 sessões `dog-remote` ficaram vivas **sem nenhuma bead** (beads fechadas, `ocupadas: 0` no `hetzner-occupancy.jsonl`) e o Pilot deixou uma bead elegível no mini (`sem alias dog-remote-<n> livre`). Ele fechou à mão com `gc session close`; este job faz o mesmo sozinho.

## O que fecha e o que nunca fecha
`scripts/hetzner-idle-session-reaper.py`, a cada 600 s pelo launchd do mini. Duas leituras, cada uma com 3 estados (leu / não consegui ler / vale X). Templates: `dog-remote` e `gate-reviewer-remote` (`HETZNER_REAP_TEMPLATES`).
- **Fecha** (`gc --city <cidade> session close <id>`) a sessão que está **viva** (active/awake), **sem bead** aberta nem in_progress em nenhum dos nomes dela (id, session_name, name, alias), com o relógio de "sem bead" **> 900 s** (`HETZNER_REAP_GRACE_S`) e **vista viva e sem bead em 2 rodadas seguidas** (a sessão que o Pilot acabou de acordar para receber bead não é fechada na rodada em que ela é vista). O relógio (`desde`, em `.gc/hetzner-idle-reaper.state.json`) corre também enquanto ela dorme, porque o laço do engine a faz dormir e acordar; uma leitura em que ela segura bead, ou em que sumiu da lista, o apaga. Na prática o zumbi cai na 3ª leitura sem bead: 20 min depois da 1ª, e a 1ª vem até 10 min depois de a bead sair (20 a 30 min no total, nunca menos de 15).
- **Nunca fecha:** com bead aberta ou in_progress (as de infra entram: `--include-infra`); com `gc` ou `bd` ilegíveis, fora do ar, em timeout ou com envelope de erro (a leitura que falha nunca vira "sem bead": ninguém é fechado e o estado nem anda); com gente anexada; linha sem id ou com id `-`; `closed` ausente; outro template. **`wa-worker-remote` fica de fora de propósito:** a bead dele mora na loja da WA, que o `bd -C <cidade>` não lê, então "sem bead" não é provável (para incluí-lo falta uma leitura da loja WA).
- **Antes de cada close** o `bd` é lido DE NOVO: bead que chegou no meio da rodada salva a sessão (`"evento":"nao-fechada"`).
- **Registro:** `.gc/hetzner-idle-reaper.jsonl` (uma linha por sessão fechada, que falhou ao fechar ou salva pela releitura) e UMA linha `"tipo":"reaper"` no `.gc/hetzner-occupancy.jsonl` por rodada que fechou ou falhou (o vigia de ocupação só escreve nesse arquivo; nada o lê). A rodada imprime uma linha: `sessoes=N com_bead=N fechadas=N falhas=N ilegiveis=N`.

## Instalar e conferir
Mayor, depois do merge, no mini (a ordem importa: primeiro a leitura, depois o plist):
```bash
python3 scripts/hetzner-idle-session-reaper.py --dry-run   # 1 leitura de verdade, não fecha nem grava nada; sessoes= tem de bater com as dog-remote vivas (0 com sessões vivas = o template não casou: nada fecha)
launchctl bootout gui/$(id -u)/com.gascity.hetzner-idle-session-reaper 2>/dev/null
cp scripts/com.gascity.hetzner-idle-session-reaper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.hetzner-idle-session-reaper.plist
launchctl print gui/$(id -u)/com.gascity.hetzner-idle-session-reaper | grep -E 'state|runs|last exit'
```
Depois de 3 rodadas (~25 min): `grep reaper .gc/hetzner-occupancy.jsonl | tail`; zumbi fechado aparece com o id e o `ocioso_s`. Registro do job na política do `wait-for-dolt` e no `DPW_CRITICAL` (`isento`; padrão da ga-2hd02v.1.17): **ainda não feito nesta fatia**. Sem ele o plano lista o job como não classificado e o DPW não vigia o heartbeat; o job funciona igual (sem o Dolt o `bd` falha e ele não fecha nada).

## Desligar e retirar
- **Desligar sem descarregar:** `touch <cidade>/.gc/hetzner-idle-reaper.off` (a rodada seguinte só diz "desligado": não lê nem fecha). Voltar: apagar o arquivo.
- **Retirar quando o patch da ga-2hd02v.1.22 estiver vivo** (`gc session list --json` mostra as dog-remote ociosas `asleep`, e o `idle_killed` não é seguido de novo start sem bead): `launchctl bootout gui/$(id -u)/com.gascity.hetzner-idle-session-reaper`, apagar o plist de `~/Library/LaunchAgents`, e remover do repo o script, o selftest, o plist e este runbook.

## Medido, lido, não testado
- **Medido (selftest, `bash scripts/hetzner-idle-session-reaper.selftest.sh`):** gc e bd de mentira; o zumbi só fecha na 3ª leitura (20 min), bead aberta ou in_progress segura, gc/bd com falha ou lixo não fecham e não mexem no estado, `.off`, anexada, outros templates, a bead que chega antes do close, o laço dormir/acordar, o relógio que zera, linha sem id, close que falha, `--dry-run`, estado corrompido.
- **Lido do código, não visto ao vivo:** o formato de `gc session list --json` (campos `id`, `name`, `session_name`, `alias`, `template`, `state`, `closed`, `attached`) vem do vigia de ocupação e do `adhoc-session-reaper`; o valor do campo `template` das dog-remote **não foi visto** (o casamento aceita `dog-remote`, `x/dog-remote` e `x.dog-remote`; se não casar o job fica inerte, e o `--dry-run` acima mostra isso). A forma `bd list --include-infra --status open,in_progress --json --limit 0` é a de `dolt-compact-routine.sh` e do `approved-state-reconciler.py`; o `gc session close <id>` é o do `adhoc-session-reaper`.
- **Não testado:** nenhuma chamada ao `gc`/`bd` reais (o nó Hetzner só tem o atalho, que não passa `gc session list`) e nenhuma execução no python 3.9 do macOS.
