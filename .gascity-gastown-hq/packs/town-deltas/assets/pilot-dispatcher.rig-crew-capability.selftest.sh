#!/usr/bin/env bash
# pilot-dispatcher.rig-crew-capability.selftest.sh — Regression guard for
# rig_has_persistent_crew_capability() (ga-r7h3lf).
#
# Bug ga-r7h3lf: the ga-jazy9 lane:big-nodog guard's escalation message always
# said "assign a live persistent crew to <id>, or route it off lane:big" —
# advice that is IMPOSSIBLE for a rig with no persistent-crew build path at
# all (gascity/HQ-engine work: only the ephemeral dog pool, TTL ~25min, ever
# builds it). Measured: ga-r150x9 (a genuinely lane:big HQ bead) looped 4
# holds on this exact impossible-remedy text before anyone noticed the
# "remedy" doesn't exist for this rig.
#
# rig_domain_default_builder("")  is ambiguous on its own: it means EITHER
# "pool-based, no single named owner" (whatsapp_automation returns "") OR "no
# persistent crew of any kind" (gascity/gastown/lexbh/marketing/unknown also
# return ""). rig_has_persistent_crew_capability() resolves that ambiguity —
# this is the specific, narrow fact the fix needs.
#
# This harness extracts BOTH real function bodies verbatim (sed -n range,
# same convention as pilot-dispatcher.beads-repo-regex.selftest.sh) and calls
# rig_has_persistent_crew_capability directly — no bd/gc/Dolt/network, pure
# bash. Exit 0 iff every assertion holds.

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

# rig_has_persistent_crew_capability calls rig_domain_default_builder — both
# function bodies must be loaded for the real code path to run (not a
# reimplementation of the case logic, per to-audit-a-consumer-execute-it).
FN_DEFAULT="$(sed -n '/^rig_domain_default_builder() {/,/^}/p' "$DISPATCHER" 2>/dev/null || true)"
FN_CAPABILITY="$(sed -n '/^rig_has_persistent_crew_capability() {/,/^}/p' "$DISPATCHER" 2>/dev/null || true)"
if [ -z "$FN_DEFAULT" ]; then
  echo "FATAL: rig_domain_default_builder() not found in $DISPATCHER (renamed/removed?)" >&2
  exit 2
fi
if [ -z "$FN_CAPABILITY" ]; then
  echo "FATAL: rig_has_persistent_crew_capability() not found in $DISPATCHER (renamed/removed/not yet implemented — this is the RED state pre-fix)" >&2
  exit 2
fi
eval "$FN_DEFAULT"
eval "$FN_CAPABILITY"

echo "── 1. rigs with a real persistent-crew build path → capable ──"
for rig in property_scrapers ps whatsapp_automation wa; do
  if rig_has_persistent_crew_capability "$rig"; then
    ok "rig '$rig' correctly reports crew capability"
  else
    bad "rig '$rig' incorrectly reports NO crew capability (has one: named crew or pool)"
  fi
done

echo "── 2. rigs with NO persistent-crew build path at all → not capable (the ga-r7h3lf fact) ──"
for rig in gascity gastown lexbh marketing; do
  if rig_has_persistent_crew_capability "$rig"; then
    bad "rig '$rig' incorrectly reports crew capability — no persistent crew of any kind builds this rig"
  else
    ok "rig '$rig' correctly reports NO crew capability"
  fi
done

echo "── 3. unknown/future rig defaults to not-capable (fail-safe, not fail-open into false advice) ──"
if rig_has_persistent_crew_capability "some_new_rig_nobody_mapped_yet"; then
  bad "unrecognized rig incorrectly reports crew capability"
else
  ok "unrecognized rig correctly reports NO crew capability"
fi

echo "── 4. empty rig argument does not crash and resolves to not-capable ──"
if rig_has_persistent_crew_capability ""; then
  bad "empty rig argument incorrectly reports crew capability"
else
  ok "empty rig argument correctly reports NO crew capability (and did not error)"
fi

echo "── 5. property_scrapers' capability is backed by an actual named crew (not just non-empty) ──"
RESULT=$(rig_domain_default_builder "property_scrapers")
if [ "$RESULT" = "batista-ps" ]; then
  ok "property_scrapers' capability traces to a real named crew (batista-ps)"
else
  bad "property_scrapers' rig_domain_default_builder changed (got '$RESULT', want 'batista-ps') — capability check may now be testing stale assumptions"
fi

echo "── 6. whatsapp_automation's capability is the POOL exception, not a named-crew mapping ──"
RESULT=$(rig_domain_default_builder "whatsapp_automation")
if [ "$RESULT" = "" ]; then
  ok "whatsapp_automation correctly has NO single named-crew mapping (pool-based, per its own comment) yet still reports capable via the pool branch"
else
  bad "whatsapp_automation unexpectedly has a named-crew mapping now ('$RESULT') — the pool-exception branch in rig_has_persistent_crew_capability may be redundant/stale"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
