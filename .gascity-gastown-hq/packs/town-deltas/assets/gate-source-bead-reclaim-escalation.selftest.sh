#!/usr/bin/env bash
# gate-source-bead-reclaim-escalation.selftest.sh (ga-v5acl, extended ga-2emo8)
#
# ORIGIN (ga-v5acl): ga-sencl's investigation (ERRATA-scoped) found 4
# call-sites in quality-gate-dispatcher.sh that clear a source bead's
# builder assignee and/or close it once a gate PASS (or an already-merged/
# superseded short-circuit) has driven the bead to its terminal state — and
# each of the 4 handled a *refused* clear/close differently:
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
# FIX (ga-v5acl): two shared functions (gate_release_stale_assignee /
# gate_close_source_terminal), both escalating via
#   bd reclaim --id <id> --older-than 0s
# — which (per `bd reclaim --help`) reverts ONLY a lease that has ALREADY
# expired, never a live one — instead of blind --force. All 4 call sites
# route through these two functions.
#
# ORIGIN (ga-2emo8): ga-v5acl's own reclaim-then-retry escalation stopped
# being sufficient once ga-z93p0 wired the REAL `bd heartbeat` into
# mol-do-work.toml (called immediately before `git push`). `bd reclaim
# --older-than 0s` reclaims ONLY an already-EXPIRED lease — and post-ga-z93p0
# a claim is routinely still FRESH the moment the dispatcher tries to clear/
# close it, seconds after ITS OWN branch merged. "Lease fresh" and "work
# done" stopped being the same question the instant heartbeat became real;
# reclaim only ever answers the first. Live-reproduced: ga-7mbry's source
# bead survived a confirmed-merged gate PASS with both WARNs firing verbatim
# ("Could not clear builder assignee... even after lease-aware reclaim",
# "Could not close source bead... even after lease-aware reclaim").
#
# FIX (ga-2emo8): both functions now take a REQUIRED <merge_verified> arg —
# the caller's attestation that it independently confirmed via git
# (merge-base/patch-id) that the branch is merged BEFORE ever calling. Only
# when merge_verified="1" AND the reclaim-then-retry still fails does the
# function escalate ONE more step, to a bead-scoped `--force` — never blind
# (gated on the caller's independent proof), never ad hoc (lives inside
# these two shared, tested primitives only, never at a raw call site). A
# missing/blank/non-"1" merge_verified refuses outright and touches bd not
# at all, so a future call site that forgets the precondition fails loudly
# instead of silently reverting to the weaker pre-ga-2emo8 behavior.
#
# THIS FILE proves both functions across three axes: lease-stale escalates
# via reclaim alone (--force never needed); lease-live + merge-verified
# escalates all the way to a scoped --force and succeeds; lease-live +
# NOT-merge-verified refuses outright with ZERO bd calls of any kind. It
# also runs structural drift-guards over the live dispatcher source proving
# --force exists only inside the two shared functions (never at a raw call
# site) and that all real call sites pass merge_verified=1 literally.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-source-bead-reclaim-escalation.selftest (ga-v5acl, extended ga-2emo8) =="

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

# ── Part 1: gate_release_stale_assignee — stale / live+verified / unverified ─
echo "── 1. gate_release_stale_assignee: stale reclaims; live+verified forces; unverified refuses untouched ──"

# scenario "stale":          1st assign refused (looks live), reclaim runs
#   (bd's own TTL check would find the lease actually expired), 2nd assign
#   succeeds. --force must never be needed.
# scenario "live", verified: 1st assign refused, reclaim runs (best-effort —
#   bd's own TTL check finds the lease genuinely NOT expired and no-ops),
#   2nd assign refused again — but merge_verified=1, so the function escalates
#   to a THIRD, --force'd assign, which succeeds (matches real bd: --force
#   overrides a live-claim refusal). This is the ga-2emo8 fix's core case.
# scenario "live", unverified: same live lease, but merge_verified is NOT
#   "1" (simulates a call site that forgot the precondition). The function
#   MUST refuse before calling bd even once — no assign, no reclaim, nothing.
run_release() {
  local scenario="$1" merge_verified="$2" log="$3"
  : > "$log"
  bash -c '
    set -euo pipefail
    SCENARIO="$1"; MERGE_VERIFIED="$2"; BD_LOG="$3"
    ASSIGN_CALLS=0
    bd() {
      echo "$*" >> "$BD_LOG"
      case " $* " in
        *" assign "*)
          if printf "%s" "$*" | grep -q -- "--force"; then
            return 0   # real bd: --force always overrides a live-claim refusal
          fi
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
    warn() { echo "WARN: $*" >&2; }
    '"$FN_RELEASE"'
    RC=0
    gate_release_stale_assignee "src-bead" "$MERGE_VERIFIED" "/fake/city" || RC=$?
    exit "$RC"
  ' _ "$scenario" "$merge_verified" "$log"
  return $?
}

LOG_STALE="$(mktemp)"
run_release stale 1 "$LOG_STALE"; RC_STALE=$?
[ "$RC_STALE" -eq 0 ] \
  && ok "(stale) function returns 0 — assignee successfully released after reclaim" \
  || bad "(stale) function returned $RC_STALE, expected 0 — log: $(cat "$LOG_STALE")"
grep -q "reclaim --id src-bead --older-than 0s" "$LOG_STALE" \
  && ok "(stale) bd reclaim --id src-bead --older-than 0s was called before the retry" \
  || bad "(stale) reclaim was not called with the expected args — log: $(cat "$LOG_STALE")"
grep -q -- "--force" "$LOG_STALE" \
  && bad "(stale) --force appeared in a bd call — reclaim alone was enough, force should never trigger. log: $(cat "$LOG_STALE")" \
  || ok "(stale) --force never needed"
rm -f "$LOG_STALE"

LOG_LIVE_V="$(mktemp)"
run_release live 1 "$LOG_LIVE_V"; RC_LIVE_V=$?
[ "$RC_LIVE_V" -eq 0 ] \
  && ok "(live, merge_verified=1) function returns 0 — escalates to scoped --force and succeeds (ga-2emo8)" \
  || bad "(live, merge_verified=1) function returned $RC_LIVE_V, expected 0 — log: $(cat "$LOG_LIVE_V")"
grep -q "reclaim --id src-bead --older-than 0s" "$LOG_LIVE_V" \
  && ok "(live, verified) bd reclaim was attempted first (still the preferred path when it works)" \
  || bad "(live, verified) expected a reclaim attempt before force — log: $(cat "$LOG_LIVE_V")"
grep -q -- "--force" "$LOG_LIVE_V" \
  && ok "(live, verified) --force was used as the last-resort escalation (ga-2emo8)" \
  || bad "(live, verified) --force never appeared — the ga-2emo8 escalation is missing. log: $(cat "$LOG_LIVE_V")"
rm -f "$LOG_LIVE_V"

LOG_UNVERIFIED="$(mktemp)"
run_release live "" "$LOG_UNVERIFIED"; RC_UNVERIFIED=$?
[ "$RC_UNVERIFIED" -ne 0 ] \
  && ok "(live, unverified) function returns non-zero — refuses without merge_verified=1" \
  || bad "(live, unverified) function returned 0 without merge_verified — a claim would have been cleared with no merge proof at all"
[ ! -s "$LOG_UNVERIFIED" ] \
  && ok "(live, unverified) bd was NEVER called — not assign, not reclaim, nothing (hard refuse, ga-2emo8)" \
  || bad "(live, unverified) bd was called despite missing merge_verified — log: $(cat "$LOG_UNVERIFIED")"
rm -f "$LOG_UNVERIFIED"

# ── Part 2: gate_close_source_terminal — stale / live+verified / unverified ─
echo "── 2. gate_close_source_terminal: stale reclaims; live+verified forces; unverified refuses untouched ──"

run_close() {
  local scenario="$1" merge_verified="$2" log="$3"
  : > "$log"
  bash -c '
    set -euo pipefail
    SCENARIO="$1"; MERGE_VERIFIED="$2"; BD_LOG="$3"
    # gate_close_source_terminal calls its FIRST close via a command
    # substitution ($(...), to capture the error text) — that forks a
    # subshell, so a plain shell-variable increment inside this mock would be
    # invisible to the later (direct, no-subshell) retries. Count via a
    # FILE instead, same technique gate-spawn-transient-retry.selftest.sh
    # uses for the identical reason.
    CLOSE_CALL_LOG="$(mktemp)"
    bd() {
      echo "$*" >> "$BD_LOG"
      case " $* " in
        *" close "*)
          if printf "%s" "$*" | grep -q -- "--force"; then
            return 0   # real bd: --force always overrides a live-claim refusal
          fi
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
    gate_close_source_terminal "src-bead" "closed by test (ga-v5acl/ga-2emo8)" "$MERGE_VERIFIED" "/fake/city" || RC=$?
    exit "$RC"
  ' _ "$scenario" "$merge_verified" "$log"
  return $?
}

LOG_CSTALE="$(mktemp)"
run_close stale 1 "$LOG_CSTALE"; RCC_STALE=$?
[ "$RCC_STALE" -eq 0 ] \
  && ok "(stale) close succeeds after reclaim" \
  || bad "(stale) close returned $RCC_STALE, expected 0 — log: $(cat "$LOG_CSTALE")"
grep -q "reclaim --id src-bead --older-than 0s" "$LOG_CSTALE" \
  && ok "(stale) reclaim called before the close retry" \
  || bad "(stale) reclaim not called — log: $(cat "$LOG_CSTALE")"
grep -q -- "--force" "$LOG_CSTALE" \
  && bad "(stale) --force used in close path — reclaim alone was enough. log: $(cat "$LOG_CSTALE")" \
  || ok "(stale) --force never needed in close path"
rm -f "$LOG_CSTALE"

LOG_CLIVE_V="$(mktemp)"
run_close live 1 "$LOG_CLIVE_V"; RCC_LIVE_V=$?
[ "$RCC_LIVE_V" -eq 0 ] \
  && ok "(live, merge_verified=1) close escalates to scoped --force and succeeds (ga-2emo8)" \
  || bad "(live, merge_verified=1) close returned $RCC_LIVE_V, expected 0 — log: $(cat "$LOG_CLIVE_V")"
grep -q -- "--force" "$LOG_CLIVE_V" \
  && ok "(live, verified) --force was used as the last-resort escalation (ga-2emo8)" \
  || bad "(live, verified) --force never appeared — the ga-2emo8 escalation is missing. log: $(cat "$LOG_CLIVE_V")"
rm -f "$LOG_CLIVE_V"

LOG_CUNVERIFIED="$(mktemp)"
run_close live "" "$LOG_CUNVERIFIED"; RCC_UNVERIFIED=$?
[ "$RCC_UNVERIFIED" -ne 0 ] \
  && ok "(live, unverified) close returns non-zero — refuses without merge_verified=1" \
  || bad "(live, unverified) close returned 0 without merge_verified — a bead would have been closed with no merge proof at all"
[ ! -s "$LOG_CUNVERIFIED" ] \
  && ok "(live, unverified) bd was NEVER called — not close, not reclaim, nothing (hard refuse, ga-2emo8)" \
  || bad "(live, unverified) bd was called despite missing merge_verified — log: $(cat "$LOG_CUNVERIFIED")"
rm -f "$LOG_CUNVERIFIED"

# ── Part 3: structural — call sites wired in; --force scoped to the two ─────
# shared functions only, never ad hoc at a raw call site.
echo "── 3. structural: --force lives ONLY inside the two shared functions; every real call site passes merge_verified=1 ──"

# ga-2emo8: --force is no longer categorically banned from this file — it is
# now the controlled last-resort escalation INSIDE the two shared functions,
# gated behind merge_verified=1 (proved in isolation above). What must still
# never happen is a call site reaching for --force directly, bypassing the
# shared, tested, contract-gated primitive — that was the original ga-v5acl
# danger (the old site B) and this guard keeps it gone.
OUTSIDE_SHARED_FNS=$(sed \
  -e '/# SELFTEST-EXTRACT gate-release-stale-assignee-fn: BEGIN/,/# SELFTEST-EXTRACT gate-release-stale-assignee-fn: END/d' \
  -e '/# SELFTEST-EXTRACT gate-close-source-terminal-fn: BEGIN/,/# SELFTEST-EXTRACT gate-close-source-terminal-fn: END/d' \
  "$DISPATCHER")
FORCE_HITS=$(printf '%s\n' "$OUTSIDE_SHARED_FNS" | grep -nE 'bd -C "\$[A-Za-z_]+" (assign|close) .*--force' || true)
if [ -z "$FORCE_HITS" ]; then
  ok "no ad hoc 'bd assign/close ... --force' outside the two shared functions"
else
  bad "found --force on bd assign/close OUTSIDE the shared functions — a call site is bypassing the contract-gated primitive:
$FORCE_HITS"
fi

printf '%s' "$FN_RELEASE" | grep -q -- '--force' \
  && ok "gate_release_stale_assignee contains the merge-verified --force escalation (ga-2emo8)" \
  || bad "gate_release_stale_assignee is missing the --force escalation — ga-2emo8 fix not present"
printf '%s' "$FN_CLOSE_TERM" | grep -q -- '--force' \
  && ok "gate_close_source_terminal contains the merge-verified --force escalation (ga-2emo8)" \
  || bad "gate_close_source_terminal is missing the --force escalation — ga-2emo8 fix not present"

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

RELEASE_VERIFIED_SITES=$(grep -cE 'gate_release_stale_assignee "\$BEAD_ID" 1([[:space:]]|$)' "$DISPATCHER" || true)
if [ "${RELEASE_VERIFIED_SITES:-0}" -ge 3 ]; then
  ok "gate_release_stale_assignee is called with merge_verified=1 literally at >=3 sites — count=$RELEASE_VERIFIED_SITES (ga-2emo8)"
else
  bad "expected >=3 gate_release_stale_assignee call sites passing merge_verified=1 literally — count=${RELEASE_VERIFIED_SITES:-0} (ga-2emo8)"
fi

CLOSE_VERIFIED_SITES=$(grep -cE 'gate_close_source_terminal "\$BEAD_ID" "[^"]*" 1([[:space:];]|$)' "$DISPATCHER" || true)
if [ "${CLOSE_VERIFIED_SITES:-0}" -ge 3 ]; then
  ok "gate_close_source_terminal is called with merge_verified=1 literally at >=3 sites — count=$CLOSE_VERIFIED_SITES (ga-2emo8)"
else
  bad "expected >=3 gate_close_source_terminal call sites passing merge_verified=1 literally — count=${CLOSE_VERIFIED_SITES:-0} (ga-2emo8)"
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
