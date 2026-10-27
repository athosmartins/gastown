#!/usr/bin/env bash
# gate-guard-skillmention-check.selftest.sh — ga-gqtg1fs: the guard's Step 5b-pre4 (agent-prompt skill-token check).
#
# The block between the `SELFTEST-EXTRACT skillmention-check` sentinels in quality-gate-guard.sh is extracted and
# EXECUTED here, not re-implemented, under the guard's own `set -euo pipefail`; only log/err/set_gate_status/bd are
# stubbed (they record what the block asked for). Two kinds of case:
#   - END TO END with the real gate-prompt-skill-check.sh and a real git repo with an origin (the rig is a SUBDIRECTORY
#     of the clone, as the gascity rig is in production): a skill token in a prompt is refused, a clean one passes;
#   - VERDICT MATRIX with a stub checker that prints what the case needs: what the guard does with each verdict, with
#     garbage, with silence, with a crash, with a missing checker, with the kill switch, with an unset input.
# The rule under test: ONLY `fail` refuses. Every other answer, including "could not measure", lets the submission
# through and is RECORDED (label + log line), so a path that skips the measurement is never silent.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GATE_GUARD_SUT:-$SELF_DIR/quality-gate-guard.sh}"
CHECKER="${GATE_PSC_SUT:-$SELF_DIR/gate-prompt-skill-check.sh}"
DET="${GATE_PSC_DETECTOR:-$SELF_DIR/pool-prompt-skill-mention.selftest.sh}"
HQ=".gascity-gastown-hq"
DET_REL="$HQ/packs/town-deltas/assets/pool-prompt-skill-mention.selftest.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }          # has <file> <fixed string>
hasnt() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

for f in "$GUARD" "$CHECKER" "$DET"; do [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }; done
POOL="$(sed -n 's/^POOL_TEMPLATES="${POOL_PROMPT_POOL_TEMPLATES:-\(.*\)}"$/\1/p' "$DET" 2>/dev/null | head -n 1)"
[ -n "$POOL" ] || { echo "FATAL: cannot read the POOL_TEMPLATES default from $DET"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/guard-psc-selftest.XXXXXX")" || { echo "FATAL: no scratch dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

echo "A. the block is extractable and parses"
B=$(grep -c '^# SELFTEST-EXTRACT skillmention-check: BEGIN$' "$GUARD"); E=$(grep -c '^# SELFTEST-EXTRACT skillmention-check: END$' "$GUARD")
[ "$B/$E" = "1/1" ] && ok "sentinels present exactly once each" || { bad "sentinels: BEGIN=$B END=$E (want 1/1)"; echo "FATAL: nothing below can run"; echo; echo "gate-guard-skillmention-check selftest: $PASS passed, $FAIL failed"; exit 1; }
BLOCK="$WORK/block.sh"
sed -n '/^# SELFTEST-EXTRACT skillmention-check: BEGIN$/,/^# SELFTEST-EXTRACT skillmention-check: END$/p' "$GUARD" | sed '1d;$d' > "$BLOCK"
if [ -s "$BLOCK" ] && bash -n "$BLOCK" 2>/dev/null; then ok "block extracted ($(wc -l < "$BLOCK" | tr -d ' ') lines) and parses"
else echo "FATAL: block empty or does not parse"; exit 1; fi

# The driver runs under the guard's own flags: a failing substitution that is not guarded would abort it here.
DRIVER="$WORK/driver.sh"
cat > "$DRIVER" <<'DRV'
set -euo pipefail
log() { printf 'LOG %s\n' "$*" >> "$CALLS"; }
err() { printf 'ERR %s\n' "$*" >> "$CALLS"; }
set_gate_status() { printf 'STATUS %s %s\n' "$1" "$2" >> "$CALLS"; }
bd() { printf 'BD %s\n' "$*" >> "$CALLS"; }
. "$BLOCK"
echo "BLOCK-FELL-THROUGH" >> "$CALLS"
DRV

# drive <calls-file> [VAR=value ...]: runs the block with the case's variables; RC = the driver's exit status.
drive() {
  local calls="$1"; shift
  : > "$calls"
  env CALLS="$calls" BLOCK="$BLOCK" GC_CITY="$GCCITY" MARKER_ID="ga-marker-1" BEAD_ID="ga-bead-1" "$@" bash "$DRIVER" > "$calls.stdout" 2>&1
  RC=$?
}
fell()    { has "$1" "BLOCK-FELL-THROUGH"; }
labeled() { has "$1" "label add ga-marker-1 gate-skillmention:$2"; }

GCCITY="$WORK/city"; mkdir -p "$GCCITY/.gc"

# ---------------------------------------------------------------- end to end
echo "B. end to end: real checker, real git, rig = a subdirectory of the clone"
ORIGIN="$WORK/origin.git"; BUILD="$WORK/build"; RIGCLONE="$WORK/rigclone"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
mkdir -p "$BUILD" && git -C "$BUILD" init -q && git -C "$BUILD" symbolic-ref HEAD refs/heads/main
git -C "$BUILD" config user.email t@example.invalid; git -C "$BUILD" config user.name t; git -C "$BUILD" config commit.gpgsign false
for a in $POOL gate-reviewer; do
  mkdir -p "$BUILD/$HQ/agents/$a"; printf '# %s\nsubmit with the gate-done skill.\n' "$a" > "$BUILD/$HQ/agents/$a/prompt.template.md"
done
mkdir -p "$BUILD/$HQ/skills/recall" "$BUILD/$HQ/packs/town-deltas/template-fragments" "$BUILD/$HQ/packs/town-deltas/assets" "$BUILD/other"
printf '# recall\n' > "$BUILD/$HQ/skills/recall/SKILL.md"
printf '[workspace]\nglobal_fragments = ["town-deltas"]\n' > "$BUILD/$HQ/city.toml"
printf 'plain fragment.\n' > "$BUILD/$HQ/packs/town-deltas/template-fragments/town-deltas.template.md"
printf 'x = 1\n' > "$BUILD/other/app.py"
cp "$DET" "$BUILD/$DET_REL"
git -C "$BUILD" add -A && git -C "$BUILD" commit -q -m base && git -C "$BUILD" remote add origin "$ORIGIN" && git -C "$BUILD" push -q origin main
git clone -q "$ORIGIN" "$RIGCLONE" 2>/dev/null
RIG="$RIGCLONE/$HQ"

push_branch() { # push_branch <name> <file> <text to append>   (branches from main)
  git -C "$BUILD" checkout -q -b "$1" main && printf '%s\n' "$3" >> "$BUILD/$2" && git -C "$BUILD" commit -q -am "$1" && git -C "$BUILD" push -q origin "$1" && git -C "$BUILD" checkout -q main
}

push_branch tok "$HQ/agents/gate-reviewer/prompt.template.md" 'then run /gate-done to submit.'
C1="$WORK/c1"; drive "$C1" RIG_PATH="$RIG" BRANCH="tok" GATE_PSC_SCRIPT="$CHECKER"
[ "$RC" = "1" ] && ok "skill token in a prompt: the block exits 1 (refuses)" || bad "token case: rc=$RC (want 1) :: $(cat "$C1.stdout" | head -3)"
fell "$C1" && bad "token case fell through" || ok "token case does not fall through"
has "$C1" "STATUS ga-marker-1 error" && ok "marker set to gate-status:error" || bad "no STATUS error recorded"
labeled "$C1" fail && ok "label gate-skillmention:fail recorded" || bad "label fail missing"
has "$C1" "Gate guard rejected marker: agent-prompt skill-token check (ga-gqtg1fs)" && ok "the comment names the check and the bead" || bad "rejection comment missing"
has "$C1" "gate-reviewer" && has "$C1" "/gate-done" && ok "the comment carries the red lines (which prompt, which text)" || bad "red lines missing from the comment"
has "$C1" "git push origin tok" && ok "the comment says how to push the fix" || bad "the comment does not name the branch to push"
has "$C1" "SKILLMENTION-CHECK bead=ga-bead-1 verdict=fail" && ok "log line SKILLMENTION-CHECK recorded" || bad "log line missing"

push_branch clean "$HQ/agents/gate-reviewer/prompt.template.md" 'one more plain sentence.'
C2="$WORK/c2"; drive "$C2" RIG_PATH="$RIG" BRANCH="clean" GATE_PSC_SCRIPT="$CHECKER"
[ "$RC" = "0" ] && fell "$C2" && ok "clean prompt edit falls through" || bad "clean prompt: rc=$RC fell=$(fell "$C2" && echo y || echo n)"
labeled "$C2" ok && ok "label gate-skillmention:ok recorded" || bad "label ok missing"
has "$C2" "STATUS" && bad "clean prompt set a gate status" || ok "clean prompt does not touch the gate status"

push_branch py "other/app.py" 'x = 2'
C3="$WORK/c3"; drive "$C3" RIG_PATH="$RIG" BRANCH="py" GATE_PSC_SCRIPT="$CHECKER"
fell "$C3" && labeled "$C3" sem-prompt-alterado && ok "a diff that touches no prompt passes and is recorded as sem-prompt-alterado" || bad "py-only diff: $(cat "$C3" | head -4 | tr '\n' '|')"

C4="$WORK/c4"; drive "$C4" RIG_PATH="$RIG" BRANCH="no-such-branch" GATE_PSC_SCRIPT="$CHECKER"
fell "$C4" && labeled "$C4" nao-consegui-medir && ok "a branch the origin does not have (fetch fails): fail-open, recorded" || bad "missing branch: $(cat "$C4" | head -4 | tr '\n' '|')"

# ---------------------------------------------------------------- verdict matrix with a stub checker
echo "C. verdict matrix: only 'fail' refuses (stub checker)"
STUBCOUNT="$WORK/stub.count"; : > "$STUBCOUNT"
mkstub() { # mkstub <path> <rc> <stdout text with \n escapes>
  { printf '#!/usr/bin/env bash\n'; printf 'echo x >> "%s"\n' "$STUBCOUNT"; printf 'printf "%%b" %s\n' "$(printf '%q' "$3")"; printf 'exit %s\n' "$2"; } > "$1"
}
matrix() { # matrix <label> <stub rc> <stub stdout> <want: refuse|pass> <want verdict label>
  local lab="$1" rc="$2" out="$3" want="$4" wv="$5" cf="$WORK/m.$RANDOM" stub="$WORK/stub.$RANDOM.sh"
  mkstub "$stub" "$rc" "$out"
  drive "$cf" RIG_PATH="$RIG" BRANCH="clean" GATE_PSC_SCRIPT="$stub"
  if [ "$want" = refuse ]; then
    [ "$RC" = "1" ] && ! fell "$cf" && labeled "$cf" "$wv" && has "$cf" "STATUS ga-marker-1 error" && ok "$lab -> refused, label $wv" || bad "$lab: wanted refusal ($wv), rc=$RC :: $(head -5 "$cf" | tr '\n' '|')"
  else
    [ "$RC" = "0" ] && fell "$cf" && labeled "$cf" "$wv" && hasnt "$cf" "STATUS" && ok "$lab -> passes, label $wv" || bad "$lab: wanted pass ($wv), rc=$RC :: $(head -5 "$cf" | tr '\n' '|')"
  fi
}
matrix "VERDICT=fail"                           0 'VERDICT=fail reason=x hits=1 tip=red base=green\n  ✗ gate-reviewer: skill token\n' refuse fail
matrix "VERDICT=debito-previo"                  0 'VERDICT=debito-previo reason=x hits=1 tip=red base=red\n' pass debito-previo
matrix "VERDICT=ok"                             0 'VERDICT=ok reason=x hits=1 tip=green base=-\n' pass ok
matrix "VERDICT=sem-prompt-alterado"            0 'VERDICT=sem-prompt-alterado reason=x hits=0 tip=- base=-\n' pass sem-prompt-alterado
matrix "VERDICT=nao-consegui-medir"             0 'VERDICT=nao-consegui-medir reason=x hits=1 tip=- base=-\n' pass nao-consegui-medir
matrix "unknown token (VERDICT=banana)"         0 'VERDICT=banana reason=x\n' pass nao-consegui-medir
matrix "token with a glued suffix (VERDICT=fail_x)" 0 'VERDICT=fail_x reason=x\n' pass nao-consegui-medir
matrix "no VERDICT line at all (garbage)"       0 'hello world\n' pass nao-consegui-medir
matrix "silence"                                0 '' pass nao-consegui-medir
matrix "checker crashes (rc 3, no output)"      3 '' pass nao-consegui-medir
matrix "VERDICT=fail but the checker exits 9"   9 'VERDICT=fail reason=x\n' refuse fail
matrix "verdict line not on the FIRST line"     0 'noise\nVERDICT=fail reason=x\n' pass nao-consegui-medir

echo "D. recorded, never silent: the paths that skip the measurement"
C5="$WORK/c5"; drive "$C5" RIG_PATH="$RIG" BRANCH="clean" GATE_PSC_SCRIPT="$WORK/does-not-exist.sh"
fell "$C5" && labeled "$C5" nao-consegui-medir && has "$C5" "reason=verificador-ilegivel" && ok "checker script missing: fail-open, recorded with its reason" || bad "missing checker: $(head -4 "$C5" | tr '\n' '|')"
C6="$WORK/c6"; drive "$C6" RIG_PATH="" BRANCH="clean" GATE_PSC_SCRIPT="$CHECKER"
fell "$C6" && labeled "$C6" nao-consegui-medir && has "$C6" "inputs_ok=0" && has "$C6" "rig_path=<EMPTY>" && ok "RIG_PATH unset: recorded as nao-consegui-medir inputs_ok=0, rig_path=<EMPTY>" || bad "unset RIG_PATH: $(head -4 "$C6" | tr '\n' '|')"
: > "$STUBCOUNT"
mkstub "$WORK/stub.counting.sh" 0 'VERDICT=fail reason=x\n'
C7="$WORK/c7"; drive "$C7" RIG_PATH="$RIG" BRANCH="clean" GATE_PSC_SCRIPT="$WORK/stub.counting.sh" GATE_SKILLMENTION_CHECK=off
fell "$C7" && labeled "$C7" desligado && [ ! -s "$STUBCOUNT" ] && ok "kill switch (env): desligado, recorded, the checker was NOT called" || bad "env kill switch: calls=$(wc -l < "$STUBCOUNT") :: $(head -3 "$C7" | tr '\n' '|')"
: > "$GCCITY/.gc/gate-skillmention.off"
C8="$WORK/c8"; drive "$C8" RIG_PATH="$RIG" BRANCH="clean" GATE_PSC_SCRIPT="$WORK/stub.counting.sh"
fell "$C8" && labeled "$C8" desligado && [ ! -s "$STUBCOUNT" ] && ok "kill switch (flag file): desligado, recorded, the checker was NOT called" || bad "flag-file kill switch: calls=$(wc -l < "$STUBCOUNT") :: $(head -3 "$C8" | tr '\n' '|')"
rm -f "$GCCITY/.gc/gate-skillmention.off"
C9="$WORK/c9"; BIG="$(awk 'BEGIN{for(i=1;i<=500;i++) printf "  X line %d %0200d\\n", i, 0}')"
mkstub "$WORK/stub.big.sh" 0 "VERDICT=fail reason=x\\n$BIG"
drive "$C9" RIG_PATH="$RIG" BRANCH="clean" GATE_PSC_SCRIPT="$WORK/stub.big.sh"
N="$(grep -c 'X line' "$C9" || true)"; [ "$RC" = "1" ] && [ "$N" -le 40 ] && [ "$N" -ge 1 ] && ok "a flood of detail is capped in the comment ($N lines of 500)" || bad "detail not capped: rc=$RC lines=$N"

echo
echo "gate-guard-skillmention-check selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
