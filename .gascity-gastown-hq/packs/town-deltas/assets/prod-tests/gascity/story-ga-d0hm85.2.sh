#!/usr/bin/env bash
# prod-tests/gascity/story-ga-d0hm85.2.sh — prod test for ga-d0hm85.2 (slice 2/4): the Jev tier's core (scripts/cut_output_jev.py),
# delivered UNWIRED and OFF. What must be true in production after this slice is deployed:
#   1. the core, its selftest and the classifier helper it needs are deployed;
#   2. the core's hermetic selftest (blocks tile the output, three states per block and record, the tier decision, the deadline,
#      every failure class of the Jev call) and the classifier's own selftest pass on the deployed copy;
#   3. THE TIER IS NOT ON WITHOUT A CITED AUTHORIZATION (town Regra N.4): the enable file does not exist, or its first non-comment
#      line is a number in 0..100 AND it has a `# who said yes, where, when` comment line. A number with no citation FAILS.
# Called by run.sh after deploy (STORY_ID=ga-d0hm85.2). Exits 0 on pass. No network, never writes the live log.
set -uo pipefail
CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"
ENABLED_FILE="${CUT_OUTPUT_SHADOW_JEV_ENABLED:-$CITY/.gc/logs/cut-output-jev.enabled}"
log()  { echo "[prod-test:gascity ga-d0hm85.2] $*"; }
fail() { echo "[prod-test:gascity ga-d0hm85.2] FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)" || fail "mktemp failed"
[ -n "$TMP" ] && [ -d "$TMP" ] || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT

for f in cut_output_egress.py cut_output_jev.py cut_output_jev.selftest.py cut_output_classifier.py; do
    [ -f "$SCRIPTS/$f" ] || fail "not deployed: $SCRIPTS/$f"
done
log "core, selftest, egress guard and classifier deployed ✓"
for t in cut_output_jev.selftest.py cut_output_classifier.py; do
    arg=""; [ "$t" = "cut_output_classifier.py" ] && arg="selftest"
    JEV_EXPERIMENT_LOG="$TMP/selftest.jsonl" python3 "$SCRIPTS/$t" $arg >"$TMP/$t.out" 2>&1 || { tail -15 "$TMP/$t.out" >&2; fail "$t failed on the deployed copy"; }
    grep -Eq "failed=0|FAIL=0" "$TMP/$t.out" || fail "$t did not report zero failures"
    log "$t: $(grep -E 'passed=|PASS=' "$TMP/$t.out" | tail -1) ✓"
done

if [ -e "$ENABLED_FILE" ]; then
    [ -f "$ENABLED_FILE" ] && [ -r "$ENABLED_FILE" ] || fail "enable file exists but is not a readable regular file: $ENABLED_FILE"
    PCT="$(grep -v '^[[:space:]]*#' "$ENABLED_FILE" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
    CITED="$(grep -c '^[[:space:]]*#[[:space:]]*[^[:space:]]' "$ENABLED_FILE")"
    if [ -n "$PCT" ] && python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0 < v <= 100 else 1)" "$PCT" 2>/dev/null; then
        [ "$CITED" -ge 1 ] || fail "the Jev tier is ENABLED ($PCT%) in $ENABLED_FILE with NO cited authorization — Regra N.4"
        log "Jev tier is ON at $PCT% with a cited authorization ✓"
    else
        log "enable file present but the tier is OFF (no usable number) ✓"
    fi
else
    log "Jev tier is OFF (no enable file) — the delivered default ✓"
fi
log "PASS"
exit 0
