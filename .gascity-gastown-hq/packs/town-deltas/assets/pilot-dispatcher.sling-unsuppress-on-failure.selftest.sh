#!/usr/bin/env bash
# pilot-dispatcher.sling-unsuppress-on-failure.selftest.sh — unit tests for
# _pilot_unsuppress_sling and _pilot_selfheal_expired_slings (ga-h6trx3).
#
# Bug ga-h6trx3: when _pilot_pool_target_has_live_session (ga-hpc1x) finds a
# live pool instance, dispatch_one() suppresses the sling's pool-visibility
# via _pilot_suppress_reused_sling (bounded defer, ~300s) "in case the nudge
# below lands on it directly." But for EPHEMERAL POOL targets, _DISPATCH_REUSE
# is force-0 (gt-4st3n's _skip_reuse), so delivery always takes the `else`
# branch: `gc session nudge "$_SLING_TARGET"` where $_SLING_TARGET is a POOL
# TEMPLATE (e.g. "gastown.dog"), not a session id/alias — `gc session nudge`
# always fails against a template. The failure was silently swallowed (only
# a `warn`, misleadingly claiming "builder will see the task bead on next
# hook cycle" — false, since the sling was just hidden), leaving the sling
# held+deferred with nothing to undo it except lifecycle-coherence-janitor's
# R6 rule. R6's MEASURED sweep-to-sweep cadence (11-17min runtime + ~10min
# gap after each exit = 21-27min between visits) can outlast
# inflight-reclaim-guard's 25min RECLAIM_TTL. Confirmed live 2026-09-15:
# ga-00ghg5's sling stayed hidden ~27min, crossing RECLAIM_TTL before any dog
# saw it; ga-0bjqix was re-dispatched 5x in one morning this way (reclaim-
# count 2/3).
#
# The fix, two parts:
#   1. _pilot_unsuppress_sling(city, id) — mirrors R6's own strip+undefer
#      sequence exactly (safe no-op on a bead that was never held). Called
#      from BOTH delivery branches (REUSE submit and pool nudge) the moment
#      delivery fails, in the SAME dispatch_one() execution — no dependency
#      on R6 or a later Pilot sweep for the dominant (delivery-failed) case.
#   2. _pilot_selfheal_expired_slings(city) — a defense-in-depth backstop for
#      the residual case (delivery reports success but the target session
#      never acts on it): at the START of every sweep, Pilot undoes its OWN
#      expired sling holds — scoped to beads carrying metadata
#      pilot.sling_for (never the unrelated ga-4zqwm/ga-lfvs6 mayor-deferred
#      STORY-bead holds, which share the same label pair on purpose). Runs on
#      Pilot's own ~12-16min sweep-start cadence, not R6's slower ~21-27min.
#
# This harness extracts both functions verbatim from the live dispatcher —
# the same awk-extraction + fake bd/gc/log/warn shell-function pattern
# pilot-dispatcher.sling-reuse-suppress.selftest.sh already uses for the
# neighboring suppression helpers.
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

# ── Extract both functions verbatim from the live file ─────────────────────
UNSUPPRESS_FN="$(awk '/^_pilot_unsuppress_sling\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$UNSUPPRESS_FN" ]; then
  echo "FATAL: _pilot_unsuppress_sling() not found in $DISPATCHER (ga-h6trx3 fix missing, or extraction pattern drifted)" >&2
  exit 2
fi
SELFHEAL_FN="$(awk '/^_pilot_selfheal_expired_slings\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$SELFHEAL_FN" ]; then
  echo "FATAL: _pilot_selfheal_expired_slings() not found in $DISPATCHER (ga-h6trx3 fix missing, or extraction pattern drifted)" >&2
  exit 2
fi

# ── Sandbox + call-log capture ───────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-sling-unsuppress-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
CALLS="$WORK/calls.log"

# run_unsuppress <city> <id> <bead_json_or_empty> [<dry(0|1)>]
# Fake bd() serves the bead's own `show <id> --json` read from the given
# canned body, and records every call verbatim.
run_unsuppress() {
  : > "$CALLS"
  local _ru_city="$1" _ru_id="$2" _ru_bead_json="$3" _ru_dry="${4:-0}"
  (
    DRY_RUN="$_ru_dry"
    bd() {
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      case "$*" in
        *"show $_ru_id --json"*) printf '%s' "$_ru_bead_json" ;;
      esac
    }
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    eval "$UNSUPPRESS_FN"
    _pilot_unsuppress_sling "$_ru_city" "$_ru_id"
  )
}

# run_selfheal <city> <held_ids_json_array> <bead_json_by_id_fn_body> [<dry(0|1)>]
# Fake bd() serves `list -l pilot:held --json -n 0` from the given id array,
# and `show <id> --json` by delegating to a caller-supplied shell function
# `_bead_for`. Records every bd/log call verbatim (deduped per-id calls all
# land in the same log, in order).
run_selfheal() {
  : > "$CALLS"
  local _rs_city="$1" _rs_ids_json="$2" _rs_dry="${3:-0}"
  (
    DRY_RUN="$_rs_dry"
    bd() {
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      case "$*" in
        *"list -l pilot:held --json -n 0"*) printf '%s' "$_rs_ids_json" ;;
        *"show "*" --json"*)
          local _id; _id=$(printf '%s' "$*" | awk '{for(i=1;i<=NF;i++) if($i=="show"){print $(i+1); exit}}')
          _bead_for "$_id"
          ;;
      esac
    }
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    eval "$UNSUPPRESS_FN"
    eval "$SELFHEAL_FN"
    _pilot_selfheal_expired_slings "$_rs_city"
  )
}

# run_unsuppress_strict / run_selfheal_strict — same as run_unsuppress /
# run_selfheal above, except the subshell runs under `set -euo pipefail`,
# matching pilot-dispatcher.sh's own top-of-file pragma (line 74) exactly.
# run_unsuppress/run_selfheal only set -uo pipefail (no -e), so they cannot
# observe a set -e-triggered abort inside the extracted function body —
# gate_run ga-b9h503 (fix-attempt 2, SHA 690dcb6e) found exactly this: a
# bare `x=$(... | grep ... | head -1)` with no match exits non-zero under
# pipefail, and set -e then killed the WHOLE Pilot process before the very
# next line's `[ -n "$x" ]` graceful check — which exists specifically to
# handle a no-match — ever ran. These wrappers reproduce the real pragma so
# that class of bug cannot hide behind a laxer harness a second time. On
# success the subshell's last action appends the literal marker line
# "SURVIVED" to $CALLS; a pre-marker set -e abort means the caller never
# sees it — that absence IS the crash signal, checked via has_call.
run_unsuppress_strict() {
  : > "$CALLS"
  local _rus_city="$1" _rus_id="$2" _rus_bead_json="$3" _rus_dry="${4:-0}"
  (
    set -euo pipefail
    DRY_RUN="$_rus_dry"
    bd() {
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      case "$*" in
        *"show $_rus_id --json"*) printf '%s' "$_rus_bead_json" ;;
      esac
    }
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    eval "$UNSUPPRESS_FN"
    _pilot_unsuppress_sling "$_rus_city" "$_rus_id"
    echo "SURVIVED" >> "$CALLS"
  )
}

run_selfheal_strict() {
  : > "$CALLS"
  local _rss_city="$1" _rss_ids_json="$2" _rss_dry="${3:-0}"
  (
    set -euo pipefail
    DRY_RUN="$_rss_dry"
    bd() {
      printf 'bd\t%s\n' "$*" >> "$CALLS"
      case "$*" in
        *"list -l pilot:held --json -n 0"*) printf '%s' "$_rss_ids_json" ;;
        *"show "*" --json"*)
          local _id; _id=$(printf '%s' "$*" | awk '{for(i=1;i<=NF;i++) if($i=="show"){print $(i+1); exit}}')
          _bead_for "$_id"
          ;;
      esac
    }
    log()  { printf 'log\t%s\n'  "$*" >> "$CALLS"; }
    eval "$UNSUPPRESS_FN"
    eval "$SELFHEAL_FN"
    _pilot_selfheal_expired_slings "$_rss_city"
    echo "SURVIVED" >> "$CALLS"
  )
}

has_call() { grep -qF -- "$1" "$CALLS" 2>/dev/null; }
count_call() { grep -cF -- "$1" "$CALLS" 2>/dev/null; }

echo "pilot-dispatcher.sling-unsuppress-on-failure.selftest — same-execution undo + sweep-start self-heal (ga-h6trx3)"

# ── Scenario A: held sling (pilot:held + held-until) → strip both, undefer ──
echo "Scenario A: sling carries pilot:held + pilot:held-until:<epoch> — strips both labels, undefers"
BEAD_A='[{"labels":["pilot:dispatched","pilot:held","pilot:held-until:1999999999"]}]'
run_unsuppress "hq" "sling-a" "$BEAD_A" 0
if has_call "bd	-C hq label remove sling-a pilot:held -q"; then
  ok "stripped pilot:held"
else
  bad "did not strip pilot:held (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if has_call "bd	-C hq label remove sling-a pilot:held-until:1999999999 -q"; then
  ok "stripped the specific pilot:held-until:<epoch> label"
else
  bad "did not strip the held-until label"
fi
if has_call "bd	-C hq undefer sling-a"; then
  ok "called bd undefer (restores bd-ready visibility, not just the label)"
else
  bad "did not call bd undefer"
fi

# ── Scenario B: bead has NO pilot:held at all — no-op, zero bd mutation ────
echo "Scenario B: bead was never suppressed (no pilot:held label) — no-op, no bd mutation calls"
BEAD_B='[{"labels":["pilot:dispatched","story:in-flight"]}]'
run_unsuppress "hq" "sling-b" "$BEAD_B" 0
if grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: mutated a bead that was never held (dump: $(cat "$CALLS" | tr '\n' '|'))"
else
  ok "never-held bead — no label/undefer mutation attempted"
fi

# ── Scenario C: empty sling_id — refuses before any bd call ────────────────
echo "Scenario C: empty sling_id — short-circuits before any bd call"
run_unsuppress "hq" "" "" 0
if grep -q '^bd\t' "$CALLS"; then
  bad "REGRESSION: made a bd call with an empty sling_id"
else
  ok "empty sling_id short-circuits before any bd call"
fi

# ── Scenario D: DRY_RUN=1 — logs WOULD, makes no real mutation ─────────────
echo "Scenario D: DRY_RUN=1 — logs WOULD-strip/undefer, no real bd mutation"
BEAD_D='[{"labels":["pilot:held","pilot:held-until:1999999999"]}]'
run_unsuppress "hq" "sling-d" "$BEAD_D" 1
if has_call "WOULD strip pilot:held"; then
  ok "DRY_RUN logs the WOULD-strip/undefer line"
else
  bad "DRY_RUN did not log a WOULD line (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi
if grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: DRY_RUN performed a real mutation"
else
  ok "DRY_RUN performs no real mutation"
fi

# ── Scenario E: bead show fails/empty (bd unreachable) — safe no-op ────────
echo "Scenario E: bd show returns nothing (store unreachable) — fails safe, no crash"
run_unsuppress "hq" "sling-e" "" 0
if [ $? -ge 128 ]; then
  bad "crashed on empty bd show output"
else
  ok "empty bd show output — returns cleanly, no crash"
fi

# ── Scenario F: self-heal — sling bead (pilot.sling_for set) with EXPIRED
#    held-until gets unsuppressed ────────────────────────────────────────────
echo "Scenario F: self-heal — expired sling hold (pilot.sling_for set) gets unsuppressed"
_bead_for() {
  case "$1" in
    sling-expired) printf '[{"metadata":{"pilot.sling_for":"story-1"},"labels":["pilot:held","pilot:held-until:1000000000"]}]' ;;
  esac
}
run_selfheal "hq" '[{"id":"sling-expired"}]' 0
if has_call "bd	-C hq label remove sling-expired pilot:held -q" && has_call "bd	-C hq undefer sling-expired"; then
  ok "expired sling hold (epoch 1000000000, long past) — stripped + undeferred"
else
  bad "expired sling hold was not unsuppressed (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

# ── Scenario G: self-heal — sling bead with a FUTURE held-until is untouched ─
echo "Scenario G: self-heal — not-yet-expired sling hold is left alone"
_bead_for() {
  case "$1" in
    sling-future) printf '[{"metadata":{"pilot.sling_for":"story-2"},"labels":["pilot:held","pilot:held-until:9999999999"]}]' ;;
  esac
}
run_selfheal "hq" '[{"id":"sling-future"}]' 0
if grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: touched a sling hold that has not expired yet (held-until:9999999999)"
else
  ok "not-yet-expired sling hold — left untouched"
fi

# ── Scenario H: self-heal — STORY-bead mayor-deferred hold (no pilot.sling_for)
#    is NEVER touched, even with an expired epoch ───────────────────────────
echo "Scenario H: self-heal — mayor-deferred STORY hold (no pilot.sling_for) is out of scope, even if expired"
_bead_for() {
  case "$1" in
    story-held) printf '[{"metadata":{},"labels":["pilot:held","pilot:held-until:1000000000"]}]' ;;
  esac
}
run_selfheal "hq" '[{"id":"story-held"}]' 0
if grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: self-heal touched a non-sling (mayor-deferred story) hold — out of scope per ga-h6trx3 item 2"
else
  ok "non-sling pilot:held bead (no pilot.sling_for) — correctly out of scope, untouched even though expired"
fi

# ── Scenario I: self-heal — mixed batch, only the expired sling is touched ──
echo "Scenario I: self-heal — mixed batch of 3 (expired sling / future sling / expired story) — exactly one action"
_bead_for() {
  case "$1" in
    mix-sling-expired) printf '[{"metadata":{"pilot.sling_for":"story-3"},"labels":["pilot:held","pilot:held-until:1000000000"]}]' ;;
    mix-sling-future)  printf '[{"metadata":{"pilot.sling_for":"story-4"},"labels":["pilot:held","pilot:held-until:9999999999"]}]' ;;
    mix-story-expired) printf '[{"metadata":{},"labels":["pilot:held","pilot:held-until:1000000000"]}]' ;;
  esac
}
run_selfheal "hq" '[{"id":"mix-sling-expired"},{"id":"mix-sling-future"},{"id":"mix-story-expired"}]' 0
_undefers=$(count_call 'bd	-C hq undefer')
if [ "$_undefers" -eq 1 ] && has_call "bd	-C hq undefer mix-sling-expired"; then
  ok "mixed batch — exactly the one expired sling was undeferred, the other two left alone"
else
  bad "mixed batch — expected exactly 1 undefer (mix-sling-expired), got $_undefers (dump: $(cat "$CALLS" | tr '\n' '|'))"
fi

# ── Scenario L: _pilot_unsuppress_sling under the REAL set -e pragma —
#    pilot:held with NO matching pilot:held-until label must not crash ─────
#    (gate_run ga-b9h503, SHA 690dcb6e: the unguarded `grep -E '...' | head
#    -1` assignment exits non-zero under pipefail when no held-until label
#    matches; set -e then aborted the WHOLE Pilot process before the very
#    next `[ -n "$_pus_expiry_lbl" ]` graceful check ever ran — worse than
#    the bug this fix set out to close. Not contrived: legacy pre-ga-brnlfa
#    slings lack held-until entirely, and the unmodified
#    _pilot_suppress_reused_sling stamps held-until and held via two
#    independent `bd label add ... || true` calls with no atomicity, so a
#    transient failure of just the first produces this shape freshly too.
#    Scenarios A-E above cannot see this: they run the extracted function
#    under `set -uo pipefail` only (no -e), so the pre-fix code silently
#    "worked" inside that harness even while it would abort the real file.)
echo "Scenario L: _pilot_unsuppress_sling, real set -e pragma — pilot:held with NO held-until label does not crash"
BEAD_L='[{"labels":["pilot:dispatched","pilot:held"]}]'
run_unsuppress_strict "hq" "sling-l" "$BEAD_L" 0
if ! has_call "SURVIVED"; then
  bad "CRASHED under set -e (the exact ga-b9h503 finding) — dump: $(cat "$CALLS" | tr '\n' '|')"
else
  if has_call "bd	-C hq label remove sling-l pilot:held -q" && has_call "bd	-C hq undefer sling-l"; then
    ok "held-but-no-until sling — survives set -e, still strips pilot:held and undefers"
  else
    bad "survived but did not complete the expected strip+undefer (dump: $(cat "$CALLS" | tr '\n' '|'))"
  fi
  if grep -qE '^bd\t-C hq label remove sling-l pilot:held-until' "$CALLS"; then
    bad "REGRESSION: attempted to remove a held-until label that was never present"
  else
    ok "no held-until label existed — none was attempted for removal"
  fi
fi

# ── Scenario M: _pilot_selfheal_expired_slings under the REAL set -e
#    pragma — a sling with pilot:held and NO held-until label must not
#    crash the sweep, and is correctly left for R6 (no epoch to judge
#    expiry by, per this function's own documented scope) ─────────────────
echo "Scenario M: self-heal, real set -e pragma — sling pilot:held with NO held-until label does not crash the sweep"
_bead_for() {
  case "$1" in
    sling-no-until) printf '[{"metadata":{"pilot.sling_for":"story-5"},"labels":["pilot:held"]}]' ;;
  esac
}
run_selfheal_strict "hq" '[{"id":"sling-no-until"}]' 0
if ! has_call "SURVIVED"; then
  bad "CRASHED under set -e (the exact ga-b9h503 finding, sweep-start path) — dump: $(cat "$CALLS" | tr '\n' '|')"
elif grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: self-heal acted on a hold with no epoch to judge expiry by"
else
  ok "held-but-no-until sling — sweep survives set -e, correctly left untouched (R6 remains the backstop)"
fi

# ── Scenario J: drift-guards — helpers defined + wired at both call sites ──
echo "Scenario J: drift-guard — helpers defined and wired into dispatch_one()'s two delivery branches + sweep start"
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has '_pilot_unsuppress_sling\(\) \{'                         "helper _pilot_unsuppress_sling is defined"
has '_pilot_selfheal_expired_slings\(\) \{'                  "helper _pilot_selfheal_expired_slings is defined"
has '_pilot_selfheal_expired_slings "\$GC_CITY"'              "sweep-start self-heal is called with \$GC_CITY"

# Sweep-start wiring: the self-heal call must appear shortly AFTER the
# "=== Pilot sweep start ===" log line (runs every sweep, before any
# quota/RAM/quiet-hours pause can short-circuit the rest).
if grep -A10 '=== Pilot sweep start' "$DISPATCHER" | grep -q '_pilot_selfheal_expired_slings "\$GC_CITY"'; then
  ok "self-heal call sits right after the sweep-start log line (runs even if the sweep pauses afterward)"
else
  bad "self-heal call does not appear shortly after '=== Pilot sweep start' — ordering may have drifted"
fi

# REUSE (submit) branch: the failure handler must call the unsuppress helper.
if grep -A2 'Could not submit to \$_DISPATCH_SESS_REF' "$DISPATCHER" | grep -q '_pilot_unsuppress_sling "\$GC_CITY" "\$SLING_BEAD_ID"'; then
  ok "REUSE branch (gc session submit failure) calls _pilot_unsuppress_sling"
else
  bad "REUSE branch's submit-failure handler does not call _pilot_unsuppress_sling — the ga-i58em REUSE sibling gap is still open"
fi

# Pool (nudge) branch: the failure handler must call the unsuppress helper —
# this is the actual bug ga-h6trx3 reproduces (nudge to a POOL TEMPLATE
# always fails).
if grep -A2 'Could not nudge \$_SLING_TARGET — un-suppressing' "$DISPATCHER" | grep -q '_pilot_unsuppress_sling "\$GC_CITY" "\$SLING_BEAD_ID"'; then
  ok "pool branch (gc session nudge failure) calls _pilot_unsuppress_sling — closes ga-h6trx3's actual failure mode"
else
  bad "REGRESSION / UNFIXED: pool branch's nudge-failure handler does not call _pilot_unsuppress_sling — ga-h6trx3 is not closed"
fi

# The unrelated ga-mfeip crew-nudge call site (~L9474, a DIFFERENT dispatch
# path/bug, concurrently under separate repair) must be untouched by this
# fix — scope guard so this selftest doesn't silently start depending on
# work from an unrelated in-flight bead.
if grep -q 'ga-mfeip: Could not nudge \$_SLING_TARGET — crew will see \$STORY_ID on next hook cycle' "$DISPATCHER"; then
  ok "unrelated ga-mfeip crew-nudge call site left untouched (out of scope for ga-h6trx3)"
else
  bad "ga-mfeip crew-nudge call site text changed — verify this wasn't an accidental scope creep from this fix"
fi

# ── Scenario K: runtime reachability — definitions must textually PRECEDE
#    the top-level sweep-start call. Gate run ga-vtzbza (fix-attempt 1,
#    commit 58c82dc2b) FAILED exactly here: both functions were defined at
#    lines 2345/2390, 750+ lines AFTER the top-level call at line 1640. Bash
#    has no function hoisting, and a top-level (non-function-body) call to a
#    not-yet-defined function is command-not-found (exit 127) under this
#    script's `set -euo pipefail` (line 74) — crashing every single Pilot
#    sweep at startup, before any dispatch logic runs. This is a DIFFERENT
#    failure shape than Scenarios A-J can see: those eval BOTH function
#    bodies verbatim in an isolated subshell (line ~60-69, 92-93, 118-120),
#    so they always define-then-call regardless of the real file's order,
#    and Scenario J's wiring check only greps textual proximity to the
#    sweep-start log line — which the broken code already satisfied. Only a
#    check against the REAL file's line order catches this class of bug.
#    (Function calls made from WITHIN another function's body — e.g.
#    _pilot_selfheal_expired_slings calling _pilot_unsuppress_sling, or
#    dispatch_one's two calls to _pilot_unsuppress_sling at L~9822/9826 —
#    are exempt from this ordering requirement: bash resolves those at the
#    outer function's CALL time, not at the outer function's definition
#    time, so the callee only needs to be defined before the outer function
#    is itself invoked. Only a bare top-level call is hoisting-sensitive,
#    which is why this scenario checks line order, not "is it defined
#    anywhere before EOF".)
echo "Scenario K: runtime reachability — helper definitions precede the top-level sweep-start call (bash has no hoisting)"
UNSUPPRESS_DEF_LINE=$(grep -n '^_pilot_unsuppress_sling() {' "$DISPATCHER" | head -1 | cut -d: -f1)
SELFHEAL_DEF_LINE=$(grep -n '^_pilot_selfheal_expired_slings() {' "$DISPATCHER" | head -1 | cut -d: -f1)
SWEEP_START_LINE=$(grep -n '=== Pilot sweep start' "$DISPATCHER" | head -1 | cut -d: -f1)
SELFHEAL_CALL_LINE=""
if [ -n "$SWEEP_START_LINE" ]; then
  SELFHEAL_CALL_LINE=$(awk -v start="$SWEEP_START_LINE" 'NR>=start && NR<=start+20 && /^_pilot_selfheal_expired_slings "\$GC_CITY"$/ {print NR; exit}' "$DISPATCHER")
fi
if [ -z "$UNSUPPRESS_DEF_LINE" ] || [ -z "$SELFHEAL_DEF_LINE" ] || [ -z "$SELFHEAL_CALL_LINE" ]; then
  bad "could not locate one of: unsuppress def ($UNSUPPRESS_DEF_LINE), selfheal def ($SELFHEAL_DEF_LINE), sweep-start call ($SELFHEAL_CALL_LINE) — cannot verify reachability"
else
  if [ "$SELFHEAL_DEF_LINE" -lt "$SELFHEAL_CALL_LINE" ]; then
    ok "_pilot_selfheal_expired_slings defined at line $SELFHEAL_DEF_LINE, before its top-level call at line $SELFHEAL_CALL_LINE"
  else
    bad "REGRESSION: _pilot_selfheal_expired_slings defined at line $SELFHEAL_DEF_LINE, AFTER its top-level call at line $SELFHEAL_CALL_LINE — this is the exact gate_run ga-vtzbza crash (command-not-found under set -e, every sweep, citywide dispatch halt)"
  fi
  if [ "$UNSUPPRESS_DEF_LINE" -lt "$SELFHEAL_CALL_LINE" ]; then
    ok "_pilot_unsuppress_sling defined at line $UNSUPPRESS_DEF_LINE, before selfheal's top-level call at line $SELFHEAL_CALL_LINE (selfheal calls it internally, so it must already be defined by call time)"
  else
    bad "REGRESSION: _pilot_unsuppress_sling defined at line $UNSUPPRESS_DEF_LINE, at or after selfheal's top-level call at line $SELFHEAL_CALL_LINE — selfheal would crash calling it"
  fi
fi

# ── Scenario N: drift-guard — both held-until grep|head lookups stay
#    guarded against pipefail's no-match exit ──────────────────────────────
#    Gate run ga-b9h503 (fix-attempt 2, SHA 690dcb6e) FAILED exactly here:
#    `_pus_expiry_lbl=$(... | grep -E '^pilot:held-until:[0-9]+$' | head
#    -1)` and the analogous _pilot_selfheal_expired_slings assignment had no
#    `|| true`/fallback, so grep's exit 1 on "pilot:held present, no
#    matching held-until label" propagated through pipefail and aborted the
#    entire Pilot process under set -euo pipefail (line 74). Scenarios L/M
#    above catch this behaviorally via the strict, real-pragma harness; this
#    scenario guards the same regression structurally — the same
#    belt-and-suspenders relationship Scenario K has to A-J — so a future
#    edit that innocently strips the trailing `|| true` as "dead code" is
#    still caught even if the strict scenarios are later weakened or removed.
echo "Scenario N: drift-guard — both held-until grep|head lookups keep their pipefail guard"
_HELD_UNTIL_GUARD_MARKER="grep -E '^pilot:held-until:[0-9]+\$' | head -1) || true"
_guarded_count=$(grep -cF -- "$_HELD_UNTIL_GUARD_MARKER" "$DISPATCHER")
if [ "$_guarded_count" -eq 2 ]; then
  ok "both held-until grep|head lookups (_pilot_unsuppress_sling + _pilot_selfheal_expired_slings) keep their || true pipefail guard"
else
  bad "REGRESSION: expected 2 guarded held-until grep|head lookups, found $_guarded_count — one may have lost its || true (the exact ga-b9h503 crash could be back)"
fi

# ── Scenario O: self-heal, real set -e pragma — empty pilot:held list is a
#    clean no-op (Mayor's ga-h6trx3 attempt-3 review, item 2) ──────────────
echo "Scenario O: self-heal, real set -e pragma — empty pilot:held list is a clean no-op"
run_selfheal_strict "hq" '[]' 0
if ! has_call "SURVIVED"; then
  bad "CRASHED under set -e on an empty pilot:held list — dump: $(cat "$CALLS" | tr '\n' '|')"
elif grep -qE '^bd\t-C hq (label remove|undefer|show)' "$CALLS"; then
  bad "REGRESSION: empty pilot:held list should never touch a single bead"
else
  ok "empty pilot:held list — sweep survives set -e, zero beads touched (nothing to self-heal)"
fi

# ── Scenario P: self-heal, real set -e pragma — bd show fails for a listed
#    id, skips gracefully via the PRE-EXISTING `|| continue` guard at line
#    ~1703 (that guard predates this fix and was never gate-flagged; this
#    proves it still holds under the real pragma, not just under -uo
#    pipefail) ────────────────────────────────────────────────────────────
echo "Scenario P: self-heal, real set -e pragma — bd show fails for a listed id, skips gracefully"
_bead_for() {
  case "$1" in
    sling-show-fails) return 1 ;;
  esac
}
run_selfheal_strict "hq" '[{"id":"sling-show-fails"}]' 0
if ! has_call "SURVIVED"; then
  bad "CRASHED under set -e when bd show fails for a listed id — dump: $(cat "$CALLS" | tr '\n' '|')"
elif grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: acted on a bead whose bd show call failed"
else
  ok "bd show failure for a listed id — sweep survives set -e, that id is skipped (pre-existing || continue guard holds)"
fi

# ── Scenario Q: self-heal, real set -e pragma — bead carries NO labels at
#    all (empty array), not merely a missing held-until among others — a
#    distinct root cause hitting the same grep|head line (jq emits zero
#    label lines instead of one non-matching line; either way grep's
#    no-match exit is what the || true on line ~1707 now absorbs) ─────────
echo "Scenario Q: self-heal, real set -e pragma — bead has NO labels at all, does not crash"
_bead_for() {
  case "$1" in
    sling-no-labels) printf '[{"metadata":{"pilot.sling_for":"story-6"},"labels":[]}]' ;;
  esac
}
run_selfheal_strict "hq" '[{"id":"sling-no-labels"}]' 0
if ! has_call "SURVIVED"; then
  bad "CRASHED under set -e on a labelless-but-listed bead — dump: $(cat "$CALLS" | tr '\n' '|')"
elif grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: acted on a bead with no labels to judge expiry by"
else
  ok "labelless sling bead — sweep survives set -e, correctly left untouched"
fi

# ── Scenario R: self-heal, real set -e pragma — bd show SUCCEEDS but returns
#    non-JSON output for a listed id, exercising the _pse_sling_for extraction
#    itself (gate_run ga-0u5xml, fix-attempt 3, SHA 3a62ea662) — distinct from
#    Scenario P (bd show FAILS outright, exit 1 — already guarded by the
#    pre-existing `|| continue` on line ~1703). Here `bd show` exits 0 but
#    stdout is not parseable JSON (a stray warning line, a truncated
#    response — CLI-misbehavior classes this codebase has hit before), so the
#    pipe `printf ... | jq -r ...` itself fails under pipefail. The
#    `_pse_sling_for=...` assignment had NO `|| continue` guard (unlike its
#    sibling `_pse_bead=...` one line above it), so set -e killed the entire
#    Pilot sweep on this input — worse than the bug ga-h6trx3 set out to fix,
#    and for every OTHER pilot:held bead due in the same sweep, not just this
#    one id. ─────────────────────────────────────────────────────────────────
echo "Scenario R: self-heal, real set -e pragma — bd show succeeds but returns non-JSON, does not crash the sweep"
_bead_for() {
  case "$1" in
    sling-malformed-json) printf 'not-json-at-all { truncated' ;;
  esac
}
run_selfheal_strict "hq" '[{"id":"sling-malformed-json"}]' 0
if ! has_call "SURVIVED"; then
  bad "CRASHED under set -e when bd show succeeds but returns non-JSON for a listed id — dump: $(cat "$CALLS" | tr '\n' '|')"
elif grep -qE '^bd\t-C hq (label remove|undefer)' "$CALLS"; then
  bad "REGRESSION: acted on a bead whose JSON could not be parsed"
else
  ok "bd show returns non-JSON for a listed id — sweep survives set -e, that id is skipped"
fi

# ── Scenario S: drift-guard — the _pse_sling_for extraction stays guarded
#    against pipefail, structurally (belt-and-suspenders to Scenario R, the
#    same relationship Scenario N already has to L/M) ─────────────────────
echo "Scenario S: drift-guard — _pse_sling_for extraction keeps its || continue pipefail guard"
if grep -F '_pse_sling_for=$(printf' "$DISPATCHER" | grep -qF -- '|| continue'; then
  ok "_pse_sling_for extraction keeps its || continue pipefail guard"
else
  bad "REGRESSION: _pse_sling_for extraction lost its || continue guard (the exact ga-0u5xml crash could be back)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.sling-unsuppress-on-failure.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
