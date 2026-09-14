#!/usr/bin/env bash
# gate-dispatcher-author-nudge-fallback.selftest.sh (ga-o2caab)
#
# Proves nudge_author_with_fallback() — sibling of notify_author_with_fallback
# (ga-fe5at, the mail version) for the 2 gate-FAIL `session nudge` call sites in
# quality-gate-dispatcher.sh (general author notify, and the ga-jyox live-crew
# author notify). Both previously called a bare
# `gc session nudge "$NOTIFY_AUTHOR" ... || warn` — the same undeliverable-bare-
# name defect ga-z3i2p/ga-fe5at already fixed for the 6 mail call sites, but
# left standing here: NOTIFY_AUTHOR is often a BARE crew-branch segment (e.g.
# "batista" from crew/batista/lx-dnw), while live session mailboxes are
# rig-qualified (e.g. "batista-lx") — gc session nudge resolves recipients by
# EXACT session identity, no prefix/fuzzy fallback, so the bare segment
# silently fails for any persistent named crew member and the FAIL feedback
# never reaches them (lx-dnw sat 7+ minutes with zero mention of the FAIL
# until a witness relayed it by hand — see ga-o2caab).
#
# Kept as a SEPARATE sibling function (not a generalized
# notify_author_with_fallback) rather than folded into the mail version: the
# nudge call takes one message, not subject+body, and the mail version already
# has 6 live call sites relying on its exact signature — touching it for this
# fix would be an unrelated-risk bundle, not a minimal change.
#
# Strategy: identical to gate-dispatcher-author-notify-fallback.selftest.sh —
# extract the LIVE function via its SELFTEST-EXTRACT sentinel (never a
# hand-copied duplicate), eval it into THIS shell, stub gc/bd/warn as plain
# bash functions. A per-scenario FAIL_RECIPIENTS list lets each case decide
# which candidates "fail" to resolve. MUTATION-checks (breaking the cascade
# order, breaking the rig-suffix derivation) prove this is not vacuous.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-dispatcher-author-nudge-fallback.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

BLOCK="$(extract_block "$DISPATCHER" "nudge-author-with-fallback")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: SELFTEST-EXTRACT nudge-author-with-fallback block not found in $DISPATCHER" >&2
  exit 2
fi
eval "$BLOCK"
if ! declare -F nudge_author_with_fallback >/dev/null 2>&1; then
  echo "FATAL: extracted block did not define nudge_author_with_fallback" >&2
  exit 2
fi

# ── stubs ────────────────────────────────────────────────────────────────────
GC_CITY="test-city"
FAIL_RECIPIENTS=""       # space-separated list of recipients this scenario fails
NUDGE_LOG=""             # accumulates every attempted `gc session nudge` recipient, in order
MAIL_LOG=""              # accumulates every attempted `gc mail send` recipient (mayor escalation only)
WARN_LOG=""
BD_COMMENT_LOG=""

_recipient_should_fail() {
  local r="$1" f
  for f in $FAIL_RECIPIENTS; do [ "$f" = "$r" ] && return 0; done
  return 1
}

gc() {
  # gc --city "$GC_CITY" session nudge "<recipient>" "<message>" --delivery wait-idle
  if [ "$1" = "--city" ] && [ "$3" = "session" ] && [ "$4" = "nudge" ]; then
    local recipient="$5"
    NUDGE_LOG="$NUDGE_LOG $recipient"
    _recipient_should_fail "$recipient" && return 1
    return 0
  fi
  # gc --city "$GC_CITY" mail send mayor -s ... -m ...  (total-failure escalation)
  if [ "$1" = "--city" ] && [ "$3" = "mail" ] && [ "$4" = "send" ]; then
    local recipient="$5"
    MAIL_LOG="$MAIL_LOG $recipient"
    return 0
  fi
  return 0
}
bd() { BD_COMMENT_LOG="$BD_COMMENT_LOG|$*"; return 0; }
warn() { WARN_LOG="$WARN_LOG|$*"; }

reset_stubs() { FAIL_RECIPIENTS=""; NUDGE_LOG=""; MAIL_LOG=""; WARN_LOG=""; BD_COMMENT_LOG=""; }

echo "S1: bare NOTIFY_AUTHOR resolves on first try (pool/template alias already exact)"
reset_stubs
nudge_author_with_fallback "lx-dnw" "wa-worker" "wa-worker" "msg" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$NUDGE_LOG" = " wa-worker" ]; then
  ok "bare alias succeeds on candidate 1, no fallback attempted (NUDGE_LOG=$NUDGE_LOG)"
else
  bad "expected rc=0 nudge_log=' wa-worker', got rc=$_rc nudge_log='$NUDGE_LOG'"
fi

echo "S2: bare fails, rig-qualified (batista -> batista-lx) succeeds — THE ga-o2caab incident shape"
reset_stubs
FAIL_RECIPIENTS="batista"
nudge_author_with_fallback "lx-dnw" "batista" "author-fallback" "msg" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$NUDGE_LOG" = " batista batista-lx" ]; then
  ok "bare 'batista' fails, qualified 'batista-lx' succeeds — matches the real batista-lx/lx-dnw incident ga-o2caab documented"
else
  bad "expected rc=0 nudge_log=' batista batista-lx', got rc=$_rc nudge_log='$NUDGE_LOG'"
fi

echo "S3: bare AND rig-qualified fail, falls through to AUTHOR"
reset_stubs
FAIL_RECIPIENTS="batista batista-lx"
nudge_author_with_fallback "lx-dnw" "batista" "some-author" "msg" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$NUDGE_LOG" = " batista batista-lx some-author" ]; then
  ok "both fail, AUTHOR candidate succeeds as final fallback"
else
  bad "expected rc=0 nudge_log=' batista batista-lx some-author', got rc=$_rc nudge_log='$NUDGE_LOG'"
fi

echo "S4: EVERY candidate fails — escalates to mayor + durable bd comment, returns 1"
reset_stubs
FAIL_RECIPIENTS="batista batista-lx some-author"
nudge_author_with_fallback "lx-dnw" "batista" "some-author" "msg" "gate FAIL feedback for lx-dnw (ga-o2caab)"
_rc=$?
if [ "$_rc" -eq 1 ] && echo "$MAIL_LOG" | grep -q "mayor" && echo "$BD_COMMENT_LOG" | grep -q "ga-o2caab" && echo "$WARN_LOG" | grep -q "ga-o2caab"; then
  ok "total failure escalates to mayor, leaves durable bd comment, warns with the specific fail_context — 'could not notify' never looks identical to 'notified'"
else
  bad "total-failure escalation incomplete — rc=$_rc nudge_log='$NUDGE_LOG' mail_log='$MAIL_LOG' bd_log='$BD_COMMENT_LOG' warn_log='$WARN_LOG'"
fi

echo "S5: empty NOTIFY_AUTHOR — returns 1 immediately, NO escalation (matches pre-existing silent-skip, not a new failure)"
reset_stubs
nudge_author_with_fallback "lx-dnw" "" "some-author" "msg" "ctx"
_rc=$?
if [ "$_rc" -eq 1 ] && [ -z "$NUDGE_LOG" ] && [ -z "$MAIL_LOG" ] && [ -z "$BD_COMMENT_LOG" ]; then
  ok "empty notify_author skips entirely, no nudge attempted, no escalation (there was never anyone to notify)"
else
  bad "empty notify_author should be a silent no-op, got rc=$_rc nudge_log='$NUDGE_LOG' mail_log='$MAIL_LOG' bd_log='$BD_COMMENT_LOG'"
fi

echo "S6: HQ/gascity bead (ga- prefix) does NOT generate a guessed rig-qualified candidate"
reset_stubs
FAIL_RECIPIENTS="batista"
nudge_author_with_fallback "ga-o2caab" "batista" "batista" "msg" "ctx"
_rc=$?
if [ "$_rc" -eq 1 ] && ! echo "$NUDGE_LOG" | grep -q "batista-ga" && echo "$MAIL_LOG" | grep -q "mayor"; then
  ok "ga-prefixed bead: no invented 'batista-ga' guess (only bare 'batista' tried, then escalated to mayor since AUTHOR==NOTIFY_AUTHOR gave no 3rd candidate): nudge_log='$NUDGE_LOG'"
else
  bad "ga-prefix bead should skip rig-qualification entirely — got rc=$_rc nudge_log='$NUDGE_LOG'"
fi

echo "S7: already-qualified NOTIFY_AUTHOR (ends in -<prefix>) does not duplicate itself as a redundant candidate"
reset_stubs
nudge_author_with_fallback "lx-dnw" "batista-lx" "batista-lx" "msg" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$NUDGE_LOG" = " batista-lx" ]; then
  ok "already-qualified NOTIFY_AUTHOR tried once, not duplicated as 'batista-lx-lx'"
else
  bad "already-qualified case should be a single clean candidate — got rc=$_rc nudge_log='$NUDGE_LOG'"
fi

echo "S8: AUTHOR identical to NOTIFY_AUTHOR is not added as a redundant duplicate candidate"
reset_stubs
FAIL_RECIPIENTS="wa-worker wa-worker-lx"
nudge_author_with_fallback "lx-dnw" "wa-worker" "wa-worker" "msg" "ctx"
_rc=$?
_count=$(echo "$NUDGE_LOG" | tr ' ' '\n' | grep -c '^wa-worker$' || true)
if [ "$_rc" -eq 1 ] && [ "$_count" -eq 1 ]; then
  ok "AUTHOR == NOTIFY_AUTHOR not re-tried as a wasted duplicate candidate (tried once: '$NUDGE_LOG')"
else
  bad "expected exactly one 'wa-worker' attempt, got rc=$_rc nudge_log='$NUDGE_LOG' count=$_count"
fi

# ── MUTATION checks — prove the scenarios above are not vacuous ─────────────
echo "S9 (mutation): breaking the try-order (AUTHOR before rig-qualified) would change S3's observed order — confirms S3 actually exercises order, not just final success"
reset_stubs
FAIL_RECIPIENTS="batista batista-lx"
nudge_author_with_fallback "lx-dnw" "batista" "some-author" "msg" "ctx" >/dev/null
if [ "$NUDGE_LOG" = " batista batista-lx some-author" ]; then
  ok "candidate order is bare -> rig-qualified -> author, exactly as documented (a reordering mutation would flip this string)"
else
  bad "candidate order drifted — got '$NUDGE_LOG'"
fi

echo "S10 (mutation): a rig-prefix typo (single-char off) must NOT accidentally match 'already qualified' and skip the real candidate"
reset_stubs
FAIL_RECIPIENTS="batista-l"   # force the bare candidate to fail so the cascade actually reaches the qualified one
nudge_author_with_fallback "lx-dnw" "batista-l" "batista-l" "msg" "ctx" >/dev/null
if echo "$NUDGE_LOG" | grep -q "batista-l-lx"; then
  ok "near-miss suffix 'batista-l' (not 'batista-lx') correctly generates its own qualified candidate 'batista-l-lx', not silently treated as already-qualified"
else
  bad "near-miss suffix handling broke — got '$NUDGE_LOG'"
fi

# ── ERREXIT-SAFETY regression (gate-FAIL attempt 1 review) ──────────────────
# The scenarios above prove nudge_author_with_fallback()'s own logic, by
# eval'ing it into THIS file's shell — which runs under `set -uo pipefail`
# (no -e, line 32). They cannot catch a caller-side bug: the dispatcher
# itself runs under `set -euo pipefail` (its L30), and both call sites live
# inside gate_finalize_run(), itself invoked as a BARE statement from Phase
# C's sweep loop. A gate reviewer caught exactly this on the first fix
# attempt: both call sites had been written as bare statements (no `|| true`
# / `|| warn` guard), so a total nudge failure (return 1 — the routine
# mayor-escalation branch, not a rare corner case under this ephemeral-
# session architecture) would abort the WHOLE dispatcher, silently killing
# finalization of every OTHER gate run pending in the same sweep. Below:
# extract the ACTUAL call-site source (never a hand-copied duplicate, same
# principle as the function extraction above) and run it in a REAL nested
# `bash -euo pipefail` — matching the dispatcher's own errexit setting — with
# nudge_author_with_fallback stubbed to always fail, proving the fix holds.
CALL_SITE_1="$(extract_block "$DISPATCHER" "nudge-call-site-1")"
CALL_SITE_2="$(extract_block "$DISPATCHER" "nudge-call-site-2")"
[ -n "$CALL_SITE_1" ] || { echo "FATAL: SELFTEST-EXTRACT nudge-call-site-1 block not found in $DISPATCHER" >&2; exit 2; }
[ -n "$CALL_SITE_2" ] || { echo "FATAL: SELFTEST-EXTRACT nudge-call-site-2 block not found in $DISPATCHER" >&2; exit 2; }

# Runs $1 (a snippet of dispatcher source, verbatim) in its own `bash -euo
# pipefail` process — piped in via stdin, never interpolated into a quoted
# -c string, so nothing in the snippet (quotes, $(...), etc.) needs escaping
# — with the vars the call sites reference pre-set and
# nudge_author_with_fallback stubbed to always return 1 (total failure, the
# scenario the reviewer named). Prints a marker after the snippet so success
# is "ran to completion", not just "process exited 0" (a snippet that exits
# early via an unrelated path would still exit 0 and must not read as safe).
errexit_survives() {
  local snippet="$1" out rc
  out="$(printf '%s\n' \
    'nudge_author_with_fallback() { return 1; }' \
    'NOTIFY_AUTHOR="batista"; BEAD_ID="lx-dnw"; AUTHOR="some-author"' \
    'BRANCH="crew/batista/lx-dnw"; FAIL_REASONS="reason"; GATE_RUN_ID="gr1"' \
    'NEW_ATTEMPT=1; GATE_FIX_CAP=3' \
    "$snippet" \
    'echo MARKER_REACHED' \
    | bash -euo pipefail 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "MARKER_REACHED"
}

echo "S11: call-site-1 (general author notify) survives total nudge failure under set -e"
if errexit_survives "$CALL_SITE_1"; then
  ok "call-site-1 ran to completion under set -e with every nudge candidate failing — the || true fix holds"
else
  bad "call-site-1 ABORTED under set -e on total nudge failure — the exact defect the gate reviewer found on attempt 1"
fi

echo "S12: call-site-2 (ga-jyox live-crew author notify) survives total nudge failure under set -e"
if errexit_survives "$CALL_SITE_2"; then
  ok "call-site-2 ran to completion under set -e with every nudge candidate failing — the || true fix holds"
else
  bad "call-site-2 ABORTED under set -e on total nudge failure — the exact defect the gate reviewer found on attempt 1"
fi

echo "S13 (mutation): stripping the trailing '|| true' from call-site-1 must abort under set -e — proves S11 actually discriminates, not vacuous"
CALL_SITE_1_UNGUARDED="$(printf '%s\n' "$CALL_SITE_1" | sed 's/ || true[[:space:]]*$//')"
if errexit_survives "$CALL_SITE_1_UNGUARDED"; then
  bad "call-site-1 with '|| true' stripped should have ABORTED under set -e but survived — S11 would not catch a regression here"
else
  ok "call-site-1 with '|| true' stripped correctly aborts under set -e — S11 is sensitive to this exact defect class"
fi

echo "S14 (mutation): stripping the trailing '|| true' from call-site-2 must abort under set -e — proves S12 actually discriminates, not vacuous"
CALL_SITE_2_UNGUARDED="$(printf '%s\n' "$CALL_SITE_2" | sed 's/ || true[[:space:]]*$//')"
if errexit_survives "$CALL_SITE_2_UNGUARDED"; then
  bad "call-site-2 with '|| true' stripped should have ABORTED under set -e but survived — S12 would not catch a regression here"
else
  ok "call-site-2 with '|| true' stripped correctly aborts under set -e — S12 is sensitive to this exact defect class"
fi

echo ""; echo "gate-dispatcher-author-nudge-fallback.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
