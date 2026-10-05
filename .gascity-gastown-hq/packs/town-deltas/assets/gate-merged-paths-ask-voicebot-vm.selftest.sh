#!/usr/bin/env bash
# gate-merged-paths-ask-voicebot-vm.selftest.sh (ga-buac0o, follow-up of ga-wye9vt)
#
# THE BUG: ga-wye9vt made the PASS path ask the dialer VM before it closes a bug/task source bead.
# Two other paths close a non-story source bead as "already merged" WITHOUT a merge of their own, and
# never asked:
#   Step 0a-4 (ga-88sl7)   a stranded needs-rebase marker whose branch is already an ancestor of main
#   Step 4b   (ga-jhyu)    the "superseded" short-circuit (ALREADY_MERGED=1), by ancestry or by patch-id
# A bug/task that touches the voicebot closed there with the VM still on old code — the 04/10
# wa-kj0x2h class, one path over. How often it happened is NOT measured here (ga-buac0o was filed
# unmeasured; ga-wye9vt measured 12 of 21 closes on the PASS path only).
#
# THE FIX under test: both paths ask `voicebot_vm_sync.py --status` through the SAME gate_vm_hold_check
# the PASS path uses, and HOLD (delivery:pending-vm + gate:passed + the hold state the 24h ceiling
# reads) instead of closing unless the VM is PROVEN current or the delta does not reach it. There is
# no merge of its own here, so the delta is the marker's base_commit .. origin/<branch>. NOT
# merge-base(branch, main): for an already-merged branch that is the branch tip itself, the range is
# empty, and an empty range reads as "does not touch" — the error-vs-empty collapse.
#
# WHAT THIS RUNS: the REAL source-bead regions of both paths (SELFTEST-EXTRACT needs-rebase-reap-
# source-bead-fn / already-merged-source-bead-cleanup-fn) and the real helpers, verbatim, against a
# mocked `bd`, a stub for the contract script (no ssh / VM / network) and a throw-away git repo. The
# observable is the bug's literal symptom: whether `bd close` is called on the bead. Every scenario
# runs through BOTH paths. Section 6 mutates the extracted code and requires the matching scenario to
# go red.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo "FATAL: timeout(1) not on PATH — the dispatcher's VM check needs it" >&2; exit 2; }

echo "== gate-merged-paths-ask-voicebot-vm.selftest (ga-buac0o) =="

# ── 1. extract the real pieces VERBATIM from the live dispatcher ─────────────
echo "── 1. extract the real already-merged regions and their helpers ──"
extract() {  # $1 = marker name
  awk -v b="SELFTEST-EXTRACT $1: BEGIN" -v e="SELFTEST-EXTRACT $1: END" \
    'index($0,b){f=1;next} index($0,e){f=0} f' "$DISPATCHER"
}
REG_0A4="$(extract needs-rebase-reap-source-bead-fn)"
REG_4B="$(extract already-merged-source-bead-cleanup-fn)"
FN_OWN="$(extract own-hold-check-fn)"
FN_CLOSE="$(extract gate-close-source-terminal-fn)"
FN_RELEASE="$(extract gate-release-stale-assignee-fn)"
FN_VSA="$(extract vb-status-action-fn)"
FN_VM_HELPERS="$(extract vm-helpers)"
FN_VM_CHECK="$(extract vm-hold-check-fn)"
FN_VM_CEIL="$(extract vm-hold-ceiling-fn)"
for _n in REG_0A4 REG_4B FN_OWN FN_CLOSE FN_RELEASE FN_VSA FN_VM_HELPERS FN_VM_CHECK FN_VM_CEIL; do
  [ -n "${!_n}" ] || { echo "FATAL: could not extract $_n — SELFTEST-EXTRACT markers moved?" >&2; exit 2; }
  ok "extracted $_n ($(printf '%s\n' "${!_n}" | wc -l | tr -d ' ') lines)"
done
# The piece this bead ADDS. Missing = a FAILED assertion, not a fatal error: the scenarios below must
# run — and fail by BEHAVIOUR — against a dispatcher without it.
FN_MERGED="$(extract merged-path-vm-hold-fn)"
if [ -n "$FN_MERGED" ]; then ok "extracted FN_MERGED ($(printf '%s\n' "$FN_MERGED" | wc -l | tr -d ' ') lines)"
else bad "could not extract FN_MERGED — the dispatcher has no merged-path-vm-hold-fn region"; fi

# Static guards: both paths go through ONE gate, ahead of their non-story close; the PASS-path comment
# that deferred this work is gone.
for _p in REG_0A4 REG_4B; do
  _code=$(printf '%s\n' "${!_p}" | grep -v '^[[:space:]]*#' || true)  # a comment naming the gate is not a call
  _n_call=$(printf '%s\n' "$_code" | grep -c 'gate_merged_path_vm_gate ' || true)
  eq "$_p calls gate_merged_path_vm_gate exactly once" "$_n_call" "1"
  _pos_gate=$(printf '%s\n' "$_code" | grep -n 'gate_merged_path_vm_gate ' | head -1 | cut -d: -f1 || true)
  _pos_close=$(printf '%s\n' "$_code" | grep -n 'gate_close_source_terminal "\$BEAD_ID" "Branch' | head -1 | cut -d: -f1 || true)
  if [ -n "$_pos_gate" ] && [ -n "$_pos_close" ] && [ "$_pos_gate" -lt "$_pos_close" ]; then
    ok "$_p asks the VM gate (line $_pos_gate) BEFORE the non-story close (line $_pos_close)"
  else
    bad "$_p does not order the VM gate (${_pos_gate:-none}) before the non-story close (${_pos_close:-none})"
  fi
done
if grep -q 'tracked as ga-buac0o' "$DISPATCHER"; then
  bad "the PASS-path comment still says the already-merged short-circuits are 'tracked as ga-buac0o' — they are covered now"
else
  ok "the PASS-path comment no longer defers the already-merged short-circuits to ga-buac0o"
fi

# ── 2. harness: mocked bd/gc, real helpers, stub contract script, throw-away repo ──
WORK_DIR="$(mktemp -d)"
cleanup() { command -v safe-clean >/dev/null 2>&1 && safe-clean "$WORK_DIR" >/dev/null 2>&1 || rm -rf "$WORK_DIR"; }
trap cleanup EXIT
ERR_F="$WORK_DIR/stderr"; LOG_F="$WORK_DIR/log"; COMMENT_F="$WORK_DIR/comments"
LABEL_F="$WORK_DIR/labels"; CLOSE_F="$WORK_DIR/closes"; GC_F="$WORK_DIR/gc"
STUB_CALLS="$WORK_DIR/vm-calls"; SHOW_N_F="$WORK_DIR/show-n"

FX=ga-buac0o-fx
VB="lib/predictive_dialer/voicebot"

sc_reset() {
  SC_FILES="$VB/capture_policy.py"   # files the branch's own delta changes
  SC_STATUS_RC=0
  SC_STATUS_OUT="STATUS: em dia — md5 igual na VM"
  SC_STATUS_ERR=""
  SC_STATUS_SLEEP=0
  SC_TIMEOUT_S=20
  SC_SCRIPT_PRESENT=1                # voicebot_vm_sync.py exists in the checkout
  SC_BASE=c0                         # marker base_commit: c0 | empty | unknown | tip | bogus | side
  SC_CLOSURE_PRESENT=1
  SC_CLOSURE_OUT="pipedrive_field_ids"
  SC_SHOW_LABELS='["lane:small"]'
  SC_SHOW_FAIL_FROM=0                # >0: every `bd show` from this call on fails (counted per run)
  SC_LABEL_ADD_FAIL=0
  SC_RT_MODE=repo                    # repo | city | empty | unmapped | unreadable
  SC_BREAK_STATE_DIR=0
  SC_PRESEED_SINCE=""                # an earlier hold's clock
}

bd() {
  local n
  case "${3:-}" in
    show)
      n=$(( $(cat "$SHOW_N_F" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SHOW_N_F"
      if [ "$SC_SHOW_FAIL_FROM" -gt 0 ] && [ "$n" -ge "$SC_SHOW_FAIL_FROM" ]; then echo "dolt hiccup" >&2; return 1; fi
      printf '[{"id":"%s","status":"open","labels":%s}]' "$FX" "$SC_SHOW_LABELS" ;;
    close)   printf 'CLOSED:%s|%s\n' "${4:-}" "${6:-}" >> "$CLOSE_F" ;;
    comment) printf '%s\n----\n' "${5:-}" >> "$COMMENT_F" ;;
    label)   printf '%s\n' "$*" >> "$LABEL_F"
             if [ "$SC_LABEL_ADD_FAIL" = "1" ] && [ "${4:-}" = "add" ]; then return 1; fi ;;
  esac
  return 0
}
gc()   { printf '%s\n' "$*" >> "$GC_F"; return 0; }
log()  { printf '%s\n' "$*" >> "$LOG_F"; }
warn() { printf '%s\n' "$*" >> "$LOG_F"; }
gate_finalize_pass_label_hygiene() { return 0; }
git_rig() { git -C "$RIG_REPO" "$@"; }
rig_resolve_commit() { git_rig rev-parse --verify -q "$1^{commit}" 2>/dev/null || echo ""; }
eval "$FN_OWN"
eval "$FN_CLOSE"
eval "$FN_RELEASE"
eval "$FN_VSA"
eval "$FN_VM_HELPERS"
eval "$FN_VM_CHECK"
eval "$FN_VM_CEIL"
eval "$FN_MERGED"

# mk_repo — a runtime checkout (which is also the rig's repo, as for WA) with a C0 base and a C1
# branch commit that changes SC_FILES. origin/main AND origin/fix/<FX> are both C1: the branch is
# ALREADY MERGED, so merge-base(branch, main) == the branch tip and that range is empty.
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
  git -C "$R" add -A; git -C "$R" commit -q -m C0
  SHA_C0="$(git -C "$R" rev-parse HEAD)"
  for f in $SC_FILES; do mkdir -p "$R/$(dirname "$f")"; echo "x = 1" >> "$R/$f"; done
  git -C "$R" add -A; git -C "$R" commit -q -m C1
  SHA_C1="$(git -C "$R" rev-parse HEAD)"
  SHA_SIDE="$(git -C "$R" commit-tree "$SHA_C0^{tree}" -p "$SHA_C0" -m side)"
  git -C "$R" update-ref refs/remotes/origin/main "$SHA_C1"
  git -C "$R" update-ref "refs/remotes/origin/fix/$FX" "$SHA_C1"
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

# run_path <0a4|4b> [region-text] — one run of the real region. KEEP_T=1 keeps the sandbox for the caller.
run_path() {
  local path="$1" region T
  case "$path" in 0a4) region="$REG_0A4" ;; 4b) region="$REG_4B" ;; esac
  region="${2:-$region}"
  T="$(mktemp -d "$WORK_DIR/run.XXXXXX")"
  : > "$ERR_F"; : > "$LOG_F"; : > "$COMMENT_F"; : > "$LABEL_F"; : > "$CLOSE_F"; : > "$GC_F"; : > "$STUB_CALLS"; rm -f "$SHOW_N_F"
  mk_repo "$T/runtime"
  GC_CITY="$T/city"; mkdir -p "$GC_CITY/.gc/runtime" "$GC_CITY/packs/town-deltas/assets"
  RIG_REPO="$T/runtime"
  case "$SC_RT_MODE" in
    repo)       printf '[[rig]]\nname = "whatsapp_automation"\nruntime_dir = "%s"\n' "$T/runtime" > "$GC_CITY/packs/town-deltas/assets/delivery-runbooks.toml" ;;
    city)       printf '[[rig]]\nname = "whatsapp_automation"\nruntime_dir = "%s"\n' "$GC_CITY" > "$GC_CITY/packs/town-deltas/assets/delivery-runbooks.toml" ;;
    empty)      printf '[[rig]]\nname = "whatsapp_automation"\ndeploy_cmd = "true"\n' > "$GC_CITY/packs/town-deltas/assets/delivery-runbooks.toml" ;;
    unmapped)   printf '[[rig]]\nname = "somebody_else"\nruntime_dir = "%s"\n' "$T/runtime" > "$GC_CITY/packs/town-deltas/assets/delivery-runbooks.toml" ;;
    unreadable) : ;;
  esac
  if [ "$SC_BREAK_STATE_DIR" = "1" ]; then : > "$GC_CITY/.gc/runtime/voicebot-vm-hold-gate"; fi
  if [ -n "$SC_PRESEED_SINCE" ]; then
    mkdir -p "$GC_CITY/.gc/runtime/voicebot-vm-hold-gate"
    printf 'fp=%s\nsince=%s\nmailed=%s\n' "pending|$GC_CITY" "$SC_PRESEED_SINCE" 0 > "$GC_CITY/.gc/runtime/voicebot-vm-hold-gate/$FX.state"
  fi
  export STUB_CALLS STUB_RC="$SC_STATUS_RC" STUB_OUT="$SC_STATUS_OUT" STUB_ERR="$SC_STATUS_ERR" STUB_SLEEP="$SC_STATUS_SLEEP"
  export VOICEBOT_VM_STATUS_TIMEOUT_S="$SC_TIMEOUT_S" STUB_CLOSURE_OUT="$SC_CLOSURE_OUT"
  unset VOICEBOT_VM_SYNC_SCRIPT
  BEAD_CITY="$GC_CITY"; BEAD_ID="$FX"; RIG=whatsapp_automation; DEFAULT_BRANCH=main
  BRANCH="fix/$FX"; MARKER_ID=marker-1; NR_BRANCH="$BRANCH"; NR_MARKER_ID="$MARKER_ID"
  case "$SC_BASE" in
    c0)      BASE_COMMIT="$SHA_C0" ;;
    empty)   BASE_COMMIT="" ;;
    unknown) BASE_COMMIT="unknown" ;;
    tip)     BASE_COMMIT="$SHA_C1" ;;
    bogus)   BASE_COMMIT="0123456789abcdef0123456789abcdef01234567" ;;
    side)    BASE_COMMIT="$SHA_SIDE" ;;
  esac
  NR_BASE_COMMIT="$BASE_COMMIT"
  eval "$region" 2>"$ERR_F"
  STATE_FILE="$GC_CITY/.gc/runtime/voicebot-vm-hold-gate/$FX.state"
  STATE_AFTER="$(cat "$STATE_FILE" 2>/dev/null || echo '<none>')"
  if [ "${KEEP_T:-0}" = "1" ]; then T_LAST="$T"; else cleanup_run "$T"; fi
}
cleanup_run() { command -v safe-clean >/dev/null 2>&1 && safe-clean "$1" >/dev/null 2>&1 || rm -rf "$1"; }

was_closed()   { grep -qF "CLOSED:$FX|" "$CLOSE_F"; }
close_reason() { sed -n "s/^CLOSED:$FX|//p" "$CLOSE_F" | head -1; }
pend_label()   { grep -qF "label add $FX delivery:pending-vm" "$LABEL_F"; }
passed_label() { grep -qF "label add $FX gate:passed" "$LABEL_F"; }
super_label()  { grep -qF "label add $FX gate:superseded" "$LABEL_F"; }
vm_calls()     { local n; n="$(grep -c -- '--status' "$STUB_CALLS" 2>/dev/null || true)"; echo "${n:-0}"; }
comments()     { cat "$COMMENT_F"; }
logtext()      { cat "$LOG_F"; }
NOT_UNKNOWN_WORDS='não consegui ler o status da VM'

# assert_hold <tag>: the bead is held, not closed, with every surface the PASS-path hold has.
assert_hold() {
  local t="$1"
  was_closed && bad "$t BUG: the already-merged path CLOSED the bead (ga-buac0o)" || ok "$t the bead is NOT closed"
  pend_label && ok "$t delivery:pending-vm written (the janitor keep-guard + the ceiling sweep key on it)" || bad "$t no delivery:pending-vm label: [$(cat "$LABEL_F")]"
  passed_label && ok "$t gate:passed written (the Pilot excludes it from re-dispatch)" || bad "$t no gate:passed label: [$(cat "$LABEL_F")]"
  super_label && bad "$t gate:superseded written on a bead that is HELD, not delivered" || ok "$t no gate:superseded on a held bead"
  has "$(comments)" "NOT closing (ga-buac0o)" && ok "$t the comment says it is not closing, citing ga-buac0o" || bad "$t comment lacks 'NOT closing (ga-buac0o)': [$(comments)]"
  has "$(comments)" "No automatic re-query" && ok "$t the comment says honestly there is no automatic re-query" || bad "$t the comment does not say there is no automatic re-query"
  has "$(comments)" "label remove $FX delivery:pending-vm" && has "$(comments)" "bd -C " \
    && ok "$t the comment names the manual release, pinning the store" || bad "$t no pinned manual-release action in the comment"
  has "$(comments)" "ONE mail" && has "$(comments)" "VOICEBOT_VM_PENDING_MAIL_AFTER_S" \
    && ok "$t the comment says when the Mayor is mailed, and which knob sets it" || bad "$t the comment does not describe the 24h ceiling"
  ! grep -qE 'Re-checked every|closes automatically|will close (it|this bead) (for you|automatically)' "$COMMENT_F" "$LOG_F" \
    && ok "$t no false promise of an automatic retry/close" || bad "$t a surface promises an automatic retry/close that nothing implements"
  has "$(logtext)" "holding, NOT closing (ga-buac0o)" && ok "$t the dispatcher log records the hold" || bad "$t no log line for the hold: [$(logtext)]"
  has "$STATE_AFTER" "since=" && has "$STATE_AFTER" "mailed=0" && has "$STATE_AFTER" "|$GC_CITY" \
    && ok "$t the hold state (<kind>|<store>, since, mailed=0) is written for the 24h ceiling" || bad "$t no usable hold state: [$STATE_AFTER]"
}
assert_closed() {  # <tag>
  was_closed && ok "$1 the bead is CLOSED as before" || bad "$1 the bead was not closed (held or stuck): comments=[$(comments)] log=[$(logtext)]"
  pend_label && bad "$1 a delivery:pending-vm label was written for a bead that closed" || ok "$1 no pending-vm label on a close"
}

scenarios() {  # <0a4|4b>
  local P="$1" _case _name _rest _rc _out _wait

  # (a) touches + exit 10 → HOLD.
  echo "── 3/$P. touches the voicebot: ask the VM; only 'em dia' closes ──"
  sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso na VM"
  run_path "$P"
  assert_hold "a1/$P touches + --status=10"
  has "$(comments)" "ligação em curso na VM" && ok "a1/$P the comment carries the script's own reason" || bad "a1/$P the --status reason is missing from the comment"
  has "$(comments)" "TOUCHES what runs on the dialer VM" && has "$(comments)" "Held as delivery:pending-vm" \
    && ok "a1/$P the comment states the verdict it holds on (TOUCHES) and that the label IS on the bead" || bad "a1/$P comment lacks TOUCHES / 'Held as delivery:pending-vm': [$(comments)]"
  has "$STATE_AFTER" "fp=pending|" && ok "a1/$P the hold state records the kind AND the bead's store" || bad "a1/$P hold state lacks <kind>|<store>: [$STATE_AFTER]"
  eq "a1/$P the contract script is asked exactly once, with --status" "$(vm_calls)" "1"
  grep -q 'gate:reviewing' "$LABEL_F" && ok "a1/$P gate:reviewing is cleared on hold" || bad "a1/$P gate:reviewing not cleared on hold"

  # (b) exit 0 + the em-dia line → close as before.
  sc_reset
  run_path "$P"
  assert_closed "b1/$P touches + em dia"
  eq "b1/$P the contract script was asked once" "$(vm_calls)" "1"
  super_label && ok "b1/$P gate:superseded is written as before" || bad "b1/$P gate:superseded no longer written on the close"
  has "$(close_reason)" "already merged" && ok "b1/$P the close reason is the old one (already merged)" || bad "b1/$P close reason: [$(close_reason)]"
  ! has "$(close_reason)" "NÃO verificada" && ok "b1/$P an em-dia close does not claim the VM was unverified" || bad "b1/$P em-dia close says the VM was unverified"

  # (c) does NOT touch → close, never asks.
  sc_reset; SC_FILES="docs/x.md"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_path "$P"
  assert_closed "c1/$P docs-only delta"
  eq "c1/$P the contract script is NOT consulted for a delta that does not touch the VM" "$(vm_calls)" "0"
  sc_reset; SC_FILES="lib/unrelated.py"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_path "$P"
  assert_closed "c2/$P lib/ file outside the voicebot closure"
  eq "c2/$P not consulted" "$(vm_calls)" "0"
  sc_reset; SC_FILES="lib/pipedrive_field_ids.py"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — ligação em curso"
  run_path "$P"
  assert_hold "c4/$P lib/ module IN the voicebot closure + VM pending"
  has "$(comments)" "TOUCHES what runs" && ok "c4/$P proven by the closure: worded as the flat 'TOUCHES'" || bad "c4/$P wording: [$(comments)]"
  sc_reset; SC_FILES="lib/unrelated.py"; SC_CLOSURE_PRESENT=0; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_path "$P"
  assert_hold "c5/$P lib/ change with NO closure script to ask → delta UNKNOWN"
  has "$(comments)" "MAY touch what runs" && ok "c5/$P worded as 'MAY touch' (a hedge)" || bad "c5/$P wording: [$(comments)]"

  # (d) exit 20 → HOLD with the reason.
  sc_reset; SC_STATUS_RC=20; SC_STATUS_OUT="STATUS: falhou — md5 diferente em 3 arquivos"
  run_path "$P"
  assert_hold "d1/$P touches + --status=20"
  has "$(comments)" "md5 diferente em 3 arquivos" && ok "d1/$P the failed reason is in the comment" || bad "d1/$P the failed reason is missing from the comment"
  has "$STATE_AFTER" "fp=failed|" && ok "d1/$P the state kind is 'failed'" || bad "d1/$P state: [$STATE_AFTER]"

  # (e) every way of NOT KNOWING holds. "unknown" is never "em dia".
  for _case in "exit3:3:STATUS: whatever" "exit1:1:" "exit2:2:uso errado" "timeout:0:STATUS: em dia" "uncorroborated:0:tudo certo"; do
    _name="${_case%%:*}"; _rest="${_case#*:}"; _rc="${_rest%%:*}"; _out="${_rest#*:}"
    sc_reset; SC_STATUS_RC="$_rc"; SC_STATUS_OUT="$_out"
    if [ "$_name" = timeout ]; then SC_STATUS_SLEEP=5; SC_TIMEOUT_S=1; fi
    run_path "$P"
    assert_hold "e/$_name/$P unreadable status"
    has "$(comments)" "$NOT_UNKNOWN_WORDS" && ok "e/$_name/$P the comment says the status could not be read" || bad "e/$_name/$P comment does not say the read failed: [$(comments)]"
    ! has "$(comments)" "STATUS: pendente" && ok "e/$_name/$P an unknown is not worded as 'pendente'" || bad "e/$_name/$P unknown worded as pendente"
  done

  # (f) contract ABSENT → close as today, and SAY the VM was not verified.
  echo "── 4/$P. contract absent / delta unreadable / not applicable ──"
  sc_reset; SC_SCRIPT_PRESENT=0
  run_path "$P"
  assert_closed "f1/$P script absent (wa-y0su67 not in main)"
  has "$(comments)" "VM não verificada: contrato ausente" && ok "f1/$P the comment says 'VM não verificada: contrato ausente'" || bad "f1/$P no 'contrato ausente' comment: [$(comments)]"
  has "$(close_reason)" "NÃO verificada" && ok "f1/$P the close reason says the VM was NOT verified" || bad "f1/$P close reason does not say so: [$(close_reason)]"
  sc_reset; SC_SCRIPT_PRESENT=0; SC_FILES="docs/x.md"
  run_path "$P"
  assert_closed "f2/$P script absent + delta does not touch the VM"
  ! has "$(comments)" "contrato ausente" && ok "f2/$P no 'contrato ausente' noise when the delta does not reach the VM" || bad "f2/$P 'contrato ausente' on a delta that does not touch the VM"

  # (g) delta UNREADABLE in a rig that HAS the package → unknown → ask, never "no".
  for _case in empty unknown bogus side tip; do
    sc_reset; SC_BASE="$_case"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente — deploy na fila"
    run_path "$P"
    assert_hold "g1/$_case/$P base_commit=$_case, VM pending"
    eq "g1/$_case/$P the VM was asked" "$(vm_calls)" "1"
    has "$(comments)" "MAY touch what runs on the dialer VM" && ! has "$(comments)" "TOUCHES what runs" \
      && ok "g1/$_case/$P worded as 'MAY touch' (a hedge), never the flat claim" || bad "g1/$_case/$P unknown delta worded as a flat TOUCHES: [$(comments)]"
    sc_reset; SC_BASE="$_case"
    run_path "$P"
    assert_closed "g2/$_case/$P base_commit=$_case + VM em dia (the VM answered)"
  done

  # (h) the rig has nothing to ask: no runtime_dir / runtime_dir == GC_CITY / registry unreadable.
  for _case in empty unmapped; do
    sc_reset; SC_RT_MODE="$_case"; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
    run_path "$P"
    assert_closed "h1/$_case/$P rig with no runtime_dir mapping"
    eq "h1/$_case/$P no VM to ask" "$(vm_calls)" "0"
    has "$(logtext)" "no runtime_dir mapping" && ok "h1/$_case/$P the log says why the VM check was skipped" || bad "h1/$_case/$P no skip reason logged: [$(logtext)]"
  done
  sc_reset; SC_RT_MODE=city; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_path "$P"
  assert_closed "h2/$P framework self-fix (runtime_dir == GC_CITY)"
  eq "h2/$P not consulted" "$(vm_calls)" "0"
  has "$(logtext)" "not applicable" && ok "h2/$P the log says the check is not applicable" || bad "h2/$P no 'not applicable' logged: [$(logtext)]"
  sc_reset; SC_RT_MODE=unreadable; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_path "$P"
  assert_closed "h3/$P the runbook registry is UNREADABLE"
  eq "h3/$P nothing to ask without a runtime_dir" "$(vm_calls)" "0"
  has "$(close_reason)" "NÃO verificada" && ok "h3/$P the close reason says the VM was NOT verified (a read failure is not 'no mapping')" || bad "h3/$P close reason: [$(close_reason)]"
  has "$(logtext)" "delivery-runbooks.toml" && ok "h3/$P the dispatcher log names the unreadable registry" || bad "h3/$P log does not name the registry: [$(logtext)]"

  # (i) a bead that ALREADY wears delivery:pending-vm is never closed over by this branch's delta.
  echo "── 5/$P. an existing hold / the hold's own bookkeeping ──"
  sc_reset; SC_FILES="docs/x.md"; SC_SHOW_LABELS='["gate:passed","delivery:pending-vm"]'
  run_path "$P"
  assert_hold "i1/$P bead already held on delivery:pending-vm, this delta does not touch the VM"
  eq "i1/$P the VM is not re-asked for a bead that is already held" "$(vm_calls)" "0"
  has "$(comments)" "already wears delivery:pending-vm" && ok "i1/$P the comment says WHY (an earlier hold stands)" || bad "i1/$P comment does not explain: [$(comments)]"
  sc_reset; SC_FILES="docs/x.md"
  if [ "$P" = 0a4 ]; then SC_SHOW_FAIL_FROM=2; else SC_SHOW_FAIL_FROM=3; fi
  run_path "$P"
  assert_hold "i2/$P the bead's labels cannot be read (unknown is not 'no hold')"
  eq "i2/$P no VM call on an unreadable bead" "$(vm_calls)" "0"

  # (j) a story is untouched: hand-off to story-delivery (which asks the VM itself, Step 6a).
  sc_reset; SC_SHOW_LABELS='["story:approved"]'; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  run_path "$P"
  was_closed && bad "j1/$P a STORY was closed by the already-merged path" || ok "j1/$P a story is not closed here"
  passed_label && ok "j1/$P story hand-off: gate:passed set as before" || bad "j1/$P no gate:passed on the story hand-off"
  eq "j1/$P the dispatcher does not ask the VM for a story (story-delivery does)" "$(vm_calls)" "0"
  pend_label && bad "j1/$P a story got delivery:pending-vm from this path" || ok "j1/$P no pending-vm on a story"

  # (k) a label that could not be written is never claimed.
  sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_LABEL_ADD_FAIL=1
  run_path "$P"
  was_closed && bad "k1/$P a failed label write released the bead to a close" || ok "k1/$P label write failed → still NOT closed"
  has "$(comments)" "could NOT be written" && ok "k1/$P the comment says the hold label could not be written" || bad "k1/$P the comment claims a label that is not there: [$(comments)]"
  ! has "$(comments)" "Held as delivery:pending-vm" && ok "k1/$P no false 'Held as delivery:pending-vm'" || bad "k1/$P false 'Held as' claim"

  # (l) an earlier hold's clock is kept; (m) a state that cannot be written is said, not hidden.
  sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_PRESEED_SINCE=1000
  run_path "$P"
  ! was_closed && has "$STATE_AFTER" "since=1000" && ok "l1/$P a hold is placed and an earlier hold's clock (since) is kept, not restarted" || bad "l1/$P no hold, or since was restarted (closed=$(was_closed && echo yes || echo no)): [$STATE_AFTER]"
  sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_BREAK_STATE_DIR=1
  run_path "$P"
  was_closed && bad "m1/$P an unwritable hold state released the bead to a close" || ok "m1/$P hold state unwritable → still NOT closed"
  has "$(comments)" "NOT armed" && ok "m1/$P the comment says the 24h ceiling is not armed" || bad "m1/$P the comment hides that the ceiling is not armed: [$(comments)]"

  # (n) the 24h ceiling covers what this path wrote: ONE mail, never a second.
  sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"
  KEEP_T=1 run_path "$P"
  local _dir="$GC_CITY/.gc/runtime/voicebot-vm-hold-gate" _since="" _gcl
  [ ! -f "$_dir/$FX.state" ] || _since="$(sed -n 's/^since=//p' "$_dir/$FX.state" | head -1)"
  case "$_since" in
    ''|*[!0-9]*) bad "n1/$P no hold state for the ceiling sweep to read (since='$_since') — nothing was held" ;;
    *)
      : > "$GC_F"
      gate_vm_hold_ceiling_sweep "$_dir" "$((_since + 90000))" 86400
      _gcl="$(cat "$GC_F")"
      has "$_gcl" "mail send mayor" && has "$_gcl" "$FX" && ok "n1/$P the ceiling sweep mails the Mayor about the hold this path wrote" || bad "n1/$P no ceiling mail for the hold: [$_gcl]"
      : > "$GC_F"
      gate_vm_hold_ceiling_sweep "$_dir" "$((_since + 90000))" 86400
      [ ! -s "$GC_F" ] && ok "n2/$P a second sweep does not mail again (at most once)" || bad "n2/$P the Mayor was mailed twice: [$(cat "$GC_F")]"
      ;;
  esac
  cleanup_run "$T_LAST"
}

echo "── 3-5. every scenario, through BOTH already-merged paths ──"
scenarios 0a4
scenarios 4b

# ── 6. mutation tests ────────────────────────────────────────────────────────
# A green scenario proves nothing until the same scenario goes RED against broken code. Each mutation
# below edits the REAL extracted merged-path-vm-hold-fn text in one place, runs the one scenario that
# is supposed to notice, and requires that scenario to fail. A mutation that does not apply, or one
# the scenario does not notice, is itself a failed assertion.
echo "── 6. mutation tests: every guard must be load-bearing ──"
held_ok() { ! was_closed && pend_label && passed_label && ! super_label; }

# mutate <tag> <scenario-fn> <old> <new>
mutate() {
  local tag="$1" scn="$2" old="$3" new="$4" mutated
  if ! mutated="$(python3 -c '
import sys
s, old, new = sys.stdin.read(), sys.argv[1], sys.argv[2]
if s.count(old) != 1:
    sys.exit(3)
sys.stdout.write(s.replace(old, new, 1))' "$old" "$new" <<<"$FN_MERGED")"; then
    bad "$tag the mutation did not apply exactly once — the production text moved, update this mutation"
    return 0
  fi
  eval "$mutated"
  if "$scn"; then ok "$tag mutation DETECTED by $scn"; else bad "$tag mutation SURVIVED $scn — the guard it removed is not load-bearing"; fi
  eval "$FN_MERGED"   # restore the real code for the next mutation
}
# Each scenario returns 0 iff the mutation is DETECTED (the behaviour went wrong).
scn_hold_pending()      { sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; run_path 0a4; ! held_ok; }
scn_tip_base_pending()  { sc_reset; SC_BASE=tip; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; run_path 0a4; ! held_ok; }
scn_own_hold()          { sc_reset; SC_SHOW_LABELS='["lane:small","delivery:pending-vm"]'; run_path 0a4; ! held_ok; }
scn_labels_unreadable() { sc_reset; SC_SHOW_FAIL_FROM=2; run_path 0a4; ! held_ok; }
scn_unknown_vm()        { sc_reset; SC_STATUS_RC=3; SC_STATUS_OUT=""; run_path 0a4; ! held_ok; }
scn_registry_note()     { sc_reset; SC_RT_MODE=unreadable; run_path 0a4; ! has "$(close_reason)" "NÃO verificada"; }
scn_held_not_superseded() { sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; run_path 0a4; super_label; }
scn_label_fail_claim()  { sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_LABEL_ADD_FAIL=1; run_path 0a4; has "$(comments)" "Held as delivery:pending-vm"; }
scn_since_restarted()   { sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_PRESEED_SINCE=1000; run_path 0a4; ! has "$STATE_AFTER" "since=1000"; }
scn_state_unwritable()  { sc_reset; SC_STATUS_RC=10; SC_STATUS_OUT="STATUS: pendente"; SC_BREAK_STATE_DIR=1; run_path 0a4; ! has "$(comments)" "NOT armed"; }

if [ -n "$FN_MERGED" ]; then
  mutate "M1  never hold (always close)"                     scn_hold_pending      'if [ "$MERGED_VM_ACTION" != "hold" ]; then' 'if true; then'
  mutate "M2  drop the empty-range (base==tip) guard"       scn_tip_base_pending  'case "$n" in 0) base="" ;; esac' ':'
  mutate "M3  ignore an earlier delivery:pending-vm"        scn_own_hold          '*" delivery:pending-vm "*)' '*" delivery:pending-vm-OFF "*)'
  mutate "M4  unreadable labels read as 'no hold'"          scn_labels_unreadable 'if [ "$OWN_HOLD_KIND" = "unverified" ]; then' 'if false; then'
  mutate "M5  an UNKNOWN vm status closes"                  scn_unknown_vm        $'    *)\n      MERGED_VM_ACTION="hold"\n      ;;' $'    unknown) : ;;\n    *)\n      MERGED_VM_ACTION="hold"\n      ;;'
  mutate "M6  unreadable registry closes without saying so" scn_registry_note     'MERGED_VM_NOTE="ga-buac0o: VM do voicebot NÃO verificada — registro de runbooks (delivery-runbooks.toml) ilegível."' 'MERGED_VM_NOTE=""'
  mutate "M7  a held bead is labelled gate:superseded"      scn_held_not_superseded 'bd -C "$bead_city" label remove "$bead_id" "gate:reviewing" -q 2>/dev/null || true' $'bd -C "$bead_city" label remove "$bead_id" "gate:reviewing" -q 2>/dev/null || true\n  bd -C "$bead_city" label add "$bead_id" "gate:superseded" -q 2>/dev/null || true'
  mutate "M8  claim a hold label that failed to write"      scn_label_fail_claim  'if bd -C "$bead_city" label add "$bead_id" "delivery:pending-vm" -q 2>/dev/null; then' 'if { bd -C "$bead_city" label add "$bead_id" "delivery:pending-vm" -q 2>/dev/null || true; }; then'
  mutate "M9  restart an earlier hold's clock"              scn_since_restarted   'since="$(voicebot_vm_state_get "$file" since)"' 'since=""'
  mutate "M10 hide that the 24h ceiling is not armed"       scn_state_unwritable  'if voicebot_vm_state_put "$dir" "$file" "$VM_HOLD_KIND|$bead_city" "$since" "$mailed"; then' 'if true; then'
  mutate "M11 delta from merge-base(branch, main), not the marker base" scn_hold_pending 'gate_vm_hold_check "$rt" "$base" "$tip"' 'gate_vm_hold_check "$rt" "$(git_rig merge-base "$tip" origin/main 2>/dev/null)" "$tip"'
else
  bad "section 6 skipped: no FN_MERGED to mutate"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
