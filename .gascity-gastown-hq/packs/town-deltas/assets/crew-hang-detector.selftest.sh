#!/usr/bin/env bash
# crew-hang-detector.selftest.sh — hermetic test for crew-hang-detector.sh (ga-khuz1).
#
# Stubs `gc` with a fixture-driven shim so NO real session is ever nudged/killed.
# Drives the detector through every decision branch and asserts the actions it
# would take (recorded by the shim). Exits 0 on PASS, non-zero on first failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$HERE/crew-hang-detector.sh"
[ -f "$DETECTOR" ] || { echo "FAIL: detector not found at $DETECTOR" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  ok: $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHIM_DIR="$WORK/bin"
ACTIONS="$WORK/actions.log"
FIXTURE="$WORK/sessions.json"
WARRANTS="$WORK/warrants.json"
mkdir -p "$SHIM_DIR"
: > "$ACTIONS"
echo "[]" > "$WARRANTS"

# ── gc shim ───────────────────────────────────────────────────────────────────
cat > "$SHIM_DIR/gc" <<SHIM
#!/usr/bin/env bash
# Fixture-driven gc stub. Records mutating calls to \$ACTIONS.
case "\$1 \$2" in
  "session list")  cat "$FIXTURE" ;;
  "bd list")       cat "$WARRANTS" ;;
  "bd create")     echo "create \$*" >> "$ACTIONS"; echo "ga-fakewarrant" ;;
  "session nudge") echo "nudge \$3" >> "$ACTIONS" ;;
  *)               : ;;
esac
exit 0
SHIM
chmod +x "$SHIM_DIR/gc"

# Fixture builder: emits a sessions JSON with last_active = now - <age> seconds.
# Usage: add_session <name> <template> <state> <attached> <age_seconds>
build_fixture() {
    AGES_SPEC="$1" python3 - "$FIXTURE" <<'PY'
import json, sys, os, datetime
out = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
sessions = []
for row in os.environ["AGES_SPEC"].strip().splitlines():
    row = row.strip()
    if not row:
        continue
    name, tmpl, state, attached, age = row.split("|")
    la = (now - datetime.timedelta(seconds=int(age))).astimezone().isoformat(timespec="seconds")
    sessions.append({
        "name": name, "template": tmpl, "state": state,
        "attached": attached == "true", "last_active": la,
    })
with open(out, "w") as f:
    json.dump({"sessions": sessions}, f)
PY
}

run() {  # run the detector with the shim on PATH, fresh state dir
    local city="$WORK/city"
    rm -rf "$city"; mkdir -p "$city/.gc/state"
    GC_CITY_PATH="$city" PATH="$SHIM_DIR:$PATH" \
        STALE_SEC=600 ESCALATE_SEC=1200 DRY_RUN=0 \
        bash "$DETECTOR" >/dev/null 2>&1
    echo "$city"
}

echo "== test 1: healthy + idle crew (fresh heartbeat) -> no action =="
build_fixture "mila-wa|mila-wa|active|false|30
thies-wa|thies-wa|active|false|90"
: > "$ACTIONS"; run >/dev/null
if [ ! -s "$ACTIONS" ]; then ok "no nudge/warrant for fresh crew"; else bad "acted on healthy crew: $(cat "$ACTIONS")"; fi

echo "== test 2: crew frozen between STALE and ESCALATE -> nudge only =="
build_fixture "thies-wa|thies-wa|active|false|800"
: > "$ACTIONS"; run >/dev/null
if grep -qx "nudge thies-wa" "$ACTIONS" && ! grep -q "^create" "$ACTIONS"; then ok "nudged, no warrant"; else bad "expected nudge-only, got: $(cat "$ACTIONS")"; fi

echo "== test 3: crew frozen past ESCALATE -> warrant, no nudge =="
build_fixture "thies-wa|thies-wa|active|false|1500"
: > "$ACTIONS"; run >/dev/null
if grep -q "^create" "$ACTIONS" && grep -q '"target":"thies-wa"' "$ACTIONS" && ! grep -q "^nudge" "$ACTIONS"; then ok "warrant filed with correct target"; else bad "expected warrant, got: $(cat "$ACTIONS")"; fi

echo "== test 4: warrant routed to dog pool + label =="
if grep -q "label=warrant" "$ACTIONS" && grep -q '"gc.routed_to":"gastown.dog"' "$ACTIONS"; then ok "warrant has --label=warrant + routed_to dog"; else bad "warrant metadata wrong: $(cat "$ACTIONS")"; fi

echo "== test 5: pool dog frozen -> ignored (not crew) =="
build_fixture "gastown.dog-3|gastown.dog|active|false|3000"
: > "$ACTIONS"; run >/dev/null
if [ ! -s "$ACTIONS" ]; then ok "pool dog ignored"; else bad "acted on pool dog: $(cat "$ACTIONS")"; fi

echo "== test 6: polecat frozen -> ignored (witness covers) =="
build_fixture "property_scrapers/claude-adhoc-x|property_scrapers/claude|active|false|3000"
: > "$ACTIONS"; run >/dev/null
if [ ! -s "$ACTIONS" ]; then ok "polecat ignored"; else bad "acted on polecat: $(cat "$ACTIONS")"; fi

echo "== test 7: human-attached frozen -> ignored =="
build_fixture "gastown.mayor|gastown.mayor|active|true|3000"
: > "$ACTIONS"; run >/dev/null
if [ ! -s "$ACTIONS" ]; then ok "attached session ignored"; else bad "acted on attached: $(cat "$ACTIONS")"; fi

echo "== test 8: dedup — open warrant exists -> no new warrant =="
build_fixture "thies-wa|thies-wa|active|false|1500"
echo '[{"id":"ga-w1","metadata":{"target":"thies-wa"}}]' > "$WARRANTS"
: > "$ACTIONS"; run >/dev/null
if ! grep -q "^create" "$ACTIONS"; then ok "no duplicate warrant when one is open"; else bad "filed duplicate warrant: $(cat "$ACTIONS")"; fi
echo "[]" > "$WARRANTS"

echo "== test 9: asleep crew -> ignored =="
build_fixture "thies-wa|thies-wa|asleep|false|9000"
: > "$ACTIONS"; run >/dev/null
if [ ! -s "$ACTIONS" ]; then ok "asleep session ignored"; else bad "acted on asleep: $(cat "$ACTIONS")"; fi

echo "== test 10: startup marker written =="
build_fixture "mila-wa|mila-wa|active|false|30"
city="$(run)"
if [ -s "$city/.gc/state/crew-hang-detector.startup" ]; then ok "startup marker written"; else bad "no startup marker"; fi

echo "== test 11: kill-switch -> no action even on a hung crew =="
city="$WORK/city"; rm -rf "$city"; mkdir -p "$city/.gc/state"; touch "$city/.gc/state/crew-hang-detector.disabled"
build_fixture "thies-wa|thies-wa|active|false|5000"
: > "$ACTIONS"
GC_CITY_PATH="$city" PATH="$SHIM_DIR:$PATH" STALE_SEC=600 ESCALATE_SEC=1200 DRY_RUN=0 bash "$DETECTOR" >/dev/null 2>&1
if [ ! -s "$ACTIONS" ]; then ok "kill-switch suppressed all action"; else bad "acted despite kill-switch: $(cat "$ACTIONS")"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
