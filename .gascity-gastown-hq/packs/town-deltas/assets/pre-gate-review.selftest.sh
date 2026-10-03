#!/usr/bin/env bash
# pre-gate-review.selftest.sh — guard for ga-gnr3tw (E3 of P0 ga-ufskhy): the builder's pre-gate self-review.
#
# What this proves, with NO live Dolt/gc/launchd/network and NO money spent (claude and gc are stubs):
#   1. ONE PROMPT. The builder renders the reviewer's task through the same lib function the dispatcher calls.
#      The judging text of the bead-mode (gate) and text-mode (builder) renders is byte-identical up to the
#      verdict-recording block; the dispatcher and the script carry no private copy of the prompt; the dispatcher
#      loads the lib before it claims any marker and dies loudly (not silently) if the lib is missing.
#   2. THE ARM IS DETERMINISTIC, BALANCED AND INDEPENDENT of the ga-rstae arm (which also splits by bead-id hash).
#   3. THREE OUTCOMES. PASS / FAIL / INCONCLUSIVE are distinct exit codes, and every way of NOT being able to judge
#      (guard, busy, timeout, no verdict line, claude error, dirty tree, HEAD off the branch, empty diff) is
#      INCONCLUSIVE — never a PASS. So is a reviewer PASS on a diff it saw only PART of (or of unknown coverage): the
#      result line, the record and the console all say how much of the diff stood behind the verdict.
#   4. IT WRITES NOTHING TO THE GATE and reviews with the LIVE gate-reviewer model/effort, read-only tools and a
#      sanitized environment; the control arm spends nothing; the per-bead run cap holds.
#   5. A PAID RUN ALWAYS LEAVES A ROW. The log gets a PENDING row BEFORE claude starts and a FINAL row after (one run_id); a run
#      interrupted by TERM / INT / HUP is settled as INCONCLUSIVE interrupted:<SIG> and its reviewer process tree is stopped;
#      SIGKILL leaves the PENDING row; an abnormal exit is settled by the EXIT net; a spend whose PENDING row cannot be written is
#      refused. All of them count toward the per-bead cap with an UNKNOWN cost (never 0), and the real apuracao reads them so.
# Exit 0 iff every assertion holds. Bash 3.2 compatible (the interpreter macOS launchd gives the dispatcher).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG="${PRE_GATE_UNDER_TEST:-$SELF_DIR/pre-gate-review.sh}"
LIB="${TASKLIB_UNDER_TEST:-$SELF_DIR/gate-review-task.lib.sh}"
DISPATCHER="${DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
GUARD="$SELF_DIR/quality-gate-guard.sh"
BASH32=/bin/bash

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — expected [$2] got [$1]"; fi; }
# here-string, never `printf | grep -q`: under pipefail grep -q can SIGPIPE the writer and flip a true match to false
has_str() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — not found: $2"; fi; }
not_str() { if grep -qF -- "$2" <<<"$1"; then bad "$3 — present: $2"; else ok "$3"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pre-gate-selftest.XXXXXX")"
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"; }
trap cleanup EXIT

echo "── 1. COMPILE-GUARD: script + lib parse under /bin/bash 3.2 and the bash in PATH ──"
for f in "$PG" "$LIB"; do
  if [ ! -f "$f" ]; then bad "missing: $f"; continue; fi
  if "$BASH32" -n "$f" 2>/dev/null && bash -n "$f" 2>/dev/null; then ok "$(basename "$f"): parses (/bin/bash + PATH bash)"; else bad "$(basename "$f"): does NOT parse"; fi
done
[ -x "$PG" ] && ok "pre-gate-review.sh is executable" || bad "pre-gate-review.sh is not executable"

# ── source the units under test (the script only defines functions when sourced) ──
# shellcheck disable=SC1090
source "$PG"

echo "── 2. THE ARM: deterministic, balanced, independent of the ga-rstae split ──"
eq "$(pregate_arm_for_bead ga-abc123)" "$(pregate_arm_for_bead ga-abc123)" "same bead → same arm (deterministic)"
pregate_arm_for_bead "" >/dev/null 2>&1; eq "$?" "2" "empty bead id → return 2 (no arm; never silently 'off')"
eq "$(pregate_arm_for_bead "")" "" "empty bead id → prints nothing"
on=0; off=0; both_on=0; both_off=0; on_a=0; on_b=0; N=160
ARM_SRC="$(sed -n '/^gate_ab_arm_for_bead()/,/^}/p' "$GUARD" 2>/dev/null)"
if [ -n "$ARM_SRC" ]; then eval "$ARM_SRC"; have_guard_arm=1; else have_guard_arm=0; fi
i=0
while [ "$i" -lt "$N" ]; do
  id="wa-t$(printf '%04x' $((i * 7 + 13)))"
  a="$(pregate_arm_for_bead "$id")"
  if [ "$a" = "on" ]; then on=$((on+1)); else off=$((off+1)); fi
  if [ "$have_guard_arm" = 1 ]; then
    g="$(gate_ab_arm_for_bead "$id")"
    if [ "$a" = "on" ] && [ "$g" = "B" ]; then both_on=$((both_on+1)); fi
    if [ "$a" = "off" ] && [ "$g" = "A" ]; then both_off=$((both_off+1)); fi
  fi
  i=$((i+1))
done
if [ "$on" -ge $((N*35/100)) ] && [ "$on" -le $((N*65/100)) ]; then ok "balanced: $on on / $off off of $N ids (within 35-65%)"; else bad "unbalanced: $on on / $off off of $N"; fi
if [ "$have_guard_arm" = 1 ]; then
  agree=$((both_on + both_off))
  # independent arms agree ~50% of the time; the SAME split would agree 100% (or 0% if inverted)
  if [ "$agree" -gt $((N*35/100)) ] && [ "$agree" -lt $((N*65/100)) ]; then ok "independent of the ga-rstae arm: agree on $agree of $N (~50%, not 0%/100%)"; else bad "arm is correlated with the ga-rstae split: agree on $agree of $N — the two experiments would be confounded"; fi
else
  bad "could not extract gate_ab_arm_for_bead from $GUARD — independence NOT checked"
fi
# find one on-arm and one off-arm bead id for the behavioural tests
ON_BEAD=""; OFF_BEAD=""; i=0
while [ -z "$ON_BEAD" ] || [ -z "$OFF_BEAD" ]; do
  id="ga-st$i"; a="$(pregate_arm_for_bead "$id")"
  [ "$a" = "on" ] && [ -z "$ON_BEAD" ] && ON_BEAD="$id"
  [ "$a" = "off" ] && [ -z "$OFF_BEAD" ] && OFF_BEAD="$id"
  i=$((i+1)); [ "$i" -gt 200 ] && break
done
[ -n "$ON_BEAD" ] && [ -n "$OFF_BEAD" ] && ok "fixture beads: on=$ON_BEAD off=$OFF_BEAD" || bad "could not find an on and an off bead id"
eq "$(bash "$PG" arm "$ON_BEAD" 2>/dev/null)" "on" "CLI: 'arm $ON_BEAD' prints on"
eq "$(bash "$PG" arm "$OFF_BEAD" 2>/dev/null)" "off" "CLI: 'arm $OFF_BEAD' prints off"
# the rule is the documented one, recomputable with a stock tool: first 32 bits of sha256("pregate:<bead>") even => on
for id in ga-abc123 wa-5460ap ps-x1y2; do
  hex="$(printf '%s' "pregate:$id" | shasum -a 256 | cut -c1-8)"
  if [ $(( 16#$hex % 2 )) -eq 0 ]; then want=on; else want=off; fi
  eq "$(pregate_arm_for_bead "$id")" "$want" "arm($id) = parity of sha256('pregate:$id') = $want (auditable with shasum)"
done
# every installed sha256 tool gives the same arm (the function takes the first one it finds, PATH differs per session)
disagree=0; checked=0
for id in ga-abc123 wa-5460ap ps-x1y2 ga-st0 ga-st1 wa-q9 crew-z1; do
  ref=""
  for tool in "sha256sum" "openssl dgst -sha256 -r" "shasum -a 256"; do
    command -v "${tool%% *}" >/dev/null 2>&1 || continue
    d="$(printf '%s' "pregate:$id" | $tool 2>/dev/null | cut -c1-8)"
    [ -z "$ref" ] && ref="$d"
    [ "$d" = "$ref" ] || disagree=$((disagree+1))
    checked=$((checked+1))
  done
done
if [ "$checked" -ge 7 ] && [ "$disagree" -eq 0 ]; then ok "all installed sha256 tools agree on the digest ($checked checks) — the arm does not depend on which one PATH offers"; else bad "sha256 tools disagree ($disagree of $checked) or none found — arms would differ by PATH"; fi
# no sha tool at all → return 3, prints nothing: 'cannot tell' must not read as 'off'
r="$(env PATH=/nonexistent "$BASH32" -c 'source "'"$PG"'" 2>/dev/null; pregate_arm_for_bead ga-x; echo "rc=$?"')"
eq "$r" "rc=3" "no sha256 tool → prints nothing and returns 3 (never silently 'off')"

echo "── 3. ONE PROMPT: same judging text for the gate and the builder, no private copies ──"
ARGS_COMMON=(2 3 feat/x au rg 0123456 "LENS-TEXT" "a.sh" "1-file" "HDR" $'diff --git a/a.sh\n+x')
BEAD_R="$(gate_render_review_task "${ARGS_COMMON[@]}" /city ga-verdict bead)"
TEXT_R="$(gate_render_review_task "${ARGS_COMMON[@]}" "" "" text)"
seam='After completing your review'
judge_bead="${BEAD_R%%$seam*}"; judge_text="${TEXT_R%%$seam*}"
if [ -n "$judge_bead" ] && [ "$judge_bead" = "$judge_text" ]; then ok "judging text identical in bead mode and text mode (${#judge_bead} bytes before the verdict block)"; else bad "judging text differs between bead mode and text mode"; fi
has_str "$BEAD_R" 'bd -C "/city" label add "ga-verdict" "verdict:PASS"' "bead mode tells the reviewer to record on the verdict bead"
not_str "$TEXT_R" 'bd -C' "text mode never tells the reviewer to run bd"
has_str "$TEXT_R" 'do NOT run bd or gc' "text mode says explicitly: do not run bd or gc"
has_str "$TEXT_R" 'VERDICT: FAIL' "text mode carries the verdict format"
gate_render_review_task "${ARGS_COMMON[@]}" "" "" bead >/dev/null 2>&1; eq "$?" "2" "bead mode with no verdict bead → return 2 (never a prompt that writes to bead \"\")"
gate_render_review_task "${ARGS_COMMON[@]}" "" "" bogus >/dev/null 2>&1; eq "$?" "2" "unknown verdict mode → return 2"
has_str "$BEAD_R" "reviewer 2 of 3 for branch: feat/x" "reviewer index / count / branch reach the prompt"
has_str "$(gate_reviewer_lens 1)" "CORRECTNESS" "lens 1 is CORRECTNESS"
eq "$(gate_reviewer_lens 9)" "" "unknown lens index → empty"

# structural: exactly one copy of the prompt
n_prompt=$(grep -c 'QUALITY GATE REVIEW' "$LIB" 2>/dev/null); eq "$n_prompt" "1" "the prompt text lives once, in the lib"
if grep -q 'QUALITY GATE REVIEW' "$DISPATCHER"; then bad "dispatcher still carries a private copy of the prompt"; else ok "dispatcher has no private copy of the prompt"; fi
if grep -q 'QUALITY GATE REVIEW' "$PG"; then bad "script carries a private copy of the prompt"; else ok "script has no private copy of the prompt"; fi
if grep -qE 'REVIEW_TASK=\$\(cat <<TASK' "$DISPATCHER"; then bad "dispatcher still renders REVIEW_TASK from an inline heredoc"; else ok "dispatcher no longer renders REVIEW_TASK inline"; fi
# the call spans two lines (backslash continuation); grep is line-based, so join continuations first
DISPATCHER_JOINED="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$DISPATCHER")"
if grep -qE 'REVIEW_TASK=\$\(gate_render_review_task "\$i" "\$REQUIRED_REVIEWERS" "\$BRANCH" "\$AUTHOR" "\$RIG" "\$BRANCH_SHA" +"\$REVIEWER_LENS" "\$CHANGED_FILES" "\$DIFF_SUMMARY" "\$DIFF_HEADER" "\$DIFF_FULL" "\$GC_CITY" "\$VERDICT_BEAD_ID" bead\)' <<<"$DISPATCHER_JOINED"; then ok "dispatcher renders REVIEW_TASK through gate_render_review_task (bead mode), arguments in the lib's order"; else bad "dispatcher does not call gate_render_review_task in bead mode with the lib's argument order"; fi
if grep -q 'gate_render_review_task' "$PG" && grep -qE 'text\)' "$PG"; then ok "script renders through gate_render_review_task (text mode)"; else bad "script does not call gate_render_review_task in text mode"; fi
if grep -q 'REVIEWER_LENS=\$(gate_reviewer_lens' "$DISPATCHER" && grep -q 'gate_reviewer_lens' "$PG"; then ok "both take the lens from gate_reviewer_lens"; else bad "lens is not shared"; fi
if grep -q 'DIFF_SUMMARY=\$(gate_diff_summary' "$DISPATCHER" && grep -q 'gate_build_diff_payload git_rig' "$DISPATCHER" && grep -q 'gate_build_diff_payload' "$PG"; then ok "both build the diff payload with gate_build_diff_payload"; else bad "diff payload is not shared"; fi
# the dispatcher must load the lib, and BEFORE it claims any marker
lib_line=$(grep -n 'source "\$_GATE_TASK_LIB"' "$DISPATCHER" | head -n1 | cut -d: -f1)
claim_line=$(grep -n -E '^[^#]*label add "\$MARKER_ID" "gate-status:dispatching"' "$DISPATCHER" | head -n1 | cut -d: -f1)
if [ -n "$lib_line" ] && [ -n "$claim_line" ] && [ "$lib_line" -lt "$claim_line" ]; then ok "dispatcher loads the lib (line $lib_line) before it first claims a marker (line $claim_line)"; else bad "dispatcher lib load ($lib_line) is not before the first marker claim ($claim_line)"; fi
if grep -B1 -A6 'if \[ -r "\$_GATE_TASK_LIB" \]' "$DISPATCHER" | grep -q 'exit 1' && grep -A6 'if \[ -r "\$_GATE_TASK_LIB" \]' "$DISPATCHER" | grep -q 'err "gate-review-task.lib.sh missing'; then ok "a missing lib is logged and fatal (never a silent set -e death, never a silent skip)"; else bad "missing-lib handling absent"; fi

echo "── 4. FIXTURE: a git repo with a feature branch, a fake city, stub claude + gc ──"
mkdir -p "$T/bin" "$T/stub" "$T/city/agents/gate-reviewer" "$T/city/.gc/agents/gate-reviewer/.claude"
git init -q --bare "$T/origin.git" && git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
G() { git -C "$T/work" "$@"; }
G config user.email t@t.t; G config user.name selftest
echo base > "$T/work/a.txt"; G add a.txt; G commit -q -m base; G branch -M main; G push -q origin main 2>/dev/null; G remote set-head origin main >/dev/null 2>&1
G checkout -q -b feat/x
echo change >> "$T/work/a.txt"; printf 'echo hi\n' > "$T/work/b.sh"; G add a.txt b.sh; G commit -q -m "feature ga-fix"
cat > "$T/city/agents/gate-reviewer/agent.toml" <<'EOF'
idle_timeout = "1h"
model = "sonnet"
provider = "claude-headless"
EOF
cat > "$T/city/city.toml" <<'EOF'
[[patches.agent]]
dir = ""
name = "refino-gate-reviewer"
option_defaults = { effort = "high" }

[[patches.agent]]
dir = ""
name = "gate-reviewer"
option_defaults = { effort = "xhigh" }
EOF
cat > "$T/city/.gc/agents/gate-reviewer/.claude/settings.json" <<'EOF'
{"autoMemoryEnabled": false, "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hook"}]}]},
 "permissions": {"deny": ["Bash(sudo:*)"]}, "claudeMdExcludes": ["/x/CLAUDE.md"]}
EOF
cat > "$T/bin/gc" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--city" ] && shift 2
if [ "${1:-}" = "prime" ] && [ "${2:-}" = "gate-reviewer" ]; then
  echo "# Gate Reviewer"
  echo "FAKE-GC-PRIME-GATE-REVIEWER"
  i=0; while [ $i -lt 40 ]; do echo "reviewer role text line $i padding padding padding padding"; i=$((i+1)); done
  echo "GC_SESSION_NAME_SEEN=${GC_SESSION_NAME:-unset}" >> "${STUB_DIR:-/dev/null}/gc-env.txt"
  exit 0
fi
exit 1
EOF
cat > "$T/bin/claude" <<'EOF'
#!/bin/bash
# stub claude: records argv/stdin/env, then emits a canned stream-json by STUB_MODE
: "${STUB_DIR:?}"
n=$(ls "$STUB_DIR"/call-*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n+1))
printf '%s\n' "$@" > "$STUB_DIR/call-$n.argv"
cat > "$STUB_DIR/call-$n.stdin"
{ echo "GC_SESSION_NAME=${GC_SESSION_NAME:-unset}"; echo "GC_ALIAS=${GC_ALIAS:-unset}"; echo "PWD=$PWD"; } > "$STUB_DIR/call-$n.env"
res() { printf '{"type":"system","subtype":"init","model":"claude-sonnet-5-5"}\n{"type":"result","subtype":"%s","is_error":%s,"result":"%s","total_cost_usd":%s,"num_turns":4,"modelUsage":{"claude-sonnet-5-5":{}}}\n' "$1" "$2" "$3" "$4"; }
case "${STUB_MODE:-pass}" in
  pass)      res success false 'Reviewed.\nVERDICT: PASS\nSummary: fine\nNon-blocking findings: none' 0.42 ;;
  fail)      res success false 'VERDICT: FAIL\nBlocking issue 1: empty and error collapse in b.sh\nNon-blocking findings: none' 0.55 ;;
  noverdict) res success false 'I looked at it and it seems OK.' 0.10 ;;
  error)     res error_max_budget_usd true 'budget exceeded' 3.01 ;;
  garbage)   echo 'not json at all' ;;
  timeout)   sleep 30 ;;
  # a review still running when the script is signalled: its pid and its child's are recorded so the test can prove the WHOLE tree stopped
  hang)      echo $$ > "$STUB_DIR/stub.pid"; sleep 120 & echo $! > "$STUB_DIR/sleep.pid"; wait ;;
  exit127)   exit 127 ;;   # claude (or nice/env) itself failing to exec: NOT "there is no timeout tool"
  # the reviewer finishes fine, but the run log became read-only while it ran: the FINAL row cannot be written
  lockrecord) chmod 444 "${PRE_GATE_LOG_DIR:?}/runs.jsonl"; res success false 'VERDICT: PASS' 0.42 ;;
  echo_template) res success false '# If PASS:\nnothing\n# If FAIL:\nVERDICT: PASS\nSummary: ok' 0.2 ;;
  # a result event that carries NO cost (or one that is not a usable number): the run was judged, the money is unknown
  nocost)    printf '{"type":"system","subtype":"init","model":"claude-sonnet-5-5"}\n{"type":"result","subtype":"success","is_error":false,"result":"VERDICT: PASS","num_turns":4}\n' ;;
  cost_str)  res success false 'VERDICT: PASS' '"abc"' ;;
  cost_neg)  res success false 'VERDICT: PASS' -1 ;;
  cost_null) res success false 'VERDICT: PASS' null ;;
  cost_bool) res success false 'VERDICT: PASS' true ;;
  cost_tiny) res success false 'VERDICT: PASS' 0.00005 ;;
  cost_int)  res success false 'VERDICT: PASS' 2 ;;
esac
exit 0
EOF
chmod +x "$T/bin/gc" "$T/bin/claude"

# run the script in the fixture; PRE_GATE_* point everything at the fixture, guards zeroed unless a test sets them
run_pg() {   # run_pg [ENV=VAL ...] -- <args>
  local envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  ( cd "$T/work" && env PATH="$T/bin:$PATH" STUB_DIR="$T/stub" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" \
      PRE_GATE_CLAUDE_BIN=claude PRE_GATE_MIN_DF_GIB=0 PRE_GATE_MIN_SWAP_MB=0 PRE_GATE_MIN_SYSTEM_CHARS=1000 GC_SESSION_NAME=builder-session GC_ALIAS=builder-alias \
      ${envs[@]+"${envs[@]}"} bash "$PG" "$@" 2>"$T/last.err" )
}
last_line() { tail -n 1 <<<"$1"; }
field() { sed -n "s/.*[ ]$2=\([^ ]*\).*/\1/p" <<<"$1" | head -n1; }   # field <line> <key>
reset_state() { rm -rf "$T/logs" "$T/stub"; mkdir -p "$T/stub"; }
ncalls() { ls "$T/stub"/call-*.argv 2>/dev/null | wc -l | tr -d ' '; }
# A launched run leaves TWO rows (PENDING before claude starts, the FINAL outcome after) tied by one run_id. A check on the OUTCOME
# must read the FINAL row only: the PENDING row also says launched=true / cost_known=false / the same bead, so a check on those
# fields over both rows would pass on the wrong one.
run_rows()     { grep '"event": "run"' "$T/logs/runs.jsonl" 2>/dev/null; }
final_rows()   { run_rows | grep -v '"verdict": "PENDING"'; }
pending_rows() { run_rows | grep '"verdict": "PENDING"'; }

echo "── 5. THREE OUTCOMES ──"
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?
eq "$rc" "0" "PASS → exit 0"; L="$(last_line "$OUT")"
eq "$(field "$L" verdict)" "PASS" "PASS → PREGATE_RESULT verdict=PASS"
eq "$(field "$L" arm)" "manual" "no --bead → arm=manual (outside the A/B)"
reset_state
OUT="$(run_pg STUB_MODE=fail -- run feat/x --no-fetch)"; rc=$?
eq "$rc" "10" "FAIL → exit 10"; L="$(last_line "$OUT")"
eq "$(field "$L" verdict)" "FAIL" "FAIL → verdict=FAIL"
has_str "$OUT" "Blocking issue 1: empty and error collapse in b.sh" "FAIL → the blocking issue is printed to the builder"
for mode in noverdict error garbage echo_template; do
  reset_state
  OUT="$(run_pg STUB_MODE=$mode -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
  case "$mode" in
    echo_template) eq "$rc" "0" "a verdict line at line start counts, even after echoed template lines (last VERDICT wins) → exit 0" ;;
    *) eq "$rc" "3" "STUB_MODE=$mode → INCONCLUSIVE exit 3 (never PASS)"; eq "$(field "$L" verdict)" "INCONCLUSIVE" "STUB_MODE=$mode → verdict=INCONCLUSIVE" ;;
  esac
done
reset_state
OUT="$(run_pg STUB_MODE=timeout PRE_GATE_TIMEOUT_SECS=1 -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "timeout → INCONCLUSIVE exit 3"; has_str "$L" "reason=timeout:1s" "timeout reason is named"

echo "── 5b. A RUN WHOSE COST IS UNKNOWN IS RECORDED AS UNKNOWN — NEVER AS \$0 ──"
# The builder console already prints "\$?" for a run with no result event, so the code KNEW it did not know. The record is
# what pre-gate-apuracao.py sums into "custo do pré-gate", and a 0 there reads as "free" on the very condition that decides
# whether to propose enabling the step for everyone. So: no cost_usd / turns key at all, and cost_known=false says so out loud.
rec_for() {   # rec_for <STUB_MODE> [ENV=VAL ...] — one run from a clean state; prints that run's record line
  local mode="$1"; shift; reset_state
  run_pg STUB_MODE="$mode" ${@+"$@"} -- run feat/x --no-fetch >/dev/null
  final_rows
}
REC="$(rec_for timeout PRE_GATE_TIMEOUT_SECS=1)"
has_str "$REC" '"launched": true' "timeout: the run is recorded as launched"
has_str "$REC" '"cost_known": false' "timeout: cost_known=false (the money is UNKNOWN)"
not_str "$REC" '"cost_usd"' "timeout: NO cost_usd key (a 0 would read as 'this run was free')"
not_str "$REC" '"turns"' "timeout: NO turns key either"
REC="$(rec_for garbage)"
has_str "$REC" '"cost_known": false' "garbage stream (claude exit 0, no result event): cost_known=false"
not_str "$REC" '"cost_usd"' "garbage stream: NO cost_usd key"
REC="$(rec_for nocost)"
has_str "$REC" '"verdict": "PASS"' "result event without a cost: the run is still judged (verdict PASS)"
has_str "$REC" '"cost_known": false' "…but its cost is unknown"
not_str "$REC" '"cost_usd"' "…so there is NO cost_usd key"
has_str "$REC" '"turns": 4' "…while turns, which it did report, is kept (known and unknown are decided per field)"
for mode in cost_str cost_neg cost_null cost_bool; do
  REC="$(rec_for "$mode")"
  has_str "$REC" '"cost_known": false' "STUB_MODE=$mode (total_cost_usd is not a usable number): cost_known=false"
  not_str "$REC" '"cost_usd"' "STUB_MODE=$mode: no cost_usd key (a string / negative / null / true is not a cost)"
done
REC="$(rec_for pass)"
has_str "$REC" '"cost_known": true' "a known cost: cost_known=true"; has_str "$REC" '"cost_usd": 0.42' "…with the exact figure"
REC="$(rec_for error)"
has_str "$REC" '"cost_known": true' "an error_max_budget run DID spend money: its cost is known"; has_str "$REC" '"cost_usd": 3.01' "…and it is recorded (the cap overrun is visible)"
REC="$(rec_for cost_tiny)"
has_str "$REC" '"cost_known": true' "a tiny cost (python prints it as 5e-05) is still KNOWN"; has_str "$REC" '"cost_usd": 5e-05' "…and recorded as a number, not dropped for its notation"
REC="$(rec_for cost_int)"
has_str "$REC" '"cost_known": true' "an integer cost is known"; has_str "$REC" '"cost_usd": 2.0' "…recorded as 2.0"

echo "── 5c. A PASS ON PART OF THE DIFF IS NOT A PASS (coverage: full / partial / unknown) ──"
# gate ga-0ygcas, third state: over GATE_DIFF_LINE_BUDGET the reviewer is shown only some of the files (the lib says so in the
# task: "PARTIAL DIFF — showing 1 of 3 files"). The script computed that, logged it, and then let a reviewer PASS on the part it
# saw end as `verdict=PASS reason=none`, exit 0 — the same text as a PASS on the whole diff, which Step 2b tells the builder is
# "no blocking defect found". Driven through `run` with a real small budget (a unit test of the lib would not have caught it:
# the lib was right, the outcome ladder ignored it).
G checkout -q -b feat/partial main
for n in 1 2 3; do i=0; : > "$T/work/p$n.txt"; while [ "$i" -lt 10 ]; do echo "line $n.$i" >> "$T/work/p$n.txt"; i=$((i+1)); done; done
G add p1.txt p2.txt p3.txt; G commit -q -m "three files"
reset_state
OUT="$(run_pg STUB_MODE=pass GATE_DIFF_LINE_BUDGET=20 -- run feat/partial --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
has_str "$(cat "$T/stub/call-1.stdin" 2>/dev/null)" "PARTIAL DIFF — showing 1 of 3 files" "fixture: the reviewer really was told PARTIAL DIFF, 1 of 3 files"
eq "$rc" "3" "reviewer PASS on 1 of 3 files → exit 3 (was: exit 0)"
eq "$(field "$L" verdict)" "INCONCLUSIVE" "…verdict=INCONCLUSIVE, never PASS"
eq "$(field "$L" reason)" "partial-diff:1/3-files" "…the reason carries the numbers"
eq "$(field "$L" coverage)" "partial:1/3" "…and the machine line carries the coverage"
has_str "$OUT" "── COVERAGE: partial:1/3" "the builder is told, in words, that the reviewer saw only part"
NOT_SHOWN="$(sed -n '/Files it was NOT shown/,$p' <<<"$OUT")"
has_str "$NOT_SHOWN" "p2.txt" "the files nobody reviewed are listed (p2.txt)"
has_str "$NOT_SHOWN" "p3.txt" "…(p3.txt)"
not_str "$NOT_SHOWN" "p1.txt" "…and the file that WAS shown is not listed as unreviewed"
has_str "$OUT" "not a clearance" "the console says the PASS is not a clearance"
REC="$(final_rows)"
has_str "$REC" '"launched": true' "record: the run was launched (money was spent)"
has_str "$REC" '"verdict": "INCONCLUSIVE"' "record: verdict INCONCLUSIVE"
has_str "$REC" '"reviewer_verdict": "PASS"' "record: what the reviewer actually said is kept (reviewer_verdict=PASS)"
has_str "$REC" '"coverage": "partial:1/3"' "record: coverage"
has_str "$REC" '"partial": true' "record: partial=true"
has_str "$REC" '"shown_files": 1' "record: shown_files=1"
has_str "$REC" '"total_files": 3' "record: total_files=3"
# a FAIL on part of the diff stands: a defect found is a defect. It still says what was not read.
reset_state
OUT="$(run_pg STUB_MODE=fail GATE_DIFF_LINE_BUDGET=20 -- run feat/partial --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "10" "reviewer FAIL on 1 of 3 files → still exit 10"
eq "$(field "$L" verdict)" "FAIL" "…verdict=FAIL stands"
eq "$(field "$L" coverage)" "partial:1/3" "…and says it was on a partial diff"
has_str "$OUT" "Files it was NOT shown" "…and lists what was not read"
has_str "$OUT" "does not clear the files above" "…and that fixing the defect does not clear them"
REC="$(final_rows)"
has_str "$REC" '"reviewer_verdict": "FAIL"' "record: reviewer_verdict=FAIL"; has_str "$REC" '"coverage": "partial:1/3"' "record: coverage=partial on the FAIL too"
# the dry run reports it as well (no money): a builder can see it before spending
reset_state
OUT="$(run_pg GATE_DIFF_LINE_BUDGET=20 -- run feat/partial --no-fetch --dry-run)"
has_str "$OUT" "coverage=partial:1/3" "dry run: coverage is reported"
G checkout -q feat/x
# the control: a diff inside the budget is FULL, and a PASS on it is a PASS, with no coverage warning
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "PASS on a full-coverage diff → exit 0 (the fix does not turn every PASS into INCONCLUSIVE)"
eq "$(field "$L" verdict)" "PASS" "…verdict=PASS"; eq "$(field "$L" reason)" "none" "…reason=none"; eq "$(field "$L" coverage)" "full" "…coverage=full"
not_str "$OUT" "── COVERAGE:" "…and no coverage warning"
REC="$(final_rows)"
has_str "$REC" '"coverage": "full"' "record: coverage=full"; has_str "$REC" '"partial": false' "record: partial=false"; has_str "$REC" '"reviewer_verdict": "PASS"' "record: reviewer_verdict=PASS"
# unknown coverage is the third state: a payload builder that does not report (unset) must not read as "saw it all"
reset_state
OUT="$( cd "$T/work" && export PATH="$T/bin:$PATH" STUB_DIR="$T/stub" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" PRE_GATE_CLAUDE_BIN=claude \
          PRE_GATE_MIN_DF_GIB=0 PRE_GATE_MIN_SWAP_MB=0 PRE_GATE_MIN_SYSTEM_CHARS=1000 STUB_MODE=pass
        eval "$(declare -f gate_build_diff_payload | sed '1s/gate_build_diff_payload/_real_gate_build_diff_payload/')"
        gate_build_diff_payload() { _real_gate_build_diff_payload "$@"; local _rc=$?; unset DIFF_COVERAGE; return "$_rc"; }
        pg_run feat/x --no-fetch 2>/dev/null )"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "builder that reports no coverage + reviewer PASS → exit 3"
eq "$(field "$L" verdict)" "INCONCLUSIVE" "…verdict=INCONCLUSIVE"; eq "$(field "$L" reason)" "coverage-unknown" "…reason=coverage-unknown"; eq "$(field "$L" coverage)" "unknown" "…coverage=unknown"
REC="$(final_rows)"
has_str "$REC" '"coverage": "unknown"' "record: coverage=unknown"; has_str "$REC" '"reviewer_verdict": "PASS"' "record: the reviewer's PASS is kept"
# a run that ended before any diff was read has no coverage to report — n/a, not "full"
reset_state
OUT="$(run_pg STUB_MODE=pass PRE_GATE_MIN_DF_GIB=99999999 -- run feat/x --no-fetch)"; L="$(last_line "$OUT")"
eq "$(field "$L" coverage)" "n/a" "a refusal before the diff is read reports coverage=n/a"

echo "── 5d. A PAID RUN ALWAYS LEAVES A ROW: PENDING before the spend, FINAL after, an interrupted run is settled (gate ga-dkdir3) ──"
# The bug: the run was recorded only AFTER claude finished. A run killed mid-review (TERM, INT, HUP, SIGKILL, a session drain, a
# reboot) — exactly the case where money was spent and nobody knows how much — left NO row: it did not count toward PRE_GATE_MAX_RUNS,
# the apuracao filed its bead under "never ran", and the arm's pre-gate cost was printed as EXATO with that spend left out. Driven with
# real signals against the real script (a stub reviewer that hangs), not by calling the record function.
run_pg_bg() {   # run_pg_bg [ENV=VAL ...] -- <args> — the script in the BACKGROUND; its pid in PG_BG, output in $T/bg.out / $T/bg.err
  local envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  # perl puts SIGINT/SIGQUIT back to their default first: a background job of a NON-interactive shell starts with them IGNORED, and a
  # signal that was ignored on entry can never be trapped — without this the INT case would test bash, not the script
  ( cd "$T/work" && exec perl -e '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; exec @ARGV' env PATH="$T/bin:$PATH" STUB_DIR="$T/stub" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" \
      PRE_GATE_CLAUDE_BIN=claude PRE_GATE_MIN_DF_GIB=0 PRE_GATE_MIN_SWAP_MB=0 PRE_GATE_MIN_SYSTEM_CHARS=1000 GC_SESSION_NAME=builder-session GC_ALIAS=builder-alias \
      ${envs[@]+"${envs[@]}"} bash "$PG" "$@" >"$T/bg.out" 2>"$T/bg.err" ) &
  PG_BG=$!
}
wait_for_file() { local f="$1" n="${2:-120}"; while [ ! -s "$f" ] && [ "$n" -gt 0 ]; do sleep 0.5; n=$((n - 1)); done; [ -s "$f" ]; }
tree_pids() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$c"; done; echo "$1"; }
run_ids() { python3 -c '
import json, sys
print(" ".join(str(r.get("run_id", "")) for r in map(json.loads, open(sys.argv[1])) if r.get("event") == "run" and r.get("launched") is True))' "$T/logs/runs.jsonl"; }
alive_any() { local p; for p in "$@"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
APUR="${APURACAO_UNDER_TEST:-$SELF_DIR/../../../scripts/pre-gate-apuracao.py}"
mk_contract_hq() {   # a minimal HQ around the fixture's real runs.jsonl, with one gate outcome for feat/x AFTER the assignment
  local hq="$T/hq-contract"; mkdir -p "$hq/packs/town-deltas/assets" "$hq/.gc/logs"
  cp "$PG" "$LIB" "$hq/packs/town-deltas/assets/"
  python3 - "$hq" <<'PY'
import sys, time
hq = sys.argv[1]; st = lambda e: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e))
now = time.time()
open(f"{hq}/.gc/logs/quality-gate-dispatcher.log", "w").write(
  f"[{st(now - 3600)}] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-old branch=other/x verdict=PASS elapsed=60s ===\n"
  f"[{st(now + 120)}] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-r1 branch=feat/x verdict=PASS elapsed=60s ===\n")
PY
  echo "$hq"
}

for spec in "TERM:143" "INT:130" "HUP:129"; do
  sig="${spec%%:*}"; want="${spec##*:}"
  reset_state
  run_pg_bg STUB_MODE=hang -- run feat/x --bead "$ON_BEAD" --no-fetch
  if wait_for_file "$T/stub/sleep.pid" 240; then ok "($sig) the reviewer is running (stub started)"; else bad "($sig) the stub reviewer never started"; fi
  STUB_PIDS="$(cat "$T/stub/stub.pid" 2>/dev/null) $(cat "$T/stub/sleep.pid" 2>/dev/null)"
  has_str "$(pending_rows)" '"verdict": "PENDING"' "($sig) WHILE the reviewer runs, the PENDING row is already on the log (written before the spend)"
  has_str "$(pending_rows)" '"cost_known": false' "($sig) …with cost_known=false (nothing is known yet)"
  t_sig=$SECONDS; kill -"$sig" "$PG_BG"; wait "$PG_BG"; rc=$?; took=$((SECONDS - t_sig))
  eq "$rc" "$want" "($sig) the script exits $want"
  [ "$took" -lt 60 ] && ok "($sig) it exited ${took}s after the signal — not after the 120s review (the trap is not held back by the foreground child)" || bad "($sig) it took ${took}s to act on the signal (held until the review finished?)"
  eq "$(run_rows | wc -l | tr -d ' ')" "2" "($sig) exactly two rows for the one run: PENDING + FINAL"
  IDS="$(run_ids)"; set -- $IDS
  [ "$#" -eq 2 ] && [ -n "$1" ] && [ "$1" = "$2" ] && ok "($sig) …tied by one run_id ($1)" || bad "($sig) the two rows do not share a run_id: [$IDS]"
  FINAL="$(final_rows)"
  has_str "$FINAL" "\"reason\": \"interrupted:$sig\"" "($sig) FINAL row: reason=interrupted:$sig (its own cause, not 'never ran')"
  has_str "$FINAL" '"verdict": "INCONCLUSIVE"' "($sig) …verdict=INCONCLUSIVE (a killed review judged nothing)"
  has_str "$FINAL" '"launched": true' "($sig) …launched=true (money was spent)"
  has_str "$FINAL" '"cost_known": false' "($sig) …cost_known=false"
  not_str "$FINAL" '"cost_usd"' "($sig) …and NO cost_usd key (the cost of an interrupted run is unknown, never 0)"
  has_str "$FINAL" "\"exit_code\": $want" "($sig) …exit_code=$want"
  has_str "$(cat "$T/bg.out")" "reason=interrupted:$sig" "($sig) the builder console gets a PREGATE_RESULT line naming the interruption"
  eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs "$ON_BEAD" bead)" "1" "($sig) the interrupted run counts as ONE run toward the per-bead cap (PENDING and FINAL are one run, not two)"
  n=20; while alive_any $STUB_PIDS && [ "$n" -gt 0 ]; do sleep 0.5; n=$((n - 1)); done
  if alive_any $STUB_PIDS; then
    bad "($sig) the reviewer process tree is STILL RUNNING after the script exited (pids: $STUB_PIDS) — an unattended run that keeps spending"; kill -TERM $STUB_PIDS 2>/dev/null
  else ok "($sig) the whole reviewer tree (claude and its child) was stopped — nothing keeps spending unattended"; fi
  if [ "$sig" = "TERM" ]; then
    # the consequence that matters: the next run for this bead sees the interrupted one, so the spend brake holds
    OUT="$(run_pg STUB_MODE=pass PRE_GATE_MAX_RUNS=1 -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
    eq "$rc" "0" "(TERM) with PRE_GATE_MAX_RUNS=1 the next run is SKIPPED, exit 0"; has_str "$L" "reason=max-runs" "(TERM) …reason=max-runs: the interrupted run consumed the cap"
    eq "$(ncalls)" "1" "(TERM) …and no second reviewer was launched"
    # writer -> reader: the REAL apuracao reads the REAL rows this script just wrote
    HQC="$(mk_contract_hq)"; APU_OUT="$(python3 "$APUR" --hq "$HQC" --runs "$T/logs/runs.jsonl" --min-n 1 2>&1)"
    has_str "$APU_OUT" "INTERROMPIDOS por sinal ou saída anormal (TERM/INT/HUP, dreno, abnormal-exit): on=1 off=0" "(TERM) apuracao: the run is listed as INTERROMPIDO"
    has_str "$APU_OUT" "rodaram a pré-revisão: 1 de 1 beads" "(TERM) apuracao: the bead is counted as having RUN the step (it did — it is not 'SEM REGISTRO')"
    not_str "$APU_OUT" "× SEM REGISTRO" "(TERM) apuracao: …and it is not filed under the 'never ran' bucket (\"não rodaram: N × SEM REGISTRO\")"
    has_str "$APU_OUT" "SEM custo conhecido: on=1 off=0" "(TERM) apuracao: the run is an unknown-cost run"
    not_str "$APU_OUT" "pré-gate = EXATO" "(TERM) apuracao: the pre-gate figure is NOT called EXATO while a launched run has no cost"
    has_str "$APU_OUT" "LIMITE INFERIOR" "(TERM) apuracao: …it is a lower bound"
    not_str "$APU_OUT" "Traceback" "(TERM) apuracao: no traceback"
  fi
done
set --

# a control that must NOT change: an uninterrupted run is still ONE run — PENDING + FINAL under one run_id, the FINAL carrying the result
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?
eq "$rc" "0" "control: an uninterrupted PASS run → exit 0"
eq "$(run_rows | wc -l | tr -d ' ')" "2" "control: two rows (PENDING + FINAL)"
IDS="$(run_ids)"; set -- $IDS; [ "$#" -eq 2 ] && [ -n "$1" ] && [ "$1" = "$2" ] && ok "control: …under one run_id" || bad "control: run_id differs or is empty: [$IDS]"; set --
has_str "$(final_rows)" '"cost_usd": 0.42' "control: the FINAL row carries the cost"; has_str "$(final_rows)" '"verdict": "PASS"' "control: …and the verdict"
not_str "$(final_rows)" "interrupted" "control: …and nothing says interrupted"
eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs "$ON_BEAD" bead)" "1" "control: pg_prior_runs counts it once"
# two runs of one bead are two run_ids (the counter is per process AND per run), and count 2
run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch >/dev/null
IDS="$(run_ids)"; set -- $IDS; eq "$(printf '%s\n' "$@" | sort -u | wc -l | tr -d ' ')" "2" "control: two runs of the same bead have two distinct run_ids"; set --
eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs "$ON_BEAD" bead)" "2" "control: …and count as 2"
# a launched row with NO run_id (a writer from before run_id) cannot be tied to any other row: each is its own run
reset_state; mkdir -p "$T/logs"
printf '%s\n' "{\"event\": \"run\", \"launched\": true, \"bead\": \"$ON_BEAD\"}" "{\"event\": \"run\", \"launched\": true, \"bead\": \"$ON_BEAD\"}" \
              "{\"event\": \"run\", \"launched\": true, \"bead\": \"$ON_BEAD\", \"run_id\": \"r1\", \"verdict\": \"PENDING\"}" "{\"event\": \"run\", \"launched\": true, \"bead\": \"$ON_BEAD\", \"run_id\": \"r1\", \"verdict\": \"PASS\"}" > "$T/logs/runs.jsonl"
eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs "$ON_BEAD" bead)" "3" "two id-less rows are two runs; a PENDING + FINAL pair sharing r1 is one → 3"

# SIGKILL cannot be trapped: only the PENDING row can be there, and it must be enough
reset_state
run_pg_bg STUB_MODE=hang -- run feat/x --bead "$ON_BEAD" --no-fetch
wait_for_file "$T/stub/sleep.pid" 240 && ok "(KILL) the reviewer is running" || bad "(KILL) the stub reviewer never started"
KTREE="$(tree_pids "$PG_BG")"
kill -KILL "$PG_BG"; wait "$PG_BG" 2>/dev/null; rc=$?
kill -TERM $KTREE 2>/dev/null   # the orphaned reviewers of THIS test (SIGKILL leaves them; the script could not stop them)
eq "$rc" "137" "(KILL) the script died of SIGKILL (137)"
eq "$(run_rows | wc -l | tr -d ' ')" "1" "(KILL) exactly one row: the PENDING one — no FINAL was possible"
has_str "$(pending_rows)" '"launched": true' "(KILL) …and it says launched=true: the spend is on the record"
eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs "$ON_BEAD" bead)" "1" "(KILL) a PENDING run with no FINAL still counts toward the cap"
OUT="$(run_pg STUB_MODE=pass PRE_GATE_MAX_RUNS=1 -- run feat/x --bead "$ON_BEAD" --no-fetch)"; L="$(last_line "$OUT")"
has_str "$L" "reason=max-runs" "(KILL) …so with PRE_GATE_MAX_RUNS=1 the next run is SKIPPED"
HQC="$(mk_contract_hq)"
APU_LIVE="$(python3 "$APUR" --hq "$HQC" --runs "$T/logs/runs.jsonl" --min-n 1 2>&1)"
has_str "$APU_LIVE" "EM CURSO (linha PENDING de ≤ 40 min — pode ainda terminar): on=1 off=0" "(KILL) apuracao: a FRESH PENDING is 'em curso' (the run may still be going) — not asserted dead"
APU_LOST="$(python3 "$APUR" --hq "$HQC" --runs "$T/logs/runs.jsonl" --min-n 1 --now "$(( $(date +%s) + 7200 ))" 2>&1)"
has_str "$APU_LOST" "SEM DESFECHO GRAVADO há mais de 40 min (SIGKILL, reboot, queda — só a linha PENDING ficou): on=1 off=0" "(KILL) apuracao: an OLD PENDING is 'sem desfecho gravado' (a run that ended without leaving an outcome)"
not_str "$APU_LOST" "pré-gate = EXATO" "(KILL) apuracao: …and its cost is unknown, so the pre-gate figure is not EXATO"
has_str "$APU_LOST" "SEM custo conhecido: on=1 off=0" "(KILL) apuracao: …it is counted as an unknown-cost run"

# the EXIT net: the shell leaves by a path that never reaches the final row (here: it dies right after the PENDING row is written)
reset_state
OUT="$( cd "$T/work" && export PATH="$T/bin:$PATH" STUB_DIR="$T/stub" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" PRE_GATE_CLAUDE_BIN=claude PRE_GATE_MIN_DF_GIB=0 PRE_GATE_MIN_SWAP_MB=0 PRE_GATE_MIN_SYSTEM_CHARS=1000 STUB_MODE=pass
        source "$PG"; trap pg_cleanup EXIT
        pg_log() { [ "${1#reviewing}" != "$1" ] && exit 9; return 0; }   # (no `case` in here: bash 3.2 cannot parse its `)` inside $( ))
        pg_run feat/x --bead "$ON_BEAD" --no-fetch 2>/dev/null )"; rc=$?
eq "$rc" "9" "(abnormal exit) the shell dies right after the PENDING row"
has_str "$(final_rows)" '"reason": "abnormal-exit"' "(abnormal exit) the EXIT net writes the FINAL row: reason=abnormal-exit"
has_str "$(final_rows)" '"launched": true' "(abnormal exit) …launched=true"; not_str "$(final_rows)" '"cost_usd"' "(abnormal exit) …and no invented cost"
eq "$(run_rows | wc -l | tr -d ' ')" "2" "(abnormal exit) …PENDING + FINAL, and no third row"
eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs "$ON_BEAD" bead)" "1" "(abnormal exit) …counted once"
# idempotent: settling twice writes one row
( source "$PG"; export PRE_GATE_LOG_DIR="$T/logs" PRE_GATE_CITY="$T/city"; PG_LIVE_ID=rid-x; PG_LIVE_KV=(bead=b1 branch=br1)
  pg_settle_live INCONCLUSIVE interrupted:TERM cost_known=false; pg_settle_live INCONCLUSIVE abnormal-exit cost_known=false; pg_cleanup )
eq "$(grep -c '"run_id": "rid-x"' "$T/logs/runs.jsonl")" "1" "settling an already-settled run (a second signal, then the EXIT net) writes exactly ONE row"

# the PENDING row cannot be written: the spend is refused, not made blind
reset_state; mkdir -p "$T/logs/slots"; : > "$T/logs/runs.jsonl"; chmod 444 "$T/logs/runs.jsonl"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"; chmod 644 "$T/logs/runs.jsonl"
eq "$rc" "3" "the PENDING row cannot be written → INCONCLUSIVE exit 3"; has_str "$L" "reason=record-unwritable" "…reason=record-unwritable"
eq "$(ncalls)" "0" "…and claude was NEVER launched (a spend that cannot be recorded is not made)"
# the FINAL row cannot be written: the run still happened, its PENDING row stands, and the builder is told
# (the stub reviewer makes the log read-only while it runs, so the failure is a real one, at the real moment)
reset_state
OUT="$(run_pg STUB_MODE=lockrecord -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"; chmod 644 "$T/logs/runs.jsonl" 2>/dev/null
eq "$rc" "0" "the FINAL row cannot be written: the run's own outcome (PASS) still stands, exit 0"
has_str "$(cat "$T/last.err")" "could NOT be written" "…and the builder is told the outcome was not written"
has_str "$(cat "$T/last.err")" "PENDING" "…and told what stands in its place (the provisional PENDING row)"
eq "$(run_rows | wc -l | tr -d ' ')" "1" "…the log has the PENDING row only"
eq "$(PRE_GATE_LOG_DIR="$T/logs" pg_prior_runs feat/x branch)" "1" "…and that PENDING row counts toward the cap"

# an exit 127 AFTER launch is claude / nice / env failing to exec — not "there is no timeout tool"
reset_state
OUT="$(run_pg STUB_MODE=exit127 -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "claude exits 127 → INCONCLUSIVE"; has_str "$L" "reason=no-result:claude-exit-127" "…reason names the exit code of claude"; not_str "$L" "no-timeout-tool" "…and is NOT misfiled as 'no-timeout-tool'"
# whether anything can bound the run is asked BEFORE launching
r="$(env PATH=/nonexistent /bin/bash -c 'source "'"$PG"'" 2>/dev/null; pg_have_timeout_tool; echo "rc=$?"')"
eq "$r" "rc=1" "no timeout / gtimeout / perl on PATH → pg_have_timeout_tool fails (refused before any launch, reason no-timeout-tool)"
pg_have_timeout_tool && ok "this machine has a way to bound a run" || bad "pg_have_timeout_tool is false on a machine with perl"

echo "── 6. EVERY WAY OF NOT BEING ABLE TO JUDGE IS INCONCLUSIVE ──"
reset_state
OUT="$(run_pg STUB_MODE=pass PRE_GATE_MIN_DF_GIB=99999999 -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "disk below the floor → INCONCLUSIVE"; has_str "$L" "machine-guard:disk-low" "reason names the disk guard"; eq "$(ncalls)" "0" "guard refusal → claude never launched"
# swap + unreadable readings, through the seams (sourced functions), not the real machine
pg_df_avail_gib() { echo 50; }; pg_swap_mb() { echo "4096 100"; }
r="$(pg_machine_guard)"; eq "$?" "1" "swap free below the floor → refuse"; has_str "$r" "swap-low" "reason names swap"
pg_swap_mb() { echo "0 0"; }; r="$(pg_machine_guard)"; eq "$?" "0" "swap total 0 (none allocated) → no floor to hold → allow"
pg_swap_mb() { :; };          r="$(pg_machine_guard)"; eq "$?" "1" "swap unreadable → refuse (cannot tell = inert)"; has_str "$r" "swap-unreadable" "reason says unreadable"
pg_df_avail_gib() { :; };     r="$(pg_machine_guard)"; eq "$?" "1" "df unreadable → refuse"
unset -f pg_df_avail_gib pg_swap_mb; source "$PG"
reset_state; echo dirty >> "$T/work/a.txt"
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "dirty worktree → INCONCLUSIVE"; has_str "$L" "reason=dirty-worktree" "reason names the dirty tree"
G checkout -q -- a.txt
reset_state; G checkout -q main
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "HEAD not on the branch under review → INCONCLUSIVE"; has_str "$L" "head-not-at-branch" "reason says HEAD is off the branch"
G checkout -q feat/x
reset_state
OUT="$(run_pg -- run feat/nope --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "unknown branch → INCONCLUSIVE"; has_str "$L" "head-unresolved" "reason names the unresolved head"
reset_state; G checkout -q -b feat/empty main
OUT="$(run_pg -- run feat/empty --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "empty diff → INCONCLUSIVE (nothing to review is not a pass)"; has_str "$L" "reason=empty-diff" "reason names the empty diff"
G checkout -q feat/x
# `git diff base...head` FAILS while --name-only and --stat still work: file_count > 0 but there is no diff TEXT. The shared
# payload builder turns that into "FULL DIFF (complete — 0 lines across N file(s), nothing omitted)" over a blank body, and a
# reviewer that was shown nothing can answer PASS — a clearance for code it never saw, handed to the builder. Refuse instead.
REAL_GIT="$(command -v git)"; mkdir -p "$T/shim"
cat > "$T/shim/git" <<SHIM
#!/bin/bash
has_diff=0; has_list=0
for a in "\$@"; do case "\$a" in diff) has_diff=1 ;; --name-only|--stat) has_list=1 ;; esac; done
if [ \$has_diff -eq 1 ] && [ \$has_list -eq 0 ]; then echo "fatal: simulated git diff failure" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$T/shim/git"
reset_state
OUT="$(run_pg PATH="$T/shim:$T/bin:$PATH" STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "git diff fails but --name-only lists files → INCONCLUSIVE (a blank body is not a diff to clear)"
has_str "$L" "reason=diff-text-empty" "…reason names it: the file list and the diff text disagree"
eq "$(ncalls)" "0" "…and claude never launched (nothing spent on a review of nothing)"
rm -rf "$T/shim"
# busy: hold both slots with LIVE pids
reset_state; mkdir -p "$T/logs/slots/1" "$T/logs/slots/2"; sleep 30 & S1=$!; sleep 30 & S2=$!
echo $S1 > "$T/logs/slots/1/pid"; echo $S2 > "$T/logs/slots/2/pid"
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "all concurrency slots held by live processes → INCONCLUSIVE"; has_str "$L" "reason=busy" "reason says busy"; eq "$(ncalls)" "0" "busy → claude never launched"
kill "$S1" "$S2" 2>/dev/null; wait "$S1" "$S2" 2>/dev/null
# a slot whose owner is dead is reclaimed
reset_state; mkdir -p "$T/logs/slots/1" "$T/logs/slots/2"; echo 999999 > "$T/logs/slots/1/pid"; echo 999998 > "$T/logs/slots/2/pid"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?; eq "$rc" "0" "stale slots (dead pids) are reclaimed and the run proceeds"
# the run needed ONE slot: it reclaimed slot 1 and must have released it; slot 2 was never touched (still stale, harmless)
[ ! -d "$T/logs/slots/1" ] && ok "the slot the run took is released after the run" || bad "the slot the run took leaked"
# a slot with NO pid yet and a FRESH mtime is a slot being taken right now (mkdir done, pid not yet written): held, not stolen
reset_state; mkdir -p "$T/logs/slots/1" "$T/logs/slots/2"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "pid-less FRESH slots are treated as held (an owner may be mid-acquire)"; has_str "$L" "reason=busy" "…reason says busy"
# a slot that NEVER got a pid and is old is a crashed acquire (owner died between mkdir and the pid write): reclaimed, not held forever
reset_state; mkdir -p "$T/logs/slots/1" "$T/logs/slots/2"; touch -t 202001010000 "$T/logs/slots/1"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?
eq "$rc" "0" "an OLD pid-less slot (crashed acquire) is reclaimed and the run proceeds — it is not held forever"
[ ! -d "$T/logs/slots/1" ] && ok "…and the reclaimed slot is released afterwards" || bad "…the reclaimed slot leaked"
ls "$T/logs/slots" 2>/dev/null | grep -q 'abandoned' && bad "takeover leftovers in the slots dir: $(ls "$T/logs/slots" | tr '\n' ' ')" || ok "…(no *.abandoned.* entries in the slots dir)"
# the slots directory CANNOT be created: that is a fault, not a busy machine — the reason must say which
reset_state; mkdir -p "$T/logs"; : > "$T/logs/slots"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "slots dir cannot be created → INCONCLUSIVE"; has_str "$L" "reason=slots-unusable" "…reason names the fault"; not_str "$L" "reason=busy" "…and it is NOT reported as busy"; eq "$(ncalls)" "0" "…and claude never launched"
# claude missing
reset_state
OUT="$(run_pg PRE_GATE_CLAUDE_BIN=/nonexistent/claude -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "claude not found → INCONCLUSIVE"; has_str "$L" "claude-not-found" "reason names it"
# reviewer config unresolved: never guess a model
reset_state; mv "$T/city/city.toml" "$T/city/city.toml.off"
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "live config unreadable → INCONCLUSIVE (a guessed model would measure a different reviewer)"; has_str "$L" "reviewer-config-unresolved" "reason names it"
mv "$T/city/city.toml.off" "$T/city/city.toml"
# gc prime: failing, returning the WRONG role, or too short — three different reasons, all INCONCLUSIVE
reset_state; mv "$T/bin/gc" "$T/bin/gc.real"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/gc"; chmod +x "$T/bin/gc"
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "gc prime fails → INCONCLUSIVE"; has_str "$L" "gc-prime-failed" "reason: gc-prime-failed"
# the generic fallback prompt gc prints (exit 0!) when it cannot resolve the city: valid-looking, right size, WRONG role
{ printf '#!/bin/bash\necho "# Gas City Agent"\n'; i=0; while [ $i -lt 60 ]; do printf 'echo "fallback prompt padding line %s padding padding padding"\n' "$i"; i=$((i+1)); done; } > "$T/bin/gc"
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "gc prime returns the generic fallback prompt (exit 0, plausible size) → INCONCLUSIVE, not a rehearsal under the wrong role"
has_str "$L" "wrong-role" "reason: wrong-role"; eq "$(ncalls)" "0" "wrong role → claude never launched"
printf '#!/bin/bash\necho "# Gate Reviewer"\necho tiny\n' > "$T/bin/gc"
OUT="$(run_pg -- run feat/x --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "gc prime returns the right heading but a truncated body → INCONCLUSIVE"; has_str "$L" "too-short" "reason: too-short"
mv "$T/bin/gc.real" "$T/bin/gc"

echo "── 7. A/B: the control arm spends nothing, the on arm runs, both are on the roster ──"
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$OFF_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "control arm → exit 0"; eq "$(field "$L" verdict)" "SKIPPED" "control arm → verdict=SKIPPED"; has_str "$L" "reason=control-arm" "control arm → reason names it"
eq "$(ncalls)" "0" "control arm → claude never launched (no spend)"
ROSTER="$(cat "$T/logs/runs.jsonl" 2>/dev/null)"
has_str "$ROSTER" "\"bead\": \"$OFF_BEAD\"" "control bead is on the roster"; has_str "$ROSTER" '"arm": "off"' "roster records arm=off"; has_str "$ROSTER" '"event": "assign"' "roster row is an assign event"
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "on arm → runs and passes"; eq "$(field "$L" arm)" "on" "on arm → arm=on"; eq "$(ncalls)" "1" "on arm → claude launched exactly once"
REC="$(cat "$T/logs/runs.jsonl")"
has_str "$REC" '"event": "assign"' "on-arm bead is on the roster too"; has_str "$REC" '"event": "run"' "and its run is recorded"
has_str "$REC" '"launched": true' "run record: launched=true"; has_str "$REC" '"cost_usd": 0.42' "run record: exact cost from the result event"
has_str "$REC" '"model_resolved": "claude-sonnet-5-5"' "run record: the model that actually answered"; has_str "$REC" '"verdict": "PASS"' "run record: verdict"
has_str "$REC" '"effort": "xhigh"' "run record: effort read from city.toml"
# `--bead ""` (an unset variable) is refused, never silently read as "no bead = manual mode"
# --base / --head with no value (an unset variable expands to nothing) are usage errors — never a silent fall back to the default ref
for flag in --base --head; do
  reset_state
  OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch "$flag")"; rc=$?
  eq "$rc" "2" "$flag as the last argument (no value) → usage error exit 2"; eq "$(ncalls)" "0" "$flag with no value → claude never launched"
  OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch "$flag" "")"; rc=$?
  eq "$rc" "2" "$flag \"\" (unset variable) → usage error exit 2, not the default ref"; eq "$(ncalls)" "0" "$flag \"\" → claude never launched"
done
# --lens N renders "reviewer N of N": the impossible "2 of 1" named a reviewer that cannot exist
for n in 1 2 3; do
  T_N="$(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" GC_ALIAS=builder-alias bash "$PG" run feat/x --no-fetch --lens "$n" --print-task 2>/dev/null)"
  has_str "$T_N" "You are reviewer $n of $n for branch: feat/x" "--lens $n renders 'reviewer $n of $n'"
done
# a run-log line that is valid JSON but not a record (12, null, [..], a string) is skipped like a corrupt line — it must not
# turn every bead INCONCLUSIVE forever; the valid record next to it is still counted
reset_state; mkdir -p "$T/logs"
printf '%s\n' '12' 'null' '[1,2]' '"str"' "{\"event\": \"run\", \"launched\": true, \"bead\": \"$ON_BEAD\"}" > "$T/logs/runs.jsonl"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "non-object JSON lines in runs.jsonl do not make the log 'unreadable'"; not_str "$L" "runs-log-unreadable" "…no runs-log-unreadable"
eq "$(field "$L" attempt)" "2" "…and the valid launched record beside them is still counted (attempt 2)"
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "" --no-fetch)"; rc=$?
eq "$rc" "2" "--bead with an empty id → usage error exit 2 (not a silent manual-mode run)"; eq "$(ncalls)" "0" "--bead \"\" → claude never launched"
# no sha256 tool → the bead has no arm: INCONCLUSIVE, off the roster, nothing spent — neither 'off' nor 'on'
reset_state
OUT="$( cd "$T/work" && export PATH="$T/bin:$PATH" STUB_DIR="$T/stub" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" PRE_GATE_CLAUDE_BIN=claude PRE_GATE_MIN_DF_GIB=0 PRE_GATE_MIN_SWAP_MB=0 PRE_GATE_MIN_SYSTEM_CHARS=1000
        source "$PG"; pregate_arm_for_bead() { return 3; }; pg_main run feat/x --bead ga-noarm --no-fetch 2>/dev/null )"; rc=$?
L="$(last_line "$OUT")"
eq "$rc" "3" "arm cannot be computed → INCONCLUSIVE exit 3"; has_str "$L" "arm=unknown" "the arm is reported as unknown, not off"; has_str "$L" "reason=arm-unavailable" "reason names it"
eq "$(ncalls)" "0" "no arm → claude never launched"; [ ! -s "$T/logs/runs.jsonl" ] && ok "no arm → not on the roster" || bad "an arm-less bead was written to the roster"
# --force on a control-arm bead runs, and the record says so (the apuracao flags a contaminated control)
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$OFF_BEAD" --no-fetch --force)"; rc=$?
eq "$rc" "0" "--force on a control bead runs"; eq "$(ncalls)" "1" "--force launches claude"
has_str "$(cat "$T/logs/runs.jsonl")" '"forced": true' "a forced run is recorded as forced"
reset_state; run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch >/dev/null
has_str "$(cat "$T/logs/runs.jsonl")" '"forced": false' "a normal run is recorded as not forced"
# `roster` (gate-done Step 3): every submission lands on the roster, run or not, and the arm is printed for the label
reset_state
OUT="$(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" bash "$PG" roster "$ON_BEAD" feat/x 2>/dev/null)"; rc=$?
eq "$rc" "0" "roster → exit 0"; eq "$OUT" "on" "roster prints the arm for the marker label ($ON_BEAD → on)"
REC="$(cat "$T/logs/runs.jsonl" 2>/dev/null)"
has_str "$REC" '"event": "assign"' "roster writes an assign row"; has_str "$REC" "\"bead\": \"$ON_BEAD\"" "…for this bead"; has_str "$REC" '"source": "gate-done"' "…tagged as coming from gate-done"
eq "$(ncalls)" "0" "roster never launches claude"
OUT="$(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" bash "$PG" roster "$OFF_BEAD" feat/x 2>/dev/null)"
eq "$OUT" "off" "roster on a control bead prints off (and records it: the control arm is on the roster too)"
(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" bash "$PG" roster "" feat/x >/dev/null 2>&1); eq "$?" "2" "roster with an empty bead id → exit 2 (usage), not an arm"
(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs" bash "$PG" roster "$ON_BEAD" >/dev/null 2>&1); eq "$?" "2" "roster with no branch → exit 2"
# a roster write that FAILS must not withhold the arm (the label still goes on) — and must say so, on stderr AND in the
# exit status: /gate-done Step 3 tells "arm ok, roster missing" (4) from "all recorded" (0) and from "no arm" (3) by it
: > "$T/notadir"
OUT="$(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/notadir/sub" bash "$PG" roster "$ON_BEAD" feat/x 2>"$T/roster.err")"; rc=$?
eq "$OUT" "on" "roster write fails → the arm is still printed"; has_str "$(cat "$T/roster.err")" "could NOT be written to the roster" "…and the failure is reported on stderr, not swallowed"
eq "$rc" "4" "…and the exit status is 4 (arm printed, roster row NOT written), not 0"
# the arm cannot be computed (no sha256 tool): nothing printed, exit 3 — never an arm, never "off"
OUT="$( cd "$T/work" && export PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" PRE_GATE_LOG_DIR="$T/logs"
        source "$PG"; pregate_arm_for_bead() { return 3; }; pg_main roster "$ON_BEAD" feat/x 2>/dev/null )"; rc=$?
eq "$rc" "3" "roster: arm cannot be computed → exit 3"; eq "$OUT" "" "…and no arm is printed (unknown must not read as on or off)"
# an EXISTING but unreadable run log must not read as "0 runs so far" (that would silently lift the spend cap)
reset_state; mkdir -p "$T/logs/runs.jsonl"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "3" "run log exists but cannot be read → INCONCLUSIVE (never 'zero runs so far')"; has_str "$L" "reason=runs-log-unreadable" "reason names it"; eq "$(ncalls)" "0" "unreadable run log → claude never launched"
# the other way to be unreadable: a real file with no read permission (the -r test, not the parse failure above)
reset_state; mkdir -p "$T/logs"; printf '%s\n' '{"event":"run","bead":"x","launched":true}' > "$T/logs/runs.jsonl"; chmod 000 "$T/logs/runs.jsonl"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
chmod 600 "$T/logs/runs.jsonl"
eq "$rc" "3" "run log with no read permission → INCONCLUSIVE"; has_str "$L" "reason=runs-log-unreadable" "…same named reason"; eq "$(ncalls)" "0" "…and claude never launched"
reset_state
# dry run assigns nothing and records nothing
reset_state
OUT="$(run_pg -- run feat/x --bead "$ON_BEAD" --no-fetch --dry-run)"; rc=$?
eq "$rc" "0" "--dry-run → exit 0"; [ ! -e "$T/logs/runs.jsonl" ] && ok "--dry-run writes no record and no roster row" || bad "--dry-run wrote to runs.jsonl"; eq "$(ncalls)" "0" "--dry-run never launches claude"
has_str "$OUT" "PREGATE_DRYRUN model=sonnet effort=xhigh config=live" "--dry-run reports the live model + effort"
# the per-bead run cap: 3 launched runs, the 4th is SKIPPED without spending
reset_state
for n in 1 2 3; do run_pg STUB_MODE=fail -- run feat/x --bead "$ON_BEAD" --no-fetch >/dev/null; done
eq "$(ncalls)" "3" "three runs launched"
OUT="$(run_pg STUB_MODE=fail -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "4th run → exit 0 (submit to the gate)"; has_str "$L" "verdict=SKIPPED" "4th run → SKIPPED"; has_str "$L" "reason=max-runs" "4th run → reason=max-runs"; eq "$(ncalls)" "3" "4th run → no claude launch"
# a guard refusal must NOT consume an attempt
reset_state
run_pg PRE_GATE_MIN_DF_GIB=99999999 -- run feat/x --bead "$ON_BEAD" --no-fetch >/dev/null
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; L="$(last_line "$OUT")"
eq "$(field "$L" attempt)" "1" "an INCONCLUSIVE guard refusal does not burn an attempt (next run is attempt 1)"

echo "── 8. WHAT REACHES claude: same task, live model/effort, read-only tools, sanitized env ──"
reset_state
run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch >/dev/null
ARGV="$(cat "$T/stub/call-1.argv")"; STDIN="$(cat "$T/stub/call-1.stdin")"; ENVF="$(cat "$T/stub/call-1.env")"
has_str "$ARGV" $'--model\nsonnet' "model = the live agent.toml model"
has_str "$ARGV" $'--effort\nxhigh' "effort = the live city.toml effort for gate-reviewer (not refino-gate-reviewer's 'high')"
has_str "$ARGV" $'--permission-mode\ndontAsk' "permission mode dontAsk (deny everything not allowed)"
has_str "$ARGV" $'--tools\nRead,Grep,Glob,Bash' "tool set is read-only"
has_str "$ARGV" "Bash(git diff:*)" "read-only git is allowed"
not_str "$ARGV" "Edit" "no Edit/Write in the allowed tools"; not_str "$ARGV" "dangerously-skip-permissions" "no permission bypass"
has_str "$ARGV" "FAKE-GC-PRIME-GATE-REVIEWER" "system prompt = the live gc prime gate-reviewer output"
has_str "$ARGV" "PRE-GATE SELF-REVIEW OVERRIDE" "system prompt carries the pre-gate override (no bd/gc, final-text verdict)"
has_str "$ARGV" $'--max-budget-usd\n3' "spend is capped per call"
has_str "$ARGV" $'--setting-sources\n' "user/project settings sources are off"
has_str "$ENVF" "GC_SESSION_NAME=unset" "the builder's GC_SESSION_NAME is not leaked into the reviewer"
has_str "$ENVF" "GC_ALIAS=unset" "the builder's GC_ALIAS is not leaked into the reviewer"
has_str "$ENVF" "PWD=" "reviewer cwd recorded"
# the settings file it was given: live deny list kept, hooks gone, read-only denies added
SET="$(printf '%s\n' "$ARGV" | sed -n '/^--settings$/{n;p;}')"
# (the temp settings file is removed after the run; assert on a dry-run copy through the same helper)
"$BASH32" -c 'true' && ok "/bin/bash present"
SETF="$T/settings.check.json"; kind="$(PRE_GATE_CITY="$T/city" pg_settings_file "$SETF" "$T/work")"
eq "$kind" "live" "settings come from the live gate-reviewer settings.json"
has_str "$(cat "$SETF")" '"Bash(sudo:*)"' "live deny list preserved"; has_str "$(cat "$SETF")" '"Write"' "Write denied"; has_str "$(cat "$SETF")" '"Edit"' "Edit denied"
not_str "$(cat "$SETF")" '"hooks"' "hooks stripped"
kind="$(PRE_GATE_CITY="$T/nocity" pg_settings_file "$T/settings.fallback.json" "$T/work")"; eq "$kind" "fallback" "no live settings → 'fallback', visible (never silently 'live')"
# the task the reviewer got == the lib render for the same inputs, and is what --print-task shows
EXP_TASK="$(cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$T/city" GC_ALIAS=builder-alias PRE_GATE_RIG=work bash "$PG" run feat/x --no-fetch --print-task 2>/dev/null | sed '$d')"
[ -n "$EXP_TASK" ] && ok "--print-task prints the task" || bad "--print-task printed nothing"
STDIN_RIG="$(sed -n 's/^Rig: //p' <<<"$STDIN" | head -n1)"
has_str "$STDIN" "QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: feat/x" "stdin task: same header the gate renders"
has_str "$STDIN" "Author (EXCLUDED from reviewing): builder-alias" "author = the builder's identity"
has_str "$STDIN" "YOUR REVIEW LENS: CORRECTNESS" "lens 1 (the lens the live gate runs, GATE_CODE_REVIEWERS=1)"
has_str "$STDIN" "FULL DIFF (complete" "diff header is the gate's own"
has_str "$STDIN" "+echo hi" "the diff itself is in the task"
has_str "$STDIN" "REFUTATION PASS" "judging text present"
not_str "$STDIN" 'bd -C' "no bd commands in the builder's task"
# stdin == --print-task except for the Rig line (basename differs by design) — compare the judging text
A_J="${STDIN%%$seam*}"; B_J="${EXP_TASK%%$seam*}"
A_J="$(sed '/^Rig: /d' <<<"$A_J")"; B_J="$(sed '/^Rig: /d' <<<"$B_J")"
eq "$A_J" "$B_J" "--print-task shows exactly what claude is sent"

echo "── 9. IT WRITES NOTHING TO THE GATE ──"
# behavioural, not a grep of prose: put recording shims for bd and gc on PATH, do a full on-arm run, and look at what was called
reset_state
printf '#!/bin/bash\necho "$*" >> "$STUB_DIR/bd-calls.txt"\nexit 0\n' > "$T/bin/bd"; chmod +x "$T/bin/bd"
cp "$T/bin/gc" "$T/bin/gc.orig"
{ printf '#!/bin/bash\necho "$*" >> "$STUB_DIR/gc-calls.txt"\n'; sed '1d' "$T/bin/gc.orig"; } > "$T/bin/gc"; chmod +x "$T/bin/gc"
run_pg STUB_MODE=fail -- run feat/x --bead "$ON_BEAD" --no-fetch >/dev/null
[ ! -s "$T/stub/bd-calls.txt" ] && ok "a full run made ZERO bd calls (no marker, no verdict bead, no label, no comment)" || bad "the run called bd: $(cat "$T/stub/bd-calls.txt")"
eq "$(sed 's#^--city [^ ]* ##' "$T/stub/gc-calls.txt" 2>/dev/null | sort -u)" "prime gate-reviewer" "the only gc call is 'prime gate-reviewer' with an explicit --city (read-only: no mail, session, sling or nudge)"
has_str "$(cat "$T/stub/gc-calls.txt" 2>/dev/null)" "--city $(cd "$T/city" && pwd) prime gate-reviewer" "gc prime is pointed at the city explicitly (a cwd outside the city would otherwise get the fallback prompt)"
mv "$T/bin/gc.orig" "$T/bin/gc"; rm -f "$T/bin/bd"
# and the source carries no gate-state vocabulary outside comments and the prompt override
if grep -vE '^\s*#' "$PG" | grep -qE 'quality-gate-marker|gate-status|type:quality-gate|label add|comment "'; then bad "the script names gate state (marker/status/label/comment)"; else ok "the script names no gate state (marker / gate-status / label / comment)"; fi
eq "$(git -C "$T/origin.git" for-each-ref --format='%(refname)' | grep -c 'gate\|marker')" "0" "nothing gate-shaped appeared in the fixture origin"

echo "── 10. THE PROGRAM SWITCH: <city>/.gc/pregate.off ends the A/B (ga-ufskhy.1) ──"
# With the file, `run` starts no claude and `roster` writes no row; without it nothing changes; a file the script cannot tell
# present from absent is read as SET (the inert state). Every "nothing" is checked on the artifact — the claude stub's call
# log and the run log itself — never on what the script says about itself. The stub FAILS the test by being called at all.
OFFF="$T/city/.gc/pregate.off"
roster_pg() {   # roster_pg <city> <bead> — stdout is the arm; stderr goes to $T/roster.err; the exit status is roster's
  ( cd "$T/work" && env PATH="$T/bin:$PATH" PRE_GATE_CITY="$1" PRE_GATE_LOG_DIR="$T/logs" bash "$PG" roster "$2" feat/x 2>"$T/roster.err" )
}
log_state() { if [ -e "$T/logs/runs.jsonl" ]; then cksum < "$T/logs/runs.jsonl"; else echo "no-log"; fi; }

# A. the switch is absent: roster records, run launches — the behaviour every earlier section already pins, here beside the set case
reset_state; rm -f "$OFFF"
OUT="$(roster_pg "$T/city" "$ON_BEAD")"; rc=$?
eq "$rc" "0" "switch absent → roster exit 0"; eq "$OUT" "on" "switch absent → roster prints the arm"
has_str "$(cat "$T/logs/runs.jsonl" 2>/dev/null)" '"event": "assign"' "switch absent → roster writes its row"

# B. the switch is set: an on-arm bead — the one that would have cost ~US\$3
reset_state; : > "$OFFF"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "switch set → run exits 0 (the builder goes to Step 3)"
eq "$(field "$L" verdict)" "SKIPPED" "switch set → verdict=SKIPPED"; eq "$(field "$L" reason)" "program-off" "switch set → reason=program-off"
eq "$(field "$L" arm)" "on" "…and the result line still names the arm the bead has ($ON_BEAD → on)"
eq "$(ncalls)" "0" "switch set → claude was never launched (an on-arm bead)"
[ ! -e "$T/logs/runs.jsonl" ] && ok "switch set → NO row of any kind (no assign, no run, no PENDING)" || bad "switch set → run wrote to the log: $(cat "$T/logs/runs.jsonl")"
[ ! -e "$T/logs/slots" ] && ok "switch set → no concurrency slot was taken" || bad "switch set → a slot directory appeared"
has_str "$(cat "$T/last.err")" "program is over" "switch set → stderr says the program is over (the builder is told why nothing ran)"

# C. a control-arm bead says program-off, not control-arm, and writes no assign row either
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$OFF_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$(field "$L" reason)" "program-off" "control-arm bead → reason=program-off (not control-arm)"; eq "$(field "$L" arm)" "off" "…arm=off"
[ ! -e "$T/logs/runs.jsonl" ] && ok "control-arm bead → no assign row after the end" || bad "control-arm bead → the roster grew: $(cat "$T/logs/runs.jsonl")"

# D. manual mode (no --bead), --dry-run and --print-task all stop at the switch; --force does not get past it
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --no-fetch)"; L="$(last_line "$OUT")"
eq "$(field "$L" verdict)" "SKIPPED" "manual run (no --bead) → SKIPPED"; eq "$(field "$L" arm)" "manual" "…arm=manual"; eq "$(ncalls)" "0" "…no claude"
OUT="$(run_pg -- run feat/x --bead "$ON_BEAD" --no-fetch --dry-run)"
eq "$(field "$(last_line "$OUT")" reason)" "program-off" "--dry-run → program-off"; not_str "$OUT" "PREGATE_DRYRUN" "--dry-run prints no PREGATE_DRYRUN line"
OUT="$(run_pg -- run feat/x --no-fetch --print-task)"
eq "$(field "$(last_line "$OUT")" reason)" "program-off" "--print-task → program-off"; not_str "$OUT" "QUALITY GATE REVIEW" "--print-task prints no task"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$OFF_BEAD" --no-fetch --force)"; rc=$?
eq "$(field "$(last_line "$OUT")" reason)" "program-off" "--force does not get past the switch"; eq "$(ncalls)" "0" "…and still launches no claude"

# E. a malformed call is still a malformed call
run_pg STUB_MODE=pass -- run feat/x --bead "" --no-fetch >/dev/null; eq "$?" "2" "switch set + --bead \"\" → still exit 2"
run_pg STUB_MODE=pass -- run --no-fetch >/dev/null; eq "$?" "2" "switch set + no <branch> → still exit 2"

# F. roster: no row, no arm, exit 5 — and the history already on the log is left byte-for-byte alone
reset_state; mkdir -p "$T/logs"; printf '%s\n' '{"arm": "on", "bead": "ga-old", "event": "assign"}' > "$T/logs/runs.jsonl"
BEFORE="$(log_state)"
OUT="$(roster_pg "$T/city" "$ON_BEAD")"; rc=$?
eq "$rc" "5" "switch set → roster exit 5 (no arm assigned, nothing recorded)"; eq "$OUT" "" "…and NO arm on stdout (Step 3 would stamp a pregate:<arm> label on it)"
has_str "$(cat "$T/roster.err")" "program is over" "…and stderr names the reason"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"
eq "$(log_state)" "$BEFORE" "run + roster after the end leave the existing log byte-for-byte unchanged (the measurement does not grow)"
roster_pg "$T/city" "" >/dev/null; eq "$?" "2" "switch set + roster with an empty bead id → still exit 2 (usage)"
roster_pg "$T/city" "$OFF_BEAD" >/dev/null; eq "$?" "5" "switch set → a control-arm bead is not rostered either (exit 5)"

# G. take the switch away and everything is back — the file is the whole state
rm -f "$OFFF"; reset_state
OUT="$(roster_pg "$T/city" "$ON_BEAD")"; rc=$?; eq "$rc" "0" "switch removed → roster exit 0 again"; eq "$OUT" "on" "…and prints the arm again"
reset_state
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$(field "$L" verdict)" "PASS" "switch removed → an on-arm run reviews again (verdict=PASS)"; eq "$(ncalls)" "1" "…and launches claude"

# H. what counts as "set": any entry at that path, a dangling symlink too
reset_state; ln -s "$T/does-not-exist" "$OFFF"
OUT="$(run_pg STUB_MODE=pass -- run feat/x --bead "$ON_BEAD" --no-fetch)"
eq "$(field "$(last_line "$OUT")" reason)" "program-off" "a dangling symlink at the switch path counts as set"; eq "$(ncalls)" "0" "…no claude"
rm -f "$OFFF"

# I. "could not look" is not "absent": the inert state wins, with the reason on the line
CITY_ND="$T/city-notdir"; mkdir -p "$CITY_ND"; : > "$CITY_ND/.gc"          # .gc is a FILE: stat of .gc/pregate.off is ENOTDIR
reset_state
OUT="$(run_pg STUB_MODE=pass PRE_GATE_CITY="$CITY_ND" -- run feat/x --bead "$ON_BEAD" --no-fetch)"; rc=$?; L="$(last_line "$OUT")"
eq "$rc" "0" "switch path unverifiable (ENOTDIR) → run exit 0"; eq "$(field "$L" verdict)" "SKIPPED" "…SKIPPED"
eq "$(field "$L" reason)" "program-off-unverifiable:not-a-directory" "…with the reason named, distinct from program-off"
eq "$(ncalls)" "0" "…and no claude"; [ ! -e "$T/logs/runs.jsonl" ] && ok "…and no row" || bad "unverifiable switch → a row was written"
roster_pg "$CITY_ND" "$ON_BEAD" >/dev/null; eq "$?" "5" "switch path unverifiable → roster exit 5 as well"
if [ "$(id -u)" != "0" ]; then
  CITY_NP="$T/city-noperm"; mkdir -p "$CITY_NP/.gc"; chmod 000 "$CITY_NP/.gc"      # EACCES (root ignores mode bits, so not run as root)
  reset_state
  OUT="$(run_pg STUB_MODE=pass PRE_GATE_CITY="$CITY_NP" -- run feat/x --bead "$ON_BEAD" --no-fetch)"; L="$(last_line "$OUT")"
  chmod 755 "$CITY_NP/.gc"
  eq "$(field "$L" reason)" "program-off-unverifiable:permission-denied" "switch path unverifiable (EACCES) → reason names permission-denied"; eq "$(ncalls)" "0" "…and no claude"
else
  echo "  - EACCES case skipped (running as root: mode bits do not stop root)"
fi

# J. the other direction must hold too: a city with NO .gc at all (stamp selftest layout) is ABSENT — not "could not look"
mkdir -p "$T/city-nogc"
OUT="$(PRE_GATE_CITY="$T/city-nogc" pg_program_off)"; rc=$?
eq "$rc" "1" "city without .gc → switch absent (rc 1)"; eq "$OUT" "" "…and nothing printed"
OUT="$(PRE_GATE_CITY="$T/city" pg_program_off)"; rc=$?; eq "$rc" "1" "city with .gc but no pregate.off → absent (rc 1)"
: > "$OFFF"; OUT="$(PRE_GATE_CITY="$T/city" pg_program_off)"; rc=$?
eq "$rc" "0" "pregate.off present → rc 0"; eq "$OUT" "program-off" "…prints program-off"; rm -f "$OFFF"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
