#!/bin/bash
# mol-dog-doctor.selftest.sh — checks for the ga-3wdlv/ga-v6y3p backup-freshness
# threshold fix and the runtime.sh vendoring fix that accompanies it.
#
# Hermetic: never sources mol-dog-doctor.sh (it has no library mode, and its main
# body needs a live Dolt server + GC_CITY_PATH; sourcing it here would require
# faking those or risk a REAL send_mayor_mail call to the Mayor — the exact class
# of noise this fix exists to stop, e.g. this city currently has 3 real orphan
# DBs, which would trip ORPHAN_WARN on any live run). Instead: (1) static text
# checks against the shipped script, mirroring mol-dog-backup.selftest.sh's
# drift-guards, (2) a real filesystem check that the runtime.sh path the script
# resolves at is actually present right now — the concrete thing a lib-mode/
# early-return selftest would be structurally blind to (see
# hermetic-selftest-cannot-test-the-bootstrap-it-stubs: 20/20 PASS + mutation
# test still missed a runtime.sh path that didn't exist), and (3) a pure
# arithmetic reproduction of the reported bug using the ACTUAL threshold value
# extracted from the script, not a hand-copied constant.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/mol-dog-doctor.sh"
ORDER_TOML="$HERE/../../orders/mol-dog-doctor.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== mol-dog-doctor.selftest.sh ==="

if [ -f "$SCRIPT" ]; then
  ok "vendored script exists at $SCRIPT"
else
  bad "vendored script missing at $SCRIPT"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

if bash -n "$SCRIPT"; then
  ok "script passes bash -n syntax check"
else
  bad "script has a syntax error"
fi

# ── drift-guard: runtime.sh sourced from its real (dolt pack) location, not ──
# ── a self-relative $PACK_DIR (the ga-gquc1 attempt-1 bootstrap-crash class: ──
# ── vendoring under town-deltas makes a self-relative $PACK_DIR resolve to ───
# ── town-deltas, which never has its own runtime.sh) ──────────────────────────
if grep -qE '^\s*PACK_DIR=.*BASH_SOURCE' "$SCRIPT"; then
  bad "self-relative \$PACK_DIR computation is present — resolves to town-deltas post-vendoring, no runtime.sh there (ga-gquc1 attempt-1 class)"
else
  ok "no self-relative \$PACK_DIR computation for locating runtime.sh"
fi
if grep -qF '.gc/system/packs' "$SCRIPT" && grep -qE '\.\s+"\$\{GC_SYSTEM_PACKS_DIR:-\$GC_CITY_PATH' "$SCRIPT"; then
  ok "runtime.sh is sourced from the dolt pack's GC_CITY_PATH-anchored live location"
else
  bad "runtime.sh sourcing no longer anchors to GC_CITY_PATH/.gc/system/packs/dolt"
fi

# ── bootstrap reality-check: the resolved runtime.sh path must actually EXIST ─
# ── right now. A passing grep above proves the PATTERN is safe, not that the ──
# ── path resolves — this closes that gap with a real filesystem check. ───────
: "${GC_CITY_PATH:=/Users/athos/gt/.gascity-gastown-hq}"
RESOLVED_RUNTIME="${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/runtime.sh"
if [ -f "$RESOLVED_RUNTIME" ]; then
  ok "resolved runtime.sh path exists on disk: $RESOLVED_RUNTIME"
else
  bad "resolved runtime.sh path does NOT exist: $RESOLVED_RUNTIME — script would abort at the sourcing line under set -e"
fi

# ── threshold fix: extract the ACTUAL shipped default, not a hand-copied ─────
# ── constant, so this test fails if the value is silently reverted/changed ───
THRESHOLD_LINE=$(grep -E '^BACKUP_STALE_S=' "$SCRIPT" || true)
NEW_THRESHOLD=$(printf '%s\n' "$THRESHOLD_LINE" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' || true)
if [ -n "$NEW_THRESHOLD" ]; then
  ok "extracted BACKUP_STALE_S default from shipped script: ${NEW_THRESHOLD}s"
else
  bad "could not extract BACKUP_STALE_S default from shipped script — got line: '$THRESHOLD_LINE'"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

# ── falsifying check: the EXACT reported false positive (ga-3wdlv, all 10 DBs ─
# ── at "19h old") must NOT trip the new threshold ─────────────────────────────
REPORTED_AGE_S=$((19 * 3600))
if [ "$REPORTED_AGE_S" -gt "$NEW_THRESHOLD" ]; then
  bad "reported false-positive age (19h=${REPORTED_AGE_S}s) STILL exceeds new threshold (${NEW_THRESHOLD}s) — bug not fixed"
else
  ok "reported false-positive age (19h=${REPORTED_AGE_S}s) no longer exceeds threshold (${NEW_THRESHOLD}s)"
fi

# ── sanity: the same age DOES exceed the OLD embedded threshold, proving this ─
# ── reproduces the real bug and isn't a vacuous comparison ────────────────────
OLD_THRESHOLD=43200
if [ "$REPORTED_AGE_S" -gt "$OLD_THRESHOLD" ]; then
  ok "sanity: the reported age (19h) DOES exceed the old 12h threshold — confirms this reproduces the real bug"
else
  bad "sanity check failed: 19h does not exceed 43200s — the reproduction itself is wrong"
fi

# ── a genuinely missed backup must still alarm — the fix must not widen the ──
# ── window into silence. 40h covers a full missed daily run plus margin ──────
GENUINELY_STALE_AGE_S=$((40 * 3600))
if [ "$GENUINELY_STALE_AGE_S" -gt "$NEW_THRESHOLD" ]; then
  ok "genuinely stale backup (40h) still exceeds new threshold — real staleness is still caught"
else
  bad "genuinely stale backup (40h=${GENUINELY_STALE_AGE_S}s) does NOT exceed new threshold (${NEW_THRESHOLD}s) — fix over-corrected into silence"
fi

# ── sanity bound: threshold must clear a full day, since the real job is ─────
# ── once-daily — anything <=24h would still false-positive near the boundary ─
ONE_DAY_S=86400
if [ "$NEW_THRESHOLD" -gt "$ONE_DAY_S" ]; then
  ok "new threshold (${NEW_THRESHOLD}s) clears a full 24h day (the real backup cadence)"
else
  bad "new threshold (${NEW_THRESHOLD}s) does not even clear 24h — will still false-positive near the daily boundary"
fi

# ── order override: exec/interval unchanged from the embedded order — this ───
# ── fix is scoped to the threshold + sourcing only, not the check cadence ────
if [ -f "$ORDER_TOML" ] && grep -qF 'exec = "$PACK_DIR/assets/scripts/mol-dog-doctor.sh"' "$ORDER_TOML" \
    && grep -qF 'interval = "5m"' "$ORDER_TOML"; then
  ok "town-deltas order override points at the vendored script, cooldown interval unchanged (5m)"
else
  bad "town-deltas order override missing or does not match expected [order] shape: $ORDER_TOML"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
