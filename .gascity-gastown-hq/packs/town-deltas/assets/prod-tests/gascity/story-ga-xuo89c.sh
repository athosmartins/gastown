#!/usr/bin/env bash
# prod-tests/gascity/story-ga-xuo89c.sh — prod test for ga-xuo89c: the supervisor
# restart watchdog counts the supervisor's open fds every sample, records them,
# and — only above 40,000 — kickstarts it once per 30 minutes (stop-gap for the
# engine's fsnotify watch leak, ga-0ox5tq: the supervisor hit the 61,440 fd
# ceiling on 2026-10-13 and the city went ~1h30 without viable sessions).
#
# Verifies on the DEPLOYED $CITY/scripts/supervisor-restart-watchdog.sh (the file
# launchd runs in place), under /bin/bash 3.2 (the interpreter the plist names):
#   1. it parses under /bin/bash and has exactly ONE launchctl mutation — a
#      `kickstart -k` on the supervisor label, written after the cooldown stamp;
#   2. a REAL run of it against fake launchctl/lsof/tmux/notify in a throwaway
#      dir, with the DEFAULT thresholds: 100 fds -> recorded only; 40,001 fds ->
#      exactly one kickstart, notify -p 4, ledger evidence (new pid, fds_after,
#      tmux sessions before/after); an immediate second >40k -> cooldown, no
#      second kickstart; an lsof that fails/hangs -> fds:null and no kickstart.
#      The fakes sit first on PATH, so the real supervisor is never touched.
# The feature's own selftest (70+ assertions, minutes at this city's load) is NOT
# re-run here; set RUN_FULL_SELFTEST=1 to include it.
# Informational only (never fails): whether the live launchd job runs this file
# and whether the live ledger already carries the `fds` field (AC2 — the job is a
# StartInterval=900 one, so the first record with it lands within 15 min of the
# deploy), and whether a real >40k event has already left its evidence (AC3 —
# that one only exists after the first real event).
#
# Called by run.sh after deploy (STORY_ID=ga-xuo89c). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
WD="$CITY/scripts/supervisor-restart-watchdog.sh"
SELFTEST="$CITY/scripts/supervisor-restart-watchdog.selftest.sh"
LABEL="com.gascity.supervisor-restart-watchdog"
LIVE_LEDGER="$CITY/.gc/logs/supervisor-restart-watchdog.jsonl"

log()  { echo "[prod-test:gascity ga-xuo89c] $*"; }
fail() { echo "[prod-test:gascity ga-xuo89c] FAIL: $*" >&2; exit 1; }

[[ -f "$WD" ]] || fail "watchdog missing: $WD"
command -v jq >/dev/null 2>&1 || fail "jq not on PATH"

log "Checking the deployed watchdog parses under /bin/bash (what launchd runs)..."
/bin/bash -n "$WD" || fail "$WD does not parse under /bin/bash (3.2)"
log "  parses ✓"

log "Checking the only launchctl mutation is the guarded kickstart..."
CODE="$(grep -vE '^[[:space:]]*#' "$WD")"
KS="$(printf '%s\n' "$CODE" | grep -cE 'launchctl[[:space:]]+kickstart')"
[[ "$KS" == "1" ]] || fail "expected exactly one 'launchctl kickstart' in the code, found $KS"
printf '%s\n' "$CODE" | grep -qE 'launchctl kickstart -k "gui/\$\{UID_NUM\}/\$\{SUPERVISOR_LABEL\}"' \
  || fail "the kickstart is not 'kickstart -k gui/\${UID_NUM}/\${SUPERVISOR_LABEL}'"
if printf '%s\n' "$CODE" | grep -qE 'launchctl[[:space:]]+(bootout|bootstrap|unload|load|stop|start|kill|remove|disable|enable)|pkill|killall'; then
  fail "the watchdog contains a launchctl bootout/unload/stop-style call or a pkill"
fi
L_STAMP="$(printf '%s\n' "$CODE" | grep -n '_srw_guard_state_write "\$RUNS"' | head -1 | cut -d: -f1)"
L_KICK="$(printf '%s\n' "$CODE" | grep -n 'launchctl kickstart' | head -1 | cut -d: -f1)"
[[ -n "$L_STAMP" && -n "$L_KICK" && "$L_STAMP" -lt "$L_KICK" ]] \
  || fail "the cooldown stamp (line ${L_STAMP:-none}) must be written before the kickstart (line ${L_KICK:-none})"
log "  one kickstart -k on the supervisor label, cooldown stamped before it ✓"

log "Running the deployed watchdog against fake launchctl/lsof/tmux/notify (default thresholds, state in a throwaway dir)..."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/story-ga-xuo89c.XXXXXX")" || fail "cannot create a scratch dir"
trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/fakebin"; mkdir -p "$FAKE" "$WORK/tmp" "$WORK/city"
: > "$WORK/supervisor.log"

cat > "$FAKE/launchctl" <<'FAKE'
#!/bin/bash
D="$FAKE_DIR"
if [ "${1:-}" = "print" ]; then
  printf '\truns = 7\n\tpid = %s\n\tlast exit code = 0\n' "$(cat "$D/pid" 2>/dev/null || echo 4242)"
  exit 0
fi
if [ "${1:-}" = "kickstart" ]; then
  printf '%s\n' "$*" >> "$D/kickstart.log"
  : > "$D/kicked"
  echo $(( $(cat "$D/pid" 2>/dev/null || echo 4242) + 1 )) > "$D/pid"
  exit 0
fi
exit 1
FAKE
cat > "$FAKE/lsof" <<'FAKE'
#!/bin/bash
N="${FAKE_LSOF_FDS:-100}"
[ -e "$FAKE_DIR/kicked" ] && N=300
case "${FAKE_LSOF_MODE:-ok}" in
  fail) echo "lsof: boom" >&2; exit 2 ;;
  slow) sleep 30; exit 0 ;;
esac
printf 'COMMAND     PID  USER   FD     TYPE\n'
awk -v n="$N" 'BEGIN { for (i = 0; i < n; i++) printf "gc 4242 athos %dr REG 1,4 0 1 /x/%d\n", i + 3, i }'
printf 'gc 4242 athos cwd DIR 1,4 0 2 /\ngc 4242 athos txt REG 1,4 0 3 /bin/gc\n'
FAKE
cat > "$FAKE/tmux" <<'FAKE'
#!/bin/bash
awk 'BEGIN { for (i = 0; i < 9; i++) print "x" }'
FAKE
cat > "$FAKE/notify" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/notify.log"
FAKE
chmod +x "$FAKE"/*

# one watchdog run as launchd would do it (/bin/bash), PATH-isolated from the real tools
run_wd() {
  env PATH="$FAKE:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin" \
      GC_CITY_PATH="$WORK/city" GC_SUPERVISOR_LOG="$WORK/supervisor.log" TMPDIR="$WORK/tmp" \
      FAKE_DIR="$WORK/fake" SRW_LSOF_TIMEOUT=2 "$@" /bin/bash "$WD" >"$WORK/last.out" 2>&1
}
mkdir -p "$WORK/fake"
LEDGER="$WORK/city/.gc/logs/supervisor-restart-watchdog.jsonl"
last() { tail -1 "$LEDGER"; }
nlines() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }

run_wd FAKE_LSOF_FDS=100
R="$(last)"
[[ "$(jq -r .fds <<<"$R")" == "100" && "$(jq -r .guard_action <<<"$R")" == "none" && "$(jq -r .fds_state <<<"$R")" == "ok" ]] \
  || { tail -5 "$WORK/last.out" >&2; fail "100 fds should be recorded as fds=100 with no action: $R"; }
[[ "$(nlines "$WORK/fake/kickstart.log")" == "0" ]] || fail "a kickstart happened at 100 fds"
log "  100 fds -> fds=100 in the ledger, no action ✓"

run_wd FAKE_LSOF_FDS=40001
R="$(last)"
[[ "$(nlines "$WORK/fake/kickstart.log")" == "1" ]] || { tail -5 "$WORK/last.out" >&2; fail "40001 fds: expected exactly 1 kickstart, got $(nlines "$WORK/fake/kickstart.log")"; }
grep -qx "kickstart -k gui/$(id -u)/com.gascity.supervisor" "$WORK/fake/kickstart.log" \
  || fail "the kickstart was not 'kickstart -k gui/<uid>/com.gascity.supervisor': $(cat "$WORK/fake/kickstart.log")"
[[ "$(jq -r .guard_action <<<"$R")" == "restart_ok" && "$(jq -r .restart_new_pid <<<"$R")" == "4243" \
   && "$(jq -r .fds_after <<<"$R")" == "300" && "$(jq -r .sessions_before <<<"$R")" == "9" && "$(jq -r .sessions_after <<<"$R")" == "9" ]] \
  || fail "40001 fds: the ledger lacks the restart evidence (new pid / fds_after / sessions before+after): $R"
[[ "$(nlines "$WORK/fake/notify.log")" == "1" ]] && grep -q -- '-p 4 ' "$WORK/fake/notify.log" \
  || fail "40001 fds: expected one notify at priority 4: $(cat "$WORK/fake/notify.log" 2>/dev/null)"
log "  40,001 fds -> one 'kickstart -k', notify -p 4, ledger: new pid 4243, fds_after 300, tmux sessions 9 -> 9 ✓"

rm -f "$WORK/fake/kicked" "$WORK/fake/pid"     # the fake supervisor comes back leaking
run_wd FAKE_LSOF_FDS=45000
R="$(last)"
[[ "$(jq -r .guard_action <<<"$R")" == "cooldown" && "$(nlines "$WORK/fake/kickstart.log")" == "1" ]] \
  || fail "a second >40k reading inside 30 minutes must not restart again: $R"
log "  >40k again right away -> cooldown, still one kickstart ✓"

for MODE in fail slow; do
  C2="$WORK/city2-$MODE"; mkdir -p "$C2"
  env PATH="$FAKE:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin" \
      GC_CITY_PATH="$C2" GC_SUPERVISOR_LOG="$WORK/supervisor.log" TMPDIR="$WORK/tmp" \
      FAKE_DIR="$WORK/fake" FAKE_LSOF_MODE=$MODE SRW_LSOF_TIMEOUT=2 /bin/bash "$WD" >"$WORK/last.out" 2>&1
  R="$(tail -1 "$C2/.gc/logs/supervisor-restart-watchdog.jsonl")"
  [[ "$(jq -r .fds <<<"$R")" == "null" && "$(jq -r .guard_action <<<"$R")" == "unreadable" && "$(nlines "$WORK/fake/kickstart.log")" == "1" ]] \
    || fail "lsof $MODE: expected fds:null, unreadable, and no new kickstart: $R"
done
log "  lsof failing / hanging -> fds:null, guard_action=unreadable, no kickstart ✓"

# every record carries the field AC2 asks for
BAD="$(jq -c 'select((has("fds") and has("fds_state") and has("guard_action")) | not)' "$LEDGER" | wc -l | tr -d ' ')"
[[ "$BAD" == "0" ]] || fail "$BAD ledger record(s) without fds/fds_state/guard_action"
log "  every synthetic ledger record carries fds/fds_state/guard_action ✓"

if [[ "${RUN_FULL_SELFTEST:-0}" == "1" ]]; then
    [[ -f "$SELFTEST" ]] || fail "selftest missing: $SELFTEST"
    log "Running the full selftest (several minutes)..."
    /bin/bash "$SELFTEST" >"$WORK/selftest.out" 2>&1 || { tail -20 "$WORK/selftest.out" >&2; fail "selftest did not pass on the deployed artifact"; }
    log "  selftest PASS ✓"
fi

# ── informational: is the LIVE job this file, and has it started recording fds? ─
# Captured, not piped into grep -q (gate ga-h2gdd2): launchctl output is large,
# grep -q exits at the first match, launchctl takes SIGPIPE and pipefail turns a
# MATCH into "not found".
LAUNCHCTL_PRINT="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"
if [[ -z "$LAUNCHCTL_PRINT" ]]; then
    log "  (info) live job $LABEL is not loaded on this host"
elif [[ "$LAUNCHCTL_PRINT" == *"$WD"* ]]; then
    log "  (info) live job $LABEL runs this file ✓"
else
    log "  (info) live job $LABEL is loaded but its program path was not confirmed as $WD — check 'launchctl print gui/$(id -u)/$LABEL'"
fi
if [[ -s "$LIVE_LEDGER" ]]; then
    LIVE_LAST="$(tail -1 "$LIVE_LEDGER")"
    if [[ "$(jq -r 'has("fds")' <<<"$LIVE_LAST" 2>/dev/null)" == "true" ]]; then
        log "  (info) live ledger's last record has fds=$(jq -r .fds <<<"$LIVE_LAST") (fds_state=$(jq -r .fds_state <<<"$LIVE_LAST")) ✓"
    else
        log "  (info) live ledger's last record has no fds field yet — the next 15-min cycle after this deploy writes it"
    fi
    EVENTS="$(jq -c 'select((.guard_action // "") | test("^restart"))' "$LIVE_LEDGER" 2>/dev/null | wc -l | tr -d ' ')"
    log "  (info) real fd-guard restarts in the live ledger so far: ${EVENTS} (AC3 evidence appears only after the first real >40k event)"
else
    log "  (info) no live ledger at $LIVE_LEDGER"
fi

log "PASS — deployed watchdog records fds every sample, kickstarts only above 40,000, at most once per 30 minutes, and never on an unread count"
exit 0
