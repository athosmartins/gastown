#!/usr/bin/env bash
# merged-bead-janitor.selftest.sh — prove the ga-tijv5 janitor in isolation,
# with NO live Dolt/gc/launchd and NO network.
#
# Sources the janitor in lib-only mode for the REAL functions (one source of
# truth, no copy-drift), unit-tests the pure decision across every branch and
# every guard, runs a real-git integration test for the merge-evidence helpers
# (commit-msg scan with token boundaries + branch ancestry), exercises the
# marker JSON helpers against synthetic fixtures, then DRIFT-GUARDS the live
# wiring. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JANITOR="$SELF_DIR/merged-bead-janitor.sh"
PLIST="$SELF_DIR/merged-bead-janitor.plist"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
rc0() { if "$@" >/dev/null 2>&1; then ok "rc0: $*"; else bad "expected rc0: $*"; fi; }
rc1() { if "$@" >/dev/null 2>&1; then bad "expected non-zero: $*"; else ok "rc!=0: $*"; fi; }

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
JANITOR_LIB_ONLY=1 source "$JANITOR" \
  || { echo "FATAL: could not source janitor in lib-only mode"; exit 1; }
for fn in janitor_decide janitor_story_decide token_bounded scan_commit_for_bead \
          scan_commit_subject_for_bead subject_impl_scopes_bead branch_merged content_in_main \
          has_open_marker has_terminal_passed_marker has_terminal_superseded_marker \
          branch_label_from_markers rig_gitdir \
          janitor_branch_decide normalize_bead_status branch_is_fresh \
          bead_lookup_one resolve_bead_state \
          commit_epoch commit_evidence_stale comments_for_bead \
          sling_beads_from_show sling_signals_for_id sling_fallback_eligible_reason; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by janitor"; exit 1; }
done

# ── 1. janitor_decide — pure decision, every branch + guard precedence ──────
# Args: <is_epic> <has_open_marker> <sig_commit> <sig_marker> <sig_branch>
echo "── 1. janitor_decide (pure verdict) ──"
eq "no signals → keep"                  "$(janitor_decide 0 0 0 0 0)" "keep:no-merge-evidence"
eq "commit signal → close"              "$(janitor_decide 0 0 1 0 0 | cut -d: -f1)" "close"
eq "marker signal → close"              "$(janitor_decide 0 0 0 1 0 | cut -d: -f1)" "close"
eq "branch signal → close"              "$(janitor_decide 0 0 0 0 1 | cut -d: -f1)" "close"
eq "commit reason"                      "$(janitor_decide 0 0 1 0 0)" "close:commit-in-origin-main"
eq "marker reason"                      "$(janitor_decide 0 0 0 1 0)" "close:terminal-gate-marker-passed"
eq "branch reason"                      "$(janitor_decide 0 0 0 0 1)" "close:branch-ancestor-of-origin-main"
# Guard precedence: epic ALWAYS keep, even with every signal set.
eq "epic beats all signals → keep"      "$(janitor_decide 1 0 1 1 1 | cut -d: -f1)" "keep"
eq "epic reason"                        "$(janitor_decide 1 0 0 0 0)" "keep:epic-parent-never-autoclosed"
# Open marker beats signals (protects wa-lstd: queued + branch present).
eq "open-marker beats commit → keep"    "$(janitor_decide 0 1 1 0 0 | cut -d: -f1)" "keep"
eq "open-marker beats branch → keep"    "$(janitor_decide 0 1 0 0 1 | cut -d: -f1)" "keep"
eq "open-marker reason"                 "$(janitor_decide 0 1 0 0 0)" "keep:active-open-gate-marker"
# Epic precedence over open-marker (both 'keep' but epic wins the label).
eq "epic+open → epic reason"            "$(janitor_decide 1 1 0 0 0)" "keep:epic-parent-never-autoclosed"

# ── 1a2. janitor_decide sig_commit_stale — joint/split-bead false-close guard (ga-2zp4h) ──
# wa-d3136 shape: mila's half was delivered+gated under her OWN sibling bead (wa-eda28),
# but her commit's subject still scoped the shared PARENT id (`chore(wa-d3136): …`) — a
# legitimate Signal-A match, yet the bead was reassigned to a second owner the day AFTER
# that commit landed, and his half was never built. sig_commit_stale=1 means a bead
# comment postdates the matched commit — it suppresses signal A ALONE; signals B/C are
# bead-specific and authoritative, so they still close normally even when stale=1.
echo "── 1a2. janitor_decide sig_commit_stale (joint/split-bead guard, ga-2zp4h) ──"
eq "backward-compat: 5 args, no 6th → commit still closes" \
   "$(janitor_decide 0 0 1 0 0)" "close:commit-in-origin-main"
eq "6th arg omitted defaults to 0 (not stale) → commit still closes" \
   "$(janitor_decide 0 0 1 0 0 | cut -d: -f1)" "close"
eq "stale commit alone → KEEP (the wa-d3136 false-close this fix prevents)" \
   "$(janitor_decide 0 0 1 0 0 1)" "keep:commit-evidence-superseded-by-newer-comment"
eq "stale commit + marker also fires → marker still closes (signal B unaffected)" \
   "$(janitor_decide 0 0 1 1 0 1)" "close:terminal-gate-marker-passed"
eq "stale commit + branch also fires → branch still closes (signal C unaffected)" \
   "$(janitor_decide 0 0 1 0 1 1)" "close:branch-ancestor-of-origin-main"
eq "stale=1 but no commit signal at all → falls through to no-merge-evidence" \
   "$(janitor_decide 0 0 0 0 0 1)" "keep:no-merge-evidence"
eq "stale=0 explicit (not just omitted) → commit still closes" \
   "$(janitor_decide 0 0 1 0 0 0)" "close:commit-in-origin-main"
# Guard precedence unchanged: epic/open-marker still beat a stale-flagged commit too.
eq "epic beats stale commit → keep (epic reason, not stale reason)" \
   "$(janitor_decide 1 0 1 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats stale commit → keep (open-marker reason)" \
   "$(janitor_decide 0 1 1 0 0 1)" "keep:active-open-gate-marker"

# ── 1a3. janitor_decide sig_marker_superseded — superseded ≠ merged (ga-v8ui5) ──
# gate-status:superseded means the branch was REPLACED (rebase/recreate — the
# documented procedure when the gate rejects a stale base) — the OPPOSITE of
# passed. It must NEVER assert delivery by itself; only real merge evidence
# (signal A commit-in-main, or signal C branch-ancestor — e.g. a REPLACEMENT
# branch that genuinely merged) may close a bead with a superseded marker.
echo "── 1a3. janitor_decide sig_marker_superseded (superseded ≠ merged, ga-v8ui5) ──"
eq "backward-compat: 6 args, no 7th → unaffected (defaults to 0)" \
   "$(janitor_decide 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "superseded alone → KEEP with a distinguishable reason (the wa-c3qsr false-close this fix prevents)" \
   "$(janitor_decide 0 0 0 0 0 0 1)" "keep:superseded-marker-needs-merge-evidence"
eq "superseded + commit signal → commit still closes (replacement branch merged, verified by content)" \
   "$(janitor_decide 0 0 1 0 0 0 1)" "close:commit-in-origin-main"
eq "superseded + branch signal → branch still closes (replacement branch is an origin/main ancestor)" \
   "$(janitor_decide 0 0 0 0 1 0 1)" "close:branch-ancestor-of-origin-main"
eq "superseded + passed marker also present → passed still wins (signal B, distinct marker)" \
   "$(janitor_decide 0 0 0 1 0 0 1)" "close:terminal-gate-marker-passed"
# Guard precedence unchanged: epic/open-marker still beat a superseded-only marker too.
eq "epic beats superseded-only → keep (epic reason, not superseded reason)" \
   "$(janitor_decide 1 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats superseded-only → keep (open-marker reason)" \
   "$(janitor_decide 0 1 0 0 0 0 1)" "keep:active-open-gate-marker"

# ── 1b. janitor_story_decide — merged story:approved → story:done (ga-gosfs) ──
# Args: <is_epic> <has_open_marker> <already_done> <in_flight> <has_builder>
#       <delivery_active> <sig_commit> <sig_marker> <sig_branch>
# Echoes "done:<reason>" (transition story:approved → story:done) or "keep:<reason>".
# This is the SECOND sweep: stories sit OPEN + story:approved after a gate PASS
# (handed off to delivery). If delivery never fires (cross-store missing gate:passed,
# superseded path, rig-store delivery never scans, delivery crash) the merged story
# is stranded story:approved and the Kanban shows false backlog. With merge evidence
# AND no active rework, the janitor drives it to story:done.
echo "── 1b. janitor_story_decide (merged story → story:done) ──"
# Happy paths: a merge signal + no active rework + not already done → done.
eq "commit signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 1 0 0)" "done:commit-in-origin-main"
eq "marker signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 0 1 0)" "done:terminal-gate-marker-passed"
eq "branch signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 0 0 1)" "done:branch-ancestor-of-origin-main"
eq "any-signal verb is done"            "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 | cut -d: -f1)" "done"
# No merge evidence → keep (a genuinely-pending approved story is NOT touched: AC2).
eq "no merge evidence → keep"           "$(janitor_story_decide 0 0 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
# Guard precedence — each guard beats every merge signal (all signals = 1):
eq "epic beats signals → keep"          "$(janitor_story_decide 1 0 0 0 0 0 1 1 1)" "keep:epic-parent-never-autoclosed"
eq "already-done idempotent → keep"     "$(janitor_story_decide 0 0 1 0 0 0 1 1 1)" "keep:already-story-done"
eq "open-marker (mid-gate) → keep"      "$(janitor_story_decide 0 1 0 0 0 0 1 1 1)" "keep:active-open-gate-marker"
eq "in-flight (active build) → keep"    "$(janitor_story_decide 0 0 0 1 0 0 1 1 1)" "keep:story-in-flight-active-rework"
eq "live builder assignee → keep"       "$(janitor_story_decide 0 0 0 0 1 0 1 1 1)" "keep:live-builder-assignee"
eq "delivery owns it → keep"            "$(janitor_story_decide 0 0 0 0 0 1 1 1 1)" "keep:delivery-owns-it"
# Guard ORDER (first match wins; ACTIVE-WORK guards precede already_done — security fix):
eq "epic > already-done"                "$(janitor_story_decide 1 0 1 0 0 0 0 0 0)" "keep:epic-parent-never-autoclosed"
# SECURITY: a bead with a STALE story:done AND an active open gate-marker must keep as
# active-open-gate-marker (NOT already-story-done) — else the orphan-close backstop false-closes it.
eq "open-marker > already-done"         "$(janitor_story_decide 0 1 1 0 0 0 0 0 0)" "keep:active-open-gate-marker"
eq "open-marker > in-flight"            "$(janitor_story_decide 0 1 0 1 0 0 0 0 0)" "keep:active-open-gate-marker"
eq "in-flight > builder"                "$(janitor_story_decide 0 0 0 1 1 0 0 0 0)" "keep:story-in-flight-active-rework"
eq "builder > delivery"                 "$(janitor_story_decide 0 0 0 0 1 1 0 0 0)" "keep:live-builder-assignee"
# Signal precedence among the three (commit > marker > branch), cosmetic only.
eq "commit beats marker+branch"         "$(janitor_story_decide 0 0 0 0 0 0 1 1 1)" "done:commit-in-origin-main"
eq "marker beats branch"                "$(janitor_story_decide 0 0 0 0 0 0 0 1 1)" "done:terminal-gate-marker-passed"

# ── 1b2. janitor_story_decide sig_commit_stale — same joint/split-bead guard (ga-2zp4h) ──
# A story can be a joint/split bead too; the suppression mirrors janitor_decide exactly.
echo "── 1b2. janitor_story_decide sig_commit_stale (joint/split-bead guard, ga-2zp4h) ──"
eq "backward-compat: 9 args, no 10th → commit still done" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0)" "done:commit-in-origin-main"
eq "stale commit alone → KEEP (not forced to story:done)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 1)" "keep:commit-evidence-superseded-by-newer-comment"
eq "stale commit + marker also fires → marker still drives done (signal B unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 1 0 1)" "done:terminal-gate-marker-passed"
eq "stale commit + branch also fires → branch still drives done (signal C unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 1 1)" "done:branch-ancestor-of-origin-main"
eq "in-flight guard still beats a stale-flagged commit" \
   "$(janitor_story_decide 0 0 0 1 0 0 1 0 0 1)" "keep:story-in-flight-active-rework"

# ── 1b3. janitor_story_decide sig_marker_superseded — superseded ≠ merged (ga-v8ui5) ──
# Same parity as janitor_decide §1a3: a superseded marker alone must never drive
# a story to story:done — only real merge evidence (commit or branch-ancestor,
# e.g. a genuinely-merged REPLACEMENT branch) may.
echo "── 1b3. janitor_story_decide sig_marker_superseded (superseded ≠ merged, ga-v8ui5) ──"
eq "backward-compat: 9 args, no 10th/11th → unaffected" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "superseded alone → KEEP with a distinguishable reason (not forced to story:done)" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0 0 1)" "keep:superseded-marker-needs-merge-evidence"
eq "superseded + commit signal → commit still drives done (replacement branch merged)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 0 1)" "done:commit-in-origin-main"
eq "superseded + branch signal → branch still drives done (replacement branch ancestor)" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 1 0 1)" "done:branch-ancestor-of-origin-main"
eq "epic beats superseded-only → keep (epic reason)" \
   "$(janitor_story_decide 1 0 0 0 0 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "already-done beats superseded-only → keep (idempotent, not re-driven by a stale marker)" \
   "$(janitor_story_decide 0 0 1 0 0 0 0 0 0 0 1)" "keep:already-story-done"
eq "in-flight beats superseded-only → keep (active rework not masked as done)" \
   "$(janitor_story_decide 0 0 0 1 0 0 0 0 0 0 1)" "keep:story-in-flight-active-rework"

# ── 1c. janitor_branch_decide — crew-branch prune (ga-tijv5 extension) ──────
# Args: <ahead> <content_in_main> <bead_state> <live_worktree> <is_fresh>. A branch
# is prunable iff its CONTENT is fully in main — either ahead==0 (strict ancestor;
# cim trivially 1) OR ahead>0 but cim==1 (squash / re-commit, the wa-fvxj1 class) —
# AND bead closed|gone AND no worktree AND not fresh. A branch with a unique patch
# NOT in main (ahead>0 AND cim!=1) must NEVER prune. Every uncertain state → KEEP.
echo "── 1c. janitor_branch_decide (crew-branch prune, squash-aware) ──"
# Strict-ancestor prune paths (ahead==0 ⟹ cim==1): fully-merged + bead closed / gone.
eq "merged + bead closed → prune"       "$(janitor_branch_decide 0 1 closed 0 0)" "prune:merged-and-bead-closed"
eq "merged + bead gone → prune"         "$(janitor_branch_decide 0 1 gone   0 0)" "prune:merged-and-bead-gone"
eq "prune verb (closed)"                "$(janitor_branch_decide 0 1 closed 0 0 | cut -d: -f1)" "prune"
# SQUASH-MERGE prune paths (ahead>0 by sha BUT content patch-present in main, cim==1):
# the wa-fvxj1 class — now prunable (was the systemic blind spot). Distinct reason.
eq "squash-merged + bead closed → prune" "$(janitor_branch_decide 1 1 closed 0 0)" "prune:squash-merged-and-bead-closed"
eq "squash-merged + bead gone → prune"   "$(janitor_branch_decide 3 1 gone   0 0)" "prune:squash-merged-and-bead-gone"
eq "squash prune verb"                   "$(janitor_branch_decide 1 1 closed 0 0 | cut -d: -f1)" "prune"
# CRITICAL negative direction — genuinely-unique content (ahead>0 AND cim!=1) is the
# destructive case: NEVER pruned, whatever the bead state. A false merged-verdict here
# would DELETE real work off the remote.
eq "unmerged content → keep"            "$(janitor_branch_decide 5 0 closed 0 0)" "keep:has-unmerged-commits"
eq "unmerged even if bead gone → keep"  "$(janitor_branch_decide 1 0 gone   0 0)" "keep:has-unmerged-commits"
# bad ahead read (ERR) with unverified content (cim=0) → keep (fail-safe).
eq "bad ahead read + cim=0 → keep"      "$(janitor_branch_decide ERR 0 closed 0 0)" "keep:has-unmerged-commits"
# bad ahead read BUT content verified in main (cim=1) → still lossless → squash prune.
eq "bad ahead read + cim=1 → prune"     "$(janitor_branch_decide ERR 1 closed 0 0)" "prune:squash-merged-and-bead-closed"
# Live worktree wins over everything (active agent), even fully merged + closed.
eq "live worktree → keep"               "$(janitor_branch_decide 0 1 closed 1 0)" "keep:live-worktree"
eq "worktree beats prune (gone)"        "$(janitor_branch_decide 0 1 gone   1 0)" "keep:live-worktree"
eq "worktree beats squash prune"        "$(janitor_branch_decide 2 1 closed 1 0)" "keep:live-worktree"
# Freshness grace: a just-merged branch is kept even with a closed bead.
eq "fresh branch → keep"                "$(janitor_branch_decide 0 1 closed 0 1)" "keep:fresh-branch-grace-window"
eq "fresh squash branch → keep"         "$(janitor_branch_decide 2 1 closed 0 1)" "keep:fresh-branch-grace-window"
# Open/active bead → keep (courtesy; content already in main loses nothing but we don't touch it).
eq "open/active bead → keep"            "$(janitor_branch_decide 0 1 active 0 0)" "keep:bead-open-or-active"
eq "open/active bead (squash) → keep"   "$(janitor_branch_decide 2 1 active 0 0)" "keep:bead-open-or-active"
# FAIL-OPEN: an unreadable bead status must never be pruned (transient Dolt).
eq "bead read error → keep (failopen)"  "$(janitor_branch_decide 0 1 readerror 0 0)" "keep:bead-read-error-failopen"
# Guard precedence: worktree > unmerged-content > fresh > readerror > active > closed/gone.
eq "worktree > unmerged"                "$(janitor_branch_decide 9 0 closed 1 0)" "keep:live-worktree"
eq "unmerged > fresh"                   "$(janitor_branch_decide 3 0 closed 0 1)" "keep:has-unmerged-commits"
eq "fresh > readerror"                  "$(janitor_branch_decide 0 1 readerror 0 1)" "keep:fresh-branch-grace-window"
eq "readerror > active"                 "$(janitor_branch_decide 0 1 active 0 0)" "keep:bead-open-or-active"

# ── 1d. normalize_bead_status — raw bd status → coarse closed|active ─────────
echo "── 1d. normalize_bead_status ──"
eq "closed → closed"                    "$(normalize_bead_status closed)" "closed"
eq "open → active"                      "$(normalize_bead_status open)" "active"
eq "in_progress → active"               "$(normalize_bead_status in_progress)" "active"
eq "blocked → active"                   "$(normalize_bead_status blocked)" "active"
eq "deferred → active"                  "$(normalize_bead_status deferred)" "active"
eq "empty → active (safe)"              "$(normalize_bead_status '')" "active"

# ── 2. token_bounded — whole-token id match (no substring false-positives) ──
echo "── 2. token_bounded ──"
rc0 token_bounded "wa-1or2" "feat(wa-1or2): add simplified mode"
rc0 token_bounded "wa-1or2" "Mirrors WA bead wa-1or2; the artifact is HQ-local"
rc0 token_bounded "wa-1or2" "Source bead: ga-piycl (mirror of wa-1or2)"
rc1 token_bounded "wa-1"    "feat(wa-1or2): unrelated longer id"      # wa-1 must NOT match wa-1or2
rc1 token_bounded "wa-1or2" "see commit wa-1or2x for details"          # trailing alnum breaks boundary
rc1 token_bounded "wa-1or2" "totally unrelated message"

# ── 2b. subject_impl_scopes_bead — THE DISCRIMINATOR (ga-wisp-ld35wuw) ───────
# rc0 iff the bead id is the IMPLEMENTING conventional-commit SCOPE (header before the
# first colon), rc1 if it is only a trailing context/motivation reference. This is the
# exact test that separates a genuine delivery from a framework commit that merely names
# the bead. The two load-bearing cases are the REAL commits from the wa-iy9s8 false-close.
echo "── 2b. subject_impl_scopes_bead (impl-scope vs trailing context) ──"
# THE REGRESSION (real subjects): 286cb29c7-HQ mentioned wa-iy9s8 in a TRAILING context
# paren "(ga-4aree/wa-iy9s8)"; d0219063-WA is the genuine fix(wa-iy9s8): delivery. The OLD
# scanner token-bounded the WHOLE subject and matched BOTH → false-closed the P1 bug.
rc1 subject_impl_scopes_bead "fix(pilot): rig-native scan no longer excludes gate:needs-fix — rig re-fix bugs dispatch (ga-4aree/wa-iy9s8)" "wa-iy9s8"   # trailing context → NOT delivery
rc0 subject_impl_scopes_bead "fix(wa-iy9s8): auto-deploy viewer/ to S3 on merge — done != deployed" "wa-iy9s8"                                          # scope → delivery
# Implementing-scope forms all MATCH (rc0):
rc0 subject_impl_scopes_bead "feat(wa-iy9s8): add thing" "wa-iy9s8"                       # feat(<id>):
rc0 subject_impl_scopes_bead "feat(warming/wa-iy9s8): re-land squashed lane" "wa-iy9s8"   # path-segment scope
rc0 subject_impl_scopes_bead "Merge crew/mila/wa-iy9s8: painel column-selector" "wa-iy9s8" # genuine merge landing
rc0 subject_impl_scopes_bead "wa-iy9s8: fix the crash" "wa-iy9s8"                          # bare-id lead
rc0 subject_impl_scopes_bead "fix bug wa-iy9s8: retry logic" "wa-iy9s8"                    # "fix bug <id>:" lead
rc0 subject_impl_scopes_bead "merge(wa-86jr+wa-o3zs): Contagem cadastre bulk-load" "wa-o3zs" # multi-id scope (real wa-o3zs landing)
# Trailing-context / body-ish / wrong-scope forms all REJECTED (rc1):
rc1 subject_impl_scopes_bead "tune(gate): VERDICT_TIMEOUT 45→22min (interim until gt-x2xin Phase-2)" "gt-x2xin" # explicitly FUTURE work
rc1 subject_impl_scopes_bead "fix(pilot): fixes dispatch for wa-iy9s8 stranded beads" "wa-iy9s8"               # id after colon = description
rc1 subject_impl_scopes_bead "feat(wa-ab6z): São João Batista 5 donos (ITBI)" "wa-y2lk"                        # sibling under parent → per-bead unproven
rc1 subject_impl_scopes_bead "docs(wa-e34v): doc-mestre de data-mastery de Contagem" "wa-qjym"                 # unrelated scope, no id
rc1 subject_impl_scopes_bead "chore: see also refs wa-iy9s8" "wa-iy9s8"                                        # trailing reference
# FAIL-CLOSED edges:
rc1 subject_impl_scopes_bead "merge wa-iy9s8 into main" "wa-iy9s8"                         # NO colon → no locatable scope → reject
rc1 subject_impl_scopes_bead 'Revert "fix(wa-iy9s8): add thing"' "wa-iy9s8"                # git default revert → undo, not delivery
rc1 subject_impl_scopes_bead "revert: fix(wa-iy9s8): add thing" "wa-iy9s8"                 # conventional revert → reject
rc1 subject_impl_scopes_bead "fix(wa-1or2): unrelated longer id" "wa-1"                    # token boundary: wa-1 ≠ wa-1or2

# ── 3. merge-evidence helpers — real git, no network ────────────────────────
echo "── 3. scan_commit_for_bead + branch_merged (real repo) ──"
export GIT_AUTHOR_NAME=selftest  GIT_AUTHOR_EMAIL=selftest@local
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local
T="$(mktemp -d 2>/dev/null || mktemp -d -t gatijv5)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
R="$T/repo"
git init -q -b main "$R"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -q -m "C1 base" )
# A mirror-style commit: subject says feat(refino), body references the WA bead.
( cd "$R" && echo b > b.txt && git add b.txt && \
  git commit -q -m "feat(refino): add simplified mode" -m "Mirrors WA bead tt-1or2 (source ga-mirror)." )
MIRROR_SHA=$(git -C "$R" rev-parse --short=9 HEAD)
# A short-id commit to test the boundary (tt-1 is its own token here).
( cd "$R" && echo c > c.txt && git add c.txt && git commit -q -m "fix(tt-1): boundary token" )

# scan: bead id present in body (mirror) → found, prints the sha.
GOT=$(scan_commit_for_bead "$R" 0 "main" "tt-1or2" 2>/dev/null || true)
if [ -n "$GOT" ]; then ok "scan finds mirror-body id tt-1or2 (sha=${GOT:0:9})"; else bad "scan missed mirror-body id tt-1or2"; fi
# boundary: tt-1 is a real token in 'fix(tt-1)' → found; but must NOT match inside tt-1or2.
rc0 scan_commit_for_bead "$R" 0 "main" "tt-1"
# absent id → not found.
rc1 scan_commit_for_bead "$R" 0 "main" "tt-zzzz"
# bad ref → rc1 (never crashes the sweep).
rc1 scan_commit_for_bead "$R" 0 "refs/heads/does-not-exist" "tt-1or2"

# branch_is_fresh (ga-tijv5 extension) — HEAD was committed "now" by this test.
eq "just-committed tip is fresh (7d)"   "$(branch_is_fresh "$R" 0 "main" 7)" "1"
eq "zero-day window → not fresh"        "$(branch_is_fresh "$R" 0 "main" 0)" "0"
eq "unknown ref date → not fresh"       "$(branch_is_fresh "$R" 0 "refs/heads/does-not-exist" 7)" "0"

# ── 3b. scan_commit_subject_for_bead — STRICT (subject only), ga-gosfs ───────
# Rejects incidental BODY mentions of a still-open story (the ga-r471 / wa-qggy
# false-positive class) while still finding genuine implementing-commits whose
# id is in the conventional-commit SUBJECT scope.
echo "── 3b. scan_commit_subject_for_bead (strict subject scope) ──"
# tt-1or2 lives ONLY in the mirror commit's BODY → strict scan must NOT find it.
rc1 scan_commit_subject_for_bead "$R" 0 "main" "tt-1or2"
# tt-1 is in the SUBJECT 'fix(tt-1): …' → strict scan FINDS it (genuine impl commit).
rc0 scan_commit_subject_for_bead "$R" 0 "main" "tt-1"
GOTS=$(scan_commit_subject_for_bead "$R" 0 "main" "tt-1" 2>/dev/null || true)
if [ -n "$GOTS" ]; then ok "strict scan prints sha for subject-scoped tt-1 (sha=${GOTS:0:9})"; else bad "strict scan missed subject-scoped tt-1"; fi
# absent id → not found; bad ref → rc1 (never crashes the sweep).
rc1 scan_commit_subject_for_bead "$R" 0 "main" "tt-zzzz"
rc1 scan_commit_subject_for_bead "$R" 0 "refs/heads/does-not-exist" "tt-1"
# Regression: a commit that names the bead in its body as STILL-OPEN/future work
# (verbatim shape of the ga-r471 + wa-qggy false positives) → strict scan REJECTS.
( cd "$R" && echo e > e.txt && git add e.txt && \
  git commit -q -m "fix(tt-other): rescope budget cap" \
                -m "enforcement moves to tt-future (after tt-acct); remains open in tt-future engine window" )
rc1 scan_commit_subject_for_bead "$R" 0 "main" "tt-future"   # body-only future mention → NOT done
rc0 scan_commit_for_bead         "$R" 0 "main" "tt-future"   # body scan WOULD match (shows why strict is needed)

# branch_merged: topic branch that IS an ancestor of main vs one that is not.
git -C "$R" branch merged-topic HEAD~1     # points at the mirror commit (ancestor of main)
git -C "$R" checkout -q -b ahead-topic main
( cd "$R" && echo d > d.txt && git add d.txt && git commit -q -m "ahead-only commit" )
git -C "$R" checkout -q main
rc0 branch_merged "$R" 0 "merged-topic" "main"     # ancestor → merged
rc1 branch_merged "$R" 0 "ahead-topic"  "main"     # has commit not in main → not merged
rc1 branch_merged "$R" 0 "no-such-branch" "main"   # missing branch → not merged (safe)
# ga-tijv5 regression: the degenerate self-referential check (bref == mref) must NOT
# count as merged. A bad marker-label / fold-linkage that resolved the branch to "main"
# itself made "main ⊑ main" trivially true and FALSE-closed an in_progress bead whose
# real crew branch was AHEAD of main, unmerged (wa-85iv8 2026-06-30).
rc1 branch_merged "$R" 0 "main" "main"             # main vs main → degenerate, NOT merged
rc1 branch_merged "$R" 0 ""     "main"             # empty bref → not merged (safe)

# ── 3c. content_in_main — SQUASH-AWARE merge detection (the wa-fvxj1 fix) ────
# A crew branch whose tip is NOT a git ancestor of main (a new sha) but whose
# entire diff is already in main via a SQUASH / re-commit. branch_merged (strict
# ancestry) says "not merged"; content_in_main correctly says "merged" (lossless to
# prune). The NEGATIVE direction — a branch with a UNIQUE patch not in main — MUST
# return "not merged" so the janitor never green-lights deleting real work.
echo "── 3c. content_in_main (squash-aware merge detection) ──"
# Build the squash case: crew branch commits a change; main RE-COMMITS the same diff
# under a new sha (exactly what a squash-merge / re-land produces — cf. wa-fvxj1's
# feat(warming/wa-fvxj1) re-commit). Tip != ancestor, but content present in main.
git -C "$R" checkout -q -b crew/x/tt-squash main
( cd "$R" && printf 'squash-feature\n' > squash.txt && git add squash.txt && git commit -q -m "work(tt-squash): feature on crew branch" )
git -C "$R" checkout -q main
( cd "$R" && printf 'squash-feature\n' > squash.txt && git add squash.txt && git commit -q -m "feat(warm/tt-squash): re-land squashed lane" )
# Sanity: strict ancestry says NOT merged (tip is a different sha) …
rc1 branch_merged   "$R" 0 "crew/x/tt-squash" "main"    # strict ancestry → NOT merged
# … but the CONTENT is fully in main (patch-equivalent) → content_in_main rc0.
rc0 content_in_main "$R" 0 "crew/x/tt-squash" "main"    # squash-aware → MERGED (lossless)
# strict ahead is >0 — this is precisely why the ahead==0 gate ALONE never pruned it.
eq "squash branch strict-ahead > 0" "$(git -C "$R" rev-list --count main..crew/x/tt-squash)" "1"
# NEGATIVE direction (the destructive case): a branch with a UNIQUE patch not in main
# must be reported NOT merged — content_in_main must NEVER green-light a delete of it.
# ahead-topic (built in §3b) carries a unique "ahead-only commit" (d.txt) not in main.
rc1 content_in_main "$R" 0 "ahead-topic" "main"         # unique patch → NOT merged (KEEP)
# A strict-ancestor branch is trivially content-in-main.
rc0 content_in_main "$R" 0 "merged-topic" "main"        # ancestor → merged
# Degenerate / bad inputs → NOT merged (fail-closed); never crash the sweep.
rc1 content_in_main "$R" 0 "main" "main"                # self-check (bref==mref) rejected
rc1 content_in_main "$R" 0 ""     "main"                # empty bref
rc1 content_in_main "$R" 0 "no-such-branch" "main"      # unresolvable ref

# ── 3d. commit_epoch — live-git committer-date lookup (ga-2zp4h) ───────────
# Feeds commit_evidence_stale: the sha Signal A matched must resolve to ITS OWN
# committer-date epoch so the janitor can compare it against the bead's comments.
echo "── 3d. commit_epoch (real git, feeds commit_evidence_stale) ──"
WANT_EPOCH=$(git -C "$R" log -1 --format='%ct' "$MIRROR_SHA")
eq "commit_epoch matches raw git %ct for a real sha" \
   "$(commit_epoch "$R" 0 "$MIRROR_SHA")" "$WANT_EPOCH"
rc1 commit_epoch "$R" 0 "0000000000000000000000000000000000000000"   # unresolvable sha
rc1 commit_epoch "$R" 0 ""                                            # empty sha

# ── 4. marker JSON helpers — synthetic fixtures ─────────────────────────────
echo "── 4. marker helpers ──"
M_OPEN='[{"status":"open","labels":["gate-status:queued","source-bead:wa-lstd","branch:crew/mila/wa-lstd"]}]'
M_PASSED='[{"status":"closed","labels":["gate-status:passed","source-bead:x"]}]'
M_SUPER='[{"status":"closed","labels":["gate-status:superseded","source-bead:x"]}]'
M_FAILED='[{"status":"closed","labels":["gate-status:failed","source-bead:x"]}]'
M_MIXED='[{"status":"open","labels":["gate-status:ready"]},{"status":"closed","labels":["gate-status:superseded"]}]'
M_EMPTY='[]'
rc0 has_open_marker "$M_OPEN"
rc1 has_open_marker "$M_PASSED"
rc1 has_open_marker "$M_EMPTY"
rc0 has_open_marker "$M_MIXED"                       # wa-ab6z shape: open ready + closed superseded → kept
rc0 has_terminal_passed_marker "$M_PASSED"
rc1 has_terminal_passed_marker "$M_SUPER"            # ga-v8ui5: superseded is NOT passed — the opposite (branch discarded)
rc1 has_terminal_passed_marker "$M_FAILED"           # closed-FAILED is NOT merged → no close signal
rc1 has_terminal_passed_marker "$M_OPEN"
rc1 has_terminal_passed_marker "$M_EMPTY"
# has_terminal_superseded_marker (ga-v8ui5) — distinguishable, NON-closing signal.
rc0 has_terminal_superseded_marker "$M_SUPER"
rc1 has_terminal_superseded_marker "$M_PASSED"
rc1 has_terminal_superseded_marker "$M_FAILED"
rc1 has_terminal_superseded_marker "$M_OPEN"
rc1 has_terminal_superseded_marker "$M_EMPTY"
eq "branch label extracted" "$(branch_label_from_markers "$M_OPEN")" "crew/mila/wa-lstd"
eq "no branch label → empty" "$(branch_label_from_markers "$M_PASSED")" ""

# ── 4b. commit_evidence_stale — synthetic comment fixtures (ga-2zp4h) ───────
# The real wa-d3136 shape: the false-closing commit landed 2026-07-24T22:29:53-03:00
# (epoch 1784942993); mila's reassignment comment landed 2026-07-26T03:13:51Z (epoch
# 1785035631) — a full day later. These are the ACTUAL production timestamps that
# reproduced the false-close (verified live against wa-d3136 + commit cd4c6f058).
echo "── 4b. commit_evidence_stale (comment-postdates-commit guard) ──"
CWA='[{"created_at":"2026-07-26T03:13:51Z"}]'
rc0 commit_evidence_stale "$CWA" 1784942993          # real wa-d3136 timestamps → STALE
rc1 commit_evidence_stale "$CWA" 1785200000          # comment BEFORE commit epoch → not stale
# Multiple comments: ANY one newer than the commit epoch is enough to flag stale.
CMULTI='[{"created_at":"2026-07-20T00:00:00Z"},{"created_at":"2026-07-27T00:00:00Z"}]'
rc0 commit_evidence_stale "$CMULTI" 1785000000
# No comments at all (the comment_count=0 shape: `bd comments <id> --json` → []).
rc1 commit_evidence_stale "[]" 1784942993
# FAIL-OPEN directions (ga-2zp4h design: never invent a false "stale" from bad input —
# preserves today's Signal-A behaviour rather than a new way to go silent on a merge).
rc1 commit_evidence_stale "$CWA" ""                                    # empty commit_epoch
rc1 commit_evidence_stale "$CWA" "not-a-number"                        # non-numeric commit_epoch
rc1 commit_evidence_stale "not json" 1784942993                        # unparseable comments blob
rc1 commit_evidence_stale '[{"created_at":"not-a-date"}]' 1784942993   # unparseable created_at

# ── 5. rig_gitdir — container (.repo.git) vs self-repo selection ────────────
echo "── 5. rig_gitdir ──"
SR="$T/selfrepo"; mkdir -p "$SR/.git"
CR="$T/container"; mkdir -p "$CR/.repo.git"
eq "self-repo → working tree, container=0" "$(rig_gitdir "$SR")" "$(printf '%s\t0' "$SR")"
eq "container → bare .repo.git, container=1" "$(rig_gitdir "$CR")" "$(printf '%s/.repo.git\t1' "$CR")"

# ── 6. Drift-guard: the live janitor wires the contract ─────────────────────
echo "── 6. drift-guard: janitor + plist wiring ──"
grep -q 'JANITOR_LIB_ONLY' "$JANITOR"            && ok "janitor sourceable in lib-only mode"     || bad "missing lib-only hook"
grep -q 'janitor_decide()' "$JANITOR"            && ok "defines janitor_decide"                  || bad "missing janitor_decide def"
grep -q 'scan_commit_for_bead()' "$JANITOR"      && ok "defines scan_commit_for_bead"            || bad "missing scan_commit_for_bead def"
grep -q 'epic-parent-never-autoclosed' "$JANITOR" && ok "epic guard present"                     || bad "epic guard missing"
grep -q 'active-open-gate-marker' "$JANITOR"     && ok "open-marker guard present"               || bad "open-marker guard missing"
grep -q 'label remove "$BID" "story:in-flight"' "$JANITOR" && ok "drops story:in-flight on close" || bad "story:in-flight removal missing"
grep -q 'JANITOR_DRY_RUN' "$JANITOR"             && ok "dry-run supported"                       || bad "dry-run support missing"
grep -q 'gate-status:passed' "$JANITOR"          && ok "terminal signal checks passed"           || bad "passed marker label missing"
# ga-v8ui5: superseded must NOT be OR'd into has_terminal_passed_marker — it is the
# opposite of passed (a discarded/replaced branch), not a merge signal. Assert the negative.
grep -qF 'or . == "gate-status:superseded"' "$JANITOR" \
  && bad "has_terminal_passed_marker still ORs in gate-status:superseded (ga-v8ui5 regression)" \
  || ok "has_terminal_passed_marker no longer treats superseded as passed"
# Branch-prune extension (ga-tijv5, 2026-07-01) — wired, conservative, and STAGED (off by default).
grep -q 'janitor_branch_decide()' "$JANITOR"     && ok "defines janitor_branch_decide"           || bad "missing janitor_branch_decide def"
grep -q 'PRUNE_BRANCHES="${JANITOR_PRUNE_BRANCHES:-0}"' "$JANITOR" && ok "branch-prune is OPT-IN, default OFF (staged)" || bad "branch-prune not default-off"
grep -q 'if \[ "$PRUNE_BRANCHES" = "1" \]' "$JANITOR" && ok "branch-prune sweep gated behind PRUNE_BRANCHES" || bad "branch-prune sweep not gated"
grep -q 'has-unmerged-commits' "$JANITOR"        && ok "never prunes unique content (ahead>0 & cim!=1)" || bad "unmerged-commits guard missing"
grep -q 'bead-read-error-failopen' "$JANITOR"    && ok "fail-open on bad bead read"              || bad "fail-open guard missing"
grep -q 'recheck content-in-main' "$JANITOR"     && ok "re-verifies content-in-main at delete time" || bad "delete-time content-in-main recheck missing"
grep -q 'BRANCH_PRUNE_MAX_PER_SWEEP' "$JANITOR"  && ok "per-sweep deletion cap present"          || bad "deletion cap missing"
# Squash-aware merge detection (the wa-fvxj1 fix): content_in_main via patch-id
# equivalence recognises a squash/re-commit (ahead>0 by sha, content in main).
grep -q 'content_in_main()' "$JANITOR"           && ok "defines content_in_main (squash-aware)"  || bad "missing content_in_main def"
grep -q 'cherry-pick --right-only' "$JANITOR"    && ok "uses git patch-id equivalence (--cherry-pick)" || bad "cherry-pick content check missing"
grep -q 'squash-merged-and-bead-closed' "$JANITOR" && ok "squash-merged prune reason wired"      || bad "squash prune reason missing"
grep -q 'janitor_branch_decide "\$AHEAD" "\$CIM"' "$JANITOR" && ok "branch decider fed content-in-main (CIM) signal" || bad "branch decider not passed CIM"
grep -q 'prune="--prune"' "$JANITOR" && grep -q 'PRUNE_BRANCHES" = "1" \] && prune' "$JANITOR" \
  && ok "fetch --prune gated behind PRUNE_BRANCHES (staged; no stale refs when active)" || bad "fetch prune gating missing"
grep -q 'remote moved since decision' "$JANITOR" && ok "delete-time remote-SHA CAS guard present" || bad "remote-SHA CAS guard missing"
# STAGED, not deployed: the plist must NOT enable branch pruning (the Mayor's deploy step).
if grep -q 'JANITOR_PRUNE_BRANCHES' "$PLIST" 2>/dev/null; then bad "plist must NOT enable branch prune (staging violated)"; else ok "plist does NOT enable branch prune (correctly staged)"; fi
# Cross-store: own-rig repo scan falls back to HQ repo (mirror case) using strict subject scan.
grep -q 'scan_commit_subject_for_bead "$HQ_GITDIR"' "$JANITOR" && ok "cross-store HQ-repo mirror scan wired (strict)" || bad "HQ-repo mirror scan missing or not strict"
# The in_progress sweep MUST use the strict subject scanner (not the body scanner) for
# signal A — guards against the wa-oxkg false-positive class: an unrelated commit that
# merely MENTIONS a bead id in its body (incident description, cross-ref) must NOT close
# that bead. Only a conventional-commit scoped as feat(<id>)/fix(<id>)/etc. in the SUBJECT
# qualifies as delivery evidence.
grep -q 'scan_commit_subject_for_bead "\$RGITDIR" "\$RCONTAINER" "origin/\$RDEFAULT" "\$BID"' "$JANITOR" \
  && ok "in_progress sweep uses strict subject scan for BID" || bad "in_progress sweep not using strict scanner for BID"
# ga-wisp-ld35wuw (2026-07-01): SCOPE discriminator + own-rig-repo scoping (the wa-iy9s8 fix).
# The false-close was an HQ `fix(pilot): … (ga-4aree/wa-iy9s8)` commit whose SUBJECT carried the
# rig id in a TRAILING context paren; the whole-subject scanner matched it and auto-closed the P1
# bug. Signal A now (a) requires the id to be the SUBJECT SCOPE (header before the first colon)
# via subject_impl_scopes_bead, and (b) matches a RIG-NATIVE bead ONLY against its own rig repo.
grep -q 'subject_impl_scopes_bead()' "$JANITOR" \
  && ok "defines subject_impl_scopes_bead (scope discriminator)" || bad "missing subject_impl_scopes_bead def"
grep -qF 'if subject_impl_scopes_bead "$subj" "$id"' "$JANITOR" \
  && ok "scan_commit_subject_for_bead gated on subject SCOPE (not whole-subject token)" || bad "scanner not using subject_impl_scopes_bead"
grep -qF '[ "${BID%%-*}" != "$RPREFIX" ]' "$JANITOR" \
  && ok "in_progress HQ fallback prefix-guarded (rig-native bead never matched vs HQ)" || bad "in_progress HQ fallback not prefix-guarded"
grep -qF '[ "${SID%%-*}" != "$RPREFIX" ]' "$JANITOR" \
  && ok "story HQ fallback prefix-guarded (rig-native story never matched vs HQ)" || bad "story HQ fallback not prefix-guarded"
# set -e/pipefail safety: no `set -e` (sweep tolerates per-bead failures) but
# the close path guards its mutation with `|| { err ...; continue; }`.
grep -q 'close failed for' "$JANITOR" && ok "close failure is non-fatal (continue)" || bad "close failure not guarded"
# ga-gosfs: story:done reconciliation sweep wiring.
grep -q 'janitor_story_decide()' "$JANITOR" && ok "defines janitor_story_decide"     || bad "missing janitor_story_decide def"
grep -q 'scan_commit_subject_for_bead()' "$JANITOR" && ok "defines strict subject scanner" || bad "missing scan_commit_subject_for_bead def"
# The story sweep MUST use the strict subject scanner (not the body scanner) for
# signal A — guards against the ga-r471/wa-qggy incidental-body-mention class.
grep -q 'scan_commit_subject_for_bead "\$RGITDIR" "\$RCONTAINER" "origin/\$RDEFAULT" "\$SID"' "$JANITOR" \
  && ok "story sweep uses strict subject scan for SID" || bad "story sweep not using strict scanner"
grep -q 'label add "\$SID" "story:done"' "$JANITOR" && ok "story sweep sets story:done" || bad "story:done transition missing"
grep -q 'already-story-done' "$JANITOR"          && ok "story idempotency guard present" || bad "story already-done guard missing"
grep -q 'delivery-owns-it' "$JANITOR"            && ok "delivery-active guard present"   || bad "delivery guard missing"
grep -q 'story-in-flight-active-rework' "$JANITOR" && ok "story in-flight guard present" || bad "story in-flight guard missing"
# The story sweep must select OPEN story:approved beads (the stuck-merged shape),
# distinct from the in_progress sweep above.
grep -q 'list --status open --json -l story:approved' "$JANITOR" \
  && ok "story sweep selects open story:approved" || bad "story sweep selector missing"
# ga-<story-close>: durable terminal — story sweep must also remove story:approved and CLOSE
# the bead (not just add story:done label). Absence of close left wa-7nz9l + wa-14w76 in
# Aprovadas for 36h+ even after story:done was added. story-delivery.sh L886 explicitly
# delegates the close to the janitor: "merged-bead-janitor backstops the close".
grep -q 'label remove "\$SID" "story:approved"' "$JANITOR" \
  && ok "story sweep removes story:approved (exits Aprovadas)" || bad "story:approved removal missing from story sweep"
grep -q 'close "\$SID" -r "\$JCLOSE_MSG"' "$JANITOR" \
  && ok "story sweep closes bead with delivery close_reason" || bad "story sweep missing close (bead stays open = Aprovadas inflation)"
# Orphan-close backstop: beads that already have story:done but are still open (prior janitor
# pass added the label but missed the close) must also be driven to the durable terminal.
grep -q 'ORPHAN-CLOSED' "$JANITOR" \
  && ok "orphan-close backstop present (already-story-done + open → close)" || bad "orphan-close backstop missing"
grep -q "S_REASON.*already-story-done.*S_EPIC.*0\|already-story-done.*S_EPIC" "$JANITOR" \
  && ok "orphan-close guards epic exclusion" || bad "orphan-close missing epic guard"
# plist drift.
grep -q 'com.gascity.merged-bead-janitor' "$PLIST" && ok "plist Label correct"        || bad "plist Label wrong"
grep -q '<key>StartInterval</key>' "$PLIST"        && ok "plist uses StartInterval"    || bad "plist missing StartInterval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST"     && ok "plist RunAtLoad=true"        || bad "plist missing RunAtLoad"

# ── 7. Signal A tightening: body-only mention must NOT close; scoped subject MUST ──
# Regression scenario for the wa-oxkg false-positive (2026-06-22):
#   commit 2adc87e3f had subject fix(pilot): … and mentioned "wa-oxkg" only in the
#   BODY (incident description). The original scan_commit_for_bead (body-wide) matched
#   it and falsely closed wa-oxkg. The fix: Signal A now uses scan_commit_subject_for_bead
#   which requires the bead id to be the conventional-commit SCOPE in the SUBJECT line.
echo "── 7. Signal A tightening: body-mention → KEEP; subject-scoped → CLOSE ──"
# Build a fresh repo with two commits that model the wa-oxkg incident:
#   C_INCIDENT: unrelated fix, body MENTIONS the bead id — must NOT trigger close.
#   C_DELIVERY: scoped feat(<id>): …  — MUST trigger close.
T7="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t7)"
trap 'rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R7="$T7/repo7"
git init -q -b main "$R7"
# Baseline commit.
( cd "$R7" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# Incident commit: subject is about pilot, body mentions tt-oxkg as context only.
# This models fix(pilot): … whose body says "a tt-oxkg dispatch surfaced mid-conversation".
( cd "$R7" && echo pilot > pilot.txt && git add pilot.txt && \
  git commit -q -m "fix(pilot): never dispatch into a human-attached crew" \
               -m "TWO dispatch-protection fixes from an incident where a tt-oxkg dispatch surfaced mid-conversation in peter-wa's session while Athos was working WITH peter." )
INCIDENT_SHA=$(git -C "$R7" rev-parse HEAD)
# Delivery commit: subject IS scoped to tt-oxkg — this is the genuine delivery.
( cd "$R7" && echo delivery > delivery.txt && git add delivery.txt && \
  git commit -q -m "feat(tt-oxkg): implement whatsapp automation component" )
DELIVERY_SHA=$(git -C "$R7" rev-parse HEAD)

# Assertion A: strict subject scan must NOT match the incident commit for tt-oxkg
#   (id appears only in body — unrelated commit). This is the wa-oxkg false-positive class.
rc1 scan_commit_subject_for_bead "$R7" 0 "$INCIDENT_SHA" "tt-oxkg"   # body-only — must NOT close

# Assertion B: strict subject scan MUST match the delivery commit for tt-oxkg
#   (id is the conventional-commit scope in the subject line — genuine delivery).
rc0 scan_commit_subject_for_bead "$R7" 0 "main" "tt-oxkg"   # subject-scoped — MUST close
GOTT=$(scan_commit_subject_for_bead "$R7" 0 "main" "tt-oxkg" 2>/dev/null || true)
WANT_SHA=$(git -C "$R7" rev-parse --short=9 "$DELIVERY_SHA")
if [ "${GOTT:0:9}" = "$WANT_SHA" ]; then
  ok "strict scan returns DELIVERY sha for tt-oxkg (${GOTT:0:9}), not incident sha"
else
  bad "strict scan returned wrong sha for tt-oxkg: got [${GOTT:0:9}], want [$WANT_SHA]"
fi

# Assertion C: the LOOSE body scan WOULD match (shows why strict is needed and
#   why the old code was broken — this assertion validates the test setup).
rc0 scan_commit_for_bead "$R7" 0 "main" "tt-oxkg"   # body scan finds incident mention (loose)

# Assertion D: a different bead id mentioned only in the incident commit body is
#   also rejected by the strict scan (cross-contamination guard).
( cd "$R7" && echo extra > extra.txt && git add extra.txt && \
  git commit -q -m "chore(housekeeping): tidy up" \
               -m "see also: tt-other bead that was incidentally referenced here" )
rc1 scan_commit_subject_for_bead "$R7" 0 "main" "tt-other"   # body-only in chore body → keep

# Assertion E: signal C (branch ancestor) still works alongside the tightened signal A —
#   a crew/<rig>/<id> branch that is merged qualifies via branch_merged independent of
#   whether any commit subject is scoped to the bead. This ensures the tightened signal A
#   does not blind us to real merges that lack a scoped-subject commit.
git -C "$R7" checkout -q -b "crew/mila/tt-oxkg" HEAD~2   # points at base+incident (pre-delivery)
git -C "$R7" checkout -q main
rc0 branch_merged "$R7" 0 "crew/mila/tt-oxkg" "main"   # crew branch IS ancestor of main → signal C fires

# ── 7b. wa-iy9s8 REGRESSION: trailing-context SUBJECT paren must NOT close (ga-wisp-ld35wuw) ──
# The wa-iy9s8 false-close (2026-07-01) was NOT a body mention — the id was in the SUBJECT, but
# as a TRAILING context paren "(ga-4aree/wa-iy9s8)" of a fix(pilot): framework commit in HQ. The
# then-current scan_commit_subject_for_bead token-bounded the WHOLE subject → it matched and the
# in_progress sweep auto-closed the P1 bug. The fix requires the id to be the SUBJECT SCOPE
# (header before the first colon). This section builds the exact shape in a real repo.
echo "── 7b. trailing-context subject paren (wa-iy9s8 shape) → KEEP; scoped → CLOSE ──"
T7B="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t7b)"
trap 'rm -rf "$T7B" 2>/dev/null || true; rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R7B="$T7B/repo7b"
git init -q -b main "$R7B"
( cd "$R7B" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# CONTEXT commit — models 286cb29c7-HQ: fix(pilot): … with the rig bead-id in a TRAILING paren.
( cd "$R7B" && echo pilot > pilot.txt && git add pilot.txt && \
  git commit -q -m "fix(pilot): rig-native scan no longer excludes gate:needs-fix — rig re-fix bugs dispatch (ga-4aree/tt-iy9s8)" )
CTX_SHA=$(git -C "$R7B" rev-parse HEAD)
# DELIVERY commit — models d0219063-WA: the genuine fix(tt-iy9s8): implementing commit.
( cd "$R7B" && echo deliver > deliver.txt && git add deliver.txt && \
  git commit -q -m "fix(tt-iy9s8): auto-deploy viewer/ to S3 on merge — done != deployed" )
DLV_SHA=$(git -C "$R7B" rev-parse --short=9 HEAD)
# STRICT scanner: the trailing-context paren commit must NOT be treated as delivery …
rc1 scan_commit_subject_for_bead "$R7B" 0 "$CTX_SHA" "tt-iy9s8"   # trailing "(…/tt-iy9s8)" → KEEP (the bug)
# … but the genuine fix(tt-iy9s8): scope commit MUST be, and returns ITS sha (not the context one).
rc0 scan_commit_subject_for_bead "$R7B" 0 "main" "tt-iy9s8"
GOTB=$(scan_commit_subject_for_bead "$R7B" 0 "main" "tt-iy9s8" 2>/dev/null || true)
if [ "${GOTB:0:9}" = "$DLV_SHA" ]; then ok "strict scan returns DELIVERY sha (${GOTB:0:9}), not the context commit"; else bad "strict scan wrong sha: got [${GOTB:0:9}] want [$DLV_SHA]"; fi
# The OLD loose behaviour (token-bounded WHOLE subject) WOULD have matched the context commit —
# this asserts the test setup reproduces the real false-positive that the fix removes.
ctx_subj=$(git -C "$R7B" log -1 --format='%s' "$CTX_SHA")
rc0 token_bounded "tt-iy9s8" "$ctx_subj"                          # loose whole-subject match (why the fix was needed)


# ── 8. story:done + close: subject-scoped commit in main → DONE verdict; body-only → KEEP ──
# Regression scenario for wa-7nz9l / wa-14w76 (2026-06-26):
#   Beads had fix(wa-7nz9l): / fix(wa-14w76): commits in origin/main.
#   janitor_story_decide correctly returned "done:commit-in-origin-main" — the pure
#   function was fine. The sweep ACTION then added story:done label but did NOT close
#   the bead or remove story:approved → beads stayed open + story:approved in Aprovadas
#   for 36h+ until Mayor fixed manually. Fix: sweep now does story:done + remove
#   story:approved + close (mirrors story-delivery ga-i53ua).
#   These tests confirm:
#   (A) subject-scoped commit (genuine delivery) → janitor_story_decide returns "done"
#   (B) body-only mention (incidental) → janitor_story_decide returns "keep"
#   (C) already-story-done bead (open, prior pass) → janitor_story_decide still
#       returns "keep:already-story-done" (pure fn unchanged); orphan-close fires in sweep
echo "── 8. story:done scenario: subject-scoped in main → done; body-only → keep; already-done → keep ──"

# (A) no open-marker, no rework, sig_commit=1 → should be done
eq "wa-7nz9l shape: sig_commit + no guards → done" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0)" \
   "done:commit-in-origin-main"

# (B) no merge evidence at all → keep
eq "body-only mention (not in subject) → keep:no-merge-evidence" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0)" \
   "keep:no-merge-evidence"

# (C) already has story:done (S_DONE=1) even with all sig_* set → "keep:already-story-done"
#     The sweep detects this and fires orphan-close (covered by drift-guard above).
eq "already-story-done beats merge signals → keep (orphan-close covers terminal)" \
   "$(janitor_story_decide 0 0 1 0 0 0 1 1 1)" \
   "keep:already-story-done"

# (D) SECURITY: has story:done + an ACTIVE open gate-marker → active-open-gate-marker WINS
#     (NOT already-story-done). A stale story:done label must NOT let the orphan-close backstop
#     close a bead that is back under active review. Active-work guards precede already_done.
eq "open-marker beats stale already-done (no false-close)" \
   "$(janitor_story_decide 0 1 1 0 0 0 0 0 0)" \
   "keep:active-open-gate-marker"
eq "in-flight beats stale already-done (rework not false-closed)" \
   "$(janitor_story_decide 0 0 1 1 0 0 0 0 0)" \
   "keep:story-in-flight-active-rework"

# (E) in-flight guard must NOT be bypassed by story:done when NOT already done
#     (a bead currently being built: in-flight=1, done=0, sig_commit=1 — mid-gate).
eq "in-flight active (not yet done): in-flight guard wins over commit signal" \
   "$(janitor_story_decide 0 0 0 1 0 0 1 0 0)" \
   "keep:story-in-flight-active-rework"

# ── 9. Drift-guard: ga-hcj4 stranded open+story:in-flight sweep ─────────────
# Pilot's "fix bug X" sling-wrapper convention leaves the underlying bug/task
# bead (or a story whose gate-PASS handoff never stripped the label) stuck
# status=open + story:in-flight FOREVER — it is never itself in_progress and
# never carries story:approved, so it fell into NEITHER sweep above no matter
# how long its own scoped commit sat merged in origin/main (ga-ap7od: confirmed
# merged 1h48m past a healthy 15min sweep cadence, invisible because the
# WRAPPER, not the bead, was the in_progress row). This bucket reuses
# janitor_decide UNCHANGED (already exhaustively covered by §1 above) — these
# assertions confirm the LIVE script wires a THIRD candidate query into that
# same pure decision, with the same false-close defenses (strict subject-scope,
# repo-scoping, branch self-guard) as the in_progress sweep, not a fresh or
# looser decision path.
echo "── 9. Drift-guard: ga-hcj4 stranded open+story:in-flight sweep ──"
grep -qF 'list --status open --json -l story:in-flight' "$JANITOR" \
  && ok "queries open+story:in-flight beads (third bucket)" || bad "open+story:in-flight query missing"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH"' "$JANITOR" \
  && ok "in-flight bucket reuses janitor_decide unchanged (no parallel decision fn)" || bad "in-flight bucket does not call janitor_decide"
grep -qF 'scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$FID"' "$JANITOR" \
  && ok "in-flight signal A uses the STRICT subject scanner (not the loose one)" || bad "in-flight bucket not using strict subject scanner"
grep -qF 'sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$FID")' "$JANITOR" \
  && ok "in-flight signal A falls back to HQ mirror scan" || bad "in-flight HQ mirror fallback missing"
grep -qF '[ "${FID%%-*}" != "$RPREFIX" ]' "$JANITOR" \
  && ok "in-flight commit signal is rig-scoped (HQ fallback only for foreign ids)" || bad "in-flight repo-scoping guard missing"
grep -qF 'case "$br" in */"$FID") : ;; *) continue ;; esac' "$JANITOR" \
  && ok "in-flight branch signal keeps the final-path-segment self-guard" || bad "in-flight branch self-guard missing"
grep -qF 'CLOSED-INFLIGHT' "$JANITOR" && ok "in-flight close action logs CLOSED-INFLIGHT" || bad "in-flight close logging missing"
grep -qF 'label remove "$FID" "story:in-flight"' "$JANITOR" \
  && ok "in-flight close drops story:in-flight (mirrors in_progress sweep)" || bad "in-flight story:in-flight removal missing"
grep -qF 'INFLIGHT_CLOSED_COUNT=$((INFLIGHT_CLOSED_COUNT+1))' "$JANITOR" \
  && ok "in-flight closes counted" || bad "in-flight close counter missing"
grep -qF 'INFLIGHT_CLOSED_COUNT" -gt 0' "$JANITOR" && ok "in-flight closes surfaced via notify_athos" || bad "in-flight notify wiring missing"
grep -qF 'WOULD-CLOSE-INFLIGHT' "$JANITOR" && ok "in-flight bucket honors DRY_RUN" || bad "in-flight dry-run path missing"

# ── 10. Drift-guard: ga-2zp4h joint/split-bead stale-comment guard ──────────
# wa-d3136 false-close: Signal A matched a LEGITIMATE subject-scoped commit that was
# actually the delivery of a DIFFERENT (split-off sibling) bead (wa-eda28) — the bead
# was reassigned to a second owner via a comment a full day AFTER that commit landed,
# and his half was never built, yet the janitor closed the shared parent anyway. The
# guard: a bead comment postdating the matched commit suppresses signal A ALONE. It
# must be wired into ALL THREE call sites that use janitor_decide/janitor_story_decide
# (in_progress, ga-hcj4 stranded-wrapper, story:approved) — missing even one leaves
# that bucket vulnerable to the exact same false-close.
echo "── 10. Drift-guard: ga-2zp4h joint/split-bead stale-comment guard ──"
grep -q 'commit_epoch()' "$JANITOR" && ok "defines commit_epoch" || bad "missing commit_epoch def"
grep -q 'commit_evidence_stale()' "$JANITOR" && ok "defines commit_evidence_stale" || bad "missing commit_evidence_stale def"
grep -q 'comments_for_bead()' "$JANITOR" && ok "defines comments_for_bead" || bad "missing comments_for_bead def"
grep -qF 'sig_commit_stale="${6:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional sig_commit_stale (backward-compatible default)" || bad "janitor_decide missing sig_commit_stale param"
grep -qF 'sig_commit_stale="${10:-0}"' "$JANITOR" \
  && ok "janitor_story_decide accepts optional sig_commit_stale (backward-compatible default)" || bad "janitor_story_decide missing sig_commit_stale param"
grep -qF 'commit-evidence-superseded-by-newer-comment' "$JANITOR" \
  && ok "stale-suppression keep reason present" || bad "stale-suppression keep reason missing"
# All THREE call sites must thread SIG_COMMIT_STALE into janitor_decide/janitor_story_decide.
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE"' "$JANITOR" \
  && ok "in_progress sweep threads sig_commit_stale into janitor_decide" || bad "in_progress sweep not threading sig_commit_stale"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads sig_commit_stale into janitor_decide" || bad "ga-hcj4 sweep not threading sig_commit_stale"
grep -qF '"$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE"' "$JANITOR" \
  && ok "story sweep threads sig_commit_stale into janitor_story_decide" || bad "story sweep not threading sig_commit_stale"
# Signal C must gate on a TRUSTED flag (not raw SIG_COMMIT) at all three call sites, so a
# stale signal A never blinds the sweep to an independent, genuinely-merged crew branch.
grep -qF '[ "$SIG_COMMIT_TRUSTED" = "0" ] && [ "$SIG_MARKER" = "0" ]' "$JANITOR" \
  && ok "in_progress signal C gates on SIG_COMMIT_TRUSTED (not raw SIG_COMMIT)" || bad "in_progress signal C not using TRUSTED gate"
grep -qF '[ "$F_SIGCOMMIT_TRUSTED" = "0" ] && [ "$F_SIGMARKER" = "0" ]' "$JANITOR" \
  && ok "ga-hcj4 signal C gates on F_SIGCOMMIT_TRUSTED (not raw F_SIGCOMMIT)" || bad "ga-hcj4 signal C not using TRUSTED gate"
grep -qF 'if [ "$S_SIGCOMMIT_TRUSTED" = "0" ] && [ "$S_SIGMK" = "0" ]' "$JANITOR" \
  && ok "story signal C gates on S_SIGCOMMIT_TRUSTED (not raw S_SIGCOMMIT)" || bad "story signal C not using TRUSTED gate"
# comments_for_bead must be fetched at all three call sites (once per BID/FID/SID).
grep -qF 'comments_for_bead "$RPATH" "$BID"' "$JANITOR" && ok "in_progress sweep fetches bead comments" || bad "in_progress sweep missing comments_for_bead call"
grep -qF 'comments_for_bead "$RPATH" "$FID"' "$JANITOR" && ok "ga-hcj4 sweep fetches bead comments" || bad "ga-hcj4 sweep missing comments_for_bead call"
grep -qF 'comments_for_bead "$RPATH" "$SID"' "$JANITOR" && ok "story sweep fetches bead comments" || bad "story sweep missing comments_for_bead call"
# ── 11. ga-vokwv: sling-bead-name fallback (sling_beads_from_show / sling_signals_for_id) ──
# The ga-hcj4 sweep's three signals key strictly off the stranded bead's OWN id.
# Pilot's "fix bug X" dispatch convention creates a ROTATING sling-task WRAPPER
# bead per (re)dispatch attempt; if a fix branch/commit is named after the
# WRAPPER instead of the PARENT bug (the ga-0jcit incident this bead fixes),
# the sweep never finds it — confirmed live: 5+ post-merge sweeps all logged
# "no-merge-evidence" for a bead whose fix had already landed. This bucket
# hardens the sweep: when FID's own id carries no evidence, it re-probes every
# sling-task wrapper id ever dispatched for FID (via metadata + comment
# history) with the SAME three signals before giving up.
echo "── 11. ga-vokwv: sling-bead-name fallback ──"

echo "  -- 11a. sling_beads_from_show (pure JSON, no live Dolt) --"
# Real shape captured live off ga-vokwv itself (2026-07-26): TWO dispatch
# attempts, each leaving a "Sling task bead: <id>" comment; metadata carries
# only the MOST RECENT wrapper. Both must surface, deduplicated — an earlier
# wrapper can be the one that actually shipped (ga-0jcit's real fix landed
# under its FIRST wrapper ga-w4ah2, while later re-dispatches carried nothing).
SHOW_MULTI='{
  "metadata": {"pilot.dispatched_at": 1785070184, "pilot.sling_bead": "ga-803hq"},
  "comments": [
    {"text": "Pilot dispatched builder gastown.dog at 2026-07-26T11:42:20Z.\nSling task bead: ga-2rp0x\nBuilder doctrine: fix bug -> gate-done -> autonomous gate+delivery.", "created_at": "2026-07-26T11:42:28Z"},
    {"text": "inflight-reclaim-guard: reclaimed - no live builder and no recent branch progress for 32min.", "created_at": "2026-07-26T12:23:47Z"},
    {"text": "Pilot dispatched builder gastown.dog at 2026-07-26T12:49:37Z.\nSling task bead: ga-803hq\nBuilder doctrine: fix bug -> gate-done -> autonomous gate+delivery.", "created_at": "2026-07-26T12:49:47Z"}
  ]
}'
GOT_SLING=$(sling_beads_from_show "$SHOW_MULTI" | sort | tr '\n' ',')
eq "extracts both wrapper ids across dispatch history, deduplicated" "$GOT_SLING" "ga-2rp0x,ga-803hq,"

# `bd show` sometimes wraps the object in a single-element array — must normalize identically.
SHOW_MULTI_ARR="[$SHOW_MULTI]"
GOT_SLING_ARR=$(sling_beads_from_show "$SHOW_MULTI_ARR" | sort | tr '\n' ',')
eq "array-wrapped bd show output normalizes the same as bare object" "$GOT_SLING_ARR" "$GOT_SLING"

# No metadata, no matching comments → nothing found (a never-redispatched bead).
SHOW_NONE='{"metadata": {}, "comments": [{"text": "just a status update, no sling reference here", "created_at": "2026-07-26T00:00:00Z"}]}'
eq "no metadata + no matching comments → empty" "$(sling_beads_from_show "$SHOW_NONE")" ""

# Missing comments field entirely (bd show WITHOUT --include-comments) → metadata-only, no crash.
SHOW_META_ONLY='{"metadata": {"pilot.sling_bead": "ga-onlyone"}}'
eq "metadata-only (no comments key) → the one wrapper id" "$(sling_beads_from_show "$SHOW_META_ONLY")" "ga-onlyone"

# Malformed comment (id char class doesn't match, e.g. non-lowercase) must NOT
# crash the extraction of its siblings — jq's capture() no-ops on a non-match,
# it does not raise (unlike the (?P<id>...) syntax error this regex avoids).
SHOW_MIXED='{"metadata": {}, "comments": [{"text": "Sling task bead: NOTLOWER", "created_at": "x"}, {"text": "Sling task bead: ga-good1", "created_at": "y"}]}'
eq "malformed sibling comment does not block a valid match" "$(sling_beads_from_show "$SHOW_MIXED")" "ga-good1"

echo "  -- 11b. sling_signals_for_id (real git + synthetic marker JSON) --"
T10="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t10)"
trap 'rm -rf "$T10" 2>/dev/null || true; rm -rf "$T7B" 2>/dev/null || true; rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R10="$T10/repo10"
git init -q -b main "$R10"
( cd "$R10" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# The genuine fix, subject-scoped to the SLING WRAPPER id (the ga-0jcit shape:
# the branch/commit names the wrapper, not the parent).
( cd "$R10" && echo fix > fix.txt && git add fix.txt && git commit -q -m "fix(tt-wrap1): the real fix, named after the wrapper" )
SLING_FIX_SHA=$(git -C "$R10" rev-parse --short=9 HEAD)
# sling_signals_for_id operates on FETCHED origin/* refs (the live sweep never
# reads local branches) — stand up remote-tracking refs without a real remote.
git -C "$R10" update-ref refs/remotes/origin/main refs/heads/main

M_OPEN_MK='[{"status":"open","labels":["gate-status:queued"]}]'
M_PASSED_MK='[{"status":"closed","labels":["gate-status:passed"]}]'

# Commit signal: the wrapper id IS the subject scope of a commit in main.
eq "subject-scoped commit → sig_commit=1 with sha evidence" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-wrap1" "$M_EMPTY")" \
   "1 0 0 ${SLING_FIX_SHA} -"

# No evidence at all for an unrelated id.
eq "no evidence → all-zero, no evidence strings" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-nothing" "$M_EMPTY")" \
   "0 0 0 - -"

# OPEN marker suppresses ALL signals, even though commit evidence exists for
# this SAME id — still-active work on a candidate must never read as evidence
# either way (mirrors has_open_marker's role in the direct FID path).
eq "open marker on the CANDIDATE suppresses its own commit evidence" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-wrap1" "$M_OPEN_MK")" \
   "0 0 0 - -"

# Terminal passed marker alone is sufficient — no git evidence required.
eq "terminal passed marker → sig_marker=1, no git lookup needed" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-passed-only" "$M_PASSED_MK")" \
   "0 1 0 - -"

# Branch-ancestor signal via the crew/*/<id> convention fallback, same
# final-path-segment self-guard as the in_progress/ga-hcj4 sweeps.
git -C "$R10" branch crew/x/tt-branchy main
git -C "$R10" update-ref refs/remotes/origin/crew/x/tt-branchy refs/heads/crew/x/tt-branchy
eq "branch-ancestor signal fires via crew/*/<id> convention" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-branchy" "$M_EMPTY")" \
   "0 0 1 - crew/x/tt-branchy"

# Self-guard: a branch whose FINAL segment != the candidate id must never
# match (mirrors the in_progress/ga-hcj4 sweeps' */"$FID" guard — a
# differently-named branch that merely CONTAINS the id string must not count).
git -C "$R10" branch "crew/x/tt-branchy-longer" main
git -C "$R10" update-ref refs/remotes/origin/crew/x/tt-branchy-longer refs/heads/crew/x/tt-branchy-longer
eq "branch self-guard rejects a final-segment mismatch" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-branchy-lon" "$M_EMPTY")" \
   "0 0 0 - -"

echo "  -- 11b2. sling_fallback_eligible_reason (ga-v8ui5 gate-feedback follow-up) --"
# GATE-FEEDBACK (2026-07-30, gate_run=ga-wisp-617q8ra): janitor_decide's new
# keep:superseded-marker-needs-merge-evidence reason (§12 below) is a SECOND
# "FID's own signals came up empty" bucket, distinct from the original
# no-merge-evidence string. Before this predicate existed, the fallback gate
# matched no-merge-evidence ONLY — so a bead superseded under its current
# wrapper, whose real merge lived under a sibling wrapper id, silently never
# got the cross-check attempted (verdict stayed "keep", indistinguishable in
# the log from "checked and found nothing"). This exercises the actual
# predicate the sweep calls, not just a grep for its source text — the gap
# the gate feedback called out was exactly that no test exercised the
# end-to-end F_REASON branch.
eq "no-merge-evidence is fallback-eligible" \
   "$(sling_fallback_eligible_reason "no-merge-evidence")" "1"
eq "superseded-marker-needs-merge-evidence is fallback-eligible (the fix)" \
   "$(sling_fallback_eligible_reason "superseded-marker-needs-merge-evidence")" "1"
# Every guard/suppression reason a "keep" verdict can carry must stay
# ineligible — the fallback may NEVER second-guess an epic, an actively-gated
# bead, or a deliberately-suppressed stale-comment commit signal.
for guard_reason in epic-parent-never-autoclosed active-open-gate-marker \
                    commit-evidence-superseded-by-newer-comment \
                    story-in-flight-active-rework live-builder-assignee \
                    delivery-owns-it already-story-done; do
  eq "guard reason '$guard_reason' stays fallback-ineligible" \
     "$(sling_fallback_eligible_reason "$guard_reason")" "0"
done

echo "  -- 11c. drift-guard: live wiring in the ga-hcj4 sweep --"
grep -q 'sling_beads_from_show()' "$JANITOR"  && ok "defines sling_beads_from_show"  || bad "missing sling_beads_from_show def"
grep -q 'sling_signals_for_id()' "$JANITOR"   && ok "defines sling_signals_for_id"   || bad "missing sling_signals_for_id def"
grep -qF 'capture("Sling task bead: (?<id>[a-z][a-z0-9-]+)")' "$JANITOR" \
  && ok "uses the WORKING jq named-group syntax (?<id>...), not the P-form quality-gate-guard.sh uses" \
  || bad "sling id capture regex missing or reverted to the broken (?P<id>...) form"
grep -qF 'if [ "$F_VERDICT" = "keep" ] && [ "$(sling_fallback_eligible_reason "$F_REASON")" = "1" ]; then' "$JANITOR" \
  && ok "fallback gated via sling_fallback_eligible_reason (never overrides epic/open-marker keeps)" \
  || bad "fallback gating condition missing, loosened, or reverted to the single-string no-merge-evidence check"
grep -qF 'sling_fallback_eligible_reason()' "$JANITOR" \
  && ok "defines sling_fallback_eligible_reason" \
  || bad "missing sling_fallback_eligible_reason def"
grep -qF '[ "$F_SLING_ID" = "$FID" ] && continue' "$JANITOR" \
  && ok "skips self-referential sling id (rig-native beads already scanned as FID itself)" \
  || bad "sling self-reference skip missing"
grep -qF 'bd -C "$RPATH" show "$FID" --json --include-comments' "$JANITOR" \
  && ok "fetches comment history (not just metadata) to resolve sling wrapper ids" \
  || bad "--include-comments show call missing"
grep -qF 'F_VERDICT="close"' "$JANITOR" && grep -qF 'F_REASON="sling-bead-evidence"' "$JANITOR" \
  && ok "sling evidence flips the verdict to close with a distinguishable reason" \
  || bad "sling-bead-evidence verdict flip missing"
grep -qF '[ -n "$F_SLING_EVID" ] && F_EVID="$F_EVID $F_SLING_EVID"' "$JANITOR" \
  && ok "sling evidence is surfaced in the close comment/log line" \
  || bad "sling evidence not appended to F_EVID"

# ── 12. Drift-guard: ga-v8ui5 superseded is NOT a merge signal ──────────────
# gate-status:superseded means the branch was REPLACED (rebase/recreate — the
# documented procedure when the gate rejects a stale base) — the OPPOSITE of
# passed. Treating it as terminal-delivered on the marker signal ALONE let the
# janitor assert delivery for discarded work (wa-c3qsr: closed "work merged to
# origin/main" while the code was NOT in origin/main — 0 content hits, branch
# not an ancestor, the page still 404). Must be wired into ALL THREE call
# sites, exactly like the ga-2zp4h stale-comment guard above — missing even
# one leaves that bucket vulnerable to the same false-close.
echo "── 12. Drift-guard: ga-v8ui5 superseded-not-merged ──"
grep -q 'has_terminal_superseded_marker()' "$JANITOR" \
  && ok "defines has_terminal_superseded_marker (distinguishable, non-closing signal)" \
  || bad "missing has_terminal_superseded_marker def"
grep -qF 'sig_marker_superseded="${7:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional sig_marker_superseded (backward-compatible default)" \
  || bad "janitor_decide missing sig_marker_superseded param"
grep -qF 'sig_marker_superseded="${11:-0}"' "$JANITOR" \
  && ok "janitor_story_decide accepts optional sig_marker_superseded (backward-compatible default)" \
  || bad "janitor_story_decide missing sig_marker_superseded param"
grep -qF 'keep:superseded-marker-needs-merge-evidence' "$JANITOR" \
  && ok "superseded-only keep reason is distinguishable from generic no-merge-evidence" \
  || bad "superseded-marker-needs-merge-evidence reason missing"
# All THREE call sites must compute the signal AND thread it into the decision fns.
grep -qF 'SIG_MK_SUPER=0; has_terminal_superseded_marker "$MK" && SIG_MK_SUPER=1' "$JANITOR" \
  && ok "in_progress sweep computes SIG_MK_SUPER from has_terminal_superseded_marker" \
  || bad "in_progress sweep not computing SIG_MK_SUPER"
grep -qF 'F_SIGMK_SUPER=0; has_terminal_superseded_marker "$FMK" && F_SIGMK_SUPER=1' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep computes F_SIGMK_SUPER" \
  || bad "ga-hcj4 sweep not computing F_SIGMK_SUPER"
grep -qF 'S_SIGMK_SUPER=0; has_terminal_superseded_marker "$SMK" && S_SIGMK_SUPER=1' "$JANITOR" \
  && ok "story sweep computes S_SIGMK_SUPER" \
  || bad "story sweep not computing S_SIGMK_SUPER"
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE" "$SIG_MK_SUPER"' "$JANITOR" \
  && ok "in_progress sweep threads sig_marker_superseded into janitor_decide" \
  || bad "in_progress sweep not threading sig_marker_superseded"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE" "$F_SIGMK_SUPER"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads sig_marker_superseded into janitor_decide" \
  || bad "ga-hcj4 sweep not threading sig_marker_superseded"
grep -qF '"$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE" "$S_SIGMK_SUPER"' "$JANITOR" \
  && ok "story sweep threads sig_marker_superseded into janitor_story_decide" \
  || bad "story sweep not threading sig_marker_superseded"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
