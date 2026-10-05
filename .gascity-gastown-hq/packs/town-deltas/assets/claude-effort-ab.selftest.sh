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
# Plus the properties the experiment stands on: the unit of randomization is the claude SESSION (its own uuid —
# NOT the session name, which can repeat: a pool slot like gastown.dog-1 must still split ~50/50 across launches),
# the split is deterministic per uuid (a --resume keeps its arm), roughly uniform, and honours treat_pct 0 / 100
# exactly.
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
# a claude session uuid (8-4-4-4-12 hex); uuid_n N is a distinct, valid one per N
uuid_n() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }
U0="$(uuid_n 0)"

# run_wb <wrapper> <env assignments...> -- <claude args...>: scrubbed env, GC_LOWPRIO=0 (no renice noise)
run_with() {
  local wrapper="$1"; shift; local envs=() a
  while [ "$#" -gt 0 ]; do a="$1"; shift; [ "$a" = "--" ] && break; envs+=("$a"); done
  env -i PATH="${SHIM_PATH:-$PATH}" HOME="$W" GC_CITY_PATH="$CITY" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$FAKE" ${envs[@]+"${envs[@]}"} /bin/bash "$wrapper" "$@"
}
run() { run_with "$WRAPPER" "$@"; }
std_args=(--model sonnet --effort xhigh --session-id "$U0" "$PROMPT")
argv_of() { run "$@" -- "${std_args[@]}"; }
# argv_u <uuid> <env...>: the standard launch, with THIS claude session uuid
argv_u() { local u="$1"; shift; run "$@" -- --model sonnet --effort xhigh --session-id "$u" "$PROMPT"; }
plain_u() { env -i PATH="$PATH" HOME="$W" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$FAKE" /bin/bash "$WRAPPER" --model sonnet --effort xhigh --session-id "$1" "$PROMPT"; }
arg4() { printf '%s\n' "$1" | sed -n 's/^arg4=\[\(.*\)\]$/\1/p'; }
arm_of() { [ "$(arg4 "$1")" = "high" ] && echo treat || echo control; }
conf() { printf '%s\n' "$@" > "$CITY/.gc/effort-ab.conf"; }
noconf() { rm -f "$CITY/.gc/effort-ab.conf" "$CITY/.gc/no-effort-ab"; }
reset_log() { : > "$LOG"; }
good_conf() { conf "salt=t1" "enroll=wa-worker gastown.dog" "control_effort=xhigh" "treat_effort=high" "treat_pct=${1:-50}"; }
EXPECT_PLAIN="$(env -i PATH="$PATH" HOME="$W" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$FAKE" /bin/bash "$WRAPPER" "${std_args[@]}")"

# a session uuid known (below, once) to land in each arm for salt=t1, pct=50
find_uuids() {
  [ -n "${TREAT_U:-}" ] && [ -n "${CTRL_U:-}" ] && return 0   # computed once with the REAL wrapper
  TREAT_U=""; CTRL_U=""; local i out
  good_conf 50
  for i in $(seq 1 40); do
    reset_log; out="$(argv_u "$(uuid_n "$i")" GC_TEMPLATE=wa-worker GC_SESSION_NAME="probe$i")"
    if [ "$(arg4 "$out")" = "high" ]; then [ -n "$TREAT_U" ] || TREAT_U="$(uuid_n "$i")"; else [ -n "$CTRL_U" ] || CTRL_U="$(uuid_n "$i")"; fi
    [ -n "$TREAT_U" ] && [ -n "$CTRL_U" ] && break
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
  find_uuids
  [ -n "$TREAT_U" ] && [ -n "$CTRL_U" ] || { bad "could not find a treat and a control session uuid in 40 tries"; return; }
  good_conf 50; reset_log
  local out; out="$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker GC_SESSION_NAME=dog-gtreat1)"
  [ "$(arg4 "$out")" = "high" ] && ok "treated session: --effort xhigh -> high" || bad "treated session not rewritten: $out"
  [ "$(printf '%s' "$out" | sed 's/^arg4=\[high\]/arg4=[xhigh]/')" = "$(plain_u "$TREAT_U")" ] && ok "treated session: every OTHER arg identical and in order (incl. prompt)" || bad "treated rewrite touched more than the effort value"
  grep -q "EFFORT-AB arm=treat template=wa-worker session=dog-gtreat1 uuid=$TREAT_U effort=xhigh->high" "$LOG" && ok "treated launch logged with the claude --session-id (join key for the transcript)" || bad "no/incorrect treat log: $(cat "$LOG")"
  reset_log; out="$(argv_u "$CTRL_U" GC_TEMPLATE=wa-worker GC_SESSION_NAME=dog-gctrl1)"
  [ "$out" = "$(plain_u "$CTRL_U")" ] && ok "control session: argv byte-for-byte" || bad "control session changed: $out"
  grep -q "EFFORT-AB arm=control .*session=dog-gctrl1 .*uuid=$CTRL_U" "$LOG" && ok "control launch logged too (compliance needs both arms)" || bad "no control log: $(cat "$LOG")"
  # the same session uuid always lands in the same arm
  local a1 a2; a1="$(arg4 "$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)")"; a2="$(arg4 "$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)")"
  [ "$a1" = "$a2" ] && ok "deterministic per session uuid" || bad "same uuid, different arm"
}

# The property the experiment stands on (gate attempt 3, ga-5c3msy): the arm is drawn per claude SESSION, never per session NAME.
# A pool slot name (gastown.dog-1 ...) repeats across launches; if it were the hash input the slot would be the unit — a few
# clusters, each stuck in one arm for good — and every launch would still log a clean arm=. Split in small cases so each mutant
# re-runs only the few launches that can kill it (every launch forks the wrapper, shasum and a fake claude; the box is loaded).
t_unit_sampling() {   # launches that ALL carry the same slot name: both arms must occur, ~50/50
  good_conf 50; local i n=0 treat_seen="" ctrl_seen="" out
  for i in $(seq 1 24); do
    out="$(argv_u "$(uuid_n $((100 + i)))" GC_TEMPLATE=gastown.dog GC_AGENT=gastown.dog-1 GC_SESSION_NAME=gastown.dog-1)"
    if [ "$(arm_of "$out")" = treat ]; then n=$((n+1)); treat_seen=1; else ctrl_seen=1; fi
  done
  [ -n "$treat_seen" ] && [ -n "$ctrl_seen" ] && ok "24 launches under ONE repeating name (gastown.dog-1): both arms occur ($n treated)" || bad "one repeating name pins every launch to one arm ($n/24 treated) — the slot, not the session, is the unit"
  [ "$n" -ge 6 ] && [ "$n" -le 18 ] && ok "...and the split under that single name is ~50/50 ($n/24 treated)" || bad "split under a repeating name is not ~50/50: $n/24"
}

t_unit_name_independent() {   # the name is logged, never hashed: same uuid, any name (or none), same arm
  find_uuids; good_conf 50
  local u nm same=1 a_first a_other
  for u in "$TREAT_U" "$CTRL_U"; do
    a_first="$(arm_of "$(argv_u "$u" GC_TEMPLATE=wa-worker GC_SESSION_NAME=name-one)")"
    for nm in gastown.dog-9 ""; do
      a_other="$(arm_of "$(argv_u "$u" GC_TEMPLATE=wa-worker GC_SESSION_NAME="$nm")")"
      [ "$a_other" = "$a_first" ] || same=0
    done
  done
  [ "$same" = 1 ] && ok "the same session uuid keeps its arm under any (or no) GC_SESSION_NAME — the name is logged, never hashed" || bad "the arm changed with the session name"
}

t_unit_resume() {   # a resumed session is the SAME session: it keeps the arm its launch had
  find_uuids; good_conf 50
  local u want got
  for u in "$TREAT_U" "$CTRL_U"; do
    want="$(arm_of "$(argv_u "$u" GC_TEMPLATE=wa-worker)")"
    got="$(arm_of "$(run GC_TEMPLATE=wa-worker -- --model sonnet --effort xhigh --resume "$u" "$PROMPT")")"
    [ "$got" = "$want" ] || { bad "--resume $u changed the arm ($want -> $got)"; return; }
  done
  want="$(arm_of "$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)")"
  got="$(arm_of "$(run GC_TEMPLATE=wa-worker -- --model sonnet --effort xhigh --session-id="$TREAT_U" "$PROMPT")")"
  [ "$got" = "$want" ] || { bad "--session-id=<uuid> changed the arm ($want -> $got)"; return; }
  got="$(arm_of "$(run GC_TEMPLATE=wa-worker -- --model sonnet --effort xhigh --resume="$TREAT_U" "$PROMPT")")"
  [ "$got" = "$want" ] || { bad "--resume=<uuid> changed the arm ($want -> $got)"; return; }
  ok "--resume <uuid>, --resume=<uuid> and --session-id=<uuid> land in the arm the original launch had"
}

t_unit_no_identity() {   # no usable session identity -> no draw. A name cannot stand in for it (that IS the confound); the value is never echoed
  good_conf 100; local bogus out
  for bogus in "U-1" "" "ZZZZZZZZ-0000-4000-8000-000000000000" "$(printf -- '-%.0s' $(seq 1 36))" "$PROMPT"; do
    reset_log
    out="$(run GC_TEMPLATE=wa-worker GC_SESSION_NAME=slot-1 -- --model sonnet --effort xhigh --session-id "$bogus" "$PROMPT")"
    [ "$(arg4 "$out")" = "xhigh" ] && grep -q 'EFFORT-AB WARN .*no usable --session-id/--resume uuid' "$LOG" && [ "$(grep -c 'EFFORT-AB' "$LOG")" -eq 1 ] && { [ -z "$bogus" ] || ! grep -q -F -e "$bogus" "$LOG"; } \
      && ok "session id [${bogus:0:16}] is not a uuid: left alone at 100%, ONE WARN line, the value is not echoed" || bad "bogus session id [${bogus:0:16}] was drawn on, not reported, or echoed: $(arg4 "$out") | $(cat "$LOG")"
  done
  reset_log; out="$(run GC_TEMPLATE=wa-worker GC_SESSION_NAME=slot-1 -- --model sonnet --effort xhigh "$PROMPT")"
  [ "$(arg4 "$out")" = "xhigh" ] && grep -q 'EFFORT-AB WARN .*no usable --session-id/--resume uuid' "$LOG" && ok "no --session-id at all: left alone + WARN (a name is never a stand-in)" || bad "launch without a session id: $(arg4 "$out") | $(cat "$LOG")"
  reset_log; out="$(run GC_TEMPLATE=wa-worker GC_SESSION_NAME=slot-1 -- --model sonnet --effort xhigh --resume)"
  [ "$(arg4 "$out")" = "xhigh" ] && grep -q 'EFFORT-AB WARN .*no usable' "$LOG" && ok "a trailing --resume with no value: left alone + WARN (no unbound-variable abort)" || bad "dangling --resume: $out | $(cat "$LOG")"
  reset_log; out="$(argv_u "$(uuid_n 3735928559 | tr a-f A-F)" GC_TEMPLATE=wa-worker)"
  grep -q 'EFFORT-AB arm=' "$LOG" && ok "an uppercase hex uuid is still a uuid" || bad "uppercase uuid rejected: $(cat "$LOG")"
}

t_enrollment_scope() {
  find_uuids; good_conf 100; reset_log
  local out
  out="$(argv_u "$TREAT_U" GC_TEMPLATE=gate-reviewer)"
  [ "$out" = "$(plain_u "$TREAT_U")" ] && ok "template not enrolled (gate-reviewer): untouched even at 100%" || bad "non-enrolled template rewritten: $out"
  out="$(argv_u "$TREAT_U" GC_AGENT=wa-worker-adhoc-29fdff1496)"
  [ "$(arg4 "$out")" = "high" ] && ok "enrolment also matches the GC_AGENT prefix (wa-worker-adhoc-*)" || bad "GC_AGENT prefix not matched: $out"
  out="$(argv_u "$TREAT_U" GC_AGENT=wa-workers-x)"
  [ "$out" = "$(plain_u "$TREAT_U")" ] && ok "prefix match is on a name boundary (wa-workers-x is NOT wa-worker)" || bad "over-matching prefix: $out"
  out="$(run GC_TEMPLATE=wa-worker -- --model sonnet --effort high --session-id "$TREAT_U" "$PROMPT")"
  [ "$(arg4 "$out")" = "high" ] && grep -q 'EFFORT-AB SKIP .*launched with effort=high, not control xhigh' "$LOG" && ok "a role launched on another effort on purpose is never touched (logged SKIP)" || bad "non-control effort handled wrong: $out"
  out="$(run GC_TEMPLATE=wa-worker -- --model --effort=xhigh --session-id "$TREAT_U" "$PROMPT")"
  [ "$(printf '%s\n' "$out" | sed -n 's/^arg2=\[\(.*\)\]$/\1/p')" = "--effort=high" ] && ok "combined --effort=VALUE form is rewritten too" || bad "--effort=VALUE not handled: $out"
}

t_split_extremes() {
  good_conf 0; local i n=0
  for i in 1 2 3 4 5 6; do [ "$(arg4 "$(argv_u "$(uuid_n $((200 + i)))" GC_TEMPLATE=wa-worker)")" = "high" ] && n=$((n+1)); done
  [ "$n" -eq 0 ] && ok "treat_pct=0: no session treated (6/6 control)" || bad "treat_pct=0 treated $n"
  good_conf 100; n=0
  for i in 1 2 3 4 5 6; do [ "$(arg4 "$(argv_u "$(uuid_n $((200 + i)))" GC_TEMPLATE=wa-worker)")" = "high" ] && n=$((n+1)); done
  [ "$n" -eq 6 ] && ok "treat_pct=100: every enrolled session treated (6/6)" || bad "treat_pct=100 treated only $n/6"
}

t_split_uniform() {   # the uniformity itself is t_unit_sampling; this is the salt
  local i diff=0 a b
  for i in $(seq 1 12); do
    good_conf 50; a="$(arg4 "$(argv_u "$(uuid_n $((300 + i)))" GC_TEMPLATE=wa-worker)")"
    conf "salt=other-salt" "enroll=wa-worker" "control_effort=xhigh" "treat_effort=high" "treat_pct=50"; b="$(arg4 "$(argv_u "$(uuid_n $((300 + i)))" GC_TEMPLATE=wa-worker)")"
    [ "$a" != "$b" ] && diff=$((diff+1))
  done
  [ "$diff" -ge 2 ] && ok "a new salt reshuffles the split ($diff/12 sessions changed arm) — a new experiment is not the old one" || bad "salt does not reshuffle ($diff/12 changed)"
}

t_fail_open() {
  find_uuids; local out
  conf "salt=t1" "enroll=wa-worker" "control_effort=xhigh" "treat_effort=high; touch $W/pwned" "treat_pct=50"; reset_log
  out="$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)"
  [ "$out" = "$(plain_u "$TREAT_U")" ] && ok "conf value with shell metacharacters: ignored, argv untouched" || bad "hostile conf value changed argv: $out"
  [ ! -e "$W/pwned" ] && ok "conf values are never executed" || bad "conf value was EXECUTED"
  grep -q 'EFFORT-AB WARN conf .* ignored' "$LOG" && ok "bad conf is a visible WARN, not silence" || bad "no WARN for bad conf"
  local c
  for c in "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=turbo|treat_pct=50" "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=high|treat_pct=150" \
           "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=high|treat_pct=abc" "salt=t1|enroll=wa-worker|control_effort=xhigh|treat_effort=high|nonsense=1|treat_pct=50" \
           "enroll=wa-worker|control_effort=xhigh|treat_effort=high|treat_pct=50" "garbage without equals"; do
    reset_log
    printf '%s\n' "$c" | tr '|' '\n' > "$CITY/.gc/effort-ab.conf"
    out="$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)"
    [ "$out" = "$(plain_u "$TREAT_U")" ] && grep -q 'EFFORT-AB WARN' "$LOG" && ok "invalid conf [$c]: argv untouched + WARN" || bad "invalid conf [$c] not fail-open: $out | $(cat "$LOG")"
  done
  good_conf 100; reset_log
  out="$(run GC_TEMPLATE=wa-worker -- --model sonnet --session-id "$TREAT_U" "$PROMPT")"
  [ "$(printf '%s' "$out" | grep -c 'effort')" -eq 0 ] && grep -q 'EFFORT-AB WARN .*without --effort' "$LOG" && ok "no --effort in argv: left alone + WARN (nothing invented)" || bad "no --effort case: $out"
  # the session NAME is logged, not hashed: a launch without GC_SESSION_NAME but with a uuid is still decided (session=? in the log)
  reset_log; out="$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)"
  [ "$(arg4 "$out")" = "high" ] && grep -q "EFFORT-AB arm=treat template=wa-worker session=? uuid=$TREAT_U" "$LOG" && ok "no GC_SESSION_NAME: the draw does not need it (logged session=?)" || bad "no session name case: $out | $(cat "$LOG")"
  mkdir -p "$W/nobin"; ln -sf "$(command -v date)" "$W/nobin/date"; reset_log
  out="$(SHIM_PATH="$W/nobin" argv_u "$TREAT_U" GC_TEMPLATE=wa-worker)"
  [ "$out" = "$(plain_u "$TREAT_U")" ] && grep -q 'EFFORT-AB WARN .*shasum failed' "$LOG" && ok "shasum missing: claude STILL launches, argv untouched, WARN" || bad "missing shasum not fail-open: $out | $(cat "$LOG")"
}

# gate (attempt 5): a treat_pct with >= 19 digits is a number bash's `[ -gt ]` cannot compare (rc 2 + "integer expression expected" on the
# agent's stderr), so the `&&` that sets ab_bad never fired: the conf was ACCEPTED and every launch logged a clean `arm=control pct=999...`
# instead of the WARN a bad conf promises. A bad conf must be the visible WARN, and nothing leaks to stderr.
t_pct_digits() {
  find_uuids; local out p
  for p in 99999999999999999999 0000000000000000001 1000; do
    conf "salt=t1" "enroll=wa-worker" "control_effort=xhigh" "treat_effort=high" "treat_pct=$p"; reset_log
    out="$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker 2>"$W/pct.err")"
    if [ "$out" = "$(plain_u "$TREAT_U")" ] && grep -q 'EFFORT-AB WARN conf .* ignored' "$LOG" && ! grep -q 'arm=' "$LOG" && ! grep -q 'integer expression' "$W/pct.err"; then
      ok "treat_pct=$p (${#p} digits): ignored with the WARN, no draw logged, stderr clean"
    else bad "treat_pct=$p (${#p} digits) not rejected cleanly: argv=[$(printf '%s' "$out" | tr '\n' ' ')] log=[$(cat "$LOG")] stderr=[$(cat "$W/pct.err")]"; fi
  done
  # controls: the cap must not reject a valid value — 3 digits (zero-padded too) are decided as before
  for p in 050 100; do
    conf "salt=t1" "enroll=wa-worker" "control_effort=xhigh" "treat_effort=high" "treat_pct=$p"; reset_log
    out="$(argv_u "$TREAT_U" GC_TEMPLATE=wa-worker 2>"$W/pct.err")"
    [ "$(arg4 "$out")" = "high" ] && grep -q "EFFORT-AB arm=treat" "$LOG" && ! grep -q 'EFFORT-AB WARN' "$LOG" && [ ! -s "$W/pct.err" ] \
      && ok "treat_pct=$p is still accepted and decided" || bad "treat_pct=$p wrongly rejected: $out | $(cat "$LOG") | $(cat "$W/pct.err")"
  done
}

# ---- mutation controls: each mutant of the wrapper must be rejected by at least one check ----------------
mutant() { # name, sed-script, case-function. A subshell inherits the functions/vars; only WRAPPER is swapped.
  local name="$1" script="$2" fn="$3" m="$W/mutant-$RANDOM.sh" nfail
  sed "$script" "$WRAPPER" > "$m"
  if cmp -s "$m" "$WRAPPER"; then bad "mutant '$name': the sed did not change the wrapper — the control is blind"; return; fi
  nfail="$( WRAPPER="$m"; PASS=0; FAIL=0; "$fn" >/dev/null 2>&1; echo "$FAIL" )"
  if [ "$nfail" != "0" ]; then ok "mutant '$name' rejected ($nfail check(s) failed against it)"; else bad "mutant '$name' SURVIVED (every check passed against the broken wrapper)"; fi
}

find_uuids
echo "== inert by default"; t_inert_without_conf
echo "== arms, and only the effort value moves"; t_arms_and_untouched_rest
echo "== the unit of randomization is the session (uuid), not the (repeating) session name"; t_unit_sampling; t_unit_name_independent; t_unit_resume; t_unit_no_identity
echo "== enrolment scope"; t_enrollment_scope
echo "== split properties"; t_split_extremes; t_split_uniform
echo "== fail-open"; t_fail_open
echo "== treat_pct: the digit cap (bash cannot compare a 19+ digit number)"; t_pct_digits
echo "== mutation controls"
mutant "treat decision inverted"              's/-lt "\$ab_pct"/-ge "$ab_pct"/'                                  t_split_extremes
mutant "control-effort guard removed"         's/if \[ "\$ab_cur" != "\$ab_ctl" \]; then/if false; then/'        t_enrollment_scope
mutant "rewrites the wrong argv slot"         's/argv\[\$((ab_idx + 1))\]="\$ab_trt"/argv[$((ab_idx + 2))]="$ab_trt"/' t_arms_and_untouched_rest
mutant "exec ignores the rewritten argv"      's/exec "\$claude_bin" \${argv\[@\]+"\${argv\[@\]}"}/exec "$claude_bin" "$@"/' t_arms_and_untouched_rest
mutant "bad conf no longer fail-open"         's/if \[ -n "\$ab_bad" \]; then/if false; then/'                  t_fail_open
mutant "kill switch file ignored"             's/ \&\& \[ ! -e "\$city\/.gc\/no-effort-ab" \]//'                  t_inert_without_conf
# gate attempt 3: the draw must be per SESSION (uuid), not per session NAME
mutant "arm hashes the session NAME (slot = unit): sampling"  's/effort-ab:\$ab_salt:\$ab_uuid/effort-ab:$ab_salt:$ab_sn/'            t_unit_sampling
mutant "arm hashes the session NAME (slot = unit): identity"  's/effort-ab:\$ab_salt:\$ab_uuid/effort-ab:$ab_salt:$ab_sn/'            t_unit_name_independent
mutant "arm hashes name AND uuid (a rename moves it)"         's/effort-ab:\$ab_salt:\$ab_uuid/effort-ab:$ab_salt:$ab_sn:$ab_uuid/' t_unit_name_independent
mutant "uuid shape not validated"                             's/elif ! is_uuid "\$ab_uuid"; then/elif false; then/'                          t_unit_no_identity
mutant "--resume ignored"                                     's/--session-id|--resume) ab_uuid=/--session-id) ab_uuid=/'                       t_unit_resume
mutant "--session-id= form ignored"                           's/--session-id=\*) ab_uuid=.*;;/--session-id=*) ;;/'                            t_unit_resume
mutant "bogus session id echoed to the log"                   's/(value of \${#ab_uuid} chars)/(value [$ab_uuid])/'                              t_unit_no_identity
mutant "treat_pct digit cap removed (19+ digits accepted)"      's/\[ "\${#ab_pct}" -gt 3 \] || //'                                          t_pct_digits
echo; echo "$PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
