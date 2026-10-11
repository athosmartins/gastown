# Dolt Server — Operational Awareness (All Agents)

## Contents

- Overview (port, fragility)
- If you detect Dolt trouble
- If you see test pollution
- Key commands
- Manual bead reclaim — never raw `bd reclaim`
- Communication hygiene

Moved verbatim from `/Users/athos/gt/CLAUDE.md` on 2026-10-11 (rule: CLAUDE.md ≤ 200 lines).
The CLAUDE.md keeps a short summary that points here.

## Overview (port, fragility)


Dolt is the data plane for beads (issues, mail, identity, work history). It runs
as a single server on **port 52756** serving all databases. **It is fragile.**

> ⚠️ **The port is 52756, NOT 3307** — and two sources will tell you 3307: this file
> used to, and `~/gt/dolt-server.port` still does. Both are stale; 3307 refuses
> connections. Verified 2026-07-17: `lsof -nP -p $(pgrep -f 'dolt sql-server') | grep LISTEN`
> shows exactly one listener, `*:52756`. Tools that take an explicit port (e.g.
> `gt reaper scan|reap|purge --port=52756`) fail with "connection refused" on 3307 —
> and a diagnostic that merely returns *empty* on the wrong port is worse, because
> it reads as "nothing is wrong". **Always derive the port from the live process,
> never from a file or from memory** — but not via a bare `pgrep -f 'dolt sql-server'
> | head -1`: sort order picks whichever matching process happens to come first,
> which is NOT always the real server (ga-0bjqix — a witness scan hit this for real
> on 2026-09-15, picking a 1s-old idle process instead of the live one). Use
> `source $CITY/scripts/dolt-pid-lib.sh; dolt_server_pid` — it verifies executable
> basename `dolt` AND a live LISTEN socket before trusting a candidate, never sort
> order alone.

### If you detect Dolt trouble

Symptoms: `bd` commands hang/timeout, "connection refused", "database not found",
query latency > 5s, unexpected empty results.

**BEFORE restarting Dolt, collect diagnostics.** Dolt hangs are hard to
reproduce. A blind restart destroys the evidence. Always:

```bash
# 1. Capture live process state WITHOUT touching the process.
#    🚨 NEVER `kill -QUIT` the Dolt PID — verified DANGEROUS 2026-08-04
#    (bug filed: search HQ for "kill -QUIT" incident). This step used to send
#    SIGQUIT with the comment "safe — does not kill the process". It does
#    not hold: sent to a live, fully-reachable dolt sql-server (confirmed via
#    `gc dolt health --json` immediately beforehand — reachable=true,
#    ~5% CPU, no sign of a hang), the process vanished on the spot
#    (`ps -p $DOLT_PID` returned nothing, `lsof -p $DOLT_PID` showed zero
#    listeners) and only a supervisor auto-respawn (~30s later, new PID)
#    brought the city's Dolt back — a real if brief citywide outage. Go's
#    default SIGQUIT handling is dump-then-terminate unless the program
#    installs its own handler; Dolt does not. Derive the PID from the LIVE
#    process via the canonical helper — never a bare `pgrep | head -1`: sort
#    order can pick a decoy, not the real server (ga-0bjqix, hit for real
#    2026-09-15 — a witness scan grabbed a 1s-old idle process this way).
#    "There is no dolt.pid file" — this line's own claim until 2026-09-15 —
#    is STALE: `.gc/runtime/packs/dolt/dolt.pid` exists and matches the live
#    server (verified 2026-09-15, ga-0bjqix). The helper below checks it AND
#    a live LISTEN socket before trusting either source. Capture state via
#    SQL instead of a signal — it never touches the live process:
source /Users/athos/gt/.gascity-gastown-hq/scripts/dolt-pid-lib.sh
DOLT_PID=$(dolt_server_pid)
[ -n "$DOLT_PID" ] || { echo "FATAL: no live dolt sql-server — do NOT proceed as if step 1 ran"; }
timeout 5 gc dolt sql -q "SHOW FULL PROCESSLIST"   # non-fatal; verified working 2026-08-04

# 2. Capture server status while it's still (mis)behaving
#    ✅ `gc dolt status` WAS BROKEN (ga-dzado, found 2026-08-07) but is FIXED
#    as of the 2026-08-13 engine window (live binary gc-1.1.1-engwin0813).
#    Old behavior: exit 0 printing ZERO BYTES regardless of whether the
#    server was running, down, or unreachable — "healthy" and "the check
#    did nothing" were indistinguishable. Now it ALWAYS prints a state line
#    with a distinct exit code: "running" (exit 0), "not running" (exit 1,
#    confirmed down), or "UNKNOWN (...)" (exit 2, genuinely indeterminate —
#    treat as unhealthy but don't conflate with a confirmed-down result).
#    Verified 2026-08-13 by direct execution of the actual deployed script
#    (not just the "running" case — all 3 states, plus the gc-beads-bd.sh
#    missing/not-found path) — this is a from-scratch behavioral check, not
#    a trust of the engine-window report. See ga-dzado for the test
#    harness (mirrors examples/dolt/status_test.go, no live Dolt touched).
#    If a LATER binary ever regresses back to silent/exit-0, that's a new
#    bug, not this one reappearing — file fresh, don't reopen this note.
#    Still capture the raw process/port facts too, as independent corroborating
#    evidence — this is one signal, not the whole picture.
gc dolt status 2>&1 | tee /tmp/dolt-hang-$(date +%s).log
ps -o pid,pcpu,pmem,etime -p "$DOLT_PID" | tee -a /tmp/dolt-hang-*.log
lsof -nP -p "$DOLT_PID" | grep LISTEN | tee -a /tmp/dolt-hang-*.log

# 3. THEN escalate with the evidence
gc mail send mayor -s "Dolt: <describe symptom>" -m "<paste evidence>"
```

**Do NOT just `gc dolt stop && gc dolt start` without steps 1-2.**

**Escalation path** (any agent can do this):
```bash
gc mail send mayor -s "Dolt: <describe symptom>" -m "<evidence>"  # Most failures
gc mail send mayor -s "Dolt: server unreachable" -m "<evidence>"  # Total outage
```

The Mayor receives all escalations.

### If you see test pollution

Orphan databases (testdb_*, beads_t*, beads_pt*, doctest_*) accumulate on the
production server and degrade performance. This is a recurring problem.

```bash
gc dolt health               # Server health + orphan count
gc dolt-cleanup             # Remove orphan databases (HYPHEN — the safe Go path; prefix-gated)
```

> 🚨 **`gc dolt health`'s orphan count has a KNOWN false-positive, and it points at the most
> destructive command in the city — read this before acting on it.** (ga-eu2x, 2026-07-17.)
> The health probe bounds `gc rig list` at 5s, but that call currently takes **8–17s** (Dolt
> load), so it times out, the fallback rig-scan finds nothing (external rigs aren't under
> `$GC_CITY_PATH/rigs`), and **every production database except `hq` — `whatsapp_automation`
> (788MB), `gastown`, `dc`, `lexbh`, `marketing`, `property_scrapers` — is reported as an
> "orphan".** The data is fine; the *report* is lying, and it's the ga-p5q3 class (a timed-out
> query read as "not referenced" read as "orphan").
>
> - **Never act on the orphan count alone.** A production DB in that list is the tell that the
>   probe degraded, not that anything is orphaned. Verify against the live rigs first:
>   `gc rig list --json | jq -r '.rigs[].path'` (let it take its time — no bound).
> - **`gc dolt-cleanup` (HYPHEN) is the safe one** — the Go binary, prefix-gated (only
>   `testdb_*`, `beads_t*`, etc.), dry-run by default, cannot drop production even with
>   `--force`. **`gc dolt cleanup` (SPACE) is a different, shell command that `DROP DATABASE`s
>   what it judges orphan** — it has guards (allowlist fails-closed if rig list errors) but no
>   production-name protection, so a degraded-but-non-erroring rig list could let it drop a
>   real DB. Prefer the hyphen. If you ever mean to run the space form with `--force`, don't —
>   escalate to the Mayor instead.

**NEVER `rm -rf` a Dolt data directory. NEVER remove, delete, or modify anything inside a
`.dolt/` directory — including `noms/LOCK`.** These are Dolt-internal files. Removing them
WILL cause unrecoverable data corruption and data loss. Dolt manages them itself; external
interference is never safe.

> 🚨 **This rule used to name the WRONG directory, and the correction matters more than the
> rule's wording.** It said only `~/.dolt-data/`. Verified 2026-07-17: **every production
> database — `hq`, `gastown`, `whatsapp_automation`, `property_scrapers`, `lexbh`,
> `marketing`, `dc` — lives in `~/gt/.gascity-gastown-hq/.beads/dolt/`**, and the live server
> holds **205 open files there and zero in `~/.dolt-data/`** (which only has `github_sheriff`
> and `session_hygiene`). So an agent could have destroyed every bead in the city without
> ever violating the letter of the old rule. A safety rule that names the wrong target is
> indistinguishable from no rule — "I followed it" and "I protected the data" were different
> facts.
>
> **Never trust a path written in a doc — including this one. Derive it from the live
> server**, which is the only thing that cannot be stale (and never via a bare
> `pgrep | head -1` either — same sort-order trap as everywhere else in this file;
> ga-0bjqix):
> ```bash
> source /Users/athos/gt/.gascity-gastown-hq/scripts/dolt-pid-lib.sh
> DOLT_PID=$(dolt_server_pid)
> ps -o command= -p "$DOLT_PID"                  # → --config <path>/dolt-config.yaml
> grep -E '^\s*(port|data_dir):' <that config>   # → the REAL port + data_dir, per town
> ```
> Both are **per-town**, materialized into gitignored `.gc/runtime/packs/dolt/dolt-config.yaml`.
> That is why no number and no path belongs in this file: the town moves, the doc doesn't.

### Key commands
```bash
gc dolt status               # Check if the Dolt server is running (fast, no diagnostics)
gc dolt health               # Server health, latency, orphan count
gc dolt start / stop        # Manage server lifecycle
gc dolt-cleanup             # Remove orphan test databases
```

### Manual bead reclaim — never raw `bd reclaim`

`bd reclaim` is generic beads-CLI lease-reaping: it clears assignee/status on
a stale-lease issue but has no notion of Gas Town's own Pilot claim markers
(`pilot:dispatched` / `pilot:dispatching` labels, `pilot.dispatched_at`
metadata). A bead reclaimed via raw `bd reclaim` keeps those markers, and
every Pilot Tier1/Tier2 candidate-scan query unconditionally excludes
anything still wearing `pilot:dispatched` — so the bead goes **permanently
invisible to re-dispatch** even though it's back to `status=open`+unassigned
(confirmed live on wa-2txhl, 2026-08-22: stuck 1h44min before a human
noticed; root-caused in `gt-1kkgu`).

`inflight-reclaim-guard.py`'s own automated reclaim already strips these
correctly — this gap is specific to a human/agent doing an **ad-hoc manual**
reclaim (e.g. forcing an early release instead of waiting on the guard's
TTL). Use the wrapper instead of raw `bd reclaim`:

```bash
packs/town-deltas/assets/pilot-manual-reclaim.sh <bead-id> [rig-path]
```

It only strips the Pilot claim markers when the reclaim actually flipped the
bead to `status=open` — if the lease hadn't expired yet, nothing is touched,
so a still-legitimately in-flight bead is never exposed to re-dispatch.

### Communication hygiene

Every `gc mail send` creates a permanent bead + Dolt commit. Every `gc nudge`
creates nothing. **Default to nudge for routine agent-to-agent communication.**

Only use mail when the message MUST survive the recipient's session death
(handoffs, structured protocol messages, escalations). See `mail-protocol.md`.
