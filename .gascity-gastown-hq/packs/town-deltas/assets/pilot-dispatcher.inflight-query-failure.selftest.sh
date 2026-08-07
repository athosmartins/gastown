#!/usr/bin/env bash
# pilot-dispatcher.inflight-query-failure.selftest.sh — regression harness for
# ga-1fssl: the Pilot's per-lane capacity counter (Step 1, "story:in-flight")
# read a FAILED bd query the same way it read a genuinely empty one —
# `2>/dev/null || echo "[]"` collapses both to the same "[]" value. That JSON
# feeds IN_FLIGHT_SMALL/IN_FLIGHT_BIG, which feed SMALL_SLOTS/BIG_SLOTS
# (MAX_SMALL - in_flight, MAX_BIG - in_flight): a failed query therefore read
# as "0 beads in flight" -> "every slot free" -> Pilot DISPATCHES onto lanes
# it never actually verified were free. Root class: ga-qj1xh, same conflation
# already fixed in quality-gate-guard.sh's shared gate-runs query — this file
# proves the same fix landed on the query that gates dispatch itself.
#
# ACEITE (ga-1fssl, verbatim): "com o bd list de story:in-flight falhando
# (simule com um bd que sai != 0), o Pilot NAO despacha e loga que nao pode
# decidir. Teste tem que cobrir os tres casos: ha beads em voo, nao ha,
# consulta falhou. E --limit 0 na consulta."
#
# Three sections:
#   1. Unit tests on the extracted pure function inflight_slots_from_query —
#      the three ACEITE cases plus the floor behavior.
#   2. Drift guards — grep the real file to confirm the fetch sites and the
#      SMALL_SLOTS/BIG_SLOTS wiring actually use the fix, not just that the
#      function exists unused.
#   3. End-to-end: the ACTUAL shipped Step-1 fetch block (extracted verbatim,
#      not retyped) run as a real child process with a real failing `bd` on
#      PATH — proves the wiring from "bd exits non-zero" through to
#      IN_FLIGHT_QUERY_OK=0 / IN_FLIGHT_RAW_JSON="[]" / a warn actually fires,
#      for both the HQ fetch and the per-rig fan-out fetch. Same extraction
#      philosophy as pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh:
#      this can't silently drift from the shipped code.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$HERE/pilot-dispatcher.sh"

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# extract_fn <name> <file> — prints a top-level `name() { ... }` function
# body. Same helper as pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh.
extract_fn() {
  awk -v fn="$1" '
    $0 == fn"() {" { p=1 }
    p { print; if ($0 == "}") exit }
  ' "$2"
}

# extract_block <start_substr> <end_substr> <file> — prints the inclusive
# line range from the first line CONTAINING start_substr through the next
# line matching end_substr exactly (trimmed). Used to pull the real Step-1
# in-flight fetch — top-level script code, not a function — verbatim out of
# the shipped dispatcher for the end-to-end section.
extract_block() {
  awk -v s="$1" -v e="$2" '
    index($0, s) { p=1 }
    p { print; if (index($0, e)) exit }
  ' "$3"
}

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== pilot-dispatcher.inflight-query-failure.selftest (ga-1fssl) =="

# ═════════════════════════════════════════════════════════════════════════
# 1. inflight_slots_from_query — the three ACEITE cases + floor behavior.
# ═════════════════════════════════════════════════════════════════════════
echo "-- 1. inflight_slots_from_query (ga-1fssl: query-failure fail-safe) --"

_fn_src="$(extract_fn inflight_slots_from_query "$DISPATCHER")"
if [ -z "$_fn_src" ]; then
  echo "FATAL: inflight_slots_from_query() not found in $DISPATCHER — extraction failed" >&2
  exit 2
fi
eval "$_fn_src"
if ! type inflight_slots_from_query >/dev/null 2>&1; then
  echo "FATAL: extraction ran but did not define a callable inflight_slots_from_query" >&2
  exit 2
fi

eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (got '$got', want '$want')"; fi
}

# "ha beads em voo": query ok, some in-flight -> normal subtraction.
eq "ha beads em voo: query ok, max=5 in_flight=2 -> 3 slots free" \
   "$(inflight_slots_from_query 1 5 2)" "3"

# "nao ha": query ok, genuinely zero in-flight -> full capacity free.
eq "nao ha: query ok, max=5 in_flight=0 -> 5 slots free (genuine empty, unchanged)" \
   "$(inflight_slots_from_query 1 5 0)" "5"

# floor: query ok but in_flight exceeds max (stale overcounts etc) -> 0, not negative.
eq "floor: query ok, max=5 in_flight=7 -> 0 slots (never negative)" \
   "$(inflight_slots_from_query 1 5 7)" "0"

# "consulta falhou": THE bug. Query failed but the (untrustworthy) in-flight
# count computed from partial/empty data happens to read as 0 — must NOT
# report full capacity free.
eq "consulta falhou (in_flight read as 0): query FAILED -> 0 slots, not max (fail-safe, ga-1fssl)" \
   "$(inflight_slots_from_query 0 5 0)" "0"

# Same failure, but with a non-zero in_flight count too — must still floor to
# 0 regardless of what the untrustworthy count says.
eq "consulta falhou (in_flight read as nonzero): query FAILED -> 0 slots regardless of count" \
   "$(inflight_slots_from_query 0 5 3)" "0"

# ═════════════════════════════════════════════════════════════════════════
# Regression guard: on failure, slots must NEVER exceed 0 — assert this
# explicitly across several max_slots/in_flight combinations so a future
# refactor that reverts to raw subtraction fails loudly here.
# ═════════════════════════════════════════════════════════════════════════
echo "-- regression guard: query_ok=0 never yields slots > 0 --"
_guard_ok=1
for combo in "5 0" "5 3" "2 0" "10 0" "1 0"; do
  set -- $combo
  _r="$(inflight_slots_from_query 0 "$1" "$2")"
  if [ "$_r" != "0" ]; then
    bad "REGRESSION: inflight_slots_from_query 0 $1 $2 -> '$_r', expected 0 (the ga-1fssl bug is back)"
    _guard_ok=0
  fi
done
[ "$_guard_ok" -eq 1 ] && ok "REGRESSION GUARD: query failure never yields free slots, across all max_slots/in_flight combos tried"

# ═════════════════════════════════════════════════════════════════════════
# 2. Drift guards — the real file must actually WIRE the fix, not just
#    define an unused function.
# ═════════════════════════════════════════════════════════════════════════
echo "-- 2. drift guards: the fix is actually wired into the shipped file --"

grep -q 'inflight_slots_from_query()' "$DISPATCHER" \
  && ok "guard defines inflight_slots_from_query (ga-1fssl)" \
  || bad "guard missing inflight_slots_from_query def"

grep -qE 'if ! _IN_FLIGHT_HQ=\$\(bd -C "\$GC_CITY" list --json -l "story:in-flight" -n 0' "$DISPATCHER" \
  && ok "HQ story:in-flight fetch captures bd's exit status via if!/then (not '|| echo \"[]\"' masking), with -n 0" \
  || bad "HQ story:in-flight fetch no longer uses the if!/then rc-capture idiom with -n 0 — may have reverted to error/empty conflation (ga-1fssl)"

grep -qE 'if ! _rig_inflight=\$\(bd -C "\$_in_flight_rig" list --json -l "story:in-flight" -n 0' "$DISPATCHER" \
  && ok "per-rig story:in-flight fetch captures bd's exit status via if!/then, with -n 0" \
  || bad "per-rig story:in-flight fetch no longer uses the if!/then rc-capture idiom with -n 0 — may have reverted (ga-1fssl)"

[ "$(grep -c 'IN_FLIGHT_QUERY_OK=0' "$DISPATCHER")" -ge 2 ] \
  && ok "IN_FLIGHT_QUERY_OK=0 is set on BOTH the HQ-fetch failure branch and the per-rig-fetch failure branch" \
  || bad "IN_FLIGHT_QUERY_OK=0 appears fewer than 2 times — the HQ or the per-rig failure branch may not taint the flag"

grep -q 'IN_FLIGHT_QUERY_OK=1' "$DISPATCHER" \
  && ok "IN_FLIGHT_QUERY_OK initialized to 1 (success default before any fetch runs)" \
  || bad "guard missing IN_FLIGHT_QUERY_OK=1 initialization"

grep -q 'story:in-flight query failed for HQ' "$DISPATCHER" \
  && ok "guard logs a warning when the HQ story:in-flight query fails (ga-1fssl: 'loga que não pode decidir')" \
  || bad "guard does not log the HQ story:in-flight query failure"

grep -q 'story:in-flight query failed for rig db' "$DISPATCHER" \
  && ok "guard logs a warning when a per-rig story:in-flight query fails" \
  || bad "guard does not log the per-rig story:in-flight query failure"

grep -qE 'SMALL_SLOTS=\$\(inflight_slots_from_query "\$IN_FLIGHT_QUERY_OK" "\$MAX_SMALL" "\$IN_FLIGHT_SMALL"\)' "$DISPATCHER" \
  && ok "SMALL_SLOTS is computed via inflight_slots_from_query, wired to IN_FLIGHT_QUERY_OK" \
  || bad "SMALL_SLOTS no longer routes through inflight_slots_from_query — may have reverted to raw subtraction (ga-1fssl)"

grep -qE 'BIG_SLOTS=\$\(inflight_slots_from_query "\$IN_FLIGHT_QUERY_OK" "\$MAX_BIG" "\$IN_FLIGHT_BIG"\)' "$DISPATCHER" \
  && ok "BIG_SLOTS is computed via inflight_slots_from_query, wired to IN_FLIGHT_QUERY_OK" \
  || bad "BIG_SLOTS no longer routes through inflight_slots_from_query — may have reverted to raw subtraction (ga-1fssl)"

[ "$(grep -c '_IN_FLIGHT_HQ=\$(bd -C "\$GC_CITY" list' "$DISPATCHER")" -eq 1 ] \
  && ok "HQ story:in-flight fetched exactly once (no duplicate bd round-trip introduced)" \
  || bad "HQ story:in-flight fetch count != 1 (duplicate-fetch regression)"

# ═════════════════════════════════════════════════════════════════════════
# 3. End-to-end: the ACTUAL shipped Step-1 fetch block, extracted verbatim,
#    run as a real child bash process (this harness itself runs under
#    `set -uo pipefail`, no -e, so it can't observe the dispatcher's own
#    `set -euo pipefail` semantics just by sourcing in-process) with a real
#    failing/succeeding `bd` on PATH.
# ═════════════════════════════════════════════════════════════════════════
echo "-- 3. end-to-end: real Step-1 fetch block reacts correctly to a real bd on PATH --"

_block_src="$(extract_block \
  '# ga-mfeip: fan-out to HQ + every non-HQ rig store' \
  'unset _IN_FLIGHT_HQ _in_flight_rig_paths _in_flight_rig _rig_inflight _in_flight_rig_json' \
  "$DISPATCHER")"
_setline="$(grep -n '^set -' "$DISPATCHER" | head -1 | cut -d: -f2-)"
_gjou_src="$(extract_fn gc_json_or_unknown "$DISPATCHER")"

if [ -z "$_block_src" ] || [ -z "$_setline" ] || [ -z "$_gjou_src" ]; then
  bad "FATAL: could not extract the Step-1 fetch block / set-line / gc_json_or_unknown from $DISPATCHER — cannot run section 3"
else
  SANDBOX_BIN="$(mktemp -d)"
  FAKE_CITY="$(mktemp -d)"
  # A `gc` that reports zero non-HQ rigs — isolates sub-scenarios A/B/C to
  # the HQ fetch only. Scenario D below swaps this for a `gc` that reports
  # one rig, to exercise the per-rig fetch branch too.
  cat > "$SANDBOX_BIN/gc" <<'EOF'
#!/usr/bin/env bash
echo '{"schema_version":"1","ok":true,"rigs":[]}'
exit 0
EOF
  chmod +x "$SANDBOX_BIN/gc"

  run_block() {
    # $1: bd script body (becomes $SANDBOX_BIN/bd). $2: extra gc override
    # script body, or "" to keep the zero-rigs gc above.
    local bd_body="$1" gc_body="${2:-}"
    cat > "$SANDBOX_BIN/bd" <<EOF
#!/usr/bin/env bash
$bd_body
EOF
    chmod +x "$SANDBOX_BIN/bd"
    if [ -n "$gc_body" ]; then
      cat > "$SANDBOX_BIN/gc" <<EOF
#!/usr/bin/env bash
$gc_body
EOF
      chmod +x "$SANDBOX_BIN/gc"
    fi
    local script; script="$(mktemp)"
    {
      printf '%s\n' "$_setline"
      echo 'warn() { echo "WARN: $*" >> "'"$WARN_LOG"'"; }'
      echo "GC_CITY=$FAKE_CITY"
      printf '%s\n' "$_gjou_src"
      printf '%s\n' "$_block_src"
      echo 'echo "IN_FLIGHT_QUERY_OK=$IN_FLIGHT_QUERY_OK"'
      echo 'echo "IN_FLIGHT_RAW_JSON=$IN_FLIGHT_RAW_JSON"'
    } > "$script"
    PATH="$SANDBOX_BIN:$PATH" bash "$script" 2>&1
    local rc=$?
    rm -f "$script"
    return $rc
  }

  # -- A: "consulta falhou" — bd exits non-zero for the HQ story:in-flight query.
  WARN_LOG="$(mktemp)"
  _out_a="$(run_block 'exit 1')"
  _rc_a=$?
  if [ "$_rc_a" -eq 0 ] \
     && printf '%s' "$_out_a" | grep -q 'IN_FLIGHT_QUERY_OK=0' \
     && printf '%s' "$_out_a" | grep -q 'IN_FLIGHT_RAW_JSON=\[\]' \
     && grep -q 'story:in-flight query failed for HQ' "$WARN_LOG"; then
    ok "consulta falhou: real failing bd -> IN_FLIGHT_QUERY_OK=0, IN_FLIGHT_RAW_JSON=[], warn logged, block did not abort the script"
  else
    bad "consulta falhou scenario failed: rc=$_rc_a out='$_out_a' warn_log='$(cat "$WARN_LOG" 2>/dev/null)'"
  fi
  rm -f "$WARN_LOG"

  # -- B: "nao ha" — bd succeeds, genuinely empty result.
  WARN_LOG="$(mktemp)"
  _out_b="$(run_block 'echo "[]"; exit 0')"
  _rc_b=$?
  if [ "$_rc_b" -eq 0 ] \
     && printf '%s' "$_out_b" | grep -q 'IN_FLIGHT_QUERY_OK=1' \
     && printf '%s' "$_out_b" | grep -q 'IN_FLIGHT_RAW_JSON=\[\]' \
     && [ ! -s "$WARN_LOG" ]; then
    ok "nao ha: real succeeding bd with genuinely empty result -> IN_FLIGHT_QUERY_OK=1, IN_FLIGHT_RAW_JSON=[] (SAME json as scenario A — proves QUERY_OK, not the JSON shape, is what callers must trust), no warn"
  else
    bad "nao ha scenario failed: rc=$_rc_b out='$_out_b' warn_log='$(cat "$WARN_LOG" 2>/dev/null)'"
  fi
  rm -f "$WARN_LOG"

  # -- C: "ha beads em voo" — bd succeeds, one real in-flight bead.
  WARN_LOG="$(mktemp)"
  _out_c="$(run_block 'echo '"'"'[{"id":"ga-e2e1","status":"in_progress"}]'"'"'; exit 0')"
  _rc_c=$?
  if [ "$_rc_c" -eq 0 ] \
     && printf '%s' "$_out_c" | grep -q 'IN_FLIGHT_QUERY_OK=1' \
     && printf '%s' "$_out_c" | grep -q 'ga-e2e1' \
     && [ ! -s "$WARN_LOG" ]; then
    ok "ha beads em voo: real succeeding bd with one in-flight bead -> IN_FLIGHT_QUERY_OK=1, bead present in IN_FLIGHT_RAW_JSON, no warn"
  else
    bad "ha beads em voo scenario failed: rc=$_rc_c out='$_out_c' warn_log='$(cat "$WARN_LOG" 2>/dev/null)'"
  fi
  rm -f "$WARN_LOG"

  # -- D: per-rig fetch failure also taints IN_FLIGHT_QUERY_OK. gc now
  #    reports one non-HQ rig; bd succeeds for HQ (empty) but fails for the
  #    rig-scoped call (`-C "$FAKE_RIG"`).
  FAKE_RIG="$(mktemp -d)"
  WARN_LOG="$(mktemp)"
  _out_d="$(run_block '
if printf "%s\n" "$@" | grep -qx -- "'"$FAKE_RIG"'"; then exit 1; fi
echo "[]"; exit 0
' 'echo "{\"schema_version\":\"1\",\"ok\":true,\"rigs\":[{\"name\":\"fakerig\",\"path\":\"'"$FAKE_RIG"'\",\"hq\":false}]}"; exit 0')"
  _rc_d=$?
  if [ "$_rc_d" -eq 0 ] \
     && printf '%s' "$_out_d" | grep -q 'IN_FLIGHT_QUERY_OK=0' \
     && grep -q "story:in-flight query failed for rig db $FAKE_RIG" "$WARN_LOG"; then
    ok "per-rig consulta falhou: HQ succeeds but the rig-scoped fetch fails -> IN_FLIGHT_QUERY_OK still lands at 0 (rig failure taints the aggregate), warn names the rig db"
  else
    bad "per-rig consulta falhou scenario failed: rc=$_rc_d out='$_out_d' warn_log='$(cat "$WARN_LOG" 2>/dev/null)'"
  fi
  rm -f "$WARN_LOG"
  rm -rf "$FAKE_RIG"

  rm -rf "$SANDBOX_BIN" "$FAKE_CITY"
fi

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && exit 0 || exit 1
