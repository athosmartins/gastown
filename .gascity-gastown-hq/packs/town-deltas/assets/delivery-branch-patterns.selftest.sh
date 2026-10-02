#!/usr/bin/env bash
# delivery-branch-patterns.selftest.sh — ga-x7m5rg.
#
# delivery-branch-patterns.sh is the single list of branch prefixes that count
# as "this bead's delivery". The Pilot's gate:needs-remerge lookup reads it; the
# GAP-1/GAP-2 reconcilers in quality-gate-guard.sh still carry three LITERAL
# copies of the same list. The bug this guards against is exactly their
# divergence: GAP-2 knew feat/, the Pilot knew only fix/, and a bead delivered
# on feat/ga-atsahv was falsely escalated to gate:needs-human (2x).
#
#  1. gc_delivery_branch_globs behaves (2 globs per prefix + the crew globs,
#     priority order, degenerate input → rc 1, never "none").
#  2. gc_delivery_branch_pick behaves (priority, decoys, the ls-remote
#     tail-match hazard, degenerate input → rc 1).
#  3. DRIFT GUARD: the prefix set at each of quality-gate-guard.sh's three PAT
#     sites equals the shared list in BOTH directions — a prefix added to one
#     side and not the other fails here, whichever side it was added on.
#  4. The Pilot consumes the shared list: pilot-dispatcher.sh carries no second
#     copy of it.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/delivery-branch-patterns.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── delivery-branch-patterns drift-guard + behaviour (ga-x7m5rg) ──"

[ -r "$LIB" ]   || { echo "FATAL: $LIB missing" >&2; exit 2; }
[ -r "$GUARD" ] || { echo "FATAL: $GUARD missing" >&2; exit 2; }
# shellcheck disable=SC1090
. "$LIB"

echo "── 1. gc_delivery_branch_globs ──"
GLOBS="$(gc_delivery_branch_globs ga-abc)"
N_PFX=$(printf '%s\n' $GC_DELIVERY_BRANCH_PREFIXES | grep -c .)
N_GLOBS=$(printf '%s\n' "$GLOBS" | grep -c .)
if [ "$N_GLOBS" -eq $((N_PFX * 2 + 2)) ]; then
  ok "2 globs per prefix + 2 crew globs ($N_GLOBS for $N_PFX prefixes)"
else
  bad "expected $((N_PFX * 2 + 2)) globs, got $N_GLOBS"
fi
if [ "$(printf '%s\n' "$GLOBS" | sed -n 1p)" = "fix/ga-abc" ] && [ "$(printf '%s\n' "$GLOBS" | sed -n 2p)" = "fix/ga-abc-*" ]; then
  ok "fix/<id> then fix/<id>-* come first (documented dispatch_one() convention has priority)"
else
  bad "fix/ is not first in priority order: $(printf '%s\n' "$GLOBS" | head -2 | tr '\n' ' ')"
fi
if [ "$(printf '%s\n' "$GLOBS" | tail -2 | tr '\n' ' ')" = "crew/*/ga-abc crew/*/ga-abc-* " ]; then
  ok "crew/*/<id> and crew/*/<id>-* come last"
else
  bad "crew globs are not last: $(printf '%s\n' "$GLOBS" | tail -2 | tr '\n' ' ')"
fi
# Never a bare <id>* glob: it would match a DIFFERENT, longer bead id.
if printf '%s\n' "$GLOBS" | grep -E '[^-]\*$' | grep -v '^crew/\*/' >/dev/null; then
  bad "a glob ends in <id>* without the '-' — would match a longer, unrelated bead id"
else
  ok "no <id>* glob without the '-' separator"
fi
_o="$(gc_delivery_branch_globs "" 2>/dev/null)"; _rc=$?
[ "$_rc" -eq 1 ] && [ -z "$_o" ] && ok "empty bead id → rc 1, no output" || bad "empty id: rc=$_rc out='$_o'"
_o="$( GC_DELIVERY_BRANCH_PREFIXES="" gc_delivery_branch_globs ga-abc 2>/dev/null)"; _rc=$?
[ "$_rc" -eq 1 ] && [ -z "$_o" ] && ok "empty prefix list → rc 1, no output (never a crew-only list that reads as complete)" || bad "empty prefixes: rc=$_rc out='$_o'"
_o="$( unset GC_DELIVERY_BRANCH_PREFIXES; set -u; gc_delivery_branch_globs ga-abc 2>/dev/null)"; _rc=$?
[ "$_rc" -eq 1 ] && [ -z "$_o" ] && ok "unset prefix list under set -u → rc 1, no crash" || bad "unset prefixes: rc=$_rc out='$_o'"

echo "── 2. gc_delivery_branch_pick ──"
pick() { local _id="$1"; shift; printf '%s\n' "$@" | gc_delivery_branch_pick "$_id"; }
assert_pick() { # label want_rc want_name id lines...
  local _label="$1" _wrc="$2" _wname="$3" _id="$4"; shift 4
  local _got _rc
  _got="$(pick "$_id" "$@")"; _rc=$?
  if [ "$_rc" -eq "$_wrc" ] && [ "$_got" = "$_wname" ]; then ok "$_label"; else bad "$_label: want rc=$_wrc '$_wname', got rc=$_rc '$_got'"; fi
}
assert_pick "local head, bare id"            0 "feat/ga-abc"        ga-abc "refs/heads/feat/ga-abc"
assert_pick "remote-tracking ref, id+slug"   0 "feat/ga-abc-slug"   ga-abc "refs/remotes/origin/feat/ga-abc-slug"
assert_pick "ls-remote line (sha<TAB>ref)"   0 "feat/ga-abc"        ga-abc "0123456789abcdef0123456789abcdef01234567	refs/heads/feat/ga-abc"
assert_pick "crew/<agent>/<id>"              0 "crew/x/ga-abc"      ga-abc "refs/heads/crew/x/ga-abc"
assert_pick "fix/ beats feat/ regardless of input order" 0 "fix/ga-abc" ga-abc "refs/heads/feat/ga-abc" "refs/heads/fix/ga-abc"
assert_pick "same branch as head and remote-tracking → that branch" 0 "feat/ga-abc" ga-abc "refs/remotes/origin/feat/ga-abc" "refs/heads/feat/ga-abc"
assert_pick "longer id sharing the prefix is NOT a match"   1 "" ga-abc "refs/heads/fix/ga-abcdef" "refs/heads/feat/ga-abcdef-slug"
assert_pick "id that only prefixes an existing branch id"   1 "" ga-ab  "refs/heads/feat/ga-abc"
assert_pick "ls-remote TAIL-match hazard: foreign ref ending the same way is rejected" 1 "" ga-abc "refs/heads/zzz/fix/ga-abc" "refs/heads/old/feat/ga-abc"
assert_pick "tags / unrelated roots are ignored" 1 "" ga-abc "refs/tags/feat/ga-abc" "refs/remotes/upstream/feat/ga-abc"
_o="$(printf '' | gc_delivery_branch_pick ga-abc)"; _rc=$?
[ "$_rc" -eq 1 ] && [ -z "$_o" ] && ok "empty input → rc 1" || bad "empty input: rc=$_rc out='$_o'"
_o="$(printf 'refs/heads/feat/ga-abc\n' | GC_DELIVERY_BRANCH_PREFIXES="" gc_delivery_branch_pick ga-abc)"; _rc=$?
[ "$_rc" -eq 1 ] && [ -z "$_o" ] && ok "unusable glob list → rc 1 (no guessing)" || bad "empty prefixes in pick: rc=$_rc out='$_o'"

echo "── 3. DRIFT GUARD vs quality-gate-guard.sh (the three literal copies of this list) ──"
LIB_SET="$(printf '%s\n' $GC_DELIVERY_BRANCH_PREFIXES | sort -u)"
check_site() { # label var
  local _label="$1" _var="$2" _site_set _missing _extra _p
  _site_set="$(grep -o "refs/heads/[a-z]*/\${${_var}}\"" "$GUARD" | sed -E 's#refs/heads/([a-z]*)/.*#\1#' | sort -u)"
  if [ -z "$_site_set" ]; then
    bad "$_label: found NO refs/heads/<prefix>/\${$_var} patterns in quality-gate-guard.sh — the extraction broke (renamed variable?), the guard is blind"
    return
  fi
  _missing="$(comm -23 <(printf '%s\n' "$LIB_SET") <(printf '%s\n' "$_site_set") | tr '\n' ' ')"
  _extra="$(comm -13 <(printf '%s\n' "$LIB_SET") <(printf '%s\n' "$_site_set") | tr '\n' ' ')"
  if [ -z "$_missing" ] && [ -z "$_extra" ]; then
    ok "$_label: prefix set == shared list ($(printf '%s' "$_site_set" | tr '\n' ' '))"
  else
    [ -n "$_missing" ] && bad "$_label: in delivery-branch-patterns.sh but MISSING from quality-gate-guard.sh: $_missing"
    [ -n "$_extra" ]   && bad "$_label: in quality-gate-guard.sh but MISSING from delivery-branch-patterns.sh: $_extra"
  fi
  for _p in $GC_DELIVERY_BRANCH_PREFIXES; do
    grep -Fq "refs/heads/$_p/\${${_var}}-*\"" "$GUARD" || bad "$_label: $_p/<id>-* variant missing from quality-gate-guard.sh"
  done
  if grep -Fq "refs/heads/crew/*/\${${_var}}\"" "$GUARD" && grep -Fq "refs/heads/crew/*/\${${_var}}-*\"" "$GUARD"; then
    ok "$_label: crew/*/<id> and crew/*/<id>-* present (the shared list appends them last)"
  else
    bad "$_label: crew/*/<id>[-*] missing from quality-gate-guard.sh"
  fi
}
check_site "GAP-1 RIGSCAN (never-branched, rig-scoped)" "RIGSCAN_OI_ID"
check_site "GAP-1 GC_CITY (merged-but-OPEN sweep)"      "OI_ID"
check_site "GAP-2 merge-search"                          "GAP2_TRY_ID"

echo "── 4. the Pilot actually consumes the shared list (no 2nd copy in pilot-dispatcher.sh) ──"
PD="$SELF_DIR/pilot-dispatcher.sh"
if grep -Eq 'refs/heads/(fix|feat|feature|refactor|docs|chore|test)/\$\{?_bid' "$PD"; then
  bad "pilot-dispatcher.sh hard-codes a <prefix>/<bead> ref again — it must read delivery-branch-patterns.sh (ga-x7m5rg)"
else
  ok "pilot-dispatcher.sh carries no literal <prefix>/<bead> ref pattern"
fi
if grep -Fq 'delivery-branch-patterns.sh' "$PD" && grep -Fq 'gc_delivery_branch_globs "$_bid"' "$PD"; then
  ok "pilot-dispatcher.sh sources the shared lib and builds the helper's patterns from it"
else
  bad "pilot-dispatcher.sh does not source/use delivery-branch-patterns.sh"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
