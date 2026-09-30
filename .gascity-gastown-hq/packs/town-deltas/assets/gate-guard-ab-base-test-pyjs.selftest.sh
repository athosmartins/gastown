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
# Sections 4 and 5 run real sandboxed pytest/vitest and take minutes on a loaded host. GATE_SELFTEST_ONLY
# ("4 5", "5", ...) limits the run to those; unset = everything. Sections 1-3 are pure and always run.
want() { [ -z "${GATE_SELFTEST_ONLY:-}" ] && return 0; case " $GATE_SELFTEST_ONLY " in (*" $1 "*) return 0 ;; (*) return 1 ;; esac; }

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

if need_fn gate_base_test_is_code_helper; then
  echo "  -- gate_base_test_is_code_helper --"
  eq "tests/conftest.py is a code helper" "$(gate_base_test_is_code_helper tests/conftest.py)" "yes"
  eq "a .py helper under tests/ is" "$(gate_base_test_is_code_helper tests/gate_pyjs_helper.py)" "yes"
  eq "a .js setup file under tests-js/ is" "$(gate_base_test_is_code_helper tests-js/setup.js)" "yes"
  eq "a .ts helper under __tests__/ is" "$(gate_base_test_is_code_helper src/__tests__/util.ts)" "yes"
  eq "a shell helper under tests/ is" "$(gate_base_test_is_code_helper tests/run.sh)" "yes"
  eq "a json fixture is DATA, not a code helper" "$(gate_base_test_is_code_helper tests/fixtures/data.json)" "no"
  eq "a snapshot / text fixture is data" "$(gate_base_test_is_code_helper tests/fixtures/out.txt)" "no"
  eq "a test file is a TEST, handled on its own, not a helper" "$(gate_base_test_is_code_helper tests/test_mod.py)" "no"
  eq "a js test file likewise" "$(gate_base_test_is_code_helper tests-js/a.test.js)" "no"
  eq "production code is not test-side at all" "$(gate_base_test_is_code_helper lib/mod.py)" "no"
  eq "a *.selftest.sh file is a test of the sh kind, not a helper" "$(gate_base_test_is_code_helper packs/x/foo.selftest.sh)" "no"
  eq "empty -> no" "$(gate_base_test_is_code_helper "")" "no"
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

# ── 3. Result parsers: a run's raw output -> an outcome table, or NOTHING if it cannot be trusted ──
echo "── 3. result parsers ──"
TAB=$(printf '\t')

if need_fn gate_base_test_parse_pytest; then
  echo "  -- gate_base_test_parse_pytest --"
  PJ="$H_SCRATCH/pj"; mkdir -p "$PJ"
  printf '%s\n' '{"id": "t.py::test_a", "o": "pass"}' '{"id": "t.py::test_b[x y]", "o": "fail"}' '{"end": true}' > "$PJ/good.jsonl"
  OUT=$(gate_base_test_parse_pytest "$PJ/good.jsonl"); RC=$?
  eq "a complete file parses (status 0)" "$RC" "0"
  eq "...to an #ok-headed TSV table, ids with spaces intact" "$OUT" "$(printf '#ok\nt.py::test_a\tpass\nt.py::test_b[x y]\tfail')"
  printf '%s\n' '{"end": true}' > "$PJ/zero.jsonl"
  eq "a complete file with ZERO tests is a readable empty table (#ok only)" "$(gate_base_test_parse_pytest "$PJ/zero.jsonl")" "#ok"
  OUT=$(gate_base_test_parse_pytest "$PJ/missing.jsonl"); RC=$?
  eq "a missing file (pytest died before writing) -> status 1" "$RC" "1"; eq "...and NO output" "$OUT" ""
  printf '%s\n' '{"id": "t.py::test_a", "o": "pass"}' > "$PJ/trunc.jsonl"
  OUT=$(gate_base_test_parse_pytest "$PJ/trunc.jsonl"); RC=$?
  eq "a file with no end sentinel (killed mid-write) -> status 1" "$RC" "1"; eq "...and NO output, not the rows it happens to hold" "$OUT" ""
  : > "$PJ/empty.jsonl"
  gate_base_test_parse_pytest "$PJ/empty.jsonl" >/dev/null; eq "a 0-byte file -> status 1 (empty is not 'zero tests')" "$?" "1"
  printf '%s\n' '{"id": "t.py::test_a", "o": "pass"}' '{"id": "t.py::tes' > "$PJ/cut.jsonl"
  gate_base_test_parse_pytest "$PJ/cut.jsonl" >/dev/null; eq "a line cut in half (invalid JSON) -> status 1" "$?" "1"
  printf '%s\n' '{"end": true}' '{"id": "t.py::test_a", "o": "pass"}' > "$PJ/after.jsonl"
  gate_base_test_parse_pytest "$PJ/after.jsonl" >/dev/null; eq "rows AFTER the sentinel (the file is not what the plugin wrote) -> status 1" "$?" "1"
  gate_base_test_parse_pytest "" >/dev/null; eq "empty path argument -> status 1" "$?" "1"
fi

if need_fn gate_base_test_parse_vitest; then
  echo "  -- gate_base_test_parse_vitest --"
  VJ="$H_SCRATCH/vj"; mkdir -p "$VJ"
  cat > "$VJ/run.json" <<'JSON'
{"numTotalTests":5,"success":false,"testResults":[
 {"name":"/x/wt/tests-js/a.test.js","status":"failed","assertionResults":[
    {"fullName":"A does x","status":"passed"},
    {"fullName":"A does (y)? [z]","status":"failed"},
    {"fullName":"A later","status":"pending"},
    {"fullName":"A todo","status":"todo"}]},
 {"name":"/x/wt/tests-js/ab.test.js","status":"passed","assertionResults":[{"fullName":"other","status":"passed"}]},
 {"name":"/x/wt/old-tests-js/a.test.js","status":"passed","assertionResults":[{"fullName":"impostor from another directory","status":"passed"}]},
 {"name":"/x/wt/tests-js/b.test.js","status":"failed","assertionResults":[],"message":"Cannot find module"},
 {"name":"/x/wt/tests-js/hook.test.js","status":"failed","assertionResults":[{"fullName":"H ok","status":"passed"}],"message":"afterAll blew up"},
 {"name":"/x/wt/tests-js/none.test.js","status":"passed","assertionResults":[]},
 {"name":"/x/wt/tests-js/weird.test.js","status":"passed","assertionResults":[{"fullName":"W","status":"exploded"}]}
]}
JSON
  eq "rows of the ONE requested file, statuses mapped, names with regex metacharacters intact" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/a.test.js)" \
    "$(printf '#ok\ntests-js/a.test.js::A does x\tpass\ntests-js/a.test.js::A does (y)? [z]\tfail\ntests-js/a.test.js::A later\tskip\ntests-js/a.test.js::A todo\tskip')"
  eq "a sibling file is read as itself (ab.test.js is not a.test.js)" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/ab.test.js | sed -n 2p)" "$(printf 'tests-js/ab.test.js::other\tpass')"
  eq "a file from ANOTHER directory whose path merely ends the same way (old-tests-js/a.test.js vs tests-js/a.test.js) is not selected" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/a.test.js | grep -c impostor)" "0"
  eq "a suite that failed before any test ran is a collect-error row, keyed by the file" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/b.test.js)" "$(printf '#ok\ntests-js/b.test.js\tcollect-error')"
  eq "a suite that FAILED though every test passed (hook error) is not allowed to read as all-green" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/hook.test.js)" \
    "$(printf '#ok\ntests-js/hook.test.js::H ok\tpass\ntests-js/hook.test.js\tcollect-error')"
  eq "a suite that passed with zero assertions is a readable empty table" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/none.test.js)" "#ok"
  eq "an unknown status word is passed through (the classifier poisons it; it is not mapped to pass)" \
    "$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/weird.test.js | sed -n 2p)" "$(printf 'tests-js/weird.test.js::W\texploded')"
  OUT=$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/notrun.test.js); RC=$?
  eq "the requested file is not in the report at all -> status 1" "$RC" "1"; eq "...and NO output" "$OUT" ""
  printf '{"success":true}' > "$VJ/noarr.json"
  gate_base_test_parse_vitest "$VJ/noarr.json" tests-js/a.test.js >/dev/null; eq "a report with no testResults array -> status 1" "$?" "1"
  printf '{"testResults":[{"name":"/x/tests-js/a.te' > "$VJ/cut.json"
  gate_base_test_parse_vitest "$VJ/cut.json" tests-js/a.test.js >/dev/null; eq "truncated JSON -> status 1" "$?" "1"
  gate_base_test_parse_vitest "$VJ/nope.json" tests-js/a.test.js >/dev/null; eq "missing file -> status 1" "$?" "1"
  gate_base_test_parse_vitest "$VJ/run.json" "" >/dev/null; eq "empty relfile -> status 1" "$?" "1"
  # End to end with the classifier: what the parser hands over must be what the classifier understands.
  T=$(gate_base_test_parse_vitest "$VJ/run.json" tests-js/a.test.js)
  eq "parser output feeds the classifier: the failing test is decisive only against a base where it passes at tip" \
    "$(gate_base_test_decisive "$T" "$(printf '#ok\ntests-js/a.test.js::A does x\tfail')")" "tests-js/a.test.js::A does x"
fi

if need_fn gate_base_test_totals_field; then
  echo "  -- gate_base_test_totals_field --"
  SCAN=$(printf 'FILE a.py kind=py state=fails-on-base why=- old=-\nTOTALS files=3 counted=2 copy_ok=2 ran=1 failed=1 repaired=0 unclassified=1 py=2 js=1\n')
  eq "reads a field from the TOTALS line" "$(gate_base_test_totals_field "$SCAN" counted)" "2"
  eq "a key that is a prefix of another (ran vs repaired) is matched EXACTLY" "$(gate_base_test_totals_field "$SCAN" ran)" "1"
  eq "zero is a value, not an absence" "$(gate_base_test_totals_field "$SCAN" repaired)" "0"
  OUT=$(gate_base_test_totals_field "$SCAN" nope); RC=$?
  eq "an unknown key -> status 1" "$RC" "1"; eq "...and prints nothing" "$OUT" ""
  gate_base_test_totals_field "FILE a.py kind=py state=x" counted >/dev/null; eq "no TOTALS line at all -> status 1 (never 0)" "$?" "1"
  gate_base_test_totals_field "TOTALS files=3 counted=two ran=1" counted >/dev/null; eq "a non-numeric value -> status 1" "$?" "1"
  gate_base_test_totals_field "TOTALS files=3 counted= ran=1" counted >/dev/null; eq "an empty value -> status 1" "$?" "1"
  gate_base_test_totals_field "" counted >/dev/null; eq "empty output -> status 1" "$?" "1"
  gate_base_test_totals_field "$SCAN" "" >/dev/null; eq "empty key -> status 1" "$?" "1"
  gate_base_test_totals_field "UNREAD" counted >/dev/null; eq "UNREAD carries no totals -> status 1" "$?" "1"
fi

# ── 4. Real runs: sandbox + pytest in throwaway repos ──
echo "── 4. real runs (sandbox + pytest) ──"

# The rig's own interpreter is what production uses ($rig/venv/bin/python). The fixture rigs borrow the
# WA rig's venv through a DIRECTORY symlink (a symlinked python binary would lose its pyvenv.cfg).
WA_RIG=/Users/athos/gt/whatsapp_automation
WA_VENV="$WA_RIG/venv"
WA_NODE_MODULES="$WA_RIG/node_modules"
HAVE_PYTEST=no
if [ -x "$WA_VENV/bin/python" ] && "$WA_VENV/bin/python" -c 'import pytest' >/dev/null 2>&1; then HAVE_PYTEST=yes; fi
HAVE_VITEST=no
if [ -f "$WA_NODE_MODULES/vitest/vitest.mjs" ] && command -v node >/dev/null 2>&1; then HAVE_VITEST=yes; fi

# mk_rig <dir>: a git repo laid out like a rig, one commit, with the borrowed venv/node_modules.
mk_rig() {
  local d="$1"
  mkdir -p "$d/lib" "$d/tests" "$d/tests-js"
  git -C "$d" init -q . && git -C "$d" config user.email t@t && git -C "$d" config user.name t
  printf '[pytest]\npythonpath = . lib\ntestpaths = tests\n' > "$d/pytest.ini"
  : > "$d/lib/__init__.py"
  printf 'def double(x):\n    return x + x\n' > "$d/lib/mod.py"
  [ "$HAVE_PYTEST" = yes ] && ln -s "$WA_VENV" "$d/venv"
  [ "$HAVE_VITEST" = yes ] && ln -s "$WA_NODE_MODULES" "$d/node_modules"
  printf "export default { test: { environment: 'node', include: ['tests-js/**/*.test.js'], globals: true } };\n" > "$d/vitest.config.js"
  printf '/venv\n/node_modules\n' > "$d/.gitignore"
}

if want 4 && need_fn gate_base_test_py_interp; then
  echo "  -- gate_base_test_py_interp --"
  if [ "$HAVE_PYTEST" = yes ]; then
    mk_rig "$H_SCRATCH/rig-interp"
    eq "a rig with a venv that can import pytest -> that venv's python" \
      "$(gate_base_test_py_interp "$H_SCRATCH/rig-interp")" "$H_SCRATCH/rig-interp/venv/bin/python"
  else
    skip "no pytest-capable venv at $WA_VENV on this host — interpreter lookup not exercised"
  fi
  mkdir -p "$H_SCRATCH/rig-novenv"
  OUT=$(gate_base_test_py_interp "$H_SCRATCH/rig-novenv"); RC=$?
  eq "a rig with NO venv -> status 1" "$RC" "1"; eq "...and prints nothing (no PATH python is guessed: it would have no pytest)" "$OUT" ""
  mkdir -p "$H_SCRATCH/rig-fakevenv/venv/bin"
  # A python that RUNS fine but has no pytest (exits 0 for anything except an `import pytest`): the
  # check must be the import itself, not merely "the interpreter starts".
  printf '#!/bin/bash\ncase "$*" in *pytest*) exit 1 ;; esac\nexit 0\n' > "$H_SCRATCH/rig-fakevenv/venv/bin/python"; chmod +x "$H_SCRATCH/rig-fakevenv/venv/bin/python"
  gate_base_test_py_interp "$H_SCRATCH/rig-fakevenv" >/dev/null; eq "a venv whose python starts but cannot import pytest -> status 1" "$?" "1"
  mkdir -p "$H_SCRATCH/rig-noexec/venv/bin"; : > "$H_SCRATCH/rig-noexec/venv/bin/python"
  gate_base_test_py_interp "$H_SCRATCH/rig-noexec" >/dev/null; eq "a venv python that is not executable -> status 1" "$?" "1"
  gate_base_test_py_interp "" >/dev/null; eq "empty rig path -> status 1" "$?" "1"
fi

if want 4 && need_fn gate_base_test_sandbox_exec; then
  echo "  -- gate_base_test_sandbox_exec (real sandbox) --"
  SX="$H_SCRATCH/sx"; mkdir -p "$SX" "$H_SCRATCH/sxcwd"
  # A listener on loopback: the POSITIVE CONTROL for the network claim. Without a reachable target a
  # refused connection would look exactly like a sandbox-denied one.
  python3 -c 'import socket,time
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1], flush=True); s.listen(8); time.sleep(300)' > "$H_SCRATCH/port.txt" &
  LISTENER_PID=$!
  trap 'kill "$LISTENER_PID" 2>/dev/null; [ -n "${H_SCRATCH:-}" ] && rm -rf "$H_SCRATCH"' EXIT
  for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$H_SCRATCH/port.txt" ] && break; sleep 0.3; done
  PORT=$(head -1 "$H_SCRATCH/port.txt" 2>/dev/null)
  CONNECT="import socket,sys; socket.create_connection(('127.0.0.1',$PORT),timeout=3)"
  python3 -c "$CONNECT" >/dev/null 2>&1; eq "control: an UNSANDBOXED connect to the local listener succeeds" "$?" "0"

  gate_base_test_sandbox_exec "$SX" 20 "$H_SCRATCH/sxcwd" python3 -c "$CONNECT" >/dev/null 2>&1
  eq "the SAME connect under the sandbox is refused (network is denied, not merely unreachable)" "$([ $? -ne 0 ] && echo denied || echo allowed)" "denied"

  gate_base_test_sandbox_exec "$SX" 20 "$H_SCRATCH/sxcwd" /usr/bin/touch "$H_SCRATCH/outside-file" >/dev/null 2>&1
  eq "a write outside the scratch is refused" "$([ -e "$H_SCRATCH/outside-file" ] && echo written || echo refused)" "refused"
  gate_base_test_sandbox_exec "$SX" 20 "$H_SCRATCH/sxcwd" /usr/bin/touch "$SX/inside-file" >/dev/null 2>&1
  eq "a write inside the scratch works" "$([ -e "$SX/inside-file" ] && echo written || echo refused)" "written"

  SECRET_FOR_TEST=hunter2 gate_base_test_sandbox_exec "$SX" 20 "$H_SCRATCH/sxcwd" /usr/bin/env >/dev/null 2>&1
  ENVDUMP=$(cat "$SX/run.log" 2>/dev/null)
  case "$ENVDUMP" in *hunter2*|*SECRET_FOR_TEST*) bad "the caller's environment leaked into the sandboxed run" ;; *) ok "the caller's environment does not leak (env -i)" ;; esac
  REALSX=$(cd "$SX" && pwd -P)
  case "$ENVDUMP" in *"HOME=$REALSX/home"*) ok "HOME is pointed into the scratch" ;; *) bad "HOME not scratch-local: $(printf '%s' "$ENVDUMP" | grep '^HOME=')" ;; esac
  case "$ENVDUMP" in *"TMPDIR=$REALSX/tmp"*) ok "TMPDIR is pointed into the scratch" ;; *) bad "TMPDIR not scratch-local" ;; esac

  gate_base_test_sandbox_exec "$SX" 20 "$H_SCRATCH/sxcwd" /bin/pwd >/dev/null 2>&1
  eq "the command runs in the requested cwd" "$(cat "$SX/run.log")" "$(cd "$H_SCRATCH/sxcwd" && pwd -P)"
  gate_base_test_sandbox_exec "$SX" 20 "$H_SCRATCH/sxcwd" /bin/sh -c 'exit 7' >/dev/null 2>&1
  eq "the command's exit status is passed through" "$?" "7"
  T0=$SECONDS
  gate_base_test_sandbox_exec "$SX" 2 "$H_SCRATCH/sxcwd" /bin/sleep 60 >/dev/null 2>&1
  RC=$?; ELAPSED=$((SECONDS - T0))
  eq "a run past its budget is killed and reported as 124" "$RC" "124"
  if [ "$ELAPSED" -le 12 ]; then ok "...and promptly (${ELAPSED}s for a 2s budget)"; else bad "timeout took ${ELAPSED}s for a 2s budget"; fi
  gate_base_test_sandbox_exec "" 5 "$H_SCRATCH/sxcwd" /usr/bin/true >/dev/null 2>&1; eq "no scratch -> not run (status 97)" "$?" "97"
  gate_base_test_sandbox_exec "$SX" 5 "$H_SCRATCH/no-such-cwd" /usr/bin/true >/dev/null 2>&1; eq "cwd that does not exist -> not run (status 97), never run in the caller's cwd" "$?" "97"
  ( GATE_ABT_SANDBOX_EXEC=/nonexistent/sandbox-exec gate_base_test_sandbox_exec "$SX" 5 "$H_SCRATCH/sxcwd" /usr/bin/touch "$SX/should-not-exist" >/dev/null 2>&1 )
  eq "sandbox-exec unavailable -> status 97 AND the command did not run unsandboxed" \
    "$([ -e "$SX/should-not-exist" ] && echo ran || echo not-run)" "not-run"
fi

if want 4 && need_fn gate_base_test_run_table; then
  echo "  -- gate_base_test_run_table (pytest) --"
  if [ "$HAVE_PYTEST" != yes ]; then
    skip "no pytest-capable venv at $WA_VENV — pytest runs not exercised"
  else
    RIG="$H_SCRATCH/rig-py"; mk_rig "$RIG"
    cat > "$RIG/tests/test_many.py" <<'PY'
import pytest

def test_pass():
    assert 1 + 1 == 2

def test_fail():
    assert 1 + 1 == 3

@pytest.mark.skip(reason="x")
def test_skip():
    pass

@pytest.mark.parametrize("v", ["a b", "c"])
def test_param(v):
    assert v
PY
    printf 'from lib.nope import missing\n\ndef test_x():\n    assert missing\n' > "$RIG/tests/test_collect.py"
    printf 'import time\n\ndef test_slow():\n    time.sleep(60)\n' > "$RIG/tests/test_slow.py"
    printf 'def helper():\n    return 1\n' > "$RIG/tests/test_zero.py"
    printf 'import socket\n\ndef test_net():\n    socket.create_connection(("127.0.0.1", %s), timeout=3)\n' "$PORT" > "$RIG/tests/test_net.py"
    printf 'import pathlib\n\ndef test_write():\n    pathlib.Path("%s/pytest-escape").write_text("x")\n' "$H_SCRATCH" > "$RIG/tests/test_write.py"
    RS="$H_SCRATCH/rs"; mkdir -p "$RS"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_many.py); RC=$?
    eq "a pytest file runs to a readable table (status 0)" "$RC" "0"
    eq "...with one row per test, statuses and parametrised ids right" "$T" \
      "$(printf '#ok\ntests/test_many.py::test_pass\tpass\ntests/test_many.py::test_fail\tfail\ntests/test_many.py::test_skip\tskip\ntests/test_many.py::test_param[a b]\tpass\ntests/test_many.py::test_param[c]\tpass')"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_many.py "tests/test_many.py::test_param[a b]")
    eq "a single test run ALONE (by node id) yields only that test" "$T" "$(printf '#ok\ntests/test_many.py::test_param[a b]\tpass')"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_collect.py); RC=$?
    eq "a collection error is a readable table with a collect-error row (status 0), not a failed read" "$RC" "0"
    eq "...keyed by the file" "$T" "$(printf '#ok\ntests/test_collect.py\tcollect-error')"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_zero.py); RC=$?
    eq "a test_*.py with no tests is a readable EMPTY table" "$T" "#ok"
    T=$(GATE_ABT_RUN_TIMEOUT=3 gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_slow.py); RC=$?
    eq "a run that exceeds its budget is UNREADABLE (status 1), never 'zero tests'" "$RC" "1"; eq "...and prints nothing" "$T" ""
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_net.py)
    eq "a test that reaches the network is FAILED by the sandbox, not passed" "$T" "$(printf '#ok\ntests/test_net.py::test_net\tfail')"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_write.py)
    eq "a test that writes outside the scratch is FAILED by the sandbox" "$T" "$(printf '#ok\ntests/test_write.py::test_write\tfail')"
    eq "...and the file was not created" "$([ -e "$H_SCRATCH/pytest-escape" ] && echo created || echo absent)" "absent"
    gate_base_test_run_table py "$H_SCRATCH/rig-novenv" "$RIG" "$RS" tests/test_many.py >/dev/null; eq "a rig with no usable interpreter -> status 1" "$?" "1"
    gate_base_test_run_table rb "$RIG" "$RIG" "$RS" tests/test_many.py >/dev/null; eq "an unknown kind -> status 1" "$?" "1"
    gate_base_test_run_table py "$RIG" "$RIG/no-such-dir" "$RS" tests/test_many.py >/dev/null; eq "a cwd that does not exist -> status 1" "$?" "1"
    gate_base_test_run_table py "$RIG" "$RIG" "$RS" "" >/dev/null; eq "an empty test file -> status 1" "$?" "1"
    # Node ids WITHOUT running anything: the cheap way to get a control sample from a file too slow to run in full.
    if type gate_base_test_collect_ids >/dev/null 2>&1; then
      IDS=$(gate_base_test_collect_ids py "$RIG" "$RIG" "$RS" tests/test_many.py); RC=$?
      eq "collect-only lists every node id, parametrised ids with spaces intact (status 0)" "$RC" "0"
      eq "...exactly the five tests, in file order" "$IDS" "$(printf 'tests/test_many.py::test_pass\ntests/test_many.py::test_fail\ntests/test_many.py::test_skip\ntests/test_many.py::test_param[a b]\ntests/test_many.py::test_param[c]')"
      eq "nothing was executed: no test ran (a failing test is listed, not run)" "$(GATE_ABT_SAMPLE=2 gate_base_test_collect_ids py "$RIG" "$RIG" "$RS" tests/test_many.py | wc -l | tr -d ' ')" "2"
      OUT=$(gate_base_test_collect_ids py "$RIG" "$RIG" "$RS" tests/test_zero.py); RC=$?
      eq "a file with no tests is a readable EMPTY list (status 0, nothing printed)" "$RC/$OUT" "0/"
      OUT=$(gate_base_test_collect_ids py "$RIG" "$RIG" "$RS" tests/test_collect.py); RC=$?
      eq "a file that cannot be imported -> status 1 and no ids (unreadable, never 'no tests')" "$RC/$OUT" "1/"
      OUT=$(gate_base_test_collect_ids py "$RIG" "$RIG" "$RS" tests/does_not_exist.py); RC=$?
      eq "a file that does not exist -> status 1" "$RC/$OUT" "1/"
      gate_base_test_collect_ids js "$RIG" "$RIG" "$RS" tests-js/a.test.js >/dev/null; eq "js is not supported -> status 1 (the caller falls back to a full run)" "$?" "1"
      gate_base_test_collect_ids py "$H_SCRATCH/rig-novenv" "$RIG" "$RS" tests/test_many.py >/dev/null; eq "a rig with no usable interpreter -> status 1" "$?" "1"
    else
      bad "gate_base_test_collect_ids not defined"
    fi
    # Fail-fast: stop after N failures. The table then holds exactly those failures and is NOT a full run.
    printf 'import pytest\n\n@pytest.mark.parametrize("i", range(6))\ndef test_bad(i):\n    assert False\n' > "$RIG/tests/test_manyfail.py"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_manyfail.py "" 2)
    eq "with a fail-fast bound of 2, exactly 2 failures are recorded (the other 4 tests never ran)" "$(printf '%s\n' "$T" | grep -c "$(printf '\tfail$')")" "2"
    eq "...and the table is still a readable one (#ok header)" "$(printf '%s\n' "$T" | head -1)" "#ok"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_manyfail.py "" "")
    eq "no bound -> all 6 failures are recorded" "$(printf '%s\n' "$T" | grep -c "$(printf '\tfail$')")" "6"
    gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_manyfail.py "" "two" >/dev/null
    eq "a non-numeric bound -> status 1 (never silently 'no bound')" "$?" "1"
    # What the plugin records for the awkward phases — each of these is a way a run could be misread.
    printf 'import pytest\n\n@pytest.fixture\ndef boom():\n    yield\n    raise RuntimeError("teardown")\n\ndef test_td(boom):\n    assert True\n' > "$RIG/tests/test_teardown.py"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_teardown.py)
    eq "a test that passed but failed in TEARDOWN is a failure, not a pass" "$T" "$(printf '#ok\ntests/test_teardown.py::test_td\tfail')"
    printf 'import pytest\npytest.importorskip("no_such_module_xyz_gate")\n\ndef test_x():\n    assert True\n' > "$RIG/tests/test_modskip.py"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_modskip.py)
    eq "a module skipped wholesale (missing dependency) is a SKIP row, not 'no tests'" "$T" "$(printf '#ok\ntests/test_modskip.py\tskip')"
    printf 'import pytest\n\n@pytest.mark.xfail(reason="known")\ndef test_xf():\n    assert False\n' > "$RIG/tests/test_xfail.py"
    T=$(gate_base_test_run_table py "$RIG" "$RIG" "$RS" tests/test_xfail.py)
    eq "an expected failure (xfail) is a skip: neither a pass nor a failure" "$T" "$(printf '#ok\ntests/test_xfail.py::test_xf\tskip')"
    # pytest's INTERNALERROR (exit 3) still runs sessionfinish, so the plugin writes a WELL-FORMED but
    # PARTIAL table. Only the exit status tells it apart from a complete run.
    RIG2="$H_SCRATCH/rig-py-internal"; mk_rig "$RIG2"
    printf 'def pytest_runtest_makereport(item, call):\n    raise RuntimeError("plugin bug")\n' > "$RIG2/tests/conftest.py"
    printf 'def test_a():\n    assert True\n\ndef test_b():\n    assert True\n' > "$RIG2/tests/test_two.py"
    OUT=$(gate_base_test_run_table py "$RIG2" "$RIG2" "$RS" tests/test_two.py); RC=$?
    eq "a pytest INTERNALERROR (exit 3) is UNREADABLE even though a table file exists -> status 1" "$RC" "1"
    eq "...and prints nothing" "$OUT" ""
    # The guard runs under `set -euo pipefail`: a non-zero from the runner must be an ANSWER, not an abort.
    OUT=$(bash -c 'set -euo pipefail; GATE_GUARD_LIB_ONLY=1 . "$1"; gate_base_test_run_table py "$2" "$2" "$3" tests/test_nope_missing.py >/dev/null 2>&1 || true; echo survived' _ "$GUARD" "$RIG" "$RS" 2>&1 | tail -1)
    eq "under set -e a failing run is handled (the sweep survives to record its verdict)" "$OUT" "survived"
  fi
fi

if want 4 && need_fn gate_base_test_run_table; then
  echo "  -- gate_base_test_run_table (vitest) --"
  if [ "$HAVE_VITEST" != yes ]; then
    skip "no vitest at $WA_NODE_MODULES (or no node) — vitest runs not exercised"
  else
    JRIG="$H_SCRATCH/rig-js"; mk_rig "$JRIG"
    cat > "$JRIG/tests-js/a.test.js" <<'JS'
describe('A', () => {
  it('passes', () => { expect(1 + 1).toBe(2); });
  it('fails', () => { expect(1 + 1).toBe(3); });
  it.skip('is skipped', () => {});
  it('has (regex)? [chars]', () => { expect(true).toBe(true); });
});
JS
    printf "const x = require('../no-such-module');\ndescribe('B', () => { it('x', () => { expect(x).toBeTruthy(); }); });\n" > "$JRIG/tests-js/b.test.js"
    printf "describe('S', () => { it('spins', () => { for (;;) {} }); });\n" > "$JRIG/tests-js/spin.test.js"
    printf "describe('N', () => { it('net', async () => {\n  const net = await import('node:net');\n  await new Promise((res, rej) => { const s = net.connect(%s, '127.0.0.1', () => { s.end(); res(); }); s.on('error', rej); });\n}); });\n" "$PORT" > "$JRIG/tests-js/net.test.js"
    printf "describe('W', () => { it('writes', async () => {\n  const fs = await import('node:fs');\n  fs.writeFileSync('%s/vitest-escape', 'x');\n}); });\n" "$H_SCRATCH" > "$JRIG/tests-js/write.test.js"
    mkdir -p "$JRIG/src"; printf "describe('O', () => { it('o', () => {}); });\n" > "$JRIG/src/outside.test.js"
    JS_S="$H_SCRATCH/jrs"; mkdir -p "$JS_S"
    T=$(gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/a.test.js); RC=$?
    eq "a vitest file runs to a readable table (status 0)" "$RC" "0"
    eq "...one row per test: statuses right, skipped is skip, regex characters in the name intact" "$T" \
      "$(printf '#ok\ntests-js/a.test.js::A passes\tpass\ntests-js/a.test.js::A fails\tfail\ntests-js/a.test.js::A is skipped\tskip\ntests-js/a.test.js::A has (regex)? [chars]\tpass')"
    T=$(gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/a.test.js "A has (regex)? [chars]")
    eq "run ALONE (by full name): exactly the requested test is a pass" \
      "$(printf '%s\n' "$T" | grep -c "$(printf 'tests-js/a.test.js::A has (regex)? \\[chars\\]\tpass')")" "1"
    eq "...and every OTHER test is reported skip (filtered out), never pass" \
      "$(printf '%s\n' "$T" | grep -v -F 'has (regex)' | grep -c "$(printf '\tpass$')")" "0"
    T=$(gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/a.test.js "A pass")
    eq "a name that is only a PREFIX of another test matches nothing (anchored), so the alone run cannot pick up a sibling" \
      "$(printf '%s\n' "$T" | grep -c "$(printf '\tpass$')")" "0"
    T=$(gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/b.test.js); RC=$?
    eq "a suite that cannot load is a readable collect-error table (status 0)" "$RC" "0"
    eq "...keyed by the file" "$T" "$(printf '#ok\ntests-js/b.test.js\tcollect-error')"
    T=$(GATE_ABT_RUN_TIMEOUT=4 gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/spin.test.js); RC=$?
    eq "a test that spins forever is killed by the budget -> UNREADABLE (status 1)" "$RC" "1"; eq "...and prints nothing" "$T" ""
    T=$(gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/net.test.js)
    eq "a vitest test that reaches the network FAILS under the sandbox" "$T" "$(printf '#ok\ntests-js/net.test.js::N net\tfail')"
    T=$(gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/write.test.js)
    eq "a vitest test that writes outside the scratch FAILS under the sandbox" "$T" "$(printf '#ok\ntests-js/write.test.js::W writes\tfail')"
    eq "...and the file was not created" "$([ -e "$H_SCRATCH/vitest-escape" ] && echo created || echo absent)" "absent"
    gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" src/outside.test.js >/dev/null
    eq "a file outside vitest's include (never run) -> status 1, NOT an empty table" "$?" "1"
    gate_base_test_run_table js "$JRIG" "$JRIG" "$JS_S" tests-js/does-not-exist.test.js >/dev/null
    eq "a file that does not exist -> status 1" "$?" "1"
    mkdir -p "$H_SCRATCH/rig-js-nonm"
    gate_base_test_run_table js "$H_SCRATCH/rig-js-nonm" "$JRIG" "$JS_S" tests-js/a.test.js >/dev/null
    eq "a rig with no node_modules/vitest -> status 1" "$?" "1"
    # Nothing the run did may touch the rig's REAL node_modules (vitest wants to write a results cache there).
    NM_NEWER=$(find "$WA_NODE_MODULES/.vite" -newer "$JRIG/vitest.config.js" -type f 2>/dev/null | head -1)
    eq "the borrowed node_modules was not written to (vitest cache stays off)" "$NM_NEWER" ""
  fi
fi

# ── 5. The orchestrator: base vs tip over real git history ──
echo "── 5. gate_base_test_pyjs_measure (base/tip over real git history) ──"

# mk_case <repo-dir> <subdir>: a repo whose RIG lives at <repo-dir>/<subdir> ("" = the toplevel).
# Base commit = code with a bug (double returns x), one test already RED on base, one green.
mk_case() {
  local R="$1" SUB="$2" D=""
  D="$R${SUB:+/$SUB}"
  mkdir -p "$D/lib" "$D/tests" "$D/tests-js"
  git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
  printf '[pytest]\npythonpath = . lib\ntestpaths = tests\n' > "$D/pytest.ini"
  : > "$D/lib/__init__.py"
  printf 'def double(x):\n    return x\n' > "$D/lib/mod.py"
  printf 'module.exports = { double: (x) => x };\n' > "$D/lib/mod.js"
  printf 'def inc(x):\n    return x + 1\n' > "$D/lib/other.py"
  printf 'from lib.other import inc\n\ndef test_old_red():\n    assert inc(1) == 3\n' > "$D/tests/test_old.py"
  printf 'from lib.mod import double\n\ndef test_keep():\n    assert callable(double)\n' > "$D/tests/test_keep.py"
  printf "export default { test: { environment: 'node', include: ['tests-js/**/*.test.js'], globals: true } };\n" > "$D/vitest.config.js"
  printf '/venv\n/node_modules\n' > "$R/.gitignore"
  [ "$HAVE_PYTEST" = yes ] && ln -s "$WA_VENV" "$D/venv"
  [ "$HAVE_VITEST" = yes ] && ln -s "$WA_NODE_MODULES" "$D/node_modules"
  git -C "$R" add -A && git -C "$R" commit -q -m base
}
# fix_commit <repo-dir> <subdir>: the "fix" — double works, and triple exists.
fix_code() {
  local D="$1${2:+/$2}"
  printf 'def double(x):\n    return x + x\n\ndef triple(x):\n    return x * 3\n' > "$D/lib/mod.py"
  printf 'module.exports = { double: (x) => x + x };\n' > "$D/lib/mod.js"
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2" && git -C "$1" rev-parse HEAD; }
# measure <repo> <subdir> <base> <tip> <files...>  (files are repo-root-relative, like `git diff --name-only`)
measure() {
  local R="$1" SUB="$2" B="$3" T="$4"; shift 4
  TMPDIR="${PRIV5:-${TMPDIR:-/tmp}}" gate_base_test_pyjs_measure "$R${SUB:+/$SUB}" "$B" "$T" "$(printf '%s\n' "$@")"
}
fstate() { printf '%s\n' "$OUT" | grep -F "FILE $1 " | sed -n 's/.* state=\([^ ]*\).*/\1/p'; }
fold()   { printf '%s\n' "$OUT" | grep -F "FILE $1 " | sed -n 's/.* old=\([^ ]*\).*/\1/p'; }
fwhy()   { printf '%s\n' "$OUT" | grep -F "FILE $1 " | sed -n 's/.* why=\([^ ]*\).*/\1/p'; }
tot()    { printf '%s\n' "$OUT" | grep '^TOTALS ' | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }

if want 5 && need_fn gate_base_test_pyjs_measure; then
  if [ "$HAVE_PYTEST" != yes ]; then
    skip "no pytest-capable venv — measure scenarios not exercised"
  else
    # A PRIVATE TMPDIR for every measurement: the shared one also holds other runs' scratch dirs (this very
    # selftest can be running twice, and so can the guard), so "nothing left behind" is only checkable here.
    PRIV5="$H_SCRATCH/private-tmp5"; mkdir -p "$PRIV5"
    C="$H_SCRATCH/case1"; mk_case "$C" ""
    BASE=$(git -C "$C" rev-parse HEAD)
    fix_code "$C" ""
    printf 'from lib.mod import double\n\ndef test_double():\n    assert double(2) == 4\n' > "$C/tests/test_fails.py"
    printf 'from lib.mod import double\n\ndef test_exists():\n    assert callable(double)\n' > "$C/tests/test_passes.py"
    printf 'import os\n\ndef test_env():\n    assert os.path.exists("/definitely/not/here/gate")\n' > "$C/tests/test_env.py"
    printf 'from lib.mod import triple\n\ndef test_triple():\n    assert triple(2) == 6\n' > "$C/tests/test_newsym.py"
    printf 'def helper():\n    return 1\n' > "$C/tests/test_zero.py"
    printf 'import pytest\npytest.importorskip("no_such_module_xyz_gate")\n\ndef test_x():\n    assert True\n' > "$C/tests/test_skipall.py"
    printf 'STATE = []\n\nfrom lib.mod import double\n\ndef test_a():\n    STATE.append(1)\n\ndef test_b():\n    assert STATE or double(2) == 4\n' > "$C/tests/test_leak.py"
    printf 'from lib.other import inc\n\ndef test_old_red():\n    assert inc(1) == 2\n' > "$C/tests/test_old.py"
    printf 'from lib.mod import double\n\ndef test_keep():\n    assert callable(double) and double is not None\n' > "$C/tests/test_keep.py"
    TIP=$(commit_all "$C" "fix + tests")
    PYFILES="tests/test_fails.py tests/test_passes.py tests/test_env.py tests/test_newsym.py tests/test_zero.py tests/test_skipall.py tests/test_leak.py tests/test_old.py tests/test_keep.py"

    echo "  -- verdict per file --"
    OUT=$(GATE_ABT_RUN_TIMEOUT=60 GATE_ABT_PYJS_MAX=20 measure "$C" "" "$BASE" "$TIP" $PYFILES)   # 10 files: above the default cap of 8
    eq "output ends in exactly one TOTALS line" "$(printf '%s\n' "$OUT" | grep -c '^TOTALS ')" "1"
    eq "a test that needs the fix: passes at tip, FAILS at base, confirmed alone -> fails-on-base" "$(fstate tests/test_fails.py)" "fails-on-base"
    eq "a test that passes with or without the fix -> passes-on-base (the file that may be refused)" "$(fstate tests/test_passes.py)" "passes-on-base"
    eq "a test that fails at TIP too (environment, not the fix) -> unmeasured, never fails-on-base" "$(fstate tests/test_env.py)" "unmeasured"
    eq "a test importing a symbol the fix ADDS: base collection error, tip green -> fails-on-base (classic TDD red)" "$(fstate tests/test_newsym.py)" "fails-on-base"
    eq "a test_*.py that holds no tests -> no-tests (not counted as a test file)" "$(fstate tests/test_zero.py)" "no-tests"
    eq "a module skipped wholesale -> unmeasured (it did not run), not no-tests" "$(fstate tests/test_skipall.py)" "unmeasured"
    eq "passes in the file run ONLY thanks to a sibling's leaked state, but fails ALONE on base -> fails-on-base (alone sweep), never refused" "$(fstate tests/test_leak.py)" "fails-on-base"
    eq "a MODIFIED test that was RED on base and is green now, green on base too -> passes-on-base with old=old-fails (a repair)" "$(fstate tests/test_old.py)/$(fold tests/test_old.py)" "passes-on-base/old-fails"
    eq "a MODIFIED test that was green before as well -> passes-on-base with old=old-passes (still refusable)" "$(fstate tests/test_keep.py)/$(fold tests/test_keep.py)" "passes-on-base/old-passes"
    eq "an ADDED test that passes on base has no old form -> old=added" "$(fold tests/test_passes.py)" "added"
    eq "TOTALS counted = files that are really tests (zero-test script excluded)" "$(tot counted)" "8"
    eq "TOTALS copy_ok = counted (every counted file was materialised on both trees)" "$(tot copy_ok)" "8"
    eq "TOTALS ran = files with a real answer (fails-on-base + passes-on-base)" "$(tot ran)" "6"
    eq "TOTALS failed = files that fail on base" "$(tot failed)" "3"
    eq "TOTALS repaired = passes-on-base whose old form was red" "$(tot repaired)" "1"
    eq "TOTALS unclassified = passes-on-base whose old form could not be measured" "$(tot unclassified)" "0"
    # Feed the totals to the REAL ga-rstae verdict function: the pieces must compose.
    eq "the totals drive gate_base_test_verdict: two unmeasured files -> nao-consegui-medir (partial measurement is not proof)" \
      "$(gate_base_test_verdict "$(tot counted)" "$(tot copy_ok)" "$(tot ran)" "$(tot failed)" "$(tot repaired)" "$(tot unclassified)")" "nao-consegui-medir"

    echo "  -- verdict composition: only clean answers may refuse --"
    OUT=$(measure "$C" "" "$BASE" "$TIP" tests/test_passes.py)
    eq "one file, passes on base -> totals give passou-na-base (the refusal)" \
      "$(gate_base_test_verdict "$(tot counted)" "$(tot copy_ok)" "$(tot ran)" "$(tot failed)" "$(tot repaired)" "$(tot unclassified)")" "passou-na-base"
    OUT=$(measure "$C" "" "$BASE" "$TIP" tests/test_passes.py tests/test_env.py)
    eq "a passing file plus an UNMEASURED one -> nao-consegui-medir (never refused on partial evidence)" \
      "$(gate_base_test_verdict "$(tot counted)" "$(tot copy_ok)" "$(tot ran)" "$(tot failed)" "$(tot repaired)" "$(tot unclassified)")" "nao-consegui-medir"
    eq "...for a reason that is reported, not blank" "$([ -n "$(fwhy tests/test_env.py)" ] && [ "$(fwhy tests/test_env.py)" != "-" ] && echo reported)" "reported"
    # The remaining compositions are pure arithmetic over totals the big scenario above already asserted:
    eq "totals of {fails, passes} -> reprovou-na-base" "$(gate_base_test_verdict 2 2 2 1 0 0)" "reprovou-na-base"
    eq "totals of {repaired test} -> consertou-teste-vermelho" "$(gate_base_test_verdict 1 1 1 0 1 0)" "consertou-teste-vermelho"
    eq "totals of {zero-test script only} -> sem-teste-novo" "$(gate_base_test_verdict 0 0 0 0 0 0)" "sem-teste-novo"

    echo "  -- test-side support files that travel to base: code helpers vs data --"
    # A CODE helper (conftest / .py under tests/) is overlaid so a test importing it does not get a false ImportError
    # 'fails-on-base'. But a helper could ALSO be the fix (a bead repairing test infrastructure); overlaying it then
    # puts the fix on base and the new tests pass there. A 'passes-on-base' answer is therefore not trusted when code
    # helpers were overlaid: unmeasured, never a refusal. Evidence that a test FAILS on base is unaffected.
    C4="$H_SCRATCH/case4"; mk_case "$C4" ""; BASE4=$(git -C "$C4" rev-parse HEAD); fix_code "$C4" ""
    # (unique module name: the WA venv ships a stray top-level `tests` package that would shadow `tests.helpers`)
    printf 'def one():\n    return 1\n' > "$C4/tests/gate_pyjs_helper.py"
    printf 'from gate_pyjs_helper import one\n\ndef test_h():\n    assert one() == 1\n' > "$C4/tests/test_helper_passes.py"
    printf 'from gate_pyjs_helper import one\nfrom lib.mod import double\n\ndef test_h2():\n    assert double(one() + 1) == 4\n' > "$C4/tests/test_helper_needs_fix.py"
    TIP4=$(commit_all "$C4" "fix + helper + tests")
    OUT=$(measure "$C4" "" "$BASE4" "$TIP4" tests/test_helper_passes.py tests/test_helper_needs_fix.py)
    eq "a code helper was overlaid and the test passes on base -> unmeasured, why=support-overlay (the helper might BE the fix)" \
      "$(fstate tests/test_helper_passes.py)/$(fwhy tests/test_helper_passes.py)" "unmeasured/support-overlay"
    eq "...but a test that uses the same helper and FAILS on base is still fails-on-base (overlay makes the evidence accurate, not weaker)" \
      "$(fstate tests/test_helper_needs_fix.py)" "fails-on-base"
    eq "...so the totals cannot refuse this submission: ran=1 of 2, failed=1" "$(tot ran)/$(tot failed)" "1/1"
    C5="$H_SCRATCH/case5"; mk_case "$C5" ""; BASE5=$(git -C "$C5" rev-parse HEAD); fix_code "$C5" ""
    mkdir -p "$C5/tests/fixtures"; printf '{"n": 1}\n' > "$C5/tests/fixtures/data.json"
    printf 'import json, pathlib\n\ndef test_data():\n    assert json.loads(pathlib.Path(__file__).parent.joinpath("fixtures/data.json").read_text())["n"] == 1\n' > "$C5/tests/test_data.py"
    TIP5=$(commit_all "$C5" "data fixture + test")
    OUT=$(measure "$C5" "" "$BASE5" "$TIP5" tests/test_data.py)
    eq "a DATA fixture cannot be a code fix: the test passes on base -> still passes-on-base (refusable)" "$(fstate tests/test_data.py)" "passes-on-base"

    echo "  -- the alone sweep is bounded: too many tests to check -> unmeasured, never a refusal --"
    printf 'from lib.mod import double\n\ndef test_1():\n    assert callable(double)\n\ndef test_2():\n    assert callable(double)\n\ndef test_3():\n    assert callable(double)\n' > "$C/tests/test_three.py"
    git -C "$C" add -A; git -C "$C" commit -q -m "three tests"; TIP_B=$(git -C "$C" rev-parse HEAD)
    OUT=$(GATE_ABT_ALONE_PASS_MAX=2 measure "$C" "" "$BASE" "$TIP_B" tests/test_three.py)
    eq "3 tests, bound lowered to 2 -> unmeasured, why=too-many-tests (an unchecked test could be the one that depends on the fix)" \
      "$(fstate tests/test_three.py)/$(fwhy tests/test_three.py)" "unmeasured/too-many-tests"
    eq "...and so the totals cannot refuse: ran=0" "$(tot ran)" "0"

    echo "  -- degraded environments: every one is unmeasured, none is a refusal --"
    OUT=$(GATE_ABT_SANDBOX_EXEC=/nonexistent/sandbox-exec measure "$C" "" "$BASE" "$TIP" tests/test_passes.py)
    eq "no working sandbox -> unmeasured, why=no-sandbox" "$(fstate tests/test_passes.py)/$(fwhy tests/test_passes.py)" "unmeasured/no-sandbox"
    eq "...and ran=0 (nothing was executed)" "$(tot ran)" "0"
    OUT=$(GATE_ABT_PYJS_MAX=1 measure "$C" "" "$BASE" "$TIP" tests/test_passes.py tests/test_fails.py)
    eq "more files than the cap -> every file unmeasured, why=cap (a cap hit is visible, never a silent truncation)" \
      "$(fstate tests/test_passes.py)/$(fstate tests/test_fails.py)/$(fwhy tests/test_fails.py)" "unmeasured/unmeasured/cap"
    OUT=$(GATE_ABT_PYJS_BUDGET=0 measure "$C" "" "$BASE" "$TIP" tests/test_passes.py)
    eq "an exhausted time budget -> unmeasured, why=budget" "$(fstate tests/test_passes.py)/$(fwhy tests/test_passes.py)" "unmeasured/budget"
    OUT=$(measure "$C" "" "deadbeef00000000000000000000000000000000" "$TIP" tests/test_passes.py)
    eq "an unresolvable base sha -> unmeasured, why=worktree" "$(fstate tests/test_passes.py)/$(fwhy tests/test_passes.py)" "unmeasured/worktree"
    OUT=$(gate_base_test_pyjs_measure "$H_SCRATCH/rig-novenv" "$BASE" "$TIP" "tests/test_passes.py")
    eq "a rig that is not a git repo -> unmeasured (and no crash)" "$(fstate tests/test_passes.py)" "unmeasured"
    OUT=$(gate_base_test_pyjs_measure "$C" "$BASE" "$TIP" "")
    eq "an empty file list -> TOTALS with counted=0 (nothing to measure is a MEASURED zero only for the caller that listed nothing)" "$(tot counted)" "0"
    eq "tests/ helper-only file (no kind) handed in by mistake -> unmeasured, never silently dropped" \
      "$(OUT=$(measure "$C" "" "$BASE" "$TIP" tests/gate_pyjs_helper.py); fstate tests/gate_pyjs_helper.py)" "unmeasured"
    eq "no scratch directory left behind after ~20 measurements (incl. timeouts and refused setups)" "$(ls -A "$PRIV5" | wc -l | tr -d ' ')" "0"
    eq "no throwaway worktree left registered in the repo" "$(git -C "$C" worktree list | wc -l | tr -d ' ')" "1"
    eq "the rig's own files were not touched by the runs" "$(git -C "$C" status --porcelain | wc -l | tr -d ' ')" "0"

    echo "  -- timeouts: a run that exceeds its budget is unmeasured --"
    C2="$H_SCRATCH/case2"; mk_case "$C2" ""
    printf 'def double(x):\n    while True:\n        pass\n' > "$C2/lib/mod.py"; git -C "$C2" add -A; git -C "$C2" commit -q -m "base hangs"
    BASE2=$(git -C "$C2" rev-parse HEAD); fix_code "$C2" ""
    printf 'from lib.mod import double\n\ndef test_double():\n    assert double(2) == 4\n' > "$C2/tests/test_hang.py"
    TIP2=$(commit_all "$C2" "fix")
    OUT=$(GATE_ABT_RUN_TIMEOUT=4 measure "$C2" "" "$BASE2" "$TIP2" tests/test_hang.py)
    eq "base hangs (infinite loop) while tip is fine -> unmeasured, NOT fails-on-base (slowness is not evidence)" "$(fstate tests/test_hang.py)" "unmeasured"

    echo "  -- a file too slow to run in full: base first, fail-fast, then only the failing tests at tip --"
    C6="$H_SCRATCH/case6"; mk_case "$C6" ""; BASE6=$(git -C "$C6" rev-parse HEAD); fix_code "$C6" ""
    printf 'import time\nimport pytest\nfrom lib.mod import double\n\n@pytest.mark.parametrize("i", range(40))\ndef test_x(i):\n    assert double(2) == 4   # fails instantly on base\n    time.sleep(0.5)         # only reached WITH the fix: a full run at tip takes ~20s\n' > "$C6/tests/test_huge.py"
    TIP6=$(commit_all "$C6" "fix + huge test")
    OUT=$(GATE_ABT_RUN_TIMEOUT=12 measure "$C6" "" "$BASE6" "$TIP6" tests/test_huge.py)
    eq "a 40-test file whose FULL run at tip exceeds the budget is still measured: fails-on-base from 3 failing tests, never the whole file" "$(fstate tests/test_huge.py)" "fails-on-base"

    echo "  -- a file that cannot even be imported on base, too slow to run in full at tip: sampled control --"
    C7="$H_SCRATCH/case7"; mk_case "$C7" ""; BASE7=$(git -C "$C7" rev-parse HEAD); fix_code "$C7" ""
    printf 'import time\nimport pytest\nfrom lib.mod import double, triple   # triple exists only WITH the fix\n\n@pytest.mark.parametrize("i", range(40))\ndef test_x(i):\n    time.sleep(0.5)   # a full run at tip takes ~20s\n    assert double(2) == 4 and triple(1) == 3\n' > "$C7/tests/test_huge_newsym.py"
    TIP7=$(commit_all "$C7" "fix + huge test that imports a new symbol")
    OUT=$(GATE_ABT_RUN_TIMEOUT=12 measure "$C7" "" "$BASE7" "$TIP7" tests/test_huge_newsym.py)
    eq "import error on base + a 40-test file whose full tip run exceeds the budget: measured from a collect-only sample, not the whole file" "$(fstate tests/test_huge_newsym.py)" "fails-on-base"

    echo "  -- cost: the first CONFIRMED failing test is enough, the other candidates are not run --"
    C8="$H_SCRATCH/case8"; mk_case "$C8" ""; BASE8=$(git -C "$C8" rev-parse HEAD); fix_code "$C8" ""
    printf 'from lib.mod import double\n\ndef test_a():\n    assert double(2) == 4\n\ndef test_b():\n    assert double(3) == 6\n\ndef test_c():\n    assert double(4) == 8\n' > "$C8/tests/test_three_fail.py"
    TIP8=$(commit_all "$C8" "fix + three tests that need it")
    rm -f "$H_SCRATCH/trace8"
    OUT=$(GATE_ABT_TRACE="$H_SCRATCH/trace8" measure "$C8" "" "$BASE8" "$TIP8" tests/test_three_fail.py)
    eq "three tests fail on base -> fails-on-base" "$(fstate tests/test_three_fail.py)" "fails-on-base"
    eq "...with exactly 3 runs: base (fail-fast), the first candidate alone at tip, the same alone at base (not 7)" "$(wc -l < "$H_SCRATCH/trace8" | tr -d ' ')" "3"
    C8B="$H_SCRATCH/case8b"; mk_case "$C8B" ""; BASE8B=$(git -C "$C8B" rev-parse HEAD); fix_code "$C8B" ""
    printf 'import os\nfrom lib.mod import double\n\ndef test_env_a():\n    assert os.path.exists("/definitely/not/here/a")\n\ndef test_env_b():\n    assert os.path.exists("/definitely/not/here/b")\n\ndef test_real():\n    assert double(2) == 4\n' > "$C8B/tests/test_mixed.py"
    TIP8B=$(commit_all "$C8B" "fix + two env-broken tests and one real one")
    OUT=$(measure "$C8B" "" "$BASE8B" "$TIP8B" tests/test_mixed.py)
    eq "candidates that do not pass alone at tip are skipped, and the next one is tried: the real test still decides -> fails-on-base" "$(fstate tests/test_mixed.py)" "fails-on-base"

    echo "  -- a rig that is a SUBDIRECTORY of the repo (the gascity layout) --"
    C3="$H_SCRATCH/case3"; mk_case "$C3" "rig"
    BASE3=$(git -C "$C3" rev-parse HEAD); fix_code "$C3" "rig"
    printf 'from lib.mod import double\n\ndef test_double():\n    assert double(2) == 4\n' > "$C3/rig/tests/test_fails.py"
    TIP3=$(commit_all "$C3" "fix + tests")
    OUT=$(measure "$C3" "rig" "$BASE3" "$TIP3" rig/tests/test_fails.py)
    eq "subdirectory rig: root-relative paths resolve to the right file (fails-on-base)" "$(fstate rig/tests/test_fails.py)" "fails-on-base"

    echo "  -- the guard runs under set -euo pipefail --"
    OUT=$(bash -c 'set -euo pipefail; GATE_GUARD_LIB_ONLY=1 . "$1"; O=$(gate_base_test_pyjs_measure "$2" "$3" "$4" "tests/test_env.py"); echo "survived:$(printf "%s\n" "$O" | grep -c "^TOTALS ")"' _ "$GUARD" "$C" "$BASE" "$TIP" 2>&1 | tail -1)
    eq "an unmeasured file (non-zero runs inside) does not abort the sweep under set -e" "$OUT" "survived:1"
  fi
fi

# ── 6. Detection: which changed files are py/js tests, and "could not read" vs "none" ──
echo "── 6. gate_base_test_pyjs_scan (detection) ──"
if need_fn gate_base_test_pyjs_scan; then
  # No sandbox on purpose: detection must be provable WITHOUT executing anything. With the sandbox
  # unavailable, every detected file comes back unmeasured/no-sandbox and nothing runs.
  D6="$H_SCRATCH/case6"; mkdir -p "$D6/lib" "$D6/tests" "$D6/tests-js" "$D6/docs"
  git -C "$D6" init -q . && git -C "$D6" config user.email t@t && git -C "$D6" config user.name t
  printf 'x = 1\n' > "$D6/lib/mod.py"; printf 'base\n' > "$D6/docs/readme.md"; printf 'def test_old():\n    assert True\n' > "$D6/tests/test_moved_from.py"
  git -C "$D6" add -A; git -C "$D6" commit -q -m base; B6=$(git -C "$D6" rev-parse HEAD)
  printf 'x = 2\n' > "$D6/lib/mod.py"                                        # production py: not a test
  printf 'def test_a():\n    assert True\n' > "$D6/tests/test_new.py"        # py test, added
  printf 'def test_b():\n    assert True\n' > "$D6/tests/b_test.py"          # py test, *_test.py
  printf 'it("c", () => {});\n' > "$D6/tests-js/c.test.js"                   # js test
  printf 'it("d", () => {});\n' > "$D6/tests-js/d.spec.ts"                   # ts spec
  printf 'export const e = 1;\n' > "$D6/tests-js/helper.js"                  # js helper: not a test
  printf 'new\n' > "$D6/docs/readme.md"                                       # doc: irrelevant
  git -C "$D6" mv tests/test_moved_from.py tests/test_moved_to.py             # a RENAME must count as an added test
  printf 'def test_old():\n    assert 1 == 1\n' > "$D6/tests/test_moved_to.py"
  git -C "$D6" add -A; git -C "$D6" commit -q -m tip; T6=$(git -C "$D6" rev-parse HEAD)
  OUT=$(GATE_ABT_SANDBOX_EXEC=/nonexistent/sandbox-exec GATE_ABT_PYJS_MAX=20 gate_base_test_pyjs_scan "$D6" "$B6" "$T6")
  FILES6=$(printf '%s\n' "$OUT" | grep '^FILE ' | sed 's/^FILE \([^ ]*\) .*/\1/' | sort | tr '\n' ' ')
  eq "exactly the py/js TEST files are detected (production py, js helper and docs are not)" \
    "$FILES6" "tests-js/c.test.js tests-js/d.spec.ts tests/b_test.py tests/test_moved_to.py tests/test_new.py "
  eq "a renamed-and-edited test counts as an added one (rename detection is off)" \
    "$(printf '%s\n' "$OUT" | grep -c 'FILE tests/test_moved_to.py')" "1"
  eq "with no sandbox nothing ran: every detected file is unmeasured/no-sandbox" \
    "$(printf '%s\n' "$OUT" | grep '^FILE ' | grep -c 'state=unmeasured why=no-sandbox')" "5"
  eq "TOTALS are for the 5 files" "$(printf '%s\n' "$OUT" | grep '^TOTALS ' | grep -c 'files=5 counted=5 copy_ok=0 ran=0')" "1"
  eq "a branch that changes no py/js test -> TOTALS files=0 (a MEASURED zero)" \
    "$(git -C "$D6" commit -q --allow-empty -m empty; gate_base_test_pyjs_scan "$D6" "$T6" "$(git -C "$D6" rev-parse HEAD)" | grep -c '^TOTALS files=0 counted=0')" "1"
  OUT=$(gate_base_test_pyjs_scan "$D6" "deadbeef00000000000000000000000000000000" "$T6")
  eq "an unresolvable base (git diff FAILS) -> UNREAD, NOT 'files=0'" "$OUT" "UNREAD"
  eq "empty inputs -> UNREAD" "$(gate_base_test_pyjs_scan "" "$B6" "$T6")" "UNREAD"
  eq "a rig that is not a repo -> UNREAD" "$(gate_base_test_pyjs_scan "$H_SCRATCH/rig-novenv" "$B6" "$T6")" "UNREAD"
fi

# ── 6b. Dangling runtime links: a fresh checkout has symlinks into directories that only exist in a live rig ──
echo "── 6b. gate_base_test_materialize_links ──"
if need_fn _gate_base_test_norm_path; then
  echo "  -- _gate_base_test_norm_path --"
  eq "a plain relative path is unchanged" "$(_gate_base_test_norm_path shared/logs)" "shared/logs"
  eq "'.' and empty components are dropped" "$(_gate_base_test_norm_path ./a//b/.)" "a/b"
  eq "'..' pops one component" "$(_gate_base_test_norm_path a/b/../c)" "a/c"
  eq "several '..' pop several" "$(_gate_base_test_norm_path a/b/../../c)" "c"
  _gate_base_test_norm_path ../x >/dev/null; eq "a path that climbs above the root -> status 1" "$?" "1"
  _gate_base_test_norm_path a/../../x >/dev/null; eq "...also when it climbs AFTER descending" "$?" "1"
  eq "a path that resolves to the root itself is the empty string (nothing to create)" "$(_gate_base_test_norm_path a/..)" ""
  _gate_base_test_norm_path /etc/passwd >/dev/null; eq "an absolute path -> status 1 (never followed)" "$?" "1"
  _gate_base_test_norm_path "" >/dev/null; eq "empty -> status 1" "$?" "1"
fi
if need_fn gate_base_test_materialize_links; then
  echo "  -- gate_base_test_materialize_links --"
  L="$H_SCRATCH/links"; mkdir -p "$L/src" && git -C "$L" init -q . && git -C "$L" config user.email t@t && git -C "$L" config user.name t
  ln -s shared/logs "$L/logs"                          # the WA shape: a tracked link into an untracked runtime dir
  ln -s shared/data "$L/data"
  ln -s ../../elsewhere/x "$L/src/up"                   # relative to the LINK'S directory: src/../../elsewhere = climbs out
  ln -s /etc "$L/abs"                                   # absolute: never followed
  mkdir -p "$L/real"; printf 'k\n' > "$L/real/keep"; ln -s real "$L/already"   # target exists (git tracks files, not empty dirs)
  ln -s ../real/sub "$L/src/inner"                      # relative to src/: resolves to real/sub, inside the tree
  printf 'x\n' > "$L/file.txt"; ln -s file.txt "$L/tofile"   # target is an existing FILE
  git -C "$L" add -A; git -C "$L" commit -q -m links
  # A fresh checkout of that commit: every link is exactly as dangling as in the WA case.
  git -C "$L" worktree add --detach -q "$H_SCRATCH/links-wt" HEAD
  N=$(gate_base_test_materialize_links "$H_SCRATCH/links-wt")
  eq "reports how many directories it created (logs, data, real/sub = 3)" "$N" "3"
  eq "logs -> shared/logs now resolves to an empty directory" "$([ -d "$H_SCRATCH/links-wt/shared/logs" ] && echo dir)" "dir"
  eq "data -> shared/data likewise" "$([ -d "$H_SCRATCH/links-wt/shared/data" ] && echo dir)" "dir"
  eq "a link relative to its own directory is resolved from THERE (src/inner -> real/sub)" "$([ -d "$H_SCRATCH/links-wt/real/sub" ] && echo dir)" "dir"
  eq "a target that would climb out of the tree is NOT created" "$([ -e "$H_SCRATCH/elsewhere" ] && echo created || echo absent)" "absent"
  eq "an absolute target is left alone" "$([ -e "$H_SCRATCH/links-wt/etc" ] && echo created || echo absent)" "absent"
  eq "an existing target is untouched (the file is still a file)" "$([ -f "$H_SCRATCH/links-wt/file.txt" ] && echo file)" "file"
  eq "running it again creates nothing (idempotent)" "$(gate_base_test_materialize_links "$H_SCRATCH/links-wt")" "0"
  eq "not a git checkout -> 0, no error" "$(gate_base_test_materialize_links "$H_SCRATCH/no-such-dir")" "0"
  eq "empty argument -> 0" "$(gate_base_test_materialize_links "")" "0"
  git -C "$L" worktree remove --force "$H_SCRATCH/links-wt" >/dev/null 2>&1
fi

if need_fn gate_base_test_mirror_runtime_dirs; then
  echo "  -- gate_base_test_mirror_runtime_dirs --"
  # The live rig has untracked runtime directories (WA: logs -> shared/logs, data -> shared/data, created on the
  # host, never committed). A fresh checkout has none, and modules that open logs/<x>.log at import fail.
  LR="$H_SCRATCH/live-rig"; mkdir -p "$LR/shared/logs" "$LR/shared/data" "$LR/cache" "$LR/secrets" "$LR/shared/other"
  ln -s shared/logs "$LR/logs"; ln -s shared/data "$LR/data"          # symlinks into the shared runtime tree
  printf 'k\n' > "$LR/shared/data/production.db"                       # real data that must NEVER reach the sandbox
  : > "$LR/var"                                                        # a FILE named like a runtime dir
  ln -s shared/other "$LR/output"
  WT="$H_SCRATCH/fresh-checkout"; mkdir -p "$WT/lib" "$WT/run"; : > "$WT/lib/x.py"   # 'run' already exists in the checkout
  mkdir -p "$LR/run"; printf 'live\n' > "$LR/run/pid"
  N=$(gate_base_test_mirror_runtime_dirs "$LR" "$WT")
  eq "the live rig's logs, data, cache, output -> 4 empty dirs created (run already existed, var is a file)" "$N" "4"
  eq "logs/ exists and is an EMPTY real directory (not a link into the live rig)" "$([ -d "$WT/logs" ] && [ ! -L "$WT/logs" ] && [ -z "$(ls -A "$WT/logs")" ] && echo empty-dir)" "empty-dir"
  eq "data/ is empty: production data never travels into the sandbox" "$([ -d "$WT/data" ] && [ -z "$(ls -A "$WT/data")" ] && echo empty-dir)" "empty-dir"
  eq "a symlink-to-dir in the live rig (output) is mirrored as a plain empty dir too" "$([ -d "$WT/output" ] && [ ! -L "$WT/output" ] && echo dir)" "dir"
  eq "a name NOT on the conventional list (secrets, shared) is never mirrored" "$([ -e "$WT/secrets" ] || [ -e "$WT/shared" ] && echo mirrored || echo absent)" "absent"
  eq "a live-rig FILE that has a runtime-dir name (var) is not turned into a directory" "$([ -e "$WT/var" ] && echo created || echo absent)" "absent"
  eq "an entry the checkout already has (run) is left exactly as it is" "$([ -z "$(ls -A "$WT/run")" ] && echo untouched)" "untouched"
  eq "running it again creates nothing (idempotent)" "$(gate_base_test_mirror_runtime_dirs "$LR" "$WT")" "0"
  mkdir -p "$H_SCRATCH/wt2" "$H_SCRATCH/lr2"
  eq "a live rig without runtime dirs -> nothing is invented: count 0" "$(gate_base_test_mirror_runtime_dirs "$H_SCRATCH/lr2" "$H_SCRATCH/wt2")" "0"
  eq "...and the checkout stays empty" "$(ls -A "$H_SCRATCH/wt2" | wc -l | tr -d ' ')" "0"
  eq "missing live rig -> 0" "$(gate_base_test_mirror_runtime_dirs "$H_SCRATCH/nope" "$WT")" "0"
  eq "missing checkout -> 0" "$(gate_base_test_mirror_runtime_dirs "$LR" "$H_SCRATCH/nope")" "0"
  eq "empty arguments -> 0" "$(gate_base_test_mirror_runtime_dirs "" "")" "0"
fi

# ── 7. The arm-B call site, END TO END: the real block, extracted verbatim, run under production options ──
echo "── 7. call site (Step 5b-pre2 block, verbatim) ──"
if want 7 && [ "$HAVE_PYTEST" = yes ]; then
  # The block is cut out of the live script with the same awk the sibling selftests use, so this tests what
  # actually ships, not a copy. Stubs only for the side-effect commands; options are the guard's own.
  BLOCK=$(awk '/Step 5b-pre2 \(ga-rstae\)/,/^fi$/' "$GUARD")
  if [ -z "$BLOCK" ]; then bad "could not extract the arm-B block from the guard"; else
    ok "the arm-B block is extractable (the drift anchor the sibling selftests rely on still holds)"
    # run_block <rig> <bead> <branch> [scan-stub-output]: prints the block's exit status; side effects land in $LOGF.
    run_block() {
      ( GATE_GUARD_LIB_ONLY=1 . "$GUARD"; set -euo pipefail
        export TMPDIR="${PRIV7:-${TMPDIR:-/tmp}}"      # private: see the leftover assertion at the end
        RIG_PATH="$1"; BEAD_ID="$2"; BRANCH="$3"; MARKER_ID="mk-e2e"; GC_CITY="/nonexistent-city"
        log()  { echo "LOG $*" >> "$LOGF"; }
        err()  { echo "ERR $*" >> "$LOGF"; }
        set_gate_status() { echo "STATUS $*" >> "$LOGF"; }
        # one log line per call, even for the multi-line refusal comment (the greps below are line-based)
        bd()   { printf 'BD %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$LOGF"; return 0; }
        if [ -n "${4-}" ]; then S4="$4"; gate_base_test_pyjs_scan() { echo CALLED >> "$LOGF"; printf '%s\n' "$S4"; }; fi
        eval "$BLOCK"
        echo "REACHED-END" >> "$LOGF"
      ) >/dev/null 2>&1
      echo $?
    }
    # mk_remote <dir>: a rig that has an origin (the block fetches origin main + the branch).
    mk_remote() {
      mkdir -p "$1"; git init -q --bare "$1/origin.git"
      mk_case "$1/rig" ""
      git -C "$1/rig" branch -M main
      git -C "$1/rig" remote add origin "$1/origin.git"
      git -C "$1/rig" push -q origin main
    }
    # branch <rig> <name>: start a feature branch from main
    branch() { git -C "$1" checkout -q -b "$2"; }
    push_branch() { git -C "$1" add -A; git -C "$1" commit -q -m "feat"; git -C "$1" push -q origin "$2"; }
    logged() { grep -c -E -- "$1" "$LOGF" 2>/dev/null || true; }
    BEAD_B=ga-pj5va; BEAD_A=ga-rstae
    eq "fixture bead $BEAD_B is in arm B" "$(gate_ab_arm_for_bead $BEAD_B)" "B"
    eq "fixture bead $BEAD_A is in arm A" "$(gate_ab_arm_for_bead $BEAD_A)" "A"

    echo "  -- arm B, a pytest test that needs the fix: reprovou-na-base, no refusal --"
    PRIV7="$H_SCRATCH/private-tmp7"; mkdir -p "$PRIV7"; export TMPDIR_SAVED7="${TMPDIR:-}"
    E1="$H_SCRATCH/e2e1"; mk_remote "$E1"; branch "$E1/rig" feat/e1; fix_code "$E1/rig" ""
    printf 'from lib.mod import double\n\ndef test_double():\n    assert double(2) == 4\n' > "$E1/rig/tests/test_fails.py"
    push_branch "$E1/rig" feat/e1
    LOGF="$H_SCRATCH/e1.log"; : > "$LOGF"
    RC=$(GATE_ABT_RUN_TIMEOUT=60 run_block "$E1/rig" $BEAD_B feat/e1)
    eq "the block completes (exit 0) — a test that depends on the fix is the GOOD case" "$RC" "0"
    eq "verdict reprovou-na-base, recorded in the AB-BASE-TEST line" "$(logged 'AB-BASE-TEST bead=ga-pj5va arm=B verdict=reprovou-na-base ')" "1"
    eq "the marker is labelled gate-ab-basetest:reprovou-na-base" "$(logged 'BD .*label add mk-e2e gate-ab-basetest:reprovou-na-base')" "1"
    eq "the per-file result is logged under its own token" "$(logged 'AB-BASE-TEST-FILE .*tests/test_fails.py kind=py state=fails-on-base')" "1"
    eq "the py/js breakdown goes on its OWN line (the AB-BASE-TEST line keeps its exact shape: gate-ab-apuracao.sh greps it)" \
      "$(logged 'AB-BASE-TEST-PYJS bead=ga-pj5va arm=B sh=0 py=1 js=0 pyjs=measured')" "1"
    eq "nothing was refused: no STATUS error" "$(logged '^STATUS')" "0"

    echo "  -- arm B, a pytest test that passes on base: REFUSED --"
    E2="$H_SCRATCH/e2e2"; mk_remote "$E2"; branch "$E2/rig" feat/e2; fix_code "$E2/rig" ""
    printf 'from lib.mod import double\n\ndef test_exists():\n    assert callable(double)\n' > "$E2/rig/tests/test_passes.py"
    push_branch "$E2/rig" feat/e2
    LOGF="$H_SCRATCH/e2.log"; : > "$LOGF"
    RC=$(GATE_ABT_RUN_TIMEOUT=60 run_block "$E2/rig" $BEAD_B feat/e2)
    eq "the block refuses (exit 1)" "$RC" "1"
    eq "verdict passou-na-base" "$(logged 'AB-BASE-TEST bead=ga-pj5va arm=B verdict=passou-na-base ')" "1"
    eq "the marker is set to gate-status error (fixable and re-submittable)" "$(logged '^STATUS mk-e2e error')" "1"
    eq "the refusal comment NAMES the pytest file the builder must strengthen" "$(logged 'BD .*comment mk-e2e .*tests/test_passes.py')" "1"
    eq "...and is not a refusal without the marker label: passou-na-base label present" "$(logged 'BD .*label add mk-e2e gate-ab-basetest:passou-na-base')" "1"

    echo "  -- arm A: untouched, nothing measured --"
    E3="$H_SCRATCH/e2e3"; mk_remote "$E3"; branch "$E3/rig" feat/e3; fix_code "$E3/rig" ""
    printf 'from lib.mod import double\n\ndef test_exists():\n    assert callable(double)\n' > "$E3/rig/tests/test_passes.py"
    push_branch "$E3/rig" feat/e3
    LOGF="$H_SCRATCH/e3.log"; : > "$LOGF"
    RC=$(run_block "$E3/rig" $BEAD_A feat/e3 "TOTALS files=0 counted=0 copy_ok=0 ran=0 failed=0 repaired=0 unclassified=0 py=0 js=0")
    eq "the same branch under an arm-A bead completes (exit 0)" "$RC" "0"
    eq "arm A: the py/js scan is NEVER called (byte-for-byte today's behaviour)" "$(logged '^CALLED')" "0"
    eq "arm A: no AB-BASE-TEST line, no label" "$(logged 'AB-BASE-TEST |gate-ab')" "0"
    eq "arm A: only the AB-ARM line is written" "$(logged 'AB-ARM bead=ga-rstae arm=A')" "1"

    echo "  -- arm B, the changed-file list cannot be read: never sem-teste-novo, never a refusal --"
    LOGF="$H_SCRATCH/e5.log"; : > "$LOGF"
    RC=$(run_block "$E3/rig" $BEAD_B feat/e3 "UNREAD")
    eq "UNREAD -> the block completes (no refusal)" "$RC" "0"
    eq "UNREAD -> verdict nao-consegui-medir (NOT sem-teste-novo: that is the claim 'I looked and there is nothing')" \
      "$(logged 'AB-BASE-TEST bead=ga-pj5va arm=B verdict=nao-consegui-medir ')" "1"
    eq "UNREAD is recorded, on the PYJS line" "$(logged 'AB-BASE-TEST-PYJS bead=ga-pj5va arm=B .*pyjs=unread')" "1"

    echo "  -- arm B, bash selftest + pytest together: counts add up --"
    E6="$H_SCRATCH/e2e6"; mk_remote "$E6"; branch "$E6/rig" feat/e6; fix_code "$E6/rig" ""
    printf '#!/bin/bash\nexit 0\n' > "$E6/rig/check.selftest.sh"
    printf 'from lib.mod import double\n\ndef test_double():\n    assert double(2) == 4\n' > "$E6/rig/tests/test_fails.py"
    push_branch "$E6/rig" feat/e6
    LOGF="$H_SCRATCH/e6.log"; : > "$LOGF"
    RC=$(GATE_ABT_RUN_TIMEOUT=60 run_block "$E6/rig" $BEAD_B feat/e6)
    eq "a selftest that passes on base + a pytest that FAILS on base -> reprovou-na-base (no refusal)" \
      "$(logged 'AB-BASE-TEST bead=ga-pj5va arm=B verdict=reprovou-na-base .*detected=2 copy_ok=2 ran=2 failed=1')" "1"
    eq "...and exit 0" "$RC" "0"
    E7="$H_SCRATCH/e2e7"; mk_remote "$E7"; branch "$E7/rig" feat/e7; fix_code "$E7/rig" ""
    printf '#!/bin/bash\nexit 0\n' > "$E7/rig/check.selftest.sh"
    printf 'from lib.mod import double\n\ndef test_exists():\n    assert callable(double)\n' > "$E7/rig/tests/test_passes.py"
    push_branch "$E7/rig" feat/e7
    LOGF="$H_SCRATCH/e7.log"; : > "$LOGF"
    RC=$(GATE_ABT_RUN_TIMEOUT=60 run_block "$E7/rig" $BEAD_B feat/e7)
    eq "a selftest AND a pytest that both pass on base -> refused" "$RC" "1"
    eq "...and the refusal names BOTH files" "$(logged 'BD .*comment mk-e2e .*check.selftest.sh.*tests/test_passes.py')" "1"

    echo "  -- arm B, a rig with no venv: the pytest file is unmeasured, never refused --"
    E8="$H_SCRATCH/e2e8"; mk_remote "$E8"; branch "$E8/rig" feat/e8; fix_code "$E8/rig" ""
    printf 'from lib.mod import double\n\ndef test_exists():\n    assert callable(double)\n' > "$E8/rig/tests/test_passes.py"
    push_branch "$E8/rig" feat/e8
    rm -f "$E8/rig/venv"
    LOGF="$H_SCRATCH/e8.log"; : > "$LOGF"
    RC=$(run_block "$E8/rig" $BEAD_B feat/e8)
    eq "no interpreter -> exit 0 (no refusal)" "$RC" "0"
    eq "...verdict nao-consegui-medir" "$(logged 'AB-BASE-TEST bead=ga-pj5va arm=B verdict=nao-consegui-medir ')" "1"
    eq "no scratch directory, worktree dir or probe file left behind by any of the above (incl. the arm-A and refusal paths)" \
      "$(ls -A "$PRIV7" | wc -l | tr -d ' ')" "0"
  fi
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
