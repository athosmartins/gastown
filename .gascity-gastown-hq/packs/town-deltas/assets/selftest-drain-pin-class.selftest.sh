#!/usr/bin/env bash
# selftest-drain-pin-class.selftest.sh — ga-a2v0bz: keep the CLASS "a selftest's outcome depends on the time of day" closed.
#
# THE CLASS (gate run ga-y0fst4, 01/10): the drain gate added to the 5 dispatchers (pilot, quality-gate, refino-gate,
# auto-refino, context-check) reads an AMBIENT file, ~/.gastown/run/city-drain.level, that scripts/nightly-reboot.sh rewrites
# every night 23:00 -> 23:55. A selftest that RUNS one of those dispatchers with the caller's real HOME therefore passed at
# noon and failed at 23:30 — 7 assertions in context-check-dispatcher.selftest.sh alone — for a reason that has nothing to do
# with the code under test. Builders and gate reviewers run selftests at night too (in-flight work keeps running during the
# drain by design), so the false FAILs landed on exactly the people who could not tell them from real ones. Two other suites
# (auto-refino, the pilot suite) were immune only BY ACCIDENT: their PATH has no /usr/sbin, `sysctl` is not found, the boot
# cannot be proven and the gate fails open. Add /usr/sbin and they break.
#
# THE RULE THIS GUARD ENFORCES, per RUN SITE (not per file — a file-level pin does not reach an `env -i` block, which is
# how the pilot suite runs every one of its ~33 sites):
#   a RUN SITE is a non-comment command (continuation lines joined) that executes a dispatcher: `bash|sh [flags] <path>` where
#   <path> is a literal …-dispatcher.sh or "$VAR" with VAR assigned such a path in the same file. `bash -n` is a syntax check,
#   not a run. It must be one of
#     - inside an `env -i` that names DRAIN_WINDOW_OVERRIDE= or DRAIN_WINDOW_FILE=       (env-pin)
#     - inside an `env -i` whose HOME= is not the caller's ($HOME / ${HOME}), or absent  (sandboxed HOME)
#     - not in an `env -i`: with the pin inline, a sandboxed HOME inline, or an
#       `export DRAIN_WINDOW_OVERRIDE|FILE=…` on an EARLIER line of the same file         (inherits a pinned environment)
#
# WHAT THIS GUARD DOES NOT SEE (say so, do not pretend): a dispatcher run through another spelling (`"$X"` as the command,
# `exec`, `xargs`, a copy of the script under another name, a variable assembled in two steps) is not recognised; a pin whose
# VALUE is wrong (a typo'd file name) is not judged — only that a pin is named. Suites that only EXTRACT functions from a
# dispatcher (`sed -n '/^fn() {/,/^}/p'`) never reach the gate and are rightly not asked for a pin. It closes the
# copy-an-old-selftest route, which is how the class spread; the empirical audit (run the suites under a live signal) is what
# found the sites. Section D is that audit for the one suite the reviewer reproduced.
#
# EXEMPTIONS: none today. One would be a line in EXEMPT with a REASON, and this file's own fixtures are skipped by name.
#
#   A  the detector on fixtures: each leaky shape is caught, each safe shape is let through
#   B  the real tree: no unpinned run site, AND the scan is not vacuous (it still sees the pilot suite's sites)
#   C  the scan cannot silently see nothing: an unreadable root FAILS instead of passing
#   D  end to end: context-check-dispatcher.selftest.sh under a LIVE drain signal gives the same verdict as without one
#
# DRAIN_PIN_SCAN_ASSETS / DRAIN_PIN_SCAN_SCRIPTS point B at another copy of the tree (used to replay the pre-pin tree: B must
# FAIL there). Runs under macOS /bin/bash 3.2 and BSD awk: no associative arrays in bash, no \b, no `$` inside a regex group.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
SCAN_ASSETS="${DRAIN_PIN_SCAN_ASSETS:-$HERE}"
SCAN_SCRIPTS="${DRAIN_PIN_SCAN_SCRIPTS:-$HERE/../../../scripts}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/drain-pin-class.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT"' EXIT

EXEMPT=""   # space-separated basenames; every entry needs a REASON in a comment right here (none today)

DET="$ROOT/detector.awk"
cat > "$DET" <<'AWK'
# Two passes over the same file (awk -f det.awk file file). Prints one record per RUN SITE: SITE|<file>|<line>|<verdict>
function pinned(s) { return s ~ /DRAIN_WINDOW_(OVERRIDE|FILE)=("[^"]|'[^']|[^"' \t])/ }
function real_home(s,   h) {
  if (!match(s, /HOME="[^"]*"/)) return 0            # HOME absent: unset, nothing to read from
  h = substr(s, RSTART, RLENGTH)
  return (h ~ /[$]HOME/ || h ~ /[$][{]HOME[}]/ || h ~ /HOME="~/)
}
function check(L, start,   v, hit) {
  L = L " "                       # leading space comes from the join, trailing one is added: no ^ / $ inside regex groups (BSD awk)
  if (L ~ /[ \t\/(;&|`](bash|sh)[ \t]+-[a-zA-Z]*n[a-zA-Z]*[ \t]/) return   # syntax check, not a run
  hit = 0
  if (L ~ RUN_LIT) hit = 1
  else for (v in vars) {
    if (L ~ ("[ \t/(;&|`](bash|sh)[ \t]+(-[a-zA-Z]+[ \t]+)*\"?[$][{]?" v "[^A-Za-z0-9_]")) { hit = 1; break }
  }
  if (!hit) return
  if (L ~ /[ \t(;&|`]env[ \t]+-i[ \t]/) {
    if (pinned(L)) verdict = "ok-env-pin"
    else if (!real_home(L)) verdict = "ok-sandboxed-home"
    else verdict = "LEAK-env-i-real-home-unpinned"
  } else {
    if (pinned(L)) verdict = "ok-inline-pin"
    else if (L ~ /HOME="/ && !real_home(L)) verdict = "ok-sandboxed-home"
    else if (exportpin && exportpin < start) verdict = "ok-export-pin"
    else verdict = "LEAK-inherits-env-no-earlier-export"
  }
  printf "SITE|%s|%d|%s\n", F, start, verdict
}
BEGIN {
  DISP = "(pilot|quality-gate|refino-gate|auto-refino|context-check)-dispatcher[.]sh"
  RUN_LIT = "[ \t/(;&|`](bash|sh)[ \t]+(-[a-zA-Z]+[ \t]+)*\"?[^ \t\"]*" DISP
}
FNR == NR {                                            # pass 1: dispatcher variables + the file-level export pin
  if ($0 ~ /^[ \t]*#/) next
  if ($0 ~ /^[ \t]*(readonly[ \t]+|export[ \t]+|local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/ && $0 ~ DISP) {
    s = $0; sub(/^[ \t]*(readonly[ \t]+|export[ \t]+|local[ \t]+)?/, "", s); sub(/=.*/, "", s); vars[s] = 1
  }
  if ($0 ~ /^[ \t]*export[ \t]+DRAIN_WINDOW_(OVERRIDE|FILE)=/ && pinned($0) && !exportpin) exportpin = FNR
  next
}
{                                                      # pass 2: logical lines (backslash continuations joined)
  line = $0
  if (!inblk) { if (line ~ /^[ \t]*#/) next; start = FNR; acc = "" }
  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); acc = acc " " line; inblk = 1; next }
  acc = acc " " line; inblk = 0
  check(acc, start)
}
AWK

# scan_file <file> — print SITE records; non-zero if awk itself failed (third state: could not scan)
scan_file() { awk -v F="$(basename "$1")" -f "$DET" "$1" "$1"; }

# scan_tree <dir>... — every *.selftest.sh directly under each dir except this file and exemptions.
# Prints all SITE records; returns 3 if a dir is unreadable or awk failed, so "found nothing" is never "could not look".
scan_tree() {
  local d f rc=0 base
  for d in "$@"; do
    [ -d "$d" ] || { echo "SCAN-ERROR|$d|not a directory"; rc=3; continue; }
    for f in "$d"/*.selftest.sh; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      [ "$base" = "$SELF_NAME" ] && continue
      case " $EXEMPT " in *" $base "*) continue ;; esac
      scan_file "$f" || { echo "SCAN-ERROR|$base|awk failed"; rc=3; }
    done
  done
  return $rc
}

# ── A: the detector on fixtures ─────────────────────────────────────────────────────────────────────────────
echo "A  detector on fixtures"
FX="$ROOT/fx"; mkdir -p "$FX"
mkfx() { cat > "$FX/$1"; }

mkfx env-i-unpinned.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
run() {
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
}
FXEOF
mkfx env-i-pinned.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
run() {
  env -i \
    DRAIN_WINDOW_OVERRIDE="OPEN" \
    PATH="$SHIMBIN:/usr/bin:/bin" \
    HOME="$HOME" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
}
FXEOF
mkfx env-i-file-pinned.selftest.sh <<'FXEOF'
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
env -i PATH="$SHIMBIN:/usr/bin" HOME="$HOME" DRAIN_WINDOW_FILE=/nonexistent-hermetic-drain \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx env-i-sandboxed-home.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/refino-gate-dispatcher.sh"
( cd / && env -i HOME="$SB/home" PATH="$SANDBOX_PATH" QUIET_HOURS_OVERRIDE=OPEN \
    /bin/bash "$DISPATCHER" ) > "$SB/out" 2>&1 || true
FXEOF
mkfx env-i-no-home.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/context-check-dispatcher.sh"
env -i PATH="/usr/bin:/bin" bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx inherit-no-export.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/context-check-dispatcher.sh"
CONTEXT_CHECK_CITY_OVERRIDE="$city" DRY_RUN=1 \
  PATH="$SANDBOX_PATH" \
  bash "$DISPATCHER" >/dev/null 2>&1
FXEOF
mkfx inherit-export-before.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/context-check-dispatcher.sh"
export DRAIN_WINDOW_OVERRIDE=OPEN
CONTEXT_CHECK_CITY_OVERRIDE="$city" DRY_RUN=1 \
  PATH="$SANDBOX_PATH" \
  bash "$DISPATCHER" >/dev/null 2>&1
FXEOF
mkfx inherit-export-after.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/auto-refino-dispatcher.sh"
bash "$DISPATCHER" >/dev/null 2>&1
export DRAIN_WINDOW_OVERRIDE=OPEN
FXEOF
mkfx inherit-inline-pin.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
DRAIN_WINDOW_OVERRIDE=OPEN GATE_CITY="$c" bash "$DISPATCHER" >/dev/null 2>&1
FXEOF
mkfx export-does-not-reach-env-i.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
export DRAIN_WINDOW_OVERRIDE=OPEN
env -i PATH="/usr/bin:/bin" HOME="$HOME" bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx one-pinned-one-not.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
env -i \
  DRAIN_WINDOW_OVERRIDE="OPEN" \
  HOME="$HOME" \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
env -i \
  HOME="$HOME" \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx empty-pin-is-no-pin.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
env -i DRAIN_WINDOW_OVERRIDE="" HOME="$HOME" bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx literal-path.selftest.sh <<'FXEOF'
env -i HOME="$HOME" bash "$SELF_DIR/pilot-dispatcher.sh" >/dev/null 2>&1 || true
FXEOF
mkfx syntax-check-only.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
if bash -n "$DISPATCHER" 2>/dev/null; then echo parses; fi
FXEOF
mkfx extraction-only.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
FN="$(sed -n '/^_e9_dispatch_line() {/,/^}$/p' "$DISPATCHER")"
awk '/x/' "$DISPATCHER"
grep -c foo "$DISPATCHER"
FXEOF
mkfx comment-only.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
#   env -i HOME="$HOME" bash "$DISPATCHER"   <- an example in a comment, not a run
FXEOF
mkfx not-a-dispatcher.selftest.sh <<'FXEOF'
SCRIPT="$SELF_DIR/reaper.sh"
env -i HOME="$HOME" bash "$SCRIPT" >/dev/null 2>&1 || true
FXEOF

verdict_of() { scan_file "$FX/$1" | awk -F'|' '{print $4}' | tr '\n' ' ' | sed 's/ $//'; }
expect() { # <fixture> <expected verdict list> <label>
  local got; got="$(verdict_of "$1")"
  if [ "$got" = "$2" ]; then ok "$3"; else nok "$3" "fixture $1: expected [$2], got [$got]"; fi
}
expect env-i-unpinned.selftest.sh            "LEAK-env-i-real-home-unpinned"            "env -i + real HOME + no pin is a LEAK"
expect env-i-pinned.selftest.sh              "ok-env-pin"                               "env -i + DRAIN_WINDOW_OVERRIDE pin is let through"
expect env-i-file-pinned.selftest.sh         "ok-env-pin"                               "env -i + DRAIN_WINDOW_FILE pin (one-line start, var via \${X:-…}) is let through"
expect env-i-sandboxed-home.selftest.sh      "ok-sandboxed-home"                        "env -i with a sandboxed HOME is let through (subshell + /bin/bash spelling)"
expect env-i-no-home.selftest.sh             "ok-sandboxed-home"                        "env -i with no HOME at all is let through (nothing to read from)"
expect inherit-no-export.selftest.sh         "LEAK-inherits-env-no-earlier-export"      "env-inheriting run with no export is a LEAK"
expect inherit-export-before.selftest.sh     "ok-export-pin"                            "env-inheriting run after an export pin is let through"
expect inherit-export-after.selftest.sh      "LEAK-inherits-env-no-earlier-export"      "an export AFTER the run protects nothing — still a LEAK"
expect inherit-inline-pin.selftest.sh        "ok-inline-pin"                            "inline VAR=… pin on the run is let through"
expect export-does-not-reach-env-i.selftest.sh "LEAK-env-i-real-home-unpinned"          "a file-level export does NOT reach an env -i block — still a LEAK"
expect one-pinned-one-not.selftest.sh        "ok-env-pin LEAK-env-i-real-home-unpinned" "judged per RUN SITE: one pinned site does not cover its unpinned neighbour"
expect empty-pin-is-no-pin.selftest.sh       "LEAK-env-i-real-home-unpinned"            "DRAIN_WINDOW_OVERRIDE=\"\" is not a pin (the helper treats empty as unset)"
expect literal-path.selftest.sh              "LEAK-env-i-real-home-unpinned"            "a literal …-dispatcher.sh path is a run site too"
expect syntax-check-only.selftest.sh         ""                                         "bash -n is a syntax check, not a run"
expect extraction-only.selftest.sh           ""                                         "sed/awk/grep over the dispatcher is not a run"
expect comment-only.selftest.sh              ""                                         "a run site inside a comment is ignored"
expect not-a-dispatcher.selftest.sh          ""                                         "a script that is not one of the 5 dispatchers is not asked for a pin"

# ── B: the real tree ────────────────────────────────────────────────────────────────────────────────────
echo "B  real tree"
REAL="$ROOT/real.records"
scan_tree "$SCAN_ASSETS" "$SCAN_SCRIPTS" > "$REAL"; rc=$?
nsites=$(grep -c '^SITE|' "$REAL"); nfiles=$(grep '^SITE|' "$REAL" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')
leaks=$(grep '^SITE|.*|LEAK-' "$REAL")
if [ "$rc" -ne 0 ]; then
  nok "the scan could not complete (rc=$rc) — that is not a pass" "$(grep '^SCAN-ERROR' "$REAL")"
elif [ -n "$leaks" ]; then
  nok "$(printf '%s\n' "$leaks" | wc -l | tr -d ' ') dispatcher run site(s) read the ambient drain signal unpinned (their outcome depends on the time of day)" \
      "$(printf '%s\n' "$leaks" | awk -F'|' '{printf "%s:%s  %s\n", $2, $3, $4}')"
else
  ok "no unpinned dispatcher run site ($nsites run site(s) in $nfiles file(s) judged)"
fi
# Not vacuous: the pilot suite runs the real dispatcher ~33 times; a regex that stops matching must not read as "clean".
pilot_sites=$(grep -c '^SITE|pilot-dispatcher[.]selftest[.]sh|' "$REAL")
if [ "$pilot_sites" -ge 25 ]; then ok "the scan still sees the pilot suite's run sites ($pilot_sites)"; else nok "the scan sees only $pilot_sites run site(s) in pilot-dispatcher.selftest.sh (expected >= 25) — the detector stopped matching, so 'clean' above means nothing"; fi
for s in context-check-dispatcher auto-refino-dispatcher refino-gate-dispatcher; do
  n=$(grep -c "^SITE|$s[.]selftest[.]sh|" "$REAL")
  if [ "$n" -ge 1 ]; then ok "the scan still sees $s.selftest.sh's run site(s) ($n)"; else nok "the scan sees NO run site in $s.selftest.sh — the detector stopped matching"; fi
done

# ── C: unreadable root is an error, not a clean bill ────────────────────────────────────────────────────
echo "C  could not look != found nothing"
scan_tree "$ROOT/does-not-exist" > "$ROOT/c.records"; crc=$?
if [ "$crc" -eq 3 ] && grep -q '^SCAN-ERROR' "$ROOT/c.records"; then ok "an unreadable scan root returns 3 + SCAN-ERROR (never an empty pass)"; else nok "an unreadable scan root returned rc=$crc: $(cat "$ROOT/c.records")"; fi

# ── D: end to end, the reviewer's reproduction ──────────────────────────────────────────────────────────
echo "D  context-check selftest under a LIVE drain signal"
CC="$SCAN_ASSETS/context-check-dispatcher.selftest.sh"
boot=$(sysctl -n kern.boottime 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="sec"){v=$(i+2); gsub(/[^0-9]/,"",v); print v; exit}}')
case "$boot" in
  ''|*[!0-9]*) echo "  skip - kern.boottime unreadable here: the drain signal cannot be made valid, so this proves nothing (NOT a pass)" ;;
  *)
    if [ ! -f "$CC" ]; then nok "context-check-dispatcher.selftest.sh not found at $CC"
    else
      run_cc() { # <home-dir> — run the suite with HOME pointed there
        ( cd "$(dirname "$CC")" && env HOME="$1" SELFTEST_LOCK_WAIT_SECS=0 /bin/bash "$CC" ) > "$1/out" 2>&1
      }
      HS="$ROOT/home-signal"; HN="$ROOT/home-none"
      mkdir -p "$HS/.gastown/run" "$HN/.gastown/run"
      now=$(date +%s)
      printf 'DRAIN\n%s\n%s\n%s\n' "$now" "$boot" "$((now+3000))" > "$HS/.gastown/run/city-drain.level"
      run_cc "$HS"; src=$?
      if [ "$src" -eq 0 ]; then
        ok "context-check suite passes with a live DRAIN signal in the caller's HOME"
      else
        run_cc "$HN"; nrc=$?
        if [ "$nrc" -eq 0 ]; then
          nok "context-check suite PASSES without the signal and FAILS with it — its outcome depends on the time of day" "$(grep -E '✗|FAIL' "$HS/out" | head -5)"
        else
          nok "context-check suite fails with AND without the signal (rc $src / $nrc) — not this class, but the suite is red" "$(grep -E '✗|FAIL' "$HN/out" | head -5)"
        fi
      fi
    fi ;;
esac

echo
echo "selftest-drain-pin-class.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
