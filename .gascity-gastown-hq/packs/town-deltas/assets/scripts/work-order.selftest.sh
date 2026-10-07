#!/usr/bin/env bash
# work-order.selftest.sh — ga-9t9acg.1 (programa ga-9t9acg, "ordem única").
#
# Proves the ordering library (work-order.sh), its Python entry point (scripts/work_order.py) and the
# registry lint (work-order.registry.tsv). Needs only bash, jq, python3. Exit 0 iff every check holds.
#   (a)-(h)  the rule, the three age rules and the three-state contract, on inline fixtures;
#   (i)      python == bash on the same fixtures;
#   (j)      MUTATION CONTROLS: textual mutants of the library (priority-only, bug-before-feature,
#            newest-first, "today's behaviour", ...) and of the lint must each make THIS file fail;
#   (k)      sourcing twice is a no-op and survives `set -euo pipefail`, under /bin/bash 3.2 and PATH bash;
#   (R)      the registry lint on the real tree and on synthetic trees.
# Env: WO_LIB_UNDER_TEST / WO_PY_UNDER_TEST / WO_REGISTRY_UNDER_TEST point the checks at another copy
# (the mutation controls use them); WO_SKIP_MUTATION=1 skips (j) and (R) (the library mutants' own runs);
# WO_ONLY=R runs only the registry lint (the lint mutants' own runs). Temp files go under $TMPDIR and are
# removed with safe-clean when it approves the path (never rm -rf).
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SELF="$SELF_DIR/$(basename "$SELF")"
ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"                       # .gascity-gastown-hq
LIB="${WO_LIB_UNDER_TEST:-$SELF_DIR/work-order.sh}"
PY="${WO_PY_UNDER_TEST:-$ROOT/scripts/work_order.py}"
REGISTRY="${WO_REGISTRY_UNDER_TEST:-$SELF_DIR/work-order.registry.tsv}"
export WORK_ORDER_LIB="$LIB"                                      # work_order.py runs the library under test

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); if [ "${WO_FAILFAST:-0}" = "1" ]; then echo "RESULT: FAIL (fail-fast, $PASS passed first)"; exit 1; fi; }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
want() { [ -z "${WO_ONLY:-}" ] || [ "$WO_ONLY" = "$1" ]; }
finish() { echo; if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS ($PASS passed, $SKIP skipped)"; else echo "RESULT: FAIL ($FAIL failed, $PASS passed, $SKIP skipped)"; fi; [ "$FAIL" -eq 0 ]; exit; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; echo "RESULT: FAIL"; exit 1; }
if [ ! -r "$LIB" ]; then
  echo "FATAL: the ordering library is missing: $LIB"
  echo "RESULT: FAIL (no work-order.sh — this is the red state before ga-9t9acg.1)"
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wo-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
cleanup() { if command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$TMP" >/dev/null 2>&1; then safe-clean "$TMP" >/dev/null 2>&1; fi; }
trap cleanup EXIT

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# B id priority type created [updated] [labels-json] — one bead object. priority is JSON text (0, null,
# '"2"', 1.5) or the word absent; type "-" omits issue_type; created/updated "-" omit the field.
B() {
  jq -cn --arg id "$1" --arg p "$2" --arg t "$3" --arg c "$4" --arg u "${5:-$4}" --argjson l "${6:-[]}" '
    {id: $id, labels: $l}
    + (if $p == "absent" then {} else {priority: ($p | fromjson)} end)
    + (if $t == "-" then {} else {issue_type: $t} end)
    + (if $c == "-" then {} else {created_at: $c} end)
    + (if $u == "-" then {} else {updated_at: $u} end)'
}
arr() { jq -cs '.'; }

# run_sort <age> <json-file>  -> SORT_OUT SORT_ERR SORT_RC (stdout and stderr kept apart)
run_sort() {
  SORT_OUT="$(work_order_sort --age "$1" < "$2" 2>"$TMP/err")"; SORT_RC=$?
  SORT_ERR="$(cat "$TMP/err")"
}
sids() { printf '%s' "$SORT_OUT" | jq -r 'map(.id) | join(",")' 2>/dev/null; }
warns() { printf '%s\n' "$SORT_ERR" | sed -n 's/^work-order WARN: //p' | sort | tr '\n' ';'; }
expect_order() { # <label> <age> <file> <expected csv>
  run_sort "$2" "$3"
  if [ "$SORT_RC" -ne 0 ]; then bad "$1: work_order_sort exited $SORT_RC: $SORT_ERR"; return; fi
  eq "$1" "$(sids)" "$4"
}

# source the library under test (the same way a dispatcher does)
# shellcheck disable=SC1090
source "$LIB"

# the 10-bead fixture of the design doc (§4), hand-checked: created j,d,c,a,e,b,i,h,g,f / reclaim d,j,c,a,e,b,i,h,g,f
F10="$TMP/f10.json"
{
  B a-p0-bug-old 0 bug 2026-09-01T10:00:00Z
  B b-p1-feat-old 1 feature 2026-08-01T10:00:00Z
  B c-p0-feat-new 0 feature 2026-10-05T18:41:00Z
  B d-p0-feat-old 0 feature 2026-09-20T09:00:00.123Z
  B e-p0-task-new 0 task 2026-10-05T20:00:00+00:00
  B f-nullprio-feat null feature 2026-07-01T10:00:00Z
  B g-p2-notype 2 - 2026-07-02T10:00:00Z
  B h-p2-bug-badage 2 bug garbage 2026-07-03T10:00:00Z
  B i-p2-bug-ok 2 bug 2026-07-04T10:00:00Z
  B j-p0-feat-reclaimed 0 feature 2026-06-01T10:00:00Z 2026-10-05T10:00:00Z '["pilot:reclaim-count:2"]'
} | arr > "$F10"
F10_CREATED="j-p0-feat-reclaimed,d-p0-feat-old,c-p0-feat-new,a-p0-bug-old,e-p0-task-new,b-p1-feat-old,i-p2-bug-ok,h-p2-bug-badage,g-p2-notype,f-nullprio-feat"
F10_RECLAIM="d-p0-feat-old,j-p0-feat-reclaimed,c-p0-feat-new,a-p0-bug-old,e-p0-task-new,b-p1-feat-old,i-p2-bug-ok,h-p2-bug-badage,g-p2-notype,f-nullprio-feat"
F10_WARNS="f-nullprio-feat: prio?;g-p2-notype: type?;h-p2-bug-badage: age?;"

# ── (a) the rule: priority > type > age ─────────────────────────────────────────────────────────
if want a; then
echo "== (a) priority > type (feature first) > age (oldest first)"
FA="$TMP/ladder.json"
{
  B p4-chore 4 chore 2026-08-01T00:00:00Z
  B p1-feat 1 feature 2026-10-05T23:00:00Z
  B p0-task-new 0 task 2026-10-05T12:00:00Z
  B p2-bug 2 bug 2026-08-03T00:00:00Z
  B p0-feat-new 0 feature 2026-10-04T08:00:00Z
  B p3-task 3 task 2026-08-02T00:00:00Z
  B p2-feat 2 feature 2026-10-05T00:00:00Z
  B p0-bug-old 0 bug 2026-08-01T08:00:00Z
  B p1-bug 1 bug 2026-08-04T00:00:00Z
  B p0-feat-old 0 feature 2026-09-01T08:00:00Z
} | arr > "$FA"
expect_order "P0 feat old < P0 feat new < P0 bug old < P0 task new < P1 feat < P1 bug < P2 feat < P2 bug < P3 < P4" created "$FA" \
  "p0-feat-old,p0-feat-new,p0-bug-old,p0-task-new,p1-feat,p1-bug,p2-feat,p2-bug,p3-task,p4-chore"
eq "an ordered, readable fixture raises no WARN" "$(warns)" ""
FS="$TMP/story.json"
{ B p0-bug 0 bug 2026-08-01T00:00:00Z; B p0-feat 0 feature 2026-10-01T00:00:00Z; B p0-story 0 story 2026-09-15T00:00:00Z; } | arr > "$FS"
expect_order "story is an alias of feature (never hidden behind a P0 bug)" created "$FS" "p0-story,p0-feat,p0-bug"
SORT_OUT="$(WORK_ORDER_FEATURE_TYPES="feature" work_order_sort < "$FS" 2>/dev/null)"
eq "WORK_ORDER_FEATURE_TYPES is read (feature only: story falls to the other types)" "$(sids)" "p0-feat,p0-bug,p0-story"
expect_order "the 10-bead fixture, created mode (hand-checked)" created "$F10" "$F10_CREATED"
eq "the 10-bead fixture raises exactly the three expected WARNs" "$(warns)" "$F10_WARNS"
fi

# ── (b) priority unreadable ─────────────────────────────────────────────────────────────────────
if want b; then
echo "== (b) priority null / \"2\" / 9 / 1.5 / -1 / absent -> after P4, with WARN; never P0, never dropped"
FB="$TMP/prio.json"
{
  B ill-absent absent feature 2026-01-06T00:00:00Z
  B p0-bug 0 bug 2026-10-01T00:00:00Z
  B ill-neg -1 feature 2026-01-05T00:00:00Z
  B p4-task 4 task 2026-10-02T00:00:00Z
  B ill-null null feature 2026-01-01T00:00:00Z
  B ill-frac 1.5 feature 2026-01-04T00:00:00Z
  B ill-str '"2"' feature 2026-01-02T00:00:00Z
  B ill-nine 9 feature 2026-01-03T00:00:00Z
} | arr > "$FB"
expect_order "illegible priorities sit behind P4, oldest first, none promoted" created "$FB" \
  "p0-bug,p4-task,ill-null,ill-str,ill-nine,ill-frac,ill-neg,ill-absent"
eq "all eight beads are still there" "$(printf '%s' "$SORT_OUT" | jq 'length')" "8"
eq "one prio? WARN per illegible bead, none for the readable ones" "$(warns)" \
  "ill-absent: prio?;ill-frac: prio?;ill-neg: prio?;ill-nine: prio?;ill-null: prio?;ill-str: prio?;"
fi

# ── (c) type unreadable ─────────────────────────────────────────────────────────────────────────
if want c; then
echo "== (c) type absent / empty / non-string -> after the known types WITHIN the priority"
FC="$TMP/type.json"
{
  B p2-notype 2 - 2026-01-01T00:00:00Z
  B p2-feat 2 feature 2026-10-05T00:00:00Z
  B p1-notype 1 - 2026-01-02T00:00:00Z
  B p2-empty 2 "" 2026-01-03T00:00:00Z
  B p2-bug 2 bug 2026-10-04T00:00:00Z
  B p2-num 2 x 2026-01-04T00:00:00Z | jq -c '.issue_type = 5'
  B p2-nulltype 2 x 2026-01-05T00:00:00Z | jq -c '.issue_type = null'
  B p2-dotype 2 - 2026-10-03T00:00:00Z | jq -c '.type = "feature"'
} | arr > "$FC"
expect_order "unknown types trail the known ones inside P2 (and are not pushed behind other priorities)" created "$FC" \
  "p1-notype,p2-dotype,p2-feat,p2-bug,p2-notype,p2-empty,p2-num,p2-nulltype"
eq "type? WARN for exactly the unreadable ones" "$(warns)" \
  "p1-notype: type?;p2-empty: type?;p2-notype: type?;p2-nulltype: type?;p2-num: type?;"
FC2="$TMP/typecase.json"
{ B p2-Bug 2 Bug 2026-01-01T00:00:00Z; B p2-FEATURE 2 FEATURE 2026-10-05T00:00:00Z; B p2-Story 2 Story 2026-10-04T00:00:00Z; } | arr > "$FC2"
expect_order "the type is case-insensitive (the Pilot lowercases it): Feature / STORY are features" created "$FC2" "p2-Story,p2-FEATURE,p2-Bug"
eq "a feature list written in capitals is lowercased by work_order_cfg" \
  "$(WORK_ORDER_FEATURE_TYPES='Feature STORY' work_order_cfg | jq -c .feature_types)" '["feature","story"]'
fi

# ── (d) age unreadable ──────────────────────────────────────────────────────────────────────────
if want d; then
echo "== (d) created_at garbage / absent / null / not UTC -> end of the class, with WARN"
FD="$TMP/age.json"
{
  B z-junk 2 bug "not-a-date"
  B p3-ok 3 bug 2026-01-01T00:00:00Z
  B ok-new 2 bug 2026-10-01T00:00:00Z
  B y-absent 2 bug -
  B ok-old 2 bug 2026-09-01T00:00:00Z
  B x-null 2 bug x | jq -c '.created_at = null'
  B w-month13 2 bug "2026-13-45T99:00:00Z"
  B v-offset 2 bug "2026-09-15T10:00:00-03:00"
  B u-space 2 bug "2026-09-15 10:00:00"
} | arr > "$FD"
expect_order "unreadable ages trail their class (by id), P3 stays behind all of P2" created "$FD" \
  "ok-old,ok-new,u-space,v-offset,w-month13,x-null,y-absent,z-junk,p3-ok"
eq "age? WARN for exactly the unreadable ones" "$(warns)" \
  "u-space: age?;v-offset: age?;w-month13: age?;x-null: age?;y-absent: age?;z-junk: age?;"
FD2="$TMP/age-cal.json"
{
  B ok 2 bug 2026-02-28T10:00:00Z
  B leap-ok 2 bug 2024-02-29T10:00:00Z
  B feb31 2 bug 2026-02-31T10:00:00Z
  B apr31 2 bug 2026-04-31T00:00:00Z
  B h24 2 bug 2026-10-06T24:00:00Z
  B notleap 2 bug 2025-02-29T00:00:00Z
} | arr > "$FD2"
expect_order "a date the calendar does not have is unreadable, not rolled over (2026-02-31 is NOT 03-03); a real 02-29 is fine" created "$FD2" \
  "leap-ok,ok,apr31,feb31,h24,notleap"
eq "age? WARN for the impossible dates only" "$(warns)" "apr31: age?;feb31: age?;h24: age?;notleap: age?;"
FD3="$TMP/noid.json"
{
  B has-id 2 bug 2026-01-01T00:00:00Z
  B x 2 bug 2026-01-02T00:00:00Z | jq -c 'del(.id)'
  B y 2 bug 2026-01-03T00:00:00Z | jq -c '.id = 7'
  B z 2 bug 2026-01-04T00:00:00Z | jq -c '.id = ""'
} | arr > "$FD3"
run_sort created "$FD3"
eq "a bead without a readable string id is kept, not dropped" "$(printf '%s' "$SORT_OUT" | jq 'length')" "4"
# (compared per line: warns() sorts, and how punctuation sorts depends on the locale)
for w in 'work-order WARN: ?: id?' 'work-order WARN: 7: id?' 'work-order WARN: : id?'; do
  if printf '%s\n' "$SORT_ERR" | grep -qxF -- "$w"; then ok "id? WARN: $w"; else bad "id? WARN missing: [$w] in [$SORT_ERR]"; fi
done
eq "and no other bead is WARNed" "$(printf '%s\n' "$SORT_ERR" | grep -c .)" "3"
# The SHAPE of the original string is what is judged, anchored at both ends; only afterwards is the fraction of the
# SECONDS field dropped and +00:00 read as Z. A ".digits" anywhere else is not a fraction (gate round 3: the old
# unanchored sub() repaired these into a valid date and the round trip then validated the repaired string).
FD4="$TMP/age-shape.json"
{
  B ok-old 2 bug 2026-10-05T09:00:00Z
  B ok-frac 2 bug 2026-10-05T10:00:00.123456789Z
  B ok-off 2 bug 2026-10-05T10:30:00.5+00:00
  B ok-new 2 bug 2026-10-05T11:00:00Z
  B x-after-z 2 bug "2026-10-05T10:00:00Z.999"
  B x-on-date 2 bug "2026-10-05.5T10:00:00Z"
  B x-on-year 2 bug "2026.5-10-05T10:00:00Z"
  B x-on-hour 2 bug "2026-10-05T10.5:00:00Z"
  B x-bare-dot 2 bug "2026-10-05T10:00:00.Z"
  B x-two-frac 2 bug "2026-10-05T10:00:00.1.2Z"
  B x-newline 2 bug $'2026-10-05T10:00:00Z\n'
  B x-junk-line 2 bug $'junk\n2026-10-05T10:00:00Z'
  B x-lower-z 2 bug "2026-10-05T10:00:00z"
  B x-pad 2 bug " 2026-10-05T10:00:00Z "
} | arr > "$FD4"
expect_order "a '.digits' outside the seconds field, a trailing newline, padding or a lowercase z make the date unreadable (end of class by id); real fractions still parse" created "$FD4" \
  "ok-old,ok-frac,ok-off,ok-new,x-after-z,x-bare-dot,x-junk-line,x-lower-z,x-newline,x-on-date,x-on-hour,x-on-year,x-pad,x-two-frac"
eq "age? WARN for each of the ten malformed shapes, none for the four real ones" "$(warns)" \
  "x-after-z: age?;x-bare-dot: age?;x-junk-line: age?;x-lower-z: age?;x-newline: age?;x-on-date: age?;x-on-hour: age?;x-on-year: age?;x-pad: age?;x-two-frac: age?;"
FD5="$TMP/age-shape-field.json"
{
  B ok 2 bug 2026-01-01T00:00:00Z | jq -c '._wo_age = "2026-10-05T10:00:00.5Z"'
  B bad 2 bug 2026-01-01T00:00:00Z | jq -c '._wo_age = "2026-10-05T10:00:00Z.999"'
} | arr > "$FD5"
expect_order "the field age goes through the same judge: a malformed _wo_age is age-unreadable" field "$FD5" "ok,bad"
eq "and is WARNed" "$(warns)" "bad: age?;"
fi

# ── (e) timestamps ──────────────────────────────────────────────────────────────────────────────
if want e; then
echo "== (e) fraction of second and +00:00 parse; compared as time, not as text"
FE="$TMP/ts.json"
{
  B z-frac 2 bug 2026-10-05T10:00:00.123456Z
  B m-offset 2 bug 2026-10-05T10:00:00+00:00
  B q-early 2 bug 2026-10-05T09:59:59.999Z
  B a-fracoff 2 bug 2026-10-05T10:00:00.5+00:00
  B b-later 2 bug 2026-10-05T10:00:01Z
} | arr > "$FE"
expect_order "same second ties by id (string order would give m,z,a); the earlier second goes first" created "$FE" \
  "q-early,a-fracoff,m-offset,z-frac,b-later"
eq "all five parse: no WARN" "$(warns)" ""
fi

# ── (f) reclaim and field ───────────────────────────────────────────────────────────────────────
if want f; then
echo "== (f) reclaim: a bead with pilot:reclaim-count:N>=1 ages by updated_at (anti-starvation, inherited)"
FF="$TMP/reclaim.json"
{
  B p1-feat 1 feature 2026-01-01T00:00:00Z
  B feat-new 0 feature 2026-10-05T18:41:00Z
  B reclaimed 0 feature 2026-06-01T00:00:00Z 2026-10-05T20:00:00Z '["pilot:reclaim-count:2"]'
  B feat-old 0 feature 2026-09-20T00:00:00Z
} | arr > "$FF"
expect_order "created mode: the ancient reclaimed bead is first" created "$FF" "reclaimed,feat-old,feat-new,p1-feat"
expect_order "reclaim mode: it sinks behind the newest normal feature of its class, still ahead of a P1" reclaim "$FF" "feat-old,feat-new,reclaimed,p1-feat"
FF2="$TMP/reclaim2.json"
{
  B zero 0 feature 2026-06-01T00:00:00Z 2026-10-05T20:00:00Z '["pilot:reclaim-count:0"]'
  B junk 0 feature 2026-06-02T00:00:00Z 2026-10-05T20:00:00Z '["pilot:reclaim-count:abc","pilot:reclaim-count:"]'
  B norl 0 feature 2026-09-01T00:00:00Z 2026-10-05T20:00:00Z '["pilot:other"]'
  B nolab 0 feature 2026-09-02T00:00:00Z | jq -c 'del(.labels)'
  B nullab 0 feature 2026-09-03T00:00:00Z | jq -c '.labels = null'
  B strlab 0 feature 2026-09-04T00:00:00Z | jq -c '.labels = "pilot:reclaim-count:3"'
  B nouptd 0 feature 2026-05-01T00:00:00Z - '["pilot:reclaim-count:1"]'
} | arr > "$FF2"
expect_order "count 0, junk counts, other labels, absent/null labels keep created_at; a reclaimed bead with no updated_at, and one whose labels are not an array (cannot tell if it was reclaimed), are age-unreadable: end of class" \
  reclaim "$FF2" "zero,junk,norl,nolab,nullab,nouptd,strlab"
eq "exactly those two are warned" "$(warns)" "nouptd: age?;strlab: age?;"
expect_order "the same fixture in created mode needs no labels at all: every bead keeps created_at, no WARN" created "$FF2" "nouptd,zero,junk,norl,nolab,nullab,strlab"
eq "created mode: no WARN for the fixture" "$(warns)" ""
FF3="$TMP/reclaim3.json"
{
  B nl-label 0 feature 2026-05-15T00:00:00Z 2026-10-05T20:00:00Z '["pilot:reclaim-count:2\n"]'
  B real-reclaim 0 feature 2026-05-16T00:00:00Z 2026-10-05T21:00:00Z '["pilot:reclaim-count:2"]'
  B plain 0 feature 2026-09-01T00:00:00Z
} | arr > "$FF3"
expect_order "a label is judged WHOLE: 'pilot:reclaim-count:2<newline>' is not a reclaim marker (a regex \$ also matches before a final newline); the real marker still is" \
  reclaim "$FF3" "nl-label,plain,real-reclaim"
eq "no WARN: a label that is not a marker is just a label" "$(warns)" ""

echo "== (f2) field: the caller injects _wo_age (the stage's own marker); no fallback to created_at"
FFD="$TMP/field.json"
{
  B newer-created 0 bug 2026-01-01T00:00:00Z | jq -c '._wo_age = "2026-10-05T12:00:00Z"'
  B older-created 0 bug 2026-10-01T00:00:00Z | jq -c '._wo_age = "2026-10-04T12:00:00.5Z"'
  B no-marker 0 bug 2026-01-01T00:00:00Z
  B bad-marker 0 bug 2026-01-01T00:00:00Z | jq -c '._wo_age = "yesterday"'
} | arr > "$FFD"
expect_order "ordered by _wo_age; a bead without a readable marker goes to the end of its class" field "$FFD" \
  "older-created,newer-created,bad-marker,no-marker"
eq "age? WARN for the two without a readable marker, even though created_at is fine" "$(warns)" "bad-marker: age?;no-marker: age?;"
expect_order "reclaim mode on the 10-bead fixture (hand-checked)" reclaim "$F10" "$F10_RECLAIM"
fi

# ── (g) input order does not matter ─────────────────────────────────────────────────────────────
if want g; then
echo "== (g) shuffling the input does not change the output (tie-break by id)"
FT="$TMP/ties.json"
{
  B t-c 1 bug 2026-10-05T10:00:00Z; B t-a 1 bug 2026-10-05T10:00:00.9Z; B t-d 1 bug 2026-10-05T10:00:00+00:00
  B t-b 1 bug 2026-10-05T10:00:00Z; B t-e 1 bug 2026-10-05T10:00:00Z
} | arr > "$FT"
SAME=0; TOTAL=0
for f in "$F10" "$FA" "$FT"; do
  mode=created
  run_sort "$mode" "$f"; want_ids="$(sids)"
  n="$(jq 'length' "$f")"
  k=0
  while [ "$k" -le "$n" ]; do
    if [ "$k" -eq "$n" ]; then jq -c 'reverse' "$f" > "$TMP/shuf.json"; else jq -c --argjson k "$k" '.[$k:] + .[:$k]' "$f" > "$TMP/shuf.json"; fi
    run_sort "$mode" "$TMP/shuf.json"; TOTAL=$((TOTAL+1))
    if [ "$(sids)" = "$want_ids" ]; then SAME=$((SAME+1)); fi
    k=$((k+1))
  done
done
eq "every rotation and the reversal of three fixtures gives the same order" "$SAME" "$TOTAL"
expect_order "full ties come out by id" created "$FT" "t-a,t-b,t-c,t-d,t-e"
run_sort created "$F10"
if [ "$(printf '%s' "$SORT_OUT" | jq -cS 'sort_by(.id)')" = "$(jq -cS 'sort_by(.id)' "$F10")" ]; then
  ok "the beads come out untouched (same objects, nothing added, nothing dropped)"
else
  bad "the output holds different bead objects than the input"
fi
fi

# ── (h) three states ────────────────────────────────────────────────────────────────────────────
if want h; then
echo "== (h) [] -> [] exit 0; anything else unreadable -> stdout EMPTY, exit != 0 (never 'no bead')"
run_sort created <(echo '[]')
eq "[] -> stdout" "$SORT_OUT" "[]"; eq "[] -> exit" "$SORT_RC" "0"; eq "[] -> no stderr" "$SORT_ERR" ""
cant() { # <label> <stdin-text> [work_order_sort args...]
  local label="$1" text="$2"; shift 2
  local out err rc
  out="$(printf '%s' "$text" | work_order_sort "$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
  if [ -z "$out" ] && [ "$rc" -eq 2 ] && [[ "$err" == work-order\ ERROR:* ]]; then ok "$label -> empty stdout, exit 2, ERROR line"
  else bad "$label: out=[$out] rc=$rc err=[$err]"; fi
}
cant "empty stdin" ""
cant "not JSON" "nope"
cant "an object" '{"id":"x"}'
cant "null" 'null'
cant "a string" '"x"'
cant "array of non-objects" '[1,2]'
cant "array with one non-object" '[{"id":"a"},3]'
cant "two documents" '[] []'
cant "truncated JSON" '[{"id":"a"'
cant "unknown --age" '[]' --age bogus
cant "--age without a value" '[]' --age
cant "unknown option" '[]' --nope
eq "work_order_cfg --age reclaim prints the options" "$(work_order_cfg --age reclaim)" '{"age":"reclaim","feature_types":["feature","story"]}'
eq "work_order_cfg default age" "$(work_order_cfg | jq -r .age)" "created"
out="$(work_order_cfg --age bogus 2>/dev/null)"; rc=$?
eq "work_order_cfg --age bogus: stdout empty" "$out" ""; eq "work_order_cfg --age bogus: exit" "$rc" "2"
out="$(WORK_ORDER_FEATURE_TYPES="" work_order_cfg 2>/dev/null)"; rc=$?
eq "work_order_cfg with an empty feature list: stdout empty" "$out" ""; eq "work_order_cfg with an empty feature list: exit" "$rc" "2"
out="$(echo '[]' | WORK_ORDER_FEATURE_TYPES="  " work_order_sort 2>/dev/null)"; rc=$?
eq "work_order_sort with a blank feature list cannot tell: stdout empty" "$out" ""; eq "work_order_sort with a blank feature list: exit" "$rc" "2"
err="$(work_order_cfg --nope 2>&1 >/dev/null)"
case "$err" in *"unknown option: --nope"*) ok "a bad option is named in the ERROR line" ;; *) bad "the bad option is not named: [$err]" ;; esac
err="$(WORK_ORDER_FEATURE_TYPES="" work_order_cfg 2>&1 >/dev/null)"
case "$err" in *"WORK_ORDER_FEATURE_TYPES is empty"*) ok "an empty feature list is named in the ERROR line" ;; *) bad "the empty list is not named: [$err]" ;; esac
out="$(PATH=/nonexistent /bin/bash -c "source '$LIB'; echo '[]' | work_order_sort" 2>"$TMP/err")"; rc=$?
eq "jq missing: stdout empty" "$out" ""; eq "jq missing: exit 2" "$rc" "2"
case "$(cat "$TMP/err")" in *"jq is not on PATH"*) ok "jq missing is reported as jq missing, not as a bad option" ;; *) bad "jq missing is not reported as such: [$(cat "$TMP/err")]" ;; esac
eq "an exported WORK_ORDER_FEATURE_TYPES survives sourcing the library" \
  "$(WORK_ORDER_FEATURE_TYPES=bug bash -c "source '$LIB'; echo \"\$WORK_ORDER_FEATURE_TYPES\"")" "bug"
out="$(WORK_ORDER_FEATURE_TYPES="" bash -c "source '$LIB'; work_order_cfg" 2>/dev/null)"; rc=$?
eq "an EMPTY export is not replaced by the default (it is refused): stdout empty" "$out" ""; eq "an EMPTY export: exit 2" "$rc" "2"
echo "-- work_order_head"
eq "head of the ordered 10-bead fixture" "$(work_order_sort < "$F10" 2>/dev/null | work_order_head | jq -r .id)" "j-p0-feat-reclaimed"
out="$(echo '[]' | work_order_head 2>/dev/null)"; rc=$?
eq "head of [] is the literal null" "$out" "null"; eq "head of [] exits 0" "$rc" "0"
for t in "" "nope" '{"id":"x"}' '[] []'; do
  out="$(printf '%s' "$t" | work_order_head 2>/dev/null)"; rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 2 ]; then ok "head of [$t] -> empty stdout, exit 2"; else bad "head of [$t]: out=[$out] rc=$rc"; fi
done
out="$(: | work_order_sort 2>/dev/null | work_order_head 2>/dev/null)"
eq "a failed sort piped into head stays EMPTY (it never reads as 'no bead')" "$out" ""
# raw `bd --json` piped straight in (no work_order_sort in between) must not read a non-bead as THE bead:
# jq's .[0] prints the literal null for [null,{...}] — the same text as "no bead" for []
for t in '[null,{"id":"x"}]' '[1]' '[{"id":"x"},"y"]' '[[]]' '["x"]'; do
  out="$(printf '%s' "$t" | work_order_head 2>"$TMP/err")"; rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 2 ]; then ok "head of $t (an element that is not a bead object) -> empty stdout, exit 2"; else bad "head of $t: out=[$out] rc=$rc"; fi
done
case "$(printf '%s' '[null,{"id":"x"}]' | work_order_head 2>&1 >/dev/null)" in *"not an object"*) ok "the ERROR line names the cause (an element is not an object)" ;; *) bad "head's ERROR line does not name the cause" ;; esac
eq "head of a one-bead array is that bead" "$(printf '%s' '[{"id":"x","priority":0}]' | work_order_head)" '{"id":"x","priority":0}'
fi

# ── (i) python == bash ──────────────────────────────────────────────────────────────────────────
if want i; then
echo "== (i) python == bash on the same fixtures"
for mode in created reclaim field; do
  case "$mode" in field) f="${FFD:-}" ;; *) f="$F10" ;; esac   # FFD is built by (f): unset under WO_ONLY=i
  [ -r "$f" ] || { skip "fixture for $mode not built (run without WO_ONLY)"; continue; }
  run_sort "$mode" "$f"; bash_out="$(printf '%s' "$SORT_OUT" | jq -cS '.')"; bash_warn="$(warns)"
  py_out="$(python3 -I -B "$PY" sort --age "$mode" < "$f" 2>"$TMP/pyerr")"; py_rc=$?
  eq "$mode: python CLI exit" "$py_rc" "0"
  eq "$mode: python output == bash output" "$(printf '%s' "$py_out" | jq -cS '.')" "$bash_out"
  eq "$mode: python WARN lines == bash WARN lines" "$(sed -n 's/^work-order WARN: //p' "$TMP/pyerr" | grep -v '^WORK_ORDER_LIB override' | sort | tr '\n' ';')" "$bash_warn"
done
out="$(printf 'nope' | python3 -I -B "$PY" sort 2>"$TMP/pyerr")"; rc=$?
eq "python CLI on garbage: stdout empty" "$out" ""; eq "python CLI on garbage: exit" "$rc" "2"
case "$(cat "$TMP/pyerr")" in work-order\ ERROR:*) ok "python CLI on garbage: ERROR line on stderr" ;; *) bad "python CLI on garbage: stderr=[$(cat "$TMP/pyerr")]" ;; esac
out="$(echo '[]' | python3 -I -B "$PY" sort --age bogus 2>/dev/null)"; rc=$?
eq "python CLI with an unknown age: stdout empty" "$out" ""; eq "python CLI with an unknown age: exit" "$rc" "2"
out="$(echo '[]' | python3 -I -B "$PY" sort 2>/dev/null)"; rc=$?
eq "python CLI on []: [] and exit 0" "$out/$rc" "[]/0"
PYMOD="$(python3 -I -B - "$ROOT/scripts" "$F10" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import work_order as wo
def ws(w):  # the WORK_ORDER_LIB override notice is checked on its own below, not counted with the bead WARNs
    return [x for x in w if not x.startswith("work-order WARN: WORK_ORDER_LIB override")]
beads = json.load(open(sys.argv[2]))
out, w = wo.sort_beads(beads)
print("created=" + ",".join(b["id"] for b in out)); print("warns=%d" % len(ws(w)))
out, w = wo.sort_beads(beads, age="reclaim"); print("reclaim=" + ",".join(b["id"] for b in out))
out, w = wo.sort_beads([]); print("empty=%r/%r" % (out, ws(w)))
out, w = wo.sort_beads({"a": 1}); print("object=%s/%d" % (out is None, len(ws(w))))
out, w = wo.sort_beads(beads, age="bogus"); print("bogus=%s" % (out is None))
os.environ["WORK_ORDER_LIB"] = "/nonexistent/work-order.sh"
out, w = wo.sort_beads(beads); print("nolib=%s" % (out is None))
PY
)"
eq "sort_beads(): created order" "$(printf '%s\n' "$PYMOD" | sed -n 's/^created=//p')" "$F10_CREATED"
eq "sort_beads(): three WARN lines" "$(printf '%s\n' "$PYMOD" | sed -n 's/^warns=//p')" "3"
eq "sort_beads(): reclaim order" "$(printf '%s\n' "$PYMOD" | sed -n 's/^reclaim=//p')" "$F10_RECLAIM"
eq "sort_beads([]) is ([], []), not None" "$(printf '%s\n' "$PYMOD" | sed -n 's/^empty=//p')" "[]/[]"
eq "sort_beads(non-list) is (None, [reason])" "$(printf '%s\n' "$PYMOD" | sed -n 's/^object=//p')" "True/1"
eq "sort_beads(unknown age) is None" "$(printf '%s\n' "$PYMOD" | sed -n 's/^bogus=//p')" "True"
eq "sort_beads(library missing) is None" "$(printf '%s\n' "$PYMOD" | sed -n 's/^nolib=//p')" "True"
echo "-- WORK_ORDER_LIB override is never silent (a stale path in a daemon's environment orders by ANOTHER rule)"
REAL_LIB="$SELF_DIR/work-order.sh"
cp "$REAL_LIB" "$TMP/override-copy.sh"; ln -s "$REAL_LIB" "$TMP/override-link.sh"
py_ovr() { # <path | UNSET> -> OVR_OUT OVR_ERR   (F10, created order)
  if [ "$1" = UNSET ]; then OVR_OUT="$(env -u WORK_ORDER_LIB python3 -I -B "$PY" sort < "$F10" 2>"$TMP/ovr.err")"
  else OVR_OUT="$(WORK_ORDER_LIB="$1" python3 -I -B "$PY" sort < "$F10" 2>"$TMP/ovr.err")"; fi
  OVR_ERR="$(cat "$TMP/ovr.err")"
}
py_ovr "$TMP/override-copy.sh"
case "$OVR_ERR" in
  *"work-order WARN: WORK_ORDER_LIB override active: "*"override-copy.sh"*) ok "a different library path in WORK_ORDER_LIB is announced on stderr, with the path" ;;
  *) bad "an active override is silent: [$OVR_ERR]" ;;
esac
eq "an active override only warns: the order is still produced" "$(printf '%s' "$OVR_OUT" | jq -r 'map(.id) | join(",")')" "$F10_CREATED"
for v in UNSET "$REAL_LIB" "$TMP/override-link.sh"; do
  py_ovr "$v"
  case "$OVR_ERR" in
    *"WORK_ORDER_LIB override"*) bad "no override notice expected for [$v]: [$OVR_ERR]" ;;
    *) ok "no notice when the default library is in use (${v##*/})" ;;
  esac
done
# ...and a run that CANNOT TELL says so too, whichever way the overridden library failed: that is where a stale
# override is the likeliest cause, and the reason must not hide it (gate round 3 self-audit: the non-JSON branch did)
printf '%s\n' 'work_order_sort() { cat >/dev/null; echo "work-order ERROR: fixture failed" >&2; return 2; }' > "$TMP/ovr-fail.sh"
printf '%s\n' 'work_order_sort() { cat >/dev/null; echo "nope"; }' > "$TMP/ovr-nojson.sh"
printf '%s\n' 'work_order_sort() { cat >/dev/null; echo "{\"a\":1}"; }' > "$TMP/ovr-notarray.sh"
py_cant_ovr() { # <label> <library path> <what the reason must also say>
  local out err rc
  out="$(echo '[]' | WORK_ORDER_LIB="$2" python3 -I -B "$PY" sort 2>"$TMP/ovr.err")"; rc=$?
  err="$(cat "$TMP/ovr.err")"
  if [ -z "$out" ] && [ "$rc" -eq 2 ] && [[ "$err" == *"$3"* ]] && [[ "$err" == *"WORK_ORDER_LIB override active: "* ]]; then
    ok "override + $1: empty stdout, exit 2, and the ERROR line names the override"
  else bad "override + $1: out=[$out] rc=$rc err=[$err]"; fi
}
py_cant_ovr "a library that fails (exit 2)"          "$TMP/ovr-fail.sh"     "fixture failed"
py_cant_ovr "a library that prints text, not JSON"   "$TMP/ovr-nojson.sh"   "library output is not JSON"
py_cant_ovr "a library that prints an object"        "$TMP/ovr-notarray.sh" "library output is not an array"
py_cant_ovr "a library path that does not exist"     "$TMP/ovr-missing.sh"  "library not found"
fi

# ── (k) sourcing ────────────────────────────────────────────────────────────────────────────────
if want k; then
echo "== (k) sourcing twice is a no-op and survives set -euo pipefail (bash 3.2 and PATH bash)"
SHELLS=""
for s in /bin/bash "$(command -v bash)"; do
  [ -x "$s" ] || continue
  case " $SHELLS " in *" $s "*) continue ;; esac
  SHELLS="$SHELLS $s"
done
mkdir -p "$TMP/cwd"; cd "$TMP/cwd" || exit 1        # a clean directory: sourcing must leave nothing in it
for s in $SHELLS; do
  v="$("$s" -c 'echo ${BASH_VERSION%%(*}')"
  OUT="$("$s" -c 'set -euo pipefail; source "$1"; source "$1"; echo REACHED' _ "$LIB" 2>&1)"
  eq "bash $v: sourced twice under set -euo pipefail prints only REACHED" "$OUT" "REACHED"
  OUT="$("$s" -c 'set -euo pipefail; source "$1"; out="$(work_order_sort --age created < "$2" 2>/dev/null | jq -r "map(.id)|join(\",\")")"; echo "$out"' _ "$LIB" "$F10" 2>&1)"
  eq "bash $v: work_order_sort under set -euo pipefail, created order" "$OUT" "$F10_CREATED"
  OUT="$("$s" -c 'set -euo pipefail; source "$1"; out="$(work_order_sort --age reclaim < "$2" 2>/dev/null | jq -r "map(.id)|join(\",\")")"; echo "$out"' _ "$LIB" "$F10" 2>&1)"
  eq "bash $v: work_order_sort under set -euo pipefail, reclaim order" "$OUT" "$F10_RECLAIM"
  OUT="$("$s" -c 'set -euo pipefail; source "$1"; if ! o="$(echo nope | work_order_sort 2>/dev/null)"; then echo "CAUGHT [$o]"; fi; echo REACHED' _ "$LIB" 2>&1)"
  eq "bash $v: a guarded failing call is caught and the shell goes on" "$OUT" "$(printf 'CAUGHT []\nREACHED')"
  OUT="$("$s" -c 'set -euo pipefail; source "$1"; o="$(echo "[]" | work_order_head)"; echo "$o"' _ "$LIB" 2>&1)"
  eq "bash $v: work_order_head of [] under set -euo pipefail" "$OUT" "null"
  eq "bash $v: sourcing leaves no file behind" "$(ls -A "$TMP/cwd" | wc -l | tr -d ' ')" "0"
done
cd "$SELF_DIR" || exit 1
FUNCS="$(bash -c 'source "$1"; declare -F | awk "{print \$3}" | sort | tr "\n" " "' _ "$LIB")"
eq "the library defines exactly three functions" "$FUNCS" "work_order_cfg work_order_head work_order_sort "
for v in WORK_ORDER_FEATURE_TYPES WORK_ORDER_JQ_DEFS; do
  if [ -n "${!v:-}" ]; then ok "$v is defined"; else bad "$v is empty"; fi
done
if bash -n "$LIB" 2>/dev/null; then ok "bash -n work-order.sh"; else bad "bash -n work-order.sh"; fi
if bash -n "$SELF" 2>/dev/null; then ok "bash -n work-order.selftest.sh"; else bad "bash -n work-order.selftest.sh"; fi
if python3 -I -B -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$PY" 2>/dev/null; then ok "work_order.py compiles"; else bad "work_order.py does not compile"; fi
fi

# ── (R) registry lint ───────────────────────────────────────────────────────────────────────────
mk_tree() { mkdir -p "$1/packs/town-deltas/assets/scripts" "$1/agents/x-worker" "$1/scripts"; }
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
lint_run() { LINT_OUT="$(python3 -I -B "$PY" lint --root "$1" --registry "$2" 2>"$TMP/lint.err")"; LINT_RC=$?; }
lint_count() { printf '%s\n' "$LINT_OUT" | grep -c "$1" | tr -d ' '; }
if want R && [ "${WO_SKIP_MUTATION:-0}" != "1" ] || [ "${WO_ONLY:-}" = "R" ]; then
echo "== (R) registry lint: the real tree"
lint_run "$ROOT" "$REGISTRY"
eq "the real tree is clean (exit)" "$LINT_RC" "0"
eq "the real tree has no finding" "$(lint_count 'LINT FAIL')" "0"
case "$LINT_OUT" in *"LINT: files="*) ok "the lint prints its summary: $(printf '%s\n' "$LINT_OUT" | grep -m1 '^LINT: files=')" ;; *) bad "no LINT summary: $LINT_OUT" ;; esac
# What the lint claims to look at is asserted from a list written HERE, not read back from the lint: a glob that
# silently drops out of SCOPE_GLOBS is a hole in the net, and "the lint is clean" would not say so.
EXPECT_GLOBS="packs/town-deltas/assets/*.sh packs/town-deltas/assets/scripts/*.sh packs/town-deltas/orders/*.toml packs/town-deltas/formulas/*.toml packs/town-deltas/template-fragments/*.md formulas/*.toml commands/*.md agents/*/prompt.template.md scripts/*.sh scripts/*.py"
eq "the printed LINT SCOPE is the expected glob list" "$(printf '%s\n' "$LINT_OUT" | grep '^LINT SCOPE: ')" "LINT SCOPE: $EXPECT_GLOBS (not: selftests, test_*.py, work-order.sh, work_order.py)"
case "$LINT_OUT" in *"
LINT SEES: "*) ok "a clean run prints LINT SEES" ;; *) bad "no LINT SEES line: $LINT_OUT" ;; esac
case "$LINT_OUT" in *"
LINT NOT SEEN: "*) ok "a clean run prints LINT NOT SEEN" ;; *) bad "no LINT NOT SEEN line: $LINT_OUT" ;; esac
# A glob that matches no file is a part of the scope the lint is not looking at (a directory renamed away): it must be
# counted in the summary and named in a LINT NOTE, and on the real tree there must be none — a rename fails HERE.
case "$LINT_OUT" in *" empty_globs=0"*) ok "the real tree: every scope glob matches a file (empty_globs=0)" ;; *) bad "the real tree has an empty scope glob: $(printf '%s\n' "$LINT_OUT" | grep -E '^LINT (NOTE|:)')" ;; esac
eq "the real tree: no LINT NOTE" "$(lint_count '^LINT NOTE')" "0"
# Consumer owners are checked for LEGITIMACY, not for presence. A slice that migrates its consumer DELETES its row in
# the same commit (the registry header says so), so "slice N still has a row" is true only until N lands: asserting it
# turned this selftest red for every slice that did what the header tells it to (ga-9t9acg.3 was the first) and made
# each of them edit this line. What stays true as rows go is: every consumer row is owned by a slice of the programme
# or by UNASSIGNED (a typo, or a consumer nobody planned for, is what is worth catching) — and an empty registry, the
# end of the programme, passes. The ext rows are never deleted by a slice, so those are still asserted one by one below.
KNOWN_OWNERS=" UNASSIGNED ga-q8tj7p ga-9t9acg.2 ga-9t9acg.3 ga-9t9acg.4 ga-9t9acg.5 ga-9t9acg.6 ga-9t9acg.8 ga-9t9acg.9 ga-9t9acg.10 ga-9t9acg.13 "
strange_owners() {   # <registry> — the consumer-row owners that are not in KNOWN_OWNERS, each followed by a space
  # A registry that cannot be read says nothing about its owners: that is "cannot tell", never "no strange owner".
  # It is reported as a finding (so the eq below fails) instead of printing nothing, which would read as clean.
  if [ ! -r "$1" ]; then printf 'UNREADABLE:%s ' "$1"; return 0; fi
  awk -F'\t' '$1 == "consumer" {print $4}' "$1" | sort -u | while IFS= read -r o; do
    case "$KNOWN_OWNERS" in *" $o "*) ;; *) printf '%s ' "$o" ;; esac
  done
}
eq "every consumer row is owned by a slice of the programme or UNASSIGNED" "$(strange_owners "$REGISTRY")" ""
printf 'consumer\tf\tx\tga-typo\tn\nconsumer\tf\ty\tga-9t9acg.3\tn\n' > "$TMP/owners.tsv"
eq "an owner nobody planned is reported; a migrated slice's id is still a legitimate owner" "$(strange_owners "$TMP/owners.tsv")" "ga-typo "
eq "an unreadable registry is reported, not read as 'no strange owner'" "$(strange_owners "$TMP/no-such-registry.tsv")" "UNREADABLE:$TMP/no-such-registry.tsv "
for o in ga-9t9acg.7 ga-9t9acg.11 ga-9t9acg.12; do
  if awk -F'\t' -v o="$o" '$1 == "ext" && $4 == o {f=1} END {exit !f}' "$REGISTRY"; then ok "an ext row is owned by $o"; else bad "no ext row for $o"; fi
done

echo "== (R) registry lint: synthetic trees"
T1="$TMP/lt1"; mk_tree "$T1"; : > "$TMP/empty.tsv"
echo '#!/bin/bash' > "$T1/packs/town-deltas/assets/ok.sh"; echo 'echo hi' >> "$T1/packs/town-deltas/assets/ok.sh"
lint_run "$T1" "$TMP/empty.tsv"; eq "a tree without idioms: exit" "$LINT_RC" "0"
case "$LINT_OUT" in *"idiom_lines=0"*) ok "a tree without idioms: idiom_lines=0" ;; *) bad "a tree without idioms: $LINT_OUT" ;; esac
case "$LINT_OUT" in *" empty_globs=9"*) ok "a tree with one file in scope: nine empty globs are counted" ;; *) bad "empty globs not counted: $(printf '%s\n' "$LINT_OUT" | grep '^LINT:')" ;; esac
eq "a tree with one file in scope: one LINT NOTE per empty glob" "$(lint_count '^LINT NOTE: no file matches scope glob ')" "9"
case "$LINT_OUT" in *"LINT NOTE: no file matches scope glob commands/*.md "*) ok "the LINT NOTE names the glob" ;; *) bad "the LINT NOTE does not name commands/*.md: $LINT_OUT" ;; esac
FOO="$T1/packs/town-deltas/assets/foo-dispatcher.sh"
printf '%s\n' '#!/bin/bash' '# sort_by(.created_at) in a comment is not a hit' "X=\$(echo \"\$J\" | jq 'sort_by(.created_at) | .[0]')" > "$FOO"
lint_run "$T1" "$TMP/empty.tsv"
eq "an unregistered sort_by: exit 1" "$LINT_RC" "1"
for k in SCOPE SEES "NOT SEEN"; do
  case "$LINT_OUT" in *"LINT $k: "*) ok "a failing run prints LINT $k" ;; *) bad "a failing run does not print LINT $k: $LINT_OUT" ;; esac
done
case "$LINT_OUT" in *"UNREGISTERED packs/town-deltas/assets/foo-dispatcher.sh:3 "*) ok "the finding names file and line (3)" ;; *) bad "finding missing: $LINT_OUT" ;; esac
case "$LINT_OUT" in *"foo-dispatcher.sh:2 "*) bad "the comment line was reported" ;; *) ok "a comment line is not a hit" ;; esac
row consumer packs/town-deltas/assets/foo-dispatcher.sh 'sort_by\(\.created_at\) \| \.\[0\]' ga-9t9acg.9 "R10 test" > "$TMP/r1.tsv"
lint_run "$T1" "$TMP/r1.tsv"; eq "registered: exit 0" "$LINT_RC" "0"
case "$LINT_OUT" in *"consumer_rows_left=1"*) ok "registered: consumer_rows_left=1" ;; *) bad "registered: $LINT_OUT" ;; esac
printf '%s\n' '#!/bin/bash' "X=\$(echo \"\$J\" | work_order_sort | work_order_head)" > "$FOO"
lint_run "$T1" "$TMP/r1.tsv"; eq "migrated without deleting the row: exit 1" "$LINT_RC" "1"
case "$LINT_OUT" in *"STALE row"*) ok "migrated without deleting the row: STALE" ;; *) bad "no STALE finding: $LINT_OUT" ;; esac
printf '%s\n' '#!/bin/bash' "A=\$(jq 'sort_by(.created_at) | .[0]')" "B=\$(jq 'sort_by(.updated_at) | .[0]')" > "$FOO"
row consumer packs/town-deltas/assets/foo-dispatcher.sh 'sort_by\(\.created_at\)' ga-9t9acg.9 "R10 test" > "$TMP/r2.tsv"
lint_run "$T1" "$TMP/r2.tsv"; eq "a second, unmatched idiom line: exit 1" "$LINT_RC" "1"
eq "exactly one finding, for line 3" "$(printf '%s\n' "$LINT_OUT" | grep -c 'UNREGISTERED .*foo-dispatcher.sh:3 ')/$(lint_count 'LINT FAIL')" "1/1"

T2="$TMP/lt2"; mk_tree "$T2"
echo "bd ready --sort oldest --json" > "$T2/packs/town-deltas/assets/a.sh"
echo "_PILOT_SORT_JQ='x'" > "$T2/packs/town-deltas/assets/b.sh"
echo 'items.sort(key=lambda b: b.get("updated_at"))' > "$T2/scripts/c.py"
echo 'bd list --json --limit=20' > "$T2/packs/town-deltas/assets/d.sh"
echo 'bd ready --sort priority --json' > "$T2/agents/x-worker/prompt.template.md"
echo "jq 'sort_by(.priority)'" > "$T2/packs/town-deltas/assets/scripts/e.sh"
lint_run "$T2" "$TMP/empty.tsv"
eq "every idiom class and every scope glob is seen (6 findings)" "$(lint_count 'UNREGISTERED')" "6"
for f in a.sh b.sh c.py d.sh prompt.template.md scripts/e.sh; do
  case "$LINT_OUT" in *"$f:1 "*) ok "seen: $f" ;; *) bad "not seen: $f" ;; esac
done

# One file per SCOPE glob, each carrying a sort: the lint has to find ten, one per glob in the list above.
T6="$TMP/lt6"; mk_tree "$T6"; n=0
IFS=' ' read -r -a GLOBS <<< "$EXPECT_GLOBS"      # an array, never an unquoted expansion: that would glob against the cwd
for g in "${GLOBS[@]}"; do
  f="${g//\*/fx}"; mkdir -p "$T6/$(dirname "$f")"; echo "jq 'sort_by(.created_at)'" > "$T6/$f"; n=$((n + 1))
done
lint_run "$T6" "$TMP/empty.tsv"
eq "one finding per SCOPE glob ($n globs)" "$(lint_count 'UNREGISTERED')" "$n"
case "$LINT_OUT" in *" empty_globs=0"*) ok "every glob has a file: empty_globs=0" ;; *) bad "empty_globs is not 0 with a file under every glob: $(printf '%s\n' "$LINT_OUT" | grep '^LINT:')" ;; esac
eq "every glob has a file: no LINT NOTE" "$(lint_count '^LINT NOTE')" "0"
for g in "${GLOBS[@]}"; do
  f="${g//\*/fx}"
  case "$LINT_OUT" in *"UNREGISTERED $f:1 "*) ok "scope glob is scanned: $g" ;; *) bad "scope glob is NOT scanned: $g" ;; esac
done

# One fixture per SHAPE the lint claims to see (flagged), per shape it claims NOT to flag (clean: 0 = the whole
# population, tail -n, usage text, ...), and per blind spot it admits to (unseen: exit 0, and LINT NOT SEEN says so).
T7="$TMP/lt7"; mk_tree "$T7"; mkdir -p "$T7/docs"
shape() { # <flagged|clean> <label> <the file content>
  printf '%s\n' "$3" > "$T7/scripts/s.py"
  lint_run "$T7" "$TMP/empty.tsv"
  if [ "$1" = flagged ]; then
    if [ "$LINT_RC" -eq 1 ] && [ "$(lint_count 'UNREGISTERED scripts/s.py:1 ')" = "1" ]; then ok "shape flagged: $2"
    else bad "shape NOT flagged — the lint is blind to it: $2 :: $3 (rc=$LINT_RC)"; fi
  else
    if [ "$LINT_RC" -eq 0 ] && [ "$(lint_count 'LINT FAIL')" = "0" ]; then ok "shape not flagged: $2"
    else bad "shape wrongly flagged: $2 :: $3 (rc=$LINT_RC)"; fi
  fi
}
unseen() { # <label> <the file content> <phrase LINT NOT SEEN must contain>
  printf '%s\n' "$2" > "$T7/scripts/s.py"
  lint_run "$T7" "$TMP/empty.tsv"
  if [ "$LINT_RC" -ne 0 ]; then bad "blind spot is now SEEN ($1): move its fixture to flagged and fix LINT_NOT_SEEN :: $2"
  elif printf '%s\n' "$LINT_OUT" | grep '^LINT NOT SEEN: ' | grep -qF -- "$3"; then ok "blind spot is documented in LINT NOT SEEN: $1"
  else bad "blind spot is NOT documented ('$3' missing from LINT NOT SEEN): $1"; fi
}
shape flagged "M1 sort_by"                         "jq 'sort_by(.created_at) | .[0]'"
shape flagged "M1 min_by"                          "jq 'min_by(.created_at)'"
shape flagged "M1 max_by"                          "jq 'max_by(.priority)'"
shape flagged "M1 call left open at end of line"   "jq 'sort_by("
shape flagged "M1 min_by left open"                "jq 'min_by("
shape flagged "M2 --sort"                          "bd ready --sort oldest --json"
shape flagged "M2 Python list-form --sort"         '  argv += ["--json", "--sort", "oldest"]'
shape flagged "M3 _PILOT_SORT_JQ"                  "_PILOT_SORT_JQ='x'"
shape flagged "M4 .sort(key=)"                     'rows.sort(key=lambda b: b["created_at"])'
shape flagged "M4 sorted(key=)"                    'x = sorted(rows, key=lambda b: b.get("priority"))'
shape flagged "M4 min(key=)"                       'o = min(rows, key=lambda b: b["updated_at"])'
shape flagged "M4 max(key=)"                       'o = max(rows, key=lambda b: b["updated_at"])'
shape flagged "M4 sorted( left open"               'layer = sorted('
shape flagged "M4 .sort( left open"                'rows.sort('
shape flagged "M5 --limit N"                       "bd list --json --limit 20"
shape flagged "M5 --limit=N"                       "bd list --json --limit=20"
shape flagged 'M5 --limit "$N"'                    'bd list --json --limit "$N"'
shape flagged 'M5 --limit $N'                      'bd list --json --limit $N'
shape flagged 'M5 --limit=${N}'                    'bd list --json --limit=${N}'
shape flagged "M5 f-string --limit={n}"            'argv += ["--json", f"--limit={n}"]'
shape flagged 'M5 list-form "--limit", "20"'       '_sh(["bd", "list", "--json", "--limit", "20"])'
shape flagged 'M5 list-form "--limit", n'          '_sh(["bd", "list", "--json", "--limit", n])'
shape flagged 'M5 list-form "--limit", str(n)'     '_sh(["bd", "list", "--limit", str(n)])'
shape flagged 'M5 list-form "-n", "200"'           'r = _sh([BD, "-C", root, "list", "-l", label, "-n", "200", "--json"])'
shape flagged 'M5 list-form "-n", variable'        'r = _sh([BD, "list", "-n", limit])'
shape flagged 'M5 list-form "-n", "100"] on a continuation line' '                 "--status", "open", "--json", "-n", "100"],'
shape flagged "M5 shell bd list -n N"              'bd list --status open -n 100'
shape flagged 'M5 shell "$BD" list -n N'           '"$BD" -C "$dir" list -n 5 --json'
shape flagged 'M5 shell bd ready -n $N'            'bd ready --json -n $N'
shape clean "--limit 0 (the whole population)"     "bd list --json --limit 0"
shape clean "--limit=0"                            "bd list --json --limit=0"
shape clean 'list-form "--limit", "0"'             '_sh(["bd", "list", "--limit", "0"])'
shape clean 'list-form "-n", "0"'                  '_sh([BD, "list", "-n", "0", "--json"])'
shape clean "tail -n"                              'tail -n 20 "$LOG"'
shape clean "sed -n"                               "sed -n '1,5p' f"
shape clean "jq -n"                                "jq -n '{}'"
shape clean "[ -n ] after a bd query"              'bd list --json | jq -e ".[0]" && [ -n "$x" ]'
shape clean "test -n after a bd query"             'bd list --json && test -n "$x"'
shape clean 'sysctl list-form "-n"'                'r = _sh(["sysctl", "-n", "hw.ncpu"])'
shape clean "usage text: --limit N"                '  [--dry-run] [--limit N] [--since-days N]'
shape clean "argparse --limit"                     'p.add_argument("--limit", type=int, default=30)'
shape clean "sorted() of names, no bead field"     'names = sorted(names)'
unseen "a sort keyed through a helper"             'rows.sort(key=_age)'                          'key=_age'
unseen "a text pipeline"                           'ls | sort -k2 | head -1'                      'sort -k'
unseen "a window assembled from pieces"            'LIM="--lim"; bd list ${LIM}it 20'             'assembled from pieces'
unseen "a window on another line than its flag"    $'_sh(["bd", "list", "--limit",\n"20"])'       'different line from its flag'
printf '%s\n' "jq 'sort_by(.created_at)'" > "$T7/docs/x.sh"; : > "$T7/scripts/s.py"
lint_run "$T7" "$TMP/empty.tsv"
if [ "$LINT_RC" -eq 0 ] && printf '%s\n' "$LINT_OUT" | grep '^LINT NOT SEEN: ' | grep -qF 'docs/'; then ok "a file in docs/ is out of scope, and LINT NOT SEEN says so"
else bad "docs/ is not documented as out of scope (rc=$LINT_RC)"; fi

T3="$TMP/lt3"; mk_tree "$T3"
for f in packs/town-deltas/assets/foo.selftest.sh scripts/test_x.py scripts/x.selftest.py packs/town-deltas/assets/scripts/work-order.sh scripts/work_order.py; do
  echo "jq 'sort_by(.created_at)'" > "$T3/$f"
done
echo 'echo clean' > "$T3/packs/town-deltas/assets/clean.sh"     # the one file that IS in scope: the lint must have looked at something
lint_run "$T3" "$TMP/empty.tsv"; eq "selftests, test_*.py and the library itself are out of scope" "$LINT_RC" "0"
case "$LINT_OUT" in *"files=1 "*) ok "only clean.sh was scanned (files=1)" ;; *) bad "scope: $LINT_OUT" ;; esac

T5="$TMP/lt5"; mk_tree "$T5"
lint_run "$T5" "$TMP/empty.tsv"
eq "a root with no file in scope cannot tell (a mistyped --root is not a clean tree): stdout empty" "$LINT_OUT" ""
eq "a root with no file in scope: exit 2" "$LINT_RC" "2"

T4="$TMP/lt4"; mk_tree "$T4"; echo 'git for-each-ref --sort=-committerdate' > "$T4/scripts/g.py"
row reviewed scripts/g.py 'for-each-ref' - "git refs" > "$TMP/r3.tsv"
lint_run "$T4" "$TMP/r3.tsv"; eq "a reviewed row covers a non-bead sort" "$LINT_RC" "0"
case "$LINT_OUT" in *"reviewed=1"*) ok "reviewed=1 in the summary" ;; *) bad "$LINT_OUT" ;; esac
{ row ext engine:internal/x.go - ga-9t9acg.7 "engine"; row consumer scripts/g.py 'for-each-ref' UNASSIGNED "found later"; } > "$TMP/r4.tsv"
lint_run "$T4" "$TMP/r4.tsv"; eq "an ext row is not scanned; an UNASSIGNED consumer is allowed" "$LINT_RC" "0"
case "$LINT_OUT" in *"unassigned=1"*"ext=1"*) ok "unassigned=1 ext=1 reported" ;; *) bad "$LINT_OUT" ;; esac
bad_row() { # <label> <registry text>
  printf '%s' "$2" > "$TMP/badrow.tsv"; lint_run "$T4" "$TMP/badrow.tsv"
  if [ "$LINT_RC" -eq 1 ] && printf '%s\n' "$LINT_OUT" | grep -q 'LINT FAIL'; then ok "$1 -> fail"; else bad "$1: rc=$LINT_RC out=[$LINT_OUT]"; fi
}
bad_row "a row with four columns" "$(printf 'consumer\tscripts/g.py\tfor-each-ref\tga-9t9acg.2\n')
"
bad_row "an unknown kind" "$(row bogus scripts/g.py for-each-ref ga-9t9acg.2 n)
"
bad_row "a consumer owned by a nobody" "$(row consumer scripts/g.py for-each-ref bob n)
"
bad_row "a reviewed row with an owner" "$(row reviewed scripts/g.py for-each-ref ga-9t9acg.2 n)
"
bad_row "an ext row with a regex" "$(row ext engine:x.go 'x' ga-9t9acg.7 n)
"
bad_row "a regex that does not compile" "$(row reviewed scripts/g.py '(' - n)
"
bad_row "a row with an empty note" "$(row reviewed scripts/g.py for-each-ref - ' ')
"
bad_row "a row for a file that does not exist" "$(row reviewed scripts/nope.py x - n)
$(row reviewed scripts/g.py for-each-ref - n)
"
bad_row "duplicate rows" "$(row reviewed scripts/g.py for-each-ref - n)
$(row reviewed scripts/g.py for-each-ref - n2)
"
out="$(python3 -I -B "$PY" lint --root "$T4" --registry "$TMP/does-not-exist.tsv" 2>"$TMP/lint.err")"; rc=$?
eq "a missing registry cannot tell: stdout empty" "$out" ""; eq "a missing registry: exit 2" "$rc" "2"
fi

# ── (j) mutation controls ───────────────────────────────────────────────────────────────────────
# mutate <src> <dest> OLD NEW [OLD NEW ...] — every OLD must occur exactly once, and the file must change.
mutate() {
  python3 -I -B -c '
import sys
src, dest, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
text = orig = open(src, encoding="utf-8").read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if text.count(old) != 1:
        sys.stderr.write("mutation target occurs %d times (want 1): %r\n" % (text.count(old), old)); sys.exit(3)
    text = text.replace(old, new)
if text == orig:
    sys.stderr.write("mutation changed nothing\n"); sys.exit(3)
open(dest, "w", encoding="utf-8").write(text)
' "$1" "$2" "${@:3}"
}
# must_fail <name> <what is mutated: lib|py|pyi> <OLD NEW ...> — the mutant has to make this file fail
# (lib: the library; py: the lint, run by (R); pyi: the entry point, run by (i))
must_fail() {
  local name="$1" kind="$2"; shift 2
  local dest="$TMP/mut-$name" rc
  if [ "$kind" = "lib" ]; then
    mutate "$LIB" "$dest.sh" "$@" 2>"$TMP/mut.err" || { bad "mutant $name could not be built: $(cat "$TMP/mut.err")"; return; }
    WO_FAILFAST=1 WO_SKIP_MUTATION=1 WO_LIB_UNDER_TEST="$dest.sh" bash "$SELF" >"$TMP/mut.out" 2>&1; rc=$?
  elif [ "$kind" = "pyi" ]; then
    # a mutant of work_order.py that is exercised by section (i): it lives in a root of its own whose `packs`
    # is a symlink to the real tree, so its default library is the REAL one (an override notice that fires
    # only because the mutant sits elsewhere would "kill" a survivor for the wrong reason)
    local mroot="$TMP/mutroot-$name"; mkdir -p "$mroot/scripts" && ln -s "$ROOT/packs" "$mroot/packs" || { bad "mutant $name: could not build its root"; return; }
    mutate "$PY" "$mroot/scripts/work_order.py" "$@" 2>"$TMP/mut.err" || { bad "mutant $name could not be built: $(cat "$TMP/mut.err")"; return; }
    env -u WO_LIB_UNDER_TEST WO_FAILFAST=1 WO_ONLY=i WO_PY_UNDER_TEST="$mroot/scripts/work_order.py" bash "$SELF" >"$TMP/mut.out" 2>&1; rc=$?
  else
    mutate "$PY" "$dest.py" "$@" 2>"$TMP/mut.err" || { bad "mutant $name could not be built: $(cat "$TMP/mut.err")"; return; }
    WO_FAILFAST=1 WO_ONLY=R WO_PY_UNDER_TEST="$dest.py" bash "$SELF" >"$TMP/mut.out" 2>&1; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then bad "mutant $name SURVIVED — the selftest did not notice"
  elif ! grep -q '^  ✗' "$TMP/mut.out"; then bad "mutant $name crashed the selftest without failing a check (a broken mutant proves nothing): $(tail -2 "$TMP/mut.out" | tr '\n' ' ' | cut -c1-160)"
  else ok "mutant $name is killed by: $(grep -m1 '^  ✗' "$TMP/mut.out" | sed 's/^  ✗ //' | cut -c1-110)"; fi
}
if want j && [ "${WO_SKIP_MUTATION:-0}" != "1" ]; then
echo "== (j) mutation controls: each mutant of the library / lint must make this selftest fail"
KEY='[wo_prio_class, wo_type_class($o), ($e // 9999999999), (.id // "")]'
must_fail priority-only lib "$KEY" '[wo_prio_class]'
must_fail bug-before-feature lib 'index($t | ascii_downcase)) != null then 0' 'index($t | ascii_downcase)) != null then 3'
must_fail newest-first lib '($e // 9999999999), (.id // "")]' '(-($e // 0)), (.id // "")]'
must_fail today-bd-default lib "$KEY" '[wo_prio_class, (-($e // 0)), (.id // "")]'
must_fail today-pilot-bug-first lib "$KEY" \
  '[wo_prio_class, (if (.issue_type // "") == "bug" then 0 elif (.issue_type // "") == "feature" then 4 else 2 end), (-($e // 0)), (.id // "")]'
must_fail age-as-text lib 'def wo_age($o): wo_epoch(wo_age_src($o));' 'def wo_age($o): (wo_age_src($o) | if type == "string" then . else null end);' \
  '($e // 9999999999), (.id // "")]' '($e // "~"), (.id // "")]'
must_fail no-warn lib '| select(length > 0)' '| select(length < 0)'
must_fail illegible-prio-is-p0 lib 'then .priority else 5 end;' 'then .priority else 0 end;'
must_fail illegible-age-first lib '($e // 9999999999), (.id // "")]' '($e // 0), (.id // "")]'
must_fail illegible-type-is-known lib 'if ($t | type) != "string" or $t == "" then 2' 'if ($t | type) != "string" or $t == "" then 1'
must_fail story-not-feature lib ': "${WORK_ORDER_FEATURE_TYPES=feature story}"' ': "${WORK_ORDER_FEATURE_TYPES=feature}"'
must_fail type-only-issue_type lib '(.issue_type // .type) as $t' '.issue_type as $t'
must_fail no-id-tiebreak lib '($e // 9999999999), (.id // "")]' '($e // 9999999999)]'
must_fail reclaim-ignores-label lib 'test("\\Apilot:reclaim-count:[1-9][0-9]*\\z")' 'test("\\Apilot:reclaim-never\\z")'
must_fail reclaim-zero-counts lib '[1-9][0-9]*\\z' '[0-9]+\\z'
must_fail field-falls-back-to-created lib 'elif $a == "field" then ._wo_age' 'elif $a == "field" then (._wo_age // .created_at)'
must_fail failure-prints-empty-array lib 'input kept out of the order)" >&2
    return 2' 'input kept out of the order)" >&2
    echo "[]"; return 0'
must_fail head-failure-prints-null lib 'stdin is not exactly one JSON array of bead objects)" >&2
    return 2' 'x)" >&2
    echo null; return 0'
must_fail empty-feature-list-accepted lib 'elif ($f | length) == 0 then error("WORK_ORDER_FEATURE_TYPES is empty")' 'elif false then empty'
must_fail bad-age-accepted lib 'if ($age | IN("created", "field", "reclaim") | not) then error("age must be created, field or reclaim")' 'if false then empty'
must_fail side-effect-at-source lib ': "${WORK_ORDER_FEATURE_TYPES=feature story}"
' ': "${WORK_ORDER_FEATURE_TYPES=feature story}"
echo LEAK
'
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ]; then
  must_fail bash4-only-syntax lib ': "${WORK_ORDER_FEATURE_TYPES=feature story}"
' ': "${WORK_ORDER_FEATURE_TYPES=feature story}"
declare -A _wo_leak
'
else
  skip "bash4-only-syntax mutant: /bin/bash is not 3.x here, so it cannot tell"
fi
must_fail lint-never-unregistered py 'if not any(r["rx"].search(text) for r in mine):' 'if False:'
must_fail lint-never-stale py 'elif not any(r["rx"].search(t) for _n, t in code[r["file"]]):' 'elif False:'
must_fail lint-reads-comments py '_COMMENT_RE = re.compile(r"^\s*#")' '_COMMENT_RE = re.compile(r"^\s*#NEVER")'
must_fail lint-skips-selftests py 'SCOPE_SKIP = re.compile(r"(\.selftest\.(sh|py)$|/test_[^/]*\.py$|/work-order\.sh$|/work_order\.py$)")' 'SCOPE_SKIP = re.compile(r"(NEVER)")'
# the lows of the review: each is a mutant that reintroduces the defect
must_fail type-case-sensitive lib 'index($t | ascii_downcase)) != null then 0' 'index($t)) != null then 0'
must_fail feature-list-not-lowercased lib '($ft | ascii_downcase | gsub' '($ft | gsub'
must_fail env-feature-types-overwritten lib ': "${WORK_ORDER_FEATURE_TYPES=feature story}"' 'WORK_ORDER_FEATURE_TYPES="feature story"'
must_fail env-empty-feature-types-replaced lib ': "${WORK_ORDER_FEATURE_TYPES=feature story}"' ': "${WORK_ORDER_FEATURE_TYPES:=feature story}"'
must_fail calendar-rolls-over lib 'if $e != null and (try ($e | todateiso8601) catch null) == $t then $e else null end' '$e'
must_fail no-id-warn lib '(if (.id | type) != "string" or .id == "" then "id?" else empty end) ]' 'empty ]'
must_fail jq-missing-not-named lib 'if ! command -v jq >/dev/null 2>&1; then' 'if false; then'
must_fail bad-option-not-named lib 'unknown option: $1' 'bad option'
# attempt 3: the validator judged the REWRITTEN string, and a `$` anchor matches before a final newline
must_fail age-judged-after-rewrite lib 'capture("\\A(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?:Z|\\+00:00)\\z")] | .[0]) as $m' '1] | .[0]) as $m' \
  'else ($m.d + "Z") as $t' 'else ($s | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) as $t'
must_fail age-end-unanchored lib '(?:Z|\\+00:00)\\z")' '(?:Z|\\+00:00)")'
must_fail age-start-unanchored lib 'capture("\\A(?<d>' 'capture("(?<d>'
must_fail age-dollar-anchor lib '(?:Z|\\+00:00)\\z")' '(?:Z|\\+00:00)$")'
must_fail age-fraction-may-be-empty lib '(?:\\.[0-9]+)?(?:Z|' '(?:\\.[0-9]*)?(?:Z|'
must_fail reclaim-label-dollar-anchor lib 'test("\\Apilot:reclaim-count:[1-9][0-9]*\\z")' 'test("^pilot:reclaim-count:[1-9][0-9]*$")'
must_fail head-accepts-non-objects lib '      elif (.[0] | all(type == "object") | not) then error("input has an element that is not an object")
' ''
must_fail head-error-names-no-cause lib 'cannot tell (${msg:0:200}${msg:+; }stdin is not' 'cannot tell (stdin is not'
# WORK_ORDER_LIB in a daemon's environment: the python entry point must say it orders by another library
must_fail override-never-announced pyi '    if not os.environ.get("WORK_ORDER_LIB"):
        return None
' '    return None
'
must_fail override-always-announced pyi '    if os.path.realpath(lib) == os.path.realpath(_DEFAULT_LIB):
        return None
' ''
must_fail override-spelling-is-not-identity pyi 'os.path.realpath(lib) == os.path.realpath(_DEFAULT_LIB)' 'os.path.normpath(lib) == os.path.normpath(_DEFAULT_LIB)'
must_fail override-notice-has-no-path pyi 'override active: %s (not the town'"'"'s library %s); "' 'override active (not the town'"'"'s library %s); "' \
  '% (lib, os.path.normpath(_DEFAULT_LIB)))' '% (os.path.normpath(_DEFAULT_LIB),))'
# ...and on every way of "cannot tell" (the self-audit of the round-3 fix found the non-JSON branch without it)
must_fail override-lost-on-library-failure pyi 'raise WorkOrderUnknown(first + tail)' 'raise WorkOrderUnknown(first)'
must_fail override-lost-on-non-json pyi '"library output is not JSON: %s%s" % (exc, tail)' '"library output is not JSON: %s" % exc'
must_fail override-lost-on-non-array pyi 'raise WorkOrderUnknown("library output is not an array" + tail)' 'raise WorkOrderUnknown("library output is not an array")'
must_fail override-lost-when-library-cannot-run pyi 'raise WorkOrderUnknown(str(exc) + tail)' 'raise WorkOrderUnknown(str(exc))'
# the lint: every alternative of every idiom, every scope glob, every line of the printed claim
must_fail lint-drops-sort-flag-idiom py '("M2-sort-flag", r"--sort(?![A-Za-z-])"),' ''
must_fail lint-drops-pilot-sort-idiom py '("M3-pilot-sort-jq", r"_PILOT_SORT_JQ"),' ''
must_fail lint-drops-min_by-max_by py 'r"\b(?:sort_by|min_by|max_by)\((?:.*%s|[^)]*$)" % _FIELD' 'r"\b(?:sort_by)\((?:.*%s|[^)]*$)" % _FIELD'
must_fail lint-drops-open-sort_by py 'r"\b(?:sort_by|min_by|max_by)\((?:.*%s|[^)]*$)" % _FIELD' 'r"\b(?:sort_by|min_by|max_by)\((?:.*%s)" % _FIELD'
must_fail lint-drops-open-py-sort py 'r"(?:\.sort|\bsorted|\bmin|\bmax)\((?:.*\bkey=.*%s|[^)]*$)" % _FIELD' 'r"(?:\.sort|\bsorted|\bmin|\bmax)\((?:.*\bkey=.*%s)" % _FIELD'
must_fail lint-drops-py-min-max py 'r"(?:\.sort|\bsorted|\bmin|\bmax)\(' 'r"(?:\.sort|\bsorted)\('
must_fail lint-drops-shell-limit py 'r"(?:--limit(?:=|\s+)%s|' 'r"(?:--NEVER(?:=|\s+)%s|'
must_fail lint-drops-list-form-limit py '[\"'\'']--limit[\"'\'']\s*,\s*%s' '[\"'\'']--NEVER[\"'\'']\s*,\s*%s'
must_fail lint-drops-list-form-n py '_N_FLAG_LIST = _NOT_OTHER_TOOL + r""".*["'\'']-n["'\'']\s*,\s*""" + _LIST_VALUE' '_N_FLAG_LIST = _NOT_OTHER_TOOL + r""".*["'\'']-NEVER["'\'']\s*,\s*""" + _LIST_VALUE'
must_fail lint-drops-shell-n py '-n(?:=|\s+)""" + _VALUE' '-NEVER(?:=|\s+)""" + _VALUE'
must_fail lint-drops-dollar-bd py '_BD_WORD = r"""(?:\bbd\b|\$\{?[A-Za-z_]*BD[A-Za-z_]*\}?)"""' '_BD_WORD = r"""(?:\bbd\b)"""'
must_fail lint-counts-zero-as-a-window py '
_VALUE = r"""["'\'']?(?!0(?!\d))(?:' '
_VALUE = r"""["'\'']?(?:'
must_fail lint-flags-tail-n py '_NOT_OTHER_TOOL = r"""^(?!.*\[\s*["'\''](?:tail|head|sed|sysctl|sort|jq|cut)["'\''])"""' '_NOT_OTHER_TOOL = r"""^"""'
must_fail lint-empty-glob-is-quiet py '        if len(files) == before:' '        if False:'
must_fail lint-hides-glob-note py '        sys.stdout.write("LINT NOTE: %s\n" % item)' '        pass'
must_fail lint-uncounted-empty-globs py 'len(empty_globs))
    notes' '0)
    notes'
must_fail lint-hides-scope py '    sys.stdout.write("LINT SCOPE: %s (not: selftests, test_*.py, work-order.sh, work_order.py)\n" % " ".join(SCOPE_GLOBS))' '    pass'
must_fail lint-hides-sees py '    sys.stdout.write("LINT SEES: %s\n" % LINT_SEES)' '    pass'
must_fail lint-hides-not-seen py '    sys.stdout.write("LINT NOT SEEN: %s\n" % LINT_NOT_SEEN)' '    pass'
must_fail lint-not-seen-lies py 'a hand-rolled min/loop; any file outside LINT SCOPE "
                 "(docs/, other directories, other repos)")' 'a hand-rolled min/loop")'
IFS=' ' read -r -a MUT_GLOBS <<< "$EXPECT_GLOBS"
for g in "${MUT_GLOBS[@]}"; do
  must_fail "lint-drops-scope-glob-${g//[^A-Za-z0-9]/_}" py "    \"$g\",
" ""
done
must_fail lint-empty-scope-is-clean py '    if not scope:
' '    if False:
'
fi

finish
