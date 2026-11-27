#!/usr/bin/env bash
# gate-root-class.selftest.sh (ga-mw5gdyu.5) — the closed root-class vocabulary: what the reviewer is TOLD (gate-review-task.lib.sh), what the gate DOES with what comes back (gate_root_class_apply: FAIL_REASONS
# + the `root_class` of the quality-gate.jsonl event) and WHERE the dispatcher calls it. The auditor's own rules are scripts/test_gate_root_class.py; here the glue is judged on what it does when the auditor
# answers, fails, or is not there; the last section also pins the auditor's boundaries and exit codes, because the hq-mutants lastro runs this file and not that one. GATE_BASH32=<a real bash 3.2> runs every
# child shell and the -n checks under it. Exit 0 iff every assertion holds.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${TASKLIB_UNDER_TEST:-$SELF_DIR/gate-review-task.lib.sh}"
DISPATCHER="${DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
HELPER="$SELF_DIR/gate-root-class.py"
BASH32="${GATE_BASH32:-/bin/bash}"
PY="$(command -v python3)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grc.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
echo "== gate-root-class.selftest =="

echo "-- syntax under $BASH32"
for f in "$LIB" "$DISPATCHER"; do
  out="$("$BASH32" -n "$f" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse: $out"; fi
done

echo "-- the reviewer task carries the closed list and the rule (every mode, both lanes), whatever else is installed"
BLOCK="$("$PY" "$HELPER" task-block)"   # the auditor's own list: the lib embeds a copy, and this is the drift guard
render() {  # render <verdict mode> [VAR=value ...] -> the task text; RLIB= renders from another copy of the lib
  local mode="$1"; shift
  env "$@" "$BASH32" -c 'set -euo pipefail; source "${RLIB:-$1}"; gate_render_review_task 1 1 fix/ga-x someone gascity 0123abc LENS a.py "1 file" HDR DIFF /city vb-1 "$2"' _ "$LIB" "$mode"
}
for variant in "bead:" "text:" "bead:GATE_REVIEW_PROMPT_MODE=task-rapida"; do
  mode="${variant%%:*}"; envs="${variant#*:}"
  task="$(render "$mode" $envs)"
  case "$task" in *"$BLOCK"$'\n\n'"After completing your review"*) ok "$variant: the block equals the auditor's list, verbatim, a blank line before the verdict commands" ;; *) bad "$variant: the block is missing, differs from gate-root-class.py task-block, or is glued to the commands" ;; esac
  case "$task" in *"Blocking issue 1: <description> root-class:<class>"*"Blocking issue 2: <description> root-class:<class>"*) ok "$variant: the FAIL format asks for a class on every blocking issue" ;; *) bad "$variant: the FAIL format does not ask for root-class:<class>" ;; esac
done
task="$(render bead GATE_ROOT_CLASS_SCRIPT=/nonexistent/gate-root-class.py GATE_ROOT_CLASS_PY=/nonexistent/python3 2>"$TMP/warn.txt")"; rc=$?
case "$task" in *"$BLOCK"*) ok "no python and no auditor: the task still carries the whole block (what a reviewer is asked never depends on a process)" ;; *) bad "the block went missing without python" ;; esac
check "…and that render succeeds without a word on stderr" "0|0" "$rc|$(wc -c < "$TMP/warn.txt" | tr -d ' ')"
mkdir -p "$TMP/alone"; cp "$LIB" "$TMP/alone/gate-review-task.lib.sh"
check "the lib copied ALONE into another directory renders the identical task (the E5 selftest renders from such a copy)" "$(render bead | cksum)" "$(RLIB="$TMP/alone/gate-review-task.lib.sh" render bead | cksum)"
check "the PASS half of the verdict commands is untouched" "1" "$(printf '%s' "$task" | grep -c 'label add .*verdict:PASS')"

echo "-- gate_root_class_apply: what the gate does with the auditor's answer"
R_OK='Reviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x never checks the read root-class:error-vs-empty\nNon-blocking findings: none\n'
R_NONE='Reviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x never checks the read\nNon-blocking findings: none\n'
R_BAD='Reviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x root-class:third-state\nNon-blocking findings: none\n'
R_MERGE='Merge failed after all-PASS verdict. Merge result: failed. Check git state of rig r.'
R_NASTY=$'Reviewer 1 FAIL: VERDICT: FAIL\\nBlocking issue 1: a $HOME `x` "q" \\\\b *.py % tab\there ção 😀 root-class:comment-lies\\nNon-blocking findings: none\\n'
run_apply() {  # run_apply <FAIL_REASONS> [script] [python] -> $TMP/a.text (FAIL_REASONS after), a.json (GATE_ROOT_CLASS_JSON), a.meta ("<warn count> <rc>"), a.warn (what was warned)
  GATE_ROOT_CLASS_SCRIPT="${2-$HELPER}" GATE_ROOT_CLASS_PY="${3-$PY}" "$BASH32" -c 'set -euo pipefail; WARNS=0; D=$3; : > "$D/a.warn"; log() { :; }; warn() { WARNS=$((WARNS+1)); printf "%s\n" "$1" >> "$D/a.warn"; }; source "$1"; FAIL_REASONS=$2
    rc=0; gate_root_class_apply || rc=$?
    printf "%s" "$FAIL_REASONS" > "$3/a.text"; printf "%s" "$GATE_ROOT_CLASS_JSON" > "$3/a.json"; echo "$WARNS $rc" > "$3/a.meta"' _ "$LIB" "$1" "$TMP"
}
same_text() { printf '%s' "$1" > "$TMP/want.text"; cmp -s "$TMP/want.text" "$TMP/a.text"; }   # byte for byte
audited() { printf '%s' "$1" | "$PY" "$HELPER" audit | jq -j '.text'; }                          # what the auditor says the text becomes
jq_ok() { jq -e "$1" "$TMP/a.json" >/dev/null 2>&1; }

run_apply "$R_OK"
if [ "$(cat "$TMP/a.text")" = "$(audited "$R_OK")" ] && jq_ok '.state == "classificada" and .valid == ["error-vs-empty"] and .invalid == [] and (keys | length) == 3'; then ok "a labelled rejection: FAIL_REASONS is the audited text, the record says classificada + the class"; else bad "labelled rejection: $(cat "$TMP/a.json")"; fi
check "…and nothing was warned" "0 0" "$(cat "$TMP/a.meta")"
run_apply "$R_NONE"
if [ "$(cat "$TMP/a.text")" = "$(audited "$R_NONE")" ] && jq_ok '.state == "sem_classe" and .valid == [] and .invalid == []' && grep -q 'SEM CLASSE' "$TMP/a.text"; then ok "no label: recorded as sem_classe and the text says SEM CLASSE"; else bad "no label: $(cat "$TMP/a.json")"; fi
check "…and it is warned (visible in the dispatcher log), not only counted" "1 0" "$(cat "$TMP/a.meta")"
run_apply "$R_BAD"
if grep -q 'root-class-invalida:third-state' "$TMP/a.text" && ! grep -q 'root-class:third-state' "$TMP/a.text" && jq_ok '.state == "fora_do_vocabulario" and .invalid == ["third-state"]'; then ok "a class outside the list: renamed in the text, listed in the record, not accepted"; else bad "outside the list: $(cat "$TMP/a.json")"; fi
R_MIX='Reviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x root-class:comment-lies\nBlocking issue 2: y root-class:made-up\nNon-blocking findings: none\n'
run_apply "$R_MIX"
if jq_ok '.state == "classificada" and .valid == ["comment-lies"] and .invalid == ["made-up"]' && grep -q 'root-class-invalida:made-up' "$TMP/a.text" && [ "$(cat "$TMP/a.meta")" = "1 0" ]; then ok "a good class next to a rejected one: classificada, the rejected one renamed and listed, and warned"; else bad "mixed rejection: $(cat "$TMP/a.json") $(cat "$TMP/a.meta")"; fi
run_apply "$R_MERGE"; same_text "$R_MERGE" && check "not a reviewer rejection: text untouched, record null, nothing warned" "null|0 0" "$(cat "$TMP/a.json")|$(cat "$TMP/a.meta")" || bad "merge failure was touched"
run_apply "$R_NASTY"; printf '%s%s' "$R_NASTY" "$("$PY" "$HELPER" audit <<<"$R_NASTY" | jq -j '.note')" > "$TMP/want.text"
if cmp -s "$TMP/want.text" "$TMP/a.text"; then ok "backslashes, \$, backticks, quotes, globs, %, a tab, accents and an emoji cross the glue byte for byte"; else bad "the reviewer's text was altered by the glue"; fi

echo "-- a reason the dispatcher could not get is not a class the reviewer left out (gate attempt 1, blocking issue 1)"
# vazio (the count below is not 2: the dispatcher was reworded or moved) → bad; falhou/ilegível (no dispatcher to read) → sed prints nothing, so the same bad: never a pass on strings that no longer exist
UNREAD_BODIES="$(sed -nE 's/^[[:space:]]*FAIL_COMMENT="((verdict:FAIL|INCONCLUSIVE) [^"]*)"$/\1/p' "$DISPATCHER" | sed 's/\$VB/ga-vb1/')"   # the two bodies gate_collect_verdicts writes for a verdict:FAIL it has no reason for
check "the dispatcher writes exactly the two placeholder bodies the auditor knows (a third must be taught to UNREAD)" "2" "$(printf '%s\n' "$UNREAD_BODIES" | grep -c .)"
while IFS= read -r body; do
  R_UNREAD="Reviewer 1 FAIL: $body"'\n'
  run_apply "$R_UNREAD"
  if same_text "$R_UNREAD" && jq_ok '.state == "nao_sei" and (keys | length) == 1' && [ "$(cat "$TMP/a.meta")" = "1 0" ] && grep -q 'not read' "$TMP/a.warn"; then ok "${body%% *}…: text untouched (no SEM CLASSE note), the record is {state:nao_sei}, warned once and why"; else bad "placeholder ${body%% *}…: json=$(cat "$TMP/a.json") meta=$(cat "$TMP/a.meta") warn=$(cat "$TMP/a.warn")"; fi
done <<<"$UNREAD_BODIES"

echo "-- the auditor cannot answer: the text stays as it was and the record says nao_sei (never a state)"
printf 'import sys\nsys.exit(3)\n' > "$TMP/exit3.py"; printf 'print("not json")\n' > "$TMP/garbage.py"
printf 'print("{\\"state\\":\\"talvez\\",\\"valid\\":[],\\"invalid\\":[],\\"text\\":\\"x\\",\\"note\\":\\"\\"}")\n' > "$TMP/unknown.py"
printf 'print("{\\"state\\":\\"sem_classe\\",\\"valid\\":[],\\"invalid\\":[],\\"text\\":\\"\\",\\"note\\":\\"\\"}")\n' > "$TMP/empty.py"
printf 'print("{\\"state\\":\\"classificada\\"}")\n' > "$TMP/nokeys.py"
printf 'print("{\\"state\\":\\"sem_classe\\",\\"valid\\":[],\\"invalid\\":[]}")\n' > "$TMP/notext.py"
for v in 'novalid:{\"state\":\"sem_classe\",\"invalid\":[],\"text\":\"x\"}' 'noinvalid:{\"state\":\"sem_classe\",\"valid\":[],\"text\":\"x\"}' 'validstr:{\"state\":\"sem_classe\",\"valid\":\"abc\",\"invalid\":[],\"text\":\"x\"}' 'invalidstr:{\"state\":\"sem_classe\",\"valid\":[],\"invalid\":5,\"text\":\"x\"}'; do
  printf 'print("%s")\n' "${v#*:}" > "$TMP/${v%%:*}.py"
  "$PY" "$TMP/${v%%:*}.py" | jq -e .state >/dev/null 2>&1 || bad "the fake auditor ${v%%:*} does not print JSON: its case would be testing the wrong branch"  # liveness: a fake that dies is caught by the first guard, not the one it is for
done
CASES=("script absent:/nonexistent/x.py:$PY" "python absent:$HELPER:/nonexistent/python3" "auditor exits 3:$TMP/exit3.py:$PY" "auditor prints garbage:$TMP/garbage.py:$PY"
       "state it does not know:$TMP/unknown.py:$PY" "empty text:$TMP/empty.py:$PY" "answer without valid/invalid:$TMP/nokeys.py:$PY" "answer without text:$TMP/notext.py:$PY"
       "text but no valid:$TMP/novalid.py:$PY" "text but no invalid:$TMP/noinvalid.py:$PY" "valid is a string:$TMP/validstr.py:$PY" "invalid is a number:$TMP/invalidstr.py:$PY")
for tc in "${CASES[@]}"; do
  IFS=: read -r name script py <<<"$tc"
  run_apply "$R_NONE" "$script" "$py"
  if same_text "$R_NONE" && jq_ok '.state == "nao_sei"' && [ "$(cut -d' ' -f1 "$TMP/a.meta")" -ge 1 ]; then ok "$name: text untouched, nao_sei, warned"; else bad "$name: json=$(cat "$TMP/a.json") meta=$(cat "$TMP/a.meta") text-same=$(same_text "$R_NONE" && echo y || echo n)"; fi
  alive="$(GATE_ROOT_CLASS_SCRIPT="$script" GATE_ROOT_CLASS_PY="$py" "$BASH32" -c 'set -euo pipefail; log() { :; }; warn() { :; }; source "$1"; FAIL_REASONS=$2; gate_root_class_apply; echo alive' _ "$LIB" "$R_NONE" 2>/dev/null)"
  check "$name: and a bare call under set -e does not abort the shell (the function owns its failures)" "alive" "$alive"
done
GATE_ROOT_CLASS_SCRIPT="$HELPER" GATE_ROOT_CLASS_PY="$PY" "$BASH32" -c 'set -euo pipefail; log() { :; }; warn() { :; }; source "$1"; FAIL_REASONS=$2; gate_root_class_apply; A=$GATE_ROOT_CLASS_JSON
  FAIL_REASONS=$3; gate_root_class_apply; echo "$A|$GATE_ROOT_CLASS_JSON"' _ "$LIB" "$R_OK" "$R_MERGE" > "$TMP/leak.txt"
check "the production path: no overrides at all, the auditor is found next to the lib and python3 by PATH" '{"state":"classificada","valid":["error-vs-empty"],"invalid":[]}' "$(env -u GATE_ROOT_CLASS_SCRIPT -u GATE_ROOT_CLASS_PY "$BASH32" -c 'set -euo pipefail; log() { :; }; warn() { :; }; source "$1"; FAIL_REASONS=$2; gate_root_class_apply; echo "$GATE_ROOT_CLASS_JSON"' _ "$LIB" "$R_OK")"
check "the record of one run does not leak into the next call" '{"state":"classificada","valid":["error-vs-empty"],"invalid":[]}|null' "$(cat "$TMP/leak.txt")"

echo "-- the dispatcher: where it is called and what the event carries"
extract_block() { sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'; }
AUDIT_BLOCK="$(extract_block "$DISPATCHER" root-class-audit)"; EMIT_BLOCK="$(extract_block "$DISPATCHER" dispatcher-complete-event)"
[ -n "$AUDIT_BLOCK" ] && [ -n "$EMIT_BLOCK" ] && ok "found the root-class-audit and dispatcher-complete-event blocks" || bad "a block is missing (audit=${#AUDIT_BLOCK}B emit=${#EMIT_BLOCK}B)"
fn="$(grep -n '^gate_finalize_run() {' "$DISPATCHER" | head -1 | cut -d: -f1)"; reset="$(awk -v s="${fn:-0}" 'NR>s && /^GATE_ROOT_CLASS_JSON=null$/ {print NR; exit}' "$DISPATCHER")"
step9="$(awk -v s="${fn:-0}" 'NR>s && /^# ── Step 9: Close reviewer sessions/ {print NR; exit}' "$DISPATCHER")"
failp="$(grep -n '^  # ── FAIL path ──' "$DISPATCHER" | head -1 | cut -d: -f1)"; audit_ln="$(grep -n 'SELFTEST-EXTRACT root-class-audit: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)"
firstuse="$(grep -n '^  log "Gate FAILED: \$FAIL_REASONS"' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$fn" ] && [ -n "$reset" ] && [ -n "$step9" ] && [ "$reset" -gt "$fn" ] && [ "$reset" -lt "$step9" ]; then ok "the record is reset at the top of gate_finalize_run (L$reset), before either verdict path: no run inherits the last one's"; else bad "no reset of GATE_ROOT_CLASS_JSON at the top of gate_finalize_run (fn=${fn:-?} reset=${reset:-?} step9=${step9:-?})"; fi
if [ -n "$failp" ] && [ -n "$audit_ln" ] && [ -n "$firstuse" ] && [ "$failp" -lt "$audit_ln" ] && [ "$audit_ln" -lt "$firstuse" ]; then ok "the audit runs on the FAIL path before anything reads FAIL_REASONS (path L$failp < audit L$audit_ln < first use L$firstuse)"; else bad "the audit is not between the FAIL path and its first use of FAIL_REASONS (${failp:-?} ${audit_ln:-?} ${firstuse:-?})"; fi
run_dispatcher() {  # run_dispatcher <OVERALL_VERDICT> <FAIL_REASONS> <GATE_ROOT_CLASS_JSON, or "-" for unset> -> the quality-gate.jsonl line
  rm -f "$TMP/qg.jsonl"; printf '%s\n' "$AUDIT_BLOCK" > "$TMP/audit.sh"; printf '%s\n' "$EMIT_BLOCK" > "$TMP/emit.sh"
  sed -n '/^gate_render_reasons() {/,/^}/p' "$DISPATCHER" > "$TMP/render.sh"
  GATE_ROOT_CLASS_SCRIPT="$HELPER" "$BASH32" -c 'set -euo pipefail; d=$1; log() { :; }; warn() { :; }; source "$5"; . "$d/render.sh"
    OVERALL_VERDICT=$2; FAIL_REASONS=$3; [ "$4" = "-" ] || GATE_ROOT_CLASS_JSON=$4
    QG_LOG=$d/qg.jsonl; REQUIRED_REVIEWERS=1; BRANCH=b; BEAD_ID=ga-x; RIG=r; TIER=t; GATE_RUN_ID=gr; MARKER_ID=m; ELAPSED_S=1; DRY_RUN=0
    if [ "$OVERALL_VERDICT" = FAIL ]; then . "$d/audit.sh"; fi   # as in the dispatcher: the audit block exists on the FAIL path only
    . "$d/emit.sh"' _ "$TMP" "$1" "$2" "$3" "$LIB" 2>"$TMP/disp.err" || true
  cat "$TMP/qg.jsonl" 2>/dev/null
}
line="$(run_dispatcher FAIL "$R_NONE" -)"
check "a refusal with no label: the event says root_class.state=sem_classe (counted in the gate's own record)" "sem_classe" "$(printf '%s' "$line" | jq -r '.root_class.state')"
line="$(run_dispatcher PASS "" -)"
check "a PASS with the record never set: root_class is null (the event writer reads it as ${GATE_ROOT_CLASS_JSON:-null}, set -u safe)" "null" "$(printf '%s' "$line" | jq -c '.root_class')"
printf '%s\n' "$AUDIT_BLOCK" > "$TMP/audit.sh"
check "the audit block without the lib loaded (a half-deployed city): no abort, ONE warning, the record says nao_sei (the run was NOT audited: not the null of nothing to classify), FAIL_REASONS untouched" "0|$R_NONE|1|nao_sei" "$("$BASH32" -c 'set -euo pipefail; WARNS=0; warn() { WARNS=$((WARNS+1)); }; FAIL_REASONS=$2; . "$1/audit.sh"; echo "$?|$FAIL_REASONS|$WARNS|$(printf "%s" "$GATE_ROOT_CLASS_JSON" | jq -r .state)"' _ "$TMP" "$R_NONE" 2>&1)"
check "an apply that returns non-zero does not abort the dispatcher (the call site is its own seatbelt)" "alive" "$("$BASH32" -c 'set -euo pipefail; gate_root_class_apply() { return 7; }; FAIL_REASONS=x; . "$1/audit.sh"; echo alive' _ "$TMP" 2>&1)"
line="$(run_dispatcher FAIL "$R_OK" -)"
check "a labelled refusal: the event carries the classes" '["error-vs-empty"]' "$(printf '%s' "$line" | jq -c '.root_class.valid')"
line="$(run_dispatcher FAIL "$R_MERGE" -)"
check "a merge failure: root_class is null (the audit found nothing to classify)" "null" "$(printf '%s' "$line" | jq -c '.root_class')"
line="$(run_dispatcher PASS "" '{"state":"sem_classe"}')"
check "the event writer prints exactly the record it was given (the reset above is what keeps a PASS from inheriting one)" "sem_classe" "$(printf '%s' "$line" | jq -r '.root_class.state')"
line="$(run_dispatcher PASS "" 'not json')"
check "a malformed record is nao_sei in the event and the line is still written (a dropped event would hide the refusal from the meter)" "1 nao_sei" "$(printf '%s' "$line" | jq -rs 'length, .[0].root_class.state' | paste -sd' ' -)"

echo "-- the auditor itself, without the glue: the boundaries and the exit codes the lastro's mutants move (the whole rulebook is scripts/test_gate_root_class.py, which the engine does not run)"
# vazio/falhou/ilegível (the auditor printed nothing, jq could not read what it printed, a file or a count below cannot be read) → "": no expected value in this section is empty, so the check is red, never a pass
aud() { printf '%s' "$1" | "$PY" "$HELPER" audit | jq -c '[.state, .valid, .invalid]'; }   # the auditor's own answer as [state, accepted, rejected]
FH='Reviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x'; FT='\nNon-blocking findings: none\n'   # a refusal in its real shape: the escaped break is the two characters backslash-n
check "outra with a why of exactly MIN_WHY (8) characters is accepted" '["classificada",["outra"],[]]' "$(aud "$FH root-class:outra - abcdefgh$FT")"
check "outra with a why of 7 characters is not: the boundary, both sides" '["fora_do_vocabulario",[],["outra"]]' "$(aud "$FH root-class:outra - abcdefg$FT")"
check "outra whose why sits on the NEXT issue is not accepted: the why is what follows on the SAME line" '["classificada",["error-vs-empty"],["outra"]]' "$(aud "$FH root-class:outra"'\nBlocking issue 2: the lock is taken twice on retry root-class:error-vs-empty'"$FT")"
# EQUIVALENT 9f56e95c60: `BREAK_RE.split(rest, maxsplit=1)[0]` -> `maxsplit=0`: 0 means no limit and only the first piece is read, which is the text up to the first break either way; only the cost of splitting the rest differs
check "the blocking part ends at the FIRST «Non-blocking findings:»: a label after it is neither read nor renamed" '["sem_classe",[],[]]' "$(aud 'Reviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x with no class\nNon-blocking findings: low: y root-class:made-up and root-class:error-vs-empty\n')"
check "…and a text that STARTS with the marker has an empty blocking part: the label after it is not read either" '["sem_classe",[],[]]' "$(aud 'Non-blocking findings: n/a\nReviewer 1 FAIL: VERDICT: FAIL\nBlocking issue 1: x root-class:comment-lies\n')"
UN1="$(printf '%s\n' "$UNREAD_BODIES" | sed -n 1p)"; UN2="$(printf '%s\n' "$UNREAD_BODIES" | sed -n 2p)"   # the dispatcher's two placeholders, read above
union_text() {  # FAIL_REASONS as gate_e5_union_reasons (gate-e5-second-reviewer.lib.sh) leaves it, byte for byte: the producer's own text, its last newline cut as the $( ) there cuts it, then the two characters backslash-n: union_text <comment>...
  "$PY" -I -c 'import importlib.util as u, sys; s = u.spec_from_file_location("e5u", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m); sys.stdout.write(m.union([{"index": i + 1, "text": c} for i, c in enumerate(sys.argv[2:])])[0].rstrip("\n") + "\\n")' "$SELF_DIR/gate-e5-union.py" "$@"
}
check "an E5 union whose every issue is the dispatcher's placeholder is nao_sei: the header counts the issues and the placeholder lines are all of them" '["nao_sei",[],[]]' "$(aud "$(union_text "$UN1" "$UN2")")"
check "…and one issue a reviewer really wrote makes the union judged: classificada by the label that issue carries" '["classificada",["error-vs-empty"],[]]' "$(aud "$(union_text $'VERDICT: FAIL\nBlocking issue 1: scripts/foo.py:40 x never checks the read root-class:error-vs-empty\nNon-blocking findings: none' "$UN1")")"
rc=0; "$PY" "$HELPER" task-block > "$TMP/cli.out" 2> "$TMP/cli.err" || rc=$?
check "task-block exits 0 with the block on stdout and nothing on stderr" "0|yes|0" "$rc|$([ -n "$BLOCK" ] && [ "$(cat "$TMP/cli.out")" = "$BLOCK" ] && echo yes || echo no)|$(wc -c < "$TMP/cli.err" | tr -d ' ')"
rc=0; "$PY" "$HELPER" bogus > "$TMP/cli.out" 2> "$TMP/cli.err" || rc=$?
check "an unknown mode exits 2 (usage) with nothing on stdout and the usage line on stderr" "2|0|1" "$rc|$(wc -c < "$TMP/cli.out" | tr -d ' ')|$(grep -c '^uso:' "$TMP/cli.err")"
rc=0; printf '\377\376 not utf-8' | "$PY" "$HELPER" audit > "$TMP/cli.out" 2> "$TMP/cli.err" || rc=$?
check "audit on stdin that is not UTF-8 exits 3 with NOTHING on stdout: a caller records nao_sei, never a state" "3|0|1" "$rc|$(wc -c < "$TMP/cli.out" | tr -d ' ')|$(grep -c 'UnicodeDecodeError' "$TMP/cli.err")"
out="$(printf '%s' "$R_OK" | "$PY" "$HELPER" audit)"
check "the answer is ASCII json (ensure_ascii) although its note carries accents: no byte above 0x7f, and the accent is there once decoded" "0|true" "$(printf '%s' "$out" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')|$(printf '%s' "$out" | jq -r '.note | contains("ç")')"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
