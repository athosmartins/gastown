#!/usr/bin/env bash
# prod-tests/gascity/story-ga-7sxdmb.sh — verify ga-7sxdmb: the JSONL export runs from ONE
# order, city-scoped, on the vendored script that carries the partial-export guards — and no
# order at any scope still resolves to the maintenance pack's stale copy.
#
# Why this asserts on the LIVE order set and not only on git: the town-deltas same-name
# override of mol-dog-jsonl (ga-gtrc8n, ga-fxrrav) only shadowed the CITY-scoped instance.
# The maintenance pack's builtin order also registers one instance PER RIG, and those five
# kept running the builtin script — the one WITHOUT the ga-fxrrav fix — into the shared
# packs/maintenance/jsonl-archive: a truncated export was committed as the snapshot, and the
# next complete export read as a growth spike ("JSONL spike detected [HIGH]", WA 3430 -> 505
# -> 5425 on 2026-09-26). `gc order list --json` is what the controller schedules from.
#
# Three-state on purpose: "gc could not list" must FAIL, never read as "zero instances". So
# we also require ok:true and that well-known control orders are still listed (a broken
# city.toml would otherwise look like a clean removal).
#
# GC_CITY overrides the city dir (lets this test run against a scratch city).

set -euo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"

log()  { echo "[prod-test:ga-7sxdmb] $*"; }
fail() { echo "[prod-test:ga-7sxdmb] FAIL: $*" >&2; exit 1; }

# ── 1. The live order set ────────────────────────────────────────────────────
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

# 1a. The old name is gone at EVERY scope (city + one instance per rig).
N=$(printf '%s' "$LIST" | jq '[.orders[] | select(.name == "mol-dog-jsonl")] | length')
if [ "$N" != "0" ]; then
    SCOPES=$(printf '%s' "$LIST" | jq -r '[.orders[] | select(.name == "mol-dog-jsonl") | .scoped_name] | join(", ")')
    fail "mol-dog-jsonl is still registered: $N instance(s) [$SCOPES] — a city-level override does not reach the per-rig builtin instances; city.toml [orders] skip does"
fi
log "mol-dog-jsonl: 0 instances in the live order set (all scopes)"

# 1b. The class, not the name: whatever an order is called and wherever it is scoped, exactly
#     one runs a jsonl-export.sh — a second one is a second writer on the shared archive.
N=$(printf '%s' "$LIST" | jq '[.orders[] | select((.exec // "") | test("jsonl-export\\.sh"))] | length')
if [ "$N" != "1" ]; then
    WHO=$(printf '%s' "$LIST" | jq -r '[.orders[] | select((.exec // "") | test("jsonl-export\\.sh")) | .scoped_name] | join(", ")')
    fail "$N order(s) run jsonl-export.sh [$WHO], want exactly 1 (jsonl-export, city scope)"
fi

# 1c. ...and it is the vendored one: city-scoped, enabled, from town-deltas.
printf '%s' "$LIST" | jq -e '
    [.orders[] | select((.exec // "") | test("jsonl-export\\.sh"))][0]
    | .name == "jsonl-export"
      and .scoped_name == "jsonl-export"
      and (.rig == null or .rig == "")
      and .enabled == true
      and ((.source // "") | endswith("packs/town-deltas/orders/jsonl-export.toml"))' >/dev/null \
    || fail "the single jsonl-export.sh order is not jsonl-export / city scope / enabled / packs/town-deltas/orders/jsonl-export.toml: $(printf '%s' "$LIST" | jq -c '[.orders[] | select((.exec // "") | test("jsonl-export\\.sh")) | {name, scoped_name, rig, enabled, source}]')"
log "jsonl-export: exactly 1 instance, city-scoped, from packs/town-deltas"

for want in mol-dog-reaper gate-sweep; do
    printf '%s' "$LIST" | jq -e --arg n "$want" '[.orders[].name] | index($n) != null' >/dev/null \
        || fail "control order '$want' is missing from the order set — the change took out more than the jsonl orders"
done
log "control orders still listed: mol-dog-reaper, gate-sweep"

# ── 2. The tracked config carries the switch (and kept the earlier ones) ─────
python3 - "$CITY/city.toml" <<'PY' || fail "city.toml [orders] skip does not carry mol-dog-jsonl alongside wisp-compact and nudge-on-route (see stderr above)"
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
want = {"wisp-compact", "nudge-on-route", "mol-dog-jsonl"}
if not isinstance(skip, list) or not want.issubset(set(skip)):
    print(f"[orders].skip is {skip!r}, missing {sorted(want - set(skip if isinstance(skip, list) else []))}", file=sys.stderr)
    sys.exit(1)
PY
log "city.toml: [orders] skip contains mol-dog-jsonl (and still wisp-compact, nudge-on-route)"

# ── 3. The replaced override stays removed, the replacement is in place ──────
[ ! -e "$CITY/packs/town-deltas/orders/mol-dog-jsonl.toml" ] \
    || fail "leftover of the replaced override: $CITY/packs/town-deltas/orders/mol-dog-jsonl.toml (skip would switch it off too)"
[ -f "$CITY/packs/town-deltas/orders/jsonl-export.toml" ] \
    || fail "missing the replacement order: $CITY/packs/town-deltas/orders/jsonl-export.toml"
[ -x "$CITY/packs/town-deltas/assets/scripts/jsonl-export.sh" ] \
    || fail "vendored script is missing or not executable: $CITY/packs/town-deltas/assets/scripts/jsonl-export.sh"
log "old override removed; jsonl-export.toml and the vendored script are in place"

log "PASS"
exit 0
