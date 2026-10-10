#!/usr/bin/env bash
# gate-g3m45n-nudge-pointer.selftest.sh (ga-g3m45n, P0)
#
# Bug: the gate put the WHOLE review task (the diff rides inside it, up to 527 KB) into the nudge queue at
# three points — the initial send, EVERY ACK retry (Step 7b, up to 3 per un-ACKed reviewer) and every
# re-convene. The engine re-reads and re-writes `.gc/nudges/state.json` whole on every operation (3 pollers
# every 2 s plus each session's drain), and measured 10/10 that 4.4 MB of the file's 5.2 MB was pending review
# tasks. The same text is already on the verdict bead (durable pull, ga-67hae).
#
# Fix under test (quality-gate-dispatcher.sh):
#   * gate_review_task_embedded     reads the verdict bead back: 0 found / 1 absent-or-truncated / 2 unreadable.
#   * gate_review_nudge_message     pointer (<1 KB) ONLY when asked (pointer_ok=1), the full task otherwise.
#   * gate_deliver_review_task      the one delivery path: pointer-or-task, and in retry mode NO second copy
#                                   when the queue already accepted one for this session.
#   * the three sites route through it; a re-convened slot starts from a clean NUDGE_SENT / POINTER_OK.
#
# Runs with NO live Dolt/gc/bd/launchd: `gc` and `bd` are shell-function mocks. The byte counts are of what the
# REAL gate_nudge/gate_deliver_review_task hand to `gc session nudge|submit`.
#
# Mutation-tested (see the "(mutation)" section and the header of the PR): the same scenarios against the
# pre-fix delivery (full task on every send + every retry) give the numbers this fix removes.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
E5LIB="$SELF_DIR/gate-e5-second-reviewer.lib.sh"
PROMPT="$SELF_DIR/../../../agents/gate-reviewer/prompt.template.md"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
le()  { if [ "$2" -le "$3" ] 2>/dev/null; then ok "$1 ($2 <= $3)"; else bad "$1: expected <= $3, got [$2]"; fi; }
hasF()    { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — not found: $2"; fi; }

echo "── 0. compile-guard ──"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: macOS system bash 3.2 -n clean"; else bad "dispatcher: system bash -n FAILED"; fi
if bash -n "$E5LIB" 2>/dev/null; then ok "e5 lib: bash -n clean"; else bad "e5 lib: bash -n FAILED"; fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
for _fn in gate_review_task_embedded gate_review_nudge_message gate_deliver_review_task respawn_reviewer_slot gate_nudge; do
  type "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn not defined by the dispatcher (the fix is missing)"; exit 1; }
done
log()  { :; }
warn() { :; }
err()  { :; }

# ── fixtures ──────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NUDGE_LOG="$TMP/nudge.log"          # one line per `session nudge`:  "<sid> <bytes> <first-60-chars>"
SUBMIT_LOG="$TMP/submit.log"        # one line per `session submit`: same shape
MSG_DIR="$TMP/msgs"; mkdir -p "$MSG_DIR"
COMMENTS_FILE="$TMP/comments.json"  # what `bd comments <vb> --json` answers
MOCK_NUDGE_FAIL=0                   # 1 → `session nudge` exits 1 with "session not found"
MOCK_SUBMIT_FAIL=0                  # 1 → `session submit` exits 1
MOCK_COMMENTS_MODE=file             # file | fail
reset_logs() { : > "$NUDGE_LOG"; : > "$SUBMIT_LOG"; rm -f "$MSG_DIR"/*; }
nudge_count()  { wc -l < "$NUDGE_LOG" | tr -d ' '; }
submit_count() { wc -l < "$SUBMIT_LOG" | tr -d ' '; }
# total bytes handed to the queue (nudge) / to submit
bytes_in() { awk '{s+=$2} END{print s+0}' "$1"; }

gc() {
  # gc --city <city> session <verb> <sid> [<msg> ...]
  [ "${1:-}" = "--city" ] && shift 2
  [ "${1:-}" = "session" ] || return 0
  local _verb="$2" _sid="$3" _msg="${4:-}" _n
  case "$_verb" in
    nudge)
      if [ "$MOCK_NUDGE_FAIL" = "1" ]; then echo "gc session nudge: session not found: \"$_sid\"" >&2; return 1; fi
      printf '%s %s %s\n' "$_sid" "$(printf '%s' "$_msg" | wc -c | tr -d ' ')" "$(printf '%s' "$_msg" | head -n1 | cut -c1-60 | tr ' ' '_')" >> "$NUDGE_LOG"
      _n=$(wc -l < "$NUDGE_LOG" | tr -d ' '); printf '%s' "$_msg" > "$MSG_DIR/nudge.$_n"
      return 0 ;;
    submit)
      if [ "$MOCK_SUBMIT_FAIL" = "1" ]; then return 1; fi
      printf '%s %s %s\n' "$_sid" "$(printf '%s' "$_msg" | wc -c | tr -d ' ')" "$(printf '%s' "$_msg" | head -n1 | cut -c1-60 | tr ' ' '_')" >> "$SUBMIT_LOG"
      return 0 ;;
    new) echo "{\"session_id\":\"${MOCK_NEW_SID:-ga-NEW}\",\"session_name\":\"${MOCK_NEW_SNAME-gate-reviewer-NEW}\"}"; return 0 ;;
  esac
  return 0
}

# bd: `comments <vb> --json` answers from COMMENTS_FILE (or fails); `update --assignee` + `show --json` model the
# verified-assign read-back that respawn_reviewer_slot runs (same idea as quality-gate-reconvene.selftest.sh).
BD_ASSIGN_FILE="$TMP/assign"; : > "$BD_ASSIGN_FILE"
bd() {
  local _t _prev="" _bead="" _assignee="" _is_update=0 _is_show=0 _is_comments=0
  for _t in "$@"; do
    [ "$_prev" = "update" ]     && _bead="$_t"
    [ "$_prev" = "show" ]       && _bead="$_t"
    [ "$_prev" = "comments" ]   && _bead="$_t"
    [ "$_prev" = "--assignee" ] && _assignee="$_t"
    [ "$_t" = "update" ]   && _is_update=1
    [ "$_t" = "show" ]     && _is_show=1
    [ "$_t" = "comments" ] && _is_comments=1
    _prev="$_t"
  done
  if [ "$_is_comments" = "1" ]; then
    [ "$MOCK_COMMENTS_MODE" = "fail" ] && return 1
    cat "$COMMENTS_FILE" 2>/dev/null; return 0
  fi
  if [ "$_is_update" = "1" ] && [ -n "$_bead" ] && [ -n "$_assignee" ]; then
    echo "$_bead $_assignee" >> "$BD_ASSIGN_FILE"; return 0
  fi
  if [ "$_is_show" = "1" ] && [ -n "$_bead" ]; then
    echo "{\"assignee\":\"$(awk -v b="$_bead" '$1==b{v=$2} END{print v}' "$BD_ASSIGN_FILE")\"}"; return 0
  fi
  return 0
}

GC_CITY="$TMP/city"; BRANCH="fix/ga-g3m45n-demo"; BRANCH_SHA="0123456789abcdef0123456789abcdef01234567"; REQUIRED_REVIEWERS=3

# A realistic task: heading line (the lib's own shape), a body of N bytes, and a tail with the verdict commands.
# make_task <reviewer_idx> <vb> <body_bytes>
make_task() {
  printf 'QUALITY GATE REVIEW — You are reviewer %s of 3 for branch: %s\n' "$1" "$BRANCH"
  printf 'lens: CORRECTNESS\n'
  head -c "$3" /dev/zero | tr '\0' 'd'
  printf '\nbd -C "%s" close "%s"\n' "$GC_CITY" "$2"
}
# write_comments <task> — the verdict bead's comment list with that task embedded (shape of `bd comments --json`)
write_comments() { jq -n --arg t "$1" '[{"id":"c1","issue_id":"vb","author":"gate","text":$t,"created_at":"2026-10-10T00:00:00Z"}]' > "$COMMENTS_FILE"; }

TASK_BIG_BYTES=500000
TASK0="$(make_task 1 vb0 $TASK_BIG_BYTES)"; TASK1="$(make_task 2 vb1 $TASK_BIG_BYTES)"; TASK2="$(make_task 3 vb2 $TASK_BIG_BYTES)"
TASK_CHARS=${#TASK0}
echo "  (fixture: 3 review tasks of ~${TASK_CHARS} chars each, the size class measured on 10/10)"

echo "── 1. gate_review_nudge_message: pointer only when asked, full task otherwise ──"
PTR="$(gate_review_nudge_message 1 "$TASK0" 1 3 "$BRANCH" "$BRANCH_SHA" vb0)"
le "pointer is under 1 KB" "$(printf '%s' "$PTR" | wc -c | tr -d ' ')" 1023
case "$PTR" in "QUALITY GATE REVIEW — POINTER"*) ok "pointer opens with the reviewer prompt's own signature (taken from the task, not repeated here)" ;; *) bad "pointer signature wrong: ${PTR:0:60}" ;; esac
case "$PTR" in *"gc bd show vb0"*) ok "pointer tells the reviewer exactly which bead to open" ;; *) bad "pointer does not name the verdict bead" ;; esac
case "$PTR" in *"$BRANCH"*"$BRANCH_SHA"*) ok "pointer carries branch + sha" ;; *) bad "pointer lacks branch/sha" ;; esac
case "$PTR" in *"dddddddddd"*) bad "pointer leaked diff content" ;; *) ok "pointer carries NO task body/diff" ;; esac
LONG_BRANCH="$(head -c 5000 /dev/zero | tr '\0' 'b')"
le "a 5000-char branch name cannot push the pointer past 1 KB" "$(gate_review_nudge_message 1 "$TASK0" 1 3 "$LONG_BRANCH" "$BRANCH_SHA" vb0 | wc -c | tr -d ' ')" 1023
for _ok in 0 "" "yes" "2"; do
  eq "pointer_ok='$_ok' → the FULL task, byte for byte" "$(gate_review_nudge_message "$_ok" "$TASK0" 1 3 "$BRANCH" "$BRANCH_SHA" vb0 | cksum)" "$(printf '%s' "$TASK0" | cksum)"
done
eq "pointer_ok=1 but no verdict bead id → the full task (never a pointer to nowhere)" \
  "$(gate_review_nudge_message 1 "$TASK0" 1 3 "$BRANCH" "$BRANCH_SHA" "" | cksum)" "$(printf '%s' "$TASK0" | cksum)"
eq "pointer_ok=1 but an unrecognisable heading (no ' — ') → the full task" \
  "$(gate_review_nudge_message 1 "just some text" 1 3 "$BRANCH" "$BRANCH_SHA" vb0 | cksum)" "$(printf '%s' "just some text" | cksum)"
eq "pointer_ok=1 with an EMPTY task → empty (nothing to point at, nothing invented)" "$(gate_review_nudge_message 1 "" 1 3 "$BRANCH" "$BRANCH_SHA" vb0 | wc -c | tr -d ' ')" "$(gate_review_nudge_message 1 "" 1 3 "$BRANCH" "$BRANCH_SHA" vb0 | wc -c | tr -d ' ')"

echo "── 2. gate_review_task_embedded: found / absent / unreadable are three different answers ──"
MOCK_COMMENTS_MODE=file
write_comments "$TASK0"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "task present whole → 0 (found)" "$rc" "0"
# truncated at a 64 KB column limit: the head survives, the tail (verdict commands) does not
write_comments "$(printf '%s' "$TASK0" | head -c 65000)"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "task TRUNCATED (tail lost) → 1 (absent), not found" "$rc" "1"
echo '[]' > "$COMMENTS_FILE"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "comments read, none → 1 (absent)" "$rc" "1"
jq -n '[{"id":"c","text":"somebody elses comment"}]' > "$COMMENTS_FILE"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "comments read, task not among them → 1 (absent)" "$rc" "1"
write_comments "$TASK1"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "ANOTHER reviewer's task embedded, not this one → 1 (absent)" "$rc" "1"
MOCK_COMMENTS_MODE=fail
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "bd failed → 2 (unreadable), NOT 1 and NOT 0" "$rc" "2"
MOCK_COMMENTS_MODE=file; echo 'this is not json' > "$COMMENTS_FILE"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "garbage output → 2 (unreadable)" "$rc" "2"
echo '{"error":"no issue found"}' > "$COMMENTS_FILE"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "an error OBJECT instead of the array → 2 (unreadable)" "$rc" "2"
: > "$COMMENTS_FILE"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "empty output → 2 (unreadable)" "$rc" "2"
echo '[{"id":"c","text":12345}]' > "$COMMENTS_FILE"
rc=0; gate_review_task_embedded vb0 "$TASK0" || rc=$?; eq "a comment whose text is not a string (jq runtime error, exit 5) → 2 (unreadable), not 'absent' and not 'found'" "$rc" "2"
write_comments "$TASK0"
rc=0; gate_review_task_embedded vb0 "" || rc=$?; eq "empty task → 2 (nothing to probe for)" "$rc" "2"
rc=0; gate_review_task_embedded "" "$TASK0" || rc=$?; eq "no bead id → 2" "$rc" "2"

echo "── 3. the byte budget of a whole cycle: 3 reviewers, nobody ACKs, 3 retry rounds (the bead's own criterion) ──"
# run_cycle <pointer_ok 0|1> — the dispatcher's flow: initial send for each of the 3 slots, then 3 ACK rounds in
# which every un-ACKed slot is re-queued. Same calls the dispatcher makes (gate_deliver_review_task send/retry).
TASKS=("$TASK0" "$TASK1" "$TASK2"); VBS=(vb0 vb1 vb2); SIDS=(s0 s1 s2)
run_cycle() {
  local _ptr="$1" _k _round
  REVIEWER_NUDGE_SENT=(); REVIEWER_POINTER_OK=(); REVIEWER_TASK_EMBEDDED=()
  reset_logs
  for _k in 0 1 2; do
    REVIEWER_POINTER_OK[$_k]="$_ptr"; REVIEWER_TASK_EMBEDDED[$_k]="$_ptr"; REVIEWER_NUDGE_SENT[$_k]=0
    gate_deliver_review_task "$_k" "${SIDS[$_k]}" "${TASKS[$_k]}" "$((_k+1))" "${VBS[$_k]}" send || true
  done
  for _round in 1 2 3; do
    for _k in 0 1 2; do
      gate_deliver_review_task "$_k" "${SIDS[$_k]}" "${TASKS[$_k]}" "$((_k+1))" "${VBS[$_k]}" retry || true
    done
  done
}
MOCK_NUDGE_FAIL=0; MOCK_SUBMIT_FAIL=0
run_cycle 1
POST_PTR_BYTES=$(bytes_in "$NUDGE_LOG")
echo "  durable channel PROVEN: $(nudge_count) nudges, ${POST_PTR_BYTES} bytes enqueued in the cycle"
eq  "proven durable channel: exactly ONE nudge per reviewer (3 retry rounds stack nothing)" "$(nudge_count)" "3"
le  "proven durable channel: the whole cycle is <= 1 task + 3 pointers (the bead's criterion: <= task + 3×pointer)" "$POST_PTR_BYTES" "$((TASK_CHARS + 3 * 1024))"
le  "…and in fact under 4 KB for the 3 reviewers together" "$POST_PTR_BYTES" "4096"
eq  "proven durable channel: nothing went through submit" "$(submit_count)" "0"

run_cycle 0
POST_FULL_BYTES=$(bytes_in "$NUDGE_LOG")
echo "  durable channel NOT proven: $(nudge_count) nudges, ${POST_FULL_BYTES} bytes enqueued in the cycle"
eq  "unproven durable channel: the FULL task goes out ONCE per reviewer — and the retries still do not stack copies" "$(nudge_count)" "3"
eq  "unproven durable channel: bytes = exactly the 3 tasks, no more" "$POST_FULL_BYTES" "$(( $(printf '%s' "$TASK0" | wc -c) + $(printf '%s' "$TASK1" | wc -c) + $(printf '%s' "$TASK2" | wc -c) ))"
cmp -s "$MSG_DIR/nudge.1" <(printf '%s' "$TASK0") && ok "…and the first nudge is the task, byte for byte (the reviewer gets everything it needs)" || bad "the full-task nudge differs from the task"

echo "── (mutation) the PRE-FIX delivery on the same scenario: full task on every send AND every retry ──"
# Exactly what the dispatcher did before ga-g3m45n at the three sites: gate_nudge "$sid" "$TASK" every time.
prefix_cycle() {
  local _k _round
  reset_logs
  for _k in 0 1 2; do gate_nudge "${SIDS[$_k]}" "${TASKS[$_k]}" --delivery queue 2>/dev/null || true; done
  for _round in 1 2 3; do for _k in 0 1 2; do gate_nudge "${SIDS[$_k]}" "${TASKS[$_k]}" --delivery queue 2>/dev/null || true; done; done
}
prefix_cycle
PRE_BYTES=$(bytes_in "$NUDGE_LOG")
echo "  pre-fix: $(nudge_count) nudges, ${PRE_BYTES} bytes enqueued in the same cycle"
eq  "pre-fix delivery enqueues 12 copies (3 initial + 3 rounds × 3)" "$(nudge_count)" "12"
if [ "$PRE_BYTES" -gt "$((POST_PTR_BYTES * 100))" ]; then ok "pre-fix bytes (${PRE_BYTES}) are >100x the fixed cycle (${POST_PTR_BYTES}) — this test would FAIL against the old delivery"; else bad "mutation did not diverge: pre=${PRE_BYTES} post=${POST_PTR_BYTES}"; fi

echo "── 4. retry semantics: a REFUSED first copy is retried, an ACCEPTED one is not ──"
REVIEWER_NUDGE_SENT=(); REVIEWER_POINTER_OK=(1); reset_logs
MOCK_NUDGE_FAIL=1; MOCK_SUBMIT_FAIL=1
rc=0; gate_deliver_review_task 0 s0 "$TASK0" 1 vb0 send || rc=$?
eq "queue AND submit refused → rc 1 (not delivered)" "$rc" "1"
eq "…and NUDGE_SENT stays 0 — a refusal is not a send" "${REVIEWER_NUDGE_SENT[0]:-0}" "0"
MOCK_NUDGE_FAIL=0
rc=0; gate_deliver_review_task 0 s0 "$TASK0" 1 vb0 retry || rc=$?
eq "the retry after a refusal DELIVERS (rc 0)" "$rc" "0"
eq "…and records the accepted copy" "${REVIEWER_NUDGE_SENT[0]:-0}" "1"
rc=0; gate_deliver_review_task 0 s0 "$TASK0" 1 vb0 retry || rc=$?
eq "the NEXT retry is dispensed (rc 10, already queued)" "$rc" "10"
eq "…exactly one nudge reached the queue in total" "$(nudge_count)" "1"
# queue refuses, submit accepts → rc 2 and it counts as sent
REVIEWER_NUDGE_SENT=(); REVIEWER_POINTER_OK=(0); reset_logs; MOCK_NUDGE_FAIL=1; MOCK_SUBMIT_FAIL=0
rc=0; gate_deliver_review_task 0 s0 "$TASK0" 1 vb0 send || rc=$?
eq "queue refused, submit accepted → rc 2" "$rc" "2"
eq "…and NUDGE_SENT=1" "${REVIEWER_NUDGE_SENT[0]:-0}" "1"
# retry mode never falls back to submit (it never did)
REVIEWER_NUDGE_SENT=(); reset_logs; MOCK_NUDGE_FAIL=1; MOCK_SUBMIT_FAIL=0
rc=0; gate_deliver_review_task 0 s0 "$TASK0" 1 vb0 retry || rc=$?
eq "retry mode with the queue refusing → rc 1 and NO submit fallback (as before the fix)" "$rc:$(submit_count)" "1:0"
MOCK_NUDGE_FAIL=0
# an unset slot (the E5 extra slot is filled by the lib, an unknown one by nobody) behaves as before: full task, retry allowed
unset REVIEWER_NUDGE_SENT REVIEWER_POINTER_OK; reset_logs
rc=0; gate_deliver_review_task 7 s7 "$TASK0" 2 vb7 retry || rc=$?
eq "a slot nobody initialised: the retry delivers (rc 0), the old behaviour" "$rc" "0"
eq "…with the FULL task, not a pointer" "$(wc -c < "$MSG_DIR/nudge.1" | tr -d ' ')" "$(printf '%s' "$TASK0" | wc -c | tr -d ' ')"

echo "── 5. respawn_reviewer_slot (the re-convene path), the REAL function ──"
VERDICT_BEAD_IDS=(vb0 vb1 vb2); SESSION_IDS=(ga-old0 ga-old1 ga-old2); REVIEW_TASKS=("$TASK0" "$TASK1" "$TASK2")
MOCK_NEW_SID="ga-NEW"; MOCK_NEW_SNAME="gate-reviewer-NEW"
# (a) assignment verifies, task provably on the bead → pointer
: > "$BD_ASSIGN_FILE"; write_comments "$TASK2"; MOCK_COMMENTS_MODE=file
REVIEWER_NUDGE_SENT=(1 1 1); REVIEWER_POINTER_OK=(0 0 0); REVIEWER_TASK_EMBEDDED=(0 0 0); reset_logs
respawn_reviewer_slot 2
eq "re-convene (task on the bead, assign verified): ONE nudge to the NEW session" "$(awk '{print $1}' "$NUDGE_LOG")" "ga-NEW"
le "…and it is a pointer, not the task" "$(awk '{print $2}' "$NUDGE_LOG")" "1023"
eq "…POINTER_OK was earned for the NEW session" "${REVIEWER_POINTER_OK[2]}" "1"
eq "…the nudge was accepted, so the NEW session's NUDGE_SENT is 1" "${REVIEWER_NUDGE_SENT[2]}" "1"
# The reset itself: NUDGE_SENT=1 was left by the DEAD session. If the respawn does not clear it, a slot whose
# delivery to the NEW session is REFUSED would still read "already queued" and the ACK pass would never retry it.
: > "$BD_ASSIGN_FILE"; write_comments "$TASK2"; SESSION_IDS=(ga-old0 ga-old1 ga-old2)
REVIEWER_NUDGE_SENT=(0 0 1); REVIEWER_POINTER_OK=(0 0 1); REVIEWER_TASK_EMBEDDED=(0 0 0); reset_logs
MOCK_NUDGE_FAIL=1; MOCK_SUBMIT_FAIL=1
respawn_reviewer_slot 2
MOCK_NUDGE_FAIL=0; MOCK_SUBMIT_FAIL=0
eq "re-convene whose delivery is REFUSED: NUDGE_SENT is 0 for the new session (the dead session's 1 is gone)" "${REVIEWER_NUDGE_SENT[2]}" "0"
rc=0; gate_deliver_review_task 2 ga-NEW "$TASK2" 3 vb2 retry || rc=$?
eq "…so the ACK pass's retry for that slot DELIVERS instead of being dispensed" "$rc" "0"
# (b) the bead has no task (the first embed was lost and the re-embed too) → full task, never a pointer to nothing
: > "$BD_ASSIGN_FILE"; echo '[]' > "$COMMENTS_FILE"; SESSION_IDS=(ga-old0 ga-old1 ga-old2)
REVIEWER_NUDGE_SENT=(0 0 1); REVIEWER_POINTER_OK=(0 0 1); REVIEWER_TASK_EMBEDDED=(0 0 0); reset_logs
respawn_reviewer_slot 2
eq "re-convene (task NOT on the bead): the nudge carries the FULL task" "$(awk '{print $2}' "$NUDGE_LOG")" "$(printf '%s' "$TASK2" | wc -c | tr -d ' ')"
eq "…POINTER_OK was reset by the respawn and NOT re-earned" "${REVIEWER_POINTER_OK[2]}" "0"
# (c) comments unreadable → also the full task
: > "$BD_ASSIGN_FILE"; MOCK_COMMENTS_MODE=fail; SESSION_IDS=(ga-old0 ga-old1 ga-old2)
REVIEWER_NUDGE_SENT=(0 0 0); REVIEWER_POINTER_OK=(0 0 0); REVIEWER_TASK_EMBEDDED=(0 0 0); reset_logs
respawn_reviewer_slot 2
eq "re-convene (bead unreadable): the FULL task, not a pointer on a guess" "$(awk '{print $2}' "$NUDGE_LOG")" "$(printf '%s' "$TASK2" | wc -c | tr -d ' ')"
MOCK_COMMENTS_MODE=file
# (d) the task was read back at the initial spawn (TASK_EMBEDDED=1): no second 500 KB read, pointer straight away
: > "$BD_ASSIGN_FILE"; MOCK_COMMENTS_MODE=fail; SESSION_IDS=(ga-old0 ga-old1 ga-old2)
REVIEWER_NUDGE_SENT=(0 0 1); REVIEWER_POINTER_OK=(0 0 1); REVIEWER_TASK_EMBEDDED=(0 0 1); reset_logs
respawn_reviewer_slot 2
le "re-convene (task already proven at spawn, assign verified): pointer even if bd is unreadable NOW" "$(awk '{print $2}' "$NUDGE_LOG")" "1023"
MOCK_COMMENTS_MODE=file
# (e) the new session's assignment did NOT verify → full task even though the task is on the bead
: > "$BD_ASSIGN_FILE"; write_comments "$TASK2"; SESSION_IDS=(ga-old0 ga-old1 ga-old2)
MOCK_NEW_SNAME=""   # spawn JSON without a session_name → durable channel not re-pointed
REVIEWER_NUDGE_SENT=(0 0 0); REVIEWER_POINTER_OK=(0 0 0); REVIEWER_TASK_EMBEDDED=(0 0 1); reset_logs
respawn_reviewer_slot 2
eq "re-convene (no session_name → assignment not re-pointed): the FULL task" "$(awk '{print $2}' "$NUDGE_LOG")" "$(printf '%s' "$TASK2" | wc -c | tr -d ' ')"
MOCK_NEW_SNAME="gate-reviewer-NEW"

echo "── 6. wiring (drift-guards on the live scripts) ──"
hasF "$DISPATCHER" 'gate_review_task_embedded "$VERDICT_BEAD_ID" "$REVIEW_TASK" || _emb_rc=$?' "initial spawn reads the task back from the verdict bead (not the exit code of bd comment)"
hasF "$DISPATCHER" 'if [ "$_vb_assign_verified" = "1" ]; then _ptr_ok=1; fi' "initial spawn: pointer needs the assignment verified AND the read-back"
hasF "$DISPATCHER" 'gate_deliver_review_task "$((i-1))" "$SESSION_ID" "$REVIEW_TASK" "$i" "$VERDICT_BEAD_ID" send' "initial spawn → gate_deliver_review_task send"
hasF "$DISPATCHER" 'gate_deliver_review_task "$k" "$_sid" "${REVIEW_TASKS[$k]}" "$((k+1))" "$_vb" retry' "ACK retry → gate_deliver_review_task retry"
hasF "$DISPATCHER" 'gate_deliver_review_task "$_idx" "$_new_sid" "${REVIEW_TASKS[$_idx]}" "$_rev" "${VERDICT_BEAD_IDS[$_idx]}" send' "re-convene → gate_deliver_review_task send"
hasF "$DISPATCHER" 'REVIEWER_NUDGE_SENT[$_idx]=0' "re-convene resets NUDGE_SENT for the new session"
# ACEITE #3 (ga-590nx): the comment-embed lines themselves are untouched and unconditional
hasF "$DISPATCHER" 'bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "$REVIEW_TASK" 2>/dev/null || true' "initial comment-embed line unchanged (ACEITE #3 of ga-590nx)"
hasF "$DISPATCHER" 'bd -C "$GC_CITY" comment "${VERDICT_BEAD_IDS[$_idx]}" "${REVIEW_TASKS[$_idx]}" 2>/dev/null || true' "re-convene comment-embed line unchanged"
# the E5 extra slot joins the same state
hasF "$E5LIB" 'REVIEWER_NUDGE_SENT[$(( ${#VERDICT_BEAD_IDS[@]} - 1 ))]="$GATE_E5_EXTRA_NUDGE_SENT"' "E5 extra slot records its NUDGE_SENT (so the ACK pass does not stack its 500 KB task either)"
hasF "$E5LIB" 'gate_review_task_embedded "$_vb2" "$_task2" || _emb_rc=$?' "E5 extra reads its task back before trusting a pointer"
# the reviewer's prompt knows what a pointer is
hasF "$PROMPT" 'POINTER' "gate-reviewer prompt documents the pointer nudge"
hasF "$PROMPT" 'trust your poll' "…and keeps the rule that a bead that is not yours is never yours (ga-6wel0o)"
# one-prompt doctrine (ga-gnr3tw): the dispatcher must not carry the prompt heading literal
if grep -q 'QUALITY GATE REVIEW' "$DISPATCHER"; then bad "dispatcher carries the prompt heading literal (pre-gate-review.selftest.sh forbids it)"; else ok "dispatcher carries no copy of the prompt heading (the pointer takes its signature from the task)"; fi

echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-g3m45n-nudge-pointer selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-g3m45n-nudge-pointer selftest"
  exit 1
fi
