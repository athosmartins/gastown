#!/usr/bin/env bash
# gate-branch-content-coherence.selftest.sh — Prove the ga-y9a1d fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-y9a1d): a P0 fix was submitted to the gate on branch
#   fix/ga-fic5d-delivery-comment-read. Hours later the branch NAME still
#   existed on origin, gate-status still looked normal, no command had ever
#   failed — but the branch's tip on origin was, byte for byte, a DIFFERENT
#   bead's own commit (fix(ga-nawd3): ...), stacked on two more unrelated
#   beads' commits (ga-jeicm, ga-hhj7u) below it. The P0 fix itself had been
#   displaced from the ref entirely. Had a deploy-block alert not prompted a
#   manual check, the gate would have reviewed and MERGED that unrelated
#   content believing it was the P0.
#
#   FIX: one live, pre-merge check inserted immediately before the merge
#   decision, same shape and same section as the existing ga-nooaw/ga-lxz5w
#   checks it sits next to: branch_bead_commit_verdict() decides — from the
#   commits unique to the branch relative to $DEFAULT_BRANCH — whether the
#   source bead is referenced ANYWHERE in that range. A genuine miss (unique
#   commits exist, none mention the bead) downgrades OVERALL_VERDICT to FAIL,
#   labels gate:needs-human, and mails the Mayor + author — never silently
#   merges. A legitimate rebase/merge (ga-kyxih), a multi-commit fix, or a
#   persistent crew/* branch carrying other beads' history too, all still
#   pass (checks "at least one match", not "every commit").
#
# This harness sources the dispatcher in lib-only mode to unit-test the REAL
# pure decision (branch_bead_commit_verdict), then exercises the REAL git
# plumbing composition against a throwaway temp repo shaped like the actual
# incident, then DRIFT-GUARDS the live script so a future refactor can't drop
# or reorder the fix silently. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helper from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type branch_bead_commit_verdict >/dev/null 2>&1 \
  || { echo "FATAL: branch_bead_commit_verdict not defined by dispatcher (lib-only)"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. branch_bead_commit_verdict — pure decision, hand-fed fixtures ─────────
echo "── 1. branch_bead_commit_verdict (pure) ──"

eq "count=0 → skip (nothing unique to check)" \
  "$(branch_bead_commit_verdict "0" "fix(ga-nawd3): whatever" "ga-fic5d")" "skip"
eq "count empty → skip" \
  "$(branch_bead_commit_verdict "" "fix(ga-nawd3): whatever" "ga-fic5d")" "skip"
eq "count non-numeric (unparseable git output) → skip, fail-open" \
  "$(branch_bead_commit_verdict "not-a-number" "fix(ga-nawd3): whatever" "ga-fic5d")" "skip"
eq "bead_id empty → skip (nothing to check against)" \
  "$(branch_bead_commit_verdict "3" "fix(ga-nawd3): whatever" "")" "skip"

eq "normal case: single commit mentions its own bead → yes" \
  "$(branch_bead_commit_verdict "1" "fix(ga-fic5d): story-delivery reads comments per-channel which BREAKS on newline" "ga-fic5d")" "yes"

# ── The real incident's exact signature ───────────────────────────────────
REAL_INCIDENT_MSGS="$(printf 'fix(ga-nawd3): cap reconciler wake budget to reduce mass-respawn Dolt collapse\n\nfix bug ga-jeicm: reviewer-spawn transient classifier\n\nfix(ga-hhj7u): self-audit — sling-status log line\n')"
eq "ga-y9a1d incident reproduced: 3 unique commits, NONE mention ga-fic5d → no" \
  "$(branch_bead_commit_verdict "3" "$REAL_INCIDENT_MSGS" "ga-fic5d")" "no"
eq "same 3-commit range correctly says yes for the bead it ACTUALLY belongs to" \
  "$(branch_bead_commit_verdict "3" "$REAL_INCIDENT_MSGS" "ga-nawd3")" "yes"

# ── Legitimate shapes that must NOT false-positive ────────────────────────
REBASED_MSG="fix(ga-fic5d): story-delivery reads comments per-channel which BREAKS on newline"
eq "legit rebase: sha changes but message text is preserved verbatim → yes" \
  "$(branch_bead_commit_verdict "1" "$REBASED_MSG" "ga-fic5d")" "yes"

MULTI_COMMIT_MSGS="$(printf 'fix(ga-fic5d): story-delivery reads comments per-channel which BREAKS on newline\n\naddress review comment: tighten the channel-split regex\n')"
eq "multi-commit fix: only the FIRST of 2 commits repeats the bead id → yes (at-least-one, not every-commit)" \
  "$(branch_bead_commit_verdict "2" "$MULTI_COMMIT_MSGS" "ga-fic5d")" "yes"

AUTO_MERGE_MSGS="$(printf 'fix(ga-fic5d): story-delivery reads comments per-channel which BREAKS on newline\n\nMerge origin/main into fix/ga-fic5d-delivery-comment-read (gate auto-merge — tip was a merge commit, ga-kyxih)\n')"
eq "ga-kyxih auto-merge commit added on top: original commit still present → yes" \
  "$(branch_bead_commit_verdict "2" "$AUTO_MERGE_MSGS" "ga-fic5d")" "yes"

CREW_BRANCH_MSGS="$(printf 'skill-template additions, no bead reference\n\nfix(wa-xy2cb): MRV mapa das avenidas\n\nfix(wa-abc12): unrelated older task on the same persistent crew branch\n')"
eq "persistent crew/* branch carrying OTHER beads' history too, current bead present somewhere → yes" \
  "$(branch_bead_commit_verdict "3" "$CREW_BRANCH_MSGS" "wa-xy2cb")" "yes"

# ── 1b. ga-unjpf regression: unanchored substring match (gate fix-attempt-3
#       FAIL, caught live by the reviewer). The old `case ... in *"$bead"*)`
#       matched $bead as a bare substring ANYWHERE — a longer sibling bead ID
#       that merely STARTS with the target satisfied the match, wrongly
#       returning 'yes' for exactly the mismatch this function exists to
#       catch. The reviewer's own repro: bead='ga-3b8', commit mentions
#       'ga-3b812'. "ACEITE COM CONTROLE" (Mayor, re-arming attempt 4): the
#       legitimate case (messages genuinely citing 'ga-3b8') must still
#       return 'yes' — a test that only covers the collision would pass with
#       a function that always returns 'no', which proves nothing.
echo "── 1b. branch_bead_commit_verdict: anchored match (ga-unjpf) ──"
eq "prefix collision: target ga-3b8, commit mentions ga-3b812 (longer sibling id) → no, not yes" \
  "$(branch_bead_commit_verdict "1" "fix(ga-3b812): unrelated work" "ga-3b8")" "no"
eq "control (required by the Mayor's re-arm): target ga-3b8, commit genuinely mentions ga-3b8 → still yes" \
  "$(branch_bead_commit_verdict "1" "fix(ga-3b8): the real fix" "ga-3b8")" "yes"
eq "left-side collision (same class, not the reviewer's exact repro but the same unanchored-match bug): target ga-3b8 mid-word inside an unrelated token → no" \
  "$(branch_bead_commit_verdict "1" "chore: omega-3b8 migration notes" "ga-3b8")" "no"
eq "boundary: bead at the very start of the messages blob (no preceding char) → yes" \
  "$(branch_bead_commit_verdict "1" "ga-3b8: fix at start of line" "ga-3b8")" "yes"
eq "boundary: bead at the very end of the messages blob (no trailing char) → yes" \
  "$(branch_bead_commit_verdict "1" "fix for ga-3b8" "ga-3b8")" "yes"
eq "punctuation boundary: bead wrapped in parens (the file's own dominant commit style) still matches → yes" \
  "$(branch_bead_commit_verdict "1" "fix(ga-3b8): parenthesized" "ga-3b8")" "yes"

# ── 2. Git-plumbing composition against a REAL temp repo (incident-shaped) ───
echo "── 2. real-git integration: reproduce the incident's exact ref shape ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-y9a1d-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

git -C "$TMPD" init -q -b main
git -C "$TMPD" config user.email "test@gascity.local"
git -C "$TMPD" config user.name "Test"

echo "base"       > "$TMPD/f.txt"; git -C "$TMPD" add f.txt; git -C "$TMPD" commit -q -m "base"
BASE_SHA="$(git -C "$TMPD" rev-parse HEAD)"

# The "corrupted" ref: 3 commits for 3 OTHER beads, nothing for ga-fic5d —
# exactly what fix/ga-fic5d-delivery-comment-read's origin tip actually was.
echo "nawd3"  >> "$TMPD/f.txt"; git -C "$TMPD" commit -qam "fix(ga-nawd3): cap reconciler wake budget"
echo "jeicm"  >> "$TMPD/f.txt"; git -C "$TMPD" commit -qam "fix bug ga-jeicm: reviewer-spawn transient classifier"
echo "hhj7u"  >> "$TMPD/f.txt"; git -C "$TMPD" commit -qam "fix(ga-hhj7u): self-audit — sling-status log line"
CORRUPTED_TIP="$(git -C "$TMPD" rev-parse HEAD)"

# A legit branch off the same base: one real commit for ga-fic5d.
git -C "$TMPD" branch legit-fic5d "$BASE_SHA"
git -C "$TMPD" checkout -q legit-fic5d
echo "fic5d" >> "$TMPD/f.txt"; git -C "$TMPD" commit -qam "fix(ga-fic5d): story-delivery reads comments per-channel which BREAKS on newline"
LEGIT_TIP="$(git -C "$TMPD" rev-parse HEAD)"
git -C "$TMPD" checkout -q main

# Drive the SAME two git calls the live call site uses (rev-list --count,
# log --format=%B), directly against this temp repo — not through git_rig
# (which is rig-context-bound), proving the composition, not just the
# isolated pure function.
CORRUPTED_COUNT="$(git -C "$TMPD" rev-list --count "${BASE_SHA}..${CORRUPTED_TIP}")"
CORRUPTED_MSGS="$(git -C "$TMPD" log --format='%B' "${BASE_SHA}..${CORRUPTED_TIP}")"
eq "real-git: corrupted ref (3 unrelated commits) vs ga-fic5d → no" \
  "$(branch_bead_commit_verdict "$CORRUPTED_COUNT" "$CORRUPTED_MSGS" "ga-fic5d")" "no"

LEGIT_COUNT="$(git -C "$TMPD" rev-list --count "${BASE_SHA}..${LEGIT_TIP}")"
LEGIT_MSGS="$(git -C "$TMPD" log --format='%B' "${BASE_SHA}..${LEGIT_TIP}")"
eq "real-git: legit ref (1 real commit) vs ga-fic5d → yes" \
  "$(branch_bead_commit_verdict "$LEGIT_COUNT" "$LEGIT_MSGS" "ga-fic5d")" "yes"

# Already-merged / not-ahead case: base==tip → skip, not a false "no".
SAME_COUNT="$(git -C "$TMPD" rev-list --count "${BASE_SHA}..${BASE_SHA}")"
SAME_MSGS="$(git -C "$TMPD" log --format='%B' "${BASE_SHA}..${BASE_SHA}")"
eq "real-git: base==tip (nothing unique) → skip, not a false 'no'" \
  "$(branch_bead_commit_verdict "$SAME_COUNT" "$SAME_MSGS" "ga-fic5d")" "skip"

rm -rf "$TMPD"
trap - EXIT

# ── 3. DRIFT GUARD: helper defined before the lib-only cutoff ────────────────
echo "── 3. drift guard: helper is selftest-sourceable (defined before lib-only guard) ──"
CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
DEF_LN=$(grep -n '^branch_bead_commit_verdict() {' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "branch_bead_commit_verdict (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
else
  bad "branch_bead_commit_verdict must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

# ── 4. DRIFT GUARD: the check is wired in, correctly ordered, before the merge
echo "── 4. drift guard: content-coherence check precedes the merge, follows the sibling check ──"
has "$DISPATCHER" 'branch_bead_commit_verdict "\$GATE_Y9A1D_COUNT" "\$GATE_Y9A1D_MSGS" "\$BEAD_ID"' \
  "call site invokes branch_bead_commit_verdict with COUNT/MSGS/BEAD_ID"
# ga-36ta4: replaced by a call to the shared verify-then-apply helper
# (ga-55syh), which still receives the distinct sub-label as its argument.
has "$DISPATCHER" 'gate_apply_needs_human "\$BEAD_CITY" "\$BEAD_ID" "gate:needs-human:branch-content-mismatch"' \
  "content-mismatch failure labels the source bead distinctly (not just generic gate:needs-human)"
has "$DISPATCHER" 'Gate needs-human: branch content mismatch on \$BEAD_ID \(ga-y9a1d\)' \
  "content-mismatch failure escalates to the Mayor via durable mail (distinct subject line)"
has "$DISPATCHER" 'GATE_Y9A1D_SUSPECTS' \
  "failure path surfaces which OTHER bead(s) the content actually references (diagnostic value-add)"

SIBLING_CHECK_LN=$(grep -n 'gate_bead_active_sibling_branch "\$GC_CITY" "\$BEAD_ID" "\$BRANCH"' "$DISPATCHER" | head -1 | cut -d: -f1)
COHERENCE_CHECK_LN=$(grep -n 'branch_bead_commit_verdict "\$GATE_Y9A1D_COUNT"' "$DISPATCHER" | head -1 | cut -d: -f1)
MERGE_LOG_LN=$(grep -n 'log "ALL PASS — proceeding to merge branch' "$DISPATCHER" | head -1 | cut -d: -f1)

if [ -n "$SIBLING_CHECK_LN" ] && [ -n "$COHERENCE_CHECK_LN" ] && [ "$SIBLING_CHECK_LN" -lt "$COHERENCE_CHECK_LN" ]; then
  ok "sibling-branch check (line $SIBLING_CHECK_LN) precedes content-coherence check (line $COHERENCE_CHECK_LN)"
else
  bad "expected sibling-branch check before content-coherence check (sibling=$SIBLING_CHECK_LN coherence=$COHERENCE_CHECK_LN)"
fi
if [ -n "$COHERENCE_CHECK_LN" ] && [ -n "$MERGE_LOG_LN" ] && [ "$COHERENCE_CHECK_LN" -lt "$MERGE_LOG_LN" ]; then
  ok "content-coherence check (line $COHERENCE_CHECK_LN) precedes the merge attempt (line $MERGE_LOG_LN)"
else
  bad "content-coherence check must precede the merge attempt (coherence=$COHERENCE_CHECK_LN merge=$MERGE_LOG_LN)"
fi

# ── 5. DRIFT GUARD: fails OPEN — every git call in the wrapper is guarded ────
echo "── 5. drift guard: call site fails open on unresolvable merge-base (never blocks on a git error) ──"
has "$DISPATCHER" 'GATE_Y9A1D_BASE=\$\(git_rig merge-base "\$BRANCH_SHA" "origin/\$DEFAULT_BRANCH" 2>/dev/null \|\| echo ""\)' \
  "merge-base resolution is guarded (empty on failure, not a hard error)"
has "$DISPATCHER" 'if \[ -n "\$GATE_Y9A1D_BASE" \]; then' \
  "the whole check is skipped (not failed) when merge-base could not be resolved"

# ── 6. DRIFT GUARD: Site A (do_merge_ff's own merge-time rebase) is ALSO
#      hardened — the gap the Explore-agent investigation found: the Step-10
#      check above validates BRANCH_SHA before do_merge_ff() runs, but
#      do_merge_ff() can rebase AGAIN (main moving between review-pass and
#      merge) and push a NEW sha the Step-10 check never saw. Without this,
#      a collapse here would also poison the existing Bug-1b post-merge
#      integrity check's own baseline (MAIN_HEAD_SHA gets reassigned to the
#      post-rebase CUR_MAIN immediately after, at "MAIN_HEAD_SHA=$CUR_MAIN").
echo "── 6. drift guard: do_merge_ff's own merge-time rebase (Site A) is also hardened ──"
GATE_Y9A1D_SITEA_CALLS=$(grep -c 'branch_bead_commit_verdict \\' "$DISPATCHER" || echo "0")
if [ "$GATE_Y9A1D_SITEA_CALLS" -ge 2 ]; then
  ok "branch_bead_commit_verdict is invoked at 2+ additional (Site A) call sites (found $GATE_Y9A1D_SITEA_CALLS multi-line invocations total, includes Step 10's)"
else
  bad "expected 2+ multi-line branch_bead_commit_verdict invocations (Site A, container+self-repo) — found $GATE_Y9A1D_SITEA_CALLS"
fi
has "$DISPATCHER" 'NEW_TIP_MR_VERDICT" = "yes"' \
  "Site A container-rig push requires an explicit 'yes' (not merely 'not no')"
has "$DISPATCHER" 'NEW_TIP_MR_SR_VERDICT" = "yes"' \
  "Site A self-repo-rig push requires an explicit 'yes' (not merely 'not no')"
has "$DISPATCHER" 'did not verifiably preserve \$BRANCH' \
  "Site A logs a distinct, diagnosable message on a non-yes verdict (container-rig)"

# ga-y9a1d self-audit catch: a COMPLETE collapse (NEW_TIP_MR ends up literally
# equal to CUR_MAIN) makes the range CUR_MAIN..NEW_TIP_MR EMPTY — the pure
# function correctly returns "skip" here (zero unique commits), not "no". A
# guard written as `!= "no"` would silently let this exact case through,
# which is the complete-collapse shape this whole fix targets. Prove the
# pure function's "skip" verdict on this shape, and that Site A's own gate
# is written to reject anything short of "yes" — never merely "not no".
echo "── (continued) 1b. branch_bead_commit_verdict: the complete-collapse shape ──"
eq "complete collapse (rebase produced ZERO commits vs the target — same sha) → skip, NOT no" \
  "$(branch_bead_commit_verdict "0" "" "ga-fic5d")" "skip"
if grep -qE 'NEW_TIP_MR_VERDICT" != "no"' "$DISPATCHER"; then
  bad "Site A must NOT use '!= \"no\"' alone — that lets a complete collapse (verdict=skip) through unguarded"
else
  ok "Site A does not use the weaker '!= \"no\"' guard anywhere (complete-collapse-safe)"
fi

# ga-y9a1d ordering: Site A's checks must be computed from CUR_MAIN (the
# pre-this-rebase baseline) — verify the call captures the range starting at
# CUR_MAIN, not some other/later variable that could already be contaminated.
has "$DISPATCHER" 'rev-list --count "\$\{CUR_MAIN\}\.\.\$\{NEW_TIP_MR\}"' \
  "Site A diffs from CUR_MAIN (pre-rebase baseline), not a variable reassigned after the fact"

# ── 7. syntax ──────────────────────────────────────────────────────────────
echo "── 7. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

# ── 8. regression: ga-y9a1d fix-attempt-1 FAIL — GATE_Y9A1D_SUSPECTS crashed
#      the WHOLE dispatcher under set -e when grep found zero matches (a real
#      case: mismatched commits with no OTHER recognizable ga/wa/dc/lexbh/
#      marketing-prefixed bead id anywhere — generic/docs/squash commits, or a
#      bead-prefix family outside those 5, both produce this). Caught live by
#      the gate's own reviewer against real branch content, NOT by this
#      selftest — sections 1-7 above never actually EXECUTE this line under
#      set -e, so a missing `|| echo ""` guard was structurally invisible to
#      the whole suite (same class as [[sibling-function-guard-not-inherited]]
#      one level down: not a sibling FUNCTION missing a guard, but a sibling
#      COMMAND in the same block). Test the REAL failure mechanism directly —
#      not the pure function (which never touches grep) — with `set -e`
#      actually enabled, matching the live dispatcher's own top-of-file
#      setting (line 6), and a fixture with a genuine zero-match shape.
# Extract and EXECUTE the LIVE dispatcher's actual assignment line — not a
# hand-copied duplicate. A duplicate would always carry whatever guard *I*
# remembered to write, and could never fail against a future regression that
# drops it again (caught myself doing exactly this on the first draft of this
# section: the hand-copied version passed even with the fix stashed out —
# see [[test-that-supplies-the-override-cannot-find-it-is-required]]).
#
# Run it as a genuinely SEPARATE bash process (a temp script file), not a
# same-process `( subshell )`. Verified empirically: a `( set -euo pipefail;
# X=$(failing-pipe); ... )` subshell run inline in this harness's own process
# does NOT reproduce the crash, while `bash <scriptfile>` and `bash -c '...'`
# both do (same discrepancy independent of eval/quoting — confirmed with a
# minimal repro before writing this). This isn't just a workaround: the real
# dispatcher.sh is ALWAYS invoked as its own top-level `#!/usr/bin/env bash`
# process (launchd/direct exec), never as a subshell inside another script —
# so the separate-process form is also the more faithful reproduction.
echo "── 8. regression: GATE_Y9A1D_SUSPECTS must not crash under set -e on zero matches ──"
SUSPECTS_LINE=$(grep -E '^[[:space:]]*GATE_Y9A1D_SUSPECTS=' "$DISPATCHER" | head -1)
if [ -z "$SUSPECTS_LINE" ]; then
  bad "could not locate the live GATE_Y9A1D_SUSPECTS assignment in $DISPATCHER"
else
  PROBE_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/gate-y9a1d-probe.XXXXXX")"
  {
    echo 'set -euo pipefail'
    # NOT "fix(ga-y9a1d): ..." — that would match the pattern on its OWN
    # bead id (the grep doesn't exclude the current bead) and silently stop
    # being a zero-match fixture. Genuinely no ga/wa/dc/lexbh/marketing-
    # <4-7chars> substring anywhere in this text (verified separately).
    echo 'GATE_Y9A1D_MSGS="chore: tighten validation regex, address earlier review feedback"'
    printf '%s\n' "$SUSPECTS_LINE"
    echo 'exit 0'
  } > "$PROBE_SCRIPT"
  if bash "$PROBE_SCRIPT" >/dev/null 2>&1; then
    ok "the LIVE dispatcher's actual GATE_Y9A1D_SUSPECTS line survives a zero-match fixture under set -euo pipefail (separate-process)"
  else
    bad "the LIVE dispatcher's actual GATE_Y9A1D_SUSPECTS line CRASHES under set -euo pipefail on zero matches — this is the fix-attempt-1 FAIL regression (missing || echo \"\" guard)"
  fi
  rm -f "$PROBE_SCRIPT"
fi

# ── 9. DRIFT GUARD: ga-pfgnv — do_merge_ff's direct-FF/post-rebase-fallthrough
#      push is ALSO gated. Site A (section 6 above) only runs inside the
#      `IS_ANC != "yes"` rebase block; when the branch was ALREADY a clean
#      fast-forward (the common, no-conflict case — arguably more likely to
#      recur in than the rebase shape, per the original ga-pfgnv filing), that
#      whole block is skipped and execution fell straight through to the FF
#      push with zero branch_bead_commit_verdict coverage. This section proves
#      the gap is closed: a 3rd call site sits right before the actual push,
#      after (not nested inside) the rebase if-block, so it fires on BOTH
#      paths — the one property that makes it close the gap Site A cannot.
echo "── 9. drift guard: ga-pfgnv — do_merge_ff's direct-FF/post-rebase-fallthrough push is ALSO gated ──"
has "$DISPATCHER" 'branch_bead_commit_verdict "\$FF_PUSH_COUNT" "\$FF_PUSH_MSGS" "\$BEAD_ID"' \
  "do_merge_ff calls branch_bead_commit_verdict immediately before the FF push (ga-pfgnv 4th call site)"
has "$DISPATCHER" 'MERGE_RESULT="failed_branch_content_mismatch"' \
  "a 'no' verdict at the FF-push site sets a distinct, greppable MERGE_RESULT"
has "$DISPATCHER" '"\$MERGE_RESULT" = "failed_branch_content_mismatch"' \
  "failed_branch_content_mismatch is checked (non-retryable list + FAIL_REASONS enrichment — a real content mismatch can't be fixed by retrying)"

FFPUSH_CHECK_LN=$(grep -n 'branch_bead_commit_verdict "\$FF_PUSH_COUNT"' "$DISPATCHER" | head -1 | cut -d: -f1)
FFPUSH_LN=$(grep -n '# FF push$' "$DISPATCHER" | head -1 | cut -d: -f1)
MAIN_HEAD_LN=$(grep -n '^      MAIN_HEAD_SHA="\$CUR_MAIN"$' "$DISPATCHER" | head -1 | cut -d: -f1)

if [ -n "$FFPUSH_CHECK_LN" ] && [ -n "$FFPUSH_LN" ] && [ "$FFPUSH_CHECK_LN" -lt "$FFPUSH_LN" ]; then
  ok "FF-push content-coherence check (line $FFPUSH_CHECK_LN) precedes the actual push (line $FFPUSH_LN)"
else
  bad "FF-push content-coherence check must precede the actual push (check=$FFPUSH_CHECK_LN push=$FFPUSH_LN)"
fi

# The gap this closes specifically: IS_ANC=="yes" (direct FF) skips do_merge_ff's
# ENTIRE rebase if-block (where Site A's 2 guards live). Anchor on
# MAIN_HEAD_SHA="$CUR_MAIN" — a line whose own comment ("No-op when main did
# not move") only makes sense if it runs on the direct-FF path too, proving it
# sits AFTER the rebase if-block closes, not inside it. If the new check came
# BEFORE this line (or, worse, were nested inside the rebase-only branch), it
# would inherit the exact blind spot it exists to close.
if [ -n "$MAIN_HEAD_LN" ] && [ -n "$FFPUSH_CHECK_LN" ] && [ "$MAIN_HEAD_LN" -lt "$FFPUSH_CHECK_LN" ]; then
  ok "FF-push check (line $FFPUSH_CHECK_LN) comes after the post-rebase-block MAIN_HEAD_SHA refresh (line $MAIN_HEAD_LN) — runs on BOTH the direct-FF and post-rebase-fallthrough paths, not nested inside the rebase-only branch"
else
  bad "expected FF-push check after the MAIN_HEAD_SHA refresh that follows the rebase if-block (main_head=$MAIN_HEAD_LN check=$FFPUSH_CHECK_LN)"
fi

eq "pure function: FF-push site's own failure shape (unique commits present, none mention the bead) → no" \
  "$(branch_bead_commit_verdict "2" "$REAL_INCIDENT_MSGS" "ga-fic5d")" "no"
eq "pure function: FF-push site on an already-caught-up branch (empty range) → skip, not a false failure (unlike Site A, this call site doesn't already know the branch has unique commits)" \
  "$(branch_bead_commit_verdict "0" "" "ga-fic5d")" "skip"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
