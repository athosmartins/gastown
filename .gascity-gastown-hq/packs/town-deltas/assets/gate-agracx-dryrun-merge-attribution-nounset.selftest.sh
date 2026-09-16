#!/usr/bin/env bash
# gate-agracx-dryrun-merge-attribution-nounset.selftest.sh — ga-agracx gate-fix
# (attempt 1) regression guard.
#
# CASO (gate reviewer, gate_run=ga-9xngnq, 2026-09-16): the ga-agracx patch
# wired quality-gate-dispatcher.sh's ga-l7n3v daemon-refresh call site to
# thread its own MERGE_PRE_MAIN_SHA/MERGE_SHA through as
# BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA (for Step 1b gap-attribution). The line
# used a BARE ($MERGE_PRE_MAIN_SHA) reference — every pre-existing use in this
# file goes through ${MERGE_PRE_MAIN_SHA:+...}. Under DRY_RUN=1 (a live,
# exercised mode of this exact success block — see ~5056-5060),
# MERGE_PRE_MAIN_SHA is NEVER assigned (only set in the real-merge else branch
# or on merge retry). Referencing a truly-unset var via a bare env-prefix
# assignment inside a `$(... || true)` command substitution triggers bash's
# nounset fatal error DURING parameter expansion — BEFORE the guarded command
# (and its trailing `|| true`) ever runs — aborting the ENTIRE dispatcher
# process mid-bead. No existing selftest exercised this merge-success/DRY_RUN
# path (daemon-refresh-bead-attribution.test.sh calls daemon-refresh.sh
# directly, bypassing this caller-side wiring).
#
# FIX: BEAD_MERGE_PRE_SHA="${MERGE_PRE_MAIN_SHA:-}" — matches daemon-refresh.sh's
# own ${BEAD_MERGE_PRE_SHA:-} default (:359), which already treats empty as
# "no attribution range" (Step 1b's own guard requires -n on both ends, :647).
#
# ACEITE: a DRY_RUN=1 invocation that reaches this block with
# MERGE_PRE_MAIN_SHA truly unset does not crash, and BEAD_MERGE_PRE_SHA
# reaches daemon-refresh.sh as an empty string (genuinely absent, matching the
# "unknown attribution range" case daemon-refresh.sh already handles).
#
# This harness live-extracts the DR_OUT construction block via sentinel (same
# technique as gate-deploy-retry.selftest.sh) and runs it twice: once as
# extracted (must NOT crash), and once with the fix mutated back to the
# original bare-reference bug (MUST crash) — proving the test actually
# detects the defect it guards, not just that the current code happens to
# pass. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

echo "== gate-agracx-dryrun-merge-attribution-nounset.selftest (ga-agracx gate-fix attempt 1) =="

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

# ── 1. live extraction ─────────────────────────────────────────────────────
echo "── 1. DR_OUT block (live extraction via sentinel) ──"
SENTINEL="ga-agracx-dryrun-merge-attribution"
BLOCK="$(sed -n "/# SELFTEST-EXTRACT $SENTINEL: BEGIN/,/# SELFTEST-EXTRACT $SENTINEL: END/p" "$DISPATCHER")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: could not locate '$SENTINEL' sentinel block in $DISPATCHER"
  exit 1
fi
ok "located live DR_OUT block via sentinel extraction"

# Stub daemon-refresh.sh under a fake GC_CITY so the extracted block runs
# end-to-end without touching the real runtime/daemon set. Echoes back the two
# attribution env vars it received so the harness can assert exactly what the
# caller threaded through.
STUB_CITY=$(mktemp -d)
mkdir -p "$STUB_CITY/packs/town-deltas/assets"
cat > "$STUB_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'STUBEOF'
#!/usr/bin/env bash
echo "VERDICT=SKIPPED"
echo "REASON=selftest-stub"
echo "PROOF=stub"
echo "SEEN_PRE_SHA=[${BEAD_MERGE_PRE_SHA:-<unset>}]"
echo "SEEN_MERGE_SHA=[${BEAD_MERGE_SHA:-<unset>}]"
STUBEOF
chmod +x "$STUB_CITY/packs/town-deltas/assets/daemon-refresh.sh"

run_block() {
  # $1 = block text to run (live or mutated). Mirrors the exact DRY_RUN state
  # the merge-success path reaches at ~5056-5060: MERGE_PRE_MAIN_SHA never
  # assigned, MERGE_SHA="DRY_RUN_NO_MERGE".
  local block="$1"
  bash -c '
    set -euo pipefail
    unset MERGE_PRE_MAIN_SHA
    MERGE_SHA="DRY_RUN_NO_MERGE"
    DRY_RUN="1"
    DR_RUNTIME_DIR="'"$STUB_CITY"'"
    DR_PRE_SHA=""
    DR_EPOCH=0
    DR_SENSITIVE=""
    DR_EXTRA_ROOTS=""
    DR_FORCE_RESTART=""
    GC_CITY="'"$STUB_CITY"'"
    '"$block"'
    printf "BLOCK_OK DR_OUT=[%s]\n" "$DR_OUT"
  ' 2>&1
}

# (a) the LIVE (post-fix) block must not crash, and must thread an empty
# BEAD_MERGE_PRE_SHA through (not lost, not a stale value).
OUT_FIXED=$(run_block "$BLOCK") && RC_FIXED=0 || RC_FIXED=$?
if printf '%s' "$OUT_FIXED" | grep -q "unbound variable"; then
  bad "(a) live block still crashes on unset MERGE_PRE_MAIN_SHA under DRY_RUN: $OUT_FIXED"
elif printf '%s' "$OUT_FIXED" | grep -q "BLOCK_OK" && printf '%s' "$OUT_FIXED" | grep -q "SEEN_PRE_SHA=\[<unset>\]"; then
  ok "(a) live block survives DRY_RUN with MERGE_PRE_MAIN_SHA unset, threads empty BEAD_MERGE_PRE_SHA through (rc=$RC_FIXED)"
else
  bad "(a) unexpected output from live block (rc=$RC_FIXED): $OUT_FIXED"
fi

# (b) mutation test: reintroduce the EXACT pre-fix bug (bare reference) into
# the freshly-extracted block text and prove the harness actually detects it
# — a test that only ever runs the fixed code proves nothing (it would also
# "pass" if the sentinel had drifted to wrap the wrong lines).
MUTATED=$(printf '%s\n' "$BLOCK" | sed 's/BEAD_MERGE_PRE_SHA="\${MERGE_PRE_MAIN_SHA:-}"/BEAD_MERGE_PRE_SHA="$MERGE_PRE_MAIN_SHA"/')
if [ "$MUTATED" = "$BLOCK" ]; then
  echo "FATAL: mutation did not change the block — sentinel extraction may have drifted"
  exit 1
fi
OUT_BUG=$(run_block "$MUTATED") && RC_BUG=0 || RC_BUG=$?
if printf '%s' "$OUT_BUG" | grep -q "unbound variable"; then
  ok "(b) pre-fix bare-reference mutation reproduces the nounset crash (proves the test detects the real defect)"
else
  bad "(b) expected the mutated (pre-fix) block to crash with 'unbound variable' (rc=$RC_BUG): $OUT_BUG"
fi

rm -rf "$STUB_CITY"

# ── 2. drift-guard ──────────────────────────────────────────────────────────
echo "── 2. drift-guard ──"
if grep -qF 'BEAD_MERGE_PRE_SHA="${MERGE_PRE_MAIN_SHA:-}" BEAD_MERGE_SHA="$MERGE_SHA"' "$DISPATCHER"; then
  ok "BEAD_MERGE_PRE_SHA uses the guarded :- form, not a bare reference"
else
  bad "BEAD_MERGE_PRE_SHA no longer uses the guarded :- form — did the ga-agracx gate-fix get reverted?"
fi

# ── 3. syntax ────────────────────────────────────────────────────────────────
echo "── 3. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
