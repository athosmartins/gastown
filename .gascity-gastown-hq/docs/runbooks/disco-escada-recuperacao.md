## Contents
- O que é e por que existe
- Estado de instalação
- Limiares
- Como o maestro decide
- Contrato dos degraus
- Retomada do D2 (`--resume`)
- Retomada do D4 (`--resume`) e a foto de RSS (ga-1p1i5jr.10)
- Interruptor, arquivos, saídas
- Três estados: o que o maestro faz quando não consegue ler
- Teto de 6 h do reinício (D4)
- D1: temporários do pytest e do GoogleUpdater, e a trava do Chrome (ga-1p1i5jr.9)
- Como testar
- Prova ponta a ponta e canário de 24 h (D5)
- Medição
- Decisão citável e fatias

## O que é e por que existe

De cerca de 05:00 a 10:40 de 01/11/2026 o volume Data do mini ficou entre 2 e 4 GB livres. A causa era memória virando swap
(rfb_monthly_refresh, demand-dashboard, map-viewer, Dolt), e as P0/P1 do WA ficaram paradas. Os guardas que existiam só LIMPAM
ARQUIVO e avisam (o `dolt-disk-floor-guard` diz que nunca mata nada). Esta escada age sozinha depois disso, até o reinício
guardado do mini.

`scripts/disk-recovery-ladder.sh` é só o **maestro**. Ele lê o disco, guarda há quanto tempo o disco está baixo e chama UM degrau
por rodada. Não apaga, não para e não reinicia nada por conta própria.

| Degrau | Quem | O que faz |
|---|---|---|
| D1 | `scripts/dolt-disk-floor-guard.sh` (já roda sozinho, a cada 5 min) | limpa arquivo (reapers, GOCACHE, órfãos…). O maestro NÃO o chama nem o reimplementa |
| D2 | `scripts/disk-recovery-d2-heavy-jobs.sh` (bead ga-1p1i5jr.2) | para jobs pesados reiniciáveis da allowlist |
| D3 | `scripts/disk-recovery-d3-ram-daemons.sh` (bead ga-1p1i5jr.3) | restart drenado dos daemons que mais usam RAM |
| D4 | `scripts/disk-recovery-d4-guarded-reboot.sh` (bead ga-1p1i5jr.4) | reinício guardado do mini |

## Estado de instalação

O job `com.gascity.disk-recovery-ladder` foi **carregado em 02/11/2026 ~22:10 BRT pelo Mayor** (`cp` + `launchctl bootstrap`; prova no comentário dele na ga-1p1i5jr:
`launchctl print` → `state = running`, `run interval = 120 seconds`; autorização: a decisão do Athos de 01/11 citada abaixo). Fazer merge de uma mudança em
`scripts/` NÃO recarrega nada: a cada 120 s o launchd roda o arquivo que estiver na árvore viva (`/Users/athos/gt/.gascity-gastown-hq/scripts/`), então confira lá que a versão mergeada chegou
(mergeado ≠ vivo) antes de dizer que uma correção está no ar. Para carregar de novo (ou numa máquina nova), com `scripts/` do degrau D2, D3 e D4 já presentes e executáveis (se faltar um, o maestro avisa uma vez por episódio,
`notify -p 4`, e pula para o próximo):

```
cp scripts/com.gascity.disk-recovery-ladder.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.disk-recovery-ladder.plist
launchctl print gui/$(id -u)/com.gascity.disk-recovery-ladder | head -20     # a prova: o serviço existe, run interval = 120 seconds
```

Para descarregar: `launchctl bootout gui/$(id -u)/com.gascity.disk-recovery-ladder`. Para pausar sem descarregar: `touch .gc/disk-recovery.off`. Carregar o job é o que liga a
escada: quem carrega precisa de autorização citável do Athos (a decisão de que a escada age sozinha, a qualquer hora e com guardas, está em "Decisão citável e fatias").

## Limiares

Medidos em MB livres de `df -Pm /System/Volumes/Data`. **Nunca `df /`**: ele lê o volume de sistema selado e mostra 71% com o
Data em 98% (`docs/runbooks/disk-guards-quem-age.md`).

| Degrau | Livre | Por quanto tempo seguido |
|---|---|---|
| D2 | ≤ 5120 MB (5 GB) | ≥ 900 s (15 min) |
| D3 | ≤ 4096 MB (4 GB) | ≥ 1800 s (30 min) |
| D4 | < 3072 MB (3 GB) | ≥ 3600 s (60 min) |
| D4, piso duro | < 1536 MB (1,5 GB) | 2 leituras SEGUIDAS, separadas por ≥ 100 s (2 rodadas do launchd), a qualquer hora |

O piso duro é parte do limiar do D4 (decisão do Athos: "< 1,5 GB a qualquer momento"). Não é um atalho para pular D2 e D3 em
episódio comum: os dois só entram depois do tempo deles. **Uma exceção (ga-1p1i5jr.10, 10/11):** com livre < 1536 MB e o D4 chamável
(fora do teto de 6 h), D2 e D3 vencidos NÃO têm vez e a rodada espera o D4 (as 2 leituras seguidas dele, ou o retry de 5 min). Sob thrash de
swap o D2 (06:30) e o D3 (06:57 e 07:30) estouraram os 900 s três vezes, 45 min do maestro, e a máquina travou às 08:01. Com o D4 no teto de
6 h não há D4 a esperar e D2 e D3 seguem como sempre. O maestro passa ao D4 `DR4_HARD_STREAK=<leituras seguidas>` (o estado terminal dele usa). Duas leituras seguidas, e não uma, para que um pico passageiro (um
`go build` que sobe e solta) não reinicie o mini. Rodadas coladas (um `--run` à mão ao lado de uma agendada, ou o launchd
atrasado que alcança) contam como UMA leitura: só valem duas leituras separadas por pelo menos `D4_HARD_SPACE_S` (100 s).

Todos os números têm uma variável `DR_<NOME>` (ver o cabeçalho do script). Um valor que não é número cai no padrão e o log diz.

## Como o maestro decide

1. **Cronômetro por nível.** Ao entrar no nível (`livre ≤ limiar`) o cronômetro começa. Só conta tempo de rodadas que o maestro
   leu.
2. **Histerese de 512 MB.** O cronômetro só ZERA quando o livre volta a `limiar + 512 MB`. Entre o limiar e `limiar + 512 MB` ele
   nem começa nem zera. Um disco que oscila em volta de 3 GB por 5 h não reinicia o relógio de 60 min a cada subida de 100 MB.
3. **Lacuna.** Mais de 600 s entre duas leituras (máquina parada, launchd fora, df ilegível) ou relógio que andou para trás zera
   cronômetros e marcas. Tempo que ninguém observou não vale como "60 min abaixo" para reiniciar uma máquina. A hora do último
   reinício (`acted4_ts`) fica.
4. **Um degrau por rodada.** A 1ª chamada de cada degrau no episódio vai em ordem D2 → D3 → D4. As repetições vão do mais alto
   para o mais baixo. Se o D2 repetisse primeiro a cada 5 min e o launchd atrasasse as rodadas para 5 min, ele ocuparia toda
   rodada e o D3 e o D4 nunca teriam vez.
5. **Re-mede depois de cada degrau.** Se o espaço voltou a `limiar + 512 MB`, os cronômetros zeram e o degrau seguinte não entra.
6. **Repetição.** Degrau que devolveu 0 (agiu) não repete por 30 min. Degrau que devolveu 10, 20 ou 30 repete em 5 min.
7. **Degrau ausente** (arquivo não existe ou sem permissão de execução): loga `degrau ausente`, avisa UMA vez por episódio (a
   marca `absent` só é gravada depois que o notify confirma; sem confirmação a rodada seguinte avisa de novo) e a rodada segue
   para o próximo degrau que tenha o tempo vencido. O maestro nunca chama o D4 sem o tempo do limiar dele.

Cada ação (degrau que agiu ou falhou) gera: 1 linha de log, `notify` (D2 `-p 3`, D3 `-p 4`, D4 `-p 5`, falha `-p 4` no mínimo) e
mail ao Mayor. Prioridade 4 ou mais vai com `NOTIFY_FORCE_PUSH=1` e `NOTIFY_STRICT_EXIT=1`: o `notify` decide push ou resumo mudo
pela REDAÇÃO da mensagem e não pelo `-p` (ga-ff6t9: um aviso de disco crítico real já caiu no resumo mudo), e sem o STRICT ele sai
0 em todo caminho que não empurrou, o que faria "tentei" parecer "entregue".

**Tentado ≠ entregue.** Toda marca de "já avisei" (a `absent` do degrau ausente, os carimbos de 1 h do estado, o `esc4` da
escalada do teto de 6 h e os arquivos `.gc/disk-recovery.nosave` e `.gc/disk-recovery.nolock`) só é gravada DEPOIS de algum canal
confirmar a entrega. Contam como entregue: `notify` com rc 0 (push com 2xx), 10 (segurado até as 7h pelo silêncio 22h–7h do Athos;
fica no `history.db` e o flush das 7h o empurra) ou 11 (dedup: um push do mesmo título saiu há menos de 30 min), e `gc mail send`
com rc 0. Não contam 12, 13, 14 nem 1 (o `notify` não empurrou nada). Sem confirmação a marca NÃO é gravada, o log diz
"NÃO confirmado" ou "NÃO entregue" e o aviso repete na rodada seguinte. De madrugada (22h–7h) o push de prioridade 4+ fica
segurado até as 7h. Nos avisos que também têm mail (degrau que agiu ou falhou, escalada do teto de 6 h) o mail ao Mayor sai na
hora; os avisos que são só `notify` (df ilegível, estado que não grava, trava, degrau ausente) esperam as 7h.

## Contrato dos degraus

Cada degrau é chamado `<script> --run` (real) ou `<script> --dry-run` (só diz o que faria). Escreve UMA linha em stdout. Saídas:

| rc | Significado | O maestro faz |
|---|---|---|
| 0 | agiu e terminou | marca `acted`, notify + mail (sempre), não repete esse degrau por 30 min |
| 10 | nada a fazer, ou a guarda adiou | marca `idle`, repete em 5 min, sem aviso |
| 20 | falhou | marca `failed`, saída 20, repete em 5 min. Notify (`-p 4` no mínimo; D4: `-p 5`) + mail no máximo 1 por hora por degrau (as repetições de 5 min só vão para o log) |
| 30 | não consegui ler o estado (não agiu) | marca `unknown`, notify `-p 3` (D4: `-p 4`), no máximo 1 por hora por degrau, repete em 5 min |
| outro / passou de 900 s | falha | tratado como 20 (o estouro de tempo recebe TERM). Exceção: não conseguir nem lançar o degrau (mktemp falhou) conta como 30 |

O notify e o mail são do maestro. Os degraus não avisam por conta própria. O limite de 1 por hora vale por degrau e por classe
(o "agiu" não cala um "FALHOU" logo depois), e só é carimbado depois da entrega confirmada (ver "Tentado ≠ entregue"). Cada mail é
um bead e um commit no Dolt de uma máquina que está sem disco, por isso o limite.

**D3 e a rodada da campanha (ga-13qui1k).** O D3 não reinicia o `demand-dashboard` (:8095) enquanto a trava da rodada diária da campanha estiver tomada. Em 08/11 às 20:39 ele o reiniciou no meio da rodada das
20:15 e o portão do prédio inteiro (vale 30 h) não foi regravado. A trava é um `flock` em `/tmp/wa_campanha_diaria/round.lock` (`lib/campanha_diaria/round_lock.py` do whatsapp_automation), o mesmo da rodada das
20:15, do botão «Rodar agora» e do bracket do ledger. O D3 a lê com um `flock` compartilhado não-bloqueante, tomado e solto na hora; o corpo do arquivo (`pid=… holder=…`) é o do último dono e fica depois que ele
sai, então não prova nada. Tomada: o log (`.gc/logs/disk-recovery-d3.log`) diz `pulo demand-dashboard: rodada da campanha em curso`, o degrau segue com os outros três daemons e sai 10 se não sobrar nada a fazer.
Ilegível (sem python3, sem permissão, não é arquivo comum): `pulo demand-dashboard: trava da rodada ilegivel`, pula do mesmo jeito e sai 30 se nada mais foi feito. O D3 só lê a trava antes de chamar o guardado:
o guardado do whatsapp_automation ainda precisa olhar a mesma trava logo antes do kickstart (wa-81n67r, item c).

## Retomada do D2 (`--resume`)

O `--run` do D2 para um job pesado reiniciável (hoje o `rfb`) quando o disco aperta. Alguém tem de religá-lo quando o disco volta; sem isso ele
só recomeça do zero no tick das 00:15. Esse alguém é o maestro (ga-1p1i5jr.6): **toda rodada** (a cada 120 s), com a escada em repouso ou
em degrau, **depois** do `--run` (se o aperto mandou), ele chama `scripts/disk-recovery-d2-heavy-jobs.sh --resume`. O `--resume` é seguro de
repetir: o registro do que foi parado, a trava e a decisão (livre ≥ `resume_above_mb`, janela, validade, run_id lido e nunca adivinhado) são do
próprio D2. O maestro só lê o código de saída.

| rc do `--resume` | O maestro faz |
|---|---|
| 0 (retomou) | `notify -p 3` "Disco: D2 retomou o job" com a linha do D2. Sem limite: o registro do D2 já impede repetir. Sem mail |
| 10 (nada a retomar, ou a guarda adiou) | **Silêncio**, nem uma linha no log. É o único código calado |
| 20 (não subiu) | Saída 20. `notify -p 4` forçado + mail ao Mayor, no máximo 1 por hora (classe `rc20`). A linha do D2 vai no aviso e traz o `run_id` quando o D2 o sabia (senão ele está no registro `.gc/disk-recovery-d2.state`): retome à mão com `rfb_stream_refresh.py --resume-run <run_id>` |
| 30 (não li o estado) | Saída 30 (se nada pior aconteceu). `notify -p 4` forçado, no máximo 1 por hora (classe `rc30`). Sem mail |
| Falha da chamada: script ausente, sem permissão de execução, passou de `RESUME_TIMEOUT_S` (120 s, TERM), rc fora de 0/10/20/30 | **Alerta**, nunca o silêncio do 10. `notify -p 4` forçado, no máximo 1 por hora (classe `broken`). Saída 20 quando o D2 rodou e se comportou mal; ausente/sem execução não muda a saída (como o degrau ausente) |

As marcas de 1 h são `.gc/disk-recovery.resume-{rc20,rc30,broken}`: o epoch do último aviso **entregue**, uma por classe (um alerta de chamada
não cala um rc 20 que venha logo depois). Marca ausente, vazia, com lixo ou no futuro não cala o aviso. A marca só é gravada depois que algum
canal confirma a entrega (tentado ≠ entregue); sem confirmação a rodada seguinte avisa de novo. **Limite aceito:** se nem a marca grava (disco
sem espaço nenhum), o aviso, mail incluído, repete a cada rodada, porque calar um job parado que ninguém retoma é o lado perigoso.

O passo **não roda** quando a rodada acaba antes dele: interruptor ligado, trava não tomada, relógio ou `df` ilegível (sem leitura nada
age). E **não roda em `--dry-run`**: o `--resume` não tem modo dry-run, chamá-lo lançaria o job de verdade. Ele também não depende do estado
salvo: roda mesmo que o estado do maestro não grave.

## Retomada do D4 (`--resume`) e a foto de RSS (ga-1p1i5jr.10)

**Retomada do D4.** Em estado terminal o D4 PAUSA o envio de primeiro contato (`outreach_config.system_paused`, com `system_paused_by` "disk-recovery-d4: …")
antes de reiniciar (`docs/runbooks/disco-d4-reinicio-guardado.md`, "Estado terminal"). Quem o solta depois do boot é o maestro: **toda rodada**, depois do `--resume` do D2,
ele chama `scripts/disk-recovery-d4-guarded-reboot.sh --resume`. Mesmos códigos do D2: 0 soltou (`notify -p 3`) · 10 nada a retomar ou ainda segurando (o ÚNICO silêncio:
nem uma linha de log) · 20 não soltou (`-p 4` forçado + mail; a linha ensina a despausar à mão) · 30 não li (`-p 4`) · falha da chamada (estouro de 120 s, rc estranho) = alerta; no máximo 1 aviso
por hora por classe (marcas `.gc/disk-recovery.resume-{d4rc20,d4rc30,d4broken}`, entregue-depois-carimbado). D4 ausente ou sem permissão de execução: calado (sem o script não há pausa dele; o degrau
ausente já avisa quando o D4 é devido). Não roda em `--dry-run`, com o interruptor ligado nem com relógio ou `df` ilegível. **Com o interruptor ligado a pausa nossa espera até alguém apagá-lo**; o D4 em
`--run` solta sozinho em toda saída normal, inclusive quando o interruptor aborta o reinício na carência.

**Foto de RSS.** 10/11 o swap foi de 0,7 para 4,6 GB entre 05:30 e 07:58 e não havia como saber QUEM inchou a RAM (nenhuma foto existia). Agora, em toda rodada com livre ≤ 5120 MB (o limiar do D2),
ANTES de chamar um degrau, o maestro grava os 10 maiores RSS (`ps -axo rss=,pid=,command=`) em `.gc/logs/disk-recovery-rss.log` (gira em `RSS_LOG_MAX_KB`, 1 MB, 1 backup `.1`). Cada linha: MB, pid e
as 3 primeiras palavras do comando, até 120 caracteres (argumento com segredo costuma vir depois do programa e do script). Só diagnóstico: `ps` que falha, estoura `RSS_TIMEOUT_S` (15 s) ou vem vazio
nunca decide nada nem muda a saída da rodada (1 linha WARN no log do maestro). Para nomear o culpado de um episódio: `grep -A1 'maiores RSS' .gc/logs/disk-recovery-rss.log | tail -40`.

## Interruptor, arquivos, saídas

| O quê | Onde |
|---|---|
| Desligar o maestro | `touch .gc/disk-recovery.off` (apague para voltar). Sai 10 sem ler nem agir |
| Estado | `.gc/disk-recovery.state` (`v=1` e chave=valor, escrito inteiro e trocado com `mv`). Estado ruim fica guardado em `.gc/disk-recovery.state.corrupt-<hora>.<pid>` (link duro) |
| Log | `.gc/logs/disk-recovery.log` (gira em 5 MB, 1 backup `.1`). Durante um episódio, 1 linha de leitura por rodada; sem episódio, 1 batimento por hora |
| stdout / stderr do launchd | `.gc/logs/disk-recovery-ladder.out` e `.err` |
| Trava | `.gc/disk-recovery.lock` (diretório + pid). Instância única. Trava de pid morto, ou de pid vivo que não é o maestro, é refeita |
| Marcas de aviso | `.gc/disk-recovery.nosave` (estado que não grava) e `.gc/disk-recovery.nolock` (trava que não tomo): arquivos vazios que limitam o aviso a 1 por hora. Só são tocados depois de o notify confirmar |
| Marcas da retomada do D2 | `.gc/disk-recovery.resume-{rc20,rc30,broken}`: o epoch do último aviso entregue de cada classe (ver "Retomada do D2"). Apagar uma libera o aviso dela na próxima rodada |
| Marcas da retomada do D4 | `.gc/disk-recovery.resume-{d4rc20,d4rc30,d4broken}`: o mesmo, para o `--resume` do D4 |
| Foto de RSS | `.gc/logs/disk-recovery-rss.log` (e `.1`): os 10 maiores RSS de cada rodada com livre ≤ 5120 MB |

Saídas do script: **0** rodada feita · **10** interruptor ligado, ou OUTRA instância VIVA rodando (calado, é o caso normal) · **20**
um degrau falhou (ou o `--resume` do D2 falhou: ver "Retomada do D2") · **30** não consegui ler o disco ou o relógio, não consegui gravar o estado, ou não consegui tomar nem verificar
a trava, e por isso não agi · **2** uso.

A trava tem três resultados: peguei · outra instância viva (sai 10, calado) · não consegui tomar nem verificar (sai 30, com aviso).
Este último é o `mkdir` que falha sem a trava existir (diretório sem escrita, disco sem espaço), o pid que não grava, a trava
velha que não consigo remover, ou o pid vivo que está com a trava há mais de `LOCK_MAX_MIN` (60 min; uma rodada legítima acaba em
minutos, o degrau mais longo tem 900 s). O maestro não rouba a trava de um processo vivo: só avisa (`notify -p 4`, no máximo 1 por
hora, marca `.gc/disk-recovery.nolock`; sem mail, porque o `gc mail` grava no Dolt e a falta de espaço que quebra o `mkdir` tende
a quebrar o mail junto) e sai 30 sem ler o disco nem chamar degrau, já que sem saber se há outra instância dois maestros
chamariam o mesmo degrau (o D4, duas vezes).

`--dry-run` lê o estado salvo, aplica a leitura de agora numa cópia em memória e chama os degraus com `--dry-run`. Não grava
estado nem log, não avisa, não manda mail, não toma a trava, não tira a foto de RSS e não chama o `--resume` do D2 nem o do D4.

## Três estados: o que o maestro faz quando não consegue ler

"Não consegui ler" nunca vira "tem bastante disco" nem "disco baixo".

| Não consegui ler | O maestro |
|---|---|
| `df` do volume Data (falhou, vazio, número inválido, ponto de montagem diferente) | NÃO chama degrau nenhum, loga, `notify -p 4` (no máximo 1 por hora ENTREGUE), sai 30. Os cronômetros NÃO zeram |
| swap (`sysctl vm.swapusage`) | NÃO é leitura obrigatória: só entra no texto das mensagens e do log, os limiares são de disco. Ilegível → `swap=?` e `[swap NÃO verificado…]` no log, e a rodada SEGUE (falha aberta, mas VISÍVEL). Lido com `LC_ALL=C` e aceitando vírgula: sob o launchd do mini (pt_BR) o `sysctl` imprime `3015,31M`, e tratar isso como ilegível desligava a escada inteira |
| relógio (`date +%s`) | NÃO chama degrau nenhum, loga e sai 30. Sem notify: sem hora não há como limitar o aviso a 1 por hora |
| trava de instância única (não consegui tomar nem verificar) | NÃO lê nem chama degrau nenhum, loga, `notify -p 4` (no máximo 1 por hora, marca `.gc/disk-recovery.nolock`), sai 30. Ver "Interruptor, arquivos, saídas" |
| estado salvo (corrompido, vazio, sem a marca `v=1`, chave que falta, campo inválido, última linha sem `\n` com valor inválido) | guarda o arquivo ruim como `disk-recovery.state.corrupt-<hora>.<pid>` (link duro, feito ANTES de o estado novo tomar o lugar dele por `mv`, para o arquivo de estado nunca deixar de existir), escreve WARN no log, os cronômetros recomeçam do zero e a rodada SEGUE (sai 0) MAS com `acted4_ts` = AGORA: não se sabe se o D4 acabou de disparar, então o teto de 6 h vale. Nada dispara por um histórico que não li. Só o arquivo AUSENTE é "primeira rodada" (`acted4_ts` = 0) |
| gravar o estado (disco cheio, sem permissão) | WARN no log, `notify -p 4` (no máximo 1 por hora, marca `.gc/disk-recovery.nosave`) e saída 30 (se nenhum degrau falhou). A escada fica cega para o TEMPO: cada rodada relê o arquivo antigo. Se a marca de ANTES da chamada de um degrau não puder ser gravada, o degrau NÃO é chamado (sem a marca no disco um reinício se repetiria) |

Em todos os casos de df ilegível os cronômetros salvos ficam como estavam; se a falta de leitura passar de 10 min, a lacuna
os zera na próxima leitura boa.

## Teto de 6 h do reinício (D4)

Reinício em laço é barrado pelo teto. O `acted4_ts` é gravado ANTES de chamar o D4 (um reinício que mata o maestro no
meio não perde a marca). Depois de um D4 que devolveu 0, o maestro não chama `d4 --run` de novo por 6 h. Se o disco segue abaixo
de 3 GB, ele **escala** em vez de reiniciar: `notify -p 5` com push forçado e mail ao Mayor, uma vez por episódio ("segue baixo
depois do reinício, preciso de um humano"). "Uma vez" só vale com a entrega CONFIRMADA por algum canal (ver "Tentado ≠
entregue"): se nem o notify nem o mail confirmam, o `esc4` fica 0 e a rodada seguinte (2 min) tenta de novo, porque disco cheio,
Dolt caído e rede falhando são o cenário esperado aqui. Se o D4 devolve 10 ou 20, a marca volta ao valor anterior e ele tenta de
novo em 5 min (a guarda adiou, ou falhou sem reiniciar). O comentário na ga-1p1i5jr.4 pede que o próprio D4 tenha o cooldown dele
também (defesa em profundidade); o maestro não depende disso.

O `acted4_ts` também vale quando o estado salvo se perde pela metade (ver "Três estados"): ele passa a ser AGORA. Só se perde com
o arquivo de estado AUSENTE (apagado à mão). Apagar `.gc/disk-recovery.state` é, de propósito, o jeito de zerar tudo, inclusive o
teto de 6 h: se o estado se perdeu e o D4 NÃO chegou a disparar, é isso que libera o D4.

## D1: temporários do pytest e do GoogleUpdater, e a trava do Chrome (ga-1p1i5jr.9)

Em 09/11/2026, 20:30–20:51, uma atualização do Chrome (GoogleUpdater) escreveu ~900 MB em `$TMPDIR` com 2,27 GB livres e, depois que o Mayor apagou os diretórios, o updater seguiu SEGURANDO 1,47 GB em
arquivos já apagados (`lsof +L1`; o `du` não vê). O D4 pediu reinício às 20:44 e às 20:50. Três coisas no D1 (`dolt-disk-floor-guard.sh`):

- **Abaixo de 5 GB livres** (`DOLT_DISK_FLOOR_LOW_DISK_TMP_GB`, em WARN e CRITICAL): `_reap_google_updater_tmp` dá TERM (depois KILL) a todo processo cuja linha de comando contém
  `/GoogleUpdater.app/Contents/MacOS/GoogleUpdater` (`DOLT_DISK_FLOOR_GOOGLE_UPDATER_CMD_PATTERN`; confira no mini com `ps -axww -o pid=,command= | grep GoogleUpdater`) e, só quando nenhum sobra e a lista de processos
  foi lida, apaga `$TMPDIR/com.google.GoogleUpdater.GoogleUpdater_chrome_url_fetcher_*`. Parar o processo é o que devolve o espaço de arquivo já apagado. `_reap_pytest_tmp` apaga `pytest-of-<usuário>/pytest-N` com
  mtime > 30 min e onde nada, em qualquer profundidade, mudou nesse tempo; o symlink `pytest-current` fica. Nenhum dos dois usa `lsof`: o dump do sistema levou 34–72 s com load ≈ 60 (ga-mv896u), justo quando o disco
  aperta. Limite aceito: um arquivo aberto e parado há mais de 30 min dentro de um `pytest-N` não é visto.
- **Toda rodada**, qualquer classe, por último na rodada (um `launchctl` pendurado nunca atrasa o aviso crítico nem o mail): `_hold_chrome_updater` deixa o job `com.google.GoogleUpdater.wake` rodar só entre 00:00 e
  06:00 com ≥ 8 GB livres (`launchctl enable` + `bootstrap`); fora disso, ou abaixo de 5 GB, `launchctl disable` + `bootout` (um download em curso às 06:00 é interrompido). Entre 5 e 8 GB mantém o estado em que está,
  para não oscilar. Só age num estado que conseguiu ler (cada `launchctl` tem prazo de 15 s) e relê depois de agir: «HELD»/«ALLOWED» só vai ao log se a releitura confirma; senão «NOT verified».
- **Não toca** nos agentes do sistema (`/Library/LaunchDaemons/com.google.GoogleUpdater.wake.system`, keystone): sem sudo, e eles podem relançar o updater; abaixo de 5 GB o D1 o para de novo a cada rodada.

Prova no log (`.gc/logs/dolt-disk-floor-guard.log`) na próxima ocorrência: `low-disk-tmp: avail=…GB < 5GB`, `google-updater-reap: stopped the Chrome updater pid=… (TERM)`, `google-updater-reap: …chrome_url_fetcher_… — DELETED`,
`pytest-tmp-reap: pytest-N … — DELETED` e `chrome-updater-hold: HELD` ou `ALLOWED`. Interruptores: `touch .gc/chrome-updater-hold.off` desliga só a trava (apague para voltar); `DOLT_DISK_FLOOR_GUARD_ENABLED=0` desliga
isto junto com os outros alívios do D1. Para desfazer a trava à mão: `launchctl enable gui/$(id -u)/com.google.GoogleUpdater.wake && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist`.
Estado de partida: o Mayor desligou o agente à mão em 09/11 ~20:53 (desabilitado e fora do launchd); o guarda lê isso como «held» e o religa sozinho na primeira rodada dentro de 00–06 h com ≥ 8 GB, então não o religue à
mão. A hora é a do relógio local do mini. Teste: as seções «low-disk temp levers + Chrome updater hold» de `dolt-disk-floor-guard.selftest.sh` (processos de brinquedo achados pelo caminho do próprio teste, `launchctl` falso
com estado, bash 3.2 incluso); o selftest roda no mini (está em `hetzner-mac-only.hq.txt`).

## Como testar

```
scripts/heavy-guard.sh --what selftest-hq --max-file-mb 512 -- bash scripts/disk-recovery-ladder.selftest.sh
```

O selftest é hermético: df, swap, relógio, degraus, `notify` e `gc mail` são simulados, e as rodadas do launchd são chamadas com a
hora que o teste escolhe (6 h de teto passam em segundos). O trecho que lê `df` e `sysctl` de verdade é testado com shims no PATH,
e o shim do `df` prova que o maestro nunca lê `df /`. Cobre cada fronteira dos limiares (5120/5121, 4096/4097, 3071/3072,
1535/1536 MB e 899/900 s), a histerese, a lacuna, a ordem e um degrau por rodada, o piso duro, cada código de saída dos degraus,
degrau ausente, o teto de 6 h (inclusive o maestro morto no meio do D4), df/swap/relógio/estado ilegíveis, o interruptor, a trava,
o dry-run, configuração inválida, notify e mail com defeito ou travados, rotação do log, estado não gravável e a retomada do D2
(`--resume`: cada rc 0/10/20/30, D2 ausente, sem permissão, rc 99/2/1 e estouro de prazo, limite de 1 h por classe, marca só depois da
entrega, marca com lixo ou no futuro, dry-run e saídas antecipadas que não chamam o `--resume`).

Resultado da última rodada completa, contra o maestro com o passo `--resume` (ga-1p1i5jr.6, 03/11/2026): **501 verificações, 0 falhas**,
rc 0, em 452 s no nó Linux de testes. (A rodada anterior, de 02/11/2026, sem o `--resume`: 446 verificações, 0 falhas, 290 s.) Com o piso duro que pula D2/D3, o `--resume` do D4 e a foto de RSS (ga-1p1i5jr.10, 10/11/2026): **553 verificações, 0 falhas**, rc 0, em 944 s no nó Linux com load 11-21 (as 52 novas: ordem e DR4_HARD_STREAK, as classes do `--resume` do D4, e a foto de RSS com ps de mentira: ordem, corte do comando, limiar de 5120, ps que falha, pendura ou vem vazio, rotação, e a foto sai ANTES do degrau).
Comando: `scripts/mbp-run.sh --repo hq --dir <worktree> -- scripts/disk-recovery-ladder.selftest.sh`; rc
96..99 do `mbp-run` significa "rode local", não teste reprovado. No mini a bateria é pesada: uma rodada anterior, com 282
verificações, levou 3 min 13 s com load ≈ 35; por isso o selftest local roda sob o `heavy-guard`, que é da classe `selftest`. O guarda vale para o volume INTEIRO: com o
disco apertado ele recusa (rc 75) ou interrompe (rc 78) mesmo que a queda venha de outro job. Nesse caso espere folga e rode de novo;
não baixe o piso do guarda para passar. `--min-free-mb` e `--max-disk-drop-mb` existem para ajustar o piso e o limite de queda numa
chamada, mas o piso nunca deve ir abaixo de 4096.

Para testar uma cópia modificada do maestro (mutantes): `DR_LADDER_PATH=/caminho/disk-recovery-ladder.<id>.sh bash scripts/disk-recovery-ladder.selftest.sh`.
O arquivo da cópia TEM de se chamar `disk-recovery-ladder.<id>.sh`: a trava de instância única só reconhece como maestro vivo um
processo cuja linha de comando contém `disk-recovery-ladder`, e com outro nome o teste da trava falha por engano.
Com `ST_FAILFAST=1` o selftest para no primeiro FAIL e sai 1 com `(ST_FAILFAST) parei no 1º FAIL: N passaram, M falharam`, o que
acelera o teste de mutantes (um mutante "pego" é um que faz o selftest sair 1).

Teste de mutação do passo `--resume` (ga-1p1i5jr.6, 03/11/2026): 19 cópias do maestro, cada uma com UMA alteração, rodadas no nó Linux com
`ST_FAILFAST=1`; o selftest pegou as 19, todas numa asserção da retomada (nenhuma caiu por acaso em outra seção). As alterações: rc 20 ignorado
(o mutante pedido pela bead), rc 30 ignorado, rc fora de 0/10/20/30 calado, estouro de prazo (124) calado, D2 ausente calado, rc 0 sem o "retomou",
rc 20 sem o mail, rc 20 sem a saída 20, as três classes de aviso fundidas numa marca, sem o limite de 1 h, marca gravada ANTES da entrega, marca com
lixo calando o aviso, marca no futuro calando o aviso, marca que a leitura falha (some, ou existe e não lê: um diretório no lugar do arquivo) tratada como "avisei há pouco", `--resume` antes do `--run`, `--resume` chamado em dry-run, prazo do `--resume` ignorado e
nenhum chamador (o comportamento de antes da bead). Os mutantes ficaram fora do repositório (cópias descartáveis); para refazer, gere a cópia com
`sed` e rode como descrito acima.

Teste de mutação da PRIMEIRA versão do maestro (01/11/2026; histórico, não vale para o script de hoje): 22 cópias do maestro, cada uma com UMA alteração de 1 a 2 linhas (limiares com `<` no lugar de `<=`
e o contrário, sem histerese, sem a regra da lacuna, sem o filtro de 2 leituras do piso duro, o tempo do limiar ignorado, marca do D4
gravada depois da chamada, `df /`, df ou swap ilegível tratado como 0, sem trava, sem `NOTIFY_FORCE_PUSH`, sem o teto de 6 h, as
duas passadas na ordem trocada, marca do D4 mantida em rc 10, dry-run gravando estado, prioridade do D3 trocada, um comando
qualquer no lugar do degrau, estado sem `v=1` aceito, última linha do estado sem `\n` descartada, interruptor ignorado). O selftest
pegou as 22. Dois só caíram, por acaso, no teste da trava de instância única: o `df /` (o teste "df chamado SEMPRE com -Pm
/System/Volumes/Data" também o pega, conferido sem failfast) e a ordem da 1ª passada invertida, que NENHUM teste mirava, porque com
rodadas a cada 5 min o cronômetro de um nível só vence depois de o de baixo já ter sido chamado. Por isso foi acrescentada a seção
"1ª passada com VÁRIOS degraus vencidos ao mesmo tempo" (estado escrito à mão); com ela esse mutante cai também nos testes da própria
ordem (conferido sem failfast).

Os consertos de revisão (gate-fix 1 a 3: entrega confirmada, trava com três estados, swap que não trava a escada, estado ruim
guardado, carimbos de 1 h) ganharam os mutantes deles. Os números estão nos comentários da ga-1p1i5jr.1 e são RELATO dos autores,
não medição deste runbook: 38 de 38 mortos no gate-fix 2 e 27 de 27 no gate-fix 3 (11 do swap, 13 da trava e do estado, 3 do D3).
O que este runbook mediu foi só a bateria inteira do script de hoje (446 / 0, acima).

## Prova ponta a ponta e canário de 24 h (D5)

**(a) Simulação ponta a ponta** — `scripts/disk-recovery-e2e.selftest.sh` (~80 s no nó Linux a partir de um worktree; pelo `mbp-run.sh` ele roda no mini, está em `hetzner-mac-only.hq.txt`; sem rede nem disco real). Diferente dos selftests de cada peça, que trocam os vizinhos por stubs, aqui o
maestro REAL chama o D2, o D3 e o D4 REAIS, do jeito do plist (`/bin/bash disk-recovery-ladder.sh --run`, env mínimo), contra UM mundo simulado: `df`, `sysctl`, `launchctl`, `ps`, `footprint`,
`curl` e `date` são shims que calculam o livre na hora a partir do estado do mundo (rfb de brinquedo morto por TERM de verdade, daemons reiniciados, vazamento de memória, reinício simulado que mata o D4
e o maestro). Cenários: S-A estouro de memória D2 → D3 → D4 (piso duro) e depois o teto de 6 h com escalada, S-B nada a liberar e o D4 só aos 3600 s, S-C/S-C2 ligação em curso segura o D4 e o D3 com o
mesmo banco, S-D pico isolado, S-F interruptor 70 min. O último bloco passa o log que o maestro real escreveu pelo relatório (b). `E2E_KEEP=1` mantém o diretório de trabalho; `E2E_LADDER`, `E2E_D2`,
`E2E_D3`, `E2E_D4` e `E2E_REPORT` apontam cópias modificadas (mutantes); `E2E_BASH=/caminho/bash` roda tudo no bash 3.2 do mini. O cenário S-A pós-boot muda quando a ga-1p1i5jr.6 (o maestro
passa a chamar o `--resume` do D2 a cada rodada) entrar: atualize-o então, é para isso que ele serve.
Achado do primeiro gate (o e2e rodado no mini pelo revisor): o D3 ficava CEGO no macOS. Os bancos de ligação são WAL e ficam sem `-wal`/`-shm` entre uma operação e outra dos apps (medido em 01/11, cabeçalho do
leitor do D4), e o `sqlite3` do mini (3.51) não abre esse estado com `-readonly` ("unable to open database file", rc 14), então a guarda de ligação dava "?" e o D3 saía com rc 30 (o revisor viu `pix=?` no
log de produção de 03/11). O D3 passou a abrir com `PRAGMA query_only=ON`, como o
leitor do D4 (o SQLite pode criar o `-shm`/`-wal`; nenhum dado é gravado), e o `sqlite3` do mundo simulado impõe a regra do mini para o e2e e o selftest do D3 pegarem a regressão também no Linux.

**(b) Canário em produção e (c) relatório** — `scripts/disk-recovery-report.py` lê o log do maestro (`.gc/logs/disk-recovery.log` e o `.1`) e calcula, sem relato de ninguém: cobertura (horas, maior
silêncio), por degrau as chamadas, o que agiu/adiou/falhou e os MB devolvidos, e as janelas com o livre < 3 GB. Depois de 24 h do job carregado (carregado em 02/11 ~22:10 BRT = 03/11 01:10Z; 24 h = 04/11
01:10Z):

```
python3 scripts/disk-recovery-report.py --since 'AAAA-MM-DD HH:MM'     # --json para máquina; rc 0 só com aceite ATENDIDO e >= 24 h de cobertura; rc 3 = log ilegível
```

O aceite da missão ("nenhuma janela > 60 min com disco < 3 GB sem uma ação da escada no log") sai como ATENDIDO / NÃO ATENDIDO / NÃO VERIFICADO. Sem leitura não se sabe que o disco ficou bom, então é NÃO VERIFICADO: silêncio de mais de 65 min entre duas linhas quaisquer
(job parado ou desligado, mini fora), janela baixa ainda aberta no fim do log sem ação da escada, ou fim de janela incerto (silêncio depois de uma leitura baixa não é "recuperou").
Se o disco nunca ficou ≤ 5 GB o relatório diz que o canário NÃO exercitou a escada: nesse caso o aceite vale por vacuidade e a prova que sobra é a simulação (a).
O relatório ao Athos é a tabela impressa (chamadas e MB por degrau), não uma narrativa. Testes do relatório: `bash scripts/disk-recovery-report.selftest.sh` (~2 s).

## Medição

Rodada que não chama degrau, com `df` e `sysctl` REAIS e estado, log e trava num diretório de teste (nada do estado real), contra o
maestro final, no mini com load ≈ 65 a 67 (02/11/2026 ~15:06 BRT, 5 rodadas): **0,41 s** a 1ª (sem estado salvo) e **0,17 a 0,46 s**
as outras (0,37 · 0,46 · 0,26 · 0,17), contra o intervalo de 120 s. `df -Pm /System/Volumes/Data` leva menos de 0,01 s e
`sysctl -n vm.swapusage` menos de 0,05 s; o resto é o bash e os subprocessos (`date`, `awk`, `du`…). Para comparar: as rodadas de
01/11 (primeira versão do maestro, load ≈ 35 a 40) levaram 0,44 s a 1ª e de 2,3 a 5,2 s as outras. Uma rodada que chama um degrau
demora o que o degrau demorar, no máximo 900 s (depois disso o degrau recebe TERM); o launchd não inicia outra enquanto esta roda e a
trava cobre o resto. Depois de um degrau o maestro atualiza a hora da última leitura, então a demora do degrau não conta como lacuna.

## Decisão citável e fatias

- **Decisão do Athos:** AskUserQuestion na sessão do Mayor, 01/11/2026 ~11:00 BRT, resposta "A qualquer hora, com guardas
  (Recomendado)". Citada na epic ga-1p1i5jr.
- **Fatias:** ga-1p1i5jr.1 (este maestro, o plist e o selftest), .2 (D2), .3 (D3), .4 (D4). Os nomes dos scripts e o contrato de
  chamada e de saída foram postados como comentário nas três beads irmãs antes de elas serem pegas.
- **Limite conhecido:** o maestro mede só o volume Data. Ele não decide QUAL daemon consome a RAM (isso é do D3) nem se é seguro
  reiniciar (isso é da guarda do D4).
