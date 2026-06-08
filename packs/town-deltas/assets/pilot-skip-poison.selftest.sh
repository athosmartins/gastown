#!/usr/bin/env bash
# pilot-skip-poison.selftest.sh — Prove the skip+continue resilience fix and the
# defensive sling-title ASCII-fold (ga-jjh7w).
#
# Bug ga-jjh7w: the Pilot dispatched ONLY the single highest-priority candidate per
# lane per sweep. When that head-of-line pick deterministically failed `gc sling`
# (e.g. ga-jhyu, whose accented title broke the Dolt bead insert with
# "Incorrect string value: '\xC3' for column 'title'"), the lane got ZERO dispatches
# that sweep — and the SAME poison bead was re-picked every sweep. This starved the
# whole small lane for ~8h until a human manually sanitized the title.
#
# Two complementary fixes are proven here, each in NON-DRY mode against a THROWAWAY
# fixture city. The harness NEVER touches the live city: PILOT_CITY_OVERRIDE redirects
# the log/jsonl into a temp dir, and a PATH-shim replaces bd/gc/notify with fakes.
#
#   Scenario 1 (skip+continue): a poison bead (tt-poison, P0, head-of-line) whose
#     `gc sling` FAILS, plus a healthy bead (tt-healthy, P1). The dispatcher must
#     SKIP the poison and dispatch the healthy one. Without the fix it attempts only
#     tt-poison, fails, and dispatches NOTHING.
#
#   Scenario 2 (ASCII-fold): a single bead (tt-accent, P0) whose title carries a raw
#     non-ASCII byte (an accented char, like the real ga-jhyu). The fake `gc sling`
#     FAILS on any non-ASCII byte in its arguments — exactly like the real bead
#     insert. The dispatcher must fold the sling title to ASCII so the dispatch
#     SUCCEEDS. Without the fold the accented bead is permanently undispatchable.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-skip-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SHIMBIN="$WORK/bin"
FIXCITY="$WORK/city"
mkdir -p "$SHIMBIN" "$FIXCITY/.gc/logs"

# ── Fake bd ───────────────────────────────────────────────────────────────────
# `blocked` and `--all` queries → empty. `-t bug` → candidates chosen by the
# SELFTEST_SCENARIO env var. `show <id>` → a clean bead carrying pilot:dispatching
# (non-empty labels — _claim_bead releases the claim if labels come back empty —
# but NOT story:in-flight/done, so the eligibility guards pass). Everything else
# (label add/remove, comment, tech-debt list) → empty/no-op.
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *blocked*) printf '[]' ;;
  *--all*)   printf '[]' ;;
  *"-t bug"*)
    if [ "${SELFTEST_SCENARIO:-poison}" = "accent" ]; then
      # tt-accent's title carries a raw non-ASCII byte (ú = \xC3\xBA), like ga-jhyu.
      printf '[\n  {"id":"tt-accent","title":"bug ac\xc3\xbamulo fixture","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}\n]'
    else
      # tt-poison is HIGHER priority (P0) → sorts to the head of the small lane.
      cat <<'JSON'
[
  {"id":"tt-poison","title":"Poison bug fixture","priority":0,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}},
  {"id":"tt-healthy","title":"Healthy bug fixture","priority":1,"issue_type":"bug","status":"open","labels":[],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}
]
JSON
    fi
    ;;
  *" show "*)
    id=$(printf '%s' "$args" | awk '{for(i=1;i<=NF;i++) if($i=="show"){print $(i+1); exit}}')
    printf '[{"id":"%s","title":"fixture","priority":0,"issue_type":"bug","status":"open","labels":["pilot:dispatching"],"assignee":null,"created_at":"2026-06-01T00:00:00Z","metadata":{}}]' "$id"
    ;;
  *)
    printf '[]'
    ;;
esac
exit 0
SHIM
chmod +x "$SHIMBIN/bd"

# ── Fake gc ───────────────────────────────────────────────────────────────────
# `sling` FAILS (returns {} — no bead_id) when the title contains the poison id OR
# ANY non-ASCII byte (reproducing the real Dolt "Incorrect string value '\xC3'"
# bead-insert rejection); SUCCEEDS otherwise. `session`/`rig list` are benign no-ops.
cat > "$SHIMBIN/gc" <<'SHIM'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *sling*)
    if printf '%s' "$args" | grep -q 'tt-poison'; then
      printf '{}'                          # poison id → fail (skip+continue case)
    elif printf '%s' "$args" | LC_ALL=C grep -q '[^ -~]'; then
      printf '{}'                          # non-ASCII byte present → Dolt insert fails
    else
      printf '{"bead_id":"sl-ok"}'
    fi
    ;;
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
# Runs the real dispatcher in NON-DRY mode with the shims on PATH; returns the log.
run_dispatch() { # <scenario>
  : > "$FIXCITY/.gc/logs/pilot-dispatcher.log"
  rm -f "$FIXCITY/.gc/pilot-dispatcher.jsonl"
  env -i \
    PATH="$SHIMBIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin" \
    HOME="$HOME" \
    DRY_RUN=0 \
    PILOT_CITY_OVERRIDE="$FIXCITY" \
    SELFTEST_SCENARIO="$1" \
    bash "$DISPATCHER" >/dev/null 2>&1 || true
  cat "$FIXCITY/.gc/logs/pilot-dispatcher.log"
}

echo "pilot-skip-poison.selftest — skip+continue + sling-title ASCII-fold (ga-jjh7w)"

# ── Scenario 1: skip the poison bead, dispatch the healthy one ────────────────
echo "Scenario 1: poison head-of-line fails sling — must skip+continue to tt-healthy"
LOG1="$(run_dispatch poison)"

if echo "$LOG1" | grep -q "gc sling failed for tt-poison"; then
  ok "poison bead tt-poison was attempted and its sling failed (head-of-line)"
else
  bad "expected a failed sling attempt for tt-poison (head pick) — not found"
fi

if echo "$LOG1" | grep -Eq "tt-healthy → story:in-flight"; then
  ok "SKIP+CONTINUE: dispatched the healthy bead tt-healthy after skipping the poison"
else
  bad "REGRESSION: poison bead starved the lane — tt-healthy was NOT dispatched"
fi

if echo "$LOG1" | grep -q "dispatched=1"; then
  ok "exactly one successful dispatch this sweep (cadence preserved)"
else
  bad "expected dispatched=1 (one successful dispatch) — got something else"
fi

if echo "$LOG1" | grep -Eq "tt-poison → story:in-flight"; then
  bad "poison bead tt-poison was wrongly transitioned to story:in-flight"
else
  ok "poison bead was NOT transitioned to story:in-flight (left dispatchable)"
fi

# ── Scenario 2: an accented title must be folded so the bead dispatches ────────
echo "Scenario 2: accented title — must ASCII-fold the sling title so it dispatches"
LOG2="$(run_dispatch accent)"

if echo "$LOG2" | grep -Eq "tt-accent → story:in-flight"; then
  ok "ASCII-FOLD: accented-title bead tt-accent dispatched (sling title folded to ASCII)"
else
  bad "accented-title bead tt-accent was NOT dispatched — fold missing or ineffective"
fi

if echo "$LOG2" | grep -q "gc sling failed for tt-accent"; then
  bad "REGRESSION: tt-accent sling failed — non-ASCII byte reached gc sling unfolded"
else
  ok "no sling failure for tt-accent (title reached gc sling as clean ASCII)"
fi

if echo "$LOG2" | grep -q "dispatched=1"; then
  ok "accented-title bead produced exactly one successful dispatch"
else
  bad "expected dispatched=1 for the accented-title scenario"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
