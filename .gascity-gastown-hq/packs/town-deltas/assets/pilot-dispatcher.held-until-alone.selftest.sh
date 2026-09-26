#!/usr/bin/env bash
# pilot-dispatcher.held-until-alone.selftest.sh — Prove the ga-0eib9f fix:
# _filter_candidates must treat a FUTURE pilot:held-until:<epoch> label as a
# hold BY ITSELF, without requiring pilot:held to be present as well.
#
# Bug (ga-0eib9f, measured 26/09): ga-w6tfb5 was born with
# pilot:held-until:<now+60h> and NO pilot:held. The old clause read
# "(no pilot:held) OR (a valid held-until AND max < now)", so a bead without
# pilot:held took the first branch and the stamp was never consulted — the
# Pilot dispatched it 21 min later, 60h early. The dog pool probe (Step 1c)
# and bead_state.py already read the stamp alone as a hold; the Pilot was the
# odd reader out (three readers, two meanings of "hold").
#
# Acceptance criteria under test:
#   AC1. Only pilot:held-until:<FUTURE>, no pilot:held  → EXCLUDED (the bug).
#   AC2. Only pilot:held-until:<PAST>                   → still dispatchable
#        (an expired stamp is not a hold; nothing about expiry changed).
#   AC3. Accumulated stamps, no pilot:held (PAST + FUTURE) → EXCLUDED: the MAX
#        epoch decides (ga-4aree), same as it does when pilot:held is present.
#   AC4. Stamp present but unreadable (no valid epoch, e.g. an ISO date typed by
#        hand), no pilot:held → EXCLUDED. Three states, not two: "cannot tell"
#        is not "no hold", and under doubt the answer is INERT. (Same answer a
#        bare pilot:held with no stamp has always given.)
#   AC5. NO REGRESSION on every shape that already worked: pilot:held +
#        FUTURE → excluded; pilot:held + PAST → dispatchable; bare pilot:held →
#        excluded; pilot:held + unreadable stamp → excluded; a plain bead and a
#        pilot:held-count:<slug>:<n> bead (different prefix) → dispatchable.
#   AC6. The reason-trace names the right reason, and only one: the two new
#        held-until-alone reasons fire ONLY when pilot:held is absent, so a
#        pilot:held bead keeps its single "pilot:held(not-expired)" line.
#   AC8. The Pilot now AGREES with the pool probes: for every fixture, "Pilot
#        excludes it" == scripts/pool-probe-vetoes.sh pool_held (the definition
#        the dog/wa-worker/ps-worker probes and the gate dispatcher share). The
#        bug was three readers with two meanings of "hold"; this pins them to
#        one so a future edit to either side fails here instead of in prod.
#   AC7. (when ORIG_DISPATCHER is set) the SAME fixtures run through the
#        pre-patch _filter_candidates LEAK the AC1/AC3/AC4 beads — proving
#        this test reproduces the reported bug — while AC2/AC5 answers are
#        identical before and after.
#
# Runs against extracted function bodies (same awk/sed-extraction idiom as
# pilot-dispatcher.exclusion-trace.selftest.sh); no live Dolt/bd/gc needed.
# Safe on a live host.
#
# Exit 0 iff all assertions hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/pilot-dispatcher.sh}"
ORIG_DISPATCHER="${ORIG_DISPATCHER:-}"   # optional: pre-patch file for the AC7 differential

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-held-until-alone-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

NOW="$(date +%s)"
FUTURE=$(( NOW + 3600 ))
PAST=$(( NOW - 100 ))
PAST2=$(( NOW - 1000 ))

# One fixture set for every run (patched and pre-patch). Every bead is
# otherwise dispatchable — no assignee, real description, no other veto — so
# the ONLY thing separating "kept" from "excluded" is the hold labels.
cat > "$WORK/input.json" <<EOF
[
  {"id":"ga-plain","assignee":null,"labels":[],"description":"a real task with content"},
  {"id":"ga-alone-future","assignee":null,"labels":["pilot:held-until:$FUTURE"],"description":"x"},
  {"id":"ga-alone-past","assignee":null,"labels":["pilot:held-until:$PAST"],"description":"x"},
  {"id":"ga-alone-accum","assignee":null,"labels":["pilot:held-until:$PAST2","pilot:held-until:$FUTURE"],"description":"x"},
  {"id":"ga-alone-garbage","assignee":null,"labels":["pilot:held-until:2026-09-29"],"description":"x"},
  {"id":"ga-alone-mixed-past","assignee":null,"labels":["pilot:held-until:2026-09-29","pilot:held-until:$PAST"],"description":"x"},
  {"id":"ga-alone-mixed-future","assignee":null,"labels":["pilot:held-until:2026-09-29","pilot:held-until:$FUTURE"],"description":"x"},
  {"id":"ga-pair-future","assignee":null,"labels":["pilot:held","pilot:held-until:$FUTURE"],"description":"x"},
  {"id":"ga-pair-past","assignee":null,"labels":["pilot:held","pilot:held-until:$PAST"],"description":"x"},
  {"id":"ga-held-bare","assignee":null,"labels":["pilot:held"],"description":"x"},
  {"id":"ga-pair-garbage","assignee":null,"labels":["pilot:held","pilot:held-until:2026-09-29"],"description":"x"},
  {"id":"ga-heldcount","assignee":null,"labels":["pilot:held-count:some-slug:3"],"description":"x"}
]
EOF

# run_filter <dispatcher-file> <tag> — extract _filter_candidates (+ the globals
# and helpers it needs) from the given file, run the fixture through it, leave
# kept ids in $WORK/<tag>.ids and the exclusion trace in $WORK/<tag>.stderr.
run_filter() {
  local src="$1" tag="$2"
  local log_fn le_fn consts fc_fn
  log_fn="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
  le_fn="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$src")"
  consts="$(awk '/^_FILTER_PREAPPROVAL_LABELS=/{print} /^_FILTER_FRAMEWORK_MARKER_LABELS=/{print} /^_FILTER_RECLAIM_CAP=/{print} /^_PILOT_ENGINE_REBUILD_RE=/{print} /^_PILOT_ENGINE_REBUILD_NONREQUEST_RE=/{print}' "$src")"
  fc_fn="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$src")"
  if [ -z "$fc_fn" ]; then
    echo "FATAL: _filter_candidates() not found in $src" >&2
    exit 2
  fi
  # The real script sources framework-marker-labels.sh via a variable path the
  # extraction cannot capture, so inject it here with this harness's own
  # (correct) $SELF_DIR — same reason as the other pilot-dispatcher selftests.
  cat > "$WORK/$tag.sh" <<EOF
$log_fn
$le_fn
source "$SELF_DIR/framework-marker-labels.sh"
$consts
$fc_fn
SELF_BEAD_ID=""
_filter_candidates < "$WORK/input.json"
EOF
  bash "$WORK/$tag.sh" 2>"$WORK/$tag.stderr" | jq -r '.[].id' 2>/dev/null | sort > "$WORK/$tag.ids"
}

kept()    { grep -qx "$2" "$WORK/$1.ids"; }
trace_of() { grep -F "EXCLUÍDO $2 por _filter_candidates:" "$WORK/$1.stderr" || true; }

echo "Scenario 1: patched _filter_candidates — held-until-alone is a hold (AC1-AC5)"
run_filter "$DISPATCHER" patched
if [ ! -s "$WORK/patched.ids" ]; then
  bad "patched run produced no output at all — harness broken (stderr: $(head -5 "$WORK/patched.stderr" 2>/dev/null))"
fi

kept patched ga-alone-future  && bad "AC1: held-until:<FUTURE> with no pilot:held leaked into candidates (the reported bug)" \
                              || ok  "AC1: held-until:<FUTURE> alone → EXCLUDED"
kept patched ga-alone-past    && ok  "AC2: held-until:<PAST> alone → still dispatchable (expired stamp is not a hold)" \
                              || bad "AC2: expired held-until alone was wrongly excluded"
kept patched ga-alone-accum   && bad "AC3: accumulated held-until (PAST+FUTURE) alone leaked — MAX epoch not honoured" \
                              || ok  "AC3: accumulated held-until, max=FUTURE, alone → EXCLUDED (MAX rule)"
kept patched ga-alone-garbage && bad "AC4: unreadable held-until alone leaked — 'cannot tell' was read as 'no hold'" \
                              || ok  "AC4: unreadable held-until alone → EXCLUDED (inert under doubt)"

kept patched ga-alone-mixed-past   && ok  "AC4: unreadable + valid PAST stamp, no pilot:held → dispatchable (the readable stamp is expired; unreadable one does not extend it)" \
                                   || bad "AC4: unreadable + expired stamp wrongly excluded"
kept patched ga-alone-mixed-future && bad "AC4: unreadable + valid FUTURE stamp, no pilot:held, leaked" \
                                   || ok  "AC4: unreadable + valid FUTURE stamp, no pilot:held → EXCLUDED"

kept patched ga-pair-future   && bad "AC5: pilot:held + FUTURE regressed — now dispatchable" \
                              || ok  "AC5: pilot:held + held-until:<FUTURE> → EXCLUDED (unchanged)"
kept patched ga-pair-past     && ok  "AC5: pilot:held + held-until:<PAST> → dispatchable (unchanged)" \
                              || bad "AC5: pilot:held + expired stamp regressed — now excluded"
kept patched ga-held-bare     && bad "AC5: bare pilot:held regressed — now dispatchable" \
                              || ok  "AC5: bare pilot:held (no stamp) → EXCLUDED (unchanged)"
kept patched ga-pair-garbage  && bad "AC5: pilot:held + unreadable stamp regressed — now dispatchable" \
                              || ok  "AC5: pilot:held + unreadable stamp → EXCLUDED (unchanged)"
kept patched ga-heldcount     && ok  "AC5: pilot:held-count:<slug>:<n> is a different prefix → dispatchable, not confused with a hold" \
                              || bad "AC5: pilot:held-count:* was mistaken for a hold"
kept patched ga-plain         && ok  "AC5: a plain bead is dispatchable" \
                              || bad "AC5: plain bead wrongly excluded"

echo ""
echo "Scenario 2: reason-trace (AC6)"
t="$(trace_of patched ga-alone-future)"
case "$t" in
  *"pilot:held-until(future,no-pilot:held)"*) ok "AC6: FUTURE-alone trace names pilot:held-until(future,no-pilot:held)" ;;
  *) bad "AC6: FUTURE-alone trace missing/wrong (got: '$t')" ;;
esac
t="$(trace_of patched ga-alone-accum)"
case "$t" in
  *"pilot:held-until(future,no-pilot:held)"*) ok "AC6: accumulated-alone trace names the future reason" ;;
  *) bad "AC6: accumulated-alone trace missing/wrong (got: '$t')" ;;
esac
t="$(trace_of patched ga-alone-garbage)"
case "$t" in
  *"pilot:held-until(unreadable,no-pilot:held)"*) ok "AC6: unreadable-alone trace names pilot:held-until(unreadable,no-pilot:held)" ;;
  *) bad "AC6: unreadable-alone trace missing/wrong (got: '$t')" ;;
esac
case "$t" in
  *"(future,"*) bad "AC6: unreadable-alone trace also claims a FUTURE stamp — the two reasons must not both fire (got: '$t')" ;;
  *) ok "AC6: unreadable-alone trace does not also claim 'future'" ;;
esac
for id in ga-pair-future ga-held-bare ga-pair-garbage; do
  t="$(trace_of patched "$id")"
  case "$t" in
    *"pilot:held(not-expired)"*"no-pilot:held"*|*"no-pilot:held"*"pilot:held(not-expired)"*)
      bad "AC6: $id (has pilot:held) is named by BOTH the old and the new reason: '$t'" ;;
    *"no-pilot:held"*)
      bad "AC6: $id (has pilot:held) got a no-pilot:held reason: '$t'" ;;
    *"pilot:held(not-expired)"*)
      ok "AC6: $id keeps its single pilot:held(not-expired) reason" ;;
    *) bad "AC6: $id has no pilot:held(not-expired) trace line (got: '$t')" ;;
  esac
done
for id in ga-plain ga-alone-past ga-pair-past ga-heldcount; do
  if grep -qF "EXCLUÍDO $id " "$WORK/patched.stderr"; then
    bad "AC6: kept bead $id appears in the exclusion trace: $(grep -F "EXCLUÍDO $id " "$WORK/patched.stderr")"
  else
    ok "AC6: kept bead $id produces no exclusion line"
  fi
done

echo ""
if [ -n "$ORIG_DISPATCHER" ] && [ -f "$ORIG_DISPATCHER" ]; then
  echo "Scenario 3: pre-patch differential (AC7)"
  run_filter "$ORIG_DISPATCHER" orig
  for id in ga-alone-future ga-alone-accum ga-alone-garbage; do
    kept orig "$id" && ok "AC7: pre-patch _filter_candidates LEAKS $id (bug reproduced — this test fails on the old code)" \
                    || bad "AC7: pre-patch baseline did not leak $id — the differential proves nothing"
  done
  for id in ga-plain ga-alone-past ga-pair-future ga-pair-past ga-held-bare ga-pair-garbage ga-heldcount; do
    if kept orig "$id"; then o=kept; else o=excluded; fi
    if kept patched "$id"; then p=kept; else p=excluded; fi
    [ "$o" = "$p" ] && ok "AC7: $id answers the same before and after ($p)" \
                    || bad "AC7: $id changed behaviour: pre-patch=$o patched=$p (the fix must only move the held-until-alone cases)"
  done
else
  echo "Scenario 3: (skipped pre-patch differential — set ORIG_DISPATCHER=<pre-patch pilot-dispatcher.sh> to prove this fails on the old code)"
fi

echo ""
echo "Scenario 4: the Pilot agrees with the pool probes' pool_held (AC8)"
POOL_VETOES="$SELF_DIR/scripts/pool-probe-vetoes.sh"
if [ ! -f "$POOL_VETOES" ]; then
  bad "AC8: $POOL_VETOES not found — cannot compare against the shared pool_held definition"
else
  # shellcheck disable=SC1090
  source "$POOL_VETOES"
  agree=0; disagree=0
  for id in $(jq -r '.[].id' "$WORK/input.json"); do
    pool_says="$(jq -c --arg id "$id" --argjson now "$NOW" \
      "${POOL_VETO_JQ_DEFS}"'.[] | select(.id == $id) | pool_held($now)' "$WORK/input.json" 2>&1)"
    if kept patched "$id"; then pilot_says=false; else pilot_says=true; fi
    if [ "$pool_says" = "$pilot_says" ]; then
      agree=$((agree+1))
    else
      disagree=$((disagree+1))
      bad "AC8: $id — pool_held=$pool_says but Pilot excluded=$pilot_says (two readers, two meanings of 'hold')"
    fi
  done
  [ "$disagree" -eq 0 ] && [ "$agree" -gt 0 ] \
    && ok "AC8: Pilot and pool_held agree on all $agree fixtures" \
    || { [ "$disagree" -eq 0 ] && bad "AC8: compared zero fixtures — harness broken"; }
fi

echo ""
echo "held-until-alone selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
