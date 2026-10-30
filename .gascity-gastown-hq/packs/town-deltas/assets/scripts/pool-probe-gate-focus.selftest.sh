#!/usr/bin/env bash
# pool-probe-gate-focus.selftest.sh — ga-6fkx9je.
#
# The dog's Step 1c probe (pool-probe.sh) takes part in the gate FOCUS MODE (ga-kqa08j): while the gate is the
# bottleneck (gate-focus-mode.sh wrote active=1) a generic builder takes no NEW story, only fixes. The wa/ps worker
# probes already did; this one did not, so a dog was handed (and returned, in a 2 h cycle) a P3 story with the mode ON.
# What it proves, on a fake `bd` (the engine's text knows nothing of the mode, so the script runs alone here;
# pool-probe.selftest.sh pins the mode OFF and proves the rest is still the engine's probe):
#   * ON  -> tier 1 loses the NEW STORIES that are not fixes; formula work (the stale-db cleanup molecule, gc.kind work),
#            fixes and tiers 2/3 keep flowing (a blanket "only fixes" filter would starve the reaper and the orders)
#   * OFF -> exactly the old answer and the old bd calls
#   * unknown (override garbage, lib missing or corrupt, no/corrupt/stale state file) -> the old answer, FAIL OPEN, with a
#            line in the pool-probe log
#   * ON but the hold cannot be built or applied -> tier 1 answers nothing and is marked unreadable (exit 3): inert, loud
#   * the --limit=20 window full of held stories -> ONE refetch with --limit=0 (a fix or a formula bead may wait behind it)
#   * a low disk wins over the mode; the fix-class label list is the same as the Pilot's and the worker prompts'
# Needs bash, jq, sh. Exit 0 iff every check holds. PP_PROBE_UNDER_TEST points at a mutant (the mutant campaign).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${PP_PROBE_UNDER_TEST:-$SELF_DIR/pool-probe.sh}"
FOCUS_LIB="$SELF_DIR/gate-focus-lib.sh"
DISK_LIB="$SELF_DIR/disk-headroom-lib.sh"
SLING_LIB="$SELF_DIR/pool-probe-sling-lib.sh"
CITY_DIR="$SELF_DIR/../../../.."       # .gascity-gastown-hq (scripts -> assets -> town-deltas -> packs -> city)

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
for f in "$PROBE" "$FOCUS_LIB" "$DISK_LIB"; do [ -f "$f" ] || { echo "FATAL: not found: $f"; exit 1; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-focus-selftest.XXXXXX")"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"' EXIT
FAKE="$TMP/bin"; FIX="$TMP/fix"; mkdir -p "$FAKE" "$FIX"

# A fake bd: logs its argv, answers from fixture files. $key.honour-limit cuts the fixture to --limit=N like the real bd
# (0 = unlimited); $key.fail makes the call fail; $key.limit0.fail makes only the unlimited call fail.
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*)   key=tier1 ;;
  "ready --metadata-field gc.run_target="*)  key=legacy ;;
  "list --parent "*)                         key=children ;;
  "query --json "*)                          key=ephemeral ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
[ -f "$BD_FIX/$key.fail" ] && exit 1
lim=""; for a in "$@"; do case "$a" in --limit=*) lim="${a#--limit=}" ;; esac; done
[ "$lim" = 0 ] && [ -f "$BD_FIX/$key.limit0.fail" ] && exit 1
if [ -f "$BD_FIX/$key.json" ]; then
  if [ -f "$BD_FIX/$key.honour-limit" ] && [ -n "$lim" ]; then jq -c --argjson n "$lim" 'if $n > 0 then .[0:$n] else . end' "$BD_FIX/$key.json"
  else cat "$BD_FIX/$key.json"; fi
else printf '[]'; fi
EOF
chmod +x "$FAKE/bd"
reset_fix() { rm -f "$FIX"/*; }

# probe [VAR=val ...] -> P_OUT P_RC P_ERR P_IDS. Starts from a roomy disk, the real libs next to the script under test
# (a mutant copy lives in $TMP, where they are not) and NO mode override: each case says what it wants.
probe() {
  : > "$TMP/pp.log"; : > "$TMP/bd.log"
  P_OUT="$(env -u GATE_FOCUS_ACTIVE_OVERRIDE -u GATE_FOCUS_STATE_FILE BD_LOG="$TMP/bd.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" \
      GC_SESSION_ORIGIN=ephemeral DISK_FREE_OVERRIDE_MB=100000 POOL_PROBE_LOG="$TMP/pp.log" \
      POOL_PROBE_FOCUS_LIB="$FOCUS_LIB" POOL_PROBE_DISK_LIB="$DISK_LIB" POOL_PROBE_SLING_LIB="$SLING_LIB" \
      "$@" sh "$PROBE" gastown.dog 2>"$TMP/err" </dev/null)"; P_RC=$?
  P_ERR="$(cat "$TMP/err")"
  P_IDS="$(printf '%s' "$P_OUT" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
  [ "$P_IDS" = "" ] && P_IDS="-"
  return 0
}
log_has() { grep -q -- "$1" "$TMP/pp.log"; }
tier1_calls() { grep -c 'gc.routed_to=' "$TMP/bd.log" | tr -d ' '; }
ON=GATE_FOCUS_ACTIVE_OVERRIDE=1; OFF=GATE_FOCUS_ACTIVE_OVERRIDE=0

# The shapes of the dog's beads: a NEW story, a fix the gate rejected, formula work with no gc.kind (the molecule of the
# stale-db cleanup) and gc.kind work. Dates make the oldest-updated pick tell them apart.
mixed() {
  cat > "$FIX/tier1.json" <<'EOF'
[
 {"id":"st-old","issue_type":"bug","updated_at":"2026-01-01T00:00:00Z","labels":["story:approved"],"metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"fx-mid","issue_type":"bug","updated_at":"2026-01-02T00:00:00Z","labels":["gate:needs-fix"],"metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"mol-new","issue_type":"molecule","updated_at":"2026-01-04T00:00:00Z","labels":["order-run:mol-dog-stale-db"],"metadata":{"gc.pool_demand":"order","gc.routed_to":"gastown.dog"}},
 {"id":"wf-new","issue_type":"task","updated_at":"2026-01-05T00:00:00Z","labels":[],"metadata":{"gc.kind":"workflow","gc.pool_demand":"order","gc.routed_to":"gastown.dog"}}
]
EOF
}

echo "== 1. the mode OFF: the oldest bead (a story) is handed out, with the old three bd calls"
reset_fix; mixed
probe "$OFF"
eq "OFF: the oldest-updated bead" "$P_IDS" "st-old"
eq "OFF: exit 0, silent" "$P_RC:$P_ERR" "0:"
eq "OFF: nothing held back" "$(grep -c 'held back' "$TMP/pp.log" | tr -d ' ')" "0"
reset_fix
probe "$OFF"
eq "OFF, nothing waiting: [] and the three tiers asked once each" "$P_OUT:$(wc -l < "$TMP/bd.log" | tr -d ' ')" "[]:3"

echo "== 2. the mode ON: the new story is held back, the fix and the formula work flow"
reset_fix; mixed
probe "$ON"
eq "ON: the story (oldest) is skipped, the oldest of the rest is the fix" "$P_IDS" "fx-mid"
eq "ON: exit 0, silent (a hold is an answer, not a doubt)" "$P_RC:$P_ERR" "0:"
log_has 'gate focus mode ON - tier 1 held back 1 new story' && ok "ON: the hold is on the record in the pool-probe log" || bad "ON: no 'held back 1 new story' line in the pool-probe log"
eq "ON: one tier-1 call (the window was not full of held stories)" "$(tier1_calls)" "1"
# only formula work + a story: the story goes, the molecule and the gc.kind bead flow
cat > "$FIX/tier1.json" <<'EOF'
[
 {"id":"st-old","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"mol-new","issue_type":"molecule","updated_at":"2026-01-04T00:00:00Z","labels":["order-run:mol-dog-stale-db"],"metadata":{"gc.pool_demand":"order","gc.routed_to":"gastown.dog"}}
]
EOF
probe "$ON"; eq "ON: the stale-db cleanup molecule (no gc.kind) still flows" "$P_IDS" "mol-new"
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"st-only","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
probe "$ON"
eq "ON, only a new story waiting: []" "$P_OUT" "[]"
eq "ON: …exit 0 and silent: a real 'nothing for you', the dog drains" "$P_RC:$P_ERR" "0:"

echo "== 3. the fix class is exactly the Pilot's and the worker probes' (a label that only looks like one is held)"
# expect|label
LABEL_TABLE='flow|gate:needs-fix
flow|gate:fix-attempt:1
flow|gate:fix-attempt:12
flow|origem:auto-healer-notify
flow|impacto:dano-ao-vivo
held|gate:fix-attempt
held|gate:needs-fix-not
held|gate:needs-fixes
held|gate:needs-human
held|origem:auto-healer
held|impacto:dano
held|impacto:dano-ao-vivo-x
held|story:approved'
while IFS='|' read -r want lab; do
  [ -z "$want" ] && continue
  jq -n --arg l "$lab" '[{"id":"b1","issue_type":"bug","updated_at":"2026-01-01T00:00:00Z","labels":[$l],"metadata":{"gc.routed_to":"gastown.dog"}}]' > "$FIX/tier1.json"
  probe "$ON"
  if [ "$want" = flow ]; then eq "ON: label $lab is a fix, so it flows" "$P_IDS" "b1"; else eq "ON: label $lab is not a fix, so it is held" "$P_IDS" "-"; fi
done <<EOF
$LABEL_TABLE
EOF
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"nolabels","issue_type":"bug","updated_at":"2026-01-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
probe "$ON"; eq "ON: a story with no labels key is held (no labels = not a fix)" "$P_IDS" "-"
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"fx-vetoed","issue_type":"bug","updated_at":"2026-01-01T00:00:00Z","labels":["gate:needs-fix","pilot:held"],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
probe "$ON"; eq "ON: a fix under a pilot hold stays vetoed (the mode never resurrects what the veto filter removed)" "$P_IDS" "-"

echo "== 4. tiers 2 and 3 are formula work and keep flowing under the mode"
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"st-only","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
cat > "$FIX/legacy.json" <<'EOF'
[{"id":"lg-1","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"}}]
EOF
probe "$ON"; eq "ON: tier 1 only has a story, tier 2 answers" "$P_IDS" "lg-1"
rm -f "$FIX/legacy.json"
cat > "$FIX/ephemeral.json" <<'EOF'
[{"id":"eph-1","created_at":"2026-01-01T00:00:00Z","labels":[],"issue_type":"molecule","metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
probe "$ON"; eq "ON: tier 3 (ephemeral) answers when tier 1 only has a story" "$P_IDS" "eph-1"
rm -f "$FIX/ephemeral.json"

echo "== 5. unknown is not off and not on: the old answer (fail OPEN) and a line in the log"
reset_fix; mixed
probe GATE_FOCUS_ACTIVE_OVERRIDE=garbage
eq "override garbage: the old answer, the story is handed out" "$P_IDS" "st-old"
log_has 'gate focus state unreadable' && ok "…and the log says nobody could tell" || bad "…no 'gate focus state unreadable' line in the log"
probe POOL_PROBE_FOCUS_LIB=/nonexistent/gate-focus-lib.sh "$ON"
eq "focus lib missing: the old answer" "$P_IDS" "st-old"
log_has 'gate focus state unreadable' && ok "…logged" || bad "…lib missing was not logged"
printf '%s\n' 'gate_focus_active() { if then' > "$TMP/corrupt-lib.sh"
probe POOL_PROBE_FOCUS_LIB="$TMP/corrupt-lib.sh" "$ON"
eq "focus lib with a syntax error: the probe survives, the old answer" "$P_IDS:$P_RC" "st-old:0"
printf '%s\n' 'gate_focus_active() { printf "%s" 7; }' > "$TMP/seven-lib.sh"
probe POOL_PROBE_FOCUS_LIB="$TMP/seven-lib.sh"
eq "a lib that answers neither 0 nor 1: unknown, the old answer" "$P_IDS" "st-old"
log_has 'gate focus state unreadable' && ok "…logged" || bad "…a 7 was not logged"

echo "== 6. the real state file (no override): ON, OFF, stale, from the future, corrupt, absent"
now="$(date +%s)"
state() { printf 'active=%s\nsince=%s\ndepth=%s\nat=%s\nescalated=0\n' "$1" "$3" "12" "$2" > "$TMP/state"; }
state 1 "$now" "$now"; probe GATE_FOCUS_STATE_FILE="$TMP/state"; eq "active=1, written now: the hold" "$P_IDS" "fx-mid"
state 0 "$now" "$now"; probe GATE_FOCUS_STATE_FILE="$TMP/state"; eq "active=0, written now: as before" "$P_IDS" "st-old"
state 1 "$((now - 7300))" "$((now - 7300))"; probe GATE_FOCUS_STATE_FILE="$TMP/state"
eq "active=1 but older than GATE_FOCUS_STALE_S (nobody re-checked it): unknown, the old answer" "$P_IDS" "st-old"
log_has 'gate focus state unreadable' && ok "…logged" || bad "…a stale state was not logged"
state 1 "$((now + 3600))" "$now"; probe GATE_FOCUS_STATE_FILE="$TMP/state"; eq "a state stamped in the future: unknown, the old answer" "$P_IDS" "st-old"
printf 'active=maybe\nat=%s\n' "$now" > "$TMP/state"; probe GATE_FOCUS_STATE_FILE="$TMP/state"; eq "a corrupt state: unknown, the old answer" "$P_IDS" "st-old"
rm -f "$TMP/state"; probe GATE_FOCUS_STATE_FILE="$TMP/state"; eq "no state file: unknown, the old answer" "$P_IDS" "st-old"
log_has 'gate focus state unreadable' && ok "…logged" || bad "…an absent state was not logged"

echo "== 7. ON but the hold cannot be built or applied: tier 1 answers nothing and says so (exit 3), never 'no work' and never 'go ahead'"
reset_fix; mixed
probe "$ON" POOL_PROBE_DISK_LIB=/nonexistent/disk-headroom-lib.sh
eq "the story definition (disk lib) is missing: no story handed out, exit 3" "$P_IDS:$P_RC" "-:3"
case "$P_ERR" in *"tier(s) 1 unreadable"*) ok "…stderr names tier 1 (the dog must not drain)";; *) bad "…stderr does not name tier 1: $P_ERR";; esac
log_has 'hold could not be applied' && ok "…and the log says why" || bad "…no 'hold could not be applied' line"
sed '/^GATE_FOCUS_FIX_JQ=/d' "$FOCUS_LIB" > "$TMP/nofix-lib.sh"
probe POOL_PROBE_FOCUS_LIB="$TMP/nofix-lib.sh" "$ON" GATE_FOCUS_ACTIVE_OVERRIDE=1
eq "a focus lib with no fix predicate: no story handed out, exit 3" "$P_IDS:$P_RC" "-:3"
sed 's/^GATE_FOCUS_FIX_JQ=.*/GATE_FOCUS_FIX_JQ="any("/' "$FOCUS_LIB" > "$TMP/badjq-lib.sh"
probe POOL_PROBE_FOCUS_LIB="$TMP/badjq-lib.sh" GATE_FOCUS_ACTIVE_OVERRIDE=1
eq "a fix predicate jq cannot compile: no story handed out, exit 3" "$P_IDS:$P_RC" "-:3"
case "$P_ERR" in *"tier(s) 1 unreadable"*) ok "…stderr names tier 1";; *) bad "…stderr does not name tier 1: $P_ERR";; esac
cat > "$FIX/legacy.json" <<'EOF'
[{"id":"lg-1","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"}}]
EOF
probe "$ON" POOL_PROBE_DISK_LIB=/nonexistent/disk-headroom-lib.sh
eq "…but formula work in tier 2 still answers (exit 0)" "$P_IDS:$P_RC" "lg-1:0"
rm -f "$FIX/legacy.json"

echo "== 8. the --limit=20 window full of held stories: ONE refetch without a limit finds the fix / the formula bead behind it"
S20="$(jq -n '[range(1;21) | {id:("s\(.)"),issue_type:"bug",updated_at:("2026-01-\(10+.)T00:00:00Z"),labels:[],metadata:{"gc.routed_to":"gastown.dog"}}]')"
printf '%s' "$S20" | jq -c '. + [{"id":"fx-late","issue_type":"bug","updated_at":"2026-03-01T00:00:00Z","labels":["gate:fix-attempt:2"],"metadata":{"gc.routed_to":"gastown.dog"}}]' > "$FIX/tier1.json"
: > "$FIX/tier1.honour-limit"
probe "$ON"
eq "20 stories fill the window, the fix is behind it: the refetch finds the fix" "$P_IDS" "fx-late"
eq "…two tier-1 calls" "$(tier1_calls)" "2"
grep -c -- '--limit=0' "$TMP/bd.log" | { read -r n; eq "…the second one is --limit=0" "$n" "1"; }
log_has 'refetched without a limit' && ok "…on the record" || bad "…no 'refetched without a limit' line"
touch "$FIX/tier1.limit0.fail"
probe "$ON"
eq "the unlimited refetch fails: no answer from tier 1 and exit 3 (never 'no work')" "$P_IDS:$P_RC" "-:3"
rm -f "$FIX/tier1.limit0.fail"
printf '%s' "$S20" | jq -c '.[0:3]' > "$FIX/tier1.json"
probe "$ON"
eq "3 stories (the window is not full): [] with no refetch" "$P_OUT:$(tier1_calls)" "[]:1"
printf '%s' "$S20" > "$FIX/tier1.json"
probe "$ON"
eq "exactly 20 stories and nothing behind them: the refetch runs once and finds nothing: []" "$P_OUT:$(tier1_calls):$P_RC" "[]:2:0"
rm -f "$FIX/tier1.honour-limit"

echo "== 9. a low disk wins over the mode (it holds the fixes too, as it always did); the mode does not add a second hold"
reset_fix; mixed
probe "$ON" DISK_FREE_OVERRIDE_MB=3000
eq "disk low + mode ON: only the formula work is handed out (the fix is held by the disk, as before)" "$P_IDS" "mol-new"
log_has 'free disk under the floor - tier 1 held back 2 new story' && ok "…the disk's own line" || bad "…no disk line"
log_has 'gate focus mode ON' && bad "…the mode logged a second hold on a low disk" || ok "…and no second hold from the mode"
probe "$OFF" DISK_FREE_OVERRIDE_MB=3000
eq "disk low + mode OFF: the same (the disk alone)" "$P_IDS" "mol-new"

echo "== 10. the fix-class list is the same text the Pilot and the worker prompts carry"
want_text="$(. "$FOCUS_LIB" && printf '%s' "$GATE_FOCUS_FIX_JQ")"
[ -n "$want_text" ] && ok "the lib gives GATE_FOCUS_FIX_JQ" || bad "GATE_FOCUS_FIX_JQ is empty"
for f in "$SELF_DIR/../pilot-dispatcher.sh" "$CITY_DIR/agents/wa-worker/prompt.template.md" "$CITY_DIR/agents/ps-worker/prompt.template.md"; do
  if [ ! -f "$f" ]; then bad "cannot compare: $f is missing"; continue; fi
  if grep -qF -- "$want_text" "$f"; then ok "$(basename "$f"): carries the same predicate"; else bad "$(basename "$f"): its fix-class list differs from GATE_FOCUS_FIX_JQ — change them together"; fi
done

echo "== 11. the file itself"
if bash -n "$PROBE" 2>/dev/null && sh -n "$PROBE" 2>/dev/null; then ok "pool-probe.sh parses under bash -n and sh -n"; else bad "syntax error in pool-probe.sh"; fi
if grep -E '(^|[^[:alnum:]_])(rm|rmdir|unlink|shred|truncate)([^[:alnum:]_]|$)' <(grep -v '^[[:space:]]*#' "$PROBE") >/dev/null; then bad "the probe mentions a removal command"; else ok "no removal command outside comments"; fi

echo
echo "pool-probe-gate-focus: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
