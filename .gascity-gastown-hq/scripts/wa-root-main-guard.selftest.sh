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
#   S0      the harness itself: an unusable scratch dir stops it (rc 2) without deleting the caller's cwd, and a guard
#           without the WA_ROOT_GUARD_ROOT/_CITY seams (it would act on the LIVE root) is refused (rc 2)
#   S1-S3   attached to main / detached at origin/main / detached on an older reviewed commit: silent (no line,
#           no notify, no output, exit 0, no state file left)
#   S4-S6   detached on a commit NOT reachable from origin/main: nothing on the 1st cycle, ONE OFF-MAIN-DETACHED line
#           + ONE notify on the 2nd consecutive cycle, then one per window (60 min); a hop between unreviewed shas is
#           the same episode; the root is never touched (no switch, no backup tag)
#   S5b     a clock that steps back past the last alert alerts again (a window in the future cannot be trusted)
#   S7      the episode ends when the root is back on origin/main (or by hand on main): one CLEARED line, no notify;
#           a blip that is not on consecutive cycles never alerts; S7d the root moving to a crew branch is not "back on
#           reviewed code"; S7e an alert that carried no timestamp (no clock) is still closed
#   S8-S10  "cannot tell" (origin/main gone, merge-base fails, HEAD unreadable): UNKNOWN-DETACHED, visible, never filed
#           as healthy and never as off-main. S10-S10c run with the root NESTED in a repo on main (the production
#           topology: whatsapp_automation inside the HQ) and the harness ceiling off: a broken or missing .git of the
#           root must not be read as the outer repo's main, also when the root is reached through a symlink
#   S11     an alert that cannot be remembered (state path unwritable) is loud on the first cycle, not silent, and says
#           so instead of promising a window; S11b the same when there is no usable clock; S11c an episode that began
#           with no clock reports its age as unknown ("?"), not ~30 million minutes
#   S12     a crew branch left in the root is still backed up and restored
#   S13     the production defaults of the test seams are the real paths
#   S14     a notify that fails does not spend the alert window: the next cycle retries, and the line says it failed
#   S15     a corrupt episode state file counts as no episode: the first cycle after it is silent, the next one alerts, the
#           root is never touched. Corrupt includes a field with a leading zero (08 is an invalid octal in $(( ))) and one
#           past 12 digits (a huge last_alarm silenced the alert for good)
#   S16     a window knob with a leading zero is decimal (08 = 8 min, 010 = 10 min), a 13-digit one is the default; and a
#           bad number never makes the script fall through to the branch restore (backup tag, CLEARED, root moved)
#   S17     the net behind S16: with an arithmetic fault INJECTED into a copy of the guard, the handler's abort ends the run
#           inert (a WARN line, rc 0, the root untouched), not in the restore
#   S18-S25 (ga-u6ueg0q) the paths the first seventeen leave at their defaults: S18 the kill switch reports a crew branch and leaves it; S19 a
#           `git switch main` that fails forces nothing, says so and ends 0; S20 a fetch that fails does not stop the restore and is a WARN,
#           while S12 pins that a fetch that worked is not; S21 the guard drops the stash entry IT made, never an unrelated one; S22 a state
#           file without its last newline still counts; S23 the age in the alert and in CLEARED (2 h, 0 min, a start in the future); S24 an
#           alert made at this very second is neither in the future nor spent; S25 no notify on PATH: log only, rc=1, window not spent
#   EQUIVALENT  read_state and clear_episode return 0 on "no episode", and swapping that for 1 changes nothing: every caller runs them as a
#           statement and the guard has no `set -e`. The two early exits `[ -f "$STATE" ] || return 0` and `[ -e "$STATE" ] || return 0` and the
#           `|| return 0` after the read can be dropped without a visible difference: with no file the read fails with k empty, and an empty k
#           reaches the case's `*) return 0` (or, in clear_episode, finds nothing to remove and no episode to close).
# HOW. Real git: a bare "origin" plus a clone as the live root, in a throwaway dir. The guard runs as a subprocess
# with WA_ROOT_GUARD_{ROOT,CITY,HOOKS,NOW} pointing there and a fake `notify` first on PATH; nothing under /Users/athos
# is read, no network, no daemons. WRMG_GUARD=<path> runs the harness against another copy of the guard — that is how it
# is shown to fail on a previous revision of THIS script (git show <rev>:<path> > copy). The copy must have the
# WA_ROOT_GUARD_ROOT/_CITY seams: the harness refuses one that does not (rc 2), because the script before ga-a7mti1 hard-codes
# the production paths and would run on the live root.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
GUARD="${WRMG_GUARD:-$SCRIPT_DIR/wa-root-main-guard.sh}"
# vazio/ausente (o guard não existe) → recusa, rc 2; falhou/ilegível → idem. Um guard sem as duas seams (o script anterior à
# ga-a7mti1 fixa os caminhos de produção) rodaria no root VIVO: recusado antes de qualquer cenário.
if [ ! -r "$GUARD" ] || ! grep -qF 'WA_ROOT_GUARD_ROOT' "$GUARD" || ! grep -qF 'WA_ROOT_GUARD_CITY' "$GUARD"; then
  echo "refusing to run: $GUARD is unreadable or lacks the WA_ROOT_GUARD_ROOT/_CITY seams — it would act on the LIVE root" >&2
  exit 2
fi
REAL_GIT="$(command -v git)"
# vazio/falhou (mktemp não criou o diretório) → rc 2 ANTES do trap: `cd ""` dá certo no bash (3.2 e 5), TMP viraria o cwd e o trap o apagaria
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wrmg-selftest.XXXXXX")" || { echo "mktemp failed — no scratch dir" >&2; exit 2; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "mktemp returned no directory" >&2; exit 2; }
TMP="$(cd "$TMP" && pwd -P)" || exit 2
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
# NOTIFY_FAIL=1 → the channel is down: non-zero exit, nothing taken. The log only counts what notify accepted (rc 0).
[ -n "${NOTIFY_FAIL:-}" ] && exit 1
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

# mk_nested <name> — mk_world, plus an enclosing repo on main at $W: production's root lives INSIDE another repo
# (/Users/athos/gt, the HQ, on main), and that is what a git that loses sight of the root's own .git climbs into.
mk_nested() {
  mk_world "$1"
  "$REAL_GIT" init -q "$W"; "$REAL_GIT" -C "$W" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$W" -c user.email=selftest@local -c user.name=selftest -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --allow-empty -m outer
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

echo "S0: the harness stops before anything can hurt — no scratch dir, or a guard that would act on the live root"
mkdir -p "$TMP/s0"; : > "$TMP/s0/marker"
( cd "$TMP/s0" && TMPDIR="$TMP/no-such-dir" bash "$SELF" >"$TMP/s0.out" 2>&1 ); S0RC=$?
eq "S0 unusable TMPDIR: the run stops with rc 2" "$S0RC" 2
if [ -e "$TMP/s0/marker" ]; then ok "S0 unusable TMPDIR: the caller's cwd is intact (the old idiom made it the scratch dir and deleted it)"
else bad "S0 unusable TMPDIR: the harness deleted its own cwd"; fi
printf '#!/bin/sh\necho "I ran on the live root"\n' > "$TMP/s0/noseam.sh"
WRMG_GUARD="$TMP/s0/noseam.sh" bash "$SELF" >"$TMP/s0.out" 2>&1; S0RC=$?
eq "S0 a guard without the WA_ROOT_GUARD_ROOT seam is refused (rc 2)" "$S0RC" 2
hasnt "S0 ... before any scenario runs" "$TMP/s0.out" "S1:"
WRMG_GUARD="$TMP/s0/no-such-guard.sh" bash "$SELF" >"$TMP/s0.out" 2>&1; S0RC=$?
eq "S0 a guard that does not exist is refused (rc 2)" "$S0RC" 2

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

echo "S5b: the clock steps back after an alert — a window that lies in the future cannot be trusted, so alert again"
mk_world s5b; fx checkout -q --detach "$U"; cycle 1; cycle 2
A=$((T0 + 114 * 2))   # when the alert fired
eq "S5b the alert fired" "$(nl "$NOTES")" 1
cycle 3 WA_ROOT_GUARD_NOW=$((A - 1000))
eq "S5b clock 1000 s behind the last alert: alerts again (the old test said -1000 < 3600, silent)" "$(nl "$LOG")" 2
eq "S5b ... and notifies" "$(nl "$NOTES")" 2
cycle 4 WA_ROOT_GUARD_NOW=$((A - 1000 + 114))
eq "S5b the new window starts at the stepped-back clock: the next cycle is silent" "$(nl "$LOG")" 2

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

echo "S7d: an alerted episode ends because the root moved to a crew branch — CLEARED must not say it is on reviewed code"
mk_world s7d; fx checkout -q --detach "$U"; cycle 1; cycle 2; fx checkout -q -b crew/y
cycle 3
has "S7d the episode is closed" "$LOG" "CLEARED"
hasnt "S7d the CLEARED line does not claim the root is back on reviewed code" "$LOG" "back on reviewed code"
has "S7d it says what changed instead" "$LOG" "no longer detached"
has "S7d the crew branch is still restored" "$LOG" "RESTORED"

echo "S7e: an alert that went out with no clock (last_alarm = 0) is still closed with a CLEARED"
mk_world s7e; fx checkout -q --detach "$U"
printf '#!/bin/sh\nexit 1\n' > "$BIN/date"; chmod +x "$BIN/date"
cycle 1 WA_ROOT_GUARD_NOW=; cycle 2 WA_ROOT_GUARD_NOW=
eq "S7e the alert fired" "$(nl "$LOG")" 1
fx checkout -q --detach "$M3"; cycle 3 WA_ROOT_GUARD_NOW=
has "S7e recovery is logged although the alert carried no timestamp" "$LOG" "CLEARED"

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

# S10-S10c are the production topology: the root sits INSIDE another repo that is on main. GIT_CEILING_DIRECTORIES= (empty)
# switches the harness ceiling off, so only the guard's own protection stands between a broken root and that outer main.
echo "S10: HEAD unreadable, root nested in a repo on main"
mk_nested s10; fx checkout -q --detach "$U"; printf 'garbage\n' > "$ROOT/.git/HEAD"
eq "S10 fixture: without a ceiling a bare git on the broken root sees the OUTER main" \
  "$(env -u GIT_CEILING_DIRECTORIES git -C "$ROOT" branch --show-current 2>/dev/null)" main
cycle 1 GIT_CEILING_DIRECTORIES=; cycle 2 GIT_CEILING_DIRECTORIES=
eq "S10 log lines (the unfixed guard read the outer 'main': rc 0, empty log)" "$(nl "$LOG")" 1
has "S10 the line is UNKNOWN-DETACHED" "$LOG" "UNKNOWN-DETACHED"
hasnt "S10 not reported as off-main" "$LOG" "OFF-MAIN-DETACHED"
eq "S10 notified" "$(nl "$NOTES")" 1

echo "S10b: the root's .git is gone, root nested in a repo on main"
mk_nested s10b; mv "$ROOT/.git" "$W/git-gone"
cycle 1 GIT_CEILING_DIRECTORIES=
eq "S10b exit code" "$RC" 0
has "S10b it is logged as not a git repo, not read as the outer main" "$LOG" "not a git repo"

echo "S10c: the root is reached through a symlink, nested in a repo on main"
mk_nested s10c; fx checkout -q --detach "$U"; printf 'garbage\n' > "$ROOT/.git/HEAD"
LINK="$TMP/s10c-link"; ln -s "$ROOT" "$LINK"   # its textual parent ($TMP) is NOT an ancestor of where git stands
cycle 1 GIT_CEILING_DIRECTORIES= WA_ROOT_GUARD_ROOT="$LINK"; cycle 2 GIT_CEILING_DIRECTORIES= WA_ROOT_GUARD_ROOT="$LINK"
eq "S10c log lines" "$(nl "$LOG")" 1
has "S10c the line is UNKNOWN-DETACHED" "$LOG" "UNKNOWN-DETACHED"

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

echo "S11c: the episode began with no clock (first_epoch 0) and the alert comes with one — the age is unknown, not ~30 million minutes"
mk_world s11c; fx checkout -q --detach "$U"
printf '#!/bin/sh\nexit 1\n' > "$BIN/date"; chmod +x "$BIN/date"
cycle 1 WA_ROOT_GUARD_NOW=
rm -f "$BIN/date"
cycle 2
has "S11c the alert fired" "$LOG" "OFF-MAIN-DETACHED"
has "S11c the age is '?'" "$LOG" "~?)"

echo "S12: a crew branch left in the root is still backed up and restored"
mk_world s12; fx checkout -q -b crew/x; echo w > "$ROOT/w.txt"; fx add w.txt; fx commit -q -m crewwork
CREW="$(fx rev-parse --short HEAD)"
cycle 1
eq "S12 root is back on main" "$(fx rev-parse --abbrev-ref HEAD)" main
has "S12 RESTORED is logged" "$LOG" "RESTORED"
eq "S12 the divergent HEAD is on a backup tag" "$(fx tag -l "wa-root-guard-backup-$CREW" | wc -l | tr -d ' ')" 1
eq "S12 notified" "$(nl "$NOTES")" 1
eq "S12 exit code" "$RC" 0
hasnt "S12 a fetch that worked leaves no 'returned nonzero' WARN" "$LOG" "returned nonzero"

echo "S13: the production defaults of the seams are the real paths"
has "S13 default ROOT" "$GUARD" 'WA_ROOT_GUARD_ROOT:-/Users/athos/gt/whatsapp_automation'
has "S13 default CITY" "$GUARD" 'WA_ROOT_GUARD_CITY:-/Users/athos/gt/.gascity-gastown-hq'
has "S13 default HOOKS" "$GUARD" 'WA_ROOT_GUARD_HOOKS:-/tmp/empty-hooks'

echo "S14: the notify channel is down — the window must not be spent on an alert notify did not take"
mk_world s14; fx checkout -q --detach "$U"
cycle 1; cycle 2 NOTIFY_FAIL=1
has "S14 the alert line is still written (the log is the durable copy)" "$LOG" "OFF-MAIN-DETACHED"
has "S14 and a second line says the alert reached only the log" "$LOG" "NOTIFY-FAILED"
eq "S14 alert line + failure line" "$(nl "$LOG")" 2
eq "S14 notify took nothing" "$(nl "$NOTES")" 0
cycle 3
eq "S14 channel back: the next cycle retries (the unfixed guard spent the window and stayed silent for an hour)" "$(nl "$NOTES")" 1
eq "S14 the retry writes its own alert line, and no failure line" "$(nl "$LOG")" 3
eq "S14 only the failed attempt reports a failure" "$(grep -c 'NOTIFY-FAILED' "$LOG")" 1
cycle 4
eq "S14 once notify took it, the window is spent: no new notification" "$(nl "$NOTES")" 1
eq "S14 once notify took it, no new line" "$(nl "$LOG")" 3

echo "S15: the episode state file is corrupt — it counts as NO episode: no confirmation for free, and no wedge"
# Every shape carries a known kind and a high count with a later field missing or twisted (the 3rd: only the alarm) —
# read as they stand, they would confirm the alert on the very first cycle.
s15() {  # s15 <world> <state content> [unreadable]
  mk_world "$1"; fx checkout -q --detach "$U"; printf '%s\n' "$2" > "$STATE"
  if [ "${3:-}" = unreadable ]; then
    # a valid-looking state the guard cannot read (permissions); as root chmod 000 stops nothing, so the case is skipped
    if [ "$(id -u)" = 0 ]; then echo "  skip: S15 [$2] unreadable — running as root"; return 0; fi
    chmod 000 "$STATE"
    if [ -r "$STATE" ]; then bad "S15 fixture: the state file is still readable"; return 0; fi
  fi
  cycle 1
  eq "S15 [$2] the 1st cycle after the corruption is silent (the count restarts)" "$(nl "$LOG")" 0
  eq "S15 [$2] and notifies nobody" "$(nl "$NOTES")" 0
  cycle 2
  eq "S15 [$2] the next cycle confirms and alerts once (the state healed, it is not wedged)" "$(nl "$LOG")" 1
  eq "S15 [$2] and notifies once" "$(nl "$NOTES")" 1
  eq "S15 [$2] the root is never touched (still on the unreviewed sha)" "$(fx rev-parse HEAD)" "$U"
  eq "S15 [$2] ... and no backup tag was made" "$(fx tag -l 'wa-root-guard-backup-*' | wc -l | tr -d ' ')" 0
}
s15 s15a 'off-main 99'
s15 s15b 'off-main 99 abc 0'
s15 s15c 'off-main 99 1800000000 x'
s15 s15d 'off-main 99 1800000000 0' unreadable
# leading zeros are not a number the arithmetic reads as written (08/09 are invalid octal, 010 is 8) and a digit string past
# 12 places wraps silently in $(( )) while `[` refuses it — a state file only the guard writes never has either: corrupt
s15 s15e 'off-main 08 1800000000 0'
s15 s15f 'off-main 99 1800000000 09'
s15 s15g 'off-main 99 0800000000 0'
s15 s15h 'off-main 99 1800000000 99999999999999999999'

echo "S16: a window knob with a leading zero is decimal, a too long one is the default — and an arithmetic error never reaches the restore"
# 08/09 are invalid octal in $(( )): the error aborted handle_detached and the script went on, with BRANCH='', to the
# restore path (backup tag, CLEARED, the root moved off its detached HEAD). 010 is not an error at all — it was 8, not 10.
untouched() {  # untouched <label> — still detached on $U, no backup tag, no restore/clear line
  eq "$1: the root is still on the unreviewed sha" "$(fx rev-parse HEAD)" "$U"
  eq "$1: and still detached" "$(fx symbolic-ref -q HEAD >/dev/null 2>&1; echo $?)" 1
  eq "$1: no backup tag" "$(fx tag -l 'wa-root-guard-backup-*' | wc -l | tr -d ' ')" 0
  hasnt "$1: no RESTORED line" "$LOG" "RESTORED"
  hasnt "$1: no CLEARED line" "$LOG" "CLEARED"
}
A=$((T0 + 114 * 2))   # when the alert of cycle 2 fires
mk_world s16a; fx checkout -q --detach "$U"; cycle 1; cycle 2
eq "S16a the alert fired" "$(nl "$NOTES")" 1
cycle 3 WA_ROOT_GUARD_ALARM_WINDOW_MIN=08
eq "S16a window 08: 114 s after the alert is inside an 8 min window — silent" "$(nl "$LOG")" 1
untouched "S16a window 08"
cycle 4 WA_ROOT_GUARD_ALARM_WINDOW_MIN=08 WA_ROOT_GUARD_NOW=$((A + 479))
eq "S16a window 08 is 8 min, not the default 60: 1 s before it ends, silent" "$(nl "$LOG")" 1
cycle 5 WA_ROOT_GUARD_ALARM_WINDOW_MIN=08 WA_ROOT_GUARD_NOW=$((A + 480))
eq "S16a window 08: at 8 min the next alert goes out" "$(nl "$LOG")" 2
eq "S16a ... and notifies" "$(nl "$NOTES")" 2
mk_world s16b; fx checkout -q --detach "$U"; cycle 1; cycle 2
cycle 3 WA_ROOT_GUARD_ALARM_WINDOW_MIN=09
eq "S16b window 09: silent" "$(nl "$LOG")" 1
untouched "S16b window 09"
mk_world s16c; fx checkout -q --detach "$U"; cycle 1; cycle 2
cycle 3 WA_ROOT_GUARD_ALARM_WINDOW_MIN=010 WA_ROOT_GUARD_NOW=$((A + 599))
eq "S16c window 010 is ten minutes, not octal 8: at 599 s still silent" "$(nl "$LOG")" 1
cycle 4 WA_ROOT_GUARD_ALARM_WINDOW_MIN=010 WA_ROOT_GUARD_NOW=$((A + 600))
eq "S16c window 010: at 600 s the next alert goes out" "$(nl "$LOG")" 2
mk_world s16d; fx checkout -q --detach "$U"; cycle 1; cycle 2
cycle 3 WA_ROOT_GUARD_ALARM_WINDOW_MIN=9999999999999 WA_ROOT_GUARD_NOW=$((A + 3599))
eq "S16d a 13-digit window is the default 60 min: at 3599 s silent" "$(nl "$LOG")" 1
cycle 4 WA_ROOT_GUARD_ALARM_WINDOW_MIN=9999999999999 WA_ROOT_GUARD_NOW=$((A + 3600))
eq "S16d ... and at 3600 s it alerts (the knob did not silence the guard for good)" "$(nl "$LOG")" 2

echo "S17: an arithmetic error nobody foresaw aborts the handler — the script ends inert, it does not fall through to the restore"
# The numbers are validated now, so no input reaches that error any more; the net behind them is tested on a COPY of the guard
# with the fault injected (a bad operand in the count test, run by every detached cycle).
mk_world s17; fx checkout -q --detach "$U"
sed 's/if \[ "\$count" -ge "\$CONFIRM" \]; then/if [ $((count + 1x)) -ge "$CONFIRM" ]; then/' "$GUARD" > "$W/guard-faulty.sh"
if cmp -s "$GUARD" "$W/guard-faulty.sh"; then
  bad "S17 fixture: the fault was not injected (the line it targets moved?)"
else
  GUARD_REAL="$GUARD"; GUARD="$W/guard-faulty.sh"; cycle 1; cycle 2; GUARD="$GUARD_REAL"
  eq "S17 exit code" "$RC" 0
  has "S17 the abort is logged, not silent" "$LOG" "did not finish"
  untouched "S17"
fi

echo "S18: the kill switch (WA_ROOT_GUARD_ENABLED=0) — a crew branch is reported and left alone"
mk_world s18; fx checkout -q -b crew/k; echo k > "$ROOT/k.txt"; fx add k.txt; fx commit -q -m crewk
cycle 1 WA_ROOT_GUARD_ENABLED=0
eq "S18 exit code" "$RC" 0
has "S18 the line says check-only" "$LOG" "check-only, NOT restoring"
eq "S18 the root stays on the crew branch" "$(fx rev-parse --abbrev-ref HEAD)" crew/k
eq "S18 no backup tag" "$(fx tag -l 'wa-root-guard-backup-*' | wc -l | tr -d ' ')" 0
hasnt "S18 no RESTORED line" "$LOG" "RESTORED"
has "S18 notified that the guard is disabled" "$NOTES" "guard DISABLED"

echo "S19: 'git switch main' fails (the crew's uncommitted edit would be overwritten) — nothing is forced, the guard says so and ends 0"
mk_world s19; fx checkout -q -b crew/c; echo crew > "$ROOT/f.txt"; fx add f.txt; fx commit -q -m crewf; echo dirty > "$ROOT/f.txt"
cycle 1
eq "S19 exit code" "$RC" 0
has "S19 the failure is logged" "$LOG" "'git switch main' FAILED"
eq "S19 the root stays on the crew branch (never forced)" "$(fx rev-parse --abbrev-ref HEAD)" crew/c
eq "S19 the uncommitted edit is still there" "$(cat "$ROOT/f.txt")" dirty
eq "S19 the divergent HEAD is on a backup tag" "$(fx tag -l 'wa-root-guard-backup-*' | wc -l | tr -d ' ')" 1
has "S19 notified (needs a human)" "$NOTES" "switch to main FAILED"

echo "S20: 'git fetch origin main' fails (offline) — the restore goes on with the local main and says so"
mk_world s20; fx checkout -q -b crew/f; echo f > "$ROOT/ff.txt"; fx add ff.txt; fx commit -q -m crewff
fx remote set-url origin "$W/no-such-origin.git"
cycle 1
eq "S20 exit code" "$RC" 0
has "S20 the fetch failure is a WARN line" "$LOG" "'git fetch origin main' returned nonzero"
has "S20 the restore still lands" "$LOG" "RESTORED"
eq "S20 the root is back on main" "$(fx rev-parse --abbrev-ref HEAD)" main

echo "S21: the guard drops only the stash entry IT made (ga-sdkrl)"
mk_world s21a; fx checkout -q -b crew/d; mkdir -p "$ROOT/daemons"; echo d1 > "$ROOT/daemons/d.txt"; fx add daemons/d.txt; fx commit -q -m crewd
echo d2 > "$ROOT/daemons/d.txt"
cycle 1
has "S21a RESTORED" "$LOG" "RESTORED"
eq "S21a the entry the guard made for daemons/ is dropped: nothing is left on the stash" "$(fx stash list | wc -l | tr -d ' ')" 0
mk_world s21b; echo mine >> "$ROOT/f.txt"; fx stash push -q -m unrelated
fx checkout -q -b crew/e; echo e > "$ROOT/e.txt"; fx add e.txt; fx commit -q -m crewe
SB="$(fx rev-parse refs/stash)"
cycle 1
has "S21b RESTORED" "$LOG" "RESTORED"
eq "S21b daemons/ was clean, so the guard made no entry: the unrelated stash is untouched" "$(fx rev-parse -q --verify refs/stash)" "$SB"

echo "S22: the episode state without its final newline still counts (read returns non-zero on it but fills the fields)"
mk_world s22; fx checkout -q --detach "$U"; printf 'off-main 1 %s 0' $((T0 + 114)) > "$STATE"
cycle 2
eq "S22 the 2nd cycle of that episode alerts" "$(nl "$LOG")" 1
has "S22 ... as cycle 2 of an episode that began a cycle earlier" "$LOG" "cycles=2, ~1min)"

echo "S23: the age in the alert and in CLEARED is the minutes since the episode began"
mk_world s23a; fx checkout -q --detach "$U"; printf 'off-main 1 %s 0\n' $((T0 + 228 - 7200)) > "$STATE"; cycle 2
has "S23a began 2 h before: ~120min" "$LOG" "cycles=2, ~120min)"
mk_world s23b; fx checkout -q --detach "$U"; printf 'off-main 1 %s 0\n' $((T0 + 228)) > "$STATE"; cycle 2
has "S23b began this very second: ~0min, not unknown" "$LOG" "cycles=2, ~0min)"
mk_world s23c; fx checkout -q --detach "$U"; printf 'off-main 1 %s 0\n' $((T0 + 228 + 600)) > "$STATE"; cycle 2
has "S23c began in the future (the clock stepped back): unknown" "$LOG" "cycles=2, ~?)"
mk_world s23d; printf 'off-main 2 %s %s\n' $((T0 + 228 - 7200)) $((T0 + 100)) > "$STATE"; cycle 2
has "S23d CLEARED carries the length of the episode" "$LOG" "lasted ~120min, 2 cycles"

echo "S24: the alert window is half-open — a last alert made at this very second is neither in the future nor spent"
mk_world s24; fx checkout -q --detach "$U"; printf 'off-main 5 %s %s\n' "$T0" $((T0 + 228)) > "$STATE"; cycle 2
eq "S24 no alert (alarm == now is not a clock that stepped back)" "$(nl "$LOG")" 0
eq "S24 ... and no notification" "$(nl "$NOTES")" 0

echo "S25: no notify on PATH — the alert is in the log only, the failure line says rc=1, and the window is not spent"
mk_world s25; fx checkout -q --detach "$U"; rm -f "$BIN/notify"
NONOTE="$BIN:$(dirname "$REAL_GIT"):/usr/bin:/bin"
if env PATH="$NONOTE" sh -c 'command -v notify' >/dev/null 2>&1; then bad "S25 fixture: a notify is still on PATH ($NONOTE)"; else
  cycle 1 PATH="$NONOTE"; cycle 2 PATH="$NONOTE"
  has "S25 the alert line is written" "$LOG" "OFF-MAIN-DETACHED"
  has "S25 the failure line says rc=1 (not the 127 of running a command that is not there)" "$LOG" "(rc=1), so this log is its only copy"
  cycle 3 PATH="$NONOTE"
  eq "S25 the window was not spent: the next cycle writes the alert again" "$(grep -c 'OFF-MAIN-DETACHED' "$LOG")" 2
fi

echo ""
echo "──────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
