---
name: refino
description: >
  This skill should be used when Athos says something like "vamos refinar a
  história", "refinar esse item", "refine this story", "quero refinar",
  "vamos refinar juntos", or otherwise signals the start of a product
  refinement session on a feature story. Guides the agent through an
  interactive, rigid 8-field Definition of Refined — mandatory fields, no
  skipping, Athos approval gate. Ends by writing/updating the story as a bead.
version: "1.0.0"
---

# Refino — Product Story Refinement Protocol

Refino is a RIGID interactive protocol that a crew agent wears to refine a
feature story WITH Athos. It does NOT end until all 8 mandatory fields are
filled AND Athos explicitly approves. No field may be skipped or left vague
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
Nenhum campo pode ser pulado — só finalizamos quando os 8 campos
estiverem preenchidos E você aprovar explicitamente.
```

If Athos provides a story title or bead ID at invocation, load it. Otherwise
open with: "Qual história vamos refinar hoje? (título ou ID do bead)"

---

## The 8 Mandatory Fields (Definition of Refined)

Work through the fields in order. After each answer, reflect it back
concisely, ask "Está correto assim?" and only advance when Athos confirms.
If an answer is vague, ask a follow-up rather than accepting it.

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

After all 8 fields are filled, present the complete summary:

```
--- HISTÓRIA REFINADA ---

1. Resumo: [...]
2. O que é + por que importa: [...]
3. Estrela-guia: [...]
4. Equilíbrios: [...]
5. Dashboard pós-entrega: [...]
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

Announce completion:

```
História aprovada e salva como bead [ID].
Label: story:approved | Prioridade: [P]
Pronta para entrar no backlog e ser despachada.
```

---

## Guard Rails

- **Never self-approve.** The agent cannot approve a story on behalf of Athos.
- **Never skip a field.** If Athos tries to skip ("isso não importa"), say:
  "Entendo, mas esse campo é obrigatório no nosso protocolo. Vamos preencher
  juntos — pode ser curto. [restate the prompt]"
- **Never fill a field on behalf of Athos without asking.** The agent may
  propose a draft, but Athos must confirm.
- **Never close Refino early.** If the session is interrupted, save partial
  progress to the bead as a note (`story:refinement-in-progress` label) and
  tell Athos the session can resume.

---

## Additional Resources

- **`references/story-bead-convention.md`** — exact bead labels, metadata
  keys, and `bd` commands for writing/querying story beads.
