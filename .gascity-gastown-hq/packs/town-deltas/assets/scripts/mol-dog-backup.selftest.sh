#!/bin/bash
# mol-dog-backup.selftest.sh — unit tests for classify_sync_failure() and
# bound_for_size_kb(), the pure logic behind the ga-gquc1 timeout-vs-failure fix.
#
# Hermetic: sources mol-dog-backup.sh in library mode (MOL_DOG_BACKUP_LIB=1), which
# returns before PACK_DIR/runtime.sh is sourced — no live Dolt server, port
# resolution, or GC_CITY_PATH is ever required. Real dolt/mail/nudge are NEVER
# called; nothing is deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/mol-dog-backup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Runs "$@" as a command after sourcing mol-dog-backup.sh in library mode, in a
# subshell — so the sourced script's `set -euo pipefail` never leaks into this
# selftest's own shell, and each call starts from a clean function/var state.
lib_call() {
  (
    export MOL_DOG_BACKUP_LIB=1
    . "$SCRIPT" >/dev/null 2>&1
    "$@"
  )
}

echo "=== mol-dog-backup.selftest.sh ==="

if lib_call type classify_sync_failure >/dev/null 2>&1 \
  && lib_call type bound_for_size_kb >/dev/null 2>&1; then
  ok "classify_sync_failure and bound_for_size_kb defined by lib-mode source"
else
  bad "pure functions NOT defined — lib mode broken"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

# ── classify_sync_failure: timeout (run_bounded exit 124) ────────────────────────
result=$(lib_call classify_sync_failure "hq" 124 120 "")
[ "$result" = "hq(timeout after 120s)" ] \
  && ok "timeout (rc=124) → 'hq(timeout after 120s)'" \
  || bad "timeout (rc=124) → got '$result', want 'hq(timeout after 120s)'"
case "$result" in
  *"sync failed"*) bad "timeout message must NOT contain 'sync failed' — got '$result'" ;;
  *) ok "timeout message does not contain 'sync failed'" ;;
esac

# ── classify_sync_failure: real failure (ga-b5h83-shaped captured error) ─────────
REAL_ERR="error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): error opening table file: table file not found: /Users/athos/gt/.gascity-gastown-hq/.dolt-backup/hq/vljre1ianoi9rv9j7429njjiosmr1ior"
result=$(lib_call classify_sync_failure "hq" 1 120 "$REAL_ERR")
case "$result" in
  "hq(sync failed: "*) ok "real failure (rc=1) → tagged 'sync failed' with detail" ;;
  *) bad "real failure (rc=1) → got '$result', want prefix 'hq(sync failed: '" ;;
esac
case "$result" in
  *"timeout"*) bad "real-failure message must NOT contain 'timeout' — got '$result'" ;;
  *) ok "real-failure message does not contain 'timeout'" ;;
esac

# ── AC: a DB that exceeds the bound MUST produce a DIFFERENT message than a DB ───
# ── whose sync really fails (the original ga-gquc1 bug: both collapsed to the ────
# ── identical "sync failed" string once stderr was discarded) ────────────────────
echo "── falsifying check: timeout vs real failure must differ ──"
timeout_msg=$(lib_call classify_sync_failure "hq" 124 120 "")
failure_msg=$(lib_call classify_sync_failure "hq" 1 120 "$REAL_ERR")
if [ "$timeout_msg" != "$failure_msg" ]; then
  ok "timeout message ('$timeout_msg') differs from real-failure message ('$failure_msg')"
else
  bad "timeout and real-failure produced the SAME message ('$timeout_msg') — the original bug"
fi

# ── classify_sync_failure: nonzero rc with empty/whitespace-only output ──────────
result=$(lib_call classify_sync_failure "dc" 1 120 "")
[ "$result" = "dc(sync failed: exit 1)" ] \
  && ok "nonzero rc + empty output → 'dc(sync failed: exit 1)'" \
  || bad "nonzero rc + empty output → got '$result'"
result=$(lib_call classify_sync_failure "dc" 2 120 "   ")
[ "$result" = "dc(sync failed: exit 2)" ] \
  && ok "nonzero rc + whitespace-only output → 'dc(sync failed: exit 2)'" \
  || bad "nonzero rc + whitespace-only output → got '$result'"

# ── bound_for_size_kb: small vs large vs boundary vs invalid input ───────────────
result=$(lib_call bound_for_size_kb 1000)
[ "$result" = "120" ] && ok "small size (1000KB) → bound 120" || bad "small size (1000KB) → got '$result', want 120"

result=$(lib_call bound_for_size_kb 600000)
[ "$result" = "600" ] && ok "large size (600000KB, ~hq) → bound 600" || bad "large size (600000KB) → got '$result', want 600"

result=$(lib_call bound_for_size_kb 1533572)
[ "$result" = "600" ] && ok "large size (1533572KB, ~whatsapp_automation) → bound 600" || bad "whatsapp_automation-sized input → got '$result', want 600"

result=$(lib_call bound_for_size_kb 512000)
[ "$result" = "600" ] && ok "boundary size (512000KB, ==threshold) → bound 600 (inclusive)" || bad "boundary size → got '$result', want 600"

result=$(lib_call bound_for_size_kb 511999)
[ "$result" = "120" ] && ok "just-below-boundary size (511999KB) → bound 120" || bad "just-below-boundary → got '$result', want 120"

result=$(lib_call bound_for_size_kb "")
[ "$result" = "120" ] && ok "empty size input → safe default bound 120" || bad "empty size input → got '$result', want 120"

result=$(lib_call bound_for_size_kb "notanumber")
[ "$result" = "120" ] && ok "non-numeric size input → safe default bound 120" || bad "non-numeric size input → got '$result', want 120"

# ── drift-guard: live script actually wires the fix into the sync step ───────────
echo "── drift-guard: wiring present in live script ──"
if grep -qF 'dolt backup sync "${db}-backup" 2>/dev/null' "$SCRIPT"; then
  bad "the sync line still discards stderr via 2>/dev/null — the original ga-gquc1 bug"
else
  ok "the sync line no longer discards stderr with 2>/dev/null"
fi
if grep -qF 'dolt backup sync "${db}-backup" 2>&1' "$SCRIPT"; then
  ok "the sync line captures combined stdout+stderr (2>&1) for classification"
else
  bad "the sync line does not capture output — cannot classify failures"
fi
if grep -qF 'classify_sync_failure "$db" "$sync_rc" "$sync_bound" "$sync_output"' "$SCRIPT"; then
  ok "the main loop calls classify_sync_failure with the captured exit code and output"
else
  bad "classify_sync_failure is defined but never called from the main loop — dead code"
fi
if grep -qF 'sync_bound=$(bound_for_size_kb' "$SCRIPT"; then
  ok "the main loop calls bound_for_size_kb to size the per-db timeout"
else
  bad "bound_for_size_kb is defined but never called from the main loop — dead code"
fi
if grep -qE 'run_bounded[[:space:]]+120[[:space:]]+dolt backup sync' "$SCRIPT"; then
  bad "a hardcoded 'run_bounded 120 dolt backup sync' is still present — bound is no longer proportional"
else
  ok "no hardcoded 'run_bounded 120 dolt backup sync' remains"
fi

# ── drift-guard: runtime.sh sourced from its real (dolt pack) location, not ──
# ── the self-relative $PACK_DIR that broke gate attempt 1 (crashed before ────
# ── Step 1 ever ran because vendoring this script under town-deltas made ─────
# ── $PACK_DIR resolve to town-deltas, which never had its own runtime.sh) ────
if grep -qE '^\s*PACK_DIR=.*BASH_SOURCE' "$SCRIPT"; then
  bad "self-relative \$PACK_DIR computation is back — this resolves to town-deltas post-vendoring, not the dolt pack, and has no runtime.sh there (the exact gate attempt-1 bootstrap crash)"
else
  ok "no self-relative \$PACK_DIR computation for locating runtime.sh"
fi
if grep -qF '.gc/system/packs' "$SCRIPT" && grep -qE '\.\s+"\$\{GC_SYSTEM_PACKS_DIR:-\$GC_CITY_PATH' "$SCRIPT"; then
  ok "runtime.sh is sourced from the dolt pack's GC_CITY_PATH-anchored live location"
else
  bad "runtime.sh sourcing no longer anchors to GC_CITY_PATH/.gc/system/packs/dolt — verify it still resolves to a real, always-materialized file"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
