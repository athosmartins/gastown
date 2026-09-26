#!/usr/bin/env bash
# prod-tests/gascity/story-ga-e6ottw.sh — verify ga-e6ottw: orphan-sweep, mol-dog-reaper and
# order-tracking-sweep each run ONCE, city-scoped, from packs/town-deltas — and no rig-scoped
# instance still runs the maintenance pack's older builtin copy.
#
# Why this asserts on the LIVE order set and not only on git: a town-deltas same-name file
# (orders/<name>.toml) only shadows the CITY-scoped instance. The maintenance pack registers
# the same order once PER RIG, and those five kept running the builtin. In these three the work
# does not depend on the scope that fired it (orphan-sweep walks HQ + every rig itself; the
# reaper is SQL over SHOW DATABASES; `gc order sweep-tracking` sweeps every store), so a rig
# instance is a redundant run of a worse script — orphan-sweep's builtin resets a claim on one
# snapshot, with none of the ga-u0vzx / ga-kq4jf / ga-114ll / ga-f6igb protection.
# `gc order list --json` is what the controller schedules from.
#
# The fix is `[[orders.overrides]]` in city.toml: `rig = "*"` + enabled = false, then a city-scope
# block that switches the city instance back on. Overrides apply IN FILE ORDER, so the reverse
# order would leave NO instance at all — the listing check below fails on that, and so does the
# static replay of city.toml (section 3), which needs no running gc.
#
# gate-sweep is the deliberate exception: `bd gate check` acts on the store of the scope that
# fired it, so its rig instances poll different stores and must stay. Section 1d pins that.
#
# Three-state on purpose: "gc could not list" must FAIL, never read as "zero instances". So we
# also require ok:true and that well-known control orders are still listed (a broken city.toml
# would otherwise look like a clean removal).
#
# What it catches that `gc config show --validate` does not: that command says "Config valid."
# for an [[orders.overrides]] block that matches no order (measured 26/09); only `gc order
# list/show/run` fail. story-delivery.sh runs this once, at delivery (via run.sh with STORY_ID);
# nothing re-runs it, so run it by hand after every gc upgrade and every change to the
# maintenance pack's orders.
#
# GC_CITY overrides the city dir (lets this test run against a scratch city).

set -euo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"

log()  { echo "[prod-test:ga-e6ottw] $*"; }
fail() { echo "[prod-test:ga-e6ottw] FAIL: $*" >&2; exit 1; }

# name | exec fragment that identifies the WORK, whatever the order is called or wherever scoped
ORDERS="orphan-sweep|orphan-sweep\\.sh
mol-dog-reaper|scripts/reaper\\.sh
order-tracking-sweep|order sweep-tracking"

# ── 1. The live order set ────────────────────────────────────────────────────
LIST=""
LIST_ERR=""
ERRF=$(mktemp "${TMPDIR:-/tmp}/story-ga-e6ottw.XXXXXX")
trap 'rm -f "$ERRF"' EXIT
for attempt in 1 2 3; do
    if LIST=$(gc --city "$CITY" order list --json 2>"$ERRF") \
       && printf '%s' "$LIST" | jq -e '.ok == true and (.orders | type == "array")' >/dev/null 2>&1; then
        break
    fi
    LIST=""
    LIST_ERR=$(grep -v '^warning: builtin' "$ERRF" | head -c 600 || true)
    case "$LIST_ERR" in *orders.overrides*) break ;; esac   # deterministic config error: a retry changes nothing
    [ "$attempt" -lt 3 ] || break
    log "gc order list attempt $attempt failed; retrying"
    sleep 5
done
if [ -z "$LIST" ]; then
    # gc's own reason is kept: a config error is deterministic and says exactly what is wrong
    # (`orders.overrides[N]: order "<name>" not found ...` = a [[orders.overrides]] block in
    # city.toml matches no order, which `gc config show --validate` does NOT flag).
    case "$LIST_ERR" in
        *orders.overrides*) fail "gc order list rejects city.toml [[orders.overrides]] — a block matches no order (upstream renamed/dropped one, or a rig was removed); the overrides after the first unmatched one may not be applied by the controller. gc said: $LIST_ERR" ;;
    esac
    fail "could not list orders after 3 attempts — cannot count instances, NOT treating it as zero. gc said: ${LIST_ERR:-<nothing on stderr>}"
fi

while IFS='|' read -r NAME EXECRE; do
    [ -n "$NAME" ] || continue

    # 1a. Exactly ONE instance of the name is active. `.enabled != false` counts an instance whose
    #     enabled flag is absent as active: an unreadable flag must not read as "switched off".
    N=$(printf '%s' "$LIST" | jq --arg n "$NAME" '[.orders[] | select(.name == $n and (.enabled != false))] | length')
    if [ "$N" != "1" ]; then
        WHO=$(printf '%s' "$LIST" | jq -r --arg n "$NAME" '[.orders[] | select(.name == $n and (.enabled != false)) | .scoped_name] | join(", ")')
        fail "$NAME: $N active instance(s) [${WHO:-none}], want exactly 1 (city scope) — a same-name file override does not reach the per-rig builtin instances; [[orders.overrides]] rig = \"*\" does, and the city block after it must switch the city instance back on"
    fi

    # 1b. ...and it is the town-deltas one: city-scoped, enabled, from packs/town-deltas.
    printf '%s' "$LIST" | jq -e --arg n "$NAME" '
        [.orders[] | select(.name == $n and (.enabled != false))][0]
        | .scoped_name == $n
          and (.rig == null or .rig == "")
          and .enabled == true
          and ((.source // "") | endswith("packs/town-deltas/orders/" + $n + ".toml"))' >/dev/null \
        || fail "$NAME: the single active instance is not city scope / enabled / packs/town-deltas/orders/$NAME.toml: $(printf '%s' "$LIST" | jq -c --arg n "$NAME" '[.orders[] | select(.name == $n and (.enabled != false)) | {name, scoped_name, rig, enabled, source}]')"

    # 1c. The class, not the name: whatever an order is called, exactly one active order runs this
    #     work — a second one is a second writer (orphan-sweep resets claims, the reaper purges).
    N=$(printf '%s' "$LIST" | jq --arg re "$EXECRE" '[.orders[] | select(.enabled != false and ((.exec // "") | test($re)))] | length')
    if [ "$N" != "1" ]; then
        WHO=$(printf '%s' "$LIST" | jq -r --arg re "$EXECRE" '[.orders[] | select(.enabled != false and ((.exec // "") | test($re))) | .scoped_name] | join(", ")')
        fail "$N active order(s) run '$EXECRE' [${WHO:-none}], want exactly 1 ($NAME, city scope)"
    fi
    log "$NAME: exactly 1 active instance, city-scoped, from packs/town-deltas"
done <<EOF_ORDERS
$ORDERS
EOF_ORDERS

# 1d. gate-sweep is the DELIBERATE exception and must stay per-scope: `bd gate check` polls the
#     store of the scope that fired it, so a rig instance is the only thing that evaluates that
#     rig's gates. Switching it off with the three above would silently stop rig gate evaluation.
printf '%s' "$LIST" | jq -e '
    [.orders[] | select(.name == "gate-sweep" and .enabled == true)] as $g
    | ([$g[] | select(.rig == null or .rig == "")] | length) == 1
      and ([$g[] | select(.rig != null and .rig != "")] | length) >= 1' >/dev/null \
    || fail "gate-sweep must keep its city instance AND its rig instances (store-bound): $(printf '%s' "$LIST" | jq -c '[.orders[] | select(.name == "gate-sweep") | {scoped_name, enabled}]')"
log "gate-sweep: city + rig instances still active (store-bound, left alone on purpose)"

for want in beads-health prune-branches; do
    printf '%s' "$LIST" | jq -e --arg n "$want" '[.orders[].name] | index($n) != null' >/dev/null \
        || fail "control order '$want' is missing from the order set — the change took out more than the three orders"
done
log "control orders still listed: beads-health, prune-branches"

# ── 2. The plain-file override stays (the city instance still needs it) ──────
for n in orphan-sweep mol-dog-reaper order-tracking-sweep; do
    [ -f "$CITY/packs/town-deltas/orders/$n.toml" ] \
        || fail "the town-deltas override $CITY/packs/town-deltas/orders/$n.toml is gone — the city instance would fall back to the builtin"
done
log "town-deltas order files for the three orders are in place"

# ── 3. Static replay of the tracked config, no running gc needed ─────────────
# Applies [[orders.overrides]] in FILE ORDER the way the engine does (orders.ApplyOverrides):
# rig = "*" matches the city instance and every rig instance, no rig matches the city instance
# only. Final state must be: city ON, rig instances OFF — and it must still be after any later
# override of the same name.
python3 - "$CITY/city.toml" <<'PY' || fail "city.toml [[orders.overrides]] does not leave the city instance ON and the rig instances OFF for the three orders (see stderr above)"
import sys
try:
    import tomllib
except ImportError:         # python3 < 3.11: say so, not "cannot parse city.toml"
    print(f"python3 {sys.version.split()[0]} has no tomllib (needs >= 3.11): cannot replay {sys.argv[1]}", file=sys.stderr)
    sys.exit(2)
try:
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:      # cannot tell must fail, not pass
    print(f"cannot read/parse {sys.argv[1]}: {e}", file=sys.stderr)
    sys.exit(2)
orders = cfg.get("orders", {})
ovs = orders.get("overrides", []) if isinstance(orders, dict) else []
if not isinstance(ovs, list):
    print(f"[orders].overrides is {type(ovs).__name__}, want a list", file=sys.stderr)
    sys.exit(2)
bad = []
for name in ("orphan-sweep", "mol-dog-reaper", "order-tracking-sweep"):
    city, rigs, named_on = True, True, set()    # the maintenance pack ships every instance ON
    for ov in ovs:
        if not isinstance(ov, dict) or ov.get("name") != name or "enabled" not in ov:
            continue
        which = ov.get("rig", "")
        if which == "*":
            city, rigs, named_on = ov["enabled"], ov["enabled"], set()
        elif which == "":
            city = ov["enabled"]
        elif ov["enabled"]:
            named_on.add(which)         # one rig switched back on by name: it runs the builtin again
        else:
            named_on.discard(which)
    if city is not True or rigs is not False or named_on:
        bad.append(f"{name}: city={city} rigs={rigs} rigs-on-by-name={sorted(named_on)} (want city=True rigs=False, none by name)")
if bad:
    print("; ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
log "city.toml: overrides replay to city ON / rig OFF for the three orders"

log "PASS"
exit 0
