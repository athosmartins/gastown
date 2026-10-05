#!/usr/bin/env bash
# gate-close-asks-voicebot-vm.selftest.sh (ga-wye9vt)
#
# THE BUG (measured by the Mayor, 12 of 21 bug/task closes): the dispatcher's PASS path closed a
# bug/task source bead the moment its merge was verified, without asking whether the merge TOUCHED
# THE VOICEBOT and whether the dialer VM (jambonz-dialer) was running that code. story-delivery.sh
# asks since ga-2kaan2 (Step 6a); the bug/task path never did, so "gate passed + merged" became
# "closed, done" with the VM still on old code — the 04/10 wa-kj0x2h class, one path over.
#
# THE FIX under test (Mayor's Option A, comment 2026-10-05 11:23 on ga-wye9vt): before the close, a
# merge whose own delta touches what the VM runs asks `voicebot_vm_sync.py --status` (the same
# contract ga-2kaan2 uses): exit 0 + a "STATUS: em dia" line → close as before; 10 / 20 / anything
# else (timeout, exit 3, unreadable) → HOLD with delivery:pending-vm + a comment carrying the reason,
# bead left open, no automatic re-query. Script ABSENT (wa-y0su67 not in the checkout) → close as
# today plus the comment 'VM não verificada: contrato ausente'. A bead that ALREADY wears
# delivery:pending-vm is held through gate_own_hold_check's OWN_HOLD_LABELS (ga-hwzzou's mechanism).
# The hold is not revisited, so a 24h CEILING (gate_vm_hold_ceiling_sweep, run every sweep before the
# empty-queue exit) mails the Mayor ONCE for a hold that still stands — it never re-asks the VM and
# never releases the hold (section 6b).
#
# WHAT THIS RUNS: the REAL `pass-close-decision` region of the live dispatcher (sibling check +
# own-hold check + VM check + the close itself) with the real helpers extracted verbatim, against a
# mocked `bd`, a stub for the contract script (no ssh / VM / network) and a throw-away git repo for the
# delta. The observable is the bug's literal symptom: whether `bd close` is called on the bead.
# Section 6 MUTATES the extracted code (each mutation re-creates one defect) and requires the
# matching scenario to go red. Section 7 pins the dispatcher's COPY of the helpers to
# story-delivery.sh's (the two scripts are self-contained by convention, so the copy is guarded).
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
STORY_DELIVERY="$SELF_DIR/story-delivery.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$STORY_DELIVERY" ] || { echo "FATAL: story-delivery.sh not found at $STORY_DELIVERY" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo "FATAL: timeout(1) not on PATH — the dispatcher's VM check needs it" >&2; exit 2; }

echo "== gate-close-asks-voicebot-vm.selftest (ga-wye9vt) =="

# ── 1. extract the real pieces VERBATIM from the live dispatcher ─────────────
echo "── 1. extract the real close-decision region and its helpers ──"
extract() {  # $1 = marker name
  awk -v b="SELFTEST-EXTRACT $1: BEGIN" -v e="SELFTEST-EXTRACT $1: END" \
    'index($0,b){f=1;next} index($0,e){f=0} f' "$DISPATCHER"
}
FN_OWN="$(extract own-hold-check-fn)"
FN_SIB="$(extract sibling-hold-check-fn)"
FN_CLOSE="$(extract gate-close-source-terminal-fn)"
REGION="$(extract pass-close-decision)"
for _n in FN_OWN FN_SIB FN_CLOSE REGION; do
  [ -n "${!_n}" ] || { echo "FATAL: could not extract $_n — SELFTEST-EXTRACT markers moved?" >&2; exit 2; }
  ok "extracted $_n ($(printf '%s\n' "${!_n}" | wc -l | tr -d ' ') lines)"
done
# The VM pieces are the ones this bead ADDS. A missing one is a FAILED assertion, not a fatal
# error: the scenarios below must run — and fail by BEHAVIOUR — against a dispatcher without them.
FN_VM_HELPERS="$(extract vm-helpers)"
FN_VM_CHECK="$(extract vm-hold-check-fn)"
FN_VM_CEIL="$(extract vm-hold-ceiling-fn)"
for _n in FN_VM_HELPERS FN_VM_CHECK FN_VM_CEIL; do
  if [ -n "${!_n}" ]; then ok "extracted $_n ($(printf '%s\n' "${!_n}" | wc -l | tr -d ' ') lines)"
  else bad "could not extract $_n — the dispatcher has no such SELFTEST-EXTRACT region"; fi
done

# Order inside the region: own-hold check, THEN the VM check, THEN the close — otherwise the
# scenarios below would run a close that never saw the VM check and pass vacuously.
_pos_own=$(printf '%s\n' "$REGION" | grep -n 'gate_own_hold_check "\$BEAD_CITY" "\$BEAD_ID"' | head -1 | cut -d: -f1 || true)
_pos_vm=$(printf '%s\n' "$REGION" | grep -n 'gate_vm_hold_check ' | head -1 | cut -d: -f1 || true)
_pos_close=$(printf '%s\n' "$REGION" | grep -n 'gate_close_source_terminal "\$BEAD_ID"' | head -1 | cut -d: -f1 || true)
if [ -n "$_pos_own" ] && [ -n "$_pos_vm" ] && [ -n "$_pos_close" ] && [ "$_pos_own" -lt "$_pos_vm" ] && [ "$_pos_vm" -lt "$_pos_close" ]; then
  ok "region runs own-hold check (line $_pos_own) BEFORE gate_vm_hold_check (line $_pos_vm) BEFORE the close (line $_pos_close)"
else
  bad "region does not order own-hold check (${_pos_own:-none}) → gate_vm_hold_check (${_pos_vm:-none}) → close (${_pos_close:-none})"
fi

# Static drift guards. IS_VM_HOLD must be initialised per PASS and must gate BOTH the close and the
# POST-MERGE re-spawn exemption (a held-open bead would otherwise false-flag as a re-pick vector and
# mail the Mayor). The VM flag rides on the SAME two conditions as IS_OWN_HOLD (checked below). The
# reverse is not true: the VM check itself READS IS_OWN_HOLD to skip a bead that is held anyway, which
# is why gate-close-honors-existing-hold.selftest.sh now pins THREE IS_OWN_HOLD readers, not two.
_n_init=$(grep -cE '^[[:space:]]*IS_VM_HOLD=0[[:space:]]*$' "$DISPATCHER" || true)
eq "IS_VM_HOLD is initialised to 0 once per PASS block" "$_n_init" "1"
_n_gate=$(grep -cF '[ "$IS_VM_HOLD" != "1" ]' "$DISPATCHER" || true)
eq "IS_VM_HOLD gates exactly two conditions (the close + the POST-MERGE exemption)" "$_n_gate" "2"
_n_both=$(grep -F '[ "$IS_VM_HOLD" != "1" ]' "$DISPATCHER" | grep -cF '[ "$IS_OWN_HOLD" != "1" ]' || true)
eq "both of them are the IS_OWN_HOLD conditions (same two sites, no third)" "$_n_both" "2"

# ── 2. harness: mocked bd/gc, real helpers, stub contract script, throw-away repo ──
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ERR_F="$WORK_DIR/stderr"; LOG_F="$WORK_DIR/log"; COMMENT_F="$WORK_DIR/comments"
LABEL_F="$WORK_DIR/labels"; CLOSE_F="$WORK_DIR/closes"; GC_F="$WORK_DIR/gc"
STUB_CALLS="$WORK_DIR/vm-calls"

FX=ga-wye9vt-fx
VB="lib/predictive_dialer/voicebot"

# Scenario inputs (globals; sc_reset restores the defaults).
sc_reset() {
  SC_FILES="$VB/capture_policy.py"   # files the merge's own delta changes
  SC_STATUS_RC=0
  SC_STATUS_OUT="STATUS: em dia — md5 igual na VM"
  SC_STATUS_ERR=""
  SC_STATUS_SLEEP=0
  SC_TIMEOUT_S=20
  SC_SCRIPT_PRESENT=1                # voicebot_vm_sync.py exists in the checkout
  SC_PRE_MAIN_KNOWN=1                # the gate recorded MERGE_PRE_MAIN_SHA
  SC_HAS_VB_DIR=1                    # the rig carries the voicebot package at all
  SC_CLOSURE_PRESENT=1               # scripts/voicebot_vm_lib_closure.py exists (the rig WA has it; other rigs never do)
  SC_CLOSURE_OUT="pipedrive_field_ids"   # the lib/ modules the voicebot imports
  SC_SHOW_LABELS='["gate:passed","lane:small"]'
  SC_LABEL_ADD_FAIL=0                # `bd label add` fails (rc 1)
  SC_RT_MODE=repo                    # repo | city (runtime_dir == GC_CITY) | empty (no runtime_dir mapping)
  SC_SIB=none                        # none | open
  SC_BREAK_STATE_DIR=0               # the hold-state directory cannot be created
}

bd() {
  case "${3:-}" in
    show)    printf '[{"id":"%s","labels":%s}]' "$FX" "$SC_SHOW_LABELS" ;;
    close)   printf 'CLOSED:%s\n' "${4:-}" >> "$CLOSE_F" ;;
    comment) printf '%s\n----\n' "${5:-}" >> "$COMMENT_F" ;;
    label)   printf '%s\n' "$*" >> "$LABEL_F"
             if [ "$SC_LABEL_ADD_FAIL" = "1" ] && [ "${4:-}" = "add" ]; then return 1; fi ;;
  esac
  return 0
}
gc()   { printf '%s\n' "$*" >> "$GC_F"; return 0; }
log()  { printf '%s\n' "$*" >> "$LOG_F"; }
warn() { printf '%s\n' "$*" >> "$LOG_F"; }
gate_bead_sibling_status_lines() {
  if [ "$SC_SIB" = "open" ]; then printf 'fix/%s-wa\topen\twhatsapp_automation\n' "$FX"; fi
  return 0
}
eval "$FN_SIB"
eval "$FN_OWN"
eval "$FN_CLOSE"
eval "$FN_VM_HELPERS"
eval "$FN_VM_CHECK"

# mk_repo — a fresh runtime checkout with a C0 base and a C1 merge that changes SC_FILES. The stub
# contract script is UNTRACKED, so it never shows up in the merge's own delta.
mk_repo() {
  local R="$1" f
  git init -q "$R"
  git -C "$R" config user.email t@t.local
  git -C "$R" config user.name t
  mkdir -p "$R/$VB" "$R/lib" "$R/scripts" "$R/docs"
  echo "# voicebot" > "$R/$VB/README.md"
  echo "x = 0" > "$R/$VB/capture_policy.py"
  echo "x = 0" > "$R/lib/unrelated.py"
  echo "x = 0" > "$R/lib/pipedrive_field_ids.py"
  echo "# doc" > "$R/docs/x.md"
  [ "$SC_HAS_VB_DIR" = "1" ] || rm -rf "$R/lib/predictive_dialer"
  git -C "$R" add -A; git -C "$R" commit -q -m C0
  SHA_C0="$(git -C "$R" rev-parse HEAD)"
  for f in $SC_FILES; do mkdir -p "$R/$(dirname "$f")"; echo "x = 1" >> "$R/$f"; done
  git -C "$R" add -A; git -C "$R" commit -q -m C1
  SHA_C1="$(git -C "$R" rev-parse HEAD)"
  if [ "$SC_CLOSURE_PRESENT" = "1" ]; then
    cat > "$R/scripts/voicebot_vm_lib_closure.py" <<'PYEOF'
import os, sys
out = os.environ.get("STUB_CLOSURE_OUT", "")
if out:
    sys.stdout.write(out.replace(" ", "\n") + "\n")
sys.exit(0)
PYEOF
  fi
  if [ "$SC_SCRIPT_PRESENT" = "1" ]; then
    cat > "$R/scripts/voicebot_vm_sync.py" <<'PYEOF'
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
}

run_region() {  # $1 = region text (default: the real one)
  local T; T="$(mktemp -d "$WORK_DIR/run.XXXXXX")"
  : > "$ERR_F"; : > "$LOG_F"; : > "$COMMENT_F"; : > "$LABEL_F"; : > "$CLOSE_F"; : > "$GC_F"; : > "$STUB_CALLS"
  mk_repo "$T/runtime"
  GC_CITY="$T/city"; mkdir -p "$GC_CITY/.gc/runtime"
  if [ "$SC_BREAK_STATE_DIR" = "1" ]; then : > "$GC_CITY/.gc/runtime/voicebot-vm-hold-gate"; fi
  case "$SC_RT_MODE" in
    repo)  DR_RUNTIME_DIR="$T/runtime" ;;
    city)  DR_RUNTIME_DIR="$GC_CITY"; mkdir -p "$GC_CITY/scripts"; cp "$T/runtime/scripts/voicebot_vm_sync.py" "$GC_CITY/scripts/" 2>/dev/null || true ;;
    empty) DR_RUNTIME_DIR="" ;;
  esac
  export STUB_CALLS STUB_RC="$SC_STATUS_RC" STUB_OUT="$SC_STATUS_OUT" STUB_ERR="$SC_STATUS_ERR" STUB_SLEEP="$SC_STATUS_SLEEP"
  export VOICEBOT_VM_STATUS_TIMEOUT_S="$SC_TIMEOUT_S" STUB_CLOSURE_OUT="$SC_CLOSURE_OUT"
  unset VOICEBOT_VM_SYNC_SCRIPT
  BEAD_CITY="$GC_CITY"; BEAD_ID="$FX"; BRANCH="fix/$FX"; RIG=whatsapp_automation
  DEFAULT_BRANCH=main; MERGE_SHA="$SHA_C1"; GATE_RUN_ID=run1; DAEMON_SOFT_WARN=""
  MERGE_PRE_MAIN_SHA="$SHA_C0"; [ "$SC_PRE_MAIN_KNOWN" = "1" ] || MERGE_PRE_MAIN_SHA=""
  IS_SIBLING_HOLD=0; IS_OWN_HOLD=0; IS_VM_HOLD=0
  SIBLING_HOLD_KIND=""; OWN_HOLD_KIND=""; OWN_HOLD_LABELS=""
  eval "${1:-$REGION}" 2>"$ERR_F"
  STATE_FILE="$GC_CITY/.gc/runtime/voicebot-vm-hold-gate/$FX.state"
  STATE_AFTER="$(cat "$STATE_FILE" 2>/dev/null || echo '<none>')"
  rm -rf "$T"
}
was_closed()   { grep -qF "CLOSED:$FX" "$CLOSE_F"; }
pend_label()   { grep -qF "label add $FX delivery:pending-vm" "$LABEL_F"; }
vm_calls()     { local n; n="$(grep -c -- '--status' "$STUB_CALLS" 2>/dev/null || true)"; echo "${n:-0}"; }
comments()     { cat "$COMMENT_F"; }
logtext()      { cat "$LOG_F"; }
NOT_UNKNOWN_WORDS='não consegui ler o status da VM'

# ── 3. the acceptance cases of the bead, through the real region ─────────────
echo "── 3. touches the voicebot: ask the VM; only 'em dia' closes ──"

# (a) touches + exit 10 → HOLD.
sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso na VM"
run_region
was_closed && bad "a1 REGRESSION/BUG: a voicebot-touching merge with the VM PENDING closed the bead" || ok "a1 touches + --status=10 → the bead is NOT closed"
eq "a1 IS_VM_HOLD=1" "${IS_VM_HOLD:-unset}" "1"
pend_label && ok "a1 delivery:pending-vm label written" || bad "a1 no delivery:pending-vm label: [$(cat "$LABEL_F")]"
has "$(comments)" "NOT closing (ga-wye9vt)" && ok "a1 the comment says it is not closing, citing ga-wye9vt" || bad "a1 comment lacks 'NOT closing (ga-wye9vt)': [$(comments)]"
has "$(comments)" "ligação em curso na VM" && ok "a1 the comment carries the script's own reason (--status)" || bad "a1 the --status reason is missing from the comment"
has "$(comments)" "TOUCHES what runs on the dialer VM" && has "$(comments)" "Held as delivery:pending-vm" \
  && ok "a1 the comment states the verdict it holds on (TOUCHES) and that the label IS on the bead" || bad "a1 comment lacks the TOUCHES verdict / the 'Held as delivery:pending-vm' statement: [$(comments)]"
has "$(comments)" "No automatic re-query" && ok "a1 the comment says honestly there is no automatic re-query" || bad "a1 the comment does not say there is no automatic re-query"
has "$(comments)" "bd -C " && has "$(comments)" "label remove $FX delivery:pending-vm" \
  && ok "a1 the comment names the manual release, pinning the store (bd -C ...)" || bad "a1 the comment has no pinned manual-release action"
! grep -qE 'Re-checked every|closes automatically|will close (it|this bead) (for you|automatically)' "$COMMENT_F" "$LOG_F" \
  && ok "a1 no false promise of an automatic retry/close" || bad "a1 a surface promises an automatic retry/close that nothing implements"
grep -q 'gate:reviewing' "$LABEL_F" && ok "a1 gate:reviewing is cleared on hold (wa-qq33j)" || bad "a1 gate:reviewing not cleared on hold"
has "$(logtext)" "holding, NOT closing (ga-wye9vt)" && ok "a1 the dispatcher log records the hold" || bad "a1 no log line for the hold"
eq "a1 the contract script is asked exactly once, with --status" "$(vm_calls)" "1"
has "$STATE_AFTER" "since=" && has "$STATE_AFTER" "mailed=0" && ok "a1 the hold state (since/mailed=0) is written for the 24h ceiling" || bad "a1 no hold state: [$STATE_AFTER]"
# The ceiling sweep finds the bead again from the state alone: the file name is the bead id, and the
# store (a rig bead does not live in the HQ store) rides in fp as "<kind>|<store>".
has "$STATE_AFTER" "fp=pending|" && has "$STATE_AFTER" "/city" \
  && ok "a1 the hold state records the kind AND the bead's store (the ceiling sweep needs it to re-read the bead)" || bad "a1 hold state lacks <kind>|<store>: [$STATE_AFTER]"
has "$(comments)" "ONE mail" && has "$(comments)" "VOICEBOT_VM_PENDING_MAIL_AFTER_S" \
  && ok "a1 the comment says when the Mayor is mailed, and which knob sets it" || bad "a1 the comment does not describe the 24h ceiling: [$(comments)]"

# (b) touches + exit 0 with the em-dia line → close as before.
sc_reset
run_region
was_closed && ok "b1 touches + em dia → the bead is CLOSED as before (the VM is proven current)" || bad "b1 the VM is em dia but the bead was held"
eq "b1 IS_VM_HOLD stays 0" "${IS_VM_HOLD:-unset}" "0"
eq "b1 the contract script was asked once" "$(vm_calls)" "1"
! grep -q 'delivery:pending-vm' "$LABEL_F" && ok "b1 no pending-vm label on a proven-current VM" || bad "b1 pending-vm label written for an em-dia VM"

# (c) does NOT touch → close, never asks.
sc_reset; SC_FILES="docs/x.md"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && ok "c1 a delta that does not reach the VM → CLOSED" || bad "c1 a docs-only merge was held on the VM gate"
eq "c1 the contract script is NOT consulted for a delta that does not touch the VM" "$(vm_calls)" "0"
sc_reset; SC_FILES="lib/unrelated.py"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && ok "c2 a lib/ file outside the voicebot closure → CLOSED, never asks" || bad "c2 held"
eq "c2 not consulted" "$(vm_calls)" "0"
# A lib/ module IN the closure the voicebot imports reaches the VM; with no closure script to
# say either way the delta is UNKNOWN, which asks (never "no").
sc_reset; SC_FILES="lib/pipedrive_field_ids.py"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
run_region
was_closed && bad "c4 a lib/ module in the voicebot closure closed the bead with the VM pending" || ok "c4 lib/ file IN the voicebot closure + VM pending → NOT closed"
has "$(comments)" "TOUCHES what runs" && ok "c4 proven by the closure: worded as the flat 'TOUCHES'" || bad "c4 wording: [$(comments)]"
sc_reset; SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && bad "c5 a lib/ change with NO closure script to ask was read as 'does not touch' and the bead closed" || ok "c5 lib/ change + closure script absent → delta UNKNOWN → asks → NOT closed"
eq "c5 the VM was asked" "$(vm_calls)" "1"
has "$(comments)" "MAY touch what runs" && ok "c5 worded as 'MAY touch' (a hedge)" || bad "c5 wording: [$(comments)]"
# A package-ROOT markdown file ships nowhere (compute_manifest excludes *.md).
sc_reset; SC_FILES="$VB/README.md"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && eq "c3 a *.md under the package is not shipped → CLOSED, never asks" "$(vm_calls)" "0" || bad "c3 a README-only merge was held on the VM gate"

# (d) exit 20 → HOLD with the reason.
sc_reset; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 diferente em 3 arquivos"
run_region
was_closed && bad "d1 a --status=20 (FAILED) merge CLOSED the bead" || ok "d1 touches + --status=20 → NOT closed"
has "$(comments)" "md5 diferente em 3 arquivos" && ok "d1 the failed reason is in the comment" || bad "d1 the failed reason is missing from the comment"
pend_label && ok "d1 the hold label is delivery:pending-vm (one label for every hold)" || bad "d1 no hold label"

# (e) every way of NOT KNOWING holds. "unknown" is never "em dia".
for _case in "exit3:3:STATUS: whatever" "exit1:1:" "exit2:2:uso errado" "timeout:0:STATUS: em dia"; do
  _name="${_case%%:*}"; _rest="${_case#*:}"; _rc="${_rest%%:*}"; _out="${_rest#*:}"
  sc_reset; SC_STATUS_RC="$_rc"; SC_STATUS_OUT="$_out"
  if [ "$_name" = timeout ]; then SC_STATUS_SLEEP=5; SC_TIMEOUT_S=1; fi
  run_region
  was_closed && bad "e/$_name an UNREADABLE status closed the bead (error read as 'em dia')" || ok "e/$_name unreadable status → NOT closed"
  has "$(comments)" "$NOT_UNKNOWN_WORDS" && ok "e/$_name the comment says the status could not be read" || bad "e/$_name comment does not say the read failed: [$(comments)]"
  ! has "$(comments)" "STATUS: pendente" && ok "e/$_name the comment does not present an unknown as 'pendente'" || bad "e/$_name unknown worded as pendente"
done
# exit 0 with NO "STATUS: em dia" line cannot be corroborated.
sc_reset; SC_STATUS_RC=0; SC_STATUS_OUT="tudo certo"
run_region
was_closed && bad "e/uncorroborated an exit 0 without the 'STATUS: em dia' line CLOSED the bead" || ok "e/uncorroborated exit 0 without the em-dia line → NOT closed"

# (f) contract ABSENT → close as today + the literal comment the Mayor named.
echo "── 4. contract absent / delta unreadable / not applicable ──"
sc_reset; SC_SCRIPT_PRESENT=0
run_region
was_closed && ok "f1 script absent (wa-y0su67 not in main) → CLOSED as today" || bad "f1 an ABSENT contract held the bead (it would never close until wa-y0su67 lands)"
has "$(comments)" "VM não verificada: contrato ausente" && ok "f1 the comment says 'VM não verificada: contrato ausente'" || bad "f1 no 'contrato ausente' comment: [$(comments)]"
! pend_label && ok "f1 no hold label on an absent contract" || bad "f1 hold label written for an absent contract"
sc_reset; SC_SCRIPT_PRESENT=0; SC_FILES="docs/x.md"
run_region
was_closed && ok "f2 script absent + delta does not touch the VM → CLOSED" || bad "f2 held"
! has "$(comments)" "contrato ausente" && ok "f2 no 'contrato ausente' noise when the delta does not reach the VM" || bad "f2 'contrato ausente' comment on a merge that does not touch the VM"

# (g) delta UNREADABLE (base not recorded) in a rig that HAS the package → unknown → ask, never "no".
sc_reset; SC_PRE_MAIN_KNOWN=0; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — deploy na fila"
run_region
was_closed && bad "g1 an UNREADABLE delta (no pre-merge base) was read as 'does not touch' and the bead closed" || ok "g1 unreadable delta + VM pending → NOT closed (unknown is not 'no')"
eq "g1 the VM was asked" "$(vm_calls)" "1"
has "$(comments)" "MAY touch what runs on the dialer VM" && ! has "$(comments)" "TOUCHES what runs" && ok "g1 worded as 'MAY touch' (a hedge), never the flat claim" || bad "g1 unknown delta worded as a flat 'TOUCHES': [$(comments)]"
sc_reset; SC_PRE_MAIN_KNOWN=0
run_region
was_closed && ok "g2 unreadable delta + VM em dia → CLOSED (the VM answered)" || bad "g2 held although the VM is proven current"

# (h) a rig WITHOUT the voicebot package has nothing to carry.
sc_reset; SC_HAS_VB_DIR=0; SC_FILES="lib/unrelated.py"; SC_PRE_MAIN_KNOWN=0; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && ok "h1 rig without the voicebot package → CLOSED" || bad "h1 a rig with no voicebot package was held"
eq "h1 never asks the VM" "$(vm_calls)" "0"

# (i) framework self-fix and unmapped runtime_dir: nothing to verify here / no checkout to ask.
sc_reset; SC_RT_MODE=city; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && ok "i1 framework self-fix (runtime_dir == GC_CITY) → CLOSED" || bad "i1 a framework self-fix was held on the VM gate"
eq "i1 never asks the VM" "$(vm_calls)" "0"
sc_reset; SC_RT_MODE=empty; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && ok "i2 no runtime_dir mapping → CLOSED (already surfaced by the daemon soft-warn)" || bad "i2 held"
eq "i2 never asks the VM" "$(vm_calls)" "0"
has "$(logtext)" "VM check skipped" && ok "i2 the skip is LOGGED, not silent" || bad "i2 silent skip: [$(logtext)]"

# ── 5. the hold interplay ────────────────────────────────────────────────────
echo "── 5. hold interplay ──"
# (j) a bead that ALREADY wears delivery:pending-vm is held through OWN_HOLD_LABELS (ga-hwzzou).
sc_reset; SC_SHOW_LABELS='["gate:passed","delivery:pending-vm"]'
run_region
was_closed && bad "j1 a bead already wearing delivery:pending-vm was CLOSED by a later PASS (the ga-hwzzou class, VM edition)" || ok "j1 delivery:pending-vm already on the bead → NOT closed"
eq "j1 OWN_HOLD_KIND=held" "${OWN_HOLD_KIND:-}" "held"
has "${OWN_HOLD_LABELS:-}" "delivery:pending-vm" && ok "j1 OWN_HOLD_LABELS names delivery:pending-vm" || bad "j1 OWN_HOLD_LABELS=[${OWN_HOLD_LABELS:-}]"
eq "j1 held bead: the VM is not asked a second time" "$(vm_calls)" "0"
# (k) an open sibling already holds the bead: no second read, no VM query.
sc_reset; SC_SIB=open; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && bad "k1 sibling-held bead closed" || ok "k1 open sibling → still NOT closed (ga-rhzbii unchanged)"
eq "k1 sibling hold owns it: the VM is not asked" "$(vm_calls)" "0"
eq "k1 IS_VM_HOLD not set (the sibling hold owns it)" "${IS_VM_HOLD:-unset}" "0"

# (l) a hold label that could NOT be written is never claimed.
sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso na VM"; SC_LABEL_ADD_FAIL=1
run_region
was_closed && bad "l1 a failed label write released the bead to the close" || ok "l1 the label write FAILED → the bead is still NOT closed (never close on a failed hold)"
has "$(comments)" "could NOT be written" && ok "l1 the comment says the hold label could not be written" || bad "l1 comment does not say the label write failed: [$(comments)]"
! has "$(comments)" "Held as delivery:pending-vm" && ok "l1 the comment does not claim a hold the bead does not carry" || bad "l1 the comment claims delivery:pending-vm that was never written"
grep -qiE 'could not (add|write)' "$LOG_F" && ok "l1 the failed write is a WARN in the log" || bad "l1 silent label-write failure"
# (m) a hold-state dir that cannot be created: still holds, says the 24h ceiling cannot run.
sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_BREAK_STATE_DIR=1
run_region
was_closed && bad "m1 an unwritable hold state released the bead" || ok "m1 hold state unwritable → still NOT closed"
has "$(logtext)" "24h" && ok "m1 the WARN says the 24h Mayor-mail ceiling cannot run for it" || bad "m1 silent: [$(logtext)]"
! has "$(comments)" "ONE mail" && has "$(comments)" "NOT armed" \
  && ok "m1 the comment does not promise a Mayor mail it cannot send (it says the ceiling is NOT armed)" || bad "m1 the comment promises a Mayor mail with no hold state to drive it: [$(comments)]"

# ── 6. mutations: each re-creates ONE defect and must turn a scenario red ────
echo "── 6. mutations (each must flip its scenario) ──"
mutate() {  # $1=text $2=pattern $3=replacement ; prints the mutated text, returns 1 if nothing changed
  local out="${1//"$2"/$3}"
  [ "$out" != "$1" ] || return 1
  printf '%s' "$out"
}
# M1: delete the whole VM block. That IS the pre-fix code: the pending scenario must CLOSE the bead.
REGION_M1="$(printf '%s\n' "$REGION" | awk 'index($0,"SELFTEST-EXTRACT vm-hold-block: BEGIN"){s=1} !s{print} index($0,"SELFTEST-EXTRACT vm-hold-block: END"){s=0}')"
if [ "$REGION_M1" = "$REGION" ]; then
  bad "M1 did not apply (vm-hold-block markers missing) — the pre-fix reproduction is unproven"
else
  sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_region "$REGION_M1"
  was_closed && ok "M1 (VM block removed = the pre-fix code): the voicebot merge with a PENDING VM is CLOSED — the bug reproduces" || bad "M1: without the VM block the bead was still not closed — the scenarios cannot catch the bug"
fi
# M2: an unreadable status reads as ok.
sc_reset; SC_STATUS_RC=3; SC_STATUS_OUT="x"
if FN_M2="$(mutate "$FN_VM_CHECK" 'VM_HOLD_KIND="unknown"' 'VM_HOLD_KIND=""')"; then
  eval "$FN_M2"; run_region
  was_closed && ok "M2 (unknown treated as ok): an UNREADABLE status CLOSES the bead → the e/* scenarios go red" || bad "M2: treating unknown as ok changed nothing — e/* cannot catch it"
  eval "$FN_VM_CHECK"
else bad "M2 did not apply (the unknown arm changed?) — the unknown scenarios are unproven"; fi
# M3: ask the VM even when the delta does not touch it.
if FN_M3="$(mutate "$FN_VM_CHECK" '"$VM_DELTA_VERDICT" = "no"' '"$VM_DELTA_VERDICT" = "never"')"; then
  eval "$FN_M3"; sc_reset; SC_FILES="docs/x.md"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; run_region
  [ "$(vm_calls)" != "0" ] && ok "M3 (always ask): a docs-only merge consults the VM → c1 goes red" || bad "M3: dropping the does-not-touch gate still did not consult the VM"
  eval "$FN_VM_CHECK"
else bad "M3 did not apply (the does-not-touch gate changed?) — c1 is unproven"; fi
# M4: an ABSENT contract holds the bead instead of closing it.
if FN_M4="$(mutate "$FN_VM_CHECK" 'VM_HOLD_KIND="absent"' 'VM_HOLD_KIND="unknown"')"; then
  eval "$FN_M4"; sc_reset; SC_SCRIPT_PRESENT=0; run_region
  was_closed && bad "M4: absent→hold still closed — f1 cannot catch it" || ok "M4 (absent contract holds): the bead is NOT closed → f1 goes red"
  eval "$FN_VM_CHECK"
else bad "M4 did not apply (the absent arm changed?) — f1 is unproven"; fi
# M5: restore and prove the harness left the real code in place.
sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
run_region
was_closed && bad "after the mutations the real code CLOSES a pending-VM bead (harness did not restore)" || ok "after the mutations the real code holds again (harness restored)"

# ── 6b. the 24h ceiling: a hold nobody revisits still reaches the Mayor ───────
# The dispatcher never asks the VM again, so without this the Mayor's "a 24h ceiling that mails the
# Mayor" would only ever be a sentence in a comment. gate_vm_hold_ceiling_sweep reads the hold states
# the PASS path wrote, and for a bead still open past the threshold mails the Mayor ONCE. Three-state
# discipline again: "could not read the bead" is neither "closed" (drop the state) nor "still held"
# (mail) — it keeps the state and tries next sweep.
echo "── 6b. the 24h ceiling (gate_vm_hold_ceiling_sweep) ──"
CE_DIR="$WORK_DIR/ce/voicebot-vm-hold-gate"; CE_BD_F="$WORK_DIR/ce-bd"; CE_NOW=1900000000; CE_AFTER=86400
CE_SHOW=open_label; CE_MAIL_FAIL=0; CE_ID=ga-ceil-1
if [ -n "$FN_VM_CEIL" ]; then eval "$FN_VM_CEIL"; fi
bd() {   # the bead as bd show --json prints it; CE_SHOW picks the shape
  printf '%s\n' "$*" >> "$CE_BD_F"
  case "${3:-}" in
    show)
      case "$CE_SHOW" in
        open_label)   printf '[{"id":"%s","status":"open","labels":["gate:passed","delivery:pending-vm"]}]' "${4:-}" ;;
        open_nolabel) printf '[{"id":"%s","status":"open","labels":["gate:passed"]}]' "${4:-}" ;;
        inprog_label) printf '[{"id":"%s","status":"in_progress","labels":["delivery:pending-vm"]}]' "${4:-}" ;;
        closed)       printf '[{"id":"%s","status":"closed","labels":["gate:passed","delivery:pending-vm"]}]' "${4:-}" ;;
        wrongid)      printf '[{"id":"ga-some-other-bead","status":"open","labels":["delivery:pending-vm"]}]' ;;
        nostatus)     printf '[{"id":"%s","labels":["delivery:pending-vm"]}]' "${4:-}" ;;
        garbage)      printf 'not json at all' ;;
        fail)         printf '{"error":"no issues found matching the provided IDs"}\n'; echo "Error fetching ${4:-}" >&2; return 1 ;;
      esac ;;
  esac
  return 0
}
gc() { printf '%s\n----\n' "$*" >> "$GC_F"; if [ "$CE_MAIL_FAIL" = "1" ]; then return 1; fi; return 0; }
ce_reset() {
  rm -rf "$WORK_DIR/ce"; mkdir -p "$CE_DIR"; : > "$LOG_F"; : > "$GC_F"; : > "$CE_BD_F"
  GC_CITY="$WORK_DIR/ce/city"; mkdir -p "$GC_CITY"
  CE_SHOW=open_label; CE_MAIL_FAIL=0; CE_ID=ga-ceil-1; DRY_RUN=0
}
ce_state()  { voicebot_vm_state_put "$CE_DIR" "$CE_DIR/$1.state" "$2" "$3" "$4"; }   # id fp since mailed
ce_get()    { voicebot_vm_state_get "$CE_DIR/$CE_ID.state" "$1"; }
ce_sweep()  { gate_vm_hold_ceiling_sweep "$CE_DIR" "$CE_NOW" "${1:-$CE_AFTER}"; }
ce_mails()  { local n; n="$(grep -c 'mail send mayor' "$GC_F" 2>/dev/null || true)"; echo "${n:-0}"; }
ce_bd_calls() { local n; n="$(grep -c ' show ' "$CE_BD_F" 2>/dev/null || true)"; echo "${n:-0}"; }
ce_mail_text() { cat "$GC_F"; }
STORE_X="$WORK_DIR/ce/rig-store"

if ! type gate_vm_hold_ceiling_sweep >/dev/null 2>&1; then
  bad "gate_vm_hold_ceiling_sweep is not defined — a hold is never revisited, so the 24h Mayor mail can never be sent"
  gate_vm_hold_ceiling_sweep() { return 0; }
fi

# (c1) under the threshold: no bd call, no mail, state untouched.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER + 1)) 0
ce_sweep
eq "c1 a hold 1s under the threshold: no mail" "$(ce_mails)" "0"
eq "c1 ...and the bead is not even read (the sweep costs no bd call for a young hold)" "$(ce_bd_calls)" "0"
eq "c1 ...state still mailed=0" "$(ce_get mailed)" "0"
# (c2) at the threshold: exactly one mail, state claims it.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER)) 0
ce_sweep
eq "c2 a hold AT the threshold: exactly one Mayor mail" "$(ce_mails)" "1"
has "$(ce_mail_text)" "mail send mayor" && has "$(ce_mail_text)" "$CE_ID" && ok "c2 the mail goes to the mayor and names the bead" || bad "c2 mail: [$(ce_mail_text)]"
has "$(ce_mail_text)" "24h" && ok "c2 the subject says the hold is over 24h" || bad "c2 subject lacks 24h: [$(ce_mail_text)]"
has "$(ce_mail_text)" "$STORE_X" && ok "c2 the mail pins the store (bd -C <store>) so the Mayor reads the right one" || bad "c2 mail does not name the store"
has "$(ce_mail_text)" "label remove $CE_ID delivery:pending-vm" && ok "c2 the mail names the manual release" || bad "c2 mail has no release action"
has "$(ce_mail_text)" "NÃO reconsulta" && ok "c2 the mail says honestly that nothing re-asks the VM" || bad "c2 mail does not say there is no automatic re-query"
eq "c2 state: mailed=1" "$(ce_get mailed)" "1"
eq "c2 state: since is preserved" "$(ce_get since)" "$((CE_NOW - CE_AFTER))"
eq "c2 state: fp (kind|store) is preserved" "$(ce_get fp)" "pending|$STORE_X"
eq "c2 the bead was re-read exactly once (live, in its own store)" "$(ce_bd_calls)" "1"
has "$(cat "$CE_BD_F")" "-C $STORE_X show $CE_ID" && ok "c2 the read is pinned to the recorded store" || bad "c2 bd read: [$(cat "$CE_BD_F")]"
# (c3) the next sweep does not mail again, and does not even re-read a hold it looked at a moment ago.
ce_sweep
eq "c3 a second sweep: still exactly one mail (at-most-once)" "$(ce_mails)" "1"
eq "c3 ...and no further bd read inside the housekeeping window" "$(ce_bd_calls)" "1"
# (c4) the bead closed meanwhile: the state goes, the Mayor is not bothered.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=closed
ce_sweep
eq "c4 a CLOSED bead: no mail" "$(ce_mails)" "0"
[ ! -e "$CE_DIR/$CE_ID.state" ] && ok "c4 ...and its hold state is dropped (a later unrelated hold must not inherit this clock)" || bad "c4 hold state of a closed bead was kept"
# (c5-c8) could not READ the bead: neither closed nor held — keep the state, mail nothing, say so.
for _shape in fail wrongid garbage nostatus; do
  ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW="$_shape"
  ce_sweep
  eq "c5/$_shape an unreadable bead: no mail" "$(ce_mails)" "0"
  [ -e "$CE_DIR/$CE_ID.state" ] && eq "c5/$_shape ...state kept, still mailed=0 (retried next sweep)" "$(ce_get mailed)" "0" || bad "c5/$_shape the state was DROPPED on an unreadable bead (an error read as 'closed')"
  has "$(cat "$LOG_F")" "could not read" && ok "c5/$_shape ...and it is said in the log, not swallowed" || bad "c5/$_shape silent: [$(cat "$LOG_F")]"
done
# (c9) still open but the label is gone: the hold no longer holds — the mail says so.
ce_reset; ce_state "$CE_ID" "failed|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=open_nolabel
ce_sweep
eq "c9 open bead whose hold label is GONE: still one mail" "$(ce_mails)" "1"
has "$(ce_mail_text)" "AUSENTE" && ok "c9 the mail says the label is missing (nothing marks the hold any more)" || bad "c9 mail does not flag the missing label: [$(ce_mail_text)]"
has "$(ce_mail_text)" "failed" && ok "c9 the mail carries the hold kind from the state (failed)" || bad "c9 kind lost: [$(ce_mail_text)]"
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=open_label
ce_sweep
has "$(ce_mail_text)" "presente" && ok "c9b label present: the mail says so" || bad "c9b mail: [$(ce_mail_text)]"
# (c10) any status but closed still stands.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=inprog_label
ce_sweep
eq "c10 an in_progress bead is still held: one mail" "$(ce_mails)" "1"
# (c11) the mail transport fails: the claim is released so the next sweep retries.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_MAIL_FAIL=1
ce_sweep
eq "c11 mail send failed: state back to mailed=0 (retried next sweep)" "$(ce_get mailed)" "0"
has "$(cat "$LOG_F")" "Could not mail" && ok "c11 the failure is logged" || bad "c11 silent mail failure"
CE_MAIL_FAIL=0; ce_sweep
eq "c11 next sweep: the mail goes out" "$(ce_mails)" "2"
eq "c11 ...and the state is mailed=1 now" "$(ce_get mailed)" "1"
# (c12) the claim is written BEFORE the mail: if it cannot be written the sweep must not mail (it could not
# dedupe, and would re-mail every sweep).
if [ "$(id -u)" = "0" ]; then ok "c12 (skipped: running as root, a read-only file does not stop root)"
else
  ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; chmod 444 "$CE_DIR/$CE_ID.state"
  ce_sweep
  eq "c12 hold state not writable: NO mail (it could not be deduplicated)" "$(ce_mails)" "0"
  has "$(cat "$LOG_F")" "could not record" && ok "c12 ...and the log says why" || bad "c12 silent: [$(cat "$LOG_F")]"
  chmod 644 "$CE_DIR/$CE_ID.state"
fi
# (c13) DRY_RUN writes nothing and sends nothing.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; DRY_RUN=1
ce_sweep
eq "c13 DRY_RUN=1: no mail" "$(ce_mails)" "0"
eq "c13 DRY_RUN=1: state untouched (mailed=0)" "$(ce_get mailed)" "0"
has "$(cat "$LOG_F")" "WOULD" && ok "c13 DRY_RUN=1 says what it would do" || bad "c13 silent dry-run"
# (c14/c15) a state that cannot be interpreted is skipped loudly — never mailed, never deleted.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" "soon" 0
ce_sweep
eq "c14 non-numeric since: no mail" "$(ce_mails)" "0"
[ -e "$CE_DIR/$CE_ID.state" ] && ok "c14 ...state kept" || bad "c14 state deleted"
has "$(cat "$LOG_F")" "unusable" && ok "c14 ...and warned" || bad "c14 silent"
ce_reset; ce_state "$CE_ID" "pending" $((CE_NOW - CE_AFTER - 5)) 0
ce_sweep
eq "c15 no store in fp: no mail (the bead cannot be found)" "$(ce_mails)" "0"
[ -e "$CE_DIR/$CE_ID.state" ] && ok "c15 ...state kept" || bad "c15 state deleted"
eq "c15 ...and no guess at a store: no bd read" "$(ce_bd_calls)" "0"
# (c16) housekeeping of ALREADY-mailed holds: look at most once an hour, drop the state when the bead closed.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - 3 * CE_AFTER)) 1; CE_SHOW=closed
ce_sweep
eq "c16a mailed + state touched just now + closed bead: NOT re-read (the hourly throttle)" "$(ce_bd_calls)" "0"
[ -e "$CE_DIR/$CE_ID.state" ] && ok "c16a ...state kept for now" || bad "c16a state dropped without a look"
touch -t 202001010000 "$CE_DIR/$CE_ID.state"
ce_sweep
eq "c16b mailed + state not looked at for an hour + closed bead: no mail" "$(ce_mails)" "0"
[ ! -e "$CE_DIR/$CE_ID.state" ] && ok "c16b ...state dropped" || bad "c16b state of a closed bead kept"
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - 3 * CE_AFTER)) 1; touch -t 202001010000 "$CE_DIR/$CE_ID.state"; CE_SHOW=open_label
ce_sweep
eq "c16c mailed + still open: never a second mail" "$(ce_mails)" "0"
eq "c16c ...state kept, still mailed=1" "$(ce_get mailed)" "1"
ce_sweep
eq "c16c ...and the look is throttled (touched): the next sweep does not read again" "$(ce_bd_calls)" "1"
# (c17) several holds: only the due one mails; a missing directory is not an error.
ce_reset; ce_state ga-ceil-a "pending|$STORE_X" $((CE_NOW - CE_AFTER - 9)) 0; ce_state ga-ceil-b "pending|$STORE_X" $((CE_NOW - 60)) 0
ce_sweep
eq "c17 two holds, one past the threshold: one mail" "$(ce_mails)" "1"
has "$(ce_mail_text)" "ga-ceil-a" && ! has "$(ce_mail_text)" "ga-ceil-b" && ok "c17 ...for the right bead" || bad "c17 wrong bead mailed: [$(ce_mail_text)]"
rm -rf "$WORK_DIR/ce"; : > "$GC_F"; : > "$CE_BD_F"
gate_vm_hold_ceiling_sweep "$WORK_DIR/ce/does-not-exist" "$CE_NOW" "$CE_AFTER"; _rc=$?
eq "c17 no hold-state directory: returns 0, mails nothing, reads nothing" "$_rc/$(ce_mails)/$(ce_bd_calls)" "0/0/0"
# (c18) the threshold is a PARAMETER (the dispatcher feeds VOICEBOT_VM_PENDING_MAIL_AFTER_S in), not a constant.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - 61)) 0
ce_sweep 60
eq "c18 threshold 60s, hold 61s old: mailed" "$(ce_mails)" "1"
# (c19) a sweep never fails the dispatcher run, whatever it found.
ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=fail
ce_sweep; _rc=$?
eq "c19 an unreadable bead: the sweep still returns 0 (it must not abort the dispatcher under set -e)" "$_rc" "0"

# Wiring: a correct sweep nobody calls guards nothing — and it has to run on an EMPTY queue, which
# is the one case where Step 0b exits before anything else could.
_call_ln=$(grep -nE '^[[:space:]]*gate_vm_hold_ceiling_sweep "' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
# Anchored on the CODE (a `log` statement), not the bare phrase: a comment that quotes the message — the
# dispatcher's own call-site comment does — is not the exit, and matching it made this check lie.
_exit_ln=$(grep -nE '^[[:space:]]*log "No queued markers\. Exiting\."' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
_n_calls=$(grep -cE '^[[:space:]]*gate_vm_hold_ceiling_sweep "' "$DISPATCHER" || true)
eq "the dispatcher calls gate_vm_hold_ceiling_sweep exactly once" "$_n_calls" "1"
if [ -n "$_call_ln" ] && [ -n "$_exit_ln" ] && [ "$_call_ln" -lt "$_exit_ln" ]; then
  ok "the sweep runs BEFORE Step 0b's empty-queue exit (line $_call_ln < $_exit_ln): a held bead is mailed even when no marker is queued"
else
  bad "the ceiling sweep is not wired before the empty-queue exit (call=${_call_ln:-none}, exit=${_exit_ln:-none})"
fi
_call_txt=""; if [ -n "$_call_ln" ]; then _call_txt="$(sed -n "$((_call_ln > 4 ? _call_ln - 4 : 1)),$((_call_ln + 2))p" "$DISPATCHER")"; fi
has "$_call_txt" 'voicebot-vm-hold-gate' && ok "the call reads the gate's own hold-state directory (voicebot-vm-hold-gate)" || bad "the call does not pass voicebot-vm-hold-gate: [$_call_txt]"
has "$_call_txt" 'GATE_VM_CEILING_AFTER_S' && ok "the call passes the (validated) threshold" || bad "the call does not pass the threshold: [$_call_txt]"
grep -qF 'VOICEBOT_VM_PENDING_MAIL_AFTER_S' "$DISPATCHER" && ok "the threshold is the same knob the story side uses (VOICEBOT_VM_PENDING_MAIL_AFTER_S)" || bad "no VOICEBOT_VM_PENDING_MAIL_AFTER_S in the dispatcher"

# ── 6c. mutations of the sweep: each re-creates ONE defect and must turn its scenario red ──
# The 6b scenarios pass on the real sweep; this proves they would NOT pass on a broken one. Every mutant
# runs in a SUBSHELL (a mutant that trips set -u must not take this selftest down with it) and the
# scenario reports the defect through its exit code: 0 = the defect is observable = the test catches it.
echo "── 6c. mutations of the ceiling sweep (each must flip its scenario) ──"
ce_mutant() {  # $1=label $2=pattern $3=replacement $4=scenario function (run in a subshell; rc 0 = defect seen)
  local m
  if ! m="$(mutate "$FN_VM_CEIL" "$2" "$3")"; then
    bad "$1 did not apply (the sweep's text changed?) — its scenario is unproven"; return 0
  fi
  if ( eval "$m"; "$4" ) >/dev/null 2>&1; then
    ok "$1 → the scenario goes red (the defect is caught)"
  else
    bad "$1 → the scenario stayed green: the mutant is NOT caught"
  fi
}
# Each scenario: rc 0 when the DEFECT shows.
cm_closed()    { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=closed; ce_sweep
                 [ "$(ce_mails)" != "0" ] || [ -e "$CE_DIR/$CE_ID.state" ]; }
cm_mailed()    { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - 3 * CE_AFTER)) 1; touch -t 202001010000 "$CE_DIR/$CE_ID.state"; CE_SHOW=open_label; ce_sweep
                 [ "$(ce_mails)" != "0" ]; }
cm_throttle()  { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER)) 0; ce_sweep; ce_sweep
                 [ "$(ce_bd_calls)" != "1" ]; }
cm_unread_mail() { local _s _seen=1   # rc 0 when ANY unreadable shape got mailed about
                 for _s in fail wrongid garbage nostatus; do
                   ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW="$_s"; ce_sweep
                   if [ "$(ce_mails)" != "0" ]; then _seen=0; fi
                 done; return "$_seen"; }
cm_unread_drop() { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=fail; ce_sweep
                 [ ! -e "$CE_DIR/$CE_ID.state" ]; }
cm_claim()     { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; ce_sweep; ce_sweep
                 [ "$(ce_mails)" != "1" ]; }
cm_release()   { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_MAIL_FAIL=1; ce_sweep
                 [ "$(ce_get mailed)" != "0" ]; }
cm_threshold() { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER + 1)) 0; ce_sweep
                 [ "$(ce_mails)" != "0" ]; }
cm_dryrun()    { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; DRY_RUN=1; ce_sweep
                 [ "$(ce_mails)" != "0" ] || [ "$(ce_get mailed)" != "0" ]; }
cm_since()     { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" "soon" 0
                 ( ce_sweep ) || return 0          # the sweep itself aborted on the bad since: a defect
                 [ "$(ce_mails)" != "0" ]; }
cm_nostore()   { ce_reset; ce_state "$CE_ID" "pending" $((CE_NOW - CE_AFTER - 5)) 0; ce_sweep
                 [ "$(ce_bd_calls)" != "0" ] || [ "$(ce_mails)" != "0" ]; }
cm_nolabel()   { ce_reset; ce_state "$CE_ID" "pending|$STORE_X" $((CE_NOW - CE_AFTER - 5)) 0; CE_SHOW=open_nolabel; ce_sweep
                 ! has "$(ce_mail_text)" "AUSENTE"; }
# Baseline first: on the REAL sweep none of the scenarios may see its defect. A scenario already "red" on
# correct code would make every mutant look caught (and one inverted in the other direction, as CM4a's
# first draft was, makes every mutant look uncaught) — so this pins the scenarios themselves.
for _cm in cm_closed cm_mailed cm_throttle cm_unread_mail cm_unread_drop cm_claim cm_release cm_threshold cm_dryrun cm_since cm_nostore cm_nolabel; do
  if ( "$_cm" ) >/dev/null 2>&1; then bad "baseline: $_cm reports its defect on the REAL sweep (scenario is wrong, not the code)"
  else ok "baseline: $_cm sees no defect on the real sweep"; fi
done
ce_mutant "CM1 (a closed bead still mails and keeps its state)"  '[ "$status" = "closed" ]' '[ "$status" = "never" ]' cm_closed
ce_mutant "CM2 (a mailed hold is mailed again)"                  '[ "$mailed" = "1" ] && continue' ':' cm_mailed
ce_mutant "CM3 (no hourly throttle on the housekeeping read)"    '[ -z "$(find "$f" -mmin -60 2>/dev/null)" ] || continue' ':' cm_throttle
ce_mutant "CM4a (an unreadable bead is treated as still held)"   '[ "$_rc" -ne 0 ] || [ "$_jrc" -ne 0 ] || [ -z "$_row" ]' 'false' cm_unread_mail
ce_mutant "CM4b (an unreadable bead is treated as closed)"       'warn "ga-wye9vt: could not read $id' 'rm -f "$f"; warn "ga-wye9vt: could not read $id' cm_unread_drop
ce_mutant "CM5 (the claim is not really written: re-mailed every sweep)" 'if ! voicebot_vm_state_put "$dir" "$f" "$fp" "$since" 1; then' 'if ! true; then' cm_claim
ce_mutant "CM6 (a failed mail keeps its claim: the escalation is lost)" '"$fp" "$since" 0' '"$fp" "$since" 1' cm_release
ce_mutant "CM7 (the threshold is ignored)"                       '-ge "$after"' '-ge 0' cm_threshold
ce_mutant "CM8 (DRY_RUN is ignored)"                             '[ "${DRY_RUN:-0}" = "1" ]' '[ "${DRY_RUN:-0}" = "never" ]' cm_dryrun
ce_mutant "CM9 (a non-numeric since is not rejected)"            "''|*[!0-9]*)" "'')" cm_since
ce_mutant "CM10 (a state with no store is not rejected)"         '*\|?*) : ;;' '*) : ;;' cm_nostore
ce_mutant "CM11 (the mail no longer says the label is gone)"     'AUSENTE' 'presente' cm_nolabel
# Restore and prove the harness left the real sweep in place (the mutants ran in subshells, but say so).
eval "$FN_VM_CEIL"
cm_closed && bad "after the sweep mutations the real sweep mails for a closed bead" || ok "after the sweep mutations the real sweep behaves again (harness restored)"

# ── 7. the dispatcher's COPY of the helpers is the story-side original ───────
echo "── 7. parity with story-delivery.sh (the scripts are self-contained, so the copy is pinned) ──"
fn_body() {  # $1=file $2=function name → its definition, `name() {` through the closing `}`
  awk -v n="$2" 'index($0, n "() {")==1{f=1} f{print} f&&/^}/{exit}' "$1"
}
for _f in voicebot_vm_delta_touched voicebot_vm_status voicebot_vm_state_put voicebot_vm_state_get; do
  _a="$(fn_body "$STORY_DELIVERY" "$_f")"; _b="$(fn_body "$DISPATCHER" "$_f")"
  if [ -z "$_a" ]; then bad "parity/$_f: not found in story-delivery.sh (renamed?)"
  elif [ -z "$_b" ]; then bad "parity/$_f: the dispatcher has no copy"
  elif [ "$_a" = "$_b" ]; then ok "parity/$_f: the dispatcher's copy is identical to story-delivery.sh's ($(printf '%s\n' "$_a" | wc -l | tr -d ' ') lines)"
  else bad "parity/$_f: the copy DRIFTED from story-delivery.sh — fix both, or extract a shared lib"; fi
done

rm -rf "$WORK_DIR"
trap - EXIT

# ── 8. syntax ────────────────────────────────────────────────────────────────
# /bin/bash (3.2), NOT the PATH bash: the dispatcher is launched by 3.2 in production.
echo "── 8. syntax (/bin/bash -n) ──"
if /bin/bash -n "$DISPATCHER"; then ok "dispatcher passes /bin/bash -n"; else bad "dispatcher /bin/bash -n FAILED"; fi
if /bin/bash -n "${BASH_SOURCE[0]}"; then ok "this selftest passes /bin/bash -n"; else bad "selftest /bin/bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
