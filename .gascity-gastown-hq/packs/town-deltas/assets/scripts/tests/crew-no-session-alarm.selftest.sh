#!/usr/bin/env bash
# crew-no-session-alarm.selftest.sh — ga-4ytmas (item 3).
# Runs the REAL crew-no-session-alarm.sh (not a reimplementation) against a fake `gc`, under /bin/bash (macOS
# 3.2 — the shell the gate parses with) unless CREW_ALARM_BASH says otherwise.
#
# Design (same as pool-stuck-prompt-alarm's selftest): ONE baseline fixture the alarm must mail about — the
# 10/10 incident itself: oracle-wa, min_active_sessions = 1, with no session at all for 11 min — then one
# scenario per condition that differs from the baseline in EXACTLY that condition and must NOT mail. Then the
# dedupe timeline, the failure paths, the valves.
#
# "A selftest must fail against the pre-fix state": section X builds MUTANTS of the script (one load-bearing
# line broken each) and requires the matching scenario to FAIL on the mutant. A mutant that survives means the
# scenario is decorative. A mutation whose text no longer occurs in the script is itself a failure (the script
# moved and the proof went stale).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CREW_ALARM_SCRIPT:-$SELF_DIR/../crew-no-session-alarm.sh}"
MODEL="${CREW_ALARM_MODEL_SCRIPT:-$SELF_DIR/../pool-stuck-prompt-alarm.sh}"
ORDER="${CREW_ALARM_ORDER:-$SELF_DIR/../../../orders/crew-no-session-alarm.toml}"
if [ -n "${CREW_ALARM_BASH:-}" ]; then BASH_RUN="$CREW_ALARM_BASH"; elif [ -x /bin/bash ]; then BASH_RUN=/bin/bash; else BASH_RUN=bash; fi

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$SCRIPT" ] || { echo "FATAL: alarm script not found at $SCRIPT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH"; exit 1; }
python3 -c 'import tomllib' 2>/dev/null || { echo "FATAL: python3 has no tomllib (3.11+) — the alarm needs it too"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FATAL: flock not on PATH (the alarm needs it too)"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "FATAL: timeout not on PATH (the alarm needs it too)"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/crew-alarm-selftest.XXXXXX")"
# one scenario makes the state dir read-only: always give write access back before the cleanup
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
NOW0=1800000000
mkdir -p "$T/fake" "$T/mut"
SCRIPT_UNDER_TEST="$SCRIPT"
SD="$T/state/crew-no-session"                          # where the alarm keeps one file per crew

# ---- fakes ---------------------------------------------------------------------------------------------
cat > "$T/fake/gc" <<'EOF'
#!/usr/bin/env bash
# fake gc: driven by files under $FAKE_DIR; every call that matters is appended to $FAKE_CALLS.
# `mail send <to> -s <subject> -m <body>` is recorded in mail.<n>.{to,subject,body} (only if it "succeeds").
# Anything but config show / session list / mail send is a DETECTION-ONLY violation: recorded as "other", and
# the selftest fails on it. FAKE_*_FAIL make the call exit non-zero AFTER printing a valid-looking answer, so only
# the exit status can tell the script it must not trust it.
case "$1 $2" in
  "config show")  echo "cfg" >> "$FAKE_CALLS"
                  if [ -f "$FAKE_DIR/config.raw" ]; then cat "$FAKE_DIR/config.raw"; else cat "$FAKE_DIR/config.toml"; fi
                  [ -n "${FAKE_CFG_FAIL:-}" ] && exit "${FAKE_CFG_FAIL}"; exit 0 ;;
  "session list") echo "list $3" >> "$FAKE_CALLS"
                  if [ -f "$FAKE_DIR/sessions.raw" ]; then cat "$FAKE_DIR/sessions.raw"; else cat "$FAKE_DIR/sessions.json"; fi
                  [ -n "${FAKE_LIST_FAIL:-}" ] && exit "${FAKE_LIST_FAIL}"; exit 0 ;;
  "mail send")    echo "mailtry $3" >> "$FAKE_CALLS"
                  [ -n "${FAKE_MAIL_FAIL:-}" ] && exit 1
                  [ -n "${FAKE_MAIL_TIMEOUT:-}" ] && exit 124      # timeout(1) killed it: it may or may not have been written
                  n="$(ls "$FAKE_DIR"/mail.*.to 2>/dev/null | wc -l | tr -d ' ')"; i=$((n + 1))
                  echo "mail $3" >> "$FAKE_CALLS"
                  printf '%s' "$3" > "$FAKE_DIR/mail.$i.to"; printf '%s' "$5" > "$FAKE_DIR/mail.$i.subject"; printf '%s' "$7" > "$FAKE_DIR/mail.$i.body"
                  exit 0 ;;
  *) echo "other $*" >> "$FAKE_CALLS"; exit 2 ;;
esac
EOF
chmod +x "$T/fake/gc"

# ---- fixture builders ----------------------------------------------------------------------------------
# cfg_base: a resolved config like the real one — one crew with the always-on floor (oracle-wa), crews with
# floor 0 that live as hand-started sessions (digo-wa), a suspended one (mila-wa), and the always-mode named
# sessions that sit `asleep` by design.
cfg_base() {
  cat > "$T/fake/config.toml" <<'TOML'
[workspace]
name = "gastown-hq"

[[agent]]
name = "oracle-wa"
provider = "claude-rc-crew"
max_active_sessions = 1
min_active_sessions = 1

[[agent]]
name = "digo-wa"
provider = "claude-rc-crew"
max_active_sessions = 1
min_active_sessions = 0

[[agent]]
name = "mila-wa"
suspended = true
max_active_sessions = 1
min_active_sessions = 0

[[named_session]]
template = "witness"
scope = "rig"
dir = "gastown"
mode = "always"

[[rigs]]
name = "gastown"
path = "/x/gastown"

[[rigs]]
name = "lexbh"
path = "/x/lexbh"
suspended = true
TOML
}
# cfg_agent <name> [dir] [min=1] [suspended=false]    (appends an [[agent]] to the base config)
cfg_agent() {
  { printf '\n[[agent]]\nname = "%s"\n' "$1"
    [ -n "${2:-}" ] && printf 'dir = "%s"\n' "$2"
    printf 'min_active_sessions = %s\nmax_active_sessions = 1\n' "${3:-1}"
    [ "${4:-false}" = true ] && printf 'suspended = true\n'
    true; } >> "$T/fake/config.toml"
}
reset() {
  find "$T/fake" -maxdepth 1 \( -name 'sessions.*' -o -name 'config.raw' -o -name 'mail.*' \) -delete
  chmod -R u+w "$T/state" 2>/dev/null
  rm -rf "$T/state" "$T/log" "$T/calls" "$T/lock"; : > "$T/calls"; mkdir -p "$T/state"
  cfg_base; SESS_LINES=""
}
# sess <template> [state=active] [closed=false]   (appends one session)
SESS_LINES=""
sess() { SESS_LINES="$SESS_LINES$1|${2:-active}|${3:-false}"$'\n'; }
write_sessions() {
  printf '%s' "$SESS_LINES" | python3 -c '
import sys, json
out = []
for i, line in enumerate(sys.stdin.read().splitlines()):
    t, st, cl = line.split("|")
    out.append({"id": "ga-s-%d" % i, "name": t, "template": t, "state": st, "closed": cl == "true"})
print(json.dumps({"sessions": out}))' > "$T/fake/sessions.json"
}
# run_at <now> [KEY=VAL ...]: one pass of the alarm at fake time <now>; extra args are env for this run only
run_at() {
  local at="$1"; shift
  write_sessions
  env FAKE_DIR="$T/fake" FAKE_CALLS="$T/calls" GC="$T/fake/gc" GC_CITY_PATH="$T/city" \
      CREW_ALARM_STATE_ROOT="$T/state" CREW_ALARM_LOG="$T/log" CREW_ALARM_LOCK="$T/lock" CREW_ALARM_NOW="$at" \
      CREW_ALARM_CALL_TIMEOUT=10 "$@" "$BASH_RUN" "$SCRIPT_UNDER_TEST" > "$T/stdout" 2>&1
  return 0
}
pass1() { run_at "$NOW0" "$@"; }                                   # first sighting: the absence clock starts
pass2() { run_at "$((NOW0 + ${GAP:-700}))" "$@"; }                 # 700 s = 11 min 40 s later, still missing
episode() { pass1 "$@"; pass2 "$@"; }
calls_n() { grep -cE "^$1( |\$)" "$T/calls" 2>/dev/null || true; }
mails() { calls_n mail; }
no_actions() { [ "$(calls_n other)" = 0 ]; }                       # detection only: nothing but config / list / mail
logged() { grep -q -- "$1" "$T/log" "$T/stdout" 2>/dev/null; }
dump() { sed 's/^/        /' "$T/log" "$T/stdout" 2>/dev/null | tail -6; }
# expect <label> <mails> : exactly that many mails, and no other gc call
expect() {
  local m; m="$(mails)"
  if [ "$m" = "$2" ] && no_actions; then ok "$1  (mails=$m)"
  else bad "$1  expected mails=$2 and no other gc call, got mails=$m other=$(calls_n other)"; dump; fi
}
said()   { if logged "$2"; then ok "$1"; else bad "$1  [log lacks: $2]"; dump; fi; }
unsaid() { if logged "$2"; then bad "$1  [log wrongly has: $2]"; dump; else ok "$1"; fi; }
baseline() { reset; }                                              # oracle-wa wanted, no session of any kind
OF="$SD/oracle-wa.state"                                           # the baseline crew's state file
check() { "$2"; case "$?" in 0) ok "$1" ;; 2) ok "$1  (skipped: cannot run as root)" ;; *) bad "$1"; dump ;; esac; }

# ---- W: wiring -------------------------------------------------------------------------------------------
echo "W. wiring"
if [ -x "$SCRIPT" ]; then ok "alarm script is executable"; else bad "alarm script is not executable"; fi
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n ($(bash --version | head -1 | cut -c1-30))"; else bad "bash -n failed"; fi
if [ -x /bin/bash ] && /bin/bash -n "$SCRIPT" 2>/dev/null; then ok "parses under /bin/bash ($(/bin/bash -c 'echo ${BASH_VERSION%%(*}'))"; else bad "does not parse under /bin/bash (macOS 3.2)"; fi
if grep -nE '(declare|local|typeset) +-[aA]|mapfile|readarray|^[[:space:]]*[A-Za-z_]+=\(' "$SCRIPT" | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then bad "script uses arrays/mapfile (bash 3.2-unsafe)"; else ok "no arrays / assoc arrays / mapfile (bash 3.2-safe)"; fi
cat > "$T/order_check.py" <<'PY'
import re, sys, tomllib
o = tomllib.load(open(sys.argv[1], "rb"))["order"]
assert o["trigger"] == "cooldown" and o["interval"], "not a cooldown order with an interval"
assert o["exec"].endswith("/assets/scripts/crew-no-session-alarm.sh"), "exec does not point at the script"
def secs(v):
    m = re.fullmatch(r"(\d+)([sm])", v); assert m, "bad duration %r" % v
    return int(m.group(1)) * (60 if m.group(2) == "m" else 1)
src = open(sys.argv[2]).read()
call = int(re.search(r'CREW_ALARM_CALL_TIMEOUT:-(\d+)', src).group(1))
missing = int(re.search(r'CREW_ALARM_MISSING_SEC:-(\d+)', src).group(1))
assert "timeout" in o, "order does not declare a timeout"
# two reads at the call cap, one mail (45 s) and room for the lock/state work
assert secs(o["timeout"]) >= 2 * call + 45 + 60, "timeout %s leaves no room for two %ss reads + the 45 s mail" % (o["timeout"], call)
# the tick must be able to catch the threshold: at most MISSING_SEC, or an outage can sit unseen past its own limit
assert secs(o["interval"]) <= missing, "interval %s is longer than the %ss threshold" % (o["interval"], missing)
assert secs(o["interval"]) >= 60, "interval %s is shorter than a loaded pass" % o["interval"]
assert missing == 600, "threshold is not the 10 min of the bead (ga-4ytmas item 3)"
PY
if [ -f "$ORDER" ] && python3 "$T/order_check.py" "$ORDER" "$SCRIPT" 2>"$T/order_err"; then
  ok "order parses: cooldown, exec -> assets/scripts/crew-no-session-alarm.sh, timeout >= 2 reads + mail, interval <= the 10 min threshold"
else bad "order missing or malformed at $ORDER ($(tail -1 "$T/order_err" 2>/dev/null))"; fi

# ---- K: detection only -----------------------------------------------------------------------------------
echo "K. detection only"
code="$(grep -v '^[[:space:]]*#' "$SCRIPT")"
# every gc INVOCATION in the code (the suggested commands inside the mail text are not invocations)
gc_calls="$(printf '%s' "$code" | grep -oE '"\$GC" +[a-z]+ +[a-z]+' | sed 's/"\$GC" //' | sort -u | tr '\n' ',')"
if [ "$gc_calls" = "config show,mail send,session list," ]; then ok "the only gc calls are: config show, session list, mail send"; else bad "unexpected gc call set: [$gc_calls] — detection-only means read + mail"; fi
if printf '%s' "$code" | grep -qE '"\$BD"|[[:space:]]bd[[:space:]]+-C'; then bad "alarm code touches bd"; else ok "alarm code does not call bd (it reads config + sessions only)"; fi
if printf '%s' "$code" | grep -qE '\$NOTIFY|notify -t'; then bad "alarm code pages (NOTIFY)"; else ok "alarm code does not page anyone — its only outward act is the mail"; fi
printf '%s' "$code" | grep -q 'mail send "\$MAYOR_ADDR"' && ok "the mail goes to \$MAYOR_ADDR (default mayor)" || bad "no 'gc mail send \$MAYOR_ADDR' in the code"

# ---- S: the state helpers have not drifted from the model alarm's ------------------------------------------
echo "S. write_state / forget are identical to pool-stuck-prompt-alarm.sh's"
if [ ! -f "$MODEL" ]; then bad "model script not found at $MODEL — cannot prove the copies"; else
  fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$1"; }
  for f in write_state forget; do
    a="$(fn "$MODEL" "$f")"; b="$(fn "$SCRIPT" "$f")"
    if [ -z "$a" ]; then bad "$f: not found in the model (renamed? update this alarm and the list)"
    elif [ "$a" = "$b" ]; then ok "$f: identical"
    else bad "$f: DIFFERS from the model's"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/        /'; fi
  done
fi

# ---- scenarios as functions (so section X can run the same proof against a mutant) -------------------------
sc_young()      { baseline; GAP=300 episode; [ "$(mails)" = 0 ]; }
sc_live()       { baseline; sess oracle-wa active; episode; [ "$(mails)" = 0 ] && [ ! -f "$OF" ]; }
sc_pending()    { baseline; sess oracle-wa start-pending; episode; [ "$(mails)" = 1 ]; }
sc_closed()     { baseline; sess oracle-wa active true; episode; [ "$(mails)" = 1 ]; }
sc_other_tmpl() { baseline; sess digo-wa active; episode; [ "$(mails)" = 1 ]; }
sc_recovery()   { baseline; pass1; sess oracle-wa active; run_at "$((NOW0 + 300))"; [ ! -f "$OF" ] || return 1
                  SESS_LINES=""; run_at "$((NOW0 + 700))"; [ "$(mails)" = 0 ]; }       # a back-and-forth is not one 11 min outage
sc_gap()        { baseline; pass1; run_at "$((NOW0 + 3000))"; [ "$(mails)" = 0 ] || return 1    # 50 min unobserved: restart, do not claim 50 min
                  run_at "$((NOW0 + 3000 + 700))"; [ "$(mails)" = 1 ]; }
sc_floor0()     { baseline; episode; [ "$(calls_n mail)" = 1 ] && ! grep -q 'digo-wa' "$T/fake/mail.1.subject"; }
sc_suspended()  { baseline; cfg_agent held-wa "" 1 true; episode; [ "$(mails)" = 1 ] && ! grep -q 'held-wa' "$T/fake/mail.1.subject"; }
sc_rig_susp()   { baseline; cfg_agent lx-crew lexbh 1; episode; [ "$(mails)" = 1 ] && ! grep -q 'lx-crew' "$T/fake/mail.1.subject"; }
sc_cfg_fail()   { baseline; pass1; pass2 FAKE_CFG_FAIL=124; [ "$(mails)" = 0 ] && [ "$(cat "$OF")" = "$NOW0 $NOW0 0" ]; }
sc_list_fail()  { baseline; printf '{"sessions":[]}' > "$T/fake/sessions.raw"; pass1; pass2 FAKE_LIST_FAIL=1; [ "$(mails)" = 0 ] && [ "$(cat "$OF")" = "$NOW0 $NOW0 0" ]; }
sc_list_bad()   { baseline; pass1; printf 'this is not json' > "$T/fake/sessions.raw"; pass2; [ "$(mails)" = 0 ] && [ "$(cat "$OF")" = "$NOW0 $NOW0 0" ]; }
sc_envelope()   { baseline; pass1; printf '{"error":"boom"}' > "$T/fake/sessions.raw"; pass2; [ "$(mails)" = 0 ]; }
sc_dedupe()     { baseline; episode; run_at "$((NOW0 + 900))"; run_at "$((NOW0 + 1500))"; [ "$(mails)" = 1 ]; }
sc_realarm()    { baseline; episode CREW_ALARM_REALARM_SEC=3600; run_at "$((NOW0 + 700 + 3700))" CREW_ALARM_REALARM_SEC=3600 CREW_ALARM_GAP_SEC=99999; [ "$(mails)" = 2 ]; }
sc_mail_retry() { baseline; pass1; pass2 FAKE_MAIL_FAIL=1; [ "$(mails)" = 0 ] || return 1; run_at "$((NOW0 + 800))"; [ "$(mails)" = 1 ]; }
sc_mail_timeout() { baseline; pass1; pass2 FAKE_MAIL_TIMEOUT=1; run_at "$((NOW0 + 800))"; run_at "$((NOW0 + 1500))"
                  [ "$(calls_n mailtry)" = 1 ] && [ "$(mails)" = 0 ]; }       # one try, never re-sent: its outcome is UNKNOWN
sc_unrecordable() { [ "$(id -u)" != 0 ] || return 2          # root can write through chmod: the scenario cannot run
                  baseline; pass1; chmod a-w "$SD"; pass2; chmod u+w "$SD"; [ "$(mails)" = 0 ]; }
sc_unsafe()     { baseline; cfg_agent "evil name;x" "" 1; episode; [ "$(mails)" = 1 ] && ! grep -q 'evil' "$T/fake/mail.1.subject" && logged 'skipped_unknown=1'; }
sc_dry()        { baseline; pass1; pass2 DRY_RUN=1; [ "$(mails)" = 0 ] && logged 'DRY_RUN would MAIL' && [ "$(awk '{print $3}' "$OF")" = 0 ]; }

echo "A. baseline: the 10/10 incident — oracle-wa (min_active_sessions = 1), no session at all for 11 min"
baseline; pass1;                                                                        expect "first sighting only starts the absence clock (no mail yet)" 0
said "...logged as an observation, not an alarm" 'clock started'
said "...and the log counts the crews that must be up" 'must be up (min_active_sessions >= 1, not suspended): 1'
[ "$(cat "$OF" 2>/dev/null)" = "$NOW0 $NOW0 0" ] && ok "absence clock recorded: '<first> <last> <alarmed=0>'" || bad "state file: [$(cat "$OF" 2>/dev/null)]"
pass2;                                                                                  expect "11 min later, still no live session => ONE mail to the Mayor" 1
[ "$(cat "$T/fake/mail.1.to" 2>/dev/null)" = "mayor" ] && ok "mail addressed to mayor" || bad "mail addressed to '$(cat "$T/fake/mail.1.to" 2>/dev/null)'"
case "$(cat "$T/fake/mail.1.subject" 2>/dev/null)" in *"11min"*oracle-wa*) ok "subject names the crew and how long it has been down (11min)" ;; *) bad "subject: $(cat "$T/fake/mail.1.subject" 2>/dev/null)" ;; esac
body="$(cat "$T/fake/mail.1.body" 2>/dev/null)"
case "$body" in *"oracle-wa"*"min_active_sessions = 1"*) ok "body names the crew and its floor" ;; *) bad "body lacks crew/floor" ;; esac
case "$body" in *"nenhuma sessão"*) ok "body says there was no session at all" ;; *) bad "body lacks the best-state line" ;; esac
case "$body" in *"deferred_by_wake_budget"*"ga-4ytmas"*) ok "body points at the 10/10 cause and the bead" ;; *) bad "body lacks the incident context" ;; esac
case "$body" in *"Nada foi feito pela detecção"*) ok "body says nothing was done (detection only) and how to act" ;; *) bad "body lacks the detection-only statement" ;; esac
[ "$(awk '{print $3}' "$OF" 2>/dev/null)" = "$((NOW0 + 700))" ] && ok "alarmed mark recorded with the pass time" || bad "alarm mark: [$(cat "$OF" 2>/dev/null)]"
unsaid "no STATE-ERROR on a clean episode" 'STATE-ERROR'
[ "$(calls_n list)" -ge 1 ] && grep -q '^list --json' "$T/calls" && ok "sessions are read with 'gc session list --json'" || bad "session list call: $(grep '^list' "$T/calls" | head -1)"

echo "B. each condition on its own must stop the alarm"
check "absent only 5 min (< 10): no mail"                                               sc_young
baseline; pass1; pass2 CREW_ALARM_MISSING_SEC=300;                                      expect "...but with the threshold at 5 min the same 11 min absence mails (the knob is live)" 1
check "a live (active) session: no mail, and no clock kept"                             sc_live
check "only a start-pending session (never came up) is NOT live: mails"                 sc_pending
case "$(cat "$T/fake/mail.1.body" 2>/dev/null)" in *"start-pending"*) ok "...and the body says so (best state: start-pending)" ;; *) bad "body lacks the start-pending state" ;; esac
baseline; sess oracle-wa asleep; episode;                                               expect "an asleep session is not live with a floor of 1: mails" 1
case "$(cat "$T/fake/mail.1.body" 2>/dev/null)" in *"asleep"*) ok "...and the body says asleep" ;; *) bad "body lacks asleep" ;; esac
baseline; sess oracle-wa orphaned; episode;                                             expect "an orphaned (runtime-missing) session is not live: mails" 1
baseline; sess oracle-wa draining; sess oracle-wa start-pending; episode;               expect "draining + start-pending, none active: mails" 1
case "$(cat "$T/fake/mail.1.body" 2>/dev/null)" in *"start-pending"*"sessões deste template: 2"*) ok "...naming the best state it found and the session count" ;; *) bad "body: best state / count wrong" ;; esac
check "a CLOSED session whose state still says active does not count"                   sc_closed
check "another crew's live session does not satisfy this one"                           sc_other_tmpl
check "the live session returns, then goes again: the clock restarted, no mail"         sc_recovery
check "observations 50 min apart (> GAP_SEC) are not one 50 min outage: clock restarts" sc_gap
said "...and the log says the absence between was not proven" 'clock restarted'
check "a crew with min_active_sessions = 0 (digo-wa) is never checked"                  sc_floor0
check "a SUSPENDED agent with min_active_sessions = 1 is not checked"                   sc_suspended
check "an agent in a SUSPENDED rig is not checked"                                      sc_rig_susp
baseline; sess oracle-wa active; cfg_agent crewx gastown 1; episode;                    expect "a rig agent is matched on 'dir/name' (gastown/crewx missing => mails)" 1
case "$(cat "$T/fake/mail.1.subject" 2>/dev/null)" in *"gastown/crewx"*) ok "...subject names it as gastown/crewx" ;; *) bad "subject: $(cat "$T/fake/mail.1.subject" 2>/dev/null)" ;; esac
[ -f "$SD/gastown@crewx.state" ] && ok "...state keyed gastown@crewx (no '/' in a file name)" || bad "state files: $(ls "$SD" 2>/dev/null | tr '\n' ' ')"
baseline; sess oracle-wa active; cfg_agent crewx gastown 1; sess gastown/crewx active; episode;                    expect "...and its live session 'gastown/crewx' satisfies it" 0
baseline; sess oracle-wa active; sess gastown.witness asleep; episode;                  expect "always-mode named sessions that sit asleep by design are not checked" 0
check "a template that cannot be safely serialised is skipped as UNKNOWN, counted"      sc_unsafe

echo "U. could not tell is UNKNOWN: it never moves a clock and never mails"
check "config show exits non-zero (timeout) after printing a valid config: UNKNOWN"     sc_cfg_fail
said "...the log says which crews must be up is UNKNOWN" 'gc config show failed or empty (exit 124)'
check "session list exits non-zero after printing an EMPTY list: UNKNOWN, not 'zero sessions'" sc_list_fail
said "...the log says which sessions are live is UNKNOWN" 'gc session list failed or empty (exit 1)'
check "session list is not JSON: UNKNOWN"                                               sc_list_bad
said "...and says so" 'could not be parsed'
check "session list is an error envelope (no 'sessions' key): UNKNOWN"                  sc_envelope
baseline; pass1; printf '' > "$T/fake/config.raw"; pass2;                               expect "config show prints nothing: UNKNOWN" 0
baseline; pass1; printf 'this is = = not toml [' > "$T/fake/config.raw"; pass2;         expect "config is not TOML: UNKNOWN" 0
said "...and says so" 'could not be parsed as a config'
baseline; pass1; printf '[workspace]\nname = "x"\n' > "$T/fake/config.raw"; pass2;      expect "config without any [[agent]]: UNKNOWN, not 'nobody must be up'" 0
baseline; pass1; printf '{"sessions": null}' > "$T/fake/sessions.raw"; pass2;           expect "'sessions': null (a Go nil slice) IS an empty list: the crew is missing => mails" 1

echo "C. the alarm is once per episode, and one mail covers everything that became due"
check "mailed once; passes 3 and 13 more minutes later do not mail again"               sc_dedupe
check "a crew still missing is mailed AGAIN after REALARM_SEC"                          sc_realarm
check "a failed 'gc mail send' clears the mark: the next pass retries and delivers"     sc_mail_retry
said "...and the failure was logged" 'FAILED'
check "a 'gc mail send' that TIMES OUT is UNKNOWN: tried once, never re-sent"           sc_mail_timeout
said "...logged as UNKNOWN delivery, with the counter" 'UNKNOWN whether the alarm'
said "...counted in the pass line" 'mails_unknown=1'
check "a state dir that cannot be written: NO mail (an unrecorded alarm would repeat)"  sc_unrecordable
baseline; cfg_agent crewx gastown 1; pass1; pass2;                                      expect "two crews due in the same pass: ONE mail, not two" 1
body="$(cat "$T/fake/mail.1.body" 2>/dev/null)"; sub="$(cat "$T/fake/mail.1.subject" 2>/dev/null)"
case "$sub$body" in *"oracle-wa"*"gastown/crewx"*) ok "...naming both crews" ;; *) bad "mail does not name both: $sub" ;; esac
baseline; pass1; pass2 CREW_ALARM_GAP_SEC=99999; cfg_agent crewx gastown 1; run_at "$((NOW0 + 750))" CREW_ALARM_GAP_SEC=99999; run_at "$((NOW0 + 1500))" CREW_ALARM_GAP_SEC=99999
case "$(cat "$T/fake/mail.2.subject" 2>/dev/null)" in *"gastown/crewx"*) ok "an already-alarmed crew is not mailed again with a newcomer (mail 2 names only the new one: $(cat "$T/fake/mail.2.subject"))" ;; *) bad "mail 2 subject: [$(cat "$T/fake/mail.2.subject" 2>/dev/null)] (mails=$(mails))" ;; esac
case "$(cat "$T/fake/mail.2.subject" 2>/dev/null)" in *"oracle-wa"*) bad "oracle-wa was mailed again with the newcomer" ;; *) ok "...oracle-wa not repeated" ;; esac
baseline; pass1; echo "garbage" > "$OF"; pass2;                                         expect "garbled state file: treated as a new episode, no mail" 0
said "...and logged" 'unreadable or garbled'
[ "$(awk '{print NF}' "$OF" 2>/dev/null)" = 3 ] && ok "...and rewritten as a valid 3-field state" || bad "state not rewritten: $(cat "$OF" 2>/dev/null)"
baseline; sess oracle-wa active; mkdir -p "$SD"; echo "1 2 0" > "$SD/ghost.state"; episode
[ ! -f "$SD/ghost.state" ] && ok "state of a crew that is no longer desired is forgotten" || bad "stale state for a vanished crew was kept"

echo "M. mail content"
baseline; episode
body="$(cat "$T/fake/mail.1.body" 2>/dev/null)"
case "$body" in *"gc session list --json"*"supervisor.log"*) ok "the body gives the two commands to check first (session list, supervisor log)" ;; *) bad "body lacks the diagnosis commands" ;; esac
case "$body" in *"ga-4ytmas-"*) ok "the body points at the engine-window patch that fixes the blindness" ;; *) bad "body lacks the patch pointer" ;; esac
no_actions && ok "no session action was taken to produce it" || bad "a session action was taken"

echo "V. safety valves"
check "DRY_RUN decides + logs, sends nothing, writes no 'alarmed' mark"                 sc_dry
baseline; episode; mkdir -p "$SD"; echo "1 2 0" > "$SD/ghost.state"; run_at "$((NOW0 + 800))" DRY_RUN=1
[ -f "$SD/ghost.state" ] && ok "DRY_RUN removes no state" || bad "DRY_RUN removed state"
baseline; mkdir -p "$T/state"; : > "$T/state/crew-no-session-alarm.disabled"; episode;  expect "kill-switch file present" 0
baseline; pass1; flock -n "$T/lock" -c 'sleep 3' & LOCKER=$!; sleep 1; pass2;           expect "another instance holds the lock" 0
wait "$LOCKER" 2>/dev/null
baseline; episode MAYOR_ADDR=deacon/;                                                   [ "$(cat "$T/fake/mail.1.to" 2>/dev/null)" = "deacon/" ] && ok "MAYOR_ADDR is honoured" || bad "MAYOR_ADDR ignored"
baseline; pass1; : > "$T/calls"; pass2 >/dev/null;
[ "$(calls_n cfg)" = 1 ] && [ "$(calls_n list)" = 1 ] && ok "cost: a pass is exactly one config read and one session-list read" || bad "cost: cfg=$(calls_n cfg) list=$(calls_n list)"

echo "R. the same proof under the default shell on PATH (not only $BASH_RUN)"
if [ "$BASH_RUN" != bash ] && command -v bash >/dev/null 2>&1; then
  BASH_SAVE="$BASH_RUN"; BASH_RUN=bash
  baseline; episode;                                                                    expect "baseline mails under $(bash --version | head -1 | cut -c1-30)" 1
  BASH_RUN="$BASH_SAVE"
else ok "(only one bash in play — skipped)"; fi

# ---- X: mutants — each load-bearing line broken; the matching scenario MUST fail ---------------------------
echo "X. mutants: the scenario that guards each line must FAIL when the line is broken"
cat > "$T/mutate.py" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) < 1:
    sys.stderr.write("mutation text not found: %r\n" % old); sys.exit(2)
open(dst, "w").write(s.replace(old, new, 1))
PY
mutant() { # <name> <old> <new> <scenario-fn> <label>
  local name="$1" old="$2" new="$3" fn="$4" label="$5" m="$T/mut/$1.sh"
  if ! python3 "$T/mutate.py" "$SCRIPT" "$m" "$old" "$new" 2>"$T/mut_err"; then bad "mutant $name: could not be built ($(cat "$T/mut_err")) — the script moved, update the proof"; return; fi
  chmod +x "$m"; SCRIPT_UNDER_TEST="$m"
  "$fn" 2>/dev/null; rc=$?
  SCRIPT_UNDER_TEST="$SCRIPT"
  case "$rc" in
    0) bad "mutant $name SURVIVED: $label — scenario $fn passes against the broken script" ;;
    2) ok "mutant $name: (skipped: scenario cannot run as root)" ;;
    *) ok "mutant $name killed: $label" ;;
  esac
}
mutant no_threshold 'if [ "$missing" -lt "$MISSING_SEC" ]; then' 'if false; then' sc_young "the 10 min threshold removed"
mutant live_ignored 'if [ "$live" = "1" ]; then' 'if false; then' sc_live "a live session does not end the episode (it mails about a crew that is up)"
mutant pending_is_live 'live = 1 if "active" in states else 0' 'live = 1 if states else 0' sc_pending "a start-pending / asleep session counted as live (the 10/10 replacement that never came up)"
mutant closed_counts 'and not s.get("closed")' '' sc_closed "a closed session still counts as the crew's session"
mutant other_template_counts 's.get("template") == tmpl and' '' sc_other_tmpl "any session satisfies any crew"
mutant live_keeps_clock '    forget "$stf"
    continue' '    continue' sc_recovery "a returning session leaves the old clock (a flap reads as one long outage)"
mutant no_gap_restart 'if [ $((NOW - ST_LAST)) -gt "$GAP_SEC" ]; then' 'if false; then' sc_gap "an unobserved gap counted as proven absence"
mutant floor0_checked 'if floor < 1 or ' 'if ' sc_floor0 "a crew with min_active_sessions = 0 is checked"
mutant suspended_checked ' or a.get("suspended") or ' ' or ' sc_suspended "a suspended agent is checked"
mutant rig_susp_checked ' or (d and d in susp_rigs)' '' sc_rig_susp "an agent in a suspended rig is checked"
mutant cfg_rc_ignored 'if [ "$rc" -ne 0 ] || [ ! -s "$CFG_FILE" ]; then log "WARN: gc config show' 'if [ ! -s "$CFG_FILE" ]; then log "WARN: gc config show' sc_cfg_fail "a failed config read is trusted"
mutant list_rc_ignored 'if [ "$rc" -ne 0 ] || [ ! -s "$SESS_FILE" ]; then log "WARN: gc session list' 'if [ ! -s "$SESS_FILE" ]; then log "WARN: gc session list' sc_list_fail "a failed session list that printed an empty list reads as 'zero sessions'"
mutant bad_json_is_empty 'assert isinstance(doc, dict) and "sessions" in doc' 'doc = doc if isinstance(doc, dict) else {}; doc.setdefault("sessions", [])' sc_envelope "an error envelope reads as 'zero sessions'"
mutant no_dedupe 'if [ "$ST_ALARMED" -gt 0 ] && [ $((NOW - ST_ALARMED)) -lt "$REALARM_SEC" ]; then N_DONE=$((N_DONE + 1)); continue; fi' ':' sc_dedupe "no once-per-episode mark (a mail every pass)"
mutant no_realarm 'lt "$REALARM_SEC" ]; then N_DONE' 'lt 99999999 ]; then N_DONE' sc_realarm "a crew that stays down is never re-alarmed"
mutant mail_fail_keeps_mark 'write_state "$SESS_STATE/$key.state" "$first $NOW 0" || state_err' ': || state_err' sc_mail_retry "a failed send leaves the alarmed mark (the alarm is lost)"
mutant mail_timeout_is_failure '        124)
' '        9999)
' sc_mail_timeout "a timed-out send read as a plain failure (mark cleared, the mail may be sent twice)"
mutant send_unrecorded 'if write_state "$stf" "$first $NOW $NOW"; then' 'if { write_state "$stf" "$first $NOW $NOW" || true; }; then' sc_unrecordable "mail sent although the alarm mark could not be recorded"
mutant unsafe_accepted 'if not name or not re.fullmatch' 'if not name or False and not re.fullmatch' sc_unsafe "a template with a space or ';' accepted"
mutant dry_run_sends 'if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would MAIL' 'if false; then
    log "DRY_RUN would MAIL' sc_dry "DRY_RUN mails and writes marks"

echo
echo "crew-no-session-alarm selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
