# Polecat Lifecycle and Patrol Coordination: Field Report

> **Wasteland:** w-gt-004
> **Date:** 2026-03-07
> **Author:** furiosa (gastown polecat), synthesizing field experience
> **Status:** Production reference — incorporates incidents from hundreds of patrol cycles
> **Supersedes:** `polecat-lifecycle-patrol.md` (2026-02-20) — adds field evidence
> **Audience:** Gas City architects, Wasteland contributors, next-gen system designers

---

## Executive Summary

This document captures what actually happened when Gas Town ran polecats at scale —
the failure modes that weren't predicted, the mitigations that worked, and the
design lessons for next-generation multi-agent systems.

Gas Town has operated hundreds of continuous patrol cycles, spawned and recovered
dozens of zombie polecats, survived a Dolt DoS, cleaned up 3,100 orphaned wisps,
and debugged spawn failures, TCP crashes, and URL lookup bugs that prevented polecats
from submitting work. Every incident is a data point. This document turns that data
into design.

**Key findings:**
1. The GUPP principle works, but hook delivery is fragile — mechanical failure points
   cluster around spawn time
2. Patrol agents eating their own Dolt budget is the #1 availability threat
3. Orphan accumulation is a slow-motion crisis that accelerates until it becomes acute
4. The self-cleaning model is correct, but `gt done` needs fork-awareness
5. Parallel queries during patrol are a DoS vector, not just a performance concern

---

## 1. The Lifecycle in Theory

### 1.1 The Model

A polecat is a stateless ephemeral worker. It:

```
Spawn ──▶ Hook ──▶ Work ──▶ gt done ──▶ Nuke
```

- **Spawn:** Witness creates tmux session in isolated git worktree
- **Hook:** Molecule assigned via `hook_bead` on agent bead; GUPP fires
- **Work:** Polecat executes molecule steps, making atomic commits
- **`gt done`:** Pushes branch, creates MR bead, signals witness, exits
- **Nuke:** Witness removes sandbox after successful merge (worktree + session deleted).
  Note: in the persistent polecat model, the sandbox survives `gt done` and is reused
  for the next work assignment — the diagram above describes the ephemeral model.

**What persists across sessions:**
- Git state (branch, commits, staged changes)
- Beads state (molecule progress, which steps are closed)
- Hook state (`hook_bead` on agent bead)

**What does NOT persist:**
- Claude context window
- In-progress analysis not committed to git or persisted to bead notes
- Any local variable or shell state

### 1.2 The Guarantee

As long as three conditions hold, a molecule WILL eventually complete:

1. Work is pinned (`hook_bead` set on agent bead)
2. Sandbox persists (branch + worktree exist)
3. Someone keeps spawning sessions (witness respawn on crash)

This is the GUPP completion guarantee. In theory, it is self-healing.
In practice, all three conditions break in interesting ways.

---

## 2. The Lifecycle in Practice: Spawn Failures

### 2.1 NODE_OPTIONS Inheritance Bug

**Incident (2026-02-04):** Polecats died immediately on spawn with "Debugger attached" error.

**Root cause:** `exec env` in `BuildStartupCommand` inherits the parent environment.
When the parent shell had `NODE_OPTIONS=--inspect` (set by VSCode for debugging),
this flag was passed through to the Claude CLI, causing it to wait for a debugger
connection that never came.

**Why it went undetected in testing:** Local development environments typically
don't have `NODE_OPTIONS` set. The bug only manifested in production tmux sessions
started from a VSCode terminal.

**Fix:**
```go
// internal/config/loader.go:1379
// Explicitly clear NODE_OPTIONS to prevent debugger flags from breaking agents
resolvedEnv["NODE_OPTIONS"] = ""
```

**Lesson for Gas City:** All spawned processes must explicitly sanitize their
inherited environment. Don't rely on "the parent environment is clean." It won't be.
Enumerate the env vars you need and set them explicitly; clear everything else.

### 2.2 git push Fork URL Bug

**Incident (2026-03-03, recurring):** Polecats working on `athosmartins/gastown`
(a fork of the main repo) failed `gt done` every time.

**Root cause:** `gt done` verifies the push URL against `steveyegge/gastown` (the
upstream). When the polecat's worktree is on a fork (`athosmartins/gastown`),
the fork URL check fails even though the push succeeded.

**Symptoms:** The polecat pushed successfully (visible via `git log`), created an
MR, then failed with a verification error. The work was actually done; the signal
system didn't know it.

**Workaround:** Create PR manually:
```bash
cd /Users/athos/go/src/gastown
git fetch fork
gh pr create --title "<title>" --base main \
  --head "athosmartins:<branch-name>" --body "<body>"
```

**Lesson for Gas City:** The submission pipeline must be fork-aware. Any URL
verification that assumes "origin == upstream" will fail in fork-based workflows.
The correct check is: "does a PR exist for this branch targeting the expected base?"
not "does the remote URL match?"

### 2.3 Spawn Failures from Missing Metadata

**Incident (2026-03-03):** Polecats spawning into the `gastown` rig failed Dolt
health checks after 8+ retries.

**Root cause:** The rig's `local_repo` path (`/Users/athos/go/src/gastown`) was
missing `dolt_server_port` in `.beads/metadata.json`. The spawn process ran from
this directory, couldn't connect to Dolt, and looped.

**Fix:** Ensure `local_repo/.beads/metadata.json` has explicit connection config:
```json
{
  "backend": "dolt",
  "database": "dolt",
  "dolt_database": "gastown",
  "dolt_mode": "server",
  "dolt_server_port": 3307
}
```

**Lesson for Gas City:** The spawn process must validate its runtime environment
before handing off to the agent. A polecat that can't read its own bead state
on startup is broken from frame one. Add an environment health check as the
first step of every spawn sequence.

---

## 3. Patrol Coordination: What We Learned

### 3.1 The Four Patrol Agents and Their Roles

| Agent | Role | Cycle interval | Weakness |
|-------|------|---------------|----------|
| **Daemon** | Session liveness, GUPP violations | 3-minute heartbeat | Low intelligence — can't distinguish "thinking" from "hung" |
| **Deacon** | Town-wide coordination, cross-rig | Per daemon tick | Risk of generating too many orphan wisps |
| **Witness** | Per-rig polecat health | Continuous | Competing parallel queries → Dolt DoS |
| **Refinery** | Merge queue processing | On demand | Serialized by merge slot — one slow merge blocks all |

### 3.2 The Dolt DoS Pattern

**Incident (2026-03-03, recurring):** Dolt CPU spiked to 180-300%, CLOSE_WAIT TCP
connections accumulated on port 3307, all `bd` operations timed out, Dolt crashed.

**Root cause:** `gt patrol report` scanned ALL open wisps globally and fired
**parallel** `bd list` queries — one per wisp type, all at once. With 2,800+
open wisps in HQ, this was hundreds of simultaneous SQL queries.

**Dolt's connection handling:** Dolt (like many embedded databases) doesn't handle
connection storms gracefully. Each connection is an OS-level file descriptor.
CLOSE_WAIT sockets don't release immediately. Under load, FDs accumulate, the
kernel socket backlog fills, new connections block, and the server stops responding.

**Mitigation:**
1. Never use `gt patrol report` — replaced with targeted per-agent queries
2. Emergency fix: `gt dolt stop && gt dolt cleanup && gt dolt start`
3. PRs filed for server-side timeouts and patrol serialization

**The deeper pattern:** Any agent that generates O(n) parallel queries where n is
proportional to the size of the bead database is a latent DoS. This includes:
- Parallel orphan scans
- Batch mol current lookups
- Per-polecat status checks in a loop

**Lesson for Gas City:** The data plane must support read isolation. Either:
- Rate-limit queries per agent per minute
- Force sequential reads for patrol operations
- Use a read replica for patrol queries, keeping the write path available

### 3.3 The Orphan Accumulation Crisis

**Incident (2026-03-04, near-fatal):** HQ database grew from 2,571 to 3,199 wisps
in 9 patrol cycles (+30 to +100 per cycle). Performance degraded. Refinery slowed.
Polecats timed out reading molecule state.

**Root cause:** Patrol cycles closed the ROOT wisp but not the CHILD step wisps.
`bd close --force` on the root bypassed the dependency check, marking the root
as closed while 5-10 child wisps remained open. Each cycle created new children
without closing old ones. After hundreds of cycles: 1,691 dangling parent refs.

**The `--force` flag semantics:** `bd close --force` means "close this bead
ignoring dependencies." It does NOT mean "cascade close all children." This is
the correct semantics for individual force-close, but it's a footgun when used
for parent-level closures.

**Remediation:**
```bash
# Wrong — closes parent only, leaves children dangling
bd close <root-wisp> --force --reason="Cycle N: complete"

# Right — close all children first
CHILDREN=$(bd show "$WISP" --children 2>&1 | grep -oE '[a-z]{2}-wisp-[a-z0-9]+')
for child in $CHILDREN; do
  bd show "$child" 2>&1 | grep -q "^○" && \
    bd close "$child" --force --reason="Cycle N: child"
done
bd close "$WISP" --force --reason="Cycle N: complete"
```

**Timeline:**
- Cycle 11: Remediation starts → 2,886 wisps (-13, working)
- Cycle 12: Regression → 3,123 wisps (+237, spike)
- Cycle 15: Mayor takes additional action → 92 wisps (-3,107, crisis resolved)

**Lesson for Gas City:** Cascade close must be the default behavior. A "close" on
a container node should close all children unless explicitly told not to. The
"close children first" requirement is an implementation detail that callers
shouldn't need to know. Implement cascade close at the storage layer.

### 3.4 bd mol current Hanging

**Incident (2026-02-18):** Multiple patrol agents called `bd mol squash`
simultaneously at cycle end. The exclusive Dolt lock caused `bd mol current`
to spin at 90-101% CPU indefinitely.

**Root cause:** No desynchronization between concurrent patrol squash calls.
All three patrol agents (deacon, witness, refinery) tried to squash their
patrol molecules within the same 30-second window after receiving the same
trigger signal.

**Fix:** Added `--jitter <duration>` to `gt mol squash`. With 10s jitter,
the three agents spread their squash calls by an average of 5 seconds,
enough to avoid contention under normal Dolt latency.

**Lesson for Gas City:** Any operation that takes an exclusive lock must
have mandatory jitter built in at the call site. "Add jitter before
calling" is too easy to forget. The locking primitive itself should
accept a `jitter_max` parameter.

### 3.5 Patrol Cycle Count per Session

**Finding (2026-02-28):** Running 13+ patrol cycles in a single session via
batch loops (piped xargs) caused repeated Dolt i/o timeouts. Single-cycle
execution was reliable.

**Root cause:** Likely pipe/process management overhead under sustained Dolt
load. Each cycle left residual connection pressure from the previous cycle.
Batching amplified this into cascading timeouts.

**Working pattern:** 2-3 cycles per session, then handoff to fresh session.
This balances:
- Context usage (starts ~0%, exits at ~95%)
- Connection pressure reset per session
- Session spawn overhead

**Lesson for Gas City:** Session lifecycle is a resource management primitive,
not just a context management primitive. Planned session rotation is health
maintenance, not overhead.

---

## 4. Known Failure Modes and Mitigations

### 4.1 Failure Mode Taxonomy

| Category | Failure | Frequency | Severity | Mitigation |
|----------|---------|-----------|----------|------------|
| **Spawn** | NODE_OPTIONS inheritance | Low | Critical | Explicit env sanitization |
| **Spawn** | Missing metadata.json | Low | Critical | Spawn health check |
| **Spawn** | Fork URL mismatch | Medium | High | PR-based verification |
| **Patrol** | Parallel query DoS | Medium | Critical | Sequential reads, rate limiting |
| **Patrol** | Orphan accumulation | High | High | Cascade close, periodic audit |
| **Patrol** | Lock contention | Low | High | Mandatory jitter |
| **Patrol** | Ephemeral mail UNIQUE constraint | Low | Medium | Use `--permanent` flag |
| **Lifecycle** | Stuck-in-done zombie | Low | Medium | Witness detection, 60s threshold |
| **Lifecycle** | Orphaned sandbox | Medium | Low | ReconcilePool cleanup |
| **Lifecycle** | Split-brain merge | Very low | High | cleanup_status serialization |
| **Data** | Dolt CLOSE_WAIT accumulation | Medium | Critical | Emergency restart procedure |
| **Session** | False "refinery stopped" | High | Low | Verify via tmux, not gt session status |

### 4.2 The Zombie Patrol

Zombie polecats (sessions with `done-intent` but still running) are handled by
the witness `DetectZombiePolecats()` sweep. The key insight: **60 seconds** is
the right threshold, not minutes. `gt done` should complete in seconds. If it's
still running after 60 seconds, it's hung.

Detection checklist:
```bash
# 1. Find polecats with done-intent label
bd list --label=done-intent --status=in_progress

# 2. Check each one's tmux session
tmux list-panes -t <session-name> -F "#{pane_current_command}"

# 3. If session exists AND done-intent > 60s old → zombie
# Kill session and continue cleanup pipeline from gt done mid-point
```

### 4.3 The CLOSE_WAIT Emergency Procedure

When Dolt is unresponsive due to CLOSE_WAIT accumulation:

```bash
# 1. Collect diagnostics FIRST (do NOT restart yet)
tail -200 ~/gt/.dolt-data/dolt.log | tee /tmp/dolt-hang-$(date +%s).log
lsof -i :3307 | grep CLOSE_WAIT | wc -l

# 2. Only then restart
gt dolt stop && gt dolt cleanup && gt dolt start

# 3. Verify recovery
gt dolt status
```

**CRITICAL:** Do NOT use `kill -QUIT` on Dolt on macOS. On Linux, SIGQUIT triggers
goroutine dumps. On macOS, it terminates the process immediately. Use `tail` on
the log file instead.

### 4.4 The Witness False Positive Problem

**Problem:** `gt session status property_scrapers/refinery` returns "stopped" when
Claude is between turns (momentarily idle). This causes false alerts.

**Root cause:** The session status check polls tmux for an active process. Between
Claude turns, the process is idle, not running. The check has no hysteresis.

**Verification procedure:**
```bash
# Do NOT trust gt session status alone
tmux list-sessions | grep refinery  # Check session exists at all
gt session status refinery          # If "stopped" here, check uptime
# If session exists AND uptime matches expected → false positive
```

**Lesson for Gas City:** Session health checks must distinguish "currently
processing" from "alive and healthy." Alive polecats are often idle. A health
check that can't distinguish idle-alive from dead-stopped will produce chronic
false positives that erode trust in the monitoring system.

---

## 5. Patrol Coordination Protocol

### 5.1 The Message Flow

```
Daemon ───LIFECYCLE:──────▶ Witness inbox
Daemon ───GUPP_VIOLATION:─▶ Witness inbox
Daemon ───ORPHANED_WORK:──▶ Witness inbox

Deacon ◀──heartbeat.json──── Daemon
Deacon ───nudge────────────▶ Witness (if stale)

Witness ──MERGE_READY:────▶ Refinery inbox
Witness ──RECOVERED_BEAD:─▶ Deacon (for re-dispatch)
Witness ──patrol receipt───▶ Beads (audit trail)

Refinery ─MERGED:─────────▶ Witness inbox
Refinery ─MERGE_FAILED:───▶ Witness inbox
```

### 5.2 Communication Hygiene

**Critical finding:** `gt mail send` creates a permanent bead with a Dolt commit.
At 100 patrol cycles/day with 3 agents sending mail per cycle, this generates
300 additional Dolt commits/day — a non-trivial write pressure.

**Policy:**
- `gt nudge` for routine inter-agent communication (ephemeral, zero Dolt cost)
- `gt mail send` ONLY for messages that must survive session death:
  - Handoffs
  - Escalations
  - MERGE_READY / MERGED protocol messages

**The cost calculation:** An agent that sends 1 unnecessary mail per patrol cycle
generates ~30 permanent beads/hour. Multiplied across agents: the mail overhead
can exceed the work-bead creation rate.

### 5.3 Cycle Closure Protocol (Correct Procedure)

This is the procedure that prevents orphan accumulation:

```bash
# Step 1: Create patrol wisp
WISP=$(gt patrol new)

# Step 2: Execute patrol steps
# ... (patrol logic) ...

# Step 3: Close children FIRST
CHILDREN=$(bd show "$WISP" 2>&1 | grep -oE '[a-z]{2}-wisp-[a-z0-9]+' | grep -v "^$WISP$")
for child in $CHILDREN; do
  STATUS=$(bd show "$child" 2>&1 | head -1 | grep -o "^[○●]")
  if [ "$STATUS" = "○" ]; then
    bd close "$child" --force --reason="Cycle $N: complete"
  fi
done

# Step 4: Close root (only after all children are closed)
bd close "$WISP" --force --reason="Cycle $N: complete"
```

**Do NOT use `bd mol burn`** — it hangs, holding an exclusive Dolt lock until killed.
**Do NOT use `gt mol squash`** without children pre-closed — it fails with "no handoff bead found".

### 5.4 Periodic Orphan Audit

Run weekly (or after any incident involving patrol closures):

```bash
# Count open wisps (healthy: < 200 in HQ)
bd list --rig=hq --status=open | wc -l

# Find dangling refs (wisps with closed parents)
bd list --rig=hq --status=open | while read id; do
  parent=$(bd show "$id" 2>&1 | grep "PARENT" | grep -oE '[a-z]{2}-[a-z0-9]+')
  if [ -n "$parent" ]; then
    status=$(bd show "$parent" 2>&1 | head -1 | grep -o "^[○●]")
    if [ "$status" = "●" ]; then
      echo "ORPHAN: $id (parent $parent is closed)"
    fi
  fi
done
```

Alert threshold: > 500 open wisps in HQ = investigate
Emergency threshold: > 1000 open wisps = halt new patrol cycles, run remediation

---

## 6. The GUPP Completion Guarantee in Production

### 6.1 What Actually Breaks the Guarantee

Theory says three conditions must hold. Practice shows each breaks differently:

**Pinned work breaks when:**
- `hook_bead` is accidentally cleared during witness cleanup
- Agent bead is nuked before work is done
- Dolt returns stale reads after a crash (wisp appears closed, isn't)

**Sandbox breaks when:**
- worktree directory is removed while session is dead
- Git index.lock gets stuck from a killed process (`rm .git/index.lock` to fix)
- Branch is force-deleted from remote

**Respawn breaks when:**
- Witness itself is down (deacon detects, restarts witness)
- NODE_OPTIONS prevents spawn (cleared in fix, but any env pollution breaks this)
- Session starts but GUPP doesn't fire (empty hook, startup prompt failure)

### 6.2 The "Thinking vs Hung" Problem

The daemon's GUPP violation detection (30 minutes with no progress) is a blunt
instrument. It cannot distinguish:
- A polecat thinking hard about a complex architectural decision
- A polecat stuck in an infinite retry loop
- A polecat with a hung subprocess (waiting for a network call)
- A polecat that crashed and left a zombie session

**The "Deacon murder spree" lesson:** Overly aggressive GUPP violation detection
killed polecats that were legitimately working. The false positive rate exceeded
the true positive rate. The thresholds were tripled.

**Current thresholds:**
- GUPP violation: 30 minutes (was 10 minutes)
- Hung session: 30 minutes of no tmux output
- Stuck-in-done: 60 seconds with done-intent label

**Who makes the kill decision:** Only the witness (an AI agent) should decide
whether a polecat is truly stuck. The daemon detects and reports; the witness
judges and acts.

### 6.3 Crash Loop Detection

Three crashes on the same step triggers escalation. Implementation:

```bash
# Witness tracks per-polecat crash count via ephemeral state
# (not Dolt — too much write pressure)
CRASH_COUNT=$(cat /tmp/polecat-crashes-$NAME 2>/dev/null || echo 0)
if [ "$CRASH_COUNT" -ge 3 ]; then
  gt escalate "Polecat $NAME crash-looping on step $STEP" -s HIGH
  # Stop respawning — file bug bead instead
  bd create --title "Crash loop: $NAME on $STEP" --type bug --priority 1
  exit 0
fi
echo $((CRASH_COUNT + 1)) > /tmp/polecat-crashes-$NAME
```

---

## 7. Recommendations for Gas City

Based on running Gas Town at scale, here are the design changes that would have
prevented the most incidents:

### 7.1 Cascade Close as Default

The single biggest source of incidents was orphan accumulation from non-cascading
closes. Gas City's equivalent of "close" must cascade by default:

```
close(node) → close all open children → close node
```

Opt-out via `--no-cascade` for cases where partial closure is intentional.

### 7.2 Explicit Environment Sanitization at Spawn Time

All spawned processes must run in a sanitized environment:
```
ALLOWED_VARS = [GT_ROLE, GT_RIG, BD_ACTOR, GIT_AUTHOR_NAME, ...]
CLEARED_VARS = [NODE_OPTIONS, DEBUGGER_*, ...]
```

No inherited environment variables except an explicit allowlist.

### 7.3 Read/Write Path Separation

Dolt's single-server architecture is the root cause of the DoS pattern.
Gas City needs:
- **Write path:** Exclusive access for bead mutations (single server or leader)
- **Read path:** Concurrent access for patrol queries (replicas or read-only connection pool)
- **Rate limiting:** Patrol agents limited to N reads/second, queued not rejected

### 7.4 Session Health = Alive + Idle-OK

Session health checks must have three states:
- **Active:** Claude is currently processing (show as green)
- **Idle:** Session exists, Claude not currently processing (show as yellow — normal)
- **Dead:** No tmux session (show as red — alert)

Collapsing "idle" and "dead" into "stopped" creates false positives that destroy
trust in monitoring.

### 7.5 Patrol Cycle Budget

Each patrol agent must have a configurable cycle budget:
```
max_queries_per_cycle: 10
max_writes_per_cycle: 3
max_cycles_per_session: 5
```

Agents that exceed their budget must yield to the next cycle. This prevents
a single "expensive cycle" from becoming a DoS event.

### 7.6 Fork-Aware Submission Pipeline

The submission pipeline (`gt done` equivalent) must:
1. Detect fork vs upstream remote configuration
2. Use PR-based verification when on a fork
3. Never use remote URL matching as the sole verification method

### 7.7 Session Rotation as First-Class Feature

Session rotation should be designed-in, not bolted on:
- Explicit "how many cycles before rotation" configuration
- Automatic context checkpointing before rotation
- Resumption that re-derives state from durable storage, not context

The current `gt handoff` mechanism works, but it requires polecats to self-report
context fullness. A system-level trigger at N% context utilization would be more
reliable.

### 7.8 Jitter at the Lock Layer

Any operation that acquires a shared lock must accept a `jitter_max_ms` parameter
at the API level. The caller should not be responsible for adding sleep before
contended operations. This is too easy to forget.

### 7.9 Mandatory Pre-Spawn Health Check

Before any polecat spawn, verify:
```bash
# 1. Data plane accessible
bd show $ISSUE_ID > /dev/null || fail "Dolt unreachable"

# 2. Git worktree clean
git -C $WORKTREE status --porcelain | grep -v "??" && fail "Dirty worktree"

# 3. Branch exists
git -C $WORKTREE branch --list $BRANCH | grep -q . || fail "Branch missing"

# 4. Molecule has remaining steps
bd mol current $MOLECULE_ID | grep -q "^○" || fail "No open steps"
```

A polecat that spawns into a broken environment wastes compute and produces
noise in the health monitoring system.

---

## 8. Incident Timeline Reference

For future incident analysis, here are the documented Gas Town incidents
in chronological order:

| Date | Incident | Impact | Resolution |
|------|----------|--------|-----------|
| 2026-02-04 | NODE_OPTIONS spawn failure | All polecats dead | Explicit NODE_OPTIONS="" in spawn env |
| 2026-02-16 | mol-convoy-feed title validation | Dog sessions not starting | Renamed `[vars.title]` to `[vars.issue_title]` |
| 2026-02-18 | bd mol current lock contention | All patrol blocked | `--jitter 10s` on mol squash |
| 2026-02-24 | Witness false positive: refinery stopped | Alert fatigue | tmux verification before escalation |
| 2026-02-24 | Ephemeral mail UNIQUE constraint | Mail failing silently | `--permanent` flag workaround |
| 2026-02-24 | Dog orphan scan: dogs can't execute | Orphan scan non-functional | Escalate to mayor; dogs don't have Claude sessions |
| 2026-02-28 | Batch patrol loop Dolt timeouts | Periodic patrol failures | Single-cycle execution; 2-3 cycles/session |
| 2026-03-03 | gt patrol report DoS | Dolt crash, all bd ops failed | Remove gt patrol report; sequential queries |
| 2026-03-03 | Gastown rig metadata missing | Polecat spawn failures | Add dolt_server_port to local_repo/.beads/metadata.json |
| 2026-03-03 | gt done fork URL mismatch | Polecats fail to submit | Manual PR creation; PR-based verification |
| 2026-03-04 | Patrol orphan accumulation | 3,199 wisps in HQ | Cascade child close; bulk remediation by Mayor |
| 2026-03-04 | bd close CLOSE_WAIT accumulation | All bd ops timed out | Emergency Dolt restart procedure |

---

## 9. Summary

The polecat lifecycle model is sound. GUPP works. The self-cleaning model prevents
accumulation. Patrol coordination provides resilience. But the failure modes are
concentrated at:

1. **Spawn time** — environment pollution, missing config, fork URL bugs
2. **Patrol scale** — parallel queries become DoS at O(100) wisps
3. **Closure semantics** — non-cascading close creates orphan debt

Gas City should address all three at the protocol level, not at the callsite level.
The lessons from Gas Town at scale are: **explicit > inherited, cascade > manual,
sequential > parallel** for patrol operations.

---

*This document was produced under Wasteland bead w-gt-004. All incidents referenced
have corresponding beads in the Gas Town production database.*
