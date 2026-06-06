#!/usr/bin/env bash
# story-delivery-staleness.test.sh — regression test for the post-deploy
# town-root staleness gate (Step 4.5, ga-rhtu) in story-delivery.sh.
#
# Extracts the REAL Step 4.5 block from story-delivery.sh (no duplication) and
# drives it with stubbed git/bd/gc/timeout to prove:
#   S1 CURRENT      — origin/<branch> is an ancestor of HEAD (current or merely
#                     local-ahead) → delivery PROCEEDS (exit 0, no delivery:failed).
#   S2 STALE        — origin/<branch> is NOT an ancestor of HEAD (behind/diverged)
#                     → delivery HALTS: delivery:failed added, delivery:running
#                     removed, story:done NOT set, author + mayor nudged.
#   S3 UNVERIFIABLE — origin/<branch> cannot be resolved → fail-closed HALT (same
#                     loud halt as S2), so a stale tree is never marked done.
#   S4 OUT-OF-SCOPE — a FATAL ff-pull deploy_cmd (no "|| true") → gate does NOT
#                     run (those rigs already halt at Step 4), exit 0, no git probes.
#   S5 MULTI-STORY  — rig-unknown halt on .[0] does NOT starve .[1] (loop iterates).
#   S6 MULTI-STORY  — no-deploy-cmd halt on .[0] does NOT starve .[1].
#
# This is the ga-rhtu acceptance test: "a regression test simulates a
# behind/diverged town root and asserts delivery does NOT mark story:done".
# ga-t1hc adds S5/S6: multi-story loop coverage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 4.5 block (from its header up to, but excluding, Step 5).
BLOCK="$(sed -n '/Step 4.5: Post-deploy town-root staleness gate/,/# ── Step 5: Daemon restarts/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 4.5 block"; exit 1; }

# run_block <scenario> <deploy_cmd>
#   scenario ∈ {CURRENT, STALE, UNVERIFIABLE}; controls the git stub's verdict.
#   deploy_cmd toggles whether the gate is in scope (swallowed vs fatal pull).
#   The block is wrapped in a for-loop so `continue` (loop-based halt) is valid.
run_block() {
  SCENARIO="$1"
  local deploy_cmd="$2"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"; mkdir -p "$GC_CITY"
  BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"; GIT_LOG="$T/git.log"

  # git stub — strips a leading "-C <dir>", then dispatches on the subcommand.
  # Records every invocation to GIT_LOG so S4 can assert the gate never probes.
  git() {
    echo "git $*" >> "$GIT_LOG"
    if [ "${1:-}" = "-C" ]; then shift 2; fi
    local sub="${1:-}"; shift || true
    case "$sub" in
      rev-parse)
        case "${1:-}" in
          --is-inside-work-tree) return 0 ;;
          --abbrev-ref)          echo "main"; return 0 ;;
          HEAD)                  echo "headsha_HEAD"; return 0 ;;
          origin/main)
            [ "$SCENARIO" = "UNVERIFIABLE" ] && return 1
            echo "remotesha_ORIGIN"; return 0 ;;
          *) return 0 ;;
        esac ;;
      fetch)      return 0 ;;
      merge-base) [ "$SCENARIO" = "CURRENT" ] && return 0 || return 1 ;;  # --is-ancestor
      rev-list)   printf '3\t0\n'; return 0 ;;
      *)          return 0 ;;
    esac
  }
  # timeout passthrough so `timeout 30 git ...` reaches the git function stub.
  timeout() { shift; "$@"; }
  bd()  { echo "bd $*"  >> "$BD_LOG"; }
  gc()  { echo "gc $*"  >> "$GC_LOG"; }
  log() { :; }; warn() { :; }; err() { :; }

  # Variables the block reads.
  local RIG="gascity"
  local RUNTIME_DIR="/tmp/fake-town-root"     # non-empty
  local DEPLOY_CMD="$deploy_cmd"
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'

  # Wrap in a for-loop so the block's `continue` (loop-based halt) is valid.
  ( for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG"  2>/dev/null || true)"
  LAST_GC="$(cat "$GC_LOG"  2>/dev/null || true)"
  LAST_GIT="$(cat "$GIT_LOG" 2>/dev/null || true)"
  unset -f git timeout bd gc log warn err
  rm -rf "$T"
}

SWALLOWED='git -C /Users/athos/gt pull --ff-only origin main 2>/dev/null || true; /x/install.sh'
FATAL='git -C /Users/athos/gt pull --ff-only'

# ── S1: CURRENT → proceed ─────────────────────────────────────────────────────
run_block CURRENT "$SWALLOWED"
[ "$RUN_RC" -eq 0 ] && ok "S1 CURRENT → block exits 0 (proceeds)" || nok "S1 exit" "rc=$RUN_RC"
! echo "$LAST_BD" | grep -q "delivery:failed" && ok "S1 no delivery:failed label" || nok "S1 failed-label" "$LAST_BD"

# ── S2: STALE (behind/diverged) → HALT, no story:done ─────────────────────────
run_block STALE "$SWALLOWED"
# Block halts via `continue` (loop-based); for-loop exits 0. BD state is the halt signal.
[ "$RUN_RC" -eq 0 ] && ok "S2 STALE → block exits 0 (continue-based halt; BD state is primary signal)" || nok "S2 rc" "rc=$RUN_RC"
echo "$LAST_BD" | grep -q "label add ga-test delivery:failed" && ok "S2 delivery:failed added" || nok "S2 failed-label" "$LAST_BD"
echo "$LAST_BD" | grep -q "label remove ga-test delivery:running" && ok "S2 delivery:running removed" || nok "S2 running-removed" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "S2 story:done label NOT set" || nok "S2 story-done" "$LAST_BD"
echo "$LAST_GC" | grep -q "session nudge mayor" && ok "S2 mayor nudged" || nok "S2 mayor-nudge" "$LAST_GC"
echo "$LAST_GC" | grep -q "session nudge crew/tester" && ok "S2 author nudged" || nok "S2 author-nudge" "$LAST_GC"

# ── S3: UNVERIFIABLE → fail-closed HALT ───────────────────────────────────────
run_block UNVERIFIABLE "$SWALLOWED"
# Block halts via `continue`; for-loop exits 0. BD state is the halt signal.
[ "$RUN_RC" -eq 0 ] && ok "S3 UNVERIFIABLE → block exits 0 (continue-based fail-closed; BD state is primary signal)" || nok "S3 rc" "rc=$RUN_RC"
echo "$LAST_BD" | grep -q "label add ga-test delivery:failed" && ok "S3 delivery:failed added" || nok "S3 failed-label" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label add ga-test story:done" && ok "S3 story:done label NOT set" || nok "S3 story-done" "$LAST_BD"

# ── S4: OUT-OF-SCOPE (fatal ff-pull) → gate skipped entirely ──────────────────
run_block STALE "$FATAL"
[ "$RUN_RC" -eq 0 ] && ok "S4 fatal-pull rig → gate skipped, exits 0" || nok "S4 exit" "rc=$RUN_RC"
[ -z "$LAST_GIT" ] && ok "S4 no git probes (gate inactive for fatal-pull rigs)" || nok "S4 git-probed" "$LAST_GIT"
! echo "$LAST_BD" | grep -q "delivery:failed" && ok "S4 no delivery:failed label" || nok "S4 failed-label" "$LAST_BD"

# ── S5/S6: Multi-story regression (loop continues past .[0] halt) ─────────────
# Runs the FULL delivery script in DRY_RUN=1 with a 2-story fixture: .[0] halts
# (via continue), .[1] should reach sweep-complete in the SAME sweep.

run_sweep_multi() {
  local HALT_TYPE="$1"
  local T; T="$(mktemp -d)"

  # Story A — triggers halt
  local A_JSON
  case "$HALT_TYPE" in
    RIG_UNKNOWN)
      # No rig label/metadata → rig-undeterminable (264-class) → continue
      A_JSON='{"id":"ga-ms-a","title":"story-a-no-rig","description":"halt","status":"open","labels":["story:approved","gate:passed"],"metadata":{}}'
      ;;
    NO_DEPLOY_CMD)
      # 'lexbh' rig has deploy_cmd="" → no-deploy-cmd (283-class) → continue
      A_JSON='{"id":"ga-ms-a","title":"story-a-no-deploy","description":"halt","status":"open","labels":["story:approved","gate:passed","rig:lexbh"],"metadata":{}}'
      ;;
  esac
  # Story B — property_scrapers: deploy_cmd present, prod_test_script on disk → proceeds in DRY_RUN.
  local B_JSON='{"id":"ga-ms-b","title":"story-b-valid","description":"proceed","status":"open","labels":["story:approved","gate:passed","rig:property_scrapers"],"metadata":{}}'

  local FIXTURE="$T/stories.json"
  echo "[$A_JSON,$B_JSON]" > "$FIXTURE"

  # PATH stubs — bd, git, gc, notify, launchctl
  mkdir -p "$T/bin"

  # bd: list → fixture; comments/show → safe empty defaults; else → true
  cat > "$T/bin/bd" << BDEOF
#!/usr/bin/env bash
case "\$*" in
  *list*)     cat "$FIXTURE" ;;
  *comments*) echo "[]" ;;
  *show*)     echo '{"id":"x","labels":[],"metadata":{}}' ;;
  *)          true ;;
esac
BDEOF

  # git: is-inside-work-tree → exit 1 so reconcile/daemon-refresh skip cleanly
  cat > "$T/bin/git" << 'GITEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
sub="${1:-}"; shift 2>/dev/null || true
case "$sub" in
  rev-parse)
    case "${1:-}" in
      --is-inside-work-tree) exit 1 ;;
      HEAD) echo "deadbeef00"; exit 0 ;;
      --abbrev-ref) echo "main"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
GITEOF

  for cmd in gc notify launchctl; do
    printf '#!/usr/bin/env bash\ntrue\n' > "$T/bin/$cmd"
  done
  chmod +x "$T/bin/bd" "$T/bin/git" "$T/bin/gc" "$T/bin/notify" "$T/bin/launchctl"

  # Track log growth (GC_CITY is hardcoded in the delivery script)
  local LOG_FILE="/Users/athos/gt/.gascity-gastown-hq/.gc/logs/story-delivery.log"
  local LOG_LINES=0
  [ -f "$LOG_FILE" ] && LOG_LINES=$(wc -l < "$LOG_FILE" | tr -d ' ')

  PATH="$T/bin:$PATH" DRY_RUN=1 bash "$DELIVERY" >/dev/null 2>&1 || true

  SWEEP_LOG=""
  if [ -f "$LOG_FILE" ]; then
    SWEEP_LOG=$(tail -n "+$((LOG_LINES+1))" "$LOG_FILE" 2>/dev/null || true)
  fi

  rm -rf "$T"
}

# ── S5: Multi-story — rig-unknown halt on .[0] does NOT block .[1] ────────────
run_sweep_multi RIG_UNKNOWN
echo "$SWEEP_LOG" | grep -q "Processing story ga-ms-a" && ok "S5 .[0] ga-ms-a was attempted" || nok "S5 a-attempted" "$(echo "$SWEEP_LOG" | tail -5)"
echo "$SWEEP_LOG" | grep -q "Processing story ga-ms-b" && ok "S5 .[1] ga-ms-b was attempted (not starved)" || nok "S5 b-not-starved" "$(echo "$SWEEP_LOG" | tail -5)"
echo "$SWEEP_LOG" | grep -q "Delivery sweep complete.*ga-ms-b" && ok "S5 .[1] ga-ms-b reached sweep-complete" || nok "S5 b-complete" "$(echo "$SWEEP_LOG" | grep -E 'ms-b|finished' | tail -5 || echo '(no ms-b lines)')"

# ── S6: Multi-story — no-deploy-cmd halt on .[0] does NOT block .[1] ──────────
run_sweep_multi NO_DEPLOY_CMD
echo "$SWEEP_LOG" | grep -q "Processing story ga-ms-a" && ok "S6 .[0] ga-ms-a was attempted" || nok "S6 a-attempted" "$(echo "$SWEEP_LOG" | tail -5)"
echo "$SWEEP_LOG" | grep -q "Processing story ga-ms-b" && ok "S6 .[1] ga-ms-b was attempted (not starved)" || nok "S6 b-not-starved" "$(echo "$SWEEP_LOG" | tail -5)"
echo "$SWEEP_LOG" | grep -q "Delivery sweep complete.*ga-ms-b" && ok "S6 .[1] ga-ms-b reached sweep-complete" || nok "S6 b-complete" "$(echo "$SWEEP_LOG" | grep -E 'ms-b|finished' | tail -5 || echo '(no ms-b lines)')"

echo ""
echo "story-delivery staleness-gate tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
