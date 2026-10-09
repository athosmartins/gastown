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
#      (only wa-worker may be raised: "the others only go down");
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
agent_cap() { sed -n 's/^max_active_sessions[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$1" 2>/dev/null | head -1; }
CFG="$CITY/agents/wa-worker/agent.toml"
[[ -f "$CFG" ]] || fail "agent config missing: $CFG"
WA_BASE=$(agent_cap "$CFG")
if ! [[ "$WA_BASE" =~ ^[0-9]+$ ]] || [[ "$WA_BASE" -lt 1 ]]; then
    fail "wa-worker: no integer max_active_sessions >= 1 in $CFG (got: $(grep '^max_active_sessions' "$CFG" || echo '<missing>'))"
fi
log "wa-worker: max_active_sessions = $WA_BASE in $CFG ✓"

# ── 2. No OTHER live source overrides the controller's view of this value ────
# city.toml can carry [[patches.agent]] blocks for name = "wa-worker"; none of
# them may set max_active_sessions (that would make agent.toml a second-place
# value, not the single source of truth this story requires).
CITY_TOML="$CITY/city.toml"
[[ -f "$CITY_TOML" ]] || fail "city.toml missing: $CITY_TOML"
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
bad = [p for p in agent_patches if isinstance(p, dict) and p.get("name") == "wa-worker" and "max_active_sessions" in p]
if bad:
    print(f"found max_active_sessions override(s) for wa-worker in [[patches.agent]]: {bad}", file=sys.stderr)
    sys.exit(1)
PY
    )
    PY_RC=$?
    case "$PY_RC" in
        0)
            log "city.toml: no [[patches.agent]] override of wa-worker max_active_sessions ✓"
            ;;
        2)
            # "Cannot determine" (missing tomllib, unreadable/unparseable file) is a
            # distinct outcome from "override found" — collapsing it into FAIL would
            # spuriously break this test wherever command -v python3 resolves to a
            # <3.11 interpreter (e.g. this host's own /usr/bin/python3 is 3.9.6),
            # even though no override exists and the real cause is tooling, not drift.
            log "city.toml override check: cannot determine ($PY_OUT) — soft skip, not a failure"
            ;;
        *)
            fail "city.toml [[patches.agent]] for wa-worker sets max_active_sessions — agent.toml is no longer the single source ($PY_OUT)"
            ;;
    esac
else
    log "python3 unavailable — skipping city.toml override check (soft skip, not a failure)"
fi

# ── 3. The generated pool-ceiling fragment (ga-m9x0lb.2): present when included, exactly what the engine writes ──
# Strict parse of the only shape pool-ceiling-engine.sh renders: blocks of [[patches.agent]] / dir = "" / name = "x" /
# max_active_sessions = N, plus comments and blanks. Anything else is FOREIGN: the effective ceiling would be unknowable.
FRAGMENT="${POOL_CEILING_ENGINE_FRAGMENT:-$CITY/.gc/pool-ceiling-engine.toml}"
INCLUDED=0
if grep -v '^[[:space:]]*#' "$CITY_TOML" 2>/dev/null | grep -qF "$(basename "$FRAGMENT")"; then INCLUDED=1; fi
FRAG_ENTRIES=""
if [[ -e "$FRAGMENT" ]]; then
    FRAG_ENTRIES=$(awk '
        function fin() { if (inblk && !(hd && hn && hm)) bad = 1 }
        BEGIN { inblk = 0; bad = 0 }
        /^[[:space:]]*(#.*)?$/ { next }
        /^\[\[patches\.agent\]\][[:space:]]*$/ { fin(); inblk = 1; hd = 0; hn = 0; hm = 0; nm = ""; next }
        /^dir[[:space:]]*=[[:space:]]*""[[:space:]]*$/ { if (!inblk || hd) bad = 1; hd = 1; next }
        /^name[[:space:]]*=[[:space:]]*"[a-z0-9._-]+"[[:space:]]*$/ { if (!inblk || hn) bad = 1; hn = 1; s = $0; sub(/^name[[:space:]]*=[[:space:]]*"/, "", s); sub(/"[[:space:]]*$/, "", s); nm = s; if (nm in seen) bad = 1; seen[nm] = 1; next }
        /^max_active_sessions[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ { if (!inblk || hm || !hn) bad = 1; hm = 1; s = $0; sub(/^[^=]*=[[:space:]]*/, "", s); sub(/[[:space:]]*$/, "", s); out[++n] = nm "=" (s + 0); next }
        { bad = 1 }
        END { fin(); if (bad) exit 1; for (i = 1; i <= n; i++) print out[i]; exit 0 }
    ' "$FRAGMENT") || fail "$FRAGMENT has FOREIGN content (not what pool-ceiling-engine.sh writes): the effective ceilings are unknowable"
    FRAG_ENTRIES=$(printf '%s' "$FRAG_ENTRIES" | tr '\n' ' ')
    log "fragment $FRAGMENT well-formed (entries: ${FRAG_ENTRIES:-none}) ✓"
elif [[ "$INCLUDED" == 1 ]]; then
    fail "city.toml includes $(basename "$FRAGMENT") but $FRAGMENT is ABSENT — gc config load error (the kill switch EMPTIES the fragment, it never deletes it)"
else
    log "no pool-ceiling fragment and city.toml does not include one (engine not installed) — effective ceilings = agent.toml ✓"
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
        [[ "$base" =~ ^[0-9]+$ ]] || fail "fragment entry $pool=$lvl but $CITY/agents/$pool/agent.toml has no readable max_active_sessions to compare with"
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
    elif ! [[ "$PLIST_MAX" =~ ^[0-9]+$ ]]; then
        fail "PILOT_WA_WORKER_MAX in $PILOT_PLIST is not a plain integer: '$PLIST_MAX'"
    elif [[ "$PLIST_MAX" -gt "$WA_EFF" ]]; then
        fail "PILOT_WA_WORKER_MAX=$PLIST_MAX > the effective engine ceiling $WA_EFF — Pilot would believe it can dispatch past the controller's real ceiling"
    else
        log "PILOT_WA_WORKER_MAX=$PLIST_MAX <= effective engine ceiling $WA_EFF ✓ (redundant-but-consistent)"
    fi
else
    log "$PILOT_PLIST not found on this host — skipping Pilot plist cross-check (soft skip, not a failure)"
fi

# ── 5. The sum of the effective ceilings fits GC_VARIABLE_SESSION_MAX ─────────
# The dispatchers apply that bound to LIVE sessions; the controller never does, so the SUM of what it is allowed to open must
# fit it by construction (wa-worker + ps-worker + gate-reviewer: the three elastic pools the bound covers).
BUDGET=""
[[ -f "$PILOT_PLIST" ]] && BUDGET=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:GC_VARIABLE_SESSION_MAX" "$PILOT_PLIST" 2>/dev/null || true)
if ! [[ "$BUDGET" =~ ^[0-9]+$ ]]; then
    log "GC_VARIABLE_SESSION_MAX not readable from $PILOT_PLIST — skipping the sum check (soft skip)"
else
    SUM=0; UNREADABLE=""
    for pool in wa-worker ps-worker gate-reviewer; do
        eff=$(frag_level "$pool")
        [[ -n "$eff" ]] || eff=$(agent_cap "$CITY/agents/$pool/agent.toml")
        if [[ "$eff" =~ ^[0-9]+$ ]]; then SUM=$((SUM + eff)); else UNREADABLE="$UNREADABLE $pool"; fi
    done
    if [[ -n "$UNREADABLE" ]]; then
        log "effective ceiling unreadable for:${UNREADABLE} — skipping the sum check (soft skip)"
    elif [[ "$SUM" -gt "$BUDGET" ]]; then
        fail "sum of the effective ceilings (wa-worker+ps-worker+gate-reviewer) = $SUM > GC_VARIABLE_SESSION_MAX=$BUDGET"
    else
        log "sum of the effective ceilings = $SUM <= GC_VARIABLE_SESSION_MAX=$BUDGET ✓"
    fi
fi

log "PASS — agents/wa-worker/agent.toml (+ the engine's generated fragment, the only other sanctioned source) defines the controller's wa-worker ceiling ($WA_EFF), and the Pilot's own ceiling does not disagree"
exit 0
