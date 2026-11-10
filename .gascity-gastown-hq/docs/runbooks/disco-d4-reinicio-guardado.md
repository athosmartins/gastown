## Contents

- O que é · Como ver o que ele decidiu · Como desligar · As guardas · Cooldown e laço · O que ele NÃO faz · Pedido pendente · Estado terminal · Limites conhecidos · O que ainda não foi provado · Testar

# D4 — reinício guardado do mini (ga-1p1i5jr.4)

## O que é

O último degrau da escada de recuperação de disco (missão ga-1p1i5jr). Decisão do Athos em 01/11/2026 (AskUserQuestion na sessão do Mayor, citada na ga-1p1i5jr): **"A qualquer hora, com guardas"** — o mini reinicia sozinho se o disco ficar < 3 GB por 60 min (ou < 1,5 GB em duas leituras seguidas), só sem ligação em curso nem envio em voo, e avisa. A causa que motivou: em 01/11 o disco não estava cheio de arquivo, a RAM virou swap (2-4 GB livres por 5 h) e só um reinício devolve o swap.

Quem decide o TEMPO é o orquestrador (`scripts/disk-recovery-ladder.sh`, ga-1p1i5jr.1). **Em 01/11 ele ainda NÃO está na `main`** (a bead estava na fila do gate; o script só existe na branch `feat/ga-1p1i5jr.1-disk-recovery-ladder`): até ele entrar, nada chama o D4 sozinho e ele só roda se alguém o executar à mão. Confira `git ls-tree origin/main --name-only -r | grep disk-recovery-ladder` antes de contar com a escada. O D4 (`scripts/disk-recovery-d4-guarded-reboot.sh`) só roda quando chamado e RECONFERE tudo antes de agir. Contrato: `--run` / `--dry-run` / `--resume` (solta a pausa de envio do estado terminal; o maestro o chama a cada rodada), UMA linha no stdout, saída **0** = agiu · **10** = nada a fazer ou uma guarda adiou · **20** = falhou · **30** = não consegui ler (não age) · **2** = uso. Com `--run` o pedido de reinício derruba o próprio D4, então um reinício que deu certo normalmente NÃO imprime linha (o processo morre por TERM).

## Como ver o que ele decidiu

- Uma linha `resultado rc=… — D4: …` por rodada: `tail -20 $GC_CITY_PATH/.gc/logs/disk-recovery-d4.log` (o log traz também as guardas lidas e, num reinício, a linha `REINÍCIO AUTOMÁTICO … marca=… livre=… swap=…`, que é o que torna o reinício atribuível).
- Estado: `cat $GC_CITY_PATH/.gc/disk-recovery-d4.state` — `reboots=` (marcas de reinício em epoch, guardadas por 7 dias), `defer_until=` (não tenta antes disto), `defer_notify_ts=` (último aviso de adiamento), `esc_for=` (reinício para o qual a escalada já saiu), `sp_mark=` (epoch da pausa de envio NOSSA ainda em aberto; 0 = nenhuma: ver "Estado terminal").
- Estado terminal no log: `grep -E 'guarda de envio: o python não respondeu|PAUSANDO|esvaziamento|marca da pausa|retomada' $GC_CITY_PATH/.gc/logs/disk-recovery-d4.log`.
- O que ele FARIA agora, sem agir, sem avisar e sem gravar estado: `bash scripts/disk-recovery-d4-guarded-reboot.sh --dry-run`. Com o disco acima do limiar ele sai 10 já no passo do disco; para ver as guardas mesmo assim, simule só a leitura do disco: `DR4_FREE_MB_OVERRIDE=2000 DR4_LOG=/tmp/d4.log bash scripts/disk-recovery-d4-guarded-reboot.sh --dry-run`.
- Estado ilegível = o D4 recusa agir (rc 30) até alguém consertar. Apagar o arquivo vale como "primeira vez" e ZERA o cooldown e o teto: faça só sabendo disso.

## Como desligar

`touch $GC_CITY_PATH/.gc/disk-recovery.off` — o MESMO interruptor do orquestrador; vale também durante os 60 s de carência depois do aviso (o aviso diz o caminho). Apague o arquivo para religar.

## As guardas

Todas precisam estar "ok"; "não consegui ler" nunca reinicia. Todas são avaliadas (uma linha mostra tudo o que está no caminho); bloqueio vence "não sei".

| Guarda | Fonte | Bloqueia quando |
|---|---|---|
| ligação em curso | `disk-recovery-d4-calls-in-flight.py` (pix `dialing`/`bridged`; voicebot `live`) | há linha em curso com menos de 4 h (`DR4_CALL_MAX_AGE_MIN`); mais velha é órfã, não segura mas é contada |
| envio em voo | `whatsapp_automation/scripts/central_sender_restart_safe.py`; se ele não responde, a leitura barata (`sqlite3` no `queue.db`: ver "Estado terminal") | rc 1 COM a mensagem do script (rc 2 e traceback = não sei), ou `sending` > 0 na leitura barata |
| manutenção do Dolt | padrão extraído do `nightly-reboot.sh` (`DOLT-MAINT-PATTERN-*`) | `pgrep` acha `dolt gc/backup/…` |
| rodada do scraper | `scraper_daily_state` extraída do `nightly-reboot.sh` (`SCRAPER-DAILY-GUARD-*`) | há rodada `running` |

As duas últimas são o MESMO código do reinício noturno, extraído pelas sentinelas. Sentinela ausente, mudada ou **duplicada**, ou o arquivo ilegível = "não sei": o D4 para de reiniciar (rc 30) e o push "o D4 não consegue ler uma guarda" chega no celular. Corrija o `nightly-reboot.sh` ou a extração.

A ligação é lida pelo script próprio, e não por `live_calls()`, porque as duas funções do pix e do voicebot devolvem `[]` em QUALQUER erro: "não consegui ler" e "não há ligação" seriam o mesmo valor.

Antes das guardas há uma **pré-checagem**: FileVault desligado (e sem habilitação adiada), autologin do MESMO usuário do console e o postcheck pós-boot (`com.gascity.nightly-reboot-postcheck`) carregado; sem `DR4_REBOOT_CMD`, o `osascript` precisa existir. Reprovou = rc 20; não consegui ler = rc 30. Vale também no `--dry-run`.

## Cooldown e laço

1 reinício automático a cada 6 h e no máximo 2 por 24 h; mini no ar há ≥ 2 h (por qualquer causa); 10 min de espera depois que uma guarda adiou; 30 min depois de um pedido que não derrubou o mini (a marca fica PENDENTE e a rodada seguinte confere o `kern.boottime`: ver "Pedido pendente"). Marca no futuro (relógio voltou) conta como cooldown. Com o disco ainda baixo depois de um reinício nosso o D4 NÃO reinicia de novo: escala UMA vez por reinício (notify -p 5 + mail ao Mayor). O orquestrador, quando entrar, tem a escalada dele também (na branch dele: `D4_COOLDOWN_S 21600`, `escalate_d4_cap`, não chama o D4 por 6 h depois de um rc 0).

O **aviso antes de reiniciar é condição**, não cortesia: push -p 5 com entrega CONFIRMADA; se o push não foi confirmado, mail ao Mayor; se os dois falharem, rc 30 e NÃO reinicia (tenta de novo em 10 min). Só o rc 0 do `notify` conta como entregue: segurado até as 7 h (rc 10, silêncio de 22 h às 7 h), repetido em menos de 30 min (11), resumo ou teto global de pushes por hora (12) e erro de transporte caem no mail, então de madrugada o mail é o ÚNICO aviso. O mail vai **sem `--from`** (o remetente é a identidade padrão do engine: `human` sob o launchd, a própria sessão numa sessão) e traz a origem no corpo. O engine só aceita `--from` de `human`, `controller` ou de uma sessão que exista, e o `--from disk-recovery-d4` que o D4 usava até 08/11 falhava SEMPRE (`invalid sender "": session not found`): com o push barrado pelo teto (rc 12) o D4 saía rc 30 e nunca reiniciava (ga-hp9pwtr). Depois, 60 s de carência (o interruptor ainda aborta), releitura do disco, da pré-checagem e das guardas, e só então a marca é gravada, conferida e o pedido sai. Cancelou DEPOIS do aviso (disco recuperou, pré-checagem reprovou ou ilegível, guarda bloqueou ou ilegível) = espera de 10 min gravada, para a rodada seguinte não reenviar o aviso "reiniciando em 60 s" a cada tick enquanto a leitura oscila no limiar; o interruptor ligado não grava espera (é um humano mandando calar).

Números ilegíveis em `DR4_*` (letra, mais de 9 dígitos) caem no padrão e o log diz `variável(is) DR4_ que não são número caíram no padrão`; nunca viram "sem limite".

## O que ele NÃO faz

- Não usa `sudo` (não há sudoers). Pede o reinício pelo MESMO AppleEvent dos reinícios manuais do Mayor: `osascript` → `loginwindow` `aevtrrst`.
- Não espera os beads em `in_progress` nem os markers do gate (o `--check-guards` inteiro bloquearia para sempre). Os markers voltam sozinhos à fila e o inflight-reclaim-guard recolhe as claims.
- Não faz o notify/mail de rc 0/20 do orquestrador (isso é dele, quando entrar). O aviso ANTES do reinício e os avisos de falha/adiamento são do próprio D4.

## Pedido pendente

(ga-1p1i5jr.4.3) "Ainda no ar 180 s depois do pedido" quer dizer que o mini AINDA não caiu, não que não vai cair: um app segurando o logout termina o desligamento depois. Por isso a marca do reinício **não é solta** nessa hora: ela fica na lista (segura cooldown de 6 h e teto de 2 por 24 h) e o estado guarda `pending_mark` e `pending_boot` (o `kern.boottime` de antes do pedido). A rodada SEGUINTE decide, antes de qualquer cooldown olhar a marca:

- `kern.boottime` mudou (mais de `DR4_BOOT_TOL_S`, 300 s, em módulo): o mini reiniciou depois do pedido, a marca era verdadeira e FICA (cooldown, teto e escalada passam a valer); a pendência é encerrada.
- `kern.boottime` igual e antes de marca + 30 min: espera (rc 10, "PENDENTE"), sem pedir de novo, sem escalar, sem mail.
- `kern.boottime` igual e passou marca + 30 min: o mini NÃO reiniciou; solta a marca e segue o fluxo normal (pode pedir de novo).
- Disco recuperado vence a espera, e a pendência é resolvida mesmo assim na mesma rodada.
- Estado com `pending_mark` sem `pending_boot` (ou não numérico) = rc 30, NÃO age: sem o boot de referência não há como dizer "mudou" nem "igual". Estado de antes desta fatia (sem as chaves) lê como "sem pendência".
- Se o D4 não conseguir gravar a pendência, a marca (já gravada e conferida) fica como reinício comum: bloqueia por 6 h, o lado inerte.

## Estado terminal (ga-1p1i5jr.10)

**10/11.** O swap foi de 0,7 para 4,6 GB (05:30 → 07:58) e o livre de 2,6 GB para 167 MB. O D2 (06:30) e o D3 (06:57 e 07:30) estouraram os 900 s do maestro; o D4 (07:25) leu 185 MB livres e devolveu
rc 30: a guarda de envio (`central_sender_restart_safe.py`, `GUARD_TIMEOUT_S` 60 s) não respondeu sob thrash, "não sei", não age. O mini travou sozinho às 08:01:50 (pânico do watchdog), sem dreno: o estado "não consigo
ler" era exatamente o estado em que a máquina cai, e o D4 ficava inerte nele.

**Terminal** = livre < 500 MB (`DR4_TERMINAL_MB`) OU livre < 1,5 GB com `DR4_HARD_STREAK` ≥ 2 (as leituras seguidas que o maestro contou e passa ao D4; sem a variável, só vale o piso de 500 MB). O que muda, e só aí:

| Guarda | Em qualquer estado do disco | Em estado terminal |
|---|---|---|
| envio em voo | o python primeiro (é o árbitro: descarta a linha `sending` órfã). Se ele não respondeu (prazo, traceback, rc estranho, ausente), a **leitura barata** responde: `sqlite3` direto no `queue.db` (`COUNT` das linhas `sending`; sem python, sem import, sem rede; prazo `DR4_CHEAP_S`, 25 s). 0 = ok; N > 0 = em voo (adia); ilegível = rc 30. Ela conta TODA linha `sending`, inclusive a órfã: nunca devolve menos que o python | se a barata TAMBÉM não leu: **pausa o envio** (`outreach_config.system_paused=1`, `system_paused_by` "disk-recovery-d4: …"), lê a fila (barata) a cada 10 s por até `DR4_DRAIN_S` (150 s) e então reinicia: 0 em voo lido, ou ilegível o tempo todo ("por construção"). Em voo lido até o fim = adia (rc 10) |
| ligação em curso | ilegível = rc 30 | ilegível = **aviso + reinício** (o travamento derruba a ligação de qualquer jeito). LIDA em curso continua bloqueando |
| Dolt, scraper | ilegível = rc 30 | idem: não são aceitos ilegíveis. Bloqueio lido bloqueia |

O que isto NÃO muda: a decisão do Athos (01/11) de só reiniciar sem ligação em curso nem envio em voo. Bloqueio LIDO vence qualquer aceitação (um bloqueio + um ilegível = rc 10 e NADA é pausado), e pausa que não leio de volta
= rc 30, não reinicia.

**A pausa** é uma escrita condicional (só se `system_paused` está 0) na MESMA chave do painel, no `demand_assignments.db`, lida de volta antes de seguir. Ela é NOSSA só se o `system_paused_by` começa com `disk-recovery-d4:`;
pausa de outro dono e linha ausente (o WA lê ausente como PAUSADO) nunca são tocadas nem soltas. A marca `sp_mark` vai ao estado ANTES da escrita (marca sem pausa é inerte; pausa sem marca seria o envio parado para sempre). O aviso
-p 5 diz que o envio foi pausado e que só volta depois do boot. **Quem solta:** o próprio D4 em toda saída normal que não pediu o reinício (disco recuperou, interruptor ligado na carência, guarda mudou, pausa não confirmada…); depois do
pedido de reinício, o `--resume` (o maestro o chama a cada rodada): sem pedido pendente solta na hora (depois do boot); com pedido pendente espera o `kern.boottime` mudar ou a espera de 30 min vencer; só solta o que ainda é nosso, lido de volta.
rc do `--resume`: 0 soltou · 10 nada a retomar (calado) ou ainda segurando · 20 não soltou (despausar à mão: `outreach_config.system_paused=0` ou o painel) · 30 não li.

## Limites conhecidos

Os três achados de código do revisor do gate (ga-24wp723) foram fechados na ga-1p1i5jr.4.3 (pedido pendente acima; pré-checagem repetida depois da carência; espera de 10 min depois de cancelar). O que continua valendo:

- **`system_paused` segura só o PRIMEIRO CONTATO** (`source=demand_outreach`): resposta, campanha e manual seguem enviando. "Esvaziado" vale para o primeiro contato; o aviso diz "PRIMEIRO CONTATO". Um envio de outra fonte pode estar em voo quando o D4 reinicia com o envio ilegível. O `queue.db` por inteiro só se prova pela leitura (barata ou do python), e só a leitura LIDA vale como prova.
- **Estado terminal com o envio LIDO em voo (python ou leitura barata) segue como sempre: adia 10 min e NÃO pausa.** A decisão da ga-1p1i5jr.10 cobre só o envio ILEGÍVEL. Com a fila ocupada o D4 pode adiar mais de uma vez no estado terminal; pausar e esvaziar também nesse caso é uma fatia pequena (a mesma função), mas muda o escopo e fica para quem decide.
- **O caminho do `queue.db` tem duas fontes:** o `DEFAULT_DB` do `central_sender_restart_safe.py` e o `DR4_QUEUE_DB` do D4 (mesmo padrão, `/Users/athos/shared/data/queue.db`). Se o WA mover o banco, a leitura barata lê um arquivo velho.
- **Com o interruptor ligado o maestro não roda o `--resume`:** a pausa nossa espera até alguém apagá-lo.
- **A pendência só é resolvida quando o D4 roda de novo.** Com o interruptor ligado (passo 1) o D4 sai antes de ler o estado; a pendência fica lá, inerte (a marca segura o cooldown), e é resolvida na primeira rodada depois que o interruptor for apagado.
- **A espera de 10 min depois de um cancelamento vale para o disco crítico (< 1,5 GB) também**: se o disco recuperar durante a carência e voltar a cair logo em seguida, o D4 só reavalia depois dela. É o preço de não repetir o aviso a cada tick.
- **`kern.boottime` é a única prova de que o mini reiniciou.** Relógio que salta mais de 300 s para qualquer lado conta como "outro boot" (a marca fica e o cooldown vale): o lado inerte.

## O que ainda não foi provado

- **Se a Automação do macOS libera o envio do AppleEvent na cadeia do launchd do orquestrador.** De uma sessão de agente a sonda de permissão dá -1744 e o reinício do Mayor funciona mesmo assim, então ela não prediz. Se o pedido falhar na produção o D4 sai 20, desfaz a marca e avisa. A prova real é o canário do D5 (ga-1p1i5jr.5): um reinício de verdade, de dia, com o Athos avisado.
- **O mail do D4 contra o engine de verdade do mini (ga-hp9pwtr, 08/11).** O selftest usa um `gc` de mentira que fala o contrato do engine no remetente (lido no fonte do engine e na mensagem que o mini deu), e `mail send mayor -s … -m …` sem `--from` é o que o orquestrador e os outros vigias já mandam; mas o D4 corrigido nunca mandou o mail de verdade, e não existe teste com um `gc` real em cidade isolada. Prova de uma linha, no mini, com o ambiente da plist do orquestrador (aproximado; manda UM mail de teste ao Mayor; esperado rc 0): `env -i HOME=/Users/athos BD_ACTOR=automation GC_CITY_PATH=/Users/athos/gt/.gascity-gastown-hq PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Users/athos/go/bin:/Users/athos/.local/bin sh -c 'cd /Users/athos/gt/.gascity-gastown-hq && gc mail send mayor -s "[teste ga-hp9pwtr] mail do D4 sem --from" -m "Prova do envio sem remetente. Pode arquivar."'; echo rc=$?`
- **O postcheck pós-boot depois de um reinício que NÃO foi o noturno:** ele só age com o arquivo de pendência do `nightly-reboot.sh`; depois de um reinício do D4 sai em silêncio. A conferência pós-boot do D4 é o orquestrador reler o disco e escalar se seguir baixo.
- Medido em 01/11 21:15 (`--dry-run` com só a leitura de disco simulada, tudo mais real): pré-checagem passou e as quatro guardas leram `calls=ok · sender=ok · dolt=ok · scraper=ok`, com o leitor de verdade nos bancos de verdade; nenhum estado, trava ou aviso foi criado.

- **NÃO verificado no mini (ga-1p1i5jr.10):** a leitura barata e a pausa com o `sqlite3` 3.51 de lá e com o `queue.db` e o `demand_assignments.db` de verdade; o selftest usa o `sqlite3` do nó Linux (3.45) em bancos de mentira com o esquema do WA. Prova read-only no mini, sob carga simulada: `for i in 1 2 3 4 5 6 7 8; do yes >/dev/null & done; time /usr/bin/sqlite3 -batch -cmd ".timeout 3000" -cmd "PRAGMA query_only=ON" /Users/athos/shared/data/queue.db "SELECT COUNT(*) FROM message_queue WHERE status='sending';"; time /usr/bin/python3 /Users/athos/gt/whatsapp_automation/scripts/central_sender_restart_safe.py --quiet; kill $(jobs -p)` (a diferença entre os dois tempos é o que a leitura barata ganha; `kill` encerra os `yes`).

## Testar

`bash scripts/disk-recovery-d4-guarded-reboot.selftest.sh` — shutdown SIMULADO (nunca reinicia; `DR4_NO_REAL_REBOOT=1` vale em todos os cenários), 522 verificações (379 da 4.2 + 81 da ga-1p1i5jr.4.3 + 10 da ga-hp9pwtr + 52 da ga-1p1i5jr.10), ~8 min no mini a load alto (7m36s medido em 01/11 para as 379; as demais não foram cronometradas no mini: o nó Linux levou ~175 s para as 470 e ~300 s para as 522 com load 11-20). As 52 novas rodam o SQL da pausa DE VERDADE (o `sqlite3` do cenário delega ao de verdade) em bancos de mentira com o esquema do WA: replay do incidente com o python pendurado de verdade, leitura barata, pausa/esvaziamento/soltura, corridas entre a leitura e a escrita, pedido pendente, diretório do estado somente leitura (a marca vem ANTES) e o `--resume`. O `gc` do selftest é fiel ao engine no remetente do `mail send` (`--from` só de human, controller ou sessão que exista): o stub antigo aceitava qualquer argv e por isso o `--from disk-recovery-d4` nunca reprovou. Rode com teto de escrita: `$GC_CITY_PATH/scripts/heavy-guard.sh --what selftest-d4 --max-file-mb 512 -- bash scripts/disk-recovery-d4-guarded-reboot.selftest.sh`. No nó Linux (`mbp-run.sh --repo hq`) dá 521 + 1 falha esperada, a trava com pid reaproveitado (o D4 usa o `stat -f %m` do macOS): no macOS, que é onde o D4 roda, passa; com um `stat` que fale `-f %m` e `DR4_STAT_BIN` apontando para ele dá 522/0.

Para provar que o teste pega defeito: `DR4_ST_SUT=<cópia mutada do D4> D4_ST_ONLY='^nt_|^cool$' bash scripts/…selftest.sh` roda só esses cenários contra a cópia. Cada mutante (uma quebra na cópia) tem de reprovar. A ga-1p1i5jr.4.3 rodou 32 mutantes sobre o código novo (tolerância e módulo do boottime, espera da pendência, solta/mantém a marca, validação das chaves `pending_*`, gravação no dry-run, pré-checagem depois da carência, espera de 10 min em cada saída de cancelamento): 30 morreram de cara e 2 sobreviveram (o dry-run gravando ao resolver a pendência); o buraco virou os cenários `pd_dry_chg` e `pd_dry_exp` e os 2 morrem agora. Controle sem mutação: FAIL=0.
