#!/usr/bin/env bash
# gate-dispatcher-author-notify-fallback.selftest.sh (ga-fe5at)
#
# Proves notify_author_with_fallback() — extracted from quality-gate-dispatcher.sh
# and shared across its 4 mail(NOTIFY_AUTHOR) call sites (sibling-branch race
# ga-lxz5w, branch-content mismatch ga-y9a1d, scope-hold ga-k2wjn, gate-fix-cap
# escalation), each of which previously copy-pasted a bare `gc mail send
# "$NOTIFY_AUTHOR" ... || warn ...` — the exact undeliverable-bare-name defect
# ga-z3i2p already found and fixed at quality-gate-guard.sh's Step 5a (fix on
# branch fix/ga-z3i2p-park-notify-author, not yet merged to main at the time of
# this fix — this bead's fix is independent of that merge landing first, since
# guard.sh and dispatcher.sh are separate files with their own copies).
#
# NOTIFY_AUTHOR is often a BARE crew-branch segment (e.g. "oracle" from
# crew/oracle/wa-166gf), but live session mailboxes are rig-qualified (e.g.
# "oracle-wa") — gc mail send resolves recipients by EXACT session_name/alias
# match, no prefix/fuzzy fallback (internal/session/resolve.go
# ResolveSessionID), so the bare segment silently fails for any persistent
# named crew member.
#
# Strategy: extract the LIVE function via its SELFTEST-EXTRACT sentinel (never
# a hand-copied duplicate) and eval it into THIS shell, then stub gc/bd/warn as
# plain bash functions (not subprocess executables — the function under test
# runs in-process here, no set -euo pipefail subshell boundary to cross, unlike
# an inline block extracted from a script that must run as its own subprocess).
# A per-scenario FAIL_RECIPIENTS list lets each case decide which candidates
# "fail" to resolve. MUTATION-checks (breaking the cascade order, breaking the
# rig-suffix derivation) prove this is not vacuous.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-dispatcher-author-notify-fallback.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

BLOCK="$(extract_block "$DISPATCHER" "notify-author-with-fallback")"
if [ -z "$BLOCK" ]; then
  echo "FATAL: SELFTEST-EXTRACT notify-author-with-fallback block not found in $DISPATCHER" >&2
  exit 2
fi
eval "$BLOCK"
if ! declare -F notify_author_with_fallback >/dev/null 2>&1; then
  echo "FATAL: extracted block did not define notify_author_with_fallback" >&2
  exit 2
fi

# ── stubs ────────────────────────────────────────────────────────────────────
GC_CITY="test-city"
FAIL_RECIPIENTS=""       # space-separated list of recipients this scenario fails
MAIL_LOG=""              # accumulates every attempted `gc mail send` recipient, in order
WARN_LOG=""
BD_COMMENT_LOG=""

_recipient_should_fail() {
  local r="$1" f
  for f in $FAIL_RECIPIENTS; do [ "$f" = "$r" ] && return 0; done
  return 1
}

gc() {
  # gc --city "$GC_CITY" mail send "<recipient>" -s ... -m ...
  if [ "$1" = "--city" ] && [ "$3" = "mail" ] && [ "$4" = "send" ]; then
    local recipient="$5"
    MAIL_LOG="$MAIL_LOG $recipient"
    _recipient_should_fail "$recipient" && return 1
    return 0
  fi
  return 0
}
bd() { BD_COMMENT_LOG="$BD_COMMENT_LOG|$*"; return 0; }
warn() { WARN_LOG="$WARN_LOG|$*"; }

reset_stubs() { FAIL_RECIPIENTS=""; MAIL_LOG=""; WARN_LOG=""; BD_COMMENT_LOG=""; }

echo "S1: bare NOTIFY_AUTHOR resolves on first try (pool/template alias already exact)"
reset_stubs
notify_author_with_fallback "wa-166gf" "wa-worker" "wa-worker" "subj" "body" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$MAIL_LOG" = " wa-worker" ]; then
  ok "bare alias succeeds on candidate 1, no fallback attempted (MAIL_LOG=$MAIL_LOG)"
else
  bad "expected rc=0 mail_log=' wa-worker', got rc=$_rc mail_log='$MAIL_LOG'"
fi

echo "S2: bare fails, rig-qualified (oracle -> oracle-wa) succeeds — THE ga-z3i2p incident shape"
reset_stubs
FAIL_RECIPIENTS="oracle"
notify_author_with_fallback "wa-166gf" "oracle" "author-fallback" "subj" "body" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$MAIL_LOG" = " oracle oracle-wa" ]; then
  ok "bare 'oracle' fails, qualified 'oracle-wa' succeeds — matches the real oracle-wa/wa-166gf incident ga-z3i2p documented"
else
  bad "expected rc=0 mail_log=' oracle oracle-wa', got rc=$_rc mail_log='$MAIL_LOG'"
fi

echo "S3: bare AND rig-qualified fail, falls through to AUTHOR"
reset_stubs
FAIL_RECIPIENTS="oracle oracle-wa"
notify_author_with_fallback "wa-166gf" "oracle" "some-author" "subj" "body" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$MAIL_LOG" = " oracle oracle-wa some-author" ]; then
  ok "both fail, AUTHOR candidate succeeds as final fallback"
else
  bad "expected rc=0 mail_log=' oracle oracle-wa some-author', got rc=$_rc mail_log='$MAIL_LOG'"
fi

echo "S4: EVERY candidate fails — escalates to mayor + durable bd comment, returns 1"
reset_stubs
FAIL_RECIPIENTS="oracle oracle-wa some-author"
notify_author_with_fallback "wa-166gf" "oracle" "some-author" "subj" "body" "sibling-branch race on wa-166gf (ga-lxz5w)"
_rc=$?
if [ "$_rc" -eq 1 ] && echo "$MAIL_LOG" | grep -q "mayor" && echo "$BD_COMMENT_LOG" | grep -q "ga-fe5at" && echo "$WARN_LOG" | grep -q "ga-lxz5w"; then
  ok "total failure escalates to mayor, leaves durable bd comment, warns with the specific fail_context — 'could not notify' never looks identical to 'notified'"
else
  bad "total-failure escalation incomplete — rc=$_rc mail_log='$MAIL_LOG' bd_log='$BD_COMMENT_LOG' warn_log='$WARN_LOG'"
fi

echo "S5: empty NOTIFY_AUTHOR — returns 1 immediately, NO escalation (matches pre-existing silent-skip, not a new failure)"
reset_stubs
notify_author_with_fallback "wa-166gf" "" "some-author" "subj" "body" "ctx"
_rc=$?
if [ "$_rc" -eq 1 ] && [ -z "$MAIL_LOG" ] && [ -z "$BD_COMMENT_LOG" ]; then
  ok "empty notify_author skips entirely, no mail attempted, no escalation (there was never anyone to notify)"
else
  bad "empty notify_author should be a silent no-op, got rc=$_rc mail_log='$MAIL_LOG' bd_log='$BD_COMMENT_LOG'"
fi

echo "S6: HQ/gascity bead (ga- prefix) does NOT generate a guessed rig-qualified candidate"
reset_stubs
FAIL_RECIPIENTS="oracle"
notify_author_with_fallback "ga-fe5at" "oracle" "oracle" "subj" "body" "ctx"
_rc=$?
if [ "$_rc" -eq 1 ] && ! echo "$MAIL_LOG" | grep -q "oracle-ga" && echo "$MAIL_LOG" | grep -q "mayor"; then
  ok "ga-prefixed bead: no invented 'oracle-ga' guess (only bare 'oracle' tried, then escalated to mayor since AUTHOR==NOTIFY_AUTHOR gave no 3rd candidate): mail_log='$MAIL_LOG'"
else
  bad "ga-prefix bead should skip rig-qualification entirely — got rc=$_rc mail_log='$MAIL_LOG'"
fi

echo "S7: already-qualified NOTIFY_AUTHOR (ends in -<prefix>) does not duplicate itself as a redundant candidate"
reset_stubs
notify_author_with_fallback "wa-166gf" "oracle-wa" "oracle-wa" "subj" "body" "ctx"
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$MAIL_LOG" = " oracle-wa" ]; then
  ok "already-qualified NOTIFY_AUTHOR tried once, not duplicated as 'oracle-wa-wa'"
else
  bad "already-qualified case should be a single clean candidate — got rc=$_rc mail_log='$MAIL_LOG'"
fi

echo "S8: AUTHOR identical to NOTIFY_AUTHOR is not added as a redundant duplicate candidate"
reset_stubs
FAIL_RECIPIENTS="wa-worker wa-worker-wa"
notify_author_with_fallback "wa-166gf" "wa-worker" "wa-worker" "subj" "body" "ctx"
_rc=$?
_count=$(echo "$MAIL_LOG" | tr ' ' '\n' | grep -c '^wa-worker$' || true)
if [ "$_rc" -eq 1 ] && [ "$_count" -eq 1 ]; then
  ok "AUTHOR == NOTIFY_AUTHOR not re-tried as a wasted duplicate candidate (tried once: '$MAIL_LOG')"
else
  bad "expected exactly one 'wa-worker' attempt, got rc=$_rc mail_log='$MAIL_LOG' count=$_count"
fi

# ── MUTATION checks — prove the scenarios above are not vacuous ─────────────
echo "S9 (mutation): breaking the try-order (AUTHOR before rig-qualified) would change S3's observed order — confirms S3 actually exercises order, not just final success"
reset_stubs
FAIL_RECIPIENTS="oracle oracle-wa"
notify_author_with_fallback "wa-166gf" "oracle" "some-author" "subj" "body" "ctx" >/dev/null
if [ "$MAIL_LOG" = " oracle oracle-wa some-author" ]; then
  ok "candidate order is bare -> rig-qualified -> author, exactly as documented (a reordering mutation would flip this string)"
else
  bad "candidate order drifted — got '$MAIL_LOG'"
fi

echo "S10 (mutation): a rig-prefix typo (single-char off) must NOT accidentally match 'already qualified' and skip the real candidate"
reset_stubs
FAIL_RECIPIENTS="oracle-w"   # force the bare candidate to fail so the cascade actually reaches the qualified one
notify_author_with_fallback "wa-166gf" "oracle-w" "oracle-w" "subj" "body" "ctx" >/dev/null
if echo "$MAIL_LOG" | grep -q "oracle-w-wa"; then
  ok "near-miss suffix 'oracle-w' (not 'oracle-wa') correctly generates its own qualified candidate 'oracle-w-wa', not silently treated as already-qualified"
else
  bad "near-miss suffix handling broke — got '$MAIL_LOG'"
fi

echo ""; echo "gate-dispatcher-author-notify-fallback.selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
