#!/usr/bin/env bash
# supervisor-formula-staleness-guard.selftest.sh (ga-4tt37)
#
# Runs the REAL supervisor-formula-staleness-guard.sh (not a reimplementation)
# against a disposable git repo + fixture formula files, with ps/gc/notify
# swapped for fakes via the script's own PS_BIN/GC_BIN/NOTIFY_BIN env-var
# seams. Exit 0 iff every assertion holds.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../supervisor-formula-staleness-guard.sh"
FAKE_PS="$SELF_DIR/supervisor-formula-staleness-guard.fake-ps"
FAKE_GC="$SELF_DIR/supervisor-formula-staleness-guard.fake-gc"
FAKE_NOTIFY="$SELF_DIR/supervisor-formula-staleness-guard.fake-notify"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CITY="$WORK/city"
NOTIFY_LOG="$WORK/notify.log"
: > "$NOTIFY_LOG"

echo "── 1. syntax ──"
if bash -n "$SCRIPT"; then ok "supervisor-formula-staleness-guard.sh passes bash -n"; else bad "bash -n FAILED"; exit 1; fi

echo "── setup: disposable git repo + fixture formulas ──"
NOW=$(date +%s)
# Supervisor fixture below runs for 2h (7200s), so its start_epoch is
# NOW-7200. OLD must be BEFORE that to represent a genuinely fresh formula
# (edited before the supervisor's current run began) -- 3h ago (10800s).
OLD=$((NOW - 10800))
mkdir -p "$CITY/formulas" "$CITY/.beads/formulas"
git -C "$CITY" init -q
git -C "$CITY" config user.email "test@test.local"
git -C "$CITY" config user.name "selftest"

# formula-a: order-a is type=formula, committed just NOW. Supervisor has
# been running 2h -> commit is NEWER than supervisor start -> STALE.
# .source points at a SYMLINK (mirrors the real .beads/formulas/*.formula.toml
# -> packs/town-deltas/formulas/*.toml layout) so this also exercises the
# resolve_real_path symlink-following path, not just a direct file.
echo "# stub-a" > "$CITY/formulas/formula-a.toml"
git -C "$CITY" add formulas/formula-a.toml
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" \
    git -C "$CITY" commit -q -m "fix(ga-realbead): formula-a fix"
ln -s "$CITY/formulas/formula-a.toml" "$CITY/.beads/formulas/formula-a.formula.toml"

# formula-b: order-b is type=formula, committed 1h ago -> commit is OLDER
# than supervisor start -> NOT stale.
echo "# stub-b" > "$CITY/formulas/formula-b.toml"
git -C "$CITY" add formulas/formula-b.toml
GIT_AUTHOR_DATE="@$OLD" GIT_COMMITTER_DATE="@$OLD" \
    git -C "$CITY" commit -q -m "chore: formula-b stub"

# formula-c: order-c is type=EXEC, not formula -- must never be looked up
# at all. If the type filter ever breaks, fake-gc has no FAKE_FORMULA_SOURCES
# entry for "formula-c" and would exit 1, which the real script already
# treats as "skip this order" -- so a broken filter would go undetected by
# that alone. Assert directly on notify output instead (section 2 below).

# formula-d: order-d is type=formula but its source resolves to a file that
# was NEVER git-committed -- `git log` returns empty -- must be skipped
# without crashing (no evidence, not a guessed verdict either way).
echo "# stub-d" > "$CITY/formulas/formula-d.toml"

git -C "$CITY" update-ref refs/remotes/origin/main HEAD

ORDER_LIST_JSON=$(cat <<EOF
{"ok":true,"orders":[
  {"name":"order-a","type":"formula","formula":"formula-a"},
  {"name":"order-b","type":"formula","formula":"formula-b"},
  {"name":"order-c","type":"exec","exec":"echo hi"},
  {"name":"order-d","type":"formula","formula":"formula-d"}
]}
EOF
)

FORMULA_SOURCES="formula-a	$CITY/.beads/formulas/formula-a.formula.toml
formula-b	$CITY/formulas/formula-b.toml
formula-d	$CITY/formulas/formula-d.toml"

run_guard() {
    local ps_output="$1"
    env -i \
        PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
        HOME="$HOME" \
        GC_CITY_PATH="$CITY" \
        STALE_FORMULA_SEEN_FILE="$WORK/seen.json" \
        STALE_FORMULA_ESCALATE_AFTER_S="${TEST_ESCALATE_AFTER_S:-86400}" \
        PS_BIN="$FAKE_PS" \
        GC_BIN="$FAKE_GC" \
        NOTIFY_BIN="$FAKE_NOTIFY" \
        FAKE_PS_OUTPUT="$ps_output" \
        FAKE_ORDER_LIST_JSON="$ORDER_LIST_JSON" \
        FAKE_FORMULA_SOURCES="$FORMULA_SOURCES" \
        NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT"
}

# Supervisor running 2h (7200s elapsed) -> start_epoch = NOW - 7200, which is
# BEFORE formula-a's commit (NOW) and AFTER formula-b's commit (NOW-3600).
SUP_PS_OUTPUT="555   02:00:00 /opt/homebrew/bin/gc supervisor run"

echo "── 2. functional: classifies all four orders correctly ──"
OUT1=$(run_guard "$SUP_PS_OUTPUT")

if printf '%s' "$OUT1" | grep -q "order=order-a "; then ok "order-a (stale, formula edited after supervisor start) reported"; else bad "order-a NOT reported (should be stale)"; fi
if printf '%s' "$OUT1" | grep -q "order=order-b "; then bad "order-b (fresh, formula edited before supervisor start) incorrectly reported"; else ok "order-b correctly silent"; fi
if printf '%s' "$OUT1" | grep -q "order-c"; then bad "order-c (type=exec, not formula) was looked up at all -- type filter broken"; else ok "order-c (type=exec) correctly excluded by the type=formula filter"; fi
if printf '%s' "$OUT1" | grep -q "order=order-d "; then bad "order-d (untracked formula file, no git evidence) incorrectly reported as stale"; else ok "order-d (no git history for its formula file) correctly skipped, no crash, no guessed verdict"; fi

echo "── 3. functional: notify fires exactly once (only order-a is stale) ──"
NOTIFY_COUNT=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT" = "1" ]; then ok "exactly 1 notify call (order-a)"; else bad "expected 1 notify call, got $NOTIFY_COUNT"; fi

echo "── 4. functional: supervisor not running -> clean skip, no crash, no notify ──"
: > "$NOTIFY_LOG"
rm -f "$WORK/seen.json"
OUT2=$(run_guard "")
if printf '%s' "$OUT2" | grep -qi "not found running"; then ok "supervisor-not-running case reported cleanly"; else bad "supervisor-not-running case did not report the expected skip message"; fi
NOTIFY_COUNT_NONE=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT_NONE" = "0" ]; then ok "no notify fired when supervisor isn't running"; else bad "notify fired ($NOTIFY_COUNT_NONE) when supervisor isn't running"; fi

echo "── 5. functional: dedup -- immediate re-run within the escalate window does NOT re-notify ──"
: > "$NOTIFY_LOG"
rm -f "$WORK/seen.json"
run_guard "$SUP_PS_OUTPUT" >/dev/null
NOTIFY_COUNT_FIRST=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
run_guard "$SUP_PS_OUTPUT" >/dev/null
NOTIFY_COUNT_SECOND=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT_SECOND" = "$NOTIFY_COUNT_FIRST" ]; then ok "second run within escalate window added zero new notifies ($NOTIFY_COUNT_SECOND total)"; else bad "second run re-notified (got $NOTIFY_COUNT_SECOND, expected $NOTIFY_COUNT_FIRST) -- dedup ledger not honored"; fi

echo "── 6. functional: a run past the escalate window DOES re-notify (dedup is a re-fire cadence, not permanent silence) ──"
TEST_ESCALATE_AFTER_S=0 run_guard "$SUP_PS_OUTPUT" >/dev/null
NOTIFY_COUNT_THIRD=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT_THIRD" -gt "$NOTIFY_COUNT_SECOND" ]; then ok "re-notified after escalate window elapsed ($NOTIFY_COUNT_SECOND -> $NOTIFY_COUNT_THIRD)"; else bad "did NOT re-notify after escalate window elapsed (stuck at $NOTIFY_COUNT_THIRD) -- a real still-stale supervisor would go silent forever"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
