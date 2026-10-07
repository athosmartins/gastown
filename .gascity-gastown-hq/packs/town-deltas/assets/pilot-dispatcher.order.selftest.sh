#!/usr/bin/env bash
# pilot-dispatcher.order.selftest.sh — ga-9t9acg.2 (programa ga-9t9acg, slice R2)
#
# The rule under test (Athos, 2026-10-06, programa ga-9t9acg): the Pilot picks priority > type (feature first)
# > age (OLDEST first), on every stage of the board — all P0 features oldest-first, then the P0 that are not
# features oldest-first, then P1 features, then the other P1s, and so on. It REVERTS the 2026-06-24 Pilot
# decision (bug first / feature last / NEWEST first, `_PILOT_SORT_JQ` + `trank`). The order itself lives in
# scripts/work-order.sh; this file proves the Pilot USES it and that nothing of the old order is left.
#
# The real `_top_candidate` / `_queue_preview` / `_pilot_order_pool` are extracted verbatim from the dispatcher
# (awk) and run under the dispatcher's own `set -euo pipefail`, next to the real lib. What is asserted:
#   O1  the programa's fixture (P0 feature old/new, P0 bug old, P0 task new, P1 feature, P1 bug) is picked in
#       the rule's order, one pick at a time the way dispatch_lane() walks a pool (pick → remove → pick);
#   O2  the same beads in any input order give the same picks; `_queue_preview` shows the same order;
#   O3  the `tech-debt` tier of the old order is gone: a tech-debt bead is "not a feature", ranked by age;
#   O4  a P0 `story` ranks as a feature; a reclaimed bead keeps its created_at age (no `reclaim` mode);
#   O5  an unreadable field keeps the bead at the end of its class AND the lib's WARN reaches stderr;
#   O6  "cannot tell" (the lib fails, or is not loaded) keeps the INPUT order with a visible WARN — never an
#       empty queue — and the pick is still the first bead, rc 0 (a non-zero rc would end a `set -e` sweep);
#   S   source guards: no `_PILOT_SORT_JQ` / `trank` / `2>/dev/null` around the sort in the dispatcher, the lib is
#       sourced ONCE behind an `[ -r ]` check (the block shared with the queue emit), the age rule is the shared
#       `_PILOT_WORK_ORDER_AGE="created"` constant, this consumer's rows are gone from the lib's registry.
# And the MUTATION CONTROLS: the same assertions run against the OLD order and against two broken copies of the
# dispatcher (no sort at all; the `reclaim` age rule) and MUST fail there — otherwise the fixture would pass
# whatever the Pilot did.
#
# Written to FAIL on the pre-fix dispatcher (run it with PILOT_DISPATCHER_PATH pointing at a pre-fix copy to see
# it RED). The 2c/4b union (a rig P0 feature beats an HQ P2 in ONE pool) is an end-to-end sweep and lives in
# pilot-dispatcher.selftest.sh, scenarios ga-9t9acg.2-*.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="$SELF_DIR/scripts/work-order.sh"
REGISTRY="$SELF_DIR/scripts/work-order.registry.tsv"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -r "$LIB" ]        || { echo "FATAL: work-order.sh not found at $LIB" >&2; exit 2; }
# ga-ck3sz7: the children run on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh).
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-order-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
sandbox_path_init "$WORK" jq || exit 2

# fn_src <file> <name> — the function's source verbatim, or nothing if the file does not define it.
fn_src() { awk -v n="$2" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$1"; }
# var_src <file> <name> — a multi-line single-quoted assignment (`NAME='` … a line starting with `'`).
var_src() { awk -v n="$2" '$0 ~ "^"n"=\047"{f=1} f{print} f&&/^\047/{exit}' "$1"; }

# funcs_of <dispatcher-file> — everything the ordering needs, whichever of it that file defines. The helper
# (_pilot_order_pool) and the old jq constant are optional on purpose: the pre-fix dispatcher has only the
# constant, and the assertions must then FAIL on the order, not abort on a missing function.
funcs_of() {
  local _f _o=""
  for _f in _pilot_order_pool _top_candidate _queue_preview; do
    _o="$_o
$(fn_src "$1" "$_f")"
  done
  _o="$_o
$(var_src "$1" _PILOT_SORT_JQ)"
  # The age rule is a constant the dispatcher defines once, in the shared work-order source block (ga-9t9acg.3 owns
  # the block, the emit and the dispatch both read the constant). It is taken from the file UNDER TEST, so a Pilot
  # whose constant says something else is judged by what it would really pass to the lib. Absent on the pre-fix file.
  _o="$_o
$(grep -m1 -E '^_PILOT_WORK_ORDER_AGE=' "$1" || true)"
  printf '%s\n' "$_o"
}

[ -n "$(fn_src "$DISPATCHER" _top_candidate)" ] || { echo "FATAL: _top_candidate() not found in $DISPATCHER" >&2; exit 2; }

# ── fixtures ─────────────────────────────────────────────────────────────────
# ids are chosen so that sorting by id (the lib's last tie-break, and the order `unique_by(.id)` leaves a merged
# pool in) CONTRADICTS the expected order: a Pilot that only de-duplicates would fail loudly.
bead() { # <id> <priority> <type> <created_at> [labels-json]
  printf '{"id":"%s","title":"t %s","priority":%s,"issue_type":"%s","created_at":"%s","labels":%s}' \
    "$1" "$1" "$2" "$3" "$4" "${5:-[]}"
}
F_OLD="$(bead z-f-old 0 feature 2026-01-01T10:00:00Z)"
F_NEW="$(bead y-f-new 0 feature 2026-09-01T10:00:00Z)"
B_OLD="$(bead x-b-old 0 bug     2026-02-01T10:00:00Z)"
T_NEW="$(bead w-t-new 0 task    2026-09-15T10:00:00Z)"
P1_F="$(bead v-f-p1   1 feature 2026-03-01T10:00:00Z)"
P1_B="$(bead u-b-p1   1 bug     2026-01-15T10:00:00Z)"
POOL_ORDERED="[$F_OLD,$F_NEW,$B_OLD,$T_NEW,$P1_F,$P1_B]"
POOL_SHUFFLED="[$P1_B,$T_NEW,$F_NEW,$P1_F,$B_OLD,$F_OLD]"
EXPECT_ORDER="z-f-old y-f-new x-b-old w-t-new v-f-p1 u-b-p1"
# What the OLD order (bug first, feature last, newest first) gives on the same pool — printed in failures only.
OLD_ORDER="x-b-old w-t-new y-f-new z-f-old u-b-p1 v-f-p1"

# The old program, kept ONLY as the mutation reference ("reverting to the old behavior must break this selftest").
OLD_SORT_JQ='
  def trank:
    ( (.labels // []) ) as $lbls
    | if ($lbls | index("tech-debt")) then 1
      else ( (.issue_type // .type // "") | ascii_downcase ) as $t
        | if   $t == "bug"      then 0
          elif $t == "tech-debt" then 1
          elif $t == "task"     then 2
          elif $t == "chore"    then 3
          elif ($t == "feature" or $t == "story") then 4
          else 5 end
      end;
  sort_by([ (.priority // 99), (. | trank), -(((.created_at // "1970-01-01T00:00:00Z")[0:19] + "Z") | fromdateiso8601? // 0), (.id // "") ])
'

# ── the child: one shell per run, like one sweep ─────────────────────────────
# run_child <dispatcher-file> <mode> <script-body> — runs <script-body> in a subshell that has the dispatcher's
# options, the real lib and the dispatcher's real ordering functions. <mode> selects a deliberate breakage:
#   real        nothing broken
#   old         _pilot_order_pool replaced by the OLD sort (the pre-ga-9t9acg.2 behavior)
#   libfail     work_order_sort exists but fails (exit 2, "cannot tell")
#   nolib       work_order_sort is not loaded at all
# stdout → $WORK/out, stderr → $WORK/err, rc → $RC. log/warn are the dispatcher's own (they ECHO TO STDOUT),
# so a helper that used them inside $(...) would corrupt the JSON it returns — and be caught here.
run_child() {
  local disp="$1" mode="$2" body="$3" _funcs
  _funcs="$(funcs_of "$disp")"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"
    log()  { echo "[ts] [pilot-dispatcher] $*"; }
    warn() { echo "[ts] [pilot-dispatcher] WARN: $*"; }
    # shellcheck disable=SC1090
    source "$LIB"
    eval "$_funcs"
    case "$mode" in
      old)     eval "$(printf '_pilot_order_pool() { printf "%%s" "$1" | jq -c %s; }' "$(printf '%q' "$OLD_SORT_JQ")")" ;;
      libfail) work_order_sort() { cat >/dev/null; echo "work-order ERROR: work_order_sort: cannot tell (selftest-forced)" >&2; return 2; } ;;
      nolib)   unset -f work_order_sort work_order_head work_order_cfg ;;
    esac
    eval "$body"
  ) >"$WORK/out" 2>"$WORK/err"
  RC=$?
}

# picks_body — the way dispatch_lane() walks a pool: pick the top, remove it, pick again, until `break`.
# Prints the ids, space-separated, on one line. $POOL is read from the environment of the child.
# shellcheck disable=SC2016
PICKS_BODY='
  pool="$POOL"; ids=""
  while :; do
    pick=$(_top_candidate "$pool")
    { [ -z "$pick" ] || [ "$pick" = "null" ]; } && break
    id=$(echo "$pick" | jq -r ".id // \"\"")
    [ -z "$id" ] && break
    ids="$ids${ids:+ }$id"
    pool=$(echo "$pool" | jq -c --arg id "$id" "[.[] | select(.id != \$id)]")
  done
  echo "$ids"
'
# picks <dispatcher> <mode> <pool-json> — sets PICKS (the pick order, "" when none) and RC. NOT called through
# $(...): RC must survive in this shell.
picks() { POOL="$3" run_child "$1" "$2" "$PICKS_BODY"; PICKS="$(head -1 "$WORK/out" | tr -d '\n')"; }

# assert_picks <label> <expected> <dispatcher> <mode> <pool-json>
assert_picks() {
  picks "$3" "$4" "$5"
  if [ "$PICKS" = "$2" ]; then ok "$1"; else bad "$1 — expected [$2] got [$PICKS] (rc=$RC; stderr: $(head -2 "$WORK/err" | tr '\n' '|'))"; fi
}
# order_holds <dispatcher> <mode> — 0 iff EVERY ordering assertion of O1/O2/O4 holds for that dispatcher+mode.
# Used by the mutation controls: a broken Pilot must make it return non-zero.
order_holds() {
  local _d="$1" _m="$2" _rc=0
  picks "$_d" "$_m" "$POOL_ORDERED";  [ "$PICKS" = "$EXPECT_ORDER" ]    || _rc=1
  picks "$_d" "$_m" "$POOL_SHUFFLED"; [ "$PICKS" = "$EXPECT_ORDER" ]    || _rc=1
  picks "$_d" "$_m" "$RECLAIM_POOL";  [ "$PICKS" = "$RECLAIM_EXPECT" ]  || _rc=1
  return "$_rc"
}

# A P0 feature reclaimed twice (updated_at is NEW) must keep its created_at position: the Pilot has no `reclaim`
# age rule — it already drops poisoned beads upstream (_FILTER_RECLAIM_CAP=3), so a bead that is still in the
# pool is not starving anyone by being old.
RECLAIM_OLD="$(bead r-f-reclaimed 0 feature 2026-01-01T10:00:00Z '["pilot:reclaim-count:2"]' | jq -c '. + {updated_at:"2026-10-06T10:00:00Z"}')"
RECLAIM_MID="$(bead a-f-mid       0 feature 2026-05-01T10:00:00Z)"
RECLAIM_POOL="[$RECLAIM_MID,$RECLAIM_OLD]"
RECLAIM_EXPECT="r-f-reclaimed a-f-mid"

# ═════════════════════════════════════════════════════════════════════════════
echo "Scenario O1: the programa's fixture is picked priority > feature first > oldest first"
assert_picks "O1: P0 feature old, P0 feature new, P0 bug old, P0 task new, P1 feature, P1 bug" \
  "$EXPECT_ORDER" "$DISPATCHER" real "$POOL_ORDERED"
[ "$RC" = 0 ] && ok "O1: the walk ends with rc 0 (no set -e abort on the way)" || bad "O1: the walk ended with rc=$RC — stderr: $(head -3 "$WORK/err")"

echo "Scenario O2: input order does not matter; the queue preview shows the real order"
assert_picks "O2: the same beads, reversed/shuffled input, give the same picks" \
  "$EXPECT_ORDER" "$DISPATCHER" real "$POOL_SHUFFLED"
POOL="$POOL_SHUFFLED" run_child "$DISPATCHER" real '_queue_preview "$POOL" small'
_prev="$(grep -o '\] [a-z0-9-]* P' "$WORK/out" | sed 's/^\] //; s/ P$//' | tr '\n' ' ' | sed 's/ $//')"
if [ "$_prev" = "z-f-old y-f-new x-b-old" ]; then ok "O2: _queue_preview lists the top 3 in the rule's order"
else bad "O2: _queue_preview lists [$_prev] — expected [z-f-old y-f-new x-b-old] (rc=$RC)"; fi
if grep -q 'P0 — t z-f-old' "$WORK/out"; then ok "O2: the preview line format is unchanged (id, P<n>, title)"
else bad "O2: the preview line format changed: $(head -1 "$WORK/out")"; fi
POOL="[]" run_child "$DISPATCHER" real '_queue_preview "$POOL" small'
if [ "$RC" = 0 ] && [ ! -s "$WORK/out" ]; then ok "O2: an empty pool previews nothing, rc 0"
else bad "O2: an empty pool printed [$(head -1 "$WORK/out")] rc=$RC"; fi

echo "Scenario O3: no tech-debt tier — a tech-debt bead is just 'not a feature', ranked by age"
TD_POOL="[$(bead d-bug-new 0 bug 2026-09-01T10:00:00Z),$(bead e-chore-mid 0 chore 2026-05-01T10:00:00Z),$(bead f-td-old 0 task 2026-01-01T10:00:00Z '["tech-debt"]')]"
assert_picks "O3: P0 tech-debt (old), P0 chore (mid), P0 bug (new) → oldest first" \
  "f-td-old e-chore-mid d-bug-new" "$DISPATCHER" real "$TD_POOL"

echo "Scenario O4: a story ranks as a feature; a reclaimed bead keeps its created_at age"
STORY_POOL="[$(bead s-bug-old 0 bug 2026-01-01T10:00:00Z),$(bead t-story-new 0 story 2026-09-01T10:00:00Z)]"
assert_picks "O4: a P0 story is ahead of an older P0 bug (story = feature)" \
  "t-story-new s-bug-old" "$DISPATCHER" real "$STORY_POOL"
assert_picks "O4: a P0 feature reclaimed twice (updated_at new) is still ranked by created_at — no reclaim mode" \
  "$RECLAIM_EXPECT" "$DISPATCHER" real "$RECLAIM_POOL"

echo "Scenario O5: an unreadable field keeps the bead at the end of its class and the lib's WARN reaches stderr"
NOAGE='{"id":"b-f-noage","title":"t","priority":0,"issue_type":"feature","labels":[]}'
UNREAD_POOL="[$NOAGE,$(bead c-f-dated 0 feature 2026-04-01T10:00:00Z),$(bead d-b-p0 0 bug 2026-01-01T10:00:00Z)]"
assert_picks "O5: P0 feature without created_at is the LAST P0 feature, still ahead of the P0 bug" \
  "c-f-dated b-f-noage d-b-p0" "$DISPATCHER" real "$UNREAD_POOL"
if grep -q 'work-order WARN: b-f-noage: age?' "$WORK/err"; then ok "O5: the lib's 'age?' WARN for the unreadable bead is on stderr (not swallowed by 2>/dev/null)"
else bad "O5: no 'work-order WARN: b-f-noage: age?' on stderr — stderr was: $(head -3 "$WORK/err")"; fi

echo "Scenario O6: 'cannot tell' keeps the input order with a visible WARN — never an empty queue"
for _mode in libfail nolib; do
  POOL="$POOL_SHUFFLED" run_child "$DISPATCHER" "$_mode" 'pick=$(_top_candidate "$POOL"); echo "$pick" | jq -r ".id // \"EMPTY\""'
  _first="$(head -1 "$WORK/out")"
  if [ "$RC" = 0 ] && [ "$_first" = "u-b-p1" ]; then ok "O6[$_mode]: the pick is the FIRST bead of the input (u-b-p1), rc 0 — the queue is not read as empty"
  else bad "O6[$_mode]: pick=[$_first] rc=$RC — expected the first input bead u-b-p1 and rc 0; stderr: $(head -3 "$WORK/err")"; fi
  if grep -qi 'cannot tell\|previous order\|input order' "$WORK/err"; then ok "O6[$_mode]: a visible WARN names the fault on stderr"
  else bad "O6[$_mode]: nothing on stderr says the order could not be applied — silent misordering"; fi
  POOL="$POOL_SHUFFLED" run_child "$DISPATCHER" "$_mode" '_queue_preview "$POOL" small'
  if [ "$RC" = 0 ] && [ "$(grep -c '^  \[small\]' "$WORK/out")" = 3 ]; then ok "O6[$_mode]: _queue_preview still lists 3 beads (input order), rc 0"
  else bad "O6[$_mode]: _queue_preview rc=$RC, $(grep -c '^  \[small\]' "$WORK/out") line(s)"; fi
done
POOL='not json at all' run_child "$DISPATCHER" real 'pick=$(_top_candidate "$POOL"); echo "pick=[$pick]"'
if [ "$RC" = 0 ] && [ "$(head -1 "$WORK/out")" = "pick=[]" ] && grep -q 'work-order ERROR' "$WORK/err"; then
  ok "O6: a pool that is not a JSON array gives an EMPTY pick (dispatch_lane breaks) with the lib's ERROR on stderr, rc 0"
else bad "O6: garbage pool → out=[$(head -1 "$WORK/out")] rc=$RC err=[$(head -2 "$WORK/err")]"; fi

# ═════════════════════════════════════════════════════════════════════════════
echo "Scenario S: source guards — nothing of the old order is left in the dispatcher"
_code="$(grep -v '^[[:space:]]*#' "$DISPATCHER")"
# Here-strings, never `printf | grep -q`: under `set -o pipefail` grep -q closes the pipe at the first match, printf
# dies of SIGPIPE (141) and the `if` reads "not found" — the guard would pass exactly when the thing IS there.
if grep -q '_PILOT_SORT_JQ' <<< "$_code"; then bad "S: _PILOT_SORT_JQ is still referenced (the pre-ga-9t9acg.2 sort program)"; else ok "S: _PILOT_SORT_JQ is gone"; fi
if grep -q 'trank' <<< "$_code"; then bad "S: trank (the old type-rank / tech-debt tier) is still in the code"; else ok "S: trank / the tech-debt tier is gone"; fi
_swallow="$(grep -E 'work_order_(sort|head)' <<< "$_code" | grep -E '2>[[:space:]]*/dev/null' || true)"
if [ -n "$_swallow" ]; then bad "S: stderr of the lib is thrown away (2>/dev/null) — the WARN lines are the only signal: $(printf '%s' "$_swallow" | head -1 | cut -c1-120)"
else ok "S: no 2>/dev/null on a work_order_sort / work_order_head call"; fi
# The variable that holds the lib's path is whatever the dispatcher assigns from `…/scripts/work-order.sh` (the source
# block is shared with the queue emit, so its variable name is not this file's to pin).
_wovar="$(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*scripts\/work-order\.sh.*/\1/p' <<< "$_code" | head -1)"
if [ -z "$_wovar" ]; then bad "S: no assignment of the path to scripts/work-order.sh in the dispatcher — the lib is not sourced at all"
else
  _srcline="$(grep -B1 -E "^[[:space:]]*(source|\\.)[[:space:]]+\"\\\$$_wovar\"" <<< "$_code" || true)"
  if [ -n "$_srcline" ] && grep -q '\[ -r ' <<< "$_srcline"; then ok "S: work-order.sh is sourced right behind an [ -r ] check"
  else bad "S: work-order.sh is not sourced behind an [ -r ] check (a missing sibling under set -e kills the sweep even with || true)"; fi
fi
_nsrc="$(grep -cE '^[[:space:]]*(source|\.)[[:space:]]+"?\$\{?[A-Za-z_]*(WO|WORK_ORDER)[A-Za-z_]*' <<< "$_code" || true)"
if [ "$_nsrc" = 1 ]; then ok "S: the lib is sourced exactly ONCE in the dispatcher (the queue emit and the dispatch share the one block)"
else bad "S: the lib is sourced $_nsrc times in the dispatcher — one block, shared with the queue emit, is the contract"; fi
if grep -qE 'work_order_sort[[:space:]]+--age[[:space:]]+"\$_PILOT_WORK_ORDER_AGE"' <<< "$_code"; then ok "S: the dispatch passes the shared age constant to the lib (the same one the queue emit passes)"
else bad "S: the sort call does not pass --age \"\$_PILOT_WORK_ORDER_AGE\" — the dispatch and the emitted queue could serve different orders"; fi
if grep -qE '^_PILOT_WORK_ORDER_AGE="created"$' <<< "$_code"; then ok "S: the age rule is created_at (_PILOT_WORK_ORDER_AGE=\"created\"), no reclaim mode"
else bad "S: _PILOT_WORK_ORDER_AGE is not \"created\" (the Pilot excludes poisoned beads by _FILTER_RECLAIM_CAP, it does not re-rank them)"; fi
if [ -r "$REGISTRY" ]; then
  _rows="$(awk -F'\t' '$2 ~ /pilot-dispatcher\.sh$/ && $4 == "ga-9t9acg.2"' "$REGISTRY" | wc -l | tr -d ' ')"
  if [ "$_rows" = 0 ]; then ok "S: this consumer's rows (owner ga-9t9acg.2) are gone from work-order.registry.tsv"
  else bad "S: work-order.registry.tsv still carries $_rows pilot-dispatcher.sh row(s) owned by ga-9t9acg.2"; fi
else bad "S: registry not found at $REGISTRY"; fi

# ═════════════════════════════════════════════════════════════════════════════
echo "Scenario C (mutation controls): a Pilot that is NOT on the rule must break the selftest"
if order_holds "$DISPATCHER" real; then ok "C0: precondition — the real dispatcher satisfies every ordering assertion"
else bad "C0: precondition failed — the real dispatcher does not satisfy the ordering assertions (see O1/O2/O4 above)"; fi
if order_holds "$DISPATCHER" old; then bad "C1: the OLD order (bug first, tech-debt tier, newest first) passes the ordering assertions — the fixture does not pin the rule"
else ok "C1: reverting to the OLD order (trank + newest-first) fails the ordering assertions"; fi
POOL="$POOL_ORDERED" run_child "$DISPATCHER" old "$PICKS_BODY"
[ "$(head -1 "$WORK/out")" = "$OLD_ORDER" ] && ok "C1: the old program really yields [$OLD_ORDER] on the fixture (the control is not vacuous)" \
  || bad "C1: the old program yielded [$(head -1 "$WORK/out")], expected [$OLD_ORDER] — the mutation harness is broken"

# Textual mutations of a COPY of the dispatcher: each must differ from the original (else the control is vacuous)
# and each must make the ordering assertions fail.
mutate() { # <name> <sed-expr>
  local _copy="$WORK/mut-$1.sh"
  sed -e "$2" "$DISPATCHER" > "$_copy"
  if cmp -s "$DISPATCHER" "$_copy"; then bad "C[$1]: the mutation changed nothing in the dispatcher — the control is vacuous (the call it targets moved?)"; return; fi
  if order_holds "$_copy" real; then bad "C[$1]: a dispatcher with this mutation still satisfies the ordering assertions — not pinned"
  else ok "C[$1]: the mutated dispatcher fails the ordering assertions"; fi
}
mutate nosort  's/work_order_sort --age "$_PILOT_WORK_ORDER_AGE"/cat/'
mutate reclaim 's/^_PILOT_WORK_ORDER_AGE="created"/_PILOT_WORK_ORDER_AGE="reclaim"/'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
