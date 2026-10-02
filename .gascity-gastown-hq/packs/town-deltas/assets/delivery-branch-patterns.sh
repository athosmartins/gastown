# delivery-branch-patterns.sh — single source of truth for "which branch names
# can carry a bead's delivery" (ga-x7m5rg). Sourced, never executed.
#
# Consumed by pilot-dispatcher.sh (_beadid_needs_remerge_branch, the ga-e2n96
# resubmit-or-escalate decision). quality-gate-guard.sh's GAP-1/GAP-2 reconcilers
# (ga-pa36, ga-g3g72, ga-tconzw) still carry their own literal copies of this
# list; delivery-branch-patterns.selftest.sh drift-guards them against it, so a
# prefix added in one place and not the other fails a test instead of shipping.
#
# Why this exists: GAP-2 looked for the delivery under fix/ feat/ feature/
# refactor/ docs/ chore/ test/ crew/*/, but the Pilot's ga-e2n96 lookup only knew
# fix/<bead>[-*]. A bead delivered on feat/<bead> (measured twice on ga-atsahv,
# the second on 01/10) was found by GAP-2, re-armed gate:needs-remerge, and then
# declared "no existing fix/ branch" by the Pilot → a false gate:needs-human that
# stopped the bead until the Mayor re-armed it by hand. Two consumers of one
# concept with divergent vocabularies — the same drift class as
# framework-marker-labels.sh (ga-vmn7kv).
#
# Add a prefix HERE and every consumer of this file sees it. Space-separated,
# in PRIORITY order: when ONE set of refs holds branches under more than one
# prefix, the earliest prefix wins (fix/ is the documented dispatch_one()
# convention, so it stays first). The Pilot's lookup applies that order within
# each source it reads (local + fetched refs, then origin), not across them —
# see _beadid_needs_remerge_branch.
# crew/*/<bead> is not listed — its glob has a different shape — and is always
# appended last by gc_delivery_branch_globs.
GC_DELIVERY_BRANCH_PREFIXES="fix feat feature refactor docs chore test"

# gc_delivery_branch_globs <bead_id>
# Prints, one per line and in priority order, the branch-NAME globs (no refs/
# root) that count as <bead_id>'s delivery: <prefix>/<id> and <prefix>/<id>-*
# for each prefix, then crew/*/<id> and crew/*/<id>-*. The bare <id> and the
# "<id>-" form are deliberately separate globs: <id>* would also match a
# DIFFERENT, longer bead id that merely starts with this one.
# rc 1 (and no output) when <bead_id> is empty or the prefix list is empty/unset
# — callers must read that as "cannot tell", never as "no branch".
gc_delivery_branch_globs() {
  local _id="${1:-}" _p
  [ -n "$_id" ] || return 1
  [ -n "${GC_DELIVERY_BRANCH_PREFIXES:-}" ] || return 1
  for _p in $GC_DELIVERY_BRANCH_PREFIXES; do
    printf '%s/%s\n' "$_p" "$_id"
    printf '%s/%s-*\n' "$_p" "$_id"
  done
  printf 'crew/*/%s\n' "$_id"
  printf 'crew/*/%s-*\n' "$_id"
}

# gc_delivery_branch_pick <bead_id>   (ref lines on stdin)
# Reads ref lines the way `git for-each-ref --format=%(refname)` prints them
# (refs/heads/X or refs/remotes/origin/X), optionally led by "<sha><TAB>" as
# `git ls-remote` prints them, and prints the branch name (root stripped) of the
# highest-priority one that is really <bead_id>'s delivery. The anchored `case`
# match re-validates what git's own pattern matching returned: ls-remote matches
# a pattern against the TAIL of a ref, so it can hand back an unrelated ref that
# merely ends the same way.
# rc 0 = picked, rc 1 = none of the lines qualify (or the glob list is unusable).
gc_delivery_branch_pick() {
  local _id="${1:-}" _globs _g _line _name _in
  [ -n "$_id" ] || return 1
  _globs=$(gc_delivery_branch_globs "$_id") || return 1
  _in=$(cat)
  while IFS= read -r _g; do
    [ -n "$_g" ] || continue
    while IFS= read -r _line; do
      _line="${_line##*$'\t'}"
      case "$_line" in
        refs/heads/*)          _name="${_line#refs/heads/}" ;;
        refs/remotes/origin/*) _name="${_line#refs/remotes/origin/}" ;;
        *) continue ;;
      esac
      case "$_name" in
        $_g) printf '%s' "$_name"; return 0 ;;
      esac
    done <<< "$_in"
  done <<< "$_globs"
  return 1
}
