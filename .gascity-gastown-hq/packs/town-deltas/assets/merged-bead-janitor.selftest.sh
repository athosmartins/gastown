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
          scan_commit_subject_for_bead branch_merged \
          has_open_marker has_terminal_passed_marker branch_label_from_markers rig_gitdir \
          janitor_branch_decide normalize_bead_status branch_is_fresh \
          bead_lookup_one resolve_bead_state; do
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
eq "marker reason"                      "$(janitor_decide 0 0 0 1 0)" "close:terminal-gate-marker-passed-or-superseded"
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
eq "marker beats branch"                "$(janitor_story_decide 0 0 0 0 0 0 0 1 1)" "done:terminal-gate-marker-passed-or-superseded"

# ── 1c. janitor_branch_decide — crew-branch prune (ga-tijv5 extension) ──────
# Args: <ahead> <bead_state> <live_worktree> <is_fresh>. The ONLY prune verdicts
# are ahead==0 AND bead closed|gone AND no worktree AND not fresh. Every other
# combination — and every uncertain state — must KEEP (lossless-only posture).
echo "── 1c. janitor_branch_decide (crew-branch prune) ──"
# The two (and only two) prune paths: fully-merged + bead closed / gone.
eq "merged + bead closed → prune"       "$(janitor_branch_decide 0 closed 0 0)" "prune:merged-and-bead-closed"
eq "merged + bead gone → prune"         "$(janitor_branch_decide 0 gone   0 0)" "prune:merged-and-bead-gone"
eq "prune verb (closed)"                "$(janitor_branch_decide 0 closed 0 0 | cut -d: -f1)" "prune"
# ahead>0 (unique commits) is the destructive case — NEVER pruned, whatever else.
eq "unmerged commits → keep"            "$(janitor_branch_decide 5 closed 0 0)" "keep:has-unmerged-commits"
eq "unmerged even if bead gone → keep"  "$(janitor_branch_decide 1 gone   0 0)" "keep:has-unmerged-commits"
eq "bad ahead read (ERR) → keep"        "$(janitor_branch_decide ERR closed 0 0)" "keep:has-unmerged-commits"
# Live worktree wins over everything (active agent), even fully merged + closed.
eq "live worktree → keep"               "$(janitor_branch_decide 0 closed 1 0)" "keep:live-worktree"
eq "worktree beats prune (gone)"        "$(janitor_branch_decide 0 gone   1 0)" "keep:live-worktree"
# Freshness grace: a just-merged branch is kept even with a closed bead.
eq "fresh branch → keep"                "$(janitor_branch_decide 0 closed 0 1)" "keep:fresh-branch-grace-window"
# Open/active bead → keep (courtesy; ahead==0 loses nothing but we don't touch it).
eq "open/active bead → keep"            "$(janitor_branch_decide 0 active 0 0)" "keep:bead-open-or-active"
# FAIL-OPEN: an unreadable bead status must never be pruned (transient Dolt).
eq "bead read error → keep (failopen)"  "$(janitor_branch_decide 0 readerror 0 0)" "keep:bead-read-error-failopen"
# Guard precedence: worktree > ahead > fresh > readerror > active > closed/gone.
eq "worktree > unmerged"                "$(janitor_branch_decide 9 closed 1 0)" "keep:live-worktree"
eq "unmerged > fresh"                   "$(janitor_branch_decide 3 closed 0 1)" "keep:has-unmerged-commits"
eq "fresh > readerror"                  "$(janitor_branch_decide 0 readerror 0 1)" "keep:fresh-branch-grace-window"
eq "readerror > active"                 "$(janitor_branch_decide 0 active 0 0)" "keep:bead-open-or-active"

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
# Branch-prune extension (ga-tijv5, 2026-07-01) — wired, conservative, and STAGED (off by default).
grep -q 'janitor_branch_decide()' "$JANITOR"     && ok "defines janitor_branch_decide"           || bad "missing janitor_branch_decide def"
grep -q 'PRUNE_BRANCHES="${JANITOR_PRUNE_BRANCHES:-0}"' "$JANITOR" && ok "branch-prune is OPT-IN, default OFF (staged)" || bad "branch-prune not default-off"
grep -q 'if \[ "$PRUNE_BRANCHES" = "1" \]' "$JANITOR" && ok "branch-prune sweep gated behind PRUNE_BRANCHES" || bad "branch-prune sweep not gated"
grep -q 'has-unmerged-commits' "$JANITOR"        && ok "never prunes ahead>0 (lossless-only)"    || bad "unmerged-commits guard missing"
grep -q 'bead-read-error-failopen' "$JANITOR"    && ok "fail-open on bad bead read"              || bad "fail-open guard missing"
grep -q 'recheck ahead=' "$JANITOR"              && ok "re-verifies ahead==0 at delete time"     || bad "delete-time ahead recheck missing"
grep -q 'BRANCH_PRUNE_MAX_PER_SWEEP' "$JANITOR"  && ok "per-sweep deletion cap present"          || bad "deletion cap missing"
grep -q 'fetch origin --prune' "$JANITOR"        && ok "fetch --prune (no stale tracking refs)"  || bad "fetch must prune for branch sweep"
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

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
