#!/usr/bin/env bash
# gate-p8pg6y-mutex-skip-no-strike.selftest.sh (ga-p8pg6y)
#
# THE BUG (measured 2026-10-04, ga-u2p995 / crew/wa-worker/wa-sggome): the pre-review
# auto-rebase in quality-gate-dispatcher.sh takes the per-repo git mutex (imp18). When a
# live holder had it, the dispatcher logged "per-repo mutex held — transient skip" and
# did NOT attempt the rebase — and then handed that very sweep to the failed-rebase
# machinery: gate:rebase-fail-count 0->1->2, gate:exiled-tier5:2, and a comment saying
# "transient auto-rebase failure (worktree/push error — no stderr captured)". Two skips in
# two minutes exiled a healthy branch to tier 5 and head-of-line-blocked the queue.
# "I could not try" and "I tried and it failed" collapsed into one value (third state
# turned into a boolean); the generic classifier (ga-10uqmi block) even overwrote the
# mutex reason with the "worktree/push error" text.
#
# THE FIX: the skip site records REBASE_NOT_ATTEMPTED=1 (+ a reason), and the first thing
# the "branch is not current" block does is requeue such a marker with NO strike and exit.
#
# Strategy: extract the real blocks via SELFTEST-EXTRACT sentinels (mutex skip site,
# not-attempted intercept) and the real helper function, run them under `set -euo
# pipefail` with stubs that record every bd write, and chain them with the REAL ga-10uqmi
# classification block so the "classifier clobbers the reason" half of the bug is covered.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
WATCHDOG="${WATCHDOG_UNDER_TEST:-$SELF_DIR/../../../scripts/gate-recovery-watchdog.py}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-p8pg6y-mutex-skip-no-strike.selftest (ga-p8pg6y) =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-p8pg6y.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A recorded bd call looks like `bd -C /fake/city comment <id> <text>` — match that exactly, and scan
# label/status writes over the NON-comment lines only (a comment legitimately NAMES the labels it says it
# did not write).
COMMENT_RE='^bd -C [^ ]+ comment '
non_comment() { grep -Ev "$COMMENT_RE" "$1" || true; }

extract_block() { sed -n "/# SELFTEST-EXTRACT $1: BEGIN/,/# SELFTEST-EXTRACT $1: END/p" "$DISPATCHER"; }

SITE_BLOCK=$(extract_block ga-p8pg6y-mutex-skip-site)
INTERCEPT_BLOCK=$(extract_block ga-p8pg6y-not-attempted-intercept)
CLASSIFY_BLOCK=$(extract_block gate-10uqmi-rebase-fail-classify)
HELPER_FN=$(sed -n '/^gate_rebase_not_attempted_requeue() {/,/^}/p' "$DISPATCHER")

# ── Section A: the mutex skip SITE records "not attempted" ───────────────────────────
echo "-- A. mutex skip site"
if [ -z "$SITE_BLOCK" ]; then
  bad "A0 mutex-skip-site sentinel block missing — the skip site cannot be tested (fix not present)"
else
  ok "A0 located mutex-skip-site block via sentinel"
  # site_case <acquire: rc0|rc1|undef> [prestate]  -> prints HELD|NOT_ATTEMPTED|HAS_CONFLICT|WHY
  site_case() {
    local acq="$1" pre="${2:-}" h="$WORK/site.$$.sh"
    {
      echo 'set -euo pipefail'
      echo 'RIG_PATH=/fake/rig; HAS_CONFLICT=0; CONFLICT_KIND=""; CONFLICT_FILES=""'
      echo 'warn() { :; }'
      case "$acq" in
        rc0) echo 'git_mutex_acquire() { return 0; }' ;;
        rc1) echo 'git_mutex_acquire() { return 1; }' ;;
        undef) : ;;
      esac
      [ -n "$pre" ] && echo "$pre"
      printf '%s\n' "$SITE_BLOCK"
      echo 'printf "%s|%s|%s|%s" "${_REBASE_MUTEX_HELD:-?}" "${REBASE_NOT_ATTEMPTED:-unset}" "$HAS_CONFLICT" "${REBASE_NOT_ATTEMPTED_WHY:-}"'
    } > "$h"
    bash "$h" 2>&1
  }
  R=$(site_case rc1)
  IFS='|' read -r HELD NA HC WHY <<<"$R"
  [ "$NA" = "1" ] && ok "A1 mutex held -> REBASE_NOT_ATTEMPTED=1" || bad "A1 mutex held -> REBASE_NOT_ATTEMPTED='$NA' (want 1) [$R]"
  [ "$HC" = "1" ] && ok "A2 mutex held -> HAS_CONFLICT=1 (the rebase itself is still skipped)" || bad "A2 HAS_CONFLICT='$HC' (want 1)"
  [ "$HELD" = "0" ] && ok "A3 mutex held -> _REBASE_MUTEX_HELD=0 (nothing to release)" || bad "A3 _REBASE_MUTEX_HELD='$HELD' (want 0)"
  case "$WHY" in *mutex*) ok "A4 reason names the mutex" ;; *) bad "A4 reason does not name the mutex: '$WHY'" ;; esac
  R=$(site_case rc0)
  IFS='|' read -r HELD NA HC WHY <<<"$R"
  { [ "$NA" = "0" ] && [ "$HC" = "0" ] && [ "$HELD" = "1" ]; } && ok "A5 mutex acquired -> not-attempted=0, no conflict, held=1" || bad "A5 acquired case wrong: [$R]"
  R=$(site_case undef)
  IFS='|' read -r HELD NA HC WHY <<<"$R"
  { [ "$NA" = "0" ] && [ "$HC" = "0" ] && [ "$HELD" = "0" ]; } && ok "A6 mutex lib not loaded -> fail-soft, rebase proceeds (not-attempted=0)" || bad "A6 lib-missing case wrong: [$R]"
  R=$(site_case rc0 'REBASE_NOT_ATTEMPTED=1; REBASE_NOT_ATTEMPTED_WHY="stale from a previous marker"')
  IFS='|' read -r HELD NA HC WHY <<<"$R"
  { [ "$NA" = "0" ] && [ -z "$WHY" ]; } && ok "A7 flag is RESET each sweep (a prior marker's skip never leaks into this one)" || bad "A7 stale not-attempted state leaked: [$R]"
fi

# ── Section B: the disposition helper ────────────────────────────────────────────────
echo "-- B. gate_rebase_not_attempted_requeue"
if [ -z "$HELPER_FN" ]; then
  bad "B0 gate_rebase_not_attempted_requeue() missing — nothing requeues a not-attempted marker without a strike"
else
  ok "B0 located gate_rebase_not_attempted_requeue()"
  # helper_case <requeue_rc>  -> files: $WORK/h.bd (bd calls), $WORK/h.out (verdict/event/skipped)
  helper_case() {
    local rc="$1" h="$WORK/helper.$$.sh"
    : > "$WORK/h.bd"; : > "$WORK/h.out"
    {
      echo 'set -euo pipefail'
      echo "GC_CITY=/fake/city; REBASE_EVENT=''; REBASE_VERDICT=''"
      echo "bd() { printf 'bd %s\n' \"\$*\" >> '$WORK/h.bd'; }"
      echo "warn() { :; }"
      echo "gate_requeue_respecting_external() { printf 'requeue %s\n' \"\$*\" >> '$WORK/h.bd'; return $rc; }"
      echo "gate_requeue_note_skipped() { printf 'note_skipped rc=%s\n' \"\$1\" >> '$WORK/h.bd'; REBASE_EVENT=note_skipped; REBASE_VERDICT=SKIPPED; }"
      printf '%s\n' "$HELPER_FN"
      echo 'gate_rebase_not_attempted_requeue "ga-marker1" "crew/wa-worker/wa-sggome" "per-repo git mutex (imp18) not acquired for /fake/rig"'
      echo "printf 'event=%s\nverdict=%s\n' \"\$REBASE_EVENT\" \"\$REBASE_VERDICT\" > '$WORK/h.out'"
    } > "$h"
    bash "$h" >"$WORK/h.stdout" 2>&1; echo $? > "$WORK/h.rc"
  }
  helper_case 0
  [ "$(cat "$WORK/h.rc")" = "0" ] && ok "B1 helper returns 0 under set -e (requeue done)" || bad "B1 helper exited $(cat "$WORK/h.rc"): $(head -c 300 "$WORK/h.stdout")"
  grep -q '^requeue ga-marker1 queued dispatching$' "$WORK/h.bd" && ok "B2 marker requeued queued<-dispatching via the compare-before-write helper" || bad "B2 wrong/no requeue call: $(cat "$WORK/h.bd")"
  if non_comment "$WORK/h.bd" | grep -Eq 'label (add|remove)|rebase-fail-count|exiled-tier5|rebase-attempt|rebase-retry|retry-cooldown'; then
    bad "B3 STRIKE/EXILE/COOLDOWN label written for a not-attempted skip: $(non_comment "$WORK/h.bd" | grep -E 'label|rebase|exile|cooldown' | head -3)"
  else
    ok "B3 no strike, exile, retry or cooldown label written"
  fi
  CMT=$(grep -E "$COMMENT_RE" "$WORK/h.bd" || true)
  case "$CMT" in *mutex*) ok "B4 marker comment cites the mutex" ;; *) bad "B4 comment does not cite the mutex: '$CMT'" ;; esac
  case "$CMT" in *"worktree/push error"*|*"no stderr captured"*) bad "B5 comment still says worktree/push error / no stderr" ;; *) ok "B5 comment does not blame a worktree/push error" ;; esac
  VERDICT=$(sed -n 's/^verdict=//p' "$WORK/h.out"); EVENT=$(sed -n 's/^event=//p' "$WORK/h.out")
  case "$VERDICT" in "QUEUED ("*) ok "B6 verdict is a QUEUED ending (what the watchdog reads)" ;; *) bad "B6 verdict '$VERDICT' is not a QUEUED ending" ;; esac
  case "$VERDICT" in "QUEUED (retry"*) bad "B7 verdict starts 'QUEUED (retry' — gate-recovery-watchdog would call it a conflict-retry and spawn a repair dog" ;; *) ok "B7 verdict is not the conflict-retry kind (no repair dog)" ;; esac
  [ "$EVENT" = "dispatcher_autorebase_not_attempted" ] && ok "B8 event is dispatcher_autorebase_not_attempted" || bad "B8 event='$EVENT'"
  helper_case 10
  if grep -Eq "$COMMENT_RE" "$WORK/h.bd"; then bad "B9 external transition respected (rc=10) but a requeue comment was still written"; else ok "B9 rc=10 (respected external transition): no 'requeued' comment"; fi
  grep -q '^note_skipped rc=10$' "$WORK/h.bd" && ok "B10 rc=10 is narrated via gate_requeue_note_skipped, not as a requeue" || bad "B10 note_skipped not called: $(cat "$WORK/h.bd")"
  helper_case 1
  grep -q '^note_skipped rc=1$' "$WORK/h.bd" && ! grep -Eq "$COMMENT_RE" "$WORK/h.bd" && ok "B11 failed write (rc=1) is not narrated as a requeue" || bad "B11 failed-write case wrong: $(cat "$WORK/h.bd")"

  # B12: the verdict must land in the watchdog's LOG-ONLY bucket, checked with the watchdog's own regexes.
  if [ -f "$WATCHDOG" ] && command -v python3 >/dev/null 2>&1; then
    helper_case 0
    VERDICT=$(sed -n 's/^verdict=//p' "$WORK/h.out")
    KIND=$(WD="$WATCHDOG" V="$VERDICT" python3 - <<'PY'
import os, re
src = open(os.environ["WD"], encoding="utf-8", errors="replace").read()
def rx(name):
    # Read the pattern out of the watchdog's own `NAME = re.compile(r"...")` line and compile it —
    # no eval, so the test uses the watchdog's real pattern without executing watchdog source.
    m = re.search(r'^%s\s*=\s*re\.compile\(r"(.*)"\)\s*$' % name, src, re.M)
    return re.compile(m.group(1)) if m else None
retry, anyq = rx("SWEEP_QUEUED_RETRY_RE"), rx("SWEEP_QUEUED_ANY_RE")
line = "Dispatcher sweep complete: branch=fix/x verdict=" + os.environ["V"]
if retry is None or anyq is None: print("regex-missing")
elif retry.search(line): print("conflict-retry")
elif anyq.search(line): print("queued-other")
else: print("not-queued")
PY
)
    [ "$KIND" = "queued-other" ] && ok "B12 watchdog classifies the verdict as 'queued-other' (log-only, no repair dog)" || bad "B12 watchdog classifies the verdict as '$KIND' (want queued-other)"
  else
    echo "  - B12 skipped (watchdog source or python3 unavailable)"
  fi
fi

# ── Section C: the intercept, chained after the REAL classifier ──────────────────────
echo "-- C. intercept (site -> real ga-10uqmi classifier -> intercept)"
if [ -z "$INTERCEPT_BLOCK" ] || [ -z "$SITE_BLOCK" ] || [ -z "$HELPER_FN" ] || [ -z "$CLASSIFY_BLOCK" ]; then
  bad "C0 cannot chain site+classifier+intercept (missing: intercept=$([ -n "$INTERCEPT_BLOCK" ] && echo ok || echo MISSING) site=$([ -n "$SITE_BLOCK" ] && echo ok || echo MISSING) helper=$([ -n "$HELPER_FN" ] && echo ok || echo MISSING) classifier=$([ -n "$CLASSIFY_BLOCK" ] && echo ok || echo MISSING))"
else
  ok "C0 located intercept, site, helper and the real classifier"
  # chain_case <acquire rc0|rc1> -> $WORK/c.bd, $WORK/c.qg (jsonl), $WORK/c.stdout ; $WORK/c.rc
  chain_case() {
    local acq="$1" h="$WORK/chain.$$.sh"
    : > "$WORK/c.bd"; rm -f "$WORK/c.qg"
    {
      echo 'set -euo pipefail'
      echo "GC_CITY=/fake/city; QG_LOG='$WORK/c.qg'"
      echo 'RIG_PATH=/fake/rig; BRANCH=crew/wa-worker/wa-sggome; MARKER_ID=ga-marker1; BEAD_ID=ga-u2p995; AUTHOR=crew/wa-worker/wa-sggome'
      echo 'MAIN_HEAD_SHA=abc123; HAS_CONFLICT=0; CONFLICT_KIND=""; CONFLICT_FILES=""; REBASE_EVENT=""; REBASE_VERDICT=""'
      echo 'AUTO_REBASE_OK=0; BRANCH_IS_CURRENT=0; AUTO_REBASE_PUSH_ERR=""; AUTO_REBASE_PUSH_RC=""; AUTO_REBASE_SETUP_ERR=""; AUTO_MERGE_FALLBACK_ERR=""'
      echo 'PR_CONTENT_VERDICT=""; PR_COMMIT_VERDICT=""; _LOST_PATHS=""'
      echo 'log() { :; }; warn() { :; }; err() { :; }'
      echo "bd() { printf 'bd %s\n' \"\$*\" >> '$WORK/c.bd'; }"
      echo "gc() { printf 'gc %s\n' \"\$*\" >> '$WORK/c.bd'; }"
      echo "read_rebase_attempt() { echo 0; }; _gate_push_skip_reason() { echo skip-reason; }"
      echo "gate_requeue_respecting_external() { printf 'requeue %s\n' \"\$*\" >> '$WORK/c.bd'; return 0; }"
      echo "gate_requeue_note_skipped() { :; }; gate_marker_status_ensure() { echo ok; }"
      [ "$acq" = "rc1" ] && echo 'git_mutex_acquire() { return 1; }' || echo 'git_mutex_acquire() { return 0; }'
      printf '%s\n' "$HELPER_FN"
      printf '%s\n' "$SITE_BLOCK"
      # The real classifier runs between the (skipped) rebase and the bounce block in the dispatcher.
      printf '%s\n' "$CLASSIFY_BLOCK"
      printf '%s\n' "$INTERCEPT_BLOCK"
      echo 'echo FELL-THROUGH-TO-STRIKE-MACHINERY'
    } > "$h"
    bash "$h" >"$WORK/c.stdout" 2>&1; echo $? > "$WORK/c.rc"
  }

  chain_case rc1
  [ "$(cat "$WORK/c.rc")" = "0" ] && ok "C1 mutex-held sweep ends exit 0 in the intercept" || bad "C1 exit=$(cat "$WORK/c.rc"): $(head -c 400 "$WORK/c.stdout")"
  grep -q 'FELL-THROUGH-TO-STRIKE-MACHINERY' "$WORK/c.stdout" && bad "C2 mutex-held sweep FELL THROUGH to the strike machinery (counter/exile would run)" || ok "C2 mutex-held sweep never reaches the strike machinery"
  if non_comment "$WORK/c.bd" | grep -Eq 'rebase-fail-count|exiled-tier5|rebase-attempt|rebase-retry|retry-cooldown|gate-status:needs-rebase|mail send'; then
    bad "C3 strike/exile/park/mail write for a held mutex: $(non_comment "$WORK/c.bd" | grep -E 'rebase|exile|cooldown|needs-rebase|mail' | head -4)"
  else
    ok "C3 gate:rebase-fail-count / gate:exiled-tier5 / needs-rebase / mail all untouched (counter does not rise)"
  fi
  grep -q '^requeue ga-marker1 queued dispatching$' "$WORK/c.bd" && ok "C4 marker requeued so the next sweep retries it" || bad "C4 marker not requeued: $(cat "$WORK/c.bd")"
  if [ -f "$WORK/c.qg" ]; then
    jq -e '.event=="dispatcher_autorebase_not_attempted" and (.conflicts|test("mutex")) and ((.conflicts|test("worktree/push"))|not)' "$WORK/c.qg" >/dev/null 2>&1 \
      && ok "C5 QG log says not-attempted and cites the mutex (not 'worktree/push error')" || bad "C5 QG log wrong: $(cat "$WORK/c.qg")"
  else
    bad "C5 no QG log line written"
  fi
  chain_case rc0
  grep -q 'FELL-THROUGH-TO-STRIKE-MACHINERY' "$WORK/c.stdout" && ok "C6 negative control: mutex ACQUIRED -> intercept does not fire, flow continues to the normal failure path" || bad "C6 intercept fired although the mutex was acquired: $(head -c 300 "$WORK/c.stdout")"
fi

# ── Section D: drift guards on the dispatcher source ─────────────────────────────────
echo "-- D. source drift guards"
BOUNCE_LN=$(awk '/^  if \[ "\$BRANCH_IS_CURRENT" != "1" \]; then$/ {print NR; exit}' "$DISPATCHER")
INTERCEPT_LN=$(awk '/# SELFTEST-EXTRACT ga-p8pg6y-not-attempted-intercept: BEGIN/ {print NR; exit}' "$DISPATCHER")
MAXATT_LN=$(awk '/^    MAX_REBASE_ATTEMPTS=3$/ {print NR; exit}' "$DISPATCHER")
STRIKE_LN=$(awk '/label add +"\$MARKER_ID" "gate:rebase-fail-count:\$NEXT_ATTEMPT"/ {print NR; exit}' "$DISPATCHER")
if [ -n "$BOUNCE_LN" ] && [ -n "$INTERCEPT_LN" ] && [ -n "$MAXATT_LN" ] && [ -n "$STRIKE_LN" ] \
   && [ "$BOUNCE_LN" -lt "$INTERCEPT_LN" ] && [ "$INTERCEPT_LN" -lt "$MAXATT_LN" ] && [ "$MAXATT_LN" -lt "$STRIKE_LN" ]; then
  ok "D1 intercept sits at the head of the 'branch not current' block, before every counter/exile write (L$BOUNCE_LN < L$INTERCEPT_LN < L$MAXATT_LN < L$STRIKE_LN)"
else
  bad "D1 intercept is not ahead of the strike machinery (bounce=${BOUNCE_LN:-?} intercept=${INTERCEPT_LN:-?} max_attempts=${MAXATT_LN:-?} strike=${STRIKE_LN:-?})"
fi
if printf '%s\n' "$INTERCEPT_BLOCK" | grep -q '^      exit 0$'; then ok "D2 intercept terminates the sweep (exit 0) so nothing below it can strike"; else bad "D2 intercept does not exit 0"; fi
if [ -z "$INTERCEPT_BLOCK" ] || [ -z "$HELPER_FN" ]; then
  bad "D3 cannot check the intercept/helper for direct label writes — one of them is missing"
elif printf '%s\n' "$INTERCEPT_BLOCK" "$HELPER_FN" | grep -Eq 'label (add|remove)|set_gate_status|gate_retry_cooldown_stamp'; then
  bad "D3 intercept/helper writes labels or raw status directly (must go through gate_requeue_respecting_external only)"
else
  ok "D3 intercept/helper write no labels and no raw set_gate_status"
fi

echo
echo "gate-p8pg6y-mutex-skip-no-strike: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
