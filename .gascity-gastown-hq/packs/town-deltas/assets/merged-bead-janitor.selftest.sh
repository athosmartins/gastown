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
for fn in janitor_decide token_bounded scan_commit_for_bead branch_merged \
          has_open_marker has_terminal_passed_marker branch_label_from_markers rig_gitdir; do
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

# branch_merged: topic branch that IS an ancestor of main vs one that is not.
git -C "$R" branch merged-topic HEAD~1     # points at the mirror commit (ancestor of main)
git -C "$R" checkout -q -b ahead-topic main
( cd "$R" && echo d > d.txt && git add d.txt && git commit -q -m "ahead-only commit" )
git -C "$R" checkout -q main
rc0 branch_merged "$R" 0 "merged-topic" "main"     # ancestor → merged
rc1 branch_merged "$R" 0 "ahead-topic"  "main"     # has commit not in main → not merged
rc1 branch_merged "$R" 0 "no-such-branch" "main"   # missing branch → not merged (safe)

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
# plist drift.
grep -q 'com.gascity.merged-bead-janitor' "$PLIST" && ok "plist Label correct"        || bad "plist Label wrong"
grep -q '<key>StartInterval</key>' "$PLIST"        && ok "plist uses StartInterval"    || bad "plist missing StartInterval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST"     && ok "plist RunAtLoad=true"        || bad "plist missing RunAtLoad"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
