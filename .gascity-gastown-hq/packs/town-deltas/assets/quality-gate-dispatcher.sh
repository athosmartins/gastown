#!/usr/bin/env bash
# quality-gate-dispatcher.sh — Autonomous Quality Gate Dispatcher ("G").
#
# Runs every ~2 min via launchd (com.gascity.quality-gate-dispatcher.plist).
# Picks up gate-status:queued markers (set by quality-gate-guard.sh after it
# claims and validates the marker), then:
#
#   1. Determines tier (CODE → 3 independent sessions; NON-CODE → 1 session + tests).
#   2. Spawns N GENUINELY INDEPENDENT reviewer sessions via
#      "gc session new gate-reviewer --no-attach".  NO shared context. Each
#      receives a unique targeted nudge describing exactly its review task.
#   3. Polls verdict beads until all reviewers post PASS or FAIL (or timeout).
#   4. On ALL-PASS  → direct-merge to production main + close source bead.
#      On ANY-FAIL  → set gate-status:failed, post blocking reasons, nudge author.
#   5. Appends one compact JSON line to .gc/quality-gate.jsonl.
#
# DESIGN INVARIANTS:
#   - Author-exclusion uses authoritative bead source (assignee/created_by).
#   - 3 separate dog sessions = 3 separate Claude Code processes. Not role-play.
#   - Verdict collection: each reviewer session closes its personal verdict bead
#     with a label "verdict:PASS" or "verdict:FAIL" and a comment with reason.
#   - DRY_RUN=1 → skips the actual git merge/push; logs "WOULD MERGE" instead.
#   - DRAIN-SAFE: this file + its plist are the ONLY artifacts. Does not touch
#     city.toml, pack.toml, or any crew skill files.
#
# Usage:
#   bash quality-gate-dispatcher.sh            # normal run
#   DRY_RUN=1 bash quality-gate-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/quality-gate-dispatcher.log"
QG_LOG="$GC_CITY/.gc/quality-gate.jsonl"

# imp18: Per-repo git mutation mutex lib — source fail-soft; provides git_mutex_acquire/release.
_GLH_SCRIPT="${GC_CITY}/scripts/git-lock-hygiene.sh"
[ -f "$_GLH_SCRIPT" ] && { GIT_LOCK_HYGIENE_LIB=1 source "$_GLH_SCRIPT" 2>/dev/null; } || true
unset _GLH_SCRIPT
# glh source clobbers LOG with its own jsonl path — restore ours (ga-l47b7 log-redirect fix)
LOG="$LOG_DIR/quality-gate-dispatcher.log"

# ── ga-eqjo hazard: AUTHOR/AUTHOR_AGENT must be BOUND for a Phase-C-only sweep ──
# gate_finalize_run() (the Phase C finalize path) calls
# resolve_recycled_author "$AUTHOR" "$AUTHOR_AGENT" ... — but both are only ASSIGNED
# in the CLAIM path (~L3600+, after a marker is claimed). The ga-eqjo async split made
# Phase C run STANDALONE: a sweep that only finalizes an in-flight run never reaches
# that assignment, so under `set -u` the sweep DIES with "AUTHOR_AGENT: unbound
# variable" — taking the whole gate with it. Observed 2026-07-16: 16 crashes, gate
# stopped spawning reviewers with 11 markers queued.
# Same shape as the extract()/cleanup_reviewer_sessions() hoists further down: Phase C
# needs everything it touches to exist BEFORE it, not at the claim site. Defaulting
# here (not `AUTHOR=""` at the claim site, which a Phase-C-only sweep skips) keeps the
# claim path's own assignment authoritative — it simply overwrites these.
AUTHOR="${AUTHOR:-}"
AUTHOR_AGENT="${AUTHOR_AGENT:-}"

# Maximum wall-clock minutes to wait for all reviewer verdicts before timing out.
VERDICT_TIMEOUT_MINUTES="${VERDICT_TIMEOUT_MINUTES:-22}"

# Safety floor: never allow a timeout shorter than 15 minutes regardless of env var.
# (Prevents accidental short timeouts from leftover test env vars causing false FAILs.)
if [ "$VERDICT_TIMEOUT_MINUTES" -lt 15 ] 2>/dev/null; then
  warn "VERDICT_TIMEOUT_MINUTES=${VERDICT_TIMEOUT_MINUTES} is dangerously short — overriding to 15m (floor)."
  VERDICT_TIMEOUT_MINUTES=15
fi

# ── ga-ltr3c: diff-size scaling of the verdict timeout ────────────────────────
# A reviewer reading a LARGE diff (many files / many lines) legitimately needs
# more wall-clock than a small one. With the fixed base above, big-but-GREEN
# packages (build + embed + sweep + tests; 1000s of lines across dozens of files —
# thies-wa wa-vnqx / digo-wa wa-bu2t) routinely outran the timeout and were killed
# as a "zombie" (age>verdict-timeout, no live reviewer) BEFORE emitting a verdict
# → an infinite re-submit loop on good code. The effective timeout is scaled by
# the diff size (gate_scaled_verdict_timeout, applied once the diff is known) and
# CAPPED here. The cap bounds worst-case dead-reviewer detection via the OUTER
# timeout; the ga-4u16h re-convene probe catches a genuinely dead reviewer far
# sooner (session gone/closed), independent of this ceiling — so raising it never
# masks a stuck reviewer, only rescues slow-but-live big reviews.
VERDICT_TIMEOUT_MAX_MINUTES="${VERDICT_TIMEOUT_MAX_MINUTES:-50}"
case "$VERDICT_TIMEOUT_MAX_MINUTES" in ''|*[!0-9]*) VERDICT_TIMEOUT_MAX_MINUTES=50 ;; esac
# The cap can never sit below the base timeout — scaling only ADDS time.
if [ "$VERDICT_TIMEOUT_MAX_MINUTES" -lt "$VERDICT_TIMEOUT_MINUTES" ] 2>/dev/null; then
  VERDICT_TIMEOUT_MAX_MINUTES="$VERDICT_TIMEOUT_MINUTES"
fi
# Per-file and per-100-changed-lines minute increments (0 disables that axis).
VERDICT_TIMEOUT_PER_FILE_MINUTES="${VERDICT_TIMEOUT_PER_FILE_MINUTES:-1}"
case "$VERDICT_TIMEOUT_PER_FILE_MINUTES" in ''|*[!0-9]*) VERDICT_TIMEOUT_PER_FILE_MINUTES=1 ;; esac
VERDICT_TIMEOUT_PER_100_LINES_MINUTES="${VERDICT_TIMEOUT_PER_100_LINES_MINUTES:-1}"
case "$VERDICT_TIMEOUT_PER_100_LINES_MINUTES" in ''|*[!0-9]*) VERDICT_TIMEOUT_PER_100_LINES_MINUTES=1 ;; esac

# Poll interval (seconds) when waiting for verdicts.
VERDICT_POLL_INTERVAL="${VERDICT_POLL_INTERVAL:-30}"

# ── ga-zl277: orphaned gate-reviewer session TTL ──────────────────────────────
# A gate-reviewer session older than this cannot belong to any live run: a live
# dispatcher closes its reviewers in Step 9, and the verdict poll itself caps a
# run at VERDICT_TIMEOUT_MINUTES. The startup janitor (Step 0a-2) reaps asleep
# gate-reviewer sessions older than this so SIGKILL/OOM-orphaned reviewers cannot
# fill the gate-reviewer template's max_active_sessions=6 budget. TTL = verdict
# timeout + margin (slack over the longest a live run can hold a session open).
# ga-ltr3c: derive from the SCALED ceiling (VERDICT_TIMEOUT_MAX_MINUTES), not the
# base — a large-diff run can now legitimately hold its reviewers up to the cap,
# so the reaper's "longest a live run can hold" must track the cap or it would
# prematurely reap a live big review's session.
REVIEWER_SESSION_TTL_MINUTES="${REVIEWER_SESSION_TTL_MINUTES:-$((VERDICT_TIMEOUT_MAX_MINUTES + 20))}"

# Dry-run mode: skip actual git merge+push.
DRY_RUN="${DRY_RUN:-0}"

# ── ga-4u16h: re-convene a DEAD reviewer slot mid-collection ──────────────────
# The Dolt :52756 server intermittently resets connections (root cause ga-hxhaj).
# When a reset kills a gate-reviewer SESSION mid-review, its verdict bead stays
# verdict:pending; pre-ga-4u16h the dispatcher waited the FULL outer timeout and
# then counted the missing verdict as a FAIL — bouncing a GOOD fix on INFRA.
# Fix: when a slot's reviewer SESSION is confirmed DEAD (gone from the session
# list, or closed=true) while its verdict bead is still pending, re-spawn a FRESH
# reviewer for THAT slot (reusing the still-pending verdict bead), bounded by a
# per-slot budget. Real verdict:FAIL votes still fail immediately; healthy runs
# are unaffected. A permanently-broken Dolt converges to FAIL within
# (1 + MAX_RESPAWNS_PER_SLOT) reviewer cohorts via the unchanged outer timeout.
#
# Max re-spawns per reviewer slot. 0 disables re-convene (exact pre-ga-4u16h
# behavior). Sanitized + ceiling-guarded (mirrors the VERDICT_TIMEOUT floor).
MAX_RESPAWNS_PER_SLOT="${MAX_RESPAWNS_PER_SLOT:-2}"
case "$MAX_RESPAWNS_PER_SLOT" in ''|*[!0-9]*) MAX_RESPAWNS_PER_SLOT=2 ;; esac
if [ "$MAX_RESPAWNS_PER_SLOT" -gt 5 ] 2>/dev/null; then
  MAX_RESPAWNS_PER_SLOT=5   # ceiling: never thrash spawning >5 cohorts for one slot
fi

# Grace window (seconds) a freshly-(re)spawned reviewer gets before its session
# may be judged DEAD — covers slow startup/waking so a live-but-slow reviewer is
# NEVER re-convened. Floor-guarded.
# ga-flfo: default was 60s, but a `gc session new --no-attach` deferred start
# was observed taking ~210s under load/Dolt pressure — comfortably outside the
# old default, which is how a reviewer got closed mid-boot before this default
# was raised. 360s matches the value already proven safe live (Mayor's
# EnvironmentVariables override on the launchd plist, applied as an interim
# mitigation while this fix was in flight) so the code default no longer
# silently regresses to the unsafe value if that override is ever removed.
# The primary fix for the boot-vs-dead conflation is session_is_booting() (see
# above) — it neutralizes deadness for state=creating regardless of this
# value; this bump is defense in depth, not the load-bearing guard.
RECONVENE_GRACE_SECS="${RECONVENE_GRACE_SECS:-360}"
case "$RECONVENE_GRACE_SECS" in ''|*[!0-9]*) RECONVENE_GRACE_SECS=360 ;; esac
[ "$RECONVENE_GRACE_SECS" -lt 20 ] 2>/dev/null && RECONVENE_GRACE_SECS=20

# Consecutive polls a slot must read DEAD before re-convene fires (defends
# against a transient/partial `gc session list`). Floor-guarded.
RECONVENE_DEAD_STREAK_MIN="${RECONVENE_DEAD_STREAK_MIN:-2}"
case "$RECONVENE_DEAD_STREAK_MIN" in ''|*[!0-9]*) RECONVENE_DEAD_STREAK_MIN=2 ;; esac
[ "$RECONVENE_DEAD_STREAK_MIN" -lt 1 ] 2>/dev/null && RECONVENE_DEAD_STREAK_MIN=1

# ga-q8tmn: seconds of session inactivity (now − last_active from `gc session
# list`) after which a reviewer that is LISTED + not-closed + ACKed but whose
# Claude has WEDGED (quota/credit limit → zero terminal output) is treated as
# DEAD and re-convened, instead of waiting the full 45m outer timeout. A frozen
# Claude stops emitting tmux activity entirely, so its last_active stops
# advancing; a genuinely-working reviewer refreshes it on every tool call.
# Floored well above normal reviewer output gaps. The probe that reads this
# value cannot run before `_spawn_age >= RECONVENE_GRACE_SECS` (the caller's
# own gate, not a static ordering of these two constants — ga-flfo raised
# RECONVENE_GRACE_SECS to 360 without needing to raise this), and staleness is
# measured from the session's own last_active clock, not from spawn time, so
# it can never reap inside the grace window regardless of how the two values
# compare numerically. Effective detection latency ≈
# REVIEWER_STALE_SECS + (RECONVENE_DEAD_STREAK_MIN−1)·VERDICT_POLL_INTERVAL — at
# the defaults ≈ 300 + 30 = 330s, comfortably under the 45m timeout and the
# ga-q8tmn <8min guiding star. Set to 0 to DISABLE the staleness probe entirely.
REVIEWER_STALE_SECS="${REVIEWER_STALE_SECS:-300}"
case "$REVIEWER_STALE_SECS" in ''|*[!0-9]*) REVIEWER_STALE_SECS=300 ;; esac
if [ "$REVIEWER_STALE_SECS" != "0" ] && [ "$REVIEWER_STALE_SECS" -lt 120 ] 2>/dev/null; then
  REVIEWER_STALE_SECS=120
fi

# ── ga-evjs2: scale the frozen-reviewer staleness window by DIFF SIZE ──────────
# REVIEWER_STALE_SECS above is the SILENCE window before a listed+peek-alive reviewer
# is declared frozen (ga-q8tmn). A reviewer reading a LARGE diff is legitimately quiet
# longer than one on a 1-file change, so a FIXED 300s window false-reaps big-diff
# reviewers at 5min → respawn → it re-reads the same huge diff, silent >5min again →
# reaped again → DEATH-SPIRAL (observed 2026-06-30: a 3885-line re-land bead drove a
# 72% reviewer-death rate over 3h, 213 respawns, burning Claude quota + Dolt CPU, the
# gate merged nothing for ~10h). The verdict TIMEOUT already scales with diff size
# (ga-ltr3c) — the staleness window did not. Scale it the SAME way
# (gate_scaled_reviewer_stale), capped at REVIEWER_STALE_MAX_SECS so a genuinely-frozen
# reviewer is still reaped well under the outer verdict timeout. Small diffs are ~unchanged.
# Set REVIEWER_STALE_MAX_SECS=REVIEWER_STALE_SECS (or the per-axis knobs to 0) to disable scaling.
REVIEWER_STALE_PER_FILE_SECS="${REVIEWER_STALE_PER_FILE_SECS:-20}"
case "$REVIEWER_STALE_PER_FILE_SECS" in ''|*[!0-9]*) REVIEWER_STALE_PER_FILE_SECS=20 ;; esac
REVIEWER_STALE_PER_100_LINES_SECS="${REVIEWER_STALE_PER_100_LINES_SECS:-15}"
case "$REVIEWER_STALE_PER_100_LINES_SECS" in ''|*[!0-9]*) REVIEWER_STALE_PER_100_LINES_SECS=15 ;; esac
REVIEWER_STALE_MAX_SECS="${REVIEWER_STALE_MAX_SECS:-900}"
case "$REVIEWER_STALE_MAX_SECS" in ''|*[!0-9]*) REVIEWER_STALE_MAX_SECS=900 ;; esac
if [ "$REVIEWER_STALE_SECS" != "0" ] && [ "$REVIEWER_STALE_MAX_SECS" -lt "$REVIEWER_STALE_SECS" ] 2>/dev/null; then
  REVIEWER_STALE_MAX_SECS="$REVIEWER_STALE_SECS"
fi

# ga-mepb0 (defense-in-depth, root cause): seconds to pause after waking each
# reviewer (except the last) so N reviewers do NOT all boot `gc prime`
# (SessionStart) against the Dolt :52756 server at the same instant. That
# thundering herd is what opens the Dolt circuit-breaker and wedges a reviewer
# at boot in the first place (EDIT #1 re-convenes survivors; this lowers the odds
# of the wedge at all). 0 disables. Floor 0, capped so a misconfig can't add
# pathological latency to every gate. Total added latency = stagger × (N-1).
GATE_SPAWN_STAGGER_SECS="${GATE_SPAWN_STAGGER_SECS:-3}"
case "$GATE_SPAWN_STAGGER_SECS" in ''|*[!0-9]*) GATE_SPAWN_STAGGER_SECS=3 ;; esac
[ "$GATE_SPAWN_STAGGER_SECS" -gt 15 ] 2>/dev/null && GATE_SPAWN_STAGGER_SECS=15

# ga-p4g6: raw-diff line budget embedded in the reviewer task text. Below this,
# the full diff is shown verbatim and the header says so plainly. At/above it,
# the diff is truncated on WHOLE-FILE boundaries (never mid-hunk) and the header
# switches to PARTIAL with real counts + the omitted file list — see Step 7.
GATE_DIFF_LINE_BUDGET="${GATE_DIFF_LINE_BUDGET:-2000}"
case "$GATE_DIFF_LINE_BUDGET" in ''|*[!0-9]*) GATE_DIFF_LINE_BUDGET=2000 ;; esac

# ── ga-dupnv (bug 2 root): bound reviewer task-delivery so a hung `gc session
# nudge/submit` cannot blow the sweep's wall-clock budget. Observed live
# (crew/thies/wa-86jr, run ga-wisp-o30v41): the `--delivery queue` nudge for
# reviewer 1 BLOCKED for ~12 minutes (09:08→09:20) and then failed — long enough
# that launchd's ~2-min StartInterval overlapped fresh sweeps and the over-running
# process was SIGTERM'd ("Terminated: 15") BEFORE it ever reached the verdict
# poll. The downstream damage: (a) the marker was left gate-status:dispatching →
# Step 0a re-queued it → a later sweep re-claimed it and spawned a DUPLICATE run
# (bug 1), and (b) the run's reviewers were never watched to a verdict (bug 2 —
# "alive 53m, no verdict"). The durable-pull channel (ga-67hae: verdict bead
# assigned to the reviewer's session_name + task embedded as a comment) is the
# reliable delivery path, so a fast-failing nudge is strictly better than a
# 12-minute hang. GATE_NUDGE_TIMEOUT is a command PREFIX (not a wrapper fn) so it
# stays mockable: an external `timeout` cannot see a shell-function `gc` mock, so
# lib-only selftests run with the prefix EMPTY (see the lib-only override below).
GATE_NUDGE_TIMEOUT_SECS="${GATE_NUDGE_TIMEOUT_SECS:-45}"
case "$GATE_NUDGE_TIMEOUT_SECS" in ''|*[!0-9]*) GATE_NUDGE_TIMEOUT_SECS=45 ;; esac
[ "$GATE_NUDGE_TIMEOUT_SECS" -lt 10 ] 2>/dev/null && GATE_NUDGE_TIMEOUT_SECS=10
GATE_NUDGE_TIMEOUT="${GATE_NUDGE_TIMEOUT:-timeout $GATE_NUDGE_TIMEOUT_SECS}"
# Lib-only mode (selftests source this script and replace `gc` with a shell
# function): the external `timeout` binary cannot see a shell-function mock, so
# null the prefix and let the real helpers call the mock directly. Production
# (no GATE_DISPATCHER_LIB_ONLY) keeps the timeout. Honors an explicit override.
if [ -n "${GATE_DISPATCHER_LIB_ONLY:-}" ] && [ -z "${GATE_NUDGE_TIMEOUT_FORCE:-}" ]; then
  GATE_NUDGE_TIMEOUT=""
fi

# ── ga-dupnv (bug 1): one branch = one authoritative gate-run. SIBLING_RUN_STALE
# is the age (minutes) past which a still-running gate-run for a branch is judged
# ABANDONED (its dispatcher died mid-run and never drove it terminal) and may be
# superseded so a fresh run can take over. A genuinely live run terminates within
# VERDICT_TIMEOUT (≤22m) — once bug 2 is fixed it always reaches the verdict poll
# — so anything older than this ceiling is presumed dead. Default 90m matches the
# guard's gate-run TTL fallback referenced by supersede_sibling_runs.
SIBLING_RUN_STALE_MINUTES="${SIBLING_RUN_STALE_MINUTES:-90}"
case "$SIBLING_RUN_STALE_MINUTES" in ''|*[!0-9]*) SIBLING_RUN_STALE_MINUTES=90 ;; esac
[ "$SIBLING_RUN_STALE_MINUTES" -lt 30 ] 2>/dev/null && SIBLING_RUN_STALE_MINUTES=30

# ── ga-cw4pm: dynamic-concurrency (Dolt + quota headroom) thresholds ──────────
# The gate's concurrency was STATIC — the gate-reviewer template's
# max_active_sessions=6 admits up to 2 CODE runs (3 reviewers each) regardless of
# how loaded the Dolt :52756 data plane is. When Dolt is already saturated (by a
# sibling run, the supervisor's per-rig reconcile scan, or the Pilot) the gate
# STILL spawned a second run × 3 reviewers → thundering herd → Dolt 200%+ →
# reviewers boot-stall on `gc prime` → verdict timeout → FALSE-FAIL on good code.
# The headroom gate (Step 0b-1) replaces the static cap with a DYNAMIC ceiling on
# concurrent reviewer sessions, computed from live Dolt CPU/latency + Claude quota
# — exactly how the Pilot already gates dispatch-to-capacity (ga-rk5va). Every
# threshold is env-overridable. CPU% is the live dolt-server process %cpu (per
# `ps`, can exceed 100 = per-core); latency is `gc dolt health` server.latency_ms.
#
# Ladder: cpu>HOT or lat>HOT_MS → ceiling 0 (open NO run — don't pile onto a hot
# plane); cpu>WARM (≤HOT)        → ceiling = one run (a 2nd concurrent run waits);
# cpu≤WARM                       → ceiling = MAX (scale up to the static 6).
# Baseline under one booting run is ~86-90%; 200 (~2 pegged cores) is the
# documented danger zone — HOT defaults just under it so the gate stops admitting
# BEFORE the herd reaches 200%.
GATE_DOLT_CPU_HOT="${GATE_DOLT_CPU_HOT:-180}"          # cpu% above which NO new run opens
GATE_DOLT_CPU_WARM="${GATE_DOLT_CPU_WARM:-100}"        # cpu% above which only ONE run runs
GATE_DOLT_LATENCY_HOT_MS="${GATE_DOLT_LATENCY_HOT_MS:-2500}"  # server latency ceiling (matches Pilot)
GATE_MAX_REVIEWERS="${GATE_MAX_REVIEWERS:-6}"          # full ceiling when calm (= template max_active_sessions)
GATE_CODE_REVIEWERS="${GATE_CODE_REVIEWERS:-2}"        # real reviewer count for a CODE-tier run (mirrors the Step 6 tier dispatch below)
GATE_SWAP_FREE_FLOOR_MB="${GATE_SWAP_FREE_FLOOR_MB:-512}"  # below this free swap, admit NO new run (ga-92azu resource brake)
case "$GATE_DOLT_CPU_HOT"        in ''|*[!0-9]*) GATE_DOLT_CPU_HOT=180 ;; esac
case "$GATE_DOLT_CPU_WARM"       in ''|*[!0-9]*) GATE_DOLT_CPU_WARM=100 ;; esac
case "$GATE_DOLT_LATENCY_HOT_MS" in ''|*[!0-9]*) GATE_DOLT_LATENCY_HOT_MS=2500 ;; esac
case "$GATE_MAX_REVIEWERS"       in ''|*[!0-9]*) GATE_MAX_REVIEWERS=6 ;; esac
case "$GATE_CODE_REVIEWERS"      in ''|*[!0-9]*) GATE_CODE_REVIEWERS=2 ;; esac
case "$GATE_SWAP_FREE_FLOOR_MB"  in ''|*[!0-9]*) GATE_SWAP_FREE_FLOOR_MB=512 ;; esac
# ga-92azu: admission must reserve what a run ACTUALLY consumes, not a stale
# worst-case. GATE_CODE_REVIEWERS (just above, validated) is that worst case
# across BOTH tiers — NON-CODE is a fixed 1 reviewer, always <= it (see the
# Step 6 tier dispatch below) — so default HERE from THAT SAME knob, instead of
# a second hardcoded constant that can silently drift from it. That drift is
# exactly what happened: the deployed plist dropped GATE_CODE_REVIEWERS to 1
# (995 logged CODE runs all used required_reviewers=1, zero used 3) while this
# constant stayed hardcoded at 3, wasting 2/3 of every admission reservation. If
# a tier ever needs 3 reviewers again, bumping GATE_CODE_REVIEWERS alone is
# enough — this default follows it automatically.
GATE_REVIEWERS_PER_RUN="${GATE_REVIEWERS_PER_RUN:-$GATE_CODE_REVIEWERS}"  # a CODE run's reviewer count (worst-case admission unit)
case "$GATE_REVIEWERS_PER_RUN"   in ''|*[!0-9]*) GATE_REVIEWERS_PER_RUN="$GATE_CODE_REVIEWERS" ;; esac
[ "$GATE_REVIEWERS_PER_RUN" -ge 1 ] 2>/dev/null || GATE_REVIEWERS_PER_RUN=1

# session_is_dead <present 0|1> <closed true|false|1|0> → echoes 1 (dead) | 0 (alive)
# A reviewer session is DEAD iff it is absent from the session list (present=0)
# OR explicitly closed. A present, non-closed session (active OR asleep) is ALIVE
# — `asleep` is the normal state of a reviewer that finished or is between turns,
# so it must NEVER be treated as dead. Pure; no I/O.
# SELFTEST-EXTRACT session-is-dead-fn: BEGIN
session_is_dead() {
  local present="$1" closed="$2"
  if [ "$present" = "0" ]; then echo 1; return 0; fi
  case "$closed" in true|TRUE|True|1) echo 1 ;; *) echo 0 ;; esac
}
# SELFTEST-EXTRACT session-is-dead-fn: END

# classify_slot_action <bead_closed 0|1> <session_dead 0|1> <budget_remaining int>
# The single decision for ONE reviewer slot in a poll iteration. Pure; no I/O.
#   received → verdict bead is closed (a verdict — PASS or FAIL — was recorded);
#              caller's existing logic counts it. NEVER re-spawn (so an explicit
#              verdict:FAIL fails immediately, as before).
#   respawn  → bead still pending AND session confirmed dead AND budget remains.
#   wait     → everything else: a live (slow) reviewer, OR a dead slot whose
#              budget is exhausted (the outer timeout is the ultimate backstop —
#              bounded, never spins).
classify_slot_action() {
  local bead_closed="$1" session_dead="$2" budget="$3"
  case "$budget" in ''|*[!0-9-]*) budget=0 ;; esac
  if [ "$bead_closed" = "1" ]; then echo "received"; return 0; fi
  if [ "$session_dead" = "1" ] && [ "$budget" -gt 0 ] 2>/dev/null; then echo "respawn"; return 0; fi
  echo "wait"
}

# slot_effectively_dead <session_dead 0|1> <acked 0|1> → 1 (treat as dead for the
# re-convene decision) | 0. Pure; no I/O.
# ga-mepb0: session_is_dead only sees absent/closed sessions. A reviewer can be
# PRESENT + not-closed (session_is_dead=0) yet wedged at boot — its SessionStart
# `gc prime` hung on the Dolt :52756 circuit-breaker, so the session is asleep
# with 0 terminal output and a still-pending verdict bead. It NEVER ACKs, so the
# ga-4u16h liveness gate alone could not see it and only the 45m outer timeout
# caught it → a FALSE FAIL on a GOOD branch. Fold the ACK signal into deadness: a
# slot is effectively dead if its session is DEAD *or* it has never shown a sign
# of life (acked != 1). The caller re-checks for LATE life (verdict progressed or
# new output) BEFORE trusting acked, so a slow-but-alive reviewer is never killed.
slot_effectively_dead() {
  local session_dead="$1" acked="$2"
  if [ "$session_dead" = "1" ]; then echo 1; return 0; fi
  if [ "$acked" != "1" ]; then echo 1; return 0; fi
  echo 0
}

# session_peek_reports_dead <peek_stderr_text> → 1 (peek CONFIRMS the session is
# GONE — drained/ended) | 0 (alive, or inconclusive → never reap). Pure; no I/O.
# ga-h9o17: a gate-reviewer that DRAINS (its session ends normally instead of
# being hard-killed) transitions to lifecycle asleep/drained but STAYS in
# `gc session list` with closed!=true. So the list-only session_is_dead() reads
# it ALIVE (present=1, closed=false → 0), and because a reviewer that drained
# mid-run had already ACKed, slot_effectively_dead() also reads it alive — the
# re-convene safety net never fires and the still-pending verdict waits the full
# 45m outer timeout → a false-FAIL of a clean, FF-mergeable branch (observed live
# 2026-06-11: 2/3-PASS sat 37min, reviewer-2 drained with verdict:pending).
#
# `gc session peek` is the discriminator the list lacks (the two views disagree):
# a drained/ended session makes peek exit non-zero and print
#   "gc session peek: session not found: <id>"
# on STDERR (stdout empty), while a genuinely asleep-but-ALIVE reviewer's peek
# SUCCEEDS with its real terminal scrollback on STDOUT. Match ONLY that explicit,
# gc-emitted not-found signal on stderr — never peek's STDOUT content (a live
# reviewer's scrollback could itself contain the words "not found"), and never a
# bare transient connection error (which does not say "session not found"). Any
# non-not-found result is treated as ALIVE, so a transient peek/Dolt glitch can
# NEVER reap a live reviewer; the grace + dead-streak guards and the outer
# timeout remain the backstops above this signal.
# SELFTEST-EXTRACT session-peek-reports-dead-fn: BEGIN
session_peek_reports_dead() {
  case "$1" in
    *"session not found"*) echo 1 ;;
    *) echo 0 ;;
  esac
}
# SELFTEST-EXTRACT session-peek-reports-dead-fn: END

# session_is_booting <state> → 1 (the session record exists but the runtime
# has not started yet — NOT a signal of death) | 0. Pure; no I/O.
# ga-flfo: a `gc session new --no-attach` deferred start can take ~210s under
# load/Dolt pressure before the tmux runtime actually appears. During that
# window `gc session list` reports state="creating" and `gc session peek`
# answers "session not found" on stderr — the IDENTICAL signal
# session_peek_reports_dead() uses to detect a DRAINED (already-ended)
# reviewer, and a present-but-never-acked slot is exactly what
# slot_effectively_dead() also treats as dead. Every existing deadness probe
# therefore reads "hasn't been born yet" the same as "died", so a slow boot
# alone got reviewers closed mid-boot (observed live: w4x6vg reaped 32s after
# spawn, uraowb at 48s — both well inside a real ~210s boot). A session can
# only report state="creating" while genuinely booting — never while
# genuinely alive-and-working or genuinely dead — so gating on it directly
# distinguishes NOT-BORN from DIED instead of conflating them via a timeout
# race. RECONVENE_GRACE_SECS remains the backstop for every OTHER state.
session_is_booting() {
  case "$1" in
    creating) echo 1 ;;
    *) echo 0 ;;
  esac
}

# headroom_live_reviewers <session_count> <reaped> <drained> → the number of
# gate-reviewer sessions that TRULY occupy the template's max_active_sessions
# budget after this sweep, floored at 0. Pure; no I/O.
# gt-bewtm: LIVE_REVIEWERS is the denominator of the Step 0b-1 headroom gate.
# The original calc was (session_count - reaped), which counts EVERY present,
# non-closed reviewer as live. But a reviewer that DRAINS (its Claude session
# ends normally instead of being hard-killed) stays LISTED + not-closed and
# presents as asleep, so the age-TTL janitor keeps it (age < TTL) and `reaped`
# misses it — yet it occupies NO real budget. Under Dolt pressure reviewers
# drain often; the phantom count climbs, headroom hits a false cap
# ("dolt-calm-cap-reached / gate em N runs") and DEFERs every sweep even with
# Dolt calm and the queue full (the 2026-06-12 town-wide deadlock). `drained`
# is the count of those peek-confirmed-gone sessions (session_peek_reports_dead
# = 1), subtracted so the denominator reflects only genuinely-live reviewers.
# This is the headroom-calc-only fix: it does NOT lower the age-TTL (which would
# reap slow-but-alive reviewers mid-review → false-FAILs); peek reports a
# slow-alive reviewer as alive and a drained one as gone, so it is the safe
# discriminator. Defensive on junk: any non-numeric arg folds to 0.
headroom_live_reviewers() {
  local count="${1:-0}" reaped="${2:-0}" drained="${3:-0}" live
  case "$count"   in ''|*[!0-9]*) count=0 ;; esac
  case "$reaped"  in ''|*[!0-9]*) reaped=0 ;; esac
  case "$drained" in ''|*[!0-9]*) drained=0 ;; esac
  live=$(( count - reaped - drained ))
  [ "$live" -lt 0 ] && live=0
  echo "$live"
}

# _ts_to_epoch <rfc3339> → unix epoch seconds (stdout) | "" on failure.
# Handles BOTH a trailing Z (UTC) and a numeric ±HH:MM offset — the two forms
# `gc session list` emits for last_active (e.g. "...Z" or "...-03:00"). python3
# parses ISO-8601 offsets natively and is the canonical cross-platform path
# (ga-ouqtg: macOS BSD `date` mishandles sub-second/offset stamps); GNU `date -d`
# is the fallback. Deliberately NOT the BSD `date -j -u -f ...${ts%%Z*}` strip
# used for the UTC-only ("...Z") marker timestamps elsewhere in this script — that
# strip would silently DISCARD a ±HH:MM offset and return an epoch off by the
# offset. Empty/garbage in → empty out (caller fail-opens). No global side effects.
_ts_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] && { echo ""; return 0; }
  python3 -c 'import sys,datetime
s=sys.argv[1].strip()
try:
    if s.endswith("Z"): s=s[:-1]+"+00:00"
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    sys.exit(1)' "$ts" 2>/dev/null && return 0
  date -d "$ts" +%s 2>/dev/null && return 0
  echo ""
}

# reviewer_last_active_stale <last_active_iso> <now_epoch> <threshold_secs>
#   → 1 (the session has emitted NO activity for ≥ threshold — frozen/wedged)
#   | 0 (fresh, OR last_active empty/unparseable/in the future → FAIL-OPEN).
# ga-q8tmn: a gate-reviewer whose Claude WEDGES mid-review (it hit a session or
# weekly quota/credit limit) stays PRESENT + not-closed in `gc session list`
# (session_is_dead=0), has already ACKed (slot_effectively_dead=0), and its
# `gc session peek` SUCCEEDS with real scrollback (session_peek_reports_dead=0)
# — EVERY existing deadness signal reads it ALIVE, so its still-pending verdict
# waited the full 45m outer timeout and false-FAILed a clean branch (observed
# live 2026-06-10 ~19:35-20:12: all 3 reviewers of wa-ag70 froze with last_active
# ~35m, the gate sat "Verdicts: 0/3" for 37m, and it only unstuck when the Mayor
# killed the 3 sessions by hand). The discriminator the others lack is the
# session's OWN activity clock: a wedged Claude produces no terminal output, so
# last_active stops advancing, while a working reviewer refreshes it on every
# tool call. last_active comes straight from the session-list JSON already
# fetched each poll, so this costs ZERO extra I/O. Parse defensively: an empty
# or unparseable timestamp, a non-numeric now/threshold, or a FUTURE last_active
# (clock skew) all yield 0 — staleness can ONLY reap on a clearly-old,
# successfully-parsed timestamp. The grace + dead-streak guards in the caller
# remain the backstops above this signal, so one stale read can never reap a
# live reviewer.
reviewer_last_active_stale() {
  local la="$1" now="$2" thresh="$3" la_epoch age
  [ -z "$la" ] && { echo 0; return 0; }
  case "$now"    in ''|*[!0-9]*) echo 0; return 0 ;; esac
  case "$thresh" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  la_epoch=$(_ts_to_epoch "$la")
  case "$la_epoch" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$la_epoch" -le 0 ] 2>/dev/null && { echo 0; return 0; }
  age=$(( now - la_epoch ))
  [ "$age" -lt 0 ] 2>/dev/null && { echo 0; return 0; }   # future ts (clock skew) → never stale
  if [ "$age" -ge "$thresh" ]; then echo 1; else echo 0; fi
}

# ── ga-vdurb: VERIFIED verdict-bead assignment to a reviewer's session NAME ─────
# The reviewer's durable-pull channel is `gc bd list --assignee=$GC_SESSION_NAME
# -l type:quality-gate-verdict` — it keys on the session NAME, not the id. A lost
# `--assignee` write silently kills that channel (the bead's assignee stays None /
# stale), leaving only the racy nudge — which misses → 0 verdicts → 0 merges.
# This helper does the assign, reads it back, and retries on mismatch, then
# WARNs (visible, not silent) if it still fails. NEVER fatal: a failed assignment
# must not abort the merge path (the outer verdict-poll + timeout are the backstop)
# — but it must not vanish silently either. Returns 0 if verified, 1 if not.
# Args: <verdict_bead_id> <session_name> <context-label-for-logs>
#
# ga-mo7q: measured 30% of verdict beads created with assignee never set (this
# was previously a bare 2-try loop with no backoff and no durable trace of a
# final failure — a WARN line in the dispatcher log is the only record, and
# nobody tails that log while a reviewer is stalling). Two changes:
#   (a) 4 tries with a short sleep between attempts, not 2 back-to-back — the
#       failures are consistent with transient read-after-write lag, and the
#       cost of extra tries (<=3s) is negligible against the multi-minute gate
#       budget.
#   (b) on final failure, label the bead `verdict:assignee-degraded` so it is
#       cheaply queryable (a detector can find it, a human can grep for it)
#       instead of leaving the only evidence in a log line. This does NOT
#       replace the reviewer-side session_name fallback (ga-mo7q fix b, in the
#       gate-reviewer prompt template) — it makes the degraded state visible
#       independently of whether the reviewer's fallback happens to rescue it.
assign_verdict_bead_verified() {
  local _vb="$1" _sname="$2" _ctx="${3:-}" _seen _try
  [ -z "$_vb" ] && return 1
  [ -z "$_sname" ] && { warn "  Verdict-assign (${_ctx}): empty session name for bead ${_vb} — durable channel NOT wired."; return 1; }
  for _try in 1 2 3 4; do
    bd -C "$GC_CITY" update "$_vb" --assignee "$_sname" --status in_progress -q 2>/dev/null || true
    # Read it back. bd show --json may fail transiently; treat unreadable as a
    # mismatch so we retry rather than declaring success blindly.
    # NOTE: `bd show --json` returns a JSON ARRAY ([{...}]), not a bare object, so
    # a plain `.assignee` filter throws "Cannot index array" → jq exits non-zero →
    # _seen="" → the write reads back as [None] EVEN WHEN IT PERSISTED (the
    # false-alarm that masqueraded as a lost --assignee write, ga-vephl). Use the
    # array-safe `if type=="array" then .[0] else . end` pattern that the rest of
    # this dispatcher already uses for every other `bd show --json` parse.
    _seen=$(bd -C "$GC_CITY" show "$_vb" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .assignee // empty' 2>/dev/null || echo "")
    if [ "$_seen" = "$_sname" ]; then
      [ "$_try" -gt 1 ] && log "  Verdict-assign (${_ctx}): bead ${_vb} → ${_sname} verified on retry ${_try}."
      return 0
    fi
    [ "$_try" -lt 4 ] && sleep 1
  done
  warn "  Verdict-assign (${_ctx}): bead ${_vb} assignee read back as [${_seen:-None}], expected [${_sname}] after ${_try} attempts — durable pull channel DEGRADED (ga-mo7q). Labeling bead verdict:assignee-degraded (session_name-fallback + detector backstop)."
  bd -C "$GC_CITY" label add "$_vb" "verdict:assignee-degraded" -q 2>/dev/null || true
  return 1
}

# respawn_reviewer_slot <0-based idx> — re-spawn a fresh gate-reviewer session for
# a dead slot, REUSING the still-pending verdict bead VERDICT_BEAD_IDS[idx] and
# re-delivering the SAME stored review task REVIEW_TASKS[idx] (it already
# references the unchanged verdict bead). Updates SESSION_IDS[idx] in place.
# Returns 0 on a fresh spawn+nudge, 1 if the spawn itself failed (caller has
# already consumed budget so a permanent spawn failure stays bounded). Reuses the
# exact gate-reviewer template + independence model of the Step 7/8 spawn block;
# deliberately omits the spawn-abort escalation (that guards the INITIAL cohort —
# here the outer timeout + budget already bound the failure). No new verdict bead.
respawn_reviewer_slot() {
  local _idx="$1"
  local _rev=$(( _idx + 1 ))
  local _err_file="/tmp/gate-reviewer-respawn-err-$$.${_idx}"
  local _json _new_sid
  _json=$(gc --city "$GC_CITY" session new gate-reviewer \
    --no-attach \
    --title "gate-reviewer-${_rev} (re-convened): $BRANCH" \
    --json \
    2>"$_err_file" || echo "{}")
  rm -f "$_err_file" 2>/dev/null || true
  _new_sid=$(echo "$_json" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  if [ -z "$_new_sid" ]; then
    warn "  Re-convene: failed to spawn replacement reviewer for slot ${_idx} — slot stays dead; outer timeout is the backstop."
    return 1
  fi
  SESSION_IDS[$_idx]="$_new_sid"
  # ── ga-vdurb (PRIMARY FIX): re-point the DURABLE PULL channel at the NEW
  # session. The initial-spawn block (~Step 7/8) assigned this slot's verdict bead
  # VERDICT_BEAD_IDS[_idx] to the FIRST session's NAME; that session is now dead,
  # so the reviewer's `gc bd list --assignee=$GC_SESSION_NAME` poll on the fresh
  # session matched NOTHING and it stood down as "unused" → 0 verdicts. Re-assign
  # the SAME (still-pending) verdict bead to the NEW session's NAME so the durable
  # channel survives the re-convene; the nudge/submit below stays the fast-path.
  # We must use the session NAME (what --assignee + the reviewer's poll key on),
  # NOT the session id — extract it from the same spawn JSON the id came from.
  _new_sname=$(echo "$_json" | jq -r '.session_name // empty' 2>/dev/null || echo "")
  if [ -n "$_new_sname" ]; then
    assign_verdict_bead_verified "${VERDICT_BEAD_IDS[$_idx]}" "$_new_sname" "re-convene slot ${_idx}" || true
    # Re-embed the stored review task as a comment too (mirrors initial spawn:
    # the durable pull reads the task from the bead, independent of the nudge).
    bd -C "$GC_CITY" comment "${VERDICT_BEAD_IDS[$_idx]}" "${REVIEW_TASKS[$_idx]}" 2>/dev/null || true
    log "  Re-convene: verdict bead ${VERDICT_BEAD_IDS[$_idx]} re-assigned to NEW session name ${_new_sname} (durable pull re-pointed, ga-vdurb)."
  else
    warn "  Re-convene: spawn JSON had no session_name for slot ${_idx} — durable channel NOT re-pointed (verdict-poll + outer timeout backstop)."
  fi
  # ga-mepb0: the re-convened session must re-prove life. Clear its ACK flag so
  # the carried-over ACKED=1 from the since-replaced session cannot mask a fresh
  # boot-wedge. Index-assignment is safe even if the arrays are sparse.
  REVIEWER_ACKED[$_idx]=0
  gc --city "$GC_CITY" session wake "$_new_sid" 2>/dev/null || true
  # ga-67hae: pin the re-convened session for the same drain-exemption reason as
  # the initial spawn. A re-convened session is just as vulnerable to config-drift
  # drain as the first — without a pin it can be killed between its ACK and its
  # verdict submission, leaving the slot pending again and wasting a respawn budget.
  gc --city "$GC_CITY" session pin "$_new_sid" 2>/dev/null || true
  # ga-mepb0: snapshot a REAL peek baseline for the NEW session here (post-wake,
  # pre-delivery) — exactly as the initial spawn does. Do NOT leave it empty: an
  # empty baseline differs from the boot banner's non-empty cksum, so the very
  # next poll's soft late-ACK would fire on boot output alone and falsely mark a
  # re-wedged respawn ALIVE — sending it back to the 45m timeout this fix exists
  # to kill. With a real pre-delivery baseline, only output produced AFTER task
  # delivery (genuine sign of life) flips the ACK. `|| echo ""` keeps set -e safe;
  # an empty result here is the conservative case (no false ACK), still backed by
  # the verdict-progressed strong check.
  REVIEWER_PEEK_BASELINE[$_idx]=$(gc --city "$GC_CITY" session peek "$_new_sid" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
  if $GATE_NUDGE_TIMEOUT gc --city "$GC_CITY" session nudge "$_new_sid" "${REVIEW_TASKS[$_idx]}" --delivery queue 2>/dev/null; then
    log "  Re-convene: review task re-queued to fresh session ${_new_sid} (slot ${_idx}, verdict bead ${VERDICT_BEAD_IDS[$_idx]} reused)."
  elif $GATE_NUDGE_TIMEOUT gc --city "$GC_CITY" session submit "$_new_sid" "${REVIEW_TASKS[$_idx]}" 2>/dev/null; then
    log "  Re-convene: review task re-submitted to fresh session ${_new_sid} (slot ${_idx})."
  else
    warn "  Re-convene: queue/submit to fresh session ${_new_sid} failed (slot ${_idx}) — verdict-poll + outer timeout backstop."
  fi
  return 0
}

# ── ga-dupnv (bug 1): live-sibling-run guard — one branch = one authoritative run
# classify_sibling_run <found 0|1> <age_min> <ceiling> — PURE (no I/O, set -e
# safe), unit-tested by gate-dup-run-guard.selftest.sh. Decides what to do about
# another gate-status:running gate-run discovered on THIS branch:
#   none  — no sibling running for this branch → create our run normally.
#   live  — a sibling is running within the staleness ceiling → YIELD (the
#           existing run is authoritative; do NOT spawn a duplicate that could
#           later write a terminal FAIL over it).
#   stale — a sibling is running but OLDER than the ceiling: its dispatcher died
#           mid-run and never drove it terminal → supersede it and proceed.
# Unparseable / negative age ⇒ LIVE (conservative: never spawn a duplicate on a
# sibling we cannot PROVE stale).
classify_sibling_run() {
  local found="$1" age_min="$2" ceiling="$3"
  [ "$found" = "1" ] || { echo "none"; return 0; }
  case "$age_min" in ''|*[!0-9-]*) echo "live"; return 0 ;; esac
  case "$ceiling" in ''|*[!0-9]*)  echo "live"; return 0 ;; esac
  if [ "$age_min" -lt 0 ] 2>/dev/null; then echo "live"; return 0; fi
  if [ "$age_min" -le "$ceiling" ]; then echo "live"; else echo "stale"; fi
}

# live_sibling_run_for_branch <branch> — runtime resolver for the guard. Scans
# gate-status:running gate-runs, matches one whose description names THIS
# branch (the trailing "." anchors the match so "wa-86jr" never matches
# "wa-86jr-reland"), computes its age from started_at, and emits exactly one of:
#   ""  (no live/stale sibling) | "LIVE <id>" | "STALE <id>"
# ga-tgj23: every candidate ALSO requires status=open, checked explicitly here
# rather than assumed from the label query alone. set_gate_status transitions a
# bead's gate-status in TWO writes (remove old label, add new); a transient
# bd/Dolt failure on the remove can leave a stale gate-status:running label on an
# already-closed/superseded bead (the same leaked-label class documented at
# set_gate_status, ga-jhyu). `.status` is the single authoritative bd-native
# field for closed/open — checking it directly makes "closed is never live" true
# independent of label consistency. A candidate we can't confirm status=open for
# is treated as NOT live (skip): per the fail-safe below, a false-proceed here is
# caught by the terminal-time supersede safety net (one branch, one authoritative
# run), while a false-yield strands the marker for a full DISPATCHING_TTL cycle.
# FAIL-OPEN: any bd/jq/date failure yields "" so a transient glitch can NEVER
# block a legitimate run (identical to the pre-guard behavior). The decision it
# defers to (classify_sibling_run) is the pure, unit-tested core.
#
# ga-f1ngu: the description match below ("Autonomous gate run for X.") is this
# dispatcher's OWN Step 6 template text — it never matches the guard's
# claim-receipt bead (quality-gate-guard.sh Step 6, description "Quality gate
# run for branch X."). That text mismatch is exactly why this guard used to be
# blind to the guard's claim receipt, letting a second (real) run get created
# right on top of it (the "same marker generates 2 runs" bug). The actual fix
# was NOT to make the text match here — that would make the dispatcher yield
# to the claim receipt as a perpetually-"live" sibling forever, since nothing
# in this run's own lifecycle ever ages it out, permanently stalling dispatch
# for every marker. The real fix was to stop the claim receipt from claiming
# gate-status:running at all (it is now gate-status:claimed), so it is
# correctly excluded up front by THIS function's own bd query, for the right
# reason instead of an accidental one.
live_sibling_run_for_branch() {
  local branch="$1" now_epoch run_json count i id status desc started started_epoch age_min verdict
  [ -z "$branch" ] && return 0
  now_epoch=$(date +%s)
  # ga-h199q: NOT routed through the read-cache shim (unlike the 3 siblings of
  # this exact query below) — gate-dup-run-guard.selftest.sh mocks `bd` as an
  # in-shell function; the shim's `bash bd-list-cached.sh` spawns a child
  # process that cannot see that function (bash doesn't inherit unexported
  # shell functions across a `bash script.sh` invocation), so caching this
  # specific call site silently breaks that selftest's live-behavior coverage.
  # Left live deliberately; see ga-h199q comment on the other 3 call sites for
  # why THIS EXACT query is still cached elsewhere (verified byte-identical
  # results; here it just could not be, given the test's mocking strategy).
  run_json=$(bd -C "$GC_CITY" list --json \
    -l type:quality-gate-run \
    -l gate-status:running \
    2>/dev/null || echo "[]")
  count=$(printf '%s\n' "$run_json" | jq 'length' 2>/dev/null || echo 0)
  case "$count" in ''|*[!0-9]*) return 0 ;; esac
  [ "$count" = 0 ] && return 0
  for i in $(seq 0 $((count - 1))); do
    id=$(printf '%s\n' "$run_json" | jq -r ".[$i].id // empty" 2>/dev/null || echo "")
    [ -z "$id" ] && continue
    status=$(printf '%s\n' "$run_json" | jq -r ".[$i].status // \"\"" 2>/dev/null || echo "")
    [ "$status" = "open" ] || continue   # closed/superseded/errored sibling is NEVER live
    desc=$(printf '%s\n' "$run_json" | jq -r ".[$i].description // \"\"" 2>/dev/null || echo "")
    printf '%s\n' "$desc" | grep -qF "Autonomous gate run for ${branch}." || continue
    started=$(printf '%s\n' "$desc" | grep -E '^started_at:' | head -1 | sed 's/^started_at: *//' || true)
    if [ -z "$started" ]; then echo "LIVE $id"; return 0; fi   # no ts → conservative LIVE
    started_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${started%%Z*}" "+%s" 2>/dev/null \
      || date -d "$started" +%s 2>/dev/null || echo 0)
    if [ "$started_epoch" -le 0 ] 2>/dev/null; then echo "LIVE $id"; return 0; fi
    age_min=$(( (now_epoch - started_epoch) / 60 ))
    verdict=$(classify_sibling_run 1 "$age_min" "$SIBLING_RUN_STALE_MINUTES")
    case "$verdict" in
      live)  echo "LIVE $id";  return 0 ;;
      stale) echo "STALE $id"; return 0 ;;
    esac
  done
  return 0
}

# ── ga-rstw5: bare-mirror reconcile to origin (durable-landing false-FAIL fix) ─
# Container rigs keep a bare .repo.git whose OWN refs/heads/<main> a `git push` to
# origin never advances. When that bare ref drifts/forks from origin/<main> — the
# canonical durable line the gate merge pushes to — the durable-landing step used
# to FF-only-or-FAIL, flipping an all-PASS verdict to failed_durable_not_ff the
# moment the bare ref had FORKED (WA's orphan 'preserve' 9c8c8a20 from the
# gt-fc02b7 decommission). The merge DID land on origin; the bare mirror must just
# track it. These two functions (a pure decision + its git plumbing) are defined
# BEFORE the lib-only guard so gate-durable-landing-reconcile.selftest.sh can
# exercise both with real temp repos — single source of truth, no copy-drift.

# reconcile_main_action <local_sha> <origin_sha> <local_anc_origin 0|1> <origin_anc_local 0|1>
#   Pure (no IO, set -e safe). Echoes the ref move that makes the bare mirror track
#   origin, given the ancestry relationship:
#     noop      — already equal, OR bare strictly AHEAD of origin (extra local-only
#                 commits we must NOT discard), OR origin unresolvable (safety).
#     ff        — bare absent or strictly BEHIND origin (ancestor) → advance to origin.
#     reconcile — FORKED (neither is the other's ancestor) → reset bare to origin
#                 (canonical), preserving the forked tip under a backup ref.
reconcile_main_action() {
  local lsha="$1" osha="$2" local_anc_origin="$3" origin_anc_local="$4"
  [ -z "$osha" ] && { echo "noop"; return 0; }
  [ -z "$lsha" ] && { echo "ff"; return 0; }
  [ "$lsha" = "$osha" ] && { echo "noop"; return 0; }
  [ "$local_anc_origin" = "1" ] && { echo "ff"; return 0; }
  [ "$origin_anc_local" = "1" ] && { echo "noop"; return 0; }
  echo "reconcile"
}

# reconcile_bare_main_to_origin <bare_git_dir> <branch>
#   Git plumbing around reconcile_main_action. Fetches origin/<branch> into the
#   bare repo, classifies ancestry, and applies the decided ref move. FF-safe and
#   idempotent (noop when already tracking); only a FORKED ref is rewritten, and
#   only ever TO origin — the forked tip is first saved under
#   refs/heads/_backup-forked-<branch>-<sha> for forensics. Echoes a one-token
#   outcome (noop:* | ff:* | reconcile:* | fetch-failed | origin-unresolved |
#   updateref-failed); returns 0 on success/no-op, 1 on a hard git failure.
#   set -e safe: every git call is wrapped in `if`/`||` so a non-zero exit (e.g.
#   is-ancestor=false) never trips the shell, and callers capture rc via `|| rc=$?`.
reconcile_bare_main_to_origin() {
  local gdir="$1" branch="$2"
  if ! git --git-dir="$gdir" fetch origin "$branch" --quiet 2>/dev/null; then
    if ! git --git-dir="$gdir" fetch origin --quiet 2>/dev/null; then
      echo "fetch-failed"; return 1
    fi
  fi
  local osha lsha
  osha=$(git --git-dir="$gdir" rev-parse --verify -q "origin/$branch^{commit}" 2>/dev/null || echo "")
  [ -z "$osha" ] && { echo "origin-unresolved"; return 1; }
  lsha=$(git --git-dir="$gdir" rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null || echo "")
  local la=0 oa=0
  if [ -n "$lsha" ]; then
    if git --git-dir="$gdir" merge-base --is-ancestor "$lsha" "$osha" 2>/dev/null; then la=1; fi
    if git --git-dir="$gdir" merge-base --is-ancestor "$osha" "$lsha" 2>/dev/null; then oa=1; fi
  fi
  local action
  action=$(reconcile_main_action "$lsha" "$osha" "$la" "$oa")
  case "$action" in
    noop)
      echo "noop:${lsha:-<none>}"; return 0 ;;
    ff)
      if ! git --git-dir="$gdir" update-ref "refs/heads/$branch" "$osha" 2>/dev/null; then
        echo "updateref-failed"; return 1
      fi
      echo "ff:${lsha:-<none>}->$osha"; return 0 ;;
    reconcile)
      git --git-dir="$gdir" update-ref "refs/heads/_backup-forked-${branch}-${lsha}" "$lsha" 2>/dev/null || true
      if ! git --git-dir="$gdir" update-ref "refs/heads/$branch" "$osha" 2>/dev/null; then
        echo "updateref-failed"; return 1
      fi
      echo "reconcile:${lsha}->${osha}(backup:_backup-forked-${branch}-${lsha})"; return 0 ;;
  esac
}

# ── ga-nooaw: fail-closed-by-SHA helpers ──────────────────────────────────────
# A gate FAIL must hold the commit: production observed a later, independent
# gate-run PASS a commit SHA an earlier run had already rejected, and merge it
# (wa-zmw4r / commit afb59120 — the bead ended up carrying gate:failed AND
# gate:passed AND story:done at once, since the PASS/FAIL labels are purely
# additive and neither write removes the other's). Fix: durably stamp the
# rejected SHA onto the source bead when a run FAILs, and refuse to merge any
# SHA that already carries that stamp, even when THIS run's own verdict is
# PASS. Only a NEW commit (new BRANCH_SHA — an actual code change) is unstamped
# and can re-gate normally. These three functions (a label-naming helper, a
# pure decision, and its bd plumbing) are defined BEFORE the lib-only guard so
# gate-sha-fail-lock.selftest.sh can exercise all three directly — single
# source of truth, no copy-drift between the write site (FAIL path) and the
# read site (pre-merge check).

# gate_sha_fail_label <sha> — canonical label naming the "this SHA already
# failed" stamp. Pure string formatting; the ONLY place this label's shape is
# spelled out, so the write and read sites can never drift apart.
gate_sha_fail_label() {
  printf 'gate-sha-failed:%s' "$1"
}

# gate_labels_have_sha_fail <space_joined_labels> <sha> — pure (no IO, set -e
# safe). Prints "yes" iff the label set already carries gate_sha_fail_label(sha).
gate_labels_have_sha_fail() {
  local hay=" $1 " needle
  needle=" $(gate_sha_fail_label "$2") "
  case "$hay" in
    *"$needle"*) printf 'yes' ;;
    *)           printf 'no' ;;
  esac
}

# gate_bead_has_prior_sha_fail <bead_city> <bead_id> <sha> — bd-backed. Prints
# "yes" iff $bead_id already has a gate-sha-failed stamp for this exact $sha,
# i.e. an EARLIER, already-terminal gate-run rejected this commit. Deliberately
# reads `bd show` directly rather than through bd-list-cached.sh: this gates a
# hard-to-reverse merge decision and must see live state, not a stale cache
# (same freshness reasoning as the other gate-critical reads left uncached
# elsewhere in this file, e.g. ga-xwza2). FAIL-OPEN on any bd/jq error ("no")
# so a transient Dolt hiccup can never permanently wedge a legitimately-fixed
# branch — the worst case on a hiccup is identical to pre-fix behavior.
gate_bead_has_prior_sha_fail() {
  local city="$1" bead="$2" sha="$3" labels
  if [ -z "$bead" ] || [ -z "$sha" ]; then
    printf 'no'
    return 0
  fi
  labels=$(bd -C "$city" show "$bead" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "")
  gate_labels_have_sha_fail "$labels" "$sha"
}

# ── ga-lxz5w: SAME-BEAD SIBLING-BRANCH + LATE-HOLD pre-merge checks ───────────
# Real incident: bead wa-fnibd had 2 builders. wa-worker's branch built an
# INCOMPLETE fix; crew/oracle's branch (a different SHA, same bead) was the
# COMPLETE superset. Oracle held the bead with gate:needs-human, but the
# incomplete branch merged anyway — the gate never checked for (a) another
# branch still active for the same source bead, or (b) a park-worthy label
# applied to the bead AFTER this run's own review began. Both checks below
# are inserted just before the ga-nooaw SHA-fail check's merge gate, downgrade
# an in-flight PASS to FAIL, and fall through to the existing FAIL path
# unchanged — identical shape to gate_bead_has_prior_sha_fail above.

# gate_active_gate_statuses — space-joined gate-status values meaning "still
# actively pursuing a merge" (not yet terminal). Single source of truth so the
# pure/resolver pair below can't silently drift on what counts as "active".
gate_active_gate_statuses() {
  printf 'ready queued claimed dispatching running needs-rebase'
}

# gate_is_active_gate_status <status> — pure. "yes" iff $status is one of
# gate_active_gate_statuses(); "no" for any terminal status (passed/failed/
# superseded/error/aborted/deferred/parked-needs-human) or empty/unknown input.
gate_is_active_gate_status() {
  case " $(gate_active_gate_statuses) " in
    *" $1 "*) printf 'yes' ;;
    *)        printf 'no' ;;
  esac
}

# gate_pick_active_sibling <branch_TAB_status_lines> <this_branch> — pure (no
# IO, set -e safe). Each input line is "<branch><TAB><gate-status-value>" for
# one marker/gate-run tied to the same source bead. Prints the FIRST line
# whose branch differs from $this_branch AND whose status is active — i.e. a
# genuinely CONCURRENT competitor. Same-branch rows are always this run's own
# earlier state, never a sibling (a `-reland` resubmission always gets a NEW
# branch name — see ga-dupnv's Step 5b comment for why branch, not bead, is
# the right key: same-bead-different-branch-over-time is a legitimate,
# non-conflicting, sequential case that must NOT be flagged here). Prints ""
# if no active sibling is found.
gate_pick_active_sibling() {
  local lines="$1" this_branch="$2" branch status
  while IFS=$'\t' read -r branch status; do
    [ -z "$branch" ] && continue
    [ "$branch" = "$this_branch" ] && continue
    if [ "$(gate_is_active_gate_status "$status")" = "yes" ]; then
      printf '%s\t%s' "$branch" "$status"
      return 0
    fi
  done <<EOF
$lines
EOF
  printf ''
}

# gate_bead_active_sibling_branch <gc_city> <bead_id> <this_branch> — bd-
# backed. Prints "<branch><TAB><status>" of another branch's marker/gate-run
# currently active for the SAME source bead, or "" if none. Queries the HQ
# city (source-bead: labels are always written there by gate-done.md and
# Step 6, regardless of which rig bead_id itself lives in) — pass gc_city,
# never bead_city. A gate-run bead has no branch: LABEL (only a marker does —
# gate-done.md Step 3); it carries the branch in its description instead
# (Step 6, "branch: $BRANCH"), so the label is tried first, description second
# — mirrors the established extract()-from-description convention (see
# docs/gate-marker-recipe.md) rather than a single brittle inline jq regex.
# Deliberately reads live (no bd-list-cached.sh) — same freshness reasoning as
# gate_bead_has_prior_sha_fail above: this gates a hard-to-reverse merge
# decision. FAIL-OPEN ("" / no sibling found) on any bd/jq error or missing
# fields — identical rationale as the SHA-fail check: a transient hiccup must
# never permanently wedge a legitimately-solo branch.
gate_bead_active_sibling_branch() {
  local gc_city="$1" bead_id="$2" this_branch="$3"
  local siblings_json count i sib marker_status labels desc branch status lines sib_id
  if [ -z "$bead_id" ] || [ -z "$this_branch" ]; then
    printf ''
    return 0
  fi
  siblings_json=$(bd -C "$gc_city" list --label "source-bead:$bead_id" --all --json 2>/dev/null || echo "[]")
  if [ -z "$siblings_json" ] || [ "$siblings_json" = "null" ]; then siblings_json="[]"; fi
  count=$(printf '%s' "$siblings_json" | jq 'length' 2>/dev/null || echo "0")
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" = "0" ]; then
    printf ''
    return 0
  fi
  lines=""
  for i in $(seq 0 $((count - 1))); do
    sib=$(printf '%s' "$siblings_json" | jq ".[$i]" 2>/dev/null) || continue
    # A closed marker keeps its residual gate-status:* label forever (nothing
    # strips it on close) — that label alone would misread a discarded/
    # superseded submission as a live concurrent one (ga-4wncs). Skip on
    # lifecycle .status, not the label. Fail-open on jq error (marker_status
    # empty, not "closed") so a transient hiccup never hides a real sibling.
    marker_status=$(printf '%s' "$sib" | jq -r '.status // ""' 2>/dev/null || echo "")
    [ "$marker_status" = "closed" ] && continue
    labels=$(printf '%s' "$sib" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")
    branch=$(printf '%s\n' "$labels" | tr ' ' '\n' | sed -n 's/^branch:\(.*\)$/\1/p' | head -1)
    if [ -z "$branch" ]; then
      desc=$(printf '%s' "$sib" | jq -r '.description // ""' 2>/dev/null || echo "")
      branch=$(printf '%s\n' "$desc" | sed -n 's/^branch:[ \t]*\(.*\)$/\1/p' | head -1)
    fi
    [ -z "$branch" ] && continue
    status=$(printf '%s\n' "$labels" | tr ' ' '\n' | sed -n 's/^gate-status:\(.*\)$/\1/p' | head -1)
    if [ -z "$status" ]; then
      # ga-kgtiw: an OPEN marker/gate-run with a real branch but NO gate-status
      # label is the exact invisible-forever signature (every dispatcher sweep
      # selects its work via `-l gate-status:<value>`, so this sibling matches
      # none of them, ever). This scan is the one place in the dispatcher that
      # walks every marker for a bead regardless of its gate-status, so it is
      # the one place that can actually SEE the gap — surface it instead of
      # silently continuing past it like before. Written straight to stderr
      # (not via warn/log, which echo to stdout): this function's own return
      # value is captured via "$(...)" by every caller, and a stdout write
      # here would corrupt that captured string.
      printf '[%s] [quality-gate-dispatcher] ALERT: sibling marker %s (bead %s, branch %s) is OPEN with NO gate-status label — ga-kgtiw invisible-marker signature. Excluded from sibling-race detection; needs manual gate-status repair.\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${sib_id:-$(printf '%s' "$sib" | jq -r '.id // "unknown"' 2>/dev/null || echo unknown)}" "$bead_id" "$branch" >&2
      continue
    fi
    lines="${lines}${branch}	${status}
"
  done
  gate_pick_active_sibling "$lines" "$this_branch"
}

# gate_bead_live_merge_block <bead_city> <bead_id> — bd-backed. Re-reads the
# source bead's CURRENT status/labels, live, right before merge — the guard's
# check_source_bead_park() (sourced from quality-gate-guard.sh above) only
# ran ONCE, at marker-claim/submission time (Step 5a), long before this exact
# moment. A park-worthy label applied AFTER claim (a human/crew holding it
# mid-review), or the bead reaching `closed` entirely (already resolved by a
# sibling branch's own finalize — the sequential variant of the same 2-branch
# race), never re-blocked an already in-flight PASS. Reuses
# check_source_bead_park so the two check sites can never drift on what
# counts as a park-worthy label.
# Returns: ok | closed | park:needs-approval | park:needs-human
# FAIL-OPEN ("ok") on any bd/jq error or missing bead — identical rationale as
# guard.sh's own Step 5a: a lookup failure must never permanently block a
# legitimate PASS.
gate_bead_live_merge_block() {
  local bead_city="$1" bead_id="$2" raw status labels
  if [ -z "$bead_id" ]; then
    printf 'ok'
    return 0
  fi
  raw=$(bd -C "$bead_city" show "$bead_id" --json 2>/dev/null || echo "")
  if [ -z "$raw" ]; then
    printf 'ok'
    return 0
  fi
  status=$(printf '%s' "$raw" | jq -r 'if type=="array" then .[0] else . end | .status // ""' 2>/dev/null || echo "")
  if [ "$status" = "closed" ]; then
    printf 'closed'
    return 0
  fi
  labels=$(printf '%s' "$raw" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "")
  check_source_bead_park "$labels"
}

# ── ga-cw4pm: dynamic-concurrency headroom helpers ────────────────────────────
# Mirror the Pilot's Dolt-saturation probe (pilot-dispatcher.sh _dolt_cpu/
# _dolt_saturated) so the GATE throttles its OWN reviewer spawns the same way the
# Pilot throttles dispatch. All three are pure/near-pure and selftest-sourceable
# via GATE_DISPATCHER_LIB_ONLY (defined above this guard).

# gate_dolt_cpu <pid> → integer CPU% of the live dolt-server process, or "" if
# unknown. `ps` %cpu can exceed 100 (per-core); the fraction is stripped for -gt
# tests. Honors GATE_DOLT_CPU_OVERRIDE (selftest seam — no live `ps`). No mutation.
gate_dolt_cpu() {
  local _pid="${1:-}"
  if [ -n "${GATE_DOLT_CPU_OVERRIDE:-}" ]; then printf '%s' "$GATE_DOLT_CPU_OVERRIDE"; return 0; fi
  if [ -z "$_pid" ] || [ "$_pid" = "TEST" ]; then printf ''; return 0; fi
  # Dolt %cpu is violently bursty: the supervisor's per-rig full-table hydration
  # scan of hq.issues (all rows, 97% closed) spikes it 5%<->400% every few seconds
  # (ga-ftmci). A SINGLE ps sample makes the headroom gate DEFER on a transient
  # spike ~1 sweep in 4 even when the plane is calm at the median — the "gate keeps
  # failing" symptom. Sample 5x over ~2s and return the MEDIAN so the reading
  # reflects sustained load, not a spike instant. Genuinely-hot planes still read
  # hot (their median stays high, so booting reviewers are still protected).
  # GATE_DOLT_CPU_SAMPLES (space-separated) is a selftest seam bypassing live `ps`.
  local _raw
  if [ -n "${GATE_DOLT_CPU_SAMPLES:-}" ]; then
    _raw="$GATE_DOLT_CPU_SAMPLES"
  else
    local _n _s _acc=""
    for _n in 1 2 3 4 5; do
      _s=$(ps -o %cpu= -p "$_pid" 2>/dev/null | tr -d ' ' | cut -d. -f1)
      [ -n "$_s" ] && _acc="$_acc $_s"
      [ "$_n" -lt 5 ] && sleep 0.5
    done
    _raw="$_acc"
  fi
  printf '%s' "$_raw" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk '{a[NR]=$0} END{if(NR)print a[int((NR+1)/2)]}'
  return 0
}

# gate_effective_headroom_cpu <ambient_cpu> <now_cpu> → the CPU% the Step 0b-1
# headroom gate should judge the data plane by. The dispatcher runs ~30s of its
# OWN Dolt-heavy janitors (Step 0a TTL re-queue, Step 0a-2 reviewer-session reap,
# Step 0a-3 rig bare-main reconcile, Step 0b marker-find) BEFORE the headroom
# probe, so the post-janitor reading is inflated by this dispatcher's own burst.
# Live evidence (ga-bgvc0): ambient dolt %cpu = ~130-155% (WARM → ceiling 1 run,
# would admit) but the post-janitor reading = ~198-200% (HOT > GATE_DOLT_CPU_HOT)
# → headroom DEFERs ceiling=0 → 0 reviewers → markers never drain = a self-
# inflicted DEFER deadlock. The AMBIENT reading, sampled at sweep start before
# any janitor, reflects the real plane load reviewers face when they boot (this
# dispatcher's janitor burst is over by then). Prefer ambient; fall back to the
# post-janitor reading when ambient is absent (pgrep miss / headroom disabled) so
# behavior degrades to the legacy reading, never worse. Pure; set -e safe; no I/O.
gate_effective_headroom_cpu() {
  local _ambient="${1:-}" _now="${2:-}"
  if [ -n "$_ambient" ]; then printf '%s' "$_ambient"; return 0; fi
  printf '%s' "$_now"
}

# gate_quota_limited → "1" iff Claude quota is exhausted (a new run would burn
# into a hard limit), else "0". Uses the ga-wjlv9 ground-truth checker
# (claude-quota-check.sh --quiet, exit 2 = LIMITED) when it is deployed;
# FAIL-OPEN ("0") when the checker is absent or errors, so an unmerged dependency
# never wedges the gate. Honors GATE_QUOTA_OVERRIDE (selftest seam: "2"=limited,
# anything else=ok). Bounded by `timeout`. No mutation of gate state.
gate_quota_limited() {
  if [ -n "${GATE_QUOTA_OVERRIDE:-}" ]; then
    [ "$GATE_QUOTA_OVERRIDE" = "2" ] && { printf '1'; return 0; }
    printf '0'; return 0
  fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf '0'; return 0; }
  local _rc=0
  timeout 15 bash "$_qc" --quiet >/dev/null 2>&1 || _rc=$?
  # 2 = LIMITED (active exhaustion). 0 = ok. 1/other = the checker's own internal
  # error → fail-open (never block the gate on a flaky checker).
  [ "$_rc" = "2" ] && { printf '1'; return 0; }
  printf '0'; return 0
}

# gate_swap_free_mb → integer MB of free swap, or "" if unreadable. The Gas
# Town host fleet is macOS-only, so this reads `sysctl vm.swapusage` directly
# (no cross-platform fallback needed). Honors GATE_SWAP_FREE_OVERRIDE_MB
# (selftest seam — no live sysctl), matching the GATE_DOLT_CPU_OVERRIDE /
# GATE_QUOTA_OVERRIDE convention. Fail-soft: any parse failure returns ""
# rather than a wrong number — gate_headroom_decision treats an empty reading
# as no-signal (never blocks), the same contract as every other probe here.
# ga-92azu: this is the resource brake Mayor's review added — Dolt CPU/latency
# and Claude quota both bound the GATE's own load; neither says anything about
# whether the MACHINE has room for one more live Claude session.
gate_swap_free_mb() {
  if [ -n "${GATE_SWAP_FREE_OVERRIDE_MB:-}" ]; then printf '%s' "$GATE_SWAP_FREE_OVERRIDE_MB"; return 0; fi
  local _raw
  _raw=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*free *= *\([0-9.]*\)M.*/\1/p')
  [ -n "$_raw" ] || { printf ''; return 0; }
  awk -v v="$_raw" 'BEGIN{printf "%d", v}' 2>/dev/null
  return 0
}

# ── ga-x3nmz: quota-aware verdict resolution ──────────────────────────────────
# gate_quota_stop_verdict <quota_limited 0|1> → "requeue" | "proceed"
# PURE (no IO, set -e safe). A reviewer that stalls or times out with NO
# substantive verdict is a QUOTA-STOP — its Claude session died on "you've hit
# your session limit" — iff the 5h window is exhausted RIGHT NOW. In that case
# the marker must be RE-QUEUED (re-run post-reset; the ga-cw4pm headroom gate
# holds it deferred until the window resets), NEVER false-FAILed. Otherwise the
# stall is a genuine boot/infra problem and the caller proceeds with its FAIL.
gate_quota_stop_verdict() {
  [ "${1:-0}" = "1" ] && { printf 'requeue'; return 0; }
  printf 'proceed'; return 0
}

# quota_reset_eta → echoes a short human ETA like "resets 4:50pm (in 37min)", or
# "" when unknown. Reads the ga-wjlv9 checker JSON (reset_time_text +
# reset_in_minutes). Honors GATE_QUOTA_ETA_OVERRIDE (selftest seam). Bounded by
# `timeout`; fail-soft to "" so a flaky/absent checker only costs the ETA string,
# never the re-queue itself. Pure-ish (read-only; no gate-state mutation).
quota_reset_eta() {
  if [ -n "${GATE_QUOTA_ETA_OVERRIDE:-}" ]; then printf '%s' "$GATE_QUOTA_ETA_OVERRIDE"; return 0; fi
  local _qc="${GC_CITY}/scripts/claude-quota-check.sh"
  [ -x "$_qc" ] || { printf ''; return 0; }
  local _j; _j=$(timeout 15 bash "$_qc" --json 2>/dev/null || echo "")
  [ -n "$_j" ] || { printf ''; return 0; }
  printf '%s' "$_j" | jq -r '
    if (.reset_time_text // "") == "" then ""
    else "resets " + .reset_time_text
         + ( if (.reset_in_minutes // null) != null then " (in \(.reset_in_minutes)min)" else "" end )
    end' 2>/dev/null || printf ''
}

# gate_headroom_decision <cpu> <lat_ms> <quota_limited 0|1> <inflight_reviewers> \
#   <cpu_hot> <cpu_warm> <lat_hot_ms> <max_reviewers> <reviewers_per_run> <failopen 0|1> \
#   [<swap_free_mb> <swap_floor_mb>]
# → echoes "<verdict> <ceiling> <reason>"  (verdict ∈ admit|defer).
# PURE; no I/O; set -e safe. Computes a DYNAMIC ceiling on concurrent reviewer
# sessions from Dolt health + quota + machine resource headroom, then admits a
# NEW run iff it fits under it:
#   quota-limited              → ceiling 0   (defer; never burn into a hard limit)
#   swap < floor (ga-92azu)    → ceiling 0   (defer; the MACHINE has no room for
#                                             one more live session — see § 1b)
#   Dolt hot (cpu>hot|lat>hot) → ceiling 0   (defer; open NO run on a hot plane → AC1/AC3)
#   no signal + failopen=0     → ceiling 0   (defer; conservative)
#   no signal + failopen=1     → ceiling max (proceed; a wedged probe must never deadlock the gate)
#   Dolt warm (cpu>warm)       → ceiling = reviewers_per_run (exactly ONE run; 2nd waits)
#   Dolt calm                  → ceiling = max_reviewers (scale up to the static cap → AC2)
# admit iff inflight + reviewers_per_run <= ceiling. swap_free_mb/swap_floor_mb
# are OPTIONAL trailing args — default "" (no signal, never blocks) so every
# existing 10-arg call site (including this selftest's HD() helper) keeps
# working unchanged.
gate_headroom_decision() {
  local cpu="$1" lat="$2" qlim="$3" inflight="$4"
  local cpu_hot="$5" cpu_warm="$6" lat_hot="$7" maxr="$8" perrun="$9" failopen="${10}"
  local swap_free="${11:-}" swap_floor="${12:-}"
  case "$cpu"      in ''|*[!0-9]*) cpu="" ;; esac
  case "$lat"      in ''|*[!0-9]*) lat="" ;; esac
  case "$inflight" in ''|*[!0-9]*) inflight=0 ;; esac
  case "$cpu_hot"  in ''|*[!0-9]*) cpu_hot=180 ;; esac
  case "$cpu_warm" in ''|*[!0-9]*) cpu_warm=100 ;; esac
  case "$lat_hot"  in ''|*[!0-9]*) lat_hot=2500 ;; esac
  case "$maxr"     in ''|*[!0-9]*) maxr=6 ;; esac
  case "$perrun"   in ''|*[!0-9]*) perrun=3 ;; esac
  case "$swap_free"  in ''|*[!0-9]*) swap_free="" ;; esac
  case "$swap_floor" in ''|*[!0-9]*) swap_floor="" ;; esac

  # 1. Quota hard-stop — independent of Dolt.
  if [ "$qlim" = "1" ]; then echo "defer 0 quota-limited"; return 0; fi

  # 1b. Low free swap — independent RESOURCE hard-stop (ga-92azu, added on
  # Mayor's review of this bead). The Dolt/quota checks above bound the GATE's
  # OWN load; neither says anything about whether the MACHINE has room for one
  # more live Claude session. Measured 2026-08-05: 13 unrelated sessions had
  # already consumed ~20.5 of 21.5GB swap (819MB free, 96% used) — scaling the
  # ceiling to 6 there would not drain the queue faster, it would thrash the
  # whole box (every process on it, not just the gate's reviewers), which is
  # worse than a slow queue. Same fail-open contract as every other probe
  # here: only a POSITIVELY-measured low reading blocks; a missing/unparseable
  # one never does. Deliberately NO in-flight==0 floor (unlike dolt-hot's § 2
  # below): that floor exists because dolt-hot load is self-inflicted by the
  # gate's OWN reviewers, so "the gate owns none of it while idle" holds and
  # justifies always allowing one. Swap pressure here comes from OTHER
  # processes the gate does not control and cannot shed by having opened zero
  # runs — idle is not evidence the machine can absorb a new one.
  #
  # GATE_SWAP_FREE_FLOOR_MB default (512) is calibrated BELOW the 819-961MB
  # range actually observed 2026-08-05, not above it: Mayor's own math sized
  # ONE new reviewer at ~250-300MB (145MB RSS + aux), and objected specifically
  # to jumping straight to 6 (+5 sessions, ~1.25-1.5GB) against 819MB free — not
  # to admitting one more. A floor near 1GB would defer EVERY admission at
  # today's readings, turning "stop wasting 2/3 of the ceiling" into "stop the
  # gate entirely" — a regression, not the fix. 512MB leaves room for a couple
  # more sessions' worth of margin below what was actually measured, so it does
  # not trip on typical readings, while a real slide toward exhaustion still
  # hits it (each admitted run consumes real RSS, so the ratchet in § 3 below
  # self-limits as swap actually drains — it does not require this floor to be
  # high to be protective).
  if [ -n "$swap_free" ] && [ -n "$swap_floor" ] \
     && [ "$swap_free" -lt "$swap_floor" ] 2>/dev/null; then
    echo "defer 0 swap-low"; return 0
  fi

  # 2. Dolt state from whatever signals we have.
  local have=0 hot=0 warm=0
  if [ -n "$cpu" ]; then have=1; [ "$cpu" -gt "$cpu_hot" ] 2>/dev/null && hot=1; fi
  if [ -n "$lat" ]; then have=1; [ "$lat" -gt "$lat_hot" ] 2>/dev/null && hot=1; fi
  if [ "$hot" = "0" ] && [ -n "$cpu" ] && [ "$cpu" -gt "$cpu_warm" ] 2>/dev/null; then warm=1; fi

  local ceiling reason
  if [ "$have" = "0" ]; then
    if [ "$failopen" = "1" ]; then ceiling="$maxr"; reason="no-signal-failopen"
    else echo "defer 0 no-signal-failclosed"; return 0; fi
  elif [ "$hot" = "1" ]; then
    # ga-q4gqq: "hot → open no run" presumes the gate is PART of the load it is
    # waiting out. That holds only while it has runs in flight. With in-flight
    # == 0 the gate owns none of the load, so deferring sheds nothing — the
    # ceiling=0 becomes a self-deadlock that clears only if some UNRELATED
    # process happens to go quiet. Measured 2026-07-30: 37 sweeps deferred at
    # ceiling=0 with in-flight=0, while the per-session `gc nudge` 2s poll
    # (~47% of Dolt load, ga-yxuab) held ambient CPU over the hot threshold.
    # Floor of exactly ONE run: turns an unbounded stall into bounded slowness
    # without ever exceeding one run while hot (in-flight>0 still defers below).
    # NOTE: deliberately NOT applied to quota-limited above — an exhausted 5h
    # window is a hard limit, and admitting there burns the run into a
    # quota-stop re-queue (ga-x3nmz). Dolt-hot is a soft signal; quota is not.
    if [ "$inflight" -eq 0 ] 2>/dev/null; then
      ceiling="$perrun"; reason="dolt-hot-floor"
    else
      echo "defer 0 dolt-hot"; return 0
    fi
  elif [ "$warm" = "1" ]; then
    ceiling="$perrun"; reason="dolt-warm"
  else
    ceiling="$maxr"; reason="dolt-calm"
  fi

  # 3. Admission: does ONE new run (perrun reviewers) fit under the ceiling?
  if [ "$(( inflight + perrun ))" -le "$ceiling" ] 2>/dev/null; then
    echo "admit $ceiling $reason"
  else
    echo "defer $ceiling ${reason}-cap-reached"
  fi
  return 0
}

# ── Single-instance lock (ported VERBATIM from pilot-dispatcher.sh, ga-7s0or) ──
# launchd fires this dispatcher every ~2 min, but a gate sweep can run up to the
# verdict timeout (~22 min). With no guard, 2-3 sweeps overlap and EACH runs the
# bd-heavy preamble (Step 0a TTL recovery, Step 0a-2 orphan-reviewer reap, the
# headroom probe, and multiple `bd list --json --all` scans) concurrently → a
# ~17-connection Dolt spike exactly as reviewers boot → reviewers stall/die →
# 22-min verdict timeout → FAIL storm. This lock collapses concurrent sweeps to
# one and removes that boot spike.
#
# Mechanism is the pilot's PROVEN fd-LESS lock, copied verbatim:
#   • an atomic `mkdir` mutex (POSIX-atomic; no fd, no inheritance — a leaked fd
#     can never keep a directory "locked", so the old flock-inode leak that
#     deadlocked the pilot for 5h+ cannot recur), plus
#   • a heartbeat file whose MTIME, written at acquire, marks liveness.
# A held lock whose heartbeat mtime is older than GATE_LOCK_MAX_AGE is a dead/
# zombie holder (a SIGKILLed/OOMed sweep leaves the dir but stops refreshing it)
# and is recovered AUTOMATICALLY, WITHOUT rm of any flock inode — this is the
# anti-wedge guarantee. PID-liveness is deliberately NOT used (PID recycling =
# TOCTOU false-"alive", per ga-7s0or AC). Recovery is gated by an atomic sentinel
# (`mkdir "$GATE_LOCK_DIR.reaping"` — one winner system-wide) and takes the stale
# dir over IN PLACE, so two concurrent recoverers can never both proceed and no
# dir-absent window is ever exposed to a racing acquirer (ga-T1 #4). A LIVE sweep
# keeps its heartbeat fresh by re-stamping it each verdict poll (ga-T1 #1), so
# MAX_AGE only ever reclaims a TRULY dead holder. Defined BEFORE the lib-only
# early-return so the lock selftest can source and drive these functions in
# isolation (mirrors spawn_abort_should_page).
#
# Distinct lock path from the pilot so the two dispatchers never share a lock.
# Kill-switch: GATE_LOCK_ENABLED=0 → legacy (unlocked) behaviour, no redeploy.
GATE_LOCK_ENABLED="${GATE_LOCK_ENABLED:-1}"
GATE_LOCK_DIR="${TMPDIR:-/tmp}/quality-gate-dispatcher$(printf '%s' "$GC_CITY" | tr '/ ' '__').lock.d"
GATE_LOCK_HB="$GATE_LOCK_DIR/heartbeat"
# A real gate sweep can legitimately run to the verdict timeout (~22m); 1800s
# (30 min) is a margin past that which still reclaims a wedged holder within a
# few launchd intervals.
GATE_LOCK_MAX_AGE="${GATE_LOCK_MAX_AGE:-1800}"
# ga-309v3: INHERITABLE across a multi-admit re-exec. A continuation round
# (GATE_ADMIT_ROUND>0) re-execs this same script to admit another marker under
# the SAME lock acquisition; it must present the SAME token or _release_gate_lock
# would refuse to free the lock at the end (token mismatch) and wedge the gate
# until GATE_LOCK_MAX_AGE. `exec` preserves $$, so the pid half stays valid too.
# Unset (the normal launchd entry) => identical to the previous behaviour.
GATE_LOCK_TOKEN="${GATE_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"
# ...but an inherited token is only OURS if its pid half is this process. `exec`
# preserves $$, so a genuine continuation always passes; any DESCENDANT (the
# gate-reviewer sessions a round spawns inherit the exported var, and an agent
# in one may later run this dispatcher by hand) gets a fresh token instead.
# WITHOUT this, the descendant fails the skip-acquire guard, correctly falls
# through to _acquire_gate_lock, and then writes the INHERITED token as the
# heartbeat — advertising a holder pid that is long dead while it is very much
# alive. The next sweep's _gate_lock_holder_dead reads that dead pid, declares
# the lock stale, and RECLAIMS IT FROM THE LIVE HOLDER: two concurrent sweeps,
# concurrent claims, concurrent merges — the ga-7s0or/ga-T1 class. Self-validating
# here means acquire, release AND holder-dead all agree everywhere, so this line
# is the keystone, not the 4-way guard further down.
[ "${GATE_LOCK_TOKEN%%:*}" = "$$" ] || GATE_LOCK_TOKEN="$$:${RANDOM}${RANDOM}"

# ── ga-309v3: multi-admit rounds ──────────────────────────────────────────────
# A sweep admits at most ONE marker (Step 0b picks `.[0]`), so with runs lasting
# 11-17min and a sweep cadence of 4-6min the number of CONCURRENT runs settles at
# ~1-2 no matter how high the Step 0b-1 headroom ceiling is — the ceiling is never
# fed fast enough to be reached. Measured 2026-08-06: ceiling=6 with a sustained
# observed concurrency of exactly 1.
#
# Instead of wrapping Step 0b..Step 8 (~2400 lines, dozens of globals) in a loop —
# where any conditionally-skipped reassignment would leak state from marker A into
# marker B and merge the WRONG branch — a continuation round RE-EXECS this script.
# exec replaces the process image, so every global is reset by construction and
# cross-round leakage is impossible. The lock is carried over deliberately (see
# GATE_LOCK_TOKEN above) so the whole burst stays ONE logical sweep.
#
# Each round re-runs the full Step 0b-1 headroom probe on its own, so a data plane
# that heats up mid-burst stops admitting immediately — the round counter is a
# hard ceiling, not the only brake. A round with no queued marker simply exits at
# Step 0b, so the burst self-terminates.
GATE_MAX_ADMITS_PER_SWEEP="${GATE_MAX_ADMITS_PER_SWEEP:-3}"
case "$GATE_MAX_ADMITS_PER_SWEEP" in ''|*[!0-9]*) GATE_MAX_ADMITS_PER_SWEEP=3 ;; esac
# Strip leading zeros BEFORE any arithmetic: bash reads 010 as OCTAL, and an
# 08/09 is a hard $(( )) error — which, at the re-exec site, would die AFTER
# `trap - EXIT` and leak the lock. 10# would also work but breaks on empty.
#
# `^0*\([0-9]\)` — NOT `^0*` — deliberately KEEPS the final digit, so a literal
# "0" survives as 0 and the `-ge 1` clamp below turns it into 1 (burst off). A
# bare `^0*` maps "0" to the empty string, the `:=3` default then fires, and an
# operator typing the universal off-switch into the plist during an incident
# would silently get the MAXIMUM burst instead. Inverting a kill switch is worse
# than not having one.
GATE_MAX_ADMITS_PER_SWEEP=$(printf '%s' "$GATE_MAX_ADMITS_PER_SWEEP" | sed 's/^0*\([0-9]\)/\1/'); : "${GATE_MAX_ADMITS_PER_SWEEP:=3}"
[ "$GATE_MAX_ADMITS_PER_SWEEP" -ge 1 ] 2>/dev/null || GATE_MAX_ADMITS_PER_SWEEP=1
# Upper clamp: this knob multiplies concurrent reviewer spawns inside ONE lock
# hold. A typo (30, or a seconds value pasted into the wrong knob) would admit
# far past the gate-reviewer template's max_active_sessions and trip ga-zl277.
# 6 == GATE_MAX_REVIEWERS, the most the headroom ceiling can ever allow anyway.
[ "$GATE_MAX_ADMITS_PER_SWEEP" -le 6 ] 2>/dev/null || GATE_MAX_ADMITS_PER_SWEEP=6
GATE_ADMIT_ROUND="${GATE_ADMIT_ROUND:-0}"
case "$GATE_ADMIT_ROUND" in ''|*[!0-9]*) GATE_ADMIT_ROUND=0 ;; esac

# ga-991au: TWO counters, because a round and an admit stopped being the same
# thing once skip-rounds exist. Conflating them broke two separate invariants:
#   · a skip round admitted NOTHING, yet the LIVE_REVIEWERS add-back below is
#     "reviewers this burst already spawned" — charging it for skips invents
#     phantom reviewers. On the CALM path over-counting merely defers earlier
#     (safe), but on the HOT path gate_headroom_decision only admits when
#     inflight==0 (the ga-q4gqq dolt-hot-floor, added because 37 sweeps
#     self-deadlocked at ceiling=0), so ONE phantom flips admit -> defer and
#     neutralises this fix in exactly the degraded state it targets.
#   · GATE_MAX_ADMITS_PER_SWEEP is documented and clamped as an ADMISSION cap
#     (<=6 == GATE_MAX_REVIEWERS). Letting skips consume it means two yields
#     end a sweep having admitted nothing while the log reads "round 2/3".
# So: GATE_ADMITS_DONE counts real admits (bounds spawns, feeds the add-back);
# GATE_ADMIT_ROUND counts every round (bounds total work per lock hold).
GATE_ADMITS_DONE="${GATE_ADMITS_DONE:-0}"
case "$GATE_ADMITS_DONE" in ''|*[!0-9]*) GATE_ADMITS_DONE=0 ;; esac
GATE_ADMITS_DONE=$(printf '%s' "$GATE_ADMITS_DONE" | sed 's/^0*\([0-9]\)/\1/'); : "${GATE_ADMITS_DONE:=0}"
# Total rounds may exceed admits (skips cost a round, not an admit). Kept modest:
# every round pays a full preamble (Phase C + janitors + a dolt health probe), so
# an unbounded skip chain would be real load for no reviews.
GATE_MAX_ROUNDS_PER_SWEEP="${GATE_MAX_ROUNDS_PER_SWEEP:-6}"
case "$GATE_MAX_ROUNDS_PER_SWEEP" in ''|*[!0-9]*) GATE_MAX_ROUNDS_PER_SWEEP=6 ;; esac
GATE_MAX_ROUNDS_PER_SWEEP=$(printf '%s' "$GATE_MAX_ROUNDS_PER_SWEEP" | sed 's/^0*\([0-9]\)/\1/'); : "${GATE_MAX_ROUNDS_PER_SWEEP:=6}"
[ "$GATE_MAX_ROUNDS_PER_SWEEP" -ge 1 ] 2>/dev/null || GATE_MAX_ROUNDS_PER_SWEEP=1
[ "$GATE_MAX_ROUNDS_PER_SWEEP" -le 12 ] 2>/dev/null || GATE_MAX_ROUNDS_PER_SWEEP=12

# ── ga-991au: an INELIGIBLE marker must not end the whole sweep ───────────────
# Step 0b selects ONE marker (`.[0]`). If that marker turns out to be ineligible
# — a live sibling gate-run for the same branch — the sweep used to `exit 0`
# right there, having admitted nothing, and the other N queued markers were
# never even looked at. Measured 2026-08-06: TEN consecutive sweeps admitted
# NOTHING (6 YIELDED, 2 NEEDS_REBASE, 2 QUEUED) while 47 markers sat queued and
# ZERO reviewers ran. One legitimate 11-17min run sterilises the entire queue for
# its whole duration, because every sweep in that window re-picks that branch.
#
# gate_continue_or_exit() converts that dead sweep into another attempt, reusing
# the ga-309v3 re-exec continuation verbatim: fresh process (no state leak),
# SAME lock (the burst is one logical sweep), bounded by the SAME round counter.
# Ownership of that lock across the re-exec is proven from the lock ITSELF (dir
# exists + on-disk heartbeat token + pid half == $$, see the GATE_LOCK_ENABLED
# block above) — never from the exported env alone, which every descendant
# (including the gate-reviewer sessions this round spawns) also inherits.
#
# ROUND 1 (abandoned — reference only, commit 6de2210 on this branch): excluded
# the yielded BRANCH, not just the marker, from later rounds' selection, because
# a second queued marker for the same branch is common and Step 4c's auto-rebase
# ends in `git push --force-with-lease`, which used to run BEFORE the
# live-sibling check — so a same-branch sibling marker could force-push a SECOND
# time before discovering the live run. A 5-round adversarial review found that
# list mechanism itself had a real blocker (`$(printf '\n')` is an EMPTY STRING —
# command substitution eats the trailing newline — so the branch list silently
# concatenated without a separator and the exclusion died from the 2nd yield
# onward) plus two more serious issues (the filter read a label that a second,
# driftable code path also resolves independently; and jq failure fell back to
# the UNFILTERED list — fail-open in the one spot here where fail-CLOSED is the
# safe default, since the failure mode is a force-push on a branch reviewers are
# reading). Replaced by:
#
# ROUND 2 (this version): the live-sibling check is HOISTED to run right after
# Step 4b (branch not already merged) and BEFORE Step 4c's rebase/force-push —
# see the call site there. This closes the problem STRUCTURALLY instead of
# derivatively: no force-push can ever precede a live-sibling discovery, for ANY
# marker, ANY round, including round 0 — so a same-branch sibling marker yields
# at that SAME early checkpoint every time, without ever touching the branch.
# Marker-level exclusion (the invariant below) is sufficient again; no
# branch-level list is needed. Step 5b keeps an identical check as a safety net
# for the residual window between the early check and actual review-spawn.
#
# No exclusion list is needed and that is not an accident: the yield path
# deliberately leaves its marker in gate-status:dispatching (never re-queued),
# and Step 0b only ever selects `-l gate-status:queued` — so the next round
# cannot re-pick the marker that just yielded. If that invariant ever changes,
# this function silently degrades into "retry the same marker until the round
# budget runs out" — bounded, but useless. The selftest pins it.
gate_continue_or_exit() {
  local _why="${1:-ineligible}"
  if [ "$((GATE_ADMIT_ROUND + 1))" -lt "$GATE_MAX_ROUNDS_PER_SWEEP" ] 2>/dev/null; then
    # Deliberately NOT calling cleanup_reviewer_sessions here. This round spawned
    # NOTHING, so there is nothing of ours to clean — and the array that function
    # iterates is not ours either: Phase C fills SESSION_IDS with the LIVE
    # SIBLING's reviewer sessions (and sets GATE_RUN_LEAVE_SESSIONS_ALIVE=0 per
    # iteration), so calling it here would take the close-loop and shut down the
    # very reviewers this yield exists to protect. They would never post a
    # verdict, the healthy run would hit its verdict timeout, and Phase C would
    # write a terminal FAIL over a good branch — precisely the clobber ga-dupnv's
    # yield was written to prevent. And when Phase C did NOT populate the array
    # (disabled, or an early `continue`), the same call dies on `set -u`
    # (SESSION_IDS: unbound variable) and takes the dispatcher down — the ga-eqjo
    # AUTHOR_AGENT outage class. Both failure modes, one line, so: no cleanup.
    # The lock carries over because `exec` replaces the process image and the
    # lock dir simply outlives it — NOT because of any flag. (An earlier version
    # of this comment credited GATE_SWEEP_HAS_MORE_WORK; that flag's only reader
    # was cleanup_reviewer_sessions, which is deliberately not called here, so
    # setting it would be dead code. Wrong comments on lock-critical paths are
    # worse than no comments.)
    #
    # And NO `trap - EXIT` here. On this path the active trap is still the plain
    # `_release_gate_lock` (the swap to cleanup_reviewer_sessions happens later,
    # at Step 5b's tail). If exec SUCCEEDS the trap vanishes with the process
    # image either way, so clearing it buys nothing; if exec FAILS — `$0` is the
    # live pack asset this very dispatcher merges into, so a truncated read
    # mid-redeploy is real — the trap is the only thing that frees the lock.
    # Clearing it would convert a clean release into a leaked lock, on the
    # path that re-execs most often (skips are ~6 of every 10 sweeps).
    log "Skip-ineligible ($_why): trying the NEXT queued marker in this same sweep — round $((GATE_ADMIT_ROUND + 1))/$GATE_MAX_ROUNDS_PER_SWEEP, admits ${GATE_ADMITS_DONE}/${GATE_MAX_ADMITS_PER_SWEEP} (ga-991au)."
    export GATE_LOCK_TOKEN
    export GATE_ADMIT_ROUND="$((GATE_ADMIT_ROUND + 1))"
    export GATE_ADMITS_DONE
    export GATE_MAX_ADMITS_PER_SWEEP
    export GATE_MAX_ROUNDS_PER_SWEEP
    # No "$@": inside a function the positional params are the FUNCTION's, so
    # `exec bash "$0" "$@"` would re-exec the daemon as `bash <script> live-sibling`,
    # mutating its argv (visible to ps/pgrep -f matchers) and propagating that
    # bogus arg through every later round. The script takes no arguments.
    exec bash "$0"
  fi
  log "Skip-ineligible ($_why): round budget exhausted (${GATE_ADMIT_ROUND}/${GATE_MAX_ROUNDS_PER_SWEEP}) — ending sweep; the next launchd fire continues (ga-991au)."
  exit 0
}
GATE_ADMIT_ROUND=$(printf '%s' "$GATE_ADMIT_ROUND" | sed 's/^0*\([0-9]\)/\1/'); : "${GATE_ADMIT_ROUND:=0}"

# Age (seconds) of an arbitrary path's mtime; a huge number if it is missing.
# Used for both the heartbeat file and the .reaping reclaim sentinel (ga-T1 #4).
_gate_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}

# Age (seconds) of the heartbeat file; a huge number if it is missing.
_gate_lock_hb_age() { _gate_lock_path_age "$GATE_LOCK_HB"; }

# ga-T1 #7 (kill-recovery): the mtime/MAX_AGE staleness path alone takes up to
# GATE_LOCK_MAX_AGE (1800s) to reclaim after the dispatcher is KILLED (e.g. a
# watchdog `kickstart -k`) — a killed holder stops refreshing its heartbeat but
# its mtime hasn't aged out, so every new sweep yields to the corpse for ~30min
# (observed in the field, dog-1 ga-wisp-vxq5tup). Fast-path: if the heartbeat's
# holder PID is provably DEAD, the holder is gone NOW regardless of mtime. PID
# reuse only makes us fall back to the (still-bounded) mtime path, never a wrong
# reclaim of a LIVE holder — so this is strictly safe. Empty/non-numeric token
# (transient hb) is treated as ALIVE (do not fast-reclaim).
_gate_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$GATE_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;   # unknown holder → treat as alive
  esac
  kill -0 "$_pid" 2>/dev/null && return 1   # pid alive → holder alive
  return 0                                   # pid dead → holder dead
}

# How long a .reaping reclaim sentinel may live before a later reclaimer may
# force-clear it (guards against a reclaimer that died mid-recovery wedging all
# future reclaims). The real reclaim is a few local-fs ops (sub-ms), so this is
# pure crash-recovery margin — keep it small.
GATE_LOCK_REAP_TTL="${GATE_LOCK_REAP_TTL:-10}"

_gate_lock_write_hb() { printf '%s\n' "$GATE_LOCK_TOKEN" > "$GATE_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a
# peer that recovered our lock after we were (wrongly) judged stale.
_release_gate_lock() {
  local _own
  _own=$(head -n1 "$GATE_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$GATE_LOCK_TOKEN" ] && rm -rf "$GATE_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE sweep holds it (back off).
_acquire_gate_lock() {
  if mkdir "$GATE_LOCK_DIR" 2>/dev/null; then
    _gate_lock_write_hb
    # ga-T1 #6: _gate_lock_write_hb swallows write errors (|| true). If the hb
    # write failed after mkdir succeeded we would own a HEARTBEAT-LESS lock →
    # _gate_lock_hb_age returns 999999999 on the next fire → instant false
    # reclaim → double sweep. Verify the hb is present+non-empty; if not, undo
    # the mkdir and return the NON-acquired path so we never proceed blind.
    if [ ! -s "$GATE_LOCK_HB" ]; then
      rm -rf "$GATE_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  local _age
  _age=$(_gate_lock_hb_age)
  if [ "$_age" -lt "$GATE_LOCK_MAX_AGE" ] && ! _gate_lock_holder_dead; then
    return 1   # fresh heartbeat + live holder → a live sweep is running.
  fi
  # else: heartbeat aged out OR holder PID dead (killed mid-sweep) → reclaim (ga-T1 #7).
  # _age ≥ MAX_AGE means the heartbeat is OLD *or* ABSENT. An absent heartbeat on
  # an existing dir is a holder caught in the µs window between its mkdir and its
  # hb write — NOT a dead holder (ga-T1 #6 guarantees a write-failed acquire tears
  # its own dir down, so a hb-less dir is only ever transient). Treat it as LIVE
  # and back off; this also removes the "fresh dir looks stale" race that let a
  # reclaimer clobber a just-created lock.
  if [ ! -s "$GATE_LOCK_HB" ]; then
    return 1
  fi
  # ── ga-T1 #4: single-winner stale reclaim (close the check-then-mv TOCTOU) ──
  # The age-check above and the reclaim below are not one atomic step. The old
  # code mv'd the stale dir aside and recreated it; that left a window where the
  # dir was ABSENT, into which a second process's entry-mkdir could slip — two
  # holders, ~4% under contention → double sweep. Two fixes together make this
  # provably single-winner:
  #   (a) gate the reclaim on ONE atomic sentinel at a FIXED path (mkdir has
  #       exactly one winner system-wide), and
  #   (b) take the stale dir over IN PLACE (overwrite its heartbeat) — the dir is
  #       NEVER removed, so no entry-mkdir gap exists at all.
  local _reaping="${GATE_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    # Sentinel already exists. A LIVE reclaim is sub-millisecond, so a sentinel
    # older than the TTL is a reclaimer that died mid-recovery and must not wedge
    # all future reclaims. STEAL it atomically (mv has exactly one winner): the
    # earlier "check age, then rm" was itself a TOCTOU — a process that read the
    # sentinel as absent could rm a peer's freshly-created LIVE sentinel and admit
    # two reclaimers. We only ever touch an EXISTING sentinel here, and age-gate
    # the steal so a live (age≈0) sentinel is never taken. Then retry the gate.
    if [ "$(_gate_lock_path_age "$_reaping")" -ge "$GATE_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${GATE_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then
        rm -rf "$_dead" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1   # another reclaimer owns the recovery → back off (no double-win).
    fi
  fi
  # Re-check UNDER the sentinel: if the lock turned fresh while we waited for the
  # sentinel, an earlier reclaimer already took over (and released the sentinel) —
  # backing off here stops us clobbering its brand-new lock (the late-loser race).
  if [ "$(_gate_lock_hb_age)" -lt "$GATE_LOCK_MAX_AGE" ] && ! _gate_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  # Sole reclaimer, stale confirmed. Overwrite the dead heartbeat with ours in
  # place (dir stays put throughout). Verify the write (ga-T1 #6); release the
  # sentinel on EVERY exit path so it can never wedge.
  _gate_lock_write_hb
  if [ ! -s "$GATE_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE gate lock (heartbeat age ${_age}s ≥ ${GATE_LOCK_MAX_AGE}s) — taking over (ga-7s0or pattern)."
  return 0
}

# ── ga-ltr3c: scale the verdict timeout by diff size (pure; selftest-sourceable) ─
# effective = base + files×PER_FILE + (lines÷100)×PER_100L, clamped to [base, MAX].
# Args: <base_minutes> <changed_files> <changed_lines>. Echoes the effective
# timeout in minutes (integer). Fail-safe: any non-numeric arg contributes 0, so
# the result can never drop below the base — a parse failure degrades to today's
# fixed-timeout behavior, never to a shorter (false-FAIL-prone) timeout.
# Unit-tested by gate-verdict-timeout-scale.selftest.sh.
gate_scaled_verdict_timeout() {
  local base="$1" files="$2" lines="$3"
  case "$base"  in ''|*[!0-9]*) base=22 ;; esac
  case "$files" in ''|*[!0-9]*) files=0 ;; esac
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  local per_file="${VERDICT_TIMEOUT_PER_FILE_MINUTES:-1}"
  local per_100l="${VERDICT_TIMEOUT_PER_100_LINES_MINUTES:-1}"
  local maxm="${VERDICT_TIMEOUT_MAX_MINUTES:-50}"
  case "$per_file" in ''|*[!0-9]*) per_file=1 ;; esac
  case "$per_100l" in ''|*[!0-9]*) per_100l=1 ;; esac
  case "$maxm"     in ''|*[!0-9]*) maxm=50 ;; esac
  local eff=$(( base + files * per_file + (lines / 100) * per_100l ))
  # Clamp: scaling only ADDS time (never below base); the cap bounds the ceiling.
  # An incoherent MAX (< base) is floored at base so the result is never < base.
  [ "$maxm" -lt "$base" ] && maxm="$base"
  [ "$eff" -lt "$base" ] && eff="$base"
  [ "$eff" -gt "$maxm" ] && eff="$maxm"
  printf '%s' "$eff"
}

# ── ga-evjs2: scale the frozen-reviewer staleness window by diff size ───────────
# Mirror of gate_scaled_verdict_timeout but in SECONDS with its own cap. base is
# REVIEWER_STALE_SECS (the silence window before a listed+peek-alive reviewer is
# declared frozen). Scaling only ADDS — a bigger diff buys a longer legitimate silence
# window so a reviewer heads-down reading 3000+ lines is not false-reaped at 5min and
# respawn-stormed. Capped at REVIEWER_STALE_MAX_SECS so a genuinely-frozen reviewer is
# still reaped well under the outer verdict timeout (the grace + dead-streak guards in
# the caller remain the backstops). A base of 0 (probe disabled) passes straight
# through. FAIL-SAFE: any non-numeric input contributes 0 → result never below base.
gate_scaled_reviewer_stale() {
  local base="$1" files="$2" lines="$3"
  case "$base" in ''|*[!0-9]*) base=300 ;; esac
  [ "$base" = "0" ] && { printf '0'; return 0; }   # probe disabled → stay disabled
  case "$files" in ''|*[!0-9]*) files=0 ;; esac
  case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
  local per_file="${REVIEWER_STALE_PER_FILE_SECS:-20}"
  local per_100l="${REVIEWER_STALE_PER_100_LINES_SECS:-15}"
  local maxs="${REVIEWER_STALE_MAX_SECS:-900}"
  case "$per_file" in ''|*[!0-9]*) per_file=20 ;; esac
  case "$per_100l" in ''|*[!0-9]*) per_100l=15 ;; esac
  case "$maxs"     in ''|*[!0-9]*) maxs=900 ;; esac
  [ "$maxs" -lt "$base" ] && maxs="$base"
  local eff=$(( base + files * per_file + (lines / 100) * per_100l ))
  [ "$eff" -lt "$base" ] && eff="$base"
  [ "$eff" -gt "$maxs" ] && eff="$maxs"
  printf '%s' "$eff"
}

# ── ga-acb: Auto-circuit-break decision (pure; selftest-sourceable) ─────────────
# Determines whether a marker is PROVABLY un-mergeable and should be permanently
# circuit-broken (gate:needs-human on source bead, marker closed) instead of
# re-queuing. Three conditions are checked:
#
#   no_branch   → branch is absent from origin (cannot review)
#   ahead_dead  → branch has >GATE_REBASE_AHEAD_MAX own commits AND author is
#                 dead/empty (no live session to re-anchor the divergence)
#   retry_dead  → rebase-attempt counter ≥ MAX AND author is dead/empty
#                 (replaces the existing "escalate to needs-rebase" path)
#
# Arguments: <condition> <ahead_count_or_blank> <author_alive_0_1> <rebase_attempt> <rebase_attempt_max> <ahead_max> <merge_clean_0_1>
# Echoes: "circuit-break:<reason>" when the marker should be circuit-broken,
#         "ok" otherwise. FAIL-OPEN: any unexpected input yields "ok".
# Env: GATE_AUTO_CIRCUIT_BREAK (default 1; set to 0 to disable).
#
# ga-agtqm: <merge_clean_0_1> (7th arg, default "0" — old 6-arg callers keep the
# PRE-existing, stricter behavior; nothing becomes silently more lenient just
# by being recompiled). Pass "1" only when the caller already proved, via a
# real `git merge-tree --write-tree`, that this branch merges into main with
# ZERO conflicts. ahead_dead's own premise is "no live author to resolve a
# rebase"; retry_dead's is "retries exhausted, will never self-heal" — both
# are false by construction when there is nothing to resolve in the first
# place. Measured case (wa-vcd01, 2026-08-02): 15 commits ahead, `git
# merge-tree --write-tree origin/main origin/crew/peter/wa-vcd01` reported
# ZERO conflicts, yet ahead_dead circuit-broke it anyway — commit count was
# used as a proxy for "would conflict" and never actually checked. no_branch
# is unaffected by this parameter: a branch absent from origin cannot be
# merge-tree'd clean in the first place.
gate_circuit_break_check() {
  local condition="${1:-}"         # "no_branch" | "ahead_dead" | "retry_dead"
  local ahead="${2:-}"             # commit-count or empty
  local author_alive="${3:-0}"     # 0 = dead/empty, 1 = alive
  local rebase_attempt="${4:-0}"   # current gate:exiled-tier5:N counter
  local rebase_max="${5:-3}"       # MAX_REBASE_ATTEMPTS
  local ahead_max="${6:-10}"       # GATE_REBASE_AHEAD_MAX
  local merge_clean="${7:-0}"      # ga-agtqm: 1 = merge-tree already proved clean

  # Sanitise numeric inputs
  case "$author_alive"   in ''|*[!0-9]*) author_alive=0 ;; esac
  case "$rebase_attempt" in ''|*[!0-9]*) rebase_attempt=0 ;; esac
  case "$rebase_max"     in ''|*[!0-9]*|0) rebase_max=3 ;; esac
  case "$ahead_max"      in ''|*[!0-9]*|0) ahead_max=10 ;; esac
  case "$merge_clean"    in 1) merge_clean=1 ;; *) merge_clean=0 ;; esac

  # Feature gate — default ON; set GATE_AUTO_CIRCUIT_BREAK=0 to disable
  if [ "${GATE_AUTO_CIRCUIT_BREAK:-1}" = "0" ]; then
    printf 'ok'; return 0
  fi

  case "$condition" in
    no_branch)
      # Branch is absent from origin — no reviewer can ever merge it.
      printf 'circuit-break:no_branch'
      ;;
    ahead_dead)
      # ga-agtqm: a proven-clean merge means there is nothing for anyone —
      # alive or dead — to resolve. Never circuit-break on commit count alone.
      if [ "$merge_clean" = "1" ]; then
        printf 'ok'; return 0
      fi
      # Branch is over the rebase envelope AND no live author to re-anchor.
      case "$ahead" in ''|*[!0-9]*) printf 'ok'; return 0 ;; esac
      if [ "$ahead" -gt "$ahead_max" ] && [ "$author_alive" = "0" ]; then
        printf 'circuit-break:ahead_dead'
      else
        printf 'ok'
      fi
      ;;
    retry_dead)
      # ga-agtqm: same clean-merge exemption as ahead_dead — retries exhausted
      # against a provably clean branch is not evidence of unmergeability,
      # only of the size-caution loop this bead fixes never resolving on its
      # own (it re-derives the identical "too wide" verdict every sweep).
      if [ "$merge_clean" = "1" ]; then
        printf 'ok'; return 0
      fi
      # Rebase retries exhausted AND no live author — will never self-heal.
      if [ "$rebase_attempt" -ge "$rebase_max" ] && [ "$author_alive" = "0" ]; then
        printf 'circuit-break:retry_dead'
      else
        printf 'ok'
      fi
      ;;
    *)
      printf 'ok'
      ;;
  esac
}

# ── ga-tgwq: no_branch local-rescue classification (pure; selftest-sourceable) ──
# "Branch absent from origin" (the no_branch condition above) conflates two
# states with OPPOSITE remedies. Real case (17/07): wa-4s5l9 had 2 commits /
# 1148 insertions, clean worktree, answering a real gate-feedback round — the
# owning session died between commit and push, and ga-acb permanently parked
# it as gate:needs-human, when the actual fix was a 3-second `git push`.
#
# Given facts about the LOCAL git state (probed by the caller — this function
# does no I/O itself, same separation-of-concerns as gate_circuit_break_check),
# classify which of three outcomes applies:
#
#   park       → no local ref either: truly unmergeable, ga-acb's original
#                behavior (unchanged).
#   rescuable  → local ref exists, no uncommitted changes in a linked
#                worktree: a session likely died between commit and push —
#                the fix is `git push`, not a human re-anchor decision.
#   escalate   → local ref exists AND a linked worktree has uncommitted
#                changes: session died MID-EDIT — needs a human, never
#                auto-push (could silently strand or overwrite the pending diff).
#
# Args: <local_ref_exists_0_1> <worktree_dirty_0_1>
# Echoes: "park" | "rescuable" | "escalate".
# FAIL-SAFE: any unexpected/non-0-1 input resolves to "park" — the pre-ga-tgwq
# behavior, so a bug in this function can only ever restore the old (safe, if
# overly aggressive) park path, never newly auto-push or silently drop work.
gate_no_branch_local_classify() {
  local ref_exists="${1:-0}" wt_dirty="${2:-0}"
  case "$ref_exists" in
    1) ;;
    *) printf 'park'; return 0 ;;
  esac
  case "$wt_dirty" in
    0) printf 'rescuable' ;;
    1) printf 'escalate' ;;
    *) printf 'park' ;;
  esac
}

# _gate_tgwq_git <git-args...> — ga-tgwq: minimal is-container-aware git
# dispatch, deliberately duplicating git_rig()'s --git-dir/-C branching
# (git_rig itself is defined later in this file, among the Step-4
# git-context helpers) rather than calling git_rig directly, because that
# definition sits AFTER the GATE_DISPATCHER_LIB_ONLY early-return above —
# so no lib-only source (every selftest, including this function's own)
# ever has it defined. Confirmed the hard way: without this, the probe
# below silently no-ops (rig_resolve_commit: command not found, masked by
# its own 2>/dev/null) and every call reads "ref absent" — quality-gate-
# circuit-break.selftest.sh's real-git-sandbox section (6c) catches this
# exact failure mode if it regresses.
_gate_tgwq_git() {
  if [ "${IS_CONTAINER_RIG:-0}" = "1" ]; then
    git --git-dir="${GIT_DIR_PATH:-}" "$@"
  else
    git -C "${GIT_DIR_PATH:-}" "$@"
  fi
}

# gate_no_branch_probe_local <branch> — ga-tgwq. Does the actual git I/O for
# the classification above: does $branch exist as a local ref in the rig's
# git dir, and if so, does any LINKED WORKTREE currently checking it out have
# uncommitted changes? Separated from the pure classifier so the decision
# logic stays unit-testable without a live git checkout.
#
# Echoes two space-separated 0/1 flags: "<ref_exists> <wt_dirty>". A worktree
# with `git worktree list --porcelain` output this function can't parse, or a
# `git status` call that fails, reads as dirty=0 (fail toward "rescuable", the
# more common case, over "escalate") since park-vs-rescuable already covers
# the safety-critical never-park-real-work distinction — this second flag
# only decides which SAFE-either-way message/label to attach.
gate_no_branch_probe_local() {
  local branch="$1" ref_exists=0 wt_dirty=0 wt_path=""
  [ -n "$(_gate_tgwq_git rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null)" ] && ref_exists=1
  if [ "$ref_exists" = "1" ]; then
    wt_path=$(_gate_tgwq_git worktree list --porcelain 2>/dev/null \
      | awk -v b="refs/heads/$branch" '/^worktree /{wt=substr($0,10)} /^branch /{if (substr($0,8)==b) print wt}' \
      | head -1)
    if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
      [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ] && wt_dirty=1
    fi
  fi
  printf '%s %s' "$ref_exists" "$wt_dirty"
}

# ── ga-jyox: FAIL-time assignee-clear decision (pure; selftest-sourceable) ──────
# On a gate FAIL, the dispatcher used to unconditionally clear the bead's
# assignee so the Pilot could re-dispatch a fixer. That is correct for an
# ephemeral pool/adhoc builder (which exits after submitting) or a session that
# has died — but WRONG for a live, long-lived named-crew author (e.g. thies-wa):
# clearing story:in-flight + assignee made imparavel-check see "buildable but
# stalled" and the Pilot dispatched a SECOND generic builder onto the SAME
# in-flight branch, racing two agents on one branch (ga-1url/ga-u4yi: this
# destroyed the same Fase 2 epic twice in one night).
#
# Args: <author> <author_alive_0_1>
# Echoes "keep" (author is a live named crew — do not clear) or "clear"
# (pool/adhoc builder, empty author, or dead session — today's behavior,
# unchanged). FAIL-SAFE: any unrecognized/empty author, or a dead session,
# resolves to "clear" — this can only ever restore today's re-dispatch path,
# never newly strand a bead.
gate_fail_assignee_action() {
  local author="${1:-}" author_alive="${2:-0}"
  case "$author_alive" in ''|*[!0-9]*) author_alive=0 ;; esac
  # Pool/ephemeral builder naming convention (ga-nkkku; mirrors the identical
  # deny-list used throughout pilot-dispatcher.sh, e.g. _beadid_live_crew_owner):
  # anything matching these patterns is a disposable build slot, never a named
  # crew PM/domain-owner, regardless of liveness.
  #   - gastown.dog / gastown.dog-* : the dog-pool TEMPLATE/alias form.
  #   - dog-*                       : the dog-pool session_name form actually
  #     stored as bead assignee (dotted templates use the post-dot segment as
  #     the session_name prefix, e.g. template "gastown.dog" → session_name
  #     "dog-gabjtm" — confirmed live via `gc session list --json`).
  #   - mayor                       : never a genuine gate-review author (Mayor
  #     doesn't submit branches); it is a routing sentinel used elsewhere in
  #     this file (wa-worker FAIL normalizer) to redirect an unrecoverable pool
  #     author's nudge to a human — must still "clear", not "keep".
  #   - gastown.mayor / gastown__mayor : ga-mgrma. The Mayor DELEGATES all
  #     implementation and never author-codes a fix, but the Mayor's session is
  #     always live, so before this exclusion a Mayor-authored gate-fail hit
  #     the author_alive=1 branch below and got "keep" — stranding the bead
  #     forever (the Mayor won't code it, the Pilot won't re-dispatch an
  #     author-kept bead, and the dog pool won't claim a bead assigned to
  #     live-mayor). Concrete: ga-tkcam gate-failed and sat kept-assigned to
  #     gastown__mayor for 110s+ until manually cleared. Both resolved-identity
  #     forms are excluded, same belt-and-suspenders pairing already used for
  #     the Mayor elsewhere in this codebase (pilot-dispatcher.sh's
  #     _attached_session_peek_cache, ga-lluq1): "gastown__mayor" is what bd's
  #     assignee field actually stores (session_name form — confirmed via the
  #     ga-tkcam incident and quality-gate-guard.sh's AUTHOR derivation, which
  #     reads the bead's raw assignee verbatim), "gastown.mayor" is the
  #     alias/name form, kept for parity in case a future call site ever feeds
  #     that form in instead. Same "gate/dispatch mis-handles the Mayor
  #     identity" class as GAP-1 (ga-625z4).
  case "$author" in
    ''|mayor|gastown.mayor|gastown__mayor|gastown.dog|gastown.dog-*|dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*)
      printf 'clear'; return 0 ;;
  esac
  if [ "$author_alive" = "1" ]; then
    printf 'keep'
  else
    printf 'clear'
  fi
}

# default_pool_route_for_rig <rig> — pure; selftest-sourceable.
# ga-f54ui: what gc.routed_to should be RESTORED to when a bead returns to the
# generic pool (e.g. after a gate FAIL whose author is not a live named crew —
# see the FAIL-handling "else" arm below). Echoes the bare pool-worker template
# name a pool worker's own self-serve probe expects
# (`bd ready --metadata-field gc.routed_to=<target> --unassigned`) — never a
# slot instance (e.g. "wa-worker-1"), only the template ("wa-worker").
#
# Mirrors pilot-dispatcher.sh's rig_to_builder()+wa_worker_template()
# composition exactly (gascity->gastown.dog, whatsapp_automation->wa-worker,
# property_scrapers->ps-worker, every other/unknown rig->gastown.dog).
# Duplicated rather than sourced: quality-gate-dispatcher.sh and
# pilot-dispatcher.sh are two independently-running daemon processes with no
# shared-lib chokepoint today — keep the two mappings in sync by hand if
# either changes (same tradeoff this file already accepts for e.g.
# gate_delivery_looks_partial vs its story-delivery.sh mirror).
default_pool_route_for_rig() {
  local rig="${1:-}"
  case "$rig" in
    whatsapp_automation|wa) printf 'wa-worker' ;;
    property_scrapers|ps)   printf 'ps-worker' ;;
    *)                      printf 'gastown.dog' ;;
  esac
}

# author_is_alive <author> — canonical liveness check for a gate marker's
# AUTHOR. Echoes 1 if AUTHOR matches session_name, name, alias, id, or
# agent_name of a live (non-closed) `gc session list` entry; 0 otherwise
# (including an empty AUTHOR). ga-ipf6: the rebase-path AUTHOR_ALIVE check
# used a narrower ad-hoc predicate (alias/name/agent only — .agent isn't even
# a real field on session-list entries, and no closed filter) than
# FAIL_AUTHOR_ALIVE's canonical one. AUTHOR is recorded in session_name form
# (<agent>-<sessionid>, e.g. peter-wa-ga2gnr), so the narrower predicate NEVER
# matched — every live author hitting the rebase path read as dead (100%
# false-dead; an earlier fix, ga-jyox, corrected only the FAIL call site).
# ga-bnu1: the matching predicate itself now lives in quality-gate-guard.sh as
# session_matches_author() (guard's pure-function lib, sourced below) — GAP-1/
# GAP-2 need the same 5-field match against a JSON blob they already hold
# (the session-list CACHE shim's output), not a live `gc session list` call
# per bead. This wrapper preserves author_is_alive()'s original live-fetch
# contract for its own call sites unchanged. Single source of truth for the
# match predicate across all three call sites so they cannot diverge again.
# gc_json_or_unknown <cmd...>
#
# ga-07509: `VAR=$(gc ... --json 2>/dev/null || echo "")` does not protect
# against a failing `gc` call — gc still prints a JSON envelope to STDOUT
# even when it exits non-zero (e.g. {"ok":false,"error":{...}}, or for
# `gc bd <sub>` a bare {"error":"..."} with no "ok" key at all), so the
# command substitution already captured that non-empty envelope before
# `|| echo` ever runs. The envelope then parses as valid JSON, and a
# downstream `.field | length` read on it silently returns 0 —
# indistinguishable from "queried successfully, zero results".
#
# This wrapper captures the REAL exit code before anything can discard it
# (via `if VAR=$(...); then`, exempt from this file's `set -e` the same way
# the rest of its guard clauses are), and additionally checks the envelope's
# own `ok` field (some gc paths print an error envelope and still exit 0).
# It resolves to exactly one of three states — never collapses the last two:
#   - valid data / legitimate-empty: prints the raw JSON to stdout, returns
#     0. The JSON may legitimately describe an empty result (e.g.
#     {"sessions": []}) — that is for the CALLER to determine via its own
#     field-specific jq query, exactly as before this fix. This helper only
#     answers "did the call itself succeed", not "was the result empty".
#   - FAILURE: prints nothing, returns 1. Callers MUST treat this distinctly
#     from a legitimate empty result — never proceed as if the answer was
#     "no data" (defer/retry/explicit fail-open per call site's own policy).
#
# Usage:
#   if _OUT=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json); then
#     ... use $_OUT, e.g. echo "$_OUT" | jq '.sessions | length' ...
#   else
#     ... gc call FAILED — decide explicitly what this call site does ...
#   fi
# Or, for a memoized cache that should retry-on-failure rather than pin an
# empty sentinel: CACHE=$(gc_json_or_unknown gc ...) || true; [ -z "$CACHE" ]
# unambiguously means "failed" — a real success is never an empty string
# (this helper's own success path always prints at least "{}"/"[]").
gc_json_or_unknown() {
  local _gjou_out _gjou_rc
  if _gjou_out=$("$@" 2>/dev/null); then
    _gjou_rc=0
  else
    _gjou_rc=$?
  fi
  [ "$_gjou_rc" -eq 0 ] || return 1
  [ -n "$_gjou_out" ] || return 1
  if ! printf '%s' "$_gjou_out" | jq -e . >/dev/null 2>&1; then
    return 1   # exit 0 but unparseable — never hand malformed JSON upstream
  fi
  if printf '%s' "$_gjou_out" | jq -e 'has("ok") and (.ok == false)' >/dev/null 2>&1; then
    return 1   # exit 0 but envelope explicitly says ok:false
  fi
  printf '%s' "$_gjou_out"
  return 0
}

author_is_alive() {
  local author="${1:-}"
  local sessions_json
  # ga-07509: on a FAILED `gc session list` call, fail toward ALIVE (1), not
  # dead (0) — the old fallback ('{}' on failure) silently read as "no live
  # sessions" here, which flows into gate_fail_assignee_action()'s 'clear'
  # branch and wipes a possibly-very-much-alive author's claim. That is
  # EXACTLY the mechanism behind ga-1url/ga-u4yi: two builders raced on the
  # same branch and destroyed the same epic twice in one night. A false
  # "alive" only costs one extra sweep before a truly-dead author's claim is
  # cleared — far cheaper than a double-dispatch.
  if ! sessions_json=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json); then
    printf '1'
    return 0
  fi
  session_matches_author "$author" "$sessions_json"
}

# resolve_recycled_author <author> <author_agent> <author_alive_0_1> — ga-pyzo.
# author_is_alive() only matches AUTHOR's LITERAL recorded string (session_name
# form, e.g. batista-wa-gawispc8tmbq) against CURRENTLY live sessions. When the
# ONE session that submitted the marker recycles (restart/crash/reap), that
# string can never match a live session again — even though the durable agent
# (e.g. batista-wa) is up under a brand-new session id — so a live agent's work
# reads as dead FOREVER and rots (evidence: 3 parked markers, 2026-07-14).
#
# If author_alive is already 1, or there is no distinct AUTHOR_AGENT to try
# (empty, or identical to AUTHOR), echoes AUTHOR unchanged — pure no-op. Only
# when AUTHOR's own session is dead AND a distinct durable agent alias was
# recorded by the guard at submit time (gate.submitted_by_agent) does this
# check THAT alias's liveness via the SAME canonical author_is_alive() — never
# a regex derivation at dispatch time (fragile: session-suffix forms vary —
# -ga2gnr, -gawispiwq9sj, -adhoc-e346188199 — no reliable single delimiter).
#
# Echoes the identity callers should treat as "the author" from here on: either
# AUTHOR (unchanged/dead) or AUTHOR_AGENT (recycled session, live agent). The
# caller is expected to reassign its own AUTHOR/*_ALIVE variables from this
# result so every downstream nudge/mail/assign in that call site's block
# targets the durable, reachable identity instead of the dead session string.
# Single shared helper for BOTH dispatcher call sites (the ga-ipf6 lesson:
# an un-factored predicate fixed on one call site and not the other stranded
# a live author for hours — do not let this fallback re-diverge the same way).
resolve_recycled_author() {
  local author="${1:-}" agent="${2:-}" alive="${3:-0}"
  case "$alive" in ''|*[!0-9]*) alive=0 ;; esac
  if [ "$alive" = "1" ] || [ -z "$agent" ] || [ "$agent" = "$author" ]; then
    printf '%s' "$author"
    return 0
  fi
  if [ "$(author_is_alive "$agent")" = "1" ]; then
    printf '%s' "$agent"
  else
    printf '%s' "$author"
  fi
}

# resolve_rebase_author <trusted_submit_author> <branch> <marker_self_declared_author>
# ga-6dp9 (bug 1 of 3): the rebase-path liveness check must be keyed on WHO
# ACTUALLY WROTE the branch, not on the source bead's CURRENT assignee/owner —
# that can be reassigned to an unrelated PM/babysitter long after the branch
# was pushed (e.g. a Mayor-crafted marker rescuing an orphaned branch, where
# the bead's owner never touched the code). Reproduced live: bead wa-aed6l's
# owner was peter-wa, who never touched the branch; the real (already-dead)
# author was an ephemeral wa-worker build. Treating peter-wa's liveness as
# "the author is alive, wait" stalled the marker in an infinite retry.
#
# <trusted_submit_author> is AUTHOR as resolved from the marker's
# gate.submitted_by METADATA (set by the guard at the ACTUAL /gate-done
# submission time, ga-tkvsa) — reliable because it is tied to the
# branch-submission EVENT, not the bead's current, driftable state. When
# that's unavailable (marker created outside the normal guard flow), fall
# through to signals ALSO tied to the branch/marker itself rather than the
# bead: the branch's own `crew/<crew>/` segment (immutable once pushed), then
# the marker's self-declared `author:` text line (untrusted for the
# SECURITY/self-review-exclusion purpose in quality-gate-guard.sh Step 5 — but
# fine here: the worst case of trusting a spoofed value for THIS check is one
# extra escalation, never a security bypass). NEVER falls through to a
# bead-assignee/owner value — that is precisely the wrong-agent vector this
# bug fixes.
#
# Echoes "" (unresolvable) rather than guessing when none of these signals
# are available; author_is_alive("") is 0 (dead) — the FAIL-SAFE direction
# (bounded-retry-then-escalate, never wait-forever on a phantom "live" author).
resolve_rebase_author() {
  local trusted="${1:-}" branch="${2:-}" marker_author="${3:-}"
  if [ -n "$trusted" ] && [ "$trusted" != "null" ]; then
    printf '%s' "$trusted"
    return 0
  fi
  local crew
  crew=$(printf '%s' "$branch" | sed -n 's#^crew/\([^/]\{1,\}\)/.*#\1#p')
  if [ -n "$crew" ]; then
    printf '%s' "$crew"
    return 0
  fi
  if [ -n "$marker_author" ] && [ "$marker_author" != "null" ]; then
    printf '%s' "$marker_author"
    return 0
  fi
  printf ''
}

# gate_behind_envelope_action <behind_exceeded_0_1> <author_alive_0_1>
# ga-6dp9 (bug 2 of 3): decide what to do when main has moved further ahead of
# the branch's base than GATE_REBASE_BEHIND_MAX allows. This is ALWAYS a
# permanent condition — main only ever moves forward, it never self-heals by
# waiting — so the only two valid outcomes are "circuit_break" (no live
# author to fix it) or "bounce" (live author can manually rebase). NEVER
# "retry": the old behavior funneled this into the generic transient-retry
# bucket, re-queueing a permanent condition as if it might clear on its own —
# an infinite "attempt 1/3" loop in production (the delta only ever grows,
# never shrinks on its own). Echoes "not_applicable" when behind_exceeded=0
# (this check does not apply; fall through to the existing generic dispatch
# unchanged).
gate_behind_envelope_action() {
  local behind_exceeded="${1:-0}" author_alive="${2:-0}"
  case "$behind_exceeded" in ''|*[!0-9]*) behind_exceeded=0 ;; esac
  case "$author_alive"    in ''|*[!0-9]*) author_alive=0    ;; esac
  if [ "$behind_exceeded" != "1" ]; then
    printf 'not_applicable'; return 0
  fi
  if [ "$author_alive" = "1" ]; then
    printf 'bounce'
  else
    printf 'circuit_break'
  fi
}

# gate_branch_already_merged <branch> <default_branch>
# ga-88sl7: reusable predicate wrapping the SAME already-merged detection
# Step 4b uses (is-ancestor, then a patch-id fallback for a rebase-merge
# whose SHAs changed but whose content is 100% in main — mirrors
# rig_content_merged's ga-01yq logic, inlined rather than called so this
# predicate has a SINGLE external dependency, git_rig, for lib-only-selftest
# shimming) — but callable independently of Step 4b's per-sweep candidate,
# so a SEPARATE sweep (Step 0a-4, below) can ask "is THIS branch merged NOW?"
# for a marker Step 4b already passed judgment on in an earlier sweep.
# Requires git_rig (and its GIT_DIR_PATH/IS_CONTAINER_RIG context) already
# resolved for the marker's rig — same precondition Step 4b has. Deliberately
# defined BEFORE the GATE_DISPATCHER_LIB_ONLY early-return below (unlike
# git_rig/rig_content_merged themselves) so it loads under lib-only sourcing;
# see gate-needs-rebase-terminality-reap.selftest.sh.
# FAIL-CLOSED: empty args or an unresolvable ref echo "0" (never reap on
# doubt — matches rig_content_merged's own FAIL-CLOSED contract). Echoes
# "1"/"0"; never exits non-zero (pure yes/no, matches this file's other
# decision-function style).
gate_branch_already_merged() {
  local _branch="$1" _default_branch="$2" _n
  if [ -z "$_branch" ] || [ -z "$_default_branch" ]; then
    printf '0'; return 0
  fi
  if git_rig merge-base --is-ancestor "origin/$_branch" "origin/$_default_branch" 2>/dev/null; then
    printf '1'; return 0
  fi
  _n=$(git_rig rev-list --count --cherry-pick --right-only "origin/$_default_branch...origin/$_branch" 2>/dev/null || echo ERR)
  if [ "$_n" = "0" ]; then
    printf '1'; return 0
  fi
  printf '0'
}

# gate_rebase_attempt_advanced <intended_next_attempt> <actual_highest_after_write>
# ga-6dp9 (bug 3 of 3): the gate:exiled-tier5:N label swap (remove old, add
# new) is fire-and-forget (`|| true`, matching this script's fail-soft
# convention for label writes) — a transient Dolt write failure on the ADD is
# silently swallowed, leaving the counter at its OLD value. The dispatcher
# would otherwise trust the unwritten counter and re-derive attempt=0 next
# sweep, replaying "attempt 1/3" forever: an unverified write and a failed
# write produce the SAME downstream behavior
# ([[error-and-empty-must-not-produce-the-same-value]]). Falsify the write
# instead of assuming it: re-read the label after writing and compare. Echoes
# "advanced" iff the marker's highest recorded attempt now meets or exceeds
# the intended value; "stuck" otherwise (write silently failed or lost a
# race) — callers should treat "stuck" as retries-exhausted and escalate
# immediately rather than looping on a counter that cannot move.
gate_rebase_attempt_advanced() {
  local intended="${1:-0}" actual="${2:-0}"
  case "$intended" in ''|*[!0-9]*) intended=0 ;; esac
  case "$actual"   in ''|*[!0-9]*) actual=0   ;; esac
  if [ "$actual" -ge "$intended" ]; then
    printf 'advanced'
  else
    printf 'stuck'
  fi
}

# gate_labels_have_status <labels> — pure (no I/O). "1" iff the space-joined
# label string carries at least one gate-status:* entry, "0" otherwise. Same
# tokenization as the sibling-branch extractor above (tr ' ' '\n', anchored
# ^gate-status: match) so the two can never drift on what counts as "has a
# status". Isolated from gate_marker_status_ensure's live I/O below so the
# actual predicate is unit-testable the same way gate_rebase_attempt_advanced
# is (ga-kgtiw).
gate_labels_have_status() {
  local labels="${1:-}"
  if printf '%s\n' "$labels" | tr ' ' '\n' | grep -q '^gate-status:'; then
    printf '1'
  else
    printf '0'
  fi
}

# gate_marker_label_snapshot <marker_id> — read a marker's current labels
# live. Prints the space-joined label string (possibly empty) and returns 0 on
# a successful read; returns 1 (prints nothing) if the read itself could not
# be trusted — `bd show` exited non-zero, produced truly empty stdout, or its
# JSON could not be parsed. Callers MUST branch on the exit status directly
# (`if labels=$(gate_marker_label_snapshot ...); then ...`), never infer
# failure from stdout shape — that inference is exactly the gap gate-fix-3
# closed below (bd's own not-found/error object still prints non-empty JSON
# to stdout, so stdout emptiness alone can't detect a failed read). Factored
# out of gate_marker_status_ensure (gate-fix-4) so its pre-write read and its
# post-write verification read share one implementation and can never drift
# into two different error-detection rules.
gate_marker_label_snapshot() {
  local marker_id="${1:-}" raw labels
  if ! raw=$(bd -C "$GC_CITY" show "$marker_id" --json 2>/dev/null); then
    return 1
  fi
  [ -z "$raw" ] && return 1
  if ! labels=$(printf '%s' "$raw" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null); then
    return 1
  fi
  printf '%s' "$labels"
  return 0
}

# gate_marker_status_ensure <marker_id> <context> — bd-backed self-heal.
# ga-kgtiw: every exit point in the rebase-fail path (Step 4c below) removes
# gate-status:dispatching up front, then — depending which branch it takes —
# adds exactly one new terminal/requeue gate-status via a SEPARATE, unverified
# `bd label add ... || true` call. That is the same shape ga-6dp9 already fixed
# for the gate:rebase-fail-count counter (see gate_rebase_attempt_advanced
# above): a transient Dolt write failure on the add is silently swallowed by
# `|| true`, and a silently-failed write is then indistinguishable from "no
# write was ever needed" — [[error-and-empty-must-not-produce-the-same-value]].
# Unlike the counter, the status label never got the same falsify-the-write
# treatment. The cost is not cosmetic: EVERY phase of this dispatcher selects
# its work via `bd ... -l gate-status:<value>` label queries, so a marker that
# ends up with ZERO gate-status labels matches no query, ever again — it is
# not "parked", it is invisible. Measured live (ga-kgtiw): 3/3 markers with
# gate:rebase-fail-count:1 had no gate-status label at all, one stranded 3
# days with 14 commits behind it.
#
# Call this immediately before every `exit 0` in the rebase-fail path (Step
# 4c) — after whatever branch-specific gate-status write it took. Re-reads the
# marker's labels live and, if truly empty, force-writes gate-status:error (a
# safe, already-retriable terminal state every other part of this system
# already knows how to handle) so the marker can never exit this script
# invisible. Signals outcome via stdout (see gate-fix-2/3/4 below) — the
# common case (a status IS present) returns immediately and touches nothing.
#
# gate-fix-2 (reviewer FAIL on gate_run=ga-wisp-0yhttsl): NEVER returns
# non-zero. Attempt 1 called this bare (no if/&&/||/!) at all 6 sites below,
# under this script's own `set -euo pipefail` (line 30) — a real non-zero
# return from the repair path aborted the ENTIRE dispatcher sweep right there,
# skipping the intended `exit 0`, trading "one invisible marker" for "the
# whole sweep dies mid-repair", in exactly the situation (a marker already
# under repair) most likely to already be under human scrutiny. Outcome is
# now signaled via stdout instead, mirroring gate_rebase_attempt_advanced()
# above: "ok" (a status was already present, nothing touched), "repaired"
# (status was genuinely missing, self-heal fired and VERIFIED — see gate-fix-4
# below), or "unknown" (state undetermined — this function does NOT guess: an
# unverified state must never be reported as a verified one, in either
# direction). A caller MAY consume the signal via
# `if [ "$(gate_marker_status_ensure ...)" = "repaired" ]`, exactly like the
# sibling function, but does not have to — a bare call is safe by
# construction now, so a future 7th call site can't reintroduce this bug by
# forgetting a guard the way the first 6 did.
#
# gate-fix-3 (reviewer FAIL on gate_run=ga-wisp-ub0uybc): the "unknown" net
# above had its own gap. It inferred a failed `bd show` from EMPTY stdout
# (`raw=$(bd ... || echo "")`; `[ -z "$raw" ]`) — but the real `bd` binary
# does not fail empty: `bd show <id-it-cannot-find> --json` exits 1 while
# still printing a non-empty, syntactically valid JSON object to STDOUT
# (`{"error": "...", "schema_version": 1}` — the human-readable message goes
# to stderr only). So `raw` was non-empty, the "unknown" branch never fired,
# jq's null-safe `.labels // []` turned the absent key into `[]`, and a
# genuine READ FAILURE was indistinguishable from "confirmed empty labels" —
# the exact [[error-and-empty-must-not-produce-the-same-value]] class this
# function exists to close off, reopened one layer down in its own read.
# Fix: check bd's ACTUAL exit status from the command substitution directly
# instead of inferring it from stdout shape (now lives in
# gate_marker_label_snapshot above, gate-fix-4 factored it out).
#
# gate-fix-4 (reviewer FAIL on gate_run=ga-wisp-twg3gh8, attempt 3/3, plus the
# Mayor's 2026-08-02 15:29 follow-up correcting the Mayor's OWN prior
# guidance): two independent blocking issues.
#
# Blocking issue 1 (primary): gate-fix-2's "signal via stdout, mirroring
# gate_rebase_attempt_advanced()" guidance was INCOMPLETE — it never stated
# the precondition that makes the precedent safe. gate_rebase_attempt_advanced
# has ZERO log/warn/err calls in its body; it is mute by construction. This
# function's warn()/err() calls used this script's own log()/warn()/err()
# helpers (defined below), which are plain `echo` — NOT `>&2` — so they wrote
# straight into the SAME stdout stream all 6 call sites capture via `$(...)`.
# On every path that mattered (the old "unknown" branches, the "repaired"
# self-heal branch) the captured value came out polluted, e.g. "[timestamp]
# ... ERROR: ga-kgtiw SELF-HEAL: ...\nrepaired" instead of the bare token
# "repaired" — so `= "repaired"` was FALSE even when a repair genuinely fired.
# Fix: this function is now MUTE — no log/warn/err calls anywhere in its body,
# and every `bd`/`gc` call's own stdout is explicitly redirected to /dev/null
# too (defense in depth against either binary someday printing a success
# message on stdout despite a quiet flag). Per the Mayor's explicit direction,
# the CALLER now logs after reading the returned signal — see the 6 call
# sites below, which warn() on "repaired" (mirroring how
# gate_rebase_attempt_advanced's own callers warn() on "stuck").
#
# Blocking issue 2 (secondary): the repair branch's `bd label add ... ||
# true` — the write that performs the actual fix — was never verified; a
# silent write failure left the marker exactly as broken as before while this
# function still printed 'repaired' and mailed the Mayor a false "fixed it".
# Same shape as ga-6dp9 (gate_rebase_attempt_advanced above), applied one
# layer down: FALSIFY THE WRITE. 'repaired' is now printed ONLY when a
# post-write re-read (via gate_marker_label_snapshot, the same helper used for
# the initial read — so both can never drift into different error-detection
# rules) CONFIRMS the label landed. A re-read that fails, OR one that
# succeeds but still shows no gate-status label, both fall back to 'unknown'
# — the Mayor's contract names exactly THREE tokens (ok/repaired/unknown), so
# an unconfirmed repair does not get a token of its own; it still mails the
# Mayor, now with honest "could not confirm" wording instead of a false
# "fixed it" (mail is a separate path from bd, so it remains the
# human-in-the-loop fallback either way).
gate_marker_status_ensure() {
  local marker_id="${1:-}" context="${2:-the rebase-fail path}"
  local labels
  [ -z "$marker_id" ] && { printf 'ok'; return 0; }

  if ! labels=$(gate_marker_label_snapshot "$marker_id"); then
    printf 'unknown'
    return 0
  fi
  if [ "$(gate_labels_have_status "$labels")" = "1" ]; then
    printf 'ok'
    return 0
  fi

  # Confirmed empty — attempt repair, then FALSIFY THE WRITE (gate-fix-4)
  # instead of trusting `|| true`: only a verified post-write read may claim
  # 'repaired'.
  bd -C "$GC_CITY" label add "$marker_id" "gate-status:error" -q >/dev/null 2>&1 || true

  if labels=$(gate_marker_label_snapshot "$marker_id") && [ "$(gate_labels_have_status "$labels")" = "1" ]; then
    bd -C "$GC_CITY" comment "$marker_id" "ga-kgtiw AUTO-REPAIR: this marker left $context with no gate-status label — a prior label write silently failed. The dispatcher's own safety net (ga-kgtiw) detected the gap, forced gate-status:error, and VERIFIED by re-read that the write landed — this marker is never permanently invisible; it will be retried like any other error marker." >/dev/null 2>&1 || true
    gc --city "$GC_CITY" mail send mayor \
      -s "Gate ALERT: marker $marker_id lost its gate-status label (ga-kgtiw self-heal fired)" \
      -m "Marker $marker_id exited $context with no gate-status label — an earlier label write silently failed (transient Dolt hiccup or similar). The ga-kgtiw self-heal forced gate-status:error and VERIFIED by re-read that the write landed, so the marker stays visible/retriable instead of vanishing forever. This should be RARE; if it keeps firing, the underlying write-reliability issue (not just this safety net) needs investigation." >/dev/null 2>&1 || true
    printf 'repaired'
    return 0
  fi

  bd -C "$GC_CITY" comment "$marker_id" "ga-kgtiw AUTO-REPAIR UNCONFIRMED: this marker left $context with no gate-status label. The dispatcher's self-heal (ga-kgtiw) attempted to force gate-status:error but could NOT verify by re-read that the write took effect — it may still have no gate-status label. Needs manual check/repair; do not assume this marker is safely retriable yet." >/dev/null 2>&1 || true
  gc --city "$GC_CITY" mail send mayor \
    -s "Gate ALERT: self-heal could NOT confirm repair of marker $marker_id (ga-kgtiw)" \
    -m "Marker $marker_id exited $context with no gate-status label. The ga-kgtiw self-heal attempted to force gate-status:error but could NOT verify (by re-read) that the write took effect — it may still be invisible to every dispatcher sweep. Needs manual bd label add / investigation; do not assume this is already fixed." >/dev/null 2>&1 || true
  printf 'unknown'
  return 0
}

# gate_should_exile_tier5 <next_attempt> <exile_after_n> — pure (no I/O).
# ga-g0v96 (AC4): stamping gate:exiled-tier5 on the VERY FIRST transient
# rebase failure sank the marker behind the ENTIRE healthy queue before its
# own just-promised "retry 1/3" had a chance to run on a busy gate — the
# exile and the retry budget it accompanies directly contradicted each other
# (observed: 4h44m between attempt 1 and attempt 2, wa-b6uy3 — the exile, not
# headroom, was the binding constraint). Forgive a single blip: only a
# REPEATED failure (this attempt >= exile_after_n) is treated as strong
# enough evidence to deprioritize the marker behind healthy ones.
gate_should_exile_tier5() {
  local next_attempt="${1:-1}" exile_after_n="${2:-2}"
  case "$next_attempt"  in ''|*[!0-9]*) next_attempt=1 ;; esac
  case "$exile_after_n" in ''|*[!0-9]*) exile_after_n=2 ;; esac
  if [ "$next_attempt" -ge "$exile_after_n" ]; then
    printf '1'
  else
    printf '0'
  fi
}

# read_rebase_attempt <marker_id> — fetch the current highest attempt-counter
# value recorded on the marker (0 if none present).
# ga-gpcx: this label was named gate:rebase-attempt:N until 2026-07-17. The old
# name read as an innocuous retry counter — an author manually re-arming a
# marker (flipping gate-status back to queued) saw it and reasonably assumed it
# was decorative, not noticing it ALSO sinks the marker to the starved tier-5
# rebase-fail bucket in the selection below (has_rebase_fail), independent of
# gate-status. Renamed so the label itself names its own effect. Still matches
# the legacy name on READ ONLY so any marker already exiled under the old name
# at deploy time stays correctly recognized as exiled — silently releasing it
# into the healthy tier would reintroduce the exact ga-q3ig2 outage class this
# tier exists to prevent. All WRITES use the new name exclusively.
# ga-g0v96 (AC4): also matches gate:rebase-fail-count:N — the counter written
# on EVERY transient failure regardless of whether it also exiles to tier5
# (see gate_should_exile_tier5 above). Without this, an attempt-1 failure
# (which no longer writes gate:exiled-tier5 by itself) would read back as
# attempt=0 forever and the counter could never advance past "1/3".
# Single source of truth for both the per-sweep initial read and the ga-6dp9
# post-write verification below, so they can never drift into two different
# parsers of the same label convention.
read_rebase_attempt() {
  local marker_id="${1:-}" n
  n=$(bd -C "$GC_CITY" show "$marker_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[]' 2>/dev/null \
    | sed -nE 's/^gate:(rebase-attempt|exiled-tier5|rebase-fail-count):([0-9]+)$/\2/p' | sort -rn | head -1 || true)
  [ -z "$n" ] && n=0
  printf '%s' "$n"
}

# is_transient_spawn_error <spawn_err_text> — "1" if the captured stderr from a
# failed `gc session new` reviewer spawn looks like a TRANSIENT connectivity
# blip (Dolt/MySQL connection dropped mid-call), "0" otherwise. Pure (no I/O),
# same shape as gate_should_exile_tier5 above, so a selftest can drift-guard
# the classification directly without touching Dolt.
# ga-2u38b: a reviewer-spawn failure used to be ONE undifferentiated bucket —
# ANY empty session_id aborted the run and parked the marker at
# gate-status:error (which no sweep re-admits), mixing "the network blinked"
# with "the template/session cap is broken"
# (root-class:transient-infra-is-terminal). The patterns below are the
# signature observed live in the 2026-08-06 08:10:23 incident ("gc session
# new: listing sessions: search wisps (merge): search wisps: invalid
# connection", 12 occurrences that sweep) plus the standard Go/MySQL-driver
# connection-drop family it belongs to. Deliberately NOT matching bare "EOF"
# or "timeout" — those are common substrings of unrelated failures too, and a
# false "transient" classification would silently mask a real broken-spawn
# outage behind endless auto-retries instead of ever reaching gate-status:error.
is_transient_spawn_error() {
  local err_text="${1:-}"
  case "$err_text" in
    *"invalid connection"*|*"read tcp"*|*"broken pipe"*|*"connection reset"*|*"dial tcp"*|*"connection refused"*|*"i/o timeout"*)
      printf '1' ;;
    *)
      printf '0' ;;
  esac
}

# read_spawn_fail_count <marker_id> — fetch the current highest
# gate:spawn-fail-count:N value recorded on the marker (0 if none present).
# ga-2u38b: mirrors read_rebase_attempt's label-counter convention above, but
# on its OWN label prefix — a separate counter/budget from rebase retries so
# the two failure classes (rebase-vs-main conflicts, reviewer-spawn
# connectivity blips) can never shadow or exhaust each other's cap.
read_spawn_fail_count() {
  local marker_id="${1:-}" n
  n=$(bd -C "$GC_CITY" show "$marker_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[]' 2>/dev/null \
    | sed -nE 's/^gate:spawn-fail-count:([0-9]+)$/\1/p' | sort -rn | head -1 || true)
  [ -z "$n" ] && n=0
  printf '%s' "$n"
}

# ga-2u38b: transient reviewer-spawn retry knobs — kept separate from the
# ga-piscg systemic-outage counters (defined further below, near
# SPAWN_ABORT_THRESHOLD). Those answer "is spawn broken town-wide" (file-based,
# spans all markers); these answer "has THIS marker's spawn hit a transient
# connection blip" (per-marker label, read via read_spawn_fail_count). A
# systemic outage still pages a human (unchanged); an isolated blip on one
# marker now self-heals instead. Declared here, BEFORE the
# GATE_DISPATCHER_LIB_ONLY cutoff below (unlike SPAWN_ABORT_*), because
# gate_spawn_failure_requeue_or_error (next function) reads
# GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS directly — a lib-only source (selftests)
# must see a real default, not an unbound variable at call time.
GATE_SPAWN_RETRY_MAX="${GATE_SPAWN_RETRY_MAX:-3}"                           # in-process retries before giving up on this sweep
GATE_SPAWN_RETRY_BACKOFF_SECS="${GATE_SPAWN_RETRY_BACKOFF_SECS:-3}"         # BASE backoff; doubles per attempt (see spawn-retry-loop)
GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS="${GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS:-3}" # cross-sweep cap before parking at gate-status:error

# gate_spawn_failure_requeue_or_error <marker_id> <spawn_err> — decides AND
# APPLIES (bd label/comment writes) whether a reviewer-spawn failure on
# <marker_id> requeues to gate-status:ready (transient, under cap, write
# verified) or falls through to gate-status:error (non-transient, cap
# exceeded, or the counter write itself could not be verified). Echoes
# "ready" or "error"; the CALLER always performs the actual gate-status:error
# write itself on "error" (this function never writes it) — exactly one
# place in the spawn-failure path writes gate-status:error, matching every
# other error path in this file. ga-2u38b.
#
# MUTE BY CONSTRUCTION (ga-kgtiw/gate-fix-4 lesson,
# [[error-and-empty-must-not-produce-the-same-value]]): zero log/warn/err
# calls in this body. Every real call site consumes this function's stdout
# via $(...) — a log/warn/err call using this script's own helpers (plain
# `echo`, not `>&2`) would splice straight into the captured token and
# corrupt the ready/error comparison silently. The caller logs AFTER reading
# the returned token, same discipline as gate_marker_status_ensure.
gate_spawn_failure_requeue_or_error() {
  local marker_id="${1:-}" spawn_err="${2:-}"
  local prev next

  if [ "$(is_transient_spawn_error "$spawn_err")" != "1" ]; then
    printf 'error'
    return 0
  fi

  prev=$(read_spawn_fail_count "$marker_id")
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  next=$((prev + 1))

  if [ "$next" -ge "$GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS" ]; then
    bd -C "$GC_CITY" comment "$marker_id" "ga-2u38b: reviewer-spawn transient connection failures persisted for $GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS attempts (last spawn_err=${spawn_err:-none}) — giving up on auto-retry, parking at gate-status:error for human/Mayor triage." 2>/dev/null || true
    printf 'error'
    return 0
  fi

  bd -C "$GC_CITY" label remove "$marker_id" "gate:spawn-fail-count:$prev" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$marker_id" "gate:spawn-fail-count:$next" -q 2>/dev/null || true

  # ga-6dp9 pattern: the label add above is fire-and-forget — verify it
  # actually stuck instead of trusting it, so a silently-lost write can't
  # replay "attempt 1/N" forever.
  if [ "$(gate_rebase_attempt_advanced "$next" "$(read_spawn_fail_count "$marker_id")")" = "stuck" ]; then
    bd -C "$GC_CITY" comment "$marker_id" "ga-2u38b: reviewer-spawn hit a transient connection error (spawn_err=${spawn_err:-none}) but the gate:spawn-fail-count label write did not verifiably land — escalating to gate-status:error now rather than risk an infinite attempt-1 retry loop." 2>/dev/null || true
    printf 'error'
    return 0
  fi

  bd -C "$GC_CITY" label add "$marker_id" "gate-status:ready" -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$marker_id" "ga-2u38b: reviewer-spawn hit a transient connection error (spawn_err=${spawn_err:-none}) — attempt $next/$GATE_SPAWN_TRANSIENT_MAX_ATTEMPTS. Requeued to gate-status:ready for automatic re-admission next sweep; no human action needed. Work already done this run (rebase/push/stale-base-check/sizing/verdict beads) is not being thrown away for a socket blip." 2>/dev/null || true
  printf 'ready'
  return 0
}

# branch_tip_is_merge_commit <branch_ref> — "1" if <branch_ref>'s tip commit
# itself has a second parent (i.e. IS a merge commit), "0" otherwise —
# including when the ref cannot be resolved at all (fail toward the existing,
# well-tested rebase path rather than the newer merge path on an ambiguous
# read; an unresolvable ref is already handled upstream of this check by
# MT_VERDICT="err").
# ga-kyxih: `git rebase <upstream>` (used unconditionally below, no
# --rebase-merges) treats the rebased range as a flat, linearized patch
# series — it does not correctly replay a commit that is ITSELF a merge (e.g.
# an earlier "merge origin/main into this branch" the author already did by
# hand). Two real incidents confirmed this class of failure (ga-ffop9,
# ga-mmdm2, measured by the Mayor 2026-08-05): `git merge-tree` (used above
# for HAS_CONFLICT/CONFLICT_KIND) correctly predicts the merge outcome, but a
# literal `git rebase` can still misbehave or fail on such a branch even when
# merge-tree reported clean — while a real `git merge` (the strategy the
# branch's own history already used once) resolves it correctly, with zero
# conflicts in one incident and a trivial additive conflict in the other. This
# predicate lets the call sites below route merge-commit-tip branches to
# `git merge` instead of `git rebase`, without touching the rebase path at all
# for the overwhelming-majority linear-history case (AC3 non-regression).
# `<ref>^2` only resolves when a SECOND parent exists — the cheapest, most
# direct test; no log-parsing, no `rev-list --parents` field-counting.
branch_tip_is_merge_commit() {
  local branch_ref="${1:-}"
  [ -z "$branch_ref" ] && { printf '0'; return 0; }
  if git_rig rev-parse --verify -q "${branch_ref}^2" >/dev/null 2>&1; then
    printf '1'
  else
    printf '0'
  fi
}

# Lib-only entrypoint for quality-gate-reconvene.selftest.sh: expose the helpers
# above WITHOUT running the live dispatcher (mirrors quality-gate-guard.sh's
# GATE_GUARD_LIB_ONLY). Must precede the log-redirect + live work below. Never
# taken in normal `bash quality-gate-dispatcher.sh` execution.
#
# ga-bnu1: load guard's pure functions (lib-only: no live sweep) BEFORE the
# GATE_DISPATCHER_LIB_ONLY early-return, not after. author_is_alive() now
# delegates to guard's session_matches_author(), so a LIB_ONLY-mode caller
# (e.g. gate-author-alive-predicate-unify.selftest.sh, which sources this
# file with GATE_DISPATCHER_LIB_ONLY=1 and calls author_is_alive() directly)
# needs it defined too — sourcing guard.sh is itself lib-only (no live sweep,
# no side effects) so running it unconditionally here is safe in both modes.
# Also gives us parse_marker_id as the canonical single source of truth (DRY:
# ga-b92q / ga-tmug).
#
# ga-bnu1 (gate-fix-attempt:2): source the SIBLING guard.sh, not GC_CITY's.
# GC_CITY (L32) is a hardcoded live-main-tree path, so a caller that sources
# THIS file from anywhere else (a review worktree, a CI checkout) still
# pulled guard.sh from main — silently loading a version that can lack
# session_matches_author(), crashing author_is_alive() with "command not
# found" instead of degrading gracefully. Resolve guard.sh relative to this
# script's own real location instead, so the two files loaded together
# always come from the same checkout/commit regardless of which tree
# dispatcher.sh itself is running from.
_GATE_DISPATCHER_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_GUARD_LIB_ONLY=1 source "${_GATE_DISPATCHER_SELF_DIR}/quality-gate-guard.sh" 2>/dev/null || true
unset _GATE_DISPATCHER_SELF_DIR
# guard.sh sets its OWN `LOG=$LOG_DIR/quality-gate-guard.log` (L25) at source time —
# restore ours, exactly like the `glh` source is already undone at L41-42 (ga-l47b7).
# Without this the `exec >> "$LOG"` below sends this dispatcher's ENTIRE output to
# quality-gate-guard.log: the gate keeps working, but every observer looking at
# quality-gate-dispatcher.log sees a file frozen at the moment this source was added,
# and concludes the gate is DEAD. It cost hours tonight — the throughput watchdog fired
# "165min with no Gate PASSED", digo reported the gate stalled, and I diagnosed a
# 3-hour outage from a log that was simply being written somewhere else. The gate had
# never stopped. Same root class (ga-p5q3): "I see nothing" read as "nothing happened".
LOG="$LOG_DIR/quality-gate-dispatcher.log"

if [ -n "${GATE_DISPATCHER_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

# ── Per-cycle heartbeat (DPW anti-false-WEDGE) ────────────────────────────────
# Touch a dedicated heartbeat file at the VERY START of every run — including
# runs that exit early (lock-contention yield, no-work, headroom DEFER). The
# daemon-presence-watchdog checks THIS file's mtime (not the main log, which
# only advances on STATE-CHANGE) to verify liveness. During a sustained quota/
# headroom defer the main log freezes for hours while the daemon fires every
# 180s; without this touch, DPW reads a frozen log as "WEDGED" and kickstarts
# + spams ntfy every 300s (false positive). Fail-open: a touch failure (e.g.
# tmpfs full) is silently swallowed — it must never abort the dispatcher.
# The heartbeat file path is $HQ/.gc/logs/quality-gate-dispatcher.heartbeat;
# $LOG_DIR is set above and mkdir -p'd before exec >> "$LOG".
#
# ga-2vf9b: touching ONLY here conflated "a sweep started" with "a sweep is
# still alive" — Phase C's own preamble (per-in-flight-run bd queries, marker
# scan, headroom check, claim+rebase+spawn) can legitimately run 500-900s+
# under Dolt latency or several in-flight runs, comfortably past DPW's 600s
# threshold BEFORE this single invocation even finishes, even though log()
# output during that same stretch never gaps past ~200s (measured against
# quality-gate-dispatcher.log: 0 of the last 4999 inter-line gaps exceeded
# 600s; the daemon was always actively progressing). So log() now re-touches
# this SAME file on every call — a strict superset of the original single
# touch (log() always fires at least once early in a normal run, covering
# fast-exit paths identically) that ALSO keeps the heartbeat fresh through a
# long-but-active sweep. A sweep that genuinely stops logging for >600s (truly
# hung, e.g. wedged on an unresponsive syscall) still goes stale and still
# gets kickstarted — that path is unchanged.
#
# ga-2vf9b (adversarial review tweak): `: > file` (truncate via shell redirect)
# bumps mtime identically to `touch` without forking an external process — the
# original once-per-run touch is cheap either way, but log()/err()/warn() below
# can now fire dozens of times per sweep, so avoid the per-call fork. Content
# is never read (only mtime), so truncating to empty each time is harmless.
#
# COUPLING WARNING: daemon-presence-watchdog.sh (same bead, ga-2vf9b) ALSO
# gained an in-flight-gate-run suppression that widens its effective
# tolerance for a stale heartbeat on THIS daemon specifically, whenever a
# quality-gate-run bead is gate-status:running. That suppression is
# defense-in-depth ON TOP OF this fix, not a substitute for it — if this
# per-call refresh is ever reverted while that suppression stays, DPW's
# effective wedge-detection window for a genuinely hung dispatcher silently
# stretches from 600s to however long a gate-run bead happens to persist as
# gate-status:running (commonly tens of minutes), which is WORSE than the
# pre-fix baseline. Revert both together, never just this one.
_GATE_HB_FILE="$LOG_DIR/quality-gate-dispatcher.heartbeat"
: > "$_GATE_HB_FILE" 2>/dev/null || true

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] $*"; : > "$_GATE_HB_FILE" 2>/dev/null || true; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] ERROR: $*"; : > "$_GATE_HB_FILE" 2>/dev/null || true; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] WARN: $*"; : > "$_GATE_HB_FILE" 2>/dev/null || true; }

# ── ga-piscg: systemic spawn-abort escalation (consecutive-abort alert) ───────
# The dispatcher processes exactly ONE queued marker per sweep. A broken spawn
# mechanism (gate-reviewer template misconfig / session-cap deadlock — ga-mzc3h)
# aborts the reviewer-spawn for EVERY marker, but each marker churns
# error→queued→error too fast for the per-marker [GATE-ERROR] monitor (10min
# stuck) to fire. We persist a counter across sweeps so K CONSECUTIVE
# spawn-aborts (across markers, not one branch) PAGE A HUMAN in minutes — the
# alerting layer that was missing during the 2026-06-06 town-wide 20h outage
# (dispatcher aborted spawn 7+x, set gate-status:error each time, never escalated).
SPAWN_ABORT_THRESHOLD="${SPAWN_ABORT_THRESHOLD:-3}"          # consecutive aborts before paging
SPAWN_ABORT_REALERT_SEC="${SPAWN_ABORT_REALERT_SEC:-1800}"  # re-page cadence (30m) while still broken
SPAWN_ABORT_COUNT_FILE="$GC_CITY/.gc/gate-spawn-abort-count"     # persisted consecutive count
SPAWN_ABORT_ALERT_FILE="$GC_CITY/.gc/gate-spawn-abort-alerted"  # last-page epoch (re-alert cadence)

# Pure decision (no IO, set -e safe) so the selftest can drift-guard it:
# given (consecutive_count, threshold, now_epoch, last_alert_epoch, realert_sec)
# echo "page" iff count>=threshold AND we are past the re-alert cooldown, else "hold".
spawn_abort_should_page() {
  local count="$1" threshold="$2" now="$3" last="$4" realert="$5"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last"  in ''|*[!0-9]*) last=0  ;; esac
  if [ "$count" -lt "$threshold" ]; then echo "hold"; return 0; fi
  if [ "$((now - last))" -ge "$realert" ]; then echo "page"; else echo "hold"; fi
}

# ── ga-art5: verdict-bead status must distinguish "couldn't read" from "open" ─
# Pure decision (no IO, set -e safe) so the selftest can drift-guard it: a
# failed `bd show` on a verdict bead is NOT the same fact as that bead's
# verdict genuinely being open — conflating them made a transient Dolt hiccup
# and a real open verdict trigger the identical REQUEUED action
# (root-class:error-vs-empty). Callers pass the __UNKNOWN__ sentinel when
# `bd show` itself failed (never a jq-parsed value in that case), and a real
# status string otherwise.
#   unknown  — bd show failed; don't guess, skip this bead this sweep
#   skip     — already closed; nothing to do
#   requeue  — genuinely not closed; safe to park as REQUEUED
# SELFTEST-EXTRACT vb-status-action-fn: BEGIN
vb_status_action() {
  local status="$1"
  if [ "$status" = "__UNKNOWN__" ]; then echo "unknown"; return 0; fi
  if [ "$status" = "closed" ]; then echo "skip"; else echo "requeue"; fi
}
# SELFTEST-EXTRACT vb-status-action-fn: END

# NOTE: set_gate_status() is provided by the guard lib sourced above (line ~58,
# GATE_GUARD_LIB_ONLY=1) — same DRY pattern as parse_marker_id. Single source of
# truth in quality-gate-guard.sh; no copy here to avoid drift (ga-jhyu).

# ── supersede_sibling_runs — proactively close a duplicate gate-status:running run ─
# Originally written (ga-tmug) because the guard's claim-time quality-gate:
# sibling bead was never driven to terminal by anyone but the guard's own 90m
# TTL fallback (Vector B). As of ga-f1ngu the guard's claim receipt is labeled
# gate-status:claimed, not :running (see quality-gate-guard.sh Step 6), so this
# function's query below no longer sees it at all — that case is now retired by
# the guard's OWN Vector B dedup, typically within one ~2min sweep of this
# dispatcher creating its real run, well before any terminal verdict. This
# function remains live for its OTHER original purpose: a re-queued marker
# (dead-dispatcher recovery, ga-dupnv/ga-o57gn) can still spawn a second REAL
# dispatcher-created run sharing this marker_id — calling this on BOTH PASS and
# FAIL terminal paths supersedes any such still-running duplicate immediately.
#
# Usage: supersede_sibling_runs <marker_id> <branch> <bead_id>
supersede_sibling_runs() {
  local this_marker="$1" branch="$2" bead_id="$3"
  [ -z "$this_marker" ] && return 0

  local running_json count
  # ga-h199q: routed through the read-cache shim (see live_sibling_run_for_branch
  # above — identical query, same-sweep dedup). Superseding is idempotent and a
  # briefly-stale miss just delays cleanup to the next sweep, not a correctness issue.
  running_json=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json \
    -l type:quality-gate-run \
    -l gate-status:running \
    2>/dev/null || echo "[]")
  count=$(echo "$running_json" | jq 'length' 2>/dev/null || echo "0")
  [ "$count" = "0" ] && return 0

  local i sibling sibling_id sibling_desc sibling_marker
  for i in $(seq 0 $((count - 1))); do
    sibling=$(echo "$running_json" | jq ".[$i]")
    sibling_id=$(echo "$sibling" | jq -r '.id')
    sibling_desc=$(echo "$sibling" | jq -r '.description // ""')
    sibling_marker=$(parse_marker_id "$sibling_desc")

    if [ "$sibling_marker" = "$this_marker" ] || \
       { [ -n "$bead_id" ] && echo "$sibling_desc" | grep -q "source_bead: $bead_id"; }; then
      log "  Superseding sibling gate-run $sibling_id (marker=$sibling_marker, branch=$branch)"
      set_gate_status "$sibling_id" "superseded"
      bd -C "$GC_CITY" comment "$sibling_id" "Dispatcher: gate-run superseded proactively on terminal path (marker $this_marker reached terminal; branch $branch). No need to wait for 90m TTL fallback. (ga-tmug Vector B)" 2>/dev/null || true
      # ga-jhyu: CLOSE at terminal so wisp-compact reaps it (was relabel-only → OPEN forever).
      bd -C "$GC_CITY" close "$sibling_id" -r "gate-run superseded (terminal) — marker $this_marker reached terminal. Closed by dispatcher (ga-jhyu)." 2>/dev/null || true
    fi
  done
}

# ── ga-eqjo: Steps 9-11 wrapped as a callable function ───────────────────────
# No logic below changed from its historical inline form — pure relocation +
# function-wrap so it is callable from TWO places: (a) the same-sweep fast
# path, right after Phase A spawns reviewers, when verdicts already happen to
# be in (near-instant reviews); (b) Phase C, a LATER sweep (possibly a
# different process) that re-derives an in-flight run's context from its bead
# state and finalizes it once complete or timed out. Defined this early
# (before Phase C, before Step 0a) purely so bash has already executed this
# definition by the time either caller runs — bash resolves a function call
# against whatever has been DEFINED so far at that point in execution, not
# by textual position, so callers earlier in the file can invoke a function
# defined here as long as this definition itself runs first each sweep.
gate_finalize_run() {
# ga-409f4: notification target for THIS run's FAIL/PASS-hold nudges/mails,
# resolved separately from $AUTHOR. $AUTHOR (set above, Step 3) is derived
# from the bead's assignee/created_by/owner for the DIFFERENT purpose of
# self-review exclusion (quality-gate-guard.sh Step 5's SECURITY note) — a
# bead's assignee can be a reporter/PM who delegated the coding to someone
# else without reassigning the bead. Reproduced live: bead assignee=digo-wa,
# actual branch author=mila on crew/mila/wa-o4ygn-r2 — the FAIL nudge went
# to digo-wa, costing the real author 2 hops/~15min to learn about it. The
# branch's own crew/<name>/ segment is immutable once pushed and always
# names the real author for crew branches; anything else (dog fix/*,
# wa-worker/* branches) falls back to $AUTHOR unchanged — the CONTROLE case
# from ga-409f4's acceptance criteria (no crew segment -> today's behavior).
# SELFTEST-EXTRACT notify-author-resolve: BEGIN
NOTIFY_AUTHOR=$(printf '%s' "$BRANCH" | sed -n 's#^crew/\([^/]\{1,\}\)/.*#\1#p')
[ -z "$NOTIFY_AUTHOR" ] && NOTIFY_AUTHOR="$AUTHOR"
# SELFTEST-EXTRACT notify-author-resolve: END

# ── Step 9: Close reviewer sessions ──────────────────────────────────────────
# Close promptly here (before the Step 10 merge) to free the gate-reviewer cap
# slots ASAP. The EXIT trap (ga-zl277) is the safety net for every abort path
# that never reaches this line; the shared idempotent helper makes the trap a
# no-op once this has run.
cleanup_reviewer_sessions

# ── Step 10: Act on verdict ───────────────────────────────────────────────────

GATE_END_EPOCH=$(date +%s)
ELAPSED_S=$((GATE_END_EPOCH - GATE_START_EPOCH))

# ── ga-x3nmz: QUOTA-STOP re-queue — never false-FAIL on an exhausted 5h window ─
# A timeout or dead reviewer slot that coincided with an exhausted Claude 5h
# quota is a quota-stop, not a logic failure. Re-queue the marker (back to
# gate-status:queued) so the next sweep re-runs the gate; the ga-cw4pm headroom
# gate holds it deferred until the window resets, giving automatic resume (AC3).
# Park any still-pending verdict beads as REQUEUED (not TIMEOUT) so they neither
# orphan nor read as a FAIL, and the re-run mints fresh ones. Clear notify + ETA
# (AC4). This branch is mutually exclusive with the PASS/FAIL paths below.
if [ "${QUOTA_REQUEUE:-0}" = "1" ]; then
  if [ "${REQUEUE_REASON:-quota}" = "dead-reviewer" ]; then
    # ga-eqjo (code-review fix): the old blocking Step 8 poll loop silently
    # self-healed a reviewer session dying mid-review (Dolt hiccup, OOM,
    # crash — the ga-4u16h/ga-h9o17 incident class) via mid-poll respawn.
    # That respawn machinery was deliberately NOT ported to Phase C (its
    # per-slot debounce state was process-local and meaningless once a
    # sweep checks a run once and exits — see gate_collect_verdicts). But
    # falling all the way through to a genuine TIMEOUT-FAIL below is WRONG
    # for this specific case: the branch may be fine and other reviewers
    # may have already passed it — blaming the AUTHOR's code for an infra
    # death burns one of their 3 auto-fix attempts toward a false, permanent
    # gate:needs-human park. Phase C confirmed EVERY still-pending
    # reviewer's session is dead (not slow, not wedged — gone) before
    # setting this flag, so re-queue for a fresh attempt with new reviewers
    # instead, reusing the exact same proven re-queue MECHANISM as the
    # ga-x3nmz quota-stop path immediately below (never FAIL, never burn a
    # fix-attempt), with reason-appropriate messaging.
    log "INFRA re-queue (ga-eqjo): marker $MARKER_ID re-queued — reviewer session(s) died mid-review (Dolt hiccup/crash class, not a code FAIL)."
    for VB in "${VERDICT_BEAD_IDS[@]}"; do
      if VB_JSON=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null); then
        VB_STATUS=$(printf '%s' "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
      else
        VB_STATUS="__UNKNOWN__"
      fi
      case "$(vb_status_action "$VB_STATUS")" in
        unknown)
          log "  Verdict bead $VB status unreadable this sweep (bd show failed — transient Dolt hiccup?) — skipping, will retry next sweep (root-class:error-vs-empty, ga-art5)."
          continue
          ;;
        skip) : ;;
        requeue)
          bd -C "$GC_CITY" label remove "$VB" "verdict:pending" -q 2>/dev/null || true
          bd -C "$GC_CITY" label add    "$VB" "verdict:REQUEUED" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$VB" "VERDICT: REQUEUED (ga-eqjo) — reviewer session died mid-review (infra failure, NOT a code FAIL). Marker re-queued for a fresh attempt." 2>/dev/null || true
          bd -C "$GC_CITY" close "$VB" 2>/dev/null || true
          ;;
      esac
    done
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:queued"      -q 2>/dev/null || true
    # ga-n2cpe: every OTHER terminal path in this function clears gate:reviewing
    # on the source bead (wa-qq33j) — this one didn't. A reviewer that died
    # before ever ACKing (stale_async_start drain during startup, ga-flfo/
    # ga-xwdl) lands here with gate:reviewing still set and no verdict to
    # trigger a PASS/FAIL clear elsewhere, so the label stuck forever with no
    # terminal path to clear it — head-of-line-blocking the whole gate queue
    # until the grw FIX4 watchdog swept it up, 15-39m later (observed live on
    # wa-c3qsr, 2026-07-25, three times in one day). Clear it here too, on the
    # same sweep this dead-reviewer condition is confirmed.
    bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || true  # wa-qq33j: clear in-review state (infra re-queue, ga-n2cpe)
    bd -C "$GC_CITY" comment "$MARKER_ID" "INFRA re-queue (ga-eqjo): reviewer session(s) died mid-review — an infra failure (Dolt hiccup/crash class, ga-4u16h/ga-h9o17), NOT a code FAIL. Marker re-queued; the ga-cw4pm headroom gate will admit a fresh attempt with new reviewers." 2>/dev/null || true
    if [ "$GATE_RUN_ID" != "unknown" ]; then
      bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate run paused (infra re-queue, ga-eqjo): reviewer session(s) died mid-review; marker $MARKER_ID re-queued for a fresh attempt. No verdict recorded; this is NOT a FAIL." 2>/dev/null || true
      # ga-fi1dh: retire THIS gate-run bead (superseded, NOT left at gate-status:
      # running) — mirrors set_gate_status's other supersede call sites
      # (quality-gate-guard.sh Vector B, supersede_sibling_runs above). Without
      # this, Phase C's `-l gate-status:running` selection query (below) re-picks
      # THIS SAME bead on its very next sweep, re-reads its own verdict bead
      # (now closed verdict:REQUEUED) as a "received, non-PASS" verdict, and
      # terminally FAILs the marker that was just re-queued for a fresh attempt
      # — before that attempt ever runs.
      set_gate_status "$GATE_RUN_ID" "superseded"
      bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "gate-run superseded (terminal) — infra re-queue (ga-eqjo), marker $MARKER_ID re-queued for a fresh attempt. Closed by dispatcher (ga-fi1dh)." 2>/dev/null || true
    fi
    notify -t "⚠️ Gate re-enfileirado: reviewer morreu" -p 3 "Gate $BRANCH re-enfileirado — sessão de reviewer morreu em pleno review (falha de infra, não é FAIL) (ga-eqjo)." 2>/dev/null || true
    return 0
  fi
  _eta=$(quota_reset_eta)
  log "QUOTA-STOP (ga-x3nmz): marker $MARKER_ID re-queued — Claude 5h quota exhausted mid-review; gate re-runs automatically post-reset${_eta:+ ($_eta)}. This is NOT a FAIL."
  # Park pending verdict beads as REQUEUED so they don't orphan or count as FAIL.
  for VB in "${VERDICT_BEAD_IDS[@]}"; do
    if VB_JSON=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null); then
      VB_STATUS=$(printf '%s' "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
    else
      VB_STATUS="__UNKNOWN__"
    fi
    case "$(vb_status_action "$VB_STATUS")" in
      unknown)
        log "  Verdict bead $VB status unreadable this sweep (bd show failed — transient Dolt hiccup?) — skipping, will retry next sweep (root-class:error-vs-empty, ga-art5)."
        continue
        ;;
      skip) : ;;
      requeue)
        bd -C "$GC_CITY" label remove "$VB" "verdict:pending" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$VB" "verdict:REQUEUED" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$VB" "VERDICT: REQUEUED (ga-x3nmz) — reviewer session ended on an exhausted Claude 5h quota (quota-stop, NOT a code FAIL). Marker re-queued for re-run post-reset${_eta:+ ($_eta)}." 2>/dev/null || true
        bd -C "$GC_CITY" close "$VB" 2>/dev/null || true
        ;;
    esac
  done
  # Re-queue the marker (reverse of the atomic claim): dispatching → queued.
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:queued"      -q 2>/dev/null || true
  # ga-n2cpe: same gap as the dead-reviewer branch above (sibling requeue
  # path, identical shape, identical missing clear) — a quota-stop can strand
  # gate:reviewing on the source bead just as permanently as a dead reviewer
  # can, with the same head-of-line fallout. See the dead-reviewer branch's
  # comment for the full incident context.
  bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || true  # wa-qq33j: clear in-review state (quota-stop re-queue, ga-n2cpe)
  bd -C "$GC_CITY" comment "$MARKER_ID" "QUOTA-STOP re-queue (ga-x3nmz): reviewer(s) stalled because Claude's 5h session quota is exhausted — a quota-stop, NOT a code FAIL. Marker re-queued; the ga-cw4pm headroom gate holds it deferred until the window resets${_eta:+ ($_eta)}, then the gate re-runs with fresh reviewers." 2>/dev/null || true
  if [ "$GATE_RUN_ID" != "unknown" ]; then
    bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate run paused (quota-stop, ga-x3nmz): Claude 5h quota exhausted mid-review; marker $MARKER_ID re-queued for re-run post-reset${_eta:+ ($_eta)}. No verdict recorded; this is NOT a FAIL." 2>/dev/null || true
    # ga-fi1dh: retire THIS gate-run bead (superseded, NOT left at gate-status:
    # running) — see the identical comment in the dead-reviewer branch above for
    # why (Phase C would otherwise re-select it next sweep and mis-finalize on
    # the REQUEUED verdict bead as a FAIL).
    set_gate_status "$GATE_RUN_ID" "superseded"
    bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "gate-run superseded (terminal) — quota-stop re-queue (ga-x3nmz), marker $MARKER_ID re-queued for re-run post-reset. Closed by dispatcher (ga-fi1dh)." 2>/dev/null || true
  fi
  notify -t "⏸️ Gate pausado: cota 5h" -p 3 "Gate $BRANCH re-enfileirado — cota 5h do Claude esgotada (quota-stop, não é FAIL); retoma quando resetar${_eta:+ ($_eta)} (ga-x3nmz)." 2>/dev/null || true
  # ga-eqjo: return (not exit) — this now runs inside gate_finalize_run(), which
  # Phase C calls once per in-flight run bead in a loop; exiting the whole
  # process here would abandon any OTHER run bead still waiting to be checked
  # this same sweep (and skip Step 0a onward for the same-sweep fast-path
  # caller). Every other path through this function already falls off its end
  # via Step 11, which is an ordinary return in function context.
  return 0
fi

# ── ga-nooaw: FAIL-CLOSED BY SHA ─────────────────────────────────────────────
# A prior, independent gate-run may already have rejected this EXACT commit
# (gate_bead_has_prior_sha_fail, defined above the lib-only guard). If so,
# downgrade THIS run's PASS to FAIL before the merge is even attempted —
# unlike the post-hoc downgrades below (merge-failure, post-merge integrity),
# this check runs BEFORE do_merge_ff(), so a rejected SHA can never reach
# $DEFAULT_BRANCH in the first place. Falls through to the existing FAIL path
# below, reusing its self-healing/notify/labeling machinery unchanged.
if [ "$OVERALL_VERDICT" = "PASS" ] && [ -n "$BEAD_ID" ] && [ -n "$BRANCH_SHA" ] \
   && [ "$(gate_bead_has_prior_sha_fail "$BEAD_CITY" "$BEAD_ID" "$BRANCH_SHA")" = "yes" ]; then
  OVERALL_VERDICT="FAIL"
  FAIL_REASONS="Commit $BRANCH_SHA already carries a recorded FAIL verdict from an earlier, independent gate-run (fail-closed by SHA, ga-nooaw). A prior rejection of this exact commit cannot be flipped to PASS by re-review — push a new commit with an actual fix, then re-run /gate-done."
  warn "Fail-closed by SHA (ga-nooaw): $BRANCH_SHA already has a gate-sha-failed label on $BEAD_ID — downgrading this run's PASS to FAIL."
fi

# ── ga-lxz5w (b): LIVE re-check — a park-worthy label or bead closure that
# arrived AFTER this gate-run began must still block an in-flight PASS. Runs
# BEFORE the sibling-branch scan below: if this catches it, the bead already
# carries the signal (closed, or an explicit hold) and there is nothing left
# for the sibling check to usefully add.
if [ "$OVERALL_VERDICT" = "PASS" ] && [ -n "$BEAD_ID" ]; then
  GATE_LXZ5W_BLOCK="$(gate_bead_live_merge_block "$BEAD_CITY" "$BEAD_ID")"
  case "$GATE_LXZ5W_BLOCK" in
    closed)
      OVERALL_VERDICT="FAIL"
      FAIL_REASONS="Source bead $BEAD_ID is already closed — a different branch/process resolved it after this gate-run began (ga-lxz5w: 2-branch race, sequential variant). Not merging $BRANCH onto an already-terminal bead; a human should confirm whether these changes are still needed as a follow-up."
      warn "ga-lxz5w: bead $BEAD_ID already closed (resolved elsewhere) — downgrading $BRANCH's in-flight PASS to FAIL before merge."
      ;;
    park:*)
      OVERALL_VERDICT="FAIL"
      FAIL_REASONS="Source bead $BEAD_ID now carries a park-worthy label ($GATE_LXZ5W_BLOCK) applied after this gate-run began — re-checked live immediately before merge (ga-lxz5w). Not merging $BRANCH; clear the hold, then re-submit."
      warn "ga-lxz5w: live re-check — bead $BEAD_ID now parks ($GATE_LXZ5W_BLOCK) — downgrading $BRANCH's in-flight PASS to FAIL before merge."
      ;;
  esac
fi

# ── ga-lxz5w (a): SIBLING-BRANCH-FOR-SAME-BEAD — detect another branch still
# actively in the gate for this SAME source bead before merging. Without this,
# two branches racing to resolve one bead silently merge whichever passes
# review first with no reconciliation, discarding the other (real incident:
# wa-fnibd — an incomplete wa-worker fix merged while oracle's complete
# superset fix, held gate:needs-human, was silently dropped). Escalates
# (gate:needs-human) rather than attempting automated reconciliation: picking
# the correct/superset branch needs semantic judgment this script cannot
# safely automate. Mails the Mayor exactly once per incident: any OTHER
# sibling branch that later reaches this same point will find gate:needs-human
# already present and be caught by check (b) above instead, never re-entering
# this block — no separate duplicate-mail guard needed.
if [ "$OVERALL_VERDICT" = "PASS" ] && [ -n "$BEAD_ID" ] && [ -n "$BRANCH" ]; then
  GATE_LXZ5W_SIBLING="$(gate_bead_active_sibling_branch "$GC_CITY" "$BEAD_ID" "$BRANCH")"
  if [ -n "$GATE_LXZ5W_SIBLING" ]; then
    GATE_LXZ5W_SIB_BRANCH="${GATE_LXZ5W_SIBLING%%$'\t'*}"
    GATE_LXZ5W_SIB_STATUS="${GATE_LXZ5W_SIBLING#*$'\t'}"
    OVERALL_VERDICT="FAIL"
    FAIL_REASONS="Another branch ($GATE_LXZ5W_SIB_BRANCH, gate-status:$GATE_LXZ5W_SIB_STATUS) is concurrently active in the gate for the same source bead $BEAD_ID (ga-lxz5w: 2 branches, same bead — auto-merging the first PASS without reconciling would silently discard whichever branch loses the race). Not merging $BRANCH; a human must reconcile (pick the correct/superset branch) and clear gate:needs-human before either can proceed."
    bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-human"              -q 2>/dev/null || true
    bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-human:sibling-race" -q 2>/dev/null || true
    bd -C "$BEAD_CITY" comment "$BEAD_ID" "Dispatcher (ga-lxz5w): held $BRANCH — a sibling branch ($GATE_LXZ5W_SIB_BRANCH, gate-status:$GATE_LXZ5W_SIB_STATUS) is concurrently active in the gate for this same bead. Two branches racing to resolve the same bead cannot be auto-merged without reconciliation. A human must pick the correct branch (or merge the superset) and clear gate:needs-human before either can proceed." 2>/dev/null || true
    gc --city "$GC_CITY" mail send mayor \
      -s "Gate needs-human: 2 branches racing on $BEAD_ID (ga-lxz5w)" \
      -m "$(printf 'Source bead %s has 2+ branches concurrently active in the quality gate.\n\nThis branch %s just PASSED review, but sibling branch %s is still %s — auto-merging either would silently discard the other. Labeled gate:needs-human on %s; the Pilot will not re-dispatch it.\n\nA human must reconcile: pick the correct/superset branch, then clear gate:needs-human.\n\nBead: %s   Rig: %s\nThis branch: %s (gate run %s)\nSibling branch: %s (gate-status:%s)' \
        "$BEAD_ID" "$BRANCH" "$GATE_LXZ5W_SIB_BRANCH" "$GATE_LXZ5W_SIB_STATUS" "$BEAD_ID" "$BEAD_ID" "$RIG" "$BRANCH" "$GATE_RUN_ID" "$GATE_LXZ5W_SIB_BRANCH" "$GATE_LXZ5W_SIB_STATUS")" \
      2>/dev/null || warn "Could not mail Mayor escalation for sibling-branch race on $BEAD_ID (ga-lxz5w)"
    # ga-lxz5w/ga-huaxo: mail the AUTHOR too, not just the Mayor. This sibling-race
    # site (ga-lxz5w) landed AFTER the ga-u4yi author-mail convention was established at
    # the other gate:needs-human sites, so it silently missed its own author-mail — the
    # ga-huaxo bijection guard (gate-selfheal.selftest.sh §8) caught it. The author's
    # branch PASSED review but is held for human reconciliation; they need a DURABLE
    # signal (mail survives a dead/restarted session, unlike an ephemeral bd comment).
    # ga-409f4: mail NOTIFY_AUTHOR (branch-author-aware), not the bead-derived
    # $AUTHOR — see the header comment at the top of this function. This site
    # nudges/mails whoever should actually act on the outcome, not whoever
    # the bead happens to be assigned to.
    if [ -n "$NOTIFY_AUTHOR" ]; then
      gc --city "$GC_CITY" mail send "$NOTIFY_AUTHOR" \
        -s "Your gate PASS is held for reconciliation: 2 branches on $BEAD_ID (ga-lxz5w)" \
        -m "$(printf 'Your branch %s PASSED gate review, but it was NOT merged.\n\nA sibling branch %s is concurrently active in the gate for the same source bead %s (gate-status:%s). Auto-merging either branch would silently discard the other, so %s was labeled gate:needs-human and the Pilot will not re-dispatch it.\n\nNothing to do from your side right now — a human must pick the correct/superset branch and clear gate:needs-human before either can proceed.\n\nBead: %s   Rig: %s\nYour branch: %s (gate run %s)\nSibling branch: %s (gate-status:%s)' \
          "$BRANCH" "$GATE_LXZ5W_SIB_BRANCH" "$BEAD_ID" "$GATE_LXZ5W_SIB_STATUS" "$BRANCH" "$BEAD_ID" "$RIG" "$BRANCH" "$GATE_RUN_ID" "$GATE_LXZ5W_SIB_BRANCH" "$GATE_LXZ5W_SIB_STATUS")" \
        2>/dev/null || warn "Could not mail author $NOTIFY_AUTHOR for sibling-branch race on $BEAD_ID (ga-lxz5w)"
    fi
    warn "ga-lxz5w: sibling branch $GATE_LXZ5W_SIB_BRANCH (gate-status:$GATE_LXZ5W_SIB_STATUS) active for bead $BEAD_ID — downgrading $BRANCH's PASS to FAIL, labeling gate:needs-human."
  fi
fi

if [ "$OVERALL_VERDICT" = "PASS" ]; then
  log "ALL PASS — proceeding to merge branch $BRANCH → $DEFAULT_BRANCH ..."

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD MERGE: git_rig push origin <branch_sha>:refs/heads/$DEFAULT_BRANCH (FF merge of $BRANCH)"
    log "DRY_RUN=1 — WOULD CLOSE source bead $BEAD_ID"
    MERGE_SHA="DRY_RUN_NO_MERGE"
    MERGE_RESULT="dry_run"
  else
    # ── Container-rig direct merge ──────────────────────────────────────────
    # For container rigs (bare .repo.git):
    #   1. Rebase the branch onto origin/main (ensures clean FF merge)
    #   2. Fast-forward main to the branch tip
    #   3. Push main to origin
    #
    # For self-repo rigs (normal .git directory):
    #   Use standard git commands via -C <rig_path>
    #
    # SECURITY NOTE: We do NOT use `git push --force`. This is a FF merge only.
    # If FF fails (diverged history), we abort and report failure.

    MERGE_SHA=""
    MERGE_RESULT="failed"

    # ── ga-3b8: Merge-time rebase+retry (starvation fix) ──────────────────────
    # The review→merge window is the starvation attack surface: another rig merge
    # can land between "reviewers PASS" and "push main".  We handle this by
    # re-fetching at merge time and, if main moved, auto-rebasing the branch
    # (conflict-free only) before the FF push.  If the FF push races again, we
    # retry the whole rebase→push sequence up to MAX_MERGE_RETRIES times.
    # Each attempt is fast (seconds), so 3 retries closes the window even on a
    # very busy rig.
    MAX_MERGE_RETRIES=3
    MERGE_ATTEMPT=0

    do_merge_ff() {
      # Arguments: IS_CONTAINER_RIG, BRANCH, DEFAULT_BRANCH — all from outer scope.
      # Returns: sets MERGE_SHA and MERGE_RESULT in outer scope.
      # Strategy per attempt:
      #   1. git fetch (get current remote state)
      #   2. If main moved (branch no longer FF-able): auto-rebase if clean
      #   3. FF push branch SHA to main
      #   4. Verify landing

      git_rig fetch origin 2>/dev/null || warn "Pre-merge fetch failed (attempt $((MERGE_ATTEMPT+1)))"
      # ga-ljbx: hardened — resolve to REAL commit objects so a dangling ref
      # surfaces as failed_sha_resolution (retryable) rather than poisoning the
      # downstream merge-base/merge-tree with a non-existent SHA.
      local CUR_MAIN
      CUR_MAIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
      local CUR_BRANCH
      CUR_BRANCH=$(rig_resolve_commit "origin/$BRANCH")

      if [ -z "$CUR_MAIN" ] || [ -z "$CUR_BRANCH" ]; then
        MERGE_RESULT="failed_sha_resolution"
        return 1
      fi

      local IS_ANC
      IS_ANC=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

      if [ "$IS_ANC" != "yes" ]; then
        # Main moved during review — attempt inline rebase before push
        log "  Merge-time rebase: main moved to $CUR_MAIN after review; rebasing $BRANCH ..."
        local TMP_MR_WT="/tmp/gc-gate-mr-retry-$$-${MERGE_ATTEMPT}"
        local MR_OK=0

        # ga-ljbx: deterministic conflict pre-check (git 2.54) — see
        # rig_merge_has_conflict. An "err" verdict is treated as a transient
        # resolution failure (retryable) rather than a phantom conflict.
        local MR_BASE
        MR_BASE=$(git_rig merge-base "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
        local MR_CONFLICT=0
        local MR_VERDICT
        MR_VERDICT=$(rig_merge_has_conflict "origin/$DEFAULT_BRANCH" "origin/$BRANCH")
        if [ "$MR_VERDICT" = "1" ]; then
          MR_CONFLICT=1
        elif [ "$MR_VERDICT" = "err" ]; then
          err "  Merge-time conflict pre-check undeterminable (base=${MR_BASE:-none}) — treating as transient (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_sha_resolution"
          return 1
        fi

        if [ "$MR_CONFLICT" = "1" ]; then
          err "  Merge-time rebase: conflicts detected — cannot auto-rebase (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_merge_time_conflict"
          return 1
        fi

        if [ "$IS_CONTAINER_RIG" = "1" ]; then
          if git_rig worktree add "$TMP_MR_WT" "origin/$BRANCH" 2>/dev/null; then
            # ga-euopg: identity scoped via -c to this invocation only — a prior
            # `git config` here wrote to the SHARED repo config (no --worktree
            # flag), silently re-stamping "Gate Dispatcher" onto every worktree's
            # default author/committer identity, repo-wide, every ~2min cycle.
            if git -C "$TMP_MR_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
              local NEW_TIP_MR
              NEW_TIP_MR=$(git -C "$TMP_MR_WT" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$NEW_TIP_MR" ] && git -C "$TMP_MR_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
                MR_OK=1
                log "  Merge-time rebase: pushed $BRANCH → $NEW_TIP_MR"
              else
                git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
              fi
            else
              git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
            fi
            git_rig worktree remove "$TMP_MR_WT" --force 2>/dev/null || true
          fi
        else
          if git -C "$GIT_DIR_PATH" worktree add "$TMP_MR_WT" "origin/$BRANCH" 2>/dev/null; then
            # ga-euopg: see identity-scoping note above (container-rig branch).
            if git -C "$TMP_MR_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
              local NEW_TIP_MR_SR
              NEW_TIP_MR_SR=$(git -C "$TMP_MR_WT" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$NEW_TIP_MR_SR" ] && git -C "$TMP_MR_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
                MR_OK=1
                log "  Merge-time rebase (self-repo): pushed $BRANCH → $NEW_TIP_MR_SR"
              else
                git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
              fi
            else
              git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
            fi
            git -C "$GIT_DIR_PATH" worktree remove "$TMP_MR_WT" --force 2>/dev/null || true
          fi
        fi

        if [ "$MR_OK" != "1" ]; then
          err "  Merge-time rebase: worktree/push failed (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_merge_time_rebase"
          return 1
        fi

        # Re-fetch after rebase push (ga-ljbx: hardened resolution)
        git_rig fetch origin 2>/dev/null || true
        CUR_BRANCH=$(rig_resolve_commit "origin/$BRANCH")
        CUR_MAIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
        if [ -z "$CUR_BRANCH" ] || [ -z "$CUR_MAIN" ]; then
          MERGE_RESULT="failed_sha_resolution"
          return 1
        fi
        IS_ANC=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

        if [ "$IS_ANC" != "yes" ]; then
          err "  Merge-time rebase: branch still not FF-able after rebase (main moved again?)"
          MERGE_RESULT="failed_still_not_ff_after_rebase"
          return 1
        fi
      fi

      # ga-eqjo: refresh the outer MAIN_HEAD_SHA to THIS attempt's just-fetched
      # CUR_MAIN before pushing. The post-merge integrity check below reads
      # MAIN_HEAD_SHA as "main's state immediately before our merge" — if main
      # moved since Step 4 claimed this marker (increasingly common now that
      # runs can overlap, ga-eqjo) and this attempt rebased onto the new tip,
      # the OLD claim-time MAIN_HEAD_SHA would be stale, making the integrity
      # diff compare against the wrong baseline (and a revert would push back
      # to a too-old sha, discarding any legitimate commits landed meanwhile).
      # No-op when main did not move (CUR_MAIN == the claim-time value).
      MAIN_HEAD_SHA="$CUR_MAIN"

      # FF push
      if git_rig push origin "${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH" 2>/dev/null; then
        git_rig fetch origin 2>/dev/null || warn "Post-FF-push fetch failed"
        local POST_MAIN
        POST_MAIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
        if [ -n "$POST_MAIN" ] && git_rig merge-base --is-ancestor "$CUR_BRANCH" "$POST_MAIN" 2>/dev/null; then
          MERGE_SHA="$CUR_BRANCH"
          MERGE_RESULT="direct_ff"
          log "FF merge + landing verified (attempt $((MERGE_ATTEMPT+1))): $BRANCH → $DEFAULT_BRANCH (sha=$MERGE_SHA, main=$POST_MAIN)"

          # ── ga-eptel: durable rig-canonical landing + survival audit ─────────
          # The FF push above advances the REMOTE (origin/$DEFAULT_BRANCH on
          # GitHub), but for a CONTAINER rig `git_rig` targets the bare
          # .repo.git — whose OWN local refs/heads/$DEFAULT_BRANCH is NOT touched
          # by a push. Crew worktrees clone from that bare repo, so a stale local
          # main makes a gate-verified merge "disappear" from the rig's canonical
          # main even though it lives on GitHub. This is the root cause of
          # ga-eptel: ps-l72n (305dd697c) and ga-i5vt (d3cafb679) were reported
          # "FF merge + landing verified" yet vanished from the rig's main —
          # because the bare local main was never advanced (verified live: both
          # SHAs present on origin/main, absent from the bare .repo.git main).
          #
          # Fix: advance the bare local main to the merge SHA (FF-only — never
          # rewrite history), then AUDIT survival by confirming the merge is an
          # ancestor of BOTH the rig-canonical local main AND origin/main after a
          # fresh fetch. If it vanished (e.g. a racing town-main push clobbered a
          # shared remote), do NOT report success: return 1 so the caller
          # degrades to gate-status:error and the source bead is re-enqueued, not
          # closed. Self-repo rigs (wa, gascity) are unaffected and untouched —
          # their deploy reads GitHub directly and they survived the audit (4/4).
          if [ "$IS_CONTAINER_RIG" = "1" ]; then
            local RESOLVED_MERGE LOCAL_MAIN AUDIT_LOCAL AUDIT_ORIGIN
            RESOLVED_MERGE=$(rig_resolve_commit "$CUR_BRANCH")
            if [ -z "$RESOLVED_MERGE" ]; then
              err "  Durable-landing: merge SHA unresolvable post-push ($CUR_BRANCH)"
              MERGE_RESULT="failed_durable_resolution"
              return 1
            fi
            # ga-rstw5: track origin/$DEFAULT_BRANCH (the canonical durable line the
            # FF push above just advanced — $RESOLVED_MERGE is verified an ancestor
            # of it), NOT merely the merge SHA. FF when the bare ref is behind; when
            # it has FORKED off origin (orphan commits — e.g. a decommission
            # 'preserve' commit) RECONCILE to origin instead of false-FAILing the
            # all-PASS verdict. The old FF-only-or-fail guard's failed_durable_not_ff
            # burned a 2nd gate cycle + mailed crew a spurious FAIL the instant the
            # bare mirror diverged. The survival audit below STILL re-verifies the
            # merge in BOTH the rig-canonical local main AND origin, so a genuine
            # clobber/orphan is still caught and re-enqueued (not closed).
            DURABLE_RECON_OUT=""
            DURABLE_RECON_RC=0
            DURABLE_RECON_OUT=$(reconcile_bare_main_to_origin "$GIT_DIR_PATH" "$DEFAULT_BRANCH") || DURABLE_RECON_RC=$?
            if [ "$DURABLE_RECON_RC" != "0" ]; then
              err "  Durable-landing: bare $DEFAULT_BRANCH reconcile to origin FAILED ($DURABLE_RECON_OUT)"
              MERGE_RESULT="failed_durable_updateref"
              return 1
            fi
            log "  Durable-landing: bare $DEFAULT_BRANCH reconciled to origin ($DURABLE_RECON_OUT)"
            # Survival audit: fresh fetch, then confirm the merge survives in BOTH
            # the rig-canonical local main AND origin/main. A failure here means
            # the merge was orphaned (shared-remote clobber or lost push) — fail
            # so the bead is re-enqueued, not closed (ga-eptel audit-guard ask).
            git_rig fetch origin 2>/dev/null || warn "  Durable-landing: audit re-fetch failed (continuing with stale refs)"
            AUDIT_LOCAL=$(rig_resolve_commit "refs/heads/$DEFAULT_BRANCH")
            if [ -z "$AUDIT_LOCAL" ] || ! git_rig merge-base --is-ancestor "$RESOLVED_MERGE" "$AUDIT_LOCAL" 2>/dev/null; then
              err "  Durable-landing AUDIT FAILED: merge $RESOLVED_MERGE not in rig-canonical $DEFAULT_BRANCH (${AUDIT_LOCAL:-<unresolved>})"
              MERGE_RESULT="failed_durable_audit_local"
              return 1
            fi
            AUDIT_ORIGIN=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
            if [ -z "$AUDIT_ORIGIN" ] || ! git_rig merge-base --is-ancestor "$RESOLVED_MERGE" "$AUDIT_ORIGIN" 2>/dev/null; then
              err "  Durable-landing AUDIT FAILED: merge $RESOLVED_MERGE not in origin/$DEFAULT_BRANCH (${AUDIT_ORIGIN:-<unresolved>}) — possible shared-remote clobber"
              MERGE_RESULT="failed_durable_audit_origin"
              return 1
            fi
            log "  Durable-landing verified: merge $RESOLVED_MERGE is ancestor of BOTH rig-canonical $DEFAULT_BRANCH ($AUDIT_LOCAL) and origin ($AUDIT_ORIGIN)"
          fi

          return 0
        else
          err "Landing verification FAILED (attempt $((MERGE_ATTEMPT+1))): $CUR_BRANCH not in $DEFAULT_BRANCH ($POST_MAIN)"
          MERGE_RESULT="failed_landing_not_verified"
          return 1
        fi
      else
        # FF push rejected: main moved between our rebase and push (race)
        warn "  FF push rejected (attempt $((MERGE_ATTEMPT+1))) — main moved during push; will retry"
        MERGE_RESULT="failed_push_race"
        return 1
      fi
    }

    while [ "$MERGE_ATTEMPT" -lt "$MAX_MERGE_RETRIES" ]; do
      MERGE_ATTEMPT=$((MERGE_ATTEMPT + 1))
      log "Merge attempt $MERGE_ATTEMPT/$MAX_MERGE_RETRIES ..."
      if do_merge_ff; then
        break
      fi
      # Only retry on push-race or stale-after-rebase; give up on conflict/worktree failure
      if [ "$MERGE_RESULT" = "failed_merge_time_conflict" ] || \
         [ "$MERGE_RESULT" = "failed_merge_time_rebase" ] || \
         [ "$MERGE_RESULT" = "failed_sha_resolution" ]; then
        log "  Non-retryable failure ($MERGE_RESULT). Stopping retry loop."
        break
      fi
      if [ "$MERGE_ATTEMPT" -lt "$MAX_MERGE_RETRIES" ]; then
        log "  Retrying in 2s ..."
        sleep 2
      fi
    done

    if [[ "$MERGE_RESULT" = failed* ]]; then
      # Merge failed despite all-PASS verdict — degrade to FAIL
      OVERALL_VERDICT="FAIL"
      FAIL_REASONS="Merge failed after all-PASS verdict. Merge result: $MERGE_RESULT. Check git state of rig $RIG."
      warn "All-PASS verdict but merge failed ($MERGE_RESULT). Setting gate to failed."
    fi

    # ── ga-hawi: soft-reload immediately after merge ──────────────────────────
    # Every gate merge bumps the template config hash (CopyFiles mtime changes).
    # Without this, the session reconciler's next tick sees config drift and
    # issues drain decisions against crew, even pinned ones (race window = 0..Ns
    # until town-root-reconciler's poll).  --soft accepts the new hash in place;
    # --async returns immediately so we don't block the gate.  Non-fatal if missing.
    if [[ ! "$MERGE_RESULT" = failed* ]] && [ "$MERGE_RESULT" != "dry_run" ]; then
      gc reload --soft --async 2>/dev/null \
        && log "ga-hawi: soft-reload dispatched post-merge (config-drift guard for pinned crew)." \
        || warn "ga-hawi: gc reload --soft --async failed (non-fatal; binary guard still active)."
    fi

    # ── Bug 1b: Post-merge diff-integrity verification (belt-and-suspenders) ──
    # After a successful merge, verify the branch's changes are actually present
    # in the merged main. This catches silent conflict resolutions where git
    # resolved to main's side (dropping the fix entirely — as seen in wa-e99e).
    #
    # Strategy: fetch updated remote refs, then verify each file changed by the
    # branch still has a non-empty diff vs what was in main BEFORE the merge.
    # If any changed file regressed back to its pre-branch state, the merge
    # silently dropped changes — revert and bounce to author.
    if [[ ! "$MERGE_RESULT" = failed* ]] && [ "$MERGE_RESULT" != "dry_run" ]; then
      log "Post-merge diff-integrity check (Bug 1b belt-and-suspenders) ..."
      git_rig fetch origin 2>/dev/null || warn "Post-merge fetch failed; integrity check may use stale refs"

      MERGED_HEAD=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
      INTEGRITY_FAIL=0
      INTEGRITY_MSG=""

      if [ -n "$MERGED_HEAD" ] && [ -n "$BRANCH_SHA" ]; then
        # For each file changed by the branch, compute:
        #   diff_in_branch   = lines added/removed by branch vs its base (pre-branch main)
        #   diff_in_merged   = what actually changed in merged main vs the original pre-merge main SHA
        # If a file was changed by the branch but shows ZERO net change in the
        # merged result vs pre-merge main, the fix was dropped.
        PRE_MERGE_MAIN="${MAIN_HEAD_SHA}"
        BRANCH_CHANGED_FILES=$(git_rig diff --name-only "${PRE_MERGE_MAIN}...origin/$BRANCH" 2>/dev/null || echo "")

        if [ -n "$BRANCH_CHANGED_FILES" ] && [ -n "$PRE_MERGE_MAIN" ]; then
          while IFS= read -r f; do
            [ -z "$f" ] && continue
            # Lines the branch added in this file (vs pre-merge main)
            # NOTE: `grep -c` ALREADY prints "0" on zero matches AND exits 1, so the old
            # `|| echo "0"` appended a SECOND "0" → the var became "0\n0" (multiline) →
            # the `[ "$X" -gt 0 ]` test below aborted the whole sweep under set -e
            # ([: 0\n0: integer expression expected). `|| true` keeps grep's single "0"
            # and neutralizes the exit code. Belt: strip to a bare integer.
            BRANCH_ADDITIONS=$(git_rig diff "$PRE_MERGE_MAIN" "origin/$BRANCH" -- "$f" 2>/dev/null | grep -c "^+" || true)
            BRANCH_ADDITIONS=$(printf '%s' "$BRANCH_ADDITIONS" | tr -dc '0-9'); BRANCH_ADDITIONS=${BRANCH_ADDITIONS:-0}
            # Lines that actually made it into merged main (vs pre-merge main)
            MERGED_ADDITIONS=$(git_rig diff "$PRE_MERGE_MAIN" "$MERGED_HEAD" -- "$f" 2>/dev/null | grep -c "^+" || true)
            MERGED_ADDITIONS=$(printf '%s' "$MERGED_ADDITIONS" | tr -dc '0-9'); MERGED_ADDITIONS=${MERGED_ADDITIONS:-0}

            # If branch added lines to a file but the merged result has ZERO
            # additions relative to pre-merge main, the file was completely dropped.
            if [ "$BRANCH_ADDITIONS" -gt 0 ] && [ "$MERGED_ADDITIONS" = "0" ]; then
              INTEGRITY_FAIL=1
              INTEGRITY_MSG="${INTEGRITY_MSG}File $f: branch had $BRANCH_ADDITIONS additions but merged main has 0 (DROPPED).\n"
              log "  INTEGRITY FAIL: $f — branch additions not in merged main"
            fi
          done <<< "$BRANCH_CHANGED_FILES"
        fi
      fi

      if [ "$INTEGRITY_FAIL" = "1" ]; then
        warn "Post-merge integrity FAILED — merge silently dropped branch changes. Reverting."
        # Revert the merge by resetting main back to pre-merge SHA
        REVERT_OK=0
        if [ -n "$MAIN_HEAD_SHA" ] && [ -n "$MERGED_HEAD" ] && [ "$MAIN_HEAD_SHA" != "$MERGED_HEAD" ]; then
          if git_rig push origin "${MAIN_HEAD_SHA}:refs/heads/$DEFAULT_BRANCH" --force-with-lease 2>/dev/null; then
            REVERT_OK=1
            log "  Main reverted to pre-merge SHA $MAIN_HEAD_SHA (merge SHA $MERGED_HEAD removed)"
          else
            err "  Revert push failed. Main may be in corrupted state. Manual intervention required."
          fi
        fi

        OVERALL_VERDICT="FAIL"
        REVERT_STATUS=$([ "$REVERT_OK" = "1" ] && echo "REVERTED (main restored to $MAIN_HEAD_SHA)" || echo "REVERT FAILED — manual fix required")
        FAIL_REASONS="Post-merge integrity check failed: merge silently dropped branch changes.
Files with dropped changes:
$(echo -e "$INTEGRITY_MSG")
Revert status: $REVERT_STATUS
Author must inspect conflict resolution and rebase + resubmit."

        # Comment on the source bead explaining what happened
        if [ -n "$BEAD_ID" ]; then
          bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:integrity-fail" -q 2>/dev/null || true
          bd -C "$BEAD_CITY" comment "$BEAD_ID" "GATE INTEGRITY FAIL: the merge of branch $BRANCH silently dropped your changes (conflict resolved to main's side).
$(echo -e "$INTEGRITY_MSG")
Revert: $REVERT_STATUS
Action required: rebase $BRANCH onto current main, resolve conflicts explicitly, and re-submit via /gate-done." 2>/dev/null || true
        fi

        # wa-uthi: TERMINAL FAIL (merge reverted, definitive) — this push is KEPT.
        notify -t "Quality Gate INTEGRITY FAIL" -p 4 "Branch $BRANCH merge dropped changes — reverted. Author: $AUTHOR" 2>/dev/null || true
        log "Post-merge integrity FAILED: $INTEGRITY_MSG — merge reverted ($REVERT_STATUS)"
      else
        log "Post-merge integrity check PASSED — branch changes present in merged main."
      fi
    fi
  fi

  if [ "$OVERALL_VERDICT" = "PASS" ]; then
    # ── ga-lzj2e: durable merge-survival ledger (async shared-remote defense) ──
    # ga-eptel's inline durable-landing AUDIT (do_merge_ff) only catches an
    # IN-FLIGHT clobber: by the time the gate exits, its audit window is closed.
    # The gastown rig SHARES remote athosmartins/gastown.git with the town main,
    # so a town-main push minutes/hours LATER can still orphan a just-merged
    # gastown SHA on the shared remote — fully async, after the gate is gone.
    # Record every CONTAINER-rig merge in a durable append-only ledger; the
    # gate-merge-survival-sweep daemon periodically re-fetches and re-verifies
    # each recent SHA is still an ancestor of origin/<default_branch>, then
    # self-heals (FF-only re-push when safe) or escalates (divergent clobber).
    # Container rigs only — a self-repo rig (wa, gascity) has no shared-remote
    # clobber vector. FULLY GUARDED: a ledger failure must NEVER affect the gate
    # outcome (every step `|| true` / non-fatal; runs only on a real merge SHA).
    if [ "$DRY_RUN" != "1" ] && [ "${IS_CONTAINER_RIG:-0}" = "1" ] \
       && printf '%s' "$MERGE_SHA" | grep -Eq '^[0-9a-f]{7,40}$'; then
      SURVIVAL_LEDGER="$GC_CITY/.gc/merge-survival-ledger.jsonl"
      mkdir -p "$GC_CITY/.gc" 2>/dev/null || true
      LEDGER_LINE=$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg rig "$RIG" --arg rig_path "$RIG_PATH" \
        --arg default_branch "$DEFAULT_BRANCH" --arg branch "$BRANCH" \
        --arg bead "${BEAD_ID:-}" --arg bead_city "${BEAD_CITY:-$GC_CITY}" \
        --arg marker "${MARKER_ID:-}" --arg gate_run "${GATE_RUN_ID:-}" \
        --arg merge_sha "$MERGE_SHA" \
        '{ts:$ts,rig:$rig,rig_path:$rig_path,default_branch:$default_branch,branch:$branch,bead:$bead,bead_city:$bead_city,marker:$marker,gate_run:$gate_run,merge_sha:$merge_sha}' \
        2>/dev/null || true)
      if [ -n "$LEDGER_LINE" ]; then
        printf '%s\n' "$LEDGER_LINE" >> "$SURVIVAL_LEDGER" 2>/dev/null \
          && log "  Survival-ledger: recorded $RIG merge_sha=$MERGE_SHA (ga-lzj2e async-clobber defense)" \
          || warn "  Survival-ledger: append failed (non-fatal)"
      fi
    fi

    # Update markers and beads for success
    set_gate_status "$MARKER_ID" "passed"
    # ga-jhyu: CLOSE the marker at terminal (passed) so it is reaped, not left
    # OPEN forever. Safe — no open-marker consumer scans gate-status:passed
    # (gate-health-monitor.py only scans gate-status:error). Idempotent.
    bd -C "$GC_CITY" close "$MARKER_ID" -r "Gate marker terminal: PASSED (branch $BRANCH merged sha=$MERGE_SHA). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true

    if [ "$GATE_RUN_ID" != "unknown" ]; then
      set_gate_status "$GATE_RUN_ID" "passed"
      bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate PASSED. Branch $BRANCH merged to $DEFAULT_BRANCH. SHA=$MERGE_SHA. Tier=$TIER. Reviewers=$REQUIRED_REVIEWERS. Elapsed=${ELAPSED_S}s. mode=${MERGE_RESULT}." 2>/dev/null || true
      # ga-jhyu: CLOSE the gate-run at terminal so wisp-compact reaps it.
      bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "gate-run terminal: PASSED (branch $BRANCH sha=$MERGE_SHA). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true
    fi

    # ── ga-esbg: DRIVE THE SOURCE BEAD TO ITS TERMINAL/HANDOFF STATE ──────────
    # A gate PASS+merge MUST NOT leave the source bead in_progress with the live
    # builder still assigned. The legacy PASS path only added gate:passed + a
    # comment, so the bead stayed in_progress with a live assignee: the pool
    # crash-recovery selector (bd list --status in_progress --assignee <builder>)
    # kept RE-SPAWNING the worker, and the Pilot's Tier-1 selectors kept
    # re-picking open bugs/tech-debt — a wasteful re-spawn loop (wa-krzm).
    # Mirror the already-merged short-circuit: drive the bead all the way to its
    # terminal state — CLOSE bugs/tasks; HAND OFF stories to delivery.
    if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
      # gate:passed is BOTH the success label AND story-delivery's pickup signal
      # (story-delivery selects story:approved + gate:passed, excluding story:done).
      bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "Quality gate PASSED. Branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA) via autonomous dispatcher (gate_run=$GATE_RUN_ID)." 2>/dev/null || true

      # Read the source bead state authoritatively (labels + live assignee).
      # ga-h199q: routed through the read-cache shim — the initial read of this
      # PASS-terminal block, before any writes to this bead in this invocation;
      # no concurrent legitimate writer at this lifecycle point (the builder
      # session is already done). The actual post-write confirmation is the
      # separate _still_listed() check below, which stays uncached (a real
      # verify-my-own-write read, not an informational one).
      SRC_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      SRC_LABELS=$(printf '%s' "$SRC_JSON" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")
      BUILDER_ASSIGNEE=$(printf '%s' "$SRC_JSON" | jq -r '.assignee // ""' 2>/dev/null || echo "")
      IS_STORY=0
      if printf '%s' "$SRC_LABELS" | grep -q "story:approved"; then IS_STORY=1; fi

      # ga-k2wjn: does the source bead's OWN body look like it enumerates
      # multiple approved deliverables? If so, "the gate approved this diff"
      # is NOT proof "this bead's full scope is done" — hold instead of
      # closing (bug/task path only; stories already hand off without
      # closing, see below). scope_covered:all is an explicit author
      # override — the cheaper of ga-k2wjn's two proposed mechanisms,
      # realized as a label instead of a new marker field so it needs no
      # gate-done.md/marker-schema change — for when the diff DOES cover
      # every enumerated item.
      IS_PARTIAL=0
      PARTIAL_EVIDENCE=""
      if [ "$IS_STORY" != "1" ]; then
        if printf '%s' "$SRC_LABELS" | grep -q "scope_covered:all"; then
          IS_PARTIAL=0
        else
          SRC_DESC=$(printf '%s' "$SRC_JSON" | jq -r '((.description // "") + "\n" + (.notes // ""))' 2>/dev/null || echo "")
          # ga-zhfk8: capture the detected list lines (stdout on a hit) so the
          # hold message below can CITE them instead of asserting without
          # showing (fix 3 of ga-zhfk8) — a human reviewer can then see in one
          # glance whether it's a real list or the heuristic's own prose.
          # ga-cjrxh: pass the TITLE as well. Across the 4 holds the Mayor
          # sampled on 2026-08-05 (3 of them false), the one signal that
          # separated the true positive from the false ones was an explicit
          # count in the title — wa-se0zu's "prod diverge do mockup em 8
          # pontos". The heuristic cannot use what it is never given.
          SRC_TITLE=$(printf '%s' "$SRC_JSON" | jq -r '.title // ""' 2>/dev/null || echo "")
          # ga-cjrxh AC3: the heuristic now NAMES its outcome on stderr —
          # held / released-with-warning / nothing-to-read were previously one
          # silent rc=1, so "the guard cleared this bead" and "the guard could
          # not read this bead" looked identical in the log. Capture it and
          # log it against the bead id so the distinction is greppable.
          PARTIAL_REASON_FILE=$(mktemp 2>/dev/null || echo "/tmp/gdlp-$$.err")
          if PARTIAL_EVIDENCE=$(gate_delivery_looks_partial "$SRC_DESC" "$SRC_TITLE" 2>"$PARTIAL_REASON_FILE"); then IS_PARTIAL=1; fi
          PARTIAL_REASON=$(tr '\n' ' ' < "$PARTIAL_REASON_FILE" 2>/dev/null || echo "")
          rm -f "$PARTIAL_REASON_FILE"
          # `|| true`: this is the last statement of the branch, and a bare
          # short-circuited AND-list must not become the block's exit status
          # under the errexit this script runs with.
          { [ -n "$PARTIAL_REASON" ] && log "escopo $BEAD_ID: $PARTIAL_REASON"; } || true
        fi
      fi

      # (1) Clear the live builder assignee on EVERY source bead. This is what
      #     removes it from the pool in_progress crash-recovery selector
      #     (--assignee <builder>) and from the Pilot's assigned-bead exclusion,
      #     breaking the re-spawn loop even if the close/handoff below fails.
      if [ -n "$BUILDER_ASSIGNEE" ]; then
        bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null \
          || warn "Could not clear builder assignee on source bead $BEAD_ID"
      fi

      # (2) Terminal vs handoff, decided by the canonical story marker
      #     (label story:approved — the type field is null for stories in bd;
      #     see story-delivery.sh / pilot-dispatcher.sh).
      if [ "$IS_STORY" = "1" ]; then
        # STORY → hand off to story-delivery (deploy + prod-test → story:done).
        # Leave it OPEN: delivery needs an open story:approved + gate:passed bead.
        # Pool re-spawn is already closed (assignee cleared above).
        # ga-3h8l: strip story:in-flight NOW (at merge). The lane slot MUST free
        # at merge — delivery may lag/fail, permanently eating a lane slot if we
        # wait. The Pilot's Tier-2 selector excludes gate:passed (see
        # pilot-dispatcher.sh), so stripping in-flight does NOT re-expose the
        # bead to re-dispatch.
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || true  # wa-qq33j: clear in-review state (PASS)
        log "Source story $BEAD_ID handed off to delivery (gate:passed set; story:in-flight + gate:reviewing cleared; builder assignee cleared)."
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate PASS handoff (ga-3h8l fix): builder assignee cleared; story:in-flight stripped (lane slot freed at merge); gate:reviewing cleared (wa-qq33j); story:approved + gate:passed in place. story-delivery will deploy + prod-test, then mark story:done." 2>/dev/null || true
      elif [ "$IS_PARTIAL" = "1" ]; then
        # ga-k2wjn: body looks multi-item and no scope_covered:all override —
        # hold, don't close. gate:passed (already set above) already keeps
        # Pilot from re-dispatching it; delivery:partial + scope:needs-review
        # is the durable "why" and puts it in front of a human instead of
        # letting the remaining scope silently exit every open-work queue.
        #
        # ga-6dpoa: this used to also add gate:needs-human(:partial-delivery).
        # That collided with the UNRELATED lifecycle-coherence-janitor R7 rule,
        # which treats any gate:needs-human* label as "not implementable" and
        # strips gc.routed_to — silently losing routing on beads that were
        # simply awaiting a scope glance, not blocked on anything. gate:passed
        # (untouched, above) already does the real job of keeping Pilot from
        # re-dispatching; scope:needs-review is a REVIEW signal, not a
        # blocking one, so it gets its own label outside the gate:needs-human
        # family instead of borrowing a label two systems then read differently.
        log "Source bug/task $BEAD_ID looks PARTIAL (ga-k2wjn heuristic) — holding, NOT closing; escalating to Mayor."
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || true  # wa-qq33j: clear in-review state (PASS)
        bd -C "$BEAD_CITY" label add "$BEAD_ID" "delivery:partial" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label add "$BEAD_ID" "scope:needs-review" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Quality gate PASSED and branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA) — but NOT closing (ga-k2wjn/ga-zhfk8): this bead body looks like it enumerates multiple approved deliverables (>=3 consecutive numbered or lettered list items — see detected lines below), and the gate only reviewed this one diff. The gate verdict is about the DIFF, not about whether the full scope of the BEAD is done — those are different claims. Labeled delivery:partial + scope:needs-review; Pilot will not re-dispatch it. If this diff genuinely covers every enumerated item, add label scope_covered:all and re-run the gate (or close manually).

$PARTIAL_EVIDENCE" 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate held for scope review: $BEAD_ID (ga-k2wjn)" \
          -m "$(printf 'Source bead %s PASSED the quality gate and merged (branch %s, sha %s, gate_run %s) but was NOT closed.\n\nga-k2wjn/ga-zhfk8: the bead body looks like it enumerates multiple approved deliverables (>=3 consecutive numbered or lettered list items), and a gate PASS only proves this one diff does what it claims, not that the full scope of the bead is done.\n\n%s\n\nLabeled delivery:partial + scope:needs-review; Pilot will not re-dispatch it.\n\nReview the diff against the full enumerated scope: if complete, add label scope_covered:all and close manually (or re-submit to the gate); if partial, the remaining items are still live on this bead.\n\nBead: %s   Rig: %s\nBranch: %s (gate run %s, sha %s)' \
            "$BEAD_ID" "$BRANCH" "$MERGE_SHA" "$GATE_RUN_ID" "$PARTIAL_EVIDENCE" "$BEAD_ID" "$RIG" "$BRANCH" "$GATE_RUN_ID" "$MERGE_SHA")" \
          2>/dev/null || warn "Could not mail Mayor scope-hold escalation for $BEAD_ID (ga-k2wjn)"
        # ga-409f4: NOTIFY_AUTHOR (branch-author-aware), not the bead-derived $AUTHOR.
        if [ -n "$NOTIFY_AUTHOR" ]; then
          gc --city "$GC_CITY" mail send "$NOTIFY_AUTHOR" \
            -s "Your gate PASS is held for scope review: $BEAD_ID (ga-k2wjn)" \
            -m "$(printf 'Your branch %s PASSED gate review and merged (sha %s), but the source bead %s was NOT closed.\n\nga-k2wjn/ga-zhfk8: the bead body looks like it enumerates multiple approved deliverables (>=3 consecutive numbered or lettered list items), and a gate PASS only proves this diff does what it claims, not that the full scope of the bead is done. Held as delivery:partial + scope:needs-review pending Mayor review.\n\n%s\n\nIf this diff genuinely covers every enumerated item, add label scope_covered:all and close manually (or re-submit to the gate); otherwise the remaining items are still live on this bead.\n\nBead: %s   Rig: %s\nBranch: %s (gate run %s)' \
              "$BRANCH" "$MERGE_SHA" "$BEAD_ID" "$PARTIAL_EVIDENCE" "$BEAD_ID" "$RIG" "$BRANCH" "$GATE_RUN_ID")" \
            2>/dev/null || warn "Could not mail author $NOTIFY_AUTHOR for scope-hold on $BEAD_ID (ga-k2wjn)"
        fi
      else
        # BUG/TASK → close it. bd list defaults to OPEN-only, so closing removes
        # the bead from EVERY open-work selector (Pilot Tier-1 bug & tech-debt),
        # and — combined with the assignee clear — from the pool crash-recovery
        # query. Closing is the durable fix for non-story source beads.
        log "Closing source bug/task $BEAD_ID (gate PASS + merged sha=$MERGE_SHA)."
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing" -q 2>/dev/null || true  # wa-qq33j: clear in-review state (PASS)
        bd -C "$BEAD_CITY" close "$BEAD_ID" \
          -r "Quality gate PASSED — branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA, gate_run=$GATE_RUN_ID). Closed by autonomous dispatcher (ga-esbg)." \
          2>/dev/null || warn "Could not close source bead $BEAD_ID"
      fi

      # (3) POST-MERGE VERIFICATION (ga-esbg): assert the source bead no longer
      #     appears in any re-spawn / re-pick selector the dispatcher knows about.
      #     If it does, a live loop vector remains — comment + escalate (never
      #     silently leave it).
      RESPAWN_HITS=""
      _still_listed() {  # 0 (true) iff $BEAD_ID is present in `bd list --json <args>`
        bd -C "$BEAD_CITY" list --json "$@" 2>/dev/null \
          | jq -e --arg id "$BEAD_ID" 'any(.[]?; .id == $id)' >/dev/null 2>&1
      }
      # a) Pool in_progress crash-recovery (applies to ALL beads — the core loop).
      if [ -n "$BUILDER_ASSIGNEE" ]; then
        if _still_listed --status in_progress --assignee "$BUILDER_ASSIGNEE"; then
          RESPAWN_HITS="$RESPAWN_HITS pool:in_progress+assignee=$BUILDER_ASSIGNEE"
        fi
      fi
      # b/c) Pilot Tier-1 open-bug / open-tech-debt re-pick. Stories are EXEMPT
      #      from Tier-1 checks (open for delivery; not type:bug / tech-debt).
      #      ga-k2wjn: a held-as-delivery:partial bead is ALSO exempt — it is
      #      deliberately left open+unassigned pending Mayor review, and would
      #      otherwise false-flag as a respawn vector here even though
      #      gate:passed already keeps Pilot from re-dispatching it.
      if [ "$IS_STORY" != "1" ] && [ "$IS_PARTIAL" != "1" ]; then
        if _still_listed -t bug;        then RESPAWN_HITS="$RESPAWN_HITS pilot:open-bug"; fi
        if _still_listed -l tech-debt;  then RESPAWN_HITS="$RESPAWN_HITS pilot:open-tech-debt"; fi
      fi
      # d) ga-3h8l: story lane-occupancy check. After PASS, story:in-flight must
      #    have been stripped (lane slot freed at merge). If still present, the
      #    slot is permanently leaked — escalate immediately.
      if [ "$IS_STORY" = "1" ]; then
        if _still_listed -l "story:in-flight"; then
          RESPAWN_HITS="$RESPAWN_HITS story:in-flight-leaked"
        fi
      fi

      if [ -n "$RESPAWN_HITS" ]; then
        warn "POST-MERGE re-spawn vector STILL PRESENT for $BEAD_ID:$RESPAWN_HITS"
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "WARNING (ga-esbg post-merge verify): source bead still appears in open-work selector(s) after gate PASS+merge:$RESPAWN_HITS. This is a re-spawn/re-pick vector — the terminal/handoff transition did not fully take." 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate post-merge: $BEAD_ID still re-pickable after PASS+merge" \
          -m "$(printf 'Source bead %s PASSED the quality gate and merged (branch %s, sha %s, gate_run %s) but still appears in open-work selector(s):%s\n\nThis leaves a re-spawn / re-pick vector (ga-esbg). The dispatcher could not drive it to terminal/handoff state — investigate (close failed? assignee clear failed? unexpected labels?).' \
            "$BEAD_ID" "$BRANCH" "$MERGE_SHA" "$GATE_RUN_ID" "$RESPAWN_HITS")" \
          2>/dev/null || warn "Could not mail Mayor post-merge re-spawn escalation for $BEAD_ID"
        notify -t "Gate post-merge vector" -p 3 "$BEAD_ID still re-pickable after PASS+merge:$RESPAWN_HITS" 2>/dev/null || true
      else
        log "Post-merge verify OK (ga-esbg): $BEAD_ID absent from all re-spawn/re-pick selectors."
      fi
    fi

    # ── ga-dcclose: REAP THE ORIGINATING COORDINATION WRAPPER AT THE MERGE ──────
    # BOUNDARY. The Pilot files a type:convoy sling wrapper per dispatch and the
    # engine deacon files dc-* coordination beads ("Merge failed", "Rebase
    # required", "T8.x merge-cycle"). Each is wired as a DEPENDENT that TRACKS the
    # source bead (dependency_type:tracks; the wrapper depends-on the source). When
    # the source PASS-merges, the wrapper's tracked work is DONE but nothing closes
    # it → it accrues OPEN forever. merged-bead-janitor's convoy-reconciler is the
    # eventual backstop (closes when ALL deps closed); closing HERE, at the merge
    # boundary, is immediate.
    #
    # SAFETY (mirrors the janitor's discipline — NO commit-matching, dependency
    # linkage ONLY): we ask "who TRACKS / depends-on the just-merged source?" via
    # `bd dep list <source> --direction=up` and close only OPEN dependents that are
    # unambiguous coordination wrappers (issue_type:convoy OR id prefix dc-). Any
    # other dependent (real follow-on work, stories, bugs) is LEFT UNTOUCHED. If we
    # cannot confidently enumerate wrappers (query fails / unreadable), we do
    # NOTHING and let the janitor backstop handle it. EVERY step is `|| true`-
    # guarded and idempotent: a close failure here MUST NEVER abort the merge — the
    # merge is the critical operation; this cleanup is strictly best-effort. Runs
    # ONLY on the PASS/merge-success path (inside `if OVERALL_VERDICT = PASS`,
    # after a real MERGE_SHA), never on FAIL.
    if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
      WRAPPER_DEPS_JSON="$(bd -C "$BEAD_CITY" dep list "$BEAD_ID" --direction=up --json 2>/dev/null || echo "")"
      # Select OPEN (non-closed) dependents that are coordination wrappers:
      # issue_type:convoy OR id prefixed dc-. Closed ones are already reaped.
      WRAPPER_IDS="$(printf '%s' "$WRAPPER_DEPS_JSON" \
        | jq -r '(if type=="array" then . else [] end)
                 | [ .[]?
                     | select((.status // "") != "closed")
                     | select(((.issue_type // .type // "") == "convoy")
                              or (((.id // "") | startswith("dc-"))))
                     | .id ] | unique | .[]' 2>/dev/null || echo "")"
      if [ -n "$WRAPPER_IDS" ]; then
        for _WID in $WRAPPER_IDS; do
          [ -z "$_WID" ] && continue
          [ "$_WID" = "$BEAD_ID" ] && continue   # never self-close the source
          if bd -C "$BEAD_CITY" close "$_WID" \
               -r "reaped: work merged (gate PASS) — coordination wrapper closed (source $BEAD_ID, branch $BRANCH, sha=$MERGE_SHA, gate_run=$GATE_RUN_ID; ga-dcclose)" \
               2>/dev/null; then
            log "ga-dcclose: reaped coordination wrapper $_WID (tracks merged source $BEAD_ID)."
          else
            # Non-fatal: an already-closed/obsolete sibling dep can make bd refuse a
            # clean close. Leave it for the janitor convoy-reconciler backstop.
            warn "ga-dcclose: could not close wrapper $_WID for $BEAD_ID (non-fatal — janitor backstop will retry)."
          fi
        done
      else
        log "ga-dcclose: no open coordination wrapper depends on $BEAD_ID — nothing to reap."
      fi
    fi

    # wa-uthi: TERMINAL SUCCESS (merged to prod).
    # ga-opyus: force digest/infra, not signal — orchestration is the Mayor's radar.
    # $BRANCH is free text (from the bead title) and can accidentally match a
    # push-trigger keyword (e.g. "needs-human"), so plain allowlist routing isn't enough.
    # wa-wzvg: differentiate the merge push for Pilot-origin stories. The Pilot
    # sets a durable "pilot:dispatched" label when it autonomously pulls a story
    # (see pilot-dispatcher.sh). If present, use a distinct prefix/emoji so Athos
    # can tell an autonomous Pilot merge apart from a human/Mayor-dispatched one.
    PILOT_ORIGIN=0
    if [ -n "$BEAD_ID" ]; then
      # ga-h199q: routed through the read-cache shim — cosmetic-only read (picks
      # a notification emoji/prefix), no state transition depends on it.
      BEAD_LABELS_NOW=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
      if echo "$BEAD_LABELS_NOW" | grep -q "pilot:dispatched"; then
        PILOT_ORIGIN=1
      fi
    fi
    if [ "$PILOT_ORIGIN" = "1" ]; then
      NOTIFY_FORCE_DIGEST=1 notify -k gate-pass -t "🤖 Pilot Gate PASSED" -p 2 "🤖 [Pilot] Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s (autonomous pickup)" 2>/dev/null || true
      log "Gate PASSED (origin=Pilot): branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
    else
      NOTIFY_FORCE_DIGEST=1 notify -k gate-pass -t "Quality Gate PASSED" -p 2 "Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
      log "Gate PASSED: branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
    fi
    supersede_sibling_runs "$MARKER_ID" "$BRANCH" "$BEAD_ID"
  fi

else
  # ── FAIL path ─────────────────────────────────────────────────────────────
  log "Gate FAILED: $FAIL_REASONS"

  set_gate_status "$MARKER_ID" "failed"
  # ga-jhyu: CLOSE the marker at terminal (failed) so it is reaped. A FAIL is
  # terminal for THIS gate attempt — re-running /gate-done mints a fresh marker.
  # Safe: no open-marker consumer scans gate-status:failed. Idempotent.
  bd -C "$GC_CITY" close "$MARKER_ID" -r "Gate marker terminal: FAILED (branch $BRANCH). Re-gate mints a new marker. Closed by dispatcher (ga-jhyu)." 2>/dev/null || true

  if [ "$GATE_RUN_ID" != "unknown" ]; then
    set_gate_status "$GATE_RUN_ID" "failed"
    bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate FAILED.
Branch: $BRANCH
Tier: $TIER  Reviewers required: $REQUIRED_REVIEWERS
Elapsed: ${ELAPSED_S}s

Blocking reasons:
$(echo -e "$FAIL_REASONS")" 2>/dev/null || true
    # ga-jhyu: CLOSE the gate-run at terminal so wisp-compact reaps it.
    bd -C "$GC_CITY" close "$GATE_RUN_ID" -r "gate-run terminal: FAILED (branch $BRANCH). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true
  fi

  # Notify the author (not the Mayor) via nudge. ga-409f4: NOTIFY_AUTHOR
  # (branch-author-aware), not the bead-derived $AUTHOR — see this
  # function's header comment.
  if [ -n "$NOTIFY_AUTHOR" ]; then
    gc --city "$GC_CITY" session nudge "$NOTIFY_AUTHOR" \
      "QUALITY GATE FAILED for branch $BRANCH. Blocking reasons: $(echo -e "$FAIL_REASONS" | head -3). Gate run: $GATE_RUN_ID. Fix the issues and re-run /gate-done when ready." \
      --delivery wait-idle 2>/dev/null || warn "Could not nudge author $NOTIFY_AUTHOR (session may not exist)"
  fi

  # ── ga-jb4l: SELF-HEALING FAIL LOOP ────────────────────────────────────────
  # A gate FAIL must not strand the source story forever. The legacy FAIL path
  # only touched the EPHEMERAL marker/gate-run beads and an ephemeral author
  # session nudge — no durable feedback reached the SOURCE bead and no actor
  # ever re-picked it (the Pilot's selection hid it: features by story:in-flight,
  # bugs by a stale builder assignee). Here we close that loop:
  #   (a) attach the FAILing reviewer reasons to the SOURCE bead (durable),
  #   (b) transition it to a Pilot-re-dispatchable gate:needs-fix state, and
  #   (c) cap auto-retry at N=3, escalating to a human (Mayor) exactly once.
  # FAIL_REASONS is already populated upstream (and, post-ga-kf0v, carries the
  # real reviewer .text reasons), so the feedback we attach is substantive.
  if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
    GATE_FIX_CAP=3

    # Read the source bead's current labels (story beads live in the HQ/city DB).
    # ga-h199q: routed through the read-cache shim — first read in the FAIL
    # self-healing block (no prior write to THIS bead in this invocation to
    # verify). The fix-attempt bump below removes every stale counter label by
    # a loop, not a single value, so a few-seconds-old label snapshot cannot
    # cause it to miss a label that didn't exist yet at read time.
    SRC_LABELS=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
      2>/dev/null || echo "")

    # Current fix-attempt count from label gate:fix-attempt:N (default 0).
    # ga-26df: coexisting counters happen ONLY via a manual clear — the
    # automatic increment path below always removes every stale counter
    # before adding the new one (see "Bump the attempt counter" below), so
    # it alone can never leave more than one behind. Taking the MAX here
    # "in case multiple counter labels ever coexist" was exactly backwards:
    # coexistence IS the manual clear's signature, and a reset always adds
    # a LOWER number than the stale one it's resetting — so MAX silently
    # discarded every manual clear (0 added alongside a stale N>0 always
    # resolved to N). Plain MIN over-corrects, though — the reviewer (ga-wisp-198xqe)
    # showed coexistence is NOT manual-clear-only. The "Bump the attempt counter" loop
    # below removes each stale label with `bd ... label remove ... || true`; a transient
    # Dolt hiccup (routine here — hence the `|| true`) leaves the stale label behind, so
    # the AUTOMATIC path alone can produce {1,2}. MIN reads that as 1 and the counter
    # STALLS below the cap: silent, unbounded, machine-only retries — worse than the
    # ignored-reset bug (which at least has a human in the loop). So: an explicit `:0`
    # is the RESET SENTINEL and always wins (the human's clear); with no `:0`, take MAX
    # so a {1,2} residue still advances toward GATE_FIX_CAP instead of stalling.
    _ATTEMPTS=$(printf '%s' "$SRC_LABELS" | tr ' ' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p')
    if printf '%s\n' "$_ATTEMPTS" | grep -qx 0; then
      PREV_ATTEMPT=0                                              # reset sentinel → reset wins
    else
      PREV_ATTEMPT=$(printf '%s\n' "$_ATTEMPTS" | sort -n | tail -1)   # else MAX (cap-safe)
    fi
    [ -z "$PREV_ATTEMPT" ] && PREV_ATTEMPT=0

    # (a) ATTACH FEEDBACK TO THE SOURCE BEAD — durable, machine-readable marker
    #     (prefix "GATE-FEEDBACK") so the Pilot can surface it to the re-dispatched
    #     builder verbatim.
    bd -C "$BEAD_CITY" comment "$BEAD_ID" "$(printf 'GATE-FEEDBACK (gate_run=%s branch=%s): quality gate FAILED. Fix THESE specific blocking issues, then run /gate-done to re-gate.\n\n%s' \
      "$GATE_RUN_ID" "$BRANCH" "$(echo -e "$FAIL_REASONS")")" \
      2>/dev/null || warn "Could not attach gate feedback to source bead $BEAD_ID"
    bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:failed" -q 2>/dev/null || true
    if [ -n "$BRANCH_SHA" ]; then
      # ga-nooaw: stamp this exact commit as rejected — see
      # gate_bead_has_prior_sha_fail, checked before the PASS/FAIL branch
      # above, before ANY future run (same SHA) is allowed to merge it.
      bd -C "$BEAD_CITY" label add "$BEAD_ID" "$(gate_sha_fail_label "$BRANCH_SHA")" -q 2>/dev/null || true
    fi

    if [ "$PREV_ATTEMPT" -ge "$GATE_FIX_CAP" ]; then
      # (c) RETRY CAP REACHED — stop auto-retry, escalate to the Mayor ONCE.
      log "Gate fix-attempt cap reached for $BEAD_ID (prev=$PREV_ATTEMPT >= $GATE_FIX_CAP). Escalating; no further auto-retry."
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:needs-fix"   -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human"           -q 2>/dev/null || true
      # imp13: sub-label classifies this as a TECHNICAL circuit-breaker park (not a product decision).
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human:technical" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate auto-fix cap ($GATE_FIX_CAP attempts) exhausted — labeled gate:needs-human. The machine could not resolve this after $GATE_FIX_CAP fix cycles; the Pilot will NOT re-dispatch it. Human/Mayor intervention required." 2>/dev/null || true
      # imp13: emit human-touch ledger entry (technical kind) for 99% metric.
      { source "$GC_CITY/scripts/gc-ledger.sh" 2>/dev/null && \
        gc_ledger_append "human-touch" "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source_daemon\":\"quality-gate-dispatcher\",\"stage\":\"executa\",\"kind\":\"technical\",\"bead_id\":\"${BEAD_ID}\",\"reason\":\"Gate fix-cap exhausted (${GATE_FIX_CAP} attempts) — circuit-breaker park\"}"; } 2>/dev/null || true
      # Escalate EXACTLY once: only mail if gate:needs-human was not already set.
      if ! printf '%s' "$SRC_LABELS" | grep -q "gate:needs-human"; then
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate needs-human: $BEAD_ID exhausted $GATE_FIX_CAP fix attempts" \
          -m "$(printf 'Source bead %s failed the quality gate %s times. Auto-retry is now DISABLED (label gate:needs-human); the Pilot will not re-dispatch it.\n\nBranch: %s\nRig: %s\nGate run: %s\n\nLast blocking reasons:\n%s\n\nA human or the Mayor must intervene.' \
            "$BEAD_ID" "$((GATE_FIX_CAP + 1))" "$BRANCH" "$RIG" "$GATE_RUN_ID" "$(echo -e "$FAIL_REASONS")")" \
          2>/dev/null || warn "Could not mail Mayor escalation for $BEAD_ID"
        notify -t "Gate needs-human" -p 4 "$BEAD_ID exhausted $GATE_FIX_CAP gate fix attempts — Mayor escalated" 2>/dev/null || true
        # ga-u4yi: durable mail to the AUTHOR too — a bd comment alone left
        # thies-wa's branch rotting 20h in silence because nothing durable told
        # her she was stuck (only Mayor was mailed; mail, not nudge, survives a
        # dead/restarted author session). ga-409f4: NOTIFY_AUTHOR
        # (branch-author-aware), not the bead-derived $AUTHOR.
        if [ -n "$NOTIFY_AUTHOR" ]; then
          gc --city "$GC_CITY" mail send "$NOTIFY_AUTHOR" \
            -s "Gate needs-human: your branch $BRANCH exhausted $GATE_FIX_CAP fix attempts" \
            -m "$(printf 'Your branch %s (bead %s) failed the quality gate %s times. Auto-retry is now DISABLED (label gate:needs-human): the Pilot will NOT re-dispatch this bead, and any further /gate-done resubmission will be silently parked until a human resolves this.\n\nGate run: %s\n\nLast blocking reasons:\n%s\n\nA human or the Mayor must intervene before this can proceed.' \
              "$BRANCH" "$BEAD_ID" "$((GATE_FIX_CAP + 1))" "$GATE_RUN_ID" "$(echo -e "$FAIL_REASONS")")" \
            2>/dev/null || warn "Could not mail author $NOTIFY_AUTHOR for gate-fix-cap escalation on $BEAD_ID"
        fi
      fi
      # ga-5w0hr: a needs-human bead has NO active worker — the gate just gave up
      # auto-retry. Mirror the needs-fix-branch cleanup so the bead is honestly
      # represented as "awaiting human" rather than masquerading as in-flight.
      # gate:needs-human (which the Pilot EXCLUDES in every candidate query —
      # pilot-dispatcher.sh) remains the re-dispatch block; this only strips the
      # contradictory story:in-flight / pilot:* claim + stale builder assignee
      # left over from the failed dispatch, which otherwise stranded the bead
      # looking forever in-flight with no worker (ga-jhyu: 21h SEM WORKER after
      # 3× FAIL). Re-dispatch policy is unchanged — needs-human still requires
      # Human/Mayor intervention to clear.
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"   -q 2>/dev/null || true  # wa-qq33j: clear in-review state (cap/needs-human)
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null || true
    else
      # (b) TRANSITION TO A PILOT-RE-DISPATCHABLE needs-fix STATE.
      NEW_ATTEMPT=$((PREV_ATTEMPT + 1))
      log "Marking $BEAD_ID gate:needs-fix (attempt $NEW_ATTEMPT/$GATE_FIX_CAP) for autonomous Pilot re-dispatch."
      # Bump the attempt counter (drop any stale counters first).
      for OLD in $(printf '%s' "$SRC_LABELS" | tr ' ' '\n' | grep '^gate:fix-attempt:'); do
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "$OLD" -q 2>/dev/null || true
      done
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:fix-attempt:${NEW_ATTEMPT}" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-fix"                  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"   -q 2>/dev/null || true  # wa-qq33j: clear in-review state (FAIL/needs-fix)
      # Clear stale Pilot claim labels left over from the failed dispatch.
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true

      # ga-jyox: a live named-crew author (long-lived session, e.g. thies-wa) must
      # KEEP ownership on FAIL instead of being cleared — see gate_fail_assignee_action
      # above for the full rationale (ga-1url/ga-u4yi double-dispatch collision).
      # ga-ipf6: unified with the rebase-path AUTHOR_ALIVE via author_is_alive()
      # — this call site's predicate was already canonical; it is now the
      # single source of truth both paths share.
      FAIL_AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")

      # ga-pyzo: recycled-session fallback (same helper as the rebase-path call
      # site above — single source of truth so the two paths cannot re-diverge,
      # the exact ga-ipf6 lesson). Applied BEFORE gate_fail_assignee_action so a
      # live agent whose specific FAILing session recycled gets "keep" (nudged
      # to fix), not "clear" (silently handed to a stranger builder).
      _RESOLVED_AUTHOR=$(resolve_recycled_author "$AUTHOR" "$AUTHOR_AGENT" "$FAIL_AUTHOR_ALIVE")
      if [ "$_RESOLVED_AUTHOR" != "$AUTHOR" ]; then
        log "  ga-pyzo: author '$AUTHOR' session recycled but agent '$_RESOLVED_AUTHOR' has a live session — redirecting liveness/nudge/assign to the agent."
        AUTHOR="$_RESOLVED_AUTHOR"
        FAIL_AUTHOR_ALIVE=1
      fi

      GATE_FAIL_ASSIGNEE_ACTION=$(gate_fail_assignee_action "$AUTHOR" "$FAIL_AUTHOR_ALIVE")

      if [ "$GATE_FAIL_ASSIGNEE_ACTION" = "keep" ]; then
        log "Author $AUTHOR is a live named-crew session — keeping assignee + story:in-flight (ga-jyox); nudging feedback instead of letting the Pilot dispatch a stranger on top of in-flight work."
        bd -C "$BEAD_CITY" assign "$BEAD_ID" "$AUTHOR" 2>/dev/null || true
        # ga-n7hu2: this arm used to leave story:in-flight untouched — relying on
        # it never having been removed — while the comment below claimed
        # UNCONDITIONALLY that both fields were kept. Measured in the field
        # (wa-e7ey9, 18/07 15:53 via bd show --json raw): assignee was present
        # but story:in-flight was ABSENT. Half the claim was false, and worse —
        # a success report that isn't true is the reason nobody re-checks it
        # (root-class:error-vs-empty). Fix: (1) actively (re)add the label here
        # so "kept" holds regardless of what an earlier/concurrent step did to
        # it, then (2) re-read the RAW post-write state (not cache, not intent)
        # and let the comment say what was actually observed. The assignee path
        # is left as-is (unconfirmed whether it was ever actually broken —
        # AC4 of ga-n7hu2 — this only adds visibility, it does not presume a fix).
        bd -C "$BEAD_CITY" label add "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true
        # The verify-read must NOT be a bare assignment: this script runs under
        # `set -euo pipefail` (global), so a non-zero `bd show` — realistic given
        # Dolt's documented fragility — would abort the WHOLE dispatcher, killing
        # finalization of every other gate run pending in the same sweep, silently
        # (gate_finalize_run is called as a bare statement from Phase C's loop).
        # But guarding with a plain `|| echo ""` is NOT enough either: an empty
        # result would then flow into the comparisons below and be reported as
        # "keep action did not stick", i.e. a READ FAILURE would be published as a
        # WRITE FAILURE — a false accusation, and the exact error-vs-empty class
        # this bead exists to kill (ga-p5q3). So track the read outcome separately
        # and let "could not verify" be its own visible, contained third state.
        KEEP_VERIFY_JSON=""
        KEEP_VERIFY_READ_OK=1
        KEEP_VERIFY_JSON=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null) || KEEP_VERIFY_READ_OK=0
        [ -n "$KEEP_VERIFY_JSON" ] || KEEP_VERIFY_READ_OK=0
        if [ "$KEEP_VERIFY_READ_OK" = "0" ]; then
          KEEP_ASSIGNEE_OBS="assignee=UNVERIFIED (post-write read failed — state unknown, NOT a claim that the keep failed)"
          KEEP_INFLIGHT_OBS="story:in-flight=UNVERIFIED (post-write read failed)"
        else
          KEEP_VERIFY_ASSIGNEE=$(printf '%s' "$KEEP_VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | .assignee // ""' 2>/dev/null || echo "")
          KEEP_VERIFY_HAS_INFLIGHT=$(printf '%s' "$KEEP_VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | ((.labels // []) | index("story:in-flight")) != null' 2>/dev/null || echo "false")
          if [ "$KEEP_VERIFY_ASSIGNEE" = "$AUTHOR" ]; then
            KEEP_ASSIGNEE_OBS="assignee=$AUTHOR (kept)"
          else
            KEEP_ASSIGNEE_OBS="assignee='${KEEP_VERIFY_ASSIGNEE}' NOT $AUTHOR — keep action did not stick, needs investigation"
          fi
          if [ "$KEEP_VERIFY_HAS_INFLIGHT" = "true" ]; then
            KEEP_INFLIGHT_OBS="story:in-flight=present"
          else
            KEEP_INFLIGHT_OBS="story:in-flight=MISSING even after re-add — needs investigation"
          fi
        fi
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate FAILED (attempt ${NEW_ATTEMPT}/${GATE_FIX_CAP}) — labeled gate:needs-fix; gate:reviewing cleared (wa-qq33j). Author $AUTHOR is a LIVE crew session, so this dispatcher acted to KEEP assignee + story:in-flight (ga-jyox) instead of letting the Pilot dispatch a stranger — verified post-write on the raw bead, not display: $KEEP_ASSIGNEE_OBS; $KEEP_INFLIGHT_OBS. See GATE-FEEDBACK above; re-run /gate-done after fixing." 2>/dev/null || true
        # ga-409f4: the NUDGE target is NOTIFY_AUTHOR (branch-author-aware) —
        # the assignee-keep decision above stays on $AUTHOR (bead ownership
        # is a separate concern from who wrote the code; see this
        # function's header comment).
        gc --city "$GC_CITY" session nudge "$NOTIFY_AUTHOR" \
          "Gate FAILED for $BEAD_ID (branch $BRANCH, attempt ${NEW_ATTEMPT}/${GATE_FIX_CAP}) — see GATE-FEEDBACK on the bead. Your assignee was kept (ga-jyox); fix and re-run /gate-done." \
          --delivery wait-idle 2>/dev/null || warn "Could not nudge live-crew author $NOTIFY_AUTHOR for gate FAIL feedback"
        # ga-7rvyt: gc hook / routed-pool surfacing has no live-in-flight-owner
        # guard (unlike Pilot's _filter_candidates), so a bead kept in-flight
        # here for a live crew author was still re-offered to generic pool
        # workers via its stale gc.routed_to whenever a later gate-review
        # cycle's Step 5b (quality-gate-guard.sh) transiently blanks the
        # assignee again. The marker was already closed terminal-FAILED above,
        # so gate:queued has no live marker behind it either. Strip both —
        # mirrors quality-gate-guard.sh Step 5b's exact unset-metadata pattern
        # (ga-e7zk7/gt-gwng6). No-op when gc.routed_to lives on a sling bead
        # instead of this source bead (current default dispatch model).
        bd -C "$BEAD_CITY" update "$BEAD_ID" --unset-metadata gc.routed_to -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:queued" -q 2>/dev/null || true
      else
        # Remove story:in-flight so the Pilot's feature-exclusion no longer hides it.
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"  -q 2>/dev/null || true
        # The Pilot's _filter_candidates drops ASSIGNED beads (both Tier-1 bugs and
        # Tier-2 features), so a stale builder assignee makes a failed bead invisible.
        # Clear it so the next sweep can re-pick this bead.
        bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null || true
        # ga-f54ui: this branch used to say "the Pilot will re-dispatch a builder"
        # without making that true. quality-gate-guard.sh Step 5b (ga-e7zk7) strips
        # gc.routed_to from the source bead unconditionally at gate-CLAIM time —
        # every review, pass or fail — expecting the Pilot's OWN re-dispatch to set
        # it fresh on the next sweep. Nothing on THIS path (the fail-and-return-to-
        # pool branch) ever did that, so a bead could sit ctx:ready + unassigned,
        # invisible to every pool worker's self-serve probe
        # (`bd ready --metadata-field gc.routed_to=<target> --unassigned`), for as
        # long as it took some UNRELATED event to next touch the field — measured
        # live at up to 13 days (ga-f54ui's own incident report, 8 beads same-day).
        # Restore it directly here, the same way a human/Mayor was doing it by
        # hand (rig -> default pool template) — see default_pool_route_for_rig
        # above for the mapping and why it is duplicated, not shared, with
        # pilot-dispatcher.sh's rig_to_builder()+wa_worker_template().
        _GFAIL_ROUTE=$(default_pool_route_for_rig "$RIG")
        bd -C "$BEAD_CITY" update "$BEAD_ID" --set-metadata "gc.routed_to=$_GFAIL_ROUTE" -q 2>/dev/null || true
        # Verify the write actually stuck (ga-p5q3 error-vs-empty discipline) — a
        # post-write READ failure must never be reported as "restore failed"; it is
        # its own third state, distinct from both success and a confirmed failure.
        _GFAIL_ROUTE_VERIFY_JSON=""
        _GFAIL_ROUTE_VERIFY_READ_OK=1
        _GFAIL_ROUTE_VERIFY_JSON=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null) || _GFAIL_ROUTE_VERIFY_READ_OK=0
        [ -n "$_GFAIL_ROUTE_VERIFY_JSON" ] || _GFAIL_ROUTE_VERIFY_READ_OK=0
        if [ "$_GFAIL_ROUTE_VERIFY_READ_OK" = "0" ]; then
          _GFAIL_ROUTE_OBS="gc.routed_to=UNVERIFIED (post-write read failed — state unknown, NOT a claim the restore failed)"
        else
          _GFAIL_ROUTE_OBSERVED=$(printf '%s' "$_GFAIL_ROUTE_VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | .metadata["gc.routed_to"] // ""' 2>/dev/null || echo "")
          if [ "$_GFAIL_ROUTE_OBSERVED" = "$_GFAIL_ROUTE" ]; then
            _GFAIL_ROUTE_OBS="gc.routed_to=$_GFAIL_ROUTE (restored)"
          else
            _GFAIL_ROUTE_OBS="gc.routed_to='${_GFAIL_ROUTE_OBSERVED}' NOT $_GFAIL_ROUTE — restore did not stick, needs investigation"
          fi
        fi
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Gate FAILED (attempt ${NEW_ATTEMPT}/${GATE_FIX_CAP}) — labeled gate:needs-fix; story:in-flight + gate:reviewing (wa-qq33j) and builder assignee cleared. gc.routed_to restored to $_GFAIL_ROUTE so pool workers can self-serve this bead (ga-f54ui) — verified post-write, not assumed: $_GFAIL_ROUTE_OBS. The Pilot will also re-dispatch a builder with the GATE-FEEDBACK above." 2>/dev/null || true
      fi
    fi
  fi

  # wa-uthi: TERMINAL FAIL (review rejected, definitive) — this push is KEPT.
  notify -t "Quality Gate FAILED" -p 3 "Branch $BRANCH failed review — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
  supersede_sibling_runs "$MARKER_ID" "$BRANCH" "$BEAD_ID"
fi

# ── Step 11: Log to quality-gate.jsonl ───────────────────────────────────────

mkdir -p "$(dirname "$QG_LOG")"
REASON=""
if [ "$OVERALL_VERDICT" = "PASS" ]; then
  REASON="quorum_${REQUIRED_REVIEWERS}_of_${REQUIRED_REVIEWERS}_independent_sessions"
else
  REASON=$(echo -e "$FAIL_REASONS" | head -1 | tr '\n' ' ' | cut -c1-200)
fi

jq -c -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg branch "$BRANCH" \
  --arg bead "$BEAD_ID" \
  --arg rig "${RIG:-unknown}" \
  --arg tier "$TIER" \
  --arg result "$OVERALL_VERDICT" \
  --arg reason "$REASON" \
  --arg gate_run "$GATE_RUN_ID" \
  --arg marker "$MARKER_ID" \
  --argjson elapsed_s "$ELAPSED_S" \
  --argjson reviewers "$REQUIRED_REVIEWERS" \
  --arg dry_run "$DRY_RUN" \
  '{ts: $ts, event: "dispatcher_complete", branch: $branch, bead: $bead,
    rig: $rig, tier: $tier, result: $result, reason: $reason,
    gate_run: $gate_run, marker: $marker, elapsed_s: $elapsed_s,
    reviewers: $reviewers, dry_run: $dry_run}' \
  >> "$QG_LOG" 2>/dev/null || true

# ga-eqjo (code-review fix): this used to be the literal LAST line of the
# script, so "sweep complete" correctly meant "the one marker this process
# claimed and blocked on is fully done." It no longer is: this line lives
# inside gate_finalize_run(), callable from Phase C's per-run loop (0, 1, or
# N times per sweep — however many gate-runs were finalized this sweep) as
# well as the same-sweep fast path. Naming it "gate run complete" instead of
# "Dispatcher sweep complete" keeps a 1:1 invariant honest for any log
# scraper: one line per FINALIZED RUN, not one per sweep (the "Dispatcher
# sweep start" line just above Phase C, logged exactly once per process
# invocation, is the only genuine per-sweep marker left).
log "=== Gate run complete: gate_run=$GATE_RUN_ID branch=$BRANCH verdict=$OVERALL_VERDICT elapsed=${ELAPSED_S}s ==="
}
# ── ga-eqjo: rig-plumbing helpers, hoisted so Phase C (which runs before any
# marker may be claimed this sweep) can resolve a PREVIOUSLY-claimed run's git
# context without waiting for Step 4 to run in THIS invocation. No logic below
# changed from its historical Step-4-adjacent form — pure relocation. Bash
# resolves a function call against whatever has been DEFINED so far at that
# point in execution (not by textual position), so moving these earlier
# changes nothing about how they behave, only when they become callable.

# SELFTEST-EXTRACT resolve-bead-city-fn: BEGIN
resolve_bead_city() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    # ga-h199q: routed through the read-cache shim — pure store-discovery probe
    # (which DB has this bead), not a state decision; a bead's home store never
    # changes within a gate run's lifetime.
    st=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  # Neither store resolved (transient Dolt issue): prefix heuristic. The HQ city
  # prefix is `ga` (gascity); every other prefix is a rig.
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}
# SELFTEST-EXTRACT resolve-bead-city-fn: END

git_rig() {
  if [ "$IS_CONTAINER_RIG" = "1" ]; then
    git --git-dir="$GIT_DIR_PATH" "$@"
  else
    git -C "$GIT_DIR_PATH" "$@"
  fi
}

# ── ga-ljbx: hardened ref resolution (defense-in-depth) ───────────────────────
# rig_resolve_commit <ref> — resolve <ref> to a real COMMIT object SHA.
#
# Plain `git rev-parse origin/main` returns whatever 40-hex string the ref file
# holds, EVEN IF that object is missing from the object DB (e.g. a ref left
# dangling by a racing/aborted fetch or a competing reconciler). That garbage SHA
# then poisons every downstream merge-base/merge-tree computation: merge-base
# returns empty ("no common ancestor"), the branch is misclassified as having
# unrelated histories, and a perfectly clean stale branch is bounced to
# needs-rebase with a non-existent main_sha (observed live on ga-tmug:
# main_sha=7b03eb9a… / e7949128…, neither of which exists in the repo).
#
# `git rev-parse --verify -q <ref>^{commit}` forces the ref to dereference to a
# real, present commit object. On a missing/garbage object it prints NOTHING and
# returns nonzero — callers can then distinguish "ref points at garbage" (→ treat
# as a transient/re-triable error, gate-status:error) from "clean stale branch"
# (→ auto-rebase). Output is empty on failure so `[ -z "$X" ]` guards trip.
rig_resolve_commit() {
  git_rig rev-parse --verify -q "$1^{commit}" 2>/dev/null || echo ""
}

# rig_content_merged <main_ref> <branch_ref> — ga-01yq: SHA-ancestry is FALSE BY
# CONSTRUCTION after a rebase-merge (the gate's own auto-rebase, or any manual
# rebase, replays commits under NEW shas) — a fully-merged branch never becomes
# an ancestor again, so a naive `merge-base --is-ancestor` strands it on
# needs-rebase FOREVER, and the suggested manual-rebase remediation can then
# re-submit PRE-REBASE file versions on top of newer work already in main (a
# real regression, not just noise — see ga-01yq / batista-wa's wa-jaxt8 catch
# and the peter/ga-fr5d near-miss).
#
# rc0 iff EVERY commit reachable from <branch_ref> but not <main_ref> already
# has its patch present on the <main_ref> side (git matches rebased/squashed/
# re-committed changes by patch-id) — i.e. the branch's content is fully
# merged regardless of SHA lineage. Mirrors merged-bead-janitor.sh's
# content_in_main() (proven on ga-tijv5/wa-fvxj1); duplicated here rather than
# sourced because each gate daemon is a self-contained script with its own
# small git-check helpers (see git_rig/rig_resolve_commit above) — there is no
# existing cross-script import convention for these.
#
# FAIL-CLOSED: any non-"0"/empty/error count → rc1 (treated as NOT merged), so
# callers keep bouncing to the existing (safe) needs-rebase path on any doubt.
rig_content_merged() {
  local main_ref="$1" branch_ref="$2"
  local n
  n=$(git_rig rev-list --count --cherry-pick --right-only "${main_ref}...${branch_ref}" 2>/dev/null || echo ERR)
  [ "$n" = "0" ]
}

# SELFTEST-EXTRACT gate-mergedriver-precheck: BEGIN
# ── ga-78n2z: union-aware conflict pre-check ──────────────────────────────────
# GATE_UNION_AWARE_PRECHECK=1 (default ON) makes the merge-tree pre-check honor
# the `merge=union` gitattributes driver. =0 restores the EXACT legacy behavior
# (merge-tree --write-tree exit code is taken at face value).
#
# WHY: `git merge-tree --write-tree <main> <branch>` does NOT apply custom/builtin
# merge=* drivers from .gitattributes — even on git 2.54 (verified empirically on
# wa-jjea/wa-40xb: merge-tree reports CONFLICT on docs/data_dictionary.md, which
# carries `merge=union`, yet a REAL `git merge` of the same pair resolves it rc=0
# with zero conflict markers because union concatenates both sides). The result
# was a recurring pile of SPURIOUS needs-rebase escalations for branches whose
# only conflict is in a union-driver file (wa-40xb, wa-jjea, ...).
#
# ga-kjlhk: the fallback below (rig_path_is_union_resolvable) originally only
# recognized the literal `union` driver name, so any RIG-SPECIFIC custom driver
# (e.g. WA's `merge=deploydeps`, scripts/merge_deploy_deps.py) fell through as a
# false "genuine conflict" too — same bug, narrower fix scope than the flag name
# suggests. Despite the name, GATE_UNION_AWARE_PRECHECK now covers any path with
# a driver actually registered via `git config merge.<name>.driver`, not just
# the builtin union.
GATE_UNION_AWARE_PRECHECK="${GATE_UNION_AWARE_PRECHECK:-1}"

# rig_conflict_paths <main_ref> <branch_ref> — echo the NUL-free newline list of
# paths merge-tree flags as conflicting (empty on clean / error). Used only to
# decide union-coverage; the authoritative verdict still comes from exit codes.
rig_conflict_paths() {
  local main_ref="$1" branch_ref="$2"
  # `merge-tree --write-tree --name-only` stdout has THREE sections (git 2.54):
  #   line 1            : the new tree OID
  #   lines 2..K        : "Conflicted file info" — one conflicting path per line
  #   (blank line)      : section separator
  #   lines K+2..EOF    : "Informational messages" — "Auto-merging…", "CONFLICT…"
  # We want ONLY the conflicted-path section: drop line 1, then stop at the FIRST
  # blank line (sed `/^$/q` quits before printing it), which discards the trailing
  # informational tail (otherwise "Auto-merging X"/"CONFLICT … X" would be mistaken
  # for paths and break union-coverage detection). `|| true` is REQUIRED: merge-tree
  # returns rc=1 on conflict and pipefail would trip set -e on the assignment.
  git_rig merge-tree --write-tree --name-only "$main_ref" "$branch_ref" 2>/dev/null \
    | tail -n +2 | sed '/^$/q' | sed '/^$/d' || true
}

# rig_path_is_union_resolvable <merge_ref> <path> — return 0 (true) iff <path> is
# governed by a merge driver that resolves WITHOUT producing conflict markers:
# the builtin `union`, OR any custom driver registered via
# `git config merge.<name>.driver` (ga-kjlhk — a rig's own driver, e.g. WA's
# `merge=deploydeps`, is exactly as resolvable as `union`; hardcoding just the
# one name meant every OTHER custom driver fell through as a false "genuine
# conflict"). check-attr is evaluated against the merge context ref (the
# branch being merged) so .gitattributes as the author sees it is
# authoritative. Any unset/unspecified driver, or a name with no driver
# actually registered, → return 1 (NOT resolvable; fail-safe — caller
# escalates as a real conflict rather than risk a false clean).
rig_path_is_union_resolvable() {
  local merge_ref="$1" path="$2" drv=""
  # `git check-attr` on a tree-ish: use --source (git ≥2.40) to read attributes
  # from <merge_ref> rather than the working tree. Fall back to plain check-attr
  # (working-tree .gitattributes) if --source is unsupported. Conservative on any
  # failure: empty/err driver → not resolvable → caller escalates as a real conflict.
  drv=$(git_rig check-attr --source "$merge_ref" merge -- "$path" 2>/dev/null | sed 's/.*: merge: //' )
  if [ -z "$drv" ] || [ "$drv" = "merge: unspecified" ]; then
    drv=$(git_rig check-attr merge -- "$path" 2>/dev/null | sed 's/.*: merge: //')
  fi
  case "$drv" in
    ""|unspecified|unset|set) return 1 ;;
    union) return 0 ;;
    *) git_rig config --get "merge.$drv.driver" >/dev/null 2>&1 ;;
  esac
}

# rig_real_merge_is_clean <main_ref> <branch_ref> — perform a REAL throwaway
# test-merge in a detached temp worktree to confirm the merge actually resolves
# clean (union drivers applied). Return 0 (clean) iff `git merge --no-commit`
# succeeds with NO unmerged index entries. Any error/uncertainty → return 1
# (treat as NOT-clean → caller escalates; fail-safe, never green-lights a real
# conflict). The worktree + a trap guarantee cleanup on every path.
rig_real_merge_is_clean() {
  local main_ref="$1" branch_ref="$2"
  local wt rc=1
  wt="$(mktemp -d "${TMPDIR:-/tmp}/gc-gate-unioncheck-XXXXXX" 2>/dev/null)" || return 1
  # Resolve the temp worktree fully so cleanup in the trap is unambiguous.
  # shellcheck disable=SC2064
  trap "git_rig worktree remove --force '$wt' >/dev/null 2>&1 || true; rm -rf '$wt' >/dev/null 2>&1 || true" RETURN
  # Create a detached worktree at main; do the merge there. --no-commit leaves the
  # index/worktree merged so we can inspect ls-files -u, then we abort.
  if git_rig worktree add --detach "$wt" "$main_ref" >/dev/null 2>&1; then
    # ga-euopg: no identity needed — --no-commit never creates a commit, and
    # this merge is always aborted below. The prior `git config` calls here
    # served no purpose except writing "Gate Dispatcher" into the SHARED repo
    # config (no --worktree flag), repo-wide, on every union-check probe.
    if git -C "$wt" merge --no-commit --no-ff "$branch_ref" >/dev/null 2>&1; then
      # Merge stopped-before-commit cleanly. Double-check no unmerged entries.
      if [ -z "$(git -C "$wt" ls-files -u 2>/dev/null)" ]; then
        rc=0
      fi
    fi
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
  fi
  return "$rc"
}

# ── ga-ljbx: git-2.54 conflict detection ──────────────────────────────────────
# rig_merge_has_conflict <main_ref> <branch_ref> — echo "1" if merging
# <branch_ref> into <main_ref> conflicts, "0" if clean, "err" if undeterminable.
#
# The legacy 3-arg form `git merge-tree <base> <ours> <theirs>` + grep '^<<<<<<<'
# is BROKEN on git 2.54: the conflict markers in that output are diff-prefixed
# (" +<<<<<<<"), so the anchored grep never matches and a real conflict reads as
# clean (verified empirically on git 2.54.0). The modern
# `git merge-tree --write-tree <main> <branch>` is authoritative: exit 0 = clean,
# exit 1 = conflict, exit >1 = error (e.g. unrelated histories / bad ref).
#
# ga-78n2z: merge-tree --write-tree does NOT apply merge=union drivers, so a
# branch whose ONLY conflict is in a union-driver file (e.g. docs/data_dictionary.md)
# reads as a conflict here while a REAL merge resolves it cleanly. When the flag is
# ON and EVERY conflicting path is union-resolvable, we run a real test-merge in a
# throwaway worktree; if that confirms clean we report "0" (clean). If ANY path is
# not union-resolvable, or the test-merge still conflicts, or anything is uncertain,
# we fall through to the legacy "1" (escalate) — never auto-greenlight a real conflict.
rig_merge_has_conflict() {
  local main_ref="$1" branch_ref="$2"
  git_rig merge-tree --write-tree "$main_ref" "$branch_ref" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "0" ]; then
    echo "0"
    return 0
  elif [ "$rc" != "1" ]; then
    echo "err"
    return 0
  fi

  # rc == 1: merge-tree reports a conflict.
  if [ "$GATE_UNION_AWARE_PRECHECK" != "1" ]; then
    echo "1"
    return 0
  fi

  # Union-aware path: is EVERY conflicting file a union-driver file?
  local paths p all_union=1 any=0
  paths="$(rig_conflict_paths "$main_ref" "$branch_ref")"
  if [ -z "$paths" ]; then
    # Conservative: rc=1 but we could not enumerate the conflicting paths →
    # cannot prove union-only → treat as a genuine conflict (legacy behavior).
    echo "1"
    return 0
  fi
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    any=1
    if ! rig_path_is_union_resolvable "$branch_ref" "$p"; then
      all_union=0
      break
    fi
  done <<EOF
$paths
EOF

  if [ "$any" = "1" ] && [ "$all_union" = "1" ]; then
    # All conflicting paths are union-driver files. Confirm with a REAL merge.
    if rig_real_merge_is_clean "$main_ref" "$branch_ref"; then
      log "  ga-78n2z: union-only merge-tree conflict in [$(printf '%s' "$paths" | tr '\n' ' ')] confirmed CLEAN by real test-merge — treating pre-check as clean." 2>/dev/null || true
      echo "0"
      return 0
    fi
    # Union-only by attribute but the real merge STILL conflicts → genuine.
    log "  ga-78n2z: union-only merge-tree conflict but real test-merge ALSO conflicts — genuine conflict, escalating." 2>/dev/null || true
  fi

  # Default / fail-safe: genuine conflict (a non-union path, or real merge unclean).
  echo "1"
  return 0
}
# SELFTEST-EXTRACT gate-mergedriver-precheck: END

# SELFTEST-EXTRACT gate-resolve-rig-context-fn: BEGIN
# gate_resolve_rig_context — given $RIG and $BEAD_ID, resolve RIG_PATH (+
# canonicalize RIG), BEAD_CITY, IS_CONTAINER_RIG, GIT_DIR_PATH, DEFAULT_BRANCH,
# and refresh RIG_LIST_JSON. Self-contained (fetches its own rig list) so it is
# callable identically from Step 4 (claim-time, same invocation) and Phase C (a
# LATER invocation finalizing a run Step 4 claimed earlier — ga-eqjo). Returns 1
# (never exits — the caller decides what an unresolvable rig means for it) on
# failure, matching Step 4's historical fail-safe reasoning.
gate_resolve_rig_context() {
RIG_PATH=""
# ga-eqjo (code-review fix): the rig registry is invariant for the lifetime
# of one sweep (it only changes via a rare, administrative `gc rig add/
# remove`, never mid-sweep), but this function is called once per Phase C
# loop iteration — on N queued gate-runs finalized in one sweep, that was N
# redundant `gc` subprocess spawns fetching byte-identical data, adding
# avoidable process + Dolt load during the same sweep that is already
# Dolt-query-heavy. Memoize per-process: fetch once, reuse for every
# subsequent call (Phase C's whole loop, and Step 4's later claim-time call
# in the same sweep, if any).
# Only CACHE a fetch that actually returned rig data (a non-empty .rigs
# array) — a transient `gc` hiccup must keep retrying on every call, exactly
# like the original uncached code did, rather than poisoning every
# subsequent Phase C iteration this sweep with an empty registry from one
# blip.
if [ -z "${_GATE_RIG_LIST_CACHE:-}" ]; then
  # ga-07509: on failure _grlc_fetch stays "" (never the look-alike-valid
  # '{}' the old fallback produced) — _grlc_count's own `|| echo "0"` and the
  # `-gt 0` gate below already treat that the same as "no rigs", so the
  # existing retry-on-failure design (this comment block, above) is
  # unchanged; only failure DETECTION moves onto the authoritative signal.
  _grlc_fetch=$(gc_json_or_unknown gc --city "$GC_CITY" rig list --json) || true
  _grlc_count=$(printf '%s' "$_grlc_fetch" | jq '.rigs | length' 2>/dev/null || echo "0")
  case "$_grlc_count" in ''|*[!0-9]*) _grlc_count=0 ;; esac
  if [ "$_grlc_count" -gt 0 ]; then
    _GATE_RIG_LIST_CACHE="$_grlc_fetch"
  else
    RIG_LIST_JSON="$_grlc_fetch"
  fi
fi
RIG_LIST_JSON="${_GATE_RIG_LIST_CACHE:-$RIG_LIST_JSON}"
if [ -n "$RIG" ]; then
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
fi

# ga-67hae: COMPOUND rig fallback — /gate-done writes rig=mila-wa or rig=batista-ps
# (crew-qualified). No rig has that compound name → bead-id prefix is authoritative
# (wa-ucrq → wa → whatsapp_automation; ps-s27l → ps → property_scrapers).
if { [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; } && [ -n "$BEAD_ID" ]; then
  _bid_prefix="${BEAD_ID%%-*}"
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$_bid_prefix" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
  [ -n "$RIG_PATH" ] && log "  rig='$RIG' unresolved; derived from bead-id prefix '$_bid_prefix' -> $RIG_PATH"
fi
# Trailing-segment fallback: mila-wa → wa
if { [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; } && [ -n "$RIG" ] && printf '%s' "$RIG" | grep -q '-'; then
  _rig_tail="${RIG##*-}"
  RIG_PATH=$(echo "$RIG_LIST_JSON" \
    | jq -r --arg r "$_rig_tail" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
  [ -n "$RIG_PATH" ] && log "  rig='$RIG' unresolved; derived from trailing segment '$_rig_tail' -> $RIG_PATH"
fi

if [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; then
  err "Cannot resolve rig path for rig='$RIG' (bead=$BEAD_ID)."
  return 1
fi

# ga-67hae: normalize $RIG to the canonical rig name (compound values break
# downstream select(.name == $RIG) lookups like DEFAULT_BRANCH derivation).
_RIG_CANON=$(echo "$RIG_LIST_JSON" | jq -r --arg p "$RIG_PATH" '.rigs[] | select(.path == $p) | .name' 2>/dev/null | head -1 || echo "")
if [ -n "$_RIG_CANON" ] && [ "$_RIG_CANON" != "$RIG" ]; then
  log "  Normalized rig '$RIG' -> canonical '$_RIG_CANON' for downstream lookups."
  RIG="$_RIG_CANON"
fi

# wa-re77: source-bead (BEAD_ID) lives in the RIG's own Dolt DB, not HQ.
# Use BEAD_CITY for all bd ops on $BEAD_ID; keep GC_CITY for marker/gate-run/verdict ops.
#
# ── ga-qw7y6: resolve the store that ACTUALLY contains the source bead ─────────
# BEAD_CITY="${RIG_PATH:-$GC_CITY}" alone is WRONG when an HQ-resident `ga-` bead
# is built on a RIG branch (e.g. an HQ painel story built on whatsapp_automation's
# crew branch — see painel-lives-in-wa-rig). There the marker carries
# rig=whatsapp_automation, so RIG_PATH resolves to the rig store, but the source
# bead lives in the HQ city store. The PASS-merge close (`bd -C "$BEAD_CITY"
# close`) and the ga-esbg post-merge verification then target the rig store,
# can't find the HQ bead, and silently no-op — the source bead stays open, the
# verification reports "absent" (false OK), and Pilot phantom-re-dispatches the
# already-merged work (ga-8tv0s re-dispatched 3×: a direct slot/cycle leak).
# Conversely, wa-re77 rig-native beads DO live in the rig store. The owning store
# is therefore NOT derivable from RIG_PATH alone — probe which store resolves it.
#
# resolve_bead_city <bead-id> — echo the store dir whose Dolt DB owns <bead-id>.
# Probes RIG_PATH first (preserve wa-re77 rig-native behavior), then GC_CITY (HQ).
# A store "owns" the bead iff `bd -C <store> show <bead> --json` yields a record
# with a non-empty .status; a not-found probe returns {"error":...} (no .status →
# empty → skip). Falls back to a bead-id prefix heuristic (ga-* → HQ) only when
# NEITHER store resolves (e.g. transient Dolt hiccup), so the close still targets
# the most-likely-correct store rather than blindly trusting RIG_PATH.

BEAD_CITY="$(resolve_bead_city "$BEAD_ID")"
if [ "$BEAD_CITY" != "${RIG_PATH:-$GC_CITY}" ]; then
  log "  ga-qw7y6: source bead $BEAD_ID resolves to store $BEAD_CITY (NOT rig store ${RIG_PATH:-$GC_CITY}) — cross-store close corrected."
fi

# Determine the canonical git repo location.
# Container rigs (property_scrapers, lexbh) have a bare .repo.git.
# Self-repo rigs (gastown, whatsapp_automation, marketing) have .git in root.
if [ -d "$RIG_PATH/.repo.git" ]; then
  GIT_DIR_PATH="$RIG_PATH/.repo.git"
  IS_CONTAINER_RIG=1
else
  GIT_DIR_PATH="$RIG_PATH"
  IS_CONTAINER_RIG=0
fi

# git_rig — wrapper that calls git with the correct rig-specific flags.
# Usage: git_rig <args...>

log "  rig_path=$RIG_PATH  git_dir=$GIT_DIR_PATH  container_rig=$IS_CONTAINER_RIG"

# Determine default branch (main unless overridden)
DEFAULT_BRANCH=$(echo "$RIG_LIST_JSON" \
  | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .default_branch // "main"' 2>/dev/null | head -1 || echo "main")
  return 0
}
# SELFTEST-EXTRACT gate-resolve-rig-context-fn: END
# gate_collect_verdicts — snapshot VERDICT_BEAD_IDS ONCE (no polling/sleep) and
# set VERDICTS_RECEIVED, ANY_FAIL, FAIL_REASONS. Extracted verbatim from the
# historical Step 8 poll loop's per-iteration body (the closed-bead branch
# only — see below) so a single check replaces what used to be a
# while-true-sleep-30 loop. Callable from the same-sweep fast path AND from
# Phase C (a later sweep re-checking a run claimed earlier — ga-eqjo).
#
# ga-eqjo DELIBERATE SCOPE REDUCTION: the historical loop ALSO re-convened a
# reviewer whose session was confirmed dead across several consecutive polls
# (ga-4u16h/ga-h9o17/ga-q8tmn/ga-mepb0 — session-list liveness + peek +
# last_active staleness, debounced by SLOT_DEAD_STREAK so a single flaky
# read could never kill a live reviewer). That debounce state lived in
# process-local bash arrays that reset every poll WITHIN one long-lived
# invocation — it has no meaning once a single sweep only checks a run ONCE
# and exits (the whole point of ga-eqjo). Porting it would mean persisting
# the streak counters as bead metadata and re-deriving them every sweep,
# which is real complexity for what was always a LATENCY optimization, not a
# correctness requirement — a dead reviewer's verdict beads just never close,
# so the outer per-run timeout (checked by every caller of this function)
# still catches it, same as always, just up to VERDICT_TIMEOUT_MINUTES later
# instead of the faster in-poll reconvene (~RECONVENE_GRACE_SECS + a few dead
# polls, often well under 5 min). gate-recovery-watchdog's independent,
# wall-clock-based hang/stranded-run detectors (already cross-invocation-safe
# by design) are the other backstop for this same failure mode. Nothing hangs
# forever; a rare failure mode is just detected slower. See ga-eqjo PR.
# SELFTEST-EXTRACT gate-collect-verdicts-fn: BEGIN
gate_collect_verdicts() {
  VERDICTS_RECEIVED=0
  ANY_FAIL=0
  FAIL_REASONS=""
  for j in "${!VERDICT_BEAD_IDS[@]}"; do
    VB="${VERDICT_BEAD_IDS[$j]}"
    # ga-art5: `|| echo "[]"` used to mask a failed `bd show` as an empty
    # result, which `.status // "open"` then reads as a genuinely-open
    # verdict — the exact error/empty conflation this bead exists to close.
    # Capture the query's own rc explicitly instead: on failure we don't know
    # this bead's status, so skip it this sweep rather than guess (it stays
    # in VERDICT_BEAD_IDS and is re-read next sweep; the outer VERDICT_TIMEOUT_MINUTES
    # backstop still applies either way).
    # ga-h199q: NOT routed through the read-cache shim —
    # gate-verdict-drained-reviewer-rescue.selftest.sh mocks `bd` in-shell and
    # sources this file lib-only to test the ga-7lz1 rescue path; the shim's
    # child-process bash invocation can't see that mock (verified: 6 assertion
    # failures, including the mutation test going vacuous). Left live.
    if ! VB_JSON=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null); then
      log "  Verdict bead $VB status unreadable this sweep (bd show failed — transient Dolt hiccup?) — skipping, will retry next sweep (root-class:error-vs-empty, ga-art5)."
      continue
    fi
    VB_STATUS=$(printf '%s' "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
    VB_LABELS=$(printf '%s' "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || true)

    # ga-7lz1: a reviewer that WRITES its verdict (label + comment) but DRAINS
    # before the final `bd close` leaves this bead OPEN forever — the
    # closed-only check right below then re-reads a genuinely complete review
    # as "still pending" every sweep, so the run sits until the full
    # VERDICT_TIMEOUT_MINUTES elapses and the dead-reviewer requeue path
    # (Phase C, below) discards the real verdict for a from-scratch
    # re-review. Rescue it: an OPEN bead already carrying an explicit
    # verdict:PASS/verdict:FAIL label is only ambiguous while its reviewer
    # might still be mid-write (the label can land seconds before the close),
    # so gate on CONFIRMED death, never on the label alone — fail-safe: any
    # inconclusive or live peek leaves the bead pending, same as before this
    # fix. `gc session list`/session_is_dead() is NOT the right death signal
    # here: a drained (normally-ended) session STAYS listed with closed!=true
    # (ga-h9o17/gt-bewtm), so it would read ALIVE. `gc session peek` is the
    # proven discriminator (same check the gt-bewtm headroom janitor uses
    # above in this file): a drained session answers "session not found" on
    # stderr; a genuinely alive-but-slow one answers with real scrollback.
    if [ "$VB_STATUS" != "closed" ] && echo "$VB_LABELS" | grep -qE "verdict:(PASS|FAIL)"; then
      VB_ASSIGNEE=$(echo "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .assignee // ""')
      if [ -n "$VB_ASSIGNEE" ]; then
        VB_PEEK_ERR=$(gc --city "$GC_CITY" session peek "$VB_ASSIGNEE" --lines 1 2>&1 >/dev/null || true)
        if [ "$(session_peek_reports_dead "$VB_PEEK_ERR")" = "1" ]; then
          log "  Verdict bead $VB has a verdict label but is still OPEN and its reviewer ($VB_ASSIGNEE) is confirmed drained — rescuing as delivered and closing it (ga-7lz1)."
          bd -C "$GC_CITY" close "$VB" -r "auto-closed by dispatcher: verdict label delivered, reviewer session drained before its own close (ga-7lz1)" 2>/dev/null || true
          VB_STATUS="closed"
        fi
      fi
    fi

    if [ "$VB_STATUS" = "closed" ]; then
      VERDICTS_RECEIVED=$((VERDICTS_RECEIVED + 1))
      if echo "$VB_LABELS" | grep -q "verdict:PASS"; then
        : # explicit PASS — continue
      elif echo "$VB_LABELS" | grep -q "verdict:FAIL"; then
        ANY_FAIL=1
        # Collect the fail reason from the reviewer's verdict comment.
        # NOTE (ga-kf0v): the beads "bd comments --json" schema uses .text
        # (keys: author, created_at, id, issue_id, text) — there is NO .body
        # field. The old accessor read .[0].body, so jq always fell through to
        # the "No reason provided" default and EVERY genuine reviewer FAIL lost
        # its reason. Parse .text (with .body kept as a defensive fallback for
        # any future schema drift), preferring the comment that starts with
        # "VERDICT:" (the reviewer convention), else the first non-empty one.
        VB_COMMENTS_JSON=$(bd -C "$GC_CITY" comments "$VB" --json 2>/dev/null || echo "[]")
        FAIL_COMMENT=$(printf '%s' "$VB_COMMENTS_JSON" | jq -r '
            [ .[]? | (.text // .body // "") ]
            | ( map(select(test("^\\s*VERDICT:"; "i"))) | last )
              // ( map(select(. != "")) | first )
              // ""
          ' 2>/dev/null || echo "")
        # FORENSICS (ga-kf0v #3): always log the raw comments + verdict labels
        # for a FAIL so any future schema/field drift is visible in the
        # dispatcher log without re-deriving from beads.
        log "  FAIL forensics reviewer $((j+1)) bead=$VB labels=[$VB_LABELS] raw_comments=$(printf '%s' "$VB_COMMENTS_JSON" | jq -c . 2>/dev/null | cut -c1-2000)"
        if [ -z "$FAIL_COMMENT" ]; then
          # Reviewer closed verdict:FAIL but left no parseable reason. Now rare
          # (the .text fix above resolves the common case). Fail-safe: PASS is
          # the only acceptable verdict, so an empty-reason FAIL still blocks
          # the merge — but mark it INCONCLUSIVE and warn loudly so it is
          # distinguishable from a substantive FAIL. (Full per-reviewer session
          # re-run retry per ga-kf0v #2 is deliberately deferred: re-dispatching
          # a reviewer mid-collection is higher-risk than this lane:small fix
          # warrants; making the empty case visible addresses the intent without
          # destabilising the gate's verdict-collection loop.)
          warn "Reviewer $((j+1)) (bead $VB) closed verdict:FAIL with no parseable reason — counting as INCONCLUSIVE FAIL (fail-safe)."
          FAIL_COMMENT="INCONCLUSIVE — verdict:FAIL with empty/unparseable reason (raw bead $VB; see forensics log above)"
        fi
        FAIL_REASONS="${FAIL_REASONS}Reviewer $((j+1)) FAIL: $FAIL_COMMENT\n"
      else
        # ga-86l90a8 (thies): the reviewer writes `label add verdict:PASS` THEN
        # `comment "VERDICT: PASS"` THEN closes the bead (Step "If PASS" ~L2284).
        # If the label-add raced / didn't commit before the close but the PASS
        # COMMENT landed, the label-only check above loses a GENUINE pass and
        # false-FAILs clean code ("verdict bead closed without explicit PASS").
        # Rescue it the same way FAIL reasons are read: parse the verdict COMMENT
        # (.text) and accept ONLY an unambiguous, anchored "VERDICT: PASS" —
        # anything else still FAILs, so the fail-safe (PASS is the ONLY acceptable
        # verdict) is fully preserved. A jq glitch leaves PASS_COMMENT empty →
        # falls through to the existing FAIL path (no regression).
        VB_COMMENTS_JSON=$(bd -C "$GC_CITY" comments "$VB" --json 2>/dev/null || echo "[]")
        PASS_COMMENT=$(printf '%s' "$VB_COMMENTS_JSON" | jq -r '
            [ .[]? | (.text // .body // "") ]
            | map(select(test("^\\s*VERDICT:\\s*PASS\\b"; "i")))
            | last // ""
          ' 2>/dev/null || echo "")
        if [ -n "$PASS_COMMENT" ]; then
          VERDICTS_RECEIVED=$VERDICTS_RECEIVED  # already counted at the closed branch
          log "  Reviewer $((j+1)) (bead $VB) closed WITHOUT a verdict:PASS label but its verdict COMMENT is an explicit PASS — rescuing as PASS (ga-86l90a8 label-race). comment=$(printf '%s' "$PASS_COMMENT" | tr '\n' ' ' | cut -c1-200)"
          : # treat as PASS — do NOT set ANY_FAIL
        else
          # Any other label (TIMEOUT, ABORTED, or missing verdict label) → FAIL.
          # PASS is the ONLY acceptable verdict; anything else blocks the merge.
          ANY_FAIL=1
          VERDICT_LABEL=$(echo "$VB_LABELS" | tr ' ' '\n' | grep "^verdict:" | head -1 || echo "no-verdict-label")
          FAIL_REASONS="${FAIL_REASONS}Reviewer $((j+1)) ${VERDICT_LABEL}: verdict bead closed without explicit PASS (no verdict:PASS label and no explicit PASS comment).\n"
        fi
      fi
    fi
    # ga-eqjo: NOT closed (still pending) -> not counted this check; see the
    # scope-reduction note in this function's header comment above.
  done
}
# SELFTEST-EXTRACT gate-collect-verdicts-fn: END
# extract <field-name> — parse a "<field-name>: value" line out of $DESC.
# Hoisted (ga-eqjo) so Phase C can reuse it on a run bead's description the
# same way Step 2 uses it on a marker's. ga-7zjs1: trailing `|| true` keeps a
# missing field from aborting the dispatcher under `set -euo pipefail` — an
# absent field makes grep exit 1 (no match) and pipefail would propagate it;
# a no-match now yields an empty string instead, letting callers fall back.
extract() { echo "$DESC" | grep -E "^$1:" | head -1 | sed "s/^$1: *//" || true; }

# ── ga-zl277: guaranteed reviewer-session cleanup on EVERY exit path ───────────
# Reviewer sessions used to be closed ONLY at Step 9 (the success/timeout path).
# A mid-loop spawn-abort or any signal/timeout kill of the dispatcher left
# already-spawned reviewer sessions ASLEEP and never closed. They pile up
# against the gate-reviewer template's max_active_sessions budget until the
# gate can no longer spawn reviewers (vicious cycle). This EXIT/signal trap
# closes whatever is in SESSION_IDS exactly once, from one place, so every
# abort path frees its cap slots. (SIGKILL/OOM cannot be trapped — the Step
# 0a-2 startup janitor backstops those.) Hoisted (ga-eqjo) — see extract()
# above for why: a Phase-C-only sweep never reaches Step 7's original
# position, so this must be defined before Phase C, not at Step 7.
_gate_cleanup_done=0
cleanup_reviewer_sessions() {
  [ "$_gate_cleanup_done" = "1" ] && return 0
  _gate_cleanup_done=1
  # ga-eqjo: a run admitted+spawned THIS sweep whose verdicts are not all in yet
  # is not finished — its reviewers must keep working (Phase B, unsupervised).
  # The non-blocking Step 8 tail sets this flag right before exiting so THIS
  # same EXIT trap (which used to unconditionally close every reviewer session)
  # only releases the single-instance lock and leaves the sessions alive for a
  # future sweep's Phase C to finalize. Finalizing runs (via gate_finalize_run,
  # from either the same-sweep fast path or Phase C) never set this flag, so
  # they still close sessions exactly as before.
  if [ "${GATE_RUN_LEAVE_SESSIONS_ALIVE:-0}" = "1" ]; then
    log "Run $GATE_RUN_ID left in flight — reviewer sessions stay alive for a future sweep (ga-eqjo): ${SESSION_IDS[*]:-none}"
    if [ "${GATE_SWEEP_HAS_MORE_WORK:-0}" != "1" ]; then _release_gate_lock 2>/dev/null || true; fi
    return 0
  fi
  if [ "${#SESSION_IDS[@]}" -gt 0 ]; then
    for _SID in "${SESSION_IDS[@]}"; do
      [ -z "$_SID" ] && continue
      gc --city "$GC_CITY" session close "$_SID" 2>/dev/null || true
    done
    log "Reviewer sessions closed (cleanup): ${SESSION_IDS[*]}"
  fi
  # This EXIT trap REPLACES the early '_release_gate_lock' trap installed at sweep
  # start, so release the single-instance lock from here too — otherwise the lock
  # would leak until GATE_LOCK_MAX_AGE on every run that reaches Step 7. Token-
  # guarded + idempotent -> a no-op when GATE_LOCK_ENABLED=0 or we don't own it.
  # ga-eqjo: GATE_SWEEP_HAS_MORE_WORK (set by Phase C around its own loop, see
  # below) skips the release here — Phase C may have MORE runs queued to
  # finalize, or Step 0b/Step 1 may still need to claim a new marker, THIS
  # SAME sweep, all under the SAME lock acquisition. Releasing early here would
  # open a window for a second concurrent sweep to start before this one's
  # remaining work is done. The lock still gets released exactly once, at the
  # sweep's true end, via whichever EXIT trap is active at that point (this
  # function, if Step 7 ran; the plain _release_gate_lock trap from sweep
  # start, if it never did) — both are idempotent and token-guarded.
  if [ "${GATE_SWEEP_HAS_MORE_WORK:-0}" != "1" ]; then _release_gate_lock 2>/dev/null || true; fi
}
# ── Single-instance guard: collapse overlapping launchd sweeps to one ─────────
# Acquire BEFORE the bd-heavy preamble (ambient-CPU snapshot, Step 0a TTL
# recovery, Step 0a-2 orphan-reviewer reap, headroom probe, and the marker
# scans) so a second concurrent sweep yields HERE instead of doubling the Dolt
# load right when reviewers are booting. The EXIT trap releases only OUR OWN lock
# (token match); it covers every early-exit path in the preamble window. At Step 7
# this trap is replaced by `trap cleanup_reviewer_sessions EXIT` — that helper is
# extended to ALSO call _release_gate_lock, so a full run frees the lock the
# instant it completes. If neither fires (SIGKILL/OOM), the stale-heartbeat
# recovery above reclaims it — the anti-wedge guarantee.
if [ "$GATE_LOCK_ENABLED" = "1" ]; then
  # ga-309v3: a continuation round already holds the lock from round 0 (it is
  # deliberately not released across the re-exec), so re-acquiring would deadlock
  # against ourselves. BUT ownership must be proven from the LOCK ITSELF, never
  # from the inherited env alone: `export GATE_ADMIT_ROUND/GATE_LOCK_TOKEN` reach
  # EVERY descendant, including the gate-reviewer sessions this round spawns. A
  # reviewer agent that later runs this dispatcher by hand (routine when
  # debugging a gate bug) would otherwise inherit "I am round N", skip the
  # single-instance guard entirely, run a concurrent sweep, stomp the live
  # holder's heartbeat and then rm -rf the lock out from under it — the
  # double-sweep/concurrent-merge class ga-7s0or and ga-T1 exist to prevent.
  #
  # `${GATE_LOCK_TOKEN%%:*}" = "$$"` is the decisive half: exec PRESERVES $$, so a
  # genuine continuation always matches, while any descendant process has a
  # different pid and fails closed into the normal _acquire_gate_lock path.
  _gate_hb_tok=$(head -n1 "$GATE_LOCK_HB" 2>/dev/null || true)
  if [ "$GATE_ADMIT_ROUND" -gt 0 ] 2>/dev/null \
     && [ -d "$GATE_LOCK_DIR" ] \
     && [ "$_gate_hb_tok" = "$GATE_LOCK_TOKEN" ] \
     && [ "${GATE_LOCK_TOKEN%%:*}" = "$$" ]; then
    # Refresh the heartbeat: a burst outlives a single round, and a heartbeat
    # left to age past GATE_LOCK_MAX_AGE would let a concurrent fire reclaim the
    # lock mid-burst.
    _gate_lock_write_hb
    trap '_release_gate_lock' EXIT
    log "Multi-admit round ${GATE_ADMIT_ROUND}/${GATE_MAX_ADMITS_PER_SWEEP} — continuing under the round-0 lock, ownership verified (ga-309v3)."
  elif _acquire_gate_lock; then
    trap '_release_gate_lock' EXIT
  else
    # ga-309v3: yielding here does NOT prove we are lock-free. A continuation
    # round that (rarely) fails the ownership guard above — lock dir vanished, a
    # transient `head` failure, or a peer reclaim after an unusually long round —
    # still HELD the lock, and _acquire_gate_lock's mkdir then fails against our
    # OWN dir: _gate_lock_holder_dead reads our own live pid, reports "alive",
    # and we land here and exit 0. Without a release trap the lock survives our
    # death, and while the dead-pid fast path normally reclaims it within one
    # launchd cadence, a RECYCLED pid makes `kill -0` succeed and wedges the gate
    # for the full GATE_LOCK_MAX_AGE (30min) with no sweep running at all.
    #
    # Safe only because GATE_LOCK_TOKEN is self-validating (pid half == $$, see
    # its definition): _release_gate_lock removes the dir ONLY on a token match,
    # so a genuine owner frees its own lock while a yielding peer — whose token
    # is freshly minted and cannot match the live holder's heartbeat — is a no-op.
    # Installing this trap BEFORE the :1274 self-validation would have let a
    # descendant with an inherited token delete the live holder's lock.
    trap '_release_gate_lock' EXIT
    _gate_holder_pid=$(head -n1 "$GATE_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
    log "Live gate sweep already running (pid=${_gate_holder_pid:-?}) — yielding (single-instance guard)."
    exit 0
  fi
fi

echo ""
log "=== Dispatcher sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── ga-bgvc0: ambient Dolt-CPU snapshot (BEFORE the janitors) ─────────────────
# The Step 0b-1 headroom gate must judge the data plane by its AMBIENT load, not
# the spike this dispatcher's own Step 0a/0a-2/0a-3 janitors add. Sample the live
# dolt-server %cpu HERE, before any janitor runs. This is a pure `ps` read (no
# Dolt query, no added load) resolved via pgrep; empty on miss → the headroom
# gate falls back to its legacy post-janitor reading (no regression). Honors the
# GATE_DOLT_CPU_OVERRIDE selftest seam through gate_dolt_cpu.
GATE_AMBIENT_DOLT_CPU=""
if [ "${GATE_HEADROOM_ENABLED:-1}" = "1" ]; then
  GATE_AMBIENT_DOLT_PID=$(pgrep -f 'dolt sql-server' 2>/dev/null | head -1 || true)
  GATE_AMBIENT_DOLT_CPU=$(gate_dolt_cpu "${GATE_AMBIENT_DOLT_PID:-}")
fi

# ── Phase C (ga-eqjo): finalize any in-flight gate-runs whose verdicts are
# complete or whose timeout has elapsed. This is what makes Step 8 (Phase A's
# tail) non-blocking: an EARLIER sweep's Phase A spawned reviewers and exited
# immediately; THIS sweep (or a later one) is what actually merges/fails once
# reviewers finish. Runs FIRST, before any new-marker admission (Step 0a
# onward), so freed reviewer-session slots are visible to THIS sweep's own
# headroom check (Step 0b-1) and the merge stays serial — this whole block
# runs under the SAME single-instance lock as the rest of the sweep.
#
# Context for each running gate-run is re-derived from its bead state (never
# from process-local variables — a DIFFERENT process may have claimed it):
# the run bead's description (source_bead/author/rig/branch/tier/
# required_reviewers/branch_sha/marker_id/started_at/verdict_timeout_minutes,
# all written at Step 6) via extract(), and its verdict beads via the
# gate-run:<id> label. gate_resolve_rig_context/gate_collect_verdicts/
# gate_finalize_run are the SAME functions the same-sweep fast path (Step 8)
# uses — no separate/duplicate logic to drift.
#
# DELIBERATE SCOPE REDUCTION: this sweep does NOT attempt mid-flight reviewer
# respawn/reconvene (ga-4u16h and friends — see gate_collect_verdicts' header
# comment). A dead reviewer is now caught by this run's own timeout (persisted
# verdict_timeout_minutes, checked below) or by gate-recovery-watchdog's
# independent hang/stranded-run detectors, both wall-clock-based and already
# safe across process boundaries — never by a debounced in-poll counter that
# only made sense inside one long-lived blocking process. See ga-eqjo PR.
if [ "${GATE_PHASE_C_ENABLED:-1}" = "1" ]; then
  # ga-h199q: routed through the read-cache shim (see live_sibling_run_for_branch's
  # header comment — identical query, same-sweep dedup across 4 call sites).
  PHASE_C_RUNNING_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json -l type:quality-gate-run -l gate-status:running 2>/dev/null || echo "[]")
  PHASE_C_COUNT=$(printf '%s' "$PHASE_C_RUNNING_JSON" | jq 'length' 2>/dev/null || echo "0")
  case "$PHASE_C_COUNT" in ''|*[!0-9]*) PHASE_C_COUNT=0 ;; esac
  if [ "$PHASE_C_COUNT" -gt 0 ]; then
    log "Phase C: sweeping $PHASE_C_COUNT in-flight gate-run(s) for completion/timeout (ga-eqjo)."
    # More than one run bead may need finalizing this sweep; keep the
    # single-instance lock held across the WHOLE loop (and into Step 0a
    # onward) rather than releasing it after the first — see
    # cleanup_reviewer_sessions' GATE_SWEEP_HAS_MORE_WORK handling above.
    GATE_SWEEP_HAS_MORE_WORK=1
    for PC_I in $(seq 0 $((PHASE_C_COUNT - 1))); do
      # ga-eqjo (code-review fix): refresh the single-instance lock's heartbeat
      # at the TOP of every Phase C iteration, mirroring what the old Step 8
      # poll loop did every 30s for the same reason (that loop's own comment:
      # "a 1846s real sweep has been observed > MAX_AGE (1800s)"). Each
      # iteration can do several bd/gc calls plus a full do_merge_ff (git
      # fetch/rebase/push, all with no per-call timeout) — on N queued runs
      # this sweep, that's easily enough wall-clock for a LIVE holder's
      # heartbeat to go stale and get reclaimed by a second concurrent sweep
      # (_acquire_gate_lock only backs off when the heartbeat is BOTH fresh
      # AND the PID confirmed alive — a live-but-slow holder fails the
      # freshness half and gets reclaimed anyway). No-op when the lock is
      # disabled or its dir is absent (token-guarded write, 2>/dev/null).
      if [ "$GATE_LOCK_ENABLED" = "1" ]; then _gate_lock_write_hb; fi
      PC_RUN=$(printf '%s' "$PHASE_C_RUNNING_JSON" | jq ".[$PC_I]")
      GATE_RUN_ID=$(printf '%s' "$PC_RUN" | jq -r '.id // empty')
      [ -z "$GATE_RUN_ID" ] && continue
      DESC=$(printf '%s' "$PC_RUN" | jq -r '.description // ""')

      # Fresh cleanup/leave-alive lifecycle for THIS run bead — a PRIOR
      # iteration of this same loop (or a fast-path run earlier this sweep)
      # may have already driven these to 1.
      _gate_cleanup_done=0
      GATE_RUN_LEAVE_SESSIONS_ALIVE=0

      BEAD_ID=$(extract "source_bead")
      AUTHOR=$(extract "author")
      RIG=$(extract "rig")
      BRANCH=$(extract "branch")
      if [ -z "$BRANCH" ] && [ -n "$BEAD_ID" ]; then
        # ga-eqjo (code-review fix): backward-compat fallback for gate-run
        # beads created by the PRE-ga-eqjo dispatcher, whose Step 6 template
        # never wrote a `branch:` description line (that field is new in
        # this diff). Without this, any run already in flight at the exact
        # moment this fix deploys can never be finalized — the required-
        # field guard below would skip it, forever, every sweep, leaking
        # its reviewer sessions and orphaning its marker.
        # The bead's TITLE format ("gate-run: $BRANCH ($BEAD_ID)", set at
        # Step 6) is UNCHANGED, so recover BRANCH from it: strip the fixed
        # prefix, then the trailing " ($BEAD_ID)" suffix using the
        # already-extracted bead id (an EXACT match against the known id,
        # not a generic parenthesis strip, so a branch name that itself
        # contains parentheses is never mis-parsed).
        #
        # ga-f1ngu note: before that fix, the guard's "quality-gate: ..."
        # claim-receipt bead could ALSO reach this loop (it was mislabeled
        # gate-status:running) and, since its title prefix is "quality-gate:
        # " not "gate-run: ", the strip below was a no-op and BRANCH ended up
        # as the garbled full title minus only the trailing "($BEAD_ID)" —
        # exactly the corrupted value this log line reported live (ga-jo3xl,
        # 2026-07-29). Now that the guard's claim-receipt is gate-status:
        # claimed, the PHASE_C_RUNNING_JSON query above never returns it, so
        # this fallback only ever sees genuine pre-ga-eqjo dispatcher beads
        # again, as originally intended.
        PC_TITLE=$(printf '%s' "$PC_RUN" | jq -r '.title // ""')
        if [ -n "$PC_TITLE" ]; then
          BRANCH="${PC_TITLE#gate-run: }"
          BRANCH="${BRANCH% (${BEAD_ID})}"
        fi
        if [ -n "$BRANCH" ]; then
          log "Phase C: gate-run $GATE_RUN_ID has no persisted branch: field (pre-ga-eqjo bead) — recovered '$BRANCH' from its title."
        fi
      fi
      TIER=$(extract "tier")
      REQUIRED_REVIEWERS=$(extract "required_reviewers")
      BRANCH_SHA=$(extract "branch_sha")
      MARKER_ID=$(extract "marker_id")
      PC_STARTED_AT=$(extract "started_at")
      PC_TIMEOUT_MIN=$(extract "verdict_timeout_minutes")
      case "$REQUIRED_REVIEWERS" in ''|*[!0-9]*) REQUIRED_REVIEWERS=1 ;; esac
      case "$PC_TIMEOUT_MIN" in ''|*[!0-9]*) PC_TIMEOUT_MIN="$VERDICT_TIMEOUT_MINUTES" ;; esac

      if [ -z "$BEAD_ID" ] || [ -z "$BRANCH" ] || [ -z "$RIG" ] || [ -z "$MARKER_ID" ]; then
        warn "Phase C: gate-run $GATE_RUN_ID missing a required field (source_bead/branch/rig/marker_id) in its description — skipping this sweep, will retry next sweep."
        continue
      fi

      if ! gate_resolve_rig_context; then
        warn "Phase C: gate-run $GATE_RUN_ID — could not resolve rig context for rig='$RIG'; skipping this sweep, will retry next sweep."
        continue
      fi

      # SELFTEST-EXTRACT phase-c-verdict-rehydrate: BEGIN
      # ga-* (2026-07-15): --all is LOAD-BEARING. `bd list` EXCLUDES closed beads by
      # default (bd list --help: "--all  Show all issues including closed (overrides
      # default filter)"). A DELIVERED verdict IS a CLOSED bead — the reviewer closes
      # the verdict bead with a verdict:PASS/verdict:FAIL label as its final act. The
      # ga-eqjo async split made Phase C RE-QUERY (rehydrate) the verdict beads from
      # scratch each sweep instead of holding the in-process Step-7 array; without --all
      # the query returns ZERO the instant any reviewer delivers, so Phase C mis-reads a
      # COMPLETED run as "died before Step 7" (the emptiness path below), strands it, and
      # NEVER finalizes → the whole gate stops merging (observed live: 5h / 0 merges,
      # wa-k971r/ga-dlzl closed verdict:PASS at 10:38 yet counted 0/1). --all restores
      # visibility of the pending (open) AND delivered (closed) verdict beads; the -l
      # label filters still scope it to this run's verdict beads only.
      # ga-h199q: NOT routed through the read-cache shim — two independent
      # selftests break: gate-phase-c-empty-verdict-unbound.selftest.sh and
      # gate-phase-c-rehydrate-includes-closed.selftest.sh both mock `bd` as an
      # in-shell function and source this file lib-only; the shim's
      # `bash bd-list-cached.sh` spawns a child process the mock can't reach
      # (verified: rc=1, "gate_collect_verdicts NOT reached — the delivered
      # verdict is invisible"). The rehydrate selftest's mutation test also
      # anchors on this EXACT `--all` query string to construct its mutant —
      # any text change here breaks that anchor match too. Left live.
      # root-class:error-vs-empty — a FAILED query must not read as "no verdict
      # beads exist". The old `|| echo "[]"` collapsed both into an empty array,
      # and the emptiness guard below then declared "likely died before Step 7".
      # MEASURED 2026-07-31 (ga-wisp-jm34iny): the SAME run logged 0/1 verdicts
      # at 23:19, "ZERO verdict beads" at 23:24, then 0/1 again at 23:29 — the
      # verdict bead (ga-45m6o) existed the whole time and the run finalized
      # correctly as FAILED. The bead never vanished; one sweep's query did.
      # That intermittent failure is what fed the "gate outage" narrative: the
      # WARN is the string three separate agents counted to size ga-jwnye at
      # 147/426 runs "dead", when the per-bead count for the same day was 13.
      # Mirrors the sibling `vb_status_action` unknown-branch (ga-art5), which
      # already skips-and-retries on an unreadable `bd show` instead of guessing.
      VB_SENTINEL="__VB_QUERY_FAILED__"
      VB_JSON=$(bd -C "$GC_CITY" list --json --all -l type:quality-gate-verdict -l "gate-run:$GATE_RUN_ID" 2>/dev/null || echo "$VB_SENTINEL")
      if [ "$VB_JSON" = "$VB_SENTINEL" ]; then
        log "  Phase C: verdict-bead query for gate-run $GATE_RUN_ID failed this sweep (transient Dolt hiccup?) — skipping, will retry next sweep (root-class:error-vs-empty). NOT treating as died-before-Step-7."
        continue
      fi
      VERDICT_BEAD_IDS=()
      while IFS= read -r PC_VBID; do
        [ -z "$PC_VBID" ] && continue
        VERDICT_BEAD_IDS+=("$PC_VBID")
      done < <(printf '%s' "$VB_JSON" | jq -r '
          sort_by([(.labels[]? | select(startswith("reviewer-index:")) | ltrimstr("reviewer-index:") | tonumber)] | (.[0] // 0))
          | .[].id' 2>/dev/null)

      # ga-eqjo (gate-fix-3): this emptiness guard MUST run before any
      # "${VERDICT_BEAD_IDS[@]}" expansion below. bash 3.2 (the only bash on
      # this host — verified no newer bash exists anywhere in PATH) throws
      # "unbound variable" under `set -euo pipefail` when "${ARR[@]}" expands
      # a declared-but-empty array, killing the whole dispatcher process. A
      # gate-run whose prior invocation died between Step 6 (run-bead
      # creation) and Step 7 (verdict-bead spawning) rehydrates here with
      # ZERO verdict beads — a real, reachable state (OOM/SIGKILL/launchd-
      # timeout mid-run) — so this check cannot be deferred until after a
      # loop that consumes the array.
      if [ "${#VERDICT_BEAD_IDS[@]}" -eq 0 ]; then
        warn "Phase C: gate-run $GATE_RUN_ID has ZERO verdict beads — likely died before Step 7 finished spawning. Leaving for gate-recovery-watchdog's hung-run backstop."
        continue
      fi

      SESSION_IDS=()
      for PC_VBID in "${VERDICT_BEAD_IDS[@]}"; do
        # ga-i5s5: `|| echo ""` used to mask a failed `bd show` (assignee
        # read) as a blank session id. A blank PC_SID matches no live
        # session below (root-class:error-vs-empty) -> the dead-reviewer
        # classifier (phase-c-dead-reviewer-classify-fn) reads "not present"
        # -> confirmed DEAD, so a transient Dolt hiccup on THIS read could
        # manufacture a false dead-reviewer verdict for a reviewer that is
        # actually still alive. Use the same __UNKNOWN__ sentinel
        # vb_status_action already establishes for this file's status reads
        # so the classifier can distinguish "confirmed absent" from
        # "couldn't check" instead of conflating them.
        if PC_SID_JSON=$(bd -C "$GC_CITY" show "$PC_VBID" --json 2>/dev/null); then
          PC_SID=$(printf '%s' "$PC_SID_JSON" | jq -r 'if type=="array" then .[0] else . end | .assignee // ""' 2>/dev/null || true)
        else
          PC_SID="__UNKNOWN__"
        fi
        SESSION_IDS+=("$PC_SID")
      done

      gate_collect_verdicts
      # SELFTEST-EXTRACT phase-c-verdict-rehydrate: END

      PC_START_EPOCH=$(_ts_to_epoch "$PC_STARTED_AT")
      case "$PC_START_EPOCH" in ''|*[!0-9]*) PC_START_EPOCH=$(date +%s) ;; esac
      PC_NOW_EPOCH=$(date +%s)
      PC_ELAPSED=$(( PC_NOW_EPOCH - PC_START_EPOCH ))
      PC_TIMEOUT_SECS=$(( PC_TIMEOUT_MIN * 60 ))
      GATE_START_EPOCH="$PC_START_EPOCH"
      QUOTA_REQUEUE=0
      REQUEUE_REASON="quota"

      if [ "$VERDICTS_RECEIVED" -eq "$REQUIRED_REVIEWERS" ]; then
        OVERALL_VERDICT="PASS"
        [ "$ANY_FAIL" = "1" ] && OVERALL_VERDICT="FAIL"
        log "Phase C: gate-run $GATE_RUN_ID (branch=$BRANCH) complete — $VERDICTS_RECEIVED/$REQUIRED_REVIEWERS verdicts, overall=$OVERALL_VERDICT (elapsed ${PC_ELAPSED}s). Finalizing."
        gate_finalize_run
      elif [ "$PC_ELAPSED" -gt "$PC_TIMEOUT_SECS" ]; then
        PC_QLIM=$(gate_quota_limited)
        if [ "$(gate_quota_stop_verdict "$PC_QLIM")" = "requeue" ]; then
          QUOTA_REQUEUE=1
          warn "Phase C: gate-run $GATE_RUN_ID timed out (${PC_ELAPSED}s) but Claude 5h quota is LIMITED — quota-stop re-queue (ga-x3nmz)."
          gate_finalize_run
          continue
        fi
        # ga-eqjo (code-review fix): before treating a timeout as a genuine
        # code FAIL, check whether every STILL-PENDING reviewer's session is
        # simply DEAD (gone — not slow, not wedged, confirmed absent or
        # closed in `gc session list`). A dead session can never produce a
        # verdict, so waiting out the full timeout only delays the
        # inevitable — but it is an INFRA failure (the ga-4u16h/ga-h9o17
        # incident class the old poll loop used to silently self-heal via
        # respawn), not a reflection of the branch's code quality. Only
        # re-queue when the run has genuinely produced NOTHING and every
        # pending slot is confirmed dead — if even one reviewer is still
        # alive (slow, or wedged on a huge diff), fall through to the
        # existing FAIL path unchanged, same as before this fix.
        # ga-07509: on failure PC_SESS_JSON stays "" (never a look-alike-
        # valid fallback) — the loop below now guards this explicitly (see
        # the PC_SESS_JSON emptiness check, mirroring its two sibling
        # guards) instead of relying on PC_PRESENT_N's `|| echo 1` to
        # accidentally land on the same safe outcome for the wrong reason.
        PC_SESS_JSON=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json) || true
        PC_ANY_PENDING=0
        PC_ALL_PENDING_DEAD=1
        # SELFTEST-EXTRACT phase-c-dead-reviewer-classify-fn: BEGIN
        for PC_J in "${!VERDICT_BEAD_IDS[@]}"; do
          PC_VB="${VERDICT_BEAD_IDS[$PC_J]}"
          # ga-art5: `|| echo "open"` used to mask a failed `bd show` as a
          # genuinely-open verdict bead, feeding this classification loop
          # false data. We can't confirm this VB's status -> we can't confirm
          # "ALL pending are dead" either, so treat it the same as finding a
          # confirmed-LIVE reviewer (existing style just below): stop
          # classifying and fall through to the TIMEOUT path, which
          # independently re-reads each bead's status (with its own
          # unknown-safe handling) rather than guessing here.
          if ! PC_VB_JSON=$(bd -C "$GC_CITY" show "$PC_VB" --json 2>/dev/null); then
            warn "  Phase C: verdict bead $PC_VB status unreadable this sweep (bd show failed — transient Dolt hiccup?) — not confirming dead-reviewer classification; falling through to the TIMEOUT path instead of guessing (root-class:error-vs-empty, ga-art5)."
            PC_ALL_PENDING_DEAD=0
            break
          fi
          PC_VB_ST=$(printf '%s' "$PC_VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
          [ "$PC_VB_ST" = "closed" ] && continue
          PC_ANY_PENDING=1
          PC_SID="${SESSION_IDS[$PC_J]:-}"
          # ga-i5s5: an unreadable assignee capture (SESSION_IDS[$PC_J] set
          # to __UNKNOWN__ above when its bd-show failed) must not fall
          # through to the present-session lookup below — an unknown SID
          # matches no session either, which is indistinguishable from a
          # confirmed-absent one and would misclassify this reviewer DEAD.
          # Mirror the bd-show-failure branch immediately above this loop
          # (root-class:error-vs-empty): can't confirm dead, fall through to
          # the TIMEOUT path instead of guessing.
          if [ "$PC_SID" = "__UNKNOWN__" ]; then
            warn "  Phase C: verdict bead $PC_VB assignee capture was unreadable earlier this sweep (bd show failed — transient Dolt hiccup?) — not confirming dead-reviewer classification; falling through to the TIMEOUT path instead of guessing (root-class:error-vs-empty, ga-i5s5)."
            PC_ALL_PENDING_DEAD=0
            break
          fi
          # ga-07509: mirror the two guards above — an unreadable session
          # roster (gc session list failed) means we cannot confirm THIS
          # reviewer is dead either. Without this, PC_PRESENT_N's own
          # `|| echo 1` fallback would silently land on the same "treat as
          # present" outcome, but for the wrong reason (a jq-parse-failure
          # default, not a confirmed inability to classify) — fragile if
          # that fallback value ever changes for unrelated reasons.
          if [ -z "$PC_SESS_JSON" ]; then
            warn "  Phase C: gc session list unreadable this sweep (transient hiccup?) — not confirming dead-reviewer classification; falling through to the TIMEOUT path instead of guessing (root-class:error-vs-empty, ga-07509)."
            PC_ALL_PENDING_DEAD=0
            break
          fi
          PC_PRESENT_N=$(printf '%s' "$PC_SESS_JSON" \
            | jq -r --arg s "$PC_SID" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | length' 2>/dev/null || echo 1)
          case "$PC_PRESENT_N" in ''|*[!0-9]*) PC_PRESENT_N=1 ;; esac
          PC_PRESENT_FLAG=0
          PC_CLOSED_FLAG=false
          if [ "$PC_PRESENT_N" -ge 1 ]; then
            PC_PRESENT_FLAG=1
            PC_CLOSED_FLAG=$(printf '%s' "$PC_SESS_JSON" \
              | jq -r --arg s "$PC_SID" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | .[0].closed // false' 2>/dev/null || echo false)
          fi
          if [ "$(session_is_dead "$PC_PRESENT_FLAG" "$PC_CLOSED_FLAG")" != "1" ]; then
            PC_ALL_PENDING_DEAD=0
            break
          fi
        done
        # SELFTEST-EXTRACT phase-c-dead-reviewer-classify-fn: END
        if [ "$PC_ANY_PENDING" = "1" ] && [ "$PC_ALL_PENDING_DEAD" = "1" ]; then
          QUOTA_REQUEUE=1
          REQUEUE_REASON="dead-reviewer"
          warn "Phase C: gate-run $GATE_RUN_ID (branch=$BRANCH) timed out with ALL pending reviewer session(s) confirmed DEAD — infra failure, not a code FAIL (ga-eqjo)."
          gate_finalize_run
        else
          warn "Phase C: gate-run $GATE_RUN_ID (branch=$BRANCH) TIMED OUT after ${PC_ELAPSED}s (limit=${PC_TIMEOUT_SECS}s) with $VERDICTS_RECEIVED/$REQUIRED_REVIEWERS verdicts. Treating as FAIL."
          OVERALL_VERDICT="FAIL"
          FAIL_REASONS="TIMEOUT: reviewers did not submit verdicts within ${PC_TIMEOUT_MIN} minutes."
          # SELFTEST-EXTRACT phase-c-timeout-close-fn: BEGIN
          for PC_VB in "${VERDICT_BEAD_IDS[@]}"; do
            # ga-art5: same conflation this whole bead exists to close, now
            # at the site that does the HARD terminal action (label+comment+
            # close) — a `bd show` failure must never produce the same
            # decision as a genuinely-still-open verdict bead. Mirrors the
            # already-fixed ga-eqjo/ga-x3nmz requeue loops above
            # (vb_status_action, defined near the top of this file).
            # ga-h199q: NOT routed through the read-cache shim —
            # gate-verdict-status-unreadable.selftest.sh's phase-c-timeout-close-fn
            # section mocks `bd` in-shell and sources this file lib-only; the
            # shim's child-process bash invocation can't see that mock (verified:
            # "pc-open was NOT closed — happy path broken"), and its mutation
            # test anchors on this exact call text. Left live.
            if PC_VB_JSON=$(bd -C "$GC_CITY" show "$PC_VB" --json 2>/dev/null); then
              PC_VB_STATUS=$(printf '%s' "$PC_VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
            else
              PC_VB_STATUS="__UNKNOWN__"
            fi
            case "$(vb_status_action "$PC_VB_STATUS")" in
              unknown)
                log "  Verdict bead $PC_VB status unreadable this sweep (bd show failed — transient Dolt hiccup?) — skipping, will retry next sweep (root-class:error-vs-empty, ga-art5)."
                continue
                ;;
              skip) : ;;
              requeue)
                bd -C "$GC_CITY" label remove "$PC_VB" "verdict:pending" -q 2>/dev/null || true
                bd -C "$GC_CITY" label add    "$PC_VB" "verdict:TIMEOUT" -q 2>/dev/null || true
                bd -C "$GC_CITY" comment "$PC_VB" "VERDICT: TIMEOUT — reviewer session did not complete within ${PC_TIMEOUT_MIN}m" 2>/dev/null || true
                bd -C "$GC_CITY" close "$PC_VB" 2>/dev/null || true
                ;;
            esac
          done
          # SELFTEST-EXTRACT phase-c-timeout-close-fn: END
          gate_finalize_run
        fi
      else
        log "Phase C: gate-run $GATE_RUN_ID (branch=$BRANCH) still in flight ($VERDICTS_RECEIVED/$REQUIRED_REVIEWERS verdicts, ${PC_ELAPSED}s/${PC_TIMEOUT_SECS}s) — leaving for a future sweep."
      fi
    done
    GATE_SWEEP_HAS_MORE_WORK=0
  fi
fi

# ── Step 0a: TTL recovery — re-queue zombie dispatching markers ───────────────
# If a marker has been in gate-status:dispatching for > DISPATCHING_TTL_MINUTES,
# the dispatcher process was killed mid-run (after claiming but before completing).
# These would otherwise block forever because the dispatcher only processes
# gate-status:queued markers.  Reset them to queued so this sweep (or the next)
# can re-process them.
#
# TTL is 30m — same as the guard's claimed TTL.  Any legitimate dispatcher run
# that's been in flight for 30m has either spawned reviewers (verdict poll keeps
# the bead alive) or should be considered dead.
#
# Safety: we only recover markers that are STILL in dispatching — i.e. the
# dispatcher never finished (no passed/failed/error/needs-rebase was set).
#
# ga-eqjo (code-review fix): this 30m TTL assumed the single-instance lock
# spanned the ENTIRE claim-to-merge duration, so a marker stuck in
# gate-status:dispatching past 30m could only mean the dispatcher process
# itself died. That invariant is gone: Phase A now claims + spawns and EXITS
# in ~65-95s, releasing the lock while Phase B (reviewers) legitimately keeps
# working for up to VERDICT_TIMEOUT_MAX_MINUTES (50m) — and nothing touches
# the MARKER's updated_at during Phase B (only the separate verdict beads get
# updated). Without a fix here, every large/scaled-timeout review would get
# spuriously "TTL recovered" mid-flight roughly every 30m even though the
# dispatcher never died. Before reclaiming, check for a LIVE
# type:quality-gate-run bead (gate-status:running) whose marker_id: matches —
# that proves Phase B is legitimately still in progress, not a zombie.
DISPATCHING_TTL_MINUTES=30

# ga-h199q: routed through the read-cache shim (see live_sibling_run_for_branch's
# header comment — identical query, same-sweep dedup across 4 call sites). A
# ≤5s-stale miss here is inconsequential against the 30-minute reclaim threshold
# this feeds (~360x the cache TTL) — a run that started in the last 5s is never
# the same marker that's been dispatching for 30 minutes.
LIVE_RUN_MARKER_IDS_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json \
  -l type:quality-gate-run \
  -l gate-status:running \
  2>/dev/null || echo "[]")

# ga-h199q: routed through the read-cache shim — feeds the same 30-minute TTL
# reclaim check as LIVE_RUN_MARKER_IDS_JSON just above; a ≤5s-stale read is
# inconsequential against that threshold.
DISPATCHING_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json \
  -l type:quality-gate-marker \
  -l gate-status:dispatching \
  2>/dev/null || echo "[]")
DISPATCHING_COUNT=$(printf '%s\n' "$DISPATCHING_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$DISPATCHING_COUNT" -gt 0 ]; then
  NOW_EPOCH_D=$(date +%s)
  for di in $(seq 0 $((DISPATCHING_COUNT - 1))); do
    D_MARKER=$(printf '%s\n' "$DISPATCHING_JSON" | jq ".[$di]")
    D_ID=$(printf '%s\n' "$D_MARKER" | jq -r '.id')
    D_UPDATED=$(printf '%s\n' "$D_MARKER" | jq -r '.updated_at // .created_at // ""')
    if [ -z "$D_UPDATED" ]; then continue; fi
    # updated_at/created_at is UTC ("...Z"). Parse the BSD branch with -u so the
    # epoch is absolute and matches `date +%s`; without -u, macOS `date -j -f`
    # reads the naive timestamp as LOCAL time and ages come out skewed by the UTC
    # offset (negative under UTC-3), so the DISPATCHING_TTL recovery never fires
    # (ga-35zp1). GNU `date -d` keeps the trailing Z and is already UTC-correct.
    D_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${D_UPDATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$D_UPDATED" +%s 2>/dev/null || echo "0")
    D_AGE_MINUTES=$(( (NOW_EPOCH_D - D_EPOCH) / 60 ))
    if [ "$D_AGE_MINUTES" -gt "$DISPATCHING_TTL_MINUTES" ]; then
      D_HAS_LIVE_RUN=$(printf '%s' "$LIVE_RUN_MARKER_IDS_JSON" | jq -r --arg mid "$D_ID" \
        '[ .[] | select(((.description // "") | test("(^|\n)marker_id: *" + $mid + "( |\n|$)")) ) ] | length' 2>/dev/null || echo "0")
      case "$D_HAS_LIVE_RUN" in ''|*[!0-9]*) D_HAS_LIVE_RUN=0 ;; esac
      if [ "$D_HAS_LIVE_RUN" -gt 0 ]; then
        log "Marker $D_ID is ${D_AGE_MINUTES}m old in gate-status:dispatching but has a LIVE gate-run (Phase B legitimately still in progress, ga-eqjo) — NOT reclaiming as a zombie."
        continue
      fi
      warn "Re-queuing zombie dispatching marker $D_ID (age=${D_AGE_MINUTES}m > TTL=${DISPATCHING_TTL_MINUTES}m — dispatcher died mid-run, no live gate-run found)"
      bd -C "$GC_CITY" label remove "$D_ID" "gate-status:dispatching" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$D_ID" "gate-status:queued"      -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$D_ID" "Dispatcher TTL recovery: marker was stuck in gate-status:dispatching for ${D_AGE_MINUTES}m (> ${DISPATCHING_TTL_MINUTES}m TTL) with no live gate-run bead found. Dispatcher process died mid-run. Re-queuing for re-processing." 2>/dev/null || true
    fi
  done
fi

# ── Step 0a-2 (ga-zl277): reap orphaned gate-reviewer sessions ────────────────
# Backstop for the EXIT trap below: a dispatcher killed by SIGKILL/OOM/launchd
# timeout cannot run any trap, so its already-spawned reviewer sessions stay
# ASLEEP and never get closed. They consume the gate-reviewer template's
# max_active_sessions=6 budget; once full, runs spawn fewer than 3 reviewers and
# fail too — the ga-zl277 vicious cycle. Each sweep we close any gate-reviewer
# session that is NON-active, NON-attached, and older than the TTL.
#
# SAFE UNDER CONCURRENCY: launchd fires this dispatcher every ~2 min while a run
# can hold reviewers open for up to VERDICT_TIMEOUT_MINUTES, so sibling runs DO
# overlap. A live run closes its reviewers in Step 9 (before the merge) and the
# verdict poll caps the run at VERDICT_TIMEOUT_MINUTES, so any gate-reviewer
# older than verdict-timeout+margin cannot belong to a live sibling. We never
# touch an active or attached session.
#
# Pure decision (no IO, set -e safe) — mirrored + drift-guarded by
# gate-reviewer-orphan-reap.selftest.sh. echo "reap" iff the session is a
# NON-active, NON-attached gate-reviewer older than the TTL, else "keep".
reviewer_session_should_reap() {
  local state="$1" attached="$2" age="$3" ttl="$4"
  case "$age" in ''|*[!0-9]*) echo "keep"; return 0 ;; esac
  case "$ttl" in ''|*[!0-9]*) echo "keep"; return 0 ;; esac
  [ "$attached" = "true" ] && { echo "keep"; return 0; }
  [ "$state" = "active" ]  && { echo "keep"; return 0; }
  if [ "$age" -gt "$ttl" ]; then echo "reap"; else echo "keep"; fi
}

# ga-07509: on failure REVIEWER_SESSIONS_RAW stays "" (never the look-alike
# -valid '{}' the old fallback produced). REVIEWER_SESSION_COUNT's own
# `''|*[!0-9]*) =0` normalization below still treats that as "zero
# reviewers" this sweep — the orphan-reap (ga-zl277) is skipped and
# LIVE_REVIEWERS (the headroom-gate denominator, gt-bewtm) under-counts for
# one sweep, same as a genuinely-empty roster. Both are self-healing (next
# sweep re-fetches) and nothing here arms a destructive action off the false
# zero, so this failure mode stays fail-open, matching the headroom gate's
# own Dolt-outage handling below — but it must be LOGGED so a real,
# recurring gc outage isn't invisible.
REVIEWER_SESSIONS_RAW=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json) || true
if [ -z "$REVIEWER_SESSIONS_RAW" ]; then
  warn "  gc session list unreadable this sweep — skipping gate-reviewer orphan-reap (ga-zl277) and reading REVIEWER_SESSION_COUNT=0 for headroom this sweep only (ga-07509, self-heals next sweep)."
fi
REVIEWER_SESSIONS_JSON=$(echo "$REVIEWER_SESSIONS_RAW" \
  | jq -c '[.sessions[]? | select(.template=="gate-reviewer")]' 2>/dev/null || echo "[]")
REVIEWER_SESSION_COUNT=$(echo "$REVIEWER_SESSIONS_JSON" | jq 'length' 2>/dev/null || echo "0")
case "$REVIEWER_SESSION_COUNT" in ''|*[!0-9]*) REVIEWER_SESSION_COUNT=0 ;; esac

if [ "$REVIEWER_SESSION_COUNT" -gt 0 ]; then
  NOW_EPOCH_R=$(date +%s)
  REAPED_REVIEWERS=0
  DRAINED_REVIEWERS=0
  for ri in $(seq 0 $((REVIEWER_SESSION_COUNT - 1))); do
    R_SESSION=$(echo "$REVIEWER_SESSIONS_JSON" | jq -c ".[$ri]" 2>/dev/null || echo "{}")
    R_ID=$(echo "$R_SESSION" | jq -r '.id // empty' 2>/dev/null || echo "")
    R_STATE=$(echo "$R_SESSION" | jq -r '.state // ""' 2>/dev/null || echo "")
    R_ATTACHED=$(echo "$R_SESSION" | jq -r '.attached // false' 2>/dev/null || echo "false")
    R_CREATED=$(echo "$R_SESSION" | jq -r '.created_at // ""' 2>/dev/null || echo "")
    [ -z "$R_ID" ] && continue
    [ -z "$R_CREATED" ] && continue
    # created_at is UTC ("...Z"). Parse the BSD branch with -u so the epoch is
    # absolute and matches `date +%s`; without -u, macOS `date -j -f` reads the
    # naive timestamp as LOCAL time and ages come out skewed by the UTC offset
    # (negative under UTC-3). GNU `date -d` keeps the trailing Z and is already
    # UTC-correct.
    R_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${R_CREATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$R_CREATED" +%s 2>/dev/null || echo "0")
    [ "$R_EPOCH" = "0" ] && continue
    R_AGE_MINUTES=$(( (NOW_EPOCH_R - R_EPOCH) / 60 ))
    if [ "$(reviewer_session_should_reap "$R_STATE" "$R_ATTACHED" "$R_AGE_MINUTES" "$REVIEWER_SESSION_TTL_MINUTES")" = "reap" ]; then
      warn "Reaping orphaned gate-reviewer session $R_ID (state=$R_STATE attached=$R_ATTACHED age=${R_AGE_MINUTES}m > TTL=${REVIEWER_SESSION_TTL_MINUTES}m — frees cap slot; ga-zl277)"
      gc --city "$GC_CITY" session close "$R_ID" 2>/dev/null || true
      REAPED_REVIEWERS=$((REAPED_REVIEWERS + 1))
    else
      # gt-bewtm: a KEPT (young, not-age-reaped) reviewer may have DRAINED — its
      # Claude session ended normally yet it stays LISTED + not-closed and
      # presents as asleep, so the age-TTL janitor above keeps it but it occupies
      # NO real cap budget. Under Dolt pressure reviewers drain often; counting
      # them as live inflates LIVE_REVIEWERS, the Step 0b-1 headroom gate hits a
      # false cap and DEFERs every sweep with Dolt calm + queue full (the
      # town-wide deadlock). `gc session peek` is the discriminator the list
      # lacks (ga-h9o17): a drained/ended session answers "session not found" on
      # STDERR, a genuinely asleep-but-alive one answers with scrollback on
      # STDOUT. `2>&1 >/dev/null` captures ONLY stderr so a live reviewer's
      # scrollback can never false-match. We do NOT close it here (the age-TTL
      # janitor owns reaping); we only EXCLUDE it from the headroom denominator,
      # which is the safe, headroom-calc-only fix — peek reads slow-alive as
      # alive, so a transient glitch can never under-count live reviewers.
      _R_PEEK_ERR=$(gc --city "$GC_CITY" session peek "$R_ID" --lines 1 2>&1 >/dev/null || true)
      if [ "$(session_peek_reports_dead "$_R_PEEK_ERR")" = "1" ]; then
        log "Drained gate-reviewer session $R_ID (state=$R_STATE age=${R_AGE_MINUTES}m < TTL but peek reports session-gone) — excluding from headroom LIVE_REVIEWERS (gt-bewtm)."
        DRAINED_REVIEWERS=$((DRAINED_REVIEWERS + 1))
      fi
    fi
  done
  if [ "$REAPED_REVIEWERS" -gt 0 ]; then
    log "Reaped $REAPED_REVIEWERS orphaned gate-reviewer session(s) this sweep (ga-zl277)."
  fi
  if [ "$DRAINED_REVIEWERS" -gt 0 ]; then
    log "Excluded $DRAINED_REVIEWERS drained gate-reviewer session(s) from headroom LIVE_REVIEWERS this sweep (gt-bewtm)."
  fi
fi

# ── Step 0a-3 (ga-rstw5): reconcile container-rig bare mains to origin ─────────
# Container rigs (.repo.git) keep a LOCAL refs/heads/<main> that a push to origin
# never advances; when it drifts/forks from origin/<main> the durable-landing step
# used to false-FAIL an all-PASS verdict (failed_durable_not_ff) and mail crew a
# spurious FAIL (ga-rstw5). do_merge_ff now reconciles the rig it merges, but this
# startup sweep additionally keeps EVERY container rig's bare main tracking origin
# each sweep, healing a stale/forked mirror BEFORE any branch reaches the guard
# (AC: bare main of every container rig tracks origin/main after a gate run).
# Cheap + idempotent: a single-ref fetch + ancestry check; only a forked ref is
# rewritten (to origin; forked tip backed up first). Silent on the common no-op so
# it does not spam the log every ~2 min.
# ga-07509: on failure RECON_RIG_JSON stays "" (never the look-alike-valid
# '{}' the old fallback produced). RECON_RIG_COUNT's own normalization below
# still reads that as "zero rigs" — this sweep's bare-main reconciliation is
# skipped, self-healing next sweep exactly like a genuine zero-rig registry
# would (this step is cheap + idempotent by design). Unlike a genuine no-op
# though, a FAILURE re-exposes the ga-rstw5 false-FAIL risk this whole step
# exists to prevent, so — unlike the no-op case, which stays silent on
# purpose — a failed fetch must be logged.
RECON_RIG_JSON=$(gc_json_or_unknown gc --city "$GC_CITY" rig list --json) || true
if [ -z "$RECON_RIG_JSON" ]; then
  warn "  gc rig list unreadable this sweep — skipping bare-main reconciliation (ga-rstw5 defense) this sweep only (ga-07509, self-heals next sweep)."
fi
RECON_RIG_COUNT=$(echo "$RECON_RIG_JSON" | jq '.rigs | length' 2>/dev/null || echo "0")
case "$RECON_RIG_COUNT" in ''|*[!0-9]*) RECON_RIG_COUNT=0 ;; esac
if [ "$RECON_RIG_COUNT" -gt 0 ]; then
  for rci in $(seq 0 $((RECON_RIG_COUNT - 1))); do
    RC_PATH=$(echo "$RECON_RIG_JSON"   | jq -r ".rigs[$rci].path // \"\""               2>/dev/null || echo "")
    RC_BRANCH=$(echo "$RECON_RIG_JSON" | jq -r ".rigs[$rci].default_branch // \"main\"" 2>/dev/null || echo "main")
    RC_NAME=$(echo "$RECON_RIG_JSON"   | jq -r ".rigs[$rci].name // \"?\""              2>/dev/null || echo "?")
    [ -z "$RC_PATH" ] && continue
    # Only container rigs have a bare .repo.git mirror that can drift; self-repo
    # rigs (wa, gascity, marketing) read origin directly and are unaffected.
    [ -d "$RC_PATH/.repo.git" ] || continue
    RC_OUT=""
    RC_RC=0
    RC_OUT=$(reconcile_bare_main_to_origin "$RC_PATH/.repo.git" "$RC_BRANCH") || RC_RC=$?
    if [ "$RC_RC" != "0" ]; then
      warn "Startup reconcile: rig $RC_NAME bare $RC_BRANCH FAILED ($RC_OUT) — continuing"
    else
      case "$RC_OUT" in
        noop:*) : ;;  # already tracking origin — silent
        *) log "Startup reconcile: rig $RC_NAME bare $RC_BRANCH → origin ($RC_OUT)" ;;
      esac
    fi
  done
fi

# ── Step 0a-4 (ga-88sl7): reap needs-rebase markers for already-merged branches ─
# gate-status:needs-rebase is EXCLUDED from Step 0b's queued-only selection
# (`-l gate-status:queued`, below) by design — a genuinely-behind branch must
# not be re-bounced/re-nudged every ~2min sweep. quality-gate-guard.sh's own
# reclaim (Vector A) explicitly treats needs-rebase as terminal too. Net
# effect: once a marker is bounced to needs-rebase, NOTHING ever re-checks it
# against the CURRENT state of main again — Step 4b's already-merged
# detection only ever runs ONCE, at that marker's original dispatch. If the
# underlying work ships through any other route afterward (a fresh
# branch/marker for the same bead, a manual merge) this marker is stranded
# holding a queue slot forever — correctly classified at the time, never
# re-evaluated since. Measured live (ga-88sl7, Mayor 06/08): 5 of 10 open
# gate markers were exactly this — two with behind>250 — and all 5 source
# beads were already closed (the work shipped some other way).
# This sweep is the periodic re-check Step 4b's one-shot classification
# cannot be: cheap (one merge-base per candidate, no author/session IO, no
# push/nudge), and scoped ONLY to "is it merged now?" — a genuinely-still-
# diverged branch is untouched and stays in needs-rebase exactly as before
# this fix (AC4 non-regression).
NEEDS_REBASE_JSON=$(bd -C "$GC_CITY" list --json --all --status open \
  -l type:quality-gate-marker \
  -l gate-status:needs-rebase \
  2>/dev/null || echo "[]")
NEEDS_REBASE_COUNT=$(printf '%s\n' "$NEEDS_REBASE_JSON" | jq 'length' 2>/dev/null || echo "0")
case "$NEEDS_REBASE_COUNT" in ''|*[!0-9]*) NEEDS_REBASE_COUNT=0 ;; esac

if [ "$NEEDS_REBASE_COUNT" -gt 0 ]; then
  REAPED_NEEDS_REBASE=0
  for nri in $(seq 0 $((NEEDS_REBASE_COUNT - 1))); do
    NR_MARKER=$(printf '%s\n' "$NEEDS_REBASE_JSON" | jq -c ".[$nri]" 2>/dev/null || echo "{}")
    NR_MARKER_ID=$(printf '%s' "$NR_MARKER" | jq -r '.id // empty' 2>/dev/null || echo "")
    DESC=$(printf '%s' "$NR_MARKER" | jq -r '.description // ""' 2>/dev/null || echo "")
    [ -z "$NR_MARKER_ID" ] && continue
    [ -z "$DESC" ] && continue

    NR_BRANCH=$(extract "branch")
    NR_BEAD_ID=$(extract "bead_id")
    NR_RIG=$(extract "rig")
    [ -z "$NR_BRANCH" ] && continue

    # Resolve THIS candidate's rig context fresh — gate_resolve_rig_context
    # reads/writes $RIG/$BEAD_ID/$RIG_PATH/$GIT_DIR_PATH/$IS_CONTAINER_RIG/
    # $DEFAULT_BRANCH/$BEAD_CITY as globals. Step 0b/Step 2/Step 4 below
    # re-derive all of these fresh from the sweep's OWN candidate before use,
    # so leaving them set to this loop's last iteration here is safe.
    RIG="$NR_RIG"
    BEAD_ID="$NR_BEAD_ID"
    if ! gate_resolve_rig_context; then
      log "  Step 0a-4: cannot resolve rig context for marker $NR_MARKER_ID (rig=$NR_RIG) — skipping this sweep."
      continue
    fi

    [ "$(gate_branch_already_merged "$NR_BRANCH" "$DEFAULT_BRANCH")" != "1" ] && continue

    log "Step 0a-4: branch $NR_BRANCH (marker $NR_MARKER_ID) is already merged into $DEFAULT_BRANCH — reaping stranded needs-rebase marker (ga-88sl7)."
    set_gate_status "$NR_MARKER_ID" "superseded"
    bd -C "$GC_CITY" comment "$NR_MARKER_ID" "Branch $NR_BRANCH is already merged into $DEFAULT_BRANCH (git merge-base --is-ancestor confirmed). This marker was stranded at gate-status:needs-rebase — needs-rebase is excluded from normal re-dispatch, so nothing re-checked it after the original bounce. Reaped by the Step 0a-4 periodic terminality sweep (ga-88sl7)." 2>/dev/null || true
    bd -C "$GC_CITY" close "$NR_MARKER_ID" -r "Gate marker terminal: SUPERSEDED (branch $NR_BRANCH already merged to $DEFAULT_BRANCH; reaped from stranded needs-rebase by Step 0a-4, ga-88sl7)." 2>/dev/null || true

    if [ -n "$BEAD_ID" ]; then
      if NR_BD_JSON=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null); then
        NR_BD_STATUS=$(printf '%s' "$NR_BD_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || echo "open")
      else
        NR_BD_STATUS="__UNKNOWN__"
      fi
      case "$NR_BD_STATUS" in
        closed) : ;;  # already terminal — the common case: the work shipped some other way.
        __UNKNOWN__)
          log "  Step 0a-4: source bead $BEAD_ID status unreadable this sweep — leaving it untouched (marker already reaped; will retry bead cleanup next sweep if still open)."
          ;;
        *)
          NR_SRC_LABELS=$(printf '%s' "$NR_BD_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "")
          # ga-67hae pilot-cascade fix, mirrored: strip story:in-flight so the
          # Pilot lane slot frees regardless of story/bug routing below.
          bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true
          bd -C "$BEAD_CITY" assign "$BEAD_ID" "" -q 2>/dev/null || true
          if printf '%s' "$NR_SRC_LABELS" | grep -q "story:approved"; then
            # STORY → hand off to story-delivery, same as Step 4b's already-merged
            # path: gate:passed is delivery's pickup signal; do not close here.
            bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
            bd -C "$BEAD_CITY" comment "$BEAD_ID" "Branch $NR_BRANCH already in $DEFAULT_BRANCH — gate skipped (marker $NR_MARKER_ID superseded, reaped from stranded needs-rebase). STORY: handed off to story-delivery (gate:passed set; story:approved kept; story:in-flight stripped). (ga-88sl7)" 2>/dev/null || true
          else
            bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:superseded" -q 2>/dev/null || true
            bd -C "$BEAD_CITY" comment "$BEAD_ID" "Branch $NR_BRANCH already in $DEFAULT_BRANCH — gate superseded (marker $NR_MARKER_ID, reaped from stranded needs-rebase). story:in-flight stripped; work already merged. (ga-88sl7)" 2>/dev/null || true
            bd -C "$BEAD_CITY" close "$BEAD_ID" -r "Branch $NR_BRANCH already merged to $DEFAULT_BRANCH — delivered via prior merge; gate superseded (marker $NR_MARKER_ID, reaped from stranded needs-rebase, ga-88sl7)." 2>/dev/null \
              || warn "Could not close already-merged non-story source bead $BEAD_ID (non-fatal)."
          fi
          ;;
      esac
    fi
    REAPED_NEEDS_REBASE=$((REAPED_NEEDS_REBASE + 1))
  done
  if [ "$REAPED_NEEDS_REBASE" -gt 0 ]; then
    log "Step 0a-4: reaped $REAPED_NEEDS_REBASE stranded needs-rebase marker(s) this sweep (ga-88sl7)."
  fi
fi

# ── ga-cw4pm / gt-bewtm: live reviewer-session count for the headroom gate ────
# gate-reviewer sessions still alive AFTER this sweep's reaping occupy the
# template's max_active_sessions budget — they are the denominator for the
# dynamic-concurrency decision (Step 0b-1). REVIEWER_SESSION_COUNT is set by the
# Step 0a-2 janitor (0 when no reviewer sessions exist); REAPED_REVIEWERS and
# DRAINED_REVIEWERS are only set inside the janitor's >0 branch, so the pure
# helper defaults both to 0 for the no-session sweep.
# gt-bewtm: subtract DRAINED_REVIEWERS — young (not-age-reaped) sessions whose
# Claude has drained but still LIST as asleep+not-closed. Without this, those
# phantoms inflated the denominator and the headroom gate hit a false
# "dolt-calm-cap-reached" ceiling, DEFERring every sweep with Dolt calm + queue
# full (the 2026-06-12 town-wide deadlock).
LIVE_REVIEWERS=$(headroom_live_reviewers "${REVIEWER_SESSION_COUNT:-0}" "${REAPED_REVIEWERS:-0}" "${DRAINED_REVIEWERS:-0}")

# ── ga-309v3: burst-aware correction — DO NOT REMOVE ──────────────────────────
# Step 0a-2's drained-exclusion calls session_peek_reports_dead with no booting
# guard, and `gc session peek` reports "session not found" for BOTH a drained
# session AND one still inside its ~210s deferred-start window (ga-flfo/ga-xwdl;
# the ACK path at Step 7b pairs that probe with session_is_booting +
# RECONVENE_GRACE_SECS for exactly this reason, this one does not).
#
# A continuation round runs ~30-120s after the previous round called
# `gc session new` — squarely inside that window. Its reviewers are still
# state=creating, get counted as DRAINED and subtracted, so LIVE_REVIEWERS reads
# 0 and the headroom gate believes the plane is empty. That turns the multi-admit
# burst into an UNBRAKED loop: on a genuinely hot Dolt the `dolt-hot-floor`
# in-flight==0 branch flips defer into admit on every round, and on the calm path
# a burst starting near the cap can push past the gate-reviewer template's
# max_active_sessions (the ga-zl277 vicious cycle, where the gate can no longer
# spawn reviewers at all).
#
# Each prior round of THIS burst admitted exactly one run, so add back what those
# rounds spawned. Over-counting (when the probe DOES see them) is the safe
# direction — it defers earlier — whereas under-counting is what removes the
# brake. This corrects the burst's own blind spot without touching the
# pre-existing probe, which is a separate fix on its own bead.
# ga-991au: charge the add-back to ADMITS, not rounds. A skip round spawned
# nothing; counting it would invent a reviewer that does not exist and, on the
# hot path, flip the ga-q4gqq dolt-hot-floor (which admits only at inflight==0)
# from admit to defer — killing the burst in the exact degraded state it is for.
if [ "${GATE_ADMITS_DONE:-0}" -gt 0 ] 2>/dev/null; then
  _burst_admitted=$(( GATE_ADMITS_DONE * GATE_REVIEWERS_PER_RUN ))
  LIVE_REVIEWERS=$(( LIVE_REVIEWERS + _burst_admitted ))
  log "Multi-admit round ${GATE_ADMIT_ROUND} (${GATE_ADMITS_DONE} admit(s) so far): +${_burst_admitted} reviewer(s) added back to LIVE_REVIEWERS=${LIVE_REVIEWERS} — this burst's own spawns can still be inside the ~210s boot window and read as drained (ga-309v3/ga-991au)."
fi

# ── Step 0b: Find a queued marker ────────────────────────────────────────────
# quality-gate-guard.sh claims, validates, derives author, and parks markers as
# gate-status:queued.  We only process queued markers — the guard already did
# all the security work.

# ga-h199q: routed through the read-cache shim — worst-case a stale/empty read
# here just defers newly-queued work to the next 180s sweep (this script has no
# internal loop; launchd re-execs it), the same bounded delay the TTL-recovery
# checks above already tolerate.
MARKERS_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json \
  -l type:quality-gate-marker \
  -l gate-status:queued \
  2>/dev/null || echo "[]")

COUNT=$(printf '%s\n' "$MARKERS_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT queued marker(s)"

if [ "$COUNT" = "0" ]; then
  log "No queued markers. Exiting."
  exit 0
fi

# ── Step 0b-1 (ga-cw4pm): dynamic-concurrency headroom gate ───────────────────
# There IS queued work. Before opening a NEW run (claiming a marker + spawning N
# reviewers), check whether the Dolt data plane + Claude quota can absorb the
# added load, and scale the concurrency ceiling dynamically (replacing the static
# gate-reviewer max_active_sessions=6). On DEFER we exit 0 WITHOUT touching any
# marker — the FIFO queue is untouched and retried next sweep (~2 min) once Dolt
# cools or quota recovers. This runs BEFORE the atomic claim below, so a deferred
# sweep never strands a marker in gate-status:dispatching, and BEFORE the EXIT
# trap is installed (Step 7), so the early exit needs no reviewer cleanup.
#
# FAIL-OPEN is load-bearing: this daemon is town-critical-path; a wedged
# `gc dolt health` must NEVER deadlock the gate. Only a POSITIVELY-MEASURED hot
# reading (or a confirmed quota limit) defers. GATE_HEADROOM_ENABLED=0 restores
# the exact pre-ga-cw4pm behavior (no probe, always proceed).
if [ "${GATE_HEADROOM_ENABLED:-1}" = "1" ]; then
  # 1. Dolt CPU/latency. Override seam (GATE_DOLT_LATENCY_OVERRIDE_MS) keeps the
  #    selftest off live `gc dolt health`. `gc dolt health` does NOT accept --city
  #    (errors out) — scope via the GC_CITY env var, exactly like the Pilot probe.
  if [ -n "${GATE_DOLT_LATENCY_OVERRIDE_MS:-}" ]; then
    HR_LAT="$GATE_DOLT_LATENCY_OVERRIDE_MS"; HR_PID="TEST"
  else
    # ga-07509: on FAILURE HR_H stays "" — identical to the pre-fix empty
    # shape, so the FAIL-OPEN "no-signal" branch documented above is
    # unchanged; only a failure can no longer be mistaken for a successful
    # read that merely omitted these fields.
    HR_H=$(GC_CITY="$GC_CITY" gc_json_or_unknown timeout 15 gc dolt health --json) || true
    HR_LAT=$(printf '%s' "$HR_H" | jq -r '.server.latency_ms // empty' 2>/dev/null || echo "")
    HR_PID=$(printf '%s' "$HR_H" | jq -r '.server.pid // empty' 2>/dev/null || echo "")
  fi
  # ga-bgvc0: judge the plane by its AMBIENT load (sampled at sweep start, before
  # our own janitors spiked it), not the self-inflated post-janitor reading. Fall
  # back to the post-janitor reading when the ambient snapshot is absent.
  HR_CPU_POSTJANITOR=$(gate_dolt_cpu "${HR_PID:-}")
  HR_CPU=$(gate_effective_headroom_cpu "${GATE_AMBIENT_DOLT_CPU:-}" "${HR_CPU_POSTJANITOR:-}")
  # 2. Claude quota (optional ga-wjlv9 dep; fail-open when the checker is absent).
  HR_QLIM=$(gate_quota_limited)
  # 2b. Free swap (ga-92azu resource brake) — independent of Dolt/quota; see
  #     gate_headroom_decision § 1b for why this cannot piggyback on either.
  HR_SWAP_FREE=$(gate_swap_free_mb)
  # 3. Pure dynamic-concurrency decision.
  HR_DECISION=$(gate_headroom_decision \
    "${HR_CPU:-}" "${HR_LAT:-}" "$HR_QLIM" "$LIVE_REVIEWERS" \
    "$GATE_DOLT_CPU_HOT" "$GATE_DOLT_CPU_WARM" "$GATE_DOLT_LATENCY_HOT_MS" \
    "$GATE_MAX_REVIEWERS" "$GATE_REVIEWERS_PER_RUN" "${GATE_HEADROOM_FAILOPEN:-1}" \
    "${HR_SWAP_FREE:-}" "$GATE_SWAP_FREE_FLOOR_MB")
  HR_VERDICT=$(printf '%s' "$HR_DECISION" | awk '{print $1}')
  HR_CEILING=$(printf '%s' "$HR_DECISION" | awk '{print $2}')
  HR_REASON=$(printf '%s' "$HR_DECISION" | cut -d' ' -f3-)
  # N in-flight runs for the log line = ceil(LIVE_REVIEWERS / reviewers-per-run).
  HR_RUNS=$(( ( LIVE_REVIEWERS + GATE_REVIEWERS_PER_RUN - 1 ) / GATE_REVIEWERS_PER_RUN ))
  if [ "$HR_QLIM" = "1" ]; then HR_COTA="LIMITED"; else HR_COTA="ok"; fi
  if [ "$HR_VERDICT" = "defer" ]; then
    log "Headroom DEFER: gate em $HR_RUNS runs (Dolt cpu=${HR_CPU:-?}% [ambient; post-janitor=${HR_CPU_POSTJANITOR:-?}%] lat=${HR_LAT:-?}ms / cota=${HR_COTA} / swap_free=${HR_SWAP_FREE:-?}MB) — ${HR_REASON}; ceiling=${HR_CEILING} reviewers, leaving $COUNT marker(s) queued (ga-cw4pm)."
    exit 0
  fi
  log "Headroom OK: gate em $HR_RUNS runs (Dolt cpu=${HR_CPU:-?}% [ambient; post-janitor=${HR_CPU_POSTJANITOR:-?}%] lat=${HR_LAT:-?}ms / cota=${HR_COTA} / swap_free=${HR_SWAP_FREE:-?}MB) — ${HR_REASON}; ceiling=${HR_CEILING} reviewers, admitting a new run (ga-cw4pm)."
fi

# QUEUE ORDER: newest-first tiebreak (4cae0a2c49, 2026-06-24 — Athos: gate>
# execute>refine>create, bugs>stories, desempate=mais novo). Originally this
# was oldest-first FIFO (ga-zf61i: bd list returns newest-first, and a bare
# .[0] always grabbed the NEWEST → with ~1 marker/sweep throughput, older
# markers like iz4a96/ga-mr8ym + 2-day-old pddg18/pqzl9h starved indefinitely).
# 4cae0a2c49 deliberately flipped that: sort_by(.created_at) | reverse now
# picks the NEWEST of the no-rebase-fail markers each sweep — an explicit
# priority policy, not a regression of the ga-zf61i fix.
#
# created_at is IMMUTABLE via `bd label add/remove` — cycling a marker's
# gate-status:queued label off and on does NOT refresh created_at and CANNOT
# change its queue rank under this (or any) ordering. A marker starved by the
# newest-first tiebreak (distinct from the ga-q3ig2 dead-rebase case below)
# can only regain priority by being closed and replaced with a fresh
# type:quality-gate-marker bead cloning its description fields — see
# docs/gate-marker-recipe.md. (ga-gsh1e / gt-mqkwj — a repair dog burned a
# full cycle on the label-cycle trick before finding this out the hard way.)
#
# ga-q3ig2 HEAD-OF-LINE FIX: a marker whose branch is stale-with-conflict and
# whose author is dead/transient gets re-queued — here (dead-author bounded
# retry re-adds gate-status:queued), by gate-health-monitor, or by a manual
# re-anchor that resets the gate:exiled-tier5 counter (named gate:rebase-attempt
# before ga-gpcx — see read_rebase_attempt above). Because the broken
# marker keeps the OLDEST created_at, a pure FIFO sort re-selects it EVERY
# sweep, fails the same rebase, and never reaches the N healthy markers behind
# it ("o FIFO insiste nele"). Result: 2× outages 2026-06-10 (~16:30, ~18:03-18:52
# = 49min) where one broken branch travou a fila INTEIRA (18 markers), zero
# merges until manual intervention.
#
# Fix: two-tier ordering. Markers with NO prior auto-rebase failure are drained
# first. Markers that already failed an auto-rebase (they carry a
# gate:exiled-tier5:N label) sink to the BACK and are only re-attempted when
# no healthy marker is queued. One broken branch can no longer travar a fila
# regardless of who re-queues it — the queue drains the healthy markers while the
# broken one is "tratado à parte" (escalated to needs-rebase by its own bounded
# retry / gate-health-monitor). Star-guide: gate never idles >15min on 1 stale branch.
#
# ga-tgo7q STARVATION-BOUND AGING: the newest-first tiebreak above is Athos's
# explicit, intended policy — but under continuous submission it can starve an
# old HEALTHY marker indefinitely (live repro: ga-wisp-7yity6v queued 90+ min
# while newer healthy markers kept jumping ahead), which also defeats
# gt-mqkwj's orphan-marker re-queue (created_at is immutable, so a starved
# marker's rank never improves on its own — see the note above re: the
# label-cycle trick being a no-op). Fix: within the healthy tier only, split
# further by age. A healthy marker that has waited longer than
# GATE_MARKER_AGE_PROMOTE_SECONDS is force-promoted ahead of every not-yet-aged
# healthy marker (FIFO among the aged set, so the longest-starved always goes
# first once promoted). This gives every healthy marker a hard wait bound
# while leaving the newest-first tiebreak untouched for markers still inside
# the window. Aging does NOT reach into the rebase-fail tier — letting a
# broken marker age its way back to the front would reintroduce the exact
# ga-q3ig2 outage class this fix sits next to. GATE_MARKER_NOW_OVERRIDE_EPOCH
# is a test-only seam (same convention as GATE_DOLT_LATENCY_OVERRIDE_MS) so
# selftests can control "now" without depending on the wall clock.
# SELFTEST-EXTRACT marker-select: BEGIN
GATE_MARKER_AGE_PROMOTE_SECONDS="${GATE_MARKER_AGE_PROMOTE_SECONDS:-1800}"
GATE_MARKER_NOW_EPOCH="${GATE_MARKER_NOW_OVERRIDE_EPOCH:-$(date -u +%s)}"
# ga-* (2026-07-15, Athos): CREW-PRIORITY tier. A space-separated allowlist of
# crew names (the `<crew>` segment of the marker's `branch: crew/<crew>/<bead>`
# field in the DESCRIPTION) whose HEALTHY markers drain BEFORE everyone else's, on
# top of the existing aged/newest tiebreaks. Keyed on the BRANCH crew segment, NOT
# the `author:` field: /gate-done writes author as the agent alias "oracle-wa" while
# the recipe writes bare "oracle" — the branch's crew dir is consistently "oracle"
# across both, so it is the reliable signal. Set to prioritize Oracle's gate
# throughput: his own crew/oracle/* builds AND the in-session sub-workers he spawns
# (their commits land on his crew/oracle/* branch → same crew segment). The
# `gate:priority` LABEL is an independent manual override for any single marker
# regardless of branch (e.g. a sub-worker Oracle SLINGS onto a crew/wa-worker/*
# branch — tag that marker's gate:priority off the source bead's created_by).
# REVERSIBLE: set GATE_PRIORITY_AUTHORS="" in the plist to disable the crew tier
# (the label override still works); the ordering collapses to the exact prior
# aged/newest behaviour. rebase-fail markers stay at the BACK even when their crew
# is prioritized — a broken branch must never jump the queue and re-break it
# (ga-q3ig2 outage class); priority raises healthy work, it does not rescue a
# conflicted one. (Env var name kept as GATE_PRIORITY_AUTHORS for continuity.)
GATE_PRIORITY_AUTHORS="${GATE_PRIORITY_AUTHORS-oracle}"
# GATE-FEEDBACK (gate_run=ga-wisp-a7b4r5): every sibling GATE_* tunable (see
# GATE_DOLT_CPU_HOT etc. above) gets a case-guard right after its ${VAR:-default}
# assignment; these two didn't, so a non-numeric override (config typo) made
# `jq --argjson` exit 2 BEFORE the marker array was even read — under this
# script's `set -euo pipefail`, that aborts the entire dispatcher sweep, not
# just this marker. Same guard convention, applied here.
case "$GATE_MARKER_AGE_PROMOTE_SECONDS" in ''|*[!0-9]*) GATE_MARKER_AGE_PROMOTE_SECONDS=1800 ;; esac
case "$GATE_MARKER_NOW_EPOCH"           in ''|*[!0-9]*) GATE_MARKER_NOW_EPOCH=$(date -u +%s) ;; esac
MARKER=$(printf '%s\n' "$MARKERS_JSON" | jq \
  --argjson now "$GATE_MARKER_NOW_EPOCH" \
  --argjson age_threshold "$GATE_MARKER_AGE_PROMOTE_SECONDS" \
  --arg priority_authors "$GATE_PRIORITY_AUTHORS" '
  # ga-gpcx: matches both the current name (gate:exiled-tier5:N) and the
  # legacy name (gate:rebase-attempt:N, used before 2026-07-17) so a marker
  # already exiled under the old name at deploy time stays correctly sunk to
  # this tier instead of being silently released into the healthy tier (which
  # would reintroduce the ga-q3ig2 outage class). See read_rebase_attempt().
  def has_rebase_fail: ((.labels // []) | map(select(test("^gate:(rebase-attempt|exiled-tier5):[0-9]+$"))) | length) > 0;
  def is_aged: try (($now - (.created_at | fromdateiso8601)) > $age_threshold) catch false;
  # crew_of parses the <crew> segment of `branch: crew/<crew>/<bead>` from the
  # marker DESCRIPTION. MUST always yield exactly one value ("" when absent) —
  # `capture`/`scan` yield an EMPTY STREAM on no-match under jq, and `crew_of as
  # $c` over an empty stream runs zero times, silently DROPPING that marker from
  # every tier → .[0] becomes null → the whole sweep selects nothing (verified: a
  # description-less marker vanished). `[ scan(re) ]` collects into an array so
  # .[0] // "" always produces one value.
  def crew_of: ([ (.description // "") | scan("(?:^|\n)branch:[ ]*crew/([^/ \n]+)/") ] | (.[0] // "") | if type == "array" then (.[0] // "") else . end);
  def prio_list: ($priority_authors | split(" ") | map(select(length>0)));
  def is_priority: (crew_of as $c | ($c != "" and ((prio_list | index($c)) != null))) or ((.labels // []) | any(. == "gate:priority"));
  # Tier order: priority-healthy (aged→newest), then other-healthy (aged→newest),
  # then rebase-fail (all authors, back of queue). Mirrors the aged/newest logic
  # inside each priority class so no invariant (aging bound, newest tiebreak) is lost.
  (map(select(is_priority and (has_rebase_fail | not) and is_aged))                 | sort_by(.created_at))
  + (map(select(is_priority and (has_rebase_fail | not) and (is_aged | not)))       | sort_by(.created_at) | reverse)
  + (map(select((is_priority | not) and (has_rebase_fail | not) and is_aged))       | sort_by(.created_at))
  + (map(select((is_priority | not) and (has_rebase_fail | not) and (is_aged | not))) | sort_by(.created_at) | reverse)
  + (map(select(has_rebase_fail))                                                   | sort_by(.created_at) | reverse)
  | .[0]')
MARKER_ID=$(printf '%s\n' "$MARKER" | jq -r '.id')
# SELFTEST-EXTRACT marker-select: END
DESC=$(printf '%s\n' "$MARKER" | jq -r '.description // ""')

log "Attempting to claim marker $MARKER_ID ..."

# ── Step 1: Atomic claim — transition queued → dispatching ───────────────────
# Remove queued label first. If another dispatcher process beat us, the re-fetch
# will show the marker no longer in queued state.

bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:queued" -q 2>/dev/null || true

# Re-fetch to verify we won the race
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null || echo "[]")
VERIFY_LABELS=$(echo "$VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$VERIFY_LABELS" | grep -q "gate-status:dispatching"; then
  log "Marker $MARKER_ID already dispatching by another process. Skipping."
  exit 0
fi
if echo "$VERIFY_LABELS" | grep -q "gate-status:queued"; then
  log "Marker $MARKER_ID still queued after removal (race condition). Skipping."
  exit 0
fi

# We own it — add dispatching label
bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || {
  err "Failed to add gate-status:dispatching to $MARKER_ID. Aborting."
  exit 1
}

log "Marker $MARKER_ID claimed for dispatching."

# ── Step 2: Extract fields from marker description ────────────────────────────

# ga-eqjo: extract() itself is now hoisted (before Phase C) so Phase C can
# reuse it to parse a run bead's persisted description the same way this step
# parses a marker's. See the hoisted block for the ga-7zjs1 rationale comment.
BRANCH=$(extract "branch")
BEAD_ID=$(extract "bead_id")
BASE_COMMIT=$(extract "base_commit")
RIG=$(extract "rig")
# ga-6dp9: self-declared author line, mirroring guard.sh's MARKER_AUTHOR. Used
# ONLY as a last-mile candidate for the rebase-liveness check (resolve_rebase_author
# below) — NEVER for self-review-exclusion (that AUTHOR derivation, below, keeps
# its existing untrusted-marker-text posture unchanged).
MARKER_AUTHOR=$(extract "author")

# ga-9oxah: format-tolerant fallback — a marker submitted OUTSIDE /gate-done's
# canonical description-writer (e.g. oracle-wa's shape: routing in LABELS —
# branch:<val>, source-bead:<val>, bead-rig:<val> — with a human-prose
# description) has no description routing block at all, so the extract()
# calls above resolve empty. Pre-fix this errored (unresolvable rig),
# gate-recovery-watchdog re-queued it, and it churned indefinitely,
# head-of-line-blocking the whole gate. extract() itself stays
# description-only and untouched (it's hoisted and reused by Phase C above
# to parse a persisted run-bead description that has no comparable label
# convention) — this fallback lives here, at the call site, mirroring the
# existing Phase C title-recovery fallback (ga-eqjo) elsewhere in this file.
# Strictly additive: only fires per-field when that field's description-based
# extract() found nothing, so a canonical marker (routing already in the
# description) is completely unaffected.
# SELFTEST-EXTRACT label-fallback: BEGIN
if [ -z "$BRANCH" ] || [ -z "$BEAD_ID" ] || [ -z "$RIG" ]; then
  MARKER_LABEL_LIST=$(printf '%s\n' "$MARKER" | jq -r '(.labels // [])[]' 2>/dev/null || true)
  label_fallback() {
    # $1=label prefix incl. trailing colon (e.g. "branch:") — first matching
    # label, prefix stripped. Colon anchors the boundary so "source-bead:"
    # never matches an unrelated "source-bead-type:" label. `|| true`
    # mirrors extract()'s own terminator (ga-7zjs1): under this script's
    # set -euo pipefail, a plain no-match grep exits 1 and pipefail
    # propagates it, aborting the WHOLE dispatcher on the very first marker
    # whose labels don't happen to carry this particular prefix — the same
    # class of bug this fix exists to clean up, not reintroduce one field over.
    printf '%s\n' "$MARKER_LABEL_LIST" | grep -E "^$1" | head -1 | sed "s/^$1//" || true
  }
  if [ -z "$BRANCH" ]; then
    LBL_VAL=$(label_fallback "branch:")
    if [ -n "$LBL_VAL" ]; then BRANCH="$LBL_VAL"; log "  branch: description had none — resolved from label 'branch:$LBL_VAL'."; fi
  fi
  if [ -z "$BEAD_ID" ]; then
    LBL_VAL=$(label_fallback "source-bead:")
    if [ -n "$LBL_VAL" ]; then BEAD_ID="$LBL_VAL"; log "  bead_id: description had none — resolved from label 'source-bead:$LBL_VAL'."; fi
  fi
  if [ -z "$RIG" ]; then
    LBL_VAL=$(label_fallback "bead-rig:")
    if [ -n "$LBL_VAL" ]; then RIG="$LBL_VAL"; log "  rig: description had none — resolved from label 'bead-rig:$LBL_VAL'."; fi
  fi
fi
# SELFTEST-EXTRACT label-fallback: END

log "  branch=$BRANCH  bead_id=$BEAD_ID  rig=${RIG:-unknown}"

# ── Step 2b: Schema-drift diagnostic for hand-created markers (ga-kefn) ──────
# /gate-done's canonical writer (commands/gate-done.md Step 3) always emits
# branch:/bead_id:/author:/base_commit:/rig:/bead_rig: — but a marker
# hand-created OUTSIDE that flow (e.g. the Mayor re-submitting after a gate
# infra failure) has zero schema enforcement. ga-wisp-5zki27 used `bead:`
# instead of `bead_id:` and omitted `rig:`/`bead_rig:` entirely; BEAD_ID/RIG
# above resolved empty with no signal why, and Step 4's eventual abort
# ("Cannot resolve rig path for rig='' (bead=)") reads like a rig-registry
# problem — nothing pointed at the real defect. Diagnosing it required
# reading dispatcher source and cross-referencing raw log timestamps over
# ~2 hours, while 3 separate dispatches landed on the already-complete fix
# and could only stand down.
#
# Deliberately NOT alias-acceptance (ga-kefn's "(c) is lowest-leverage" —
# silently accepting one typo just leaves the next hand-typed marker's novel
# typo equally silent). This only names a REAL near-miss line for a field
# that came back empty, so it never fires on crew markers that legitimately
# omit `rig:` by design (ga-7zjs1 above) — only when a plausible-but-wrong
# line is actually present in the description.
# SELFTEST-EXTRACT near-miss-diagnostic: BEGIN
warn_near_miss_field() {
  # $1=canonical field  $2=already-resolved value  $3..=known near-miss aliases
  local canonical="$1" resolved="$2"; shift 2
  [ -n "$resolved" ] && return 0
  local alias line
  for alias in "$@"; do
    line=$(printf '%s\n' "$DESC" | grep -E "^${alias}:" | head -1 || true)
    if [ -n "$line" ]; then
      log "  WARNING: '${canonical}:' is empty but description has near-miss line '${line}' — likely a hand-created marker (outside /gate-done) using a non-canonical field name. See ga-kefn."
      return 0
    fi
  done
  return 0
}
warn_near_miss_field "bead_id" "$BEAD_ID" bead beadid bead-id issue issue_id
warn_near_miss_field "rig"     "$RIG"     bead_rig rig_name rigname target_rig
# SELFTEST-EXTRACT near-miss-diagnostic: END

# ── Step 3: Re-derive author authoritatively (never trust marker self-declaration)
#
# Resolution order (most-to-least authoritative):
#   0. gate.submitted_by metadata already recorded on THIS marker by the guard
#      at parking time (ga-tkvsa — see below).
#   1. Look up the bead via "gc bd show" (cross-rig lookup — works for any rig DB).
#   2. Try HQ DB directly as a fallback (in case gc bd fails).
#   3. If assignee is a session-id (contains "adhoc"), map it back to the base
#      crew role by stripping the adhoc suffix (e.g. "digo-wa-adhoc-e2510107f6" → "digo-wa").
#
# SECURITY: We do NOT trust the marker's self-declared author (the `author:`
# line in its description). The resolved value is used solely for self-review
# exclusion. A partial/approximate match is safe here: it only prevents a
# reviewer from reviewing their own work; it doesn't grant access.

AUTHOR=""

# ga-tkvsa (fixes ga-w5agg): prefer the author the guard already resolved
# authoritatively at submit time (quality-gate-guard.sh Step 7 records it as
# gate.submitted_by metadata on the marker, via --set-metadata — overwrite
# semantics, so a worker cannot forge this by pre-seeding it at marker-creation
# time; the guard's write at parking time is always final). Re-deriving from the
# source bead's assignee/created_by/owner below is a TOCTOU race: the guard's own
# Step 5 (dog-pool detach, ga-e7zk7) clears the bead's assignee in the SAME run
# that resolves AUTHOR, and created_by/owner are never populated on
# programmatically-created sling beads either — so by the time this sweep runs
# (seconds to minutes later, typically after the submitting dog has closed+exited
# per dog doctrine), every dog-submitted marker for a fix/* branch hit the
# fail-safe below and dead-ended at gate-status:deferred, which nothing ever
# re-reads. $VERIFY_JSON was already fetched above (Step 1 claim-verification) —
# reuse it rather than re-fetching.
AUTHOR=$(printf '%s\n' "$VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | .metadata["gate.submitted_by"] // empty' 2>/dev/null || true)
if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
  log "  Author recorded on marker by guard at submit time: $AUTHOR (trusted, ga-tkvsa; skipping bead re-derivation)"
else
  AUTHOR=""
fi
# ga-6dp9: snapshot the trusted-metadata result BEFORE the bead-derived
# fallback below (over)writes AUTHOR. resolve_rebase_author() needs to know
# whether AUTHOR came from the branch-submission event (trustworthy for
# rebase-liveness) or is about to fall through to the bead's current
# assignee/owner (NOT trustworthy for that purpose — see resolve_rebase_author).
AUTHOR_TRUSTED_SUBMIT="$AUTHOR"

# ga-pyzo: also read the durable agent alias the guard recorded alongside
# gate.submitted_by (best-effort; empty for markers submitted before this fix,
# or when the guard's own live-session lookup at submit time missed). Used
# ONLY as a liveness FALLBACK further below when AUTHOR's specifically
# recorded session has since recycled — never overrides AUTHOR itself here at
# derivation time (SECURITY: gate.submitted_by remains the sole trusted
# self-review-exclusion identity — see the ga-tkvsa header above).
AUTHOR_AGENT=$(printf '%s\n' "$VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | .metadata["gate.submitted_by_agent"] // empty' 2>/dev/null || true)
[ "$AUTHOR_AGENT" = "null" ] && AUTHOR_AGENT=""

# bead_field_grep <raw_json_text> <field_name>
# Extracts a simple string field from potentially-malformed JSON output.
# Uses grep/sed instead of jq because gc bd output may contain literal newlines
# embedded in string values (invalid JSON per RFC7159) that cause jq 1.8.1+ to fail.
bead_field_grep() {
  local raw="$1" field="$2"
  # The || true prevents pipefail from aborting when grep finds no match (exits 1).
  echo "$raw" | grep -o "\"${field}\": *\"[^\"]*\"" \
    | sed "s/\"${field}\": *\"\(.*\)\"/\1/" \
    | head -1 || true
}

# ga-tkvsa: only re-derive from the (possibly by-now-cleared) source bead when
# the trusted marker-recorded value above didn't already resolve AUTHOR.
if [ -z "$AUTHOR" ] && [ -n "$BEAD_ID" ]; then
  # 1. Cross-rig lookup via gc bd (authoritative — queries the owning rig's DB).
  #    This handles beads in rig DBs (e.g. wa-*, ps-*) that are NOT in the HQ DB.
  # ga-07509: on failure BEAD_RAW stays "" exactly as before — the fallback-
  # to-HQ-DB guard right below already treats empty as "try the other
  # lookup", correct whether gc failed OR the bead genuinely wasn't found
  # there; only the failure DETECTION changes.
  BEAD_RAW=$(gc_json_or_unknown gc --city "$GC_CITY" bd show "$BEAD_ID" --json) || true

  # If cross-rig lookup returned nothing, fall back to HQ DB
  if [ -z "$BEAD_RAW" ]; then
    log "  gc bd cross-rig lookup returned empty; trying HQ DB directly."
    # ga-h199q: routed through the read-cache shim (the bd-native fallback leg
    # only — the cross-rig `gc bd show` leg above uses a different binary/argv
    # shape the shim's `bd -C <verb>` contract doesn't cover, so it stays direct).
    BEAD_RAW=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null || echo "")
  fi

  # Extract fields using grep (robust to embedded-newline JSON from gc bd)
  AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "created_by")
  fi
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "owner")
  fi
fi

# 3. Session-id normalization: if assignee looks like an adhoc session-id
#    (e.g. "digo-adhoc-e2510107f6"), strip the adhoc suffix to get the crew role.
#    We keep the FULL id as the exclusion target AND the normalized role — a
#    reviewer session matches if its alias contains either form.
if [ -n "$AUTHOR" ] && echo "$AUTHOR" | grep -qE "-adhoc-[0-9a-f]+" 2>/dev/null; then
  AUTHOR_BASE=$(echo "$AUTHOR" | sed 's/-adhoc-[0-9a-f]*$//')
  log "  Author '$AUTHOR' looks like a session-id; normalized to base role '$AUTHOR_BASE'."
  AUTHOR="$AUTHOR_BASE"
fi
# wa-worker FAIL normalizer (pilot-rewire): a wa-worker build uses an ephemeral session
# (wa-worker or wa-worker-<sid>) that has already drained by FAIL time.
# Route FAIL to the Mayor so the human always gets a signal, never a dead-session nudge.
if [ -n "$AUTHOR" ] && echo "$AUTHOR" | grep -qE "^wa-worker" 2>/dev/null; then
  log "  Author '$AUTHOR' is a wa-worker ephemeral session — routing FAIL nudge to Mayor (the human signal)"
  AUTHOR="mayor"
fi

# Ephemeral-pool fallback (pilot-rewire): a worker-built bead (branch crew/wa-worker/<id>)
# has assignee cleared/null by dispatch time and no created_by/owner — so AUTHOR is empty
# here even though the work is real and merge-ready. Route its author to the Mayor (the
# human signal) instead of deferring forever. Without this, every worker-built bead defers
# permanently at the fail-safe below (observed: wa-14w76/wa-oly1 stuck gate-status:deferred).
if { [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; } && echo "$BRANCH" | grep -qE "^crew/wa-worker/" 2>/dev/null; then
  log "  Author unresolved but branch '$BRANCH' is an ephemeral wa-worker build — routing author to Mayor."
  AUTHOR="mayor"
fi

# SELFTEST-EXTRACT gate-author-final-fallback: BEGIN
# ga-tmkjg: generic crew-branch fallback. gate.submitted_by can be blanked by a
# raw `bd update` outside this dispatcher (bd-update-blanks-gc-metadata) and,
# independently, a reclaim/janitor (lifecycle R4) can clear the source bead's
# own assignee — so BOTH resolution paths above can legitimately go empty for
# real, in-flight work, not only for the wa-worker case already handled.
# Observed: 12 markers stuck ~2h with zero gate-runs (this bead). The branch
# name is the one signal that cannot go missing: crew/<name>/<bead-id> is the
# reason the marker exists at all, so <name> is always recoverable here even
# when every bead-side field has been wiped. Mirrors resolve_rebase_author's
# own crew-from-branch sed (this file) but stops there — unlike that function,
# does NOT fall through to the marker's self-declared `author:` line, per the
# SECURITY note at the top of this section (self-declared author must stay
# untrusted for self-review-exclusion; resolve_rebase_author's marker_author
# tier is safe only for its own lower-stakes liveness-check purpose).
if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
  _CREW_FROM_BRANCH=$(printf '%s' "$BRANCH" | sed -n 's#^crew/\([^/]\{1,\}\)/.*#\1#p')
  if [ -n "$_CREW_FROM_BRANCH" ]; then
    log "  Author unresolved (gate.submitted_by and bead assignee/created_by/owner all empty) but branch '$BRANCH' names crew '$_CREW_FROM_BRANCH' — using branch fallback instead of aborting."
    AUTHOR="$_CREW_FROM_BRANCH"
  fi
fi

if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
  err "Cannot derive author authoritatively for bead $BEAD_ID — aborting (fail-safe)."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred"    -q 2>/dev/null || true
  # wa-uthi: non-terminal (deferred) — no push to Athos. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): author unresolvable for $MARKER_ID — deferred."
  # ga-tmkjg: a silently-deferred marker re-enters the SAME oldest-first queue
  # position next sweep (gate-recovery-watchdog's grw-defer-requeue) and fails
  # identically every time — an author-unresolvable marker cannot become
  # resolvable between sweeps on its own — so it head-of-line-blocks every
  # OTHER queued marker behind it, with zero gate-runs and no signal anything
  # is wrong (this bead: 12 markers, ~2h, zero throughput, found only because
  # Athos noticed the review queue looked empty). Mail Mayor so a human sees
  # it THIS sweep, not N hours from now.
  gc --city "$GC_CITY" mail send mayor \
    -s "Gate: marker $MARKER_ID has no derivable author (bead ${BEAD_ID:-unknown})" \
    -m "Marker $MARKER_ID (bead ${BEAD_ID:-unknown}, branch ${BRANCH:-unknown}, rig ${RIG:-unknown}) has no derivable author: gate.submitted_by is empty, the source bead's assignee/created_by/owner are all empty, and branch '${BRANCH:-unknown}' is not a crew/<name>/* branch so no name could be recovered from it either. Deferred (gate-status:deferred) rather than left dispatching, but it will fail identically on every future sweep and head-of-line-blocks the rest of the queue until someone intervenes (ga-tmkjg). Fix: set gate.submitted_by on the marker, or restore the source bead's assignee — either lets it re-dispatch on the next sweep." 2>/dev/null \
    || warn "Could not mail Mayor for authorless marker $MARKER_ID"
  exit 0
fi
# SELFTEST-EXTRACT gate-author-final-fallback: END

log "Authoritative author: $AUTHOR"

# ── Step 4: Determine rig path and git references ─────────────────────────────
# SELFTEST-EXTRACT rig-path-resolve: BEGIN
# ga-eqjo: rig/BEAD_CITY/DEFAULT_BRANCH resolution itself now lives in
# gate_resolve_rig_context() (hoisted above, before Phase C) so Phase C can
# call the exact same logic for a run claimed by an EARLIER sweep. Only the
# claim-time-only work (fetch, shallow-preflight, verify the branch still
# exists on origin) stays inline here.
#
# ga-dmox: a marker whose rig:/bead_id: fields don't resolve to any registered
# rig is a MALFORMED-DATA problem local to this one marker, not a dispatcher
# infrastructure failure. Mark it (label + comment, so a human/watchdog reading
# the bead sees exactly what's missing) and exit 0 — matching Step 3's
# established "cannot derive X -> mark terminal, exit 0" convention 30 lines
# above. exit 1 here previously poisoned daemon-presence-watchdog's per-daemon
# exit-code FAILING counter (scripts/daemon-presence-watchdog.sh) over a single
# bad marker, making a one-item data problem look like a dispatcher outage.
# (gate_resolve_rig_context() already logged the specific "cannot resolve"
# reason via its own err call before returning 1 — no need to repeat it here.)
if ! gate_resolve_rig_context; then
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$MARKER_ID" "ga-dmox: rig path unresolved for rig='${RIG:-<empty>}' bead_id='${BEAD_ID:-<empty>}' — marker's branch:/bead_id:/rig: fields did not resolve to any registered rig via exact name, bead-id prefix, or trailing-segment match. Marker skipped (gate-status:error); other queued markers are unaffected. Resubmit via /gate-done with a corrected bead_id:/rig: field, or fix by hand and re-queue." 2>/dev/null || true
  log "SUPPRESSED PUSH (ga-dmox non-terminal): rig path unresolvable for $MARKER_ID — gate-status:error (skipped, not a daemon failure)."
  exit 0
fi
# SELFTEST-EXTRACT rig-path-resolve: END

# Fetch to ensure we have the latest remote state
log "Fetching remote for rig $RIG ..."
git_rig fetch origin 2>/dev/null || warn "git fetch failed (continuing with stale refs)"

# ── ga-ymbv: shallow-clone preflight ──────────────────────────────────────────
# A SHALLOW rig checkout can make every ancestry-walking command below
# (merge-base, merge-base --is-ancestor, merge-tree) misreport two related
# branches as having no common ancestor — not because the branches are
# genuinely unrelated, but because their shared history sits past the shallow
# fetch boundary. Verified empirically on this exact checkout (ga-ymbv): a
# branch's root commit had a real parent per `git cat-file -p`, invisible to
# `git log --parents` because of the shallow boundary; `git merge-base` came
# back empty until `git fetch origin --unshallow` was run, after which it
# resolved correctly for every branch against the current fetch boundary, not
# just the one that surfaced the bug. Fixing it ONCE here, before any
# downstream ancestry check runs, is cheaper and more robust than patching
# each of the dozen+ merge-base/merge-tree call sites below individually.
#
# `rev-parse --is-shallow-repository` is O(1) (checks for a `.git/shallow`
# marker file), so this is a cheap no-op on an already-full clone.
# `fetch --unshallow` is local-only and non-destructive; a failure (e.g. a
# transient network hiccup) is non-fatal — downstream ancestry checks simply
# fall back to the pre-existing gate-status:error retry path, same as before
# this fix.
if [ "$(git_rig rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  log "  Rig checkout ($GIT_DIR_PATH) is a shallow clone — running git fetch --unshallow so merge-base/merge-tree see full history (ga-ymbv)."
  if git_rig fetch origin --unshallow >/dev/null 2>&1; then
    log "  unshallow OK."
  else
    warn "  unshallow FAILED (non-fatal) — ancestry checks may still misreport merge-base=none for branches rooted past the fetch boundary."
  fi
fi

# Verify branch exists on remote (ga-ljbx: hardened — a ref pointing at a missing
# object yields EMPTY here, so we fail to gate-status:error, never proceed on garbage)
BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH")
if [ -z "$BRANCH_SHA" ]; then
  err "Branch '$BRANCH' not found on remote origin (or ref points at a missing object). Aborting."

  # ga-tgwq: "absent from origin" conflates "doesn't exist anywhere" with
  # "exists locally, session died before push" — two states with opposite
  # remedies. Probe local git state BEFORE concluding the work is gone; see
  # gate_no_branch_probe_local()/gate_no_branch_local_classify() above.
  read -r _NB_REF_EXISTS _NB_WT_DIRTY <<<"$(gate_no_branch_probe_local "$BRANCH")"
  _NB_CLASS=$(gate_no_branch_local_classify "$_NB_REF_EXISTS" "$_NB_WT_DIRTY")

  if [ "$_NB_CLASS" = "rescuable" ]; then
    _NB_LOCAL_SHA=$(rig_resolve_commit "refs/heads/$BRANCH")
    err "  ga-tgwq: branch $BRANCH absent from origin but exists LOCALLY at $_NB_LOCAL_SHA with a clean worktree — looks like a session died between commit and push. NOT circuit-breaking; flagging as rescuable."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$MARKER_ID" "ga-tgwq: branch '$BRANCH' is absent from origin, but a local ref exists at $_NB_LOCAL_SHA with a clean worktree — reads as a session that died between commit and push, not missing work. Rescue: \`git -C $GIT_DIR_PATH push -u origin $BRANCH\` (verify after with \`git ls-remote origin $BRANCH\`). Marker left at gate-status:error (retriable) — NOT circuit-broken: this is a push away, not a human re-anchor decision." 2>/dev/null || true
    if [ -n "$BEAD_ID" ]; then
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-tgwq: gate found branch '$BRANCH' absent from origin but present locally (committed, clean) at $_NB_LOCAL_SHA — likely the session died between commit and push. Rescue: \`git -C $GIT_DIR_PATH push -u origin $BRANCH\`. Bead left as-is (no gate:needs-human, assignee untouched) — this is a 3-second push, not a re-anchor decision." 2>/dev/null || true
    fi
    gc --city "$GC_CITY" mail send mayor \
      -s "Gate: $BRANCH absent from origin but rescuable (${BEAD_ID:-unknown})" \
      -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) is absent from origin but exists locally at $_NB_LOCAL_SHA with a CLEAN worktree — looks like the owning session died between commit and push. Rescue command: git -C $GIT_DIR_PATH push -u origin $BRANCH. NOT circuit-broken (ga-tgwq): this is a push away, not a human re-anchor decision." 2>/dev/null \
      || warn "Could not mail Mayor for rescuable branch $BRANCH"
    log "ga-tgwq: branch $BRANCH absent from origin but locally rescuable at $_NB_LOCAL_SHA — marker $MARKER_ID left at gate-status:error (retriable), bead $BEAD_ID untouched."
    exit 0
  elif [ "$_NB_CLASS" = "escalate" ]; then
    err "  ga-tgwq: branch $BRANCH absent from origin; local worktree has UNCOMMITTED changes — session likely died mid-edit. Escalating, not circuit-breaking or pushing."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$MARKER_ID" "ga-tgwq: branch '$BRANCH' is absent from origin; a local ref exists but its worktree has UNCOMMITTED changes — the owning session likely died mid-edit. NOT circuit-broken, NOT auto-pushed (would silently strand the uncommitted diff). Human or Mayor must inspect the local worktree and decide: commit+push, or discard." 2>/dev/null || true
    if [ -n "$BEAD_ID" ]; then
      # ga-tgwq: same needs-human + Pilot-lane-free convention as the true
      # park path below — safe to mirror here because gate:needs-human is
      # what actually blocks Pilot re-dispatch of THIS bead (per the park
      # path's own comment); clearing story:in-flight/pilot:dispatched/
      # assignee is just stale-tracking hygiene once that label is set, not
      # what does the blocking. Deliberately NOT done in the "rescuable"
      # branch above, which has no gate:needs-human — clearing pilot:dispatched
      # there would let Pilot re-dispatch a fresh builder while the
      # almost-done branch just sits unpushed.
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"  -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"   -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""                 -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-tgwq: gate found branch '$BRANCH' absent from origin with UNCOMMITTED changes in a local worktree — the session likely died mid-edit. Set gate:needs-human: a human or Mayor must inspect the pending diff before deciding whether to commit+push or discard. story:in-flight + pilot:dispatched stripped (Pilot lane slot freed)." 2>/dev/null || true
    fi
    gc --city "$GC_CITY" mail send mayor \
      -s "Gate: $BRANCH absent from origin, uncommitted local work (${BEAD_ID:-unknown})" \
      -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) is absent from origin; its local worktree has UNCOMMITTED changes — looks like the session died mid-edit. NOT auto-pushed (ga-tgwq): could silently strand the pending diff. Please inspect and decide: commit+push, or discard." 2>/dev/null \
      || warn "Could not mail Mayor for dirty-local branch $BRANCH"
    # ga-y43lq/ga-u4yi: durable mail to the AUTHOR too, not just Mayor — this
    # site sets gate:needs-human above (line ~4480) but, unlike every other
    # gate:needs-human site in this file (the park/ga-acb path below, plus
    # ahead_dead/behind_dead/retry_dead), it never told the author their own
    # branch needed attention — they'd only find out from a Mayor-only mail
    # or by noticing the bead went quiet. Same convention as those sites.
    if [ -n "$AUTHOR" ]; then
      gc --city "$GC_CITY" mail send "$AUTHOR" \
        -s "Gate needs-human: $BRANCH has uncommitted local work ($BEAD_ID)" \
        -m "Your branch $BRANCH (bead $BEAD_ID) is absent from origin, and its local worktree has UNCOMMITTED changes — looks like your session died mid-edit. Source bead $BEAD_ID is now labeled gate:needs-human: the Pilot will NOT re-dispatch it, and any further /gate-done resubmission for this bead will be silently parked until a human resolves this. Please inspect the local worktree and decide: commit+push, or discard, before resubmitting." \
        2>/dev/null || warn "Could not mail author $AUTHOR for dirty-local branch $BRANCH"
    fi
    log "ga-tgwq: branch $BRANCH absent from origin with dirty local worktree — marker $MARKER_ID at gate-status:error, bead $BEAD_ID set needs-human, Mayor + author mailed."
    exit 0
  fi
  # _NB_CLASS = "park": no local ref either — falls through to the original
  # ga-acb circuit-break below, unchanged.

  # ga-acb: branch absent on origin is PROVABLY un-mergeable — circuit-break immediately.
  _ACB=$(gate_circuit_break_check "no_branch" "" "0" "0" "3" "10")
  if [ "$_ACB" != "ok" ]; then
    err "  ga-acb: circuit-breaking marker $MARKER_ID (${_ACB}) — branch $BRANCH is GONE from origin."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$MARKER_ID" "ga-acb AUTO-CIRCUIT-BREAK (${_ACB}): branch '$BRANCH' is absent from origin. No reviewer can ever merge a non-existent branch. Marker permanently parked at gate-status:error. Source bead $BEAD_ID set gate:needs-human so the guard does NOT recreate a marker." 2>/dev/null || true
    if [ -n "$BEAD_ID" ]; then
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human"           -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human:technical" -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"            -q 2>/dev/null || true
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"             -q 2>/dev/null || true  # wa-qq33j
      bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"           -q 2>/dev/null || true
      bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""                           -q 2>/dev/null || true
      bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-acb AUTO-CIRCUIT-BREAK: branch '$BRANCH' is absent from origin (marker $MARKER_ID). Gate cannot review or merge a non-existent branch. Set gate:needs-human — human or Mayor must re-anchor the work. story:in-flight + pilot:dispatched stripped (Pilot lane slot freed). gate:reviewing cleared (wa-qq33j)." 2>/dev/null || true
    fi
    gc --city "$GC_CITY" mail send mayor \
      -s "Gate circuit-break: $BRANCH absent from origin (${BEAD_ID:-unknown})" \
      -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) is ABSENT from origin — gate cannot review or merge it. Auto-circuit-broken (ga-acb): marker permanently parked at gate-status:error; source bead set gate:needs-human. Human or Mayor decision required: re-push the branch or close the bead." 2>/dev/null \
      || warn "Could not mail Mayor for circuit-break on $BRANCH"
    # ga-u4yi: mail the AUTHOR too, not just the Mayor — a bd comment alone left
    # thies-wa's branch rotting 20h in silence because nothing durable told her
    # she was stuck. Mail (not nudge) survives a dead/restarted author session.
    if [ -n "$AUTHOR" ]; then
      gc --city "$GC_CITY" mail send "$AUTHOR" \
        -s "Gate needs-human: your branch $BRANCH is gone from origin ($BEAD_ID)" \
        -m "Your branch $BRANCH (bead $BEAD_ID) is ABSENT from origin — the gate cannot review or merge a branch that doesn't exist on the remote. Source bead $BEAD_ID is now labeled gate:needs-human: the Pilot will NOT re-dispatch it, and any further /gate-done resubmission for this bead will be silently parked until a human resolves this. Re-push the branch (or ask the Mayor to re-anchor the work) before resubmitting." \
        2>/dev/null || warn "Could not mail author $AUTHOR for circuit-break on $BRANCH"
    fi
    log "ga-acb circuit-break: branch $BRANCH absent from origin — marker $MARKER_ID parked, bead $BEAD_ID needs-human."
    # ga-dmox: marker is already fully parked (labels, comments, mail to Mayor +
    # author all sent above) — exit 0, not 1. This case is a deliberately-handled
    # terminal outcome for ONE marker, not a dispatcher process failure; exit 1
    # here poisoned daemon-presence-watchdog's exit-code FAILING counter.
    exit 0
  fi
  # GATE_AUTO_CIRCUIT_BREAK=0: fall through to legacy gate-status:error (retriable).
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  # wa-uthi: non-terminal (marker error, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH not found on remote — gate-status:error."
  # ga-dmox: retriable per-marker state (comment above says so) must not exit 1.
  exit 0
fi

log "  branch_sha=$BRANCH_SHA"
# ── Step 4b: Already-merged detection ────────────────────────────────────────
# If the branch tip is already an ancestor of the rig's default branch, the
# work has already been merged.  Re-spawning reviewers on merged work wastes
# sessions and produces duplicate gate-failed/passed noise.
# DETECT: if merge-base --is-ancestor origin/$BRANCH origin/$DEFAULT_BRANCH → true
# → mark marker gate-status:done/superseded and exit cleanly.
#
# ga-01yq: the is-ancestor check alone is FALSE BY CONSTRUCTION after a
# rebase-merge (new shas on main) even when the branch's content is 100%
# merged. Before concluding "not merged" (and falling into Step 4c below,
# which can bounce to needs-rebase and invite a dangerous "merge main + push"
# re-submission of pre-rebase files), fall back to the patch-id content check.

ALREADY_MERGED=0
MERGED_BY_REBASE=0
if git_rig merge-base --is-ancestor "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
  ALREADY_MERGED=1
elif rig_content_merged "origin/$DEFAULT_BRANCH" "origin/$BRANCH"; then
  ALREADY_MERGED=1
  MERGED_BY_REBASE=1
fi

if [ "$ALREADY_MERGED" = "1" ]; then
  if [ "$MERGED_BY_REBASE" = "1" ]; then
    log "Branch $BRANCH is merged-by-rebase into $DEFAULT_BRANCH (not an ancestor by SHA, but 0 unmerged patches by content) — superseding marker $MARKER_ID (ga-01yq)."
    set_gate_status "$MARKER_ID" "superseded"
    bd -C "$GC_CITY" comment "$MARKER_ID" "Branch $BRANCH is merged-by-rebase into $DEFAULT_BRANCH: not a SHA ancestor (a rebase-merge replays commits under new shas) but every branch commit's patch is already present in main (git rev-list --cherry-pick --right-only == 0). Gate skipped — no reviewers needed, no rebase requested (ga-01yq)." 2>/dev/null || true
  else
    log "Branch $BRANCH is already merged into $DEFAULT_BRANCH — superseding marker $MARKER_ID."
    set_gate_status "$MARKER_ID" "superseded"
    bd -C "$GC_CITY" comment "$MARKER_ID" "Branch $BRANCH is already merged into $DEFAULT_BRANCH (SHA $BRANCH_SHA is ancestor of main). Gate skipped — no reviewers needed." 2>/dev/null || true
  fi
  # ga-jhyu: CLOSE the marker at terminal (superseded) so it is reaped, not left OPEN.
  bd -C "$GC_CITY" close "$MARKER_ID" -r "Gate marker terminal: SUPERSEDED (branch $BRANCH already merged to $DEFAULT_BRANCH). Closed by dispatcher (ga-jhyu)." 2>/dev/null || true

  # Drive the source bead to its terminal/handoff state if open.
  if [ -n "$BEAD_ID" ]; then
    # SELFTEST-EXTRACT already-merged-source-bead-cleanup-fn: BEGIN
    # ga-i5s5: `|| true` used to mask a failed `bd show` as BD_STATUS="",
    # which `!= closed` then reads as "not yet closed" — the exact same
    # error/empty conflation ga-s07s closed at the verdict-bead sites,
    # applied here to the SOURCE bead. Consequence here is lower severity
    # (the already-merged FACT is established independently by the earlier
    # git merge-base/patch-id check, not by this read; a false "not closed"
    # only re-runs the idempotent label/comment/close cascade below — the
    # close call already has a `|| warn ... non-fatal` fallback), but an
    # unreadable status must still not silently pass as "open". Reuse
    # vb_status_action() (root-class:error-vs-empty) for the same
    # unknown/skip/requeue split the verdict-bead sites use.
    # NOTE deliberately NOT routed through bd-list-cached.sh (ga-h199q):
    # this whole block is verbatim-extracted by SELFTEST-EXTRACT and run in
    # a sandbox that stubs a `bd` shell function only — a shim call shells
    # out to a separate script the stub cannot intercept, which silently
    # made every scenario (including genuinely-open) read as unreadable.
    # Also matches the shim's own documented caveat: not safe, without a
    # confirming resample, for a call site that itself decides to close/
    # supersede/requeue a bead from the result — exactly this site.
    if BD_JSON=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null); then
      BD_STATUS=$(printf '%s' "$BD_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
    else
      BD_STATUS="__UNKNOWN__"
    fi
    case "$(vb_status_action "$BD_STATUS")" in
      unknown)
        log "  Source bead $BEAD_ID status unreadable this sweep (bd show failed — transient Dolt hiccup?) — skipping already-merged cleanup this run rather than assuming open (root-class:error-vs-empty, ga-i5s5)."
        ;;
      skip) : ;;
      requeue)
        # ga-i53ua: route a STORY already-merged through the SAME delivery completion
        # as the PASS path — do NOT just mark gate:superseded and leave it OPEN at
        # story:approved (the old behavior delivered NOTHING: no story:done, no
        # story:approved removal, no delivery-close → the executed story stranded in
        # the painel "Aprovadas" column forever, exactly the M1 mechanism this bead
        # tracks). Detect a story by its canonical label story:approved (type is null
        # for stories in bd; mirrors the PASS path's IS_STORY logic at ga-esbg).
        SUPERSEDE_SRC_LABELS=$(bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
          | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "")
        SUPERSEDE_IS_STORY=0
        if printf '%s' "$SUPERSEDE_SRC_LABELS" | grep -q "story:approved"; then SUPERSEDE_IS_STORY=1; fi

        # ga-67hae PILOT-CASCADE FIX: branch already merged → strip story:in-flight so
        # the Pilot lane slot frees. The PASS path strips it at merge (ga-3h8l) but this
        # supersede path did not — phantom in-flight slots wedged the Pilot at capacity.
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" assign "$BEAD_ID" "" -q 2>/dev/null || true

        if [ "$SUPERSEDE_IS_STORY" = "1" ]; then
          # STORY → hand off to story-delivery exactly like the PASS path: set
          # gate:passed (story-delivery's pickup signal), keep it OPEN with
          # story:approved, and let delivery run deploy→prod-test→story:done+close
          # (the durable terminal — story:approved removed + delivery close_reason →
          # painel Done — lives in story-delivery, ga-i53ua Fix A). We do NOT mark
          # gate:superseded on a story: that label is a non-delivery word the painel
          # would mis-route, and superseded is not the story's outcome (it WAS merged).
          bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
          bd -C "$BEAD_CITY" comment "$BEAD_ID" "Branch $BRANCH already in $DEFAULT_BRANCH — gate skipped (marker $MARKER_ID superseded), but this is a STORY: handed off to story-delivery (gate:passed set; story:approved kept; story:in-flight stripped; builder assignee cleared). Delivery will deploy + prod-test, then mark story:done and CLOSE with a delivery reason so it reaches painel Done (ga-i53ua)." 2>/dev/null || true
          log "Already-merged STORY $BEAD_ID handed off to delivery (gate:passed set; story:approved kept for delivery pickup)."
        else
          # BUG/TASK → superseded close-direct (unchanged behavior). Non-story beads
          # do NOT route through story-delivery; they close terminal here.
          bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:superseded" -q 2>/dev/null || true
          bd -C "$BEAD_CITY" comment "$BEAD_ID" "Branch $BRANCH already in $DEFAULT_BRANCH — gate superseded (marker $MARKER_ID). story:in-flight stripped (Pilot lane slot freed — ga-67hae pilot-cascade fix); work already merged." 2>/dev/null || true
          bd -C "$BEAD_CITY" close "$BEAD_ID" -r "Branch $BRANCH already merged to $RIG/$DEFAULT_BRANCH — delivered via prior merge; gate superseded (marker $MARKER_ID). Closed by dispatcher (ga-i53ua: non-story already-merged terminal)." 2>/dev/null \
            || warn "Could not close already-merged non-story source bead $BEAD_ID (non-fatal)."
        fi
        ;;
    esac
    # SELFTEST-EXTRACT already-merged-source-bead-cleanup-fn: END
  fi

  # Log and exit without error
  mkdir -p "$(dirname "$QG_LOG")"
  jq -c -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$BRANCH" \
    --arg bead "$BEAD_ID" \
    --arg rig "${RIG:-unknown}" \
    --arg marker "$MARKER_ID" \
    '{ts: $ts, event: "dispatcher_superseded", branch: $branch, bead: $bead, rig: $rig, marker: $marker, reason: "already_merged"}' \
    >> "$QG_LOG" 2>/dev/null || true

  # wa-uthi: non-terminal (marker superseded — no new outcome) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH already merged — gate marker superseded."
  log "=== Dispatcher sweep complete: branch=$BRANCH verdict=SUPERSEDED (already merged) ==="
  exit 0
fi

log "  Branch $BRANCH not yet merged into $DEFAULT_BRANCH — proceeding with review."

# ── Step 4b-1 (ga-991au round 2): live-sibling-run guard, HOISTED before any
# rebase/force-push ───────────────────────────────────────────────────────────
# Originally this check ran only at Step 5b, AFTER Step 4c's auto-rebase — which
# ends in `git push --force-with-lease` on THIS branch. A marker for a branch
# that already has a live gate-run would force-push it a SECOND time, rewriting
# the tip underneath reviewers still holding the old sha, and only THEN discover
# the sibling and yield. Checking here, before Step 4c ever touches the branch,
# closes that failure mode STRUCTURALLY: no force-push can precede a
# live-sibling discovery, for ANY marker, ANY round — including round 0 — so a
# same-branch sibling marker yields at this SAME early checkpoint every time,
# without ever touching the branch. (ga-991au round 1 tried a branch-level
# exclusion LIST instead of moving the check; see the retired-round note on
# gate_continue_or_exit() above for why that approach was abandoned.)
#
# Step 5b (below) keeps an IDENTICAL check as a safety net for the residual
# race window between this early check and actual review-spawn — a sibling run
# that starts during Step 4c's rebase or Step 5's tier classification is still
# caught before reviewers are spawned, just not before THIS marker's own
# rebase/force-push (a narrower, rarer window than the one this hoist closes).
if [ "${GATE_SIBLING_GUARD_ENABLED:-1}" = "1" ]; then
  SIBLING_VERDICT=$(live_sibling_run_for_branch "$BRANCH" || echo "")
  case "$SIBLING_VERDICT" in
    "LIVE "*)
      SIBLING_RUN_ID="${SIBLING_VERDICT#LIVE }"
      log "Live sibling gate-run $SIBLING_RUN_ID already running for branch $BRANCH — YIELDING before any rebase/force-push (one branch = one authoritative run). NOT spawning a duplicate."
      # Leave the marker in gate-status:dispatching (do NOT re-queue): re-queuing
      # would let this same (oldest) marker be re-selected every sweep and
      # head-of-line-block other branches. Step 0a re-queues it after its TTL if
      # the sibling never terminates, so the branch is never permanently stranded.
      # We touch NEITHER the source bead NOR any verdict, so the duplicate path can
      # never write a terminal FAIL over the healthy sibling. (Idempotent, fail-safe.)
      log "  Marker $MARKER_ID left dispatching; Step 0a TTL re-queues it once the sibling terminates."
      log "=== Dispatcher sweep complete: branch=$BRANCH verdict=YIELDED (live sibling $SIBLING_RUN_ID, pre-rebase) ==="
      # ga-991au: this branch is busy, but the other queued markers are not. Try
      # the next one in THIS sweep instead of burning the whole cadence on a
      # branch we already know we cannot touch. Safe to re-enter: our marker
      # stayed in gate-status:dispatching just above, and Step 0b only selects
      # gate-status:queued — so the next round cannot pick it again.
      gate_continue_or_exit "live-sibling-pre-rebase"
      ;;
    "STALE "*)
      SIBLING_RUN_ID="${SIBLING_VERDICT#STALE }"
      warn "Stale sibling gate-run $SIBLING_RUN_ID for branch $BRANCH (older than ${SIBLING_RUN_STALE_MINUTES}m — its dispatcher died mid-run and never drove it terminal). Superseding it and proceeding with a fresh run."
      set_gate_status "$SIBLING_RUN_ID" "superseded" 2>/dev/null || true
      bd -C "$GC_CITY" comment "$SIBLING_RUN_ID" "Dispatcher: superseded as STALE (> ${SIBLING_RUN_STALE_MINUTES}m — dispatcher died mid-run) so a fresh gate-run for branch $BRANCH can take over. (ga-dupnv live-sibling guard, pre-rebase check)" 2>/dev/null || true
      bd -C "$GC_CITY" close "$SIBLING_RUN_ID" -r "gate-run superseded (stale sibling) — fresh run for branch $BRANCH takes over. (ga-dupnv)" 2>/dev/null || true
      ;;
  esac
fi

# ── Step 4c: Stale-base check (Bug 1a) ───────────────────────────────────────
# Require that the branch be CURRENT with main before review starts.
# A branch is current iff main HEAD is an ancestor of the branch tip — i.e.
# the branch was forked from (or rebased onto) the current main tip.
#
# If main has moved ahead of the branch base, a merge-tree pre-check can still
# silently resolve conflicts to main's side (as happened with wa-e99e / 52ba4c95).
# We refuse to proceed and bounce back to the author with gate-status:needs-rebase.

# ga-ljbx: hardened — resolve main to a REAL commit object. If the ref points at a
# missing/garbage object (racing fetch, competing reconciler), we MUST NOT proceed:
# every downstream merge-base/merge-tree would silently misclassify a clean branch
# as "no common ancestor" and strand it on needs-rebase (root cause of the ga-tmug
# bounce: main_sha 7b03eb9a…/e7949128… never existed in the repo). Instead, set
# gate-status:error (re-triable on the next sweep once the ref settles) and exit.
MAIN_HEAD_SHA=$(rig_resolve_commit "origin/$DEFAULT_BRANCH")
if [ -z "$MAIN_HEAD_SHA" ]; then
  err "Cannot resolve origin/$DEFAULT_BRANCH to a real commit (dangling/garbage ref). Marking gate-status:error for retry."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$MARKER_ID" "Gate transient error: origin/$DEFAULT_BRANCH did not resolve to a present commit object (likely a racing fetch). NOT a conflict — will retry on next sweep." 2>/dev/null || true
  log "SUPPRESSED PUSH (wa-uthi non-terminal): origin/$DEFAULT_BRANCH unresolvable — gate-status:error (retriable)."
  if [ "$(gate_marker_status_ensure "$MARKER_ID" "the main-ref-unresolvable guard")" = "repaired" ]; then
    warn "ga-kgtiw SELF-HEAL: marker $MARKER_ID had no gate-status label after the main-ref-unresolvable guard — self-heal force-wrote and verified gate-status:error (see marker comment + Mayor mail for detail)."
  fi
  # ga-dmox: retriable per-marker state (comment above says so) must not exit 1.
  exit 0
fi
BRANCH_IS_CURRENT=0
# main is an ancestor of branch iff the branch includes all of main
if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
  BRANCH_IS_CURRENT=1
fi

if [ "$BRANCH_IS_CURRENT" != "1" ]; then
  # ── ga-we1: Auto-rebase (clean branches only) ─────────────────────────────
  # Instead of bouncing to the author, the dispatcher attempts a conflict-free
  # rebase directly.  This eliminates the starvation loop where a branch passes
  # the stale check, enters review, main moves again during review→merge, and
  # the whole cycle restarts.
  #
  # Strategy:
  #   1. Use `git merge-tree` to detect conflicts before touching anything.
  #   2. If conflict-free: create a temp worktree, rebase onto current main,
  #      push the rebased branch tip, update BRANCH_SHA, and continue.
  #   3. If conflicts: bounce to author with a targeted conflict report (not
  #      a generic "rebase and re-run" — we know exactly which files conflict).

  log "  Branch $BRANCH is STALE (main=$MAIN_HEAD_SHA not in branch=$BRANCH_SHA). Attempting auto-rebase ..."

  # ga-ljbx: deterministic conflict detection (git 2.54). The legacy
  # `merge-tree <base> <ours> <theirs>` + grep '^<<<<<<<' read EVERY real conflict
  # as clean on git 2.54 (markers are diff-indented), so genuine conflicts slipped
  # into the rebase and a transient empty merge-base was mislabeled "no common
  # ancestor" → forced conflict → strand. We now use --write-tree exit codes.
  HAS_CONFLICT=0
  CONFLICT_FILES=""
  # ga-q3ig2: classify WHY a branch can't fast-forward so the dead-author handler
  # can decide whether a server-side retry is worthwhile. "merge" = a genuine,
  # deterministic merge conflict vs current main (re-running the rebase yields the
  # same result; a dead author cannot resolve it → skip retries, escalate at once).
  # "transient" = auto-rebase worktree/push plumbing failure (main may settle →
  # bounded retry still makes sense).
  CONFLICT_KIND=""
  MERGE_BASE_SHA=$(git_rig merge-base "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
  MT_VERDICT=$(rig_merge_has_conflict "origin/$DEFAULT_BRANCH" "origin/$BRANCH")
  # ga-kyxih: computed once per sweep, independent of MT_VERDICT (a structural
  # fact about the branch's own history, not about its relationship to main).
  # Used below both to route the auto-rebase-vs-auto-merge choice and to
  # tailor the bounce/retry messaging further down when a merge-commit-tip
  # branch still needs a human (a genuine conflict even under merge, or an
  # unexpected merge failure).
  BRANCH_TIP_IS_MERGE_COMMIT=$(branch_tip_is_merge_commit "origin/$BRANCH")

  if [ "$MT_VERDICT" = "err" ]; then
    # Undeterminable (unrelated histories OR a ref still settling). Do NOT bounce to
    # needs-rebase — that strands a possibly-clean branch on a dead author. Mark
    # gate-status:error so the next sweep re-attempts once refs settle.
    err "  Conflict pre-check undeterminable for $BRANCH (merge-tree err; base=${MERGE_BASE_SHA:-none}). Marking gate-status:error for retry."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$MARKER_ID" "Gate transient error: merge-tree conflict pre-check for $BRANCH vs $DEFAULT_BRANCH was undeterminable (merge-base=${MERGE_BASE_SHA:-none}). NOT necessarily a conflict — will retry on next sweep." 2>/dev/null || true
    log "SUPPRESSED PUSH (wa-uthi non-terminal): merge-tree undeterminable for $BRANCH — gate-status:error (retriable)."
    if [ "$(gate_marker_status_ensure "$MARKER_ID" "the merge-tree-undeterminable guard")" = "repaired" ]; then
      warn "ga-kgtiw SELF-HEAL: marker $MARKER_ID had no gate-status label after the merge-tree-undeterminable guard — self-heal force-wrote and verified gate-status:error (see marker comment + Mayor mail for detail)."
    fi
    # ga-dmox: retriable per-marker state (comment above says so) must not exit 1.
    exit 0
  elif [ "$MT_VERDICT" = "1" ]; then
    HAS_CONFLICT=1
    CONFLICT_KIND="merge"   # ga-q3ig2: genuine, deterministic merge conflict.
    # Capture conflicting file names from the structured --write-tree conflict block.
    # The trailing `|| true` is REQUIRED: merge-tree --write-tree returns rc=1 on a
    # conflict, and under `set -euo pipefail` (line 30) `pipefail` propagates that
    # non-zero through the pipe, so the bare `CONFLICT_FILES=$(...)` assignment would
    # trip `set -e` and SILENTLY kill the dispatcher mid-conflict-handling — head-of-
    # line-blocking the whole gate on the first conflicting branch (ga-mzc3h follow-up).
    CONFLICT_FILES=$(git_rig merge-tree --write-tree --name-only "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null \
      | tail -n +2 | head -5 | tr '\n' ' ' | cut -c1-300 || true)
    [ -z "$CONFLICT_FILES" ] && CONFLICT_FILES="merge conflict (files unavailable)"
  fi

  # imp22: Constrain auto-rebase to the FF-only / behind-only / clean-tree envelope.
  # The gate only attempts a server-side rebase when the branch is within a safe
  # divergence envelope AND the rig git state is clean.  Outside this envelope the
  # rebase is skipped (treated as transient) so it enters the bounded-retry / Mayor-
  # escalation path rather than blindly rebasing large or unclean branches:
  #   (a) Divergence ahead cap (GATE_REBASE_AHEAD_MAX): branch has at most N own
  #       commits not yet on main.  A large ahead-count risks logical conflicts even
  #       when textually clean (merge-tree is textual-only).
  #   (b) Divergence behind cap (GATE_REBASE_BEHIND_MAX): main has moved at most M
  #       commits since the branch base.  A huge main-delta compounds that risk.
  #   (c) Clean-tree guard: no ORIG_HEAD / MERGE_HEAD / index.lock in the rig's
  #       .git dir — signs of a prior interrupted git operation that a worktree
  #       rebase would collide with.
  GATE_REBASE_AHEAD_MAX="${GATE_REBASE_AHEAD_MAX:-10}"
  GATE_REBASE_BEHIND_MAX="${GATE_REBASE_BEHIND_MAX:-50}"
  REBASE_IN_ENVELOPE=1
  REBASE_SKIP_REASON=""
  # ga-6dp9 (bug 2 of 3): tracks specifically whether the BEHIND-envelope check
  # (below) is what took us out of envelope, as distinct from the AHEAD check or
  # the clean-tree guard. main only ever moves forward, so this specific cause is
  # a PERMANENT condition (never self-heals by waiting) — see
  # gate_behind_envelope_action() above. Initialized here (unconditionally,
  # before the HAS_CONFLICT branch below) so it is always defined under this
  # script's `set -u`, even when HAS_CONFLICT was already 1 and the envelope
  # checks are skipped entirely.
  REBASE_BEHIND_EXCEEDED=0
  # ga-agtqm: true iff the ahead-commit-count cap below is the SOLE reason
  # this branch is out of envelope — i.e. the real merge-tree check that
  # gates entry to this whole block (HAS_CONFLICT=0 test just below) already
  # proved the branch merges CLEAN, and we are only distrusting it here for
  # being textually-clean-but-large. Fed into gate_circuit_break_check()'s
  # ahead_dead/retry_dead conditions downstream so a provably clean-merging
  # branch is never circuit-broken purely because of its commit count.
  # Reset to 0 if the behind-cap or clean-tree guard below ALSO fire —
  # those are independent, already-correctly-severe conditions (ga-6dp9)
  # this bead does not touch.
  REBASE_AHEAD_CAP_ONLY=0

  if [ "$HAS_CONFLICT" = "0" ]; then
    REBASE_AHEAD=$(git_rig rev-list --count "origin/$DEFAULT_BRANCH..origin/$BRANCH" 2>/dev/null || echo "")
    REBASE_BEHIND=$(git_rig rev-list --count "origin/$BRANCH..origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")

    # ga-agtqm: an explicit human/Mayor release decision — label
    # gate:allow-large-divergence on the SOURCE BEAD — bypasses the ahead-cap
    # below entirely, letting a provably-clean branch (HAS_CONFLICT=0 above)
    # proceed straight to auto-rebase regardless of size. Re-read FRESH every
    # sweep (never cached across sweeps, no persistent state file) so the
    # decision survives every future scan: the bug this replaces had a human
    # revert gate-status by hand, only for the NEXT sweep to re-derive the
    # identical ahead>max condition and re-park it — nothing ever checked for
    # a durable release signal, only a transient one that kept getting
    # overwritten.
    GATE_ALLOW_LARGE_DIVERGENCE=0
    if [ -n "$BEAD_ID" ]; then
      _ALD_LABELS=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "")
      case " $_ALD_LABELS " in
        *" gate:allow-large-divergence "*) GATE_ALLOW_LARGE_DIVERGENCE=1 ;;
      esac
    fi

    if [ -n "$REBASE_AHEAD" ] && [ "$REBASE_AHEAD" -gt "$GATE_REBASE_AHEAD_MAX" ] && [ "$GATE_ALLOW_LARGE_DIVERGENCE" != "1" ]; then
      REBASE_IN_ENVELOPE=0
      REBASE_AHEAD_CAP_ONLY=1
      REBASE_SKIP_REASON="branch has $REBASE_AHEAD own commits not on main (> GATE_REBASE_AHEAD_MAX=${GATE_REBASE_AHEAD_MAX}) — large divergence risks logical conflicts"
    elif [ -n "$REBASE_AHEAD" ] && [ "$REBASE_AHEAD" -gt "$GATE_REBASE_AHEAD_MAX" ]; then
      log "  ga-agtqm: branch $BRANCH is $REBASE_AHEAD commits ahead (> $GATE_REBASE_AHEAD_MAX) but bead $BEAD_ID carries gate:allow-large-divergence — proceeding despite the envelope (explicit release)."
    fi
    if [ -n "$REBASE_BEHIND" ] && [ "$REBASE_BEHIND" -gt "$GATE_REBASE_BEHIND_MAX" ]; then
      REBASE_IN_ENVELOPE=0
      REBASE_BEHIND_EXCEEDED=1
      REBASE_AHEAD_CAP_ONLY=0
      REBASE_SKIP_REASON="${REBASE_SKIP_REASON:+${REBASE_SKIP_REASON}; }main moved $REBASE_BEHIND commits ahead of branch base (> GATE_REBASE_BEHIND_MAX=${GATE_REBASE_BEHIND_MAX}) — large main delta compounds conflict risk"
    fi

    # Clean-tree guard: check rig .git dir for signs of an interrupted git op.
    if [ "$IS_CONTAINER_RIG" = "1" ]; then
      _RIG_GIT_DIR=$(git_rig rev-parse --git-dir 2>/dev/null || echo "")
    else
      _RIG_GIT_DIR="${GIT_DIR_PATH}/.git"
    fi
    if [ -n "$_RIG_GIT_DIR" ] && [ -d "$_RIG_GIT_DIR" ]; then
      # GATE-HANG FIX (2026-06-24): ORIG_HEAD is a BENIGN backup ref that git writes
      # after EVERY rebase/reset/merge — NOT a sign of an interrupted op. Gating on it
      # froze the gate for ~15h: every stale-branch sweep skipped the rebase then hung,
      # and ORIG_HEAD regenerates on each git op so it never cleared. Only REAL
      # in-progress markers count (rebase dirs / MERGE_HEAD / CHERRY_PICK_HEAD / index.lock).
      if [ -d "$_RIG_GIT_DIR/rebase-merge" ] || [ -d "$_RIG_GIT_DIR/rebase-apply" ] || [ -f "$_RIG_GIT_DIR/MERGE_HEAD" ] || [ -f "$_RIG_GIT_DIR/CHERRY_PICK_HEAD" ] || [ -f "$_RIG_GIT_DIR/index.lock" ]; then
        REBASE_IN_ENVELOPE=0
        REBASE_AHEAD_CAP_ONLY=0
        _LOCK_FILES=""
        [ -d "$_RIG_GIT_DIR/rebase-merge"     ] && _LOCK_FILES="${_LOCK_FILES}rebase-merge "
        [ -d "$_RIG_GIT_DIR/rebase-apply"     ] && _LOCK_FILES="${_LOCK_FILES}rebase-apply "
        [ -f "$_RIG_GIT_DIR/MERGE_HEAD"       ] && _LOCK_FILES="${_LOCK_FILES}MERGE_HEAD "
        [ -f "$_RIG_GIT_DIR/CHERRY_PICK_HEAD" ] && _LOCK_FILES="${_LOCK_FILES}CHERRY_PICK_HEAD "
        [ -f "$_RIG_GIT_DIR/index.lock"       ] && _LOCK_FILES="${_LOCK_FILES}index.lock "
        REBASE_SKIP_REASON="${REBASE_SKIP_REASON:+${REBASE_SKIP_REASON}; }rig .git is unclean (${_LOCK_FILES% }) — prior interrupted git op"
      fi
    fi

    if [ "$REBASE_IN_ENVELOPE" = "0" ]; then
      warn "  Auto-rebase skipped (imp22 envelope): ${REBASE_SKIP_REASON}"
      HAS_CONFLICT=1
      CONFLICT_KIND="transient"
      CONFLICT_FILES="out-of-envelope: ${REBASE_SKIP_REASON}"
    fi
  fi

  if [ "$HAS_CONFLICT" = "0" ]; then
    # Clean rebase within the safe envelope: perform in a temp worktree, push to
    # origin, continue with review.
    log "  Auto-rebase: no conflicts detected (ahead=${REBASE_AHEAD:-?} behind=${REBASE_BEHIND:-?}) — rebasing $BRANCH onto $MAIN_HEAD_SHA ..."
    AUTO_REBASE_OK=0
    TMP_REBASE_WT="/tmp/gc-gate-autorebase-$$"
    # ga-g0v96 (AC3): captured push stderr/exit-code, if the push below fails.
    # Empty means "no push was attempted or none failed" — never confuse with a
    # captured-but-empty stderr (AUTO_REBASE_PUSH_RC is the actual failure signal).
    AUTO_REBASE_PUSH_ERR=""
    AUTO_REBASE_PUSH_RC=""

    # imp18: Acquire per-repo mutation mutex before any git worktree/rebase/push ops.
    # If a live holder exists, treat as transient (next sweep retries; mutex + janitor
    # together ensure locks never block a rig permanently). Skipped gracefully when the
    # mutex lib was not sourced (git_mutex_acquire not defined).
    _REBASE_MUTEX_HELD=0
    if type git_mutex_acquire >/dev/null 2>&1; then
      if git_mutex_acquire "$RIG_PATH" 2>/dev/null; then
        _REBASE_MUTEX_HELD=1
      else
        warn "  Auto-rebase (imp18): per-repo mutex held for $RIG_PATH — transient skip; janitor will clear stale locks"
        HAS_CONFLICT=1
        CONFLICT_KIND="transient"
        CONFLICT_FILES="per-repo git mutex held (imp18 — another git op in progress)"
      fi
    fi

    if [ "$IS_CONTAINER_RIG" = "1" ] && [ "$HAS_CONFLICT" = "0" ]; then
      # Container rig (bare repo): worktree uses the bare .repo.git
      if git_rig worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>/dev/null; then
        if [ "$BRANCH_TIP_IS_MERGE_COMMIT" = "1" ]; then
          # ga-kyxih: this branch's own tip is already a merge commit — `git
          # rebase` (the else-branch below) linearizes/mishandles that
          # history (see branch_tip_is_merge_commit() above for why). Use a
          # real `git merge` instead; merge-tree already predicted this would
          # be clean (HAS_CONFLICT=0 to have reached this block at all).
          log "  Auto-merge (ga-kyxih: tip is itself a merge commit — rebase is not applicable): merging $DEFAULT_BRANCH into $BRANCH instead of rebasing ..."
          if git -C "$TMP_REBASE_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" merge "origin/$DEFAULT_BRANCH" -m "Merge origin/$DEFAULT_BRANCH into $BRANCH (gate auto-merge — tip was a merge commit, ga-kyxih)" 2>/dev/null; then
            NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
            if [ -z "$NEW_TIP" ]; then
              warn "  Auto-merge: rev-parse HEAD after merge returned empty for $BRANCH — treating as push failure"
              AUTO_REBASE_PUSH_ERR="rev-parse HEAD after merge returned empty (merge produced no commit?)"
            else
              _PUSH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/gc-gate-autorebase-push.XXXXXX" 2>/dev/null || echo "/tmp/gc-gate-autorebase-push.$$")
              if git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>"$_PUSH_ERR_FILE"; then
                AUTO_REBASE_OK=1
                BRANCH_SHA="$NEW_TIP"
                log "  Auto-merge success: $BRANCH pushed to $NEW_TIP (merged $DEFAULT_BRANCH in — tip was already a merge commit, ga-kyxih)"
                bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-merged origin/$DEFAULT_BRANCH into $BRANCH ($MAIN_HEAD_SHA) instead of rebasing — this branch's tip was already a merge commit (ga-kyxih). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
                git_rig fetch origin 2>/dev/null || true
                BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH"); [ -z "$BRANCH_SHA" ] && BRANCH_SHA="$NEW_TIP"
                if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
                  BRANCH_IS_CURRENT=1
                else
                  warn "  Post-auto-merge stale check still fails — falling through to bounce."
                  AUTO_REBASE_OK=0
                fi
              else
                AUTO_REBASE_PUSH_RC=$?
                AUTO_REBASE_PUSH_ERR=$(tr '\n' ' ' < "$_PUSH_ERR_FILE" 2>/dev/null | cut -c1-500)
                warn "  Auto-merge push failed for $BRANCH (exit=$AUTO_REBASE_PUSH_RC): ${AUTO_REBASE_PUSH_ERR:-<no stderr captured>}"
              fi
              rm -f "$_PUSH_ERR_FILE" 2>/dev/null || true
            fi
          else
            warn "  Auto-merge git merge command failed (unexpected, ga-kyxih — merge-tree reported no conflicts; tip is itself a merge commit)"
            git -C "$TMP_REBASE_WT" merge --abort 2>/dev/null || true
          fi
        # ga-euopg: identity scoped via -c to this invocation only — see note
        # at the merge-time-rebase call site above for why (was leaking into
        # shared repo config, repo-wide, every auto-rebase cycle).
        elif git -C "$TMP_REBASE_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
          if [ -z "$NEW_TIP" ]; then
            warn "  Auto-rebase: rev-parse HEAD after rebase returned empty for $BRANCH — treating as push failure"
            AUTO_REBASE_PUSH_ERR="rev-parse HEAD after rebase returned empty (rebase produced no commit?)"
          else
            # ga-g0v96 (AC3): capture stderr + exit code instead of discarding both —
            # "Auto-rebase push failed" with zero diagnostics was the exact
            # error==empty defect this bead exists to fix.
            _PUSH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/gc-gate-autorebase-push.XXXXXX" 2>/dev/null || echo "/tmp/gc-gate-autorebase-push.$$")
            if git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>"$_PUSH_ERR_FILE"; then
              AUTO_REBASE_OK=1
              BRANCH_SHA="$NEW_TIP"
              log "  Auto-rebase success: $BRANCH pushed to $NEW_TIP (rebased onto $MAIN_HEAD_SHA)"
              bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-rebased $BRANCH onto main ($MAIN_HEAD_SHA). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
              # Re-verify stale check passes now
              git_rig fetch origin 2>/dev/null || true
              BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH"); [ -z "$BRANCH_SHA" ] && BRANCH_SHA="$NEW_TIP"
              if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
                BRANCH_IS_CURRENT=1
              else
                warn "  Post-auto-rebase stale check still fails — falling through to bounce."
                AUTO_REBASE_OK=0
              fi
            else
              AUTO_REBASE_PUSH_RC=$?
              AUTO_REBASE_PUSH_ERR=$(tr '\n' ' ' < "$_PUSH_ERR_FILE" 2>/dev/null | cut -c1-500)
              warn "  Auto-rebase push failed for $BRANCH (exit=$AUTO_REBASE_PUSH_RC): ${AUTO_REBASE_PUSH_ERR:-<no stderr captured>}"
            fi
            rm -f "$_PUSH_ERR_FILE" 2>/dev/null || true
          fi
        else
          warn "  Auto-rebase git rebase command failed (unexpected — merge-tree reported no conflicts)"
          git -C "$TMP_REBASE_WT" rebase --abort 2>/dev/null || true
        fi
        git_rig worktree remove "$TMP_REBASE_WT" --force 2>/dev/null || true
      else
        warn "  Could not create auto-rebase worktree at $TMP_REBASE_WT"
      fi
    elif [ "$HAS_CONFLICT" = "0" ]; then
      # Self-repo rig
      if git -C "$GIT_DIR_PATH" worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>/dev/null; then
        if [ "$BRANCH_TIP_IS_MERGE_COMMIT" = "1" ]; then
          # ga-kyxih: see the container-rig branch above for why — this
          # branch's own tip is already a merge commit, so `git rebase` (the
          # elif-branch below) is not applicable; use a real `git merge`.
          log "  Auto-merge (self-repo, ga-kyxih: tip is itself a merge commit — rebase is not applicable): merging $DEFAULT_BRANCH into $BRANCH instead of rebasing ..."
          if git -C "$TMP_REBASE_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" merge "origin/$DEFAULT_BRANCH" -m "Merge origin/$DEFAULT_BRANCH into $BRANCH (gate auto-merge — tip was a merge commit, ga-kyxih)" 2>/dev/null; then
            NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
            if [ -z "$NEW_TIP" ]; then
              warn "  Auto-merge (self-repo): rev-parse HEAD after merge returned empty for $BRANCH — treating as push failure"
              AUTO_REBASE_PUSH_ERR="rev-parse HEAD after merge returned empty (merge produced no commit?)"
            else
              _PUSH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/gc-gate-autorebase-push.XXXXXX" 2>/dev/null || echo "/tmp/gc-gate-autorebase-push.$$")
              if git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>"$_PUSH_ERR_FILE"; then
                AUTO_REBASE_OK=1
                BRANCH_SHA="$NEW_TIP"
                log "  Auto-merge success (self-repo): $BRANCH pushed to $NEW_TIP (tip was already a merge commit, ga-kyxih)"
                bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-merged origin/$DEFAULT_BRANCH into $BRANCH ($MAIN_HEAD_SHA) instead of rebasing — this branch's tip was already a merge commit (ga-kyxih). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
                git_rig fetch origin 2>/dev/null || true
                BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH"); [ -z "$BRANCH_SHA" ] && BRANCH_SHA="$NEW_TIP"
                if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
                  BRANCH_IS_CURRENT=1
                else
                  warn "  Post-auto-merge stale check still fails — falling through to bounce."
                  AUTO_REBASE_OK=0
                fi
              else
                AUTO_REBASE_PUSH_RC=$?
                AUTO_REBASE_PUSH_ERR=$(tr '\n' ' ' < "$_PUSH_ERR_FILE" 2>/dev/null | cut -c1-500)
                warn "  Auto-merge push failed (self-repo) for $BRANCH (exit=$AUTO_REBASE_PUSH_RC): ${AUTO_REBASE_PUSH_ERR:-<no stderr captured>}"
              fi
              rm -f "$_PUSH_ERR_FILE" 2>/dev/null || true
            fi
          else
            warn "  Auto-merge git merge command failed (self-repo, unexpected, ga-kyxih — merge-tree reported no conflicts; tip is itself a merge commit)"
            git -C "$TMP_REBASE_WT" merge --abort 2>/dev/null || true
          fi
        # ga-euopg: see identity-scoping note above (container-rig branch).
        elif git -C "$TMP_REBASE_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
          if [ -z "$NEW_TIP" ]; then
            warn "  Auto-rebase (self-repo): rev-parse HEAD after rebase returned empty for $BRANCH — treating as push failure"
            AUTO_REBASE_PUSH_ERR="rev-parse HEAD after rebase returned empty (rebase produced no commit?)"
          else
            # ga-g0v96 (AC3): capture stderr + exit code instead of discarding both.
            _PUSH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/gc-gate-autorebase-push.XXXXXX" 2>/dev/null || echo "/tmp/gc-gate-autorebase-push.$$")
            if git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>"$_PUSH_ERR_FILE"; then
              AUTO_REBASE_OK=1
              BRANCH_SHA="$NEW_TIP"
              log "  Auto-rebase success (self-repo): $BRANCH pushed to $NEW_TIP"
              bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-rebased $BRANCH onto main ($MAIN_HEAD_SHA). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
              git_rig fetch origin 2>/dev/null || true
              BRANCH_SHA=$(rig_resolve_commit "origin/$BRANCH"); [ -z "$BRANCH_SHA" ] && BRANCH_SHA="$NEW_TIP"
              if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
                BRANCH_IS_CURRENT=1
              else
                warn "  Post-auto-rebase stale check still fails — falling through to bounce."
                AUTO_REBASE_OK=0
              fi
            else
              AUTO_REBASE_PUSH_RC=$?
              AUTO_REBASE_PUSH_ERR=$(tr '\n' ' ' < "$_PUSH_ERR_FILE" 2>/dev/null | cut -c1-500)
              warn "  Auto-rebase push failed (self-repo) for $BRANCH (exit=$AUTO_REBASE_PUSH_RC): ${AUTO_REBASE_PUSH_ERR:-<no stderr captured>}"
            fi
            rm -f "$_PUSH_ERR_FILE" 2>/dev/null || true
          fi
        else
          warn "  Auto-rebase git rebase failed (self-repo)"
          git -C "$TMP_REBASE_WT" rebase --abort 2>/dev/null || true
        fi
        git -C "$GIT_DIR_PATH" worktree remove "$TMP_REBASE_WT" --force 2>/dev/null || true
      else
        warn "  Could not create auto-rebase worktree (self-repo) at $TMP_REBASE_WT"
      fi
    fi
    # imp18: release the per-repo mutex (noop if never acquired or lib not loaded)
    [ "$_REBASE_MUTEX_HELD" = "1" ] && { type git_mutex_release >/dev/null 2>&1 && git_mutex_release "$RIG_PATH" 2>/dev/null || true; }

    if [ "$AUTO_REBASE_OK" = "1" ] && [ "$BRANCH_IS_CURRENT" = "1" ]; then
      log "  Auto-rebase complete — branch is now current. Continuing with review."
      # ga-g0v96 (AC5): any retry saga for this marker is over now — clear the
      # informational retry label from the SOURCE bead so it doesn't linger
      # once the branch recovers on a later sweep.
      _PRIOR_ATTEMPT=$(read_rebase_attempt "$MARKER_ID")
      if [ -n "$BEAD_ID" ] && [ "$_PRIOR_ATTEMPT" != "0" ]; then
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:rebase-retry:$_PRIOR_ATTEMPT" -q 2>/dev/null || true
      fi
      # Fall through to Step 5 with updated BRANCH_SHA
    else
      # Auto-rebase failed despite no conflicts (worktree/push failure).
      # ga-g0v96 (AC3): surface the CAPTURED diagnostic when we have one, instead
      # of the old zero-information "worktree/push error" string.
      HAS_CONFLICT=1
      CONFLICT_KIND="transient"   # ga-q3ig2: plumbing failure, not a real conflict — retry is worthwhile.
      if [ -n "$AUTO_REBASE_PUSH_ERR" ]; then
        CONFLICT_FILES="auto-rebase push failed (exit=${AUTO_REBASE_PUSH_RC:-?}): $AUTO_REBASE_PUSH_ERR"
      else
        CONFLICT_FILES="auto-rebase failed (worktree/push error) — no stderr captured"
      fi
    fi
  fi

  if [ "$BRANCH_IS_CURRENT" != "1" ]; then
    # ── ga-ljbx: never-strand bounce ──────────────────────────────────────────
    # GENUINE conflict (or auto-rebase worktree/push failure). The old behavior
    # bounced to needs-rebase + nudged the author. For framework self-fixes the
    # author is a drained/transient pool dog (AUTHOR empty OR no live session), so
    # the nudge hit nothing and the bead stranded forever, re-firing needs_rebase
    # on every re-pick. We now:
    #   1. Decide if the author is reachable (non-empty AND a live session exists).
    #   2. If reachable: bounce + nudge as before (author can fix conflicts).
    #   3. If NOT reachable: track a bounded gate:exiled-tier5:N counter on the
    #      marker. Below MAX → mark gate-status:error (the next sweep re-attempts
    #      the auto-rebase; main may have settled / a transient may clear). At/above
    #      MAX → escalate to the Mayor via mail (durable) and mark needs-rebase, so
    #      a human-or-Mayor-driven resolution happens — but we NEVER silently strand.
    MAX_REBASE_ATTEMPTS=3
    # ga-g0v96 (AC4): a marker used to sink to tier5 (behind EVERY healthy queued
    # marker) on the VERY FIRST transient rebase failure — the same step that
    # stamped "retry 1/3" also stamped the exile, so on a busy gate the marker's
    # own retry budget starved behind the healthy queue for hours (observed: 4h44m
    # between attempt 1 and attempt 2, wa-b6uy3). Forgive a single blip: only a
    # REPEATED transient failure (this attempt >= threshold) sinks the marker.
    # GATE_EXILE_AFTER_ATTEMPTS=1 restores the old always-exile behavior.
    GATE_EXILE_AFTER_ATTEMPTS="${GATE_EXILE_AFTER_ATTEMPTS:-2}"

    # ga-6dp9 (bug 1 of 3): compute the branch-author candidate for THIS
    # liveness check specifically — see resolve_rebase_author() above. Does
    # NOT touch $AUTHOR itself — the notify target below keeps its original
    # ga-pyzo/ga-ipf6 wiring unchanged (restored below, gate-fix-1: an
    # earlier revision of this fix accidentally repurposed that wiring for
    # the liveness decision instead of duplicating it — see the block below).
    REBASE_AUTHOR=$(resolve_rebase_author "$AUTHOR_TRUSTED_SUBMIT" "$BRANCH" "$MARKER_AUTHOR")

    # ga-ipf6: unified with FAIL_AUTHOR_ALIVE via author_is_alive() — the old
    # inline predicate here (alias/name/agent only, no session_name) never
    # matched AUTHOR's actual session_name form, so every live author was
    # misread as dead on this path. ga-6dp9 (gate-fix-1): named
    # REBASE_AUTHOR_ALIVE (not AUTHOR_ALIVE) and keyed on REBASE_AUTHOR — the
    # actual branch author, bug 1's fix — so it can drive every decision
    # below without colliding with AUTHOR's own liveness/redirect, restored
    # below for the notify target.
    REBASE_AUTHOR_ALIVE=$(author_is_alive "$REBASE_AUTHOR")

    # ga-pyzo: recycled-session fallback for the REBASE_AUTHOR liveness
    # DECISION (bug 1), applied BEFORE the ga-acb circuit-break check below
    # (which consumes REBASE_AUTHOR_ALIVE) so a live agent whose specific
    # submitting session recycled is never misread as dead-with-no-live-author
    # and permanently circuit-broken.
    _RESOLVED_REBASE_AUTHOR=$(resolve_recycled_author "$REBASE_AUTHOR" "$AUTHOR_AGENT" "$REBASE_AUTHOR_ALIVE")
    if [ "$_RESOLVED_REBASE_AUTHOR" != "$REBASE_AUTHOR" ]; then
      log "  ga-pyzo: rebase-liveness author '$REBASE_AUTHOR' session recycled but agent '$_RESOLVED_REBASE_AUTHOR' has a live session — redirecting liveness to the agent."
      REBASE_AUTHOR="$_RESOLVED_REBASE_AUTHOR"
      REBASE_AUTHOR_ALIVE=1
    fi

    # ga-6dp9 (gate-fix-1): restore the ga-pyzo/ga-ipf6 wiring for $AUTHOR
    # itself, independent of REBASE_AUTHOR_ALIVE (which drives the actual
    # bounce/circuit-break decision, bug 1) — same helper, same pattern as the
    # FAIL-path call site above (ga-ipf6 lesson: don't let this fallback
    # re-diverge across call sites again). Gate review on the first submission
    # (gate_run=ga-wisp-wejpxu) caught that an earlier revision reassigned
    # ONLY REBASE_AUTHOR above and never touched $AUTHOR again, so a worker
    # submitting under an ephemeral adhoc session (e.g.
    # gate.submitted_by="digo-wa-adhoc-abc123") whose durable role has since
    # picked up a fresh live session would have had ITS notify target silently
    # left on the confirmed-dead adhoc id wherever $AUTHOR is still the notify
    # variable (the circuit-break paths below, and the QG_LOG "author of
    # record" field).
    #
    # ga-6dp9 (gate-fix-2): the bounce/retry branches below (behind-envelope
    # bounce, genuine-merge-conflict bounce, transient-retry-live-author, and
    # its exhausted-retries escalation) do NOT use $AUTHOR for their nudge
    # target — they use $REBASE_AUTHOR instead. Gate review on gate-fix-1
    # (gate_run=ga-wisp-bkb9q6) found that those branches decide "someone can
    # fix this" via REBASE_AUTHOR_ALIVE (a check that, unlike $AUTHOR, never
    # falls through to a stale bead-assignee/owner — see resolve_rebase_author()
    # above) but were nudging the separate, possibly-dead $AUTHOR — leaving no
    # one actually notified when the two identities diverge. Do not
    # "fix" those call sites back to $AUTHOR.
    AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")
    _RESOLVED_AUTHOR=$(resolve_recycled_author "$AUTHOR" "$AUTHOR_AGENT" "$AUTHOR_ALIVE")
    if [ "$_RESOLVED_AUTHOR" != "$AUTHOR" ]; then
      log "  ga-pyzo: notify author '$AUTHOR' session recycled but agent '$_RESOLVED_AUTHOR' has a live session — redirecting nudge/mail target to the agent."
      AUTHOR="$_RESOLVED_AUTHOR"
      AUTHOR_ALIVE=1
    fi

    # Read current rebase-attempt counter from the marker labels.
    REBASE_ATTEMPT=$(read_rebase_attempt "$MARKER_ID")

    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true

    # ga-acb: ahead_dead circuit-break — branch has more own commits than the
    # rebase envelope allows AND no live author to re-anchor a large divergence.
    # Checked BEFORE the retry/bounce branching so the marker never enters the
    # bounded-retry churn cycle on a provably un-mergeable branch.
    _ACB_AHEAD=$(gate_circuit_break_check "ahead_dead" "${REBASE_AHEAD:-}" "$REBASE_AUTHOR_ALIVE" "$REBASE_ATTEMPT" "$MAX_REBASE_ATTEMPTS" "$GATE_REBASE_AHEAD_MAX" "$REBASE_AHEAD_CAP_ONLY")
    if [ "$_ACB_AHEAD" != "ok" ]; then
      err "  ga-acb: circuit-breaking marker $MARKER_ID (${_ACB_AHEAD}): ahead=${REBASE_AHEAD:-?} > GATE_REBASE_AHEAD_MAX=${GATE_REBASE_AHEAD_MAX} and author dead/empty."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:error" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$MARKER_ID" "ga-acb AUTO-CIRCUIT-BREAK (${_ACB_AHEAD}): branch $BRANCH is ${REBASE_AHEAD:-?} commits ahead of main (> GATE_REBASE_AHEAD_MAX=${GATE_REBASE_AHEAD_MAX}) with no live author session. A server-side rebase of a large divergence with no one to resolve conflicts is futile. Marker permanently parked at gate-status:error. Source bead $BEAD_ID set gate:needs-human." 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human"           -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human:technical" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"            -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"             -q 2>/dev/null || true  # wa-qq33j
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"           -q 2>/dev/null || true
        bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""                           -q 2>/dev/null || true
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-acb AUTO-CIRCUIT-BREAK (${_ACB_AHEAD}): branch $BRANCH is ${REBASE_AHEAD:-?} commits ahead (> ${GATE_REBASE_AHEAD_MAX} max) with no live author (marker $MARKER_ID). Large divergence + dead author = un-mergeable. Set gate:needs-human; story:in-flight + gate:reviewing (wa-qq33j) + pilot:dispatched stripped." 2>/dev/null || true
      fi
      gc --city "$GC_CITY" mail send mayor \
        -s "Gate circuit-break: $BRANCH large divergence + dead author (${BEAD_ID:-unknown})" \
        -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) is ${REBASE_AHEAD:-?} commits ahead of main (> ${GATE_REBASE_AHEAD_MAX} max) with no live author session. Auto-circuit-broken (ga-acb): marker parked at gate-status:error; source bead set gate:needs-human. Human or Mayor must re-anchor the work or close the bead." 2>/dev/null \
        || warn "Could not mail Mayor for ahead_dead circuit-break on $BRANCH"
      # ga-u4yi: durable mail to the AUTHOR too (see no_branch site above for why).
      if [ -n "$AUTHOR" ]; then
        gc --city "$GC_CITY" mail send "$AUTHOR" \
          -s "Gate needs-human: $BRANCH diverged too far from main ($BEAD_ID)" \
          -m "Your branch $BRANCH (bead $BEAD_ID) is ${REBASE_AHEAD:-?} commits ahead of main (> ${GATE_REBASE_AHEAD_MAX} max) and your session was not live to resolve the rebase. Source bead $BEAD_ID is now labeled gate:needs-human: the Pilot will NOT re-dispatch it, and any further /gate-done resubmission will be silently parked until a human resolves this. A human or the Mayor must re-anchor the work." \
          2>/dev/null || warn "Could not mail author $AUTHOR for ahead_dead circuit-break on $BRANCH"
      fi
      REBASE_EVENT="dispatcher_circuit_break_ahead_dead"
      REBASE_VERDICT="CIRCUIT-BREAK (ahead=${REBASE_AHEAD:-?} > max=${GATE_REBASE_AHEAD_MAX}, dead author)"
      log "ga-acb circuit-break: $BRANCH ahead_dead — marker $MARKER_ID parked, bead $BEAD_ID needs-human."
      if [ "$(gate_marker_status_ensure "$MARKER_ID" "the ahead_dead circuit-break")" = "repaired" ]; then
        warn "ga-kgtiw SELF-HEAL: marker $MARKER_ID had no gate-status label after the ahead_dead circuit-break — self-heal force-wrote and verified gate-status:error (see marker comment + Mayor mail for detail)."
      fi
      log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH — $REBASE_VERDICT."
      mkdir -p "$(dirname "$QG_LOG")"
      jq -c -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg branch "$BRANCH" \
        --arg bead "$BEAD_ID" \
        --arg rig "${RIG:-unknown}" \
        --arg marker "$MARKER_ID" \
        --arg author "$AUTHOR" \
        --arg event "$REBASE_EVENT" \
        '{ts: $ts, event: $event, branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author}' \
        >> "$QG_LOG" 2>/dev/null || true
      log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$REBASE_VERDICT ==="
      # ga-dmox: marker already fully parked (labels, comments, mail sent above)
      # — exit 0, not 1; this is a handled terminal outcome, not a daemon failure.
      exit 0
    fi

    # ga-6dp9 (bug 2 of 3): behind-envelope is ALWAYS a permanent condition —
    # main only moves forward, so this can never clear by waiting. Decide and
    # exit BEFORE the generic transient-retry dispatch below, which would
    # otherwise re-queue it with a bounded counter as if it might self-heal
    # (the exact infinite "attempt 1/3" loop this bead fixes). Checked after
    # ahead_dead above (independent condition; both can be simultaneously
    # true — ahead_dead's own circuit-break, if it already fired, exited above
    # and this code is unreached).
    _BEHIND_ACTION=$(gate_behind_envelope_action "$REBASE_BEHIND_EXCEEDED" "$REBASE_AUTHOR_ALIVE")
    if [ "$_BEHIND_ACTION" = "circuit_break" ]; then
      err "  ga-6dp9: circuit-breaking marker $MARKER_ID (behind_dead): behind=${REBASE_BEHIND:-?} > GATE_REBASE_BEHIND_MAX=${GATE_REBASE_BEHIND_MAX} and author dead/empty."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:error" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$MARKER_ID" "ga-6dp9 AUTO-CIRCUIT-BREAK (behind_dead): branch $BRANCH's base is ${REBASE_BEHIND:-?} commits behind current main (> GATE_REBASE_BEHIND_MAX=${GATE_REBASE_BEHIND_MAX}) with no live author session. main only moves forward, so this delta cannot shrink on its own, and a server-side rebase this large risks conflicts with no one to resolve them. Marker permanently parked at gate-status:error. Source bead $BEAD_ID set gate:needs-human." 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human"           -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human:technical" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"            -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"             -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"           -q 2>/dev/null || true
        bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""                           -q 2>/dev/null || true
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-6dp9 AUTO-CIRCUIT-BREAK (behind_dead): branch $BRANCH base is ${REBASE_BEHIND:-?} commits behind main (> ${GATE_REBASE_BEHIND_MAX} max) with no live author (marker $MARKER_ID). Large main delta + dead author = un-mergeable without a human rebase. Set gate:needs-human; story:in-flight + gate:reviewing + pilot:dispatched stripped." 2>/dev/null || true
      fi
      gc --city "$GC_CITY" mail send mayor \
        -s "Gate circuit-break: $BRANCH main diverged too far + dead author (${BEAD_ID:-unknown})" \
        -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) base is ${REBASE_BEHIND:-?} commits behind current main (> ${GATE_REBASE_BEHIND_MAX} max) with no live author session. Auto-circuit-broken (ga-6dp9): marker parked at gate-status:error; source bead set gate:needs-human. Human or Mayor must re-anchor the work (assisted rebase) or close the bead." 2>/dev/null \
        || warn "Could not mail Mayor for behind_dead circuit-break on $BRANCH"
      if [ -n "$AUTHOR" ]; then
        gc --city "$GC_CITY" mail send "$AUTHOR" \
          -s "Gate needs-human: $BRANCH's base fell too far behind main ($BEAD_ID)" \
          -m "Branch $BRANCH (bead $BEAD_ID) base is ${REBASE_BEHIND:-?} commits behind current main (> ${GATE_REBASE_BEHIND_MAX} max) and no live author session was found to resolve the rebase. Source bead $BEAD_ID is now labeled gate:needs-human: the Pilot will NOT re-dispatch it, and any further /gate-done resubmission will be silently parked until a human resolves this. A human or the Mayor must re-anchor the work." \
          2>/dev/null || warn "Could not mail author $AUTHOR for behind_dead circuit-break on $BRANCH"
      fi
      REBASE_EVENT="dispatcher_circuit_break_behind_dead"
      REBASE_VERDICT="CIRCUIT-BREAK (behind=${REBASE_BEHIND:-?} > max=${GATE_REBASE_BEHIND_MAX}, dead author)"
      log "ga-6dp9 circuit-break: $BRANCH behind_dead — marker $MARKER_ID parked, bead $BEAD_ID needs-human."
      if [ "$(gate_marker_status_ensure "$MARKER_ID" "the behind_dead circuit-break")" = "repaired" ]; then
        warn "ga-kgtiw SELF-HEAL: marker $MARKER_ID had no gate-status label after the behind_dead circuit-break — self-heal force-wrote and verified gate-status:error (see marker comment + Mayor mail for detail)."
      fi
      log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH — $REBASE_VERDICT."
      mkdir -p "$(dirname "$QG_LOG")"
      jq -c -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg branch "$BRANCH" \
        --arg bead "$BEAD_ID" \
        --arg rig "${RIG:-unknown}" \
        --arg marker "$MARKER_ID" \
        --arg author "$AUTHOR" \
        --arg event "$REBASE_EVENT" \
        '{ts: $ts, event: $event, branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author}' \
        >> "$QG_LOG" 2>/dev/null || true
      log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$REBASE_VERDICT ==="
      exit 0
    elif [ "$_BEHIND_ACTION" = "bounce" ]; then
      warn "Branch $BRANCH: main is ${REBASE_BEHIND:-?} commits ahead of branch base (> GATE_REBASE_BEHIND_MAX=${GATE_REBASE_BEHIND_MAX}); author $REBASE_AUTHOR is live — bouncing for manual/assisted rebase instead of auto-retrying a permanent condition."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$MARKER_ID" "Gate BLOCKED (ga-6dp9): branch $BRANCH's base is ${REBASE_BEHIND:-?} commits behind current main (> GATE_REBASE_BEHIND_MAX=${GATE_REBASE_BEHIND_MAX}). This is a permanent condition (main only moves forward) — auto-retry cannot help. Action required: manually rebase $BRANCH onto current origin/$DEFAULT_BRANCH and re-run /gate-done." 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add  "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Quality gate blocked (ga-6dp9): branch $BRANCH's base is ${REBASE_BEHIND:-?} commits behind main (> GATE_REBASE_BEHIND_MAX=${GATE_REBASE_BEHIND_MAX}). Manual rebase required — re-run /gate-done after rebasing." 2>/dev/null || true
      fi
      # ga-6dp9 (gate-fix-2): notify the identity actually verified alive for
      # THIS decision (REBASE_AUTHOR — resolve_rebase_author() never falls
      # through to a bead-assignee/owner value, so it stays reliable here),
      # not $AUTHOR, which can be a stale bead-owner. Gate review on gate-fix-1
      # (gate_run=ga-wisp-bkb9q6) caught that this bounce decides "someone can
      # fix this" via REBASE_AUTHOR_ALIVE but then nudged the separate,
      # possibly-dead $AUTHOR — leaving no one actually notified.
      gc --city "$GC_CITY" session nudge "$REBASE_AUTHOR" \
        "GATE BLOCKED for branch $BRANCH: base is ${REBASE_BEHIND:-?} commits behind main (> ${GATE_REBASE_BEHIND_MAX} max) — this is permanent, not a transient race. Manually rebase onto origin/$DEFAULT_BRANCH and re-run /gate-done. Bead: $BEAD_ID" \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $REBASE_AUTHOR for rebase"
      REBASE_EVENT="dispatcher_needs_rebase_behind_envelope"
      REBASE_VERDICT="NEEDS_REBASE (main delta > envelope, author live, bounced)"
      if [ "$(gate_marker_status_ensure "$MARKER_ID" "the behind-envelope bounce")" = "repaired" ]; then
        warn "ga-kgtiw SELF-HEAL: marker $MARKER_ID had no gate-status label after the behind-envelope bounce — self-heal force-wrote and verified gate-status:error (see marker comment + Mayor mail for detail)."
      fi
      log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH — $REBASE_VERDICT."
      mkdir -p "$(dirname "$QG_LOG")"
      jq -c -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg branch "$BRANCH" --arg bead "$BEAD_ID" --arg rig "${RIG:-unknown}" \
        --arg marker "$MARKER_ID" --arg author "$AUTHOR" --arg main_sha "$MAIN_HEAD_SHA" \
        --arg conflicts "${CONFLICT_FILES:-unknown}" --arg event "$REBASE_EVENT" \
        '{ts: $ts, event: $event, branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author, main_sha: $main_sha, conflicts: $conflicts}' \
        >> "$QG_LOG" 2>/dev/null || true
      log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$REBASE_VERDICT ==="
      exit 0
    fi

    if [ "$REBASE_AUTHOR_ALIVE" = "1" ] && [ "$CONFLICT_KIND" = "merge" ]; then
      # gt-4tk5m fix: only bounce to needs-rebase when the conflict is GENUINE
      # (deterministic merge conflict). A TRANSIENT failure (worktree/push plumbing
      # race — e.g. the author force-pushed a rebase while this marker was queued
      # and --force-with-lease rejected our push) must NOT set needs-rebase and
      # exit: that silently drops the branch from the queue (catch-22: the author
      # already rebased and expects the gate to pick it up, but needs-rebase tells
      # them to rebase again). Re-queue instead (same logic as dead-author transient
      # path) so the next sweep re-reads the author's rebased tip and proceeds.
      warn "Branch $BRANCH: genuine merge conflict (${CONFLICT_FILES:-conflicts}); author $REBASE_AUTHOR is live — bouncing for manual rebase."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
      # ga-kyxih (AC2/AC4): when this branch's OWN tip is already a merge
      # commit, a manual "rebase" is not the applicable fix either (see
      # branch_tip_is_merge_commit() above — the same reason auto-rebase
      # itself is skipped for this class) — tell the author to MERGE, not
      # rebase, instead of the generic instruction that doesn't match their
      # branch's history shape.
      if [ "$BRANCH_TIP_IS_MERGE_COMMIT" = "1" ]; then
        _REBASE_ACTION_ADVICE="this branch's own tip is already a merge commit, so rebase is not the applicable fix (ga-kyxih) — run 'git merge origin/$DEFAULT_BRANCH' into $BRANCH, resolve the conflict, and push"
      else
        _REBASE_ACTION_ADVICE="manually rebase $BRANCH onto current origin/$DEFAULT_BRANCH, resolve conflicts, and re-run /gate-done"
      fi
      bd -C "$GC_CITY" comment "$MARKER_ID" "Gate BLOCKED: branch $BRANCH is stale and has a genuine merge conflict that auto-rebase cannot resolve.
main HEAD is $MAIN_HEAD_SHA. Conflicting regions: ${CONFLICT_FILES:-unknown}.
Action required: ${_REBASE_ACTION_ADVICE}." 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add  "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" comment "$BEAD_ID" "Quality gate blocked: branch $BRANCH has a genuine merge conflict with current main ($MAIN_HEAD_SHA). Auto-rebase failed (${CONFLICT_FILES:-conflicts}). Action required: ${_REBASE_ACTION_ADVICE}." 2>/dev/null || true
      fi
      # ga-6dp9 (gate-fix-2): see the matching comment at the behind-envelope
      # bounce above — notify REBASE_AUTHOR (verified alive by this branch's
      # own gate), not the possibly-stale/dead $AUTHOR.
      gc --city "$GC_CITY" session nudge "$REBASE_AUTHOR" \
        "GATE BLOCKED for branch $BRANCH: stale with merge conflicts — auto-rebase cannot resolve. Conflicts: ${CONFLICT_FILES:-unknown}. Action required: ${_REBASE_ACTION_ADVICE}. Bead: $BEAD_ID" \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $REBASE_AUTHOR for rebase"
      REBASE_EVENT="dispatcher_needs_rebase"
      REBASE_VERDICT="NEEDS_REBASE (genuine merge conflict, author live, bounced)"
    elif [ "$REBASE_AUTHOR_ALIVE" = "1" ] && [ "$CONFLICT_KIND" = "transient" ]; then
      # gt-4tk5m fix: author is live but failure is TRANSIENT (worktree/push plumbing
      # race — e.g. author force-pushed a rebase while marker was queued and our
      # --force-with-lease was rejected). The branch may already be correctly rebased
      # by the author. Re-queue (with a rebase-attempt counter to sink it behind
      # healthy markers) so the next sweep re-reads the updated branch tip. No
      # needs-rebase bounce — that would tell the author to re-run /gate-done when
      # their branch is already fine, and silently drop it from the queue if they
      # don't (the catch-22 this bead fixes).
      NEXT_ATTEMPT=$((REBASE_ATTEMPT + 1))
      # ga-g0v96 (AC4): the attempt COUNTER now lives in gate:rebase-fail-count,
      # written on every transient failure; gate:exiled-tier5 (the tier-sinking
      # label) is only added once gate_should_exile_tier5 says the failure has
      # REPEATED — a single blip no longer costs queue position. ga-gpcx: still
      # remove the legacy/current tier5 names defensively (a marker exiled before
      # the 2026-07-17 rename may still carry the old one).
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:exiled-tier5:$REBASE_ATTEMPT"     -q 2>/dev/null || true
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:rebase-attempt:$REBASE_ATTEMPT"    -q 2>/dev/null || true
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:rebase-fail-count:$REBASE_ATTEMPT" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$MARKER_ID" "gate:rebase-fail-count:$NEXT_ATTEMPT"   -q 2>/dev/null || true
      _EXILE_THIS_ATTEMPT=$(gate_should_exile_tier5 "$NEXT_ATTEMPT" "$GATE_EXILE_AFTER_ATTEMPTS")
      if [ "$_EXILE_THIS_ATTEMPT" = "1" ]; then
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate:exiled-tier5:$NEXT_ATTEMPT" -q 2>/dev/null || true
      fi
      # ga-g0v96 (AC5): mirror the retry state onto the SOURCE bead too — this
      # state used to live ONLY as a label on the marker, and neither the
      # reporter nor the author ever saw it there.
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:rebase-retry:$REBASE_ATTEMPT" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:rebase-retry:$NEXT_ATTEMPT"   -q 2>/dev/null || true
      fi
      # ga-6dp9 (bug 3 of 3): the label add above is fire-and-forget — verify it
      # actually stuck instead of trusting it. A write that silently failed would
      # otherwise re-derive REBASE_ATTEMPT=0 next sweep and replay "attempt 1/3"
      # forever. A stuck counter means the retry cannot make progress by
      # construction, so treat it exactly like retries-exhausted: force the
      # escalation branch below instead of re-queueing again.
      if [ "$(gate_rebase_attempt_advanced "$NEXT_ATTEMPT" "$(read_rebase_attempt "$MARKER_ID")")" = "stuck" ]; then
        warn "Branch $BRANCH: gate:rebase-fail-count label write did not take effect (intended $NEXT_ATTEMPT) — forcing escalation to avoid an infinite attempt-1/3 loop."
        NEXT_ATTEMPT="$MAX_REBASE_ATTEMPTS"
      fi
      # ga-g0v96 (AC3): present the CAPTURED push diagnostic, and mark the
      # mechanism as a HYPOTHESIS rather than an established cause — mila-wa
      # proved the old "likely rebase-while-queued race, author may have
      # force-pushed" text asserted a mechanism that was chronologically
      # IMPOSSIBLE in the real incident this bead reports (push failed 2h before
      # the cited force-push could have happened).
      if [ -n "$AUTO_REBASE_PUSH_ERR" ]; then
        _PUSH_DIAG="push failed (exit=${AUTO_REBASE_PUSH_RC:-?}): $AUTO_REBASE_PUSH_ERR — cause not otherwise confirmed"
      else
        _PUSH_DIAG="push failed; cause not captured"
      fi
      if [ "$NEXT_ATTEMPT" -lt "$MAX_REBASE_ATTEMPTS" ]; then
        if [ "$_EXILE_THIS_ATTEMPT" = "1" ]; then
          warn "Branch $BRANCH: transient auto-rebase-fail (author $REBASE_AUTHOR live; attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS, exiled to tier5) — gate-status:queued for server-side retry."
          _TIER5_NOTE=" Carries gate:exiled-tier5:$NEXT_ATTEMPT so it sinks behind healthy markers (ga-q3ig2) — remove this label to re-anchor and rejoin the healthy queue."
        else
          warn "Branch $BRANCH: transient auto-rebase-fail (author $REBASE_AUTHOR live; attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS, still in the healthy queue) — gate-status:queued for server-side retry."
          _TIER5_NOTE=""
        fi
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:queued" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$MARKER_ID" "Gate auto-retry $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS (gt-4tk5m): branch $BRANCH hit a transient auto-rebase failure (${CONFLICT_FILES:-plumbing}) — $_PUSH_DIAG. Re-queued for next sweep; no /gate-done re-run needed.${_TIER5_NOTE}" 2>/dev/null || true
        # ga-6dp9 (gate-fix-2): same notify-identity fix as the bounce branches
        # above — REBASE_AUTHOR is this branch's own verified-alive identity.
        # ga-kyxih (AC4): a merge-commit-tip branch reaching THIS retry path
        # means the auto-merge attempt above (branch_tip_is_merge_commit())
        # itself hit trouble — no longer the common self-healing plumbing
        # blip the default "no action needed" wording assumes. Don't leave
        # the author waiting: tell them the deterministic fallback now, not
        # only after retries are exhausted. Non-merge-commit-tip branches
        # (the overwhelming majority of transient retries) keep the
        # original, correct "no action needed" wording unchanged.
        if [ "$BRANCH_TIP_IS_MERGE_COMMIT" = "1" ]; then
          gc --city "$GC_CITY" session nudge "$REBASE_AUTHOR" \
            "Gate auto-retry for branch $BRANCH (${BEAD_ID:-unknown}): auto-merge hit a transient failure (attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS) — re-queued for next sweep. Your branch's tip is already a merge commit (ga-kyxih), so if this keeps failing after $MAX_REBASE_ATTEMPTS attempts, don't wait: run 'git merge origin/$DEFAULT_BRANCH' into $BRANCH yourself and push." \
            --delivery wait-idle 2>/dev/null || true
        else
          gc --city "$GC_CITY" session nudge "$REBASE_AUTHOR" \
            "Gate auto-retry for branch $BRANCH (${BEAD_ID:-unknown}): transient rebase push race detected (attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS) — re-queued for next sweep. No action needed unless this keeps retrying." \
            --delivery wait-idle 2>/dev/null || true
        fi
        REBASE_EVENT="dispatcher_autorebase_retry_alive"
        REBASE_VERDICT="QUEUED (transient rebase race, author $REBASE_AUTHOR live, retry $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS)"
      else
        err "Branch $BRANCH: transient auto-rebase failure persists after $MAX_REBASE_ATTEMPTS attempts even with live author $REBASE_AUTHOR — escalating."
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$MARKER_ID" "Gate ESCALATED (gt-4tk5m): branch $BRANCH hit persistent transient auto-rebase failures ($MAX_REBASE_ATTEMPTS attempts) despite live author $REBASE_AUTHOR. Last attempt: $_PUSH_DIAG. Parked at needs-rebase for human/Mayor resolution." 2>/dev/null || true
        # ga-g0v96 (AC5): the retry saga is now terminal (bounced) — drop the
        # informational label from the source bead so it doesn't linger.
        [ -n "$BEAD_ID" ] && bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:rebase-retry:$NEXT_ATTEMPT" -q 2>/dev/null || true
        if [ -n "$BEAD_ID" ]; then
          bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
        fi
        # ga-6dp9 (gate-fix-2): same notify-identity fix — REBASE_AUTHOR, not $AUTHOR.
        gc --city "$GC_CITY" session nudge "$REBASE_AUTHOR" \
          "GATE ESCALATED for branch $BRANCH (${BEAD_ID:-unknown}): persistent transient auto-rebase failures after $MAX_REBASE_ATTEMPTS retries. Please check your branch and re-run /gate-done, or contact Mayor." \
          --delivery wait-idle 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate escalation: $BRANCH transient rebase race (live author, $MAX_REBASE_ATTEMPTS attempts)" \
          -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) hit persistent transient auto-rebase failures ($MAX_REBASE_ATTEMPTS attempts) even with live author $REBASE_AUTHOR. ${CONFLICT_FILES:-unknown}. Possible stuck push race or corrupt ref. Parked at needs-rebase. (gt-4tk5m)" 2>/dev/null \
          || warn "Could not mail Mayor for gate escalation on $BRANCH"
        REBASE_EVENT="dispatcher_needs_rebase_transient_escalated"
        REBASE_VERDICT="NEEDS_REBASE (persistent transient race, escalated after $MAX_REBASE_ATTEMPTS attempts)"
      fi
    elif [ "$CONFLICT_KIND" = "merge" ]; then
      # ga-q3ig2 IDEAL SKIP: a GENUINE merge conflict vs current main is
      # deterministic — re-running the same rebase next sweep produces the same
      # conflict, and the author session is gone so no one will resolve it. The
      # old bounded-retry path (below) burned MAX_REBASE_ATTEMPTS sweeps re-failing
      # before escalating; with the broken marker keeping the oldest created_at it
      # also head-of-line-blocked the queue. Go STRAIGHT to needs-rebase + escalate
      # so the marker leaves the active queue on its FIRST determination and the
      # gate-health-monitor / a fresh re-dispatch can re-anchor or rebuild it.
      err "Branch $BRANCH: genuine merge conflict vs $DEFAULT_BRANCH, author dead/empty — immediate needs-rebase (no retry; conflict is deterministic)."
      bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
      # ga-kyxih (AC2): name the merge-commit-tip cause distinctly when it
      # applies (see branch_tip_is_merge_commit() above). No live author to
      # notify here (AC4 targets the live-author paths above) — this only
      # sharpens the marker's own diagnostic text for whoever triages it.
      if [ "$BRANCH_TIP_IS_MERGE_COMMIT" = "1" ]; then
        _REBASE_REANCHOR_ADVICE="This branch's own tip is already a merge commit (ga-kyxih) — re-anchoring means 'git merge origin/$DEFAULT_BRANCH' into $BRANCH, not a rebase."
      else
        _REBASE_REANCHOR_ADVICE="Needs re-anchor/rebuild or a Mayor decision."
      fi
      bd -C "$GC_CITY" comment "$MARKER_ID" "Gate SKIPPED + ESCALATED (ga-q3ig2): branch $BRANCH has a genuine, deterministic merge conflict (${CONFLICT_FILES:-unknown}) vs main ($MAIN_HEAD_SHA) and no live author session exists. A server-side rebase retry would fail identically, so the marker is parked at needs-rebase immediately (NOT re-queued) — it no longer blocks the queue. $_REBASE_REANCHOR_ADVICE" 2>/dev/null || true
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
      fi
      gc --city "$GC_CITY" mail send mayor \
        -s "Gate escalation: $BRANCH genuine conflict (no live author)" \
        -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) has a genuine, deterministic conflict vs origin/$DEFAULT_BRANCH ($MAIN_HEAD_SHA). Conflicting: ${CONFLICT_FILES:-unknown}. Author session is gone — gate cannot self-heal, and a rebase retry would fail identically. Parked at needs-rebase (not blocking the queue). Needs a manual re-anchor/rebuild or a decision." 2>/dev/null \
        || warn "Could not mail Mayor for gate escalation on $BRANCH"
      REBASE_EVENT="dispatcher_needs_rebase_immediate"
      REBASE_VERDICT="NEEDS_REBASE (genuine conflict, dead author — immediate skip)"
    else
      # Dead/empty author + TRANSIENT auto-rebase failure (worktree/push plumbing).
      # main may settle on a later sweep, so a bounded server-side retry is worth
      # it; then escalate. (Genuine merge conflicts take the immediate-skip branch
      # above — they never reach here.)
      NEXT_ATTEMPT=$((REBASE_ATTEMPT + 1))
      # ga-g0v96 (AC4): same decoupled counter/exile scheme as the live-author
      # branch above — gate:rebase-fail-count is the counter, gate:exiled-tier5
      # only applies once gate_should_exile_tier5 confirms the failure repeated.
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:exiled-tier5:$REBASE_ATTEMPT"     -q 2>/dev/null || true
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:rebase-attempt:$REBASE_ATTEMPT"    -q 2>/dev/null || true
      bd -C "$GC_CITY" label remove "$MARKER_ID" "gate:rebase-fail-count:$REBASE_ATTEMPT" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$MARKER_ID" "gate:rebase-fail-count:$NEXT_ATTEMPT"   -q 2>/dev/null || true
      _EXILE_THIS_ATTEMPT=$(gate_should_exile_tier5 "$NEXT_ATTEMPT" "$GATE_EXILE_AFTER_ATTEMPTS")
      if [ "$_EXILE_THIS_ATTEMPT" = "1" ]; then
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate:exiled-tier5:$NEXT_ATTEMPT" -q 2>/dev/null || true
      fi
      # ga-g0v96 (AC5): mirror the retry state onto the SOURCE bead (see the
      # matching comment at the live-author call site above).
      if [ -n "$BEAD_ID" ]; then
        bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:rebase-retry:$REBASE_ATTEMPT" -q 2>/dev/null || true
        bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:rebase-retry:$NEXT_ATTEMPT"   -q 2>/dev/null || true
      fi
      # ga-6dp9 (bug 3 of 3): verify the label write actually stuck (see the
      # matching comment at the live-author call site above) — a stuck counter
      # here would otherwise replay "attempt 1/3, dead author" forever instead
      # of ever reaching the retry_dead circuit-break below.
      if [ "$(gate_rebase_attempt_advanced "$NEXT_ATTEMPT" "$(read_rebase_attempt "$MARKER_ID")")" = "stuck" ]; then
        warn "Branch $BRANCH: gate:rebase-fail-count label write did not take effect (intended $NEXT_ATTEMPT) — forcing escalation to avoid an infinite attempt-1/3 loop."
        NEXT_ATTEMPT="$MAX_REBASE_ATTEMPTS"
      fi
      if [ "$NEXT_ATTEMPT" -lt "$MAX_REBASE_ATTEMPTS" ]; then
        if [ "$_EXILE_THIS_ATTEMPT" = "1" ]; then
          warn "Branch $BRANCH: transient auto-rebase-fail, author dead/empty (attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS, exiled to tier5) — gate-status:queued for server-side retry."
          _TIER5_NOTE=" Carries gate:exiled-tier5:$NEXT_ATTEMPT so it sinks behind healthy markers (ga-q3ig2) — remove this label to re-anchor and rejoin the healthy queue."
        else
          warn "Branch $BRANCH: transient auto-rebase-fail, author dead/empty (attempt $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS, still in the healthy queue) — gate-status:queued for server-side retry."
          _TIER5_NOTE=""
        fi
        bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:queued" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$MARKER_ID" "Gate auto-retry $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS: branch $BRANCH hit a transient auto-rebase failure (${CONFLICT_FILES:-plumbing}) and the author session is gone. Queued for server-side retry on next sweep (NOT stranded on a dead author).${_TIER5_NOTE}" 2>/dev/null || true
        REBASE_EVENT="dispatcher_autorebase_retry"
        REBASE_VERDICT="QUEUED (retry $NEXT_ATTEMPT/$MAX_REBASE_ATTEMPTS, dead author)"
      else
        # ga-acb: retry_dead circuit-break — retries exhausted + dead author.
        # Previously this set gate-status:needs-rebase, which the guard's Vector A
        # does NOT reclaim (needs-rebase is a terminal label the guard ignores), but
        # the gate-health-monitor leaves it as an open error marker AND the guard's
        # own reclaim path could re-ready it if the marker somehow regained claimed/
        # dispatching. Promote to gate:needs-human on the SOURCE BEAD so Pilot knows
        # not to re-dispatch, and park the marker permanently at gate-status:error.
        _ACB_RETRY=$(gate_circuit_break_check "retry_dead" "" "$REBASE_AUTHOR_ALIVE" "$NEXT_ATTEMPT" "$MAX_REBASE_ATTEMPTS" "$GATE_REBASE_AHEAD_MAX" "$REBASE_AHEAD_CAP_ONLY")
        if [ "$_ACB_RETRY" != "ok" ]; then
          err "Branch $BRANCH: retries exhausted ($NEXT_ATTEMPT >= $MAX_REBASE_ATTEMPTS) + dead author — ga-acb circuit-break (${_ACB_RETRY})."
          bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:error" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$MARKER_ID" "ga-acb AUTO-CIRCUIT-BREAK (${_ACB_RETRY}): branch $BRANCH could not auto-rebase (${CONFLICT_FILES:-unknown}) vs main ($MAIN_HEAD_SHA) after $MAX_REBASE_ATTEMPTS attempts, and no live author session exists. Marker permanently parked at gate-status:error. Source bead $BEAD_ID set gate:needs-human so Pilot does NOT re-dispatch." 2>/dev/null || true
          if [ -n "$BEAD_ID" ]; then
            bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human"           -q 2>/dev/null || true
            bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human:technical" -q 2>/dev/null || true
            bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"            -q 2>/dev/null || true
            bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"           -q 2>/dev/null || true
            # ga-g0v96 (AC5): retry saga is now terminal (circuit-broken) — drop
            # the informational label so it doesn't linger under gate:needs-human.
            bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:rebase-retry:$NEXT_ATTEMPT" -q 2>/dev/null || true
            bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""                           -q 2>/dev/null || true
            bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-acb AUTO-CIRCUIT-BREAK (${_ACB_RETRY}): branch $BRANCH failed auto-rebase $MAX_REBASE_ATTEMPTS times with no live author (marker $MARKER_ID). Set gate:needs-human; story:in-flight + pilot:dispatched stripped (Pilot lane slot freed). Human or Mayor must re-anchor or close." 2>/dev/null || true
          fi
          gc --city "$GC_CITY" mail send mayor \
            -s "Gate circuit-break: $BRANCH retries exhausted + dead author (${BEAD_ID:-unknown})" \
            -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) could not auto-rebase vs origin/$DEFAULT_BRANCH ($MAIN_HEAD_SHA). ${CONFLICT_FILES:-unknown}. Auto-rebase failed $MAX_REBASE_ATTEMPTS times and the author session is gone. Auto-circuit-broken (ga-acb): marker parked at gate-status:error; source bead set gate:needs-human. Human or Mayor decision required." 2>/dev/null \
            || warn "Could not mail Mayor for retry_dead circuit-break on $BRANCH"
          # ga-u4yi: durable mail to the AUTHOR too (see no_branch site above for why).
          if [ -n "$AUTHOR" ]; then
            gc --city "$GC_CITY" mail send "$AUTHOR" \
              -s "Gate needs-human: $BRANCH could not auto-rebase ($BEAD_ID)" \
              -m "Your branch $BRANCH (bead $BEAD_ID) could not be auto-rebased onto origin/$DEFAULT_BRANCH after $MAX_REBASE_ATTEMPTS attempts, and your session was not live to resolve conflicts. Source bead $BEAD_ID is now labeled gate:needs-human: the Pilot will NOT re-dispatch it, and any further /gate-done resubmission will be silently parked until a human resolves this. A human or the Mayor must re-anchor the work." \
              2>/dev/null || warn "Could not mail author $AUTHOR for retry_dead circuit-break on $BRANCH"
          fi
          REBASE_EVENT="dispatcher_circuit_break_retry_dead"
          REBASE_VERDICT="CIRCUIT-BREAK (retry_dead: ${MAX_REBASE_ATTEMPTS} attempts exhausted, dead author)"
        else
          # GATE_AUTO_CIRCUIT_BREAK=0: fall through to legacy needs-rebase escalation.
          err "Branch $BRANCH: transient auto-rebase failure persists after $MAX_REBASE_ATTEMPTS server-side attempts, author dead/empty — escalating to Mayor."
          bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$MARKER_ID" "Gate ESCALATED: branch $BRANCH could not auto-rebase (${CONFLICT_FILES:-unknown}) vs main ($MAIN_HEAD_SHA) after $MAX_REBASE_ATTEMPTS attempts, and no live author session exists. Escalated to Mayor for resolution." 2>/dev/null || true
          if [ -n "$BEAD_ID" ]; then
            bd -C "$BEAD_CITY" label add "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
          fi
          gc --city "$GC_CITY" mail send mayor \
            -s "Gate escalation: $BRANCH stranded conflict (no live author)" \
            -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) could not auto-rebase vs origin/$DEFAULT_BRANCH ($MAIN_HEAD_SHA). ${CONFLICT_FILES:-unknown}. Auto-rebase failed $MAX_REBASE_ATTEMPTS times and the author session is gone — gate cannot self-heal. Needs a manual rebase or a decision." 2>/dev/null \
            || warn "Could not mail Mayor for gate escalation on $BRANCH"
          REBASE_EVENT="dispatcher_needs_rebase_escalated"
          REBASE_VERDICT="NEEDS_REBASE (escalated to Mayor after $MAX_REBASE_ATTEMPTS attempts)"
        fi
      fi
    fi

    # wa-uthi: non-terminal (retryable / escalated) — no push to Athos.
    log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH — $REBASE_VERDICT."

    mkdir -p "$(dirname "$QG_LOG")"
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg branch "$BRANCH" \
      --arg bead "$BEAD_ID" \
      --arg rig "${RIG:-unknown}" \
      --arg marker "$MARKER_ID" \
      --arg author "$AUTHOR" \
      --arg main_sha "$MAIN_HEAD_SHA" \
      --arg conflicts "${CONFLICT_FILES:-unknown}" \
      --arg event "$REBASE_EVENT" \
      '{ts: $ts, event: $event, branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author, main_sha: $main_sha, conflicts: $conflicts}' \
      >> "$QG_LOG" 2>/dev/null || true

    if [ "$(gate_marker_status_ensure "$MARKER_ID" "the auto-rebase decision (merge-conflict/transient-retry/circuit-break)")" = "repaired" ]; then
      warn "ga-kgtiw SELF-HEAL: marker $MARKER_ID had no gate-status label after the auto-rebase decision — self-heal force-wrote and verified gate-status:error (see marker comment + Mayor mail for detail)."
    fi
    log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$REBASE_VERDICT ==="
    exit 0
  fi
fi

log "  Branch $BRANCH is current with $DEFAULT_BRANCH — stale-base check passed."

# ── Step 5: Code-vs-non-code tier classification ──────────────────────────────
#
# NON-CODE: ALL changed files are ONLY in docs/, tests/ (test_*.py, *_test.py,
# *_test.go, *.test.*, spec files), or pure data-config (*.json, *.yaml, *.toml,
# *.md, *.csv, *.txt under docs/ or data/).
#
# CODE: ANY file outside the above set → CODE tier.
#
# When classifier is uncertain or the gate policy itself is modified → CODE tier.
# This is the "escalate up, never down" rule from review-merge-policy.md.

CHANGED_FILES=$(git_rig diff --name-only "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null || echo "")

# ── ga-ir033: reject double-prefixed (mis-rooted-worktree) paths ──────────────
# A build from a worktree created *inside* a nested city repo (e.g. gascity's
# `.gascity-gastown-hq`, a tracked SUBDIR of the outer monorepo, not its own
# git root) can silently write files under a path with a directory segment
# repeated back-to-back (`.gascity-gastown-hq/.gascity-gastown-hq/...`) — see
# git-worktree-nested-city-path-prefix-gotcha. Such a file is fully real to
# git (stable line numbers, reviewable) but is NEVER read by any deploy/
# launchd job — a green gate on it is a false-done: reviewed, merged, nothing
# shipped. Reject before reviewers are ever dispatched, before any other
# Step-5 work runs. Match is BRE (no -E): this grep is BSD/macOS grep, whose
# -E does not support backreferences — verified empirically (ga-ir033).
DOUBLE_PREFIXED_FILES=$(printf '%s\n' "$CHANGED_FILES" | grep '\(^\|/\)\([^/]*\)/\2\(/\|$\)' || echo "")
if [ -n "$DOUBLE_PREFIXED_FILES" ]; then
  err "Branch $BRANCH: double-prefixed (mis-rooted-worktree) path(s) detected — rejecting before dispatch:
$DOUBLE_PREFIXED_FILES"
  bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:error" -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$MARKER_ID" "ga-ir033 REJECTED before reviewer dispatch: branch $BRANCH contains file path(s) with a directory segment repeated back-to-back — the signature of a mis-rooted nested-worktree build (git-worktree-nested-city-path-prefix-gotcha):
$DOUBLE_PREFIXED_FILES
These are almost certainly ghost duplicates of a correctly-placed file one level up (e.g. .gascity-gastown-hq/.gascity-gastown-hq/foo instead of .gascity-gastown-hq/foo) and are never read by any deploy/launchd job. Verify 'git rev-parse --show-toplevel' resolves to the true repo root and target paths relative to THAT before building; remove the ghost path(s); re-run /gate-done." 2>/dev/null || true
  if [ -n "$BEAD_ID" ]; then
    bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human"           -q 2>/dev/null || true
    bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:needs-human:technical" -q 2>/dev/null || true
    bd -C "$BEAD_CITY" label remove "$BEAD_ID" "story:in-flight"            -q 2>/dev/null || true
    bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"             -q 2>/dev/null || true
    bd -C "$BEAD_CITY" label remove "$BEAD_ID" "pilot:dispatched"           -q 2>/dev/null || true
    bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""                           -q 2>/dev/null || true
    bd -C "$BEAD_CITY" comment "$BEAD_ID" "ga-ir033 AUTO-REJECT: branch $BRANCH (marker $MARKER_ID) has double-prefixed ghost path(s), a mis-rooted-worktree signature:
$DOUBLE_PREFIXED_FILES
Set gate:needs-human; story:in-flight + gate:reviewing + pilot:dispatched stripped (Pilot lane slot freed). Fix the build topology, remove the ghost path(s), resubmit." 2>/dev/null || true
  fi
  gc --city "$GC_CITY" mail send mayor \
    -s "Gate reject: $BRANCH has mis-rooted-worktree ghost path(s) (${BEAD_ID:-unknown})" \
    -m "Branch $BRANCH (bead ${BEAD_ID:-unknown}, rig ${RIG:-unknown}, marker $MARKER_ID) was rejected before reviewer dispatch (ga-ir033): file path(s) with a directory segment repeated back-to-back were found — a mis-rooted nested-worktree build signature:
$DOUBLE_PREFIXED_FILES
Source bead set gate:needs-human. This class of bug lets a ghost file pass review while the real target file stays untouched (false-done)." 2>/dev/null \
    || warn "Could not mail Mayor for ga-ir033 double-prefix rejection on $BRANCH"
  if [ -n "$AUTHOR" ]; then
    gc --city "$GC_CITY" mail send "$AUTHOR" \
      -s "Gate needs-human: $BRANCH has mis-rooted-worktree ghost path(s)" \
      -m "Your branch $BRANCH (bead ${BEAD_ID:-unknown}) was rejected before reviewer dispatch: file path(s) with a directory segment repeated back-to-back were found:
$DOUBLE_PREFIXED_FILES
This is the signature of a mis-rooted nested-worktree build (git-worktree-nested-city-path-prefix-gotcha) — the real target file was probably never touched. Source bead is now labeled gate:needs-human: Pilot will NOT re-dispatch it, and further /gate-done resubmission will be silently parked until this is resolved. Verify 'git rev-parse --show-toplevel', fix the ghost path(s), and resubmit." \
      2>/dev/null || warn "Could not mail author $AUTHOR for ga-ir033 double-prefix rejection on $BRANCH"
  fi
  mkdir -p "$(dirname "$QG_LOG")"
  jq -c -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$BRANCH" \
    --arg bead "$BEAD_ID" \
    --arg rig "${RIG:-unknown}" \
    --arg marker "$MARKER_ID" \
    --arg author "$AUTHOR" \
    --arg event "dispatcher_reject_double_prefixed_path" \
    --arg files "$DOUBLE_PREFIXED_FILES" \
    '{ts: $ts, event: $event, branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author, files: $files}' \
    >> "$QG_LOG" 2>/dev/null || true
  log "=== Dispatcher sweep complete: branch=$BRANCH verdict=REJECTED (ga-ir033 double-prefixed path) ==="
  exit 0
fi

# ── ga-ltr3c: scale this run's verdict timeout by its diff size ───────────────
# CHANGED_FILES is already in hand; add the changed-line count (insertions +
# deletions via --numstat, ignoring binary "-" rows) and scale VERDICT_TIMEOUT_
# MINUTES so a large-but-green package isn't killed as a "zombie" before its
# reviewer can emit a verdict. Fail-safe: any git/parse failure leaves the counts
# at 0 → the scaler returns the unchanged base timeout (today's behavior).
DIFF_FILE_COUNT=$(printf '%s\n' "$CHANGED_FILES" | grep -c . 2>/dev/null || echo 0)
DIFF_LINE_COUNT=$(git_rig diff --numstat "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null \
  | awk '{ if ($1 ~ /^[0-9]+$/) s += $1; if ($2 ~ /^[0-9]+$/) s += $2 } END { print s + 0 }' \
  || echo 0)
case "$DIFF_FILE_COUNT" in ''|*[!0-9]*) DIFF_FILE_COUNT=0 ;; esac
case "$DIFF_LINE_COUNT" in ''|*[!0-9]*) DIFF_LINE_COUNT=0 ;; esac
_VT_BASE="$VERDICT_TIMEOUT_MINUTES"
VERDICT_TIMEOUT_MINUTES=$(gate_scaled_verdict_timeout "$_VT_BASE" "$DIFF_FILE_COUNT" "$DIFF_LINE_COUNT")
if [ "$VERDICT_TIMEOUT_MINUTES" != "$_VT_BASE" ]; then
  log "ga-ltr3c: scaled verdict timeout ${_VT_BASE}m → ${VERDICT_TIMEOUT_MINUTES}m for diff (${DIFF_FILE_COUNT} files, ${DIFF_LINE_COUNT} lines; cap=${VERDICT_TIMEOUT_MAX_MINUTES}m)."
fi

# ga-evjs2: scale the frozen-reviewer staleness window by the SAME diff size, so a
# reviewer reading a large diff is not false-reaped at the fixed 300s (→ respawn
# death-spiral). Computed here (diff known) and consumed by the reconvene staleness
# probe below. Falls back to REVIEWER_STALE_SECS for any path that skips this block.
REVIEWER_STALE_SECS_SCALED=$(gate_scaled_reviewer_stale "$REVIEWER_STALE_SECS" "$DIFF_FILE_COUNT" "$DIFF_LINE_COUNT")
if [ "$REVIEWER_STALE_SECS_SCALED" != "$REVIEWER_STALE_SECS" ]; then
  log "ga-evjs2: scaled reviewer-staleness window ${REVIEWER_STALE_SECS}s → ${REVIEWER_STALE_SECS_SCALED}s for diff (${DIFF_FILE_COUNT} files, ${DIFF_LINE_COUNT} lines; cap=${REVIEWER_STALE_MAX_SECS}s)."
fi

TIER="CODE"
if [ -n "$CHANGED_FILES" ]; then
  NON_CODE_PATTERN='^(docs/|tests?/|test_|.*_test\.(py|go|js|ts)|.*\.test\.(js|ts|jsx|tsx)|.*\.spec\.(js|ts)|.*\.(md|txt|csv)$|\.github/)'
  ANY_CODE=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! echo "$f" | grep -qE "$NON_CODE_PATTERN"; then
      ANY_CODE=1
      break
    fi
  done <<< "$CHANGED_FILES"
  if [ "$ANY_CODE" = "0" ]; then
    TIER="NON-CODE"
  fi
fi

# Policy self-protection: if the gate policy or classifier is being modified,
# escalate to CODE tier regardless.
POLICY_FILES=$(echo "$CHANGED_FILES" | grep -E "(review-merge-policy|quality-gate)" || echo "")
if [ -n "$POLICY_FILES" ]; then
  TIER="CODE"
  warn "Gate policy file in diff — escalating to CODE tier (self-protection)."
fi

case "$TIER" in
  CODE)     REQUIRED_REVIEWERS="${GATE_CODE_REVIEWERS:-2}" ;;
  NON-CODE) REQUIRED_REVIEWERS=1 ;;
  *)        REQUIRED_REVIEWERS="${GATE_CODE_REVIEWERS:-2}" ;;
esac

log "Tier: $TIER  required_reviewers: $REQUIRED_REVIEWERS"

# ── Step 5b (ga-dupnv, bug 1): live-sibling-run guard — SAFETY NET ────────────
# A marker can be claimed twice for the SAME branch: the dispatcher dies mid-run
# (Terminated/SIGTERM/launchd overlap) leaving the marker gate-status:dispatching,
# Step 0a re-queues it after its TTL, and a later sweep re-claims it — OR a re-gate
# mints a second marker while the first run is still live. Either way TWO gate-runs
# for ONE branch then race, and the loser (e.g. a verdict-TIMEOUT) writes a terminal
# FAIL onto the source bead, clobbering the healthy sibling (observed: dup run
# ga-wisp-4wa97q false-failed wa-86jr while ga-wisp-mzxm9h had a live reviewer).
# supersede_sibling_runs only fires at TERMINAL time and made whichever run finished
# FIRST authoritative — i.e. it superseded the HEALTHY run. Here, BEFORE creating
# our run, we defer to any gate-run already running for THIS branch. Branch is the
# correct key (NOT source-bead: wa-86jr and wa-86jr-reland share bead wa-86jr).
#
# ga-991au round 2: this is now the SECOND of two identical checks — the PRIMARY
# one runs at Step 4b-1, before Step 4c's rebase/force-push ever touches the
# branch. This copy stays as a safety net for the narrower residual window
# where a sibling run starts DURING Step 4c/Step 5 (auto-rebase, tier
# classification) — rare, but a real gap the early check alone cannot close.
if [ "${GATE_SIBLING_GUARD_ENABLED:-1}" = "1" ]; then
  SIBLING_VERDICT=$(live_sibling_run_for_branch "$BRANCH" || echo "")
  case "$SIBLING_VERDICT" in
    "LIVE "*)
      SIBLING_RUN_ID="${SIBLING_VERDICT#LIVE }"
      log "Live sibling gate-run $SIBLING_RUN_ID already running for branch $BRANCH — YIELDING (one branch = one authoritative run). NOT spawning a duplicate."
      # Leave the marker in gate-status:dispatching (do NOT re-queue): re-queuing
      # would let this same (oldest) marker be re-selected every sweep and
      # head-of-line-block other branches. Step 0a re-queues it after its TTL if
      # the sibling never terminates, so the branch is never permanently stranded.
      # We touch NEITHER the source bead NOR any verdict, so the duplicate path can
      # never write a terminal FAIL over the healthy sibling. (Idempotent, fail-safe.)
      log "  Marker $MARKER_ID left dispatching; Step 0a TTL re-queues it once the sibling terminates."
      log "=== Dispatcher sweep complete: branch=$BRANCH verdict=YIELDED (live sibling $SIBLING_RUN_ID) ==="
      # ga-991au: this branch is busy, but the other queued markers are not. Try
      # the next one in THIS sweep instead of burning the whole cadence on a
      # branch we already know we cannot touch. Safe to re-enter: our marker
      # stayed in gate-status:dispatching just above, and Step 0b only selects
      # gate-status:queued — so the next round cannot pick it again.
      gate_continue_or_exit "live-sibling"
      ;;
    "STALE "*)
      SIBLING_RUN_ID="${SIBLING_VERDICT#STALE }"
      warn "Stale sibling gate-run $SIBLING_RUN_ID for branch $BRANCH (older than ${SIBLING_RUN_STALE_MINUTES}m — its dispatcher died mid-run and never drove it terminal). Superseding it and proceeding with a fresh run."
      set_gate_status "$SIBLING_RUN_ID" "superseded" 2>/dev/null || true
      bd -C "$GC_CITY" comment "$SIBLING_RUN_ID" "Dispatcher: superseded as STALE (> ${SIBLING_RUN_STALE_MINUTES}m — dispatcher died mid-run) so a fresh gate-run for branch $BRANCH can take over. (ga-dupnv live-sibling guard)" 2>/dev/null || true
      bd -C "$GC_CITY" close "$SIBLING_RUN_ID" -r "gate-run superseded (stale sibling) — fresh run for branch $BRANCH takes over. (ga-dupnv)" 2>/dev/null || true
      ;;
  esac
fi

# ── Step 6: Create gate-run tracking bead ────────────────────────────────────

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GATE_START_EPOCH=$(date +%s)

GATE_RUN_ID=$(bd -C "$GC_CITY" create \
  "gate-run: $BRANCH ($BEAD_ID)" \
  -t chore --ephemeral \
  -l type:quality-gate-run \
  -l gate-status:running \
  -l "source-bead:$BEAD_ID" \
  -d "Autonomous gate run for $BRANCH.
source_bead: $BEAD_ID
author: $AUTHOR
rig: $RIG
branch: $BRANCH
tier: $TIER
required_reviewers: $REQUIRED_REVIEWERS
branch_sha: $BRANCH_SHA
marker_id: $MARKER_ID
started_at: $NOW
verdict_timeout_minutes: $VERDICT_TIMEOUT_MINUTES" \
  --json 2>/dev/null | jq -r '.id // empty' || echo "")

if [ -z "$GATE_RUN_ID" ]; then
  warn "Could not create gate-run tracking bead. Continuing without it."
  GATE_RUN_ID="unknown"
fi
log "Gate-run bead: $GATE_RUN_ID"
# ga-ub8yq: one self-contained record joining run+bead+size, keyed by GATE_RUN_ID
# (unique per attempt) so gate-review-size-report.py can pair each attempt with
# its own "Gate run complete: gate_run=..." verdict line without guessing from
# bead/branch substrings. Skip when GATE_RUN_ID is the "unknown" sentinel — every
# failed-to-create run would share that key, which would silently re-collide
# unrelated runs' sizes, the exact bug class this line exists to eliminate.
if [ "$GATE_RUN_ID" != "unknown" ]; then
  log "Gate-run size: gate_run=$GATE_RUN_ID bead=$BEAD_ID files=$DIFF_FILE_COUNT lines=$DIFF_LINE_COUNT"
fi

# ── Step 7: Create verdict beads (one per reviewer) ───────────────────────────
# Each reviewer session writes its verdict to its personal verdict bead:
#   - Closes bead with label "verdict:PASS" or "verdict:FAIL"
#   - Posts a comment with the reasons (required for FAIL)
#
# The dispatcher polls these beads for closed status + verdict label.

DIFF_SUMMARY=$(git_rig diff --stat "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | tail -5 | tr '\n' ' ' | cut -c1-300 || true)

# ga-p4g6: the old `head -2000` truncation sliced through diff hunks mid-file
# AND the header unconditionally said "FULL DIFF (first 2000 lines)" — "full"
# and "silently truncated at 45%" rendered as IDENTICAL text, so a reviewer
# trusting the header had no way to know 9 of 20 changed files (including the
# one with the real bug) were never shown. Measured impact: 14% of live
# branches (3/21 sampled) truncate silently; the worst cases show reviewers as
# little as 25-38% of the actual change.
#
# Fix: capture the full diff ONCE (avoid a 2nd/3rd `git diff` invocation), and
# if it exceeds the budget, rebuild it by walking $CHANGED_FILES in order and
# including each file's diff WHOLE — stopping before the file that would blow
# the budget, never inside one. The header then states real numbers and names
# every omitted file, so "I reviewed the change" and "I reviewed part of the
# change" can no longer produce the same text.
#
# Note: "|| true" suppresses SIGPIPE (exit 141) if a downstream consumer of
# this output truncates under pipefail — kept from the original for parity.
DIFF_RAW=$(git_rig diff "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null || true)
if [ -z "$DIFF_RAW" ]; then
  DIFF_RAW_TOTAL_LINES=0
else
  DIFF_RAW_TOTAL_LINES=$(printf '%s\n' "$DIFF_RAW" | wc -l | tr -d ' ')
fi

if [ "$DIFF_RAW_TOTAL_LINES" -le "$GATE_DIFF_LINE_BUDGET" ]; then
  DIFF_FULL="$DIFF_RAW"
  DIFF_HEADER="FULL DIFF (complete — $DIFF_RAW_TOTAL_LINES lines across $DIFF_FILE_COUNT file(s), nothing omitted):"
else
  DIFF_FULL=""
  _DIFF_SHOWN_LINES=0
  _DIFF_SHOWN_FILES=0
  DIFF_OMITTED_FILES=""
  while IFS= read -r _df; do
    [ -z "$_df" ] && continue
    _FILE_DIFF=$(git_rig diff "origin/$DEFAULT_BRANCH...origin/$BRANCH" -- "$_df" 2>/dev/null || true)
    _FILE_DIFF_LINES=$(printf '%s\n' "$_FILE_DIFF" | wc -l | tr -d ' ')
    # Always take at least the first file whole (even if it alone exceeds the
    # budget) — one complete file beats zero, and this still never cuts a hunk.
    if [ $((_DIFF_SHOWN_LINES + _FILE_DIFF_LINES)) -le "$GATE_DIFF_LINE_BUDGET" ] || [ "$_DIFF_SHOWN_FILES" = "0" ]; then
      DIFF_FULL="${DIFF_FULL}${_FILE_DIFF}
"
      _DIFF_SHOWN_LINES=$((_DIFF_SHOWN_LINES + _FILE_DIFF_LINES))
      _DIFF_SHOWN_FILES=$((_DIFF_SHOWN_FILES + 1))
    else
      DIFF_OMITTED_FILES="${DIFF_OMITTED_FILES}  - ${_df}
"
    fi
  done <<< "$CHANGED_FILES"

  if [ "$IS_CONTAINER_RIG" = "1" ]; then
    DIFF_ESCAPE_HATCH_CMD="git --git-dir=$GIT_DIR_PATH diff origin/$DEFAULT_BRANCH...origin/$BRANCH"
  else
    DIFF_ESCAPE_HATCH_CMD="cd $RIG_PATH && git diff origin/$DEFAULT_BRANCH...origin/$BRANCH"
  fi

  DIFF_HEADER="PARTIAL DIFF — showing $_DIFF_SHOWN_FILES of $DIFF_FILE_COUNT files ($_DIFF_SHOWN_LINES of $DIFF_RAW_TOTAL_LINES total diff lines). DO NOT treat the omitted files below as reviewed — you have not seen them:
OMITTED FILES ($((DIFF_FILE_COUNT - _DIFF_SHOWN_FILES))):
${DIFF_OMITTED_FILES}To review the FULL diff yourself: $DIFF_ESCAPE_HATCH_CMD"
fi

VERDICT_BEAD_IDS=()
SESSION_IDS=()
# ga-noxbv: parallel arrays (index-aligned with the two above) backing the
# post-spawn ACK-verification pass. REVIEW_TASKS keeps each reviewer's exact task
# text so it can be re-queued; REVIEWER_PEEK_BASELINE snapshots each session's
# terminal BEFORE the task lands (new output later = the reviewer came alive);
# REVIEWER_ACKED tracks per-reviewer delivery confirmation.
REVIEW_TASKS=()
REVIEWER_PEEK_BASELINE=()
REVIEWER_ACKED=()

# ── ga-zl277: guaranteed reviewer-session cleanup on EVERY exit path ───────────
# cleanup_reviewer_sessions() itself is now hoisted (before Phase C, ga-eqjo) so
# a Phase-C-only sweep — one that finalizes an earlier run but claims NO new
# marker, so this Step 7 never executes — still has it defined when
# gate_finalize_run's Step 9 calls it. Reset the dedup flag here, fresh, for
# THIS claim's own cleanup lifecycle: Phase C (just above, same sweep) may have
# already driven it to 1 while finalizing a DIFFERENT, earlier-claimed run.
_gate_cleanup_done=0
trap cleanup_reviewer_sessions EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

log "Spawning $REQUIRED_REVIEWERS independent reviewer session(s) ..."

for i in $(seq 1 $REQUIRED_REVIEWERS); do
  # ga-cvhoj: reviewer 1 spawns FIRST, immediately after the dispatcher's own
  # Dolt-heavy setup (Step 0a janitors, fetch/rebase, stale-base check, diff) — so
  # its `gc prime` boot hit peak Dolt and ~100% stillborn'd ("no live reviewer →
  # dispatcher abandoned it" → zombie run → re-dispatch loop), while reviewer 2+
  # got the ga-mepb0 BETWEEN-spawn stagger and survived. The existing stagger
  # (below) only pauses between reviewers, never before #1. Give the FIRST
  # reviewer the SAME settle window so its boot lands in calmer Dolt too. Uses the
  # same GATE_SPAWN_STAGGER_SECS knob (0 disables).
  if [ "$i" = "1" ] && [ "${GATE_SPAWN_STAGGER_SECS:-0}" -gt 0 ] 2>/dev/null; then
    log "  Spawn stagger: settling ${GATE_SPAWN_STAGGER_SECS}s before reviewer 1 (ga-cvhoj — let the setup Dolt-burst subside before gc prime)"
    sleep "$GATE_SPAWN_STAGGER_SECS" || true
  fi
  REVIEWER_LENS=""
  case "$i" in
    1) REVIEWER_LENS="CORRECTNESS: focus on logic errors, edge cases, off-by-one bugs, null/empty handling, error propagation, and incorrect assumptions. Be adversarial. (The ga-p5q3 third-state check now lives in the reviewer prompt template as a MANDATORY dimension for ALL lenses — ga-31ac, mila-wa. Do not duplicate it here: saying it twice dilutes both.)" ;;
    2) REVIEWER_LENS="SECURITY & ROBUSTNESS: focus on injection risks, unsafe eval/exec, credentials in code, path traversal, race conditions, resource leaks, and missing input validation." ;;
    3) REVIEWER_LENS="DESIGN & MAINTAINABILITY: focus on architectural concerns, code duplication, missing tests, test quality, unclear naming, violation of existing conventions, and tech debt introduced." ;;
  esac

  # Create a verdict bead for this reviewer.
  # NOTE: deliberately NOT --ephemeral. The reviewer's durable-pull channel
  # (ga-67hae) is `gc bd list --assignee=$GC_SESSION_NAME -l type:quality-gate-verdict`,
  # and `bd list` EXCLUDES ephemeral beads by default. The live bd (v1.0.5) has NO
  # `--include-ephemeral` flag, so an ephemeral verdict bead is invisible to the
  # reviewer's poll → it finds nothing → self-drains → 0 verdicts → 0 merges
  # (ga-vephl root cause). A non-ephemeral verdict bead is found by the exact poll
  # (verified live: ga-moog2). The reviewer closes the bead when done and the wisp
  # reaper sweeps closed gate beads, so dropping --ephemeral does not leak.
  VERDICT_BEAD_ID=$(bd -C "$GC_CITY" create \
    "reviewer-verdict: $BRANCH (reviewer $i/$REQUIRED_REVIEWERS)" \
    -t chore \
    -l type:quality-gate-verdict \
    -l "gate-run:$GATE_RUN_ID" \
    -l "reviewer-index:$i" \
    -l verdict:pending \
    -d "Verdict bead for reviewer $i of $REQUIRED_REVIEWERS on branch $BRANCH.
gate_run: $GATE_RUN_ID
branch: $BRANCH
author: $AUTHOR
lens: $REVIEWER_LENS
This bead ID will be delivered to the reviewer session via nudge with exact commands." \
    --json 2>/dev/null | jq -r '.id // empty' || echo "")

  if [ -z "$VERDICT_BEAD_ID" ]; then
    err "Failed to create verdict bead for reviewer $i. Aborting gate."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    exit 1
  fi

  VERDICT_BEAD_IDS+=("$VERDICT_BEAD_ID")
  log "  Verdict bead $i: $VERDICT_BEAD_ID"

  # Build the review task message for the session nudge.
  # Each session gets: (a) the diff, (b) its specific lens, (c) exact bd commands to record verdict.
  REVIEW_TASK=$(cat <<TASK
QUALITY GATE REVIEW — You are reviewer $i of $REQUIRED_REVIEWERS for branch: $BRANCH
Author (EXCLUDED from reviewing): $AUTHOR
Rig: $RIG
Branch SHA: $BRANCH_SHA

YOUR REVIEW LENS: $REVIEWER_LENS

CHANGED FILES:
$CHANGED_FILES

DIFF SUMMARY:
$DIFF_SUMMARY

$DIFF_HEADER
$DIFF_FULL

--- YOUR TASK ---
Review this diff adversarially using ONLY your assigned lens above.
You must NOT know or consider what the other reviewers think (you are independent).
This author ($AUTHOR) cannot be a reviewer of their own work.

REFUTATION PASS — MANDATORY BEFORE ANY FAIL:
For EVERY blocking issue you are about to raise, RE-READ the exact changed lines
in the diff and actively try to REFUTE it: is the defect really present in THIS
diff, at the lines you cite, given the surrounding context — or are you
pattern-matching on superficially-similar code, or assuming context you did not
actually verify in the diff? If you cannot ground a blocking issue in specific
changed lines, DROP it. Only issues you can prove against the actual diff count
as blocking. If nothing survives refutation, your verdict is PASS.
WHY THIS MATTERS: this gate fails on ANY single reviewer FAIL, so a
false-positive FAIL is expensive — it forces a full re-dispatch + re-work cycle
on correct code. Be adversarial about the CODE, and equally adversarial about
your own findings before you commit to FAIL.

After completing your review, record your verdict with EXACTLY these bash commands:

bd -C "$GC_CITY" label remove "$VERDICT_BEAD_ID" "verdict:pending"
# If PASS:
bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:PASS"
bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: PASS
Summary: <2-3 sentence summary of what you checked and why it passes your lens>"
bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

# If FAIL:
# bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:FAIL"
# bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: FAIL
# Blocking issue 1: <description>
# Blocking issue 2: <description> (if any)"
# bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

Run those commands and then exit your session. Do not start other work.
TASK
)

  # Spawn an independent reviewer session (no attach, fresh wake mode).
  # Uses "gate-reviewer" template (not gastown.dog) to avoid consuming the
  # dog pool's 3 permanent cap slots (ga-mzc3h). The gate-reviewer template has
  # its own budget (max_active_sessions=6, min=0 → no permanent pool workers).
  # Stderr is captured to a temp file (not swallowed) so failures are visible.
  # NOTE: this loop runs at top-level script scope (not a function), so we do
  # NOT use `local` here — `local` outside a function errors to stderr.
  _spawn_err_file="/tmp/gate-reviewer-spawn-err-$$.${i}"
  SESSION_JSON=$(gc --city "$GC_CITY" session new gate-reviewer \
    --no-attach \
    --title "gate-reviewer-$i: $BRANCH" \
    --json \
    2>"$_spawn_err_file" || echo "{}")
  _spawn_err=$(head -c 300 "$_spawn_err_file" 2>/dev/null || echo "")
  rm -f "$_spawn_err_file"

  SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

  # ── ga-2u38b: short in-process retry BEFORE giving up on the run. The
  # rebase/push/stale-base-check/sizing/verdict-bead work above is already
  # done and paid for — if this is a transient Dolt/MySQL connection blip, a
  # few seconds' backoff often clears it outright and the run never has to
  # touch the marker's gate-status at all. Only loops while the failure still
  # classifies as transient; a non-transient failure (broken template,
  # session-cap deadlock) gets zero extra tries here and falls straight
  # through to the classification below, same as before this fix.
  #
  # ga-3jn3a: GATE_SPAWN_RETRY_MAX=1 + a flat 3s backoff (the original
  # ga-2u38b shape) survived a short blip but not the ~39s Dolt outage
  # observed live (08/06 16:00) — two consecutive failures 39s apart
  # exhausted the single retry and the run aborted straight to
  # gate-status:error, three separate times in one day requiring manual
  # rescue. Backoff now DOUBLES per attempt (base * 2^(n-1): 3s, 6s, 12s
  # with the default base and max) instead of repeating the same short
  # wait — cumulative in-process coverage grows from ~3s to ~21s, closer to
  # the observed outage duration, before ever falling through to the
  # cross-sweep gate_spawn_failure_requeue_or_error path below.
# SELFTEST-EXTRACT spawn-retry-loop: BEGIN
  _spawn_retry_n=0
  while [ -z "$SESSION_ID" ] \
      && [ "$_spawn_retry_n" -lt "$GATE_SPAWN_RETRY_MAX" ] \
      && [ "$(is_transient_spawn_error "$_spawn_err")" = "1" ]; do
    _spawn_retry_n=$((_spawn_retry_n + 1))
    _spawn_backoff_secs=$((GATE_SPAWN_RETRY_BACKOFF_SECS * (1 << (_spawn_retry_n - 1))))
    warn "  Reviewer $i spawn hit a transient connection error (spawn_err=${_spawn_err:-none}) — in-process retry $_spawn_retry_n/$GATE_SPAWN_RETRY_MAX after ${_spawn_backoff_secs}s backoff (ga-2u38b/ga-3jn3a)."
    sleep "$_spawn_backoff_secs" 2>/dev/null || true
    _spawn_err_file="/tmp/gate-reviewer-spawn-err-$$.${i}.r${_spawn_retry_n}"
    SESSION_JSON=$(gc --city "$GC_CITY" session new gate-reviewer \
      --no-attach \
      --title "gate-reviewer-$i: $BRANCH" \
      --json \
      2>"$_spawn_err_file" || echo "{}")
    _spawn_err=$(head -c 300 "$_spawn_err_file" 2>/dev/null || echo "")
    rm -f "$_spawn_err_file"
    SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')
  done
# SELFTEST-EXTRACT spawn-retry-loop: END

  if [ -z "$SESSION_ID" ]; then
    err "Failed to spawn reviewer session $i (ga-mzc3h). Aborting gate. spawn_err=${_spawn_err:-no output}"
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true

    # ── ga-piscg: account this abort + escalate on K consecutive (across markers).
    # Every $() is guarded with `|| echo …` and every numeric is sanitized so this
    # block can NEVER crash the set -euo pipefail dispatcher (cf ga-8fx5e).
    _sa_count=$(cat "$SPAWN_ABORT_COUNT_FILE" 2>/dev/null || echo 0)
    case "$_sa_count" in ''|*[!0-9]*) _sa_count=0 ;; esac
    _sa_count=$((_sa_count + 1))
    echo "$_sa_count" > "$SPAWN_ABORT_COUNT_FILE" 2>/dev/null || true

    # Structured audit-trail event (carries spawn_err + consecutive count).
    mkdir -p "$(dirname "$QG_LOG")" 2>/dev/null || true
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg branch "$BRANCH" \
      --arg bead "$BEAD_ID" \
      --arg marker "$MARKER_ID" \
      --arg reviewer "$i" \
      --arg spawn_err "${_spawn_err:-no output}" \
      --argjson consec "$_sa_count" \
      '{ts:$ts, event:"spawn_abort", branch:$branch, bead:$bead, marker:$marker, reviewer:$reviewer, consecutive:$consec, spawn_err:$spawn_err}' \
      >> "$QG_LOG" 2>/dev/null || true

    if [ "$_sa_count" -ge "$SPAWN_ABORT_THRESHOLD" ]; then
      _sa_now=$(date +%s 2>/dev/null || echo 0)
      _sa_last=$(cat "$SPAWN_ABORT_ALERT_FILE" 2>/dev/null || echo 0)
      if [ "$(spawn_abort_should_page "$_sa_count" "$SPAWN_ABORT_THRESHOLD" "$_sa_now" "$_sa_last" "$SPAWN_ABORT_REALERT_SEC")" = "page" ]; then
        err "SYSTEMIC SPAWN OUTAGE: $_sa_count consecutive reviewer-spawn aborts across markers (threshold=$SPAWN_ABORT_THRESHOLD). Paging Athos + Mayor. spawn_err=${_spawn_err:-no output}"
        notify -t "🚨 Gate spawn OUTAGE" -p 5 "🚨 Quality gate DOWN: $_sa_count consecutive reviewer-spawn aborts across markers — no gate can pass. spawn_err: ${_spawn_err:-no output}" 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "🚨 Gate DOWN: $_sa_count consecutive reviewer-spawn aborts" \
          -m "$(printf 'The quality-gate dispatcher has aborted reviewer-spawn %s times CONSECUTIVELY across markers (threshold=%s, one marker per sweep). The reviewer-spawn mechanism appears broken town-wide (cf ga-mzc3h: gate-reviewer template / session cap). NO gate can PASS until this is fixed.\n\nLatest marker: %s\nLatest branch: %s\nLatest source bead: %s\nspawn_err: %s\n\nAthos was paged via ntfy. Investigate the gate-reviewer template + session cap immediately; clear the counter at %s once spawn works again.' \
            "$_sa_count" "$SPAWN_ABORT_THRESHOLD" "$MARKER_ID" "$BRANCH" "$BEAD_ID" "${_spawn_err:-no output}" "$SPAWN_ABORT_COUNT_FILE")" \
          2>/dev/null || warn "Could not mail Mayor spawn-outage escalation"
        echo "$_sa_now" > "$SPAWN_ABORT_ALERT_FILE" 2>/dev/null || true
      fi
    fi

    # ── ga-2u38b: transient connection failure ≠ terminal logic failure. ─────
    # 12 occurrences observed 2026-08-06, heaviest exactly when the queue is
    # full and Dolt is under load (worst possible time to discard a run).
    # gate_spawn_failure_requeue_or_error (defined above, mirrors
    # gate_marker_status_ensure's mute-function/caller-logs discipline)
    # decides AND applies the requeue: a recognized transient-connection
    # signature routes the marker back to gate-status:ready (auto re-admitted
    # by the guard, ga-o64z1 Step 4b) with a bounded attempt counter instead
    # of gate-status:error (which no sweep re-admits — a human had to flip it
    # back by hand every time). Anything NOT matching the transient
    # signature, a spent retry budget, or an unverifiable counter write
    # returns "error" and falls through to the unchanged gate-status:error
    # write below — the ACEITE test requires this distinction to actually
    # exist, not just the transient path to work.
    if [ "$(gate_spawn_failure_requeue_or_error "$MARKER_ID" "$_spawn_err")" = "ready" ]; then
      log "SUPPRESSED PUSH (ga-2u38b non-terminal): reviewer-spawn transient connection failure for $MARKER_ID — gate-status:ready, spawn_err=${_spawn_err:-no output}."
      exit 1
    fi

    bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:error" -q 2>/dev/null || true
    exit 1
  fi

  SESSION_IDS+=("$SESSION_ID")
  log "  Reviewer session $i spawned: session_id=$SESSION_ID verdict_bead=$VERDICT_BEAD_ID"

  # Wake the session so it starts immediately
  gc --city "$GC_CITY" session wake "$SESSION_ID" 2>/dev/null || true
  # ga-67hae: pin reviewer so config-drift drain can't kill it mid-review.
  # Reviewer sessions have min_active_sessions=0 and no persistent pin, so a
  # supervisor config-drift event (CopyFiles hash change) would drain them — the
  # reviewer dies, its verdict bead stays pending, gate times out. Pinning sets
  # the durable pin override on the session bead so drain is a no-op for this
  # session for its lifetime. Non-fatal: if pin fails the reviewer still runs,
  # just unprotected (the re-convene + outer timeout remain backstops).
  gc --city "$GC_CITY" session pin "$SESSION_ID" 2>/dev/null || true
  log "  Reviewer session $SESSION_ID pinned (drain-exempt, ga-67hae)"

  # ga-67hae: DURABLE PULL CHANNEL — assign verdict bead to this reviewer's
  # session_name + embed the review task in its comment. The nudge below is a
  # fast-path; the reviewer's poll loop (`gc bd list --assignee=$GC_SESSION_NAME`)
  # is the reliable fallback that survives nudge-injection races. All guarded
  # with || true (set -euo pipefail safe).
  SESSION_NAME=$(echo "$SESSION_JSON" | jq -r '.session_name // empty')
  if [ -n "$SESSION_NAME" ]; then
    # ga-vdurb (SECONDARY FIX): the assign used to be a bare `|| true`-swallowed
    # write, so an intermittent lost write under load left the bead assignee=None
    # even for the FIRST cohort — silently killing the durable pull from the start.
    # Use the verified-assign helper (assign + read-back + 1 retry + WARN-on-fail);
    # still NON-fatal, but a lost assignment is now visible in the log, not silent.
    assign_verdict_bead_verified "$VERDICT_BEAD_ID" "$SESSION_NAME" "initial slot $i" || true
    bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "$REVIEW_TASK" 2>/dev/null || true
    log "  Verdict bead $VERDICT_BEAD_ID assigned to $SESSION_NAME + task embedded (durable pull, ga-67hae)"
  else
    warn "  Initial slot $i: spawn JSON had no session_name — durable pull channel NOT wired (verdict-poll + outer timeout backstop)."
  fi

  # ga-noxbv: snapshot the session's terminal BEFORE the task is delivered. The
  # ACK pass (Step 7b) compares a fresh peek against this baseline — any change
  # means the reviewer came alive and consumed input. cksum of the peek buffer is
  # a cheap stable fingerprint. `|| echo ""` keeps set -euo pipefail happy.
  _peek_base=$(gc --city "$GC_CITY" session peek "$SESSION_ID" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
  REVIEW_TASKS+=("$REVIEW_TASK")
  REVIEWER_PEEK_BASELINE+=("$_peek_base")
  REVIEWER_ACKED+=(0)

  # Deliver the review task via `queue` (enqueue-and-return). ga-noxbv root cause:
  # `--delivery immediate` typed the task into a freshly-spawned headless session
  # that was NOT yet input-ready → keystrokes dropped → reviewer idle forever →
  # gate hung at N/3 verdicts. `queue` hands the task to the runtime, which
  # delivers it WHEN the session becomes input-ready (no dropped keystrokes, no
  # magic sleep needed). NOT `wait-idle`: this spawn loop is sequential, so a
  # blocking wait on a never-idle reviewer would stall spawning reviewers 2&3 —
  # `queue` returns immediately. Do NOT log "delivered" here (it would lie on a
  # send the reviewer never consumed); Step 7b confirms a real ACK.
  if $GATE_NUDGE_TIMEOUT gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REVIEW_TASK" --delivery queue 2>/dev/null; then
    log "  Review task QUEUED to session $SESSION_ID (reviewer $i) — ACK pending (Step 7b)"
  elif $GATE_NUDGE_TIMEOUT gc --city "$GC_CITY" session submit "$SESSION_ID" "$REVIEW_TASK" 2>/dev/null; then
    log "  Review task SUBMITTED to session $SESSION_ID (reviewer $i) — ACK pending (Step 7b)"
  else
    warn "  Initial queue/submit to session $SESSION_ID failed — Step 7b will retry (reviewer $i)"
  fi

  # ga-mepb0 (EDIT #2, defense-in-depth): stagger the NEXT reviewer's spawn so the
  # N reviewers do not all fire `gc prime` (SessionStart) against Dolt :52756 in
  # the same instant — that thundering herd is what trips the Dolt circuit-breaker
  # and wedges a reviewer at boot (the false-FAIL root). Skip the pause after the
  # last reviewer (nothing left to spawn) and when disabled (stagger=0). EDIT #1
  # still re-convenes any reviewer that wedges despite this; the stagger just
  # lowers the odds of the wedge. Guarded so a misconfig can't crash the loop.
  if [ "$GATE_SPAWN_STAGGER_SECS" -gt 0 ] 2>/dev/null && [ "$i" -lt "$REQUIRED_REVIEWERS" ] 2>/dev/null; then
    log "  Spawn stagger: sleeping ${GATE_SPAWN_STAGGER_SECS}s before reviewer $((i+1)) (ga-mepb0, Dolt boot-herd guard)"
    sleep "$GATE_SPAWN_STAGGER_SECS" || true
  fi
done

log "All $REQUIRED_REVIEWERS reviewer sessions spawned: ${SESSION_IDS[*]}"

# ── ga-4u16h: per-slot re-convene state (index-aligned with VERDICT_BEAD_IDS /
# SESSION_IDS / REVIEW_TASKS). RESPAWN_BUDGET caps re-spawns per slot;
# SLOT_SPAWN_EPOCH anchors each slot's grace window (reset on every re-spawn so a
# fresh reviewer gets a fair start); SLOT_DEAD_STREAK requires consecutive DEAD
# reads before acting (transient-list-failure guard).
RESPAWN_BUDGET=()
SLOT_SPAWN_EPOCH=()
SLOT_DEAD_STREAK=()
_reconvene_init_now=$(date +%s)
for _ri in "${!SESSION_IDS[@]}"; do
  RESPAWN_BUDGET+=("$MAX_RESPAWNS_PER_SLOT")
  SLOT_SPAWN_EPOCH+=("$_reconvene_init_now")
  SLOT_DEAD_STREAK+=(0)
done

# ── ga-piscg: spawn mechanism is proven working this sweep → reset the
# consecutive-abort counter + alert state so a FUTURE outage pages fresh (and so
# we don't carry a stale count from an outage that has since recovered).
_sa_prev=$(cat "$SPAWN_ABORT_COUNT_FILE" 2>/dev/null || echo 0)
case "$_sa_prev" in ''|*[!0-9]*) _sa_prev=0 ;; esac
if [ "$_sa_prev" -gt 0 ]; then
  log "Reviewer-spawn succeeded — clearing consecutive spawn-abort counter (was $_sa_prev)."
fi
rm -f "$SPAWN_ABORT_COUNT_FILE" "$SPAWN_ABORT_ALERT_FILE" 2>/dev/null || true

# ── ga-T1 #1: refresh the single-instance heartbeat before the long ACK + verdict
# windows. The hb is written once at acquire; the bd-heavy preamble + the ACK loop
# (up to ~ACK_MAX_RETRIES*ACK_WAIT_SECS ≈ 80s) can run a sizeable fraction of
# MAX_AGE before the verdict poll even starts. Stamp it fresh here so a LIVE sweep
# is never mistaken for stale during this stretch. No-ops cleanly when the lock is
# disabled or its dir is absent (token-guarded write, 2>/dev/null).
if [ "$GATE_LOCK_ENABLED" = "1" ]; then _gate_lock_write_hb; fi

# ── Step 7b: ACK verification — confirm reviewers actually consumed their task ──
# ga-noxbv reliability fix. `queue` delivery (above) lets the runtime deliver when
# a session is input-ready, but a session that spawned-then-wedged would still
# never consume the task → the old gate hung at N/3 forever, invisibly. Here we
# confirm a real ACK per reviewer and RE-QUEUE only sessions showing NO sign of
# life, bounded to ~ACK_MAX_RETRIES*ACK_WAIT_SECS (~80s worst case). A reviewer
# ACKs when EITHER (strong) its verdict bead has progressed past verdict:pending
# OR (soft) its session has produced new terminal output since the pre-delivery
# baseline. We only re-queue sessions that show neither — exactly the wedged/idle
# case — so a live-but-slow reviewer is never spammed with duplicate tasks.
# NON-fatal by design: the verdict poll, the DISPATCHING_TTL zombie-recovery, and
# gate-health-monitor's idle-reviewer watchdog remain the ultimate backstops, so
# we never abort the gate here.
# HARD CONSTRAINT (memory gate-dispatcher-set-e-pipefail-crash): set -euo pipefail
# is active — every command below is `|| true`-guarded or used as a condition so a
# transient failure can never head-of-line-block the gate.
ACK_MAX_RETRIES="${ACK_MAX_RETRIES:-4}"
ACK_WAIT_SECS="${ACK_WAIT_SECS:-20}"
for _ack_attempt in $(seq 1 "$ACK_MAX_RETRIES"); do
  _all_acked=1
  # ga-xwdl: snapshot session state + "now" ONCE per attempt (not per-reviewer,
  # same bounding idiom as ga-4u16h's RECONVENE_SESS_JSON below) so the
  # ga-aknox skip further down can tell "still booting" apart from "genuinely
  # drained" without an extra `gc session list` call per reviewer. Only
  # fetched from attempt 2 on — the ga-aknox branch never runs on attempt 1.
  # Fail-safe: if the list call fails or is unparseable, ACK_LIST_OK stays 0,
  # every reviewer's state then reads "" (session_is_booting("")=0) — the
  # spawn-age gate below still has to clear separately, so an inconclusive
  # list read cannot by itself produce a skip.
  ACK_LIST_OK=0
  ACK_SESS_JSON=""
  _ack_now=$(date +%s 2>/dev/null || echo 0)
  if [ "$_ack_attempt" -gt 1 ]; then
    # ga-07509: on failure ACK_SESS_JSON stays "" exactly as before — the
    # `-n "$ACK_SESS_JSON"` shape gate right below already keeps ACK_LIST_OK
    # at 0 for that case, so the fail-safe documented above is unchanged;
    # only the failure DETECTION moves onto the authoritative signal.
    ACK_SESS_JSON=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json) || true
    if [ -n "$ACK_SESS_JSON" ] && echo "$ACK_SESS_JSON" \
         | jq -e 'if type=="array" then true else has("sessions") end' >/dev/null 2>&1; then
      ACK_LIST_OK=1
    fi
  fi
  for k in "${!VERDICT_BEAD_IDS[@]}"; do
    if [ "${REVIEWER_ACKED[$k]:-0}" = "1" ]; then continue; fi
    _vb="${VERDICT_BEAD_IDS[$k]}"
    _sid="${SESSION_IDS[$k]}"
    # Strong ACK: verdict bead progressed past verdict:pending (reviewer is acting).
    # ga-h199q: routed through the read-cache shim — this is an ACK poll, already
    # designed to tolerate a missed/stale update (falls through to the Soft ACK
    # session-peek check right below on any given poll iteration).
    _vb_labels=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" show "$_vb" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null || echo "verdict:pending")
    if ! echo "$_vb_labels" | grep -q "verdict:pending"; then
      REVIEWER_ACKED[$k]=1
      log "  ACK (verdict-progressed): reviewer $((k+1)) session=$_sid bead=$_vb"
      continue
    fi
    # Soft ACK: session produced new output since baseline → alive and consuming
    # input; trust the already-queued task will deliver. Stop re-queuing it.
    _peek_now=$(gc --city "$GC_CITY" session peek "$_sid" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
    if [ -n "$_peek_now" ] && [ "$_peek_now" != "${REVIEWER_PEEK_BASELINE[$k]:-}" ]; then
      REVIEWER_ACKED[$k]=1
      log "  ACK (session-alive): reviewer $((k+1)) producing output session=$_sid"
      continue
    fi
    # No sign of life. On the FIRST attempt just wait (give the initial queue a
    # chance); from attempt 2 on, re-queue the exact task into the idle session.
    _all_acked=0
    if [ "$_ack_attempt" -gt 1 ]; then
      # ga-aknox (ORIGINAL): skip nudge (and its 45s GATE_NUDGE_TIMEOUT) when the
      # session has already drained — peek reports "session not found" on STDERR
      # for gone sessions. Early-exit here saves ~45s×(N-1); the verdict-poll
      # re-convene (ga-4u16h) fires sooner and gets the branch reviewed.
      #
      # ga-xwdl: that peek signal is the SAME "session not found" a reviewer
      # still inside its ~210s deferred-start boot window produces (ga-flfo) —
      # `gc session peek` cannot tell "not yet born" from "already dead". This
      # loop's own attempts land at spawn_age ~20-60s, deep inside that window,
      # so the ORIGINAL unconditional check misread a booting reviewer as
      # drained, skipped its nudge, and — because the very next attempt's peek
      # then succeeded (ACK) and stopped all further re-queuing — the task was
      # NEVER delivered; the reviewer sat alive-but-untasked for the full 29m
      # outer timeout. Gate the skip behind the SAME discriminator the
      # reconvene loop already trusts a few hundred lines below
      # (session_is_booting + RECONVENE_GRACE_SECS): only treat "peek says
      # gone" as a confirmed drain once the session is not currently booting
      # AND has been alive long enough that boot could not still explain a
      # "not found" read. Any inconclusive read (list call failed, empty
      # state, missing spawn epoch) biases toward "not past grace" and falls
      # through to re-queue too — never skip on uncertain evidence.
      _ack_state_flag=""
      if [ "$ACK_LIST_OK" = "1" ]; then
        _ack_state_flag=$(echo "$ACK_SESS_JSON" \
          | jq -r --arg s "$_sid" 'if type=="array" then . else .sessions end | map(select(.id==$s or .session_id==$s)) | .[0].state // ""' 2>/dev/null || echo "")
      fi
      _ack_booting=$(session_is_booting "$_ack_state_flag")
      _ack_spawn_age=$(( _ack_now - ${SLOT_SPAWN_EPOCH[$k]:-$_ack_now} ))
      _ack_peek_stderr=$(gc --city "$GC_CITY" session peek "$_sid" --lines 5 2>&1 >/dev/null || true)
      if [ "$(session_peek_reports_dead "$_ack_peek_stderr")" = "1" ] && [ "$_ack_booting" != "1" ] && [ "$_ack_spawn_age" -ge "$RECONVENE_GRACE_SECS" ]; then
        warn "  ACK skip (ga-aknox): reviewer $((k+1)) session=$_sid drained during startup (stale_async_start race) — nudge skipped, re-convene will re-spawn"
      else
        if [ "$_ack_booting" = "1" ]; then
          warn "  No ACK from reviewer $((k+1)) (attempt $_ack_attempt/$ACK_MAX_RETRIES) — session still booting (state=creating, spawn_age=${_ack_spawn_age}s, ga-xwdl) — re-queuing task session=$_sid"
        else
          warn "  No ACK from reviewer $((k+1)) (attempt $_ack_attempt/$ACK_MAX_RETRIES) — re-queuing task session=$_sid"
        fi
        $GATE_NUDGE_TIMEOUT gc --city "$GC_CITY" session nudge "$_sid" "${REVIEW_TASKS[$k]}" --delivery queue 2>/dev/null || true
      fi
    fi
  done
  [ "$_all_acked" = "1" ] && break
  sleep "$ACK_WAIT_SECS" || true
done
for k in "${!VERDICT_BEAD_IDS[@]}"; do
  if [ "${REVIEWER_ACKED[$k]:-0}" != "1" ]; then
    warn "  Reviewer $((k+1)) never ACKed after ${ACK_MAX_RETRIES} attempts — relying on verdict-poll + DISPATCHING_TTL + monitor backstops (session=${SESSION_IDS[$k]})"
  fi
done

log "Verdicts requested (timeout=${VERDICT_TIMEOUT_MINUTES}m) — checking once now; if incomplete, a future sweep's Phase C finalizes (ga-eqjo, no longer blocking here)."

# ── Step 8 (ga-eqjo): non-blocking verdict check — replaces the historical
# `while true; do ...; sleep 30; done` blocking poll. That loop held the
# single-instance lock (and this whole process) for the ENTIRE review wait —
# 90%+ of a run's wall time (4-26min observed) — even though nothing in the
# wait touches shared state. This is the actual fix for ga-eqjo: check ONCE,
# non-blocking; if the run already finished (rare — a near-instant review),
# finalize it right here in the same process (identical behavior to before,
# just via gate_finalize_run instead of inline Steps 9-11). Otherwise, exit
# immediately, leaving the reviewers running unsupervised (Phase B) — a LATER
# sweep's Phase C (near the top of this file) checks back and finalizes once
# complete, or once the run's own persisted timeout elapses. This is what
# lets the single-instance lock be held for only ~65-95s (claim+spawn)
# instead of the full review wait, so multiple runs can be genuinely in
# flight at once (ceiling=3 headroom, ga-cw4pm, finally reachable).

OVERALL_VERDICT="PASS"
FAIL_REASONS=""
# ga-eqjo (code-review fix): QUOTA_REQUEUE is a plain script-global gate_finalize_run
# checks FIRST, before OVERALL_VERDICT. Phase C (above) may have already set it to 1
# while finalizing a DIFFERENT, earlier-in-this-sweep run bead and never reset it
# afterward — without this reset, that stale 1 would make gate_finalize_run silently
# discard THIS run's real, just-computed verdict as a false quota-stop re-queue.
# REQUEUE_REASON gets the same treatment: a stale "dead-reviewer" reason left
# by an earlier Phase-C-processed run would otherwise mislabel THIS run's own
# (unrelated) quota-stop re-queue, if it ever hits one.
QUOTA_REQUEUE=0
REQUEUE_REASON="quota"
gate_collect_verdicts

if [ "$VERDICTS_RECEIVED" -eq "$REQUIRED_REVIEWERS" ]; then
  [ "$ANY_FAIL" = "1" ] && OVERALL_VERDICT="FAIL"
  log "All verdicts already in ($VERDICTS_RECEIVED/$REQUIRED_REVIEWERS) on the same sweep that spawned them — finalizing now (fast path, OVERALL=$OVERALL_VERDICT)."
  gate_finalize_run
else
  # ga-eqjo: not all verdicts are in on the SAME sweep that spawned this run —
  # this is now the NORMAL case (reviewers take minutes; this check runs
  # seconds after spawn), not a timeout. The full FAIL-path handling that used
  # to live here (self-healing retry loop, marker/gate-run closure, author
  # nudge/mail, ga-pyzo's recycled-author fallback) now lives inside
  # gate_finalize_run() itself, shared by BOTH this function's fast-path call
  # above (line ~4907) and Phase C's later call for runs finalized on a
  # subsequent sweep — so it fires exactly once, whichever path completes the
  # run, instead of being duplicated per call site.
  log "Run $GATE_RUN_ID admitted: $VERDICTS_RECEIVED/$REQUIRED_REVIEWERS verdict(s) in so far — reviewers keep working independently (Phase B); a future sweep's Phase C will finalize (ga-eqjo)."
  GATE_RUN_LEAVE_SESSIONS_ALIVE=1

  # ── ga-309v3: continue the multi-admit burst ────────────────────────────────
  # Reached ONLY on the leave-in-flight path — i.e. we just admitted a run and
  # its reviewers are working unsupervised. That is exactly when the gate has
  # spare capacity it currently throws away: today the sweep ends here and the
  # next marker waits a full launchd cadence (4-6min) for a fresh sweep.
  #
  # The ONLY guard here is the round counter. Everything else (headroom, queue
  # depth, quota, swap, rebase health) is re-evaluated from scratch by the next
  # round, because it is a full fresh run of this script — no duplicated policy
  # to drift out of sync with Step 0b-1, and a round that finds nothing to do
  # exits on its own at Step 0b. A hot data plane stops the burst on the next
  # round's own headroom probe.
  # ga-991au: this round DID admit, so it is bounded by the ADMIT cap (and must
  # also respect the total-round cap). GATE_ADMITS_DONE advances only here.
  if [ "$((GATE_ADMITS_DONE + 1))" -lt "$GATE_MAX_ADMITS_PER_SWEEP" ] 2>/dev/null \
     && [ "$((GATE_ADMIT_ROUND + 1))" -lt "$GATE_MAX_ROUNDS_PER_SWEEP" ] 2>/dev/null; then
    # Keep the lock across the re-exec: cleanup_reviewer_sessions releases it
    # unless this flag is set, and `exec` would otherwise fire no trap at all —
    # set it FIRST so both the explicit call below and any signal path agree.
    GATE_SWEEP_HAS_MORE_WORK=1
    cleanup_reviewer_sessions
    trap - EXIT
    log "Multi-admit: round $GATE_ADMIT_ROUND done (admit $((GATE_ADMITS_DONE + 1))/$GATE_MAX_ADMITS_PER_SWEEP), re-exec for round $((GATE_ADMIT_ROUND + 1))/$GATE_MAX_ROUNDS_PER_SWEEP under the same lock (ga-309v3)."
    export GATE_LOCK_TOKEN
    export GATE_ADMIT_ROUND="$((GATE_ADMIT_ROUND + 1))"
    export GATE_ADMITS_DONE="$((GATE_ADMITS_DONE + 1))"
    export GATE_MAX_ADMITS_PER_SWEEP
    export GATE_MAX_ROUNDS_PER_SWEEP
    # No "$@" — the script takes no arguments, and forwarding a stale positional
    # would mutate the daemon's argv for every later round (ps / pgrep -f).
    exec bash "$0"
  fi
fi
