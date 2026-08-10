#!/usr/bin/env bash
# gate-verdict-dual-null-link.selftest.sh — Prove the ga-qqtoo fix: a verdict
# bead's --assignee write can fail with NO usable link at all (both assignee
# AND metadata.gc.session_name null), not just a degraded-but-recoverable
# assignee gap. assign_verdict_bead_verified() must try every channel it has
# before letting a bead end up silently unclaimable.
#
# Bug ga-qqtoo: distinct from ga-mo7q (gate-verdict-assignee-fallback.
# selftest.sh) in kind, not just degree. ga-mo7q's fix hardened the --assignee
# write (retry + backoff + a degraded-label on failure) and taught the
# REVIEWER's poll to also check metadata.gc.session_name as a fallback. But
# the WRITE side never attempted metadata itself — it only ever wrote
# --assignee. MEASURED live 2026-08-10: of 88 open verdict beads, 28 had BOTH
# assignee AND metadata.gc.session_name null — genuinely unclaimable by
# either of the reviewer's two documented poll channels. Live example:
# gate_run ga-8k5ll's verdict bead ga-xflu7, created with a full well-formed
# review-task comment (so creation itself worked) but assignee=null AND
# metadata=null — nobody could claim it, the run burned its full 36min
# verdict_timeout, and requeued. Two real beads, ga-676t (assignee landed)
# and ga-yhxx (assignee didn't land, but metadata.gc.session_name did, from
# the SAME bd update call) show the write can PARTIALLY land — so the fix is
# to check for that partial success before giving up, and if genuinely
# NEITHER field landed after all retries, make one final EXPLICIT
# --set-metadata attempt (a distinct bd write path) before accepting defeat.
#
# This harness mirrors the PURE decision — given which of the three attempt
# channels succeeded, does the bead end up with a usable link? — for direct
# unit-testing, the same technique gate-verdict-assignee-fallback.selftest.sh
# uses for verdict_bead_lookup. Section 2 drift-guards the real shipped files
# so a regression that quietly drops the new fallback wiring (not just
# deletes the whole function) fails this check too.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"
REFINO_GATE="$SELF_DIR/refino-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── The PURE three-channel decision assign_verdict_bead_verified now makes:
# given which attempts succeeded (assignee write / metadata as a side effect
# of that same write / an explicit final metadata write), is the bead linked?
link_after_assign_attempt() {
  local _assignee_ok="$1" _metadata_side_effect_ok="$2" _explicit_metadata_ok="$3"
  [ "$_assignee_ok" = "1" ] && { echo "linked:assignee"; return 0; }
  [ "$_metadata_side_effect_ok" = "1" ] && { echo "linked:metadata-side-effect"; return 0; }
  [ "$_explicit_metadata_ok" = "1" ] && { echo "linked:explicit-metadata-fallback"; return 0; }
  echo "unlinked"; return 1
}

echo "── 1. link_after_assign_attempt on the real measured bead shapes ──"
# ga-676t: assignee write landed cleanly — healthy case, unaffected by the fix.
eq "ga-676t-shaped (assignee OK)" \
   "$(link_after_assign_attempt 1 0 0)" \
   "linked:assignee"

# ga-yhxx: assignee didn't land, but metadata.gc.session_name did (SAME write
# call, partial success) — the ga-mo7q fix already relied on this via the
# reviewer's poll; ga-qqtoo's fix makes the WRITER recognize it too, so it
# doesn't burn retries chasing a column that already lost the race.
eq "ga-yhxx-shaped (assignee EMPTY, metadata side-effect landed)" \
   "$(link_after_assign_attempt 0 1 0)" \
   "linked:metadata-side-effect"

# ga-xflu7-shaped: assignee didn't land, metadata didn't land as a side
# effect either. Pre-ga-qqtoo, this is the end of the line — unlinked. The
# fix's new behavior: try ONE more thing, an explicit --set-metadata call, a
# genuinely different bd write path.
eq "ga-xflu7-shaped, explicit fallback succeeds → THE FIX (was unreachable before ga-qqtoo)" \
   "$(link_after_assign_attempt 0 0 1)" \
   "linked:explicit-metadata-fallback"

# Genuinely all three channels fail: correctly stays unlinked. The fix
# reduces how often this state is reached; it does not (and per the bug's own
# acceptance criteria, should not) pretend to make it impossible — a real
# Dolt outage can still fail every write. What must NOT happen is silence:
# section 2 below drift-guards that the real function still warns + labels
# verdict:assignee-degraded on this exact path.
eq "all three channels fail → correctly unlinked (must warn+label, not vanish)" \
   "$(link_after_assign_attempt 0 0 0)" \
   "unlinked"

echo
echo "── 2. mutation: removing the metadata-awareness reproduces the ORIGINAL ga-qqtoo bug ──"
# Simulates the pre-fix function: it only ever checks/attempts assignee, so
# BOTH the ga-yhxx case (metadata landed as a side effect) and the
# genuinely-recoverable-via-explicit-write case must, without that logic,
# resolve the same way as an outright failure — that collapse (a recoverable
# case reading identical to an unrecoverable one) IS the bug.
pre_fix_link_after_assign_attempt() {
  local _assignee_ok="$1"
  [ "$_assignee_ok" = "1" ] && { echo "linked:assignee"; return 0; }
  echo "unlinked"; return 1
}
neutralized_yhxx="$(pre_fix_link_after_assign_attempt 0)"
if [ "$neutralized_yhxx" = "unlinked" ]; then
  ok "pre-fix shape reproduces the ga-qqtoo bug for the ga-yhxx case (assignee failed, metadata ignored → unlinked)"
else
  bad "pre-fix mirror should have produced 'unlinked' for the ga-yhxx case, got [$neutralized_yhxx] — mirror no longer models the real bug"
fi

echo
echo "── 3. DRIFT-GUARD: the real shipped files actually wire the ga-qqtoo fix in ──"
has "$GATE" 'metadata\["gc\.session_name"\] // empty' \
    "quality-gate-dispatcher.sh: assign_verdict_bead_verified reads back metadata.gc.session_name (not just assignee)"
has "$GATE" '\-\-set-metadata "gc\.session_name=\$_sname"' \
    "quality-gate-dispatcher.sh: assign_verdict_bead_verified makes an explicit --set-metadata fallback write"
has "$REFINO_GATE" 'metadata\["gc\.session_name"\] // empty' \
    "refino-gate-dispatcher.sh: refino_assign_verdict_bead_verified reads back metadata.gc.session_name too"
has "$REFINO_GATE" '\-\-set-metadata "gc\.session_name=\$_sname"' \
    "refino-gate-dispatcher.sh: refino_assign_verdict_bead_verified makes the same explicit fallback write"

# Section 3 of gate-verdict-assignee-fallback.selftest.sh already drift-guards
# the retry count and the verdict:assignee-degraded label on both functions —
# not duplicated here, per this file's own convention of not re-testing what
# a sibling selftest already covers.

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
