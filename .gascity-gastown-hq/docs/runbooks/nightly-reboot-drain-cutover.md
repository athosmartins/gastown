# Reboot noturno em modo DRENO — passagem para 23:00 (ga-a2v0bz)

**Estado:** código pronto e testado; falta (1) o merge pelo gate, (2) instalar a conferência
pós-boot, (3) UM comando `sudo` que move o horário do LaunchDaemon. Enquanto o passo 3 não
roda, o reboot segue às 01:00 e os **guards e a espera do fluxo legado são os de sempre**. Mas o
merge (passo 1) **muda o que o script faz nessa noite das 01:00** — a lista real, conferida contra o
script de antes (`eae3207a8`), é esta:

1. **SKIP e alarme "N noites seguidas" vão por push** ("Reboot noturno pulado", "🚨 … noites seguidas
   sem reiniciar"). Antes iam pro digest silencioso (0 de 47 avisos deste script chegaram ao push).
   Uma noite pulada às ~02:27 passa a avisar na hora.
2. **O registro do skip tem prazo** (`record_skip_bounded`, 120 s): um `gc mail send` pendurado
   (Dolt doente) não prende mais a instância e a noite seguinte dispara.
3. **A contagem de `in_progress` por rig (informativa) tem prazo** (≤30 s por sonda, ≤75 s no total).
4. **Escreve o arquivo de pendência** `.gc/logs/nightly-reboot.pending` (`mode=legacy`): a conferência
   pós-boot passa a agir também depois do reboot das 01:00 e manda o "Reboot noturno OK" (isso, depois do passo 2).
5. **O streak é zerado logo antes do `shutdown`**, depois do aviso "Reiniciando" (antes: antes dos
   logs de disco/swap e do aviso).
6. **Shutdown aceito (rc 0): sai com 0** e registra `shutdown accepted`. Antes registrava sempre
   `ERROR: shutdown returned … reboot did NOT happen` e saía com 1, mesmo com a máquina caindo
   (essa linha nunca aparece nos logs das 12 noites que reiniciaram: o script morre antes de escrevê-la —
   o sistema manda TERM enquanto o shutdown roda; ver a linha das ~23:42 abaixo sobre o que isso faz com o sinal).
7. **Shutdown que falha (rc ≠ 0): a noite vira SKIP.** O streak e o contador de scraper cortado
   **voltam ao que eram** (arquivo ausente continua ausente), a noite entra no streak como pulada
   (+1: o streak **não** é zerado numa noite sem reboot), sai o push **"Reboot noturno FALHOU"**, a
   pendência e o sinal de dreno são removidos e o script sai com 1. Antes: só a linha de ERROR, com o
   streak já zerado.

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
| 23:40 | Só os guards de **SEGURANÇA** seguram o reboot, esperando até ~23:55: envio em voo (`central_sender_restart_safe.py`, rodado como o usuário via `sudo -u`, como o `notify` — como root ele poderia deixar `-shm`/`-wal` de root ao lado da fila do sender) e manutenção de Dolt (compact/gc/backup/table-swap). "Não consegui olhar" conta como **não seguro**. |
| 23:40 | Gate com marker, bead em `in_progress` e rodada do scraper viram **informativos**: vão pro log e pro snapshot `.gc/logs/nightly-reboot-pre-<data>.txt` como "o que este reboot corta". O gate re-enfileira, o reclaim devolve o bead, o scraper retoma pelo catch-up. |
| ~23:42 | **Re-checagem final** dos guards de segurança, logo antes do `shutdown -r now` (o veredito das 23:40 já tem minutos: sondas informativas, update do macOS e notify passam no meio, e o envio central não é travado pelo dreno). Um envio que começou nesse intervalo segura o reboot como um que já estava lá; se não liberar, é SKIP — e o streak continua contando. Só depois da re-checagem sai o aviso de rotina "Reiniciando às HH:MM" (digest) — uma noite pulada ali nunca disse "reiniciando". Depois `shutdown -r now`. O sinal de dreno carrega o boot-epoch: o próprio reboot o invalida, não há passo de limpeza que possa falhar. O script larga a posse do sinal (`DRAIN_ACTIVE=0`) **imediatamente antes** de chamar o shutdown, então o sinal **fica** no disco nos dois jeitos de sair da chamada: o rc 0 e o **TERM que o sistema manda ao script enquanto desliga** (o caminho que de fato roda numa noite que reinicia — o log não tem nenhuma linha depois do `shutdown -r now`; o trap de TERM vira `exit 143` e o trap de saída já não tem o que soltar). Soltá-lo seguraria a cidade a admitir trabalho segundos antes de cair. Se o shutdown **voltar** com rc ≠ 0 o sinal é solto na hora — antes do push e do registro do skip, que podem levar ~2 min —, o streak e o contador do scraper voltam ao que eram, a noite conta como pulada e sai o push **"Reboot noturno FALHOU"**. |
| pós-boot | `nightly-reboot-postcheck.sh` confere Dolt / envio / mapa / dreno (**mapa** = a ORIGEM em `127.0.0.1:8099` **e** o túnel cloudflared: job com PID + o `/ready` dele com ≥ 1 conexão de borda; o pior dos dois vale. A URL pública `mapa.urblink.com.br` **não** entra: o Cloudflare Access responde 302 na borda, com o mapa de pé ou não) (re-tenta ~20 min enquanto os serviços sobem) e manda `notify`: **"Reboot noturno OK"** (rotina: vai pro digest) ou **"pós-boot COM PROBLEMA"** (vai por **push**; também mail ao mayor, que depende do Dolt). É também **daqui** que sai o mail "scraper cortado N noites seguidas" (abaixo). |

Noite que não consegue reiniciar até ~23:55: **solta o dreno na hora**, registra SKIP (aviso **"Reboot noturno pulado"** por push) e segue o
streak/alarme de sempre (o alarme de N noites seguidas também vai por push). Uma noite falha nunca deixa a cidade congelada. Rodada do scraper
cortada 2 noites seguidas → mail ao mayor (o ps precisa saber que o corte virou rotina). **Quem manda é a conferência pós-boot, não o
reboot:** na hora de decidir nada foi cortado ainda (um shutdown que falha não corta nada, e o mail não se desfaz), e depois do
`shutdown -r now` nada que o script escreve sobrevive. O reboot só deixa o aviso devido na pendência (`scraper_cut_alarm=` e
`scraper_cut_reason=`); a conferência o manda ao confirmar que este boot é o do noturno. Um shutdown que falha **desfaz** o contador e
descarta o aviso junto com a pendência: não sai mail por corte que não houve.

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
   # esperado: `map ok: origin ok (http://127.0.0.1:8099/ answers HTTP 200); tunnel ok (... N edge connection(s) ready ...)`
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
- `postcheck: ERROR: mail to mayor TIMED OUT` / `FAILED` (no mesmo log) e `ERROR: recording the skip ... TIMED OUT`: o
  aviso ao mayor não saiu (o contador/streak já estava gravado). Antes isso era silencioso. Se o campo
  `scraper_cut_alarm` da pendência vier danificado, o log diz `... (not a number) — the scraper-cut alarm is NOT sent`.
- Noite em que o shutdown **falhou**: `ERROR: shutdown returned N — reboot did NOT happen`, depois
  `counters: skip streak put back to …` / `scraper-cut counter put back to …`, o push **"Reboot noturno FALHOU"**
  e `skip streak: N consecutive night(s)`. A cidade volta a admitir trabalho (dreno solto). Nenhum mail "scraper cortado".
- se algo ficou de pé: push **"pós-boot COM PROBLEMA"** com o check e o rótulo (`FAIL` = caiu,
  `unknown` = não consegui olhar). `nightly-reboot-postcheck.sh --now` repete a conferência a qualquer hora.

## Rollback

```bash
sudo /usr/libexec/PlistBuddy -c 'Set :StartCalendarInterval:Hour 1' /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
sudo launchctl bootout system/com.gascity.nightly-reboot
sudo launchctl bootstrap system /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
```
O fluxo legado das 01:00 continua no script, **com as 7 mudanças listadas no topo** (o rollback devolve o horário, não o
comportamento de antes do merge).

## Soltar uma cidade drenada à mão

Depende de o `nightly-reboot.sh` (quem grava o sinal) estar vivo — do disparo, 23:00, até o `shutdown`:

- **Script vivo** (o caso em que alguém quer soltar): `rm ~/.gastown/run/city-drain.level` **não basta**. O script
  regrava o sinal sem olhar se alguém o tirou — a cada ≤5 min na espera até 23:40 e a cada tentativa dos guards
  de segurança (60 s) — e não deixa linha no log dizendo que o `rm` foi desfeito: a cidade fica solta só até o
  próximo carimbo. O que funciona é matar o script com TERM:
  ```bash
  sudo launchctl kill TERM system/com.gascity.nightly-reboot
  ```
  O trap de saída dele (`drain_cleanup`) remove o sinal e o script sai: **a noite não reinicia**. Na espera das
  23:00–23:40 e nas sondas com prazo o TERM age na hora; numa chamada sem prazo (update do macOS, `notify`) só
  quando ela volta. **Exceção:** a partir do `shutdown -r now` (~23:42) o script já largou a posse do sinal, e
  um TERM nessa hora **não o remove** — a máquina está caindo e o boot-epoch o invalida; só um shutdown que
  volta com erro faz o próprio script soltá-lo.
- **Script já morto** (saiu, ou levou KILL e o trap não rodou — o `launchctl kill` acima responde
  `No process to signal.`): aí `rm ~/.gastown/run/city-drain.level` solta na hora, porque nada mais o regrava.
  Sem o `rm` o sinal expira sozinho: ≤30 min depois do último carimbo, teto de 90 min.

## Limites conhecidos (não escondidos)

- O guard de manutenção de Dolt enxerga, por processo: os **wrappers** (`dolt-compact-routine`,
  `dolt-gc-maintenance`, `dolt-gc-release-trigger`, `dolt-backup-reseed`, `dolt-backup-swap-repair`,
  `dolt-backup-residue-reclaim`, `dolt-offline-backup-sync`, `dolt-s3-backup` — o backup das 04:00 —
  e `dolt-restore-verify`) rodando em qualquer shell (`/bin/bash`, `/opt/homebrew/bin/bash`...), o CLI
  `dolt gc|backup|push|pull|fetch|table` e o `dolt ... sql -q '... CALL DOLT_GC/DOLT_BACKUP ...'`. **Não**
  enxerga um `CALL` digitado numa sessão SQL interativa já aberta, nem feito por outro cliente (`mysql`).
  O selftest (E12b) enumera todo `scripts/dolt-*.sh` e reprova um que não esteja no padrão nem numa lista
  explícita de "não é risco" — um wrapper novo tem que ser classificado.
- Ficam **sem prazo**, de propósito: `softwareupdate --install` (a instalação do update do macOS é
  longa por desenho e não pode ser cortada no meio), `softwareupdate --list --no-scan` (cache
  local), o `notify` (já tem limites próprios: curl 6 s, e-mail 45 s), `sync` e `sudo`. Tudo que fala
  com bd/Dolt entre o disparo e o `shutdown` tem prazo: TERM no prazo, ~2 s de folga e **KILL** (um processo que ignora o TERM não segura o reboot).
- Um TERM/KILL que caia entre a gravação dos contadores e a chamada do `shutdown` (escritas locais, a
  pendência e um `sync`: segundos) **não** desfaz os contadores da noite: de dentro do script isso é
  indistinguível do reboot derrubando o script. Quanto ao sinal: um TERM antes de `DRAIN_ACTIVE=0` o
  solta (o trap de saída roda); um TERM depois dele (é uma atribuição: instantes) o deixa no disco, e um
  KILL em qualquer ponto também, porque o trap não roda. Nos dois casos ele expira sozinho (≤30 min, teto 90 min).
- O sinal de dreno é carimbado uma vez antes do update do macOS. Se a instalação passar de 30 min,
  os leitores o consideram velho e os despachantes voltam a admitir trabalho (falha aberta, por
  desenho): o que entrar nesse intervalo é cortado pelo reboot como qualquer trabalho em voo.
- **Roteamento do `notify`:** o padrão dele é o **digest silencioso**; `-p 4`/`-p 5` e "🚨" no
  título não mudam isso (medido com `NOTIFY_ROUTE_TEST=1`). Por isso os avisos de alarme — noite
  pulada, N noites seguidas, pós-boot COM PROBLEMA / não conferido — saem com `NOTIFY_FORCE_PUSH=1`,
  e os de rotina (reiniciando, OK, update) ficam no digest. Medido no `history.db` do próprio
  notify (04/09–01/10): dos 47 avisos "Reboot noturno…" que este script mandou, **47 foram pro
  digest e nenhum pro push** — inclusive os seis alarmes "🚨 N noites seguidas" (N = 2…12).
- Os checks do pós-boot dizem o que olham, e nada além: **envio** = o job do launchd
  (`com.whatsapp.central-sender`) tem PID — prova que o processo está de pé, **não** que está
  enviando (o daemon é um laço sem porta nem heartbeat consumível daqui); **mapa** = a origem
  responde e o túnel tem conexão de borda — prova que o caminho existe, **não** que o Cloudflare
  Access deixa o Athos entrar (esse é o login dele). "Cidade de pé" é isso, não "tudo funcionando".
- O corte da rodada do scraper depende do catch-up do próprio rig (`--skip-done-today`) retomar
  no boot; a conferência pós-boot **não** verifica isso (é do dono do property_scrapers).
- A porta usada pelo `SELECT 1` de confirmação do Dolt vem de `BEADS_DOLT_PORT` (default no
  `gc-dolt-probe.sh`); só entra em jogo se três chamadas de `gc dolt health` falharem seguidas.
- Por que a sonda é chamada com `--robust`: com a cidade saturada (load 37, 01/10) o
  `gc dolt health` leva ~9 s e a sonda "crua" (12 s) já deu `unhealthy` para um Dolt vivo.
