#!/usr/bin/env bash
# gate-lane-scope-refusal-cases.selftest.sh (ga-wnaxl43) — the cases around the locked repro (gate-lane-scope-refusal-not-code-fail.selftest.sh proves the
# bug and its fix on the incident's own shape). Here: the recognizer's edges, the controls that keep a code rejection a code rejection, the lane's
# opt-out on the resubmission, the risk list for daemons/routes/cls_*.py, a drift guard against the lane prompt's wording, and one mutant per moving part.
#
#   a) gate_fail_is_lane_scope_refusal says yes only when EVERY "Blocking issue" header opens with "out of the task-rapida scope"
#   a2) a header is a header under every decoration the project's other parsers read (**, -, >, #N, no number): a code issue under one is never hidden
#      behind a refusal, and a refusal under one is still seen (gate review of 604f11b82)
#   b) class hold only for a task-rapida run whose EVERY judged FAIL is such a refusal; a code FAIL anywhere, a FAIL whose reason could not be read,
#      an empty-reason FAIL, another lane (or none) stay class code — and the run is still an evaluated FAIL (NO_EVAL=0: gate:fix-attempt advances)
#   c) the relay is recomputed per collect and zeroed by finalize
#   d) a hold stamp + gate:normal-only -> the lane answers opted-out (normal gate); a code stamp keeps blocking (ga-nooaw not weakened)
#   e) the shipped risk list covers daemons/routes/cls_*.py, and it is the new line that does it
#   f) the lane prompt still carries the wording the recognizer keys on
#   g) MUTATION: each moving part removed alone turns a case red
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
LANE_LIB="$SELF_DIR/gate-taskrapida.lib.sh"
PROMPT_LIB="$SELF_DIR/gate-review-task.lib.sh"
RISK_DEFAULT="$SELF_DIR/gate-task-rapida-risco.default.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
echo "== gate-lane-scope-refusal-cases.selftest (ga-wnaxl43) =="
for f in "$DISPATCHER" "$LANE_LIB" "$PROMPT_LIB" "$RISK_DEFAULT"; do [ -r "$f" ] || { echo "FATAL: $f not readable" >&2; exit 2; }; done

FIX="$(mktemp -d "${TMPDIR:-/tmp}/gate-lanescope-cases-XXXXXX")"; MUT="$FIX/mutant.sh"
trap 'rm -rf "$FIX"' EXIT

extract_block() { sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'; }
jt() { printf '%s' "$1" | jq -Rs '[{text: .}]'; }
mk_vb() { # <id> <labels-csv> <comments-json>
  local l arr="" IFS_SAVE="$IFS"; IFS=','
  for l in $2; do arr="${arr:+$arr,}\"$l\""; done; IFS="$IFS_SAVE"
  printf '{"status":"closed","labels":["type:quality-gate-verdict"%s],"assignee":"reviewer-%s"}\n' "${arr:+,$arr}" "$1" > "$FIX/$1.json"
  printf '%s\n' "$3" > "$FIX/$1.comments.json"
}
# run_case <dispatcher-file> <lane|-> <preset-relay> <id>... -> RESULT|VR|ANY_FAIL|NO_EVAL|SCOPE (relay after collect)|CLASS|SCOPE_AFTER (relay after finalize)
run_case() {
  local file="$1" lane="$2" preset="$3" fn_collect fn_peek fn_link fn_reset; shift 3
  fn_collect="$(extract_block "$file" "gate-collect-verdicts-fn")"; fn_peek="$(extract_block "$file" "session-peek-reports-dead-fn")"
  fn_link="$(extract_block "$file" "gate-verdict-identity-link-fn")"; fn_reset="$(extract_block "$file" "finalize-failclass-reset")"
  { [ -n "$fn_collect" ] && [ -n "$fn_peek" ] && [ -n "$fn_link" ] && [ -n "$fn_reset" ]; } || { echo "COULD_NOT_EXTRACT_BLOCK"; return 99; }
  bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"; FIX="$1"; LANE="$2"; PRESET="$3"; shift 3
    if [ "$LANE" != "-" ]; then GATE_LANE="$LANE"; fi
    VERDICT_BEAD_IDS=("$@")
    bd() {
      local sub="" id="" a
      for a in "$@"; do case "$a" in show|comments|close) sub="$a" ;; -*|/*) : ;; *) [ -n "$sub" ] && [ -z "$id" ] && id="$a" ;; esac; done
      case "$sub" in show) cat "$FIX/$id.json" ;; comments) [ -f "$FIX/$id.comments.fail" ] && return 1; cat "$FIX/$id.comments.json" ;; esac
      return 0
    }
    gc() { return 1; }; log() { :; }; warn() { :; }
    '"$fn_peek"'
    '"$fn_link"'
    '"$fn_collect"'
    finalize_reset() {
      '"$fn_reset"'
    }
    GATE_FAIL_LANE_SCOPE="$PRESET"
    gate_collect_verdicts
    SCOPE="${GATE_FAIL_LANE_SCOPE:-unset}"; NOEVAL="${GATE_FAIL_NO_EVAL:-0}"
    GATE_SHA_FAIL_CLASS="code"
    finalize_reset
    printf "RESULT|VR=%s|ANY_FAIL=%s|NO_EVAL=%s|SCOPE=%s|CLASS=%s|SCOPE_AFTER=%s|\n" "$VERDICTS_RECEIVED" "$ANY_FAIL" "$NOEVAL" "$SCOPE" "$GATE_SHA_FAIL_CLASS" "${GATE_FAIL_LANE_SCOPE:-unset}"
  ' _ "$FIX" "$lane" "$preset" "$@" 2>&1
}
expect() { # <label> <result-line> <any_fail> <scope-relay> <class>
  case "$2" in *"|ANY_FAIL=$3|NO_EVAL=0|SCOPE=$4|CLASS=$5|SCOPE_AFTER=0|"*) ok "$1 -> ANY_FAIL=$3 SCOPE=$4 CLASS=$5" ;;
    *) bad "$1 — expected ANY_FAIL=$3 NO_EVAL=0 SCOPE=$4 CLASS=$5 SCOPE_AFTER=0, got: $2" ;; esac
}
pred() { # <text> [path] -> yes|no, from the recognizer extracted out of the dispatcher at <file>
  bash -c "$(extract_block "${DISP_UNDER_TEST:-$DISPATCHER}" gate-collect-verdicts-fn)"'
    if [ -n "${2:-}" ]; then PATH="$2"; fi
    gate_fail_is_lane_scope_refusal "$1"' _ "$1" "${2:-}"
}
expect_pred() { local g; g="$(pred "$3" "${4:-}")"; if [ "$g" = "$2" ]; then ok "recognizer: $1 -> $2"; else bad "recognizer: $1 — expected $2, got '$g'"; fi; }

REF1=$'VERDICT: FAIL\nBlocking issue 1: out of the task-rapida scope: daemons/routes/cls_property.py writes the classifications table and pushes deals to the CRM; nothing else was reviewed. Builder: add the label gate:normal-only to the source bead and resubmit. root-class:wrong-scope\nNon-blocking findings: none'
REF2=$'VERDICT: FAIL\nBlocking issue 1: out of the task-rapida scope: sends WhatsApp messages root-class:wrong-scope\nBlocking issue 2: Out Of The Task-Rapida Scope: writes the leads table root-class:wrong-scope\nNon-blocking findings: none'
CODE1=$'VERDICT: FAIL\nBlocking issue 1: off-by-one in the retry cap root-class:error-vs-empty\nNon-blocking findings: none'
MIXED=$'VERDICT: FAIL\nBlocking issue 1: out of the task-rapida scope: touches the CRM root-class:wrong-scope\nBlocking issue 2: off-by-one in the retry cap root-class:error-vs-empty'

echo "── a. the recognizer ──"
expect_pred "the wa-4e3efc shape" yes "$REF1"
expect_pred "two refusals (the reviewer listed both things it touches)" yes "$REF2"
expect_pred "markdown header, decorated title" yes $'VERDICT: FAIL\n## Blocking issue 1: **`out of the task-rapida scope`**: writes the leads table'
expect_pred "title after a dash, upper case" yes $'VERDICT: FAIL\nBlocking issue 1 — OUT OF THE TASK-RAPIDA SCOPE: pipedrive push'
expect_pred "a code rejection" no "$CODE1"
expect_pred "a refusal plus a code issue (the reviewer judged something)" no "$MIXED"
expect_pred "the phrase inside another issue's text, not its title" no $'VERDICT: FAIL\nBlocking issue 1: the guard says out of the task-rapida scope but the diff is fine root-class:outra'
expect_pred "the phrase in the Summary only" no $'VERDICT: FAIL\nSummary: this is out of the task-rapida scope\nBlocking issue 1: off-by-one root-class:outra'
expect_pred "no header at all (format not recognised)" no $'VERDICT: FAIL — out of the task-rapida scope: sends messages'
expect_pred "a header not at the start of its line" no $'VERDICT: FAIL\nsee Blocking issue 1: out of the task-rapida scope: x'
expect_pred "empty text" no ""
expect_pred "the INCONCLUSIVE placeholder" no "INCONCLUSIVE — verdict:FAIL with empty/unparseable reason (raw bead x; see forensics log above)"
expect_pred "awk unavailable (answers no, never nothing)" no "$REF1" /nonexistent

echo "── a2. a header the project's own parsers read (gate-e5-union ISSUE_RE, gate-refusal-meter TITLE_RE, e4_parse RX_MARK) is a header here too ──"
# A header this cannot see is read as "no other issue": a code rejection under it would be stamped hold (gate review of 604f11b82, root-class:error-vs-empty).
RP='out of the task-rapida scope: writes the classifications table root-class:wrong-scope'; CI='off-by-one in the retry cap root-class:error-vs-empty'
for d in '**Blocking issue <n>:** ' '**Blocking issue <n>**: ' '- Blocking issue <n>: ' '> Blocking issue <n>: ' '## Blocking issue <n>: ' '**Blocking** issue <n>: ' \
         'Blocking issue #<n>: ' '1. Blocking issue <n>: ' 'BLOCKING ISSUE <n> — ' 'Blocking issue: '; do
  expect_pred "a refusal headed «${d/<n>/1}», alone" yes "VERDICT: FAIL"$'\n'"${d/<n>/1}$RP"
  expect_pred "a refusal, then a code issue headed «${d/<n>/2}»" no "VERDICT: FAIL"$'\n'"Blocking issue 1: $RP"$'\n'"${d/<n>/2}$CI"
  expect_pred "a code issue headed «${d/<n>/1}», then a refusal" no "VERDICT: FAIL"$'\n'"${d/<n>/1}$CI"$'\n'"Blocking issue 2: $RP"
done
expect_pred "a decorated header whose text only quotes the phrase" no $'VERDICT: FAIL\n**Blocking issue 1:** the guard says out of the task-rapida scope but the diff is fine'
expect_pred "a non-blocking line that talks about issues is not a header" yes "VERDICT: FAIL"$'\n'"Blocking issue 1: $RP"$'\nNon-blocking issue: off-by-one in the retry cap'
expect_pred "a plural «issues» header counts as a header and is never read as a refusal (stays code, the safe direction)" no $'VERDICT: FAIL\nBlocking issues: '"$RP"

echo "── b/c. class through the real collect + finalize blocks ──"
mk_vb r-scope "verdict:FAIL" "$(jt "$REF1")";   mk_vb r-scope2 "verdict:FAIL" "$(jt "$REF2")"
mk_vb r-race "" "$(jt "$REF1")"   # the verdict:FAIL label lost the race, the anchored FAIL comment landed
mk_vb r-code "verdict:FAIL" "$(jt "$CODE1")";   mk_vb r-mixed "verdict:FAIL" "$(jt "$MIXED")"
mk_vb r-empty "verdict:FAIL" "[]"; mk_vb r-pass "verdict:PASS" "[]"
mk_vb r-unread "verdict:FAIL" "$(jt "$REF1")"; : > "$FIX/r-unread.comments.fail"   # label says FAIL, its reason could not be read
mk_vb r-unread2 "" "[]"; : > "$FIX/r-unread2.comments.fail"                       # no label, comments unreadable: a FAIL cannot be ruled out
mk_vb r-boldscope "verdict:FAIL" "$(jt $'VERDICT: FAIL\n**Blocking issue 1:** out of the task-rapida scope: touches the CRM root-class:wrong-scope')"
mk_vb r-boldmixed "verdict:FAIL" "$(jt $'VERDICT: FAIL\nBlocking issue 1: out of the task-rapida scope: touches the CRM root-class:wrong-scope\n**Blocking issue 2:** off-by-one in the retry cap root-class:error-vs-empty')"
mk_vb r-unnummixed "verdict:FAIL" "$(jt $'VERDICT: FAIL\nBlocking issue 1: out of the task-rapida scope: touches the CRM root-class:wrong-scope\n- Blocking issue: off-by-one in the retry cap root-class:error-vs-empty')"
expect "task-rapida, one refusal"                         "$(run_case "$DISPATCHER" task-rapida 0 r-scope)" 1 1 hold
expect "task-rapida, two refusals in one verdict"          "$(run_case "$DISPATCHER" task-rapida 0 r-scope2)" 1 1 hold
expect "task-rapida, refusal delivered as a comment only"  "$(run_case "$DISPATCHER" task-rapida 0 r-race)" 1 1 hold
expect "task-rapida, two reviewers, both refuse"           "$(run_case "$DISPATCHER" task-rapida 0 r-scope r-scope2)" 1 1 hold
expect "task-rapida, one refuses + one PASS"               "$(run_case "$DISPATCHER" task-rapida 0 r-scope r-pass)" 1 1 hold
expect "task-rapida, a code rejection"                     "$(run_case "$DISPATCHER" task-rapida 0 r-code)" 1 0 code
expect "task-rapida, refusal + code issue in one verdict"  "$(run_case "$DISPATCHER" task-rapida 0 r-mixed)" 1 0 code
expect "task-rapida, refusal then a code FAIL"             "$(run_case "$DISPATCHER" task-rapida 0 r-scope r-code)" 1 0 code
expect "task-rapida, a code FAIL then a refusal"           "$(run_case "$DISPATCHER" task-rapida 0 r-code r-scope)" 1 0 code
expect "task-rapida, a refusal under a bold header"        "$(run_case "$DISPATCHER" task-rapida 0 r-boldscope)" 1 1 hold
expect "task-rapida, refusal + a code issue under a bold header" "$(run_case "$DISPATCHER" task-rapida 0 r-boldmixed)" 1 0 code
expect "task-rapida, refusal + an unnumbered bulleted code issue" "$(run_case "$DISPATCHER" task-rapida 0 r-unnummixed)" 1 0 code
expect "task-rapida, FAIL with no reason (INCONCLUSIVE)"   "$(run_case "$DISPATCHER" task-rapida 0 r-empty)" 1 0 code
expect "task-rapida, refusal + a FAIL whose reason is unreadable" "$(run_case "$DISPATCHER" task-rapida 0 r-scope r-unread)" 1 0 code
expect "task-rapida, refusal + a no-label bead with unreadable comments" "$(run_case "$DISPATCHER" task-rapida 0 r-scope r-unread2)" 1 0 code
expect "normal lane, the same refusal text"                "$(run_case "$DISPATCHER" normal 0 r-scope)" 1 1 code
expect "no lane set at all, the same refusal text"         "$(run_case "$DISPATCHER" - 0 r-scope)" 1 1 code
expect "fast lane, the same refusal text"                  "$(run_case "$DISPATCHER" fast 0 r-scope)" 1 1 code
expect "all PASS"                                          "$(run_case "$DISPATCHER" task-rapida 0 r-pass)" 0 0 code
expect "stale relay=1 + all PASS: recomputed to 0"         "$(run_case "$DISPATCHER" task-rapida 1 r-pass)" 0 0 code
expect "stale relay=1 + a code FAIL: stays code"           "$(run_case "$DISPATCHER" task-rapida 1 r-code)" 1 0 code

echo "── d. the resubmission: gate:normal-only on a hold stamp reaches the normal gate ──"
SHA=4e8837512; : > "$FIX/on"
stale() { bash -c 'GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo LIBFAIL; exit 0; }; gate_labels_have_sha_fail "$2" "$3"' _ "$DISPATCHER" "$1" "$SHA"; }
lane_code() { # <labels-json-array> -> the lane's GATE_TR_CODE for a source bead that is a task with these labels
  GATE_TASKRAPIDA_ON_FILE="$FIX/on" GATE_TASKRAPIDA_RISK_FILE="$RISK_DEFAULT" bash -c '
    source "$1"; GATE_LANE=normal; GATE_E5_ACTIVE=0; nogit() { return 1; }
    gate_taskrapida_decide nogit main abc1234 "[{\"id\":\"wa-4e3efc\",\"issue_type\":\"task\",\"labels\":$2}]" whatsapp_automation "" >/dev/null 2>&1
    printf "%s" "${GATE_TR_CODE:-}"' _ "$LANE_LIB" "$1"
}
[ "$(stale "gate:failed gate-sha-failed:$SHA:hold")" = no ] && ok "a hold stamp does not close the same commit's marker" || bad "a hold stamp must not trip the STALE-SHA guard"
[ "$(stale "gate:failed gate-sha-failed:$SHA:code")" = yes ] && ok "a code stamp still does (a real rejection keeps blocking, ga-nooaw)" || bad "a code stamp must keep tripping the STALE-SHA guard"
[ "$(lane_code '["gate:failed","gate:needs-fix","gate:fix-attempt:1","gate:normal-only","gate-sha-failed:'$SHA':hold"]')" = opted-out ] \
  && ok "with gate:normal-only the lane answers opted-out: the normal gate takes the run" || bad "gate:normal-only must route the resubmission to the normal gate"
[ "$(lane_code '["gate:failed","gate-sha-failed:'$SHA':hold"]')" != opted-out ] \
  && ok "without the label the lane does not say opted-out (the label is what routes)" || bad "the lane said opted-out with no gate:normal-only on the bead"

echo "── e. the risk list covers daemons/routes/cls_*.py ──"
risk_hit() { # <list-file> <path> -> "path<TAB>pattern" of the first hit, empty when none
  bash -c 'source "$1"; GATE_TASKRAPIDA_RISK_FILE="$2"; _gate_tr_load_risk whatsapp_automation || { echo LOADFAIL; exit 0; }; _gate_tr_risk_hit "$3"' _ "$LANE_LIB" "$1" "$2"
}
grep -v '^daemons/routes/cls_$' "$RISK_DEFAULT" > "$FIX/risk-without.txt"
for m in cls_analytics cls_captura cls_completeness cls_contacts cls_drafts cls_eval cls_followup cls_ligacoes_andre cls_manual_sends cls_media cls_property cls_shared; do
  h="$(risk_hit "$RISK_DEFAULT" "daemons/routes/$m.py")"
  case "$h" in ""|LOADFAIL) bad "the shipped list lets daemons/routes/$m.py into the lane ('$h')" ;; *) ok "the shipped list keeps daemons/routes/$m.py out of the lane" ;; esac
done
for m in cls_property cls_contacts; do
  [ -z "$(risk_hit "$FIX/risk-without.txt" "daemons/routes/$m.py")" ] && ok "control: without the new line daemons/routes/$m.py got the lane (it is the line that covers it)" || bad "control: another pattern already covers daemons/routes/$m.py, so the new line proves nothing for it"
done
[ -z "$(risk_hit "$RISK_DEFAULT" daemons/routes/health.py)" ] && ok "a neutral route is untouched" || bad "daemons/routes/health.py must stay in the lane"

echo "── f. the lane prompt still carries the wording the recognizer keys on ──"
P="$(bash -c 'source "$1"; GATE_REVIEW_PROMPT_MODE=task-rapida gate_render_review_task 1 1 feat/x author-1 rig-1 abc1234 LENS a.py "1 file" "" "diff" "" "" text' _ "$PROMPT_LIB" 2>&1)"
W="$(printf '%s\n' "$P" | grep -o 'out of the task-rapida scope: <what it touches>' | head -1)"
if [ -n "$W" ]; then expect_pred "a refusal built from the prompt's own wording" yes "VERDICT: FAIL"$'\n'"Blocking issue 1: ${W/<what it touches>/x}"; else bad "the lane prompt no longer carries the refusal wording the recognizer keys on"; fi

echo "── g. MUTATION: each moving part removed alone must turn a case red ──"
mutate() { # <anchor> <replacement> — writes the mutant dispatcher to $MUT; the anchor must be unique
  python3 - "$DISPATCHER" "$1" "$2" "$MUT" <<'PYEOF'
import sys
src, anchor, repl, out = sys.argv[1:5]
c = open(src).read(); n = c.count(anchor)
if n != 1: print("ANCHOR_COUNT=%d anchor=%r" % (n, anchor), file=sys.stderr); sys.exit(1)
open(out, "w").write(c.replace(anchor, repl, 1))
PYEOF
}
mutant() { # <name> <anchor> <replacement> <lane> <preset> <ids...> -> prints the mutant's result line, or BUILD_FAIL
  local name="$1" a="$2" r="$3"; shift 3
  if mutate "$a" "$r"; then run_case "$MUT" "$@"; else echo BUILD_FAIL; fi
}
red() { case "$2" in *BUILD_FAIL*|*COULD_NOT*) bad "$1: could not build the mutant (anchor not unique — source shape changed?)" ;; *"$3"*) ok "$1: red — $4" ;; *) bad "$1: stayed green — $2" ;; esac; }
R='if [ "$ANY_FAIL" = "1" ] && [ "$_scope_fails" -gt 0 ] && [ "$_scope_fails" -eq "$_judged_fails" ]; then'
red "M1 relay never raised"       "$(mutant M1 "$R" 'if false; then' task-rapida 0 r-scope)" "|SCOPE=0|CLASS=code|" "the lane's refusal is a code stamp again (the bug)"
FIN='if [ "${GATE_FAIL_LANE_SCOPE:-0}" = "1" ] && [ "${GATE_LANE:-}" = "task-rapida" ]; then'
red "M2 finalize ignores relay"   "$(mutant M2 "$FIN" 'if false; then' task-rapida 0 r-scope)" "|SCOPE=1|CLASS=code|" "the relay is raised but nothing reads it"
red "M3 equality guard dropped"   "$(mutant M3 ' && [ "$_scope_fails" -eq "$_judged_fails" ]; then' '; then' task-rapida 0 r-scope r-code)" "|CLASS=hold|" "a code FAIL beside a refusal is stamped hold"
COUNT='if [ "$(gate_fail_is_lane_scope_refusal "$FAIL_COMMENT")" = "yes" ]; then _scope_fails=$((_scope_fails + 1)); fi'
red "M4 label branch not counted" "$(mutant M4 "$COUNT"$'\n        FAIL_REASONS=' 'true'$'\n        FAIL_REASONS=' task-rapida 0 r-scope)" "|SCOPE=0|CLASS=code|" "a labelled refusal is a code stamp"
red "M5 rescue branch not counted" "$(mutant M5 '_scope_fails=$((_scope_fails + 1)); fi   # ga-wnaxl43, as at the label branch' 'true; fi' task-rapida 0 r-race)" "|SCOPE=0|CLASS=code|" "a comment-only refusal is a code stamp"
red "M6 lane check dropped at finalize" "$(mutant M6 "$FIN" 'if [ "${GATE_FAIL_LANE_SCOPE:-0}" = "1" ]; then' normal 0 r-scope)" "|CLASS=hold|" "another lane gets the refusal's hold stamp"
red "M6b stale relay survives collect" "$(mutant M6 '  GATE_FAIL_LANE_SCOPE=0
  local _scope_fails=0' '  local _scope_fails=0' task-rapida 1 r-code)" "|CLASS=hold|" "a stale 1 turns a code FAIL into hold"
red "M7 finalize does not zero the relay" "$(mutant M7 'GATE_FAIL_LANE_SCOPE=0
# SELFTEST-EXTRACT finalize-failclass-reset: END' '# SELFTEST-EXTRACT finalize-failclass-reset: END' task-rapida 0 r-scope)" "|SCOPE_AFTER=1|" "the relay leaks into the next bead"
DISP_UNDER_TEST="$MUT"
red "M8 recognizer counts one refusal among code issues" "$(mutant M8 'END { print ((n >= 1 && s == n) ? "yes" : "no") }' 'END { print ((n >= 1 && s >= 1) ? "yes" : "no") }' task-rapida 0 r-mixed)" "|CLASS=hold|" "a verdict with a code issue is a refusal"
g="$(pred "$MIXED")"; [ "$g" = yes ] && ok "M8 at the recognizer: the mixed verdict reads yes" || bad "M8 at the recognizer: expected yes, got '$g'"
mutate 'if (l ~ /^out of the task-rapida scope/) s++' 'if (l ~ /out of the task-rapida scope/) s++' && [ "$(pred $'VERDICT: FAIL\nBlocking issue 1: the guard says out of the task-rapida scope but the diff is fine')" = yes ] \
  && ok "M9 phrase not anchored to the title: the phrase quoted inside another issue reads yes" || bad "M9: stayed green (or could not build)"
mutate "|| printf 'no'" '' && [ -z "$(pred "$REF1" /nonexistent)" ] && ok "M10 no fallback: awk missing answers nothing, not no" || bad "M10: stayed green (or could not build)"
H='l ~ /^[^a-z]*blocking[^a-z]+issue/ {'
mutate "$H" 'l ~ /^[ \t]*#*[ \t]*blocking[^a-z]+issue/ {' && [ "$(pred "VERDICT: FAIL"$'\n'"Blocking issue 1: $RP"$'\n**Blocking issue 2:** '"$CI")" = yes ] && [ "$(pred $'VERDICT: FAIL\n**Blocking issue 1:** '"$RP")" = no ] \
  && ok "M11 prefix narrowed back to #*: a code issue under ** hides behind the refusal, a refusal under ** is not seen" || bad "M11: stayed green (or could not build)"
mutate "$H" 'l ~ /^[^a-z]*blocking[^a-z]+issue[^a-z]*[0-9]/ {' && [ "$(pred "VERDICT: FAIL"$'\n'"Blocking issue 1: $RP"$'\n- Blocking issue: '"$CI")" = yes ] \
  && ok "M12 number required again: an unnumbered code issue hides behind the refusal" || bad "M12: stayed green (or could not build)"
mutate 'sub(/^[^a-z]*blocking[^a-z]+issue[^a-z]*/, "", l)' 'sub(/^[^a-z]*blocking[^a-z]+issue[ \t0-9:]*/, "", l)' && [ "$(pred "$REF1")" = yes ] && [ "$(pred $'VERDICT: FAIL\n**Blocking issue 1:** '"$RP")" = no ] \
  && ok "M13 decoration left in front of the title: a refusal under ** is not recognised (liveness: the plain refusal still reads yes, so awk ran)" || bad "M13: stayed green (or could not build)"

echo ""
echo "== gate-lane-scope-refusal-cases: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
