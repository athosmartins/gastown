#!/usr/bin/env bash
# gate-dispatcher-cross-repo-rescue.selftest.sh (ga-6mir5)
#
# Proves: when a gate marker's resolved rig ($RIG) is WRONG — the branch was
# never in that repo — the dispatcher must NOT treat "absent from the repo we
# guessed" as "absent from origin" and circuit-break. It must sweep every
# OTHER registered rig's origin for the same branch and, on an unambiguous
# single match, self-correct and continue the gate run normally.
#
# Real incident (13/08, wa-sowus): the marker resolved rig=whatsapp_automation
# (derived from the wa- bead-id prefix / the bead-rig: label — see
# gate_cross_repo_branch_probe's own header comment in the dispatcher for the
# full mechanism), but the branch's actual code (a town doctrine fix) was
# pushed to the gascity/root repo. The dispatcher looked for the branch in
# whatsapp_automation, found nothing, and ga-acb permanently parked the
# marker + mailed the author that their work was "ABSENT from origin" and
# gone — when it was never gone, just probed in the wrong repo.
#
# Three layers, each tested at the layer where it actually needs real I/O:
#   1. gate_cross_repo_rescue_classify — pure (0/1/N match-count -> verdict).
#   2. gate_cross_repo_branch_probe    — real git I/O against disposable
#      "rig" repos with real bare origins (a fake match-count can't catch a
#      broken `git ls-remote`/container-rig-path bug; the plumbing must run
#      for real, same posture as ga-tgwq's own 6c section in
#      quality-gate-circuit-break.selftest.sh).
#   3. The inline no-branch-cross-repo-rescue wiring (Step 4, quality-gate-
#      dispatcher.sh) — extracted verbatim (SELFTEST-EXTRACT sentinel) and
#      run under the dispatcher's own `set -euo pipefail`, with
#      gate_resolve_rig_context/git_rig/rig_resolve_commit stubbed (those
#      have their own dedicated coverage in gate-dispatcher-rig-resolve-
#      noabort.selftest.sh; re-deriving resolve_bead_city's Dolt-probe shape
#      here would test that function again, not this one) and the REAL
#      gate_cross_repo_branch_probe/gate_cross_repo_rescue_classify wired in.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "== gate-dispatcher-cross-repo-rescue.selftest =="

# ── 1+2. Pure classifier + real-git-I/O probe — both defined well before the
#    GATE_DISPATCHER_LIB_ONLY cutoff, so a plain lib-only source exposes them
#    directly (no block extraction needed — same style as
#    quality-gate-circuit-break.selftest.sh's tests of gate_circuit_break_check
#    and gate_no_branch_local_classify/gate_no_branch_probe_local). ──────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
log()  { :; }
warn() { :; }
err()  { :; }

type gate_cross_repo_rescue_classify >/dev/null 2>&1 \
  || { echo "FATAL: gate_cross_repo_rescue_classify not defined (ga-6mir5 missing?)"; exit 1; }
type gate_cross_repo_branch_probe >/dev/null 2>&1 \
  || { echo "FATAL: gate_cross_repo_branch_probe not defined (ga-6mir5 missing?)"; exit 1; }

echo "── 1. gate_cross_repo_rescue_classify: 0/1/N match-count -> verdict ──"
eq "0 matches -> not_found" "$(gate_cross_repo_rescue_classify "0")" "not_found"
eq "1 match -> rescue (unambiguous)" "$(gate_cross_repo_rescue_classify "1")" "rescue"
eq "2 matches -> ambiguous (never guess)" "$(gate_cross_repo_rescue_classify "2")" "ambiguous"
eq "5 matches -> ambiguous" "$(gate_cross_repo_rescue_classify "5")" "ambiguous"
eq "empty (default arg) -> not_found (fail toward the pre-existing circuit-break, not a guess)" \
  "$(gate_cross_repo_rescue_classify "")" "not_found"
eq "garbage count -> ambiguous (fail-safe: never auto-correct on a value that isn't a clean 0/1)" \
  "$(gate_cross_repo_rescue_classify "xx")" "ambiguous"

echo "── 2. gate_cross_repo_branch_probe: real git I/O (throwaway sandbox) ──"
_PB_SANDBOX=$(mktemp -d)
cleanup_pb_sandbox() { [ -n "${_PB_SANDBOX:-}" ] && rm -rf "$_PB_SANDBOX"; }
trap cleanup_pb_sandbox EXIT

mk_rig() {
  # mk_rig <name> [container:0|1] -> creates a real bare "origin" (what the
  # probe actually queries — `ls-remote` never reads a container rig's own
  # local .repo.git content, only its configured origin remote) plus, for a
  # non-container rig, a working copy pointed at it. Echoes the PATH the
  # probe's rig-list entry should carry (top-level dir either way — the
  # probe itself appends .repo.git for the container case). No commits
  # pushed here; push_branch_to_origin populates content on demand, so a rig
  # with nothing pushed to it is a genuine, correctly-empty "doesn't have the
  # branch" fixture — same posture as circuit-break selftest's 6c (real git
  # plumbing, not a faked result).
  local name="$1" container="${2:-0}"
  local bare="$_PB_SANDBOX/$name-origin.git"
  git init -q --bare "$bare"
  if [ "$container" = "1" ]; then
    local top="$_PB_SANDBOX/$name" repogit="$_PB_SANDBOX/$name/.repo.git"
    mkdir -p "$top"
    git init -q --bare "$repogit"
    git --git-dir="$repogit" remote add origin "$bare"
    printf '%s' "$top"
  else
    local work="$_PB_SANDBOX/$name"
    git init -q "$work"
    git -C "$work" config user.email t@t.local; git -C "$work" config user.name T
    git -C "$work" remote add origin "$bare"
    printf '%s' "$work"
  fi
}

push_branch_to_origin() {
  # push_branch_to_origin <rig-name> <branch> — pushes <branch> straight into
  # <rig-name>'s bare origin via a throwaway clone, regardless of
  # container-ness (the probe only ever resolves through origin).
  local name="$1" branch="$2"
  local bare="$_PB_SANDBOX/$name-origin.git"
  local scratch="$_PB_SANDBOX/.scratch-$name-$branch"
  git clone -q "$bare" "$scratch"
  git -C "$scratch" config user.email t@t.local; git -C "$scratch" config user.name T
  git -C "$scratch" checkout -q -b "$branch"
  git -C "$scratch" commit -q --allow-empty -m "seed $branch"
  git -C "$scratch" push -q origin "$branch"
  rm -rf "$scratch"
}

PB_RIG_NOTHING=$(mk_rig "pb-nothing" 0)
PB_RIG_HAS=$(mk_rig "pb-has" 0)
push_branch_to_origin "pb-has" "the-target-branch"
PB_RIG_ALSO_HAS=$(mk_rig "pb-also-has" 0)
push_branch_to_origin "pb-also-has" "the-target-branch"
PB_RIG_CONTAINER=$(mk_rig "pb-container" 1)
push_branch_to_origin "pb-container" "the-target-branch"
PB_EXPECTED_SHA=$(git --git-dir="$_PB_SANDBOX/pb-has-origin.git" rev-parse "the-target-branch")

PB_RIG_JSON=$(printf '{"rigs":[
  {"name":"pb-nothing","path":"%s"},
  {"name":"pb-has","path":"%s"},
  {"name":"pb-excluded-even-though-it-has-it","path":"%s"}
]}' "$PB_RIG_NOTHING" "$PB_RIG_HAS" "$PB_RIG_ALSO_HAS")
# pb-excluded-even-though-it-has-it also carries the branch (pb-also-has) —
# reused here under an excluded name to prove the exclude arg actually
# suppresses a match, not just that the probe can find matches at all.

PB_OUT=$(gate_cross_repo_branch_probe "the-target-branch" "$PB_RIG_JSON" "pb-excluded-even-though-it-has-it")
PB_LINES=$(printf '%s\n' "$PB_OUT" | grep -c . || true)
eq "exactly one match (pb-has); pb-nothing silent, excluded rig suppressed despite having the branch" \
  "$PB_LINES" "1"
case "$PB_OUT" in
  "pb-has"*"$PB_EXPECTED_SHA"*) ok "match line names the right rig and the real sha" ;;
  *) bad "match line wrong — got: $PB_OUT" ;;
esac

PB_OUT_NONE=$(gate_cross_repo_branch_probe "totally-absent-branch" "$PB_RIG_JSON" "")
PB_LINES_NONE=$(printf '%s\n' "$PB_OUT_NONE" | grep -c . || true)
eq "branch nowhere -> zero matches" "$PB_LINES_NONE" "0"

PB_RIG_JSON_AMBIG=$(printf '{"rigs":[{"name":"pb-has","path":"%s"},{"name":"pb-also-has","path":"%s"}]}' \
  "$PB_RIG_HAS" "$PB_RIG_ALSO_HAS")
PB_OUT_AMBIG=$(gate_cross_repo_branch_probe "the-target-branch" "$PB_RIG_JSON_AMBIG" "")
PB_LINES_AMBIG=$(printf '%s\n' "$PB_OUT_AMBIG" | grep -c . || true)
eq "branch present in 2 non-excluded rigs -> probe reports both (classifier decides ambiguity, not the probe)" \
  "$PB_LINES_AMBIG" "2"

PB_RIG_JSON_MISSING=$(printf '{"rigs":[{"name":"pb-gone","path":"%s/does-not-exist"}]}' "$_PB_SANDBOX")
PB_OUT_MISSING=$(gate_cross_repo_branch_probe "the-target-branch" "$PB_RIG_JSON_MISSING" "")
eq "nonexistent rig path -> silently skipped, no crash" "$(printf '%s\n' "$PB_OUT_MISSING" | grep -c . || true)" "0"

PB_RIG_JSON_CONTAINER=$(printf '{"rigs":[{"name":"pb-container","path":"%s"}]}' "$_PB_SANDBOX/pb-container")
PB_OUT_CONTAINER=$(gate_cross_repo_branch_probe "the-target-branch" "$PB_RIG_JSON_CONTAINER" "")
case "$PB_OUT_CONTAINER" in
  "pb-container"*) ok "container rig (.repo.git bare layout) probed correctly via --git-dir" ;;
  *) bad "container rig probe failed — got: $PB_OUT_CONTAINER" ;;
esac

cleanup_pb_sandbox
trap - EXIT

# ── 3. End-to-end: the inline rescue wiring inside Step 4 ────────────────────
# Extracts the live "no-branch-cross-repo-rescue" block verbatim and runs it
# under set -euo pipefail with gate_resolve_rig_context/git_rig/
# rig_resolve_commit STUBBED (dedicated coverage lives in
# gate-dispatcher-rig-resolve-noabort.selftest.sh / this file's own section 2
# above) and the REAL gate_cross_repo_branch_probe/gate_cross_repo_rescue_classify
# extracted alongside it, so the actual decision logic runs for real.
echo "── 3. no-branch-cross-repo-rescue: end-to-end wiring (real-git sandbox) ──"

extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

_E2E_SANDBOX=$(mktemp -d)
cleanup_e2e_sandbox() { [ -n "${_E2E_SANDBOX:-}" ] && rm -rf "$_E2E_SANDBOX"; }
trap cleanup_e2e_sandbox EXIT

mk_e2e_rig() {
  local name="$1"
  local work="$_E2E_SANDBOX/$name" bare="$_E2E_SANDBOX/$name-origin.git"
  git init -q --bare "$bare"
  git init -q "$work"
  git -C "$work" config user.email t@t.local; git -C "$work" config user.name T
  git -C "$work" commit -q --allow-empty -m init
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q origin HEAD:refs/heads/main
  printf '%s' "$work"
}

E2E_WRONG=$(mk_e2e_rig "e2e-wrong")     # the rig the marker mis-resolved to
E2E_RIGHT=$(mk_e2e_rig "e2e-right")     # where the branch actually lives
git -C "$E2E_RIGHT" branch -q the-real-branch HEAD
git -C "$E2E_RIGHT" push -q origin the-real-branch
E2E_EXPECTED_SHA=$(git -C "$E2E_RIGHT" rev-parse the-real-branch)

E2E_ALSO_WRONG=$(mk_e2e_rig "e2e-also-wrong")   # for the not_found negative case

run_rescue_block() {
  # run_rescue_block <dispatcher-file> <initial-rig> <rig-json> -> stdout has
  # "RIG=<x>|BRANCH_SHA=<y>|BD=<call1;call2;...>" on success.
  local file="$1" initial_rig="$2" rig_json="$3"
  local fn_classify fn_probe block
  fn_classify="$(extract_block "$file" "cross-repo-rescue-classify-fn" 2>/dev/null)"
  fn_probe="$(extract_block "$file" "cross-repo-rescue-probe-fn" 2>/dev/null)"
  block="$(extract_block "$file" "no-branch-cross-repo-rescue")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  bash -c '
    set -euo pipefail
    RIG="$1"; RIG_LIST_JSON="$2"; BRANCH="the-real-branch"; BRANCH_SHA=""
    MARKER_ID="test-marker"; GC_CITY="/fake/city"; BD_CALLS=""
    E2E_WRONG="$3"; E2E_RIGHT="$4"

    bd()   { BD_CALLS="$BD_CALLS|$*"; return 0; }
    err()  { :; }
    warn() { :; }
    log()  { :; }

    # Stubs for the collaborators this block calls that this test is not
    # about (dedicated coverage: gate-dispatcher-rig-resolve-noabort.selftest.sh).
    gate_resolve_rig_context() {
      case "$RIG" in
        e2e-wrong)      RIG_PATH="'"$E2E_WRONG"'"; GIT_DIR_PATH="$RIG_PATH"; IS_CONTAINER_RIG=0; return 0 ;;
        e2e-right)      RIG_PATH="'"$E2E_RIGHT"'"; GIT_DIR_PATH="$RIG_PATH"; IS_CONTAINER_RIG=0; return 0 ;;
        *) return 1 ;;
      esac
    }
    git_rig() { git -C "$GIT_DIR_PATH" "$@"; }
    rig_resolve_commit() { git_rig rev-parse --verify -q "$1^{commit}" 2>/dev/null || echo ""; }

    '"$fn_classify"'
    '"$fn_probe"'
    '"$block"'
    printf "RIG=%s|BRANCH_SHA=%s|BD=%s" "$RIG" "$BRANCH_SHA" "$BD_CALLS"
  ' _ "$initial_rig" "$rig_json" "$E2E_WRONG" "$E2E_RIGHT"
}

# ga-6mir5 has its own classify/probe defined earlier in THIS process (lib-only
# sourced above) but the nested bash -c is a fresh shell that inherits no
# functions — extract them from the file verbatim too, same technique as
# gate-dispatcher-rig-resolve-noabort.selftest.sh's run_rig_resolve. These
# sentinels don't exist in the dispatcher (the functions live safely before
# the GATE_DISPATCHER_LIB_ONLY cutoff and don't need one for lib-only
# sourcing) — extract by function boundary instead via a tiny awk, so this
# test has no dependency on a sentinel nobody else needs.
extract_fn() {
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\) \\{" { p=1 }
    p { print }
    p && /^}/ { exit }
  ' "$1"
}
RESCUE_CLASSIFY_FN="$(extract_fn "$DISPATCHER" gate_cross_repo_rescue_classify)"
RESCUE_PROBE_FN="$(extract_fn "$DISPATCHER" gate_cross_repo_branch_probe)"
if [ -z "$RESCUE_CLASSIFY_FN" ] || [ -z "$RESCUE_PROBE_FN" ]; then
  bad "could not extract gate_cross_repo_rescue_classify/gate_cross_repo_branch_probe by function boundary — awk pattern drifted?"
else
  extract_block() {
    local file="$1" name="$2"
    if [ "$name" = "cross-repo-rescue-classify-fn" ]; then printf '%s' "$RESCUE_CLASSIFY_FN"; return 0; fi
    if [ "$name" = "cross-repo-rescue-probe-fn" ]; then printf '%s' "$RESCUE_PROBE_FN"; return 0; fi
    sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" | sed '1d;$d'
  }

  # ── 3a. Rescue: branch absent from the wrongly-resolved rig, present on
  #    exactly one other -> self-correct, no circuit-break, BRANCH_SHA set. ──
  RIG_JSON_RESCUE=$(printf '{"rigs":[{"name":"e2e-wrong","path":"%s"},{"name":"e2e-right","path":"%s"}]}' "$E2E_WRONG" "$E2E_RIGHT")
  OUT_RESCUE=$(run_rescue_block "$DISPATCHER" "e2e-wrong" "$RIG_JSON_RESCUE" 2>&1)
  case "$OUT_RESCUE" in
    "RIG=e2e-right|BRANCH_SHA=$E2E_EXPECTED_SHA|"*)
      ok "rescue: RIG self-corrected to e2e-right and BRANCH_SHA resolved to the real sha (the wa-sowus shape, end-to-end)" ;;
    *) bad "rescue: expected RIG=e2e-right|BRANCH_SHA=$E2E_EXPECTED_SHA — got: $OUT_RESCUE" ;;
  esac
  case "$OUT_RESCUE" in
    *"BD="*" comment "*) ok "rescue: a bd comment documents the self-correction" ;;
    *) bad "rescue: no bd comment left explaining the self-correction — got: $OUT_RESCUE" ;;
  esac

  # ── 3b. Not found: branch absent everywhere -> no rescue, BRANCH_SHA stays
  #    empty, RIG unchanged (falls through to the existing, unmodified
  #    ga-tgwq/ga-acb circuit-break path exactly as before this fix). ────────
  RIG_JSON_GONE=$(printf '{"rigs":[{"name":"e2e-wrong","path":"%s"},{"name":"e2e-also-wrong","path":"%s"}]}' "$E2E_WRONG" "$E2E_ALSO_WRONG")
  OUT_GONE=$(run_rescue_block "$DISPATCHER" "e2e-wrong" "$RIG_JSON_GONE" 2>&1)
  case "$OUT_GONE" in
    "RIG=e2e-wrong|BRANCH_SHA=|"*) ok "not_found: genuinely-gone branch leaves RIG/BRANCH_SHA untouched — existing circuit-break path unaffected" ;;
    *) bad "not_found: expected RIG=e2e-wrong|BRANCH_SHA= (unchanged) — got: $OUT_GONE" ;;
  esac

  # ── 3c. MUTATION TEST — neutralize the fix (classify always says
  #    not_found) and confirm 3a goes RED. Proves this test actually
  #    exercises the wiring, not a tautology (same discipline as the
  #    rig-resolve-noabort selftest's own mutation test). ───────────────────
  MUT="$(mktemp)"
  cp "$DISPATCHER" "$MUT"
  python3 - "$MUT" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
target = "gate_cross_repo_rescue_classify() {\n  local n=\"${1:-0}\"\n"
if target not in text:
    print("MUTATION_ANCHOR_NOT_FOUND", file=sys.stderr)
    sys.exit(1)
# Force the classifier to always report not_found, regardless of match count
# -- neutralizes the rescue while leaving every call site untouched, so a
# regression that silently disables the classify->rescue wiring (not just a
# deleted function) is exactly what this proves is still caught.
mutated = target + "  printf 'not_found'; return 0\n"
text = text.replace(target, mutated, 1)
open(path, 'w').write(text)
PYEOF
  if [ $? -ne 0 ]; then
    bad "mutation-test: could not construct a mutated scratch copy (anchor drifted?)"
  else
    MUT_CLASSIFY_FN="$(extract_fn "$MUT" gate_cross_repo_rescue_classify)"
    MUT_PROBE_FN="$(extract_fn "$MUT" gate_cross_repo_branch_probe)"
    RESCUE_CLASSIFY_FN="$MUT_CLASSIFY_FN"
    RESCUE_PROBE_FN="$MUT_PROBE_FN"
    OUT_MUT=$(run_rescue_block "$MUT" "e2e-wrong" "$RIG_JSON_RESCUE" 2>&1)
    case "$OUT_MUT" in
      "RIG=e2e-wrong|BRANCH_SHA=|"*)
        ok "mutation-test: neutralizing the classifier turns the rescue off — RIG/BRANCH_SHA stay unchanged, assertion 3a would go red (rc verified: not vacuous)" ;;
      *) bad "mutation-test: neutralizing the classifier did NOT change the outcome — got: $OUT_MUT (this test may not actually be exercising the fix)" ;;
    esac
  fi
  rm -f "$MUT"
fi

cleanup_e2e_sandbox
trap - EXIT

# ── 4. Drift guard: functions must still be exported by the dispatcher ───────
echo "── 4. drift guard: new functions present in lib-only mode ──"
type gate_cross_repo_rescue_classify >/dev/null 2>&1 \
  && ok "gate_cross_repo_rescue_classify present in lib-only mode" \
  || bad "gate_cross_repo_rescue_classify MISSING from dispatcher lib-only export (drift!)"
type gate_cross_repo_branch_probe >/dev/null 2>&1 \
  && ok "gate_cross_repo_branch_probe present in lib-only mode" \
  || bad "gate_cross_repo_branch_probe MISSING from dispatcher lib-only export (drift!)"

echo ""
echo "== gate-dispatcher-cross-repo-rescue: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
