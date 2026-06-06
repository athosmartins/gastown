#!/usr/bin/env bash
# pilot-dispatcher.selftest.sh — Prove the dependency-blocking filter (ga-5ew) in isolation.
#
# Bug ga-5ew: the Pilot dispatched a story whose hard dependency was not yet
# merged. The fix (_filter_unblocked) drops candidates that bd reports as BLOCKED
# by unresolved (open) dependencies, BEFORE picking the top-priority dispatch.
#
# This harness drives the REAL pilot-dispatcher.sh in DRY_RUN against a THROWAWAY
# fixture city. It NEVER touches the live city: PILOT_CITY_OVERRIDE redirects the
# log/jsonl into a temp dir, and a PATH-shim replaces bd/gc/notify with fakes that
# return canned JSON. No live Dolt, no live gc, no live launchd — safe on a live host.
#
# Two candidate bugs are presented to the dispatcher every run:
#   tt-blkd  — priority P0 (HIGHEST), but BLOCKED by an unresolved dep
#   tt-unblk — priority P1 (lower),   UNBLOCKED
#
# Scenario 1 (dep enforced): blocked-set = {tt-blkd}. The fix MUST exclude the
#   higher-priority blocked bug and dispatch the lower-priority unblocked one.
#   Without the fix the dispatcher would pick tt-blkd (P0) — so this scenario
#   fails loudly if the regression returns.
# Scenario 2 (no over-filter): blocked-set = {}. Nothing is blocked, so the
#   dispatcher must pick the highest-priority bug (tt-blkd) and emit NO exclusion.
#
# Exit 0 iff both scenarios behave as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Throwaway workspace ───────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SHIMBIN="$WORK/bin"
FIXCITY="$WORK/city"
mkdir -p "$SHIMBIN" "$FIXCITY/.gc/logs"

# ── Fake bd ───────────────────────────────────────────────────────────────────
# Dispatches on argv. Order matters: blocked check first, then the --all queries
# (stale recovery + in-flight count → empty), then the bug candidate query.
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *blocked*)
    ids="${FAKE_BLOCKED_IDS:-}"
    if [ -z "$ids" ]; then printf '[]'; exit 0; fi
    out="["; first=1
    for id in $ids; do
      [ "$first" -eq 1 ] || out="$out,"
      out="$out{\"id\":\"$id\",\"title\":\"blocked fixture\",\"status\":\"open\"}"
      first=0
    done
    printf '%s]' "$out"
    ;;
  *--all*)
    # Step 0 (stale story:approved+pilot:dispatching) and Step 1 (story:in-flight)
    # → empty, so all lane slots are free.
    printf '[]'
    ;;
  *"-t bug"*)
    # Two open, unassigned bug candidates. tt-blkd is HIGHER priority (P0).
    cat <<'JSON'
[
  {"id":"tt-blkd","title":"Blocked bug fixture","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-unblk","title":"Unblocked bug fixture","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
    ;;
  *)
    # tech-debt query, tier-2 features, anything else → empty.
    printf '[]'
    ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/bd"

# ── Fake gc / notify (no-ops; not reached on the HQ-candidate DRY_RUN path) ────
cat > "$SHIMBIN/gc" <<'SHIM'
#!/usr/bin/env bash
# Only rig-fallback would call `gc ... rig list`; return an empty rig set if so.
case "$*" in
  *"rig list"*) printf '{"rigs":[]}' ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/gc"

cat > "$SHIMBIN/notify" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$SHIMBIN/notify"

# ── Runner ────────────────────────────────────────────────────────────────────
# Runs the real dispatcher in DRY_RUN with the shims on PATH, returns the log.
run_dispatch() { # FAKE_BLOCKED_IDS
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    FAKE_BLOCKED_IDS="$1" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "pilot-dispatcher.selftest — dependency-blocking filter (ga-5ew)"

# ── Scenario 1: blocked dep is enforced ───────────────────────────────────────
echo "Scenario 1: tt-blkd BLOCKED — must skip it and dispatch tt-unblk"
LOG1="$(run_dispatch "tt-blkd")"

if echo "$LOG1" | grep -q "excluded 1 blocked candidate"; then
  ok "logged exclusion of the blocked candidate"
else
  bad "did NOT log exclusion (expected 'excluded 1 blocked candidate')"
fi

if echo "$LOG1" | grep -q "Lane picks — small: tt-unblk"; then
  ok "dispatched the UNBLOCKED bug (tt-unblk)"
else
  bad "did not pick tt-unblk as the small-lane dispatch"
fi

if echo "$LOG1" | grep -q "Lane picks — small: tt-blkd"; then
  bad "REGRESSION: dispatched the blocked bug (tt-blkd)"
else
  ok "did NOT dispatch the blocked bug"
fi

# ── Scenario 2: nothing blocked — no over-filtering ───────────────────────────
echo "Scenario 2: nothing blocked — must pick highest priority (tt-blkd) and not exclude"
LOG2="$(run_dispatch "")"

if echo "$LOG2" | grep -q "excluded .* blocked candidate"; then
  bad "over-filtered: emitted an exclusion when nothing was blocked"
else
  ok "no spurious exclusion when blocked-set is empty"
fi

if echo "$LOG2" | grep -q "Lane picks — small: tt-blkd"; then
  ok "picked the highest-priority bug (tt-blkd) when unblocked"
else
  bad "did not pick the highest-priority bug when nothing was blocked"
fi

# ── Structural tests: classify_lane and rig_to_builder coverage ──────────────
# Use || true on bare $() grep substitutions to prevent set -e aborts if the
# function is renamed — the grep exit code is captured into ok/bad, not set -e.
echo "Structural: classify_lane() and rig_to_builder() coverage"

grep -A 10 "^rig_to_builder()" "$DISPATCHER" | grep -q "whatsapp_automation" \
  && ok "rig_to_builder: wa mapping present" || bad "rig_to_builder: wa mapping missing"

grep -A 10 "^rig_to_builder()" "$DISPATCHER" | grep -q "gastown.dog" \
  && ok "rig_to_builder: default gastown.dog" || bad "rig_to_builder: default missing"

_fn_body=$(grep -A 30 "^classify_lane()" "$DISPATCHER" | head -30 || true)
echo "$_fn_body" | grep -q "lane:big" \
  && ok "classify_lane: lane:big check" || bad "classify_lane: lane:big missing"

_fn_body=$(grep -A 30 "^classify_lane()" "$DISPATCHER" | head -30 || true)
echo "$_fn_body" | grep -q "BIG_CRITERIA_THRESHOLD" \
  && ok "classify_lane: BIG_CRITERIA_THRESHOLD threshold" || bad "classify_lane: threshold missing"

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
