#!/usr/bin/env bash
# prod-tests/gascity/story-ga-d0hm85.sh — prod test for ga-d0hm85: the Jev tier of the cut-large-output SHADOW front
# (scripts/cut_output_jev.py), delivered OFF.
#
# What must be true in production after this story is deployed:
#   1. the files are deployed (the engine imports cut_output_jev: a missing file would fail EVERY large-output hook call
#      of every pool session, silently, as a lost measurement);
#   2. the module's own hermetic selftest passes on the deployed copy (states, partition, egress guard, tier decision);
#   3. THE TIER IS NOT ON WITHOUT A CITED AUTHORIZATION (town Regra N.4). Sending command output to Cloudflare is outward-facing
#      and not undoable, so the enable file either does not exist, or its first non-comment line is a number in 0..100 AND it has
#      at least one `#` comment line (where the authorization is cited). An enable file with a number and no citation FAILS this
#      test: that is exactly the "an agent flipped it saying the Athos authorized" case the rule exists for;
#   4. the REAL hook wrapper, on a large output no fixed rule applies to, with the tier pinned OFF, writes ONE row stamped
#      jev_tier=disabled and prints {} (no network, no credential lookup — the deployed default);
#   5. the pool-roles manifest still equals the rendered overlays (this story corrected the hook's rationale text);
#   6. the report renders on the live log and has its Jev section.
#
# Called by run.sh after deploy (STORY_ID=ga-d0hm85). Exits 0 on pass. Never touches the network, never writes the live log.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"
LOGS="$CITY/.gc/logs"
ENABLED_FILE="${CUT_OUTPUT_SHADOW_JEV_ENABLED:-$LOGS/cut-output-jev.enabled}"

log()  { echo "[prod-test:gascity ga-d0hm85] $*"; }
fail() { echo "[prod-test:gascity ga-d0hm85] FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)" || fail "mktemp failed"
[ -n "$TMP" ] && [ -d "$TMP" ] || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT

# ── 1. deployed files ─────────────────────────────────────────────────────────
for f in cut_output_jev.py cut-output-shadow.py cut-output-shadow.sh cut_output_classifier.py jev_cut_output_report.py jev_cut_output_join.py; do
    [ -f "$SCRIPTS/$f" ] || fail "not deployed: $SCRIPTS/$f"
done
log "all six scripts deployed ✓"

# ── 2. the module's selftest, on the deployed copy, pointed at a throwaway log ─
JEV_EXPERIMENT_LOG="$TMP/selftest.jsonl" python3 "$SCRIPTS/cut_output_jev.py" selftest >"$TMP/jev-selftest.out" 2>&1 \
    || { tail -15 "$TMP/jev-selftest.out" >&2; fail "cut_output_jev.py selftest failed on the deployed copy"; }
grep -q "failed=0" "$TMP/jev-selftest.out" || fail "cut_output_jev.py selftest did not report failed=0"
log "cut_output_jev.py selftest: $(grep -E 'passed=' "$TMP/jev-selftest.out" | tail -1) ✓"

# ── 3. the tier is OFF, or ON with a cited authorization — never ON without one ─
if [ -e "$ENABLED_FILE" ]; then
    [ -f "$ENABLED_FILE" ] && [ -r "$ENABLED_FILE" ] || fail "enable file exists but is not a readable regular file: $ENABLED_FILE"
    PCT="$(grep -v '^[[:space:]]*#' "$ENABLED_FILE" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
    CITED="$(grep -c '^[[:space:]]*#[[:space:]]*[^[:space:]]' "$ENABLED_FILE")"
    if [ -n "$PCT" ] && python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0 < v <= 100 else 1)" "$PCT" 2>/dev/null; then
        [ "$CITED" -ge 1 ] || fail "the Jev tier is ENABLED ($PCT%) in $ENABLED_FILE with NO cited authorization (needs a '# who said yes, where, when' comment line) — Regra N.4"
        log "Jev tier is ON at $PCT% with a cited authorization ($CITED comment line(s)) ✓"
    else
        log "enable file present but the tier is OFF (no usable number: '${PCT:-<none>}') ✓"
    fi
else
    log "Jev tier is OFF (no enable file) — the delivered default ✓"
fi

# ── 4. the REAL wrapper, tier pinned OFF: one row, jev_tier=disabled, {} on stdout ─
BIG="$(python3 -c "print('\n\n'.join(f'prod-test paragraph {i} with generic prose, no pytest or log shape' for i in range(80)))")"
PAYLOAD="$(python3 - "$BIG" <<'PYEOF'
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_response": {"stdout": sys.argv[1], "stderr": ""}, "tool_use_id": "prodtest-ga-d0hm85",
                  "session_id": "prodtest", "transcript_path": "/tmp/prodtest.jsonl", "tool_input": {"command": "prod-test --verbose"}}))
PYEOF
)"
OUT="$(printf '%s' "$PAYLOAD" | env JEV_EXPERIMENT_LOG="$TMP/hook.jsonl" CUT_OUTPUT_SHADOW_JEV_ENABLED="$TMP/never-enabled" \
        CUT_OUTPUT_SHADOW_JEV_DISABLED="$TMP/never-disabled" CUT_OUTPUT_SHADOW_DISABLED="$TMP/never-hook-disabled" \
        CLOUDFLARE_ACCOUNT_ID= CLOUDFLARE_API_TOKEN= JEV_SECRET_BIN=/nonexistent/secret bash "$SCRIPTS/cut-output-shadow.sh" 2>"$TMP/hook.err")"
[ "$OUT" = "{}" ] || fail "the deployed wrapper printed [$OUT], expected {} (stderr: $(head -c 300 "$TMP/hook.err"))"
[ -f "$TMP/hook.jsonl" ] && [ "$(wc -l < "$TMP/hook.jsonl" | tr -d ' ')" = "1" ] || fail "expected exactly ONE row from the deployed hook, got: $(cat "$TMP/hook.jsonl" 2>/dev/null | head -c 400)"
ROW="$(cat "$TMP/hook.jsonl")"
python3 - "$ROW" <<'PYEOF' || fail "the hook's row is not the expected fixed-rule 'unmatched' row stamped jev_tier=disabled: $ROW"
import json, sys
r = json.loads(sys.argv[1])
assert r["experiment"] == "cut-output-fixed" and r["mode"] == "cut-output", r
assert r["rule"] == "unmatched" and r["jev_tier"] == "disabled", r
assert r["tokens_would_save"] is None, r
PYEOF
log "deployed hook, tier OFF: one unmatched row stamped jev_tier=disabled, {} on stdout ✓"

# ── 5. pool-roles manifest == rendered overlays ───────────────────────────────
python3 "$CITY/packs/town-deltas/assets/pool-preamble-build.py" check >"$TMP/preamble.out" 2>&1 \
    || { cat "$TMP/preamble.out" >&2; fail "pool-preamble-build check failed"; }
log "pool-roles manifest == overlays ✓"

# ── 6. the report renders on the live log and has its Jev section ─────────────
REPORT="$(python3 "$SCRIPTS/jev_cut_output_report.py" 2>&1)" || fail "jev_cut_output_report.py exited non-zero: $(printf '%s' "$REPORT" | head -c 300)"
case "$REPORT" in
    *"LOG NOT READ"*) fail "the report could not read the live log: $(printf '%s' "$REPORT" | head -c 300)" ;;
    *"Jev tier ("*) log "report renders, Jev section present ✓" ;;
    *) fail "the report has no Jev section: $(printf '%s' "$REPORT" | head -c 300)" ;;
esac

log "PASS"
exit 0
