#!/usr/bin/env bash
# story-delivery-daemon-refresh-idle-advance.test.sh — regression test for
# ga-thoo16 (extracts the real "Step 0-pre" block from story-delivery.sh, no
# duplication — same technique as story-delivery-daemon-refresh-staleness-alarm.test.sh).
#
# THE BUG (ga-thoo16): the daemon-refresh baseline marker ($RIG.sha) and its
# per-daemon file ($RIG.perdaemon) only ever moved from inside Step 5b, which
# runs for a STORY awaiting delivery. A delta that no daemon or scheduled job
# can load (tests/**, docs/**, *.md) that arrives any other way — a task/bug
# closed by the Step 1b reconciler, the rig's own deploy.sh resetting the
# checkout before a scheduled run — never reached Step 5b, so the marker stayed
# put, the Step 0a staleness alarm (ga-gjum0y) fired, and every later helper
# run kept a window that only got wider.
#
# THE FIX: a new sweep-level step ("Step 0-pre", before the Step 0a alarm so an
# inert delta never alarms) moves the marker — and every unflagged per-daemon
# pin whose own window is inert too — to the checkout's HEAD when
# marker..HEAD touches ONLY tests/**, docs/** or *.md, and logs
# "advanced: delta sem daemon afetado". Anything else leaves everything alone:
# a code file, a scheduled-job file (plist/script), a rename out of code, a git
# failure, a marker that is not an ancestor, an unknown rig. Unknown never
# counts as inert.
#
# Since ga-xx7qt7a a delta that holds CODE has a second way to move the marker (the rig-wide
# scheduled-job proof, dri_sched_proof; see story-delivery-daemon-refresh-scheduled-advance.test.sh).
# The stub below answers only `runtime_dir`, so for that proof `extra_runtime_roots` is unreadable
# and it holds — which is why the code cases here (T2, T4, T12) still read as holds.
#
# T1: docs-only delta → marker moves to HEAD, log says "advanced: delta sem
#     daemon afetado", an unflagged pin on the marker moves, a 'stuck' pin, a
#     pin whose own window has code, and a pin with no sha stay byte-for-byte.
# T2: a delta that changes runner.py (the PS window the bead measured) → no
#     move; the reason is logged ONCE per (marker, HEAD), not every sweep.
# T3: tests/** + docs/** + *.md delta → moves.
# T4: docs + a scheduled-job file (scripts/new_job.sh, plist template) → no move.
# T5: DRY_RUN=1 → nothing written, the log says it WOULD.
# T6: marker not an ancestor of HEAD (reset/rebase) → no move, even when the
#     two differ in docs only (so it is the ancestor check that refuses).
# T7: marker == HEAD → content unchanged, mtime refreshed (so Step 0a does not
#     call a fully-current marker "frozen"); DRY_RUN=1 leaves the mtime alone.
# T8: marker content is not a commit → no move, no crash.
# T9: rig unknown to the runbook → no move, no crash.
# T10: runtime_dir is not a git work tree → no move, no crash.
# T11: git diff fails → no move (unknown is not inert).
# T12: code renamed into docs/ (old path was code) → no move.
# T13: two rigs in one sweep are judged independently.
# T14: no baseline dir at all → clean no-op.
# T15: the pattern list equals daemon-refresh.sh's DEFAULT_NO_RESTART_PATTERNS.

# No `pipefail` at file level (ga-uel7sb): see story-delivery-daemon-refresh-staleness-alarm.test.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="${DELIVERY_UNDER_TEST:-$SCRIPT_DIR/../story-delivery.sh}"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

BLOCK="$(sed -n '/# ── Step 0-pre: daemon-refresh baseline/,/# ── Step 0a: daemon-refresh baseline staleness alarm/p' "$DELIVERY" | sed '$d')"
if [ -z "$BLOCK" ]; then
  nok "Step 0-pre block (ga-thoo16) exists in $(basename "$DELIVERY")" "no '# ── Step 0-pre: daemon-refresh baseline' header found"
  echo ""
  echo "story-delivery baseline idle-advance tests: $PASS passed, $FAIL failed"
  exit 1
fi

G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fixture repo: a linear history C0..C4 plus a side branch commit S.
#   C0 base: runner.py, lib/util.py, README.md, docs/a.md, tests/test_a.py
#   C1 code: runner.py edited
#   C2 docs: docs/b.md added, CLAUDE.md added
#   C3 tests+docs+md: tests/test_b.py, docs/a.md edited, README.md edited
#   C4 docs + scheduled-job files: docs/c.md, scripts/new_job.sh, templates/com.x.job.plist
#   C5 code moved into docs/ (rename): runner.py -> docs/runner.py.md
#   S  off C0 (adds lib/side.py), S2 off C2 (adds docs/side.md): other lines of history
mk_repo() {
  local d="$1"
  mkdir -p "$d"; ( cd "$d" || exit 1
    G init -q -b main .
    mkdir -p docs tests lib scripts templates
    echo "print(1)" > runner.py; echo "x=1" > lib/util.py; echo "# r" > README.md
    echo "a" > docs/a.md; echo "t" > tests/test_a.py
    G add -A; G commit -q -m C0; G tag C0
    echo "print(2)" > runner.py; G add -A; G commit -q -m C1; G tag C1
    echo "b" > docs/b.md; echo "# c" > CLAUDE.md; G add -A; G commit -q -m C2; G tag C2
    echo "t2" > tests/test_b.py; echo "a2" >> docs/a.md; echo "r2" >> README.md
    G add -A; G commit -q -m C3; G tag C3
    echo "c" > docs/c.md; echo "#!/bin/sh" > scripts/new_job.sh; echo "<plist/>" > templates/com.x.job.plist
    G add -A; G commit -q -m C4; G tag C4
    G mv runner.py docs/runner.py.md; G commit -q -m C5; G tag C5
    G checkout -q -b side C0; echo "side" > lib/side.py; G add -A; G commit -q -m S; G tag S
    # S2: a docs-only commit on ANOTHER line of history (off C2). S2..C3 changes only
    # docs/tests/md, so nothing but the ancestor check can refuse it.
    G checkout -q -b side2 C2; echo "side" > docs/side.md; G add -A; G commit -q -m S2; G tag S2
    G checkout -q main
  )
}

RT="$TMP_ROOT/runtime"; mk_repo "$RT"
sha_of() { G -C "$RT" rev-parse "$1"; }
C0="$(sha_of C0)"; C1="$(sha_of C1)"; C2="$(sha_of C2)"; C3="$(sha_of C3)"; C4="$(sha_of C4)"; C5="$(sha_of C5)"; S="$(sha_of S)"; S2="$(sha_of S2)"

# new_city → sets CITY, BASE (baseline dir), LOG_FILE; resets state files.
new_city() {
  CITY="$(mktemp -d "$TMP_ROOT/city.XXXXXX")"
  BASE="$CITY/.gc/runtime/daemon-refresh-baseline"
  mkdir -p "$BASE"
  LOG_FILE="$CITY/log.log"; : > "$LOG_FILE"
}

# run_block <head_ref> [<dry_run>] — checks out head_ref in $RT, runs the real
# block under the production shell options (set -euo pipefail). Rigs known to
# the stub runbook: property_scrapers → $RT, plus whatever RIG_MAP lists.
run_block() {
  local head_ref="$1" dry="${2:-0}"
  G -C "$RT" checkout -q "$head_ref" 2>/dev/null || G -C "$RT" checkout -q --detach "$head_ref"
  (
    set -euo pipefail
    GC_CITY="$CITY"; DRY_RUN="$dry"
    log()  { echo "$*" >> "$LOG_FILE"; }
    warn() { echo "WARN: $*" >> "$LOG_FILE"; }
    err()  { echo "ERR: $*" >> "$LOG_FILE"; }
    get_runbook_field() {
      local rig="$1" field="$2" pair
      [ "$field" = "runtime_dir" ] || return 1
      for pair in ${RIG_MAP:-property_scrapers=$RT}; do
        [ "${pair%%=*}" = "$rig" ] && { echo "${pair#*=}"; return 0; }
      done
      return 1
    }
    for _t in _once; do eval "$BLOCK"; done
  ) >"$CITY/block.out" 2>&1
  BLOCK_RC=$?
  LOG_CONTENT="$(cat "$LOG_FILE" 2>/dev/null || true)"
}

marker() { tr -d '[:space:]' < "$BASE/$1.sha" 2>/dev/null || true; }
backdate() { touch -t "$(date -v-"$2"d +%Y%m%d%H%M.%S)" "$1"; }

PD_SEED() {
  printf '%s\n' \
    "com.scrapers.clean $C1" \
    "com.scrapers.frozen $C1 stuck" \
    "com.scrapers.oldpin $C0" \
    "com.scrapers.nosha" > "$BASE/property_scrapers.perdaemon"
}

# ── T1: docs-only delta (C1 → C2) ────────────────────────────────────────────
new_city; printf '%s\n' "$C1" > "$BASE/property_scrapers.sha"; PD_SEED
PD_BEFORE="$(cat "$BASE/property_scrapers.perdaemon")"
run_block C2
[ "$BLOCK_RC" -eq 0 ] && ok "T1 block exits 0 under set -euo pipefail" || nok "T1 rc" "rc=$BLOCK_RC out=$(cat "$CITY/block.out")"
[ "$(marker property_scrapers)" = "$C2" ] \
  && ok "T1 docs-only delta: marker advanced to HEAD" \
  || nok "T1 marker" "got '$(marker property_scrapers)' want '$C2'"
echo "$LOG_CONTENT" | grep -F "advanced: delta sem daemon afetado" >/dev/null \
  && ok "T1 log line 'advanced: delta sem daemon afetado'" \
  || nok "T1 log line" "LOG=[$LOG_CONTENT]"
PD_AFTER="$(cat "$BASE/property_scrapers.perdaemon")"
EXPECT_PD="$(printf '%s\n' "com.scrapers.clean $C2" "com.scrapers.frozen $C1 stuck" "com.scrapers.oldpin $C0" "com.scrapers.nosha")"
[ "$PD_AFTER" = "$EXPECT_PD" ] \
  && ok "T1 per-daemon: unflagged pin moved; stuck / code-window / no-sha lines untouched" \
  || nok "T1 per-daemon" "got:
$PD_AFTER
want:
$EXPECT_PD"

# ── T2: code in the delta (C0 → C2 includes runner.py) ───────────────────────
new_city; printf '%s\n' "$C0" > "$BASE/property_scrapers.sha"; PD_SEED
PD_BEFORE="$(cat "$BASE/property_scrapers.perdaemon")"
run_block C2
[ "$(marker property_scrapers)" = "$C0" ] \
  && ok "T2 delta with runner.py: marker NOT advanced" \
  || nok "T2 marker moved" "got '$(marker property_scrapers)'"
[ "$(cat "$BASE/property_scrapers.perdaemon")" = "$PD_BEFORE" ] \
  && ok "T2 per-daemon file untouched" || nok "T2 per-daemon changed"
echo "$LOG_CONTENT" | grep -F "runner.py" >/dev/null \
  && ok "T2 the reason names the file that blocks (runner.py)" \
  || nok "T2 reason" "LOG=[$LOG_CONTENT]"
echo "$LOG_CONTENT" | grep -F "advanced: delta sem daemon afetado" >/dev/null \
  && nok "T2 must not claim an advance" "LOG=[$LOG_CONTENT]" \
  || ok "T2 no advance claimed"
N1="$(echo "$LOG_CONTENT" | grep -c "NOT advanced")"
run_block C2
N2="$(grep -c "NOT advanced" "$LOG_FILE")"
[ "$N1" = "1" ] && [ "$N2" = "1" ] \
  && ok "T2 reason logged once per (marker, HEAD), not every sweep" \
  || nok "T2 dedup" "after 1st run: $N1, after 2nd run: $N2"

# ── T3: tests + docs + *.md delta (C2 → C3) ──────────────────────────────────
new_city; printf '%s\n' "$C2" > "$BASE/property_scrapers.sha"
run_block C3
[ "$(marker property_scrapers)" = "$C3" ] \
  && ok "T3 tests/**+docs/**+*.md delta: advanced" \
  || nok "T3 marker" "got '$(marker property_scrapers)' want '$C3'"

# ── T4: docs + scheduled-job files (C3 → C4) ─────────────────────────────────
new_city; printf '%s\n' "$C3" > "$BASE/property_scrapers.sha"
run_block C4
[ "$(marker property_scrapers)" = "$C3" ] \
  && ok "T4 delta touching scripts/new_job.sh + a plist template: NOT advanced" \
  || nok "T4 marker moved" "got '$(marker property_scrapers)'"
echo "$LOG_CONTENT" | grep -E "scripts/new_job.sh|templates/com.x.job.plist" >/dev/null \
  && ok "T4 reason names a scheduled-job file" || nok "T4 reason" "LOG=[$LOG_CONTENT]"

# ── T5: DRY_RUN=1 ────────────────────────────────────────────────────────────
new_city; printf '%s\n' "$C1" > "$BASE/property_scrapers.sha"; PD_SEED
PD_BEFORE="$(cat "$BASE/property_scrapers.perdaemon")"
run_block C2 1
[ "$(marker property_scrapers)" = "$C1" ] && [ "$(cat "$BASE/property_scrapers.perdaemon")" = "$PD_BEFORE" ] \
  && ok "T5 DRY_RUN=1: nothing written" || nok "T5 wrote under DRY_RUN"
echo "$LOG_CONTENT" | grep -i "would" | grep -F "delta sem daemon afetado" >/dev/null \
  && ok "T5 DRY_RUN=1: log says it WOULD advance" || nok "T5 log" "LOG=[$LOG_CONTENT]"

# ── T6: marker not an ancestor of HEAD ───────────────────────────────────────
new_city; printf '%s\n' "$S" > "$BASE/property_scrapers.sha"
run_block C2
[ "$(marker property_scrapers)" = "$S" ] \
  && ok "T6 marker on another line of history (code differs): NOT advanced" \
  || nok "T6 marker moved" "got '$(marker property_scrapers)'"
# the discriminating case: S2 differs from C3 in docs/tests/md ONLY, so the file
# check alone would call it inert — only "marker must be an ancestor" refuses it.
new_city; printf '%s\n' "$S2" > "$BASE/property_scrapers.sha"
run_block C3
[ "$(marker property_scrapers)" = "$S2" ] \
  && ok "T6 marker on another line of history (docs-only difference): NOT advanced — the ancestor check, not the file check, refuses it" \
  || nok "T6 ancestor check" "got '$(marker property_scrapers)'"
echo "$LOG_CONTENT" | grep -F "not an ancestor" >/dev/null \
  && ok "T6 the reason says so" || nok "T6 reason" "LOG=[$LOG_CONTENT]"

# ── T7: marker == HEAD → mtime refreshed (not content) ───────────────────────
new_city; printf '%s\n' "$C2" > "$BASE/property_scrapers.sha"; backdate "$BASE/property_scrapers.sha" 5
run_block C2
AGE="$(( ( $(date +%s) - $(stat -f %m "$BASE/property_scrapers.sha") ) / 86400 ))"
[ "$(marker property_scrapers)" = "$C2" ] && [ "$AGE" -lt 1 ] \
  && ok "T7 marker == HEAD: content kept, mtime refreshed (age ${AGE}d)" \
  || nok "T7 current marker" "marker=$(marker property_scrapers) age=${AGE}d"
new_city; printf '%s\n' "$C2" > "$BASE/property_scrapers.sha"; backdate "$BASE/property_scrapers.sha" 5
run_block C2 1
AGE="$(( ( $(date +%s) - $(stat -f %m "$BASE/property_scrapers.sha") ) / 86400 ))"
[ "$AGE" -ge 4 ] && ok "T7 DRY_RUN=1 leaves the mtime alone" || nok "T7 dry-run touched" "age=${AGE}d"

# ── T8: marker content is not a commit ───────────────────────────────────────
new_city; printf '%s\n' "not-a-commit" > "$BASE/property_scrapers.sha"
run_block C2
[ "$BLOCK_RC" -eq 0 ] && [ "$(marker property_scrapers)" = "not-a-commit" ] \
  && ok "T8 unknown marker: left alone, no crash" || nok "T8" "rc=$BLOCK_RC marker=$(marker property_scrapers)"
: > "$BASE/property_scrapers.sha"
run_block C2
[ "$BLOCK_RC" -eq 0 ] && [ -z "$(marker property_scrapers)" ] \
  && ok "T8 empty marker: left alone, no crash" || nok "T8 empty" "rc=$BLOCK_RC marker=$(marker property_scrapers)"

# ── T9: rig unknown to the runbook ───────────────────────────────────────────
new_city; printf '%s\n' "$C1" > "$BASE/retired_rig.sha"
run_block C2
[ "$BLOCK_RC" -eq 0 ] && [ "$(marker retired_rig)" = "$C1" ] \
  && ok "T9 rig with no runbook entry: left alone, no crash" || nok "T9" "rc=$BLOCK_RC marker=$(marker retired_rig)"

# ── T10: runtime_dir is not a git work tree ──────────────────────────────────
new_city; printf '%s\n' "$C1" > "$BASE/property_scrapers.sha"; mkdir -p "$TMP_ROOT/not-git"
RIG_MAP="property_scrapers=$TMP_ROOT/not-git" run_block C2
[ "$BLOCK_RC" -eq 0 ] && [ "$(marker property_scrapers)" = "$C1" ] \
  && ok "T10 runtime_dir not a repo: left alone, no crash" || nok "T10" "rc=$BLOCK_RC"

# ── T11: git diff fails → unknown is not inert ───────────────────────────────
new_city; printf '%s\n' "$C1" > "$BASE/property_scrapers.sha"
G -C "$RT" checkout -q C2
(
  set -euo pipefail
  GC_CITY="$CITY"; DRY_RUN=0
  log()  { echo "$*" >> "$LOG_FILE"; }; warn() { echo "WARN: $*" >> "$LOG_FILE"; }; err() { echo "ERR: $*" >> "$LOG_FILE"; }
  get_runbook_field() { [ "$2" = runtime_dir ] && echo "$RT"; }
  git() { local a; for a in "$@"; do [ "$a" = diff ] && return 1; done; command git "$@"; }
  for _t in _once; do eval "$BLOCK"; done
) >"$CITY/block.out" 2>&1
BLOCK_RC=$?
[ "$BLOCK_RC" -eq 0 ] && [ "$(marker property_scrapers)" = "$C1" ] \
  && ok "T11 git diff failing: NOT advanced (unknown never counts as inert)" \
  || nok "T11" "rc=$BLOCK_RC marker=$(marker property_scrapers)"

# ── T12: code renamed into docs/ ─────────────────────────────────────────────
new_city; printf '%s\n' "$C4" > "$BASE/property_scrapers.sha"
run_block C5
[ "$(marker property_scrapers)" = "$C4" ] \
  && ok "T12 runner.py renamed to docs/runner.py.md: NOT advanced (old path was code)" \
  || nok "T12 marker moved" "got '$(marker property_scrapers)'"

# ── T13: two rigs, judged independently ──────────────────────────────────────
RT2="$TMP_ROOT/runtime2"; mk_repo "$RT2"
R2C0="$(G -C "$RT2" rev-parse C0)"; R2C2="$(G -C "$RT2" rev-parse C2)"
new_city
printf '%s\n' "$C1" > "$BASE/property_scrapers.sha"     # C1→C2 inert → moves
printf '%s\n' "$R2C0" > "$BASE/whatsapp_automation.sha" # C0→C2 has runner.py → stays
G -C "$RT2" checkout -q C2
RIG_MAP="property_scrapers=$RT whatsapp_automation=$RT2" run_block C2
[ "$(marker property_scrapers)" = "$C2" ] && [ "$(marker whatsapp_automation)" = "$R2C0" ] \
  && ok "T13 one rig advances, the other (code in its delta) does not" \
  || nok "T13" "ps=$(marker property_scrapers) wa=$(marker whatsapp_automation)"

# ── T14: no baseline dir at all ──────────────────────────────────────────────
new_city; rmdir "$BASE"
run_block C2
[ "$BLOCK_RC" -eq 0 ] && ok "T14 no baseline dir: clean no-op" || nok "T14" "rc=$BLOCK_RC out=$(cat "$CITY/block.out")"

# ── T15: pattern list cannot drift from the helper's ─────────────────────────
MINE="$(printf '%s\n' "$BLOCK" | sed -n 's/^DRI_NO_DAEMON_PATTERNS="\(.*\)"/\1/p' | head -1)"
THEIRS="$(sed -n 's/^DEFAULT_NO_RESTART_PATTERNS="\(.*\)"/\1/p' "$HELPER" | head -1)"
[ -n "$MINE" ] && [ "$MINE" = "$THEIRS" ] \
  && ok "T15 Step 0-pre patterns == daemon-refresh.sh DEFAULT_NO_RESTART_PATTERNS ('$MINE')" \
  || nok "T15 pattern drift" "step0-pre='$MINE' helper='$THEIRS'"

echo ""
echo "story-delivery baseline idle-advance tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
