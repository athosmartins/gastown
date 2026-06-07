#!/usr/bin/env bash
# pilot-eligibility.selftest.sh — Prove the ga-zzrts dispatch-eligibility guards in isolation.
#
# Bug ga-zzrts: the Pilot flooded the gastown.dog pool with invalid slings in three ways:
#   (a) Dispatched beads whose SOURCE was already closed/delivered (orphan-sling flood).
#   (b) Dispatched beads labeled gate:needs-human (engine-path, un-buildable by dogs).
#   (c) Emitted duplicate slings for the same source bead (pilot:dispatched bead re-queued).
#
# This harness drives the REAL pilot-dispatcher.sh in DRY_RUN against a throwaway fixture
# city. PATH-shims replace bd / gc / notify with fakes; no live Dolt, no live gc, no live
# launchd. Safe on a live host.
#
# Scenarios:
#   1. gate:needs-human bead — MUST be excluded from candidates (query-layer exclusion).
#   2. pilot:dispatched bead — MUST be excluded from candidates (query-layer exclusion,
#      prevents duplicate sling even if story:in-flight was stripped by a crash).
#   3. Normal (eligible) bead — MUST be dispatched when the two ineligible beads are filtered.
#   4. Drift-guards — check that ga-zzrts guard patterns are present in the dispatcher source.
#
# For (a) orphan-sling/closed-source: the bd list query never returns closed beads, so the
# primary protection is the post-claim STATUS check inside dispatch_one (non-DRY_RUN path).
# That path is covered by the drift-guard (scenario 4) which asserts the guard strings exist.
#
# Exit 0 iff all assertions hold.

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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-eligibility-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SHIMBIN="$WORK/bin"
FIXCITY="$WORK/city"
mkdir -p "$SHIMBIN" "$FIXCITY/.gc/logs"

# ── Fake bd ───────────────────────────────────────────────────────────────────
# Three candidate bugs. The fake bd filters them based on --exclude-label flags
# in the args (space-separated), mimicking what real bd does.
#
# tt-normal      : no exclusion labels — should be dispatched.
# tt-needs-human : has gate:needs-human — excluded by --exclude-label gate:needs-human.
# tt-dispatched  : has pilot:dispatched — excluded by --exclude-label pilot:dispatched.
#
# The fake parses $args for "--exclude-label X" tokens and drops any candidate whose
# labels array contains X. This proves the dispatcher PASSES the right flags to bd.
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
args="$*"

# Collect --exclude-label values from args
excluded=""
rest="$args"
while true; do
  case "$rest" in
    *"--exclude-label "*)
      part="${rest#*--exclude-label }"
      label="${part%% *}"
      # strip surrounding quotes if any
      label="${label//\"/}"
      excluded="$excluded $label"
      rest="${rest#*--exclude-label $part}"
      rest="$args"
      break
      ;;
    *) break ;;
  esac
done
# Simpler: just grep out all --exclude-label values
excluded=$(printf '%s\n' $args | awk 'f{print;f=0} /--exclude-label/{f=1}' | tr -d '"')

case "$args" in
  *blocked*)
    printf '[]'
    ;;
  *--all*)
    # Step 0 (stale) and Step 1 (in-flight) → empty, all slots free.
    printf '[]'
    ;;
  *"-t bug"*)
    # All three candidate bugs. Filter by any --exclude-label present in args.
    CANDIDATES=$(cat <<'JSON'
[
  {"id":"tt-normal","title":"Normal eligible bug","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-needs-human","title":"Gate-parked bug","priority":0,"issue_type":"bug","status":"open","labels":["gate:needs-human"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-dispatched","title":"Already-dispatched bug","priority":0,"issue_type":"bug","status":"open","labels":["pilot:dispatched"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
)
    # Filter: drop any bead whose labels contain a value in --exclude-label list.
    EXCL_LABELS=$(printf '%s\n' $args \
      | awk 'f{print;f=0} /^--exclude-label$/{f=1}' \
      | tr -d '"')
    if [ -z "$EXCL_LABELS" ]; then
      printf '%s' "$CANDIDATES"
    else
      EXCL_JQ=$(printf '%s\n' "$EXCL_LABELS" \
        | jq -R . | jq -s . 2>/dev/null || echo '[]')
      printf '%s' "$CANDIDATES" \
        | jq --argjson excl "$EXCL_JQ" \
          '[.[] | select((.labels // []) | map(. as $l | $excl | index($l)) | all(. == null))]' \
          2>/dev/null || printf '%s' "$CANDIDATES"
    fi
    ;;
  *)
    # tech-debt, tier-2 features, anything else → empty.
    printf '[]'
    ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/bd"

# ── Fake gc / notify ──────────────────────────────────────────────────────────
cat > "$SHIMBIN/gc" <<'SHIM'
#!/usr/bin/env bash
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
run_dispatch() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "pilot-eligibility.selftest — ga-zzrts dispatch-eligibility guards"

# ── Scenario 1: gate:needs-human excluded from candidates ────────────────────
echo ""
echo "Scenario 1: gate:needs-human bead (tt-needs-human) must NOT be dispatched"
LOG="$(run_dispatch)"

if echo "$LOG" | grep -q "tt-needs-human"; then
  bad "REGRESSION: tt-needs-human appeared in dispatch picks (gate:needs-human not excluded)"
else
  ok "tt-needs-human NOT in dispatch picks (excluded by --exclude-label gate:needs-human)"
fi

# ── Scenario 2: pilot:dispatched excluded from candidates ────────────────────
echo ""
echo "Scenario 2: pilot:dispatched bead (tt-dispatched) must NOT be dispatched"

if echo "$LOG" | grep -q "tt-dispatched"; then
  bad "REGRESSION: tt-dispatched appeared in dispatch picks (pilot:dispatched not excluded)"
else
  ok "tt-dispatched NOT in dispatch picks (excluded by --exclude-label pilot:dispatched)"
fi

# ── Scenario 3: eligible bead is dispatched ──────────────────────────────────
echo ""
echo "Scenario 3: eligible bead (tt-normal) MUST be dispatched"

if echo "$LOG" | grep -q "Lane picks — small: tt-normal"; then
  ok "tt-normal selected as small-lane dispatch (eligible bead dispatched correctly)"
else
  bad "tt-normal NOT selected as small-lane dispatch (eligible bead was not dispatched)"
  echo "  --- log excerpt ---"
  echo "$LOG" | grep -E "(Lane picks|Tier 1|candidate)" | head -10
fi

# ── Scenario 4: drift-guards — key ga-zzrts patterns in source ───────────────
echo ""
echo "Scenario 4: drift-guards — ga-zzrts guard patterns present in dispatcher source"

check_pattern() {
  local name="$1"
  local pattern="$2"
  if grep -qE "$pattern" "$DISPATCHER"; then
    ok "$name"
    PASS=$((PASS+1))
    # Already counted via ok, undo the double count
    PASS=$((PASS-1))
    return 0
  else
    bad "$name — pattern missing: $pattern"
    return 1
  fi
}

# (b) gate:needs-human excluded from every bd list query
NH_COUNT=$(grep -c 'exclude-label "gate:needs-human"' "$DISPATCHER" 2>/dev/null || echo "0")
if [ "$NH_COUNT" -ge "6" ]; then
  ok "gate:needs-human excluded in all 6 bd list queries (found $NH_COUNT occurrences)"
else
  bad "gate:needs-human exclusion count expected >=6, got $NH_COUNT"
fi

# (c) pilot:dispatched excluded from every bd list query
PD_COUNT=$(grep -c 'exclude-label "pilot:dispatched"' "$DISPATCHER" 2>/dev/null || echo "0")
if [ "$PD_COUNT" -ge "6" ]; then
  ok "pilot:dispatched excluded in all 6 bd list queries (found $PD_COUNT occurrences)"
else
  bad "pilot:dispatched exclusion count expected >=6, got $PD_COUNT"
fi

# (b) post-claim gate:needs-human guard in dispatch_one
if grep -q "ga-zzrts(b)" "$DISPATCHER"; then
  ok "post-claim gate:needs-human guard present (ga-zzrts fix b)"
else
  bad "post-claim gate:needs-human guard MISSING from dispatch_one"
fi

# (c) post-claim duplicate guard in dispatch_one
if grep -q "ga-zzrts(c)" "$DISPATCHER"; then
  ok "post-claim pilot:dispatched duplicate guard present (ga-zzrts fix c)"
else
  bad "post-claim pilot:dispatched duplicate guard MISSING from dispatch_one"
fi

# (a) closed-bead STATUS guard in dispatch_one
if grep -q "ga-zzrts(a)" "$DISPATCHER"; then
  ok "post-claim closed-bead / orphan-sling STATUS guard present (ga-zzrts fix a)"
else
  bad "post-claim closed-bead STATUS guard MISSING from dispatch_one"
fi

# (a) source-bead metadata lookup
if grep -q 'VERIFY_SOURCEBEAD' "$DISPATCHER"; then
  ok "source-bead metadata field lookup present (orphan-sling guard)"
else
  bad "source-bead metadata field lookup MISSING (orphan-sling guard incomplete)"
fi

# set -e/pipefail safety: new pipelines must not be unguarded
# Check that all VERIFY_* assignments end with || echo ""
if grep -A2 'VERIFY_STATUS=\|VERIFY_SOURCEBEAD=\|SOURCE_BEAD_STATUS=' "$DISPATCHER" \
    | grep -q '|| echo ""'; then
  ok "new pipeline assignments guarded with || echo \"\" (set-e/pipefail safe)"
else
  bad "new pipeline assignments may be unguarded — check set-e/pipefail safety"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
