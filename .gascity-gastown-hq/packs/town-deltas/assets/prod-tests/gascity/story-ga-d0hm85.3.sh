#!/usr/bin/env bash
# prod-tests/gascity/story-ga-d0hm85.3.sh — prod test for ga-d0hm85.3 (slice 3/4): the engine calls the Jev tier, which ships OFF.
# What must be true in production after this slice is deployed:
#   1. every file the engine now imports is deployed (a missing module would fail EVERY large-output hook call of every pool
#      session, silently, as a lost measurement);
#   2. the REAL hook wrapper, on a large output no fixed rule applies to, with the tier pinned OFF, writes ONE row stamped
#      jev_tier=disabled and prints {} — no network, no credential lookup (the deployed default);
#   3. the same, with the tier forced ON through a temp enable file but the credential lookup pointed at a binary that fails: TWO
#      rows (the fixed row stamped 'attempted', then a cut-output-jev row NOT JUDGED with tokens_would_save null — never 0), still
#      {} on stdout and still no network;
#   4. the pool-roles manifest still equals the rendered overlays (this slice corrected the hook's rationale text).
# Called by run.sh after deploy (STORY_ID=ga-d0hm85.3). Exits 0 on pass. Never touches the network or the live log.
set -uo pipefail
CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"
log()  { echo "[prod-test:gascity ga-d0hm85.3] $*"; }
fail() { echo "[prod-test:gascity ga-d0hm85.3] FAIL: $*" >&2; exit 1; }
TMP="$(mktemp -d)" || fail "mktemp failed"
[ -n "$TMP" ] && [ -d "$TMP" ] || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT

for f in cut_output_egress.py cut_output_jev.py cut-output-shadow.py cut-output-shadow.sh cut_output_classifier.py; do
    [ -f "$SCRIPTS/$f" ] || fail "not deployed: $SCRIPTS/$f"
done
log "engine and everything it imports deployed ✓"

BIG="$(python3 -c "print('\n\n'.join(f'prod-test paragraph {i} with generic prose, no pytest or log shape' for i in range(80)))")"
PAYLOAD="$(python3 - "$BIG" <<'PYEOF'
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_response": {"stdout": sys.argv[1], "stderr": ""}, "tool_use_id": "prodtest-ga-d0hm85.3",
                  "session_id": "prodtest", "transcript_path": "/tmp/prodtest.jsonl", "tool_input": {"command": "prod-test --verbose"}}))
PYEOF
)"
run_hook() {  # run_hook <log> <enabled-file> -> stdout of the wrapper
    printf '%s' "$PAYLOAD" | env JEV_EXPERIMENT_LOG="$1" CUT_OUTPUT_SHADOW_JEV_ENABLED="$2" CUT_OUTPUT_SHADOW_JEV_DISABLED="$TMP/never-disabled" \
        CUT_OUTPUT_SHADOW_DISABLED="$TMP/never-hook-disabled" CLOUDFLARE_ACCOUNT_ID= CLOUDFLARE_API_TOKEN= JEV_SECRET_BIN="$TMP/failing-secret" \
        bash "$SCRIPTS/cut-output-shadow.sh" 2>"$TMP/hook.err"
}
printf '#!/bin/sh\nexit 1\n' > "$TMP/failing-secret"; chmod +x "$TMP/failing-secret"

OUT="$(run_hook "$TMP/off.jsonl" "$TMP/never-enabled")"
[ "$OUT" = "{}" ] || fail "tier OFF: the deployed wrapper printed [$OUT] (stderr: $(head -c 300 "$TMP/hook.err"))"
[ "$(wc -l < "$TMP/off.jsonl" 2>/dev/null | tr -d ' ')" = "1" ] || fail "tier OFF: expected exactly ONE row, got: $(head -c 400 "$TMP/off.jsonl" 2>/dev/null)"
python3 - "$(cat "$TMP/off.jsonl")" <<'PYEOF' || fail "tier OFF: the row is not the 'unmatched' row stamped jev_tier=disabled"
import json, sys
r = json.loads(sys.argv[1])
assert r["experiment"] == "cut-output-fixed" and r["rule"] == "unmatched" and r["jev_tier"] == "disabled" and r["tokens_would_save"] is None, r
PYEOF
log "tier OFF (the delivered default): one unmatched row stamped jev_tier=disabled, {} on stdout ✓"

printf '# prod test only: stands in for "<who said yes>, <bead#comment>, <when>"\n100\n' > "$TMP/enabled-100"
OUT="$(run_hook "$TMP/on.jsonl" "$TMP/enabled-100")"
[ "$OUT" = "{}" ] || fail "tier ON (vault down): the deployed wrapper printed [$OUT] (stderr: $(head -c 300 "$TMP/hook.err"))"
[ "$(wc -l < "$TMP/on.jsonl" 2>/dev/null | tr -d ' ')" = "2" ] || fail "tier ON (vault down): expected TWO rows, got: $(head -c 600 "$TMP/on.jsonl" 2>/dev/null)"
python3 - "$(sed -n 1p "$TMP/on.jsonl")" "$(sed -n 2p "$TMP/on.jsonl")" <<'PYEOF' || fail "tier ON (vault down): the two rows are not (attempted, not-judged with a null saving)"
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert a["jev_tier"] == "attempted" and b["experiment"] == "cut-output-jev" and a["entity_id"] == b["entity_id"], (a, b)
assert b["jev_state"] == "not-judged" and b["coverage"] == "none" and b["tokens_would_save"] is None and b["jev_error"] == "vault_unavailable", b
PYEOF
log "tier forced ON, vault down: attempted + a NOT-JUDGED row with tokens_would_save null (never 0), {} on stdout ✓"

python3 "$CITY/packs/town-deltas/assets/pool-preamble-build.py" check >"$TMP/preamble.out" 2>&1 || { cat "$TMP/preamble.out" >&2; fail "pool-preamble-build check failed"; }
log "pool-roles manifest == overlays ✓"
log "PASS"
exit 0
