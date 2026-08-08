#!/usr/bin/env bash
# gate-sha-fail-lock.selftest.sh — Prove the ga-nooaw fail-closed-by-SHA fix in
# isolation, with NO live Dolt/gc/launchd:
#
#   BUG (ga-nooaw): a gate FAIL did not hold the commit. Reviewers across
#   independent gate-runs can diverge (one FAIL, a later one PASS); the
#   dispatcher merged the SAME already-rejected commit SHA the moment any run
#   PASSed it. Live incident: commit afb59120 (bead wa-zmw4r) was REJECTED by
#   gate-run ga-wisp-5qzux2 (a real blocking issue — list-open fallback opened
#   a WhatsApp chat by name without verifying identity), but a later run
#   PASSED the same SHA and merged it. wa-zmw4r closed carrying gate:failed AND
#   gate:passed AND story:done simultaneously — the signature of the race.
#
#   FIX: fail-closed by SHA. When a run FAILs, durably stamp the rejected
#   commit SHA onto the source bead (gate-sha-failed:<sha>:<class> label).
#   Before any future run acts on a PASS verdict, check whether THIS EXACT
#   SHA already carries a blocking stamp; if so, downgrade to FAIL before the
#   merge is even attempted. A NEW commit (new SHA, i.e. an actual fix)
#   carries no stamp and re-gates normally — the legitimate re-fix loop is
#   never blocked.
#
#   BUG #2 (ga-4cy2t), found operating the fix above: the stamp recorded ONLY
#   the verdict, not the REASON. A gate FAIL can happen two ways — (a) a
#   reviewer/content verdict actually rejected the code, or (b) the code
#   PASSED but a non-code administrative refusal (a hold/park/needs-human
#   label applied mid-run, a sibling branch racing the same bead, the bead
#   closed elsewhere) downgraded it after the fact. Both wrote the identical
#   unclassed "gate-sha-failed:<sha>" stamp, so once a hold-driven FAIL
#   happened, the exact same commit stayed permanently blocked even after the
#   hold was proven wrong and removed — the only way out was pushing a new,
#   often empty, commit just to change the SHA. Live incident: commit
#   48a365ae (bead ga-y9a1d) was correct and reviewed clean, but a Pilot
#   brief-void hold (ga-e2n96) forced a FAIL; removing the hold and
#   re-submitting the SAME commit still hit the sha-fail lock, because the
#   lock could not tell "held" from "rejected".
#
#   FIX #2: gate_sha_fail_label now takes a <class> — "code" (rejected by
#   review/content; keeps blocking, unchanged from BUG #1's fix) or "hold"
#   (a non-code administrative downgrade of an already-PASS verdict; does
#   NOT block re-review — the live hold check re-guards independently while
#   the hold is still active). A pre-fix unclassed label is treated as "code"
#   (ambiguous defaults to the blocking/safe branch). If the SAME sha ever
#   accumulates both a hold stamp and a code stamp (across separate runs), it
#   stays blocked — one real rejection is enough, regardless of order.
#
# This harness SOURCES the dispatcher in lib-only mode to unit-test the REAL
# pure decision (gate_labels_have_sha_fail, gate_sha_fail_label) and the REAL
# bd-backed resolver (gate_bead_has_prior_sha_fail, driven by an in-shell bd
# mock), then DRIFT-GUARDS the live script so a future refactor that drops or
# reorders either fix fails loudly. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_sha_fail_label          >/dev/null 2>&1 || { echo "FATAL: gate_sha_fail_label not defined by dispatcher"; exit 1; }
type gate_labels_have_sha_fail    >/dev/null 2>&1 || { echo "FATAL: gate_labels_have_sha_fail not defined by dispatcher"; exit 1; }
type gate_bead_has_prior_sha_fail >/dev/null 2>&1 || { echo "FATAL: gate_bead_has_prior_sha_fail not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_sha_fail_label — canonical label shape (pure) ────────────────────
echo "── 1. gate_sha_fail_label (label naming) ──"
eq "formats sha+class into the canonical stamp" "$(gate_sha_fail_label 'deadbeef' 'code')" "gate-sha-failed:deadbeef:code"
eq "formats the hold class"                     "$(gate_sha_fail_label 'deadbeef' 'hold')" "gate-sha-failed:deadbeef:hold"
eq "formats a full 40-char sha"                 "$(gate_sha_fail_label 'afb591200000000000000000000000000000ab' 'code')" "gate-sha-failed:afb591200000000000000000000000000000ab:code"
eq "class omitted defaults to code (ga-4cy2t: safe/blocking branch)" "$(gate_sha_fail_label 'deadbeef')" "gate-sha-failed:deadbeef:code"

# ── 2. gate_labels_have_sha_fail — pure blocking decision (ga-4cy2t) ─────────
# BUG this closes: gate-sha-failed used to record ONLY a verdict, not a
# reason, so a non-code administrative refusal (a hold applied mid-run, later
# proven wrong and removed) stamped the exact same label as a genuine code
# rejection — permanently poisoning a commit the reviewer never actually
# rejected. Now: a "code" stamp blocks re-review forever (unchanged); a
# "hold" stamp alone does not (the live hold check re-guards it independently
# while the hold is still active); a legacy unclassed stamp (written before
# this fix shipped) blocks, since its class can't be recovered retroactively.
echo "── 2. gate_labels_have_sha_fail (pure label-set membership) ──"
eq "empty label set → no"                                  "$(gate_labels_have_sha_fail '' 'abc123')"                                    "no"
eq "unrelated labels only → no"                             "$(gate_labels_have_sha_fail 'gate:failed area:gate' 'abc123')"                "no"
eq "code-class stamp, sole label → yes"                     "$(gate_labels_have_sha_fail 'gate-sha-failed:abc123:code' 'abc123')"          "yes"
eq "code-class stamp among other labels → yes"              "$(gate_labels_have_sha_fail 'gate:failed gate-sha-failed:abc123:code area:gate' 'abc123')" "yes"
eq "hold-class stamp ALONE → no (never code-rejected)"      "$(gate_labels_have_sha_fail 'gate-sha-failed:abc123:hold' 'abc123')"          "no"
eq "hold-class stamp among other labels → no"                "$(gate_labels_have_sha_fail 'gate:failed gate-sha-failed:abc123:hold area:gate' 'abc123')" "no"
eq "MIXED: hold AND code stamps for same sha → yes (stays blocked)" "$(gate_labels_have_sha_fail 'gate-sha-failed:abc123:hold gate-sha-failed:abc123:code' 'abc123')" "yes"
eq "legacy pre-ga-4cy2t unclassed stamp → yes (ambiguous defaults to blocking)" "$(gate_labels_have_sha_fail 'gate-sha-failed:abc123' 'abc123')" "yes"
eq "different sha's code stamp present → no"                "$(gate_labels_have_sha_fail 'gate-sha-failed:def456:code' 'abc123')"          "no"
# Boundary anchoring: a longer/shorter sha sharing a prefix/suffix must NOT
# false-positive via naive substring containment.
eq "longer sha sharing our prefix does NOT match (boundary)" "$(gate_labels_have_sha_fail 'gate-sha-failed:abc1234:code' 'abc123')"         "no"
eq "sha embedded as a suffix does NOT match (boundary)"      "$(gate_labels_have_sha_fail 'gate-sha-failed:xabc123:code' 'abc123')"          "no"

# ── 3. gate_bead_has_prior_sha_fail — bd-backed resolver (mock bd) ────────────
echo "── 3. gate_bead_has_prior_sha_fail (bd show + label check, mock bd) ──"
MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=0
bd() {
  case " $* " in
    *" show "*)
      [ "$MOCK_SHOW_FAIL" = "1" ] && return 1
      printf '%s\n' "$MOCK_SHOW_JSON"
      ;;
    *) : ;;
  esac
  return 0
}

eq "(a) empty bead_id → no (never calls bd)"    "$(gate_bead_has_prior_sha_fail 'city' '' 'abc123')"     "no"
eq "(b) empty sha → no (never calls bd)"        "$(gate_bead_has_prior_sha_fail 'city' 'bead1' '')"      "no"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate:failed","area:gate"]}]'
eq "(c) bead has no gate-sha-failed label → no" "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate:failed","gate-sha-failed:abc123:code"]}]'
eq "(d) bead stamped CODE for THIS sha → yes"   "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "yes"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate-sha-failed:def456:code"]}]'
eq "(e) bead stamped for a DIFFERENT sha → no"  "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='{"id":"bead1","labels":["gate-sha-failed:abc123:code"]}'
eq "(f) bare object (not array) response → yes" "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "yes"

MOCK_SHOW_JSON='[{"id":"bead1"}]'
eq "(g) labels field absent entirely → no"      "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=1
eq "(h) bd show fails (transient) → no (fail-open)" "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"
MOCK_SHOW_FAIL=0

# ── 3b. ga-4cy2t: hold-only refusal must NOT poison the sha; mixed stays blocked ──
echo "── 3b. gate_bead_has_prior_sha_fail (ga-4cy2t: hold vs code class, mock bd) ──"
MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate:failed","gate-sha-failed:abc123:hold"]}]'
eq "(i) bead stamped HOLD-only for THIS sha → no (re-submittable once the hold clears, no new commit needed)" \
  "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "no"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate-sha-failed:abc123:hold","gate-sha-failed:abc123:code"]}]'
eq "(j) MIXED: same sha has a hold stamp (earlier run) AND a code stamp (later run) → yes (stays blocked)" \
  "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "yes"

MOCK_SHOW_JSON='[{"id":"bead1","labels":["gate-sha-failed:abc123"]}]'
eq "(k) LEGACY pre-ga-4cy2t unclassed stamp for THIS sha → yes (ambiguous defaults to blocking)" \
  "$(gate_bead_has_prior_sha_fail 'city' 'bead1' 'abc123')" "yes"

# ── 4. DRIFT GUARD: helpers defined before the lib-only cutoff ───────────────
echo "── 4. drift guard: helpers are selftest-sourceable (defined before lib-only guard) ──"
DEF_LN=$(grep -n '^gate_bead_has_prior_sha_fail() {' "$DISPATCHER" | head -1 | cut -d: -f1)
CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "gate_bead_has_prior_sha_fail (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
else
  bad "helpers must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

# ── 5. DRIFT GUARD: pre-merge check wired in, and runs BEFORE the merge ──────
echo "── 5. drift guard: fail-closed check precedes the merge attempt ──"
has "$DISPATCHER" 'gate_bead_has_prior_sha_fail "\$BEAD_CITY" "\$BEAD_ID" "\$BRANCH_SHA"' \
  "pre-merge check calls gate_bead_has_prior_sha_fail with BEAD_CITY/BEAD_ID/BRANCH_SHA"
has "$DISPATCHER" 'OVERALL_VERDICT="FAIL"' "fail-closed check can downgrade OVERALL_VERDICT to FAIL"

CHECK_LN=$(grep -n 'gate_bead_has_prior_sha_fail "\$BEAD_CITY" "\$BEAD_ID" "\$BRANCH_SHA"' "$DISPATCHER" | head -1 | cut -d: -f1)
MERGE_LOG_LN=$(grep -n 'log "ALL PASS — proceeding to merge branch' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$CHECK_LN" ] && [ -n "$MERGE_LOG_LN" ] && [ "$CHECK_LN" -lt "$MERGE_LOG_LN" ]; then
  ok "fail-closed check (line $CHECK_LN) runs BEFORE the merge attempt (line $MERGE_LOG_LN)"
else
  bad "fail-closed check must precede the merge attempt (check=$CHECK_LN merge=$MERGE_LOG_LN)"
fi

# ── 6. DRIFT GUARD: FAIL path stamps the rejected SHA, classed (ga-4cy2t) ─────
echo "── 6. drift guard: FAIL path stamps the rejected SHA, classed by reason ──"
STAMP_LN=$(grep -n 'label add "\$BEAD_ID" "\$(gate_sha_fail_label "\$BRANCH_SHA" "\${GATE_SHA_FAIL_CLASS:-code}")"' "$DISPATCHER" | head -1 | cut -d: -f1)
FAILED_LABEL_LN=$(grep -n 'label add "\$BEAD_ID" "gate:failed" -q' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$STAMP_LN" ]; then
  ok "FAIL path stamps the rejected SHA via gate_sha_fail_label, passing the tracked class (line $STAMP_LN)"
else
  bad "FAIL path must stamp the rejected SHA via gate_sha_fail_label \"\$BRANCH_SHA\" \"\${GATE_SHA_FAIL_CLASS:-code}\" — found the old unclassed call, or none at all?"
fi
if [ -n "$STAMP_LN" ] && [ -n "$FAILED_LABEL_LN" ] && [ "$STAMP_LN" -gt "$FAILED_LABEL_LN" ]; then
  ok "SHA stamp (line $STAMP_LN) is written in the same FAIL path as gate:failed (line $FAILED_LABEL_LN)"
else
  bad "SHA stamp must sit in the FAIL path, after the gate:failed label add (stamp=$STAMP_LN failed=$FAILED_LABEL_LN)"
fi

# ── 6b. DRIFT GUARD: fail-class tracker resets to "code" before ga-nooaw,
# and every ga-lxz5w administrative downgrade (closed / live park / sibling-
# race) overrides it to "hold" — the wiring ga-4cy2t depends on. Without
# this, gate_labels_have_sha_fail's new hold-vs-code logic is correct but
# dead code: every stamp would silently keep going out as "code" (the
# default), reproducing the exact bug this bead fixes.
echo "── 6b. drift guard: fail-class reset + all 3 administrative downgrades classify as hold ──"
RESET_LN=$(grep -n '^GATE_SHA_FAIL_CLASS="code"$' "$DISPATCHER" | head -1 | cut -d: -f1)
NOOAW_LN=$(grep -n '# ── ga-nooaw: FAIL-CLOSED BY SHA' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$RESET_LN" ] && [ -n "$NOOAW_LN" ] && [ "$RESET_LN" -lt "$NOOAW_LN" ]; then
  ok "fail-class resets to \"code\" (line $RESET_LN) before the ga-nooaw block (line $NOOAW_LN) — no leakage across beads in the same sweep"
else
  bad "fail-class reset must precede the ga-nooaw block (reset=$RESET_LN nooaw=$NOOAW_LN)"
fi

HOLD_COUNT=$(grep -c 'GATE_SHA_FAIL_CLASS="hold"' "$DISPATCHER" || true)
HOLD_COUNT=${HOLD_COUNT:-0}
# Sanity floor only (the known sites as of ga-3ipxu's review: closed bead,
# live park, sibling-race, ga-y9a1d branch-content-coherence, the
# merge-mechanical failed* block, post-merge integrity-revert). This does
# NOT prove completeness — a hard count is exactly the gap 6c below exists
# to close; see that check for the actual regression guard.
if [ "$HOLD_COUNT" -ge 6 ]; then
  ok "at least the 6 known administrative downgrades classify as hold ($HOLD_COUNT sites found)"
else
  bad "expected >=6 GATE_SHA_FAIL_CLASS=\"hold\" sites (closed bead, live park, sibling-race, ga-y9a1d, merge-mechanical, post-merge integrity), found $HOLD_COUNT"
fi

# ── 6c. DRIFT GUARD (ga-4cy2t gate-fix-1, ga-3ipxu review): EVERY
# OVERALL_VERDICT="FAIL" site inside gate_finalize_run() must classify
# GATE_SHA_FAIL_CLASS, not just whatever count 6b happens to hard-code. 6b's
# plain tally was exactly the gap the review caught: 3 sites covered, 4
# more silently defaulting to "code" via the untouched top-of-function
# reset, with zero regression signal — a future site added the same way
# would go missing again just as quietly. This check instead structurally
# ties every FAIL site to a nearby classification, so a new unclassified
# site fails LOUDLY instead of silently inheriting "code". The one
# legitimate exception (the ga-nooaw self-check, which relies on
# gate_bead_has_prior_sha_fail already having filtered to code-only-or-
# legacy shas before it ever sets OVERALL_VERDICT — see that block's own
# header comment) is allowlisted by proximity to that specific call, not by
# position, so reordering the function doesn't silently break the exemption.
echo "── 6c. drift guard: every FAIL site in gate_finalize_run() is classified (or the one documented exemption) ──"

FINALIZE_START=$(grep -n '^gate_finalize_run() {' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
FINALIZE_START=${FINALIZE_START:-0}
FINALIZE_REL_END=""
if [ "$FINALIZE_START" -gt 0 ]; then
  FINALIZE_REL_END=$(tail -n "+$((FINALIZE_START + 1))" "$DISPATCHER" | grep -n '^[A-Za-z_][A-Za-z0-9_]*() {' | head -1 | cut -d: -f1 || true)
fi

if [ "$FINALIZE_START" -eq 0 ] || [ -z "$FINALIZE_REL_END" ]; then
  bad "could not bound gate_finalize_run()'s body (renamed/moved?) — drift guard 6c cannot run"
else
  FINALIZE_END=$((FINALIZE_START + FINALIZE_REL_END))  # absolute line of the NEXT top-level function (exclusive bound)

  VERDICT_REL_LINES=$(sed -n "${FINALIZE_START},$((FINALIZE_END - 1))p" "$DISPATCHER" | grep -n 'OVERALL_VERDICT="FAIL"' | cut -d: -f1 || true)
  VERDICT_LINES=()
  for rel in $VERDICT_REL_LINES; do
    VERDICT_LINES+=($((FINALIZE_START + rel - 1)))
  done
  SITE_COUNT=${#VERDICT_LINES[@]}

  # Floor, not an exact count: legitimate new FAIL sites (properly
  # classified) grow this without needing to touch the test. A drop below
  # the known-good count, or an extraction that silently returns zero, is
  # what this guards against — the latter would otherwise make the per-site
  # loop below vacuously "pass" by iterating zero times.
  if [ "$SITE_COUNT" -ge 7 ]; then
    ok "found $SITE_COUNT OVERALL_VERDICT=\"FAIL\" sites in gate_finalize_run() (>=7 floor)"
  else
    bad "expected >=7 OVERALL_VERDICT=\"FAIL\" sites in gate_finalize_run(), found $SITE_COUNT — extraction broken (function renamed?), or a real site disappeared"
  fi

  for i in "${!VERDICT_LINES[@]}"; do
    L=${VERDICT_LINES[$i]}
    NEXTIDX=$((i + 1))
    if [ "$NEXTIDX" -lt "$SITE_COUNT" ]; then
      NEXT=${VERDICT_LINES[$NEXTIDX]}
    else
      NEXT=$FINALIZE_END
    fi
    LOOKBACK=$((L - 10))
    [ "$LOOKBACK" -lt "$FINALIZE_START" ] && LOOKBACK=$FINALIZE_START

    # Captured into variables, not piped straight into `grep -q`: `grep -q`
    # exits as soon as it finds a match, which can SIGPIPE an upstream `sed`
    # still writing the rest of a large range — under this script's own
    # `set -o pipefail`, that flips the PIPELINE's exit status to non-zero
    # even though grep itself DID find the match (reproduced live: failed
    # only on the two largest windows, ~370 and ~728 lines, where the match
    # sits near the top — small windows finished writing before grep could
    # close early, so they never tripped it). A drift guard giving a false
    # NEGATIVE on its own account is worse than not existing — same
    # misattributed-exit-status family as `cmd | head; echo $?`.
    EXEMPT_WINDOW=$(sed -n "${LOOKBACK},${L}p" "$DISPATCHER")
    if [[ "$EXEMPT_WINDOW" == *gate_bead_has_prior_sha_fail* ]]; then
      ok "FAIL site at line $L: documented exemption (ga-nooaw self-check, already gated to code-only-or-legacy shas)"
      continue
    fi

    CLASS_WINDOW=$(sed -n "${L},$((NEXT - 1))p" "$DISPATCHER")
    if [[ "$CLASS_WINDOW" == *GATE_SHA_FAIL_CLASS=* ]]; then
      ok "FAIL site at line $L: classifies GATE_SHA_FAIL_CLASS before line $NEXT"
    else
      bad "FAIL site at line $L sets OVERALL_VERDICT=\"FAIL\" but never assigns GATE_SHA_FAIL_CLASS before line $NEXT — silently defaults to \"code\" via the top-of-function reset (the exact ga-3ipxu review class of bug). Classify it explicitly, or if it's a genuine code-content rejection needing the default, extend this guard's exemption check with a named reason instead of leaving it silently unclassified."
    fi
  done
fi

# ── 7. syntax ──────────────────────────────────────────────────────────────
echo "── 7. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
