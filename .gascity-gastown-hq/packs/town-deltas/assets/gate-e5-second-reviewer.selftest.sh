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
#  11. TIME: the dispatcher runs the fingerprint and the extra-task builder under the gate lock on the WHOLE
#      reviewer task (up to 400KB); a >= 300KB task is handled in < 5s under bash 3.2 and the answer equals an
#      independent oracle's (no bash ${v#*pat} / ${v/pat/rep} on the task — they are quadratic).
#      The fingerprint splits at the template's OWN marker line (the LAST line that is exactly the marker; a diff
#      that quotes it must not move the split), and an awk/cksum that FAILS is 'unknown', never the checksum of
#      an empty stream (gate ga-4fbmfz).
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

# ── 4b. TIME is part of the contract: a real-size task must not stall the gate (gate ga-qprxlk) ──
# The dispatcher runs gate_e5_prompt_fingerprint (every admitted run, both arms) and gate_e5_extra_task (twice per
# spawn) UNDER THE GATE LOCK on the WHOLE reviewer task, which carries up to GATE_DIFF_BYTE_BUDGET (400KB) of diff.
# Under bash 3.2 ${v#*pat} and ${v/pat/rep} are quadratic in the length of $v (80KB: 4-10s; the real 333KB task of
# this bead: minutes), and every case above is a few-KB task — so the suite was green while a routine large-diff run
# would have stalled every other run behind it. The answer is also checked against an oracle that shares no code
# with the lib (python), so a fast-but-wrong rewrite does not pass either.
echo "── 4b. A real-size task (>= 300KB, the marker AFTER the diff) is handled in well under 5s — and the answer is still right ──"
E5_BIG_LIMIT=5
cat > "$TMP/e5_oracle.py" <<'PY'
import sys
# e5_oracle.py <fp|xt> <task-file> <vb1> <vb2-or-author> [lens] — the old documented behaviour, byte for byte.
mode, path, a, b = sys.argv[1:5]
s = open(path, "rb").read().rstrip(b"\n")          # what "$(cat file)" hands the lib
a, b = a.encode(), b.encode()
if mode == "fp":                                    # a = verdict-bead id, b = AUTHOR
    mk = b"--- YOUR TASK ---"                     # the template's own line: the LAST line that IS the marker
    lines = s.split(b"\n")                          # (a diff may quote it mid-line or after a +/- — those are not it)
    k = max((j for j, l in enumerate(lines) if l == mk), default=-1)
    rem = b"\n".join([b""] + lines[k + 1:]) if k >= 0 else s   # nothing standalone: the whole task
    if a: rem = rem.replace(a, b"<VB>")
    if b: rem = rem.replace(b, b"<AUTHOR>")
    sys.stdout.buffer.write(rem)
else:                                               # a = reviewer 1's id, b = reviewer 2's id
    lens = sys.argv[5].encode()
    s1, s2 = b"You are reviewer 1 of 1 for branch:", b"You are reviewer 2 of 2 for branch:"
    if s1 not in s or b"YOUR REVIEW LENS:" not in s or a not in s: sys.exit(3)
    lines = s.replace(s1, s2, 1).split(b"\n")
    for k, l in enumerate(lines):
        if l.startswith(b"YOUR REVIEW LENS:"):
            lines[k] = b"YOUR REVIEW LENS: " + lens
            break
    sys.stdout.buffer.write(b"\n".join(lines).replace(a, b))
PY
timed_lib() { # timed_lib <lib> <task-file> <out-file> <body>  -> "<rc|TIMEOUT> <secs>"; the child is KILLED at the bound
  local script="set -uo pipefail; source '$1'; t=\"\$(cat \"\$TASK_FILE\")\"; $4"
  python3 - "$E5_BIG_LIMIT" "$3" env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMP" GC_CITY="$TMP/city" TASK_FILE="$2" "$BASH32" -c "$script" <<'PY'
import os, signal, subprocess, sys, time
limit, outf, cmd = float(sys.argv[1]), sys.argv[2], sys.argv[3:]
t0 = time.time()
with open(outf, "wb") as o:
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=o, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        rc = str(p.wait(timeout=limit))
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.wait(); rc = "TIMEOUT"
print(rc, "%.2f" % (time.time() - t0))
PY
}
E5_FP_BODY='AUTHOR=crew/x gate_e5_prompt_fingerprint "$t" ga-vb0001'
E5_XT_BODY='gate_e5_extra_task "$t" ga-vb0001 ga-vb0002'
E5_LENS="$(run_lib -- <<<'gate_e5_extra_lens')"
fp_oracle() { python3 "$TMP/e5_oracle.py" fp "$1" ga-vb0001 crew/x | cksum | awk '{print $1}'; }
within_bound() { awk -v s="$1" -v l="$E5_BIG_LIMIT" 'BEGIN { exit !(s < l) }'; }

# the fingerprint had no direct case at all: small task, marker present / absent / twice, ids normalised
for kind in real two-markers no-marker; do
  case "$kind" in
    real)        cp "$TMP/task.on" "$TMP/fp.task" ;;
    two-markers) { cat "$TMP/task.on"; printf '\nga-vb0001 crew/x tail\n--- YOUR TASK ---\nsecond ga-vb0001\n'; } > "$TMP/fp.task" ;;
    no-marker)   grep -v -- '--- YOUR TASK ---' "$TMP/task.on" > "$TMP/fp.task" ;;
  esac
  GOT="$(timed_lib "$LIB" "$TMP/fp.task" "$TMP/fp.out" "$E5_FP_BODY")"
  check "fingerprint ($kind task) == the oracle's (rc, cksum)" "0 $(fp_oracle "$TMP/fp.task")" "${GOT%% *} $(tr -d '\n' < "$TMP/fp.out")"
done
sed 's/ga-vb0001/ga-vb7777/g' "$TMP/task.on" > "$TMP/fp.task7"
FP1="$(timed_lib "$LIB" "$TMP/task.on" "$TMP/fp.o1" 'gate_e5_prompt_fingerprint "$t" ga-vb0001' >/dev/null; cat "$TMP/fp.o1")"
FP7="$(timed_lib "$LIB" "$TMP/fp.task7" "$TMP/fp.o7" 'gate_e5_prompt_fingerprint "$t" ga-vb7777' >/dev/null; cat "$TMP/fp.o7")"
[ -n "$FP1" ] && [ "$FP1" = "$FP7" ] && ok "two runs of the same prompt with different verdict-bead ids share one fingerprint ($FP1)" || bad "the per-run id leaks into the fingerprint ($FP1 vs $FP7)"

# gate ga-4fbmfz, issue 1: the split is at the template's OWN marker line — the LAST line that is exactly the marker —
# not at the first place the text occurs. A diff can quote the marker (the diff of this very feature does, ten times:
# mid-line, after a "+", and as a removed "-- YOUR TASK ---" line that renders as the bare marker), and the diff sits BEFORE
# the template's marker, so the first occurrence is inside the DIFF: the logged fingerprint then identified the diff, and
# two runs with the identical prompt and different diffs got different fingerprints.
awk '{ print } $0 == "-line two" {
  print "+# the marker, quoted mid-line: --- YOUR TASK ---"
  print "+--- YOUR TASK ---"
  print "+  m = \"--- YOUR TASK ---\"   # ga-vb0001 crew/x"
  print "--- YOUR TASK ---" }' "$TMP/task.on" > "$TMP/fp.taskq"
[ "$(grep -c -- '--- YOUR TASK ---' "$TMP/fp.taskq")" -ge 5 ] && ok "the quoting task carries the marker $(grep -c -- '--- YOUR TASK ---' "$TMP/fp.taskq") times (3 quotes + a bare-marker line in the diff, then the template's own)" || bad "the quoting task was not built"
GOT="$(timed_lib "$LIB" "$TMP/fp.taskq" "$TMP/fp.outq" "$E5_FP_BODY")"
check "fingerprint (a diff that quotes the marker) == the oracle's (rc, cksum)" "0 $(fp_oracle "$TMP/fp.taskq")" "${GOT%% *} $(tr -d '\n' < "$TMP/fp.outq")"
check "the same instructions fingerprint the same whatever the diff quotes (quoting task == plain task)" "$(tr -d '\n' < "$TMP/fp.o1")" "$(tr -d '\n' < "$TMP/fp.outq")"
# a standalone marker with trailing text, or with a leading character, is NOT the template's line; with no standalone line
# at all the whole task is fingerprinted (the template drifted, and the value then says so by being a different number)
{ grep -v -- '--- YOUR TASK ---' "$TMP/task.on"; printf '%s\n' '+--- YOUR TASK ---' 'x --- YOUR TASK --- y' '--- YOUR TASK --- trailing'; } > "$TMP/fp.taskn"
GOT="$(timed_lib "$LIB" "$TMP/fp.taskn" "$TMP/fp.outn" "$E5_FP_BODY")"
check "fingerprint (only non-standalone markers) == the oracle's: the WHOLE task, not a split inside a line" "0 $(fp_oracle "$TMP/fp.taskn")" "${GOT%% *} $(tr -d '\n' < "$TMP/fp.outn")"

# gate ga-4fbmfz, issue 2: error and empty must not print the same number. A genuinely EMPTY instruction part checksums to
# 4294967295 (cksum of nothing); an awk that FAILS (fork failure / OOM-kill at load ~76 on a 350KB input) used to feed cksum an
# empty stream and print that very value, which the caller logs as a measurement. Now it is "unknown". The shim fails ONLY the
# fingerprint's program (rc 2) and passes every other awk through, like the reviewer's reproduction.
mkdir -p "$TMP/shim-awk" "$TMP/shim-cksum"
REAL_AWK="$(command -v awk)"; REAL_CKSUM="$(command -v cksum)"
printf '#!/bin/sh\ncase "$*" in *"YOUR TASK"*) exit 2 ;; esac\nexec %s "$@"\n' "$REAL_AWK" > "$TMP/shim-awk/awk"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$TMP/shim-cksum/cksum"
chmod +x "$TMP/shim-awk/awk" "$TMP/shim-cksum/cksum"
FP_TASK='head ga-vb0001 crew/x
--- YOUR TASK ---
the instructions ga-vb0001'
FP_CALL='printf "%s" "$(gate_e5_prompt_fingerprint "$FPT" ga-vb0001)"'
HEALTHY="$(run_lib AUTHOR=crew/x FPT="$FP_TASK" -- <<<"$FP_CALL")"
case "$HEALTHY" in ''|*[!0-9]*|4294967295) bad "healthy fingerprint is not a real checksum ('$HEALTHY')" ;; *) ok "healthy: the fingerprint is a real checksum ($HEALTHY)" ;; esac
check "a REALLY empty instruction part (the marker is the last line) is the checksum of nothing" "4294967295" "$(run_lib AUTHOR=crew/x FPT='head
--- YOUR TASK ---' -- <<<"$FP_CALL")"
check "an awk that FAILS is 'unknown' — not the checksum of an empty stream" "unknown" "$(run_lib PATH="$TMP/shim-awk:$PATH" AUTHOR=crew/x FPT="$FP_TASK" -- <<<"$FP_CALL")"
check "a cksum that FAILS is 'unknown' too" "unknown" "$(run_lib PATH="$TMP/shim-cksum:$PATH" AUTHOR=crew/x FPT="$FP_TASK" -- <<<"$FP_CALL")"
check "the failing fingerprint returns 0 (the dispatcher's admission path must go on) and prints nothing but the value" "unknown 0" "$(run_lib PATH="$TMP/shim-awk:$PATH" AUTHOR=crew/x FPT="$FP_TASK" -- <<<'v="$(gate_e5_prompt_fingerprint "$FPT" ga-vb0001)"; echo "$v $?"')"
# ... and the record: warn() in the dispatcher writes to STDOUT, so a warning raised inside the $(...) would BE the logged
# value. The record carries exactly "unknown", the loss is said in the dispatcher log once, and a healthy run says nothing.
ADMIT_BODY='warn() { echo "WARN: $*"; }
unset GATE_E5_SIZE_STATE; GATE_RUN_ID=ga-run-fp; BEAD_ID=ga-x; BRANCH=b
gate_e5_log_admit "$FPT" ga-vb0001 | sed "s/^/STDOUT> /"
jq -r "select(.event==\"e5_admit\" and .gate_run==\"ga-run-fp\") | \"LOGGED> \" + .review_prompt_cksum" "$QG_LOG" | tail -1'
OUT="$(run_lib PATH="$TMP/shim-awk:$PATH" GATE_E5_ENABLED=1 QG_LOG="$TMP/city/.gc/fp-admit1.jsonl" AUTHOR=crew/x FPT="$FP_TASK" -- <<<"$ADMIT_BODY")"
check "admit with a failing awk: the record says exactly 'unknown'" "LOGGED> unknown" "$(printf '%s\n' "$OUT" | grep '^LOGGED> ')"
[ "$(printf '%s\n' "$OUT" | grep -c '^STDOUT> .*WARN: .*unknown')" = "1" ] && ok "admit with a failing awk: the loss is warned ONCE, by the caller, outside the command substitution" || bad "admit with a failing awk: expected exactly one warning naming 'unknown', got: $(printf '%s' "$OUT" | tr '\n' '|')"
OUT="$(run_lib GATE_E5_ENABLED=1 QG_LOG="$TMP/city/.gc/fp-admit2.jsonl" AUTHOR=crew/x FPT="$FP_TASK" -- <<<"$ADMIT_BODY")"
check "admit with a healthy awk: a numeric record and NO warning" "LOGGED> $HEALTHY" "$(printf '%s\n' "$OUT" | grep '^LOGGED> ')"
check "admit with a healthy awk: nothing was warned" "0" "$(printf '%s\n' "$OUT" | grep -c '^STDOUT> ')"

# the real-size task: ~320KB of diff BETWEEN the template head and the "--- YOUR TASK ---" marker, like the live one
awk 'BEGIN { while (n < 320000) { l = sprintf("+filler diff line %06d the quick brown fox jumps over the lazy dog 0123456789", ++i); if (i % 10 == 0) l = l " ga-vb0001"; print l; n += length(l) + 1 } }' > "$TMP/filler.txt"
awk -v ff="$TMP/filler.txt" '{ print } $0 == "-line two" { while ((getline l < ff) > 0) print l }' "$TMP/task.on" > "$TMP/task.big"
BIG_BYTES="$(wc -c < "$TMP/task.big" | tr -d ' ')"
[ "$BIG_BYTES" -ge 300000 ] && ok "the big task is >= 300KB ($BIG_BYTES bytes)" || bad "the big task is only $BIG_BYTES bytes"
FILLER_LAST="$(grep -n '^+filler diff line' "$TMP/task.big" | tail -1 | cut -d: -f1)"; MARKER_AT="$(grep -n -- '^--- YOUR TASK ---$' "$TMP/task.big" | head -1 | cut -d: -f1)"
[ -n "$FILLER_LAST" ] && [ -n "$MARKER_AT" ] && [ "$MARKER_AT" -gt "$FILLER_LAST" ] && ok "in the big task the marker sits AFTER the diff (line $MARKER_AT > $FILLER_LAST) — the shape that made the shortest-prefix match walk the whole task" || bad "the big task does not have the marker after the diff"

GOT="$(timed_lib "$LIB" "$TMP/task.big" "$TMP/big.fp" "$E5_FP_BODY")"; FP_RC="${GOT%% *}"; FP_SECS="${GOT#* }"
if [ "$FP_RC" = "0" ] && within_bound "$FP_SECS"; then ok "fingerprint of the $BIG_BYTES-byte task: rc=0 in ${FP_SECS}s (bound ${E5_BIG_LIMIT}s)"; else bad "fingerprint of the $BIG_BYTES-byte task: rc=$FP_RC after ${FP_SECS}s (bound ${E5_BIG_LIMIT}s) — a quadratic pattern operation on the task is back"; fi
check "fingerprint of the big task == the oracle's" "$(fp_oracle "$TMP/task.big")" "$(tr -d '\n' < "$TMP/big.fp")"

GOT="$(timed_lib "$LIB" "$TMP/task.big" "$TMP/big.xt" "$E5_XT_BODY")"; XT_RC="${GOT%% *}"; XT_SECS="${GOT#* }"
if [ "$XT_RC" = "0" ] && within_bound "$XT_SECS"; then ok "extra task from the $BIG_BYTES-byte task: rc=0 in ${XT_SECS}s (bound ${E5_BIG_LIMIT}s)"; else bad "extra task from the $BIG_BYTES-byte task: rc=$XT_RC after ${XT_SECS}s (bound ${E5_BIG_LIMIT}s) — a quadratic pattern operation on the task is back"; fi
python3 "$TMP/e5_oracle.py" xt "$TMP/task.big" ga-vb0001 ga-vb0002 "$E5_LENS" > "$TMP/big.xt.want"; ORC=$?
[ "$ORC" -eq 0 ] && [ -s "$TMP/big.xt.want" ] && cmp -s "$TMP/big.xt" "$TMP/big.xt.want" && ok "the big extra task equals the oracle's, byte for byte (slot, lens, every id, the whole diff)" || bad "the big extra task differs from the oracle's (oracle rc=$ORC; got $(wc -c < "$TMP/big.xt" | tr -d ' ') bytes, want $(wc -c < "$TMP/big.xt.want" | tr -d ' '))"
check "no line of the big extra task still carries reviewer 1's id, and every one of the $(grep -c 'ga-vb0001' "$TMP/task.big") lines that had it now carries reviewer 2's" "0 $(grep -c 'ga-vb0001' "$TMP/task.big")" "$(grep -c 'ga-vb0001' "$TMP/big.xt") $(grep -c 'ga-vb0002' "$TMP/big.xt")"

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
# same file+line but a DIFFERENT defect (low overlap) -> kept. The file names are REAL length on
# purpose (gate attempt 1, ga-syxaki): with a 6-char "run.sh" the path contributes no tokens, so this
# fixture never exercised the thing it claims to test — path words inflating the overlap.
cat > "$TMP/d1.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: packs/town-deltas/assets/quality-gate-dispatcher.sh:40 swallows the curl failure and returns an empty default instead of an error
EOF
cat > "$TMP/d2.txt" <<'EOF'
VERDICT: FAIL
Blocking issue 1: packs/town-deltas/assets/quality-gate-dispatcher.sh:40 the comment above claims retries happen three times but the loop body executes once
EOF
mk_payload "1=$TMP/d1.txt" "2=$TMP/d2.txt" | union | jq -r '.stats | "\(.duplicates_merged),\(.distinct_issues)"' > "$TMP/o.txt"
check "same file:line but a different defect stays separate (0 merged, 2 distinct)" "0,2" "$(cat "$TMP/o.txt")"
u_pair() { # u_pair <issue text of reviewer 1> <issue text of reviewer 2> -> "<merged>,<distinct>"
  printf 'VERDICT: FAIL\n%s\n' "$1" > "$TMP/up1.txt"; printf 'VERDICT: FAIL\n%s\n' "$2" > "$TMP/up2.txt"
  mk_payload "1=$TMP/up1.txt" "2=$TMP/up2.txt" | union | jq -r '.stats | "\(.duplicates_merged),\(.distinct_issues)"'
}
# gate attempt 1, blocking issue 1 — the two repros the reviewer ran against the branch. Both cite the same REAL
# file a couple of lines apart; the defects differ. Only the path words (scripts, gate, switch...) and a few
# common words are shared, which used to reach the 0.50 overlap-over-the-smaller-side bar.
check "same real file, lines 40 vs 42, two DIFFERENT defects: not merged (path words are not a description)" "0,2" \
  "$(u_pair 'Blocking issue 1: scripts/gate-e5-switch.sh:40 - the quoting of $cite is missing' \
            'Blocking issue 1: scripts/gate-e5-switch.sh:42 - the refusal when the flag file is absent exits zero')"
LONG_OTHER='Blocking issue 1: packs/town-deltas/assets/quality-gate-dispatcher.sh:10141 the function gate_e5_union_reasons rewrites FAIL_REASONS with a backslash-n tail while the legacy concatenation ends with a real newline, so downstream watchdogs that parse the Reviewer N FAIL prefix see a doubled prefix on the last line'
check "a SHORT finding is not absorbed by a LONG one about another defect that merely names the same identifier" "0,2" \
  "$(u_pair 'Blocking issue 1: quality-gate-dispatcher.sh:10140 - gate_e5_union_reasons ignores its return code' "$LONG_OTHER")"
check "...and the short finding survives in the merged text the builder reads" 1 \
  "$(printf 'VERDICT: FAIL\n%s\n' 'Blocking issue 1: quality-gate-dispatcher.sh:10140 - gate_e5_union_reasons ignores its return code' > "$TMP/up1.txt"; printf 'VERDICT: FAIL\n%s\n' "$LONG_OTHER" > "$TMP/up2.txt"; mk_payload "1=$TMP/up1.txt" "2=$TMP/up2.txt" | union | jq -r .text | grep -c 'ignores its return code')"
# ...and the fix must not turn the dedupe off: a genuine duplicate in different words, real-length names, still merges.
check "the SAME defect in different words (paths of different length, lines 10503 vs 10500-10510) is still merged" "1,1" \
  "$(u_pair "Blocking issue 1: packs/town-deltas/assets/quality-gate-dispatcher.sh:10503 gate_e5_phase_c_hook reads VB_JSON as the run's verdict-bead list, but gate_collect_verdicts overwrites that global VB_JSON once per bead, so after the collect the hook sees only the last bead's JSON." \
            "Blocking issue 2: quality-gate-dispatcher.sh:10500-10510 VB_JSON is a global clobbered by gate_collect_verdicts for every bead; gate_e5_phase_c_hook then reads VB_JSON, which now holds just the last verdict bead, not the run's list.")"
# a citation alone never decides: same file + same line, NOTHING else in common
check "same file:line and no description in common: not merged" "0,2" \
  "$(u_pair 'Blocking issue 1: scripts/gate-e5-switch.sh:40 alpha bravo charlie delta' 'Blocking issue 1: scripts/gate-e5-switch.sh:40 echo foxtrot golf hotel')"
# the merged header no longer promises an absolute it cannot keep
check "the merged header makes no 'nothing else was dropped' absolute" 0 \
  "$(printf 'VERDICT: FAIL\nBlocking issue 1: a.py:1 x\n' > "$TMP/up1.txt"; cp "$TMP/up1.txt" "$TMP/up2.txt"; mk_payload "1=$TMP/up1.txt" "2=$TMP/up2.txt" | union | jq -r .text | grep -c 'Nothing else was dropped')"
# a verdict line that carries more than the keyword is kept, not swallowed whole (gate attempt 1, non-blocking)
printf 'VERDICT: FAIL — reviewed at SHA 9f3c2ab over the FULL diff\nBlocking issue 1: scripts/gate-e5-switch.sh:40 alpha bravo charlie delta\n' > "$TMP/up1.txt"
printf 'VERDICT: FAIL\nBlocking issue 1: other_file_name.py:7 echo foxtrot golf hotel\n' > "$TMP/up2.txt"
check "text after 'VERDICT: FAIL' on the verdict line is kept in the merged notes" 1 \
  "$(mk_payload "1=$TMP/up1.txt" "2=$TMP/up2.txt" | union | jq -r .text | grep -c 'reviewed at SHA 9f3c2ab over the FULL diff')"
# gate attempt 4 (ga-syxaki), blocking issue 1 — a MERGE must not lose what the OTHER wording carries. The reviewer's repro: reviewer 2
# says the same defect in shorter words and ALSO cites the sibling site; the dedupe kept the longer text, REPLACED the citations, and the
# sibling site (dispatcher.sh:15499) vanished while the output said "independently confirmed". The reverse also lost reviewer 1's
# unique clause whenever reviewer 2's wording happened to be longer. Every fixture here is a pair that STILL merges: the fix must not
# turn the dedupe off, only stop it from throwing content away.
U4_R1='Blocking issue 1: scripts/lib.sh:100-110 — gate_e5_spawn_extra treats an empty verdict bead id as success after bd create fails, so the caller waits until the extra window ends and the run is held.'
U4_R2='Blocking issue 1: scripts/lib.sh:102 — gate_e5_spawn_extra takes an empty verdict bead id for success after bd create fails. Same at scripts/lib.sh:102 and scripts/dispatcher.sh:15499.'
u4_text() { # u4_text <issue of reviewer 1> <issue of reviewer 2> -> merged text
  printf 'VERDICT: FAIL\n%s\n' "$1" > "$TMP/up1.txt"; printf 'VERDICT: FAIL\n%s\n' "$2" > "$TMP/up2.txt"
  mk_payload "1=$TMP/up1.txt" "2=$TMP/up2.txt" | union | jq -r .text
}
u4_appended() { printf 'VERDICT: FAIL\n%s\n' "$1" > "$TMP/up1.txt"; printf 'VERDICT: FAIL\n%s\n' "$2" > "$TMP/up2.txt"; mk_payload "1=$TMP/up1.txt" "2=$TMP/up2.txt" | union | jq -r .stats.sentences_appended; }
check "the reviewer's repro pair is still ONE merged issue (the fix keeps the dedupe on)" "1,1" "$(u_pair "$U4_R1" "$U4_R2")"
check "the SHORTER wording's extra citation (scripts/dispatcher.sh:15499) reaches the builder" 1 "$(u4_text "$U4_R1" "$U4_R2" | grep -c 'scripts/dispatcher.sh:15499')"
check "...under the loser's name, not passed off as the headline's own words" 1 "$(u4_text "$U4_R1" "$U4_R2" | grep -c '^  also from reviewer 2 ')"
check "...and the merged issue is still tagged as found by both" 1 "$(u4_text "$U4_R1" "$U4_R2" | grep -c 'found by reviewer 1 and reviewer 2 — independently confirmed')"
# the reverse: reviewer 2's wording is the LONGER one (the headline), reviewer 1 is the loser and carries a clause of its own
U4_R1_SHORT='Blocking issue 1: scripts/lib.sh:101 — gate_e5_spawn_extra treats an empty verdict bead id as success after bd create fails. The run record is written before the bead exists.'
check "reverse: the loser's own clause ('the run record is written before the bead exists') survives when the OTHER wording is longer" 1 \
  "$(u4_text "$U4_R1_SHORT" "$U4_R1 It then logs nothing about the abandoned attempt, so the apuração cannot count it." | grep -c 'run record is written before the bead exists')"
# only the CITATION test can keep this one: every significant word of the shorter wording is already in the kept text, one cited site is not
U4_CITE_ONLY='Blocking issue 1: scripts/lib.sh:104 — gate_e5_spawn_extra treats an empty verdict bead id as success after bd create fails (also scripts/dispatcher.sh:15499).'
check "a wording that adds NOTHING but a file:line the kept text lacks still contributes that citation" 1 "$(u4_text "$U4_R1" "$U4_CITE_ONLY" | grep -c 'scripts/dispatcher.sh:15499')"
# a loser whose every point is already in the kept text appends NOTHING (a duplicate is not copied twice)
U4_COVERED='Blocking issue 1: scripts/lib.sh:101 — gate_e5_spawn_extra treats an empty verdict bead id as success after bd create fails.'
check "a wording fully covered by the kept one appends nothing (0 sentences, no 'also from' line)" "0,0" \
  "$(u4_appended "$U4_R1" "$U4_COVERED"),$(u4_text "$U4_R1" "$U4_COVERED" | grep -c '^  also from reviewer')"
check "the stats say how much was appended (>0 for the repro pair)" true "$([ "$(u4_appended "$U4_R1" "$U4_R2")" -gt 0 ] 2>/dev/null && echo true || echo false)"
check "the header no longer says the other wording is simply dropped" 0 "$(u4_text "$U4_R1" "$U4_R2" | head -1 | grep -c 'the more detailed wording is shown)')"
# three reviewers: the LONGEST wording (reviewer 3) takes the headline over from the first; the clauses of 1 and 2 must both survive
printf 'VERDICT: FAIL\n%s\n' 'Blocking issue 1: scripts/lib.sh:101 — gate_e5_spawn_extra treats an empty verdict bead id as success after bd create fails. The run record is written before the bead exists.' > "$TMP/t1.txt"
printf 'VERDICT: FAIL\n%s\n' 'Blocking issue 1: scripts/lib.sh:103 — gate_e5_spawn_extra treats an empty verdict bead id as success after bd create fails. Same at scripts/dispatcher.sh:15499.' > "$TMP/t2.txt"
printf 'VERDICT: FAIL\n%s\n' "$U4_R1 The caller waits until the extra window ends, and the run is held until then." > "$TMP/t3.txt"   # longest, same defect in more of the same words (Jaccard ~0.44 against the merged item, well above the bar)
mk_payload "1=$TMP/t1.txt" "2=$TMP/t2.txt" "3=$TMP/t3.txt" | union | jq -r '.text, (.stats | "STATS \(.duplicates_merged),\(.distinct_issues)")' > "$TMP/t.out"
check "three reviewers, one defect: merged into ONE issue (2 duplicates, 1 distinct)" "STATS 2,1" "$(grep '^STATS' "$TMP/t.out")"
check "three reviewers: reviewer 1's clause survives although reviewer 3's wording took the headline" 1 "$(grep -c 'run record is written before the bead exists' "$TMP/t.out")"
check "three reviewers: reviewer 2's extra citation survives too" 1 "$(grep -c 'scripts/dispatcher.sh:15499' "$TMP/t.out")"
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
# gate attempt 3 (non-blocking): "no counter file" reads as "nothing spent today" ONLY when a count can be written. A directory that refuses the
# write would make every later call read "no file = 0" and the cap would never bite — the same value for "none spent" and "cannot count".
mkdir -p "$TMP/ro-city/.gc"; chmod 555 "$TMP/ro-city/.gc"
check "a counter directory that cannot be written -> unknown, not 'ok' (a spend that cannot be counted is a cap that cannot bite)" unknown "$(env -i PATH="$PATH" GC_CITY="$TMP/ro-city" "$BASH32" -c "set -euo pipefail; source '$LIB'; gate_e5_cap_state")"
chmod 755 "$TMP/ro-city/.gc"
check "...and the same directory, writable, with no counter yet -> ok" ok "$(env -i PATH="$PATH" GC_CITY="$TMP/ro-city" "$BASH32" -c "set -euo pipefail; source '$LIB'; gate_e5_cap_state")"
check "no city at all (no counter directory exists) -> unknown, not 'ok'" unknown "$(env -i PATH="$PATH" "$BASH32" -c "set -euo pipefail; source '$LIB'; gate_e5_cap_state")"

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
    *" list "*)     echo "bd $*" >> "$CALLS"; [ -f "$FIX/list-fail" ] && return 1; [ -f "$FIX/list.json" ] && cat "$FIX/list.json" || echo '[]'; return 0 ;;
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
# gate attempt 1, blocking issue 2: gate_collect_verdicts assigns the GLOBAL VB_JSON once per bead, so by the time the
# hook runs it holds ONE bead's answer — not the run's list. Every hook scenario below hands the hook the run's real
# list through GATE_E5_RUN_VB_JSON and leaves VB_JSON on this clobbered value, so a hook that reads VB_JSON again
# takes a different decision and its scenario fails.
CLOBBERED_VB_JSON='[{"id":"ga-vb0001","status":"closed","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:FAIL"]}]'
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
GATE_E5_RUN_ARM="B"   # the arm persisted in the gate-run record at admission (Step 5) and read back by Phase C — see section 12
GATE_E5_RUN_VB_JSON="[{\"id\":\"ga-vb0001\",\"status\":\"closed\",\"created_at\":\"2026-09-30T17:00:00Z\",\"labels\":[\"type:quality-gate-verdict\",\"reviewer-index:1\",\"verdict:FAIL\"]}]"; VB_JSON="$CLOBBERED_VB_JSON"
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
# gate attempt 3 (non-blocking): the session's identity is written INTO the create, so it exists exactly when the bead does — the later
# verified assign can fail and leave the bead with no assignee, and the pinned session would then have no record but a log line.
case "$C" in *'--metadata {"e5.session_id":"ga-wisp-new1","e5.session_name":"gate-reviewer-adhoc-new1"}'*) ok "the extra's session id and name are written into the bead's own metadata at create" ;; *) bad "create carries no session metadata: $(grep create "$F/calls.log" | cut -c1-300)" ;; esac
case "$C" in *"assign ga-newvb1 gate-reviewer-adhoc-new1"*) ok "durable pull: verdict bead assigned to the new session" ;; *) bad "verdict bead not assigned" ;; esac
case "$C" in *"comment ga-newvb1 QUALITY GATE REVIEW — You are reviewer 2 of 2"*) ok "the extra reviewer's task is embedded on its verdict bead" ;; *) bad "task not embedded: $(grep 'bd comment' "$F/calls.log" | cut -c1-150)" ;; esac
case "$C" in *"nudge ga-wisp-new1"*) ok "task queued to the new session" ;; *) bad "task not delivered" ;; esac
case "$C" in *"session pin ga-wisp-new1"*) ok "extra reviewer pinned (drain-exempt like reviewer 1)" ;; *) bad "extra reviewer not pinned" ;; esac
check "spend counted (1 extra review today)" 1 "$(cat "$TMP"/city/.gc/gate-e5-spend-*.count 2>/dev/null | head -1)"
check "event e5_extra_spawn records the window the extra was granted (run timeout 1800s, capped by the 4800s ceiling at t=300s)" 1800 "$(jq -r 'select(.event=="e5_extra_spawn") | .window_secs' "$TMP/city/.gc/quality-gate.jsonl")"
F="$(new_fix spawn-late)"; show_bead "$F" "$ARM_B_ID" '["story:in-flight"]'
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
PC_ELAPSED=1700
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "a first FAIL at t=1700s of a 1800s run still gets an extra (its window is its own, not the 100s left)" "REQ=2 N=2" "$OUT"
check "...and the event records the full 1800s window" 1800 "$(jq -r 'select(.event=="e5_extra_spawn") | .window_secs' "$TMP/city/.gc/quality-gate.jsonl")"
check "event e5_extra_spawn logged with the session key (for cost)" "ga-run001|first-fail|ga-newvb1|key-new1" "$(jq -r 'select(.event=="e5_extra_spawn") | [.gate_run,.trigger,.extra_vb,.session_key] | join("|")' "$TMP/city/.gc/quality-gate.jsonl")"
# The window belongs to the ONE spawn the hook granted it to. A big-diff extra has no window of its own (it is born with reviewer 1, on
# the run's clock); one spawned later in the same dispatcher process must log an EMPTY window_secs, not the first-fail run's 1800.
F="$(new_fix spawn-stale-window)"; show_bead "$F" "$ARM_B_ID" '["story:in-flight"]'
scn "$F" GATE_E5_ENABLED=1 -- <<EOF >/dev/null
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
gate_e5_spawn_extra ga-run002 ga-vb0001 "\$(gate_e5_read_task ga-vb0001)" big-diff
EOF
check "a big-diff spawn after a first-fail spawn in the same process does not inherit that run's window_secs" "1800|" "$(jq -r 'select(.event=="e5_extra_spawn") | .window_secs' "$TMP/city/.gc/quality-gate.jsonl" | paste -sd'|' -)"

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
# gate attempt 2, blocking issue 1: an extra is only worth paying for if it can finish. It gets its own window (the run timeout, counted
# from its birth) capped by the run ceiling (the guard aborts a run at 90 min) — below the minimum review window it is not started at all,
# with a NAMED reason, instead of being paid for and then retired undelivered by the shared run clock.
decline_case "too little run budget left for a review (ceiling 2000s, run at 1500s -> 500s window)" "too-little-time-left" "" "GATE_E5_ENABLED=1 GATE_E5_RUN_CEILING_SECS=2000" "PC_ELAPSED=1500"
decline_case "run ceiling unreadable (garbage): the window cannot be measured" "run-window-unreadable" "" "GATE_E5_ENABLED=1 GATE_E5_RUN_CEILING_SECS=abc" ""
decline_case "run timeout unreadable (PC_TIMEOUT_SECS not a number)" "run-window-unreadable" "" GATE_E5_ENABLED=1 "PC_TIMEOUT_SECS=soon"
decline_case "daily cap reached" "daily-cap-reached" "echo 50 > \"$TMP/city/.gc/gate-e5-spend-\$(date +%Y-%m-%d).count\"" GATE_E5_ENABLED=1 ""
decline_case "daily cap unreadable" "daily-cap-unreadable" "" "GATE_E5_ENABLED=1 GATE_E5_DAILY_CAP_USD=abc" ""
decline_case "reviewer 1's task not on its bead" "reviewer-1-task-unavailable" "echo '[]' > \"\$f/comments-ga-vb0001.json\"" GATE_E5_ENABLED=1 ""
decline_case "template drifted (anchor missing)" "task-anchor-missing" "jq -n '[{\"text\":\"QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch: x\\nno lens line here ga-vb0001\"}]' > \"\$f/comments-ga-vb0001.json\"" GATE_E5_ENABLED=1 ""
decline_case "Claude quota exhausted" "claude-quota-limited" "" GATE_E5_ENABLED=1 "gate_quota_limited() { printf 1; }"
decline_case "no free session slot" "spawn-failed" "touch \"\$f/spawn-fail\"" GATE_E5_ENABLED=1 ""
# gate attempt 1, blocking issue 3: the arm is decided ONCE, when the run is admitted, and carried in the run record. A run
# that was not admitted as arm B — admitted while the flag was off (the Mayor flips it mid-flight), an older run with no
# e5_arm line, or one whose arm could not be measured — must never get a first-fail extra just because the flag is on NOW
# and the bead's arm recomputes to B. (Silent: such a run is not in the experiment's denominator, so there is nothing to record.)
decline_case "run admitted with the flag off (no persisted arm)" "" "" GATE_E5_ENABLED=1 'GATE_E5_RUN_ARM=""'
decline_case "run admitted with an unmeasured arm (?)" "" "" GATE_E5_ENABLED=1 'GATE_E5_RUN_ARM="?"'
decline_case "run admitted as arm A although the bead recomputes to B" "" "" GATE_E5_ENABLED=1 'GATE_E5_RUN_ARM="A"'
decline_case "persisted arm is garbage" "" "" GATE_E5_ENABLED=1 'GATE_E5_RUN_ARM="b B"'
F="$(new_fix runarm-log)"; show_bead "$F" "$ARM_B_ID" '[]'
scn "$F" GATE_E5_ENABLED=1 -- >/dev/null <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
GATE_E5_RUN_ARM=""
gate_e5_phase_c_hook
EOF
case "$(cat "$F/stderr")" in *"not admitted as arm B"*) ok "a run admitted outside the experiment says so in the dispatcher log (no silent skip)" ;; *) bad "no log line for a run that was not admitted as arm B: $(cat "$F/stderr" | head -3)" ;; esac
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
check "verdict-bead create failed and the run's beads READ BACK empty: the clean 'no bead' reason" verdict-bead-create-failed "$(jq -r 'select(.event=="e5_extra_declined") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"
grep -q 'bd -C .* list .*-l gate-run:ga-run001 -l e5-extra' "$F/calls.log" && ok "a failed create is read back with the run's own verdict-bead query (gate-run label + e5-extra)" || bad "a failed create was taken at its word: no readback query in $(cat "$F/calls.log" | cut -c1-200)"
# gate attempt 3 (non-blocking), the third state of "the create failed": the write LANDED and only the answer was lost (a Dolt hiccup on
# the way back). Declaring "no bead" there leaves an unassigned e5-extra verdict:pending bead that Phase C counts as a live slot, so the run
# would wait out the extra's whole window for a reviewer that does not exist.
F="$(new_fix createfail-exists)"; show_bead "$F" "$ARM_B_ID" '[]'; touch "$F/create-fail"
echo '[{"id":"ga-orphan1","labels":["type:quality-gate-verdict","gate-run:ga-run001","e5-extra"]}]' > "$F/list.json"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]} LAST=\${VERDICT_BEAD_IDS[1]:-none} SID=\${SESSION_IDS[1]:-none}"
EOF
)"
check "create reported failure but the bead EXISTS: it is adopted (slot appended, REQUIRED 2), not declared 'no bead'" "REQ=2 N=2 LAST=ga-orphan1 SID=gate-reviewer-adhoc-new1" "$OUT"
grep -q 'session close ga-wisp-new1' "$F/calls.log" && bad "the session of an adopted bead was closed" || ok "the session behind an adopted bead is kept"
case "$(cat "$F/calls.log")" in *"assign ga-orphan1 gate-reviewer-adhoc-new1"*"comment ga-orphan1 QUALITY GATE REVIEW — You are reviewer 2 of 2"*) ok "the adopted bead gets the durable assign and the task, like a clean create" ;; *) bad "adopted bead not wired: $(cut -c1-160 "$F/calls.log")" ;; esac
check "...and the spawn event names the adopted bead" ga-orphan1 "$(jq -r 'select(.event=="e5_extra_spawn") | .extra_vb' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"
F="$(new_fix createfail-unreadable)"; show_bead "$F" "$ARM_B_ID" '[]'; touch "$F/create-fail" "$F/list-fail"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "create failed AND the readback failed: the run is untouched (arm-A behaviour)" "REQ=1 N=1" "$OUT"
check "...declined under its OWN reason — 'could not look' is not the clean 'no bead'" verdict-bead-create-unverified "$(jq -r 'select(.event=="e5_extra_declined") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"
grep -q 'gc --city .* session close ga-wisp-new1' "$F/calls.log" && ok "...and the session that has no bead behind it is closed" || bad "orphan session left behind an unverified create"
F="$(new_fix createfail-notarray)"; show_bead "$F" "$ARM_B_ID" '[]'; touch "$F/create-fail"; echo '{"error":"not a list"}' > "$F/list.json"
scn "$F" GATE_E5_ENABLED=1 -- >/dev/null <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
EOF
check "a readback that is not a JSON array is unreadable too (never 'no bead')" verdict-bead-create-unverified "$(jq -r 'select(.event=="e5_extra_declined") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"

echo "  · one attempt per run, and retiring an extra that cannot help:"
EXTRA_OPEN='[{"id":"ga-vb0001","status":"closed","created_at":"2026-09-30T17:00:00Z","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:FAIL"]},{"id":"ga-newvb1","status":"open","created_at":"__CREATED__","labels":["type:quality-gate-verdict","reviewer-index:2","verdict:pending","e5-extra","e5-trigger:first-fail"]}]'
iso_ago() { python3 -c 'import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# retire_case <label> <expected reason, "" = kept> <extra age in SECONDS, "" = created_at unreadable> <pc_elapsed> <closed-session 0|1>
#             [verdicts_received=1] [run timeout secs=1800] [expected PC_TIMEOUT_SECS after the hook = the run timeout unless given]
# The extra's age is a number, not a timestamp, on purpose: an extra is created AFTER its run started, so age <= pc_elapsed in every
# state production can produce. (Gate attempt 2: the old case "extra older than the run's timeout" put a 45-minute-old extra inside a
# 5-minute-old run — a state that cannot exist — so the branch it claimed to test was never shown to fire. A fixture that cannot
# happen is now a FAILED assertion here, not a green one.)
retire_case() {
  local label="$1" want="$2" age="$3" elapsed="$4" closed="$5" received="${6:-1}" tmo="${7:-1800}" want_pt="${8:-}"
  [ -n "$want_pt" ] || want_pt="$tmo"
  local f; f="$(new_fix "r-$label")"; show_bead "$f" "$ARM_B_ID" '[]'
  if [ -n "$age" ] && [ "$age" -gt "$elapsed" ]; then bad "$label: IMPOSSIBLE FIXTURE — the extra is ${age}s old inside a run that is only ${elapsed}s old (an extra is created after its run starts)"; return; fi
  jq -n '[{id:"ga-newvb1",status:"open",labels:["e5-extra"]}]' > "$f/show-ga-newvb1.json"
  [ "$closed" = "1" ] && touch "$f/closed-gate-reviewer-adhoc-new1"
  local created=""; [ -n "$age" ] && created="$(iso_ago "$age")"
  local vbj="${EXTRA_OPEN/__CREATED__/$created}"
  local out pt
  out="$(scn "$f" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
GATE_E5_RUN_VB_JSON='$vbj'; VB_JSON="\$CLOBBERED_VB_JSON"
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(rev-sess-1 gate-reviewer-adhoc-new1); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=$received; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=$elapsed; PC_TIMEOUT_SECS=$tmo; PC_TIMEOUT_MIN=\$(( $tmo / 60 ))
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]} IDS=\${VERDICT_BEAD_IDS[*]}"
echo "PT=\$PC_TIMEOUT_SECS PM=\$PC_TIMEOUT_MIN"
EOF
)"
  pt="$(printf '%s\n' "$out" | sed -n 2p)"; out="$(printf '%s\n' "$out" | sed -n 1p)"
  if [ -n "$want" ]; then
    check "$label: extra retired, slot dropped, REQUIRED back to 1" "REQ=1 N=1 IDS=ga-vb0001" "$out"
    check "$label: reason logged" "$want" "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"
    grep -q 'bd -C .* label add ga-newvb1 e5-extra-abandoned' "$f/calls.log" && ok "$label: verdict bead labelled e5-extra-abandoned (Phase C ignores it from now on)" || bad "$label: abandoned label not written"
    grep -q 'bd -C .* close ga-newvb1' "$f/calls.log" && ok "$label: verdict bead closed" || bad "$label: verdict bead not closed"
    grep -q 'session close gate-reviewer-adhoc-new1' "$f/calls.log" && ok "$label: extra session closed" || bad "$label: extra session not closed"
    grep -q '^collect$' "$f/calls.log" && ok "$label: verdicts re-collected without the extra" || bad "$label: no re-collect after dropping the slot"
    check "$label: a retired extra leaves the run deadline alone" "PT=$tmo" "${pt%% PM=*}"
  else
    check "$label: extra kept, run still waiting" "REQ=2 N=2 IDS=ga-vb0001 ga-newvb1" "$out"
    grep -q 'e5-extra-abandoned' "$f/calls.log" && bad "$label: abandoned although it can still deliver" || ok "$label: not abandoned"
    if [ "$want_pt" = "$tmo" ]; then
      check "$label: the run's deadline is untouched" "PT=$want_pt PM=$(( (want_pt + 59) / 60 ))" "$pt"
    else
      # Raised to the extra's own deadline = birth offset + window, where the offset is (elapsed - the extra's age) and the age is read off the
      # WALL CLOCK when the hook runs. The fixture's iso_ago truncates to the second and the hook runs later, so the deadline comes out at
      # (expected - the seconds that passed): 1s on an idle machine, more under load. Never above expected; a wrong rule is a minute or more off.
      ptv="${pt#PT=}"; ptv="${ptv%% *}"; pmv="${pt##*PM=}"
      if [ -n "$ptv" ] && [ "$ptv" -le "$want_pt" ] && [ "$ptv" -ge $((want_pt - 60)) ] && [ "$pmv" = "$(( (ptv + 59) / 60 ))" ]; then
        ok "$label: the run's deadline is the extra's own (PT=$ptv, expected $want_pt less clock drift; PM=$pmv)"
      else
        bad "$label: the run's deadline is not the extra's own — expected PT in [$((want_pt - 60)), $want_pt] with PM=ceil(PT/60), got '$pt'"
      fi
    fi
  fi
}
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# the ordinary states (run timeout 1800s)
retire_case "extra still young, run young, session alive" "" 0 300 0 1 1800 2100
retire_case "extra session confirmed closed" "extra-session-closed" 0 300 1
# gate attempt 2, blocking issue 1 — a FIRST-FAIL extra is born late (reviewer 1's FAIL arrives at, say, t=1000s) and must get its
# OWN window (the run timeout, counted from its creation), not whatever is left of the shared run clock. Every state below is one a
# real run produces: age <= elapsed, offset = elapsed - age is when reviewer 1 delivered.
retire_case "first-fail extra born at t=1000s, run past the shared 1800s clock, extra 1500s old: still inside its own window" "" 1500 2500 0 1 1800 2800
retire_case "first-fail extra born at t=1000s, at t=1800s (the shared clock's last second): kept, deadline is 1000+1800" "" 800 1800 0 1 1800 2800
retire_case "first-fail extra born at t=1000s, 1850s old (own window spent), run at 2850s" "extra-timeout" 1850 2850 0
# the shared clock still rules when reviewer 1 has NOT delivered (the big-diff extra is born with reviewer 1): only a run whose other
# reviewers all delivered may outlive its run timeout for the extra
retire_case "reviewer 1 still pending, run past its timeout: the run times out as it always did" "run-timeout" 1790 1810 0 0
retire_case "reviewer 1 still pending, run young" "" 100 120 0 0
# the run never outlives the guard's hard cap (GATE_RUN_TTL_MINUTES=90 -> E5 ceiling 4800s): a 3000s run timeout with reviewer 1's
# FAIL at t=2900s leaves the extra min(3000, 4800-2900)=1900s, not 3000s
retire_case "ceiling: extra born at t=2900s, run timeout 3000s, 1100s old: deadline is the 4800s ceiling, not 2900+3000" "" 1100 4000 0 1 3000 4800
retire_case "ceiling: the same extra 1950s old (ceiling window 1900s spent)" "extra-timeout" 1950 4850 0 1 3000
# an UNREADABLE age is "could not tell", not "too old" — a possibly live extra is not retired on it, and it cannot be granted a window
# it cannot be measured against (the run timeout and a confirmed-closed session still retire it, as they do when the age is known)
retire_case "extra age unreadable (no created_at), run young, session alive" "" "" 300 0
retire_case "extra age unreadable, but the run timed out" "run-timeout" "" 4000 0
# gate attempt 3 (non-blocking): the slot's session, as Phase C reads it, is the verdict bead's ASSIGNEE — EMPTY when the extra's verified
# assign failed at spawn (its session had already been pinned) and "__UNKNOWN__" when the read failed. Neither means "no session": the
# spawn also wrote the session into the bead's metadata, and the hook recovers it from there so the pinned session is closed, not leaked.
EXTRA_OPEN_META='[{"id":"ga-vb0001","status":"closed","created_at":"2026-09-30T17:00:00Z","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:FAIL"]},{"id":"ga-newvb1","status":"open","created_at":"__CREATED__","labels":["type:quality-gate-verdict","reviewer-index:2","verdict:pending","e5-extra","e5-trigger:first-fail"],"metadata":{"e5.session_id":"ga-wisp-new1","e5.session_name":"gate-reviewer-adhoc-new1"}}]'
# sess_case <label> <SESSION_IDS slot for the extra> <metadata yes|no> <extra age s> <pc_elapsed> <expect: "closed:<sid>" | "noclose" | "kept:<slot after the hook>">
sess_case() {
  local label="$1" slot="$2" meta="$3" age="$4" elapsed="$5" want="$6" f vbj out
  f="$(new_fix "s-$label")"; show_bead "$f" "$ARM_B_ID" '[]'
  jq -n '[{id:"ga-newvb1",status:"open",labels:["e5-extra"]}]' > "$f/show-ga-newvb1.json"
  vbj="${EXTRA_OPEN_META/__CREATED__/$(iso_ago "$age")}"
  [ "$meta" = "yes" ] || vbj="$(printf '%s' "$vbj" | jq -c 'map(del(.metadata))')"
  out="$(scn "$f" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
GATE_E5_RUN_VB_JSON='$vbj'; VB_JSON="\$CLOBBERED_VB_JSON"
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(rev-sess-1 "$slot"); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=$elapsed; PC_TIMEOUT_SECS=1800; PC_TIMEOUT_MIN=30
gate_e5_phase_c_hook
echo "N=\${#VERDICT_BEAD_IDS[@]} SLOT1=[\${SESSION_IDS[1]:-}]"
EOF
)"
  case "$want" in
    closed:*) grep -q "session close ${want#closed:}\$" "$f/calls.log" && ok "$label: the retired extra's session (${want#closed:}) was closed" || bad "$label: the pinned extra session was NOT closed: $(grep 'session close' "$f/calls.log" | tr '\n' ' ')" ;;
    noclose)  grep -q 'session close' "$f/calls.log" && bad "$label: a session close was attempted with no session known: $(grep 'session close' "$f/calls.log" | tr '\n' ' ')" || ok "$label: no session known, none closed (and no bogus close either)" ;;
    kept:*)   check "$label: extra kept; the slot's session after the hook" "N=2 SLOT1=[${want#kept:}]" "$out" ;;
  esac
}
sess_case "empty assignee, retired: closed from the metadata"  ""              yes 1850 2850 "closed:gate-reviewer-adhoc-new1"
sess_case "unreadable assignee, retired: closed from the metadata" "__UNKNOWN__" yes 1850 2850 "closed:gate-reviewer-adhoc-new1"
sess_case "empty assignee and NO metadata, retired: nothing to close" ""         no  1850 2850 "noclose"
sess_case "unreadable assignee and NO metadata, retired: no bogus close of the sentinel" "__UNKNOWN__" no 1850 2850 "noclose"
sess_case "empty assignee, kept: the slot is filled in from the metadata (classifier and EXIT cleanup see the real session)" "" yes 100 300 "kept:gate-reviewer-adhoc-new1"
sess_case "unreadable assignee, kept: the sentinel stays (a failed read is not a session)" "__UNKNOWN__" yes 100 300 "kept:__UNKNOWN__"
sess_case "real assignee, kept: untouched" "gate-reviewer-adhoc-other" yes 100 300 "kept:gate-reviewer-adhoc-other"
sess_case "real assignee, retired: its own session is the one closed, not the metadata's" "gate-reviewer-adhoc-other" yes 1850 2850 "closed:gate-reviewer-adhoc-other"
# extra already delivered (bead closed) -> nothing to do, not retired
F="$(new_fix delivered)"; jq -n '[{id:"ga-newvb1",status:"closed",labels:["e5-extra","verdict:FAIL"]}]' > "$F/show-ga-newvb1.json"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
GATE_E5_RUN_VB_JSON='${EXTRA_OPEN/__CREATED__/$NOW_ISO}'; VB_JSON="\$CLOBBERED_VB_JSON"
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
GATE_E5_RUN_VB_JSON='[{"id":"ga-vb0001","status":"closed","labels":["verdict:FAIL"]},{"id":"ga-oldvb","status":"closed","labels":["e5-extra","e5-extra-abandoned"]}]'; VB_JSON="\$CLOBBERED_VB_JSON"
VERDICT_BEAD_IDS=(ga-vb0001); SESSION_IDS=(a); REQUIRED_REVIEWERS=1
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=300; PC_TIMEOUT_SECS=1800
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "an abandoned extra blocks a second spawn for the same run" "REQ=1 N=1" "$OUT"
grep -q '^session-new$' "$F/calls.log" && bad "spawned a second extra for the same run" || ok "no second session"
# gate attempt 1, blocking issue 2 — the hook is handed the run's list, and an UNREADABLE list is not "no extra yet"
F="$(new_fix nolist)"; show_bead "$F" "$ARM_B_ID" '[]'
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
unset GATE_E5_RUN_VB_JSON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "no run list captured (never reached the query): the hook does NOT fall back to the clobbered VB_JSON, and spawns nothing" "REQ=1 N=1" "$OUT"
grep -q '^session-new$' "$F/calls.log" && bad "spawned an extra with no run list to check the one-attempt rule against" || ok "no session spawned without the run list"
check "...and says why (decline reason run-verdict-list-unavailable)" run-verdict-list-unavailable "$(jq -r 'select(.event=="e5_extra_declined") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"
F="$(new_fix notarray)"; show_bead "$F" "$ARM_B_ID" '[]'
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
GATE_E5_RUN_VB_JSON='{"error":"not a list"}'
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
check "a run list that is not a JSON array is unreadable too: nothing spawned" "REQ=1 N=1" "$OUT"

# The REAL Phase C chain: the extracted rehydrate block (list query -> rehydrate -> the REAL gate_collect_verdicts) followed by
# the extracted hook-call block. The hook tests above hand-set the state; this is what production actually produces at that
# point. (Gate attempt 1: the old tests stubbed gate_collect_verdicts and hand-set VB_JSON to the full list — a state the
# real flow never produces — so 185 green assertions hid a hook that spawned a SECOND extra for a run that had abandoned one.)
FLOW_REHY="$(extract_block "$DISPATCHER" phase-c-verdict-rehydrate)"
FLOW_HOOKCALL="$(extract_block "$DISPATCHER" e5-phase-c-hook-call)"
FLOW_EXTRACT_FN="$(extract_block "$DISPATCHER" run-desc-extract-fn)"; FLOW_RUNARM="$(extract_block "$DISPATCHER" e5-run-arm)"
FLOW_COLLECT="$(extract_block "$DISPATCHER" gate-collect-verdicts-fn)"; FLOW_PEEK="$(extract_block "$DISPATCHER" session-peek-reports-dead-fn)"; FLOW_IDENT="$(extract_block "$DISPATCHER" gate-verdict-identity-link-fn)"
[ -n "$FLOW_REHY" ] && [ -n "$FLOW_HOOKCALL" ] && [ -n "$FLOW_COLLECT" ] && [ -n "$FLOW_PEEK" ] && [ -n "$FLOW_IDENT" ] && ok "Phase C rehydrate block, hook-call block and the collect function extracted from the dispatcher" || bad "could not extract the Phase C blocks (rehydrate=${#FLOW_REHY} hookcall=${#FLOW_HOOKCALL} collect=${#FLOW_COLLECT})"
[ -n "$FLOW_EXTRACT_FN" ] && [ -n "$FLOW_RUNARM" ] && ok "the dispatcher's real extract() and the run-arm read-back block extracted" || bad "could not extract the run-arm read-back (extract-fn=${#FLOW_EXTRACT_FN} run-arm=${#FLOW_RUNARM}): Phase C does not read the arm persisted at admission"
flow_case() { # flow_case <fixdir> <env...> -- <tail script on stdin: sets BEAD_ID/PC_*, runs the blocks, prints>
  local fix="$1"; shift
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  {
    cat <<'EOF'
set -euo pipefail
FIX="$FIXDIR"; CALLS="$FIX/calls.log"; : > "$CALLS"
log()  { echo "LOG: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
_ts_to_epoch() { python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"; }
gc_json_or_unknown() { "$@"; }
reviewer_session_confirmed_closed() { [ -f "$FIX/closed-$1" ] && echo 1 || echo 0; }
assign_verdict_bead_verified() { echo "assign $1 $2" >> "$CALLS"; return 0; }
gate_nudge() { echo "nudge $1" >> "$CALLS"; return 0; }
bd() {
  case " $* " in
    *" list "*)     cat "$FIX/list.json"; return 0 ;;
    *" show "*)     local id; id=$(printf '%s\n' "$@" | awk '/^show$/ {getline; print; exit}'); [ -f "$FIX/show-$id.json" ] && { cat "$FIX/show-$id.json"; return 0; }; return 1 ;;
    *" comments "*) local id; id=$(printf '%s\n' "$@" | awk '/^comments$/ {getline; print; exit}'); [ -f "$FIX/comments-fail-$id" ] && return 1; [ -f "$FIX/comments-$id.json" ] && cat "$FIX/comments-$id.json" || echo "[]"; return 0 ;;
    *" create "*)   echo "create $*" >> "$CALLS"; echo '{"id":"ga-newvb1"}'; return 0 ;;
    *)              echo "bd $*" >> "$CALLS"; return 0 ;;
  esac
}
gc() {
  case " $* " in
    *" session new "*)  echo "session-new" >> "$CALLS"; echo '{"session_id":"ga-wisp-new1","session_name":"gate-reviewer-adhoc-new1","session_key":"key-new1"}'; return 0 ;;
    *" session list "*) echo '{"sessions":[]}'; return 0 ;;
    *" session peek "*) echo "scrollback"; return 0 ;;
    *)                  echo "gc $*" >> "$CALLS"; return 0 ;;
  esac
}
git_rig() { return 0; }
GC_CITY="$CITYDIR"; QG_LOG="$CITYDIR/.gc/quality-gate.jsonl"; BRANCH="crew/x/ga-demo"; GATE_RUN_ID="ga-run001"; BEAD_CITY="$CITYDIR"
EOF
    echo "$FLOW_PEEK"; echo "$FLOW_IDENT"; echo "$FLOW_COLLECT"
    echo 'source "$LIBFILE"; GATE_E5_LIB_OK=1'
    cat
  } > "$fix/flow.sh"
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMP" FIXDIR="$fix" CITYDIR="$TMP/city" LIBFILE="$LIB" ${envs[@]+"${envs[@]}"} "$BASH32" "$fix/flow.sh" 2>"$fix/stderr"
}
flow_fix() { # flow_fix <name> <list-json> -> fixture dir with the verdict beads' show/comments files
  local d; d="$(new_fix "flow-$1")"; printf '%s' "$2" > "$d/list.json"
  show_bead "$d" "$ARM_B_ID" '["story:in-flight"]'
  # like the real `bd show --json`: an ARRAY holding the one bead
  printf '%s' '[{"id":"ga-vb0001","status":"closed","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:FAIL"],"assignee":"rev-sess-1","created_at":"2026-09-30T17:00:00Z"}]' > "$d/show-ga-vb0001.json"
  jq -n --arg t "$TASK1_TEXT" '[{"text":$t},{"text":"VERDICT: FAIL\nBlocking issue 1: a real defect in scripts/gate-e5-switch.sh:40 — the quoting of $cite is missing"}]' > "$d/comments-ga-vb0001.json"
  echo "$d"
}
FLOW_TAIL='
BEAD_ID="$ARM_ID"; PC_ELAPSED="${FLOW_ELAPSED:-300}"; PC_TIMEOUT_SECS=1800; PC_TIMEOUT_MIN=30
REQUIRED_REVIEWERS=1   # the run record says 1; the rehydrate block adds the LIVE extras on top
DESC="$RUN_DESC"       # the gate-run bead description Phase C reads the run record from
'"$FLOW_EXTRACT_FN"'
'"$FLOW_RUNARM"'
for _dummy in 1; do
'"$FLOW_REHY"'
'"$FLOW_HOOKCALL"'
done
echo "REQ=$REQUIRED_REVIEWERS N=${#VERDICT_BEAD_IDS[@]} IDS=${VERDICT_BEAD_IDS[*]}"
'
FLOW_TAIL_PT="$FLOW_TAIL"'
echo "PT=$PC_TIMEOUT_SECS PM=$PC_TIMEOUT_MIN"
'
R1_FAIL='{"id":"ga-vb0001","status":"closed","created_at":"2026-09-30T17:00:00Z","labels":["type:quality-gate-verdict","gate-run:ga-run001","reviewer-index:1","verdict:FAIL"]}'
# (a) the reviewer's repro: reviewer 1 closed FAIL + an extra that was ABANDONED in an earlier sweep -> NO second extra
F="$(flow_fix abandoned "[$R1_FAIL,{\"id\":\"ga-oldvb\",\"status\":\"closed\",\"created_at\":\"2026-09-30T17:01:00Z\",\"labels\":[\"type:quality-gate-verdict\",\"gate-run:ga-run001\",\"reviewer-index:2\",\"e5-extra\",\"e5-extra-abandoned\"]}]")"
OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" RUN_DESC=$'required_reviewers: 1\ne5_arm: B' -- <<<"$FLOW_TAIL")"
check "REAL chain: an abandoned extra + reviewer 1's FAIL -> NO second extra for the same run" "REQ=1 N=1 IDS=ga-vb0001" "$OUT"
grep -q '^session-new$' "$F/calls.log" && bad "REAL chain: a SECOND extra was spawned for a run that had already abandoned one (the reviewer's repro)" || ok "REAL chain: no second session for the run"
# (b) first-fail trigger through the real chain: no extra yet -> exactly one is spawned
F="$(flow_fix firstfail "[$R1_FAIL]")"
OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" RUN_DESC=$'required_reviewers: 1\ne5_arm: B' -- <<<"$FLOW_TAIL")"
check "REAL chain: first judged FAIL of an arm-B bead -> one extra appended, REQUIRED 1->2" "REQ=2 N=2 IDS=ga-vb0001 ga-newvb1" "$OUT"
# (c) an extra in flight, through the real chain. Ages are real-run ages (extra age <= run elapsed): reviewer 1's FAIL arrives at
# offset = elapsed - age and the extra was born then. young: born 300s ago in a 300s run (a big-diff extra, born with the run).
# own-window-spent: reviewer 1 FAILed at t=400s; at t=3400s the extra is 3000s old, past its own 1800s window -> retired as extra-timeout.
EXTRA_LIVE='{"id":"ga-newvb1","status":"open","created_at":"__CREATED__","labels":["type:quality-gate-verdict","gate-run:ga-run001","reviewer-index:2","verdict:pending","e5-extra","e5-trigger:first-fail"]}'
for spec in "young:300:300:REQ=2 N=2 IDS=ga-vb0001 ga-newvb1" "own-window-spent:3000:3400:REQ=1 N=1 IDS=ga-vb0001"; do
  nm="${spec%%:*}"; rest="${spec#*:}"; age="${rest%%:*}"; rest="${rest#*:}"; elapsed="${rest%%:*}"; want="${rest#*:}"
  F="$(flow_fix "live-$nm" "[$R1_FAIL,${EXTRA_LIVE/__CREATED__/$(iso_ago "$age")}]")"
  printf '%s' '[{"id":"ga-newvb1","status":"open","labels":["type:quality-gate-verdict","gate-run:ga-run001","reviewer-index:2","verdict:pending","e5-extra"],"assignee":"gate-reviewer-adhoc-new1"}]' > "$F/show-ga-newvb1.json"
  OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" FLOW_ELAPSED="$elapsed" RUN_DESC=$'required_reviewers: 1\ne5_arm: B' -- <<<"$FLOW_TAIL")"
  check "REAL chain: an in-flight extra ($nm, ${age}s old in a ${elapsed}s run) is $([ "$nm" = young ] && echo kept || echo 'retired as extra-timeout')" "$want" "$OUT"
done
check "REAL chain: the old extra's retirement reason is extra-timeout" extra-timeout "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | tail -1)"
# (c2) gate attempt 2, blocking issue 1, through the REAL chain (real collect -> real hook): reviewer 1 FAILed at t=1000s, the extra
# was born then; at t=2500s the shared 1800s run clock has run out, but the extra (1500s old) is inside its own window — it is KEPT, and
# the deadline Phase C then compares against (PC_TIMEOUT_SECS) is the extra's: 1000+1800.
F="$(flow_fix "live-ownwindow" "[$R1_FAIL,${EXTRA_LIVE/__CREATED__/$(iso_ago 1500)}]")"
printf '%s' '[{"id":"ga-newvb1","status":"open","labels":["type:quality-gate-verdict","gate-run:ga-run001","reviewer-index:2","verdict:pending","e5-extra"],"assignee":"gate-reviewer-adhoc-new1"}]' > "$F/show-ga-newvb1.json"
OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" FLOW_ELAPSED=2500 RUN_DESC=$'required_reviewers: 1\ne5_arm: B' -- <<<"$FLOW_TAIL_PT")"
OUTL="$(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
PTV="$(printf '%s' "$OUTL" | sed -n 's/.* PT=\([0-9]*\) PM=.*/\1/p')"; PMV="$(printf '%s' "$OUTL" | sed -n 's/.* PM=\([0-9]*\)$/\1/p')"
check "REAL chain: a first-fail extra inside its own window survives the shared run clock — slot kept, REQUIRED stays 2" "REQ=2 N=2 IDS=ga-vb0001 ga-newvb1" "${OUTL%% PT=*}"
# The run's deadline is the extra's: its birth offset (elapsed 2500 - the extra's age) + its 1800s window = 2800. The age is measured against
# the WALL CLOCK when the hook runs, not when this fixture was built, and the real chain runs several python3 `_ts_to_epoch` calls in between —
# so on a loaded machine the deadline is 2800 minus the seconds that passed (measured: 2791 at load 45-60). It can never be ABOVE 2800, and a
# wrong rule lands far outside this minute: the run's own 1800s clock, or the old 2500+1800.
if [ -n "$PTV" ] && [ "$PTV" -le 2800 ] && [ "$PTV" -ge 2740 ] && [ "$PMV" = "$(( (PTV + 59) / 60 ))" ]; then ok "REAL chain: ...and the run's deadline moves to the extra's: PT=$PTV (2800 minus the load-time drift), PM=$PMV is its own ceiling in minutes"
else bad "REAL chain: the run's deadline did not move to the extra's own (1000+1800=2800, allowing 60s of drift): PT='$PTV' PM='$PMV'"; fi
grep -q 'e5-extra-abandoned' "$F/calls.log" && bad "REAL chain: the extra was retired although it is inside its own window" || ok "REAL chain: not retired"
# (d) the extra's own `bd show` failing inside the collect must not blind the hook to it: the hook decides from the run list
F="$(flow_fix "live-showfail" "[$R1_FAIL,${EXTRA_LIVE/__CREATED__/$(iso_ago 3000)}]")"   # no show-ga-newvb1.json -> every `bd show` of it fails (and the extra is past its window: still nothing retired on a guess)
OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" FLOW_ELAPSED=3400 RUN_DESC=$'required_reviewers: 1\ne5_arm: B' -- <<<"$FLOW_TAIL")"
check "REAL chain: the extra's bead unreadable this sweep -> nothing retired on a guess, nothing new spawned" "REQ=2 N=2 IDS=ga-vb0001 ga-newvb1" "$OUT"
grep -q '^session-new$' "$F/calls.log" && bad "REAL chain: spawned another extra while one exists but could not be read" || ok "REAL chain: no spawn while the existing extra is unreadable"
# (d2) gate attempt 2 (non-blocking, third state), through the REAL chain (real collect -> real hook). The same extra — bead closed, session
# closed (how a FINISHED extra looks), no verdict label — in two worlds: its comments read fine and hold no verdict ("delivered nothing":
# retired for good, as before), or the read of its comments FAILS ("unknown": it may hold a real FAIL; retiring is final, so it is kept and
# re-read next sweep). Error and empty must not produce the same outcome.
EXTRA_CLOSED='{"id":"ga-newvb1","status":"closed","created_at":"__CREATED__","labels":["type:quality-gate-verdict","gate-run:ga-run001","reviewer-index:2","e5-extra","e5-trigger:first-fail"]}'
for spec in "empty:REQ=1 N=1 IDS=ga-vb0001" "unreadable:REQ=2 N=2 IDS=ga-vb0001 ga-newvb1"; do
  nm="${spec%%:*}"; want="${spec#*:}"
  F="$(flow_fix "closed-$nm" "[$R1_FAIL,${EXTRA_CLOSED/__CREATED__/$(iso_ago 200)}]")"
  printf '%s' '[{"id":"ga-newvb1","status":"closed","labels":["type:quality-gate-verdict","gate-run:ga-run001","reviewer-index:2","e5-extra"],"assignee":"gate-reviewer-adhoc-new1"}]' > "$F/show-ga-newvb1.json"
  touch "$F/closed-gate-reviewer-adhoc-new1"
  [ "$nm" = unreadable ] && touch "$F/comments-fail-ga-newvb1"
  OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" FLOW_ELAPSED=300 RUN_DESC=$'required_reviewers: 1\ne5_arm: B' -- <<<"$FLOW_TAIL")"
  check "REAL chain: extra closed without a verdict, comments $nm -> $([ "$nm" = empty ] && echo 'retired (delivered nothing)' || echo 'kept (unknown, re-read next sweep)')" "$want" "$OUT"
  if [ "$nm" = unreadable ]; then
    grep -q 'e5-extra-abandoned' "$F/calls.log" && bad "REAL chain: an extra whose comments could not be read was abandoned (a real FAIL would be erased for good)" || ok "REAL chain: the unreadable extra was not abandoned"
    grep -q 'session close gate-reviewer-adhoc-new1' "$F/calls.log" && bad "REAL chain: the unreadable extra's session was closed" || ok "REAL chain: the unreadable extra's session left alone"
  else
    check "REAL chain: the empty extra's retirement reason" extra-closed-without-verdict "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | tail -1)"
  fi
done
# (e) gate attempt 1, blocking issue 3, through the real chain: the arm is what ADMISSION persisted in the run record (Step 5,
# one read of the flag), not what Phase C recomputes from the bead id under whatever the flag says now. A run admitted while
# the flag was off has no e5_arm line; one admitted as arm A says A — neither may get an extra because the flag is on NOW and
# the bead's own arm happens to be B.
for spec in "flag-off-at-admission:required_reviewers: 1" "admitted-as-A:required_reviewers: 1"$'\n'"e5_arm: A" "unmeasured:required_reviewers: 1"$'\n'"e5_arm: ?"; do
  nm="${spec%%:*}"; rd="${spec#*:}"
  F="$(flow_fix "notadm-$nm" "[$R1_FAIL]")"
  OUT="$(flow_case "$F" GATE_E5_ENABLED=1 ARM_ID="$ARM_B_ID" RUN_DESC="$rd" -- <<<"$FLOW_TAIL")"
  check "REAL chain: run $nm + the flag on now + a bead that recomputes to B -> NO first-fail extra" "REQ=1 N=1 IDS=ga-vb0001" "$OUT"
  grep -q '^session-new$' "$F/calls.log" && bad "REAL chain: run $nm: an extra was spawned for a run that was not admitted as arm B" || ok "REAL chain: run $nm: no session spawned"
done
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
mk_git() { # git_rig override returning N diff lines (BSD `seq 1 0` counts DOWN, so zero is spelled out)
  echo "git_rig() { echo \"git_rig \$*\" >> \"\$CALLS\"; if [ -f \"\$FIX/git-fail\" ]; then return 128; fi; if [ $1 -gt 0 ]; then seq 1 $1 | sed 's/^/+line /'; fi; }"
}
# gate attempt 3, blocking issue 2: the size is a stratification key for BOTH arms, so the admit decision measures the diff for every
# admitted run — arm A as much as arm B. The trigger (the treatment) stays arm B's alone. Every line below asserts the WHOLE record
# (arm, trigger, size_state, raw_lines): the old check looked only at the arm and the trigger, and arm A's "size_state=no, raw_lines=''"
# — an unmeasured diff logged as a measured small one — went through it.
for spec in "$ARM_B_ID:0:none" "$ARM_B_ID:799:none" "$ARM_B_ID:800:big-diff" "$ARM_B_ID:5000:big-diff" "$ARM_A_ID:0:none" "$ARM_A_ID:799:none" "$ARM_A_ID:800:none" "$ARM_A_ID:5000:none"; do
  IFS=: read -r bead n want <<<"$spec"
  OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
$(mk_git "$n")
BEAD_ID="$bead"; DEFAULT_BRANCH=main; REQUIRED_REVIEWERS=1
gate_e5_admit_decision
echo "\$GATE_E5_ARM \$GATE_E5_TRIGGER \$GATE_E5_SIZE_STATE \${GATE_E5_RAW_LINES:-}"
EOF
)"
  case "$bead" in "$ARM_A_ID") wantarm=A ;; *) wantarm=B ;; esac
  if [ "$n" -ge 800 ]; then wantsize=yes; else wantsize=no; fi
  check "admit: $bead ($wantarm) with $n diff lines -> arm, trigger, size_state, raw_lines" "$wantarm $want $wantsize $n" "$OUT"
done
# no arm at all (an empty bead id): still measured — the size belongs to the RUN, the arm only to the bead — and never a trigger
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
$(mk_git 900)
BEAD_ID=""; DEFAULT_BRANCH=main; REQUIRED_REVIEWERS=1
gate_e5_admit_decision
echo "\$GATE_E5_ARM \$GATE_E5_TRIGGER \$GATE_E5_SIZE_STATE \${GATE_E5_RAW_LINES:-}"
EOF
)"
check "admit: a run whose arm cannot be decided (?) is still measured, and never triggers" "? none yes 900" "$OUT"
touch "$F/git-fail"
for bead in "$ARM_B_ID" "$ARM_A_ID"; do
  OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
$(mk_git 900)
BEAD_ID="$bead"; DEFAULT_BRANCH=main; REQUIRED_REVIEWERS=1
gate_e5_admit_decision
echo "\$GATE_E5_ARM \$GATE_E5_TRIGGER \$GATE_E5_SIZE_STATE [\${GATE_E5_RAW_LINES:-}]"
EOF
)"
  case "$bead" in "$ARM_A_ID") wantarm=A ;; *) wantarm=B ;; esac
  check "admit: git diff failing is 'unknown' with NO line count (arm $wantarm) — never 'small' and never a trigger" "$wantarm none unknown []" "$OUT"
done
rm -f "$F/git-fail"
check "admit: a run nobody measured is 'unknown' by default, never 'no' (= measured small)" "unknown" "$(run_lib -- <<<'printf "%s" "$GATE_E5_SIZE_STATE"')"
OUT="$(run_lib GATE_E5_ENABLED=1 QG_LOG="$TMP/city/.gc/quality-gate.jsonl" -- <<<'unset GATE_E5_SIZE_STATE; GATE_RUN_ID=ga-run-u; BEAD_ID=ga-x; BRANCH=b; gate_e5_log_admit "task text" ga-vb0001; jq -r "select(.event==\"e5_admit\" and .gate_run==\"ga-run-u\") | .size_state" "$QG_LOG" | tail -1')"
check "an admit record written with no size decision logs size_state unknown (not 'no' and not empty)" "unknown" "$OUT"
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
printf 'VR=%s ANY=%s NOEVAL=%s JUDGED=%s UNDELIVERED=%s UNREAD=%s EXTRAV=%s\n' "$VERDICTS_RECEIVED" "$ANY_FAIL" "$GATE_FAIL_NO_EVAL" "$GATE_COLLECT_JUDGED_FAILS" "$GATE_E5_EXTRA_UNDELIVERED" "$GATE_E5_EXTRA_UNREADABLE" "$GATE_E5_EXTRA_VERDICT"
# What the run LOGS must be what it ACTED on (gate attempt 3, blocking issue 1): the e5_run_end line the finalize step writes, read back
# out of the log, goes to a side file so the one-line output above stays what every check below compares.
QG_LOG="$CITYDIR/collect2-qg.jsonl"; rm -f "$QG_LOG"
GATE_RUN_ID=ga-run-x; BEAD_ID=ga-b; OVERALL_VERDICT=$([ "$ANY_FAIL" = "1" ] && echo FAIL || echo PASS); REQUIRED_REVIEWERS=2
gate_e5_log_run_end
{ [ -s "$QG_LOG" ] && jq -r 'select(.event=="e5_run_end") | .extra_verdict' "$QG_LOG" | tail -1; } > "$CITYDIR/collect2.logged" || true
EOF
  } > "$f"
  env -i HOME="$HOME" PATH="$PATH" CITYDIR="$TMP/city" LIBFILE="$LIB" VB1="$1" VB2="$2" VB2C="$3" "$BASH32" "$f" 2>"$TMP/collect.err"
}
V1P='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:1","verdict:PASS"],"assignee":"s1"}'
V2_NOVERDICT='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2","e5-extra"],"assignee":"s2"}'
V2_PASS='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2","e5-extra","verdict:PASS"],"assignee":"s2"}'
V2_FAIL='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2","e5-extra","verdict:FAIL"],"assignee":"s2"}'
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[]')"
check "R1 PASS + extra closed with NO verdict: run stays a PASS (extra not delivered, not counted)" "VR=1 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=1 UNREAD=0 EXTRAV=NONE" "$OUT"
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" FAILREAD)"
# gate attempt 2 (non-blocking, third state): "could not read the comments" is NOT "delivered nothing". UNDELIVERED=1 makes the hook retire
# the extra for good, which on a failed read erases a real FAIL it may have written — so the unreadable extra is its own state.
check "R1 PASS + extra closed, its comments UNREADABLE: not a FAIL, not counted, and NOT 'undelivered' (unknown — the hook must not retire it on this)" "VR=1 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=0 UNREAD=1 EXTRAV=UNREADABLE" "$OUT"
# (the same extra read fine on the next sweep is the label-race case two checks below: its FAIL comment counts — nothing was erased)
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[{"text":"VERDICT: FAIL\nBlocking issue 1: real defect in a.sh:3"}]')"
# gate attempt 3, blocking issue 1: this case PASSED with EXTRAV=NONE — the test's own title said "the delivered FAIL counts", and the
# run did count it (ANY=1 JUDGED=1, its text goes to the builder) while the variable the log and the apuração read said it delivered nothing.
check "R1 PASS + extra closed with a FAIL *comment* but no label (label race): the delivered FAIL counts — and is recorded as FAIL, not NONE" "VR=2 ANY=1 NOEVAL=0 JUDGED=1 UNDELIVERED=0 UNREAD=0 EXTRAV=FAIL" "$OUT"
check "...and the e5_run_end line the finalize step WRITES says FAIL (what the run acted on is what it logged)" FAIL "$(cat "$TMP/city/collect2.logged")"
OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[{"text":"VERDICT: PASS\nSummary: fine"}]')"
check "R1 PASS + extra closed with a PASS *comment* but no label (label race): a delivered PASS, recorded as PASS" "VR=2 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=0 UNREAD=0 EXTRAV=PASS" "$OUT"
check "...and the e5_run_end line says PASS" PASS "$(cat "$TMP/city/collect2.logged")"
# the label/comment combinations, each against what the run acted on: the log must agree in EVERY one of them
logged_case() { # logged_case <label> <vb2 json> <vb2 comments> <expected EXTRAV and logged value>
  local o; o="$(collect_case2 "$V1P" "$2" "$3")"
  check "$1: the verdict the run acted on" "$4" "$(printf '%s' "$o" | sed 's/.*EXTRAV=//')"
  check "$1: the verdict the log records" "$4" "$(cat "$TMP/city/collect2.logged")"
}
logged_case "label FAIL, PASS comment (the label wins, as it does for the run)" "$V2_FAIL" '[{"text":"VERDICT: PASS\nSummary: fine"}]' FAIL
logged_case "label PASS, FAIL comment (the label wins)" "$V2_PASS" '[{"text":"VERDICT: FAIL\nBlocking issue 1: x"}]' PASS
logged_case "no label, no comment" "$V2_NOVERDICT" '[]' NONE
logged_case "no label, comments unreadable" "$V2_NOVERDICT" FAILREAD UNREADABLE
logged_case "no label, an unrelated comment only" "$V2_NOVERDICT" '[{"text":"working on it"}]' NONE
OUT="$(collect_case2 "$V1P" "$V2_FAIL" '[{"text":"VERDICT: FAIL\nBlocking issue 1: real defect in a.sh:3"}]')"
check "R1 PASS + extra delivered FAIL: the run FAILs (an extra can add a rejection)" "VR=2 ANY=1 NOEVAL=0 JUDGED=1 UNDELIVERED=0 UNREAD=0 EXTRAV=FAIL" "$OUT"
OUT="$(collect_case2 "$V1P" "$V2_PASS" '[]')"
check "R1 PASS + extra delivered PASS: PASS" "VR=2 ANY=0 NOEVAL=0 JUDGED=0 UNDELIVERED=0 UNREAD=0 EXTRAV=PASS" "$OUT"
# and the plain (non-extra) path keeps today's strictness: a reviewer closed with no verdict IS a no-eval FAIL
V2_PLAIN_NOVERDICT='{"status":"closed","labels":["type:quality-gate-verdict","reviewer-index:2"],"assignee":"s2"}'
OUT="$(collect_case2 "$V1P" "$V2_PLAIN_NOVERDICT" '[]')"
check "a NORMAL reviewer closed with no verdict is still a no-evaluation FAIL (pre-E5 strictness untouched)" "VR=2 ANY=1 NOEVAL=1 JUDGED=0 UNDELIVERED=0 UNREAD=0 EXTRAV=-" "$OUT"

# hook: a closed extra that delivered nothing is retired
F="$(new_fix closedundelivered)"; show_bead "$F" "$ARM_B_ID" '[]'
jq -n '[{id:"ga-newvb1",status:"closed",labels:["e5-extra"]}]' > "$F/show-ga-newvb1.json"
OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
GATE_E5_RUN_VB_JSON='${EXTRA_OPEN/__CREATED__/$NOW_ISO}'; VB_JSON="\$CLOBBERED_VB_JSON"
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(a b); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=300; PC_TIMEOUT_SECS=1800; GATE_E5_EXTRA_UNDELIVERED=1
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS IDS=\${VERDICT_BEAD_IDS[*]}"
EOF
)"
check "hook: a closed-without-verdict extra is retired; the run is decided on reviewer 1" "REQ=1 IDS=ga-vb0001" "$OUT"
check "hook: reason logged" extra-closed-without-verdict "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | head -1)"

# hook: a closed extra whose comments could not be READ is unknown, not "delivered nothing" (gate attempt 2, non-blocking, third state).
# Retiring is final (label, close, session close), so the extra is kept — even with its session confirmed closed, which is exactly how a
# FINISHED extra looks — and only its own clock retires it, under a reason that says it was never read.
unread_case() { # unread_case <label> <extra age s> <pc_elapsed> <expected reason, "" = kept>
  local label="$1" age="$2" elapsed="$3" want="$4" f out
  f="$(new_fix "unread-$label")"; show_bead "$f" "$ARM_B_ID" '[]'
  jq -n '[{id:"ga-newvb1",status:"closed",labels:["e5-extra"]}]' > "$f/show-ga-newvb1.json"
  touch "$f/closed-gate-reviewer-adhoc-new1"
  local vbj="${EXTRA_OPEN/__CREATED__/$(iso_ago "$age")}"
  out="$(scn "$f" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
GATE_E5_RUN_VB_JSON='$vbj'; VB_JSON="\$CLOBBERED_VB_JSON"
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(rev-sess-1 gate-reviewer-adhoc-new1); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=$elapsed; PC_TIMEOUT_SECS=1800; GATE_E5_EXTRA_UNREADABLE=1
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS IDS=\${VERDICT_BEAD_IDS[*]}"
EOF
)"
  if [ -n "$want" ]; then
    check "hook, unreadable extra, $label: retired by its clock" "REQ=1 IDS=ga-vb0001" "$out"
    check "hook, unreadable extra, $label: the reason says it was never read" "$want" "$(jq -r 'select(.event=="e5_extra_abandoned") | .reason' "$TMP/city/.gc/quality-gate.jsonl" | tail -1)"
  else
    check "hook, unreadable extra, $label: kept in its slot (the run keeps waiting; the next sweep re-reads it)" "REQ=2 IDS=ga-vb0001 ga-newvb1" "$out"
    grep -q 'e5-extra-abandoned' "$f/calls.log" && bad "hook, unreadable extra, $label: abandoned on a failed read" || ok "hook, unreadable extra, $label: not abandoned"
    grep -q 'session close gate-reviewer-adhoc-new1' "$f/calls.log" && bad "hook, unreadable extra, $label: its session was closed on a failed read" || ok "hook, unreadable extra, $label: its session left alone"
  fi
}
unread_case "young, session already closed (a finished extra)" 200 300 ""
unread_case "its own window spent (1850s old > 1800s)" 1850 2850 "extra-comments-unreadable"

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
  # gate attempt 1 (non-blocking): an UNREADABLE spend counter is "unknown", never "US$ 0.00 of the cap"
  echo "not-a-number" > "$SWC/.gc/gate-e5-spend-$(date +%Y-%m-%d).count"
  SW_ARGS=(status); OUT="$(sw)"
  case "$OUT" in *"US\$ 0.00"*) bad "status renders an unreadable counter as zero spend: $OUT" ;; *"ilegível"*"desconhecid"*) ok "status: an unreadable spend counter is reported as unknown, not as US\$ 0.00" ;; *) bad "status for an unreadable counter: $OUT" ;; esac
  # gate attempt 3 (same class, the switch): "cannot be read" is its own state — never "absent", never "zero spend", never "no bound".
  CNT="$SWC/.gc/gate-e5-spend-$(date +%Y-%m-%d).count"
  echo 4 > "$CNT"; chmod 000 "$CNT"
  SW_ARGS=(status); OUT="$(sw)"
  case "$OUT" in *"US\$ 0.00"*|*"extras pagos hoje: 0"*) bad "status renders a counter that EXISTS but cannot be read as zero spend: $OUT" ;; *"ilegível"*) ok "status: a counter that exists but cannot be read is 'ilegível', not US\$ 0.00" ;; *) bad "status for an unreadable (chmod 000) counter: $OUT" ;; esac
  chmod 600 "$CNT"; echo 3 > "$CNT"
  chmod 000 "$SWC/.gc/gate-e5-second-reviewer.on"
  SW_ARGS=(status); OUT="$(sw)"
  case "$OUT" in *"DESLIGADO (arquivo"*) bad "status calls a flag file that EXISTS but cannot be read 'ausente': $OUT" ;; *"ILEGÍVEL"*"DESLIGADO (inerte)"*|*"ILEGÍVEL"*"inerte"*) ok "status: a flag file that exists but cannot be read is 'ILEGÍVEL' (the dispatcher reads it as off), not 'ausente'" ;; *) bad "status for an unreadable flag file: $OUT" ;; esac
  chmod 600 "$SWC/.gc/gate-e5-second-reviewer.on"
  rm -f "$CNT"; chmod 555 "$SWC/.gc"
  SW_ARGS=(status); OUT="$(sw)"
  chmod 755 "$SWC/.gc"
  case "$OUT" in *"não gravável"*"nenhum extra nasce"*) ok "status: no counter yet and none can be written is 'não gravável' (the dispatcher's cap reads it as unknown too), not '0 extras'" ;; *) bad "status for an unwritable counter directory: $OUT" ;; esac
  echo 3 > "$CNT"; : > "$CNT.alerted"
  SW_ARGS=(off); sw >/dev/null 2>&1; RC=$?
  [ "$RC" = "0" ] && [ ! -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && check "off removes the flag; the reader sees 0" 0 "$(env -i PATH="$PATH" GC_CITY="$SWC" "$BASH32" -c "source '$LIB'; gate_e5_enabled")" || bad "off failed: rc=$RC"
  # a not-before bound that is not a number is not "no bound": the date guard would otherwise be skipped in silence
  SW_ARGS=(on "Mayor, bead ga-syxaki #3, 2026-10-01T21:05-03"); sw GATE_E5_NOT_BEFORE_EPOCH=abc >/dev/null 2>"$TMP/sw-bound.err"; RC=$?
  [ "$RC" = "2" ] && [ ! -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && grep -q "não é um número" "$TMP/sw-bound.err" && ok "on with an unreadable date bound: refused (rc 2, flag NOT written) — a bound that cannot be read is not 'no bound'" || bad "garbage GATE_E5_NOT_BEFORE_EPOCH let 'on' through or failed oddly: rc=$RC flag=$([ -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && echo written || echo absent) err=$(head -1 "$TMP/sw-bound.err")"
  SW_ARGS=(on "urgent: Athos asked in bead ga-syxaki #9"); sw GATE_E5_NOT_BEFORE_EPOCH=99999999999 GATE_E5_FORCE_EARLY=1 >/dev/null 2>&1; RC=$?
  [ "$RC" = "0" ] && [ -e "$SWC/.gc/gate-e5-second-reviewer.on" ] && ok "GATE_E5_FORCE_EARLY=1 is the explicit override for an early start" || bad "force-early failed: rc=$RC"
  SW_ARGS=(bogus); sw >/dev/null 2>&1; check "unknown subcommand: usage error (rc 2)" 2 "$?"
fi

# ── 12. gate attempt 1, blocking issue 3 ─────────────────────────────────────────
echo "── 12. The arm is decided ONCE (Step 5), carried in the run record, and an unmeasured arm is never A ──"
S5="$(extract_block "$DISPATCHER" e5-admit-step5)"; S6="$(extract_block "$DISPATCHER" e5-run-desc)"; S7="$(extract_block "$DISPATCHER" e5-step7-task-vars)"
if [ -n "$S5" ] && [ -n "$S6" ] && [ -n "$S7" ]; then ok "Step 5 admission, Step 6 run-record line and Step 7 task-vars blocks extracted from the dispatcher"
else bad "could not extract the admission blocks (step5=${#S5} step6=${#S6} step7=${#S7}): the flag is still read at two different times and the arm is not carried"; fi
build_step_sh() {
{
  cat <<'EOF'
set -euo pipefail
log() { :; }; warn() { :; }
git_rig() { seq 1 10 | sed 's/^/+l /'; }
DEFAULT_BRANCH=main; BRANCH=crew/x/ga-demo; REQUIRED_REVIEWERS=1; BEAD_ID="$BEAD"; GATE_RUN_ID=ga-run1
GATE_E5_LIB_OK=0; GATE_E5_COV_RULES=""; GATE_E5_COV_PASS_LINE=""; GATE_E5_EXTRA_SEEN=0; GATE_E5_EXTRA_VERDICT="-"; GATE_E5_ACTIVE=0
source "$LIBFILE"; GATE_E5_LIB_OK=1
GATE_E5_ENABLED="$F5"
EOF
  printf '%s\n' "$S5"
  echo 'GATE_E5_ENABLED="$F7"   # the Mayor flips the flag between Step 5 and the later steps'
  printf '%s\n' "$S6"; printf '%s\n' "$S7"
  cat <<'EOF'
echo "ACTIVE=$GATE_E5_ACTIVE ARM=$GATE_E5_ARM TRIGGER=$GATE_E5_TRIGGER COV=${#GATE_E5_COV_RULES} RUNDESC=[${GATE_E5_RUN_DESC_LINE//$'\n'/|}]"
echo "SIZE=$GATE_E5_SIZE_STATE RAW=${GATE_E5_RAW_LINES:-}"
EOF
} > "$TMP/step.sh"
}
build_step_sh
step_run() { # step_run <flag at Step 5> <flag at Step 7> <bead> — prints the run's record line; step_size then prints the size line of the LAST run
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMP" GC_CITY="$TMP/city" LIBFILE="$LIB" F5="$1" F7="$2" BEAD="$3" "$BASH32" "$TMP/step.sh" > "$TMP/step.out" 2>&1
  grep -v '^SIZE=' "$TMP/step.out"
}
step_size() { grep '^SIZE=' "$TMP/step.out" || echo "SIZE=<none: $(head -1 "$TMP/step.out")>"; }
if [ -n "$S5" ] && [ -n "$S6" ] && [ -n "$S7" ]; then
  OUT="$(step_run 0 0 "$ARM_B_ID")"
  check "flag off throughout: inert — not active, the arm is UNMEASURED (?), no prompt pieces, nothing added to the run record" "ACTIVE=0 ARM=? TRIGGER=none COV=0 RUNDESC=[]" "$OUT"
  check "flag off: the size was never measured, and the dispatcher's own default says so (unknown — not 'no', which means measured small)" "SIZE=unknown RAW=" "$(step_size)"
  OUT="$(step_run 0 1 "$ARM_B_ID")"
  check "THE RACE: flag off at Step 5, the Mayor turns it on before Step 7 -> the run stays OUT of the experiment (not active, arm ?, nothing logged as arm A)" "ACTIVE=0 ARM=? TRIGGER=none COV=0 RUNDESC=[]" "$OUT"
  OUT="$(step_run 1 1 "$ARM_B_ID")"
  case "$OUT" in "ACTIVE=1 ARM=B TRIGGER=none COV="[1-9]*"RUNDESC=[|e5_arm: B]") ok "flag on at Step 5, arm-B bead: active, arm B measured, prompt pieces set, the run record carries 'e5_arm: B'" ;; *) bad "flag on, arm B: $OUT" ;; esac
  check "flag on, arm B: the diff (10 lines from the mocked git) is measured at Step 5" "SIZE=no RAW=10" "$(step_size)"
  OUT="$(step_run 1 1 "$ARM_A_ID")"
  case "$OUT" in "ACTIVE=1 ARM=A TRIGGER=none COV="[1-9]*"RUNDESC=[|e5_arm: A]") ok "flag on at Step 5, arm-A bead: active, arm A MEASURED (the only way to read A), record carries 'e5_arm: A'" ;; *) bad "flag on, arm A: $OUT" ;; esac
  check "flag on, arm A: the diff is measured too — through the dispatcher's real Step 5 block, not 'no' with no line count" "SIZE=no RAW=10" "$(step_size)"
  OUT="$(step_run 1 0 "$ARM_B_ID")"
  case "$OUT" in "ACTIVE=1 ARM=B TRIGGER=none COV="[1-9]*"RUNDESC=[|e5_arm: B]") ok "the inverse race: flag on at Step 5, off before Step 7 -> the run was ADMITTED, so it stays active and gets the same prompt pieces it was logged with" ;; *) bad "inverse race: $OUT" ;; esac
fi
check "an arm nobody measured defaults to ? in the lib (No arm must never read as A)" "?" "$(run_lib -- <<<'printf "%s" "$GATE_E5_ARM"')"
OUT="$(run_lib GATE_E5_ENABLED=1 QG_LOG="$TMP/city/.gc/quality-gate.jsonl" -- <<<'unset GATE_E5_ARM; GATE_RUN_ID=ga-run1; BEAD_ID=ga-x; BRANCH=b; gate_e5_log_admit "task text" ga-vb0001; jq -r "select(.event==\"e5_admit\") | .arm" "$QG_LOG" | tail -1')"
check "an admit record written with no arm decision logs arm ? (not A)" "?" "$OUT"
check "gate_e5_task_vars with no argument still follows the flag (off -> empty pieces)" "[][]" "$(run_lib -- <<<'gate_e5_task_vars; printf "[%s][%s]" "$GATE_E5_COV_RULES" "$GATE_E5_COV_PASS_LINE"')"
OUT="$(run_lib -- <<<'gate_e5_task_vars admitted; printf "%s|%s" "$GATE_E5_COV_RULES" "$GATE_E5_COV_PASS_LINE"')"
case "$OUT" in *"COVERAGE REPORT (required)"*"|Coverage: <"*) ok "gate_e5_task_vars admitted: the pieces are set WITHOUT a second read of the flag (here the flag is off)" ;; *) bad "gate_e5_task_vars admitted did not set the pieces: $OUT" ;; esac
AFTER5="$(awk '/# SELFTEST-EXTRACT e5-admit-step5: END/ {f=1; next} f && !/^[[:space:]]*#/ && /gate_e5_enabled/ {print NR": "$0}' "$DISPATCHER")"
[ -z "$AFTER5" ] && ok "after the Step 5 admission the dispatcher never reads the flag again (Phase C's own read is earlier in the file and is about spending, not admission)" || bad "the flag is read again after Step 5:
$AFTER5"
N_DESC="$(awk '/^GATE_RUN_ID=\$\(bd -C "\$GC_CITY" create/ {f=1} f && /GATE_E5_RUN_DESC_LINE/ {n++} f && /--json/ {exit} END {print n+0}' "$DISPATCHER")"
check "the gate-run bead is created with the run-record line in its description" 1 "$N_DESC"

# ── 13. gate attempt 4, blocking issue 2: a flag that is ON while the E5 is not running must not be silent ──────
echo "── 13. Flag ON + lib NOT loaded, and an E5 event that could not be written, are SAID ──"
# The verdict's three silent paths to the same empty apuração: (a) quality-gate-dispatcher.sh sources the lib with 2>/dev/null and a failure just
# leaves GATE_E5_LIB_OK=0 — no line anywhere when the flag file exists; (b) gate_e5_log_event swallowed a failed append (|| true, no warn), so a lost
# e5_admit silently left a run out of the denominators. The apuração now reads the flag (its own suite); here the dispatcher and the lib speak.
s5_case() { # s5_case <step5-block> <flag path> <qg log> <lib_ok 0|1> -> output of the block run under bash 3.2 (WARN lines, ACTIVE=, DONE)
  cat > "$TMP/s5w.sh" <<EOF
set -euo pipefail
log() { :; }; warn() { echo "WARN: \$*"; }
gate_e5_enabled() { printf '0'; }
BEAD_ID=ga-demo; QG_LOG="$3"; GC_CITY="$TMP/city"; GATE_E5_FLAG_FILE="$2"
GATE_E5_LIB_OK=$4; GATE_E5_LIB_WHY="the lib file is missing or unreadable: /x/lib.sh"; GATE_E5_ACTIVE=0
$1
echo "ACTIVE=\$GATE_E5_ACTIVE"
echo DONE
EOF
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMP" "$BASH32" "$TMP/s5w.sh" 2>&1
}
printf 'ligado em 2026-10-02T09:00:00Z — teste\n' > "$TMP/s5w.flag.on"
printf 'ligado em 2026-10-02T09:00:00Z — teste\n' > "$TMP/s5w.flag.locked"; chmod 000 "$TMP/s5w.flag.locked"
if [ -n "$S5" ]; then
  : > "$TMP/s5w.q1.jsonl"
  OUT="$(s5_case "$S5" "$TMP/s5w.flag.on" "$TMP/s5w.q1.jsonl" 0)"
  case "$OUT" in *"WARN: E5: the flag file exists but the E5 lib is NOT loaded (the lib file is missing or unreadable: /x/lib.sh)"*"bead ga-demo"*"ACTIVE=0"*DONE*) ok "flag file readable + lib NOT loaded: the dispatcher WARNS, with the reason and the bead, and the run stays inert (ACTIVE=0)" ;; *) bad "flag on + lib not loaded was silent or wrong: $OUT" ;; esac
  check "...and leaves ONE e5_lib_not_loaded event with the reason, for the apuração" "e5_lib_not_loaded|ga-demo|the lib file is missing or unreadable: /x/lib.sh|1" \
    "$(jq -r '[.event, .bead, .why] | join("|")' "$TMP/s5w.q1.jsonl" | head -1)|$(grep -c . "$TMP/s5w.q1.jsonl")"
  : > "$TMP/s5w.q2.jsonl"
  OUT="$(s5_case "$S5" "$TMP/s5w.flag.absent" "$TMP/s5w.q2.jsonl" 0)"
  case "$OUT" in *WARN*) bad "lib not loaded but the flag is ABSENT: must be silent (nothing is supposed to run), got: $OUT" ;; *"ACTIVE=0"*DONE*) ok "lib not loaded + flag ABSENT: silent (the E5 is off, and says nothing)" ;; *) bad "flag-absent case did not finish: $OUT" ;; esac
  check "...and writes no event" 0 "$(grep -c . "$TMP/s5w.q2.jsonl")"
  OUT="$(s5_case "$S5" "$TMP/s5w.flag.locked" "$TMP/s5w.q2.jsonl" 0)"
  case "$OUT" in *WARN*) bad "an UNREADABLE flag file reads as off for the dispatcher: no 'lib not loaded' warning expected, got: $OUT" ;; *DONE*) ok "lib not loaded + flag file UNREADABLE: silent here (the lib's own reader reads it as off; the apuração reports the unreadable flag as its own state)" ;; *) bad "unreadable-flag case did not finish: $OUT" ;; esac
  OUT="$(s5_case "$S5" "$TMP/s5w.flag.on" "$TMP/s5w.q2.jsonl" 1)"
  case "$OUT" in *WARN*) bad "lib LOADED + flag readable must not trigger the lib-not-loaded warning: $OUT" ;; *DONE*) ok "lib LOADED: no 'lib not loaded' warning even with a readable flag" ;; *) bad "lib-loaded case did not finish: $OUT" ;; esac
  OUT="$(s5_case "$S5" "$TMP/s5w.flag.on" /nonexistent-dir-13/qg.jsonl 0)"
  case "$OUT" in *"WARN: E5: the flag file exists but the E5 lib is NOT loaded"*"ACTIVE=0"*DONE*) ok "an event log that cannot be written does not abort the dispatcher (set -e): the warning is still printed and the run proceeds" ;; *) bad "unwritable QG_LOG broke the Step 5 warning path: $OUT" ;; esac
  # mutation: take the warning branch out
  S5_MUT="$(printf '%s\n' "$S5" | sed 's/^elif \[ "\${GATE_E5_LIB_OK:-0}" != "1" \].*; then$/elif false; then/')"
  if [ "$S5_MUT" = "$S5" ]; then bad "Step 5 mutation did not apply (the elif anchor changed)"; else
    OUT="$(s5_case "$S5_MUT" "$TMP/s5w.flag.on" "$TMP/s5w.q2.jsonl" 0)"
    case "$OUT" in *WARN*) bad "mutant (no lib-not-loaded branch) still warned: $OUT" ;; *) ok "mutation 'no warning when the flag is on and the lib is not loaded' is caught by the case above (the mutant is silent)" ;; esac
  fi
fi
chmod 600 "$TMP/s5w.flag.locked"
# the sourcing site itself (top of the dispatcher): WHY the lib did not load, run as the dispatcher runs it
SRC13="$(sed -n '/^GATE_E5_LIB_OK=0$/,/^unset _E5_LIB$/p' "$DISPATCHER")"
mkdir -p "$TMP/c13-nolib" "$TMP/c13-ok/packs/town-deltas/assets" "$TMP/c13-ret/packs/town-deltas/assets" "$TMP/c13-locked/packs/town-deltas/assets" "$TMP/c13-fail/packs/town-deltas/assets"
cp "$LIB" "$TMP/c13-ok/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"
printf 'return 1\n' > "$TMP/c13-ret/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"
printf 'X=1\n' > "$TMP/c13-locked/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"; chmod 000 "$TMP/c13-locked/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"
printf 'false\n' > "$TMP/c13-fail/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"
src_case() { env -i HOME="$HOME" PATH="$PATH" GC_CITY="$1" "$BASH32" -c "set -euo pipefail; $SRC13; echo \"OK=\$GATE_E5_LIB_OK WHY=[\$GATE_E5_LIB_WHY]\"" 2>&1; }
if [ -n "$SRC13" ]; then
  check "lib file missing: LIB_OK=0 and the reason names the path" "OK=0 WHY=[the lib file is missing or unreadable: $TMP/c13-nolib/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh]" "$(src_case "$TMP/c13-nolib")"
  check "lib present and loads: LIB_OK=1 and no stale reason left behind" "OK=1 WHY=[]" "$(src_case "$TMP/c13-ok")"
  check "lib whose top level does an explicit 'return 1': survived, LIB_OK=0, and the reason says the source returned non-zero (not 'missing')" "OK=0 WHY=[sourcing $TMP/c13-ret/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh returned non-zero (e.g. a top-level return)]" "$(src_case "$TMP/c13-ret")"
  check "lib file present but UNREADABLE: LIB_OK=0 with the missing-or-unreadable reason" "OK=0 WHY=[the lib file is missing or unreadable: $TMP/c13-locked/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh]" "$(src_case "$TMP/c13-locked")"
  chmod 600 "$TMP/c13-locked/packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"
  # What the idiom does NOT survive, MEASURED on this host: a failing top-level command in the lib takes the shell down at the `source` under
  # bash 3.2 (launchd's), so the dispatcher's comment must not promise "fail-soft". This line records the outcome; it is informational because the
  # fact belongs to the host's bash, not to this code — if it ever reads "survived", the comment in the dispatcher is stale and can be loosened.
  R="$(src_case "$TMP/c13-fail")"
  case "$R" in "") ok "(info) a lib whose top-level command FAILS exits the shell at the source under $BASH32 — NOT fail-soft; the dispatcher's comment says so, and the protection is this suite (bash -n + the lib sourced under strict flags)" ;; OK=*) ok "(info) a failing top-level command did NOT kill the shell under $BASH32 here ($R) — the dispatcher's comment about it is now stale" ;; *) ok "(info) a failing top-level command under $BASH32: $R" ;; esac
else bad "could not extract the lib-sourcing block from the dispatcher"; fi

# gate_e5_log_event: every way of NOT writing the line says so
OUT="$(run_lib QG_LOG="$TMP/city/.gc" -- <<<'gate_e5_log_event e5_probe k v; echo "AFTER rc=$?"' 2>&1)"
case "$OUT" in *"E5: could not append the e5_probe event to $TMP/city/.gc"*"AFTER rc=0"*) ok "a failed append (target is a directory) WARNS on stderr when the lib runs without the dispatcher's warn(), and still returns 0" ;; *) bad "failed append was silent or failed the caller: $OUT" ;; esac
OUT="$(run_lib QG_LOG="$TMP/city/.gc" -- <<<'warn() { echo "WARN-FN: $*"; }; gate_e5_log_event e5_probe k v; echo "AFTER rc=$?"' 2>&1)"
case "$OUT" in "WARN-FN: E5: could not append the e5_probe event"*"AFTER rc=0") ok "...and goes through the dispatcher's warn() when there is one (so it lands in the dispatcher log)" ;; *) bad "append warning did not use warn(): $OUT" ;; esac
OUT="$(run_lib QG_LOG= -- <<<'gate_e5_log_event e5_probe k v; echo "AFTER rc=$?"' 2>&1)"
case "$OUT" in *"E5: no event log is configured (QG_LOG is empty) — the e5_probe event was NOT written"*"AFTER rc=0") ok "an EMPTY QG_LOG (was: return 0 in silence) warns too" ;; *) bad "empty QG_LOG was silent: $OUT" ;; esac
: > "$TMP/s13.jsonl"
OUT="$(run_lib QG_LOG="$TMP/s13.jsonl" -- <<<'gate_e5_log_event e5_probe k v; echo "AFTER rc=$?"' 2>&1)"
check "a SUCCESSFUL append prints nothing and writes the line" "AFTER rc=0|e5_probe" "$(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/ $//')|$(jq -r .event "$TMP/s13.jsonl")"
LIB_SAVE13="$LIB"; python3 - "$LIB" "$TMP/lib.mut13" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
old = '    _e5_warn "E5: could not append the $_ev event to $_file (disk full? permission? jq failed?) — the apuração will be missing this line."\n'
assert old in s, "mutation anchor missing"
open(sys.argv[2], "w").write(s.replace(old, "    :\n"))
PYMUT
LIB="$TMP/lib.mut13"
OUT="$(run_lib QG_LOG="$TMP/city/.gc" -- <<<'gate_e5_log_event e5_probe k v; echo "AFTER rc=$?"' 2>&1)"
LIB="$LIB_SAVE13"
[ "$OUT" = "AFTER rc=0" ] && ok "mutation 'a failed append is swallowed again' (the old '|| true') is caught: the mutant prints nothing where the real lib warns" || bad "swallowed-append mutant survived: $OUT"

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
grep -q '\[ -r "\$_E5_LIB" \]' "$DISPATCHER" && ok "lib is sourced only when readable (a missing or unreadable lib cannot kill the daemon; a parse error or failing top-level command still would — see section 13)" || bad "lib source is not guarded by [ -r ]"
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
  # union (gate attempt 1, blocking issue 1). The three defences overlap (description without the path, symmetric
  # measure, minimum shared words), so ONE mutant per defence proves little — any other defence still stops the
  # reviewer's repro. So: (1) revert ALL of them (= the old behaviour) and the repro must merge again; (2) remove
  # each defence alone and the pair that ONLY that defence stops must merge.
  mutate_union() { # mutate_union <out> <which: all|path|symmetric|minimum>
    python3 - "$UNION" "$1" "$2" <<'PYMUT_EOF'
import re, sys
src, out, which = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
def sub(old, new):
    global s
    assert old in s, "mutation anchor missing: %r" % old
    s = s.replace(old, new)
if which in ("all", "path"):
    sub("for t in TOKEN_RE.findall(description_of(body)):", "for t in TOKEN_RE.findall(body):")
if which in ("all", "symmetric"):
    sub("return shared, shared / float(len(ta | tb))", "return shared, shared / float(min(len(ta), len(tb)))")
if which in ("all", "minimum"):
    s = re.sub(r"^MIN_SHARED_TOKENS = \d+", "MIN_SHARED_TOKENS = 0", s, flags=re.M)
if which == "all":
    sub("STRONG_THRESHOLD = 0.35", "STRONG_THRESHOLD = 0.50")
open(out, "w").write(s)
PYMUT_EOF
  }
  merged_count() { # merged_count <union-script> <issue1> <issue2> -> duplicates_merged
    printf 'VERDICT: FAIL\n%s\n' "$2" > "$TMP/m1.txt"; printf 'VERDICT: FAIL\n%s\n' "$3" > "$TMP/m2.txt"
    mk_payload "1=$TMP/m1.txt" "2=$TMP/m2.txt" | python3 "$1" | jq -r '.stats.duplicates_merged'
  }
  P_REPRO1_A='Blocking issue 1: scripts/gate-e5-switch.sh:40 - the quoting of $cite is missing'
  P_REPRO1_B='Blocking issue 1: scripts/gate-e5-switch.sh:42 - the refusal when the flag file is absent exits zero'
  P_THIN_A='Blocking issue 1: other-file-name.sh:40 swallows failure'; P_THIN_B='Blocking issue 1: other-file-name.sh:41 swallows failure'
  P_TERSE_A='Blocking issue 1: scripts/gate-e5-switch.sh:40 cap_state returns unknown counter unreadable'
  P_TERSE_B='Blocking issue 1: scripts/gate-e5-switch.sh:42 the function cap_state reads the counter file, and when the counter holds garbage the caller treats unknown as ok in one branch while every other branch declines, which makes the daily spend guard inconsistent across sweeps and lets the spawn path run past the limit'
  mutate_union "$TMP/union.all.py" all && R="$(merged_count "$TMP/union.all.py" "$P_REPRO1_A" "$P_REPRO1_B")"
  [ "$R" = "1" ] && ok "mutation 'revert every defence' (path tokens + overlap over the smaller side + no minimum) is caught: the reviewer's repro merges again" || bad "full-revert mutant did not reproduce the old merge (merged=$R)"
  mutate_union "$TMP/union.min.py" minimum && R0="$(merged_count "$UNION" "$P_THIN_A" "$P_THIN_B")" && R="$(merged_count "$TMP/union.min.py" "$P_THIN_A" "$P_THIN_B")"
  [ "$R0" = "0" ] && [ "$R" = "1" ] && ok "mutation 'no minimum of shared words' is caught by the thin-evidence pair (real: $R0 merged, mutant: $R)" || bad "minimum-shared mutant survived (real=$R0 mutant=$R)"
  mutate_union "$TMP/union.sym.py" symmetric && R0="$(merged_count "$UNION" "$P_TERSE_A" "$P_TERSE_B")" && R="$(merged_count "$TMP/union.sym.py" "$P_TERSE_A" "$P_TERSE_B")"
  [ "$R0" = "0" ] && [ "$R" = "1" ] && ok "mutation 'overlap over the smaller side' is caught by the terse-in-long pair (real: $R0 merged, mutant: $R)" || bad "symmetric-measure mutant survived (real=$R0 mutant=$R)"
  mutate_union "$TMP/union.path.py" path && R="$(merged_count "$TMP/union.path.py" "$P_REPRO1_A" "$P_REPRO1_B")"
  ok "(info) restoring path tokens alone: repro merged=$R — the other two defences overlap with it by design"
  # gate attempt 4, blocking issue 1 — what a merge keeps. (1) revert to the old behaviour (the longer wording replaces the other,
  # nothing is appended) and the reviewer's repro must lose the sibling citation again; (2) drop ONLY the citation test and the pair
  # whose shorter wording adds nothing but a file:line must lose it.
  mutate_keep() { # mutate_keep <out> <which: drop|cites>
    python3 - "$UNION" "$1" "$2" <<'PYMUT_EOF'
import sys
src, out, which = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
def sub(old, new):
    global s
    assert old in s, "mutation anchor missing: %r" % old
    s = s.replace(old, new)
if which == "drop":
    sub("notes.append((rev, novel))", "pass")
if which == "cites":
    sub("if any(not cite_covered(c, kept_cites) for c in cites_of(sent)):", "if False:")
open(out, "w").write(s)
PYMUT_EOF
  }
  kept_count() { # kept_count <union-script> <issue1> <issue2> <needle> -> occurrences of the needle in the merged text
    printf 'VERDICT: FAIL\n%s\n' "$2" > "$TMP/m1.txt"; printf 'VERDICT: FAIL\n%s\n' "$3" > "$TMP/m2.txt"
    mk_payload "1=$TMP/m1.txt" "2=$TMP/m2.txt" | python3 "$1" | jq -r .text | grep -c "$4"
  }
  mutate_keep "$TMP/union.drop.py" drop && R0="$(kept_count "$UNION" "$U4_R1" "$U4_R2" 'scripts/dispatcher.sh:15499')" && R="$(kept_count "$TMP/union.drop.py" "$U4_R1" "$U4_R2" 'scripts/dispatcher.sh:15499')"
  [ "$R0" = "1" ] && [ "$R" = "0" ] && ok "mutation 'the other wording is dropped on a merge' (the old behaviour) is caught by the repro (real keeps the citation: $R0, mutant: $R)" || bad "drop-the-loser mutant survived (real=$R0 mutant=$R)"
  mutate_keep "$TMP/union.cites.py" cites && R0="$(kept_count "$UNION" "$U4_R1" "$U4_CITE_ONLY" 'scripts/dispatcher.sh:15499')" && R="$(kept_count "$TMP/union.cites.py" "$U4_R1" "$U4_CITE_ONLY" 'scripts/dispatcher.sh:15499')"
  [ "$R0" = "1" ] && [ "$R" = "0" ] && ok "mutation 'no citation test' is caught by the cite-only pair (real: $R0, mutant: $R)" || bad "citation-test mutant survived (real=$R0 mutant=$R)"
  # gate attempt 1, blocking issue 3 — the new defences must be noticed too.
  # (1) the hook obeys the arm PERSISTED at admission: drop that requirement and a run that was never admitted as arm B gets an extra.
  LIB_SAVE="$LIB"; cp "$LIB" "$TMP/lib.mut2"; sed -i.bak 's/\[ "\${GATE_E5_RUN_ARM:-}" != "B" \]/false/' "$TMP/lib.mut2"
  if cmp -s "$LIB" "$TMP/lib.mut2"; then bad "run-arm mutation did not apply (the hook no longer tests \"\${GATE_E5_RUN_ARM:-}\" != \"B\")"; else
    F="$(new_fix mutrunarm)"; show_bead "$F" "$ARM_B_ID" '[]'
    LIB="$TMP/lib.mut2"
    OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
GATE_E5_RUN_ARM=""
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
    LIB="$LIB_SAVE"
    [ "$OUT" = "REQ=2 N=2" ] && ok "mutation 'ignore the persisted arm' is caught: without the requirement a never-admitted run gets an extra (the decline cases above go red)" || bad "persisted-arm mutant survived (got '$OUT')"
  fi
  # (2) Step 7 must not read the flag again: put the OLD Step 7 block back and the race reproduces (an ACTIVE run whose arm was never measured).
  S7_SAVE="$S7"
  S7='GATE_E5_ACTIVE=0
if [ "${GATE_E5_LIB_OK:-0}" = "1" ] && [ "$(gate_e5_enabled)" = "1" ]; then
  GATE_E5_ACTIVE=1
  gate_e5_task_vars
fi'
  build_step_sh
  OUT="$(step_run 0 1 "$ARM_B_ID")"
  case "$OUT" in "ACTIVE=1 ARM=?"*) ok "mutation 'Step 7 reads the flag again' is caught: the race then yields an ACTIVE run with an unmeasured arm ($OUT)" ;; *) bad "old-Step-7 mutant did not reproduce the race (got '$OUT')" ;; esac
  S7="$S7_SAVE"; build_step_sh
  cp "$TASKLIB" "$TMP/tasklib.mut.sh"; sed -i.bak 's/\${GATE_E5_COV_RULES:-}/\n${GATE_E5_COV_RULES:-}/' "$TMP/tasklib.mut.sh"
  if cmp -s "$TASKLIB" "$TMP/tasklib.mut.sh"; then bad "task-lib mutation did not apply"; else
    M_OFF="$(render_task off bead "$TMP/tasklib.mut.sh")"
    [ "$M_OFF" != "$TASK_STRIPPED" ] && ok "mutation 'token leaves a stray line when empty' is caught by the byte-identity assertion" || bad "stray-newline mutation survived the byte-identity assertion"
  fi

  # gate attempt 3 — each of these re-introduces ONE of the defects the gate found (or one of its siblings), and the suite must go red.
  # (1) blocking issue 1: the comment-rescue branches stop recording the verdict they acted on.
  FN_COLLECT_SAVE="$FN_COLLECT"
  FN_COLLECT="$(printf '%s\n' "$FN_COLLECT_SAVE" | grep -v 'a rescued FAIL is a DELIVERED FAIL')"
  if [ "$FN_COLLECT" = "$FN_COLLECT_SAVE" ]; then bad "rescued-FAIL mutation did not apply (the anchor comment moved)"; else
    OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[{"text":"VERDICT: FAIL\nBlocking issue 1: real defect in a.sh:3"}]')"
    case "$OUT" in *"ANY=1"*"EXTRAV=FAIL") bad "mutation 'the rescued FAIL is not recorded' survived" ;; *"ANY=1"*) ok "mutation 'the rescued FAIL is not recorded' is caught: the run still FAILs on it (ANY=1) but logs EXTRAV=${OUT##*EXTRAV=}" ;; *) bad "rescued-FAIL mutant: unexpected output '$OUT'" ;; esac
  fi
  FN_COLLECT="$(printf '%s\n' "$FN_COLLECT_SAVE" | grep -v 'a rescued PASS is a DELIVERED PASS')"
  if [ "$FN_COLLECT" = "$FN_COLLECT_SAVE" ]; then bad "rescued-PASS mutation did not apply (the anchor comment moved)"; else
    OUT="$(collect_case2 "$V1P" "$V2_NOVERDICT" '[{"text":"VERDICT: PASS\nSummary: fine"}]')"
    case "$OUT" in *"EXTRAV=PASS") bad "mutation 'the rescued PASS is not recorded' survived" ;; *) ok "mutation 'the rescued PASS is not recorded' is caught (EXTRAV=${OUT##*EXTRAV=})" ;; esac
  fi
  FN_COLLECT="$FN_COLLECT_SAVE"
  # (2) blocking issue 2: the admit decision returns before measuring unless the bead is arm B / "not measured" is read as "no".
  admit_with() { # admit_with <lib> <bead> <diff lines> -> "ARM TRIGGER SIZE [RAW]"
    env -i PATH="$PATH" GC_CITY="$TMP/city" "$BASH32" -c "set -euo pipefail; warn() { :; }; git_rig() { if [ -f '$TMP/git-fail-m' ]; then return 128; fi; seq 1 $3 | sed 's/^/+l /'; }; BEAD_ID='$2'; DEFAULT_BRANCH=main; BRANCH=crew/x/ga-demo; REQUIRED_REVIEWERS=1; source '$1'; gate_e5_admit_decision; echo \"\$GATE_E5_ARM \$GATE_E5_TRIGGER \$GATE_E5_SIZE_STATE [\${GATE_E5_RAW_LINES:-}]\""
  }
  check "control: the real admit measures an arm-A run (5000 lines)" "A none yes [5000]" "$(admit_with "$LIB" "$ARM_A_ID" 5000)"
  awk '{ print } /^  GATE_E5_SIZE_STATE="unknown"; GATE_E5_RAW_LINES=""; GATE_E5_TRIGGER="none"$/ { print "  [ \"$GATE_E5_ARM\" = \"B\" ] || return 0" }' "$LIB" > "$TMP/lib.mut3"
  if cmp -s "$LIB" "$TMP/lib.mut3"; then bad "measure-only-arm-B mutation did not apply"; else
    R="$(admit_with "$TMP/lib.mut3" "$ARM_A_ID" 5000)"
    [ "$R" != "A none yes [5000]" ] && ok "mutation 'measure the diff only for arm B' is caught: arm A then logs '$R'" || bad "measure-only-arm-B mutant survived"
  fi
  cp "$LIB" "$TMP/lib.mut3"; sed -i.bak 's/GATE_E5_SIZE_STATE="unknown"/GATE_E5_SIZE_STATE="no"/' "$TMP/lib.mut3"
  touch "$TMP/git-fail-m"; R="$(admit_with "$TMP/lib.mut3" "$ARM_A_ID" 5000)"; R0="$(admit_with "$LIB" "$ARM_A_ID" 5000)"; rm -f "$TMP/git-fail-m"
  [ "$R0" = "A none unknown []" ] && [ "$R" != "$R0" ] && ok "mutation 'an unmeasured size defaults to no' is caught: a failed diff then logs '$R' instead of '$R0'" || bad "unmeasured-defaults-to-no mutant survived (real='$R0' mutant='$R')"
  # (3) the failed-create readback, the session recovery and the cap's writable-directory check.
  cp "$LIB" "$TMP/lib.mut4"; sed -i.bak 's/_found=\$(gate_e5_find_extra_bead "\$_run") || _frc=\$?/_found=""; _frc=0/' "$TMP/lib.mut4"
  if cmp -s "$LIB" "$TMP/lib.mut4"; then bad "no-readback mutation did not apply"; else
    F="$(new_fix mutreadback)"; show_bead "$F" "$ARM_B_ID" '[]'; touch "$F/create-fail"
    echo '[{"id":"ga-orphan1","labels":["e5-extra"]}]' > "$F/list.json"
    LIB="$TMP/lib.mut4"
    OUT="$(scn "$F" GATE_E5_ENABLED=1 -- <<EOF
BEAD_ID="$ARM_B_ID"
$HOOK_COMMON
gate_e5_phase_c_hook
echo "REQ=\$REQUIRED_REVIEWERS N=\${#VERDICT_BEAD_IDS[@]}"
EOF
)"
    LIB="$LIB_SAVE"
    [ "$OUT" = "REQ=1 N=1" ] && ok "mutation 'take a failed create at its word' is caught: the existing bead is declared absent and the run is left with an orphan slot" || bad "no-readback mutant survived (got '$OUT')"
  fi
  cp "$LIB" "$TMP/lib.mut5"; sed -i.bak 's/_close_sid="\$_meta_sid"/_close_sid=""/' "$TMP/lib.mut5"
  if cmp -s "$LIB" "$TMP/lib.mut5"; then bad "no-session-recovery mutation did not apply"; else
    F="$(new_fix mutsess)"; show_bead "$F" "$ARM_B_ID" '[]'; jq -n '[{id:"ga-newvb1",status:"open",labels:["e5-extra"]}]' > "$F/show-ga-newvb1.json"
    vbj="${EXTRA_OPEN_META/__CREATED__/$(iso_ago 1850)}"
    LIB="$TMP/lib.mut5"
    scn "$F" GATE_E5_ENABLED=1 -- >/dev/null <<EOF
BEAD_ID="$ARM_B_ID"
GATE_E5_RUN_VB_JSON='$vbj'; VB_JSON="\$CLOBBERED_VB_JSON"
VERDICT_BEAD_IDS=(ga-vb0001 ga-newvb1); SESSION_IDS=(rev-sess-1 ""); REQUIRED_REVIEWERS=2
VERDICTS_RECEIVED=1; ANY_FAIL=1; GATE_FAIL_NO_EVAL=0; GATE_COLLECT_JUDGED_FAILS=1
PC_ELAPSED=2850; PC_TIMEOUT_SECS=1800; PC_TIMEOUT_MIN=30
gate_e5_phase_c_hook
EOF
    LIB="$LIB_SAVE"
    grep -q 'session close gate-reviewer-adhoc-new1' "$F/calls.log" && bad "no-session-recovery mutant survived" || ok "mutation 'ignore the session recorded on the bead' is caught: the pinned extra session is left open"
  fi
  cp "$LIB" "$TMP/lib.mut6"; sed -i.bak '/^gate_e5_cap_state()/,/^}/ { /-w "\${_f%\/\*}"/d; }' "$TMP/lib.mut6"
  if cmp -s "$LIB" "$TMP/lib.mut6"; then bad "cap writable-check mutation did not apply"; else
    chmod 555 "$TMP/ro-city/.gc"
    R="$(env -i PATH="$PATH" GC_CITY="$TMP/ro-city" "$BASH32" -c "set -euo pipefail; source '$TMP/lib.mut6'; gate_e5_cap_state")"
    chmod 755 "$TMP/ro-city/.gc"
    [ "$R" = "ok" ] && ok "mutation 'no writable-directory check on the cap' is caught: an uncountable spend reads 'ok' ($R)" || bad "cap mutant survived (got '$R')"
  fi
  # the two functions exactly as they were at 700c090 (bash pattern operations on the whole task) appended over the real ones:
  # the 4b cases must catch EACH of them on the big task (a mutant here is KILLED at the bound, so this costs ~5s, not minutes)
  cp "$LIB" "$TMP/lib.mutq1"; cp "$LIB" "$TMP/lib.mutq2"
  cat >> "$TMP/lib.mutq1" <<'EOF'
gate_e5_prompt_fingerprint() {
  local _t="${1#*--- YOUR TASK ---}" _vb="${2:-}"
  [ -n "$_vb" ] && _t="${_t//$_vb/<VB>}"
  [ -n "${AUTHOR:-}" ] && _t="${_t//$AUTHOR/<AUTHOR>}"
  printf '%s' "$_t" | cksum 2>/dev/null | awk '{print $1}'
}
EOF
  cat >> "$TMP/lib.mutq2" <<'EOF'
gate_e5_extra_task() {
  local t1="${1:-}" vb1="${2:-}" vb2="${3:-}" lens t2
  [ -n "$t1" ] && [ -n "$vb1" ] && [ -n "$vb2" ] || return 1
  lens="$(gate_e5_extra_lens)"
  t2="${t1/You are reviewer 1 of 1 for branch:/You are reviewer 2 of 2 for branch:}"
  t2=$(printf '%s\n' "$t2" | awk -v lens="$lens" '
      !done && /^YOUR REVIEW LENS:/ { print "YOUR REVIEW LENS: " lens; done = 1; next }
      { print }') || return 1
  t2="${t2//$vb1/$vb2}"
  printf '%s' "$t2"
}
EOF
  ( timed_lib "$TMP/lib.mutq1" "$TMP/task.big" "$TMP/mutq1.out" "$E5_FP_BODY" > "$TMP/mutq1.res" ) &
  ( timed_lib "$TMP/lib.mutq2" "$TMP/task.big" "$TMP/mutq2.out" "$E5_XT_BODY" > "$TMP/mutq2.res" ) &
  wait
  for m in "mutq1:fingerprint:\${1#*--- YOUR TASK ---}" "mutq2:extra task:\${t1/pat/rep}"; do
    id="${m%%:*}"; rest="${m#*:}"; what="${rest%%:*}"; form="${rest#*:}"; GOT="$(cat "$TMP/$id.res")"
    if [ "${GOT%% *}" = "TIMEOUT" ] || ! within_bound "${GOT#* }"; then ok "mutation 'bash pattern operation on the whole task' ($form, $what) is caught: the $BIG_BYTES-byte task is not done in ${E5_BIG_LIMIT}s ($GOT)"; else bad "quadratic-form mutant ($what) survived: $GOT"; fi
  done
fi

echo "== gate-e5-second-reviewer.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
