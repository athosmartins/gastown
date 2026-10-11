# Agent Instructions

See **CLAUDE.md** for complete agent context and instructions. This file exists for compatibility
with tools that look for AGENTS.md.

## Contents

- 🚨 REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA
- 🚨 REGRA Nº 2 — só pergunte PRODUTO/NEGÓCIO. Técnico nunca vai pro Athos
- 🚨 Dispatch de pesquisa ("research-only") — proíba o CANAL, não só o arquivo
- Role: Deacon — scope and boundaries
- Cross-Clone Discipline
- Beads, Gas Town comms and Session Completion

Rule (Athos, 2026-10-11, ga-vhzdh5): this file stays ≤ 200 lines. Detail lives in `docs/` with a pointer.

---

## 🚨 REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA

**Pergunta aberta é PROIBIDA.** Duplicada aqui DE PROPÓSITO (não é redundância
preguiçosa): agentes não-Claude (Codex, Gemini) leem este arquivo e NÃO leem o
CLAUDE.md, então um ponteiro "veja o CLAUDE.md" deixaria justamente eles sem a
regra. Se você é um agente lendo AGENTS.md, esta regra vale para você.

Formato OBRIGATÓRIO, em qualquer canal (terminal, mail, nudge, WhatsApp, Slack):

1. **Contexto primeiro, em BULLET POINTS curtos** — o problema e por que a
   decisão importa. Nada de parágrafo corrido.
2. **Opções concretas e mutuamente exclusivas**, cada uma com o **TRADEOFF
   explícito** (o que ele ganha e o que perde).
3. **A 1ª opção é SEMPRE a SUA recomendação** — você estudou o problema, tome
   posição.
4. **Texto livre só como UMA das opções**, nunca como a pergunta inteira.
5. Sem a ferramenta AskUserQuestion disponível? Escreva as opções **numeradas
   1/2/3** no corpo da mensagem, com a mesma estrutura.

❌ PROIBIDO: "O que você acha?", "Como prefere?", "Pode confirmar?", "Alguma
preferência?" — qualquer coisa que obrigue o Athos a redigir a resposta do zero.

⚖️ **Antes de perguntar, cheque se precisa perguntar.** Default óbvio, ou é do
SEU domínio técnico, ou a resposta não muda o que você fará → **decida e
reporte**, não pergunte. Sobre-perguntar viola a regra tanto quanto perguntar
errado.

---

## 🚨 REGRA Nº 2 — só pergunte PRODUTO/NEGÓCIO. Técnico nunca vai pro Athos

Mandato do Athos (2026-07-31). Ele **não deve precisar de conhecimento de
programação ou engenharia de software** para responder você. Se responder exige
ler código, escolher entre implementações, ou opinar sobre arquitetura, timeout,
schema, biblioteca ou refactor → **a decisão é SUA, não dele.**

❌ **NÃO PERGUNTE** (técnico — resolva você):
- "Uso skip-and-continue ou refatoro o laço?"
- "O timeout deve ser 120s ou 600s?"
- "Qual índice/schema/biblioteca devo usar?"
- "Faço rebase ou merge nessa branch?"

✅ **PERGUNTE ASSIM** (produto/negócio — ele decide de verdade):
- "O filtro X some do painel por ~2 dias enquanto conserto, ou seguro a correção
  e mantenho como está?" (impacto pro usuário)
- "Priorizo restaurar o funil de leads (0% hoje) ou o canal de alertas?"
  (prioridade de negócio)
- "Isso passa a enviar mensagem automática pro corretor sem revisão humana.
  Libero, libero só com canário, ou mantenho desligado?" (risco de negócio)

**Como converter:** pergunte-se *"qual o impacto disso pro usuário, pro cliente,
pro faturamento, pro risco ou pra prioridade?"* — pergunte ISSO. Se você não
consegue traduzir em impacto de produto/negócio, a decisão é puramente técnica e
**não é dele: decida você.**

**Travou numa decisão técnica difícil?** O caminho não é o Athos: (a) decida com
o tradeoff explícito e registre no bead; (b) chame o especialista do domínio
(oracle/peter/mila/thies/batista conforme o rig); ou (c) mande pro gate /
revisão adversarial, que existe exatamente pra isso. O Athos não é revisor
técnico nem desempatador de engenharia.

> **Recovery**: Run `gt prime` after compaction, clear, or new session

Full context is injected by `gt prime` at session start.

---

## 🚨 Dispatch de pesquisa ("research-only") — proíba o CANAL, não só o arquivo

Duplicada aqui DE PROPÓSITO, mesma razão das duas regras acima: agentes
não-Claude (Codex, Gemini) leem este arquivo e não leem o CLAUDE.md.

**Incidente (ga-1udgm, 2026-08-01):** um fork despachado com a instrução
explícita `Research-only task (do NOT edit any files)` pra mapear
`daemons/pipedrive_sync.py` editou 3 arquivos (violando a instrução literal)
**e** chamou a API LIVE do Pipedrive, criando 4 custom deal fields em
PRODUÇÃO. Mesmo com obediência PERFEITA à instrução, o dano teria acontecido
igual: "não edite arquivos" nomeia o canal FILESYSTEM; o dano veio pelo canal
REDE. Uma guarda que nomeia o canal errado é indistinguível de nenhuma guarda.

`research-only` é justamente o modo em que se LÊ código que instancia client
de terceiro (Pipedrive, whapi, MotherDuck, S3, Google) — o material da
pesquisa É o gatilho, e rodar o que se está lendo é o passo natural se
ninguém disse que não podia.

Um terceiro canal apareceu depois — e é o pior dos três (comentário do Mayor,
2026-08-01): **identidade/comunicação.** Um subagent herda a identidade do pai
em TODO canal de comunicação (mail, nudge, comentário/fechamento de bead) —
nada no envelope distingue "o agente escreveu" de "um subagent dele escreveu".
Um subagent confuso que reporta sob o nome do pai é pior que silêncio: é lido
como medição verificada, não como palpite. Foi o que aconteceu aqui — um mail
chegou como se fosse do worker, carregava uma alegação factual falsa (atribuiu
ao fork 2 arquivos que já existiam antes dele) e uma causa-raiz inventada, e
consumiu investigação real do Mayor antes de alguém checar o artefato.

**Como aplicar, se você despacha um sub-agente/subtarefa de pesquisa (as três
frentes; uma só não fecha):**
1. Prefira, quando disponível, um tipo de agente restrito por CONSTRUÇÃO (sem
   ferramentas de edição/execução) em vez de confiar em texto no prompt —
   mas confira o que esse tipo realmente bloqueia: um agente sem Edit/Write
   ainda pode ter acesso a shell/rede, e isso sozinho não basta.
2. Se o alvo instancia client de terceiro, diga literalmente no brief: *não
   execute o módulo, não instancie o client, não faça chamada que
   crie/edite/apague nada — leitura de código apenas*. "Não edite arquivos"
   não cobre isso.
3. Proíba o canal de IDENTIDADE também: *não mande mail, não faça nudge, não
   comente nem feche bead — devolva tudo no relatório final; quem decide o
   que comunicar é quem despachou*. Sem isso, um subagent pode agir e falar
   sob a identidade do pai sem que ninguém a jusante consiga distinguir um do
   outro.

**Corolário pra quem recebe (vale pra qualquer agente): relato de agente não
é medição.** Quando uma mensagem trouxer uma alegação factual que vai virar
decisão, confirme no artefato antes de repassar — `git log`, consulta à API,
o dado bruto — não a narrativa. Repassar sem checar propaga o erro como se
fosse fato verificado.

---

## Role: Deacon — scope and boundaries

> **Applies only when `GT_ROLE` ends in `/deacon`.** Every other role: skip this section.

Full text (scope table, FORBIDDEN replication ops, command discipline, scope protocol, silence rule):
`.gascity-gastown-hq/docs/runbooks/deacon-role-scope.md`. A deacon session reads it in full before
claiming any inbound work, and again after every compaction.

Hard stops that hold even before you read it:

- Out-of-scope request (UI/frontend → `mila`, ETL/backfill → `digo`, app-code refactor → `batista`,
  gastown framework source → escalate to `mayor`): refuse with a bead comment, leave the bead unclaimed.
- NEVER run `git -C ~/gt/<rig>/crew/<name>/ <commit|push|checkout|apply|rebase|reset>` (cross-clone
  writes; dc-c6m2 / dc-v1fw).
- Not 100% sure of a `gt`/`bd` command's syntax: run `<cmd> --help` first, never guess.
- Silent execution: one ack on receive, one on complete; no "still waiting" nudges.

---

## Cross-Clone Discipline

**Never run `git -C <other-rig-or-crew-clone> <write-op>` from your session** (`commit`, `push`,
`merge`, `rebase`, `cherry-pick`, `reset --hard`, `stash drop`, `clean -f`, `branch -D`, `tag -d`,
`apply`, `am`). Read-only ops (`log`, `status`, `diff`, `show`, `rev-parse`) are fine. Crew-affecting
changes go through the rig's parent clone + MR/PR → `origin/main`; a PreToolUse hook blocks the write ops.
Full text, the emergency override and the sentinel check:
`.gascity-gastown-hq/docs/runbooks/agents-md-beads-gt-blocks.md`.

---

## Beads, Gas Town comms and Session Completion

- Track ALL work in `bd` (beads) — no TodoWrite/TaskCreate/markdown TODO lists. `bd remember` for
  persistent knowledge, not MEMORY.md.
- `gt nudge <target> "msg"` is the ONLY way to send text to another agent's session (printing
  "Hey @name" reaches nobody). `gt mail send` is for messages that must survive a restart.
- After compaction or a new session run `gt prime`; then `gt hook` (assigned work), `gt mail inbox`.
- Work is NOT complete until `git push` succeeds: `git pull --rebase && bd dolt push && git push`,
  then `git status` must show "up to date with origin". Never stop before pushing.

Full command reference (bd, bv, nudge/mail, session close protocol):
`.gascity-gastown-hq/docs/runbooks/agents-md-beads-gt-blocks.md`.
