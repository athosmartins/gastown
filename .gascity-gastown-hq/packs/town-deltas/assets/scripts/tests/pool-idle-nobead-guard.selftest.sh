#!/usr/bin/env bash
# pool-idle-nobead-guard.selftest.sh — ga-7nxfa1 (item 2).
# Runs the REAL pool-idle-nobead-guard.sh (not a reimplementation) against fake `gc` and `bd`.
#
# Design: ONE baseline fixture the guard must act on (an idle, bead-less wa-worker with a readable pane),
# then one scenario per condition that differs from the baseline in EXACTLY that condition and must make
# the guard do nothing. If a condition were dropped from the guard, its scenario would start acting and
# fail here — that is what makes each of them load-bearing rather than decorative. Then the two-stage
# timeline (nudge -> grace -> close), the caps, DRY_RUN, the kill-switch and the single-instance lock.
#
# What the first version of this file could not see, and the gate caught (ga-7nxfa1, fix attempt 2):
#   - its fake `gc` accepted `session kill` and always exited 0, so "the verb was invoked" passed for a verb
#     that frees nothing. Now: the fake models what `gc session close` really does to the session list, can
#     fail to, and ANY `kill` call fails every scenario;
#   - its "busy" pane was not the shape of a real one (no prompt box, no hours in the timer). Now the pane
#     fixtures are copied from the live city (03/10), prompt box included;
#   - the failure paths (nudge fails, state cannot be written/removed, close does not take effect) had no
#     scenario at all.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${POOL_IDLE_GUARD_SCRIPT:-$SELF_DIR/../pool-idle-nobead-guard.sh}"
ORDER="${POOL_IDLE_GUARD_ORDER:-$SELF_DIR/../../../orders/pool-idle-nobead-guard.toml}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$SCRIPT" ] || { echo "FATAL: guard script not found at $SCRIPT"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pool-idle-selftest.XXXXXX")"
# the state dir is made read-only by one scenario: always give write access back before the cleanup
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
NOW=1800000000
CITYDIR="$T/gt/.gascity-gastown-hq"; RIGDIR="$T/gt/whatsapp_automation"
mkdir -p "$CITYDIR" "$RIGDIR" "$T/fake" "$T/shim" "$T/shim2"

# ---- fakes ---------------------------------------------------------------------------------------------
cat > "$T/fake/gc" <<'EOF'
#!/usr/bin/env bash
# fake gc: driven entirely by files under $FAKE_DIR; every state-changing call is appended to $FAKE_CALLS.
# `session close <n>` behaves like the real one: afterwards <n> is gone from the DEFAULT session list.
# FAKE_CLOSE_KEEPS=1 models a close that returns 0 but frees nothing (the reviewers' reading of `kill`).
case "$1 $2" in
  "session list") [ -n "${FAKE_LIST_FAIL:-}" ] && exit 1
                  if ls "$FAKE_DIR"/closed.* >/dev/null 2>&1; then
                    [ -n "${FAKE_LIST_FAIL_AFTER_CLOSE:-}" ] && exit 1
                    if [ -z "${FAKE_CLOSE_KEEPS:-}" ] && [ -f "$FAKE_DIR/sessions.json" ]; then
                      python3 -c '
import json, os, glob
d = os.environ["FAKE_DIR"]
gone = {os.path.basename(p)[len("closed."):] for p in glob.glob(d + "/closed.*")}
data = json.load(open(d + "/sessions.json"))
data["sessions"] = [s for s in data["sessions"] if s["name"] not in gone]
print(json.dumps(data))'
                      exit 0
                    fi
                  fi
                  if [ -f "$FAKE_DIR/sessions.raw" ]; then cat "$FAKE_DIR/sessions.raw"; else cat "$FAKE_DIR/sessions.json"; fi ;;
  "rig list")     [ -n "${FAKE_RIG_FAIL:-}" ] && exit 1; cat "$FAKE_DIR/rigs.json" ;;
  "session peek") [ -f "$FAKE_DIR/pane.$3" ] && cat "$FAKE_DIR/pane.$3"; exit 0 ;;
  "session nudge") echo "nudge $3" >> "$FAKE_CALLS"; printf '%s' "$4" > "$FAKE_DIR/last_nudge.txt"
                   [ -n "${FAKE_NUDGE_SLEEP:-}" ] && sleep "$FAKE_NUDGE_SLEEP"
                   [ -n "${FAKE_NUDGE_FAIL:-}" ] && exit 1; exit 0 ;;
  "session close") echo "close $3" >> "$FAKE_CALLS"
                   [ -n "${FAKE_CLOSE_FAIL:-}" ] && exit 1
                   : > "$FAKE_DIR/closed.$3"; exit 0 ;;
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
# shim for ONE scenario: stands in for python3 so the candidate extractor can emit a line the real one never
# would (a non-numeric idle age) — the loop's defensive branch is otherwise unreachable.
cat > "$T/shim/python3" <<'EOF'
#!/bin/sh
cat > /dev/null
printf '%s\n' "$FAKE_CAND_LINE"
EOF
# shim for ONE scenario: the real grep, except that counting the skip report fails (rc 2 = "could not read")
cat > "$T/shim2/grep" <<'EOF'
#!/bin/sh
case "$*" in *"-c ^skip:"*) [ -n "${FAKE_SKIP_UNREADABLE:-}" ] && exit 2 ;; esac
exec /usr/bin/grep "$@"
EOF
chmod +x "$T/fake/gc" "$T/fake/bd" "$T/shim/python3" "$T/shim2/grep"

# ---- pane fixtures -------------------------------------------------------------------------------------
# REAL panes, copied from the live wa-workers on 03/10 (gc session peek), trimmed. Note both carry the "❯"
# prompt box: that glyph is on EVERY pane, busy or idle, so it can never be what tells them apart.
# (written with top-level heredocs, then read back: bash 3.2 — which the gate parses with — mis-parses a heredoc whose
#  body has quotes/parens when it sits inside $( ))
mkdir -p "$T/fixtures"
cat > "$T/fixtures/real_busy.txt" <<'EOF'
⏺ Re-running the real-data E2E with a fresh oracle · 1m 5s
  ⎿  $ cd /Users/athos/gt/whatsapp_automation/crew/worker-wa-yo0ex9 && python3 -
     <<'PYEOF'
     (ctrl+b ctrl+b (twice) to run in background)

✢ Kneading… (1h 31m 47s · ↓ 298.6k tokens)
  ⎿  Tip: Use /clear to start fresh when switching topics and free up context

────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  👥 0 workers · 🚦 running 2/3 6c179cf040677bf559f74e
  [Sonnet 5.5] ctx: 68.0% (680k/1000k)
  ⏵⏵ bypass permissions on · 2 shells · ← 1 agent
EOF
cat > "$T/fixtures/real_idle.txt" <<'EOF'
⏺ Monitor(mutation (new code) and neighbour differential finished)
  ⎿  Monitor started · task bh0a27iaa · timeout 1800s

⏺ Status: tudo commitado localmente (c9475d8c0, 2 commits sobre o tip da origin,
  push será fast-forward). Falta só a mutação dos trechos novos e a vizinhança;
  assim que terminarem, empurro e rodo o gate-done como um script único.

✻ Cooked for 1h 1m 30s · done 10:22 AM · 3 shells, 1 monitor still running

────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  👥 0 workers · 🚦 running 2/3 6c179cf040677bf559f74e
  [Sonnet 5.5] ctx: 38.0% (380k/1000k)
  ⏵⏵ bypass permissions on · 3 shells, 1 monitor · ← 1 agent
EOF
REAL_BUSY_PANE="$(cat "$T/fixtures/real_busy.txt")"
REAL_IDLE_PANE="$(cat "$T/fixtures/real_idle.txt")"
CHROME=$'\n────────────────────────────────────────────────────────────────────────────────\n❯ \n────────────────────────────────────────────────────────────────────────────────\n  [Sonnet 5.5] ctx: 38.0% (380k/1000k)'
IDLE_PANE=$'● done with the previous thing\n\n✻ Cogitated for 3m 21s · done 8:30 AM'"$CHROME"
BUSY_PANE=$'✳ Gitifying… (15m 49s · ↓ 61.3k tokens)'"$CHROME"

# ---- fixture builders ----------------------------------------------------------------------------------
reset() {
  # find, not a glob: the city DB fixture is a dot-file ('.gascity-gastown-hq.list.json') that '*.json' skips
  find "$T/fake" -maxdepth 1 \( -name '*.json' -o -name 'sessions.raw' -o -name 'pane.*' -o -name 'last_nudge.txt' -o -name 'closed.*' \) -delete
  chmod -R u+w "$T/state" 2>/dev/null
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
# expect <label> <nudges> <closes>  — and `kill` must NEVER be called (it frees no slot: see the guard header)
expect() {
  local n c k; n="$(calls_n nudge)"; c="$(calls_n close)"; k="$(calls_n kill)"
  if [ "$n" = "$2" ] && [ "$c" = "$3" ] && [ "$k" = 0 ]; then ok "$1  (nudges=$n closes=$c)"
  else bad "$1  expected nudges=$2 closes=$3 kills=0, got nudges=$n closes=$c kills=$k"; sed 's/^/        /' "$T/log" 2>/dev/null | tail -6; fi
}
logged()   { grep -q -- "$1" "$T/log" 2>/dev/null; }
# said <label> <fixed text that must be in the log>   /   unsaid <label> <text that must NOT be>
said()   { if logged "$2"; then ok "$1"; else bad "$1  [log lacks: $2]"; sed 's/^/        /' "$T/log" 2>/dev/null | tail -5; fi; }
unsaid() { if logged "$2"; then bad "$1  [log wrongly has: $2]"; sed 's/^/        /' "$T/log" 2>/dev/null | tail -5; else ok "$1"; fi; }
baseline() { reset; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 700; pane wa-worker-adhoc-aaa "$IDLE_PANE"; }
bead_json() { printf '[{"id":"wa-1","status":"%s","assignee":"%s"}]' "$1" "$2" > "$T/fake/$3.$4.json"; }
SF="$T/state/pool-idle-nobead/wa-worker-adhoc-aaa.nudged"          # the baseline session's state file
stage() { mkdir -p "$T/state/pool-idle-nobead"; echo "$1" > "$T/state/pool-idle-nobead/${2:-wa-worker-adhoc-aaa}.nudged"; }   # stage <content> [session]
nudged_ago() { stage "nudged $((NOW - $1))" "${2:-wa-worker-adhoc-aaa}"; }                                                   # a CONFIRMED nudge, <n> s ago

# ---- static: wiring ------------------------------------------------------------------------------------
echo "W. wiring"
if [ -x "$SCRIPT" ]; then ok "guard script is executable"; else bad "guard script is not executable"; fi
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n ($(bash --version | head -1 | cut -c1-30))"; else bad "bash -n failed"; fi
if [ -x /bin/bash ] && /bin/bash -n "$SCRIPT" 2>/dev/null; then ok "parses under /bin/bash ($(/bin/bash -c 'echo ${BASH_VERSION%%(*}'))"; else bad "does not parse under /bin/bash (macOS 3.2)"; fi
# `gc session kill` leaves the session active for the reconciler to restart: it frees no pool slot. The
# guard must free the slot with `close`. Comments may say "kill"; code must not call it.
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -q 'session kill'; then bad "guard CODE calls 'gc session kill' (frees no slot)"; else ok "guard code never calls 'gc session kill'"; fi
grep -v '^[[:space:]]*#' "$SCRIPT" | grep -q '"\$GC" session close' && ok "guard code frees the slot with 'gc session close'" || bad "guard code never invokes 'gc session close'"
cat > "$T/order_check.py" <<'PY'
import re, sys, tomllib
o = tomllib.load(open(sys.argv[1], "rb"))["order"]
assert o["trigger"] == "cooldown" and o["interval"] and o["exec"].endswith("/assets/scripts/pool-idle-nobead-guard.sh")
# the timeout must be DECLARED (not left to the engine default) and leave room after the pass budget
def secs(v):
    m = re.fullmatch(r"(\d+)([sm])", v); assert m, "bad duration %r" % v
    return int(m.group(1)) * (60 if m.group(2) == "m" else 1)
budget = int(re.search(r'POOL_IDLE_PASS_BUDGET_SEC:-(\d+)', open(sys.argv[2]).read()).group(1))
assert "timeout" in o, "order does not declare a timeout"
assert secs(o["timeout"]) >= budget + 60, "timeout %s leaves < 60s after the %ss pass budget" % (o["timeout"], budget)
PY
if [ -f "$ORDER" ] && python3 "$T/order_check.py" "$ORDER" "$SCRIPT" 2>"$T/order_err"; then
  ok "order parses: cooldown trigger, interval set, exec -> assets/scripts/pool-idle-nobead-guard.sh, timeout declared >= pass budget + 60s"
else bad "order missing or malformed at $ORDER ($(tail -1 "$T/order_err" 2>/dev/null))"; fi

# ---- baseline: the guard MUST act ------------------------------------------------------------------------
echo "A. baseline: idle, bead-less pool worker"
baseline; run; expect "idle 700s + readable idle pane + no bead anywhere => nudged" 1 0
[ "$(cat "$SF" 2>/dev/null)" = "nudged $NOW" ] && ok "nudge recorded in state as 'nudged <ts>' (confirmed)" || bad "state after a delivered nudge is not 'nudged $NOW': '$(cat "$SF" 2>/dev/null)'"
msg="$(cat "$T/fake/last_nudge.txt" 2>/dev/null)"
case "$msg" in *"drain-ack"*"exit"*) ok "nudge text asks for drain-ack then exit" ;; *) bad "nudge text lacks the drain-ack/exit request: $msg" ;; esac
case "$msg" in *"--claim"*) ok "nudge text tells a worker WITH work to claim it" ;; *) bad "nudge text lacks the 'has work -> claim' branch" ;; esac
if printf '%s' "$msg" | grep -Eq '(^|[^[:alnum:]_/.~-])/(gate-done|recall|refino|backup|reaper)'; then bad "nudge text contains a slash-skill token (would become a skill_mention)"; else ok "nudge text has no slash-skill token"; fi

# ---- single-factor abstentions ----------------------------------------------------------------------------
echo "B. each condition on its own must stop the guard"
baseline; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 300; run;                   expect "idle only 300s (< 600)" 0 0
baseline; pane wa-worker-adhoc-aaa "$BUSY_PANE"; run;                                    expect "pane is mid-turn (spinner + elapsed timer + prompt box)" 0 0
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
said "...and says so (not a silent '0 candidates')" 'could not be parsed'
baseline; printf '{"error":"boom"}' > "$T/fake/sessions.raw"; run;                        expect "session list is an error envelope (no 'sessions' key) -> skip pass" 0 0
said "...and says so" 'could not be parsed'
baseline; bead_json in_progress someone-else whatsapp_automation list; run;              expect "ANOTHER session's bead does not shield this one (exact assignee match)" 1 0
# a session whose timestamps cannot be read is UNKNOWN: not a candidate, but COUNTED and NAMED
baseline; printf '{"sessions":[{"name":"wa-worker-adhoc-aaa","id":"i","alias":"a","session_name":"s","template":"wa-worker","state":"active","attached":false,"last_active":"garbage","created_at":"garbage","work_dir":"%s/crew/worker"}]}' "$RIGDIR" > "$T/fake/sessions.raw"; run
                                                                                          expect "session with undatable timestamps is not acted on" 0 0
said "...and the skip is logged with the session name, not silent" 'skipped as UNKNOWN'
said "...and counted in the pass summary" 'skipped_unknown=1'
# an unreadable skip report must show as UNKNOWN ("?"), never as "0 skipped" — and must not block real work
baseline; run FAKE_SKIP_UNREADABLE=1 PATH="$T/shim2:$PATH";                              expect "skip report unreadable: the pass still does its work" 1 0
said   "...and says the skip count is UNKNOWN" 'is UNKNOWN'
said   "...and the summary shows '?', not 0" 'skipped_unknown=?'
baseline; run FAKE_CAND_LINE='wa-worker-adhoc-aaa|ga-wisp-aaa|a|s|wa-worker|/x|NOTANUMBER' PATH="$T/shim:$PATH"; expect "malformed candidate line (non-numeric idle age) is skipped, not read as idle" 0 0
said "...and says so" 'non-numeric idle age'

# ---- the pane leg ------------------------------------------------------------------------------------------
# Every pane below carries the "❯" prompt box, as every real one does. The first version of the guard called
# anything with that glyph IDLE, so a turn past 1 h (timer "1h 31m 47s") read as idle.
echo "P. pane classification (real panes + the shapes that fooled the first version)"
baseline; pane wa-worker-adhoc-aaa "$REAL_IDLE_PANE"; run;                                expect "REAL idle pane (summary 'Cooked for 1h 1m 30s', prompt box) => IDLE => nudged" 1 0
baseline; pane wa-worker-adhoc-aaa "$REAL_BUSY_PANE"; run;                                expect "REAL busy pane ('Kneading… (1h 31m 47s', prompt box) => BUSY" 0 0
said "...classified BUSY, not UNKNOWN" 'pane busy'
for dur in '45s' '15m 49s' '1h 6m 3s' '2h 0m 3s' '1h 10m 44s'; do
  baseline; pane wa-worker-adhoc-aaa $'✽ Kneading… ('"$dur"$' · ↓ 246.1k tokens)'"$CHROME"; run;  expect "spinner timer '($dur' => BUSY" 0 0
done
baseline; pane wa-worker-adhoc-aaa $'  Running… esc to interrupt'"$CHROME"; run;           expect "older build: only 'esc to interrupt' => BUSY" 0 0
baseline; pane wa-worker-adhoc-aaa $'✻ Pondering…'"$CHROME"; run;                         expect "spinner line whose timer we cannot read => UNKNOWN, not idle" 0 0
said "...classified UNKNOWN" 'pane UNKNOWN'
baseline; pane wa-worker-adhoc-aaa $'✻ Sautéing…'"$CHROME"; run;                          expect "spinner with a non-ASCII verb, no timer => UNKNOWN" 0 0
baseline; pane wa-worker-adhoc-aaa $'⏺ Vou verificar… e já volto\n'"$CHROME"; run;         expect "prose ellipsis in an assistant message is not a spinner => IDLE" 1 0
baseline; pane wa-worker-adhoc-aaa $'✻ Baked for 2h 3m 4s · done 9:50 AM'; run;           expect "turn summary with an hours unit, no prompt box => IDLE" 1 0
baseline; pane wa-worker-adhoc-aaa $'✻ Cogitated for 3m 21s'"$CHROME"; run;               expect "summary without hours (the shape the first version knew) => IDLE" 1 0

# ---- safety valves -----------------------------------------------------------------------------------------
echo "C. safety valves"
baseline; run DRY_RUN=1
n="$(calls_n nudge)"; sc="$(ls "$T/state/pool-idle-nobead" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n" = 0 ] && [ "$sc" = 0 ] && grep -q 'DRY_RUN would NUDGE' "$T/stdout"; then ok "DRY_RUN decides + logs, changes nothing, writes no state"; else bad "DRY_RUN leaked (nudges=$n state_files=$sc)"; fi
baseline; nudged_ago 700; run DRY_RUN=1
c="$(calls_n close)"; if [ "$c" = 0 ] && [ "$(cat "$SF")" = "nudged $((NOW - 700))" ] && grep -q 'DRY_RUN would CLOSE' "$T/stdout"; then ok "DRY_RUN would CLOSE: logs it, closes nothing, leaves the state untouched"; else bad "DRY_RUN close leaked (closes=$c)"; fi
baseline; : > "$T/state/pool-idle-nobead-guard.disabled"; run;                           expect "kill-switch file present" 0 0
baseline; flock -n "$T/lock" -c 'sleep 3' & LOCKER=$!; sleep 1; run;                    expect "another instance holds the lock" 0 0
wait "$LOCKER" 2>/dev/null

# ---- the two-stage timeline --------------------------------------------------------------------------------
echo "D. nudge -> grace -> close"
baseline; run; run;                                                                       expect "second pass right after the nudge does not nudge again" 1 0
baseline; nudged_ago 700; run;                                                            expect "nudged 700s ago, still idle + bead-less => CLOSE" 0 1
baseline; nudged_ago 300; run;                                                            expect "nudged only 300s ago (< grace 600) => wait" 0 0
baseline; nudged_ago 700; SESS_LINES=""; sess wa-worker-adhoc-aaa wa-worker 100; run;     expect "nudged long ago but it replied 100s ago (mid-conversation) => wait" 0 0
baseline; nudged_ago 2500; run;                                                           expect "our own state is stale (> 3x grace) => start over with a nudge, not a close" 1 0
baseline; nudged_ago 700; run POOL_IDLE_CLOSE=0;                                          expect "close stage disabled (POOL_IDLE_CLOSE=0)" 0 0
baseline; nudged_ago 700; bead_json in_progress wa-worker-adhoc-aaa whatsapp_automation list; run
c="$(calls_n close)"; if [ "$c" = 0 ] && [ ! -f "$SF" ]; then ok "it picked up a bead after the nudge => no close, nudge state cleared"; else bad "closed (or kept state for) a worker that now holds a bead (closes=$c)"; fi
baseline; nudged_ago 700; pane wa-worker-adhoc-aaa "$BUSY_PANE"; run;                    expect "nudged long ago but the pane is busy now => no close" 0 0
baseline; nudged_ago 700; pane wa-worker-adhoc-aaa "$REAL_BUSY_PANE"; run;               expect "nudged long ago, REAL busy pane (1h+ timer) => no close" 0 0
baseline; nudged_ago 700; run FAKE_BD_FAIL=1;                                             expect "ready to close but bd unreadable => no close (re-checked at close time)" 0 0
baseline; mkdir -p "$T/state/pool-idle-nobead"; echo "nudged $((NOW - 100))" > "$T/state/pool-idle-nobead/ghost-session.nudged"; run
[ ! -f "$T/state/pool-idle-nobead/ghost-session.nudged" ] && ok "state for a session that no longer exists is forgotten" || bad "stale state for a vanished session was kept"

# ---- the outcome of a close is verified, not assumed ---------------------------------------------------------
# `gc session close` returning 0 means gc accepted the request. The slot is free only if the session is no
# longer active/creating afterwards. The first version logged "pool slot released" on exit 0 alone.
echo "O. a close is only 'released' when the session list says so"
baseline; nudged_ago 700; run
expect "close taken => one close, no kill" 0 1
said   "...logged as RELEASED, with the evidence" 'slot RELEASED (verified'
[ ! -f "$SF" ] && ok "...and the nudge state is cleared" || bad "nudge state kept after a verified release"
said   "...and counted in the summary" 'released=1'
baseline; nudged_ago 700; run FAKE_CLOSE_KEEPS=1
expect "close returns 0 but the session stays active => the close was attempted" 0 1
said   "...logged as CLOSE-INEFFECTIVE (slot NOT released)" 'CLOSE-INEFFECTIVE'
unsaid "...and NEVER as released" 'slot RELEASED'
[ -f "$SF" ] && ok "...and the state is kept, so the next pass looks again" || bad "state forgotten although the slot is still held (the silent infinite-cycle shape)"
said   "...and counted in the summary" 'still_active=1'
baseline; nudged_ago 700; run FAKE_LIST_FAIL_AFTER_CLOSE=1
said   "list unreadable after the close => CLOSE-UNVERIFIED" 'CLOSE-UNVERIFIED'
unsaid "...and not claimed as released" 'slot RELEASED'
[ -f "$SF" ] && ok "...state kept" || bad "state forgotten although the outcome is unknown"
said   "...counted in the summary" 'unverified=1'
baseline; nudged_ago 700; run FAKE_CLOSE_FAIL=1
expect "close fails (rc 1) => attempted once" 0 1
said   "...logged as NOT CONFIRMED" 'close NOT CONFIRMED'
unsaid "...never as released" 'slot RELEASED'
[ -f "$SF" ] && ok "...state kept" || bad "state forgotten after a failed close"
baseline; nudged_ago 700; run FAKE_CLOSE_KEEPS=1; run FAKE_CLOSE_KEEPS=1
n="$(calls_n close)"; if [ "$n" = 2 ]; then ok "an ineffective close is retried on the next pass (loudly), not forgotten"; else bad "expected 2 close attempts over 2 passes, got $n"; fi

# ---- the nudge and the state it needs --------------------------------------------------------------------------
# The first version did `nudge && echo > state || ignore`: with an unwritable state dir it re-sent the same
# nudge every pass (an agent turn each) while logging NUDGED, and the grace period could never start.
echo "S. state that cannot be written / removed, and nudges that do not confirm"
baseline; rm -rf "$T/state"; : > "$T/state"        # $STATE_ROOT is a FILE: mkdir and every write fail (works as root too)
run; run; run
expect "state dir unusable, 3 passes => NO nudge at all (not 3 of them)" 0 0
said   "...says STATE-ERROR" 'STATE-ERROR'
said   "...counted in the pass summary" 'state_errors=1'
unsaid "...never claims it nudged" 'NUDGED'
if grep -qi 'not a directory\|permission denied\|No such file' "$T/log"; then bad "raw shell error text leaked into the log"; else ok "...no raw redirect/mkdir noise in the log"; fi
baseline; run FAKE_NUDGE_FAIL=1
expect "nudge call fails => it was attempted once" 1 0
said   "...logged as NOT CONFIRMED" 'nudge NOT CONFIRMED'
unsaid "...never as NUDGED" 'NUDGED'
[ "$(cat "$SF" 2>/dev/null)" = "nudging $NOW" ] && ok "...state stays 'nudging <ts>' (= not nudged)" || bad "state after a failed nudge: '$(cat "$SF" 2>/dev/null)'"
run
expect "...next pass (gc healthy again) nudges again, and does NOT close" 2 0
[ "$(cat "$SF" 2>/dev/null)" = "nudged $NOW" ] && ok "...and now the state is 'nudged'" || bad "state after the retry: '$(cat "$SF" 2>/dev/null)'"
baseline; run FAKE_NUDGE_SLEEP=3 POOL_IDLE_CALL_TIMEOUT=1
said   "nudge cut by the timeout (rc 124) is worded as UNCONFIRMED, not as a failure" '124 = timed out'
[ "$(cat "$SF" 2>/dev/null)" = "nudging $NOW" ] && ok "...state stays 'nudging' (it may or may not have been delivered)" || bad "state after a timed-out nudge: '$(cat "$SF" 2>/dev/null)'"
baseline; stage "nudging $((NOW - 700))"; run
expect "an unconfirmed 'nudging' record never leads to a close: it is retried as a nudge" 1 0
baseline; stage "garbage-not-a-state"; run
expect "a garbled state file counts as 'not nudged' => nudge, not close" 1 0
said   "...and says the file was garbled" 'garbled'
# removal failure: a bead shows up after the nudge, so the guard wants to forget the state — on a read-only dir it cannot
baseline; nudged_ago 700; bead_json in_progress wa-worker-adhoc-aaa whatsapp_automation list
chmod 555 "$T/state/pool-idle-nobead"
if [ -w "$T/state/pool-idle-nobead" ]; then echo "  ~ SKIP: cannot make a directory read-only here (running as a user that writes everywhere)"
else
  run
  said   "state file cannot be removed => STATE-ERROR, loudly" 'STATE-ERROR: cannot remove'
  said   "...and counted" 'state_errors=1'
  expect "...and nothing is closed meanwhile" 0 0
fi
chmod 755 "$T/state/pool-idle-nobead" 2>/dev/null

# ---- caps -----------------------------------------------------------------------------------------------------
echo "E. caps bound the blast radius"
baseline; SESS_LINES=""; for i in 1 2 3 4; do sess wa-worker-adhoc-w$i wa-worker 700; pane wa-worker-adhoc-w$i "$IDLE_PANE"; done; run; expect "4 eligible, MAX_NUDGES default 3" 3 0
baseline; SESS_LINES=""; for i in 1 2; do sess wa-worker-adhoc-w$i wa-worker 700; pane wa-worker-adhoc-w$i "$IDLE_PANE"; nudged_ago 700 wa-worker-adhoc-w$i; done; run; expect "2 ready to close, MAX_CLOSES default 1" 0 1
baseline; SESS_LINES=""; for i in 1 2 3 4; do sess wa-worker-adhoc-w$i wa-worker 700; pane wa-worker-adhoc-w$i "$IDLE_PANE"; done; run POOL_IDLE_PASS_BUDGET_SEC=-1; expect "pass budget spent => leaves every session for the next pass" 0 0
said   "...and says the budget was spent" 'pass budget'
baseline; SESS_LINES=""; sess ps-w ps-worker 700 active false "$T/gt/property_scrapers/crew/worker"
printf '{"rigs":[{"name":"gascity","path":"%s"},{"name":"property_scrapers","path":"%s"}]}' "$CITYDIR" "$T/gt/property_scrapers" > "$T/fake/rigs.json"; pane ps-w "$IDLE_PANE"; run; expect "ps-worker is covered too (rig derived from its work_dir)" 1 0

echo
echo "pool-idle-nobead-guard selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
