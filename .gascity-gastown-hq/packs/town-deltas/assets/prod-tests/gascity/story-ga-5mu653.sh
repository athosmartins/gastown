#!/usr/bin/env bash
# prod-tests/gascity/story-ga-5mu653.sh — verify ga-5mu653: the wisp-compact order
# is gone at EVERY scope (city + one instance per rig), and nothing else went with it.
#
# Why this asserts on the LIVE order set and not only on git: a town-deltas
# override/tombstone only shadows the CITY-scoped instance. The maintenance pack's
# builtin order also registers one instance PER RIG (wisp-compact:rig:<rig>); before
# this story 6 of the 7 instances came from the builtin (no mail carve-out), each on
# a 1h cooldown. `gc order list --json` is what the controller schedules from.
#
# Three-state on purpose: "gc could not list" must FAIL, never read as "zero
# instances". So we also require ok:true and that well-known control orders are
# still listed (a broken city.toml would otherwise look like a clean removal).
#
# GC_CITY overrides the city dir (lets this test run against a scratch city).

set -euo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"

log()  { echo "[prod-test:ga-5mu653] $*"; }
fail() { echo "[prod-test:ga-5mu653] FAIL: $*" >&2; exit 1; }

# ── 1. The live order set: zero wisp-compact instances, controls still present ──
LIST=""
for attempt in 1 2 3; do
    if LIST=$(gc --city "$CITY" order list --json 2>/dev/null) \
       && printf '%s' "$LIST" | jq -e '.ok == true and (.orders | type == "array")' >/dev/null 2>&1; then
        break
    fi
    LIST=""
    log "gc order list attempt $attempt failed; retrying"
    sleep 5
done
[ -n "$LIST" ] || fail "could not list orders after 3 attempts — cannot tell, NOT treating it as zero instances"

N=$(printf '%s' "$LIST" | jq '[.orders[] | select(.name == "wisp-compact")] | length')
if [ "$N" != "0" ]; then
    SCOPES=$(printf '%s' "$LIST" | jq -r '[.orders[] | select(.name == "wisp-compact") | .scoped_name] | join(", ")')
    fail "wisp-compact is still registered: $N instance(s) [$SCOPES] — a city-level override does not reach the per-rig builtin instances; city.toml [orders] skip does"
fi
log "wisp-compact: 0 instances in the live order set (all scopes)"

for want in mol-dog-reaper gate-sweep; do
    printf '%s' "$LIST" | jq -e --arg n "$want" '[.orders[].name] | index($n) != null' >/dev/null \
        || fail "control order '$want' is missing from the order set — the change took out more than wisp-compact"
done
log "control orders still listed: mol-dog-reaper, gate-sweep"

# ── 2. The tracked config carries the switch ─────────────────────────────────
python3 - "$CITY/city.toml" <<'PY' || fail "city.toml does not carry [orders] skip = [\"wisp-compact\"] (see stderr above)"
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:      # cannot tell must fail, not pass
    print(f"cannot read/parse {sys.argv[1]}: {e}", file=sys.stderr)
    sys.exit(2)
orders = cfg.get("orders", {})
skip = orders.get("skip", []) if isinstance(orders, dict) else []
if not isinstance(skip, list) or "wisp-compact" not in skip:
    print(f"[orders].skip is {skip!r}", file=sys.stderr)
    sys.exit(1)
PY
log "city.toml: [orders] skip contains wisp-compact"

# ── 3. The removed artifacts stay removed ────────────────────────────────────
for rel in packs/town-deltas/orders/wisp-compact.toml \
           packs/town-deltas/assets/scripts/wisp-compact.sh \
           packs/town-deltas/assets/scripts/wisp-compact.selftest.sh; do
    [ ! -e "$CITY/$rel" ] || fail "leftover of the removed order: $CITY/$rel"
done
log "vendored override, script and selftest are gone"

log "PASS"
exit 0
