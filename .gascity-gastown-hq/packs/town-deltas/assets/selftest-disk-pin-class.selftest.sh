#!/usr/bin/env bash
# selftest-disk-pin-class.selftest.sh — ga-ydaslo: keep the CLASS "a selftest's outcome depends on how full the host's disk is" closed.
# (Mirror of selftest-drain-pin-class.selftest.sh, which does the same for the time of day.)
#
# THE CLASS (gate run ga-lhbess, 17/10): the Pilot gained a DISK FLOOR gate (_pilot_disk_floor) that reads the host's REAL free
# disk and pauses the whole sweep under 5 GB. Only pilot-dispatcher.selftest.sh pinned the reading (DISK_FREE_OVERRIDE_MB); two
# other suites that run the whole dispatcher under `env -i` did not, so they were green on a roomy disk and RED on the mini
# whenever it was under 5 GB (pilot-choretask-unconditional 6/0 -> 4/2, pilot-eligibility 10/0 -> 9/1) for a reason that has
# nothing to do with the code under test. The mini IS under 5 GB most days, and that is where the gate runs.
#
# THE RULE, per RUN SITE (not per file — a file-level pin does not reach an `env -i` block, which scrubs the environment):
#   a RUN SITE is a non-comment command (continuation lines joined) that executes pilot-dispatcher.sh: `bash|sh [flags] <path>`
#   where <path> is a literal …pilot-dispatcher.sh or "$VAR" with VAR assigned such a path in the same file. `bash -n` is a syntax
#   check, not a run. It must be one of
#     - inside an `env -i` that names DISK_FREE_OVERRIDE_MB=<value> or PILOT_DISK_FREE_OVERRIDE_MB=<value> or PILOT_DISK_FLOOR_ENABLED=0
#     - not in an `env -i`: with the pin inline, or an `export …` of one on an EARLIER line of the same file
#   There is no "sandboxed HOME" way out (unlike the drain signal): df reads the host whatever HOME says.
#
# WHAT THIS GUARD DOES NOT SEE (said, not pretended): a dispatcher run through another spelling (`"$X"` as the command, `exec`,
# `xargs`, a copy under another name, a variable assembled in two steps) is not recognised; a pin whose VALUE is wrong is not judged,
# only that a non-empty one is named. Suites that only EXTRACT functions from the dispatcher (`sed -n '/^fn() {/,/^}/p'`) never
# reach the gate and are rightly not asked for a pin. Only pilot-dispatcher.sh reads the disk, so only it is scanned.
#
#   A  the detector on fixtures: each leaky shape is caught, each safe shape is let through
#   B  the real tree: no unpinned run site, AND the scan is not vacuous (it still sees the suites that run the dispatcher)
#   C  the scan cannot silently see nothing: an unreadable root FAILS instead of passing
#
# DISK_PIN_SCAN_ASSETS / DISK_PIN_SCAN_SCRIPTS point B at another copy of the tree (used to replay the pre-pin tree: B must FAIL
# there). Runs under macOS /bin/bash 3.2 and BSD awk: no associative arrays in bash, no \b, no `$` inside a regex group.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
SCAN_ASSETS="${DISK_PIN_SCAN_ASSETS:-$HERE}"
SCAN_SCRIPTS="${DISK_PIN_SCAN_SCRIPTS:-$HERE/../../../scripts}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/disk-pin-class.XXXXXX")" || exit 1
trap 'rm -rf "$ROOT"' EXIT

# space-separated basenames; every entry needs a REASON in a comment right here:
#   selftest-drain-pin-class.selftest.sh — its "run sites" are heredoc FIXTURES (text it feeds to its own detector), never executed;
#   it runs context-check-dispatcher.selftest.sh, not the Pilot.
EXEMPT="selftest-drain-pin-class.selftest.sh"

DET="$ROOT/detector.awk"
cat > "$DET" <<'AWK'
# Two passes over the same file (awk -f det.awk file file). Prints one record per RUN SITE: SITE|<file>|<line>|<verdict>
function pinned(s) {
  return (s ~ /DISK_FREE_OVERRIDE_MB=("[^"]|'[^']|[^"' \t])/ || s ~ /PILOT_DISK_FLOOR_ENABLED=0[ \t"']/)
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
    verdict = pinned(L) ? "ok-env-pin" : "LEAK-env-i-unpinned"
  } else if (pinned(L)) verdict = "ok-inline-pin"
  else if (exportpin && exportpin < start) verdict = "ok-export-pin"
  else verdict = "LEAK-inherits-env-no-earlier-export"
  printf "SITE|%s|%d|%s\n", F, start, verdict
}
BEGIN {
  DISP = "pilot-dispatcher[.]sh"
  RUN_LIT = "[ \t/(;&|`](bash|sh)[ \t]+(-[a-zA-Z]+[ \t]+)*\"?[^ \t\"]*" DISP
}
FNR == NR {                                            # pass 1: dispatcher variables + the file-level export pin
  if ($0 ~ /^[ \t]*#/) next
  if ($0 ~ /^[ \t]*(readonly[ \t]+|export[ \t]+|local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/ && $0 ~ DISP) {
    s = $0; sub(/^[ \t]*(readonly[ \t]+|export[ \t]+|local[ \t]+)?/, "", s); sub(/=.*/, "", s); vars[s] = 1
  }
  if ($0 ~ /^[ \t]*export[ \t]+(PILOT_)?DISK_FREE_OVERRIDE_MB=/ && pinned($0) && !exportpin) exportpin = FNR
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
    DISK_FREE_OVERRIDE_MB="${PILOT_TEST_DISK_FREE_MB:-100000}" \
    PATH="$SHIMBIN:/usr/bin:/bin" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
}
FXEOF
mkfx env-i-pilot-override.selftest.sh <<'FXEOF'
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
env -i PATH="$SHIMBIN:/usr/bin" PILOT_DISK_FREE_OVERRIDE_MB=100000 bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx env-i-kill-switch.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
env -i PATH="/usr/bin:/bin" PILOT_DISK_FLOOR_ENABLED=0 bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx env-i-sandboxed-home.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
( cd / && env -i HOME="$SB/home" PATH="$SANDBOX_PATH" /bin/bash "$DISPATCHER" ) > "$SB/out" 2>&1 || true
FXEOF
mkfx inherit-no-export.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
PILOT_CITY_OVERRIDE="$city" DRY_RUN=1 \
  PATH="$SANDBOX_PATH" \
  bash "$DISPATCHER" >/dev/null 2>&1
FXEOF
mkfx inherit-export-before.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
export DISK_FREE_OVERRIDE_MB=100000
DRY_RUN=1 bash "$DISPATCHER" >/dev/null 2>&1
FXEOF
mkfx inherit-export-after.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
bash "$DISPATCHER" >/dev/null 2>&1
export DISK_FREE_OVERRIDE_MB=100000
FXEOF
mkfx inherit-inline-pin.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
DISK_FREE_OVERRIDE_MB=100000 GATE_CITY="$c" bash "$DISPATCHER" >/dev/null 2>&1
FXEOF
mkfx export-does-not-reach-env-i.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
export DISK_FREE_OVERRIDE_MB=100000
env -i PATH="/usr/bin:/bin" HOME="$HOME" bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx one-pinned-one-not.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
env -i \
  DISK_FREE_OVERRIDE_MB="100000" \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
env -i \
  HOME="$HOME" \
  bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx empty-pin-is-no-pin.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
env -i DISK_FREE_OVERRIDE_MB="" HOME="$HOME" bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF
mkfx kill-switch-on-is-no-pin.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
env -i PILOT_DISK_FLOOR_ENABLED=1 HOME="$HOME" bash "$DISPATCHER" >/dev/null 2>&1 || true
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
mkfx other-dispatcher.selftest.sh <<'FXEOF'
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
env -i HOME="$HOME" bash "$DISPATCHER" >/dev/null 2>&1 || true
FXEOF

verdict_of() { scan_file "$FX/$1" | awk -F'|' '{print $4}' | tr '\n' ' ' | sed 's/ $//'; }
expect() { # <fixture> <expected verdict list> <label>
  local got; got="$(verdict_of "$1")"
  if [ "$got" = "$2" ]; then ok "$3"; else nok "$3" "fixture $1: expected [$2], got [$got]"; fi
}
expect env-i-unpinned.selftest.sh              "LEAK-env-i-unpinned"                 "env -i with no disk pin is a LEAK"
expect env-i-pinned.selftest.sh                "ok-env-pin"                          "env -i + DISK_FREE_OVERRIDE_MB (multi-line block) is let through"
expect env-i-pilot-override.selftest.sh        "ok-env-pin"                          "env -i + PILOT_DISK_FREE_OVERRIDE_MB (one-line start, var via \${X:-…}) is let through"
expect env-i-kill-switch.selftest.sh           "ok-env-pin"                          "env -i + PILOT_DISK_FLOOR_ENABLED=0 is let through"
expect env-i-sandboxed-home.selftest.sh        "LEAK-env-i-unpinned"                 "a sandboxed HOME is NOT a way out: df reads the host whatever HOME says"
expect inherit-no-export.selftest.sh           "LEAK-inherits-env-no-earlier-export" "env-inheriting run with no export is a LEAK"
expect inherit-export-before.selftest.sh       "ok-export-pin"                       "env-inheriting run after an export pin is let through"
expect inherit-export-after.selftest.sh        "LEAK-inherits-env-no-earlier-export" "an export AFTER the run protects nothing — still a LEAK"
expect inherit-inline-pin.selftest.sh          "ok-inline-pin"                       "inline VAR=… pin on the run is let through"
expect export-does-not-reach-env-i.selftest.sh "LEAK-env-i-unpinned"                "a file-level export does NOT reach an env -i block — still a LEAK"
expect one-pinned-one-not.selftest.sh          "ok-env-pin LEAK-env-i-unpinned"      "judged per RUN SITE: one pinned site does not cover its unpinned neighbour"
expect empty-pin-is-no-pin.selftest.sh         "LEAK-env-i-unpinned"                 "DISK_FREE_OVERRIDE_MB=\"\" is not a pin (the reader treats empty as unset)"
expect kill-switch-on-is-no-pin.selftest.sh    "LEAK-env-i-unpinned"                 "PILOT_DISK_FLOOR_ENABLED=1 is the default, not a pin"
expect literal-path.selftest.sh                "LEAK-env-i-unpinned"                 "a literal …pilot-dispatcher.sh path is a run site too"
expect syntax-check-only.selftest.sh           ""                                    "bash -n is a syntax check, not a run"
expect extraction-only.selftest.sh             ""                                    "sed/awk/grep over the dispatcher is not a run"
expect comment-only.selftest.sh                ""                                    "a run site inside a comment is ignored"
expect other-dispatcher.selftest.sh            ""                                    "a dispatcher that does not read the disk is not asked for a pin"

# ── B: the real tree ────────────────────────────────────────────────────────────────────────────────────
echo "B  real tree"
REAL="$ROOT/real.records"
scan_tree "$SCAN_ASSETS" "$SCAN_SCRIPTS" > "$REAL"; rc=$?
nsites=$(grep -c '^SITE|' "$REAL"); nfiles=$(grep '^SITE|' "$REAL" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')
leaks=$(grep '^SITE|.*|LEAK-' "$REAL")
if [ "$rc" -ne 0 ]; then
  nok "the scan could not complete (rc=$rc) — that is not a pass" "$(grep '^SCAN-ERROR' "$REAL")"
elif [ -n "$leaks" ]; then
  nok "$(printf '%s\n' "$leaks" | wc -l | tr -d ' ') dispatcher run site(s) read the host's real disk unpinned (their outcome depends on how full the disk is)" \
      "$(printf '%s\n' "$leaks" | awk -F'|' '{printf "%s:%s  %s\n", $2, $3, $4}')"
else
  ok "no unpinned dispatcher run site ($nsites run site(s) in $nfiles file(s) judged)"
fi
# Not vacuous: the pilot suite runs the real dispatcher ~34 times; a regex that stops matching must not read as "clean".
pilot_sites=$(grep -c '^SITE|pilot-dispatcher[.]selftest[.]sh|' "$REAL")
if [ "$pilot_sites" -ge 25 ]; then ok "the scan still sees the pilot suite's run sites ($pilot_sites)"; else nok "the scan sees only $pilot_sites run site(s) in pilot-dispatcher.selftest.sh (expected >= 25) — the detector stopped matching, so 'clean' above means nothing"; fi
for s in pilot-choretask-unconditional pilot-eligibility; do
  n=$(grep -c "^SITE|$s[.]selftest[.]sh|" "$REAL")
  if [ "$n" -ge 1 ]; then ok "the scan still sees $s.selftest.sh's run site(s) ($n)"; else nok "the scan sees NO run site in $s.selftest.sh — the detector stopped matching"; fi
done

# ── C: unreadable root is an error, not a clean bill ────────────────────────────────────────────────────
echo "C  could not look != found nothing"
scan_tree "$ROOT/does-not-exist" > "$ROOT/c.records"; crc=$?
if [ "$crc" -eq 3 ] && grep -q '^SCAN-ERROR' "$ROOT/c.records"; then ok "an unreadable scan root returns 3 + SCAN-ERROR (never an empty pass)"; else nok "an unreadable scan root returned rc=$crc: $(cat "$ROOT/c.records")"; fi

echo
echo "selftest-disk-pin-class.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
