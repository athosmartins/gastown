# Disco D2 — parar jobs pesados reiniciáveis (allowlist) — ga-1p1i5jr.2

## Contents
- O que é · Como chamar · Contrato (stdout e códigos) · A allowlist · O que o rfb retoma · Registro de "o que parei" · Retomar · Guardas · Selftest · Quem chama o quê

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
stdout = exatamente UMA linha. Códigos: `0` agiu e terminou · `10` nada a fazer ou uma guarda adiou · `20` falhou · `30` não consegui ler o estado (e portanto não agi) · `2` uso errado. Notificação e mail em rc 0/20 são do orquestrador (`disk-recovery-ladder.sh`); o D2 só escreve o próprio log (`.gc/logs/disk-recovery-d2.log`).

"Não consegui ler" nunca vira "baixo" nem "bom": df, ps, allowlist, registro ou plist ilegíveis dão rc 30 e nenhuma ação.

## A allowlist
Uma linha por job, 9 colunas separadas por TAB: `id adapter match_regex parent_regex stop_below_mb resume_above_mb resume_window resume_max_age_s como`. O formato, o que qualifica e os candidatos REJEITADOS (com o motivo medido) estão no cabeçalho do próprio arquivo. Hoje só há uma linha ativa:

| id | para quando livre ≤ | retoma quando livre ≥ | janela | validade |
|---|---|---|---|---|
| `rfb-monthly-refresh` | 3072 MB | 8448 MB | 21h–6h | 24 h |

Rejeitados (precisam de marcador "parado pelo D2" no wrapper, para não acordar o Athos com um alarme que o D2 causou): `lotes-rebuild`, `property-search-rebuild`; sem prova de kill seguro: `sync-to-motherduck`; piora o disco: `jsonl-archive-pack`.

## O que o rfb retoma (a pergunta do bead)
**Por tabela, não do ponto.** Cada tabela que termina e é verificada grava `s3://urblink-motherduck-backups/real_estate/rfb/_meta/stream-run-<run_id>.<tabela>.json`; ao retomar com `--resume-run <run_id>` essas tabelas são reaproveitadas, e a tabela em andamento recomeça do **zero** (horas). Por isso o piso de parada é **3 GB**, não os 5 GB em que o orquestrador chama o D2. O tick das 00:15 começa um run NOVO e apaga chaves temporárias com mais de 24 h.

## Registro de "o que parei"
`.gc/disk-recovery-d2.state` (TSV: `epoch EVENT id pid início_epoch run_id livre_mb detalhe`). O `STOPPING` é gravado ANTES do sinal (sem registro, não para: rc 20 e o job segue vivo); `STOPPED` só depois de provar a morte por `ps`. Eventos: `STOPPING → STOPPED | STOP_FAILED`; na retomada `RESUME_STARTED`, `RESUME_REFUSED` (continua pendente), `RESUME_FAILED`, `ABANDONED`.

O `run_id` é `<epoch>-<pid>` do python do job: o D2 o LÊ do S3 (chave `stream-run-<epoch>-<pid>.*` com o pid do processo parado e a hora de início do processo ±5 s). Se não achar ou achar mais de um, grava `-` e o `--resume` tenta de novo. **Nunca adivinha.**

## Retomar
`--resume` só lança quando: há registro pendente; livre ≥ `resume_above_mb`; hora dentro da janela; o registro não passou da validade; o job não voltou a rodar sozinho; o `run_id` existe e tem a forma `^[0-9]+-[0-9]+$`. Lança por `launchctl submit` (desacoplado) com o `EnvironmentVariables` do plist do próprio job (tetos de memória/RSS ficam em sincronia), via `job_timeout.sh --soft`, e vigia alguns segundos. O portão do próprio job (rc 3 "NÃO RODEI": janela ou disco) vira `RESUME_REFUSED` e segue pendente.

## Guardas
Allowlist inválida / regex que casa mais de 3 processos → rc 30. Só processos do mesmo usuário; só o filho do pai certo (`job_timeout.sh` do launchd: `py_compile` ou `--dry-run` rodados por gente/teste nunca casam). Identidade re-conferida logo antes de cada sinal (pid reaproveitado). TERM → graça → KILL só se ainda listado. Trava por `mkdir` com tomada de trava velha. Histerese: `resume_above_mb` > `stop_below_mb` (validado).

## Selftest
`scripts/disk-recovery-d2-heavy-jobs.selftest.sh` (hermético: processos de brinquedo + stubs de ps/aws/launchctl; só mata o que ele mesmo criou). Roda 126 asserções e uma bateria de **10 mutantes** (cada guarda estragada tem de derrubar o seu cenário). Rodar sob o guarda de disco:
```
scripts/heavy-guard.sh --what selftest-d2 --min-free-mb 6144 --max-file-mb 20 -- bash scripts/disk-recovery-d2-heavy-jobs.selftest.sh
```
~2 min (mais com a máquina em swap).

## Quem chama o quê
O orquestrador (`disk-recovery-ladder.sh`, dog-2) chama o D2 só com o disco ≤ 5120 MB por 15 min. **Falta um chamador de `--resume`**: algo (um tick do orquestrador ou um agendador) precisa chamar `disk-recovery-d2-heavy-jobs.sh --resume` quando o disco voltar. Sem isso, o job fica parado até o tick das 00:15 começar um run novo (do zero).

Pendências conhecidas: marcador "parado pelo D2" nos wrappers de `property-search-rebuild` e `lotes-rebuild` (para promovê-los); prova de que a publicação do `lotes-rebuild` é atômica.
