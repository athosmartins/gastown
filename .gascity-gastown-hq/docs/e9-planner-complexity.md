# E9 — refino como PLANEJADOR + nível de COMPLEXIDADE (ga-798p6w, filho do P0 ga-ufskhy)

**Estado em 01/10/2026: construído e INERTE.** Sem `.gc/e9-ab.conf` nada muda no fluxo de ninguém. Ligar é decisão do Mayor (§5).
**Dependência que ainda falta:** o veredito de custo e de aprovação usa o medidor do E8 (`bead-token-meter.py`, ga-5c3msy). Hoje ele
existe só num commit WIP (`f67779821`) numa branch não mergeada. Sem `--meter` a apuração diz "CUSTO E APROVAÇÃO — NÃO MEDIDOS" e
não decide nada. Braços, roster e custo do planejador já funcionam.

O que o Athos pediu (01/10 06:56): (a) todo refino atribui um nível de complexidade, e o nível escolhe modelo × effort do construtor;
(b) o refino entrega "mais mastigado" — não só o QUÊ, mas o COMO (arquivos, funções, casos-limite, teste que reprova). E que se avalie
de forma **científica** se isso cumpre o objetivo: mais beads em DONE, menos tokens por bead DONE.

## 1. Onde o plano é feito — e por que NÃO só no refino

Medido em 01/10/2026 14:00Z, HQ + whatsapp_automation, beads que passaram o gate (`close_reason` começa com "Quality gate PASSED")
nos últimos 7 dias exatos (`closed_at >= 24/09 14:00Z`):

| tipo | beads | % |
|---|---|---|
| bug | 117 | 69% |
| task | 37 | 22% |
| chore | 8 | 5% |
| feature | 8 | 5% |
| **total** | **170** | |

O auto-refino só pega `feature`/`story` (`auto-refino-dispatcher.sh:16,251`: "bug/chore/task SKIP the funnel", ga-flxp6). Logo, **no máximo
8 de 170 (4,7%)** das beads entregues passaram ou poderiam ter passado pelo refino. Um planejador que mora só no refino planeja ~5% do que
se constrói: não move "tokens por bead DONE" e não chega a uma amostra. (A primeira medição do construtor anterior deu 5 de 134, 3,7%, numa janela
e contagem ligeiramente diferentes; a conclusão é a mesma e esta tabela a substitui.)

Reproduzir: `bd -C <store> list --status closed --closed-after 2026-09-24 --limit 0 --json`, filtrar `close_reason`, agrupar por `issue_type`,
para os dois stores (HQ e `whatsapp_automation`). `--limit 0` é obrigatório (o default trunca em 50 sem avisar no JSON).

O ponto por onde TODA construção passa é o **início do build**. É aí que o plano é feito (`e9-plan.sh`), disparado pela linha extra que o Pilot
põe no comentário de despacho — só para bead do braço `on`. O gancho do refino (`e9-arms.sh block|finalize|check|plancheck`) existe, é testado e
continua DESLIGADO: ninguém o chama ainda. Uma bead que já traz plano válido (de qualquer um dos dois estágios) é REUSADA, nunca replanejada.

## 2. O que existe (todos em `packs/town-deltas/assets/`, salvo indicação)

| arquivo | papel |
|---|---|
| `e9-arms.sh` | biblioteca: braço (SHA-256 do id, salt, % do conf), roster, nível-a-partir-dos-fatos, checagem de estrutura do plano, estado do conf |
| `e9-plan.sh` | o planejador de início de build: uma execução `claude -p` Opus SOMENTE-LEITURA (Read/Grep/Glob), devolve FATOS + plano de 5 seções |
| `pilot-dispatcher.sh` (`_e9_dispatch_line`) | a linha no comentário de despacho; vazia em todo caminho de dúvida |
| `scripts/e9-apuracao.py` | a apuração (READ-ONLY): compara os braços pelo critério do §4 |
| `*.selftest.sh` (4) | contratos de cada peça, com controles de mutação |

Garantias que valem para o conjunto:

- **Inerte por padrão.** Sem conf, com a chave-kill `.gc/no-e9-ab`, ou com conf malformado: nenhuma linha no despacho, nenhum gasto, nenhuma linha no roster.
  Conf malformado é um estado próprio (`invalid`), não "sem conf": um typo não pode rodar o experimento a 0%.
- **Três estados, nunca dois.** Braço `on` / `off` / "não sei dizer" nunca imprimem a mesma coisa. Um `assign` que falha, estoura o tempo ou imprime lixo
  NÃO vira `on` (apontaria um construtor para uma execução Opus paga de uma bead que não está no braço). Custo desconhecido é "desconhecido", nunca US$ 0.
- **Braço controle = o fluxo de hoje**, byte a byte; mas é REGISTRADO no roster (um controle sem denominador não é controle).
- **O planejador não age.** Sem Bash, sem rede, sem edição, sem identidade de sessão; o texto da bead entra cercado como DADO. O plano nomeia
  arquivos: se algum não existe, o plano NÃO é entregue (plano errado é pior que nenhum).
- **Todo gasto deixa linha.** Duas linhas `plan_run` por execução (PENDING antes de gastar, FINAL depois); se a PENDING não pode ser escrita, a execução não começa.
- **Teto de gasto:** US$ 4 por execução, 2 execuções por bead, 900 s, 2 concorrentes, e a guarda de máquina (disco/swap) recusa em vez de somar carga.
- **Intenção de tratar.** Uma bead `on` cujo planejador falhou (exit 3, INCONCLUSIVE) continua no braço `on` na análise; a aderência sai em separado.

## 3. Complexidade: campo de MEDIÇÃO primeiro; o roteamento NÃO foi construído aqui

O nível (S/M/L) é **calculado, nunca declarado**: o planejador registra FATOS (arquivos, superfícies, externo, migração) e o código os transforma
em nível. L se envia algo para fora do sistema, exige migração, toca ≥ 3 superfícies ou ≥ 8 arquivos; S se ≤ 2 arquivos em ≤ 1 superfície sem nada
disso; M o resto. `check` recalcula e acusa nível que discorda dos próprios fatos. Fato que o planejador não consegue estabelecer vira
"desconhecido", que não é S.

Gravado na bead: `story.complexidade_fatos`, `story.complexidade`, `story.plano_tecnico`, label `complexity:<nível>`.

**Por que o roteamento (S → Sonnet high, M → xhigh, L → Opus high) não entra neste slice:**

1. O próprio pedido diz que a tabela é "ponto de partida, não a resposta" e que, sem amostra para um fatorial, se testa **um fator de cada vez, começando pelo planejador**.
2. Amostra: o critério do §4 pede 174 beads com custo conhecido por braço. A ~170 beads entregues por semana e 50% no `on`, isso é ~85 por braço por semana, ~2 semanas
   para UM fator. O 2×2 (planejador × roteamento) precisa de 4 células: ~4 semanas, com o planejador confundido com a mudança de modelo se rodarem juntos.
3. O roteamento por bead depende de o construtor receber modelo × effort por bead, que é a infraestrutura do E8 (ga-5c3msy, ainda em andamento). Construir uma segunda cópia aqui criaria duas fontes de verdade.

A tabela de roteamento fica como hipótese para o slice seguinte, que só começa depois do veredito do planejador (ou em paralelo se o E8 já entregar o gancho).
**Limite assumido:** hoje o nível é registrado só para beads do braço `on` (é o planejador que o calcula). O controle não tem nível gravado; a apuração
estratifica pelos dois braços usando o tamanho REALIZADO (arquivos no git), não o nível previsto.

## 4. Critério PRÉ-REGISTRADO (a regra de veredito; decisão é do Mayor, o script nunca age)

Escrito antes de haver dado, e implementado como padrão de `scripts/e9-apuracao.py` (flags entre parênteses). Mudar um número depois de ver o resultado invalida o experimento.

- **Amostra:** n ≥ 174 beads **com custo conhecido por braço** (`--min-n`; vem do E8: −30% de custo com CV 1,0). Abaixo disso o veredito é **INCONCLUSIVO**,
  qualquer que seja a estimativa. Não se para o experimento quando o número agrada.
- **Métrica primária:** custo (US$) por bead APROVADA = construtor + planejador + revisor × rodadas. **O custo do próprio planejador entra na conta** — um plano que
  economiza o que custa não é vitória.
- **ADOTAR** só se: o custo por bead aprovada do `on` é pelo menos **30%** menor (`--min-effect`) com o limite superior do IC de 95% abaixo de 0, **e** a aprovação na
  1ª tentativa não cai: estimativa da diferença on−off ≥ **−3 pp** (`--max-fp-drop`) **e** limite inferior do IC ≥ **−10 pp** (`--fp-ci-floor`).
  Por que não "IC ≥ −3 pp": provar não-inferioridade de 3 pp exige ~4.200 beads por braço; a regra nunca chegaria a ADOTAR. O que a guarda NÃO prova
  (uma queda real entre 3 e 10 pp) é dito no veredito.
- **NÃO ADOTAR** se mesmo o melhor extremo do IC não alcança os 30%, **ou** a queda de aprovação já passa de 3 pp com confiança (limite superior do IC < −3 pp).
- **INDETERMINADO** em todo o resto, e quando mais de **10%** das beads de um braço ficam sem custo conhecido (`--max-unknown-share`).
- **Sinal de que o plano erra:** o construtor põe `PLAN-DEVIATION: <por quê>` no corpo do commit quando o código contradiz o plano; a apuração conta.

## 5. Operação

Ligar (decisão do Mayor — afeta o custo do pool, cada plano é uma execução Opus):

```bash
cat > "$GC_CITY_PATH/.gc/e9-ab.conf" <<'EOF'
planner_pct=50
salt=e9a
EOF
```

Desligar: `touch "$GC_CITY_PATH/.gc/no-e9-ab"` (ou remover o conf) — vale no próximo despacho, sem reload. O roster
(`.gc/e9-roster.jsonl`) e os planos guardados (`.gc/e9-plans/`) ficam para a apuração.

Estado e braço de uma bead: `bash e9-arms.sh state` · `bash e9-arms.sh arm planner <bead-id>` (receita recomputável por qualquer um:
`printf '%s' "e9-planner:e9a:<bead-id>" | shasum -a 256 | cut -c1-8`, em decimal módulo 100, `< planner_pct` ⇒ `on`).
O prefixo `e9-planner:` não é enfeite: o braço do E3 é a paridade de SHA-256("pregate:<id>"); dois experimentos sobre as mesmas beads não podem ser a mesma moeda.

Ler o resultado (read-only, a qualquer hora):

```bash
python3 scripts/e9-apuracao.py --meter <saída de bead-token-meter.py report --json> --repo /Users/athos/gt
```

Sem `--meter` (hoje, até o E8 ser mergeado) a parte de custo e aprovação sai "NÃO MEDIDOS", e a de roster/execuções do planejador sai normalmente.

O que o construtor vê (braço `on`): uma linha no comentário de despacho mandando rodar `bash e9-plan.sh run <bead> --store <store>` e partir do plano impresso.
`exit 3` (nenhum plano pôde ser feito) **não é veredito sobre a bead**: constrói-se como sempre.

## 6. Riscos e o que a medição vai dizer

- O planejador gasta tokens (Opus) e pode errar o COMO; o construtor segue um plano errado. Mitigação: o plano com arquivo inexistente é descartado, `PLAN-DEVIATION` é contado,
  e o custo do planejador está na métrica primária.
- O ganho esperado vem do COMO técnico, não de mais texto de produto: no E4, 53% das reprovações do gate são caso-limite / 3º estado e "história ambígua" é só 1,3%.
- Beads de bug/chore/task (95% do que se entrega, 162 de 170) agora podem receber plano: o estágio de início de build não tem o filtro de tipo do refino. O roster **não grava o tipo**
  da bead (a linha `assign` tem bead, store, salt, braço, pct, complexity e stage), e a apuração estratifica por **tamanho realizado** (arquivos no git), não por tipo. Se o efeito por
  tipo importar, o tipo precisa entrar na linha `assign` — fora deste slice.

## 7. Fora deste slice

Roteamento modelo × effort por nível (§3) · ligar o gancho do refino (`e9-arms.sh block|finalize`) · decisão de ligar o experimento e de qual `planner_pct` (Mayor).
