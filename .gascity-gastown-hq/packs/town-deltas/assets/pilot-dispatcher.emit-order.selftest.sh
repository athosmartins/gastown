#!/usr/bin/env bash
# pilot-dispatcher.emit-order.selftest.sh — ga-9t9acg.3 (programa ga-9t9acg): the queue the Pilot emits to the
# painel (_pilot_emit_dispatchable -> PILOT_DISPATCHABLE_FILE) is ordered by the ONE shared rule in
# scripts/work-order.sh (priority > type, feature first > age, oldest first) and not by a sort of its own.
#
# Why it exists. The emit used to `sort_by([priority, created_at, id])`: oldest-first with NO type tier, while
# _top_candidate dispatched bug-first/newest-first. The "position in the queue" that the painel and
# approved-state-reconciler.py (_pilot_queue_position) print was therefore not the order of anything.
#
# What is under test is the REAL _pilot_emit_dispatchable, cut out of the dispatcher with sed (same idiom as
# pilot-dispatcher.exclusion-trace.selftest.sh); only its inputs are stubbed: the per-store query
# (_emit_query_one -> a fixture) and `gc rig list` (no rigs). Everything else — the order step, the projection,
# the atomic write, the logging — is the dispatcher's own text, run under the dispatcher's own
# `set -euo pipefail`.
#
# Sections:
#   (a) the order: a mixed fixture comes out in the rule's order — LITERAL expected ids, written by hand, not
#       computed by the library, so a library that drifted fails here too; shuffling the input changes nothing;
#       the order equals work_order_sort called directly on the same input (parity).
#   (b) the painel contract (keys, count, ttl) is unchanged — only the order moved.
#   (c) THREE states: an illegible field keeps the bead (at the end of its class) AND its `work-order WARN:`
#       line reaches the log (the emit body runs under 2>/dev/null, which would swallow it);
#       "cannot tell" (library missing / exit 2 / empty stdout) writes NOTHING and leaves the previous file
#       byte-identical, with a WARN that says why; an empty queue is a real, fresh `count 0` file.
#   (d) the dispatcher sources the library from next to itself, and a missing library degrades loudly.
#   (e) MUTATION CONTROLS: each mutant below reverts one property and must make THIS file fail:
#       the old sort, a swallowed stderr, "cannot tell" read as an empty queue, and three library mutants
#       (priority only, bug before feature, newest first).
#
# Env: EO_DISPATCHER_UNDER_TEST / EO_LIB_UNDER_TEST point at a mutant (the mutation controls use them);
#      EO_SKIP_MUTATION=1 skips (e) (the mutants' own runs). Exit 0 iff every check holds.

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SELF="$SELF_DIR/$(basename "$SELF")"
DISPATCHER="${EO_DISPATCHER_UNDER_TEST:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="${EO_LIB_UNDER_TEST:-$SELF_DIR/scripts/work-order.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$LIB" ]        || { echo "FATAL: work-order.sh not found at $LIB" >&2; exit 2; }
command -v jq >/dev/null 2>&1      || { echo "FATAL: jq is not on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not on PATH" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-emit-order-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

OUT="$WORK/pilot-dispatchable.json"

extract_fn() { sed -n "/^$1() {/,/^}\$/p" "$DISPATCHER"; }
LOG_FN="$(grep '^log()' "$DISPATCHER")"
WARN_FN="$(grep '^warn()' "$DISPATCHER")"
EMIT_FN="$(extract_fn _pilot_emit_dispatchable)"
if [ -z "$LOG_FN" ] || [ -z "$WARN_FN" ] || [ -z "$EMIT_FN" ]; then
  echo "FATAL: log()/warn()/_pilot_emit_dispatchable() not found in $DISPATCHER" >&2
  exit 2
fi
# The age constant the dispatcher defines next to the library source; the harness has to hand the same one.
WO_AGE="$(sed -n 's/^_PILOT_WORK_ORDER_AGE="\([a-z]*\)".*/\1/p' "$DISPATCHER" | head -n 1)"

# emit_run <fixture-json> <lib-file|-> — run the dispatcher's own _pilot_emit_dispatchable against a fixture.
# stdout = the dispatcher's log lines; the file written (or not) is $OUT. `-` sources no library at all.
# A fresh subshell each time, under the dispatcher's own `set -euo pipefail`.
emit_run() {
  local fixture="$1" lib="$2"
  (
    set -euo pipefail
    GC_CITY=/nonexistent-city-for-selftest
    PILOT_EMIT_DISPATCHABLE=1
    PILOT_EMITTED_DONE=0
    PILOT_DISPATCHABLE_TTL=1800
    PILOT_DISPATCHABLE_FILE="$OUT"
    _PILOT_WORK_ORDER_AGE="${WO_AGE:-created}"
    eval "$LOG_FN"
    eval "$WARN_FN"
    gc_json_or_unknown() { printf '%s' '{"rigs":[]}'; }
    _emit_query_one() { printf '%s' "$fixture"; }
    if [ "$lib" != "-" ]; then source "$lib"; fi
    eval "$EMIT_FN"
    _pilot_emit_dispatchable
  )
}

ids_of() { jq -r '[.items[].id] | join(",")' "$OUT" 2>/dev/null; }

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────
# bead <id> <priority|-> <type> <created_at> — `-` leaves the field out. Every bead carries the fields the
# real _emit_query_one hands over (labels, metadata, _emit_store).
bead() {
  jq -cn --arg id "$1" --arg p "$2" --arg t "$3" --arg c "$4" '
    {id:$id, title:("bead " + $id), issue_type:$t, created_at:$c, assignee:null, labels:[],
     metadata:{"story.rig":"whatsapp_automation"}, _emit_store:"hq"}
    + (if $p == "-" then {} else {priority:($p|tonumber)} end)'
}
arr() { local first=1 b; printf '['; for b in "$@"; do [ "$first" = 1 ] || printf ','; first=0; printf '%s' "$b"; done; printf ']'; }

# The mixed fixture. The rule's order is written out by hand:
#   P0 features, oldest first : f-old (01-02), f-new (03-01)
#   P0 not features, oldest   : b-old (01-01), t-mid (02-01)
#   P1 features / P1 others   : p1-f, p1-b ; then P2 : p2-b
# The OLD emit (priority > created_at > id, no type tier) gives b-old,f-old,t-mid,f-new,p1-b,p1-f,p2-b.
B_OLD="$(bead b-old 0 bug     2026-01-01T00:00:00Z)"
F_OLD="$(bead f-old 0 feature 2026-01-02T00:00:00Z)"
T_MID="$(bead t-mid 0 task    2026-02-01T00:00:00Z)"
F_NEW="$(bead f-new 0 feature 2026-03-01T00:00:00Z)"
P1_F="$(bead p1-f   1 feature 2026-01-15T00:00:00Z)"
P1_B="$(bead p1-b   1 bug     2026-01-01T00:00:00Z)"
P2_B="$(bead p2-b   2 bug     2025-12-01T00:00:00Z)"
MIXED="$(arr "$B_OLD" "$F_OLD" "$T_MID" "$F_NEW" "$P1_F" "$P1_B" "$P2_B")"
MIXED_REVERSED="$(arr "$P2_B" "$P1_B" "$P1_F" "$F_NEW" "$T_MID" "$F_OLD" "$B_OLD")"
EXPECTED_MIXED="f-old,f-new,b-old,t-mid,p1-f,p1-b,p2-b"

# ── (a) the order ───────────────────────────────────────────────────────────────────────────────────────
echo "pilot-dispatcher.emit-order.selftest (ga-9t9acg.3)"
echo "== (a) the emitted queue follows priority > type (feature first) > age (oldest first)"
rm -f "$OUT"
emit_run "$MIXED" "$LIB" >"$WORK/a1.log" 2>&1
GOT="$(ids_of)"
if [ "$GOT" = "$EXPECTED_MIXED" ]; then ok "mixed fixture comes out as $EXPECTED_MIXED"
else bad "mixed fixture order is [$GOT], want [$EXPECTED_MIXED] (the old emit gives b-old,f-old,t-mid,f-new,p1-b,p1-f,p2-b)"; fi

rm -f "$OUT"
emit_run "$MIXED_REVERSED" "$LIB" >"$WORK/a2.log" 2>&1
GOT_REV="$(ids_of)"
[ "$GOT_REV" = "$EXPECTED_MIXED" ] && ok "the same beads in the reverse input order give the same queue" \
  || bad "input order leaked into the queue: [$GOT_REV]"

DIRECT="$(printf '%s' "$MIXED" | ( set -euo pipefail; source "$LIB"; work_order_sort --age "${WO_AGE:-created}" ) 2>/dev/null | jq -r '[.[].id] | join(",")' 2>/dev/null || true)"
if [ -n "$DIRECT" ] && [ "$DIRECT" = "$GOT" ]; then ok "parity: the file's order == work_order_sort --age ${WO_AGE:-created} on the same input"
else bad "parity broken: file [$GOT] vs library [$DIRECT]"; fi

grep -qE '^_PILOT_WORK_ORDER_AGE="created"' "$DISPATCHER" \
  && ok "the age source is the documented one (created_at), defined once as _PILOT_WORK_ORDER_AGE" \
  || bad "_PILOT_WORK_ORDER_AGE=\"created\" is not defined in the dispatcher"

# ── (b) the painel contract ─────────────────────────────────────────────────────────────────────────────
echo "== (b) the painel contract is untouched: only the order moved"
rm -f "$OUT"
emit_run "$MIXED" "$LIB" >"$WORK/b.log" 2>&1
KEYS="$(jq -c '[.items[0] | keys[]]' "$OUT" 2>/dev/null)"
[ "$KEYS" = '["assignee","created_at","id","priority","rig","store","title","type"]' ] \
  && ok "each item has exactly id,title,type,rig,priority,created_at,assignee,store" || bad "item keys changed: $KEYS"
jq -e '.count == (.items | length) and .count == 7 and .ttl_seconds == 1800 and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$OUT" >/dev/null 2>&1 \
  && ok "count == items == 7, ttl_seconds 1800, generated_at is ISO UTC" || bad "envelope (count/ttl/generated_at) changed: $(head -c 200 "$OUT" 2>/dev/null)"
jq -e '.items[] | select(.id == "f-old") | .type == "feature" and .rig == "whatsapp_automation" and .priority == 0 and .store == "hq" and .created_at == "2026-01-02T00:00:00Z" and .assignee == "" and .title == "bead f-old"' "$OUT" >/dev/null 2>&1 \
  && ok "field values survive the projection (type, rig from metadata, store, assignee \"\")" || bad "projected field values changed: $(jq -c '.items[] | select(.id == "f-old")' "$OUT" 2>/dev/null)"

# ── (c) three states ────────────────────────────────────────────────────────────────────────────────────
echo "== (c1) an illegible field keeps the bead at the end of its class, and its WARN reaches the log"
D_P0="$(bead d-p0 0 feature 2026-01-01T00:00:00Z)"
D_P4="$(bead d-p4 4 task    2026-01-01T00:00:00Z)"
D_NOPRIO="$(bead d-noprio - feature 2026-01-01T00:00:00Z)"
D_BADDATE="$(bead d-baddate 1 feature garbage)"
ILLEGIBLE="$(arr "$D_NOPRIO" "$D_P4" "$D_BADDATE" "$D_P0")"
rm -f "$OUT"
emit_run "$ILLEGIBLE" "$LIB" >"$WORK/c1.log" 2>&1
GOT_ILL="$(ids_of)"
[ "$GOT_ILL" = "d-p0,d-baddate,d-p4,d-noprio" ] \
  && ok "no bead is dropped and none is promoted: d-p0,d-baddate,d-p4,d-noprio (no priority sorts behind P4)" \
  || bad "illegible-field order is [$GOT_ILL], want [d-p0,d-baddate,d-p4,d-noprio]"
grep -q 'work-order WARN: d-noprio: prio?' "$WORK/c1.log" \
  && ok "the log carries the library's WARN for the bead with no priority" || bad "the WARN for d-noprio (prio?) never reached the log: $(grep -c . "$WORK/c1.log") line(s)"
grep -q 'work-order WARN: d-baddate: age?' "$WORK/c1.log" \
  && ok "the log carries the library's WARN for the unreadable created_at" || bad "the WARN for d-baddate (age?) never reached the log"
[ "$(jq '.items[] | select(.id == "d-noprio") | .priority' "$OUT" 2>/dev/null)" = "99" ] \
  && ok "the projection still shows an unreadable priority as 99 (the painel contract), the WARN is what tells the truth" \
  || bad "projection of the unreadable priority changed"

echo "== (c2) cannot tell is not an empty queue: nothing is written, the previous file stays byte-identical"
SENTINEL='{"generated_at":"2026-01-01T00:00:00Z","ttl_seconds":1800,"count":3,"items":[{"id":"previous-a"},{"id":"previous-b"},{"id":"previous-c"}]}'
cannot_tell_case() {   # <name> <lib-file|->
  printf '%s\n' "$SENTINEL" > "$OUT"
  cp "$OUT" "$WORK/sentinel.copy"
  emit_run "$MIXED" "$2" >"$WORK/c2-$1.log" 2>&1
  if cmp -s "$OUT" "$WORK/sentinel.copy"; then ok "$1: the previous file is byte-identical (no fresh file, no count 0)"
  else bad "$1: the previous file was rewritten: $(head -c 160 "$OUT" 2>/dev/null)"; fi
  if grep -q 'WARN' "$WORK/c2-$1.log" && grep -qi 'previous' "$WORK/c2-$1.log"; then ok "$1: a WARN says the previous file was kept"
  else bad "$1: no WARN that the previous file was kept: $(tail -n 3 "$WORK/c2-$1.log" | tr '\n' '|' | cut -c1-200)"; fi
}
cannot_tell_case "library not loaded (work_order_sort undefined)" "-"
printf '%s\n' 'work_order_sort() { echo "work-order ERROR: stub: cannot tell" >&2; return 2; }' > "$WORK/lib-exit2.sh"
cannot_tell_case "library exits 2" "$WORK/lib-exit2.sh"
grep -q 'work-order ERROR: stub: cannot tell' "$WORK/c2-library exits 2.log" \
  && ok "library exits 2: the library's own ERROR line is in the log (the reason is visible)" || bad "library exits 2: the reason never reached the log"
printf '%s\n' 'work_order_sort() { cat >/dev/null; return 0; }' > "$WORK/lib-empty.sh"
cannot_tell_case "library exits 0 with EMPTY stdout" "$WORK/lib-empty.sh"

echo "== (c3) an empty queue is a real answer: a fresh count 0 file, no WARN"
printf '%s\n' "$SENTINEL" > "$OUT"
emit_run '[]' "$LIB" >"$WORK/c3.log" 2>&1
jq -e '.count == 0 and (.items | length) == 0 and .generated_at != "2026-01-01T00:00:00Z"' "$OUT" >/dev/null 2>&1 \
  && ok "[] in -> a fresh {count:0, items:[]} file (the painel can tell 'out of work' from 'stale')" || bad "empty queue not written as a fresh count 0 file: $(head -c 160 "$OUT" 2>/dev/null)"
! grep -q 'WARN' "$WORK/c3.log" && ok "no WARN for a healthy empty queue" || bad "a healthy empty queue logged a WARN: $(grep WARN "$WORK/c3.log" | head -n 1)"

# ── (d) the library is sourced from next to the dispatcher ──────────────────────────────────────────────
echo "== (d) the dispatcher sources scripts/work-order.sh from its own directory, and degrades loudly without it"
BLOCK="$(sed -n '/^# SELFTEST-EXTRACT work-order-source: BEGIN$/,/^# SELFTEST-EXTRACT work-order-source: END$/p' "$DISPATCHER")"
if [ -z "$BLOCK" ]; then
  bad "the work-order-source block (SELFTEST-EXTRACT markers) is missing from the dispatcher"
else
  mkdir -p "$WORK/assets/scripts"
  cp "$LIB" "$WORK/assets/scripts/work-order.sh"
  {
    echo 'set -euo pipefail'
    echo "$WARN_FN"
    printf '%s\n' "$BLOCK"
    echo 'if type work_order_sort >/dev/null 2>&1; then echo LOADED; else echo NOT_LOADED; fi'
    echo 'echo "unset-sibling-var: ${_GC_WO_SIBLING-gone}"'
  } > "$WORK/assets/block.sh"
  R1="$(bash "$WORK/assets/block.sh" 2>&1; echo "rc=$?")"
  case "$R1" in *LOADED*rc=0) [ "${R1#*NOT_LOADED}" = "$R1" ] && ok "next to the script: scripts/work-order.sh is sourced (work_order_sort defined), rc 0 under set -euo pipefail" || bad "library not loaded from scripts/: $R1";; *) bad "library not loaded from scripts/: $R1";; esac
  case "$R1" in *"unset-sibling-var: gone"*) ok "the sibling-path variable is unset again after the block";; *) bad "the block leaks _GC_WO_SIBLING: $R1";; esac
  rm -f "$WORK/assets/scripts/work-order.sh"
  R2="$(bash "$WORK/assets/block.sh" 2>&1; echo "rc=$?")"
  case "$R2" in *NOT_LOADED*rc=0) ok "library absent: the script does NOT abort (rc 0) and work_order_sort stays undefined";; *) bad "library absent: wrong behaviour: $R2";; esac
  case "$R2" in *WARN*work-order.sh*) ok "library absent: a WARN names the missing file";; *) bad "library absent: no WARN naming work-order.sh: $R2";; esac
fi

# ── (e) mutation controls ───────────────────────────────────────────────────────────────────────────────
mutate() {   # <src> <dest> OLD NEW [OLD NEW ...] — every OLD occurs exactly once and the file must change
  python3 -I - "$@" <<'PY'
import sys
src, dest, *pairs = sys.argv[1:]
text = open(src, encoding="utf-8").read()
orig = text
for old, new in zip(pairs[0::2], pairs[1::2]):
    if text.count(old) != 1:
        sys.stderr.write("mutation target occurs %d times (want 1): %r\n" % (text.count(old), old)); sys.exit(3)
    text = text.replace(old, new)
if text == orig:
    sys.stderr.write("mutation changed nothing\n"); sys.exit(3)
open(dest, "w", encoding="utf-8").write(text)
PY
}
# must_fail <name> <dispatcher|lib> OLD NEW ... — the mutant has to make a fresh run of this file FAIL a check.
must_fail() {
  local name="$1" what="$2" dest rc; shift 2
  dest="$WORK/mutant-$name.sh"
  if [ "$what" = "dispatcher" ]; then
    mutate "$DISPATCHER" "$dest" "$@" 2>"$WORK/mut.err" || { bad "mutant $name could not be built: $(cat "$WORK/mut.err")"; return; }
    EO_SKIP_MUTATION=1 EO_DISPATCHER_UNDER_TEST="$dest" EO_LIB_UNDER_TEST="$LIB" bash "$SELF" >"$WORK/mut.out" 2>&1; rc=$?
  else
    mutate "$LIB" "$dest" "$@" 2>"$WORK/mut.err" || { bad "mutant $name could not be built: $(cat "$WORK/mut.err")"; return; }
    EO_SKIP_MUTATION=1 EO_DISPATCHER_UNDER_TEST="$DISPATCHER" EO_LIB_UNDER_TEST="$dest" bash "$SELF" >"$WORK/mut.out" 2>&1; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then bad "mutant $name SURVIVED — this selftest did not notice"
  elif ! grep -q '^  ✗' "$WORK/mut.out"; then bad "mutant $name crashed the selftest without failing a check (a broken mutant proves nothing): $(tail -n 2 "$WORK/mut.out" | tr '\n' ' ' | cut -c1-160)"
  else ok "mutant $name is killed by: $(grep -m1 '^  ✗' "$WORK/mut.out" | sed 's/^  ✗ //' | cut -c1-110)"; fi
}

if [ "${EO_SKIP_MUTATION:-0}" != "1" ]; then
  echo "== (e) mutation controls: each mutant must make this selftest fail"
  # The dispatcher's wiring put back to what it did before this slice (the old sort, no type tier).
  must_fail "old-sort-in-the-emit" dispatcher \
    'work_order_sort --age "$_PILOT_WORK_ORDER_AGE" 2>"$_wo_err"' \
    "jq -c 'sort_by([ (.priority // 99), (.created_at // \"\"), (.id // \"\") ])' 2>\"\$_wo_err\""
  # The library's stderr thrown away, as the body's own `2>/dev/null` would do to it.
  must_fail "stderr-swallowed" dispatcher '2>"$_wo_err")' '2>/dev/null)'
  # "Cannot tell" read as an empty queue (the error/empty collapse the library's contract forbids).
  must_fail "cannot-tell-is-an-empty-queue" dispatcher '      _wo_ok=0' '      _wo_ok=1; _ordered="[]"'
  # The library itself, three ways the rule can rot: ignore the type, bugs first, newest first.
  WO_KEY='def wo_key($o): (wo_age($o)) as $e | [wo_prio_class, wo_type_class($o), ($e // 9999999999), (.id // "")];'
  must_fail "lib-priority-only" lib "$WO_KEY" 'def wo_key($o): (wo_age($o)) as $e | [wo_prio_class, 0, ($e // 9999999999), (.id // "")];'
  must_fail "lib-bug-before-feature" lib "$WO_KEY" 'def wo_key($o): (wo_age($o)) as $e | [wo_prio_class, (if (.issue_type // "") == "bug" then 0 else 1 end), ($e // 9999999999), (.id // "")];'
  must_fail "lib-newest-first" lib "$WO_KEY" 'def wo_key($o): (wo_age($o)) as $e | [wo_prio_class, wo_type_class($o), (0 - ($e // 0)), (.id // "")];'
fi

echo
echo "pilot-dispatcher.emit-order.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
