#!/usr/bin/env bash
# pilot-dispatcher.sling-reuse-suppress.selftest.sh — unit tests for
# _pilot_suppress_reused_sling (ga-i58em).
#
# Bug ga-i58em: when Pilot's dispatch_one() REUSE path (_DISPATCH_REUSE=1)
# delivers work to an already-live pool session via `gc session submit
# --intent follow_up`, it ALSO creates a pool-routed sling wrapper bead
# (gc.routed_to=<pool>, unassigned, pilot.sling_for=<story>) purely as an
# audit-trail record. Because delivery went out-of-band (never through the
# sling bead's own claim mechanism), that sling bead is left looking exactly
# like legitimate unclaimed pool demand to a SECOND idle worker's own
# routed-pool startup probe — which claims it and, per the same dispatch
# prompt template, re-dispatches the SAME target story a second time. Live
# incident: ga-0ehtp double-dispatched to gastown.dog-1 (direct submit) and
# gastown.dog-3 (claimed sling ga-x4rca) within the same Pilot transaction.
#
# The fix: _pilot_suppress_reused_sling, called from dispatch_one()'s REUSE
# branch right after the sling bead's pilot.sling_for stamp, defers the
# SLING bead (never the story bead) a bounded window into the future via the
# existing _pilot_defer_extend helper — reusing the ga-z297h lesson that a
# bare pilot:held/pilot:held-until label alone does not reliably stop a
# bd-ready-based pool probe; only the bd-native defer_until field does.
#
# This harness extracts _pilot_suppress_reused_sling (and _pilot_defer_extend,
# which it calls through to) verbatim from the live dispatcher — the same
# awk-extraction + fake bd/gc/log/warn shell-function pattern
# pilot-hold-escalate.selftest.sh already uses for the neighboring
# suppression helpers — and evals them standalone, in-process, no subprocess
# or live Dolt needed.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Extract both functions verbatim from the live file ────────────────────────
SUPPRESS_FN="$(awk '/^_pilot_suppress_reused_sling\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$SUPPRESS_FN" ]; then
  echo "FATAL: _pilot_suppress_reused_sling() not found in $DISPATCHER (extraction pattern drifted?)" >&2
  exit 2
fi
DEFER_FN="$(awk '/^_pilot_defer_extend\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$DEFER_FN" ]; then
  echo "FATAL: _pilot_defer_extend() not found in $DISPATCHER (extraction pattern drifted?)" >&2
  exit 2
fi

# ── Workspace + call-log capture ───────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-sling-reuse-suppress-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CALLS="$WORK/calls.log"

# run_suppress <city> <sling_id> [<defer_secs_or_empty>] [<dry(0|1)>]
# Fake bd() serves _pilot_defer_extend's own internal `show <id> --json`
# read (no pre-existing defer_until — the common case for a freshly-created
# sling bead) and records every call verbatim, same convention as
# pilot-hold-escalate.selftest.sh's run_defer().
run_suppress() {
  : > "$CALLS"
  local _rs_city="$1" _rs_id="$2" _rs_secs="${3:-}" _rs_dry="${4:-0}"
  (
    DRY_RUN="$_rs_dry"
    if [ -n "$_rs_secs" ]; then
      PILOT_REUSE_SLING_DEFER_SECONDS="$_rs_secs"
    fi
    bd() {
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      case "$*" in
        *"show $_rs_id --json"*) printf '[{"defer_until":null}]' ;;
      esac
    }
    gc()   { printf 'gc\t%s\n'   "$*" >> "$CALLS"; }
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$CALLS"; }
    eval "$DEFER_FN"
    eval "$SUPPRESS_FN"
    _pilot_suppress_reused_sling "$_rs_city" "$_rs_id"
  )
}

has_call() { grep -qF -- "$1" "$CALLS" 2>/dev/null; }   # exact-substring, any recorded call

# extract_deferred_iso <city> <id> — pulls the ISO8601 argument off the
# recorded `bd -C <city> update <id> --defer <iso> -q` call line, if any.
extract_deferred_iso() {
  grep -F -- "bd	-C $1 update $2 --defer " "$CALLS" 2>/dev/null \
    | sed -E 's/.*--defer ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) -q.*/\1/' \
    | head -1
}

# iso_to_epoch <iso8601> — macOS/BSD date parse-back (verified against
# `date -u -r <epoch>`'s own output format at authoring time).
iso_to_epoch() {
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

echo "pilot-dispatcher.sling-reuse-suppress.selftest — REUSE sling suppression (ga-i58em)"

# ── Scenario A: default defer window (300s) — real (non-dry) call ────────────
echo "Scenario A: valid sling bead, default PILOT_REUSE_SLING_DEFER_SECONDS — defers ~300s into the future"
_before=$(date +%s)
run_suppress "hq" "sling-1" "" 0
_after=$(date +%s)
_iso=$(extract_deferred_iso "hq" "sling-1")
if [ -z "$_iso" ]; then
  bad "no bd update --defer call recorded for sling-1 (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  _epoch=$(iso_to_epoch "$_iso")
  _lo=$((_before + 300))
  _hi=$((_after + 300))
  if [ -n "$_epoch" ] && [ "$_epoch" -ge "$_lo" ] && [ "$_epoch" -le "$_hi" ]; then
    ok "deferred to $_iso — within the expected +300s window ([$_lo,$_hi], got $_epoch)"
  else
    bad "deferred timestamp $_iso (epoch=$_epoch) outside expected +300s window [$_lo,$_hi]"
  fi
fi
if has_call "bd	-C hq show sling-1 --json"; then
  ok "reads the sling bead's own city/id through to _pilot_defer_extend (hq, sling-1)"
else
  bad "did not read through to the expected city/id"
fi

# ── Scenario B: empty sling id — refuses outright, no bd/gc call at all ──────
echo "Scenario B: empty sling_id — refuses before any bd/gc call (would defer nothing about nothing)"
run_suppress "hq" "" "" 0
if grep -qE '^(bd|gc)	' "$CALLS"; then
  bad "REGRESSION: made a bd/gc call with an empty sling_id (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  ok "empty sling_id short-circuits before any bd/gc call"
fi

# ── Scenario C: configurable window via PILOT_REUSE_SLING_DEFER_SECONDS ──────
echo "Scenario C: PILOT_REUSE_SLING_DEFER_SECONDS=60 override changes the defer window accordingly"
_before=$(date +%s)
run_suppress "propdb" "sling-2" "60" 0
_after=$(date +%s)
_iso=$(extract_deferred_iso "propdb" "sling-2")
if [ -z "$_iso" ]; then
  bad "no bd update --defer call recorded for sling-2 (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  _epoch=$(iso_to_epoch "$_iso")
  _lo=$((_before + 60))
  _hi=$((_after + 60))
  if [ -n "$_epoch" ] && [ "$_epoch" -ge "$_lo" ] && [ "$_epoch" -le "$_hi" ]; then
    ok "custom 60s override respected — deferred to $_iso ([$_lo,$_hi], got $_epoch)"
  else
    bad "custom 60s override not respected — $_iso (epoch=$_epoch) outside [$_lo,$_hi] (still using the 300s default?)"
  fi
fi

# ── Scenario D: DRY_RUN propagates through to _pilot_defer_extend ────────────
echo "Scenario D: DRY_RUN=1 — logs WOULD defer via _pilot_defer_extend, makes no real bd update call"
run_suppress "hq" "sling-3" "" 1
if has_call "WOULD defer sling-3"; then
  ok "DRY_RUN propagates through to _pilot_defer_extend's own WOULD-log"
else
  bad "DRY_RUN did not propagate — no WOULD-defer log seen (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if has_call "update sling-3 --defer"; then
  bad "REGRESSION: DRY_RUN performed a real bd update"
else
  ok "DRY_RUN performs no real mutation"
fi

# ── Scenario E: drift-guards — helper defined + wired into the REUSE branch ──
echo "Scenario E: drift-guard — _pilot_suppress_reused_sling is defined and wired into dispatch_one()'s REUSE branch"
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has '_pilot_suppress_reused_sling\(\) \{'                              "helper _pilot_suppress_reused_sling is defined"
has '_pilot_suppress_reused_sling "\$GC_CITY" "\$SLING_BEAD_ID"'       "dispatch_one() call site invokes the helper with (GC_CITY, SLING_BEAD_ID)"
# The call must be scoped to the REUSE branch only — the non-reuse (fresh
# spawn) path still needs gc.routed_to+unassigned as the new session's REAL
# discovery hook, so an unconditional call here would be a regression.
if grep -B2 '_pilot_suppress_reused_sling "\$GC_CITY" "\$SLING_BEAD_ID"' "$DISPATCHER" | grep -qE 'if \[ "\$_DISPATCH_REUSE" = "1" \]; then'; then
  ok "call site is scoped to _DISPATCH_REUSE=1 only (non-reuse spawn path untouched)"
else
  bad "REGRESSION: call site is not visibly guarded by _DISPATCH_REUSE=1 — may now suppress fresh-spawn slings too"
fi
# The call must come AFTER pilot.sling_for is stamped (the bead must exist
# and be tagged before we touch it) — same "confirmed live in Dolt first"
# ordering the ga-nimyz comment right above it already establishes.
if grep -A6 'set-metadata "pilot.sling_for=\$STORY_ID"' "$DISPATCHER" | grep -q '_pilot_suppress_reused_sling'; then
  ok "call site comes after the pilot.sling_for stamp (bead confirmed to exist first)"
else
  bad "call site does not appear shortly after the pilot.sling_for stamp — ordering may have drifted"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.sling-reuse-suppress.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
