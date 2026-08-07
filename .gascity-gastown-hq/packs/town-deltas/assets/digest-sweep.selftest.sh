#!/usr/bin/env bash
# digest-sweep.selftest.sh — regression harness for digest-sweep.sh (ga-8f40w).
#
# Stubs `bd` entirely (PATH-shadowed) so no real database is touched. Proves
# the acceptance criteria's explicit safety cases: a future-dated title and a
# title with no parseable date must NEVER be closed — a failed/absent parse
# must KEEP, never CLOSE, since closing by mistake destroys information.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts" && pwd)"
SCRIPT="$HERE/digest-sweep.sh"

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== digest-sweep.selftest (ga-8f40w) =="

if [ ! -x "$SCRIPT" ]; then
  echo "FATAL: $SCRIPT not found or not executable"
  exit 1
fi

TODAY="$(date -u +%Y-%m-%d)"
YESTERDAY="$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u -d yesterday +%Y-%m-%d)"
TOMORROW="$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d)"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

CLOSED_LOG="$FIXTURE_DIR/closed.log"
: > "$CLOSED_LOG"

# Stub `bd`: `bd list ...` prints a fixed fixture; `bd close <id> ...` records
# the id instead of touching any real database.
cat > "$FIXTURE_DIR/bd" <<STUB
#!/usr/bin/env bash
case "\$1" in
  list)
    cat "$FIXTURE_DIR/fixture.json"
    ;;
  close)
    echo "\$2" >> "$CLOSED_LOG"
    ;;
  *)
    echo "unexpected bd invocation: \$*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$FIXTURE_DIR/bd"

cat > "$FIXTURE_DIR/fixture.json" <<JSON
[
  {"id": "test-past",      "title": "Digest: $YESTERDAY"},
  {"id": "test-today",     "title": "Digest: $TODAY"},
  {"id": "test-future",    "title": "Digest: $TOMORROW"},
  {"id": "test-nodate",    "title": "Digest"},
  {"id": "test-malformed", "title": "Digest: not-a-date"},
  {"id": "test-unrelated", "title": "Some other bead mentioning digest"}
]
JSON

PATH="$FIXTURE_DIR:$PATH" "$SCRIPT"
RC=$?
[ "$RC" -eq 0 ] && ok "script exits 0" || bad "script exited $RC"

CLOSED="$(cat "$CLOSED_LOG")"

echo "-- past-day digest --"
echo "$CLOSED" | grep -qx "test-past" \
  && ok "past-day digest closed" \
  || bad "past-day digest NOT closed (expected close)"

echo "-- today's digest must stay open (não esconder o de hoje) --"
echo "$CLOSED" | grep -qx "test-today" \
  && bad "today's digest was closed (must stay open)" \
  || ok "today's digest left open"

echo "-- future-dated digest must stay open --"
echo "$CLOSED" | grep -qx "test-future" \
  && bad "future-dated digest was closed (date-parse safety violated)" \
  || ok "future-dated digest left open"

echo "-- no-date title must stay open --"
echo "$CLOSED" | grep -qx "test-nodate" \
  && bad "no-date-titled bead was closed (date-parse safety violated)" \
  || ok "no-date-titled bead left open"

echo "-- malformed-date title must stay open --"
echo "$CLOSED" | grep -qx "test-malformed" \
  && bad "malformed-date bead was closed (date-parse safety violated)" \
  || ok "malformed-date bead left open"

echo "-- unrelated title must stay open --"
echo "$CLOSED" | grep -qx "test-unrelated" \
  && bad "unrelated bead was closed (title match too loose)" \
  || ok "unrelated bead left open"

echo "-- exactly one bead closed this run --"
N=$(printf '%s\n' "$CLOSED" | grep -c . || true)
[ "$N" -eq 1 ] && ok "exactly 1 bead closed (only the past-day one)" || bad "expected exactly 1 close, got $N: $CLOSED"

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
