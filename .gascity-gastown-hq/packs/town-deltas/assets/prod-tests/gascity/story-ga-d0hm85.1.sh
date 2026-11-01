#!/usr/bin/env bash
# prod-tests/gascity/story-ga-d0hm85.1.sh — prod test for ga-d0hm85.1 (slice 1/4 of the Jev tier of the cut-large-output
# SHADOW front): the egress guard (scripts/cut_output_egress.py) and the scrubbed command in the shadow log.
#
# What must be true in production after this slice is deployed:
#   1. the guard module and the engine that imports it are deployed (a missing module would make the engine fail on EVERY
#      large-output hook call of every pool session, silently, as a lost measurement);
#   2. the guard's own hermetic selftest passes on the deployed copy;
#   3. the REAL hook wrapper, given a large output and a command line that carries a credential, writes ONE row whose `command`
#      is the placeholder and whose text contains no trace of the credential, and prints {};
#   4. the same when the credential STARTS inside the logged 300 characters and ENDS after them (the command is judged before it is cut).
#
# Called by run.sh after deploy (STORY_ID=ga-d0hm85.1). Exits 0 on pass. Never touches the network or the live log.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"

log()  { echo "[prod-test:gascity ga-d0hm85.1] $*"; }
fail() { echo "[prod-test:gascity ga-d0hm85.1] FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)" || fail "mktemp failed"
[ -n "$TMP" ] && [ -d "$TMP" ] || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT

for f in cut_output_egress.py cut-output-shadow.py cut-output-shadow.sh; do
    [ -f "$SCRIPTS/$f" ] || fail "not deployed: $SCRIPTS/$f"
done
log "guard module, engine and wrapper deployed ✓"

JEV_EXPERIMENT_LOG="$TMP/selftest.jsonl" python3 "$SCRIPTS/cut_output_egress.py" selftest >"$TMP/egress.out" 2>&1 \
    || { tail -15 "$TMP/egress.out" >&2; fail "cut_output_egress.py selftest failed on the deployed copy"; }
grep -q "failed=0" "$TMP/egress.out" || fail "cut_output_egress.py selftest did not report failed=0"
log "$(grep -E 'passed=' "$TMP/egress.out" | tail -1) ✓"

SECRET='abcdef0123456789abcdef'
BIG="$(python3 -c "print('\n\n'.join(f'prod-test paragraph {i} with generic prose, no pytest or log shape' for i in range(80)))")"
PAYLOAD="$(python3 - "$BIG" "$SECRET" <<'PYEOF'
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_response": {"stdout": sys.argv[1], "stderr": ""}, "tool_use_id": "prodtest-ga-d0hm85.1",
                  "session_id": "prodtest", "transcript_path": "/tmp/prodtest.jsonl",
                  "tool_input": {"command": f"curl -H 'Authorization: Bearer {sys.argv[2]}' https://example.invalid/x"}}))
PYEOF
)"
OUT="$(printf '%s' "$PAYLOAD" | env JEV_EXPERIMENT_LOG="$TMP/hook.jsonl" CUT_OUTPUT_SHADOW_DISABLED="$TMP/never-hook-disabled" \
        bash "$SCRIPTS/cut-output-shadow.sh" 2>"$TMP/hook.err")"
[ "$OUT" = "{}" ] || fail "the deployed wrapper printed [$OUT], expected {} (stderr: $(head -c 300 "$TMP/hook.err"))"
[ -f "$TMP/hook.jsonl" ] && [ "$(wc -l < "$TMP/hook.jsonl" | tr -d ' ')" = "1" ] || fail "expected exactly ONE row from the deployed hook, got: $(head -c 400 "$TMP/hook.jsonl" 2>/dev/null)"
grep -q "$SECRET" "$TMP/hook.jsonl" && fail "the credential typed into the command line is AT REST in the shadow log row"
python3 - "$(cat "$TMP/hook.jsonl")" <<'PYEOF' || fail "the row's command is not the withheld placeholder: $(cat "$TMP/hook.jsonl" | head -c 300)"
import json, sys
r = json.loads(sys.argv[1])
assert r["experiment"] == "cut-output-fixed" and r["mode"] == "cut-output", r
assert r["command"].startswith("[command withheld"), r["command"]
PYEOF
log "deployed hook: one row, command withheld, credential nowhere in it, {} on stdout ✓"

# 4. gate fix 1: a credential that STARTS inside the logged 300 characters and ENDS after them (a DSN: the '@' that closes the
#    password is past the cut) must not leave its first part in the row either -- the command is judged before it is cut.
DSN_PW='Zk3Jq9XvB2nM'
PAYLOAD2="$(python3 - "$BIG" "$DSN_PW" <<'PYEOF'
import json, sys
cmd = "x" * 270 + " psql postgres://app:" + sys.argv[2] + "@db.internal:5432/app"
print(json.dumps({"tool_name": "Bash", "tool_response": {"stdout": sys.argv[1], "stderr": ""}, "tool_use_id": "prodtest-ga-d0hm85.1-straddle",
                  "session_id": "prodtest", "transcript_path": "/tmp/prodtest.jsonl", "tool_input": {"command": cmd}}))
PYEOF
)"
OUT2="$(printf '%s' "$PAYLOAD2" | env JEV_EXPERIMENT_LOG="$TMP/hook2.jsonl" CUT_OUTPUT_SHADOW_DISABLED="$TMP/never-hook-disabled" \
        bash "$SCRIPTS/cut-output-shadow.sh" 2>"$TMP/hook2.err")"
[ "$OUT2" = "{}" ] || fail "the deployed wrapper printed [$OUT2] for the straddling command, expected {} (stderr: $(head -c 300 "$TMP/hook2.err"))"
[ -f "$TMP/hook2.jsonl" ] && [ "$(wc -l < "$TMP/hook2.jsonl" | tr -d ' ')" = "1" ] || fail "expected exactly ONE row for the straddling command, got: $(head -c 400 "$TMP/hook2.jsonl" 2>/dev/null)"
# the first characters of the password are inside the logged prefix, so grep for a short fragment of it, not just the whole value
grep -q "Zk3Jq9" "$TMP/hook2.jsonl" && fail "the first part of a credential that straddles the logged prefix is AT REST in the shadow log row"
python3 - "$(cat "$TMP/hook2.jsonl")" <<'PYEOF' || fail "the straddling command's row is not the withheld placeholder: $(head -c 300 "$TMP/hook2.jsonl")"
import json, sys
r = json.loads(sys.argv[1])
assert r["command"].startswith("[command withheld"), r["command"]
PYEOF
log "deployed hook: a credential straddling the logged prefix is withheld whole ✓"

log "PASS"
exit 0
