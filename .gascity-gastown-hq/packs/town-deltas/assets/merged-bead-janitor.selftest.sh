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
          scan_commit_subject_for_bead branch_merged branch_unmerged \
          has_open_marker has_terminal_passed_marker branch_label_from_markers rig_gitdir; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by janitor"; exit 1; }
done

# ── 1. janitor_decide — pure decision, every branch + guard precedence ──────
# Args: <is_epic> <has_open_marker> <sig_commit_subject> <sig_commit_body>
#       <sig_marker> <sig_branch> <unmerged_branch>
#
# ga-92o95 FIX: the commit signal is SPLIT into two strengths:
#   • sig_commit_subject — the bead id is in an origin/main commit SUBJECT
#     (conventional scope feat(<id>)/fix(<id>)) → STRONG proof the commit
#     IMPLEMENTS the bead. Trusted unconditionally.
#   • sig_commit_body — the id appears ONLY in a commit BODY → WEAK/ambiguous:
#     it is the genuine signal for the sibling-under-parent and cross-store
#     mirror cases (code IS in that merged commit), but it ALSO fires when a
#     commit merely MENTIONS the bead ("rescued from <id>", "supersedes <id>")
#     without containing its code (the wa-qjym false-close). It is therefore
#     VETOED by an unmerged branch (the bead's crew/*/<id> branch resolves and
#     is NOT an ancestor of origin/main → its work is demonstrably NOT merged).
# The veto applies ONLY to the weak body signal; a subject commit, a terminal
# marker, or branch-ancestry still close even when a branch lingers (e.g. a
# squash-merge leaves the crew branch non-ancestor of main).
echo "── 1. janitor_decide (pure verdict) ──"
eq "no signals → keep"                  "$(janitor_decide 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "subject signal → close"             "$(janitor_decide 0 0 1 0 0 0 0 | cut -d: -f1)" "close"
eq "body signal → close"                "$(janitor_decide 0 0 0 1 0 0 0 | cut -d: -f1)" "close"
eq "marker signal → close"              "$(janitor_decide 0 0 0 0 1 0 0 | cut -d: -f1)" "close"
eq "branch signal → close"              "$(janitor_decide 0 0 0 0 0 1 0 | cut -d: -f1)" "close"
eq "subject reason"                     "$(janitor_decide 0 0 1 0 0 0 0)" "close:commit-subject-in-origin-main"
eq "body reason"                        "$(janitor_decide 0 0 0 1 0 0 0)" "close:commit-body-in-origin-main"
eq "marker reason"                      "$(janitor_decide 0 0 0 0 1 0 0)" "close:terminal-gate-marker-passed-or-superseded"
eq "branch reason"                      "$(janitor_decide 0 0 0 0 0 1 0)" "close:branch-ancestor-of-origin-main"
# ── ga-92o95 regression: the wa-qjym false-close class ──
# Body-only mention + an unmerged crew branch → the work is provably NOT merged.
eq "body+unmerged-branch → KEEP (veto)" "$(janitor_decide 0 0 0 1 0 0 1)" "keep:unmerged-branch-disconfirms-commit-mention"
eq "unmerged branch alone → keep"       "$(janitor_decide 0 0 0 0 0 0 1)" "keep:no-merge-evidence"
# The veto is SCOPED to the weak body signal — strong signals still close even
# with a lingering unmerged branch (the squash-merge / errored-then-merged shape).
eq "subject+unmerged → still close"     "$(janitor_decide 0 0 1 0 0 0 1)" "close:commit-subject-in-origin-main"
eq "marker+unmerged → still close"      "$(janitor_decide 0 0 0 0 1 0 1)" "close:terminal-gate-marker-passed-or-superseded"
eq "branch-ancestor+unmerged → close"   "$(janitor_decide 0 0 0 0 0 1 1)" "close:branch-ancestor-of-origin-main"
# Signal precedence (cosmetic): marker > subject > branch > body.
eq "subject beats body"                 "$(janitor_decide 0 0 1 1 0 0 0)" "close:commit-subject-in-origin-main"
eq "marker beats subject"               "$(janitor_decide 0 0 1 0 1 0 0)" "close:terminal-gate-marker-passed-or-superseded"
# Guard precedence: epic ALWAYS keep, even with every signal set.
eq "epic beats all signals → keep"      "$(janitor_decide 1 0 1 1 1 1 1 | cut -d: -f1)" "keep"
eq "epic reason"                        "$(janitor_decide 1 0 0 0 0 0 0)" "keep:epic-parent-never-autoclosed"
# Open marker beats signals INCLUDING the body+veto path (protects wa-lstd).
eq "open-marker beats subject → keep"   "$(janitor_decide 0 1 1 0 0 0 0 | cut -d: -f1)" "keep"
eq "open-marker beats body+veto → keep" "$(janitor_decide 0 1 0 1 0 0 1 | cut -d: -f1)" "keep"
eq "open-marker beats branch → keep"    "$(janitor_decide 0 1 0 0 0 1 0 | cut -d: -f1)" "keep"
eq "open-marker reason"                 "$(janitor_decide 0 1 0 0 0 0 0)" "keep:active-open-gate-marker"
# Epic precedence over open-marker (both 'keep' but epic wins the label).
eq "epic+open → epic reason"            "$(janitor_decide 1 1 0 0 0 0 0)" "keep:epic-parent-never-autoclosed"

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
eq "marker signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 0 1 0)" "done:terminal-gate-marker-passed-or-superseded"
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
# Guard ORDER (lower-numbered guard wins the label when several apply):
eq "epic > already-done"                "$(janitor_story_decide 1 0 1 0 0 0 0 0 0)" "keep:epic-parent-never-autoclosed"
eq "already-done > open-marker"         "$(janitor_story_decide 0 1 1 0 0 0 0 0 0)" "keep:already-story-done"
eq "open-marker > in-flight"            "$(janitor_story_decide 0 1 0 1 0 0 0 0 0)" "keep:active-open-gate-marker"
eq "in-flight > builder"                "$(janitor_story_decide 0 0 0 1 1 0 0 0 0)" "keep:story-in-flight-active-rework"
eq "builder > delivery"                 "$(janitor_story_decide 0 0 0 0 1 1 0 0 0)" "keep:live-builder-assignee"
# Signal precedence among the three (commit > marker > branch), cosmetic only.
eq "commit beats marker+branch"         "$(janitor_story_decide 0 0 0 0 0 0 1 1 1)" "done:commit-in-origin-main"
eq "marker beats branch"                "$(janitor_story_decide 0 0 0 0 0 0 0 1 1)" "done:terminal-gate-marker-passed-or-superseded"

# ── 2. token_bounded — whole-token id match (no substring false-positives) ──
echo "── 2. token_bounded ──"
rc0 token_bounded "wa-1or2" "feat(wa-1or2): add simplified mode"
rc0 token_bounded "wa-1or2" "Mirrors WA bead wa-1or2; the artifact is HQ-local"
rc0 token_bounded "wa-1or2" "Source bead: ga-piycl (mirror of wa-1or2)"
rc1 token_bounded "wa-1"    "feat(wa-1or2): unrelated longer id"      # wa-1 must NOT match wa-1or2
rc1 token_bounded "wa-1or2" "see commit wa-1or2x for details"          # trailing alnum breaks boundary
rc1 token_bounded "wa-1or2" "totally unrelated message"

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

# ── 3c. branch_unmerged — the ga-92o95 disconfirming-branch veto helper ──────
# rc0 iff the branch RESOLVES and is NOT an ancestor of main (its work is
# demonstrably NOT in main). Missing branch → rc1 (no unmerged work to veto on).
# This is the inverse of branch_merged but distinct on the missing-branch case.
echo "── 3c. branch_unmerged (disconfirming-branch veto) ──"
rc0 branch_unmerged "$R" 0 "ahead-topic"  "main"   # diverged → unmerged work exists → veto
rc1 branch_unmerged "$R" 0 "merged-topic" "main"   # ancestor → NOT unmerged (already in main)
rc1 branch_unmerged "$R" 0 "no-such-branch" "main" # missing → nothing to veto on (safe)

# ── 3d. END-TO-END regression for ga-92o95 (the wa-qjym false-close) ─────────
# Shape: a DOCS/supersede commit lands in origin/main and mentions the bead id
# ONLY in its body ("rescued from <id>"); the bead's REAL code lives on an
# unmerged crew branch. Body scan fires (SIG_BODY=1), subject scan does NOT
# (SIG_SUBJ=0), and the crew branch is unmerged → janitor_decide must KEEP.
echo "── 3d. ga-92o95 end-to-end (body-mention + unmerged crew branch → KEEP) ──"
( cd "$R" && echo docs > docs.txt && git add docs.txt && \
  git commit -q -m "docs(tt-docs): rework runbook" \
                -m "Unrelated docs change; rescued the crawler from tt-orphan into another branch." )
# crew branch carrying the orphaned bead's real code, NOT merged into main.
git -C "$R" checkout -q -b crew/claude/tt-orphan main
( cd "$R" && echo scraper > scraper.py && git add scraper.py && \
  git commit -q -m "feat(tt-orphan): the real scraper code (never merged)" )
git -C "$R" checkout -q main
E2E_SUBJ=0; scan_commit_subject_for_bead "$R" 0 "main" "tt-orphan" >/dev/null 2>&1 && E2E_SUBJ=1
E2E_BODY=0; scan_commit_for_bead         "$R" 0 "main" "tt-orphan" >/dev/null 2>&1 && E2E_BODY=1
E2E_UNMG=0; branch_unmerged "$R" 0 "crew/claude/tt-orphan" "main"   && E2E_UNMG=1
eq "e2e: subject scan does NOT match (0)" "$E2E_SUBJ" "0"
eq "e2e: body scan DOES match (1)"        "$E2E_BODY" "1"
eq "e2e: crew branch is unmerged (1)"     "$E2E_UNMG" "1"
eq "e2e: janitor KEEPS the orphan bead"   \
   "$(janitor_decide 0 0 "$E2E_SUBJ" "$E2E_BODY" 0 0 "$E2E_UNMG")" \
   "keep:unmerged-branch-disconfirms-commit-mention"

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
rc0 has_terminal_passed_marker "$M_SUPER"
rc1 has_terminal_passed_marker "$M_FAILED"           # closed-FAILED is NOT merged → no close signal
rc1 has_terminal_passed_marker "$M_OPEN"
rc1 has_terminal_passed_marker "$M_EMPTY"
eq "branch label extracted" "$(branch_label_from_markers "$M_OPEN")" "crew/mila/wa-lstd"
eq "no branch label → empty" "$(branch_label_from_markers "$M_PASSED")" ""

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
grep -q 'gate-status:passed' "$JANITOR" && grep -q 'gate-status:superseded' "$JANITOR" \
  && ok "terminal signal checks passed+superseded" || bad "terminal marker labels missing"
# Cross-store: own-rig repo scan falls back to HQ repo (mirror case).
grep -q 'scan_commit_for_bead "$HQ_GITDIR"' "$JANITOR" && ok "cross-store HQ-repo mirror scan wired" || bad "HQ-repo mirror scan missing"
# set -e/pipefail safety: no `set -e` (sweep tolerates per-bead failures) but
# the close path guards its mutation with `|| { err ...; continue; }`.
grep -q 'close failed for' "$JANITOR" && ok "close failure is non-fatal (continue)" || bad "close failure not guarded"
# ga-gosfs: story:done reconciliation sweep wiring.
grep -q 'janitor_story_decide()' "$JANITOR" && ok "defines janitor_story_decide"     || bad "missing janitor_story_decide def"
grep -q 'scan_commit_subject_for_bead()' "$JANITOR" && ok "defines strict subject scanner" || bad "missing scan_commit_subject_for_bead def"
# The story sweep MUST use the strict subject scanner (not the body scanner) for
# signal A — guards against the ga-r471/wa-qggy incidental-body-mention class.
grep -q 'scan_commit_subject_for_bead "\$RGITDIR"' "$JANITOR" && ok "story sweep uses strict subject scan" || bad "story sweep not using strict scanner"
# ga-92o95: the in_progress sweep must compute the disconfirming-branch veto and
# the split subject/body commit signal so a body-only mention + unmerged crew
# branch (the wa-qjym false-close) is KEPT, not closed.
grep -q 'branch_unmerged()' "$JANITOR" && ok "defines branch_unmerged veto helper" || bad "missing branch_unmerged def"
grep -q 'unmerged-branch-disconfirms-commit-mention' "$JANITOR" && ok "in_progress sweep wires the unmerged-branch veto" || bad "unmerged-branch veto missing"
grep -q 'scan_commit_subject_for_bead "\$RGITDIR" "\$RCONTAINER" "origin/\$RDEFAULT" "\$BID"' "$JANITOR" \
  && ok "in_progress sweep computes the strong subject signal" || bad "in_progress sweep missing subject signal"
grep -q 'label add "\$SID" "story:done"' "$JANITOR" && ok "story sweep sets story:done" || bad "story:done transition missing"
grep -q 'already-story-done' "$JANITOR"          && ok "story idempotency guard present" || bad "story already-done guard missing"
grep -q 'delivery-owns-it' "$JANITOR"            && ok "delivery-active guard present"   || bad "delivery guard missing"
grep -q 'story-in-flight-active-rework' "$JANITOR" && ok "story in-flight guard present" || bad "story in-flight guard missing"
# The story sweep must select OPEN story:approved beads (the stuck-merged shape),
# distinct from the in_progress sweep above.
grep -q 'list --status open --all --json -l story:approved' "$JANITOR" \
  && ok "story sweep selects open story:approved" || bad "story sweep selector missing"
# plist drift.
grep -q 'com.gascity.merged-bead-janitor' "$PLIST" && ok "plist Label correct"        || bad "plist Label wrong"
grep -q '<key>StartInterval</key>' "$PLIST"        && ok "plist uses StartInterval"    || bad "plist missing StartInterval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST"     && ok "plist RunAtLoad=true"        || bad "plist missing RunAtLoad"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
