#!/usr/bin/env bash
# gate-guard-ab-base-test-pyjs.selftest.sh — Prove ga-kisvqp (E7 of ga-ufskhy):
# the ga-rstae "a new/changed test must FAIL on the pre-fix base" check, which
# only ever ran *.selftest.sh, now also measures pytest (test_*.py, *_test.py) and
# JS (*.test.* / *.spec.*) files — on the same arm B, with the same verdict words.
#
# MEASURED MOTIVATION (docs/reports/gate-e4-historico.md item 4): ceiling of
# 10.1% of gate FAILs (12.5% after 25/09) are "a test that passes without
# exercising the path". The base check only looked at bash selftests, so a
# submission whose only new tests were pytest/js read `sem-teste-novo` — the same
# word as "no test at all".
#
# What makes this harder than the bash case, and what each layer proves:
#   * These files import the code under test. Run against the BASE tree, a test
#     can "fail" for reasons that say nothing about the fix (no venv, no
#     node_modules, a clock, order, a missing network). So every test is also run
#     on the TIP (the branch, fix applied) as a CONTROL: only a test that PASSES
#     at tip and FAILS at base counts as evidence, and that pair is re-run ALONE
#     (lição wa-br1w4r / wa-u4bdpn) before it is believed.
#   * These files run builder-authored code against PRE-fix code (wa-x2stb: a test
#     run against old code really pushed). So every run is sandboxed: no network,
#     writes only to a scratch dir, scrubbed environment. No sandbox -> no run.
#   * Three states everywhere (tem / não-tem / não-consegui-saber): anything the
#     check could not measure is `nao-consegui-medir`, which never blocks. Only a
#     clean "every test that passes at tip ALSO passes at base" may refuse.
#
# Layers (same convention as gate-guard-ab-base-test-check.selftest.sh):
#   1. Pure functions, sourced with GATE_GUARD_LIB_ONLY=1.
#   2. Real runs: sandbox + pytest + vitest against throwaway git repos.
#   3. Drift guards on the live script: wiring, arm A untouched, bash 3.2.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { echo "  ok $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP $*"; SKIP=$((SKIP+1)); }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
bash -n "$GUARD" && ok "guard passes bash -n syntax check" || bad "guard has syntax errors"

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sets -euo pipefail and it leaks into this sourcing shell

need_fn() { type "$1" >/dev/null 2>&1 || { bad "FATAL: $1 not defined after LIB_ONLY sourcing"; return 1; }; }

# ── 1. Pure functions ────────────────────────────────────────────────────────
echo "── 1. pure function unit tests ──"

if need_fn gate_base_test_kind; then
  echo "  -- gate_base_test_kind --"
  eq "*.selftest.sh -> sh (the ga-rstae kind, unchanged)" \
    "$(gate_base_test_kind packs/town-deltas/assets/foo.selftest.sh)" "sh"
  eq "tests/test_mod.py -> py" "$(gate_base_test_kind tests/test_mod.py)" "py"
  eq "lib/mod_test.py -> py (pytest's second default pattern)" "$(gate_base_test_kind lib/mod_test.py)" "py"
  eq "lib/predictive_dialer/test_dialer.py -> py (a test outside tests/)" \
    "$(gate_base_test_kind lib/predictive_dialer/test_dialer.py)" "py"
  eq "tests-js/cacheBust.test.js -> js" "$(gate_base_test_kind tests-js/cacheBust.test.js)" "js"
  eq "a/b.spec.ts -> js" "$(gate_base_test_kind a/b.spec.ts)" "js"
  eq "x.test.mjs -> js" "$(gate_base_test_kind x.test.mjs)" "js"
  eq "x.test.cjs -> js" "$(gate_base_test_kind x.test.cjs)" "js"
  eq "x.test.tsx -> js" "$(gate_base_test_kind x.test.tsx)" "js"
  eq "tests/conftest.py is support, not a test -> none" "$(gate_base_test_kind tests/conftest.py)" "none"
  eq "tests/helpers.py -> none" "$(gate_base_test_kind tests/helpers.py)" "none"
  eq "lib/mod.py (production code) -> none" "$(gate_base_test_kind lib/mod.py)" "none"
  eq "src/foo.js -> none" "$(gate_base_test_kind src/foo.js)" "none"
  eq "foo.test.json is data, not a test -> none" "$(gate_base_test_kind foo.test.json)" "none"
  eq "notest.js -> none (name only contains 'test')" "$(gate_base_test_kind notest.js)" "none"
  eq "attest.py -> none (not test_*.py / *_test.py)" "$(gate_base_test_kind attest.py)" "none"
  eq "empty path -> none (unresolved input is never a test)" "$(gate_base_test_kind "")" "none"
fi

if need_fn gate_base_test_is_support; then
  echo "  -- gate_base_test_is_support --"
  eq "a py test file is test-side" "$(gate_base_test_is_support tests/test_mod.py)" "yes"
  eq "a js test file is test-side" "$(gate_base_test_is_support tests-js/a.test.js)" "yes"
  eq "conftest.py anywhere is test-side" "$(gate_base_test_is_support lib/conftest.py)" "yes"
  eq "a helper under tests/ is test-side" "$(gate_base_test_is_support tests/helpers/util.py)" "yes"
  eq "a helper under tests-js/ is test-side" "$(gate_base_test_is_support tests-js/setup.js)" "yes"
  eq "a file under __tests__/ is test-side" "$(gate_base_test_is_support src/__tests__/a.js)" "yes"
  eq "a fixture under fixtures/ is test-side" "$(gate_base_test_is_support tests/fixtures/a.json)" "yes"
  eq "production code is NOT test-side (it is the fix; it must stay at base)" \
    "$(gate_base_test_is_support lib/mod.py)" "no"
  eq "a directory merely CONTAINING 'test' in its name is not test-side (lib/contest/x.py)" \
    "$(gate_base_test_is_support lib/contest/x.py)" "no"
  eq "docs/tests.md: basename is not a test-directory component" "$(gate_base_test_is_support docs/tests.md)" "no"
  eq "empty path -> no" "$(gate_base_test_is_support "")" "no"
fi

# tsv <id> <outcome> [<id> <outcome> ...] -> an outcome table as the runners emit it:
# a "#ok" header (the run was READ) then one "id<TAB>outcome" row per test.
tsv() {
  printf '#ok\n'
  while [ "$#" -ge 2 ]; do printf '%s\t%s\n' "$1" "$2"; shift 2; done
}

if need_fn gate_base_test_decisive && need_fn gate_base_test_file_state; then
  echo "  -- gate_base_test_decisive --"
  TIP=$(tsv t::a pass t::b pass t::c fail)
  eq "a test that passes at tip and FAILS at base is decisive" \
    "$(gate_base_test_decisive "$TIP" "$(tsv t::a pass t::b fail t::c fail)")" "t::b"
  eq "a test that fails at tip too is NOT decisive (env noise, not the fix)" \
    "$(gate_base_test_decisive "$TIP" "$(tsv t::a pass t::b pass t::c fail)")" ""
  eq "a collection error at base makes every tip-PASSING test decisive, never the tip-failing one" \
    "$(gate_base_test_decisive "$TIP" "$(tsv t.py collect-error)" | tr '\n' ' ')" "t::a t::b "
  eq "a test ABSENT at base without a collection error is not decisive (unknown, not failed)" \
    "$(gate_base_test_decisive "$TIP" "$(tsv t::a pass)")" ""
  eq "a SKIP at base is not decisive" \
    "$(gate_base_test_decisive "$TIP" "$(tsv t::a skip t::b skip)")" ""
  TIP5=$(tsv a pass b pass c pass d pass e pass)
  BASE5=$(tsv a fail b fail c fail d fail e fail)
  eq "at most 3 decisive ids are reported (they are re-run ALONE one by one; the cost is bounded)" \
    "$(gate_base_test_decisive "$TIP5" "$BASE5" | wc -l | tr -d ' ')" "3"
  eq "GATE_ABT_ALONE_MAX overrides the bound" \
    "$(GATE_ABT_ALONE_MAX=1 gate_base_test_decisive "$TIP5" "$BASE5" | wc -l | tr -d ' ')" "1"
  eq "tip input with no #ok header (run not read) -> no decisive ids, not 'all of them'" \
    "$(gate_base_test_decisive "" "$BASE5")" ""
  eq "base input with no #ok header -> no decisive ids" \
    "$(gate_base_test_decisive "$TIP5" "")" ""
  eq "a malformed row (no outcome) poisons its table -> no decisive ids" \
    "$(gate_base_test_decisive "$TIP5" "$(printf '#ok\na\n')")" ""
  eq "a bad row must not be DROPPED while the rest is believed: base {a fail + unparseable row} -> no decisive ids, not 'a'" \
    "$(gate_base_test_decisive "$(tsv a pass)" "$(printf '#ok\na\tfail\nzzz\n')")" ""

  echo "  -- gate_base_test_file_state --"
  OKT=$(tsv t::a pass t::b pass)
  st() { gate_base_test_file_state "$1" "$2" "${3-}" "${4-}"; }
  eq "every tip-pass test also passes at base -> passes-on-base (the BLOCK case)" \
    "$(st "$OKT" "$(tsv t::a pass t::b pass)")" "passes-on-base"
  eq "fails at base, passes at tip, and the same pair holds when run ALONE -> fails-on-base" \
    "$(st "$OKT" "$(tsv t::a pass t::b fail)" "$(tsv t::b pass)" "$(tsv t::b fail)")" "fails-on-base"
  eq "fails at base in the file run but PASSES alone at base (order/leak dependent) -> unmeasured, never fails-on-base" \
    "$(st "$OKT" "$(tsv t::a pass t::b fail)" "$(tsv t::b pass)" "$(tsv t::b pass)")" "unmeasured"
  eq "fails alone at base but ALSO fails alone at tip (flaky/env) -> unmeasured" \
    "$(st "$OKT" "$(tsv t::a pass t::b fail)" "$(tsv t::b fail)" "$(tsv t::b fail)")" "unmeasured"
  eq "decisive test found but the ALONE runs never happened (no tables) -> unmeasured" \
    "$(st "$OKT" "$(tsv t::a pass t::b fail)")" "unmeasured"
  eq "alone tables present but unreadable (no #ok) -> unmeasured" \
    "$(st "$OKT" "$(tsv t::a pass t::b fail)" "t::b	pass" "t::b	fail")" "unmeasured"
  eq "tip all failing (control not green) -> unmeasured" \
    "$(st "$(tsv t::a fail)" "$(tsv t::a fail)")" "unmeasured"
  eq "tip collection error -> unmeasured" \
    "$(st "$(tsv t.py collect-error)" "$(tsv t.py collect-error)")" "unmeasured"
  eq "tip read cleanly with ZERO tests -> no-tests (a test_*.py script, not a test)" \
    "$(st "$(tsv)" "$(tsv)")" "no-tests"
  eq "tip table EMPTY STRING (unread) -> unmeasured, NOT no-tests (the erro==vazio collapse)" \
    "$(st "" "$(tsv t::a pass)")" "unmeasured"
  eq "base table EMPTY STRING (unread) -> unmeasured, NOT passes-on-base" \
    "$(st "$OKT" "")" "unmeasured"
  eq "a SKIP at base is not a pass -> unmeasured" \
    "$(st "$OKT" "$(tsv t::a pass t::b skip)")" "unmeasured"
  eq "a tip-pass test ABSENT at base (no collection error) -> unmeasured" \
    "$(st "$OKT" "$(tsv t::a pass)")" "unmeasured"
  eq "new symbol the fix adds: base collection ERROR, alone too, tip alone passes -> fails-on-base (classic TDD red)" \
    "$(st "$OKT" "$(tsv t.py collect-error)" "$(tsv t::a pass)" "$(tsv t.py collect-error)")" "fails-on-base"
  eq "skipped at tip AND base does not stop the passing tests from deciding -> passes-on-base" \
    "$(st "$(tsv t::a pass t::b skip)" "$(tsv t::a pass t::b skip)")" "passes-on-base"
  eq "a garbled outcome word poisons the table -> unmeasured" \
    "$(st "$OKT" "$(tsv t::a pass t::b maybe)")" "unmeasured"
  # The two cases above would answer 'unmeasured' even if a bad row were silently DROPPED.
  # These would not: drop the bad row and the answer becomes a confident passes-on-base /
  # fails-on-base — the exact "unread read as clear" collapse the #ok contract exists to stop.
  eq "a bad row in the BASE table must not be dropped: tip {a pass}, base {a pass + unparseable row} -> unmeasured, not passes-on-base" \
    "$(st "$(tsv t::a pass)" "$(printf '#ok\nt::a\tpass\nt::z\n')")" "unmeasured"
  eq "a bad row in the TIP table must not be dropped: tip {a pass + unparseable row}, base {a pass} -> unmeasured, not passes-on-base" \
    "$(st "$(printf '#ok\nt::a\tpass\nt::z\tmaybe\n')" "$(tsv t::a pass)")" "unmeasured"
  eq "a bad row in the ALONE-base table must not be dropped: confirmation needs a READABLE table -> unmeasured, not fails-on-base" \
    "$(st "$OKT" "$(tsv t::a pass t::b fail)" "$(tsv t::b pass)" "$(printf '#ok\nt::b\tfail\nt::q\n')")" "unmeasured"
fi

if need_fn gate_base_test_old_form_state; then
  echo "  -- gate_base_test_old_form_state --"
  eq "old form has a failing test -> old-fails (old red + new green = a repair, ga-yl1k3w)" \
    "$(gate_base_test_old_form_state "$(tsv t::a pass t::b fail)")" "old-fails"
  eq "old form collection error -> old-fails" \
    "$(gate_base_test_old_form_state "$(tsv t.py collect-error)")" "old-fails"
  eq "old form all green -> old-passes" \
    "$(gate_base_test_old_form_state "$(tsv t::a pass t::b skip)")" "old-passes"
  eq "old form read cleanly but no tests -> unknown" "$(gate_base_test_old_form_state "$(tsv)")" "unknown"
  eq "old form only skips -> unknown (skip is not green)" \
    "$(gate_base_test_old_form_state "$(tsv t::a skip)")" "unknown"
  eq "old form unread (empty string) -> unknown, never old-passes" \
    "$(gate_base_test_old_form_state "")" "unknown"
fi

# ── 2. Sandbox: the boundary that makes running builder tests against PRE-fix code safe ──
echo "── 2. sandbox ──"

# A scratch tree for this whole harness. mktemp under the default TMPDIR is a SYMLINKED path on
# macOS (/var -> /private/var) — exactly the shape the sandbox profile must be robust to.
H_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/gate-pyjs-selftest.XXXXXX")
trap '[ -n "${H_SCRATCH:-}" ] && rm -rf "$H_SCRATCH"' EXIT

if need_fn gate_base_test_sandbox_profile; then
  echo "  -- gate_base_test_sandbox_profile --"
  P=$(gate_base_test_sandbox_profile /private/tmp/scr /Users/someone)
  case "$P" in *"(deny network*)"*) ok "profile denies all network" ;; *) bad "profile does not deny network: $P" ;; esac
  case "$P" in *"(deny file-write*)"*) ok "profile denies all file writes by default" ;; *) bad "profile does not deny writes" ;; esac
  case "$P" in *'(subpath "/private/tmp/scr")'*) ok "profile allows writes only under the scratch subpath" ;; *) bad "scratch subpath not allowed" ;; esac
  case "$P" in *'(literal "/dev/null")'*) ok "profile keeps /dev/null writable (every tool redirects to it)" ;; *) bad "/dev/null not allowed" ;; esac
  N_ALLOW=$(printf '%s\n' "$P" | grep -c 'allow file-write')
  eq "exactly ONE write allowance (a second one is a widened sandbox)" "$N_ALLOW" "1"
  case "$P" in *'(deny file-read* (subpath "/Users/someone/Library/CloudStorage"))'*) ok "profile denies READ of the TCC-protected CloudStorage (a scan would raise the macOS prompt)" ;; *) bad "CloudStorage read not denied" ;; esac
  case "$P" in *'(subpath "/Users/someone/Documents")'*) ok "profile denies READ of Documents" ;; *) bad "Documents read not denied" ;; esac
  P2=$(gate_base_test_sandbox_profile /private/tmp/scr "")
  case "$P2" in *"Documents"*) bad "no home given but a home path was invented" ;; *) ok "no home given -> no read denials invented" ;; esac
  gate_base_test_sandbox_profile "" /Users/x >/dev/null 2>&1; eq "empty scratch -> refused (an empty subpath would allow everything)" "$?" "1"
  gate_base_test_sandbox_profile "relative/dir" /Users/x >/dev/null 2>&1; eq "relative scratch -> refused (the sandbox resolves absolute paths)" "$?" "1"
  gate_base_test_sandbox_profile '/tmp/a"b' /Users/x >/dev/null 2>&1; eq "scratch with a double quote -> refused (profile injection)" "$?" "1"
  gate_base_test_sandbox_profile '/tmp/a\b' /Users/x >/dev/null 2>&1; eq "scratch with a backslash -> refused" "$?" "1"
  gate_base_test_sandbox_profile "$(printf '/tmp/a\nb')" /Users/x >/dev/null 2>&1; eq "scratch with a newline -> refused" "$?" "1"
  eq "a refused profile prints nothing (no half-built profile to run with)" \
    "$(gate_base_test_sandbox_profile '/tmp/a"b' /Users/x 2>/dev/null)" ""
  gate_base_test_sandbox_profile /private/tmp/scr 'bad"home' >/dev/null 2>&1; eq "home with a quote -> refused" "$?" "1"
fi

if need_fn gate_base_test_sandbox_ok; then
  echo "  -- gate_base_test_sandbox_ok (runs the real sandbox) --"
  mkdir -p "$H_SCRATCH/probe1"
  gate_base_test_sandbox_ok "$H_SCRATCH/probe1"; eq "a working sandbox-exec passes the probe" "$?" "0"
  gate_base_test_sandbox_ok "$H_SCRATCH/does-not-exist" 2>/dev/null; eq "a scratch dir that does not exist -> probe fails (not 'sandbox ok')" "$?" "1"
  gate_base_test_sandbox_ok "" 2>/dev/null; eq "empty scratch -> probe fails" "$?" "1"
  # Symlinked scratch: the profile must be built from the REAL path or every write is denied.
  ln -s "$H_SCRATCH/probe1" "$H_SCRATCH/link1"
  gate_base_test_sandbox_ok "$H_SCRATCH/link1"; eq "a scratch given as a SYMLINK still passes (canonicalised, not silently read-only)" "$?" "0"
  # A sandbox that does not sandbox must be CAUGHT, not trusted. Three fakes, each a distinct way to lie:
  mkdir -p "$H_SCRATCH/fakes" "$H_SCRATCH/probe2"
  printf '#!/bin/bash\nshift 2\nexec "$@"\n' > "$H_SCRATCH/fakes/decorative"      # ignores the profile, runs the command freely
  printf '#!/bin/bash\nexit 1\n'             > "$H_SCRATCH/fakes/denies-all"      # refuses everything, inside writes too
  printf '#!/bin/bash\nexit 0\n'             > "$H_SCRATCH/fakes/runs-nothing"    # claims success, executes nothing
  chmod +x "$H_SCRATCH/fakes/"*
  ( GATE_ABT_SANDBOX_EXEC="$H_SCRATCH/fakes/decorative" gate_base_test_sandbox_ok "$H_SCRATCH/probe2" 2>/dev/null )
  eq "a DECORATIVE sandbox (lets the outside write through) -> probe fails" "$?" "1"
  LEFT=$(ls -A "$(dirname "$(cd "$H_SCRATCH/probe2" && pwd -P)")" 2>/dev/null | grep -c '^\.gate-abt-probe\.')
  eq "the probe cleans up the outside file it provoked from a decorative sandbox" "$LEFT" "0"
  ( GATE_ABT_SANDBOX_EXEC="$H_SCRATCH/fakes/denies-all" gate_base_test_sandbox_ok "$H_SCRATCH/probe2" 2>/dev/null )
  eq "a sandbox that denies even the inside write -> probe fails" "$?" "1"
  ( GATE_ABT_SANDBOX_EXEC="$H_SCRATCH/fakes/runs-nothing" gate_base_test_sandbox_ok "$H_SCRATCH/probe2" 2>/dev/null )
  eq "a sandbox that reports success but runs nothing (no inside file appears) -> probe fails" "$?" "1"
  # A sandbox that cannot deny is not a sandbox: with sandbox-exec hidden the probe must fail.
  ( GATE_ABT_SANDBOX_EXEC=/nonexistent/sandbox-exec gate_base_test_sandbox_ok "$H_SCRATCH/probe1" 2>/dev/null ); eq "sandbox-exec unavailable -> probe fails, never 'ok'" "$?" "1"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
