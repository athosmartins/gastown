#!/usr/bin/env bash
# story-delivery-halt-attribution-presentation.test.sh — regression test for
# ga-9lug2k (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh and the other
# story-delivery-daemon-refresh-*.test.sh files).
#
# THE BUG: story-delivery.sh's Step 5b already computes TWO daemon-refresh.sh
# results per no-op-pull story: a WIDE one (baseline..POST, "is anything
# stale") and a NARROW one (MERGE_PRE_MAIN..MERGE_SHA, "does THIS story's own
# merge reach a live daemon" — ga-6zkhci's MERGE_OWN_* fallback). Both are
# real. But the HALT posted to the bead only ever showed the WIDE list
# (${REFRESH_GUARDED}, often ~50 daemons after several merges touch a
# widely-imported lib) — the precise, already-computed NARROW list
# (${MERGE_OWN_AFFECTED}, 1-2 daemons) never reached the bead text at all,
# only a log line. Measured live (2026-09-16, wa-b26ju and wa-gyqzr, two
# deliveries in a row): each halt cost ~30-60min of agent time re-deriving by
# hand what this script had already computed a few lines above — and in
# wa-gyqzr's case, the wide list didn't even CONTAIN the one daemon that
# actually needed restarting (a real daemon can be older than its own
# closure from an EARLIER, unrelated merge — that's not this story's fault).
#
# THE FIX: when the narrow probe ran and returned a real, non-empty
# attribution for THIS story (THIS_PULL_STRUCTURALLY_INERT="0" and
# MERGE_OWN_AFFECTED non-empty), lead the HALT's ACTION text with "restart
# THESE for this merge" naming the narrow list, and demote the wide list to a
# clearly-marked "Context only — NOT attributed to this merge" line. When no
# narrow attribution is available this run (Path A, or the probe crashed/
# timed out), fall back to the original wide-list-only wording unchanged —
# never invent a claim the script cannot back up.
#
# T1: wide window and narrow probe disagree — wide flags TWO daemons (one
#     from an EARLIER, unrelated merge; one this story's own merge caused),
#     narrow flags only the ONE this story's own merge reaches. The halt's
#     leading ACTION text must name only the narrow daemon; the OTHER,
#     unrelated daemon must appear only in the demoted "Context only" line,
#     never in the leading action. Reproduces wa-gyqzr's exact shape.
# T2: control — no narrow attribution available this run (own delta is
#     tests/docs/md-only, MERGE_OWN_AFFECTED stays empty because
#     THIS_PULL_STRUCTURALLY_INERT="1" takes the "not blamed" branch instead
#     of ever reaching the halt at all) — covered by the existing
#     no-op-attribution T1/T2; this file's T3 below instead covers the
#     "probe ran but returned nothing" precise-fallback case directly.
# T3: control — narrow probe never ran for this story (Path A: PRE_DEPLOY_SHA
#     != POST_DEPLOY_SHA) → MERGE_OWN_AFFECTED stays empty (reset, never set)
#     → the halt ACTION text must fall back to the ORIGINAL wide-list-only
#     wording, explicitly noting no per-bead attribution was available —
#     never silently omit the wide list just because it's now "secondary".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to the other story-delivery-*.test.sh files.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"

# run_block <mode>
#   "disagree" (T1): true no-op pull (PRE==POST==own tip). Wide call (DRY_RUN
#     unset) sees old_sensitive.py (C1, an earlier unrelated merge) AND
#     new_sensitive.py (this story's own C2) → GUARDED names BOTH daemons.
#     Narrow call (DRY_RUN=1, MERGE_PRE_MAIN=C1..MERGE_SHA=C2) sees ONLY
#     new_sensitive.py → AFFECTED names only the one this story caused.
#   "path_a" (T3): PRE_DEPLOY_SHA=C0 != POST_DEPLOY_SHA=C2 (a real pull
#     happened) → Step 5b never calls the narrow per-bead probe at all (that
#     fallback is scoped to the true no-op branch only) → MERGE_OWN_AFFECTED
#     stays at its reset empty value all the way to the halt.
run_block() {
  local mode="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/lib"
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  echo old > "$REPO/lib/old_sensitive.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"
  echo new > "$REPO/lib/new_sensitive.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C2
  local SHA_C2; SHA_C2="$(git -C "$REPO" rev-parse HEAD)"

  # Widen the wide-window baseline to C0 so it spans C1's old_sensitive.py —
  # simulates a real, unresolved staleness from an EARLIER, unrelated merge.
  mkdir -p "$GC_CITY/$(dirname "$MARKER_REL")"
  printf '%s\n' "$SHA_C0" > "$GC_CITY/$MARKER_REL"

  # Fake daemon-refresh.sh: classifies whatever range it's asked about by
  # actually diffing PRE..POST itself, naming a daemon per changed sensitive
  # file — exactly like a real per-daemon reachability check would, so the
  # wide and narrow calls can genuinely disagree the way wa-gyqzr's did.
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<'EOF'
CHANGED="$(git -C "$RUNTIME_DIR" diff --name-only "$PRE_DEPLOY_SHA" "$POST_DEPLOY_SHA" 2>/dev/null)"
NAMES=""
echo "$CHANGED" | grep -q "old_sensitive\.py" && NAMES="$NAMES com.test.old-daemon"
echo "$CHANGED" | grep -q "new_sensitive\.py" && NAMES="$NAMES com.test.new-daemon"
NAMES="${NAMES# }"
if [ -n "$NAMES" ]; then
  echo "VERDICT=NEEDS_GUARDED_RESTART"
  echo "AFFECTED=$NAMES"
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED=$NAMES"
  echo "REASON=sensitive hot-path daemon(s) need a guarded restart"
  exit 1
else
  echo "VERDICT=OK"
  echo "AFFECTED="
  echo "RESTARTED="
  echo "FRESH_FAIL="
  echo "GUARDED="
  echo "REASON=no daemon imports the changed files"
  exit 0
fi
EOF

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  local PRE_DEPLOY_SHA POST_DEPLOY_SHA MERGE_SHA MERGE_REF MERGE_PRE_MAIN
  case "$mode" in
    disagree)
      # True no-op pull: something else already advanced HEAD to this
      # story's own tip before PRE_DEPLOY_SHA was captured (ga-gokm6).
      PRE_DEPLOY_SHA="$SHA_C2"; POST_DEPLOY_SHA="$SHA_C2"
      MERGE_SHA="$SHA_C2"; MERGE_REF="origin/main"; MERGE_PRE_MAIN="$SHA_C1"
      ;;
    path_a)
      # A real pull happened this iteration — the narrow per-bead fallback
      # (scoped to PRE_DEPLOY_SHA==POST_DEPLOY_SHA only) never triggers.
      PRE_DEPLOY_SHA="$SHA_C0"; POST_DEPLOY_SHA="$SHA_C2"
      MERGE_SHA="$SHA_C2"; MERGE_REF="origin/main"; MERGE_PRE_MAIN="$SHA_C1"
      ;;
    *)
      echo "run_block: unknown mode '$mode'" >&2; exit 1 ;;
  esac
  get_runbook_field() { echo "old-daemon new-daemon"; }

  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  rm -rf "$T"
}

# ── T1 (mode=disagree): wide flags BOTH old+new daemons, narrow flags only
#    new — halt must lead with new-daemon only, demote old-daemon to context
#    ("Context only" line), reproducing wa-gyqzr's exact shape ────────────
run_block disagree
[ "$RUN_RC" -eq 0 ] && ok "T1 block runs clean (rc=0; continue-based halt, BD state is the signal)" \
  || nok "T1 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T1 own-merge probe classified NOT inert (new_sensitive.py is a real hit)" \
  || nok "T1 inert classification" "$LOG_OUT"
COMMENT_CALL="$(echo "$BD_CALLS" | grep "bd -C .* comment ga-test" || true)"
[ -n "$COMMENT_CALL" ] && ok "T1 halt comment was posted" || nok "T1 no comment call found" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "restart THESE for this merge" \
  && ok "T1 halt leads with the per-bead attribution phrase" \
  || nok "T1 missing lead-with phrase" "$BD_CALLS"
LEAD_PART="$(echo "$BD_CALLS" | awk '/Context only/{exit} {print}')"
echo "$LEAD_PART" | grep -q "com.test.new-daemon" \
  && ok "T1 leading action names the precisely-attributed daemon (new-daemon)" \
  || nok "T1 lead missing new-daemon" "$LEAD_PART"
echo "$LEAD_PART" | grep -q "com.test.old-daemon" \
  && nok "T1 leading action wrongly names the unattributed daemon (old-daemon leaked into the lead)" "$LEAD_PART" \
  || ok "T1 leading action does NOT name the unattributed daemon (old-daemon kept out of the lead)"
echo "$BD_CALLS" | grep -q "Context only — NOT attributed to this merge" \
  && ok "T1 wide list demoted to an explicitly-marked context line" \
  || nok "T1 missing context-demotion marker" "$BD_CALLS"
CONTEXT_PART="$(echo "$BD_CALLS" | awk '/Context only/{p=1} p{print}')"
echo "$CONTEXT_PART" | grep -q "com.test.old-daemon" \
  && ok "T1 demoted context line still names the unattributed daemon (nothing hidden, just de-prioritized)" \
  || nok "T1 old-daemon missing entirely from context line" "$CONTEXT_PART"

# ── T3 (mode=path_a): a real pull happened, narrow probe never ran → no
#    per-bead attribution this run → falls back to the ORIGINAL wide-list-
#    only wording, explicitly saying so (never silently drops the wide list,
#    never fabricates a "restart THESE" claim it can't back up) ───────────
run_block path_a
[ "$RUN_RC" -eq 0 ] && ok "T3 block runs clean (rc=0)" || nok "T3 rc" "rc=$RUN_RC"
echo "$LOG_OUT" | grep -q "this-pull-structurally-inert=0" \
  && ok "T3 own-merge classified via the static tests/docs/md pattern (Path A), not the probe" \
  || nok "T3 inert classification" "$LOG_OUT"
! echo "$BD_CALLS" | grep -q "restart THESE for this merge" \
  && ok "T3 halt does NOT claim a per-bead attribution it never computed" \
  || nok "T3 wrongly claimed per-bead attribution" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "No per-bead attribution available this run" \
  && ok "T3 halt explicitly says why (falls back to wide-list-only, honestly)" \
  || nok "T3 missing fallback explanation" "$BD_CALLS"
echo "$BD_CALLS" | grep -q "com.test.new-daemon" \
  && ok "T3 wide list (the only list available) still names the real finding" \
  || nok "T3 wide list missing from fallback halt" "$BD_CALLS"

echo ""
echo "story-delivery halt attribution presentation tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
