## Contents

- O que é · Como ver o que ele decidiu · Como desligar · As guardas · Cooldown e laço · O que ele NÃO faz · Limites conhecidos · O que ainda não foi provado · Testar

# D4 — reinício guardado do mini (ga-1p1i5jr.4)

## O que é

O último degrau da escada de recuperação de disco (missão ga-1p1i5jr). Decisão do Athos em 01/11/2026 (AskUserQuestion na sessão do Mayor, citada na ga-1p1i5jr): **"A qualquer hora, com guardas"** — o mini reinicia sozinho se o disco ficar < 3 GB por 60 min (ou < 1,5 GB em duas leituras seguidas), só sem ligação em curso nem envio em voo, e avisa. A causa que motivou: em 01/11 o disco não estava cheio de arquivo, a RAM virou swap (2-4 GB livres por 5 h) e só um reinício devolve o swap.

Quem decide o TEMPO é o orquestrador (`scripts/disk-recovery-ladder.sh`, ga-1p1i5jr.1). **Em 01/11 ele ainda NÃO está na `main`** (a bead estava na fila do gate; o script só existe na branch `feat/ga-1p1i5jr.1-disk-recovery-ladder`): até ele entrar, nada chama o D4 sozinho e ele só roda se alguém o executar à mão. Confira `git ls-tree origin/main --name-only -r | grep disk-recovery-ladder` antes de contar com a escada. O D4 (`scripts/disk-recovery-d4-guarded-reboot.sh`) só roda quando chamado e RECONFERE tudo antes de agir. Contrato: `--run` / `--dry-run`, UMA linha no stdout, saída **0** = agiu · **10** = nada a fazer ou uma guarda adiou · **20** = falhou · **30** = não consegui ler (não age) · **2** = uso. Com `--run` o pedido de reinício derruba o próprio D4, então um reinício que deu certo normalmente NÃO imprime linha (o processo morre por TERM).

## Como ver o que ele decidiu

- Uma linha `resultado rc=… — D4: …` por rodada: `tail -20 $GC_CITY_PATH/.gc/logs/disk-recovery-d4.log` (o log traz também as guardas lidas e, num reinício, a linha `REINÍCIO AUTOMÁTICO … marca=… livre=… swap=…`, que é o que torna o reinício atribuível).
- Estado: `cat $GC_CITY_PATH/.gc/disk-recovery-d4.state` — `reboots=` (marcas de reinício em epoch, guardadas por 7 dias), `defer_until=` (não tenta antes disto), `defer_notify_ts=` (último aviso de adiamento), `esc_for=` (reinício para o qual a escalada já saiu).
- O que ele FARIA agora, sem agir, sem avisar e sem gravar estado: `bash scripts/disk-recovery-d4-guarded-reboot.sh --dry-run`. Com o disco acima do limiar ele sai 10 já no passo do disco; para ver as guardas mesmo assim, simule só a leitura do disco: `DR4_FREE_MB_OVERRIDE=2000 DR4_LOG=/tmp/d4.log bash scripts/disk-recovery-d4-guarded-reboot.sh --dry-run`.
- Estado ilegível = o D4 recusa agir (rc 30) até alguém consertar. Apagar o arquivo vale como "primeira vez" e ZERA o cooldown e o teto: faça só sabendo disso.

## Como desligar

`touch $GC_CITY_PATH/.gc/disk-recovery.off` — o MESMO interruptor do orquestrador; vale também durante os 60 s de carência depois do aviso (o aviso diz o caminho). Apague o arquivo para religar.

## As guardas

Todas precisam estar "ok"; "não consegui ler" nunca reinicia. Todas são avaliadas (uma linha mostra tudo o que está no caminho); bloqueio vence "não sei".

| Guarda | Fonte | Bloqueia quando |
|---|---|---|
| ligação em curso | `disk-recovery-d4-calls-in-flight.py` (pix `dialing`/`bridged`; voicebot `live`) | há linha em curso com menos de 4 h (`DR4_CALL_MAX_AGE_MIN`); mais velha é órfã, não segura mas é contada |
| envio em voo | `whatsapp_automation/scripts/central_sender_restart_safe.py` | rc 1 COM a mensagem do script (rc 2 e traceback = não sei) |
| manutenção do Dolt | padrão extraído do `nightly-reboot.sh` (`DOLT-MAINT-PATTERN-*`) | `pgrep` acha `dolt gc/backup/…` |
| rodada do scraper | `scraper_daily_state` extraída do `nightly-reboot.sh` (`SCRAPER-DAILY-GUARD-*`) | há rodada `running` |

As duas últimas são o MESMO código do reinício noturno, extraído pelas sentinelas. Sentinela ausente, mudada ou **duplicada**, ou o arquivo ilegível = "não sei": o D4 para de reiniciar (rc 30) e o push "o D4 não consegue ler uma guarda" chega no celular. Corrija o `nightly-reboot.sh` ou a extração.

A ligação é lida pelo script próprio, e não por `live_calls()`, porque as duas funções do pix e do voicebot devolvem `[]` em QUALQUER erro: "não consegui ler" e "não há ligação" seriam o mesmo valor.

Antes das guardas há uma **pré-checagem**: FileVault desligado (e sem habilitação adiada), autologin do MESMO usuário do console e o postcheck pós-boot (`com.gascity.nightly-reboot-postcheck`) carregado; sem `DR4_REBOOT_CMD`, o `osascript` precisa existir. Reprovou = rc 20; não consegui ler = rc 30. Vale também no `--dry-run`.

## Cooldown e laço

1 reinício automático a cada 6 h e no máximo 2 por 24 h; mini no ar há ≥ 2 h (por qualquer causa); 10 min de espera depois que uma guarda adiou; 30 min depois de um pedido que não derrubou o mini. Marca no futuro (relógio voltou) conta como cooldown. Com o disco ainda baixo depois de um reinício nosso o D4 NÃO reinicia de novo: escala UMA vez por reinício (notify -p 5 + mail ao Mayor). O orquestrador, quando entrar, tem a escalada dele também (na branch dele: `D4_COOLDOWN_S 21600`, `escalate_d4_cap`, não chama o D4 por 6 h depois de um rc 0).

O **aviso antes de reiniciar é condição**, não cortesia: push -p 5 com entrega CONFIRMADA; se o push não foi confirmado, mail ao Mayor; se os dois falharem, rc 30 e NÃO reinicia (tenta de novo em 10 min). Depois, 60 s de carência (o interruptor ainda aborta), releitura do disco e das guardas, e só então a marca é gravada, conferida e o pedido sai.

Números ilegíveis em `DR4_*` (letra, mais de 9 dígitos) caem no padrão e o log diz `variável(is) DR4_ que não são número caíram no padrão`; nunca viram "sem limite".

## O que ele NÃO faz

- Não usa `sudo` (não há sudoers). Pede o reinício pelo MESMO AppleEvent dos reinícios manuais do Mayor: `osascript` → `loginwindow` `aevtrrst`.
- Não espera os beads em `in_progress` nem os markers do gate (o `--check-guards` inteiro bloquearia para sempre). Os markers voltam sozinhos à fila e o inflight-reclaim-guard recolhe as claims.
- Não faz o notify/mail de rc 0/20 do orquestrador (isso é dele, quando entrar). O aviso ANTES do reinício e os avisos de falha/adiamento são do próprio D4.

## Limites conhecidos

Apontados pelo revisor do gate (ga-24wp723), fora do escopo desta fatia de teste (o D4 não foi mexido aqui). Nenhum reinicia o mini errado: todos caem do lado inerte ou custam um aviso a mais.

- **"Ainda no ar" ≠ "não vai cair".** Se o mini continua no ar 180 s depois do pedido, a marca é solta (rc 20, nova tentativa em 30 min). Um desligamento lento (app segurando o logout) pode terminar depois; aí o cooldown e a escalada DESSA queda se perdem. O piso de 2 h de uptime ainda segura o laço. Conserto proposto: marca "pendente" conferida pelo `kern.boottime` na rodada seguinte.
- **Depois da carência a pré-checagem não se repete** (só o disco e as guardas são relidos).
- **Releitura oscilando no limiar** (disco recuperou/guarda ilegível sem `defer_until`) pode reenviar o push "reiniciando em 60 s" a cada rodada do orquestrador.

## O que ainda não foi provado

- **Se a Automação do macOS libera o envio do AppleEvent na cadeia do launchd do orquestrador.** De uma sessão de agente a sonda de permissão dá -1744 e o reinício do Mayor funciona mesmo assim, então ela não prediz. Se o pedido falhar na produção o D4 sai 20, desfaz a marca e avisa. A prova real é o canário do D5 (ga-1p1i5jr.5): um reinício de verdade, de dia, com o Athos avisado.
- **O postcheck pós-boot depois de um reinício que NÃO foi o noturno:** ele só age com o arquivo de pendência do `nightly-reboot.sh`; depois de um reinício do D4 sai em silêncio. A conferência pós-boot do D4 é o orquestrador reler o disco e escalar se seguir baixo.
- Medido em 01/11 21:15 (`--dry-run` com só a leitura de disco simulada, tudo mais real): pré-checagem passou e as quatro guardas leram `calls=ok · sender=ok · dolt=ok · scraper=ok`, com o leitor de verdade nos bancos de verdade; nenhum estado, trava ou aviso foi criado.

## Testar

`bash scripts/disk-recovery-d4-guarded-reboot.selftest.sh` — shutdown SIMULADO (nunca reinicia; `DR4_NO_REAL_REBOOT=1` vale em todos os cenários), 378 verificações, ~8 min no mini a load alto (7m36s medido em 01/11). Rode com teto de escrita: `$GC_CITY_PATH/scripts/heavy-guard.sh --what selftest-d4 --max-file-mb 512 -- bash scripts/disk-recovery-d4-guarded-reboot.selftest.sh`. No nó Linux (`mbp-run.sh --repo hq`) dá 1 falha esperada, a trava com pid reaproveitado (o D4 usa o `stat -f %m` do macOS): no macOS, que é onde o D4 roda, passa.

Para provar que o teste pega defeito: `DR4_ST_SUT=<cópia mutada do D4> D4_ST_ONLY='^nt_|^cool$' bash scripts/…selftest.sh` roda só esses cenários contra a cópia. Cada mutante (uma quebra na cópia) tem de reprovar.
