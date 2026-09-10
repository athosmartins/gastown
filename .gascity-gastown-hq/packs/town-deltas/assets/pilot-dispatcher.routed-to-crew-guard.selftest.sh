#!/usr/bin/env bash
# pilot-dispatcher.routed-to-crew-guard.selftest.sh — unit tests for
# _pilot_routed_to_pool_guard and _pilot_crew_stale_reclaim (ga-c9qj8).
#
# Bug ga-c9qj8: wa-vm94r (gc.routed_to=wa-worker, i.e. already POOL-committed
# by a prior sweep) was dispatched via the rig-native path's crew `*)` arm to
# batista-wa — a LIVE named crew that never runs RoutedPoolQuery/pool-hook
# self-serve. Nothing in dispatch_one()'s existing ownership guards (ga-htjni,
# ga-sndpm — both answer "does someone ELSE already own this dispatch
# attempt", not "was this bead already promised to the pool") catches the
# mismatch. The bead sat assigned+in_progress for ~3h; Stage 1's existing
# stale-in-flight detector only frees the LANE-CAPACITY COUNT ("NOT counted
# as live occupants, freeing their slot(s)") — it never touches the bead
# itself, so the stuck assignment survives indefinitely.
#
# Two independent fixes, two independent functions:
#   1. _pilot_routed_to_pool_guard  — refuses a crew-arm dispatch when the
#      bead already carries gc.routed_to=<pool-identity>.
#   2. _pilot_crew_stale_reclaim    — reclaims (unassigns + clears
#      story:in-flight) a stale in-flight bead whose assignee is a named
#      crew AND for which no crew/fix branch exists anywhere (never
#      engaged) — narrower than "any stale+crew-assigned bead" on purpose,
#      see its own header comment in the live file.
#
# Falsifiable: neither function exists before this fix, so the awk
# extraction below fails hard (FATAL, exit 2) against pre-fix HEAD — this
# selftest cannot pass without the fix landed.
#
# This harness follows the same conventions as its siblings in this
# directory: verbatim function extraction (pilot-dispatcher.sling-reuse-
# suppress.selftest.sh's pattern) + a real PATH-stubbed `bd` that logs every
# mutation (dog-pool-preflight-reclaim.selftest.sh's pattern, since `bd` is
# invoked as a bare external command in both functions under test — a shell-
# function override would not survive if a future edit wraps either call in
# `timeout`, so match the more robust convention used elsewhere in this file).
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.routed-to-crew-guard.selftest.sh
# Exit 0 iff every scenario behaves as expected.

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

# ── Extract both functions verbatim from the live file ─────────────────────
extract_fn() {
  local _name="$1"
  awk "/^${_name}\\(\\)/{f=1} f{print} f&&/^}\$/{exit}" "$DISPATCHER"
}
GUARD_FN="$(extract_fn '_pilot_routed_to_pool_guard')"
RECLAIM_FN="$(extract_fn '_pilot_crew_stale_reclaim')"
if [ -z "$GUARD_FN" ]; then
  echo "FATAL: _pilot_routed_to_pool_guard() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi
if [ -z "$RECLAIM_FN" ]; then
  echo "FATAL: _pilot_crew_stale_reclaim() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi
# _pilot_crew_stale_reclaim calls _beadid_branch_signal as a plain shell
# function (no timeout wrapper) — override it with a test double rather than
# extracting the real one, which would otherwise need a full git-repo sandbox.
# _pilot_routed_to_pool_guard has no such dependency.

# ── Sandbox helpers ─────────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-routed-to-crew-guard-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# fake_bd_show <routed_to_value|FAIL|GARBAGE> — bd stub for the guard test:
# answers `show --json` with a single-object array carrying the given
# gc.routed_to metadata value; any other subcommand is a silent no-op.
fake_bd_show() {
  local _mode="$1" _dir
  _dir="$(mktemp -d "$WORK/bin.XXXXXX")"
  # The real call is `bd -C "$_city" show "$_bid" --json` — "show" is
  # somewhere in the argv, not necessarily $1 (that's the -C flag). Scan all
  # args instead of assuming position.
  case "$_mode" in
    FAIL)
      cat > "$_dir/bd" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "show" ] && { echo "boom" >&2; exit 1; }; done
exit 0
EOF
      ;;
    GARBAGE)
      cat > "$_dir/bd" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "show" ] && { echo "not json at all"; exit 0; }; done
exit 0
EOF
      ;;
    *)
      cat > "$_dir/bd" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "show" ]; then
    printf '[{"id":"story-x","metadata":{"gc.routed_to":"%s"}}]'  "$_mode"
    exit 0
  fi
done
exit 0
EOF
      ;;
  esac
  chmod +x "$_dir/bd"
  printf '%s' "$_dir"
}

echo "pilot-dispatcher.routed-to-crew-guard.selftest — ga-c9qj8"
echo ""
echo "=== Part A: _pilot_routed_to_pool_guard ==="

run_guard() { # run_guard <bd_mode> <bead_id> <city> <sling_target>
  local _bd_mode="$1" _bid="$2" _city="$3" _target="$4" _bin
  _bin=$(fake_bd_show "$_bd_mode")
  PATH="$_bin:$PATH" bash -c "$GUARD_FN"'
_pilot_routed_to_pool_guard "'"$_bid"'" "'"$_city"'" "'"$_target"'"'
}

# Scenario A: pool-committed (wa-worker) + resolved crew target → REFUSE
out=$(run_guard "wa-worker" "wa-vm94r" "wa" "batista-wa"); rc=$?
if [ "$rc" = "0" ] && [ "$out" = "routed_to:wa-worker" ]; then
  ok "gc.routed_to=wa-worker + crew target 'batista-wa' -> REFUSE (routed_to:wa-worker) — the measured wa-vm94r shape"
else
  bad "gc.routed_to=wa-worker + crew target -> expected REFUSE 'routed_to:wa-worker', got rc=$rc out='$out'"
fi

# Scenario B: pool-committed (ps-worker) + crew target → REFUSE
out=$(run_guard "ps-worker" "ps-x" "ps" "some-ps-crew"); rc=$?
if [ "$rc" = "0" ] && [ "$out" = "routed_to:ps-worker" ]; then
  ok "gc.routed_to=ps-worker + crew target -> REFUSE (routed_to:ps-worker)"
else
  bad "gc.routed_to=ps-worker + crew target -> expected REFUSE, got rc=$rc out='$out'"
fi

# Scenario C: pool-committed (gastown.dog) + crew target → REFUSE
out=$(run_guard "gastown.dog" "ga-x" "hq" "some-crew"); rc=$?
if [ "$rc" = "0" ] && [ "$out" = "routed_to:gastown.dog" ]; then
  ok "gc.routed_to=gastown.dog + crew target -> REFUSE (routed_to:gastown.dog)"
else
  bad "gc.routed_to=gastown.dog + crew target -> expected REFUSE, got rc=$rc out='$out'"
fi

# Scenario D: no prior routing + crew target → PROCEED (the ordinary,
# legitimate rig-native crew dispatch must keep working unchanged).
out=$(run_guard "" "wa-normal" "wa" "mila-wa"); rc=$?
if [ "$rc" = "1" ] && [ -z "$out" ]; then
  ok "no gc.routed_to + crew target -> PROCEED (ordinary crew dispatch unaffected)"
else
  bad "no gc.routed_to + crew target -> expected PROCEED (rc=1, empty), got rc=$rc out='$out'"
fi

# Scenario E: pool-committed metadata but target IS the pool (self-consistent
# — e.g. a fresh sweep correctly re-targeting the same pool) → PROCEED.
# Self-contained short-circuit: must never refuse a genuinely pool-bound
# dispatch just because stale-looking metadata happens to agree with it.
out=$(run_guard "wa-worker" "wa-y" "wa" "wa-worker-3"); rc=$?
if [ "$rc" = "1" ] && [ -z "$out" ]; then
  ok "gc.routed_to=wa-worker + POOL target 'wa-worker-3' -> PROCEED (self-consistent, not the bug shape)"
else
  bad "gc.routed_to=wa-worker + pool target -> expected PROCEED, got rc=$rc out='$out'"
fi

# Scenario F: bd show fails outright → fail-open, PROCEED, never crash.
out=$(run_guard "FAIL" "wa-z" "wa" "batista-wa"); rc=$?
if [ "$rc" = "1" ] && [ -z "$out" ]; then
  ok "bd show failure -> fails open to PROCEED (never blocks dispatch on a probe error)"
else
  bad "bd show failure -> expected fail-open PROCEED, got rc=$rc out='$out'"
fi

# Scenario G: bd show returns garbage JSON → fail-open, PROCEED, no crash
# under set -u.
out=$(run_guard "GARBAGE" "wa-g" "wa" "batista-wa"); rc=$?
if [ "$rc" = "1" ] && [ -z "$out" ]; then
  ok "garbage JSON from bd show -> fails open to PROCEED without crashing"
else
  bad "garbage JSON -> expected fail-open PROCEED, got rc=$rc out='$out'"
fi

# Scenario H: kill switch PILOT_ROUTED_TO_GUARD=0 disables the CALL SITE
# (structural — the function itself has no kill-switch check; the call site
# in dispatch_one() gates it). Verify the wiring exists.
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has 'PILOT_ROUTED_TO_GUARD:-1'                                              "call site respects PILOT_ROUTED_TO_GUARD kill switch (default on)"
has '_pilot_routed_to_pool_guard "\$STORY_ID" "\$STORY_BEAD_CITY" "\$_SLING_TARGET"' "call site invokes the guard with STORY_ID/STORY_BEAD_CITY/_SLING_TARGET"
has 'DISPATCH_RESULT="rig_native_pool_target_only"'                          "refusal is attributed to a distinct DISPATCH_RESULT (rig_native_pool_target_only)"
# Ordering: the guard call must appear BEFORE the --assignee write in the
# SAME crew arm, else it refuses too late (bead already assigned to crew).
if awk '/_pilot_routed_to_pool_guard "\$STORY_ID"/{g=NR} /--assignee "\$_SLING_TARGET" --status in_progress/{a=NR} END{exit !(g && a && g<a)}' "$DISPATCHER"; then
  ok "guard call precedes the crew --assignee write (refuses BEFORE assigning, not after)"
else
  bad "REGRESSION: guard call does not precede the crew --assignee write — ordering may have drifted"
fi

echo ""
echo "=== Part B: _pilot_crew_stale_reclaim ==="

# fresh/stale ISO8601 timestamps (portable via python3, same convention as
# dog-pool-preflight-reclaim.selftest.sh's date math).
STALE_TS="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
FRESH_TS="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
CUTOFF="$(python3 -c 'import datetime;print(int((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).timestamp()))')"

# fake_bd_mutate — bd stub for the reclaim test: logs every label/assign/
# update call to $MUT (dropping the leading `-C <city>` so log lines read
# "MUT <verb> <args...>", matching the assertions below), answers everything
# else as a silent no-op.
MUT="$WORK/mutations.log"
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/bd" <<EOF
#!/usr/bin/env bash
# real calls are: bd -C <city> <verb> <args...> — the verb is \$3, not \$1
if [ "\$1" = "-C" ]; then shift 2; fi
case "\$1" in
  label|assign|update) echo "MUT \$*" >>"$MUT" ;;
esac
exit 0
EOF
chmod +x "$BIN/bd"

# run_reclaim <in_flight_json> <branch_beads_space_list> [extra_env] — runs
# the extracted function with stub _beadid_branch_signal + _ownership_guard_
# repos + warn (the real ones are top-level helpers defined elsewhere in the
# file, not part of the extracted function): any bead id listed in
# TEST_HAS_BRANCH is reported as an existing (blocking) branch; everything
# else reports "no branch" (empty), matching the real function's exit-1/
# empty-output "no signal" contract. _ownership_guard_repos succeeds by
# default (TEST_REPOS_OK=1) — pass extra_env="TEST_REPOS_OK=0" to simulate
# the branch-probe infrastructure itself being down (ga-c9qj8 third state).
run_reclaim() {
  local _json="$1" _has_branch="$2" _extra_env="${3:-}"
  : >"$MUT"
  # _extra_env listed LAST so a caller-supplied override (e.g. TEST_REPOS_OK=0)
  # wins over the defaults to its left — env applies assignments in order and
  # the last one for a given name wins.
  env TEST_HAS_BRANCH="$_has_branch" PATH="$BIN:$PATH" $_extra_env bash -c "
warn() { :; }
_ownership_guard_repos() { [ \"\${TEST_REPOS_OK:-1}\" = \"1\" ]; }
_beadid_branch_signal() {
  case \" \$TEST_HAS_BRANCH \" in
    *\" \$1 \"*) printf 'block\\tfix/%s-test' \"\$1\" ;;
    *) return 1 ;;
  esac
}
$RECLAIM_FN
_pilot_crew_stale_reclaim '$_json' '$CUTOFF'
"
}

# Scenario 1 (the incident): stale + crew assignee + NO branch -> RECLAIMED.
J1=$(jq -n --arg id "wa-vm94r" --arg a "batista-wa" --arg u "$STALE_TS" --arg db "wa" \
  '[{id:$id, assignee:$a, updated_at:$u, _rig_db:$db}]')
run_reclaim "$J1" ""
if grep -q '^MUT label remove wa-vm94r story:in-flight' "$MUT" \
   && grep -q '^MUT assign wa-vm94r' "$MUT"; then
  ok "stale + crew assignee + no branch -> RECLAIMED (unassigned, story:in-flight cleared) — reproduces the wa-vm94r fix"
else
  bad "stale + crew assignee + no branch -> expected reclaim mutations, got: $(cat "$MUT" 2>/dev/null | tr '\n' '|')"
fi
if grep -q '^MUT label remove wa-vm94r pilot:dispatched' "$MUT" \
   && grep -q '^MUT label remove wa-vm94r pilot:dispatching' "$MUT" \
   && grep -q '^MUT update wa-vm94r --unset-metadata pilot.dispatched_at' "$MUT" \
   && grep -q '^MUT update wa-vm94r --unset-metadata pilot.dispatching_at' "$MUT" \
   && grep -q '^MUT update wa-vm94r --unset-metadata pilot.sling_bead' "$MUT"; then
  ok "reclaim strips the FULL pilot fingerprint (dispatched/dispatching labels + all 3 pilot.* metadata) — else ga-zzrts(c) would strand it a second way"
else
  bad "reclaim did not strip the full pilot fingerprint: $(cat "$MUT" 2>/dev/null | tr '\n' '|')"
fi

# Scenario 2: stale + POOL-worker assignee -> NOT this function's job (Stage 2 owns it).
J2=$(jq -n --arg id "wa-pool1" --arg a "wa-worker-3" --arg u "$STALE_TS" --arg db "wa" \
  '[{id:$id, assignee:$a, updated_at:$u, _rig_db:$db}]')
run_reclaim "$J2" ""
if [ -s "$MUT" ]; then
  bad "stale + pool-worker assignee -> REGRESSION: mutated (out of scope — Stage 2 owns pool-worker staleness)"
else
  ok "stale + pool-worker assignee -> no mutation (correctly out of scope)"
fi

# Scenario 3: stale + crew assignee + a branch DOES exist (live/unmerged work) -> LEFT ALONE.
J3=$(jq -n --arg id "wa-midbuild" --arg a "mila-wa" --arg u "$STALE_TS" --arg db "wa" \
  '[{id:$id, assignee:$a, updated_at:$u, _rig_db:$db}]')
run_reclaim "$J3" "wa-midbuild"
if [ -s "$MUT" ]; then
  bad "stale + crew assignee + LIVE branch -> REGRESSION: reclaimed anyway (double-dispatch risk over real in-progress work)"
else
  ok "stale + crew assignee + live branch found -> NOT reclaimed (conservative: some work artifact exists, leave it)"
fi

# Scenario 4: NOT stale (fresh updated_at) + crew assignee -> LEFT ALONE.
J4=$(jq -n --arg id "wa-fresh" --arg a "batista-wa" --arg u "$FRESH_TS" --arg db "wa" \
  '[{id:$id, assignee:$a, updated_at:$u, _rig_db:$db}]')
run_reclaim "$J4" ""
if [ -s "$MUT" ]; then
  bad "fresh (non-stale) + crew assignee -> REGRESSION: reclaimed a bead that is not even stale yet"
else
  ok "fresh (non-stale) + crew assignee -> no mutation (age cutoff respected)"
fi

# Scenario 5: kill switch PILOT_CREW_STALE_RECLAIM=0 -> no mutation even for
# the exact incident shape.
run_reclaim "$J1" "" "PILOT_CREW_STALE_RECLAIM=0"
if [ -s "$MUT" ]; then
  bad "PILOT_CREW_STALE_RECLAIM=0 -> REGRESSION: mutated despite kill switch"
else
  ok "PILOT_CREW_STALE_RECLAIM=0 -> no mutation (kill switch respected)"
fi

# Scenario 6: empty assignee (should never be in a real in-flight set, but
# defensive) -> no mutation, no crash.
J6=$(jq -n --arg id "wa-noassg" --arg a "" --arg u "$STALE_TS" --arg db "wa" \
  '[{id:$id, assignee:$a, updated_at:$u, _rig_db:$db}]')
run_reclaim "$J6" ""
if [ -s "$MUT" ]; then
  bad "stale + empty assignee -> REGRESSION: mutated a bead with no assignee at all"
else
  ok "stale + empty assignee -> no mutation (defensive; jq filter excludes it)"
fi

# Scenario 7: multiple beads in one call — only the reclaimable one mutates.
J7=$(jq -n --arg id1 "wa-vm94r" --arg a1 "batista-wa" --arg u1 "$STALE_TS" --arg db1 "wa" \
           --arg id2 "wa-pool1" --arg a2 "wa-worker-2" --arg u2 "$STALE_TS" --arg db2 "wa" \
  '[{id:$id1, assignee:$a1, updated_at:$u1, _rig_db:$db1},
    {id:$id2, assignee:$a2, updated_at:$u2, _rig_db:$db2}]')
run_reclaim "$J7" ""
if grep -q '^MUT assign wa-vm94r' "$MUT" && ! grep -q 'wa-pool1' "$MUT"; then
  ok "mixed batch -> only the crew-assigned/no-branch bead is touched, the pool-assigned sibling is untouched"
else
  bad "mixed batch -> expected only wa-vm94r touched, got: $(cat "$MUT" 2>/dev/null | tr '\n' '|')"
fi

# Scenario 8 (third-state self-audit, ga-c9qj8): the branch-probe
# infrastructure itself is down (_ownership_guard_repos fails, e.g. `gc rig
# list` unreachable) -> the ENTIRE sweep must be skipped, NEVER treated as
# "no branch found anywhere". Same exact incident shape as Scenario 1 (would
# otherwise reclaim) — the only difference is the probe's own health.
run_reclaim "$J1" "" "TEST_REPOS_OK=0"
if [ -s "$MUT" ]; then
  bad "branch-probe infra down -> REGRESSION: reclaimed anyway (collapsed 'could not check' into 'no branch found' — the third-state bug this fix exists to avoid)"
else
  ok "branch-probe infra down -> sweep skipped entirely, no mutation (cannot distinguish 'no branch' from 'could not check', so treats it as unknown -> inert)"
fi

# Drift-guards — call site wiring in the main sweep.
has 'PILOT_CREW_STALE_RECLAIM:-1'                       "reclaim function respects PILOT_CREW_STALE_RECLAIM kill switch (default on)"
has '_pilot_crew_stale_reclaim "\$IN_FLIGHT_RAW_JSON" "\$_STUCK_CUTOFF"' "main sweep calls the reclaim function with IN_FLIGHT_RAW_JSON + the Stage-1 cutoff"
has '! _ownership_guard_repos >/dev/null; then'         "reclaim function gates on _ownership_guard_repos before trusting any branch-signal result (third-state guard)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.routed-to-crew-guard.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
