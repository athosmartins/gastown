#!/usr/bin/env bash
# gate-e5-second-reviewer.selftest.sh (ga-syxaki, E5)
#
# Proves the E5 experiment's contract — the parts that can hurt the gate if they are wrong:
#   1. OFF by default, and off means INERT (no bd/gc call, prompt pieces empty).
#   2. The arm is a pure, balanced SHA-256-parity function of a salted bead id (the documented spec,
#      recomputed with hashlib) and is independent of the ga-rstae arm and of E3's pre-gate arm.
#   3. The 800-line trigger is exactly >= 800, and "could not measure" is not "small".
#   4. The 2nd reviewer's task is built from the REAL render of the shared prompt lib
#      (gate-review-task.lib.sh: anchors pinned against what gate_render_review_task prints),
#      carries none of reviewer 1's verdict, and a drifted template is refused, not guessed.
#   5. That prompt lib differs from the pre-E5 one only by two optional tokens that expand to
#      nothing with the flag off — for the gate AND for the builder's pre-gate text mode (the
#      bash 3.2 parse of the dispatcher and both libs is checked too).
#   6. The union (gate-e5-union.py) merges a duplicate, keeps every distinct issue, never
#      merges two issues of one reviewer, and every failure falls back to the concatenation.
#   7. The Phase C hook: first-fail spawn only under every condition; every refusal is a
#      logged decline that leaves the run exactly as arm A would have it; an extra that can
#      no longer help is retired; one attempt per run.
#   8. gate_collect_verdicts (the REAL block, extracted): flag off -> FAIL_REASONS is the
#      legacy text; extra present + 2 judged FAILs -> the union; union broken -> legacy text.
#   9. The daily spend cap, including its "unknown" state.
#  10. Every E5 call site in the dispatcher sits behind the GATE_E5_LIB_OK guard.
# Mutation checks at the end prove the suite is not vacuous.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
LIB="$SELF_DIR/gate-e5-second-reviewer.lib.sh"
TASKLIB="$SELF_DIR/gate-review-task.lib.sh"
UNION="$SELF_DIR/gate-e5-union.py"
GUARD="$SELF_DIR/quality-gate-guard.sh"
BASH32=/bin/bash

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 (=$3)"; else bad "$1 — expected '$2', got '$3'"; fi
}

echo "== gate-e5-second-reviewer.selftest =="
for f in "$DISPATCHER" "$LIB" "$UNION" "$TASKLIB"; do
  [ -r "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-e5-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}
# ── 0. parse ────────────────────────────────────────────────────────────────────
echo "── 0. Everything parses under the host's real bash (3.2) ──"
"$BASH32" -n "$DISPATCHER" 2>"$TMP/syn.err" && ok "quality-gate-dispatcher.sh parses under $BASH32" || bad "dispatcher does NOT parse under $BASH32: $(head -2 "$TMP/syn.err")"
"$BASH32" -n "$LIB" 2>"$TMP/syn.err" && ok "gate-e5-second-reviewer.lib.sh parses under $BASH32" || bad "lib does NOT parse under $BASH32: $(head -2 "$TMP/syn.err")"
"$BASH32" -n "$TASKLIB" 2>"$TMP/syn.err" && ok "gate-review-task.lib.sh parses under $BASH32" || bad "task lib does NOT parse under $BASH32: $(head -2 "$TMP/syn.err")"
python3 -m py_compile "$UNION" 2>"$TMP/syn.err" && ok "gate-e5-union.py compiles" || bad "union script does not compile: $(head -2 "$TMP/syn.err")"

# run a snippet against the lib under bash 3.2 with strict flags, like the dispatcher
run_lib() { # run_lib <env-assignments...> -- <script>   (script read from stdin)
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMP" GC_CITY="$TMP/city" ${envs[@]+"${envs[@]}"} "$BASH32" -c "set -euo pipefail; source '$LIB'; $(cat)"
}
mkdir -p "$TMP/city/.gc"

# ── 1. flag ─────────────────────────────────────────────────────────────────────
echo "── 1. The flag: off by default; off means inert ──"
check "no env, no flag file -> off" 0 "$(run_lib -- <<<'gate_e5_enabled')"
touch "$TMP/city/.gc/gate-e5-second-reviewer.on"
check "flag file present -> on" 1 "$(run_lib -- <<<'gate_e5_enabled')"
check "GATE_E5_ENABLED=0 beats the file" 0 "$(run_lib GATE_E5_ENABLED=0 -- <<<'gate_e5_enabled')"
rm -f "$TMP/city/.gc/gate-e5-second-reviewer.on"
check "GATE_E5_ENABLED=1 without a file -> on" 1 "$(run_lib GATE_E5_ENABLED=1 -- <<<'gate_e5_enabled')"
check "GATE_E5_ENABLED=yes (garbage) and no file -> off" 0 "$(run_lib GATE_E5_ENABLED=yes -- <<<'gate_e5_enabled')"
check "unreadable state (no GC_CITY at all) -> off" 0 "$(env -i PATH="$PATH" "$BASH32" -c "set -euo pipefail; source '$LIB'; gate_e5_enabled")"
check "flag off -> the prompt pieces are EMPTY" "[][]" "$(run_lib -- <<<'gate_e5_task_vars; printf "[%s][%s]" "$GATE_E5_COV_RULES" "$GATE_E5_COV_PASS_LINE"')"
OUT="$(run_lib GATE_E5_ENABLED=1 -- <<<'gate_e5_task_vars; printf "%s|%s" "$GATE_E5_COV_RULES" "$GATE_E5_COV_PASS_LINE"')"
case "$OUT" in *"COVERAGE REPORT (required)"*"a FAIL comment as much as a PASS one"*"|Coverage: <"*) ok "flag on -> rules paragraph (PASS and FAIL) + the PASS template line" ;; *) bad "flag on but the coverage pieces are wrong: $OUT" ;; esac

# ── 2. arm ──────────────────────────────────────────────────────────────────────
echo "── 2. The arm: SHA-256 parity of a salted id — pure, balanced, independent of ga-rstae and of E3 ──"
python3 - "$TMP/arm-ids.txt" <<'EOF'
import hashlib, sys
ids = ["ga-%s" % hashlib.md5(str(k).encode()).hexdigest()[:6] for k in range(4000)]
open(sys.argv[1], "w").write("\n".join(ids) + "\n")
EOF
# the spec, computed independently of the bash function (hashlib): B <=> first 32 bits even
python3 - "$TMP/arm-ids.txt" "$TMP/arm-spec.txt" "$TMP/arm-e3.txt" <<'EOF'
import hashlib, sys
ids = open(sys.argv[1]).read().split()
def first32(salt, b): return int(hashlib.sha256((salt + b).encode()).hexdigest()[:8], 16)
open(sys.argv[2], "w").write("\n".join("%s %s" % (b, "B" if first32("e5-second-reviewer:", b) % 2 == 0 else "A") for b in ids) + "\n")
open(sys.argv[3], "w").write("\n".join("%s %s" % (b, "on" if first32("pregate:", b) % 2 == 0 else "off") for b in ids) + "\n")
EOF
SAMPLE="$(head -60 "$TMP/arm-spec.txt")"
GOT="$(printf '%s\n' "$SAMPLE" | awk '{print $1}' | while read -r id; do printf '%s %s\n' "$id" "$(run_lib -- <<<"gate_e5_arm_for_bead $id")"; done)"
[ "$GOT" = "$SAMPLE" ] && ok "the bash function equals the documented spec (SHA-256 of 'e5-second-reviewer:<id>', even = B) on 60 ids" || bad "bash arm differs from the spec on: $(diff <(printf '%s\n' "$SAMPLE") <(printf '%s\n' "$GOT") | head -3 | tr '\n' ' ')"
NB="$(grep -c ' B$' "$TMP/arm-spec.txt")"
[ "$NB" -ge 1880 ] && [ "$NB" -le 2120 ] && ok "balanced over 4000 ids: B=$NB A=$((4000-NB))" || bad "lopsided split: B=$NB of 4000"
# independence vs the ga-rstae polynomial arm (real guard function) and vs E3's pre-gate arm: expect ~50% agreement
ARM_SRC="$(sed -n '/^gate_ab_arm_for_bead()/,/^}/p' "$GUARD")"
if [ -z "$ARM_SRC" ]; then bad "could not extract gate_ab_arm_for_bead from the guard"; else
  env -i PATH="$PATH" "$BASH32" -c "set -euo pipefail; $ARM_SRC; while read -r id; do printf '%s %s\n' \"\$id\" \"\$(gate_ab_arm_for_bead \"\$id\")\"; done" < "$TMP/arm-ids.txt" > "$TMP/arm-rstae.txt"
  AG="$(paste -d' ' "$TMP/arm-spec.txt" "$TMP/arm-rstae.txt" | awk '$2==$4 {n++} END {print n+0}')"
  [ "$AG" -ge 1840 ] && [ "$AG" -le 2160 ] && ok "independent of the ga-rstae arm: agree on $AG of 4000 (≈2000 expected; a salted polynomial gave 43%)" || bad "E5 arm correlates with the ga-rstae arm: agree on $AG of 4000"
fi
AG3="$(paste -d' ' "$TMP/arm-spec.txt" "$TMP/arm-e3.txt" | awk '($2=="B" && $4=="on") || ($2=="A" && $4=="off") {n++} END {print n+0}')"
[ "$AG3" -ge 1840 ] && [ "$AG3" -le 2160 ] && ok "independent of E3's pre-gate arm: agree on $AG3 of 4000" || bad "E5 arm correlates with the pre-gate arm: agree on $AG3 of 4000"
check "empty bead id: no arm (nothing printed, rc 2) — never read as A" "|2" "$(run_lib -- <<<'set +e; out=$(gate_e5_arm_for_bead ""); echo "$out|$?"')"
mkdir -p "$TMP/nobin"; ln -sf "$(command -v cut)" "$TMP/nobin/cut"
check "no sha tool on PATH: no arm (nothing printed, rc 3) — never read as A" "|3" "$(env -i PATH="$TMP/nobin" GC_CITY="$TMP/city" "$BASH32" -c "source '$LIB'; set +e; out=\$(gate_e5_arm_for_bead ga-x); echo \"\$out|\$?\"")"
X1="$(run_lib -- <<<'gate_e5_arm_for_bead ga-abc123')"; X2="$(run_lib -- <<<'gate_e5_arm_for_bead ga-abc123')"
[ "$X1" = "$X2" ] && ok "same bead id -> same arm on every call ($X1)" || bad "arm is not stable: $X1 $X2"
# arm ids used by the scenarios below (first of each arm from the spec list)
ARM_B_ID="$(awk '$2=="B" {print $1; exit}' "$TMP/arm-spec.txt")"; ARM_A_ID="$(awk '$2=="A" {print $1; exit}' "$TMP/arm-spec.txt")"
[ -n "$ARM_B_ID" ] && [ -n "$ARM_A_ID" ] && ok "fixture beads: arm A=$ARM_A_ID arm B=$ARM_B_ID" || bad "could not find one bead per arm"

# ── 3. size trigger ─────────────────────────────────────────────────────────────
echo "── 3. The 800-line trigger ──"
for pair in "0:no" "799:no" "800:yes" "801:yes" "5000:yes" ":unknown" "abc:unknown" "12x:unknown"; do
  v="${pair%%:*}"; want="${pair##*:}"
  check "size_state('$v')" "$want" "$(run_lib -- <<<"gate_e5_size_state '$v'")"
done
check "threshold is configurable (env 100: 100 -> yes)" yes "$(run_lib GATE_E5_SIZE_THRESHOLD_LINES=100 -- <<<"gate_e5_size_state 100")"
check "a garbage threshold falls back to 800 (799 -> no)" no "$(run_lib GATE_E5_SIZE_THRESHOLD_LINES=zzz -- <<<"gate_e5_size_state 799")"

# ── 4/5. the real task template (gate-review-task.lib.sh) ────────────────────────
echo "── 4. The shared prompt lib: only two optional E5 tokens, empty when off; the extra task is built from the REAL render ──"
check "optional E5 tokens in the task lib's code (comments excluded): exactly 2 (rules + PASS line)" 2 "$(grep -v '^[[:space:]]*#' "$TASKLIB" | grep -o 'GATE_E5_[A-Z_]*' | wc -l | tr -d ' ')"
check "both are read as \${VAR:-} (a caller that never sets them — the builder's pre-gate — still renders under set -u)" 2 "$(grep -c '{GATE_E5_COV_[A-Z_]*:-}' "$TASKLIB" | tr -d ' ')"
render_task() { # render_task <on|off> [bead|text] [tasklib-path] — the real render, flag state decides the pieces
  cat > "$TMP/render.sh" <<EOF
set -euo pipefail
source "$LIB"
source "${3:-$TASKLIB}"
GATE_E5_COV_RULES=""; GATE_E5_COV_PASS_LINE=""
[ "\${E5_SET_VARS:-1}" = "1" ] && gate_e5_task_vars
gate_render_review_task 1 1 "crew/x/ga-demo" "builder-1" gascity abc1234 "CORRECTNESS: focus on logic errors." "a.sh
b.py" "2 files" "FULL DIFF (complete):" "+line one
-line two" "$TMP/city" ga-vb0001 "${2:-bead}"
EOF
  env -i PATH="$PATH" GATE_E5_ENABLED="$([ "$1" = on ] && echo 1 || echo 0)" E5_SET_VARS="${E5_SET_VARS:-1}" "$BASH32" "$TMP/render.sh"
}
TASK_OFF="$(render_task off)"
[ -n "$TASK_OFF" ] && ok "flag-off task renders" || bad "flag-off task is empty"
sed -e 's/\${GATE_E5_COV_RULES:-}//' -e 's/\${GATE_E5_COV_PASS_LINE:-}//' "$TASKLIB" > "$TMP/tasklib.stripped.sh"
TASK_STRIPPED="$(render_task off bead "$TMP/tasklib.stripped.sh")"
[ "$TASK_OFF" = "$TASK_STRIPPED" ] && ok "flag-off rendering == rendering from the lib with the E5 tokens deleted (byte-identical to the pre-E5 prompt)" || bad "flag-off rendering differs from the token-less template"
case "$TASK_OFF" in *"Coverage"*) bad "flag-off task mentions Coverage" ;; *) ok "flag-off task never mentions Coverage" ;; esac
TEXT_OFF="$(E5_SET_VARS=0 render_task off text)"; TEXT_OFF_STRIPPED="$(E5_SET_VARS=0 render_task off text "$TMP/tasklib.stripped.sh")"
[ "$TEXT_OFF" = "$TEXT_OFF_STRIPPED" ] && ok "the BUILDER's text-mode prompt (vars never set) is byte-identical too" || bad "builder text-mode prompt changed"
TASK_ON="$(render_task on)"
case "$TASK_ON" in *"COVERAGE REPORT (required)"*) ok "flag-on task carries the coverage rules" ;; *) bad "flag-on task lacks the coverage rules" ;; esac
case "$TASK_ON" in *$'\nCoverage: <files/passages you examined'*"Non-blocking findings: <one per line as severity: description, or none>\""*) ok "flag-on PASS template has the Coverage line right before Non-blocking findings" ;; *) bad "flag-on PASS template is malformed" ;; esac
check "flag-on differs from flag-off ONLY by added text (every original line survives in order)" 0 "$(diff <(printf '%s\n' "$TASK_OFF") <(printf '%s\n' "$TASK_ON") | grep -c '^<' | tr -d ' ')"
check "flag-on added text is exactly the rules paragraph + the PASS line" 2 "$(diff <(printf '%s\n' "$TASK_OFF") <(printf '%s\n' "$TASK_ON") | grep -c '^> COVERAGE REPORT\|^> Coverage:')"
cat > "$TMP/extra.sh" <<'EOF'
t="$(cat "$TASK_FILE")"
out="$(gate_e5_extra_task "$t" ga-vb0001 ga-vb0002)"; rc=$?
printf 'RC=%s\n' "$rc"
case "$out" in *"You are reviewer 2 of 2 for branch:"*) echo SLOT=ok ;; *) echo SLOT=BAD ;; esac
case "$out" in *"You are reviewer 1 of 1"*) echo OLDSLOT=present ;; *) echo OLDSLOT=gone ;; esac
case "$out" in *"YOUR REVIEW LENS: CORRECTNESS — INDEPENDENT FULL-COVERAGE PASS"*) echo LENS=ok ;; *) echo LENS=BAD ;; esac
case "$out" in *"CORRECTNESS: focus on logic errors."*) echo OLDLENS=present ;; *) echo OLDLENS=gone ;; esac
case "$out" in *ga-vb0001*) echo VB1=present ;; *) echo VB1=gone ;; esac
n=$(printf '%s' "$out" | grep -o 'ga-vb0002' | wc -l | tr -d ' '); echo "VB2COUNT=$n"
case "$out" in *"+line one"*"-line two"*) echo DIFF=kept ;; *) echo DIFF=LOST ;; esac
case "$out" in *VERDICT:\ PASS*) echo VERDICTTEMPLATE=kept ;; *) echo VERDICTTEMPLATE=LOST ;; esac
EOF
printf '%s' "$TASK_ON" > "$TMP/task.on"
EXTRA_OUT="$(TASK_FILE="$TMP/task.on" run_lib TASK_FILE="$TMP/task.on" -- < "$TMP/extra.sh")"
for kv in RC=0 SLOT=ok OLDSLOT=gone LENS=ok OLDLENS=gone VB1=gone DIFF=kept VERDICTTEMPLATE=kept; do
  case "$EXTRA_OUT" in *"$kv"*) ok "extra task: $kv" ;; *) bad "extra task: wanted $kv — got: $(printf '%s' "$EXTRA_OUT" | tr '\n' ' ')" ;; esac
done
V2N="$(printf '%s' "$EXTRA_OUT" | sed -n 's/^VB2COUNT=//p')"
OWN="$(printf '%s' "$TASK_ON" | grep -o 'ga-vb0001' | wc -l | tr -d ' ')"
check "every verdict-bead id of reviewer 1 became reviewer 2's ($OWN occurrences)" "$OWN" "$V2N"
# independence: the task is the diff + instructions, never a verdict
case "$TASK_ON" in *"Blocking issue 1:"*"VERDICT: FAIL"*) : ;; esac
# a drifted template is refused, not guessed
for mut in 's/You are reviewer 1 of 1 for branch:/You are the first reviewer of branch:/' 's/^YOUR REVIEW LENS:/LENS:/' 's/ga-vb0001/ga-other/g'; do
  printf '%s' "$TASK_ON" | sed "$mut" > "$TMP/task.mut"
  RC="$(TASK_FILE="$TMP/task.mut" run_lib TASK_FILE="$TMP/task.mut" -- <<<'t="$(cat "$TASK_FILE")"; set +e; gate_e5_extra_task "$t" ga-vb0001 ga-vb0002 >/dev/null; echo $?')"
  [ "$RC" != "0" ] && ok "drifted template refused (rc=$RC): $mut" || bad "drifted template was ACCEPTED: $mut"
done
check "empty task refused" 1 "$(run_lib -- <<<'set +e; gate_e5_extra_task "" a b >/dev/null; echo $?')"

# ── 6. the union ────────────────────────────────────────────────────────────────
echo "── 6. The union (gate-e5-union.py) ──"
union() { python3 "$UNION"; }
mk_payload() { python3 - "$@" <<'EOF'
import json, sys
print(json.dumps({"reviewers": [{"index": int(a.split("=",1)[0]), "text": open(a.split("=",1)[1]).read()} for a in sys.argv[1:]]}))
EOF
}
cat > "$TMP/r1.txt" <<'EOF'
VERDICT: FAIL
Lens: CORRECTNESS. Reviewed the FULL diff.

Blocking issue 1 — THIRD STATE: a KNOWN verdict is overwritten by a FAILED judge (scripts/voicebot_campaign.py:366-377).
The judge is gated on cp._human_spoke(...), not on outcome == "atendeu". If the judge returns INDETERMINADO line 375 overwrites it with "optout".

Blocking issue 2 — THIRD STATE: INDETERMINADO is written into durable compliance lists as a verified fact (scripts/voicebot_campaign.py:553-561).
record_optout_everywhere gets no reason.

Non-blocking findings:
low: something minor
Coverage: scripts/voicebot_campaign.py, capture_policy.py
EOF
cat > "$TMP/r2.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: The judge verdict INDETERMINADO overwrites a known outcome (voicebot_campaign.py:370-376) — third state collapsed: the judge is invoked even for voicemail, and when it fails the known caixa_postal becomes optout.
Blocking issue 2: capture_policy.py:1332 the stem regex admits past tense statements ("tirei meu número") as opt-outs.
Blocking issue 3: a lying comment in docs/data_dictionary.md:40 says final_outcome optout never means judge unavailable.
Coverage: voicebot_campaign.py, capture_policy.py, data_dictionary.md
EOF
mk_payload "1=$TMP/r1.txt" "2=$TMP/r2.txt" | union > "$TMP/u.json"; RC=$?
check "union exits 0 on two real-shaped verdicts" 0 "$RC"
TXT="$(jq -r .text "$TMP/u.json")"
case "$TXT" in "Reviewer 1 FAIL: VERDICT: FAIL — E5: union of 2 independent reviews"*) ok "keeps the 'Reviewer N FAIL:' prefix the watchdogs parse" ;; *) bad "merged text lost its 'Reviewer N FAIL:' prefix: $(printf '%s' "$TXT" | head -1)" ;; esac
check "issues: 2 + 3 = 5 in, 1 duplicate merged, 4 distinct out" "2,3,1,4" "$(jq -r '[.stats.issues_by_reviewer["1"], .stats.issues_by_reviewer["2"], .stats.duplicates_merged, .stats.distinct_issues] | join(",")' "$TMP/u.json")"
check "the duplicate is marked as independently confirmed" 1 "$(printf '%s' "$TXT" | grep -c 'found by reviewer 1 and reviewer 2 — independently confirmed')"
check "the issue only reviewer 1 found survives" 1 "$(printf '%s' "$TXT" | grep -c 'INDETERMINADO is written into durable compliance lists')"
check "both issues only reviewer 2 found survive" 2 "$(printf '%s' "$TXT" | grep -c -e 'stem regex admits past tense' -e 'lying comment in docs/data_dictionary.md')"
check "issues are renumbered 1..4" 4 "$(printf '%s' "$TXT" | grep -c '^Blocking issue [1-4]')"
check "non-blocking findings and both Coverage lines are kept verbatim" 3 "$(printf '%s' "$TXT" | grep -c -e 'low: something minor' -e 'Coverage: scripts/voicebot_campaign.py' -e 'Coverage: voicebot_campaign.py')"

# never merge two issues of ONE reviewer, even if they look alike
cat > "$TMP/same.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: swallowed error in run.sh:10 returns default zero
Blocking issue 2: swallowed error in run.sh:11 returns default zero
EOF
cat > "$TMP/other.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: an unrelated problem in other.py:5 with the parser
EOF
mk_payload "1=$TMP/same.txt" "2=$TMP/other.txt" | union | jq -r '.stats | "\(.duplicates_merged),\(.distinct_issues)"' > "$TMP/o.txt"
check "two similar issues of the SAME reviewer stay two (0 merged, 3 distinct)" "0,3" "$(cat "$TMP/o.txt")"
# same file+line but a DIFFERENT defect (low overlap) -> kept
cat > "$TMP/d1.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: run.sh:40 swallows the curl failure and returns an empty default instead of an error
EOF
cat > "$TMP/d2.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: run.sh:40 the comment above claims retries happen three times but the loop body executes once
EOF
mk_payload "1=$TMP/d1.txt" "2=$TMP/d2.txt" | union | jq -r '.stats | "\(.duplicates_merged),\(.distinct_issues)"' > "$TMP/o.txt"
check "same file:line but a different defect stays separate (0 merged, 2 distinct)" "0,2" "$(cat "$TMP/o.txt")"
# explicit, DIFFERENT class tags decide it even when the text overlaps
cat > "$TMP/c1.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1 (class: third-state): run.sh:40 swallows the curl failure and returns an empty default
EOF
cat > "$TMP/c2.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1 (class: comment-lies): run.sh:40 swallows the curl failure and returns an empty default
EOF
mk_payload "1=$TMP/c1.txt" "2=$TMP/c2.txt" | union | jq -r '.stats | "\(.duplicates_merged),\(.distinct_issues)"' > "$TMP/o.txt"
check "different explicit class tags -> not duplicates" "0,2" "$(cat "$TMP/o.txt")"
# a comment with no 'Blocking issue' marker is kept whole, never dropped
cat > "$TMP/free.txt" <<'EOF'
VERDICT: FAIL
The migration drops the index before the backfill finishes; readers time out in between.
EOF
mk_payload "1=$TMP/free.txt" "2=$TMP/other.txt" | union | jq -r '.text' > "$TMP/o.txt"
check "an unmarked free-form FAIL is kept whole" 1 "$(grep -c 'migration drops the index before the backfill' "$TMP/o.txt")"
# bad input -> exit 2, nothing on stdout
echo '{"reviewers": []}' | python3 "$UNION" >/dev/null 2>&1; check "empty reviewer list -> exit 2" 2 "$?"
echo 'not json' | python3 "$UNION" >/dev/null 2>&1; check "invalid JSON -> exit 2" 2 "$?"
echo '{"reviewers":[{"index":1,"text":"  "}]}' | python3 "$UNION" >/dev/null 2>&1; check "blank reviewer text -> exit 2" 2 "$?"

# bash side: gate_e5_union_reasons and its fallbacks
cat > "$TMP/ur.sh" <<'EOF'
warn() { echo "WARN: $*" >&2; }; log() { :; }
T1="$(cat "$R1")"; T2="$(cat "$R2")"
legacy() { FAIL_REASONS="Reviewer 1 FAIL: ${T1}\nReviewer 2 FAIL: ${T2}\n"; }
legacy; BEFORE="$FAIL_REASONS"
GATE_E5_FAIL_IDX=(1 2); GATE_E5_FAIL_TXT=("$T1" "$T2")
gate_e5_union_reasons
case "$FAIL_REASONS" in "Reviewer 1 FAIL: VERDICT: FAIL — E5: union"*) echo "UNION=applied" ;; *) echo "UNION=NOT-applied" ;; esac
case "$FAIL_REASONS" in *'\n') echo "TAIL=backslash-n" ;; *) echo "TAIL=BAD" ;; esac
[ -n "$GATE_E5_UNION_STATS" ] && echo "STATS=set" || echo "STATS=EMPTY"
# one FAIL only -> untouched
legacy; GATE_E5_FAIL_IDX=(1); GATE_E5_FAIL_TXT=("$T1"); gate_e5_union_reasons
[ "$FAIL_REASONS" = "$BEFORE" ] && echo "ONE=untouched" || echo "ONE=CHANGED"
# script missing / failing / malformed -> untouched
for s in /nonexistent/union.py "$BROKEN" "$GARBAGE"; do
  legacy; GATE_E5_FAIL_IDX=(1 2); GATE_E5_FAIL_TXT=("$T1" "$T2"); GATE_E5_UNION_SCRIPT="$s" gate_e5_union_reasons 2>/dev/null
  [ "$FAIL_REASONS" = "$BEFORE" ] && echo "FALLBACK=ok" || echo "FALLBACK=CHANGED($s)"
done
EOF
printf '%s\n' 'import sys; sys.exit(3)' > "$TMP/broken.py"
printf '%s\n' 'import json; print(json.dumps({"text": "no prefix here", "stats": {}}))' > "$TMP/garbage.py"
UR_OUT="$(run_lib GATE_E5_UNION_SCRIPT="$UNION" R1="$TMP/r1.txt" R2="$TMP/r2.txt" BROKEN="$TMP/broken.py" GARBAGE="$TMP/garbage.py" -- < "$TMP/ur.sh" 2>"$TMP/ur.err")"
for kv in UNION=applied TAIL=backslash-n STATS=set ONE=untouched; do case "$UR_OUT" in *"$kv"*) ok "gate_e5_union_reasons: $kv" ;; *) bad "gate_e5_union_reasons: wanted $kv — got $(printf '%s' "$UR_OUT" | tr '\n' ' ')" ;; esac; done
check "missing / failing / malformed union script -> legacy concatenation kept (3 of 3)" 3 "$(printf '%s' "$UR_OUT" | grep -c '^FALLBACK=ok')"
# (the GATE_E5_UNION_SCRIPT env above is per-call in the snippet; the first call uses the suite's real script)

# ── 9. cap ──────────────────────────────────────────────────────────────────────
echo "── 9. The daily spend cap ──"
check "30 / 0.60 -> 50 extra reviews a day" 50 "$(run_lib -- <<<'gate_e5_cap_max')"
check "cap 3 / est 1 -> 3" 3 "$(run_lib GATE_E5_DAILY_CAP_USD=3 GATE_E5_EST_COST_USD=1 -- <<<'gate_e5_cap_max')"
check "garbage cap -> empty (unknown)" "" "$(run_lib GATE_E5_DAILY_CAP_USD=abc -- <<<'gate_e5_cap_max')"
check "zero estimate -> empty (unknown)" "" "$(run_lib GATE_E5_EST_COST_USD=0 -- <<<'gate_e5_cap_max')"
check "garbage cap -> state unknown (never 'ok')" unknown "$(run_lib GATE_E5_DAILY_CAP_USD=abc -- <<<'gate_e5_cap_state')"
rm -f "$TMP/city/.gc/gate-e5-spend-"*
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "$@" >> "%s/notify.log"\n' "$TMP" > "$TMP/bin/notify"; chmod +x "$TMP/bin/notify"
CAP_OUT="$(PATH="$TMP/bin:$PATH" run_lib GATE_E5_DAILY_CAP_USD=2 GATE_E5_EST_COST_USD=1 -- <<<'echo "s0=$(gate_e5_cap_state)"; gate_e5_spend_record >/dev/null; echo "s1=$(gate_e5_cap_state)"; gate_e5_spend_record >/dev/null; echo "s2=$(gate_e5_cap_state)"; gate_e5_spend_record >/dev/null; echo "s3=$(gate_e5_cap_state)"')"
check "cap 2: ok -> ok -> capped -> capped" "s0=ok s1=ok s2=capped s3=capped" "$(printf '%s' "$CAP_OUT" | tr '\n' ' ' | sed 's/ $//')"
check "the cap pages exactly once (notify called once)" 1 "$(wc -l < "$TMP/notify.log" 2>/dev/null | tr -d ' ')"
echo "x" > "$(ls "$TMP"/city/.gc/gate-e5-spend-*.count | head -1)"
check "a corrupt counter -> unknown (never 'ok')" unknown "$(run_lib GATE_E5_DAILY_CAP_USD=2 GATE_E5_EST_COST_USD=1 -- <<<'gate_e5_cap_state')"
rm -f "$TMP"/city/.gc/gate-e5-spend-*

# ── 7. Phase C hook + spawn (mocked bd/gc) ──────────────────────────────────────
echo "── 7. The Phase C hook and the extra-reviewer spawn (mocked bd / gc) ──"
cat > "$TMP/prelude.sh" <<'EOF'
set -euo pipefail
FIX="$FIXDIR"; CALLS="$FIX/calls.log"; : > "$CALLS"
log()  { echo "LOG: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
_ts_to_epoch() { python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"; }
gc_json_or_unknown() { "$@"; }
reviewer_session_confirmed_closed() { [ -f "$FIX/closed-$1" ] && echo 1 || echo 0; }
assign_verdict_bead_verified() { echo "assign $1 $2" >> "$CALLS"; return 0; }
gate_nudge() { echo "nudge $1" >> "$CALLS"; return 0; }
gate_collect_verdicts() { echo "collect" >> "$CALLS"; }
bd() {
  case " $* " in
    *" show "*)     local id; id=$(printf '%s\n' "$@" | awk '/^show$/ {getline; print; exit}'); [ -f "$FIX/show-$id.json" ] && { cat "$FIX/show-$id.json"; return 0; }; return 1 ;;
    *" comments "*) local id; id=$(printf '%s\n' "$@" | awk '/^comments$/ {getline; print; exit}'); [ -f "$FIX/comments-$id.json" ] && cat "$FIX/comments-$id.json" || echo "[]"; return 0 ;;
    *" create "*)   echo "create $*" >> "$CALLS"; [ -f "$FIX/create-fail" ] && return 1; echo '{"id":"ga-newvb1"}'; return 0 ;;
    *)              echo "bd $*" >> "$CALLS"; return 0 ;;
  esac
}
gc() {
  case " $* " in
    *" session new "*)  [ -f "$FIX/spawn-fail" ] && { echo "session-new-failed" >> "$CALLS"; echo '{}'; return 0; }; echo "session-new" >> "$CALLS"; echo '{"session_id":"ga-wisp-new1","session_name":"gate-reviewer-adhoc-new1","session_key":"key-new1"}'; return 0 ;;
    *" session list "*) [ -f "$FIX/sessions.json" ] && cat "$FIX/sessions.json" || echo '{"sessions":[]}'; return 0 ;;
    *" session peek "*) echo "scrollback"; return 0 ;;
    *)                  echo "gc $*" >> "$CALLS"; return 0 ;;
  esac
}
git_rig() { echo "git_rig $*" >> "$CALLS"; return 0; }
GC_CITY="$CITYDIR"; QG_LOG="$CITYDIR/.gc/quality-gate.jsonl"; BRANCH="crew/x/ga-demo"; GATE_RUN_ID="ga-run001"; BEAD_CITY="$CITYDIR"
source "$LIBFILE"
EOF
TASK1_TEXT="$(printf '%s' "$TASK_OFF" | sed 's/ga-vb0001/ga-vb0001/g')"
new_fix() { # new_fix <name> -> echoes the fixture dir
  local d="$TMP/fix-$1"; rm -rf "$d"; mkdir -p "$d"; : > "$TMP/city/.gc/quality-gate.jsonl"; rm -f "$TMP"/city/.gc/gate-e5-spend-*
  jq -n --arg t "$TASK1_TEXT" '[{"text":$t}]' > "$d/comments-ga-vb0001.json"
  echo "$d"
}
scn() { # scn <fixdir> <env...> -- <script>
  local fix="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  { cat "$TMP/prelude.sh"; cat; } > "$fix/scn.sh"
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMP" FIXDIR="$fix" CITYDIR="$TMP/city" LIBFILE="$LIB" ${envs[@]+"${envs[@]}"} "$BASH32" "$fix/scn.sh" 2>"$fix/stderr"
}
HOOK_COMMON='
VB_JSON="[{\"id\":\"ga-vb0001\",\"status\":\"closed\",\"created_at\":\"2026-09-30T17:00:00Z\",\"labels\":[\"type:quality-gate-verdict\",\"reviewer-index:1\",\"verdict:FAIL\"]}]"
VERDICT_BEAD_IDS=(ga-vb0001); SESSION_IDS=(rev-sess-1); REQUIRED_REVIEWERS=1
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=300; PC_TIMEOUT_SECS=1800
'
show_bead() { # show_bead <fixdir> <id> <labels-json-array>
  jq -n --arg id "$2" --argjson l "$3" '[{id:$id,status:"open",labels:$l}]' > "$1/show-$2.json"
}

echo "  · first-fail trigger:"
F="$(new_fix spawn)"; show_bead "$F" "$ARM_B_ID" '["story:in-flight"]'
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]} LAST=\${VERDICT_BEAD_IDS[1]:-none} SID=\${SESSION_IDS[1]:-none}"
EOF
)"
check "spawns: REQUIRED 1->2, extra slot appended" "REQ=2 N=2 LAST=ga-newvb1 SID=gate-reviewer-adhoc-new1" "$OUT"
C="$(cat "$F/calls.log")"
case "$C" in *"create"*"-l gate-run:ga-run001"*"-l reviewer-index:2"*"-l verdict:pending"*"-l e5-extra"*"-l e5-trigger:first-fail"*) ok "extra verdict bead carries gate-run, reviewer-index:2, verdict:pending, e5-extra, e5-trigger:first-fail" ;; *) bad "verdict bead labels wrong: $(grep create "$F/calls.log")" ;; esac
case "$C" in *"assign ga-newvb1 gate-reviewer-adhoc-new1"*) ok "durable pull: verdict bead assigned to the new session" ;; *) bad "verdict bead not assigned" ;; esac
case "$C" in *"comment ga-newvb1 QUALITY GATE REVIEW — You are reviewer 2 of 2"*) ok "the extra reviewer's task is embedded on its verdict bead" ;; *) bad "task not embedded: $(grep 'bd comment' "$F/calls.log" | cut -c1-150)" ;; esac
case "$C" in *"nudge ga-wisp-new1"*) ok "task queued to the new session" ;; *) bad "task not delivered" ;; esac
case "$C" in *"session pin ga-wisp-new1"*) ok "extra reviewer pinned (drain-exempt like reviewer 1)" ;; *) bad "extra reviewer not pinned" ;; esac
check "spend counted (1 extra review today)" 1 "$(cat "$TMP"/city/.gc/gate-e5-spend-*.count 2>/dev/null | head -1)"
check "event e5_extra_spawn logged with the session key (for cost)" "ga-run001|first-fail|ga-newvb1|key-new1" "$(jq -r 'select(.event=="e5_extra_spawn") | [.gate_run,.trigger,.extra_vb,.session_key] | join("|")' "$TMP/city/.gc/quality-gate.jsonl")"

decline_case() { # decline_case <label> <expected-reason> <fixture-mutator-cmd> <env> <hook-prelude-override>
  local label="$1" reason="$2" mut="$3" envs="$4" pre="$5"
  local f; f="$(new_fix "d-$label")"; show_bead "$f" "$ARM_B_ID" '["story:in-flight"]'
  [ -n "$mut" ] && eval "$mut"
  local out
  out="$(scn "$f" $envs -- <<EOF
BEAD_ID="${DECL_BEAD:-$ARM_B_ID}"
$HOOK_COMMON
$pre
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
  check "$label: run untouched (arm-A behaviour)" "REQ=1 N=1" "$out"
  if grep -q '^session-new$' "$f/calls.log"; then bad "$label: a session was spawned anyway"; else ok "$label: no session spawned"; fi
  if [ -n "$reason" ]; then
    check "$label: decline logged with its reason" "$reason" "$(jq -r 'select(.event=="e5_extra_declined") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1 | sed 's/:.*//')"
  fi
}
DECL_BEAD="$ARM_A_ID" decline_case "arm A" "" "show_bead \"\$f\" \"$ARM_A_ID\" '[]'" GATE_E5_ENABLED=1 ""
decline_case "flag off" "" "" GATE_E5_ENABLED=0 ""
decline_case "not the first FAIL (gate:fix-attempt:1)" "not-first-fail" "show_bead \"\$f\" \"$ARM_B_ID\" '[\"gate:fix-attempt:1\"]'" GATE_E5_ENABLED=1 ""
decline_case "source bead unreadable" "first-fail-unreadable" "rm -f \"\$f/show-$ARM_B_ID.json\"" GATE_E5_ENABLED=1 ""
decline_case "a no-verdict run (dead reviewer)" "" "" GATE_E5_ENABLED=1 "GATE_FAIL_NO_EVAL=1; GATE_COLLECT_JUDGED_FAILS=0"
decline_case "reviewer 1 PASSED" "" "" GATE_E5_ENABLED=1 "ANY_FAIL=0; GATE_COLLECT_JUDGED_FAILS=0"
decline_case "reviewer 1 has not delivered yet" "" "" GATE_E5_ENABLED=1 "VERDICTS_RECEIVED=0"
decline_case "run already past its timeout" "run-already-timed-out" "" GATE_E5_ENABLED=1 "PC_ELAPSED=4000"
decline_case "daily cap reached" "daily-cap-reached" "echo 50 > \"$TMP/city/.gc/gate-e5-spend-\$(date +%Y-%m-%d).count\"" GATE_E5_ENABLED=1 ""
decline_case "daily cap unreadable" "daily-cap-unreadable" "" "GATE_E5_ENABLED=1 GATE_E5_DAILY_CAP_USD=abc" ""
decline_case "reviewer 1's task not on its bead" "reviewer-1-task-unavailable" "echo '[]' > \"\$f/comments-ga-vb0001.json\"" GATE_E5_ENABLED=1 ""
decline_case "template drifted (anchor missing)" "task-anchor-missing" "jq -n '[{\"text\":\"QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: x\\nno lens line here ga-vb0001\"}]' > \"\$f/comments-ga-vb0001.json\"" GATE_E5_ENABLED=1 ""
decline_case "Claude quota exhausted" "claude-quota-limited" "" GATE_E5_ENABLED=1 "gate_quota_limited() { printf 1; }"
decline_case "no free session slot" "spawn-failed" "touch \"\$f/spawn-fail\"" GATE_E5_ENABLED=1 ""
# the verdict-bead create failing must also close the session it just opened
F="$(new_fix createfail)"; show_bead "$F" "$ARM_B_ID" '[]'; touch "$F/create-fail"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "verdict-bead create failed: run untouched" "REQ=1 N=1" "$OUT"
grep -q 'gc --city .* session close ga-wisp-new1' "$F/calls.log" && ok "verdict-bead create failed: the just-opened session was closed (no orphan)" || bad "orphan session left behind: $(cat "$F/calls.log")"
check "verdict-bead create failed: nothing counted against the cap" "" "$(cat "$TMP"/city/.gc/gate-e5-spend-*.count 2>/dev/null | head -1)"

echo "  · one attempt per run, and retiring an extra that cannot help:"
EXTRA_OPEN='[{"id":"ga-vb0001","status":"closed","created_at":"2026-09-30T17:00:00Z","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:FAIL"]},{"id":"ga-newvb1","status":"open","created_at":"__CREATED__","labels":["type:quality-gate-verdict","reviewer-index:2","verdict:pending","e5-extra","e5-trigger:first-fail"]}]'
retire_case() { # retire_case <label> <expected reason> <created_at> <pc_elapsed> <closed-session 0|1>
  local f; f="$(new_fix "r-$1")"; show_bead "$f" "$ARM_B_ID" '[]'
  jq -n '[{id:"ga-newvb1",status:"open",labels:["e5-extra"]}]' > "$f/show-ga-newvb1.json"
  [ "$5" = "1" ] && touch "$f/closed-gate-reviewer-adhoc-new1"
  local vbj="${EXTRA_OPEN/__CREATED__/$3}"
  local out
  out="$(scn "$f" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
VB_JSON='$vbj'
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(rev-sess-1 gate-reviewer-adhoc-new1); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=$4; PC_TIMEOUT_SECS=1800
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]} IDS=\${VERDICT_BEAD_IDS[*]}"
EOF
)"
  if [ -n "$2" ]; then
    check "$1: extra retired, slot dropped, REQUIRED back to 1" "REQ=1 N=1 IDS=ga-vb0001" "$out"
    check "$1: reason logged" "$2" "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"
    grep -q 'bd -C .* label add ga-newvb1 e5-extra-abandoned' "$f/calls.log" && ok "$1: verdict bead labelled e5-extra-abandoned (Phase C ignores it from now on)" || bad "$1: abandoned label not written"
    grep -q 'bd -C .* close ga-newvb1' "$f/calls.log" && ok "$1: verdict bead closed" || bad "$1: verdict bead not closed"
    grep -q 'session close gate-reviewer-adhoc-new1' "$f/calls.log" && ok "$1: extra session closed" || bad "$1: extra session not closed"
    grep -q '^collect$' "$f/calls.log" && ok "$1: verdicts re-collected without the extra" || bad "$1: no re-collect after dropping the slot"
  else
    check "$1: extra kept, run still waiting" "REQ=2 N=2 IDS=ga-vb0001 ga-newvb1" "$out"
    grep -q 'e5-extra-abandoned' "$f/calls.log" && bad "$1: abandoned although it can still deliver" || ok "$1: not abandoned"
  fi
}
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; OLD_ISO="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=45)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
retire_case "extra still young, run young, session alive" "" "$NOW_ISO" 300 0
retire_case "run timed out" "run-timeout" "$NOW_ISO" 4000 0
retire_case "extra older than the run's timeout" "extra-timeout" "$OLD_ISO" 300 0
retire_case "extra session confirmed closed" "extra-session-closed" "$NOW_ISO" 300 1
# extra already delivered (bead closed) -> nothing to do, not retired
F="$(new_fix delivered)"; jq -n '[{id:"ga-newvb1",status:"closed",labels:["e5-extra","verdict:FAIL"]}]' > "$F/show-ga-newvb1.json"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
VB_JSON='${EXTRA_OPEN/__CREATED__/$NOW_ISO}'
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(a b); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=2; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=2
PC_ELAPSED=4000; PC_TIMEOUT_SECS=1800
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "a DELIVERED extra is never retired (even past the timeout)" "REQ=2 N=2" "$OUT"
# one attempt per run: an ABANDONED extra blocks a second spawn
F="$(new_fix once)"; show_bead "$F" "$ARM_B_ID" '[]'
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
VB_JSON='[{"id":"ga-vb0001","status":"closed","labels":["verdict:FAIL"]},{"id":"ga-oldvb","status":"closed","labels":["e5-extra","e5-extra-abandoned"]}]'
VERDICT_BEAD_IDS=(ga-vb0001); SESSION_IDS=(a); REQUIRED_REVIEWERS=1
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=300; PC_TIMEOUT_SECS=1800
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "an abandoned extra blocks a second spawn for the same run" "REQ=1 N=1" "$OUT"
grep -q '^session-new$' "$F/calls.log" && bad "spawned a second extra for the same run" || ok "no second session"
# flag OFF + no extra bead -> not a single bd/gc call
F="$(new_fix inert)"
OUT="$(scn "$F" GATE_E5_ENABLED=0 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "flag off: hook changes nothing" "REQ=1 N=1" "$OUT"
check "flag off: hook made zero bd/gc calls" 0 "$(wc -l < "$F/calls.log" | tr -d ' ')"

echo "  · rehydrate:"
F="$(new_fix rehydrate)"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<'EOF'
VBJ='[{"id":"a","labels":["reviewer-index:1"]},{"id":"b","labels":["e5-extra","e5-extra-abandoned"]},{"id":"c","labels":["e5-extra"]}]'
VERDICT_BEAD_IDS=(a b c); REQUIRED_REVIEWERS=1
gate_e5_rehydrate "$VBJ"
echo "REQ=$REQUIRED_REVIEWERS IDS=${VERDICT_BEAD_IDS[*]}"
VBJ='[{"id":"a","labels":[]},{"id":"b","labels":["e5-extra","e5-extra-abandoned"]}]'
VERDICT_BEAD_IDS=(a b); REQUIRED_REVIEWERS=1
gate_e5_rehydrate "$VBJ"
echo "REQ=$REQUIRED_REVIEWERS IDS=${VERDICT_BEAD_IDS[*]}"
VBJ='[{"id":"a","labels":[]}]'
VERDICT_BEAD_IDS=(a); REQUIRED_REVIEWERS=1
gate_e5_rehydrate "$VBJ"
echo "REQ=$REQUIRED_REVIEWERS IDS=${VERDICT_BEAD_IDS[*]}"
EOF
)"
check "abandoned dropped, live extra counted (a b c -> a c, required 2)" "REQ=2 IDS=a c" "$(printf '%s' "$OUT" | sed -n 1p)"
check "only-abandoned extra: back to the base run" "REQ=1 IDS=a" "$(printf '%s' "$OUT" | sed -n 2p)"
check "no E5 beads: untouched" "REQ=1 IDS=a" "$(printf '%s' "$OUT" | sed -n 3p)"

echo "  · admission (big-diff) and the Step 7 glue:"
F="$(new_fix admit)"
mk_git() { # git_rig override returning N diff lines
  echo "git_rig() { echo \"git_rig \$*\" >> \"\$CALLS\"; if [ -f \"\$FIX/git-fail\" ]; then return 128; fi; seq 1 $1 | sed 's/^/+line /'; }"
}
for spec in "$ARM_B_ID:799:none" "$ARM_B_ID:800:big-diff" "$ARM_A_ID:5000:none"; do
  IFS=: read -r bead n want <<<"$spec"
  OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
$(mk_git "$n")
BEAD_ID="$bead"; DEFAULT_BRANCH=main; REQUIRED_REVIEWERS=1
gate_e5_admit_decision
echo "\$GATE_E5_ARM \$GATE_E5_TRIGGER \$GATE_E5_SIZE_STATE \${GATE_E5_RAW_LINES:-}"
EOF
)"
  case "$bead" in "$ARM_A_ID") wantarm=A ;; *) wantarm=B ;; esac
  case "$OUT" in "$wantarm $want "*) ok "admit: $bead ($wantarm) with $n diff lines -> trigger=$want" ;; *) bad "admit: $bead/$n expected trigger $want, got '$OUT'" ;; esac
done
touch "$F/git-fail"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
$(mk_git 900)
BEAD_ID="$ARM_B_ID"; DEFAULT_BRANCH=main; REQUIRED_REVIEWERS=1
gate_e5_admit_decision
echo "\$GATE_E5_ARM \$GATE_E5_TRIGGER \$GATE_E5_SIZE_STATE"
EOF
)"
check "admit: git diff failing is 'unknown', never 'small' and never a trigger" "B none unknown" "$OUT"
rm -f "$F/git-fail"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
$(mk_git 900)
BEAD_ID="$ARM_B_ID"; DEFAULT_BRANCH=main; REQUIRED_REVIEWERS=2
gate_e5_admit_decision
echo "\$GATE_E5_TRIGGER"
EOF
)"
check "admit: a base run that already has 2 reviewers gets no E5 trigger" none "$OUT"
F="$(new_fix step7)"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
REVIEW_TASKS=("$(printf '%s' "$TASK1_TEXT" | sed 's/"/\\"/g; s/\$/\\$/g; s/\`/\\\`/g')"); REVIEWER_PEEK_BASELINE=(111); REVIEWER_ACKED=(0)
VERDICT_BEAD_IDS=(ga-vb0001); SESSION_IDS=(ga-wisp-r1); REQUIRED_REVIEWERS=1; BEAD_ID="$ARM_B_ID"
GATE_SPAWN_STAGGER_SECS=0
gate_e5_step7_extra
echo "REQ=\$REQUIRED_REVIEWERS VB=\${VERDICT_BEAD_IDS[*]} SID=\${SESSION_IDS[*]} TASKS=\${#REVIEW_TASKS[@]} PEEK=\${#REVIEWER_PEEK_BASELINE[@]} ACK=\${REVIEWER_ACKED[*]}"
EOF
)"
check "Step 7 glue: extra appended to EVERY per-slot array (ACK pass covers it), REQUIRED=2" "REQ=2 VB=ga-vb0001 ga-newvb1 SID=ga-wisp-r1 ga-wisp-new1 TASKS=2 PEEK=2 ACK=0 0" "$OUT"
check "Step 7 glue: event says trigger=big-diff" big-diff "$(jq -r 'select(.event=="e5_extra_spawn") | .trigger' "$TMP/city/.gc/quality-gate.jsonl")"

# ── 8. the REAL gate_collect_verdicts ────────────────────────────────────────────
echo "── 8. gate_collect_verdicts (real block, extracted) with and without an extra reviewer ──"
FN_COLLECT="$(extract_block "$DISPATCHER" gate-collect-verdicts-fn)"
FN_PEEK="$(extract_block "$DISPATCHER" session-peek-reports-dead-fn)"
FN_IDENT="$(extract_block "$DISPATCHER" gate-verdict-identity-link-fn)"
[ -n "$FN_COLLECT" ] && [ -n "$FN_PEEK" ] && [ -n "$FN_IDENT" ] && ok "blocks extracted from the dispatcher" || bad "could not extract the collect blocks"
cp "$TMP/r1.txt" "$TMP/collect-r1.txt"; cp "$TMP/r2.txt" "$TMP/collect-r2.txt"
collect_case() { # collect_case <lib_ok 0|1> <extra_label yes|no> <union_script>
  local f="$TMP/collect-$1-$2.sh"
  {
    cat <<'EOF'
set -euo pipefail
GC_CITY="$CITYDIR"; QG_LOG="$CITYDIR/.gc/quality-gate.jsonl"
log()  { echo "LOG: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
bd() {
  case " $* " in
    *" show vb1 "*) echo '{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:FAIL"],"assignee":"s1"}'; return 0 ;;
    *" show vb2 "*) echo "{\"status\":\"closed\",\"labels\":[\"type:quality-gate-verdict\",\"reviewer-index:2\",\"verdict:FAIL\"$EXTRA_LABEL],\"assignee\":\"s2\"}"; return 0 ;;
    *" comments vb1 "*) jq -Rs '[{text: .}]' < "$R1"; return 0 ;;
    *" comments vb2 "*) jq -Rs '[{text: .}]' < "$R2"; return 0 ;;
    *" comments "*) echo "[]"; return 0 ;;
  esac
  return 0
}
gc() { return 0; }
EOF
    echo "$FN_PEEK"; echo "$FN_IDENT"; echo "$FN_COLLECT"
    if [ "$1" = "1" ]; then echo 'GATE_E5_LIB_OK=1; source "$LIBFILE"'; fi
    cat <<'EOF'
VERDICT_BEAD_IDS=(vb1 vb2)
gate_collect_verdicts
printf 'VR=%s ANY=%s JUDGED=%s EXTRA=%s/%s\n' "$VERDICTS_RECEIVED" "$ANY_FAIL" "$GATE_COLLECT_JUDGED_FAILS" "${GATE_E5_EXTRA_SEEN:-?}" "${GATE_E5_EXTRA_VERDICT:-?}"
# no `printf | head` / `printf | grep -q` here: under pipefail the early-exiting reader SIGPIPEs the writer
# on a long FAIL_REASONS and the verdict flips with timing (seen under load). Bash-native instead.
printf '%s\n' "${FAIL_REASONS:0:120}" | tr '\n' '~'; echo
case "$FAIL_REASONS" in *"E5: union of"*) echo UNION=yes ;; *) echo UNION=no ;; esac
case "$FAIL_REASONS" in *"Reviewer 2 FAIL: "*) echo LEGACY2=yes ;; *) echo LEGACY2=no ;; esac
EOF
  } > "$f"
  local lbl=""; [ "$2" = "yes" ] && lbl=',"e5-extra"'
  env -i HOME="$HOME" PATH="$PATH" CITYDIR="$TMP/city" LIBFILE="$LIB" R1="$TMP/collect-r1.txt" R2="$TMP/collect-r2.txt" EXTRA_LABEL="$lbl" \
    GATE_E5_UNION_SCRIPT="${3:-$UNION}" "$BASH32" "$f" 2>"$TMP/collect.err"
}
OUT="$(collect_case 0 no)"
case "$OUT" in *"VR=2 ANY=1 JUDGED=2"*"UNION=no"*"LEGACY2=yes"*) ok "lib absent / no extra: legacy 'Reviewer N FAIL:' concatenation, exactly as before" ;; *) bad "flag-off collect changed: $OUT" ;; esac
OUT="$(collect_case 1 no)"
case "$OUT" in *"UNION=no"*"LEGACY2=yes"*) ok "lib loaded but NO extra slot: still the legacy concatenation (union never touches a plain run)" ;; *) bad "union applied to a run with no extra slot: $OUT" ;; esac
OUT="$(collect_case 1 yes)"
case "$OUT" in *"VR=2 ANY=1 JUDGED=2 EXTRA=1/FAIL"*"UNION=yes"*"LEGACY2=no"*) ok "extra slot + 2 judged FAILs: the union replaces the concatenation; extra verdict recorded (FAIL)" ;; *) bad "extra run not unioned: $OUT" ;; esac
OUT="$(collect_case 1 yes /nonexistent/union.py)"
case "$OUT" in *"UNION=no"*"LEGACY2=yes"*) ok "union script missing: legacy concatenation kept (a lost finding is worse than a duplicate)" ;; *) bad "union failure lost the legacy text: $OUT" ;; esac

# the extra slot may only ADD a delivered verdict — never turn a reviewer-1 PASS into a FAIL
collect_case2() { # collect_case2 <vb1 json> <vb2 json> <vb2 comments json>
  local f="$TMP/collect2.sh"
  {
    cat <<'EOF'
set -euo pipefail
GC_CITY="$CITYDIR"; QG_LOG="$CITYDIR/.gc/quality-gate.jsonl"
log()  { echo "LOG: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
bd() {
  case " $* " in
    *" show vb1 "*) echo "$VB1"; return 0 ;;
    *" show vb2 "*) echo "$VB2"; return 0 ;;
    *" comments vb1 "*) echo '[{"text":"VERDICT: PASS\nSummary: fine"}]'; return 0 ;;
    *" comments vb2 "*) if [ "$VB2C" = "FAILREAD" ]; then return 1; fi; echo "$VB2C"; return 0 ;;
    *" comments "*) echo "[]"; return 0 ;;
  esac
  return 0
}
gc() { return 0; }
EOF
    echo "$FN_PEEK"; echo "$FN_IDENT"; echo "$FN_COLLECT"
    echo 'GATE_E5_LIB_OK=1; source "$LIBFILE"'
    cat <<'EOF'
VERDICT_BEAD_IDS=(vb1 vb2)
gate_collect_verdicts
printf 'VR=%s ANY=%s NOEVAL=%s JUDGED=%s UNDELIVERED=%s EXTRAV=%s\n' "$VERDICTS_RECEIVED" "$ANY_FAIL" "$GATE_FAIL_NO_EVAL" "$GATE_COLLECT_JUDGED_FAILS" "$GATE_E5_EXTRA_UNDELIVERED" "$GATE_E5_EXTRA_VERDICT"
EOF
  } > "$f"
  env -i HOME="$HOME" PATH="$PATH" CITYDIR="$TMP/city" LIBFILE="$LIB" VB1="$1" VB2="$2" VB2C="$3" "$BASH32" "$f" 2>"$TMP/collect.err"
}
V1P='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:PASS"],"assignee":"s1"}'
V2_NOVERDICT='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2","e5-extra"],"assignee":"s2"}'
V2_PASS='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2","e5-extra","verdict:PASS"],"assignee":"s2"}'
V2_FAIL='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2","e5-extra","verdict:FAIL"],"assignee":"s2"}'
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[]')"
check "R1 PASS + extra closed with NO verdict: run stays a PASS (extra not delivered, not counted)" "VR=1 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=1 EXTRAV=NONE" "$OUT"
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" FAILREAD)"
check "R1 PASS + extra closed, its comments UNREADABLE: still not a FAIL (an unreadable extra is 'not delivered', arm-A behaviour)" "VR=1 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=1 EXTRAV=NONE" "$OUT"
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[{"text":"VERDICT: FAIL\nBlocking issue 1: real defect in a.sh:3"}]')"
check "R1 PASS + extra closed with a FAIL *comment* but no label (label race): the delivered FAIL counts" "VR=2 ANY=1 NOEVAL=0 JUDGED=1 UNDELIVERED=0 EXTRAV=NONE" "$OUT"
OUT="$(collect_case2 "$V1P" "$V2_FAIL" '[{"text":"VERDICT: FAIL\nBlocking issue 1: real defect in a.sh:3"}]')"
check "R1 PASS + extra delivered FAIL: the run FAILs (an extra can add a rejection)" "VR=2 ANY=1 NOEVAL=0 JUDGED=1 UNDELIVERED=0 EXTRAV=FAIL" "$OUT"
OUT="$(collect_case2 "$V1P" "$V2_PASS" '[]')"
check "R1 PASS + extra delivered PASS: PASS" "VR=2 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=0 EXTRAV=PASS" "$OUT"
# and the plain (non-extra) path keeps today's strictness: a reviewer closed with no verdict IS a no-eval FAIL
V2_PLAIN_NOVERDICT='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2"],"assignee":"s2"}'
OUT="$(collect_case2 "$V1P" "$V2_PLAIN_NOVERDICT" '[]')"
check "a NORMAL reviewer closed with no verdict is still a no-evaluation FAIL (pre-E5 strictness untouched)" "VR=2 ANY=1 NOEVAL=1 JUDGED=0 UNDELIVERED=0 EXTRAV=-" "$OUT"

# hook: a closed extra that delivered nothing is retired
F="$(new_fix closedundelivered)"; show_bead "$F" "$ARM_B_ID" '[]'
jq -n '[{id:"ga-newvb1",status:"closed",labels:["e5-extra"]}]' > "$F/show-ga-newvb1.json"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
VB_JSON='${EXTRA_OPEN/__CREATED__/$NOW_ISO}'
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(a b); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=300; PC_TIMEOUT_SECS=1800; GATE_E5_EXTRA_UNDELIVERED=1
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS IDS=\${VERDICT_BEAD_IDS[*]}"
EOF
)"
check "hook: a closed-without-verdict extra is retired; the run is decided on reviewer 1" "REQ=1 IDS=ga-vb0001" "$OUT"
check "hook: reason logged" extra-closed-without-verdict "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"

# ── the switch script ───────────────────────────────────────────────────────────
echo "── 11. scripts/gate-e5-switch.sh: the Mayor's switch (cited authorization, not before the E2 window, status) ──"
SW="$SELF_DIR/../../../scripts/gate-e5-switch.sh"
if [ ! -x "$SW" ]; then bad "switch script missing or not executable: $SW"; else
  SWC="$TMP/swcity"; mkdir -p "$SWC/.gc"; rm -f "$SWC/.gc/gate-e5-second-reviewer.on"
  sw() { env -i HOME="$HOME" PATH="$PATH" GC_CITY="$SWC" "$@" "$BASH32" "$SW" "${SW_ARGS[@]}"; }
  SW_ARGS=(status); OUT="$(sw)"; case "$OUT" in *"DESLIGADO"*) ok "status: off by default" ;; *) bad "status did not say DESLIGADO: $OUT" ;; esac
  SW_ARGS=(on); sw GATE_E5_NOT_BEFORE_EPOCH=0 >/dev/null 2>&1; RC=$?
  [ "$RC" = "2" ] && [ ! -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && ok "on without a cited authorization: refused (rc 2), flag NOT written" || bad "on without authorization: rc=$RC, flag present=$([ -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && echo yes || echo no)"
  SW_ARGS=(on "Mayor, bead ga-syxaki #3, 2026-10-01T21:05-03"); sw GATE_E5_NOT_BEFORE_EPOCH=99999999999 >/dev/null 2>&1; RC=$?
  [ "$RC" = "3" ] && [ ! -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && ok "on before the E2 window closes: refused (rc 3), flag NOT written" || bad "early on: rc=$RC"
  SW_ARGS=(on "Mayor, bead ga-syxaki #3, 2026-10-01T21:05-03"); OUT="$(sw GATE_E5_NOT_BEFORE_EPOCH=0)"; RC=$?
  [ "$RC" = "0" ] && [ -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && ok "on with a citation, after the window: flag written" || bad "on failed: rc=$RC $OUT"
  case "$(cat "$SWC/.gc/gate-e5-second-reviewer.on" 2>/dev/null)" in *"Mayor, bead ga-syxaki #3, 2026-10-01T21:05-03"*) ok "the authorization citation is recorded inside the flag file" ;; *) bad "citation not recorded in the flag" ;; esac
  check "the dispatcher's own reader (gate_e5_enabled) sees it on the next sweep" 1 "$(env -i PATH="$PATH" GC_CITY="$SWC" "$BASH32" -c "source '$LIB'; gate_e5_enabled")"
  SW_ARGS=(status); OUT="$(sw)"; case "$OUT" in *"LIGADO"*"Mayor, bead ga-syxaki"*) ok "status shows ON and who authorized it" ;; *) bad "status after on: $OUT" ;; esac
  echo 3 > "$SWC/.gc/gate-e5-spend-$(date +%Y-%m-%d).count"; : > "$SWC/.gc/gate-e5-spend-$(date +%Y-%m-%d).count.alerted"
  SW_ARGS=(status); OUT="$(sw)"; case "$OUT" in *"extras pagos hoje: 3"*"US\$ 1.80"*"JÁ foi atingido"*) ok "status reports today's extras, the estimate, and that the cap was hit" ;; *) bad "status spend lines wrong: $OUT" ;; esac
  SW_ARGS=(off); sw >/dev/null 2>&1; RC=$?
  [ "$RC" = "0" ] && [ ! -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && check "off removes the flag; the reader sees 0" 0 "$(env -i PATH="$PATH" GC_CITY="$SWC" "$BASH32" -c "source '$LIB'; gate_e5_enabled")" || bad "off failed: rc=$RC"
  SW_ARGS=(on "urgent: Athos asked in bead ga-syxaki #9"); sw GATE_E5_NOT_BEFORE_EPOCH=99999999999 GATE_E5_FORCE_EARLY=1 >/dev/null 2>&1; RC=$?
  [ "$RC" = "0" ] && [ -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && ok "GATE_E5_FORCE_EARLY=1 is the explicit override for an early start" || bad "force-early failed: rc=$RC"
  SW_ARGS=(bogus); sw >/dev/null 2>&1; check "unknown subcommand: usage error (rc 2)" 2 "$?"
fi

# ── 10. wiring ──────────────────────────────────────────────────────────────────
echo "── 10. Every E5 call site in the dispatcher is behind the GATE_E5_LIB_OK guard ──"
UNGUARDED="$(awk '
  /GATE_E5_LIB_OK|GATE_E5_ACTIVE/ { last = NR }
  /^[[:space:]]*#/ { next }
  /gate_e5_[a-z_]+/ { if (NR - last > 10 && $0 !~ /^GATE_E5_LIB_OK/) print NR ": " $0 }
' "$DISPATCHER")"
[ -z "$UNGUARDED" ] && ok "no gate_e5_* call sits more than 10 lines below a GATE_E5_LIB_OK guard" || bad "unguarded E5 call(s):
$UNGUARDED"
check "GATE_E5_ACTIVE=1 is assigned only right under a LIB_OK test" 0 "$(awk '/^[[:space:]]*GATE_E5_ACTIVE=1/ { if (NR - last > 2) bad++ } /GATE_E5_LIB_OK/ { last = NR } END { print bad + 0 }' "$DISPATCHER")"
grep -q '\[ -r "\$_E5_LIB" \]' "$DISPATCHER" && ok "lib is sourced only when readable (fail-soft)" || bad "lib source is not guarded by [ -r ]"
check "flag defaults: GATE_E5_LIB_OK=0 before sourcing" 1 "$(grep -c '^GATE_E5_LIB_OK=0$' "$DISPATCHER")"

# ── mutation checks (is this suite vacuous?) ─────────────────────────────────────
echo "── Mutations: the suite must notice each of these ──"
if true; then
  cp "$LIB" "$TMP/lib.mut"; sed -i.bak "/^gate_e5_enabled()/,/^}/ s/printf '0'\$/printf '1'/" "$TMP/lib.mut"
  R="$(env -i PATH="$PATH" GC_CITY="$TMP/city" "$BASH32" -c "set -euo pipefail; source '$TMP/lib.mut'; gate_e5_enabled")"
  [ "$R" = "1" ] && ok "mutation 'flag defaults to on' is caught by the off-by-default assertion (got $R)" || bad "mutation 'flag defaults to on' survived (got $R)"
  cp "$LIB" "$TMP/lib.mut"; sed -i.bak 's/-ge "\$GATE_E5_SIZE_THRESHOLD_LINES"/-gt "$GATE_E5_SIZE_THRESHOLD_LINES"/' "$TMP/lib.mut"
  R="$(env -i PATH="$PATH" GC_CITY="$TMP/city" "$BASH32" -c "set -euo pipefail; source '$TMP/lib.mut'; gate_e5_size_state 800")"
  [ "$R" = "no" ] && ok "mutation '>= 800 becomes > 800' is caught by the boundary assertion (800 -> $R)" || bad "boundary mutation survived (800 -> $R)"
  cp "$LIB" "$TMP/lib.mut"; sed -i.bak 's/"e5-second-reviewer:\$bead"/"$bead"/' "$TMP/lib.mut"
  MISM=0
  for id in $(awk '{print $1}' "$TMP/arm-spec.txt" | head -30); do
    want="$(awk -v i="$id" '$1==i {print $2}' "$TMP/arm-spec.txt")"
    got="$(env -i PATH="$PATH" GC_CITY="$TMP/city" "$BASH32" -c "set -euo pipefail; source '$TMP/lib.mut'; gate_e5_arm_for_bead $id")"
    [ "$want" = "$got" ] || MISM=$((MISM+1))
  done
  [ "$MISM" -ge 5 ] && ok "mutation 'drop the salt' is caught by the spec comparison ($MISM of 30 ids differ)" || bad "unsalted mutation survived the spec comparison (only $MISM of 30 differ)"
  cp "$TASKLIB" "$TMP/tasklib.mut.sh"; sed -i.bak 's/\${GATE_E5_COV_RULES:-}/\n${GATE_E5_COV_RULES:-}/' "$TMP/tasklib.mut.sh"
  if cmp -s "$TASKLIB" "$TMP/tasklib.mut.sh"; then bad "task-lib mutation did not apply"; else
    M_OFF="$(render_task off bead "$TMP/tasklib.mut.sh")"
    [ "$M_OFF" != "$TASK_STRIPPED" ] && ok "mutation 'token leaves a stray line when empty' is caught by the byte-identity assertion" || bad "stray-newline mutation survived the byte-identity assertion"
  fi
fi

echo "== gate-e5-second-reviewer.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
