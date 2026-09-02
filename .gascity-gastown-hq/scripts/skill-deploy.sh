#!/usr/bin/env bash
# skill-deploy.sh — Deploy a skill to the gastown-hq city skills sink
#
# GUARD: prevents re-priming live sessions by running "gc reload --soft" immediately
# after writing skill files. This accepts the config drift without restarting sessions,
# since gc reload --soft cancels any queued config-drift restart before the second
# reconciler tick fires restart_in_place.
#
# Usage:
#   skill-deploy.sh <skill-name> <source-skill-dir>
#
#   skill-name:       e.g. "refino"
#   source-skill-dir: directory containing SKILL.md (and any subdirs)
#
# Example (from ~/gt):
#   .gascity-gastown-hq/scripts/skill-deploy.sh refino gastown/city-local/skills/refino
#
# The script:
#   1. Validates args and source exists.
#   2. Checks for currently attached sessions (warns but does NOT block).
#   3. Copies skill files to the city source sink (.gascity-gastown-hq/skills/<name>/)
#      and the vendor sink (.gascity-gastown-hq/.claude/skills/<name>/).
#   4. Immediately runs "gc reload --soft" to accept config drift without restarting
#      any live attached sessions.
#
# Why "gc reload --soft" works here:
#   The engine defers named-session restarts for ONE reconciler tick (~30-60s) after
#   detecting FPExtra hash change. gc reload --soft updates the stored hash and cancels
#   any already-queued drains, so the second tick sees no drift and fires no restart.
#   Window: ~60 seconds between poke (file change detected) and tick-2 (actual restart).
#   gc reload --soft completes in < 5s under normal load, but the reload lock can be
#   held far longer under contention (measured 76s, ga-twax4) — step 4 retries at a
#   fixed interval for up to ~120s before telling the operator to run it by hand.

set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CITY_DIR defaults to the city this script lives in. SKILL_DEPLOY_CITY overrides
# it (used by the self-test to target a throwaway fixture; also lets the same
# script serve other cities). Default preserves the original behaviour exactly.
CITY_DIR="${SKILL_DEPLOY_CITY:-$(cd "$_SELF_DIR/.." && pwd)}"
GC="${GC:-gc}"

# Shared digest helper — the SAME implementation skill-audit.sh uses, so the
# manifest recorded here and the live hash the auditor computes can never
# disagree (that disagreement would be a false off-path flag).
# shellcheck source=skill-lib.sh
source "$_SELF_DIR/skill-lib.sh"

MANIFEST="${SKILL_MANIFEST:-$CITY_DIR/.gc/state/skill-manifest.json}"

# --- Parse args ---
if [[ $# -lt 2 ]]; then
    echo >&2 "usage: skill-deploy.sh <skill-name> <source-skill-dir>"
    echo >&2 "  skill-name:       name for the skill (e.g. 'refino')"
    echo >&2 "  source-skill-dir: path to directory containing SKILL.md"
    exit 1
fi

SKILL_NAME="$1"
SOURCE_DIR="$2"

# Resolve source dir (allow relative paths from cwd)
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo >&2 "skill-deploy: source directory not found: $SOURCE_DIR"
    exit 1
fi

if [[ ! -f "$SOURCE_DIR/SKILL.md" ]]; then
    echo >&2 "skill-deploy: SKILL.md not found in $SOURCE_DIR"
    exit 1
fi

CITY_SOURCE_SINK="$CITY_DIR/skills/$SKILL_NAME"
CITY_VENDOR_SINK="$CITY_DIR/.claude/skills/$SKILL_NAME"

# --- Check for attached sessions (warn only, does NOT block) ---
ATTACHED_SESSIONS=""
if command -v "$GC" >/dev/null 2>&1; then
    ATTACHED_SESSIONS=$(
        "$GC" session list --json --city "$CITY_DIR" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    attached = [s.get('name','?') + ' (' + s.get('id','?') + ')' for s in data.get('sessions', []) if s.get('attached')]
    print('\n'.join(attached))
except Exception as e:
    pass
" 2>/dev/null || true
    )
fi

if [[ -n "$ATTACHED_SESSIONS" ]]; then
    echo "skill-deploy: WARNING — human-attached sessions detected:"
    while IFS= read -r s; do
        echo "  - $s"
    done <<< "$ATTACHED_SESSIONS"
    echo ""
    echo "skill-deploy: Proceeding with deploy + gc reload --soft to suppress re-prime."
    echo "  Attached sessions will keep their current context; new context takes effect"
    echo "  on their next natural restart (or via 'gc prime <session>' if needed urgently)."
    echo ""
else
    echo "skill-deploy: No attached sessions — safe to deploy."
fi

# --- Copy skill files ---
echo "skill-deploy: Writing $SKILL_NAME to city source sink..."
mkdir -p "$CITY_SOURCE_SINK"
# Use rsync to copy entire directory tree (handles subdirs like references/)
rsync -a --delete "$SOURCE_DIR/" "$CITY_SOURCE_SINK/"

echo "skill-deploy: Writing $SKILL_NAME to city vendor sink (.claude/skills/)..."
mkdir -p "$CITY_VENDOR_SINK"
rsync -a --delete "$SOURCE_DIR/" "$CITY_VENDOR_SINK/"

echo "skill-deploy: Files written. Running gc reload --soft to suppress config-drift restarts..."

# --- Immediate soft reload (retried at a fixed interval) ---
# This cancels any queued config-drift drain caused by the FPExtra hash change above.
# A single attempt undershoots real lock contention (measured 76s vs. the <5s the
# header assumes) — retry before telling the operator to do it by hand within a
# window ("~60s") that can already have expired by the time they read it.
# Overridable so the selftest doesn't need real ~120s sleeps.
RELOAD_RETRY_WAIT="${SKILL_DEPLOY_RELOAD_RETRY_WAIT:-10}"       # seconds between retries
RELOAD_MAX_RETRIES="${SKILL_DEPLOY_RELOAD_MAX_RETRIES:-12}"     # retries after the first attempt (~120s total)

if command -v "$GC" >/dev/null 2>&1; then
    RELOAD_TOTAL_ATTEMPTS=$((RELOAD_MAX_RETRIES + 1))
    reload_ok=""
    attempt=1
    while (( attempt <= RELOAD_TOTAL_ATTEMPTS )); do
        if "$GC" reload --soft --city "$CITY_DIR" 2>&1; then
            reload_ok=1
            break
        fi
        if (( attempt < RELOAD_TOTAL_ATTEMPTS )); then
            echo "skill-deploy: gc reload --soft failed (attempt $attempt/$RELOAD_TOTAL_ATTEMPTS) — retrying in ${RELOAD_RETRY_WAIT}s..."
            sleep "$RELOAD_RETRY_WAIT"
        fi
        attempt=$((attempt + 1))
    done
    if [[ -n "$reload_ok" ]]; then
        echo "skill-deploy: gc reload --soft completed (attempt $attempt/$RELOAD_TOTAL_ATTEMPTS) — no session restarts will be triggered."
    else
        echo >&2 "skill-deploy: WARNING — gc reload --soft failed after $RELOAD_TOTAL_ATTEMPTS attempts (~$((RELOAD_MAX_RETRIES * RELOAD_RETRY_WAIT))s). Sessions may be restarted by the reconciler."
        echo >&2 "skill-deploy: Run 'gc reload --soft' manually within ~60s to prevent restarts."
    fi
else
    echo >&2 "skill-deploy: WARNING — 'gc' not found in PATH. Cannot run gc reload --soft."
    echo >&2 "skill-deploy: Run 'gc reload --soft --city $CITY_DIR' manually within ~60s to prevent restarts."
fi

# --- Record the official-deploy manifest entry ---
# This is the baseline that skill-audit.sh uses for off-path detection: it
# records the content digest of the canonical skill AS PUBLISHED through this
# script. A later canonical change that did NOT come through here will diverge
# from this digest, and the auditor flags it as an off-path write (criterion #3).
DEPLOY_DIGEST="$(skilllib_tree_digest "$CITY_SOURCE_SINK")"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DEPLOYED_BY="${BD_ACTOR:-${GIT_AUTHOR_NAME:-${USER:-unknown}}}"

mkdir -p "$(dirname "$MANIFEST")"
if MANIFEST="$MANIFEST" SKILL_NAME="$SKILL_NAME" DEPLOY_DIGEST="$DEPLOY_DIGEST" \
   DEPLOYED_AT="$DEPLOYED_AT" DEPLOYED_BY="$DEPLOYED_BY" SOURCE_DIR="$SOURCE_DIR" \
   python3 - <<'PY'
import json, os, sys, tempfile

path   = os.environ["MANIFEST"]
name   = os.environ["SKILL_NAME"]

# Read-merge-write so deploying one skill never clobbers another's entry.
try:
    with open(path) as f:
        m = json.load(f)
        if not isinstance(m, dict):
            m = {}
except (FileNotFoundError, json.JSONDecodeError):
    m = {}

m.setdefault("schema_version", "1")
skills = m.setdefault("skills", {})
skills[name] = {
    "tree_digest": os.environ["DEPLOY_DIGEST"],
    "deployed_at": os.environ["DEPLOYED_AT"],
    "deployed_by": os.environ["DEPLOYED_BY"],
    "source_dir":  os.environ["SOURCE_DIR"],
}

# Atomic write: tmp file in the same dir + os.replace, so a crash mid-write
# can never leave a half-written manifest (which would break the auditor).
d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".skill-manifest.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(m, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
then
    echo "skill-deploy: Manifest updated ($SKILL_NAME -> $DEPLOY_DIGEST) at $MANIFEST"
else
    echo >&2 "skill-deploy: WARNING — failed to update manifest at $MANIFEST."
    echo >&2 "skill-deploy: skill-audit.sh will flag '$SKILL_NAME' as unmanaged until the manifest records it."
fi

echo "skill-deploy: Done. Skill '$SKILL_NAME' deployed to $CITY_DIR."
echo ""
echo "NOTE: Running sessions already have their previous skill context loaded. To push"
echo "      the updated skill to a specific session immediately, run:"
echo "      gc prime <session-name>  (if supported)  OR  restart that session manually."
