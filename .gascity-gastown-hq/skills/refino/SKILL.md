---
name: refino
description: >
  This skill should be used when Athos says something like "vamos refinar a
  história", "refinar esse item", "refine this story", "quero refinar",
  "vamos refinar juntos", or otherwise signals the start of a product
  refinement session on a feature story. Guides the agent through an
  interactive Definition of Refined in two modes — completo (8 mandatory
  fields) or simplificado (5 essential fields: F1, F2, F6, F7, F8). No
  skipping within the chosen mode, Athos approval gate. Ends by
  writing/updating the story as a bead.
version: "1.1.0"
---

# Refino — Product Story Refinement Protocol

Refino is a RIGID interactive protocol that a crew agent wears to refine a
feature story WITH Athos. It runs in one of two modes — **completo** (all 8
fields) or **simplificado** (the 5 essential fields F1, F2, F6, F7, F8). It
does NOT end until every mandatory field *for the chosen mode* is filled AND
Athos explicitly approves. No mandatory field may be skipped or left vague
based on agent discretion.

Language: conduct the session in Portuguese unless Athos switches to English.
Tone: collaborative product partner — not an engineer. Avoid technical jargon
unless Athos uses it.

---

## Invocation

Athos says something in the family of "vamos refinar a história". The agent
immediately enters Refino mode and announces it:

```
Entrando no modo Refino. Vamos refinar a história juntos.
```

If Athos provides a story title or bead ID at invocation, load it. Otherwise
open with: "Qual história vamos refinar hoje? (título ou ID do bead)"

---

## Claim antes de refinar (anti-overlap — OBRIGATÓRIO)

Workers/crews refinam o MESMO pool `story:unrefined` em paralelo. Os sinais de
status/label LAGAM — uma história pode parecer livre e já estar sendo refinada
por outro (visto em campo: bead some do pool de unrefined em minutos). **Antes de
propor QUALQUER campo**, RESERVE a história atomicamente:

```bash
bd update <id> --set-labels story:refinement-in-progress --assignee "$BEADS_ACTOR"
```

Depois **verifique que o claim pegou e é seu** (`bd show <id>` — se o
assignee/label for de outro ator, OUTRO worker ganhou a corrida: pare e escolha
outra história). Só então comece a propor campos. Na aprovação, a transição
`--set-labels story:approved` substitui o `story:refinement-in-progress`.

**Nunca refine uma história que não esteja claimed por você.** Elimina trabalho
duplicado entre workers/crews.

---

## Mode Selection (completo vs. simplificado)

Before working any field, choose the mode. The mode determines which fields
are mandatory and how each field is presented.

**Ask once, right after the story is identified:**
> "Refino completo (8 campos) ou simplificado (essenciais: F1, F2, F6, F7,
> F8)? No simplificado eu já proponho um rascunho de cada campo e você
> confirma ou ajusta."

**Shortcut — skip the question and enter simplificado directly when** Athos's
invocation already signals it: he says "Refino Simplificado", "modo
simplificado", or passes `simplificado` as an argument. In that case do not
ask; announce the simplified mode and proceed.

**After the mode is known, announce it explicitly so expectations are set:**

- Completo:
  ```
  Modo completo. Nenhum campo pode ser pulado — só finalizamos quando os 8
  campos estiverem preenchidos E você aprovar explicitamente.
  ```
- Simplificado:
  ```
  Modo simplificado. Vamos preencher os 5 campos essenciais (Resumo, O que é,
  Critérios, Dependências/fora-de-escopo, e a checagem história/épico).
  Estrela-guia, equilíbrios e dashboard ficam de fora e são marcados como
  pulados. Para cada campo eu proponho um rascunho e você confirma ou ajusta.
  Só finalizamos quando os 5 campos estiverem preenchidos E você aprovar.
  ```

**Field sets:**

| Mode | Mandatory fields | Skipped |
|------|------------------|---------|
| Completo | F1, F2, F3, F4, F5, F6, F7, F8 | none |
| Simplificado | F1, F2, F6, F7, F8 | F3, F4, F5 |

In **simplificado**, for each mandatory field the agent FIRST proposes a draft
(derived from the bead title/description and known context), then asks Athos to
confirm or adjust. The draft is a starting point, not a decision: **per-field
confirmation remains mandatory** and no field advances without Athos's explicit
"ok"/"sim"/"isso". The skipped fields (F3, F4, F5) are never asked; they are
recorded with the skip sentinel at write-back (see Bead Write-back).

---

## The Fields (Definition of Refined)

Work through the fields in order, running only the fields mandatory for the
chosen mode (see Mode Selection). In **completo** all 8 run; in **simplificado**
F3, F4 and F5 are skipped. After each answer, reflect it back concisely, ask
"Está correto assim?" and only advance when Athos confirms. If an answer is
vague, ask a follow-up rather than accepting it.

### Field 1 — Resumo em 1 frase

**Prompt to Athos:**
> "Me dá o titular da história em uma frase. Deve ser claro o suficiente
> para qualquer pessoa da equipe entender o que é sem mais contexto."

**Acceptance criterion for this field:**
- Single sentence, ≤ 15 words.
- No "sistema deve" or passive constructions. Action-oriented.
- Example: "Buscar imóveis por nome retorna resultados em menos de 2 segundos."

**If too long or vague:** propose a shorter version and ask for confirmation.

---

### Field 2 — O que é + por que importa

**Prompt to Athos:**
> "Descreve o que essa história faz e por que ela importa em termos de
> produto. Pensa no usuário final: qual é o problema que estamos resolvendo
> e qual o valor gerado?"

**Acceptance criterion:**
- Two parts present: (1) what it does, (2) why it matters for the product/user.
- Written in product language, not engineering language.
- Example: "Permite que corretores encontrem imóveis por nome sem precisar
  navegar manualmente. Reduz o tempo de atendimento e melhora a experiência
  em campo."

---

### Field 3 — Estrela-guia (north-star metric)

*(Pulado no modo simplificado — registrado com a sentinela de skip no write-back.)*

**Prompt to Athos:**
> "Qual é a métrica estrela-guia dessa história — como vamos saber que
> valeu a pena entregar? Um número ou comportamento mensurável que, se
> atingido, confirma o sucesso."

**Acceptance criterion:**
- Single, measurable metric or observable outcome.
- Must be falsifiable (can be measured after ship).
- Examples: "A busca retorna em menos de 2s na maioria dos casos", "Taxa de
  conversão da busca aumenta 15%", "Zero reclamações de lentidão no período
  pós-entrega".

**If vague ("melhorar performance"):** push for a number or threshold.

---

### Field 4 — Equilíbrios (balancing metrics)

*(Pulado no modo simplificado — registrado com a sentinela de skip no write-back.)*

**Prompt to Athos:**
> "O que NÃO pode piorar quando entregarmos isso? Quais métricas ou
> comportamentos existentes precisam se manter estáveis?"

**Acceptance criterion:**
- At least one balancing metric stated.
- Framed as "must not degrade" (e.g., "Latência das outras buscas não
  pode aumentar", "Taxa de erro da API deve permanecer < 0.5%").
- If Athos says "nada", challenge: "Tem certeza? Pensa em performance,
  disponibilidade, experiência de outras features..."

---

### Field 5 — O que o dashboard observa depois de entregue

*(Pulado no modo simplificado — registrado com a sentinela de skip no write-back.)*

**Prompt to Athos:**
> "Depois que essa história estiver em produção, o que vamos monitorar
> no dashboard ou nos logs para saber que está saudável? Quais sinais
> operacionais devemos acompanhar?"

**Acceptance criterion:**
- At least two operational signals named.
- Examples: "Taxa de erro da busca por nome", "Tempo de resposta da busca
  na maioria dos casos", "Volume de buscas por nome vs total de buscas",
  "Alertas de lentidão ou falha no banco".

---

### Field 6 — Critério de aceitação

**Prompt to Athos:**
> "Lista os critérios de aceitação concretos e verificáveis — o que
> precisa ser VERDADEIRO para a história estar pronta e funcionando.
> Escreve como RESULTADO (o que deve acontecer), não como implementação
> (como fazer). Ex: 'buscar por nome retorna lista em < 2s' — não 'usar
> índice no banco'."

**Acceptance criterion:**
- At least 2 criteria.
- Each criterion: observable result, verifiable by a human tester.
- No "deveria", "deve usar X tecnologia", or implementation details.
- Each criterion passes the "can someone check this without source code?" test.

**Enforce result-framing:** if Athos writes implementation steps, say:
"Esse é um 'como' — vamos reformular como resultado. O que o usuário ou
sistema vai observar quando isso estiver certo?"

---

### Field 7 — Dependências + fora-de-escopo

**Prompt to Athos:**
> "Duas partes aqui:
> 1. **Dependências**: O que essa história precisa que ainda não existe,
>    ou o que ela depende de outro time/sistema?
> 2. **Fora de escopo**: O que explicitamente NÃO faz parte dessa história
>    (para evitar scope creep)?"

**Acceptance criterion:**
- Both parts present. Can be "nenhuma dependência externa" for part 1 if
  genuinely none.
- Fora de escopo must have at least one explicit exclusion — this prevents
  scope creep. If Athos skips it, ask: "O que alguém razoavelmente poderia
  achar que está incluído, mas não está?"

---

### Field 8 — Checagem "é história ou épico?"

**Prompt to Athos:**
> "Essa história cabe em um ciclo de entrega — pode ser desenvolvida e
> entregue como uma unidade de trabalho? Ou é grande demais e precisa ser
> dividida em histórias menores?"

**Size heuristics to share with Athos if needed:**
- A story should be deliverable independently in ~1 sprint (1-2 weeks).
- If the acceptance criteria list has 6+ items spanning multiple flows:
  likely an epic.
- If there are 3+ dependencies between components: likely needs splitting.

**If it's a story:** proceed to approval gate.

**If it's an epic:** initiate the split protocol below.

The size check — and the split protocol — run in **both** modes. F8 is
mandatory in simplificado too, so a simplified story that turns out to be an
epic still splits.

### Split Protocol (when story is too big)

```
Essa história parece grande demais para uma única entrega.
Vamos quebrá-la em histórias menores.

Proposta de split:
  1. [título da história menor 1] — [razão]
  2. [título da história menor 2] — [razão]
  ...

Cada uma dessas pode ser refinada separadamente depois.
Quer ajustar essa divisão antes de continuar?
```

After Athos confirms the split, document it as the `notes` of the bead and
change the bead type to `epic`. Create child bead stubs for each sub-story
(title only, `story:unrefined` label) using `--no-inherit-labels` so each
child carries ONLY `story:unrefined` and does not silently inherit
`story:epic-split` from the parent. Do NOT run full Refino on each sub-story
in this session — offer to refine each one in a separate session.
Then close this Refino session.

---

## Approval Gate

After all mandatory fields are filled, present the complete summary. In
**simplificado**, lines 3–5 show the skip sentinel `— pulado no refino
simplificado` instead of content:

```
--- HISTÓRIA REFINADA ---

1. Resumo: [...]
2. O que é + por que importa: [...]
3. Estrela-guia: [... | — pulado no refino simplificado]
4. Equilíbrios: [... | — pulado no refino simplificado]
5. Dashboard pós-entrega: [... | — pulado no refino simplificado]
6. Critérios de aceitação:
   - [...]
   - [...]
7. Dependências: [...] | Fora de escopo: [...]
8. Checagem épico/história: [história — tamanho ok]

Você aprova essa história como está? (sim / não / ajustar campo X)
```

**The story is ONLY approved when Athos explicitly says "sim", "aprovado",
"ok", "aprovo" or equivalent.** A non-committal response ("parece bom",
"acho que sim") does NOT count. Ask again: "Confirma a aprovação?"

**If Athos says "ajustar campo X":** go back to that field, re-run it,
re-present the full summary. Loop until explicit approval.

**After explicit approval, ask ONE priority question before writing the bead:**

```
Qual a prioridade — Normal / Alta / Baixa?
```

Map the answer to `--priority` (Alta→1, Normal→2, Baixa→3). If unclear,
default to Normal (P2). See `references/story-bead-convention.md` for the
full priority table.

---

## Bead Write-back (on approval)

On approval (after the priority question), create or update the story bead
using the Story Bead Convention. See `references/story-bead-convention.md`
for the exact commands and field mapping.

The write-back MUST use `bd -C "$GC_CITY_PATH"` on every command. The
lifecycle label transition MUST use `--set-labels story:approved` (atomic,
works from any source lifecycle state — `story:unrefined`,
`story:refinement-in-progress`, or new bead).

**Mode marker + skipped fields.** On write-back, record the mode via the
`story.refino_mode` metadata key:

- **Simplificado:** set `--set-metadata "story.refino_mode=simplificado"`, and
  write the three skipped fields with the skip sentinel instead of leaving them
  null — `--set-metadata "story.estrela_guia=— pulado no refino simplificado"`
  (idem `story.equilibrios` and `story.dashboard`). The sentinel keeps the cut
  fields visible-but-marked, so the Pilot/Kanban can tell "skipped" from
  "forgotten".
- **Completo:** do **not** set `story.refino_mode`. Absence of the key means
  completo (the legacy default — existing beads have no key and are completo).
  Full mode's write-back is otherwise unchanged.

See `references/story-bead-convention.md` for the full key table and the
treat-as-absent semantics of the skip sentinel.

Announce completion:

```
História aprovada e salva como bead [ID].
Label: story:approved | Prioridade: [P]
Pronta para entrar no backlog e ser despachada.
```

---

## Guard Rails

- **Never self-approve.** The agent cannot approve a story on behalf of Athos.
- **Never skip a mandatory field.** The only cuttable fields are F3, F4 and F5,
  and only in **simplificado** (where they are recorded with the skip sentinel,
  not silently dropped). Every other field is mandatory in both modes. If Athos
  tries to skip a mandatory field ("isso não importa"), say: "Entendo, mas esse
  campo é obrigatório no nosso protocolo. Vamos preencher juntos — pode ser
  curto. [restate the prompt]"
- **Never fill a field on behalf of Athos without asking.** The agent may
  propose a draft, but Athos must confirm. In **simplificado** the draft is the
  default presentation, but it does NOT replace consent: each mandatory field
  still requires an explicit confirm/adjust before advancing, and the final
  approval gate is unchanged.
- **Never close Refino early.** If the session is interrupted, save partial
  progress to the bead as a note (`story:refinement-in-progress` label) and
  tell Athos the session can resume.

---

## Additional Resources

- **`references/story-bead-convention.md`** — exact bead labels, metadata
  keys, and `bd` commands for writing/querying story beads.
