#!/usr/bin/env bash
# prod-tests/gascity/story-ga-1exon4.sh — verify ga-1exon4: `deacon` is no longer a RIG in the
# city registry, and nothing that must survive the removal went with it.
#
# Decision (Athos, sessao batista-lx, 2026-09-15T20:41Z, verbatim): "Deacon nao deveria ser um rig".
# Plan (Mayor, ga-1exon4 comment): drop the [[rigs]] block from city.toml, then the machine-local
# binding from .gc/site.toml. NOT removed, on purpose: the AGENT gastown.deacon (city-scoped,
# dir=""), the directory <town>/deacon with its .beads (an UNTRACKED local directory — 0 files
# tracked, excluded in .git/info/exclude — so a deletion could not be restored from git), the 28
# dc-* beads (they live in the HQ store) and the Dolt database dc.
#
# The `dc` route in .beads/routes.jsonl is the one thing the plan wanted kept that this story
# CANNOT keep: gc derives every store's routes.jsonl from the rig registry (measured 2026-09-20:
# the 7 files were written in the same second and map 1:1 to the 7 rigs; writeAllRoutes and
# collectRigRoutes are in the live binary), so the route is expected to go with the rig. That is
# harmless for resolution — dc-b31r resolves TODAY while the route still points at the EMPTY
# deacon store, so bd is finding it in the local store and not through the route — which is why
# check 3 asserts on resolution and only REPORTS the route.
#
# What this pins, in production (each check has its own failure message):
#   1. The file the controller loads (city.toml) declares no rig named deacon, and still declares
#      the 5 other declared rigs — a bad edit that ate a neighbour must not read as success.
#   2. The LIVE registry (`gc rig list --json`) has no deacon and still lists all 6 remaining
#      rigs (gascity is the city's own rig and is never declared in city.toml).
#   3. What must survive is still there: a dc-* bead resolving through plain `bd` AND through
#      `gc bd` (the second is what would break if gc resolved dc-* through the rig registry), and
#      the rig directory with its .beads.
#   (info) the dc route, and .gc/site.toml — machine-local, gitignored. Until the post-merge
#      cleanup it still binds deacon; gc only WARNS about that ("binding for unknown rig",
#      measured on a throwaway city 2026-09-20). Both are reported and never failed on.
#
# Three-state on purpose: "gc could not list" / "could not parse" is a FAIL — it must never read
# as "deacon is gone".
#
# Deliberately NOT here: a "no session was config-drift drained by the reload" check. The only
# place the engine records a drift drain is ~/.gc/supervisor.log ("Draining session 'x':
# config-drift"), and those lines carry NO timestamp of their own, so they cannot be tied to this
# reload without reconstructing one from the surrounding api lines; the current file (2026-09-08
# to 09-20) holds 148 of them, and a session with live assigned work is skipped, not drained
# ("Skipping config-drift drain ...: live assigned work found"). An assertion on it here would be
# vacuous or flaky. The reload's safety rests on ga-00ghg5 (that skip, present in the live binary)
# + config-drift-watcher (soft reload on any city.toml change), and the post-merge follow-up
# checks the log by hand with a timestamp-carrying awk.
#
# GC_CITY overrides the city dir (lets this test run against a scratch/fixture city);
# STORY_TEST_RETRY_SLEEP shortens the propagation wait between `gc rig list` attempts.

set -uo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
TOWN="$(cd "$CITY/.." && pwd)"
DEACON_DIR="$TOWN/deacon"
RETRY_SLEEP="${STORY_TEST_RETRY_SLEEP:-20}"
ATTEMPTS=6

log()  { echo "[prod-test:ga-1exon4] $*"; }
fail() { echo "[prod-test:ga-1exon4] FAIL: $*" >&2; exit 1; }

command -v jq      >/dev/null 2>&1 || fail "jq is not on PATH — cannot tell, NOT treating it as a pass"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH — cannot tell, NOT treating it as a pass"
TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 120"

# ── 1. The file the controller loads: no deacon, neighbours intact ─────────────────
python3 - "$CITY/city.toml" <<'PY' || fail "city.toml check failed (see stderr above)"
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:      # cannot tell must fail, not pass
    print(f"cannot read/parse {sys.argv[1]}: {e}", file=sys.stderr)
    sys.exit(2)
names = [r.get("name") for r in cfg.get("rigs", []) if isinstance(r, dict)]
if "deacon" in names:
    print(f"city.toml still declares [[rigs]] name = \"deacon\" (declared: {names})", file=sys.stderr)
    sys.exit(1)
lost = sorted({"property_scrapers", "marketing", "lexbh", "gastown", "whatsapp_automation"} - set(names))
if lost:
    print(f"city.toml lost rigs it must keep: {lost} (declared: {names})", file=sys.stderr)
    sys.exit(1)
PY
log "city.toml: no deacon; property_scrapers marketing lexbh gastown whatsapp_automation still declared"

# ── 2. The LIVE registry ───────────────────────────────────────────────────────────
# The CLI can lag the file by a reload, so wait a bounded time — but only for "deacon still
# listed"; a listing that fails or has no .rigs array is "cannot tell" and ends in FAIL.
STATE="cannot-list"
NAMES=""
attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if OUT=$($TMO gc --city "$CITY" rig list --json 2>/dev/null) \
       && printf '%s' "$OUT" | jq -e '.rigs | type == "array"' >/dev/null 2>&1; then
        NAMES=$(printf '%s' "$OUT" | jq -r '.rigs[].name' | sort | tr '\n' ' ')
        if printf '%s' "$OUT" | jq -e 'any(.rigs[]; .name == "deacon")' >/dev/null 2>&1; then
            STATE="deacon-listed"
            log "attempt $attempt/$ATTEMPTS: live registry still lists deacon ($NAMES) — waiting for the reload"
        else
            STATE="ok"
            break
        fi
    else
        STATE="cannot-list"
        log "attempt $attempt/$ATTEMPTS: gc rig list failed or returned no .rigs array"
    fi
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep "$RETRY_SLEEP"
done
case "$STATE" in
    ok) ;;
    deacon-listed) fail "the live registry still lists deacon after $ATTEMPTS attempts ($NAMES) although city.toml on disk is clean — the reload did not land; check .gc/logs/config-drift-watcher.log" ;;
    *)             fail "could not list the live rig registry after $ATTEMPTS attempts — cannot tell, NOT treating it as 'deacon is gone'" ;;
esac
for keep in gascity property_scrapers marketing lexbh gastown whatsapp_automation; do
    case " $NAMES " in
        *" $keep "*) ;;
        *) fail "rig '$keep' is missing from the live registry ($NAMES) — the change took out more than deacon" ;;
    esac
done
log "live registry: no deacon; still listed: $NAMES"

# ── 3. What must survive the removal ───────────────────────────────────────────────
# (info) the dc route: gc rewrites routes.jsonl from the registry, so it may still be there or may
# already be gone — neither is a failure. An unreadable/unparseable file is reported as UNKNOWN,
# never as "gone".
ROUTES="$CITY/.beads/routes.jsonl"
ROUTE_STATE=$(python3 -c '
import sys, json
try:
    with open(sys.argv[1]) as f:
        found = any(json.loads(l).get("prefix") == "dc" for l in f if l.strip())
    print("present" if found else "absent")
except Exception:
    print("unknown")
' "$ROUTES" 2>/dev/null) || ROUTE_STATE="unknown"
case "$ROUTE_STATE" in
    present) log "NOTE: routes.jsonl still has the dc route (gc drops it when it rewrites routes from the registry) — harmless" ;;
    absent)  log "routes.jsonl: no dc route (expected: gc derives routes from the rig registry) — dc-* still resolve locally, see below" ;;
    *)       log "NOTE: cannot read/parse $ROUTES — whether the dc route is still there is UNKNOWN (informational only, not a failure)" ;;
esac

# Which dc-* bead to resolve: the one the Mayor verified with (dc-b31r), else any dc-* bead in the
# HQ store. A failed listing is "cannot tell"; a successful listing with zero dc-* beads means the
# beads this story promises to leave alone are gone — also a FAIL.
DC_ID=""
if bd -C "$CITY" show dc-b31r --json 2>/dev/null | jq -e '.[0].id == "dc-b31r"' >/dev/null 2>&1; then
    DC_ID="dc-b31r"
else
    LIST=$(bd -C "$CITY" list --all --limit 0 --json 2>/dev/null) \
        || fail "could not list the HQ store — cannot tell whether dc-* beads still resolve"
    DC_ID=$(printf '%s' "$LIST" | jq -r '[.[] | select(.id | startswith("dc-"))][0].id // empty' 2>/dev/null) \
        || fail "could not parse the HQ store listing — cannot tell whether dc-* beads still resolve"
    [ -n "$DC_ID" ] || fail "no dc-* bead is left in the HQ store — the removal must not touch them"
fi
bd -C "$CITY" show "$DC_ID" --json 2>/dev/null | jq -e --arg id "$DC_ID" '.[0].id == $id' >/dev/null 2>&1 \
    || fail "plain bd cannot resolve $DC_ID from the HQ store"
gc --city "$CITY" bd show "$DC_ID" --json 2>/dev/null | jq -e --arg id "$DC_ID" '.[0].id == $id' >/dev/null 2>&1 \
    || fail "'gc bd show $DC_ID' does not resolve although plain bd does — gc is resolving dc-* through the rig registry"
log "dc-* beads still resolve ($DC_ID) through plain bd and through gc bd"

[ -d "$DEACON_DIR" ]       || fail "the rig directory $DEACON_DIR is gone — the decision removes the registration, never the directory (it is untracked: git cannot restore it)"
[ -d "$DEACON_DIR/.beads" ] || fail "$DEACON_DIR/.beads is gone — the decision removes the registration, never the data (it is untracked: git cannot restore it)"
log "$DEACON_DIR and its .beads are untouched"

# ── (info) the machine-local binding ───────────────────────────────────────────────
SITE="$CITY/.gc/site.toml"
if [ ! -r "$SITE" ]; then
    log "NOTE: cannot read $SITE — whether it still binds deacon is UNKNOWN (informational only, not a failure)"
elif grep -q -E '^name[[:space:]]*=[[:space:]]*"deacon"' "$SITE"; then
    log "NOTE: .gc/site.toml still binds deacon (an orphan; gc only warns about it) — remove it in the post-merge cleanup"
else
    log ".gc/site.toml: no deacon binding"
fi

log "PASS"
exit 0
