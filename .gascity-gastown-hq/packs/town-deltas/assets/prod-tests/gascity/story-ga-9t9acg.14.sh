#!/usr/bin/env bash
# prod-tests/gascity/story-ga-9t9acg.14.sh — prod test for ga-9t9acg.14 (programa ga-9t9acg, "Ordem única"): the "dano ao vivo"
# exception, ported from the gate (ga-emgkvn) into the work-order lib.
#
# What "deployed and correct" means for a sort rule that every pipeline stage is going to call:
#   (1) the pieces are on disk in the LIVE tree and parse (work-order.sh, work_order.py);
#   (2) through the LIVE lib, a P0 bug labelled impacto:dano-ao-vivo comes out BEFORE an older P0 feature — the one thing the rule
#       exists to do, read back with this test's own jq, not with the lib;
#   (3) the exception is as narrow as the Athos decision of 06/10 ("Bug com dano ao vivo primeiro"): it needs priority exactly 0,
#       issue_type exactly "bug" and the label exactly `impacto:dano-ao-vivo`. A P1 bug with the label, a P0 feature with the label,
#       a P0 bug with a look-alike label stay where the plain rule (priority > type > age) puts them;
#   (4) the labels have three states, never collapsed: a `labels` key that is ABSENT (bd omits it for a bead with no label) is "does
#       not have it" and says nothing; one that is there but cannot be read (null, a string) is treated as WITHOUT the label and, on a
#       P0 bug, said out loud (`work-order WARN: <id>: labels?`) — the sort never promotes on a doubt, and never doubts in silence;
#   (5) inside P0 the rest of the rule is intact: dano bugs, then features, then the rest, oldest first inside each class;
#   (6) the Python entry point (what the consumers outside the shell call) orders the same way — it runs the same lib, so this is a
#       check that nobody put a second implementation next to it.
# Everything runs on scratch beads in a scratch dir: it reads no live bead, calls no API and spends nothing.
#
# Called by run.sh after deploy (STORY_ID=ga-9t9acg.14). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
LIB="$ASSETS/scripts/work-order.sh"
PY="$CITY/scripts/work_order.py"

log()  { echo "[prod-test:gascity ga-9t9acg.14] $*"; }
fail() { echo "[prod-test:gascity ga-9t9acg.14] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ──────────────────────────────────────────────────────────────
[[ -f "$LIB" ]] || fail "not deployed: $LIB"
bash -n "$LIB" || fail "does not parse under bash: $LIB"
[[ -f "$PY" ]] || fail "not deployed: $PY"
command -v jq >/dev/null 2>&1 || fail "jq missing — the lib cannot sort"
command -v python3 >/dev/null 2>&1 || fail "python3 missing — work_order.py cannot run"
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$PY" || fail "does not parse under python3: $PY"
log "work-order.sh and work_order.py are deployed and parse ✓"

# the deployed lib must carry the exception at all (a deploy of the previous version would pass every other check of this test's
# preamble and fail only at (2) — say which it is)
grep -q 'impacto:dano-ao-vivo' "$LIB" || fail "the deployed work-order.sh does not mention impacto:dano-ao-vivo — the exception is not in the live lib"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-9t9acg14.XXXXXX")" || fail "no scratch dir"
trap 'rm -rf "$S"' EXIT

# bead <id> <prio> <type> <created_at> <labels-json | ABSENT>
bead() {
  if [[ "$5" == ABSENT ]]; then
    jq -cn --arg id "$1" --argjson p "$2" --arg t "$3" --arg c "$4" '{id:$id, priority:$p, issue_type:$t, created_at:$c}'
  else
    jq -cn --arg id "$1" --argjson p "$2" --arg t "$3" --arg c "$4" --argjson l "$5" '{id:$id, priority:$p, issue_type:$t, created_at:$c, labels:$l}'
  fi
}
arr() { jq -cs '.'; }
D='["impacto:dano-ao-vivo"]'

# sort_ids <engine: lib|py> <file> — the ids of the file's beads in the order the engine gives, comma-joined; stderr is kept in $S/err.
# The ids are read with this test's own jq.
sort_ids() {
  local eng="$1" f="$2" out rc=0
  if [[ "$eng" == lib ]]; then
    out="$(bash -c '. "$1" && work_order_sort' _ "$LIB" < "$f" 2> "$S/err")" || rc=$?
  else
    out="$(python3 -I "$PY" sort < "$f" 2> "$S/err")" || rc=$?
  fi
  [[ "$rc" -eq 0 && -n "$out" ]] || { echo "CANNOT-TELL(rc=$rc)"; return 0; }
  printf '%s' "$out" | jq -r '[.[].id] | join(",")'
}
check_order() { # <engine> <what> <file> <want>
  local got; got="$(sort_ids "$1" "$3")"
  [[ "$got" == "$4" ]] || fail "[$1] $2: expected [$4], got [$got] (stderr: $(tr '\n' '|' < "$S/err"))"
}

# ── 2. the point: a P0 dano bug goes before an OLDER P0 feature ───────────────────────────────────────────────────
{
  bead feat-old 0 feature 2026-08-01T00:00:00Z '[]'
  bead bug-dano 0 bug     2026-09-20T00:00:00Z "$D"
  bead bug-plain 0 bug    2026-08-15T00:00:00Z '["area:x"]'
} | arr > "$S/point.json"
for eng in lib py; do
  check_order "$eng" "P0 dano bug, P0 feature (older), P0 plain bug (older than the dano one)" "$S/point.json" "bug-dano,feat-old,bug-plain"
done
log "a P0 bug with impacto:dano-ao-vivo comes out before the older P0 feature and the older P0 plain bug, through the lib and through work_order.py ✓"

# ── 3. the exception is exactly as wide as the decision ───────────────────────────────────────────────────────────
# the plain rule is priority > type > age; each case below puts the labelled bead where that rule puts it
{ bead p1-dano 1 bug 2026-09-25T00:00:00Z "$D"; bead p1-feat 1 feature 2026-09-20T00:00:00Z '[]'; bead p0-last 0 task 2026-09-30T00:00:00Z '[]'; } | arr > "$S/p1.json"
check_order lib "a P1 bug with the label is NOT promoted (inside P1 the features still go first); every P0 still goes before every P1" "$S/p1.json" "p0-last,p1-feat,p1-dano"
{ bead f-dano 0 feature 2026-09-25T00:00:00Z "$D"; bead f-old 0 feature 2026-08-01T00:00:00Z '[]'; } | arr > "$S/feat.json"
check_order lib "a P0 FEATURE with the label is not a bug: oldest first, the label moves nothing" "$S/feat.json" "f-old,f-dano"
{ bead t-dano 0 task 2026-09-25T00:00:00Z "$D"; bead t-feat 0 feature 2026-09-26T00:00:00Z '[]'; } | arr > "$S/task.json"
check_order lib "a P0 TASK with the label is not a bug: the P0 feature is still first" "$S/task.json" "t-feat,t-dano"
{ bead b-case 0 Bug 2026-09-25T00:00:00Z "$D"; bead b-feat 0 feature 2026-09-26T00:00:00Z '[]'; } | arr > "$S/case.json"
check_order lib "issue_type \"Bug\" (not exactly \"bug\") is not promoted: the doubt goes to the plain rule" "$S/case.json" "b-feat,b-case"
for lab in 'impacto:dano' 'Impacto:Dano-Ao-Vivo' 'x-impacto:dano-ao-vivo' 'impacto:dano-ao-vivo-x'; do
  { bead look 0 bug 2026-09-25T00:00:00Z "[\"$lab\"]"; bead lf 0 feature 2026-09-26T00:00:00Z '[]'; } | arr > "$S/look.json"
  check_order lib "the look-alike label '$lab' does not count: the label is exactly impacto:dano-ao-vivo" "$S/look.json" "lf,look"
done
log "narrow: P1 bug / P0 feature / P0 task with the label, issue_type \"Bug\", and look-alike labels are all left to the plain rule ✓"

# ── 4. the three states of labels ────────────────────────────────────────────────────────────────────────────────
{ bead ab-bug 0 bug 2026-09-25T00:00:00Z ABSENT; bead ab-feat 0 feature 2026-09-26T00:00:00Z '[]'; } | arr > "$S/absent.json"
check_order lib "labels key ABSENT = does not have it: the P0 feature goes first" "$S/absent.json" "ab-feat,ab-bug"
grep -q 'labels?' "$S/err" && fail "an ABSENT labels key was reported as unreadable — bd omits the key for a bead with no label, that is not a doubt: $(cat "$S/err")"
for bad in null '"impacto:dano-ao-vivo"' '{"impacto:dano-ao-vivo":true}' '["impacto:dano-ao-vivo", 7]'; do
  { bead un-bug 0 bug 2026-09-25T00:00:00Z "$bad"; bead un-feat 0 feature 2026-09-26T00:00:00Z '[]'; } | arr > "$S/unr.json"
  check_order lib "labels = $bad cannot be read: treated as WITHOUT the label (the sort never promotes on a doubt), so the feature goes first" "$S/unr.json" "un-feat,un-bug"
  grep -q 'work-order WARN: un-bug: labels?' "$S/err" || fail "labels = $bad on a P0 bug was treated as 'no' IN SILENCE — it must say work-order WARN: un-bug: labels? (stderr: $(tr '\n' '|' < "$S/err"))"
done
# ...and the doubt is only worth a line where the label could have moved the bead: a P0 feature with labels null is the plain rule, quietly
{ bead nf-a 0 feature 2026-09-26T00:00:00Z '[]'; bead nf-b 0 feature 2026-08-01T00:00:00Z null; } | arr > "$S/nonc.json"
check_order lib "labels null on a P0 FEATURE: the plain order, oldest first" "$S/nonc.json" "nf-b,nf-a"
grep -q 'labels?' "$S/err" && fail "labels null on a P0 feature raised a WARN — the label could not have moved it: $(cat "$S/err")"
log "labels: absent = does not have it (quiet); null / string / object / non-string element on a P0 bug = without the label + WARN labels?; same on a non-bug = quiet ✓"

# ── 5. the rest of the rule is intact inside P0 and outside it ─────────────────────────────────────────────────────
{
  bead z-task    0 task    2026-07-01T00:00:00Z '[]'
  bead y-feat-n  0 feature 2026-09-01T00:00:00Z '[]'
  bead x-feat-o  0 feature 2026-08-01T00:00:00Z '[]'
  bead w-dano-n  0 bug     2026-09-29T00:00:00Z "$D"
  bead v-dano-o  0 bug     2026-09-10T00:00:00Z "$D"
  bead u-p1-feat 1 feature 2026-06-01T00:00:00Z '[]'
  bead t-p1-dano 1 bug     2026-06-02T00:00:00Z "$D"
} | arr > "$S/full.json"
want="v-dano-o,w-dano-n,x-feat-o,y-feat-n,z-task,u-p1-feat,t-p1-dano"
check_order lib "dano bugs (oldest first), P0 features (oldest first), the other P0, then P1 by its own rule" "$S/full.json" "$want"
check_order py  "the same through work_order.py" "$S/full.json" "$want"
# the same beads in the reverse input order give the same output (the id is the last tie-break; nothing depends on the input order)
jq -c 'reverse' "$S/full.json" > "$S/full-rev.json"
check_order lib "the same beads in the reverse input order" "$S/full-rev.json" "$want"
log "inside P0: dano bugs, then features, then the rest, oldest first in each; P1 untouched; input order irrelevant ✓"

# ── 6. the library does not mention a second place that decides ─────────────────────────────────────────────────────
# work_order.py must run the lib, not carry a sort of its own (a Python-side re-implementation would make the two disagree the day
# the label changes)
grep -q 'impacto:dano-ao-vivo' "$PY" && fail "work_order.py names the dano label itself — the rule must live only in work-order.sh"
log "work_order.py carries no copy of the exception ✓"

log "PASS"
exit 0
