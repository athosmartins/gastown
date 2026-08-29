#!/usr/bin/env bash
# story-delivery-task-reconciler.test.sh — regression test for the gate:passed
# task/bug reconciler (Step 1b, ga-tjqe) in story-delivery.sh.
#
# Extracts the real Step 1b block from story-delivery.sh (no duplication) and
# drives it with stubbed bd/log/warn to prove:
#   T1 TASK_WITH_GATE_PASSED  — open/in_progress task bead with gate:passed and
#                               no story:approved → bd close called, TASK_COUNT=1.
#   T2 STORY_EXCLUDED         — bead with gate:passed AND story:approved (a story
#                               awaiting delivery) → NOT closed, TASK_COUNT=0.
#   T3 DONE_EXCLUDED          — bead with gate:passed AND story:done but no
#                               story:approved → NOT closed, TASK_COUNT=0.
#   T4 NO_TASK_BEADS          — bd list returns [] → TASK_COUNT=0, no bd close.
#   T5 DRY_RUN_SKIPS_CLOSE    — DRY_RUN=1 with a task bead → bd close NOT called.
#   T6 FORCE_ID_SKIPS_BLOCK   — FORCE_STORY_ID set → reconciler skips entirely.
#   T7 CONTRADICTED_VERIFIED  — ga-tuk26: gate:passed + gate:failed +
#                               gate:needs-fix, but a real commit for this bead
#                               IS in origin/main (content-verified) → residual
#                               labels cleared AND bd close called.
#   T8 CONTRADICTED_UNVERIFIED— ga-tuk26: same contradictory label triple, but
#                               NO commit anywhere verifies it → stays stuck,
#                               unchanged (fail-safe control — this must NOT
#                               regress, or the fix becomes "trust the label
#                               pair alone" in different clothes).
#   T9 SHA_SCOPED_OVERRIDES   — ga-as3p1: the bead-scoped commit-subject scan
#                               (T7's mechanism) finds a real commit for this
#                               bead id — but a gate-sha-failed stamp names a
#                               DIFFERENT, unresolved sha (the multi-slice
#                               shape: one slice merged, a later slice failed
#                               and never merged, wa-7l2u3). The sha-scoped
#                               check must OVERRIDE the bead-scoped hit and
#                               keep the labels — T7's proof that "verified
#                               resolves" must not regress into "any commit
#                               for this bead id resolves any contradiction."
#
# This is the ga-tjqe acceptance test: "a regression test simulates a gate:passed
# task/bug bead and asserts delivery closes it in the same sweep". T7/T8 are the
# ga-tuk26 acceptance test: "a fixture reproducing wa-iochp's exact label set
# resolves iff independently verifiable; the same fixture without a verifiable
# commit stays stuck, unchanged." T9 is the ga-as3p1 acceptance test: "a bead
# carrying gate-sha-failed:<shaB>, with <shaA> (a DIFFERENT commit for the same
# bead) in origin/main and <shaB> outside it, keeps gate:failed/gate:needs-fix —
# today they are erased."

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

# ga-o643d: load the REAL merge-verification helpers (rig_gitdir,
# scan_commit_subject_for_bead, task_reconciler_verdict, ...) that Step 1b
# calls — lib-only mode defines them without running the live sweep, mirrors
# merged-bead-janitor.selftest.sh's established pattern (one source of truth).
STORY_DELIVERY_LIB_ONLY=1 source "$DELIVERY" \
  || { echo "FATAL: could not source story-delivery.sh in lib-only mode"; exit 1; }

export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@local
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 1b block (from its header to the end-marker comment).
BLOCK="$(sed -n '/# ── Step 1b: Task\/bug reconciler/,/# ── End Step 1b/p' "$DELIVERY")"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 1b block"; exit 1; }

# ── Helper: run the block with a bd list stub that returns given JSON ──────────
# run_block <bd_list_json> [dry_run] [force_story_id] [close_fail_stderr]
#   bd_list_json: JSON array the bd-list stub will return.
#   dry_run: 0 or 1 (default 0).
#   force_story_id: non-empty to simulate FORCE_STORY_ID (default empty).
#   close_fail_stderr: ga-s1qb2 — when non-empty, `bd ... close ...` returns
#     rc=1 with this text on stderr instead of succeeding (simulates a real
#     bd close failure, e.g. the ownership-guard refusal message). Empty
#     (default) preserves every pre-existing test's always-succeeds behavior.
# Sets globals: RUN_TASK_COUNT, LAST_BD
run_block() {
  local bd_list_json="$1"
  local dry_run="${2:-0}"
  local force_id="${3:-}"
  local close_fail_stderr="${4:-}"
  local T; T="$(mktemp -d)"
  local BD_LOG="$T/bd.log"

  bd() {
    echo "bd $*" >> "$BD_LOG"
    # Intercept: bd ... list ... → return stubbed JSON
    local args_str="$*"
    case "$args_str" in
      *list*--json*)
        printf '%s' "$bd_list_json"
        ;;
      *close*)
        # ga-s1qb2: simulate a real bd-close failure (e.g. the ownership
        # guard's "reclaim or use --force to override" refusal) so the
        # reconciler's verify-before-claiming-success path can be exercised.
        if [ -n "$close_fail_stderr" ]; then
          echo "$close_fail_stderr" >&2
          return 1
        fi
        ;;
    esac
  }
  # ga-s1qb2: the close-retry-exhausted path mails Mayor — stub `gc` so a
  # test run can never reach a real Dolt server / send real mail, and so the
  # attempt itself is observable via BD_LOG (reused for simplicity: this is
  # a "commands issued" log, not literally bd-only).
  gc() { echo "gc $*" >> "$BD_LOG"; }
  log()  { :; }
  warn() { :; }
  err()  { :; }
  jq() {
    # Pass through to real jq — only stub what bd calls
    command jq "$@"
  }

  local GC_CITY="$T/city"
  local DELIVERY_LOG="$T/delivery.jsonl"
  local FORCE_STORY_ID="$force_id"
  local DRY_RUN="$dry_run"
  # ga-o643d: the block fans out over ALL_STORES (ga-mt03s) and computes
  # TASK_DEFAULT_BRANCH from RIG_LIST_JSON — both unset here under set -u
  # would abort the eval before any bd/log call. One store (this temp dir).
  local ALL_STORES="$T"
  local RIG_LIST_JSON='{"rigs":[]}'

  # ga-o643d: real git repo so the ga-266z8 merge-verification guard
  # (scan_commit_subject_for_bead) has real history to check TASK_BEAD_JSON's
  # id against — mirrors merged-bead-janitor.selftest.sh's real-git fixtures
  # rather than stubbing the verification itself away.
  git init -q -b main "$T" >/dev/null 2>&1
  ( cd "$T" && echo x > f.txt && git add f.txt \
      && git commit -q -m "fix(ga-test-task): synthetic commit for reconciler selftest" ) >/dev/null 2>&1
  git -C "$T" update-ref refs/remotes/origin/main refs/heads/main >/dev/null 2>&1

  # Run block; capture TASK_COUNT (set inside block)
  local TASK_COUNT=0
  ( eval "$BLOCK"; echo "TASK_COUNT=$TASK_COUNT" ) > "$T/out.txt" 2>&1
  RUN_TASK_COUNT=$(grep '^TASK_COUNT=' "$T/out.txt" 2>/dev/null | tail -1 | sed 's/TASK_COUNT=//' || echo "0")
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || echo "")"

  unset -f bd gc log warn err jq
  rm -rf "$T"
}

# ── Stub JSON helpers ──────────────────────────────────────────────────────────
TASK_BEAD_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","lane:small"]}]'
STORY_WITH_GATE_JSON='[{"id":"ga-test-story","title":"Add feature X","status":"open","issue_type":null,"labels":["gate:passed","story:approved"]}]'
DONE_WITH_GATE_JSON='[{"id":"ga-test-done","title":"Old fix","status":"in_progress","issue_type":"task","labels":["gate:passed","story:done"]}]'
EMPTY_JSON='[]'
# ga-tuk26: same id as TASK_BEAD_JSON ("ga-test-task") — run_block's synthetic
# git repo (below) commits with subject scoped to exactly this id, so this
# fixture IS independently verifiable. Reproduces wa-iochp's real label set
# (gate:passed + gate:failed + gate:needs-fix + gate:fix-attempt:1).
CONTRADICTED_VERIFIED_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","gate:failed","gate:needs-fix","gate:fix-attempt:1","lane:small"]}]'
# ga-tuk26: a DIFFERENT id ("ga-test-task-nocommit") that run_block's synthetic
# repo has no commit for — the fail-safe control. Same contradictory labels,
# but nothing anywhere proves the fail-cycle residue is stale.
CONTRADICTED_UNVERIFIED_JSON='[{"id":"ga-test-task-nocommit","title":"unrelated task, never merged","status":"in_progress","issue_type":"task","labels":["gate:passed","gate:failed","gate:needs-fix","lane:small"]}]'
# ga-as3p1: SAME id as TASK_BEAD_JSON/CONTRADICTED_VERIFIED_JSON ("ga-test-task")
# — the bead-scoped scan finds run_block's synthetic commit for it, exactly
# like T7. The difference is the extra gate-sha-failed stamp naming a sha that
# does not exist anywhere in the synthetic repo (standing in for wa-7l2u3's
# df90c973 — a real, different, never-merged slice). A bead-scoped-only check
# would wrongly treat T7's proof as covering this bead too; the sha-scoped
# check must catch that the NAMED rejected sha specifically never resolved.
CONTRADICTED_SHA_SCOPED_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","gate:failed","gate:needs-fix","gate-sha-failed:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef:code","lane:small"]}]'

# ── T1: Task bead with gate:passed → close called ─────────────────────────────
run_block "$TASK_BEAD_JSON" 0 ""
echo "$LAST_BD" | grep -q "close ga-test-task" && ok "T1 TASK_WITH_GATE_PASSED → bd close called" || nok "T1 bd-close missing" "$LAST_BD"
echo "$LAST_BD" | grep -q "comment ga-test-task" && ok "T1 comment added to task bead" || nok "T1 comment missing" "$LAST_BD"
# TASK_COUNT should be 1 (reconciler ran)
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T1 TASK_COUNT=1" || nok "T1 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T2: Story bead excluded (has story:approved) ──────────────────────────────
run_block "$STORY_WITH_GATE_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-story" && ok "T2 STORY_EXCLUDED → bd close NOT called" || nok "T2 story-closed" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T2 TASK_COUNT=0 (story filtered out)" || nok "T2 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T3: Bead with story:done excluded ─────────────────────────────────────────
run_block "$DONE_WITH_GATE_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-done" && ok "T3 DONE_EXCLUDED → bd close NOT called" || nok "T3 done-closed" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T3 TASK_COUNT=0 (story:done filtered out)" || nok "T3 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T4: No gate:passed task beads ─────────────────────────────────────────────
run_block "$EMPTY_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close" && ok "T4 NO_TASK_BEADS → no bd close" || nok "T4 spurious-close" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T4 TASK_COUNT=0 (empty list)" || nok "T4 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T5: DRY_RUN=1 → bd close NOT called ──────────────────────────────────────
run_block "$TASK_BEAD_JSON" 1 ""
! echo "$LAST_BD" | grep -q "close ga-test-task" && ok "T5 DRY_RUN_SKIPS_CLOSE → bd close NOT called" || nok "T5 dry-run-closed" "$LAST_BD"
# TASK_COUNT should still be 1 (reconciler ran, found bead, but skipped close)
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T5 TASK_COUNT=1 (found bead in dry-run)" || nok "T5 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T6: FORCE_STORY_ID set → reconciler skipped entirely ─────────────────────
run_block "$TASK_BEAD_JSON" 0 "ga-some-story"
! echo "$LAST_BD" | grep -q "close" && ok "T6 FORCE_ID_SKIPS_BLOCK → no bd close (reconciler skipped)" || nok "T6 force-id-closed" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "0" ] && ok "T6 TASK_COUNT=0 (FORCE_STORY_ID skips block)" || nok "T6 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T7: contradicted but independently VERIFIED → residue cleared + closed ──
# ga-tuk26 AC1: "a fixture reproducing wa-iochp's exact label set (gate:passed
# + gate:failed + gate:needs-fix, in_progress) with an independently-verifiable
# merged commit resolves: stale labels cleared, bd close called."
run_block "$CONTRADICTED_VERIFIED_JSON" 0 ""
echo "$LAST_BD" | grep -q 'label remove ga-test-task "\?gate:failed"\?' \
  && ok "T7 CONTRADICTED_VERIFIED → gate:failed cleared" || nok "T7 gate:failed not cleared" "$LAST_BD"
echo "$LAST_BD" | grep -q 'label remove ga-test-task "\?gate:needs-fix"\?' \
  && ok "T7 CONTRADICTED_VERIFIED → gate:needs-fix cleared" || nok "T7 gate:needs-fix not cleared" "$LAST_BD"
echo "$LAST_BD" | grep -q "close ga-test-task" \
  && ok "T7 CONTRADICTED_VERIFIED → bd close called (contradiction proven stale)" || nok "T7 bd-close missing" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T7 TASK_COUNT=1" || nok "T7 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T8: contradicted, NOT verifiable anywhere → stays stuck, unchanged ──────
# ga-tuk26 AC2 (fail-safe control): "the SAME fixture WITHOUT a verifiable
# commit stays stuck, unchanged — proves this isn't 'trust the label pair
# alone' in different clothes."
run_block "$CONTRADICTED_UNVERIFIED_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-task-nocommit" \
  && ok "T8 CONTRADICTED_UNVERIFIED → bd close NOT called (never guess)" || nok "T8 spurious-close" "$LAST_BD"
! echo "$LAST_BD" | grep -q "label remove ga-test-task-nocommit" \
  && ok "T8 CONTRADICTED_UNVERIFIED → labels left untouched" || nok "T8 spurious-label-remove" "$LAST_BD"
# TASK_COUNT is `jq 'length'` on the raw candidate list (set once, before the
# loop runs — see story-delivery.sh ~line 504) — it reflects how many
# candidates the QUERY surfaced, not whether the loop acted on them. T1/T5/T7
# also assert TASK_COUNT=1 for the same reason: one gate:passed, non-story,
# non-done bead is present in the stubbed `bd list` response. Distinguishing
# "kept, not closed" from "closed" is what the two assertions above already
# do (no close call, no label remove) — TASK_COUNT is not that signal.
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T8 TASK_COUNT=1 (candidate found, but kept — not the same as acted)" || nok "T8 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T9: bead-scoped hit EXISTS, but the NAMED rejected sha is unresolved ────
# ga-as3p1 acceptance test: the bead-scoped commit-subject scan (T7's own
# mechanism) finds a real commit for "ga-test-task" — same as T7 — but the
# gate-sha-failed stamp names a sha that isn't that commit and doesn't
# resolve anywhere. Before this fix, the bead-scoped hit alone was enough to
# clear gate:failed/gate:needs-fix and close the bead — exactly the false
# positive measured live on wa-7l2u3 (slice 8b2c5ffe merged papering over
# slice df90c973's live, correct rejection). The sha-scoped check must win:
# labels survive, bd close is never called.
run_block "$CONTRADICTED_SHA_SCOPED_JSON" 0 ""
! echo "$LAST_BD" | grep -q 'label remove ga-test-task "\?gate:failed"\?' \
  && ok "T9 SHA_SCOPED_OVERRIDES → gate:failed NOT cleared (named sha unresolved)" || nok "T9 gate:failed wrongly cleared" "$LAST_BD"
! echo "$LAST_BD" | grep -q 'label remove ga-test-task "\?gate:needs-fix"\?' \
  && ok "T9 SHA_SCOPED_OVERRIDES → gate:needs-fix NOT cleared" || nok "T9 gate:needs-fix wrongly cleared" "$LAST_BD"
! echo "$LAST_BD" | grep -q "close ga-test-task" \
  && ok "T9 SHA_SCOPED_OVERRIDES → bd close NOT called (bead-scoped hit overridden)" || nok "T9 spurious-close" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T9 TASK_COUNT=1 (candidate found, but kept)" || nok "T9 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T10/T11/T12 (ga-s1qb2): bd-close FAILS — verify-before-claiming-success ──
# wa-l30yr incident: `bd close` refused (bd's own ownership guard — assignee
# is a role name, actor is a session name for the same agent) but the
# reconciler still posted "Closed by delivery sweep" and retried forever, one
# Dolt commit per sweep. These prove (a) a failed close never gets a
# false-success comment, (b) the failure reason is captured, not sent to
# /dev/null, and (c) retries stop at TASK_CLOSE_MAX_RETRIES with an
# escalation instead of continuing forever.
CLOSE_FAIL_STDERR='cannot close ga-test-task: assignee is "role-x", actor is "role-x-session1"; reclaim or use --force to override'
CLOSE_FIRST_ATTEMPT_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","lane:small"]}]'
# Same bead, but already carries delivery:close-retry:2 — this failure is the
# 3rd (TASK_CLOSE_MAX_RETRIES=3), the one that must trip the cap.
CLOSE_LAST_ATTEMPT_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","lane:small","delivery:close-retry:2"]}]'
# Already escalated on a PRIOR sweep — the early skip-check must fire before
# ever attempting another close.
CLOSE_EXHAUSTED_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","lane:small","delivery:close-retry-exhausted"]}]'

# ── T10: first close failure → no false-success comment, retry-count bumped,
#         no escalation yet (1 of 3) ──────────────────────────────────────────
run_block "$CLOSE_FIRST_ATTEMPT_JSON" 0 "" "$CLOSE_FAIL_STDERR"
echo "$LAST_BD" | grep -q "close ga-test-task" \
  && ok "T10 close IS attempted" || nok "T10 close not attempted" "$LAST_BD"
! echo "$LAST_BD" | grep -q "Closed by delivery sweep" \
  && ok "T10 CLOSE_FAILS → no false-success 'Closed by delivery sweep' comment" || nok "T10 false-success comment posted despite failed close" "$LAST_BD"
echo "$LAST_BD" | grep -q 'label add ga-test-task "\?delivery:close-retry:1"\?' \
  && ok "T10 retry-count bumped to delivery:close-retry:1" || nok "T10 retry-count not bumped" "$LAST_BD"
! echo "$LAST_BD" | grep -q "close-retry-exhausted" \
  && ok "T10 NOT yet exhausted (1st of 3 allowed attempts)" || nok "T10 wrongly marked exhausted on 1st failure" "$LAST_BD"
! echo "$LAST_BD" | grep -q "gc.*mail send mayor" \
  && ok "T10 no Mayor escalation yet (cap not reached)" || nok "T10 escalated too early" "$LAST_BD"

# ── T11: 3rd consecutive failure (cap=3) → escalate, stop retrying ──────────
run_block "$CLOSE_LAST_ATTEMPT_JSON" 0 "" "$CLOSE_FAIL_STDERR"
echo "$LAST_BD" | grep -q "close ga-test-task" \
  && ok "T11 close IS attempted (3rd time)" || nok "T11 close not attempted" "$LAST_BD"
! echo "$LAST_BD" | grep -q "Closed by delivery sweep" \
  && ok "T11 CLOSE_FAILS 3x → still no false-success comment" || nok "T11 false-success comment posted" "$LAST_BD"
echo "$LAST_BD" | grep -q 'label remove ga-test-task "\?delivery:close-retry:2"\?' \
  && ok "T11 stale delivery:close-retry:2 removed" || nok "T11 stale retry-count label not removed" "$LAST_BD"
echo "$LAST_BD" | grep -q 'label add ga-test-task "\?delivery:close-retry-exhausted"\?' \
  && ok "T11 CAP REACHED → delivery:close-retry-exhausted added" || nok "T11 exhausted label not added" "$LAST_BD"
echo "$LAST_BD" | grep -q "comment ga-test-task" \
  && ok "T11 escalation comment posted (honest — describes failure, not success)" || nok "T11 no escalation comment" "$LAST_BD"
echo "$LAST_BD" | grep -q "gc.*mail send mayor" \
  && ok "T11 Mayor notified (ga-s1qb2 escalation, same convention as keep:partial-delivery)" || nok "T11 no Mayor mail on cap" "$LAST_BD"

# ── T12: already exhausted (prior sweep escalated) → skip entirely, no retry ─
run_block "$CLOSE_EXHAUSTED_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-task" \
  && ok "T12 ALREADY_EXHAUSTED → bd close NOT attempted at all (early skip)" || nok "T12 spurious close attempt on exhausted bead" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T12 TASK_COUNT=1 (candidate found, but skipped — not the same as acted)" || nok "T12 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

# ── T13 (ga-wnxeq): delivery:pending-restart → veto, NOT closed even though ──
# merge verification WOULD succeed (same id/commit as T1) ───────────────────
# ga-l7n3v's daemon-verification hold (quality-gate-dispatcher.sh) sets
# delivery:pending-restart and EXPLICITLY withholds closure ("Closure is
# WITHHELD until this is resolved ... close this bead manually once confirmed
# live"). This reconciler is a SEPARATE, independent close path (it exists to
# catch beads the primary dispatcher crashed before closing) and had NO
# knowledge of delivery:pending-restart at all — so it ran its own merge
# check, found the content genuinely in origin/main (true — the gate DID
# merge it, same synthetic commit as T1's "ga-test-task"), and closed anyway,
# directly overriding the hold. Reproduces wa-q3x98 (DEPLOY_FAILED — the rig's
# runtime checkout never even pulled the merge, closed regardless) and
# wa-5wlrd (NEEDS_GUARDED_RESTART on a sensitive daemon, "NOT auto-bounced",
# closed regardless) — both real beads had a genuinely merged commit, which is
# exactly what let this reconciler's own content check wave them through.
PENDING_RESTART_JSON='[{"id":"ga-test-task","title":"fix cloudflared DNS reconciler","status":"in_progress","issue_type":"task","labels":["gate:passed","delivery:pending-restart","lane:small"]}]'
run_block "$PENDING_RESTART_JSON" 0 ""
! echo "$LAST_BD" | grep -q "close ga-test-task" \
  && ok "T13 PENDING_RESTART_VETO → bd close NOT called (daemon-verification hold wins over merge proof)" || nok "T13 spurious-close despite delivery:pending-restart" "$LAST_BD"
! echo "$LAST_BD" | grep -q 'label remove ga-test-task.*delivery:pending-restart' \
  && ok "T13 delivery:pending-restart label left untouched (resolution is manual/daemon-refresh, not this reconciler)" || nok "T13 label wrongly removed" "$LAST_BD"
! echo "$LAST_BD" | grep -q "comment ga-test-task" \
  && ok "T13 no comment posted (already announced in full by the dispatcher when it set the label — avoids the ga-s1qb2 per-sweep comment-spam anti-pattern)" || nok "T13 spurious comment" "$LAST_BD"
[ "${RUN_TASK_COUNT:-0}" = "1" ] && ok "T13 TASK_COUNT=1 (candidate found, but kept — not the same as acted)" || nok "T13 TASK_COUNT" "got=${RUN_TASK_COUNT:-UNSET}"

echo ""
echo "story-delivery task-reconciler tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
