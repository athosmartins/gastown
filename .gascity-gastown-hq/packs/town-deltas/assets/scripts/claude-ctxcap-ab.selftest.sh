#!/bin/bash
# claude-ctxcap-ab.selftest.sh — hermetic test for ga-55vrxw (E10 of P0 ga-ufskhy).
#
# Runs the REAL claude-ctxcap-ab.sh against a fake city under a temp dir, with a stub standing in for the
# next hop (claude-lowprio.sh -> claude), and checks the argv the stub receives. Nothing here starts claude.
#
# ISOLATION: every launch goes through `env -i`. A pool session running this test has its own GC_TEMPLATE /
# GC_SESSION_NAME / GC_CITY_PATH exported, and the wrapper reads exactly those — letting them leak would make
# a "no session name" case pass or fail on who happens to be running the test.
#
# WHAT THE CASES PROTECT. This wrapper sits on the launch path of EVERY pool session, and `claude` EXITS on an
# --autocompact value outside auto|100k-1M (measured, claude 2.1.286), so the dangerous failure is not "the
# arm did not apply" but "a typo in a conf file stopped every dog, wa-worker and gate-reviewer from starting".
# Hence: bad conf -> argv untouched (T6), conf text can never add a flag (T6 injection), the flag lands before
# any `--` (T9), and a missing next hop still launches claude (T13).
#
# MUTATION CONTROLS (bottom): the selftest is re-run against copies of the script with one guard removed each;
# every copy must make it FAIL. A test that stays green when the guard is gone proves nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CTXCAP_SCRIPT:-$HERE/claude-ctxcap-ab.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

CITY="$WORKDIR/city"
mkdir -p "$CITY/.gc/logs"
CONF="$CITY/.gc/context-ab.conf"
LOG="$CITY/.gc/logs/claude-lowprio.log"
OUT="$WORKDIR/argv.out"
STUB="$WORKDIR/stub-next.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB"

UUID="11111111-2222-3333-4444-555555555555"
ARGS=(--model sonnet --strict-mcp-config --effort xhigh --session-id "$UUID")
joined() { local IFS='|'; echo "$*"; }
ARGS_J="$(joined "${ARGS[@]}")"

# run_wrapper [ENV=val ...] -- args...   (later ENV wins; GC_SESSION_NAME= empties it)
run_wrapper() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$OUT"
  env -i PATH="$PATH" HOME="$WORKDIR" GC_CITY_PATH="$CITY" GC_CTXCAP_NEXT_BIN="$STUB" STUB_OUT="$OUT" \
    GC_TEMPLATE=gastown.dog GC_AGENT=gastown.dog-1 GC_SESSION_NAME=dog-aaa111 \
    ${envs[@]+"${envs[@]}"} /bin/bash "$SCRIPT" "$@"   # /bin/bash = the script's shebang = bash 3.2 on macOS, not the PATH bash
}
reset() { rm -f "$CONF" "$CITY/.gc/no-ctx-ab"; : > "$LOG"; }
conf()  { printf '%s\n' "$@" > "$CONF"; }
got_argv() { paste -sd'|' "$OUT"; }
expect_argv() { # name want
  local g; g="$(got_argv)"
  if [ "$g" = "$2" ]; then ok "$1"; else bad "$1 — got [$g] want [$2]"; fi
}
expect_log()   { if grep -q -- "$2" "$LOG"; then ok "$1"; else bad "$1 — no /$2/ in log: $(tr '\n' ';' < "$LOG")"; fi; }
expect_nolog() { if grep -q -- "$2" "$LOG"; then bad "$1 — unexpected /$2/ in log"; else ok "$1"; fi; }

GOOD=(salt=t1 "enroll=gastown.dog wa-worker" treat_window=200000)

echo "T1 inert without a conf"
reset
run_wrapper -- "${ARGS[@]}"
expect_argv "T1 argv untouched" "$ARGS_J"
expect_nolog "T1 no CTX-AB line" "CTX-AB"

echo "T2 treated arm (pct=100): flag prepended, uuid logged"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- "${ARGS[@]}"
expect_argv "T2 --autocompact 200000 + original argv" "--autocompact|200000|$ARGS_J"
expect_log "T2 arm=treat with uuid and window" "CTX-AB arm=treat .*uuid=$UUID.* window=200000"

echo "T3 control arm (pct=0): argv untouched, decision still logged"
reset; conf "${GOOD[@]}" treat_pct=0
run_wrapper -- "${ARGS[@]}"
expect_argv "T3 argv untouched" "$ARGS_J"
expect_log "T3 arm=control logged" "CTX-AB arm=control .*uuid=$UUID"

echo "T4 not enrolled"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_TEMPLATE=gate-reviewer GC_AGENT=gate-reviewer-7 -- "${ARGS[@]}"
expect_argv "T4 argv untouched" "$ARGS_J"
expect_nolog "T4 no arm line" "CTX-AB arm="

echo "T5 enrolled by GC_AGENT prefix when GC_TEMPLATE differs"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_TEMPLATE=other GC_AGENT=wa-worker-3 -- "${ARGS[@]}"
expect_argv "T5 treated via agent prefix" "--autocompact|200000|$ARGS_J"

echo "T6 bad conf never reaches claude (claude exits on an invalid --autocompact)"
n=0
# The 20-digit values are the third-state cases: `[ N -lt 100000 ]` cannot compare a number that overflows
# (it returns 2, an ERROR), and "could not compare" must never read as "in range".
for bad_line in "treat_window=50000" "treat_window=2000000" "treat_window=abc" "treat_window=200k" "treat_window=" \
                "treat_window=99999999999999999999" "treat_window=0200000" "treat_window=00000000000200000" \
                "treat_window=200000 --permission-mode bypassPermissions" "treat_window=200000;touch /tmp/x" \
                "treat_pct=101" "treat_pct=abc" "treat_pct=-1" "treat_pct=99999999999999999999" "treat_pct=1000" "bogus_key=1"; do
  n=$((n+1)); reset
  conf salt=t1 "enroll=gastown.dog" treat_window=200000 treat_pct=100
  case "$bad_line" in
    treat_window=*) conf salt=t1 "enroll=gastown.dog" "$bad_line" treat_pct=100 ;;
    treat_pct=*)    conf salt=t1 "enroll=gastown.dog" treat_window=200000 "$bad_line" ;;
    *)              conf salt=t1 "enroll=gastown.dog" treat_window=200000 treat_pct=100 "$bad_line" ;;
  esac
  run_wrapper -- "${ARGS[@]}"
  expect_argv "T6.$n [$bad_line] argv untouched" "$ARGS_J"
  expect_log  "T6.$n [$bad_line] WARN logged" "CTX-AB WARN"
done
reset; conf "enroll=gastown.dog" treat_window=200000 treat_pct=100          # salt missing
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.salt missing -> argv untouched" "$ARGS_J"
reset; conf salt=t1 treat_window=200000 treat_pct=100                       # enroll missing
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.enroll missing -> argv untouched" "$ARGS_J"
reset; conf salt=t1 "enroll=gastown.dog" treat_window=200000                # pct missing
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.pct missing -> argv untouched" "$ARGS_J"
reset; conf salt=t1 "enroll=gastown.dog" treat_window=100000 treat_pct=100  # exact floor is valid
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.floor 100000 accepted" "--autocompact|100000|$ARGS_J"
reset; conf salt=t1 "enroll=gastown.dog" treat_window=1000000 treat_pct=100 # exact ceiling is valid
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.ceiling 1000000 accepted" "--autocompact|1000000|$ARGS_J"

echo "T7 kill switches"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_CTX_AB=0 -- "${ARGS[@]}"
expect_argv "T7 GC_CTX_AB=0 argv untouched" "$ARGS_J"
reset; conf "${GOOD[@]}" treat_pct=100; : > "$CITY/.gc/no-ctx-ab"
run_wrapper -- "${ARGS[@]}"
expect_argv "T7 .gc/no-ctx-ab argv untouched" "$ARGS_J"
expect_nolog "T7 kill switch is silent (no arm line)" "CTX-AB arm="

echo "T8 argv that already carries --autocompact is left alone"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- "${ARGS[@]}" --autocompact 150k
expect_argv "T8 separate-value form" "$ARGS_J|--autocompact|150k"
run_wrapper -- "${ARGS[@]}" --autocompact=150k
expect_argv "T8 =value form" "$ARGS_J|--autocompact=150k"
expect_log "T8 SKIP logged" "CTX-AB SKIP"

echo "T9 flag lands before a -- separator and a trailing prompt"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- --model sonnet -- "do the thing"
expect_argv "T9 prepended" "--autocompact|200000|--model|sonnet|--|do the thing"

echo "T10 no session name -> left alone"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_SESSION_NAME= -- "${ARGS[@]}"
expect_argv "T10 argv untouched" "$ARGS_J"
expect_log "T10 WARN logged" "CTX-AB WARN"

# T11 launches the wrapper 180 times (a few minutes when the box is loaded) and no mutation below needs it,
# so the mutation re-runs skip it.
if [ -z "${CTXCAP_NO_MUTATE:-}" ]; then
echo "T11 the split is deterministic, honours pct, and the salt matters"
reset; conf "${GOOD[@]}" treat_pct=50
treat=0; vec_a=""
for i in $(seq 1 60); do
  run_wrapper GC_SESSION_NAME="dog-s$i" -- "${ARGS[@]}"
  if [ "$(head -1 "$OUT")" = "--autocompact" ]; then treat=$((treat+1)); vec_a="${vec_a}1"; else vec_a="${vec_a}0"; fi
done
if [ "$treat" -ge 17 ] && [ "$treat" -le 43 ]; then ok "T11 pct=50 over 60 sessions -> $treat treated"; else bad "T11 pct=50 over 60 sessions -> $treat treated (want 17..43)"; fi
vec_b=""
for i in $(seq 1 60); do
  run_wrapper GC_SESSION_NAME="dog-s$i" -- "${ARGS[@]}"
  if [ "$(head -1 "$OUT")" = "--autocompact" ]; then vec_b="${vec_b}1"; else vec_b="${vec_b}0"; fi
done
if [ "$vec_a" = "$vec_b" ]; then ok "T11 same session name -> same arm on a second launch"; else bad "T11 arms changed between two identical passes"; fi
conf salt=t2 "enroll=gastown.dog" treat_window=200000 treat_pct=50
vec_c=""
for i in $(seq 1 60); do
  run_wrapper GC_SESSION_NAME="dog-s$i" -- "${ARGS[@]}"
  if [ "$(head -1 "$OUT")" = "--autocompact" ]; then vec_c="${vec_c}1"; else vec_c="${vec_c}0"; fi
done
if [ "$vec_a" != "$vec_c" ]; then ok "T11 a new salt reshuffles the split"; else bad "T11 salt t1 and t2 gave the identical split"; fi
fi

echo "T12 exit status of the next hop is the wrapper's exit status (exec, not a child)"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper STUB_RC=7 -- "${ARGS[@]}"; rc=$?
if [ "$rc" -eq 7 ]; then ok "T12 rc=7 propagated"; else bad "T12 rc=$rc, want 7"; fi

echo "T13 next hop missing -> claude is still launched (fail-open), arm still applied"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_CTXCAP_NEXT_BIN="$WORKDIR/does-not-exist" GC_LOWPRIO_CLAUDE_BIN="$STUB" -- "${ARGS[@]}"
expect_argv "T13 fell back to the real claude with the arm applied" "--autocompact|200000|$ARGS_J"
expect_log "T13 WARN logged" "CTX-AB WARN"

echo "T14 no log directory -> still launches"
rm -rf "$CITY/.gc/logs"; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- "${ARGS[@]}"
expect_argv "T14 treated without a log dir" "--autocompact|200000|$ARGS_J"
mkdir -p "$CITY/.gc/logs"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"

# ---- MUTATION CONTROLS ---------------------------------------------------------------------------------------
# Each mutation removes ONE guard from a copy of the script; the selftest re-run against that copy must FAIL.
# A sed that changes nothing is itself a failure (the pattern went stale), never a silent pass.
if [ "$FAIL" -eq 0 ] && [ -z "${CTXCAP_NO_MUTATE:-}" ]; then
  echo
  echo "MUTATION CONTROLS"
  MFAIL=0
  mutate() { # name sed-expr
    local name="$1" expr="$2" copy="$WORKDIR/mut-$1.sh"
    sed -e "$expr" "$SCRIPT" > "$copy"
    if cmp -s "$SCRIPT" "$copy"; then
      echo "  FAIL: mutation $name did not change the script (stale pattern)"; MFAIL=$((MFAIL+1)); return
    fi
    if CTXCAP_SCRIPT="$copy" CTXCAP_NO_MUTATE=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
      echo "  FAIL: mutation $name was NOT caught — the selftest passes without that guard"; MFAIL=$((MFAIL+1))
    else
      echo "  PASS: mutation $name caught"
    fi
  }
  mutate window-floor     's/-lt 100000/-lt 1/'
  mutate window-ceiling   's/-gt 1000000/-gt 99999999999/'
  mutate window-digits    's/ab_win" in \(.*\)\*\[!0-9\]\*)/ab_win" in \1NEVER)/'
  mutate pct-ceiling      's/"\$ab_pct" -gt 100/"$ab_pct" -gt 9999/'
  mutate window-overflow  's/"\${#ab_win}" -gt 7/"${#ab_win}" -gt 70/'
  mutate pct-overflow     's/"\${#ab_pct}" -gt 3/"${#ab_pct}" -gt 30/'
  mutate window-leading-0 's/\x27\x27|0\*|\*\[!0-9\]\*)/\x27\x27|*[!0-9]*)/'
  mutate arm-inverted     's/"\$ab_n" -lt "\$ab_pct"/"$ab_n" -ge "$ab_pct"/'
  mutate append-not-prepend 's/argv=(--autocompact "\$ab_win" \${argv\[@\]+"\${argv\[@\]}"})/argv=(${argv[@]+"${argv[@]}"} --autocompact "$ab_win")/'
  mutate already-set      's/--autocompact|--autocompact=\*)/--autocompact-never)/'
  mutate no-session-name  's/\[ -z "\$ab_sn" \]/[ -z "never" ]/'
  mutate kill-env         's/"\${GC_CTX_AB:-}" != "0"/"${GC_CTX_AB:-}" != "never"/'
  mutate kill-file        's/! -e "\$city\/.gc\/no-ctx-ab"/! -e "$city\/.gc\/never"/'
  mutate fail-open-next   's/\[ -x "\$next" \]/[ -n "$next" ]/'
  if [ "$MFAIL" -ne 0 ]; then FAIL=$((FAIL+MFAIL)); fi
fi

[ "$FAIL" -eq 0 ]
