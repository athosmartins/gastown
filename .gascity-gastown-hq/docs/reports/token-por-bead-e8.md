# E8 — tokens por bead aprovada: o medidor, o baseline de 7 dias e o que o dado diz sobre modelo e effort

Bead ga-5c3msy (P0, filha de ga-ufskhy). Janela: 24/09–01/10/2026 (dias UTC inteiros), transcritos locais + arquivo permanente do S3 (`s3://urblink-claude-history-backup`), log do gate. Somente leitura sobre transcritos e gate; o que a bead entrega e o que ficou para o Mayor decidir estão nas seções 1 e 5.

**Em 7 linhas**

1. **O medidor existe e está certo**: `bead-token-meter.py` dá tokens e US$ por papel × modelo × effort, por bead e por bead aprovada, a partir dos transcritos. Conferido contra uma recontagem independente (8/8 sessões idênticas) e contra o ramo do gate (81/81 atribuições batem). Os transcritos são apagados pelo reaper 24h depois da morte da sessão; um **ledger durável** + uma order a cada 30 min impedem que o histórico evapore (o histórico de 7 dias foi recuperado do S3).
2. **Linha de base (7 dias): ≈ US$ 12,6 mil a preço de lista, 404 beads aprovadas → US$ 31 por bead aprovada, sistema inteiro** (US$ 1,5–2,0 mil/dia). **51% desse total depende de um preço ASSUMIDO**: o Sonnet 5 (anterior ao 5.5) não tem preço na tabela da bead; assumi o do 5.5. Os tokens são exatos; o US$ não.
3. **Onde o custo está**: nos builders 53–72% do US$ é *leitura de cache* (o wa-worker roda a ~330 mil tokens de contexto por turno, ~90 turnos por sessão), 16–30% é escrita de cache e só **12–17% é saída** — a única parte em que o effort age. **Effort é alavanca de 2ª ordem** (teto ≈ 2–4% do gasto do wa-worker); o **tamanho do contexto × nº de turnos** é a de 1ª.
4. **O critério "1ª aprovação não cai mais que 3 pp" não é verificável**: pede ~4.200 beads por braço (≈ 333 dias no volume do wa-worker). Custo/bead −30% se vê em 14 dias; −10% pede 126. Um A/B por bead só enxerga efeitos grandes — a métrica primária tem que ser por mensagem.
5. **A aprovação caiu quando o modelo mudou, e o custo por aprovada triplicou** (wa-worker: 62% → 38% na 1ª tentativa; US$ 33 → US$ 104 por bead aprovada na 1ª), no mesmo dia em que o revisor também foi de Sonnet 5 → 5.5. Observacional; não separa construtor de revisor.
6. **O mecanismo do A/B de effort está pronto e INERTE** (`claude-lowprio.sh`, só age se existir `.gc/effort-ab.conf`; kill-switch sem reload). **Não ativei**: a decisão de ligar é do Mayor, com os números da seção 4 na mão.
7. **Maior alavanca medida, fora do escopo desta bead**: um teto de contexto de ~250 mil nos wa-workers mexe em até **22% do gasto deles** (US$ 825 em 7 dias), contra 2–4% do effort. Mas a janela de compactação tem uma decisão do Athos (31/08) que só ele reabre — seção 4.

---

## 1. O que foi entregue

| Peça | Onde | O que faz |
|---|---|---|
| Medidor | `packs/town-deltas/assets/bead-token-meter.py` | `harvest` (transcritos → ledger), `report` (tokens/US$ por papel, bead, coorte, aprovada, composição, teto de contexto, poder), `backfill-s3`, `prices` |
| Ledger | `.gc/token-ledger/sessions.jsonl` (5.655 sessões) | uma linha por sessão; sobrevive à remoção do transcrito pelo reaper; idempotente, incremental, com `flock` |
| Colheita periódica | `orders/token-ledger-harvest.toml` + `assets/scripts/token-ledger-harvest.sh` | a cada 30 min (medido: 1 s incremental, ~10 s a varredura completa de 1,8 mil transcritos); log em `.gc/logs/token-ledger-harvest.log` |
| Braço de effort | `assets/scripts/claude-lowprio.sh` (bloco "EFFORT A/B") | decide o braço por SHA-256 do nome da sessão e reescreve só o valor depois de `--effort`; **inerte sem conf**; fail-open |
| Testes | `bead-token-meter.selftest.py` (18 casos + 9 mutantes), `claude-effort-ab.selftest.sh` (31 checagens + 6 mutantes), `token-ledger-harvest.selftest.sh` (7) | cada caso existe por um erro real ou plausível; cada mutante do script é reprovado por pelo menos um caso |

**Como o medidor conta (as armadilhas medidas)**

* O Claude Code grava **um registro por bloco** (thinking/text/tool_use) e todos repetem o `usage` da mesma resposta: 512 registros para 187 respostas num worker. Somar linhas inflaria o gasto ~2,7×. Conta-se por `message.id`, entre o transcrito e os de subagente.
* O **effort de cada turno está gravado** no transcrito (`effort`), assim como o modelo: o baseline não infere nada da config.
* Preço: escrita de cache 5 min = 1,25× a entrada, 1 h = 2×, leitura = 0,1×. Modelo sem preço = "n/p" (nunca US$ 0).
* **Bead de um worker = `bd update <id> --claim` com resultado "Updated issue"**. Id citado na 1ª mensagem NÃO conta: o preâmbulo do papel cita ~93 beads de doutrina. Worker com bead já atribuído (sem claim) cai na referência mais citada em `bd show|comment|heartbeat|close` (3 de 294 beads). Crew e Mayor (sessões conversacionais) não ganham bead.
* Revisor: o cabeçalho `QUALITY GATE REVIEW — … for branch: X` chega **dentro de um tool_result**, e pode vir antes um *exemplo* de doutrina; o medidor guarda todos os ramos citados e fica com o que o log do gate conhece.
* Sessão de pool sem claim e sem referência = **spawn ocioso**, linha própria (12/12 amostradas de fato só sondaram a fila e saíram).

## 2. Baseline de 7 dias (24/09–01/10)

Reproduzir: `python3 packs/town-deltas/assets/bead-token-meter.py report --from 2026-09-24 --assume-price claude-sonnet-5=claude-sonnet-5-5`.

**Regimes (UTC, % das mensagens)** — o que mudou, e quando:

| | até 24/09 | 25/09 | 26–27/09 | 28/09 | desde 29/09 |
|---|---|---|---|---|---|
| builders e revisor | Sonnet 5, **effort max** (100%) | xhigh em 74–86% das msgs (ga-ttwzqd) | Sonnet 5 **xhigh** (100%) | Sonnet 5.5 entra (wa 8%, dog 17%, revisor 26%) | **Sonnet 5.5 xhigh** (100%) |

Builder e revisor trocaram de modelo **no mesmo dia** (ambos usam o alias `sonnet`).

**Por coorte do construtor** (modelo e effort da 1ª sessão do bead; custo de retrabalho incluído). "aprov." = aprovada em alguma rodada.

| coorte | beads | 1ª-PASS (IC95%) | build US$/bead | revisão US$/bead | Mtok/bead | US$ por 1ª-aprovada | US$ por aprovada |
|---|---|---|---|---|---|---|---|
| wa-worker Sonnet 5 xhigh | 95 | 62% (52–71) | 16,75 | 3,47 | 72 | 32,6 | 20,4 |
| wa-worker Sonnet 5 **max** | 57 | 68% (56–79) | 15,81 | 2,91 | 65 | 27,4 | 18,7 |
| wa-worker **Sonnet 5.5 xhigh** | 29 | **38%** (23–56) | **33,68** | 5,88 | **137** | **104,3** | 44,1 |
| dog Sonnet 5 xhigh | 77 | 55% (43–65) | 11,55 | 3,59 | 44 | 27,8 | 15,1 |
| dog **Sonnet 5.5 xhigh** | 24 | **38%** (21–57) | 11,40 | 4,72 | 46 | 43,0 | 18,4 |
| dog Sonnet 5 max | 7 | 71% (36–92) | 14,81 | 2,63 | 57 | 24,4 | 17,4 |

294 de 415 beads da janela têm construtor de pool medido (71%); dos 121 restantes, 89 foram construídos por crew (sessão conversacional, sem atribuição por bead), 28 têm branch `fix/feat` sem dono identificável e 4 são lacuna real. **US$ por bead aprovada, sistema inteiro: 12.591 ÷ 404 = US$ 31** (inclui crews, Mayor, produto, revisores, refino e spawns ociosos).

**Leitura**: as linhas Sonnet 5 → 5.5 são o único contraste com amostra, e ele é *observacional*: modelo do construtor, modelo do revisor, o prompt do revisor (E0) e o mix de beads mudaram juntos. Ele sustenta "o custo e a reprovação subiram junto com o 5.5", **não** "o 5.5 construtor é pior". O custo por mensagem também subiu com o 5.5 no mesmo effort (saída/msg do wa-worker 938 → 1.297; turnos por sessão 98 → 116) — coerente com a nota da bead de que os níveis de effort do 5.5 foram *recalibrados* em relação ao Sonnet 5.

## 3. Onde o dinheiro está

**Composição do custo** (% do US$; saída inclui thinking):

| papel | US$ (7 d) | entrada nova | **saída** | escrita de cache | **leitura de cache** | msgs/sessão | contexto/msg | thinking (% da saída) |
|---|---|---|---|---|---|---|---|---|
| wa-worker | 3.659 | 0% | **12,0%** | 15,8% | **72,2%** | 87 | 331 mil | 52% |
| dog | 2.581 | 0% | **17,0%** | 29,9% | 53,1% | 22 | 213 mil | 44% |
| gate-reviewer | 1.717 | 0% | 20,9% | 31,6% | 47,5% | 32 | 152 mil | 69% |
| crew | 2.982 | 0% | 5,9% | 21,5% | 72,6% | 268 | 444 mil | 30% |

* **Effort age só na saída** (e, indiretamente, no nº de turnos). Saída = 12% do gasto do wa-worker; thinking é pouco mais da metade disso. Um corte de 30% do thinking vale ≈ **2% do gasto do wa-worker**, de 30% de *toda* a saída ≈ 3,6%. Experimento natural (mesmo modelo, Sonnet 5, `max` → `xhigh`): o thinking por mensagem caiu 33% no wa-worker e 41% no revisor, e só 5% no dog — o efeito existe, o teto é pequeno.
* **O gasto é contexto × turnos**: o wa-worker roda a **331 mil tokens de contexto por turno** (média da semana; nas últimas 40 h, 40 sessões, todas Sonnet 5.5: mediana 332 mil, p90 601 mil, máx 866 mil) e ~87 turnos por sessão; o contexto do 1º turno de um wa-worker recém-nascido é 110 mil (dog 74 mil, ps-worker 84 mil, revisor 53 mil — `pool-preamble-measure.py first-turn`).
* **Teto de contexto** (limite SUPERIOR da economia de compactar antes — ignora o custo da compactação e o risco de qualidade): US$ de leitura de cache *acima* do teto, como % do gasto total do papel:

| papel | acima de 150k | acima de 250k | acima de 350k |
|---|---|---|---|
| wa-worker | 39,3% (US$ 1.446) | **22,4% (US$ 825)** | 11,7% (US$ 431) |
| dog | 19,7% | 8,7% | 3,6% |
| gate-reviewer | 7,8% | 0,6% | 0,0% |
| ps-worker | 0,6% | 0% | 0% |

* **Spawn ocioso**: 1.056 de 1.556 sessões de dog (68%) não acharam trabalho — US$ 517 — **mas quase tudo foi em 24–27/09 (369/398 em 24/09) e caiu a ~0 a partir de 28/09** (5/73, 7/68, 2/81, 0/13): já está resolvido, não há o que fazer. O **ps-worker segue ocioso** (97% na semana: 266 de 275 sessões, US$ 113 ≈ US$ 16/dia, 0,9% do gasto; 74/79 em 29/09, 42/46 em 30/09). wa-worker: 18% ocioso na semana (88 de 478); 0 em 30/09 e 01/10.

## 4. O A/B de effort: o que o volume permite, o que está pronto, o que decidir

**Poder de um A/B por bead** (alfa 5%, poder 80%, braços 50/50, todos os beads do papel entrando):

| papel | beads/dia | CV do US$/bead | custo −10% | custo −20% | custo −30% | 1ª aprovação ±10 pp | ±5 pp | ±3 pp |
|---|---|---|---|---|---|---|---|---|
| wa-worker | 25 | 1,01 | 1.597/braço (126 d) | 399 (31 d) | **177 (14 d)** | 387 (30 d) | 1.531 (120 d) | **4.227 (333 d)** |
| dog | 16 | 1,16 | 2.127 (262 d) | 532 (65 d) | 236 (29 d) | 390 (48 d) | 1.568 (193 d) | 4.359 (536 d) |

Duas consequências: (i) **"não cair mais que 3 pp" não pode ser o critério** — nenhum experimento por bead fecha isso; (ii) **a métrica primária do A/B tem que ser por MENSAGEM/turno** (saída e thinking por mensagem, milhares de amostras por semana), e a aprovação vira *trava de segurança*: parar e escalar se, com ≥ 40 beads por braço, o braço `high` estiver ≥ 10 pp abaixo do controle — é um alarme, não um teste (só detecta queda grande).

**O que está pronto (inerte)**. Em `claude-lowprio.sh`, com `.gc/effort-ab.conf` presente, cada sessão enrolada lançada em `control_effort` cai num braço por `SHA-256("effort-ab:<salt>:<nome da sessão>")`. O braço é fixado **antes** de a sessão ver qualquer bead, e o bead que um worker de pool pega é o mais antigo pronto — braço e bead são independentes, a mesma propriedade que o A/B do E3 tira do hash do id do bead. O log `.gc/logs/claude-lowprio.log` grava cada decisão com o `--session-id` do claude; o transcrito grava o effort efetivo (`effort`), então "o braço chegou no processo?" é um join. O `report` já coorta por **effort efetivo** — é a própria análise.

**Para ligar** (decisão do Mayor — ver recomendação abaixo):

```
cat > $GC_CITY_PATH/.gc/effort-ab.conf <<'EOF'
salt=ga-5c3msy-1
enroll=wa-worker gastown.dog ps-worker
control_effort=xhigh
treat_effort=high
treat_pct=50
EOF
```
Desligar: `rm .gc/effort-ab.conf` (ou `touch .gc/no-effort-ab`); vale na próxima sessão lançada, sem reload. Conferir depois de 1 h: `grep 'EFFORT-AB arm=' .gc/logs/claude-lowprio.log | tail`.

**Recomendação (técnica; o Mayor decide)**

1. **Ligar o A/B só no wa-worker** (o maior gasto e o de maior efeito natural do effort), 50/50, e ler a **saída/thinking por mensagem** semanalmente. Esperar ~3% de ganho de custo; só vale se a trava de aprovação ficar quieta. Se o objetivo é *menos tokens*, este é o experimento de menor retorno.
2. **O de maior retorno é o teto de contexto nos wa-workers** (até 22% do gasto deles, ≈ US$ 110/dia). A janela de compactação foi decidida pelo Athos em 31/08 ("900k em todos os 7"; reabrir só com decisão dele) por causa de um *loop de compactação* nos papéis de vida longa, cuja base é ~260 mil tokens. O contexto do 1º turno do wa-worker é **110 mil** — um teto de 300 mil deixaria ~190 mil de folga, contra os ~40 mil da época do loop. Mas o loop de 31/08 foi medido *na volta da compactação* (260 mil, com resumo e releitura), e a nota do próprio config diz que "o piso seguro tem que ser ≫ o contexto base medido na hora, não um palpite": a base pós-compactação do wa-worker não está medida aqui. É decisão de risco do Athos, não minha. O mesmo mecanismo do braço serve (acrescentar uma chave de variável de ambiente por braço). Não implementei: precisa do "sim" dele.
3. **ps-worker ocioso** (US$ 16/dia): corrigir quando alguém mexer no reconciler do pool; o do dog já se resolveu sozinho em 28/09.

## 5. Limites e o que NÃO foi medido

* **US$ = preço de lista da API**, não fatura. **US$ 6,4 mil de 12,6 mil usam o preço do Sonnet 5.5 para o Sonnet 5** (`--assume-price`, rotulado com `~` na saída). Sem a suposição o relatório mostra "n/p" e deixa esses tokens fora do total. Tokens/Mtok por bead não dependem de preço. Haiku 4.5, Opus 4.7 e Sonnet 4.6 não têm preço na tabela (196 Mtok, fora do total).
* **Sessões de subagente de crew/Mayor restauradas do S3 não foram baixadas** (1.970 objetos, 451 MB): o gasto de crew/Mayor está *subestimado* no S3; nos transcritos locais entram. Não afeta os builders de pool (não usam subagente).
* **Construtor = 1ª sessão do bead** (intenção de tratar). Crew e Mayor ficam sem atribuição por bead; 153 sessões de revisor não têm ramo conhecido do gate e ficam fora do custo de revisão por bead (entram no total do sistema).
* **A comparação Sonnet 5 × 5.5 é observacional** (construtor, revisor, prompt do revisor e mix mudaram juntos). Aprovação é a **1ª rodada real do gate** (a mesma definição do `pool-preamble-measure.py`); 20 linhas ilegíveis do log do gate são ignoradas e contadas.
* **O custo da pré-revisão do E3 não aparece aqui**: `pre-gate-review.sh` roda `claude -p --no-session-persistence` (0 sessões `pregate-review` no ledger), então não deixa transcrito; o custo exato está nas linhas próprias dela (`pre-gate-apuracao.py`). O `rev US$/bead` da tabela é só de revisores do gate.
* **A integridade do histórico restaurado**: o backup do S3 rodou todo dia às 04:00 (88 execuções, 0 erro no log), sem `--delete`; o reaper só apaga transcrito morto há > 24 h, então sempre há um backup no meio. Nenhum buraco de dia na janela.

## 6. Reproduzir e verificar

```
python3 packs/town-deltas/assets/bead-token-meter.py harvest                 # ledger (a order faz isso sozinha)
python3 packs/town-deltas/assets/bead-token-meter.py report --from 2026-09-24 --assume-price claude-sonnet-5=claude-sonnet-5-5 [--json]
python3 packs/town-deltas/assets/bead-token-meter.py backfill-s3 --since 2026-09-24   # histórico que o reaper já apagou (lotes de 400 MB, guarda de disco)
python3 packs/town-deltas/assets/bead-token-meter.selftest.py ; bash packs/town-deltas/assets/claude-effort-ab.selftest.sh ; bash packs/town-deltas/assets/token-ledger-harvest.selftest.sh
```
Cobertura de teste que a 1ª versão do medidor não tinha e o teste achou: o pré-filtro de linhas dependia do espaçamento do JSON (formato novo = zero mensagens lidas, silenciosamente) — hoje lê igual e há um alarme quando ≥ 25% das sessões grandes de uma colheita voltam com 0 respostas.
