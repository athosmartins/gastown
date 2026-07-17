#!/usr/bin/env bash
# gate-verdict-status-unreadable.selftest.sh (ga-art5, remaining sites)
#
# Proves: a FAILED `bd show` on a verdict bead never produces the same
# decision as a genuinely-open (or genuinely-closed) one. ga-art5's own
# proof: `... || true` + `jq '.status // "open"'` made a transient query
# failure (VB_STATUS="") and a real open verdict (VB_STATUS="open") both
# satisfy `!= closed`, so a Dolt hiccup and an honest "still reviewing" read
# took the IDENTICAL action — including, at the hard-close sites, a comment
# asserting a fact ("reviewer session did not complete") that the code has
# no basis for when what actually failed was the query, not the reviewer.
#
# ga-oiu7/dog-gaplbk already fixed the two ga-eqjo/ga-x3nmz requeue loops
# (gate_finalize_run) using a new pure classifier, vb_status_action()
# (unknown/skip/requeue) — see this file's own selftest coverage gap: that
# fix landed (commit 055cc4f5) but its selftest never got committed (dog
# pool-slot collision, see [[shared-root-edit-worktree-first-not-last]]).
# This selftest covers BOTH that gap and the three sites ga-s07s closes:
#   - vb_status_action() / session_is_dead(): direct unit coverage (pure,
#     no I/O) — the classifier itself had ZERO test coverage before this.
#   - gate_collect_verdicts(): an unreadable VB is skipped, not miscounted.
#   - phase-c-dead-reviewer-classify-fn: an unreadable VB can't be confirmed
#     dead, so the run falls through to the (safe) TIMEOUT path instead of
#     the lenient dead-reviewer requeue shortcut.
#   - phase-c-timeout-close-fn: an unreadable VB is left untouched — no
#     verdict:TIMEOUT label, no false "did not complete" comment, no close.
#     This is the highest-severity site (a hard terminal action), so it
#     gets a MUTATION TEST proving the suite isn't vacuous.
#
# Strategy: extract each block VERBATIM via SELFTEST-EXTRACT markers (real
# production code, not a hand-maintained duplicate) and run under real
# `set -euo pipefail`, stubbing only the I/O boundary (`bd`, `gc`, `log`,
# `warn`). Mirrors gate-verdict-drained-reviewer-rescue.selftest.sh's proven
# harness shape.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-verdict-status-unreadable.selftest (ga-art5) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# ── Part 1: vb_status_action() — pure, direct unit tests ────────────────────
echo "── 1. vb_status_action(): pure classifier unit coverage ──"
FN_VSA="$(extract_block "$DISPATCHER" "vb-status-action-fn")"
if [ -z "$FN_VSA" ]; then
  bad "could not extract vb-status-action-fn block — aborting Part 1"
else
  eval "$FN_VSA"
  [ "$(vb_status_action "__UNKNOWN__")" = "unknown" ] \
    && ok "__UNKNOWN__ sentinel -> unknown" \
    || bad "__UNKNOWN__ sentinel did not classify as unknown"
  [ "$(vb_status_action "closed")" = "skip" ] \
    && ok "closed -> skip" \
    || bad "closed did not classify as skip"
  [ "$(vb_status_action "open")" = "requeue" ] \
    && ok "open -> requeue" \
    || bad "open did not classify as requeue"
  [ "$(vb_status_action "TIMEOUT")" = "requeue" ] \
    && ok "any other real status (e.g. TIMEOUT) -> requeue" \
    || bad "TIMEOUT did not classify as requeue"
fi

# ── Part 2: session_is_dead() — pure, direct unit tests ──────────────────────
echo "── 2. session_is_dead(): pure liveness classifier unit coverage ──"
FN_SID="$(extract_block "$DISPATCHER" "session-is-dead-fn")"
if [ -z "$FN_SID" ]; then
  bad "could not extract session-is-dead-fn block — aborting Part 2"
else
  eval "$FN_SID"
  [ "$(session_is_dead 0 false)" = "1" ] \
    && ok "absent session (present=0) -> dead" \
    || bad "absent session did not classify as dead"
  [ "$(session_is_dead 1 true)" = "1" ] \
    && ok "present but closed=true -> dead" \
    || bad "present+closed did not classify as dead"
  [ "$(session_is_dead 1 false)" = "0" ] \
    && ok "present and closed=false -> alive" \
    || bad "present+not-closed did not classify as alive"
fi

# ── Part 3: gate_collect_verdicts() — an unreadable VB is skipped, not ──────
# miscounted as pending (the pre-fix behavior was already inert for this
# site — see ga-s07s's investigation notes — but the raw `|| echo "[]"` idiom
# it used is exactly the C2 shape error-empty-conflation-scan.sh flags, and a
# reader could not previously tell "still pending" from "couldn't read" in
# the logs). This proves: no crash, no mis-count, no destructive action.
echo "── 3. gate_collect_verdicts(): bd-show failure is skipped, not mis-counted ──"
FN_COLLECT="$(extract_block "$DISPATCHER" "gate-collect-verdicts-fn")"
if [ -z "$FN_COLLECT" ]; then
  bad "could not extract gate-collect-verdicts-fn block — aborting Part 3"
else
  BD_LOG3="$(mktemp)"
  OUT3="$(bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"
    BD_LOG="$1"
    VB_CLOSED_PASS='"'"'{"status":"closed","labels":["verdict:PASS"]}'"'"'
    VB_PENDING='"'"'{"status":"open","labels":[]}'"'"'
    VERDICT_BEAD_IDS=(vb-closed-pass vb-pending vb-unreadable)
    bd() {
      case " $* " in
        *" show vb-closed-pass "*) echo "$VB_CLOSED_PASS"; return 0 ;;
        *" show vb-pending "*)     echo "$VB_PENDING"; return 0 ;;
        *" show vb-unreadable "*)  echo "bd: transient Dolt hiccup" >&2; return 1 ;;
        *" comments "*)            echo "[]"; return 0 ;;
        *)                         echo "UNEXPECTED:$*" >> "$BD_LOG"; return 0 ;;
      esac
    }
    log()  { echo "LOG: $*" >&2; }
    warn() { echo "WARN: $*" >&2; }
    session_peek_reports_dead() { echo 0; }
    '"$FN_COLLECT"'
    gate_collect_verdicts
    printf "RESULT|VERDICTS_RECEIVED=%s|ANY_FAIL=%s\n" "$VERDICTS_RECEIVED" "$ANY_FAIL"
  ' _ "$BD_LOG3" 2>&1)"
  RC3=$?
  RESULT3="$(printf '%s\n' "$OUT3" | grep '^RESULT|' || true)"
  if [ "$RC3" -eq 0 ] && [ -n "$RESULT3" ]; then
    ok "gate_collect_verdicts runs to completion with an unreadable VB present (rc=0)"
  else
    bad "gate_collect_verdicts crashed or produced no result (rc=$RC3): $OUT3"
  fi
  VR3=$(printf '%s' "$RESULT3" | sed -n 's/.*VERDICTS_RECEIVED=\([0-9]*\).*/\1/p')
  [ "$VR3" = "1" ] \
    && ok "VERDICTS_RECEIVED=1 (only the closed bead counted; unreadable and pending both correctly excluded)" \
    || bad "VERDICTS_RECEIVED expected 1, got '$VR3'"
  case "$OUT3" in
    *"vb-unreadable"*"unreadable"*) ok "unreadable VB is named in the diagnostic log (distinguishable from genuinely-pending)" ;;
    *) bad "no diagnostic log line naming vb-unreadable as unreadable" ;;
  esac
  if grep -q "UNEXPECTED" "$BD_LOG3"; then
    bad "unexpected bd call recorded: $(cat "$BD_LOG3")"
  else
    ok "no destructive/unexpected bd call fired for the unreadable VB"
  fi
  rm -f "$BD_LOG3"
fi

# ── Part 4: phase-c-dead-reviewer-classify-fn — an unreadable VB can't be ───
# confirmed dead, so PC_ALL_PENDING_DEAD must drop to 0 (same effect as
# finding a confirmed-LIVE reviewer) rather than silently defaulting to
# "open" and potentially being misread as a dead one.
echo "── 4. phase-c-dead-reviewer-classify-fn: unreadable VB blocks the all-dead verdict ──"
FN_CLASSIFY="$(extract_block "$DISPATCHER" "phase-c-dead-reviewer-classify-fn")"
FN_SID2="$(extract_block "$DISPATCHER" "session-is-dead-fn")"
if [ -z "$FN_CLASSIFY" ] || [ -z "$FN_SID2" ]; then
  bad "could not extract phase-c-dead-reviewer-classify-fn or session-is-dead-fn — aborting Part 4"
else
  run_classify() {
    local vb1_ok="$1"  # "ok" or "fail" — controls whether bd show for pc-vb-1 succeeds
    bash -c '
      set -euo pipefail
      GC_CITY="/fake/city"
      VB1_OK="$1"
      VB_OPEN_DEAD='"'"'{"status":"open"}'"'"'
      VERDICT_BEAD_IDS=(pc-vb-1 pc-vb-2)
      SESSION_IDS=(sess-1 sess-2)
      PC_SESS_JSON="[]"   # empty session list -> every session is absent -> dead
      PC_ANY_PENDING=0
      PC_ALL_PENDING_DEAD=1
      bd() {
        case " $* " in
          *" show pc-vb-1 "*)
            if [ "$VB1_OK" = "fail" ]; then echo "transient" >&2; return 1; fi
            echo "$VB_OPEN_DEAD"; return 0 ;;
          *" show pc-vb-2 "*) echo "$VB_OPEN_DEAD"; return 0 ;;
        esac
        return 0
      }
      warn() { echo "WARN: $*" >&2; }
      '"$FN_SID2"'
      '"$FN_CLASSIFY"'
      printf "RESULT|PC_ANY_PENDING=%s|PC_ALL_PENDING_DEAD=%s\n" "$PC_ANY_PENDING" "$PC_ALL_PENDING_DEAD"
    ' _ "$vb1_ok"
  }

  OUT4_BASE="$(run_classify ok 2>&1)"; RC4_BASE=$?
  RES4_BASE="$(printf '%s\n' "$OUT4_BASE" | grep '^RESULT|' || true)"
  if [ "$RC4_BASE" -eq 0 ] && printf '%s' "$RES4_BASE" | grep -q "PC_ALL_PENDING_DEAD=1"; then
    ok "baseline (both VBs readable, both sessions absent): PC_ALL_PENDING_DEAD=1 — happy path unaffected by this fix"
  else
    bad "baseline classification broken (rc=$RC4_BASE): $OUT4_BASE"
  fi

  OUT4_FAIL="$(run_classify fail 2>&1)"; RC4_FAIL=$?
  RES4_FAIL="$(printf '%s\n' "$OUT4_FAIL" | grep '^RESULT|' || true)"
  if [ "$RC4_FAIL" -eq 0 ] && printf '%s' "$RES4_FAIL" | grep -q "PC_ALL_PENDING_DEAD=0"; then
    ok "pc-vb-1 unreadable: PC_ALL_PENDING_DEAD=0 (falls through to the safe TIMEOUT path instead of guessing) — got: $RES4_FAIL"
  else
    bad "pc-vb-1 unreadable did NOT force PC_ALL_PENDING_DEAD=0 (rc=$RC4_FAIL): $OUT4_FAIL"
  fi
fi

# ── Part 5: phase-c-timeout-close-fn — an unreadable VB is never closed ─────
# with a false "did not complete" claim. MUTATION TESTED (highest-severity
# site: a hard terminal bd close).
echo "── 5. phase-c-timeout-close-fn: unreadable VB is left untouched (no false close) ──"
FN_CLOSE="$(extract_block "$DISPATCHER" "phase-c-timeout-close-fn")"
FN_VSA2="$(extract_block "$DISPATCHER" "vb-status-action-fn")"
if [ -z "$FN_CLOSE" ] || [ -z "$FN_VSA2" ]; then
  bad "could not extract phase-c-timeout-close-fn or vb-status-action-fn — aborting Part 5"
else
  run_close() {
    local file_fn="$1" bd_log="$2"
    : > "$bd_log"
    bash -c '
      set -euo pipefail
      GC_CITY="/fake/city"
      BD_LOG="$1"
      PC_TIMEOUT_MIN=30
      VB_OPEN='"'"'{"status":"open"}'"'"'
      VB_CLOSED='"'"'{"status":"closed"}'"'"'
      VERDICT_BEAD_IDS=(pc-open pc-closed pc-unreadable)
      bd() {
        case " $* " in
          *" show pc-open "*)       echo "$VB_OPEN"; return 0 ;;
          *" show pc-closed "*)     echo "$VB_CLOSED"; return 0 ;;
          *" show pc-unreadable "*) echo "transient Dolt hiccup" >&2; return 1 ;;
          *" label "*|*" comment "*|*" close "*) echo "$*" >> "$BD_LOG"; return 0 ;;
        esac
        return 0
      }
      log()  { echo "LOG: $*" >&2; }
      warn() { echo "WARN: $*" >&2; }
      '"$file_fn"'
    ' _ "$bd_log"
    return $?
  }

  BD_LOG5="$(mktemp)"
  OUT5="$(run_close "$FN_VSA2
$FN_CLOSE" "$BD_LOG5" 2>&1)"
  RC5=$?
  if [ "$RC5" -eq 0 ]; then
    ok "phase-c-timeout-close-fn runs to completion with an unreadable VB present (rc=0)"
  else
    bad "phase-c-timeout-close-fn crashed (rc=$RC5): $OUT5"
  fi
  grep -q "close pc-open" "$BD_LOG5" \
    && ok "pc-open (genuinely open, readable) IS closed as TIMEOUT — happy path unaffected by this fix" \
    || bad "pc-open was NOT closed — happy path broken: $(cat "$BD_LOG5")"
  grep -q "close pc-closed" "$BD_LOG5" \
    && bad "pc-closed (already closed) was redundantly re-closed" \
    || ok "pc-closed (already closed) was left alone — no redundant close"
  if grep -q "pc-unreadable" "$BD_LOG5"; then
    bad "pc-unreadable was labeled/commented/closed despite bd show FAILING — the exact ga-art5 bug: query failure produced the same action as a genuinely-open bead. bd_log: $(cat "$BD_LOG5")"
  else
    ok "pc-unreadable was NEVER labeled/commented/closed — no false 'did not complete' claim written on a query failure"
  fi
  case "$OUT5" in
    *"pc-unreadable"*"unreadable"*) ok "unreadable VB is named in the diagnostic log" ;;
    *) bad "no diagnostic log line naming pc-unreadable as unreadable" ;;
  esac
  rm -f "$BD_LOG5"

  echo "── 5b. MUTATION TEST: removing the unknown-guard must revert to the pre-fix bug ──"
  MUT5="$(mktemp "${TMPDIR:-/tmp}/gate-timeout-close-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-timeout-close-mutant-$$.sh")"
  trap 'rm -f "$MUT5"' EXIT
  cp "$DISPATCHER" "$MUT5"
  MUTATE_OK5=0
  python3 - "$MUT5" <<'PYEOF' && MUTATE_OK5=1
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
anchor = '''            if PC_VB_JSON=$(bd -C "$GC_CITY" show "$PC_VB" --json 2>/dev/null); then
              PC_VB_STATUS=$(printf '%s' "$PC_VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)
            else
              PC_VB_STATUS="__UNKNOWN__"
            fi'''
n = c.count(anchor)
if n != 1:
    print("ANCHOR_NOT_UNIQUE count=%d" % n, file=sys.stderr)
    sys.exit(1)
# Reverts to the exact pre-fix idiom: a failed `bd show` silently masks to
# an empty PC_VB_STATUS via `|| true`, which vb_status_action() then reads
# as "requeue" (not "__UNKNOWN__"), reproducing ga-art5's original bug.
mutant = '''            PC_VB_STATUS=$(bd -C "$GC_CITY" show "$PC_VB" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || true)'''
c2 = c.replace(anchor, mutant, 1)
if c2 == c:
    print("SWAP_NO_OP", file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.write(c2)
PYEOF
  if [ "$MUTATE_OK5" != "1" ]; then
    bad "mutation-test: could not construct the mutant (anchor not found exactly once — source shape changed?) — INCONCLUSIVE, treat as FAIL"
  else
    FN_CLOSE_MUT="$(extract_block "$MUT5" "phase-c-timeout-close-fn")"
    FN_VSA_MUT="$(extract_block "$MUT5" "vb-status-action-fn")"
    BD_LOG5M="$(mktemp)"
    OUT5M="$(run_close "$FN_VSA_MUT
$FN_CLOSE_MUT" "$BD_LOG5M" 2>&1)"
    if grep -q "close pc-unreadable" "$BD_LOG5M"; then
      ok "mutant (rc-capture reverted to the pre-fix masked pipe): pc-unreadable IS falsely closed — reproduces the pre-fix ga-art5 bug, proving this test is not vacuous"
    else
      bad "mutant did NOT reproduce the pre-fix bug — test may be vacuous. bd_log: $(cat "$BD_LOG5M")"
    fi
    rm -f "$BD_LOG5M"
  fi
  rm -f "$MUT5"
fi

echo ""
echo "== gate-verdict-status-unreadable: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
