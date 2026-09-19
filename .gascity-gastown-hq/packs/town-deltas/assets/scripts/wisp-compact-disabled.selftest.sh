#!/usr/bin/env bash
# wisp-compact-disabled.selftest.sh — ga-5mu653 regression guard.
#
# The `wisp-compact` order must stay OFF at EVERY scope until a replacement
# retention design exists (wisp retention is the mol-dog-reaper SQL purge,
# ga-u8nbt9). What this pins, and why each piece is what it is:
#
#   1. city.toml carries [orders] skip = [... "wisp-compact" ...].
#      A town-deltas override/tombstone is NOT enough: the maintenance pack's
#      builtin order registers one instance PER RIG, and a same-name override
#      only shadows the city-scoped one (measured 2026-09-19: 7 live instances,
#      6 of them rig-scoped and registered from the builtin script, which has no
#      mail carve-out). `skip` excludes the name at every scope.
#   2. The vendored override + script stay gone. A leftover override would look
#      like the order is still curated while `skip` silently hides it.
#
# The checker is three-state on purpose (skipped / NOT skipped / cannot tell):
# an unreadable or unparseable city.toml must FAIL, never read as "fine".
# Section A proves the checker itself against fixtures (so it cannot pass
# vacuously); section B applies it to the real tree.
#
# Hermetic: tracked files only; needs no gc, no bd, no Dolt.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts -> assets -> town-deltas -> packs -> <city dir>
CITY_DIR="$(cd "$SELF_DIR/../../../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wisp-compact-disabled-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# city_skips_wisp_compact <city.toml>
#   exit 0 = wisp-compact is in [orders].skip
#   exit 1 = readable, valid, and NOT skipped
#   exit 2 = cannot tell (missing/unreadable/invalid TOML, no tomllib, skip not a list)
city_skips_wisp_compact() {
  python3 - "$1" <<'PY'
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        cfg = tomllib.load(f)
except Exception as e:   # includes ImportError: no tomllib must NOT read as "not skipped"
    print(f"cannot read/parse {sys.argv[1]}: {e}", file=sys.stderr)
    sys.exit(2)
orders = cfg.get("orders", {})
skip = orders.get("skip", []) if isinstance(orders, dict) else None
if not isinstance(skip, list):
    print("[orders].skip is not a list", file=sys.stderr)
    sys.exit(2)
sys.exit(0 if "wisp-compact" in skip else 1)
PY
}

expect_rc() {  # label want_rc file
  local label="$1" want="$2" file="$3" got
  city_skips_wisp_compact "$file" 2>/dev/null
  got=$?
  [ "$got" -eq "$want" ] && ok "checker: $label -> rc=$got" \
                         || bad "checker: $label -> rc=$got (wanted $want)"
}

echo "wisp-compact-disabled.selftest (ga-5mu653)"
echo ""
echo "-- A. the checker itself (fixtures) --"

printf '[orders]\nskip = ["wisp-compact"]\n' > "$WORK/skips.toml"
expect_rc "skip = [wisp-compact]" 0 "$WORK/skips.toml"

printf '[orders]\nskip = ["something-else", "wisp-compact"]\n' > "$WORK/skips-among-others.toml"
expect_rc "wisp-compact among other names" 0 "$WORK/skips-among-others.toml"

printf '[workspace]\nname = "x"\n' > "$WORK/no-orders.toml"
expect_rc "no [orders] table at all" 1 "$WORK/no-orders.toml"

printf '[orders]\nskip = ["something-else"]\n' > "$WORK/other-skip.toml"
expect_rc "skip lists a different order" 1 "$WORK/other-skip.toml"

printf '[[orders.overrides]]\nname = "wisp-compact"\nenabled = false\n' > "$WORK/override-only.toml"
expect_rc "an [[orders.overrides]] entry alone is NOT skip (city-scope only)" 1 "$WORK/override-only.toml"

printf 'this is = = not toml\n' > "$WORK/garbage.toml"
expect_rc "invalid TOML is 'cannot tell', not 'not skipped'" 2 "$WORK/garbage.toml"

expect_rc "missing file is 'cannot tell'" 2 "$WORK/does-not-exist.toml"

printf '[orders]\nskip = "wisp-compact"\n' > "$WORK/scalar.toml"
expect_rc "skip as a bare string is 'cannot tell' (no substring match)" 2 "$WORK/scalar.toml"

echo ""
echo "-- B. the real tree ($CITY_DIR) --"

city_skips_wisp_compact "$CITY_DIR/city.toml"
rc=$?
case "$rc" in
  0) ok "city.toml has [orders] skip containing \"wisp-compact\"" ;;
  1) bad "city.toml does NOT skip wisp-compact — the per-rig builtin instances would run again (ga-5mu653)" ;;
  *) bad "cannot determine whether city.toml skips wisp-compact (rc=$rc)" ;;
esac

for rel in packs/town-deltas/orders/wisp-compact.toml \
           packs/town-deltas/assets/scripts/wisp-compact.sh; do
  if [ -e "$CITY_DIR/$rel" ]; then
    bad "leftover of the removed order: $rel (ga-5mu653)"
  else
    ok "removed and stays removed: $rel"
  fi
done

echo ""
echo "wisp-compact-disabled.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
