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

# Fake `gc`: "session list" reports no attached sessions (keeps output clean)
# unless FAKE_GC_SESSIONS_JSON gives another listing, or FAKE_GC_SESSION_RC makes
# it fail (ga-ow127o6: scenarios 6-7);
# "reload --soft" fails FAKE_GC_RELOAD_FAIL_COUNT times (tracked via a counter
# file) before succeeding, so a test can simulate a lock busy for N attempts.
FAKE_GC="$TMP/fake-gc"
cat > "$FAKE_GC" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    session)
        if [ -n "${FAKE_GC_SESSION_RC:-}" ]; then exit "$FAKE_GC_SESSION_RC"; fi
        if [ -n "${FAKE_GC_SESSIONS_JSON:-}" ]; then echo "$FAKE_GC_SESSIONS_JSON"; else echo '{"sessions": []}'; fi
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
echo "── Scenario 3: reload succeeds but only AFTER the real deadline has passed ──"
# ga-twax4 gate-feedback: a late success must not be reported the same as an
# on-time one — the restart may already have fired at tick-2. Force elapsed >
# deadline without a real ~76s wait: deadline=0 plus one real 1s retry sleep
# guarantees RELOAD_ELAPSED (whole seconds since POKE_TS) is > 0.
CITY3="$TMP/city3"; mkdir -p "$CITY3"
COUNTER3="$TMP/counter3"
OUT3="$TMP/out3.log"
SKILL_DEPLOY_CITY="$CITY3" GC="$FAKE_GC" SKILL_DEPLOY_RELOAD_RETRY_WAIT=1 SKILL_DEPLOY_RELOAD_DEADLINE_SECONDS=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER3" FAKE_GC_RELOAD_FAIL_COUNT=1 \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT3" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "3: script exits 0" || bad "3: expected exit 0, got $rc"
grep -q "gc reload --soft completed late" "$OUT3" && ok "3: late-success message printed" || bad "3: missing late-success message, got: $(grep 'skill-deploy:.*reload' "$OUT3")"
grep -q "no session restarts will be triggered" "$OUT3" && bad "3: unconditional prevention claim printed even though the deadline had passed" || ok "3: unconditional prevention claim NOT printed"
grep -q "verify session state" "$OUT3" && ok "3: operator told to verify session state instead of assuming prevention" || bad "3: missing verify-session-state guidance"

echo ""
echo "── Scenario 4: retries exhaust AFTER the real deadline has already passed ──"
# ga-twax4 gate-feedback: the exhaustion warning must not tell the operator to
# act "within ~Ns" once that window has already closed.
CITY4="$TMP/city4"; mkdir -p "$CITY4"
COUNTER4="$TMP/counter4"
OUT4="$TMP/out4.log"
SKILL_DEPLOY_CITY="$CITY4" GC="$FAKE_GC" SKILL_DEPLOY_RELOAD_RETRY_WAIT=1 SKILL_DEPLOY_RELOAD_MAX_RETRIES=1 SKILL_DEPLOY_RELOAD_DEADLINE_SECONDS=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER4" FAKE_GC_RELOAD_FAIL_COUNT=999 \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT4" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "4: script still exits 0" || bad "4: expected exit 0, got $rc"
grep -q "window has already passed" "$OUT4" && ok "4: warning states the deadline already passed" || bad "4: missing already-passed guidance, got: $(grep 'skill-deploy:.*reload\|skill-deploy:.*window' "$OUT4")"
grep -q "manually within ~" "$OUT4" && bad "4: told operator to act within a window that had already closed" || ok "4: did NOT give a stale 'within ~Ns' instruction"

# ── hq-mutants lastro (ga-ow127o6): scenarios 5-8 close the survivors the scenarios above never reached.
# Each "absent" check on a LOG below is paired with a positive check on the SAME log, so a log that is empty or
# unreadable reprova instead of passing the absence (empty → the positive check fails; ilegível → same).

echo ""
echo "── Scenario 5: bad arguments / bad source are refused with exit 1 and write nothing ──"
# mutants 56e2d88b4a (usage exit), be70b3c7c7 (source dir missing), 1d30e04436 (SKILL.md missing): `exit 1` -> `exit 0`
CITY5="$TMP/city5"; mkdir -p "$CITY5"
OUT5="$TMP/out5.log"
EMPTY_SRC5="$TMP/empty-src5"; mkdir -p "$EMPTY_SRC5"
SKILL_DEPLOY_CITY="$CITY5" GC="$FAKE_GC" bash "$J" >"$OUT5" 2>&1
rc=$?
# vazio → o grep de "usage:" falha e o check reprova; falhou/ilegível → idem (nunca passa por ausência)
[ "$rc" -eq 1 ] && grep -q "usage: skill-deploy.sh" "$OUT5" && ok "5: no arguments -> usage + exit 1" || bad "5: no arguments: expected usage + exit 1, got rc=$rc: $(head -n 2 "$OUT5" 2>/dev/null)"
SKILL_DEPLOY_CITY="$CITY5" GC="$FAKE_GC" bash "$J" only-a-name >"$OUT5" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q "usage: skill-deploy.sh" "$OUT5" && ok "5: one argument -> usage + exit 1" || bad "5: one argument: expected usage + exit 1, got rc=$rc: $(head -n 2 "$OUT5" 2>/dev/null)"
SKILL_DEPLOY_CITY="$CITY5" GC="$FAKE_GC" bash "$J" fixture-skill "$TMP/no-such-dir" >"$OUT5" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q "source directory not found: $TMP/no-such-dir" "$OUT5" && ok "5: missing source dir -> message + exit 1" || bad "5: missing source dir: expected message + exit 1, got rc=$rc: $(head -n 2 "$OUT5" 2>/dev/null)"
SKILL_DEPLOY_CITY="$CITY5" GC="$FAKE_GC" bash "$J" fixture-skill "$EMPTY_SRC5" >"$OUT5" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q "SKILL.md not found in $EMPTY_SRC5" "$OUT5" && ok "5: source dir without SKILL.md -> message + exit 1" || bad "5: no SKILL.md: expected message + exit 1, got rc=$rc: $(head -n 2 "$OUT5" 2>/dev/null)"
[ ! -e "$CITY5/skills" ] && [ ! -e "$CITY5/.claude" ] && ok "5: none of the four refusals wrote to the city sinks" || bad "5: a refused deploy still created a city sink"

echo ""
echo "── Scenario 6: attached sessions are warned about and listed, and the deploy is not blocked ──"
# mutants d2c52abd7f (neg-if on `command -v gc`), 93028eca27 + c279799168 (neg-if / -n -> -z on the attached test),
# 1f73161660 (neg-if on the listing loop)
CITY6="$TMP/city6"; mkdir -p "$CITY6"
COUNTER6="$TMP/counter6"
OUT6="$TMP/out6.log"
SESS6='{"sessions":[{"name":"mayor","id":"s-1","attached":true},{"name":"dog","id":"s-2","attached":false},{"name":"deacon","id":"s-3","attached":true}]}'
SKILL_DEPLOY_CITY="$CITY6" GC="$FAKE_GC" SKILL_DEPLOY_RELOAD_RETRY_WAIT=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER6" FAKE_GC_SESSIONS_JSON="$SESS6" \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT6" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "6: attached sessions only warn (exit 0, deploy not blocked)" || bad "6: expected exit 0, got $rc"
grep -q "WARNING — human-attached sessions detected" "$OUT6" && ok "6: attached-sessions WARNING printed" || bad "6: missing attached-sessions WARNING, got: $(grep 'skill-deploy:' "$OUT6" 2>/dev/null | head -n 2)"
grep -q "^  - mayor (s-1)$" "$OUT6" && grep -q "^  - deacon (s-3)$" "$OUT6" && ok "6: every attached session is listed by name and id" || bad "6: attached sessions not listed one per line, got: $(grep '^  - ' "$OUT6" 2>/dev/null)"
grep -q "s-2" "$OUT6" && bad "6: a session that is NOT attached was listed" || ok "6: the unattached session is not listed"
grep -q "No attached sessions" "$OUT6" && bad "6: said 'No attached sessions' while two are attached" || ok "6: did NOT claim 'No attached sessions'"
[ -f "$CITY6/skills/fixture-skill/SKILL.md" ] && ok "6: the skill was still written to the city sink" || bad "6: the deploy did not run after the warning"

echo ""
echo "── Scenario 7: 'gc session list' failing does not abort the deploy ──"
# mutant 53e55ea66c: `|| true` -> `&& true` at the end of the session probe (set -e + pipefail would abort on gc's rc)
CITY7="$TMP/city7"; mkdir -p "$CITY7"
COUNTER7="$TMP/counter7"
OUT7="$TMP/out7.log"
SKILL_DEPLOY_CITY="$CITY7" GC="$FAKE_GC" SKILL_DEPLOY_RELOAD_RETRY_WAIT=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER7" FAKE_GC_SESSION_RC=3 \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT7" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "7: exit 0 although 'gc session list' exited 3" || bad "7: expected exit 0, got $rc: $(tail -n 2 "$OUT7" 2>/dev/null)"
grep -q "No attached sessions — safe to deploy" "$OUT7" && ok "7: unreadable session list is reported as 'no attached sessions' and the deploy goes on" || bad "7: missing 'No attached sessions' line, got: $(grep 'skill-deploy:' "$OUT7" 2>/dev/null | head -n 2)"
grep -q "Done. Skill 'fixture-skill' deployed" "$OUT7" && ok "7: the deploy ran to the end" || bad "7: the deploy stopped before the end"

echo ""
echo "── Scenario 8: the manifest entry is recorded, and a manifest that cannot be written is reported ──"
# mutant 8d4ccc1ca4: `if <python manifest writer>` -> `if ! ...` (success and failure messages swapped)
CITY8="$TMP/city8"; mkdir -p "$CITY8"
COUNTER8="$TMP/counter8"
OUT8="$TMP/out8.log"
MANIFEST8="$TMP/m8/skill-manifest.json"
SKILL_DEPLOY_CITY="$CITY8" GC="$FAKE_GC" SKILL_MANIFEST="$MANIFEST8" SKILL_DEPLOY_RELOAD_RETRY_WAIT=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER8" \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT8" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q "Manifest updated (fixture-skill -> " "$OUT8" && ok "8: manifest written -> 'Manifest updated' + exit 0" || bad "8: expected 'Manifest updated' + exit 0, got rc=$rc: $(grep -i 'manifest' "$OUT8" 2>/dev/null | head -n 2)"
grep -q "failed to update manifest" "$OUT8" && bad "8: the success path also warned the manifest failed" || ok "8: no failure WARNING on a good write"
# vazio → o grep do nome falha e o check reprova; falhou/ilegível (arquivo ausente) → idem
grep -q '"fixture-skill"' "$MANIFEST8" 2>/dev/null && ok "8: the manifest file records the skill" || bad "8: manifest file missing or without the skill"
# a manifest PATH that is a directory: open() raises IsADirectoryError, which the writer does not swallow
CITY8B="$TMP/city8b"; mkdir -p "$CITY8B"
MANIFEST8B="$TMP/m8b/manifest-is-a-dir"; mkdir -p "$MANIFEST8B"
OUT8B="$TMP/out8b.log"
SKILL_DEPLOY_CITY="$CITY8B" GC="$FAKE_GC" SKILL_MANIFEST="$MANIFEST8B" SKILL_DEPLOY_RELOAD_RETRY_WAIT=0 \
    FAKE_GC_COUNTER_FILE="$COUNTER8" \
    bash "$J" fixture-skill "$SRC_SKILL" >"$OUT8B" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q "WARNING — failed to update manifest at $MANIFEST8B" "$OUT8B" && ok "8: unwritable manifest -> WARNING, deploy not aborted (exit 0)" || bad "8: expected WARNING + exit 0, got rc=$rc: $(grep -i 'manifest' "$OUT8B" 2>/dev/null | head -n 2)"
grep -q "Manifest updated" "$OUT8B" && bad "8: claimed 'Manifest updated' for a manifest that could not be written" || ok "8: no 'Manifest updated' claim on a failed write"

echo ""
echo "skill-deploy selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
