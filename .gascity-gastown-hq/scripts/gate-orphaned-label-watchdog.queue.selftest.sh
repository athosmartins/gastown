#!/usr/bin/env bash
# gate-orphaned-label-watchdog.queue.selftest.sh — ga-ljcbnms. End-to-end proof, with the REAL gate-orphaned-label-watchdog.sh run as a
# subprocess through its documented env seams, of what the in-file `--selftest` cannot show (it calls run_sweep directly and assigns
# PILOT_TEXT_LOG itself): the Pilot's log is found at its DEFAULT path under GOLW_HQ, GOLW_QUEUE_EVIDENCE_MIN is honoured, and a Pilot
# log that cannot be read (here: `tail` exits 3) leaves the alert exactly as it was before the QUEUED bucket existed.
# Stubs only: no bd, gc, notify or Pilot is touched. GOLW_SCRIPT_UNDER_TEST=<other copy> proves the selftest fails on older code.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${GOLW_SCRIPT_UNDER_TEST:-$HERE/gate-orphaned-label-watchdog.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/failbin" "$T/tmp" "$T/hq/.gc/logs"

# bd: `-C <store> list --json --limit 0` = the candidates, `list ... -l source-bead:<id>` = no gate artifact, `comment <id> --stdin` = logged
cat > "$T/bin/bd" <<'BDSTUB'
#!/usr/bin/env bash
verb="$3"; shift 3
if [ "$verb" = list ]; then
  if [[ "$*" == *"source-bead:"* ]]; then echo '[]'; else cat "$QS_CANDIDATES"; fi
elif [ "$verb" = comment ]; then
  cat > /dev/null; echo "comment:$1" >> "$QS_COMMENTS"
else
  echo '[]'
fi
BDSTUB
printf '#!/bin/sh\n[ "$1 $2" = "session list" ] && echo '"'"'{"sessions":[]}'"'"'\nexit 0\n' > "$T/bin/gc"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notify"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$T/failbin/tail"
chmod +x "$T/bin/bd" "$T/bin/gc" "$T/bin/notify" "$T/failbin/tail"

# the live wa-a2iz7b.1 shape (open, no assignee, routed, gate:needs-fix) and the Pilot's own line for it 10 min ago (local clock, no zone)
stamp() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
OLD_TS="$(date -u -v-10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date +%s)"
printf '[{"id":"wa-a2iz7b.1","status":"open","updated_at":"%s","metadata":{"gc.routed_to":"wa-worker"},"labels":["gate:needs-fix","gate:fix-attempt:1"]}]\n' "$OLD_TS" > "$T/candidates.json"
printf '[%s] [pilot-dispatcher] ga-5fn5p3: wa-a2iz7b.1 P2 cedida a P0/P1 de whatsapp_automation (P1 wa-p1 waits behind wa-worker 2/2) — not claimed, no writes this sweep\n' "$(stamp $((NOW - 600)))" > "$T/hq/.gc/logs/pilot-dispatcher.log"

run() {  # VAR=val args extend the env; one real run with a fresh state; leaves $T/comments (one line per bd comment) and $T/golw.log
  : > "$T/comments"; : > "$T/golw.log"; rm -f "$T/state.json"
  env "$@" TMPDIR="$T/tmp" GOLW_HQ="$T/hq" GOLW_STORES="$T/hq" GOLW_BD_BIN="$T/bin/bd" GOLW_GC_BIN="$T/bin/gc" GOLW_NOTIFY_BIN="$T/bin/notify" \
    GOLW_LOG="$T/golw.log" GOLW_STATE_DIR="$T" GOLW_STATE_FILE="$T/state.json" GOLW_JEV_EXPERIMENT_ENABLED=0 \
    QS_CANDIDATES="$T/candidates.json" QS_COMMENTS="$T/comments" bash "$SCRIPT" > "$T/out" 2>&1
}

echo "run 1: the Pilot's recent 'cedida' line sits at the DEFAULT path ($T/hq/.gc/logs/pilot-dispatcher.log) -> queued, not alerted"
run
[ ! -s "$T/comments" ] && ok "run 1: no comment on the queued bead" || bad "run 1: the bead the Pilot holds for capacity was commented (default log path or env binding broken)"
grep -q "QUEUED: 1 bead" "$T/golw.log" && ok "run 1: the log counts it as QUEUED" || bad "run 1: no QUEUED line in the watchdog log"

echo "run 2: GOLW_QUEUE_EVIDENCE_MIN=5 (the line is 10 min old) -> no proof, alerted as before"
run GOLW_QUEUE_EVIDENCE_MIN=5
grep -q "comment:wa-a2iz7b.1" "$T/comments" && ok "run 2: the bead is commented (the window env is honoured)" || bad "run 2: a 10-min-old line proved a 5-min window"

echo "run 3: tail exits 3 -> the proof cannot be read -> alerted as before, one WARN says why"
run PATH="$T/failbin:$PATH"
grep -q "comment:wa-a2iz7b.1" "$T/comments" && ok "run 3: the bead is commented although the Pilot log could not be read" || bad "run 3: an unreadable Pilot log hid the alert"
grep -q "WARN: ga-ljcbnms: reading the Pilot log" "$T/golw.log" && ok "run 3: the WARN names the failed read" || bad "run 3: no WARN about the failed read"
grep -q "QUEUED:" "$T/golw.log" && bad "run 3: QUEUED reported without a readable log" || ok "run 3: no QUEUED bucket without a readable log"

echo ""
echo "gate-orphaned-label-watchdog.queue selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
