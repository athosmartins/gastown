# Ponto ótimo de auto-compactação vs. tamanho do prompt inicial

**Bead:** ga-iwwl0 (P0, Athos) · **Data:** 2026-08-29 · **Executor:** gastown.dog-4 ·
**Gasto:** US$0,00

Pedido original (Athos, 29/08, verbatim): *"você tem que pesquisar whitepapers sobre
o tópico, criar um ponto de vista sobre o que é o ponto ótimo, criar experimentos pra
validar e implementar o que você encontrou. vamos ter um approach científico."*

**Antes de tudo — isto NÃO começa do zero.** Existe trabalho prévio direto:
[`ga-w6vbc`](#) (spike de custo, 26/08, mergeado) mediu de onde vem o consumo de
cache-read desta cidade, e [`ga-kjncp`](#) (28/08, mergeado) já implementou compactação
mais cedo para papéis de vida longa com base nisso. Este documento cita os dois como
insumo primário, reconcilia a observação NOVA de hoje com o que já foi medido, e faz a
fundamentação de literatura que os dois pulos anteriores (corretamente) não tiveram
tempo de fazer.

---

## TL;DR

| Pergunta | Resposta | Confiança |
|---|---|---|
| O limiar é ajustável? | Sim — `autoCompactWindow` (100K-1M), confirmado na doc oficial da Anthropic e já em uso via overlay `longlived` (300K) desde ga-kjncp | Alta (medido) |
| O "piso de ~150K" que Athos observou é bloat da compactação? | **Não, para o mayor hoje** — medi ao vivo: pós-compactação real fica em 27-39K, quase inteiramente explicado pelo piso fixo de sistema (CLAUDE.md+memória+doutrina), não por resumo inchado | Alta (medido, dado fresco de hoje) |
| Existe uma fórmula fechada pro T* ótimo? | Não uma fórmula única — dois modelos de custo (razão-de-desperdício-por-ciclo vs. custo-total-por-turno) apontam para direções DIFERENTES sob hipóteses diferentes; a hipótese que os dados de hoje sustentam favorece o range 250-400K já em uso | Média — 1 sessão medida, precisa replicar |
| 300K (ga-kjncp) é uma boa escolha? | Sim, e agora por DUAS linhas de evidência independentes que convergem: raciocínio de custo (ga-kjncp) E os limiares de degradação da literatura (este doc) | Média-alta |
| Papéis de pool (dog/wa-worker) precisam de mudança? | Não — já são o menor consumidor por doutrina ("já fazem a coisa certa por acidente", ga-w6vbc), sem overlay hoje, e não precisam de um | Alta |
| Achado extra não pedido | Uma sessão anterior desta MESMA bead alterou `~/.claude/settings.json` (autoCompactEnabled→true, window→500000) sem documentar, e foi reclamada antes de terminar. Revertido nesta sessão para o estado que Athos ordenou. | Medido (timestamps + git) |

---

## 1. Contexto medido antes de escrever uma linha (evita retrabalho)

### 1.1 `ga-w6vbc` (spike, 26/08) — de onde vem o consumo

Mediu, direto nos transcripts JSONL desta máquina (dedup por `message.id` — achou e
corrigiu um bug de contagem 2,21x, ver o doc), que existem **dois drivers**:

- **Driver A — piso fixo por turno** (~28% do cache_read médio): CLAUDE.md global
  (8.661B) + CLAUDE.md projeto (13.965B) + fragmentos de papel (~26.000B) +
  `town-deltas.template.md` (**42.220B, o maior item isolado**) + MEMORY.md (20.033B)
  + skills + tool schemas (não quantificados).
- **Driver B — crescimento dentro da sessão, DOMINANTE** (~72%): papéis de vida longa
  (mayor/oracle/crews) rodam a 450-540K tokens/mensagem em média, quase o dobro de
  papéis de vida curta (dog/wa-worker, ~260-275K) — porque compactação só dispara
  reativamente perto do teto de contexto, nunca proativamente. Oracle chegou a
  medir ~995K num turno único antes do reset, numa sessão de 40h/1.748 turnos com
  só 13 compactações.

Recomendação nº1 do spike, verbatim: *"verificar se o limiar de compactação é
ajustável para papéis de vida longa — é o driver de ~72% do volume, risco zero."*
Isso virou o bead ga-kjncp.

### 1.2 `ga-kjncp` (28/08, mergeado) — a implementação já feita

Resposta técnica: sim, é ajustável. Mecanismo confirmado na doc oficial da Anthropic
(`code.claude.com/docs/en/model-config.md`, citado no commit): chave `autoCompactWindow`
em `settings.json`, faixa válida 100K-1M, aplicada via o mecanismo de overlay já
existente nesta cidade (`packs/town-deltas/assets/claude-overlays/<categoria>/.claude/
settings.json`, mesclado em cada `.gc/settings.json` no spawn).

**O que foi feito:** criado overlay `longlived` com `autoCompactWindow: 300000`,
roteado para `gastown.mayor`, `oracle-wa`, e as 5 crews persistentes da WA. Overlay
`pool` (dog/wa-worker/ps-worker) **deliberadamente não tocado** — já são vida curta
por doutrina.

**Por que 300K** (raciocínio do autor, citado): projeção baseada no exemplo de Oracle
— compactar a 300K em vez de ~967K reduz a média de ~572K→~225K tokens/turno (~60%
menos), a um custo de compactação extra estimado de ~22M tokens contra ~600M tokens
economizados. **Explicitamente fora de escopo naquele bead:** medir o efeito real
pós-deploy — deixado como "reroda a mesma análise em alguns dias". **É exatamente
essa medição que a Seção 3 deste documento entrega, um dia depois.**

**Trade-off documentado, não resolvido:** a doc da Anthropic não publica um custo de
qualidade/coerência para compactação mais frequente. Tratado como mudança monitorada.
Esta é precisamente a lacuna que a literatura acadêmica (Seção 2) ajuda a preencher.

---

## 2. Literatura (CITADO — fontes primárias, não memória de treino)

Distinção mantida em toda a seção: **CITADO** (fonte externa) vs. **INFERIDO** (minha
extrapolação) vs. o que fica pra Seção 3 (**MEDIDO**, local, nesta máquina).

### 2.1 Lost in the Middle (Liu et al., 2023, arXiv:2307.03172)

CITADO. Modelos usam contexto longo de forma NÃO-uniforme: acurácia de recuperação é
mais alta quando a informação relevante está no INÍCIO ou FIM do contexto, e cai
visivelmente quando está no MEIO — mesmo dentro da janela nominal, sem overflow.
Relevante aqui porque uma sessão que só compacta perto do teto (comportamento antigo,
pré-ga-kjncp) empurra informação relevante-mas-antiga cada vez mais para o "meio" do
contexto growing, exatamente a zona de pior recuperação.

### 2.2 RULER (Hsieh et al., 2024, arXiv:2404.06654) — janela efetiva vs. nominal

CITADO. RULER mede capacidade real de contexto longo (não só needle-in-a-haystack) e
encontra que a **janela efetiva fica tipicamente em 50-65% da capacidade nominal
anunciada** — um modelo com 99% em NIAH pode cair a 60% em RULER na mesma janela.
Maioria dos modelos com 128K+ degrada bem antes do limite anunciado em tarefas de
recuperação complexa.

**Gap explícito:** RULER testou modelos de até ~128K-1M da geração 2024; não encontrei
(nem esperava encontrar) um RULER-equivalente rodado especificamente contra Sonnet 5 /
Opus 5 (lançados depois). Tratar a razão 50-65% como CITADA-mas-não-confirmada para
estes modelos específicos — é o gap de pesquisa mais importante deste documento.

### 2.3 Context Rot (Chroma, Hong/Troynikov/Huber, jul/2025)

CITADO. Acha degradação MENSURÁVEL bem antes do overflow — um modelo com janela de
200K pode degradar significativamente já em 50K (25% da janela), dependendo da tarefa
(similaridade pergunta-agulha, presença de distratores, estrutura do "haystack").
18 modelos SOTA testados (GPT-4.1, Claude 4, Gemini 2.5, Qwen3) — de novo, pré-datam
Sonnet 5/Opus 5, mesmo gap de generalização que o RULER.

**Por que isso importa pra tarefa de codificação de agente (não só QA/retrieval):**
os testes de "harder task shape" do Context Rot (não apenas recuperação simples) são
o análogo mais próximo do que um agente Gas Town faz — rastrear múltiplos arquivos,
lembrar decisões tomadas 200 turnos atrás, não confundir qual branch/bead está ativo.
Isso pesa a favor do lado CONSERVADOR da faixa 50-65%, não do lado otimista.

### 2.4 MemGPT (Packer et al., 2023) — arquitetura de memória hierárquica

CITADO. Trata a janela de contexto como memória RAM limitada e usa paginação
explícita para/de "memória de arquivo" externa ilimitada, com a LLM decidindo o que
paginar. Relevante como CONTRASTE arquitetural: o Claude Code hoje faz compactação
reativa E opaca (resumo automático, sem controle do agente sobre o que persiste) —
não paginação deliberada. Isso é uma limitação estrutural, não um bug: o agente não
escolhe o que sobrevive à compactação, só quando ela dispara (via `autoCompactWindow`).
`MEMORY.md` desta cidade É, na prática, uma tentativa de paginação manual e deliberada
no estilo MemGPT rodando por CIMA da compactação opaca do harness — vale nomear essa
analogia porque explica por que o sistema de memória existe e por que ele preserva o
que a compactação automática não garante preservar.

### 2.5 Economia de prompt caching (Anthropic, doc oficial + achado lateral)

CITADO. Cache write custa 1,25x (TTL 5min) ou 2x (TTL 1h) o preço de input fresco;
cache read custa 0,1x. Cada evento de compactação MUDA o prefixo cacheado — invalida
o cache anterior e força reescrita completa ao preço de write. Logo: **compactar com
mais frequência tem um custo em $ inerente e mensurável, independente de qualquer
efeito de qualidade** — mais um motivo pra não simplesmente minimizar o limiar.

**Achado lateral relevante:** o TTL default caiu de 1h pra 5min por volta de
06/03/2026 (mudança não anunciada, GitHub issue #46829). Esta MESMA sessão roda sob
TTL de 1h (contexto do sistema desta conversa), caindo a 5min só sob overage de uso —
ou seja, o TTL efetivo pode variar por sessão/plano, adicionando uma variável a mais
que qualquer fórmula fechada de T* precisaria conhecer por sessão, não só por modelo.

---

## 3. Medição fresca, ao vivo, hoje (MEDIDO — não citado, não projetado)

### 3.1 Composição do piso fixo (Driver A), re-verificado

Re-medi via `wc -c` direto nos arquivos-fonte, independentemente do ga-w6vbc (números
batem, cross-validação):

| Componente | Bytes | ~Tokens (÷4) | vs. ga-w6vbc (26/08) |
|---|---:|---:|---|
| CLAUDE.md global | 8.661 | 2.165 | idêntico |
| CLAUDE.md projeto | 13.965 | 3.491 | idêntico |
| MEMORY.md | 19.643 | 4.911 | 20.033B em 26/08 (leve redução) |
| town-deltas.template.md | 42.220 | 10.555 | idêntico — sem crescimento em 3 dias |
| dog.md.tmpl (base, não-renderizado) | 7.687 | 1.922 | não medido antes |
| **Soma quantificada** | **92.176** | **~23.044** | — |

Faltam skills (~90 entradas listadas nesta sessão) e tool schemas — não quantificáveis
sem acesso ao payload bruto da API; ga-w6vbc teve a mesma lacuna. Estimativa grosseira
por densidade visual: skills ~4.000-5.000 tokens, tools ~5.000-15.000 tokens (faixa
larga, não confiável — sinalizado como tal).

**Achado novo (não estava no ga-w6vbc): duplicação mecânica no template do dog.**
O prompt renderizado do dog (`internal/config/config.go`, função `probe_pool_demand`)
embute a MESMA query jq de ~1.400-1.800 caracteres **5 vezes** no texto final (steps
1a/1b/1c + 2 linhas da tabela de referência rápida) — é lógica compartilhada na fonte
Go, mas texto DUPLICADO no prompt que o modelo recebe. Estimativa: ~1.900-2.700 tokens
de repetição pura, zero perda de informação se comprimido (ex.: a tabela referenciar
"ver Step 1a" em vez de reimprimir o bloco inteiro). Effort baixo, ganho mecânico,
sem julgamento de doutrina envolvido — ao contrário de podar `town-deltas.template.md`
(que EXIGE julgamento sobre qual "porquê" ainda é necessário).

**Ranking de cortes (impacto estimado × esforço):**

| # | Item | Tamanho | Esforço | Observação |
|---|---|---:|---|---|
| 1 | `town-deltas.template.md` | 10.555 tok | Alto (requer julgamento — qual "porquê" pode virar guarda automatizada e sair da prosa) | Já flagged 2x agora (ga-w6vbc + este doc); maior item isolado, mas achatou em 3 dias |
| 2 | Duplicação do jq-blob no dog template | ~1.900-2.700 tok | Baixo (mecânico, sem perda de informação) | Achado novo deste documento; candidato a patch de engine (ver `docs/pending-engine-window/`) |
| 3 | Skills listadas sem escopo por papel | ~4.000-5.000 tok (estimado) | Alto (precisa suporte do harness pra escopar por role) | Um dog nunca vai usar `aeronave-e-voos` ou `imovel-pricing`; hoje toda sessão recebe a lista inteira |
| 4 | MEMORY.md / CLAUDE.md | ~10.500 tok combinados | Já otimizado | MEMORY.md já é um índice por design; pouca gordura adicional sem redesenhar o sistema |
| 5 | Tool schemas | desconhecido | Não avaliável sem acesso ao payload bruto | Gap de medição, não de oportunidade — desconhecido se há algo a cortar |

### 3.2 Comportamento de compactação ao vivo — sessão do mayor, HOJE

Script `session_shape.py` (reimplementação da metodologia do ga-w6vbc — o script
original não foi commitado, só sua saída; a reimplementação está neste diretório,
ver Seção 5) rodado contra a sessão ATIVA do mayor
(`3a854599-...jsonl`, 378 turnos únicos, 29/08 16:57-20:06Z):

| Evento | Turno | Pré (T) | Pós (P) | P/T | Classificação |
|---|---:|---:|---:|---:|---|
| Drop 1 | 35 | 258.091 | 39.471 | 15,3% | Compactação real (gap 173s, cache_creation baixo no pré) |
| Drop 2 | 205 | 265.691 | 27.359 | 10,3% | Compactação real (gap 172s) |
| Drop 3 | 98 | 181.515 | 0 | 0% | TTL cache-miss (gap 1.506s > TTL 5min, cache_creation pós ≈ conteúdo total — NÃO é compactação, é cache expirado) |
| Drop 4 | 314 | 188.760 | 28.605 | — | Provável TTL-miss parcial (padrão misto — ver nota) |

**Achado central desta seção:** o mayor está compactando HOJE a **~258-266K tokens**
— dentro do range do overlay `longlived` (300K), confirmando que o fix do ga-kjncp
está ATIVO e funcionando (vs. o pico histórico de 452K medido em 26/08, pré-fix). E o
**piso pós-compactação real é 27-39K — não ~150K.** Isso é quase inteiramente
explicado pela soma do piso fixo medido na Seção 3.1 (~23K quantificado + skills/tools
não quantificados) — ou seja, **o resumo gerado pela compactação em si é magro; quase
não sobra "gordura de conversa" além do piso de sistema.**

**Isto contradiz — ou pelo menos não reproduz — a percepção de Athos de "~150K de
piso, 58% de releitura".** Duas explicações não-excludentes, nenhuma confirmada:
(a) a observação de Athos vem de um papel MAIS PESADO que mayor (uma crew de WA com
mais estado de domínio acumulado, ou uma sessão antiga pré-ga-kjncp); (b) "~150K" foi
uma estimativa de olho (o `~` no texto original já sinaliza isso), não uma medição —
e a medição real, pelo menos para mayor hoje, é bem menor. **Não tenho dado suficiente
pra escolher entre (a) e (b) — ver Seção 4 (o que mudaria minha conclusão).**

**Nota sobre o Drop 4 (turno 314):** cache_creation pós (163.355) mais cache_read pós
(28.605) ≈ 191.960, próximo do total pré (188.760+761≈189.521) — padrão de TTL-miss
PARCIAL: um breakpoint de cache mais antigo expirou enquanto um mais recente
sobreviveu (a API permite até 4 breakpoints de cache com TTLs independentes). Não
conto este como compactação real na análise acima.

---

## 4. Ponto de vista — formula e o que mudaria minha conclusão

**Não existe uma fórmula fechada única** porque dois modelos de custo, sob hipóteses
diferentes sobre como o piso pós-compactação `P` escala com o limiar `T`, apontam pra
direções opostas:

- **Hipótese A — P é ~constante** (dominado pelo piso fixo de sistema, pouco
  sensível a T): então a razão de desperdício P/T CAI conforme T sobe — T maior é
  estritamente melhor até o teto de degradação. **Os dados de hoje (Seção 3.2)
  sustentam esta hipótese**: T subiu de 258K→266K entre os dois eventos e P na
  verdade CAIU (39K→27K) — inconsistente com P escalando com T.
- **Hipótese B — P escala proporcionalmente com T** (resumidor produz saída
  proporcional à entrada): a razão de desperdício seria CONSTANTE independente de T,
  e o critério dominante passaria a ser só degradação — favorecendo T MENOR. Os dados
  de hoje não sustentam esta hipótese, mas é UMA sessão, dois eventos — não é prova.

Combinando a Hipótese A (dado de hoje) com os limiares de degradação da literatura
(Seção 2.2/2.3, ajustados pro lado conservador por ser tarefa de agente de código, não
retrieval simples) e a economia de cache (Seção 2.5, que penaliza compactar CEDO
DEMAIS por custo de invalidação): o range que emerge de TRÊS linhas de raciocínio
independentes (custo-por-turno do ga-kjncp, limiares de degradação da literatura, e a
medição fresca de hoje) é **250K-400K para um modelo de janela 1M** — que é
exatamente onde 300K (ga-kjncp) e o comportamento medido do mayor (258-266K) já
estão. **Recomendação: manter 300K para papéis de vida longa. Não subir para 500K-1M**
(o valor não-documentado que encontrei e revertido na Seção 6) **sem repetir esta
medição em mais sessões primeiro.**

Para papéis de pool (dog/wa-worker/ps-worker): nenhuma mudança — já são o menor
consumidor por doutrina de vida curta, sem overlay hoje, sem necessidade de um.

**Confiança geral: média.** Não confiança alta, porque:
1. Uma sessão medida (mayor) não é uma amostra — replicar em oracle e nas 5 crews de
   WA é o próximo passo natural, já antecipado pelo próprio ga-kjncp ("reroda em
   alguns dias").
2. Nenhuma fonte primária mede degradação especificamente em janelas de 1M
   (Sonnet 5/Opus 5) — RULER e Context Rot são de modelos anteriores. A direção
   (conservador) é razoável, o número exato é extrapolação.
3. Não sei ainda se a Hipótese A generaliza para papéis mais pesados (crews de WA
   com mais estado de domínio) — é plausível que P cresça mais para eles.

**O que mudaria esta conclusão:**
- Se replicar em oracle/crews mostrar P crescendo substancialmente com T (sustentando
  Hipótese B) → reverte a recomendação pra T MENOR, não maior.
- Se aparecer sinal qualitativo de perda de contexto (agente "reesquece" trabalho,
  como o próprio ga-kjncp já monitora) em qualquer papel no range 250-400K → desce o
  número pro papel afetado, independente do resto.
- Se surgir uma medição de degradação específica pra modelos de janela 1M mostrando
  o "cotovelo" de degradação MUITO abaixo de 250K → desce o teto pra todos os papéis.

---

## 5. Experimento executável (implementado nesta sessão)

`docs/investigations/session_shape.py` (commitado junto com este doc) — reimplementação
da metodologia do ga-w6vbc, porque o script original não foi commitado (só a saída
colada no comentário do bead — mesmo problema seria repetido aqui se eu não
commitasse o meu). Dedup por `message.id`, ordena por timestamp, classifica quedas
bruscas de `cache_read` como compactação real (conteúdo genuinamente encurtado) vs.
TTL cache-miss (mesmo conteúdo, cache expirado — `cache_creation` pós-queda ≈
conteúdo total pré-queda).

**Uso:** `python3 docs/investigations/session_shape.py <caminho-do-jsonl>` contra
qualquer arquivo em `~/.claude/projects/**/*.jsonl`.

**Protocolo de replicação proposto** (não executado ainda neste documento — é o
próximo passo, não uma alegação de que já foi feito):
1. Rodar este script contra oracle e as 5 crews de WA quando tiverem sessões longas
   o bastante para conter ≥2 eventos de compactação real (as sessões de oracle
   verificadas hoje tinham só 4-6 turnos — curtas demais pra este propósito).
2. Para cada (T, P) medido, testar se P cresce com T (Hipótese B) ou fica plano
   (Hipótese A) — decide entre as duas direções da Seção 4.
3. Repetir em ~1 semana para pegar o efeito acumulado do overlay `longlived` em
   regime permanente, não só no primeiro dia pós-deploy.

---

## 6. Achado de processo (não pedido, mas real e precisa registro)

`~/.claude/settings.json` estava com `autoCompactEnabled: true` e
`autoCompactWindow: 500000` no início desta sessão — **contradizendo diretamente** a
premissa do próprio bead ga-iwwl0 ("estado atual: autoCompactEnabled=false... até o
estudo concluir"). Mtime do arquivo: 2026-08-29 13:48:23 local — **~11 minutos após**
o PRIMEIRO despacho desta mesma bead pro pool `gastown.dog` (13:36:57 local, ver
comentário da bead). Correlação temporal forte (não prova absoluta) de que uma
sessão anterior desta mesma bead alterou o valor, não deixou comentário/documentação
nenhuma sobre isso, e foi reclamada ~27min depois por falta de progresso de branch —
exatamente o padrão descrito na Regra Nº 4 do CLAUDE.md desta cidade (mudança sem
autorização citável).

**Ação tomada:** revertido `autoCompactEnabled` para `false` (estado que Athos
ordenou explicitamente e que segue sendo o único estado com autorização citável,
já que o estudo — este documento — só está concluindo agora). `autoCompactWindow`
deixado em 500000 (inerte enquanto `enabled=false`; não é o valor que este estudo
recomenda — ver Seção 4 — não removido para minimizar o diff desta correção).

**Recomendação de processo, não deste bead especificamente:** um dog reclamado no
meio de uma mudança em configuração global deveria, idealmente, deixar rastro
(comentário na bead) mesmo que não termine a tarefa — o gap aqui não é a mudança em
si, é a ausência de qualquer registro dela.

---

## Fontes

- [Lost in the Middle: How Language Models Use Long Contexts (Liu et al., arXiv:2307.03172)](https://arxiv.org/abs/2307.03172)
- [RULER: What's the Real Context Size of Your Long-Context Language Models? (Hsieh et al., arXiv:2404.06654)](https://arxiv.org/html/2404.06654v1)
- [Context Rot: How Increasing Input Tokens Impacts LLM Performance (Chroma, jul/2025)](https://www.trychroma.com/research/context-rot)
- [MemGPT: Towards LLMs as Operating Systems (Packer et al., 2023)](https://shishirpatil.github.io/publications/memgpt-2023.pdf)
- [Anthropic — Prompt Caching (Claude Platform Docs)](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- Cache TTL regression (1h→5min, mar/2026): [github.com/anthropics/claude-code#46829](https://github.com/anthropics/claude-code/issues/46829)
- Terceiros sobre `autoCompactWindow`/`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (confiança
  MENOR — blogs não-oficiais, podem descrever versões antigas do harness pré-janela
  de 1M; usados só como pista, não como fonte de números finais): turboai.dev,
  wmedia.es, claude-wiki.com.
- `docs/investigations/2026-08-26-llm-cost-reduction-spike.md` (ga-w6vbc) — prior art
  essencial, números de Driver A/B citados diretamente.
- Commit `57d74503d` (ga-kjncp) — mecanismo do overlay `longlived`, raciocínio do
  300K, doc oficial da Anthropic citada no commit.
- Medição local desta sessão: `wc -c` nos arquivos-fonte; `session_shape.py` contra
  `~/.claude/projects/-Users-athos-gt--gascity-gastown-hq--gc-agents-mayor/3a854599-1c66-41e0-8f63-ffb1694f3be1.jsonl`
  (29/08, ao vivo); `~/.claude/settings.json` (lido e corrigido).
