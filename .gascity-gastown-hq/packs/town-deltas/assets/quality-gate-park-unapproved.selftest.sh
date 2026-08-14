#!/usr/bin/env bash
# quality-gate-park-unapproved.selftest.sh — Prove the gate gap fix (Step 5a) that
# parks markers whose source-bead is story:needs-approval or gate:needs-human.
#
# Problem (wa-x9ooo class): a crew re-submitted a gate marker for a bead carrying
# story:needs-approval + gate:needs-human 3+ times. Each re-submit created a fresh
# marker, the guard claimed it, spawned reviewers, they failed, the cycle repeated.
# The 4 duplicate markers HOL-blocked the gate (merge-stall).
#
# Fix (Step 5a in quality-gate-guard.sh): after AUTHOR is resolved but BEFORE the
# gate-run tracking bead is created (Step 6), fetch the source-bead's labels from
# BEAD_RAW (already in scope from Step 5) and run check_source_bead_park.
# If the result is not "ok", park the marker (gate-status:parked-needs-human +
# bd close) and exit without creating the gate-run or spawning reviewers.
#
# gate:needs-fix ALONE must NOT be parked — it is the normal fix-iterate path
# (the crew fixed the bead and re-submitted; the gate should review it).
#
# This harness SOURCES the guard in lib-only mode to unit-test the REAL pure
# function (check_source_bead_park), then drift-guards the live script.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the pure function from the guard (no live sweep) ────────────────────
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type check_source_bead_park >/dev/null 2>&1 \
  || { echo "FATAL: check_source_bead_park not defined by guard (Step 5a missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. story:needs-approval → always park (never approved) ───────────────────
echo "── 1. story:needs-approval → park ──"
eq "needs-approval alone → park" \
  "$(check_source_bead_park 'story:needs-approval')" \
  "park:needs-approval"
eq "needs-approval + gate:needs-fix → park (approval blocks, not fix)" \
  "$(check_source_bead_park 'story:needs-approval gate:needs-fix')" \
  "park:needs-approval"
eq "needs-approval + gate:needs-human → park (needs-approval checked first)" \
  "$(check_source_bead_park 'story:needs-approval gate:needs-human')" \
  "park:needs-approval"
eq "other labels + needs-approval → park" \
  "$(check_source_bead_park 'lane:small tech-debt story:needs-approval gate:fix-attempt:3')" \
  "park:needs-approval"

# ── 2. gate:needs-human → always park (circuit-broken) ───────────────────────
echo "── 2. gate:needs-human → park ──"
eq "gate:needs-human alone → park" \
  "$(check_source_bead_park 'gate:needs-human')" \
  "park:needs-human"
eq "gate:needs-human:fix-attempt:3 (wildcard suffix) → park" \
  "$(check_source_bead_park 'gate:needs-human:fix-attempt:3')" \
  "park:needs-human"
eq "gate:needs-human + gate:needs-fix → park (needs-human checked before needs-fix)" \
  "$(check_source_bead_park 'gate:needs-human gate:needs-fix')" \
  "park:needs-human"
eq "story:approved + gate:needs-human → park (circuit-break wins over approval)" \
  "$(check_source_bead_park 'story:approved gate:needs-human')" \
  "park:needs-human"

# ── 3. CRITICAL safety: story:approved path MUST pass through (no false park) ─
echo "── 3. story:approved → ok (normal gate path must not be blocked) ──"
eq "story:approved alone → ok" \
  "$(check_source_bead_park 'story:approved')" \
  "ok"
eq "story:approved + lane:small → ok" \
  "$(check_source_bead_park 'story:approved lane:small')" \
  "ok"
eq "story:approved + gate:needs-fix → ok (fix-iterate path, must pass)" \
  "$(check_source_bead_park 'story:approved gate:needs-fix')" \
  "ok"
eq "story:approved + gate:needs-fix + gate:fix-attempt:2 → ok" \
  "$(check_source_bead_park 'story:approved gate:needs-fix gate:fix-attempt:2')" \
  "ok"

# ── 4. gate:needs-fix alone → ok (fix-iterate path, must pass) ───────────────
echo "── 4. gate:needs-fix alone → ok (distinguish from gate:needs-human) ──"
eq "gate:needs-fix alone → ok" \
  "$(check_source_bead_park 'gate:needs-fix')" \
  "ok"
eq "gate:needs-fix + gate:fix-attempt:1 → ok" \
  "$(check_source_bead_park 'gate:needs-fix gate:fix-attempt:1')" \
  "ok"
eq "gate:needs-fix + gate:fix-attempt:3 (at-cap) → ok (dispatch still ok)" \
  "$(check_source_bead_park 'gate:needs-fix gate:fix-attempt:3')" \
  "ok"

# ── 5. Edge cases: empty / unknown labels → ok (fail-open) ───────────────────
echo "── 5. edge cases → ok (fail-open: unknown=no block) ──"
eq "empty labels → ok (fail-open)" \
  "$(check_source_bead_park '')" \
  "ok"
eq "unrelated labels only → ok" \
  "$(check_source_bead_park 'lane:small type:feature priority:high')" \
  "ok"
eq "label that is a PREFIX of needs-approval → ok (no substring match)" \
  "$(check_source_bead_park 'story:needs')" \
  "ok"
eq "label that is a PREFIX of needs-human → ok (no substring match)" \
  "$(check_source_bead_park 'gate:needs')" \
  "ok"

# ── 6. Drift-guards: guard implements Step 5a in the live sweep ───────────────
echo "── 6. drift-guard: guard implements Step 5a park check ──"
grep -q 'check_source_bead_park()'           "$GUARD" \
  && ok "guard defines check_source_bead_park" \
  || bad "guard missing check_source_bead_park def"
grep -q 'story:needs-approval'               "$GUARD" \
  && ok "guard checks story:needs-approval in check_source_bead_park" \
  || bad "guard missing story:needs-approval check"
grep -q 'gate:needs-human:\*)' "$GUARD" \
  && ok "guard checks gate:needs-human (wildcard suffix)" \
  || bad "guard missing gate:needs-human wildcard check"
grep -q 'gate:needs-human)' "$GUARD" \
  && ok "guard checks gate:needs-human (exact, bare)" \
  || bad "guard missing gate:needs-human exact check"
grep -q 'park:needs-approval'                "$GUARD" \
  && ok "guard emits park:needs-approval" \
  || bad "guard missing park:needs-approval return"
grep -q 'park:needs-human'                   "$GUARD" \
  && ok "guard emits park:needs-human" \
  || bad "guard missing park:needs-human return"
grep -q 'Step 5a'                            "$GUARD" \
  && ok "guard has Step 5a annotation" \
  || bad "guard missing Step 5a annotation"
grep -q 'PARK_ACTION'                        "$GUARD" \
  && ok "guard wires PARK_ACTION in live sweep" \
  || bad "guard does not use PARK_ACTION variable"
grep -q 'parked-needs-human'                 "$GUARD" \
  && ok "guard uses gate-status:parked-needs-human terminal label" \
  || bad "guard missing parked-needs-human label"
# The park path must close the marker (terminal ⇒ closed, ga-jhyu invariant).
# close and the reason string are on separate lines (bash line continuation),
# so grep separately: one for 'close "$MARKER_ID"' and one for the Step 5a tag.
grep -q 'close "\$MARKER_ID"'               "$GUARD" \
  && ok "guard closes the marker at park (ga-jhyu terminal invariant)" \
  || bad "guard does not close the marker in Step 5a — stranded open"
grep -q 'marker parked (terminal)'          "$GUARD" \
  && ok "guard close carries 'marker parked (terminal)' reason string" \
  || bad "guard missing 'marker parked (terminal)' in close reason"
# The check fires BEFORE Step 6 (gate-run creation) — verify ordering by checking
# that the Step 5a section header precedes the canonical "# ── Step 6:" header.
STEP5A_LINE=$(grep -n '# ── Step 5a:' "$GUARD" | head -1 | cut -d: -f1)
STEP6_LINE=$(grep -n '# ── Step 6:' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$STEP5A_LINE" ] && [ -n "$STEP6_LINE" ] && [ "$STEP5A_LINE" -lt "$STEP6_LINE" ]; then
  ok "Step 5a park check fires BEFORE Step 6 (gate-run creation) — no reviewer spawned"
else
  bad "Step 5a/Step 6 ordering wrong (5a must precede 6): 5a=${STEP5A_LINE:-missing} 6=${STEP6_LINE:-missing}"
fi
# FAIL-OPEN guard: the check is wrapped in `if [ -n "$BEAD_RAW" ]` so a lookup
# failure never blocks a legitimate submission.
grep -qE 'if \[ -n "\$BEAD_RAW" \]' "$GUARD" \
  && ok "park check is FAIL-OPEN (guarded by non-empty BEAD_RAW)" \
  || bad "park check is NOT fail-open (no BEAD_RAW guard — could block on lookup failure)"

# ── 7. Drift-guards (ga-oo66): AUTHOR is mailed on Step 5a park ──────────────
# Bug ga-oo66: a park (Step 5a) commented the marker + source bead but never
# told the AUTHOR — from the submitter's side, "parked, nobody will ever look"
# and "queued, reviewers incoming" emitted the identical signal (silence).
# /gate-done promises "you will be mailed when the gate passes or fails"; this
# park never fulfilled that promise. Fix: mail "$AUTHOR" (survives a dead/
# restarted session, unlike a comment — same rationale as ga-u4yi's AUTHOR
# mail at the dispatcher's gate:needs-human transition sites), scoped to the
# Step 5a block specifically (isolate from Step 6+ / dispatcher content).
# ga-409f4: the mail target is now $NOTIFY_AUTHOR (branch-author-aware),
# not the bead-derived $AUTHOR — same durable-mail property, different
# (more correct) identity source. Both patterns are accepted below.
# ga-z3i2p: $NOTIFY_AUTHOR alone is often UNDELIVERABLE (a bare crew-branch
# segment like "oracle" vs the real session alias "oracle-wa" — gc mail send
# resolves by exact match, no fuzzy/prefix fallback). Step 5a now tries a
# small candidate list (see gate-park-notify-address-fallback.selftest.sh for
# the full cascade + mutation tests) and, if EVERY candidate fails, escalates
# to mayor + leaves a durable marker comment instead of a bare log WARN — a
# terminal park must never let "could not notify" look identical to
# "notified". The checks below only prove the STRUCTURAL shape (mails a
# resolved candidate, distinguishes park from queued, escalates on total
# failure, fires before close); the address-resolution cascade itself is
# unit-tested end-to-end in the dedicated selftest.
echo "── 7. drift-guard: ga-oo66/ga-z3i2p — AUTHOR is mailed on Step 5a park (not just commented) ──"
STEP5A_BLOCK=$(awk '/# ── Step 5a:/{f=1} f{print} f&&/# ── Resolve the store that OWNS the source bead/{exit}' "$GUARD")
printf '%s\n' "$STEP5A_BLOCK" | grep -Eq 'mail send "\$_park_candidate"' \
  && ok "Step 5a mails a resolved author candidate on park (ga-oo66/ga-z3i2p)" \
  || bad "Step 5a still only comments — author has no durable park signal (ga-oo66 regression)"
printf '%s\n' "$STEP5A_BLOCK" | grep -qF 'PARK_NOTIFY_CANDIDATES="$NOTIFY_AUTHOR"' \
  && ok "Step 5a candidate list is seeded from NOTIFY_AUTHOR (still author-derived, not an arbitrary target)" \
  || bad "Step 5a candidate list no longer seeded from NOTIFY_AUTHOR — may notify the wrong identity"
# Both park reasons (needs-approval, needs-human) plus the fail-open default
# each compute their own unblock hint — exactly 3 assignments, mirroring
# ga-u4yi's "exactly N sites" counting style.
eq "Step 5a covers all 3 park-action branches with a tailored unblock hint" \
  "$(printf '%s\n' "$STEP5A_BLOCK" | grep -c 'UNBLOCK_HINT=')" \
  "3"
printf '%s\n' "$STEP5A_BLOCK" | grep -qi 'not queued' \
  && ok "Step 5a mail explicitly distinguishes 'parked' from 'queued, reviewers incoming'" \
  || bad "Step 5a mail does not distinguish park from queued — the ga-oo66 root-cause silence survives"
printf '%s\n' "$STEP5A_BLOCK" | grep -qF 'gc --city "$GC_CITY" mail send mayor' \
  && ok "Step 5a escalates to mayor when every author candidate fails (ga-z3i2p AC2)" \
  || bad "Step 5a has no mayor-escalation fallback — a total mail failure is silent again"
printf '%s\n' "$STEP5A_BLOCK" | grep -qF 'bd -C "$GC_CITY" comment "$MARKER_ID"' \
  && ok "Step 5a leaves a durable marker comment when author-notify fails (ga-z3i2p AC2, second signal)" \
  || bad "Step 5a does not mark the bead on notify failure — 'could not notify' looks identical to 'notified'"
# Ordering: notify attempt before close, mirroring the comment-then-mail-then-
# close sequence used at the dispatcher's own ga-u4yi sites.
# The `|| true` on each is required, not decorative: under set -euo pipefail,
# a legitimate zero-match grep (exactly the pre-fix case this line exists to
# catch) would otherwise abort the whole script instead of flowing into the
# "missing" branch below — the same error/empty conflation this codebase's
# own ga-p5q3 doctrine warns against, just inverted (empty caught as a hard
# abort instead of a graceful signal).
MAIL_LINE=$(printf '%s\n' "$STEP5A_BLOCK" | grep -nF 'for _park_candidate in $PARK_NOTIFY_CANDIDATES' | head -1 | cut -d: -f1 || true)
CLOSE_LINE=$(printf '%s\n' "$STEP5A_BLOCK" | grep -n 'close "\$MARKER_ID"' | head -1 | cut -d: -f1 || true)
if [ -n "$MAIL_LINE" ] && [ -n "$CLOSE_LINE" ] && [ "$MAIL_LINE" -lt "$CLOSE_LINE" ]; then
  ok "Step 5a author-notify attempt fires BEFORE the marker close"
else
  bad "Step 5a author-notify ordering wrong (notify attempt must precede close): notify=${MAIL_LINE:-missing} close=${CLOSE_LINE:-missing}"
fi

# ── 8. ga-o5de8: gate:needs-human:partial-delivery must NOT park ─────────────
# Deadlock this fixes: the ga-k2wjn/ga-zhfk8 scope backstop (quality-gate-
# dispatcher.sh) holds a gate-PASSED bug/task bead open by labeling it
# delivery:partial + gate:needs-human + gate:needs-human:partial-delivery
# instead of closing it, when its body looks like it enumerates more
# deliverables than the reviewed diff covered. Before this fix, Step 5a
# treated that bare gate:needs-human co-tag as a generic circuit-break and
# parked EVERY future marker for the bead — including a brand-new branch
# submitted specifically to deliver the missing item. The park blocked the
# only merge that could ever clear the label: permanent deadlock (reported by
# digo-wa, hit 3x in one day).
echo "── 8. gate:needs-human:partial-delivery (ga-o5de8) → ok, not parked ──"
eq "partial-delivery alone → ok" \
  "$(check_source_bead_park 'gate:needs-human:partial-delivery')" \
  "ok"
eq "real-world combo (bare co-tag + partial-delivery, as dispatcher actually sets both) → ok" \
  "$(check_source_bead_park 'gate:needs-human gate:needs-human:partial-delivery')" \
  "ok"
eq "full real-world combo incl. delivery:partial → ok" \
  "$(check_source_bead_park 'delivery:partial gate:needs-human gate:needs-human:partial-delivery')" \
  "ok"
eq "partial-delivery + unrelated labels → ok" \
  "$(check_source_bead_park 'lane:small gate:needs-human gate:needs-human:partial-delivery pilot:dispatched')" \
  "ok"

echo "── 8b. CONTROL: a genuine circuit-break sub-reason still parks, even alongside partial-delivery ──"
eq "partial-delivery + :technical (mixed reasons) → park" \
  "$(check_source_bead_park 'gate:needs-human gate:needs-human:partial-delivery gate:needs-human:technical')" \
  "park:needs-human"
eq "partial-delivery + :sibling-race (mixed reasons) → park" \
  "$(check_source_bead_park 'gate:needs-human:partial-delivery gate:needs-human:sibling-race')" \
  "park:needs-human"
eq "story:needs-approval + partial-delivery → park:needs-approval (approval check runs first, unaffected)" \
  "$(check_source_bead_park 'story:needs-approval gate:needs-human:partial-delivery')" \
  "park:needs-approval"

echo "── 8c. CONTROL: other real gate:needs-human sub-reasons (no partial-delivery) still park unchanged ──"
eq "gate:needs-human:technical alone → park" \
  "$(check_source_bead_park 'gate:needs-human gate:needs-human:technical')" \
  "park:needs-human"
eq "gate:needs-human:sibling-race alone → park" \
  "$(check_source_bead_park 'gate:needs-human gate:needs-human:sibling-race')" \
  "park:needs-human"
eq "gate:needs-human:diverging alone → park" \
  "$(check_source_bead_park 'gate:needs-human:diverging')" \
  "park:needs-human"
eq "gate:needs-human:product alone → park" \
  "$(check_source_bead_park 'gate:needs-human:product')" \
  "park:needs-human"
eq "bare gate:needs-human with no sub-reason at all → still park (conservative default preserved)" \
  "$(check_source_bead_park 'gate:needs-human')" \
  "park:needs-human"

echo "── 8d. drift-guard: guard's own comment cites the ga-o5de8 rationale ──"
grep -q 'ga-o5de8' "$GUARD" \
  && ok "guard documents the ga-o5de8 partial-delivery exemption" \
  || bad "guard missing ga-o5de8 rationale comment"
grep -q 'gate:needs-human:partial-delivery)' "$GUARD" \
  && ok "guard has a dedicated case arm for gate:needs-human:partial-delivery" \
  || bad "guard missing dedicated partial-delivery case arm"

# ── 9. ga-6qbgy: PARK_REASON cites the EXACT label(s) that matched, not the ──
#      bare prefix name. Real incident: a marker parked citing bare
#      "gate:needs-human" while the label actually present was
#      "gate:needs-human:technical" — an operator who removed only the bare
#      label (the only name the message ever gave them) verified a clean
#      list BY EXACT NAME and declared the veto cleared, while the sibling
#      variant kept parking every resubmission (wa-vcd01, 2026-08-06).
echo "── 9. ga-6qbgy: matching_veto_labels cites exact label(s), not bare prefix ──"

type matching_veto_labels >/dev/null 2>&1 \
  || { echo "FATAL: matching_veto_labels not defined by guard (ga-6qbgy fix missing?)"; exit 1; }

eq "bare label only → echoes the bare label" \
  "$(matching_veto_labels 'gate:needs-human gate:needs-fix' 'gate:needs-human')" \
  "gate:needs-human"

eq "bare + :technical both present → echoes BOTH, not just the bare prefix" \
  "$(matching_veto_labels 'gate:needs-human gate:needs-human:technical' 'gate:needs-human')" \
  "gate:needs-human gate:needs-human:technical"

eq "sub-reason only (no bare co-tag) → echoes the sub-reason variant" \
  "$(matching_veto_labels 'gate:needs-human:refused' 'gate:needs-human')" \
  "gate:needs-human:refused"

eq "unrelated labels are excluded" \
  "$(matching_veto_labels 'lane:small gate:needs-human:diverging pilot:dispatched' 'gate:needs-human')" \
  "gate:needs-human:diverging"

eq "no match → empty" \
  "$(matching_veto_labels 'gate:needs-fix lane:small' 'gate:needs-human')" \
  ""

eq "does not false-match a different label that merely shares the prefix as a substring" \
  "$(matching_veto_labels 'gate:needs-human-ish' 'gate:needs-human')" \
  ""

# CONTROL — reproduce the pre-fix bug shape directly: a check that only ever
# names the bare prefix cannot distinguish "bare only" from "bare + sibling
# variant present". This is the exact test the bug report calls for: one
# that FAILS if collapsed back to bare-prefix-only reporting.
BARE_ONLY_REPORT="gate:needs-human"
ACTUAL_MATCH=$(matching_veto_labels 'gate:needs-human gate:needs-human:technical' 'gate:needs-human')
if [ "$ACTUAL_MATCH" != "$BARE_ONLY_REPORT" ]; then
  ok "control: exact-match output DIFFERS from bare-prefix-only reporting (the bug is fixed)"
else
  bad "control: output collapsed to bare prefix — ga-6qbgy regression (sibling variant would be invisible again)"
fi

echo "── 9b. drift-guard: Step 5a's PARK_REASON construction actually USES matching_veto_labels ──"
grep -q 'MATCHED_VETO_LABELS=\$(matching_veto_labels "\$SRC_LABELS_PARK" "gate:needs-human")' "$GUARD" \
  && ok "Step 5a wires matching_veto_labels into the needs-human PARK_REASON" \
  || bad "Step 5a does not call matching_veto_labels for needs-human — would regress to bare-prefix text"
grep -q 'MATCHED_VETO_LABELS=\$(matching_veto_labels "\$SRC_LABELS_PARK" "story:needs-approval")' "$GUARD" \
  && ok "Step 5a wires matching_veto_labels into the needs-approval PARK_REASON" \
  || bad "Step 5a does not call matching_veto_labels for needs-approval"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
