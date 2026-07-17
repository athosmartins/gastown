#!/usr/bin/env bash
# quality-gate-park-notify.selftest.sh — Falsifies ga-oo66: Step 5a's park path
# (source bead carries story:needs-approval / gate:needs-human) used to be
# SILENT to the author — comments landed on a marker that gets closed right
# after (nobody re-opens a closed marker) and on the source bead (comments
# don't notify). /gate-done promises every author "you will be mailed when
# the gate passes or fails"; a park is neither, so that promise silently went
# unkept.
#
# ga-p5q3 rule (b): a check whose EMPTINESS is load-bearing must be falsified —
# run it against a case you KNOW should fire and watch it fire. So this harness
# doesn't just grep the source for "mail send" (that would prove the string
# exists, not that it runs): it sources the REAL notify_park_author() function
# via GATE_GUARD_LIB_ONLY=1 (same seam quality-gate-park-unapproved.selftest.sh
# already uses for check_source_bead_park/set_gate_status), shadows gc/notify
# in-shell so no live Dolt/ntfy is touched, forces a fake park, and asserts the
# real mail+notify call fired with the right author/bead/reason/unblock text.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

CALL_LOG="$(mktemp -t ga-oo66-calls.XXXXXX)"
trap 'rm -f "$CALL_LOG"' EXIT

# ── Shadow gc/notify/warn so the REAL notify_park_author code runs but hits no
# live Dolt/ntfy — captures full argv so assertions can check what would have
# shipped. log/err silenced (noise from other sourced helpers). The -m mail
# body is multi-line (embedded \n\n); collapse embedded newlines to a literal
# "\N" marker before logging so each call stays a single grep-able CALL_LOG
# line — otherwise the record splits across lines and only the first line
# would be visible to the line-based assertions below.
gc()     { printf 'gc|%s\n' "${*//$'\n'/\\N}" >> "$CALL_LOG"; return 0; }
notify() { printf 'notify|%s\n' "${*//$'\n'/\\N}" >> "$CALL_LOG"; return 0; }
warn()   { printf 'warn|%s\n' "${*//$'\n'/\\N}" >> "$CALL_LOG"; }
log()    { :; }
err()    { :; }

# ── Load the real notify_park_author (and siblings) without running the live sweep ──
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type notify_park_author >/dev/null 2>&1 \
  || { echo "FATAL: notify_park_author not defined by guard (ga-oo66 fix missing?)"; exit 1; }

# ── 1. Force a fake needs-human park and see the mail actually go out ────────
echo "── 1. fake park:needs-human → mail fires with author/bead/reason/unblock ──"
: > "$CALL_LOG"
notify_park_author "some-crew-author" "wa-fake01" "fix/wa-fake01-thing" "ga-fakemarker01" \
  "source bead wa-fake01 carries gate:needs-human (circuit-broken — human intervention required)"

MAIL_LINE=$(grep '^gc|' "$CALL_LOG" | grep 'mail send' || true)
if [ -n "$MAIL_LINE" ]; then ok "mail send call fired"; else bad "no mail send call captured — CALL_LOG: $(cat "$CALL_LOG")"; fi

case "$MAIL_LINE" in
  *"mail send some-crew-author"*) ok "mailed to the resolved AUTHOR (some-crew-author)" ;;
  *) bad "mail not addressed to AUTHOR: $MAIL_LINE" ;;
esac
case "$MAIL_LINE" in
  *"wa-fake01"*) ok "mail names the bead (wa-fake01)" ;;
  *) bad "mail does not name the bead: $MAIL_LINE" ;;
esac
case "$MAIL_LINE" in
  *"gate:needs-human"*) ok "mail names the park reason (gate:needs-human)" ;;
  *) bad "mail does not carry the park reason: $MAIL_LINE" ;;
esac
case "$MAIL_LINE" in
  *"/gate-done"*) ok "mail names the unblock condition (re-submit via /gate-done)" ;;
  *) bad "mail does not tell the author how to unblock: $MAIL_LINE" ;;
esac

NOTIFY_LINE=$(grep '^notify|' "$CALL_LOG" || true)
if [ -n "$NOTIFY_LINE" ]; then ok "notify (ntfy) call fired"; else bad "no notify call captured"; fi
case "$NOTIFY_LINE" in
  *"needs-human"*) ok "notify title/body reflects needs-human" ;;
  *) bad "notify does not mention needs-human: $NOTIFY_LINE" ;;
esac

# ── 2. story:needs-approval park mails too (not just gate:needs-human) ───────
echo "── 2. fake park:needs-approval → mail fires ──"
: > "$CALL_LOG"
notify_park_author "another-author" "wa-fake03" "fix/wa-fake03" "ga-fakemarker03" \
  "source bead wa-fake03 carries story:needs-approval (not yet product-approved)"
MAIL_LINE2=$(grep '^gc|' "$CALL_LOG" | grep 'mail send' || true)
case "$MAIL_LINE2" in
  *"mail send another-author"*"story:needs-approval"*) ok "needs-approval park also mails the author with its own reason" ;;
  *) bad "needs-approval park did not mail correctly: $MAIL_LINE2" ;;
esac

# ── 3. mail-send failure warns instead of dying silently (set -e safety) ─────
echo "── 3. mail send failure → warn fired, no silent loss ──"
: > "$CALL_LOG"
gc() { printf 'gc|%s\n' "${*//$'\n'/\\N}" >> "$CALL_LOG"; return 1; }  # simulate mail send failing
notify_park_author "author2" "wa-fake02" "fix/wa-fake02" "ga-fakemarker02" "reason2"
WARN_LINE=$(grep '^warn|' "$CALL_LOG" || true)
if [ -n "$WARN_LINE" ]; then ok "mail failure produced a warn (not silent)"; else bad "mail failure was silent — CALL_LOG: $(cat "$CALL_LOG")"; fi

# ── 4. drift-guard: Step 5a actually wires notify_park_author into the live park path ──
echo "── 4. drift-guard: Step 5a calls notify_park_author (not orphaned) ──"
grep -q 'notify_park_author "\$AUTHOR" "\$BEAD_ID" "\$BRANCH" "\$MARKER_ID" "\$PARK_REASON"' "$GUARD" \
  && ok "Step 5a calls notify_park_author with the resolved author/bead/branch/marker/reason" \
  || bad "Step 5a does not call notify_park_author — park path would be silent again"
# Must fire AFTER the marker close (mail should reflect the final parked state,
# and a call before an unresolved close would be premature/misleading).
CLOSE_LINE=$(grep -n 'marker parked (terminal)' "$GUARD" | head -1 | cut -d: -f1)
NOTIFY_CALL_LINE=$(grep -n 'notify_park_author "\$AUTHOR"' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$CLOSE_LINE" ] && [ -n "$NOTIFY_CALL_LINE" ] && [ "$NOTIFY_CALL_LINE" -gt "$CLOSE_LINE" ]; then
  ok "notify_park_author fires AFTER the marker close (reflects final parked state)"
else
  bad "notify_park_author ordering wrong relative to marker close: close=${CLOSE_LINE:-missing} notify=${NOTIFY_CALL_LINE:-missing}"
fi
# The park must still exit 0 right after (terminal, no reviewer spawned) —
# guards against a "fix" that accidentally fell through to Step 6.
AFTER_NOTIFY_BLOCK=$(sed -n "${NOTIFY_CALL_LINE:-1},+3p" "$GUARD" 2>/dev/null || true)
case "$AFTER_NOTIFY_BLOCK" in
  *"exit 0"*) ok "park path still exits 0 right after notifying (terminal, no reviewer spawned)" ;;
  *) bad "park path does not exit immediately after notify_park_author — may fall through to Step 6: $AFTER_NOTIFY_BLOCK" ;;
esac

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
