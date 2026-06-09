#!/usr/bin/env bash
# gate-source-bead-detach.selftest.sh — Regression guard for ga-e7zk7.
#
# A source bead with a LIVE gate marker kept getting re-dispatched to the dog
# pool (ga-noxbv re-pooled 15x mid-gate). The builder leaves the source bead
# in_progress + assignee=<pool alias> for the whole gate duration, and the
# dog-pool startup probes are label-blind + engine-baked (cannot be changed
# without an engine window):
#   - Step 1a re-matches  in_progress + assignee=<recycled pool alias>   (Vector 1a)
#   - Step 1c re-matches  unassigned + gc.routed_to=<template>           (Vector 1c)
#
# The fix detaches the source bead while the gate owns its marker
# (gate-status:claimed): quality-gate-guard.sh clears the source bead's assignee
# (kills 1a) and strips gc.routed_to (kills 1c). gate-status:claimed is an active
# state the inflight-reclaim-guard already excludes, so the detach cannot trigger
# a false reclaim.
#
# CRITICAL ORDERING (the gate FAIL that produced this revision): the detach must
# run AFTER Step 5 author derivation, not before it. Step 5 derives the
# self-review-exclusion author from the source bead, first-choice signal = the
# bead's assignee (assignee → created_by → owner). Clearing the assignee before
# Step 5 forces a fall-through to created_by (the FILER), which lets the real
# builder review their own branch — a self-review bypass. So the detach lives
# right after `log "Authoritative author: $AUTHOR"`, still inside the
# gate-status:claimed window (Step 6 has not flipped the marker yet).
#
# This test statically guards quality-gate-guard.sh against regressing that
# behaviour: the detach must exist, clear BOTH vectors, be best-effort (never
# abort the set -euo pipefail sweep), and be positioned AFTER Step 5 author
# derivation (after the authoritative author is resolved) and before Step 6.
#
# Pure bash + grep/awk. Never runs gc/bd, never touches the live city or beads —
# safe to run on a live host (honors the "no live config edit" doctrine).
#
# Exit 0 iff every assertion passes.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "== gate-source-bead-detach.selftest =="

if [ ! -f "$GUARD" ]; then
  echo "  ✗ guard not found at $GUARD"
  exit 1
fi

# 1. Guard parses (catches a malformed insertion).
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses (bash -n)"
else
  bad "quality-gate-guard.sh has a syntax error"
fi

# 2. Vector 1a kill: the detach clears the source bead's assignee.
if grep -Eq 'bd -C "\$GC_CITY" assign "\$BEAD_ID" ""' "$GUARD"; then
  ok "clears source-bead assignee (Vector 1a) via bd assign \"\$BEAD_ID\" \"\""
else
  bad "missing assignee clear on \$BEAD_ID (Vector 1a not killed)"
fi

# 3. Vector 1c kill: the detach strips gc.routed_to metadata.
if grep -Eq -- '--unset-metadata gc\.routed_to' "$GUARD"; then
  ok "strips gc.routed_to (Vector 1c) via --unset-metadata"
else
  bad "missing gc.routed_to strip (Vector 1c not killed)"
fi

# 4. Best-effort: the metadata strip is guarded with '|| true' so a missing key
#    never aborts the set -euo pipefail sweep.
if grep -Eq -- '--unset-metadata gc\.routed_to[^|]*\|\| true' "$GUARD"; then
  ok "gc.routed_to strip is guarded with || true (won't abort the sweep)"
else
  bad "gc.routed_to strip is not guarded with || true"
fi

# 5. Guarded by a non-empty bead-id check (never detach with an empty id).
#    The detach assign line must live inside an 'if [ -n "$BEAD_ID" ]' block.
detach_line=$(grep -nE 'bd -C "\$GC_CITY" assign "\$BEAD_ID" ""' "$GUARD" | head -1 | cut -d: -f1)
guard_line=$(awk '/if \[ -n "\$BEAD_ID" \]; then/ { print NR }' "$GUARD" | awk -v d="${detach_line:-0}" '$1 < d' | tail -1)
if [ -n "${detach_line:-}" ] && [ -n "${guard_line:-}" ]; then
  ok "detach is guarded by 'if [ -n \"\$BEAD_ID\" ]'"
else
  bad "detach is not guarded by a non-empty \$BEAD_ID check"
fi

# 6. Ordering: the detach must fire AFTER Step 5 resolves the authoritative author
#    (the `log "Authoritative author: $AUTHOR"` line) and BEFORE Step 6 — i.e.
#    still inside the gate-status:claimed window, but only once the source bead's
#    assignee has been READ for self-review exclusion. Detaching before Step 5
#    clears the assignee that Step 5 reads first (assignee → created_by → owner),
#    forcing a fall-through to created_by (the filer) and letting the real builder
#    review their own branch — the self-review bypass that FAILED the gate. This
#    assertion locks in the corrected order (after author derivation).
author_line=$(grep -nE 'log "Authoritative author: \$AUTHOR"' "$GUARD" | head -1 | cut -d: -f1)
step6_line=$(grep -nE '^# .*Step 6: Create gate-run' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "${author_line:-}" ] && [ -n "${detach_line:-}" ] && [ -n "${step6_line:-}" ] \
   && [ "$detach_line" -gt "$author_line" ] && [ "$detach_line" -lt "$step6_line" ]; then
  ok "detach is positioned after Step 5 author derivation and before Step 6"
else
  bad "detach is mis-positioned (author=$author_line detach=$detach_line step6=$step6_line)"
fi

# 7. Traceability: the detach references its bead id so future readers can trace
#    the rationale.
if grep -q 'ga-e7zk7' "$GUARD"; then
  ok "detach block references ga-e7zk7 for traceability"
else
  bad "detach block is missing the ga-e7zk7 trace reference"
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
