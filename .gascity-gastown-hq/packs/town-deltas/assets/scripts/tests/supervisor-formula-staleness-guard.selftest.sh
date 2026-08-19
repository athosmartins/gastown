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
# at all. GATE FIX (blocking issue 1): a prior version of this fixture gave
# order-c NO resolvable formula, so a completely REMOVED type filter would
# still silently `continue` on the resulting formula_name="null" lookup
# (jq's `\(.formula)` on a missing field renders literally "null", which
# has no FAKE_FORMULA_SOURCES entry) -- indistinguishable from a working
# filter (verified live: replacing `select(.type=="formula")` with
# `select(true)` in the real script still passed this selftest 10/10).
# formula-c is now git-committed at NOW, the SAME stale shape as formula-a,
# and DOES have a FAKE_FORMULA_SOURCES entry -- so if the type filter is
# ever weakened or removed, order-c reaches the exact same successful
# lookup path formula-a does and gets reported STALE, a positive, wrong
# signal the assertion below can actually catch, instead of relying on a
# downstream lookup coincidentally failing for an unrelated reason.
echo "# stub-c" > "$CITY/formulas/formula-c.toml"
git -C "$CITY" add formulas/formula-c.toml
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" \
    git -C "$CITY" commit -q -m "chore: formula-c stub (same stale shape as formula-a)"

# formula-d: order-d is type=formula but its source resolves to a file that
# was NEVER git-committed -- `git log` returns empty -- must be skipped
# without crashing (no evidence, not a guessed verdict either way).
echo "# stub-d" > "$CITY/formulas/formula-d.toml"

git -C "$CITY" update-ref refs/remotes/origin/main HEAD

ORDER_LIST_JSON=$(cat <<EOF
{"ok":true,"orders":[
  {"name":"order-a","type":"formula","formula":"formula-a"},
  {"name":"order-b","type":"formula","formula":"formula-b"},
  {"name":"order-c","type":"exec","exec":"echo hi","formula":"formula-c"},
  {"name":"order-d","type":"formula","formula":"formula-d"}
]}
EOF
)

FORMULA_SOURCES="formula-a	$CITY/.beads/formulas/formula-a.formula.toml
formula-b	$CITY/formulas/formula-b.toml
formula-c	$CITY/formulas/formula-c.toml
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
if printf '%s' "$OUT1" | grep -q "order=order-c "; then bad "order-c (type=exec, not formula) was reported STALE -- type filter let it through despite having a resolvable, stale-shaped formula (formula-c)"; else ok "order-c (type=exec, formula=formula-c resolvable+stale if ever reached) correctly excluded by the type=formula filter"; fi
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

echo "── 7. functional (GATE FIX, blocking issue 2): every per-order lookup failing must be VISIBLE, never silently identical to a healthy cycle ──"
# Verified live before this fix existed: forcing every `gc bd formula show`
# call to fail while `gc order list --json` still succeeds produced ZERO
# stdout, ZERO notify calls, exit 0 -- byte-identical to a genuinely healthy
# "checked everything, all fresh" cycle. Two orders here, neither with a
# FAKE_FORMULA_SOURCES entry, so both hit the unresolved path regardless of
# type filtering (order-x/y are both type=formula).
ORDER_LIST_JSON_ALL_UNRESOLVED='{"ok":true,"orders":[
  {"name":"order-x","type":"formula","formula":"formula-x-no-fixture"},
  {"name":"order-y","type":"formula","formula":"formula-y-no-fixture"}
]}'
: > "$NOTIFY_LOG"
rm -f "$WORK/seen.json"
OUT3=$(env -i \
    PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
    HOME="$HOME" \
    GC_CITY_PATH="$CITY" \
    STALE_FORMULA_SEEN_FILE="$WORK/seen.json" \
    STALE_FORMULA_ESCALATE_AFTER_S=86400 \
    PS_BIN="$FAKE_PS" \
    GC_BIN="$FAKE_GC" \
    NOTIFY_BIN="$FAKE_NOTIFY" \
    FAKE_PS_OUTPUT="$SUP_PS_OUTPUT" \
    FAKE_ORDER_LIST_JSON="$ORDER_LIST_JSON_ALL_UNRESOLVED" \
    FAKE_FORMULA_SOURCES="" \
    NOTIFY_LOG="$NOTIFY_LOG" \
    bash "$SCRIPT")
if printf '%s' "$OUT3" | grep -qi "could not be checked at all\|UNKNOWN"; then ok "all-unresolved cycle prints an explicit degraded-state message"; else bad "all-unresolved cycle produced no distinguishing message -- silent, indistinguishable from a healthy cycle (the exact defect this section exists to catch)"; fi
NOTIFY_COUNT_DEGRADED=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT_DEGRADED" -ge "1" ]; then ok "all-unresolved cycle fires a notify ($NOTIFY_COUNT_DEGRADED call(s))"; else bad "all-unresolved cycle fired NO notify -- would go dark with nothing to page on"; fi
if grep -qi "conseguiu checar nada" "$NOTIFY_LOG"; then ok "degraded notify carries a distinct message from the per-order stale alert"; else bad "degraded notify text does not distinguish itself from a normal stale alert"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
