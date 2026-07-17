#!/usr/bin/env bash
# gatefix-deadworker-recovery.sh — auto-recover gate:needs-fix beads whose worker DIED.
#
# PROBLEM (ga-pdrij sub-scope C, observed 2026-06-30 on wa-85iv8 + wa-5otq4): a worker
# dispatched for the autonomous gate-fix loop (gate:needs-fix) can DIE/drain mid-fix,
# leaving an orphan per-bead worktree (crew/worker-<bead> or /gt/worker-<bead>) plus a
# stale claim (gc.session_name/work_dir) on the bead. The orphan worktree + stale claim
# then BLOCK the Pilot from re-dispatching the bead — it sits gate:needs-fix forever (the
# worktree-reaper only reaps CLEAN worktrees >24h, so a dirty-from-dead one is skipped
# indefinitely). This janitor automates that recovery within one sweep.
#
# WHAT IT DOES: for each gate:needs-fix bead that is NOT story:in-flight, whose recorded
# worker session (gc.session_name) is DEAD (drained/asleep/absent in `gc session list`),
# reap its orphan worktree (force, path-scoped — never touches any branch ref) + clear
# its stale claim metadata so the next Pilot sweep re-dispatches it fresh. A bead whose
# worker is still LIVE (or has no recorded session) is LEFT untouched (active rework —
# never reaped).
#
# NO BRANCH DELETION (ga-0re8j, 2026-07-17): this janitor used to also delete
# crew/*/<bead> branches (local + remote) on the theory that a gate:needs-fix branch is
# disposable "failed gate work". That premise was false, and the glob was worse than
# imprecise: refs/heads/crew/*/<bead> requires exactly two path segments (git ref globs
# never cross `/`), so it could ONLY match the crew's own crew/<owner>/<bead> PRIMARY
# submission branch — the gatefix-worker worktree at crew/worker-<bead> checks out that
# SAME ref, so there was never a distinct disposable branch to target. gate:needs-fix
# means the crew will keep fixing THIS branch, not abandon it. Result: 73 remote branch
# deletions over 17 days, 100% of them primary branches, zero permanent loss only by
# luck (objects not yet git-gc'd). Recovery never needed the branch gone — clearing the
# stale claim below is sufficient for the Pilot to re-dispatch. Do not re-add branch
# deletion here.
#
# SAFETY: only acts on gate:needs-fix beads with a DEMONSTRABLY-DEAD worker. DRY_RUN
# default-off but easily toggled; kill-switch GATEFIX_RECOVERY_ENABLED=0; per-sweep cap.
# Lib-only seam (GATEFIX_RECOVERY_LIB_ONLY=1) exposes the pure decision for the selftest.
set -uo pipefail

GT="${GATEFIX_RECOVERY_GT:-/Users/athos/gt}"
HQ="$GT/.gascity-gastown-hq"
LOG="${GATEFIX_RECOVERY_LOG:-$HQ/.gc/logs/gatefix-deadworker-recovery.jsonl}"
ENABLED="${GATEFIX_RECOVERY_ENABLED:-1}"
DRY_RUN="${GATEFIX_RECOVERY_DRY_RUN:-0}"
MAX_PER_SWEEP="${GATEFIX_RECOVERY_MAX_PER_SWEEP:-10}"
case "$MAX_PER_SWEEP" in ''|*[!0-9]*) MAX_PER_SWEEP=10 ;; esac
NOTIFY="${GATEFIX_RECOVERY_NOTIFY:-/Users/athos/.local/bin/notify}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
notify_fail() { "$NOTIFY" -t "Gatefix Deadworker Recovery" -p 4 "🚨 $*" 2>/dev/null || true; }

# ── PURE DECISION (selftest-sourceable) ───────────────────────────────────────
# gatefix_recovery_decide <has_needs_fix 0|1> <in_flight 0|1> <session_name> <live_set>
#   live_set = space-delimited list of LIVE session identifiers (name/alias/session_name).
# Echoes: "recover" | "skip:<reason>". A bead is recovered ONLY when it has gate:needs-fix,
# is NOT in-flight, has a NON-EMPTY recorded worker, and that worker is NOT in the live set.
gatefix_recovery_decide() {
  local needs_fix="$1" in_flight="$2" sess="$3" live="$4"
  [ "$needs_fix" = "1" ] || { echo "skip:not-needs-fix"; return 0; }
  [ "$in_flight" = "0" ] || { echo "skip:in-flight-active-rework"; return 0; }
  [ -n "$sess" ] || { echo "skip:no-recorded-worker"; return 0; }   # can't prove dead → leave
  case " $live " in *" $sess "*) echo "skip:worker-still-live"; return 0 ;; esac
  echo "recover"
}

# Lib-only: stop before the live sweep so the selftest can source the pure function.
[ "${GATEFIX_RECOVERY_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

command -v gc >/dev/null 2>&1 || { printf '{"ts":"%s","event":"noop","reason":"no_gc"}\n' "$(ts)" >> "$LOG" 2>/dev/null; notify_fail "gatefix-deadworker-recovery: comando 'gc' nao encontrado no PATH — recuperacao de worker morto parada"; exit 0; }
command -v bd >/dev/null 2>&1 || { printf '{"ts":"%s","event":"noop","reason":"no_bd"}\n' "$(ts)" >> "$LOG" 2>/dev/null; notify_fail "gatefix-deadworker-recovery: comando 'bd' nao encontrado no PATH — recuperacao de worker morto parada"; exit 0; }

# ── live session identifiers (state NOT asleep/drained/dead/closed) ───────────
LIVE_SESSIONS="$(gc session list --json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit()
sess = d.get("sessions", d) if isinstance(d, dict) else d
out = set()
for s in (sess or []):
    if str(s.get("state","")).lower() in ("asleep","drained","dead","closed"): continue
    for k in ("session_name","name","alias","id","agent_name"):
        v = s.get(k)
        if v: out.add(str(v))
print(" ".join(sorted(out)))
' 2>/dev/null)"
# FAIL-SAFE: if we could not read the roster, do NOT reap anything (can't prove dead).
[ -n "$LIVE_SESSIONS" ] || { printf '{"ts":"%s","event":"noop","reason":"empty_roster_failsafe"}\n' "$(ts)" >> "$LOG" 2>/dev/null; exit 0; }

# ── rig repos (where the orphan worktrees live) ───────────────────────────────
RIGS="$(gc --city "$HQ" rig list --json 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for r in d.get("rigs",[]):
    p=r.get("path")
    if p: print(p)
' 2>/dev/null)"
STORES="$HQ
$RIGS"

recovered=0; skipped=0; cap_hit=0

# reap_orphans <rig_repo> <bead_id> — remove the per-bead worktree. Best-effort; never
# fatal. Does NOT touch any branch ref (see NO BRANCH DELETION in the file header).
reap_orphans() {
  local repo="$1" bid="$2" wt
  command -v git >/dev/null 2>&1 || return 0
  # candidate worktree paths — directory-scoped; removing a worktree never deletes the
  # branch ref it had checked out
  for wt in "$repo/crew/worker-$bid" "$GT/worker-$bid"; do
    [ -d "$wt" ] || continue
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null \
      && printf '{"ts":"%s","event":"worktree_reaped","repo":"%s","bead":"%s","wt":"%s"}\n' "$(ts)" "$(basename "$repo")" "$bid" "$wt" >> "$LOG" 2>/dev/null
  done
  git -C "$repo" worktree prune 2>/dev/null || true
}

while IFS= read -r store; do
  [ -n "$store" ] && [ -d "$store" ] || continue
  beads="$(bd -C "$store" list -l "gate:needs-fix" --json 2>/dev/null || echo '[]')"
  ids="$(printf '%s' "$beads" | python3 -c '
import sys, json
try: b = json.loads(sys.stdin.read(), strict=False)
except Exception: b = []
for x in b:
    labs = x.get("labels", [])
    inflight = "1" if "story:in-flight" in labs else "0"
    sess = (x.get("metadata", {}) or {}).get("gc.session_name", "") or ""
    print("%s\t%s\t%s" % (x.get("id",""), inflight, sess))
' 2>/dev/null)"
  while IFS=$'\t' read -r bid inflight sess; do
    [ -n "$bid" ] || continue
    decision="$(gatefix_recovery_decide 1 "$inflight" "$sess" "$LIVE_SESSIONS")"
    if [ "$decision" != "recover" ]; then skipped=$((skipped+1)); continue; fi
    if [ "$recovered" -ge "$MAX_PER_SWEEP" ] 2>/dev/null; then
      [ "$cap_hit" = "0" ] && { cap_hit=1; printf '{"ts":"%s","event":"cap_hit","cap":%s}\n' "$(ts)" "$MAX_PER_SWEEP" >> "$LOG" 2>/dev/null; }
      continue
    fi
    if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
      printf '{"ts":"%s","event":"would_recover","store":"%s","bead":"%s","dead_worker":"%s"}\n' "$(ts)" "$(basename "$store")" "$bid" "$sess" >> "$LOG" 2>/dev/null
      recovered=$((recovered+1)); continue
    fi
    # reap orphans in EVERY rig repo (the worktree could be in any)
    while IFS= read -r rig; do [ -n "$rig" ] && [ -d "$rig" ] && reap_orphans "$rig" "$bid"; done <<< "$RIGS"
    reap_orphans "$GT" "$bid"
    # clear the DEAD worker's stale claim so the bead is a clean re-dispatch candidate
    # (orphan branch/worktree alone is not enough — the stale gc.session_name/work_dir +
    # any assignee left by the dead worker keep it looking "claimed"; wa-85iv8 only
    # re-dispatched + went on to PASS once its claim was also cleared, 2026-06-30).
    bd -C "$store" update "$bid" --unset-metadata "gc.session_name" -q 2>/dev/null || true
    bd -C "$store" update "$bid" --unset-metadata "gc.work_dir"     -q 2>/dev/null || true
    bd -C "$store" update "$bid" --unset-metadata "pilot.sling_bead" -q 2>/dev/null || true
    # only unassign if the assignee IS the dead worker (never touch a live owner)
    _cur_asg="$(bd -C "$store" show "$bid" --json 2>/dev/null | python3 -c 'import sys,json
try:
 d=json.loads(sys.stdin.read(),strict=False); d=d[0] if isinstance(d,list) else d
 print(d.get("assignee") or "")
except: print("")' 2>/dev/null)"
    if [ -n "$_cur_asg" ] && [ "$_cur_asg" = "$sess" ]; then
      bd -C "$store" assign "$bid" "" -q 2>/dev/null || true
    fi
    printf '{"ts":"%s","event":"recovered","store":"%s","bead":"%s","dead_worker":"%s","note":"orphans+claim cleared → re-dispatchable"}\n' "$(ts)" "$(basename "$store")" "$bid" "$sess" >> "$LOG" 2>/dev/null
    recovered=$((recovered+1))
  done <<< "$ids"
done <<< "$STORES"

printf '{"ts":"%s","event":"sweep","recovered":%s,"skipped":%s,"dry_run":%s}\n' "$(ts)" "$recovered" "$skipped" "$DRY_RUN" >> "$LOG" 2>/dev/null
exit 0
