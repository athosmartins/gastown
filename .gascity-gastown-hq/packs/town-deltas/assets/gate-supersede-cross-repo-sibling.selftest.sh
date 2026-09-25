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
#   (2) The bug/task PASS-close branch now calls gate_sibling_hold_check(), a
#       thin wrapper over gate_bead_sibling_status_lines() — the SAME helper
#       story-delivery.sh already uses for ga-0m6tgc — immediately before
#       gate_close_source_terminal. It tells three outcomes apart: no open
#       sibling (close as before), an OPEN sibling (SIBLING_HOLD_KIND=open),
#       and a FAILED bd query (SIBLING_HOLD_KIND=unverified — siblings unknown,
#       not confirmed open). Either non-empty outcome holds instead of closing
#       (IS_SIBLING_HOLD=1, comment left, gate:passed already blocks Pilot
#       re-dispatch). The hold is NOT re-checked by a later dispatcher sweep:
#       the bead is released when the OTHER marker's own PASS re-runs the check
#       and finds nothing else open, or by hand — the bead comment says so and
#       names the manual action. IS_SIBLING_HOLD also exempts the bead from the
#       POST-MERGE VERIFICATION's Tier-1 open-bug re-spawn check, mirroring
#       IS_PARTIAL/IS_DAEMON_HOLD.
#
#   Gate attempt 1 of this bead FAILED on two things in that hold branch, both
#   now fixed AND covered by Sections 5-6 below (the branch was previously only
#   grep-checked, which is why 16/16 green missed both): (a) the helper call
#   carried 2>/dev/null, discarding the helper's bd-query-failure ALERT and
#   presenting a failed query as "a sibling is open"; (b) the log line and bead
#   comment promised "re-checked every dispatcher sweep" — a retry that does not
#   exist.
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
# cross-repo sibling as "still open" with no fix needed there. Sections 5-6
# extract gate_sibling_hold_check() and the inline hold block (both wrapped in
# SELFTEST-EXTRACT markers in the dispatcher) and RUN them against a mocked bd
# — including a failing one. Exit 0 iff every assertion holds.

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

has "$DISPATCHER" '^ +gate_sibling_hold_check "\$GC_CITY" "\$BEAD_ID"$' \
  "PASS-path bug/task close consults gate_sibling_hold_check before closing"
# The false-promise wording gate attempt 1 caught: no retry exists, so no text
# may claim one. (Both the log line and the bead comment used to say it.)
! grep -qE 'Re-checked every (dispatcher )?sweep|closes automatically once every marker/run' "$DISPATCHER" \
  && ok "no 'checked every sweep / closes automatically' promise remains in the dispatcher" \
  || bad "dispatcher still promises a per-sweep re-check / automatic close that nothing implements"
has "$DISPATCHER" 'IS_SIBLING_HOLD=1' \
  "IS_SIBLING_HOLD is set when a sibling is still open"
has "$DISPATCHER" 'IS_SIBLING_HOLD" != "1"' \
  "POST-MERGE VERIFICATION Tier-1 re-spawn check is exempted by IS_SIBLING_HOLD"

SIB_CHECK_LN=$(grep -nE '^ +gate_sibling_hold_check "\$GC_CITY" "\$BEAD_ID"$' "$DISPATCHER" | head -1 | cut -d: -f1)
CLOSE_CALL_LN=$(grep -n 'if gate_close_source_terminal "\$BEAD_ID" "\$_CLOSE_REASON" 1; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$SIB_CHECK_LN" ] && [ -n "$CLOSE_CALL_LN" ] && [ "$SIB_CHECK_LN" -lt "$CLOSE_CALL_LN" ]; then
  ok "sibling check (line $SIB_CHECK_LN) precedes the source-bead close call (line $CLOSE_CALL_LN)"
else
  bad "expected sibling check before close call (sibling=$SIB_CHECK_LN close=$CLOSE_CALL_LN)"
fi

# ── 5. gate_sibling_hold_check(): RUN it (real fn, mocked bd) ────────────────
# Gate attempt 1 failed on a defect in this exact branch that Section 4's greps
# could not see. Here the real extracted function runs against a mocked bd —
# including one that FAILS — and the three outcomes must stay distinguishable.
echo "── 5. gate_sibling_hold_check(): none / open / unverified, and the ALERT survives ──"
FN_HOLD="$(awk '/SELFTEST-EXTRACT sibling-hold-check-fn: BEGIN/{f=1;next} /SELFTEST-EXTRACT sibling-hold-check-fn: END/{f=0} f' "$DISPATCHER")"
[ -n "$FN_HOLD" ] || { echo "FATAL: could not extract gate_sibling_hold_check() — SELFTEST-EXTRACT markers moved?" >&2; exit 2; }
ok "extracted gate_sibling_hold_check() ($(printf '%s\n' "$FN_HOLD" | wc -l | tr -d ' ') lines)"
eval "$FN_HOLD"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ERR_F="$WORK_DIR/stderr"; LOG_F="$WORK_DIR/log"; COMMENT_F="$WORK_DIR/comments"; LABEL_F="$WORK_DIR/labels"
MOCK_OPEN_JSON='[{"id":"m-wa","status":"open","labels":["type:quality-gate-marker","gate-status:dispatching","source-bead:ga-g7x0si"],"description":"branch: fix/ga-g7x0si-mockup-directions-wa\nbead_id: ga-g7x0si\nrig: whatsapp_automation\nbead_rig: gascity"}]'
MOCK_BD_MODE=none
# Dispatch on the VERB ($3, after `-C <city>`), never on a substring of "$*":
# a comment body can contain the words "list" or "comment".
bd() {
  case "${3:-}" in
    list)
      case "$MOCK_BD_MODE" in
        fail) return 1 ;;
        open) printf '%s\n' "$MOCK_OPEN_JSON" ;;
        *)    printf '[]\n' ;;
      esac ;;
    comment) printf '%s\n----\n' "${5:-}" >> "$COMMENT_F" ;;
    label)   printf '%s\n' "$*" >> "$LABEL_F" ;;
  esac
  return 0
}
log() { printf '%s\n' "$*" >> "$LOG_F"; }

: > "$ERR_F"; MOCK_BD_MODE=none; gate_sibling_hold_check city ga-g7x0si 2>"$ERR_F"
eq "no open siblings → SIBLING_HOLD_KIND empty (close proceeds as before)" "$SIBLING_HOLD_KIND" ""
eq "no open siblings → no rows" "$OPEN_SIBLINGS_FOR_CLOSE" ""

: > "$ERR_F"; MOCK_BD_MODE=open; gate_sibling_hold_check city ga-g7x0si 2>"$ERR_F"
eq "a real open cross-repo sibling → SIBLING_HOLD_KIND=open" "$SIBLING_HOLD_KIND" "open"
printf '%s\n' "$OPEN_SIBLINGS_FOR_CLOSE" | grep -q 'fix/ga-g7x0si-mockup-directions-wa' \
  && ok "the open sibling's branch is in the rows" || bad "open sibling row missing: [$OPEN_SIBLINGS_FOR_CLOSE]"

# THE gate-attempt-1 blocker: a FAILED query must be reported as UNVERIFIED —
# not as "a sibling is open" — and the helper's ALERT must reach stderr ($LOG).
: > "$ERR_F"; MOCK_BD_MODE=fail; gate_sibling_hold_check city ga-g7x0si 2>"$ERR_F"
eq "failed bd query → SIBLING_HOLD_KIND=unverified (NOT 'open', NOT empty)" "$SIBLING_HOLD_KIND" "unverified"
grep -q 'ALERT: gate_bead_sibling_status_lines query FAILED' "$ERR_F" \
  && ok "the bd-query-failure ALERT reaches stderr (not swallowed)" \
  || bad "the bd-query-failure ALERT was swallowed — stderr was: [$(cat "$ERR_F")]"

# A helper that EXITS non-zero (undefined, killed) is a fourth way of not
# knowing. It must read as unverified, never as "no siblings" (which closes).
_SAVED_HELPER="$(declare -f gate_bead_sibling_status_lines)"
gate_bead_sibling_status_lines() { return 3; }
: > "$ERR_F"; gate_sibling_hold_check city ga-g7x0si 2>"$ERR_F"
eq "helper exits non-zero → SIBLING_HOLD_KIND=unverified (NOT 'no siblings' → close)" "$SIBLING_HOLD_KIND" "unverified"
eval "$_SAVED_HELPER"

# MUTATION: re-add the 2>/dev/null the reviewer flagged. The ALERT assertion
# above must then go red — proving it catches the old defect, not just passes.
_pat='"$bead_id") || _rc'; _rep='"$bead_id" 2>/dev/null) || _rc'
FN_HOLD_MUT="${FN_HOLD//"$_pat"/$_rep}"
if [ "$FN_HOLD_MUT" = "$FN_HOLD" ]; then
  bad "mutation did not apply (helper call line changed?) — the ALERT assertion is unproven"
else
  eval "$FN_HOLD_MUT"
  : > "$ERR_F"; MOCK_BD_MODE=fail; gate_sibling_hold_check city ga-g7x0si 2>"$ERR_F"
  if grep -q 'ALERT: gate_bead_sibling_status_lines query FAILED' "$ERR_F"; then
    bad "mutation (2>/dev/null re-added) did NOT hide the ALERT — the ALERT assertion cannot catch the old defect"
  else
    ok "mutation: re-adding 2>/dev/null hides the ALERT → the assertion above goes red on the old code"
  fi
  eval "$FN_HOLD"
fi

# ── 6. the inline hold block: RUN it, read what it tells the operator ─────────
echo "── 6. inline hold block: wording for open / unverified / none (real block, mocked bd) ──"
BLOCK="$(awk '/SELFTEST-EXTRACT sibling-hold-block: BEGIN/{f=1;next} /SELFTEST-EXTRACT sibling-hold-block: END/{f=0} f' "$DISPATCHER")"
[ -n "$BLOCK" ] || { echo "FATAL: could not extract the sibling-hold block — SELFTEST-EXTRACT markers moved?" >&2; exit 2; }
ok "extracted the sibling-hold block ($(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ') lines)"

run_block() {  # $1 = MOCK_BD_MODE ; resets fixtures; leaves results in files + IS_SIBLING_HOLD
  MOCK_BD_MODE="$1"; : > "$ERR_F"; : > "$LOG_F"; : > "$COMMENT_F"; : > "$LABEL_F"
  GC_CITY=city; BEAD_CITY=beadcity; BEAD_ID=ga-g7x0si; BRANCH=fix/ga-g7x0si-mockup-directions
  RIG=gascity; DEFAULT_BRANCH=main; MERGE_SHA=abc1234; IS_SIBLING_HOLD=0
  eval "$BLOCK" 2>"$ERR_F"
}

run_block open
eq "open sibling → IS_SIBLING_HOLD=1" "$IS_SIBLING_HOLD" "1"
grep -q 'fix/ga-g7x0si-mockup-directions-wa' "$COMMENT_F" && ok "comment names the still-open sibling branch" || bad "comment does not name the sibling: [$(cat "$COMMENT_F")]"
grep -q 'NOT re-checked by a later sweep' "$COMMENT_F" && ok "comment states honestly that there is no per-sweep re-check" || bad "comment lacks the no-re-check statement"
grep -q "close it by hand" "$COMMENT_F" && ok "comment names the manual release action for a failed/discarded sibling" || bad "comment lacks the manual action"
# The manual check must pin the store: a bare `bd list` from another cwd reads a
# different DB and returns [] — which a human reads as "every marker is closed",
# the error-vs-empty collapse this bead exists to remove.
grep -qF 'bd -C city list --label source-bead:ga-g7x0si --all' "$COMMENT_F" \
  && ok "open-sibling comment's manual check pins the store (bd -C <city> list ...)" \
  || bad "open-sibling comment's manual check is a bare bd (wrong-store empty list reads as 'all closed')"
! grep -qE 'Re-checked every|closes automatically' "$COMMENT_F" "$LOG_F" && ok "no false 'checked every sweep' promise in the comment or log" || bad "false retry promise still emitted"
grep -q 'gate:reviewing' "$LABEL_F" && ok "gate:reviewing is cleared on hold (wa-qq33j)" || bad "gate:reviewing not cleared on hold"

run_block fail
eq "FAILED query → IS_SIBLING_HOLD=1 (safe direction: hold, never close on a false 'none')" "$IS_SIBLING_HOLD" "1"
grep -q 'COULD NOT RUN' "$COMMENT_F" && grep -q 'UNKNOWN' "$COMMENT_F" \
  && ok "comment says the check could not run and siblings are UNKNOWN" || bad "comment does not say the check failed: [$(cat "$COMMENT_F")]"
! grep -q 'is still open (not yet terminal)' "$COMMENT_F" \
  && ok "comment does NOT assert an open sibling when none was confirmed" \
  || bad "comment asserts 'a sibling is still open' on a FAILED query (failure presented as a positive)"
grep -q 'ACTION' "$COMMENT_F" && grep -qF 'bd -C city list --label source-bead:ga-g7x0si --all' "$COMMENT_F" \
  && ok "comment gives the manual check pinned to the store (bd -C <city> list --label source-bead:<id> --all)" \
  || bad "comment lacks the manual action, or it is a bare bd (wrong-store empty list reads as 'all closed')"
grep -q 'could NOT run' "$LOG_F" && ok "log line says the check could not run" || bad "log line does not flag the failed check: [$(cat "$LOG_F")]"
grep -q 'ALERT: gate_bead_sibling_status_lines query FAILED' "$ERR_F" \
  && ok "through the real block, the ALERT still reaches stderr" || bad "ALERT swallowed on the block path"

run_block none
eq "no sibling → IS_SIBLING_HOLD stays 0 (bead closes on the ordinary path)" "$IS_SIBLING_HOLD" "0"
[ ! -s "$COMMENT_F" ] && [ ! -s "$LABEL_F" ] \
  && ok "no comment / no label change when there is nothing to hold" || bad "block wrote to the bead although nothing is held"

rm -rf "$WORK_DIR"
trap - EXIT

# ── 7. syntax ────────────────────────────────────────────────────────────────
# /bin/bash (3.2), NOT the PATH bash: Homebrew bash 5.x accepts constructs the
# system 3.2 rejects, and the dispatcher is launched by 3.2 in production.
echo "── 7. syntax (/bin/bash -n) ──"
if /bin/bash -n "$DISPATCHER"; then ok "dispatcher passes /bin/bash -n"; else bad "dispatcher /bin/bash -n FAILED"; fi
if /bin/bash -n "${BASH_SOURCE[0]}"; then ok "this selftest passes /bin/bash -n"; else bad "selftest /bin/bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
