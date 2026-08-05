#!/usr/bin/env bash
# eval-window-concurrency-guard.selftest.sh — prove the ga-sb11i.2 window-detection
# and profile-toggle logic in isolation, with NO live Dolt/gc/launchd and NO
# mutation of the real committed config (everything runs against temp copies).
#
# Fixture epochs (verified round-trip via `date -r` before being hardcoded):
#   FRI_IN_WINDOW    = Fri 2026-08-07 05:15 local (dow=5) -> lexbh window
#   MON_IN_WINDOW    = Mon 2026-08-10 09:18 local (dow=1) -> whatsapp window
#   WED_NEUTRAL      = Wed 2026-08-05 12:00 local (dow=3) -> no window
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/scripts/eval-window-concurrency-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Hermetic sandbox: real committed files, temp copy (never touch the live city) ─
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/packs/town-deltas/orders"
cp "$SELF_DIR/../../../city.toml" "$SANDBOX/city.toml"
cp "$SELF_DIR/../orders/beads-health.toml" "$SANDBOX/packs/town-deltas/orders/beads-health.toml"
cp "$SELF_DIR/../orders/gate-sweep.toml" "$SANDBOX/packs/town-deltas/orders/gate-sweep.toml"
cp "$SELF_DIR/../orders/order-tracking-sweep.toml" "$SANDBOX/packs/town-deltas/orders/order-tracking-sweep.toml"

# ── Load the REAL helpers from the guard script (lib-only = no live run) ──────
# Plain assignments (not a prefix on `source`) so GC/GC_CITY_PATH stay set for
# the rest of this script, not just for the duration of the source call.
export GC_CITY_PATH="$SANDBOX"
export EVAL_WINDOW_GUARD_LIB_ONLY=1
export GC=/bin/true
source "$SCRIPT" \
  || { echo "FATAL: could not source guard script in lib-only mode"; exit 1; }

for fn in in_lexbh_window in_whatsapp_window in_qge_window current_window_name \
          desired_profile get_dog_max get_oracle_min get_order_interval apply_profile; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by guard script"; exit 1; }
done

FRI_IN_WINDOW=1786090500   # Fri 2026-08-07 05:15 -03
MON_IN_WINDOW=1786364280   # Mon 2026-08-10 09:18 -03
WED_NEUTRAL=1785942000     # Wed 2026-08-05 12:00 -03

# ── 1. calendar window detection ───────────────────────────────────────────────
echo "── 1. lexbh / whatsapp calendar windows ──"
in_lexbh_window "$FRI_IN_WINDOW" && ok "Fri 05:15 -> inside lexbh window" || bad "Fri 05:15 should be inside lexbh window"
in_lexbh_window "$MON_IN_WINDOW" && bad "Mon 09:18 should NOT be inside lexbh window" || ok "Mon 09:18 -> outside lexbh window"
in_whatsapp_window "$MON_IN_WINDOW" && ok "Mon 09:18 -> inside whatsapp window" || bad "Mon 09:18 should be inside whatsapp window"
in_whatsapp_window "$FRI_IN_WINDOW" && bad "Fri 05:15 should NOT be inside whatsapp window" || ok "Fri 05:15 -> outside whatsapp window"
in_lexbh_window "$WED_NEUTRAL" && bad "Wed noon should NOT be inside lexbh window" || ok "Wed noon -> outside lexbh window"
in_whatsapp_window "$WED_NEUTRAL" && bad "Wed noon should NOT be inside whatsapp window" || ok "Wed noon -> outside whatsapp window"

# Boundary: one minute before/after the lexbh window edges.
FRI_BEFORE=$((FRI_IN_WINDOW - (15*60) - 60))  # 04:59 same Friday
FRI_AFTER=$((FRI_IN_WINDOW + (15*60)))        # 05:30 same Friday (end is exclusive)
in_lexbh_window "$FRI_BEFORE" && bad "04:59 should be before the lexbh window" || ok "04:59 -> before lexbh window (pre-roll boundary)"
in_lexbh_window "$FRI_AFTER" && bad "05:30 should be at/after the lexbh window end (exclusive)" || ok "05:30 -> at lexbh window end, excluded"

# ── 2. QGE drifting-interval window (log-mtime + 7d ± buffer) ─────────────────
echo "── 2. quality-gate-eval predicted window ──"
QGE_NOW=1786000000
in_qge_window "$QGE_NOW" "" && bad "empty mtime should never be in-window" || ok "empty/missing QGE log mtime -> never in window (fail-safe)"
in_qge_window "$QGE_NOW" "$((QGE_NOW - 604800))" && ok "exactly one period ago -> predicted window hit" || bad "mtime exactly 7d before now should predict a hit"
in_qge_window "$QGE_NOW" "$((QGE_NOW - 604800 - 1200))" && ok "7d + 1200s (buffer edge) -> still in window" || bad "buffer edge (1200s) should still count as in-window"
in_qge_window "$QGE_NOW" "$((QGE_NOW - 604800 - 1201))" && bad "7d + 1201s should be outside the buffer" || ok "just past the buffer -> outside window"
in_qge_window "$QGE_NOW" "$((QGE_NOW - 300000))" && bad "an unrelated recent mtime should not predict a hit" || ok "unrelated mtime (not ~7d ago) -> outside window"

# ── 3. window name + profile composition ──────────────────────────────────────
echo "── 3. current_window_name + desired_profile ──"
eq "Friday 05:15 window name" "$(current_window_name "$FRI_IN_WINDOW" "")" "lexbh"
eq "Monday 09:18 window name" "$(current_window_name "$MON_IN_WINDOW" "")" "whatsapp"
eq "Wed noon window name (no QGE mtime)" "$(current_window_name "$WED_NEUTRAL" "")" ""
eq "Wed noon WITH a QGE-predicting mtime" "$(current_window_name "$WED_NEUTRAL" "$((WED_NEUTRAL - 604800))")" "quality-gate-eval"
eq "profile when window=lexbh" "$(desired_profile "lexbh")" "throttled"
eq "profile when window=empty" "$(desired_profile "")" "normal"

# ── 4. reading current on-disk values (against the REAL committed files) ──────
echo "── 4. get_dog_max / get_oracle_min / get_order_interval read the real files ──"
eq "gastown.dog max_active_sessions (normal, as committed)" "$(get_dog_max)" "3"
eq "oracle-wa min_active_sessions (normal, as committed)" "$(get_oracle_min)" "1"
eq "beads-health interval (normal, as committed)" "$(get_order_interval "$BEADS_HEALTH_TOML")" "120s"
eq "gate-sweep interval (normal, as committed)" "$(get_order_interval "$GATE_SWEEP_TOML")" "60s"
eq "order-tracking-sweep interval (normal, as committed)" "$(get_order_interval "$ORDER_TRACKING_TOML")" "5m"

# ── 5. DRY_RUN never mutates the sandbox files ─────────────────────────────────
echo "── 5. DRY_RUN=1 computes but never writes ──"
SUM_BEFORE="$(cat "$CITY_TOML" "$BEADS_HEALTH_TOML" "$GATE_SWEEP_TOML" "$ORDER_TRACKING_TOML" | shasum)"
DRY_RUN=1 apply_profile "throttled" >/dev/null
SUM_AFTER="$(cat "$CITY_TOML" "$BEADS_HEALTH_TOML" "$GATE_SWEEP_TOML" "$ORDER_TRACKING_TOML" | shasum)"
eq "DRY_RUN leaves all 4 files byte-identical" "$SUM_AFTER" "$SUM_BEFORE"

# ── 6. real apply (GC stubbed to /bin/true — never touches the live city) ─────
echo "── 6. apply_profile(throttled) rewrites all 5 targets ──"
apply_profile "throttled" >/dev/null
eq "gastown.dog max_active_sessions -> throttled" "$(get_dog_max)" "1"
eq "oracle-wa min_active_sessions -> throttled" "$(get_oracle_min)" "0"
eq "beads-health interval -> throttled" "$(get_order_interval "$BEADS_HEALTH_TOML")" "300s"
eq "gate-sweep interval -> throttled" "$(get_order_interval "$GATE_SWEEP_TOML")" "150s"
eq "order-tracking-sweep interval -> throttled" "$(get_order_interval "$ORDER_TRACKING_TOML")" "12m"

# Untouched fields on the SAME city.toml block must survive the rewrite.
grep -q 'pre_start = \["/Users/athos/gt/.gascity-gastown-hq/scripts/dog-pool-preflight-reclaim.py"\]' "$CITY_TOML" \
  && ok "unrelated gastown.dog fields (pre_start) survive the rewrite" \
  || bad "pre_start line was clobbered by the rewrite"
grep -q 'provider = "claude-headless"' "$CITY_TOML" \
  && ok "unrelated gastown.dog fields (provider) survive the rewrite" \
  || bad "provider line was clobbered by the rewrite"

# ── 7. idempotency: re-applying the SAME profile changes nothing ──────────────
echo "── 7. idempotent re-apply ──"
SUM_THROTTLED="$(cat "$CITY_TOML" "$BEADS_HEALTH_TOML" "$GATE_SWEEP_TOML" "$ORDER_TRACKING_TOML" | shasum)"
apply_profile "throttled" >/dev/null
SUM_THROTTLED_AGAIN="$(cat "$CITY_TOML" "$BEADS_HEALTH_TOML" "$GATE_SWEEP_TOML" "$ORDER_TRACKING_TOML" | shasum)"
eq "re-applying throttled profile is a byte-identical no-op" "$SUM_THROTTLED_AGAIN" "$SUM_THROTTLED"

# ── 8. restore path: normal profile round-trips back to the original values ───
echo "── 8. apply_profile(normal) restores the original values ──"
apply_profile "normal" >/dev/null
eq "gastown.dog max_active_sessions restored" "$(get_dog_max)" "3"
eq "oracle-wa min_active_sessions restored" "$(get_oracle_min)" "1"
eq "beads-health interval restored" "$(get_order_interval "$BEADS_HEALTH_TOML")" "120s"
eq "gate-sweep interval restored" "$(get_order_interval "$GATE_SWEEP_TOML")" "60s"
eq "order-tracking-sweep interval restored" "$(get_order_interval "$ORDER_TRACKING_TOML")" "5m"
SUM_RESTORED="$(cat "$CITY_TOML" "$BEADS_HEALTH_TOML" "$GATE_SWEEP_TOML" "$ORDER_TRACKING_TOML" | shasum)"
eq "restored state is byte-identical to the original committed files" "$SUM_RESTORED" "$SUM_BEFORE"

# ── 9. drift-guard: the plist points at the real script path ──────────────────
# Checked as a stable path SUFFIX, not the absolute $SCRIPT path — this
# selftest may run from a worktree checkout, but the plist correctly hardcodes
# the canonical PRODUCTION path (mirrors crew-hang-detector.plist's own
# convention), so an absolute-path comparison would false-fail under a worktree.
echo "── 9. drift-guard: plist wiring ──"
PLIST="$SELF_DIR/eval-window-concurrency-guard.plist"
CANONICAL_SUFFIX="packs/town-deltas/assets/scripts/eval-window-concurrency-guard.sh"
if grep -q "$CANONICAL_SUFFIX" "$PLIST"; then
  ok "plist ProgramArguments references the real script path"
else
  bad "plist does NOT reference .../$CANONICAL_SUFFIX — deploy would run the wrong file"
fi
if grep -q '<integer>300</integer>' "$PLIST"; then
  ok "plist StartInterval is 300s (matches the guard's own 5-target reload assumption)"
else
  bad "plist StartInterval changed — re-check window pre-roll margins still cover one poll cycle"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
