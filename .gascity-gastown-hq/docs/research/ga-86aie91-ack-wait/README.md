# ga-86aie91 · a admissão do gate não espera o ACK do revisor

## Contents

Estado do mundo · O que foi medido · Por que o laço de ACK não decide nada · O que mudou · Projeção (NÃO medida) · Aceite: como medir depois do deploy · Próximo trecho, se faltar · Limites da medição

## Estado do mundo

Gate: ~7-8 admissões/h (medido 01/11), com o teto do nó Hetzner em 7 e só 2-3 revisores remotos vivos. O `quality-gate-dispatcher.sh` é um processo serial que segura o lock durante a rodada inteira. A rodada que admite leva uma mediana de **388 s** (média 415 s) no regime de orçamento pré-admissão de 60 s; o trecho **mais longo** é o laço de ACK do Step 7b (**150 s**, 39%), em que nada muda e o próximo marker espera.

## O que foi medido

`segments.py` (nesta pasta, só leitura) parte cada rodada do `.gc/logs/quality-gate-dispatcher.log` nos marcos do próprio log. Regime atual (`GATE_PREADMIT_BUDGET_SECS=60`, desde 01/11 01:47), 16 rodadas que admitiram, 01/11 01:50–03:50:

| trecho | mediana | média | p90 |
|---|---|---|---|
| pré-admissão (início do sweep → `Found N queued`: Phase C, janitors, mid-sweep) | 142 s | 142 s | 182 s |
| headroom / pool-ceiling | 34 s | 35 s | 39 s |
| escolher, reivindicar, fetch, gate-run bead | 34 s | 36 s | 50 s |
| spawn do revisor e entrega da tarefa | 46 s | 51 s | 69 s |
| **laço de ACK (Step 7b)** | **152 s** | **152 s** | 167 s |
| **rodada inteira** | **396 s** | **415 s** | 490 s |
| intervalo até o próximo sweep (burst de 3 admissões + `StartInterval=60`) | 1 s | 20 s | 61 s |

14 das 16 rodadas finalizaram pelo menos um run: com a fila cheia, cada admissão vem junto de uma finalização, e esse trabalho é inerente. Média por admissão = 415 + 20 = 435 s = **8,3/h** (o log registra 3-9 `Gate-run bead` por hora; 6-9 nas últimas quatro horas).

Janela maior (31/10 18:00 → 01/11 03:50, 62 rodadas, mistura os orçamentos de 150 s e 60 s): rodada mediana 451 s, laço de ACK mediana 152 s, 7,4/h implícitas. O trecho do ACK é o mesmo nos dois regimes.

## Por que o laço de ACK não decide nada

Medido no mesmo log, 14/10–01/11 (18 dias): **1798** tarefas de revisão aceitas pela fila de nudges no 1º envio (1792 `queue`, 6 `submit`) e **2** recusadas. O laço re-enfileirou algo **5** vezes. Gerou **3881** linhas `its task nudge is already queued … NOT stacking another copy`, **940** `never ACKed` (contra 859 `ACK (session-alive)`) e nenhum `ACK (verdict-progressed)`.

A razão está no código: desde ga-g3m45n, `gate_deliver_review_task … retry` devolve rc 10 e não faz nada para um slot cujo nudge a fila já ACEITOU (`REVIEWER_NUDGE_SENT[k]=1`). Com todos os slots assim, o laço só pode ler, dormir 20 s e logar. A flag `REVIEWER_ACKED` que ele grava só é lida por ele mesmo (o selftest trava isso). Um revisor que nunca consome a tarefa é pego fora do laço: Phase C (sessão primária confirmada fechada → re-fila, ga-peb71d), o timeout do run (ancorado em `task-sent-at`) e o gate-recovery-watchdog.

## O que mudou

`packs/town-deltas/assets/quality-gate-dispatcher.sh`:

* `gate_ack_loop_needed` (pura): pula o laço só se **todo** slot ainda sem ACK tem `REVIEWER_NUDGE_SENT` igual a `"1"`. Recusado (0), não preenchido, lixo, misto, sem slots, array não declarado: o laço roda como antes, espera inclusa. Chave de desligar: `GATE_ACK_SKIP=0` ou o arquivo `$GC_CITY/.gc/gate-ack-skip.off` (lidos a cada admissão).
* Step 7b: o texto do laço ficou byte a byte igual (outros selftests o fixam); só entram a decisão antes dele, um `break` no topo, a guarda do `never ACKed after N attempts` (um laço que não rodou não tentou nada) e **uma** coleta de ponto seguro `step-7b-skip` no lugar da 1ª passada do laço: é o que mantém a promessa de ga-yjrg7n6 (runs prontos adiados são coletados quando o último marker da fila foi admitido).

Prova: `packs/town-deltas/assets/gate-ack-skip.selftest.sh` (texto REAL extraído, `gc`/`bd` falsos; 14 mutantes, um por guarda). O mutante "nunca pula" é o comportamento antigo e o selftest o reprova (a região tem de voltar em ≤ 5 s com `ACK_WAIT_SECS=20`).

## Projeção (NÃO medida)

Cortando o trecho do ACK do regime atual: 415 − 152 = 263 s de rodada + 20 s de intervalo médio = **283 s por admissão ≈ 12,7/h** (com medianas daria ~13,8; a média é a que conta, porque rodadas longas existem). Com o orçamento de 150 s a mesma conta dá ~10,7/h. É uma projeção de arquivo de log, não uma medição pós-deploy, e a margem sobre o critério (≥ 12/h) é de uns 6%.

## Aceite: como medir depois do deploy

Por OUTRO dog que não o que implementou, depois do merge e com `Delivery sweep … result=PASS`, numa janela de 1 h com fila ≥ 8 e vaga no nó:

```bash
cd "$GC_CITY_PATH"
# 1. admissões por hora e trechos (a janela = a hora cheia depois do deploy)
python3 -I docs/research/ga-86aie91-ack-wait/segments.py .gc/logs/quality-gate-dispatcher.log --since "YYYY-MM-DD HH:00:00" --hourly
# 2. o ACK foi pulado? (esperado: uma linha por admissão; 'No ACK from reviewer' e 'never ACKed' sumiram)
grep -c 'Step 7b (ga-86aie91)' .gc/logs/quality-gate-dispatcher.log ; grep -c 'never ACKed' .gc/logs/quality-gate-dispatcher.log
# 3. revisores remotos vivos ao mesmo tempo (amostre a cada minuto da janela, guarde o máximo)
gc session list --json | jq '[.[] | select((.template // .session_name // "") | test("gate-reviewer-remote")) | select(.state=="active" or .state=="creating")] | length'
# 4. nenhum run perdido: todo gate-run aberto na janela tem desfecho (PASS/FAIL/requeue) até 1 rodada depois do veredito
bash scripts/gate-queue-composition.sh
```

Critério (do bead): ≥ 12 admissões/h por 1 h; ≥ 5 `gate-reviewer-remote` vivos ao mesmo tempo; nenhum run perdido. Se faltar admissão por hora: a linha `ACK wait (7b)` do `segments.py` tem de estar perto de 0; se estiver, o que sobra é o trecho seguinte.

## Próximo trecho, se faltar

Em ordem de tamanho medido, sem nada implementado aqui:

1. **Finalização fora do caminho crítico** (desenho já escrito em ga-bk5j8u.4, fechada "reabrir se fila > 15"): cauda de FAIL (média 62 s por run FAIL, medida em ga-bk5j8u.3) e fechamento das sessões do revisor (mediana 21 s) em segundo plano. Teto ≈ 35 s por rodada (62 s × ~28% de FAIL + 21 s × ~87% de rodadas que finalizam; estimativa herdada de ga-bk5j8u.3, 14/10, n = 17, NÃO remedida hoje) ⇒ 283 → ~248 s, ≈ +1,8/h.
2. **Burst de 3 → 6 admissões** (`GATE_MAX_ADMITS_PER_SWEEP` no plist, hoje 3): o intervalo médio de 20 s cai para ~10 s, 283 → ~273 s, ≈ +0,5/h. É chave de operação (teto de spawns por lock, ga-zl277) e foi deixada como está.
3. **Phase C que só diz "ainda em voo"**: ~33 s por run conferido; já limitado pelo orçamento de 60 s, e 14 de 16 rodadas finalizam algo de qualquer forma, então o ganho hoje é pequeno.

## Limites da medição

* O log só diz o que o dispatcher escreveu: há trechos sem linha (ex.: ~30 s entre o fim do Phase C e `Found`, janitors), e cada marco é a PRIMEIRA linha do tipo na rodada, exceto `Verdicts requested`, que é a última.
* Amostra do regime de 60 s: 16 rodadas em ~2 h. A mediana e a média do ACK (152 s) são estáveis nas duas janelas; o resto varia mais.
* A projeção supõe que nada além do laço de ACK mude de tempo. Tirar o laço também tira 14 chamadas `bd`/`gc` por admissão de 1 revisor (2 na tentativa 1, 4 em cada uma das 2-4, contadas no código) sob a mesma carga, o que só pode ajudar, mas não foi medido.
* Os 18 dias de contagem de ACK vêm do log retido (rotaciona); não incluem a rodada que o deploy desta mudança vai produzir.
