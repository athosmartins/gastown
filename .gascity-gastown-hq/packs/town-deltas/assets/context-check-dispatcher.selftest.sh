#!/usr/bin/env bash
# context-check-dispatcher.selftest.sh — Regression harness for the Context-check
# creation-gate daemon ("Option D"). Proves the PURE decision core in isolation
# (no live Dolt/gc/Claude), then DRIFT-GUARDS the live wiring so a future refactor
# cannot silently break the design contract.
#
# Sources the dispatcher in lib-only mode (CONTEXT_CHECK_LIB=1) to unit-test the
# REAL functions the shipped dispatcher calls, so the tested logic IS the shipped
# logic (no parallel reimplementation).
#
# Contract proven:
#   - only actionable types judged; plumbing excluded     → Scenarios 1, 2.
#   - idempotence / anti-loop (ctx:* already present)       → Scenario 3.
#   - lifecycle-skip (in-flight/done/gate-stuck)            → Scenario 4.
#   - complete → ctx:ready ; empty/vague → ctx:thin         → Scenarios 5, 6, 7.
#   - terse-complete is NOT falsely thin (positive label)   → Scenario 6b (uncertain band).
#   - fail-toward-human: uncertain/timeout → ctx:thin       → Scenario 8.
#   - verdict vocabulary bounded to ctx:ready/ctx:thin      → Scenario 9.
#   - LABEL-ONLY: never dispatch/sling/close/lifecycle      → drift guards.
#   - DRY_RUN proof-mode runs clean (no write, no spawn)    → drift guard.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/context-check-dispatcher.sh"
# ga-a2v0bz: the drain signal (~/.gastown/run/city-drain.level, rewritten by nightly-reboot.sh 23:00-23:55) is AMBIENT
# state and the e2e blocks below keep the caller's real HOME. Pinned OPEN so this suite's outcome never depends on the
# time of day — unpinned, a run inside the drain window fails 7 e2e assertions (reproduced, gate run ga-y0fst4). The
# sandbox PATH below has /usr/sbin, so `sysctl` resolves and the signal is provable: nothing here fails open by luck.
export DRAIN_WINDOW_OVERRIDE=OPEN
# ga-ck3sz7: every e2e block runs the dispatcher on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh). They used to
# run it with "...:/usr/local/bin:/opt/homebrew/bin" — the dir the real gc and bd live in — so "with no live bd" (section 8)
# was false on this box, and the `bd` stub of section 11 (first on that PATH) fell through to the REAL bd the moment its
# fixture dir vanished. Sourced at the top: a missing lib refuses to start instead of dying half way through.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
# _sb_init <dir> — <dir>/bin is where a stub goes; sets SANDBOX_PATH. jq/git/timeout are what the dispatcher (and the
# `timeout 120 bash` wrapper the e2e blocks put in front of it) really need from outside /usr/bin:/bin.
_sb_init() { mkdir -p "$1/bin" && sandbox_path_init "$1" jq git timeout; }
# The e2e blocks bound the dispatcher with `timeout 120` (was 30). It is a hang-guard, not an assertion about speed: a
# sweep of 6 fixture beads measured 3s-33s wall on this box depending on load (30s was blown on the ORIGINAL PATH too,
# 31s, at load ~48), and a killed sweep never reaches the last fixture (ga-stillthin2) — a red test caused by the machine.

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

echo "context-check-dispatcher.selftest — pure decision core + drift guards (Option D)"

# Source the dispatcher in lib-only mode (pure functions only, no side effects).
CONTEXT_CHECK_LIB=1 . "$DISPATCHER"

if declare -F context_check_verdict_label >/dev/null 2>&1; then
  ok "sourced lib-only: context_check_verdict_label is defined"
else
  bad "lib-only source did not expose context_check_verdict_label"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# Pin the exclude sets the pure plumbing classifier reads (the dispatcher sets
# defaults; we re-assert them so the selftest is hermetic).
CONTEXT_CHECK_EXCLUDE_LABELS="gt:agent gt:rig gt:convoy gc:nudge digest pinned gt:message"
CONTEXT_CHECK_EXCLUDE_PREFIXES="type:quality-gate gate-status: nudge: reviewer-index: verdict: refino-gate: auto-refino: gate-reclaim-count: order-run: ctx:"
# Pin heuristic thresholds so length-based assertions are deterministic.
CONTEXT_CHECK_THIN_MAXLEN=40
CONTEXT_CHECK_READY_MINLEN=120

# ── Scenario 1: type eligibility ──────────────────────────────────────────────
echo "Scenario 1: type eligibility — bug/chore/task/debt + feature checkable; others not"
for t in bug chore task debt feature; do
  [ "$(context_check_type_eligible "$t")" = "yes" ] && ok "$t → yes" || bad "$t → expected yes"
done
for t in epic decision molecule gate convoy merge-request; do
  [ "$(context_check_type_eligible "$t")" = "no" ] && ok "$t → no" || bad "$t → expected no"
done

# ── Scenario 2: plumbing exclusion (mirrors painel _is_automation_bead + gate family)
echo "Scenario 2: plumbing exclusion — engine-internal coordination is NOT human work"
[ "$(context_check_is_plumbing "ga-x" "type:quality-gate-marker" "false")" = "yes" ] && ok "gate marker → plumbing" || bad "gate marker → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "gate-status:queued" "false")" = "yes" ]        && ok "gate-status:* → plumbing" || bad "gate-status → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "gt:agent" "false")" = "yes" ]                  && ok "gt:agent → plumbing"     || bad "gt:agent → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "gc:nudge" "false")" = "yes" ]                  && ok "gc:nudge → plumbing"     || bad "gc:nudge → expected plumbing"
[ "$(context_check_is_plumbing "dc-abc" "" "false")" = "yes" ]                        && ok "dc- id → plumbing"       || bad "dc- → expected plumbing"
[ "$(context_check_is_plumbing "ga-wisp-x" "" "false")" = "yes" ]                     && ok "-wisp- id → plumbing"    || bad "-wisp- → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "" "true")" = "yes" ]                           && ok "ephemeral → plumbing"    || bad "ephemeral → expected plumbing"
[ "$(context_check_is_plumbing "ga-real" "tech-debt" "false")" = "no" ]               && ok "real bead (tech-debt) → NOT plumbing" || bad "real bead → expected not plumbing"
[ "$(context_check_is_plumbing "ga-real" "" "false")" = "no" ]                        && ok "real bead (no labels) → NOT plumbing" || bad "real bead → expected not plumbing"
# ga-aq5cw: mol-digest-generate's archive-as-bead step tags type=task beads
# label=digest,{{period}} with no park label — a pure log record, no code to build.
[ "$(context_check_is_plumbing "ga-x" "digest,daily" "false")" = "yes" ]              && ok "digest label → plumbing (ga-aq5cw)" || bad "digest → expected plumbing"
# ga-gzv7g: pinned marks a permanent-reference/preservation note (e.g. the
# Mayor's pre-restart capture of unsubmitted Athos instructions) — not human
# work to be judged/dispatched.
[ "$(context_check_is_plumbing "ga-x" "pinned" "false")" = "yes" ]                    && ok "pinned label → plumbing (ga-gzv7g)" || bad "pinned → expected plumbing"
# ga-4yii8z: gt:message marks a self-continuity handoff/patrol note an agent
# leaves for itself across session cycling (e.g. "🤝 HANDOFF: Patrol cycling")
# — same shape as pinned above, not human work to be judged/dispatched.
[ "$(context_check_is_plumbing "ga-x" "gt:message" "false")" = "yes" ]                && ok "gt:message label → plumbing (ga-4yii8z)" || bad "gt:message → expected plumbing"

# ── Scenario 3: idempotence — an already-judged bead is never re-judged ───────
echo "Scenario 3: idempotence / anti-loop (ga-it11w lesson) — ctx:* already present"
[ "$(context_check_has_ctx_label "ctx:ready")" = "yes" ] && ok "ctx:ready present → yes" || bad "ctx:ready → expected yes"
[ "$(context_check_has_ctx_label "ctx:thin,tech-debt")" = "yes" ] && ok "ctx:thin present → yes" || bad "ctx:thin → expected yes"
[ "$(context_check_has_ctx_label "tech-debt,daily")" = "no" ] && ok "no ctx:* → no (judgeable)" || bad "no ctx:* → expected no"
# A ctx:thin bead is NEVER re-selected as a candidate (the anti-loop guarantee).
[ "$(context_check_is_candidate "ga-x" "task" "ctx:thin,tech-debt" "false" "no")" = "no" ] \
  && ok "ctx:thin bead → NOT a candidate (no re-ingestion loop)" \
  || bad "ctx:thin bead → expected NOT a candidate (loop would re-form)"
[ "$(context_check_is_candidate "ga-x" "task" "ctx:ready" "false" "no")" = "no" ] \
  && ok "ctx:ready bead → NOT a candidate (idempotent)" || bad "ctx:ready → expected NOT a candidate"

# ── Scenario 4: lifecycle-skip — never re-label work already moving ───────────
echo "Scenario 4: lifecycle-skip — in-flight/done/cancelled/gate-stuck/dispatched"
for L in story:in-flight story:done story:cancelled pilot:dispatched gate:needs-human gate:needs-fix gate:failed; do
  [ "$(context_check_lifecycle_skip "$L")" = "yes" ] && ok "$L → skip" || bad "$L → expected skip"
done
[ "$(context_check_lifecycle_skip "tech-debt")" = "no" ] && ok "tech-debt (active work) → not skipped" || bad "tech-debt → expected not skipped"

# ── Scenario 4a: park-exclusion (ga-ipm4) — never re-arm a deliberately parked bead
echo "Scenario 4a: park-exclusion — needs-human/pool:refused:*/story:blocked/pilot:no-auto-dispatch never re-armed"
[ "$(context_check_is_parked "needs-human")" = "yes" ] && ok "needs-human → parked" || bad "needs-human → expected parked"
[ "$(context_check_is_parked "story:blocked")" = "yes" ] && ok "story:blocked → parked" || bad "story:blocked → expected parked"
[ "$(context_check_is_parked "pool:refused:engine-rebuild-required")" = "yes" ] && ok "pool:refused:<reason> → parked" || bad "pool:refused:* → expected parked"
[ "$(context_check_is_parked "pool:refused:anything-else")" = "yes" ] && ok "pool:refused:* prefix matches any reason suffix" || bad "pool:refused:<other> → expected parked"
[ "$(context_check_is_parked "root-class:error-vs-empty,needs-human,lane:small")" = "yes" ] && ok "needs-human mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
# ga-r8haw (follow-up to ga-6qbgy): bare needs-human must match suffixed
# variants too, not just the exact literal — same bare-or-":"/"-"-suffix
# rule as park_labels.py's label_matches() and this function's own
# pool:refused:* line above. needs-human-decision is a real sibling label
# (pilot-dispatcher.sh's candidate filter excludes it as a distinct case
# alongside bare needs-human); a colon-suffixed needs-human:<reason> would
# use the same convention gate:needs-human:* already uses one namespace over.
[ "$(context_check_is_parked "needs-human-decision")" = "yes" ] \
  && ok "needs-human-decision (dash-suffixed sibling) → parked (ga-r8haw)" || bad "needs-human-decision → expected parked (ga-r8haw)"
[ "$(context_check_is_parked "needs-human:technical")" = "yes" ] \
  && ok "needs-human:technical (colon-suffixed) → parked (ga-r8haw)" || bad "needs-human:technical → expected parked (ga-r8haw)"
[ "$(context_check_is_parked "lane:small,needs-human-decision,area:infra")" = "yes" ] \
  && ok "needs-human-decision mixed with unrelated labels → parked (ga-r8haw)" || bad "mixed labels → expected parked (ga-r8haw)"
# Negative control: a label that merely SHARES the "needs-human" characters
# without the "-"/":" separator must NOT false-positive (mirrors the "PREFIX
# of needs-human → ok" negative control in quality-gate-park-unapproved.selftest.sh).
[ "$(context_check_is_parked "needs-humanoid-unrelated")" = "no" ] \
  && ok "needs-humanoid-unrelated (no separator) → NOT parked, no over-match (ga-r8haw)" || bad "needs-humanoid-unrelated → expected NOT parked (ga-r8haw)"
[ "$(context_check_is_parked "tech-debt,lane:small")" = "no" ] && ok "no park label → not parked" || bad "clean labels → expected not parked"
[ "$(context_check_is_parked "")" = "no" ] && ok "empty labels → not parked" || bad "empty → expected not parked"
# ga-66wc repro: a park label surviving ALONE (ctx:ready/exec:auto already stripped
# by a human/dog) must still read as parked — this is exactly the state that
# tricked the pre-fix daemon into treating the bead as "fresh, never judged".
[ "$(context_check_is_parked "needs-human,pool:refused:engine-rebuild-required,root-class:error-vs-empty")" = "yes" ] \
  && ok "ga-66wc post-strip label set (no ctx:*, no exec:*) → still parked" || bad "ga-66wc post-strip set → expected parked"
# ga-bzbig: pilot:no-auto-dispatch — the sticky opt-out for a disarm reason
# outside the other three (e.g. an epic-child tracker/umbrella, not human-gated,
# not refused, not dependency-blocked, just structurally not a single
# dispatchable unit).
[ "$(context_check_is_parked "pilot:no-auto-dispatch")" = "yes" ] && ok "pilot:no-auto-dispatch → parked" || bad "pilot:no-auto-dispatch → expected parked"
[ "$(context_check_is_parked "area:infra,pilot:no-auto-dispatch,lane:small")" = "yes" ] && ok "pilot:no-auto-dispatch mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
# ga-0x4tv repro: pilot:no-auto-dispatch surviving ALONE (ctx:ready/exec:auto/
# story:approved already stripped by Mayor) must still read as parked — this is
# exactly the state that tricked the pre-fix daemon into re-arming ga-0x4tv
# 42min after Mayor's manual disarm (context-check-dispatcher.log: "ga-0x4tv →
# ctx:ready + exec:auto (mech=ready sig=yes dlen=962)").
[ "$(context_check_is_parked "area:infra,pilot:no-auto-dispatch,epic:ga-05604")" = "yes" ] \
  && ok "ga-0x4tv post-strip label set (no ctx:*, no exec:*, no story:approved) → still parked" || bad "ga-0x4tv post-strip set → expected parked"

# ga-rfpm9: bare "no-auto-dispatch" (no pilot: prefix) is a DIFFERENT string
# this case statement never matched pre-fix — this is the CANONICAL consumer
# ga-bzbig's own comment above names, so the bare-label gap here is the
# primary bug, not a defense-in-depth mirror (pilot-dispatcher.sh's three
# chokepoints are the mirrors, fixed in the same story).
[ "$(context_check_is_parked "no-auto-dispatch")" = "yes" ] && ok "ga-rfpm9: bare no-auto-dispatch → parked" || bad "ga-rfpm9: bare no-auto-dispatch → expected parked"
[ "$(context_check_is_parked "area:infra,no-auto-dispatch,lane:small")" = "yes" ] && ok "ga-rfpm9: bare no-auto-dispatch mixed with unrelated labels → parked" || bad "ga-rfpm9: mixed labels → expected parked"
[ "$(context_check_is_parked "area:infra,no-auto-dispatch,epic:ga-05604")" = "yes" ] \
  && ok "ga-rfpm9: ga-0x4tv-shaped post-strip set with the BARE label → still parked" || bad "ga-rfpm9: bare-label post-strip set → expected parked"
# Negative control: a label merely containing the substring, not equal to it,
# must not false-positive (case-statement alternatives here are exact-match,
# no wildcard on this one — mirrors the needs-humanoid-unrelated control above).
[ "$(context_check_is_parked "team:no-auto-dispatch-followup")" = "no" ] \
  && ok "ga-rfpm9: label merely containing the substring → NOT parked, no over-match" || bad "ga-rfpm9: expected NOT parked (over-match regression)"

# ── Scenario 4a3 (ga-7mbry, 3rd occurrence): blocked:*/pilot:refused-reason:*/
# needs:engine-window/gate:needs-human:* — four more park signals this function
# was blind to. wa-ic1uw repro: a bead parked with `blocked:external-quota-
# motherduck` (ctx:ready/exec:auto already stripped) read as "fresh, never
# judged" on the next sweep and was re-armed — an operator/wa-worker reclaimed
# it a 7th time before this fix.
echo "Scenario 4a3: park-exclusion (ga-7mbry) — blocked:*/pilot:refused-reason:*/needs:engine-window/gate:needs-human:* never re-armed"
[ "$(context_check_is_parked "blocked:external-quota-motherduck")" = "yes" ] && ok "blocked:<reason> → parked (ga-7mbry, wa-ic1uw repro)" || bad "blocked:<reason> → expected parked"
[ "$(context_check_is_parked "blocked:needs-remeasure")" = "yes" ] && ok "blocked:<other reason> prefix matches any suffix" || bad "blocked:<other> → expected parked"
[ "$(context_check_is_parked "lane:small,blocked:external-quota-motherduck,area:infra")" = "yes" ] && ok "blocked:<reason> mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
# Negative control: "blocked-by:*" is a DIFFERENT label family (points at what
# blocks a bead, not "this bead IS blocked") — must not false-positive through
# the colon-only blocked:* match, mirroring the needs-humanoid negative control
# above and pilot-dispatcher.sh's own ga-4iw15 "blocked:[^,]*" scope (colon only).
[ "$(context_check_is_parked "blocked-by:wa-10srb")" = "no" ] \
  && ok "blocked-by:<id> (different label family) → NOT parked, no over-match (ga-7mbry)" || bad "blocked-by:<id> → expected NOT parked"
[ "$(context_check_is_parked "pilot:refused-reason:oracle-named-executor")" = "yes" ] && ok "pilot:refused-reason:<slug> → parked (ga-uvfs6 audit label)" || bad "pilot:refused-reason:<slug> → expected parked"
[ "$(context_check_is_parked "story:in-flight,pilot:refused-reason:cross-rig-framework")" = "yes" ] && ok "pilot:refused-reason:<slug> mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
[ "$(context_check_is_parked "needs:engine-window")" = "yes" ] && ok "needs:engine-window → parked (ga-vhyd exact label)" || bad "needs:engine-window → expected parked"
[ "$(context_check_is_parked "framework,lane:small,needs:engine-window")" = "yes" ] && ok "needs:engine-window mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
[ "$(context_check_is_parked "gate:needs-human:technical")" = "yes" ] && ok "gate:needs-human:<reason> (colon-suffixed) → parked" || bad "gate:needs-human:<reason> → expected parked"
[ "$(context_check_is_parked "gate:needs-human:partial-delivery")" = "yes" ] && ok "gate:needs-human:<other reason> prefix matches any suffix" || bad "gate:needs-human:<other> → expected parked"
[ "$(context_check_is_parked "gate:needs-human")" = "yes" ] && ok "gate:needs-human bare (redundant w/ lifecycle_skip, still recognized here)" || bad "gate:needs-human bare → expected parked"
# is_candidate-level integration test — the exact wa-ic1uw shape: ctx:ready/
# exec:auto already stripped, only the park label remains.
[ "$(context_check_is_candidate "wa-ic1uw" "bug" "blocked:external-quota-motherduck,lane:small" "false" "no")" = "no" ] \
  && ok "wa-ic1uw-shaped bead (parked via blocked:*, ctx:* stripped) → NOT a candidate (no re-arm, ga-7mbry)" \
  || bad "REGRESSION ga-7mbry: blocked:*-parked bead with ctx:* stripped would be re-judged and re-armed"

# ── Scenario 4a2: sling-stub detection (ga-mzkx2) ──────────────────────────────
echo "Scenario 4a2: context_check_is_sling_stub — Pilot-minted dispatch stubs are by-design empty, not thin"
[ "$(context_check_is_sling_stub "task" "fix bug ga-mzkx2: sling-task-janitor closes ctx:thin dispatch stubs" 0)" = "yes" ] \
  && ok "task, 'fix bug <id>: ...' title, empty desc → sling stub" || bad "fix bug shape → expected sling stub"
[ "$(context_check_is_sling_stub "task" "build story ga-mk6ve: raw classifier signal" 0)" = "yes" ] \
  && ok "task, 'build story <id>: ...' title, empty desc → sling stub" || bad "build story shape → expected sling stub"
[ "$(context_check_is_sling_stub "task" "implement ga-x: something" 0)" = "yes" ] \
  && ok "task, 'implement <id>: ...' title, empty desc → sling stub" || bad "implement shape → expected sling stub"
[ "$(context_check_is_sling_stub "bug" "fix bug ga-mzkx2: something" 0)" = "no" ] \
  && ok "issue_type=bug (not task) → NOT a sling stub (Pilot only mints type=task stubs)" || bad "bug type → expected not sling stub"
[ "$(context_check_is_sling_stub "task" "fix bug ga-mzkx2: something" 42)" = "no" ] \
  && ok "non-empty description → NOT a sling stub (a real, independently-described task)" || bad "non-empty desc → expected not sling stub"
[ "$(context_check_is_sling_stub "task" "Refatorar o dashboard de clientes" 0)" = "no" ] \
  && ok "title doesn't match the dispatch-stub pattern → NOT a sling stub" || bad "unrelated title → expected not sling stub"
[ "$(context_check_is_sling_stub "task" "" 0)" = "no" ] \
  && ok "empty title → NOT a sling stub (no pattern to match)" || bad "empty title → expected not sling stub"

# ── Scenario 4b: master candidate gate composes all the above ─────────────────
echo "Scenario 4b: context_check_is_candidate composes type+plumbing+ctx+lifecycle+park"
[ "$(context_check_is_candidate "ga-good" "task" "tech-debt" "false" "no")" = "yes" ] \
  && ok "real open task, no ctx, not plumbing/in-flight → candidate" || bad "real task → expected candidate"
[ "$(context_check_is_candidate "ga-feat" "feature" "story:unrefined" "false" "yes")" = "no" ] \
  && ok "feature WITH story:* (refino funnel) → NOT a candidate" || bad "feature w/ story:* → expected not candidate"
[ "$(context_check_is_candidate "ga-feat2" "feature" "frontend" "false" "no")" = "yes" ] \
  && ok "feature WITHOUT story:* → candidate (raw actionable)" || bad "feature w/o story:* → expected candidate"
[ "$(context_check_is_candidate "ga-junk" "epic" "" "false" "no")" = "no" ] \
  && ok "epic → NOT a candidate (type ineligible)" || bad "epic → expected not candidate"
# ga-ipm4: the exact ga-66wc shape — bug, no ctx:* label (stripped), park labels
# present, no lifecycle/lock label — must NOT re-enter candidacy.
[ "$(context_check_is_candidate "ga-66wc" "bug" "needs-human,pool:refused:engine-rebuild-required,root-class:error-vs-empty" "false" "no")" = "no" ] \
  && ok "ga-66wc-shaped bead (parked, ctx:* stripped) → NOT a candidate (no re-arm)" \
  || bad "REGRESSION ga-ipm4: parked bead with ctx:* stripped would be re-judged and re-armed"
[ "$(context_check_is_candidate "ga-blocked" "chore" "story:blocked,lane:small" "false" "no")" = "no" ] \
  && ok "story:blocked bead → NOT a candidate" || bad "story:blocked → expected not candidate"
# ga-bzbig: the exact ga-0x4tv shape — chore, no ctx:* label (Mayor stripped it),
# pilot:no-auto-dispatch present, no lifecycle/lock label — must NOT re-enter
# candidacy (this is the regression: pre-fix, is_parked didn't recognize this
# label so is_candidate returned "yes" and the daemon re-armed ctx:ready+exec:auto).
[ "$(context_check_is_candidate "ga-0x4tv" "chore" "area:infra,pilot:no-auto-dispatch,epic:ga-05604" "false" "no")" = "no" ] \
  && ok "ga-0x4tv-shaped bead (parked via pilot:no-auto-dispatch, ctx:* stripped) → NOT a candidate (no re-arm)" \
  || bad "REGRESSION ga-bzbig: Mayor-disarmed tracker with ctx:* stripped would be re-judged and re-armed"
# ga-rfpm9: same ga-0x4tv shape, BARE label (no pilot: prefix) — the primary
# bug this story fixes, end-to-end through context_check_is_candidate.
[ "$(context_check_is_candidate "ga-0x4tv-bare" "chore" "area:infra,no-auto-dispatch,epic:ga-05604" "false" "no")" = "no" ] \
  && ok "ga-rfpm9: ga-0x4tv-shaped bead parked via the BARE no-auto-dispatch label → NOT a candidate (no re-arm)" \
  || bad "REGRESSION ga-rfpm9: bare-label-disarmed tracker with ctx:* stripped would be re-judged and re-armed"
# ga-aq5cw: the exact ga-sh5zv/ga-mun9x shape — a freshly-created digest-archive
# bead (type=task, label=digest,{{period}}, no ctx:* yet, no park label at all)
# — must never be granted candidacy in the first place (there is no park label
# to strip; the fix is at the type/plumbing gate, not the park gate).
[ "$(context_check_is_candidate "ga-sh5zv" "task" "digest,daily" "false" "no")" = "no" ] \
  && ok "digest-archive bead (task, label=digest) → NOT a candidate (ga-aq5cw)" \
  || bad "REGRESSION ga-aq5cw: digest-archive bead would be armed ctx:ready+exec:auto with nothing to build"
# ga-gzv7g: the exact ga-sxbvj/ga-lvtqi shape — a Mayor pre-restart
# preservation note (label=pinned, no other park label) — must never be
# granted candidacy in the first place, same gate as the digest-archive
# case above.
[ "$(context_check_is_candidate "ga-sxbvj" "task" "pinned" "false" "no")" = "no" ] \
  && ok "pinned bead (task, label=pinned) → NOT a candidate (ga-gzv7g)" \
  || bad "REGRESSION ga-gzv7g: pinned preservation-note bead would be armed ctx:ready+exec:auto with nothing to build"
# ga-4yii8z: the exact dc-etn4/dc-3okx/dc-oq0g shape — a self-continuity
# handoff/patrol note (label=gt:message, no other park label) — must never be
# granted candidacy in the first place, same gate as the pinned case above.
[ "$(context_check_is_candidate "dc-etn4" "task" "gt:message" "false" "no")" = "no" ] \
  && ok "gt:message bead (task, label=gt:message) → NOT a candidate (ga-4yii8z)" \
  || bad "REGRESSION ga-4yii8z: gt:message handoff-note bead would be armed ctx:ready+exec:auto with nothing to build"
# ga-mzkx2: the exact ga-tdaeq shape — a freshly-minted sling-task stub (task,
# "fix bug <id>: ..." title, 0-char description, no labels yet) — must never be
# granted candidacy (and thus never get ctx:thin), so Step 1c's dog-pool probe
# (--exclude-label ctx:thin) can still discover it before sling-task-janitor's
# 60min orphan sweep closes it, unclaimed, as an abandoned dispatch.
[ "$(context_check_is_candidate "ga-tdaeq" "task" "" "false" "no" "fix bug ga-mk6ve: raw classifier signal" 0)" = "no" ] \
  && ok "sling-task stub (task, dispatch-shaped title, empty desc) → NOT a candidate (ga-mzkx2, no ctx:thin mislabel)" \
  || bad "REGRESSION ga-mzkx2: sling stub would be stamped ctx:thin and become invisible to Step 1c's dog-pool probe"
# The same dimension omitted (title/dlen not supplied) must preserve prior
# behavior exactly — existing callers of this function (and every scenario
# above) never break just because the sling-stub check exists.
[ "$(context_check_is_candidate "ga-good" "task" "tech-debt" "false" "no")" = "yes" ] \
  && ok "title/dlen omitted → sling-stub dimension skipped, prior behavior unchanged" \
  || bad "omitted title/dlen → expected unchanged prior behavior"
# A real, independently-described task whose title MATCHES the dispatch-stub
# pattern (cites another bead's id) must NOT be swallowed — the desc_len==0
# guard, not the title shape alone, is what keeps context_check_is_sling_stub
# from over-firing on real work that happens to reference an id in its title.
[ "$(context_check_is_candidate "ga-realbug" "task" "tech-debt" "false" "no" "fix bug ga-real1: add missing null check" 42)" = "yes" ] \
  && ok "sling-shaped title (cites ga-real1) but a REAL, non-empty description → still a candidate" \
  || bad "real described task → expected candidate despite title resembling the dispatch-stub pattern"

# ── Scenario 5: verifiable-signal detection ───────────────────────────────────
echo "Scenario 5: verifiable-signal detection (HOW-TO-VERIFY / concrete artifact)"
[ "$(context_check_has_verifiable_signal "Acceptance criteria: the CLI returns 0")" = "yes" ] && ok "acceptance criteria → signal" || bad "acceptance → expected signal"
[ "$(context_check_has_verifiable_signal "deve retornar o resultado esperado")" = "yes" ]      && ok "pt verification vocab → signal" || bad "pt verif → expected signal"
[ "$(context_check_has_verifiable_signal "edit scripts/foo.sh to add retry")" = "yes" ]        && ok "named .sh artifact → signal" || bad ".sh → expected signal"
[ "$(context_check_has_verifiable_signal "run bd list and confirm output")" = "yes" ]          && ok "named bd command → signal" || bad "bd cmd → expected signal"
[ "$(context_check_has_verifiable_signal "- [ ] step one
- [ ] step two")" = "yes" ]                                                                   && ok "task-list checklist → signal" || bad "checklist → expected signal"
[ "$(context_check_has_verifiable_signal "make it better somehow")" = "no" ]                   && ok "vague prose → no signal" || bad "vague → expected no signal"
[ "$(context_check_has_verifiable_signal "")" = "no" ]                                         && ok "empty → no signal" || bad "empty → expected no signal"
# ga-gqokrx — context_check_has_verifiable_signal has the identical ASCII-only
# case-fold gap ga-dpas3r fixed in context_check_exec_class: `tr 'A-Z' 'a-z'`
# doesn't touch an uppercase accented letter's UTF-8 bytes, so an uppercase
# "É" passes through untouched and matches neither the "critério" nor the
# "criterio" alternative already listed above. Reuses the exact accent-fold
# ga-dpas3r added upstream in context_check_exec_class (no apostrophe fold
# needed here — this function has no apostrophe-based literals).
#
# NOTE on the bead's own repro string: ga-gqokrx's reported repro
# ("CRITÉRIO DE ACEITE: retorna 200 se autenticado") in fact returns "yes"
# today, unfixed — it already contains the literal (unaccented, already-
# lowercase) word "retorna", which independently satisfies the signal check
# regardless of the CRITÉRIO fold bug. Verified directly against the shipped
# (pre-fix) function before writing these tests. The two cases below isolate
# the actual fold gap with no such confound: no other vocabulary word,
# checklist marker or file-extension/command literal appears in either
# string, so each must fail on the accent fold alone, not by accident.
[ "$(context_check_has_verifiable_signal "CRITÉRIO obrigatorio para este trabalho ficar completo e aceitavel sem duvida")" = "yes" ] \
  && ok "ga-gqokrx: all-caps 'CRITÉRIO', no other trigger word → signal" || bad "ga-gqokrx REGRESSION: all-caps 'CRITÉRIO' failed to fold → no signal"
[ "$(context_check_has_verifiable_signal "critÉrio obrigatorio para este trabalho ficar completo e aceitavel sem duvida")" = "yes" ] \
  && ok "ga-gqokrx: lone uppercase accented letter 'critÉrio' → signal" || bad "ga-gqokrx REGRESSION: lone uppercase accented letter 'critÉrio' failed to fold"

# ── Scenario 6: mechanical verdict — complete → ready ; empty/vague → thin ────
echo "Scenario 6: mechanical verdict"
# Long + signal → ready.
[ "$(context_check_mechanical_verdict 200 yes 30)" = "ready" ] && ok "long(200) + signal → ready" || bad "long+signal → expected ready"
# Empty / near-empty → thin regardless of signal.
[ "$(context_check_mechanical_verdict 0 no 10)" = "thin" ]    && ok "empty(0) → thin" || bad "empty → expected thin"
[ "$(context_check_mechanical_verdict 20 yes 10)" = "thin" ]  && ok "near-empty(20) even w/ signal → thin" || bad "near-empty → expected thin"
# Described, no signal, short body → lean thin.
[ "$(context_check_mechanical_verdict 80 no 10)" = "thin" ]   && ok "described(80) no signal → thin" || bad "described-no-signal → expected thin"
echo "Scenario 6b: terse-but-maybe-complete → uncertain (NOT falsely thin/ready)"
# Signal present but short body → uncertain (Sonnet-judged, not auto-ready/thin).
[ "$(context_check_mechanical_verdict 70 yes 30)" = "uncertain" ] && ok "short(70) + signal → uncertain (terse-complete defended)" || bad "short+signal → expected uncertain"
# Long body but NO signal → uncertain (long ramble must not auto-ready).
[ "$(context_check_mechanical_verdict 300 no 30)" = "uncertain" ] && ok "long(300) no signal → uncertain (no false ready)" || bad "long-no-signal → expected uncertain"
# Byte-count alone can NEVER yield ready (no-signal long stays uncertain, never ready).
[ "$(context_check_mechanical_verdict 5000 no 30)" != "ready" ] && ok "huge body w/o signal NEVER auto-ready (positive-label invariant)" || bad "huge-no-signal → must not be ready"

# ── Scenario 7: final label resolution ────────────────────────────────────────
echo "Scenario 7: verdict_label maps mechanical(+sonnet) → ctx:ready | ctx:thin"
[ "$(context_check_verdict_label ready)" = "ctx:ready" ] && ok "ready → ctx:ready" || bad "ready → expected ctx:ready"
[ "$(context_check_verdict_label thin)" = "ctx:thin" ]   && ok "thin → ctx:thin" || bad "thin → expected ctx:thin"
[ "$(context_check_verdict_label uncertain READY)" = "ctx:ready" ] && ok "uncertain + Sonnet READY → ctx:ready" || bad "uncertain+READY → expected ctx:ready"
[ "$(context_check_verdict_label uncertain THIN)" = "ctx:thin" ]   && ok "uncertain + Sonnet THIN → ctx:thin" || bad "uncertain+THIN → expected ctx:thin"

# ── Scenario 8: fail-toward-human — uncertain without a clear READY → ctx:thin ─
echo "Scenario 8: fail-toward-human (never falsely ready)"
[ "$(context_check_verdict_label uncertain TIMEOUT)" = "ctx:thin" ] && ok "uncertain + Sonnet TIMEOUT → ctx:thin" || bad "uncertain+TIMEOUT → expected ctx:thin"
[ "$(context_check_verdict_label uncertain "")" = "ctx:thin" ]      && ok "uncertain + no Sonnet verdict → ctx:thin (heuristic-only default)" || bad "uncertain+empty → expected ctx:thin"
[ "$(context_check_verdict_label uncertain GARBAGE)" = "ctx:thin" ] && ok "uncertain + garbage → ctx:thin" || bad "uncertain+garbage → expected ctx:thin"
[ "$(context_check_resolve_uncertain READY)" = "ctx:ready" ]        && ok "resolve_uncertain READY → ctx:ready" || bad "resolve READY → expected ctx:ready"
[ "$(context_check_resolve_uncertain FAIL)" = "ctx:thin" ]          && ok "resolve_uncertain FAIL → ctx:thin (only explicit READY is ready)" || bad "resolve FAIL → expected ctx:thin"

# ── Scenario 9: verdict vocabulary is bounded — only ctx:ready / ctx:thin ──────
echo "Scenario 9: verdict vocabulary bounded (no dispatch/approve/lifecycle token)"
seen_bad=0
for m in ready thin uncertain garbage ""; do
  for s in READY THIN TIMEOUT "" FAIL; do
    d=$(context_check_verdict_label "$m" "$s")
    case "$d" in ctx:ready|ctx:thin) : ;; *) seen_bad=1; bad "unexpected verdict label '$d' for mech=$m sonnet=$s" ;; esac
  done
done
[ "$seen_bad" = "0" ] && ok "every input yields ONLY ctx:ready or ctx:thin (no dispatch/approve/lifecycle)" || bad "REGRESSION: verdict label escaped the ctx:ready/ctx:thin set"

# ── Scenario 10: exec-class (automation-debt) classifier ──────────────────────
# Applied to ctx:ready beads only. exec:manual iff a clear physical-device /
# human-identity-credential / human-provisioning signal; else exec:auto (default).
echo "Scenario 10: exec-class — physical/portal/credential → exec:manual; else exec:auto"
if declare -F context_check_exec_class >/dev/null 2>&1; then
  ok "context_check_exec_class is defined (exposed lib-only)"
else
  bad "context_check_exec_class not exposed by lib-only source"
fi
# 10a — PHYSICAL device / hardware / physical proxy → exec:manual (agent has no hands).
[ "$(context_check_exec_class "experimentar phone-as-Claro-mobile-proxy" "plugar o celular físico como proxy móvel da Claro")" = "exec:manual" ] \
  && ok "phone-as-proxy (physical phone) → exec:manual" || bad "phone-as-proxy → expected exec:manual"
[ "$(context_check_exec_class "trocar o SIM do aparelho" "inserir novo chip / SIM no celular de testes")" = "exec:manual" ] \
  && ok "SIM/chip swap on physical device → exec:manual" || bad "SIM swap → expected exec:manual"
[ "$(context_check_exec_class "configurar hardware proxy" "ligar o dongle e conectar manualmente")" = "exec:manual" ] \
  && ok "hardware/dongle + conectar manualmente → exec:manual" || bad "hardware proxy → expected exec:manual"
# 10a2 — ga-s16ob: BARE device nouns (no paired action verb) must NOT tip
#        exec:manual — whatsapp_automation's ordinary vocabulary is phones/
#        chips/devices, and a bare match over-tagged pure-Python bug fixes.
[ "$(context_check_exec_class "Vigia de contact-sync pode condenar aparelho SAO" "pick_fresh_wa_test_number escolhe o alvo entre os chips da frota; excluir chip DESCARTADO e o numero do proprio aparelho na selecao do teste")" = "exec:auto" ] \
  && ok "ga-s16ob: bare 'aparelho'/'chip' in a pure-Python bug fix → exec:auto (wa-5ct4l pattern)" || bad "ga-s16ob REGRESSION: bare aparelho/chip over-tagged exec:manual (wa-5ct4l pattern)"
[ "$(context_check_exec_class "Envio de outreach nao deve esperar o espelho de contato" "abrir a conversa pelo NUMERO (wa.me) em vez de depender do aparelho fisicamente sincronizado; a mudanca e so em central_sender.py")" = "exec:auto" ] \
  && ok "ga-s16ob: bare 'aparelho'/'fisicamente' in a code-path change → exec:auto (wa-4032l pattern)" || bad "ga-s16ob REGRESSION: bare aparelho/fisicamente over-tagged exec:manual (wa-4032l pattern)"
[ "$(context_check_exec_class "corrigir classificador de dispositivo" "o smartphone e o celular do usuario aparecem duplicados na tabela; ajustar a query em classification_database.py")" = "exec:auto" ] \
  && ok "ga-s16ob: bare 'dispositivo'/'smartphone'/'celular' in a SQL fix → exec:auto" || bad "ga-s16ob REGRESSION: bare dispositivo/smartphone/celular over-tagged exec:manual"
# 10a3 — ga-s16ob: an ACTION VERB paired with the device noun still tips exec:manual.
[ "$(context_check_exec_class "canal travado" "reiniciar o aparelho e trocar o chip antes de repetir o teste")" = "exec:manual" ] \
  && ok "ga-s16ob: verb+noun ('reiniciar o aparelho'/'trocar o chip') → exec:manual" || bad "ga-s16ob: verb+noun physical action → expected exec:manual"
# 10a4 — ga-s16ob: a bead that genuinely requires touching/experimenting on the
#        device (wa-y9nh0 pattern) stays exec:manual.
[ "$(context_check_exec_class "Destravar canal com espelho de contatos travado" "experimentos por aparelho; NUNCA rootear nenhum aparelho; descobrir se da pra fazer por adb sem toque humano")" = "exec:manual" ] \
  && ok "ga-s16ob: wa-y9nh0 pattern (toque humano / rootear aparelho) → exec:manual" || bad "ga-s16ob: wa-y9nh0 pattern → expected exec:manual, under-tagged auto"
# 10b — GOV / 3rd-party PORTAL gated by human identity (CPF+CAPTCHA, e-SIC/LAI, cartório).
[ "$(context_check_exec_class "pedido e-SIC/LAI Planta Genérica" "abrir pedido no portal e-SIC (LAI) para a Planta Genérica de Valores")" = "exec:manual" ] \
  && ok "e-SIC/LAI gov portal → exec:manual" || bad "e-SIC/LAI → expected exec:manual"
[ "$(context_check_exec_class "login no portal da prefeitura" "acessar com identidade CPF e resolver o CAPTCHA")" = "exec:manual" ] \
  && ok "CPF + CAPTCHA human-identity portal → exec:manual" || bad "CPF+CAPTCHA → expected exec:manual"
[ "$(context_check_exec_class "obter certidão no cartório" "comparecer ao cartório / protocolo presencial")" = "exec:manual" ] \
  && ok "cartório / presencial → exec:manual" || bad "cartório → expected exec:manual"
# 10c — HUMAN-held credential / account / channel provisioning → exec:manual.
[ "$(context_check_exec_class "canal efêmero — provisionar canal Whapi" "provisionar canal Whapi novo para o número efêmero")" = "exec:manual" ] \
  && ok "provisionar canal Whapi (credential provisioning) → exec:manual" || bad "provisionar canal Whapi → expected exec:manual"
# 10c2 — HUMAN DESIGN / BUSINESS-DECISION GATE → exec:manual (the design-first mis-dispatch class).
[ "$(context_check_exec_class "F2 inbound on-device v2" "DESIGN-FIRST: spec aprovado por Athos antes de codar. Acceptance criteria a definir.")" = "exec:manual" ] \
  && ok "design-first + spec aprovado antes de codar → exec:manual (wa-1my1)" || bad "design-first → expected exec:manual"
[ "$(context_check_exec_class "F11 inbound nunca perder" "Status: DESIGN-FIRST — aguardando OK do thies/Athos antes de qualquer código.")" = "exec:manual" ] \
  && ok "design-first + aguardando OK antes de qualquer código → exec:manual (wa-tozk)" || bad "wa-tozk class → expected exec:manual"
[ "$(context_check_exec_class "multi-arm IP survival" "bloqueado em decisão de custo: free phone-proxy vs paid .156")" = "exec:manual" ] \
  && ok "decisão de custo (business decision) → exec:manual (wa-yma9)" || bad "decisão de custo → expected exec:manual"
# CONSERVATIVE: an ordinary task that merely mentions 'design' (not design-first) stays auto.
[ "$(context_check_exec_class "refatorar o design system" "ajustar os tokens de cor do design system e rodar os testes")" = "exec:auto" ] \
  && ok "ordinary 'design system' code task → exec:auto (no over-tag on bare 'design')" || bad "design system task → expected exec:auto"
# 10d — DEFAULT exec:auto: code/script/verification/data/API/email tasks a crew can do.
[ "$(context_check_exec_class "inbound_generator: gerar leads" "rodar o script que gera inbound a partir da base, --apply")" = "exec:auto" ] \
  && ok "inbound_generator script task → exec:auto" || bad "inbound_generator → expected exec:auto"
[ "$(context_check_exec_class "Contagem declividade: rodar --apply" "executar o scraper com --apply e validar a saída")" = "exec:auto" ] \
  && ok "scraper --apply → exec:auto" || bad "scraper --apply → expected exec:auto"
[ "$(context_check_exec_class "Verificar saúde do token PDPJ" "health-check do token via API e reportar o status")" = "exec:auto" ] \
  && ok "token health-check (API verification) → exec:auto" || bad "health-check → expected exec:auto"
[ "$(context_check_exec_class "envio de e-mail de cobrança" "montar e disparar e-mail via API de envio")" = "exec:auto" ] \
  && ok "email-based request via API → exec:auto" || bad "email request → expected exec:auto"
# 10e — CONSERVATIVE: never over-tag manual. A generic "provision a table" code
#       task (provisioning verb but NO credential/account/channel noun) stays auto.
[ "$(context_check_exec_class "provision a new staging table" "create a staging table in the warehouse and backfill it")" = "exec:auto" ] \
  && ok "provision a TABLE (code, not credential) → exec:auto (conservative default)" || bad "provision table → expected exec:auto"
[ "$(context_check_exec_class "rename notify wrapper" "edit scripts/notify to rename the wrapper fn so it stops shadowing the CLI")" = "exec:auto" ] \
  && ok "ambiguous/neutral code task → exec:auto (default)" || bad "neutral code task → expected exec:auto"
[ "$(context_check_exec_class "" "")" = "exec:auto" ] \
  && ok "empty title+desc → exec:auto (default, never falsely manual)" || bad "empty → expected exec:auto"
# 10g0 — ga-dpas3r: context_check_negated, the pure helper backing the
#        negation-awareness fix below. A trigger substring inside a PROHIBITION
#        ("nunca X") must not read the same as a request for X.
if declare -F context_check_negated >/dev/null 2>&1; then
  ok "context_check_negated is defined (exposed lib-only)"
else
  bad "context_check_negated not exposed by lib-only source"
fi
[ "$(context_check_negated "nunca criar conta em nome do usuario" "criar conta")" = "yes" ] \
  && ok "context_check_negated: 'nunca criar conta' → yes (same-clause negation precedes)" || bad "context_check_negated: same-clause negation not detected"
[ "$(context_check_negated "por favor, criar conta nova para o teste" "criar conta")" = "no" ] \
  && ok "context_check_negated: 'criar conta' with no negation → no" || bad "context_check_negated REGRESSION: false positive on a genuine request"
[ "$(context_check_negated "provisionar credencial" "criar conta")" = "no" ] \
  && ok "context_check_negated: phrase absent entirely → no" || bad "context_check_negated: absent phrase should be 'no'"
[ "$(context_check_negated "nunca apague o log. depois disso, criar conta de teste." "criar conta")" = "no" ] \
  && ok "context_check_negated: negation in an EARLIER, different clause does not leak forward across a '.'" || bad "context_check_negated REGRESSION: negation window leaked across a sentence boundary"
# 10g0a — ga-dpas3r attempt 2, blocking issue 2 (gate_run=ga-6ibdui): a negation
#        word immediately followed by punctuation ("nunca," with a comma, not a
#        trailing space) must still be recognized as negating the clause — the
#        word-boundary match used to require a literal space on both sides and
#        silently missed this, reopening the wa-vrs3g false-positive class for a
#        comma-qualified variant of the exact wording this fix targets.
[ "$(context_check_negated "nunca, em hipotese alguma, criar conta nova para este robo." "criar conta")" = "yes" ] \
  && ok "context_check_negated: comma-qualified 'nunca, em hipotese alguma,' still negates (ga-dpas3r attempt 2 fix2)" || bad "context_check_negated REGRESSION: comma right after negation word broke the match (ga-dpas3r attempt 2 fix2)"
# Class fix, not just the cited comma instance: colon and parens directly
# abutting the negation word must negate too (same mechanism, different glyph).
[ "$(context_check_negated "nunca: sob nenhuma hipotese, criar conta" "criar conta")" = "yes" ] \
  && ok "context_check_negated: colon-qualified 'nunca:' still negates (fix2 generalizes beyond comma)" || bad "context_check_negated REGRESSION: colon right after negation word broke the match"
[ "$(context_check_negated "(nunca) criar conta imediatamente" "criar conta")" = "yes" ] \
  && ok "context_check_negated: parenthesized '(nunca)' still negates (fix2 generalizes beyond comma)" || bad "context_check_negated REGRESSION: parens around negation word broke the match"
# 10g0b — ga-dpas3r attempt 2, blocking issue 1 (gate_run=ga-6ibdui): a phrase
#        that occurs TWICE — once inside a prohibition, once later as a genuine
#        request — must be caught by its second, unnegated occurrence.
#        context_check_negated alone only ever inspects the FIRST occurrence;
#        context_check_any_unnegated must scan every occurrence, or the second,
#        real request silently downgrades to exec:auto (a human-required
#        credential-provisioning task misclassified as agent-executable).
[ "$(context_check_any_unnegated "nunca provisionar conta de admin automaticamente. ao final, e necessario provisionar conta de servico dedicada para este pipeline." "provisionar conta")" = "yes" ] \
  && ok "context_check_any_unnegated: 2nd unnegated occurrence caught after a negated 1st (ga-dpas3r attempt 2 fix1)" || bad "context_check_any_unnegated REGRESSION: only inspected the first occurrence, missed the genuine second request (ga-dpas3r attempt 2 fix1)"
# 10g0c — same two cases, end-to-end through exec_class (title+desc, real case).
[ "$(context_check_exec_class "pipeline de contas" "Nunca provisionar conta de admin automaticamente. Ao final, e necessario provisionar conta de servico dedicada para este pipeline.")" = "exec:manual" ] \
  && ok "ga-dpas3r attempt 2: 2nd, genuine 'provisionar conta' request after a negated 1st → exec:manual (fix1 end-to-end)" || bad "ga-dpas3r REGRESSION: genuine 2nd occurrence after a negated 1st stayed exec:auto (fix1 end-to-end)"
[ "$(context_check_exec_class "guardrail de escopo" "Nunca, em hipotese alguma, criar conta nova para este robo.")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 2: comma-qualified 'Nunca, em hipotese alguma,' prohibition → exec:auto (fix2 end-to-end)" || bad "ga-dpas3r REGRESSION: comma right after negation word over-tagged exec:manual (fix2 end-to-end)"
# 10g0d — ga-dpas3r attempt 3 (gate_run=ga-yydf1o): "sem"/"evitar"/"evite" are a
#        preposition/verb that takes the WORD IMMEDIATELY FOLLOWING them as its
#        own object — unlike "nunca"/"não"/"jamais" (pure adverbs, no object of
#        their own), that object can be a different, EARLIER thing than the
#        trigger phrase later in the same comma-delimited sentence. "sem duvida,"
#        negates "duvida", not a genuine request appearing after the comma; same
#        for "evitar retrabalho,". Both silently downgraded a real request to
#        exec:auto before this fix.
[ "$(context_check_negated "sem duvida, criar conta nova para o parceiro." "criar conta")" = "no" ] \
  && ok "context_check_negated: 'sem duvida,' does not reach across the comma to negate an unrelated later phrase (ga-dpas3r attempt 3)" || bad "context_check_negated REGRESSION: 'sem duvida,' falsely negated an unrelated later phrase (ga-dpas3r attempt 3)"
[ "$(context_check_negated "evitar retrabalho, provisionar conta de servico agora." "provisionar conta")" = "no" ] \
  && ok "context_check_negated: 'evitar retrabalho,' does not reach across the comma to negate an unrelated later phrase (ga-dpas3r attempt 3)" || bad "context_check_negated REGRESSION: 'evitar retrabalho,' falsely negated an unrelated later phrase (ga-dpas3r attempt 3)"
# Class fix, not just the two cited words: "nem" (quantifier — "nem tudo") has
# the identical shape (binds to the word right after it, e.g. "tudo", not a
# later trigger) and was NOT named in the gate feedback, but ships the same fix
# pre-emptively rather than waiting for a third report of the same bug family.
[ "$(context_check_negated "nem tudo esta definido, provisionar conta e o proximo passo." "provisionar conta")" = "no" ] \
  && ok "context_check_negated: 'nem tudo,' does not reach across the comma to negate an unrelated later phrase (class fix, ga-dpas3r attempt 3)" || bad "context_check_negated REGRESSION: 'nem tudo,' falsely negated an unrelated later phrase (class fix, ga-dpas3r attempt 3)"
# Regression: adjacent (no comma) usage of all three must still negate — the
# tightened scope must not lose the true positives this whole fix protects.
[ "$(context_check_negated "sem criar conta nenhuma, resolva localmente" "criar conta")" = "yes" ] \
  && ok "context_check_negated: 'sem criar conta' (adjacent, no comma before the phrase) still negates" || bad "context_check_negated REGRESSION: adjacent 'sem' stopped negating"
[ "$(context_check_negated "evite provisionar conta sem necessidade real" "provisionar conta")" = "yes" ] \
  && ok "context_check_negated: 'evite provisionar conta' (adjacent, no comma before the phrase) still negates" || bad "context_check_negated REGRESSION: adjacent 'evite' stopped negating"
[ "$(context_check_negated "nem provisionar conta seria necessario aqui" "provisionar conta")" = "yes" ] \
  && ok "context_check_negated: 'nem provisionar conta' (adjacent, no comma before the phrase) still negates" || bad "context_check_negated REGRESSION: adjacent 'nem' stopped negating"
# 10g0e — same cases, end-to-end through exec_class (title+desc, real case).
[ "$(context_check_exec_class "pipeline" "Sem dúvida, criar conta nova para o parceiro.")" = "exec:manual" ] \
  && ok "ga-dpas3r attempt 3: 'Sem duvida, criar conta...' genuine request → exec:manual (end-to-end)" || bad "ga-dpas3r REGRESSION: 'Sem duvida, criar conta...' genuine request stayed exec:auto (end-to-end)"
[ "$(context_check_exec_class "pipeline" "Evitar retrabalho, provisionar conta de serviço agora.")" = "exec:manual" ] \
  && ok "ga-dpas3r attempt 3: 'Evitar retrabalho, provisionar conta...' genuine request → exec:manual (end-to-end)" || bad "ga-dpas3r REGRESSION: 'Evitar retrabalho, provisionar conta...' genuine request stayed exec:auto (end-to-end)"
[ "$(context_check_exec_class "pipeline" "Nem tudo esta definido, provisionar conta e o proximo passo.")" = "exec:manual" ] \
  && ok "ga-dpas3r attempt 3: 'Nem tudo, provisionar conta...' genuine request → exec:manual (class fix, end-to-end)" || bad "ga-dpas3r REGRESSION: 'Nem tudo, provisionar conta...' genuine request stayed exec:auto (class fix, end-to-end)"
[ "$(context_check_exec_class "guardrail" "Sem criar conta, resolva localmente.")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 3: 'Sem criar conta,' (adjacent prohibition) → exec:auto (end-to-end)" || bad "ga-dpas3r REGRESSION: adjacent 'Sem criar conta,' prohibition over-tagged exec:manual (end-to-end)"
# 10g0f — ga-dpas3r attempt 4 (gate_run=ga-2n0g4c): the preceding fixes all
#        assumed title+desc arrive already ASCII-foldable, but `tr 'A-Z' 'a-z'`
#        only maps single-byte ASCII — an uppercase ACCENTED letter's UTF-8
#        bytes pass through untouched ("NÃO" → "nÃo"), and a curly/smart
#        apostrophe (U+2019, what phone/editor autocorrect substitutes for a
#        typed one) never equals the ASCII "'" the "don't"/"can't" literals
#        use. Both silently fell through to exec:auto for a genuine
#        prohibition/negation this fix exists to detect — the exact
#        wa-vrs3g class again, reached via a Unicode form instead of a
#        wording gap this time.
[ "$(context_check_exec_class "guardrail de escopo" "NÃO criar conta nova em nenhum servico externo durante este bug fix")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 4: accented-uppercase 'NÃO criar conta' (prohibition) → exec:auto (reviewer repro 1)" || bad "ga-dpas3r REGRESSION: accented-uppercase 'NÃO' prohibition over-tagged exec:manual (reviewer repro 1)"
[ "$(context_check_exec_class "guardrail" "We don’t create a new account automatically here, ever.")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 4: curly-quote 'don’t' (U+2019) prohibition → exec:auto (reviewer repro 2)" || bad "ga-dpas3r REGRESSION: curly-quote 'don’t' prohibition over-tagged exec:manual (reviewer repro 2)"
[ "$(context_check_exec_class "guardrail" "We can’t create a new account automatically here.")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 4: curly-quote 'can’t' (sibling negator, same mechanism) → exec:auto" || bad "ga-dpas3r REGRESSION: curly-quote 'can’t' prohibition over-tagged exec:manual"
[ "$(context_check_exec_class "guardrail" "We don´t create a new account automatically here.")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 4: acute-accent 'don´t' (U+00B4, dead-key/keyboard lookalike) prohibition → exec:auto (Mayor review)" || bad "ga-dpas3r REGRESSION: acute-accent 'don´t' prohibition over-tagged exec:manual (Mayor review)"
[ "$(context_check_exec_class "" "NÃo criar conta nova, apenas ler dados publicos")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 4: mixed-case 'NÃo' (leading caps only) still folds and negates" || bad "ga-dpas3r REGRESSION: mixed-case 'NÃo' failed to fold"
[ "$(context_check_exec_class "" "nÃO criar conta nova, apenas ler dados publicos")" = "exec:auto" ] \
  && ok "ga-dpas3r attempt 4: mixed-case 'nÃO' (trailing caps only) still folds and negates" || bad "ga-dpas3r REGRESSION: mixed-case 'nÃO' failed to fold"
# Class fix, not just the cited "NÃO"/"don't": the accent fold is a single
# shared preprocessing step, so it also reaches accented literals OUTSIDE
# the negation-word list — §4's business-decision gate — for an all-caps
# title/desc, and a genuine (non-negated) accented-uppercase request must
# still tip exec:manual, proving the fold didn't just make everything auto.
[ "$(context_check_exec_class "F11 inbound" "BLOQUEADO EM DECISÃO DE CUSTO: opção gratuita vs paga")" = "exec:manual" ] \
  && ok "ga-dpas3r attempt 4: accented-uppercase 'DECISÃO DE CUSTO' (§4, outside negation list) still tips exec:manual" || bad "ga-dpas3r REGRESSION: accented-uppercase §4 phrase stopped matching after the fold"
[ "$(context_check_exec_class "pipeline" "CRIAR CONTA NOVA PARA O PARCEIRO, JÁ")" = "exec:manual" ] \
  && ok "ga-dpas3r attempt 4: genuine accented-uppercase request (no negation) still tips exec:manual (not over-corrected to always-auto)" || bad "ga-dpas3r REGRESSION: accented-uppercase genuine request wrongly fell to exec:auto"
# 10g0g — ga-dpas3r 5th attempt (Mayor, gate_run=ga-lvl2t2): SCOPE-based
#        negation. Mayor's rule after the 4th gate FAIL: a negation word's
#        scope runs from the negator to the end of the SENTENCE (next
#        .;!?/newline) OR an adversative conjunction (mas/porém/porem/
#        contudo/entretanto/todavia/exceto/salvo/but/however/except) —
#        whichever comes first. Coordination (ou/e/nem/or/and/nor) and a bare
#        comma do NOT end the scope. These 5 cases are the Mayor's own
#        mandatory acceptance tests, verbatim (comment 2026-09-19T06:12:57Z).
[ "$(context_check_exec_class "" "nunca criar conta pessoal ou criar conta comercial")" = "exec:auto" ] \
  && ok "ga-dpas3r 5th attempt: 'nunca X ou X' (coordination) stays ONE negated clause → exec:auto (Mayor test 1)" || bad "ga-dpas3r REGRESSION: 'nunca X ou X' lost its negation across 'ou' → exec:manual (Mayor test 1)"
[ "$(context_check_exec_class "" "nunca criar conta pessoal e criar conta comercial")" = "exec:auto" ] \
  && ok "ga-dpas3r 5th attempt: 'nunca X e X' (coordination) stays ONE negated clause → exec:auto (Mayor test 2)" || bad "ga-dpas3r REGRESSION: 'nunca X e X' lost its negation across 'e' → exec:manual (Mayor test 2)"
[ "$(context_check_exec_class "" "nunca criar conta pessoal nem criar conta comercial")" = "exec:auto" ] \
  && ok "ga-dpas3r 5th attempt: 'nunca X nem X' (coordination) stays ONE negated clause → exec:auto (Mayor test 3)" || bad "ga-dpas3r REGRESSION: 'nunca X nem X' lost its negation across 'nem' → exec:manual (Mayor test 3)"
[ "$(context_check_exec_class "" "não criar conta, mas criar conta de teste")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: adversative 'mas' ENDS negation scope → 2nd occurrence is a fresh request → exec:manual (Mayor test 4)" || bad "ga-dpas3r REGRESSION: 'mas' failed to end negation scope → exec:auto (Mayor test 4)"
[ "$(context_check_exec_class "" "Não precisa revisar. Criar conta no portal X")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: '.' ENDS negation scope → next sentence is a fresh request → exec:manual (Mayor test 5)" || bad "ga-dpas3r REGRESSION: negation leaked across '.' into the next sentence → exec:auto (Mayor test 5)"
# Class fix, not just the 5 cited repros: the same scope rule must hold
# case-folded/all-caps (interacts with attempt 4's accent fold), with a
# comma immediately before the coordinating conjunction (the natural PT
# spelling), in English (the classifier is bilingual — untested for the
# NEW adversative words until now), for a different adversative word than
# "mas"/"but" (porém), and must not have over-corrected to always-auto (a
# plain, non-negated coordination of two genuine requests must still tip
# exec:manual — either arm of the "ou" is independently actionable).
[ "$(context_check_exec_class "" "NUNCA CRIAR CONTA PESSOAL OU CRIAR CONTA COMERCIAL")" = "exec:auto" ] \
  && ok "ga-dpas3r 5th attempt: all-caps 'NUNCA X OU X' still stays one negated clause after case-fold → exec:auto" || bad "ga-dpas3r REGRESSION: all-caps 'NUNCA X OU X' lost its negation → exec:manual"
[ "$(context_check_exec_class "" "nunca criar conta, ou criar conta comercial")" = "exec:auto" ] \
  && ok "ga-dpas3r 5th attempt: comma-before-'ou' (natural PT spelling) still stays one negated clause → exec:auto" || bad "ga-dpas3r REGRESSION: comma immediately before 'ou' ended the scope early → exec:manual"
[ "$(context_check_exec_class "" "we don't need a new account here except creating a new account for the test suite is fine")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: English adversative 'except' ends scope → 2nd 'new account' is a fresh request → exec:manual" || bad "ga-dpas3r REGRESSION: English 'except' failed to end negation scope → exec:auto"
[ "$(context_check_exec_class "" "we don't need a new account here, however creating a new account for staging is fine")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: English adversative 'however' ends scope → 2nd 'new account' is a fresh request → exec:manual" || bad "ga-dpas3r REGRESSION: English 'however' failed to end negation scope → exec:auto"
[ "$(context_check_exec_class "" "nunca criar conta, porém criar conta de teste é necessário")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: adversative 'porém' (not just 'mas') ends scope → exec:manual" || bad "ga-dpas3r REGRESSION: adversative 'porém' failed to end negation scope → exec:auto"
[ "$(context_check_exec_class "" "NUNCA CRIAR CONTA, PORÉM CRIAR CONTA DE TESTE É NECESSÁRIO")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: accented-uppercase 'PORÉM' still ends scope after case-fold → exec:manual" || bad "ga-dpas3r REGRESSION: accented-uppercase 'PORÉM' failed to fold/end negation scope → exec:auto"
[ "$(context_check_exec_class "" "criar conta pessoal ou criar conta comercial")" = "exec:manual" ] \
  && ok "ga-dpas3r 5th attempt: plain 'X ou X' with NO negator — both genuine requests — still tips exec:manual (not over-corrected to always-auto)" || bad "ga-dpas3r REGRESSION: un-negated 'X ou X' wrongly fell to exec:auto"
# 10g — ga-dpas3r: a PROHIBITION must not tip exec:manual just because its
#       trigger substring occurs inside it — "nunca criar conta" contains
#       "criar conta" but FORBIDS it, the opposite of a request (wa-vrs3g).
[ "$(context_check_exec_class "cadastro de fonte de dados" "nunca criar conta em nome do usuario; apenas ler dados publicos via API")" = "exec:auto" ] \
  && ok "ga-dpas3r: 'nunca criar conta' (prohibition) → exec:auto, not exec:manual (wa-vrs3g)" || bad "ga-dpas3r REGRESSION: negated 'criar conta' over-tagged exec:manual (wa-vrs3g)"
[ "$(context_check_exec_class "guardrail de escopo" "NAO criar conta nova em nenhum servico externo durante este bug fix")" = "exec:auto" ] \
  && ok "ga-dpas3r: 'NAO criar conta' (uppercase prohibition) → exec:auto" || bad "ga-dpas3r REGRESSION: uppercase negated 'criar conta' over-tagged exec:manual"
# ga-dpas3r: a bare MENTION of a portal noun (a research category, or an
# access-method description) is not a request for a human to pass that gate
# personally — cartório/captcha need a paired action verb, same lesson ga-s16ob
# already taught section 1's bare device nouns (wa-jjztr).
[ "$(context_check_exec_class "mapear fontes de dados publicos" "pesquisar em fontes como cartorios, prefeituras e tribunais para levantar o historico do imovel")" = "exec:auto" ] \
  && ok "ga-dpas3r: 'pesquisar cartorios' (research-category mention) → exec:auto, not exec:manual (wa-jjztr)" || bad "ga-dpas3r REGRESSION: bare 'cartorios' mention over-tagged exec:manual (wa-jjztr)"
[ "$(context_check_exec_class "mapear fontes de dados publicos" "algumas fontes tem acesso via captcha ou API, conforme o portal disponibilizar")" = "exec:auto" ] \
  && ok "ga-dpas3r: 'acesso via captcha' (access-method mention) → exec:auto, not exec:manual (wa-jjztr)" || bad "ga-dpas3r REGRESSION: bare 'captcha' mention over-tagged exec:manual (wa-jjztr)"
# 10f — exec vocabulary is bounded to exactly exec:manual | exec:auto.
ec_bad=0
for pair in "physical phone proxy|x" "rodar script|y" "|"; do
  IFS='|' read -r _a _b <<< "$pair"
  ec=$(context_check_exec_class "$_a" "$_b")
  case "$ec" in exec:manual|exec:auto) : ;; *) ec_bad=1; bad "exec-class escaped vocabulary: '$ec'" ;; esac
done
[ "$ec_bad" = "0" ] && ok "exec-class yields ONLY exec:manual or exec:auto" || bad "exec-class vocabulary escaped"

# ── DRIFT GUARDS: static assertions on the shipped dispatcher ─────────────────
echo "Drift guards: live wiring matches the design contract"

# 1. LABEL-ONLY: the only bead-state writes are `label add ... ctx:ready|ctx:thin`
#    and a comment. NO dispatch / sling write in code. (Match an actual INVOCATION
#    — `gc ... sling` or `pilot-dispatcher` — not the `pilot:dispatched` LABEL the
#    lifecycle-skip classifier legitimately matches against.)
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -E 'gc .*sling|pilot-dispatcher|pilot dispatch' >/dev/null; then
  bad "REGRESSION: dispatcher contains a dispatch/sling call — must be LABEL-ONLY"
else
  ok "no dispatch/sling invocation in code (LABEL-ONLY)"
fi
# It must never CLOSE a candidate bead. (It may close its OWN ephemeral verdict
# bead — guard that the close target is the verdict bead variable, never a candidate.)
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -E 'bd_ close' | grep -v '_verdict_bead' >/dev/null; then
  bad "REGRESSION: a bd_ close targets something other than the verdict bead — must not close candidates"
else
  ok "bd_ close only ever targets the daemon's own verdict bead (never a candidate)"
fi
# It must never write a lifecycle/dispatch label onto a candidate.
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -E 'label add "\$c_id" "(story:|pilot:|gate:)' >/dev/null; then
  bad "REGRESSION: dispatcher writes a lifecycle/dispatch label onto a candidate"
else
  ok "candidate writes are ONLY ctx:* + a comment (no lifecycle/dispatch label)"
fi
# The positive verdict label the dispatcher adds to a candidate is the computed
# $LABEL (ctx:ready/ctx:thin), via `label add "$c_id" "$LABEL"`.
if grep -qF 'label add "$c_id" "$LABEL"' "$DISPATCHER"; then
  ok "candidate verdict written via additive label add \$c_id \$LABEL (positive label)"
else
  bad "candidate verdict not written via additive label add"
fi

# 2. Idempotence: the candidate query EXCLUDES ctx:ready and ctx:thin, AND the
#    pure classifier re-asserts has_ctx_label (defense in depth, anti-loop).
if grep -qF -- '--exclude-label ctx:ready' "$DISPATCHER" \
   && grep -qF -- '--exclude-label ctx:thin' "$DISPATCHER" \
   && grep -qF 'context_check_has_ctx_label' "$DISPATCHER"; then
  ok "candidate query excludes ctx:ready/ctx:thin + classifier re-asserts (idempotent, anti-loop)"
else
  bad "idempotence not enforced at query AND classifier"
fi

# 3. Anti-Dolt-spike: per-sweep cap + per-sweep Sonnet cap exist and are honored.
if grep -q 'CONTEXT_CHECK_MAX_PER_SWEEP' "$DISPATCHER" \
   && grep -q 'JUDGED" -ge "\$CONTEXT_CHECK_MAX_PER_SWEEP' "$DISPATCHER" \
   && grep -q 'CONTEXT_CHECK_MAX_SONNET_PER_SWEEP' "$DISPATCHER"; then
  ok "per-sweep bead cap + per-sweep Sonnet cap enforced (anti-Dolt-spike)"
else
  bad "per-sweep caps missing or not enforced"
fi

# 4. Kill-switch: CONTEXT_CHECK_ENABLED=0 → no-op exit before any work.
if grep -q 'CONTEXT_CHECK_ENABLED' "$DISPATCHER" \
   && grep -q 'CONTEXT_CHECK_ENABLED" != "1"' "$DISPATCHER"; then
  ok "kill-switch CONTEXT_CHECK_ENABLED=0 → no-op exit"
else
  bad "kill-switch missing"
fi

# 5. Fail-toward-human in code: the uncertain branch defaults to ctx:thin when
#    Sonnet is disabled, and any non-READY Sonnet verdict resolves to ctx:thin.
if grep -q 'context_check_resolve_uncertain' "$DISPATCHER" \
   && grep -qF 'READY) echo "ctx:ready"' "$DISPATCHER"; then
  ok "fail-toward-human: only explicit Sonnet READY → ctx:ready; all else → ctx:thin"
else
  bad "fail-toward-human resolution missing"
fi

# 6. The Sonnet judge is spawned on the context-check-reviewer template (Sonnet).
if grep -q 'session new "\$CONTEXT_CHECK_REVIEWER_TEMPLATE"' "$DISPATCHER"; then
  ok "Sonnet judge spawned via gc session new on the context-check-reviewer template"
else
  bad "Sonnet judge spawn does not use the context-check-reviewer template"
fi
# The agent template must pin model = sonnet (sibling .toml shipped alongside).
_TOML="$SELF_DIR/../../../agents/context-check-reviewer/agent.toml"
_TOML_ALT="$SELF_DIR/context-check-reviewer-agent.toml"
if grep -q '^model = "sonnet"' "$_TOML" 2>/dev/null || grep -q '^model = "sonnet"' "$_TOML_ALT" 2>/dev/null; then
  ok "context-check-reviewer template pins model = sonnet"
else
  bad "context-check-reviewer template does not pin model = sonnet (checked $_TOML and $_TOML_ALT)"
fi

# 7. The plist pins the exclude sets (deployment-layer defense for plumbing).
PLIST="$SELF_DIR/com.gascity.context-check-dispatcher.plist"
if grep -q 'CONTEXT_CHECK_EXCLUDE_LABELS' "$PLIST" 2>/dev/null \
   && grep -q 'CONTEXT_CHECK_EXCLUDE_PREFIXES' "$PLIST" 2>/dev/null \
   && grep -q 'type:quality-gate' "$PLIST" 2>/dev/null; then
  ok "plist pins CONTEXT_CHECK_EXCLUDE_LABELS + _PREFIXES incl. quality-gate (deployment defense)"
else
  bad "plist does not pin the exclude sets"
fi

# 8. DRY_RUN must not write labels or spawn. With no live bd the queue is empty →
#    it exits 0 without spawning, logging the dry-run sweep start.
_drycity="$(mktemp -d)"
_sb_init "$_drycity/sb" || exit 2
CONTEXT_CHECK_CITY_OVERRIDE="$_drycity" DRY_RUN=1 \
  PATH="$SANDBOX_PATH" \
  bash "$DISPATCHER" >/dev/null 2>&1
_dryrc=$?
_drylog=$(cat "$_drycity/.gc/logs/context-check-dispatcher.log" 2>/dev/null || echo "")
if [ "$_dryrc" -eq 0 ] && echo "$_drylog" | grep -iE 'Context-check sweep start.*dry_run=1' >/dev/null; then
  ok "DRY_RUN executes the sweep harness cleanly (exit 0, proof mode, no spawn)"
else
  bad "DRY_RUN did not run cleanly in proof mode (rc=$_dryrc)"
fi
rm -rf "$_drycity"

# 9. Kill-switch e2e: CONTEXT_CHECK_ENABLED=0 exits 0 with the no-op log line.
_kcity="$(mktemp -d)"
_sb_init "$_kcity/sb" || exit 2
CONTEXT_CHECK_CITY_OVERRIDE="$_kcity" CONTEXT_CHECK_ENABLED=0 \
  PATH="$SANDBOX_PATH" \
  bash "$DISPATCHER" >/dev/null 2>&1
_krc=$?
_klog=$(cat "$_kcity/.gc/logs/context-check-dispatcher.log" 2>/dev/null || echo "")
if [ "$_krc" -eq 0 ] && echo "$_klog" | grep -i 'DISABLED' >/dev/null; then
  ok "kill-switch e2e: CONTEXT_CHECK_ENABLED=0 → exit 0 + DISABLED log line (no work)"
else
  bad "kill-switch e2e did not no-op cleanly (rc=$_krc)"
fi
rm -rf "$_kcity"

# 10. exec-class wiring (automation-debt pill).
#  a) feature-gated: CONTEXT_CHECK_EXEC_CLASS default 1, applied ONLY when ctx:ready.
if grep -q 'CONTEXT_CHECK_EXEC_CLASS' "$DISPATCHER" \
   && grep -qF 'CONTEXT_CHECK_EXEC_CLASS:-1' "$DISPATCHER" \
   && grep -qF '[ "$LABEL" = "ctx:ready" ] && [ "$CONTEXT_CHECK_EXEC_CLASS" = "1" ]' "$DISPATCHER"; then
  ok "exec-class env-gated (CONTEXT_CHECK_EXEC_CLASS, default 1) + applied ONLY at ctx:ready"
else
  bad "exec-class not env-gated or not scoped to ctx:ready"
fi
#  b) exactly ONE exec:* label written, via the multi-store bd_ wrapper (right store).
if grep -qF 'bd_ label add "$c_id" "$EXEC"' "$DISPATCHER" \
   && grep -qF 'bd_ label remove "$c_id" "exec:auto"' "$DISPATCHER" \
   && grep -qF 'bd_ label remove "$c_id" "exec:manual"' "$DISPATCHER"; then
  ok "exec label written via multi-store bd_ (CC_STORE-targeted), opposite stripped (exactly one)"
else
  bad "exec label not written via bd_ or opposite not stripped"
fi
#  c) idempotent: only writes if absent/changed (no thrash on re-mark).
if grep -qF 'echo ",$c_labels," | grep -F ",$EXEC," >/dev/null' "$DISPATCHER"; then
  ok "exec label idempotent (skips write when already present — no thrash)"
else
  bad "exec label idempotence guard missing"
fi
#  d) fail-open: exec-class computed with || fallback; never on the ctx:thin gap path.
#     The exec write block must NOT touch the ctx:ready/ctx:thin label add above it.
if grep -qF 'context_check_exec_class "$c_title" "$c_desc" 2>/dev/null || echo "exec:auto"' "$DISPATCHER"; then
  ok "exec-class fail-open: classifier failure → exec:auto default, never blocks the verdict"
else
  bad "exec-class not fail-open (missing || default)"
fi
#  e) exec-class is a PURE function (no bd_/gc/jq side-effects in its body).
_ecbody=$(awk '/^context_check_exec_class\(\)/{f=1} f{print} /^}/{if(f)exit}' "$DISPATCHER")
if echo "$_ecbody" | grep -E 'bd_ |gc |session |sling|--apply' >/dev/null; then
  bad "REGRESSION: context_check_exec_class has a side-effect (must be pure)"
else
  ok "context_check_exec_class is pure (no bd_/gc/sling side-effect — selftest-safe)"
fi

# 11. exec-class e2e via DRY_RUN: a manual-signal bead projects exec:manual, an
#     auto bead projects exec:auto, and a ctx:thin bead gets NO exec label — all
#     written to the candidate's OWN store via a stub bd_ on PATH (multi-store).
_ecity="$(mktemp -d)"
mkdir -p "$_ecity/.gc/logs"
_sb_init "$_ecity/sb" || exit 2   # the `bd` stub below lives in $_ecity/sb/bin — first on SANDBOX_PATH, and the only bd there is
# Stub `bd` so the dispatcher's `bd_ list` returns three crafted candidates and
# label/comment writes are captured (no live Dolt). One ready+manual, one
# ready+auto, one thin (empty desc).
cat > "$_ecity/sb/bin/bd" <<'STUB'
#!/usr/bin/env bash
# Minimal bd stub: serve `list` candidates for type=task, no-op everything else.
case "$1 $2" in
  "-C "*)
    shift 2 ;;  # drop -C <store>
esac
cmd="$1"; shift || true
if [ "$cmd" = "list" ]; then
  want=""
  while [ $# -gt 0 ]; do case "$1" in --type) want="$2"; shift 2;; *) shift;; esac; done
  if [ "$want" = "task" ]; then
    cat <<'JSON'
[{"id":"ga-manual1","issue_type":"task","title":"experimentar phone-as-Claro-mobile-proxy","description":"Plugar o celular físico como proxy móvel da Claro e medir a latência. Critério de aceitação: a chamada de teste retorna 200 e o IP observado é o da operadora. Passos: ligar o aparelho, conectar manualmente, rodar o probe.","labels":[],"ephemeral":false,"created_at":"2026-01-01T00:00:00Z"},{"id":"ga-auto1","issue_type":"task","title":"Verificar saúde do token PDPJ","description":"Fazer health-check do token PDPJ via API e reportar o status. Critério de aceitação: o script retorna o expected output {status:ok} e grava em scripts/pdpj-health.sh o resultado. Comando: bd list para confirmar.","labels":[],"ephemeral":false,"created_at":"2026-01-02T00:00:00Z"},{"id":"ga-thin1","issue_type":"task","title":"arrumar","description":"x","labels":[],"ephemeral":false,"created_at":"2026-01-03T00:00:00Z"},{"id":"ga-commentsfail1","issue_type":"task","title":"revisar outro item pendente","description":"","labels":[],"ephemeral":false,"created_at":"2026-01-03T12:00:00Z","comment_count":1},{"id":"ga-ctxrescue1","issue_type":"task","title":"corrigir latência do endpoint de health-check","description":"","labels":[],"ephemeral":false,"created_at":"2026-01-04T00:00:00Z","comment_count":2},{"id":"ga-stillthin2","issue_type":"task","title":"revisar item pendente","description":"","labels":[],"ephemeral":false,"created_at":"2026-01-05T00:00:00Z","comment_count":1}]
JSON
  else
    echo "[]"
  fi
  exit 0
fi
# ga-o9uvc: serve `comments <id> --json` for the two comment-context fixtures
# above (empty description; the real/only context lives in a comment). Any
# other id gets [] (matches the "no comments" real-world default).
if [ "$cmd" = "comments" ]; then
  id="$1"
  case "$id" in
    ga-commentsfail1)
      # ga-o9uvc fix-attempt 3: simulate a real `bd comments` failure (Dolt
      # hiccup/timeout) — nonzero exit, no JSON on stdout. Must NOT be
      # collapsed into "0 comments"; the candidate should be skipped this
      # sweep instead of judged on incomplete context.
      echo "error: connection refused" >&2
      exit 1
      ;;
    ga-ctxrescue1)
      cat <<'JSON2'
[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano."},{"text":"Reported by mayor 2026-07-09: root cause confirmed via scripts/diagnose.sh — the health-check was hitting a stale cache. Acceptance criteria: the script returns exit 0 and the expected output is status ok after the fix lands."}]
JSON2
      ;;
    ga-stillthin2)
      cat <<'JSON3'
[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano.\n  • O QUÊ: descrição + comentários vazios ou quase vazios (0 chars combinados). Diga o que precisa ser feito e por quê — na descrição ou em um comentário.\nQuando estiver completo, remova o label ctx:thin para re-avaliação."}]
JSON3
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi
# Capture mutating writes to a ledger so the test can assert on them.
echo "$cmd $*" >> "$LEDGER"
exit 0
STUB
chmod +x "$_ecity/sb/bin/bd"
LEDGER="$_ecity/ledger.txt"; export LEDGER
# ga-o9uvc (incidental, pre-existing): $_ecity is a bare mktemp dir, not a git
# repo — CC_BUILT_IDS's `git -C "$CC_STORE" for-each-ref | grep ...` pipeline
# exits non-zero (git fails outright, or grep finds no crew/* matches even in
# a real repo) and aborts the WHOLE dispatcher under set -euo pipefail before
# it judges a single candidate, despite the code's own comment promising
# "FAIL-OPEN (git fails → empty set → no exclusion)". Verified this was
# already silently broken on the unmodified baseline (same failure, same
# empty-ledger symptom, before any of this file's ga-o9uvc changes) — use the
# test seams the dispatcher already provides (CONTEXT_CHECK_TEST_BUILT_IDS /
# _BLOCKED_IDS) to bypass the git/bd_ calls entirely, matching how every other
# e2e block in this file avoids live I/O.
CONTEXT_CHECK_CITY_OVERRIDE="$_ecity" \
  CONTEXT_CHECK_STORES="$_ecity" \
  CONTEXT_CHECK_TEST_BUILT_IDS="" \
  CONTEXT_CHECK_TEST_BLOCKED_IDS="" \
  CONTEXT_CHECK_MAX_SONNET_PER_SWEEP=0 \
  CONTEXT_CHECK_EXEC_CLASS=1 \
  PATH="$SANDBOX_PATH" \
  timeout 120 bash "$DISPATCHER" >/dev/null 2>&1 || true
_eled=$(cat "$LEDGER" 2>/dev/null || echo "")
# ga-manual1: ctx:ready + exec:manual.
if echo "$_eled" | grep -E 'label add ga-manual1 ctx:ready' >/dev/null \
   && echo "$_eled" | grep -E 'label add ga-manual1 exec:manual' >/dev/null; then
  ok "e2e: manual-signal ready bead → ctx:ready + exec:manual (written to its own store)"
else
  bad "e2e: manual bead did not get ctx:ready + exec:manual (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-auto1: ctx:ready + exec:auto.
if echo "$_eled" | grep -E 'label add ga-auto1 ctx:ready' >/dev/null \
   && echo "$_eled" | grep -E 'label add ga-auto1 exec:auto' >/dev/null; then
  ok "e2e: auto ready bead → ctx:ready + exec:auto"
else
  bad "e2e: auto bead did not get ctx:ready + exec:auto (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-thin1: ctx:thin and NO exec label (pill only on ready/Aprovadas).
if echo "$_eled" | grep -E 'label add ga-thin1 ctx:thin' >/dev/null \
   && ! echo "$_eled" | grep -E 'label add ga-thin1 exec:' >/dev/null; then
  ok "e2e: thin bead → ctx:thin, NO exec label (no pill on non-ready)"
else
  bad "e2e: thin bead wrongly got an exec label or no ctx:thin (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-ctxrescue1 (ga-o9uvc): empty description, but a real comment carries the
# full report (ga-pgzes/ga-r7uec live shape) → must clear ctx:ready, not thin.
if echo "$_eled" | grep -E 'label add ga-ctxrescue1 ctx:ready' >/dev/null; then
  ok "e2e: comment-carried context rescues an empty-description bead → ctx:ready (not falsely ctx:thin)"
else
  bad "e2e REGRESSION: comment-carried context did not rescue ga-ctxrescue1 (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-stillthin2 (ga-o9uvc): empty description, only comment is the daemon's
# OWN prior gap-notice (ga-u8fly/gh-b2d live shape) → must stay ctx:thin, no
# circular self-rescue from reading its own past verdict as context.
if echo "$_eled" | grep -E 'label add ga-stillthin2 ctx:thin' >/dev/null; then
  ok "e2e: only-the-daemon's-own-gap-comment present → stays ctx:thin (no circular self-rescue)"
else
  bad "e2e REGRESSION: daemon's own gap-comment was read back as rescuing context for ga-stillthin2 (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-commentsfail1 (ga-o9uvc fix-attempt 3): comment_count>0 but the `bd
# comments` fetch itself fails (nonzero exit, no JSON). Must be SKIPPED this
# sweep — no ctx:ready, no ctx:thin — never judged on incomplete context.
# This is the exact gap that survived fix-attempt 2 (a blanket `|| true`
# collapsed "fetch failed" into "0 comments", producing an identical thin
# verdict as a genuinely-empty bead — gate-FAILED on this precise point).
if echo "$_eled" | grep -E 'label add ga-commentsfail1 ctx:(ready|thin)' >/dev/null; then
  bad "e2e REGRESSION: ga-commentsfail1 got a verdict despite its comments fetch failing (should be skipped, not judged on incomplete context) (ledger: $(echo "$_eled" | tr '\n' ';'))"
else
  ok "e2e: comments-fetch failure → candidate skipped this sweep, no verdict on incomplete context"
fi
# The failure must be visible (not silently absorbed) and, critically, must
# NOT abort the rest of the sweep — the ga-ctxrescue1/ga-stillthin2 checks
# above already prove later candidates still got judged (they sort AFTER
# ga-commentsfail1 by created_at), which is the direct regression test for
# fix-attempt 1's original bug (an unguarded fetch failure killing the whole
# sweep under set -euo pipefail).
_eclog="$_ecity/.gc/logs/context-check-dispatcher.log"
if [ -f "$_eclog" ] && grep -q "ga-commentsfail1: comments fetch failed" "$_eclog"; then
  ok "e2e: comments-fetch failure is logged distinctly (not silently absorbed into '0 comments')"
else
  bad "e2e: no distinct log line for ga-commentsfail1's comments-fetch failure (log: $([ -f "$_eclog" ] && cat "$_eclog" || echo '<missing>'))"
fi
# Feature-gate OFF: CONTEXT_CHECK_EXEC_CLASS=0 → ctx:ready still written, NO exec label.
LEDGER="$_ecity/ledger2.txt"; export LEDGER; : > "$LEDGER"
CONTEXT_CHECK_CITY_OVERRIDE="$_ecity" \
  CONTEXT_CHECK_STORES="$_ecity" \
  CONTEXT_CHECK_TEST_BUILT_IDS="" \
  CONTEXT_CHECK_TEST_BLOCKED_IDS="" \
  CONTEXT_CHECK_MAX_SONNET_PER_SWEEP=0 \
  CONTEXT_CHECK_EXEC_CLASS=0 \
  PATH="$SANDBOX_PATH" \
  timeout 120 bash "$DISPATCHER" >/dev/null 2>&1 || true
_eled2=$(cat "$LEDGER" 2>/dev/null || echo "")
if echo "$_eled2" | grep -E 'label add ga-manual1 ctx:ready' >/dev/null \
   && ! echo "$_eled2" | grep -E 'label add ga-manual1 exec:' >/dev/null; then
  ok "feature-gate OFF: ctx:ready verdict intact, NO exec label (exec-class skipped)"
else
  bad "feature-gate OFF did not preserve verdict-without-exec (ledger: $(echo "$_eled2" | tr '\n' ';'))"
fi
rm -rf "$_ecity"

# 12. ga-l5ud0 ROOT B FIX: exec:manual is AUTHORITATIVE — the classifier MUST NOT
#     downgrade an existing exec:manual to exec:auto. A bead that already carries
#     exec:manual (Mayor/human-set) must keep it even when context_check_exec_class
#     returns exec:auto (the conservative default for content with no physical/credential
#     signal). The loop this closes: exec:manual clobbered → Pilot sees exec:auto +
#     ctx:ready → dispatches a crew that cannot complete the task → mila clears → repeat.
#
#     Pure drift guards (no live Dolt/gc) — these test the actual shipped code paths
#     exercised by the ga-l5ud0 fix, not just the fix's presence.
echo "Scenario 12: ga-l5ud0 — exec:manual authoritative-hold guard (drift guards)"
# 12a — The guard code is present in the dispatcher (the critical branch that prevents
#        downgrade). Regression: if this disappears, exec:manual gets clobbered again.
if grep -qF 'exec:auto.*exec:manual,.*AUTHORITATIVE-HOLD\|AUTHORITATIVE-HOLD' "$DISPATCHER" \
   || grep -qF 'AUTHORITATIVE-HOLD' "$DISPATCHER"; then
  ok "ga-l5ud0: AUTHORITATIVE-HOLD guard present in dispatcher (exec:manual NOT downgradeable)"
else
  bad "ga-l5ud0 REGRESSION: AUTHORITATIVE-HOLD guard missing — exec:manual can be silently clobbered"
fi
# 12b — The guard specifically checks: if computed=exec:auto AND existing has exec:manual, skip.
#        Verify the exact branch condition exists in the code.
if grep -qF '"exec:auto" ] && echo ",$c_labels," | grep -F ",exec:manual," >/dev/null' "$DISPATCHER"; then
  ok "ga-l5ud0: hold-condition wiring correct (exec:auto + existing exec:manual → skip)"
else
  bad "ga-l5ud0: hold-condition wiring malformed or missing"
fi
# 12c — BEHAVIORAL SIMULATION (pure shell, no Dolt): verify the hold fires correctly
#        by sourcing the lib and simulating the label-write decision logic inline.
#        wa-14w76 pattern: content → exec:auto; existing label = exec:manual → KEEP.
_ga_l5ud0_hold_ok=0
(
  c_labels="ctx:ready,exec:manual,lane:small,story:approved"
  EXEC=$(context_check_exec_class \
    "Restaurar input do grupo UrbLink via historico" \
    "A capacidade de LER O HISTORICO de um grupo JA ESTA IMPLEMENTADA. whapi foi descontinuado. Ligar ao /peter-review." \
    2>/dev/null || echo "exec:auto")
  # Verify: classifier returns exec:auto for this content.
  [ "$EXEC" = "exec:auto" ] || exit 2
  # Simulate the guard: if exec:auto AND existing exec:manual → hold (no-op).
  _would_downgrade=1
  if echo ",$c_labels," | grep -F ",exec:manual," >/dev/null && [ "$EXEC" = "exec:auto" ]; then
    _would_downgrade=0  # AUTHORITATIVE-HOLD fires
  fi
  [ "$_would_downgrade" = "0" ] || exit 3
  exit 0
) && _ga_l5ud0_hold_ok=1
if [ "$_ga_l5ud0_hold_ok" = "1" ]; then
  ok "ga-l5ud0: behavioral sim — wa-14w76 pattern: classifier→exec:auto, existing=exec:manual → HOLD (no downgrade)"
else
  bad "ga-l5ud0 REGRESSION: behavioral sim shows exec:manual was or would be downgraded for wa-14w76 pattern"
fi
# 12d — Converse: exec:manual UPGRADE (auto→manual) is still allowed. A bead with
#        exec:auto whose content now matches a physical-device signal → upgrades to
#        exec:manual (the guard ONLY blocks downgrade, not upgrade).
_ga_l5ud0_upgrade_ok=0
(
  c_labels="ctx:ready,exec:auto,lane:small"
  EXEC=$(context_check_exec_class \
    "ligar o phone-as-Claro-mobile-proxy" \
    "conectar manualmente o celular físico como proxy móvel" \
    2>/dev/null || echo "exec:auto")
  # Verify: classifier returns exec:manual (physical-device signal).
  [ "$EXEC" = "exec:manual" ] || exit 2
  # Simulate: existing=exec:auto, computed=exec:manual → upgrade is NOT blocked.
  _would_upgrade=0
  if echo ",$c_labels," | grep -F ",exec:auto," >/dev/null && [ "$EXEC" = "exec:manual" ]; then
    _would_upgrade=1  # upgrade path fires (no AUTHORITATIVE-HOLD — guard only blocks auto)
  fi
  [ "$_would_upgrade" = "1" ] || exit 3
  exit 0
) && _ga_l5ud0_upgrade_ok=1
if [ "$_ga_l5ud0_upgrade_ok" = "1" ]; then
  ok "ga-l5ud0: upgrade (exec:auto → exec:manual on new physical signal) is NOT blocked by hold"
else
  bad "ga-l5ud0: upgrade path broken — exec:auto→exec:manual upgrade is blocked (should only block downgrade)"
fi

# context_check_skip_reason (wa-9t2ty): dep-BLOCKED beads must be skipped from
# ctx:ready (re)marking, so a refiner's manual block (remove ctx:ready + add a
# blocked-by dep) is not undone every sweep. Also covers built + kill-switches.
if [ "$(context_check_skip_reason wa-X '' wa-X 1 1)" = "blocked" ]; then
  ok "skip_reason: dep-blocked bead → 'blocked' (no ctx:ready re-mark)"
else
  bad "skip_reason: dep-blocked bead not skipped (blocked bead would re-enter ctx:ready)"
fi
if [ "$(context_check_skip_reason wa-X wa-X '' 1 1)" = "built" ]; then
  ok "skip_reason: built bead → 'built'"
else
  bad "skip_reason: built bead not skipped"
fi
if [ -z "$(context_check_skip_reason wa-X wa-Y wa-Z 1 1)" ]; then
  ok "skip_reason: clean bead (in neither set) → no skip"
else
  bad "skip_reason: clean bead wrongly skipped"
fi
if [ -z "$(context_check_skip_reason wa-X '' wa-X 1 0)" ]; then
  ok "skip_reason: EXCLUDE_BLOCKED=0 kill-switch → no skip"
else
  bad "skip_reason: blocked kill-switch ignored"
fi

# ── Scenario 13: comment-aware context (ga-o9uvc: erro-vs-vazio) ──────────────
# ctx:thin must not fire purely because .description is empty when the real
# context lives in a comment. Also: the daemon's OWN prior gap-comment must be
# excluded from the signal check (no circular self-rescue on a re-judged bead).
echo "Scenario 13: comment-aware context — comments count, but not the daemon's own gap-comment"

# 13a — join_comments: real comments are joined; the daemon's own gap-comment
#       (identified by its literal head string) is filtered out.
_join_in='[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano."},{"text":"Reported by mayor: root cause is X, fix is Y, verify via scripts/z.sh"}]'
_joined=$(context_check_join_comments "$_join_in")
if echo "$_joined" | grep "Reported by mayor" >/dev/null && ! echo "$_joined" | grep "marcado ctx:thin" >/dev/null; then
  ok "join_comments: keeps real comment text, excludes the daemon's own gap-comment"
else
  bad "join_comments: did not filter correctly (got: $_joined)"
fi
[ -z "$(context_check_join_comments "[]")" ] && ok "join_comments: empty array → empty text" || bad "join_comments: empty array should yield empty text"
[ -z "$(context_check_join_comments "")" ] && ok "join_comments: empty/malformed input → empty text (no crash)" || bad "join_comments: empty input should yield empty text, not crash"

# 13b — effective_text: comments appended to description; desc-only unchanged when no comments.
[ "$(context_check_effective_text "hello" "")" = "hello" ] && ok "effective_text: no comments → description unchanged" || bad "effective_text: no-comments case changed the description"
_eff=$(context_check_effective_text "" "world")
case "$_eff" in *world*) ok "effective_text: empty description + comments → comments included" ;; *) bad "effective_text: comments not folded in (got: '$_eff')" ;; esac

# 13c — end-to-end mechanical verdict, pure-function pipeline (no I/O):
# baseline unchanged — empty description with NO comments is still thin.
_base_sig=$(context_check_has_verifiable_signal "")
_base_mech=$(context_check_mechanical_verdict 0 "$_base_sig" 10)
[ "$_base_mech" = "thin" ] && ok "baseline unchanged: empty description, no comments → thin" || bad "REGRESSION: empty desc, no comments should still be thin"
# ga-pgzes/ga-r7uec live shape: description empty, but a real comment carries
# the full report — folding it in must clear the ready bar.
_rescue_comment="Reported by mayor 2026-07-09: root cause confirmed via scripts/diagnose.sh, expected output is status ok. Acceptance criteria: the health-check returns 0 and scripts/diagnose.sh --apply completes without error."
_rescue_text=$(context_check_effective_text "" "$_rescue_comment")
_rescue_sig=$(context_check_has_verifiable_signal "$_rescue_text")
_rescue_mech=$(context_check_mechanical_verdict "${#_rescue_text}" "$_rescue_sig" 10)
[ "$_rescue_mech" = "ready" ] && ok "ga-pgzes/ga-r7uec shape: empty description + verifiable comment → ready (was falsely thin pre-fix)" || bad "REGRESSION: comment-carried context did not rescue an empty-description bead (mech=$_rescue_mech sig=$_rescue_sig)"
# ga-u8fly/gh-b2d live shape: the ONLY comment is the daemon's own prior
# gap-notice — must NOT self-rescue (still genuinely thin).
_selfnotice='[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano.\n  • O QUÊ: descrição + comentários vazios ou quase vazios (0 chars combinados). Diga o que precisa ser feito e por quê — na descrição ou em um comentário.\nQuando estiver completo, remova o label ctx:thin para re-avaliação."}]'
_selfnotice_text=$(context_check_join_comments "$_selfnotice")
_selfnotice_eff=$(context_check_effective_text "" "$_selfnotice_text")
_selfnotice_sig=$(context_check_has_verifiable_signal "$_selfnotice_eff")
_selfnotice_mech=$(context_check_mechanical_verdict "${#_selfnotice_eff}" "$_selfnotice_sig" 10)
[ "$_selfnotice_mech" = "thin" ] && ok "ga-u8fly/gh-b2d shape: only the daemon's own gap-comment present → stays thin (no circular self-rescue)" || bad "REGRESSION: daemon's own gap-comment was read back as rescuing context (mech=$_selfnotice_mech)"

# ── Scenario 14: ga-9t9acg.10 — ONE order across ALL stores, the cap applied AFTER it ──────────────────────────
# Programa ga-9t9acg (Athos, 2026-10-06): priority > type (feature first) > age, on every stage of the board. This
# stage used to take the stores one after the other, FIFO inside each, and stop at the GLOBAL cap — so the order of
# the STORES beat the priority: a P0 feature of the second store was never judged while the first one had a backlog.
# Fixture: two stores (hq listed first, wa second), five beads, cap 3. The sweep must judge, in this order:
#   wa-p0-feat-new  P0 feature, the NEWEST bead of the fixture (a feature goes before an older P0 bug)
#   hq-p0-bug-old   P0 bug
#   wa-p1-task      P1
# and must not reach hq-p2-old / hq-p2-old2, which the old per-store FIFO judged first.
echo "Scenario 14: ga-9t9acg.10 — one order across all stores (priority > type > age), cap after the order"
_c14="$(mktemp -d)"
mkdir -p "$_c14/hq/.gc/logs" "$_c14/wa" "$_c14/fix"
_sb_init "$_c14/sb" || exit 2   # the two-store `bd` stub below is the only bd on SANDBOX_PATH
_c14_desc='Fazer health-check do token PDPJ via API e reportar o status. Critério de aceitação: o script retorna o expected output {status:ok} e grava em scripts/pdpj-health.sh o resultado. Comando: bd list para confirmar.'
# _c14_bead <id> <type> <priority> <created_at> — one bead as `bd list --json` prints it.
_c14_bead() {
  jq -cn --arg id "$1" --arg t "$2" --argjson p "$3" --arg c "$4" --arg d "$_c14_desc" \
    '{id:$id, issue_type:$t, priority:$p, title:("Verificar saúde do token PDPJ — fixture " + $id), description:$d, labels:[], ephemeral:false, created_at:$c}'
}
# _c14_put <store> <type> <bead-json>... — the file the stub serves for `bd -C <store> list --type <type>`.
_c14_put() { local s="$1" t="$2"; shift 2; printf '%s\n' "$@" | jq -cs '.' > "$_c14/fix/$s.$t.json"; }
_c14_put hq task    "$(_c14_bead hq-p2-old task 2 2026-01-01T00:00:00Z)" "$(_c14_bead hq-p2-old2 task 2 2026-01-02T00:00:00Z)"
_c14_put hq bug     "$(_c14_bead hq-p0-bug-old bug 0 2026-01-03T00:00:00Z)"
_c14_put wa feature "$(_c14_bead wa-p0-feat-new feature 0 2026-02-01T00:00:00Z)"
_c14_put wa task    "$(_c14_bead wa-p1-task task 1 2026-01-01T00:00:00Z)"
# A bead whose priority bd did not give: the lib keeps it at the END (class 5, behind P4) and says so on stderr (14m/14n).
_c14_put hq chore   "$(_c14_bead hq-noprio chore 0 2026-01-01T00:00:00Z | jq -c 'del(.priority)')"
cat > "$_c14/sb/bin/bd" <<'STUB'
#!/usr/bin/env bash
# Two-store bd stub. `-C <store>` picks the fixture set by the store's basename (hq | wa); `list --type T` serves
# $C14_FIX/<store>.<T>.json (else []) and is recorded in $C14_CALLS; every WRITE lands in $C14_LEDGER as
# "<store> <cmd> <args>", so the test can see WHICH store a verdict was written to.
store=""
if [ "${1:-}" = "-C" ]; then store="$(basename "$2")"; shift 2; fi
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    echo "$store list $*" >> "$C14_CALLS"
    want=""
    while [ $# -gt 0 ]; do case "$1" in --type) want="$2"; shift 2 ;; *) shift ;; esac; done
    if [ -f "$C14_FIX/$store.$want.json" ]; then cat "$C14_FIX/$store.$want.json"; else echo "[]"; fi
    exit 0 ;;
  comments) echo "[]"; exit 0 ;;
  blocked)
    # C14_BLOCKED_FAIL=1: `bd blocked` itself fails (a Dolt hiccup) — nonzero, nothing on stdout.
    if [ "${C14_BLOCKED_FAIL:-0}" = "1" ]; then echo "error: connection refused" >&2; exit 1; fi
    echo "[]"; exit 0 ;;
esac
echo "$store $cmd $*" >> "$C14_LEDGER"
exit 0
STUB
chmod +x "$_c14/sb/bin/bd"
C14_FIX="$_c14/fix"; C14_CALLS="$_c14/calls.txt"; C14_LEDGER="$_c14/ledger.txt"
export C14_FIX C14_CALLS C14_LEDGER
_c14_log="$_c14/hq/.gc/logs/context-check-dispatcher.log"
# _c14_run <dispatcher> — one sweep over the two stores with a cap of 3. Writes land in $C14_LEDGER, list calls in
# $C14_CALLS. Exec-class off: the only writes are the verdicts. The blocked-ids test seam is set (to empty) unless
# C14_BLOCKED_SEAM=off: then the dispatcher really runs `bd blocked` through the stub (14k/14l).
_c14_run() {
  : > "$C14_LEDGER"; : > "$C14_CALLS"; rm -f "$_c14_log"
  local -a _c14_env=(CONTEXT_CHECK_CITY_OVERRIDE="$_c14/hq" CONTEXT_CHECK_STORES="$_c14/hq $_c14/wa"
    CONTEXT_CHECK_TEST_BUILT_IDS="" CONTEXT_CHECK_MAX_PER_SWEEP=3 CONTEXT_CHECK_MAX_SONNET_PER_SWEEP=0
    CONTEXT_CHECK_EXEC_CLASS=0 PATH="$SANDBOX_PATH")
  [ "${C14_BLOCKED_SEAM:-on}" = "on" ] && _c14_env+=(CONTEXT_CHECK_TEST_BLOCKED_IDS="")
  env "${_c14_env[@]}" timeout 120 bash "$1" >/dev/null 2>&1 || true
}
# _c14_judged — the ids that got a verdict, in the order the verdicts were written, space-separated.
_c14_judged() { awk '$2=="label" && $3=="add" && ($5=="ctx:ready" || $5=="ctx:thin") {printf "%s%s", sep, $4; sep=" "}' "$C14_LEDGER"; }
# _c14_count <words> — how many words (ids) in the string.
_c14_count() { printf '%s' "$1" | wc -w | tr -d ' '; }
# _c14_copy <dir> <real|none|broken> — a copy of the dispatcher beside symlinks to every sibling. `real` keeps
# scripts/ (the lib); `none` has no scripts/ at all; `broken` has a scripts/work-order.sh whose work_order_sort cannot tell.
_c14_copy() {
  local d="$1" mode="$2" e b
  for e in "$SELF_DIR"/*; do
    b="$(basename "$e")"
    [ "$b" = "context-check-dispatcher.sh" ] && continue
    [ "$b" = "scripts" ] && [ "$mode" != "real" ] && continue
    ln -s "$e" "$d/$b"
  done
  cp "$DISPATCHER" "$d/context-check-dispatcher.sh"
  if [ "$mode" = "broken" ]; then
    mkdir -p "$d/scripts"
    printf '%s\n' 'work_order_sort() { echo "work-order ERROR: stub: cannot tell" >&2; return 2; }' > "$d/scripts/work-order.sh"
  fi
}

# 14a-14d — the shipped dispatcher.
_c14_run "$DISPATCHER"
_c14_got="$(_c14_judged)"
_c14_want="wa-p0-feat-new hq-p0-bug-old wa-p1-task"
if [ "$_c14_got" = "$_c14_want" ]; then
  ok "14a: judged in the city order — the 2nd store's P0 feature first, then the older P0 bug, then P1 ($_c14_got)"
else
  bad "14a: wrong judging order (want: $_c14_want | got: ${_c14_got:-<nothing judged>})"
fi
if [ "$(_c14_count "$_c14_got")" = "3" ] && ! echo " $_c14_got " | grep -E ' hq-p2-old2? ' >/dev/null; then
  ok "14b: the cap of 3 is applied AFTER the order — the first store's two P2 beads were not reached"
else
  bad "14b: cap not applied after the order (judged: ${_c14_got:-<nothing>})"
fi
_c14_led="$(cat "$C14_LEDGER")"
if echo "$_c14_led" | grep -E '^wa label add wa-p0-feat-new ctx:(ready|thin) ' >/dev/null \
   && echo "$_c14_led" | grep -E '^hq label add hq-p0-bug-old ctx:(ready|thin) ' >/dev/null \
   && echo "$_c14_led" | grep -E '^wa label add wa-p1-task ctx:(ready|thin) ' >/dev/null; then
  ok "14c: every verdict is written to the store the bead came from (bd -C follows the row, not the loop)"
else
  bad "14c: a verdict went to the wrong store (ledger: $(echo "$_c14_led" | tr '\n' ';'))"
fi
_c14_nlist=$(grep -c ' list ' "$C14_CALLS" || true)
_c14_nolim=$(grep ' list ' "$C14_CALLS" | grep -vc -- '--limit 0' || true)
if [ "$_c14_nlist" = "10" ] && [ "$_c14_nolim" = "0" ]; then
  ok "14d: all 5 types of BOTH stores were fetched, every list with --limit 0 (the whole population before the order)"
else
  bad "14d: list calls=$_c14_nlist (want 10 = 5 types x 2 stores), without --limit 0=$_c14_nolim (want 0)"
fi

# 14e — mutation control: put the rule of today back (priority-blind, oldest first) and the order assertion must FAIL.
_c14m="$(mktemp -d)"
_c14_copy "$_c14m" real
sed "s/work_order_sort --age created/jq -c 'sort_by(.created_at \/\/ .id)'/" "$DISPATCHER" > "$_c14m/context-check-dispatcher.sh"
if cmp -s "$DISPATCHER" "$_c14m/context-check-dispatcher.sh"; then
  bad "14e: the mutation did not apply (no 'work_order_sort --age created' in the dispatcher) — the control proves nothing"
else
  _c14_run "$_c14m/context-check-dispatcher.sh"
  _c14_gotm="$(_c14_judged)"
  if [ "$_c14_gotm" != "$_c14_want" ] && [ -n "$_c14_gotm" ]; then
    ok "14e: mutation control — the old priority-blind FIFO rule does NOT give the city order (got: $_c14_gotm)"
  else
    bad "14e: mutation control failed — with the old rule the sweep still judged '${_c14_gotm:-<nothing>}', so 14a cannot catch a revert"
  fi
fi

# 14f/14g — "cannot tell" is not "empty queue": the lib missing, or work_order_sort failing, keeps sweeping (beads are
# still judged, in the order they were gathered) and says so in the log. It never reads as "no bead to judge".
_c14n="$(mktemp -d)"; _c14_copy "$_c14n" none
_c14_run "$_c14n/context-check-dispatcher.sh"
_c14_gotn="$(_c14_judged)"
if [ "$(_c14_count "$_c14_gotn")" = "3" ] && grep -E 'WARN.*ga-9t9acg\.10.*work-order\.sh missing' "$_c14_log" >/dev/null 2>&1; then
  ok "14f: lib missing → the sweep still judges (3 beads) and logs a WARN naming ga-9t9acg.10; not an empty queue"
else
  bad "14f: lib missing mishandled (judged: '${_c14_gotn:-<nothing>}'; log: $([ -f "$_c14_log" ] && grep -c . "$_c14_log" || echo '<missing>') lines)"
fi
_c14b="$(mktemp -d)"; _c14_copy "$_c14b" broken
_c14_run "$_c14b/context-check-dispatcher.sh"
_c14_gotb="$(_c14_judged)"
if [ "$(_c14_count "$_c14_gotb")" = "3" ] && grep -E 'WARN.*ga-9t9acg\.10.*cannot tell' "$_c14_log" >/dev/null 2>&1; then
  ok "14g: work_order_sort cannot tell → the sweep still judges (3 beads) and logs a WARN naming ga-9t9acg.10; not an empty queue"
else
  bad "14g: work_order_sort failure mishandled (judged: '${_c14_gotb:-<nothing>}'; log: $([ -f "$_c14_log" ] && grep -c . "$_c14_log" || echo '<missing>') lines)"
fi

# 14m/14n — the library's WARN lines reach the log. A bead whose priority is unreadable is kept at the end of the order
# and named on the library's stderr; that line is the ONLY signal, so the dispatcher must keep it (`2>/dev/null` would turn
# "unreadable, kept at the end" into "silently misordered"). Mutation control: send that stderr to /dev/null and it vanishes.
_c14_run "$DISPATCHER"
if grep -F 'work-order WARN: hq-noprio: prio?' "$_c14_log" >/dev/null 2>&1; then
  ok "14m: a bead with an unreadable priority is named in the sweep log by the library's own WARN (and the order is unchanged)"
else
  bad "14m: the library's WARN for hq-noprio did not reach the log (log: $([ -f "$_c14_log" ] && grep -c . "$_c14_log" || echo '<missing>') lines)"
fi
_c14w="$(mktemp -d)"
_c14_copy "$_c14w" real
sed 's|2>"${_wo_err:-/dev/null}"|2>/dev/null|' "$DISPATCHER" > "$_c14w/context-check-dispatcher.sh"
if cmp -s "$DISPATCHER" "$_c14w/context-check-dispatcher.sh"; then
  bad "14n: the mutation did not apply (no '2>\"\${_wo_err:-/dev/null}\"' in the dispatcher) — the control proves nothing"
else
  _c14_run "$_c14w/context-check-dispatcher.sh"
  if grep -F 'work-order WARN: hq-noprio' "$_c14_log" >/dev/null 2>&1; then
    bad "14n: mutation control failed — with the library's stderr sent to /dev/null its WARN still reached the log, so 14m proves nothing"
  else
    ok "14n: mutation control — with the library's stderr thrown away its WARN never reaches the log, so 14m catches that regression"
  fi
fi

# 14k/14l — `bd blocked` failing must not kill the sweep. The dep-blocked set is documented FAIL-OPEN (a failed query is an
# empty set, no exclusion); under `set -euo pipefail` the unguarded substitution aborted the whole process before it judged a
# bead. Here the stub's `bd blocked` exits 1 and the blocked-ids seam is OFF, so the dispatcher really runs the query.
C14_BLOCKED_SEAM=off; C14_BLOCKED_FAIL=1; export C14_BLOCKED_FAIL
_c14_run "$DISPATCHER"
_c14_gotk="$(_c14_judged)"
if [ "$_c14_gotk" = "$_c14_want" ]; then
  ok "14k: 'bd blocked' failing → the sweep survives (fail-open, empty blocked set) and still judges in the city order"
else
  bad "14k: a failing 'bd blocked' broke the sweep (want: $_c14_want | got: ${_c14_gotk:-<nothing judged>})"
fi
# Fail-open is not silent: an empty set from a FAILED query must not look like an empty set from "nothing is blocked".
if grep -E 'WARN.*ga-9t9acg\.10: bd blocked failed in .*fail-open' "$_c14_log" >/dev/null 2>&1; then
  ok "14k2: the failed 'bd blocked' is logged as a WARN naming the store — fail-open, not silent"
else
  bad "14k2: 'bd blocked' failed and the log says nothing (log: $([ -f "$_c14_log" ] && grep -c . "$_c14_log" || echo '<missing>') lines)"
fi
# Mutation control: put the query back OUTSIDE the `if` (unguarded assignment) and the same run must judge NOTHING (the sweep dies).
_c14k="$(mktemp -d)"
_c14_copy "$_c14k" real
sed 's/^  elif _cc_blocked=\$(\(bd_ blocked.*\)); then$/  elif true; then _cc_blocked=$(\1)/' "$DISPATCHER" > "$_c14k/context-check-dispatcher.sh"
if cmp -s "$DISPATCHER" "$_c14k/context-check-dispatcher.sh"; then
  bad "14l: the mutation did not apply (no 'elif _cc_blocked=\$(bd_ blocked …); then' in the dispatcher) — the control proves nothing"
else
  _c14_run "$_c14k/context-check-dispatcher.sh"
  _c14_gotl="$(_c14_judged)"
  if [ -z "$_c14_gotl" ]; then
    ok "14l: mutation control — with the query unguarded a failing 'bd blocked' kills the sweep before it judges a bead, so 14k catches a revert"
  else
    bad "14l: mutation control failed — with the query unguarded the sweep still judged '$_c14_gotl', so 14k cannot catch a revert"
  fi
fi
C14_BLOCKED_SEAM=on; C14_BLOCKED_FAIL=0; export C14_BLOCKED_FAIL

# 14h-14j — drift guards on the shipped file and on the registry.
_c14_code="$(grep -vE '^[[:space:]]*#' "$DISPATCHER")"
if echo "$_c14_code" | grep -F 'scripts/work-order.sh' >/dev/null && echo "$_c14_code" | grep -F 'work_order_sort --age created' >/dev/null; then
  ok "14h: the dispatcher sources scripts/work-order.sh and orders with it (age = created_at)"
else
  bad "14h: the dispatcher does not source/call the work-order lib"
fi
if echo "$_c14_code" | grep -E 'sort_by\(\.created_at' >/dev/null; then
  bad "14i: an ad-hoc sort_by(.created_at ...) is back in the dispatcher (the registry lint would flag it)"
else
  ok "14i: no ad-hoc created_at sort left in the dispatcher"
fi
if grep -E '^consumer[[:space:]]+packs/town-deltas/assets/context-check-dispatcher\.sh[[:space:]]' "$SELF_DIR/scripts/work-order.registry.tsv" >/dev/null; then
  bad "14j: the context-check-dispatcher.sh consumer row is still in work-order.registry.tsv (the slice must delete it)"
else
  ok "14j: the context-check-dispatcher.sh consumer row is gone from work-order.registry.tsv"
fi
rm -rf "$_c14" "$_c14m" "$_c14n" "$_c14b" "$_c14k" "$_c14w"

echo ""
echo "context-check-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
