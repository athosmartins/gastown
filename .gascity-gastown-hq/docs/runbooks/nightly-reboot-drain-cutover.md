# Reboot noturno em modo DRENO — passagem para 23:00 (ga-a2v0bz)

**Estado:** código pronto e testado; falta (1) o merge pelo gate, (2) instalar a conferência
pós-boot, (3) UM comando `sudo` que move o horário do LaunchDaemon. Enquanto o passo 3 não
roda, nada muda: o reboot segue às 01:00 no fluxo legado, que esta entrega não alterou.

## Por que existe

O reboot noturno pulou 13 noites seguidas (`.gc/logs/nightly-reboot.log`). O bloqueio mais
frequente não era o scraper e sim o Guard 3 (`hq beads in_progress`): a cidade nunca para de
madrugada (revisores do gate, dogs, construtores), então "nenhum construtor vivo" nunca valia
nos ~85 min que o fluxo legado esperava. O scraper (00:01, rodadas de 8–20 h) cobria o resto.
Efeito medido: swap acumulando 5–7 GB, disco a 2 GB, backup do hq parado desde 29/09.

Pedido do Athos (01/10, P0): reiniciar **antes** do scraper. Desenho no bead ga-a2v0bz.

## O que muda

| Hora | O que acontece |
|---|---|
| 23:00 | O LaunchDaemon dispara `nightly-reboot.sh`. Ele grava o sinal de **dreno** (`~/.gastown/run/city-drain.level`); pilot, gate, refino-gate, auto-refino e context-check **param de admitir trabalho novo** (o que já está em curso termina). |
| 23:00–23:40 | Espera, re-carimbando o sinal a cada 5 min. |
| 23:40 | Só os guards de **SEGURANÇA** seguram o reboot, esperando até ~23:55: envio em voo (`central_sender_restart_safe.py`) e manutenção de Dolt (compact/gc/backup/table-swap). "Não consegui olhar" conta como **não seguro**. |
| 23:40 | Gate com marker, bead em `in_progress` e rodada do scraper viram **informativos**: vão pro log e pro snapshot `.gc/logs/nightly-reboot-pre-<data>.txt` como "o que este reboot corta". O gate re-enfileira, o reclaim devolve o bead, o scraper retoma pelo catch-up. |
| ~23:42 | **Re-checagem final** dos guards de segurança, logo antes do `shutdown -r now` (o veredito das 23:40 já tem minutos: sondas informativas, update do macOS e notify passam no meio, e o envio central não é travado pelo dreno). Um envio que começou nesse intervalo segura o reboot como um que já estava lá; se não liberar, é SKIP — e o streak continua contando. Depois `shutdown -r now`. O sinal de dreno carrega o boot-epoch: o próprio reboot o invalida, não há passo de limpeza que possa falhar. |
| pós-boot | `nightly-reboot-postcheck.sh` confere Dolt / envio / mapa / dreno (re-tenta ~20 min enquanto os serviços sobem) e manda `notify`: **"Reboot noturno OK"** (rotina: vai pro digest) ou **"pós-boot COM PROBLEMA"** (vai por **push**; também mail ao mayor, que depende do Dolt). |

Noite que não consegue reiniciar até ~23:55: **solta o dreno na hora**, registra SKIP (aviso **"Reboot noturno pulado"** por push) e segue o
streak/alarme de sempre (o alarme de N noites seguidas também vai por push). Uma noite falha nunca deixa a cidade congelada. Rodada do scraper
cortada 2 noites seguidas → mail ao mayor (o ps precisa saber que o corte virou rotina).

## Ordem OBRIGATÓRIA

O plist root executa o script **do checkout principal** (`/Users/athos/gt/.gascity-gastown-hq/scripts/nightly-reboot.sh`).
Se o horário for movido para 23:00 **antes** do merge, o script antigo acorda às 23:00, vê que
está fora da sua janela 01:00–01:19 e pula: noites perdidas, em silêncio.

1. **Merge** (gate). Conferir (com o bash do launchd, `/bin/bash` 3.2): `/bin/bash -n scripts/nightly-reboot.sh && /bin/bash scripts/nightly-reboot.selftest.sh | tail -1 && /bin/bash scripts/nightly-reboot.drain.selftest.sh | tail -1`
2. **Instalar a conferência pós-boot** (usuário, sem sudo; seguro a qualquer hora — sem pendência é no-op):
   ```bash
   cp /Users/athos/gt/.gascity-gastown-hq/scripts/com.gascity.nightly-reboot-postcheck.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.nightly-reboot-postcheck.plist
   bash /Users/athos/gt/.gascity-gastown-hq/scripts/nightly-reboot-postcheck.sh --now   # 4 linhas: dolt / sender / map / drain
   ```
3. **Mover o horário** (privilegiado — um dog não roda `sudo`; quem tem sudo roda):
   ```bash
   sudo /usr/libexec/PlistBuddy -c 'Set :StartCalendarInterval:Hour 23' /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
   sudo launchctl bootout system/com.gascity.nightly-reboot
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
   plutil -p /Library/LaunchDaemons/com.gascity.nightly-reboot.plist | grep -A3 StartCalendarInterval   # Hour => 23, Minute => 0
   ```
   `RunAtLoad` do plist é `false`: o `bootstrap` não dispara nada na hora.

## Verificar na primeira noite

`tail -f /Users/athos/gt/.gascity-gastown-hq/.gc/logs/nightly-reboot.log`

- 23:00 `drain mode: the city stops admitting new work until the reboot at 23:40`
- 23:40 `safety guards OK on attempt 1/16 ... rebooting with agent work possibly in flight`
- depois do boot, `postcheck: RESULT: all four checks ok` + aviso **"Reboot noturno OK"** (digest, não vibra)
- `informational: guardN ...: unknown TIMED OUT` ou `info: other rigs' in_progress counts TIMED OUT`:
  o bd/Dolt não respondeu a tempo (cada sonda ≤30 s, todas juntas ≤75 s). O reboot **sai mesmo
  assim** — um Dolt doente de madrugada é justamente quando o reboot mais importa — e o snapshot
  `nightly-reboot-pre-<data>.txt` registra a linha como `unknown`, não como `ok`. Se aparecer
  várias noites seguidas, o Dolt está lento de madrugada: investigar à parte (`gc dolt health`).
- `ERROR: alarm mail to mayor TIMED OUT` / `FAILED` e `ERROR: recording the skip ... TIMED OUT`: o
  aviso ao mayor não saiu (o contador/streak já estava gravado). Antes isso era silencioso.
- se algo ficou de pé: push **"pós-boot COM PROBLEMA"** com o check e o rótulo (`FAIL` = caiu,
  `unknown` = não consegui olhar). `nightly-reboot-postcheck.sh --now` repete a conferência a qualquer hora.

## Rollback

```bash
sudo /usr/libexec/PlistBuddy -c 'Set :StartCalendarInterval:Hour 1' /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
sudo launchctl bootout system/com.gascity.nightly-reboot
sudo launchctl bootstrap system /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
```
O fluxo legado das 01:00 continua no script, intacto. Para soltar uma cidade drenada à mão:
`rm ~/.gastown/run/city-drain.level` (o sinal também expira sozinho: ≤30 min sem re-carimbo,
teto de 90 min).

## Limites conhecidos (não escondidos)

- O guard de manutenção de Dolt enxerga os **wrappers** (`dolt-compact-routine.sh` etc.) e o
  CLI `dolt gc|backup|push|pull|fetch|table` por processo — não um `CALL dolt_gc()` digitado
  num SQL interativo.
- Ficam **sem prazo**, de propósito: `softwareupdate --install` (a instalação do update do macOS é
  longa por desenho e não pode ser cortada no meio), `softwareupdate --list --no-scan` (cache
  local), o `notify` (já tem limites próprios: curl 6 s, e-mail 45 s), `sync` e `sudo`. Tudo que fala
  com bd/Dolt entre o disparo e o `shutdown` tem prazo.
- O sinal de dreno é carimbado uma vez antes do update do macOS. Se a instalação passar de 30 min,
  os leitores o consideram velho e os despachantes voltam a admitir trabalho (falha aberta, por
  desenho): o que entrar nesse intervalo é cortado pelo reboot como qualquer trabalho em voo.
- **Roteamento do `notify`:** o padrão dele é o **digest silencioso**; `-p 4`/`-p 5` e "🚨" no
  título não mudam isso (medido com `NOTIFY_ROUTE_TEST=1`). Por isso os avisos de alarme — noite
  pulada, N noites seguidas, pós-boot COM PROBLEMA / não conferido — saem com `NOTIFY_FORCE_PUSH=1`,
  e os de rotina (reiniciando, OK, update) ficam no digest. Medido no `history.db` do próprio
  notify (04/09–01/10): dos 47 avisos "Reboot noturno…" que este script mandou, **47 foram pro
  digest e nenhum pro push** — inclusive os seis alarmes "🚨 N noites seguidas" (N = 2…12).
- O corte da rodada do scraper depende do catch-up do próprio rig (`--skip-done-today`) retomar
  no boot; a conferência pós-boot **não** verifica isso (é do dono do property_scrapers).
- A porta usada pelo `SELECT 1` de confirmação do Dolt vem de `BEADS_DOLT_PORT` (default no
  `gc-dolt-probe.sh`); só entra em jogo se três chamadas de `gc dolt health` falharem seguidas.
- Por que a sonda é chamada com `--robust`: com a cidade saturada (load 37, 01/10) o
  `gc dolt health` leva ~9 s e a sonda "crua" (12 s) já deu `unhealthy` para um Dolt vivo.
