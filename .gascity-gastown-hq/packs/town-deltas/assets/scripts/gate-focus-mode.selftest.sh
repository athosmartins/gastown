#!/usr/bin/env bash
# gate-focus-mode.selftest.sh (ga-kqa08j) — hermetic: every path points into a scratch
# dir, notify is a stub that records calls, bd is never called (depth override).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/gate-focus-st.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

export GC_CITY="$W/city" GC_CITY_PATH="$W/city"
mkdir -p "$GC_CITY/.gc/logs"
export GATE_FOCUS_STATE_FILE="$W/city/.gc/gate-focus.state"
export GATE_FOCUS_OFF_FILE="$W/city/.gc/gate-focus.off"
export GATE_FOCUS_LOG="$W/city/.gc/logs/gate-focus-mode.log"
export GATE_FOCUS_LOCK="$W/city/.gc/gate-focus.lock"
cat >"$W/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/notified"
EOF
chmod +x "$W/notify"
export GATE_FOCUS_NOTIFY_CMD="$W/notify"
export BD="$W/no-bd-must-not-be-called"
MODE="$HERE/gate-focus-mode.sh"
LIB="$HERE/gate-focus-lib.sh"

run() { GATE_FOCUS_DEPTH_OVERRIDE="$1" GATE_FOCUS_NOW="$2" bash "$MODE"; }
field() { sed -n "s/^$1=//p" "$GATE_FOCUS_STATE_FILE" 2>/dev/null | head -n 1; }
notes() { [ -f "$W/notified" ] && wc -l <"$W/notified" | tr -d ' ' || echo 0; }

# T1 decide() table — the hysteresis band 8..15 keeps the previous mode.
( GATE_FOCUS_LIB_MODE=1 source "$MODE"
  r=""; for c in "0 15:0" "0 16:1" "1 15:1" "1 8:1" "1 7:0" "0 7:0" "0 100:1" "1 0:0"; do
    p="${c%%:*}"; want="${c##*:}"; got="$(decide ${p% *} ${p#* })"
    [ "$got" = "$want" ] || r="$r [$p want $want got $got]"
  done; [ -z "$r" ] || { echo "$r"; exit 1; } ) && ok || bad "T1 decide table"

# T2 a sequence: 14 (stay off), 16 (ENTER + 1 notify), 10 (stay on, no notify), 7 (EXIT + 1 notify)
run 14 1000; [ "$(field active)" = "0" ] && [ "$(notes)" = "0" ] && ok || bad "T2a 14 must stay off, no notify"
run 16 1300; [ "$(field active)" = "1" ] && [ "$(notes)" = "1" ] && [ "$(field since)" = "1300" ] && ok || bad "T2b 16 must enter with exactly one notify"
grep -q 'LIGADO' "$W/notified" && ok || bad "T2b' enter notify text"
run 10 1600; [ "$(field active)" = "1" ] && [ "$(notes)" = "1" ] && [ "$(field since)" = "1300" ] && ok || bad "T2c 10 must keep focus, no new notify, since unchanged"
run 7 1900;  [ "$(field active)" = "0" ] && [ "$(notes)" = "2" ] && grep -q 'DESLIGADO' "$W/notified" && ok || bad "T2d 7 must exit with one notify"

# T3 unreadable depth: keeps the mode, no notify, does NOT refresh at
run 20 2200; at_before="$(field at)"
run unreadable 2500
[ "$(field active)" = "1" ] && [ "$(field at)" = "$at_before" ] && [ "$(notes)" = "3" ] && ok \
  || bad "T3 unreadable must keep active=1, keep at=$at_before (got $(field at)), add no notify"

# T4 reader: fresh -> 1; stale -> unknown; corrupt -> unknown; missing -> unknown
( source "$LIB"; [ "$(GATE_FOCUS_NOW=2300 gate_focus_active)" = "1" ] ) && ok || bad "T4a fresh state must read 1"
( source "$LIB"; [ "$(GATE_FOCUS_NOW=$((2200+7201)) gate_focus_active)" = "unknown" ] ) && ok || bad "T4b stale state must read unknown"
cp "$GATE_FOCUS_STATE_FILE" "$W/keep"; printf 'active=yes\nat=2200\n' >"$GATE_FOCUS_STATE_FILE"
( source "$LIB"; [ "$(GATE_FOCUS_NOW=2300 gate_focus_active)" = "unknown" ] ) && ok || bad "T4c corrupt active must read unknown"
rm -f "$GATE_FOCUS_STATE_FILE"
( source "$LIB"; [ "$(GATE_FOCUS_NOW=2300 gate_focus_active)" = "unknown" ] ) && ok || bad "T4d missing file must read unknown"
cp "$W/keep" "$GATE_FOCUS_STATE_FILE"

# T5 kill switch forces OFF with exactly one exit notify, then stays quiet
touch "$GATE_FOCUS_OFF_FILE"
run 40 2600; [ "$(field active)" = "0" ] && [ "$(notes)" = "4" ] && ok || bad "T5a kill switch must force off with one notify"
run 40 2900; [ "$(field active)" = "0" ] && [ "$(notes)" = "4" ] && ok || bad "T5b kill switch must not re-notify"
rm -f "$GATE_FOCUS_OFF_FILE"

# T6 DRY_RUN writes nothing and notifies nothing
cp "$GATE_FOCUS_STATE_FILE" "$W/before"
DRY_RUN=1 run 99 3200; cmp -s "$W/before" "$GATE_FOCUS_STATE_FILE" && [ "$(notes)" = "4" ] && ok || bad "T6 DRY_RUN must not write or notify"

# T7 a held lock skips the run (no write)
mkdir "$GATE_FOCUS_LOCK"; cp "$GATE_FOCUS_STATE_FILE" "$W/before"
run 99 3500; cmp -s "$W/before" "$GATE_FOCUS_STATE_FILE" && ok || bad "T7 a held lock must skip the run"
rmdir "$GATE_FOCUS_LOCK"

# T8 max duration: ON for > GATE_FOCUS_MAX_S escalates exactly once
rm -f "$GATE_FOCUS_STATE_FILE"; : >"$W/notified"
GATE_FOCUS_MAX_S=1000 run 30 10000          # enter (1 notify)
GATE_FOCUS_MAX_S=1000 run 30 10500          # 500 s in: no escalation
[ "$(notes)" = "1" ] && ok || bad "T8a no escalation before the max duration"
GATE_FOCUS_MAX_S=1000 run 30 11200          # 1200 s in: escalate once
GATE_FOCUS_MAX_S=1000 run 30 11500          # still on: no second escalation
[ "$(notes)" = "2" ] && grep -q 'Modo foco no gate há' "$W/notified" && ok || bad "T8b exactly one escalation after the max duration (notes=$(notes))"

# T9 pool-autoscale-watchdog reads the same state (silences STUCK pushes only when fresh+ON)
PY_OK="$(GATE_FOCUS_STATE_FILE="$GATE_FOCUS_STATE_FILE" python3 - "$HERE/../../../../scripts" <<'PYEOF'
import sys, importlib.util, types
sys.modules['gc_ledger'] = types.SimpleNamespace(gc_ledger_append=lambda *a, **k: None)
spec = importlib.util.spec_from_file_location("paw", sys.argv[1] + "/pool-autoscale-watchdog.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("%s %s" % (m._gate_focus_active(11600), m._gate_focus_active(11500 + 7201)))
PYEOF
)"
[ "$PY_OK" = "True False" ] && ok || bad "T9 watchdog focus reader: fresh ON must be True, stale must be False (got '$PY_OK')"

echo "gate-focus-mode selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
