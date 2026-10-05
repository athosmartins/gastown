#!/usr/bin/env bash
# story-delivery-voicebot-vm-gate.test.sh — regression test for ga-2kaan2
# (replays the acceptance cases (a)-(f) of the bead against the REAL block of
# story-delivery.sh that runs between the prod test and `story:done`; the VM
# contract script is a stub, so no ssh, no VM and no network are touched).
#
# THE BUG (04/10, wa-kj0x2h, merge 95931501b): the delivery declared story:done
# on a merge that touched the voicebot while the dialer VM (jambonz-dialer) was
# still running OLD code — "7 daemons cosméticos e nenhum executor real" — and the
# Mayor deployed the VM by hand afterwards. scripts/voicebot_vm_sync.py (rig WA,
# wa-y0su67) now says, read-only, whether the VM provably matches main:
#   exit 0 = em dia (md5 lido NA VM)   exit 10 = pendente   exit 20 = falhou
#
# THE FIX under test: a merge whose own delta touches the voicebot (or a file in
# the closure of lib/ that scripts/voicebot_vm_lib_closure.py computes) asks that
# script before story:done. 0 -> proceed; 10 -> HOLD with delivery:pending-vm
# (never close — closing with a label is "done with the VM old"); 20 ->
# delivery:failed; anything else (timeout, unknown exit, illegible stdout) is
# "não sei" and holds like pending — an error must never read as "em dia".
#
# The block under test is everything from the Step 6 header up to (not
# including) Step 8, so the tests do not care WHERE inside it the gate sits —
# only whether a story still reaches Step 8 (REACHED=1) or was held (`continue`).
#
# Negative controls (c, c2, h2, g3: "must NOT consult the VM") pass on today's
# HEAD by construction — HEAD never consults. They exist to stop an over-eager
# implementation (always consult); they were proven against exactly such a mutant.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# has <haystack> <needle> — literal substring test with NO pipe.
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# count_of <haystack> <needle> — number of literal occurrences.
count_of() { printf '%s' "$1" | grep -o -F -- "$2" | wc -l | tr -d ' '; }

BLOCK="$(sed -n '/^# ── Step 6: Run prod test/,/^# ── Step 8: Mark story:done/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract the Step 6..Step 7 block"; exit 1; }

command -v timeout >/dev/null 2>&1 || { echo "FAIL: timeout(1) not on PATH — story-delivery.sh needs it too"; exit 1; }

# The block calls helpers defined above the lib-only guard (voicebot_vm_delta_touched,
# voicebot_vm_status, voicebot_vm_state_get): load the REAL ones — one source of truth,
# no copy-drift. The file sets -e on source; this test shell does not want it (the block
# itself still runs under `set -euo pipefail`, see run_block).
STORY_DELIVERY_LIB_ONLY=1 source "$DELIVERY" || { echo "FAIL: could not source story-delivery.sh in lib-only mode"; exit 1; }
set +e

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

VB="lib/predictive_dialer/voicebot"

# ── scenario inputs (globals, set by each test before run_block) ──────────────
reset_scenario() {
  SC_FILES="$VB/capture_policy.py"   # files the merge's own delta changes
  SC_MOVE=""                         # "<src> <dst>": a pure rename inside the delta
  SC_RM_PKG=0                        # the delta deletes the WHOLE voicebot package
  SC_STATUS_RC=0
  SC_STATUS_OUT="STATUS: em dia — md5 igual na VM"
  SC_STATUS_SLEEP=0
  SC_SCRIPT_PRESENT=1                # voicebot_vm_sync.py exists in the checkout
  SC_CLOSURE_OUT="pipedrive_field_ids"
  SC_CLOSURE_RC=0
  SC_CLOSURE_PRESENT=1               # scripts/voicebot_vm_lib_closure.py exists (the rig WA has it; other rigs never do)
  SC_PRE_MAIN_KNOWN=1                # the gate comment recorded MERGE_PRE_MAIN
  SC_HAS_VOICEBOT_DIR=1              # the rig carries the voicebot package at all
  SC_LABELS=""                       # extra STORY_LABELS entries (comma-joined)
  SC_STATE_DETAIL=""                 # `detail` inside voicebot_vm_sync_state.json
  SC_DRY_RUN=0
  SC_TIMEOUT_S=20
  SC_MAIL_AFTER_S=""                 # override of the 24h Mayor-mail threshold
}

# new_city — a fresh GC_CITY (holds the per-story hold state between cycles).
new_city() { CITY="$(mktemp -d "$ROOT/city.XXXXXX")"; mkdir -p "$CITY/.gc/runtime"; }

# run_block — one delivery cycle for story ga-test against a fresh runtime repo.
run_block() {
  local T; T="$(mktemp -d "$ROOT/run.XXXXXX")"
  GC_CITY="$CITY"
  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/$VB" "$REPO/lib" "$REPO/scripts" "$REPO/docs"
  echo "# voicebot" > "$REPO/$VB/README.md"
  echo "requests" > "$REPO/$VB/requirements.txt"
  echo "x = 0" > "$REPO/$VB/capture_policy.py"
  echo "x = 0" > "$REPO/lib/pipedrive_field_ids.py"
  echo "x = 0" > "$REPO/lib/unrelated.py"
  echo "x = 0" > "$REPO/scripts/other.py"
  echo "# doc" > "$REPO/docs/x.md"
  [ "$SC_HAS_VOICEBOT_DIR" = "1" ] || rm -rf "$REPO/lib/predictive_dialer"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  local f
  for f in $SC_FILES; do
    mkdir -p "$REPO/$(dirname "$f")"; echo "x = 1" >> "$REPO/$f"
  done
  if [ -n "$SC_MOVE" ]; then
    set -- $SC_MOVE
    mkdir -p "$REPO/$(dirname "$2")"; git -C "$REPO" mv "$1" "$2"
  fi
  [ "$SC_RM_PKG" = "1" ] && git -C "$REPO" rm -rq "$VB"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"

  # The VM contract stub + the closure stub live UNTRACKED in the checkout, so
  # they never show up in the merge's own delta.
  STUB_CALLS="$T/vm-calls.log"; : > "$STUB_CALLS"
  if [ "$SC_SCRIPT_PRESENT" = "1" ]; then
    cat > "$REPO/scripts/voicebot_vm_sync.py" <<'PYEOF'
import os, sys, time
open(os.environ["STUB_CALLS"], "a").write(" ".join(sys.argv[1:]) + "\n")
time.sleep(float(os.environ.get("STUB_SLEEP", "0")))
out = os.environ.get("STUB_OUT", "")
if out:
    print(out)
sys.exit(int(os.environ.get("STUB_RC", "0")))
PYEOF
  fi
  if [ "$SC_CLOSURE_PRESENT" = "1" ]; then
    cat > "$REPO/scripts/voicebot_vm_lib_closure.py" <<'PYEOF'
import os, sys
out = os.environ.get("STUB_CLOSURE_OUT", "")
if out:
    print(out.replace(" ", "\n"))
sys.exit(int(os.environ.get("STUB_CLOSURE_RC", "0")))
PYEOF
  fi
  if [ -n "$SC_STATE_DETAIL" ]; then
    mkdir -p "$REPO/shared/data"
    jq -n --arg d "$SC_STATE_DETAIL" '{status:"falhou", detail:$d}' > "$REPO/shared/data/voicebot_vm_sync_state.json"
  fi
  export STUB_CALLS STUB_RC="$SC_STATUS_RC" STUB_OUT="$SC_STATUS_OUT" STUB_SLEEP="$SC_STATUS_SLEEP"
  export STUB_CLOSURE_OUT="$SC_CLOSURE_OUT" STUB_CLOSURE_RC="$SC_CLOSURE_RC"
  export VOICEBOT_VM_STATUS_TIMEOUT_S="$SC_TIMEOUT_S"
  if [ -n "$SC_MAIL_AFTER_S" ]; then export VOICEBOT_VM_PENDING_MAIL_AFTER_S="$SC_MAIL_AFTER_S"
  else unset VOICEBOT_VM_PENDING_MAIL_AFTER_S; fi

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"; VARS_FILE="$T/vars.out"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local DRY_RUN="$SC_DRY_RUN"
  local NO_HARNESS=1 STORY_TEST_MISSING=0 PROD_TEST_SCRIPT=""
  local STORY_ID="ga-test" STORY_TITLE="voicebot story"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  local STORY_LABELS="ctx:ready,story:approved,gate:passed"
  [ -n "$SC_LABELS" ] && STORY_LABELS="$STORY_LABELS,$SC_LABELS"
  local MERGE_SHA="$SHA_C1" MERGE_REF="origin/main" MERGE_PRE_MAIN="$SHA_C0"
  [ "$SC_PRE_MAIN_KNOWN" = "1" ] || MERGE_PRE_MAIN=""
  local DEPLOY_CMD="true" REFRESH_PROOF="verified"

  # Same strictness as production (`set -euo pipefail`); `continue` inside the
  # block leaves the one-pass loop, so REACHED stays 0 for a held story.
  ( set -euo pipefail
    REACHED=0
    for _t in _once; do eval "$BLOCK"; REACHED=1; done
    echo "REACHED=$REACHED" > "$VARS_FILE" ) >"$T/block.out" 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  BD_CALLS="$(cat "$BD_LOG" 2>/dev/null || true)"
  GC_CALLS="$(cat "$GC_LOG" 2>/dev/null || true)"
  VARS_OUT="$(cat "$VARS_FILE" 2>/dev/null || echo 'REACHED=<block aborted>')"
  BLOCK_OUT="$(cat "$T/block.out" 2>/dev/null || true)"
  VM_CALLS="$(grep -c -- '--status' "$STUB_CALLS" 2>/dev/null || true)"
  VM_CALLS="${VM_CALLS:-0}"
  STATE_FILE_ABS="$CITY/.gc/runtime/voicebot-vm-hold/$STORY_ID.state"
  STATE_AFTER="$(cat "$STATE_FILE_ABS" 2>/dev/null || echo '<none>')"
  rm -rf "$T"
}

reached()       { [ "$VARS_OUT" = "REACHED=1" ]; }
held()          { [ "$VARS_OUT" = "REACHED=0" ]; }
pending_label() { has "$BD_CALLS" "label add ga-test delivery:pending-vm"; }
failed_label()  { has "$BD_CALLS" "label add ga-test delivery:failed"; }
# The REAL writes only — Step 6's NO_HARNESS comment merely MENTIONS "story:done".
done_written()  { has "$BD_CALLS" "label add ga-test story:done" || has "$BD_CALLS" " close ga-test"; }
# A held story must not run the prod test (it would re-run every cycle for nothing)
# — with NO_HARNESS=1 that step writes delivery:untested, so its absence proves it.
prod_test_ran() { has "$BD_CALLS" "delivery:untested"; }
unreadable_msg="não consegui ler o status da VM"

# ── (a) merge touching the voicebot, --status=10 -> held with delivery:pending-vm ──
echo "(a) pending VM holds the delivery; the next cycle with exit 0 releases it"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso na VM"
run_block
[ "$RUN_RC" -eq 0 ] && ok "a1 block runs clean under set -euo pipefail" || nok "a1 rc" "rc=$RUN_RC out=[$BLOCK_OUT]"
held && ok "a1 the story is HELD (does not reach Step 8)" || nok "a1 story reached Step 8 with the VM pending — the bug" "$VARS_OUT"
pending_label && ok "a1 label delivery:pending-vm added" || nok "a1 no delivery:pending-vm label" "$BD_CALLS"
has "$BD_CALLS" "label remove ga-test delivery:running" && ok "a1 delivery:running released while held" || nok "a1 delivery:running not removed" "$BD_CALLS"
has "$BD_CALLS" "ligação em curso na VM" && ok "a1 the comment carries the script's own reason" || nok "a1 reason missing from the comment" "$BD_CALLS"
failed_label && nok "a1 pending was recorded as delivery:failed (that is exit 20's label)" "$BD_CALLS" || ok "a1 not delivery:failed"
done_written && nok "a1 story:done / close written while the VM is pending" "$BD_CALLS" || ok "a1 no story:done and no close"
prod_test_ran && nok "a1 the prod test still ran for a story held on the VM" "$BD_CALLS" || ok "a1 held BEFORE the prod test (no wasted re-run every cycle)"
[ "$VM_CALLS" = "1" ] && ok "a1 the contract script was asked exactly once, with --status" || nok "a1 VM calls=$VM_CALLS" ""

SC_LABELS="delivery:pending-vm"; SC_STATUS_RC=0; SC_STATUS_OUT="STATUS: em dia — md5 igual na VM"
run_block
reached && ok "a2 next cycle with exit 0: the story proceeds to Step 8" || nok "a2 still held after the VM turned em dia" "$VARS_OUT"
has "$BD_CALLS" "label remove ga-test delivery:pending-vm" && ok "a2 delivery:pending-vm removed" || nok "a2 label not removed" "$BD_CALLS"
pending_label && nok "a2 pending-vm re-added on an em dia VM" "$BD_CALLS" || ok "a2 no pending-vm re-add"
[ "$STATE_AFTER" = "<none>" ] && ok "a2 the hold state is cleared" || nok "a2 hold state left behind" "$STATE_AFTER"

# ── (b) voicebot merge with --status=0 -> proceeds ──
echo "(b) VM proven equal to main -> proceeds"
reset_scenario; new_city
run_block
reached && ok "b the story proceeds" || nok "b held although the VM is em dia" "$VARS_OUT"
[ "$VM_CALLS" = "1" ] && ok "b the VM was consulted once (a voicebot file changed)" || nok "b VM calls=$VM_CALLS (HEAD never consults)" ""
pending_label || failed_label && nok "b a hold label was written" "$BD_CALLS" || ok "b no hold label"

# ── (c) merge with no voicebot file -> the script is not called ──
echo "(c) no voicebot file in the delta -> never consults, never touches the VM"
reset_scenario; new_city
SC_FILES="docs/x.md scripts/other.py lib/unrelated.py"; SC_STATUS_RC=10
run_block
reached && ok "c the story proceeds" || nok "c held for a merge that does not touch the voicebot" "$VARS_OUT"
[ "$VM_CALLS" = "0" ] && ok "c 0 calls to the contract script" || nok "c VM calls=$VM_CALLS" ""
reset_scenario; new_city
SC_FILES="$VB/README.md $VB/requirements.txt"; SC_STATUS_RC=10
run_block
reached && [ "$VM_CALLS" = "0" ] && ok "c2 voicebot *.md and requirements.txt do not count (0 calls, proceeds)" || nok "c2 consulted for a doc/requirements-only change" "calls=$VM_CALLS $VARS_OUT"

# ── (d) --status=20 -> delivery:failed with stdout AND the state's detail ──
echo "(d) exit 20 -> delivery:failed with the reason"
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate em lib/x.py"; SC_STATE_DETAIL="scp recusado: disco cheio na VM"
run_block
held && ok "d held" || nok "d reached Step 8 with a FAILED VM sync" "$VARS_OUT"
failed_label && ok "d delivery:failed added" || nok "d no delivery:failed" "$BD_CALLS"
prod_test_ran && nok "d the prod test still ran for a story whose VM sync FAILED" "$BD_CALLS" || ok "d held before the prod test"
has "$BD_CALLS" "md5 não bate em lib/x.py" && ok "d comment has the script's stdout" || nok "d stdout missing" "$BD_CALLS"
has "$BD_CALLS" "scp recusado: disco cheio na VM" && ok "d comment has the state's detail" || nok "d state detail missing" "$BD_CALLS"
pending_label && nok "d a failed sync was labelled pending-vm" "$BD_CALLS" || ok "d not pending-vm"
done_written && nok "d story:done/close written" "$BD_CALLS" || ok "d no story:done and no close"
has "$GC_CALLS" "session nudge" && ok "d the author/Mayor is nudged" || nok "d nobody was nudged" "$GC_CALLS"

# ── (e) "não sei": timeout / unknown exit / python crash / illegible stdout ──
echo "(e) an unreadable status is NOT em dia"
for case_ in "timeout|0|slow|5" "exit3|3||0" "crash|1||0" "illegible0|0||0"; do
  IFS='|' read -r name rc out sl <<< "$case_"
  reset_scenario; new_city
  SC_STATUS_RC="$rc"; SC_STATUS_OUT="$out"; SC_STATUS_SLEEP="$sl"
  [ "$name" = "timeout" ] && { SC_TIMEOUT_S=1; SC_STATUS_OUT="STATUS: em dia"; SC_STATUS_RC=0; }
  run_block
  held && ok "e/$name held (never treated as em dia)" || nok "e/$name proceeded on an unreadable status" "$VARS_OUT"
  pending_label && ok "e/$name labelled delivery:pending-vm" || nok "e/$name no pending-vm label" "$BD_CALLS"
  has "$BD_CALLS" "$unreadable_msg" && ok "e/$name comment says: $unreadable_msg" || nok "e/$name comment lacks the reason" "$BD_CALLS"
  failed_label && nok "e/$name wrongly delivery:failed" "$BD_CALLS" || ok "e/$name not delivery:failed"
done
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT=""
run_block
held && pending_label && ok "e2 exit 10 with no stdout is still pending (the exit code speaks)" || nok "e2 exit 10 + empty stdout" "$VARS_OUT / $BD_CALLS"

# ── (f) contract script absent -> proceeds as today + visible comment ──
echo "(f) contract absent (wa-y0su67 not in main yet) -> as today, with a comment"
reset_scenario; new_city
SC_SCRIPT_PRESENT=0
run_block
reached && ok "f the story proceeds (no dependency on merge order with wa-y0su67)" || nok "f held although the contract does not exist" "$VARS_OUT"
has "$BD_CALLS" "VM do voicebot não verificada: contrato ausente" && ok "f comment: VM do voicebot não verificada: contrato ausente" || nok "f no 'contrato ausente' comment" "$BD_CALLS"
pending_label && nok "f labelled pending-vm with no contract" "$BD_CALLS" || ok "f no hold label"

# ── (g) unknown delta (MERGE_PRE_MAIN not recorded): error != empty ──
echo "(g) the merge's own delta cannot be read -> ask the VM anyway (never guess 'no voicebot')"
reset_scenario; new_city
SC_PRE_MAIN_KNOWN=0; SC_FILES="docs/x.md"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — VM sem resposta"
run_block
[ "$VM_CALLS" = "1" ] && held && pending_label && ok "g1 unknown delta + VM pending -> consulted and held" || nok "g1 unknown delta" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_PRE_MAIN_KNOWN=0; SC_FILES="docs/x.md"
run_block
[ "$VM_CALLS" = "1" ] && reached && ok "g2 unknown delta + VM em dia -> proceeds" || nok "g2 unknown delta + em dia" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_PRE_MAIN_KNOWN=0; SC_HAS_VOICEBOT_DIR=0; SC_FILES="docs/x.md"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "0" ] && reached && ok "g3 unknown delta in a rig with no voicebot package -> not consulted" || nok "g3 consulted for a rig without a voicebot" "calls=$VM_CALLS $VARS_OUT"

# ── (h) closure of lib/ ──
echo "(h) a changed lib/ file counts only when it is in the voicebot's closure"
reset_scenario; new_city
SC_FILES="lib/pipedrive_field_ids.py"; SC_CLOSURE_OUT="pipedrive_field_ids human_name_guard"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "h1 lib file in the closure -> consulted, held" || nok "h1 closure member ignored" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_OUT="pipedrive_field_ids"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "0" ] && reached && ok "h2 lib file outside the closure -> not consulted" || nok "h2 consulted for a non-closure lib file" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_RC=2; SC_CLOSURE_OUT=""; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "h3 closure refuses (exit 2) -> cannot rule the file out -> consulted" || nok "h3 closure failure read as 'not in closure'" "calls=$VM_CALLS $VARS_OUT"

# ── (i) the hold is quiet: one comment per change of state, one mail after 24h ──
echo "(i) no comment spam while pending; one Mayor mail once pending > 24h"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
c1="$(count_of "$BD_CALLS" "Delivery HELD")"
SC_LABELS="delivery:pending-vm"
run_block
c2="$(count_of "$BD_CALLS" "Delivery HELD")"
[ "$c1" = "1" ] && [ "$c2" = "0" ] && ok "i1 same reason next cycle: no second comment (1 then 0)" || nok "i1 comment counts $c1 then $c2" ""
pending_label && nok "i1 pending-vm re-added while already on the bead" "$BD_CALLS" || ok "i1 label not re-written"
held && ok "i1 still held" || nok "i1 not held" "$VARS_OUT"
SC_STATUS_OUT="STATUS: pendente — VM sem resposta"
run_block
c3="$(count_of "$BD_CALLS" "Delivery HELD")"
[ "$c3" = "1" ] && ok "i2 the reason changed: a new comment" || nok "i2 comment count=$c3" "$BD_CALLS"

reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
has "$GC_CALLS" "mail send" && nok "i3 mailed the Mayor on the FIRST pending cycle" "$GC_CALLS" || ok "i3 no mail while pending is young"
mkdir -p "$CITY/.gc/runtime/voicebot-vm-hold"
SINCE=$(( $(date +%s) - 90000 ))
fp="$(grep '^fp=' "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state" 2>/dev/null | head -1)"
printf '%s\nsince=%s\nmailed=0\n' "$fp" "$SINCE" > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"
SC_LABELS="delivery:pending-vm"
run_block
[ "$(count_of "$GC_CALLS" "mail send mayor")" = "1" ] && ok "i4 pending > 24h: exactly one mail to the Mayor" || nok "i4 mail count" "$GC_CALLS"
# The reader is the Mayor deciding what to do: a date he can read, not a bare epoch number.
has "$GC_CALLS" "desde $(date -u -r "$SINCE" '+%Y-%m-%d')" && ! has "$GC_CALLS" "epoch" \
  && ok "i4b the mail says WHEN it started holding as a calendar date, not an epoch" \
  || nok "i4b the mail gives an unreadable 'since' (expected 'desde $(date -u -r "$SINCE" '+%Y-%m-%d')')" "$GC_CALLS"
run_block
[ "$(count_of "$GC_CALLS" "mail send mayor")" = "0" ] && ok "i5 the next cycle does not mail again" || nok "i5 mailed twice" "$GC_CALLS"
SC_STATUS_RC=0; SC_STATUS_OUT="STATUS: em dia — ok"
run_block
[ "$STATE_AFTER" = "<none>" ] && ok "i6 em dia clears the hold state (a later, unrelated hold starts a fresh 24h clock)" || nok "i6 state kept" "$STATE_AFTER"

reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5"
run_block
f1="$(count_of "$BD_CALLS" "Delivery FAILED")"; n1="$(count_of "$GC_CALLS" "session nudge")"
SC_LABELS="delivery:failed"
run_block
f2="$(count_of "$BD_CALLS" "Delivery FAILED")"; n2="$(count_of "$GC_CALLS" "session nudge")"
[ "$f1" = "1" ] && [ "$n1" -ge 1 ] && [ "$f2" = "0" ] && [ "$n2" = "0" ] \
  && ok "i7 failed twice with the same reason: one comment + nudge, then silence" \
  || nok "i7 failed comment/nudge counts: comment $f1 then $f2, nudge $n1 then $n2" "$BD_CALLS / $GC_CALLS"

# ── (k) the labels follow the state: failed <-> pending never leave the wrong one behind ──
echo "(k) failed -> pending drops the stale delivery:failed; pending -> failed drops pending-vm"
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
SC_LABELS="delivery:failed"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
has "$BD_CALLS" "label remove ga-test delivery:failed" && pending_label \
  && ok "k1 the VM went failed -> pending: delivery:failed removed, delivery:pending-vm added" \
  || nok "k1 stale delivery:failed left on a merely-pending story" "$BD_CALLS"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
SC_LABELS="delivery:pending-vm"; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
has "$BD_CALLS" "label remove ga-test delivery:pending-vm" && failed_label \
  && ok "k2 the VM went pending -> failed: delivery:pending-vm removed, delivery:failed added" \
  || nok "k2 stale delivery:pending-vm left on a failed story" "$BD_CALLS"

# ── (l) a reason that only changes in its numbers is not a new state ──
echo "(l) 'há 3 min' -> 'há 4 min' is the same hold, not a new comment every cycle"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso há 3 min (2 chamadas)"
run_block
SC_LABELS="delivery:pending-vm"; SC_STATUS_OUT="STATUS: pendente — ligação em curso há 4 min (3 chamadas)"
run_block
[ "$(count_of "$BD_CALLS" "Delivery HELD")" = "0" ] && ok "l1 only the numbers moved: no new comment" || nok "l1 re-commented on a numeric change" "$BD_CALLS"
SC_STATUS_OUT="STATUS: pendente — VM sem resposta"
run_block
[ "$(count_of "$BD_CALLS" "Delivery HELD")" = "1" ] && ok "l2 a different reason is still a new comment" || nok "l2 a real change went unreported" "$BD_CALLS"

# ── (m) hostile / oversized input must not abort the whole sweep or flood the bead ──
echo "(m) a runaway stdout or state detail neither aborts the sweep nor floods the comment"
BIG="$(head -c 120000 /dev/zero | tr '\0' 'x')"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — grande"$'\n'"$BIG"
run_block
[ "$RUN_RC" -eq 0 ] && held && pending_label \
  && ok "m1 120KB of stdout: the block survives (set -e + pipefail) and still holds" \
  || nok "m1 oversized stdout aborted/misclassified the block" "rc=$RUN_RC $VARS_OUT out=[${BLOCK_OUT:0:200}]"
[ "${#BD_CALLS}" -lt 8000 ] && ok "m2 the comment stays bounded (${#BD_CALLS} bytes of bd calls)" || nok "m2 the comment is unbounded (${#BD_CALLS} bytes)" ""
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5"; SC_STATE_DETAIL="$BIG"
run_block
[ "$RUN_RC" -eq 0 ] && held && failed_label && [ "${#BD_CALLS}" -lt 8000 ] \
  && ok "m3 a 120KB state detail is capped in the failed comment" \
  || nok "m3 oversized detail" "rc=$RUN_RC held=$VARS_OUT bytes=${#BD_CALLS}"

# ── (n) a rename OUT of the voicebot package is a voicebot change ──
echo "(n) git lists only the NEW path of a rename — the old one (the VM's copy) must still count"
reset_scenario; new_city
SC_FILES=""; SC_MOVE="$VB/capture_policy.py docs/capture_policy_moved.py"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "n1 moving a file out of the voicebot package -> consulted, held" || nok "n1 rename out of the package was invisible" "calls=$VM_CALLS $VARS_OUT"

# ── (o) the helper itself: no runtime dir is 'unknown', not 'no' ──
echo "(o) voicebot_vm_delta_touched with no runtime_dir cannot claim 'nothing to verify'"
voicebot_vm_delta_touched "" "abc" "def"
[ "$VM_DELTA_VERDICT" = "unknown" ] && ok "o1 no runtime_dir -> unknown" || nok "o1 no runtime_dir read as '$VM_DELTA_VERDICT'" "$VM_DELTA_WHY"

# ── (p) a rig WITHOUT the voicebot package has nothing to carry — however the delta reads ──
# Gate fix-attempt 1 (ga-t3thji). The "rig sem o pacote => no" rule used to guard only the
# UNREADABLE-delta branch. A READABLE delta that changes a top-level lib/*.py looked for a
# closure script that can never exist in such a rig and answered "unknown" — so every
# property_scrapers story touching lib/*.py got a false "VM do voicebot não verificada:
# contrato ausente ... mexe no que roda na VM" comment, forever (wa-y0su67 merging never
# puts the script in that checkout). run_block always wrote the closure stub, which is why
# g3/h2/h3 never reached it: SC_CLOSURE_PRESENT=0 is the rig as it really is.
echo "(p) rig without the voicebot package: readable delta + lib/ change + no closure script -> nothing to verify"
reset_scenario; new_city
SC_HAS_VOICEBOT_DIR=0; SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_SCRIPT_PRESENT=0
run_block
[ "$RUN_RC" -eq 0 ] && reached && ok "p1 the story proceeds" || nok "p1 rc/reached" "rc=$RUN_RC $VARS_OUT out=[$BLOCK_OUT]"
[ "$VM_CALLS" = "0" ] && ok "p1 0 calls to the contract script" || nok "p1 VM calls=$VM_CALLS" ""
has "$BD_CALLS" "contrato ausente" && nok "p1 a rig with no voicebot got the false 'contrato ausente' comment on its story" "$BD_CALLS" || ok "p1 no 'contrato ausente' comment"
has "$BD_CALLS" "VM do voicebot" && nok "p1 some VM comment was written on a story that cannot touch the VM" "$BD_CALLS" || ok "p1 nothing about the VM written on the bead"
has "$LOG_OUT" "rig sem o pacote" && ok "p1 logged: rig sem o pacote" || nok "p1 the reason is not the rig-has-no-package one" "$LOG_OUT"
[ "$STATE_AFTER" = "<none>" ] && ok "p1 no hold/absent state file written" || nok "p1 state file written for a story that is not about the VM" "$STATE_AFTER"
reset_scenario; new_city
SC_HAS_VOICEBOT_DIR=0; SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "0" ] && reached && ok "p2 even with the contract script present: not consulted, proceeds" || nok "p2 consulted for a rig without a voicebot (closure absent read as 'unknown')" "calls=$VM_CALLS $VARS_OUT"
# Control (passes on HEAD too): a merge that ADDS the package must still ask. Step 4 has
# already pulled the tree, so the directory exists when the check runs.
reset_scenario; new_city
SC_HAS_VOICEBOT_DIR=0; SC_FILES="$VB/capture_policy.py"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "p3 a merge that introduces the voicebot package is consulted and held" || nok "p3 the package-absent check hid a merge that ADDS the package" "calls=$VM_CALLS $VARS_OUT"

# Control (passes on HEAD too): a merge that DELETES the whole package leaves a post-pull
# tree with no package directory, yet the VM still holds the old copy — that delta is
# "yes", so the package-absent rule must never run ahead of the package-file match.
reset_scenario; new_city
SC_RM_PKG=1; SC_FILES=""; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "p4 a merge that deletes the whole voicebot package is consulted and held (the VM still has it)" || nok "p4 deleting the package was read as 'rig sem o pacote'" "calls=$VM_CALLS $VARS_OUT"

# ── (q) 'could not tell' is never worded as 'it touches the VM' ──
# Same class as (p): the comments said "este merge mexe no que roda na VM" while the
# parenthesised reason said the delta could not be read / the closure could not be
# computed. Known (yes) keeps the assertive wording; unknown says "pode mexer".
echo "(q) the wording follows the verdict: 'mexe' only when the delta was PROVEN to touch the VM"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_SCRIPT_PRESENT=0
run_block
has "$BD_CALLS" "contrato ausente" && ok "q1 (control) the contract-absent comment is still posted when the delta is unknown" || nok "q1 no contract-absent comment" "$BD_CALLS"
has "$BD_CALLS" "pode mexer" && ok "q1 contract-absent + unknown delta says 'pode mexer'" || nok "q1 unknown delta not hedged in the contract-absent comment" "$BD_CALLS"
has "$BD_CALLS" "Este merge mexe no que roda" && nok "q1 unknown delta stated as fact: 'Este merge mexe no que roda na VM'" "$BD_CALLS" || ok "q1 no flat 'mexe no que roda' for an unknown delta"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — VM sem resposta"
run_block
has "$BD_CALLS" "Delivery HELD" && has "$BD_CALLS" "pode mexer" && ok "q2 HELD comment on an unknown delta says 'pode mexer'" || nok "q2 HELD comment not hedged" "$BD_CALLS"
has "$BD_CALLS" "este merge mexe no que roda" && nok "q2 HELD comment states an unknown delta as fact" "$BD_CALLS" || ok "q2 HELD comment has no flat 'mexe no que roda'"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5"
run_block
has "$BD_CALLS" "Delivery FAILED" && has "$BD_CALLS" "pode mexer" && ok "q3 FAILED comment on an unknown delta says 'pode mexer'" || nok "q3 FAILED comment not hedged" "$BD_CALLS"
has "$BD_CALLS" "este merge mexe no que roda" && nok "q3 FAILED comment states an unknown delta as fact" "$BD_CALLS" || ok "q3 FAILED comment has no flat 'mexe no que roda'"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
has "$BD_CALLS" "este merge mexe no que roda" && ok "q4 a PROVEN voicebot delta keeps the assertive 'mexe no que roda'" || nok "q4 proven delta lost its assertive wording" "$BD_CALLS"
has "$BD_CALLS" "pode mexer" && nok "q4 a proven delta was hedged as 'pode mexer'" "$BD_CALLS" || ok "q4 proven delta is not hedged"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — VM sem resposta"
run_block
SINCE=$(( $(date +%s) - 90000 ))
fp="$(grep '^fp=' "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state" 2>/dev/null | head -1)"
printf '%s\nsince=%s\nmailed=0\n' "$fp" "$SINCE" > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"
SC_LABELS="delivery:pending-vm"
run_block
has "$GC_CALLS" "mail send mayor" && ok "q5 (control) pending > 24h on an unknown delta still mails the Mayor" || nok "q5 no mail" "$GC_CALLS"
has "$GC_CALLS" "o merge mexe no voicebot" && nok "q5 the Mayor mail states an unknown delta as fact: 'o merge mexe no voicebot'" "$GC_CALLS" || ok "q5 the Mayor mail does not state an unknown delta as fact"

# ── (r) Step 8 sweeps every delivery label this gate can leave behind ──
# Step 6a removes delivery:pending-vm itself, but with `-q 2>/dev/null || true`; a failed
# removal would leave a stale hold label on a story that is already story:done. Step 8
# is the backstop that already clears delivery:failed / delivery:deploy-pending.
# (A text-level guard: Step 8 itself is not run by this harness.)
echo "(r) the Step 8 terminal cleanup also drops delivery:pending-vm"
STEP8="$(sed -n '/^# ── Step 8: Mark story:done/,$p' "$DELIVERY")"
has "$STEP8" '"delivery:pending-vm"' && ok "r1 Step 8 removes delivery:pending-vm with the other delivery labels" || nok "r1 Step 8 leaves a stale delivery:pending-vm on a delivered story" ""

# ── (s) add the hold label BEFORE releasing delivery:running ──
# remove-then-add leaves a window in which a janitor sweep sees neither label on the story
# (nothing says "a delivery owns this"). add-then-remove keeps one of them at every instant.
echo "(s) the hold label lands before delivery:running is released"
line_of() { printf '%s\n' "$1" | grep -n -F -- "$2" | head -1 | cut -d: -f1; }
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
add_ln="$(line_of "$BD_CALLS" "label add ga-test delivery:pending-vm")"; rm_ln="$(line_of "$BD_CALLS" "label remove ga-test delivery:running")"
[ -n "$add_ln" ] && [ -n "$rm_ln" ] && [ "$add_ln" -lt "$rm_ln" ] \
  && ok "s1 pending: delivery:pending-vm added (call $add_ln) before delivery:running removed (call $rm_ln)" \
  || nok "s1 pending: running released before the hold label exists (add@${add_ln:-none} remove@${rm_ln:-none})" "$BD_CALLS"
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5"
run_block
add_ln="$(line_of "$BD_CALLS" "label add ga-test delivery:failed")"; rm_ln="$(line_of "$BD_CALLS" "label remove ga-test delivery:running")"
[ -n "$add_ln" ] && [ -n "$rm_ln" ] && [ "$add_ln" -lt "$rm_ln" ] \
  && ok "s2 failed: delivery:failed added (call $add_ln) before delivery:running removed (call $rm_ln)" \
  || nok "s2 failed: running released before delivery:failed exists (add@${add_ln:-none} remove@${rm_ln:-none})" "$BD_CALLS"

# ── (j) dry-run writes nothing ──
echo "(j) DRY_RUN=1: reads the status, writes nothing"
reset_scenario; new_city
SC_DRY_RUN=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — x"
run_block
pending_label && nok "j wrote a label in dry-run" "$BD_CALLS" || ok "j no label written"
has "$BD_CALLS" "Delivery HELD" && nok "j wrote a comment in dry-run" "$BD_CALLS" || ok "j no comment written"
has "$LOG_OUT" "WOULD" && has "$LOG_OUT" "pending-vm" && ok "j logs what it WOULD do (the pending-vm hold)" || nok "j the dry-run does not say it would hold" "$LOG_OUT"
held && ok "j the decision is still a hold (no Step 8 in dry-run either)" || nok "j dry-run reached Step 8 with the VM pending" "$VARS_OUT"
[ -d "$CITY/.gc/runtime/voicebot-vm-hold" ] && nok "j hold state written in dry-run" "" || ok "j no hold state written"

echo
echo "story-delivery-voicebot-vm-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
