#!/usr/bin/env bash
# prod-tests/gascity/story-ga-o3o09z.sh — prod test for ga-o3o09z:
# "Teto do WA em 2 lugares" — agents/wa-worker/agent.toml is the COMMITTED source of truth for the controller's wa-worker
# pool ceiling, and the Pilot's own plist ceiling (a separate, redundant safety net) never disagrees with the ceiling the
# controller ACTUALLY applies.
#
# v2 (ga-m9x0lb.2, approved by the Mayor 09/10): "the ceiling the controller actually applies" is no longer agent.toml alone.
# The pool-ceiling engine writes ONE generated fragment (.gc/pool-ceiling-engine.toml, included by city.toml) whose
# [[patches.agent]] entries override agent.toml. So the EFFECTIVE engine ceiling = the fragment's entry for the pool if there
# is one, else agent.toml. The rules, all checked here:
#   1. agent.toml carries an integer max_active_sessions >= 1 (the value is read, not hard-coded: the literal 2 was a
#      photograph of 25/09, not the invariant);
#   2. city.toml has NO [[patches.agent]] of its own setting wa-worker's max_active_sessions (the fragment is the only other
#      sanctioned source — a second one would make "single source of truth" a lie);
#   3. if city.toml includes the fragment the file EXISTS (an absent included fragment is a config LOAD ERROR) and is exactly
#      what the engine writes: allowlisted pools only, integers in [1, 8], and ps-worker / gate-reviewer never ABOVE agent.toml
#      (only wa-worker may be raised: "the others only go down"). "Includes" is read from the PARSED `include` array (entries
#      resolved to real paths), never matched as text; a fragment with entries that city.toml does not include is a FAIL (the
#      controller applies none of it), and so is one whose include cannot be told (needs python3 >= 3.11: unknown is not "in force");
#   4. PILOT_WA_WORKER_MAX in the Pilot's plist is never HIGHER than the effective wa-worker ceiling;
#   5. the sum of the effective ceilings of the three variable pools (wa-worker + ps-worker + gate-reviewer) stays within
#      GC_VARIABLE_SESSION_MAX (read from the Pilot's plist).
#
# Why not just agent.toml: before ga-o3o09z the controller ignored the Pilot's PILOT_WA_WORKER_MAX entirely (it only gates what
# the Pilot itself dispatches), so the two ceilings could silently diverge (measured 25/09: agent.toml=4, plist=2, 4 wa-workers
# actually active). Checking only the file would pass even if the plist drifted out of sync, or if a fragment raised the pool
# past what the dispatcher believes.
#
# Called by run.sh after deploy (STORY_ID=ga-o3o09z). Exits 0 on pass. Overrides (tests): CITY, PILOT_PLIST,
# POOL_CEILING_ENGINE_FRAGMENT.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
PILOT_PLIST="${PILOT_PLIST:-$HOME/Library/LaunchAgents/com.gascity.pilot.plist}"

log()  { echo "[prod-test:gascity ga-o3o09z] $*"; }
fail() { echo "[prod-test:gascity ga-o3o09z] FAIL: $*" >&2; exit 1; }

# ── 1. agent.toml is the committed source of truth: an integer max_active_sessions >= 1 ──
# A number this script compares or sums must be a canonical decimal integer: "0", or no leading zero. "09" is not a TOML integer (gc
# rejects it at load) and bash arithmetic reads it as a bad octal, erroring quietly inside [[ -gt ]] and $(( )) — so it never
# enters as if it were 9. Every number read from outside (agent.toml, the fragment, the Pilot plist) is checked against INT_RE.
INT_RE='^(0|[1-9][0-9]*)$'
agent_cap() { local v; v=$(sed -n 's/^max_active_sessions[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$1" 2>/dev/null | head -1); [[ "$v" =~ $INT_RE ]] && printf '%s' "$v"; return 0; }
CFG="$CITY/agents/wa-worker/agent.toml"
[[ -f "$CFG" ]] || fail "agent config missing: $CFG"
WA_BASE=$(agent_cap "$CFG")
if ! [[ "$WA_BASE" =~ $INT_RE ]] || [[ "$WA_BASE" -lt 1 ]]; then
    fail "wa-worker: no integer max_active_sessions >= 1 in $CFG (got: $(grep '^max_active_sessions' "$CFG" || echo '<missing>'))"
fi
log "wa-worker: max_active_sessions = $WA_BASE in $CFG ✓"

# ── 2. No OTHER live source overrides the controller's view of this value ────
# city.toml can carry [[patches.agent]] blocks for name = "wa-worker"; none of
# them may set max_active_sessions (that would make agent.toml a second-place
# value, not the single source of truth this story requires).
CITY_TOML="$CITY/city.toml"
SKIPPED=""   # every soft skip below lands here, so the final PASS line says what it did NOT check
[[ -f "$CITY_TOML" && -r "$CITY_TOML" ]] || fail "city.toml missing or unreadable: $CITY_TOML"   # unreadable must not read as "no include" in section 3
if command -v python3 >/dev/null 2>&1; then
    PY_OUT=$(python3 - "$CITY_TOML" <<'PY' 2>&1
import sys
try:
    import tomllib
except ImportError:
    print(f"python3 {sys.version.split()[0]} has no tomllib (needs >= 3.11): cannot check {sys.argv[1]}", file=sys.stderr)
    sys.exit(2)
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:
    print(f"cannot read/parse {sys.argv[1]}: {e}", file=sys.stderr)
    sys.exit(2)
patches = cfg.get("patches", {})
agent_patches = patches.get("agent", []) if isinstance(patches, dict) else []
bad = [p for p in agent_patches if isinstance(p, dict) and p.get("name") in ("wa-worker", "ps-worker", "gate-reviewer") and "max_active_sessions" in p]
if bad:
    print(f"found max_active_sessions override(s) for the engine's pools in [[patches.agent]]: {bad}", file=sys.stderr)
    sys.exit(1)
PY
    )
    PY_RC=$?
    case "$PY_RC" in
        0)
            log "city.toml: no [[patches.agent]] override of max_active_sessions for wa-worker, ps-worker or gate-reviewer ✓"
            ;;
        2)
            # "Cannot determine" (missing tomllib, unreadable/unparseable file) is a
            # distinct outcome from "override found" — collapsing it into FAIL would
            # spuriously break this test wherever command -v python3 resolves to a
            # <3.11 interpreter (e.g. this host's own /usr/bin/python3 is 3.9.6),
            # even though no override exists and the real cause is tooling, not drift.
            log "city.toml override check: cannot determine ($PY_OUT) — soft skip, not a failure"
            SKIPPED="$SKIPPED city.toml-override-check"
            ;;
        *)
            fail "city.toml [[patches.agent]] for wa-worker/ps-worker/gate-reviewer sets max_active_sessions — agent.toml (+ the fragment) is no longer the only source ($PY_OUT)"
            ;;
    esac
else
    log "python3 unavailable — skipping city.toml override check (soft skip, not a failure)"
    SKIPPED="$SKIPPED city.toml-override-check"
fi

# ── 3. The generated pool-ceiling fragment (ga-m9x0lb.2): present when included, exactly what the engine writes ──
# Strict parse of the only shape pool-ceiling-engine.sh renders: blocks of [[patches.agent]] / dir = "" / name = "x" /
# max_active_sessions = N, plus comments and blanks. Anything else is FOREIGN: the effective ceiling would be unknowable.
FRAGMENT="${POOL_CEILING_ENGINE_FRAGMENT:-$CITY/.gc/pool-ceiling-engine.toml}"
# Does city.toml INCLUDE the fragment? Three answers, never two: 1 yes, 0 no, ? cannot tell. It is read from the PARSED city.toml —
# the `include` array, each entry resolved against city.toml's directory and compared with the fragment's real path — and not
# matched as text: a trailing `# was ".gc/pool-ceiling-engine.toml"`, a `.toml.bak`, or the same file name in another directory
# is not an include, and a text match read all three as one while the controller loaded nothing (gate rounds 1-2 of ga-m9x0lb.2.1).
# The verdict is the token python prints, never its exit status: a crash exits 1 as well, and that must not read as "not included".
INCLUDED="?"; INCLUDE_WHY=""
if command -v python3 >/dev/null 2>&1; then
    INCLUDE_OUT=$(python3 - "$CITY_TOML" "$FRAGMENT" <<'PY' 2>&1
import os, sys
try:
    import tomllib
except ImportError:
    print(f"python3 {sys.version.split()[0]} has no tomllib (needs >= 3.11)")
    sys.exit(2)
city_toml, fragment = sys.argv[1], sys.argv[2]
try:
    with open(city_toml, "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:
    print(f"cannot read/parse {city_toml}: {e}")
    sys.exit(2)
inc = cfg.get("include", [])
if not isinstance(inc, list) or not all(isinstance(e, str) for e in inc):
    print(f"'include' in {city_toml} is not an array of strings")
    sys.exit(2)
base = os.path.dirname(os.path.abspath(city_toml))
want = os.path.realpath(fragment)
print("included" if any(os.path.realpath(os.path.join(base, e)) == want for e in inc) else "not-included")
PY
    )
    case "${INCLUDE_OUT##*$'\n'}" in
        included)     INCLUDED=1 ;;
        not-included) INCLUDED=0 ;;
        *)            INCLUDE_WHY="${INCLUDE_OUT:-no verdict}" ;;
    esac
else
    INCLUDE_WHY="python3 unavailable"
fi
FRAG_ENTRIES=""
if [[ -e "$FRAGMENT" ]]; then
    FRAG_ENTRIES=$(awk '
        function fin() { if (inblk && !(hd && hn && hm)) bad = 1 }
        BEGIN { inblk = 0; bad = 0 }
        /^[[:space:]]*(#.*)?$/ { next }
        /^\[\[patches\.agent\]\][[:space:]]*$/ { fin(); inblk = 1; hd = 0; hn = 0; hm = 0; nm = ""; next }
        /^dir[[:space:]]*=[[:space:]]*""[[:space:]]*$/ { if (!inblk || hd) bad = 1; hd = 1; next }
        /^name[[:space:]]*=[[:space:]]*"[a-z0-9._-]+"[[:space:]]*$/ { if (!inblk || hn) bad = 1; hn = 1; s = $0; sub(/^name[[:space:]]*=[[:space:]]*"/, "", s); sub(/"[[:space:]]*$/, "", s); nm = s; if (nm in seen) bad = 1; seen[nm] = 1; next }
        /^max_active_sessions[[:space:]]*=[[:space:]]*(0|[1-9][0-9]*)[[:space:]]*$/ { if (!inblk || hm || !hn) bad = 1; hm = 1; s = $0; sub(/^[^=]*=[[:space:]]*/, "", s); sub(/[[:space:]]*$/, "", s); out[++n] = nm "=" (s + 0); next }
        { bad = 1 }
        END { fin(); if (bad) exit 1; for (i = 1; i <= n; i++) print out[i]; exit 0 }
    ' "$FRAGMENT") || fail "$FRAGMENT has FOREIGN content (not what pool-ceiling-engine.sh writes): the effective ceilings are unknowable"
    FRAG_ENTRIES=$(printf '%s' "$FRAG_ENTRIES" | tr '\n' ' ')
    log "fragment $FRAGMENT well-formed (entries: ${FRAG_ENTRIES:-none}) ✓"
    # A file the controller never loads is not in force: reading its entries as the effective ceiling is the ga-o3o09z drift itself.
    # And "cannot tell whether it is loaded" is not "it is loaded": a populated fragment with an unknown include is a FAIL.
    if [[ -n "${FRAG_ENTRIES// /}" ]]; then
        case "$INCLUDED" in
            1) ;;
            0) fail "$FRAGMENT has entries (${FRAG_ENTRIES}) but city.toml does not include it: the controller applies none of them" ;;
            *) fail "$FRAGMENT has entries (${FRAG_ENTRIES}) and whether city.toml includes it cannot be told (${INCLUDE_WHY}): the effective ceiling is unknowable, and unknown is not 'in force'" ;;
        esac
    elif [[ "$INCLUDED" == "?" ]]; then
        log "city.toml include check: cannot determine (${INCLUDE_WHY}) — soft skip; an empty fragment sets no ceiling whether or not it is loaded"
        SKIPPED="$SKIPPED city.toml-include-check"
    fi
elif [[ "$INCLUDED" == 1 ]]; then
    fail "city.toml includes $(basename "$FRAGMENT") but $FRAGMENT is ABSENT — gc config load error (the kill switch EMPTIES the fragment, it never deletes it)"
elif [[ "$INCLUDED" == 0 ]]; then
    log "no pool-ceiling fragment and city.toml does not include one (engine not installed) — effective ceilings = agent.toml ✓"
else
    log "no pool-ceiling fragment; whether city.toml includes one cannot be determined (${INCLUDE_WHY}) — soft skip (an include of the absent file would be a gc config load error); effective ceilings = agent.toml"
    SKIPPED="$SKIPPED city.toml-include-check"
fi
frag_level() { local e; for e in $FRAG_ENTRIES; do case "$e" in "$1="*) printf '%s' "${e#*=}"; return 0 ;; esac; done; return 0; }
for e in $FRAG_ENTRIES; do
    pool="${e%%=*}"; lvl="${e#*=}"
    case "$pool" in
        wa-worker|ps-worker|gate-reviewer) ;;
        *) fail "fragment entry for '$pool': outside the engine's allowlist (wa-worker ps-worker gate-reviewer)" ;;
    esac
    { [[ "$lvl" -ge 1 ]] && [[ "$lvl" -le 8 ]]; } || fail "fragment entry $pool=$lvl: outside [1, 8]"
    if [[ "$pool" != "wa-worker" ]]; then
        base=$(agent_cap "$CITY/agents/$pool/agent.toml")
        [[ "$base" =~ $INT_RE ]] || fail "fragment entry $pool=$lvl but $CITY/agents/$pool/agent.toml has no readable max_active_sessions to compare with"
        [[ "$lvl" -le "$base" ]] || fail "fragment entry $pool=$lvl is ABOVE agent.toml's $base — only wa-worker may be raised (the others only go down)"
    fi
done
WA_EFF=$(frag_level wa-worker); WA_EFF="${WA_EFF:-$WA_BASE}"
log "wa-worker effective engine ceiling = $WA_EFF (agent.toml $WA_BASE) ✓"

# ── 4. The Pilot's own ceiling (separate mechanism) is consistent, not stale ──
# PILOT_WA_WORKER_MAX only bounds what the Pilot itself dispatches — it never
# reaches the controller — so it is allowed to be MORE conservative than the
# effective engine ceiling, but must never be HIGHER (that would let the Pilot
# dispatch past the controller's real ceiling under the false belief it is capped).
if [[ -f "$PILOT_PLIST" ]]; then
    PLIST_MAX=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PILOT_WA_WORKER_MAX" "$PILOT_PLIST" 2>/dev/null || true)
    if [[ -z "$PLIST_MAX" ]]; then
        log "PILOT_WA_WORKER_MAX not set in $PILOT_PLIST — nothing to cross-check, skipping (soft skip)"
        SKIPPED="$SKIPPED pilot-ceiling-crosscheck"
    elif ! [[ "$PLIST_MAX" =~ $INT_RE ]]; then
        fail "PILOT_WA_WORKER_MAX in $PILOT_PLIST is not a plain integer: '$PLIST_MAX'"
    elif [[ "$PLIST_MAX" -gt "$WA_EFF" ]]; then
        fail "PILOT_WA_WORKER_MAX=$PLIST_MAX > the effective engine ceiling $WA_EFF — Pilot would believe it can dispatch past the controller's real ceiling"
    else
        log "PILOT_WA_WORKER_MAX=$PLIST_MAX <= effective engine ceiling $WA_EFF ✓ (redundant-but-consistent)"
    fi
else
    log "$PILOT_PLIST not found on this host — skipping Pilot plist cross-check (soft skip, not a failure)"
    SKIPPED="$SKIPPED pilot-ceiling-crosscheck"
fi

# ── 5. The sum of the effective ceilings fits GC_VARIABLE_SESSION_MAX ─────────
# The dispatchers apply that bound to LIVE sessions; the controller never does, so the SUM of what it is allowed to open must
# fit it by construction (wa-worker + ps-worker + gate-reviewer: the three elastic pools the bound covers).
BUDGET=""
[[ -f "$PILOT_PLIST" ]] && BUDGET=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:GC_VARIABLE_SESSION_MAX" "$PILOT_PLIST" 2>/dev/null || true)
if ! [[ "$BUDGET" =~ $INT_RE ]]; then
    log "GC_VARIABLE_SESSION_MAX not readable from $PILOT_PLIST — skipping the sum check (soft skip)"
    SKIPPED="$SKIPPED sum-vs-GC_VARIABLE_SESSION_MAX"
else
    SUM=0
    for pool in wa-worker ps-worker gate-reviewer; do
        eff=$(frag_level "$pool")
        [[ -n "$eff" ]] || eff=$(agent_cap "$CITY/agents/$pool/agent.toml")
        [[ "$eff" =~ $INT_RE ]] || fail "effective ceiling of $pool unreadable ($CITY/agents/$pool/agent.toml has no integer max_active_sessions): the sum cannot be checked, and unknown is not 'fits'"
        SUM=$((SUM + eff))
    done
    if [[ "$SUM" -gt "$BUDGET" ]]; then
        fail "sum of the effective ceilings (wa-worker+ps-worker+gate-reviewer) = $SUM > GC_VARIABLE_SESSION_MAX=$BUDGET"
    else
        log "sum of the effective ceilings = $SUM <= GC_VARIABLE_SESSION_MAX=$BUDGET ✓"
    fi
fi

log "PASS — agents/wa-worker/agent.toml (+ the engine's generated fragment, the only other sanctioned source) defines the controller's wa-worker ceiling ($WA_EFF), and the Pilot's own ceiling does not disagree${SKIPPED:+ (NOT CHECKED, soft-skipped:$SKIPPED)}"
exit 0
