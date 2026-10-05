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
#
# Sections (p)-(s) came from gate fix-attempt 1 (ga-t3thji); (t)-(z) and o2 from fix-attempt 2
# (ga-8xbsjh). Both rounds are the SAME class (root-class:error-vs-empty): every "could not
# know" in the block — a rig whose tree cannot be read, a path git quoted, an empty or garbled
# closure, an unreadable status, a failed state write, a contract script that vanished under a
# standing hold — has to come out as the INERT answer (consult / hold / warn), never as the
# harmless one ("no", "em dia", silence). Cases that pass on the previous HEAD by design are
# controls or guards for the restructure: t4, t5b, t6, t6b, u2, w3, y3-y5, z3.
#
# Sections (aa)-(ab) came from gate fix-attempt 3 (ga-onxu8f), the same class once more, now at
# the hold-label WRITE: a `label add` that fails must not let delivery:running be released, the
# opposite hold be dropped, or a comment / nudge / state fingerprint claim a hold the bead does
# not carry; a `label remove` that fails is a WARN, not a "removido". Controls that pass on the
# previous HEAD by design: aa2b, aa5, aa5b, aa7, ab1b.

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
  SC_STATUS_ERR=""                   # what the contract script writes to STDERR
  SC_CLOSED_NOW=0                    # `bd show` reports the story closed (someone closed it mid-sweep)
  SC_BD_FAIL_COMMENT=0               # `bd comment` fails (rc 1)
  SC_BD_FAIL_LABEL_ADD=0             # `bd label add` fails (rc 1) — the hold label itself cannot be written
  SC_BD_FAIL_LABEL_REMOVE=0          # `bd label remove` fails (rc 1)
  SC_GC_FAIL_MAIL=0                  # `gc mail send` fails (rc 1)
  SC_BREAK_STATE_DIR=0               # the hold-state directory cannot be created
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
err = os.environ.get("STUB_ERR", "")
if err:
    sys.stderr.write(err + "\n")
sys.exit(int(os.environ.get("STUB_RC", "0")))
PYEOF
  fi
  if [ "$SC_CLOSURE_PRESENT" = "1" ]; then
    cat > "$REPO/scripts/voicebot_vm_lib_closure.py" <<'PYEOF'
import os, sys
out = os.environ.get("STUB_CLOSURE_OUT", "")
if out:
    sys.stdout.buffer.write(os.fsencode(out.replace(" ", "\n")) + b"\n")
sys.exit(int(os.environ.get("STUB_CLOSURE_RC", "0")))
PYEOF
  fi
  if [ -n "$SC_STATE_DETAIL" ]; then
    mkdir -p "$REPO/shared/data"
    jq -n --arg d "$SC_STATE_DETAIL" '{status:"falhou", detail:$d}' > "$REPO/shared/data/voicebot_vm_sync_state.json"
  fi
  export STUB_CALLS STUB_RC="$SC_STATUS_RC" STUB_OUT="$SC_STATUS_OUT" STUB_SLEEP="$SC_STATUS_SLEEP"
  export STUB_CLOSURE_OUT="$SC_CLOSURE_OUT" STUB_CLOSURE_RC="$SC_CLOSURE_RC" STUB_ERR="$SC_STATUS_ERR"
  # A regular file where the hold-state DIRECTORY should go: mkdir -p fails, writes fail.
  if [ "$SC_BREAK_STATE_DIR" = "1" ]; then : > "$CITY/.gc/runtime/voicebot-vm-hold"; fi
  export VOICEBOT_VM_STATUS_TIMEOUT_S="$SC_TIMEOUT_S"
  if [ -n "$SC_MAIL_AFTER_S" ]; then export VOICEBOT_VM_PENDING_MAIL_AFTER_S="$SC_MAIL_AFTER_S"
  else unset VOICEBOT_VM_PENDING_MAIL_AFTER_S; fi

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"; VARS_FILE="$T/vars.out"
  # `bd -C <store> <verb> ...`: $3 is the verb. `show` answers the closed-now re-check.
  bd()   {
    echo "bd $*" >> "$BD_LOG"
    if [ "${3:-}" = "show" ]; then
      if [ "$SC_CLOSED_NOW" = "1" ]; then echo '[{"status":"closed"}]'; else echo '[{"status":"open"}]'; fi
      return 0
    fi
    if [ "$SC_BD_FAIL_COMMENT" = "1" ] && [ "${3:-}" = "comment" ]; then return 1; fi
    if [ "$SC_BD_FAIL_LABEL_ADD" = "1" ] && [ "${3:-}" = "label" ] && [ "${4:-}" = "add" ]; then return 1; fi
    if [ "$SC_BD_FAIL_LABEL_REMOVE" = "1" ] && [ "${3:-}" = "label" ] && [ "${4:-}" = "remove" ]; then return 1; fi
    return 0
  }
  gc()   {
    echo "gc $*" >> "$GC_LOG"
    case "$*" in *"mail send"*) [ "$SC_GC_FAIL_MAIL" = "1" ] && return 1 ;; esac
    return 0
  }
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
# A runtime dir that does not exist is "could not look", not "the rig has no voicebot package":
# the package-absent rule only holds when there IS a tree to look at (gate fix-attempt 2 sweep).
voicebot_vm_delta_touched "$ROOT/no-such-runtime-dir" "abc" "def"
[ "$VM_DELTA_VERDICT" = "unknown" ] && ok "o2 a runtime_dir that does not exist -> unknown, not 'rig sem o pacote'" || nok "o2 missing runtime_dir read as '$VM_DELTA_VERDICT'" "$VM_DELTA_WHY"

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

# ── (t) a path git would C-quote is still a path ──
# Gate fix-attempt 2 (ga-8xbsjh), blocking 1 (root-class:error-vs-empty). The delta was read
# with plain `git diff --name-only`, which prints any path with a non-ASCII byte as a C-quoted
# string ("lib/.../liga\303\247\303\243o.py", leading double quote). No `case` arm matches
# that, so an accented voicebot file was classified "no": the VM was never asked and the log
# said the delta "does not touch the voicebot". The WA repo already tracks accented paths.
# `-z` returns every path verbatim.
echo "(t) a voicebot/lib file whose NAME git would quote is still seen"
reset_scenario; new_city
SC_FILES="$VB/ligação.py"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && pending_label && ok "t1 accented file inside the voicebot package -> consulted, held" || nok "t1 an accented package file was invisible (read as 'no')" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_FILES="$VB/a\"b.py"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "t2 a double quote in the name (git quotes it even with quotePath=false) -> consulted, held" || nok "t2 a name with a double quote was invisible" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_FILES="lib/açúcar.py"; SC_CLOSURE_OUT="açúcar"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "t3 accented lib/*.py that IS in the closure -> consulted, held" || nok "t3 an accented lib file was invisible" "calls=$VM_CALLS $VARS_OUT"
# Control (passes on HEAD too): a quoted name that reaches nothing must not become a hold.
reset_scenario; new_city
SC_FILES="docs/ação.md"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "0" ] && reached && ok "t4 (control) an accented doc outside the package and lib/ is not consulted" || nok "t4 over-held an accented doc" "calls=$VM_CALLS $VARS_OUT"

# Belt and braces: if some git still hands back a C-quoted path, "could not parse" is not "no".
echo "(t5) a path that still arrives C-quoted cannot be matched -> unknown, never 'no'"
SH="$(mktemp -d "$ROOT/shim.XXXXXX")"
git init -q "$SH"; git -C "$SH" config user.email t@t.local; git -C "$SH" config user.name t
mkdir -p "$SH/$VB"; echo x > "$SH/$VB/a.py"; git -C "$SH" add -A; git -C "$SH" commit -q -m c0
SH0="$(git -C "$SH" rev-parse HEAD)"; echo y >> "$SH/$VB/a.py"; git -C "$SH" commit -q -am c1; SH1="$(git -C "$SH" rev-parse HEAD)"
SHN="$(mktemp -d "$ROOT/shim.XXXXXX")"
git init -q "$SHN"; git -C "$SHN" config user.email t@t.local; git -C "$SHN" config user.name t
mkdir -p "$SHN/lib"; echo x > "$SHN/lib/x.py"; git -C "$SHN" add -A; git -C "$SHN" commit -q -m c0
SHN0="$(git -C "$SHN" rev-parse HEAD)"; echo y >> "$SHN/lib/x.py"; git -C "$SHN" commit -q -am c1; SHN1="$(git -C "$SHN" rev-parse HEAD)"
# A `git` that answers every `diff` with one quoted record + the end-of-list sentinel.
git() { case " $* " in *" diff "*) printf '"lib/predictive_dialer/voicebot/liga\\303\\247\\303\\243o.py"\0\0'; return 0 ;; esac; command git "$@"; }
voicebot_vm_delta_touched "$SH" "$SH0" "$SH1"
V_PKG="$VM_DELTA_VERDICT"
voicebot_vm_delta_touched "$SHN" "$SHN0" "$SHN1"
V_NOPKG="$VM_DELTA_VERDICT"
unset -f git
[ "$V_PKG" = "unknown" ] && ok "t5a a quoted path in a rig WITH the package -> unknown (the VM gets asked)" || nok "t5a a path that could not be parsed read as '$V_PKG'" ""
[ "$V_NOPKG" = "no" ] && ok "t5b the same in a rig WITHOUT the package -> no (nothing to carry, as everywhere else)" || nok "t5b rig without the package read as '$V_NOPKG'" ""
# The delta list is read through a process substitution (a `$(...)` would drop the NUL
# separators), so git's own failure has to be told apart from "git printed nothing": a diff
# that FAILS must not read as an empty delta.
git() { case " $* " in *" diff "*) return 1 ;; esac; command git "$@"; }
voicebot_vm_delta_touched "$SH" "$SH0" "$SH1"
V_FAIL="$VM_DELTA_VERDICT"; V_FAIL_WHY="$VM_DELTA_WHY"
unset -f git
[ "$V_FAIL" = "unknown" ] && ok "t6 a git diff that FAILS is 'could not read' (unknown), not an empty delta" || nok "t6 a failed git diff read as '$V_FAIL'" "$V_FAIL_WHY"
# Control: git succeeding with an EMPTY list is a real "nothing changed" -> no.
git() { case " $* " in *" diff "*) printf '\0'; return 0 ;; esac; command git "$@"; }
voicebot_vm_delta_touched "$SH" "$SH0" "$SH1"
V_EMPTY="$VM_DELTA_VERDICT"
unset -f git
[ "$V_EMPTY" = "no" ] && ok "t6b (control) git succeeding with an empty list is a real 'no'" || nok "t6b an empty-but-successful diff read as '$V_EMPTY'" ""

# ── (u) the delta predicate is exactly the manifest's, no wider ──
# voicebot_vm_sync.compute_manifest skips only *.md and the package-ROOT requirements.txt; a
# nested requirements.txt (or any other file) ships to the VM. The predicate used to skip
# "$pkg"/*/requirements.txt too — a file the VM receives, read as "nothing reaches the VM".
echo "(u) only *.md and the package-ROOT requirements.txt stay home"
reset_scenario; new_city
SC_FILES="$VB/models/requirements.txt"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "u1 a NESTED requirements.txt ships to the VM -> consulted, held" || nok "u1 a nested requirements.txt was read as 'stays home'" "calls=$VM_CALLS $VARS_OUT"
reset_scenario; new_city
SC_FILES="$VB/requirements.txt"; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "0" ] && reached && ok "u2 (control) the package-ROOT requirements.txt still stays home" || nok "u2 over-held the root requirements.txt" "calls=$VM_CALLS $VARS_OUT"

# ── (v) the closure answers 'no' only with a real, readable closure ──
# Gate fix-attempt 2 (ga-8xbsjh), blocking 2. A closure script that exits 0 and prints
# NOTHING gave closure="" — accepted as an answer, so every changed lib/*.py read "not in the
# closure" -> no. The real closure is never empty (22 modules today), so empty output is itself
# the "could not compute" signal — the same rule voicebot_vm_status applies to an exit 0 it
# cannot corroborate.
echo "(v) an empty or unreadable closure is 'could not compute', not 'not in the closure'"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_OUT=""; SC_CLOSURE_RC=0; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "v1 closure exit 0 with EMPTY output -> unknown -> consulted, held" || nok "v1 an empty closure was read as 'not in the closure'" "calls=$VM_CALLS $VARS_OUT"
has "$BD_CALLS" "pode mexer" && ok "v1 the comment hedges ('pode mexer'), it does not claim the delta touches the VM" || nok "v1 empty closure not hedged" "$BD_CALLS"
reset_scenario; new_city
SC_FILES="lib/unrelated.py"; SC_CLOSURE_OUT="ERRO: fechamento incompleto"; SC_CLOSURE_RC=0; SC_STATUS_RC=10
run_block
[ "$VM_CALLS" = "1" ] && held && ok "v2 closure exit 0 printing something that is not module names -> unknown -> consulted, held" || nok "v2 an unreadable closure was read as 'not in the closure'" "calls=$VM_CALLS $VARS_OUT"

# ── (w) the cause of an unreadable status is shown ──
# voicebot_vm_status ran the contract with 2>/dev/null and said "exit 2, que o contrato não
# define" — but the contract defines 2 ("uso errado"), and its stderr ("ERRO: shared/data
# ausente (rode scripts/ensure_symlinks.sh)") is the only place the cause is written. The hold
# was right; the comment and the 24h mail carried a false statement and no cause.
echo "(w) the status script's stderr reaches the comment; exit 2 is worded as the contract defines it"
reset_scenario; new_city
SC_STATUS_RC=2; SC_STATUS_OUT=""; SC_STATUS_ERR="ERRO: shared/data ausente (rode scripts/ensure_symlinks.sh)"
run_block
held && pending_label && ok "w1 exit 2 holds as 'não sei'" || nok "w1 exit 2" "$VARS_OUT / $BD_CALLS"
has "$BD_CALLS" "ensure_symlinks.sh" && ok "w1 the comment carries the script's stderr (the only place the cause is written)" || nok "w1 stderr dropped" "$BD_CALLS"
has "$BD_CALLS" "uso errado" && ok "w1 exit 2 is called what the contract calls it: uso errado" || nok "w1 exit 2 not described as uso errado" "$BD_CALLS"
has "$BD_CALLS" "que o contrato não define" && nok "w1 exit 2 described as undefined by the contract (it is defined)" "$BD_CALLS" || ok "w1 no false 'que o contrato não define' for exit 2"
reset_scenario; new_city
SC_STATUS_RC=3; SC_STATUS_OUT=""; SC_STATUS_ERR="Traceback: boom"
run_block
has "$BD_CALLS" "boom" && has "$BD_CALLS" "que o contrato não define" && ok "w2 an exit the contract really does not define: stderr shown AND still 'não define'" || nok "w2 exit 3" "$BD_CALLS"
BIGERR="$(head -c 120000 /dev/zero | tr '\0' 'e')"
reset_scenario; new_city
SC_STATUS_RC=2; SC_STATUS_OUT=""; SC_STATUS_ERR="$BIGERR"
run_block
[ "$RUN_RC" -eq 0 ] && held && [ "${#BD_CALLS}" -lt 8000 ] && ok "w3 120KB of stderr: the block survives and the comment stays bounded (${#BD_CALLS} bytes)" || nok "w3 oversized stderr" "rc=$RUN_RC $VARS_OUT bytes=${#BD_CALLS}"

# ── (x) a story closed while the VM was being read gets no mutation (ga-rugqks) ──
# The last closed-now check sits before Step 5b's reprobe (up to 180s); delta + closure (<=60s)
# and --status (<=30s) come after it. The likeliest way a hold ENDS — the Mayor deploys the
# VM by hand and closes the story — lands in that window.
echo "(x) closed while 6a was reading -> no label, comment, nudge or mail"
no_mutation() {
  local m=0 p
  for p in "label add" "label remove" " comment "; do has "$BD_CALLS" "$p" && m=1; done
  has "$GC_CALLS" "session nudge" && m=1
  has "$GC_CALLS" "mail send" && m=1
  [ "$m" = "0" ]
}
reset_scenario; new_city
SC_CLOSED_NOW=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
held && no_mutation && ok "x1 pending status on a story closed meanwhile: nothing written, nobody nudged" || nok "x1 mutated a closed story" "$VARS_OUT / $BD_CALLS / $GC_CALLS"
reset_scenario; new_city
SC_CLOSED_NOW=1; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5"
run_block
held && no_mutation && ok "x2 failed status on a story closed meanwhile: nothing written, nobody nudged" || nok "x2 mutated a closed story" "$VARS_OUT / $BD_CALLS / $GC_CALLS"
reset_scenario; new_city
SC_CLOSED_NOW=1; SC_FILES="docs/x.md"; SC_LABELS="delivery:pending-vm"
run_block
held && no_mutation && ok "x3 delta clean + stale pending-vm on a story closed meanwhile: label left alone" || nok "x3 mutated a closed story" "$VARS_OUT / $BD_CALLS / $GC_CALLS"
reset_scenario; new_city
SC_CLOSED_NOW=1; SC_LABELS="delivery:pending-vm"
run_block
held && no_mutation && ok "x4 em dia + pending-vm on a story closed meanwhile: label left alone" || nok "x4 mutated a closed story" "$VARS_OUT / $BD_CALLS / $GC_CALLS"

# ── (y) the hold state is never silently lost ──
# `mkdir -p ... || true` + `printf > file 2>/dev/null || true`: with an unwritable state dir
# `since` was reborn as NOW every cycle, so the 24h Mayor-mail ceiling could never fire and
# the comment dedup broke — and nothing said so.
echo "(y) a hold-state write that fails, or a 'since' nobody can read, is a WARN"
reset_scenario; new_city
SC_BREAK_STATE_DIR=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
[ "$RUN_RC" -eq 0 ] && held && pending_label && ok "y1 an unwritable hold-state dir does not abort the sweep; the story is still held" || nok "y1 unwritable state dir" "rc=$RUN_RC $VARS_OUT"
has "$LOG_OUT" "não consegui gravar o estado do hold" && ok "y1 the failed state write is a WARN (the 24h ceiling cannot fire without it)" || nok "y1 the failed state write was silent" "$LOG_OUT"
reset_scenario; new_city
SC_BREAK_STATE_DIR=1; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5"
run_block
has "$LOG_OUT" "não consegui gravar o estado do hold" && ok "y1b same WARN on the failed branch" || nok "y1b the failed branch swallowed the state-write failure" "$LOG_OUT"
reset_scenario; new_city
mkdir -p "$CITY/.gc/runtime/voicebot-vm-hold"
printf 'fp=pending|STATUS: pendente — ligação em curso\nsince=lixo\nmailed=0\n' > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"
SC_LABELS="delivery:pending-vm"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
has "$LOG_OUT" "since ilegível" && ok "y2 a state file whose 'since' is garbage is a WARN (the 24h clock restarts)" || nok "y2 the 24h clock was reset silently" "$LOG_OUT"
# Controls for gaps the gate review named (they pass on HEAD too): a failed comment / mail is
# retried next cycle because its fingerprint / mailed flag was NOT stored.
reset_scenario; new_city
SC_BD_FAIL_COMMENT=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
c1="$(count_of "$BD_CALLS" "Delivery HELD")"
SC_BD_FAIL_COMMENT=0; SC_LABELS="delivery:pending-vm"
run_block
c2="$(count_of "$BD_CALLS" "Delivery HELD")"
[ "$c1" = "1" ] && [ "$c2" = "1" ] && ok "y3 (control) a comment that failed is retried next cycle (fingerprint not stored)" || nok "y3 comment counts $c1 then $c2" "$BD_CALLS"
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
SINCE=$(( $(date +%s) - 90000 ))
fp="$(grep '^fp=' "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state" 2>/dev/null | head -1)"
printf '%s\nsince=%s\nmailed=0\n' "$fp" "$SINCE" > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"
SC_LABELS="delivery:pending-vm"; SC_GC_FAIL_MAIL=1
run_block
m1="$(count_of "$GC_CALLS" "mail send mayor")"; mailed_after="$(grep '^mailed=' "$STATE_FILE_ABS" 2>/dev/null | head -1)"
SC_GC_FAIL_MAIL=0
run_block
m2="$(count_of "$GC_CALLS" "mail send mayor")"
[ "$m1" = "1" ] && [ "$mailed_after" = "mailed=0" ] && [ "$m2" = "1" ] && ok "y4 (control) a Mayor mail that failed is retried next cycle (mailed flag not set)" || nok "y4 mail counts $m1 then $m2, state '$mailed_after'" "$GC_CALLS"
has "$STEP8" 'rm -f "$VM_HOLD_FILE"' && ok "y5 (control) Step 8 removes the hold-state file of a delivered story" || nok "y5 Step 8 leaves the VM hold state behind" ""

# ── (z) a hold already on the bead is never released because nobody can be asked ──
# Contract absent = "behave as before" is for a story that was NEVER held. If the contract
# script later disappears from the checkout (revert, odd checkout) while delivery:pending-vm —
# or a VM-originated delivery:failed — is on the story, "could not ask" used to proceed exactly
# like "the VM is fine": the label came off and the story reached story:done.
echo "(z) script gone while a VM hold exists -> still held (could not ask != em dia)"
reset_scenario; new_city
SC_SCRIPT_PRESENT=0; SC_LABELS="delivery:pending-vm"
run_block
held && ok "z1 pending hold + contract script gone -> still held" || nok "z1 the hold was released because the script vanished" "$VARS_OUT"
has "$BD_CALLS" "label remove ga-test delivery:pending-vm" && nok "z1 delivery:pending-vm removed although the VM could not be asked" "$BD_CALLS" || ok "z1 delivery:pending-vm kept"
done_written && nok "z1 story:done/close written" "$BD_CALLS" || ok "z1 no story:done and no close"
has "$BD_CALLS" "não existe neste checkout" && ok "z1 the comment says the contract script is gone" || nok "z1 the hold was kept without saying why" "$BD_CALLS"
reset_scenario; new_city
mkdir -p "$CITY/.gc/runtime/voicebot-vm-hold"
printf 'fp=failed|STATUS: falhou — md5\nsince=%s\nmailed=0\n' "$(date +%s)" > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"
SC_SCRIPT_PRESENT=0; SC_LABELS="delivery:failed"
run_block
held && pending_label && ok "z2 a VM-originated failed hold + script gone -> still held (as pending-vm)" || nok "z2 a failed VM hold was released" "$VARS_OUT / $BD_CALLS"
# Control (passes on HEAD too): delivery:failed from ANOTHER cause (prod test, deploy) has no
# VM hold state, so a missing contract script still means "as today" for that story.
reset_scenario; new_city
SC_SCRIPT_PRESENT=0; SC_LABELS="delivery:failed"
run_block
reached && has "$BD_CALLS" "contrato ausente" && ok "z3 (control) delivery:failed from another cause + script absent -> proceeds as today, with the comment" || nok "z3 a non-VM failure got held on the VM gate" "$VARS_OUT / $BD_CALLS"
# The comment states what the code KNOWS (the path is missing), not why it is missing.
reset_scenario; new_city
SC_SCRIPT_PRESENT=0
run_block
has "$BD_CALLS" "possivelmente a wa-y0su67" && ok "z4 the contract-absent comment hedges its cause ('possivelmente a wa-y0su67 ainda não entrou no main')" || nok "z4 cause stated as fact" "$BD_CALLS"

# ── (aa) a hold label that was NOT written must not release delivery:running ──
# Gate fix-attempt 3 (ga-onxu8f), blocking 1 — the same class (root-class:error-vs-empty), one
# level up: the hold-label WRITE itself. Both hold branches ran `label add <hold> || true` and
# then removed delivery:running unconditionally, stored the hold in the state file and (pending)
# commented "o label delivery:pending-vm fica no bead". With the add failing, the story was left
# story:approved + gate:passed with NO delivery:* label at all — which is exactly what
# merged-bead-janitor reads as done:commit-in-origin-main, and force-closes with story:done
# while the VM runs old code. The cases above only ever failed `bd comment`, never `label add`.
# Rule under test: delivery:running is the lock until a hold label is CONFIRMED; nothing
# downstream (lock release, opposite-label removal, comment, nudge, state fingerprint) behaves as
# if the hold existed. Controls that pass on the previous HEAD by design: aa2b, aa5, aa5b, aa7
# (mail count and mailed flag — not the lock line aa7b).
echo "(aa) hold label add FAILS -> delivery:running stays as the lock, and nothing claims a hold that does not exist"
lock_released() { has "$BD_CALLS" "label remove ga-test delivery:running"; }
state_fp()      { printf '%s\n' "$STATE_AFTER" | sed -n 's/^fp=//p' | head -n 1; }
state_since()   { printf '%s\n' "$STATE_AFTER" | sed -n 's/^since=//p' | head -n 1; }
reset_scenario; new_city
SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
[ "$RUN_RC" -eq 0 ] && held && ok "aa1 pending + label add failing: the block survives and the story is still held" || nok "aa1 rc/held" "rc=$RUN_RC $VARS_OUT out=[$BLOCK_OUT]"
pending_label && ok "aa1 (precondition) the add of delivery:pending-vm WAS attempted" || nok "aa1 the add was never attempted — the stub proves nothing" "$BD_CALLS"
lock_released && nok "aa1 delivery:running REMOVED although delivery:pending-vm was never written — the story is left with no delivery:* label (the janitor force-closes it)" "$BD_CALLS" || ok "aa1 delivery:running NOT removed: it stays as the lock"
has "$LOG_OUT" "WARN: Could not write delivery:pending-vm on ga-test" && has "$LOG_OUT" "keeping delivery:running as the lock" && ok "aa1 a WARN says the hold label could not be written and the lock is kept" || nok "aa1 the failed hold-label write is silent" "$LOG_OUT"
done_written && nok "aa1 story:done / close written" "$BD_CALLS" || ok "aa1 no story:done and no close"
[ "$(count_of "$BD_CALLS" "Delivery HELD")" = "0" ] && ok "aa2 no 'Delivery HELD' comment (it says the label stays on the bead — it was never written)" || nok "aa2 commented a hold the bead does not carry" "$BD_CALLS"
case "$(state_fp)" in pending\|*) nok "aa2 the state file records fp=pending for a hold that was never placed" "$STATE_AFTER" ;; *) ok "aa2 the state file does not record the hold as placed" ;; esac
case "$(state_since)" in ''|*[!0-9]*) nok "aa2b (control) since is not persisted — the 24h clock would restart" "$STATE_AFTER" ;; *) ok "aa2b (control) since IS persisted: the 24h clock keeps running while the label cannot be written" ;; esac

reset_scenario; new_city
SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
[ "$RUN_RC" -eq 0 ] && held && failed_label && ok "aa3 failed + label add failing: held, the add of delivery:failed WAS attempted" || nok "aa3 rc/held/attempt" "rc=$RUN_RC $VARS_OUT $BD_CALLS"
lock_released && nok "aa3 delivery:running REMOVED although delivery:failed was never written" "$BD_CALLS" || ok "aa3 delivery:running NOT removed"
has "$LOG_OUT" "WARN: Could not write delivery:failed on ga-test" && has "$LOG_OUT" "keeping delivery:running as the lock" && ok "aa3 a WARN says delivery:failed could not be written and the lock is kept" || nok "aa3 the failed hold-label write is silent" "$LOG_OUT"
[ "$(count_of "$BD_CALLS" "Delivery FAILED")" = "0" ] && ! has "$GC_CALLS" "session nudge" && ok "aa3 no 'Delivery FAILED' comment and nobody nudged about a hold that does not exist" || nok "aa3 announced a hold the bead does not carry" "$BD_CALLS / $GC_CALLS"
case "$(state_fp)" in failed\|*) nok "aa3 the state file records fp=failed for a hold that was never placed" "$STATE_AFTER" ;; *) ok "aa3 the state file does not record the failed hold as placed" ;; esac

# The opposite hold stays while the new one cannot be written: dropping it would again leave
# the story with no delivery:* label.
reset_scenario; new_city
SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
SC_LABELS="delivery:pending-vm"; SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
has "$BD_CALLS" "label remove ga-test delivery:pending-vm" && nok "aa4 pending -> failed with the add failing: delivery:pending-vm REMOVED (no hold label left)" "$BD_CALLS" || ok "aa4 pending -> failed, add failing: delivery:pending-vm kept"
lock_released && nok "aa4 pending -> failed, add failing: delivery:running released" "$BD_CALLS" || ok "aa4 pending -> failed, add failing: delivery:running kept"
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
SC_LABELS="delivery:failed"; SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
has "$BD_CALLS" "label remove ga-test delivery:failed" && nok "aa4b failed -> pending with the add failing: delivery:failed REMOVED (no hold label left)" "$BD_CALLS" || ok "aa4b failed -> pending, add failing: delivery:failed kept"
lock_released && nok "aa4b failed -> pending, add failing: delivery:running released" "$BD_CALLS" || ok "aa4b failed -> pending, add failing: delivery:running kept"

# Controls (pass on HEAD too): when the hold label is ALREADY on the bead the add is not
# attempted (i1 pins that), so a failing `label add` cannot matter and the lock is released.
reset_scenario; new_city
SC_LABELS="delivery:pending-vm"; SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
held && lock_released && ! pending_label && ok "aa5 (control) pending-vm already on the bead: no add attempted, the lock is released as before" || nok "aa5 a hold already on the bead was treated as unplaced" "$VARS_OUT / $BD_CALLS"
has "$LOG_OUT" "Could not write" && nok "aa5 a WARN about an add that was never attempted" "$LOG_OUT" || ok "aa5 no WARN for an add that was never attempted"
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
SC_LABELS="delivery:failed"; SC_BD_FAIL_LABEL_ADD=1
run_block
held && lock_released && ! failed_label && ok "aa5b (control) delivery:failed already on the bead: no add attempted, the lock is released as before" || nok "aa5b a failed hold already on the bead was treated as unplaced" "$VARS_OUT / $BD_CALLS"

# Recovery: the cycle after the failure has a fresh snapshot, places the label, releases the
# lock — and, because the failed cycle stored no fingerprint, posts the comment it never posted.
reset_scenario; new_city
SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
h1="$(count_of "$BD_CALLS" "Delivery HELD")"
SC_BD_FAIL_LABEL_ADD=0
run_block
h2="$(count_of "$BD_CALLS" "Delivery HELD")"
held && pending_label && lock_released && [ "$h1" = "0" ] && [ "$h2" = "1" ] \
  && ok "aa6 next cycle (add works): label written, lock released, the hold is announced exactly once (0 then 1)" \
  || nok "aa6 recovery after a failed hold-label write: comments $h1 then $h2" "$VARS_OUT / $BD_CALLS"

# Control (passes on HEAD too): the >24h Mayor mail does not depend on the label write — a VM
# unproven for a day is exactly when bd is most likely to be sick, and the mail is what catches it.
reset_scenario; new_city
mkdir -p "$CITY/.gc/runtime/voicebot-vm-hold"
printf 'fp=\nsince=%s\nmailed=0\n' "$(( $(date +%s) - 90000 ))" > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"
SC_BD_FAIL_LABEL_ADD=1; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_block
[ "$(count_of "$GC_CALLS" "mail send mayor")" = "1" ] && ok "aa7 (control) pending > 24h with the add failing: the Mayor is still mailed exactly once" || nok "aa7 mail count" "$GC_CALLS"
[ "$(printf '%s\n' "$(cat "$STATE_FILE_ABS" 2>/dev/null)" | sed -n 's/^mailed=//p' | head -n 1)" = "1" ] && ok "aa7 (control) the mailed flag is persisted (no second mail next cycle)" || nok "aa7 mailed flag not stored" "$STATE_AFTER"
lock_released && nok "aa7b >24h + add failing: delivery:running released" "$BD_CALLS" || ok "aa7b >24h + add failing: delivery:running kept"

# ── (ab) a hold label that could not be REMOVED is said, not claimed ──
# Same class on the release side: `label remove ... || true` and then a comment saying
# "delivery:pending-vm removido". The story still proceeds (the VM IS em dia, and Step 8 sweeps
# the label again — r1), but nothing may say the label is gone when it is not, and the failure
# is a WARN, not silence.
echo "(ab) a failed removal of a hold label is a WARN and the comment does not claim it"
reset_scenario; new_city
SC_LABELS="delivery:pending-vm"; SC_BD_FAIL_LABEL_REMOVE=1
run_block
reached && ok "ab1 em dia + removal failing: the story still proceeds (the VM is proven)" || nok "ab1 held on a proven VM" "$VARS_OUT"
has "$LOG_OUT" "WARN: Could not remove delivery:pending-vm from ga-test" && ok "ab1 the failed removal is a WARN" || nok "ab1 the failed removal is silent" "$LOG_OUT"
has "$BD_CALLS" "delivery:pending-vm removido" && nok "ab1 the comment says delivery:pending-vm was removed — it was not" "$BD_CALLS" || ok "ab1 the comment does not claim a removal that failed"
reset_scenario; new_city
SC_LABELS="delivery:pending-vm"
run_block
has "$BD_CALLS" "delivery:pending-vm removido" && ok "ab1b (control) removal OK: the comment still says delivery:pending-vm removido" || nok "ab1b the success comment lost its claim" "$BD_CALLS"
reset_scenario; new_city
SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 não bate"
run_block
SC_LABELS="delivery:failed"; SC_BD_FAIL_LABEL_REMOVE=1; SC_STATUS_RC=0; SC_STATUS_OUT="STATUS: em dia — md5 igual na VM"
run_block
reached && has "$LOG_OUT" "WARN: Could not remove delivery:failed from ga-test" && ok "ab2 failed -> em dia with the removal failing: proceeds, and the stale delivery:failed is a WARN" || nok "ab2 stale delivery:failed left in silence" "$VARS_OUT / $LOG_OUT"
reset_scenario; new_city
SC_FILES="docs/x.md"; SC_LABELS="delivery:pending-vm"; SC_BD_FAIL_LABEL_REMOVE=1
run_block
reached && has "$LOG_OUT" "WARN: Could not remove delivery:pending-vm from ga-test" && ok "ab3 delta clean + stale pending-vm + removal failing: proceeds, and the stale label is a WARN" || nok "ab3 stale pending-vm left in silence" "$VARS_OUT / $LOG_OUT"
# The hold STATE is the third thing a finished hold leaves behind: if clearing it fails, a later
# unrelated hold on the same story inherits the old `since` (24h mail fires at once) and `mailed`.
# A directory where the state file should be makes `rm -f` fail for real.
reset_scenario; new_city
mkdir -p "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state"; : > "$CITY/.gc/runtime/voicebot-vm-hold/ga-test.state/keep"
run_block
reached && has "$LOG_OUT" "WARN: Could not clear the VM hold state" && ok "ab4 em dia + the hold state cannot be cleared: proceeds, and the leftover state is a WARN" || nok "ab4 a state file that could not be cleared is silent" "$VARS_OUT / $LOG_OUT"

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
