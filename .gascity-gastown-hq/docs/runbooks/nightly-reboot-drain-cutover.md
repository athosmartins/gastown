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
| ~23:42 | `shutdown -r now`. O sinal de dreno carrega o boot-epoch: o próprio reboot o invalida, não há passo de limpeza que possa falhar. |
| pós-boot | `nightly-reboot-postcheck.sh` confere Dolt / envio / mapa / dreno (re-tenta ~20 min enquanto os serviços sobem) e manda `notify`: **"Reboot noturno OK"** ou **"pós-boot COM PROBLEMA"** (neste caso também mail ao mayor). |

Noite que não consegue reiniciar até ~23:55: **solta o dreno na hora**, registra SKIP e segue o
streak/alarme de sempre. Uma noite falha nunca deixa a cidade congelada. Rodada do scraper
cortada 2 noites seguidas → mail ao mayor (o ps precisa saber que o corte virou rotina).

## Ordem OBRIGATÓRIA

O plist root executa o script **do checkout principal** (`/Users/athos/gt/.gascity-gastown-hq/scripts/nightly-reboot.sh`).
Se o horário for movido para 23:00 **antes** do merge, o script antigo acorda às 23:00, vê que
está fora da sua janela 01:00–01:19 e pula: noites perdidas, em silêncio.

1. **Merge** (gate). Conferir: `bash -n scripts/nightly-reboot.sh && bash scripts/nightly-reboot.selftest.sh | tail -1`
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
- depois do boot, `postcheck: RESULT: all four checks ok` + push **"Reboot noturno OK"**
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
- O corte da rodada do scraper depende do catch-up do próprio rig (`--skip-done-today`) retomar
  no boot; a conferência pós-boot **não** verifica isso (é do dono do property_scrapers).
- A porta usada pelo `SELECT 1` de confirmação do Dolt vem de `BEADS_DOLT_PORT` (default no
  `gc-dolt-probe.sh`); só entra em jogo se três chamadas de `gc dolt health` falharem seguidas.
- Por que a sonda é chamada com `--robust`: com a cidade saturada (load 37, 01/10) o
  `gc dolt health` leva ~9 s e a sonda "crua" (12 s) já deu `unhealthy` para um Dolt vivo.
