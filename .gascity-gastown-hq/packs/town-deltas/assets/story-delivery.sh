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
  printf '%s' "$2" | grep -Eq "(^|[^[:alnum:]-])$1([^[:alnum:]-]|\$)"
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
unset _STORY_DELIVERY_SELF_DIR _STORY_DELIVERY_GUARD_SIB
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
      if [ "$TASK_IS_PARTIAL" != "1" ] && printf '%s' "$TASK_PARTIAL_REASON_RAW" | grep -q '^escopo-multiplo:possivel'; then
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

# Skip if already marked story:done (idempotency guard)
if echo "$STORY_LABELS" | grep -q "story:done"; then
  log "Story $STORY_ID already labeled story:done — skipping."
  continue
fi

# Skip if already in delivery (prevents parallel runs)
if echo "$STORY_LABELS" | grep -q "delivery:running"; then
  log "Story $STORY_ID already has delivery:running — skipping (already in flight)."
  continue
fi

# ga-aqqj0: skip if the no-deploy-cmd retry cap already escalated this story
# (Step 3 below). A human has been notified via bead comment + Mayor mail;
# do not keep re-halting/re-commenting every ~5min sweep while waiting for
# that human to fix the rig value or the runbook (that unbounded-comment loop
# — 18 identical halts in 1h on ga-dv2gk — is exactly what the retry cap
# exists to stop). Removing the label lets the sweep retry automatically.
if echo "$STORY_LABELS" | grep -q "delivery:no-deploy-cmd-exhausted"; then
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
fi

DELIVERY_START=$(date +%s)

# ── Step 2: Determine rig from story metadata / labels ───────────────────────
# Priority order:
#   1. label  rig:<name>  on the bead
#   2. metadata field  story.rig
#   3. Parse the gate comment ("merged to <rig>/main") — set by dispatcher
RIG=""
if echo "$STORY_LABELS" | grep -oE "rig:[a-z_]+" | head -1 | grep -q "rig:"; then
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
# SCOPE: only run when the deploy will execute a FATAL `pull --ff-only` (the
# bug's domain — property_scrapers, whatsapp_automation). Rigs whose deploy
# swallows pull failures (e.g. gascity: "... 2>/dev/null || true") or that don't
# pull at all are NOT subject to the untracked-overwrite abort, so the reconcile
# must NOT run for them — otherwise a pre-existing, harmless untracked file in
# that runtime (e.g. the town root's .gitignore) would wrongly halt delivery.
RUN_RECONCILE=0
case "$DEPLOY_CMD" in
  *"pull --ff-only"*)
    case "$DEPLOY_CMD" in
      *"|| true"*) RUN_RECONCILE=0 ;;  # pull failure swallowed → not fatal
      *)           RUN_RECONCILE=1 ;;
    esac
    ;;
esac

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
  log "Daemon refresh: pre=$PRE_DEPLOY_SHA post=$POST_DEPLOY_SHA sensitive='$SENSITIVE_DAEMONS' extra_roots='$EXTRA_RUNTIME_ROOTS' ..."
  REFRESH_OUT=$(RUNTIME_DIR="$RUNTIME_DIR" \
    PRE_DEPLOY_SHA="$PRE_DEPLOY_SHA" POST_DEPLOY_SHA="$POST_DEPLOY_SHA" \
    DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
    EXTRA_RUNTIME_ROOTS="$EXTRA_RUNTIME_ROOTS" \
    DRY_RUN="$DRY_RUN" \
    bash "$REFRESH_HELPER" || true)
  REFRESH_VERDICT=$(echo "$REFRESH_OUT" | grep '^VERDICT=' | head -1 | sed 's/^VERDICT=//')
  REFRESH_REASON=$(echo  "$REFRESH_OUT" | grep '^REASON='  | head -1 | sed 's/^REASON=//')
  REFRESH_RESTARTED=$(echo "$REFRESH_OUT" | grep '^RESTARTED=' | head -1 | sed 's/^RESTARTED=//')
  REFRESH_GUARDED=$(echo "$REFRESH_OUT" | grep '^GUARDED=' | head -1 | sed 's/^GUARDED=//')
  REFRESH_FRESHFAIL=$(echo "$REFRESH_OUT" | grep '^FRESH_FAIL=' | head -1 | sed 's/^FRESH_FAIL=//')
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
  case "$REFRESH_VERDICT" in
    OK|SKIPPED)
      if [ -n "${REFRESH_RESTARTED// /}" ]; then
        log "Refreshed + verified live: $REFRESH_RESTARTED"
      fi
      ;;
    *)
      err "Daemon refresh did NOT pass (verdict=$REFRESH_VERDICT): $REFRESH_REASON"
      if [ "$REFRESH_VERDICT" = "NEEDS_GUARDED_RESTART" ]; then
        # ga-puq8z ACEITE 2: this verdict is single-hop import/template-closure
        # detection (daemon-refresh.sh Step 3), not proof the daemon's live
        # code path reaches the changed symbols — say so explicitly rather
        # than asserting staleness outright. daemon-refresh.sh's own
        # already-fresh check (COMMIT_EPOCH-based, ga-puq8z) already ran and
        # did NOT clear this daemon, but a human deciding whether to bounce a
        # hot-path daemon on this alone should know the detection basis.
        REFRESH_ACTION="ACTION: perform a guarded/graceful restart of the flagged hot-path daemon(s) ($REFRESH_GUARDED) — drain in-flight messages/webhooks first — then re-run delivery. (Configure a DRAIN_CMD_<label> for daemon-refresh.sh to automate this.) CAVEAT (ga-puq8z): flagged by import/template-closure matching, not proven reachable to the changed symbols — if in doubt, compare \`ps -o lstart= -p <pid>\` against commit $POST_DEPLOY_SHA before restarting."
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
        bd -C "$STORY_STORE" comment "$STORY_ID" "Delivery HALTED (ga-iwv0 daemon refresh): $REFRESH_VERDICT — $REFRESH_REASON
A long-lived daemon serving rig '$RIG' is running code OLDER than this deploy and could not be safely refreshed/verified, so the merged feature would be DORMANT in production. story:done is WITHHELD (a dormant deploy must never be marked done).
$REFRESH_ACTION
Refresh detail:
$REFRESH_OUT" 2>/dev/null || true
        AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
        if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
          gc --city "$GC_CITY" session nudge "$AUTHOR" \
            "DELIVERY HALTED for $STORY_ID (ga-iwv0): $REFRESH_VERDICT — a daemon serving the merge is dormant/unverified. See bead; do NOT mark done." \
            --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
        fi
        gc --city "$GC_CITY" session nudge mayor \
          "DELIVERY HALTED ($STORY_ID, rig $RIG): daemon refresh $REFRESH_VERDICT — $REFRESH_REASON. story:done withheld." \
          2>/dev/null || true
      fi
      # wa-uthi: non-terminal (delivery:failed re-picked every cycle once the
      # daemon is refreshed) — no Athos push. Author + Mayor nudged above.
      warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID daemon refresh $REFRESH_VERDICT."
      continue
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
  if echo "$STORY_LABELS" | grep -q "pilot:dispatched"; then
    PILOT_ORIGIN=1
  else
    BEAD_LABELS_NOW=$(bd -C "$STORY_STORE" show "$STORY_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
    echo "$BEAD_LABELS_NOW" | grep -q "pilot:dispatched" && PILOT_ORIGIN=1 || true
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
