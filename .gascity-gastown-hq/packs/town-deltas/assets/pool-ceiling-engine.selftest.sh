#!/usr/bin/env bash
# pool-ceiling-engine.selftest.sh (ga-m9x0lb.2)
#
# Proves the pool-ceiling ENGINE: the one writer of the generated fragment $GC_CITY/.gc/pool-ceiling-engine.toml that makes the
# controller's per-pool max_active_sessions follow the Athos rule (wa-worker 3 by default; 2 when swap used > 6 GB or free disk
# < 6 GB; back to 3 only after 2 sweeps with swap <= 6 GB and disk >= 9 GB; the other pools only go DOWN; the sum of the ceilings
# never above GC_VARIABLE_SESSION_MAX; at most 1 write / 10 min / pool; a daily write breaker; a kill switch that EMPTIES the
# fragment — gc turns an ABSENT included fragment into a config load error, ga-m9x0lb.1).
#
# Hermetic: every scenario runs against a throwaway git repo used as the city; nothing under the real city's .gc is read or
# written (section 23 compares the real paths before and after the whole run and goes RED if any scenario forgot to isolate).
#
# `gc` is faked for speed (bin/gc below) — and the fake is PROVEN, not trusted: section 20 runs the same fragments through the REAL
# `gc config show` and compares what each one resolves. It skips with a notice (never silently) if no usable gc is on PATH.
#
# MUTANTS: section 22 re-runs the behavioural sections against copies of the engine with ONE rule broken each (raise without the
# 2 sweeps, raise with swap > 6 GB, budget ignored, no read-back, unreadable read as clear, kill switch that deletes, ...). Each
# must turn the suite RED; a mutant that does not apply (the engine text drifted) is itself a failure.
#
# Override: POOL_CEILING_ENGINE_PATH (engine under test). PCE_ST_NO_MUTANTS=1 skips section 22 (the slow part); PCE_ST_JOBS=<n> sets how
# many mutants run at once (default 2: the box this runs on is routinely at load 50+); PCE_ST_ONLY="7 9" runs just those sections;
# PCE_ST_MUTANT_FILTER="no-lock dry-run-writes" runs only those mutants (the table is still validated in full).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
ENGINE="${POOL_CEILING_ENGINE_PATH:-$SELF_DIR/pool-ceiling-engine.sh}"
LIB="$SELF_DIR/pool-ceiling.sh"
MUTANT_MODE="${PCE_ST_MUTANT:-0}"

want() { [ -z "${PCE_ST_ONLY:-}" ] && return 0; case " $PCE_ST_ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$MUTANT_MODE" = "1" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3 (got: $1)"; else bad "$3 (expected: $2, got: $1)"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2' in: $1)" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (unexpected '$2' in: $1)" ;; *) ok "$3" ;; esac; }
section() { [ "$MUTANT_MODE" = "1" ] || echo; [ "$MUTANT_MODE" = "1" ] || echo "── $* ──"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

REAL_CITY="${GC_CITY:-$HOME/gt/.gascity-gastown-hq}"
prod_snapshot() { # path|mtime|size (or absent) for everything the engine could create under the REAL city
  local p
  for p in "$REAL_CITY/.gc/pool-ceiling-engine.toml" "$REAL_CITY/.gc/pool-ceiling-engine.off" "$REAL_CITY/.gc/logs/pool-ceiling-engine.log" "$REAL_CITY/.gc/pool-ceiling-engine"; do
    if [ -e "$p" ]; then printf '%s|%s|%s\n' "$p" "$(stat -f '%m' "$p" 2>/dev/null)" "$(stat -f '%z' "$p" 2>/dev/null)"; else printf '%s|absent\n' "$p"; fi
  done
}
PROD_BEFORE="$(prod_snapshot)"

# ── fakes ─────────────────────────────────────────────────────────────────────
mkdir -p "$TMPROOT/bin"
# fake `gc config show --city X --json`: base agents from X/city.toml [[agent]] blocks + X/.gc/pool-ceiling-engine.toml patches, with
# the behaviours measured on the real binary in ga-m9x0lb.1 (parity-checked in section 17):
#   include present + fragment absent => exit 1 | malformed TOML, a string max, an unknown agent => exit 1
#   a typo'd key (max_active_session) => exit 0, ceiling unchanged | max_active_sessions = -1 => accepted (-1 = unlimited)
# FAKE_GC_MODE=fail|notjson, FAKE_GC_IGNORE=1 (never applies the fragment), FAKE_GC_FAIL_NTH=<n> (the n-th call exits 1).
cat > "$TMPROOT/bin/gc" <<'FAKEGC'
#!/usr/bin/env bash
[ "$1 $2" = "config show" ] || exit 2
city=""; while [ $# -gt 0 ]; do case "$1" in --city) city="$2"; shift ;; esac; shift; done
if [ -n "${FAKE_GC_COUNT_FILE:-}" ]; then
  n=$(cat "$FAKE_GC_COUNT_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_GC_COUNT_FILE"
  [ -n "${FAKE_GC_FAIL_NTH:-}" ] && [ "$n" = "$FAKE_GC_FAIL_NTH" ] && { echo "fake gc: forced failure on call $n" >&2; exit 1; }
fi
case "${FAKE_GC_MODE:-ok}" in fail) echo "fake gc: boom" >&2; exit 1 ;; notjson) echo 'this is not json'; exit 0 ;; esac
frag="$city/.gc/pool-ceiling-engine.toml"
agents=$(awk '
  function flush() { if (inag && n != "" && m != "") print n "=" m; n = ""; m = "" }
  /^\[/ { flush(); inag = ($0 ~ /^\[\[agent\]\]/); next }
  /^name[ \t]*=/ { if (!inag) next; s = $0; sub(/^name[ \t]*=[ \t]*"/, "", s); sub(/".*$/, "", s); n = s; next }
  /^max_active_sessions[ \t]*=/ { s = $0; sub(/^[^=]*=[ \t]*/, "", s); sub(/[ \t]*(#.*)?$/, "", s); m = s; next }
  END { flush() }' "$city/city.toml")
if grep -v '^[[:space:]]*#' "$city/city.toml" | grep -qF "pool-ceiling-engine.toml"; then
  [ -e "$frag" ] || { echo "fake gc: loading fragment: no such file or directory" >&2; exit 1; }
  if [ "${FAKE_GC_IGNORE:-0}" != "1" ]; then
    patched=$(awk '
      /^[ \t]*(#.*)?$/ { next }
      /^\[\[patches\.agent\]\][ \t]*$/ { inb = 1; next }
      /^dir[ \t]*=[ \t]*""[ \t]*$/ { next }
      /^name[ \t]*=[ \t]*"[^"]*"[ \t]*$/ { s = $0; sub(/^name[ \t]*=[ \t]*"/, "", s); sub(/".*$/, "", s); nm = s; next }
      /^max_active_sessions[ \t]*=[ \t]*-?[0-9]+[ \t]*$/ { s = $0; sub(/^[^=]*=[ \t]*/, "", s); print nm "=" s; next }
      /^max_active_session[ \t]*=/ { next }               # a typo: gc only WARNS
      { print "MALFORMED"; exit }' "$frag") || exit 1
    case "$patched" in *MALFORMED*) echo "fake gc: parsing fragment" >&2; exit 1 ;; esac
    for e in $patched; do
      nm="${e%%=*}"; v="${e#*=}"
      case " $(echo "$agents" | sed 's/=[^ ]*//g' | tr '\n' ' ')" in *" $nm "*) ;; *) echo "fake gc: agent \"$nm\" not found in merged config" >&2; exit 1 ;; esac
      agents=$(echo "$agents" | awk -F= -v nm="$nm" -v v="$v" '$1 == nm { print nm "=" v; next } { print }')
    done
  fi
fi
printf '{"ok":true,"config":{"Agents":['
first=1; for a in $agents; do [ "$first" = 1 ] || printf ','; first=0; printf '{"Name":"%s","Dir":"","MaxActiveSessions":%s}' "${a%%=*}" "${a#*=}"; done
printf ']}}\n'
FAKEGC
chmod +x "$TMPROOT/bin/gc"
printf '#!/bin/sh\necho "$*" >> "%s/notify.log"\n' "$TMPROOT" > "$TMPROOT/bin/notify"; chmod +x "$TMPROOT/bin/notify"
GCBIN="$TMPROOT/bin/gc"; NOTIFY="$TMPROOT/bin/notify"
# The engine reads city.toml's include array with python3 + tomllib (>= 3.11; pce_include_state). A host without one cannot run this suite
# meaningfully (every scenario would read "cannot tell" and write nothing), so say so once instead of failing a hundred checks.
PYTL=""; for p in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do "$p" -c 'import tomllib' >/dev/null 2>&1 && { PYTL="$p"; break; }; done
[ -n "$PYTL" ] || { echo "FAIL: no python3 >= 3.11 (tomllib) on this host: the engine cannot read city.toml's include array (pce_include_state)"; exit 1; }
printf '#!/bin/sh\nexit 1\n' > "$TMPROOT/bin/py-crash"; printf '#!/bin/sh\necho yes\n' > "$TMPROOT/bin/py-junk"; printf '#!/bin/sh\necho 1\nexit 1\n' > "$TMPROOT/bin/py-late-crash"
chmod +x "$TMPROOT/bin/py-crash" "$TMPROOT/bin/py-junk" "$TMPROOT/bin/py-late-crash"
# The engine runs under the interpreter the launchd model names (/bin/bash: 3.2 on macOS), never under whichever bash is first on PATH: a
# "bash 3.2 compatible" claim exercised only under bash 5 is not exercised (gate ga-a7bsxr: a parse error in `status` went unseen for that reason).
ENGBASH="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$SELF_DIR/pool-ceiling-engine.plist.template" 2>/dev/null)"
[ -x "$ENGBASH" ] || { echo "FAIL: cannot read the plist model's interpreter (ProgramArguments:0 of pool-ceiling-engine.plist.template): '$ENGBASH'"; exit 1; }

# ── fixture city: a throwaway git repo ────────────────────────────────────────
T0=1790000000          # a real-looking epoch (2026-09-21): the engine dates its daily counter with it
C=""
mk_city() { # <name> — fresh city: wa-worker 2, ps-worker 1, gate-reviewer 3 (committed), include present, fragment empty, .on
  C="$TMPROOT/$1/city"; mkdir -p "$C/.gc" "$C/agents/wa-worker" "$C/agents/ps-worker" "$C/agents/gate-reviewer"
  printf 'min_active_sessions = 0\nmax_active_sessions = 2\n' > "$C/agents/wa-worker/agent.toml"
  printf 'min_active_sessions = 0\nmax_active_sessions = 1\n' > "$C/agents/ps-worker/agent.toml"
  printf 'max_active_sessions = 3 # gate\nmin_active_sessions = 0\n' > "$C/agents/gate-reviewer/agent.toml"
  cat > "$C/city.toml" <<'CITYTOML'
include = [".gc/pool-ceiling-engine.toml"]

[workspace]
name = "selftest"

[[agent]]
name = "wa-worker"
max_active_sessions = 2

[[agent]]
name = "ps-worker"
max_active_sessions = 1

[[agent]]
name = "gate-reviewer"
max_active_sessions = 3
CITYTOML
  printf '# empty\n' > "$C/.gc/pool-ceiling-engine.toml"
  : > "$C/.gc/pool-ceiling-engine.on"
  printf '.gc/\n' > "$C/.gitignore"
  ( cd "$C" && git init -q . && git add city.toml agents .gitignore && git -c user.email=t@t -c user.name=t commit -q -m base ) >/dev/null 2>&1
  : > "$TMPROOT/notify.log"
}
# eng <now> <swap_used_mb|""> <disk_free_mb|""> [VAR=val ...] — one engine `run` (empty swap/disk = the reading could not be taken)
eng() {
  local now="$1" swap="$2" disk="$3"; shift 3
  env POOL_CEILING_ENGINE_CITY="$C" POOL_CEILING_ENGINE_NOW="$now" POOL_CEILING_T_SWAP_USED_MB="$swap" POOL_CEILING_T_DISK_FREE_MB="$disk" \
      POOL_CEILING_ENGINE_GC="$GCBIN" POOL_CEILING_ENGINE_NOTIFY="$NOTIFY" POOL_CEILING_ENGINE_PILOT_PLIST="$TMPROOT/no-such.plist" POOL_CEILING_ENGINE_PYTHON="$PYTL" \
      POOL_CEILING_ENGINE_LIB="$LIB" GC_VARIABLE_SESSION_MAX="${BUDGET:-9}" "$@" "$ENGBASH" "$ENGINE" "${ENG_CMD:-run}" 2>&1
}
cm() { ( cd "$C" && git add agents && git -c user.email=t@t -c user.name=t commit -q -m "${1:-edit}" ) >/dev/null 2>&1; }   # commit the agents/ edits made to the fixture city
eng_quiet() { eng "$@" >/dev/null 2>&1; }
# levels — the fragment's "pool=level ..." read by an INDEPENDENT awk (not the engine's own parser)
levels() { awk '/^name[ \t]*=/ { s = $0; sub(/^name[ \t]*=[ \t]*"/, "", s); sub(/".*$/, "", s); n = s } /^max_active_sessions[ \t]*=/ { s = $0; sub(/^[^=]*=[ \t]*/, "", s); printf "%s%s=%s", (c++ ? " " : ""), n, s }' "$C/.gc/pool-ceiling-engine.toml" 2>/dev/null; }
logf() { cat "$C/.gc/logs/pool-ceiling-engine.log" 2>/dev/null; }
events() { logf | grep -F "event=$1" ; }
nevents() { logf | grep -cF "event=$1" | tr -d ' '; }
tree_sig() { ( cd "$C" && find . -path ./.git -prune -o \( -type f -o -type d \) -print | LC_ALL=C sort | while IFS= read -r f; do stat -f '%N %m %z' "$f"; done | md5 -q ); }

# source the engine for the pure-function sections (no side effects on source; pce_init reads the env)
# shellcheck disable=SC1090
. "$ENGINE"
export POOL_CEILING_ENGINE_CITY="$TMPROOT/pure/city" POOL_CEILING_ENGINE_LIB="$LIB"
mkdir -p "$TMPROOT/pure/city"
pce_init

# ═════════════════════════════════════════════════════════════════════════════
section "1. sourcing the engine has no side effect; knobs with garbage fall back"
eq "$(ls -A "$TMPROOT/pure/city")" "" "sourcing + pce_init created nothing under the city"
eq "$("$ENGBASH" -c 'echo "${BASH_VERSINFO[0]}"')" "3" "the engine runs under the plist model's interpreter ($ENGBASH), bash 3.x: 'bash 3.2 compatible' is exercised, not assumed"
eq "$(POOL_CEILING_ENGINE_CLEAR_SWEEPS=abc _pce_knob POOL_CEILING_ENGINE_CLEAR_SWEEPS 2 1)" "2" "garbage knob -> default"
eq "$(POOL_CEILING_ENGINE_CLEAR_SWEEPS=0 _pce_knob POOL_CEILING_ENGINE_CLEAR_SWEEPS 2 1)" "2" "knob below its minimum -> default (0 sweeps would mean 'raise without waiting')"
eq "$(POOL_CEILING_ENGINE_CLEAR_SWEEPS=3 _pce_knob POOL_CEILING_ENGINE_CLEAR_SWEEPS 2 1)" "3" "valid knob honoured"

# ═════════════════════════════════════════════════════════════════════════════
section "2. pressure: swap > 6 GB OR disk < 6 GB is high; swap <= 6 GB AND disk >= 9 GB is clear; 6..9 GB holds; unreadable is never clear"
P() { pce_pressure "$1" "$2"; }
eq "$(P 6144 9216)" "clear"   "swap exactly 6 GB, disk exactly 9 GB -> clear (the rule is <= / >=)"
eq "$(P 6145 20000)" "high"   "swap 6 GB + 1 MB -> high, whatever the disk"
eq "$(P 0 6143)" "high"       "disk 6 GB - 1 MB -> high, whatever the swap"
eq "$(P 6144 6144)" "band"    "disk exactly 6 GB is NOT low (the rule is < 6): hysteresis band"
eq "$(P 100 9215)" "band"     "disk 9 GB - 1 MB -> band: not enough to come back"
eq "$(P "" 20000)" "unknown"  "swap unreadable + disk fine -> unknown, NOT clear"
eq "$(P 100 "")" "unknown"    "disk unreadable + swap fine -> unknown, NOT clear"
eq "$(P "" "")" "unknown"     "both unreadable -> unknown"
eq "$(P 7000 "")" "high"      "swap high + disk unreadable -> high: one positive reading is enough"
eq "$(P "" 100)" "high"       "disk low + swap unreadable -> high"
eq "$(P abc 20000)" "unknown" "garbage swap reading -> unknown"

# ═════════════════════════════════════════════════════════════════════════════
section "3. decision: lower now, raise after 2 counted sweeps and the rate limit, hold in the band, restore when blind for too long"
D() { pce_decide "$@"; }   # C L floor ceil pressure clear_streak unknown_streak rate_ok
eq "$(D 2 3 2 3 high 0 0 1)" "2|lower:pressure"               "wa-worker 3 under pressure -> 2 at once"
eq "$(D 2 2 2 3 high 0 0 1)" "2|hold:at-floor"                "already at the floor: nothing to lower"
eq "$(D 3 3 2 3 high 0 0 0)" "2|lower:pressure"               "lowering ignores the rate limit ('baixar na hora')"
eq "$(D 2 2 2 3 clear 1 0 1)" "2|hold:clear-streak-1/2"       "1 clear sweep is not enough"
eq "$(D 2 2 2 3 clear 2 0 1)" "3|raise:clear-2-sweeps"        "2 clear sweeps -> raise one step"
eq "$(D 2 2 2 3 clear 2 0 0)" "2|hold:rate-limited"           "2 clear sweeps but written < 10 min ago -> hold"
eq "$(D 2 3 2 3 clear 5 0 1)" "3|hold:at-ceiling"             "at the ceiling nothing to raise"
eq "$(D 2 2 2 3 band 9 0 1)" "2|hold:band"                    "band never raises, however long the streak was"
eq "$(D 2 3 2 3 band 0 0 1)" "3|hold:band"                    "band never lowers either (hysteresis)"
eq "$(D 2 2 2 3 unknown 0 5 1)" "2|hold:unreadable"           "unreadable never raises"
eq "$(D 2 3 2 3 unknown 0 2 1)" "3|hold:unreadable"           "blind but not for long: hold"
eq "$(D 2 3 2 3 unknown 0 3 1)" "2|restore:unreadable-3-sweeps" "blind for 3 sweeps while ABOVE committed -> back to committed"
eq "$(D 3 2 2 3 unknown 0 9 1)" "2|hold:unreadable"           "blind while BELOW committed: stays lowered (the inert direction), no raise"
eq "$(D 3 2 2 3 clear 2 0 1)" "3|raise:clear-2-sweeps"        "a pool lowered by pressure climbs back to committed on the same rule"

# ═════════════════════════════════════════════════════════════════════════════
section "4. per-pool bounds: wa-worker may exceed committed (3); the others never do; nothing below 1"
eq "$(pce_floor wa-worker 2)/$(pce_ceil wa-worker 2)" "2/3" "wa-worker committed 2 -> floor 2, ceiling 3 (the Athos default)"
eq "$(pce_floor ps-worker 1)/$(pce_ceil ps-worker 1)" "1/1" "ps-worker committed 1 -> cannot move"
eq "$(pce_floor gate-reviewer 3)/$(pce_ceil gate-reviewer 3)" "2/3" "gate-reviewer committed 3 -> floor 2 (one gate run needs 2), ceiling = committed"
eq "$(pce_floor wa-worker 1)/$(pce_ceil wa-worker 1)" "1/3" "a floor is never above committed"
eq "$(pce_floor wa-worker 4)/$(pce_ceil wa-worker 4)" "2/4" "a ceiling is never below committed (the engine does not lower by clamping)"
eq "$(POOL_CEILING_ENGINE_WA_WORKER_CEIL=99 pce_ceil wa-worker 2)" "8" "a knob cannot push a ceiling past the hard max"
eq "$(pce_ceil some-other-pool 2)" "2" "any other pool: ceiling = committed"

# ═════════════════════════════════════════════════════════════════════════════
section "5. rendering: only allowlisted pools, only integers in [1, hard max]; the file is always a valid include"
R() { pce_fragment_render "$1"; }
body="$(R "wa-worker=3")"; rc=$?
eq "$rc" "0" "render accepts wa-worker=3"
has "$body" '[[patches.agent]]' "has the table header"
has "$body" 'dir = ""' "has dir = \"\" (like the other blocks)"
has "$body" 'name = "wa-worker"' "names the pool"
has "$body" 'max_active_sessions = 3' "exact key (a typo'd key is only a gc WARNING: the ceiling would silently not move)"
has "$body" '# GENERATED' "carries the do-not-edit header"
has "$body" 'MUST exist' "the header says the file may never be deleted"
eq "$(R "" | grep -vc '^#')" "0" "no entries -> comment-only (measured exit 0, config identical to baseline)"
R "wa-worker=0" >/dev/null; eq "$?" "1" "REFUSES 0 (gc accepts it and the pool would open nothing)"
R "wa-worker=-1" >/dev/null; eq "$?" "1" "REFUSES -1 (gc accepts it as UNLIMITED)"
R "wa-worker=abc" >/dev/null; eq "$?" "1" "REFUSES a non-integer"
R 'wa-worker="3"' >/dev/null; eq "$?" "1" "REFUSES a quoted value (gc: incompatible types, load error)"
R "wa-worker=9" >/dev/null; eq "$?" "1" "REFUSES a level above the hard max"
R "gastown.dog=4" >/dev/null; eq "$?" "1" "REFUSES gastown.dog (eval-window-concurrency-guard owns it; the fragment would override the guard)"
R "no-such-agent=2" >/dev/null; eq "$?" "1" "REFUSES a pool outside the allowlist (an unknown agent is a config LOAD ERROR)"
R "wa-worker=3 wa-worker=2" >/dev/null; eq "$?" "1" "REFUSES a duplicate pool (the last one would win silently)"
eq "$(R "wa-worker=3 gate-reviewer=2" | grep -c '^\[\[patches.agent\]\]')" "2" "two entries -> two blocks"

# ═════════════════════════════════════════════════════════════════════════════
section "6. parsing: the engine only trusts what it would have rendered"
PF="$TMPROOT/frag.toml"
R "wa-worker=3 gate-reviewer=2" > "$PF"
eq "$(pce_fragment_parse "$PF" | tr '\n' ' ')" "wa-worker=3 gate-reviewer=2 " "round trip"
: > "$PF"; out="$(pce_fragment_parse "$PF")"; eq "$?/$out" "0/" "0 bytes -> well-formed, no entries"
printf '# only a comment\n\n' > "$PF"; out="$(pce_fragment_parse "$PF")"; eq "$?/$out" "0/" "comment-only -> well-formed, no entries"
parse_rc() { printf '%b' "$1" > "$PF"; pce_fragment_parse "$PF" >/dev/null; echo $?; }
eq "$(parse_rc '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_session = 3\n')" "1" "typo'd key -> FOREIGN (rewritten, never trusted)"
eq "$(parse_rc '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_sessions = 3\nextra = 1\n')" "1" "an extra key -> FOREIGN"
eq "$(parse_rc '[[patches.agent]]\nname = "wa-worker"\nmax_active_sessions = 3\n')" "1" "missing dir -> FOREIGN"
eq "$(parse_rc '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_sessions = 3\n[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_sessions = 2\n')" "1" "duplicate pool -> FOREIGN"
eq "$(parse_rc '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_sessions = 0\n')" "1" "level 0 -> FOREIGN"
eq "$(parse_rc '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_sessions = 03\n')" "1" "level 03 -> FOREIGN (a leading zero is no TOML integer: the controller would refuse to load it)"
eq "$(_pce_int 09; echo $?)/$(_pce_int 00; echo $?)/$(_pce_int 0; echo $?)/$(_pce_int 9; echo $?)/$(_pce_int ''; echo $?)" "1/1/0/0/1" "_pce_int is a canonical decimal: 09 and 00 are not (bad octal inside \$(( ))), 0 and 9 are, empty is not"
eq "$(parse_rc '[other]\nx = 1\n')" "1" "a foreign table -> FOREIGN"
eq "$(parse_rc '[[patches.agent]\ndir = ""\n')" "1" "malformed header -> FOREIGN"
pce_fragment_parse "$TMPROOT/does-not-exist.toml" >/dev/null; eq "$?" "2" "absent -> rc 2 (not 'empty')"

csw() { local n="$1" t="$2" i=0; shift 2; while [ "$i" -lt "$n" ]; do eng_quiet $((t + i * 300)) 4000 11264 "$@"; i=$((i + 1)); done; }   # n clear sweeps, 5 min apart
resolved() { "$GCBIN" config show --city "$C" --json 2>/dev/null | jq -r --arg n "$1" '.config.Agents[] | select(.Name == $n) | .MaxActiveSessions'; }

# ═════════════════════════════════════════════════════════════════════════════
if want 7; then section "7. raising: only after 2 COUNTED sweeps (swap <= 6 GB, disk >= 9 GB); two runs a few seconds apart are one sweep"
mk_city s7
eng_quiet "$T0" 4000 11264
eq "$(levels)" "" "sweep 1 (clear): counted 1/2, nothing written"
eng_quiet $((T0 + 10)) 4000 11264
eq "$(levels)" "" "a run 10 s later is NOT a new sweep (gap < 240 s): still 1/2"
eng_quiet $((T0 + 300)) 4000 11264
eq "$(levels)" "wa-worker=3" "sweep 2 (clear): wa-worker 2 -> 3 (the Athos default)"
eq "$(nevents write)" "1" "exactly one write"
has "$(events write)" "readback=ok" "the write was read back through gc config show"
eq "$(resolved wa-worker)" "3" "the config the controller loads now says 3"
eq "$(resolved ps-worker)/$(resolved gate-reviewer)" "1/3" "ps-worker and gate-reviewer untouched"
# "2 counted sweeps" means 2 CONSECUTIVE ones: a clear streak does not survive a long silence (a breaker trip, .on removed and re-added, the Mac asleep)
mk_city s7b
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 5000)) 4000 11264
eq "$(levels)" "" "1 clear sweep, then 5000 s of silence: the streak does NOT carry over, 1 more clear sweep is not 2"
eng_quiet $((T0 + 5300)) 4000 11264
eq "$(levels)" "wa-worker=3" "the next one is the 2nd consecutive sweep: raised"
mk_city s7c
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 900)) 4000 11264
eq "$(levels)" "wa-worker=3" "a 15 min gap (a couple of missed runs) is still consecutive: the expiry is 20 min, not the 4-min sweep gap"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 8; then section "8. swap above 6 GB never raises wa-worker, and takes the gate down"
mk_city s8
i=0; while [ "$i" -lt 6 ]; do eng_quiet $((T0 + 3000 + i * 300)) 7000 11264; i=$((i + 1)); done
eq "$(levels)" "gate-reviewer=2" "swap 7000 MB: wa-worker not raised; gate-reviewer lowered 3 -> 2 (the others only go DOWN)"
eq "$(nevents write)" "1" "one write for all the sweeps under pressure (nothing to move after the first)"
mk_city s8b
eng_quiet "$T0" 4000 6000; eng_quiet $((T0 + 300)) 4000 6000; eng_quiet $((T0 + 600)) 4000 6000
eq "$(levels)" "gate-reviewer=2" "disk 6000 MB (< 6 GB) is pressure too: no raise, gate lowered"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 9; then section "9. lowering is immediate; raising again waits for 2 sweeps AND the 10-min rate limit"
mk_city s9
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 300)) 4000 11264
eq "$(levels)" "wa-worker=3" "raised"
eng_quiet $((T0 + 360)) 7000 11264
eq "$(levels)" "gate-reviewer=2" "60 s after the raise, pressure: wa-worker back to committed (entry gone) and gate lowered — 'baixar na hora'"
eng_quiet $((T0 + 660)) 4000 11264 POOL_CEILING_ENGINE_RATE_SECS=900
eng_quiet $((T0 + 960)) 4000 11264 POOL_CEILING_ENGINE_RATE_SECS=900
eq "$(levels)" "gate-reviewer=2" "2 clear sweeps but the last write was 600 s ago (< 900 s): no raise yet"
has "$(events sweep | grep "ts=$((T0 + 960))" | grep 'pool=wa-worker')" "hold:rate-limited" "the log says WHY (rate-limited)"
eng_quiet $((T0 + 1260)) 4000 11264 POOL_CEILING_ENGINE_RATE_SECS=900
eq "$(levels)" "wa-worker=3" "900 s after the last write: wa-worker 3 again, gate-reviewer back to committed (entry gone)"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 10; then section "10. the 6..9 GB band holds; an unreadable signal never raises; blind for too long goes back to committed"
mk_city s10a
csw 2 "$T0"
eng_quiet $((T0 + 600)) 4000 7000; eng_quiet $((T0 + 900)) 4000 7000
eq "$(levels)" "wa-worker=3" "raised, then disk in the band (7000 MB): NOT lowered (hysteresis)"
mk_city s10b
csw 2 "$T0"; eng_quiet $((T0 + 600)) 7000 11264
eq "$(levels)" "gate-reviewer=2" "pressure: back down"
i=0; while [ "$i" -lt 6 ]; do eng_quiet $((T0 + 900 + i * 300)) 4000 7000; i=$((i + 1)); done
eq "$(levels)" "gate-reviewer=2" "6 sweeps in the band after a lowering: still lowered (the band never raises)"
mk_city s10c
i=0; while [ "$i" -lt 6 ]; do eng_quiet $((T0 + i * 300)) "" 11264; i=$((i + 1)); done
eq "$(levels)" "" "swap unreadable for 6 sweeps: never raises (unreadable is not clear)"
mk_city s10d
csw 2 "$T0"
eng_quiet $((T0 + 600)) "" 11264; eng_quiet $((T0 + 900)) "" 11264
eq "$(levels)" "wa-worker=3" "blind for 2 sweeps: holds the raised level"
eng_quiet $((T0 + 1200)) "" 11264
eq "$(levels)" "" "blind for 3 sweeps while above committed: back to committed"
has "$(events sweep | grep "ts=$((T0 + 1200))" | grep 'pool=wa-worker')" "restore:unreadable-3-sweeps" "the log says WHY"
mk_city s10e
csw 1 "$T0"; printf 'junk, not key=value\n' > "$C/.gc/pool-ceiling-engine/wa-worker.state"
eng_quiet $((T0 + 300)) 4000 11264; eng_quiet $((T0 + 600)) 4000 11264
eq "$(levels)" "" "a CORRUPT state file is not 'never written': at T0+600 the streak would be 2 and, read as 0, the rate limit would let it raise - instead it is treated as just written"
eq "$(nevents state-corrupt)" "1" "and the corruption is logged once, not silently absorbed"
eng_quiet $((T0 + 900)) 4000 11264
eq "$(levels)" "wa-worker=3" "the file was rewritten healthy and 10 min after the corruption the raise lands"
# a state write that FAILS (disk full is the very pressure this engine reacts to) is logged, never silent
SWF=$( ( PCE_DRY=0; PCE_NOW="$T0"; PCE_STATE="$TMPROOT/s10f-no-such-dir/state"; PCE_LOG="$TMPROOT/s10f.log"
         pce_state_put wa-worker 1 0 "$T0" "$T0"; pce_trip daily "x"; cat "$PCE_LOG" ) 2>&1 )
has "$SWF" "what=wa-worker.state" "a per-pool state that cannot be written is logged (the streaks and the rate limit restart)"
has "$SWF" "what=trip" "a trip that cannot be written is logged"
SWD=$( ( PCE_DRY=0; PCE_NOW="$T0"; PCE_STATE="$TMPROOT/s10f-no-such-dir/state"; PCE_LOG="$TMPROOT/s10g.log"; pce_daily_bump; cat "$PCE_LOG" ) 2>&1 )
has "$SWD" "what=daily-counter" "a daily counter that cannot be written is logged (the breaker may undercount)"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 11; then section "11. the other pools only go DOWN: never above what is committed, however long the machine is clear"
mk_city s11
csw 12 "$T0"
eq "$(levels)" "wa-worker=3" "12 clear sweeps: only wa-worker moved"
eq "$(resolved ps-worker)/$(resolved gate-reviewer)" "1/3" "ps-worker 1 and gate-reviewer 3 as committed"
eng_quiet $((T0 + 5000)) 7000 11264
eq "$(levels)" "gate-reviewer=2" "pressure lowers the gate (and wa-worker back to committed)"
i=0; while [ "$i" -lt 12 ]; do eng_quiet $((T0 + 6000 + i * 300)) 4000 11264; i=$((i + 1)); done
eq "$(levels)" "wa-worker=3" "clear again: gate-reviewer climbs back to 3 and STOPS there (entry gone); wa-worker is the only deviation"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 12; then section "12. the sum of the ceilings never exceeds GC_VARIABLE_SESSION_MAX"
mk_city s12a
BUDGET=6 csw 4 "$T0"
eq "$(levels)" "" "budget 6: raising wa-worker would make 3+1+3 = 7 > 6: cancelled, however many sweeps"
has "$(events budget)" "budget=6" "the log says the budget stopped it"
eq "$(nevents write)" "0" "no write at all"
mk_city s12b
BUDGET=7 csw 2 "$T0"
eq "$(levels)" "wa-worker=3" "budget 7: 7 <= 7 is allowed (the bound is <=)"
PLIST="$TMPROOT/pilot.plist"; /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' -c 'Add :EnvironmentVariables:GC_VARIABLE_SESSION_MAX string 6' "$PLIST" >/dev/null 2>&1
mk_city s12c
BUDGET=9 csw 4 "$T0" POOL_CEILING_ENGINE_PILOT_PLIST="$PLIST"
eq "$(levels)" "" "env says 9 but the live Pilot plist says 6: the SMALLER one wins"
b() { ( unset GC_VARIABLE_SESSION_MAX; env "$@" bash -c ". '$ENGINE'; pce_init; pce_budget" ); }
eq "$(b POOL_CEILING_ENGINE_PILOT_PLIST="$PLIST")" "6" "budget from the plist alone"
eq "$(b GC_VARIABLE_SESSION_MAX=4 POOL_CEILING_ENGINE_PILOT_PLIST="$PLIST")" "4" "env 4 < plist 6 -> 4"
eq "$(b POOL_CEILING_ENGINE_PILOT_PLIST=/nonexistent)" "6" "neither readable -> the dispatchers' own default 6 (the inert direction)"
eq "$(b GC_VARIABLE_SESSION_MAX=abc POOL_CEILING_ENGINE_PILOT_PLIST=/nonexistent)" "6" "garbage env -> default, not 0 and not unlimited"
# A ceiling that cannot be READ is not a ceiling of 0 (it would under-count the sum and let a raise through, gate ga-a7bsxr): while any pool is
# unknown nothing is raised. The operator's pause (committed 0) is the only legitimate zero, and lowering never waits for the budget.
mk_city s12d
printf '# no max_active_sessions line here\n' > "$C/agents/ps-worker/agent.toml"; cm unreadable
BUDGET=6 csw 4 "$T0"
eq "$(levels)" "" "ps-worker's committed ceiling UNREADABLE, budget 6: wa-worker 3 + ps-worker ? + gate-reviewer 3 cannot be shown <= 6 - no raise, however many sweeps"
has "$(events budget)" "unknown=ps-worker" "the log says the budget stopped it and names the pool whose ceiling is unknown"
eq "$(nevents write)" "0" "no write at all"
mk_city s12e
printf 'max_active_sessions = 0\n' > "$C/agents/ps-worker/agent.toml"; cm pause
BUDGET=6 csw 2 "$T0"
eq "$(levels)" "wa-worker=3" "ps-worker PAUSED (committed 0, a KNOWN zero): 3 + 0 + 3 = 6 <= 6, the raise lands - a pause is not 'unknown'"
mk_city s12f
printf '# no max_active_sessions line here\n' > "$C/agents/ps-worker/agent.toml"; cm unreadable
csw 2 "$T0"; eng_quiet $((T0 + 700)) 7000 11264
eq "$(levels)" "gate-reviewer=2" "an unknown ceiling blocks only RAISES: under pressure the known pools are still lowered"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 13; then section "13. write hygiene: atomic, no leftovers, no tracked file touched, routine writes are silent"
mk_city s13
csw 2 "$T0"
eq "$(ls "$C/.gc" | grep -c 'tmp')" "0" "no tmp file left in .gc"
eq "$(ls "$C/.gc/pool-ceiling-engine" | grep -c 'tmp')" "0" "no tmp file left in the state dir"
eq "$(ENG_CMD=check eng "$T0" 4000 11264)" "ok: include present, fragment present and well-formed" "check: the fragment is well-formed"
eq "$(cd "$C" && git status --porcelain)" "" "city.toml and every agents/*/agent.toml untouched (git status clean)"
eq "$(cat "$TMPROOT/notify.log")" "" "a routine raise does not notify"
eq "$(ls "$C/.gc/pool-ceiling-engine" | grep -c 'lock')" "0" "the lock is released after a run"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 14; then section "14. read-back and preflight: a write that did not do what was written is undone at once"
mk_city s14a
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 300)) 4000 11264 FAKE_GC_IGNORE=1
eq "$(levels)" "" "controller does not apply the fragment (or a typo'd key): read-back sees 2 != 3 -> fragment EMPTIED"
has "$(events readback-failed)" "intended=3" "the log names the mismatch"
eq "$(sed -n 's/^kind=//p' "$C/.gc/pool-ceiling-engine/tripped")" "manual" "a read-back MISMATCH trips until a human resets"
has "$(cat "$TMPROOT/notify.log")" "FAILED" "and notifies"
csw 4 $((T0 + 600))
eq "$(levels)" "" "tripped: 4 healthy clear sweeps later it is still inert"
eq "$(nevents tripped)" "1" "a trip is logged ONCE when it appears, not on every 5-minute sweep"
eq "$(nevents restore)" "1" "and the fragment is emptied once (a no-op restore is not logged again and again)"
eng_quiet $((T0 + 100000)) 4000 11264; eng_quiet $((T0 + 100300)) 4000 11264
eq "$(levels)" "" "a manual trip does not expire with the day"
ENG_CMD=reset eng_quiet $((T0 + 200000)) 4000 11264
csw 2 $((T0 + 200100))
eq "$(levels)" "wa-worker=3" "after 'reset' the engine works again"
mk_city s14b; : > "$TMPROOT/cnt"
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 300)) 4000 11264 FAKE_GC_COUNT_FILE="$TMPROOT/cnt" FAKE_GC_FAIL_NTH=2
eq "$(levels)" "" "gc fails the READ-BACK (call 2 of the run): the write is undone"
eq "$(sed -n 's/^kind=//p' "$C/.gc/pool-ceiling-engine/tripped")" "daily" "unreadable (not a proven mismatch) trips only until tomorrow"
eng_quiet $((T0 + 100000)) 4000 11264; eng_quiet $((T0 + 100300)) 4000 11264
eq "$(levels)" "wa-worker=3" "next day: trip expired, 2 sweeps, raised"
has "$(events trip-expired)" "was=readback-unreadable" "the expiry is logged with what it was"
mk_city s14c
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 300)) 4000 11264 FAKE_GC_MODE=fail
eq "$(levels)" "" "gc down BEFORE writing: preflight cannot confirm the pool exists -> nothing written"
has "$(events preflight-failed)" "rc=2" "logged as could-not-read"
eq "$([ -e "$C/.gc/pool-ceiling-engine/tripped" ] && echo trip || echo none)" "none" "a failed preflight is not a trip: nothing was written"
eng_quiet $((T0 + 600)) 4000 11264
eq "$(levels)" "wa-worker=3" "gc back: the pending raise lands at the next sweep"
mk_city s14d
mkdir -p "$C/agents/ghost-worker"; printf 'max_active_sessions = 2\n' > "$C/agents/ghost-worker/agent.toml"
( cd "$C" && git add agents && git -c user.email=t@t -c user.name=t commit -q -m ghost ) >/dev/null 2>&1
G="POOL_CEILING_ENGINE_POOLS=wa-worker ps-worker gate-reviewer ghost-worker"
BUDGET=12 eng_quiet "$T0" 4000 11264 "$G" POOL_CEILING_ENGINE_GHOST_WORKER_CEIL=3; BUDGET=12 eng_quiet $((T0 + 300)) 4000 11264 "$G" POOL_CEILING_ENGINE_GHOST_WORKER_CEIL=3
eq "$(levels)" "" "an allowlisted pool that is NOT in the config: nothing written (it would be a config LOAD ERROR), not even the legitimate raise"
has "$(events preflight-failed)" "ghost-worker" "the log names the missing agent"
BUDGET=12 eng_quiet $((T0 + 600)) 4000 11264 "$G" POOL_CEILING_ENGINE_GHOST_WORKER_CEIL=3; BUDGET=12 eng_quiet $((T0 + 900)) 4000 11264 "$G" POOL_CEILING_ENGINE_GHOST_WORKER_CEIL=3
eq "$(grep -c 'not writing' "$TMPROOT/notify.log")" "1" "the same missing agent over 4 sweeps notifies ONCE (the log line was deduplicated, the notification was not)"
mk_city s14g
eng_quiet "$T0" 4000 11264; chmod 555 "$C/.gc"
eng_quiet $((T0 + 300)) 4000 11264; eng_quiet $((T0 + 600)) 4000 11264; eng_quiet $((T0 + 900)) 4000 11264
chmod 755 "$C/.gc"
eq "$(nevents write-failed)" "1" "a fragment that cannot be written (the .gc dir is read-only) is logged once, not on every 5-minute sweep"
eq "$(grep -c 'could not write' "$TMPROOT/notify.log")" "1" "and notified once"
# `reset` says it cleared the trip only when the files are really gone (an unwritable state dir used to print the same success line, rc 0)
mk_city s14e; SD="$C/.gc/pool-ceiling-engine"; mkdir -p "$SD"; printf 'kind=manual\ndate=2026-09-21\nreason=readback-mismatch\n' > "$SD/tripped"
chmod 555 "$SD"; out="$(ENG_CMD=reset eng "$T0" 4000 11264)"; rc=$?; chmod 755 "$SD"
eq "$rc" "1" "reset with an UNWRITABLE state dir: exit 1, not 0"
has "$out" "FALHOU" "and it says it FAILED"
hasnt "$out" "zerados" "and never claims the trip was cleared"
eq "$([ -e "$SD/tripped" ] && echo tripped || echo free)" "tripped" "(the trip really is still armed)"
has "$(events reset-failed)" "tripped" "the failure is logged, with what was left"
out="$(ENG_CMD=reset eng "$T0" 4000 11264)"; rc=$?
eq "$rc/$([ -e "$SD/tripped" ] && echo tripped || echo free)" "0/free" "reset with a writable state dir: exit 0 and the trip is gone"
has "$out" "zerados" "and it says so"
# a daily trip is expired only by a DIFFERENT, readable date: where the stored date cannot be read it is not 'another day' (the engine always writes it; a
# hand-edited or foreign file may not) - step 1b guards the CURRENT date for the same collapse, this is its sibling
n=0
for tc in 'no date line|reason=daily-breaker' 'empty date|date=\nreason=daily-breaker' 'garbage date|date=not-a-date\nreason=daily-breaker'; do
  n=$((n + 1)); mk_city "s14f$n"; SD="$C/.gc/pool-ceiling-engine"; mkdir -p "$SD"; printf 'kind=daily\n%b\n' "${tc#*|}" > "$SD/tripped"
  csw 3 "$T0"
  eq "$(levels)/$(nevents trip-expired)/$([ -e "$SD/tripped" ] && echo tripped || echo free)" "/0/tripped" "a daily trip with ${tc%%|*}: NOT expired, still tripped, nothing written"
done
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 15; then section "15. daily write breaker: past the limit the next write is replaced by EMPTYING the fragment, until tomorrow"
mk_city s15
K="POOL_CEILING_ENGINE_DAILY_MAX=2 POOL_CEILING_ENGINE_RATE_SECS=0 POOL_CEILING_ENGINE_SWEEP_GAP_SECS=0"
eng_quiet "$T0" 4000 11264 $K; eng_quiet $((T0 + 1)) 4000 11264 $K
eq "$(levels)" "wa-worker=3" "write 1: raise"
eng_quiet $((T0 + 2)) 7000 11264 $K
eq "$(levels)" "gate-reviewer=2" "write 2: pressure lowers"
eng_quiet $((T0 + 3)) 4000 11264 $K; eng_quiet $((T0 + 4)) 4000 11264 $K
eq "$(levels)" "" "the 3rd write would exceed 2 per day: fragment EMPTIED instead (the safe state)"
has "$(events breaker)" "max=2" "logged"
has "$(cat "$TMPROOT/notify.log")" "breaker" "notified"
eng_quiet $((T0 + 5)) 4000 11264 $K; eng_quiet $((T0 + 6)) 4000 11264 $K
eq "$(levels)" "" "tripped for the day: stays inert however clear the machine is"
eng_quiet $((T0 + 100000)) 4000 11264 $K; eng_quiet $((T0 + 100001)) 4000 11264 $K
eq "$(levels)" "wa-worker=3" "next day the counter and the trip are gone"
mk_city s15b
eng_quiet "$T0" 4000 11264; mkdir -p "$C/.gc/pool-ceiling-engine"; printf 'garbage\n' > "$C/.gc/pool-ceiling-engine/daily"
eng_quiet $((T0 + 300)) 4000 11264
eq "$(levels)" "" "a daily counter that EXISTS but cannot be read counts as AT THE LIMIT (read as 0 it would switch the breaker off for good)"
has "$(events breaker)" "writes_today=10" "the log shows it as at the limit"
# a calendar date that cannot be computed is not "a new day": the counter and the trip are dated with it. The fake date fails on -r / -d only
# (the epoch, `+%s`, still works), which is the one half of the clock the engine reads twice.
mkdir -p "$TMPROOT/nodate"; printf '#!/bin/sh\ncase "${1:-}" in -r|-d) exit 1 ;; esac\nexec /bin/date "$@"\n' > "$TMPROOT/nodate/date"; chmod +x "$TMPROOT/nodate/date"
NODATE="PATH=$TMPROOT/nodate:$PATH"
mk_city s15c
K1="POOL_CEILING_ENGINE_DAILY_MAX=1 POOL_CEILING_ENGINE_RATE_SECS=0 POOL_CEILING_ENGINE_SWEEP_GAP_SECS=0"
eng_quiet "$T0" 4000 11264 $K1; eng_quiet $((T0 + 1)) 4000 11264 $K1
eq "$(levels)" "wa-worker=3" "write 1 of the day (the limit is 1): raise"
eng_quiet $((T0 + 2)) 7000 11264 $K1 "$NODATE"
eq "$(levels)" "wa-worker=3" "pressure wants a lowering, but with the calendar date unreadable the counter cannot be read as 'today': nothing is written"
has "$(events skip)" "cannot compute the calendar date" "logged as a skip with its reason"
eng_quiet $((T0 + 3)) 7000 11264 $K1
eq "$(levels)" "" "date back: the same pressure now meets the breaker (1 write today) and the fragment is EMPTIED"
eq "$([ -e "$C/.gc/pool-ceiling-engine/tripped" ] && echo tripped || echo free)" "tripped" "and the engine is tripped for the day"
eng_quiet $((T0 + 4)) 4000 11264 $K1 "$NODATE"
eq "$([ -e "$C/.gc/pool-ceiling-engine/tripped" ] && echo tripped || echo free)" "tripped" "date unreadable: today's trip is not 'expired' (it would read as a different day)"
mk_city s15d
eng_quiet "$T0" 4000 11264 $K1; eng_quiet $((T0 + 1)) 4000 11264 $K1; : > "$C/.gc/pool-ceiling-engine.off"
eng_quiet $((T0 + 2)) 4000 11264 $K1 "$NODATE"
eq "$(levels)" "" "the kill switch does not wait for the calendar date: the fragment is emptied all the same"
mkdir -p "$TMPROOT/noclock"; printf '#!/bin/sh\ncase "$*" in "+%%s") exit 1 ;; esac\nexec /bin/date "$@"\n' > "$TMPROOT/noclock/date"; chmod +x "$TMPROOT/noclock/date"
mk_city s15e
eng_quiet "$T0" 4000 11264 $K1; eng_quiet $((T0 + 1)) 4000 11264 $K1
has "$(ENG_CMD=status eng $((T0 + 2)) 4000 11264 $K1)" "escritas hoje: 1/" "status: with the clock readable, today's writes are counted"
has "$(ENG_CMD=status eng x 4000 11264 $K1 "PATH=$TMPROOT/noclock:$PATH")" "escritas hoje: ?/" "status: with the clock unreadable, today's writes are '?', never a 0 dated 1970"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 16; then section "16. kill switch, disabled engine, include, and a fragment that is not what the engine wrote"
mk_city s16a
csw 2 "$T0"; : > "$C/.gc/pool-ceiling-engine.off"
eng_quiet $((T0 + 700)) 4000 11264
eq "$(levels)" "" "kill switch: every pool back to committed (entries gone)"
eq "$([ -e "$C/.gc/pool-ceiling-engine.toml" ] && echo exists || echo DELETED)" "exists" "the fragment is EMPTIED, never deleted (an absent included fragment breaks the config load)"
eq "$(resolved wa-worker)" "2" "and the config still loads, wa-worker back to 2"
has "$(cat "$TMPROOT/notify.log")" "kill switch" "emptying a non-empty fragment notifies"
eq "$(sed -n 's/^clear_streak=//p' "$C/.gc/pool-ceiling-engine/wa-worker.state")" "0" "the kill switch resets the per-pool streaks"
csw 3 $((T0 + 1000))
eq "$(levels)" "" ".off wins over .on, however many clear sweeps"
eq "$(events restore | grep -c 'reason=kill-switch')" "2" "kill switch: one 'emptied' line and one 'already empty' line, not one line per sweep"
rm -f "$C/.gc/pool-ceiling-engine.toml"; eng_quiet $((T0 + 2000)) 4000 11264
eq "$(ENG_CMD=check eng "$T0" 4000 11264)" "ok: include present, fragment present and well-formed" ".off with the fragment ABSENT re-creates it empty"
rm -f "$C/.gc/pool-ceiling-engine.off"
eng_quiet $((T0 + 3000)) 4000 11264
eq "$(levels)" "" "kill switch lifted: the first sweep only counts again"
eng_quiet $((T0 + 3300)) 4000 11264
eq "$(levels)" "wa-worker=3" "and the 2nd raises: the engine resumes from a clean slate"

mk_city s16b; rm -f "$C/.gc/pool-ceiling-engine.on"; before="$(tree_sig)"
csw 3 "$T0"
eq "$(tree_sig)" "$before" "no .on, no .off: nothing read, nothing written, no state, no log (silent and inert)"
rm -f "$C/.gc/pool-ceiling-engine.toml"
has "$(ENG_CMD=status eng "$T0" 4000 11264)" "AUSENTE" "status reports an absent fragment as ABSENT (not as 'unreadable or strange')"
mk_city s16c; rm -f "$C/.gc/pool-ceiling-engine.on" "$C/.gc/pool-ceiling-engine.toml"
eng_quiet "$T0" 4000 11264
eq "$(ENG_CMD=check eng "$T0" 4000 11264)" "ok: include present, fragment present and well-formed" "disabled + include present + fragment ABSENT: re-created EMPTY (the one state that breaks the next reload)"
has "$(cat "$TMPROOT/notify.log")" "ABSENT" "and says so"
eq "$([ -d "$C/.gc/pool-ceiling-engine" ] && echo state || echo none)" "none" "without creating any engine state"
mk_city s16d; rm -f "$C/.gc/pool-ceiling-engine.on" "$C/.gc/pool-ceiling-engine.toml"; sed -i '' '/^include/d' "$C/city.toml"
eng_quiet "$T0" 4000 11264
eq "$([ -e "$C/.gc/pool-ceiling-engine.toml" ] && echo created || echo untouched)" "untouched" "no include in city.toml: a missing fragment is not an error, nothing is created"
mk_city s16e; sed -i '' '/^include/d' "$C/city.toml"; cp "$C/.gc/pool-ceiling-engine.toml" "$TMPROOT/frag.before"
csw 4 "$T0"
eq "$(cmp -s "$C/.gc/pool-ceiling-engine.toml" "$TMPROOT/frag.before" && echo same || echo CHANGED)" "same" ".on but city.toml does not include the fragment: nothing would apply it, nothing is written"
eq "$(nevents write)" "0" "no write event"
has "$(logf)" "does not include" "the log says why"
mk_city s16i; chmod 000 "$C/city.toml"
csw 2 "$T0"
chmod 644 "$C/city.toml"
eq "$(levels)" "" "city.toml UNREADABLE: nothing written"
has "$(events skip)" "UNREADABLE" "and it is reported as unreadable, not as 'does not include the fragment'"

# The include is read from city.toml's PARSED include array and has THREE answers (1 / 0 / ?): the fragment's file name in a comment, a .bak, another
# directory or an unrelated string is NOT an include (the engine must not write a fragment nobody loads), and what cannot be parsed is "cannot tell",
# never "included" - the class the gate rejected in the prod-test of slice A (ga-m9x0lb.2.1, round 2).
incw() { # <name> <first line of city.toml; @C@ = the fixture city> [VAR=val ...] - .on, then 2 clear sweeps: a REAL include raises wa-worker to 3
  local nm="$1" line="$2"; shift 2; mk_city "$nm"; line="${line//@C@/$C}"
  { printf '%s\n' "$line"; sed '1d' "$C/city.toml"; } > "$TMPROOT/ct.new" && mv "$TMPROOT/ct.new" "$C/city.toml"
  csw 2 "$T0" "$@"
}
FRAG_NAME='.gc/pool-ceiling-engine.toml'
incw i1 "include = [\"$FRAG_NAME\"]  # a trailing comment on a REAL include"
eq "$(levels)" "wa-worker=3" "a real include with a trailing comment IS an include (positive control)"
incw i2 'include = [ "agents/x.toml", "./.gc/../.gc/pool-ceiling-engine.toml" ]'
eq "$(levels)" "wa-worker=3" "a real include whose path needs normalising IS an include"
incw i3 'include = ["@C@/.gc/pool-ceiling-engine.toml"]'
eq "$(levels)" "wa-worker=3" "a real include by absolute path IS an include"
for ic in 'i4|include = []  # was ".gc/pool-ceiling-engine.toml"|a trailing comment that names the file' \
          'i5|include = [".gc/pool-ceiling-engine.toml.bak"]|a .bak' \
          'i6|include = ["other/.gc/pool-ceiling-engine.toml"]|the same name in another directory' \
          'i7|description = "see .gc/pool-ceiling-engine.toml"|the name inside an unrelated string'; do
  IFS='|' read -r inm iline iwhy <<< "$ic"
  incw "$inm" "$iline"
  eq "$(levels)" "" "$iwhy is NOT an include: nothing written"
  has "$(events skip)" "does not include" "and the log says so ($inm)"
done
incw i8 'include = ".gc/pool-ceiling-engine.toml"'
eq "$(levels)" "" "include is a string, not an array (odd shape): cannot tell, NOT included - nothing written"
has "$(events skip)" "cannot tell whether city.toml's parsed include array" "logged as cannot-tell"
hasnt "$(events skip)" "does not include" "and never worded as 'does not include'"
incw i9 'include = [".gc/pool-ceiling-engine.toml"'
eq "$(levels)" "" "city.toml readable but NOT valid TOML: nothing written"
has "$(events skip)" "cannot tell" "logged as cannot-tell"
incw i10 "include = [\"$FRAG_NAME\"]" POOL_CEILING_ENGINE_PYTHON="$TMPROOT/bin/py-crash"
eq "$(levels)" "" "python3 cannot run the check (no tomllib / a crash): a REAL include is not acted on - nothing written"
incw i11 "include = [\"$FRAG_NAME\"]" POOL_CEILING_ENGINE_PYTHON="$TMPROOT/bin/py-junk"
eq "$(levels)" "" "python3 prints something that is neither 0 nor 1: cannot tell - nothing written"
incw i12 "include = [\"$FRAG_NAME\"]" POOL_CEILING_ENGINE_PYTHON="$TMPROOT/bin/py-late-crash"
eq "$(levels)" "" "python3 prints 1 and then crashes: the verdict of a crashed run is void - nothing written"

mk_city i13; rm -f "$C/.gc/pool-ceiling-engine.on" "$C/.gc/pool-ceiling-engine.toml"; { printf 'include = ".gc/pool-ceiling-engine.toml"\n'; sed '1d' "$C/city.toml"; } > "$TMPROOT/ct.new" && mv "$TMPROOT/ct.new" "$C/city.toml"
eng_quiet "$T0" 4000 11264
eq "$([ -e "$C/.gc/pool-ceiling-engine.toml" ] && echo created || echo untouched)" "created" "disabled + fragment ABSENT + include 'cannot tell': re-created (an empty file cannot hurt, an absent one may break the next reload)"
eq "$(pce_fragment_parse "$C/.gc/pool-ceiling-engine.toml" | wc -l | tr -d ' ')" "0" "and it is EMPTY"
has "$(events repair)" "include=?" "the repair log says the include was undecidable"
mk_city i14; chmod 000 "$C/city.toml"
out="$(ENG_CMD=check eng "$T0" 4000 11264)"; rc=$?; chmod 644 "$C/city.toml"
eq "$rc" "2" "check: city.toml UNREADABLE -> exit 2 (cannot verify), not 0"
has "$out" "UNKNOWN" "and it says UNKNOWN, not 'ok: does not include'"
incw i15 'include = []  # was ".gc/pool-ceiling-engine.toml"'
eq "$(ENG_CMD=check eng "$T0" 4000 11264)" "ok: city.toml does not include the fragment (nothing to check)" "check: a definite 'not included' is still ok"
has "$(ENG_CMD=status eng "$T0" 4000 11264)" "include no city.toml: NAO" "status: NAO for a definite 0"
incw i16 'include = ".gc/pool-ceiling-engine.toml"'
has "$(ENG_CMD=status eng "$T0" 4000 11264)" "include no city.toml: DESCONHECIDO" "status: DESCONHECIDO when it cannot tell (never NAO)"
hasnt "$(ENG_CMD=status eng "$T0" 4000 11264)" "syntax error" "status prints no shell syntax error under the plist's bash 3.2 (a case inside \$( ) inside a quoted string does not parse there)"
# .on + include 'cannot tell' + fragment ABSENT: the same repair as when disabled (the header and the doc promise it for include 1 OR ?)
mk_city i17; { printf 'include = ".gc/pool-ceiling-engine.toml"\n'; sed '1d' "$C/city.toml"; } > "$TMPROOT/ct.new" && mv "$TMPROOT/ct.new" "$C/city.toml"; rm -f "$C/.gc/pool-ceiling-engine.toml"
eng_quiet "$T0" 4000 11264
eq "$([ -e "$C/.gc/pool-ceiling-engine.toml" ] && echo created || echo ABSENT)" "created" "ENABLED + include 'cannot tell' + fragment ABSENT: re-created EMPTY (the state the safety net exists for), as when disabled"
out="$(pce_fragment_parse "$C/.gc/pool-ceiling-engine.toml")"; eq "$?/$out" "0/" "and it is a well-formed fragment with NO entries: no level was written on a guess"
has "$(events repair)" "include=?" "the repair log says the include was undecidable"
mk_city i18; sed -i '' '/^include/d' "$C/city.toml"; rm -f "$C/.gc/pool-ceiling-engine.toml"
eng_quiet "$T0" 4000 11264
eq "$([ -e "$C/.gc/pool-ceiling-engine.toml" ] && echo created || echo untouched)" "untouched" "ENABLED + a definite 'no include' + fragment absent: nothing is created (control)"

mk_city s16f
printf '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_session = 3\n' > "$C/.gc/pool-ceiling-engine.toml"
eng_quiet "$T0" 4000 11264
eq "$(levels)" "" "a fragment with a typo'd key (a hand edit or an old version) is FOREIGN: rewritten from the model"
eq "$(ENG_CMD=check eng "$T0" 4000 11264)" "ok: include present, fragment present and well-formed" "and well-formed afterwards"
has "$(events fragment-foreign)" "rewrite" "logged"
mk_city s16g
printf '[[patches.agent]]\ndir = ""\nname = "gastown.dog"\nmax_active_sessions = 4\n' > "$C/.gc/pool-ceiling-engine.toml"
eng_quiet "$T0" 4000 11264
eq "$(levels)" "" "an entry for a pool OUTSIDE the allowlist (gastown.dog belongs to eval-window-concurrency-guard) is dropped"
mk_city s16h; rm -f "$C/.gc/pool-ceiling-engine.toml"
eng_quiet "$T0" 4000 11264
eq "$(ENG_CMD=check eng "$T0" 4000 11264)" "ok: include present, fragment present and well-formed" ".on + include + fragment ABSENT: the sweep re-creates it"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 17; then section "17. one instance at a time: a live lock is respected silently; stale / dead / heartbeat-less locks are reclaimed"
mk_city s17; LD="$C/.gc/pool-ceiling-engine/lock.d"
mkdir -p "$LD"; echo "$$:live" > "$LD/heartbeat"
csw 2 "$T0"
eq "$(nevents sweep)" "0" "a LIVE holder: the run backs off silently (no sweep, no log)"
eq "$(levels)" "" "and changes nothing"
rm -f "$LD/heartbeat"; rmdir "$LD"
sleep 0 & dp=$!; wait "$dp" 2>/dev/null; mkdir -p "$LD"; echo "$dp:gone" > "$LD/heartbeat"
eng_quiet "$T0" 4000 11264
eq "$([ "$(nevents sweep)" -ge 1 ] && echo ran || echo BLOCKED)" "ran" "a DEAD holder (its pid is gone, heartbeat fresh): reclaimed, the run proceeds"
eq "$([ -d "$LD" ] && echo held || echo released)" "released" "and the lock is released afterwards"
rm -f "$C/.gc/logs/pool-ceiling-engine.log"
mkdir -p "$LD"; echo "$$:old" > "$LD/heartbeat"; touch -t 202001010000 "$LD/heartbeat"
eng_quiet $((T0 + 300)) 4000 11264
eq "$(events lock-reclaimed | grep -c 'holder_age_s')" "1" "a STALE heartbeat (older than the TTL, even with a live pid): reclaimed, and logged"
rm -f "$C/.gc/logs/pool-ceiling-engine.log"
mkdir -p "$LD"; touch -t 202001010000 "$LD"
eng_quiet $((T0 + 600)) 4000 11264
eq "$([ "$(nevents sweep)" -ge 1 ] && echo ran || echo BLOCKED)" "ran" "an old lock dir with NO heartbeat (crash between mkdir and the first write): reclaimed by the dir's own age, never stuck"
rm -f "$C/.gc/logs/pool-ceiling-engine.log"
mkdir -p "$LD"
eng_quiet $((T0 + 900)) 4000 11264
eq "$(nevents sweep)" "0" "a FRESH lock dir with no heartbeat yet is a holder mid-start: back off"
rm -f "$LD/heartbeat" 2>/dev/null; rmdir "$LD" 2>/dev/null
mkdir -p "$TMPROOT/nostat"; printf '#!/bin/sh\nexit 1\n' > "$TMPROOT/nostat/stat"; chmod +x "$TMPROOT/nostat/stat"
rm -f "$C/.gc/logs/pool-ceiling-engine.log"
mkdir -p "$LD"; echo "$$:old" > "$LD/heartbeat"; touch -t 202001010000 "$LD/heartbeat"
eng_quiet $((T0 + 1200)) 4000 11264 "PATH=$TMPROOT/nostat:$PATH"
eq "$(nevents sweep)" "0" "a heartbeat whose age CANNOT be read (no usable stat) is not 'ancient': the live holder is respected"
eq "$([ -d "$LD" ] && echo held || echo taken)" "held" "and its lock is left alone"
eq "$(events lock-age-unreadable | grep -c 'path=')" "1" "and the unreadable age is logged, never silent"
rm -f "$LD/heartbeat" 2>/dev/null; rmdir "$LD" 2>/dev/null
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 18; then section "18. plan (dry run) changes nothing, not even without .on"
mk_city s18
csw 2 "$T0"; before="$(tree_sig)"
out="$(ENG_CMD=plan eng $((T0 + 900)) 7000 11264)"
has "$out" "event=would-write" "plan prints what it WOULD write (pressure: lower)"
has "$out" "to=gate-reviewer=2" "and what"
has "$out" "why=levels-change" "and why"
eq "$(tree_sig)" "$before" "no file created, changed or removed (fragment, state, log, lock, counters)"
rm -f "$C/.gc/pool-ceiling-engine.on"; before="$(tree_sig)"
out="$(ENG_CMD=plan eng $((T0 + 900)) 4000 11264)"
has "$out" "event=sweep" "plan evaluates even when the engine is disabled (to preview the first sweeps)"
has "$out" "event=no-change" "and says so when nothing would change (instead of a bare silence)"
eq "$(tree_sig)" "$before" "and still writes nothing"
mk_city s18b; rm -f "$C/.gc/pool-ceiling-engine.toml"
out="$(ENG_CMD=plan eng "$T0" 4000 11264)"
has "$out" "why=fragment-absent" "plan says when the only thing it would do is create the missing fragment"
eq "$([ -e "$C/.gc/pool-ceiling-engine.toml" ] && echo created || echo untouched)" "untouched" "and does not create it"
fi

# ═════════════════════════════════════════════════════════════════════════════
if want 19; then section "19. the baseline is what is COMMITTED at HEAD, never the working tree; a pool whose committed value is unreadable or 0 is left alone"
mk_city s19a
printf 'max_active_sessions = 5\n' > "$C/agents/wa-worker/agent.toml"     # uncommitted experiment
csw 2 "$T0"
eq "$(levels)" "wa-worker=3" "working tree says 5, HEAD says 2: the engine still works from 2 (raises to 3)"
has "$(events sweep | grep 'pool=wa-worker' | tail -1)" "worktree_cap=5" "the divergence is visible in the log"
has "$(events sweep | grep 'pool=wa-worker' | tail -1)" "committed=2" "next to the committed value it used"
mk_city s19b
printf 'max_active_sessions = 0\n' > "$C/agents/ps-worker/agent.toml"; ( cd "$C" && git add agents && git -c user.email=t@t -c user.name=t commit -q -m pause ) >/dev/null 2>&1
csw 2 "$T0"
has "$(events skip)" "pool=ps-worker" "committed 0 (the operator's pause): that pool is skipped"
eq "$(levels)" "wa-worker=3" "and the others carry on"
mk_city s19c
csw 2 "$T0" "POOL_CEILING_ENGINE_POOLS=wa-worker ps-worker gate-reviewer no-such-pool"
has "$(events skip)" "pool=no-such-pool" "a pool with no agent.toml at HEAD is skipped, not guessed"
eq "$(levels)" "" "and while its ceiling is unknown nothing is RAISED (the budget cannot be checked: an unknown is not a zero)"
eng_quiet $((T0 + 700)) 7000 11264 "POOL_CEILING_ENGINE_POOLS=wa-worker ps-worker gate-reviewer no-such-pool"
eq "$(levels)" "gate-reviewer=2" "but the pressure lowering carries on for the pools that are known"
# A ceiling that cannot be read must not undo what the pressure already did (gate ga-9j2yjo): dropping a pool's entry hands it back to
# the committed value - a RAISE for a pool the engine had lowered, while the pressure that lowered it is still there. The entry that is
# there is HELD: neither raised nor lowered, because the engine does not know what it would be moving from or to.
mk_city s19d
eng_quiet "$T0" 7000 11264
eq "$(levels)" "gate-reviewer=2" "swap 7000 MB lowers gate-reviewer 3 -> 2 (the setup: a pool BELOW its committed value)"
printf '# no max_active_sessions line here\n' > "$C/agents/gate-reviewer/agent.toml"; cm unreadable
eng_quiet $((T0 + 700)) 7000 11264; eng_quiet $((T0 + 1400)) 7000 11264
eq "$(levels)" "gate-reviewer=2" "gate-reviewer's committed ceiling becomes UNREADABLE, pressure unchanged: its entry is HELD, not dropped (dropping it re-raises 2 -> 3)"
eq "$(resolved gate-reviewer)" "2" "and the controller still resolves 2: what gc loads is what the engine meant"
eq "$(nevents write)" "1" "no second write for a pool nobody can say anything new about (a drop would be a write, and one more of the day's 10)"
has "$(events skip | tail -1)" "pool=gate-reviewer" "the log still names the pool whose committed value could not be read"
has "$(events skip | tail -1)" "hold-entry" "and says its entry was HELD (not dropped)"
mk_city s19e   # the whole read fails at once (git cannot run for one sweep): every pool unreadable, nothing may move
eng_quiet "$T0" 7000 11264
for p in wa-worker ps-worker gate-reviewer; do printf '# no max_active_sessions line here\n' > "$C/agents/$p/agent.toml"; done; cm all-unreadable
eng_quiet $((T0 + 700)) 7000 11264; eng_quiet $((T0 + 1400)) 7000 11264
eq "$(levels)" "gate-reviewer=2" "every committed ceiling unreadable for the sweep: the fragment is NOT emptied under pressure"
eq "$(nevents write)" "1" "and no flapping: the three blind sweeps wrote nothing (a flaky git must not eat the daily breaker)"
mk_city s19f   # the over-correction guard: a KNOWN 0 is the operator's pause and wins - holding its old entry would un-pause the pool
eng_quiet "$T0" 7000 11264
printf 'max_active_sessions = 0\n' > "$C/agents/gate-reviewer/agent.toml"; cm pause
sed -i '' '/name = "gate-reviewer"/{n;s/max_active_sessions = 3/max_active_sessions = 0/;}' "$C/city.toml"   # the fake gc takes its base from city.toml: pause it there too
eng_quiet $((T0 + 700)) 7000 11264
eq "$(levels)" "" "gate-reviewer lowered to 2, then PAUSED (committed 0): its entry is dropped, the pause stands (an entry of 2 would override it)"
eq "$(resolved gate-reviewer)" "0" "and the controller resolves the pause"
fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$MUTANT_MODE" != "1" ] && want 20; then section "20. the fake gc is PROVEN against the real one, and the engine runs end to end on the real gc"
REALGC="$(command -v gc 2>/dev/null || true)"; usable=0
mk_city s20
if [ -n "$REALGC" ] && "$REALGC" config show --city "$C" --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; then usable=1; fi
if [ "$usable" != "1" ]; then
  echo "  - SKIPPED: no usable real gc on PATH — the fake gc is NOT proven in this run"
else
  view() { # <gc binary> -> "rc=0 <pool=max ...>" or "rc=err" (what the three pools resolve to)
    local out rc; out=$("$1" config show --city "$C" --json 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then echo "rc=err"; return 0; fi
    printf '%s' "$out" | jq -r '"rc=0 " + ([.config.Agents[] | select(.Name == "wa-worker" or .Name == "ps-worker" or .Name == "gate-reviewer") | "\(.Name)=\(.MaxActiveSessions)"] | sort | join(" "))'
  }
  parity() { printf '%b' "$2" > "$C/.gc/pool-ceiling-engine.toml"; local f r; f=$(view "$GCBIN"); r=$(view "$REALGC"); eq "$f" "$r" "parity: $1 (real gc: $r)"; }
  H='[[patches.agent]]\ndir = ""\n'
  parity "comment-only fragment" '# nothing\n'
  parity "0-byte fragment" ''
  parity "wa-worker = 3" "${H}name = \"wa-worker\"\nmax_active_sessions = 3\n"
  parity "three pools at once" "${H}name = \"wa-worker\"\nmax_active_sessions = 3\n\n${H}name = \"ps-worker\"\nmax_active_sessions = 2\n\n${H}name = \"gate-reviewer\"\nmax_active_sessions = 2\n"
  parity "a TYPO'D key: gc only warns, the ceiling does NOT move" "${H}name = \"wa-worker\"\nmax_active_session = 3\n"
  parity "an agent that does not exist (config load error)" "${H}name = \"no-such-agent\"\nmax_active_sessions = 3\n"
  parity "max_active_sessions = -1 (accepted by gc: UNLIMITED)" "${H}name = \"wa-worker\"\nmax_active_sessions = -1\n"
  parity "max_active_sessions = 0 (accepted by gc)" "${H}name = \"wa-worker\"\nmax_active_sessions = 0\n"
  parity "a quoted value (load error)" "${H}name = \"wa-worker\"\nmax_active_sessions = \"3\"\n"
  parity "a malformed header (load error)" '[[patches.agent\nname = "wa-worker"\n'
  rm -f "$C/.gc/pool-ceiling-engine.toml"
  eq "$(view "$GCBIN")" "$(view "$REALGC")" "parity: fragment ABSENT while city.toml includes it (load error: why the kill switch empties and never deletes)"
  mk_city s20b
  csw 2 "$T0" POOL_CEILING_ENGINE_GC="$REALGC"
  eq "$(levels)" "wa-worker=3" "real gc: 2 clear sweeps raise wa-worker (preflight and read-back both ran through the real binary)"
  has "$(events write)" "readback=ok" "and the read-back passed"
  eq "$(view "$REALGC")" "rc=0 gate-reviewer=3 ps-worker=1 wa-worker=3" "the REAL config now resolves wa-worker=3, the others as committed"
  : > "$C/.gc/pool-ceiling-engine.off"; eng_quiet $((T0 + 700)) 4000 11264 POOL_CEILING_ENGINE_GC="$REALGC"
  eq "$(view "$REALGC")" "rc=0 gate-reviewer=3 ps-worker=1 wa-worker=2" "kill switch on the real gc: the config still LOADS and wa-worker is back to 2"
fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# MUTANTS — the proof that each rule above is load-bearing. One rule broken per copy of the engine; the behavioural sections named
# for it (plus the pure sections 1-6, always run) are re-run against the copy and MUST fail. A mutant whose target text no longer
# matches exactly once is a failure too: it would mean the table drifted from the engine and proves nothing.
if [ "$MUTANT_MODE" != "1" ] && want 21; then section "21. wiring: what the engine and the files around it must agree on (the prod-test v2 reads what the engine WRITES; the launchd model runs THIS file)"
# The outside pieces are proved by their own selftests (slice A, ga-m9x0lb.2.1): the watcher's hash by config-drift-watcher-reload-policy.selftest.sh
# section I, the dedup set by crew-session-dedup.selftest.sh, the plist model and the prod-test v2 scenarios (with fragments written by hand) by
# pool-ceiling-wiring.selftest.sh. What only THIS file can prove is that they agree with the engine, so the prod-test below reads fragments the
# engine itself rendered and wrote.
CITYROOT="$(cd "$SELF_DIR/../../.." && pwd)"
PROD="$SELF_DIR/prod-tests/gascity/story-ga-o3o09z.sh"
PLIST_T="$SELF_DIR/pool-ceiling-engine.plist.template"

# (a) the launchd model runs this very file (the absolute path it names maps to a real file in this tree)
plist_script="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$PLIST_T" 2>/dev/null)"
eq "$([ -f "$CITYROOT/${plist_script#/Users/athos/gt/.gascity-gastown-hq/}" ] && echo present)" "present" "the plist's ProgramArguments script ($plist_script) maps to a real file in this tree"
eq "$(basename "$plist_script")" "$(basename "$SELF_DIR/pool-ceiling-engine.sh")" "and it is the engine, not another script"

# (b) the prod-test v2 (story-ga-o3o09z.sh) against the engine's own rendering
PP="$TMPROOT/pilot-prod.plist"
mkplist() { # <PILOT_WA_WORKER_MAX> <GC_VARIABLE_SESSION_MAX>
  rm -f "$PP"
  /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' -c "Add :EnvironmentVariables:PILOT_WA_WORKER_MAX string $1" -c "Add :EnvironmentVariables:GC_VARIABLE_SESSION_MAX string $2" "$PP" >/dev/null 2>&1
}
prod() { env -u POOL_CEILING_ENGINE_FRAGMENT CITY="$C" PILOT_PLIST="$PP" bash "$PROD" > "$TMPROOT/prod.out" 2>&1; echo $?; }
frag() { # <entries> -> writes the engine's own rendering into the fixture
  ( . "$ENGINE"; POOL_CEILING_ENGINE_CITY="$C" pce_init; pce_fragment_render "$1" ) > "$C/.gc/pool-ceiling-engine.toml"
}
mk_city p1; mkplist 2 9
eq "$(prod)" "0" "prod-test: the engine's EMPTY fragment (fixture default) + Pilot 2: passes"
mk_city p2; mkplist 3 9; frag "wa-worker=3"
eq "$(prod)" "0" "prod-test: a fragment rendered by the engine (header, blank lines and all) is accepted by its strict parser; Pilot 3 = effective 3"
has "$(cat "$TMPROOT/prod.out")" "effective engine ceiling = 3" "and it read the engine's entry, not agent.toml's 2"
mk_city p3; mkplist 4 9; frag "wa-worker=3"
eq "$(prod)" "1" "prod-test: Pilot 4 above the effective 3 FAILS"
mk_city p4; mkplist 3 9; frag "wa-worker=3 ps-worker=1 gate-reviewer=2"
eq "$(prod)" "0" "prod-test: all three pools in one rendered fragment (3+1+2 = 6 <= 9) pass"
mk_city p5; mkplist 3 6; frag "wa-worker=3"
eq "$(prod)" "1" "prod-test: 3+1+3 = 7 over GC_VARIABLE_SESSION_MAX 6 FAILS"
mk_city p6; mkplist 2 9; frag "gate-reviewer=4"
eq "$(prod)" "1" "prod-test: the renderer WILL emit gate-reviewer=4 (it only checks [1, hard max]); the prod-test refuses it, 'the others only go down'"

# (c) end to end: what `run` itself writes after 2 clear sweeps, and after the kill switch, is what the prod-test accepts
mk_city e1; mkplist 3 9
eng_quiet "$T0" 4000 11264; eng_quiet $((T0 + 300)) 4000 11264
eq "$(levels)" "wa-worker=3" "run: 2 clear sweeps wrote wa-worker=3"
eq "$(prod)" "0" "prod-test: the fragment the engine's own run wrote is accepted (Pilot 3 = effective 3)"
mkplist 4 9
eq "$(prod)" "1" "prod-test: and a Pilot at 4 is still refused against it"
: > "$C/.gc/pool-ceiling-engine.off"; eng_quiet $((T0 + 900)) 4000 11264; mkplist 2 9
eq "$(levels)" "" "kill switch: the engine emptied the fragment"
eq "$(prod)" "0" "prod-test: an EMPTIED fragment (not an absent one) passes with the Pilot back at agent.toml's 2"
fi

if [ "$MUTANT_MODE" != "1" ] && [ "${PCE_ST_NO_MUTANTS:-0}" != "1" ] && want 22; then section "22. mutants: break one rule at a time, the suite must go red"
cat > "$TMPROOT/mutate.py" <<'PYEOF'
import sys, os
src, outdir = sys.argv[1], sys.argv[2]
text = open(src).read()
M = [
 # (name, sections that must catch it, old text (exactly once), new text)
 ("raise-without-2-sweeps", "7", 'PCE_CLEAR_SWEEPS=$(_pce_knob POOL_CEILING_ENGINE_CLEAR_SWEEPS 2 1)', 'PCE_CLEAR_SWEEPS=1'),
 ("sweep-gap-ignored", "7", 'counted=0; if [ "$lsw" -eq 0 ] || [ $((PCE_NOW - lsw)) -ge "$PCE_SWEEP_GAP_SECS" ]; then counted=1; fi', 'counted=1'),
 ("raise-with-swap-over-6gb", "8", 'if [ "$s_ok" = "1" ] && [ "$s" -gt "$PCE_SWAP_HIGH_MB" ]; then echo high; return 0; fi', ':'),
 ("raise-with-disk-under-6gb", "8", 'if [ "$d_ok" = "1" ] && [ "$d" -lt "$PCE_DISK_LOW_MB" ]; then echo high; return 0; fi', ':'),
 ("unreadable-reads-as-clear", "10", 'if [ "$s_ok" = "0" ] || [ "$d_ok" = "0" ]; then echo unknown; return 0; fi', 'if [ "$s_ok" = "0" ] || [ "$d_ok" = "0" ]; then echo clear; return 0; fi'),
 ("hysteresis-band-reads-as-clear", "10", 'if [ "$d" -ge "$PCE_DISK_CLEAR_MB" ]; then echo clear; return 0; fi', 'if [ "$d" -ge "$PCE_DISK_LOW_MB" ]; then echo clear; return 0; fi'),
 ("blind-too-long-never-restores", "10", 'if [ "$L" -gt "$C" ] && [ "$us" -ge "$PCE_UNKNOWN_RESTORE" ]; then echo "$C|restore', 'if false; then echo "$C|restore'),
 ("lowering-obeys-the-rate-limit", "9", 'if [ "$L" -gt "$floor" ]; then echo "$((L - 1))|lower:pressure"', 'if [ "$L" -gt "$floor" ] && [ "$rate_ok" = "1" ]; then echo "$((L - 1))|lower:pressure"'),
 ("no-rate-limit-on-raise", "9", 'rate_ok=0; if [ "$lw" -eq 0 ] || [ $((PCE_NOW - lw)) -ge "$PCE_RATE_SECS" ]; then rate_ok=1; fi', 'rate_ok=1'),
 ("other-pools-go-above-committed", "11", '*:ceil) echo "$3" ;;', '*:ceil) echo "$(( $3 + 1 ))" ;;'),
 ("budget-ignored", "12", '[ "$sum" -gt "$budget" ] ||', '[ "$sum" -gt 9999 ] ||'),
 ("budget-takes-the-larger-source", "12", 'if [ "$a" -le "$b" ]; then echo "$a"; else echo "$b"; fi', 'if [ "$a" -ge "$b" ]; then echo "$a"; else echo "$b"; fi'),
 ("no-readback", "14", 'rb=$(pce_readback "$dev"); rbrc=$?', 'rb=""; rbrc=0'),
 ("readback-compares-nothing", "14", 'if [ "$got" != "$want" ]; then mism=1;', 'if false; then mism=1;'),
 ("no-preflight", "14", 'pf=$(pce_preflight "$dev"); pfrc=$?', 'pf=""; pfrc=0'),
 ("trip-ignored", "14 15", 'if [ -e "$PCE_STATE/tripped" ]; then', 'if [ -e "$PCE_STATE/tripped-never" ]; then'),
 ("no-daily-breaker", "15", '"$(pce_daily_writes)" -ge "$PCE_DAILY_MAX"', '"$(pce_daily_writes)" -ge 99999'),
 ("unreadable-date-reads-as-a-new-day", "15", '[ -n "$(_pce_date_of "$PCE_NOW")" ] || { pce_log_change "date-unreadable"', 'true || { pce_log_change "date-unreadable"'),
 ("kill-switch-deletes-the-fragment", "16", 'if pce_write_fragment "$empty"; then', 'if rm -f "$PCE_FRAGMENT"; then'),
 ("writes-without-the-include", "16", 'if [ "$include" != "1" ] && [ "$PCE_DRY" != "1" ]; then', 'if false; then'),
 ("cannot-tell-reads-as-included", "16", 'if [ "$include" != "1" ] && [ "$PCE_DRY" != "1" ]; then', 'if [ "$include" = "0" ] && [ "$PCE_DRY" != "1" ]; then'),
 ("cannot-tell-reads-as-not-included", "16", 'case "$v" in 0|1) echo "$v" ;; *) echo \'?\' ;; esac', 'case "$v" in 1) echo 1 ;; *) echo 0 ;; esac'),
 ("unknown-include-not-repaired", "16", '[ "$st" != "0" ] || return 0', '[ "$st" = "1" ] || return 0'),
 ("parse-accepts-level-0-and-03", "6", '/^max_active_sessions[[:space:]]*=[[:space:]]*[1-9][0-9]*[[:space:]]*$/ {', '/^max_active_sessions[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ {'),
 ("int-accepts-leading-zero", "6", "''|*[!0-9]*|0?*) return 1 ;; esac; return 0; }", "''|*[!0-9]*) return 1 ;; esac; return 0; }"),
 ("missing-fragment-not-repaired", "16", '[ -e "$PCE_FRAGMENT" ] && return 0', 'return 0'),
 ("trip-restores-on-every-sweep", "14", 'pce_fragment_is_empty || pce_restore "tripped:$tr" >/dev/null', 'pce_restore "tripped:$tr" >/dev/null'),
 ("kill-switch-clears-dedup-every-sweep", "16", 'if pce_restore "kill-switch"; then', 'if pce_restore "kill-switch"; then pce_clear_condition'),
 ("corrupt-daily-counter-reads-as-zero", "15", 'if [ -z "$d" ] || ! _pce_int "$w"; then printf \'%s\' "$PCE_DAILY_MAX"; return 0; fi', 'if [ -z "$d" ] || ! _pce_int "$w"; then printf \'0\'; return 0; fi'),
 ("corrupt-state-reads-as-never-written", "10", 'cs=0; us=0; lw="$PCE_NOW"', ':'),
 ("state-write-failure-is-silent", "10", ' || pce_log "event=state-write-failed" "what=$1.state" "effect=the streaks and the rate limit of $1 restart as if its file were absent"', ''),
 ("trip-write-failure-is-silent", "10", ' || pce_log "event=state-write-failed" "what=trip" "effect=the trip may not hold; the callers empty the fragment regardless"', ''),
 ("no-lock", "17", 'pce_lock_acquire || return 0', 'pce_lock_acquire || true'),
 ("heartbeat-less-lock-never-reclaimed", "17", 'else age=$(_pce_lock_age "$PCE_LOCK_DIR"); fi', 'else age=0; fi'),
 ("lock-age-unreadable-reads-as-ancient", "17", 'the lock is respected"; echo 0; return 0; }', 'the lock is respected"; echo 999999999; return 0; }'),
 ("status-clock-unreadable-reads-as-epoch-zero", "15", 'PCE_NOW=$(_pce_now); PCE_NOW="${PCE_NOW:-?}"', 'PCE_NOW=$(_pce_now); PCE_NOW="${PCE_NOW:-0}"'),
 ("status-writes-today-without-a-date", "15", '[ -n "$(_pce_date_of "$PCE_NOW")" ] && pce_daily_writes || echo', 'true && pce_daily_writes || echo'),
 ("dry-run-writes", "18", '  if [ "$PCE_DRY" = "1" ]; then\n    local why="levels-change"', '  if false; then\n    local why="levels-change"'),
 ("baseline-from-the-working-tree", "19", 'txt=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$PCE_CITY" show "HEAD:./agents/$pool/agent.toml" 2>/dev/null) || return 0', 'txt=$(cat "$PCE_CITY/agents/$pool/agent.toml" 2>/dev/null) || return 0'),
 ("render-accepts-any-pool", "5", '    case " $PCE_POOLS " in *" $p "*) ;; *) return 1 ;; esac', '    :'),
 ("render-accepts-zero", "5", '_pce_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le "$PCE_HARD_MAX" ] || return 1', '_pce_int "$v" && [ "$v" -le "$PCE_HARD_MAX" ] || return 1'),
 # the defects of gate round ga-a7bsxr, and the class around each
 ("status-parses-only-under-bash-5", "16", 'include no city.toml: $(_pce_include_word)"', 'include no city.toml: $(case "$(pce_include_state)" in 1) echo sim ;; 0) echo NAO ;; *) echo DESCONHECIDO ;; esac)"'),
 ("unknown-ceiling-reads-as-zero", "12", 'skipped="$skipped $pool"', ':'),
 ("paused-pool-reads-as-unknown", "12", 'if [ "$C" = "0" ]; then pce_log "event=skip"', 'if [ "$C" = "0" ]; then skipped="$skipped $pool"; pce_log "event=skip"'),
 ("reset-claims-success-unchecked", "14", 'rm -f "$PCE_STATE/$f" 2>/dev/null && [ ! -e "$PCE_STATE/$f" ] || left="$left $f"', 'rm -f "$PCE_STATE/$f" 2>/dev/null'),
 ("reset-exits-0-on-failure", "14", 'reset) pce_reset; exit $? ;;', 'reset) pce_reset; exit 0 ;;'),
 ("trip-with-unreadable-date-expires", "14", '[[ "$td" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && ', ''),
 ("clear-streak-survives-any-gap", "7", 'if [ "$lsw" -ne 0 ] && [ $((PCE_NOW - lsw)) -gt "$PCE_STREAK_EXPIRE_SECS" ]; then cs=0; fi', ':'),
 ("enabled-unknown-include-not-repaired", "16", 'pce_repair_missing_fragment   # a definite 0', ':   # a definite 0'),
 ("preflight-notifies-every-sweep", "14", '&& [ "$pfrc" -eq 1 ] && pce_notify', '; [ "$pfrc" -eq 1 ] && pce_notify'),
 ("write-failed-notifies-every-sweep", "14", '&& pce_notify "pool-ceiling-engine: could not write', '; pce_notify "pool-ceiling-engine: could not write'),
 ("daily-counter-write-failure-is-silent", "10", ' || pce_log "event=state-write-failed" "what=daily-counter" "effect=the breaker may undercount today\'s writes"', ''),
 # the defect of gate round ga-9j2yjo: an unreadable committed ceiling DROPPED the pool's entry, re-raising a pool the pressure had lowered
 ("unreadable-ceiling-entry-not-remembered", "19", '_pce_int "$L" && held=$(_pce_map_set "$held" "$pool" "$L")', ':'),
 ("held-entry-not-rendered", "19", '_pce_int "$new" && dev=$(_pce_map_set "$dev" "$pool" "$new"); continue; }', 'continue; }'),
 ("paused-pool-entry-is-held", "19", 'if [ "$C" = "0" ]; then pce_log "event=skip"', 'if [ "$C" = "0" ]; then held=$(_pce_map_set "$held" "$pool" "$(_pce_map_get "$cur_map" "$pool")"); pce_log "event=skip"'),
]
names = []
for name, secs, old, new in M:
    if text.count(old) != 1:
        print("BAD %s: target matches %d times" % (name, text.count(old))); sys.exit(3)
    mut = text.replace(old, new)
    if mut == text:
        print("BAD %s: mutation changes nothing" % name); sys.exit(3)
    open(os.path.join(outdir, name + ".sh"), "w").write(mut)
    names.append("%s|%s" % (name, secs))
open(os.path.join(outdir, "index"), "w").write("\n".join(names) + "\n")
PYEOF
MD="$TMPROOT/mutants"; mkdir -p "$MD"
if ! python3 -I "$TMPROOT/mutate.py" "$ENGINE" "$MD" > "$MD/mutate.out" 2>&1; then
  bad "the mutant table does not apply to this engine: $(cat "$MD/mutate.out")"
else
  n=0; jobs="${PCE_ST_JOBS:-2}"; started=0
  while IFS='|' read -r mname msecs; do
    [ -n "$mname" ] || continue
    [ -z "${PCE_ST_MUTANT_FILTER:-}" ] || case " $PCE_ST_MUTANT_FILTER " in *" $mname "*) ;; *) continue ;; esac
    ( PCE_ST_MUTANT=1 PCE_ST_ONLY="$msecs" POOL_CEILING_ENGINE_PATH="$MD/$mname.sh" bash "$SELF" > "$MD/$mname.out" 2>&1; echo $? > "$MD/$mname.rc" ) &
    started=$((started + 1)); [ $((started % jobs)) -eq 0 ] && wait
  done < "$MD/index"
  wait
  while IFS='|' read -r mname msecs; do
    [ -n "$mname" ] || continue
    [ -z "${PCE_ST_MUTANT_FILTER:-}" ] || case " $PCE_ST_MUTANT_FILTER " in *" $mname "*) ;; *) continue ;; esac
    mrc="$(cat "$MD/$mname.rc" 2>/dev/null || echo missing)"
    if [ "$mrc" = "1" ]; then ok "mutant KILLED: $mname — caught by: $(grep -m1 '✗' "$MD/$mname.out" | cut -c1-110)"
    else bad "mutant SURVIVED (rc=$mrc): $mname — no section noticed the rule being broken"; fi
  done < "$MD/index"
fi
fi

# ═════════════════════════════════════════════════════════════════════════════
if [ "$MUTANT_MODE" != "1" ] && [ -z "${PCE_ST_ONLY:-}" ]; then section "23. hermetic: nothing under the REAL city's engine paths changed during this run"
eq "$(prod_snapshot)" "$PROD_BEFORE" "the real city's fragment / .off / log / state are exactly as they were before the run"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  [ "$MUTANT_MODE" = "1" ] || echo "PASS: $PASS checks"
  exit 0
fi
echo "FAIL: $FAIL of $((PASS + FAIL)) checks"
exit 1
