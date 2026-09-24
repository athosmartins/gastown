#!/usr/bin/env bash
# story-delivery.sh — Autonomous Story Delivery Driver ("D").
#
# Runs after the quality gate merges a story to prod main. Handles the gap
# between "merged" and "done": deploys code, verifies in prod, marks story:done.
#
# Pipeline:
#   1. Find stories with label gate:passed (merged, not yet deployed/verified).
#   2. For each, load its rig's deploy runbook from delivery-runbooks.toml.
#   3. Deploy: run the rig's deploy_cmd (git pull / etc.)
#   4. Restart daemons listed in daemon_restarts (if any).
#   5. Run the rig's prod_test_script (with STORY_ID set so story-specific
#      tests are included). Exit code decides pass/fail.
#   6. Verify refino criteria from the story bead metadata.
#   7. SUCCESS: add label story:done + comment with evidence.
#   8. FAILURE: HALT-AND-ESCALATE — notify author + Mayor, add label
#      delivery:failed, DO NOT auto-revert (DB migration risk).
#   9. Log to .gc/story-delivery.jsonl.
#
# SAFETY INVARIANTS:
#   - NEVER auto-reverts. On failure: halt + escalate.
#   - DRY_RUN=1 → prints what it WOULD do, no writes.
#   - No edits to city.toml, pack.toml, or crew skill files.
#   - Idempotent: skips stories already labeled story:done.
#
# Usage:
#   bash story-delivery.sh            # normal run
#   DRY_RUN=1 bash story-delivery.sh  # dry-run (proof mode)
#   STORY_ID=ga-b8t bash story-delivery.sh  # force single story
#   DRY_RUN=1 STORY_ID=ga-b8t bash story-delivery.sh  # dry-run single story

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/story-delivery.log"
DELIVERY_LOG="$GC_CITY/.gc/story-delivery.jsonl"
RUNBOOK_FILE="$GC_CITY/packs/town-deltas/assets/delivery-runbooks.toml"

DRY_RUN="${DRY_RUN:-0}"
FORCE_STORY_ID="${STORY_ID:-}"  # If set, process only this story

# ═════════════════════════════════════════════════════════════════════════════
# ga-266z8: merge-verification helpers for the Step 1b task/bug reconciler below.
# NEVER trust a gate:passed LABEL alone before closing a bead — see Step 1b for
# the full rationale (confirmed false-closes: ga-opyus, ga-t1ub9). These mirror
# merged-bead-janitor.sh's already-audited git helpers verbatim (one proven
# implementation of "verify by content, not label", not a second one to drift).
# ═════════════════════════════════════════════════════════════════════════════

# rig_gitdir <rig_path> — echoes "<git_dir_path>\t<is_container 0|1>".
# Container rigs keep a bare .repo.git (preferred when present); self-repo rigs
# use their working tree .git.
rig_gitdir() {
  local rig_path="$1"
  if [ -d "$rig_path/.repo.git" ]; then
    printf '%s\t1\n' "$rig_path/.repo.git"
  else
    printf '%s\t0\n' "$rig_path"
  fi
}

# git_in <git_dir> <is_container> <git-args...> — run git against a rig repo.
git_in() {
  local gdir="$1" container="$2"; shift 2
  if [ "$container" = "1" ]; then
    git --git-dir="$gdir" "$@"
  else
    git -C "$gdir" "$@"
  fi
}

# token_bounded <bead_id> <text> — rc0 iff text contains bead_id as a whole
# token (not a substring of a longer id).
token_bounded() {
  printf '%s' "$2" | grep -E "(^|[^[:alnum:]-])$1([^[:alnum:]-]|\$)" >/dev/null
}

# subject_impl_scopes_bead <subject_line> <bead_id> — rc0 iff <bead_id> is the
# IMPLEMENTING conventional-commit SCOPE of <subject> (fix(<id>):, feat(area/<id>):,
# a bare "<id>:" lead, etc.) rather than a trailing "(context/<id>)" mention.
subject_impl_scopes_bead() {
  local subj="$1" id="$2" header
  case "$subj" in *:*) : ;; *) return 1 ;; esac
  header="${subj%%:*}"
  case "$header" in [Rr]evert*) return 1 ;; esac
  token_bounded "$id" "$header"
}

# scan_commit_subject_for_bead <git_dir> <is_container> <ref> <bead_id>
# rc0 + prints the first matching sha iff an ancestor commit of <ref> references
# the bead id as an implementing conventional-commit scope in its SUBJECT line —
# i.e. this bead's fix genuinely landed in <ref>'s history. Content check, not a
# branch-name guess (the reconciler has no branch name for a task bead to test).
scan_commit_subject_for_bead() {
  local gdir="$1" container="$2" ref="$3" id="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "$ref" >/dev/null 2>&1 || return 1
  local shas sha subj
  shas=$(git_in "$gdir" "$container" log "$ref" -F --grep="$id" --format='%H' 2>/dev/null || true)
  [ -z "$shas" ] && return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    subj=$(git_in "$gdir" "$container" log -1 --format='%s' "$sha" 2>/dev/null || true)
    if subject_impl_scopes_bead "$subj" "$id"; then printf '%s' "$sha"; return 0; fi
  done <<EOF
$shas
EOF
  return 1
}

# task_reconciler_verdict <is_contradicted> <is_merge_verified> [is_partial] —
# pure decision: echoes "close:<reason>" iff gate:passed may be trusted,
# "keep:<reason>" otherwise.
#
# ga-tuk26: a contradicting gate:failed/gate:needs-fix label used to ALWAYS
# win outright — before this fix, the caller never even computed
# is_merge_verified when contradicted (see the call site above this
# function), so a contradicted bead could NEVER earn independent proof and
# sat stuck forever, even after whatever wrote the stale label stopped
# recurring (measured live 6x in one night — wa-6cx36, wa-8ok7u, ga-dnc2m,
# wa-3xd3w, wa-ze2u1, wa-iochp — each unstuck by hand). Fixed on BOTH sides:
# the caller now always runs verification, and this function only trusts
# is_contradicted=1 outright when is_merge_verified is NOT "1" — i.e. it
# never guesses: an unverified contradiction still wins unconditionally
# (fail-safe, unchanged). Once independently PROVEN stale (a real commit for
# this bead verified in origin/<default_branch>), the contradiction is
# resolved and the bead falls through to the SAME rules as any other
# verified bead below — including the ga-k2wjn partial-scope check: a
# resolved contradiction is not a scope signal, so a bead whose body looks
# like it enumerates multiple approved deliverables is still kept
# (keep:partial-delivery) rather than closed outright. Absent partial too,
# the verified-merged bead closes — with a distinct verdict string
# (close:contradicted-but-...) so the caller knows to also clear the stale
# labels as part of closing.
# is_partial defaults to "0" so existing 2-arg call sites are unaffected.
# Absent all of the above, the bead must show independent content proof
# before the sweep may close it.
task_reconciler_verdict() {
  local is_contradicted="$1" is_merge_verified="$2" is_partial="${3:-0}"
  if [ "$is_contradicted" = "1" ] && [ "$is_merge_verified" != "1" ]; then
    echo "keep:contradicted-by-gate-failed-or-needs-fix"
    return 0
  fi
  if [ "$is_partial" = "1" ]; then
    echo "keep:partial-delivery"
    return 0
  fi
  if [ "$is_merge_verified" = "1" ]; then
    if [ "$is_contradicted" = "1" ]; then
      echo "close:contradicted-but-commit-verified-in-origin-main"
    else
      echo "close:commit-in-origin-main"
    fi
    return 0
  fi
  echo "keep:merge-not-verified"
}

# task_reconciler_failed_sha_resolved <gdir> <container> <ref> <labels> —
# ga-as3p1. Three-state answer about the SPECIFIC sha(s) the gate rejected
# (gate-sha-failed:<sha>[:<class>], quality-gate-dispatcher.sh's
# gate_sha_fail_label — stamped in the SAME write as gate:failed/
# gate:needs-fix; see quality-gate-dispatcher.sh:4305-4314/4373):
#   "yes"    — at least one gate-sha-failed sha was found, and EVERY one is
#              now an ancestor of <ref> (reuses story_merge_verdict, defined
#              below in the STORY helpers section — one sha+ref ancestry
#              check, not a second copy that could drift).
#   "no"     — at least one gate-sha-failed sha was found, and at least one
#              is NOT an ancestor of <ref> — the rejection is still live.
#   "absent" — no gate-sha-failed stamp on this bead at all. Distinct from
#              "no": there is nothing here to disprove staleness with, so
#              the caller must fall back to its own (bead-scoped) evidence
#              rather than guess in either direction ("could not verify" and
#              "verified negative" must not collapse to the same value).
#
# Why this exists (not scan_commit_subject_for_bead, above): that proves
# "SOME commit for this bead id is in <ref>" — true for ANY slice that ever
# passed, not necessarily the slice that is CURRENTLY failing. Measured live
# (wa-7l2u3): slice 8b2c5ffe passed and merged; slice df90c973 failed the
# gate (ga-7ppa7) and never merged (`git merge-base --is-ancestor df90c973
# origin/main` → no; the bead's real label set carried
# gate-sha-failed:df90c9737596394969e78ee66382759e355a0ca6). The bead-scoped
# scan found 8b2c5ffe, called the coexisting gate:failed stale, and erased a
# live, correct rejection (an off-by-one timezone bug) — the bead was left
# looking approved with the bug still in it. Multiple stamps (e.g. an
# ancient superseded rejection alongside a live one) resolve to "no" as a
# set — one still-unmerged sha is enough to keep the labels: same
# asymmetric-cost reasoning as elsewhere in this file (keeping a stale FAIL
# costs a re-verification; erasing a live one ships a bug marked approved).
task_reconciler_failed_sha_resolved() {
  local gdir="$1" container="$2" ref="$3" labels="$4"
  local sha found=0
  for sha in $(printf '%s\n' "$labels" | tr ' ' '\n' \
      | sed -n 's/^gate-sha-failed:\([0-9a-f]\{4,40\}\)\(:[a-z]*\)\{0,1\}$/\1/p' | sort -u); do
    found=1
    story_merge_verdict "$gdir" "$container" "$ref" "$sha" >/dev/null 2>&1 || { echo "no"; return 0; }
  done
  if [ "$found" = "1" ]; then echo "yes"; else echo "absent"; fi
}

# ═════════════════════════════════════════════════════════════════════════════
# ga-mmdm2: pre-deploy merge-verification helpers for the STORY delivery loop
# below (Step 3.6). gate:passed is a LABEL, not proof the story's commit ever
# reached the rig's remote main — the story path had NO check at all before
# this (unlike the ga-266z8 task-reconciler block above, which already verifies
# by content). Proven broken live on ga-sb11i.2: gate:passed AND
# gate-sha-failed on the SAME sha, the commit existing only on its feature
# branch — deploy would have pulled the rig's main as-is (no fix) and still
# marked the story done, losing 511 reviewed lines of work. These helpers
# apply the same "verify by content, never by label" discipline to that gap.
# ═════════════════════════════════════════════════════════════════════════════

# extract_gate_merge_info <bd_comments_text> — echoes "<rig>/<branch>\t<sha>"
# from the LAST "... merged to <rig>/<branch> (sha=<sha>)" gate-dispatcher
# comment (quality-gate-dispatcher.sh's PASSED comment). A story can accumulate
# several gate:fix-attempt cycles, so only the MOST RECENT merge comment is
# authoritative — never gate-sha-failed:<sha>, which records what FAILED, not
# what merged. rc1 + no output when no such comment exists — the caller must
# treat that as UNVERIFIED, not skip the check (ga-mmdm2 control #2: an absent
# merge comment is itself evidence the merge never happened).
extract_gate_merge_info() {
  local text="$1" line rig_branch sha
  line=$(printf '%s\n' "$text" \
    | grep -oE 'merged to [a-z_]+/[A-Za-z0-9_.-]+ \(sha=[0-9a-f]{7,40}\)' \
    | tail -1)
  [ -n "$line" ] || return 1
  rig_branch=$(printf '%s' "$line" | sed -E 's#^merged to ([a-z_]+/[A-Za-z0-9_.-]+) \(sha=.*#\1#')
  sha=$(printf '%s' "$line" | sed -E 's#.*\(sha=([0-9a-f]{7,40})\).*#\1#')
  [ -n "$rig_branch" ] && [ -n "$sha" ] || return 1
  printf '%s\t%s' "$rig_branch" "$sha"
}

# extract_gate_merge_pre_main <bd_comments_text> — echoes the pre-merge main
# sha from the LAST "... merged to <rig>/<branch> (sha=<sha>)
# (pre_merge_main=<sha>)" gate-dispatcher comment (quality-gate-dispatcher.sh,
# ga-6zkhci fix-attempt-3). A SEPARATE function from extract_gate_merge_info
# above rather than a 3rd return field on it — that function's "<rig>/
# <branch>\t<sha>" contract is depended on verbatim by two callers (this
# file's own Step 3 and derive_rig_from_comments), and re-splitting a 3-tuple
# at the call sites risked corrupting the already-twice-hardened MERGE_SHA
# parse (ga-fic5d, ga-mmdm2) for zero benefit — a new field is safer as a new
# function over the same raw text.
#
# rc1 + no output when the most recent merge comment carries no
# pre_merge_main field at all — an older-format comment (predating this
# fix) or a merge whose own MAIN_HEAD_SHA capture was empty. The caller MUST
# treat that as UNKNOWN, never as "no base needed": Mayor decision (ga-6zkhci,
# 2026-09-15) explicitly rules out guessing a substitute (e.g. MERGE_SHA^,
# fix-attempt-2's bug) when the real pre-merge baseline was never recorded.
#
# The regex requires sha= and pre_merge_main= adjacent on the SAME matched
# line as extract_gate_merge_info's own pattern (not a bare global grep for
# "pre_merge_main=" anywhere in the comment text) — this guarantees whatever
# is returned came from the exact same merge event as the sha
# extract_gate_merge_info returns, never a different, stale comment that
# happens to mention the string.
extract_gate_merge_pre_main() {
  local text="$1" line sha
  line=$(printf '%s\n' "$text" \
    | grep -oE 'merged to [a-z_]+/[A-Za-z0-9_.-]+ \(sha=[0-9a-f]{7,40}\) \(pre_merge_main=[0-9a-f]{7,40}\)' \
    | tail -1)
  [ -n "$line" ] || return 1
  sha=$(printf '%s' "$line" | sed -E 's#.*\(pre_merge_main=([0-9a-f]{7,40})\).*#\1#')
  [ -n "$sha" ] || return 1
  printf '%s' "$sha"
}

# derive_rig_from_comments <bd_comments_text> — echoes just the <rig> segment
# of the MOST RECENT authoritative gate-dispatcher merge comment, by
# delegating entirely to extract_gate_merge_info() above (one source of
# truth for "what does a real gate-merge comment look like", not two). rc1 +
# no output when no such comment exists, exactly mirroring
# extract_gate_merge_info's own contract.
#
# ga-aqqj0: this REPLACES a second, looser, independently-drifted regex that
# used to live inline at this file's Step 2 (rig resolution) —
#   grep -oE "merged to [a-z_]+/main" | head -1
# — matched against ALL of a story's comment text concatenated together, with
# two compounding defects:
#   1. No "(sha=...)" anchor, so it also matched incidental HUMAN PROSE that
#      merely QUOTES a gate comment while narrating something else — e.g. a
#      Mayor comment retelling '...citando "code merged to origin/main —
#      commit-in-origin-main [a43d1a267]"' while explaining what a DIFFERENT
#      bot (merged-bead-janitor) had written. "origin" there is the git
#      REMOTE name (see that janitor's own boilerplate phrasing), never a
#      rig — but the regex cannot tell prose-about-a-comment from the
#      dispatcher's own comment.
#   2. `head -1` (first match across the WHOLE history) instead of `tail -1`
#      (most recent) — so that early, incidental false match could shadow a
#      later, real, well-formed "merged to gascity/main (sha=...)" comment
#      from the actual gate dispatcher.
# Live proof: ga-dv2gk resolved RIG="origin" this way, and no runbook entry
# for "origin" will ever exist — Step 3 (deploy_cmd lookup) HALTED on a
# 5-minute retry loop, 18 identical "no deploy_cmd for rig 'origin'" comments
# in 1 hour, even though the story's real fix was already merged to gascity's
# actual main. See story-delivery.selftest.sh section 5b for the regression
# test against this exact comment shape.
derive_rig_from_comments() {
  local text="$1" info
  info=$(extract_gate_merge_info "$text") || return 1
  printf '%s' "${info%%/*}"
}

# story_merge_verdict <gdir> <container> <branch_ref> <sha> — echoes
# "verified"|"not-ancestor"|"unresolvable"; rc0 iff "verified". Content check:
# does <branch_ref> (e.g. origin/main, already fetched by the caller) CONTAIN
# <sha> (the commit the gate said it merged)? Fails closed to "unresolvable"
# (rc1) if either <sha> or <branch_ref> cannot be resolved in <gdir> at all —
# unresolvable is not proof of absence, but it is also not proof of merge, so
# it must never be treated the same as "verified" (ga-mmdm2:
# "não consegui verificar" and "verifiquei e está ok" must not produce the
# same result).
#
# DISTINCT from this file's existing post-deploy staleness check (~line 860,
# `merge-base --is-ancestor "$STALE_REF" HEAD`) — that asks "is the LOCAL
# runtime tree fresh relative to origin" (ga-rhtu), already assuming origin has
# the fix. This asks the prior question: did the story's own commit reach
# origin's main AT ALL (ga-mmdm2). Both gaps are real and different.
#
# ga-d5rrr: strict ancestry ALONE false-negatives when <sha>'s own commit was
# rebased or squashed before landing — the same content reaches <branch_ref>
# under a DIFFERENT sha (new parent ⇒ new hash even though the diff is
# identical), so <sha> is never an ancestor even though nothing it carries is
# actually missing. Per the ga-d5rrr bug report, the Mayor's manual triage hit
# this exact false reading on 4 beads in one day (2026-09-01:
# wa-uc0uw/wa-96eth/wa-llxua/wa-shfen) — `git merge-base --is-ancestor` said
# "not merged" while `git cherry origin/main origin/<branch>` showed zero
# pending commits (content 100% delivered); this repo's own
# gate-passed-not-mean-merged-never-verifies incident log independently
# confirms the SAME false-negative shape already occurred live against THIS
# function (story_merge_verdict, ga-fgdmol addendum, 2026-08-16 — squash
# merge, sha mismatch, correct fix identified there as "verify by content").
# The check below mirrors the SAME patch-id / content-equivalence technique
# already proven live in merged-bead-janitor.sh's content_in_main()
# (wa-fvxj1: squash, count 0 → correctly treated as merged) — reimplemented
# here rather than shared, since the two scripts don't currently cross-source
# each other's functions. A cherry-pick right-only count of 0 means every
# commit reachable from <sha> but not <branch_ref> has an equivalent-patch
# commit ALREADY on <branch_ref> — i.e. nothing <sha> carries is actually
# missing from it.
story_merge_verdict() {
  local gdir="$1" container="$2" branch_ref="$3" sha="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1 || { echo "unresolvable"; return 1; }
  git_in "$gdir" "$container" rev-parse -q --verify "$branch_ref" >/dev/null 2>&1 || { echo "unresolvable"; return 1; }
  if git_in "$gdir" "$container" merge-base --is-ancestor "$sha" "$branch_ref" 2>/dev/null; then
    echo "verified"
    return 0
  fi
  local cherry_count
  cherry_count=$(git_in "$gdir" "$container" rev-list --count --cherry-pick --right-only "${branch_ref}...${sha}" 2>/dev/null || echo "ERR")
  if [ "$cherry_count" = "0" ]; then
    echo "verified"
    return 0
  fi
  echo "not-ancestor"
  return 1
}

# gate_delivery_looks_partial() and its helpers (_gate_delivery_header_class,
# _gate_delivery_list_run, plus v4's _gate_delivery_norm/_enumerates/
# _item_is_verification/_run_verdict) used to be copy-pasted here, with a
# comment claiming they mirrored quality-gate-guard.sh's copy "VERBATIM...
# kept in sync by inspection". That claim went stale — guard.sh advanced to
# v4 (ga-cjrxh: catches UPPERCASE lettered lists and title-level enumeration;
# AC3: distinguishes an empty body from an evaluated-and-clean one on stderr)
# while this copy stayed at v3 — and nothing caught the drift, because the
# comment itself told the next reader to stop looking (ga-3k70w2). Source the
# real implementation instead of maintaining a second one to drift, same
# pattern quality-gate-dispatcher.sh already uses for this exact file (see
# its GATE_GUARD_LIB_ONLY source, ga-bnu1). Resolved relative to this
# script's own location (not $GC_CITY) so a caller running from a review
# worktree still pairs with the guard.sh from the SAME checkout.
# ga-q4sadt: `2>/dev/null || true` does NOT guard this. `source` is a POSIX
# special builtin, and this file runs under `set -euo pipefail` (L32) — an
# unreadable target kills the shell IMMEDIATELY, before `|| true` is ever
# evaluated (measured on /bin/bash 3.2.57: `source /missing.sh 2>/dev/null ||
# true; echo REACHED` exits 1, REACHED never prints). A briefly missing or
# desynced quality-gate-guard.sh sibling — the exact partial-deploy failure
# class packs/town-deltas/assets/ has hit before — would silently kill this
# script's entire top-level init, before any log/warn call exists: the
# delivery reconciler goes dark every launchd cycle, and merged beads never
# close, with nothing anywhere explaining why. Same defect ga-vmn7kv already
# fixed in pilot-dispatcher.sh/context-check-dispatcher.sh; this file and
# quality-gate-dispatcher.sh were the two pre-existing instances left out of
# that diff on purpose (scope). Check readability BEFORE sourcing instead:
# `[ -r ]`, not `[ -f ]` — an existing-but-unreadable file still kills a bare
# `source` (measured: exit 1, "Permission denied"). stderr on the source
# itself is intentionally NOT suppressed: a corrupt sibling (syntax error)
# should be loud, not silent — that's a deploy fault, not a legitimate
# absence.
_STORY_DELIVERY_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_STORY_DELIVERY_GUARD_SIB="${_STORY_DELIVERY_SELF_DIR}/quality-gate-guard.sh"
if [ -r "$_STORY_DELIVERY_GUARD_SIB" ]; then
  GATE_GUARD_LIB_ONLY=1 source "$_STORY_DELIVERY_GUARD_SIB"
fi
# ga-rj7b1a: Step 6 runs the rig's prod tests, which can be heavy suites (pytest, the
# pilot selftest). Lower THIS process's priority now (ni 15) so everything it spawns
# inherits it and never competes with Dolt / the supervisor on equal terms. Safe for
# this driver: daemons are restarted through `launchctl kickstart` (launchd-owned, so
# they do not inherit); the driver itself is not latency-critical. Same readability
# rule as the sibling above: a missing helper must not kill the init — the priority is
# a courtesy, so it degrades to "runs at the inherited priority", never to "no delivery".
_STORY_DELIVERY_HSG_SIB="${_STORY_DELIVERY_SELF_DIR}/heavy-selftest-guard.sh"
if [ -r "$_STORY_DELIVERY_HSG_SIB" ]; then
  source "$_STORY_DELIVERY_HSG_SIB"
  heavy_selftest_lowprio
fi
unset _STORY_DELIVERY_SELF_DIR _STORY_DELIVERY_GUARD_SIB _STORY_DELIVERY_HSG_SIB
# guard.sh sets its OWN LOG=$LOG_DIR/quality-gate-guard.log at source time —
# restore ours (GC_CITY/LOG_DIR are already identical in both files, so only
# LOG needs it). Mirrors quality-gate-dispatcher.sh's identical restore right
# after its own guard.sh source (ga-l47b7) — without it this script's own log
# output would silently start flowing into quality-gate-guard.log instead.
LOG="$LOG_DIR/story-delivery.log"

# task_reconciler_is_partial <already_partial 0|1> <scope_covered_all 0|1> <text> [title]
#   Pure decision (ga-3k70w2 DEFEITO 4): scope_covered:all is an explicit
#   author override and must win even over a PRIOR delivery:partial hold —
#   this sweep applies delivery:partial itself when it holds (see call site),
#   so once held, testing already_partial first meant scope_covered:all could
#   never run again on a later sweep: the exact label the hold-mail tells a
#   human to add then had no effect, holding the bead forever (the real
#   wa-agkop case, 2026-08-16). Order here is deliberate and load-bearing —
#   do not swap it back.
#   Prints partial evidence (if any) on stdout; rc0 iff the bead is partial.
task_reconciler_is_partial() {
  local already_partial="$1" scope_covered_all="$2" text="$3" title="${4:-}"
  if [ "$scope_covered_all" = "1" ]; then
    return 1
  elif [ "$already_partial" = "1" ]; then
    return 0
  else
    gate_delivery_looks_partial "$text" "$title"
  fi
}

# refino_criteria_status_line <missing_meta>
#   Pure decision (ga-t6wlfb): the Step 8 "Delivery COMPLETE" comment must
#   reflect Step 7's OWN finding about refino metadata (story.estrela_guia,
#   story.equilibrios, story.dashboard), never assert "verified" when Step 7
#   already found (and warned about) fields missing on this same bead in this
#   same delivery run. Previously both COMPLETE templates hardcoded the
#   "verified" line unconditionally, contradicting the WARNING comment posted
#   two seconds earlier by Step 7 whenever $missing_meta was non-empty.
#   <missing_meta>: space-prefixed list of missing field names, or "" if none
#   missing (the exact $MISSING_META value Step 7 already computed).
refino_criteria_status_line() {
  local missing_meta="${1:-}"
  if [ -n "$missing_meta" ]; then
    echo "Refino criteria: INCOMPLETE (missing:$missing_meta) — see WARNING above"
  else
    echo "Criteria verified: estrela_guia, equilibrios, dashboard (see bead metadata)"
  fi
}

# task_reconciler_gate_passed_too_fresh <updated_at_iso> <now_epoch> <min_age_minutes>
#   wa-n27z0: pure decision — rc0 (true) iff the bead's last update is younger
#   than min_age_minutes. The task reconciler (Step 1b below) must not act on a
#   gate:passed non-story bead until enough wall-clock time has passed for the
#   SAME (still-running, NOT crashed) quality-gate-dispatcher.sh invocation
#   that set gate:passed to also finish its own daemon-liveness check and land
#   delivery:pending-restart if a hold applies (ga-l7n3v) — the
#   TASK_PENDING_RESTART veto right below this function's call site only helps
#   once that label actually exists.
#
#   Measured live 2026-09-09 on 5 beads in one morning (wa-olqmv, wa-a5c4g,
#   wa-8oe0t, wa-0161a, wa-f1anj — see wa-n27z0): gate:passed and
#   delivery:pending-restart are set by the SAME dispatcher run, but 391-604s
#   (6.5-10min) apart — quality-gate-dispatcher.sh sets gate:passed EARLY
#   (ga-esbg, so the Pilot stops re-dispatching and story-delivery can pick the
#   bead up), then runs its daemon-liveness check afterward, which can take
#   several minutes. That gap is comfortably longer than this reconciler's own
#   ~5min sweep interval (launchd StartInterval=309s), so the very NEXT sweep
#   after gate:passed reliably raced ahead of the verdict and closed all 5
#   beads before the hold label ever appeared — silently erasing the "daemon
#   still stale" signal the hold exists to preserve (sibling bead wa-omfug:
#   the daemons really were stale, unnoticed for hours as a result).
#
#   updated_at is used as the age anchor rather than a dedicated
#   gate:passed-label-add-timestamp lookup: in every observed case the
#   dispatcher's post-merge bookkeeping (label hygiene, comments,
#   scope:advisory, etc.) lands within the same few-second burst as
#   gate:passed itself, so updated_at is an accurate proxy — and erring toward
#   "looks newer than it really is" only makes this MORE conservative (skips
#   longer), never less safe.
#
#   Delegates the actual arithmetic to age_minutes_of (quality-gate-guard.sh,
#   sourced above this point) — but does NOT trust its fallback for an
#   unparseable timestamp uniformly: age_minutes_of only returns age=0 (safe,
#   "very fresh") for an EMPTY ts via its own early-return; a non-empty but
#   GARBLED ts instead falls through to epoch 0 (1970) internally, which this
#   caller's arithmetic would then read as billions of seconds old — i.e. the
#   UNSAFE direction (treated as ancient, allowed to proceed to close). Caught
#   by this function's own selftest (section 10, story-delivery.selftest.sh)
#   before it ever shipped: a bare shape check below on the exact
#   "YYYY-MM-DDTHH:MM:SSZ" form bd always emits for updated_at intercepts any
#   empty/malformed/unrecognized input and returns "too fresh" (defer)
#   directly, so a garbled timestamp can never reach age_minutes_of's unsafe
#   fallback path at all.
#
#   Cost of this check: this reconciler is a crash-recovery fallback (the
#   dispatcher's own direct-close, ga-esbg, is the primary path) that acts on
#   at most one bead per ~5min sweep — a bounded extra delay here is not
#   time-critical. Same asymmetric-cost reasoning ga-266z8 already uses
#   elsewhere in this file: waiting longer costs a few extra sweeps; closing
#   too early destroys a safety signal that is hard to reconstruct after the
#   fact.
task_reconciler_gate_passed_too_fresh() {
  local updated_at="$1" now_epoch="$2" min_age_minutes="$3"
  case "$updated_at" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) return 0 ;;  # empty, malformed, or unrecognized shape -> too fresh (defer)
  esac
  # ga-fapnl (gate-feedback on this bead's own first attempt): age_minutes_of
  # is sourced CONDITIONALLY above ("if [ -r "$_STORY_DELIVERY_GUARD_SIB" ]")
  # — a transiently unreadable/missing guard.sh sibling (the exact
  # partial-deploy class this file's init comment already documents) leaves
  # the symbol undefined. Calling it anyway from inside this function's own
  # if-condition call site does NOT trip `set -e` (bash exempts if/while/&&/||
  # conditions, recursively into the callee) — the resulting error read as
  # "not too fresh" and proceeded, reproducing the exact race this function
  # exists to close, via a different path than the garbled-timestamp case
  # above. Fail closed the same way: can't verify freshness -> defer.
  type age_minutes_of >/dev/null 2>&1 || return 0
  local age_min
  age_min=$(age_minutes_of "$updated_at" "$now_epoch")
  # Same third-state family as the guard above, one level further in: even
  # with age_minutes_of callable, don't trust its output blind before using
  # it as a `-lt` operand — a non-numeric result (future internal change,
  # unexpected input) must also fail toward "too fresh", not throw an
  # "integer expression expected" that (per the same if-condition exemption
  # above) reads as non-zero -> proceed.
  case "$age_min" in
    ''|*[!0-9]*) return 0 ;;  # non-numeric -> can't compare -> too fresh (defer)
  esac
  [ "$age_min" -lt "$min_age_minutes" ]
}

# task_gate_passed_age_anchor <updated_at_iso_or_empty> <last_event_at_iso_or_empty>
#   wa-x6ggx: PURE picker — returns whichever of the two ISO-8601 timestamps is
#   MORE RECENT. Exists because `bd label add`/`bd label remove` NEVER bump a
#   bead's `updated_at` field (confirmed empirically 2026-09-09 against a live
#   claimed bead: added a label, updated_at was byte-for-byte unchanged) — and
#   gate:passed is ALWAYS applied via `bd label add` (quality-gate-
#   dispatcher.sh:5193), a label-only mutation. So updated_at ALONE can read as
#   arbitrarily OLDER than when gate:passed actually landed, whenever no OTHER
#   genuine (non-label) mutation happens to coincide with it — silently
#   defeating task_reconciler_gate_passed_too_fresh in the UNSAFE direction
#   (looks older than it really is -> proceeds to close before delivery:
#   pending-restart has had time to land, reproducing the exact wa-n27z0 race
#   this whole mechanism exists to close, just via a different anchor bug than
#   either guard that function already hardens against). Live repro: wa-1psgk
#   (2026-09-09 14:38:41-47 BRT) — gate:passed added, the reconciler closed it
#   6 SECONDS later; updated_at read the timestamp of an earlier, unrelated
#   content update because the intervening label additions (gate:queued,
#   gate:reviewing, gate:passed) never touched it.
#
#   Comparison is plain string ">" — safe ONLY because both inputs, once
#   shape-validated, are the fixed-width "YYYY-MM-DDTHH:MM:SSZ" form bd always
#   emits, for which lexicographic order equals chronological order (same
#   assumption task_reconciler_gate_passed_too_fresh's own header already
#   relies on for its shape-check). Repeats that function's tiny case-guard
#   inline rather than factor out a shared helper — this file's established
#   idiom for a 3-line check, see that function itself. An invalid/empty
#   candidate is simply never preferred; if BOTH are invalid/empty, returns
#   the first argument (possibly empty/malformed) unchanged and lets
#   task_reconciler_gate_passed_too_fresh's own shape-check — unchanged —
#   fail closed exactly as it already does today. This function only ever
#   improves the INPUT to that check; it adds no second decision point.
task_gate_passed_age_anchor() {
  local a="$1" b="$2"
  local a_ok=0 b_ok=0
  case "$a" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) a_ok=1 ;;
  esac
  case "$b" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) b_ok=1 ;;
  esac
  if [ "$a_ok" = "1" ] && [ "$b_ok" = "1" ]; then
    if [ "$b" \> "$a" ]; then echo "$b"; else echo "$a"; fi
  elif [ "$b_ok" = "1" ]; then
    echo "$b"
  else
    echo "$a"
  fi
}

# task_bead_last_event_at <store> <bead_id>
#   wa-x6ggx: thin LIVE-data fetch, deliberately kept separate from the pure
#   picker above so it can be overridden/faked in the selftest (same
#   dependency-injection pattern this file already uses for age_minutes_of,
#   see selftest section 10) — this selftest suite runs with NO live Dolt/gc/
#   launchd (see this file's own header), so this function is never
#   unit-tested directly, only via override.
#
#   Queries the standard `events` audit table (NOT the opt-in
#   bd_events_journal, which requires explicit enablement per `bd events
#   --help` and is not guaranteed on for every rig) for this bead's most
#   recent mutation of ANY kind — not narrowed to the specific "Added label:
#   gate:passed" comment text, both because that exact text is not a stable
#   contract to match against and because any recent touch (a further label
#   after gate:passed, say) is at least as good a "still potentially
#   mid-flight" signal.
#
#   Bead id is shape-validated before interpolation into the SQL string
#   (defense in depth — ids are always bd-generated, never user input, but
#   this file's own established style never trusts that alone; see e.g. the
#   updated_at shape-checks throughout). The guard REJECTS anything containing
#   a character outside [a-zA-Z0-9_-] (this is a character-class exclusion,
#   not a "must contain a hyphen" positive match — a naive `[a-zA-Z]*-*`
#   glob looks like it requires a hyphen but does NOT: `-*` matches zero
#   occurrences too, so it would silently accept a hyphen-free string;
#   caught in this bead's own selftest before shipping). Also rejects empty.
#   Fails closed: any failure (malformed id, bd sql unavailable/erroring/
#   timing out, empty result, unparseable JSON) returns an EMPTY string,
#   which task_gate_passed_age_anchor above treats as "no better information"
#   and task_reconciler_gate_passed_too_fresh's own shape-check treats as
#   "too fresh, defer" if it ends up the sole anchor — never LESS
#   conservative than today's updated_at-only behavior, only ever more.
task_bead_last_event_at() {
  local store="$1" bead_id="$2"
  case "$bead_id" in
    ""|*[!a-zA-Z0-9_-]*) echo ""; return ;;
  esac
  timeout 10 bd -C "$store" sql --json \
    "SELECT created_at FROM events WHERE issue_id='$bead_id' ORDER BY created_at DESC LIMIT 1" \
    2>/dev/null | jq -r '.[0].created_at // ""' 2>/dev/null || echo ""
}

# ga-rugqks: Step 1's selector (story:approved + gate:passed, minus
# story:done) decides which beads enter the per-story loop, but the loop
# body itself then never re-checks a bead's CURRENT status before mutating
# it — it only ever reads $STORY_LABELS, a snapshot taken once at Step 1.
# A bead can be closed OUT OF BAND (e.g. a human closing it directly after
# independently verifying delivery) at any point between that snapshot and
# this iteration's own mutations, and Step 5b's own daemon-refresh
# subprocess alone is documented elsewhere in this file
# (task_reconciler_gate_passed_too_fresh's header, wa-n27z0) to take up to
# 6.5-10 minutes per cycle — plenty of time for exactly that race. Live
# case: wa-a7tca was closed by the Mayor at 21:23:57 (delivered, verified
# live); the sweep still in flight re-added delivery:failed +
# delivery:deploy-pending and re-nudged its owner at 21:33:55, ~10 minutes
# later, over work that was already done.
#
# Call this immediately before any label/comment/nudge mutation (and before
# re-running deploy/reconcile/merge-verify) so an externally-closed bead is
# never reprocessed. Always re-queries live state via `bd show` (never
# trusts $STORY_LABELS). Fails OPEN (returns 1 / "not closed") on any bd
# error, empty, or unparseable result — a transient bd hiccup must never
# look identical to "already closed" and silently swallow a genuine
# delivery halt/failure that still needs to be reported.
story_bead_closed_now() {
  local store="$1" bead_id="$2"
  local status
  status=$(bd -C "$store" show "$bead_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | .status // ""' 2>/dev/null || echo "")
  [ "$status" = "closed" ]
}

# ga-c3oyk6: unix epoch at which <sha> became reachable from <runtime_dir>'s HEAD
# — when the merge's code actually landed in the checkout the daemons run from.
# It is the bead-scoped freshness re-probe's floor (Step 5b) in place of
# DEPLOY_EPOCH, which is "now" for THIS sweep iteration. On a retry (hold ->
# ops restart the daemon -> the next sweep re-checks) every daemon restarted
# between the first deploy and the retry sits BEFORE the retry's DEPLOY_EPOCH,
# so it can only reach already_fresh()'s weaker "correlation" tier
# (PROOF=not_verified) and the story is closed delivery:daemon-unverified
# ("may still be dormant") over daemons that provably started AFTER the code
# arrived. Live: wa-0n0bj 2026-09-20 — merge landed 03:31:46Z, demand-dashboard
# restarted 03:39:47Z, the retry's DEPLOY_EPOCH was 03:44Z.
#
# Read from HEAD's reflog, newest first: the entries whose commit contains <sha>
# form the current "arrival run" and the answer is the OLDEST entry of that run.
# Never guesses: prints NOTHING (the caller keeps its own DEPLOY_EPOCH) when the
# runtime is not a git checkout, <sha> is unknown to it, the newest reflog entry
# does not contain <sha> (the merge is not in the runtime at all), or a
# timestamp does not parse. Reaching the $cap bound, an unreadable entry or the
# end of the reflog prints the oldest run entry seen — LATER than the true
# arrival, i.e. only ever stricter for a freshness floor, never looser.
runtime_arrival_epoch() {  # runtime_arrival_epoch <runtime_dir> <sha> [<cap>]
  local rt="$1" sha="$2" cap="${3:-500}" n=0 arrival="" ent when
  [ -n "$rt" ] && [ -n "$sha" ] || return 0
  git -C "$rt" rev-parse --verify -q "${sha}^{commit}" >/dev/null 2>&1 || return 0
  while IFS=' ' read -r ent when; do
    [ -n "$ent" ] || continue
    n=$((n + 1))
    [ "$n" -le "$cap" ] || break
    git -C "$rt" merge-base --is-ancestor "$sha" "$ent" 2>/dev/null || break
    when="${when//[^0-9]/}"   # HEAD@{1789875106} -> 1789875106 (no braces: bash 3.2)
    [ -n "$when" ] || { arrival=""; break; }
    arrival="$when"
  done < <(git -C "$rt" reflog show --date=unix --format='%H %gd' HEAD 2>/dev/null)
  printf '%s' "$arrival"
}

# Lib-only mode: `STORY_DELIVERY_LIB_ONLY=1 source story-delivery.sh` defines the
# helpers above without running the live sweep, so the selftest exercises the
# real functions (one source of truth, no copy-drift). Mirrors merged-bead-janitor.sh.
[ "${STORY_DELIVERY_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [story-delivery] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [story-delivery] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [story-delivery] WARN: $*"; }

echo ""
log "=== Delivery sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Step 0a: daemon-refresh baseline staleness alarm (ga-gjum0y) ──────────────
# Runs once per sweep, unconditionally — deliberately NOT inside Step 5b below,
# which only executes for a rig that HAS a story awaiting delivery right now.
# The whole incident this closes is a baseline stuck for 5 days while zero
# stories reached OK|SKIPPED for that rig — gating the alarm on the same
# story traffic that stopped flowing would reproduce the exact silence being
# fixed. Self-contained: scans whatever *.sha files this mechanism has itself
# already written under daemon-refresh-baseline/ (one per rig that has ever
# gone through Step 5b at least once) — no separate rig-enumeration needed.
# Dedup is by the SHA VALUE the marker is stuck at, not by wall-clock time:
# a baseline stuck on the same sha for 40 sweeps alarms once, but a baseline
# that recovers and later gets stuck on a DIFFERENT sha is a new episode and
# alarms again (invariant c: "um por sequência", never permanent silence).
DAEMON_REFRESH_BASELINE_DIR_TOP="$GC_CITY/.gc/runtime/daemon-refresh-baseline"
DAEMON_REFRESH_STALE_DAYS="${DAEMON_REFRESH_STALE_DAYS:-2}"
if [ -d "$DAEMON_REFRESH_BASELINE_DIR_TOP" ]; then
  for _drb_sha_file in "$DAEMON_REFRESH_BASELINE_DIR_TOP"/*.sha; do
    [ -f "$_drb_sha_file" ] || continue
    _drb_rig="$(basename "$_drb_sha_file" .sha)"
    # macOS (BSD stat) and Linux (GNU stat) spell "mtime as epoch seconds"
    # differently — try both, same fallback idiom used elsewhere in this repo.
    _drb_mtime="$(stat -f %m "$_drb_sha_file" 2>/dev/null || stat -c %Y "$_drb_sha_file" 2>/dev/null || echo "")"
    if [ -z "$_drb_mtime" ]; then
      warn "daemon-refresh baseline staleness check: could not stat $_drb_sha_file (unknown mtime) — skipping this rig this sweep, not silently treating as fresh."
      continue
    fi
    _drb_age_days=$(( ( $(date +%s) - _drb_mtime ) / 86400 ))
    if [ "$_drb_age_days" -ge "$DAEMON_REFRESH_STALE_DAYS" ]; then
      _drb_sha_value="$(cat "$_drb_sha_file" 2>/dev/null || echo "")"
      _drb_alarm_marker="$DAEMON_REFRESH_BASELINE_DIR_TOP/$_drb_rig.staleness-alarmed"
      _drb_already_alarmed="$(cat "$_drb_alarm_marker" 2>/dev/null || echo "")"
      if [ -n "$_drb_sha_value" ] && [ "$_drb_already_alarmed" = "$_drb_sha_value" ]; then
        : # already alarmed for this exact stuck sha — do not repeat every sweep
      else
        warn "daemon-refresh baseline for rig $_drb_rig has not advanced in ${_drb_age_days}d (stuck at ${_drb_sha_value:-<empty>}) — alarming (ga-gjum0y; this used to be silent)."
        if [ "$DRY_RUN" != "1" ]; then
          gc --city "$GC_CITY" session nudge mayor \
            "daemon-refresh baseline for rig $_drb_rig frozen ${_drb_age_days}d at ${_drb_sha_value:-<empty>} — every deploy's diff window keeps widening (ga-gjum0y). Likely cause: some daemon/scheduled-job on this rig can never reach OK|SKIPPED (e.g. a real NEEDS_GUARDED_RESTART nobody restarted, or a scheduled-job installation gap with no opt-out recorded in restart_policy.yaml)." \
            2>/dev/null || true
          # Record the marker even if the nudge above failed (gc unreachable,
          # etc.) — a lost notification should not ALSO turn into permanent
          # spam every 5 minutes; the next distinct stuck sha still alarms.
          printf '%s' "$_drb_sha_value" > "$_drb_alarm_marker" 2>/dev/null || true
        fi
      fi
    fi
  done
fi

# ── Step 0: Read runbook file ─────────────────────────────────────────────────
# Parse TOML runbook via Python (available everywhere this runs).
if [ ! -f "$RUNBOOK_FILE" ]; then
  err "Runbook file not found: $RUNBOOK_FILE"
  exit 1
fi

get_runbook_field() {
  local rig_name="$1"
  local field="$2"
  python3 - <<PYEOF
import re, sys

rig_name = '$rig_name'
field = '$field'

with open('$RUNBOOK_FILE') as f:
    content = f.read()

# Find the [[rig]] block for our rig
# Simple parser: split on [[rig]] boundaries, find the one with name = "rig_name"
blocks = re.split(r'\[\[rig\]\]', content)
for block in blocks:
    m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if m and m.group(1) == rig_name:
        # Find the field value
        fm = re.search(rf'{re.escape(field)}\s*=\s*"([^"]*)"', block)
        if fm:
            print(fm.group(1))
        else:
            # Check for array (daemon_restarts = [])
            am = re.search(rf'{re.escape(field)}\s*=\s*\[([^\]]*)\]', block)
            if am:
                items = [x.strip().strip('"') for x in am.group(1).split(',') if x.strip().strip('"')]
                print('\n'.join(items))
        sys.exit(0)
# Not found
sys.exit(1)
PYEOF
}

# ── FIX 1 (ga-857v): safe untracked-vs-tracked reconciliation before ff-pull ──
# Problem: deploy_cmd typically runs `git -C <runtime> pull --ff-only`. If the
# runtime working tree holds an UNTRACKED copy of a file that the incoming merge
# adds as TRACKED (e.g. a live-served daemon that ran as an untracked file
# before its tracked version merged to main), git aborts the ff-pull:
#   "The following untracked working tree files would be overwritten by merge:
#    <file> — Please move or remove them before you merge. Aborting"
# Delivery then sets delivery:failed and the story never reaches story:done,
# even though the merge to main is durable and the content is byte-identical.
#
# This reconciler removes ONLY verified-identical duplicates. For each untracked
# file the incoming upstream adds as tracked, it compares the working-tree bytes
# against the upstream version:
#   IDENTICAL  → back up to /tmp then remove, so the ff-pull lands the tracked
#                copy (the NEVER-auto-revert invariant holds: we only delete a
#                proven-identical duplicate, never real content).
#   DIFFERENT  → do NOT touch it; collect into RECONCILE_DIFF_LIST and return 2
#                so the caller halts + escalates (uncommitted prod work is never
#                destroyed).
# Sets globals RECONCILE_DIFF_LIST (space-separated paths that differ) and
# RECONCILE_COUNT (number auto-reconciled). Honours DRY_RUN.
RECONCILE_DIFF_LIST=""
RECONCILE_COUNT=0
reconcile_untracked_for_ffpull() {
  local dir="$1"
  RECONCILE_DIFF_LIST=""
  RECONCILE_COUNT=0

  # Only meaningful for a real git working tree.
  [ -n "$dir" ] || { log "reconcile: no runtime_dir — skip"; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log "reconcile: $dir is not a git work tree — skip"; return 0; }

  # Determine the incoming upstream ref (e.g. origin/main).
  local upstream remote branch
  upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
  if [ -z "$upstream" ]; then
    branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
    [ -n "$branch" ] && upstream="origin/$branch"
  fi
  [ -n "$upstream" ] || { log "reconcile: no upstream for $dir — skip"; return 0; }
  remote="${upstream%%/*}"

  # Refresh remote refs so the comparison reflects what the pull will merge.
  git -C "$dir" fetch --quiet "$remote" 2>/dev/null \
    || git -C "$dir" fetch --quiet 2>/dev/null || true

  local conflicts=0 u base ts backup
  # Enumerate untracked (non-ignored) files; -z keeps paths with spaces safe.
  while IFS= read -r -d '' u; do
    [ -n "$u" ] || continue
    # Does the incoming upstream add this path as tracked? If not, ignore it
    # (genuine local-only file — leave it completely alone).
    git -C "$dir" cat-file -e "$upstream:$u" 2>/dev/null || continue
    # Collision candidate. Compare working-tree bytes against incoming version.
    if git -C "$dir" show "$upstream:$u" 2>/dev/null | cmp -s - "$dir/$u"; then
      # IDENTICAL → safe to remove so the ff-pull can land the tracked copy.
      base=$(basename "$u")
      ts=$(date +%Y%m%d-%H%M%S)
      backup="/tmp/${base}.backup.${ts}.$$"
      if [ "$DRY_RUN" = "1" ]; then
        log "reconcile: DRY_RUN — WOULD backup+remove identical untracked '$u' (backup $backup)"
      else
        cp -p "$dir/$u" "$backup" 2>/dev/null || cp "$dir/$u" "$backup" 2>/dev/null || true
        rm -f "$dir/$u"
        log "reconcile: auto-reconciled identical untracked '$u' (backup: $backup)"
      fi
      RECONCILE_COUNT=$((RECONCILE_COUNT + 1))
    else
      # GENUINELY DIFFERENT → never clobber. Record for halt + escalation.
      warn "reconcile: CONFLICT — untracked '$u' DIFFERS from incoming $upstream:$u (NOT removed)"
      RECONCILE_DIFF_LIST="$RECONCILE_DIFF_LIST $u"
      conflicts=$((conflicts + 1))
    fi
  done < <(git -C "$dir" ls-files --others --exclude-standard -z 2>/dev/null)

  [ "$conflicts" -gt 0 ] && return 2
  return 0
}

# ── Cross-store enumeration (ga-mt03s) ────────────────────────────────────────
# Enumerate ALL rig stores dynamically so gate:passed beads in ps-/wa-/lx-/ma-/
# dc-/gastown rigs are found by the delivery scan — not just HQ (gascity store).
# Fail-open: if gc rig list fails, fall back to HQ only so HQ stories are never
# blocked by a failing rig-list call.
# ga-266z8: cache the full rig-list JSON (not just paths) — the task reconciler
# below needs each rig's default_branch to verify merges by content, and a
# second live `gc rig list` call per candidate would be wasteful and hit Dolt
# again for no reason.
RIG_LIST_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo "")
ALL_STORES=$(echo "$RIG_LIST_JSON" | jq -r '.rigs[].path' 2>/dev/null || echo "")
[ -z "$ALL_STORES" ] && ALL_STORES="$GC_CITY"
log "Stores to scan: $(echo "$ALL_STORES" | tr '\n' ' ')"

# ── Step 1: Find stories with gate:passed but NOT story:done ──────────────────
# Stories are identified by label story:approved (type field is null in bd).
# gate:passed is set by the quality-gate-dispatcher after merge.
# story:done is set by this script after successful delivery.
if [ -n "$FORCE_STORY_ID" ]; then
  log "Forced single-story mode: $FORCE_STORY_ID"
  STORIES_JSON="[]"
  for _store_path in $ALL_STORES; do
    [ -d "$_store_path" ] || continue
    _chunk=$(bd -C "$_store_path" list --json \
      -l "story:approved" \
      -l "gate:passed" \
      2>/dev/null \
      | jq --arg id "$FORCE_STORY_ID" --arg sp "$_store_path" \
          '[.[] | select(.id == $id) | . + {_store: $sp}]' \
      || echo "[]")
    STORIES_JSON=$(printf '%s\n%s' "$STORIES_JSON" "$_chunk" | jq -s 'add // []' || echo "$STORIES_JSON")
  done
else
  STORIES_JSON="[]"
  for _store_path in $ALL_STORES; do
    [ -d "$_store_path" ] || continue
    _chunk=$(bd -C "$_store_path" list --json \
      -l "story:approved" \
      -l "gate:passed" \
      2>/dev/null \
      | jq --arg sp "$_store_path" \
          '[.[] | select(.labels | map(select(. == "story:done")) | length == 0) | . + {_store: $sp}]' \
      || echo "[]")
    STORIES_JSON=$(printf '%s\n%s' "$STORIES_JSON" "$_chunk" | jq -s 'add // []' || echo "$STORIES_JSON")
  done
fi

COUNT=$(echo "$STORIES_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT story/stories awaiting delivery"

# ── Step 1b: Task/bug reconciler — close gate:passed non-story beads (ga-tjqe) ─
# The gate dispatcher (ga-esbg) closes task/bug source beads directly after a
# verified merge+push. But if the dispatcher crashes BETWEEN setting gate:passed
# and calling bd close, the bead strands open/in_progress with gate:passed
# indefinitely — story-delivery only sweeps story:approved beads (Step 1 above),
# so task beads are invisible to the normal delivery path.
#
# This reconciler closes one gate:passed non-story bead per sweep (same "one per
# run" discipline as story processing). No deploy/prod-test — the gate already
# verified the merge. Terminal for artifact tasks.
#
# Skipped in forced single-story mode (FORCE_STORY_ID set).
#
# IMPORTANT: uses --status open,in_progress because stranded task beads are
# typically in_progress (builder claimed them), not open. bd list default shows
# only open; without --status open,in_progress they are invisible.
TASK_COUNT=0
# ga-s1qb2: cap on consecutive bd-close failures for the SAME task bead before
# the reconciler stops auto-retrying and escalates to a human instead — see
# the close:* verdict branch below. Each failed attempt used to still post a
# "Closed by delivery sweep" comment (never true) and retry forever, one Dolt
# commit per sweep (~5min cadence; wa-l30yr: 8+ in under 3 hours).
TASK_CLOSE_MAX_RETRIES=3
# wa-n27z0: minimum age (by updated_at) a gate:passed non-story bead must have
# before the task reconciler will act on it at all — see
# task_reconciler_gate_passed_too_fresh's header for the full race-condition
# rationale and the measured 391-604s (6.5-10min) gap this guards against.
# Overridable via env for tests/tuning, same idiom as the two constants above.
TASK_GATE_PASSED_MIN_AGE_MINUTES="${TASK_GATE_PASSED_MIN_AGE_MINUTES:-20}"
# ga-aqqj0: same cap idiom as TASK_CLOSE_MAX_RETRIES above, applied to a
# DIFFERENT loop/step — Step 3 of the STORY delivery loop below (rig runbook
# lookup), not the task reconciler. A rig value that can never have a runbook
# entry (e.g. 'origin', a git remote name wrongly resolved as a rig by Step 2
# — see derive_rig_from_comments) used to HALT every ~5min sweep forever: 18
# identical "no deploy_cmd for rig 'origin'" comments in 1h on ga-dv2gk,
# before this was noticed. See the delivery:no-deploy-cmd-retry:N /
# delivery:no-deploy-cmd-exhausted labels at Step 3.
DELIVERY_NO_DEPLOY_CMD_MAX_RETRIES=3
if [ -z "$FORCE_STORY_ID" ]; then
  # Fan-out over ALL stores (ga-mt03s): task beads in ps-/wa-/etc. rigs live in
  # their own stores, not HQ. Inject _store so mutations target the right store.
  TASK_BEADS_JSON="[]"
  for _store_path in $ALL_STORES; do
    [ -d "$_store_path" ] || continue
    _chunk=$(bd -C "$_store_path" list --json \
      --status open,in_progress \
      -l "gate:passed" \
      2>/dev/null \
      | jq --arg sp "$_store_path" '[.[] |
          select((.labels // []) | contains(["story:approved"]) | not) |
          select((.labels // []) | contains(["story:done"]) | not) |
          . + {_store: $sp}
        ]' || echo "[]")
    TASK_BEADS_JSON=$(printf '%s\n%s' "$TASK_BEADS_JSON" "$_chunk" | jq -s 'add // []' || echo "$TASK_BEADS_JSON")
  done
  TASK_COUNT=$(echo "$TASK_BEADS_JSON" | jq 'length' 2>/dev/null || echo "0")

  if [ "$TASK_COUNT" -gt 0 ]; then
    # ga-266z8: iterate candidates (not just .[0]) so a bead that fails the new
    # verification guards below doesn't head-of-line-block every other
    # candidate forever — but still act on (close, or re-arm) AT MOST ONE per
    # sweep, same "one per run" discipline as before.
    TASK_ACTED=0
    TASK_FETCHED_STORES=""
    _task_idx=0
    while [ "$TASK_ACTED" = "0" ] && [ "$_task_idx" -lt "$TASK_COUNT" ]; do
      TASK_BEAD=$(echo "$TASK_BEADS_JSON" | jq ".[$_task_idx]")
      _task_idx=$((_task_idx + 1))
      TASK_BEAD_ID=$(echo "$TASK_BEAD" | jq -r '.id')
      TASK_BEAD_TITLE=$(echo "$TASK_BEAD" | jq -r '.title // "untitled"' | head -c 80)
      TASK_STORE=$(echo "$TASK_BEAD" | jq -r '._store // ""')
      [ -z "$TASK_STORE" ] && TASK_STORE="$GC_CITY"
      # ga-s1qb2: already escalated after TASK_CLOSE_MAX_RETRIES failed close
      # attempts (see the close:* verdict branch below) — a human has been
      # notified; do not keep re-attempting (that IS the infinite-loop bug
      # this fixes). Skip without acting so the sweep tries the next
      # candidate, same "iterate past unsuitable candidates" discipline
      # ga-266z8 already established for this loop.
      TASK_CLOSE_EXHAUSTED=$(echo "$TASK_BEAD" | jq -r 'if ((.labels // []) | contains(["delivery:close-retry-exhausted"])) then "1" else "0" end' 2>/dev/null || echo "0")
      if [ "$TASK_CLOSE_EXHAUSTED" = "1" ]; then
        log "Task reconciler: $TASK_BEAD_ID already escalated (delivery:close-retry-exhausted, ga-s1qb2) — close kept failing after $TASK_CLOSE_MAX_RETRIES attempts and a human was notified. Skipping; checking next candidate this sweep."
        continue
      fi
      # ga-iwv0 (done==deployed, not merged): a gate:passed bead that ALSO carries
      # delivery:deploy-pending went THROUGH delivery and the DEPLOY did not complete (a hot-path
      # daemon needs a guarded restart / did not come up fresh → merged code is NOT live). It is a
      # deploy-PENDING story, NOT a no-deploy artifact task — closing it here would mark "done"
      # while the code is dormant in prod (the exact gap that closed wa-t4olb before its daemon was
      # restarted). Do NOT close: re-arm story:approved so Step 1 re-picks it and runs delivery to
      # REAL completion (story:done only after daemon-refresh verifies live). NOTE: we key on the
      # specific delivery:deploy-pending label, NOT generic delivery:failed — a prod-test
      # delivery:failed must NOT auto-retry here (a flaky test would loop forever); that path stays
      # author-driven.
      TASK_DEPLOY_PENDING=$(echo "$TASK_BEAD" | jq -r 'if ((.labels // []) | contains(["delivery:deploy-pending"])) then "1" else "0" end' 2>/dev/null || echo "0")
      if [ "$TASK_DEPLOY_PENDING" = "1" ]; then
        log "Task reconciler: $TASK_BEAD_ID has delivery:deploy-pending (deploy NOT live) — NOT closing; re-arming story:approved for delivery retry (ga-iwv0: done must mean deployed, not merged)."
        if [ "$DRY_RUN" = "1" ]; then
          log "DRY_RUN=1 — WOULD: bd -C $TASK_STORE label add $TASK_BEAD_ID story:approved (re-arm delivery retry; do NOT close)"
        else
          bd -C "$TASK_STORE" label add "$TASK_BEAD_ID" "story:approved" -q 2>/dev/null || true
          bd -C "$TASK_STORE" comment "$TASK_BEAD_ID" "Delivery task reconciler (ga-iwv0): NOT closed — this bead carries delivery:deploy-pending, i.e. delivery ran and the deploy did NOT go live (a hot-path daemon needs a guarded restart). Closing here would mark done while the merged code is dormant in prod. Re-armed story:approved so the delivery sweep retries to completion; story:done is set only after the deploy (daemon-refresh) verifies the daemon is live on the new code." 2>/dev/null || true
        fi
        TASK_ACTED=1
        continue
      fi

      # ga-wnxeq: a gate:passed bead that ALSO carries delivery:pending-restart
      # went through quality-gate-dispatcher.sh's own daemon-verification hold
      # (ga-l7n3v) — that hold EXPLICITLY withholds closure ("Closure is
      # WITHHELD until this is resolved ... close this bead manually once
      # confirmed live", quality-gate-dispatcher.sh ~line 5289) because a
      # long-lived daemon may still be serving code older than this merge.
      # This reconciler is a SEPARATE, independent close path (it exists to
      # catch beads the primary dispatcher crashed before closing) and had NO
      # knowledge of delivery:pending-restart at all — so it ran its OWN merge
      # check below, found the content genuinely in origin/$TASK_DEFAULT_BRANCH
      # (true — the gate DID merge it), and closed anyway, directly overriding
      # the hold. Reproduced live on wa-q3x98 (DEPLOY_FAILED — the rig's
      # runtime checkout never even pulled the merge, closed regardless) and
      # wa-5wlrd (NEEDS_GUARDED_RESTART on a sensitive daemon with no drain
      # path, "NOT auto-bounced", closed regardless) — both had a genuinely
      # merged commit, which is exactly what let this reconciler's content
      # check wave them through.
      #
      # NOT the same fix as delivery:deploy-pending (ga-iwv0) above: that
      # label's only consumer re-arms story:approved to route the bead through
      # the full STORY delivery pipeline for a daemon-refresh retry loop.
      # quality-gate-dispatcher.sh deliberately chose delivery:pending-restart
      # as a DIFFERENT, un-consumed label specifically so it would NEVER
      # trigger that story-only mechanism on a bug/task bead (see that
      # script's own comment beside its label-add call) — reusing the
      # deploy-pending branch here would revive exactly what that comment
      # says to avoid. So this is veto-only: do not close, do not relabel, do
      # not comment (the hold was already announced in full — with Mayor mail
      # and author notification — by the dispatcher at the moment it set the
      # label; commenting again on every ~5min sweep this bead is re-picked
      # would reproduce the identical Dolt-commit-spam anti-pattern ga-s1qb2
      # already fixed once for this same file). Move on to the next
      # candidate this sweep, same as the already-escalated skip above —
      # resolution is manual (human closes once confirmed live) or via
      # whatever future automation clears the label.
      TASK_PENDING_RESTART=$(echo "$TASK_BEAD" | jq -r 'if ((.labels // []) | contains(["delivery:pending-restart"])) then "1" else "0" end' 2>/dev/null || echo "0")
      if [ "$TASK_PENDING_RESTART" = "1" ]; then
        log "Task reconciler: $TASK_BEAD_ID has delivery:pending-restart (daemon verification withheld closure, ga-l7n3v) — NOT closing; checking next candidate this sweep."
        continue
      fi

      # wa-n27z0: the TASK_PENDING_RESTART veto just above only helps once
      # delivery:pending-restart actually exists on the bead — but that label
      # is set by a LATER step of the SAME (still-running, not crashed)
      # quality-gate-dispatcher.sh invocation that set gate:passed, and the two
      # writes are 391-604s (6.5-10min) apart in every incident measured live
      # (wa-n27z0). A bead scanned before the hold verdict lands looks
      # identical to one the dispatcher already cleared — this reconciler
      # cannot tell "hold is coming" from "no hold needed" without waiting.
      # See task_reconciler_gate_passed_too_fresh's header for the full
      # incident and the asymmetric-cost reasoning for erring toward "wait".
      TASK_UPDATED_AT=$(echo "$TASK_BEAD" | jq -r '.updated_at // ""' 2>/dev/null || echo "")
      if task_reconciler_gate_passed_too_fresh "$TASK_UPDATED_AT" "$(date +%s)" "$TASK_GATE_PASSED_MIN_AGE_MINUTES"; then
        log "Task reconciler: $TASK_BEAD_ID gate:passed still fresh (updated_at=$TASK_UPDATED_AT, <${TASK_GATE_PASSED_MIN_AGE_MINUTES}min old) — the dispatcher invocation that merged this may still be mid-flight on its own daemon-liveness check and has not had time to land delivery:pending-restart if a hold applies (wa-n27z0). NOT closing yet; checking next candidate this sweep."
        continue
      fi
      # wa-x6ggx: updated_at ALONE just said "old enough" — but bd label
      # add/remove never bumps updated_at (confirmed empirically), and
      # gate:passed is ALWAYS applied via a label-only mutation, so updated_at
      # can be stale by exactly the amount that matters here. Double-check
      # against the bead's true last-touched time (events table, includes
      # label mutations) before trusting the "proceed" verdict — live repro
      # wa-1psgk (2026-09-09): updated_at reflected an unrelated earlier
      # update at the instant gate:passed landed 6sec before the sweep closed
      # it. Only paid on THIS path (updated_at already said "proceed") — the
      # common case where updated_at alone already says "too fresh" above is
      # unaffected and unslowed by the extra query.
      TASK_LAST_EVENT_AT=$(task_bead_last_event_at "$TASK_STORE" "$TASK_BEAD_ID")
      TASK_EFFECTIVE_UPDATED_AT=$(task_gate_passed_age_anchor "$TASK_UPDATED_AT" "$TASK_LAST_EVENT_AT")
      if task_reconciler_gate_passed_too_fresh "$TASK_EFFECTIVE_UPDATED_AT" "$(date +%s)" "$TASK_GATE_PASSED_MIN_AGE_MINUTES"; then
        log "Task reconciler: $TASK_BEAD_ID gate:passed still fresh once label-only mutations are accounted for (effective anchor=$TASK_EFFECTIVE_UPDATED_AT, updated_at alone read $TASK_UPDATED_AT, <${TASK_GATE_PASSED_MIN_AGE_MINUTES}min old, wa-x6ggx) — NOT closing yet; checking next candidate this sweep."
        continue
      fi

      # ga-266z8: NEVER trust the gate:passed label alone before closing — it can
      # be PROPAGATED from a sling/earlier run while the parent's own latest gate
      # run FAILED (confirmed false-closes: ga-opyus, ga-t1ub9, both manually
      # re-opened). Two guards, mirroring the already-fixed sibling ga-v8ui5
      # (verify by content, never by label alone):
      #   (1) a contradicting gate:failed/gate:needs-fix label means gate:passed
      #       is stale/propagated, not evidence — the gate has not resolved.
      #   (2) absent that, require independent proof the fix landed in
      #       origin/<default_branch>: scan for a commit whose conventional-commit
      #       SCOPE is this bead id (same discriminator merged-bead-janitor.sh
      #       uses) — a content check, since the reconciler has no branch name
      #       for a task bead to run merge-base --is-ancestor against.
      TASK_CONTRADICTED=$(echo "$TASK_BEAD" | jq -r 'if ((.labels // []) | any(. == "gate:failed" or . == "gate:needs-fix")) then "1" else "0" end' 2>/dev/null || echo "0")

      # ga-tuk26: run content-verification UNCONDITIONALLY, even when
      # TASK_CONTRADICTED=1. This used to be gated on `!= "1"`, which meant a
      # contradicted bead's TASK_MERGE_VERIFIED stayed hard-coded 0 forever —
      # task_reconciler_verdict()'s contradiction check then short-circuited
      # before that value was ever meaningful, so the bead could NEVER earn
      # the independent proof that would let it resolve (it just sat stuck,
      # even after whatever wrote the stale gate:failed/gate:needs-fix
      # stopped recurring). This never trusts the label pair alone in the
      # OTHER direction either: task_reconciler_verdict still keeps an
      # unverified contradicted bead stuck, unconditionally — see that
      # function for the fail-safe half of this fix.
      TASK_MERGE_VERIFIED=0
      TASK_DEFAULT_BRANCH=$(echo "$RIG_LIST_JSON" | jq -r --arg p "$TASK_STORE" '(.rigs[] | select(.path==$p) | .default_branch) // "main"' 2>/dev/null || echo "main")
      [ -z "$TASK_DEFAULT_BRANCH" ] && TASK_DEFAULT_BRANCH="main"
      TASK_GITDIR_PAIR=$(rig_gitdir "$TASK_STORE")
      TASK_GDIR="${TASK_GITDIR_PAIR%$'\t'*}"
      TASK_CONTAINER="${TASK_GITDIR_PAIR#*$'\t'}"
      case " $TASK_FETCHED_STORES " in
        *" $TASK_STORE "*) : ;;
        *)
          timeout 30 sh -c '
            if [ "$3" = "1" ]; then git --git-dir="$1" fetch origin "$2" --quiet; else git -C "$1" fetch origin "$2" --quiet; fi
          ' _ "$TASK_GDIR" "$TASK_DEFAULT_BRANCH" "$TASK_CONTAINER" 2>/dev/null \
            || warn "Task reconciler: fetch origin/$TASK_DEFAULT_BRANCH failed/timed out for $TASK_STORE (non-fatal — verifying against last-known ref)."
          TASK_FETCHED_STORES="$TASK_FETCHED_STORES $TASK_STORE"
          ;;
      esac
      if scan_commit_subject_for_bead "$TASK_GDIR" "$TASK_CONTAINER" "origin/$TASK_DEFAULT_BRANCH" "$TASK_BEAD_ID" >/dev/null 2>&1; then
        TASK_MERGE_VERIFIED=1
      fi

      # ga-as3p1: the bead-scoped scan above proves "some commit for this
      # bead id landed" — true for ANY slice that ever passed, not
      # necessarily the slice that is CURRENTLY failing (multi-slice
      # false-positive, measured live on wa-7l2u3 — see
      # task_reconciler_failed_sha_resolved's header for the full incident).
      # When a gate-sha-failed stamp names the SPECIFIC rejected sha, that is
      # strictly better evidence and must override the bead-scoped guess in
      # BOTH directions (a still-unmerged failed sha must NOT be waved
      # through just because a sibling slice merged; an ancestor failed sha
      # DOES resolve, even absent a bead-scoped hit — the hold-class case).
      # No stamp recorded at all ("absent") leaves TASK_MERGE_VERIFIED at the
      # bead-scoped value above — there is nothing sha-specific to disprove
      # staleness with, so this falls back to the pre-ga-as3p1 behavior
      # rather than guessing in either direction.
      if [ "$TASK_CONTRADICTED" = "1" ]; then
        TASK_LABELS_SPACE=$(echo "$TASK_BEAD" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")
        case "$(task_reconciler_failed_sha_resolved "$TASK_GDIR" "$TASK_CONTAINER" "origin/$TASK_DEFAULT_BRANCH" "$TASK_LABELS_SPACE")" in
          yes) TASK_MERGE_VERIFIED=1 ;;
          no)  TASK_MERGE_VERIFIED=0 ;;
          *)   : ;;  # absent — keep the bead-scoped TASK_MERGE_VERIFIED as-is
        esac
      fi

      # ga-tuk26: if the contradiction is now independently PROVEN stale
      # (contradicted AND the commit really did land), clear the residual
      # gate:failed/gate:needs-fix labels regardless of the eventual verdict
      # below (close, or kept for an unrelated reason like partial-scope) —
      # a bead should never sit there LOOKING contradicted once we have
      # positive proof it is not. Never runs in the unverified case (stays
      # maximally conservative — see task_reconciler_verdict). ga-as3p1:
      # TASK_MERGE_VERIFIED is now sha-scoped whenever a gate-sha-failed
      # stamp exists (see above); this block is otherwise unchanged.
      TASK_CONTRADICTION_RESOLVED=0
      if [ "$TASK_CONTRADICTED" = "1" ] && [ "$TASK_MERGE_VERIFIED" = "1" ]; then
        TASK_CONTRADICTION_RESOLVED=1
        log "Task reconciler: $TASK_BEAD_ID contradiction (gate:failed/gate:needs-fix) proven STALE — the rejected sha (or, absent a gate-sha-failed stamp, a commit for this bead) is verified in origin/$TASK_DEFAULT_BRANCH (ga-as3p1/ga-tuk26). Clearing residual labels."
        if [ "$DRY_RUN" = "1" ]; then
          log "DRY_RUN=1 — WOULD: bd -C $TASK_STORE label remove $TASK_BEAD_ID gate:failed / gate:needs-fix (ga-tuk26 stale-contradiction clear)"
        else
          bd -C "$TASK_STORE" label remove "$TASK_BEAD_ID" "gate:failed" -q 2>/dev/null || true
          bd -C "$TASK_STORE" label remove "$TASK_BEAD_ID" "gate:needs-fix" -q 2>/dev/null || true
          bd -C "$TASK_STORE" comment "$TASK_BEAD_ID" "Delivery task reconciler (ga-as3p1/ga-tuk26): gate:failed/gate:needs-fix cleared — independently verified (sha-scoped where a gate-sha-failed stamp exists, ga-as3p1; bead-scoped content check otherwise, ga-266z8) that origin/$TASK_DEFAULT_BRANCH now contains the resolving commit, proving the coexisting gate:passed reflects the latest cycle and the earlier FAIL-cycle residue was stale." 2>/dev/null || true
        fi
      fi

      # ga-k2wjn: does the task bead ALREADY carry delivery:partial (primary
      # dispatcher already held+escalated it — nothing new to do here beyond
      # not closing) or scope_covered:all (explicit author override — trust
      # it, and let it override a prior hold too, ga-3k70w2), or — the
      # crash-window case, primary dispatcher never reached this decision —
      # does its OWN body look like it enumerates multiple approved
      # deliverables? Precedence lives in task_reconciler_is_partial above.
      TASK_ALREADY_PARTIAL=$(echo "$TASK_BEAD" | jq -r 'if ((.labels // []) | contains(["delivery:partial"])) then "1" else "0" end' 2>/dev/null || echo "0")
      TASK_SCOPE_COVERED_ALL=$(echo "$TASK_BEAD" | jq -r 'if ((.labels // []) | contains(["scope_covered:all"])) then "1" else "0" end' 2>/dev/null || echo "0")
      TASK_TEXT=$(echo "$TASK_BEAD" | jq -r '((.description // "") + "\n" + (.notes // ""))' 2>/dev/null || echo "")
      TASK_IS_PARTIAL=0
      # ga-zhfk8: capture the detected list lines (stdout on a hit) so the
      # hold message below can cite them instead of asserting without
      # showing. ga-3k70w2: pass the title too (guard.sh's v4 signature) —
      # the backstop used to call this text-only, which is one more way it
      # was weaker than the primary (title-level enumeration went undetected).
      TASK_PARTIAL_REASON_FILE=$(mktemp 2>/dev/null || echo "/tmp/tgdlp-$$.err")
      if TASK_PARTIAL_EVIDENCE=$(task_reconciler_is_partial "$TASK_ALREADY_PARTIAL" "$TASK_SCOPE_COVERED_ALL" "$TASK_TEXT" "$TASK_BEAD_TITLE" 2>"$TASK_PARTIAL_REASON_FILE"); then
        TASK_IS_PARTIAL=1
      fi
      TASK_PARTIAL_REASON_RAW=$(cat "$TASK_PARTIAL_REASON_FILE" 2>/dev/null || echo "")
      rm -f "$TASK_PARTIAL_REASON_FILE"
      # ga-a7bt6u: the advisory sub-case (rc=1, an unclassifiable-header run
      # cleared the >=3-item bar under gate_delivery_looks_partial) used to
      # just fall into this script's own log (exec redirects the whole
      # script's stderr to $LOG at top, see above) — captured, but nowhere a
      # human reviewing THIS bead would look. Mirrors
      # quality-gate-dispatcher.sh's advisory consumption; this backstop
      # needs its own capture since it only runs the crash-window case (the
      # primary dispatcher never reached this bead). scope:advisory is
      # additive/non-blocking — never delivery:partial or scope:needs-review,
      # which hold the bead; that would reopen exactly the deadlock
      # ga-cjrxh's release-over-hold bias exists to prevent.
      if [ "$TASK_IS_PARTIAL" != "1" ] && printf '%s' "$TASK_PARTIAL_REASON_RAW" | grep '^escopo-multiplo:possivel' >/dev/null; then
        if [ "$DRY_RUN" = "1" ]; then
          log "DRY_RUN=1 — WOULD: bd -C $TASK_STORE comment $TASK_BEAD_ID (scope advisory, ga-a7bt6u) + label scope:advisory"
        else
          bd -C "$TASK_STORE" comment "$TASK_BEAD_ID" "Gate scope advisory (ga-a7bt6u, task reconciler backstop): $TASK_PARTIAL_REASON_RAW" 2>/dev/null || true
          bd -C "$TASK_STORE" label add "$TASK_BEAD_ID" "scope:advisory" -q 2>/dev/null || true
        fi
      fi

      TASK_VERDICT=$(task_reconciler_verdict "$TASK_CONTRADICTED" "$TASK_MERGE_VERIFIED" "$TASK_IS_PARTIAL")
      case "$TASK_VERDICT" in
        close:*)
          log "Task reconciler: gate:passed non-story bead $TASK_BEAD_ID ($TASK_BEAD_TITLE) in store $TASK_STORE — verified merged ($TASK_VERDICT) — closing (no deploy/prod-test)."
          if [ "$DRY_RUN" = "1" ]; then
            log "DRY_RUN=1 — WOULD: bd -C $TASK_STORE close $TASK_BEAD_ID (gate:passed task reconciler, ga-tjqe; ancestry-verified ga-266z8)"
          else
            # ga-s1qb2: verify the close's OWN exit code before claiming
            # success below — this used to be `... || warn "..."` (a
            # non-fatal log line), after which the comment+log+delivery-log
            # calls ran UNCONDITIONALLY, so a FAILED close (e.g. bd's own
            # ownership guard refusing because assignee/actor are the same
            # agent under two identity forms) still got a bead comment
            # claiming "Closed by delivery sweep" and a delivery-log entry
            # claiming result:"task_closed" — neither true. Since nothing
            # about the bead's own state changed, the next sweep re-selected
            # it and repeated the exact same false claim: wa-l30yr collected
            # 8+ identical comments (one Dolt commit each) in under 3 hours
            # before a human noticed and force-closed it by hand.
            # `if ! VAR=$(cmd); then` (not a bare `VAR=$(cmd) || ...`) is
            # this file's own established idiom for capturing a failing
            # command's output without tripping `set -euo pipefail` — see
            # the story_merge_verdict call above for the same pattern with
            # its own explanatory comment.
            TASK_CLOSE_STDERR=""
            if ! TASK_CLOSE_STDERR=$(bd -C "$TASK_STORE" close "$TASK_BEAD_ID" \
                  -r "Delivery task reconciler (ga-tjqe): gate:passed non-story bead closed — merge verified by content-in-origin-$TASK_DEFAULT_BRANCH check (ga-266z8), not the label alone. Gate dispatcher's direct-close (ga-esbg) was the primary path; this sweep catches beads the dispatcher did not close (e.g., crash between gate:passed + bd close)." \
                  2>&1 >/dev/null); then
              # Third state (ga-s1qb2): "refused by bd's own ownership guard
              # because assignee/actor are the same agent under two identity
              # forms" is a KNOWN, expected, non-error condition — distinct
              # from an unrecognized/generic failure. Neither is silently
              # discarded (the old `2>/dev/null` did exactly that); both are
              # recorded, and the reason is quoted verbatim to whoever
              # eventually has to act on it.
              case "$TASK_CLOSE_STDERR" in
                *"reclaim or use --force to override"*) TASK_CLOSE_REASON="ownership-refused" ;;
                *) TASK_CLOSE_REASON="error" ;;
              esac
              TASK_CLOSE_RETRY=$(echo "$TASK_BEAD" | jq -r '
                (.labels // []) | map(select(startswith("delivery:close-retry:"))) | .[0] // ""
                | if . == "" then "0" else ltrimstr("delivery:close-retry:") end
              ' 2>/dev/null || echo "0")
              TASK_CLOSE_RETRY_NEXT=$((TASK_CLOSE_RETRY + 1))
              warn "Task reconciler: could not close $TASK_BEAD_ID ($TASK_CLOSE_REASON, attempt $TASK_CLOSE_RETRY_NEXT/$TASK_CLOSE_MAX_RETRIES): $TASK_CLOSE_STDERR"
              if [ "$TASK_CLOSE_RETRY_NEXT" -ge "$TASK_CLOSE_MAX_RETRIES" ]; then
                # Cap reached (ga-s1qb2 item c): stop retrying — the early
                # delivery:close-retry-exhausted skip-check above prevents
                # this bead from ever reaching this branch again. Escalate to
                # Mayor exactly like the keep:partial-delivery verdict below
                # already does for its own "reconciler stuck, needs a human"
                # case — same shape, same file, same mail convention.
                [ "$TASK_CLOSE_RETRY" -gt 0 ] && bd -C "$TASK_STORE" label remove "$TASK_BEAD_ID" "delivery:close-retry:$TASK_CLOSE_RETRY" -q 2>/dev/null || true
                bd -C "$TASK_STORE" label add "$TASK_BEAD_ID" "delivery:close-retry-exhausted" -q 2>/dev/null || true
                bd -C "$TASK_STORE" comment "$TASK_BEAD_ID" "Delivery task reconciler (ga-s1qb2): gate:passed and independently merge-verified, but bd close has now failed $TASK_CLOSE_RETRY_NEXT/$TASK_CLOSE_MAX_RETRIES times ($TASK_CLOSE_REASON) — NOT retrying further to avoid an unbounded loop of identical comments (this replaced a prior version of this sweep that retried forever). Last error: $TASK_CLOSE_STDERR. A human needs to close this bead manually (or resolve the ownership conflict) once ready; remove the delivery:close-retry-exhausted label to let the reconciler try again automatically." 2>/dev/null || true
                gc --city "$GC_CITY" mail send mayor \
                  -s "Delivery reconciler: close retries exhausted for $TASK_BEAD_ID" \
                  -m "$(printf 'Task bead %s (%s) is gate:passed and independently merge-verified, but the delivery task reconciler could not close it after %s attempts (%s). Last error: %s\n\nStore: %s\n\nThis bead will no longer be auto-retried (ga-s1qb2 retry cap) — close it manually once the underlying issue (likely an ownership/actor identity mismatch — see bd close --help) is resolved, or remove label delivery:close-retry-exhausted to let the reconciler try again.' \
                    "$TASK_BEAD_ID" "$TASK_BEAD_TITLE" "$TASK_CLOSE_MAX_RETRIES" "$TASK_CLOSE_REASON" "$TASK_CLOSE_STDERR" "$TASK_STORE")" \
                  2>/dev/null || warn "Task reconciler: could not mail Mayor close-retry-exhausted escalation for $TASK_BEAD_ID (ga-s1qb2)"
              else
                [ "$TASK_CLOSE_RETRY" -gt 0 ] && bd -C "$TASK_STORE" label remove "$TASK_BEAD_ID" "delivery:close-retry:$TASK_CLOSE_RETRY" -q 2>/dev/null || true
                bd -C "$TASK_STORE" label add "$TASK_BEAD_ID" "delivery:close-retry:$TASK_CLOSE_RETRY_NEXT" -q 2>/dev/null || true
              fi
              mkdir -p "$(dirname "$DELIVERY_LOG")"
              jq -c -n \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg task_id "$TASK_BEAD_ID" \
                --arg task_title "$TASK_BEAD_TITLE" \
                --arg result "task_close_failed" \
                --arg reason "$TASK_CLOSE_REASON" \
                --arg attempt "$TASK_CLOSE_RETRY_NEXT" \
                --arg dry_run "$DRY_RUN" \
                '{ts: $ts, event: "task_reconcile", task_id: $task_id, task_title: $task_title, result: $result, reason: $reason, attempt: ($attempt | tonumber), dry_run: $dry_run}' \
                >> "$DELIVERY_LOG" 2>/dev/null || true
            else
              bd -C "$TASK_STORE" comment "$TASK_BEAD_ID" "Delivery task reconciler (ga-tjqe): gate:passed is set and this bead is not a story (no story:approved). Verified merged by scanning origin/$TASK_DEFAULT_BRANCH for a commit scoped to this bead id (ga-266z8 — the label alone is never trusted). Closed by delivery sweep — terminal for artifact tasks." 2>/dev/null || true
              log "Task reconciler: closed $TASK_BEAD_ID"
              mkdir -p "$(dirname "$DELIVERY_LOG")"
              jq -c -n \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg task_id "$TASK_BEAD_ID" \
                --arg task_title "$TASK_BEAD_TITLE" \
                --arg result "task_closed" \
                --arg dry_run "$DRY_RUN" \
                '{ts: $ts, event: "task_reconcile", task_id: $task_id, task_title: $task_title, result: $result, dry_run: $dry_run}' \
                >> "$DELIVERY_LOG" 2>/dev/null || true
            fi
          fi
          TASK_ACTED=1
          ;;
        keep:partial-delivery)
          if [ "$TASK_ALREADY_PARTIAL" = "1" ]; then
            log "Task reconciler: $TASK_BEAD_ID already held as delivery:partial (ga-k2wjn) — NOT closing; checking next candidate this sweep."
          else
            log "Task reconciler: $TASK_BEAD_ID gate:passed but body looks PARTIAL (ga-k2wjn heuristic, crash-window catch — primary dispatcher never labeled it) — holding, NOT closing; escalating to Mayor."
            if [ "$DRY_RUN" = "1" ]; then
              log "DRY_RUN=1 — WOULD: label $TASK_BEAD_ID delivery:partial + scope:needs-review, comment, mail mayor (ga-k2wjn task-reconciler backstop)"
            else
              # ga-6dpoa: scope:needs-review, NOT gate:needs-human(:partial-delivery) — the
              # latter collides with lifecycle-coherence-janitor's R7 rule (treats any
              # gate:needs-human* label as non-implementable and strips gc.routed_to).
              # gate:passed (already set) is what actually keeps Pilot from re-dispatching;
              # this label is purely the human-visible "why". See quality-gate-dispatcher.sh's
              # primary-path sibling of this block for the full rationale.
              bd -C "$TASK_STORE" label add "$TASK_BEAD_ID" "delivery:partial" -q 2>/dev/null || true
              bd -C "$TASK_STORE" label add "$TASK_BEAD_ID" "scope:needs-review" -q 2>/dev/null || true
              # ga-pm93k: mirrors quality-gate-dispatcher.sh's primary-path
              # sibling of this block verbatim (existing convention) — the
              # message stops asserting the list-structure signal as a
              # verified deliverable count (an "OU"/"ou alternativamente"/
              # "OR"-led item is an alternative to the item before it, not
              # an extra deliverable) and always requests the git-log check
              # that actually discriminates "gate passed" from "is ready",
              # independent of whether the primary dispatcher or this
              # crash-window backstop produced the hold. See that sibling
              # block for the full rationale.
              TASK_SCOPE_HOLD_WEAK_SIGNAL_NOTE="this bead body CONTAINS a numbered/lettered list structure (>=3 consecutive items — see detected lines below) that MAY enumerate multiple approved deliverables. This is a structural signal, not a verified count: an item starting with an alternative conjunction (OU, ou alternativamente, OR) is an ALTERNATIVE to the item before it, not an extra deliverable, so the real scope can be smaller than the item count suggests — read the detected lines before assuming N separate deliverables."
              TASK_SCOPE_HOLD_ALWAYS_CHECK="Before deciding, ALWAYS also run: git log --oneline --all --grep=$TASK_BEAD_ID — and compare the result against origin/$TASK_DEFAULT_BRANCH. A bead commit that exists but never reached that branch is what actually discriminates gate passed from ready, independent of this list signal."
              bd -C "$TASK_STORE" comment "$TASK_BEAD_ID" "Delivery task reconciler (ga-k2wjn/ga-zhfk8 backstop): gate:passed is set and this bead is not a story, but $TASK_SCOPE_HOLD_WEAK_SIGNAL_NOTE The primary gate dispatcher never labeled this (crash-window — ga-esbg did not complete on it), so this sweep is doing so now instead of closing. $TASK_SCOPE_HOLD_ALWAYS_CHECK If this diff genuinely covers every enumerated item, add label scope_covered:all and close manually; otherwise the remaining items are still live on this bead.

$TASK_PARTIAL_EVIDENCE" 2>/dev/null || true
              gc --city "$GC_CITY" mail send mayor \
                -s "Gate held for scope review: $TASK_BEAD_ID (ga-k2wjn backstop)" \
                -m "$(printf 'Task bead %s carries gate:passed and looks merged, but %s The primary gate dispatcher never labeled it delivery:partial (crash-window), so the story-delivery task reconciler is holding it now instead of closing.\n\n%s\n\n%s\n\nReview the diff against the full enumerated scope: if complete, add label scope_covered:all and close manually; if partial, the remaining items are still live on this bead.\n\nBead: %s   Store: %s' \
                  "$TASK_BEAD_ID" "$TASK_SCOPE_HOLD_WEAK_SIGNAL_NOTE" "$TASK_PARTIAL_EVIDENCE" "$TASK_SCOPE_HOLD_ALWAYS_CHECK" "$TASK_BEAD_ID" "$TASK_STORE")" \
                2>/dev/null || warn "Task reconciler: could not mail Mayor scope-hold escalation for $TASK_BEAD_ID (ga-k2wjn)"
            fi
          fi
          ;;
        keep:contradicted-by-gate-failed-or-needs-fix)
          log "Task reconciler: $TASK_BEAD_ID carries gate:passed but ALSO gate:failed/gate:needs-fix (ga-266z8 contradiction guard) — NOT closing; checking next candidate this sweep."
          ;;
        *)
          log "Task reconciler: $TASK_BEAD_ID has gate:passed but no commit scoped to it was found in origin/$TASK_DEFAULT_BRANCH (ga-266z8 — never trust the label alone) — NOT closing this sweep; checking next candidate."
          ;;
      esac
    done
  fi
fi
# ── End Step 1b ──────────────────────────────────────────────────────────────

if [ "$COUNT" = "0" ] && [ "$TASK_COUNT" = "0" ]; then
  log "No stories or tasks pending delivery. Exiting."
  exit 0
fi

if [ "$COUNT" = "0" ]; then
  log "No stories pending delivery (task reconciler sweep done). Exiting."
  exit 0
fi

# Iterate all eligible stories — avoids head-of-line blocking when .[0] halts.
while IFS= read -r STORY; do
  # Reset per-iteration state so a prior story's halt never bleeds into the next.
  NO_HARNESS=0
  STORY_TEST_MISSING=0
  RUN_RECONCILE=0
  RECONCILE_COUNT=0
  RECONCILE_DIFF_LIST=""
  PRE_DEPLOY_SHA=""
  POST_DEPLOY_SHA=""
  STALENESS_GATE=0
  MERGE_VERDICT=""
  MERGE_SHA=""
  MERGE_REF=""

  STORY_ID=$(echo "$STORY" | jq -r '.id')
  # Cross-store (ga-mt03s): each bead carries a _store field set during fan-out.
  # All bd mutations for this story target STORY_STORE, not hardwired GC_CITY.
  STORY_STORE=$(echo "$STORY" | jq -r '._store // ""')
  [ -z "$STORY_STORE" ] && STORY_STORE="$GC_CITY"
  STORY_TITLE=$(echo "$STORY" | jq -r '.description // .title // "untitled"' | head -c 80)
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')

  log "Processing story $STORY_ID: $STORY_TITLE"
  log "Labels: $STORY_LABELS"

# ga-rugqks: $STORY_LABELS above is a Step-1-time snapshot — re-verify the
# bead's CURRENT status fresh before doing anything else this iteration.
# Any bead reaching this loop already carries gate:passed (Step 1's own
# selector requires it), so skipping an already-closed one here can never
# be used to dodge delivery verification for a bead that still needs it —
# it only stops reprocessing a bead someone already closed with proof.
if story_bead_closed_now "$STORY_STORE" "$STORY_ID"; then
  log "Story $STORY_ID is already closed (verified live, not from the Step-1 label snapshot) — skipping, no mutation."
  continue
fi

# Skip if already marked story:done (idempotency guard)
if echo "$STORY_LABELS" | grep "story:done" >/dev/null; then
  log "Story $STORY_ID already labeled story:done — skipping."
  continue
fi

# Skip if already in delivery (prevents parallel runs) -- UNLESS the lock is
# STALE (ga-015qqe): wa-r4ehy.2 sat wedged ~3.5h because this check was
# unconditional -- every OTHER lock in this file is staleness-aware (search
# "staleness" above: the post-deploy town-root gate ga-rhtu, the daemon-
# refresh baseline alarm ga-gjum0y, the gate:failed/gate:needs-fix
# contradiction check ga-tuk26/ga-as3p1) but this one just checked "does the
# label exist" -- if the run that set it crashed/was killed (e.g. resource
# pressure) before reaching any of its 6 cleanup call sites, nothing ever
# re-evaluates whether it's actually still alive, and the story is wedged
# permanently.
#
# Fail-closed direction: only treat as stale (and renew) when the recorded
# timestamp is PRESENT and UNAMBIGUOUSLY past the ceiling. A missing/
# unparseable timestamp (e.g. a delivery:running set before this fix shipped,
# with no metadata) is never treated as stale -- that could clobber a
# genuinely slow-but-live delivery just because we can't prove it isn't
# done. $STORY is the same Step-1
# snapshot STORY_LABELS itself came from, so reading its embedded metadata
# here is internally consistent with the label check right above it.
if echo "$STORY_LABELS" | grep "delivery:running" >/dev/null; then
  _DELIVERY_RUNNING_SINCE=$(echo "$STORY" | jq -r '.metadata["delivery.running_since"] // empty' 2>/dev/null || echo "")
  _DELIVERY_RUNNING_STALE=0
  if [ -n "$_DELIVERY_RUNNING_SINCE" ]; then
    _DRS_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_DELIVERY_RUNNING_SINCE" +%s 2>/dev/null \
      || date -u -d "$_DELIVERY_RUNNING_SINCE" +%s 2>/dev/null || echo "")
    if [ -n "$_DRS_EPOCH" ]; then
      _DRS_AGE=$(( $(date -u +%s) - _DRS_EPOCH ))
      [ "$_DRS_AGE" -ge "${DELIVERY_RUNNING_STALE_CEILING_S:-1800}" ] && _DELIVERY_RUNNING_STALE=1
    fi
  fi
  if [ "$_DELIVERY_RUNNING_STALE" = "1" ]; then
    warn "Story $STORY_ID has delivery:running since $_DELIVERY_RUNNING_SINCE (>= ${DELIVERY_RUNNING_STALE_CEILING_S:-1800}s ago) -- treating as abandoned (ga-015qqe), renewing the lock and re-processing this sweep instead of skipping."
    if [ "$DRY_RUN" != "1" ]; then
      bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery reconciler (ga-015qqe): delivery:running was set at $_DELIVERY_RUNNING_SINCE and never cleared -- the run that set it most likely crashed or was killed before finishing (no staleness check existed before this fix; wa-r4ehy.2 hit exactly this for ~3.5h). Renewing the lock with a fresh timestamp so this sweep retries cleanly." 2>/dev/null || true
      # ga-015qqe gate-fix (attempt 2): renew delivery.running_since IN PLACE
      # instead of removing the label here and relying on the CLAIM block
      # below to re-set it later. Between here and CLAIM (lines ~1549+) sit
      # two more checks that can `continue` this same iteration --
      # delivery:no-deploy-cmd-exhausted right below, and the OPEN_SIBLINGS
      # hold further down, which this file's own comments confirm is a real,
      # anticipated case for a cross-rig/resubmitted story (i.e. it CAN be
      # true for a story whose delivery is genuinely still mid-flight, not
      # actually abandoned -- the staleness heuristic above is a guess, not
      # proof of death). A bare `label remove` here, followed by either of
      # those `continue`s, left the story with NO lock at all until some
      # later, unrelated sweep happened to re-claim it -- opening a window
      # for a second, genuinely concurrent delivery run against a first one
      # that was merely slow. The label is already present (this whole branch
      # only runs when the CHECK above matched it) -- only the timestamp
      # needs to move, so the lock is never actually absent, whatever this
      # iteration does next. Gate-caught (gate_run=ga-epuc97): reviewer 1
      # traced the exact fall-through-into-OPEN_SIBLINGS window this closes.
      bd -C "$STORY_STORE" update "$STORY_ID" --set-metadata "delivery.running_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)" -q 2>/dev/null || true
    fi
    # Deliberately NOT `continue` -- fall through so THIS iteration re-processes
    # the story fresh instead of waiting a full extra sweep interval. The lock
    # itself was just renewed above (not removed), so any later `continue`
    # this same iteration takes (no-deploy-cmd-exhausted, OPEN_SIBLINGS)
    # leaves a freshly-timestamped lock behind -- identical in shape to what
    # the CLAIM block itself persists -- instead of no lock at all.
  else
    log "Story $STORY_ID already has delivery:running — skipping (already in flight)."
    continue
  fi
fi

# ga-aqqj0: skip if the no-deploy-cmd retry cap already escalated this story
# (Step 3 below). A human has been notified via bead comment + Mayor mail;
# do not keep re-halting/re-commenting every ~5min sweep while waiting for
# that human to fix the rig value or the runbook (that unbounded-comment loop
# — 18 identical halts in 1h on ga-dv2gk — is exactly what the retry cap
# exists to stop). Removing the label lets the sweep retry automatically.
if echo "$STORY_LABELS" | grep "delivery:no-deploy-cmd-exhausted" >/dev/null; then
  log "Story $STORY_ID already escalated (delivery:no-deploy-cmd-exhausted, ga-aqqj0) — no deploy_cmd halt already reported to a human. Skipping."
  continue
fi

# ga-0m6tgc: cross-rig/multi-marker awareness. quality-gate-dispatcher.sh
# adds gate:passed to the shared source bead unconditionally, per-marker,
# with no check for a SIBLING marker still pending on the SAME story. A
# cross-rig or resubmitted story can carry more than one gate marker citing
# it (source-bead:$STORY_ID); the FIRST to reach PASS+merge makes this bead
# selectable by Step 1 above even while a second marker, submitted
# separately, is still open/under review elsewhere. Deploying and marking
# story:done on that first marker alone would silently ship only part of
# the story's acceptance criteria while the rest sits unmerged, with
# nothing left watching the still-open marker once this bead reaches
# story:done (it stops matching Step 1's own selector).
#
# gate_bead_sibling_status_lines (quality-gate-guard.sh, sourced above —
# ga-0m6tgc moved it there from quality-gate-dispatcher.sh specifically so
# this file could reach it) returns one "<branch><TAB><status><TAB><rig>"
# line per NON-CLOSED marker/gate-run citing source-bead:$STORY_ID, always
# queried against GC_CITY (source-bead: labels are always written to the HQ
# city regardless of which store the story bead itself lives in — see that
# function's own header). This branch's OWN marker is already closed by the
# time gate:passed lands on the bead (the PASS path in quality-gate-
# dispatcher.sh closes the marker before setting the label, same
# invocation), so in the ordinary single-marker story — the overwhelming
# majority — this is always empty and nothing here changes behavior. A
# non-empty result means a genuinely different, still-open submission
# exists for this same story.
#
# ga-0m6tgc gate-fix (attempt 2): deliberately NOT `2>/dev/null` here. The
# function's own header documents writing its ALERT lines straight to
# stderr specifically so they survive being captured by `$(...)` and reach
# whatever this caller's stderr is directed to — which for this script is
# LOG (the `exec >> "$LOG" 2>&1` above), the same convention every OTHER
# caller of this function/its siblings already relies on (quality-gate-
# dispatcher.sh's gate_bead_active_sibling_branch/gate_bead_terminal_failed_
# sibling_branch call sites carry no local stderr redirect either). A local
# `2>/dev/null` here silently discarded the bd-query-failure ALERT this same
# fix adds — the one call site in the codebase that would have hidden it.
OPEN_SIBLINGS=$(gate_bead_sibling_status_lines "$GC_CITY" "$STORY_ID" || echo "")
if [ -n "$OPEN_SIBLINGS" ]; then
  log "Story $STORY_ID has an OPEN sibling gate marker — holding (ga-0m6tgc), not deploying:"
  printf '%s\n' "$OPEN_SIBLINGS" | while IFS="$(printf '\t')" read -r _sib_branch _sib_status _sib_rig; do
    [ -n "$_sib_branch" ] && log "  sibling: branch=$_sib_branch status=$_sib_status rig=${_sib_rig:-?}"
  done
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:blocked-sibling" -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "$(printf 'Delivery HELD (ga-0m6tgc): gate:passed is set, but at least one OTHER gate marker/run citing this story via source-bead: is still open (not yet terminal):\n\n%s\n\nA cross-rig or resubmitted story can have more than one marker; deploying/marking story:done on the first one to pass would silently ship only part of the scope while the rest is still in review. Re-checked every delivery sweep — this proceeds automatically once every marker reaches a terminal state.' "$OPEN_SIBLINGS")" 2>/dev/null || true
  fi
  # Non-terminal, retried every sweep — same posture as the wa-uthi holds
  # elsewhere in this file (no push, no story:done, just wait and re-check).
  continue
fi
# No open siblings (the common single-marker case, or every marker for this
# story has now reached a terminal state) — clear a stale hold label from a
# prior sweep, if any, before proceeding.
if [ "$DRY_RUN" != "1" ]; then
  bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:blocked-sibling" -q 2>/dev/null || true
fi

# Mark as running (claim)
if [ "$DRY_RUN" != "1" ]; then
  bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:running" -q 2>/dev/null || {
    warn "Could not add delivery:running to $STORY_ID (race condition?). Skipping."
    continue
  }
  # ga-015qqe: persist WHEN this claim was made so a later sweep (possibly a
  # different process, if this one dies) can tell a fresh claim apart from an
  # abandoned one -- see the staleness check above this loop's top. Best-effort
  # (|| true): if this write fails, the check above simply never finds a
  # timestamp for this story and fails closed (never treats it as stale),
  # same as any other missing-metadata case.
  bd -C "$STORY_STORE" update "$STORY_ID" --set-metadata "delivery.running_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)" -q 2>/dev/null || true
fi

DELIVERY_START=$(date +%s)

# ── Step 2: Determine rig from story metadata / labels ───────────────────────
# Priority order:
#   1. label  rig:<name>  on the bead
#   2. metadata field  story.rig
#   3. Parse the gate comment ("merged to <rig>/main") — set by dispatcher
RIG=""
if echo "$STORY_LABELS" | grep -oE "rig:[a-z_]+" | head -1 | grep "rig:" >/dev/null; then
  RIG=$(echo "$STORY_LABELS" | grep -oE "rig:[a-z_]+" | head -1 | sed 's/rig://')
fi

if [ -z "$RIG" ]; then
  RIG=$(echo "$STORY" | jq -r '.metadata // {} | .["story.rig"] // ""' 2>/dev/null || echo "")
fi

if [ -z "$RIG" ]; then
  # Parse the gate dispatcher comment: "merged to property_scrapers/main (sha=...)"
  #
  # ga-fic5d (Mayor, 2026-08-07): SEGUNDO sítio com o mesmo defeito do bloco de
  # merge-verification (~linha 929) — achado varrendo o IDIOMA, não pelo sintoma.
  # `bd comments` quebra o texto em ~80 colunas, a quebra cai entre "merged to" e
  # "<rig>/main", o grep não acha, RIG fica vazio e a entrega falha ANTES de
  # chegar à verificação de merge. Ler por --json, que não formata.
  #
  # Fallback pro formatado se o JSON render vazio: o pior caso volta a ser o bug
  # conhecido, nunca um RIG silenciosamente vazio por um caminho novo.
  _SD_COMMENTS=$(bd -C "$STORY_STORE" show "$STORY_ID" --json --include-comments 2>/dev/null \
    | jq -r '(if type=="array" then .[0] else . end).comments[]?.text // empty' 2>/dev/null || echo "")
  [ -z "$_SD_COMMENTS" ] && _SD_COMMENTS=$(bd -C "$STORY_STORE" comments "$STORY_ID" 2>/dev/null || echo "")
  # ga-aqqj0: delegate to derive_rig_from_comments (which delegates to
  # extract_gate_merge_info, defined above) instead of a second, looser,
  # ad hoc regex. That old regex — "merged to [a-z_]+/main" with `head -1`
  # over ALL comment text, no "(sha=...)" anchor — matched incidental HUMAN
  # PROSE quoting a gate comment (e.g. "...citando 'code merged to
  # origin/main...'") and let that earlier, incidental match shadow a later,
  # real, well-formed dispatcher comment. "origin" (a git REMOTE name, never
  # a rig) then sailed through as RIG and no runbook entry for it will ever
  # exist — see ga-dv2gk: 18 identical "no deploy_cmd for rig 'origin'" halts
  # in 1h on a story whose real fix was already merged to gascity's main.
  if RIG=$(derive_rig_from_comments "$_SD_COMMENTS"); then
    log "Rig derived from gate comment: $RIG"
  else
    RIG=""
  fi
fi

if [ -z "$RIG" ]; then
  err "Cannot determine rig for story $STORY_ID. Add label rig:<name> or metadata story.rig to the bead."
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery FAILED: cannot determine rig. Add label rig:<name> or metadata field story.rig to this bead." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (delivery:failed is re-picked every cycle until fixed —
  # retries indefinitely, not a definitive rejection) — no push. Logged + bead comment only.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID rig unknown — add rig:<name> label."
  continue
fi

log "Rig: $RIG"

# ── Step 3: Load runbook for this rig ─────────────────────────────────────────
DEPLOY_CMD=$(get_runbook_field "$RIG" "deploy_cmd" 2>/dev/null || echo "")
RUNTIME_DIR=$(get_runbook_field "$RIG" "runtime_dir" 2>/dev/null || echo "")
PROD_TEST_SCRIPT=$(get_runbook_field "$RIG" "prod_test_script" 2>/dev/null || echo "")

if [ -z "$DEPLOY_CMD" ]; then
  err "No deploy_cmd for rig '$RIG' in runbook. Story delivery blocked."
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    # ga-aqqj0: cap consecutive halts for this story instead of commenting
    # forever — same shape, same file, same mail convention as the
    # ga-s1qb2 delivery:close-retry(-exhausted) circuit breaker the task
    # reconciler already uses above for its own "reconciler stuck, needs a
    # human" case. Before this, a rig value that can never have a runbook
    # entry (e.g. 'origin', a git remote name wrongly resolved as a rig)
    # HALTED every sweep forever: 18 identical comments in 1h on ga-dv2gk.
    RIG_HALT_RETRY=$(echo "$STORY" | jq -r '
      (.labels // []) | map(select(startswith("delivery:no-deploy-cmd-retry:"))) | .[0] // ""
      | if . == "" then "0" else ltrimstr("delivery:no-deploy-cmd-retry:") end
    ' 2>/dev/null || echo "0")
    case "$RIG_HALT_RETRY" in ''|*[!0-9]*) RIG_HALT_RETRY=0 ;; esac
    RIG_HALT_RETRY_NEXT=$((RIG_HALT_RETRY + 1))
    [ "$RIG_HALT_RETRY" -gt 0 ] && bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:no-deploy-cmd-retry:$RIG_HALT_RETRY" -q 2>/dev/null || true
    if [ "$RIG_HALT_RETRY_NEXT" -ge "$DELIVERY_NO_DEPLOY_CMD_MAX_RETRIES" ]; then
      bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:no-deploy-cmd-exhausted" -q 2>/dev/null || true
      bd -C "$STORY_STORE" label add "$STORY_ID" "gate:needs-human" -q 2>/dev/null || true
      bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED $RIG_HALT_RETRY_NEXT/$DELIVERY_NO_DEPLOY_CMD_MAX_RETRIES times: no deploy_cmd for rig '$RIG' in runbook (ga-aqqj0 retry cap) — NOT retrying further to avoid an unbounded loop of identical comments. Either '$RIG' is not a real rig (check Step 2's rig resolution: label rig:<name>, metadata story.rig, or the gate's own merge comment) or delivery-runbooks.toml genuinely needs a deploy_cmd entry for it. A human must fix the rig value or the runbook, then remove label delivery:no-deploy-cmd-exhausted to let this retry automatically." 2>/dev/null || true
      gc --city "$GC_CITY" mail send mayor \
        -s "Delivery: no deploy_cmd for rig '$RIG' exhausted retries ($STORY_ID)" \
        -m "$(printf 'Story %s halted %s times with "no deploy_cmd for rig %s" (ga-aqqj0 retry cap) — this cannot converge on its own.\n\nStore: %s\n\nCheck whether %s is a real rig with a runbook entry in delivery-runbooks.toml, or a rig-resolution bug (Step 2 of story-delivery.sh, derive_rig_from_comments). This story will no longer be auto-retried — fix the rig value or the runbook, then remove label delivery:no-deploy-cmd-exhausted to let delivery try again automatically.' \
          "$STORY_ID" "$RIG_HALT_RETRY_NEXT" "$RIG" "$STORY_STORE" "$RIG")" \
        2>/dev/null || warn "Could not mail Mayor no-deploy-cmd-exhausted escalation for $STORY_ID (ga-aqqj0)"
    else
      bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:no-deploy-cmd-retry:$RIG_HALT_RETRY_NEXT" -q 2>/dev/null || true
      bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED: no deploy_cmd for rig '$RIG'. Codify the deploy runbook before retrying. (attempt $RIG_HALT_RETRY_NEXT/$DELIVERY_NO_DEPLOY_CMD_MAX_RETRIES before this escalates and stops auto-retrying — ga-aqqj0)" 2>/dev/null || true
    fi
  fi
  # wa-uthi: non-terminal (config gap, retries every cycle once codified) — no push. Logged + bead comment only.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID — no deploy_cmd for rig $RIG."
  continue
fi

# Bug 2 fix (ga-dqp): warn-only when the rig has NO prod-test harness at all.
# RATIONALE: some rigs (e.g. whatsapp_automation) have no prod_test_script yet.
# Halting delivery for every WA story blocks the pipeline indefinitely.
# INTERIM POLICY: if prod_test_script is empty/missing → deliver + warn (story:done
# with delivery:untested label). If the rig HAS a harness but the file is absent
# or the story-specific test is missing, HALT as before (author must fix).
# DESTINY: add a real prod-test harness per rig (tracked as follow-up).
NO_HARNESS=0
if [ -z "$PROD_TEST_SCRIPT" ]; then
  warn "No prod_test_script configured for rig '$RIG' — rig has no test harness. Proceeding with delivery:untested (interim policy)."
  NO_HARNESS=1
fi

# wa-l5z9 + ga-857v FIX 2: a MISSING story-specific prod test is NON-BLOCKING.
# RATIONALE (flow-never-stops): the pipeline must never stall just because nobody
# wrote a story-specific test. wa-l5z9 first removed the HALT/per-cycle NTFY for
# this case by SKIPPING the prod test → delivery:untested.
# ga-857v FIX 2 finishes the job wa-l5z9's comments deferred to it ("coverage
# tracked by ga-857v"): instead of skipping, if the rig HAS a harness we now RUN
# the rig's BASELINE harness (run.sh invoked WITHOUT STORY_ID, so no rig's run.sh
# can hard-fail on the absent story test) → a passing baseline yields
# delivery:tested. The flow still never HALTs on a *missing* test; it only fails
# if the baseline detects genuinely broken prod (which SHOULD halt). The sole
# remaining delivery:untested case is NO_HARNESS=1 (rig has no harness at all).
STORY_TEST_MISSING=0

if [ "$NO_HARNESS" = "0" ] && [ ! -f "$PROD_TEST_SCRIPT" ]; then
  err "prod_test_script '$PROD_TEST_SCRIPT' not found on disk."
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED: prod_test_script '$PROD_TEST_SCRIPT' not found. File must exist." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (runbook misconfig — points to a non-existent harness
  # file; retries every cycle until fixed) — no push. Logged + bead comment only.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID — prod_test_script '$PROD_TEST_SCRIPT' not found on disk."
  continue
fi

# Check for story-specific test existence (only if the rig HAS a harness).
# wa-l5z9: an ABSENT story-specific test is NON-BLOCKING (warn-only) — set
# STORY_TEST_MISSING=1 and continue. Delivery proceeds and ends at story:done
# with delivery:untested (same warn-only path as the no-harness case). No HALT,
# no per-cycle NTFY.
SCRIPT_DIR=""
STORY_TEST_FILE=""
if [ "$NO_HARNESS" = "0" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$PROD_TEST_SCRIPT")" && pwd)"
  STORY_TEST_FILE="$SCRIPT_DIR/story-${STORY_ID}.sh"
  if [ ! -f "$STORY_TEST_FILE" ]; then
    warn "No story-specific prod test: $STORY_TEST_FILE — proceeding with delivery:untested (wa-l5z9 warn-only policy). Flow never stops; coverage tracked by ga-857v/ga-iwv0."
    STORY_TEST_MISSING=1
  fi
fi

log "Runbook loaded: deploy_cmd='$DEPLOY_CMD' runtime='$RUNTIME_DIR' test='$PROD_TEST_SCRIPT'"

# ── Step 3.5: Reconcile untracked-vs-tracked before deploy (ga-857v FIX 1) ────
# Prevents the ff-pull abort when the runtime holds an untracked copy of a file
# the incoming merge adds as tracked. Identical duplicates are backed up +
# removed; a genuine divergence halts + escalates (never clobbered).
#
# SCOPE: only run when the deploy will execute a FATAL fast-forward-only
# merge (the bug's domain — property_scrapers, whatsapp_automation). Rigs
# whose deploy swallows pull failures (e.g. gascity: "... 2>/dev/null ||
# true") or that don't pull at all are NOT subject to the untracked-overwrite
# abort, so the reconcile must NOT run for them — otherwise a pre-existing,
# harmless untracked file in that runtime (e.g. the town root's .gitignore)
# would wrongly halt delivery.
#
# ga-nh1muq: matches `pull --ff-only` (property_scrapers), the explicit
# `merge --ff-only` a deploy_cmd takes after switching off the racy
# FETCH_HEAD-reading `pull` form (lexbh's pre-existing "fetch && merge
# --ff-only" entry — that rig was silently missing this same reconcile
# before this fix, since its deploy_cmd never matched the old pull-only
# pattern either), AND a deploy_cmd that calls out to
# scripts/git-deploy-pull.sh (whatsapp_automation, after this same bead's
# fix). That last one is NOT textually a "pull"/"merge" invocation at all —
# it's an opaque call to a wrapper script that performs the fatal ff-merge
# INTERNALLY, invisible to a string match on $DEPLOY_CMD — so it needs its
# own explicit alternative rather than being caught by the other two
# patterns (caught by story-delivery.selftest.sh section 12, which failed
# on exactly this gap during development). All three shapes abort
# identically on an untracked-file collision — same git merge/checkout
# machinery underneath — so all three need the same protection.
# SELFTEST-EXTRACT run-reconcile-classify: BEGIN
# (kept extractable+runnable standalone by story-delivery.selftest.sh's
# "run-reconcile-classify" section — mirrors the technique
# scripts/git-lock-hygiene.sh uses for the same reason: this classifies pure
# string shape with no I/O, so a snippet harness can drive it directly
# against every known deploy_cmd shape without sourcing/running the whole
# 2900+ line script.)
RUN_RECONCILE=0
case "$DEPLOY_CMD" in
  *"pull --ff-only"*|*"merge --ff-only"*|*"git-deploy-pull.sh"*)
    case "$DEPLOY_CMD" in
      *"|| true"*) RUN_RECONCILE=0 ;;  # failure swallowed → not fatal
      *)           RUN_RECONCILE=1 ;;
    esac
    ;;
esac
# SELFTEST-EXTRACT run-reconcile-classify: END

if [ "$RUN_RECONCILE" != "1" ]; then
  log "Pre-deploy reconcile skipped — deploy_cmd for rig '$RIG' does not run a fatal ff-pull."
elif reconcile_untracked_for_ffpull "$RUNTIME_DIR"; then
  if [ "$RECONCILE_COUNT" -gt 0 ]; then
    log "Pre-deploy reconcile: backed up + removed $RECONCILE_COUNT identical untracked duplicate(s) so the ff-pull can land the tracked version(s)."
  fi
else
  # Return 2 → genuine divergence between an untracked prod file and the merge.
  err "Pre-deploy reconcile ABORT: untracked working-tree file(s) DIFFER from the incoming tracked version:$RECONCILE_DIFF_LIST"
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED (ga-857v FIX 1): the production working tree at $RUNTIME_DIR holds untracked file(s) that the incoming merge adds as tracked, and they GENUINELY DIFFER from the merged version:$RECONCILE_DIFF_LIST
These were NOT removed — uncommitted prod work is never destroyed. Resolve manually: diff each untracked file against origin's version, preserve any real local changes, then re-run delivery." 2>/dev/null || true
    # Escalate to author + Mayor via nudge (durable record is the bead comment + label).
    AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
    if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
      gc --city "$GC_CITY" session nudge "$AUTHOR" \
        "DELIVERY HALTED for story $STORY_ID: untracked prod file(s) differ from the incoming merge:$RECONCILE_DIFF_LIST. NOT clobbered — resolve manually, then re-run delivery." \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
    fi
    gc --city "$GC_CITY" session nudge mayor \
      "DELIVERY HALTED ($STORY_ID, rig $RIG): untracked working-tree file(s) at $RUNTIME_DIR differ from the incoming merged version:$RECONCILE_DIFF_LIST. Not removed (no data loss). Manual resolution needed before re-running delivery." \
      2>/dev/null || true
  fi
  # wa-uthi: non-terminal (delivery:failed is re-picked every cycle until the
  # divergence is resolved — retries, not a definitive rejection) — SUPPRESS the
  # Athos push. Author + Mayor are nudged above; the bead comment is the record.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID reconcile conflict — untracked prod file differs from merge:$RECONCILE_DIFF_LIST."
  continue
fi

# ── Step 3.6: Pre-deploy merge verification (ga-mmdm2) ────────────────────────
# THE BUG: gate:passed is a label, not proof the story's commit reached the
# rig's remote main. Deploy (Step 4 below) used to trust the label alone and
# pull whatever origin/main currently is — proven broken live on ga-sb11i.2:
# gate:passed AND gate-sha-failed on the SAME sha, the commit existing only on
# its feature branch. Deploying would have pulled main AS-IS (no fix), the
# baseline prod test would still pass (main is healthy, just missing the
# feature), and the story would be marked done while the work sat only on its
# source branch — 511 reviewed lines silently lost.
#
# Verify by content before deploying:
#   1. Extract the sha the gate itself reported merging, from the gate's OWN
#      comment ("merged to <rig>/<branch> (sha=<sha>)") — never from
#      gate-sha-failed, which records what FAILED, not what merged.
#   2. Confirm that sha is an ancestor of the rig's own origin/<branch>
#      (fetched fresh, bounded, from RUNTIME_DIR — the same tree Step 4 is
#      about to deploy). No merge comment, or an unresolvable sha/ref, is
#      UNVERIFIED — blocked the SAME as a confirmed non-ancestor. Delivery is
#      never defaulted to "proceed" just because verification was impossible.
#
# MERGE_VERDICT starts (and stays, on any early branch) at "unresolvable" —
# only the explicit success path below sets it to "verified". Fail-closed by
# construction, not by remembering to add a check on every exit.
MERGE_VERDICT="unresolvable"
MERGE_SHA=""
MERGE_PRE_MAIN=""
MERGE_REF=""
MERGE_FAIL_MSG=""
if [ -z "$RUNTIME_DIR" ] || ! git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MERGE_FAIL_MSG="RUNTIME_DIR ('$RUNTIME_DIR') for rig $RIG is unset or not a git work tree — cannot verify the story's commit reached $RIG's main."
else
  # ga-fic5d (Mayor, 2026-08-07): LER POR --json, NUNCA por `bd comments`.
  #
  # `bd comments` formata para leitura humana e QUEBRA a linha em ~80 colunas. O
  # comentário de merge do gate é longo, e a quebra caía no ponto fatal:
  #     "Quality gate PASSED. Branch crew/oracle/wa-8ok7u merged to"
  #     "whatsapp_automation/main (sha=fc40e581...)"
  # O regex de extract_gate_merge_info exige "merged to <rig>/<branch> (sha=…)"
  # TUDO NA MESMA LINHA — com a quebra ali, nunca casa. O guard então concluía
  # "nenhum comentário de merge existe" e travava a entrega de stories cujo merge
  # estava feito e verificável.
  #
  # Medido no mesmo bead, no mesmo instante:
  #     bd comments <id>  -> 43871 bytes, exit 0, ZERO linhas casam
  #     bd show --json    -> as MESMAS duas linhas casam
  # E story_merge_verdict, com o sha extraído do JSON, devolve 'verified'. Todo o
  # resto do guard já estava correto; só a leitura era cega.
  #
  # ⚠️ "não existe comentário de merge" e "existe, mas li por um canal que o
  # mutila" produziam a MESMA mensagem. E o custo era permanente: delivery:failed
  # não auto-retenta, então cada story afetado travava até intervenção manual.
  #
  # NÃO troque por `tr -d '\n'` sobre a saída formatada: isso junta comentários
  # DIFERENTES e pode fabricar um "merged to" que ninguém escreveu — pior que o
  # bug original. O canal tem que ser o que não formata.
  STORY_COMMENTS_TEXT=$(bd -C "$STORY_STORE" show "$STORY_ID" --json --include-comments 2>/dev/null \
    | jq -r '(if type=="array" then .[0] else . end).comments[]?.text // empty' 2>/dev/null || echo "")
  # Fail-open explícito: se o caminho JSON não render nada (bd sem
  # --include-comments, jq ausente, Dolt fora), cai no formatado. O pior caso
  # volta a ser o bug conhecido — nunca uma regressão silenciosa para vazio.
  if [ -z "$STORY_COMMENTS_TEXT" ]; then
    STORY_COMMENTS_TEXT=$(bd -C "$STORY_STORE" comments "$STORY_ID" 2>/dev/null || echo "")
  fi
  if MERGE_INFO=$(extract_gate_merge_info "$STORY_COMMENTS_TEXT"); then
    MERGE_RIG_BRANCH="${MERGE_INFO%%$'\t'*}"
    MERGE_SHA="${MERGE_INFO#*$'\t'}"
    MERGE_BRANCH="${MERGE_RIG_BRANCH#*/}"
    MERGE_REF="origin/$MERGE_BRANCH"
    # ga-6zkhci fix-attempt-3: independent extraction over the same raw text
    # (see extract_gate_merge_pre_main's own header for why this is a
    # separate function rather than a 3rd field here). rc1/empty (older-
    # format comment, or the dispatcher's own MAIN_HEAD_SHA capture was
    # empty) leaves MERGE_PRE_MAIN at its "" default from above — Step 5b
    # below treats that as UNKNOWN, never as license to guess a substitute.
    MERGE_PRE_MAIN="$(extract_gate_merge_pre_main "$STORY_COMMENTS_TEXT" || true)"
    timeout 30 git -C "$RUNTIME_DIR" fetch origin "$MERGE_BRANCH" --quiet 2>/dev/null \
      || warn "Merge-verify: 'git fetch origin $MERGE_BRANCH' failed/timed out for $RIG — verifying against last-known $MERGE_REF."
    MERGE_GITDIR_PAIR=$(rig_gitdir "$RUNTIME_DIR")
    MERGE_GDIR="${MERGE_GITDIR_PAIR%$'\t'*}"
    MERGE_CONTAINER="${MERGE_GITDIR_PAIR#*$'\t'}"
    # ga-mmdm2 gate-fix-attempt-2: story_merge_verdict returns rc1 on both
    # "not-ancestor" and "unresolvable" (only "verified" is rc0) — a bare
    # assignment here triggers this file's own `set -euo pipefail` (errexit)
    # and aborts the WHOLE script before the halt-and-escalate block below
    # ever runs, since this loop is fed via process substitution (not a
    # subshell) and errexit isn't scoped to one iteration. Guard it, matching
    # the extract_gate_merge_info call two lines above.
    if ! MERGE_VERDICT=$(story_merge_verdict "$MERGE_GDIR" "$MERGE_CONTAINER" "$MERGE_REF" "$MERGE_SHA"); then
      : # non-"verified" outcome — $MERGE_VERDICT is still captured; handled below
    fi
    if [ "$MERGE_VERDICT" != "verified" ]; then
      MERGE_FAIL_MSG="sha $MERGE_SHA (from the gate's merge comment) is NOT an ancestor of $MERGE_REF in $RUNTIME_DIR (verdict=$MERGE_VERDICT) — the story's commit has not reached $RIG's main. gate:passed does not imply merged (ga-mmdm2)."
    fi
  else
    MERGE_FAIL_MSG="no gate merge comment with a sha was found on $STORY_ID — cannot verify the story's commit ever reached $RIG's main."
  fi
fi

if [ "$MERGE_VERDICT" != "verified" ]; then
  err "Pre-deploy merge verification HALT (ga-mmdm2): $MERGE_FAIL_MSG"
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED (ga-mmdm2 pre-deploy merge verification): $MERGE_FAIL_MSG story:done WITHHELD — deploying now would pull $RIG's main AS-IS (without this story's fix) and could still pass a baseline prod test, marking the story done while the work sits only on its source branch. NON-TERMINAL: re-picked next cycle once the branch is actually merged to $RIG's main via the gate (re-submit through gate re-anchor, not a manual merge)." 2>/dev/null || true
    AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
    if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
      gc --city "$GC_CITY" session nudge "$AUTHOR" \
        "DELIVERY HALTED for story $STORY_ID (ga-mmdm2): $MERGE_FAIL_MSG" \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
    fi
    gc --city "$GC_CITY" session nudge mayor \
      "DELIVERY HALTED ($STORY_ID, rig $RIG, ga-mmdm2 merge verification): $MERGE_FAIL_MSG" \
      2>/dev/null || true
  fi
  # wa-uthi: non-terminal (delivery:failed re-picked every cycle once the story
  # is actually merged) — no push. Author + Mayor nudged above.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID pre-deploy merge verification $MERGE_VERDICT."
  continue
fi
log "Pre-deploy merge verification OK: sha $MERGE_SHA is an ancestor of $MERGE_REF."

# ── Step 4: Deploy ─────────────────────────────────────────────────────────────
# Capture the deploy timestamp + pre-deploy HEAD so Step 5b (ga-iwv0) can tell
# which source files this deploy changed and prove the affected daemons restart
# AFTER the deploy. Both are best-effort: only meaningful when runtime_dir is a
# git work tree (the rigs whose deploy is a git-pull).
DEPLOY_EPOCH=$(date +%s)
PRE_DEPLOY_SHA=""
if [ -n "$RUNTIME_DIR" ] && git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PRE_DEPLOY_SHA=$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD RUN: $DEPLOY_CMD"
else
  log "Deploying rig $RIG ..."
  DEPLOY_OUTPUT=$(eval "$DEPLOY_CMD" 2>&1) && DEPLOY_RC=$? || DEPLOY_RC=$?
  log "Deploy output: $DEPLOY_OUTPUT"
  if [ "$DEPLOY_RC" -ne 0 ]; then
    err "Deploy failed (rc=$DEPLOY_RC): $DEPLOY_OUTPUT"
    bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery FAILED at deploy step. Command: $DEPLOY_CMD. Output: $DEPLOY_OUTPUT. HALT — investigate before retrying." 2>/dev/null || true
    # wa-uthi: non-terminal (delivery:failed is re-picked next cycle — retries, no
    # retry-exhaustion counter) — no push. Logged + bead comment only.
    warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID deploy failed (rc=$DEPLOY_RC)."
    continue
  fi
  log "Deploy OK"
fi

# Post-deploy HEAD (the SHA the runtime is now serving). With PRE_DEPLOY_SHA this
# brackets exactly what the deploy changed.
POST_DEPLOY_SHA=""
if [ -n "$RUNTIME_DIR" ] && git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  POST_DEPLOY_SHA=$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

# ── Step 4.5: Post-deploy town-root staleness gate (ga-rhtu) ──────────────────
# THE BUG: rigs whose deploy_cmd runs a BEST-EFFORT, swallowed ff-pull
# (`git -C <dir> pull --ff-only ... 2>/dev/null || true; <install>` — the
# gascity / in-place HQ-framework runtime) can silently keep running STALE code.
# If that runtime's branch carries LOCAL-AHEAD or DIVERGED commits, or its `main`
# tracks a stale upstream (a fork remote), the ff-pull CANNOT fast-forward to
# origin/main, the `|| true` eats the failure, and Step 4 logs "Deploy OK" on a
# tree that never received the just-merged fix. Delivery would then mark
# story:done while the live engines run outdated code (proven on ga-jb4l).
# FATAL-pull rigs are NOT affected — a failed `pull --ff-only` already halts
# Step 4 above — so this gate runs ONLY for the swallowed-pull class.
#
# Fail-closed verification: after deploy, the runtime HEAD must CONTAIN
# origin/<branch> (the canonical merge target the gate pushes to). If
# origin/<branch> is an ANCESTOR of HEAD (HEAD is current, or merely local-ahead
# — a documented, legitimate state for the in-place town root) delivery
# proceeds. If HEAD is BEHIND or DIVERGED (origin/<branch> is NOT an ancestor —
# the merged fix is missing), or freshness cannot be verified at all, delivery
# HALTS LOUDLY (delivery:failed, escalate author + Mayor, story:done WITHHELD)
# and is re-picked next cycle once the town-root reconciler brings the tree
# current. It does NOT reconcile the tree itself: THIS script runs in-place from
# that tree, so a self-mutating ff mid-run risks corrupting the running engine —
# advancing the tree is the reconciler's job, not delivery's.
STALENESS_GATE=0
case "$DEPLOY_CMD" in
  *"pull --ff-only"*)
    case "$DEPLOY_CMD" in
      *"|| true"*) STALENESS_GATE=1 ;;   # swallowed ff-pull → the vulnerable class
    esac
    ;;
esac
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — skipping post-deploy staleness gate."
  STALENESS_GATE=0
fi
if [ "$STALENESS_GATE" = "1" ] && [ -n "$RUNTIME_DIR" ] \
   && git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  STALE_BRANCH=$(git -C "$RUNTIME_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  case "$STALE_BRANCH" in ""|HEAD) STALE_BRANCH="main" ;; esac
  STALE_REF="origin/$STALE_BRANCH"
  # Best-effort, bounded refresh of the canonical ref. Never fatal on its own —
  # the deploy's own pull already fetched; this only guards a stale local ref.
  timeout 30 git -C "$RUNTIME_DIR" fetch origin "$STALE_BRANCH" --quiet 2>/dev/null \
    || warn "Staleness gate: 'git fetch origin $STALE_BRANCH' failed/timed out — comparing against last-known $STALE_REF."
  STALE_REMOTE_SHA=$(git -C "$RUNTIME_DIR" rev-parse "$STALE_REF" 2>/dev/null || echo "")
  STALE_HEAD_SHA=$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if [ -z "$STALE_REMOTE_SHA" ]; then
    STALE_VERDICT="UNVERIFIABLE"
  elif git -C "$RUNTIME_DIR" merge-base --is-ancestor "$STALE_REF" HEAD 2>/dev/null; then
    STALE_VERDICT="CURRENT"     # HEAD contains origin/<branch> (current or local-ahead) → fresh
  else
    STALE_VERDICT="STALE"       # behind or diverged → the merged fix is NOT live
  fi

  if [ "$STALE_VERDICT" = "CURRENT" ]; then
    log "Staleness gate OK: $RUNTIME_DIR HEAD ($STALE_HEAD_SHA) contains $STALE_REF ($STALE_REMOTE_SHA)."
  else
    STALE_COUNTS=$(git -C "$RUNTIME_DIR" rev-list --left-right --count "$STALE_REF...HEAD" 2>/dev/null || printf '?\t?')
    STALE_BEHIND=$(printf '%s' "$STALE_COUNTS" | awk '{print $1}')
    STALE_AHEAD=$(printf '%s' "$STALE_COUNTS" | awk '{print $2}')
    if [ "$STALE_VERDICT" = "UNVERIFIABLE" ]; then
      STALE_MSG="could not resolve $STALE_REF in $RUNTIME_DIR — freshness UNVERIFIABLE (failing closed to avoid a false story:done)"
    else
      STALE_MSG="live runtime $RUNTIME_DIR is STALE — HEAD ($STALE_HEAD_SHA) is behind=$STALE_BEHIND / ahead=$STALE_AHEAD vs $STALE_REF ($STALE_REMOTE_SHA); the merged fix did NOT reach the in-place engines"
    fi
    err "Staleness gate HALT (ga-rhtu): $STALE_MSG"
    if [ "$DRY_RUN" != "1" ]; then
      bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
      bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
      bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED (ga-rhtu post-deploy staleness gate): $STALE_MSG. story:done WITHHELD — the live framework engines would otherwise be marked done while running outdated code. NON-TERMINAL: the town-root reconciler brings $RUNTIME_DIR current with $STALE_REF, after which delivery is re-picked automatically. If HEAD carries local-ahead commits on the in-place town root, move them to an isolated worktree (ref: 'Shipping framework stories via gate') so the tree stays fast-forwardable." 2>/dev/null || true
      AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
      if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
        gc --city "$GC_CITY" session nudge "$AUTHOR" \
          "DELIVERY HALTED for story $STORY_ID: $STALE_MSG. story:done withheld; re-picked once the town root is reconciled to $STALE_REF." \
          --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
      fi
      gc --city "$GC_CITY" session nudge mayor \
        "DELIVERY HALTED ($STORY_ID, rig $RIG): $STALE_MSG. story:done withheld (ga-rhtu staleness gate). Reconcile $RUNTIME_DIR to $STALE_REF; delivery retries next cycle." \
        2>/dev/null || true
    fi
    # Non-terminal (re-picked every cycle until the tree is reconciled — retries,
    # not a definitive rejection) → SUPPRESS the Athos push (wa-uthi convention).
    warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID — $STALE_MSG."
    continue
  fi
fi

# ── Step 5: Daemon restarts ────────────────────────────────────────────────────
DAEMON_LIST=$(get_runbook_field "$RIG" "daemon_restarts" 2>/dev/null || echo "")
if [ -n "$DAEMON_LIST" ]; then
  while IFS= read -r daemon; do
    [ -z "$daemon" ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN=1 — WOULD kickstart launchd: $daemon"
    else
      log "Kickstarting daemon: $daemon"
      launchctl kickstart -k "gui/$(id -u)/$daemon" 2>/dev/null \
        || launchctl kickstart "$daemon" 2>/dev/null \
        || warn "launchctl kickstart failed for $daemon (may already be running or label wrong)"
    fi
  done <<< "$DAEMON_LIST"
fi

# ── Step 5b: Daemon freshness refresh + verification (ga-iwv0) ────────────────
# THE BUG: the deploy above is a git-pull — it updates files on disk but does
# NOT restart long-lived launchd daemons. A daemon-side feature merged into an
# already-running process stays DORMANT until that process restarts for some
# other reason, while the story is marked story:done (ga-d81: ban-risk-dashboard
# served 5-day-old code; every new endpoint 404'd). This step closes the gap:
# it detects which RUNNING daemons the merged files affect, restarts the SAFE
# (read-only dashboard) ones, and VERIFIES each came up AFTER this deploy.
# SENSITIVE hot-path daemons (central_sender, webhook_receiver, slot_scheduler,
# conversation_monitor — from the rig's sensitive_daemons runbook field) are
# NEVER auto-bounced (in-flight messages/webhooks must drain first); they are
# flagged for a guarded restart. A dormant or unverifiable daemon HALTS delivery
# here, BEFORE story:done — making a dormant deploy impossible to mark done.
#
# Skipped for the framework/town-root rig: its own engine daemons (this very
# script, the gate dispatcher, the reconcilers) must not be self-restarted
# mid-run; they are handled by config-drift-watcher + the static daemon_restarts
# above. Also skipped when runtime_dir is unset.
REFRESH_HELPER="$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh"
# ga-vmq1i: fresh on every story in the sweep loop (fail closed) — never let a
# PRIOR story's REFRESH_PROOF leak into one that takes a skip branch below.
REFRESH_PROOF="not_verified"
if [ -z "$RUNTIME_DIR" ] || [ "$RUNTIME_DIR" = "$GC_CITY" ]; then
  log "Daemon refresh skipped — framework/town-root or no runtime_dir (RUNTIME_DIR='$RUNTIME_DIR')."
elif [ ! -f "$REFRESH_HELPER" ]; then
  warn "daemon-refresh helper missing at $REFRESH_HELPER — skipping freshness verification (degraded; cannot prove daemons are live)."
else
  SENSITIVE_DAEMONS=$(get_runbook_field "$RIG" "sensitive_daemons" 2>/dev/null | tr '\n' ' ' || echo "")
  EXTRA_RUNTIME_ROOTS=$(get_runbook_field "$RIG" "extra_runtime_roots" 2>/dev/null | tr '\n' ' ' || echo "")
  # ga-gokm6: for a self-repo rig (runtime_dir == git_repo, e.g.
  # whatsapp_automation), something OTHER than this loop iteration — a crew
  # session's own post-merge fast-forward, or a sibling story's delivery
  # earlier in the same sweep — can advance RUNTIME_DIR's HEAD past this
  # story's merge commit before PRE_DEPLOY_SHA was captured above, so the
  # pull just ran is a true no-op ("Already up to date") and
  # PRE_DEPLOY_SHA==POST_DEPLOY_SHA. That is a real fact about THIS pull, but
  # it is NOT the same claim as "every live daemon has been checked against
  # everything that landed" — daemon-refresh.sh's Step 1 cannot tell the two
  # apart and short-circuits to VERDICT=SKIPPED/PROOF=not_applicable without
  # ever running discovery, silently skipping the exact protection this step
  # exists to provide. Confirmed live in story-delivery.log: wa-gqdtk
  # (2026-09-11T18:05:55Z) and wa-fuveb (2026-09-11T15:47:35Z) both logged
  # "no SHA delta (X .. X) — deploy changed nothing — skip" while
  # com.whatsapp.pipedrive-sync (not in this rig's sensitive_daemons list,
  # but caught by restart_policy.yaml's own "unlisted = manual" default, per
  # policy_says_sensitive() in daemon-refresh.sh) ran ~2h of pre-merge code
  # unflagged, requiring a manual restart. Feed the helper the delta since
  # the last sha it actually got a chance to examine (see
  # daemon_refresh_baseline_file() above and the marker write below) instead
  # of since this iteration's own possibly-already-caught-up pre-pull HEAD.
  # A missing/unreadable marker, or one that is not an ancestor of
  # POST_DEPLOY_SHA (first run for this rig, or a rebase/reset), falls back
  # to today's PRE_DEPLOY_SHA unchanged — pure no-op in both cases.
  # (Inlined rather than a helper function: this whole Step 5b block is
  # extracted verbatim and eval'd standalone by
  # tests/story-delivery-step5b.test.sh — a function defined elsewhere in
  # this file would not exist in that context.)
  DAEMON_REFRESH_PRE_SHA="$PRE_DEPLOY_SHA"
  DAEMON_REFRESH_BASELINE_DIR="$GC_CITY/.gc/runtime/daemon-refresh-baseline"
  mkdir -p "$DAEMON_REFRESH_BASELINE_DIR" 2>/dev/null || true
  DAEMON_REFRESH_BASELINE_FILE="$DAEMON_REFRESH_BASELINE_DIR/$RIG.sha"
  DAEMON_REFRESH_BASELINE_SHA="$(cat "$DAEMON_REFRESH_BASELINE_FILE" 2>/dev/null || echo "")"
  if [ -n "$DAEMON_REFRESH_BASELINE_SHA" ] \
     && git -C "$RUNTIME_DIR" cat-file -e "${DAEMON_REFRESH_BASELINE_SHA}^{commit}" 2>/dev/null \
     && git -C "$RUNTIME_DIR" merge-base --is-ancestor "$DAEMON_REFRESH_BASELINE_SHA" "$POST_DEPLOY_SHA" 2>/dev/null; then
    DAEMON_REFRESH_PRE_SHA="$DAEMON_REFRESH_BASELINE_SHA"
  fi
  # ga-0fawwr: per-daemon baseline overrides — see daemon-refresh.sh's own
  # comment at its point of use (end of its Step 3) for the full rationale.
  # Read as free-form text and handed to the helper verbatim; the helper
  # alone validates each "<label> <sha>" line's ancestry before trusting it,
  # so a stale/foreign/corrupt line here can only ever be ignored there,
  # never misused — this read needs no validation of its own.
  DAEMON_REFRESH_PERDAEMON_FILE="$DAEMON_REFRESH_BASELINE_DIR/$RIG.perdaemon"
  DAEMON_BASELINE_OVERRIDES="$(cat "$DAEMON_REFRESH_PERDAEMON_FILE" 2>/dev/null || echo "")"
  # ga-3bdttu: DAEMON_REFRESH_PRE_SHA above can be far older than this story's
  # own pull — frozen at whatever it was when an earlier, still-unresolved
  # sensitive-daemon restart last blocked the marker from advancing (the
  # write-back below only fires on OK/SKIPPED). daemon-refresh.sh's CHANGED
  # set is computed over that WIDE range, which is correct for "is any daemon
  # stale", but a non-OK verdict from it does NOT mean THIS story's own merge
  # is the cause — a sweep delivers many stories, and the whole verdict used
  # to get pinned on whichever one happened to close the window (confirmed
  # live, story-delivery.log 2026-09-12: wa-u09s4 11:04 and wa-m6v3d 11:17,
  # each a single tests/*.py-only merge, both held with delivery:failed for a
  # demand-dashboard staleness neither introduced). Compute THIS story's own
  # contribution separately — its real PRE_DEPLOY_SHA..POST_DEPLOY_SHA, never
  # the widened DAEMON_REFRESH_PRE_SHA — and, only when that delta is itself
  # tests/**+docs/**+*.md-only, exempt the BLAME/HOLD decision below (never
  # the underlying restart requirement, which stays real and unresolved for
  # whichever earlier commit actually caused it — see the case statement).
  # Left unset (not "0") when PRE_DEPLOY_SHA==POST_DEPLOY_SHA: that is a true
  # this-iteration no-op (ga-gokm6's own scenario — a sibling story's
  # delivery already advanced HEAD past this story's own commit before
  # PRE_DEPLOY_SHA was captured), so this range cannot show this story's own
  # files at all and guessing here would be worse than the existing fallback.
  THIS_PULL_STRUCTURALLY_INERT=""
  # ga-9lug2k: reset alongside THIS_PULL_STRUCTURALLY_INERT, for the identical
  # leakage reason — MERGE_OWN_AFFECTED is only ever (re-)populated below, and
  # only on the Path-B (true no-op) branch. Without this reset, a story that
  # takes Path A (PRE!=POST) right after a sibling story that took Path B in
  # the SAME sweep would inherit the sibling's stale attribution: Path A sets
  # its own THIS_PULL_STRUCTURALLY_INERT (0 or 1) same as always, and the halt
  # builder below keys on THIS_PULL_STRUCTURALLY_INERT="0" plus a non-empty
  # MERGE_OWN_AFFECTED to decide whether to lead with it — a stale non-empty
  # value here would satisfy that check with the WRONG story's daemon list.
  MERGE_OWN_AFFECTED=""
  MERGE_OWN_VERDICT_LINE=""
  # ga-8i2nds: the raw per-story probe output is now read by the bead-scoped
  # halt detail further down, so it needs the same per-story reset as the two
  # variables above — otherwise a story that never runs the probe (unresolvable
  # MERGE_PRE_MAIN) would render the PREVIOUS story's probe output as its own.
  MERGE_OWN_OUT=""
  # ga-nuou9v: same leakage reason as MERGE_OWN_AFFECTED above — only set
  # when THIS_PULL_STRUCTURALLY_INERT is (re-)set to "1" below, on whichever
  # of Path A/Path B actually ran this iteration. Read (below) only where
  # THIS_PULL_STRUCTURALLY_INERT="1" is already known true, so a stale value
  # here could otherwise mislabel a DIFFERENT story's inert reason as this
  # one's.
  THIS_PULL_INERT_PREDICATE=""
  if [ -n "$PRE_DEPLOY_SHA" ] && [ "$PRE_DEPLOY_SHA" != "$POST_DEPLOY_SHA" ]; then
    THIS_PULL_CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null || true)"
    if [ -n "${THIS_PULL_CHANGED// /}" ]; then
      # Same universal claim as daemon-refresh.sh's own DEFAULT_NO_RESTART_PATTERNS
      # (ga-dk7fw): tests/**, docs/**, *.md are never part of any daemon's
      # import graph on any rig. Deliberately duplicated as a literal here
      # (not sourced from daemon-refresh.sh) — this whole Step 5b block is
      # extracted verbatim by tests/story-delivery-step5b.test.sh, so a cross-
      # file reference would not resolve in that context. Keep the pattern
      # list in sync if daemon-refresh.sh's ever changes.
      this_pull_no_restart_patterns="tests/** docs/** *.md"
      this_pull_uncovered=""
      set -f
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        covered=0
        for pat in $this_pull_no_restart_patterns; do
          # shellcheck disable=SC2254  # deliberate glob match, not literal
          case "$f" in $pat) covered=1; break ;; esac
        done
        [ "$covered" -eq 1 ] || this_pull_uncovered="$this_pull_uncovered $f"
      done <<< "$THIS_PULL_CHANGED"
      set +f
      if [ -z "${this_pull_uncovered// /}" ]; then
        THIS_PULL_STRUCTURALLY_INERT=1
        THIS_PULL_INERT_PREDICATE="tests/docs/md-only"
      else
        THIS_PULL_STRUCTURALLY_INERT=0
      fi
    fi
  fi
  # ga-ndu4ic: the block above (Path A: THIS iteration's own pull moved HEAD,
  # PRE_DEPLOY_SHA != POST_DEPLOY_SHA) only proves whether ITS OWN pull's
  # PRE..POST window is tests/docs/md-only — and that window is NOT scoped to
  # this story alone whenever more than one merge lands in the same pull
  # cycle (routine in this city, ~90 commits/day). The block below used to
  # run ONLY as an `elif` — i.e. ONLY on Path B (PRE_DEPLOY_SHA==
  # POST_DEPLOY_SHA, a true no-op pull) — so the one genuinely story-scoped
  # probe (MERGE_PRE_MAIN..MERGE_SHA: exactly this story's own commits,
  # however many, regardless of what else got pulled alongside them) NEVER
  # ran on Path A, the more common case. Every per-bead OWN-attribution and
  # baseline-advance-on-exoneration mechanism below (ga-49fwiw/ga-g63ejg/
  # ga-87solq) silently never engaged for it as a result — confirmed live:
  # wa-vbsm5.1 (2026-09-18 22:0x, ga-ndu4ic) took Path B by coincidence and
  # WAS correctly narrowed to demand-dashboard alone, but the identical shape
  # on Path A (the common case) falls straight to the wide-list-only,
  # unattributed halt below, blaming the reporting story for every daemon
  # ANY delivery left stuck since the baseline last advanced. Run this probe
  # whenever MERGE_SHA/MERGE_PRE_MAIN resolve validly, UNCONDITIONALLY (an
  # `if`, not an `elif` off the block above) — its result, when parseable, is
  # always at least as accurate as the pattern check above (scoped to exactly
  # this story's own commits; the pattern check's PRE..POST window is not),
  # so it OVERRIDES THIS_PULL_STRUCTURALLY_INERT/MERGE_OWN_AFFECTED whenever
  # it successfully runs — on EITHER path.
  if [ -n "$MERGE_SHA" ] \
     && [ -n "$MERGE_PRE_MAIN" ] \
     && MERGE_OWN_BASE_SHA="$(git -C "$RUNTIME_DIR" rev-parse --verify -q "$MERGE_PRE_MAIN" 2>/dev/null)" \
     && [ -n "$MERGE_OWN_BASE_SHA" ] \
     && git -C "$RUNTIME_DIR" merge-base --is-ancestor "$MERGE_OWN_BASE_SHA" "$MERGE_SHA" 2>/dev/null; then
    # ga-6zkhci: on Path B (PRE_DEPLOY_SHA==POST_DEPLOY_SHA, a true no-op
    # pull — ga-gokm6's scenario: something else, a sibling story's delivery
    # earlier in the same sweep or a crew's own post-merge fast-forward,
    # already advanced RUNTIME_DIR's HEAD past this story's merge before
    # PRE_DEPLOY_SHA was captured above), the pattern check above never even
    # runs (its own PRE==POST window is empty) — this story's own delta still
    # has a real, known diff regardless of what the pull did, IF we know the
    # right base to diff from. Confirmed live (story-delivery.log
    # 2026-09-14): wa-ibaqq (docs/mockups/*.html only) and wa-mjpjs
    # (scripts/lib files no daemon imports) were both held on exactly this
    # gap — THIS_PULL_STRUCTURALLY_INERT stayed unset, so the case statement
    # below fell to blame/hold for staleness neither one caused. (ga-ndu4ic:
    # this probe now ALSO runs on Path A, for the identical reason — see the
    # comment above this block.)
    #
    # fix-attempt-2 (gate_run ga-u0gc14) used MERGE_SHA^ (the parent commit)
    # as that base and got it wrong: quality-gate-dispatcher.sh's direct_ff
    # merge always fast-forward-pushes the WHOLE branch, never squashes, so
    # MERGE_SHA^ is only the true pre-story baseline on a single-commit
    # branch — and every gate fix-attempt adds a commit, making multi-commit
    # branches the common case, not the exception. On this very branch,
    # MERGE_SHA^ resolved to fix-attempt-2's OWN commit, completely missing
    # fix-attempt-1's 323-line diff — the actual bulk of this feature.
    #
    # Mayor decision (ga-6zkhci, 2026-09-15): the correct base is
    # MERGE_PRE_MAIN — main's real tip immediately before the push that
    # landed this merge, persisted by quality-gate-dispatcher.sh into its own
    # PASSED comment (MAIN_HEAD_SHA at push time) and parsed above by
    # extract_gate_merge_pre_main. Never trust it blindly: verify it both
    # resolves to a real object in RUNTIME_DIR AND is an actual ancestor of
    # MERGE_SHA before using it as a diff base (an unresolvable or
    # non-ancestor value — corrupted comment, force-pushed history, a merge
    # from before this field existed — is the THIRD STATE: this whole if's
    # condition then evaluates false, THIS_PULL_STRUCTURALLY_INERT is left
    # exactly as the Path-A pattern check above set it (or stays unset, on
    # Path B with nothing to fall back on), and the existing blame/hold
    # behavior below applies exactly as it did before this fix. Never fall
    # back to guessing MERGE_SHA^ or any other substitute — an unrecorded
    # base means UNKNOWN, not "assume single commit".
    #
    # Ask daemon-refresh.sh itself — DRY_RUN=1 hardcoded (never the outer
    # $DRY_RUN): this is a pure classification probe on a delta that has
    # nothing to do with what the caller's own deploy is doing, so it must
    # never kickstart or drain anything for real — whether THIS story's own
    # delta alone (MERGE_PRE_MAIN..MERGE_SHA, i.e. every commit this story's
    # branch actually added, however many there are) reaches any live daemon.
    # This reuses the exact same import/template-closure discovery Step 3
    # (below) already trusts for the wide window, instead of re-deriving a
    # second, weaker heuristic here: the tests/docs/md pattern above is
    # deliberately NOT extended to cover cases like wa-mjpjs's scripts/*.py —
    # daemon-refresh.sh's own header point 9 explains why a static pattern
    # can't safely cover arbitrary .py files, since whether one is reachable
    # from any daemon depends on the rig's actual import graph, not its path.
    #
    # Bounded with `timeout 180`: measured live against this rig's real
    # daemon roster (ga-6zkhci), a call that can't short-circuit on a
    # tests/docs/md-only delta (i.e. one that reaches Step 2/3's live
    # launchctl/ps discovery across every declared daemon) took ~98s
    # wall-clock. A single slow-or-hung probe here must not stall every OTHER
    # story queued behind this one in the same sweep; a timeout is treated
    # the same as any other unparseable result below — fails closed to the
    # existing blame behavior, never guesses an exemption.
    #
    # Read AFFECTED, never VERDICT, to decide inert-ness. Under DRY_RUN=1,
    # daemon-refresh.sh reports VERDICT=OK for a daemon it WOULD have
    # restarted (WOULD_RESTART branch) exactly as readily as for one that
    # reaches nothing at all — it never actually kickstarts or verify_fresh()s
    # under dry-run, so "OK" here cannot distinguish "this story's files touch
    # no live daemon" from "this story's files touch a live daemon that a REAL
    # run might fail to bring back fresh". AFFECTED is populated by Step 3's
    # import/template-closure discovery alone, before any restart is
    # attempted — empty means no live daemon is reachable from this story's
    # own delta at all (the only claim this probe needs to make); non-empty
    # means it is, regardless of how a real restart of it would have gone.
    #
    # wa-xokje: AFFECTED alone conflates two very different cases — reaching
    # a LIVE daemon (may genuinely need a human's guarded restart) vs
    # reaching ONLY a scheduled/one-shot job with no live PID right now
    # (daemon-refresh.sh's own Step 4 already never kickstarts these — see
    # its "not currently running" branch — because doing so would wrongly
    # TRIGGER a one-shot job, and because such a job needs no restart at all:
    # it will pick up the new code on its own, automatically, whenever
    # launchd next fires it). Before this fix, a story whose own delta only
    # touched a scheduled job's entrypoint (e.g.
    # scripts/detect_unloaded_committed_daemons.py, consumed solely by the
    # daily com.whatsapp.unloaded-daemons-full-daily job) was wrongly treated
    # as "not inert" and held/retried every sweep forever — no amount of
    # retrying could ever change that outcome (confirmed live: wa-bpbgp,
    # numerically identical HALT output across 2h+ of 5-minute retries).
    # AFFECTED_NOT_RUNNING (daemon-refresh.sh, same probe call) names the
    # subset of AFFECTED with no live PID; subtract it here so inertness is
    # decided on AFFECTED_LIVE — reachability into a live daemon only. A
    # story that ALSO reaches a real live daemon (the common, mixed case)
    # still correctly stays "not inert" below: subtracting a self-healing
    # scheduled job never empties a set that also contains a live daemon.
    MERGE_OWN_OUT=$(RUNTIME_DIR="$RUNTIME_DIR" \
      PRE_DEPLOY_SHA="$MERGE_OWN_BASE_SHA" POST_DEPLOY_SHA="$MERGE_SHA" \
      DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
      EXTRA_RUNTIME_ROOTS="$EXTRA_RUNTIME_ROOTS" \
      DRY_RUN=1 \
      timeout 180 bash "$REFRESH_HELPER" 2>/dev/null || true)
    MERGE_OWN_VERDICT_LINE=$(echo "$MERGE_OWN_OUT" | grep '^VERDICT=' | head -1 || true)
    MERGE_OWN_AFFECTED=$(echo "$MERGE_OWN_OUT" | grep '^AFFECTED=' | head -1 | sed 's/^AFFECTED=//' || true)
    MERGE_OWN_AFFECTED_NOT_RUNNING=$(echo "$MERGE_OWN_OUT" | grep '^AFFECTED_NOT_RUNNING=' | head -1 | sed 's/^AFFECTED_NOT_RUNNING=//' || true)
    MERGE_OWN_AFFECTED_LIVE=""
    for _moa in $MERGE_OWN_AFFECTED; do
      case " $MERGE_OWN_AFFECTED_NOT_RUNNING " in
        *" $_moa "*) ;;  # no live PID (scheduled/one-shot) — self-heals, never held for this
        *) MERGE_OWN_AFFECTED_LIVE="$MERGE_OWN_AFFECTED_LIVE $_moa" ;;
      esac
    done
    log "Per-story attribution probe (this-iteration-pull pre=$PRE_DEPLOY_SHA post=$POST_DEPLOY_SHA) — asked daemon-refresh.sh (DRY_RUN=1, no real kickstart/drain) whether $STORY_ID's own merge $MERGE_SHA alone (vs pre-merge-main base $MERGE_OWN_BASE_SHA) reaches any live daemon: ${MERGE_OWN_VERDICT_LINE:-<unparseable output>} affected=[$MERGE_OWN_AFFECTED] affected_not_running=[$MERGE_OWN_AFFECTED_NOT_RUNNING] affected_live=[$MERGE_OWN_AFFECTED_LIVE]."
    if [ -z "$MERGE_OWN_VERDICT_LINE" ]; then
      : # unparseable helper output (crash/timeout) — leave THIS_PULL_STRUCTURALLY_INERT/MERGE_OWN_AFFECTED exactly as the Path-A pattern check (if it ran) already set them; existing blame fallback applies either way
    elif [ "$MERGE_OWN_VERDICT_LINE" = "VERDICT=JOB_NOT_INSTALLED" ]; then
      # ga-nuou9v (wa-s5fux): a job this bead's own merge added/touched that
      # is missing from launchd or present-but-not-loaded can NEVER self-heal
      # via "next scheduled run" — daemon-refresh.sh never runs a job launchd
      # doesn't know about. AFFECTED_NOT_RUNNING's "no live PID" test cannot
      # tell that apart from a legitimately-installed scheduled job with no
      # live PID right now (both have no PID, for opposite reasons), so never
      # let the AFFECTED_LIVE subtraction below decide inert-ness once
      # daemon-refresh.sh has already told us, by name, which case this is.
      THIS_PULL_STRUCTURALLY_INERT=0
    elif [ -z "${MERGE_OWN_AFFECTED_LIVE// /}" ]; then
      THIS_PULL_STRUCTURALLY_INERT=1
      THIS_PULL_INERT_PREDICATE="confirmed to reach no live daemon"
    else
      THIS_PULL_STRUCTURALLY_INERT=0
    fi
  fi
  log "Daemon refresh: pre=$DAEMON_REFRESH_PRE_SHA post=$POST_DEPLOY_SHA (this-pull-pre=$PRE_DEPLOY_SHA) this-pull-structurally-inert=${THIS_PULL_STRUCTURALLY_INERT:-unknown} sensitive='$SENSITIVE_DAEMONS' extra_roots='$EXTRA_RUNTIME_ROOTS' ..."
  # ga-xz3ypu: pass this bead's own merge range through so daemon-refresh.sh's
  # Step 1b (ga-agracx) can tell "this bead's own plist" apart from "some
  # other bead's plist" — same BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA convention
  # quality-gate-dispatcher.sh's own call site already uses (its
  # MERGE_PRE_MAIN_SHA/MERGE_SHA are this file's MERGE_PRE_MAIN/MERGE_SHA).
  # Neither call site here ever set these before, so Step 1b's attribution
  # guard always took its "unknown" branch — which defaults to attributable —
  # for every story-delivery.sh-driven deploy (wa-a7tca/wa-8urdy, 2026-09-17).
  # Deliberately NOT MERGE_OWN_BASE_SHA (assigned in the `if` above): that var
  # is only assigned when this story's MERGE_PRE_MAIN resolves and is an
  # ancestor of MERGE_SHA (ga-ndu4ic made that `if` run on Path A too, so it is
  # no longer Path-B-only). When it does NOT, the var is either never assigned
  # (an unbound-variable abort under this file's `set -euo pipefail`) or still
  # holds a PREVIOUS story's value from the same sweep. Every later use of it —
  # the freshness re-probe and the bead-scoped halt (ga-8i2nds) — is therefore
  # gated on MERGE_OWN_AFFECTED being non-empty: reset per story above, and
  # only ever populated inside that same `if`.
  # MERGE_SHA/MERGE_PRE_MAIN are always defined (defaulted "" earlier in the
  # sweep loop), and by this point MERGE_VERDICT=="verified" is guaranteed
  # (the pre-deploy merge-verification HALT above already `continue`d
  # otherwise). daemon-refresh.sh's own guard independently re-verifies
  # non-empty/distinct/ancestor before trusting either value, so an empty or
  # stale MERGE_PRE_MAIN here can only ever fall back to today's existing
  # (safe) attribute-by-default behavior — never misattribute.
  REFRESH_OUT=$(RUNTIME_DIR="$RUNTIME_DIR" \
    PRE_DEPLOY_SHA="$DAEMON_REFRESH_PRE_SHA" POST_DEPLOY_SHA="$POST_DEPLOY_SHA" \
    DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
    EXTRA_RUNTIME_ROOTS="$EXTRA_RUNTIME_ROOTS" \
    DAEMON_BASELINE_OVERRIDES="$DAEMON_BASELINE_OVERRIDES" \
    BEAD_MERGE_PRE_SHA="${MERGE_PRE_MAIN:-}" BEAD_MERGE_SHA="${MERGE_SHA:-}" \
    DRY_RUN="$DRY_RUN" \
    bash "$REFRESH_HELPER" || true)
  # ga-rugqks: the daemon-refresh subprocess just above is the one step in
  # this loop documented to take up to 6.5-10 minutes per cycle (see
  # task_reconciler_gate_passed_too_fresh's header, wa-n27z0) — long enough
  # for someone to close this exact bead (independently verified delivered)
  # while this call was in flight. Re-check fresh, right where the real
  # incident's own timestamps land, before acting on a verdict that no
  # longer matters to anyone.
  if story_bead_closed_now "$STORY_STORE" "$STORY_ID"; then
    log "Story $STORY_ID was closed while daemon-refresh was in flight — skipping verdict handling, no mutation."
    continue
  fi
  REFRESH_VERDICT=$(echo "$REFRESH_OUT" | grep '^VERDICT=' | head -1 | sed 's/^VERDICT=//')
  REFRESH_REASON=$(echo  "$REFRESH_OUT" | grep '^REASON='  | head -1 | sed 's/^REASON=//')
  REFRESH_RESTARTED=$(echo "$REFRESH_OUT" | grep '^RESTARTED=' | head -1 | sed 's/^RESTARTED=//')
  REFRESH_GUARDED=$(echo "$REFRESH_OUT" | grep '^GUARDED=' | head -1 | sed 's/^GUARDED=//')
  # ga-87solq: GUARDED_OWN (wa-flysp, header point 16) is the subset of
  # REFRESH_GUARDED whose OWN entrypoint/template changed — CLOSURE_ONLY
  # members are "known noise" per this file's own REFRESH_ACTION text below,
  # yet the NEEDS_GUARDED_RESTART_UNATTRIBUTED check further down used to
  # intersect against the full combined REFRESH_GUARDED, so a story whose
  # own delta only ever closure-reaches a stuck daemon could never be
  # exonerated. Measured live: every story since the baseline froze at
  # 8cb99239 (9h+/51 commits, 8 manual unblocks) reached a wide, closure-
  # contaminated guarded set via a shared file (e.g. daemons/deploy_deps.json
  # regeneration touching dozens of daemons' recorded closures) — the
  # intersection was never empty, so the rig-wide marker never advanced.
  # Absent line (older daemon-refresh.sh predating this field) falls back to
  # the full combined list — never assume "nothing own-file stuck" when the
  # split simply is not available; a present-but-empty line means the split
  # ran and genuinely found no own-file-changed member, which IS trustworthy.
  REFRESH_GUARDED_OWN_LINE=$(echo "$REFRESH_OUT" | grep '^GUARDED_OWN=' | head -1 || true)
  if [ -n "$REFRESH_GUARDED_OWN_LINE" ]; then
    REFRESH_GUARDED_OWN=$(echo "$REFRESH_GUARDED_OWN_LINE" | sed 's/^GUARDED_OWN=//')
  else
    REFRESH_GUARDED_OWN="$REFRESH_GUARDED"
  fi
  REFRESH_FRESHFAIL=$(echo "$REFRESH_OUT" | grep '^FRESH_FAIL=' | head -1 | sed 's/^FRESH_FAIL=//')
  # ga-0fawwr: every label this cycle's discovery examined — may be genuinely
  # absent (an older daemon-refresh.sh predating this field, same hazard the
  # PROOF field below already guards against), so `|| true` here for the same
  # reason: under this script's `set -euo pipefail`, an unmatched grep piped
  # into head/sed still propagates a non-zero pipeline status and would kill
  # the whole sweep otherwise. Empty is the safe fallback either way — the
  # write-back block further below simply does nothing without it.
  REFRESH_ALL_LABELS=$(echo "$REFRESH_OUT" | grep '^ALL_LABELS=' | head -1 | sed 's/^ALL_LABELS=//' || true)
  # ga-vmq1i: PROOF disambiguates a positive restart+fresh confirmation from a
  # VERDICT=OK/SKIPPED that never actually confirmed anything live — fail
  # closed to not_verified if the helper's output predates this field or is
  # otherwise unparseable. Unlike VERDICT/REASON/etc. above (always emitted,
  # so their grep always matches), PROOF may be genuinely absent (an older
  # daemon-refresh.sh, or a mid-window deploy of one without the other) — under
  # this script's `set -euo pipefail`, an unmatched grep piped into head/sed
  # still propagates a non-zero pipeline status and kills the whole sweep, so
  # the fallback below needs `|| true` here to ever be reached.
  REFRESH_PROOF=$(echo "$REFRESH_OUT" | grep '^PROOF=' | head -1 | sed 's/^PROOF=//' || true)
  [ -n "$REFRESH_PROOF" ] || REFRESH_PROOF="not_verified"
  log "Daemon refresh verdict=$REFRESH_VERDICT restarted=[$REFRESH_RESTARTED] guarded=[$REFRESH_GUARDED] freshfail=[$REFRESH_FRESHFAIL] proof=$REFRESH_PROOF reason=$REFRESH_REASON"
  # ga-0fawwr: per-daemon baseline bookkeeping — independent of the rig-wide
  # OK|SKIPPED gate below, which starves for days whenever even ONE daemon
  # stays guarded (see daemon-refresh.sh's own comment on
  # DAEMON_BASELINE_OVERRIDES, at its point of use, for the full incident).
  # REFRESH_ALL_LABELS is every daemon this cycle's discovery actually
  # examined (empty on every early short-circuit — nothing ran, nothing to
  # record). Each label ends in exactly one of three states, and only the
  # first may move its baseline forward:
  #   clean   — examined and not left in GUARDED or FRESH_FAIL: resolved as of
  #             POST_DEPLOY_SHA (never affected at all, or affected-and-
  #             restarted-and-verified), so its OWN baseline is advanced
  #             regardless of what any OTHER daemon on the same rig is still
  #             stuck on. One extra condition applies ONLY to a label whose
  #             recorded entry is flagged stuck: it is clean only if this
  #             cycle's wide window starts at or before that entry (else it is
  #             "unknown", below). An older UNFLAGGED entry advances
  #             unconditionally — the pre-ga-7polxu behaviour; nothing here
  #             checks that the window covers it.
  #   stuck   — left in GUARDED or FRESH_FAIL: FROZEN, never advanced and never
  #             dropped (ga-7polxu). It keeps its existing entry when that is
  #             a real commit reachable from POST_DEPLOY_SHA (its last
  #             known-clean point), otherwise it gets the effective PRE this
  #             cycle's helper run was measured against. Written as
  #             "<label> <sha> stuck". Until ga-7polxu this branch wrote
  #             nothing AND the carry-forward below skipped every examined
  #             label, so a stuck label's previous entry was thrown away and a
  #             first-time one never got one — while this comment said the
  #             label was "simply left untouched".
  #   unknown — flagged stuck earlier, not flagged now, but this cycle's wide
  #             window starts AFTER its entry (the rig-wide marker moved past
  #             it — e.g. the unattributed release below): nothing looked at
  #             that stretch, so "not flagged" means "not looked at", never
  #             "clean". The entry is kept as it was.
  # What these entries are FOR is easy to over-read: they keep each label's own
  # last-known-clean point, and daemon-refresh.sh only ever NARROWS the wide
  # window with them (an entry strictly between the rig-wide PRE and POST can
  # drop a label out of AFFECTED; it never adds one and ignores an entry older
  # than PRE). A frozen entry therefore does NOT keep its label in the wide
  # list once the rig-wide marker has moved past it — see the note at the
  # unattributed release below. It is a record of what was LAST SEEN
  # unresolved, and since when, instead of an erasure — not a live status: once
  # the marker is past an entry nothing re-examines that label, so a daemon
  # restarted afterwards is not cleared from it (ga-n2jnsa).
  # PD_RECORDED / PD_WROTE: what this cycle REALLY wrote, for the release log
  # below — initialised here, ahead of every branch that can skip the write
  # (DRY_RUN, an untouched file), because that log reads them under set -u.
  PD_RECORDED=" "
  PD_WROTE=0
  PD_STUCK=" "
  for pd_label in $REFRESH_GUARDED $REFRESH_FRESHFAIL; do
    case "$PD_STUCK" in *" $pd_label "*) ;; *) PD_STUCK="${PD_STUCK}${pd_label} " ;; esac
  done
  # Two "the input never said" states that must NOT read as "nothing is stuck" or
  # "nothing is recorded" — either would let a stuck label advance as clean, or a
  # flagged record be rewritten from an empty read. In both the file is left
  # exactly as it was (the inert answer) and this cycle warns just below:
  #  - no GUARDED= LINE in the helper's output (crash, kill mid-print): a missing
  #    line is not an empty one. Tested on the text, not by piping into grep -q:
  #    under pipefail the writer takes SIGPIPE when grep -q exits early.
  #    (Under this script's own set -e the REFRESH_GUARDED= parse further up has
  #    no `|| true` — deliberately: a missing line must not become an EMPTY
  #    guarded list, which the release below would read as "nothing guarded". So
  #    a missing line normally aborts the sweep before it reaches here: loud, and
  #    nothing is written. This test keeps the file inert on any path where that
  #    parse survives.)
  #  - the per-daemon file exists but cannot be read.
  PD_SKIP_WHY=""
  case $'\n'"$REFRESH_OUT" in *$'\n'GUARDED=*) ;; *) PD_SKIP_WHY="the helper printed no GUARDED= line" ;; esac
  PERDAEMON_OLD=""
  if [ -e "$DAEMON_REFRESH_PERDAEMON_FILE" ]; then
    PERDAEMON_OLD="$(cat "$DAEMON_REFRESH_PERDAEMON_FILE" 2>/dev/null)" || PD_SKIP_WHY="the per-daemon file exists but could not be read"
  fi
  # pd_commit_state <sha>: "ok" = a real commit reachable from POST_DEPLOY_SHA;
  # "bad" = positively not one (not a full 40-hex id, no such commit, not an
  # ancestor); "unknown" = git could not say (a broken checkout, a signal — any
  # exit but a plain yes/no). Only "bad" may replace a recorded baseline.
  # rev-parse --verify -q exits 1 for an absent commit and 128 for a broken
  # repository; cat-file -e exits 128 for both, so it cannot tell them apart.
  pd_commit_state() {
    local pd_rc=0
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] || { echo bad; return 0; }
    git -C "$RUNTIME_DIR" rev-parse --verify -q "${1}^{commit}" >/dev/null 2>&1 || pd_rc=$?
    case "$pd_rc" in 0) ;; 1) echo bad; return 0 ;; *) echo unknown; return 0 ;; esac
    pd_rc=0
    git -C "$RUNTIME_DIR" merge-base --is-ancestor "$1" "$POST_DEPLOY_SHA" >/dev/null 2>&1 || pd_rc=$?
    case "$pd_rc" in 0) echo ok ;; 1) echo bad ;; *) echo unknown ;; esac
  }
  if [ "$DRY_RUN" != "1" ] && [ -n "$POST_DEPLOY_SHA" ] && [ -n "${REFRESH_ALL_LABELS// /}" ] && [ -n "$PD_SKIP_WHY" ]; then
    warn "per-daemon baseline for rig $RIG left untouched this cycle: $PD_SKIP_WHY (unknown is not clean; ga-7polxu)"
  fi
  if [ "$DRY_RUN" != "1" ] && [ -n "$POST_DEPLOY_SHA" ] && [ -n "${REFRESH_ALL_LABELS// /}" ] && [ -z "$PD_SKIP_WHY" ]; then
    PERDAEMON_NEW=""
    # labels whose recorded entry already carries the stuck flag — the file is
    # ~200 lines and almost no label is ever flagged, so a per-label lookup
    # happens only for a label that can be in this set or in PD_STUCK.
    PD_FLAGGED=" $(printf '%s\n' "$PERDAEMON_OLD" | awk '$3=="stuck"{printf "%s ", $1}')"
    # carry forward every existing entry NOT examined this cycle untouched
    # (flag included) — a rig can have daemons this run's discovery didn't see
    # (e.g. a plist parse error) whose own last-known baseline must not be
    # silently dropped. A stuck label is written by the loop below whether or
    # not discovery listed it, so it is skipped here to stay one line per label.
    if [ -n "$PERDAEMON_OLD" ]; then
      while IFS=' ' read -r pd_label pd_rest; do
        [ -n "$pd_label" ] || continue
        case " $REFRESH_ALL_LABELS " in *" $pd_label "*) continue ;; esac
        case "$PD_STUCK" in *" $pd_label "*) continue ;; esac
        PERDAEMON_NEW="${PERDAEMON_NEW}${pd_label} ${pd_rest}"$'\n'
      done <<< "$PERDAEMON_OLD"
    fi
    PD_SEEN=" "
    for pd_label in $REFRESH_ALL_LABELS $PD_STUCK; do
      case "$PD_SEEN" in *" $pd_label "*) continue ;; esac
      PD_SEEN="${PD_SEEN}${pd_label} "
      pd_old_sha=""
      # The lookup reads the WHOLE file — no awk `exit`. This is an assignment
      # under set -e + pipefail: an early-exit reader closes the pipe while printf
      # is still writing the ~15 KB variable, the writer takes SIGPIPE (rc 141),
      # the pipeline reports 141 and errexit kills the whole sweep — once per stuck
      # label, so 41 stuck daemons make it likely (ga-7polxu gate review: 11 of 12
      # sweeps at incident scale aborted, 0 of 12 on base). The value captured is
      # right either way; it is the STATUS that kills. Duplicate labels: the first
      # line wins, as before.
      case "$PD_STUCK$PD_FLAGGED" in
        *" $pd_label "*) pd_old_sha="$(printf '%s\n' "$PERDAEMON_OLD" | awk -v l="$pd_label" '$1==l && !d{print $2; d=1}')" ;;
      esac
      case "$PD_STUCK" in
        *" $pd_label "*)
          # stuck: frozen — the existing entry if it is a real commit reachable
          # from POST_DEPLOY_SHA, or if git cannot say (an entry older than PRE
          # is kept too: it is the truthful "unresolved since", and the
          # consumer ignores it), else the effective PRE. Nothing usable at all
          # (PRE unknown): write no entry rather than invent one — the label
          # then has none, as before.
          pd_frozen="$DAEMON_REFRESH_PRE_SHA"
          if [ -n "$pd_old_sha" ]; then
            # "unknown" keeps the recorded entry too: git failing to answer is
            # not evidence the entry is wrong, and replacing it would move a
            # recorded baseline on a guess.
            case "$(pd_commit_state "$pd_old_sha")" in ok|unknown) pd_frozen="$pd_old_sha" ;; esac
          fi
          if [ -n "$pd_frozen" ]; then
            PERDAEMON_NEW="${PERDAEMON_NEW}${pd_label} ${pd_frozen} stuck"$'\n'
            PD_RECORDED="${PD_RECORDED}${pd_label} "
          fi
          continue
          ;;
      esac
      case "$PD_FLAGGED" in
        *" $pd_label "*)
          # flagged earlier, not flagged now: clean only when this cycle's wide
          # window starts at or before the entry (PRE is an ancestor-or-equal
          # of it). Not covered, or git unable to say (PRE unknown, any exit but
          # a plain yes/no), means the window did not look at that stretch: the
          # entry stays exactly as it was. Only an entry that is POSITIVELY not
          # a commit reachable from POST_DEPLOY_SHA carries no information and
          # is replaced like any other — "git could not say" must not be read as
          # "invalid", or a transient failure would turn a stuck record into a
          # clean one.
          if [ -n "$pd_old_sha" ]; then
            pd_keep=0
            case "$(pd_commit_state "$pd_old_sha")" in
              unknown) pd_keep=1 ;;
              ok)
                pd_rc=2
                if [ -n "$DAEMON_REFRESH_PRE_SHA" ]; then
                  pd_rc=0
                  git -C "$RUNTIME_DIR" merge-base --is-ancestor "$DAEMON_REFRESH_PRE_SHA" "$pd_old_sha" >/dev/null 2>&1 || pd_rc=$?
                fi
                [ "$pd_rc" = "0" ] || pd_keep=1
                ;;
            esac
            if [ "$pd_keep" = "1" ]; then
              PERDAEMON_NEW="${PERDAEMON_NEW}${pd_label} ${pd_old_sha} stuck"$'\n'
              continue
            fi
          fi
          ;;
      esac
      PERDAEMON_NEW="${PERDAEMON_NEW}${pd_label} ${POST_DEPLOY_SHA}"$'\n'
    done
    if printf '%s' "$PERDAEMON_NEW" > "$DAEMON_REFRESH_PERDAEMON_FILE" 2>/dev/null; then
      PD_WROTE=1
    else
      warn "could not persist per-daemon baseline for rig $RIG at $DAEMON_REFRESH_PERDAEMON_FILE (non-fatal; next sweep falls back to the rig-wide marker for every label)"
    fi
  fi
  case "$REFRESH_VERDICT" in
    OK|SKIPPED)
      if [ -n "${REFRESH_RESTARTED// /}" ]; then
        log "Refreshed + verified live: $REFRESH_RESTARTED"
      fi
      # ga-gokm6: this deploy's code is now confirmed examined (checked-and-
      # clean, or genuinely nothing changed since the LAST marker — never
      # "this iteration's own pull happened to be a no-op"). Advance the
      # per-rig marker so the NEXT sweep's baseline starts here, not at
      # whatever this iteration's own pre-pull HEAD was. Skip on DRY_RUN
      # (no side effects) and when POST_DEPLOY_SHA is unknown (non-git
      # runtime — nothing to persist).
      if [ "$DRY_RUN" != "1" ] && [ -n "$POST_DEPLOY_SHA" ]; then
        printf '%s\n' "$POST_DEPLOY_SHA" > "$DAEMON_REFRESH_BASELINE_FILE" 2>/dev/null \
          || warn "could not persist daemon-refresh baseline for rig $RIG at $DAEMON_REFRESH_BASELINE_FILE (non-fatal; next sweep falls back to its own pre-pull HEAD)"
      fi
      ;;
    *)
      # ga-49fwiw: for NEEDS_GUARDED_RESTART specifically, THIS_PULL_STRUCTURALLY_
      # INERT alone is too coarse a filter — it only answers "does this bead's own
      # merge reach ANY live daemon", not "is any daemon it reaches among the ones
      # CURRENTLY still stuck in the wide-window GUARDED list". wa-a7tca's own
      # merge reached exactly one live daemon (com.whatsapp.demand-dashboard,
      # already restarted+verified 9min post-merge), so THIS_PULL_STRUCTURALLY_
      # INERT="0" (it IS reachable) — yet the whole delivery was held for ~6h on
      # account of 52 OTHER sensitive daemons stuck in the wide window for
      # unrelated reasons (no drain path, nobody restarts them every deploy).
      # Same fix shape as ga-xz3ypu (JOB_NOT_INSTALLED): attribute by
      # intersecting the CURRENT guarded set with what this bead's own merge
      # actually reaches ($MERGE_OWN_AFFECTED, already computed above) — no
      # new infrastructure, matches invariant (a).
      #
      # ga-87solq: intersect against REFRESH_GUARDED_OWN, not the full
      # REFRESH_GUARDED. A daemon this bead's delta only reaches via
      # transitively-changed imports (closure-only) is exactly the "known
      # noise" class REFRESH_ACTION's own CLOSURE-ONLY text already
      # disclaims below — it was never safe to treat as proof this bead
      # caused it, so it should never have been able to block exoneration
      # either. MERGE_OWN_AFFECTED itself is deliberately left as the raw,
      # unnarrowed reach (not similarly split into own/closure-only) —
      # conservative on purpose: this bead's own contribution being "closure-
      # only" toward a genuinely-own-file-stuck daemon does not prove this
      # bead is blameless for it, only the reverse (an own-file-stuck daemon
      # this bead cannot even closure-reach) does.
      NEEDS_GUARDED_RESTART_UNATTRIBUTED=0
      # ga-8i2nds: what the bead-scoped freshness re-probe concluded, so the
      # release branch and the halt builder below can each say which evidence
      # they rest on ("none" = it never ran for this story). Reset per story
      # for the usual sweep-loop leakage reason.
      BEAD_REPROBE_STATE="none"
      # ga-c3oyk6: the re-probe's own proof tier when (and only when) it came
      # back "clean" — what lets a release override the WIDE window's
      # PROOF=not_verified for THIS story (see the release branch below).
      BEAD_REPROBE_PROOF=""
      UNATTRIBUTED_ADVANCES_MARKER=0
      MERGE_OWN_WIDE_OVERLAP=""
      MERGE_OWN_FRESH_OUT=""
      MERGE_OWN_FRESH_VERDICT_LINE=""
      MERGE_OWN_FRESH_GUARDED_LINE=""
      MERGE_OWN_FRESH_PROOF=""
      MERGE_OWN_ARRIVAL_EPOCH=""
      MERGE_OWN_REPROBE_EPOCH=""
      MERGE_OWN_LIVE_STALE=""
      # ga-j3lh6p: what the helper proved about the still-stale set, reset per
      # story for the same sweep-loop leakage reason as the vars above. All empty
      # = "no split was made", which is exactly what an older helper gets.
      MERGE_OWN_FRESH_COSMETIC_LINE=""
      MERGE_OWN_FRESH_COSMETIC=""
      MERGE_OWN_ACTIONABLE_STALE=""
      MERGE_OWN_LOCKED_COSMETIC_STALE=""
      # ga-xrn8ni: a SIBLING of the two vars just above, same reset reason —
      # the daemon-refresh.sh subset excused via a missing $DRAIN_CMD_<label>
      # rather than restart_policy.yaml's notify_only_locked (extends
      # ga-j3lh6p to a SENSITIVE-but-not-locked daemon).
      MERGE_OWN_FRESH_NODRAIN_LINE=""
      MERGE_OWN_FRESH_NODRAIN=""
      MERGE_OWN_NODRAIN_COSMETIC_STALE=""
      if [ "$REFRESH_VERDICT" = "NEEDS_GUARDED_RESTART" ] \
         && [ "$THIS_PULL_STRUCTURALLY_INERT" = "0" ] \
         && [ -n "${MERGE_OWN_AFFECTED// /}" ]; then
        # ga-8i2nds: this branch used to run ONLY when the wide guarded set did
        # NOT overlap this bead's own reach — an overlap was taken as proof the
        # bead's daemon is stale and went straight to the hold. The wide sweep
        # does not measure that: daemon-refresh.sh's already_fresh() compares a
        # daemon's process start against the commit time of the wide window's
        # TIP (POST_DEPLOY_SHA), so a daemon restarted AFTER this bead's merge
        # but BEFORE some later, unrelated commit is reported stale for a
        # change it already runs. Measured live 2026-09-19 (rig baseline ~7h
        # behind): com.whatsapp.ficha360, restarted 08:25:07, was flagged for
        # wa-catpm — merge committed 08:08:44, in the runtime checkout from
        # 08:22:59, and its own diff really did touch ficha360 — so wa-catpm
        # was held; a read-only re-probe of that merge against the live
        # processes came back VERDICT=OK, all 5 reached daemons already fresh.
        # (wa-ben95, held for the same ficha360 flag, is a REAL hold: the same
        # re-probe finds com.whatsapp.clientes-dashboard older than its merge —
        # which is exactly why the re-probe decides, not the wide flag.)
        # The question a hold has to answer is "does a daemon THIS merge
        # reaches still run code older than THIS merge", and this re-probe
        # answers exactly that, overlap or not — so it decides in both cases,
        # and ITS stale list (never the wide list) is what a hold reports.
        # The overlap only changes what a release does with the rig-wide
        # marker (see the release branch below).
        #
        # Known tolerance (inherited from ga-g63ejg, not introduced here):
        # "fresh" is pid-start > the merge COMMIT's time, a LOWER bound on when
        # the code reached the runtime checkout (wa-catpm: 14min later). A
        # daemon restarted inside that gap would read fresh while still running
        # pre-merge code. Closing it means flooring the reference at the
        # checkout-arrival time inside daemon-refresh.sh — a separate change.
        MERGE_OWN_WIDE_OVERLAP="$(comm -12 \
              <(echo "$REFRESH_GUARDED_OWN" | tr ' ' '\n' | grep -v '^$' | sort -u) \
              <(echo "$MERGE_OWN_AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u) \
              | tr '\n' ' ' | sed 's/ $//')"
        # ga-g63ejg: an empty intersection with REFRESH_GUARDED_OWN only proves
        # this bead's own affected daemon(s) are off the WIDE sweep's radar —
        # never that they are actually fresh. The wide sweep's own [PRE,POST]
        # window can advance past this bead's merge without the daemon it
        # touches ever being independently re-examined or restarted (e.g. an
        # EARLIER bead's own unattributed branch, right below, moves the
        # rig-wide marker straight to ITS OWN POST_DEPLOY_SHA regardless of
        # what other files landed in the same range) — so a daemon whose only
        # changed file was THIS bead's own merge can permanently drop off
        # REFRESH_GUARDED_OWN without ever being confirmed fresh. Live: wa-
        # xn0w0 was closed story:done while com.whatsapp.map-viewer was still
        # confirmed serving the pre-merge JS bundle 7min after this exact
        # branch logged "not holding this delivery for it" and exonerated.
        #
        # Re-probe this bead's own AFFECTED set directly: force every label in
        # it through daemon-refresh.sh's SENSITIVE already_fresh() check
        # (pid-start-epoch vs. this bead's own commit, $MERGE_SHA) regardless
        # of the rig's real sensitive/safe classification. A SAFE daemon's
        # normal DRY_RUN=1 path never runs this check (it always reports
        # WOULD_RESTART — real-restart semantics don't need to know whether a
        # restart is actually needed, since kickstarting a SAFE daemon for
        # real is harmless either way), which is exactly why the ORIGINAL
        # MERGE_OWN_OUT probe above cannot answer "is it stale RIGHT NOW" for
        # one. Same DRY_RUN=1 contract as MERGE_OWN_OUT — never kickstarts or
        # drains anything for real, a pure live-process snapshot check.
        # ga-c3oyk6: the re-probe's "verified" bar is pid-start > DEPLOY_EPOCH —
        # this iteration's start. On a RETRY that bar is later than the moment
        # the merge really reached the runtime, so a daemon the operator
        # restarted in between (the normal hold -> restart -> retry flow) could
        # only ever score the weaker commit-time correlation tier, and the
        # release below then inherited the WIDE window's PROOF=not_verified
        # (Step 8: delivery:daemon-unverified, "may still be dormant") with the
        # bead-scoped probe having just answered VERDICT=OK still-stale=[]
        # (wa-0n0bj, 2026-09-20). Floor the probe at the merge's arrival in the
        # runtime checkout instead. That does make "verified" reachable for a
        # daemon started between the arrival and DEPLOY_EPOCH — the intent: it
        # started after the code was in the checkout, and DEPLOY_EPOCH was only
        # ever a conservative upper bound on that moment. It never goes below
        # the arrival, and only ever LOWERS the floor: a later or unprovable
        # arrival keeps DEPLOY_EPOCH, and a respawn between the merge's commit
        # time and its arrival (old code still checked out) stays not_verified.
        MERGE_OWN_ARRIVAL_EPOCH="$(runtime_arrival_epoch "$RUNTIME_DIR" "$MERGE_SHA" || true)"
        MERGE_OWN_REPROBE_EPOCH="$DEPLOY_EPOCH"
        case "$MERGE_OWN_ARRIVAL_EPOCH" in
          ''|*[!0-9]*) MERGE_OWN_ARRIVAL_EPOCH="" ;;
          *)
            if [ "$MERGE_OWN_ARRIVAL_EPOCH" -lt "$DEPLOY_EPOCH" ]; then
              MERGE_OWN_REPROBE_EPOCH="$MERGE_OWN_ARRIVAL_EPOCH"
            fi
            ;;
        esac
        MERGE_OWN_FRESH_OUT=$(RUNTIME_DIR="$RUNTIME_DIR" \
          PRE_DEPLOY_SHA="$MERGE_OWN_BASE_SHA" POST_DEPLOY_SHA="$MERGE_SHA" \
          DEPLOY_EPOCH="$MERGE_OWN_REPROBE_EPOCH" \
          SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS $MERGE_OWN_AFFECTED" \
          EXTRA_RUNTIME_ROOTS="$EXTRA_RUNTIME_ROOTS" \
          DRY_RUN=1 \
          timeout 180 bash "$REFRESH_HELPER" 2>/dev/null || true)
        MERGE_OWN_FRESH_VERDICT_LINE=$(echo "$MERGE_OWN_FRESH_OUT" | grep '^VERDICT=' | head -1 || true)
        # ga-8i2nds (third-state audit): keep the GUARDED= LINE itself, not only
        # its value. A verdict with NO GUARDED= line at all is "the re-probe did
        # not say", and must not read as "GUARDED is empty, nothing is stale".
        # daemon-refresh.sh's emit() prints VERDICT= first and GUARDED= some
        # fifteen lines later, so a truncated/partial output is exactly this
        # shape — and an overlap used to force a hold before this read decided
        # anything, so the release it can now cause has to rest on positive
        # evidence.
        MERGE_OWN_FRESH_GUARDED_LINE=$(echo "$MERGE_OWN_FRESH_OUT" | grep '^GUARDED=' | head -1 || true)
        MERGE_OWN_LIVE_STALE=$(echo "$MERGE_OWN_FRESH_OUT" | grep '^GUARDED=' | head -1 | sed 's/^GUARDED=//' || true)
        # ga-c3oyk6: the probe's OWN proof tier ("verified" only when every reached
        # daemon's pid-start cleared the floor above). Absent line = "did not say".
        MERGE_OWN_FRESH_PROOF=$(echo "$MERGE_OWN_FRESH_OUT" | grep '^PROOF=' | head -1 | sed 's/^PROOF=//' || true)
        # ga-j3lh6p: the still-stale labels daemon-refresh.sh proved BOTH locked
        # against automation (restart_policy.yaml notify_only_locked) AND cleanly
        # without a call-graph path to any symbol this merge's own delta changed
        # (its header point 19). Keep the LINE, not only its value: a helper that
        # predates the field prints none, and "did not say" must never be read as
        # an answer in either direction — here it simply means no split is made.
        MERGE_OWN_FRESH_COSMETIC_LINE=$(echo "$MERGE_OWN_FRESH_OUT" | grep '^GUARDED_LOCKED_COSMETIC=' | head -1 || true)
        MERGE_OWN_FRESH_COSMETIC=$(echo "$MERGE_OWN_FRESH_COSMETIC_LINE" | sed 's/^GUARDED_LOCKED_COSMETIC=//')
        # ga-xrn8ni: a SIBLING read, same reasoning as the pair just above but
        # for daemon-refresh.sh's GUARDED_NODRAIN_COSMETIC (extends ga-j3lh6p
        # to a SENSITIVE daemon excused via a missing $DRAIN_CMD_<label>
        # rather than restart_policy.yaml's notify_only_locked).
        MERGE_OWN_FRESH_NODRAIN_LINE=$(echo "$MERGE_OWN_FRESH_OUT" | grep '^GUARDED_NODRAIN_COSMETIC=' | head -1 || true)
        MERGE_OWN_FRESH_NODRAIN=$(echo "$MERGE_OWN_FRESH_NODRAIN_LINE" | sed 's/^GUARDED_NODRAIN_COSMETIC=//')
        log "Freshness re-probe for $STORY_ID's own affected daemon(s) [$MERGE_OWN_AFFECTED] (forced through the SENSITIVE already_fresh() check): ${MERGE_OWN_FRESH_VERDICT_LINE:-<unparseable output>} still-stale=[$MERGE_OWN_LIVE_STALE] proof=${MERGE_OWN_FRESH_PROOF:-none} (freshness floor $MERGE_OWN_REPROBE_EPOCH: merge arrived in the runtime at ${MERGE_OWN_ARRIVAL_EPOCH:-unknown}, this deploy started $DEPLOY_EPOCH)."
        # Three states, and only the first one releases:
        #   clean       — the re-probe printed BOTH a VERDICT= and a GUARDED= line,
        #                 the verdict is exactly VERDICT=OK, and GUARDED is empty:
        #                 positive evidence nothing this merge reaches is stale.
        #                 In this mode (DRY_RUN=1, every reached label forced
        #                 through the SENSITIVE already_fresh() check) the helper
        #                 has exactly two healthy outputs: VERDICT=OK over an empty
        #                 GUARDED (all fresh) and VERDICT=NEEDS_GUARDED_RESTART
        #                 over a named list (some stale). Every OTHER verdict —
        #                 JOB_NOT_INSTALLED (a scheduled job this delivery ships
        #                 never ran: the wa-s5fux incident, held by every other
        #                 read of this verdict in this file), VERIFY_FAILED,
        #                 SKIPPED — leaves GUARDED empty too, and that emptiness
        #                 is NOT evidence of freshness.
        #   stale       — it NAMED the still-stale daemons (GUARDED non-empty).
        #   unparseable — anything else: no VERDICT, no GUARDED= line, a verdict
        #                 other than OK over an empty list, or a
        #                 NEEDS_GUARDED_RESTART that contradicts its own empty
        #                 list. "The re-probe did not say" — held, never read as
        #                 fresh.
        if [ "$MERGE_OWN_FRESH_VERDICT_LINE" = "VERDICT=OK" ] \
           && [ -n "$MERGE_OWN_FRESH_GUARDED_LINE" ] \
           && [ -z "${MERGE_OWN_LIVE_STALE// /}" ]; then
          NEEDS_GUARDED_RESTART_UNATTRIBUTED=1
          BEAD_REPROBE_STATE="clean"
          BEAD_REPROBE_PROOF="$MERGE_OWN_FRESH_PROOF"
          # Only the pre-existing exoneration (no overlap with the wide guarded
          # set, ga-49fwiw invariant c) advances the rig-wide marker. An
          # overlap-exoneration (ga-8i2nds) must NOT: the marker is the PRE of
          # every later wide window, so moving it to POST_DEPLOY_SHA drops any
          # still-pending sibling's merge out of its own next window — that
          # sibling's wide verdict then reads SKIPPED/OK on an empty range and
          # its own stale daemons are never looked at again. This branch's
          # evidence is about THIS merge only, so it releases THIS story only.
          if [ -z "$MERGE_OWN_WIDE_OVERLAP" ]; then
            UNATTRIBUTED_ADVANCES_MARKER=1
          fi
        elif [ -n "$MERGE_OWN_FRESH_VERDICT_LINE" ] && [ -n "${MERGE_OWN_LIVE_STALE// /}" ]; then
          BEAD_REPROBE_STATE="stale"
          # ga-j3lh6p: split the still-stale set into what a human / guarded
          # restart can act on and what daemon-refresh.sh proved LOCKED against
          # every automation AND without a call-graph path to any symbol this
          # merge changed — staleness that is cosmetic and can never self-heal
          # (wa-z66jb, wa-ho1ol 20/09: held forever, closed by hand each time).
          # Eligibility is deliberately narrow, and every "no" defaults to the
          # hold this file has always made:
          #   - only a re-probe verdict of EXACTLY NEEDS_GUARDED_RESTART: a
          #     JOB_NOT_INSTALLED that also lists a guarded label is a job that
          #     never ran, and no symbol split can excuse that;
          #   - only when the helper printed the GUARDED_LOCKED_COSMETIC line at
          #     all (an older helper gets no split — absent != empty);
          #   - positive membership per label: a stale label the helper did not
          #     NAME stays actionable. An empty line names nothing, so nothing is
          #     excused; a name that is not stale excuses nothing.
          # A locked daemon whose symbol IS reached (SYMBOL-CONFIRMED), was never
          # computed, or was flagged by a partial analysis is never named by the
          # helper, so it can never reach this split: this is NOT "ignore
          # notify_only_locked".
          MERGE_OWN_ACTIONABLE_STALE="$MERGE_OWN_LIVE_STALE"
          # ga-xrn8ni: the trigger now also fires when the helper printed
          # GUARDED_NODRAIN_COSMETIC (extends ga-j3lh6p's split to a SENSITIVE
          # daemon excused via a missing $DRAIN_CMD_<label>, not just a
          # notify_only_locked one) — either line alone is enough to attempt
          # the split; a stale label not named by EITHER stays actionable.
          if [ "$MERGE_OWN_FRESH_VERDICT_LINE" = "VERDICT=NEEDS_GUARDED_RESTART" ] \
             && { [ -n "$MERGE_OWN_FRESH_COSMETIC_LINE" ] || [ -n "$MERGE_OWN_FRESH_NODRAIN_LINE" ]; }; then
            MERGE_OWN_ACTIONABLE_STALE=""
            for _sl in $MERGE_OWN_LIVE_STALE; do
              case " $MERGE_OWN_FRESH_COSMETIC " in
                *" $_sl "*) MERGE_OWN_LOCKED_COSMETIC_STALE="$MERGE_OWN_LOCKED_COSMETIC_STALE $_sl"; continue ;;
              esac
              case " $MERGE_OWN_FRESH_NODRAIN " in
                *" $_sl "*) MERGE_OWN_NODRAIN_COSMETIC_STALE="$MERGE_OWN_NODRAIN_COSMETIC_STALE $_sl"; continue ;;
              esac
              MERGE_OWN_ACTIONABLE_STALE="$MERGE_OWN_ACTIONABLE_STALE $_sl"
            done
            MERGE_OWN_ACTIONABLE_STALE="$(echo "$MERGE_OWN_ACTIONABLE_STALE" | tr -s ' ' | sed 's/^ //; s/ $//')"
            MERGE_OWN_LOCKED_COSMETIC_STALE="$(echo "$MERGE_OWN_LOCKED_COSMETIC_STALE" | tr -s ' ' | sed 's/^ //; s/ $//')"
            MERGE_OWN_NODRAIN_COSMETIC_STALE="$(echo "$MERGE_OWN_NODRAIN_COSMETIC_STALE" | tr -s ' ' | sed 's/^ //; s/ $//')"
            if [ -z "${MERGE_OWN_ACTIONABLE_STALE// /}" ]; then
              BEAD_REPROBE_STATE="locked-cosmetic"
            fi
          fi
          if [ "$BEAD_REPROBE_STATE" = "locked-cosmetic" ]; then
            # ga-xrn8ni: name only the reason(s) that actually apply — never
            # assert "notify_only_locked" for a daemon exonerated purely via
            # the no-drain-configured set (a human checking restart_policy.yaml
            # for it would find nothing, and rightly distrust the message).
            COSMETIC_WHY=""
            [ -n "${MERGE_OWN_LOCKED_COSMETIC_STALE// /}" ] && COSMETIC_WHY="${COSMETIC_WHY}[$MERGE_OWN_LOCKED_COSMETIC_STALE] notify_only_locked; "
            [ -n "${MERGE_OWN_NODRAIN_COSMETIC_STALE// /}" ] && COSMETIC_WHY="${COSMETIC_WHY}[$MERGE_OWN_NODRAIN_COSMETIC_STALE] SENSITIVE with no \$DRAIN_CMD_<label> configured; "
            log "Daemon refresh verdict=$REFRESH_VERDICT — $STORY_ID's own merge reaches [$MERGE_OWN_AFFECTED]; the freshness re-probe confirms [$MERGE_OWN_LIVE_STALE] still run code older than the merge commit ($MERGE_SHA), but EVERY one of them is either locked against automation or lacks a drain path (${COSMETIC_WHY%; }) AND has no call-graph path to any symbol this merge changed ($MERGE_OWN_BASE_SHA..$MERGE_SHA) — cosmetic staleness that can never self-heal; NOT holding this delivery for it (ga-j3lh6p / ga-xrn8ni; wide-window overlap: [${MERGE_OWN_WIDE_OVERLAP:-none}])."
          else
            log "Daemon refresh verdict=$REFRESH_VERDICT — $STORY_ID's own merge reaches [$MERGE_OWN_AFFECTED]; the freshness re-probe confirms [$MERGE_OWN_LIVE_STALE] still run code older than the merge commit ($MERGE_SHA) — holding this delivery for exactly those (wide-window overlap: [${MERGE_OWN_WIDE_OVERLAP:-none}])."
          fi
        else
          BEAD_REPROBE_STATE="unparseable"
          # Third state (unparseable re-probe: no VERDICT= line at all,
          # crash/timeout, no GUARDED= line, a verdict other than OK over an
          # empty list, or a NEEDS_GUARDED_RESTART that contradicts its own
          # empty list) is deliberately NOT treated as fresh — same
          # fail-closed default this file uses everywhere else for "can't
          # tell" (verify-before-completion's own rule: if we can't tell,
          # don't release). NEEDS_GUARDED_RESTART_UNATTRIBUTED stays 0, so
          # control falls through to the hold branch below. The log names
          # what the re-probe actually returned, so an operator reading a
          # hold can tell "it crashed" from "it said JOB_NOT_INSTALLED".
          log "Daemon refresh verdict=$REFRESH_VERDICT — $STORY_ID's own merge reaches [$MERGE_OWN_AFFECTED], but the freshness re-probe did not confirm it fresh (no consistent VERDICT/GUARDED pair in its output — got [${MERGE_OWN_FRESH_VERDICT_LINE:-no VERDICT line}] / [${MERGE_OWN_FRESH_GUARDED_LINE:-no GUARDED= line}]; only VERDICT=OK over an empty GUARDED= counts as fresh) — holding this delivery for it (ga-g63ejg: absence from the wide sweep's list does not prove fresh; wide-window overlap: [${MERGE_OWN_WIDE_OVERLAP:-none}])."
        fi
      fi
      if [ "$THIS_PULL_STRUCTURALLY_INERT" = "1" ]; then
        # ga-3bdttu: verdict is real (some daemon IS stale) but this story's
        # own merge did not cause it (its own delta is tests/docs/md-only) —
        # do not blame/hold/withhold story:done for it. Fall through to Step 6
        # as if this step passed. Deliberately do NOT advance the baseline
        # marker above (that only happens in the OK|SKIPPED case): the
        # underlying staleness is real and still unresolved for whichever
        # earlier commit actually caused it, and advancing the marker here
        # would hide it from every future sweep too, not just this story.
        log "Daemon refresh verdict=$REFRESH_VERDICT ($REFRESH_REASON) predates $STORY_ID's own merge (its own delta is ${THIS_PULL_INERT_PREDICATE:-tests/docs/md-only}) — not holding this delivery for it."
        if [ "$DRY_RUN" != "1" ]; then
          gc --city "$GC_CITY" session nudge mayor \
            "Daemon refresh $REFRESH_VERDICT persists for rig $RIG ($REFRESH_REASON) — NOT caused by $STORY_ID, whose own merge is ${THIS_PULL_INERT_PREDICATE:-tests/docs/md-only}; an earlier commit still needs a guarded restart." \
            2>/dev/null || true
        fi
      elif [ "$NEEDS_GUARDED_RESTART_UNATTRIBUTED" = "1" ]; then
        # ga-49fwiw: this bead's own merge DOES reach a live daemon (not
        # structurally inert), but NONE of the daemon(s) currently stuck in
        # NEEDS_GUARDED_RESTART belong to this bead — invariant (b): the wide
        # window stays visible and charged (nudge below), but does not retain
        # whoever didn't cause it.
        #
        # ga-c3oyk6: this story is released on the bead-scoped re-probe's OWN
        # evidence, so its daemon-liveness PROOF has to come from that probe,
        # not from the WIDE window it was just exonerated from. REFRESH_PROOF is
        # still the window's here (always not_verified under NEEDS_GUARDED_
        # RESTART) and Step 8 keys delivery:daemon-unverified + "may still be
        # dormant" off it — contradicting the probe that just found every daemon
        # this merge reaches running code newer than the merge (wa-0n0bj,
        # 2026-09-20: labelled 11s after "VERDICT=OK still-stale=[]"). Only the
        # strongest answer counts: proof=verified over VERDICT=OK and an empty
        # GUARDED (BEAD_REPROBE_STATE=clean), i.e. every running daemon reached
        # started after the merge landed. Anything weaker — the not_verified
        # correlation tier, not_applicable, a missing PROOF line — leaves the
        # window's fail-closed value in place. Per story: REFRESH_PROOF is reset
        # for each one (above), and from here on only Step 8 reads it.
        if [ "$BEAD_REPROBE_STATE" = "clean" ] && [ "$BEAD_REPROBE_PROOF" = "verified" ]; then
          log "Daemon refresh: $STORY_ID's daemon-liveness proof is bead-scoped — the freshness re-probe says proof=verified (every running daemon its merge reaches [$MERGE_OWN_AFFECTED] started after the merge landed in the runtime; floor $MERGE_OWN_REPROBE_EPOCH), overriding the wide window's proof=$REFRESH_PROOF for this story only."
          REFRESH_PROOF="verified"
        fi
        if [ -n "$MERGE_OWN_WIDE_OVERLAP" ]; then
          # ga-8i2nds: released on the bead-scoped re-probe even though the wide
          # window names daemon(s) this merge reaches — see the comment at the
          # re-probe above for why that wide flag is not evidence about THIS
          # merge. The wide names that overlap are kept in the log/nudge (they
          # are the reason a reader would otherwise suspect this release).
          log "Daemon refresh verdict=$REFRESH_VERDICT — the wide window flags [$MERGE_OWN_WIDE_OVERLAP], which $STORY_ID's own merge reaches, but the freshness re-probe finds none of the daemons it reaches [$MERGE_OWN_AFFECTED] still running code older than its merge commit ($MERGE_SHA); the wide flag is measured against the window tip ($POST_DEPLOY_SHA), not this merge — not holding this delivery for it. Rig-wide baseline marker left where it is (ga-8i2nds: a pending sibling's window must not be skipped)."
        else
          log "Daemon refresh verdict=$REFRESH_VERDICT — none of the currently-guarded daemon(s) ($REFRESH_GUARDED) are attributed to $STORY_ID's own merge (which reaches: $MERGE_OWN_AFFECTED) — not holding this delivery for it."
        fi
        if [ "$DRY_RUN" != "1" ]; then
          if [ -n "$MERGE_OWN_WIDE_OVERLAP" ]; then
            gc --city "$GC_CITY" session nudge mayor \
              "Daemon refresh $REFRESH_VERDICT persists for rig $RIG — $STORY_ID released on its own evidence: the wide window flags [$MERGE_OWN_WIDE_OVERLAP] (which its merge reaches), but none of the daemons its merge reaches [$MERGE_OWN_AFFECTED] still runs code older than the merge commit ($MERGE_SHA). The wide flag is judged against the window tip, not this merge; another commit may still need a guarded restart." \
              2>/dev/null || true
          else
            gc --city "$GC_CITY" session nudge mayor \
              "Daemon refresh $REFRESH_VERDICT persists for rig $RIG — NOT attributed to $STORY_ID (its own merge reaches [$MERGE_OWN_AFFECTED], none currently in the guarded list [$REFRESH_GUARDED]); an earlier commit still needs a guarded restart." \
              2>/dev/null || true
          fi
          # ga-49fwiw invariant (c): unlike the pre-existing inert branch above
          # (deliberately left un-advanced — see its own comment), THIS branch
          # DOES advance the rig-wide marker: this bead's own portion of the
          # wide window is fully examined (MERGE_OWN_AFFECTED is non-empty and
          # every daemon it reaches is confirmed NOT in the current guarded
          # set). Only the self-feeding wide-window growth this bug's own
          # root-cause section describes (verdict never OK -> marker never
          # advances -> window widens -> more daemons match -> verdict never
          # OK) stops.
          #
          # ga-7polxu — what this advance does NOT protect, said plainly
          # because this comment used to claim the opposite ("any daemon still
          # genuinely stuck keeps its OWN per-daemon override baseline frozen
          # regardless ... so nothing is hidden from a future sweep"). It did
          # not: the per-daemon block above discarded a stuck label's entry
          # (measured 2026-09-20 on whatsapp_automation: 41 guarded, 0 of them
          # recorded, marker advanced, wide list 41 -> 5, nobody restarted
          # anything). It now RECORDS each one ("<label> <sha> stuck") — but the
          # only reader of that file, daemon-refresh.sh, merely narrows a
          # label's window between the rig-wide PRE and POST: it never adds a
          # label and ignores an entry older than PRE. So a still-stuck daemon
          # DOES drop out of the next wide window when the line below moves the
          # marker past it; what survives is the frozen entry, the record of
          # what was last seen unresolved and since when (it is not cleared by a
          # later restart either — nothing re-examines the label). Making the wide list itself
          # stick to those labels needs a per-daemon freshness reference first:
          # already_fresh() measures a daemon's start against the window TIP,
          # so one restarted by hand reads stale as soon as any later commit
          # lands, and a held window could stay lit indefinitely — that is
          # ga-n2jnsa, deliberately not done here.
          #
          # ga-8i2nds: only when the exoneration was the no-overlap kind. A
          # release that rests on the bead-scoped re-probe DESPITE a wide
          # overlap (UNATTRIBUTED_ADVANCES_MARKER=0) proves nothing about the
          # rest of the window, so it leaves the marker alone.
          if [ "$UNATTRIBUTED_ADVANCES_MARKER" = "1" ] && [ -n "$POST_DEPLOY_SHA" ]; then
            if [ -n "${PD_STUCK// /}" ]; then
              pd_dropped="${PD_STUCK# }"; pd_dropped="${pd_dropped% }"
              # Claim a record only for the labels this cycle REALLY wrote one for.
              # The file may have been left untouched (PD_SKIP_WHY), the write may
              # have failed (PD_WROTE), or a label may have had nothing to freeze
              # (effective PRE unknown, no earlier entry): "each keeps ..." in any
              # of those cases is the promise-without-delivery this bead removes.
              pd_unrecorded=""
              for pd_ul in $PD_STUCK; do
                case " $PD_RECORDED " in
                  *" $pd_ul "*) [ "$PD_WROTE" = "1" ] || pd_unrecorded="${pd_unrecorded} ${pd_ul}" ;;
                  *) pd_unrecorded="${pd_unrecorded} ${pd_ul}" ;;
                esac
              done
              if [ -z "$pd_unrecorded" ]; then
                log "Daemon refresh: advancing the rig-wide baseline marker to $POST_DEPLOY_SHA drops the still-stuck daemon(s) [$pd_dropped] out of the next wide window. Each keeps a frozen 'stuck' baseline in $DAEMON_REFRESH_PERDAEMON_FILE — a record of what is unresolved and since when, not a re-flag: daemon-refresh.sh only narrows per-daemon baselines (ga-7polxu; making the list itself stick is ga-n2jnsa)."
              else
                log "Daemon refresh: advancing the rig-wide baseline marker to $POST_DEPLOY_SHA drops the still-stuck daemon(s) [$pd_dropped] out of the next wide window. NO frozen 'stuck' baseline was recorded for [${pd_unrecorded# }] this cycle (${PD_SKIP_WHY:-the per-daemon file was not rewritten, or the label had no baseline to freeze}): they leave no per-daemon record (ga-7polxu; making the list itself stick is ga-n2jnsa)."
              fi
            fi
            printf '%s\n' "$POST_DEPLOY_SHA" > "$DAEMON_REFRESH_BASELINE_FILE" 2>/dev/null \
              || warn "could not persist daemon-refresh baseline for rig $RIG at $DAEMON_REFRESH_BASELINE_FILE (non-fatal; next sweep falls back to its own pre-pull HEAD)"
          fi
        fi
      elif [ "$BEAD_REPROBE_STATE" = "locked-cosmetic" ]; then
        # ga-j3lh6p: this merge DOES reach daemon(s) still running pre-merge code,
        # and every one of them is locked against all automation AND has no
        # call-graph path to a symbol this merge changed. Holding would hold
        # FOREVER — nothing can ever restart them (wa-z66jb, wa-ho1ol 20/09:
        # delivery:deploy-pending permanent, closed by hand after ~20min of
        # investigation each) — so the delivery proceeds to Step 6, with the
        # reason RECORDED on the bead, where it can be audited and disproved.
        # The proof tier says what was actually established: not "verified"
        # (nothing was restarted; the daemon really is still stale) and not the
        # generic "not_verified" either (we DID check, and the analysis says the
        # merged code is not dormant there). One value for both would put "could
        # not check" and "checked, judged not needed" in the same label — Step 8
        # gives this tier its own label and its own wording, the way
        # asset_served_per_request does for a policy-proven safe change.
        # Deliberately does NOT advance the rig-wide baseline marker (ga-8i2nds:
        # this evidence is about THIS merge only, so it releases THIS story only;
        # moving the marker would drop a still-pending sibling's merge out of its
        # own next window).
        # ga-xrn8ni: two exoneration reasons can each cover a DISJOINT subset of
        # the still-stale set (a label is never in both — see the elif in the
        # split above). Pick the proof tier from whichever subset(s) are
        # non-empty; a mixed batch (both non-empty) tags as the newer,
        # less-run mechanism so it stays easy to find while it accrues
        # production mileage — the comment below still names BOTH reasons
        # precisely either way, never claiming one for a daemon it doesn't
        # cover.
        if [ -n "${MERGE_OWN_NODRAIN_COSMETIC_STALE// /}" ]; then
          REFRESH_PROOF="symbol_unreachable_nodrain"
        else
          REFRESH_PROOF="symbol_unreachable_locked"
        fi
        if [ "$DRY_RUN" != "1" ]; then
          COSMETIC_WHY_BODY=""
          if [ -n "${MERGE_OWN_LOCKED_COSMETIC_STALE// /}" ]; then
            COSMETIC_WHY_BODY="${COSMETIC_WHY_BODY}Daemon(s) still running pre-merge code, LOCKED against automation (ga-j3lh6p): $MERGE_OWN_LOCKED_COSMETIC_STALE
  Reason: notify_only_locked in restart_policy.yaml — no automation may restart it (a restart halts what it hosts, e.g. the outreach worker), so a hold on it could never clear by itself.
"
          fi
          if [ -n "${MERGE_OWN_NODRAIN_COSMETIC_STALE// /}" ]; then
            COSMETIC_WHY_BODY="${COSMETIC_WHY_BODY}Daemon(s) still running pre-merge code, SENSITIVE with NO DRAIN PATH configured (ga-xrn8ni): $MERGE_OWN_NODRAIN_COSMETIC_STALE
  Reason: no \$DRAIN_CMD_<label> is wired for it, so automation cannot drain in-flight work before restarting it — a configuration gap, not a deliberate policy lock, that changes the moment someone configures a drain command.
"
          fi
          bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery NOT held for a locked/no-drain daemon (ga-j3lh6p / ga-xrn8ni) — released on positive evidence, recorded here so it can be audited and disproved.
${COSMETIC_WHY_BODY}daemon-refresh.sh's symbol reachability, on this merge's own delta $MERGE_OWN_BASE_SHA..$MERGE_SHA, found NO call-graph path from either daemon's entrypoint to any symbol this merge changed. The analysis was cleanly evaluated — an unparseable entrypoint or a partial analysis would have been NOT COMPUTED and held.
LIMIT: 'no call-graph path' is evidence, not proof — a changed module-level constant read by an unchanged function, or a call chain the AST walk does not follow, is invisible to it. To check by hand: run compute_symbol_reachability.py --before $MERGE_OWN_BASE_SHA --after $MERGE_SHA for that daemon, or compare \`ps -o lstart= -p <pid>\` with the merge commit date. If a daemon DOES need the new code: restart a locked one only in a window where halting what it hosts is acceptable; restart a no-drain one by hand, or wire \$DRAIN_CMD_<label> so future deploys handle it automatically.
This delivery is recorded as proof=$REFRESH_PROOF — not as verified." 2>/dev/null || true
        fi
      else
        err "Daemon refresh did NOT pass (verdict=$REFRESH_VERDICT): $REFRESH_REASON"
        # ga-8i2nds: what the halt posts as its headline, its raw detail block
        # and its dedup key. Default = the wide sweep's own text, unchanged —
        # the right (and only honest) thing to show when this story has no
        # bead-scoped attribution. The bead-scoped branch below overrides all
        # three, because the wide REASON is a property of the WIDE WINDOW
        # (baseline..tip), identical for every story delivered while that
        # baseline stays put, and its wording ("its own entrypoint/template is
        # in THIS diff ... restart THESE first") reads as a claim about this
        # story's diff. Measured live 2026-09-19: wa-r4ehy.3's posted halt (diff:
        # slot_scheduler.py + queue_database.py) headlined a 36-daemon list and
        # told it com.whatsapp.ficha360 was OWN-FILE-CHANGED; the Mayor reported
        # the same list on wa-r4ehy.2, wa-catpm and wa-ben95 (ga-8i2nds).
        HALT_REASON="$REFRESH_REASON"
        HALT_DETAIL="$REFRESH_OUT"
        HALT_FP_LIST="$REFRESH_GUARDED"
        if [ "$REFRESH_VERDICT" = "NEEDS_GUARDED_RESTART" ]; then
          # ga-puq8z ACEITE 2: this verdict is single-hop import/template-closure
          # detection (daemon-refresh.sh Step 3), not proof the daemon's live
          # code path reaches the changed symbols — say so explicitly rather
          # than asserting staleness outright. daemon-refresh.sh's own
          # already-fresh check (COMMIT_EPOCH-based, ga-puq8z) already ran and
          # did NOT clear this daemon, but a human deciding whether to bounce a
          # hot-path daemon on this alone should know the detection basis.
          #
          # ga-9lug2k: lead with the per-bead attribution this block ALREADY
          # computed above (Path B / MERGE_OWN_*), reusing it instead of
          # making every reader re-derive it by hand. THIS_PULL_STRUCTURALLY_
          # INERT="0" is the only state that guarantees MERGE_OWN_AFFECTED is
          # both freshly set THIS iteration (reset above, ga-9lug2k) AND
          # non-empty (see the if/elif above: "1" means empty-and-inert,
          # unset/unknown means Path A ran instead, or the probe was
          # unparseable — neither carries a trustworthy attribution here).
          # Measured cost this fixes (wa-b26ju, wa-gyqzr, 2026-09-16): without
          # it, the ~50-daemon wide list was the ONLY thing a halt ever
          # showed, so every reader re-derived by hand what this script had
          # already computed a few lines above — ~30-60min each, twice in a
          # row, and in wa-gyqzr's case the wide list didn't even CONTAIN the
          # one daemon that actually needed restarting.
          if [ "$THIS_PULL_STRUCTURALLY_INERT" = "0" ] && [ -n "${MERGE_OWN_AFFECTED// /}" ]; then
            # gate_run=ga-c6ke4i (Reviewer-1 FAIL): the demoted line below used
            # to interpolate the raw $REFRESH_GUARDED wide list. Whenever a
            # narrow-attributed daemon was ALSO present in the wide sweep (the
            # common case — MERGE_PRE_MAIN..MERGE_SHA is normally a sub-range
            # of the wide baseline..POST window), that same daemon appeared
            # both in the lead "restart THESE for this merge" line and, two
            # lines later, in a line calling it "NOT attributed to this merge"
            # / "from EARLIER merges" — a self-contradiction. Subtract the
            # already-attributed set first, same set-difference shape as
            # SJ_FINE's fix for the identical contradiction class in
            # daemon-refresh.sh (gate_run=ga-3khhu).
            REFRESH_GUARDED_CONTEXT_ONLY="$(comm -23 \
              <(echo "$REFRESH_GUARDED" | tr ' ' '\n' | grep -v '^$' | sort -u) \
              <(echo "$MERGE_OWN_AFFECTED" | tr ' ' '\n' | grep -v '^$' | sort -u) \
              | tr '\n' ' ' | sed 's/ $//')"
            # ga-8i2nds: the halt lists ONLY this merge's own daemons. Which
            # ones depends on what the bead-scoped freshness re-probe (run
            # above, whether or not the wide list overlapped) concluded:
            #   stale       -> the daemons it confirmed still run pre-merge code
            #                  (started before this merge's commit) — the
            #                  precise "restart THESE" list, not the full reach
            #                  (a reached daemon restarted after the merge is
            #                  fresh and needs nothing);
            #   unparseable -> it could not say, so fall back to this merge's
            #                  full LIVE reach, worded as "not confirmed stale"
            #                  (fail closed: still held, never called fresh).
            # A hold never reaches this point in the "clean" state (released
            # above), so BEAD_REPROBE_STATE is "stale" or "unparseable" here —
            # or "none" if the re-probe somehow did not run, which is worded
            # exactly like unparseable rather than guessed at.
            # ga-j3lh6p: a still-stale daemon the helper proved locked against all
            # automation AND without a call-graph path to any symbol this merge
            # changed (MERGE_OWN_LOCKED_COSMETIC_STALE — set above only for a
            # NEEDS_GUARDED_RESTART re-probe that printed the field) stays out of
            # the "restart THESE" list: restarting it halts what it hosts (the
            # outreach worker) and buys nothing here, so telling a human to do it
            # is actively harmful advice. It is still NAMED, with the reason, on
            # its own line, so it cannot silently vanish from a hold — and once
            # the daemons that ARE actionable are handled, the next sweep's
            # re-probe re-checks everything that is left on the same evidence and
            # releases the story only if all of it still holds (a locked daemon
            # whose analysis came back NOT COMPUTED under load would hold again).
            HALT_LOCKED_NOTE=""; HALT_LOCKED_CLAUSE=""; HALT_NODRAIN_NOTE=""; HALT_NODRAIN_CLAUSE=""
            if [ "$BEAD_REPROBE_STATE" = "stale" ]; then
              HALT_OWN_LIST="$(echo "$MERGE_OWN_ACTIONABLE_STALE" | tr -s ' ' | sed 's/^ //; s/ $//')"
              if [ -n "${MERGE_OWN_LOCKED_COSMETIC_STALE// /}" ]; then
                HALT_LOCKED_NOTE=$'\n'"Not listed above: $MERGE_OWN_LOCKED_COSMETIC_STALE — notify_only_locked (no automation may restart it) and no call-graph path to any symbol this merge changed: cosmetic staleness. Do NOT restart it on this story's account — a restart halts what it hosts and buys nothing here. Once the daemon(s) above are handled, the next sweep re-checks this one on the same evidence and, only if it still holds, releases the story (ga-j3lh6p)."
                HALT_LOCKED_CLAUSE=" (plus $(echo "$MERGE_OWN_LOCKED_COSMETIC_STALE" | wc -w | tr -d ' ') more still on old code but locked with no call-graph path to a changed symbol — cosmetic, not listed: ga-j3lh6p)"
              fi
              # ga-xrn8ni: a SIBLING note/clause, same shape as the locked pair
              # just above but for a SENSITIVE daemon excused via a missing
              # $DRAIN_CMD_<label> instead of restart_policy.yaml.
              if [ -n "${MERGE_OWN_NODRAIN_COSMETIC_STALE// /}" ]; then
                HALT_NODRAIN_NOTE=$'\n'"Not listed above: $MERGE_OWN_NODRAIN_COSMETIC_STALE — SENSITIVE with no \$DRAIN_CMD_<label> configured (automation cannot drain it) and no call-graph path to any symbol this merge changed: cosmetic staleness. Do NOT restart it on this story's account on that basis alone — once the daemon(s) above are handled, the next sweep re-checks this one on the same evidence and, only if it still holds, releases the story (ga-xrn8ni, extends ga-j3lh6p)."
                HALT_NODRAIN_CLAUSE=" (plus $(echo "$MERGE_OWN_NODRAIN_COSMETIC_STALE" | wc -w | tr -d ' ') more still on old code but SENSITIVE with no drain path configured and no call-graph path to a changed symbol — cosmetic, not listed: ga-xrn8ni)"
              fi
              HALT_OWN_BASIS="the freshness re-probe found each of these started BEFORE this merge's commit $MERGE_SHA, i.e. still running pre-merge code"
            else
              HALT_OWN_LIST="$(echo "$MERGE_OWN_AFFECTED_LIVE" | tr -s ' ' | sed 's/^ //; s/ $//')"
              [ -n "$HALT_OWN_LIST" ] || HALT_OWN_LIST="$(echo "$MERGE_OWN_AFFECTED" | tr -s ' ' | sed 's/^ //; s/ $//')"
              HALT_OWN_BASIS="the freshness re-probe was unavailable, so this is the merge's full live reach — NOT confirmed stale"
            fi
            HALT_OWN_COUNT="$(echo "$HALT_OWN_LIST" | wc -w | tr -d ' ')"
            HALT_REACH_COUNT="$(echo "$MERGE_OWN_AFFECTED_LIVE" | wc -w | tr -d ' ')"
            HALT_CONTEXT_COUNT="$(echo "$REFRESH_GUARDED_CONTEXT_ONLY" | wc -w | tr -d ' ')"
            if [ "$BEAD_REPROBE_STATE" = "stale" ]; then
              HALT_REASON="this merge's own delta ($MERGE_OWN_BASE_SHA..$MERGE_SHA) reaches $HALT_REACH_COUNT live daemon(s); $HALT_OWN_COUNT of them still run code older than the merge: $HALT_OWN_LIST$HALT_LOCKED_CLAUSE$HALT_NODRAIN_CLAUSE"
            else
              HALT_REASON="this merge's own delta ($MERGE_OWN_BASE_SHA..$MERGE_SHA) reaches $HALT_REACH_COUNT live daemon(s), could not confirm which are stale (freshness re-probe unavailable): $HALT_OWN_LIST"
            fi
            # The raw block: this merge's own probe output, KEY=value lines
            # only (the wide run's stdout carries its whole discovery log —
            # hundreds of lines per comment, re-posted on every announce).
            # Prefer the re-probe (says which reached daemons are stale AND
            # which are already fresh), fall back to the plain probe.
            HALT_DETAIL_BODY="$(echo "${MERGE_OWN_FRESH_OUT:-$MERGE_OWN_OUT}" | grep -E '^(VERDICT|REASON|AFFECTED|AFFECTED_NOT_RUNNING|RESTARTED|FRESH_FAIL|GUARDED|GUARDED_OWN|GUARDED_CLOSURE_ONLY|GUARDED_SYMBOL_CONFIRMED|GUARDED_SYMBOL_NO_EVIDENCE|GUARDED_SYMBOL_NOT_COMPUTED|GUARDED_LOCKED_COSMETIC|ALREADY_FRESH|PROOF)=' || true)"
            # An empty body must not read as "the probe found nothing": say
            # that it produced nothing parseable (the third state).
            [ -n "$HALT_DETAIL_BODY" ] || HALT_DETAIL_BODY="(the bead-scoped probe produced no parseable KEY=value output — see story-delivery.log)"
            HALT_DETAIL="Bead-scoped detail — this merge's own delta $MERGE_OWN_BASE_SHA..$MERGE_SHA, NOT the rig-wide window:
$HALT_DETAIL_BODY"
            HALT_FP_LIST="$HALT_OWN_LIST"
            REFRESH_ACTION="ACTION: restart THESE for this merge — per-bead attribution ($STORY_ID's own delta $MERGE_OWN_BASE_SHA..$MERGE_SHA reaches them; $HALT_OWN_BASIS):$HALT_OWN_LIST
Drain in-flight messages/webhooks first, then re-run delivery. (Configure a DRAIN_CMD_<label> for daemon-refresh.sh to automate this.)${HALT_LOCKED_NOTE}${HALT_NODRAIN_NOTE}
Context only — NOT attributed to this merge: $HALT_CONTEXT_COUNT other sensitive daemon(s) flagged by the rig-wide window ($DAEMON_REFRESH_PRE_SHA..$POST_DEPLOY_SHA), which is judged against that window's tip commit, not this merge (cosmetic unless one of them actually uses a changed symbol; do not restart these on THIS story's account). Names deliberately omitted so this halt lists only this merge's own daemons (ga-8i2nds) — the full list is in story-delivery.log, the 'Daemon refresh verdict=' lines of this sweep.
CAVEAT (ga-puq8z): the list above is an import/template-closure match against this merge's own delta, not proof of reachability to the changed symbols — if in doubt, compare \`ps -o lstart= -p <pid>\` against this merge's commit $MERGE_SHA before restarting."
          else
            REFRESH_ACTION="ACTION: perform a guarded/graceful restart of the flagged hot-path daemon(s) ($REFRESH_GUARDED) — drain in-flight messages/webhooks first — then re-run delivery. (Configure a DRAIN_CMD_<label> for daemon-refresh.sh to automate this.) No per-bead attribution available this run (this story's own pull was not a true no-op, or the attribution probe above did not return a parseable result) — this is the wide sweep's list only. CAVEAT (ga-puq8z): flagged by import/template-closure matching, not proven reachable to the changed symbols — if in doubt, compare \`ps -o lstart= -p <pid>\` against commit $POST_DEPLOY_SHA before restarting."
          fi
        elif [ "$REFRESH_VERDICT" = "JOB_NOT_INSTALLED" ]; then
          # ga-nuou9v: same fix shape as quality-gate-dispatcher.sh's
          # DAEMON_HOLD_ACTION (ga-l7n3v) for the bug/task-merge flow — the
          # generic crash-oriented default below ("did not come up fresh")
          # does not fit this case at all: nothing ever ran, so say so and
          # name the actual remedy (install the job), not a restart.
          REFRESH_ACTION="ACTION: install the missing scheduled job(s) named in the reason above: copy the plist(s) into ~/Library/LaunchAgents and \`launchctl load\` (or \`launchctl bootstrap\`) them, then confirm \`launchctl list <label>\` succeeds. This verdict only proves the job is installed+loaded — NOT that a run has actually completed successfully (a job installed today may not reach its next scheduled window for hours) — so also wait for, or manually trigger via \`launchctl kickstart -k\`, one run and confirm a readable result lands in its log before re-running delivery."
        else
          REFRESH_ACTION="ACTION: investigate why the restarted daemon(s) ($REFRESH_FRESHFAIL) did not come up fresh (crash on boot? wrong launchd label? port in use?), fix forward, then re-run delivery."
        fi
        if [ "$DRY_RUN" != "1" ]; then
          bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
          bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
          # ga-iwv0: mark the DEPLOY-PENDING cause distinctly (code merged but NOT live — a
          # daemon needs a guarded restart / did not come up fresh). The task reconciler keys on
          # THIS label to re-arm story:approved (retry to real deploy), vs. a prod-test
          # delivery:failed which must NOT auto-retry (e.g. a flaky test → infinite loop).
          bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:deploy-pending" -q 2>/dev/null || true
          # wa-xokje: a HALT this cycle can be numerically IDENTICAL to the
          # last one — confirmed live (wa-bpbgp: same verdict + same GUARDED
          # set across 2h07 of 5-minute retries, "numeros IDENTICOS"). Nothing
          # about re-announcing an unchanged, already-reported condition every
          # single cycle helps anyone — it is exactly the "chronic condition
          # delivered as repeated acute alert" class this city already has a
          # name for (wa-bpbgp's own fix; the 'erro-vs-vazio' family
          # generally). Announce on first occurrence and on any real
          # transition (verdict, guarded set, or freshfail set changes);
          # stay quiet in between — except for a spaced reminder (ga-vv5ngy):
          # confirmed live that wa-xokje's dedup ALSO stayed silent past its
          # own fingerprint match on a bead that was never actually resolving
          # (wa-bpbgp again, ~1h after wa-xokje shipped), which is just as
          # unhelpful as spamming — "quiet" and "abandoned" must not look the
          # same to whoever is watching the bead. The retry/label mechanics
          # above are UNCHANGED: still retried every 5-minute sweep, still
          # story:approved, still recovers the instant the verdict changes.
          # Fails OPEN (always announce) if the fingerprint file can't be
          # read/written — never silently drops a genuinely NEW failure.
          HALT_FP_DIR="$GC_CITY/.gc/runtime/daemon-refresh-baseline/halt-fingerprint"
          mkdir -p "$HALT_FP_DIR" 2>/dev/null \
            || warn "could not create halt-fingerprint dir $HALT_FP_DIR for $STORY_ID (non-fatal; dedup fails open — will announce this cycle)"
          HALT_FP_FILE="$HALT_FP_DIR/$STORY_ID.txt"
          # ga-vv5ngy: line 1 is the dedup key (unchanged from wa-xokje:
          # verdict|guarded|freshfail); line 2 is the epoch this fingerprint
          # was last ANNOUNCED (not merely seen). Read the two lines
          # separately so a pre-ga-vv5ngy, wa-xokje-era file (fingerprint
          # only, no line 2) degrades to "timestamp unknown" rather than a
          # parse error — `sed -n Np` on a missing line prints nothing, it
          # does not fail.
          # ga-8i2nds: the list in the key is whatever the halt itself reports —
          # this merge's own stale daemons when it has bead-scoped attribution,
          # the wide guarded list otherwise (HALT_FP_LIST, set above). Keying on
          # the WIDE list while the comment shows the bead-scoped one would
          # re-announce on every unrelated change to the wide window and stay
          # silent when the bead's own list actually changed.
          HALT_FP_NEW="$REFRESH_VERDICT|$HALT_FP_LIST|$REFRESH_FRESHFAIL"
          HALT_FP_NOW="$(date +%s)"
          HALT_FP_OLD="$(sed -n '1p' "$HALT_FP_FILE" 2>/dev/null || echo "")"
          HALT_FP_OLD_TS="$(sed -n '2p' "$HALT_FP_FILE" 2>/dev/null || echo "")"
          case "$HALT_FP_OLD_TS" in ''|*[!0-9]*) HALT_FP_OLD_TS=0 ;; esac
          # Spaced reminder (ga-vv5ngy invariant b): an unresolved HALT that
          # never changes must not stay silent FOREVER just because it
          # matches the dedup key — that reads as "nothing is happening" to
          # whoever is watching the bead. Default once per day; overridable
          # (the halt-fingerprint-dedup hermetic tests set this low so the
          # reminder path is exercised without a real 24h wait).
          HALT_FP_REMINDER_INTERVAL_S="${HALT_FP_REMINDER_INTERVAL_S:-86400}"
          if [ -n "$HALT_FP_OLD" ] && [ "$HALT_FP_NEW" = "$HALT_FP_OLD" ]; then
            if [ "$HALT_FP_OLD_TS" -gt 0 ] && [ $(( HALT_FP_NOW - HALT_FP_OLD_TS )) -lt "$HALT_FP_REMINDER_INTERVAL_S" ]; then
              HALT_FP_MODE="silent"
            else
              HALT_FP_MODE="reminder"
            fi
          else
            HALT_FP_MODE="announce"
          fi
          if [ "$HALT_FP_MODE" = "silent" ]; then
            log "Daemon refresh HALT unchanged since last report for $STORY_ID (verdict=$REFRESH_VERDICT) — suppressing duplicate comment/nudge (still retrying every sweep)."
          else
            printf '%s\n%s\n' "$HALT_FP_NEW" "$HALT_FP_NOW" > "$HALT_FP_FILE" 2>/dev/null \
              || warn "could not persist halt-fingerprint for $STORY_ID at $HALT_FP_FILE (non-fatal; may re-announce next cycle)"
            if [ "$HALT_FP_MODE" = "reminder" ]; then
              # Invariant (c): never repeat the full daemon list past the
              # first announcement for this fingerprint — point back at it.
              bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED (ga-iwv0 daemon refresh) — STILL unresolved, unchanged since the last report: $REFRESH_VERDICT — $HALT_REASON
Not repeating the full daemon list here — see the earlier 'Delivery HALTED' comment on this bead for it (ga-vv5ngy spaced reminder: fires every ${HALT_FP_REMINDER_INTERVAL_S}s while the condition stays unchanged). story:done remains WITHHELD.
$REFRESH_ACTION" 2>/dev/null || true
              AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
              if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
                gc --city "$GC_CITY" session nudge "$AUTHOR" \
                  "DELIVERY still HALTED for $STORY_ID (ga-iwv0): $REFRESH_VERDICT — unchanged since last report. See bead; do NOT mark done." \
                  --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
              fi
              gc --city "$GC_CITY" session nudge mayor \
                "DELIVERY still HALTED ($STORY_ID, rig $RIG): daemon refresh $REFRESH_VERDICT unchanged since last report — $HALT_REASON. story:done withheld." \
                2>/dev/null || true
            else
              bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED (ga-iwv0 daemon refresh): $REFRESH_VERDICT — $HALT_REASON
A long-lived daemon serving rig '$RIG' is running code OLDER than this deploy and could not be safely refreshed/verified, so the merged feature would be DORMANT in production. story:done is WITHHELD (a dormant deploy must never be marked done).
$REFRESH_ACTION
Refresh detail:
$HALT_DETAIL" 2>/dev/null || true
              AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
              if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
                gc --city "$GC_CITY" session nudge "$AUTHOR" \
                  "DELIVERY HALTED for $STORY_ID (ga-iwv0): $REFRESH_VERDICT — a daemon serving the merge is dormant/unverified. See bead; do NOT mark done." \
                  --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
              fi
              gc --city "$GC_CITY" session nudge mayor \
                "DELIVERY HALTED ($STORY_ID, rig $RIG): daemon refresh $REFRESH_VERDICT — $HALT_REASON. story:done withheld." \
                2>/dev/null || true
            fi
          fi
        fi
        # wa-uthi: non-terminal (delivery:failed re-picked every cycle once the
        # daemon is refreshed) — no Athos push. Author + Mayor nudged above.
        warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID daemon refresh $REFRESH_VERDICT."
        continue
      fi
      ;;
  esac
fi

# ── Step 6: Run prod test ──────────────────────────────────────────────────────
# delivery:untested is now reserved for the SINGLE case NO_HARNESS=1 — the rig
# has no prod-test harness at all (ga-dqp interim). That case skips + warns
# (story:done with delivery:untested), never HALTs.
#
# ga-857v FIX 2: when the rig HAS a harness we ALWAYS run it (→ delivery:tested
# on pass). If the story-specific test is missing (STORY_TEST_MISSING=1) we run
# the rig BASELINE only, by invoking run.sh WITHOUT STORY_ID — every rig's run.sh
# runs its story-specific block solely when STORY_ID is set, so baseline mode can
# never hard-fail on an absent story test. Flow still never HALTs on a *missing*
# test; it only fails if the baseline finds genuinely broken prod (correct).
if [ "$NO_HARNESS" = "1" ]; then
  UNTESTED_REASON="rig '$RIG' has no prod-test harness"
  UNTESTED_FOLLOWUP="a real prod-test harness for rig '$RIG' is needed (ga-dqp DESTINY item)"
  warn "Skipping prod test — $UNTESTED_REASON (delivery:untested, ga-dqp interim). Flow never stops."
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD SKIP PROD TEST ($UNTESTED_REASON); WOULD SET delivery:untested (no NTFY — terminal-only push policy wa-uthi)"
  else
    bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:untested" -q 2>/dev/null || true
    bd -C "$STORY_STORE" comment "$STORY_ID" "WARNING: prod test skipped — $UNTESTED_REASON.
Story is being marked story:done with delivery:untested label.
FOLLOW-UP: $UNTESTED_FOLLOWUP." 2>/dev/null || true
    # wa-uthi: NO push here. "delivery:untested" is a non-terminal warning; the
    # single terminal push fires at story:done (Step 8). Mid-flow warnings are
    # suppressed so Athos only gets pushed on terminal outcomes.
  fi
else
  # Rig HAS a harness → run it. Baseline-only (no STORY_ID) when the
  # story-specific test is absent; full (with STORY_ID) when it exists.
  if [ "$STORY_TEST_MISSING" = "1" ]; then
    TEST_STORY_ID=""
    TEST_MODE_DESC="rig baseline harness only — no story-specific test (ga-857v FIX 2)"
  else
    TEST_STORY_ID="$STORY_ID"
    TEST_MODE_DESC="rig harness + story-specific test (story-${STORY_ID}.sh)"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD RUN PROD TEST: STORY_ID='$TEST_STORY_ID' bash $PROD_TEST_SCRIPT ($TEST_MODE_DESC)"
  else
    log "Running prod test: $PROD_TEST_SCRIPT (STORY_ID='$TEST_STORY_ID'; $TEST_MODE_DESC) ..."
    TEST_OUTPUT=$(STORY_ID="$TEST_STORY_ID" bash "$PROD_TEST_SCRIPT" 2>&1) && TEST_RC=$? || TEST_RC=$?
    log "Test output: $TEST_OUTPUT"

    if [ "$TEST_RC" -ne 0 ]; then
      err "Prod test FAILED (rc=$TEST_RC)"
      bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
      bd -C "$STORY_STORE" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
      bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery FAILED: prod test did not pass.
Script: $PROD_TEST_SCRIPT ($TEST_MODE_DESC)
Exit code: $TEST_RC
Output:
$TEST_OUTPUT

HALT — do NOT auto-revert (DB migration risk). Investigate the failure, fix forward, and re-run delivery." 2>/dev/null || true

      # Escalate: notify author (from bead)
      AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
      if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
        gc --city "$GC_CITY" session nudge "$AUTHOR" \
          "DELIVERY FAILED for story $STORY_ID ($STORY_TITLE). Prod test failed (exit $TEST_RC). See bead comments. DO NOT auto-revert — investigate and fix forward." \
          --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
      fi

      # wa-uthi: non-terminal (delivery:failed re-picked every cycle — retries, no
      # exhaustion counter) — no push to Athos. The author is nudged above; Athos
      # only hears terminal outcomes (story:done or definitive rejection).
      warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID prod test FAILED (rc=$TEST_RC) — author nudged."
      continue
    fi

    log "Prod test PASS ($TEST_MODE_DESC)"
  fi
fi

# ── Step 7: Verify refino criteria from story metadata ────────────────────────
# The story bead has metadata fields set by /refino:
#   story.estrela_guia, story.equilibrios, story.dashboard
# These are already codified in the story bead — we verify they are present
# and non-empty (the actual criteria were verified by the prod test above).
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD VERIFY refino criteria (story.estrela_guia, story.equilibrios, story.dashboard)"
else
  log "Verifying refino criteria metadata ..."
  STORY_META=$(bd -C "$STORY_STORE" show "$STORY_ID" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | .metadata // {}' 2>/dev/null || echo "{}")

  ESTRELA=$(echo "$STORY_META" | jq -r '.["story.estrela_guia"] // ""')
  EQUILIBRIOS=$(echo "$STORY_META" | jq -r '.["story.equilibrios"] // ""')
  DASHBOARD=$(echo "$STORY_META" | jq -r '.["story.dashboard"] // ""')

  MISSING_META=""
  [ -z "$ESTRELA" ] && MISSING_META="$MISSING_META story.estrela_guia"
  [ -z "$EQUILIBRIOS" ] && MISSING_META="$MISSING_META story.equilibrios"
  [ -z "$DASHBOARD" ] && MISSING_META="$MISSING_META story.dashboard"

  if [ -n "$MISSING_META" ]; then
    warn "Missing refino criteria fields:$MISSING_META — story lacks /refino metadata"
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery WARNING: missing refino metadata fields:$MISSING_META. /refino may not have been run. Story marked done but refino incomplete." 2>/dev/null || true
  else
    log "Refino criteria present: estrela_guia, equilibrios, dashboard"
  fi
fi

# ── Step 8: Mark story:done ────────────────────────────────────────────────────
DELIVERY_END=$(date +%s)
ELAPSED=$((DELIVERY_END - DELIVERY_START))

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD: bd label remove $STORY_ID delivery:running"
  log "DRY_RUN=1 — WOULD: bd label add $STORY_ID story:done"
  log "DRY_RUN=1 — WOULD: bd comment $STORY_ID 'Delivery COMPLETE...'"
  log "DRY_RUN=1 — notify 'Story $STORY_ID done'"
  # ga-i53ua: durable terminal — the data-level close that takes the executed
  # story OUT of Aprovadas and INTO Done (label-only story:done never sufficed).
  log "DRY_RUN=1 — WOULD: bd label remove $STORY_ID story:approved (leave Aprovadas)"
  log "DRY_RUN=1 — WOULD: bd label remove $STORY_ID story:in-flight"
  log "DRY_RUN=1 — WOULD: bd close $STORY_ID -r 'Story DELIVERED … (ga-i53ua durable terminal; delivery close_reason → painel Done)'"
else
  bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
  bd -C "$STORY_STORE" label add    "$STORY_ID" "story:done"       -q 2>/dev/null || true

  # wa-wzvg: detect Pilot origin (durable "pilot:dispatched" label set by the
  # Pilot when it autonomously pulled the story). Used to differentiate the
  # terminal DONE push so Athos can tell autonomous Pilot deliveries apart.
  PILOT_ORIGIN=0
  if echo "$STORY_LABELS" | grep "pilot:dispatched" >/dev/null; then
    PILOT_ORIGIN=1
  else
    BEAD_LABELS_NOW=$(bd -C "$STORY_STORE" show "$STORY_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
    echo "$BEAD_LABELS_NOW" | grep "pilot:dispatched" >/dev/null && PILOT_ORIGIN=1 || true
  fi
  PILOT_PREFIX=""
  [ "$PILOT_ORIGIN" = "1" ] && PILOT_PREFIX="🤖 [Pilot] "

  # ga-vmq1i: was the daemon actually serving this deploy ever confirmed live?
  # Orthogonal to which prod-test path ran below — apply to both branches.
  # Only "verified" (positive restart+fresh), "not_applicable" (structurally
  # nothing live to check), and (ga-y108i) "asset_served_per_request" (a
  # rig-declared no_restart_paths glob structurally proved the change safe —
  # see daemon-refresh.sh header point 8) may stay silent; everything else
  # gets an explicit, queryable label so "delivery:tested" alone can never be
  # read as "daemon confirmed live" the way the bug's own incident (wa-3dfnw)
  # was misread.
  case "$REFRESH_PROOF" in
    verified|not_applicable|asset_served_per_request) : ;;
    # ga-j3lh6p: Step 5b released this story because every still-stale daemon is
    # notify_only_locked AND has no call-graph path to a symbol the merge
    # changed. That is a THIRD answer — not "verified" (nothing was restarted;
    # the daemon really is still stale) and not "unverified" (we DID check and
    # judged it not needed). delivery:daemon-unverified means "could not check";
    # putting this case under it would make two different facts one label, and
    # tell Athos "may still be dormant" about something the system judged safe.
    symbol_unreachable_locked) bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:daemon-stale-locked" -q 2>/dev/null || true ;;
    # ga-xrn8ni: same THIRD-answer reasoning as symbol_unreachable_locked just
    # above, extended to a SENSITIVE daemon excused via a missing
    # $DRAIN_CMD_<label> rather than restart_policy.yaml's notify_only_locked.
    # Own label so a reader can tell the two exoneration paths apart (one
    # names a deliberate human lock, the other a configuration gap).
    symbol_unreachable_nodrain) bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:daemon-stale-nodrain" -q 2>/dev/null || true ;;
    *) bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:daemon-unverified" -q 2>/dev/null || true ;;
  esac

  # UNTESTED terminal success is now NO_HARNESS=1 ONLY (ga-857v FIX 2: a missing
  # story-specific test runs the rig baseline → delivery:tested, handled below).
  if [ "$NO_HARNESS" = "1" ]; then
    DONE_TEST_LINE="SKIPPED — rig '$RIG' has no prod-test harness (interim policy per ga-dqp)."
    DONE_NOTE="a real prod-test harness for this rig is a DESTINY follow-up item."
    DONE_PUSH_TAIL="prod test SKIPPED (no harness for $RIG)"
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery COMPLETE. story:done (delivery:untested).
Rig: $RIG
Deploy: $DEPLOY_CMD
Prod test: $DONE_TEST_LINE
Elapsed: ${ELAPSED}s
$(refino_criteria_status_line "${MISSING_META:-}")
NOTE: $DONE_NOTE" 2>/dev/null || true
    # wa-uthi: TERMINAL SUCCESS (story:done) — push KEPT. wa-wzvg: Pilot-differentiated.
    notify -t "${PILOT_PREFIX}Story DONE (untested)" -p 2 "${PILOT_PREFIX}Story $STORY_ID ($STORY_TITLE) — deployed, $DONE_PUSH_TAIL" 2>/dev/null || true
  else
    # delivery:tested — rig harness passed (full when a story-specific test exists,
    # baseline-only when it does not — ga-857v FIX 2). Add an explicit
    # delivery:tested label so the tested state is queryable (acceptance wording).
    bd -C "$STORY_STORE" label add "$STORY_ID" "delivery:tested" -q 2>/dev/null || true
    if [ "$STORY_TEST_MISSING" = "1" ]; then
      DONE_TEST_LINE="$PROD_TEST_SCRIPT — rig BASELINE harness only, no story-specific test (ga-857v FIX 2)"
      DONE_PUSH_TAIL="deployed + baseline-tested in prod"
    else
      DONE_TEST_LINE="$PROD_TEST_SCRIPT (STORY_ID=$STORY_ID)"
      DONE_PUSH_TAIL="deployed + tested in prod"
    fi
    # ga-vmq1i (THE FIX): the prod-test harness passing proves the CODE TREE is
    # consistent — it says nothing about whether a live daemon is running it.
    # "deployed + tested in prod" wrongly implied both. Only override wording
    # when daemon liveness was NOT positively confirmed and there genuinely was
    # something live to check (not_applicable — e.g. no daemon serves this
    # change at all — keeps the wording above, since nothing false is claimed;
    # ga-y108i's asset_served_per_request is the same shape — a stronger,
    # policy-proven not_applicable, see daemon-refresh.sh header point 8).
    case "$REFRESH_PROOF" in
      verified|not_applicable|asset_served_per_request) : ;;
      # ga-j3lh6p: says exactly what is known and no more — a locked daemon IS
      # still on the old code; the analysis found no call-graph path from it to
      # anything this merge changed. Evidence, not proof.
      symbol_unreachable_locked) DONE_PUSH_TAIL="deployed + tested in prod; a notify_only_locked daemon still runs the old code — no call-graph path from it to a symbol this merge changed (evidence, not proof; see delivery:daemon-stale-locked)" ;;
      # ga-xrn8ni: same evidence-not-proof wording as symbol_unreachable_locked
      # just above, for a SENSITIVE daemon excused via a missing
      # $DRAIN_CMD_<label> instead of a notify_only_locked policy entry.
      symbol_unreachable_nodrain) DONE_PUSH_TAIL="deployed + tested in prod; a SENSITIVE daemon with no drain path configured still runs the old code — no call-graph path from it to a symbol this merge changed (evidence, not proof; see delivery:daemon-stale-nodrain)" ;;
      *) DONE_PUSH_TAIL="deployed (rig harness passed); DAEMON LIVENESS NOT VERIFIED — merged code may still be dormant, see delivery:daemon-unverified" ;;
    esac
    bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery COMPLETE. story:done (delivery:tested).
Rig: $RIG
Deploy: $DEPLOY_CMD
Prod test: $DONE_TEST_LINE
Elapsed: ${ELAPSED}s
$(refino_criteria_status_line "${MISSING_META:-}")" 2>/dev/null || true
    # wa-uthi: TERMINAL SUCCESS (story:done) — push KEPT. wa-wzvg: Pilot-differentiated.
    notify -t "${PILOT_PREFIX}Story DONE" -p 2 "${PILOT_PREFIX}Story $STORY_ID ($STORY_TITLE) — $DONE_PUSH_TAIL" 2>/dev/null || true
  fi
  log "story:done set on $STORY_ID"

  # ── ga-i53ua: DRIVE THE STORY TO ITS DURABLE TERMINAL STATE ─────────────────
  # THE BUG: the steps above add the story:done LABEL but never (a) remove the
  # highest cycle label story:approved, nor (b) CLOSE the bead. A delivered story
  # therefore stays OPEN at story:approved+story:done forever (proven on ga-w7wvm,
  # ga-v3z4z, ga-sefot — all PASS in story-delivery.jsonl yet still OPEN+approved).
  # The painel renders open story:approved beads in "Aprovadas" (cycle-column
  # query is open-only) and only routes CLOSED+delivery-reason beads to "Done"
  # (_closed_bead_belongs_in_done → _is_delivery_close). So an executed story is
  # never DATA-done; it just accretes a story:done label while sitting in Aprovadas.
  #
  # FORWARD FIX (this is what makes the executed story reach Done by DATA):
  #   (a) remove story:approved  → it is no longer in the Aprovadas open-query
  #   (b) remove story:in-flight → defensive (merge usually stripped it already)
  #   (c) bd close with a close_reason that the painel's _is_delivery_close
  #       recognizes as a DELIVERY (contains "Delivered"/"delivered"/"merged"/
  #       "done" — see painel_visibilidade.py _DELIVERY_CLOSE) and contains NO
  #       non-delivery word (stale/superseded/cancel/…), so the closed bead lands
  #       in Done. story:done LABEL is RETAINED — the Done column query uses --all,
  #       so the closed bead still appears there. This reproduces the known-good
  #       manual end-state (ref ga-mtlm6: story:approved removed + "merged" close).
  # Fully guarded: every step `|| true`. If close fails (e.g. cross-store no-op),
  # the merged-bead-janitor remains a backstop, but the story:approved REMOVAL
  # above still pulls the bead out of Aprovadas even if it stays open.
  bd -C "$STORY_STORE" label remove "$STORY_ID" "story:approved"  -q 2>/dev/null || true
  bd -C "$STORY_STORE" label remove "$STORY_ID" "story:in-flight" -q 2>/dev/null || true
  # ga-iwv0: this terminal is reached only after the daemon-refresh verified the deploy is LIVE,
  # so clear any deploy-pending/failed markers left by an earlier halted attempt — the bead is
  # now genuinely deployed; stale markers must not linger on a delivered story.
  bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:deploy-pending" -q 2>/dev/null || true
  bd -C "$STORY_STORE" label remove "$STORY_ID" "delivery:failed"          -q 2>/dev/null || true
  # wa-xokje: this story is genuinely delivered now — drop its halt-dedup
  # fingerprint (see Step 5b) so a FUTURE, unrelated halt on this same
  # STORY_ID (should one ever recur) is never silently matched against a
  # stale fingerprint from a completely different incident.
  rm -f "$GC_CITY/.gc/runtime/daemon-refresh-baseline/halt-fingerprint/$STORY_ID.txt" 2>/dev/null || true
  # ga-vmq1i: do not hardcode "verified in prod" here — DONE_PUSH_TAIL above is
  # already the single, accurate source of truth for what was actually
  # confirmed (including the NOT-verified case); repeating a blanket "verified"
  # claim in the same sentence would just contradict it.
  DELIVERY_CLOSE_REASON="Story DELIVERED — story:done (rig $RIG, ${DONE_PUSH_TAIL:-delivered}). Closed by story-delivery (ga-i53ua durable terminal)."
  CLOSE_STATUS_NOW=$(bd -C "$STORY_STORE" show "$STORY_ID" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | .status // "open"' 2>/dev/null || echo "open")
  if [ "$CLOSE_STATUS_NOW" != "closed" ]; then
    if bd -C "$STORY_STORE" close "$STORY_ID" -r "$DELIVERY_CLOSE_REASON" 2>/dev/null; then
      log "Story $STORY_ID CLOSED (delivery terminal: story:approved removed; delivery close_reason → painel Done)."
    else
      warn "Could not close story $STORY_ID at delivery terminal (non-fatal; story:approved already removed so it leaves Aprovadas; merged-bead-janitor backstops the close)."
    fi
  else
    log "Story $STORY_ID already closed — story:approved removed; delivery terminal idempotent."
  fi
fi

# ── Step 9: Log to story-delivery.jsonl ───────────────────────────────────────
# Determine result classification. ga-857v FIX 2: untested is NO_HARNESS only;
# a missing story-specific test now runs the rig baseline → PASS (tested).
if [ "$DRY_RUN" = "1" ]; then
  DELIVERY_RESULT="dry_run"
elif [ "$NO_HARNESS" = "1" ]; then
  DELIVERY_RESULT="PASS_UNTESTED"
else
  DELIVERY_RESULT="PASS"
fi
mkdir -p "$(dirname "$DELIVERY_LOG")"
jq -c -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg story_id "$STORY_ID" \
  --arg story_title "$STORY_TITLE" \
  --arg rig "$RIG" \
  --arg result "$DELIVERY_RESULT" \
  --arg deploy_cmd "$DEPLOY_CMD" \
  --arg prod_test "$PROD_TEST_SCRIPT" \
  --argjson elapsed_s "$ELAPSED" \
  --arg dry_run "$DRY_RUN" \
  '{ts: $ts, event: "delivery_complete", story_id: $story_id, story_title: $story_title,
    rig: $rig, result: $result, deploy_cmd: $deploy_cmd, prod_test: $prod_test,
    elapsed_s: $elapsed_s, dry_run: $dry_run}' \
  >> "$DELIVERY_LOG" 2>/dev/null || true

log "=== Delivery sweep complete: story=$STORY_ID rig=$RIG result=$([ "$DRY_RUN" = "1" ] && echo dry_run || echo PASS) elapsed=${ELAPSED}s ==="

done < <(echo "$STORIES_JSON" | jq -c '.[]')
log "=== Delivery sweep finished ==="
