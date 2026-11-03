#!/usr/bin/env bash
# prod-tests/gascity/story-ga-7sxdmb.sh — verify ga-7sxdmb (and, since ga-ki02nmt, where the export runs from): the JSONL export has exactly ONE
# writer on the shared archive, it is the vendored script that carries the partial-export guards, and no order at any scope still resolves to the
# maintenance pack's stale copy.
#
# STATE SINCE ga-ki02nmt (2026-11-03): the writer is the launchd job com.gascity.jsonl-export (every 15 min, same script, same 840 s timeout), NOT a gc
# order. The engine dispatcher serves ~1.16 order runs/min against ~14.7 asked, so an order every 15 min really ran every ~35 min or worse and the RPO
# of the beads backup depended on that cap. So `jsonl-export` and `jsonl-hourly-offsite` are in city.toml [orders] skip (the SAME deploy as the plists:
# the exporter has no lock, two writers on one archive is the failure this test exists for), and the order files stay in the repo as the source of
# the timeout/interval that scripts/jsonl-launchd-plists.selftest.sh holds the plists to.
#
# Why this asserts on the LIVE order set and not only on git: the town-deltas same-name
# override of mol-dog-jsonl (ga-gtrc8n, ga-fxrrav) only shadowed the CITY-scoped instance.
# The maintenance pack's builtin order also registers one instance PER RIG, and those five
# kept running the builtin script — the one WITHOUT the ga-fxrrav fix — into the shared
# packs/maintenance/jsonl-archive: a truncated export was committed as the snapshot, and the
# next complete export read as a growth spike ("JSONL spike detected [HIGH]", WA 3430 -> 505
# -> 5425 on 2026-09-26). `gc order list --json` is what the controller schedules from.
#
# Three-state on purpose: "gc could not list" must FAIL, never read as "zero instances"; "launchctl could not tell" must FAIL, never read as "loaded".
# So we also require ok:true and that well-known control orders are still listed (a broken
# city.toml would otherwise look like a clean removal).
#
# GC_CITY overrides the city dir (lets this test run against a scratch city). The launchd leg is host-global (one label per host, pointing at the real
# city), so it only runs for the real city; a scratch run says so in the log.

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

# 1b. The class, not the name: whatever an order is called and wherever it is scoped, NO order runs a jsonl-export.sh any more (the launchd job does,
#     see 1c) — a second one is a second writer on the shared archive, and the exporter has no single-flight lock to stop it.
#     vazio (0 orders) → é o estado ESPERADO desde o ga-ki02nmt, não um erro; lista ilegível já falhou acima (ok:true exigido), nunca vira "0".
N=$(printf '%s' "$LIST" | jq '[.orders[] | select((.exec // "") | test("jsonl-export\\.sh"))] | length')
if [ "$N" != "0" ]; then
    WHO=$(printf '%s' "$LIST" | jq -r '[.orders[] | select((.exec // "") | test("jsonl-export\\.sh")) | .scoped_name] | join(", ")')
    fail "$N order(s) run jsonl-export.sh [$WHO], want 0: the exporter runs from launchd (com.gascity.jsonl-export) and has no lock, an order on top of it is a second writer — add the name to city.toml [orders] skip"
fi
log "jsonl-export.sh: 0 orders at any scope (the launchd job is the single writer)"

# 1b'. The upload half the same way: the order is off, its launchd twin runs it. (jsonl-hourly-offsite HAS a lock, so this one is about the cadence
#      being the plist's, not about corruption.) The -age alarm order is NOT replaced and must stay listed.
for gone in jsonl-export jsonl-hourly-offsite; do
    printf '%s' "$LIST" | jq -e --arg n "$gone" '[.orders[] | select(.name == $n)] | length == 0' >/dev/null \
        || fail "order '$gone' is still listed by gc order list: its launchd job runs it now, add \"$gone\" to city.toml [orders] skip"
done
printf '%s' "$LIST" | jq -e '[.orders[].name] | index("jsonl-hourly-offsite-age") != null' >/dev/null \
    || fail "order 'jsonl-hourly-offsite-age' (the S3 age alarm) is missing from the order set — the skip took out more than the two replaced orders"
log "orders jsonl-export and jsonl-hourly-offsite: not listed (skipped); jsonl-hourly-offsite-age still listed"

# 1c. ...and the launchd job that replaced them is LOADED and points at the vendored script of THIS city (skip live + plist missing = no exports at all).
#     launchctl ausente / label não carregada / saída ilegível → FALHA ("não sei" nunca vira "carregada"); só o city real tem o label (um por host).
_launchd_job() {   # <label> <script-name>
    local label="$1" script="$2" out
    command -v launchctl >/dev/null 2>&1 || fail "launchctl not found: cannot tell whether $label is loaded"
    out=$(launchctl print "gui/$(id -u)/$label" 2>&1) \
        || fail "$label is NOT loaded in gui/$(id -u) ($(printf '%s' "$out" | head -1)) — the order is skipped and nothing runs the job: install ~/Library/LaunchAgents/$label.plist and launchctl bootstrap it (docs/runbooks/jsonl-launchd-cutover.md)"
    printf '%s\n' "$out" | grep -q "state = " \
        || fail "launchctl print $label returned no 'state =' line: cannot tell whether it is loaded"
    printf '%s\n' "$out" | grep -qF "$CITY/packs/town-deltas/assets/scripts/$script" \
        || fail "$label is loaded but its arguments do not run $CITY/packs/town-deltas/assets/scripts/$script: $(printf '%s\n' "$out" | grep -A6 'arguments = ' | tr '\n' ' ')"
    log "$label: loaded, runs $CITY/packs/town-deltas/assets/scripts/$script"
}
if [ "$CITY" = "/Users/athos/gt/.gascity-gastown-hq" ]; then
    _launchd_job com.gascity.jsonl-export jsonl-export.sh
    _launchd_job com.gascity.jsonl-hourly-offsite jsonl-hourly-offsite.sh
else
    log "scratch city ($CITY): launchd leg not checked (the labels belong to the real city)"
fi

for want in mol-dog-reaper gate-sweep; do
    printf '%s' "$LIST" | jq -e --arg n "$want" '[.orders[].name] | index($n) != null' >/dev/null \
        || fail "control order '$want' is missing from the order set — the change took out more than the jsonl orders"
done
log "control orders still listed: mol-dog-reaper, gate-sweep"

# ── 2. The tracked config carries the switch (and kept the earlier ones) ─────
python3 - "$CITY/city.toml" <<'PY' || fail "city.toml [orders] skip does not carry mol-dog-jsonl, jsonl-export and jsonl-hourly-offsite alongside wisp-compact and nudge-on-route (see stderr above)"
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
want = {"wisp-compact", "nudge-on-route", "mol-dog-jsonl", "jsonl-export", "jsonl-hourly-offsite"}
if not isinstance(skip, list) or not want.issubset(set(skip)):
    print(f"[orders].skip is {skip!r}, missing {sorted(want - set(skip if isinstance(skip, list) else []))}", file=sys.stderr)
    sys.exit(1)
PY
log "city.toml: [orders] skip contains mol-dog-jsonl, jsonl-export, jsonl-hourly-offsite (and still wisp-compact, nudge-on-route)"

# ── 3. The replaced override stays removed, the replacement is in place ──────
[ ! -e "$CITY/packs/town-deltas/orders/mol-dog-jsonl.toml" ] \
    || fail "leftover of the replaced override: $CITY/packs/town-deltas/orders/mol-dog-jsonl.toml (skip would switch it off too)"
# the skipped order file stays: it is the single source of the timeout/interval the plist copies (scripts/jsonl-launchd-plists.selftest.sh reads it)
[ -f "$CITY/packs/town-deltas/orders/jsonl-export.toml" ] \
    || fail "missing the order file the plist's timeout/interval is held to: $CITY/packs/town-deltas/orders/jsonl-export.toml"
[ -x "$CITY/packs/town-deltas/assets/scripts/jsonl-export.sh" ] \
    || fail "vendored script is missing or not executable: $CITY/packs/town-deltas/assets/scripts/jsonl-export.sh"
log "old override removed; jsonl-export.toml (skipped, source of the plist numbers) and the vendored script are in place"

log "PASS"
exit 0
