---
description: Walk the deacon Scope Discipline Protocol checklist on an inbound work item — domain, replication, command, memory
allowed-tools: Bash(bd show*), Bash(bd comment*), Bash(bd update*), Bash(gt mail read*), Bash(gt escalate*), Bash(gt nudge*)
argument-hint: <bead-id-or-mail-id> [reason]
---

# Scope Check (deacon)

Decide whether an inbound work item is yours, refusable, or escalation-worthy
**before** marking it `in_progress` or running any command on it.

This command implements the 4-step Scope Discipline Protocol documented in
`AGENTS.md → Role: Deacon → Scope Discipline Protocol`. Run it on every
slung bead, every mail-with-task, and every hooked molecule whose scope
isn't already obvious.

> **Role gate.** This command is only meaningful when `GT_ROLE` ends in
> `/deacon`. If you are mayor, witness, refinery, polecat, or crew, this
> command does not apply to your scope rules.

Argument: `$ARGUMENTS` — bead ID (`dc-…`, `wa-…`, `gt-…`, `hq-…`) or mail
ID (`*-wisp-*`). Optional second token: free-text reason / source.

## Step 1 — Read the item, do not act on it yet

```bash
# Bead
bd show <id>
# OR mail
gt mail read <id>
```

Capture in your head: title, slinger, body summary, what it asks you to do
or commit to. Do **not** run `bd update --status=in_progress`, do not
run any commands the item describes, do not commit anything.

## Step 2 — Domain check

Compare the ask against deacon's owned domains:

- replication strategy (when/how `origin/main` pushes happen)
- daemon health checks (Dolt status, agent liveness, queue latency)
- hygiene patrols (zombie scan, orphan DB cleanup, session GC, cleanup wisps)
- sentinel infrastructure (gates, molecule dispatch, patrol formulas, dog-pool)

If the ask falls cleanly inside one of these → **accept**, claim the item
normally, run `/patrol` or whatever is appropriate.

If the ask is in any of these REFUSE categories, run:

```bash
bd comment <id> "Out of scope for deacon, sugiro reassign para <agent>."
```

…then leave the item unclaimed. Do not mark `in_progress`.

| Smell | `<agent>` | Examples |
|---|---|---|
| UI / frontend / mockup / dashboard / CSS / HTML | `mila` | toggle mockups, lot-card redesign, dashboard styling |
| ETL / backfill / data pipeline / migration | `digo` | classification backfill, sheet sync, Hex pipeline edits |
| Refactor of application code (non-infra) | `batista` | restructuring `daemons/`, splitting `lib/`, renaming public APIs |
| `bd` 1.0.x source / gastown framework | escalate to `mayor` | anything under `cmd/`, `internal/`, `pkg/` |

If the ask **mixes scope** (e.g. infra fix + UI tweak): comment that you
will accept only the infra half and the rest needs reassignment. Then
proceed only on the infra portion.

If you are **unsure**: do NOT guess. Run

```bash
bd comment <id> "deacon scope check: <specific question to slinger/mayor>"
```

…and wait for clarification before claiming.

## Step 3 — Replication check

If completing the item would require any of these on a crew clone, STOP:

```bash
git -C ~/gt/<rig>/crew/<name>/ commit  …
git -C ~/gt/<rig>/crew/<name>/ push    …
git -C ~/gt/<rig>/crew/<name>/ checkout …
git -C ~/gt/<rig>/crew/<name>/ apply   …
git -C ~/gt/<rig>/crew/<name>/ rebase  …
git -C ~/gt/<rig>/crew/<name>/ reset   …
```

Replication is dc-x2qs's job (origin/main push + crew pull), not deacon's
runtime LLM choice. If dc-x2qs cannot serve and there is a real need:

```bash
gt escalate -s HIGH "Cross-clone write needed for <id>; dc-x2qs path insufficient because: <reason>"
```

Do not improvise a one-off cross-clone op. See dc-c6m2 / dc-v1fw for the
incidents this rule was written against.

## Step 4 — Command check

If the item's resolution involves any `gt`/`bd` command you have not run
recently and verbatim, **run `<cmd> --help` first** — do not guess command
names from intent.

Spot-check against the known confusions:

| Intent | Wrong (do not guess) | Correct |
|---|---|---|
| Read a piece of mail | `gt escalate read <id>` | `gt mail read <id>` |
| Send mail | `gt escalate send …` | `gt mail send <target> -s "…" -m "…"` |
| Create an escalation bead | `gt mail escalate …` | `gt escalate -s HIGH "…"` |
| Wake another agent | `gt mail wake …` | `gt nudge <target> "…"` |
| List your mail | `gt inbox` | `gt mail inbox` |

If a command produces "command not found" followed by an unintended bead
being created (the dc-rfmo failure mode), **STOP**, do not fire more
commands, run `gt --help` and re-plan.

## Step 5 — Memory check

If this scope check turned up a fact about deacon's scope that future
sessions should know (a new agent role, a new edge case, a new "this kind
of bead always gets refused" pattern), record it before continuing:

```bash
bd remember "<short fact for future deacon sessions>"
```

Do **not** rely on in-session todos / TodoWrite — those die at the next
compaction. AGENTS.md is the canonical store; `bd remember` is the
delta-store.

## Step 6 — Decision

After steps 1–5, your state on this item should be exactly one of:

- **Accept** — domain check passed, replication check passed, commands
  understood, memory recorded if applicable. Mark `in_progress`, proceed.
- **Refuse + reassign** — domain check failed. Comment posted. Bead left
  unclaimed.
- **Wait for clarification** — domain check ambiguous. Comment posted with
  a specific question. Bead left unclaimed. Do not poll; you'll see the
  reply on next inbox cycle.
- **Escalate** — replication check failed and dc-x2qs path is insufficient.
  `gt escalate` posted to mayor. Bead left unclaimed.

If you find yourself in a fifth state ("uncertain but starting anyway"),
you skipped a step. Go back to Step 2.

## Notes

- This command does not touch any state by itself; the actions in steps 2,
  3, and 5 are the ones that mutate. Reading the item in step 1 is
  side-effect-free.
- The protocol is intentionally rigid. Scope drift on dc-2yqq, dc-bhlt,
  dc-mbqn happened because earlier deacon sessions were in "uncertain but
  starting anyway" state. The point of the checklist is to make that
  state impossible.
- After the rules in `AGENTS.md` are loaded by `gt prime`, this command is
  the operationalization. Edits to AGENTS.md and edits to this file
  should stay in sync.
