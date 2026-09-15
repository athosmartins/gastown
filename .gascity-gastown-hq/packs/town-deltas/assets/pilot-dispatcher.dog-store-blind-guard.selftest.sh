#!/usr/bin/env bash
# pilot-dispatcher.dog-store-blind-guard.selftest.sh — unit tests for
# _pilot_dog_store_blind_guard (ga-cszxcf).
#
# Bug ga-cszxcf: the RIG-NATIVE dispatch path's crew `*)` arm assigns
# $_SLING_TARGET directly via `bd -C "$STORY_BEAD_CITY" update ... --assignee
# ... --status in_progress` whenever the target does not match
# `wa-worker*|ps-worker*` — which is every gastown.dog/gastown.dog-N target,
# since the pool-self-serve arm only lists wa-worker*/ps-worker*. But
# _IS_RIG_NATIVE=1 means, by the variable's own definition a few hundred
# lines above (`[ "$STORY_BEAD_CITY" != "$GC_CITY" ] && _IS_RIG_NATIVE=1`),
# that STORY_BEAD_CITY is NOT the HQ store. gastown.dog's own startup
# probes (Step 1a/1b/1c in its formula prompt) carry no BEADS_DIR/GC_RIG and
# always resolve against the ambient default store, which for a dog's cwd
# (.gc/agents/dogs/<name>) is HQ — so a bead assigned in a non-HQ store is
# permanently invisible to the very agent it was assigned to. Measured
# 2026-09-15: 16 of 17 gt- (gastown rig) dispatches to gastown.dog since
# 09-12 got no builder; inflight-reclaim-guard released every one with "no
# live builder and no recent branch progress", 4 reached gate:needs-human.
#
# Fix: _pilot_dog_store_blind_guard(sling_target, is_rig_native) — a pure
# predicate (no bd calls, self-contained per the ga-c9qj8
# _pilot_routed_to_pool_guard convention: re-checks both inputs rather than
# trusting the call site) that returns 0 (REFUSE) only when the target is a
# gastown.dog identity AND the dispatch is rig-native (non-HQ). The
# dispatch_one() call site (crew `*)` arm, before the existing --assignee
# write) then parks visibly instead of assigning: pilot:no-auto-dispatch +
# next-action:mayor + an explanatory comment, mirroring the "vai parar
# esperando decisão do Mayor" convention (CLAUDE.md Regra de comunicação /
# next-action-coordinator-alert.sh).
#
# Falsifiable: the function does not exist before this fix, so the awk
# extraction below fails hard (FATAL, exit 2) against pre-fix HEAD — this
# selftest cannot pass without the fix landed.
#
# Follows the same conventions as its closest sibling,
# pilot-dispatcher.routed-to-crew-guard.selftest.sh: verbatim function
# extraction + `has()` source-grep checks for call-site wiring (the guard
# itself takes no `bd` stub — it is a pure string/flag predicate, so no fake
# bd is needed for Part A).
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.dog-store-blind-guard.selftest.sh
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

# ── Extract the function verbatim from the live file ───────────────────────
extract_fn() {
  local _name="$1"
  awk "/^${_name}\\(\\)/{f=1} f{print} f&&/^}\$/{exit}" "$DISPATCHER"
}
GUARD_FN="$(extract_fn '_pilot_dog_store_blind_guard')"
if [ -z "$GUARD_FN" ]; then
  echo "FATAL: _pilot_dog_store_blind_guard() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi

echo "pilot-dispatcher.dog-store-blind-guard.selftest — ga-cszxcf"
echo ""
echo "=== Part A: _pilot_dog_store_blind_guard ==="

run_guard() { # run_guard <sling_target> <is_rig_native>
  local _target="$1" _rig_native="$2"
  bash -c "$GUARD_FN"'
_pilot_dog_store_blind_guard "'"$_target"'" "'"$_rig_native"'"'
}

# Scenario A: bare "gastown.dog" target + rig-native (non-HQ store) → REFUSE.
# The exact ga-cszxcf incident shape (gt-4l134/gt-4i3ei/gt-4zk4b/... assigned
# to gastown.dog in the gastown rig's own store).
run_guard "gastown.dog" "1"; rc=$?
if [ "$rc" = "0" ]; then
  ok "gastown.dog + rig-native=1 -> REFUSE (the measured gt- dispatch shape)"
else
  bad "gastown.dog + rig-native=1 -> expected REFUSE (rc=0), got rc=$rc"
fi

# Scenario B: slotted "gastown.dog-N" target + rig-native → REFUSE. Slots are
# the common case in practice (BUILDER_TARGET picks a specific pool slot).
run_guard "gastown.dog-6" "1"; rc=$?
if [ "$rc" = "0" ]; then
  ok "gastown.dog-6 (slotted) + rig-native=1 -> REFUSE"
else
  bad "gastown.dog-6 + rig-native=1 -> expected REFUSE (rc=0), got rc=$rc"
fi

# Scenario C: gastown.dog target but HQ store (rig-native=0) → PROCEED.
# Dogs read the HQ store natively (no BEADS_DIR/GC_RIG needed) — the
# ordinary, already-working sling path to gastown.dog must stay unaffected.
run_guard "gastown.dog" "0"; rc=$?
if [ "$rc" = "1" ]; then
  ok "gastown.dog + rig-native=0 (HQ) -> PROCEED (dogs read HQ fine, unaffected)"
else
  bad "gastown.dog + rig-native=0 -> expected PROCEED (rc=1), got rc=$rc"
fi

# Scenario D: gastown.dog target, rig-native unset/empty (defensive default)
# → PROCEED. Only an explicit "1" may trigger refusal — never fail toward
# blocking a legitimate HQ dispatch on a missing/garbled flag.
run_guard "gastown.dog-2" ""; rc=$?
if [ "$rc" = "1" ]; then
  ok "gastown.dog-2 + rig-native='' -> PROCEED (defensive default, only explicit '1' refuses)"
else
  bad "gastown.dog-2 + rig-native='' -> expected PROCEED (rc=1), got rc=$rc"
fi

# Scenario E: named crew target (not a dog), rig-native=1 → PROCEED.
# Ordinary rig-native crew dispatch (mila-wa, oracle-wa, ...) must keep
# working unchanged — this guard is scoped to gastown.dog identities only.
run_guard "mila-wa" "1"; rc=$?
if [ "$rc" = "1" ]; then
  ok "mila-wa (named crew) + rig-native=1 -> PROCEED (ordinary crew dispatch unaffected)"
else
  bad "mila-wa + rig-native=1 -> expected PROCEED (rc=1), got rc=$rc"
fi

# Scenario F: wa-worker slot, rig-native=1 → PROCEED. wa-worker*/ps-worker*
# never reach the call site this guard lives in (they match the earlier
# case arm), but the guard's OWN pattern must not over-match them either.
run_guard "wa-worker-2" "1"; rc=$?
if [ "$rc" = "1" ]; then
  ok "wa-worker-2 + rig-native=1 -> PROCEED (guard scoped to gastown.dog*, not other pools)"
else
  bad "wa-worker-2 + rig-native=1 -> expected PROCEED (rc=1), got rc=$rc"
fi

# ── Drift-guards — call site wiring in dispatch_one()'s crew `*)` arm ───────
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has 'PILOT_DOG_STORE_GUARD:-1'                                                "call site respects PILOT_DOG_STORE_GUARD kill switch (default on)"
has '_pilot_dog_store_blind_guard "\$_SLING_TARGET" "\$_IS_RIG_NATIVE"'       "call site invokes the guard with _SLING_TARGET/_IS_RIG_NATIVE"
has 'DISPATCH_RESULT="rig_native_dog_store_blind"'                           "refusal is attributed to a distinct DISPATCH_RESULT (rig_native_dog_store_blind)"
has '"\$STORY_BEAD_CITY" label add "\$STORY_ID" "pilot:no-auto-dispatch"'    "refusal parks the bead with pilot:no-auto-dispatch (stops Pilot re-selecting it)"
has '"\$STORY_BEAD_CITY" label add "\$STORY_ID" "next-action:mayor"'         "refusal marks next-action:mayor (surfaces on the Mayor's view per bead_state.py PARK_PREFIXES)"
has '"\$STORY_BEAD_CITY" comment "\$STORY_ID"'                               "refusal leaves an explanatory comment on the bead (not just labels)"

# Ordering: the guard call must appear BEFORE the crew --assignee write in
# the SAME arm, else it refuses too late (bead already assigned+stranded).
if awk '/_pilot_dog_store_blind_guard "\$_SLING_TARGET"/{g=NR} /--assignee "\$_SLING_TARGET" --status in_progress/{a=NR} END{exit !(g && a && g<a)}' "$DISPATCHER"; then
  ok "guard call precedes the crew --assignee write (refuses BEFORE assigning, not after)"
else
  bad "REGRESSION: guard call does not precede the crew --assignee write — ordering may have drifted"
fi

echo ""
echo "pilot-dispatcher.dog-store-blind-guard.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
