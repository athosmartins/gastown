#!/usr/bin/env bash
# claude-effort-ab.selftest.sh — ga-5c3msy (E8): the effort A/B arm inside assets/scripts/claude-lowprio.sh.
#
# That wrapper is the `command` of EVERY pool session (dog, wa-worker, ps-worker, reviewers, refiners): a bug
# here stops the whole factory from launching, so the arm logic is held to three promises and each case below
# exists for one of them:
#   1. INERT BY DEFAULT — no .gc/effort-ab.conf (or either kill switch) => claude gets its argv byte-for-byte,
#      and nothing is logged. Shipping the code changes nothing until someone writes the conf.
#   2. ONLY THE VALUE AFTER --effort MOVES, and only for an enrolled session launched on control_effort.
#      Everything else in argv (spaces, newlines, --session-id, the prompt) arrives untouched and in order;
#      a role set to another effort on purpose is never overridden.
#   3. FAIL-OPEN — a bad conf, a missing shasum, no --effort, no session name: claude STILL starts with its
#      argv as received, and the log says why. (The exec is the last line; nothing above it may exit.)
# Plus the property the experiment stands on: the split is deterministic per session name, roughly uniform,
# and honours treat_pct 0 / 100 exactly.
#
# Hermetic: scrubbed env (env -i), a fake claude that prints its argv, private city dir. Run under
# /bin/bash 3.2 (what the wrapper runs under on this host) AND the default bash.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${CLAUDE_LOWPRIO_WRAPPER:-$SELF_DIR/scripts/claude-lowprio.sh}"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
[ -f "$WRAPPER" ] || { echo "FATAL: wrapper not found at $WRAPPER"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-effort-ab-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
CITY="$W/city"; mkdir -p "$CITY/.gc/logs"
LOG="$CITY/.gc/logs/claude-lowprio.log"
FAKE="$W/fake-claude.sh"
cat > "$FAKE" <<'EOF'
#!/bin/bash
i=0; for a in "$@"; do i=$((i+1)); printf 'arg%d=[%s]\n' "$i" "$a"; done; echo "argc=$#"
EOF
chmod +x "$FAKE"
PROMPT=$'prompt with spaces, "quotes" and a\nnewline'

# run_wb <wrapper> <env assignments...> -- <claude args...>: scrubbed env, GC_LOWPRIO=0 (no renice noise)
run_with() {
  local wrapper="$1"; shift; local envs=() a
  while [ "$#" -gt 0 ]; do a="$1"; shift; [ "$a" = "--" ] && break; envs+=("$a"); done
  env -i PATH="${SHIM_PATH:-$PATH}" HOME="$W" GC_CITY_PATH="$CITY" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$FAKE" ${envs[@]+"${envs[@]}"} /bin/bash "$wrapper" "$@"
}
run() { run_with "$WRAPPER" "$@"; }
std_args=(--model sonnet --effort xhigh --session-id U-1 "$PROMPT")
argv_of() { run "$@" -- "${std_args[@]}"; }
arg4() { printf '%s\n' "$1" | sed -n 's/^arg4=\[\(.*\)\]$/\1/p'; }
conf() { printf '%s\n' "$@" > "$CITY/.gc/effort-ab.conf"; }
noconf() { rm -f "$CITY/.gc/effort-ab.conf" "$CITY/.gc/no-effort-ab"; }
reset_log() { : > "$LOG"; }
good_conf() { conf "salt=t1" "enroll=wa-worker gastown.dog" "control_effort=xhigh" "treat_effort=high" "treat_pct=${1:-50}"; }
EXPECT_PLAIN="$(env -i PATH="$PATH" HOME="$W" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$FAKE" /bin/bash "$WRAPPER" "${std_args[@]}")"

# a session name known (below, once) to land in each arm for salt=t1, pct=50
find_names() {
  [ -n "${TREAT:-}" ] && [ -n "${CTRL:-}" ] && return 0   # computed once with the REAL wrapper; the hash is the same in every mutant
  TREAT=""; CTRL=""; local i out
  good_conf 50
  for i in $(seq 1 40); do
    reset_log; out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="probe$i")"
    if [ "$(arg4 "$out")" = "high" ]; then [ -n "$TREAT" ] || TREAT="probe$i"; else [ -n "$CTRL" ] || CTRL="probe$i"; fi
    [ -n "$TREAT" ] && [ -n "$CTRL" ] && break
  done
}

t_inert_without_conf() {
  noconf; reset_log
  local out; out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME=s1)"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "no conf: argv byte-for-byte, prompt with spaces/quotes/newline intact" || bad "no conf changed argv: $out"
  grep -q 'EFFORT-AB' "$LOG" && bad "no conf logged an EFFORT-AB line (inert means silent)" || ok "no conf: nothing logged"
  good_conf 100; touch "$CITY/.gc/no-effort-ab"
  out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME=s1)"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "kill switch file (.gc/no-effort-ab) beats a 100% conf" || bad "kill-switch file ignored: $out"
  rm -f "$CITY/.gc/no-effort-ab"
  out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME=s1 GC_EFFORT_AB=0)"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "GC_EFFORT_AB=0 beats a 100% conf" || bad "GC_EFFORT_AB=0 ignored: $out"
}

t_arms_and_untouched_rest() {
  find_names
  [ -n "$TREAT" ] && [ -n "$CTRL" ] || { bad "could not find a treat and a control session name in 40 tries"; return; }
  good_conf 50; reset_log
  local out; out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT")"
  [ "$(arg4 "$out")" = "high" ] && ok "treated session: --effort xhigh -> high" || bad "treated session not rewritten: $out"
  [ "$(printf '%s' "$out" | sed 's/^arg4=\[high\]/arg4=[xhigh]/')" = "$EXPECT_PLAIN" ] && ok "treated session: every OTHER arg identical and in order (incl. prompt)" || bad "treated rewrite touched more than the effort value"
  grep -q "EFFORT-AB arm=treat template=wa-worker session=$TREAT uuid=U-1 effort=xhigh->high" "$LOG" && ok "treated launch logged with the claude --session-id (join key for the transcript)" || bad "no/incorrect treat log: $(cat "$LOG")"
  reset_log; out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$CTRL")"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "control session: argv byte-for-byte" || bad "control session changed: $out"
  grep -q "EFFORT-AB arm=control .*session=$CTRL .*uuid=U-1" "$LOG" && ok "control launch logged too (compliance needs both arms)" || bad "no control log: $(cat "$LOG")"
  # the same name always lands in the same arm (a resumed/relaunched session keeps its arm)
  local a1 a2; a1="$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT")")"; a2="$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT")")"
  [ "$a1" = "$a2" ] && ok "deterministic per session name" || bad "same name, different arm"
}

t_enrollment_scope() {
  find_names; good_conf 100; reset_log
  local out
  out="$(argv_of GC_TEMPLATE=gate-reviewer GC_SESSION_NAME="$TREAT")"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "template not enrolled (gate-reviewer): untouched even at 100%" || bad "non-enrolled template rewritten: $out"
  out="$(argv_of GC_AGENT=wa-worker-adhoc-29fdff1496 GC_SESSION_NAME="$TREAT")"
  [ "$(arg4 "$out")" = "high" ] && ok "enrolment also matches the GC_AGENT prefix (wa-worker-adhoc-*)" || bad "GC_AGENT prefix not matched: $out"
  out="$(argv_of GC_AGENT=wa-workers-x GC_SESSION_NAME="$TREAT")"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "prefix match is on a name boundary (wa-workers-x is NOT wa-worker)" || bad "over-matching prefix: $out"
  out="$(run GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT" -- --model sonnet --effort high --session-id U-1 "$PROMPT")"
  [ "$(arg4 "$out")" = "high" ] && grep -q 'EFFORT-AB SKIP .*launched with effort=high, not control xhigh' "$LOG" && ok "a role launched on another effort on purpose is never touched (logged SKIP)" || bad "non-control effort handled wrong: $out"
  out="$(run GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT" -- --model --effort=xhigh --session-id U-1 "$PROMPT")"
  [ "$(printf '%s\n' "$out" | sed -n 's/^arg2=\[\(.*\)\]$/\1/p')" = "--effort=high" ] && ok "combined --effort=VALUE form is rewritten too" || bad "--effort=VALUE not handled: $out"
}

t_split_extremes() {
  good_conf 0; local i n=0
  for i in 1 2 3 4 5 6; do [ "$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="z$i")")" = "high" ] && n=$((n+1)); done
  [ "$n" -eq 0 ] && ok "treat_pct=0: no session treated (6/6 control)" || bad "treat_pct=0 treated $n"
  good_conf 100; n=0
  for i in 1 2 3 4 5 6; do [ "$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="z$i")")" = "high" ] && n=$((n+1)); done
  [ "$n" -eq 6 ] && ok "treat_pct=100: every enrolled session treated (6/6)" || bad "treat_pct=100 treated only $n/6"
}

t_split_uniform() {
  good_conf 50; local i n=0
  for i in $(seq 1 40); do [ "$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="dog-g$i")")" = "high" ] && n=$((n+1)); done
  [ "$n" -ge 10 ] && [ "$n" -le 30 ] && ok "treat_pct=50 over 40 session names: $n treated (uniform within sampling noise)" || bad "split not uniform: $n/40 treated"
  local diff=0 a b
  for i in $(seq 1 16); do
    good_conf 50; a="$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="dog-g$i")")"
    conf "salt=other-salt" "enroll=wa-worker" "control_effort=xhigh" "treat_effort=high" "treat_pct=50"; b="$(arg4 "$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="dog-g$i")")"
    [ "$a" != "$b" ] && diff=$((diff+1))
  done
  [ "$diff" -ge 3 ] && ok "a new salt reshuffles the split ($diff/16 sessions changed arm) — a new experiment is not the old one" || bad "salt does not reshuffle ($diff/16 changed)"
}

t_fail_open() {
  find_names; local out
  conf "salt=t1" "enroll=wa-worker" "control_effort=xhigh" "treat_effort=high; touch $W/pwned" "treat_pct=50"; reset_log
  out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT")"
  [ "$out" = "$EXPECT_PLAIN" ] && ok "conf value with shell metacharacters: ignored, argv untouched" || bad "hostile conf value changed argv: $out"
  [ ! -e "$W/pwned" ] && ok "conf values are never executed" || bad "conf value was EXECUTED"
  grep -q 'EFFORT-AB WARN conf .* ignored' "$LOG" && ok "bad conf is a visible WARN, not silence" || bad "no WARN for bad conf"
  local c
  for c in "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=turbo|treat_pct=50" "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=high|treat_pct=150" \
           "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=high|treat_pct=abc" "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=high|nonsense=1|treat_pct=50" \
           "enroll=wa-worker|control_effort=xhigh|treat_effort=high|treat_pct=50" "garbage without equals"; do
    reset_log
    printf '%s\n' "$c" | tr '|' '\n' > "$CITY/.gc/effort-ab.conf"
    out="$(argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT")"
    [ "$out" = "$EXPECT_PLAIN" ] && grep -q 'EFFORT-AB WARN' "$LOG" && ok "invalid conf [$c]: argv untouched + WARN" || bad "invalid conf [$c] not fail-open: $out | $(cat "$LOG")"
  done
  good_conf 100; reset_log
  out="$(run GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT" -- --model sonnet --session-id U-1 "$PROMPT")"
  [ "$(printf '%s' "$out" | grep -c 'effort')" -eq 0 ] && grep -q 'EFFORT-AB WARN .*without --effort' "$LOG" && ok "no --effort in argv: left alone + WARN (nothing invented)" || bad "no --effort case: $out"
  reset_log; out="$(argv_of GC_TEMPLATE=wa-worker)"
  [ "$out" = "$EXPECT_PLAIN" ] && grep -q 'EFFORT-AB WARN .*no GC_SESSION_NAME' "$LOG" && ok "no GC_SESSION_NAME: left alone + WARN" || bad "no session name case: $out"
  mkdir -p "$W/nobin"; ln -sf "$(command -v date)" "$W/nobin/date"; reset_log
  out="$(SHIM_PATH="$W/nobin" argv_of GC_TEMPLATE=wa-worker GC_SESSION_NAME="$TREAT")"
  [ "$out" = "$EXPECT_PLAIN" ] && grep -q 'EFFORT-AB WARN .*shasum failed' "$LOG" && ok "shasum missing: claude STILL launches, argv untouched, WARN" || bad "missing shasum not fail-open: $out | $(cat "$LOG")"
}

# ---- mutation controls: each mutant of the wrapper must be rejected by at least one check ----------------
mutant() { # name, sed-script, case-function. A subshell inherits the functions/vars; only WRAPPER is swapped.
  local name="$1" script="$2" fn="$3" m="$W/mutant-$RANDOM.sh" nfail
  sed "$script" "$WRAPPER" > "$m"
  if cmp -s "$m" "$WRAPPER"; then bad "mutant '$name': the sed did not change the wrapper — the control is blind"; return; fi
  nfail="$( WRAPPER="$m"; PASS=0; FAIL=0; "$fn" >/dev/null 2>&1; echo "$FAIL" )"
  if [ "$nfail" != "0" ]; then ok "mutant '$name' rejected ($nfail check(s) failed against it)"; else bad "mutant '$name' SURVIVED (every check passed against the broken wrapper)"; fi
}

find_names
echo "== inert by default"; t_inert_without_conf
echo "== arms, and only the effort value moves"; t_arms_and_untouched_rest
echo "== enrolment scope"; t_enrollment_scope
echo "== split properties"; t_split_extremes; t_split_uniform
echo "== fail-open"; t_fail_open
echo "== mutation controls"
mutant "treat decision inverted"              's/-lt "\$ab_pct"/-ge "$ab_pct"/'                                  t_split_extremes
mutant "control-effort guard removed"         's/if \[ "\$ab_cur" != "\$ab_ctl" \]; then/if false; then/'        t_enrollment_scope
mutant "rewrites the wrong argv slot"         's/argv\[\$((ab_idx + 1))\]="\$ab_trt"/argv[$((ab_idx + 2))]="$ab_trt"/' t_arms_and_untouched_rest
mutant "exec ignores the rewritten argv"      's/exec "\$claude_bin" \${argv\[@\]+"\${argv\[@\]}"}/exec "$claude_bin" "$@"/' t_arms_and_untouched_rest
mutant "bad conf no longer fail-open"         's/if \[ -n "\$ab_bad" \]; then/if false; then/'                  t_fail_open
mutant "kill switch file ignored"             's/ \&\& \[ ! -e "\$city\/.gc\/no-effort-ab" \]//'                  t_inert_without_conf
echo; echo "$PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
