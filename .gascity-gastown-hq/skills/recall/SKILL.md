---
name: recall
description: Use BEFORE bulk `bd list --status closed` + reading several full bead bodies to answer "has this been done before?" / "what broke last time with X?" / "was this bug already fixed?". Runs the `recall` CLI, a hybrid semantic+lexical search over CLOSED beads (HQ+WA, telemetry-filtered) that returns the ~5 most relevant beads (id, title, close_reason, top comments) for a fraction of the tokens of a manual bd-list scan. Applies to ALL Gas City agents.
---

# recall — historical-work lookup over closed beads

Before doing a manual `bd list --status closed` + reading several full `bd
show` bodies to check "has this been done? / what broke last time?", run:

```bash
recall "has the gate two-branch race for the same bead been fixed?"
recall "what broke last time with tick_unconfirmed duplicate sends?"
```

It prints the ~5 most relevant CLOSED beads: id, title, close_reason, and
the 1-2 most relevant comments. Hybrid retrieval (local `all-MiniLM-L6-v2`
embeddings, no external API) — measured 5.9x fewer tokens than bd-list+read
at recall@5=0.95 (ga-ps28g). Self-maintaining index; the first call after a
long gap may take longer while it refreshes.

Scope: CLOSED beads only, HQ + WA, last 90 days, telemetry-filtered
(gate/nudge/order/session/molecule markers excluded). If you already know
the exact bead ID, just `bd show <id>` — don't `recall` for that. If the
work you're checking might still be OPEN/in-progress, `recall` won't see
it — use `bd list`/`bv` instead.

Implementation: `.gascity-gastown-hq/scripts/recall_lib.py` +
`recall.py`. Usage is logged to `.gc/logs/recall-usage.jsonl` for
token-savings measurement over time.
