#!/usr/bin/env bash
# story-delivery-daemon-refresh-noop-attribution.test.sh — regression test for
# ga-6zkhci (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh and
# story-delivery-daemon-refresh-attribution.test.sh).
#
# THE BUG: ga-3bdttu (story-delivery-daemon-refresh-attribution.test.sh) taught
# Step 5b to stop blaming a story for daemon staleness its own merge did not
# cause — but only when PRE_DEPLOY_SHA != POST_DEPLOY_SHA. In this rig, the
# story-delivery pull is USUALLY a true no-op (something else — a sibling
# story's delivery earlier in the same sweep — already advanced RUNTIME_DIR's
# HEAD past this story's own commit before PRE_DEPLOY_SHA was captured), so
# PRE_DEPLOY_SHA==POST_DEPLOY_SHA and THIS_PULL_STRUCTURALLY_INERT was left
# unset — the ga-3bdttu exemption never even ran. Confirmed live
# (story-delivery.log 2026-09-14): wa-ibaqq (own merge touches only
# docs/mockups/*.html) and wa-mjpjs (own merge touches only scripts/lib files
# no live daemon imports) were both held with delivery:failed +
# delivery:deploy-pending for a demand-dashboard-class staleness neither one
# caused.
#
# THE FIX (fix-attempt-1): when PRE_DEPLOY_SHA==POST_DEPLOY_SHA, derive this
# story's own delta from MERGE_SHA (the gate-verified commit already proven an
# ancestor of MERGE_REF) instead of the pull range, and ask daemon-refresh.sh
# itself (DRY_RUN=1 — never a real kickstart/drain) whether that delta alone
# reaches any live daemon — reusing the same import/template-closure
# discovery Step 3 already trusts for the wide window, rather than a second
# static heuristic that could never recognize a case like wa-mjpjs's
# scripts/*.py.
#
# THE FIX-ATTEMPT-2 BUG (gate_run ga-u0gc14, caught on review, never shipped):
# fix-attempt-1 used MERGE_SHA^ (the parent commit) as "this story's own
# base". quality-gate-dispatcher.sh's direct_ff merge always fast-forwards
# the WHOLE branch (never squashes), so MERGE_SHA^ is only the true
# pre-story baseline on a SINGLE-commit branch — and every gate fix-attempt
# adds a commit, making multi-commit branches the common case, not the
# exception. On a 2-commit branch, MERGE_SHA^..MERGE_SHA sees only the LAST
# commit, silently missing an earlier commit that actually touched a live
# daemon's import graph — the exact dormant-deploy failure Step 5b exists to
# prevent, reintroduced through this fallback's own "fix".
#
# THE FIX-ATTEMPT-3 FIX (Mayor decision, 2026-09-15): use MERGE_PRE_MAIN — the
# real pre-merge main tip that quality-gate-dispatcher.sh now persists into
# its own PASSED comment at push time — as the base instead, but never trust
# it blindly: verify it resolves in RUNTIME_DIR AND is an actual ancestor of
# MERGE_SHA first. If either check fails (or the field is simply absent — an
# older-format comment), that is a THIRD STATE: inert stays unset and the
# existing blame/hold behavior applies, exactly as if this fallback did not
# exist. Never fall back to guessing MERGE_SHA^ or any other substitute.
#
# T1: no-op pull, own merge (MERGE_SHA) touches only docs/*.html → the
#     merge-own-base probe returns OK → NOT blamed (repro wa-ibaqq).
# T2: no-op pull, own merge touches a file matching NEITHER the tests/docs/md
#     pattern NOR any live daemon's import graph (simulated: the fake
#     daemon-refresh.sh only flags paths containing "sensitive") → the probe
#     still returns OK (real reachability, not a path pattern) → NOT blamed
#     (repro wa-mjpjs).
# T3: control — no-op pull, own merge touches a file the fake daemon-refresh.sh
#     DOES treat as reaching a live (simulated sensitive) daemon → the probe
#     returns NEEDS_GUARDED_RESTART → still blamed exactly as before (proves
#     the fallback doesn't blindly exempt every no-op pull).
# T4: MERGE_PRE_MAIN not persisted at all (older-format gate comment, field
#     absent) → the fallback condition itself fails closed on its 2nd guard
#     → inert stays unknown → existing blame behavior (Mayor's required test
#     #2: "merge sem base gravada: tem que cair no hold existente"). Runs
#     strict (real `set -euo pipefail`, matching production).
# T5: merge-own DRY_RUN=1 probe times out/crashes (no VERDICT= line at all,
#     e.g. `timeout 180` firing) → must fall back to unknown, same as T4
#     (existing blame behavior), and must NOT crash the whole delivery sweep.
#     fix-attempt 1 (gate_run ga-oaid6p) added the probe-output reads without
#     the `|| true` guard the adjacent REFRESH_PROOF line already has; under
#     `set -euo pipefail` a no-match grep piped into head/sed kills the whole
#     script, not just this story. Runs strict for the same reason as T4.
# T6: MERGE_PRE_MAIN present but does not resolve to a real object in
#     RUNTIME_DIR (never fetched / corrupted comment) → the fallback's
#     `rev-parse --verify -q` guard fails closed → inert stays unknown →
#     existing blame behavior (preserves fix-attempt-1's original "unusable
#     MERGE_SHA" coverage under the new mechanism). Runs strict.
# T7: THE key fix-attempt-3 regression test (Mayor's required test #1: "branch
#     de 2 commits em que só o 1º toca o arquivo do daemon: tem que segurar").
#     This story's branch has TWO commits — C2 touches a live daemon's import
#     graph, C3 (the gate-fix-attempt commit) touches only a harmless file.
#     MERGE_PRE_MAIN correctly spans BOTH (it is main's tip before either
#     commit landed) → the probe sees C2's sensitive file → inert=0 → still
#     blamed. Proves the fix: the old MERGE_SHA^ approach would diff only
#     C2..C3 (C3's own parent is C2, not the true pre-story base), see only
#     C3's harmless file, and wrongly exempt a story whose own earlier commit
#     really did cause the staleness. Runs strict.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to the other story-delivery-*.test.sh files.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# run_block <own-file-shape> <pre_main_mode> <merge_probe_crash(0/1)> <strict(0/1)>
#
# Builds a real git fixture in a fresh RUNTIME_DIR:
#   C0 (base) -> C1 (adds lib/sensitive_daemon_dep.py, a PRE-EXISTING file a
#     live daemon imports — simulates the real, earlier cause of staleness;
#     also doubles as "main's real tip before this story's branch" for
#     pre_main_mode=correct) -> this story's own commit(s), per own_file_shape:
#     "docs"       -> ONE commit: docs/mockup.html            (T1, wa-ibaqq shape)
#     "harmless"   -> ONE commit: scripts/cron_only.py         (T2, wa-mjpjs shape)
#     "sensitive"  -> ONE commit: lib/sensitive_daemon_dep2.py (T3 control)
#     "two_commit" -> TWO commits: C2 lib/sensitive_daemon_dep3.py (sensitive),
#                     then C3 docs/mockup2.html (harmless) — T7, the
#                     multi-commit shape gate_run ga-u0gc14 caught.
#   MERGE_SHA is always the tip of this story's own commit(s) (SHA_C2, or
#   SHA_C3 for two_commit).
#
# pre_main_mode selects what MERGE_PRE_MAIN is set to:
#   "correct" (default) -> SHA_C1, the real pre-story main tip
#   "missing"           -> "" — simulates an older-format gate comment with
#                          no pre_merge_main field at all (T4)
#   "garbage"           -> 40 zeros — a syntactically-valid sha this
#                          RUNTIME_DIR cannot resolve (T6)
#
# The fake daemon-refresh.sh classifies ANY range it is asked about by
# actually diffing PRE..POST itself and flagging NEEDS_GUARDED_RESTART only
# when a path containing "sensitive" is in that range — so the WIDE call
# (baseline C0 .. POST) always sees C1's sensitive file and returns
# NEEDS_GUARDED_RESTART (a real, persistent staleness exists), while the
# NARROW merge-own-base call sees only the range it's given — exactly like a
# real per-daemon reachability check would.
run_block() {
  local own_file_shape="$1" pre_main_mode="${2:-correct}" merge_probe_crash="${3:-0}" strict="${4:-0}"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/lib" "$REPO/docs/mockups" "$REPO/scripts"
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo prod > "$REPO/lib/sensitive_daemon_dep.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"

  local OWN_TIP_SHA
  case "$own_file_shape" in
    docs)
      echo mock > "$REPO/docs/mockups/foo.html"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    harmless)
      echo cron > "$REPO/scripts/cron_only.py"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    sensitive)
      echo prod2 > "$REPO/lib/sensitive_daemon_dep2.py"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    two_commit)
      echo prod3 > "$REPO/lib/sensitive_daemon_dep3.py"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      echo mock2 > "$REPO/docs/mockups/foo2.html"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C3
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    scheduled_only)
      # wa-xokje T8 (repro wa-bpbgp's scheduled-job half): own merge touches
      # only a file whose sole reachable consumer is a scheduled/one-shot job
      # with no live PID right now — e.g. scripts/detect_unloaded_committed_daemons.py,
      # consumed solely by the daily com.whatsapp.unloaded-daemons-full-daily job.
      echo cron2 > "$REPO/scripts/scheduled_job.py"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    mixed_sensitive_scheduled)
      # wa-xokje T9 (repro wa-bpbgp's ACTUAL full shape): own merge reaches
      # BOTH a not-running scheduled job AND a live sensitive daemon in the
      # same commit — must stay blamed; subtracting the scheduled job must
      # never empty a set that still contains a live daemon.
      echo prod4 > "$REPO/lib/sensitive_daemon_dep4.py"
      echo cron3 > "$REPO/scripts/scheduled_job2.py"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    job_not_installed)
      # ga-nuou9v T10 (repro wa-s5fux): own merge SHIPS a scheduled job's
      # plist + entrypoint that is not installed/loaded in launchd — unlike
      # "scheduled_only" above, the "no live PID" here means "will NEVER
      # run", not "installed, next launchd fire self-heals".
      echo notinstalled > "$REPO/scripts/notinstalled_job.py"
      git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
      OWN_TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"
      ;;
    *)
      echo "run_block: unknown own_file_shape '$own_file_shape'" >&2
      exit 1
      ;;
  esac

  # Widen the wide-window baseline to C0 so it spans C1's sensitive file —
  # simulates a real, unresolved staleness that predates this story.
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"

  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
if [ "$DRY_RUN" = "1" ] && [ "${SIMULATE_MERGE_PROBE_CRASH:-0}" = "1" ]; then
  # ga-6zkhci gate-fix (T5): simulate the narrow merge-own probe (always
  # DRY_RUN=1) timing out or crashing before printing anything parseable —
  # what `timeout 180 ...` returns when the timeout fires. The WIDE-window
  # call (DRY_RUN unset/0, Step 5b's non-probe invocation) is untouched by
  # this guard, so T5 isolates the narrow probe's failure from the rest of
  # Step 5b.
  exit 124
fi
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null)"
# wa-xokje: model AFFECTED_NOT_RUNNING independently of the sensitive/live
# signal — a real deploy can reach a not-running scheduled job, a live
# sensitive daemon, both, or neither, and the two must combine correctly
# (T9: subtracting the scheduled job must never empty a set that still
# contains the live daemon).
AFF=""; AFF_NR=""; GRD=""
case "$CHANGED" in *scheduled*) AFF="$AFF com.test.scheduled-job"; AFF_NR="$AFF_NR com.test.scheduled-job" ;; esac
case "$CHANGED" in *notinstalled*) AFF="$AFF com.test.not-installed-job"; AFF_NR="$AFF_NR com.test.not-installed-job" ;; esac
case "$CHANGED" in
  *notinstalled*)
    # ga-nuou9v T10: mirrors real daemon-refresh.sh's emit() — Step 1b's
    # JOB_NOT_INSTALLED verdict is FORCED ahead of whatever Step 2/3 would
    # otherwise find (real emit(), gate ga-ax0t9), so this branch must be
    # checked before *sensitive* below, not after.
    echo "VERDICT=JOB_NOT_INSTALLED"
    echo "AFFECTED=${AFF# }"
    echo "AFFECTED_NOT_RUNNING=${AFF_NR# }"
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED="
    echo "REASON=scheduled-job plist(s) changed by this deploy are not actually installed for launchd to run them — missing from /fake/LaunchAgents: com.test.not-installed-job"
    exit 1
    ;;
  *sensitive*)
    AFF="$AFF com.test.central-sender"; GRD="$GRD com.test.central-sender"
    echo "VERDICT=NEEDS_GUARDED_RESTART"
    echo "AFFECTED=${AFF# }"
    echo "AFFECTED_NOT_RUNNING=${AFF_NR# }"
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED=${GRD# }"
    echo "REASON=sensitive hot-path daemon needs a guarded restart"
    exit 1
    ;;
  *scheduled*)
    echo "VERDICT=OK"
    echo "AFFECTED=${AFF# }"
    echo "AFFECTED_NOT_RUNNING=${AFF_NR# }"
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED="
    echo "REASON=changed code touches no live daemon (only a not-currently-running scheduled job)"
    exit 0
    ;;
  *)
    echo "VERDICT=OK"
    echo "AFFECTED="
    echo "AFFECTED_NOT_RUNNING="
    echo "RESTARTED="
    echo "FRESH_FAIL="
    echo "GUARDED="
    echo "REASON=no daemon imports the changed files"
    exit 0
    ;;
esac
EOF

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true
  SIMULATE_MERGE_PROBE_CRASH="$merge_probe_crash"
  export SIMULATE_MERGE_PROBE_CRASH

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  # True no-op pull (ga-gokm6's own scenario): PRE==POST==own tip, exactly
  # like a sibling story's delivery already advancing HEAD before this
  # iteration's own PRE_DEPLOY_SHA capture.
  local PRE_DEPLOY_SHA="$OWN_TIP_SHA" POST_DEPLOY_SHA="$OWN_TIP_SHA" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # MERGE_SHA is what Step 3 (pre-deploy merge verification, earlier in the
  # real script) would have set from the gate's merge comment — always this
  # story's own tip commit.
  local MERGE_SHA="$OWN_TIP_SHA" MERGE_REF="origin/main"
  # MERGE_PRE_MAIN is what extract_gate_merge_pre_main would have parsed from
  # that same comment (ga-6zkhci fix-attempt-3).
  local MERGE_PRE_MAIN
  case "$pre_main_mode" in
    correct) MERGE_PRE_MAIN="$SHA_C1" ;;
    missing) MERGE_PRE_MAIN="" ;;
    garbage) MERGE_PRE_MAIN="0000000000000000000000000000000000000000" ;;
    *)
      echo "run_block: unknown pre_main_mode '$pre_main_mode'" >&2
      exit 1
      ;;
  esac
  get_runbook_field() { echo "central-sender"; }

  rm -f "$T/reached.marker"
  if [ "$strict" = "1" ]; then
    # ga-6zkhci gate-fix (T5): production runs this whole file under
    # `set -euo pipefail` (story-delivery.sh line 32). The default subshell
    # below deliberately does NOT enable `-e` (T1-T3 rely on that to observe
    # BD_CALLS/GC_CALLS state after a continue-based halt rather than a hard
    # stop), which is exactly why gate-fix-attempt 1's missing `|| true` on
    # the probe-output reads slipped through unnoticed there — this harness
    # could not have observed that crash. Opt in to real errexit semantics
    # for any test that exercises the new fallback's guard chain.
    ( set -euo pipefail; for _t in _once; do eval "$BLOCK"; touch "$T/reached.marker"; done ) >/dev/null 2>&1
  else
    ( for _t in _once; do eval "$BLOCK"; touch "$T/reached.marker"; done ) >/dev/null 2>&1
  fi
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  [ -f "$T/reached.marker" ] && REACHED=1 || REACHED=0
  rm -rf "$T"
}

# ── T1: no-op pull, own merge is docs-only → NOT blamed (repro wa-ibaqq) ─────
run_block docs correct
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0)" || nok "T1 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=1" >/dev/null \
  && ok "T1 own-merge-only probe classified inert (docs-only)" \
  || nok "T1 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 1 ] && ok "T1 block falls through past the verdict (no continue) — delivery proceeds" \
  || nok "T1 fell through" "REACHED=$REACHED"
! echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T1 delivery:failed NOT added — innocent story not blamed" \
  || nok "T1 no failed-label" "$BD_CALLS"
echo "$GC_CALLS" | grep "session nudge mayor" >/dev/null \
  && ok "T1 Mayor still nudged — real staleness (C1) not silenced" \
  || nok "T1 mayor nudged" "$GC_CALLS"

# ── T2: no-op pull, own merge touches a file no live daemon reaches (not a
#        tests/docs/md path either) → NOT blamed (repro wa-mjpjs) ───────────
run_block harmless correct
[ "$RUN_RC" -eq 0 ] && ok "T2 block runs clean (rc=0)" || nok "T2 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=1" >/dev/null \
  && ok "T2 own-merge-only probe classified inert (harmless script, real reachability not a path pattern)" \
  || nok "T2 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 1 ] && ok "T2 block falls through past the verdict — delivery proceeds" \
  || nok "T2 fell through" "REACHED=$REACHED"
! echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T2 delivery:failed NOT added — innocent story not blamed" \
  || nok "T2 no failed-label" "$BD_CALLS"
# ga-nuou9v (ACEITE 3): T2's own delta is scripts/cron_only.py — NOT
# tests/**, docs/**, or *.md — so the nudge-to-mayor message must never
# claim "tests/docs/md-only" for it; that would be a false, specific factual
# claim about a delta that plainly isn't. It must give the real reason this
# delta was judged inert instead (it reaches no live daemon).
! echo "$GC_CALLS" | grep "tests/docs/md-only" >/dev/null \
  && ok "T2 nudge message does not falsely claim tests/docs/md-only for a non-tests/docs delta" \
  || nok "T2 nudge wording (false tests/docs/md-only claim)" "$GC_CALLS"
echo "$GC_CALLS" | grep "confirmed to reach no live daemon" >/dev/null \
  && ok "T2 nudge message gives the real, accurate reason" \
  || nok "T2 nudge wording (accurate reason)" "$GC_CALLS"

# ── T3: control — no-op pull, own merge DOES reach a (simulated) live
#        sensitive daemon → still blamed ────────────────────────────────────
run_block sensitive correct
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T3 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=0" >/dev/null \
  && ok "T3 own-merge-only probe classified NOT inert (control)" \
  || nok "T3 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T3 block halts via continue (does not fall through)" \
  || nok "T3 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T3 delivery:failed added — this story's own merge IS the cause" \
  || nok "T3 failed-label" "$BD_CALLS"
echo "$BD_CALLS" | grep "label add ga-test delivery:deploy-pending" >/dev/null \
  && ok "T3 delivery:deploy-pending added" \
  || nok "T3 deploy-pending" "$BD_CALLS"

# ── T4: MERGE_PRE_MAIN not persisted at all (older-format gate comment) →
#        fallback's 2nd guard fails closed → unknown → existing blame
#        behavior (Mayor's required test: "merge sem base gravada") ────────
run_block docs missing 0 1
[ "$RUN_RC" -eq 0 ] && ok "T4 block runs clean (rc=0)" || nok "T4 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=unknown" >/dev/null \
  && ok "T4 absent pre_merge_main → inert stays unknown (never guessed)" \
  || nok "T4 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T4 block halts via continue (falls back to existing blame behavior)" \
  || nok "T4 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T4 delivery:failed added — unknown attribution defaults to blame, not exemption" \
  || nok "T4 failed-label" "$BD_CALLS"

# ── T5: merge-own DRY_RUN=1 probe times out/crashes (no VERDICT= line at
#        all, e.g. `timeout 180` firing) → must fall back to unknown, same
#        as T4 (existing blame behavior), and — this is the actual gate FAIL
#        this test regresses — must NOT crash the whole delivery sweep.
#        fix-attempt 1 (gate_run ga-oaid6p) added the probe-output reads
#        without the `|| true` guard the adjacent REFRESH_PROOF line already
#        has; under `set -euo pipefail` a no-match grep piped into head/sed
#        kills the whole script, not just this story. Runs strict because
#        the default harness mode used by T1-T3 cannot observe this crash at
#        all (see run_block's strict branch above) ───────────────────────
run_block docs correct 1 1
[ "$RUN_RC" -eq 0 ] && ok "T5 block runs clean despite merge-own probe crash/timeout (rc=0)" \
  || nok "T5 rc — merge-own probe crash killed the whole block instead of falling back" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=unknown" >/dev/null \
  && ok "T5 unparseable probe output → inert stays unknown (never guessed)" \
  || nok "T5 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T5 block halts via continue (falls back to existing blame behavior, does not crash)" \
  || nok "T5 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T5 delivery:failed added — unknown attribution defaults to blame, not exemption" \
  || nok "T5 failed-label" "$BD_CALLS"

# ── T6: MERGE_PRE_MAIN present but unresolvable in RUNTIME_DIR (corrupted
#        comment / never fetched) → fallback's rev-parse guard fails closed
#        → unknown → existing blame behavior (preserves fix-attempt-1's
#        original "unusable base" coverage under the new mechanism) ───────
run_block docs garbage 0 1
[ "$RUN_RC" -eq 0 ] && ok "T6 block runs clean (rc=0)" || nok "T6 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=unknown" >/dev/null \
  && ok "T6 unresolvable pre_merge_main → inert stays unknown (never guessed)" \
  || nok "T6 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T6 block halts via continue (falls back to existing blame behavior)" \
  || nok "T6 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T6 delivery:failed added — unknown attribution defaults to blame, not exemption" \
  || nok "T6 failed-label" "$BD_CALLS"

# ── T7: THE fix-attempt-3 regression test (Mayor's required test #1). This
#        story's branch has TWO commits: C2 touches a live daemon's import
#        graph, C3 (the gate-fix-attempt commit) touches only a harmless
#        file. MERGE_PRE_MAIN correctly spans BOTH → probe sees C2's
#        sensitive file → inert=0 → still blamed. The old MERGE_SHA^
#        approach would diff only C2..C3 (C3's git-parent is C2, not the
#        true pre-story base) and wrongly exempt this story. ─────────────
run_block two_commit correct 0 1
[ "$RUN_RC" -eq 0 ] && ok "T7 block runs clean (rc=0)" || nok "T7 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=0" >/dev/null \
  && ok "T7 multi-commit own-merge probe classified NOT inert (pre_merge_main spans both commits)" \
  || nok "T7 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T7 block halts via continue (does not fall through)" \
  || nok "T7 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T7 delivery:failed added — earlier commit (C2) in this story's own branch IS the cause" \
  || nok "T7 failed-label" "$BD_CALLS"

# ── T8 (wa-xokje): no-op pull, own merge touches ONLY a file whose sole
#        reachable consumer is a not-running scheduled/one-shot job (repro
#        wa-bpbgp's scheduled-job half — scripts/detect_unloaded_committed_daemons.py,
#        consumed solely by daily com.whatsapp.unloaded-daemons-full-daily).
#        AFFECTED is non-empty (the probe DOES see the job) but
#        AFFECTED_NOT_RUNNING names it too, so AFFECTED_LIVE is empty →
#        inert=1 → NOT blamed. Pre-fix (raw AFFECTED, no subtraction) this
#        would have classified inert=0 and blamed the story forever — no
#        amount of retrying could ever have changed that outcome. ─────────
run_block scheduled_only correct
[ "$RUN_RC" -eq 0 ] && ok "T8 block runs clean (rc=0)" || nok "T8 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=1" >/dev/null \
  && ok "T8 own-merge-only probe classified inert (reaches only a not-running scheduled job)" \
  || nok "T8 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 1 ] && ok "T8 block falls through past the verdict — delivery proceeds" \
  || nok "T8 fell through" "REACHED=$REACHED"
! echo "$BD_CALLS" | grep "delivery:failed" >/dev/null \
  && ok "T8 delivery:failed NOT added — a self-healing scheduled job is not a reason to hold" \
  || nok "T8 no failed-label" "$BD_CALLS"
echo "$GC_CALLS" | grep "session nudge mayor" >/dev/null \
  && ok "T8 Mayor still nudged — real staleness (C1) not silenced" \
  || nok "T8 mayor nudged" "$GC_CALLS"

# ── T9 (wa-xokje): control — no-op pull, own merge reaches BOTH a not-running
#        scheduled job AND a live sensitive daemon in the same commit (repro
#        wa-bpbgp's ACTUAL full shape: scripts/detect_unloaded_committed_daemons.py
#        + the lazy-imported admin-dashboard dependency). Subtracting the
#        scheduled job must never empty a set that still contains the live
#        daemon → inert stays 0 → still blamed. Proves T8's fix doesn't
#        over-exempt the mixed case. ───────────────────────────────────────
run_block mixed_sensitive_scheduled correct
[ "$RUN_RC" -eq 0 ] && ok "T9 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T9 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=0" >/dev/null \
  && ok "T9 own-merge-only probe classified NOT inert (live daemon survives the subtraction)" \
  || nok "T9 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T9 block halts via continue (does not fall through)" \
  || nok "T9 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T9 delivery:failed added — the live daemon in this story's own merge IS a real cause" \
  || nok "T9 failed-label" "$BD_CALLS"

# ── T10 (ga-nuou9v, repro wa-s5fux): no-op pull, own merge SHIPS a scheduled
#        job's plist that is NOT installed/loaded in launchd (own merge ADDS
#        the plist + entrypoint; the "no live PID" it has is because launchd
#        was never told about it, not because it is a legitimately
#        self-healing scheduled job). Pre-fix: AFFECTED_NOT_RUNNING names the
#        not-installed label same as any legitimately-scheduled job, so
#        AFFECTED_LIVE was wrongly empty → inert=1 → exonerated → story:done
#        despite the job never having run (the exact wa-s5fux incident: the
#        watchdog job stayed uninstalled and the bead closed anyway). Post-fix:
#        VERDICT=JOB_NOT_INSTALLED forces inert=0 regardless of AFFECTED_LIVE
#        → delivery held, not closed, with an ACTION message that tells the
#        reader to install the job (not the generic "did not come up fresh"
#        text, which is actively wrong here — nothing ever ran to crash). ──
run_block job_not_installed correct
[ "$RUN_RC" -eq 0 ] && ok "T10 block runs clean (rc=0)" || nok "T10 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=0" >/dev/null \
  && ok "T10 own-merge-only probe classified NOT inert — JOB_NOT_INSTALLED never counts as self-heal" \
  || nok "T10 inert classification" "$LOG_OUT"
[ "$REACHED" -eq 0 ] && ok "T10 block halts via continue — delivery is held, not exonerated" \
  || nok "T10 halted" "REACHED=$REACHED"
echo "$BD_CALLS" | grep "label add ga-test delivery:failed" >/dev/null \
  && ok "T10 delivery:failed added — a never-installed job can never self-heal" \
  || nok "T10 failed-label" "$BD_CALLS"
echo "$BD_CALLS" | grep "label add ga-test delivery:deploy-pending" >/dev/null \
  && ok "T10 delivery:deploy-pending added" \
  || nok "T10 deploy-pending" "$BD_CALLS"
echo "$BD_CALLS" | grep -E "launchctl load|launchctl bootstrap" >/dev/null \
  && ok "T10 ACTION message tells the reader to install the job" \
  || nok "T10 ACTION message (install guidance)" "$BD_CALLS"
! echo "$BD_CALLS" | grep "did not come up fresh" >/dev/null \
  && ok "T10 ACTION message does NOT use the crash-oriented generic text (nothing ever ran)" \
  || nok "T10 ACTION message (wrong generic text)" "$BD_CALLS"

echo ""
echo "story-delivery daemon-refresh no-op attribution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
