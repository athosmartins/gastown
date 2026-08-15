#!/usr/bin/env bash
# pilot-choretask-unconditional.selftest.sh — Prove the ga-ciyypt fix in isolation.
#
# Bug ga-ciyypt: painel_visibilidade.py doctrine (_AUTO_DISPATCH_TYPES, L602-607)
# documents bug/chore/task as ALL "despachados direto" (no readiness label
# required — only ctx:thin excludes). BUGS_JSON/DEBT_JSON already gave HQ
# bug/tech-debt that unconditional treatment; chore/task never did — they ONLY
# flowed through CTXREADY_JSON, which hard-requires -l ctx:ready. The fix adds
# CHORE_JSON/TASK_JSON (HQ) mirroring BUGS_JSON exactly, plus an explicit
# type:quality-gate-marker/-run/-verdict exclusion (those are internal gate-
# bookkeeping beads conventionally typed "chore" that were, until now, kept out
# only by the accident of never being ctx:ready-labeled).
#
# This harness drives the REAL pilot-dispatcher.sh in DRY_RUN against a
# throwaway fixture city, following the exact shim technique already proven by
# pilot-eligibility.selftest.sh. Safe on a live host.
#
# Scenarios:
#   1. Plain chore bead, no labels at all — MUST be dispatched (the fix's core claim).
#   2. Plain task bead, no labels at all — MUST be dispatched (same, other type).
#   3. Chore bead carrying type:quality-gate-marker — MUST NOT be dispatched
#      (safety: internal gate bookkeeping must never look like real work).
#   4. Chore bead carrying ctx:thin — MUST NOT be dispatched (matches painel's
#      own _is_auto_dispatch_card gate; defense-in-depth already present).
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-choretask-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SHIMBIN="$WORK/bin"
FIXCITY="$WORK/city"
mkdir -p "$SHIMBIN" "$FIXCITY/.gc/logs"

# ── Fake bd ───────────────────────────────────────────────────────────────────
# Fixtures, one per scenario. The fake filters them by any --exclude-label
# token present in $args, mimicking real bd (same technique as
# pilot-eligibility.selftest.sh's proven shim).
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
args="$*"

filter_by_exclude() {
  local candidates="$1"
  local excl_labels
  excl_labels=$(printf '%s\n' $args \
    | awk 'f{print;f=0} /^--exclude-label$/{f=1}' \
    | tr -d '"')
  if [ -z "$excl_labels" ]; then
    printf '%s' "$candidates"
  else
    local excl_jq
    excl_jq=$(printf '%s\n' "$excl_labels" | jq -R . | jq -s . 2>/dev/null || echo '[]')
    printf '%s' "$candidates" \
      | jq --argjson excl "$excl_jq" \
        '[.[] | select((.labels // []) | map(. as $l | $excl | index($l)) | all(. == null))]' \
        2>/dev/null || printf '%s' "$candidates"
  fi
}

case "$args" in
  *blocked*)
    printf '[]'
    ;;
  *" -l pilot:dispatching"*|*" -l story:in-flight"*)
    printf '[]'
    ;;
  *"-t chore"*)
    CANDIDATES=$(cat <<'JSON'
[
  {"id":"tt-chore-normal","title":"Plain chore, no labels","priority":2,"issue_type":"chore","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{},"description":"A real, ordinary chore with enough description to dispatch."},
  {"id":"tt-chore-gatemarker","title":"Gate marker masquerading as chore","priority":2,"issue_type":"chore","status":"open","labels":["type:quality-gate-marker","gate-status:queued"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{},"description":"source-bead: tt-some-bug"},
  {"id":"tt-chore-thin","title":"Under-specified chore","priority":2,"issue_type":"chore","status":"open","labels":["ctx:thin"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{},"description":"tbd"}
]
JSON
)
    filter_by_exclude "$CANDIDATES"
    ;;
  *"-t task"*)
    CANDIDATES=$(cat <<'JSON'
[
  {"id":"tt-task-normal","title":"Plain task, no labels","priority":2,"issue_type":"task","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{},"description":"A real, ordinary task with enough description to dispatch."}
]
JSON
)
    filter_by_exclude "$CANDIDATES"
    ;;
  *)
    # bug, tech-debt, tier-2 features, ctx:ready queries, anything else → empty.
    printf '[]'
    ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/bd"

cat > "$SHIMBIN/gc" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  *"rig list"*) printf '{"rigs":[]}' ;;
  *"dolt health"*) printf '{"server":{"latency_ms":5,"pid":12345}}' ;;
  *"session list"*) printf '{"sessions":[]}' ;;
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

run_dispatch() {
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  env -i \
    PATH="$SHIMBIN:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=1 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    PILOT_RAM_PRESSURE_OVERRIDE="OK" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "pilot-choretask-unconditional.selftest — ga-ciyypt chore/task dispatch gap"
LOG="$(run_dispatch)"

echo ""
echo "Scenario 1: plain chore bead (tt-chore-normal), no ctx:ready — MUST dispatch"
if echo "$LOG" | grep -qE "(Lane picks|small|big).*tt-chore-normal|tt-chore-normal.*(Lane picks|dispatch)"; then
  ok "tt-chore-normal appears in dispatch picks"
elif echo "$LOG" | grep -q "tt-chore-normal"; then
  ok "tt-chore-normal referenced in dispatch log (candidate reached the pool)"
else
  bad "tt-chore-normal NOT referenced anywhere in dispatch log — fix did not make it a candidate"
  echo "  --- log excerpt ---"
  echo "$LOG" | grep -E "(Lane picks|Tier 1|candidate|chore)" | head -10
fi

echo ""
echo "Scenario 2: plain task bead (tt-task-normal), no ctx:ready — MUST dispatch"
if echo "$LOG" | grep -q "tt-task-normal"; then
  ok "tt-task-normal referenced in dispatch log (candidate reached the pool)"
else
  bad "tt-task-normal NOT referenced anywhere in dispatch log — fix did not make it a candidate"
  echo "  --- log excerpt ---"
  echo "$LOG" | grep -E "(Lane picks|Tier 1|candidate|task)" | head -10
fi

echo ""
echo "Scenario 3: chore bead labeled type:quality-gate-marker — MUST NOT dispatch"
if echo "$LOG" | grep -q "tt-chore-gatemarker"; then
  bad "REGRESSION: tt-chore-gatemarker appeared in dispatch log — gate-marker bookkeeping bead exposed as a candidate"
else
  ok "tt-chore-gatemarker NOT in dispatch log (excluded by type:quality-gate-marker)"
fi

echo ""
echo "Scenario 4: chore bead labeled ctx:thin — MUST NOT dispatch"
if echo "$LOG" | grep -q "tt-chore-thin"; then
  bad "REGRESSION: tt-chore-thin appeared in dispatch log — under-specified bead dispatched"
else
  ok "tt-chore-thin NOT in dispatch log (excluded by ctx:thin)"
fi

echo ""
echo "Scenario 5: drift-guard — CHORE_JSON/TASK_JSON present in dispatcher source"
if grep -q 'CHORE_JSON=' "$DISPATCHER" && grep -q 'TASK_JSON=' "$DISPATCHER"; then
  ok "CHORE_JSON/TASK_JSON present (ga-ciyypt fix landed)"
else
  bad "CHORE_JSON/TASK_JSON MISSING from dispatcher source"
fi

if grep -q '_rt1_chore=' "$DISPATCHER" && grep -q '_rt1_task=' "$DISPATCHER"; then
  ok "_rt1_chore/_rt1_task present (rig-side ga-ciyypt fix landed)"
else
  bad "_rt1_chore/_rt1_task MISSING from dispatcher source (rig side)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
