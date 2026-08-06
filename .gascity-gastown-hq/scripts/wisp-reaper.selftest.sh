#!/bin/bash
# wisp-reaper.selftest.sh — unit tests for wisp-reaper.sh's pure decision
# logic, focused on criterion (d) — recipient suspended/long-asleep — added
# for ga-clgc2 (see wisp-reaper.sh's header for the full (a)-(d) list).
#
# wisp-reaper.sh's own header (WISP_REAPER_LIB_ONLY=1) explicitly invites a
# selftest sourcing it in library mode; none existed before this file (see
# ga-clgc2 investigation — grepped the whole tree for WISP_REAPER_LIB_ONLY,
# the only hit was the definition inside wisp-reaper.sh itself).
#
# Hermetic: sources wisp-reaper.sh in library mode (WISP_REAPER_LIB_ONLY=1),
# which returns right after the pure function definitions — before the
# `gc dolt status` health probe, the `gc agent list --json` snapshot, or any
# `bd`/Dolt call. No live city, no mutation, nothing closed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/wisp-reaper.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Runs "$@" as a command after sourcing wisp-reaper.sh in library mode, in a
# subshell — so the sourced script's `set -uo pipefail` never leaks into this
# selftest's own shell, and each call starts from a clean function/var state.
lib_call() {
  (
    export WISP_REAPER_LIB_ONLY=1
    . "$SCRIPT" >/dev/null 2>&1
    "$@"
  )
}

echo "=== wisp-reaper.selftest.sh ==="

if [ -f "$SCRIPT" ]; then
  ok "script exists at $SCRIPT"
else
  bad "script missing at $SCRIPT"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

if bash -n "$SCRIPT"; then
  ok "script passes bash -n syntax check"
else
  bad "script has a syntax error"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

if lib_call type wisp_reap_decide >/dev/null 2>&1 \
  && lib_call type recipient_unreachable_too_long >/dev/null 2>&1 \
  && lib_call type slept_minutes >/dev/null 2>&1 \
  && lib_call type is_protected_labels >/dev/null 2>&1 \
  && lib_call type state_is_terminal >/dev/null 2>&1 \
  && lib_call type ttl_is_expired >/dev/null 2>&1; then
  ok "all pure decision functions defined by lib-mode source"
else
  bad "one or more pure functions NOT defined — lib mode broken"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

# ── recipient_unreachable_too_long: suspended, asleep vs threshold, unknown ──
echo "── recipient_unreachable_too_long (ga-clgc2 criterion d) ──"

result=$(lib_call recipient_unreachable_too_long 1 "" 720)
[ "$result" = "1" ] && ok "suspended=1 (asleep_minutes unknown) → 1 (close)" \
  || bad "suspended=1 → got '$result', want 1"

result=$(lib_call recipient_unreachable_too_long 0 "" 720)
[ "$result" = "0" ] && ok "not suspended, asleep_minutes unknown ('') → 0 (keep, fail-safe)" \
  || bad "not suspended + unknown asleep → got '$result', want 0"

result=$(lib_call recipient_unreachable_too_long 0 100 720)
[ "$result" = "0" ] && ok "asleep 100min, threshold 720min → 0 (under threshold, keep)" \
  || bad "asleep 100min under 720min threshold → got '$result', want 0"

result=$(lib_call recipient_unreachable_too_long 0 800 720)
[ "$result" = "1" ] && ok "asleep 800min, threshold 720min → 1 (over threshold, close)" \
  || bad "asleep 800min over 720min threshold → got '$result', want 1"

result=$(lib_call recipient_unreachable_too_long 0 720 720)
[ "$result" = "0" ] && ok "asleep exactly at threshold (720==720) → 0 (strict >, not >=; keep)" \
  || bad "boundary case (720==720) → got '$result', want 0 (strictly greater-than only)"

result=$(lib_call recipient_unreachable_too_long 0 721 720)
[ "$result" = "1" ] && ok "asleep 1min past threshold (721>720) → 1 (close)" \
  || bad "just-over-boundary (721>720) → got '$result', want 1"

result=$(lib_call recipient_unreachable_too_long 0 notanumber 720)
[ "$result" = "0" ] && ok "non-numeric asleep_minutes → 0 (fail-safe, keep)" \
  || bad "non-numeric asleep_minutes → got '$result', want 0 (fail-safe)"

result=$(lib_call recipient_unreachable_too_long 1 100 720)
[ "$result" = "1" ] && ok "suspended=1 wins even when asleep_minutes is well under threshold" \
  || bad "suspended=1 should win regardless of asleep_minutes — got '$result', want 1"

# ── slept_minutes: real time-since-timestamp math ────────────────────────────
echo "── slept_minutes ──"

result=$(lib_call slept_minutes "")
[ "$result" = "" ] && ok "empty slept_at → '' (unknown)" \
  || bad "empty slept_at → got '$result', want ''"

result=$(lib_call slept_minutes "0001-01-01T00:00:00Z")
[ "$result" = "" ] && ok "zero-time sentinel (0001-01-01) → '' (unknown, not a huge duration)" \
  || bad "zero-time sentinel → got '$result', want '' — treating it as a real timestamp would report an enormous bogus duration"

NOW_ISO=$(lib_call bash -c 'date -u +%Y-%m-%dT%H:%M:%SZ')
result=$(lib_call slept_minutes "$NOW_ISO")
if [ -n "$result" ] && [ "$result" -ge 0 ] && [ "$result" -le 1 ] 2>/dev/null; then
  ok "slept_minutes(now) → $result (want ~0)"
else
  bad "slept_minutes(now) → got '$result', want 0 or 1"
fi

TWO_H_AGO=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null)
if [ -n "$TWO_H_AGO" ]; then
  result=$(lib_call slept_minutes "$TWO_H_AGO")
  if [ -n "$result" ] && [ "$result" -ge 118 ] && [ "$result" -le 122 ] 2>/dev/null; then
    ok "slept_minutes(2h ago) → $result (want ~120)"
  else
    bad "slept_minutes(2h ago) → got '$result', want ~120 (118-122 band)"
  fi
else
  bad "could not build a 2h-ago fixture timestamp with python3 — skipping this check"
fi

# ── wisp_reap_decide: non-regression on (a)/(b)/(c), new (d) additive only ───
echo "── wisp_reap_decide non-regression + new criterion (d) ──"

# Non-regression: every pre-existing (a)/(b)/(c) verdict must be UNCHANGED
# now that a 6th positional arg exists — pass recipient_unreachable=0 in all
# of these so only the ORIGINAL five inputs drive the verdict.
result=$(lib_call wisp_reap_decide 0 0 0 0 0 0)
[ "$result" = "keep:not-an-ephemeral-nudge" ] && ok "non-nudge bead → keep:not-an-ephemeral-nudge (unchanged)" \
  || bad "non-nudge bead → got '$result'"

result=$(lib_call wisp_reap_decide 1 1 0 0 0 1)
[ "$result" = "keep:protected-class-owned-elsewhere" ] && ok "protected-class bead → keep, even with recipient_unreachable=1 (guard wins)" \
  || bad "protected-class bead → got '$result', want keep:protected-class-owned-elsewhere (protected guard must win over ALL close signals)"

result=$(lib_call wisp_reap_decide 1 0 1 0 0 0)
[ "$result" = "close:nudge-ttl-expired" ] && ok "TTL expired → close:nudge-ttl-expired (unchanged, criterion a)" \
  || bad "TTL expired → got '$result'"

result=$(lib_call wisp_reap_decide 1 0 0 1 0 0)
[ "$result" = "close:nudge-orphan-parent-session-closed" ] && ok "orphan parent → close:nudge-orphan-parent-session-closed (unchanged, criterion b)" \
  || bad "orphan parent → got '$result'"

result=$(lib_call wisp_reap_decide 1 0 0 0 1 0)
[ "$result" = "close:nudge-terminal-state" ] && ok "terminal state → close:nudge-terminal-state (unchanged, criterion c)" \
  || bad "terminal state → got '$result'"

result=$(lib_call wisp_reap_decide 1 0 0 0 0 0)
[ "$result" = "keep:nudge-still-pending" ] && ok "nothing fires (recipient reachable) → keep:nudge-still-pending (unchanged default)" \
  || bad "nothing fires → got '$result'"

# ── falsifying check: the EXACT reported scenario — a queued nudge to a ──────
# ── suspended, long-asleep deacon, where TTL has NOT expired, parent session ─
# ── is NOT closed (just asleep), and state is still "queued" (not terminal) ──
# ── — is exactly what (a)/(b)/(c) all miss and (d) exists to catch. ──────────
result=$(lib_call wisp_reap_decide 1 0 0 0 0 1)
[ "$result" = "close:nudge-recipient-suspended-or-long-asleep" ] \
  && ok "EXACT ga-clgc2 scenario (queued, TTL live, parent open, state non-terminal, recipient suspended) → close:nudge-recipient-suspended-or-long-asleep" \
  || bad "ga-clgc2 scenario → got '$result', want close:nudge-recipient-suspended-or-long-asleep — the bug is NOT fixed"

# ── sanity: WITHOUT criterion (d) (recipient_unreachable=0), the exact same
# ── shape falls through to keep — confirms this reproduces the real bug and
# ── isn't a vacuous comparison (this is what wisp-reaper did BEFORE this fix)
result=$(lib_call wisp_reap_decide 1 0 0 0 0 0)
[ "$result" = "keep:nudge-still-pending" ] \
  && ok "sanity: same shape WITHOUT the new signal → keep:nudge-still-pending — confirms (a)/(b)/(c) alone miss this, reproducing the real bug" \
  || bad "sanity check failed — got '$result'"

# ── ordering: earlier criteria still take precedence over the new one when ───
# ── multiple signals fire on the same bead (defensive — should never matter ──
# ── in practice since they're independent conditions, but locks the order) ───
result=$(lib_call wisp_reap_decide 1 0 1 0 0 1)
[ "$result" = "close:nudge-ttl-expired" ] && ok "TTL-expired reason wins over recipient-unreachable when both fire (ordering locked)" \
  || bad "expected ttl-expired to win ordering, got '$result'"

# ── drift-guard: the sweep loop actually wires the new signal in — not dead
# ── code sitting unused next to a function that's never called ──────────────
echo "── drift-guard: wiring present in live script ──"

if grep -qE 'wisp_reap_decide "\$IS_NUDGE" "\$IS_PROT" "\$TTL_EXP" "\$PAR_CLOSED" "\$ST_TERM" "\$RECIP_UNREACH"' "$SCRIPT"; then
  ok "the sweep loop calls wisp_reap_decide with the new 6th argument (RECIP_UNREACH)"
else
  bad "the sweep loop does not pass a 6th argument to wisp_reap_decide — criterion (d) is dead code"
fi
if grep -qF 'RECIP_UNREACH=$(recipient_unreachable_too_long' "$SCRIPT"; then
  ok "the sweep loop calls recipient_unreachable_too_long() to compute RECIP_UNREACH"
else
  bad "recipient_unreachable_too_long() is defined but never called from the sweep loop — dead code"
fi
if grep -qF 'AGENT_SUSP=$(agent_is_suspended "$BAGENT")' "$SCRIPT"; then
  ok "the sweep loop looks up agent suspension via agent_is_suspended(\$BAGENT)"
else
  bad "agent_is_suspended() is not called with the bead's metadata.agent — dead code or wrong wiring"
fi
if grep -qF 'ASLEEP_MIN=$(session_asleep_minutes "$BSESS")' "$SCRIPT"; then
  ok "the sweep loop looks up asleep duration via session_asleep_minutes(\$BSESS)"
else
  bad "session_asleep_minutes() is not called with the bead's session_id — dead code or wrong wiring"
fi
if grep -qF 'BAGENT=$(printf' "$SCRIPT" && grep -qF '.metadata.agent // ""' "$SCRIPT"; then
  ok "BAGENT is extracted from metadata.agent (matches the real gc:nudge bead schema)"
else
  bad "BAGENT extraction missing or does not read metadata.agent"
fi

# ── config: HALF_TTL_MINUTES is present, configurable, and a sane fraction ───
# ── of the observed ~24h nudge TTL ────────────────────────────────────────────
HALF_TTL_LINE=$(grep -E '^HALF_TTL_MINUTES=' "$SCRIPT" || true)
HALF_TTL_DEFAULT=$(printf '%s\n' "$HALF_TTL_LINE" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' || true)
if [ -n "$HALF_TTL_DEFAULT" ]; then
  ok "extracted HALF_TTL_MINUTES default from shipped script: ${HALF_TTL_DEFAULT}min"
  if [ "$HALF_TTL_DEFAULT" -ge 60 ] && [ "$HALF_TTL_DEFAULT" -le 1440 ]; then
    ok "HALF_TTL_MINUTES default (${HALF_TTL_DEFAULT}min) is a sane fraction of a ~24h TTL (60-1440min band)"
  else
    bad "HALF_TTL_MINUTES default (${HALF_TTL_DEFAULT}min) is outside the sane 60-1440min band for half of a ~24h TTL"
  fi
  if echo "$HALF_TTL_LINE" | grep -qF 'WISP_REAPER_HALF_TTL_MINUTES'; then
    ok "HALF_TTL_MINUTES is configurable via WISP_REAPER_HALF_TTL_MINUTES env var (matches the file's WISP_REAPER_* convention)"
  else
    bad "HALF_TTL_MINUTES is not wired to a WISP_REAPER_* env var override"
  fi
else
  bad "could not extract HALF_TTL_MINUTES default from shipped script — got line: '$HALF_TTL_LINE'"
fi

# ── protected-class guard still wins even for the new criterion: a gc:session
# ── bead (or other protected class) that happens to reference a suspended
# ── agent in its metadata must NEVER be closed by this reaper — that's owned
# ── by session/supervisor lifecycle, not wisp-reaper (see SCOPE BOUNDARY). ───
result=$(lib_call is_protected_labels "gc:session" "ga-wisp-abc123")
[ "$result" = "1" ] && ok "gc:session label is still recognized as protected (unchanged by this fix)" \
  || bad "gc:session label protection regressed — got '$result', want 1"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
