#!/usr/bin/env bash
# wa-root-main-guard.selftest.sh — regression harness for wa-root-main-guard.sh (ga-a7mti1).
#
# ## Contents
#   What it pins · How it runs
#
# WHAT IT PINS. Since 10/10 the live WA clone sits on a DETACHED HEAD at origin/main (the updater merges origin/main
# onto it). The guard read only the branch NAME, so "detached at origin/main" (healthy) and "detached on code nobody
# reviewed" (the 24/10 incident) printed the same WARN line, 10161 times in October, and the restore of a crew branch
# left in the root never ran again. Pinned here:
#   S1-S3   attached to main / detached at origin/main / detached on an older reviewed commit: silent (no line,
#           no notify, no output, exit 0, no state file left)
#   S4-S6   detached on a commit NOT reachable from origin/main: nothing on the 1st cycle, ONE OFF-MAIN-DETACHED line
#           + ONE notify on the 2nd consecutive cycle, then one per window (60 min); a hop between unreviewed shas is
#           the same episode; the root is never touched (no switch, no backup tag)
#   S7      the episode ends when the root is back on origin/main (or by hand on main): one CLEARED line, no notify;
#           a blip that is not on consecutive cycles never alerts
#   S8-S10  "cannot tell" (origin/main gone, merge-base fails, HEAD unreadable): UNKNOWN-DETACHED, visible, never filed
#           as healthy and never as off-main
#   S11     an alert that cannot be remembered (state path unwritable) is loud on the first cycle, not silent, and says
#           so instead of promising a window; S11b the same when there is no usable clock
#   S12     a crew branch left in the root is still backed up and restored
#   S13     the production defaults of the test seams are the real paths
# HOW. Real git: a bare "origin" plus a clone as the live root, in a throwaway dir. The guard runs as a subprocess
# with WA_ROOT_GUARD_{ROOT,CITY,HOOKS,NOW} pointing there and a fake `notify` first on PATH; nothing under /Users/athos
# is read, no network, no daemons. WRMG_GUARD=<path> runs the harness against another copy of the guard (that is how it
# is shown to fail on the pre-fix script).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GUARD="${WRMG_GUARD:-$SCRIPT_DIR/wa-root-main-guard.sh}"
REAL_GIT="$(command -v git)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wrmg-selftest.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
# git must not climb out of the fixtures into an enclosing repo (a corrupted HEAD makes it look upward) nor pick up
# a repo from the caller's environment.
export GIT_CEILING_DIRECTORIES="$TMP"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ok: $*"; }
bad()   { FAIL=$((FAIL+1)); echo "  BAD: $*"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }
has()   { if [ -f "$2" ] && grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: no '$3' in $2"; fi; }
hasnt() { if [ -f "$2" ] && grep -qF -- "$3" "$2"; then bad "$1: found '$3' in $2"; else ok "$1"; fi; }
nl()    { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }   # a missing file is 0 lines

fx() { git -C "$ROOT" -c core.hooksPath=/dev/null "$@"; }

# mk_world <name> — globals W ROOT CITY BIN LOG STATE NOTES M2 M3 U U2: a live root on main with 3 commits pushed to
# a bare origin (M2 older, M3 = origin/main) plus two local-only commits U, U2 that no branch of origin contains.
mk_world() {
  W="$TMP/$1"; ROOT="$W/root"; CITY="$W/city"; BIN="$W/bin"
  LOG="$CITY/.gc/logs/wa-root-main-guard.log"; STATE="$CITY/.gc/wa-root-main-guard.state"; NOTES="$W/notify.log"
  mkdir -p "$CITY/.gc/logs" "$BIN" "$W/hooks"; : > "$NOTES"
  cat > "$BIN/notify" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NOTIFY_LOG:-/dev/null}"
EOF
  chmod +x "$BIN/notify"
  "$REAL_GIT" init -q --bare "$W/origin.git"; "$REAL_GIT" -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$W/origin.git" "$ROOT" 2>/dev/null
  fx symbolic-ref HEAD refs/heads/main
  fx config user.email selftest@local; fx config user.name selftest; fx config commit.gpgsign false
  local i
  for i in 1 2 3; do
    echo "v$i" > "$ROOT/f.txt"; fx add f.txt; fx commit -q -m "c$i"
    if [ "$i" = 2 ]; then M2="$(fx rev-parse HEAD)"; fi
  done
  M3="$(fx rev-parse HEAD)"
  fx push -q origin main 2>/dev/null
  fx checkout -q -b side
  echo u1 > "$ROOT/u.txt"; fx add u.txt; fx commit -q -m u1; U="$(fx rev-parse HEAD)"
  echo u2 >> "$ROOT/u.txt"; fx add u.txt; fx commit -q -m u2; U2="$(fx rev-parse HEAD)"
  fx checkout -q main
}

# cycle <k> [VAR=val ...] — the k-th guard run, 114 s apart on the fake clock; sets RC.
T0=1800000000
cycle() {
  local k="$1"; shift
  env PATH="$BIN:$PATH" NOTIFY_LOG="$NOTES" WA_ROOT_GUARD_ROOT="$ROOT" WA_ROOT_GUARD_CITY="$CITY" \
      WA_ROOT_GUARD_HOOKS="$W/hooks" WA_ROOT_GUARD_ENABLED=1 WA_ROOT_GUARD_NOW=$((T0 + 114 * k)) "$@" \
      bash "$GUARD" >"$W/out" 2>"$W/err"
  RC=$?
}

echo "S1: attached to main"
mk_world s1
for k in 1 2 3; do cycle $k; done
eq "S1 exit code" "$RC" 0
eq "S1 log lines" "$(nl "$LOG")" 0
eq "S1 notifications" "$(nl "$NOTES")" 0

echo "S2: detached at origin/main — the healthy state since 10/10"
mk_world s2; fx checkout -q --detach "$M3"
for k in 1 2 3; do cycle $k; done
eq "S2 exit code" "$RC" 0
eq "S2 log lines (the pre-fix guard wrote one WARN per cycle)" "$(nl "$LOG")" 0
eq "S2 notifications" "$(nl "$NOTES")" 0
if [ ! -s "$W/out" ] && [ ! -s "$W/err" ]; then ok "S2 prints nothing"; else bad "S2 printed: $(cat "$W/out" "$W/err")"; fi
if [ ! -e "$STATE" ]; then ok "S2 leaves no episode state"; else bad "S2 left $STATE"; fi

echo "S3: detached on an older commit that origin/main contains (a rollback to reviewed code)"
mk_world s3; fx checkout -q --detach "$M2"
for k in 1 2 3; do cycle $k; done
eq "S3 log lines" "$(nl "$LOG")" 0
eq "S3 notifications" "$(nl "$NOTES")" 0

echo "S4: detached on code origin/main does not contain (the 24/10 incident), left there"
mk_world s4; fx checkout -q --detach "$U"
cycle 1
eq "S4 cycle 1 (first sighting) log lines" "$(nl "$LOG")" 0
eq "S4 cycle 1 notifications" "$(nl "$NOTES")" 0
cycle 2
eq "S4 cycle 2 (second consecutive) log lines" "$(nl "$LOG")" 1
has "S4 the line is the distinct OFF-MAIN-DETACHED" "$LOG" "OFF-MAIN-DETACHED"
has "S4 the line carries the sha" "$LOG" "$(fx rev-parse --short "$U")"
eq "S4 cycle 2 notifications" "$(nl "$NOTES")" 1
for k in 3 4 5; do cycle $k; done
eq "S4 cycles 3-5 log lines (one alert per window, not per cycle)" "$(nl "$LOG")" 1
eq "S4 cycles 3-5 notifications" "$(nl "$NOTES")" 1
eq "S4 exit code" "$RC" 0
eq "S4 detection only: the root is still on the unreviewed sha" "$(fx rev-parse HEAD)" "$U"
eq "S4 detection only: no backup tag" "$(fx tag -l 'wa-root-guard-backup-*' | wc -l | tr -d ' ')" 0

echo "S5: one alert per window (60 min), then one more"
A=$((T0 + 114 * 2))   # when S4's alert fired
cycle 6 WA_ROOT_GUARD_NOW=$((A + 3599))
eq "S5 1 s before the window ends: no new line" "$(nl "$LOG")" 1
cycle 7 WA_ROOT_GUARD_NOW=$((A + 3600))
eq "S5 window over: one more line" "$(nl "$LOG")" 2
eq "S5 window over: one more notification" "$(nl "$NOTES")" 2
eq "S5 both lines are OFF-MAIN-DETACHED" "$(grep -c 'OFF-MAIN-DETACHED' "$LOG")" 2
cycle 8 WA_ROOT_GUARD_NOW=$((A + 3700))
eq "S5 next cycle inside the new window: silent" "$(nl "$LOG")" 2

echo "S6: HEAD hops between unreviewed shas — still one episode"
mk_world s6; fx checkout -q --detach "$U"; cycle 1; fx checkout -q --detach "$U2"; cycle 2
eq "S6 the 2nd consecutive off-main cycle alerts although the sha changed" "$(nl "$LOG")" 1
has "S6 the line names the sha the root is on now" "$LOG" "$(fx rev-parse --short "$U2")"

echo "S7: the episode ends when the root is back on origin/main"
mk_world s7; fx checkout -q --detach "$U"; cycle 1; cycle 2
eq "S7 the alert fired" "$(nl "$LOG")" 1
fx checkout -q --detach "$M3"; cycle 3
has "S7 recovery is logged" "$LOG" "CLEARED"
eq "S7 recovery adds exactly one line" "$(nl "$LOG")" 2
eq "S7 recovery does not notify" "$(nl "$NOTES")" 1
if [ ! -e "$STATE" ]; then ok "S7 episode state removed"; else bad "S7 state left behind"; fi
cycle 4; cycle 5
eq "S7 afterwards silent" "$(nl "$LOG")" 2

echo "S7b: back on main by hand also ends it"
mk_world s7b; fx checkout -q --detach "$U"; cycle 1; cycle 2; fx checkout -q main; cycle 3
has "S7b CLEARED after a hand restore" "$LOG" "CLEARED"
eq "S7b log lines" "$(nl "$LOG")" 2

echo "S7c: off, on, off is not >1 consecutive cycle"
mk_world s7c; fx checkout -q --detach "$U"; cycle 1; fx checkout -q --detach "$M3"; cycle 2; fx checkout -q --detach "$U"; cycle 3
eq "S7c a healthy cycle in between resets the count: no line" "$(nl "$LOG")" 0
cycle 4
eq "S7c off, on, off, off: now two in a row" "$(nl "$LOG")" 1

echo "S8: origin/main missing — cannot tell, must not be filed as healthy"
mk_world s8; fx checkout -q --detach "$M3"; fx update-ref -d refs/remotes/origin/main
cycle 1
eq "S8 cycle 1 log lines" "$(nl "$LOG")" 0
cycle 2
eq "S8 cycle 2 log lines" "$(nl "$LOG")" 1
has "S8 the line is UNKNOWN-DETACHED" "$LOG" "UNKNOWN-DETACHED"
hasnt "S8 not reported as off-main" "$LOG" "OFF-MAIN-DETACHED"
eq "S8 notified" "$(nl "$NOTES")" 1

echo "S9: merge-base itself fails"
mk_world s9; fx checkout -q --detach "$U"
cat > "$BIN/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "--is-ancestor" ]; then echo "fatal: injected failure" >&2; exit 128; fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN/git"
cycle 1; cycle 2
eq "S9 log lines" "$(nl "$LOG")" 1
has "S9 the line is UNKNOWN-DETACHED" "$LOG" "UNKNOWN-DETACHED"
hasnt "S9 not reported as off-main" "$LOG" "OFF-MAIN-DETACHED"
eq "S9 notified" "$(nl "$NOTES")" 1

echo "S10: HEAD unreadable"
mk_world s10; fx checkout -q --detach "$U"; printf 'garbage\n' > "$ROOT/.git/HEAD"
cycle 1; cycle 2
eq "S10 log lines" "$(nl "$LOG")" 1
has "S10 the line is UNKNOWN-DETACHED" "$LOG" "UNKNOWN-DETACHED"
hasnt "S10 not reported as off-main" "$LOG" "OFF-MAIN-DETACHED"
eq "S10 notified" "$(nl "$NOTES")" 1

echo "S11: the state path is unwritable — the alert must not wait for a confirmation it cannot remember"
mk_world s11; fx checkout -q --detach "$U"; mkdir -p "$STATE"
cycle 1
has "S11 alert on the first cycle" "$LOG" "OFF-MAIN-DETACHED"
eq "S11 notified on the first cycle" "$(nl "$NOTES")" 1
has "S11 the line says why it will alert again" "$LOG" "Episode state unwritable"
hasnt "S11 and does not promise a window it cannot keep" "$LOG" "Next alert in"

echo "S11b: no usable clock — no window can be kept, so the alert must not go quiet"
mk_world s11b; fx checkout -q --detach "$U"
printf '#!/bin/sh\nexit 1\n' > "$BIN/date"; chmod +x "$BIN/date"
cycle 1 WA_ROOT_GUARD_NOW=; cycle 2 WA_ROOT_GUARD_NOW=; cycle 3 WA_ROOT_GUARD_NOW=
eq "S11b alerts on the 2nd and the 3rd cycle" "$(nl "$LOG")" 2
has "S11b says there is no window" "$LOG" "No usable clock"

echo "S12: a crew branch left in the root is still backed up and restored"
mk_world s12; fx checkout -q -b crew/x; echo w > "$ROOT/w.txt"; fx add w.txt; fx commit -q -m crewwork
CREW="$(fx rev-parse --short HEAD)"
cycle 1
eq "S12 root is back on main" "$(fx rev-parse --abbrev-ref HEAD)" main
has "S12 RESTORED is logged" "$LOG" "RESTORED"
eq "S12 the divergent HEAD is on a backup tag" "$(fx tag -l "wa-root-guard-backup-$CREW" | wc -l | tr -d ' ')" 1
eq "S12 notified" "$(nl "$NOTES")" 1

echo "S13: the production defaults of the seams are the real paths"
has "S13 default ROOT" "$GUARD" 'WA_ROOT_GUARD_ROOT:-/Users/athos/gt/whatsapp_automation'
has "S13 default CITY" "$GUARD" 'WA_ROOT_GUARD_CITY:-/Users/athos/gt/.gascity-gastown-hq'
has "S13 default HOOKS" "$GUARD" 'WA_ROOT_GUARD_HOOKS:-/tmp/empty-hooks'

echo ""
echo "──────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
