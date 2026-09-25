#!/usr/bin/env bash
# gate-supersede-cross-repo-sibling.selftest.sh (ga-rhzbii)
#
# THE BUG (found by a gate-reviewer session, verified by the Mayor, 2026-09-25):
# ga-g7x0si was delivered as TWO branches in TWO repos — fix/ga-g7x0si-mockup-
# directions (HQ, marker ga-7mjxj6) and fix/ga-g7x0si-mockup-directions-wa
# (whatsapp_automation, marker ga-pzi1hw) — both correlated to the same source
# bead via the source-bead: label/description field. When the HQ marker
# PASSED and merged, TWO independent mechanisms in quality-gate-dispatcher.sh
# treated the WA sibling as a stale duplicate of the SAME submission instead
# of a genuinely different, still-in-flight delivery:
#
#   (1) supersede_sibling_runs() matched any OTHER gate-run bead carrying
#       "source_bead: <id>" in its description and closed it as "superseded"
#       — with no check that the sibling was even in the SAME repo/rig. The
#       WA gate-run got closed the instant the HQ run reached terminal, even
#       though the WA branch's own review had already reached PASS on its
#       own merits and was simply waiting to merge.
#   (2) The PASS path's close of the source bug/task bead (gate_close_source_
#       terminal, called right after the HQ merge) had NO check for other
#       still-open gate markers/runs on the same source-bead before closing
#       it — unlike story-delivery.sh's OPEN_SIBLINGS hold (ga-0m6tgc), which
#       already implements exactly this rule for story:approved beads. So the
#       source bead closed the moment the FIRST branch merged, and the CLOSED
#       bead then matched no re-spawn/re-pick selector — nothing would ever
#       revisit the WA branch. Its marker was left stuck in gate-status:
#       dispatching forever, with a PASS verdict (ga-zpy0pf) unmerged.
#
# THE FIX:
#   (1) supersede_sibling_runs() now takes a 4th <rig> argument (both PASS and
#       FAIL call sites pass $RIG) and only fires its bead_id-based match when
#       the sibling's OWN "rig:" description field equals this run's rig. The
#       marker_id-based match (a re-queued marker spawning a second run for
#       ITSELF) stays unconditional — that case can never legitimately cross a
#       rig boundary.
#   (2) The bug/task PASS-close branch now calls gate_bead_sibling_status_
#       lines($GC_CITY, $BEAD_ID) — the SAME helper story-delivery.sh already
#       uses for ga-0m6tgc — immediately before gate_close_source_terminal.
#       A non-empty result (another marker/gate-run for this source-bead is
#       still open) holds instead of closing (IS_SIBLING_HOLD=1, comment left,
#       gate:passed already blocks Pilot re-dispatch) and is re-checked every
#       sweep. IS_SIBLING_HOLD also exempts the bead from the POST-MERGE
#       VERIFICATION's Tier-1 open-bug re-spawn check, mirroring IS_PARTIAL/
#       IS_DAEMON_HOLD.
#
# This harness extracts supersede_sibling_runs() VERBATIM from the live
# dispatcher (it is defined AFTER the GATE_DISPATCHER_LIB_ONLY early-return,
# so it cannot be reached via the usual `GATE_DISPATCHER_LIB_ONLY=1 source`
# pattern — see gate-sibling-branch-guard.selftest.sh's own drift guard for
# functions that DO sit before that cutoff) and evals it in a subshell with a
# mocked `bd` and a real, temp-dir bd-list-cached.sh stub (the same technique
# quality-gate-reconcile.selftest.sh's Part 7f already uses for this exact
# "bash <script>` spawns a child the mock can't reach" problem). It also loads
# the REAL gate_bead_sibling_status_lines from quality-gate-guard.sh (pre-
# cutoff, mockable via GATE_GUARD_LIB_ONLY=1) to prove it already reports a
# cross-repo sibling as "still open" with no fix needed there. Exit 0 iff
# every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD" >&2; exit 2; }

echo "== gate-supersede-cross-repo-sibling.selftest (ga-rhzbii) =="

# ── 1. Extract supersede_sibling_runs() VERBATIM from the live dispatcher ────
echo "── 1. extract supersede_sibling_runs() from the live file ──"
FN_SUPERSEDE="$(awk '/^supersede_sibling_runs\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "$DISPATCHER")"
if [ -z "$FN_SUPERSEDE" ]; then
  echo "FATAL: could not extract supersede_sibling_runs() — function signature changed?" >&2
  exit 2
fi
ok "extracted supersede_sibling_runs() ($(printf '%s\n' "$FN_SUPERSEDE" | wc -l | tr -d ' ') lines)"
printf '%s\n' "$FN_SUPERSEDE" | grep -q 'local this_marker="\$1" branch="\$2" bead_id="\$3" rig="\${4:-}"' \
  && ok "signature takes a 4th rig argument" \
  || bad "signature missing the 4th rig argument — extraction or fix regressed"

# ── 2. Exercise the REAL extracted function against fixture bd-list-cached ───
echo "── 2. supersede_sibling_runs behavior (real fn, mocked bd + bd-list-cached.sh stub) ──"

FAKE_CITY="$(mktemp -d)"
mkdir -p "$FAKE_CITY/scripts"
trap 'rm -rf "$FAKE_CITY"' EXIT

run_supersede() {
  # $1=running_json fixture  $2=this_marker  $3=branch  $4=bead_id  $5=rig
  # Prints one line per `bd -C ... close <id>` call the extracted function made.
  cat > "$FAKE_CITY/scripts/bd-list-cached.sh" <<STUB
#!/usr/bin/env bash
cat <<'JSON'
$1
JSON
STUB
  chmod +x "$FAKE_CITY/scripts/bd-list-cached.sh"

  GC_CITY="$FAKE_CITY" bash -c '
    set -euo pipefail
    log()  { :; }
    warn() { :; }
    parse_marker_id() {
      local desc="$1"
      [ -z "$desc" ] && { echo ""; return; }
      local line
      line=$(printf "%s\n" "$desc" | grep -E "^marker_id:" | head -1 || true)
      [ -z "$line" ] && { echo ""; return; }
      printf "%s" "$line" | sed "s/^marker_id:[[:space:]]*//" | sed "s/[[:space:]]*\$//"
    }
    set_gate_status() { :; }
    bd() {
      case " $* " in
        *" close "*)
          # args: -C <city> close <id> -r <reason>
          echo "CLOSED:$4"
          ;;
        *) : ;;
      esac
    }
    '"$FN_SUPERSEDE"'
    supersede_sibling_runs '"$(printf '%q' "$2")"' '"$(printf '%q' "$3")"' '"$(printf '%q' "$4")"' '"$(printf '%q' "$5")"'
  ' 2>&1 | { grep '^CLOSED:' || true; } | sed 's/^CLOSED://'
}

# Case A (THE BUG, reproduced): sibling is a DIFFERENT repo/rig (WA) for the
# SAME source-bead, with a DIFFERENT marker_id. Pre-fix this closed r-wa;
# fixed behavior must leave it alone.
JSON_A='[{"id":"r-wa","description":"Autonomous gate run for fix/ga-g7x0si-mockup-directions-wa.\nsource_bead: ga-g7x0si\nrig: whatsapp_automation\nbranch: fix/ga-g7x0si-mockup-directions-wa\nmarker_id: ga-pzi1hw"}]'
CLOSED_A="$(run_supersede "$JSON_A" "ga-7mjxj6" "fix/ga-g7x0si-mockup-directions" "ga-g7x0si" "gascity")"
eq "ga-rhzbii repro: cross-repo sibling (rig=whatsapp_automation vs this rig=gascity) is NOT closed" \
  "$CLOSED_A" ""

# Case B (dedup still works): sibling is the SAME repo/rig, same source-bead,
# a genuine stale duplicate run of a re-queued marker — must still supersede.
JSON_B='[{"id":"r-dup","description":"Autonomous gate run for fix/ga-g7x0si-mockup-directions.\nsource_bead: ga-g7x0si\nrig: gascity\nbranch: fix/ga-g7x0si-mockup-directions\nmarker_id: ga-oldstale"}]'
CLOSED_B="$(run_supersede "$JSON_B" "ga-7mjxj6" "fix/ga-g7x0si-mockup-directions" "ga-g7x0si" "gascity")"
eq "same-rig sibling for the same source-bead IS still closed (dedup not removed, only narrowed)" \
  "$CLOSED_B" "r-dup"

# Case C: marker_id match (THIS marker spawned a 2nd run for itself) fires
# regardless of the sibling's rig field — a re-queue can never legitimately
# cross a rig boundary, so this branch stays unconditional.
JSON_C='[{"id":"r-samemarker","description":"Autonomous gate run for fix/x.\nsource_bead: ga-other\nrig: some-other-rig\nbranch: fix/x\nmarker_id: ga-7mjxj6"}]'
CLOSED_C="$(run_supersede "$JSON_C" "ga-7mjxj6" "fix/ga-g7x0si-mockup-directions" "ga-g7x0si" "gascity")"
eq "same marker_id (dead-dispatcher re-run of ITSELF) is closed regardless of rig field" \
  "$CLOSED_C" "r-samemarker"

# Case D (fail-safe): rig omitted/empty at the call site (e.g. an
# unresolved $RIG) must NOT fall back to the old unconditional bead_id-only
# match — better to skip a cleanup than risk cross-repo bulldozing again.
CLOSED_D="$(run_supersede "$JSON_B" "ga-7mjxj6" "fix/ga-g7x0si-mockup-directions" "ga-g7x0si" "")"
eq "rig omitted at call site → bead_id-only match does NOT fire (fails toward not-superseding)" \
  "$CLOSED_D" ""

rm -rf "$FAKE_CITY"
trap - EXIT

# ── 3. gate_bead_sibling_status_lines already reports a cross-repo sibling
#       as still-open — no fix needed there, just prove it (mock bd) ────────
echo "── 3. gate_bead_sibling_status_lines sees the cross-repo sibling as OPEN (real fn, mock bd) ──"
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }
type gate_bead_sibling_status_lines >/dev/null 2>&1 \
  || { echo "FATAL: gate_bead_sibling_status_lines not defined by guard (lib-only)"; exit 1; }
log()  { :; }
warn() { :; }

MOCK_SIB_JSON='[{"id":"m-wa","status":"open","labels":["type:quality-gate-marker","gate-status:dispatching","source-bead:ga-g7x0si"],"description":"branch: fix/ga-g7x0si-mockup-directions-wa\nbead_id: ga-g7x0si\nrig: whatsapp_automation\nbead_rig: gascity"},{"id":"m-hq-old","status":"closed","labels":["type:quality-gate-marker","gate-status:passed","source-bead:ga-g7x0si"],"description":"branch: fix/ga-g7x0si-mockup-directions\nbead_id: ga-g7x0si\nrig: gascity"}]'
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_SIB_JSON" ;;
    *) : ;;
  esac
  return 0
}
SIB_LINES="$(gate_bead_sibling_status_lines city ga-g7x0si)"
printf '%s\n' "$SIB_LINES" | grep -q 'fix/ga-g7x0si-mockup-directions-wa' \
  && ok "still-open cross-repo WA sibling appears in the sibling-status lines" \
  || bad "cross-repo WA sibling missing from sibling-status lines: got [$SIB_LINES]"
printf '%s\n' "$SIB_LINES" | grep -q 'fix/ga-g7x0si-mockup-directions[^-]' \
  && bad "CLOSED HQ marker incorrectly appears as an open sibling: got [$SIB_LINES]" \
  || ok "closed HQ marker correctly excluded (only the open WA sibling is reported)"

MOCK_SIB_JSON='[{"id":"m-hq-old","status":"closed","labels":["type:quality-gate-marker","gate-status:passed","source-bead:ga-g7x0si"],"description":"branch: fix/ga-g7x0si-mockup-directions\nbead_id: ga-g7x0si\nrig: gascity"}]'
SIB_LINES_NONE="$(gate_bead_sibling_status_lines city ga-g7x0si)"
eq "single-repo delivery (no open siblings left) → empty, close proceeds as before" \
  "$SIB_LINES_NONE" ""

# ── 4. Drift guards: call sites and wiring in the live dispatcher ───────────
echo "── 4. drift guards: call sites pass \$RIG; close path checks siblings first ──"
CALLS_WITH_RIG=$(grep -c 'supersede_sibling_runs "\$MARKER_ID" "\$BRANCH" "\$BEAD_ID" "\$RIG"' "$DISPATCHER" || true)
[ "${CALLS_WITH_RIG:-0}" -eq 2 ] \
  && ok "both supersede_sibling_runs call sites (PASS + FAIL) pass \$RIG" \
  || bad "expected exactly 2 supersede_sibling_runs(...\$RIG) call sites, found ${CALLS_WITH_RIG:-0}"
! grep -q 'supersede_sibling_runs "\$MARKER_ID" "\$BRANCH" "\$BEAD_ID"$' "$DISPATCHER" \
  && ok "no remaining 3-arg (no-rig) supersede_sibling_runs call sites" \
  || bad "a 3-arg supersede_sibling_runs call site remains — rig check bypassed there"

has "$DISPATCHER" 'OPEN_SIBLINGS_FOR_CLOSE=\$\(gate_bead_sibling_status_lines "\$GC_CITY" "\$BEAD_ID"' \
  "PASS-path bug/task close computes OPEN_SIBLINGS_FOR_CLOSE via gate_bead_sibling_status_lines"
has "$DISPATCHER" 'IS_SIBLING_HOLD=1' \
  "IS_SIBLING_HOLD is set when a sibling is still open"
has "$DISPATCHER" 'IS_SIBLING_HOLD" != "1"' \
  "POST-MERGE VERIFICATION Tier-1 re-spawn check is exempted by IS_SIBLING_HOLD"

SIB_CHECK_LN=$(grep -n 'OPEN_SIBLINGS_FOR_CLOSE=\$(gate_bead_sibling_status_lines' "$DISPATCHER" | head -1 | cut -d: -f1)
CLOSE_CALL_LN=$(grep -n 'if gate_close_source_terminal "\$BEAD_ID" "\$_CLOSE_REASON" 1; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$SIB_CHECK_LN" ] && [ -n "$CLOSE_CALL_LN" ] && [ "$SIB_CHECK_LN" -lt "$CLOSE_CALL_LN" ]; then
  ok "sibling check (line $SIB_CHECK_LN) precedes the source-bead close call (line $CLOSE_CALL_LN)"
else
  bad "expected sibling check before close call (sibling=$SIB_CHECK_LN close=$CLOSE_CALL_LN)"
fi

# ── 5. syntax ────────────────────────────────────────────────────────────────
echo "── 5. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
