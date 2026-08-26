#!/usr/bin/env bash
# pilot-hold-escalate.selftest.sh — unit tests for _pilot_hold_or_escalate
# (ga-2n7xw), the shared sticky hold/escalate counter used by the 3
# refusal-successor sites in pilot-dispatcher.sh: ga-lfvs6 (domain build, no
# idle crew, cap=3), ga-jazy9 (lane:big, no dog pool, cap=3), ga-4zqwm
# (Mayor-deferred hold, cap=1 — AC4: escalate on the FIRST hold).
#
# Bug ga-2n7xw: a Pilot refusal that only holds-and-retries forever, with no
# counter and no escalation, caused 3 real incidents in 24h (ga-8jxe1 branch-
# veto deadlock, ga-q640n permission-dialog stall, ga-7ti1t unmapped-crew hold
# renewed forever). The invariant: every refusal must ROUTE, ESCALATE, or
# TERMINATE — never silently repeat. This file covers AC1/AC2/AC4/AC5 for the
# shared mechanism; pilot-dispatcher.selftest.sh Scenario ga-2n7xw covers the
# same behaviour END-TO-END through the real dispatch_one() flow for the
# ga-lfvs6/ga-jazy9 sites (ga-4zqwm has no end-to-end harness in either file —
# see that scenario's header comment for why).
#
# This harness extracts JUST _pilot_hold_or_escalate's source from the live
# dispatcher — the same awk-extraction pattern pilot-dispatcher.selftest.sh
# already uses for bead_content_rig (its `_BCR_FN` / Scenario 18j) — and evals
# it standalone against minimal fake bd/gc/log/warn SHELL FUNCTIONS (not a
# PATH shim — no subprocess needed since we're testing one function in-process).
# Every bd/gc invocation the function makes is recorded verbatim so assertions
# can check WHICH mutation happened, not just that a log line appeared (AC5's
# explicit caution: assert by which path, not just that "something happened").
#
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

# ── Extract _pilot_hold_or_escalate's source verbatim from the live file ──────
HOLD_FN="$(awk '/^_pilot_hold_or_escalate\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$HOLD_FN" ]; then
  echo "FATAL: _pilot_hold_or_escalate() not found in $DISPATCHER (extraction pattern drifted?)" >&2
  exit 2
fi

# ── _pilot_defer_extend (ga-sfj3i.1) — extracted here, near the top, NOT next
# to its own D1-D9 scenarios below, because Scenario H (further down) needs it
# in scope too. ga-m365u: _mayor_deferred_hold_db now calls _pilot_defer_extend,
# but Scenario H's isolated subshell only ever eval'd MDH_FN+HOLD_FN — under
# this file's own `set -uo pipefail` (no -e), the resulting "command not
# found" was silently swallowed (Scenario H's assertions check OTHER bd calls
# that still fire regardless), so 50/50 passed while the wiring was actually
# broken. Extracting DEFER_FN here — before Scenario H's subshell — and eval'ing
# it there alongside the other two closes the gap at its root: any function a
# scenario's real call graph touches must be in scope BEFORE that scenario
# runs, not just before its own dedicated section.
DEFER_FN="$(awk '/^_pilot_defer_extend\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$DEFER_FN" ]; then
  echo "FATAL: _pilot_defer_extend() not found in $DISPATCHER (extraction pattern drifted?)" >&2
  exit 2
fi

# ── Workspace + call-log capture ───────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-hold-escalate-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CALLS="$WORK/calls.log"

# Fake bd/gc/log/warn as plain shell functions (inherited by the `( )` subshell
# run_hold spawns — no PATH shim / subprocess needed to test one pure-ish
# function). Every bd/gc call is appended to $CALLS as "<cmd>\t<argv>".
bd()   { printf 'bd\t%s\n'   "$*" >> "$CALLS"; }
gc()   { printf 'gc\t%s\n'   "$*" >> "$CALLS"; }
log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
warn() { printf 'warn\t%s\n' "$*" >> "$CALLS"; }

# run_hold <db> <id> <slug> <reason> <unblock> <labels_json> <cap> <dry(0|1)>
# Empty <cap> falls back to PILOT_HOLD_ESCALATE_CAP (defaulted to 3 here,
# matching the live file's own default) exactly like the real call sites.
run_hold() {
  : > "$CALLS"
  ( DRY_RUN="${8:-0}"
    PILOT_HOLD_ESCALATE_CAP="${PILOT_HOLD_ESCALATE_CAP:-3}"
    eval "$HOLD_FN"
    _pilot_hold_or_escalate "$1" "$2" "$3" "$4" "$5" "$6" "$7" )
}

has_call() { grep -qF -- "$1" "$CALLS" 2>/dev/null; }   # exact-substring, any recorded call

echo "pilot-hold-escalate.selftest — shared hold/escalate counter (ga-2n7xw)"

# ── Scenario A (AC1): DRY_RUN — counter math logged, but NEVER mutates ────────
echo "Scenario A: DRY_RUN hold #1 (ga-lfvs6, cap=3) logs count=1/3, makes no bd/gc call"
run_hold "db1" "bd-1" "ga-lfvs6" "no idle crew" "map a crew" '[]' 3 1
if has_call "log	[pilot-hold] WOULD stamp pilot:held-count:ga-lfvs6:1 on bd-1 (hold 1/3)"; then
  ok "DRY_RUN first hold logs the correct count/cap"
else
  bad "DRY_RUN first hold did not log the expected text (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -qE '^(bd|gc)	' "$CALLS"; then
  bad "REGRESSION: DRY_RUN performed a real bd/gc mutation"
else
  ok "DRY_RUN performs no bd/gc mutation (log-only)"
fi

echo "Scenario A2: DRY_RUN hold #3 (prior count=2) logs WOULD ESCALATE, not another WOULD stamp"
run_hold "db1" "bd-1" "ga-lfvs6" "no idle crew" "map a crew" '["pilot:held-count:ga-lfvs6:2"]' 3 1
if has_call "log	[pilot-hold] WOULD ESCALATE bd-1 (ga-lfvs6, hold 3/3) to Mayor: no idle crew"; then
  ok "DRY_RUN 3rd hold logs WOULD ESCALATE with the right count/slug/reason"
else
  bad "DRY_RUN 3rd hold did not log the expected ESCALATE text"
fi
if has_call "WOULD stamp pilot:held-count:ga-lfvs6:3"; then
  bad "REGRESSION: 3rd hold logged a plain stamp instead of escalating"
else
  ok "3rd hold did not fall back to a plain-hold log line"
fi

# ── Scenario B (AC1/AC2): real mutation — counter stamp + purge of stale stamp
echo "Scenario B: real (non-dry) hold #2 stamps count=2 and purges the stale count=1 stamp"
run_hold "propdb" "bd-2" "ga-lfvs6" "no idle crew" "map a crew" '["lane:small","pilot:held-count:ga-lfvs6:1"]' 3 0
if has_call "bd	-C propdb label add bd-2 pilot:held-count:ga-lfvs6:2 -q"; then
  ok "real hold #2 stamps pilot:held-count:ga-lfvs6:2 against the bead's OWN db (propdb)"
else
  bad "real hold #2 did not stamp the expected counter label"
fi
if has_call "bd	-C propdb label remove bd-2 pilot:held-count:ga-lfvs6:1 -q"; then
  ok "real hold #2 purges the stale count=1 stamp (no unbounded label accumulation)"
else
  bad "real hold #2 did not purge the stale stamp"
fi
if has_call "bd	-C propdb label remove bd-2 pilot:held-count:ga-lfvs6:2 -q"; then
  bad "REGRESSION: the just-added count=2 stamp was purged as if it were stale"
else
  ok "the freshly-added stamp itself was correctly excluded from the purge"
fi
if has_call "gate:needs-human" || has_call "mail send mayor"; then
  bad "REGRESSION: hold #2 (below cap=3) escalated — should only escalate AT the cap"
else
  ok "hold #2 (below cap) did not escalate"
fi

# ── Scenario C (AC2): real escalation at cap — labels + comment + Mayor mail ──
echo "Scenario C: real hold #3 (AT cap=3) adds gate:needs-human(:technical), comments, and mails the Mayor"
run_hold "propdb" "bd-3" "ga-lfvs6" "no idle crew (owning crew: unmapped)" "map/free a crew for property_scrapers" '["pilot:held-count:ga-lfvs6:2"]' 3 0
if has_call "bd	-C propdb label add bd-3 gate:needs-human -q"; then
  ok "escalation adds the bare gate:needs-human label (excluded from all future dispatch candidacy)"
else
  bad "escalation did not add gate:needs-human"
fi
if has_call "bd	-C propdb label add bd-3 gate:needs-human:technical -q"; then
  ok "escalation adds gate:needs-human:technical (hooks the quorum-convergence-watchdog safety net)"
else
  bad "escalation did not add gate:needs-human:technical"
fi
if has_call "bd	-C propdb comment bd-3"; then
  ok "escalation comments the bead"
else
  bad "escalation did not comment the bead"
fi
if has_call "gc	--city" && has_call "mail send mayor" && has_call "Pilot hold escalation (ga-lfvs6): bd-3"; then
  ok "escalation mails the Mayor with a subject naming the slug and bead id"
else
  bad "escalation did not mail the Mayor as expected (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if has_call "no idle crew (owning crew: unmapped)" ; then
  ok "the literal refusal reason (AC2) is carried into the escalation (comment or mail body)"
else
  bad "the literal reason text did not appear anywhere in the escalation calls"
fi
if has_call "map/free a crew for property_scrapers"; then
  ok "the unblock hint (AC2: 'o que destravaria') is carried into the escalation"
else
  bad "the unblock hint did not appear in the escalation calls"
fi
if has_call "bd	-C propdb label add bd-3 pilot:held-count:ga-lfvs6:3 -q"; then
  ok "the counter is still stamped even on the escalating call (observability survives escalation)"
else
  bad "the counter was not stamped on the escalating call"
fi

# ── Scenario D (AC4): ga-4zqwm passes cap=1 — escalates on the FIRST hold ─────
echo "Scenario D: ga-4zqwm (Mayor-deferred hold) escalates on hold #1 — no 3-strikes wait"
run_hold "hq" "bd-4" "ga-4zqwm" "depends on a human to clear it" "Mayor reviews and clears/routes/closes" '[]' 1 0
if has_call "bd	-C hq label add bd-4 gate:needs-human -q" && has_call "mail send mayor"; then
  ok "ga-4zqwm (cap=1) escalates on its very first hold, per AC4 (a design that depends on a human must call the human immediately)"
else
  bad "ga-4zqwm did not escalate on its first hold (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if has_call "pilot:held-count:ga-4zqwm:1"; then
  ok "ga-4zqwm still stamps its own counter at 1 (sticky, survives hold expiry per AC1)"
else
  bad "ga-4zqwm did not stamp its counter"
fi

# ── Scenario E: cross-slug isolation — one site's count never leaks into another
echo "Scenario E: a bead already at ga-jazy9's cap does NOT affect a fresh ga-lfvs6 count on the SAME bead"
run_hold "db1" "bd-5" "ga-lfvs6" "no idle crew" "map a crew" '["pilot:held-count:ga-jazy9:9"]' 3 1
if has_call "log	[pilot-hold] WOULD stamp pilot:held-count:ga-lfvs6:1 on bd-5 (hold 1/3)"; then
  ok "ga-lfvs6's counter starts fresh at 1 despite an unrelated ga-jazy9:9 label on the same bead (namespaces are independent)"
else
  bad "REGRESSION: cross-slug isolation broke — ga-jazy9's count leaked into ga-lfvs6's (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

# ── Scenario F: malformed counter labels degrade safely, never crash ──────────
echo "Scenario F: a non-numeric pilot:held-count:<slug>:* label is ignored, not fatal"
run_hold "db1" "bd-6" "ga-lfvs6" "no idle crew" "map a crew" '["pilot:held-count:ga-lfvs6:notanumber"]' 3 1
if has_call "log	[pilot-hold] WOULD stamp pilot:held-count:ga-lfvs6:1 on bd-6 (hold 1/3)"; then
  ok "a malformed counter label is ignored — count safely defaults to 0 → 1, no crash"
else
  bad "malformed counter label was not handled safely (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

# ── Scenario G: drift-guards — the helper is actually wired into all 3 sites ──
# (AC1/AC2/AC3/AC4 only matter if the real call sites actually invoke this
# function; the scenarios above only prove the function is CORRECT in
# isolation. Belt-and-suspenders against a future edit that quietly detaches
# a call site while leaving the helper itself untouched.)
echo "Scenario G: drift-guard — all 3 refusal sites call _pilot_hold_or_escalate with their own slug"
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has '_pilot_hold_or_escalate\(\) \{'                                         "helper _pilot_hold_or_escalate is defined"
has '_pilot_hold_or_escalate "\$STORY_BEAD_CITY" "\$STORY_ID" "ga-lfvs6"'    "ga-lfvs6 (domain build) call site is wired"
has '_pilot_hold_or_escalate "\$STORY_BEAD_CITY" "\$STORY_ID" "ga-jazy9"'    "ga-jazy9 (lane:big) call site is wired"
has '_pilot_hold_or_escalate "\$_db" "\$_bid" "ga-4zqwm"'                    "ga-4zqwm (Mayor-deferred) call site is wired"
# ga-4zqwm must pass an explicit cap of 1 (AC4) — the call spans 5 lines
# (continued with trailing backslashes), ending in a bare "1" argument.
if grep -A6 '_pilot_hold_or_escalate "\$_db" "\$_bid" "ga-4zqwm"' "$DISPATCHER" | grep -qE '^\s*1\s*$'; then
  ok "ga-4zqwm passes an explicit cap of 1 (AC4: escalate on the first hold, not the 3rd)"
else
  bad "ga-4zqwm call site no longer passes an explicit cap=1 — AC4 regression risk"
fi

# ── Scenario H: real end-to-end smoke test of _mayor_deferred_hold_db calling
# through to _pilot_hold_or_escalate (ga-4zqwm). This is the ONE site with no
# other selftest coverage anywhere (unlike ga-lfvs6/ga-jazy9, which also get
# a full run_capacity()-driven end-to-end scenario in the sibling
# pilot-dispatcher.selftest.sh — Scenario ga-2n7xw). Extracts BOTH real
# functions (not mocked) and drives them against a fake bd/gc returning one
# genuinely-qualifying in-flight bead + its pool:refused:mayor-deferred
# sling, proving the cross-reference plumbing (in-flight bead → its sling →
# the sling's OWN labels) actually reaches the new call, not just that the
# call site text is present (Scenario G already proves that separately).
echo "Scenario H: _mayor_deferred_hold_db end-to-end — a genuinely-qualifying bead escalates on its first hold (AC4)"
MDH_FN="$(awk '/^_mayor_deferred_hold_db\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$MDH_FN" ]; then
  bad "FATAL: _mayor_deferred_hold_db() not found in $DISPATCHER (extraction pattern drifted?)"
else
  : > "$CALLS"
  (
    DRY_RUN=0
    GC_CITY="hq"
    MAYOR_DEFERRED_HOLD_SECS=86400
    bd() {
      local out=""
      case "$*" in
        *"list --json"*"story:in-flight"*"pilot:dispatched"*)
          out='[{"id":"mh-bead1","labels":["story:in-flight","pilot:dispatched"],"metadata":{"pilot.sling_bead":"mh-sling1"}}]' ;;
        *"show mh-sling1 --json"*)
          out='{"id":"mh-sling1","labels":["pool:refused:mayor-deferred"]}' ;;
        *"show mh-bead1 --json"*)
          out='{"id":"mh-bead1","labels":["story:in-flight","pilot:dispatched"]}' ;;
      esac
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      [ -n "$out" ] && printf '%s' "$out"
    }
    gc()   { printf 'gc\t%s\n'   "$*" >> "$CALLS"; }
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$CALLS"; }
    eval "$MDH_FN"
    eval "$HOLD_FN"
    eval "$DEFER_FN"
    _mayor_deferred_hold_db "hq" "$(date +%s)"
  )
  if has_call "bd	-C hq label add mh-bead1 pilot:held -q"; then
    ok "pre-existing pilot:held stamping still fires unchanged (AC6 — refusal itself not weakened)"
  else
    bad "pre-existing pilot:held stamping did not fire — the cross-reference plumbing may be broken"
  fi
  if has_call "bd	-C hq label add mh-bead1 pilot:held-count:ga-4zqwm:1 -q"; then
    ok "the new counter reaches _pilot_hold_or_escalate through the real cross-reference lookup"
  else
    bad "AC1/AC4 regression: the counter was never stamped — _mayor_deferred_hold_db did not call through"
  fi
  if has_call "bd	-C hq label add mh-bead1 gate:needs-human -q" && has_call "mail send mayor"; then
    ok "AC4: escalates to the Mayor on the FIRST genuinely-qualifying hold, end-to-end"
  else
    bad "AC4 regression: did not escalate end-to-end (dump: $(cat "$CALLS" | tr '\n' '|'))"
  fi
  # ga-m365u: the assertions above only prove the PRE-EXISTING labels/escalation
  # still fire — none of them ever checked the NEW _pilot_defer_extend wiring
  # itself. Without DEFER_FN in scope (fixed above), this call would silently
  # fail to even happen; now that it's in scope, assert the real bd update
  # --defer call actually fires with a well-formed ISO8601 target (the exact
  # timestamp is wall-clock-dependent — _now is real `date +%s` at test-run
  # time plus MAYOR_DEFERRED_HOLD_SECS — so match the STRUCTURE, not a literal
  # value).
  if grep -qE '^bd	-C hq update mh-bead1 --defer [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z -q$' "$CALLS"; then
    ok "ga-m365u: the real bd -C hq update mh-bead1 --defer <iso> call fires end-to-end — proves the epoch-to-ISO wiring between _mayor_deferred_hold_db and _pilot_defer_extend actually connects, not just that both functions exist in isolation"
  else
    bad "ga-m365u regression: the end-to-end defer call never fired from _mayor_deferred_hold_db (dump: $(cat "$CALLS" | tr '\n' '|'))"
  fi
fi

# ── Scenario I (ga-1mqdz AC3): explicitly-parked beads skip hold/escalation ──
# Bug ga-1mqdz: a bead already parked by an EXPLICIT human/Mayor decision
# (pilot:no-auto-dispatch, or any needs-human/needs-approval gate label) must
# not have its hold counted or escalated — that counter exists for beads that
# SHOULD be flowing and genuinely aren't (e.g. "no idle crew"), not for beads
# a human already told the Pilot to leave alone. Real incident (dolt_diff-
# confirmed on ga-t8274/ga-i0n83): pilot:no-auto-dispatch predated the first
# hold by 5 days, yet 3 holds were counted and escalated anyway before AC1
# (the candidacy fix, tested separately) closes the primary gap — this is the
# defense-in-depth layer for any OTHER path that might still reach this
# function on an explicitly-parked bead.
echo "Scenario I: pilot:no-auto-dispatch bead skips hold/escalation entirely — no stamp, no mail, no comment"
run_hold "db1" "bd-parked" "ga-lfvs6" "no idle crew" "map a crew" '["pilot:no-auto-dispatch"]' 3 0
if has_call "already parked by explicit decision"; then
  ok "logs the skip reason (no-auto-dispatch/needs-human)"
else
  bad "did not log the expected skip reason (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -qE '^(bd|gc)	' "$CALLS"; then
  bad "REGRESSION: pilot:no-auto-dispatch bead triggered a real bd/gc mutation (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  ok "no bd/gc mutation at all for a no-auto-dispatch bead (no stamp, no escalation labels, no mail)"
fi

echo "Scenario I2: gate:needs-human bead ALSO skips hold/escalation (same explicit-decision family)"
run_hold "db1" "bd-parked2" "ga-jazy9" "no dog pool" "wait for a persistent crew" '["gate:needs-human"]' 3 0
if has_call "already parked by explicit decision"; then
  ok "gate:needs-human bead also logs the skip reason"
else
  bad "gate:needs-human bead did not skip (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -qE '^(bd|gc)	' "$CALLS"; then
  bad "REGRESSION: gate:needs-human bead triggered a real bd/gc mutation (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  ok "gate:needs-human bead: no bd/gc mutation, no hold-count stamp, no escalation"
fi

echo "Scenario I3 (AT cap — must NOT re-escalate): a bead already at cap AND explicitly parked stays skipped"
run_hold "db1" "bd-parked3" "ga-lfvs6" "no idle crew" "map a crew" '["pilot:no-auto-dispatch","pilot:held-count:ga-lfvs6:3"]' 3 0
if has_call "mail send mayor"; then
  bad "REGRESSION: an explicitly-parked bead at cap was RE-escalated (should stay silent — already the Mayor's to unpark)"
else
  ok "explicitly-parked bead at cap does not re-escalate"
fi

echo "Scenario I4 (no false-positive): a normal bead with NO explicit-decision label still holds/escalates exactly as before"
run_hold "db1" "bd-normal" "ga-lfvs6" "no idle crew" "map a crew" '["lane:small"]' 3 1
if has_call "log	[pilot-hold] WOULD stamp pilot:held-count:ga-lfvs6:1 on bd-normal (hold 1/3)"; then
  ok "a normal (unparked) bead is unaffected by the AC3 skip — holds exactly as before"
else
  bad "REGRESSION: AC3 skip over-fired on a bead with no explicit-decision label (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

echo "Scenario I5: drift-guard — the AC3 skip is wired into _pilot_hold_or_escalate"
echo "$HOLD_FN" | grep -q 'pilot:no-auto-dispatch' && ok "_pilot_hold_or_escalate carries the pilot:no-auto-dispatch skip clause" || bad "pilot:no-auto-dispatch skip clause missing from _pilot_hold_or_escalate"

# ── Scenario I6 (ga-rfpm9): bare "no-auto-dispatch" (no pilot: prefix) is a
# DIFFERENT string this function's AC3 skip never recognized pre-fix — same
# bare-label gap already fixed in _filter_candidates (pilot-dispatcher.selftest.sh
# Scenario ga-rfpm9) and context_check_is_parked (context-check-dispatcher.
# selftest.sh). Mirrors Scenario I exactly, bare label only.
echo "Scenario I6 (ga-rfpm9): bare no-auto-dispatch bead ALSO skips hold/escalation entirely — no stamp, no mail, no comment"
run_hold "db1" "bd-parked-bare" "ga-lfvs6" "no idle crew" "map a crew" '["no-auto-dispatch"]' 3 0
if has_call "already parked by explicit decision"; then
  ok "bare no-auto-dispatch also logs the skip reason (ga-rfpm9)"
else
  bad "REGRESSION: bare no-auto-dispatch did not skip (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -qE '^(bd|gc)	' "$CALLS"; then
  bad "REGRESSION: bare no-auto-dispatch bead triggered a real bd/gc mutation (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  ok "no bd/gc mutation at all for a bare no-auto-dispatch bead (ga-rfpm9)"
fi

echo "Scenario I7: drift-guard — the bare no-auto-dispatch alias is wired into _pilot_hold_or_escalate (ga-rfpm9)"
echo "$HOLD_FN" | grep -q '"no-auto-dispatch"' && ok "_pilot_hold_or_escalate carries the bare no-auto-dispatch skip clause" || bad "bare no-auto-dispatch skip clause missing from _pilot_hold_or_escalate"

# ── _pilot_defer_extend (ga-sfj3i.1) ───────────────────────────────────────────
# A Pilot timed hold (the pilot:held-until label stamped by ga-lfvs6/ga-4zqwm)
# never actually stopped a bd-ready-based self-serve pool probe (dog Step
# 1a/1c, wa-worker/ps-worker) from claiming the bead mid-hold — confirmed live
# on ga-z297h. _pilot_defer_extend makes a timed hold ALSO set the bead's real
# defer_until (the one field every such probe already respects), with an
# "extend, never shorten" guard so a short automatic hold can never clobber a
# longer hold already in place (wa-2lzmz-class incident). DEFER_FN itself is
# extracted near the top of this file (before Scenario H), not here — see the
# ga-m365u comment there for why.

# run_defer <db> <id> <new_iso> [<cur_defer_iso_or_empty>] [<dry(0|1)>] [<simulate_show_failure(0|1)>]
# The fake bd() here additionally SERVES `show <id> --json` with a
# controllable current defer_until, since _pilot_defer_extend reads it back
# before deciding whether to extend — the plain call-logging fake bd() at the
# top of this file (used by run_hold) can't do that. simulate_show_failure=1
# makes the fake `show` return non-zero with no output, exercising the
# fail-closed path (a real Dolt hiccup must not be read as "no current hold").
run_defer() {
  : > "$CALLS"
  ( DRY_RUN="${5:-0}"
    _RD_ID="$2" _RD_CUR="${4:-}" _RD_FAIL="${6:-0}"
    bd() {
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      case "$*" in
        *"show $_RD_ID --json"*)
          [ "$_RD_FAIL" = "1" ] && return 1
          if [ -n "$_RD_CUR" ]; then
            printf '[{"defer_until":"%s"}]' "$_RD_CUR"
          else
            printf '[{"defer_until":null}]'
          fi
          ;;
      esac
    }
    eval "$DEFER_FN"
    _pilot_defer_extend "$1" "$2" "$3" )
}

echo "Scenario D1: no existing defer_until — sets defer to the new target"
run_defer "propdb" "bd-10" "2026-08-25T22:00:00Z" "" 0
if has_call "bd	-C propdb update bd-10 --defer 2026-08-25T22:00:00Z -q"; then
  ok "sets defer_until when none existed"
else
  bad "did not set defer_until (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

echo "Scenario D2: existing defer_until EARLIER than new target — extends to the new (later) value"
run_defer "propdb" "bd-11" "2026-08-26T10:00:00Z" "2026-08-25T09:00:00Z" 0
if has_call "bd	-C propdb update bd-11 --defer 2026-08-26T10:00:00Z -q"; then
  ok "extends defer_until to the later target"
else
  bad "did not extend defer_until (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

echo "Scenario D3 (never-shorten): existing defer_until LATER than new target — does not shorten"
run_defer "propdb" "bd-12" "2026-08-25T10:00:00Z" "2026-08-27T00:00:00Z" 0
if has_call "bd	-C propdb update bd-12 --defer"; then
  bad "REGRESSION: shortened an existing longer defer (wa-2lzmz-class incident)"
else
  ok "never-shorten: kept the existing longer defer_until untouched"
fi
if has_call "keeping existing defer_until"; then
  ok "logs why the shorter hold was skipped"
else
  bad "did not log the never-shorten decision"
fi

echo "Scenario D4 (equal boundary): existing defer_until EQUAL to new target — treated as not-older, no redundant update"
run_defer "propdb" "bd-13" "2026-08-25T10:00:00Z" "2026-08-25T10:00:00Z" 0
if has_call "bd	-C propdb update bd-13 --defer"; then
  bad "REGRESSION: re-issued an update for an equal (not actually longer) target"
else
  ok "equal defer_until treated as not-older — no redundant bd update"
fi

echo "Scenario D5: DRY_RUN — logs WOULD defer, no real bd update call"
run_defer "propdb" "bd-14" "2026-08-25T22:00:00Z" "" 1
if has_call "WOULD defer bd-14"; then
  ok "DRY_RUN logs the intended defer"
else
  bad "DRY_RUN did not log WOULD defer"
fi
if has_call "update bd-14 --defer"; then
  bad "REGRESSION: DRY_RUN performed a real bd update"
else
  ok "DRY_RUN performs no real mutation"
fi

echo "Scenario D7 (fail-closed, third-state): bd show fails/unreadable — does NOT write a defer (never clobber an unverifiable existing hold)"
run_defer "propdb" "bd-15" "2026-08-25T22:00:00Z" "" 0 1
if has_call "bd	-C propdb update bd-15 --defer"; then
  bad "REGRESSION: wrote a defer despite being unable to verify the current value"
else
  ok "fail-closed: no defer written when the current value could not be verified"
fi
if has_call "could not verify current defer_until"; then
  ok "logs the fail-closed reason (not silent)"
else
  bad "did not log why the write was skipped"
fi

echo "Scenario D8 (empty new_iso guard): an empty new-defer target is refused outright, never reaches bd update"
run_defer "propdb" "bd-16" "" "" 0
if grep -qE '^bd\t' "$CALLS"; then
  bad "REGRESSION: made a bd call at all for an empty new-defer target (would risk clearing defer_until via --defer '')"
else
  ok "refuses an empty new-defer target before any bd call — cannot accidentally clear defer_until"
fi

echo "Scenario D9 (errexit safety, ga-061ua): _pilot_defer_extend survives set -euo pipefail with a genuinely failing bd — does not crash the caller"
# ga-061ua: gate review caught that the D7 fail-closed path above was
# UNREACHABLE in production — pilot-dispatcher.sh runs under `set -euo
# pipefail` (its own line 74), and a bare `VAR=$(cmd); rc=$?` never reaches
# the rc= line when cmd fails, since the assignment's own failure aborts the
# whole dispatcher right there. D7 (above) uses a shell FUNCTION override for
# bd, which runs in THIS file's own harness (set -uo pipefail — no -e), so it
# could never have caught that class of bug: it proves the DECISION LOGIC is
# right, not that the caller survives to reach it. This scenario runs the
# extracted function in a FRESH bash process with -e actually enabled (the
# same option the real dispatcher runs under) and a `bd` that genuinely
# returns non-zero, so a regression back to the unguarded pattern fails here
# even though D7 would still pass.
D9_SCRIPT="$WORK/errexit-check.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'log() { :; }'
  echo 'DRY_RUN=0'
  echo 'bd() { return 17; }'
  printf '%s\n' "$DEFER_FN"
  echo '_pilot_defer_extend "propdb" "bd-errexit-test" "2026-08-25T22:00:00Z"'
  echo 'echo SURVIVED'
} > "$D9_SCRIPT"
D9_OUT="$(bash "$D9_SCRIPT" 2>&1)"
D9_RC=$?
if [ "$D9_RC" -eq 0 ] && printf '%s' "$D9_OUT" | grep -q "SURVIVED"; then
  ok "survives set -e with a failing bd show (does not abort the dispatcher mid-sweep)"
else
  bad "REGRESSION (ga-061ua): crashes under set -e when bd show fails (rc=$D9_RC, out: $D9_OUT)"
fi

echo "Scenario D6: drift-guard — both timed-hold call sites (ga-lfvs6, ga-4zqwm) wire in _pilot_defer_extend"
if grep -qF -- '_pilot_defer_extend "$STORY_BEAD_CITY" "$STORY_ID"' "$DISPATCHER"; then
  ok "ga-lfvs6 site calls _pilot_defer_extend"
else
  bad "ga-lfvs6 site does not call _pilot_defer_extend — pilot:held-until would again be probe-invisible"
fi
if grep -qF -- '_pilot_defer_extend "$_db" "$_bid"' "$DISPATCHER"; then
  ok "ga-4zqwm site calls _pilot_defer_extend"
else
  bad "ga-4zqwm site does not call _pilot_defer_extend — pilot:held-until would again be probe-invisible"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "pilot-hold-escalate.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
