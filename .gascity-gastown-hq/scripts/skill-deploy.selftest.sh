#!/usr/bin/env bash
# Selftest for skill-deploy.sh — proves the "gc reload --soft" step retries
# at a fixed interval under lock contention instead of warning after a
# single attempt (ga-twax4: measured lock hold of ~76s vs. the script's own
# <5s assumption and the "~60s" manual-retry window it used to print).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/skill-deploy.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake `gc`: "session list" reports no attached sessions (keeps output clean);
# "reload --soft" fails FAKE_GC_RELOAD_FAIL_COUNT times (tracked via a counter
# file) before succeeding, so a test can simulate a lock busy for N attempts.
FAKE_GC="$TMP/fake-gc"
cat > "$FAKE_GC" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    session)
        echo '{"sessions": []}'
        exit 0
        ;;
    reload)
        n=0
        [ -f "$FAKE_GC_COUNTER_FILE" ] && n="$(cat "$FAKE_GC_COUNTER_FILE")"
        n=$((n + 1))
        echo "$n" > "$FAKE_GC_COUNTER_FILE"
        if [ "$n" -le "${FAKE_GC_RELOAD_FAIL_COUNT:-0}" ]; then
            echo "fake-gc: reload lock busy (attempt $n)" >&2
            exit 1
        fi
        echo "fake-gc: reload accepted (attempt $n)"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_GC"

# Minimal valid skill source dir (only SKILL.md is required by skill-deploy.sh).
SRC_SKILL="$TMP/src-skill"
mkdir -p "$SRC_SKILL"
echo "# fixture skill" > "$SRC_SKILL/SKILL.md"

echo "── Scenario 1: lock busy for 8 attempts (~80s at the default 10s spacing) then frees ──"
CITY1="$TMP/city1"; mkdir -p "$CITY1"
COUNTER1="$TMP/counter1"
OUT1="$TMP/out1.log"
SKILL_DEPLOY_CITY="$CITY1" GC="$FAKE_GC" SKILL_DEPLOY_RELOAD_RETRY_WAIT=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER1" FAKE_GC_RELOAD_FAIL_COUNT=8 \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT1" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "1: script exits 0 despite 8 failed reload attempts" || bad "1: expected exit 0, got $rc"
grep -q "WARNING — gc reload --soft failed" "$OUT1" && bad "1: WARNING printed even though reload succeeded within budget (regression: no retry)" || ok "1: no WARNING printed — retry absorbed the contention"
grep -q "gc reload --soft completed" "$OUT1" && ok "1: success message printed" || bad "1: missing success message"
[ "$(cat "$COUNTER1" 2>/dev/null)" = "9" ] && ok "1: reload actually retried (9 attempts recorded)" || bad "1: expected 9 recorded attempts, got $(cat "$COUNTER1" 2>/dev/null || echo '<none>')"

echo ""
echo "── Scenario 2: reload never succeeds — retries exhaust and WARNING still fires ──"
CITY2="$TMP/city2"; mkdir -p "$CITY2"
COUNTER2="$TMP/counter2"
OUT2="$TMP/out2.log"
SKILL_DEPLOY_CITY="$CITY2" GC="$FAKE_GC" SKILL_DEPLOY_RELOAD_RETRY_WAIT=0 SKILL_DEPLOY_RELOAD_MAX_RETRIES=2 \
    FAKE_GC_COUNTER_FILE="$COUNTER2" FAKE_GC_RELOAD_FAIL_COUNT=999 \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT2" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "2: script still exits 0 (deploy itself is not aborted)" || bad "2: expected exit 0, got $rc"
grep -q "WARNING — gc reload --soft failed after 3 attempts" "$OUT2" && ok "2: WARNING fires once the retry budget is genuinely exhausted" || bad "2: expected exhaustion WARNING, got: $(grep 'skill-deploy:.*reload' "$OUT2")"
[ "$(cat "$COUNTER2" 2>/dev/null)" = "3" ] && ok "2: stopped at 3 attempts (1 + SKILL_DEPLOY_RELOAD_MAX_RETRIES=2), not an infinite loop" || bad "2: expected 3 recorded attempts, got $(cat "$COUNTER2" 2>/dev/null || echo '<none>')"

echo ""
echo "skill-deploy selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
