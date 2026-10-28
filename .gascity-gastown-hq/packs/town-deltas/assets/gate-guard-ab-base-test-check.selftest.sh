#!/usr/bin/env bash
# gate-guard-ab-base-test-check.selftest.sh — Prove the ga-rstae A/B fix:
# arm B (per gate_ab_arm_for_bead, a pure hash of the bead id) is refused at
# SUBMISSION time when every new/changed *.selftest.sh on the branch passes
# UNMODIFIED against the pre-fix base commit — i.e. the test doesn't actually
# depend on this branch's own diff and proves nothing. Arm A never sees this
# check at all (control, byte-for-byte today's behavior — "A com um aviso"
# is not A, per the bead's own words).
#
# MEASURED MOTIVATION (docs/gate-analysis/2026-08-12-gate-failure-taxonomy.md):
# "teste nao pega o bug" is family #5, 22% of 443 classified blocking issues
# across 1524 gate-runs (2026-07-23..2026-08-12). Doctrine prose already asks
# builders not to do this (test-driven-development's own Iron Law, gate-
# done.md's pre-flight self-audit) and still produces this rate — the next
# degree has to be mechanical verification, not more prose (the taxonomy
# doc's own closing argument).
#
# Three layers, matching this codebase's own established convention (see
# gate-guard-submission-time-coherence.selftest.sh, the sibling this file
# copies its shape from):
#   1. Pure-function unit tests (GATE_GUARD_LIB_ONLY=1 sourcing) — both new
#      functions: gate_ab_arm_for_bead, gate_base_test_verdict. ga-yl1k3w adds
#      the repair-aware cases of the verdict (a selftest that is red on base in
#      its OLD form and green in its NEW form is non-blocking) and, in layer 2,
#      direct tests of gate_base_test_old_state — the one new IO function,
#      which layer 2's mirror loop calls for real instead of copying.
#   2. Real-git plumbing composition against a temp repo WITH an origin
#      remote — proves the exact fetch/rev-parse/merge-base/diff/worktree-
#      add/git-show/run sequence the live check runs, not just the isolated
#      pure functions. This doubles as the bead's own mandatory self-
#      measurement requirement: it reproduces a submission whose test passes
#      on base (must be refused) and one whose test fails on base (must
#      proceed) — the exact family-#5-applied-to-itself proof the bead body
#      demands.
#   3. Drift guards on the live script — placement, wiring, ordering, and
#      that arm A genuinely never reaches the worktree machinery.
#
# ga-hlcfzx9 (portability repairs): a test that is red ONLY on the Linux node and green on
# the mini before and after (ga-9s361xi) is accepted as consertou-portabilidade when the
# source bead DECLARES it (label teste:portabilidade-os) AND the node MEASURES it (base's
# copy red there, the branch's copy green there). Layer 1 covers the verdict word, the node
# rc classes and the declaration read (a fake `bd`); layer 2 covers the node probe with a
# fake mbp-run.sh and the acceptance matrix (a repair is accepted; a test green on BOTH
# systems, an undeclared repair and every case the node cannot answer are not refused for
# the wrong reason); layer 3 pins the wiring and that no code line picks anything by bead id.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
bash -n "$GUARD" && ok "guard passes bash -n syntax check" || bad "guard has syntax errors"

# ── 1. Pure functions: gate_ab_arm_for_bead + gate_base_test_verdict ────────
echo "── 1. pure function unit tests ──"

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail, which leaks into this
        # shell (sourced, not subprocessed) and would silently kill the rest
        # of this harness on the first non-zero command — same fix
        # gate-guard-submission-time-coherence.selftest.sh uses for the
        # identical reason.

if ! type gate_ab_arm_for_bead >/dev/null 2>&1; then
  bad "FATAL: gate_ab_arm_for_bead not defined after LIB_ONLY sourcing — cannot continue section 1"
elif ! type gate_base_test_verdict >/dev/null 2>&1; then
  bad "FATAL: gate_base_test_verdict not defined after LIB_ONLY sourcing — cannot continue section 1"
else
  echo "  -- gate_ab_arm_for_bead --"

  eq "same bead id called twice -> identical arm (stability, not a fresh coin flip each call)" \
    "$(gate_ab_arm_for_bead ga-rstae)" "$(gate_ab_arm_for_bead ga-rstae)"

  eq "empty bead id -> A (fail-open: unresolved input never lands in the arm that can block)" \
    "$(gate_ab_arm_for_bead "")" "A"

  _ARM_OUT=$(gate_ab_arm_for_bead ga-rstae)
  case "$_ARM_OUT" in
    A|B) ok "output is exactly 'A' or 'B', never anything else (got '$_ARM_OUT')" ;;
    *)   bad "output is not A/B: got '$_ARM_OUT'" ;;
  esac

  # Regression pins — hardcoded expected outputs for specific ids, computed
  # once and fixed here. If these ever change, the hash algorithm changed
  # underneath already-submitted beads — exactly the arm-hopping contamination
  # the bead's design forbids (a bead that fails once and resubmits under the
  # SAME id must land in the SAME arm, forever).
  eq "regression pin: ga-rstae -> A" "$(gate_ab_arm_for_bead ga-rstae)" "A"
  eq "regression pin: ga-pj5va -> B" "$(gate_ab_arm_for_bead ga-pj5va)" "B"
  eq "regression pin: ga-sdkqs -> B" "$(gate_ab_arm_for_bead ga-sdkqs)" "B"
  eq "regression pin: ga-kgja -> A"  "$(gate_ab_arm_for_bead ga-kgja)"  "A"

  # Balance sanity over a FIXED (not random — this file must itself be
  # deterministic), realistic-looking sample of 20 ids: both arms must
  # appear. A hash bug that always returns the same arm regardless of input
  # would sail through the stability/pin checks above (a constant function
  # IS "stable") but fails this one.
  SAMPLE_IDS="ga-rstae ga-pj5va ga-sdkqs wa-uthi ga-5crlw ga-qubtx ga-kgja ga-oiu7 ga-art5 ga-31ac ga-y9a1d ga-zdkn1 ga-o64z1 ga-e7zk7 ga-f1ngu ga-jto05 ga-pa36 ga-3h8l ga-u07fn ga-qtc16"
  SAMPLE_A=0; SAMPLE_B=0
  for _id in $SAMPLE_IDS; do
    case "$(gate_ab_arm_for_bead "$_id")" in
      A) SAMPLE_A=$((SAMPLE_A+1)) ;;
      B) SAMPLE_B=$((SAMPLE_B+1)) ;;
    esac
  done
  if [ "$SAMPLE_A" -gt 0 ] && [ "$SAMPLE_B" -gt 0 ]; then
    ok "20-id fixed sample lands in BOTH arms (A=$SAMPLE_A B=$SAMPLE_B) — not a degenerate constant function"
  else
    bad "REGRESSION: 20-id fixed sample is all one arm (A=$SAMPLE_A B=$SAMPLE_B) — hash is degenerate"
  fi

  echo "  -- gate_base_test_verdict --"

  eq "no test files (0,0,0,0) -> sem-teste-novo" \
    "$(gate_base_test_verdict 0 0 0 0)" "sem-teste-novo"

  eq "unparseable detected count (empty) -> nao-consegui-medir, NOT sem-teste-novo (the erro==vazio collapse this whole bead exists to catch — see the function's own header comment)" \
    "$(gate_base_test_verdict "" 0 0 0)" "nao-consegui-medir"

  eq "unparseable detected count (non-numeric) -> nao-consegui-medir" \
    "$(gate_base_test_verdict "abc" 0 0 0)" "nao-consegui-medir"

  eq "1 file, fully measured, passes on base -> passou-na-base (the block case)" \
    "$(gate_base_test_verdict 1 1 1 0)" "passou-na-base"

  eq "1 file, fully measured, fails on base -> reprovou-na-base (the good case)" \
    "$(gate_base_test_verdict 1 1 1 1)" "reprovou-na-base"

  eq "3 files, all pass on base -> passou-na-base" \
    "$(gate_base_test_verdict 3 3 3 0)" "passou-na-base"

  eq "3 files, only ONE fails on base -> reprovou-na-base (one genuine failure is enough to prove something — matches 'ao menos um reprovar' in the bead)" \
    "$(gate_base_test_verdict 3 3 3 1)" "reprovou-na-base"

  eq "2 detected but only 1 copied -> nao-consegui-medir (partial measurement is never treated as proof)" \
    "$(gate_base_test_verdict 2 1 1 0)" "nao-consegui-medir"

  eq "1 detected, copied, but 0 ran (e.g. timeout-killed) -> nao-consegui-medir" \
    "$(gate_base_test_verdict 1 1 0 0)" "nao-consegui-medir"

  eq "2 files, both measured, both fail -> reprovou-na-base" \
    "$(gate_base_test_verdict 2 2 2 2)" "reprovou-na-base"

  # ── ga-yl1k3w: repair-aware verdict (args 5/6 = repaired / unclassified) ──
  # A selftest that is WRONGLY RED on base and is fixed by the branch passes on
  # base in its new form by definition. Before this bead that always landed in
  # passou-na-base = refused, so a test-repair bead was unsatisfiable in arm B.
  echo "  -- gate_base_test_verdict: repair-aware (ga-yl1k3w) --"

  eq "1 modified file, new form passes on base, OLD form failed on base (repaired=1) -> consertou-teste-vermelho (non-blocking)" \
    "$(gate_base_test_verdict 1 1 1 0 1 0)" "consertou-teste-vermelho"

  eq "1 file passes on base and repaired=0 stated explicitly -> still passou-na-base (a test that passes on base in BOTH forms stays refused)" \
    "$(gate_base_test_verdict 1 1 1 0 0 0)" "passou-na-base"

  eq "legacy 4-arg call (no repaired/unclassified) -> passou-na-base, byte-for-byte the pre-ga-yl1k3w answer" \
    "$(gate_base_test_verdict 1 1 1 0)" "passou-na-base"

  eq "2 files, one repair + one that passes in both forms -> consertou-teste-vermelho (at least one discriminating file is enough, same rule as reprovou-na-base)" \
    "$(gate_base_test_verdict 2 2 2 0 1 0)" "consertou-teste-vermelho"

  eq "precedence: a file that FAILS on base beats a repair -> reprovou-na-base (existing meaning untouched)" \
    "$(gate_base_test_verdict 2 2 2 1 1 0)" "reprovou-na-base"

  eq "passing file whose old form could not be classified (unclassified=1) -> nao-consegui-medir, NEVER passou-na-base (uncertainty must not refuse a builder)" \
    "$(gate_base_test_verdict 1 1 1 0 0 1)" "nao-consegui-medir"

  eq "repair + an unclassifiable sibling -> consertou-teste-vermelho (positive evidence present, both non-blocking)" \
    "$(gate_base_test_verdict 2 2 2 0 1 1)" "consertou-teste-vermelho"

  eq "repaired count present-but-EMPTY -> nao-consegui-medir, not collapsed to 0 (which would refuse: the erro==vazio family)" \
    "$(gate_base_test_verdict 1 1 1 0 "" 0)" "nao-consegui-medir"

  eq "repaired count non-numeric -> nao-consegui-medir, not collapsed to 0" \
    "$(gate_base_test_verdict 1 1 1 0 abc 0)" "nao-consegui-medir"

  eq "unclassified count present-but-EMPTY -> nao-consegui-medir" \
    "$(gate_base_test_verdict 1 1 1 0 0 "")" "nao-consegui-medir"

  eq "repaired > detected (impossible counts) -> nao-consegui-medir, inconsistent input is not evidence" \
    "$(gate_base_test_verdict 1 1 1 0 2 0)" "nao-consegui-medir"

  eq "partial measurement wins over a repair claim (2 detected, 1 copied) -> nao-consegui-medir" \
    "$(gate_base_test_verdict 2 1 1 0 1 0)" "nao-consegui-medir"

  eq "no test files + a stray repaired count -> sem-teste-novo (detected=0 still short-circuits)" \
    "$(gate_base_test_verdict 0 0 0 0 1 0)" "sem-teste-novo"

  eq "unparseable detected + a repaired count -> nao-consegui-medir (still not sem-teste-novo)" \
    "$(gate_base_test_verdict "" 0 0 0 1 0)" "nao-consegui-medir"

  # ── ga-hlcfzx9: portability-aware verdict (arg 7 = portable) ──
  # A test red only on ANOTHER OS passes on the mini in both forms, so no mini-side
  # count can ever call it a repair. The 7th count is the node-measured one.
  echo "  -- gate_base_test_verdict: portability-aware (ga-hlcfzx9) --"

  eq "1 file, node-measured portability repair (portable=1) -> consertou-portabilidade" \
    "$(gate_base_test_verdict 1 1 1 0 0 0 1)" "consertou-portabilidade"

  eq "portable=0 stated explicitly -> still passou-na-base (green on both systems stays refused)" \
    "$(gate_base_test_verdict 1 1 1 0 0 0 0)" "passou-na-base"

  eq "legacy 6-arg call (no portable) -> passou-na-base, byte-for-byte the pre-ga-hlcfzx9 answer" \
    "$(gate_base_test_verdict 1 1 1 0 0 0)" "passou-na-base"

  eq "legacy 4-arg call (no repaired/unclassified/portable) -> passou-na-base" \
    "$(gate_base_test_verdict 1 1 1 0)" "passou-na-base"

  eq "precedence: a file that FAILS on base beats a portability repair -> reprovou-na-base (existing meaning untouched)" \
    "$(gate_base_test_verdict 2 2 2 1 0 0 1)" "reprovou-na-base"

  eq "precedence: a mini-side repair beats a portability repair -> consertou-teste-vermelho (the older, stronger proof keeps its word)" \
    "$(gate_base_test_verdict 2 2 2 0 1 0 1)" "consertou-teste-vermelho"

  eq "portability repair + an unclassifiable sibling -> consertou-portabilidade (positive evidence present, both non-blocking)" \
    "$(gate_base_test_verdict 2 2 2 0 0 1 1)" "consertou-portabilidade"

  eq "portability repair + a sibling that is green on both systems (portable=1, rest uncounted) -> consertou-portabilidade (one discriminating file is enough, same rule as the others)" \
    "$(gate_base_test_verdict 2 2 2 0 0 0 1)" "consertou-portabilidade"

  eq "portable count present-but-EMPTY -> nao-consegui-medir, not collapsed to 0 (erro==vazio: 0 would refuse)" \
    "$(gate_base_test_verdict 1 1 1 0 0 0 "")" "nao-consegui-medir"

  eq "portable count non-numeric -> nao-consegui-medir, not collapsed to 0" \
    "$(gate_base_test_verdict 1 1 1 0 0 0 abc)" "nao-consegui-medir"

  eq "portable count negative-looking ('-1') -> nao-consegui-medir" \
    "$(gate_base_test_verdict 1 1 1 0 0 0 -1)" "nao-consegui-medir"

  eq "portable > detected (impossible counts) -> nao-consegui-medir, inconsistent input is not evidence" \
    "$(gate_base_test_verdict 1 1 1 0 0 0 2)" "nao-consegui-medir"

  eq "repaired + unclassified + portable > detected (each fits alone, the SUM does not) -> nao-consegui-medir" \
    "$(gate_base_test_verdict 2 2 2 0 1 1 1)" "nao-consegui-medir"

  eq "partial measurement wins over a portability claim (2 detected, 1 copied) -> nao-consegui-medir" \
    "$(gate_base_test_verdict 2 1 1 0 0 0 1)" "nao-consegui-medir"

  eq "no test files + a stray portable count -> sem-teste-novo (detected=0 still short-circuits)" \
    "$(gate_base_test_verdict 0 0 0 0 0 0 1)" "sem-teste-novo"

  eq "unparseable detected + a portable count -> nao-consegui-medir (still not sem-teste-novo)" \
    "$(gate_base_test_verdict "" 0 0 0 0 0 1)" "nao-consegui-medir"

  eq "an unclassified file and NO positive evidence -> nao-consegui-medir (portable=0 does not turn doubt into a refusal)" \
    "$(gate_base_test_verdict 1 1 1 0 0 1 0)" "nao-consegui-medir"
fi

# ── ga-hlcfzx9: the pure rc classifier, and the declaration read ─────────────
if ! type gate_base_test_node_rc_class >/dev/null 2>&1 \
   || ! type gate_base_test_portability_declared >/dev/null 2>&1 \
   || ! type gate_base_test_node_state >/dev/null 2>&1; then
  bad "FATAL: gate_base_test_node_rc_class / _portability_declared / _node_state not all defined after LIB_ONLY sourcing (ga-hlcfzx9)"
else
  echo "  -- gate_base_test_node_rc_class (ga-hlcfzx9) --"
  # What one run of a selftest on the Linux node means. Only a PROVEN red may be "red":
  # 96..99 are mbp-run.sh saying "the node did not run it", 124 a timeout, >=128 a signal.
  for _rc in 0; do
    eq "node rc $_rc -> green" "$(gate_base_test_node_rc_class "$_rc")" "green"
  done
  for _rc in 1 2 3 50 95; do
    eq "node rc $_rc (the selftest's own failure, propagated) -> red" "$(gate_base_test_node_rc_class "$_rc")" "red"
  done
  for _rc in 126 127; do
    eq "node rc $_rc (a command in it could not be executed / found there: the very ga-9s361xi failure) -> red" \
      "$(gate_base_test_node_rc_class "$_rc")" "red"
  done
  for _rc in 96 97 98 99; do
    eq "node rc $_rc (mbp-run.sh: node off / paused / unhealthy / busy / usage — the test never ran there) -> unknown, NOT red" \
      "$(gate_base_test_node_rc_class "$_rc")" "unknown"
  done
  eq "node rc 124 (timeout: would it have failed or only needed longer?) -> unknown, NOT red" \
    "$(gate_base_test_node_rc_class 124)" "unknown"
  for _rc in 100 125 128 130 137 143 255 256 999; do
    eq "node rc $_rc (signal / out of the convention) -> unknown" "$(gate_base_test_node_rc_class "$_rc")" "unknown"
  done
  eq "node rc EMPTY -> unknown (erro==vazio: not green, not red)" "$(gate_base_test_node_rc_class "")" "unknown"
  eq "node rc non-numeric -> unknown" "$(gate_base_test_node_rc_class abc)" "unknown"
  eq "node rc '-1' -> unknown" "$(gate_base_test_node_rc_class -1)" "unknown"
  eq "node rc '1.5' -> unknown" "$(gate_base_test_node_rc_class 1.5)" "unknown"
  eq "node rc with leading zeros ('007', '08' — must not be read as octal) -> red" \
    "$(gate_base_test_node_rc_class 007)$(gate_base_test_node_rc_class 08)" "redred"
  eq "node rc classifier always exits 0 (safe under the guard's set -e)" \
    "$(gate_base_test_node_rc_class 137 >/dev/null; echo $?)" "0"

  echo "  -- gate_base_test_portability_declared (ga-hlcfzx9) --"
  # A fake `bd` on PATH: prints the file named by FAKE_BD_OUT_FILE, exits FAKE_BD_RC, and logs its
  # arguments, so the test can see both what the function was told and what it asked bd.
  _PT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gate-hlcfzx9-decl.XXXXXX")
  mkdir -p "$_PT_DIR/bin" "$_PT_DIR/empty"
  cat > "$_PT_DIR/bin/bd" <<'FAKEBDEOF'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_BD_LOG:-/dev/null}"
[ -n "${FAKE_BD_OUT_FILE:-}" ] && cat "$FAKE_BD_OUT_FILE"
exit "${FAKE_BD_RC:-0}"
FAKEBDEOF
  chmod +x "$_PT_DIR/bin/bd"
  _decl() {  # _decl <json-or-@raw> [rc] [bead]  -> what the function answers for that bd output
    printf '%s' "$1" > "$_PT_DIR/out.json"
    PATH="$_PT_DIR/bin:$PATH" FAKE_BD_OUT_FILE="$_PT_DIR/out.json" FAKE_BD_RC="${2:-0}" \
      gate_base_test_portability_declared /fake/store "${3:-ga-x}"
  }
  eq "declared: record carries teste:portabilidade-os (bd show --json array form) -> yes" \
    "$(_decl '[{"id":"ga-x","labels":["gate:g","teste:portabilidade-os","p3"]}]')" "yes"
  eq "declared: same label on a bare object -> yes" \
    "$(_decl '{"id":"ga-x","labels":["teste:portabilidade-os"]}')" "yes"
  eq "declared: record read, other labels only -> no" \
    "$(_decl '[{"id":"ga-x","labels":["gate:g","p3"]}]')" "no"
  eq "declared: record read, labels is an empty list -> no" \
    "$(_decl '[{"id":"ga-x","labels":[]}]')" "no"
  eq "declared: record read, NO labels key at all (bd omits it when there are none) -> no, not unknown" \
    "$(_decl '[{"id":"ga-x","title":"t"}]')" "no"
  eq "declared: a label that merely CONTAINS the word ('teste:portabilidade-os-x', 'teste:portabilidade') -> no (exact match only)" \
    "$(_decl '[{"id":"ga-x","labels":["teste:portabilidade-os-x","teste:portabilidade"]}]')" "no"
  eq "declared: not-found answer {\"error\":...} (no labels, would read as 'no') -> unknown" \
    "$(_decl '{"error":"no issues found matching the provided IDs","schema_version":1}')" "unknown"
  eq "declared: bd answered about a DIFFERENT bead -> unknown, never its labels" \
    "$(_decl '[{"id":"ga-other","labels":["teste:portabilidade-os"]}]')" "unknown"
  eq "declared: empty array [] (nothing found) -> unknown" "$(_decl '[]')" "unknown"
  eq "declared: bd prints nothing and exits 0 -> unknown (vazio is not 'no')" "$(_decl '')" "unknown"
  eq "declared: bd output is not JSON -> unknown" "$(_decl 'Error fetching ga-x: boom')" "unknown"
  eq "declared: bd FAILS (rc 1) even with a valid record on stdout -> unknown (falhou is not 'no')" \
    "$(_decl '[{"id":"ga-x","labels":["teste:portabilidade-os"]}]' 1)" "unknown"
  eq "declared: labels is a string, not a list -> unknown" \
    "$(_decl '[{"id":"ga-x","labels":"teste:portabilidade-os"}]')" "unknown"
  eq "declared: labels holds a non-string -> unknown" \
    "$(_decl '[{"id":"ga-x","labels":["teste:portabilidade-os",7]}]')" "unknown"
  eq "declared: labels is null -> no (null is bd's own 'none', same as omitted)" \
    "$(_decl '[{"id":"ga-x","labels":null}]')" "no"
  eq "declared: bd binary not found at all -> unknown" \
    "$(PATH="$_PT_DIR/empty" gate_base_test_portability_declared /fake/store ga-x)" "unknown"
  eq "declared: empty store -> unknown" "$(gate_base_test_portability_declared "" ga-x)" "unknown"
  eq "declared: empty bead id -> unknown" "$(gate_base_test_portability_declared /fake/store "")" "unknown"
  eq "declared: always exits 0 (safe under the guard's set -e even on 'unknown')" \
    "$(PATH="$_PT_DIR/empty" gate_base_test_portability_declared "" "" >/dev/null; echo $?)" "0"
  : > "$_PT_DIR/bd.log"
  printf '%s' '[{"id":"ga-x","labels":["teste:portabilidade-os"]}]' > "$_PT_DIR/out.json"
  PATH="$_PT_DIR/bin:$PATH" FAKE_BD_LOG="$_PT_DIR/bd.log" FAKE_BD_OUT_FILE="$_PT_DIR/out.json" \
    gate_base_test_portability_declared /the/store ga-x >/dev/null
  eq "declared: asks bd exactly 'bd -C <store> show <bead> --json' (the SOURCE bead, in its own store)" \
    "$(cat "$_PT_DIR/bd.log")" "-C /the/store show ga-x --json"
  unset -f _decl
  rm -rf "$_PT_DIR"
fi

if ! type gate_base_test_old_state >/dev/null 2>&1; then
  bad "FATAL: gate_base_test_old_state not defined after LIB_ONLY sourcing (ga-yl1k3w) — cannot classify a modified selftest's OLD form"
fi

# ── 2. Real-git integration: the exact fetch/rev-parse/merge-base/diff/ ─────
#       worktree-add/git-show/run sequence Step 5b-pre2 runs ────────────────
echo "── 2. real-git integration: fetch/merge-base/diff/worktree-add/git-show/run against a real origin remote ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

ORIGIN_DIR="$TMPD/origin.git"
CLONE_DIR="$TMPD/rig-clone"

git init -q --bare "$ORIGIN_DIR"
# A bare repo's HEAD defaults to refs/heads/master (or whatever
# init.defaultBranch says) regardless of what gets pushed later — without
# this, HEAD can point at a ref that never comes to exist (only "main" ever
# gets pushed below) and `git clone` silently leaves the working tree empty.
# Same fix gate-guard-submission-time-coherence.selftest.sh uses.
git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main

git init -q -b main "$TMPD/seed"
git -C "$TMPD/seed" config user.email "test@gascity.local"
git -C "$TMPD/seed" config user.name "Test"
mkdir -p "$TMPD/seed/lib"
cat > "$TMPD/seed/lib/add.sh" <<'SEEDEOF'
add() { echo $(( $1 + $2 )); }
SEEDEOF
# ga-yl1k3w: three selftests that ALREADY EXIST on base, so a branch that touches
# them is a MODIFICATION (diff-filter=M), not an addition. red = wrongly red on
# base (asserts 2+2==5), green = correctly green, slow = an old form that will
# not finish inside the timeout budget.
cat > "$TMPD/seed/lib/red.selftest.sh" <<'REDEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
[ "$(add 2 2)" = "5" ] && exit 0 || exit 1
REDEOF
cat > "$TMPD/seed/lib/green.selftest.sh" <<'GREENEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
[ "$(add 2 2)" = "4" ] && exit 0 || exit 1
GREENEOF
cat > "$TMPD/seed/lib/slow.selftest.sh" <<'SLOWEOF'
#!/usr/bin/env bash
sleep 5
exit 0
SLOWEOF
git -C "$TMPD/seed" add -A
git -C "$TMPD/seed" commit -q -m base
git -C "$TMPD/seed" remote add origin "$ORIGIN_DIR"
git -C "$TMPD/seed" push -q origin main

git clone -q "$ORIGIN_DIR" "$CLONE_DIR"
git -C "$CLONE_DIR" config user.email "test@gascity.local"
git -C "$CLONE_DIR" config user.name "Test"

# Branch A: a selftest that would pass EVEN ON THE UNFIXED BASE — it never
# exercises anything the base lacks, so it proves nothing about this branch.
git -C "$CLONE_DIR" checkout -q -b feat/badtest
mkdir -p "$CLONE_DIR/lib"
cat > "$CLONE_DIR/lib/add.selftest.sh" <<'BADEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
result=$(add 2 2)
[ "$result" = "4" ] && exit 0 || exit 1
BADEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: add trivial selftest that passes regardless of the fix"
git -C "$CLONE_DIR" push -q origin feat/badtest

# Branch B: a selftest that genuinely FAILS on base — it depends on
# add_safe, which base does not have yet.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/goodtest
cat > "$CLONE_DIR/lib/add.selftest.sh" <<'GOODEOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
result=$(add_safe 2 2 2>/dev/null || echo "MISSING")
[ "$result" = "4" ] && exit 0 || exit 1
GOODEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: add selftest for add_safe (not implemented on base)"
git -C "$CLONE_DIR" push -q origin feat/goodtest

# Branch C: no test file touched at all — just a docs change.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/notest
echo "notes" > "$CLONE_DIR/NOTES.md"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "docs: notes, no test files touched"
git -C "$CLONE_DIR" push -q origin feat/notest

# Branch D: 16 new selftest files — exceeds the safety cap (>15), must be
# nao-consegui-medir regardless of their (trivially-passing) content.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/toomanytests
mkdir -p "$CLONE_DIR/manyfiles"
for _n in $(seq 1 16); do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE_DIR/manyfiles/f${_n}.selftest.sh"
done
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: 16 new selftest files, exceeds the measurement cap"
git -C "$CLONE_DIR" push -q origin feat/toomanytests

# ── ga-yl1k3w: branches that MODIFY selftests already on base ────────────────
# Branch E: REPAIRS the wrongly-red selftest (old form red on base, new form
# green on base). Must be non-blocking: consertou-teste-vermelho.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/repair
cat > "$CLONE_DIR/lib/red.selftest.sh" <<'REPAIREOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/add.sh"
[ "$(add 2 2)" = "4" ] && exit 0 || exit 1
REPAIREOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: repair the wrongly-red selftest"
git -C "$CLONE_DIR" push -q origin feat/repair

# Branch F: touches a selftest that was ALREADY green on base and keeps it green
# (passes on base in BOTH forms). Still proves nothing -> passou-na-base.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/noopmod
echo "# cosmetic edit, behavior identical" >> "$CLONE_DIR/lib/green.selftest.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "chore: touch an already-green selftest"
git -C "$CLONE_DIR" push -q origin feat/noopmod

# Branch G: one repair + one brand-new always-green selftest. At least one file
# discriminates -> consertou-teste-vermelho (same at-least-one rule as
# reprovou-na-base).
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/repair-plus-added
git -C "$CLONE_DIR" show feat/repair:lib/red.selftest.sh > "$CLONE_DIR/lib/red.selftest.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE_DIR/lib/extra.selftest.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: repair red selftest and add an unrelated always-green one"
git -C "$CLONE_DIR" push -q origin feat/repair-plus-added

# Branch H: modifies a selftest whose OLD form cannot finish inside the timeout
# budget (run below with a 1s old-form budget). Whether it would have failed is
# unknowable -> nao-consegui-medir, never a refusal.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/oldtimeout
printf '#!/usr/bin/env bash\nexit 0\n' > "$CLONE_DIR/lib/slow.selftest.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: rewrite the slow selftest so it finishes"
git -C "$CLONE_DIR" push -q origin feat/oldtimeout

# A second, independent local clone stands in for RIG_PATH — the guard never
# runs inside the submitter's own worktree, it operates on the registered
# rig's own local checkout. Proves the check doesn't depend on any local
# state left over from creating the branches above.
RIG_PATH="$TMPD/rig-registered-copy"
git clone -q "$ORIGIN_DIR" "$RIG_PATH"
git -C "$RIG_PATH" config user.email "test@gascity.local"
git -C "$RIG_PATH" config user.name "Test"

run_live_basetest_check() {
  # Mirrors the EXACT git-plumbing sequence in quality-gate-guard.sh's Step
  # 5b-pre2 block, through computing the verdict. The bd/label/comment/
  # refuse side effects need a live city DB and are intentionally NOT
  # exercised here — same scope the sibling selftest's run_live_check()
  # uses for the ga-pj5va check.
  local branch="$1"
  local verdict="nao-consegui-medir"
  local detected=0 copy_ok=0 ran=0 failed=0 repaired=0 unclassified=0
  local base="" test_files=""
  local outside="unknown"   # ga-x4mkk2: "never measured" is NOT 0

  git -C "$RIG_PATH" fetch origin main "$branch" --quiet 2>/dev/null || true
  local main_sha branch_sha
  main_sha=$(git -C "$RIG_PATH" rev-parse "origin/main" 2>/dev/null || echo "")
  branch_sha=$(git -C "$RIG_PATH" rev-parse "origin/$branch" 2>/dev/null || echo "")
  if [ -n "$main_sha" ] && [ -n "$branch_sha" ]; then
    base=$(git -C "$RIG_PATH" merge-base "$branch_sha" "$main_sha" 2>/dev/null || echo "")
  fi

  if [ -n "$base" ]; then
    # ga-x4mkk2: the REAL guard function, not a copy. Count only — `outside` is never
    # an input to the verdict below. It reaches the caller through a FILE because this
    # function runs inside $(...), where a variable assignment would die with the subshell.
    outside=$(gate_base_test_outside_subtree "$RIG_PATH" "$base" "$branch_sha")
    test_files=$(git -C "$RIG_PATH" diff --name-only --diff-filter=AM "${base}..${branch_sha}" -- '*.selftest.sh' 2>/dev/null || echo "")
    [ -n "$test_files" ] && detected=$(printf '%s\n' "$test_files" | grep -c .)

    if [ "$detected" -eq 0 ]; then
      verdict="sem-teste-novo"
    elif [ "$detected" -gt 15 ]; then
      verdict="nao-consegui-medir"
    else
      local wt
      wt=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-wt.XXXXXX" 2>/dev/null || echo "")
      if [ -n "$wt" ] && git -C "$RIG_PATH" worktree add --detach --quiet "$wt" "$base" 2>/dev/null; then
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          mkdir -p "$(dirname "$wt/$f")" 2>/dev/null
          if git -C "$RIG_PATH" show "${branch_sha}:$f" > "$wt/$f" 2>/dev/null; then
            copy_ok=$((copy_ok + 1))
            if timeout 30 bash "$wt/$f" >/dev/null 2>&1; then
              ran=$((ran + 1))
              # ga-yl1k3w: the new form passed on base; ask the REAL guard function
              # (not a copy of it) what base's own copy of this file does on base.
              case "$(gate_base_test_old_state "$RIG_PATH" "$base" "$wt" "$f")" in
                old-fails)         repaired=$((repaired + 1)) ;;
                added|old-passes)  : ;;
                *)                 unclassified=$((unclassified + 1)) ;;
              esac
            else
              rc=$?
              if [ "$rc" != "124" ]; then
                ran=$((ran + 1))
                failed=$((failed + 1))
              fi
            fi
          fi
        done <<TESTFILESEOF
$test_files
TESTFILESEOF
        git -C "$RIG_PATH" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt" 2>/dev/null
      else
        [ -n "$wt" ] && rm -rf "$wt" 2>/dev/null
      fi
      verdict=$(gate_base_test_verdict "$detected" "$copy_ok" "$ran" "$failed" "$repaired" "$unclassified")
    fi
  fi
  if [ -n "${ABT_OUTSIDE_FILE:-}" ]; then printf '%s' "$outside" > "$ABT_OUTSIDE_FILE"; fi
  printf '%s' "$verdict"
}

# ga-x4mkk2: run the mirror and report BOTH what the guard decides and what it counts, from
# the SAME run — "the verdict is unchanged" is only a claim if it is read next to the count.
run_live_check_full() {
  local of v
  of=$(mktemp "${TMPDIR:-/tmp}/gate-xk-outside.XXXXXX")
  v=$(ABT_OUTSIDE_FILE="$of" run_live_basetest_check "$1")
  printf '%s outside-subtree=%s' "$v" "$(cat "$of")"
  rm -f "$of"
}

eq "real-git+origin: badtest (passes unmodified on base) -> passou-na-base (WOULD be refused today)" \
  "$(run_live_basetest_check feat/badtest)" "passou-na-base"

eq "real-git+origin: goodtest (fails on base, depends on the fix) -> reprovou-na-base (proceeds)" \
  "$(run_live_basetest_check feat/goodtest)" "reprovou-na-base"

eq "real-git+origin: notest (no selftest touched) -> sem-teste-novo (proceeds)" \
  "$(run_live_basetest_check feat/notest)" "sem-teste-novo"

eq "real-git+origin: toomanytests (16 files, exceeds cap) -> nao-consegui-medir (proceeds, capped not silently truncated)" \
  "$(run_live_basetest_check feat/toomanytests)" "nao-consegui-medir"

eq "real-git+origin: nonexistent branch (fetch/rev-parse fails) -> nao-consegui-medir, fails open, never crashes" \
  "$(run_live_basetest_check feat/does-not-exist)" "nao-consegui-medir"

# ga-x4mkk2: when the rig IS the repo toplevel there is no "outside" — the count is a MEASURED 0
# (real selftests changed, all of them inside), never a blank; and when no base could be
# resolved it is `unknown`, which must not read as that same 0.
eq "toplevel rig: badtest (a selftest changed, all inside) -> verdict unchanged, outside-subtree=0" \
  "$(run_live_check_full feat/badtest)" "passou-na-base outside-subtree=0"
eq "toplevel rig: notest -> verdict unchanged, outside-subtree=0 (measured zero)" \
  "$(run_live_check_full feat/notest)" "sem-teste-novo outside-subtree=0"
eq "toplevel rig: nonexistent branch (no base) -> nao-consegui-medir, outside-subtree=unknown, NOT 0" \
  "$(run_live_check_full feat/does-not-exist)" "nao-consegui-medir outside-subtree=unknown"

# ── ga-yl1k3w: a selftest REPAIR is satisfiable, a no-op edit is still refused ──
eq "real-git+origin: repair (old form RED on base, new form green) -> consertou-teste-vermelho (non-blocking; before ga-yl1k3w this was passou-na-base = refused)" \
  "$(run_live_basetest_check feat/repair)" "consertou-teste-vermelho"

eq "real-git+origin: noopmod (already-green selftest edited, green in BOTH forms) -> passou-na-base (still refused in arm B — the check's intent survives)" \
  "$(run_live_basetest_check feat/noopmod)" "passou-na-base"

eq "real-git+origin: repair + a brand-new always-green selftest -> consertou-teste-vermelho (at least one discriminating file)" \
  "$(run_live_basetest_check feat/repair-plus-added)" "consertou-teste-vermelho"

eq "real-git+origin: modified selftest whose OLD form times out (1s old-form budget) -> nao-consegui-medir, never a refusal" \
  "$(GATE_ABT_OLD_TIMEOUT=1 run_live_basetest_check feat/oldtimeout)" "nao-consegui-medir"

# Direct three-state tests of the new function (the only new IO in the check).
_OS_BASE=$(git -C "$RIG_PATH" rev-parse origin/main)
_OS_WT=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-oldstate.XXXXXX")
git -C "$RIG_PATH" worktree add --detach --quiet "$_OS_WT" "$_OS_BASE" 2>/dev/null
eq "old_state: file that does not exist on base (an ADDED selftest) -> added" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/brand-new.selftest.sh)" "added"
eq "old_state: base copy red on base -> old-fails" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/red.selftest.sh)" "old-fails"
eq "old_state: base copy green on base -> old-passes" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/green.selftest.sh)" "old-passes"
eq "old_state: base copy that outlives the budget -> unknown (timeout is ambiguous, not a failure)" \
  "$(GATE_ABT_OLD_TIMEOUT=1 gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" lib/slow.selftest.sh)" "unknown"
eq "old_state: unresolvable base sha (ls-tree ERRORS) -> unknown, NOT added (error must not read as 'file absent')" \
  "$(gate_base_test_old_state "$RIG_PATH" "0000000000000000000000000000000000000000" "$_OS_WT" lib/red.selftest.sh)" "unknown"
eq "old_state: empty base -> unknown" \
  "$(gate_base_test_old_state "$RIG_PATH" "" "$_OS_WT" lib/red.selftest.sh)" "unknown"
eq "old_state: empty file arg -> unknown" \
  "$(gate_base_test_old_state "$RIG_PATH" "$_OS_BASE" "$_OS_WT" "")" "unknown"
eq "old_state: always exits 0 (safe under the guard's set -e even on 'unknown')" \
  "$(gate_base_test_old_state "$RIG_PATH" "" "$_OS_WT" x >/dev/null; echo $?)" "0"
git -C "$RIG_PATH" worktree remove --force "$_OS_WT" 2>/dev/null || rm -rf "$_OS_WT" 2>/dev/null

# ── ga-yl1k3w gate feedback 1/3 (gate ga-ql6pdl): the PRODUCTION topology ────
# Every fixture above clones origin as a TOP-LEVEL repo, so RIG_PATH == the repo
# toplevel and a path relative to the -C dir equals a path relative to the root.
# The gascity rig is not shaped like that: its RIG_PATH is a SUBDIRECTORY of the
# repo (/Users/athos/gt/.gascity-gastown-hq inside /Users/athos/gt), while the
# selftest paths the guard feeds gate_base_test_old_state come from
# `git diff --name-only` — ROOT-relative. A plain `git ls-tree` resolves its
# path against the -C dir, exits 0 with EMPTY output for a file that exists on
# base, and the function called a real repair `added` (=> refused). 74/74 stayed
# green with that bug present because no fixture had this shape. This one does.
SUB_ORIGIN="$TMPD/sub-origin.git"
SUB_SEED="$TMPD/sub-seed"
SUB_CLONE="$TMPD/sub-rig-clone"    # the repo TOPLEVEL
SUB_RIG="$SUB_CLONE/sub"           # what the guard is handed as RIG_PATH
git init -q --bare "$SUB_ORIGIN"
git -C "$SUB_ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q -b main "$SUB_SEED"
git -C "$SUB_SEED" config user.email "test@gascity.local"
git -C "$SUB_SEED" config user.name "Test"
mkdir -p "$SUB_SEED/sub/lib"
cp "$TMPD/seed/lib/add.sh" "$TMPD/seed/lib/red.selftest.sh" "$TMPD/seed/lib/green.selftest.sh" "$SUB_SEED/sub/lib/"
# Exit-status boundary fixtures (old-fails must only be claimed for a test that
# RAN and went red; 126/127/signal are "could not tell", not "was red").
printf '#!/usr/bin/env bash\nexit 125\n' > "$SUB_SEED/sub/lib/exit125.selftest.sh"
printf '#!/usr/bin/env bash\nexit 126\n' > "$SUB_SEED/sub/lib/exit126.selftest.sh"
printf '#!/usr/bin/env bash\nexit 127\n' > "$SUB_SEED/sub/lib/exit127.selftest.sh"
cat > "$SUB_SEED/sub/lib/sigkill.selftest.sh" <<'SIGKILLEOF'
#!/usr/bin/env bash
kill -9 $$
SIGKILLEOF
# ga-x4mkk2: selftests that live OUTSIDE the rig subtree (sub/) — the shape of the 4
# selftests (of 304) in the real repo that the arm-B detection, scoped to the -C
# directory, cannot see. sub-other/ shares the "sub" NAME prefix on purpose: a subtree
# test that forgets the trailing slash would file it as inside.
mkdir -p "$SUB_SEED/top/lib" "$SUB_SEED/sub-other/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_SEED/top/lib/outside.selftest.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_SEED/sub-other/lib/sibling.selftest.sh"
git -C "$SUB_SEED" add -A
git -C "$SUB_SEED" commit -q -m base
git -C "$SUB_SEED" remote add origin "$SUB_ORIGIN"
git -C "$SUB_SEED" push -q origin main
git clone -q "$SUB_ORIGIN" "$SUB_CLONE"
git -C "$SUB_CLONE" config user.email "test@gascity.local"
git -C "$SUB_CLONE" config user.name "Test"

# feat/repair-sub: the old red form is fixed to go green (the ga-97tqu7 shape).
git -C "$SUB_CLONE" checkout -q -b feat/repair-sub
git -C "$SUB_CLONE" show main:sub/lib/green.selftest.sh > "$SUB_CLONE/sub/lib/red.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "fix: repair the wrongly-red selftest"
git -C "$SUB_CLONE" push -q origin feat/repair-sub
# feat/noop-sub: an already-green selftest is edited but stays green in BOTH forms.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/noop-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/sub/lib/green.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "chore: touch an already-green selftest"
git -C "$SUB_CLONE" push -q origin feat/noop-sub
# feat/added-sub: a brand-new always-green selftest (there is no old form).
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/added-sub
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_CLONE/sub/lib/brand-new.selftest.sh"
git -C "$SUB_CLONE" add -A
git -C "$SUB_CLONE" commit -q -m "test: add a new always-green selftest"
git -C "$SUB_CLONE" push -q origin feat/added-sub

# ga-x4mkk2 branches: changed selftests OUTSIDE sub/ (the arm-B detection is blind to them).
# feat/outside-only-sub: the ONLY changed selftest is outside the subtree.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-only-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "chore: touch a selftest outside the rig subtree"
git -C "$SUB_CLONE" push -q origin feat/outside-only-sub
# feat/outside-two-sub: TWO outside — one modified, one ADDED four levels deep (proves the
# wildcard crosses directory separators).
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-two-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
mkdir -p "$SUB_CLONE/top/a/b/c"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_CLONE/top/a/b/c/deep.selftest.sh"
git -C "$SUB_CLONE" add -A
git -C "$SUB_CLONE" commit -q -m "test: two selftests outside the rig subtree"
git -C "$SUB_CLONE" push -q origin feat/outside-two-sub
# feat/outside-and-inside-sub: a REPAIR inside the subtree + an edit outside it.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-and-inside-sub
git -C "$SUB_CLONE" show main:sub/lib/green.selftest.sh > "$SUB_CLONE/sub/lib/red.selftest.sh"
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "fix: repair a selftest inside the subtree, touch one outside"
git -C "$SUB_CLONE" push -q origin feat/outside-and-inside-sub
# feat/sibling-prefix-sub: sub-other/ is OUTSIDE sub/ even though its name starts with "sub".
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/sibling-prefix-sub
printf '# cosmetic edit\n' >> "$SUB_CLONE/sub-other/lib/sibling.selftest.sh"
git -C "$SUB_CLONE" commit -q -am "chore: touch a selftest in a sibling dir sharing the sub prefix"
git -C "$SUB_CLONE" push -q origin feat/sibling-prefix-sub
# feat/outside-deleted-sub: an outside selftest is DELETED. The detection filters AM, so the
# count must too — otherwise the two numbers stop being comparable.
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/outside-deleted-sub
git -C "$SUB_CLONE" rm -q "top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" commit -q -m "chore: delete a selftest outside the rig subtree"
git -C "$SUB_CLONE" push -q origin feat/outside-deleted-sub
# feat/nonascii-inside-sub (gate ga-m9ezwi feedback): a selftest INSIDE sub/ whose name is
# non-ASCII, plus one real edit outside. With git's default core.quotePath, `diff --name-only`
# prints the inside path as "sub/lib/caf\303\251.selftest.sh" — quoted, so it no longer starts
# with the "sub/" prefix and would be counted OUTSIDE (2, truth 1).
git -C "$SUB_CLONE" checkout -q main
git -C "$SUB_CLONE" checkout -q -b feat/nonascii-inside-sub
printf '#!/usr/bin/env bash\nexit 0\n' > "$SUB_CLONE/sub/lib/$(printf 'caf\303\251').selftest.sh"
printf '# cosmetic edit\n' >> "$SUB_CLONE/top/lib/outside.selftest.sh"
git -C "$SUB_CLONE" add -A
git -C "$SUB_CLONE" commit -q -m "test: a non-ASCII selftest inside the subtree, one edit outside it"
git -C "$SUB_CLONE" push -q origin feat/nonascii-inside-sub
git -C "$SUB_CLONE" checkout -q main

# Fixture preconditions — without these the block below could pass vacuously.
eq "subdir-topology fixture: RIG_PATH really is a SUBDIRECTORY of the repo toplevel" \
  "$(git -C "$SUB_RIG" rev-parse --show-prefix)" "sub/"
_SS_BASE=$(git -C "$SUB_RIG" rev-parse origin/main)
eq "subdir-topology fixture: a plain ls-tree on the ROOT-relative path is EMPTY from the subdir rig (the failure mode this block guards)" \
  "$(git -C "$SUB_RIG" ls-tree "$_SS_BASE" -- sub/lib/red.selftest.sh)" ""
[ -n "$(git -C "$SUB_RIG" ls-tree --full-tree "$_SS_BASE" -- sub/lib/red.selftest.sh)" ] \
  && ok "subdir-topology fixture: ls-tree --full-tree finds that same path" \
  || bad "subdir-topology fixture: ls-tree --full-tree did not find sub/lib/red.selftest.sh"

_SAVED_RIG_PATH="$RIG_PATH"
RIG_PATH="$SUB_RIG"
eq "subdir rig, real-git+origin: repair (old red, new green) -> consertou-teste-vermelho (was passou-na-base = REFUSED before this fix)" \
  "$(run_live_basetest_check feat/repair-sub)" "consertou-teste-vermelho"
eq "subdir rig, real-git+origin: no-op edit (green in BOTH forms) -> passou-na-base (still refused in arm B)" \
  "$(run_live_basetest_check feat/noop-sub)" "passou-na-base"
eq "subdir rig, real-git+origin: ADDED selftest (no old form) -> passou-na-base (still refused in arm B)" \
  "$(run_live_basetest_check feat/added-sub)" "passou-na-base"

_SS_WT=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-subold.XXXXXX")
git -C "$SUB_RIG" worktree add --detach --quiet "$_SS_WT" "$_SS_BASE" 2>/dev/null
eq "subdir rig, old_state: base copy red on base (root-relative path) -> old-fails, NOT added" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/red.selftest.sh)" "old-fails"
eq "subdir rig, old_state: base copy green on base -> old-passes" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/green.selftest.sh)" "old-passes"
eq "subdir rig, old_state: path genuinely absent on base -> added (--full-tree must not turn absence into an error)" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/brand-new.selftest.sh)" "added"
eq "subdir rig, old_state: unresolvable base sha -> unknown (ls-tree error, not 'added')" \
  "$(gate_base_test_old_state "$SUB_RIG" "0000000000000000000000000000000000000000" "$_SS_WT" sub/lib/red.selftest.sh)" "unknown"
# old-fails is a positive claim ("the old test was red"): only an ordinary failure status may make it.
eq "old_state: old form exits 125 (top of the ordinary-failure range) -> old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/exit125.selftest.sh)" "old-fails"
eq "old_state: old form exits 126 (could not execute) -> unknown, NOT old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/exit126.selftest.sh)" "unknown"
eq "old_state: old form exits 127 (command not found in the bare worktree) -> unknown, NOT old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/exit127.selftest.sh)" "unknown"
eq "old_state: old form killed by SIGKILL (exit 137) -> unknown, NOT old-fails" \
  "$(gate_base_test_old_state "$SUB_RIG" "$_SS_BASE" "$_SS_WT" sub/lib/sigkill.selftest.sh)" "unknown"
git -C "$SUB_RIG" worktree remove --force "$_SS_WT" 2>/dev/null || rm -rf "$_SS_WT" 2>/dev/null
_SS_LEFTOVER=$(git -C "$SUB_RIG" worktree list 2>/dev/null | grep -c -E "gate-rstae-selftest-(wt|subold)" || true)
eq "subdir rig: no leftover linked worktrees after the subdir-topology runs" "${_SS_LEFTOVER:-0}" "0"

# ── ga-x4mkk2: a changed selftest OUTSIDE the rig subtree is counted, never silent ──
# The detection above is scoped to the -C directory (a subdirectory of the repo), so a
# submission whose only changed selftest lives elsewhere reads as sem-teste-novo — the
# same look as "no test at all". Each line below reads the VERDICT and the COUNT from one
# run: the verdict must be exactly what it was before this bead (option 1: detection
# only, the arm-B experiment is untouched) while the count makes the blind spot visible.
eq "subdir rig: ONLY selftest changed is outside sub/ -> verdict unchanged (sem-teste-novo), outside-subtree=1" \
  "$(run_live_check_full feat/outside-only-sub)" "sem-teste-novo outside-subtree=1"
eq "subdir rig: two outside (one modified, one ADDED 4 levels deep) -> outside-subtree=2 (the wildcard crosses directory separators)" \
  "$(run_live_check_full feat/outside-two-sub)" "sem-teste-novo outside-subtree=2"
eq "subdir rig: REPAIR inside + edit outside -> verdict unchanged (consertou-teste-vermelho), outside-subtree=1" \
  "$(run_live_check_full feat/outside-and-inside-sub)" "consertou-teste-vermelho outside-subtree=1"
eq "subdir rig: sub-other/ (name starts with 'sub') is OUTSIDE sub/ -> outside-subtree=1 (subtree test needs the trailing slash)" \
  "$(run_live_check_full feat/sibling-prefix-sub)" "sem-teste-novo outside-subtree=1"
eq "subdir rig: a DELETED outside selftest is not counted (same AM filter as the detection) -> outside-subtree=0" \
  "$(run_live_check_full feat/outside-deleted-sub)" "sem-teste-novo outside-subtree=0"
eq "subdir rig: repair, everything inside -> verdict unchanged, outside-subtree=0 (measured zero, not blank)" \
  "$(run_live_check_full feat/repair-sub)" "consertou-teste-vermelho outside-subtree=0"
eq "subdir rig: no-op edit inside -> still refusable (passou-na-base), outside-subtree=0" \
  "$(run_live_check_full feat/noop-sub)" "passou-na-base outside-subtree=0"
eq "subdir rig: ADDED selftest inside -> still refusable (passou-na-base), outside-subtree=0" \
  "$(run_live_check_full feat/added-sub)" "passou-na-base outside-subtree=0"
eq "subdir rig: nonexistent branch (no base) -> nao-consegui-medir, outside-subtree=unknown, NOT 0" \
  "$(run_live_check_full feat/does-not-exist)" "nao-consegui-medir outside-subtree=unknown"

# Direct three-state tests of the helper itself. `unknown` (could not ask git) must never
# collapse into `0` (asked, and the answer was none) — that is the family-#2 defect this
# whole check exists downstream of, and a blind-spot counter that reads 0 on error would
# hide the blind spot exactly when it is widest.
git -C "$SUB_RIG" fetch -q origin main feat/outside-two-sub 2>/dev/null
_XK_BASE=$(git -C "$SUB_RIG" rev-parse origin/main)
_XK_HEAD=$(git -C "$SUB_RIG" rev-parse origin/feat/outside-two-sub)
_XK_ZERO="0000000000000000000000000000000000000000"
eq "outside_subtree: two outside selftests between base and head -> 2" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_HEAD")" "2"
eq "outside_subtree: empty range (base..base) is a MEASURED zero -> 0" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_BASE")" "0"
eq "outside_subtree: unresolvable head sha (diff ERRORS) -> unknown, NOT 0" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_ZERO")" "unknown"
eq "outside_subtree: unresolvable base sha (diff ERRORS) -> unknown, NOT 0" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_ZERO" "$_XK_HEAD")" "unknown"
eq "outside_subtree: empty rig -> unknown" \
  "$(gate_base_test_outside_subtree "" "$_XK_BASE" "$_XK_HEAD")" "unknown"
eq "outside_subtree: empty base -> unknown" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "" "$_XK_HEAD")" "unknown"
eq "outside_subtree: empty head -> unknown" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "")" "unknown"
_XK_NOTREPO=$(mktemp -d "${TMPDIR:-/tmp}/gate-xk-notrepo.XXXXXX")
eq "outside_subtree: rig is not a git repo -> unknown (an empty diff there must not read as 0)" \
  "$(gate_base_test_outside_subtree "$_XK_NOTREPO" "$_XK_BASE" "$_XK_HEAD")" "unknown"
rmdir "$_XK_NOTREPO" 2>/dev/null
eq "outside_subtree: always exits 0 (safe under the guard's set -e even on 'unknown')" \
  "$(gate_base_test_outside_subtree "" "" "" >/dev/null; echo $?)" "0"

# Gate ga-m9ezwi feedback (blocking): a starved temp file must not read as a measured zero.
# The live guard is launched as /bin/bash (bash 3.2 on the mini), where a here-document is a
# temp FILE. When that file cannot be written (ENOSPC/quota — this city has had >=96% disk),
# bash prints "cannot create temp file for here document", skips the whole loop, and the old
# helper fell through to `printf 0`: an error reading as a measured zero. `ulimit -f 0` with
# SIGXFSZ ignored reproduces the starvation without touching the disk. The selftest itself
# runs under env bash (5.x, pipe-backed here-documents), which never reaches that path — hence
# the explicit /bin/bash child. The answer must be the TRUE count or `unknown`, never a 0.
_XK_HD_PROG='while IFS= read -r l; do echo "read:$l"; done <<E
x
E'
_XK_HD_PROBE=$( ( ulimit -f 0; trap '' XFSZ; /bin/bash -c "$_XK_HD_PROG" ) 2>/dev/null )
_XK_CHILD='GATE_GUARD_LIB_ONLY=1 . "$1"; gate_base_test_outside_subtree "$2" "$3" "$4"'
if [ -z "$_XK_HD_PROBE" ]; then
  _XK_STARVED=$( ( ulimit -f 0; trap '' XFSZ; /bin/bash -c "$_XK_CHILD" _ "$GUARD" "$SUB_RIG" "$_XK_BASE" "$_XK_HEAD" ) 2>/dev/null )
  case "$_XK_STARVED" in
    2|unknown) ok "outside_subtree: /bin/bash with here-document temp files starved -> '$_XK_STARVED' (true count or unknown), never a silent 0" ;;
    *) bad "outside_subtree: /bin/bash with here-document temp files starved -> got '$_XK_STARVED', want the true count 2 or unknown (an error read as a measured value)" ;;
  esac
else
  echo "  skip outside_subtree starved-temp-file case: /bin/bash here-documents are pipe-backed on this host, so the path cannot be exercised here (NOT counted as a pass)"
fi
eq "outside_subtree: same count under /bin/bash (3.2 on the mini) — the counting form parses and runs there" \
  "$(/bin/bash -c "$_XK_CHILD" _ "$GUARD" "$SUB_RIG" "$_XK_BASE" "$_XK_HEAD" 2>/dev/null)" "2"
# The two defensive exits of the counting pipeline cannot be reached with a real git, so shadow
# printf in the child to force them: (1) the pipeline emits something that is not an integer,
# (2) the pipeline itself fails. Either way the answer must be `unknown`, never a number.
_XK_CHILD_GARBAGE='GATE_GUARD_LIB_ONLY=1 . "$1"; printf() { case "$*" in "%s "[0-9]*) builtin printf "%s" "not-a-count" ;; *) builtin printf "$@" ;; esac; }; gate_base_test_outside_subtree "$2" "$3" "$4"'
_XK_CHILD_PIPEFAIL='GATE_GUARD_LIB_ONLY=1 . "$1"; printf() { case "$*" in "%s "[0-9]*) builtin printf "%s" "$2"; return 1 ;; *) builtin printf "$@" ;; esac; }; gate_base_test_outside_subtree "$2" "$3" "$4"'
eq "outside_subtree: the counter emits a non-integer -> unknown, NOT a number (integer-or-unknown is self-enforcing)" \
  "$(/bin/bash -c "$_XK_CHILD_GARBAGE" _ "$GUARD" "$SUB_RIG" "$_XK_BASE" "$_XK_HEAD" 2>/dev/null)" "unknown"
eq "outside_subtree: the counting pipeline itself fails -> unknown, NOT the count it had reached" \
  "$(/bin/bash -c "$_XK_CHILD_PIPEFAIL" _ "$GUARD" "$SUB_RIG" "$_XK_BASE" "$_XK_HEAD" 2>/dev/null)" "unknown"

# Gate ga-m9ezwi feedback (medium): with git's default core.quotePath a non-ASCII path is printed
# quoted, so the "sub/" prefix match fails and an INSIDE selftest is counted OUTSIDE.
git -C "$SUB_RIG" fetch -q origin feat/nonascii-inside-sub 2>/dev/null
_XK_NA=$(git -C "$SUB_RIG" rev-parse origin/feat/nonascii-inside-sub)
eq "nonascii fixture: default git output DOES quote the inside path (the failure mode this block guards)" \
  "$(git -C "$SUB_RIG" -c core.quotePath=true diff --name-only --diff-filter=AM "${_XK_BASE}..${_XK_NA}" -- ':(top)sub/lib/*.selftest.sh' | grep -c '^"')" "1"
eq "outside_subtree: a non-ASCII selftest INSIDE sub/ is not counted outside (1 real outside edit) -> 1" \
  "$(gate_base_test_outside_subtree "$SUB_RIG" "$_XK_BASE" "$_XK_NA")" "1"
RIG_PATH="$_SAVED_RIG_PATH"

# The call site's own third state: gate_base_test_old_state is documented to print
# exactly one word, but if it ever printed NOTHING (killed substitution) or an
# unrecognised word, a `case` with only old-fails/unknown arms would count nothing,
# the file would read "ran, passed, no repair, no doubt", and the verdict would be
# passou-na-base = a REFUSED builder made from "I don't know". noopmod is the
# fixture that is honestly refusable (green in both forms): with a healthy
# function it stays passou-na-base (asserted above); with a function that cannot
# answer it must degrade to nao-consegui-medir.
_REAL_OLDSTATE_DEF=$(declare -f gate_base_test_old_state)
gate_base_test_old_state() { printf ''; return 0; }
eq "call site: old_state prints NOTHING -> nao-consegui-medir, NOT a refusal (don't-know must not become passou-na-base)" \
  "$(run_live_basetest_check feat/noopmod)" "nao-consegui-medir"
gate_base_test_old_state() { printf 'garbage'; return 0; }
eq "call site: old_state prints an UNRECOGNISED word -> nao-consegui-medir, NOT a refusal" \
  "$(run_live_basetest_check feat/noopmod)" "nao-consegui-medir"
eval "$_REAL_OLDSTATE_DEF"
eq "call site: real old_state restored after the stubs (noopmod is refusable again)" \
  "$(run_live_basetest_check feat/noopmod)" "passou-na-base"

# ── ga-hlcfzx9: portability repairs — declared AND measured on the Linux node ─────
# The fixture is shaped like the production repo: the selftests live under
# .gascity-gastown-hq/ (the only tree mbp-run.sh --repo hq can run on the node). The "node" is a
# fake mbp-run.sh that behaves like Linux for exactly one reason: a file containing the marker
# LINUX_BREAKS exits 126 there (the ga-9s361xi failure: a command that cannot be executed) and
# everything else exits 0. On the mini (this shell) every file below is green, in BOTH forms.
PORT_REPO="$TMPD/port-repo"
mkdir -p "$PORT_REPO/.gascity-gastown-hq/lib" "$PORT_REPO/outside"
git init -q -b main "$PORT_REPO"
git -C "$PORT_REPO" config user.email "test@gascity.local"
git -C "$PORT_REPO" config user.name "Test"
_pw() { mkdir -p "$(dirname "$PORT_REPO/$1")"; printf '%s' "$2" > "$PORT_REPO/$1"; }
_PT_BROKEN=$'#!/usr/bin/env bash\n# LINUX_BREAKS\nexit 0\n'
_PT_FIXED=$'#!/usr/bin/env bash\nexit 0\n'
_pw .gascity-gastown-hq/lib/port.selftest.sh     "$_PT_BROKEN"   # green on mini, red on node
_pw .gascity-gastown-hq/lib/port2.selftest.sh    "$_PT_BROKEN"   # a second portability repair
_pw .gascity-gastown-hq/lib/both.selftest.sh     "$_PT_FIXED"    # green on both systems
_pw .gascity-gastown-hq/lib/stillbad.selftest.sh "$_PT_BROKEN"   # red on node, and its new form too
_pw .gascity-gastown-hq/lib/macred.selftest.sh   $'#!/usr/bin/env bash\nexit 1\n'   # red on the mini
_pw outside/other.selftest.sh                    "$_PT_BROKEN"   # red on node, but not under .gascity-gastown-hq/
git -C "$PORT_REPO" add -A && git -C "$PORT_REPO" commit -q -m "base"
PORT_BASE=$(git -C "$PORT_REPO" rev-parse HEAD)
# One branch per scenario; each one is a single commit on the base.
_pbranch() {  # _pbranch <name> <path> <content> [<path> <content> ...]
  local name="$1"; shift
  git -C "$PORT_REPO" checkout -q -b "$name" "$PORT_BASE"
  while [ "$#" -ge 2 ]; do _pw "$1" "$2"; shift 2; done
  git -C "$PORT_REPO" add -A && git -C "$PORT_REPO" commit -q -m "$name"
  git -C "$PORT_REPO" checkout -q main
}
_pbranch port       .gascity-gastown-hq/lib/port.selftest.sh "$_PT_FIXED"
_pbranch bothedit   .gascity-gastown-hq/lib/both.selftest.sh "$(printf '%s# cosmetic' "$_PT_FIXED")"
_pbranch stillbad   .gascity-gastown-hq/lib/stillbad.selftest.sh "$(printf '%s# cosmetic' "$_PT_BROKEN")"
_pbranch macred     .gascity-gastown-hq/lib/macred.selftest.sh "$_PT_FIXED"
_pbranch outside    outside/other.selftest.sh "$_PT_FIXED"
_pbranch added      .gascity-gastown-hq/lib/brand-new.selftest.sh "$_PT_FIXED"
_pbranch mixed      .gascity-gastown-hq/lib/port.selftest.sh "$_PT_FIXED" .gascity-gastown-hq/lib/both.selftest.sh "$(printf '%s# cosmetic' "$_PT_FIXED")"
_pbranch twoport    .gascity-gastown-hq/lib/port.selftest.sh "$_PT_FIXED" .gascity-gastown-hq/lib/port2.selftest.sh "$_PT_FIXED"
_pbranch portmacred .gascity-gastown-hq/lib/port.selftest.sh "$_PT_FIXED" .gascity-gastown-hq/lib/macred.selftest.sh "$_PT_FIXED"
unset -f _pbranch _pw

PORT_BIN="$TMPD/port-bin"; mkdir -p "$PORT_BIN" "$TMPD/port-empty"
cat > "$PORT_BIN/mbp-run.sh" <<'FAKEMBPEOF'
#!/usr/bin/env bash
# Fake of scripts/mbp-run.sh for the portability tests: logs every call, optionally forces an rc,
# otherwise behaves like Linux: LINUX_BREAKS in the file => exit 126, else 0.
dir=""; target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) shift 2 ;;
    --dir)  dir="$2"; shift 2 ;;
    --)     target="$2"; shift 2; break ;;
    *)      shift ;;
  esac
done
echo "budget=${MBP_RUN_TIMEOUT_S:-} dir=$dir target=$target" >> "${FAKE_MBP_LOG:-/dev/null}"
[ -n "${FAKE_MBP_RC:-}" ] && exit "$FAKE_MBP_RC"
grep -q LINUX_BREAKS "$dir/$target" 2>/dev/null && exit 126
exit 0
FAKEMBPEOF
chmod +x "$PORT_BIN/mbp-run.sh"
cat > "$PORT_BIN/bd" <<'FAKEBD2EOF'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_BD_LOG:-/dev/null}"
[ -n "${FAKE_BD_OUT_FILE:-}" ] && cat "$FAKE_BD_OUT_FILE"
exit "${FAKE_BD_RC:-0}"
FAKEBD2EOF
chmod +x "$PORT_BIN/bd"
export FAKE_MBP_LOG="$TMPD/port-mbp.log" FAKE_BD_LOG="$TMPD/port-bd.log"
export GATE_ABT_MBP_RUN="$PORT_BIN/mbp-run.sh"
PORT_BD_DECLARED='[{"id":"ga-port","labels":["gate:g","teste:portabilidade-os"]}]'
PORT_BD_UNDECLARED='[{"id":"ga-port","labels":["gate:g"]}]'
PORT_BD_NOTFOUND='{"error":"no issues found matching the provided IDs","schema_version":1}'
_pbd() { printf '%s' "$1" > "$TMPD/port-bd.json"; export FAKE_BD_OUT_FILE="$TMPD/port-bd.json"; }
_pcalls() { if [ -f "$1" ]; then grep -c . "$1" || true; else echo 0; fi; }   # grep -c prints 0 AND exits 1 on an empty file
_preset() { : > "$FAKE_MBP_LOG"; : > "$FAKE_BD_LOG"; unset FAKE_MBP_RC FAKE_BD_RC GATE_ABT_NODE_TIMEOUT; }

echo "  -- gate_base_test_node_state (direct, fake mbp-run.sh) --"
_PS_WT=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-port.XXXXXX")
git -C "$PORT_REPO" worktree add --detach --quiet "$_PS_WT" "$PORT_BASE" 2>/dev/null
_PS_TIP() { git -C "$PORT_REPO" rev-parse "$1"; }
_ns() {  # _ns <branch> <file>
  gate_base_test_node_state "$PORT_REPO" "$PORT_BASE" "$(_PS_TIP "$1")" "$_PS_WT" "$2"
}
_PF=.gascity-gastown-hq/lib

_preset
eq "node_state: base RED on the node + branch GREEN there (the ga-9s361xi shape) -> node-red" \
  "$(_ns port $_PF/port.selftest.sh)" "node-red"
_preset; _ns port $_PF/port.selftest.sh >/dev/null
eq "node_state: that took exactly 2 node calls (old form, then the control run of the new form)" \
  "$(_pcalls "$FAKE_MBP_LOG")" "2"
eq "node_state: node called as '--repo hq --dir <wt>/.gascity-gastown-hq -- <path relative to it>' (the log shows the dir and the target)" \
  "$(head -1 "$FAKE_MBP_LOG" | sed "s#$_PS_WT#WT#")" "budget=300 dir=WT/.gascity-gastown-hq target=lib/port.selftest.sh"
_preset
eq "node_state: base GREEN on the node too (passes on BOTH systems before the fix) -> node-green" \
  "$(_ns bothedit $_PF/both.selftest.sh)" "node-green"
_preset; _ns bothedit $_PF/both.selftest.sh >/dev/null
eq "node_state: node-green costs ONE node call (no control run once the old form is green)" \
  "$(_pcalls "$FAKE_MBP_LOG")" "1"
_preset
eq "node_state: base red on node but the branch's copy is red THERE TOO (nothing proves the diff fixed it) -> unknown" \
  "$(_ns stillbad $_PF/stillbad.selftest.sh)" "unknown"
_preset; _ns stillbad $_PF/stillbad.selftest.sh >/dev/null
eq "node_state: ... after both runs (2 calls)" "$(_pcalls "$FAKE_MBP_LOG")" "2"
_preset
eq "node_state: file outside .gascity-gastown-hq/ (mbp-run.sh --repo hq cannot run it) -> unknown" \
  "$(_ns outside outside/other.selftest.sh)" "unknown"
_preset; _ns outside outside/other.selftest.sh >/dev/null
eq "node_state: ... and the node was never asked" "$(_pcalls "$FAKE_MBP_LOG")" "0"
_preset
eq "node_state: a path that only STARTS like the hq dir ('.gascity-gastown-hq-x/…') -> unknown" \
  "$(gate_base_test_node_state "$PORT_REPO" "$PORT_BASE" "$(_PS_TIP port)" "$_PS_WT" .gascity-gastown-hq-x/lib/a.selftest.sh)" "unknown"
eq "node_state: bare '.gascity-gastown-hq/' with no file -> unknown" \
  "$(gate_base_test_node_state "$PORT_REPO" "$PORT_BASE" "$(_PS_TIP port)" "$_PS_WT" .gascity-gastown-hq/)" "unknown"
for _rc in 96 97 98 99 124 137 255; do
  _preset; export FAKE_MBP_RC=$_rc
  eq "node_state: node answers rc $_rc on the OLD form (did not run / timeout / signal) -> unknown, NOT node-red" \
    "$(_ns port $_PF/port.selftest.sh)" "unknown"
  _preset; export FAKE_MBP_RC=$_rc; _ns port $_PF/port.selftest.sh >/dev/null
  eq "node_state: ... rc $_rc stops after the first call (no control run on an answer that is not an answer)" \
    "$(_pcalls "$FAKE_MBP_LOG")" "1"
done
_preset; export FAKE_MBP_RC=1
eq "node_state: node red on BOTH forms (rc 1 always: the node is simply broken) -> unknown, NOT node-red (the control run is what makes 'red' mean the test)" \
  "$(_ns port $_PF/port.selftest.sh)" "unknown"
_preset; export FAKE_MBP_RC=0
eq "node_state: node green on both -> node-green" "$(_ns port $_PF/port.selftest.sh)" "node-green"
_preset
eq "node_state: base sha that does not resolve (cannot extract the old form) -> unknown" \
  "$(gate_base_test_node_state "$PORT_REPO" 0000000000000000000000000000000000000000 "$(_PS_TIP port)" "$_PS_WT" $_PF/port.selftest.sh)" "unknown"
eq "node_state: tip sha that does not resolve (the control run cannot happen) -> unknown, NOT node-red" \
  "$(gate_base_test_node_state "$PORT_REPO" "$PORT_BASE" 0000000000000000000000000000000000000000 "$_PS_WT" $_PF/port.selftest.sh)" "unknown"
for _blank in rig base tip wt file; do
  _args=("$PORT_REPO" "$PORT_BASE" "$(_PS_TIP port)" "$_PS_WT" "$_PF/port.selftest.sh")
  case "$_blank" in rig) _args[0]="" ;; base) _args[1]="" ;; tip) _args[2]="" ;; wt) _args[3]="" ;; file) _args[4]="" ;; esac
  eq "node_state: empty $_blank argument -> unknown" "$(gate_base_test_node_state "${_args[@]}")" "unknown"
done
_preset
eq "node_state: wrapper path does not exist -> unknown (the node is optional; absence is not a verdict)" \
  "$(GATE_ABT_MBP_RUN="$TMPD/port-empty/nope.sh" _ns port $_PF/port.selftest.sh)" "unknown"
printf '#!/bin/sh\nexit 126\n' > "$TMPD/port-empty/noexec.sh"
eq "node_state: wrapper exists but is not executable -> unknown" \
  "$(GATE_ABT_MBP_RUN="$TMPD/port-empty/noexec.sh" _ns port $_PF/port.selftest.sh)" "unknown"
eq "node_state: no GATE_ABT_MBP_RUN and no GC_CITY (default wrapper path unresolvable) -> unknown, no crash" \
  "$(env -u GATE_ABT_MBP_RUN GC_CITY="" bash -c 'GATE_GUARD_LIB_ONLY=1 . "$1"; gate_base_test_node_state "$2" "$3" "$4" "$5" "$6"' _ "$GUARD" "$PORT_REPO" "$PORT_BASE" "$(_PS_TIP port)" "$_PS_WT" "$_PF/port.selftest.sh")" "unknown"
_preset; GATE_ABT_NODE_TIMEOUT=17 _ns port $_PF/port.selftest.sh >/dev/null
eq "node_state: GATE_ABT_NODE_TIMEOUT=17 is handed to mbp-run.sh as MBP_RUN_TIMEOUT_S (the REMOTE process dies with the budget, ga-vg16lk)" \
  "$(head -1 "$FAKE_MBP_LOG" | sed 's# dir=.*##')" "budget=17"
for _bad in 0 abc ""; do
  _preset; GATE_ABT_NODE_TIMEOUT="$_bad" _ns port $_PF/port.selftest.sh >/dev/null
  eq "node_state: GATE_ABT_NODE_TIMEOUT='$_bad' (not a usable budget) -> default 300" \
    "$(head -1 "$FAKE_MBP_LOG" | sed 's# dir=.*##')" "budget=300"
done
eq "node_state: always exits 0 (safe under the guard's set -e even on 'unknown')" \
  "$(gate_base_test_node_state "" "" "" "" "" >/dev/null; echo $?)" "0"
git -C "$PORT_REPO" worktree remove --force "$_PS_WT" 2>/dev/null || rm -rf "$_PS_WT" 2>/dev/null
unset -f _PS_TIP _ns

# The call site, end to end. Same scope and same convention as run_live_basetest_check above: a
# mirror of the Step 5b-pre2 loop that calls the REAL guard functions (old_state, portability_declared,
# mutants_declared, declared_state [-> mutants_state, node_state], verdict) — section 3 pins that the live
# call site has the same shape. ga-4kykayr: this fixture's bead never carries teste:endurece-mutantes, so the
# mutant path answers "no" here and the portability matrix below is the unchanged ga-hlcfzx9 one; the mutant
# path has its own fixture and matrix in gate-guard-ab-base-test-mutants.selftest.sh.
run_port_check() {  # run_port_check <branch> [bead-id]  -> verdict
  local branch="$1" bead="${2:-ga-port}" tip base="$PORT_BASE"
  local detected=0 copy_ok=0 ran=0 failed=0 repaired=0 unclassified=0 portable=0 killed=0 decl="" mdecl="" files wt f rc
  tip=$(git -C "$PORT_REPO" rev-parse "$branch")
  files=$(git -C "$PORT_REPO" diff --name-only --diff-filter=AM "${base}..${tip}" -- '*.selftest.sh')
  detected=$(printf '%s\n' "$files" | grep -c .)
  wt=$(mktemp -d "${TMPDIR:-/tmp}/gate-rstae-selftest-port.XXXXXX")
  git -C "$PORT_REPO" worktree add --detach --quiet "$wt" "$base" 2>/dev/null
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    mkdir -p "$(dirname "$wt/$f")"
    if git -C "$PORT_REPO" show "${tip}:$f" > "$wt/$f" 2>/dev/null; then
      copy_ok=$((copy_ok + 1))
      if timeout 30 bash "$wt/$f" >/dev/null 2>&1; then
        ran=$((ran + 1))
        case "$(gate_base_test_old_state "$PORT_REPO" "$base" "$wt" "$f")" in
          old-fails)         repaired=$((repaired + 1)) ;;
          added)             : ;;
          old-passes)
            if [ -z "$decl" ]; then
              decl=$(gate_base_test_portability_declared /fake/store "$bead")
            fi
            if [ -z "$mdecl" ]; then
              mdecl=$(gate_base_test_mutants_declared /fake/store "$bead")
            fi
            case "$(gate_base_test_declared_state "$PORT_REPO" "$base" "$tip" "$wt" "$f" /fake/store "$bead" "$mdecl" "$decl")" in
              killed)     killed=$((killed + 1)) ;;
              portable)   portable=$((portable + 1)) ;;
              refusable)  : ;;
              *)          unclassified=$((unclassified + 1)) ;;
            esac ;;
          *)                 unclassified=$((unclassified + 1)) ;;
        esac
      else
        rc=$?
        if [ "$rc" != "124" ]; then ran=$((ran + 1)); failed=$((failed + 1)); fi
      fi
    fi
  done <<PORTFILESEOF
$files
PORTFILESEOF
  git -C "$PORT_REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt" 2>/dev/null
  gate_base_test_verdict "$detected" "$copy_ok" "$ran" "$failed" "$repaired" "$unclassified" "$portable" "$killed"
}
# Every run below goes through PATH with the fake bd first, like the live guard resolves `bd`.
run_port() { PATH="$PORT_BIN:$PATH" run_port_check "$@"; }

echo "  -- acceptance matrix (ga-hlcfzx9): the declared + measured path --"
_preset; _pbd "$PORT_BD_DECLARED"
eq "ACCEPT 1: portability repair, DECLARED, node red on base + green on the branch -> consertou-portabilidade (ga-9s361xi passes via the new path)" \
  "$(run_port port)" "consertou-portabilidade"
_preset; _pbd "$PORT_BD_DECLARED"
eq "ACCEPT 2: a test that passes on BOTH systems before the fix, DECLARED, stays refused -> passou-na-base" \
  "$(run_port bothedit)" "passou-na-base"
_preset; _pbd "$PORT_BD_UNDECLARED"
eq "same repair, NOT declared -> passou-na-base (the label is what opens the node path)" \
  "$(run_port port)" "passou-na-base"
_preset; _pbd "$PORT_BD_UNDECLARED"; run_port port >/dev/null
eq "same repair, NOT declared: the node is never asked (no cost without a declaration)" "$(_pcalls "$FAKE_MBP_LOG")" "0"
_preset; _pbd "$PORT_BD_DECLARED"; export FAKE_MBP_RC=97
eq "declared, node unavailable (rc 97) -> nao-consegui-medir, NOT a refusal (no node, no verdict)" "$(run_port port)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_DECLARED"; export FAKE_MBP_RC=124
eq "declared, node times out (rc 124) -> nao-consegui-medir" "$(run_port port)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_DECLARED"; export FAKE_MBP_RC=137
eq "declared, node process killed (rc 137) -> nao-consegui-medir" "$(run_port port)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_DECLARED"
eq "declared, but the new form is ALSO red on the node (the repair did not repair it) -> nao-consegui-medir, not accepted and not refused" \
  "$(run_port stillbad)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_DECLARED"
eq "declared, but the file is outside .gascity-gastown-hq/ (the node cannot run it) -> nao-consegui-medir" \
  "$(run_port outside)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_NOTFOUND"
eq "declaration UNREADABLE (bd answered not-found) -> nao-consegui-medir, NOT passou-na-base (could not read != nobody declared)" \
  "$(run_port port)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_NOTFOUND"; run_port port >/dev/null
eq "declaration unreadable: the node is never asked" "$(_pcalls "$FAKE_MBP_LOG")" "0"
_preset; _pbd "$PORT_BD_DECLARED"; export FAKE_BD_RC=1
eq "declaration unreadable (bd exits 1) -> nao-consegui-medir" "$(run_port port)" "nao-consegui-medir"
_preset; _pbd ""
eq "declaration unreadable (bd prints nothing) -> nao-consegui-medir" "$(run_port port)" "nao-consegui-medir"
_preset; _pbd "$PORT_BD_DECLARED"
eq "a mini-side REPAIR (old form red on the mini) is still consertou-teste-vermelho — the older path is untouched" \
  "$(run_port macred)" "consertou-teste-vermelho"
_preset; _pbd "$PORT_BD_DECLARED"; run_port macred >/dev/null
eq "a mini-side repair never reads the declaration and never asks the node (lazy: cost only where needed)" \
  "$(_pcalls "$FAKE_BD_LOG") $(_pcalls "$FAKE_MBP_LOG")" "0 0"
_preset; _pbd "$PORT_BD_DECLARED"
eq "a brand-new selftest, DECLARED -> passou-na-base (no old form to repair: the node path is for MODIFIED tests only)" \
  "$(run_port added)" "passou-na-base"
_preset; _pbd "$PORT_BD_DECLARED"; run_port added >/dev/null
eq "a brand-new selftest: no declaration read, no node call" "$(_pcalls "$FAKE_BD_LOG") $(_pcalls "$FAKE_MBP_LOG")" "0 0"
_preset; _pbd "$PORT_BD_DECLARED"
eq "portability repair + a sibling green on both systems -> consertou-portabilidade (one discriminating file is enough)" \
  "$(run_port mixed)" "consertou-portabilidade"
_preset; _pbd "$PORT_BD_DECLARED"
eq "two portability repairs -> consertou-portabilidade" "$(run_port twoport)" "consertou-portabilidade"
_preset; _pbd "$PORT_BD_DECLARED"; run_port twoport >/dev/null
eq "two files to check: each declaration is read ONCE (bd called twice: teste:portabilidade-os, teste:endurece-mutantes), the node 4 times (2 files x old+control)" \
  "$(_pcalls "$FAKE_BD_LOG") $(_pcalls "$FAKE_MBP_LOG")" "2 4"
_preset; _pbd "$PORT_BD_DECLARED"
eq "a mini-side repair + a portability repair together -> consertou-teste-vermelho (the older proof keeps its word)" \
  "$(run_port portmacred)" "consertou-teste-vermelho"
_preset; _pbd "$PORT_BD_DECLARED"
eq "the declaration is read from the SOURCE bead in its store: asked 'bd -C /fake/store show <bead> --json'" \
  "$(run_port port >/dev/null; head -1 "$FAKE_BD_LOG")" "-C /fake/store show ga-port --json"

echo "  -- the path is not chosen by bead id (Mayor decision 2026-10-26) --"
# The verdict hangs off the declaration and the measurement only. Same scenario under bead ids that
# hash to arm A and to arm B, and under the real ga-9s361xi: the answer cannot differ.
_PB_A=""; _PB_B=""
for _n in $(seq 1 60); do
  case "$(gate_ab_arm_for_bead "ga-hlc$_n")" in
    A) [ -z "$_PB_A" ] && _PB_A="ga-hlc$_n" ;;
    B) [ -z "$_PB_B" ] && _PB_B="ga-hlc$_n" ;;
  esac
  [ -n "$_PB_A" ] && [ -n "$_PB_B" ] && break
done
if [ -n "$_PB_A" ] && [ -n "$_PB_B" ]; then
  _V=""
  for _bid in "$_PB_A" "$_PB_B" ga-9s361xi ga-zxevh3a; do
    _preset; _pbd "[{\"id\":\"$_bid\",\"labels\":[\"teste:portabilidade-os\"]}]"
    _V="$_V$(PATH="$PORT_BIN:$PATH" run_port_check port "$_bid") "
  done
  eq "same repair under an arm-A bead, an arm-B bead, ga-9s361xi and its marker -> the SAME verdict four times" \
    "$_V" "consertou-portabilidade consertou-portabilidade consertou-portabilidade consertou-portabilidade "
else
  bad "could not find one bead id per arm among ga-hlc1..60 — the arm-independence check has nothing to compare"
fi

echo "  -- the call site's third state for the new reads --"
# Same doctrine as the old_state stubs above: a function documented to print one word that prints
# NOTHING (killed substitution) or an unrecognised word must read "don't know", never refusal.
_preset; _pbd "$PORT_BD_DECLARED"
_REAL_NODESTATE_DEF=$(declare -f gate_base_test_node_state)
gate_base_test_node_state() { printf ''; return 0; }
eq "call site: node_state prints NOTHING -> nao-consegui-medir, NOT a refusal" "$(run_port bothedit)" "nao-consegui-medir"
gate_base_test_node_state() { printf 'garbage'; return 0; }
eq "call site: node_state prints an UNRECOGNISED word -> nao-consegui-medir, NOT a refusal" "$(run_port bothedit)" "nao-consegui-medir"
gate_base_test_node_state() { printf 'unknown'; return 0; }
eq "call site: node_state prints 'unknown' -> nao-consegui-medir" "$(run_port port)" "nao-consegui-medir"
eval "$_REAL_NODESTATE_DEF"
eq "call site: real node_state restored (bothedit is refusable again)" "$(run_port bothedit)" "passou-na-base"
_REAL_DECL_DEF=$(declare -f gate_base_test_portability_declared)
gate_base_test_portability_declared() { printf ''; return 0; }
eq "call site: portability_declared prints NOTHING -> nao-consegui-medir, NOT a refusal" "$(run_port bothedit)" "nao-consegui-medir"
gate_base_test_portability_declared() { printf 'maybe'; return 0; }
eq "call site: portability_declared prints an UNRECOGNISED word -> nao-consegui-medir, NOT a refusal" "$(run_port bothedit)" "nao-consegui-medir"
eval "$_REAL_DECL_DEF"
eq "call site: real portability_declared restored" "$(run_port bothedit)" "passou-na-base"

unset FAKE_MBP_LOG FAKE_BD_LOG GATE_ABT_MBP_RUN FAKE_BD_OUT_FILE FAKE_MBP_RC FAKE_BD_RC GATE_ABT_NODE_TIMEOUT
unset -f _pbd _pcalls _preset run_port run_port_check

# Worktree hygiene: after all the runs above, the RIG_PATH clone must have
# no leftover linked worktrees and no stray temp directories — a leaked
# throwaway worktree on every guard sweep would slowly fill disk on the one
# machine this whole city's control plane runs on.
_WT_LEFTOVER=$(git -C "$RIG_PATH" worktree list 2>/dev/null | grep -c -E "gate-rstae-selftest-(wt|oldstate)" || true)
eq "no leftover linked worktrees after 9 check runs + the old_state probes (git worktree remove ran cleanly every time)" \
  "${_WT_LEFTOVER:-0}" "0"
_WT_LEFTOVER_PORT=$(git -C "$PORT_REPO" worktree list 2>/dev/null | grep -c "gate-rstae-selftest-port" || true)
eq "no leftover linked worktrees after the portability runs either (node_state and the mirror both clean up)" \
  "${_WT_LEFTOVER_PORT:-0}" "0"

rm -rf "$TMPD"
trap - EXIT

# ── 3. DRIFT GUARDS on the live script ───────────────────────────────────────
echo "── 3. drift guards: placement, param shape, wiring, ordering, arm-A isolation ──"

# 3a. Both pure functions defined before the GATE_GUARD_LIB_ONLY cutoff (the
# ga-zdkn1-class regression this codebase has already hit once before: a
# pure function defined past the cutoff is invisible to lib-only sourcing).
CUTOFF_LINE=$(grep -n 'GATE_GUARD_LIB_ONLY:-' "$GUARD" | head -1 | cut -d: -f1)
ARM_DEF_LINE=$(grep -n '^gate_ab_arm_for_bead() {' "$GUARD" | head -1 | cut -d: -f1)
VERDICT_DEF_LINE=$(grep -n '^gate_base_test_verdict() {' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$ARM_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$ARM_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_ab_arm_for_bead (L$ARM_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_ab_arm_for_bead def=${ARM_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

if [ -n "$VERDICT_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$VERDICT_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_base_test_verdict (L$VERDICT_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_base_test_verdict def=${VERDICT_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

OUTSIDE_DEF_LINE=$(grep -n '^gate_base_test_outside_subtree() {' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$OUTSIDE_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$OUTSIDE_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_base_test_outside_subtree (L$OUTSIDE_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE) (ga-x4mkk2)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_base_test_outside_subtree def=${OUTSIDE_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

OLDSTATE_DEF_LINE=$(grep -n '^gate_base_test_old_state() {' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$OLDSTATE_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$OLDSTATE_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_base_test_old_state (L$OLDSTATE_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE) (ga-yl1k3w)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_base_test_old_state def=${OLDSTATE_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

for _fn in gate_base_test_node_rc_class gate_base_test_portability_declared gate_base_test_node_state; do
  _FN_LINE=$(grep -n "^${_fn}() {" "$GUARD" | head -1 | cut -d: -f1)
  if [ -n "$_FN_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$_FN_LINE" -lt "$CUTOFF_LINE" ]; then
    ok "guard.sh: $_fn (L$_FN_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE) (ga-hlcfzx9)"
  else
    bad "REGRESSION (ga-zdkn1-class): $_fn def=${_FN_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
  fi
done

# 3b. The Step 5b-pre2 block exists exactly once and is wired: calls both
# pure functions, gates the worktree machinery on arm B, sets
# gate-status:error, and exits 1 on the block path.
STEP_COUNT=$(grep -c 'Step 5b-pre2 (ga-rstae)' "$GUARD")
eq "guard.sh: Step 5b-pre2 (ga-rstae) block present exactly once" "$STEP_COUNT" "1"

ABT_BLOCK=$(awk '/Step 5b-pre2 \(ga-rstae\)/,/^fi$/' "$GUARD")

echo "$ABT_BLOCK" | grep '_ABT_ARM=\$(gate_ab_arm_for_bead "\$BEAD_ID")' >/dev/null \
  && ok "guard.sh: block calls gate_ab_arm_for_bead on BEAD_ID" \
  || bad "guard.sh: block does not call gate_ab_arm_for_bead correctly"

echo "$ABT_BLOCK" | grep '_ABT_VERDICT=\$(gate_base_test_verdict' >/dev/null \
  && ok "guard.sh: block calls gate_base_test_verdict" \
  || bad "guard.sh: block does not call gate_base_test_verdict"

echo "$ABT_BLOCK" | grep 'set_gate_status "\$MARKER_ID" "error"' >/dev/null \
  && ok "guard.sh: refusal sets gate-status:error (re-submittable, matches Step 5b-pre's own convention)" \
  || bad "guard.sh: refusal does not set gate-status:error"

echo "$ABT_BLOCK" | grep 'exit 1' >/dev/null \
  && ok "guard.sh: refusal actually exits 1 (does not fall through to Step 7)" \
  || bad "guard.sh: refusal does not exit — sweep would continue to Step 7 anyway"

echo "$ABT_BLOCK" | grep '"\$_ABT_VERDICT" = "passou-na-base"' >/dev/null \
  && ok "guard.sh: refusal is gated EXACTLY on verdict = passou-na-base (not a broader condition that would also refuse sem-teste-novo/nao-consegui-medir/reprovou-na-base)" \
  || bad "guard.sh: refusal condition missing or wrong — could over-refuse the non-blocking states"

# 3c. Arm-A isolation: the arm-B gate must appear BEFORE any worktree/fetch
# machinery in the block — i.e. arm A truly never reaches it. Compare line
# numbers WITHIN the extracted block (awk NR resets per invocation, so use a
# fresh grep -n on the block text itself).
ARM_GATE_LINE=$(echo "$ABT_BLOCK" | grep -n '"\$_ABT_ARM" = "B"' | head -1 | cut -d: -f1)
WORKTREE_LINE=$(echo "$ABT_BLOCK" | grep -n 'worktree add' | head -1 | cut -d: -f1)
FETCH_LINE=$(echo "$ABT_BLOCK" | grep -n 'git -C "\$RIG_PATH" fetch origin main "\$BRANCH"' | head -1 | cut -d: -f1)

if [ -n "$ARM_GATE_LINE" ] && [ -n "$WORKTREE_LINE" ] && [ "$ARM_GATE_LINE" -lt "$WORKTREE_LINE" ]; then
  ok "guard.sh: arm-B gate (block-relative L$ARM_GATE_LINE) precedes worktree add (L$WORKTREE_LINE) — arm A cannot reach the worktree machinery"
else
  bad "REGRESSION: arm gate=${ARM_GATE_LINE:-missing} worktree=${WORKTREE_LINE:-missing} — arm A might reach worktree machinery"
fi

if [ -n "$ARM_GATE_LINE" ] && [ -n "$FETCH_LINE" ] && [ "$ARM_GATE_LINE" -lt "$FETCH_LINE" ]; then
  ok "guard.sh: arm-B gate (block-relative L$ARM_GATE_LINE) precedes the fetch/rev-parse/merge-base git calls (L$FETCH_LINE) — arm A does zero git IO from this check"
else
  bad "REGRESSION: arm gate=${ARM_GATE_LINE:-missing} fetch=${FETCH_LINE:-missing} — arm A might trigger git IO"
fi

# 3c'. ga-yl1k3w: the old-form probe is arm-B-only too — the call must sit after
# the arm-B gate inside the block, and the verdict call must hand over BOTH new
# counts (a 4-arg call would silently drop repairs and re-refuse them).
OLDSTATE_CALL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_old_state "\$RIG_PATH"' | head -1 | cut -d: -f1)
if [ -n "$ARM_GATE_LINE" ] && [ -n "$OLDSTATE_CALL_LINE" ] && [ "$ARM_GATE_LINE" -lt "$OLDSTATE_CALL_LINE" ]; then
  ok "guard.sh: gate_base_test_old_state is called only after the arm-B gate (block-relative L$OLDSTATE_CALL_LINE > L$ARM_GATE_LINE) — arm A never runs it"
else
  bad "REGRESSION: old-state call line=${OLDSTATE_CALL_LINE:-missing} arm gate=${ARM_GATE_LINE:-missing} — arm A might run the old-form probe"
fi

echo "$ABT_BLOCK" | grep '_ABT_VERDICT=\$(gate_base_test_verdict "\$_ABT_DETECTED" "\$_ABT_COPY_OK" "\$_ABT_RAN" "\$_ABT_FAILED" "\$_ABT_REPAIRED" "\$_ABT_UNCLASSIFIED" "\$_ABT_PORTABLE" "\$_ABT_KILLED")' >/dev/null \
  && ok "guard.sh: verdict call passes repaired, unclassified, portable AND killed (8 args)" \
  || bad "guard.sh: verdict call does not pass all four counts — repairs (ga-yl1k3w), portability repairs (ga-hlcfzx9) or mutant kills (ga-4kykayr) would be re-refused"

# The old_state case: ONLY added is a proven "nothing to repair" without further asking. old-passes
# is the one answer that may lead to a refusal, and only through the declaration + node arms below;
# every other answer (empty, garbage, unknown) must land in unclassified.
echo "$ABT_BLOCK" | grep -E '^[[:space:]]*added\)[[:space:]]+:[[:space:]]*;;' >/dev/null \
  && echo "$ABT_BLOCK" | grep -E '^[[:space:]]*old-passes\)[[:space:]]*$' >/dev/null \
  && echo "$ABT_BLOCK" | grep -E '^[[:space:]]*\*\)[[:space:]]+_ABT_UNCLASSIFIED=\$\(\(_ABT_UNCLASSIFIED \+ 1\)\) ;;' >/dev/null \
  && ok "guard.sh: the old_state case has added as a plain no-count arm, old-passes as its own arm (declaration + node), and sends everything else (empty/garbage/unknown) to unclassified" \
  || bad "guard.sh: the old_state case lacks the added / old-passes / *) unclassified arms — an empty or unrecognised answer would read as a refusal"

echo "$ABT_BLOCK" | grep 'AB-BASE-TEST bead=.*repaired=\$_ABT_REPAIRED unclassified=\$_ABT_UNCLASSIFIED' >/dev/null \
  && ok "guard.sh: AB-BASE-TEST log line carries repaired=/unclassified= (appended, existing fields untouched)" \
  || bad "guard.sh: AB-BASE-TEST log line lacks repaired=/unclassified="

echo "$ABT_BLOCK" | grep 'AB-BASE-TEST bead=.*unclassified=\$_ABT_UNCLASSIFIED portable=\$_ABT_PORTABLE killed=\$_ABT_KILLED outside-subtree=' >/dev/null \
  && ok "guard.sh: AB-BASE-TEST log line carries portable= (ga-hlcfzx9) and killed= (ga-4kykayr) between unclassified= and outside-subtree= (existing fields untouched)" \
  || bad "guard.sh: AB-BASE-TEST log line lacks portable=\$_ABT_PORTABLE killed=\$_ABT_KILLED in its slot"

# ga-hlcfzx9 / ga-4kykayr: where the declared paths are called. All of it is arm-B-only (after the gate), the
# declaration reads and the dispatch are INSIDE the old-passes arm (the lazy cost: a submission that never gets
# there pays nothing), and the dispatch itself (gate_base_test_declared_state) asks the node only for a declared
# portability file and runs mutants only for a declared mutant-hardening one (pinned on its body further down).
_PO_DECL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_portability_declared "\$BEAD_CITY" "\$BEAD_ID"' | head -1 | cut -d: -f1)
_PO_MDECL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_mutants_declared "\$BEAD_CITY" "\$BEAD_ID"' | head -1 | cut -d: -f1)
_PO_CALL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_declared_state "\$RIG_PATH" "\$_ABT_BASE" "\$_ABT_BRANCH_SHA" "\$_ABT_WT" "\$_abt_f" "\$BEAD_CITY" "\$BEAD_ID" "\$_ABT_MUT_DECL" "\$_ABT_PORT_DECL"' | head -1 | cut -d: -f1)
_PO_OLDPASS_LINE=$(echo "$ABT_BLOCK" | grep -n -E '^[[:space:]]*old-passes\)[[:space:]]*$' | head -1 | cut -d: -f1)
if [ -n "$ARM_GATE_LINE" ] && [ -n "$_PO_OLDPASS_LINE" ] && [ -n "$_PO_DECL_LINE" ] && [ -n "$_PO_MDECL_LINE" ] && [ -n "$_PO_CALL_LINE" ] \
   && [ "$ARM_GATE_LINE" -lt "$_PO_OLDPASS_LINE" ] && [ "$_PO_OLDPASS_LINE" -lt "$_PO_DECL_LINE" ] \
   && [ "$_PO_OLDPASS_LINE" -lt "$_PO_MDECL_LINE" ] \
   && [ "$_PO_DECL_LINE" -lt "$_PO_CALL_LINE" ] && [ "$_PO_MDECL_LINE" -lt "$_PO_CALL_LINE" ]; then
  ok "guard.sh: arm-B gate (L$ARM_GATE_LINE) < old-passes arm (L$_PO_OLDPASS_LINE) < both declaration reads (L$_PO_DECL_LINE, L$_PO_MDECL_LINE) < declared_state call (L$_PO_CALL_LINE) — arm A never reads a declaration or measures anything"
else
  bad "guard.sh: declaration reads / declared_state call not ordered arm gate < old-passes < reads < call (gate=${ARM_GATE_LINE:-missing} old-passes=${_PO_OLDPASS_LINE:-missing} decl=${_PO_DECL_LINE:-missing} mdecl=${_PO_MDECL_LINE:-missing} call=${_PO_CALL_LINE:-missing}) — a declared path could run for undeclared files, or arm A could reach it"
fi
# the node is reached ONLY through gate_base_test_declared_state: no direct call left at the call site
eq "guard.sh: the Step 5b-pre2 block has no direct gate_base_test_node_state / _mutants_state call (the dispatch is the one function)" \
  "$(echo "$ABT_BLOCK" | sed -E 's/(^|[[:space:]])#.*$//' | grep -cE 'gate_base_test_node_state|gate_base_test_mutants_state' || true)" "0"

_PO_DS=$(awk '/^gate_base_test_declared_state\(\) \{/,/^\}/' "$GUARD")
_PO_DS_PCASE=$(echo "$_PO_DS" | grep -n 'case "\$pdecl" in' | head -1 | cut -d: -f1)
_PO_DS_NODE=$(echo "$_PO_DS" | grep -n 'gate_base_test_node_state "\$rig" "\$base" "\$tip" "\$wt" "\$f"' | head -1 | cut -d: -f1)
_PO_DS_YES=$(echo "$_PO_DS" | awk -v s="${_PO_DS_PCASE:-0}" 'NR > s && /^[[:space:]]*yes\)[[:space:]]*$/ { print NR; exit }')
if [ -n "$_PO_DS_PCASE" ] && [ -n "$_PO_DS_YES" ] && [ -n "$_PO_DS_NODE" ] && [ "$_PO_DS_PCASE" -lt "$_PO_DS_YES" ] && [ "$_PO_DS_YES" -lt "$_PO_DS_NODE" ]; then
  ok "guard.sh: in gate_base_test_declared_state the node is asked only inside the portability declaration's yes) arm (case L$_PO_DS_PCASE < yes) L$_PO_DS_YES < node_state L$_PO_DS_NODE)"
else
  bad "guard.sh: gate_base_test_declared_state does not ask the node only under a declared portability yes) (case=${_PO_DS_PCASE:-missing} yes=${_PO_DS_YES:-missing} node=${_PO_DS_NODE:-missing})"
fi

echo "$ABT_BLOCK" | grep -E '^[[:space:]]*_ABT_PORTABLE=0; _ABT_PORT_DECL=""' >/dev/null \
  && ok "guard.sh: _ABT_PORTABLE starts at 0 and _ABT_PORT_DECL starts EMPTY (declaration not read until first needed)" \
  || bad "guard.sh: _ABT_PORTABLE/_ABT_PORT_DECL not initialised as 0 / empty"

# The inner cases: a node answer other than node-red/node-green, a mutant answer other than killed/survived and a
# declaration answer other than no/yes all end in "unknown" -> the call site's unclassified (nao-consegui-medir) —
# never in "no count" (= refusal) and never in a repair that was not measured.
echo "$_PO_DS" | grep -E "^[[:space:]]*node-red\)[[:space:]]+printf 'portable'; return 0 ;;" >/dev/null \
  && echo "$_PO_DS" | grep -E '^[[:space:]]*node-green\)[[:space:]]+:[[:space:]]*;;' >/dev/null \
  && echo "$_PO_DS" | grep -E "^[[:space:]]*killed\)[[:space:]]+printf 'killed'; return 0 ;;" >/dev/null \
  && echo "$_PO_DS" | grep -E '^[[:space:]]*survived\)[[:space:]]+:[[:space:]]*;;' >/dev/null \
  && [ "$(echo "$_PO_DS" | grep -cE '^[[:space:]]*no\)[[:space:]]+:[[:space:]]*;;')" -ge 2 ] \
  && [ "$(echo "$_PO_DS" | grep -cE '^[[:space:]]*\*\)[[:space:]]+unk=1 ;;')" -ge 4 ] \
  && ok "guard.sh: in declared_state, node-red -> portable and killed -> killed (early return), node-green / survived / a declared 'no' count nothing, and an unreadable declaration / unrecognised mutant or node answer set unknown" \
  || bad "guard.sh: gate_base_test_declared_state's cases are not (node-red -> portable, node-green -> nothing, killed -> killed, survived -> nothing, no -> nothing, *) -> unknown) — doubt could become a refusal or an unmeasured repair"
_PO_CS=$(echo "$ABT_BLOCK" | sed -n '/^[[:space:]]*old-passes)[[:space:]]*$/,/^[[:space:]]*esac ;;$/p')
echo "$_PO_CS" | grep -E '^[[:space:]]*killed\)[[:space:]]+_ABT_KILLED=\$\(\(_ABT_KILLED \+ 1\)\) ;;' >/dev/null \
  && echo "$_PO_CS" | grep -E '^[[:space:]]*portable\)[[:space:]]+_ABT_PORTABLE=\$\(\(_ABT_PORTABLE \+ 1\)\) ;;' >/dev/null \
  && echo "$_PO_CS" | grep -E '^[[:space:]]*refusable\)[[:space:]]+:[[:space:]]*;;' >/dev/null \
  && echo "$_PO_CS" | grep -E '^[[:space:]]*\*\)[[:space:]]+_ABT_UNCLASSIFIED=\$\(\(_ABT_UNCLASSIFIED \+ 1\)\) ;;' >/dev/null \
  && ok "guard.sh: inside old-passes: killed counts _ABT_KILLED, portable counts _ABT_PORTABLE, refusable counts nothing and anything else (empty/garbage/unknown) is unclassified" \
  || bad "guard.sh: the old-passes arm does not map declared_state's words (killed -> _ABT_KILLED, portable -> _ABT_PORTABLE, refusable -> nothing, *) -> unclassified)"
echo "$ABT_BLOCK" | grep -E '^[[:space:]]*_ABT_KILLED=0; _ABT_MUT_DECL=""' >/dev/null \
  && ok "guard.sh: _ABT_KILLED starts at 0 and _ABT_MUT_DECL starts EMPTY (mutant declaration not read until first needed)" \
  || bad "guard.sh: _ABT_KILLED/_ABT_MUT_DECL not initialised as 0 / empty"

# Nothing in the new code picks a path by bead id (Mayor, 2026-10-26): no code line (comments excluded)
# names ga-9s361xi / ga-zxevh3a, and the new functions do not look at the A/B arm at all.
_PO_ID_CODE=$(grep -nE 'ga-9s361xi|ga-zxevh3a' "$GUARD" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c . || true)
eq "guard.sh: no CODE line names ga-9s361xi / ga-zxevh3a (comments excluded) — the portability path is not keyed on the case that motivated it" "${_PO_ID_CODE:-0}" "0"
_PO_FUNCS=$(awk '/^gate_base_test_portability_declared\(\) \{/,/^\}/; /^gate_base_test_node_rc_class\(\) \{/,/^\}/; /^gate_base_test_node_state\(\) \{/,/^\}/' "$GUARD")
if [ -n "$_PO_FUNCS" ] && [ "$(echo "$_PO_FUNCS" | grep -c .)" -gt 40 ]; then
  eq "guard.sh: the three new functions never mention the arm (gate_ab_arm_for_bead / _ABT_ARM) — arm-independent by construction" \
    "$(echo "$_PO_FUNCS" | grep -vE '^[[:space:]]*#' | grep -cE 'gate_ab_arm_for_bead|_ABT_ARM' || true)" "0"
else
  bad "guard.sh: could not extract the three new functions (got $(echo "$_PO_FUNCS" | grep -c .) lines) — the arm-independence check has nothing to look at"
fi

# The builder must be told how to declare. The note is built only in the refusal block, from the declaration
# this run actually read, and ends up in the same bd comment as the ga-yl1k3w line.
echo "$ABT_BLOCK" | grep -E 'bd label add \$BEAD_ID teste:portabilidade-os' >/dev/null \
  && echo "$ABT_BLOCK" | grep -E '^\$_ABT_PORT_NOTE \(ga-hlcfzx9\)$' >/dev/null \
  && ok "guard.sh: the refusal comment tells the builder to 'bd label add <bead> teste:portabilidade-os' and carries \$_ABT_PORT_NOTE" \
  || bad "guard.sh: the refusal comment does not explain the declared portability path"
_PO_NOTE_LINE=$(echo "$ABT_BLOCK" | grep -n '_ABT_PORT_NOTE=' | head -1 | cut -d: -f1)
_PO_REFUSE_LINE=$(echo "$ABT_BLOCK" | grep -n '"\$_ABT_VERDICT" = "passou-na-base"' | head -1 | cut -d: -f1)
if [ -n "$_PO_NOTE_LINE" ] && [ -n "$_PO_REFUSE_LINE" ] && [ "$_PO_NOTE_LINE" -gt "$_PO_REFUSE_LINE" ]; then
  ok "guard.sh: _ABT_PORT_NOTE is built INSIDE the passou-na-base refusal (L$_PO_NOTE_LINE > L$_PO_REFUSE_LINE): no other verdict composes or sends it"
else
  bad "guard.sh: _ABT_PORT_NOTE built at L${_PO_NOTE_LINE:-missing} but the refusal starts at L${_PO_REFUSE_LINE:-missing} — it may be built outside the refusal"
fi
_PO_LEAK=$(echo "$ABT_BLOCK" | grep -E 'gate_base_test_verdict|"\$_ABT_VERDICT" = ' | grep -c '_ABT_PORT_DECL\|_ABT_PORT_NOTE' || true)
eq "guard.sh: the declaration and the note appear on NO verdict-call or refusal-condition line (the verdict is computed from the counts only; the declaration decides whether the node is asked, and what the message says)" "${_PO_LEAK:-0}" "0"

# ga-x4mkk2: the outside-subtree count is arm-B-only, starts as `unknown` (never measured is
# not 0), is measured with the REAL helper against the same base/head the detection uses, is
# logged as the LAST field (existing fields untouched), and is NOT an input to any verdict or
# refusal — option 1 of the bead is detection only.
OUTSIDE_CALL_LINE=$(echo "$ABT_BLOCK" | grep -n 'gate_base_test_outside_subtree "\$RIG_PATH" "\$_ABT_BASE" "\$_ABT_BRANCH_SHA"' | head -1 | cut -d: -f1)
if [ -n "$ARM_GATE_LINE" ] && [ -n "$OUTSIDE_CALL_LINE" ] && [ "$ARM_GATE_LINE" -lt "$OUTSIDE_CALL_LINE" ]; then
  ok "guard.sh: gate_base_test_outside_subtree is called only after the arm-B gate (block-relative L$OUTSIDE_CALL_LINE > L$ARM_GATE_LINE) with RIG_PATH/base/branch sha — arm A never runs it"
else
  bad "REGRESSION: outside-subtree call line=${OUTSIDE_CALL_LINE:-missing} arm gate=${ARM_GATE_LINE:-missing} — arm A might run it, or it is not wired to the same base/head as the detection"
fi

echo "$ABT_BLOCK" | grep -E '^[[:space:]]*_ABT_OUTSIDE="unknown"' >/dev/null \
  && ok "guard.sh: _ABT_OUTSIDE starts as \"unknown\" (a count that was never measured cannot read as 0)" \
  || bad "guard.sh: _ABT_OUTSIDE is not initialised to \"unknown\" — an unmeasured submission could log a blank or a 0"

echo "$ABT_BLOCK" | grep -E 'AB-BASE-TEST bead=.*unclassified=\$_ABT_UNCLASSIFIED portable=\$_ABT_PORTABLE killed=\$_ABT_KILLED outside-subtree=\$_ABT_OUTSIDE"$' >/dev/null \
  && ok "guard.sh: AB-BASE-TEST log line ends with outside-subtree=\$_ABT_OUTSIDE (appended last, existing fields untouched)" \
  || bad "guard.sh: AB-BASE-TEST log line does not end with outside-subtree=\$_ABT_OUTSIDE"

_XK_LEAK=$(echo "$ABT_BLOCK" | grep -E 'gate_base_test_verdict|"\$_ABT_VERDICT" = ' | grep -c '_ABT_OUTSIDE')
eq "guard.sh: _ABT_OUTSIDE appears on NO verdict-computing or refusal line (count is logged, never decided on)" "${_XK_LEAK:-0}" "0"

# The tally: "counted separately" only means something if scripts/gate-ab-apuracao.sh
# really aggregates by verdict. That section was silent for two independent reasons
# (it read the DISPATCHER log, which never gets AB-BASE-TEST lines, and used \S in a
# BSD sed that does not understand it), so run the script's OWN pipeline text — not a
# re-typed regexp — over a synthetic guard log in the guard's real line format.
_APU="$SELF_DIR/../../../scripts/gate-ab-apuracao.sh"
if [ ! -r "$_APU" ]; then
  bad "cannot read $_APU — the tally cannot be checked"
else
  _APU_PIPE=$(awk "/^  grep -oE 'AB-BASE-TEST/,/head -10/" "$_APU")
  _APU_LOG=$(mktemp "${TMPDIR:-/tmp}/gate-rstae-apu.XXXXXX")
  {
    echo "[2026-09-25 09:21:37] [quality-gate-guard] AB-BASE-TEST bead=ga-a arm=B verdict=passou-na-base branch=fix/ga-a base=aaa detected=1 copy_ok=1 ran=1 failed=0 repaired=0 unclassified=0 outside-subtree=1"
    echo "[2026-09-25 09:22:37] [quality-gate-guard] AB-BASE-TEST bead=ga-b arm=B verdict=passou-na-base branch=fix/ga-b base=bbb detected=1 copy_ok=1 ran=1 failed=0"
    echo "[2026-09-25 09:23:37] [quality-gate-guard] AB-BASE-TEST bead=ga-c arm=B verdict=consertou-teste-vermelho branch=fix/ga-c base=ccc detected=1 copy_ok=1 ran=1 failed=0 repaired=1 unclassified=0 outside-subtree=0"
    echo "[2026-09-25 09:24:37] [quality-gate-guard] AB-BASE-TEST bead=ga-d arm=B verdict=reprovou-na-base branch=fix/ga-d base=ddd detected=1 copy_ok=1 ran=1 failed=1 repaired=0 unclassified=0 outside-subtree=unknown"
    echo "[2026-10-26 23:48:37] [quality-gate-guard] AB-BASE-TEST bead=ga-e arm=B verdict=consertou-portabilidade branch=fix/ga-e base=eee detected=1 copy_ok=1 ran=1 failed=0 repaired=0 unclassified=0 portable=1 outside-subtree=0"
    echo "[2026-10-28 04:07:50] [quality-gate-guard] AB-BASE-TEST bead=ga-f arm=B verdict=matou-mutantes branch=fix/ga-f base=fff detected=1 copy_ok=1 ran=1 failed=0 repaired=0 unclassified=0 portable=0 killed=1 outside-subtree=0"
  } > "$_APU_LOG"
  _APU_OUT=$(GUARD_LOG="$_APU_LOG" eval "$_APU_PIPE" 2>/dev/null | sed -E 's/^ +//; s/ +/ /g')
  rm -f "$_APU_LOG"
  printf '%s\n' "$_APU_OUT" | grep -qx '2 B passou-na-base' \
    && ok "apuracao tally aggregates the two passou-na-base lines into ONE row (2 B passou-na-base) — BSD-sed safe" \
    || bad "apuracao tally did not aggregate: got '$(printf '%s' "$_APU_OUT" | tr '\n' '|')'"
  printf '%s\n' "$_APU_OUT" | grep -qx '1 B consertou-teste-vermelho' \
    && ok "apuracao tally counts consertou-teste-vermelho as its own separate row (1 B consertou-teste-vermelho)" \
    || bad "apuracao tally lacks the separate consertou-teste-vermelho row: got '$(printf '%s' "$_APU_OUT" | tr '\n' '|')'"
  printf '%s\n' "$_APU_OUT" | grep -qx '1 B consertou-portabilidade' \
    && ok "apuracao tally counts consertou-portabilidade as its own separate row (1 B consertou-portabilidade) — the new verdict is measurable, not folded into another word" \
    || bad "apuracao tally lacks the separate consertou-portabilidade row: got '$(printf '%s' "$_APU_OUT" | tr '\n' '|')'"
  printf '%s\n' "$_APU_OUT" | grep -qx '1 B matou-mutantes' \
    && ok "apuracao tally counts matou-mutantes as its own separate row (1 B matou-mutantes, ga-4kykayr) — counted apart, with no change to the script" \
    || bad "apuracao tally lacks the separate matou-mutantes row: got '$(printf '%s' "$_APU_OUT" | tr '\n' '|')'"
  grep -q 'quality-gate-guard.log' "$_APU" \
    && ok "apuracao reads quality-gate-guard.log for the verdict section (where the guard actually writes AB-BASE-TEST)" \
    || bad "apuracao does not reference quality-gate-guard.log — verdict section would read the wrong log again"
fi

# 3d. Every arm-B path (including nao-consegui-medir / sem-teste-novo /
# reprovou-na-base, not just the block case) reaches the label+log lines —
# required so the A/B apuracao counts all four states, not just refusals.
echo "$ABT_BLOCK" | grep 'label add "\$MARKER_ID" "gate-ab:arm-b"' >/dev/null \
  && ok "guard.sh: arm-b label is written unconditionally within the arm-B branch (before the passou-na-base check, not inside it)" \
  || bad "guard.sh: gate-ab:arm-b label missing or misplaced"

echo "$ABT_BLOCK" | grep 'AB-BASE-TEST bead=\$BEAD_ID arm=B verdict=\$_ABT_VERDICT' >/dev/null \
  && ok "guard.sh: structured AB-BASE-TEST log line present with bead/arm/verdict fields (apuracao-parseable)" \
  || bad "guard.sh: AB-BASE-TEST structured log line missing or malformed"

# 3e. Ordering: the check runs AFTER RIG_PATH is resolved (it depends on it)
# and BEFORE Step 7 parks the marker as gate-status:queued (the actual
# enqueue point — refusing after that would be pointless).
RIGPATH_LINE=$(grep -n '\[ -d "\$RIG_PATH" \] || RIG_PATH=""' "$GUARD" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'Step 5b-pre2 (ga-rstae)' "$GUARD" | head -1 | cut -d: -f1)
QUEUED_LINE=$(grep -n 'label add    "\$MARKER_ID" "gate-status:queued"' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$RIGPATH_LINE" ] && [ -n "$CHECK_LINE" ] && [ "$RIGPATH_LINE" -lt "$CHECK_LINE" ]; then
  ok "guard.sh: RIG_PATH resolved (L$RIGPATH_LINE) BEFORE the base-test check (L$CHECK_LINE)"
else
  bad "guard.sh: ordering wrong — RIG_PATH=${RIGPATH_LINE:-missing} check=${CHECK_LINE:-missing}, check would run with an unresolved RIG_PATH"
fi

if [ -n "$CHECK_LINE" ] && [ -n "$QUEUED_LINE" ] && [ "$CHECK_LINE" -lt "$QUEUED_LINE" ]; then
  ok "guard.sh: base-test check (L$CHECK_LINE) fires BEFORE the marker is parked gate-status:queued (L$QUEUED_LINE) — genuinely pre-enqueue"
else
  bad "guard.sh: ordering wrong — check=${CHECK_LINE:-missing} queued-park=${QUEUED_LINE:-missing}, check would run too late to prevent enqueueing"
fi

# 3f. The neighboring ga-pj5va check (Step 5b-pre) is untouched and still
# wired — regression guard: this bead must not have weakened or duplicated
# the existing branch-content-coherence safety net while inserting its own.
PJ5VA_COUNT=$(grep -c 'Step 5b-pre (ga-pj5va)' "$GUARD")
eq "guard.sh: neighboring Step 5b-pre (ga-pj5va) check still present exactly once, untouched" "$PJ5VA_COUNT" "1"

CBC_CALL_COUNT=$(grep -c 'branch_bead_commit_verdict' "$GUARD")
if [ "$CBC_CALL_COUNT" -ge 2 ]; then
  ok "guard.sh: branch_bead_commit_verdict (ga-pj5va's function) still defined+called ($CBC_CALL_COUNT refs) — not weakened by this bead's insertion"
else
  bad "guard.sh: only $CBC_CALL_COUNT branch_bead_commit_verdict references — ga-pj5va's check may have been damaged"
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
