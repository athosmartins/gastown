#!/usr/bin/env bash
# gate-guard-submission-time-coherence.selftest.sh — Prove the ga-pj5va fix:
# a branch whose commit range never cites its own bead id is now refused at
# SUBMISSION time (quality-gate-guard.sh, ~2 min after /gate-done) instead of
# only breaking hours later at MERGE time (quality-gate-dispatcher.sh's Step
# 10, which then escalates to gate:needs-human waiting on a person).
#
# BACKSTORY: fix-attempt-1 (gate_run=ga-xvn9w) tried to solve the same real
# problem — a sliced sub-bead (wa-awya7) whose commit cites only its PARENT
# (wa-cuk7o) — by WIDENING quality-gate-dispatcher.sh's merge-time reader
# check (branch_bead_commit_verdict) to also accept a bead merely co-mentioned
# in the target bead's own title+description. Gate review FAILED it: bare
# co-mention is not proof of a declared relationship, and it reopens the
# exact ga-y9a1d incident class (content merged under the wrong bead's
# identity) that check exists to catch. The corrected design (this bead,
# rewritten by the Mayor after the FAIL) fixes the WRITER instead of loosening
# the READER: quality-gate-dispatcher.sh's branch_bead_commit_verdict stays
# permanently strict (see gate-branch-content-coherence.selftest.sh, which
# re-proves this at 45/45 — the exact pre-ga-pj5va baseline). This harness
# covers the NEW half: the submission-time refusal in quality-gate-guard.sh.
#
# Three layers, matching this codebase's own established conventions for
# guard.sh (see quality-gate-guard.selftest.sh for layer 1, gate-main-branch-
# close.selftest.sh for layer 3):
#   1. Pure-function unit tests (GATE_GUARD_LIB_ONLY=1 sourcing).
#   2. Real-git plumbing composition against a temp repo WITH an origin
#      remote (proves the exact fetch/rev-parse/merge-base/rev-list/log
#      sequence the live check runs, not just the isolated pure function).
#   3. Drift guards on the live script (definition placement, param count in
#      BOTH copies, wiring, ordering).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

for f in "$GUARD" "$DISPATCHER"; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }
done

bash -n "$GUARD" && ok "guard passes bash -n syntax check" || bad "guard has syntax errors"
bash -n "$DISPATCHER" && ok "dispatcher passes bash -n syntax check" || bad "dispatcher has syntax errors"

# ── 1. Pure function: guard.sh's own copy of branch_bead_commit_verdict ──────
echo "── 1. branch_bead_commit_verdict (guard.sh copy): pure decision cases ──"

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail, which leaks into this
        # shell (sourced, not subprocessed) and silently kills the rest of
        # this harness on the first non-zero command — same fix as
        # quality-gate-guard.selftest.sh uses for the identical reason.

if ! type branch_bead_commit_verdict >/dev/null 2>&1; then
  bad "FATAL: branch_bead_commit_verdict not defined after LIB_ONLY sourcing — cannot continue section 1/2"
else
  eq "own bead cited directly → yes" \
    "$(branch_bead_commit_verdict "1" "fix(ga-500): unrelated-looking but self-cited work" "ga-500")" "yes"

  eq "range non-empty, bead never mentioned → no (the ga-y9a1d signature)" \
    "$(branch_bead_commit_verdict "3" "fix(ga-nawd3): a
fix bug ga-jeicm: b
fix(ga-hhj7u): c" "ga-fic5d")" "no"

  # ga-pj5va's own motivating case: wa-awya7 cites only its PARENT wa-cuk7o.
  # Unlike the dispatcher's MERGE-time check (which also says 'no' here, by
  # design — see gate-branch-content-coherence.selftest.sh section 1c), THIS
  # check now catches it much earlier, at submission — that's the whole
  # point of ga-pj5va: fail cheap and fast, not loosen the safety net.
  eq "wa-awya7 real case: commit cites only parent wa-cuk7o, never itself → no (caught at submission now, not just at merge)" \
    "$(branch_bead_commit_verdict "1" "feat(wa-cuk7o item 1): agenda a fila de identidade no launchd" "wa-awya7")" "no"

  eq "multi-commit: only the first cites the bead → yes (checks the whole range)" \
    "$(branch_bead_commit_verdict "2" "fix(ga-3b8): part 1
chore: unrelated follow-up cleanup" "ga-3b8")" "yes"

  eq "empty range (already caught up) → skip, not a false no" \
    "$(branch_bead_commit_verdict "0" "" "ga-500")" "skip"

  eq "unparseable count → skip (fail-safe)" \
    "$(branch_bead_commit_verdict "" "fix(ga-500): x" "ga-500")" "skip"

  eq "empty bead id → skip (fail-safe, never a false no on unresolved input)" \
    "$(branch_bead_commit_verdict "1" "fix(ga-500): x" "")" "skip"

  eq "anchored match: sibling id that only STARTS with the target does not false-negative-match (ga-unjpf class) → no" \
    "$(branch_bead_commit_verdict "1" "fix(ga-3b812): unrelated longer id" "ga-3b8")" "no"
fi

# ── 2. Real-git plumbing composition, WITH an origin remote ──────────────────
# The live check runs: git fetch origin main <branch> && rev-parse origin/main
# && rev-parse origin/<branch> && merge-base && rev-list --count && log
# --format=%B. Section 1 above only proves the isolated pure function; this
# proves that exact sequence composes correctly against a real repo shaped
# like a registered rig (a local clone with a real 'origin' remote) — not a
# simplified stand-in.
echo "── 2. real-git integration: fetch/rev-parse/merge-base/rev-list/log against a real origin remote ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-pj5va-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

ORIGIN_DIR="$TMPD/origin.git"
CLONE_DIR="$TMPD/rig-clone"

git init -q --bare "$ORIGIN_DIR"
# A bare repo's HEAD defaults to refs/heads/master (or whatever
# init.defaultBranch says) regardless of what gets pushed later — without
# this, HEAD can point at a ref that never comes to exist (only "main" ever
# gets pushed below), and `git clone` silently leaves the working tree empty
# ("remote HEAD refers to nonexistent ref") instead of erroring loudly.
git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main

git init -q -b main "$TMPD/seed"
git -C "$TMPD/seed" config user.email "test@gascity.local"
git -C "$TMPD/seed" config user.name "Test"
echo "base" > "$TMPD/seed/f.txt"
git -C "$TMPD/seed" add f.txt
git -C "$TMPD/seed" commit -q -m "base"
git -C "$TMPD/seed" remote add origin "$ORIGIN_DIR"
git -C "$TMPD/seed" push -q origin main

git clone -q "$ORIGIN_DIR" "$CLONE_DIR"
git -C "$CLONE_DIR" config user.email "test@gascity.local"
git -C "$CLONE_DIR" config user.name "Test"

# Branch A: commits cite a DIFFERENT bead only (the ga-pj5va motivating shape
# — could be a parent epic, could be someone else's work entirely; from this
# check's perspective the signature is identical, by design).
git -C "$CLONE_DIR" checkout -q -b fix/ga-fic5d-no-self-cite
echo "w1" >> "$CLONE_DIR/f.txt"
git -C "$CLONE_DIR" commit -qam "feat(wa-cuk7o item 1): parent-only citation, no reference to the target bead"
git -C "$CLONE_DIR" push -q origin fix/ga-fic5d-no-self-cite

# Branch B: commit cites its own bead — the control.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b fix/ga-fic5d-self-cite
echo "w2" >> "$CLONE_DIR/f.txt"
git -C "$CLONE_DIR" commit -qam "fix(ga-fic5d): the actual deliverable"
git -C "$CLONE_DIR" push -q origin fix/ga-fic5d-self-cite

# A second, independent local clone stands in for RIG_PATH — the guard never
# runs inside the submitter's own worktree, it fetches into the registered
# rig's own local checkout. Prove the check doesn't depend on any local state
# left over from creating the branches above.
RIG_PATH="$TMPD/rig-registered-copy"
git clone -q "$ORIGIN_DIR" "$RIG_PATH"
git -C "$RIG_PATH" config user.email "test@gascity.local"
git -C "$RIG_PATH" config user.name "Test"

run_live_check() {
  # Mirrors the EXACT sequence in quality-gate-guard.sh's Step 5b-pre block.
  local branch="$1" bead="$2"
  git -C "$RIG_PATH" fetch origin main "$branch" --quiet 2>/dev/null || true
  local main_sha branch_sha base count msgs
  main_sha=$(git -C "$RIG_PATH" rev-parse "origin/main" 2>/dev/null || echo "")
  branch_sha=$(git -C "$RIG_PATH" rev-parse "origin/$branch" 2>/dev/null || echo "")
  [ -z "$main_sha" ] || [ -z "$branch_sha" ] && { echo "FETCH-FAILED"; return; }
  base=$(git -C "$RIG_PATH" merge-base "$branch_sha" "$main_sha" 2>/dev/null || echo "")
  [ -z "$base" ] && { echo "FETCH-FAILED"; return; }
  count=$(git -C "$RIG_PATH" rev-list --count "${base}..${branch_sha}" 2>/dev/null || echo "")
  msgs=$(git -C "$RIG_PATH" log --format='%B' "${base}..${branch_sha}" 2>/dev/null || echo "")
  branch_bead_commit_verdict "$count" "$msgs" "$bead"
}

eq "real-git+origin: branch citing only a different bead vs ga-fic5d → no" \
  "$(run_live_check fix/ga-fic5d-no-self-cite ga-fic5d)" "no"

eq "real-git+origin: branch citing its own bead vs ga-fic5d → yes" \
  "$(run_live_check fix/ga-fic5d-self-cite ga-fic5d)" "yes"

eq "real-git+origin: branch already caught up with main (main itself) → skip, not a false no" \
  "$(run_live_check main ga-fic5d)" "skip"

eq "real-git+origin: nonexistent branch on origin (fetch/rev-parse fails) → fails open, never crashes" \
  "$(run_live_check fix/does-not-exist ga-fic5d)" "FETCH-FAILED"

rm -rf "$TMPD"
trap - EXIT

# ── 3. DRIFT GUARDS on the live scripts ───────────────────────────────────────
echo "── 3. drift guards: placement, param count (both copies), wiring, ordering ──"

# 3a. ga-zdkn1-class regression: the pure function MUST be defined before the
# GATE_GUARD_LIB_ONLY cutoff, or lib-only test sourcing (this very harness)
# silently stops seeing it, exactly like ga-zdkn1 already documented once in
# this same file for gc_json_or_unknown/resolve_author_agent_alias.
DEF_LINE=$(grep -n "^branch_bead_commit_verdict() {" "$GUARD" | head -1 | cut -d: -f1)
CUTOFF_LINE=$(grep -n 'GATE_GUARD_LIB_ONLY:-' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: branch_bead_commit_verdict (L$DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): branch_bead_commit_verdict def=${DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing} — function moved past the lib-only cutoff, tests can no longer see it"
fi

# 3b. Param count stays 3 in BOTH copies — no own_text 4th param, ever again.
for pair in "guard.sh:$GUARD" "dispatcher.sh:$DISPATCHER"; do
  name="${pair%%:*}"; file="${pair#*:}"
  PLINE=$(grep -n '^branch_bead_commit_verdict() {' "$file" | head -1 | cut -d: -f1)
  if [ -z "$PLINE" ]; then
    bad "$name: branch_bead_commit_verdict not found at all"
    continue
  fi
  PARAMS=$(sed -n "$((PLINE+1))p" "$file")
  case "$PARAMS" in
    *'local count="$1" messages="$2" bead="$3"'*)
      # exactly this — and NOT followed by a 4th own_text default anywhere
      # in the next 3 lines (own_text could be added on its own line too).
      OWNTEXT_NEARBY=$(sed -n "$((PLINE+1)),$((PLINE+4))p" "$file" | grep -c 'own_text' || true)
      if [ "${OWNTEXT_NEARBY:-0}" = "0" ]; then
        ok "$name: branch_bead_commit_verdict is strict 3-arg-only (no own_text)"
      else
        bad "REGRESSION ga-pj5va: $name's branch_bead_commit_verdict has own_text back in its param area"
      fi
      ;;
    *)
      bad "REGRESSION ga-pj5va: $name's branch_bead_commit_verdict param line changed unexpectedly: $PARAMS"
      ;;
  esac
done

# 3c. Neither file has ANY live own_text/GATE_BEAD_OWN_TEXT variable usage —
# broader net than 3b, catches a reintroduction anywhere else in either file
# (e.g. a new call site resurrecting the resolved-bead-text plumbing), not
# just at the function signature. Comments that merely NAME the concept for
# historical context (this harness's own header, guard.sh's own explanatory
# comment above the function) are expected and fine — this checks for the
# EXECUTABLE shapes only: a variable assignment or a 4th positional arg.
for pair in "guard.sh:$GUARD" "dispatcher.sh:$DISPATCHER"; do
  name="${pair%%:*}"; file="${pair#*:}"
  LIVE_HITS=$(grep -cE '(^|[^A-Za-z_])(own_text|GATE_BEAD_OWN_TEXT)=|"\$(GATE_BEAD_OWN_TEXT|own_text)"' "$file" || true)
  if [ "${LIVE_HITS:-0}" = "0" ]; then
    ok "$name: no live own_text/GATE_BEAD_OWN_TEXT variable usage anywhere in the file"
  else
    bad "REGRESSION ga-pj5va: $name has $LIVE_HITS live own_text/GATE_BEAD_OWN_TEXT usage(s) — the reverted feature may be back"
  fi
done

# 3d. The Step 5b-pre check block exists and is wired: calls the pure
# function, checks for 'no', sets gate-status:error, and exits 1 — the same
# refusal shape as the pre-existing VALIDATION_OK=false block (Step 4), not
# a silent skip or a mere log line.
grep -q 'Step 5b-pre (ga-pj5va)' "$GUARD" \
  && ok "guard.sh: Step 5b-pre (ga-pj5va) block present" \
  || bad "guard.sh: Step 5b-pre (ga-pj5va) block MISSING"

grep -q '_CBC_VERDICT=\$(branch_bead_commit_verdict' "$GUARD" \
  && ok "guard.sh: the new block actually calls branch_bead_commit_verdict" \
  || bad "guard.sh: new block does not call branch_bead_commit_verdict"

CBC_BLOCK=$(awk '/Step 5b-pre \(ga-pj5va\)/,/^fi$/' "$GUARD")
echo "$CBC_BLOCK" | grep -q '"\$_CBC_VERDICT" = "no"' \
  && ok "guard.sh: refusal is gated on verdict = no (not != yes — skip must NOT refuse)" \
  || bad "guard.sh: refusal condition missing or too broad (would refuse on skip too)"
echo "$CBC_BLOCK" | grep -q 'set_gate_status "\$MARKER_ID" "error"' \
  && ok "guard.sh: refusal sets gate-status:error (re-submittable, matches Step 4's convention)" \
  || bad "guard.sh: refusal does not set gate-status:error"
echo "$CBC_BLOCK" | grep -q 'exit 1' \
  && ok "guard.sh: refusal actually exits 1 (does not fall through to Step 7)" \
  || bad "guard.sh: refusal does not exit — sweep would continue to Step 7 anyway"
echo "$CBC_BLOCK" | grep -q 'git commit --allow-empty' \
  && ok "guard.sh: refusal comment gives the author an actionable 30-second fix" \
  || bad "guard.sh: refusal comment is not actionable"

# 3e. Ordering: the check runs AFTER RIG_PATH is resolved (it depends on it)
# and BEFORE Step 7 parks the marker as gate-status:queued (the actual
# 'enfileirar' point — refusing after that would be pointless, the marker
# would already be eligible for the autonomous dispatcher).
RIGPATH_LINE=$(grep -n '\[ -d "\$RIG_PATH" \] || RIG_PATH=""' "$GUARD" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'Step 5b-pre (ga-pj5va)' "$GUARD" | head -1 | cut -d: -f1)
QUEUED_LINE=$(grep -n 'label add    "\$MARKER_ID" "gate-status:queued"' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$RIGPATH_LINE" ] && [ -n "$CHECK_LINE" ] && [ "$RIGPATH_LINE" -lt "$CHECK_LINE" ]; then
  ok "guard.sh: RIG_PATH resolved (L$RIGPATH_LINE) BEFORE the coherence check (L$CHECK_LINE)"
else
  bad "guard.sh: ordering wrong — RIG_PATH=${RIGPATH_LINE:-missing} check=${CHECK_LINE:-missing}, check would run with an unresolved RIG_PATH"
fi

if [ -n "$CHECK_LINE" ] && [ -n "$QUEUED_LINE" ] && [ "$CHECK_LINE" -lt "$QUEUED_LINE" ]; then
  ok "guard.sh: coherence check (L$CHECK_LINE) fires BEFORE the marker is parked gate-status:queued (L$QUEUED_LINE) — genuinely pre-enqueue"
else
  bad "guard.sh: ordering wrong — check=${CHECK_LINE:-missing} queued-park=${QUEUED_LINE:-missing}, check would run too late to prevent enqueueing"
fi

# 3f. The merge-time check in the dispatcher is untouched and still wired at
# all its known call sites (regression guard: this fix must not have
# accidentally deleted or weakened the existing safety net while reverting
# fix-attempt-1/2's own_text changes on top of it).
DISPATCHER_CALLSITES=$(grep -c 'branch_bead_commit_verdict' "$DISPATCHER")
if [ "$DISPATCHER_CALLSITES" -ge 6 ]; then
  ok "dispatcher.sh: branch_bead_commit_verdict still wired at $DISPATCHER_CALLSITES sites (def + doc-ref + 5+ call sites, matching origin/main)"
else
  bad "dispatcher.sh: only $DISPATCHER_CALLSITES branch_bead_commit_verdict references — merge-time check may have been weakened"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
