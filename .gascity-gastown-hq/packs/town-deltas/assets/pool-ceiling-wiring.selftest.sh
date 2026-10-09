#!/usr/bin/env bash
# pool-ceiling-wiring.selftest.sh (ga-m9x0lb.2.1)
#
# Proves the pieces the pool-ceiling ENGINE relies on OUTSIDE itself (ga-m9x0lb.2, slice A). None of them needs the engine to exist:
#   - the launchd job TEMPLATE pool-ceiling-engine.plist (valid, every 5 min, no run at load, runs `run`, a model only);
#   - the prod-test v2 (prod-tests/gascity/story-ga-o3o09z.sh): the Pilot's ceiling is bounded by the EFFECTIVE ceiling
#     (agent.toml, or the generated fragment's entry), the fragment is validated strictly, the sum fits GC_VARIABLE_SESSION_MAX.
# The watcher's hash and the dedup set are proved by their own selftests (config-drift-watcher-reload-policy.selftest.sh section I,
# crew-session-dedup.selftest.sh). The fragments below are WRITTEN BY HAND in the shape the engine renders ([[patches.agent]] /
# dir = "" / name / max_active_sessions); pool-ceiling-engine.selftest.sh (slice B) runs the same prod-test against the engine's
# own rendering, so the two shapes cannot drift apart unnoticed.
#
# Hermetic: every scenario runs against a throwaway city under a temp dir; nothing under the real city is read or written.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD="$SELF_DIR/prod-tests/gascity/story-ga-o3o09z.sh"
PLIST_T="$SELF_DIR/pool-ceiling-engine.plist"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
eq()  { if [ "$1" = "$2" ]; then ok "$3 (got: $1)"; else bad "$3 (expected: $2, got: $1)"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2' in: $1)" ;; esac; }
section() { echo; echo "── $* ──"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ── 1. the launchd job template ───────────────────────────────────────────────
section "1. pool-ceiling-engine.plist: a valid TEMPLATE for a 5-minute job that does not run at load"
plutil -lint "$PLIST_T" >/dev/null 2>&1; eq "$?" "0" "it is a valid plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST_T" 2>/dev/null; }
eq "$(pb Label)" "com.gascity.pool-ceiling-engine" "its own label (not the Pilot's, not the gate's)"
eq "$(pb StartInterval)" "300" "runs every 5 minutes (StartInterval)"
eq "$(pb RunAtLoad)" "false" "RunAtLoad false: a bootstrap or relog is not a sweep"
eq "$(pb ProgramArguments:2)" "run" "with the 'run' subcommand"
eq "$(pb ProgramArguments:1 | sed 's|.*/packs/||')" "town-deltas/assets/pool-ceiling-engine.sh" "and the script it names is pool-ceiling-engine.sh in this pack"
pb EnvironmentVariables:GC_VARIABLE_SESSION_MAX >/dev/null; eq "$?" "1" "GC_VARIABLE_SESSION_MAX is NOT set here: the engine reads the Pilot's plist, one source of truth"
has "$(sed -n '/<!--/,/-->/p' "$PLIST_T")" "NOT INSTALLED" "the file says out loud that it is a template, not an installed job"

# ── 2. the prod-test v2 ───────────────────────────────────────────────────────
section "2. story-ga-o3o09z.sh v2: the Pilot ceiling is bounded by the EFFECTIVE ceiling, never by a literal 2"
C=""; PP="$TMPROOT/pilot-prod.plist"
skip() { SKIP=$((SKIP+1)); echo "  - SKIPPED: $*"; }
mk_city() { # <name> — wa-worker 2, ps-worker 1, gate-reviewer 3 (+ mila-wa 1, a pool OUTSIDE the engine) in agent.toml; city.toml includes the fragment; fragment empty
  C="$TMPROOT/$1/city"; mkdir -p "$C/.gc" "$C/agents/wa-worker" "$C/agents/ps-worker" "$C/agents/gate-reviewer" "$C/agents/mila-wa"
  printf 'min_active_sessions = 0\nmax_active_sessions = 1\n' > "$C/agents/mila-wa/agent.toml"
  printf 'min_active_sessions = 0\nmax_active_sessions = 2\n' > "$C/agents/wa-worker/agent.toml"
  printf 'min_active_sessions = 0\nmax_active_sessions = 1\n' > "$C/agents/ps-worker/agent.toml"
  printf 'max_active_sessions = 3 # gate\nmin_active_sessions = 0\n' > "$C/agents/gate-reviewer/agent.toml"
  printf 'include = [".gc/pool-ceiling-engine.toml"]\n\n[workspace]\nname = "selftest"\n' > "$C/city.toml"
  printf '# empty\n' > "$C/.gc/pool-ceiling-engine.toml"
}
mkplist() { # <PILOT_WA_WORKER_MAX> <GC_VARIABLE_SESSION_MAX>
  rm -f "$PP"
  /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' -c "Add :EnvironmentVariables:PILOT_WA_WORKER_MAX string $1" -c "Add :EnvironmentVariables:GC_VARIABLE_SESSION_MAX string $2" "$PP" >/dev/null 2>&1
}
frag() { # <"pool=level ..."> — a fragment in the shape the engine renders
  local e; { printf '# GENERATED\n'; for e in $1; do printf '\n[[patches.agent]]\ndir = ""\nname = "%s"\nmax_active_sessions = %s\n' "${e%%=*}" "${e#*=}"; done; } > "$C/.gc/pool-ceiling-engine.toml"
}
prod() { env -u POOL_CEILING_ENGINE_FRAGMENT CITY="$C" PILOT_PLIST="$PP" bash "$PROD" > "$TMPROOT/prod.out" 2>&1; echo $?; }

mk_city p1; mkplist 2 9
eq "$(prod)" "0" "baseline (empty fragment, Pilot 2, agent.toml 2, sum 2+1+3 = 6 <= 9) passes"
has "$(cat "$TMPROOT/prod.out")" "effective engine ceiling = 2" "and says what it checked"
mk_city p2; mkplist 3 9; frag "wa-worker=3"
eq "$(prod)" "0" "fragment raises wa-worker to 3, Pilot 3: passes (the Pilot may match the EFFECTIVE ceiling; v1 failed it)"
mk_city p3; mkplist 4 9; frag "wa-worker=3"
eq "$(prod)" "1" "Pilot 4 above the effective 3: FAILS"
has "$(cat "$TMPROOT/prod.out")" "effective engine ceiling 3" "naming the effective ceiling"
mk_city p4; mkplist 3 9
eq "$(prod)" "1" "empty fragment, Pilot 3 above agent.toml's 2: still FAILS (the original invariant is kept)"
mk_city p5; mkplist 3 6; frag "wa-worker=3"
eq "$(prod)" "1" "sum 3+1+3 = 7 over GC_VARIABLE_SESSION_MAX 6: FAILS"
has "$(cat "$TMPROOT/prod.out")" "GC_VARIABLE_SESSION_MAX=6" "naming the budget"
mk_city p6; mkplist 2 9; rm -f "$C/.gc/pool-ceiling-engine.toml"
eq "$(prod)" "1" "city.toml includes the fragment but it is ABSENT (a config load error): FAILS"
has "$(cat "$TMPROOT/prod.out")" "ABSENT" "and says why"
mk_city p7; mkplist 2 9; printf '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_session = 3\n' > "$C/.gc/pool-ceiling-engine.toml"
eq "$(prod)" "1" "a fragment that is not what the engine renders (typo'd key): FAILS (the effective ceiling is unknowable)"
has "$(cat "$TMPROOT/prod.out")" "FOREIGN content" "because it is FOREIGN, not for some other reason"
mk_city p8; mkplist 2 9; frag "gate-reviewer=4"
eq "$(prod)" "1" "gate-reviewer ABOVE its agent.toml (3): FAILS ('the others only go down')"
has "$(cat "$TMPROOT/prod.out")" "ABOVE agent.toml's 3" "because it is above the committed value"
mk_city p9; mkplist 2 9; frag "mila-wa=1"
eq "$(prod)" "1" "an entry for mila-wa (it HAS an agent.toml, 1; level within it, outside the allowlist): FAILS"
has "$(cat "$TMPROOT/prod.out")" "outside the engine's allowlist" "because of the allowlist: the agent.toml compare would have let it through"
mk_city p9b; mkplist 2 9; frag "gastown.dog=4"
eq "$(prod)" "1" "an entry for gastown.dog (outside the allowlist, no agent.toml here): FAILS"
has "$(cat "$TMPROOT/prod.out")" "outside the engine's allowlist" "and says the allowlist, not 'no readable agent.toml'"
mk_city p10; mkplist 2 9; frag "gate-reviewer=2"
eq "$(prod)" "0" "gate-reviewer lowered to 2 is fine"
mk_city p11; mkplist 2 9; rm -f "$C/.gc/pool-ceiling-engine.toml"; printf 'include = []\n\n[workspace]\nname = "selftest"\n' > "$C/city.toml"
eq "$(prod)" "0" "engine not installed (no include, no fragment): passes on agent.toml alone"
mk_city p12; mkplist 2 9; printf '\n[[patches.agent]]\nname = "wa-worker"\nmax_active_sessions = 3\n' >> "$C/city.toml"
if python3 -c 'import tomllib' 2>/dev/null; then   # the prod-test soft-skips this rule without tomllib (python >= 3.11): say so, don't pretend
  eq "$(prod)" "1" "a [[patches.agent]] of its own in city.toml setting wa-worker's ceiling: FAILS (the fragment is the only other source)"
else
  skip "the city.toml [[patches.agent]] rule needs python3 >= 3.11 (tomllib); $(command -v python3 || echo 'no python3') cannot run it"
fi
mk_city p13; mkplist 2 9; rm -f "$C/.gc/pool-ceiling-engine.toml"; chmod 000 "$C/city.toml"
if [ -r "$C/city.toml" ]; then   # running as root: mode 000 does not hide the file, so the scenario cannot be built
  skip "city.toml stays readable here (uid $(id -u)), cannot stage an unreadable one"
else
  eq "$(prod)" "1" "city.toml UNREADABLE (not 'no include'): FAILS, it must not read as 'engine not installed'"
  has "$(cat "$TMPROOT/prod.out")" "unreadable" "and says why"
fi
chmod 644 "$C/city.toml"
mk_city p14; mkplist 3 9; frag "wa-worker=3"; printf 'include = []\n\n[workspace]\nname = "selftest"\n' > "$C/city.toml"
eq "$(prod)" "1" "a POPULATED fragment that city.toml does not include (partial rollback; Pilot 3 vs the controller's real 2): FAILS"
has "$(cat "$TMPROOT/prod.out")" "does not include it" "saying the controller applies none of it"
mk_city p14b; mkplist 2 9; printf 'include = []\n\n[workspace]\nname = "selftest"\n' > "$C/city.toml"
eq "$(prod)" "0" "an EMPTY fragment that city.toml does not include yet (slice 3 step 1 creates it first): passes"
mk_city p14c; mkplist 2 9; { printf '# the include is only mentioned: pool-ceiling-engine.toml\n'; printf 'include = []\n\n[workspace]\nname = "selftest"\n'; } > "$C/city.toml"; frag "wa-worker=3"
eq "$(prod)" "1" "a COMMENT that names the fragment is not an include: FAILS the same way"
mk_city p15; mkplist 2 9; frag "wa-worker=9"
eq "$(prod)" "1" "wa-worker=9 (above the engine's hard max 8): FAILS"
has "$(cat "$TMPROOT/prod.out")" "outside [1, 8]" "on the bound"
mk_city p16; mkplist 2 9; frag "wa-worker=0"
eq "$(prod)" "1" "wa-worker=0 (a pause is the operator's, never the engine's): FAILS"
has "$(cat "$TMPROOT/prod.out")" "outside [1, 8]" "on the bound"
mk_city p17; mkplist 2 9; frag "wa-worker=3 wa-worker=3"
eq "$(prod)" "1" "the same pool twice: FAILS (which entry wins is unknowable)"
has "$(cat "$TMPROOT/prod.out")" "FOREIGN content" "as foreign"
mk_city p18; mkplist 2 9; printf '[[patches.agent]]\nname = "wa-worker"\nmax_active_sessions = 3\n' > "$C/.gc/pool-ceiling-engine.toml"
eq "$(prod)" "1" "an entry without dir = \"\" (not what the engine renders): FAILS"
has "$(cat "$TMPROOT/prod.out")" "FOREIGN content" "as foreign"
mk_city p19; mkplist 2 9; printf '\n[[patches.agent]]\nname = "ps-worker"\nmax_active_sessions = 4\n' >> "$C/city.toml"
if python3 -c 'import tomllib' 2>/dev/null; then
  eq "$(prod)" "1" "a [[patches.agent]] in city.toml setting ps-worker's ceiling: FAILS too (not only wa-worker)"
else
  skip "the ps-worker city.toml rule needs python3 >= 3.11 (tomllib)"
fi
mk_city p20; mkplist 2 9; rm -f "$C/agents/ps-worker/agent.toml"
eq "$(prod)" "1" "ps-worker's agent.toml unreadable: the sum cannot be checked, FAILS (unknown is not 'fits')"
has "$(cat "$TMPROOT/prod.out")" "ps-worker unreadable" "naming the pool"
mk_city p21; rm -f "$PP"
eq "$(prod)" "0" "no Pilot plist on this host: passes, and the PASS line SAYS what it did not check"
has "$(cat "$TMPROOT/prod.out")" "NOT CHECKED" "in the verdict line itself"
mk_city p22; mkplist 2 9; printf '[[patches.agent]]\ndir = ""\nname = "wa-worker"\nmax_active_sessions = 3\nenabled = false\n' > "$C/.gc/pool-ceiling-engine.toml"
eq "$(prod)" "1" "an otherwise COMPLETE entry plus a line the engine never renders (enabled = false): FAILS"
has "$(cat "$TMPROOT/prod.out")" "FOREIGN content" "as foreign (a catch-all, not a missing-key side effect)"
mk_city p23; mkplist 2 9; rm -f "$C/.gc/pool-ceiling-engine.toml"; mkdir -p "$TMPROOT/fakebin"
printf '#!/bin/sh\ncase "$*" in *city.toml*) exit 2 ;; esac\nexec /usr/bin/grep "$@"\n' > "$TMPROOT/fakebin/grep"; chmod +x "$TMPROOT/fakebin/grep"
prod_rc=$(PATH="$TMPROOT/fakebin:$PATH" prod)
eq "$prod_rc" "1" "grep fails reading city.toml (not 'no match'): FAILS, the include is unknowable (ABSENT fragment would have passed)"
has "$(cat "$TMPROOT/prod.out")" "cannot read" "and says it could not read"

echo
SKIPNOTE=""; [ "$SKIP" -gt 0 ] && SKIPNOTE=" ($SKIP scenario(s) SKIPPED, see above)"
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS checks$SKIPNOTE"; exit 0; fi
echo "FAIL: $FAIL of $((PASS + FAIL)) checks$SKIPNOTE"
exit 1
