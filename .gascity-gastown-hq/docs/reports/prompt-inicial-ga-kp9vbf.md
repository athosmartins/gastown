# O prompt inicial está inchado? Medição por papel, onde está o dinheiro e como cortar sem perder aderência

Bead ga-kp9vbf (P0). Dados: `gc prime` renderizado em 30/09, transcritos retidos (23/09–01/10), 16 sondas `claude -p`, log do Pilot. Somente leitura; **nada foi aplicado em produção**. Scripts e como reproduzir: `prompt-inicial-ga-kp9vbf/README.md`. **WTE** = token-equivalente ponderado (entrada 1×, escrita de cache de 1 h 2×, leitura de cache 0,1×, saída 5×; multiplicadores são os preços públicos, não medidos aqui).

## O estado do mundo

1. **É maior do que a bead dizia.** O `gc prime` tem **26 a 53 mil tokens contados** (dog 44.132; ps-worker 52.877), não 15–30 mil: chars/4 erra por ~1,8× neste texto, que tem 2,2 caracteres por token. O 1º turno de uma sessão de pool lê 53–110 mil tokens; o dos crews 107–162 mil.
2. **Mas o prompt é ~14% do gasto do pool, não a maior parte.** Dos 541 M WTE/dia dos 6 papéis de pool, a doutrina inteira custa 73 M (13,6%). 60% do gasto é cache lido (a sessão relendo o próprio contexto), 22% é escrita de cache, 18% é saída. Cortar 100% da doutrina daria 13,6%; o desenho abaixo captura **≈ 8%** (43 M WTE/dia).
3. **A maior fatia disso não é cortar texto.** A doutrina vai como mensagem do usuário e é **reescrita no cache a cada sessão, ao preço de 2×** (56,7 mil tokens escritos por sessão de dog; só 17 mil são lidos). Numa sonda, a mesma doutrina no system prompt voltou **99% do cache** (46.279 de 46.758 tokens lidos). Sem mudar uma palavra: ≈ 3,6% do pool.
4. **O maior desperdício isolado é um loop, não um prompt.** 93% das sessões ps-worker de 30/09 não tinham trabalho: o Pilot spawna um ps-worker a cada ~23 min para a bead `lx-b5q`, que vive em outro store e que o ps-worker não enxerga — **251 spawns desde 27/09**. 1,5% do pool. Bead própria: **ga-653ilw**.
5. **Sobre qualidade, não há dado em nenhuma direção.** O único experimento natural (o corte de 26/09) é confundido pelo prompt v2 do revisor de 25/09. O que há de indireto aponta para mecanismo, não texto: a regra do 3º estado já está em todo prompt de construtor e é 53% das reprovações; `rm -rf` é tentado em 31–39% das sessões apesar da regra escrita.
6. **Nada aqui precisa de decisão do Athos** (é desenho técnico). O que precisa do Mayor: ga-653ilw, e agendar as fases abaixo com o E3/E2 em andamento.

## 1. Inventário por papel (pergunta 1)

| papel | prime (tokens) | prime (chars) | 1º turno (mediana 72h) | sessões/dia | turnos (med.) | WTE/dia | doutrina = % do custo do papel |
|---|---|---|---|---|---|---|---|
| dog | 44.132 | 95.703 | 73.897 | 79 | 39 | 160,8 M | 16% |
| wa-worker | 39.477 | 86.533 | 110.415 | 32 | 119 | 207,5 M | 9% |
| ps-worker | 52.877 | 117.502 | 83.502 | 45 | 3 | 11,6 M | **51%** |
| gate-reviewer | 26.988 | 60.472 | 53.344 | 136 | 38 | 156,5 M | 14% |
| refino-gate-reviewer | 25.757 | 56.882 | 53.558 | 23 | 5 | 2,7 M | **52%** |
| auto-refiner | 36.567 | 79.180 | 90.300 | 4 | 6 | 1,7 M | 27% |
| mayor | 41.233 | 90.591 | 107.125 (n=2) | — | 424 (n=2) | — | — |
| peter-wa | 32.988 | 71.174 | 162.151 (n=2) | — | — | — | — |

Tokens por contagem real (uso da API: sonda com e sem o texto, mesmo harness; 2,16–2,24 chars/token em todos). O 1º turno do dog caiu de 147,5 mil (25/09) para 83,1 mil com o ga-aijm2v.6 (preâmbulo por papel, verificado no ga-aijm2v.10) e hoje está em 73,9 mil. Dos 73,9 mil: 44,1 mil são a doutrina, 17,2 mil cache lido (system prompt + schemas) e ≈ 12,5 mil outros escritos por sessão (hooks, listas de skills e de agentes, git status — **não decomposto aqui**; é uma bead à parte, mesma lógica de cache). Os outros 5 crews (batista, mila, oracle, thies, digo) estão `suspended`: prime vazio.

**Por título (chars; "Operational Awareness" = fragmento nativo ≈ 6 mil + town-deltas):**

| papel | Operational Awareness | resto relevante |
|---|---|---|
| dog | 60,1 mil (62,8%) | Startup 11,0 · Quick-Reference 9,9 · "Piston" 9,2 · demais ~5 |
| gate-reviewer | 39,5 mil (65%) | "Piston" 9,2 · Startup 4,5 · **3º ESTADO 2,4** · Path 1,6 |
| refino-gate-reviewer | 39,5 mil (69%) | "Piston" 9,2 · Startup 4,8 |
| wa-worker | 62,2 mil (72%) | Startup Protocol 20,1 mil (23%) |
| ps-worker | 62,2 mil (53%) | **Startup Protocol 50,2 mil (43%)** |
| auto-refiner | 66,5 mil (84%) | Startup/How to work/Polling ~9,8 |
| mayor | 66,6 mil (73%) | "Main Drive Shaft" 10,2 |
| peter-wa | 66,5 mil (93%) | Regras gerais 1,8 |

**Conferência das alegações da bead contra o artefato.** O prompt do gate-reviewer ainda carrega "Gas Town Architecture" (1×), o roteiro de diagnóstico de hang do Dolt (2 menções, ver `SHOW FULL PROCESSLIST`) e "Mail lifecycle" (1×) — **confirmado**. O bloco de WITNESS **não está mais lá** (2 menções soltas): saiu com o ga-aijm2v.6 (-27 mil chars no revisor). A baseline da bead (97.448 chars no dog) já era pós-corte.

**Repetição dentro do prime** (trechos de 120 chars que reaparecem): dog **21,4 mil chars = 22%, ≈ 9,8 mil tokens** (cinco scripts `work_query` quase idênticos em Piston, Startup 1a/1b/1c e Quick-Reference); ps-worker 13,5% (≈ 7,2 mil); auto-refiner 7,5%; revisores 7–8%; wa-worker 5,6%; peter-wa 0,2%.

**Seções do town-deltas** (23 seções, 66,3 mil chars ≈ 30,6 mil tokens; tokens a 0,461/char, a razão medida do dog) e o uso medido dos procedimentos que cada uma documenta (% das sessões com ≥ 1 comando; **amostra de 1 dia**: dog 83, wa-worker 39, ps-worker 44, gate-reviewer 138):

| seção | tokens | uso medido (dog / wa / ps / revisor) | destino proposto | gatilho que garante o carregamento |
|---|---|---|---|---|
| engine-window-patch | 2.856 | 4% / 10% / 0% / 1% (`.patch`, `go build`) | doc + 2 linhas | label `framework:engine`/`needs:engine-window` no claim (ga-aijm2v.13); `engine-window-backlog-guard` já acusa patch no lugar errado |
| models | 2.589 | n/a (guia de quem escreve prompt) | 4 linhas núcleo + skill | skill (probabilística; custo baixo se faltar) |
| witness-startup | 2.383 | só vai a quem **não tem** `TD_ROLE`: mayor, crews, auto-refiner, context-check — nenhum roda witness (o witness por rig está sem uso, `city.toml`) | remover desses papéis; manter no witness | nenhum necessário |
| rm-rf-safe-clean | 2.193 | `rm -rf` direto: 39% / 31% / 5% / 36% **apesar do texto**; `safe-clean` 17% / 21% / 0% / 3% | 4 linhas + deny | o deny de `rm -rf` (já em todo overlay de pool) segura; medir tentativas no A/B |
| autonomy | 2.182 | — | **fica** (3º estado, verificação por artefato) | núcleo |
| next-action-mayor-waiting | 1.900 | 0% em todos (escrita de label `next-action:`) | 3 linhas do procedimento | núcleo curto |
| rule-3 (`athos.acao`) | 1.752 | 0% | 1 linha no pool; completa no Mayor/crews | `athos-acao-guard.py` (detecção) |
| mockup-s3 | 1.706 | 1% / **38%\*** / 0% / 3% | **fica no wa-worker**; sai do ps-worker/refiner | skill `wa-worker-session-protocol` disparou em 4 de 15 sessões que rodaram S3 (27%) — não é gatilho |
| research-only-channels | 1.653 | `Agent`: 0% / 21% / 0% / 0% | hook no uso de `Agent` (a confirmar o tipo de saída do hook) | hook por comando |
| rule-4 | 1.433 | — | 3 linhas no pool (autorização citável) | núcleo curto |
| rule-1 + rule-2 | 1.555 | `AskUserQuestion` 0% (pool headless não pergunta ao Athos) | 1 linha no pool | núcleo curto |
| nudge-permission-dialog | 840 | `tmux send-keys` 0% | sai do dog | `agent-stuck-escalation.sh` já detecta o prompt e manda a instrução |
| claudemd-carryover / dolt-cleanup-hazards / graph-v2 | 1.125 / 756 / 778 | gmail-totp 0%, `bd reclaim` 0%, `gc dolt cleanup` com espaço 0%; `mol current` 6% (dog) | **ficam** (guardam incidentes) | núcleo |
| worktree, bd-list-limit, home-scan, cloudstorage, secrets | 1.000 / 972 / 896 / 445 / 464 | worktree 80% (dog) e 95% (wa); `bd list` sem escopo ~1% | **ficam** | núcleo |

\* o detector de S3 casa a palavra "mockup" em qualquer comando; superestima.

## 2. Quanto custa (pergunta 2)

| papel | cache lido | escrita de cache | saída | escrita do 1º turno = % da escrita total |
|---|---|---|---|---|
| dog | 60% | 21% | 19% | 27% |
| wa-worker | 72% | 14% | 14% | 20% |
| ps-worker | 24% | 61% | 15% | **84%** |
| gate-reviewer | 48% | 30% | 22% | 22% |
| refino-gate-reviewer | 20% | 71% | 9% | **88%** |
| auto-refiner | 32% | 53% | 16% | 52% |
| **pool** | **60%** | **22%** | **18%** | — |

- **Sessão longa** (dog 39 turnos, wa-worker 119, gate-reviewer 38): o custo é o contexto crescendo e relido; a doutrina vale 9–16%. Cortar 40% dela rende 4–6% do papel.
- **Sessão curta** (ps-worker 3 turnos, refino 5): o 1º turno é 84–88% da escrita e a doutrina 51–52% do custo — **aqui o texto e o cache pesam**.
- O que o cache barateia e o que não: a releitura em cada turno é barata (0,1×); a **1ª escrita por sessão não** — as 2 transcrições de dog inspecionadas mostram 56.716 e 56.720 tokens escritos e 17.154 lidos (praticamente iguais entre sessões); toda escrita observada, nelas e nas 16 sondas, é do nível de 1 h. O que é lido é só o system prompt + schemas.

## 3. O achado de cache (alavanca 1)

Mesmo harness (`claude -p`, sonnet, sem tools, só settings de projeto), `D` = o prime real do dog (44.132 tokens):

| sonda | o que varia | escrita | leitura |
|---|---|---|---|
| P0 | baseline do harness | 2.069 | 531 |
| P1, P2 | beacon + `D` na mensagem (**como hoje**), beacon diferente | 44.600 / 44.600 | 2.147 / 2.147 |
| P3, P4 | `D` primeiro, beacon depois, beacon diferente | 44.600 / 44.600 | 2.147 / 2.147 |
| P5 | `D` no system prompt (1ª vez) | 46.216 | 540 |
| **P6** | **mesma `D` no system prompt, só o beacon do usuário muda** | **477** | **46.279** |
| P7 | system = `D` + 1 linha de instância | 46.234 | 540 |

- A hipótese que eu tinha ("é só pôr o beacon depois") **não se confirmou**: P4 reescreveu tudo. O cache só reaproveita prefixo em fronteira de bloco; a mensagem do usuário é um bloco único (101.406 chars, beacon no offset 0). **A doutrina precisa estar no system prompt** (ou num bloco próprio marcado).
- **P7**: um byte diferente no bloco invalida tudo. Os primes de hoje trazem 2–3 linhas de identidade da instância (`Working directory`, `Mail identity`, alias) — têm de sair do bloco cacheável (para o beacon).
- Acerto estimado pelos intervalos entre inícios de sessão do mesmo papel, entrada viva por 1 h: dog **92%**, ps-worker 89%, gate-reviewer **99%**, wa-worker 77%, refino 58%, auto-refiner 39% (sessões/dia: 79, 45, 136, 32, 23, 4). Limite superior: supõe prime idêntico entre sessões.
- Economia: escrita 2× vira leitura 0,1×: **19,5 M WTE/dia (3,6% do pool)** só com isso; dog 6,1 M, gate-reviewer 6,9 M, ps-worker 4,0 M.
- **Não verificado:** a config do provider tem `prompt_mode = "flag"` + `prompt_flag` (está no binário e no schema), o que sugere ser configuração e não patch de engine — mas não testei com o claude, nem como o `gc` inicia a sessão sem mensagem de usuário. Mover a doutrina para o system prompt também muda a autoridade da instrução: pode melhorar ou piorar a aderência, por isso entra no A/B.

## 4. Qualidade (pergunta 3)

- **A regra do 3º estado chega e não é seguida.** Está em todo prompt de construtor (autonomy §3, "núcleo") e num bloco próprio no revisor. E4 (`gate-e4-historico.md`): 53,0% dos 2.224 blocking issues são caso-limite/3º estado; em 37,4% dos 227 pares reprovado→aprovado o guard "que deveria ter vindo de primeira" era de 3º estado; a medição de 12/08 já dizia que as 4 frases chegam ao prompt e o volume não caiu. A conclusão de E4 (verificação mecânica antes do gate, E3) vale aqui: **mais ou menos texto não é a alavanca**.
- **Aderência por detector, nesta amostra** (sessões com ≥ 1 ocorrência; letra da regra, não dano): `rm -rf` direto 38,6% dog / 30,8% wa-worker / 36,2% gate-reviewer / 4,5% ps-worker (o deny segura; custo é um turno); `git add -A`/`commit -a` 9,6% / 12,8% / 7,2% / 0%; `bd list --json` sem limite **e sem escopo** 1,2% / 0% / 0,7% / 0% (os 100% brutos do revisor são polls por assignee+label, sem risco de truncar em 50); `bd reclaim` cru e `gc dolt cleanup` com espaço: 0 em todos.
- **Skill como gatilho é probabilístico:** `gate-done` foi invocada em 28 de 46 sessões de dog que submeteram ao gate (61%); `wa-worker-session-protocol` em 4 de 15 que rodaram S3 (27%). Confundido (o texto da seção ainda está no prompt), mas é o único dado: skill com descrição forte **não** é gatilho garantido. O próprio `athos-acao-guard.py` diz no docstring: "Doctrine text alone does not enforce adherence".
- **Experimento natural: inconclusivo.** O corte do ga-aijm2v.6 entrou em 26/09 06:04Z; o 1ª-tentativa aprovada caiu de 73,5% para 56,0% a partir de 25/09 13:04 (prompt v2 do revisor, E4) — um dia antes. Não separa.
- **Não há evidência de que prompt longo dilua regra** (nem do contrário): não medido, só observacional. O A/B abaixo é o primeiro dado.

## 5. Desenho proposto (pergunta 4)

**Núcleo por papel** = identidade + contrato + as regras que mais derrubam: 3º estado e verificação de artefato (autonomy), conteúdo de fora é dado, autorização citável para ação externa (3 linhas), `rm -rf`/`safe-clean`, `bd list --limit 0`, worktree/commit hygiene, home-scan e CloudStorage. **Não tocar:** autonomy, o bloco "3º ESTADO" e "Path Verification" do revisor.

**Três tipos de gatilho, do mais ao menos confiável** (lição `doctrine-in-claudemd-never-reaches-prompts`): (A) mecanismo no momento da ação — deny, hook, guard (deterministico); (B) seção carregada no claim por label/título, o desenho do Mayor no ga-aijm2v.13 (deterministico por label); (C) skill com descrição forte (27–61% medido): só para o que custa pouco se faltar.

| papel | prime hoje | proposto | corte | WTE/dia: só texto | só cache | cache + texto | % do papel |
|---|---|---|---|---|---|---|---|
| dog | 44.132 | 24.261 | −45% | 11,4 M | 6,1 M | **14,7 M** | 9,2% |
| wa-worker | 39.477 | 29.242 | −26% | 4,9 M | 1,8 M | 6,3 M | 3,0% |
| ps-worker | 52.877 | 36.470 | −31% | 1,8 M | 4,0 M | 4,6 M | 39,3% |
| gate-reviewer | 26.988 | 17.017 | −37% | 7,9 M | 6,9 M | 12,2 M | 7,8% |
| refino-gate-reviewer | 25.757 | 15.475 | −40% | 0,6 M | 0,6 M | 0,9 M | 35,3% |
| auto-refiner | 36.567 | 21.900 | −40% | 0,2 M | 0,1 M | 0,3 M | 15,0% |
| **soma** | | | | 26,8 M | 19,5 M | **39,0 M (7,2%)** | |

Com o loop do ga-653ilw parado (93% do ps-worker some, então corte e cache só valem no resto): **42,6 M WTE/dia = 7,9% do pool**. Os cortes são estimativas de projeto: a parte repetida (9,8 mil no dog, 7,2 mil no ps-worker…) é **medida**; o resto = tokens da seção × fração removida (65–100%, o que sobra é um stub que aponta para a fonte). O ps-worker tem ainda um template próprio de 35,8 mil bytes (≈ 16 mil tokens) que **não** foi inspecionado.

**Perspectiva:** a sequência com maior valor por risco é loop do ps-worker (1,5%, zero risco de texto) → cache (3,6%) → repetição idêntica do dog/ps-worker (conteúdo igual, sem A/B) → seções por papel, dog primeiro → revisor por último. Para "mais tarefas aprovadas por token", o prompt inteiro (13,6%) vale menos que a taxa de aprovação na 1ª tentativa: cada FAIL custa uma sessão de revisor (≈ 1,15 M WTE medidos) mais uma de conserto; E4 projeta 0,90 → 0,55–0,70 FAIL por bead — só o revisor evitado são ≈ 14–24 M WTE/dia a 59,7 beads/dia, a mesma ordem de **todas** as alavancas de prompt somadas (fora o custo do conserto, não medido).

## 6. Experimento (pergunta 5)

Padrão E3 (braço = paridade de SHA-256 do bead-id, **com sal próprio** `ga-kp9vbf:` para ser independente do E3; estratificar por faixa de tamanho, rig e tipo; registrar o sha do prompt de cada run). Economia de tokens é **determinística** (o prompt é conhecido): o A/B não mede economia, mede **segurança**.

| fase | o que muda | braços | métrica | n e prazo (α 0,05 unilateral, poder 0,80) |
|---|---|---|---|---|
| F0 | parar o loop do ps-worker (ga-653ilw) | antes/depois | % de sessões ps-worker sem claim (93% hoje) | imediato |
| F1 | **cache:** doutrina no system prompt, instância fora do bloco | 1 papel (dog), alterna por hash da sessão | 1º turno com ≥ 90% da doutrina lida do cache em ≥ 70% das sessões (previsto 89–92%); detectores iguais | 79 sessões/dia: 3–7 dias |
| F2 | repetição idêntica do prime nativo (dog −9,8 mil, ps −7,2 mil) | sem A/B (conteúdo igual) | tokens do 1º turno; `denied-attempts` | 2 dias |
| F3 | seções por papel, **dog primeiro** (via 2 definições de agente roteadas pelo Pilot, ou ga-aijm2v.13) | A: atual · B: enxuto | **econômica:** WTE por bead aprovada. **Segurança:** detectores (`rm -rf`, `git add -A`, `bd list` sem escopo, `denied-attempts`, turnos/bead) | +10 pp em `rm -rf` (38,6%): 294 sessões/braço ≈ **7,4 dias** no dog; `git add -A` (9,6%): 108 ≈ 2,7 dias; wa-worker 139 ≈ 8,7 dias |
| guarda | 1ª tentativa aprovada (56,0%) | idem | parada sequencial: B < A − 10 pp com p < 0,05, olhada semanal. Não-inferioridade formal é cara: margem −10 pp = 305 beads/braço (10 dias), −8 pp = 477 (16 dias), −5 pp = 1.219 (41 dias) a 59,7 beads/dia | usar como freio, não como desfecho |
| F4 | revisores: só o bloco nativo alheio (Dolt/mail/arquitetura ≈ 6,5 mil chars) | com a guarda | gate-rate (`pool-preamble-measure.py gate-rate`) | — |

- **Não rodar um shadow pareado do revisor para cortar mais:** 342 pares (McNemar, ψ = 0,20, δ = 0,06) custam 394 M WTE (0,73 dia do pool inteiro) por uma economia de ≈ 8 M/dia: retorno em ~50 dias, e o recall do revisor é o valor do gate.
- **Colisões:** E2 (crews em `effort high`) termina 01/10 ~21 h e o E3 (pré-revisão, ga-gnr3tw) roda em metade das beads: F3 só depois do E2, com **controle concorrente** (a baseline de 56% vai mudar com o E3); logar os dois braços em cada bead. A entrega por seção no claim (ga-aijm2v.13) segue travada na sombra 2a; este estudo lista as seções e o uso medido que ela precisa.
- Ferramentas já existentes: `pool-preamble-measure.py first-turn | denied-attempts | gate-rate`. Cada mudança vira bead própria depois do F1/F3 — **não abri nenhuma além da ga-653ilw**.

## 7. Limites

- **Janela curta.** Só há transcritos de 23–26/09 (revisores) e 30/09–01/10 (resto); dog, wa-worker e ps-worker são ~1 dia (83/39/44 sessões). Um dia **não prova uso zero** de procedimento raro (engine, rule-4): a coluna "uso medido" é gatilho para investigar, não licença para cortar. O estudo de 8 dias do ga-aijm2v.6 cobre só uso de tool.
- **Multiplicadores de preço** (2× / 0,1× / 5×) são os públicos, não medidos; sob cota de assinatura o peso relativo pode ser outro. Os fatos de tokens (escrita 1 h, leitura) são medidos.
- **Sondas sintéticas:** a prova de cache foi `claude -p` sem tools, não uma sessão de pool; o acerto de 77–99% é limite superior por intervalos de início (sem fim de sessão) e supõe prime idêntico entre sessões.
- **Seções:** tokens = chars × razão do papel (medida no papel, não por seção); as frações cortadas são hipótese de projeto.
- **Detectores validados por amostra e dois estavam errados na 1ª versão:** `git add .` casava caminhos que começam com ponto (falsos 36,6% → 9,6% depois de apertar) e `next-action:` casava o filtro de startup (100% → 0%). São violação da **letra**; o `bd list` sem limite do revisor é benigno. n do ps-worker = 44.
- **Observacional.** Tamanho, modelo, effort e regime do gate estão entrelaçados; o corte de 26/09 não se separa do prompt v2 do revisor.
- **Render com `GC_ALIAS` do dog-2:** vaza em 2–3 linhas dos primes de revisor (não muda tamanho).
- **Custo do estudo:** ≈ 650 mil tokens em 16 sondas (≈ 1,3 M WTE, 0,24% de um dia do pool); 0 mensagens e 0 nudges; 1 bead criada (ga-653ilw).
