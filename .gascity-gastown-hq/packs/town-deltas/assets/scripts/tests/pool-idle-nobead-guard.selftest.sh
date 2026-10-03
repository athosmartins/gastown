#!/usr/bin/env bash
# pool-idle-nobead-guard.selftest.sh — ga-7nxfa1 (item 2).
# Runs the REAL pool-idle-nobead-guard.sh (not a reimplementation) against fake `gc` and `bd`.
#
# Design: ONE baseline fixture the guard must act on (an idle, bead-less wa-worker with a readable pane),
# then one scenario per condition that differs from the baseline in EXACTLY that condition and must make
# the guard do nothing. If a condition were dropped from the guard, its scenario would start acting and
# fail here — that is what makes each of them load-bearing rather than decorative. Then the two-stage
# timeline (nudge -> grace -> kill), the caps, DRY_RUN, the kill-switch and the single-instance lock.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${POOL_IDLE_GUARD_SCRIPT:-$SELF_DIR/../pool-idle-nobead-guard.sh}"
ORDER="${POOL_IDLE_GUARD_ORDER:-$SELF_DIR/../../../orders/pool-idle-nobead-guard.toml}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$SCRIPT" ] || { echo "FATAL: guard script not found at $SCRIPT"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pool-idle-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
NOW=1800000000
CITYDIR="$T/gt/.gascity-gastown-hq"; RIGDIR="$T/gt/whatsapp_automation"
mkdir -p "$CITYDIR" "$RIGDIR" "$T/fake"

# ---- fakes ---------------------------------------------------------------------------------------------
cat > "$T/fake/gc" <<'EOF'
#!/usr/bin/env bash
# fake gc: driven entirely by files under $FAKE_DIR; every state-changing call is appended to $FAKE_CALLS
case "$1 $2" in
  "session list") [ -n "${FAKE_LIST_FAIL:-}" ] && exit 1
                  if [ -f "$FAKE_DIR/sessions.raw" ]; then cat "$FAKE_DIR/sessions.raw"; else cat "$FAKE_DIR/sessions.json"; fi ;;
  "rig list")     [ -n "${FAKE_RIG_FAIL:-}" ] && exit 1; cat "$FAKE_DIR/rigs.json" ;;
  "session peek") [ -f "$FAKE_DIR/pane.$3" ] && cat "$FAKE_DIR/pane.$3"; exit 0 ;;
  "session nudge") echo "nudge $3" >> "$FAKE_CALLS"; printf '%s' "$4" > "$FAKE_DIR/last_nudge.txt"; [ -n "${FAKE_NUDGE_FAIL:-}" ] && exit 1; exit 0 ;;
  "session kill")  echo "kill $3" >> "$FAKE_CALLS"; exit 0 ;;
  *) echo "fake gc: unexpected call: $*" >> "$FAKE_CALLS"; exit 2 ;;
esac
EOF
cat > "$T/fake/bd" <<'EOF'
#!/usr/bin/env bash
# fake bd -C <db> list ... | query --json '<expr>' ... ; reads $FAKE_DIR/<basename db>.<kind>.json, default []
[ -n "${FAKE_BD_FAIL:-}" ] && exit 1
db="$(basename "$2")"; shift 2
case "$1" in
  list)  kind=list ;;
  query) case "$3" in *in_progress*) kind=wisp_in_progress ;; *) kind=wisp_open ;; esac ;;
  *) exit 2 ;;
esac
f="$FAKE_DIR/$db.$kind.json"; [ -f "$f" ] && cat "$f" || echo '[]'
EOF
chmod +x "$T/fake/gc" "$T/fake/bd"

# ---- fixture builders ----------------------------------------------------------------------------------
IDLE_PANE=$'● done with the previous thing\n\n✻ Cogitated for 3m 21s · done 8:30 AM\n\n──────────\n❯ '
BUSY_PANE=$'✳ Gitifying… (15m 49s · ↓ 61.3k tokens)\n  esc to interrupt'

reset() {
  # find, not a glob: the city DB fixture is a dot-file ('.gascity-gastown-hq.list.json') that '*.json' skips
  find "$T/fake" -maxdepth 1 \( -name '*.json' -o -name 'sessions.raw' -o -name 'pane.*' -o -name 'last_nudge.txt' \) -delete
  rm -rf "$T/state" "$T/log" "$T/calls"; : > "$T/calls"; mkdir -p "$T/state"
  rigs_ok; }
rigs_ok() { printf '{"rigs":[{"name":"gascity","path":"%s"},{"name":"whatsapp_automation","path":"%s"}]}' "$CITYDIR" "$RIGDIR" > "$T/fake/rigs.json"; }
# sess <name> <template> <idle_sec> [state=active] [attached=false] [work_dir]   (appends one session)
SESS_LINES=""
sess() { SESS_LINES="$SESS_LINES$1|$2|$3|${4:-active}|${5:-false}|${6:-$RIGDIR/crew/worker}"$'\n'; }
write_sessions() {
  printf '%s' "$SESS_LINES" | NOW="$NOW" python3 -c '
import sys, os, json, datetime
now = int(os.environ["NOW"]); out = []
for line in sys.stdin.read().splitlines():
    n, t, idle, st, att, wd = line.split("|")
    la = datetime.datetime.fromtimestamp(now - int(idle), tz=datetime.timezone.utc).isoformat()
    out.append({"name": n, "id": "ga-wisp-" + n[-3:], "alias": n, "session_name": n.replace("adhoc-", "gawisp"), "template": t,
                "state": st, "attached": att == "true", "last_active": la, "created_at": la, "work_dir": wd})
print(json.dumps({"sessions": out}))' > "$T/fake/sessions.json"
}
pane() { printf '%s' "$2" > "$T/fake/pane.$1"; }
# run the guard; extra args are env assignments (KEY=VAL) applied to this run only
run() {
  write_sessions
  env FAKE_DIR="$T/fake" FAKE_CALLS="$T/calls" GC="$T/fake/gc" BD="$T/fake/bd" GC_CITY_PATH="$CITYDIR" \
      POOL_IDLE_STATE_ROOT="$T/state" POOL_IDLE_LOG="$T/log" POOL_IDLE_LOCK="$T/lock" POOL_IDLE_NOW="$NOW" \
      POOL_IDLE_CALL_TIMEOUT=10 "$@" bash "$SCRIPT" > "$T/stdout" 2>&1
  return 0
}
calls_n() { grep -c "^$1 " "$T/calls" 2>/dev/null || true; }
expect() { # expect <label> <nudges> <kills>
  local n k; n="$(calls_n nudge)"; k="$(calls_n kill)"
  if [ "$n" = "$2" ] && [ "$k" = "$3" ]; then ok "$1  (nudges=$n kills=$k)"
  else bad "$1  expected nudges=$2 kills=$3, got nudges=$n kills=$k"; sed 's/^/        /' "$T/log" 2>/dev/null | tail -6; fi
}
baseline() { reset; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 700; pane wa-worker-adhoc-aaa "$IDLE_PANE"; }
bead_json() { printf '[{"id":"wa-1","status":"%s","assignee":"%s"}]' "$1" "$2" > "$T/fake/$3.$4.json"; }

# ---- static: wiring ------------------------------------------------------------------------------------
echo "W. wiring"
if [ -x "$SCRIPT" ]; then ok "guard script is executable"; else bad "guard script is not executable"; fi
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n ($(bash --version | head -1 | cut -c1-30))"; else bad "bash -n failed"; fi
if [ -x /bin/bash ] && /bin/bash -n "$SCRIPT" 2>/dev/null; then ok "parses under /bin/bash ($(/bin/bash -c 'echo ${BASH_VERSION%%(*}'))"; else bad "does not parse under /bin/bash (macOS 3.2)"; fi
cat > "$T/order_check.py" <<'PY'
import sys, tomllib
o = tomllib.load(open(sys.argv[1], "rb"))["order"]
assert o["trigger"] == "cooldown" and o["interval"] and o["exec"].endswith("/assets/scripts/pool-idle-nobead-guard.sh")
PY
if [ -f "$ORDER" ] && python3 "$T/order_check.py" "$ORDER" 2>/dev/null; then
  ok "order parses: cooldown trigger, interval set, exec -> assets/scripts/pool-idle-nobead-guard.sh"
else bad "order missing or malformed at $ORDER"; fi

# ---- baseline: the guard MUST act ------------------------------------------------------------------------
echo "A. baseline: idle, bead-less pool worker"
baseline; run; expect "idle 700s + readable idle pane + no bead anywhere => nudged" 1 0
grep -q '^nudge wa-worker-adhoc-aaa' "$T/calls" && [ -f "$T/state/pool-idle-nobead/wa-worker-adhoc-aaa.nudged" ] && ok "nudge recorded in state" || bad "no state recorded after the nudge"
msg="$(cat "$T/fake/last_nudge.txt" 2>/dev/null)"
case "$msg" in *"drain-ack"*"exit"*) ok "nudge text asks for drain-ack then exit" ;; *) bad "nudge text lacks the drain-ack/exit request: $msg" ;; esac
case "$msg" in *"--claim"*) ok "nudge text tells a worker WITH work to claim it" ;; *) bad "nudge text lacks the 'has work -> claim' branch" ;; esac
if printf '%s' "$msg" | grep -Eq '(^|[^[:alnum:]_/.~-])/(gate-done|recall|refino|backup|reaper)'; then bad "nudge text contains a slash-skill token (would become a skill_mention)"; else ok "nudge text has no slash-skill token"; fi

# ---- single-factor abstentions ----------------------------------------------------------------------------
echo "B. each condition on its own must stop the guard"
baseline; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 300; run;                   expect "idle only 300s (< 600)" 0 0
baseline; pane wa-worker-adhoc-aaa "$BUSY_PANE"; run;                                    expect "pane is mid-turn (spinner + elapsed timer)" 0 0
baseline; pane wa-worker-adhoc-aaa "";            run;                                    expect "pane empty -> UNKNOWN, not idle" 0 0
baseline; pane wa-worker-adhoc-aaa "hello world, no prompt, no summary"; run;             expect "pane unclassifiable -> UNKNOWN" 0 0
baseline; bead_json in_progress wa-worker-adhoc-aaa whatsapp_automation list; run;       expect "bead in_progress assigned by name (rig DB)" 0 0
baseline; bead_json open ga-wisp-aaa .gascity-gastown-hq list; run;                      expect "bead open assigned by session ID (city DB)" 0 0
baseline; bead_json blocked wa-worker-adhoc-aaa whatsapp_automation list; run;           expect "bead blocked (parked) assigned by name" 0 0
baseline; bead_json in_progress wa-worker-adhoc-aaa whatsapp_automation wisp_in_progress; run; expect "assigned as an EPHEMERAL wisp, in_progress" 0 0
baseline; bead_json open ga-wisp-aaa .gascity-gastown-hq wisp_open; run;                 expect "assigned as an EPHEMERAL wisp, open" 0 0
baseline; bead_json in_progress wa-worker-gawispaaa whatsapp_automation list; run;       expect "bead assigned by session_name" 0 0
baseline; run FAKE_BD_FAIL=1;                                                             expect "bd unreadable -> UNKNOWN, never 'no bead'" 0 0
baseline; run FAKE_RIG_FAIL=1;                                                            expect "rig list unreadable -> UNKNOWN" 0 0
baseline; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 700 active false "$T/elsewhere/crew/worker"; run; expect "work_dir under no known rig -> UNKNOWN" 0 0
baseline; SESS_LINES=""; sess batista-wa batista-wa 700; pane batista-wa "$IDLE_PANE"; run; expect "non-pool template (named crew)" 0 0
baseline; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 700 active true; run;         expect "human-attached session" 0 0
baseline; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 700 asleep; run;              expect "session not active (asleep)" 0 0
baseline; run FAKE_LIST_FAIL=1;                                                           expect "session list unreadable -> skip pass" 0 0
baseline; printf '[{"id":"wa-1","status":"in_progress","assignee":"someone-else","metadata":{"gc.session_name":"wa-worker-gawispaaa"}}]' > "$T/fake/whatsapp_automation.list.json"; run
                                                                                          expect "bead attributed ONLY via metadata gc.session_name" 0 0
baseline; printf 'this is not json' > "$T/fake/sessions.raw"; run;                           expect "session list is not JSON -> skip pass" 0 0
grep -q 'could not be parsed' "$T/log" && ok "...and says so (not a silent '0 candidates')" || bad "unparseable session list was logged as if it were zero sessions"
baseline; printf '{"error":"boom"}' > "$T/fake/sessions.raw"; run;                        expect "session list is an error envelope (no 'sessions' key) -> skip pass" 0 0
grep -q 'could not be parsed' "$T/log" && ok "...and says so" || bad "error-envelope session list read as zero sessions"
baseline; bead_json in_progress someone-else whatsapp_automation list; run;              expect "ANOTHER session's bead does not shield this one (exact assignee match)" 1 0

# ---- safety valves -----------------------------------------------------------------------------------------
echo "C. safety valves"
baseline; run DRY_RUN=1
n="$(calls_n nudge)"; sc="$(ls "$T/state/pool-idle-nobead" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n" = 0 ] && [ "$sc" = 0 ] && grep -q 'DRY_RUN would NUDGE' "$T/stdout"; then ok "DRY_RUN decides + logs, changes nothing, writes no state"; else bad "DRY_RUN leaked (nudges=$n state_files=$sc)"; fi
baseline; : > "$T/state/pool-idle-nobead-guard.disabled"; run;                           expect "kill-switch file present" 0 0
baseline; flock -n "$T/lock" -c 'sleep 3' & LOCKER=$!; sleep 1; run;                    expect "another instance holds the lock" 0 0
wait "$LOCKER" 2>/dev/null

# ---- the two-stage timeline --------------------------------------------------------------------------------
echo "D. nudge -> grace -> kill"
stage() { mkdir -p "$T/state/pool-idle-nobead"; echo "$1" > "$T/state/pool-idle-nobead/wa-worker-adhoc-aaa.nudged"; }
baseline; run; run;                                                                       expect "second pass right after the nudge does not nudge again" 1 0
baseline; stage $((NOW - 700)); run;                                                      expect "nudged 700s ago, still idle + bead-less => KILL" 0 1
baseline; stage $((NOW - 300)); run;                                                      expect "nudged only 300s ago (< grace 600) => wait" 0 0
baseline; stage $((NOW - 700)); SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 100; run; expect "nudged long ago but it replied 100s ago (mid-conversation) => wait" 0 0
baseline; stage $((NOW - 2500)); run;                                                     expect "our own state is stale (> 3x grace) => start over with a nudge, not a kill" 1 0
baseline; stage $((NOW - 700)); run POOL_IDLE_KILL=0;                                     expect "kill disabled (POOL_IDLE_KILL=0)" 0 0
baseline; stage $((NOW - 700)); bead_json in_progress wa-worker-adhoc-aaa whatsapp_automation list; run
n="$(calls_n kill)"; if [ "$n" = 0 ] && [ ! -f "$T/state/pool-idle-nobead/wa-worker-adhoc-aaa.nudged" ]; then ok "it picked up a bead after the nudge => no kill, nudge state cleared"; else bad "killed (or kept state for) a worker that now holds a bead (kills=$n)"; fi
baseline; stage $((NOW - 700)); pane wa-worker-adhoc-aaa "$BUSY_PANE"; run;               expect "nudged long ago but the pane is busy now => no kill" 0 0
baseline; stage $((NOW - 700)); run FAKE_BD_FAIL=1;                                       expect "ready to kill but bd unreadable => no kill (re-checked at kill time)" 0 0
baseline; mkdir -p "$T/state/pool-idle-nobead"; echo $((NOW - 100)) > "$T/state/pool-idle-nobead/ghost-session.nudged"; run
[ ! -f "$T/state/pool-idle-nobead/ghost-session.nudged" ] && ok "state for a session that no longer exists is forgotten" || bad "stale state for a vanished session was kept"

# ---- caps -----------------------------------------------------------------------------------------------------
echo "E. caps bound the blast radius"
baseline; SESS_LINES=""; for i in 1 2 3 4; do sess wa-worker-adhoc-w$i wa-worker 700; pane wa-worker-adhoc-w$i "$IDLE_PANE"; done; run; expect "4 eligible, MAX_NUDGES default 3" 3 0
baseline; SESS_LINES=""; for i in 1 2; do sess wa-worker-adhoc-w$i wa-worker 700; pane wa-worker-adhoc-w$i "$IDLE_PANE"; mkdir -p "$T/state/pool-idle-nobead"; echo $((NOW - 700)) > "$T/state/pool-idle-nobead/wa-worker-adhoc-w$i.nudged"; done; run; expect "2 ready to kill, MAX_KILLS default 1" 0 1
baseline; SESS_LINES=""; sess ps-w ps-worker 700 active false "$T/gt/property_scrapers/crew/worker"
printf '{"rigs":[{"name":"gascity","path":"%s"},{"name":"property_scrapers","path":"%s"}]}' "$CITYDIR" "$T/gt/property_scrapers" > "$T/fake/rigs.json"; pane ps-w "$IDLE_PANE"; run; expect "ps-worker is covered too (rig derived from its work_dir)" 1 0

echo
echo "pool-idle-nobead-guard selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
