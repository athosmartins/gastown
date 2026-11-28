#!/usr/bin/env bash
# gate-guard-hardchecks.selftest.sh — ga-vywjzsp: the guard's Step 5b-pre5 (the gate's hard checks 2b-2f at submission; 2f, ga-89ix4m4, is the test lock).
#
# The block between the `SELFTEST-EXTRACT hardchecks` sentinels in quality-gate-guard.sh is extracted and EXECUTED here, not
# re-implemented, under the guard's own `set -euo pipefail`; only log/err/set_gate_status/bd are stubbed (they record what the
# block asked for). Two kinds of case:
#   - END TO END with the real gate-hard-checks.sh, the real tools and a real git repo with an origin (the rig is a SUBDIRECTORY
#     of the clone, as the gascity rig is in production): a doc without Contents is refused by step 2c, a clean one passes, and a
#     new read with no failure test is refused by step 2e and leaves its arm in the city's .gc;
#   - VERDICT MATRIX with a stub checker: what the guard does with each verdict, with garbage, silence, a crash, a missing
#     checker, the switches, an unset input. The rule under test: ONLY `fail` refuses, in enforce mode. Every other answer,
#     including "could not measure", lets the submission through and is RECORDED (a label and a log line per step).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GATE_GUARD_SUT:-$SELF_DIR/quality-gate-guard.sh}"
CHECKER="${GHC_SUT:-$SELF_DIR/gate-hard-checks.sh}"
RHQ="${GHC_HQ:-$(cd "$SELF_DIR/../../.." && pwd)}"
HQ=".gascity-gastown-hq"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }          # has <file> <fixed string>
hasnt() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

for f in "$GUARD" "$CHECKER" "$RHQ/scripts/doc-rules-lint.py" "$RHQ/scripts/repro-lock.py" "$RHQ/packs/town-deltas/assets/third-state-reads-check.py"; do [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }; done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/guard-hc-selftest.XXXXXX")" || { echo "FATAL: no scratch dir"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

echo "A. the block is extractable and parses"
B=$(grep -c '^# SELFTEST-EXTRACT hardchecks: BEGIN$' "$GUARD"); E=$(grep -c '^# SELFTEST-EXTRACT hardchecks: END$' "$GUARD")
if [ "$B/$E" = "1/1" ]; then ok "sentinels present exactly once each"; else bad "sentinels: BEGIN=$B END=$E (want 1/1)"; echo "FATAL: nothing below can run"; echo; echo "gate-guard-hardchecks selftest: $PASS passed, $FAIL failed"; exit 1; fi
BLOCK="$WORK/block.sh"
sed -n '/^# SELFTEST-EXTRACT hardchecks: BEGIN$/,/^# SELFTEST-EXTRACT hardchecks: END$/p' "$GUARD" | sed '1d;$d' > "$BLOCK"
if [ -s "$BLOCK" ] && bash -n "$BLOCK" 2>/dev/null; then ok "block extracted ($(wc -l < "$BLOCK" | tr -d ' ') lines) and parses"; else echo "FATAL: block empty or does not parse"; exit 1; fi

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
fell() { has "$1" "BLOCK-FELL-THROUGH"; }
lab() { has "$1" "label add ga-marker-1 $2:$3"; }     # lab <calls> <label> <verdict>

# the city: copies of the REAL tools and of the checker, so the checker's default HQ_DIR is this city
GCCITY="$WORK/city"; AS="$GCCITY/packs/town-deltas/assets"
mkdir -p "$GCCITY/scripts" "$AS" "$GCCITY/.gc" && cp "$RHQ/scripts/doc-rules-lint.py" "$RHQ/scripts/repro-lock.py" "$GCCITY/scripts/" && cp "$CHECKER" "$AS/" || { echo "FATAL: cannot build the fixture city"; exit 1; }
for f in third-state-reads-check.py e12-crew-doctrine.sh e12-arms.sh template-fragment-lint-guard.sh; do cp "$RHQ/packs/town-deltas/assets/$f" "$AS/" || exit 1; done
# the checker's own helpers sit beside it in the city: 2c runs the lint through gate-hard-checks-lint.py and without it the step is unmeasured (ga-ymc1052)
for f in gate-hard-checks-imports.py gate-hard-checks-lint.py; do cp "$(dirname "$CHECKER")/$f" "$AS/" || { echo "FATAL: cannot build the fixture city ($f beside the checker)"; exit 1; }; done

echo "B. end to end: real checker and tools, real git, rig = a subdirectory of the clone"
ORIGIN="$WORK/origin.git"; BUILD="$WORK/build"; RIGCLONE="$WORK/rigclone"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
mkdir -p "$BUILD/$HQ" "$BUILD/docs" "$BUILD/lib" && git -C "$BUILD" init -q && git -C "$BUILD" symbolic-ref HEAD refs/heads/main
git -C "$BUILD" config user.email t@example.invalid; git -C "$BUILD" config user.name t; git -C "$BUILD" config commit.gpgsign false
FILL=""; i=0; while [ "$i" -lt 12 ]; do FILL="$FILL a-sentence-long-enough-to-pass-the-300-char-threshold."; i=$((i+1)); done
printf '# T\n\n## Contents\n\n- A\n\n## A\n\n%s\n' "$FILL" > "$BUILD/docs/ok.md"; printf 'x = 1\n' > "$BUILD/lib/app.py"; : > "$BUILD/$HQ/.keep"
git -C "$BUILD" add -A && git -C "$BUILD" commit -q -m base && git -C "$BUILD" remote add origin "$ORIGIN" && git -C "$BUILD" push -q origin main
git clone -q "$ORIGIN" "$RIGCLONE" 2>/dev/null
RIG="$RIGCLONE/$HQ"
push_branch() { # push_branch <name> <file> <content>   (branches from main)
  git -C "$BUILD" checkout -q -b "$1" main && printf '%b' "$3" > "$BUILD/$2" && git -C "$BUILD" add -A && git -C "$BUILD" commit -q -m "$1" && git -C "$BUILD" push -q origin "$1" && git -C "$BUILD" checkout -q main
}
push_branch bad docs/new_bad.md "# T\n\n## A\n\n$FILL\n"
C1="$WORK/c1"; drive "$C1" RIG_PATH="$RIG" BRANCH="bad"
if [ "$RC" = "1" ] && ! fell "$C1"; then ok "a doc over 300 chars without Contents: the block exits 1 (refuses)"; else bad "bad doc: rc=$RC fell=$(fell "$C1" && echo y || echo n) :: $(head -4 "$C1.stdout" | tr '\n' '|')"; fi
has "$C1" "STATUS ga-marker-1 error" && ok "marker set to gate-status:error" || bad "no STATUS error recorded"
lab "$C1" gate-docrules fail && lab "$C1" gate-tmplparse nao-se-aplica && lab "$C1" gate-e12cov nao-se-aplica && lab "$C1" gate-tsr nao-ligado && lab "$C1" gate-testlock nao-se-aplica && ok "one label per step: docrules fail, the others measured zero / not switched on (no test lock declared)" || bad "labels: $(grep 'label add' "$C1" | tr '\n' '|')"
has "$C1" "Gate guard rejected marker: gate hard checks (ga-vywjzsp), step(s) 2c." && ok "the comment names the check and the failing step" || bad "rejection comment missing"
has "$C1" "contents-missing" && ok "the comment carries the tool's own line (which file, which rule)" || bad "the tool's line is missing from the comment"
has "$C1" "git push origin bad" && has "$C1" "--fix-contents" && ok "the comment says how to rerun the step and how to push" || bad "hint/push line missing"
n="$(grep -c 'LOG HARDCHECK step=' "$C1")"; [ "$n" = 5 ] && ok "five HARDCHECK log lines, one per step" || bad "HARDCHECK lines: $n (want 5)"
has "$C1" "step=2c verdict=fail" && has "$C1" "checker=[VERDICT=fail step=2c reason=violacoes-doc-rules rc=1" && ok "the 2c line carries the checker's line with the tool's rc" || bad "2c log line: $(grep 'step=2c' "$C1" | head -2)"

push_branch clean docs/new_ok.md "# T\n\n## Contents\n\n- A\n\n## A\n\n$FILL\n"
C2="$WORK/c2"; drive "$C2" RIG_PATH="$RIG" BRANCH="clean"
[ "$RC" = "0" ] && fell "$C2" && ok "a clean doc falls through" || bad "clean doc: rc=$RC :: $(head -4 "$C2.stdout" | tr '\n' '|')"
lab "$C2" gate-docrules ok && hasnt "$C2" "STATUS" && ok "label docrules:ok, the gate status untouched" || bad "clean doc labels: $(grep 'label add' "$C2" | tr '\n' '|')"
push_branch code lib/app.py 'x = 2\n'
C3="$WORK/c3"; drive "$C3" RIG_PATH="$RIG" BRANCH="code"
fell "$C3" && lab "$C3" gate-docrules nao-se-aplica && ok "a code-only diff: 2c is a measured zero" || bad "code-only: $(grep 'label add' "$C3" | tr '\n' '|')"
printf 'mode=enforce\n' > "$GCCITY/.gc/third-state-reads.conf"
push_branch read lib/m.py 'def load(p):\n    return open(p).read()\n'
C4="$WORK/c4"; drive "$C4" RIG_PATH="$RIG" BRANCH="read"
[ "$RC" = "1" ] && lab "$C4" gate-tsr fail && has "$C4" "step(s) 2e." && ok "a new read with no failure test: refused by step 2e" || bad "read case: rc=$RC :: $(grep -E 'label add|STATUS' "$C4" | tr '\n' '|')"
grep -q '"bead": "ga-bead-1"' "$GCCITY/.gc/third-state-reads-arms.jsonl" 2>/dev/null && ok "the bead's arm is now a row in .gc/third-state-reads-arms.jsonl (the proof step 2e ran)" || bad "no arms row recorded"
rm -f "$GCCITY/.gc/third-state-reads.conf"
# 2f end to end (ga-89ix4m4): a branch whose FIRST commit is the test lock (trailers), then the fix; the real repro-lock.py reads only the history
push_lock() { # push_lock <name> <intact|tamper|release>
  git -C "$BUILD" checkout -q -b "$1" main && mkdir -p "$BUILD/tests" && printf 'def test_bug():\n    assert f() == 2\n' > "$BUILD/tests/test_lock.py" \
    && git -C "$BUILD" add -A && printf 'test(ga-bead-1): reproduz\n\nRepro-Lock: ga-bead-1\nRepro-Lock-File: tests/test_lock.py\n' | git -C "$BUILD" commit -q -F - \
    && printf 'x = 2\n' > "$BUILD/lib/app.py" && git -C "$BUILD" commit -q -am fix || return 1
  case "$2" in
    (tamper) printf 'def test_bug():\n    assert True\n' > "$BUILD/tests/test_lock.py"; git -C "$BUILD" commit -q -am loosen ;;
    (release) printf 'chore(ga-bead-1): libera\n\nRepro-Lock-Release: ga-bead-1\nRepro-Lock-Release-Reason: o teste confere 3 mas o contrato diz 2: defeito do teste\n' | git -C "$BUILD" commit -q --allow-empty -F - \
                && printf 'def test_bug():\n    assert f() == 2  # corrigido\n' > "$BUILD/tests/test_lock.py" && git -C "$BUILD" commit -q -am corrige ;;
  esac
  git -C "$BUILD" push -q origin "$1" && git -C "$BUILD" checkout -q main
}
push_lock lockok intact
C12="$WORK/c12"; drive "$C12" RIG_PATH="$RIG" BRANCH="lockok"
[ "$RC" = "0" ] && fell "$C12" && lab "$C12" gate-testlock ok && hasnt "$C12" "STATUS" && ok "2f: a lock commit first, the test untouched: passes, label testlock:ok" || bad "lock intact: rc=$RC :: $(grep -E 'label|STATUS' "$C12" | tr '\n' '|')"
push_lock locktamper tamper
C13="$WORK/c13"; drive "$C13" RIG_PATH="$RIG" BRANCH="locktamper"
[ "$RC" = "1" ] && ! fell "$C13" && lab "$C13" gate-testlock fail && has "$C13" "STATUS ga-marker-1 error" && has "$C13" "step(s) 2f." && ok "2f: a commit that loosens the locked test is refused, marker gate-status:error" || bad "lock tamper: rc=$RC :: $(grep -E 'label|STATUS' "$C13" | tr '\n' '|')"
has "$C13" "teste-travado-alterado" && has "$C13" "tests/test_lock.py depois da trava" && has "$C13" "repro-lock.py check" && has "$C13" "repro-lock.py release" && ok "the comment carries the tool's lines and says how to rerun the step and how to release with a reason" || bad "2f refusal comment incomplete"
has "$C13" "step=2f verdict=fail reason=teste-travado-alterado" && ok "the HARDCHECK line of step 2f carries the tool's reason" || bad "2f log line: $(grep 'step=2f' "$C13" | head -2)"
push_lock lockrel release
C14="$WORK/c14"; drive "$C14" RIG_PATH="$RIG" BRANCH="lockrel"
[ "$RC" = "0" ] && fell "$C14" && lab "$C14" gate-testlock aviso && hasnt "$C14" "STATUS" && ok "2f: a release with a reason is an aviso: passes, label testlock:aviso" || bad "lock release: rc=$RC :: $(grep -E 'label|STATUS' "$C14" | tr '\n' '|')"
has "$C14" "Gate guard note (ga-89ix4m4, step 2f)" && has "$C14" "o teste confere 3 mas o contrato diz 2" && ok "and the reason is a comment on the marker, where the reviewer reads it" || bad "no 2f note on the marker: $(grep -c 'BD .*comment' "$C14") comment calls"
C5="$WORK/c5"; drive "$C5" RIG_PATH="$RIG" BRANCH="no-such-branch"
fell "$C5" && lab "$C5" gate-docrules nao-consegui-medir && lab "$C5" gate-tsr nao-consegui-medir && lab "$C5" gate-testlock nao-consegui-medir && has "$C5" "reason=fetch-falhou" && ok "a branch the origin does not have: all five steps fail-open and recorded" || bad "missing branch: $(head -6 "$C5" | tr '\n' '|')"
# main moves after the branch was cut: the checker must get the MERGE BASE, not the new main tip (or it would judge main's own changes)
git -C "$BUILD" checkout -q -b behind main && printf 'x = 3\n' > "$BUILD/lib/app.py" && git -C "$BUILD" commit -qam behind && git -C "$BUILD" push -q origin behind
git -C "$BUILD" checkout -q main && printf 'y = 1\n' > "$BUILD/lib/other.py" && git -C "$BUILD" add -A && git -C "$BUILD" commit -qm "main moves" && git -C "$BUILD" push -q origin main
ARGS="$WORK/args.log"; : > "$ARGS"
printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >> "%s"; echo >> "%s"\necho "VERDICT=ok step=$1 reason=x rc=0 tip=- base=- arm=-"\n' "$ARGS" "$ARGS" > "$WORK/argstub.sh"
C6="$WORK/c6"; drive "$C6" RIG_PATH="$RIG" BRANCH="behind" GATE_HC_SCRIPT="$WORK/argstub.sh"
MB="$(git -C "$BUILD" merge-base behind main)"; TIPSHA="$(git -C "$BUILD" rev-parse behind)"; MAINSHA="$(git -C "$BUILD" rev-parse main)"
if grep -qF "2c|$RIG|$MB|$TIPSHA|ga-bead-1|" "$ARGS" && [ "$MB" != "$MAINSHA" ]; then ok "the checker gets rig, MERGE BASE (not main's tip), the branch tip and the bead, once per step"; else bad "args: $(cat "$ARGS" | tr '\n' ' ') (merge-base $MB, main $MAINSHA)"; fi
[ "$(wc -l < "$ARGS" | tr -d ' ')" = 5 ] && ok "the checker was called exactly five times" || bad "calls: $(wc -l < "$ARGS")"

echo "C. verdict matrix: only 'fail' refuses, in enforce mode (stub checker)"
STUBDIR="$WORK/stubs"; mkdir -p "$STUBDIR"; STUBCOUNT="$WORK/stub.count"; : > "$STUBCOUNT"
{ printf '#!/usr/bin/env bash\necho x >> "%s"\n' "$STUBCOUNT"; printf '[ -f "%s/$1" ] && printf "%%b" "$(cat "%s/$1")"\n' "$STUBDIR" "$STUBDIR"; printf 'exit "$(cat "%s/$1.rc" 2>/dev/null || echo 0)"\n' "$STUBDIR"; } > "$WORK/stub.sh"
setstub() { printf '%s' "$2" > "$STUBDIR/$1"; if [ -n "${3:-}" ]; then printf '%s' "$3" > "$STUBDIR/$1.rc"; else rm -f "$STUBDIR/$1.rc"; fi; }
allstubs() { local s=""; for s in 2b 2c 2d 2e 2f; do setstub "$s" "$1"; done; }
mx() { # mx <label> <want refuse|pass> <step> <label name> <want verdict label> [VAR=value ...]
  local l="$1" want="$2" st="$3" ln="$4" wv="$5" cf="$WORK/m.$RANDOM"; shift 5
  MXCF="$cf"   # the log of the case just run, for the checks that follow it (a glob over m.* would be several files, not this one)
  drive "$cf" RIG_PATH="$RIG" BRANCH="clean" GATE_HC_SCRIPT="$WORK/stub.sh" "$@"
  if [ "$want" = refuse ]; then
    [ "$RC" = 1 ] && ! fell "$cf" && lab "$cf" "$ln" "$wv" && has "$cf" "STATUS ga-marker-1 error" && ok "$l -> refused, label $ln:$wv" || bad "$l: wanted refusal, rc=$RC :: $(grep -E 'label|STATUS' "$cf" | tr '\n' '|')"
  else
    [ "$RC" = 0 ] && fell "$cf" && lab "$cf" "$ln" "$wv" && hasnt "$cf" "STATUS" && ok "$l -> passes, label $ln:$wv" || bad "$l: wanted pass, rc=$RC :: $(grep -E 'label|STATUS' "$cf" | tr '\n' '|')"
  fi
}
V() { printf 'VERDICT=%s step=2c reason=x rc=%s tip=- base=- arm=-\\n' "$1" "${2:-0}"; }
allstubs "$(V ok)"
setstub 2c "$(V fail 1)\\n  contents-missing line\\n";                                         mx "2c VERDICT=fail" refuse 2c gate-docrules fail
setstub 2c "$(V fail 1)\\n";  setstub 2e "$(V fail 1)\\n";                                       mx "2c and 2e both fail" refuse 2e gate-tsr fail
has "$MXCF" "step(s) 2c 2e." && ok "ONE refusal lists both failing steps" || bad "two failures: $(grep 'rejected' "$MXCF" | head -2)"
allstubs "$(V ok)"
for v in debito-previo aviso nao-se-aplica nao-ligado desligado nao-consegui-medir ok; do setstub 2c "$(V "$v")\\n"; mx "2c VERDICT=$v" pass 2c gate-docrules "$v"; done
setstub 2c "$(V banana)\\n";                    mx "unknown token (VERDICT=banana)" pass 2c gate-docrules nao-consegui-medir
setstub 2c "$(V fail_x)\\n";                    mx "token with a glued suffix (VERDICT=fail_x)" pass 2c gate-docrules nao-consegui-medir
setstub 2c 'hello world\n';                     mx "no VERDICT line (garbage)" pass 2c gate-docrules nao-consegui-medir
setstub 2c '';                                  mx "silence" pass 2c gate-docrules nao-consegui-medir
setstub 2c '' 3;                                mx "checker crashes (rc 3, no output)" pass 2c gate-docrules nao-consegui-medir
setstub 2c "$(V fail 1)\\n" 9;                  mx "VERDICT=fail but the checker exits 9" refuse 2c gate-docrules fail
setstub 2c "noise\\n$(V fail 1)\\n";            mx "verdict line not on the FIRST line" pass 2c gate-docrules nao-consegui-medir
setstub 2c "$(V ok)\\n"
V2f() { printf 'VERDICT=%s step=2f reason=x rc=%s tip=- base=- arm=-\\n' "$1" "${2:-0}"; }
setstub 2f "$(V2f fail 1)\\n  teste-travado-alterado: abc1234 mexe em tests/test_a.py depois da trava\\n";   mx "2f VERDICT=fail" refuse 2f gate-testlock fail
has "$MXCF" "step(s) 2f." && has "$MXCF" "repro-lock.py check" && ok "the refusal names step 2f and its rerun command" || bad "2f refusal text: $(grep 'rejected' "$MXCF" | head -2)"
setstub 2c "$(V fail 1)\\n"; setstub 2f "$(V2f fail 1)\\n"
mx "2c and 2f both fail" refuse 2f gate-testlock fail
has "$MXCF" "step(s) 2c 2f." && ok "ONE refusal lists both" || bad "2c+2f refusal: $(grep 'rejected' "$MXCF" | head -2)"
setstub 2c "$(V ok)\\n"
setstub 2f "$(V2f aviso)\\n  liberada em abc1234: o teste confere 3 mas o contrato diz 2\\n"
mx "2f VERDICT=aviso (a release with a reason)" pass 2f gate-testlock aviso
has "$MXCF" "Gate guard note (ga-89ix4m4, step 2f)" && has "$MXCF" "o teste confere 3 mas o contrato diz 2" && ok "and the reason is posted on the marker" || bad "2f note: $(grep -c 'comment' "$MXCF") comment calls"
setstub 2c "$(V aviso)\\n"; setstub 2f "$(V2f ok)\\n"
mx "an aviso of ANOTHER step leaves no 2f note" pass 2c gate-docrules aviso
hasnt "$MXCF" "Gate guard note (ga-89ix4m4" && ok "no 2f note without a 2f aviso" || bad "a 2f note appeared for another step's aviso"
for v in ok nao-se-aplica desligado nao-consegui-medir debito-previo nao-ligado; do setstub 2f "$(V2f "$v")\\n"; mx "2f VERDICT=$v" pass 2f gate-testlock "$v"; done
setstub 2f "$(V2f banana)\\n";                  mx "2f unknown token (VERDICT=banana)" pass 2f gate-testlock nao-consegui-medir
allstubs "$(V ok)"
setstub 2c "$(V fail 1)\\n"
mx "observe mode: a fail is recorded and NOT refused" pass 2c gate-docrules fail GATE_HARDCHECKS=observe
has "$MXCF" "HARDCHECK-OBSERVE would refuse marker ga-marker-1 (steps: 2c)" && ok "and the log says what it WOULD have refused" || bad "no observe line"

echo "D. recorded, never silent: the paths that skip the measurement"
C7="$WORK/c7"; drive "$C7" RIG_PATH="$RIG" BRANCH="clean" GATE_HC_SCRIPT="$WORK/does-not-exist.sh"
n="$(grep -c 'reason=verificador-ilegivel' "$C7")"; fell "$C7" && lab "$C7" gate-docrules nao-consegui-medir && [ "$n" = 5 ] && ok "checker script missing: fail-open, recorded on all five steps with its reason" || bad "missing checker: n=$n $(head -4 "$C7" | tr '\n' '|')"
C8="$WORK/c8"; drive "$C8" RIG_PATH="" BRANCH="clean" GATE_HC_SCRIPT="$WORK/stub.sh"
fell "$C8" && lab "$C8" gate-tsr nao-consegui-medir && has "$C8" "reason=entrada-nao-resolvida" && has "$C8" "checker=[<EMPTY>]" && ok "RIG_PATH unset: recorded as nao-consegui-medir, the checker line says <EMPTY>" || bad "unset input: $(head -4 "$C8" | tr '\n' '|')"
: > "$STUBCOUNT"
C9="$WORK/c9"; drive "$C9" RIG_PATH="$RIG" BRANCH="clean" GATE_HC_SCRIPT="$WORK/stub.sh" GATE_HARDCHECKS=off
n="$(grep -c 'label add ga-marker-1 gate-.*:desligado' "$C9")"; fell "$C9" && [ "$n" = 5 ] && [ ! -s "$STUBCOUNT" ] && ok "kill switch (env): five desligado records, the checker was NOT called" || bad "env switch: n=$n calls=$(wc -l < "$STUBCOUNT")"
: > "$GCCITY/.gc/gate-hardchecks.off"; : > "$STUBCOUNT"
C10="$WORK/c10"; drive "$C10" RIG_PATH="$RIG" BRANCH="clean" GATE_HC_SCRIPT="$WORK/stub.sh"
n="$(grep -c 'label add ga-marker-1 gate-.*:desligado' "$C10")"; fell "$C10" && [ "$n" = 5 ] && [ ! -s "$STUBCOUNT" ] && ok "kill switch (flag file): five desligado records, the checker was NOT called" || bad "flag switch: n=$n calls=$(wc -l < "$STUBCOUNT")"
rm -f "$GCCITY/.gc/gate-hardchecks.off"
BIG="$(awk 'BEGIN{for(i=1;i<=500;i++) printf "  X line %d %0200d\\n", i, 0}')"
setstub 2c "$(V fail 1)\\n$BIG"
C11="$WORK/c11"; drive "$C11" RIG_PATH="$RIG" BRANCH="clean" GATE_HC_SCRIPT="$WORK/stub.sh"
N="$(grep -c 'X line' "$C11" || true)"; [ "$RC" = 1 ] && [ "$N" -ge 1 ] && [ "$N" -le 20 ] && ok "a flood of detail is capped in the comment ($N lines of 500)" || bad "detail not capped: rc=$RC lines=$N"

echo
echo "gate-guard-hardchecks selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
