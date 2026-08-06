#!/usr/bin/env bash
# quality-gate-dispatcher.ttl-liveness.selftest.sh (2026-08-06)
#
# Regression guard for ga-9uwbw: "Dispatcher declara 'LIVE gate-run' sem
# NENHUM revisor vivo — marker encalhou 375min e o proprio guard anti-zumbi o
# protegeu."
#
# ROOT CAUSE: Step 0a's zombie-reclaim check used to ask only "does a
# type:quality-gate-run bead exist with a gate-status:running LABEL whose
# description mentions this marker_id". That label is set once at Step 6 and
# never touched again during Phase B — it is not evidence anyone is still
# reviewing. Measured live 2026-08-06 (Mayor, marker ga-wisp-wqxq55z): the run
# bead's label said gate-status:running for 375 minutes straight while the
# ONE gate-reviewer session running city-wide was reviewing a COMPLETELY
# DIFFERENT bead (ga-9bob9) — zero reviewers were actually working this run —
# yet every sweep logged "has a LIVE gate-run ... NOT reclaiming as a
# zombie". Root-class:error-vs-empty: "the run is alive" and "I could not
# prove it's dead" produced the same log line and the same (in)action.
#
# FIX:
#   gate_run_has_live_reviewer() positively resolves an ACTUAL live reviewer
#   session for a gate-run, via its verdict beads' assignee (=session_name,
#   set durably at spawn) cross-checked against `gc session list` — the same
#   data path Phase C's own dead-reviewer classifier already trusts, not a
#   second, divergent one.
#   gate_run_marker_reclaim_decision() is the pure policy: fold that
#   liveness verdict together with an ABSOLUTE age ceiling (AC3 — no
#   legitimate run outlives 2x VERDICT_TIMEOUT_MAX_MINUTES) so an
#   unverifiable-forever marker cannot be silently protected indefinitely
#   either, even if some future bug reopens a liveness-check gap.
#
# This suite:
#   Part A — gate_run_marker_reclaim_decision: pure function, zero mocking,
#            full AC1/AC2/AC3/AC4 input matrix.
#   Part B — gate_run_has_live_reviewer: mocked bd/gc, including a direct
#            shape-for-shape reproduction of the ga-wisp-wqxq55z incident.
#   Part C — Step 0a wired end-to-end (real bd-list-cached.sh shim, mocked
#            bd/gc underneath it): proves the actual log/action changes for
#            the incident's exact input shape, and non-regression for a
#            genuinely in-progress run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$HERE/quality-gate-dispatcher.sh"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  # $1 = marker name, $2 = file
  sed -n "/# SELFTEST-EXTRACT $1: BEGIN/,/# SELFTEST-EXTRACT $1: END/p" "$2" | sed '1d;$d'
}

echo "== quality-gate-dispatcher.ttl-liveness.selftest (ga-9uwbw) =="

# ══════════════════════════════════════════════════════════════════════════
# Part A: gate_run_marker_reclaim_decision — pure, zero mocking
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Part A: gate_run_marker_reclaim_decision (pure decision fn) ──"
DECISION_SNIP="$(extract_block "gate-run-marker-reclaim-decision-fn" "$DISPATCHER")"
case "$DECISION_SNIP" in
  *gate_run_marker_reclaim_decision*) : ;;
  *) echo "FATAL: could not extract gate_run_marker_reclaim_decision — did it move/rename?" >&2; exit 2 ;;
esac
eval "$DECISION_SNIP"
type gate_run_marker_reclaim_decision >/dev/null 2>&1 || { echo "FATAL: eval did not define gate_run_marker_reclaim_decision"; exit 2; }

# AC4 non-regression: age <= ttl always skips, regardless of liveness —
# nothing is stuck yet, unchanged from pre-fix behavior for this branch.
eq "age < ttl, live      → skip" "$(gate_run_marker_reclaim_decision 10 30 100 live)"    "skip"
eq "age < ttl, dead      → skip" "$(gate_run_marker_reclaim_decision 10 30 100 dead)"    "skip"
eq "age < ttl, unknown   → skip" "$(gate_run_marker_reclaim_decision 10 30 100 unknown)" "skip"
eq "age == ttl (boundary) → skip (not >)" "$(gate_run_marker_reclaim_decision 30 30 100 dead)" "skip"

# AC1: past ttl, under absolute ceiling, VERIFIED live → skip (not reclaimed).
eq "past ttl, under ceiling, live    → skip"    "$(gate_run_marker_reclaim_decision 60 30 100 live)"    "skip"
# AC2: past ttl, under ceiling, could NOT verify → skip (absence of evidence
# of life must not read as confirmed death — same stance as this file's own
# root-class:error-vs-empty handling elsewhere).
eq "past ttl, under ceiling, unknown → skip"    "$(gate_run_marker_reclaim_decision 60 30 100 unknown)" "skip"
# The classic, now-VERIFIED zombie case.
eq "past ttl, under ceiling, dead    → requeue" "$(gate_run_marker_reclaim_decision 60 30 100 dead)"    "requeue"

# AC3: past the ABSOLUTE ceiling, requeue regardless of liveness —
# distinct return value only so the caller can log which situation happened.
eq "past absolute ceiling, live    → requeue-past-absolute-ceiling" \
   "$(gate_run_marker_reclaim_decision 150 30 100 live)"    "requeue-past-absolute-ceiling"
eq "past absolute ceiling, unknown → requeue (no protection forever)" \
   "$(gate_run_marker_reclaim_decision 150 30 100 unknown)" "requeue"
eq "past absolute ceiling, dead    → requeue" \
   "$(gate_run_marker_reclaim_decision 150 30 100 dead)"    "requeue"
# Boundary discipline: exactly AT the ceiling is not PAST it (same > vs >=
# convention as the existing TTL check just above it in the source).
eq "age == absolute ceiling (boundary), live → skip (not >)" \
   "$(gate_run_marker_reclaim_decision 100 30 100 live)" "skip"

# ══════════════════════════════════════════════════════════════════════════
# Part B: gate_run_has_live_reviewer — mocked bd/gc
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Part B: gate_run_has_live_reviewer (live-session resolver) ──"
LIVE_FN_SNIP="$(extract_block "gate-run-has-live-reviewer-fn" "$DISPATCHER")"
SESSDEAD_SNIP="$(extract_block "session-is-dead-fn" "$DISPATCHER")"
case "$LIVE_FN_SNIP" in
  *gate_run_has_live_reviewer*) : ;;
  *) echo "FATAL: could not extract gate_run_has_live_reviewer — did it move/rename?" >&2; exit 2 ;;
esac
case "$SESSDEAD_SNIP" in
  *session_is_dead*) : ;;
  *) echo "FATAL: could not extract session_is_dead — did it move/rename?" >&2; exit 2 ;;
esac

# run_liveness_case <desc> <list-rc> <list-out> <vb-show-map-json> <show-fail-vbid> <sess-list-out> <want>
#   vb-show-map-json: {"<vbid>": {"status":"open|closed","assignee":"<sid>"}}
#   show-fail-vbid:   a single vbid for which the mocked `bd show` should
#                      simulate a hard read failure (non-zero exit, no
#                      output) — "" to disable.
run_liveness_case() {
  local desc="$1" list_rc="$2" list_out="$3" vb_map="$4" show_fail="$5" sess_out="$6" want="$7" got
  got=$("$REAL_BASH" -c '
    set -euo pipefail
    '"$SESSDEAD_SNIP"'
    '"$LIVE_FN_SNIP"'
    GC_CITY="/fake/city"
    LIST_RC="$1"; LIST_OUT="$2"; VB_MAP="$3"; SHOW_FAIL="$4"; SESS_OUT="$5"
    bd() {
      case " $* " in
        *" list "*)
          [ -n "$LIST_OUT" ] && echo "$LIST_OUT"
          return "$LIST_RC"
          ;;
        *" show "*)
          local _vbid="" _prev=""
          for _tok in "$@"; do
            [ "$_prev" = "show" ] && { _vbid="$_tok"; break; }
            _prev="$_tok"
          done
          if [ -n "$SHOW_FAIL" ] && [ "$_vbid" = "$SHOW_FAIL" ]; then
            return 1
          fi
          echo "$VB_MAP" | jq -c --arg id "$_vbid" ".[\$id] // {}"
          return 0
          ;;
      esac
      return 0
    }
    gc() {
      case " $* " in
        *" session list "*) echo "$SESS_OUT"; return 0 ;;
      esac
      return 0
    }
    gate_run_has_live_reviewer "test-run-1"
  ' _ "$list_rc" "$list_out" "$vb_map" "$show_fail" "$sess_out" 2>/dev/null)
  eq "$desc" "$got" "$want"
}

# 1. Confirmed LIVE: one pending verdict bead, its assignee is present+alive.
run_liveness_case \
  "pending verdict, assignee present+not-closed → live" \
  0 '[{"id":"vb-1"}]' \
  '{"vb-1":{"status":"open","assignee":"sess-A"}}' \
  "" \
  '{"sessions":[{"session_name":"sess-A","closed":false}]}' \
  "live"

# 2. Confirmed DEAD: one pending verdict bead, its assignee is NOT in the
# session list at all (the incident's exact shape, single-reviewer case).
run_liveness_case \
  "pending verdict, assignee ABSENT from session list → dead" \
  0 '[{"id":"vb-1"}]' \
  '{"vb-1":{"status":"open","assignee":"sess-GHOST"}}' \
  "" \
  '{"sessions":[{"session_name":"sess-A","closed":false}]}' \
  "dead"

# 3. Confirmed DEAD: assignee present but CLOSED (session ended).
run_liveness_case \
  "pending verdict, assignee present but CLOSED → dead" \
  0 '[{"id":"vb-1"}]' \
  '{"vb-1":{"status":"open","assignee":"sess-A"}}' \
  "" \
  '{"sessions":[{"session_name":"sess-A","closed":true}]}' \
  "dead"

# 4. Zero verdict beads at all (Phase A died before Step 7 spawned anyone).
run_liveness_case \
  "zero verdict beads → dead" \
  0 '[]' \
  '{}' \
  "" \
  '{"sessions":[]}' \
  "dead"

# 5. AC2: the verdict-bead QUERY ITSELF fails — must be "unknown", never
# silently read as "dead" (root-class:error-vs-empty, this file's own stance
# elsewhere — see phase-c-verdict-rehydrate's VB_SENTINEL handling).
run_liveness_case \
  "verdict-bead query FAILS (rc=1) → unknown, not dead" \
  1 "" \
  '{}' \
  "" \
  '{"sessions":[]}' \
  "unknown"

# 6. AC2, second flavor: the list query succeeds but an individual verdict
# bead's own `bd show` fails — also "unknown", not "dead" (don't guess).
run_liveness_case \
  "individual verdict-bead show FAILS → unknown, not dead" \
  0 '[{"id":"vb-1"}]' \
  '{}' \
  "vb-1" \
  '{"sessions":[]}' \
  "unknown"

# 7. All verdicts already CLOSED (delivered) — no pending reviewer left to
# verify; not evidence of a zombie either way, but this check's job is only
# "is Phase B still legitimately active", so it reports dead (Phase C /
# gate-recovery-watchdog own the separate "finalize a fully-verdicted run"
# problem, not Step 0a).
run_liveness_case \
  "all verdict beads already closed/delivered → dead (nothing pending)" \
  0 '[{"id":"vb-1"},{"id":"vb-2"}]' \
  '{"vb-1":{"status":"closed","assignee":"sess-A"},"vb-2":{"status":"closed","assignee":"sess-B"}}' \
  "" \
  '{"sessions":[]}' \
  "dead"

# 8. Multiple reviewers, only one still alive → live wins (at least one
# genuinely active reviewer is enough to call Phase B in progress).
run_liveness_case \
  "2 pending verdicts, one dead one live → live" \
  0 '[{"id":"vb-1"},{"id":"vb-2"}]' \
  '{"vb-1":{"status":"open","assignee":"sess-GHOST"},"vb-2":{"status":"open","assignee":"sess-B"}}' \
  "" \
  '{"sessions":[{"session_name":"sess-B","closed":false}]}' \
  "live"

# 9. ★ THE INCIDENT ITSELF, shape-for-shape ★ — ga-wisp-wqxq55z: a live
# gate-reviewer session (gate-reviewer-adhoc-8cd7708884) genuinely exists
# city-wide, but it is assigned to a DIFFERENT bead's verdict (ga-9bob9),
# not this run's. The pre-fix check never looked this closely — it only
# checked whether ANY gate-status:running bead's description mentioned the
# marker_id, which this run's bead did. The fixed check must say "dead".
run_liveness_case \
  "★ ga-wisp-wqxq55z shape: live session exists city-wide but for a DIFFERENT bead → dead" \
  0 '[{"id":"vb-wqxq55z-1"}]' \
  '{"vb-wqxq55z-1":{"status":"open","assignee":"sess-for-a-different-marker"}}' \
  "" \
  '{"sessions":[{"session_name":"gate-reviewer-adhoc-8cd7708884","closed":false}]}' \
  "dead"

# ══════════════════════════════════════════════════════════════════════════
# Part C: Step 0a wired end-to-end (bd calls mocked directly)
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Part C: Step 0a TTL-recovery, end-to-end ──"
STEP0A_SNIP_RAW="$(extract_block "step-0a-ttl-recovery" "$DISPATCHER")"
case "$STEP0A_SNIP_RAW" in
  *"DISPATCHING_TTL_MINUTES=30"*) : ;;
  *) echo "FATAL: could not extract the Step 0a block — did it move/rename?" >&2; exit 2 ;;
esac
case "$STEP0A_SNIP_RAW" in
  *'bash "$GC_CITY/scripts/bd-list-cached.sh"'*) : ;;
  *) echo "FATAL: Step 0a no longer calls bd-list-cached.sh the expected way — update this test's bypass substitution" >&2; exit 2 ;;
esac
# This suite tests Step 0a's own DECISION logic (the part ga-9uwbw actually
# changed), not bd-list-cached.sh's caching mechanics (pre-existing,
# independently relied on elsewhere, untouched by this fix). Swap the two
# `bash ".../bd-list-cached.sh" -C "$GC_CITY" list ...` calls for a direct
# `bd -C "$GC_CITY" list ...` — same args reach the same mocked `bd` below,
# minus a cache layer that would otherwise need its own filesystem fixtures
# to test hermetically here.
STEP0A_SNIP="$(printf '%s' "$STEP0A_SNIP_RAW" | sed 's|bash "\$GC_CITY/scripts/bd-list-cached\.sh" -C|bd -C|g')"
case "$STEP0A_SNIP" in
  *'bd-list-cached.sh'*) echo "FATAL: bypass substitution did not fully apply" >&2; exit 2 ;;
esac

# run_step0a_case <desc> <marker-updated-ago-min> <run-list-out> <verdict-list-out> <vb-map> <sess-out> <want-substr> [want-no-mutation=1]
run_step0a_case() {
  local desc="$1" age_min="$2" run_list_out="$3" verdict_list_out="$4" vb_map="$5" sess_out="$6" want_substr="$7" want_no_mutation="${8:-0}"
  local marker_ts
  marker_ts=$(date -u -v-"${age_min}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${age_min} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
  local dispatching_json='[{"id":"marker-under-test","updated_at":"'"$marker_ts"'"}]'
  local mut_log
  mut_log=$(mktemp "${TMPDIR:-/tmp}/gate-9uwbw-mut-XXXXXX" 2>/dev/null || echo "/tmp/gate-9uwbw-mut-$$")
  rm -f "$mut_log"
  local out
  out=$("$REAL_BASH" -c '
    set -uo pipefail
    '"$SESSDEAD_SNIP"'
    '"$DECISION_SNIP"'
    '"$LIVE_FN_SNIP"'
    GC_CITY="/fake/city"; VERDICT_TIMEOUT_MAX_MINUTES=50
    RUN_LIST_OUT="$1"; MARKER_LIST_OUT="$2"; VERDICT_LIST_OUT="$3"; VB_MAP="$4"; SESS_OUT="$5"; MUT_LOG="$6"
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*"; }
    bd() {
      case " $* " in
        *"type:quality-gate-run"*"gate-status:running"*)
          [ -n "$RUN_LIST_OUT" ] && echo "$RUN_LIST_OUT"; return 0 ;;
        *"type:quality-gate-marker"*"gate-status:dispatching"*)
          [ -n "$MARKER_LIST_OUT" ] && echo "$MARKER_LIST_OUT"; return 0 ;;
        *"type:quality-gate-verdict"*)
          [ -n "$VERDICT_LIST_OUT" ] && echo "$VERDICT_LIST_OUT"; return 0 ;;
        *" show "*)
          local _vbid="" _prev=""
          for _tok in "$@"; do
            [ "$_prev" = "show" ] && { _vbid="$_tok"; break; }
            _prev="$_tok"
          done
          echo "$VB_MAP" | jq -c --arg id "$_vbid" ".[\$id] // {}"
          return 0
          ;;
        *" label "*|*" comment "*)
          echo "MUTATION: $*" >> "$MUT_LOG"
          return 0
          ;;
      esac
      return 0
    }
    gc() {
      case " $* " in
        *" session list "*) echo "$SESS_OUT"; return 0 ;;
      esac
      return 0
    }
    '"$STEP0A_SNIP"'
  ' _ "$run_list_out" "$dispatching_json" "$verdict_list_out" "$vb_map" "$sess_out" "$mut_log" 2>&1)
    case "$out" in
      *"$want_substr"*) ok "$desc" ;;
      *) bad "$desc — did not find [$want_substr] in output: $(echo "$out" | tr '\n' '|' | cut -c1-400)" ;;
    esac
    if [ "$want_no_mutation" = "1" ]; then
      if [ -s "$mut_log" ]; then
        bad "$desc — expected NO label/comment mutation, but got: $(cat "$mut_log" | tr '\n' '|')"
      else
        ok "$desc — no label/comment mutation (marker left untouched)"
      fi
    else
      if [ -s "$mut_log" ]; then
        ok "$desc — label/comment mutation happened as expected"
      else
        bad "$desc — expected a label/comment mutation (requeue) but none happened"
      fi
    fi
    rm -f "$mut_log" 2>/dev/null || true
  }

  # C1 ★ the incident itself, end-to-end: a 400m-old marker (comfortably past
  # both the 30m TTL and the 100m absolute ceiling for VERDICT_TIMEOUT_MAX_
  # MINUTES=50), whose gate-run bead says gate-status:running (exactly the
  # label the OLD check trusted blindly) but whose verdict bead's assignee
  # matches no live session at all. Old behavior: "LIVE gate-run ... NOT
  # reclaiming" logged every sweep, forever. New behavior must requeue.
  run_step0a_case \
    "★ incident reproduction: stale gate-status:running label, zero live reviewers → requeue" \
    400 \
    '[{"id":"gr-1","description":"marker_id: marker-under-test\nstarted_at: 2026-08-05T20:32:00Z"}]' \
    '[{"id":"vb-1"}]' \
    '{"vb-1":{"status":"open","assignee":"sess-GHOST"}}' \
    '{"sessions":[]}' \
    "no live gate-run reviewer session found" \
    0

  # C2 non-regression: a genuinely in-progress run (60m old — past the 30m
  # TTL but comfortably under the 100m absolute ceiling — with a VERIFIED
  # live reviewer) must be left alone, not reclaimed.
  run_step0a_case \
    "non-regression: verified live reviewer at 60m → skip, no mutation" \
    60 \
    '[{"id":"gr-2","description":"marker_id: marker-under-test\nstarted_at: 2026-08-05T20:32:00Z"}]' \
    '[{"id":"vb-2"}]' \
    '{"vb-2":{"status":"open","assignee":"sess-ALIVE"}}' \
    '{"sessions":[{"session_name":"sess-ALIVE","closed":false}]}' \
    "VERIFIED a live reviewer session" \
    1

echo ""
echo "== quality-gate-dispatcher.ttl-liveness.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
