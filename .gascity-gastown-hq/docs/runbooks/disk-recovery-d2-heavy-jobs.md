# Disco D2 — parar jobs pesados reiniciáveis (allowlist) — ga-1p1i5jr.2

## Contents
- O que é · Como chamar · Contrato (stdout e códigos) · A allowlist · O que o rfb retoma (a pergunta do bead) · Registro de "o que parei" · Retomar · Guardas · Selftest · Quem chama o quê

## O que é
Degrau D2 da escada de recuperação de disco (D1 limpeza de arquivos → **D2 parar jobs pesados reiniciáveis** → D3 reinício drenado de daemons de RAM → D4 reboot com guardas). Decisão do Athos para a épica `ga-1p1i5jr`: "a qualquer hora, com guardas" (AskUserQuestion na sessão do Mayor, 01/11/2026 ~11h BRT).

O D2 só para o que está na allowlist (`scripts/disk-recovery-d2-allowlist.tsv`). Nunca escolhe "o maior consumidor". Nada fora da lista é tocado.

## Como chamar
```
scripts/disk-recovery-d2-heavy-jobs.sh --dry-run   # só diz o que faria; não cria trava, registro, log; não chama S3 nem launchctl
scripts/disk-recovery-d2-heavy-jobs.sh --run       # para de verdade o que a allowlist manda e o piso permite
scripts/disk-recovery-d2-heavy-jobs.sh --resume    # retoma o que o D2 parou (aditivo ao contrato; ver "Quem chama o quê")
```

## Contrato
stdout = exatamente UMA linha. Códigos: `0` agiu e terminou · `10` nada a fazer ou uma guarda adiou · `20` falhou (registro não gravou, processo não morreu, **morte não comprovada**) · `30` não consegui ler o estado (e portanto não agi) · `2` uso errado (não escreve no log). Notificação e mail em rc 0/20 são do orquestrador (`disk-recovery-ladder.sh`); o D2 só escreve o próprio log (`.gc/logs/disk-recovery-d2.log`).

"Não consegui ler" nunca vira "baixo" nem "bom": df, ps, allowlist, registro, plist ou `launchctl list` ilegíveis dão rc 30 e nenhuma ação (`launchctl list` com rc 113 = "não conheço o rótulo" = não há retomada viva; qualquer outro rc = não sei, não lanço outra por cima). O mesmo vale no meio do caminho: ps ilegível na re-conferência antes do primeiro sinal = rc 30 (se algo já tinha sido parado, rc 20); depois do TERM, ps ilegível ou pid vivo que a allowlist não lista mais = "morte não comprovada" = rc 20, **sem KILL às cegas**.

## A allowlist
Uma linha por job, 9 colunas separadas por TAB: `id adapter match_regex parent_regex stop_below_mb resume_above_mb resume_window resume_max_age_s como`. O formato, o que qualifica e os candidatos REJEITADOS (com o motivo medido) estão no cabeçalho do próprio arquivo. Hoje só há uma linha ativa:

| id | para quando livre ≤ | retoma quando livre ≥ | janela | validade |
|---|---|---|---|---|
| `rfb-monthly-refresh` | 3072 MB | 8448 MB | 21h–6h | 24 h |

Rejeitados (precisam de marcador "parado pelo D2" no wrapper, para não acordar o Athos com um alarme que o D2 causou): `lotes-rebuild`, `property-search-rebuild`; sem prova de kill seguro: `sync-to-motherduck`; piora o disco: `jsonl-archive-pack`.

## O que o rfb retoma (a pergunta do bead)
**Por tabela, não do ponto.** Cada tabela que termina e é verificada grava `s3://urblink-motherduck-backups/real_estate/rfb/_meta/stream-run-<run_id>.<tabela>.json`; ao retomar com `--resume-run <run_id>` essas tabelas são reaproveitadas, e a tabela em andamento recomeça do **zero** (horas). Por isso o piso de parada é **3 GB**, não os 5 GB em que o orquestrador chama o D2. O tick das 00:15 começa um run NOVO e apaga chaves temporárias com mais de 24 h.

## Registro de "o que parei"
`.gc/disk-recovery-d2.state` (TSV: `epoch EVENT id pid início_epoch run_id livre_mb detalhe`). O `STOPPING` é gravado ANTES do sinal (sem registro, não para: rc 20 e o job segue vivo); `STOPPED` só depois de provar a morte por `ps` **e** por `kill -0` (zumbi conta como morto); `STOP_FAILED` se não morreu ou se a morte não foi comprovada. Eventos: `STOPPING → STOPPED | STOP_FAILED`; na retomada `RESUME_STARTED`, `RESUME_REFUSED` (continua pendente), `RESUME_FAILED`, `ABANDONED`.

O `run_id` é `<epoch>-<pid>` do python do job: o D2 o LÊ do S3 (chave `stream-run-<epoch>-<pid>.*` com o pid do processo parado e a hora de início do processo ±5 s). Se não achar ou achar mais de um, grava `-` e o `--resume` tenta de novo. **Nunca adivinha.** Exceção que é leitura, não palpite: o job que o `--resume` lançou leva `--resume-run <id>` na própria linha de comando, e as chaves do S3 de um run retomado ficam sob o id ANTIGO (pid+hora não as achariam); se a escada o parar de novo, o D2 lê o id dali (só na forma `<epoch>-<pid>`), sem consultar o S3, e o `--resume` seguinte retoma o mesmo run.

## Retomar
`--resume` só lança quando: há registro pendente; livre ≥ `resume_above_mb`; hora dentro da janela; o registro não passou da validade; o job não voltou a rodar sozinho; o `run_id` existe e tem a forma `^[0-9]+-[0-9]+$`. Lança por `launchctl submit` (desacoplado) com o `EnvironmentVariables` do plist do próprio job (tetos de memória/RSS ficam em sincronia), via `job_timeout.sh --soft`, e vigia `D2_RESUME_WATCH_S` segundos (25 por padrão). O portão do próprio job (rc 3 "NÃO RODEI": janela ou disco) vira `RESUME_REFUSED` e segue pendente. Job **de pé** depois da vigia = rc 0, mas isso **não prova** que ele passou dos portões: origem, checkpoints no S3 e mês rodam depois de imports e rede e podem levar mais que a vigia. O D2 para de olhar ali; o desfecho fica no código de saída (abaixo) e no log `.gc/logs/disk-recovery-d2-resume-rfb.log`, e uma recusa tardia (rc 3 depois da vigia) **não** volta a ficar pendente: o tick das 00:15 recomeça do zero.

**Vida do rótulo `com.gascity.d2-resume.rfb`.** `launchctl submit` cria um job KeepAlive: o launchd o relança ~10 s depois de **toda** saída, com qualquer código, até alguém tirar o rótulo (medido pelo revisor do gate com jobs de brinquedo; o selftest o reproduz com um launchd de brinquedo que também relança). Por isso o job roda dentro de um wrapper (`bash -c`, uma linha) que, quando o job acaba, grava o código de saída em `.gc/disk-recovery-d2-resume-rfb.rc` e **remove o próprio rótulo**: o rótulo existe só enquanto o job existe.
- O job que termina depois da vigia, bem ou mal, **não roda de novo**.
- O job que a escada para outra vez (TERM no python) **não volta sozinho**; o `--resume` seguinte o relança só se disco, janela e validade deixarem.
- O `--resume` apaga o arquivo de código antes de cada lançamento (se não conseguir: rc 30, nada é lançado), para um código velho nunca ser lido como o da retomada nova.
- Se o `remove` do wrapper falhar e o launchd relançar o wrapper, ele acha o arquivo de código e só tenta remover de novo, sem rodar o job.
- Rótulo órfão (wrapper morto à força): o `--resume` que for lançar de novo remove o que estiver sem PID; à mão, `launchctl remove com.gascity.d2-resume.rfb`.

A trava é a mesma do `--run`: outra instância viva = rc 10; trava que não dá para criar ou verificar = rc 30 e nada é lançado (a linha diz "a trava", não "outra instância"). Se o job sobe mas o `RESUME_STARTED` não grava, o rc segue 0 (o job está de pé) e a linha de stdout e o log trazem `ALERTA`: sem esse registro um novo `--resume` pode lançar de novo se o job cair.

## Guardas
Allowlist inválida / regex que casa mais de 3 processos → rc 30. Só processos do mesmo usuário; só o filho do pai certo (`job_timeout.sh` do launchd: `py_compile` ou `--dry-run` rodados por gente/teste nunca casam). Identidade re-conferida logo antes de cada sinal (pid reaproveitado). TERM → graça → KILL só se ainda listado. Trava por `mkdir`: o dono é conferido pela linha de comando (pid reaproveitado por outro programa não prende o D2); dono que não consigo ver = rc 30, não roubo; pasta sem pid e com menos de 2 min = outro D2 começando (rc 10), mais velha = abandonada. Trava que não dá para criar é rc 30, nunca "outra instância". Histerese: `resume_above_mb` > `stop_below_mb` (validado).

## Selftest
`scripts/disk-recovery-d2-heavy-jobs.selftest.sh` (hermético: processos de brinquedo + stubs de ps/aws/launchctl; pid lido de arquivo só leva sinal se a linha de comando dele carregar o diretório temporário DESTA instância, e o stub exige que o job seja filho do supervisor dele: um arquivo de pid velho, cujo número o macOS já deu a outro programa, não leva KILL — S18). Roda 337 asserções e uma bateria de **34 mutantes** (cada guarda do script do D2 estragada tem de derrubar o seu cenário; o S18 testa o próprio selftest, então não tem mutante: os mutantes estragam o script do D2). O launchctl de brinquedo executa o comando do `submit` com KeepAlive (relança depois de toda saída), por isso os cenários R20-R26 enxergam o relançamento que a retomada precisa evitar. A allowlist do teste é ancorada no diretório temporário de cada instância: duas rodadas ao mesmo tempo na máquina (dois revisores do gate, por exemplo) não matam os toys uma da outra (S17). O `s_real_df` lê o df de verdade (só leitura) e exige rc 10 + MB igual a um df independente: df quebrado não passa. Leva alguns minutos com a máquina carregada. Rodar sob o guarda de disco:
```
scripts/heavy-guard.sh --what selftest-d2 --max-file-mb 512 -- bash scripts/disk-recovery-d2-heavy-jobs.selftest.sh
```
Medido em 02/11/2026 (gate-fix 2) no nó Linux via `mbp-run.sh --repo hq --dir <worktree> -- scripts/disk-recovery-d2-heavy-jobs.selftest.sh`, bash 5.2, ~3 min: 337 asserções, 334 passam; as 3 que reprovam são do S2 **por ambiente** (ele lê a allowlist real e o espelho do `mbp-run` não leva o `.tsv`; para o S2 nesse caminho, rode no mini); 34/34 mutantes mortos, nenhum sobreviveu. Em uma 1ª rodada o S13 (rc 10, nada a parar) e o S17 (o toy de fora morto) também reprovaram e a rodada seguinte não os reproduziu: é o que se vê se um toy é morto por um processo de fora, e o nó é compartilhado, mas a causa não foi provada. O S18, sozinho, reprova 8 das 10 asserções contra o código anterior (c22667949, com o `Killed sleep 300` do `lc_cleanup` no log) e passa 10/10 agora (as 2 que passam antes são o controle positivo e a pré-condição). No mini, só o que cabe sem o guarda de disco: `bash -n` limpo no `/bin/bash` 3.2.57 e as peças novas (`own_pid`/`kill_own` e o `own_job` do stub, sob o `ps` do macOS) conferidas com ele; o selftest INTEIRO não rodou no mini nem no bash 3.2.57 depois deste conserto (o `heavy-guard.sh` recusou: 6107 MB livres < 6144 MB, rc 75). A medição de 01/11 no mini, antes da vida do rótulo (244/244 e 21/21, 471 s com load ~39 sob o `heavy-guard.sh`), também não foi refeita para as asserções novas.

## Quem chama o quê
O orquestrador (`disk-recovery-ladder.sh`, dog-2) chama o `--run` do D2 só com o disco ≤ 5120 MB por 15 min. O `--resume` tem chamador desde ga-1p1i5jr.6: o mesmo orquestrador o chama **toda rodada** (a cada 120 s), depois do `--run`, com a escada em repouso ou em degrau, e avisa por rc (0 retomou · 10 silêncio · 20 e 30 alerta, com limite de 1 por hora · falha da chamada também é alerta). Detalhes e o que fica de fora (`--dry-run`, interruptor, trava, leitura ilegível) em `disco-escada-recuperacao.md`, seção "Retomada do D2". O trecho "QUEM CHAMA --resume … Sem chamador" do cabeçalho de `disk-recovery-d2-heavy-jobs.sh` ficou velho (o script não foi tocado: a lógica do `--resume` está fora do escopo daquela bead).

Pendências conhecidas: marcador "parado pelo D2" nos wrappers de `property-search-rebuild` e `lotes-rebuild` (para promovê-los); prova de que a publicação do `lotes-rebuild` é atômica.
