## Contents

- O que é · Como ver o que ele decidiu · Como desligar · O que ele NÃO faz · O que ainda não foi provado · Testar

# D4 — reinício guardado do mini (ga-1p1i5jr.4)

## O que é

O último degrau da escada de recuperação de disco (missão ga-1p1i5jr). Decisão do Athos em 01/11/2026 (AskUserQuestion na sessão do Mayor, citada na ga-1p1i5jr): **"A qualquer hora, com guardas"** — o mini reinicia sozinho se o disco ficar < 3 GB por 60 min (ou < 1,5 GB em duas leituras seguidas), só sem ligação em curso nem envio em voo, e avisa.

Quem decide o TEMPO é o orquestrador (`scripts/disk-recovery-ladder.sh`, ga-1p1i5jr.1). O D4 (`scripts/disk-recovery-d4-guarded-reboot.sh`) só roda quando ele chama, e RECONFERE tudo antes de agir. Contrato: `--run` / `--dry-run`, uma linha no stdout, saída 0 = agiu · 10 = nada a fazer ou uma guarda adiou · 20 = falhou · 30 = não consegui ler (não age).

## Como ver o que ele decidiu

- Uma linha por rodada: `tail -20 $GC_CITY_PATH/.gc/logs/disk-recovery-d4.log`
- Estado (marcas de reinício, espera, avisos): `cat $GC_CITY_PATH/.gc/disk-recovery-d4.state`
- Cada reinício deixa um registro `…/.gc/logs/disk-recovery-d4-reboot-<data>.txt` (quando, disco, swap, guardas) — é o que torna o reinício atribuível (um reinício sem dono já virou investigação em rig alheio, 26-29/09).
- O que ele FARIA agora, sem agir nem avisar: `bash scripts/disk-recovery-d4-guarded-reboot.sh --dry-run`. Roda as leituras de verdade (disco, FileVault, autologin, postcheck, as 4 guardas) e sai 0 ("reiniciaria"), 10 (adiado ou nada a fazer), 20 (pré-checagem reprovou) ou 30 (não consegui ler).

## Como desligar

`touch $GC_CITY_PATH/.gc/disk-recovery.off` — o MESMO interruptor do orquestrador; vale também durante os 60 s de carência depois do aviso (o aviso diz o caminho). Apague o arquivo para religar.

## As guardas (todas precisam estar "ok"; não consegui ler = não reinicia)

| Guarda | Fonte | Bloqueia quando |
|---|---|---|
| ligação em curso | `disk-recovery-d4-calls-in-flight.py` (pix `dialing`/`bridged`; voicebot `live`) | há linha em curso com menos de 4 h |
| envio em voo | `whatsapp_automation/scripts/central_sender_restart_safe.py` | rc 1 com a mensagem do script (rc 2 e traceback = não sei) |
| manutenção do Dolt | padrão extraído do `nightly-reboot.sh` (`DOLT-MAINT-PATTERN-*`) | `pgrep` acha `dolt gc/backup/...` |
| rodada do scraper | `scraper_daily_state` extraída do `nightly-reboot.sh` (`SCRAPER-DAILY-GUARD-*`) | há rodada `running` |

As duas últimas são o MESMO código do reinício noturno, extraído pelas sentinelas. Se alguém mexer nas sentinelas do `nightly-reboot.sh`, a guarda vira "não sei" (rc 30) e o D4 para de reiniciar — o aviso "o D4 não consegue ler uma guarda" chega no celular. Corrija o `nightly-reboot.sh` ou ajuste a extração.

Por que ligação em curso é lida pelo script próprio e não por `live_calls()`: as duas funções devolvem `[]` em QUALQUER erro, então "não consegui ler" e "não há ligação" seriam o mesmo valor.

## Cooldown e laço

1 reinício automático a cada 6 h, 2 por 24 h, mini no ar há ≥ 2 h (qualquer causa), 30 min entre pedidos que não derrubaram o mini, 10 min de espera depois de uma guarda adiar. Com o disco ainda baixo depois de um reinício nosso o D4 NÃO reinicia de novo: escala UMA vez por reinício (notify -p 5 + mail ao Mayor). O orquestrador tem a escalada dele também (bloqueia o D4 por 6 h depois de um rc 0).

## O que ele NÃO faz

- Não usa `sudo` (não há sudoers; `Bash(sudo:*)` é "ask"). Pede o reinício pelo MESMO AppleEvent dos reinícios manuais do Mayor: `osascript` → `loginwindow` `aevtrrst`.
- Não espera os beads em `in_progress` nem os markers do gate (o `--check-guards` inteiro bloquearia para sempre, e o reinício noturno em modo dreno também decide só pelas guardas de segurança). Os markers voltam sozinhos à fila e o inflight-reclaim-guard recolhe as claims.
- Não faz o notify/mail de rc 0/20: isso é do orquestrador.

## O que ainda não foi provado

- **Se a Automação do macOS libera o envio do AppleEvent na cadeia do launchd do orquestrador.** De uma sessão de agente a sonda `AEDeterminePermissionToAutomateTarget` dá -1744 ("pediria consentimento") e o reinício do Mayor funciona mesmo assim, então a sonda não serve de preditor. Se o pedido falhar na produção, o D4 sai 20, desfaz a marca e avisa. A prova real é o canário do D5 (ga-1p1i5jr.5): um reinício de verdade, de dia, com o Athos avisado.
- Que o postcheck pós-boot reporta bem um reinício que NÃO foi o noturno: ele só age com o arquivo de pendência do `nightly-reboot.sh`; depois de um reinício do D4 ele sai em silêncio. A conferência pós-boot do D4 hoje é: o orquestrador relê o disco e escala se seguir baixo.

## Testar

`bash scripts/disk-recovery-d4-guarded-reboot.selftest.sh` — shutdown SIMULADO (nunca reinicia), ~110 verificações. Com o mini a load 40 leva ~10 min; rode com teto de escrita: `( ulimit -f 524288; bash scripts/disk-recovery-d4-guarded-reboot.selftest.sh )`.
