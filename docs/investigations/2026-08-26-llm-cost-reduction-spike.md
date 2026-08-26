# SPIKE: como baixar o custo de IA da operação sem perder performance

**Bead:** ga-w6vbc · **Data:** 2026-08-26 · **Executor:** dog-gacmc0q (gastown.dog-1) · **Gasto:** US$0,00 (teto US$10)

Reenquadramento original (Mayor, 08/08): a ideia de trocar o motor por um modelo aberto
cobrado por token já estava descartada por medição (~57x mais caro). Este documento
responde as 3 perguntas que sobraram, nesta ordem: AC1 tarifa-plana, AC2 self-host, AC3
de onde vem o consumo. AC4 (teste ponta-a-ponta) só roda se AC1 ou AC2 derem positivo.

---

## TL;DR

| Pergunta | Resposta | Confiança |
|---|---|---|
| AC1: existe assinatura tarifa-plana viável? | **Existe o PRODUTO (GLM/Qwen/Kimi/MiniMax), mas nenhum plano de conta única aguenta nossa escala** — o maior teto publicado é dimensionado para 1-2 devs, não uma frota de dezenas de sessões 24/7 | Alta |
| AC2: self-host compensa? | **Não — e estruturalmente NÃO PODE compensar** enquanto a assinatura flat continuar disponível: self-host tem piso de hardware (~US$1.000+/mês, 24/7) que a assinatura já bate por baixo no nosso volume | Alta |
| AC3: dá pra cortar o cache-read? | **Sim, e é a alavanca real** — mas o corte de maior volume não é "encolher o prompt", é encurtar sessões longas sem compactação | Alta (medido, não suposto) |
| **Recomendação nº 1 (fazer primeiro)** | Verificar se o limiar de compactação é ajustável para papéis de vida longa (mayor/oracle/crews) — é o driver de ~72% do volume medido, risco zero, sem gastar nada | — |

---

## 0. Correção de metodologia (achado não-planejado, mas necessário)

A medição original do Mayor (08/08: "21,8B tokens em 4 dias, 97% cache-read") foi eu
tentar REPRODUZIR, não aceitar — e a reprodução expôs um bug de contagem real.

**O bug:** cada turno do Claude Code (uma chamada de API) é gravado no transcript
JSONL como **múltiplas linhas** — uma por bloco de conteúdo (`thinking`, `text`,
`tool_use`, `tool_use`...) — e CADA linha carrega uma CÓPIA do mesmo `usage` daquele
turno. Somar todas as linhas com campo `usage` (o jeito óbvio de medir) conta o mesmo
turno várias vezes. Verificado num arquivo de exemplo: 4 linhas idênticas
(`message.id` igual, `cache_read_input_tokens` igual) para 1 único turno. Na medição
completa desta rodada: 80.336 linhas com `usage` continham apenas **36.419 mensagens
únicas** (por `message.id`) — fator de inflação médio **2,21x**.

Isso não invalida o achado principal do Mayor (97% cache-read continua verdade — o
`%` não muda com a duplicação, já que numerador e denominador inflam igual), mas muda
a MAGNITUDE absoluta, que importa pra qualquer conta de US$/mês.

**Metodologia corrigida:** dedup global por `message.id` (script em
`usage_agg.py`, disponível sob pedido). Script + números brutos ficam anexados no
comentário do bead, não neste doc, pra não poluir o POV com material de apoio.

## 1. Baseline medido (corrigido)

Janela: 2026-08-22 a 2026-08-26 (5 dias — é o retention real dos transcripts locais
nesta máquina agora; não dá pra estender sem uma fonte externa de histórico).
976 arquivos, 378.016 linhas brutas, 36.419 mensagens únicas.

| Dia | Dia da semana | cache_read | TOTAL (in+cache_new+cache_read+out) | % cache_read |
|---|---|---:|---:|---:|
| 08-22 | sáb | 975.528.868 | 993.980.415 | 98,1% |
| 08-23 | dom | 1.463.849.066 | 1.490.080.715 | 98,2% |
| 08-24 | seg | 1.661.872.373 | 1.694.442.907 | 98,1% |
| 08-25 | ter | 4.664.014.067 | 4.758.184.705 | 98,0% |
| 08-26 | qua (parcial, até 17:04Z) | 4.433.792.095 | 4.578.346.971 | 96,8% |

**GRAND TOTAL (5 dias, dedup):** cache_read = 13.199.056.469 (**97,66%** do total
de 13.515.035.713 tokens). Média simples/dia = **~2,64B cache_read** (~2,70B total).

**Padrão fim-de-semana vs dia útil, claro nos dados:** sáb/dom ficam em ~1,0-1,5B/dia;
seg/ter/qua ficam em ~1,7-4,8B/dia. Usando só os 2 dias úteis completos (seg+ter):
**média ~3,16B cache_read/dia (~3,23B total/dia)** — mais perto (mas ainda abaixo)
do "~4,3B/dia normal" original. Não dá pra saber, com 5 dias de amostra, se a
diferença residual é variância real ou mistura de efeitos; uso **3-5B tokens/dia**
como faixa de trabalho pras contas de custo abaixo, e digo qual ponta da faixa cada
conclusão usa.

**Por papel** (5 dias, cache_read):

| Papel | cache_read | msgs | cache_read/msg |
|---|---:|---:|---:|
| mila (crew persistente) | 2.292.877.800 | 4.258 | 538.631 |
| batista (crew persistente) | 1.669.718.033 | 3.203 | 521.299 |
| digo (crew persistente) | 1.330.124.649 | 2.504 | 531.208 |
| thies (crew persistente) | 705.204.808 | 1.372 | 513.993 |
| peter (crew persistente) | 486.801.492 | 1.074 | 453.257 |
| oracle (coordenação, vida longa) | 1.145.829.931 | 2.386 | 480.264 |
| mayor (coordenação, vida longa) | 1.119.705.289 | 2.406 | 465.431 |
| **dog** (pool, vida curta) | 1.409.019.523 | 5.433 | **259.376** |
| **wa-worker** (pool, vida curta) | 1.249.796.814 | 4.570 | **273.478** |

Este último par de colunas é o achado-chave da seção AC3 abaixo — ver lá antes de
concluir algo sobre "qual papel é o problema".

---

## 2. AC1 — Existe tarifa-plana/assinatura viável?

Pesquisa dedicada (agente separado, 28 chamadas de busca/fetch, todas as fontes
citadas). Resultado completo no comentário do bead; resumo aqui.

| Candidato | Assinatura tarifa-plana? | Tier mais barato | Teto do maior tier | Via Claude Code CLI? |
|---|---|---|---|---|
| **GLM / Zhipu (z.ai)** | Sim | $18/mês | $168/mês → 28.000 créditos/5h, 140.000/semana | Sim — endpoint compatível Anthropic, `ANTHROPIC_BASE_URL` |
| **Qwen / Alibaba** | Sim | $50/mês (tier Lite descontinuado) | único tier: 6.000 req/5h, 90.000/mês | Sim — Qwen Code CLI oficial + Claude Code |
| **Kimi / Moonshot** | Sim (embutido no plano geral, não avulso) | ~$19/mês | $199/mês (tiers CN/US não batem — ver nota) | Sim — endpoint dedicado `api.kimi.com/coding/`, doc oficial |
| **MiniMax** | Sim | $10/mês | $150/mês → até 30.000 req/5h | Sim — endpoint `api.minimax.io/anthropic`, doc oficial |
| OpenRouter / Groq / Together AI / DeepInfra | **Não** | — | — | N/A (só por token; capacidade dedicada existe mas é aluguel de GPU, não assinatura) |

**O mecanismo técnico funciona** — e isso ATUALIZA um achado anterior (ga-9oyvj,
Mayor 06/08): ele testou `ANTHROPIC_MODEL=compound-beta` direto e o Claude Code
recusou client-side (nome de modelo fora da lista conhecida). Os 4 candidatos aqui
usam um mecanismo DIFERENTE e documentado — `ANTHROPIC_DEFAULT_SONNET_MODEL` /
`_OPUS_MODEL` / `_HAIKU_MODEL` (remapeiam o TIER conhecido pro modelo deles, em vez
de mandar um nome de modelo arbitrário) — verificado ao vivo na doc oficial da Kimi
(`kimi.com/code/docs`, WebFetch direto, 26/08). Isso não é contradição, é mecanismo
diferente: o preset `groq-compound` continua quebrado pelo motivo que o Mayor achou,
mas "CLI padrão do Claude Code + endpoint de terceiro" É viável por essa outra rota —
relevante se algum dia isto virar AC4.

**Por que isso NÃO resolve o problema, mesmo assim:** todo teto publicado é em
requisições/janela (centenas a dezenas de milhares por 5h ou por semana), nunca em
tokens/dia — dimensionado pra 1-2 desenvolvedores humanos, não uma frota de dezenas
de sessões automatizadas rodando 24/7. Mesmo o maior tier de qualquer um dos 4
($150-168/mês) é ordens de grandeza pequeno demais pro nosso volume (3-5B
tokens/dia). Empilhar N contas pra fechar essa lacuna não é um caminho documentado
(são planos por-conta-individual, provavelmente contra o ToS de uso "fleet"), e não
foi testado — ficaria como especulação, não medição.

**Veredito AC1: NÃO é um substituto de conta única. Não vale perseguir sem antes
alguém decidir formalmente se vale o risco de ToS de multi-conta — e isso é uma
decisão de negócio, não técnica.**

### 2.1 Adendo — Gemini/Codex (correção, não estava no escopo original da
pesquisa)

Esta história absorveu o escopo do ga-pmiwj ("Gemini/Codex por assinatura",
fechado como superseded), mas o agente de pesquisa que rodei pra AC1 só cobriu
GLM/Qwen/Kimi/MiniMax + agregadores — Gemini e Codex/OpenAI NÃO estavam no
briefing que dei a ele. Percebi o buraco só depois de já ter fechado o ga-pmiwj
citando isso como coberto — errado, e corrijo aqui em vez de deixar a citação
errada de pé (a correção foi feita também no comentário do ga-pmiwj).

Checagem rápida (2 buscas, 26/08), suficiente pra não deixar a lacuna aberta:

- **Codex/OpenAI:** mesma forma que os outros 4 — embutido nos planos do
  ChatGPT (Go $8, Plus $20, Pro $100-200/mês), limite por janela de 5h (Plus:
  15-280 "tarefas" dependendo do modelo interno; Pro: 5x-20x isso). A CLI do
  Codex já é um preset registrado no Gas City (confirmado em ga-9oyvj, 06/08).
  Mesma conclusão esperada dos outros 4: dimensionado pra 1 dev, não pra
  frota — mas não medi o teto exato do tier Pro/20x em tokens, então isto é
  uma extrapolação por semelhança de forma, não uma medição direta como os
  outros 4.
- **Gemini/Google — achado DIFERENTE dos outros 4, vale registrar:** a
  assinatura INDIVIDUAL/consumidor pro Gemini Code Assist foi DESCONTINUADA
  em 18/06/2026 (redirecionada pro produto "Antigravity" — que, por
  coincidência, já aparece na lista de skills desta sessão). O que sobra é
  **licenciamento por ASSENTO da Google Cloud** (Standard $19-22,80/assento/
  mês) — estruturalmente diferente dos outros 4: é desenhado pra escalar
  por número de assentos comprados, não uma conta única com teto fixo. Isso
  muda a pergunta de "cabe numa conta?" pra "cabe no orçamento por N
  assentos?" — mas eu **não tenho o teto de uso por assento** (tokens ou
  requisições), então não dá pra concluir se compensa. **Fica como pergunta
  em aberto, não como "não" nem como "sim"** — sinalizando o gap em vez de
  fingir que medi.

## 3. AC2 — Self-host compensa?

Pesquisa dedicada (agente separado, 22 chamadas de busca/fetch, todas as fontes
citadas). Resultado completo no comentário do bead; resumo aqui.

**Erro meu, corrigido antes de usar o resultado:** no briefing que dei ao agente eu
escrevi tanto "~3-5B tokens/dia" quanto "~3.000-5.000 tokens/segundo" como se fossem
a mesma coisa — não são. 4B/dia ÷ 86.400s ≈ **46.300 tokens/s**, não 3-5 mil (eu
errei a conta por ~10x). O agente flagrou a inconsistência sozinho, recusou
escolher por mim, e rodou os dois cenários. Resolvo aqui com a Seção 1 deste mesmo
documento — que É a medição direta, sem ambiguidade: **2,7-4,8B tokens/dia**. Isso
corresponde ao "Cenário A" do agente (não ao B). Uso Cenário A como autoritativo
abaixo. Registro o erro em vez de escondê-lo — o próprio ato de checar contra a
Seção 1 é o motivo de eu confiar no número final.

### Custo de servir localmente, no nosso volume real (2,7-4,8B tokens/dia)

| GPU (24/7, confiável) | US$/mês só de aluguel |
|---|---:|
| Vast.ai marketplace (mais barato, sem SLA) | ~US$1.088-1.500 |
| RunPod Secure / Lambda on-demand (confiável) | ~US$1.452-3.130 |
| Together/Fireworks dedicado gerenciado | ~US$4.700-5.100 |

Modelo de referência: só a faixa **~32B** (Qwen2.5-Coder-32B/classe) é
economicamente plausível — GLM-4.6 (32B ativos/355B total MoE), Kimi K2 (32B
ativos/1 TRILHÃO total) e Qwen3-Coder-480B são MoE: mesmo com poucos parâmetros
ativos por token, TODOS os experts precisam caber em VRAM, exigindo **8+ GPUs
H100 só pra carregar os pesos** — isso sozinho já custa US$11.680-17.520/mês em
hardware, 16-24x a assinatura, antes de servir um token.

Com 3-4 GPUs H100 (dimensionado pro nosso throughput real, considerando que ~95%
do volume é cache-read — compute mais barato que prefill fresco, efeito
quantificado via a proporção de desconto de cache da própria Anthropic, 10% do
preço de input fresco, como proxy) + operação leve (não um cargo dedicado):
**estimativa central ~US$7.900/mês** (faixa US$4.000-23.500 dependendo do tier
de GPU escolhido).

**Comparação em US$/milhão de tokens (a lente certa, já que um lado é tarifa
fixa):**
- Assinatura atual: US$740 ÷ (~4B tokens/dia × 30 dias) ≈ **US$0,006/M tokens**.
- Self-host mais barato viável: **US$0,033-0,196/M tokens** — **5x a 32x mais
  caro por token**, estimativa central **~10,7x**.

**Por que self-host não pode vencer aqui, estruturalmente:** self-host tem um
PISO de hardware (nenhuma GPU 24/7 confiável sai por menos de ~US$1.000-1.500/mês,
não importa o volume) enquanto a assinatura é tarifa FIXA — quanto mais a
usamos, MENOR fica o custo por token dela. Não existe volume onde as duas curvas
se cruzam a favor do self-host **enquanto a assinatura continuar disponível sem
limite que force comprar uma segunda.** O único cenário em que o self-host
começa a fazer sentido é se o crescimento algum dia exigir **múltiplas
assinaturas de US$740** pra sustentar o volume (throttling por seat/limite,
não por dinheiro) — aí sim comparar self-host contra N×US$740, não contra 1.
Isso liga diretamente com a AC3: reduzir desperdício de cache-read é o que
adia esse dia.

**Veredito AC2: NÃO compensa hoje, por 5x a 32x. Não é "quase lá" — é uma
característica estrutural do regime de cobrança (fixo vs. piso-de-hardware), não
um detalhe de preço de GPU que pode mudar com pesquisa melhor.**

## 4. AC3 — De onde vem o cache-read (97%), e dá pra cortar sem perder performance?

Esta é a pergunta que rende valor mesmo ficando 100% no Claude Code (Mayor já tinha
sinalizado isso) — e é a única que eu medi diretamente na própria estrutura da
cidade, não em pesquisa externa.

### 4.1 Existem DOIS drivers, não um — e eles têm remédios diferentes

**Driver A — piso fixo por turno.** Todo turno reenvia um prefixo que quase não
muda: CLAUDE.md global (8.661 B) + CLAUDE.md do projeto (13.965 B) + fragmentos de
contexto de papel (propulsion/operational-awareness/approval-fallacy/capability-
ledger/tdd-discipline/etc., ~26.000 B pro pack gastown) + **town-deltas.template.md,
sozinho 42.220 B** + MEMORY.md (20.033 B, quando ativo) + lista de skills + schemas
de ferramenta. Medido direto nos arquivos-fonte (`wc -c`), não estimado.

`town-deltas.template.md` é o maior item isolado, e está CRESCENDO: snapshots
históricos em worktrees antigos mostram 22.764 → 24.875 → 36.198 → 38.125 → 42.220
bytes ao longo do tempo. É doutrina acumulada (post-mortems de incidente, regras
específicas) que nunca é consolidada/podada — cada incidente novo soma bytes, para
sempre, multiplicado por TODO turno de TODA sessão da cidade.

**Driver B — crescimento dentro da sessão (dominante em volume).** Medido em 4
sessões reais de papéis diferentes, sequência de `cache_read_input_tokens` por
turno, ordenado por timestamp:

| Sessão | Turnos únicos | cache_read no turno 1 | cache_read máximo atingido | Resets (compactação) |
|---|---:|---:|---:|---:|
| mayor (3h48 corridas) | 273 | 100.183 | 452.368 | 2 |
| dog (várias horas) | 455 | 34.971 | 931.616 | 1 |
| wa-worker (~1h12) | 202 | 36.927 | 611.203 | 0 |
| **oracle (~40h corridas, sem restart)** | **1.748** | 145.812 | **995.241** | 13 |

Em TODAS as 4 sessões, `cache_read` cresce quase monotonicamente com o índice do
turno — do piso (Driver A, ~30-180K) até centenas de milhares, e no caso do Oracle
(sessão mais longa da amostra) até quase **1 milhão de tokens por turno único**,
antes do próximo reset de compactação. Compactação existe e dispara (13 vezes nas
40h do Oracle), mas só reativamente perto do limite de contexto — nunca
proativamente — então cada sessão sobe a curva inteira antes de resetar.

**Isso bate com a tabela de "cache_read/msg por papel" da seção 1:** papéis de
vida curta por doutrina (dog, wa-worker — "encontra trabalho → executa → fecha →
sai") têm média de ~260-275K tokens/mensagem; papéis de vida longa (crews
persistentes mila/batista/digo/thies/peter, coordenação mayor/oracle) têm média de
~450-540K — quase o DOBRO, apesar de terem MENOS mensagens totais em alguns casos.
A doutrina de dog já é o comportamento certo por acidente; o buraco está nos papéis
de vida longa.

**Hipótese testada e descartada:** cheguei a suspeitar que `gc prime` (ou comando
similar) reinjetasse o bloco de doutrina inteiro repetidamente DENTRO da mesma
sessão, como texto de resultado de ferramenta (o que ENTRARIA no histórico e seria
recontado a cada turno seguinte — um desperdício real e diferente do Driver B).
Achei o texto da doutrina repetido até 120x num único arquivo de transcript, o que
parecia confirmar a suspeita — mas checando o TIPO da entrada, 119/120 ocorrências
eram `type:"last-prompt"`, um registro de bookkeeping local da UI (`lastPrompt`,
`leafUuid`, `sessionId`) SEM campo `message` e SEM `usage` — fora do caminho de
billing inteiramente. Hipótese descartada por medição direta, não por suposição.

### 4.2 Estimativa de proporção (aproximada, sinalizada como tal)

Usando um piso médio ponderado de ~100K tokens/turno (meio da faixa 30-180K medida)
contra a média real de ~362K cache_read/mensagem (13,2B ÷ 36.419 msgs): o piso fixo
explica **~28%** do cache_read médio; o crescimento-dentro-da-sessão explica os
outros **~72%**. Isto é uma estimativa de ordem de grandeza a partir de dados
agregados, não uma decomposição exata por sessão — dito isso porque a conclusão
prática muda dependendo de qual driver se ataca.

### 4.3 Recomendação AC3 (risco zero de perder performance, nenhuma das duas
depende de trocar de modelo)

1. **Podar `town-deltas.template.md`** — 42.220 B hoje, cresceu ~2x desde sua
   origem. Não é conserto imediato deste bead (mexer em doutrina viva é escopo de
   quem a mantém), mas o padrão de "post-mortem vira parágrafo permanente, nunca
   consolidado" é o mecanismo de crescimento — vale bead próprio pra
   quem tem essa doutrina no domínio.
2. **Compactação mais cedo em papéis de vida longa** (mayor, oracle, crews
   persistentes) em vez de só perto do teto de contexto — é o driver de ~72% do
   volume medido. Não sei se o limiar de compactação é configurável no Claude Code
   ou é comportamento fixo do harness — **isto precisa de verificação técnica
   separada antes de virar proposta concreta**, não estou afirmando que dá pra
   mudar.
3. Nenhuma das duas exige trocar de motor, gastar dinheiro, ou arriscar
   performance — são as únicas mudanças deste spike inteiro com risco zero.

---

## 5. AC4 — Teste ponta-a-ponta

**Condição de disparo:** só roda se AC1 OU AC2 derem positivo. **Os dois deram
negativo** (AC1: produto existe mas não escala pra frota; AC2: 5-32x mais caro,
estruturalmente). Isso é exatamente a saída válida que o próprio AC do bead prevê:
*"se nenhum dos dois for vantajoso, o spike termina sem esse teste e isso conta
como resultado válido."* **AC4 não roda.** Nenhum dinheiro gasto em conta/chave
paga.

---

## 6. Recomendação final

**Não trocar o motor, não self-hospedar. Nenhuma das duas rotas paga o teto de
risco (performance, ToS, ou ambos) pelo retorno medido.** A alavancagem real deste
spike inteiro é AC3 — e ela não depende de nenhuma decisão de fornecedor.

**Uma ressalva importante sobre "economia":** a assinatura atual é tarifa FIXA
(paga-se ~US$740/mês independente do volume, dentro dos limites de uso da
janela de 5h/semana). Isso significa que cortar cache-read **não reduz a fatura
deste mês** — o ganho real de AC3 é outro, e mais valioso do que parece à
primeira vista:
1. **Menos throttling por limite de janela** (5h/semana) → menos sessão travada
   esperando quota voltar → é literalmente o "sem perder performance" que o
   bead pede, na direção oposta (ganha performance).
2. **Adia o dia em que crescimento força comprar uma 2ª assinatura** — que é a
   ÚNICA condição sob a qual a conta de self-host (AC2) ou multi-conta (AC1)
   deixaria de ser negativa. Cortar desperdício de cache-read hoje é o que
   compra tempo antes de qualquer uma das outras duas rotas precisar ser
   reaberta.

**Prioridade 1 — verificação técnica, não produto (fazer primeiro, risco zero,
custo zero):** descobrir se o limiar de compactação automática do Claude Code é
configurável, e se sim, testar compactação mais cedo (não esperar chegar perto do
teto de contexto) nos papéis de vida longa — mayor, oracle, crews persistentes
(mila/batista/digo/thies/peter). Medido: esses 7 papéis somam ~64% do cache_read
total da amostra e rodam a ~450-540K tokens/mensagem em média, quase o dobro dos
papéis de vida curta (dog/wa-worker, ~260-275K) que já fazem a coisa certa por
doutrina ("encontra → executa → fecha → sai"). Isto é uma pergunta em aberto, não
uma proposta pronta — decide-se com uma verificação técnica direta (é
configuração do harness, não decisão de produto/negócio).

**Prioridade 2 — baixo esforço, sempre correto, sem urgência:** consolidar/podar
`town-deltas.template.md` (42.220 B hoje, ~2x maior que há semanas, cresce a cada
incidente novo sem nunca ser resumido). É o menor dos dois drivers medidos (~28%
do piso fixo, que por sua vez é só ~28% do total — ou seja, uma fatia pequena do
todo), mas é uma escrita pura sem contrapartida: uma vez que a lição de um
incidente vira guarda automatizada, o parágrafo de prosa que a registrou pode sair
da doutrina viva. Dono natural: quem mantém essa doutrina, não este bead.

**Não recomendado agora, revisar só se a premissa mudar:**
- AC1 (multi-conta GLM/Qwen/Kimi/MiniMax/Codex): revisar apenas se o
  crescimento da frota algum dia tornar N×US$740 uma comparação real —
  decisão de negócio (risco de ToS), não técnica.
- AC2 (self-host): mesma condição de gatilho.

**Pendência real, não fechada (não confundir com "não recomendado"):** o
licenciamento por assento do Gemini Code Assist (Seção 2.1) tem forma
estruturalmente diferente dos outros candidatos — eu não tenho o teto de uso
por assento pra concluir se compensa. Não é "não vale a pena", é "não sei
ainda". Quem pegar isso a seguir: comece por aí, é o único fio solto deste
spike com pergunta em aberto real.

## 7. Gasto registrado

US$0,00. Toda a pesquisa (AC1, AC2) foi feita sem criar conta, sem chave paga, sem
sinal de pagamento. AC3 foi 100% medição local (transcripts + arquivos-fonte já
presentes na máquina).

## Fontes

- AC1 e AC2: relatórios completos dos agentes de pesquisa, com URLs por
  afirmação, anexados ao comentário do bead ga-w6vbc (economiza espaço aqui;
  peça se precisar re-verificar uma fonte específica).
- AC3: `usage_agg.py` e `session_shape.py` (scripts desta investigação, dedup por
  `message.id`), rodados ao vivo em 26/08 contra `~/.claude/projects/**/*.jsonl`;
  tamanhos de arquivo via `wc -c` direto nos fragmentos de template em
  `.gascity-gastown-hq/packs/town-deltas/` e `.gascity-gastown-hq/.gc/system/packs/`.
