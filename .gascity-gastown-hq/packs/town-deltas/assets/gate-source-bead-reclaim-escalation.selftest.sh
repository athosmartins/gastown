#!/usr/bin/env bash
# gate-source-bead-reclaim-escalation.selftest.sh (ga-v5acl)
#
# ORIGIN: ga-sencl's investigation (ERRATA-scoped) found 4 call-sites in
# quality-gate-dispatcher.sh that clear a source bead's builder assignee
# and/or close it once a gate PASS (or an already-merged/superseded
# short-circuit) has driven the bead to its terminal state — and each of
# the 4 handled a *refused* clear/close differently:
#   A ~3646  PASS path, shared step 1 (clear assignee, every source bead):
#            failure -> only `warn`, never retried.
#   B ~3707  PASS path, bug/task close: failure -> escalates to
#            `bd assign ... --force` + `bd close ... --force`
#            UNCONDITIONALLY — never checks the claim is actually abandoned.
#            This is the dangerous one: bd's own `--force` help text says
#            "use only for abandoned claims... prefer bd reclaim".
#   C ~5540  Step 0a-4 (stranded needs-rebase reaper): failure -> silent
#            `|| true`, not even a warn.
#   D ~6350  Step 4b (already-merged short-circuit): failure -> `warn`,
#            never retried.
#
# FIX: two shared functions (gate_release_stale_assignee /
# gate_close_source_terminal, defined in quality-gate-dispatcher.sh before
# the GATE_DISPATCHER_LIB_ONLY early-return, each under its own
# SELFTEST-EXTRACT markers), both escalating via
#   bd reclaim --id <id> --older-than 0s
# — which (per `bd reclaim --help`) reverts ONLY a lease that has ALREADY
# expired, never a live one — instead of blind --force. All 4 call sites now
# route through these two functions.
#
# THIS FILE proves the two shared functions themselves: lease-stale
# escalates successfully via reclaim; lease-live is refused safely, with
# --force NEVER appearing in any code path. It also runs a handful of
# structural drift-guards over the live dispatcher source proving the old
# dangerous/silent patterns are actually gone from all 4 sites, not just
# from the two new functions in isolation.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-source-bead-reclaim-escalation.selftest (ga-v5acl) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

FN_RELEASE="$(extract_block "$DISPATCHER" "gate-release-stale-assignee-fn")"
FN_CLOSE_TERM="$(extract_block "$DISPATCHER" "gate-close-source-terminal-fn")"

if [ -z "$FN_RELEASE" ] || [ -z "$FN_CLOSE_TERM" ]; then
  echo "FATAL: could not extract gate_release_stale_assignee and/or gate_close_source_terminal via SELFTEST-EXTRACT markers — aborting" >&2
  exit 2
fi

# ── Part 1: gate_release_stale_assignee — lease stale vs lease live ─────────
echo "── 1. gate_release_stale_assignee: stale lease reclaims and clears; live lease is never forced ──"

# scenario "stale": 1st assign refused (looks live), reclaim runs (bd's own
#   TTL check would find the lease actually expired), 2nd assign succeeds.
# scenario "live":  1st assign refused, reclaim runs (best-effort — bd's own
#   TTL check finds the lease genuinely NOT expired and no-ops), 2nd assign
#   is refused again for the same reason. Nothing must ever be forced.
run_release() {
  local scenario="$1" log="$2"
  : > "$log"
  bash -c '
    set -euo pipefail
    SCENARIO="$1"; BD_LOG="$2"
    ASSIGN_CALLS=0
    bd() {
      echo "$*" >> "$BD_LOG"
      case " $* " in
        *" assign "*)
          ASSIGN_CALLS=$((ASSIGN_CALLS + 1))
          if [ "$ASSIGN_CALLS" -eq 1 ]; then
            return 1
          fi
          [ "$SCENARIO" = stale ] && return 0 || return 1
          ;;
        *" reclaim "*) return 0 ;;
      esac
      return 0
    }
    '"$FN_RELEASE"'
    RC=0
    gate_release_stale_assignee "src-bead" "/fake/city" || RC=$?
    exit "$RC"
  ' _ "$scenario" "$log"
  return $?
}

LOG_STALE="$(mktemp)"
run_release stale "$LOG_STALE"; RC_STALE=$?
[ "$RC_STALE" -eq 0 ] \
  && ok "(stale) function returns 0 — assignee successfully released after reclaim" \
  || bad "(stale) function returned $RC_STALE, expected 0 — log: $(cat "$LOG_STALE")"
grep -q "reclaim --id src-bead --older-than 0s" "$LOG_STALE" \
  && ok "(stale) bd reclaim --id src-bead --older-than 0s was called before the retry" \
  || bad "(stale) reclaim was not called with the expected args — log: $(cat "$LOG_STALE")"
grep -q -- "--force" "$LOG_STALE" \
  && bad "(stale) --force appeared in a bd call — must NEVER be used. log: $(cat "$LOG_STALE")" \
  || ok "(stale) --force never used"
rm -f "$LOG_STALE"

LOG_LIVE="$(mktemp)"
run_release live "$LOG_LIVE"; RC_LIVE=$?
[ "$RC_LIVE" -ne 0 ] \
  && ok "(live) function returns non-zero — a genuinely-live claim is NOT force-cleared" \
  || bad "(live) function returned 0 on a live claim — a live claim would have been silently cleared"
grep -q "reclaim --id src-bead --older-than 0s" "$LOG_LIVE" \
  && ok "(live) bd reclaim was still attempted (best-effort — bd's own TTL check is the real gate, and correctly no-ops)" \
  || bad "(live) expected a reclaim attempt even on the live path — log: $(cat "$LOG_LIVE")"
grep -q -- "--force" "$LOG_LIVE" \
  && bad "(live) --force appeared in a bd call — must NEVER be used. log: $(cat "$LOG_LIVE")" \
  || ok "(live) --force never used — claim remains intact, nothing forced"
rm -f "$LOG_LIVE"

# ── Part 2: gate_close_source_terminal — lease stale vs lease live ──────────
echo "── 2. gate_close_source_terminal: stale lease closes via reclaim; live lease is never forced ──"

run_close() {
  local scenario="$1" log="$2"
  : > "$log"
  bash -c '
    set -euo pipefail
    SCENARIO="$1"; BD_LOG="$2"
    # gate_close_source_terminal calls its FIRST close via a command
    # substitution ($(...), to capture the error text) — that forks a
    # subshell, so a plain shell-variable increment inside this mock would be
    # invisible to the SECOND (direct, no-subshell) retry call. Count via a
    # FILE instead, same technique gate-spawn-transient-retry.selftest.sh
    # uses for the identical reason.
    CLOSE_CALL_LOG="$(mktemp)"
    bd() {
      echo "$*" >> "$BD_LOG"
      case " $* " in
        *" close "*)
          echo x >> "$CLOSE_CALL_LOG"
          _n=$(wc -l < "$CLOSE_CALL_LOG" | tr -d "[:space:]")
          if [ "$_n" -eq 1 ]; then
            echo "cannot close src-bead: assignee is somebody, actor is dispatcher; reclaim or use --force" >&2
            return 1
          fi
          [ "$SCENARIO" = stale ] && return 0 || return 1
          ;;
        *" reclaim "*) return 0 ;;
      esac
      return 0
    }
    warn() { echo "WARN: $*" >&2; }
    '"$FN_CLOSE_TERM"'
    RC=0
    gate_close_source_terminal "src-bead" "closed by test (ga-v5acl)" "/fake/city" || RC=$?
    exit "$RC"
  ' _ "$scenario" "$log"
  return $?
}

LOG_CSTALE="$(mktemp)"
run_close stale "$LOG_CSTALE"; RCC_STALE=$?
[ "$RCC_STALE" -eq 0 ] \
  && ok "(stale) close succeeds after reclaim" \
  || bad "(stale) close returned $RCC_STALE, expected 0 — log: $(cat "$LOG_CSTALE")"
grep -q "reclaim --id src-bead --older-than 0s" "$LOG_CSTALE" \
  && ok "(stale) reclaim called before the close retry" \
  || bad "(stale) reclaim not called — log: $(cat "$LOG_CSTALE")"
grep -q -- "--force" "$LOG_CSTALE" \
  && bad "(stale) --force used in close path — log: $(cat "$LOG_CSTALE")" \
  || ok "(stale) --force never used in close path"
rm -f "$LOG_CSTALE"

LOG_CLIVE="$(mktemp)"
run_close live "$LOG_CLIVE"; RCC_LIVE=$?
[ "$RCC_LIVE" -ne 0 ] \
  && ok "(live) close correctly fails — a genuinely-live claim is NOT force-closed" \
  || bad "(live) close returned 0 on a live claim — a live worker's bead would have been force-closed out from under it"
grep -q -- "--force" "$LOG_CLIVE" \
  && bad "(live) --force used in close path — log: $(cat "$LOG_CLIVE")" \
  || ok "(live) --force never used — bead remains open, claim intact"
rm -f "$LOG_CLIVE"

# ── Part 3: structural — all 4 call-sites wired in; old dangerous/silent ────
# patterns are gone from the live dispatcher source (not just from the two
# functions tested in isolation above).
echo "── 3. structural: --force is gone everywhere; shared functions are wired into >=3 sites each ──"

FORCE_HITS=$(grep -nE 'bd -C "\$[A-Za-z_]+" (assign|close) .*--force' "$DISPATCHER" || true)
if [ -z "$FORCE_HITS" ]; then
  ok "no unconditional 'bd assign/close ... --force' remains anywhere in the dispatcher (ga-v5acl removed the last 2, at the old site B)"
else
  bad "found leftover --force on bd assign/close:
$FORCE_HITS"
fi

RELEASE_SITES=$(grep -c 'gate_release_stale_assignee "\$BEAD_ID"' "$DISPATCHER" || true)
if [ "${RELEASE_SITES:-0}" -ge 3 ]; then
  ok "gate_release_stale_assignee is called at >=3 sites (A/C/D) — count=$RELEASE_SITES"
else
  bad "gate_release_stale_assignee called at fewer than 3 sites — count=${RELEASE_SITES:-0}"
fi

CLOSE_SITES=$(grep -c 'gate_close_source_terminal "\$BEAD_ID"' "$DISPATCHER" || true)
if [ "${CLOSE_SITES:-0}" -ge 3 ]; then
  ok "gate_close_source_terminal is called at >=3 sites (B/C/D) — count=$CLOSE_SITES"
else
  bad "gate_close_source_terminal called at fewer than 3 sites — count=${CLOSE_SITES:-0}"
fi

SILENT_CLEAR_HITS=$(grep -nE 'assign "\$BEAD_ID" "" -q 2>/dev/null \|\| true$' "$DISPATCHER" || true)
if [ -z "$SILENT_CLEAR_HITS" ]; then
  ok "no silent (no-warn) 'bd assign \"\" || true' assignee-clear remains (ga-v5acl fixed site C's 'not even a warn' gap)"
else
  bad "found leftover silent assignee-clear with no warn:
$SILENT_CLEAR_HITS"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
