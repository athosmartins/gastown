#!/usr/bin/env bash
# crew-hang-detector.selftest.sh — hermetic test for crew-hang-detector.sh
# (ga-khuz1 origin; reworked under ga-6i82w / ga-yqcdj).
#
# Stubs `gc` (session list / session peek / bd list / bd create / session nudge)
# and `notify` with fixture-driven shims so NO real session is ever nudged/killed
# and no real notification fires. Drives the detector through every decision
# branch and asserts the actions it would take (recorded by the shims). Exits 0
# on PASS, non-zero on first failure.
#
# The hang signal is a pane that is in the ACTIVE-WORK state AND byte-frozen
# across passes. Wall-clock freeze age cannot be faked in one process, so the
# threshold branches are tested by running pass 1 (which records the fingerprint
# and a first-seen epoch), backdating that epoch in the state file, then running
# pass 2 with the SAME pane fixture (same fingerprint = still frozen).

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
PANES_DIR="$WORK/panes"
mkdir -p "$SHIM_DIR" "$PANES_DIR"
: > "$ACTIONS"
echo "[]" > "$WARRANTS"

# ── gc shim ───────────────────────────────────────────────────────────────────
# session peek <name> --lines N -> cat $PANES_DIR/<name> (empty if absent).
cat > "$SHIM_DIR/gc" <<SHIM
#!/usr/bin/env bash
case "\$1 \$2" in
  "session list")  cat "$FIXTURE" ;;
  "session peek")  pf="$PANES_DIR/\$3"; [ -f "\$pf" ] && cat "\$pf" ;;
  "bd list")       cat "$WARRANTS" ;;
  "bd create")     echo "create \$*" >> "$ACTIONS"; echo "ga-fakewarrant" ;;
  "session nudge") echo "nudge \$3" >> "$ACTIONS" ;;
  *)               : ;;
esac
exit 0
SHIM
chmod +x "$SHIM_DIR/gc"

# ── notify shim (records the human-alert branch) ──────────────────────────────
cat > "$SHIM_DIR/notify" <<SHIM
#!/usr/bin/env bash
echo "notify \$*" >> "$ACTIONS"
exit 0
SHIM
chmod +x "$SHIM_DIR/notify"

# Active-work spinner pane (frozen frame): ellipsis + parenthesized elapsed.
ACTIVE_PANE_A=$'  some tool output line\n✳ Gitifying… (15m 49s · ↓ 61.3k tokens)\n❯ \n  [Opus] ctx: 10%'
# A DIFFERENT active-work frame (timer advanced) — used for the progressing test.
ACTIVE_PANE_B=$'  some tool output line\n✳ Gitifying… (21m 03s · ↓ 72.1k tokens)\n❯ \n  [Opus] ctx: 11%'
# Idle pane: past-tense summary, no spinner/elapsed.
IDLE_PANE=$'✻ Cooked for 6s\n────────\n❯ \n  [Opus] ctx: 10%'

set_pane()  { mkdir -p "$(dirname "$PANES_DIR/$1")"; printf '%s' "$2" > "$PANES_DIR/$1"; }
clear_panes() { rm -rf "$PANES_DIR"; mkdir -p "$PANES_DIR"; }

# Fixture builder: spec rows "name|tmpl|state|attached".
build_fixture() {
    AGES_SPEC="$1" python3 - "$FIXTURE" <<'PY'
import json, sys, os
out = sys.argv[1]
sessions = []
for row in os.environ["AGES_SPEC"].strip().splitlines():
    row = row.strip()
    if not row:
        continue
    name, tmpl, state, attached = row.split("|")
    sessions.append({
        "name": name, "template": tmpl, "state": state,
        "attached": attached == "true",
    })
with open(out, "w") as f:
    json.dump({"sessions": sessions}, f)
PY
}

fresh_city() {  # echo a clean city path
    local city="$WORK/city"
    rm -rf "$city"; mkdir -p "$city/.gc/state"
    echo "$city"
}

# Run one detector pass against an existing city (state preserved across calls).
pass() {  # pass <city> [extra env assignments...]
    local city="$1"; shift
    env GC_CITY_PATH="$city" PATH="$SHIM_DIR:$PATH" \
        STALE_SEC=600 ESCALATE_SEC=1200 DRY_RUN=0 PEEK_LINES=40 "$@" \
        bash "$DETECTOR" >/dev/null 2>&1
}

# Backdate the first-seen epoch in a session's state file by N seconds.
backdate() {  # backdate <city> <name> <seconds_ago>
    local sf="$1/.gc/state/crew-hang/$2"; local secs="$3"
    [ -f "$sf" ] || { echo "(no state file to backdate: $sf)" >&2; return 1; }
    local fp; fp="$(sed -n 1p "$sf")"
    local nudged; nudged="$(sed -n 3p "$sf")"
    local escalated; escalated="$(sed -n 4p "$sf")"
    printf '%s\n%s\n%s\n%s\n' "$fp" "$(( $(date +%s) - secs ))" "${nudged:-0}" "${escalated:-0}" > "$sf"
}

echo "== test 1: idle crew (no spinner) -> no action, even across two passes =="
build_fixture "mila-wa|mila-wa|active|false
thies-wa|thies-wa|active|false"
clear_panes; set_pane mila-wa "$IDLE_PANE"; set_pane thies-wa "$IDLE_PANE"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"; pass "$city"
if [ ! -s "$ACTIONS" ]; then ok "no nudge/warrant for idle crew"; else bad "acted on idle crew: $(cat "$ACTIONS")"; fi

echo "== test 2: active + progressing (pane changes) -> no action even if backdated =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"                       # records fp(A)
backdate "$city" thies-wa 1300     # pretend it has been there a while
set_pane thies-wa "$ACTIVE_PANE_B" # ...but the pane advanced (live turn)
pass "$city"
if [ ! -s "$ACTIONS" ]; then ok "progressing active turn not flagged"; else bad "acted on progressing turn: $(cat "$ACTIONS")"; fi

echo "== test 3: active + frozen between STALE and ESCALATE -> nudge only =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"                       # first seen (no action)
if [ -s "$ACTIONS" ]; then bad "acted on first observation: $(cat "$ACTIONS")"; else ok "first observation takes no action"; fi
backdate "$city" thies-wa 700      # frozen 700s (>STALE 600, <ESCALATE 1200)
: > "$ACTIONS"; pass "$city"
if grep -qx "nudge thies-wa" "$ACTIONS" && ! grep -q "^create" "$ACTIONS"; then ok "nudged, no warrant"; else bad "expected nudge-only, got: $(cat "$ACTIONS")"; fi

echo "== test 4: frozen past ESCALATE, WARRANT_ENABLED=1 -> warrant, correct target/route =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city" WARRANT_ENABLED=1
backdate "$city" thies-wa 1500     # frozen 1500s (>ESCALATE 1200)
: > "$ACTIONS"; pass "$city" WARRANT_ENABLED=1
if grep -q "^create" "$ACTIONS" && grep -q '"target":"thies-wa"' "$ACTIONS" \
   && grep -q "label=warrant" "$ACTIONS" && grep -q '"gc.routed_to":"gastown.dog"' "$ACTIONS"; then
  ok "warrant filed with correct target + label + dog route"
else bad "expected warrant, got: $(cat "$ACTIONS")"; fi

echo "== test 5: frozen past ESCALATE, WARRANT_ENABLED=0 (default) -> notify, NO warrant =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"                       # default WARRANT_ENABLED=0
backdate "$city" thies-wa 1500
: > "$ACTIONS"; pass "$city"
if grep -q "^notify" "$ACTIONS" && ! grep -q "^create" "$ACTIONS"; then ok "notify-only, no warrant (gated off)"; else bad "expected notify-only, got: $(cat "$ACTIONS")"; fi

echo "== test 6: gawisp-form crew (name != template) matched -> nudged =="
build_fixture "digo-wa-gawisp82s0ge|digo-wa|active|false"
clear_panes; set_pane digo-wa-gawisp82s0ge "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"
backdate "$city" digo-wa-gawisp82s0ge 700
: > "$ACTIONS"; pass "$city"
if grep -qx "nudge digo-wa-gawisp82s0ge" "$ACTIONS"; then ok "gawisp-form crew matched + nudged"; else bad "gawisp crew not matched: $(cat "$ACTIONS")"; fi

echo "== test 7: pool dog frozen -> ignored (not crew) =="
build_fixture "gastown.dog-3|gastown.dog|active|false"
clear_panes; set_pane gastown.dog-3 "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"; backdate "$city" gastown.dog-3 1500 2>/dev/null; : > "$ACTIONS"; pass "$city"
if [ ! -s "$ACTIONS" ]; then ok "pool dog ignored"; else bad "acted on pool dog: $(cat "$ACTIONS")"; fi

echo "== test 8: polecat frozen -> ignored (template has '/') =="
build_fixture "property_scrapers/claude-adhoc-x|property_scrapers/claude|active|false"
clear_panes; set_pane "property_scrapers/claude-adhoc-x" "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"; pass "$city"
if [ ! -s "$ACTIONS" ]; then ok "polecat ignored"; else bad "acted on polecat: $(cat "$ACTIONS")"; fi

echo "== test 9: human-attached frozen -> ignored =="
build_fixture "mila-wa|mila-wa|active|true"
clear_panes; set_pane mila-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"; pass "$city"
if [ ! -s "$ACTIONS" ]; then ok "attached session ignored"; else bad "acted on attached: $(cat "$ACTIONS")"; fi

echo "== test 10: asleep crew -> ignored =="
build_fixture "thies-wa|thies-wa|asleep|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"; pass "$city"
if [ ! -s "$ACTIONS" ]; then ok "asleep session ignored"; else bad "acted on asleep: $(cat "$ACTIONS")"; fi

echo "== test 11: dedup — open warrant exists -> no new warrant =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
echo '[{"id":"ga-w1","metadata":{"target":"thies-wa"}}]' > "$WARRANTS"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city" WARRANT_ENABLED=1
backdate "$city" thies-wa 1500 2>/dev/null
: > "$ACTIONS"; pass "$city" WARRANT_ENABLED=1
if ! grep -q "^create" "$ACTIONS"; then ok "no duplicate warrant when one is open"; else bad "filed duplicate warrant: $(cat "$ACTIONS")"; fi
echo "[]" > "$WARRANTS"

echo "== test 12: recovery — frozen then idle -> state cleared, no action =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; : > "$ACTIONS"
pass "$city"; backdate "$city" thies-wa 700
set_pane thies-wa "$IDLE_PANE"     # session went idle (recovered)
: > "$ACTIONS"; pass "$city"
if [ ! -s "$ACTIONS" ] && [ ! -f "$city/.gc/state/crew-hang/thies-wa" ]; then ok "idle recovery cleared state, no action"; else bad "recovery mishandled: actions=[$(cat "$ACTIONS")] state_present=$( [ -f "$city/.gc/state/crew-hang/thies-wa" ] && echo yes || echo no )"; fi

echo "== test 13: kill-switch -> no action even on a frozen crew =="
build_fixture "thies-wa|thies-wa|active|false"
clear_panes; set_pane thies-wa "$ACTIVE_PANE_A"
city="$(fresh_city)"; touch "$city/.gc/state/crew-hang-detector.disabled"
: > "$ACTIONS"; pass "$city" WARRANT_ENABLED=1
if [ ! -s "$ACTIONS" ]; then ok "kill-switch suppressed all action"; else bad "acted despite kill-switch: $(cat "$ACTIONS")"; fi

echo "== test 14: startup marker written =="
build_fixture "mila-wa|mila-wa|active|false"
clear_panes; set_pane mila-wa "$IDLE_PANE"
city="$(fresh_city)"; pass "$city"
if [ -s "$city/.gc/state/crew-hang-detector.startup" ]; then ok "startup marker written"; else bad "no startup marker"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
