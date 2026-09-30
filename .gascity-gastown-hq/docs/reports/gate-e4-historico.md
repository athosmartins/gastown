# E4 — o histórico inteiro de reprovações do gate, e a Frente 6 (defeito latente)

Bead ga-26k2y1 (P0, filha de ga-ufskhy). Dados: 09/06–30/09/2026 (o primeiro veredito do dispatcher é de 09/06), os 4 bancos Dolt, somente leitura. Scripts e como reproduzir: `gate-e4-historico/README.md`.

**As 5 mudanças de maior impacto — medidas aqui, nenhuma aplicada; "% dos FAILs" = vereditos de FAIL de revisor (n = 1.679), salvo onde dito.**

1. **Verificação mecânica do "terceiro estado" no construtor, antes do gate** (o E3, ga-gnr3tw, com a lente guiada por estes dados + um mapa por-diff dos pontos de leitura). Teto: **62,6%** dos vereditos só contêm defeitos de classe B/C/D (**71,5%** depois de 25/09). Estimativa: **16–31%** dos FAILs (**18–36%** no regime atual), supondo 25–50% de captura — hipótese, não medida ⇒ aprovação na 1ª tentativa **+8 a +16 pp** (56% → 64–72%). Evidência: 53,0% dos blocking issues são caso-limite/3º estado; em **37,4%** dos 227 pares com diff completo a correção que "deveria ter vindo de primeira" foi um guard de 3º estado.
2. **Primeira revisão completa**: 2º revisor independente no 1º FAIL e em todo diff ≥ 800 linhas + o parecer lista arquivos/trechos examinados. **Frente 6: 52,7% dos blocking issues de rodada ≥ 2 eram LATENTES** (já estavam na rodada 1; 164 de 167 verificados contra o git) e **45% das rodadas ≥ 2 são inteiramente latentes** (105 de 232; equivalem a 17% de todos os FAILs de revisor da Era B — o numerador só conta as 122 beads julgadas, então é uma referência, não um teto estrito). Estimativa: **7–17%** dos FAILs. Corta rodadas e horas; **não** move a aprovação na 1ª tentativa.
3. **Consertar a mecânica do gate**: **11,0%** das tentativas reprovadas (207 de 1.886) nem tiveram revisão de código (timeout do revisor 110, merge falho depois de ALL PASS 30, bead já fechada 17…) e **3,2%** das beads têm isso como 1º resultado (⇒ +2,3 pp de aprovação); e **6,9%** das runs entregam ao revisor um diff PARCIAL (1,6% veem < 10% do diff; FAIL de 64% nesses, contra 38,8% quando o revisor recebe o diff inteiro de uma mudança de ≥ 800 linhas — a comparação de mesmo tamanho; os 24,5% de "diff inteiro de qualquer tamanho" misturariam o efeito do tamanho).
4. **Estender o "teste tem que falhar na base" (ga-rstae) de `*.selftest.sh` para pytest/js**: teto **10,1%** dos FAILs (12,5% depois de 25/09), mecânico, sem LLM.
5. **NÃO investir agora em**: texto de história/refino (sem efeito detectável por proxy de palavra-chave; classe "história ambígua" = 1,3% dos issues), regex-lint como porteiro (dispara em 20%, 41%, 36% e 96% dos diffs já **aprovados** — reprovado×aprovado: 20%×20%, 39%×41%, 31%×36%, 93%×96%), nem "quebrar bead grande" para subir aprovação (o risco por linha **cai** com o tamanho: partir aumentaria o total de FAILs). E: o patamar mudou — aprovação na 1ª tentativa por bead foi **73,5% → 56,0%** em 25/09 (recall do revisor); metas devem partir do novo piso.

---

## 1. O estado do mundo em 5 números

| | valor |
|---|---|
| beads que passaram pelo gate (09/06–30/09) | **3.858** (3.813 já mergeadas, 2 needs-human, 43 abertas) |
| aprovação na **1ª tentativa** (por bead: o 1º desfecho do gate é PASS) | **72,1%** (2.783 de 3.858; 2.758 nunca reprovaram — a diferença são 25 beads que passaram e foram ao gate de novo) — na linha dos 71% (659/931) da taxonomia do Mayor de 12/08 |
| antes / depois de 25/09 13:04 -03 (prompt v2 do revisor) | **73,5%** (n = 3.567) → **56,0%** (n = 291); por tentativa: 76,2% na semana anterior ao corte (18/09→25/09, n = 651) → 52,1% depois (n = 572) |
| beads com ≥ 1 FAIL / com ≥ 2 / com ≥ 3 | 1.100 (28,5%) / 409 / 173 |
| FAILs (tentativas) | 1.886: **87,1%** revisor com blocking issue, 1,9% revisor sem marcador parseável, **11,0% mecânica do gate** |

Uma bead reprovada quase sempre passa (1.055 das 1.100 já passaram; das que o gate já encerrou, 1.055 de 1.057 — as outras 43 seguem abertas): o FAIL é **custo de retrabalho**, não perda. Cada FAIL = 1 rodada de gate + 1 sessão de conserto; ciclo entre um FAIL e o próximo desfecho: mediana 1,5 h, média 5,7 h, p90 7,8 h (relógio, inclui fila e espera — não é esforço do construtor); computação de gate das runs reprovadas (Era B): mediana 15 min, soma 187 h.

**Correção ao número de partida.** "3.258 comentários GATE-FEEDBACK em 962 beads" conta por substring e **dobra os vereditos**: em WA/setembro, 515 comentários começam com `GATE-FEEDBACK`; dos outros 503 que só o citam, 472 são da identidade do dispatcher (`Test`) — numa amostra de um dia, 11 de 11 são o aviso "Gate FAILED (attempt N/3)… See GATE-FEEDBACK above", um por FAIL. Os vereditos reais são **1.886** (WA 1.655, hq 200, property_scrapers 30, gastown 1), em 1.100 beads. Outros cinco comentários começam com `GATE-FEEDBACK` e não são vereditos do dispatcher — 4 respostas de construtor e 1 parecer postado à mão, sem o cabeçalho `(gate_run=…)` — e ficam fora.

## 2. Dados e método (o suficiente para julgar os números)

* **Fonte única, duas eras.** Comentários de gate na bead de origem (todos os bancos, 06/06→): 1.886 vereditos do dispatcher (`GATE-FEEDBACK (gate_run=…)`), 3.889 merges distintos (`Quality gate PASSED`, ver "Limites" sobre duplicatas) e 2.224 blocking issues (2.188 com marcador `Blocking issue N`). **Era B** (18/08→) tem além disso o registro `gate-run` no hq (2.690 runs) e, em cada bead de revisor, a **tarefa completa** entregue ao revisor: autor, sha, arquivos, **o diff inteiro que ele viu** e o parecer. Foi isso que tornou a Frente 6 e os pares possíveis sem depender de sha solto no git. Era A (06/06–17/08) tem só comentários e labels.
* **Extração:** paginada por dia (um mês no hq estoura o `read_timeout` de 30 s do Dolt), 0 erros em 6 grupos de consulta, 10,6 min. Veredito do dispatcher que cola o mesmo texto várias vezes (até 6×) conta uma vez.
* **Classificação:** **censo** de todos os 2.224 issues (o pedido era ≥ 600), taxonomia FIXA A–F + Z (processo/não-código — acrescentei o Z: sem ele "branch obsoleta" não tem casa) com subtags fechadas (`taxonomy_prompt.md`), Sonnet 5.5 em lote (8–12 por chamada). **2º julgamento independente** em 221 issues (10%, estratificado mês×rig, semente fixa) por Opus 5.5: **88,7%** de concordância na classe [83,8–92,2], **κ = 0,82**, Jaccard médio das subtags 0,57 (as subtags são menos confiáveis que as classes). Desacordos: 19 de 25 são B↔A (a fronteira "caso-limite × bug comum"). Confiança < 0,6 em 9,8% dos issues.
* **Pares reprovado→aprovado:** **264 julgados** (356 candidatos na Era B; uma por bead, amostra por mês proporcional ao volume com piso de 20 — os meses pequenos entram inteiros), dos quais **227 têm o diff completo nos dois lados e são os analisados**. O "delta" da correção sai das duas tarefas armazenadas (linhas do diff aprovado que não estavam no reprovado e vice-versa) — sem git — e por isso só vale com diff completo: os arquivos que um diff parcial omite apareceriam como acrescentados ou removidos pela correção (37 pares ficam de fora).
* **Custo do estudo:** ≈ US$ 42 de LLM em lote; 0 mensagens, 0 comentários fora desta bead, 0 escrita em Dolt/repositórios.

## 3. O que reprova (item 2 do pedido)

### 3.1 Classes (n = 2.224 blocking issues; classe primária)

| classe | tudo | antes de 25/09 (n = 1.836) | depois (n = 388) |
|---|---|---|---|
| **B** caso-limite / 3º estado | **53,0%** | 52,2% | 56,4% |
| **A** bug de comportamento | 29,4% | 31,4% | **20,1%** |
| **C** comentário/log/label promete mais que o código | 7,9% | 6,6% | **13,9%** |
| **D** teste não prova o que diz | 7,9% | 7,7% | 8,8% |
| **E** escopo / história | 1,3% | 1,5% | 0,5% |
| **F** especulativo | **0,3%** (7) | 0,3% | 0,3% |
| **Z** processo, não-código | 0,2% | 0,2% | 0,0% |

Confirma a amostra de ga-ufskhy/E0 em escala (F ≈ 0: **os FAILs não são infundados**) e mostra o que o prompt v2 mudou: A cai, **C dobra** (comentário enganoso passou a bloquear), B fica.

Subtags mais frequentes (% dos issues que carregam a tag): `b.third_state_other` 20,0 · `b.error_swallowed_default` 17,4 · `a.wrong_logic` 14,9 · `b.empty_read_as_ok` 12,7 · `x.external_effect` 8,1 · `b.malformed_input` 7,9 · `a.integration_contract` 7,7 · `b.stale_state` 6,9 · `a.regression` 5,8 · `b.boundary` 5,1 · `c.absolute_comment` 4,8 · `b.race_concurrency` 4,7 · `d.path_not_exercised` 4,2 · `b.decided_var_not_acted_var` 3,9 · `d.vacuous_pass` 2,6. **Composição por veredito** (o que importa para "quanto um conserto previne"): só-B 46,3% · só-A 24,9% · só-C 5,4% · só-D 6,4% · **só B/C/D 62,6%** (61,0% antes, 71,5% depois) · ≥ 1 issue de B 59,3% · ≥ 1 de D 10,1% · ≥ 1 de C 9,8% · com E/F/Z apenas 2,3%.

**Reconciliação com a taxonomia de 12/08** (ga-rstae, 443 issues, multi-rótulo por palavra-chave): lá "comentário mente" 30%, "3º estado" 30%, "teste não pega" 22%, "escopo" 21%. Aqui cada issue conta **uma vez**, pela classe do defeito, e não pela menção: visão multi-rótulo por tag dá c.* 9,2% · 3º estado 42,4% · d.* 8,8% · escopo 1,4%. Não há contradição — lá a palavra "comentário" bastava; aqui o comentário tem de ser o defeito. O achado central de 12/08 **se confirma e se agrava**: a doutrina já está no prompt do construtor e o volume não caiu (a fatia C dobrou quando o revisor passou a bloquear comentário enganoso).

### 3.2 O que a correção acrescentou (item 3 do pedido; 227 pares reprovado→aprovado com diff completo nos dois lados, de 264 julgados)

| a correção acrescentou… | % dos pares |
|---|---|
| teste de caso-limite novo | 72,2 |
| comentário/docstring/mensagem reescrito | 70,9 |
| correção de lógica | 69,6 |
| **guard de 3º estado** | **45,4** |
| alinhamento de contrato (mesma variável decidida e agida; canônico × cru) | 34,8 |
| teste que passou a exercitar o caminho | 32,2 |
| escopo acrescentado / removido | 6,2 / 4,8 |

"O que deveria ter feito de primeira" (a única correção que, feita na 1ª versão, mais provavelmente evitaria a reprovação): **guard de 3º estado 37,4%**, alinhamento de contrato 21,1%, teste de caso-limite 20,7%, teste que exercita o caminho 9,3%, comentário 6,2%, lógica 2,2% (nenhuma: 2,6%). **73,1%** das correções foram **além do exemplo citado** (cobriram irmãos ou a classe) — o conserto chega à classe, só que depois de uma rodada; a correção toca só testes em 5,3% e tem mediana de +73/−7 linhas. Antes de 25/09: 70% (n = 166); depois: 80% (n = 61) — diferença não significativa (z = 1,5; p = 0,14). Incluindo os 37 pares de diff parcial (contaminados) o guard de 3º estado aparecia em 47,0% e como "primeira vez" em 41,3%: inflado pelo delta falso; o bloco de comparação está na saída de `e4_final.py` (seção 5).

## 4. Lado da história e do construtor (item 4 do pedido)

Aprovação na 1ª tentativa por bead, e o que a explica (regressão logística, n = 3.858; Era B, n = 1.701, com tamanho e construtor):

* **Tamanho é o preditor mais forte** (odds ×0,55 por e-fold do diff, z = −7,7). Antes de 25/09: < 200 linhas 89,2% · 200–799 77,5% · 800–2.999 66,4% · ≥ 3.000 55,6% (n = 9); depois: 74,6% · 58,3% · 40,3% · 25,0% (n = 12).
* **Regime** (depois de 25/09): odds ×0,32.
* **Tipo:** feature 56,8% contra bug 76,9%, chore 80,2%, task 70,2% (odds feature ×0,42; ×0,51 na Era B). Beads que tocam efeito externo (envio, ligação, Pipedrive…): 70,6% contra 75,7% (×0,70; some no controle por tamanho).
* **Citar arquivos na descrição** ajuda um pouco (×1,19–1,26 por unidade de log; 0 caminhos 65,9% × 1–5 caminhos ≈ 75%).
* **Sem efeito medido:** quem construiu (crew 74,8% n = 1.300 · dog 74,8% n = 361 · marker-mayor 73,7% n = 38), rig (wa 71,7 · hq 75,0 · ps 74,0), tamanho da descrição, "menciona caso-limite" (**72,1% × 72,2%**), "menciona modo de falha" (71,6 × 72,2), critério de aceite na descrição (+2,8 pp, z = 1,3–1,8), diff parcial (×1,23, n.s. depois de controlar o tamanho).

Limites: os traços de história são **proxies por palavra-chave** e labels de estado atual (só uso `lane/ctx/exec/refino`, postos antes do construtor); a identidade do construtor vem do campo "autor" do marker, que em 44% das runs da Era B diz `mayor` — só resolvo pelo nome da branch (`crew/<nome>/…`); as ≈ 2.150 beads sem run registrada (Era A) ficam sem tamanho nem construtor. **Leitura honesta:** o que o Athos escreve na história explica pouco da reprovação; o que explica é o tamanho da mudança, ser feature e o rigor do revisor.

**Aprovação × tamanho, sem se enganar.** FAILs de 1ª tentativa por 100 linhas de diff: < 200 → 0,101 · 200–799 → 0,053 · 800–2.999 → 0,027 · ≥ 3.000 → 0,007 (antes de 25/09; depois: 0,225 · 0,094 · 0,043 · 0,014). A probabilidade **por bead** sobe com o tamanho, mas **por linha cai muito**: partir um diff de 1.200 linhas em quatro de 300 **aumentaria** o total esperado de FAILs. Isto descarta "quebrar bead grande" como alavanca de aprovação e é consistente com o revisor dar a cada linha de um diff grande menos atenção (ver Frente 6) — inferência, não medição direta.

## 5. Reincidência (item 5 do pedido)

153 beads com ≥ 3 rodadas de FAIL de revisor, 484 transições. O FAIL k+1 tem ≥ 1 **classe** igual ao FAIL k em **65,5%** (acaso, com a mesma composição: 55,2%) e ≥ 1 **subtag** igual em **39,7%** (acaso: 24,1%); ≥ 1 **subtag** igual à de **qualquer** rodada anterior: 60,7% (acaso: 42,9%). Ou seja: reincidência acima do acaso, mas **a maioria dos FAILs seguintes traz um defeito de outra subtag** (só 39,7% repetem alguma subtag do FAIL anterior; 60,3% não), e o B→B — que dominaria se a classe grudasse — é **218 das 484 transições (45,0% [40,7–49,5]; se ter B na rodada k fosse independente de ter B na k−1, seriam 41,7%)**: B repete só um pouco acima do acaso, em boa parte porque B é 53% de tudo. (Nas 357 beads com ≥ 2 rodadas o B→B é 303 de 688 = 44,0%: é outra população, e não a dos percentuais desta seção.) "Consertou o exemplo, não a classe" aparece assim: em 38,9% dos issues latentes da Frente 6 o defeito é **irmão** do já apontado numa rodada anterior, e em 5,0% o **mesmo** defeito reaparece porque o conserto não o tocou (REPEATED). O tag explícito `x.fixed_instance_not_class` só marca 1,6% — o revisor raramente diz isso, o diff mostra mais.

## 6. Frente 6 — a revisão devolve tudo de uma vez? (pedido do Athos, 30/09 09:09)

**Resposta curta: não.** Entre os blocking issues de rodada ≥ 2, **a maioria já estava no código da rodada 1**.

### Método

População: as 122 beads da Era B com ≥ 2 FAILs de revisor cujas rodadas todas têm o diff guardado (35% das 346 beads multi-FAIL do estudo; 317 dos 880 issues de rodada ≥ 2). Para cada issue: (i) montei mecanicamente as janelas de código citado na rodada 1, na anterior e na N a partir dos diffs que o revisor viu, mais o parecer completo da rodada 1 e os issues das rodadas anteriores; (ii) um juiz (Sonnet 5.5, 1 chamada por bead) rotulou **LATENTE / INTRODUZIDO / VEIO-DO-MAIN / REPETIDO / INDETERMINADO**, e para LATENTE precisa **citar uma linha literal** da rodada 1 e a mesma da rodada N — verificada depois no diff guardado; (iii) 2ª passada, só nos indeterminados: o mesmo juiz com o **arquivo inteiro lido do git** no sha de cada rodada (`git show <sha>:<arquivo>`, só leitura); (iv) **auditoria mecânica de todos os rótulos** contra o git, sobre os arquivos citados pelo issue **mais** os alterados na rodada 1 **mais** os alterados na rodada N (até 80 arquivos; nenhum issue bateu no teto): LATENTE só vale se a linha citada existe em algum desses arquivos no sha da rodada 1 **e** ainda existe em algum deles no da rodada N; INTRODUZIDO só vale se a linha "nova" **não** existe em nenhum deles no sha da rodada 1 — uma linha que já existisse num arquivo fora dessa lista não é vista. Quando o git não consegue ler um arquivo o veredito é UNREADABLE, nunca um CONFIRMADO por omissão (0 casos). Não re-rodei revisor.

### Resultado (n = 317 issues, 122 beads, 232 vereditos de rodada ≥ 2)

| rótulo final | issues | % |
|---|---|---|
| **LATENTE** | 167 | **52,7%** [47,2–58,1] |
| INDETERMINADO | 81 | 25,6% |
| INTRODUZIDO pelo conserto | 51 | 16,1% |
| REPETIDO (já apontado antes, não corrigido) | 16 | 5,0% |
| VEIO-DO-MAIN/rebase | 2 | 0,6% |

* **Limites do número:** piso **51,7%** (164 LATENTES verificados no git; 3 não confirmados) e teto **55,8%** (todos os LATENTES + os 10 INTRODUZIDOS que o git **contradisse** — a linha "nova" já existia na rodada 1, o juiz sobre-rotulou INTRODUZIDO em 10 de 56; 1 dos 56 não trazia citação para auditar). Entre os **decididos** (236), LATENTE = **70,8%**. Dos 51 INTRODUZIDOS, 45 têm citação verificada e 6 não.
* **O parecer da rodada 1 sobre esses latentes** (n = 167): não mencionou o trecho **62,3%** · deu o trecho como **verificado/OK 28,1%** (o pior caso — 47 issues) · listou como não-bloqueante 6,6% · o arquivo estava na parte omitida do diff parcial 3,0%.
* **Por rodada:** rodada 2 → 53,7% latente (n = 175) · 3 → 54,4% (57) · 4 → 34,5% (29) · 5 → 52,4% (21) · 6 → 50,0% (14). Não é "cada rodada acha o próximo": o latente aparece desde a rodada 2.
* **Rodadas evitáveis:** **105 das 232 rodadas ≥ 2 (45,3%) só tinham issues latentes** — teriam sido dobradas na rodada 1 se o revisor tivesse achado tudo. 56,5% têm ≥ 1 latente. Custo: 105 sessões de conserto + 31 h de gate + 259 h de relógio entre o FAIL anterior e o desfecho seguinte (relógio, não esforço; mediana 1,4 h). Sobre **todos** os 616 FAILs de revisor da Era B: **17,0%** — o numerador só conta as 122 beads julgadas (e nenhuma rodada com algum issue INDETERMINADO), o denominador é a Era B inteira: é uma **referência**, não um teto estrito, e se a rodada 1 teria mesmo achado esses defeitos é o que a fase sombra da proposta 2 mede.
* **Casos-semente do Mayor, confirmados com citação e git.** *wa-br1w4r*, rodada 2 (`ga-x28109`, sha `7ede71df7`): LATENTE — `titular = (resolvers.titular(phone) or "").strip()` idêntico na rodada 1 (`54d924f5b`), cujo parecer deu os resolvers como corretos ("production resolvers: helper signatures match"). O outro issue da rodada 2 é REPETIDO (o teste e2e dependente do loader já apontado). *wa-0efsc3*: dos 8 issues de rodada ≥ 2, 3 LATENTES — dois na rodada 2 (a busca por grafia crua, `return any(dnc.contains(v) for v in phone_variants(phone))`, **que existia desde a versão 1**, e o teste positivo do PIX que faltava) e um na rodada 7 (`attempt_block(... phone: str …)` recebendo a string crua, irmão do primeiro; o parecer da rodada 1 deu esse trecho como OK) —, 3 INTRODUZIDOS (rodadas 3–5: a razão `parada_pelo_operador` e a negação do opt-out), 1 REPETIDO, 1 INDETERMINADO. Hipótese do Mayor (cru × canônico desde a 1ª versão): **confirmada**.

### Por quê (causas prováveis, em ordem de evidência)

1. **Um revisor, uma passada, uma lente, e a saída não cresce com o diff.** 2.657 de 2.657 tarefas guardadas dizem "reviewer 1 of 1" e lente CORRECTNESS (onde o cabeçalho da run traz o campo, `Reviewers required: 1` — 708 runs). Blocking issues por FAIL: **1,29** (< 200 linhas) → **1,44** (≥ 3.000) enquanto o diff cresce mais de 20×; 73,5% dos pareceres listam **exatamente um** issue. E quando a rodada 1 listou só um, **81,6%** dos issues decididos das rodadas seguintes eram latentes (n = 125), contra 58,6% quando listou ≥ 2 (n = 111). É consistente com "parou no primeiro / achou o que cabia numa passada" (a esparsidade natural dos defeitos daria a mesma contagem; o rótulo LATENTE é que distingue).
2. **Diff grande.** Latente entre os decididos, por tamanho do diff da rodada 1: < 200 → 18,2% (n = 11) · 200–799 → 61,3% (106) · **800–2.999 → 85,0% (113)** · ≥ 3.000 → 66,7% (6).
3. **Diff parcial.** 6,9% das runs (182) entregam ao revisor um `PARTIAL DIFF — showing 12 of 29 files (1993 of 8633 total diff lines). DO NOT treat the omitted files below as reviewed`; em 39 das 2.446 runs com veredito (1,6%) o revisor recebe < 10% das linhas (caso extremo: 12 de 3.108). O único remédio dado é um `git diff` que ele mesmo tem de rodar. Latente com round-1 parcial: **93,2%** [81,8–97,7] (n = 44) contra 65,6% (n = 192) — comparação confundida com o tamanho: o parcial só existe em diffs ≥ 800 linhas, onde o latente já é 85,0% [77,2–90,4] (n = 113, faixa 800–2.999), e os intervalos se sobrepõem. Só 5% dos issues de rodada ≥ 2 citam arquivo omitido na rodada 1 — o parcial explica pouco do total; ele é um marcador de "diff grande demais para uma passada".
4. **O prompt permite parar cedo.** `agents/gate-reviewer/prompt.template.md` + `REVIEW_TASK` em `quality-gate-dispatcher.sh` (l. 15062–15130 em `0d4f4d6f3`): pede "verify each issue is real, then **report everything real you find**, at its true severity" — dever sobre o que foi encontrado, **não sobre a cobertura**. Não pede varredura completa, lista de arquivos/trechos examinados, nem "continue depois do primeiro bloqueante"; a 3ª-estado é dimensão obrigatória mas há só uma lente.
5. **Ruído do revisor (parcial × não-determinístico).** No mesmo sha, no gate real: 17 pares (bead, sha) revisados ≥ 2 vezes, **3 viraram o veredito** (n pequeno; o gate falha-fechado por sha e por isso quase não repete). No E0: arm A reprovou 10 dos 15 casos; o arm B (mesmo prompt, modelo fixado em `claude-sonnet-5`) inverteu 4 dos 10 — **confundido com a troca de modelo**, é um teto. Não separo o ruído do latente na fatia: parte dos LATENTES é uma amostra ruim de uma distribuição (o mesmo revisor, outra passada, acharia). **Isso não enfraquece a proposta 2** — um 2º revisor independente ataca as duas causas.
6. **Orçamento (tempo) — não sustentado.** Reviewer sem veredito por timeout: 0,7% – 1,8% das runs em **todas** as faixas de tamanho (36 runs com tamanho conhecido; mediana 461 vs 467 linhas). O revisor não é cortado por tempo nos diffs grandes; ele termina — só termina cedo.

## 7. Propostas (nada aplicado; cada uma vira bead própria se aprovada)

"Teto" = fração dos vereditos que a mudança evitaria **se funcionasse perfeitamente**, calculada em base estrita (todo issue do veredito coberto); a linha 2 usa, no lugar, a fração de rodadas inteiramente latentes da Frente 6, que é uma referência (§6). "Estimativa" = teto × hipótese de captura; a captura é o que o A/B mede. A doutrina de 12/08 vale: prosa no prompt do construtor **já foi tentada** — o degrau é verificação mecânica, sessão separada e mudança estrutural.

| # | mudança | onde muda | teto | estimativa | move qual métrica | evidência |
|---|---|---|---|---|---|---|
| 1 | **Pré-revisão do construtor com a lente do revisor (E3), agora guiada por estes dados**, + **mapa por-diff gerado por máquina**: todo ponto de leitura nas linhas adicionadas (subprocess, consulta, HTTP, arquivo, chave JSON) e toda afirmação em comentário/log, cada um com "o que o código faz se NÃO SOUBER". Lista de subtags da lente: 3º estado outro (25% dos vereditos), erro engolido→default (21%), vazio lido como OK (17%), decidida≠agida (5%), efeito externo (9,5%) | **(b)** `/gate-done` e fragments — como **sessão separada** + gerador do mapa, não como mais texto; **(c)** o gerador é mecânico | 62,6% (71,5% pós-25/09) | 16–31% (18–36% no regime atual) | **aprovação na 1ª tentativa** +8 a +16 pp (56% → 64–72%) no regime atual | §3.1, §3.2 (37,4% "primeira vez" = guard de 3º estado) |
| 2 | **Primeira revisão completa**: 2º revisor independente (sessão separada, lente "irmãos no mesmo diff") no **1º FAIL** e sempre em diff ≥ 800 linhas; o parecer lista arquivos/trechos examinados; nunca entregar diff parcial sem revisor extra para o resto | **(d)** REVIEW_TASK/dispatcher; **(a)** nada | 17% (105 de 616 FAILs Era B; referência, não teto estrito — §6) | 7–17% (captura de 50–100% por issue; veredito só some se todos os seus issues saírem) | **rodadas por bead** (−0,03 a −0,06 por bead) e horas; aprovação na 1ª tentativa **não muda** | §6; custo ≈ US$ 0,60/revisão (E0) ⇒ ≈ +US$ 15–22/dia |
| 3 | **Mecânica do gate**: FAIL sem revisão de código (timeout, merge falho após ALL PASS, bead já fechada, sha reprisado) **não** conta em `gate:fix-attempt` e reenfileira sozinho; diff parcial ⇒ chunk/2º revisor | engine/dispatcher — **patch em `pending-engine-window/`**, sem build (Mayor agenda) | 11,0% das tentativas reprovadas (6,6% pós-25/09); 3,2% das beads no 1º resultado | 100% do teto | aprovação +2,3 pp; menos needs-human por conflito | §1, §6 (causa 3) |
| 4 | **"Teste tem que falhar na base" para pytest/js** (o ga-rstae hoje só cobre `*.selftest.sh`) | **(c)** guard do gate, mecânico | vereditos com ≥ 1 issue D: 10,1% (12,5% pós-25/09); só-D 6,4% | 3–6% | aprovação na 1ª tentativa | §3.1 |
| 5 | **Nada por enquanto**: template de história/refino, regex-lint, partir bead | — | E = 1,3% dos issues | ≈ 0 | — | §4, §8 |

**O que sobe a aprovação e o que sobe a velocidade não é a mesma coisa.** As propostas 1, 3 e 4 mexem na aprovação na 1ª tentativa; a 2 mexe nas rodadas. Combinadas, no regime atual e com sobreposição descontada (a 4 quase toda cabe na 1): aprovação 56% → ≈ 66–75% e FAILs por bead 0,90 → ≈ 0,55–0,70 (ordem de grandeza de teto × captura; não é promessa). Critérios do revisor **não** são tocados em nenhuma delas.

## 8. O que os dados dizem para NÃO fazer

* **Regex-lint como porteiro.** Medido em 227 pares com diff completo nos dois lados (linhas adicionadas do diff reprovado × aprovado): `|| true`/`2>/dev/null` dispara em 20% × 20% dos diffs; `except Exception`/suppress 39% × 41%; `.get(k, 0/""/None)`/`or ""` 31% × 36%; `all(`/`any(` 30% × 33%; palavra absoluta em comentário **93% × 96%** (10–14 linhas por diff). O que importa é a segunda coluna: **a fração de diffs já APROVADOS em que o padrão dispara** (20% a 96%) — ele acusaria código aceito nessa proporção, e por isso não serve de porteiro. (Comparar as duas colunas não mede poder de discriminação: o diff reprovado e o aprovado são duas versões da mesma mudança e dividem quase todas as linhas.) Serve, no máximo, como o **mapa** da proposta 1 (lista para o construtor justificar), nunca como bloqueio.
* **Partir bead grande para "subir aprovação"**: ver §4 (risco por linha cai com o tamanho).
* **Mais texto no prompt do construtor**: 12/08 mediu que as 4 frases já chegam ao prompt e o volume de issues nessas famílias continuou; a fatia C dobrou depois que o revisor passou a bloquear comentário enganoso.
* **Texto de história**: "menciona caso-limite" 72,1% × 72,2%; a classe "história ambígua sem critério" é 1,3% dos issues (E) — o teto de qualquer mudança de template é ≈ 1–2% dos FAILs. Se o Athos quiser mexer, o único traço com efeito robusto medido é o **tipo** (feature).

## 9. Desenho de experimento (padrão E3: braço = hash do bead-id; sem tocar o critério do revisor)

Base: depois de 25/09, 59,7 beads/dia (291 em 4,9 dias) e 56,0% de aprovação na 1ª tentativa. **Não iniciar antes de 01/10 ~21 h (fim do E2 — crews em `effort high`)**; estratificar por faixa de tamanho, rig e tipo (feature × resto); registrar builder e o sha do prompt do revisor de cada run.

| proposta | braços | métrica primária | secundárias | n e prazo (2 lados, α 0,05, poder 0,80) |
|---|---|---|---|---|
| 1 | A: gate atual · B: pré-revisão guiada + mapa por-diff | aprovação na 1ª tentativa por bead | issues/FAIL, classe B por FAIL, custo por bead | +10 pp: 370/braço ⇒ **12 dias**; +15 pp: 158/braço ⇒ 5 dias; +8 pp: 585/braço ⇒ 20 dias |
| 2 | **Fase 1 (7 dias): sombra** — o 2º revisor roda em todo 1º FAIL, não altera veredito | recall do 2º revisor sobre os issues que depois aparecem como LATENTES da rodada ≥ 2 (verdade-terreno = os rótulos desta Frente 6, refeitos com o mesmo método) | falsos-positivos: issues do 2º revisor que a rodada seguinte não confirma | ≈ 170 primeiros FAILs/semana; **critério de passagem proposto** (a decidir): recall ≥ 40% e falso-positivo ≤ 15% |
| 2 | **Fase 2: braços** A: 1 revisor · B: 2º revisor no 1º FAIL e ≥ 800 linhas | **binária:** a bead com 1º FAIL de revisor precisa de uma 2ª rodada de FAIL (36,0% hoje). A contagem de rodadas por bead **não serve**: desvio-padrão 1,3 para média 0,69 pede > 1.100 beads por braço para −0,15 | fração de rodadas ≥ 2 inteiramente latentes (45% hoje), custo por bead | −15 pp (36% → 21%): 139 beads com 1º FAIL por braço ⇒ **11 dias**; −10 pp: 332/braço ⇒ 27 dias (≈ 25 primeiros FAILs/dia) |
| 3 | antes/depois (é infraestrutura, não dá A/B) | FAIL de processo por dia e % das tentativas (6,6% pós-25/09; meta ≤ 2%) | `gate:fix-attempt` esgotado por FAIL de processo | 2 semanas |
| 4 | **sombra** 7 dias: roda o check em pytest/js de toda submissão sem bloquear | fração que falha na base (teto de captura) | falso-positivo (submissões boas que falham na base) | 7 dias |

## 10. Limites

* **Cobertura.** Diffs guardados só na Era B (44% das beads com tamanho/construtor); a Frente 6 cobre 35% das beads multi-FAIL (as 122 da Era B com todas as rodadas guardadas) — sem generalizar para a Era A (diff ausente, sha às vezes solto). A Era B mistura os dois regimes do prompt; separei por corte, mas o efeito de `effort`/modelo (28/09) não se separa do prompt (já dito em ga-ufskhy).
* **Rótulos de LLM.** Classes: 88,7% de concordância com um 2º modelo (κ 0,82) — as **subtags** são menos firmes (Jaccard 0,57); tratar percentuais de subtag como ±5 pp. Frente 6: 25,6% ficam INDETERMINADOS (a citação não pôde ser verificada); INTRODUZIDO foi sobre-rotulado em 10/56 (o git contradisse); **LATENTE** foi o rótulo mais robusto (164/167 confirmados; 3 não). A auditoria de git cobre os arquivos citados + os alterados nas rodadas 1 e N: uma linha "nova" que já existisse num arquivo fora dessa lista não seria vista, então INTRODUZIDO pode ainda estar sobre-rotulado. LATENTE = "o código do defeito já estava lá", não prova que o revisor da rodada 1 falhou por preguiça: pode ser ruído de amostra (ver causa 5).
* **Observacional.** Tamanho, tipo e regime estão entrelaçados; a regressão controla, não prova causa. Estimativas de captura das propostas são hipóteses.
* **Anomalias achadas e corrigidas no caminho** (nos scripts e nos números acima): (1) a contagem por substring dobra os vereditos (§1); (2) **13% dos registros PASS eram a 2ª variante do comentário (`… but NOT closing …`) do mesmo merge** — inflava a taxa de PASS por tentativa em ~13%; deduplicado por (bead, sha de merge), o que reconciliou com a medição do Mayor no log (76,2% na janela 18/09→25/09 / 52,1% depois de 25/09, contra 77% / 61→57→42%); a taxa por bead (1ª tentativa) não muda; (3) a linha de resumo do diff vem cortada nos diffs grandes (tamanho passou a vir do cabeçalho `FULL/PARTIAL DIFF`); (4) o modelo encurtava ids longos ao devolvê-los (≈ 3% dos lotes) — ids locais curtos; (5) uma condição de corrida (conexão sqlite compartilhada entre threads) corrompeu silenciosamente o 1º piloto de uma bead-semente, achada pela verificação contra o Mayor e refeita; (6) cinco comentários que começam com `GATE-FEEDBACK` mas não são vereditos (sem o cabeçalho `(gate_run=`: 4 respostas de construtor, 1 parecer postado à mão) entravam como vereditos — fora (1.891 → 1.886; FAIL sem revisão de código 212 → 207); (7) o delta dos pares com diff PARCIAL (37 de 264) lia arquivos omitidos como acrescentados/removidos pela correção — a análise dos pares passou a usar só os 227 com diff completo (antes: guard de 3º estado 47,0%, "primeira vez" 41,3%); (8) campo booleano que o modelo deixou de preencher era gravado como 0 ("não"), o mesmo valor de um "não" explícito: agora é NULL, e as tabelas foram corrigidas a partir da saída bruta guardada, sem nova chamada (`e4_backfill_tristate.py`: 3 de 317 issues da Frente 6 — nenhum deles LATENTE —, 0 nos pares e na 2ª passada com git); (9) um percentual trazia numerador e denominador de populações diferentes (B→B: 303 de 484, §5) — agora cada percentual sai com a sua população.
* **Atlas.** `whatsapp_automation/docs/data_dictionary.md` não tem entrada para o esquema Dolt dos beads (`issues`/`comments`/`labels` por banco) nem para a estrutura `gate-run` → `verdict` (tarefa completa embutida no comentário): lacuna de atlas registrada aqui; não abri bead (pedido: somente esta).
