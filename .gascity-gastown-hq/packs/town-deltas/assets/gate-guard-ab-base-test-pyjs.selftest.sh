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

if need_fn gate_base_test_py_interp; then
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

if need_fn gate_base_test_sandbox_exec; then
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

if need_fn gate_base_test_run_table; then
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

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
