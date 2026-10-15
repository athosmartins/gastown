#!/usr/bin/env bash
# gate-phase-c-lane-restore.selftest.sh (ga-ufeq1c, 2026-10-14)
#
# Proves: a task-rapida run finalized by a LATER sweep (Phase C) writes lane=task-rapida on its dispatcher_complete event,
# not lane=normal.
#
# ROOT CAUSE it guards (read off the live .gc/quality-gate.jsonl on 2026-10-14): the task-rapida lane is decided in the sweep that
# launches the reviewer and finalized in a later one. GATE_LANE is process-local, Phase C never restored it, and Step 11 writes
# `${GATE_LANE:-normal}` -- so 5 of 5 task-rapida runs that completed carried lane=normal (dispatcher_complete.lane over the whole
# log: absent 8099, normal 163, never task-rapida).
#
# Strategy: pull the LIVE "phase-c-lane-restore" block and the LIVE "dispatcher-complete-event" block out of the dispatcher and run
# them back to back in one /bin/bash under `set -euo pipefail`, once per run description, exactly as Phase C's loop does. The
# assertion reads the `lane` field off the JSON event that was really written -- the symptom, not a variable. THREE MUTATIONS of a
# scratch copy then prove the suite is not vacuous: (1) no restore -> the task-rapida run reads normal again; (2) no reset -> one
# run's lane leaks into the next run whose record has none; (3) "fast" restored too -> a recovered fast run would flip behavior.
#
# Run against the dispatcher WITHOUT the fix (DISPATCHER=<path to the old file>) it exits 2: the block does not exist.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
REAL_BASH="/bin/bash"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-phase-c-lane-restore.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -x "$REAL_BASH" ] || { echo "FATAL: $REAL_BASH not found" >&2; exit 2; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lane-restore-selftest.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP_ROOT"' EXIT

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" | sed '1d;$d'
}

# The record Step 6 writes for a run (same keys, same order). Only the lane line varies; <lane-line> is passed whole so a
# fixture can also omit it (a run from before the line existed) or garble it.
desc() {
  local lane_line="$1"
  printf 'Autonomous gate run for fix/ga-x-lane.\nsource_bead: ga-x\nauthor: gastown.dog-4\nrig: gascity\nbead_rig: \nbranch: fix/ga-x-lane\ntier: TASK-RAPIDA\n'
  [ -n "$lane_line" ] && printf '%s\n' "$lane_line"
  printf 'required_reviewers: 1\nbranch_sha: 0123456789abcdef\nmarker_id: ga-mk\nstarted_at: 2026-10-14T21:00:00Z\nverdict_timeout_minutes: 30\n'
}

# run_lanes <dispatcher-file> <desc>...   -> prints, one per line, the `lane` of the dispatcher_complete event written for each
# description, all in ONE shell (Phase C's loop finalizes several runs in one process, so a leak between them is visible).
run_lanes() {
  local file="$1"; shift
  local d restore emit exfn
  d="$(mktemp -d "$TMP_ROOT/run.XXXXXX")" || return 99
  restore="$(extract_block "$file" phase-c-lane-restore)"
  emit="$(extract_block "$file" dispatcher-complete-event)"
  exfn="$(grep -E '^extract\(\) \{' "$file" | head -1)"
  if [ -z "$restore" ] || [ -z "$emit" ] || [ -z "$exfn" ]; then
    echo "COULD_NOT_EXTRACT (restore=${#restore}B emit=${#emit}B extract_fn=${#exfn}B)" >&2
    return 99
  fi
  printf '%s\n' "$restore" > "$d/restore.sh"
  printf '%s\n' "$emit"    > "$d/emit.sh"
  printf '%s\n' "$exfn"    > "$d/extract_fn.sh"
  "$REAL_BASH" -c '
    set -euo pipefail
    d="$1"; shift
    . "$d/extract_fn.sh"
    QG_LOG="$d/qg.jsonl"
    OVERALL_VERDICT=PASS; FAIL_REASONS=""; REQUIRED_REVIEWERS=1
    BRANCH=fix/ga-x-lane; BEAD_ID=ga-x; RIG=gascity; TIER=TASK-RAPIDA; GATE_RUN_ID=ga-run; MARKER_ID=ga-mk; ELAPSED_S=836; DRY_RUN=0
    for DESC in "$@"; do
      . "$d/restore.sh"
      . "$d/emit.sh"
    done
  ' _ "$d" "$@" >"$d/out.txt" 2>"$d/err.txt" || { echo "RUN_FAILED: $(cat "$d/err.txt")" >&2; return 98; }
  jq -r '.lane' "$d/qg.jsonl"
}

# expect <label> <expected, space-separated per run> <dispatcher-file> <desc>...
expect() {
  local label="$1" want="$2" file="$3"; shift 3
  local got rc=0
  got="$(run_lanes "$file" "$@" | tr '\n' ' ' | sed 's/ $//')" || rc=$?
  if [ "$got" = "$want" ]; then ok "$label  (lane: $got)"; else bad "$label  (want '$want', got '${got:-<nothing>}')"; fi
}

# ── presence: the fix is in the file, inside Phase C's loop, ahead of the finalize calls ─────────────────────────────────
if [ -z "$(extract_block "$DISPATCHER" phase-c-lane-restore)" ]; then
  echo "FATAL: no phase-c-lane-restore block in $DISPATCHER -- the fix is not there" >&2
  exit 2
fi
if [ -z "$(extract_block "$DISPATCHER" dispatcher-complete-event)" ]; then
  echo "FATAL: no dispatcher-complete-event block in $DISPATCHER" >&2
  exit 2
fi

echo "-- placement"
loop_ln="$(grep -n 'for PC_I in \$(seq 0' "$DISPATCHER" | head -1 | cut -d: -f1)"
rest_ln="$(grep -n 'SELFTEST-EXTRACT phase-c-lane-restore: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)"
fin_ln="$(awk -v s="${loop_ln:-0}" 'NR>s && /^[[:space:]]+gate_finalize_run$/ {print NR; exit}' "$DISPATCHER")"
if [ -n "$loop_ln" ] && [ -n "$rest_ln" ] && [ -n "$fin_ln" ] && [ "$loop_ln" -lt "$rest_ln" ] && [ "$rest_ln" -lt "$fin_ln" ]; then
  ok "the restore sits inside Phase C's per-run loop (loop L$loop_ln < restore L$rest_ln < first finalize L$fin_ln)"
else
  bad "the restore is not between Phase C's loop and its first gate_finalize_run (loop='${loop_ln:-?}' restore='${rest_ln:-?}' finalize='${fin_ln:-?}')"
fi

echo "-- the symptom: what dispatcher_complete says"
expect "task-rapida run finalized by a later sweep -> lane=task-rapida"        "task-rapida" "$DISPATCHER" "$(desc 'lane: task-rapida')"
expect "normal run -> lane=normal"                                             "normal"      "$DISPATCHER" "$(desc 'lane: normal')"
expect "run record with NO lane line (before the line existed) -> normal"      "normal"      "$DISPATCHER" "$(desc '')"
expect "empty lane value -> normal"                                            "normal"      "$DISPATCHER" "$(desc 'lane:')"
expect "unknown lane value -> normal (no third lane from a record)"           "normal"      "$DISPATCHER" "$(desc 'lane: bogus')"
expect "fast in a record -> normal, as before (its finalize needs state a later process lacks)" "normal" "$DISPATCHER" "$(desc 'lane: fast')"
expect "'lane:' mid-line is not the lane line"                                 "normal"      "$DISPATCHER" "$(desc 'lane: normal')$(printf '\nnote: lane: task-rapida')"
expect "lane value in a different case is not task-rapida"                 "normal"      "$DISPATCHER" "$(desc 'lane: Task-Rapida')"

echo "-- a loop of runs in one process (Phase C finalizes several per sweep)"
expect "task-rapida then a record with no lane: no leak forward"               "task-rapida normal"              "$DISPATCHER" "$(desc 'lane: task-rapida')" "$(desc '')"
expect "task-rapida, normal, task-rapida: each run keeps its own"              "task-rapida normal task-rapida"  "$DISPATCHER" "$(desc 'lane: task-rapida')" "$(desc 'lane: normal')" "$(desc 'lane: task-rapida')"
expect "task-rapida then fast: fast does not inherit, and is not restored"     "task-rapida normal"              "$DISPATCHER" "$(desc 'lane: task-rapida')" "$(desc 'lane: fast')"

echo "-- controls: the assertions above fail when the guard is taken out (scratch copies; the real file is untouched)"
M1="$TMP_ROOT/mut-no-restore.sh"
sed '/phase-c-lane-restore: BEGIN/,/phase-c-lane-restore: END/{/task-rapida) GATE_LANE=/d;}' "$DISPATCHER" > "$M1"
if cmp -s "$DISPATCHER" "$M1"; then bad "control 1 did not change the file (the sed matched nothing)"; else
  expect "control 1 (no restore): the task-rapida run reads normal again -- the original symptom" "normal" "$M1" "$(desc 'lane: task-rapida')"
fi
M2="$TMP_ROOT/mut-no-reset.sh"
sed '/phase-c-lane-restore: BEGIN/,/phase-c-lane-restore: END/{/^[[:space:]]*GATE_LANE="normal"$/d;}' "$DISPATCHER" > "$M2"
if cmp -s "$DISPATCHER" "$M2"; then bad "control 2 did not change the file (the sed matched nothing)"; else
  expect "control 2 (no reset): the lane leaks into the next run whose record has none" "task-rapida task-rapida" "$M2" "$(desc 'lane: task-rapida')" "$(desc '')"
fi
M3="$TMP_ROOT/mut-restore-fast.sh"
sed '/phase-c-lane-restore: BEGIN/,/phase-c-lane-restore: END/{s/task-rapida) GATE_LANE="task-rapida"/task-rapida|fast) GATE_LANE="$(extract "lane")"/;}' "$DISPATCHER" > "$M3"
if cmp -s "$DISPATCHER" "$M3"; then bad "control 3 did not change the file (the sed matched nothing)"; else
  expect "control 3 (fast restored too): a recovered fast run would flip lane -- the scope guard has teeth" "fast" "$M3" "$(desc 'lane: fast')"
fi

echo "-- syntax"
if "$REAL_BASH" -n "$DISPATCHER" 2>"$TMP_ROOT/syn.err"; then ok "bash -n on the dispatcher (/bin/bash $("$REAL_BASH" -c 'echo $BASH_VERSION'))"; else bad "bash -n failed: $(head -3 "$TMP_ROOT/syn.err")"; fi

echo
echo "gate-phase-c-lane-restore.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
