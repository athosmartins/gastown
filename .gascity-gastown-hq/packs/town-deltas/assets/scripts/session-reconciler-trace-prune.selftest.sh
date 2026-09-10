#!/bin/bash
# session-reconciler-trace-prune.selftest.sh — hermetic test for ga-op9f7.
#
# Builds a fake city under a temp dir (never touches the real
# .gc/runtime/session-reconciler-trace), runs the REAL script against it, and
# checks: retention boundary (keep <=3d, delete >3d),
#
# ISOLATION GOTCHA THIS TEST HIT ONCE (do not remove the explicit overrides
# below): a plain `GC_CITY_PATH="$CITY" bash "$SCRIPT"` is NOT enough to
# isolate this script from a real Gas Town session's own environment — this
# session already has GC_CITY_RUNTIME_DIR exported pointing at the REAL
# city, and the script's own fallback chain (`${GC_CITY_RUNTIME_DIR:-$CITY/
# .gc/runtime}`) prefers that already-set var over the fake $CITY, so the
# first version of this test actually pruned the real trace tree instead of
# the temp one (harmless that time only by luck — the affected real
# directories happened to already be empty skeletons). Always pin
# SESSION_RECONCILER_TRACE_ROOT directly (the script's most-specific
# override) AND unset GC_CITY_RUNTIME_DIR/GC_CITY for the test invocation —
# never rely on GC_CITY_PATH alone to isolate a script that has more than
# one env fallback in its chain.
# current-day is never touched even though its age is 0, root files/dirs
# (head.json, arms.json, quarantine/, trace.lock) survive untouched, a
# non-date-shaped decoy directory is left alone rather than guessed at,
# emptied YYYY/MM skeletons get swept, and the whole thing is idempotent
# across a second run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/session-reconciler-trace-prune.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

CITY="$WORKDIR/city"
TRACE_ROOT="$CITY/.gc/runtime/session-reconciler-trace"
SEGMENTS="$TRACE_ROOT/segments"

TODAY=$(date -u +%Y-%m-%d)
D1=$(date -u -v-1d +%Y-%m-%d)
D2=$(date -u -v-2d +%Y-%m-%d)
D3=$(date -u -v-3d +%Y-%m-%d)
D4=$(date -u -v-4d +%Y-%m-%d)
D10=$(date -u -v-10d +%Y-%m-%d)
ANCIENT="2020-01-15"   # fixed, always >3d old regardless of when this runs

mk_day() {
  # mk_day <YYYY-MM-DD> — creates segments/YYYY/MM/DD/seg-00001.jsonl
  local d="$1" y m dd dir
  y="${d%%-*}"; m="${d#*-}"; m="${m%%-*}"; dd="${d##*-}"
  dir="$SEGMENTS/$y/$m/$dd"
  mkdir -p "$dir"
  echo '{"seq":1}' > "$dir/seg-00001.jsonl"
}

mkdir -p "$TRACE_ROOT/quarantine"
echo '{"head":true}' > "$TRACE_ROOT/head.json"
echo '{"arms":true}' > "$TRACE_ROOT/arms.json"
: > "$TRACE_ROOT/trace.lock"
echo 'quarantined' > "$TRACE_ROOT/quarantine/bad-segment.jsonl.123"

mk_day "$TODAY"
mk_day "$D1"
mk_day "$D2"
mk_day "$D3"
mk_day "$D4"
mk_day "$D10"
mk_day "$ANCIENT"

# Decoy: not a real date shape — must be left alone, never guessed at.
mkdir -p "$SEGMENTS/notayear/01/01"

# Loose file directly under segments/ — outside the mindepth3/maxdepth3
# day-dir walk entirely; must survive.
echo 'stray' > "$SEGMENTS/stray.txt"

HEAD_BEFORE=$(cat "$TRACE_ROOT/head.json")
ARMS_BEFORE=$(cat "$TRACE_ROOT/arms.json")
QUARANTINE_BEFORE=$(cat "$TRACE_ROOT/quarantine/bad-segment.jsonl.123")

echo "=== session-reconciler-trace-prune.selftest.sh ==="
echo "today=$TODAY d1=$D1 d2=$D2 d3=$D3 d4=$D4 d10=$D10 ancient=$ANCIENT"

PRUNE_LOG="$WORKDIR/prune.log"
OUT1=$(GC_CITY_PATH="$CITY" GC_CITY_RUNTIME_DIR="" GC_CITY="" \
       SESSION_RECONCILER_TRACE_ROOT="$TRACE_ROOT" \
       SESSION_RECONCILER_TRACE_PRUNE_LOG="$PRUNE_LOG" \
       bash "$SCRIPT" 2>&1)
RC1=$?
echo "--- run 1 output ---"; echo "$OUT1"

[ "$RC1" -eq 0 ] && ok "run 1 exits 0" || bad "run 1 exited $RC1"

# ── retention boundary ─────────────────────────────────────────────────────
[ -f "$SEGMENTS/${TODAY%%-*}/$(echo "$TODAY" | cut -d- -f2)/$(echo "$TODAY" | cut -d- -f3)/seg-00001.jsonl" ] \
  && ok "current day ($TODAY) kept" || bad "current day ($TODAY) was removed"

check_kept() {
  local d="$1" y m dd
  y="${d%%-*}"; m="${d#*-}"; m="${m%%-*}"; dd="${d##*-}"
  [ -f "$SEGMENTS/$y/$m/$dd/seg-00001.jsonl" ] && ok "day $d (<=3d old) kept" || bad "day $d (<=3d old) was WRONGLY removed"
}
check_removed() {
  local d="$1" y m dd
  y="${d%%-*}"; m="${d#*-}"; m="${m%%-*}"; dd="${d##*-}"
  [ ! -e "$SEGMENTS/$y/$m/$dd" ] && ok "day $d (>3d old) removed" || bad "day $d (>3d old) was WRONGLY kept"
}

check_kept "$D1"
check_kept "$D2"
check_kept "$D3"
check_removed "$D4"
check_removed "$D10"
check_removed "$ANCIENT"

# ── ancient day's YYYY/MM skeleton must be swept, not just the day itself ──
[ ! -d "$SEGMENTS/2020" ] && ok "ancient year skeleton (2020/) swept" || bad "ancient year skeleton (2020/) left behind"

# ── decoy + stray file: left alone, not guessed at ─────────────────────────
[ -d "$SEGMENTS/notayear/01/01" ] && ok "non-date decoy dir left untouched" || bad "non-date decoy dir was removed — should only ever touch real YYYY/MM/DD"
[ -f "$SEGMENTS/stray.txt" ] && ok "stray file directly under segments/ left untouched" || bad "stray file under segments/ was removed"

# ── root files/dirs preserved byte-for-byte ────────────────────────────────
[ "$(cat "$TRACE_ROOT/head.json" 2>/dev/null)" = "$HEAD_BEFORE" ] && ok "head.json untouched" || bad "head.json was modified/removed"
[ "$(cat "$TRACE_ROOT/arms.json" 2>/dev/null)" = "$ARMS_BEFORE" ] && ok "arms.json untouched" || bad "arms.json was modified/removed"
[ -f "$TRACE_ROOT/trace.lock" ] && ok "trace.lock untouched" || bad "trace.lock was removed"
[ "$(cat "$TRACE_ROOT/quarantine/bad-segment.jsonl.123" 2>/dev/null)" = "$QUARANTINE_BEFORE" ] && ok "quarantine/ contents untouched" || bad "quarantine/ contents were modified/removed"

# ── summary line reports something when there was work to do ──────────────
echo "$OUT1" | grep -q "removed_dirs=" && ok "run 1 prints a removed_dirs summary line" || bad "run 1 printed no summary line despite deletions"

# ── idempotency: second run over the already-pruned tree must not error ───
OUT2=$(GC_CITY_PATH="$CITY" GC_CITY_RUNTIME_DIR="" GC_CITY="" \
       SESSION_RECONCILER_TRACE_ROOT="$TRACE_ROOT" \
       SESSION_RECONCILER_TRACE_PRUNE_LOG="$PRUNE_LOG" \
       bash "$SCRIPT" 2>&1)
RC2=$?
echo "--- run 2 output ---"; echo "$OUT2"
[ "$RC2" -eq 0 ] && ok "run 2 (idempotent re-run) exits 0" || bad "run 2 exited $RC2"
check_kept "$D1"
check_kept "$D2"
check_kept "$D3"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
