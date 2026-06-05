#!/usr/bin/env bash
# quality-gate-step0c-gaps.selftest.sh — Prove the ga-pa36 Step-0c GAP-1/GAP-2
# extensions in quality-gate-guard.sh are correctly wired, with NO live
# Dolt/gc/launchd/git calls required.
#
# GAP-1: merged-but-OPEN beads — OPEN story:in-flight with branch already merged
#   to origin/main but no gate:passed. The existing condition (closed OR gate:passed)
#   misses these. Fix: test git merge-base --is-ancestor; safe-skip if branch SHA
#   cannot be resolved or a live builder session is assigned.
#
# GAP-2: parent-story stranding — gate ran on SLING/WORK bead, FAIL self-heal
#   acted on work-bead only, parent story retains story:in-flight + pilot:dispatched
#   with no builder forever. Fix: detect via "Sling task bead: $ID" comment,
#   check sling bead is closed, free parent lane + label gate:needs-fix.
#
# This harness uses drift-guard (grep) assertions only — pure structural proof
# that the live guard implements both patterns with safe-defaults. No live I/O.
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
grp() { grep -q "$1" "$GUARD" && ok "$2" || bad "$3"; }

# ── 1. GAP-1: merged-but-OPEN sweep is present ─────────────────────────────
echo "── 1. drift-guard: GAP-1 merged-but-OPEN sweep ──"
grp 'ga-pa36 GAP-1'                "guard names GAP-1 (ga-pa36)"                   "guard missing GAP-1 block"
grp 'merge-base --is-ancestor'     "guard uses git merge-base --is-ancestor"        "guard missing merge-base --is-ancestor (GAP-1)"
grp 'ls-remote origin.*fix/'       "guard resolves branch via ls-remote (GAP-1)"   "guard missing ls-remote branch lookup (GAP-1)"
grp 'refs/remotes/origin/fix/'     "guard falls back to local remote-tracking cache" "guard missing for-each-ref fallback (GAP-1)"
grp 'MAIN_SHA'                     "guard fetches origin/main SHA (GAP-1)"          "guard missing MAIN_SHA (GAP-1)"
grp 'BRANCH_SHA'                   "guard resolves BRANCH_SHA (GAP-1)"              "guard missing BRANCH_SHA (GAP-1)"
grp 'origin/main SHA unreachable.*safe-skip' \
                                   "guard safe-skips if origin/main unreachable"     "guard missing unreachable-main safe-skip"
grp 'branch SHA not found.*safe.skip' \
                                   "guard safe-skips if branch SHA not found"        "guard missing branch-not-found safe-skip"
grp 'already merged to origin/main.*no gate:passed' \
                                   "guard comment names the GAP-1 condition"         "guard missing GAP-1 comment"

# ── 2. GAP-1: pilot:dispatched beads excluded (handled by GAP-2) ───────────
echo "── 2. drift-guard: GAP-1 excludes pilot:dispatched candidates ──"
grp 'pilot:dispatched.*not'        "guard excludes pilot:dispatched from GAP-1 candidates" \
                                   "guard does not exclude pilot:dispatched in GAP-1"

# ── 3. GAP-1 + GAP-2: live-session safety guard ────────────────────────────
echo "── 3. drift-guard: live-session assignee safety (both gaps) ──"
eq_count() {
  local cnt
  cnt=$(grep -c "$1" "$GUARD" 2>/dev/null || echo "0")
  if [ "$cnt" -ge "$2" ]; then ok "$3 (count=$cnt)"; else bad "$4 (count=$cnt, need >=$2)"; fi
}
eq_count 'SESSION_ALIVE' 2 "guard checks SESSION_ALIVE in at least 2 places (GAP-1 + GAP-2)" \
                            "guard missing SESSION_ALIVE checks (need GAP-1 + GAP-2)"
eq_count 'live.*assignee.*safe.skip\|safe.skip.*live.*assignee' 2 \
  "guard logs safe-skip on live assignee in at least 2 places" \
  "guard missing live-assignee safe-skip log (need GAP-1 + GAP-2)"

# ── 4. GAP-2: parent-story stranding sweep is present ──────────────────────
echo "── 4. drift-guard: GAP-2 parent-story stranding sweep ──"
grp 'ga-pa36 GAP-2'               "guard names GAP-2 (ga-pa36)"                   "guard missing GAP-2 block"
grp 'pilot:dispatched'             "guard sweeps pilot:dispatched label (GAP-2)"   "guard missing pilot:dispatched sweep"
grp 'include-comments'             "guard fetches comments with --include-comments" "guard missing --include-comments (GAP-2)"
grp 'Sling task bead'              "guard parses 'Sling task bead:' from comments"  "guard missing Sling task bead parse (GAP-2)"
grp 'SLING_ID'                     "guard resolves SLING_ID (GAP-2)"               "guard missing SLING_ID (GAP-2)"
grp 'SLING_STATUS'                 "guard checks SLING_STATUS (GAP-2)"             "guard missing SLING_STATUS check (GAP-2)"
grp 'gate:needs-fix'               "guard applies gate:needs-fix to stranded parent" "guard missing gate:needs-fix on parent (GAP-2)"
grp 'pilot:dispatched.*-q'         "guard strips pilot:dispatched from parent (GAP-2)" \
                                   "guard missing pilot:dispatched strip (GAP-2)"
grp "Sling task bead.*comment.*found.*safe.skip\|no.*Sling task bead.*safe.skip" \
                                   "guard safe-skips if no sling comment found"     "guard missing no-sling-comment safe-skip (GAP-2)"
grp 'status unknown.*safe.skip'    "guard safe-skips on unknown sling status"       "guard missing unknown-status safe-skip (GAP-2)"
grp 'work-bead only, not parent\|acted on work.bead only\|acted on work-bead only' \
                                   "guard comment explains the GAP-2 root cause"    "guard missing GAP-2 root-cause comment"

# ── 5. Shared: INFLIGHT_JSON is reused across all three sub-steps ──────────
echo "── 5. drift-guard: INFLIGHT_JSON fetched once, reused by GAP-1 + GAP-2 ──"
grp 'INFLIGHT_JSON'                "INFLIGHT_JSON referenced in guard"              "guard missing INFLIGHT_JSON"
eq_count 'INFLIGHT_COUNT' 3 "INFLIGHT_COUNT guarded in 3 places (0c, GAP-1, GAP-2)" \
                             "guard missing INFLIGHT_COUNT guards"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
