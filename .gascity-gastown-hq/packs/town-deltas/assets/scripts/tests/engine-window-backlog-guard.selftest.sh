#!/usr/bin/env bash
# engine-window-backlog-guard.selftest.sh (ga-jwb60)
#
# Runs the REAL engine-window-backlog-guard.sh (not a reimplementation)
# against two disposable git repos -- a fixture CITY (holding
# docs/pending-engine-window/*.patch, committed with controlled dates) and a
# fixture SRC_TREE (the "engine source" the patches target) -- with only
# notify swapped for a fake via the script's own NOTIFY_BIN env-var seam. Real
# git runs for real against the fixtures; PENDING/LANDED/UNKNOWN classification
# is proven by actual `git apply --check`/`--check --reverse` outcomes, not by
# asserting on mocked behavior. Exit 0 iff every assertion holds.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../engine-window-backlog-guard.sh"
FAKE_NOTIFY="$SELF_DIR/engine-window-backlog-guard.fake-notify"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
NOTIFY_LOG="$WORK/notify.log"
: > "$NOTIFY_LOG"

echo "── 1. syntax ──"
if bash -n "$SCRIPT"; then ok "engine-window-backlog-guard.sh passes bash -n"; else bad "bash -n FAILED"; exit 1; fi

echo "── 2. static invariant: git apply is NEVER invoked without --check ──"
# DETECTION-ONLY is load-bearing (build+swap is Mayor-scope, not this guard's).
# Any 'apply' call on a line lacking '--check' would be a live mutation of
# SRC_TREE -- catch that at the source level, not just by behavior. Comment
# lines are excluded: the header prose legitimately says things like "não
# passa pelo apply-check" (compound word, no literal "--check" flag), which
# a naive grep flags as a false positive -- proven live: this check FAILED
# against the correct, unmodified script until comments were excluded here.
BAD_APPLY_LINES=$(grep -n 'apply' "$SCRIPT" | grep -v -- '--check' | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [ -z "$BAD_APPLY_LINES" ]; then
    ok "every code 'apply' invocation in the script includes --check"
else
    bad "found apply line(s) without --check (would mutate SRC_TREE for real):"
    printf '%s\n' "$BAD_APPLY_LINES"
fi

echo "── setup: fixture SRC_TREE (the 'engine source') ──"
SRC="$WORK/src"
mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" config user.email "test@test.local"
git -C "$SRC" config user.name "selftest"

printf 'package main\n\nfunc Foo() int {\n\treturn 1\n}\n' > "$SRC/foo.go"
printf 'package main\n\nfunc Bar() int {\n\treturn 2\n}\n' > "$SRC/baz.go"
printf 'package main\n\nfunc Qux() int {\n\treturn 100\n}\n' > "$SRC/qux.go"
git -C "$SRC" add foo.go baz.go qux.go
git -C "$SRC" commit -q -m "initial"

# pending.patch: changes foo.go, NEVER applied to SRC -> forward clean, reverse dirty.
printf 'package main\n\nfunc Foo() int {\n\treturn 42\n}\n' > "$SRC/foo.go"
git -C "$SRC" diff -- foo.go > "$WORK/pending.patch"
git -C "$SRC" checkout -q -- foo.go

# landed.patch: changes baz.go, and that exact change IS committed to SRC ->
# forward dirty (already applied), reverse clean.
printf 'package main\n\nfunc Bar() int {\n\treturn 222\n}\n' > "$SRC/baz.go"
git -C "$SRC" diff -- baz.go > "$WORK/landed.patch"
git -C "$SRC" add baz.go
git -C "$SRC" commit -q -m "apply bar change directly"

# conflict.patch: diff of qux.go (100 -> 200), but SRC's qux.go has since
# drifted to a THIRD value (999) on the same line -> neither direction clean.
printf 'package main\n\nfunc Qux() int {\n\treturn 200\n}\n' > "$SRC/qux.go"
git -C "$SRC" diff -- qux.go > "$WORK/conflict.patch"
git -C "$SRC" checkout -q -- qux.go
printf 'package main\n\nfunc Qux() int {\n\treturn 999\n}\n' > "$SRC/qux.go"
git -C "$SRC" add qux.go
git -C "$SRC" commit -q -m "unrelated drift on qux, same line"

echo "── setup: fixture CITY (docs/pending-engine-window/, controlled commit dates) ──"
CITY="$WORK/city"
mkdir -p "$CITY/docs/pending-engine-window" "$CITY/.beads"
git -C "$CITY" init -q
git -C "$CITY" config user.email "test@test.local"
git -C "$CITY" config user.name "selftest"
NOW=$(date +%s)
OLD=$((NOW - 864000))   # 10 days ago

cp "$WORK/pending.patch" "$CITY/docs/pending-engine-window/ga-p1-pending.patch"
git -C "$CITY" add docs/pending-engine-window/ga-p1-pending.patch
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" git -C "$CITY" commit -q -m "docs(ga-p1): stage pending patch"

cp "$WORK/landed.patch" "$CITY/docs/pending-engine-window/ga-p2-landed.patch"
git -C "$CITY" add docs/pending-engine-window/ga-p2-landed.patch
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" git -C "$CITY" commit -q -m "docs(ga-p2): stage landed patch"

cp "$WORK/conflict.patch" "$CITY/docs/pending-engine-window/ga-p3-conflict.patch"
git -C "$CITY" add docs/pending-engine-window/ga-p3-conflict.patch
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" git -C "$CITY" commit -q -m "docs(ga-p3): stage conflict patch"

echo "not a real diff, just marked" > "$CITY/docs/pending-engine-window/ga-p4-marked.patch.APLICADO-20260101"
git -C "$CITY" add docs/pending-engine-window/ga-p4-marked.patch.APLICADO-20260101
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" git -C "$CITY" commit -q -m "chore(engine-window): marca ga-p4 como APLICADO"

cp "$WORK/pending.patch" "$CITY/docs/pending-engine-window/ga-p5-old-pending.patch"
git -C "$CITY" add docs/pending-engine-window/ga-p5-old-pending.patch
GIT_AUTHOR_DATE="@$OLD" GIT_COMMITTER_DATE="@$OLD" git -C "$CITY" commit -q -m "docs(ga-p5): stage old pending patch"

run_guard() {
    env -i \
        PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
        HOME="$HOME" \
        GC_CITY_PATH="$CITY" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="${TEST_SEEN_FILE:-$WORK/seen.json}" \
        ENGINE_WINDOW_GUARD_ESCALATE_AFTER_S="${TEST_ESCALATE_AFTER_S:-86400}" \
        ENGINE_WINDOW_GUARD_SIZE_THRESHOLD="${TEST_SIZE_THRESHOLD:-100}" \
        ENGINE_WINDOW_GUARD_AGE_THRESHOLD_S="${TEST_AGE_THRESHOLD_S:-2592000}" \
        ENGINE_WINDOW_GUARD_LOCK="${TEST_LOCK_FILE:-$WORK/guard.lock}" \
        NOTIFY_BIN="$FAKE_NOTIFY" \
        NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT" "$@"
}

echo "── 3. functional: composition below both thresholds -- correct counts, zero notify ──"
OUT1=$(TEST_SIZE_THRESHOLD=100 TEST_AGE_THRESHOLD_S=2592000 TEST_SEEN_FILE="$WORK/seen-baseline.json" run_guard --json)
echo "  raw: $OUT1"
TOTAL=$(printf '%s' "$OUT1" | jq -r '.total')
PENDING=$(printf '%s' "$OUT1" | jq -r '.pending')
LANDED=$(printf '%s' "$OUT1" | jq -r '.landed')
UNKNOWN=$(printf '%s' "$OUT1" | jq -r '.unknown')
MARKED=$(printf '%s' "$OUT1" | jq -r '.marked')
BREACHED=$(printf '%s' "$OUT1" | jq -r '.threshold_breached')

[ "$TOTAL" = "5" ] && ok "total=5" || bad "total expected 5, got $TOTAL"
[ "$PENDING" = "2" ] && ok "pending=2 (ga-p1, ga-p5 -- forward clean, reverse dirty)" || bad "pending expected 2, got $PENDING"
[ "$LANDED" = "1" ] && ok "landed=1 (ga-p2 -- forward dirty, reverse clean)" || bad "landed expected 1, got $LANDED"
[ "$UNKNOWN" = "1" ] && ok "unknown=1 (ga-p3 -- neither direction clean)" || bad "unknown expected 1, got $UNKNOWN"
[ "$MARKED" = "1" ] && ok "marked=1 (ga-p4 -- .APLICADO suffix, never git-apply-checked)" || bad "marked expected 1, got $MARKED"
[ "$BREACHED" = "false" ] && ok "threshold_breached=false (both thresholds generous)" || bad "expected threshold_breached=false, got $BREACHED"

NC=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC" = "0" ] && ok "zero notify calls when below threshold" || bad "expected 0 notify calls, got $NC"

echo "── 4. functional: human-readable output lists each patch under its bucket ──"
OUT1H=$(TEST_SIZE_THRESHOLD=100 TEST_AGE_THRESHOLD_S=2592000 TEST_SEEN_FILE="$WORK/seen-baseline2.json" run_guard)
printf '%s' "$OUT1H" | grep -q "ga-p1-pending.patch" && ok "ga-p1 listed in human output" || bad "ga-p1 missing from human output"
printf '%s' "$OUT1H" | grep -q "ga-p2-landed.patch" && ok "ga-p2 listed in human output" || bad "ga-p2 missing from human output"
printf '%s' "$OUT1H" | grep -q "ga-p3-conflict.patch" && ok "ga-p3 listed in human output" || bad "ga-p3 missing from human output"
printf '%s' "$OUT1H" | grep -q "ga-p4-marked.patch.APLICADO-20260101" && ok "ga-p4 listed in human output" || bad "ga-p4 missing from human output"

echo "── 5. functional: SIZE threshold breach (backlog=pending+unknown=3 > 2) fires notify ──"
: > "$NOTIFY_LOG"
OUT2=$(TEST_SIZE_THRESHOLD=2 TEST_AGE_THRESHOLD_S=2592000 TEST_SEEN_FILE="$WORK/seen-size.json" run_guard --json)
B2=$(printf '%s' "$OUT2" | jq -r '.threshold_breached')
[ "$B2" = "true" ] && ok "threshold_breached=true when backlog(3) > SIZE_THRESHOLD(2)" || bad "expected breach, got $B2 ($OUT2)"
NC2=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC2" = "1" ] && ok "exactly 1 notify call on size-threshold breach" || bad "expected 1 notify call, got $NC2"

echo "── 6. functional: dedup -- immediate re-run within escalate window does NOT re-notify ──"
OUT3=$(TEST_SIZE_THRESHOLD=2 TEST_AGE_THRESHOLD_S=2592000 TEST_SEEN_FILE="$WORK/seen-size.json" run_guard --json)
NC3=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC3" = "$NC2" ] && ok "second run within escalate window added zero new notifies ($NC3 total)" || bad "expected $NC2, got $NC3 -- dedup not honored"

echo "── 7. functional: re-fire after escalate window elapses (dedup is a cadence, not permanent silence) ──"
OUT4=$(TEST_SIZE_THRESHOLD=2 TEST_AGE_THRESHOLD_S=2592000 TEST_SEEN_FILE="$WORK/seen-size.json" TEST_ESCALATE_AFTER_S=0 run_guard --json)
NC4=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC4" -gt "$NC3" ] && ok "re-notified after escalate window elapsed ($NC3 -> $NC4)" || bad "did NOT re-notify after window elapsed (stuck at $NC4) -- a real unfixed backlog would go silent forever"

echo "── 8. functional: AGE threshold alone (count below SIZE_THRESHOLD, but ga-p5 is 10d old) fires notify ──"
: > "$NOTIFY_LOG"
OUT5=$(TEST_SIZE_THRESHOLD=100 TEST_AGE_THRESHOLD_S=100000 TEST_SEEN_FILE="$WORK/seen-age.json" run_guard --json)
B5=$(printf '%s' "$OUT5" | jq -r '.threshold_breached')
[ "$B5" = "true" ] && ok "threshold_breached=true on age alone (oldest pending ~10d > ~1.16d threshold, count 2 < 100)" || bad "expected age breach, got $B5 ($OUT5)"
NC5=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC5" = "1" ] && ok "exactly 1 notify call on age-threshold breach" || bad "expected 1 notify call, got $NC5"

echo "── 9. functional: single-instance lock -- a held lock makes the guard exit immediately, zero notify, zero mutation ──"
: > "$NOTIFY_LOG"
LOCK_FOR_TEST="$WORK/held.lock"
(
    exec 8>"$LOCK_FOR_TEST"
    flock 8
    sleep 5
) &
HOLDER_PID=$!
# give the holder a moment to actually acquire the flock before racing it
for _ in 1 2 3 4 5 6 7 8 9 10; do
    flock -n -x 8 2>/dev/null && { echo "  (setup problem: lock was not actually held)"; break; }
    [ -e "$LOCK_FOR_TEST" ] && break
    sleep 0.2
done
OUT6=$(TEST_LOCK_FILE="$LOCK_FOR_TEST" TEST_SIZE_THRESHOLD=1 TEST_AGE_THRESHOLD_S=1 TEST_SEEN_FILE="$WORK/seen-lock.json" run_guard 2>&1) || true
wait "$HOLDER_PID" 2>/dev/null || true
printf '%s' "$OUT6" | grep -qi "outra inst" && ok "locked run prints the 'already running' message and exits" || bad "locked run did not report the lock (got: $OUT6)"
printf '%s' "$OUT6" | grep -q "COMPOSIÇÃO" && bad "locked run still computed a composition -- lock did not actually block work" || ok "locked run computed no composition"
NC6=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC6" = "0" ] && ok "locked run made zero notify calls" || bad "locked run made $NC6 notify call(s) -- should be 0"

echo "── 10. error path: unreadable SRC_TREE -> clean exit 2 with ERRO, not a false empty-composition success ──"
set +e
OUT7=$(TEST_SEEN_FILE="$WORK/seen-badsrc.json" \
    env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$CITY" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$WORK/does-not-exist" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-badsrc.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/badsrc.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT" --json 2>&1)
RC7=$?
set -e
[ "$RC7" = "2" ] && ok "unreadable SRC_TREE exits 2" || bad "expected exit 2, got $RC7"
printf '%s' "$OUT7" | grep -qi "ERRO" && ok "unreadable SRC_TREE prints an ERRO, not silent JSON" || bad "no ERRO message on unreadable SRC_TREE (got: $OUT7)"

echo "── 11. edge case: empty patch dir -> total=0, exit 0, no notify ──"
EMPTY_CITY="$WORK/empty-city"
mkdir -p "$EMPTY_CITY/docs/pending-engine-window" "$EMPTY_CITY/.beads"
git -C "$EMPTY_CITY" init -q
: > "$NOTIFY_LOG"
set +e
OUT8=$(env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$EMPTY_CITY" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-empty.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/empty.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT" --json)
RC8=$?
set -e
[ "$RC8" = "0" ] && ok "empty patch dir exits 0" || bad "expected exit 0, got $RC8"
T8=$(printf '%s' "$OUT8" | jq -r '.total' 2>/dev/null || echo "?")
[ "$T8" = "0" ] && ok "empty patch dir reports total=0" || bad "expected total=0, got $T8 ($OUT8)"
NC8=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC8" = "0" ] && ok "empty patch dir: zero notify calls" || bad "expected 0 notify calls, got $NC8"

echo "── 12. edge case: non-.patch artifact (e.g. a RECIPE.md, or a bare .sh not yet suffix-tagged) is counted as OTHER, never silently dropped from the census ──"
OTHER_CITY="$WORK/other-city"
mkdir -p "$OTHER_CITY/docs/pending-engine-window" "$OTHER_CITY/.beads"
git -C "$OTHER_CITY" init -q
echo "not a patch, just notes" > "$OTHER_CITY/docs/pending-engine-window/ga-p9-notes-RECIPE.md"
: > "$NOTIFY_LOG"
OUT9=$(env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$OTHER_CITY" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-other.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/other.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT" --json)
O9=$(printf '%s' "$OUT9" | jq -r '.other')
T9=$(printf '%s' "$OUT9" | jq -r '.total')
[ "$O9" = "1" ] && ok "non-.patch artifact counted in other=1" || bad "expected other=1, got $O9 ($OUT9)"
[ "$T9" = "0" ] && ok "non-.patch artifact does NOT inflate the patch total (stays 0)" || bad "expected total=0, got $T9 ($OUT9)"
OUT9H=$(env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$OTHER_CITY" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-other2.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/other2.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT")
printf '%s' "$OUT9H" | grep -q "ga-p9-notes-RECIPE.md" && ok "non-.patch artifact named in human-readable output" || bad "ga-p9-notes-RECIPE.md missing from human output"

echo "── 13. regression (gate-feedback ga-tae4f): default relative CITY ('.') still classifies correctly ──"
# The run_guard() helper above always forces GC_CITY_PATH="$CITY" as an
# ABSOLUTE mktemp -d path -- it never exercises the script's own documented
# default (GC_CITY_PATH/GC_CITY unset -> CITY="."), which is a real mode: the
# script's usage line lists no required env vars, and its own .beads-missing
# error message ("Setei GC_CITY_PATH?") anticipates someone running it bare.
# Under the bug, a relative CITY makes every $f in the classification loop
# relative too, and `git -C "$SRC_TREE" apply --check "$f"` resolves that
# relative $f against SRC_TREE's chdir, not CITY -- so every real patch
# misclassifies as ILEGÍVEL. Reuse the exact CITY fixture from section 3
# (known-good composition: pending=2, landed=1, unknown=1, marked=1) but
# invoke with cwd=$CITY and GC_CITY_PATH/GC_CITY genuinely unset (env -i,
# neither var set) so CITY resolves to "." for real inside the script --
# same effective directory, opposite path shape.
: > "$NOTIFY_LOG"
OUT10=$(cd "$CITY" && env -i \
    PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
    HOME="$HOME" \
    ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
    ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-relcity.json" \
    ENGINE_WINDOW_GUARD_LOCK="$WORK/relcity.lock" \
    NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
    bash "$SCRIPT" --json)
echo "  raw: $OUT10"
PENDING10=$(printf '%s' "$OUT10" | jq -r '.pending' 2>/dev/null || echo "?")
LANDED10=$(printf '%s' "$OUT10" | jq -r '.landed' 2>/dev/null || echo "?")
UNKNOWN10=$(printf '%s' "$OUT10" | jq -r '.unknown' 2>/dev/null || echo "?")
MARKED10=$(printf '%s' "$OUT10" | jq -r '.marked' 2>/dev/null || echo "?")
[ "$PENDING10" = "2" ] && ok "relative CITY: pending=2 (not misclassified as ILEGÍVEL)" || bad "relative CITY: pending expected 2, got $PENDING10 -- cross-tree apply --check is resolving \$f wrong again"
[ "$LANDED10" = "1" ] && ok "relative CITY: landed=1" || bad "relative CITY: landed expected 1, got $LANDED10"
[ "$UNKNOWN10" = "1" ] && ok "relative CITY: unknown=1 (only the genuine conflict, not the whole set)" || bad "relative CITY: unknown expected 1, got $UNKNOWN10"
[ "$MARKED10" = "1" ] && ok "relative CITY: marked=1" || bad "relative CITY: marked expected 1, got $MARKED10"

echo "── 14. regression (gate-feedback ga-tae4f secondary): a '%' in a patch filename survives the human-readable listing verbatim ──"
PCT_CITY="$WORK/pct-city"
mkdir -p "$PCT_CITY/docs/pending-engine-window" "$PCT_CITY/.beads"
git -C "$PCT_CITY" init -q
cp "$WORK/pending.patch" "$PCT_CITY/docs/pending-engine-window/ga-p10-100%-done.patch"
: > "$NOTIFY_LOG"
OUT11=$(env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$PCT_CITY" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-pct.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/pct.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT")
printf '%s' "$OUT11" | grep -qF "ga-p10-100%-done.patch" && ok "'%' in filename printed verbatim, not consumed as a format directive" || bad "'%' in filename corrupted the listing (got: $OUT11)"

echo "── 15. static invariant (ga-0ehtp): wrong-location scan never rm/mv's anything ──"
# Detection-only extends to the new check too: it must only ever read
# WRONG_PATCH_DIR, never clear it -- mirroring section 2's mechanical
# enforcement of the same principle for the existing --check invariant.
BAD_MUTATION_LINES=$(grep -nE '\b(rm|mv|rmdir)\b' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [ -z "$BAD_MUTATION_LINES" ]; then
    ok "no rm/mv/rmdir anywhere in the script's code (wrong-location scan is read-only)"
else
    bad "found rm/mv/rmdir call(s) (would violate detection-only):"
    printf '%s\n' "$BAD_MUTATION_LINES"
fi

echo "── 16. functional (ga-0ehtp): stray .patch ONE LEVEL ABOVE CITY -- invisible to the window, must fire a dedicated alarm ──"
# Reproduces the exact 5x-measured incident: an agent whose doctrine-relative
# cwd resolves docs/pending-engine-window/ one level too high stages a patch
# there. WRONG_PATCH_DIR is derived as "one level above CITY" (mirrors
# PATCH_DIR's own derivation), so a dedicated fixture root -- NOT the shared
# $WORK used by sections 3-14 -- keeps this from leaking a stray file into
# every other section's "one level above" (which is $WORK itself).
WRONGLOC_ROOT="$WORK/wrongloc-root"
mkdir -p "$WRONGLOC_ROOT/city/.beads" "$WRONGLOC_ROOT/docs/pending-engine-window"
git -C "$WRONGLOC_ROOT/city" init -q
echo "diff --git a/x.go b/x.go" > "$WRONGLOC_ROOT/docs/pending-engine-window/ga-stray-example.patch"
: > "$NOTIFY_LOG"
OUT12=$(TEST_SEEN_FILE="$WORK/seen-wrongloc.json" \
    env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$WRONGLOC_ROOT/city" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-wrongloc.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/wrongloc.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT" --json)
echo "  raw: $OUT12"
WL12=$(printf '%s' "$OUT12" | jq -r '.wrong_location_count' 2>/dev/null || echo "?")
[ "$WL12" = "1" ] && ok "wrong_location_count=1 when a stray .patch sits one level above CITY" || bad "expected wrong_location_count=1, got $WL12 ($OUT12)"
NC12=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC12" -ge "1" ] 2>/dev/null && ok "stray patch in wrong location fires at least 1 notify ($NC12)" || bad "expected >=1 notify call for wrong-location patch, got $NC12"
grep -q "ga-stray-example.patch" "$NOTIFY_LOG" 2>/dev/null && ok "notify body names the stray file" || bad "notify body does not name the stray file (log: $(cat "$NOTIFY_LOG" 2>/dev/null))"

echo "── 17. functional (ga-0ehtp): wrong-location alarm is dedup'd like the others (immediate re-run adds zero new notifies) ──"
OUT13=$(TEST_SEEN_FILE="$WORK/seen-wrongloc.json" \
    env -i PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" HOME="$HOME" \
        GC_CITY_PATH="$WRONGLOC_ROOT/city" \
        ENGINE_WINDOW_GUARD_SRC_TREE="$SRC" \
        ENGINE_WINDOW_GUARD_SEEN_FILE="$WORK/seen-wrongloc.json" \
        ENGINE_WINDOW_GUARD_LOCK="$WORK/wrongloc.lock" \
        NOTIFY_BIN="$FAKE_NOTIFY" NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$SCRIPT" --json)
NC13=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
[ "$NC13" = "$NC12" ] && ok "second run within escalate window added zero new wrong-location notifies ($NC13 total)" || bad "expected $NC12, got $NC13 -- wrong-location dedup not honored"

echo "── 18. functional (ga-0ehtp): no false positive -- baseline fixture (section 3, nothing staged above it) reports wrong_location_count=0 ──"
WL14=$(printf '%s' "$OUT1" | jq -r '.wrong_location_count' 2>/dev/null || echo "?")
[ "$WL14" = "0" ] && ok "wrong_location_count=0 for the baseline fixture (nothing staged above CITY)" || bad "expected wrong_location_count=0, got $WL14 ($OUT1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
