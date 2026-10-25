#!/usr/bin/env bash
# gate-e11-diff-cap.selftest.sh — ga-lzidpo (E11 of the P0 ga-ufskhy): the production-code size cap on a
# gate submission, as an A/B, in quality-gate-guard.sh.
#
# THE DATA BEHIND IT (measured 05/10, 1.408 gate runs): first-attempt approval by diff size is 55-80% under 500
# lines, 31-57% for 500-1500, and 13% over 1500 (8/61 last week). The reviewer cannot cover a giant diff in one
# pass, and every round finds another instance of what was already in the first diff (E4: 53%).
#
# WHAT THE GUARD DOES (arm B only): a marker whose diff against origin/main, counting ONLY production code
# (no tests, fixtures, generated files, lockfiles or .md docs), is over 800 lines is REFUSED at submission —
# gate-status:error plus the instruction to split into slices, each with its own marker. Arm A (control) is today's
# behavior. The arm is a pure function of the bead id (SHA-256 with its own salt 'e11-diff-cap', the E5/E9 pattern).
# Exemption: label gate:size-exempt WITH a reason in a comment (mechanical migration / rename). Born OFF: the flag
# file $GC_CITY/.gc/gate-e11-diff-cap.on is the Mayor's switch.
#
# ga-mzyghi adds a SECOND cap on the same arm-B submission: the TOTAL of the diff (insertions + deletions over every path
# a person wrote — code, tests, fixtures, docs; not generated/vendor/lockfiles/node_modules/dist, not changelog fragments),
# 1000 by default (GATE_E11_TOTAL_CAP). Same third state (refused only on a MEASURED total with the exemption READ as
# absent). Exempt by gate:size-exempt (label + reason) or by a source bead that already carries gate:fix-attempt:*. The
# first-review pass rate falls from 81% (<=200 lines) to 36% (>800) by TOTAL size, and the average bead was above 1000
# because 532 of its 871 lines were tests and docs, which the production cap never saw.
#
# THE THIRD STATE, which is what the acceptance criteria hang on: a diff that cannot be read, a count that failed,
# a bead whose exemption cannot be read — none of those refuses. They are logged as 'nao-medido' and the submission
# goes through exactly as today. A refusal needs POSITIVE evidence (a measured count over the cap and an exemption
# read as absent); "I could not tell" is never "too big".
#
# Every assertion below must FAIL on the guard as it was before this change (run it with
# GATE_GUARD_UNDER_TEST=<a copy of the old guard>: the functions do not exist and the block is not there).
#
# Runs under PATH bash AND /bin/bash 3.2 (the interpreter launchd uses) — keep it 3.2-clean. Exit 0 iff all hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GATE_GUARD_UNDER_TEST:-$SELF_DIR/quality-gate-guard.sh}"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }
has() { grep -F -- "$3" "$2" >/dev/null 2>&1 && ok "$1" || bad "$1 — '$3' not in: $(tr '\n' '|' < "$2" | cut -c1-300)"; }
lacks() { grep -F -- "$3" "$2" >/dev/null 2>&1 && bad "$1 — '$3' unexpectedly in: $(tr '\n' '|' < "$2" | cut -c1-300)" || ok "$1"; }
# five older assertions call `hasnt`, which nothing defined: "command not found" is not a failure here, so they counted for
# nothing (found by ga-mzyghi). Same meaning as `lacks`.
hasnt() { lacks "$@"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # sourcing the guard leaks its `set -e` into this shell (same as the siblings)
# An operator's own cap in the environment would turn every live-block assertion below into a loud failure (gate round 3,
# nit): the sections that need an override set it themselves, per call.
unset GATE_E11_CAP_LINES GATE_E11_TOTAL_CAP

# ── 0. preflight: every function the feature is made of exists ──────────────
# Without this a negative assertion ("prints nothing", "no bd call") passes VACUOUSLY on a guard that has no E11 at
# all — `command not found` also prints nothing. One assertion per function, so the old guard fails loudly here.
echo "── 0. the E11 functions exist ──"
E11_FNS="gate_e11_switch_state gate_e11_enabled gate_e11_arm_for_bead gate_e11_path_is_production gate_e11_count_production_lines
gate_e11_cap_lines gate_e11_cap_state gate_e11_exempt_label gate_e11_exempt_reason gate_e11_exempt_state gate_e11_exempt_merge gate_e11_verdict gate_e11_force_all
gate_e11_path_is_generated gate_e11_path_counts_for_total gate_e11_count_lines_by gate_e11_count_total_lines gate_e11_total_cap gate_e11_total_cap_state
gate_e11_fix_attempt_label gate_e11_fix_attempt_state gate_e11_total_verdict gate_e11_combine_verdicts gate_e11_caps_exceeded gate_e11_refused_by
gate_e11_label_state gate_e11_labels_as_wanted gate_e11_label_write_verified gate_e11_refusal_count"
E11_MISSING=0
for f in $E11_FNS; do
  if declare -F "$f" >/dev/null 2>&1; then ok "function $f is defined"; else bad "function $f is NOT defined in $GUARD"; E11_MISSING=1; fi
done

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/gate-e11-selftest.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
LOGF="$TMPD/log.txt"
CALLS="$TMPD/calls.txt"
mkdir -p "$TMPD/city/.gc"
TAB=$'\t'

# ── 1. the switch: born OFF ──────────────────────────────────────────────────
echo "── 1. gate_e11_enabled: off unless the Mayor turns it on ──"
unset GATE_E11_ENABLED GATE_E11_FLAG_FILE
FLAG="$TMPD/city/.gc/gate-e11-diff-cap.on"
eq "no flag file, no env: OFF" "$(GC_CITY="$TMPD/city" gate_e11_enabled)" "0"
: > "$FLAG"
eq "flag file present: ON" "$(GC_CITY="$TMPD/city" gate_e11_enabled)" "1"
eq "env 0 wins over the file" "$(GATE_E11_ENABLED=0 GC_CITY="$TMPD/city" gate_e11_enabled)" "0"
rm -f "$FLAG"
eq "env 1 wins over an absent file" "$(GATE_E11_ENABLED=1 GC_CITY="$TMPD/city" gate_e11_enabled)" "1"
eq "env with a junk value does not turn it on" "$(GATE_E11_ENABLED=yes GC_CITY="$TMPD/city" gate_e11_enabled)" "0"
if [ "$(id -u)" != "0" ]; then
  : > "$FLAG"; chmod 000 "$FLAG"
  eq "flag file that EXISTS but cannot be read is OFF (inert), not on" "$(GC_CITY="$TMPD/city" gate_e11_enabled)" "0"
  chmod 600 "$FLAG"; rm -f "$FLAG"
fi
eq "GC_CITY empty and no env: OFF" "$(GC_CITY="" gate_e11_enabled)" "0"

# Gate round 2, blocking issue 1: an env value that is not exactly 1 or 0 fell THROUGH to the flag file, so with the
# file present an operator's `GATE_E11_ENABLED=off` kept E11 refusing. "I could not understand the switch" must be
# INERT — the same direction as every other doubt in this feature — never "no override". The test above ('junk value
# does not turn it on') only passed because the flag file was ABSENT at that point: it could not tell an inert junk
# value from an ignored one. These all run with the flag file PRESENT, which is the case that matters.
: > "$FLAG"
for JUNK in off false no 2 yes on ON " "; do
  eq "flag file PRESENT + env '$JUNK' (an unreadable override): OFF, not ON" "$(GATE_E11_ENABLED="$JUNK" GC_CITY="$TMPD/city" gate_e11_enabled)" "0"
done
eq "flag file present + env EMPTY: no override at all, the file decides: ON" "$(GATE_E11_ENABLED= GC_CITY="$TMPD/city" gate_e11_enabled)" "1"
eq "flag file present + env 1: ON" "$(GATE_E11_ENABLED=1 GC_CITY="$TMPD/city" gate_e11_enabled)" "1"
# the switch's own state, which the live block logs when OFF is not a decision but a failure to read
eq "state: file decides, present = on" "$(GATE_E11_ENABLED= GC_CITY="$TMPD/city" gate_e11_switch_state)" "on"
eq "state: env 1 = on" "$(GATE_E11_ENABLED=1 GC_CITY="$TMPD/city" gate_e11_switch_state)" "on"
eq "state: env 0 = off (a decision, nothing to say)" "$(GATE_E11_ENABLED=0 GC_CITY="$TMPD/city" gate_e11_switch_state)" "off"

echo "── 1b. the 100% switch (Athos 07/10: 'Ligar hoje, 100%') ──"
rm -f "$TMPD/city/.gc/gate-e11-diff-cap.all"
eq "100%: no env, no .all file -> 0 (arms stay A/B)" "$(GATE_E11_ALL= GC_CITY="$TMPD/city" gate_e11_force_all)" "0"
eq "100%: env GATE_E11_ALL=1 -> 1" "$(GATE_E11_ALL=1 GC_CITY="$TMPD/city" gate_e11_force_all)" "1"
eq "100%: env GATE_E11_ALL=0 beats a present file" "$(touch "$TMPD/city/.gc/gate-e11-diff-cap.all"; GATE_E11_ALL=0 GC_CITY="$TMPD/city" gate_e11_force_all)" "0"
eq "100%: .all file present, env empty -> 1" "$(GATE_E11_ALL= GC_CITY="$TMPD/city" gate_e11_force_all)" "1"
eq "100%: junk env (GATE_E11_ALL=yes) -> 0, never 'on by accident'" "$(GATE_E11_ALL=yes GC_CITY="$TMPD/city" gate_e11_force_all)" "0"
eq "100%: no GC_CITY and no env -> 0" "$(unset GC_CITY; GATE_E11_ALL= gate_e11_force_all)" "0"
rm -f "$TMPD/city/.gc/gate-e11-diff-cap.all"
# the live block honours it: the exact arm-promotion line must exist between the sentinels
# (the block is read into a variable first: `sed | grep -q` under pipefail fails whenever grep exits on its first match before
# sed has finished writing — the block grew with ga-mzyghi and the assertion became flaky)
E11_BLOCK_NOW=$(sed -n '/# SELFTEST-EXTRACT e11-diff-cap: BEGIN/,/# SELFTEST-EXTRACT e11-diff-cap: END/p' "$GUARD" || true)
if [[ "$E11_BLOCK_NOW" == *'if [ "$_E11_ARM" = "A" ] && [ "$(gate_e11_force_all)" = "1" ]; then _E11_ARM="B"; _E11_FORCED=1; fi'* ]]; then ok "live block promotes arm A to B under the 100% switch (and leaves '?' alone)"; else bad "live block does not consult gate_e11_force_all"; fi
eq "state: env 'off' = env-invalido (OFF, and it SAYS why)" "$(GATE_E11_ENABLED=off GC_CITY="$TMPD/city" gate_e11_switch_state)" "env-invalido"
eq "state: env ' ' (a single space) = env-invalido" "$(GATE_E11_ENABLED=" " GC_CITY="$TMPD/city" gate_e11_switch_state)" "env-invalido"
rm -f "$FLAG"
eq "state: no env, no file = off (born OFF, nothing to say)" "$(GATE_E11_ENABLED= GC_CITY="$TMPD/city" gate_e11_switch_state)" "off"
eq "state: GC_CITY empty and no env = off" "$(GATE_E11_ENABLED= GC_CITY="" gate_e11_switch_state)" "off"
if [ "$(id -u)" != "0" ]; then
  : > "$FLAG"; chmod 000 "$FLAG"
  eq "state: flag file that EXISTS but cannot be read = flag-ilegivel (OFF, and it SAYS why — round 2 low)" "$(GATE_E11_ENABLED= GC_CITY="$TMPD/city" gate_e11_switch_state)" "flag-ilegivel"
  chmod 600 "$FLAG"; rm -f "$FLAG"
fi
ln -s "$TMPD/nowhere.on" "$FLAG"
eq "state: a DANGLING symlink as the flag file = flag-ilegivel, not a quiet off" "$(GATE_E11_ENABLED= GC_CITY="$TMPD/city" gate_e11_switch_state)" "flag-ilegivel"
eq "a dangling symlink as the flag file: OFF" "$(GATE_E11_ENABLED= GC_CITY="$TMPD/city" gate_e11_enabled)" "0"
rm -f "$FLAG"

# ── 2. the arm: SHA-256, own salt, pure function of the bead id ──────────────
echo "── 2. gate_e11_arm_for_bead: SHA-256('e11-diff-cap:<bead>'), even => B ──"
n_b=0; n_a=0; n_wrong=0
i=0
while [ "$i" -lt 120 ]; do
  i=$((i+1)); id="ga-e11arm$i"
  got="$(gate_e11_arm_for_bead "$id")"
  d="$(printf '%s' "e11-diff-cap:$id" | shasum -a 256 | cut -c1-8)"
  if [ $(( 16#$d % 2 )) -eq 0 ]; then want=B; else want=A; fi
  [ "$got" = "$want" ] || n_wrong=$((n_wrong+1))
  [ "$got" = "B" ] && n_b=$((n_b+1))
  [ "$got" = "A" ] && n_a=$((n_a+1))
done
eq "120 ids: every arm equals the independent shasum recomputation" "$n_wrong" "0"
if [ "$n_a" -ge 36 ] && [ "$n_b" -ge 36 ]; then ok "120 ids: a real split, A=$n_a B=$n_b (not a lopsided hash)"; else bad "120 ids: lopsided split A=$n_a B=$n_b"; fi
arm1="$(gate_e11_arm_for_bead ga-e11arm7 2>/dev/null)"; arm2="$(gate_e11_arm_for_bead ga-e11arm7 2>/dev/null)"
case "$arm1" in A|B) [ "$arm1" = "$arm2" ] && ok "same id twice, same arm '$arm1' (a re-submission can never hop arms)" || bad "same id gave '$arm1' then '$arm2'" ;;
  *) bad "same id twice: no arm at all ('$arm1') — equal emptiness is not stability" ;; esac
gate_e11_arm_for_bead "" >/dev/null 2>&1; eq "empty id: rc 2 (no arm)" "$?" "2"
# 'prints nothing' only means something when the function EXISTS (a missing one also prints nothing, rc 127)
if declare -F gate_e11_arm_for_bead >/dev/null 2>&1; then
  eq "empty id: prints nothing — never an 'A'" "$(gate_e11_arm_for_bead "" 2>/dev/null)" ""
  out="$( PATH=/nonexistent; gate_e11_arm_for_bead ga-e11arm7 2>/dev/null )"
  eq "no sha tool on PATH: prints nothing (no arm, never A)" "$out" ""
else
  bad "empty id: prints nothing — cannot be judged, gate_e11_arm_for_bead is not defined"
  bad "no sha tool on PATH: prints nothing — cannot be judged, gate_e11_arm_for_bead is not defined"
fi
( PATH=/nonexistent; gate_e11_arm_for_bead ga-e11arm7 >/dev/null 2>&1 ); eq "no sha tool on PATH: rc 3" "$?" "3"

# ── 3. what counts as production code ───────────────────────────────────────
echo "── 3. gate_e11_path_is_production ──"
prod() { gate_e11_path_is_production "$1"; }
for p in src/a.sh packs/town-deltas/assets/quality-gate-guard.sh scripts/gate-e11-switch.sh cmd/gc/main.go \
         internal/x/manager.go src/contest/a.sh src/latest.sh src/protest.py lib/attest.go web/app.ts; do
  prod "$p"; eq "production: $p" "$?" "0"
done
for p in tests/x.sh a/tests/x.sh a/test/x.sh a/__tests__/x.js foo.selftest.sh packs/x/assets/gate-e11-diff-cap.selftest.sh \
         a/b/test_x.py a/b/x_test.py x_test.go web/a.test.ts web/a.spec.js a/conftest.py \
         testdata/a.txt a/fixtures/b.json a/fixture/b.json a/__snapshots__/x.snap a/x.golden \
         package-lock.json sub/yarn.lock sub/pnpm-lock.yaml go.sum Cargo.lock poetry.lock sub/Gemfile.lock x/other.lock \
         docs/a.md README.md notes/a.markdown notes/a.mdx \
         api/x.pb.go x_pb2.py x_pb2_grpc.py static/app.min.js static/app.min.css a/b.generated.ts a/b_generated.go x.gen.go \
         vendor/lib/a.go a/node_modules/x/index.js a/dist/bundle.js a/generated/x.go; do
  prod "$p"; eq "NOT production: $p" "$?" "1"
done
# The REAL test names this repo tracks (ga-lzidpo gate round 1: a synthetic foo.selftest.sh alone let the Python
# convention through — 910-1716 lines each, so a 40-line change plus its selftest.py read as 950 production lines).
# Each is a path `git ls-files` returns today. A test counted as production inflates a MEASURED count and refuses
# honest work, the one direction this feature must never err in.
for p in .gascity-gastown-hq/scripts/jev-preambulo.selftest.py .gascity-gastown-hq/scripts/portaria-shadow.selftest.py \
         .gascity-gastown-hq/scripts/cdp-tab-guard.selftest.py .gascity-gastown-hq/scripts/jev_recomecar_experiment.selftest.py \
         .gascity-gastown-hq/scripts/jev-quem-pensa.selftest.py \
         .gascity-gastown-hq/packs/town-deltas/assets/bead-token-meter.selftest.py \
         web/app.selftest.js \
         .gascity-gastown-hq/packs/town-deltas/assets/selftest-sandbox-path.lib.sh \
         .gascity-gastown-hq/packs/town-deltas/assets/selftest-tmproot-tripwire.lib.sh \
         scripts/test-gce-install.sh scripts/test-proxy-smoke.sh scripts/migration-test/test-edge-cases.sh \
         scripts/migration-test/run-test.sh scripts/migration-test/vm-integration-test.sh \
         npm-package/scripts/test.js; do
  prod "$p"; eq "NOT production (real repo test name): $p" "$?" "1"
done
# Gate round 3 (ga-v9g519, blocking issue 1): the same class, now by DIRECTORY. This repo keeps its post-deploy tests in
# .../assets/prod-tests/<rig>/story-ga-*.sh + run.sh (58 of the 59 tracked files, ~6.000 lines, headed "prod test for
# ga-xxxx"): the directory is `prod-tests`, not a whole `tests` component, and none of the base names is test_*/*_test.*/
# *.selftest.* — so round 1's fix, built from selftest.py / selftest lib / test-*.sh shapes only, let every one of them
# count as production (commit a7321f4a8 read 802 = refused at 800; its real production count is 694). Each path below is
# one `git ls-files` returns today: the directory shapes this repo's tests really live under, not only the base names.
for p in .gascity-gastown-hq/packs/town-deltas/assets/prod-tests/gascity/story-ga-5c3msy.sh \
         .gascity-gastown-hq/packs/town-deltas/assets/prod-tests/lexbh/run.sh \
         .gascity-gastown-hq/packs/town-deltas/assets/prod-tests/property_scrapers/story-ga-0ys.sh \
         internal/testutil/doltserver.go internal/testutil/cmd.go \
         scripts/migration-test/seed-data.sh scripts/migration-test/validate-migration.sh; do
  prod "$p"; eq "NOT production (real repo test DIRECTORY): $p" "$?" "1"
done
# The class, not the one directory: a component qualified as a test dir (-test, -tests, _test, _tests suffix) and the Go
# helper package testutil/testutils are test code wherever they sit, whole components only.
for p in a/prod-tests/x.sh a/e2e-tests/x.py a/migration-test/x.sh a/smoke_tests/x.py a/unit_test/x.sh \
         a/b/testutil/x.go a/testutils/x.go top-tests/x.sh; do
  prod "$p"; eq "NOT production (test-qualified directory shape): $p" "$?" "1"
done
# …and the names that LOOK like tests but are product code must stay counted: only the anchored shapes above are
# excluded, never a bare 'test'/'selftest' substring.
for p in internal/daemon/main_branch_test_runner.go internal/doctor/testutil_symlink_check.go \
         .gascity-gastown-hq/packs/town-deltas/assets/gate_basetest_outcomes.py \
         .gascity-gastown-hq/packs/town-deltas/assets/heavy-selftest-guard.sh \
         src/latest-test-run.go src/contest-runner.sh src/selftestify.py; do
  prod "$p"; eq "still production (test-ish name, product code): $p" "$?" "0"
done
# The directory shapes are anchored on the WHOLE component too: a dir that merely contains the word, or ends in it with
# no separator, is product code (the same rule that keeps src/contest/ and lib/attest.go counted).
for p in src/contest-runner/a.sh src/test-runner/a.sh src/latest/a.sh src/fastest/a.sh src/attest/a.sh src/protests/a.py \
         src/testutility/a.go src/testutil-helpers/a.go src/prod-testing/a.sh src/tests-runner/a.sh src/ab-test-arms/a.sh; do
  prod "$p"; eq "still production (dir name merely contains the word): $p" "$?" "0"
done
# Known edge, pinned so it stays a decision: "/$p/" makes the last segment a component, so an extension-less FILE named like
# a test dir is excluded too (the same way a file named `tests` always was). It leans toward not counting — the inert side.
prod src/run-test; eq "NOT production (extension-less file named like a test dir: inert side, same as a file named 'tests')" "$?" "1"
prod src/tests;    eq "NOT production (a file named exactly 'tests': the pre-existing behavior this edge shares)" "$?" "1"
# The replay that made the reviewer's point, as an assertion, on a REAL numstat (git diff --numstat --no-renames of
# a7321f4a8, feat(ga-5lx)): its two prod-tests files (story-ga-5lx.sh 78 + run.sh 30) took a 694-line production change to
# 802 = refused at the 800 cap. The 215-line skill-audit.selftest.sh was already excluded.
A7321="130${TAB}0${TAB}.gascity-gastown-hq/scripts/skill-integrity-install.sh
268${TAB}0${TAB}.gascity-gastown-hq/scripts/skill-audit.sh
30${TAB}0${TAB}.gascity-gastown-hq/packs/town-deltas/assets/prod-tests/gascity/run.sh
39${TAB}0${TAB}.gascity-gastown-hq/packs/town-deltas/assets/skill-audit.plist
43${TAB}0${TAB}.gascity-gastown-hq/scripts/skill-lib.sh
53${TAB}0${TAB}.gascity-gastown-hq/scripts/skill-audit-emit.sh
72${TAB}1${TAB}.gascity-gastown-hq/scripts/skill-deploy.sh
78${TAB}0${TAB}.gascity-gastown-hq/packs/town-deltas/assets/prod-tests/gascity/story-ga-5lx.sh
88${TAB}0${TAB}.gascity-gastown-hq/packs/town-deltas/assets/delivery-runbooks.toml
215${TAB}0${TAB}.gascity-gastown-hq/scripts/skill-audit.selftest.sh"
eq "gate round 3 replay (a7321f4a8): the prod-tests story and run.sh do not count — 694, not the 802 that was refused" "$(gate_e11_count_production_lines "$A7321")" "694"

# ── 4. counting: added + deleted over production paths, three states ─────────
echo "── 4. gate_e11_count_production_lines ──"
NS="10${TAB}2${TAB}src/a.sh
5${TAB}5${TAB}tests/t.sh
300${TAB}0${TAB}package-lock.json
-${TAB}-${TAB}logo.png
7${TAB}1${TAB}README.md
20${TAB}0${TAB}src/b.py
"
eq "added+deleted, tests/lock/docs out, binary row 0: 12 + 0 + 20" "$(gate_e11_count_production_lines "$NS")" "32"
eq "empty numstat is a MEASURED zero" "$(gate_e11_count_production_lines "")" "0"
eq "a path git quoted is unquoted before it is classified" "$(gate_e11_count_production_lines "4${TAB}0${TAB}\"src/q.sh\"")" "4"
eq "a quoted TEST path is still a test" "$(gate_e11_count_production_lines "9${TAB}0${TAB}\"tests/q.sh\"")" "0"
eq "the gate's repro: 910-line jev-preambulo.selftest.py + 40-line jev-preambulo.py counts 40, not 950" "$(gate_e11_count_production_lines "910${TAB}0${TAB}scripts/jev-preambulo.selftest.py
40${TAB}0${TAB}scripts/jev-preambulo.py")" "40"
eq "garbled row (no path): unknown, not 0" "$(gate_e11_count_production_lines "10${TAB}2")" "unknown"
eq "garbled row (non-numeric count): unknown, not 0" "$(gate_e11_count_production_lines "abc${TAB}2${TAB}src/a.sh")" "unknown"
eq "one garbled row among good ones poisons the count: unknown" "$(gate_e11_count_production_lines "10${TAB}2${TAB}src/a.sh
oops")" "unknown"
# Gate round 2 nit: bash arithmetic wraps silently past 2^63 (99999999999999999999 -> 7766279631452241919), and a wrapped
# number is a MEASUREMENT that was never taken. No real numstat has a 10-digit row; one that does is unreadable.
eq "a 20-digit added count would wrap in bash arithmetic: unknown, never the wrapped number" "$(gate_e11_count_production_lines "99999999999999999999${TAB}0${TAB}src/a.sh")" "unknown"
eq "a 20-digit deleted count: unknown" "$(gate_e11_count_production_lines "0${TAB}99999999999999999999${TAB}src/a.sh")" "unknown"
eq "a 10-digit count (past any real diff): unknown" "$(gate_e11_count_production_lines "1000000000${TAB}0${TAB}src/a.sh")" "unknown"
eq "a 9-digit count is still a number" "$(gate_e11_count_production_lines "100000000${TAB}0${TAB}src/a.sh")" "100000000"
eq "a huge count on a TEST path is not read as a number to wrap either: still unknown (the row is unreadable, whatever the path)" "$(gate_e11_count_production_lines "99999999999999999999${TAB}0${TAB}tests/t.sh")" "unknown"

# ── 4b. the TOTAL: everything a person wrote (ga-mzyghi) ─────────────────────
echo "── 4b. gate_e11_path_is_generated / gate_e11_path_counts_for_total / gate_e11_count_total_lines ──"
gen_p() { gate_e11_path_is_generated "$1"; }
for p in vendor/lib/a.go a/node_modules/x/index.js a/dist/bundle.js a/generated/x.go \
         package-lock.json sub/yarn.lock sub/pnpm-lock.yaml go.sum Cargo.lock \
         api/x.pb.go x_pb2.py x_pb2_grpc.py static/app.min.js static/app.min.css a/b.generated.ts a/b_generated.go x.gen.go; do
  gen_p "$p"; eq "generated (no cap counts it): $p" "$?" "0"
done
# the shared list is ONLY what a tool wrote: tests, docs, snapshots and changelog fragments are decided by each cap itself
for p in src/a.sh tests/x.sh docs/a.md a/b/test_x.py a/__snapshots__/x.snap a/x.golden lib/changelog.d/x.md \
         src/distance/a.go src/vendored/a.sh src/generated_x.go src/lockfile.go; do
  gen_p "$p"; eq "not generated: $p" "$?" "1"
done
tot() { gate_e11_path_counts_for_total "$1"; }
# Code, tests, fixtures, docs: all of it is written by hand and all of it is review load.
for p in src/a.sh tests/x.sh a/test/x.sh a/b/test_x.py x_test.go foo.selftest.sh web/a.test.ts a/conftest.py \
         testdata/a.txt a/fixtures/b.json docs/a.md README.md notes/a.markdown notes/a.mdx \
         .gascity-gastown-hq/packs/town-deltas/assets/prod-tests/gascity/story-ga-5lx.sh \
         lib/changelog.d.txt src/changelog.d.go src/distance/a.go src/vendored/a.sh; do
  tot "$p"; eq "counts toward the total: $p" "$?" "0"
done
# Only what a tool wrote (the shared list), the changelog fragments and the test snapshots stay out.
for p in lib/changelog.d/20261012-x.md changelog.d/a.txt a/__snapshots__/x.snap x.snap a/x.golden \
         vendor/lib/a.go a/node_modules/x/index.js a/dist/bundle.js a/generated/x.go \
         package-lock.json sub/yarn.lock sub/pnpm-lock.yaml go.sum Cargo.lock \
         api/x.pb.go x_pb2.py x_pb2_grpc.py static/app.min.js static/app.min.css a/b.generated.ts a/b_generated.go x.gen.go; do
  tot "$p"; eq "NOT in the total: $p" "$?" "1"
done
# the numstat of section 4, read by the other counter: 12 (src/a.sh) + 10 (tests) + 0 (lockfile) + 0 (binary) + 8 (README) + 20
eq "total: tests and docs count, lockfile and binary do not: 12 + 10 + 8 + 20" "$(gate_e11_count_total_lines "$NS")" "50"
eq "...and the production count of the SAME numstat is unchanged: 32" "$(gate_e11_count_production_lines "$NS")" "32"
eq "total: empty numstat is a MEASURED zero" "$(gate_e11_count_total_lines "")" "0"
eq "total: a quoted path is unquoted first" "$(gate_e11_count_total_lines "4${TAB}0${TAB}\"tests/q.sh\"")" "4"
eq "total: a quoted GENERATED path is still generated" "$(gate_e11_count_total_lines "4${TAB}0${TAB}\"vendor/q.go\"")" "0"
eq "total: a changelog fragment does not count, the code beside it does" "$(gate_e11_count_total_lines "2000${TAB}0${TAB}lib/changelog.d/20261012-x.md
30${TAB}0${TAB}src/a.sh")" "30"
eq "total: added + deleted" "$(gate_e11_count_total_lines "100${TAB}40${TAB}tests/t.sh")" "140"
eq "total: garbled row (no path): unknown, not 0" "$(gate_e11_count_total_lines "10${TAB}2")" "unknown"
eq "total: garbled row (non-numeric count): unknown" "$(gate_e11_count_total_lines "abc${TAB}2${TAB}src/a.sh")" "unknown"
eq "total: a garbled row on a GENERATED path still poisons the count (the row is unreadable, whatever the path)" "$(gate_e11_count_total_lines "abc${TAB}2${TAB}package-lock.json
10${TAB}0${TAB}src/a.sh")" "unknown"
eq "total: a 20-digit count would wrap: unknown" "$(gate_e11_count_total_lines "99999999999999999999${TAB}0${TAB}tests/t.sh")" "unknown"
eq "total: a 10-digit count: unknown" "$(gate_e11_count_total_lines "1000000000${TAB}0${TAB}src/a.sh")" "unknown"
eq "total: a 9-digit count is still a number" "$(gate_e11_count_total_lines "100000000${TAB}0${TAB}tests/t.sh")" "100000000"
eq "gate round 3 replay (a7321f4a8): 694 production lines, 1017 in the total (the total cap would refuse it)" "$(gate_e11_count_total_lines "$A7321")" "1017"
eq "count_lines_by with a predicate that is not a function: unknown, never a measured zero" "$(gate_e11_count_lines_by no_such_predicate "10${TAB}2${TAB}src/a.sh")" "unknown"
eq "count_lines_by with no predicate at all: unknown" "$(gate_e11_count_lines_by "" "10${TAB}2${TAB}src/a.sh")" "unknown"

# ── 5. the cap ───────────────────────────────────────────────────────────────
echo "── 5. gate_e11_cap_lines ──"
eq "default is 800" "$(unset GATE_E11_CAP_LINES; gate_e11_cap_lines)" "800"
eq "numeric override" "$(GATE_E11_CAP_LINES=1000 gate_e11_cap_lines)" "1000"
eq "junk override falls back to 800" "$(GATE_E11_CAP_LINES=abc gate_e11_cap_lines)" "800"
eq "0 would refuse everything: falls back to 800" "$(GATE_E11_CAP_LINES=0 gate_e11_cap_lines)" "800"
eq "empty override falls back to 800" "$(GATE_E11_CAP_LINES= gate_e11_cap_lines)" "800"

# Gate round 3, class sweep of round 2's blocking issue. A switch nobody could read must not read as "no override"; the
# same is true of the cap. gate_e11_cap_lines above still answers a number (the block needs one to print), so whether
# the override was UNDERSTOOD is a separate question — gate_e11_cap_state: ok (unset, empty, or a positive integer of at
# most 9 digits) or invalido (anything else). An operator's `GATE_E11_CAP_LINES=1,200` fell back to 800 without a word
# and refused submissions they had meant to allow: a doubt that went to the REFUSING side.
echo "── 5b. gate_e11_cap_state ──"
eq "state: unset = ok (the documented default is a decision)" "$(unset GATE_E11_CAP_LINES; gate_e11_cap_state)" "ok"
eq "state: empty = ok (no override)" "$(GATE_E11_CAP_LINES= gate_e11_cap_state)" "ok"
eq "state: 1000 = ok" "$(GATE_E11_CAP_LINES=1000 gate_e11_cap_state)" "ok"
eq "state: 800 spelled out = ok" "$(GATE_E11_CAP_LINES=800 gate_e11_cap_state)" "ok"
eq "state: 0800 (leading zero, still 800) = ok" "$(GATE_E11_CAP_LINES=0800 gate_e11_cap_state)" "ok"
eq "state: 999999999 (9 digits, the last readable size) = ok" "$(GATE_E11_CAP_LINES=999999999 gate_e11_cap_state)" "ok"
for JC in abc "1,200" "1.5" "-5" " " "5 " "0" "00" "1000000000" "99999999999999999999"; do
  eq "state: '$JC' = invalido (an override nobody can read is not 'no override')" "$(GATE_E11_CAP_LINES="$JC" gate_e11_cap_state)" "invalido"
done

# ── 5c. the total cap (ga-mzyghi): same validation as the production cap, its own default ──
echo "── 5c. gate_e11_total_cap / gate_e11_total_cap_state ──"
eq "default total cap is 1000" "$(unset GATE_E11_TOTAL_CAP; gate_e11_total_cap)" "1000"
eq "numeric override" "$(GATE_E11_TOTAL_CAP=1500 gate_e11_total_cap)" "1500"
eq "a leading zero is still a number" "$(GATE_E11_TOTAL_CAP=01500 gate_e11_total_cap)" "1500"
eq "junk override falls back to 1000 (not to the production 800)" "$(GATE_E11_TOTAL_CAP=abc gate_e11_total_cap)" "1000"
eq "0 would refuse everything: falls back to 1000" "$(GATE_E11_TOTAL_CAP=0 gate_e11_total_cap)" "1000"
eq "empty override falls back to 1000" "$(GATE_E11_TOTAL_CAP= gate_e11_total_cap)" "1000"
eq "the production override does not move the total cap" "$(GATE_E11_CAP_LINES=500 gate_e11_total_cap)" "1000"
eq "the total override does not move the production cap" "$(unset GATE_E11_CAP_LINES; GATE_E11_TOTAL_CAP=1500 gate_e11_cap_lines)" "800"
eq "state: unset = ok (the documented default is a decision)" "$(unset GATE_E11_TOTAL_CAP; gate_e11_total_cap_state)" "ok"
eq "state: empty = ok (no override)" "$(GATE_E11_TOTAL_CAP= gate_e11_total_cap_state)" "ok"
eq "state: 1500 = ok" "$(GATE_E11_TOTAL_CAP=1500 gate_e11_total_cap_state)" "ok"
eq "state: 999999999 (9 digits, the last readable size) = ok" "$(GATE_E11_TOTAL_CAP=999999999 gate_e11_total_cap_state)" "ok"
for JC in abc "1,200" "1.5" "-5" " " "5 " "0" "00" "1000000000" "99999999999999999999"; do
  eq "state: '$JC' = invalido (an override nobody can read is not 'no override')" "$(GATE_E11_TOTAL_CAP="$JC" gate_e11_total_cap_state)" "invalido"
done
eq "state: the production override being junk does not make the total override invalid" "$(GATE_E11_CAP_LINES=abc gate_e11_total_cap_state)" "ok"

# ── 6. the exemption: label + reason, three states ───────────────────────────
echo "── 6. gate:size-exempt needs a label AND a reason ──"
LAB_YES='[{"id":"ga-x","labels":["story:approved","gate:size-exempt"]}]'
LAB_NO='[{"id":"ga-x","labels":["story:approved"]}]'
eq "label present (array form)" "$(gate_e11_exempt_label "$LAB_YES")" "yes"
eq "label present (object form)" "$(gate_e11_exempt_label '{"id":"ga-x","labels":["gate:size-exempt"]}')" "yes"
eq "label absent" "$(gate_e11_exempt_label "$LAB_NO")" "no"
eq "no labels key at all on a real bead: absent" "$(gate_e11_exempt_label '[{"id":"ga-x"}]')" "no"
eq "empty output (bd failed): desconhecido, not 'no'" "$(gate_e11_exempt_label "")" "desconhecido"
eq "not JSON: desconhecido" "$(gate_e11_exempt_label "Error: no issue found")" "desconhecido"
eq "an error object with no id: desconhecido, not 'no'" "$(gate_e11_exempt_label '{"error":"not found"}')" "desconhecido"
RSN_OK='[{"text":"Pilot dispatched builder"},{"text":"gate:size-exempt: renome mecanico de 40 arquivos para o novo prefixo"}]'
RSN_SHORT='[{"text":"gate:size-exempt: ok"}]'
RSN_NOPREFIX='[{"text":"this is a mechanical rename of forty files, please exempt it from the size cap"}]'
eq "reason comment with the prefix and a real reason" "$(gate_e11_exempt_reason "$RSN_OK")" "yes"
eq "prefix with a token reason ('ok'): not a reason" "$(gate_e11_exempt_reason "$RSN_SHORT")" "no"
eq "a long comment that does not carry the prefix: not a reason" "$(gate_e11_exempt_reason "$RSN_NOPREFIX")" "no"
eq "no comments: no reason" "$(gate_e11_exempt_reason '[]')" "no"
eq "comments unreadable (empty): desconhecido" "$(gate_e11_exempt_reason "")" "desconhecido"
eq "comments not JSON: desconhecido" "$(gate_e11_exempt_reason "boom")" "desconhecido"
# Gate round 2, low: a comment object with no .text read as an EMPTY comment, so a bd schema drift (text renamed) turned
# "I could not read the comments" into "no reason" -> label-sem-motivo -> REFUSE: the very collapse the feature avoids
# everywhere else. An element that is not an object with a string .text is unreadable. A VALID reason elsewhere in the
# list still wins (positive evidence of the exemption is never outvoted by a neighbour we could not read).
eq "an array element with no .text key (schema drift): desconhecido, not 'no'" "$(gate_e11_exempt_reason '[{"body":"gate:size-exempt: renome mecanico de 40 arquivos para o novo prefixo"}]')" "desconhecido"
eq "a .text that is null: desconhecido" "$(gate_e11_exempt_reason '[{"text":null}]')" "desconhecido"
eq "a .text that is not a string: desconhecido" "$(gate_e11_exempt_reason '[{"text":42}]')" "desconhecido"
eq "an element that is not an object: desconhecido" "$(gate_e11_exempt_reason '["gate:size-exempt: renome mecanico de 40 arquivos"]')" "desconhecido"
eq "a readable comment with no reason PLUS one with no .text: desconhecido (the unreadable one may hold it)" "$(gate_e11_exempt_reason '[{"text":"Pilot dispatched builder"},{"id":"c2"}]')" "desconhecido"
eq "a valid reason PLUS one element with no .text: yes (the reason wins)" "$(gate_e11_exempt_reason '[{"id":"c2"},{"text":"gate:size-exempt: renome mecanico de 40 arquivos para o novo prefixo"}]')" "yes"
eq "an EMPTY-string .text is a readable empty comment: no" "$(gate_e11_exempt_reason '[{"text":""}]')" "no"
eq "state: label + reason = exempt" "$(gate_e11_exempt_state yes yes)" "exempt"
eq "state: label without reason = label-sem-motivo" "$(gate_e11_exempt_state yes no)" "label-sem-motivo"
eq "state: label, reason unreadable = desconhecido" "$(gate_e11_exempt_state yes desconhecido)" "desconhecido"
eq "state: no label = nao" "$(gate_e11_exempt_state no no)" "nao"
eq "state: label unreadable = desconhecido" "$(gate_e11_exempt_state desconhecido no)" "desconhecido"
eq "merge: exempt beats everything" "$(gate_e11_exempt_merge nao exempt)" "exempt"
eq "merge: desconhecido beats label-sem-motivo (the bead nobody could read may hold the exemption)" "$(gate_e11_exempt_merge label-sem-motivo desconhecido)" "desconhecido"
eq "merge: label-sem-motivo beats nao" "$(gate_e11_exempt_merge nao label-sem-motivo)" "label-sem-motivo"
eq "merge: desconhecido beats nao (an unread bead is not 'no exemption')" "$(gate_e11_exempt_merge nao desconhecido)" "desconhecido"
eq "merge: nao + nao = nao" "$(gate_e11_exempt_merge nao nao)" "nao"

# ── 7. the verdict ───────────────────────────────────────────────────────────
echo "── 7. gate_e11_verdict <arm> <count> <exempt> [cap] ──"
v() { gate_e11_verdict "$@"; }
eq "arm A, huge diff: controle (today's behavior)" "$(v A 5000 nao 800)" "controle"
eq "no arm (unidentifiable bead): sem-braco, never refused" "$(v '?' 5000 nao 800)" "sem-braco"
eq "empty arm: sem-braco" "$(v '' 5000 nao 800)" "sem-braco"
eq "B, count unknown: nao-medido (third state, accepts)" "$(v B unknown nao-consultado 800)" "nao-medido"
eq "B, count not a number: nao-medido" "$(v B '' nao-consultado 800)" "nao-medido"
eq "B, exactly at the cap: dentro-do-teto" "$(v B 800 nao-consultado 800)" "dentro-do-teto"
eq "B, zero lines: dentro-do-teto" "$(v B 0 nao-consultado 800)" "dentro-do-teto"
eq "B, one over the cap, no exemption: recusa" "$(v B 801 nao 800)" "recusa"
eq "B, over the cap, label without reason: recusa" "$(v B 801 label-sem-motivo 800)" "recusa"
eq "B, over the cap, exempt: isento" "$(v B 801 exempt 800)" "isento"
eq "B, over the cap, exemption unreadable: nao-medido-isencao (accepts)" "$(v B 801 desconhecido 800)" "nao-medido-isencao"
eq "B, over the cap, exemption never consulted: accepts, never refuses" "$(v B 801 nao-consultado 800)" "nao-medido-isencao"
eq "B, over the cap, an exemption word nobody defined: accepts" "$(v B 801 banana 800)" "nao-medido-isencao"
eq "B, the cap is a parameter" "$(v B 1500 nao 2000)" "dentro-do-teto"
eq "B, a junk cap falls back to 800" "$(v B 801 nao abc)" "recusa"

# ── 7b. the total cap's own pieces: the fix-attempt exemption, the verdict, the two-cap combination ──
echo "── 7b. gate:fix-attempt:*, gate_e11_total_verdict, gate_e11_combine_verdicts, cap_hit / refused_by ──"
eq "fix-attempt label present (array form)" "$(gate_e11_fix_attempt_label '[{"id":"ga-x","labels":["story:approved","gate:fix-attempt:1"]}]')" "yes"
eq "fix-attempt label present (object form)" "$(gate_e11_fix_attempt_label '{"id":"ga-x","labels":["gate:fix-attempt:3"]}')" "yes"
eq "a :0 reset is still a bead the gate already judged (the Pilot's own predicate; a doubt goes to the exempt side)" "$(gate_e11_fix_attempt_label '[{"id":"ga-x","labels":["gate:fix-attempt:0"]}]')" "yes"
eq "no fix-attempt label: no" "$(gate_e11_fix_attempt_label '[{"id":"ga-x","labels":["story:approved","gate:needs-fix"]}]')" "no"
eq "no labels key at all on a real bead: no" "$(gate_e11_fix_attempt_label '[{"id":"ga-x"}]')" "no"
eq "gate:e11-refusals:N is not a fix attempt (a refusal by THIS gate must not exempt the bead from it)" "$(gate_e11_fix_attempt_label '[{"id":"ga-x","labels":["gate:needs-fix","gate:e11-refusals:2"]}]')" "no"
eq "a label that only CONTAINS the text is not the label" "$(gate_e11_fix_attempt_label '[{"id":"ga-x","labels":["x:gate:fix-attempt:1","gate:fix-attemptX"]}]')" "no"
eq "empty output (bd failed): desconhecido, not 'no'" "$(gate_e11_fix_attempt_label "")" "desconhecido"
eq "not JSON: desconhecido" "$(gate_e11_fix_attempt_label "Error: no issue found")" "desconhecido"
eq "an error object with no id: desconhecido, not 'no'" "$(gate_e11_fix_attempt_label '{"error":"not found"}')" "desconhecido"
eq "fix-attempt state: yes = exempt" "$(gate_e11_fix_attempt_state yes)" "exempt"
eq "fix-attempt state: no = nao" "$(gate_e11_fix_attempt_state no)" "nao"
eq "fix-attempt state: desconhecido = desconhecido" "$(gate_e11_fix_attempt_state desconhecido)" "desconhecido"
eq "fix-attempt state: empty = desconhecido" "$(gate_e11_fix_attempt_state "")" "desconhecido"
eq "fix-attempt state: a word nobody defined = desconhecido" "$(gate_e11_fix_attempt_state banana)" "desconhecido"
exT() { gate_e11_exempt_merge "$1" "$(gate_e11_fix_attempt_state "$2")"; }   # what the live block computes for the total cap
eq "total exemption: size-exempt absent + fix-attempt: exempt" "$(exT nao yes)" "exempt"
eq "total exemption: label without a reason + fix-attempt: exempt" "$(exT label-sem-motivo yes)" "exempt"
eq "total exemption: size-exempt present + no fix-attempt: exempt" "$(exT exempt no)" "exempt"
eq "total exemption: neither: nao (a refusal may stand)" "$(exT nao no)" "nao"
eq "total exemption: label without a reason, no fix-attempt: label-sem-motivo (a refusal may stand)" "$(exT label-sem-motivo no)" "label-sem-motivo"
eq "total exemption: fix-attempt unreadable, size-exempt absent: desconhecido (accepts)" "$(exT nao desconhecido)" "desconhecido"
eq "total exemption: size-exempt unreadable, no fix-attempt: desconhecido (accepts)" "$(exT desconhecido no)" "desconhecido"
tv() { gate_e11_total_verdict "$@"; }
eq "total: arm A, huge diff: controle" "$(tv A 5000 nao 1000)" "controle"
eq "total: no arm: sem-braco, never refused" "$(tv '?' 5000 nao 1000)" "sem-braco"
eq "total: B, count unknown: nao-medido (third state, accepts)" "$(tv B unknown nao-consultado 1000)" "nao-medido"
eq "total: B, exactly at the cap: dentro-do-teto" "$(tv B 1000 nao-consultado 1000)" "dentro-do-teto"
eq "total: B, one over, no exemption: recusa" "$(tv B 1001 nao 1000)" "recusa"
eq "total: B, over, label without reason: recusa" "$(tv B 1001 label-sem-motivo 1000)" "recusa"
eq "total: B, over, exempt: isento" "$(tv B 1001 exempt 1000)" "isento"
eq "total: B, over, exemption unreadable: nao-medido-isencao (accepts)" "$(tv B 1001 desconhecido 1000)" "nao-medido-isencao"
eq "total: B, over, exemption never consulted: accepts, never refuses" "$(tv B 1001 nao-consultado 1000)" "nao-medido-isencao"
eq "total: no cap given: the default is 1000" "$(tv B 1001 nao)" "recusa"
eq "total: no cap given, 1000 lines: dentro-do-teto" "$(tv B 1000 nao)" "dentro-do-teto"
eq "total: a junk cap falls back to 1000, NOT to the production 800 (900 lines is inside)" "$(tv B 900 nao abc)" "dentro-do-teto"
eq "total: a junk cap falls back to 1000 (1001 lines is out)" "$(tv B 1001 nao abc)" "recusa"
eq "total: the cap is a parameter" "$(tv B 900 nao 800)" "recusa"
cv() { gate_e11_combine_verdicts "$@"; }
eq "combine: recusa for one cap + nao-medido for the other: recusa (positive evidence stands alone)" "$(cv recusa nao-medido)" "recusa"
eq "combine: nao-medido-isencao + recusa: recusa" "$(cv nao-medido-isencao recusa)" "recusa"
eq "combine: recusa + dentro-do-teto: recusa" "$(cv recusa dentro-do-teto)" "recusa"
eq "combine: isento + recusa: recusa (an exemption for one cap is not one for the other)" "$(cv isento recusa)" "recusa"
eq "combine: recusa + recusa: recusa" "$(cv recusa recusa)" "recusa"
eq "combine: controle + controle: controle" "$(cv controle controle)" "controle"
eq "combine: sem-braco + sem-braco: sem-braco" "$(cv sem-braco sem-braco)" "sem-braco"
eq "combine: dentro-do-teto + dentro-do-teto: dentro-do-teto" "$(cv dentro-do-teto dentro-do-teto)" "dentro-do-teto"
eq "combine: dentro-do-teto + nao-medido-isencao: the doubt stays visible" "$(cv dentro-do-teto nao-medido-isencao)" "nao-medido-isencao"
eq "combine: nao-medido + dentro-do-teto: nao-medido" "$(cv nao-medido dentro-do-teto)" "nao-medido"
eq "combine: isento + dentro-do-teto: isento" "$(cv isento dentro-do-teto)" "isento"
eq "combine: nao-medido + nao-medido-isencao: nao-medido-isencao" "$(cv nao-medido nao-medido-isencao)" "nao-medido-isencao"
eq "combine: nao-medido + isento: nao-medido" "$(cv nao-medido isento)" "nao-medido"
eq "combine: a word nobody defined is a doubt, never a refusal" "$(cv banana dentro-do-teto)" "nao-medido"
eq "combine: ...also next to isento" "$(cv isento banana)" "nao-medido"
eq "combine: ...a refusal on the other cap still stands" "$(cv banana recusa)" "recusa"
eq "combine: ...a stronger doubt on the other cap stays" "$(cv banana nao-medido-isencao)" "nao-medido-isencao"
eq "combine: two undefined words: the doubt, never the word itself" "$(cv banana banana)" "nao-medido"
eq "combine: empty + empty: the doubt (nothing is invented, nothing is refused)" "$(cv "" "")" "nao-medido"
ce() { gate_e11_caps_exceeded "$@"; }
eq "caps_exceeded: production only" "$(ce 900 800 900 1000)" "producao"
eq "caps_exceeded: total only" "$(ce 600 800 1300 1000)" "total"
eq "caps_exceeded: both" "$(ce 900 800 1300 1000)" "ambos"
eq "caps_exceeded: neither" "$(ce 700 800 900 1000)" "nenhum"
eq "caps_exceeded: exactly at both caps is not over" "$(ce 800 800 1000 1000)" "nenhum"
eq "caps_exceeded: one over the production cap" "$(ce 801 800 1000 1000)" "producao"
eq "caps_exceeded: one over the total cap" "$(ce 800 800 1001 1000)" "total"
eq "caps_exceeded: counts not measured are not over anything" "$(ce unknown 800 unknown 1000)" "nenhum"
eq "caps_exceeded: arm A / no arm ('-') is not over anything" "$(ce - 800 - 1000)" "nenhum"
eq "caps_exceeded: one unknown, the other measured" "$(ce unknown 800 1300 1000)" "total"
eq "caps_exceeded: junk caps fall back (800 / 1000)" "$(ce 801 abc 1001 abc)" "ambos"
eq "caps_exceeded: junk caps fall back, 900 total is inside 1000" "$(ce 700 abc 900 abc)" "nenhum"
rb() { gate_e11_refused_by "$@"; }
eq "refused_by: both verdicts refuse" "$(rb recusa recusa)" "ambos"
eq "refused_by: production refuses, the total is exempt" "$(rb recusa isento)" "producao"
eq "refused_by: the total refuses alone" "$(rb dentro-do-teto recusa)" "total"
eq "refused_by: nobody refuses" "$(rb isento nao-medido)" "nenhum"

# ── 8. the guard block, run LIVE ─────────────────────────────────────────────
echo "── 7c. the refusal's label readings: has / lacks / desconhecido (ga-emc197) ──"
# The refusal used to write labels with `|| true` and no read-back, and to turn an unreadable bead into "no refusals yet".
# These are the three-state readings it decides on now: "I could not tell" is its own answer, never "lacks" / "0".
R_ARR='[{"id":"x-1","labels":["gate:queued","story:approved"]}]'
R_OBJ='{"id":"x-1","labels":["gate:needs-fix"]}'
R_EMPTYLBL='[{"id":"x-1","labels":[]}]'
R_NOKEY='[{"id":"x-1"}]'
R_ERR='{"error":"database is locked"}'
eq "label_state: array, label present → has" "$(gate_e11_label_state "$R_ARR" gate:queued)" "has"
eq "label_state: single object, label present → has" "$(gate_e11_label_state "$R_OBJ" gate:needs-fix)" "has"
eq "label_state: label absent → lacks" "$(gate_e11_label_state "$R_ARR" gate:needs-fix)" "lacks"
eq "label_state: empty labels → lacks (the bead was READ)" "$(gate_e11_label_state "$R_EMPTYLBL" gate:queued)" "lacks"
eq "label_state: no labels key → lacks (bd omits it when empty)" "$(gate_e11_label_state "$R_NOKEY" gate:queued)" "lacks"
eq "label_state: empty output → desconhecido, NOT lacks" "$(gate_e11_label_state "" gate:queued)" "desconhecido"
eq "label_state: text that is not JSON → desconhecido" "$(gate_e11_label_state "Error: no such bead" gate:queued)" "desconhecido"
eq "label_state: bd's {error} object → desconhecido" "$(gate_e11_label_state "$R_ERR" gate:queued)" "desconhecido"
eq "label_state: empty array → desconhecido" "$(gate_e11_label_state '[]' gate:queued)" "desconhecido"
eq "label_state: no label named → desconhecido" "$(gate_e11_label_state "$R_ARR" "")" "desconhecido"
eq "as_wanted: every label present → yes" "$(gate_e11_labels_as_wanted "$R_ARR" has gate:queued story:approved)" "yes"
eq "as_wanted: one of two present → no" "$(gate_e11_labels_as_wanted "$R_ARR" has gate:queued gate:needs-fix)" "no"
eq "as_wanted: every label absent → yes" "$(gate_e11_labels_as_wanted "$R_ARR" lacks gate:needs-fix gate:needs-human)" "yes"
eq "as_wanted: one of two still there → no" "$(gate_e11_labels_as_wanted "$R_ARR" lacks gate:needs-fix gate:queued)" "no"
eq "as_wanted: unreadable bead → desconhecido, for has" "$(gate_e11_labels_as_wanted "" has gate:needs-fix)" "desconhecido"
eq "as_wanted: unreadable bead → desconhecido, for lacks (a failed read is not proof of absence)" "$(gate_e11_labels_as_wanted "" lacks gate:queued)" "desconhecido"
eq "as_wanted: a word nobody defined → desconhecido" "$(gate_e11_labels_as_wanted "$R_ARR" banana gate:queued)" "desconhecido"
eq "as_wanted: no label named → desconhecido" "$(gate_e11_labels_as_wanted "$R_ARR" has)" "desconhecido"
eq "refusal_count: no counter label on a READ bead → 0" "$(gate_e11_refusal_count "$R_ARR")" "0"
eq "refusal_count: empty labels → 0" "$(gate_e11_refusal_count "$R_EMPTYLBL")" "0"
eq "refusal_count: no labels key → 0" "$(gate_e11_refusal_count "$R_NOKEY")" "0"
eq "refusal_count: one counter label → N" "$(gate_e11_refusal_count '[{"id":"x-1","labels":["gate:e11-refusals:2"]}]')" "2"
eq "refusal_count: several counter labels → the highest" "$(gate_e11_refusal_count '[{"id":"x-1","labels":["gate:e11-refusals:1","gate:e11-refusals:3","gate:e11-refusals:2"]}]')" "3"
eq "refusal_count: single object also reads" "$(gate_e11_refusal_count '{"id":"x-1","labels":["gate:e11-refusals:2"]}')" "2"
eq "refusal_count: empty output → desconhecido, NOT 0 (it used to restart at '1 of 3')" "$(gate_e11_refusal_count "")" "desconhecido"
eq "refusal_count: text that is not JSON → desconhecido" "$(gate_e11_refusal_count "Error: database is locked")" "desconhecido"
eq "refusal_count: bd's {error} object → desconhecido" "$(gate_e11_refusal_count "$R_ERR")" "desconhecido"
eq "refusal_count: empty array → desconhecido" "$(gate_e11_refusal_count '[]')" "desconhecido"
eq "refusal_count: a junk number is not a count" "$(gate_e11_refusal_count '[{"id":"x-1","labels":["gate:e11-refusals:abc"]}]')" "0"
eq "refusal_count: a negative number is not a count" "$(gate_e11_refusal_count '[{"id":"x-1","labels":["gate:e11-refusals:-3"]}]')" "0"
eq "refusal_count: junk beside a real counter does not hide it" "$(gate_e11_refusal_count '[{"id":"x-1","labels":["gate:e11-refusals:abc","gate:e11-refusals:2"]}]')" "2"

echo "── 8. the live block in quality-gate-guard.sh ──"
E11_FILE="$TMPD/e11-block.sh"
sed -n '/# SELFTEST-EXTRACT e11-diff-cap: BEGIN/,/# SELFTEST-EXTRACT e11-diff-cap: END/p' "$GUARD" > "$E11_FILE"
if [ -s "$E11_FILE" ]; then ok "E11 block found between its SELFTEST-EXTRACT sentinels ($(wc -l < "$E11_FILE") lines)"
else bad "E11 block (SELFTEST-EXTRACT e11-diff-cap sentinels) not found in $GUARD"; echo "  PASS=$PASS  FAIL=$FAIL"; echo "  RESULT: FAIL"; exit 1; fi

# wiring: the cheap refusal sits AFTER the coherence check and BEFORE the expensive base-test worktree step
L_COH=$(grep -n 'SELFTEST-EXTRACT coherence-check: END' "$GUARD" | head -1 | cut -d: -f1)
L_E11=$(grep -n 'SELFTEST-EXTRACT e11-diff-cap: BEGIN' "$GUARD" | head -1 | cut -d: -f1)
L_ABT=$(grep -n 'Step 5b-pre2 (ga-rstae)' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$L_COH" ] && [ -n "$L_E11" ] && [ -n "$L_ABT" ] && [ "$L_COH" -lt "$L_E11" ] && [ "$L_E11" -lt "$L_ABT" ]; then
  ok "wired between the coherence check (line $L_COH) and the base-test A/B (line $L_ABT)"
else bad "E11 block is not between the coherence check and Step 5b-pre2 (coh=$L_COH e11=$L_E11 abt=$L_ABT)"; fi

# A real repo with an origin
GITC="git -c init.defaultBranch=main -c user.email=t@gascity.local -c user.name=Test -c commit.gpgsign=false"
ORIGIN="$TMPD/origin.git"; SEED="$TMPD/seed"; RIG_OK="$TMPD/rig-clone"
gen() { mkdir -p "$(dirname "$1")"; seq 1 "$2" | sed "s/^/${3:-line} /" > "$1"; }
$GITC init -q --bare "$ORIGIN"
$GITC clone -q "$ORIGIN" "$SEED" 2>/dev/null
( cd "$SEED" || exit 1
  echo base > README; gen src/mod.sh 500 old
  $GITC add -A && $GITC commit -q -m "chore: base"
  $GITC push -q origin HEAD:refs/heads/main
  mkb() { $GITC checkout -q main; $GITC checkout -q -b "$1"; }
  fin() { $GITC add -A && $GITC commit -q -m "$2" && $GITC push -q origin "$1"; }
  mkb feat/prod900;  gen src/big.sh 900;  gen tests/t.sh 100;                                   fin feat/prod900 "feat(ga-e11): 900 prod + 100 test"
  mkb feat/prod800;  gen src/a.sh 800;                                                          fin feat/prod800 "feat(ga-e11): exactly the cap"
  mkb feat/prod801;  gen src/a.sh 801;                                                          fin feat/prod801 "feat(ga-e11): one over"
  mkb feat/nonprod;  gen tests/a.sh 1000; gen fixtures/x.json 1000; gen package-lock.json 1000; gen docs/n.md 1000
                     gen lib/x.selftest.sh 1000; gen api/x.pb.go 1000; gen src/small.sh 50;     fin feat/nonprod "feat(ga-e11): lots of non-production"
  mkb feat/rewrite;  gen src/mod.sh 500 new;                                                    fin feat/rewrite "feat(ga-e11): rewrite 500 lines"
  mkb feat/binary;   printf '\000\001\002\003' > src/blob.bin; gen src/ten.sh 10;               fin feat/binary "feat(ga-e11): a binary and 10 lines"
  mkb feat/pytest;   gen scripts/jev.selftest.py 910; gen lib/selftest-sandbox.lib.sh 70; gen scripts/jev.py 40; fin feat/pytest "feat(ga-e11): 40 prod + selftest.py + selftest lib"
  # ga-mzyghi: branches whose PRODUCTION count is under 800 and whose TOTAL is around 1000
  mkb feat/tot1300;  gen src/b.sh 600;  gen tests/b.sh 700;                                     fin feat/tot1300 "feat(ga-e11): 600 prod + 700 test = 1300 total"
  mkb feat/tot1001;  gen src/b.sh 601;  gen tests/b.sh 400;                                     fin feat/tot1001 "feat(ga-e11): 1001 total"
  mkb feat/tot1000;  gen src/b.sh 600;  gen tests/b.sh 400;                                     fin feat/tot1000 "feat(ga-e11): exactly the total cap"
  mkb feat/totdocs;  gen src/b.sh 100;  gen docs/b.md 1100;                                     fin feat/totdocs "feat(ga-e11): 100 prod + 1100 docs"
  # 400 written lines + 14.000 lines nobody wrote; -f so that no ignore rule on this machine (dist/, node_modules/) drops a file
  mkb feat/totexcl;  gen src/b.sh 300;  gen tests/b.sh 100; gen lib/changelog.d/x.md 2000; gen vendor/v.go 2000; gen package-lock.json 2000
                     gen node_modules/n.js 2000; gen dist/d.js 2000; gen api/x.pb.go 2000; gen tests/__snapshots__/s.snap 2000
                     $GITC add -A -f && $GITC commit -q -m "feat(ga-e11): 400 written lines among generated/vendor/changelog/snapshot" && $GITC push -q origin feat/totexcl
) >/dev/null 2>&1
$GITC clone -q "$ORIGIN" "$RIG_OK" 2>/dev/null

# A SECOND origin, for the stale-main case (ga-lzidpo gate round 1, blocking issue 1). main is at C1 when the rig
# clone is made; someone else then merges 1000 lines to main (M2); a 10-line branch is cut from M2. The rig fetches
# ONLY the branch (so origin/main stays at C1 but the branch tip carries M2) and then origin becomes unreachable, so the
# block's own fetch fails. Against the stale C1 the three-dot diff takes in everything main gained since: 1010 lines
# for a 10-line submission. The honest answer is "I could not tell what main is", never "too big".
ORIGIN2="$TMPD/origin2.git"; SEED2="$TMPD/seed2"; RIG_STALE="$TMPD/rig-stale"
$GITC init -q --bare "$ORIGIN2"
$GITC clone -q "$ORIGIN2" "$SEED2" 2>/dev/null
( cd "$SEED2" || exit 1
  echo base > README; gen src/mod.sh 500 old
  $GITC add -A && $GITC commit -q -m "chore: base"
  $GITC push -q origin HEAD:refs/heads/main
) >/dev/null 2>&1
$GITC clone -q "$ORIGIN2" "$RIG_STALE" 2>/dev/null
( cd "$SEED2" || exit 1
  gen src/merged-by-someone-else.sh 1000
  $GITC add -A && $GITC commit -q -m "feat: someone else merges 1000 lines to main (M2)"
  $GITC push -q origin HEAD:refs/heads/main
  $GITC checkout -q -b feat/small
  gen src/ten.sh 10
  $GITC add -A && $GITC commit -q -m "feat(ga-e11): 10 lines on top of M2"
  $GITC push -q origin feat/small
) >/dev/null 2>&1
$GITC -C "$RIG_STALE" fetch -q origin feat/small 2>/dev/null   # the branch only: origin/main stays at C1
STALE_MAIN_BEFORE=$($GITC -C "$RIG_STALE" rev-parse origin/main 2>/dev/null)
REAL_MAIN2=$($GITC -C "$ORIGIN2" rev-parse refs/heads/main 2>/dev/null)
$GITC -C "$RIG_STALE" remote set-url origin "$TMPD/origin-is-gone.git"   # unreachable: every fetch from here on fails
NOT_A_REPO="$TMPD/plain-dir"; mkdir -p "$NOT_A_REPO"

# Stubs for what the live block calls. Defined AFTER sourcing (the guard's own log/err sit past its lib-only cutoff).
log()  { echo "LOG $*" >> "$LOGF"; }
err()  { echo "ERR $*" >> "$LOGF"; }
warn() { echo "WARN $*" >> "$LOGF"; }
set_gate_status() { echo "STATUS $*" >> "$CALLS"; }
# bd answers `show <id>` and `comments <id>` from files named per id AND per store (-C <dir>): the source bead lives in
# BEAD_CITY ($TMPD/beadcity), the marker in GC_CITY ($TMPD/city) — two DIFFERENT dirs, so a block that read the source
# bead from the marker's store (or the reverse) finds nothing and the assertions below fail (gate round 2 nit: the stub
# used to ignore -C and BEAD_CITY equalled GC_CITY, so swapping them would still have passed). Any other verb
# (comment ...) succeeds.
bd() {
  echo "BD $*" >> "$CALLS"
  local dir="" a skip=0 verb="" id="" op="" labs="" f
  local -a rest=()
  for a in "$@"; do
    if [ "$skip" = 1 ]; then dir="$a"; skip=0; continue; fi
    case "$a" in -C) skip=1; continue ;; esac
    rest+=("$a")
  done
  verb="${rest[0]:-}"; id="${rest[1]:-}"
  case "$verb" in
    # E11_STUB_SRC_SHOW_FAIL_N=<n> [E11_STUB_SRC_SHOW_FAIL_FROM=<k>, default 1]: n reads of the SOURCE bead, counting from the k-th,
    # do not answer (E11_STUB_SRC_SHOW_FAIL_MODE=rc: rc 1 and nothing; =error: rc 0 and bd's {"error": ...} object) — the
    # unreadable counter / read-back of ga-emc197. The live block reads the source bead 1st for the exemption (only on an
    # over-cap submission) and 2nd for the counter, then once per read-back: FROM=2 N=1 is "the counter cannot be read".
    show)     if [ "$dir" = "$SRC_STORE" ] && [ "${E11_STUB_SRC_SHOW_FAIL_N:-0}" -gt 0 ]; then
                local n=0; [ -f "$TMPD/src-show-n" ] && n=$(cat "$TMPD/src-show-n"); n=$((n+1)); echo "$n" > "$TMPD/src-show-n"
                if [ "$n" -ge "${E11_STUB_SRC_SHOW_FAIL_FROM:-1}" ] && [ "$n" -lt $(( ${E11_STUB_SRC_SHOW_FAIL_FROM:-1} + ${E11_STUB_SRC_SHOW_FAIL_N:-0} )) ]; then
                  if [ "${E11_STUB_SRC_SHOW_FAIL_MODE:-rc}" = "error" ]; then echo '{"error":"database is locked"}'; return 0; fi
                  return 1
                fi
              fi
              [ -n "$dir" ] && [ -f "$dir/show-$id.json" ] && cat "$dir/show-$id.json" || return 1 ;;
    comments) [ -n "$dir" ] && [ -f "$dir/comments-$id.json" ] && cat "$dir/comments-$id.json" || return 1 ;;
    # A tiny fake store, so the guard's READ-BACKS see what a real bd would show: `label add/remove` persist into
    # show-<id>.json (unless E11_STUB_LABELS_VANISH=1 — the silent-failure shape the guard must detect), `close`
    # flips status to closed (unless E11_STUB_CLOSE_FAILS=1 — rc 1 and nothing persists). A bead with no file:
    # the write "succeeds" and persists nothing.
    # E11_STUB_LABELS_VANISH: 1 = no store keeps a label write; marker / source = only that store drops them (the refusal
    # label on the MARKER vanishing is a different fact from the SOURCE bead's labels vanishing — ga-emc197).
    # E11_STUB_DROP="<op> <labels>[|<op> <labels>]": that exact write on the SOURCE bead persists nothing and returns
    # E11_STUB_DROP_RC (default 0 — the silent shape); E11_STUB_DROP_TIMES=n drops only the first n such writes (a retry lands).
    label)    op="${rest[1]:-}"; id="${rest[2]:-}"; labs="${rest[3]:-}"; f="$dir/show-$id.json"
      local drop=0 drop_rc=0
      case "${E11_STUB_LABELS_VANISH:-0}" in
        1) drop=1 ;;
        marker) [ "$dir" = "$MRK_STORE" ] && drop=1 ;;
        source) [ "$dir" = "$SRC_STORE" ] && drop=1 ;;
      esac
      case "|${E11_STUB_DROP:-}|" in
        *"|$op $labs|"*)
          local dn=0; [ -f "$TMPD/drop-n" ] && dn=$(cat "$TMPD/drop-n"); dn=$((dn+1)); echo "$dn" > "$TMPD/drop-n"
          if [ "$dn" -le "${E11_STUB_DROP_TIMES:-999}" ]; then drop=1; drop_rc="${E11_STUB_DROP_RC:-0}"; fi ;;
      esac
      [ "$drop_rc" != "0" ] && return "$drop_rc"
      if [ -n "$dir" ] && [ -f "$f" ] && [ "$drop" = "0" ]; then
        case "$op" in
          add)    jq -c --arg l "$labs" '.[0].labels = (((.[0].labels // []) + ($l|split(","))) | unique)' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
          remove) jq -c --arg l "$labs" '.[0].labels = ((.[0].labels // []) - ($l|split(",")))' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
        esac
      fi
      return 0 ;;
    close)    f="$dir/show-$id.json"
      [ "${E11_STUB_CLOSE_FAILS:-0}" = "1" ] && return 1
      if [ -n "$dir" ] && [ -f "$f" ]; then jq -c '.[0].status = "closed"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; fi
      return 0 ;;
    *) return 0 ;;
  esac
}
gc() { echo "GC $*" >> "$CALLS"; return 0; }
SRC_STORE="$TMPD/beadcity"; MRK_STORE="$TMPD/city"
mkdir -p "$SRC_STORE"

# two real bead ids, one per arm, found with the guard's own arm function
find_bead() { local want="$1" k id; k=0; while [ "$k" -lt 200 ]; do k=$((k+1)); id="ga-e11live$k"; [ "$(gate_e11_arm_for_bead "$id")" = "$want" ] && { echo "$id"; return 0; }; done; return 1; }
BB="$(find_bead B)"; AA="$(find_bead A)"
[ -n "$BB" ] && [ -n "$AA" ] && ok "found a bead per arm: B=$BB A=$AA" || { bad "could not find a bead per arm (arm function missing?)"; echo "  PASS=$PASS  FAIL=$FAIL"; echo "  RESULT: FAIL"; exit 1; }

set_beads() { # <source-bead> <source labels json> <marker labels json>
  printf '[{"id":"%s","labels":%s}]' "$1" "$2" > "$SRC_STORE/show-$1.json"
  printf '[{"id":"m-e11","labels":%s}]' "$3" > "$MRK_STORE/show-m-e11.json"
  rm -f "$SRC_STORE/comments-$1.json" "$MRK_STORE/comments-m-e11.json"
}
PLAIN='["story:approved"]'; EXEMPT='["story:approved","gate:size-exempt"]'

# run_e11 <on 1|0> <RIG_PATH> <BEAD_ID> <BRANCH>  → rc; log/calls in $LOGF/$CALLS. Subshell under the guard's real
# `set -euo pipefail`; `exit 1` in a refusal ends only the subshell.
run_e11() {
  : > "$LOGF"; : > "$CALLS"; rm -f "$TMPD/src-show-n" "$TMPD/drop-n"
  ( set -euo pipefail
    export GATE_E11_ENABLED="$1"
    RIG_PATH="$2"; BEAD_ID="$3"; BRANCH="$4"; MARKER_ID="m-e11"; GC_CITY="$MRK_STORE"; BEAD_CITY="$SRC_STORE"
    . "$E11_FILE" ) >/dev/null 2>&1
  return $?
}
calls_n() { wc -c < "$CALLS" | tr -d ' '; }

# Everything from here to "the TOTAL cap" exercises the PRODUCTION cap in isolation (ga-lzidpo). Some of its fixtures carry
# thousands of test/doc lines on purpose — that is what "tests do not count" is about — and the total cap (ga-mzyghi)
# would refuse them. It is lifted here; the TOTAL-cap section unsets this and runs on the real default.
export GATE_E11_TOTAL_CAP=999999999

echo "  — flag OFF: byte-for-byte today —"
set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 0 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "flag off, arm B, 900 prod lines: accepted (rc 0)" "$RC" "0"
eq "flag off: not one line logged" "$(wc -c < "$LOGF" | tr -d ' ')" "0"
eq "flag off: no label, no comment, no bd call" "$(calls_n)" "0"

echo "  — arm A (control) —"
run_e11 1 "$RIG_OK" "$AA" feat/prod900; RC=$?
eq "arm A, 900 prod lines: accepted (rc 0)" "$RC" "0"
has "arm A: the arm is recorded" "$LOGF" "LOG E11-DIFF-CAP bead=$AA arm=A verdict=controle"
eq "arm A: nothing touched — no bd call, no label, no comment" "$(calls_n)" "0"

echo "  — 100% switch: an arm-A bead is treated as B (Athos 07/10) —"
set_beads "$AA" "$PLAIN" "$PLAIN"   # the forced bead is now READ for an exemption, like any arm-B bead
mkdir -p "$MRK_STORE/.gc"; touch "$MRK_STORE/.gc/gate-e11-diff-cap.all"
run_e11 1 "$RIG_OK" "$AA" feat/prod900; RC=$?
eq "100%: arm A, 900 prod lines: REFUSED (rc 1)" "$RC" "1"
has "100%: the record says arm=B verdict=recusa" "$LOGF" "bead=$AA arm=B verdict=recusa production_lines=900"
has "100%: the record says forced=1 (the hash arm was A)" "$LOGF" "forced=1"
has "100%: the marker gets the guard-refusal label the recovery watchdog reads" "$CALLS" "label add m-e11 gate-guard:refused-e11"
rm -f "$MRK_STORE/.gc/gate-e11-diff-cap.all"
run_e11 1 "$RIG_OK" "$AA" feat/prod900; RC=$?
eq "100% off again: arm A back to controle (rc 0)" "$RC" "0"
has "100% off: record says forced=0" "$LOGF" "forced=0"

echo "  — arm B, treated —"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "arm B, 900 prod lines (+100 test): REFUSED (rc 1)" "$RC" "1"
echo "  — refusal: what reaches the source bead, the author and the marker (audit of 72dc10768, finding 1) —"
has "refusal: the marker's refusal label is written" "$CALLS" "label add m-e11 gate-guard:refused-e11"
hasnt "refusal: ...and READ BACK as persisted (no 'NOT persisted' warning)" "$LOGF" "NOT persisted"
has "refusal: source bead loses gate:queued (nothing is queued)" "$CALLS" "BD -C $SRC_STORE label remove $BB gate:queued"
has "refusal: source bead gets gate:needs-fix + refusal counter 1" "$CALLS" "BD -C $SRC_STORE label add $BB gate:needs-fix,gate:e11-refusals:1"
has "refusal: the reason lands on the SOURCE bead as a VERDICT: FAIL comment (what a fix sling carries)" "$CALLS" "BD -C $SRC_STORE comment $BB VERDICT: FAIL (gate guard, diff-size cap E11 — refusal 1 of 3"
has "refusal: the reason says what to do (split)" "$CALLS" "O QUE FAZER: dividir em fatias"
# ga-2xdj1x: the slices must be born with the type of the source bead (bd create --parent with no -t makes a task). This fake
# source bead carries no issue_type: bd answered, but not with the type -> the PLACEHOLDER, never a guessed -t.
has "refusal: the reason tells how to create the slices (child of the bead, with -t)" "$CALLS" "bd create '<titulo da fatia>' --parent $BB -t "
has "refusal: source type not in the answer -> placeholder, not a guess" "$CALLS" "--parent $BB -t <tipo de $BB>."
has "refusal: marker closed" "$CALLS" "BD -C $MRK_STORE close m-e11"
has "refusal: ...VERIFIED, and the status is failed (not error)" "$LOGF" "CLOSED (verified, gate-status:failed)"
has "refusal: status set to failed" "$CALLS" "STATUS m-e11 failed"
hasnt "refusal: no gate-status:error on a verified close" "$CALLS" "STATUS m-e11 error"
hasnt "refusal: feat/ branch names no crew → no author mail attempted" "$CALLS" "GC --city $MRK_STORE mail send"
hasnt "refusal: 1st refusal → no needs-human, no mayor mail" "$CALLS" "gate:needs-human"
eq "refusal: the source bead REALLY carries gate:needs-fix afterwards (fake store)" "$(jq -r '.[0].labels|index("gate:needs-fix") != null' "$SRC_STORE/show-$BB.json")" "true"
eq "refusal: ...and no gate:queued" "$(jq -r '.[0].labels|index("gate:queued")' "$SRC_STORE/show-$BB.json")" "null"

echo "  — refusal of a crew branch: the author is mailed —"
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
# the guard counts origin/<branch>: publish the same 900-line tip under a crew-shaped name in the fake origin
git -C "$RIG_OK" push -q origin origin/feat/prod900:refs/heads/crew/oracle/wa-abc123 >/dev/null 2>&1 && git -C "$RIG_OK" fetch -q origin >/dev/null 2>&1 || echo "  (could not publish the crew branch in the fake origin)"
run_e11 1 "$RIG_OK" "$BB" crew/oracle/wa-abc123; RC=$?
eq "crew branch refused (rc 1)" "$RC" "1"
has "crew branch: author mail to the crew name from the branch" "$CALLS" "GC --city $MRK_STORE mail send oracle -s Gate recusou $BB na submissao: 900 linhas de producao > teto 800 (E11)"
eq "crew branch: one mail, the first candidate succeeded" "$(grep -c 'GC --city .* mail send oracle' "$CALLS")" "1"

echo "  — 3rd refusal of the same bead: bounded end state (needs-human + mayor) —"
set_beads "$BB" '["story:approved","gate:e11-refusals:2"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "3rd refusal still refuses (rc 1)" "$RC" "1"
has "3rd: counter 3" "$CALLS" "label add $BB gate:needs-fix,gate:e11-refusals:3"
has "3rd: gate:needs-human added" "$CALLS" "BD -C $SRC_STORE label add $BB gate:needs-human"
has "3rd: gate:needs-fix removed again (the Pilot must not redispatch)" "$CALLS" "BD -C $SRC_STORE label remove $BB gate:needs-fix"
has "3rd: the mayor is mailed" "$CALLS" "GC --city $MRK_STORE mail send mayor -s Gate E11: $BB recusado 3x por tamanho"
has "3rd: the comment says 'refusal 3 of 3'" "$CALLS" "refusal 3 of 3"
has "3rd: the mail to the mayor carries the slicing command with -t (ga-2xdj1x)" "$CALLS" "bd create '<titulo>' --parent $BB -t "
has "3rd: the mail to the mayor also says the slice is VERTICAL, one end-to-end behavior and not a layer (ga-x8mmt7)" "$CALLS" "e fatia VERTICAL: um comportamento testavel de ponta a ponta, nao uma camada so de schema/API/infra"

echo "  — ga-2xdj1x: the slices are born with the type of the source bead (a slice of a feature is a feature) —"
# <issue_type the fake bd shows> <the -t the reason must carry>. Controls: a task stays task, a bug stays bug (the hint
# never turns a slice into a feature on its own); an epic's slices are features (refino split convention); a type this
# list does not know (spike) or an empty one is NOT guessed: the placeholder.
slice_type_case() {
  printf '[{"id":"%s","labels":%s,"issue_type":"%s"}]' "$BB" "$PLAIN" "$1" > "$SRC_STORE/show-$BB.json"
  printf '[{"id":"m-e11","labels":%s}]' "$PLAIN" > "$MRK_STORE/show-m-e11.json"
  rm -f "$SRC_STORE/comments-$BB.json" "$MRK_STORE/comments-m-e11.json"
  run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
  eq "slice type [$1]: refused (rc 1)" "$RC" "1"
  has "slice type [$1]: the reason says -t $2" "$CALLS" "bd create '<titulo da fatia>' --parent $BB -t $2."
  has "slice type [$1]: the reason says to slice VERTICALLY, not by layer (ga-x8mmt7)" "$CALLS" "Fatie na VERTICAL: cada fatia entrega um comportamento visivel e testavel de ponta a ponta, nao uma camada (so schema, so API ou so infra)"
}
slice_type_case feature feature
slice_type_case task task
slice_type_case bug bug
slice_type_case chore chore
slice_type_case epic feature
slice_type_case spike "<tipo de $BB>"
slice_type_case "" "<tipo de $BB>"

echo "  — refusal label write that does not persist: said, and the close still ends it —"
set_beads "$BB" "$PLAIN" "$PLAIN"
# only the MARKER store drops its label writes: this section is about the marker's refusal label. With every store dropping,
# the source bead's labels vanish too and the old guard still logged "-> gate:needs-fix" and closed (the ga-emc197 defect).
E11_STUB_LABELS_VANISH=marker run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label vanish: still refused (rc 1)" "$RC" "1"
eq "label vanish: label add was RETRIED (2 attempts)" "$(grep -c 'label add m-e11 gate-guard:refused-e11' "$CALLS")" "2"
has "label vanish: the warning names it" "$LOGF" "WARN E11-DIFF-CAP: refusal label gate-guard:refused-e11 NOT persisted on m-e11 after 2 attempts"
has "label vanish: the marker is still closed (verified) — the close is the primary mechanism" "$LOGF" "CLOSED (verified, gate-status:failed); source $BB -> gate:needs-fix (refusal 1/3); refusal label persisted=0"

echo "  — close that fails: gate-status:error, said, the watchdog backstop named —"
set_beads "$BB" "$PLAIN" "$PLAIN"
E11_STUB_CLOSE_FAILS=1 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "close fails: still refused (rc 1)" "$RC" "1"
has "close fails: status error (not failed)" "$CALLS" "STATUS m-e11 error"
hasnt "close fails: never claims a verified close" "$LOGF" "CLOSED (verified"
has "close fails: the warning names the backstop and the label state" "$LOGF" "WARN E11-DIFF-CAP refused: marker m-e11 close NOT verified — left in gate-status:error; gate-recovery-watchdog closes it (close:guard-refused)"
has "close fails: label persisted=1 in that record" "$LOGF" "(persisted=1)"
set_beads "$BB" "$PLAIN" "$PLAIN"
has "refusal: the record is written BEFORE the exit, with the production count (tests not counted)" "$LOGF" "LOG E11-DIFF-CAP bead=$BB arm=B verdict=recusa production_lines=900 cap=800"
has "refusal: gate-status:error on the marker" "$CALLS" "STATUS m-e11 error"
has "refusal: a comment goes on the marker" "$CALLS" "BD -C $TMPD/city comment m-e11"
has "refusal: the comment tells the builder to split into slices" "$CALLS" "fatias"
has "refusal: the comment names the exemption label" "$CALLS" "gate:size-exempt"
has "refusal: the comment gives the count and the cap" "$CALLS" "900"

echo "  — ga-emc197: the source bead's labels are WRITTEN, READ BACK, and only then is anything claimed or closed —"
# The audit of 00634ad5a: the refusal removed gate:queued BEFORE adding gate:needs-fix, both with `|| true` and no read-back.
# If the add did not land (bd's batch is all-or-nothing), the bead had NO gate:* label — nothing watches that — the marker
# was closed anyway and the log said "-> gate:needs-fix". Each case below must FAIL on the guard as it was at 00634ad5a.
stub_reset() { unset E11_STUB_DROP E11_STUB_DROP_RC E11_STUB_DROP_TIMES E11_STUB_SRC_SHOW_FAIL_N E11_STUB_SRC_SHOW_FAIL_FROM E11_STUB_SRC_SHOW_FAIL_MODE E11_STUB_LABELS_VANISH; rm -f "$TMPD/src-show-n" "$TMPD/drop-n"; }
src_has() { jq -r --arg l "$1" '.[0].labels|index($l) != null' "$SRC_STORE/show-$BB.json" 2>/dev/null; }
calls_count() { grep -cF -- "$1" "$CALLS"; }

echo "  · write_verified, on the fake store —"
stub_reset; : > "$CALLS"
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
eq "write_verified: an add that lands → yes" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-fix)" "yes"
eq "write_verified: ...and the label is really there" "$(src_has gate:needs-fix)" "true"
eq "write_verified: a remove that lands → yes" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" remove gate:queued)" "yes"
eq "write_verified: ...and the label is really gone" "$(src_has gate:queued)" "false"
eq "write_verified: removing a label the bead never had → yes (it is not there)" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" remove gate:needs-human)" "yes"
eq "write_verified: a batch of two labels lands → yes" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-human,gate:e11-refusals:3)" "yes"
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"; : > "$CALLS"
export E11_STUB_DROP="add gate:needs-fix"
eq "write_verified: an add that returns 0 and persists NOTHING → no" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-fix)" "no"
eq "write_verified: ...it tried twice, not once" "$(calls_count "label add $BB gate:needs-fix")" "2"
stub_reset; : > "$CALLS"; export E11_STUB_DROP="add gate:needs-fix" E11_STUB_DROP_RC=1
eq "write_verified: an add that FAILS (rc 1) → no" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-fix)" "no"
stub_reset; : > "$CALLS"; export E11_STUB_DROP="add gate:needs-fix" E11_STUB_DROP_TIMES=1
eq "write_verified: the first attempt dropped, the retry lands → yes" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-fix)" "yes"
eq "write_verified: ...after exactly two writes" "$(calls_count "label add $BB gate:needs-fix")" "2"
stub_reset; : > "$CALLS"; export E11_STUB_SRC_SHOW_FAIL_N=99
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
eq "write_verified: the read-back itself fails → desconhecido, NOT yes" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-fix)" "desconhecido"
eq "write_verified: a failed read-back is not proof of absence either (remove) → desconhecido" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" remove gate:queued)" "desconhecido"
stub_reset; : > "$CALLS"; export E11_STUB_SRC_SHOW_FAIL_N=99 E11_STUB_SRC_SHOW_FAIL_MODE=error
eq "write_verified: bd answers {error} on the read-back → desconhecido" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add gate:needs-fix)" "desconhecido"
stub_reset; : > "$CALLS"
eq "write_verified: a bead the store does not have → desconhecido" "$(gate_e11_label_write_verified "$SRC_STORE" "no-such-bead" add gate:needs-fix)" "desconhecido"
: > "$CALLS"
eq "write_verified: an op nobody defined → desconhecido, and nothing was written" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" toggle gate:needs-fix)|$(calls_n)" "desconhecido|0"
eq "write_verified: no label named → desconhecido, and nothing was written" "$(gate_e11_label_write_verified "$SRC_STORE" "$BB" add "")|$(calls_n)" "desconhecido|0"

echo "  · refusal 1: the add to the source bead does not land —"
# Both shapes of the failure: bd returns 0 and persists nothing (ga-ehbw5, ga-kgtiw), and bd fails outright.
src_add_fails_case() { # <rc the failed write returns> <branch>
  local rc="$1" br="${2:-feat/prod900}"
  stub_reset
  set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
  E11_STUB_DROP="add gate:needs-fix,gate:e11-refusals:1" E11_STUB_DROP_RC="$rc" run_e11 1 "$RIG_OK" "$BB" "$br"; RC=$?
  eq "add fails [rc $rc]: still refused (rc 1), and the block ran to its end (no unbound variable)" "$RC|$(grep -cF 'SUPPRESSED PUSH (wa-uthi non-terminal): diff-size cap (E11) refused m-e11.' "$LOGF")" "1|1"
  eq "add fails [rc $rc]: the source bead KEEPS gate:queued (it is the state a watchdog can see)" "$(src_has gate:queued)" "true"
  eq "add fails [rc $rc]: ...and did not get gate:needs-fix" "$(src_has gate:needs-fix)" "false"
  hasnt "add fails [rc $rc]: gate:queued is never removed before the add is confirmed" "$CALLS" "label remove $BB gate:queued"
  eq "add fails [rc $rc]: the add was retried once, not hammered" "$(calls_count "label add $BB gate:needs-fix,gate:e11-refusals:1")" "2"
  hasnt "add fails [rc $rc]: the marker is NOT closed" "$CALLS" "BD -C $MRK_STORE close m-e11"
  has "add fails [rc $rc]: gate-status:error is left for the recovery watchdog" "$CALLS" "STATUS m-e11 error"
  hasnt "add fails [rc $rc]: never gate-status:failed" "$CALLS" "STATUS m-e11 failed"
  hasnt "add fails [rc $rc]: the log never says '-> gate:needs-fix'" "$LOGF" "-> gate:needs-fix"
  hasnt "add fails [rc $rc]: the log never says CLOSED (verified" "$LOGF" "CLOSED (verified"
  has "add fails [rc $rc]: the warning says the writes were NOT confirmed and the marker NOT closed" "$LOGF" "WARN E11-DIFF-CAP refused: the label writes on source $BB were NOT confirmed — gate:needs-fix was not confirmed on the source bead after the add"
  has "add fails [rc $rc]: ...and names what the watchdog will do" "$LOGF" "gate-recovery-watchdog closes it (close:guard-refused) after its error grace if the refusal label stuck (persisted=1), else it requeues it"
  has "add fails [rc $rc]: the marker comment says it was not closed" "$CALLS" "BD -C $MRK_STORE comment m-e11 Gate guard rejected marker: diff-size cap (ga-lzidpo / E11)."
  has "add fails [rc $rc]: ...in words" "$CALLS" "Marker NOT closed: the guard could not confirm its label writes on the source bead $BB"
  hasnt "add fails [rc $rc]: no VERDICT: FAIL comment on a bead nobody confirmed (the builder is not sent away)" "$CALLS" "BD -C $SRC_STORE comment $BB"
  hasnt "add fails [rc $rc]: no mail to anyone" "$CALLS" "mail send"
}
src_add_fails_case 0
src_add_fails_case 1
src_add_fails_case 0 crew/oracle/wa-abc123
hasnt "add fails on a crew branch: the author is NOT mailed a reason about labels nobody saw land" "$CALLS" "mail send oracle"
stub_reset

echo "  · refusal 1: gate:needs-fix landed, the removal of gate:queued is not confirmed —"
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
E11_STUB_DROP="remove gate:queued" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "queued stays: still refused (rc 1)" "$RC" "1"
eq "queued stays: gate:needs-fix IS on the bead (the add was read back)" "$(src_has gate:needs-fix)" "true"
eq "queued stays: ...and so is gate:queued, which the guard knows" "$(src_has gate:queued)" "true"
hasnt "queued stays: the marker is NOT closed" "$CALLS" "BD -C $MRK_STORE close m-e11"
has "queued stays: gate-status:error" "$CALLS" "STATUS m-e11 error"
hasnt "queued stays: the log never says '-> gate:needs-fix'" "$LOGF" "-> gate:needs-fix"
has "queued stays: the warning names the removal that was not confirmed" "$LOGF" "gate:needs-fix is on the source bead, but the removal of gate:queued was not confirmed (read-back: no)"
hasnt "queued stays: no VERDICT: FAIL comment promising 'sem gate:queued'" "$CALLS" "sem gate:queued"

echo "  · refusal 1: the source bead cannot be READ after the exemption was (bd goes down mid-run) —"
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
E11_STUB_SRC_SHOW_FAIL_FROM=2 E11_STUB_SRC_SHOW_FAIL_N=99 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "bd down: still refused (rc 1) — the exemption was read before bd went down" "$RC" "1"
hasnt "bd down: gate:queued is not removed on an unconfirmed add" "$CALLS" "label remove $BB gate:queued"
hasnt "bd down: the marker is NOT closed" "$CALLS" "BD -C $MRK_STORE close m-e11"
has "bd down: gate-status:error" "$CALLS" "STATUS m-e11 error"
hasnt "bd down: the log never says '-> gate:needs-fix'" "$LOGF" "-> gate:needs-fix"
has "bd down: the count was unreadable, said, and NOT restarted at 1" "$LOGF" "WARN E11-DIFF-CAP: could not read the refusal count of $BB"
has "bd down: the warning gives the read-back state" "$LOGF" "(read-back: desconhecido)"
hasnt "bd down: no counter label written on a count nobody read" "$CALLS" "gate:e11-refusals:"

echo "  · refusal with an unreadable COUNTER (the read-backs answer): not '1 of 3' again —"
unread_count_case() { # <mode rc|error> <labels json>
  stub_reset
  set_beads "$BB" "$2" "$PLAIN"
  E11_STUB_SRC_SHOW_FAIL_FROM=2 E11_STUB_SRC_SHOW_FAIL_N=1 E11_STUB_SRC_SHOW_FAIL_MODE="$1" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
  eq "unreadable count [$1]: still refused (rc 1)" "$RC" "1"
  has "unreadable count [$1]: said, in a warning, that it is NOT restarting at 1" "$LOGF" "WARN E11-DIFF-CAP: could not read the refusal count of $BB (bd show answered nothing usable) — NOT restarting at 1"
  eq "unreadable count [$1]: no counter label is written (not 'gate:e11-refusals:1')" "$(calls_count "gate:e11-refusals:")" "0"
  has "unreadable count [$1]: gate:needs-fix still goes on (the refusal is real)" "$CALLS" "BD -C $SRC_STORE label add $BB gate:needs-fix"
  has "unreadable count [$1]: ...and gate:queued off, once that was read back" "$CALLS" "BD -C $SRC_STORE label remove $BB gate:queued"
  has "unreadable count [$1]: the comment says 'refusal ? of 3', not 'refusal 1 of 3'" "$CALLS" "refusal ? of 3 for this bead"
  hasnt "unreadable count [$1]: ...never 'refusal 1 of 3'" "$CALLS" "refusal 1 of 3"
  has "unreadable count [$1]: the comment says the count could not be read" "$CALLS" "A contagem de recusas deste bead nao pode ser lida desta vez"
  hasnt "unreadable count [$1]: no escalation decided on a number nobody read" "$CALLS" "gate:needs-human"
  hasnt "unreadable count [$1]: ...no mail to the mayor" "$CALLS" "mail send mayor"
  has "unreadable count [$1]: the log says '?'" "$LOGF" "(refusal ?/3)"
}
unread_count_case rc '["story:approved","gate:queued","gate:e11-refusals:2"]'
unread_count_case error '["story:approved","gate:queued"]'
stub_reset

echo "  · refusal 1: the first write is dropped, the retry lands (a hiccup is not a failure) —"
set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
E11_STUB_DROP="add gate:needs-fix,gate:e11-refusals:1" E11_STUB_DROP_TIMES=1 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "retry lands: refused (rc 1)" "$RC" "1"
eq "retry lands: the add was written twice" "$(calls_count "label add $BB gate:needs-fix,gate:e11-refusals:1")" "2"
eq "retry lands: gate:needs-fix is on the bead, gate:queued is not" "$(src_has gate:needs-fix)|$(src_has gate:queued)" "true|false"
has "retry lands: the marker IS closed, verified" "$LOGF" "CLOSED (verified, gate-status:failed); source $BB -> gate:needs-fix (refusal 1/3); refusal label persisted=1"
hasnt "retry lands: nothing to warn about" "$LOGF" "NOT confirmed"
stub_reset

echo "  · 3rd refusal: gate:needs-human is read back BEFORE gate:needs-fix goes, and the mayor is told the truth —"
set_beads "$BB" '["story:approved","gate:queued","gate:e11-refusals:2"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "3rd, all lands: refused (rc 1)" "$RC" "1"
eq "3rd, all lands: needs-human yes, needs-fix no, queued no" "$(src_has gate:needs-human)|$(src_has gate:needs-fix)|$(src_has gate:queued)" "true|false|false"
has "3rd, all lands: the log names where the bead ENDED (gate:needs-human), not where it passed" "$LOGF" "CLOSED (verified, gate-status:failed); source $BB -> gate:needs-human (refusal 3/3)"
hasnt "3rd, all lands: the log never says '-> gate:needs-fix'" "$LOGF" "-> gate:needs-fix"
has "3rd, all lands: the mail says it is parked, byte for byte" "$CALLS" "Ficou com gate:needs-human (gate:needs-fix removido); o Pilot nao redespacha. Decida: fatiar voce mesmo"
has "3rd, all lands: the comment on the bead says so too" "$CALLS" "Esta foi a 3a recusa: Ficou com gate:needs-human (gate:needs-fix removido); o Pilot nao redespacha."
hasnt "3rd, all lands: the comment no longer promises 'o Pilot despacha o conserto' about a bead going to a human" "$CALLS" "o Pilot despacha o conserto"

set_beads "$BB" '["story:approved","gate:queued","gate:e11-refusals:2"]' "$PLAIN"
E11_STUB_DROP="add gate:needs-human" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "3rd, needs-human NOT confirmed: refused (rc 1)" "$RC" "1"
eq "3rd, needs-human NOT confirmed: gate:needs-fix is KEPT (removing it would leave no gate:* label)" "$(src_has gate:needs-fix)|$(src_has gate:needs-human)" "true|false"
hasnt "3rd, needs-human NOT confirmed: gate:needs-fix is never removed" "$CALLS" "label remove $BB gate:needs-fix"
has "3rd, needs-human NOT confirmed: the mayor is still mailed (somebody must hear it)" "$CALLS" "GC --city $MRK_STORE mail send mayor -s Gate E11: $BB recusado 3x por tamanho"
has "3rd, needs-human NOT confirmed: ...and the mail says it could NOT confirm" "$CALLS" "ATENCAO: nao consegui CONFIRMAR gate:needs-human no bead (releitura: no): ele segue com gate:needs-fix e o Pilot PODE redespachar"
hasnt "3rd, needs-human NOT confirmed: ...and never claims 'Ficou com gate:needs-human'" "$CALLS" "Ficou com gate:needs-human"
has "3rd, needs-human NOT confirmed: the comment on the bead says the escalation is pending" "$CALLS" "gate:needs-human NAO foi confirmado"
has "3rd, needs-human NOT confirmed: a warning" "$LOGF" "WARN E11-DIFF-CAP: 3rd refusal of $BB but gate:needs-human was NOT confirmed (read-back: no)"
has "3rd, needs-human NOT confirmed: the log says where the bead really is" "$LOGF" "source $BB -> gate:needs-fix (refusal 3/3)"
hasnt "3rd, needs-human NOT confirmed: ...never gate:needs-human" "$LOGF" "-> gate:needs-human"

set_beads "$BB" '["story:approved","gate:queued","gate:e11-refusals:2"]' "$PLAIN"
E11_STUB_DROP="add gate:needs-human" E11_STUB_DROP_RC=1 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "3rd, needs-human add FAILS (rc 1): same end state, gate:needs-fix kept" "$RC|$(src_has gate:needs-fix)|$(src_has gate:needs-human)" "1|true|false"
has "3rd, needs-human add FAILS: the mayor is told it was not confirmed" "$CALLS" "ATENCAO: nao consegui CONFIRMAR gate:needs-human"

set_beads "$BB" '["story:approved","gate:queued","gate:e11-refusals:2"]' "$PLAIN"
E11_STUB_DROP="remove gate:needs-fix" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "3rd, needs-human landed but needs-fix stays: refused (rc 1)" "$RC" "1"
eq "3rd, ...the bead carries both, and the guard knows" "$(src_has gate:needs-human)|$(src_has gate:needs-fix)" "true|true"
has "3rd, ...the log says gate:needs-human (it IS there)" "$LOGF" "source $BB -> gate:needs-human (refusal 3/3)"
has "3rd, ...a warning about the removal that was not confirmed" "$LOGF" "WARN E11-DIFF-CAP: gate:needs-human is on $BB but the removal of gate:needs-fix was not confirmed (read-back: no)"
has "3rd, ...the mail to the mayor says both labels may be there" "$CALLS" "a remocao de gate:needs-fix NAO foi confirmada (releitura: no): o bead pode carregar os dois labels."

set_beads "$BB" '["story:approved","gate:queued","gate:e11-refusals:2"]' "$PLAIN"
E11_STUB_DROP="add gate:needs-fix,gate:e11-refusals:3" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "3rd, the first add (needs-fix + counter 3) not confirmed: nothing escalated, nothing removed" "$RC|$(src_has gate:queued)|$(src_has gate:needs-human)" "1|true|false"
hasnt "3rd, ...no mail to the mayor claiming anything" "$CALLS" "mail send mayor"
hasnt "3rd, ...the marker is not closed" "$CALLS" "BD -C $MRK_STORE close m-e11"
stub_reset
set_beads "$BB" "$PLAIN" "$PLAIN"   # later sections start from a plain source bead again

run_e11 1 "$RIG_OK" "$BB" feat/prod800; RC=$?
eq "arm B, exactly 800 prod lines: accepted (the cap is 'over 800')" "$RC" "0"
has "exactly the cap: dentro-do-teto, count 800" "$LOGF" "verdict=dentro-do-teto production_lines=800"
run_e11 1 "$RIG_OK" "$BB" feat/prod801; RC=$?
eq "arm B, 801 prod lines: REFUSED" "$RC" "1"

run_e11 1 "$RIG_OK" "$BB" feat/nonprod; RC=$?
eq "arm B, 6000 lines of tests/fixtures/lockfile/docs/selftest/generated + 50 prod: ACCEPTED" "$RC" "0"
has "non-production does not count: production_lines=50" "$LOGF" "verdict=dentro-do-teto production_lines=50"
eq "accepted: no label, no comment" "$(calls_n)" "0"

run_e11 1 "$RIG_OK" "$BB" feat/rewrite; RC=$?
eq "arm B, rewrite of a 500-line file (500 added + 500 deleted): REFUSED" "$RC" "1"
has "added + deleted: production_lines=1000" "$LOGF" "production_lines=1000"

run_e11 1 "$RIG_OK" "$BB" feat/binary; RC=$?
eq "arm B, a binary + 10 lines: accepted" "$RC" "0"
has "the binary row does not count: production_lines=10" "$LOGF" "production_lines=10"

run_e11 1 "$RIG_OK" "$BB" feat/pytest; RC=$?
eq "arm B, 40 prod lines + a 910-line .selftest.py + a selftest-*.lib.sh: ACCEPTED (the repo's own test names)" "$RC" "0"
has "Python selftest and selftest lib do not count: production_lines=40" "$LOGF" "verdict=dentro-do-teto production_lines=40"

echo "  — the third state: could not measure => accept + say so —"
# Blocking issue 1 (gate round 1): the fetch's outcome used to be thrown away, so a failed fetch left origin/main
# STALE and the block counted everything main gained since as part of the branch.
[ "$STALE_MAIN_BEFORE" != "$REAL_MAIN2" ] && [ -n "$STALE_MAIN_BEFORE" ] \
  && ok "fixture: the rig's origin/main (${STALE_MAIN_BEFORE:0:8}) really is behind origin's main (${REAL_MAIN2:0:8})" \
  || bad "fixture: the stale rig is not stale (rig=${STALE_MAIN_BEFORE:-?} origin=${REAL_MAIN2:-?})"
run_e11 1 "$RIG_STALE" "$BB" feat/small; RC=$?
eq "origin unreachable, origin/main stale (10-line branch, 1010 lines vs the stale main): ACCEPTED (rc 0)" "$RC" "0"
has "stale main: nao-medido, the count never arrived" "$LOGF" "verdict=nao-medido production_lines=unknown"
has "stale main: the cause is NAMED, not why=-" "$LOGF" "why=fetch-falhou"
lacks "stale main: no 1010 reaches the log as if it were a measurement" "$LOGF" "production_lines=1010"
eq "stale main: nothing refused or labelled" "$(calls_n)" "0"
# the control: same rig, origin back — the fetch works, origin/main moves to M2 and the REAL size (10) comes out
$GITC -C "$RIG_STALE" remote set-url origin "$ORIGIN2"
run_e11 1 "$RIG_STALE" "$BB" feat/small; RC=$?
eq "origin reachable again: fetch moves origin/main, 10-line branch accepted" "$RC" "0"
has "origin reachable: the REAL size is measured (10), not 1010" "$LOGF" "verdict=dentro-do-teto production_lines=10"
lacks "origin reachable: no why= cause recorded" "$LOGF" "why=fetch-falhou"
run_e11 1 "" "$BB" feat/prod900; RC=$?
eq "RIG_PATH empty: accepted (rc 0)" "$RC" "0"
has "RIG_PATH empty: logged as nao-medido with the cause" "$LOGF" "verdict=nao-medido production_lines=unknown"
has "RIG_PATH empty: the cause is NAMED" "$LOGF" "why=entrada-vazia"
eq "RIG_PATH empty: nothing refused or labelled" "$(calls_n)" "0"
run_e11 1 "$NOT_A_REPO" "$BB" feat/prod900; RC=$?
eq "git cannot answer (not a repo): accepted (rc 0)" "$RC" "0"
has "not a repo: nao-medido, count never arrived" "$LOGF" "verdict=nao-medido production_lines=unknown"
eq "not a repo: nothing refused or labelled" "$(calls_n)" "0"
run_e11 1 "$RIG_OK" "$BB" feat/ghost; RC=$?
eq "branch missing on origin: accepted (rc 0)" "$RC" "0"
has "branch missing: nao-medido" "$LOGF" "verdict=nao-medido production_lines=unknown"
run_e11 1 "$RIG_OK" "" feat/prod900; RC=$?
eq "BEAD_ID empty: accepted (rc 0), no arm so no refusal" "$RC" "0"
has "BEAD_ID empty: named <EMPTY>, verdict sem-braco" "$LOGF" "bead=<EMPTY> arm=? verdict=sem-braco"
run_e11 1 "$RIG_OK" "$BB" ""; RC=$?
eq "BRANCH empty: accepted (rc 0)" "$RC" "0"
has "BRANCH empty: nao-medido" "$LOGF" "verdict=nao-medido production_lines=unknown"

echo "  — the exemption —"
set_beads "$BB" "$EXEMPT" "$PLAIN"
printf '%s' "$RSN_OK" > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label on the bead + a reason: accepted (rc 0)" "$RC" "0"
has "exempt: logged as isento, with the count" "$LOGF" "verdict=isento production_lines=900"
lacks "exempt: no refusal comment" "$CALLS" "STATUS m-e11 error"

set_beads "$BB" "$EXEMPT" "$PLAIN"
printf '%s' "$RSN_SHORT" > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label with a token reason: still REFUSED" "$RC" "1"
has "label without a real reason: recorded as label-sem-motivo" "$LOGF" "exempt=label-sem-motivo"

set_beads "$BB" "$EXEMPT" "$PLAIN"
printf '[]' > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label and NO comment at all: still REFUSED" "$RC" "1"

set_beads "$BB" "$PLAIN" "$EXEMPT"
printf '%s' "$RSN_OK" > "$MRK_STORE/comments-m-e11.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label + reason on the MARKER bead instead: accepted" "$RC" "0"

set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "neither bead carries the label: REFUSED" "$RC" "1"
has "refusal records exempt=nao" "$LOGF" "exempt=nao"

echo "  — an exemption that cannot be read is not 'no exemption' —"
set_beads "$BB" "$PLAIN" "$PLAIN"; rm -f "$SRC_STORE/show-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "source bead unreadable (bd show fails): accepted, not refused" "$RC" "0"
has "bd show failing: verdict nao-medido-isencao" "$LOGF" "verdict=nao-medido-isencao production_lines=900"
has "bd show failing: the cause is NAMED (why=isencao-ilegivel), not why=-" "$LOGF" "why=isencao-ilegivel"
lacks "bd show failing: no gate-status:error" "$CALLS" "STATUS m-e11 error"

set_beads "$BB" "$EXEMPT" "$PLAIN"      # label present but its comments cannot be read (no comments file => bd fails)
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label present, comments unreadable: accepted, not refused" "$RC" "0"
has "comments unreadable: nao-medido-isencao" "$LOGF" "verdict=nao-medido-isencao"
has "comments unreadable: the cause is NAMED (why=isencao-ilegivel)" "$LOGF" "why=isencao-ilegivel"

set_beads "$BB" "$EXEMPT" "$PLAIN"      # label present, but the comment has no .text key (bd schema drift)
printf '[{"id":"c1","body":"gate:size-exempt: renome mecanico de 40 arquivos para o novo prefixo"}]' > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "label present, comment with no .text (schema drift): accepted, NOT refused as 'no reason' (round 2 low)" "$RC" "0"
has "no .text: nao-medido-isencao, the exemption could not be read" "$LOGF" "verdict=nao-medido-isencao production_lines=900"
has "no .text: the cause is NAMED" "$LOGF" "why=isencao-ilegivel"

echo "  — the two stores: the source bead from BEAD_CITY, the marker from GC_CITY —"
set_beads "$BB" "$EXEMPT" "$PLAIN"
printf '%s' "$RSN_OK" > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "exemption read from the source bead's own store: accepted (rc 0)" "$RC" "0"
has "the source bead is read from BEAD_CITY" "$CALLS" "BD -C $SRC_STORE show $BB"
has "the source bead's comments are read from BEAD_CITY" "$CALLS" "BD -C $SRC_STORE comments $BB"
has "the marker is read from GC_CITY" "$CALLS" "BD -C $MRK_STORE show m-e11"
lacks "the source bead is NOT looked up in the marker's store" "$CALLS" "BD -C $MRK_STORE show $BB"

echo "  — a switch nobody could read: OFF, and the log says so (gate round 2, blocking issue 1) —"
set_beads "$BB" "$PLAIN" "$PLAIN"
: > "$FLAG"
run_e11 off "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "flag file PRESENT + GATE_E11_ENABLED=off (the operator's kill switch), arm B, 900 prod lines: ACCEPTED" "$RC" "0"
has "junk env: ONE record says the switch could not be read, and why" "$LOGF" "LOG E11-DIFF-CAP bead=$BB arm=- verdict=interruptor-ilegivel production_lines=- cap=800 exempt=- why=env-invalido"
eq "junk env: nothing refused, nothing labelled, no bd call" "$(calls_n)" "0"
eq "junk env: exactly one E11-DIFF-CAP line" "$(grep -c 'E11-DIFF-CAP' "$LOGF" | tr -d ' ')" "1"
run_e11 0 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "flag file present + env 0 (an explicit, readable OFF): accepted" "$RC" "0"
eq "env 0 is a decision, not a failure: not one line logged" "$(wc -c < "$LOGF" | tr -d ' ')" "0"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "flag file present + env 1: still ON — arm B, 900 prod lines REFUSED" "$RC" "1"
run_e11 "" "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "flag file present + env EMPTY (no override): the file decides, ON — REFUSED" "$RC" "1"
rm -f "$FLAG"
run_e11 off "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "no flag file + junk env: accepted" "$RC" "0"
has "no flag file + junk env: still says the env value could not be read" "$LOGF" "verdict=interruptor-ilegivel production_lines=- cap=800 exempt=- why=env-invalido"
run_e11 "" "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "born OFF (no file, no env): accepted" "$RC" "0"
eq "born OFF: not one line logged (silence is the OFF contract)" "$(wc -c < "$LOGF" | tr -d ' ')" "0"
if [ "$(id -u)" != "0" ]; then
  : > "$FLAG"; chmod 000 "$FLAG"
  run_e11 "" "$RIG_OK" "$BB" feat/prod900; RC=$?
  eq "flag file that exists but cannot be read: OFF, accepted" "$RC" "0"
  has "unreadable flag file: the log says so (round 2 low), not a silent OFF" "$LOGF" "verdict=interruptor-ilegivel production_lines=- cap=800 exempt=- why=flag-ilegivel"
  chmod 600 "$FLAG"; rm -f "$FLAG"
fi

echo "  — a cap override nobody could read: accept + say so, never a silent tighter cap (gate round 3, class sweep) —"
# Same family as the switch above: GATE_E11_CAP_LINES=1,200 used to fall back to 800 without a word, so a submission the
# operator meant to allow was refused at a cap nobody chose. An override that cannot be read is nao-medido (accepted,
# why=cap-invalido); the measured count still goes in the log. A READABLE cap, tight or loose, behaves as before.
set_beads "$BB" "$PLAIN" "$PLAIN"
for JC in "1,200" abc 0 " " 1000000000; do
  GATE_E11_CAP_LINES="$JC" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
  eq "cap override '$JC' (unreadable), arm B, 900 prod lines: ACCEPTED, not refused at a cap nobody chose" "$RC" "0"
  has "cap override '$JC': nao-medido, the measured count stays in the log, the cause is NAMED" "$LOGF" "LOG E11-DIFF-CAP bead=$BB arm=B verdict=nao-medido production_lines=900 cap=800 exempt=nao-consultado why=cap-invalido"
  lacks "cap override '$JC': nothing refused, nothing labelled" "$CALLS" "STATUS"
  eq "cap override '$JC': no bd call (no exemption lookup for a refusal that cannot happen)" "$(calls_n)" "0"
done
GATE_E11_CAP_LINES=abc run_e11 1 "$RIG_OK" "$BB" feat/pytest; RC=$?
eq "unreadable cap + a 40-line submission: accepted" "$RC" "0"
has "unreadable cap + a small diff: still nao-medido (nobody can say it is 'within' a cap that could not be read)" "$LOGF" "verdict=nao-medido production_lines=40 cap=800 exempt=nao-consultado why=cap-invalido"
GATE_E11_CAP_LINES=abc run_e11 1 "" "$BB" feat/prod900; RC=$?
eq "unreadable cap + an empty RIG_PATH: accepted" "$RC" "0"
has "the FIRST cause keeps its name (the cap does not overwrite it)" "$LOGF" "why=entrada-vazia"
lacks "the cap is not blamed for a cause it did not cause" "$LOGF" "why=cap-invalido"
GATE_E11_CAP_LINES=abc run_e11 1 "$RIG_OK" "$AA" feat/prod900; RC=$?
eq "unreadable cap, arm A (never measured): accepted" "$RC" "0"
has "arm A is still the control" "$LOGF" "LOG E11-DIFF-CAP bead=$AA arm=A verdict=controle"
lacks "arm A: the cap is irrelevant, so it is not named" "$LOGF" "cap-invalido"
GATE_E11_CAP_LINES=1000 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "a READABLE cap of 1000, 900 prod lines: accepted" "$RC" "0"
has "readable loose cap: dentro-do-teto at cap=1000" "$LOGF" "verdict=dentro-do-teto production_lines=900 cap=1000"
lacks "readable cap: not flagged as invalid" "$LOGF" "cap-invalido"
GATE_E11_CAP_LINES=500 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "a READABLE cap of 500, 900 prod lines: still REFUSED (positive evidence, nothing weakened)" "$RC" "1"
has "readable tight cap: the refusal names that cap" "$LOGF" "verdict=recusa production_lines=900 cap=500"

# ── the TOTAL cap, live (ga-mzyghi) ──────────────────────────────────────────
echo "  — the TOTAL cap (ga-mzyghi): code + tests + docs, 1000 by default —"
unset GATE_E11_TOTAL_CAP   # the real default from here on
RAWX=$($GITC -C "$RIG_OK" diff --numstat --no-renames origin/main...origin/feat/totexcl 2>/dev/null)
eq "fixture: feat/totexcl really carries its 9 files (generated ones force-added past any ignore rule)" "$(printf '%s\\n' "$RAWX" | grep -c .)" "9"
eq "fixture: of those, 400 lines are written by a person" "$(gate_e11_count_total_lines "$RAWX")" "400"

set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "arm B, 600 prod + 700 test = 1300 total: REFUSED (production is under 800 — only the total says no)" "$RC" "1"
has "refusal record: both counts, both caps, the new fields at the END of the line" "$LOGF" "LOG E11-DIFF-CAP bead=$BB arm=B verdict=recusa production_lines=600 cap=800 exempt=nao why=- branch=feat/tot1300 marker=m-e11 forced=0 total_lines=1300 total_cap=1000 cap_hit=total fix_attempt=no"
if grep -Eq ' verdict=[a-z-]+ production_lines=600 cap=800 .* total_lines=1300 total_cap=1000 cap_hit=total fix_attempt=no$' "$LOGF"; then ok "the record still parses the way gate-daily-report.py reads it (' verdict=<word> ', one word)"; else bad "the record does not match the shape gate-daily-report.py parses"; fi
has "the err line names the total" "$LOGF" "ERR   diff-size cap (ga-lzidpo/E11): 1300 total lines (production: 600) on feat/tot1300 vs origin/main exceed the total cap of 1000"
has "refusal: same machinery as the production refusal — the marker's refusal label" "$CALLS" "label add m-e11 gate-guard:refused-e11"
has "refusal: source bead gets gate:needs-fix + counter 1" "$CALLS" "BD -C $SRC_STORE label add $BB gate:needs-fix,gate:e11-refusals:1"
has "refusal: the VERDICT: FAIL comment on the source bead" "$CALLS" "BD -C $SRC_STORE comment $BB VERDICT: FAIL (gate guard, diff-size cap E11 — refusal 1 of 3"
has "refusal text: states the TOTAL" "$CALLS" "tem 1300 linhas no TOTAL"
has "refusal text: ...and the PRODUCTION" "$CALLS" "600 linhas de codigo de PRODUCAO"
has "refusal text: ...and both caps, naming the one exceeded" "$CALLS" "Os tetos por submissao sao 1000 no total e 800 de producao. Estourou o teto do total."
lacks "refusal text: does not blame the production cap" "$CALLS" "Estourou o teto de producao."
has "refusal text: asks for slices" "$CALLS" "O QUE FAZER: dividir em fatias"
has "refusal text: the total-cap refusal also carries the typed slicing command (ga-2xdj1x: a feature slice is born -t feature)" "$CALLS" "bd create '<titulo da fatia>' --parent $BB -t "
has "refusal text: the total-cap refusal also says to slice VERTICALLY (ga-x8mmt7)" "$CALLS" "Fatie na VERTICAL: cada fatia entrega um comportamento visivel e testavel de ponta a ponta, nao uma camada (so schema, so API ou so infra)"
has "refusal text: keep only the minimum test that proves the behavior" "$CALLS" "mantenha so o teste minimo que prova o comportamento"
has "refusal text: the guide, test lines <= code lines" "$CALLS" "(guia: linhas de teste <= linhas de codigo)"
has "refusal text: the exemption label is still named" "$CALLS" "gate:size-exempt"
has "refusal: marker closed, VERIFIED, failed" "$LOGF" "CLOSED (verified, gate-status:failed)"
has "refusal: the marker comment states the total" "$CALLS" "1300 total lines (production: 600) on feat/tot1300 vs origin/main exceed the total cap of 1000"

run_e11 1 "$RIG_OK" "$BB" feat/tot1001; RC=$?
eq "arm B, 601 prod + 400 test = 1001 total: REFUSED (the cap is 'over 1000')" "$RC" "1"
set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/tot1000; RC=$?
eq "arm B, 600 prod + 400 test = exactly 1000 total: accepted" "$RC" "0"
has "exactly the total cap: dentro-do-teto, both counts logged" "$LOGF" "verdict=dentro-do-teto production_lines=600 cap=800 exempt=nao-consultado why=- branch=feat/tot1000 marker=m-e11 forced=0 total_lines=1000 total_cap=1000 cap_hit=nenhum fix_attempt=nao-consultado"
eq "inside both caps: no bd call at all (the exemption is looked up only over a cap)" "$(calls_n)" "0"

run_e11 1 "$RIG_OK" "$BB" feat/totdocs; RC=$?
eq "arm B, 100 prod + 1100 lines of docs = 1200 total: REFUSED (docs count toward the total)" "$RC" "1"
has "docs: production_lines=100, total_lines=1200" "$LOGF" "verdict=recusa production_lines=100 cap=800 exempt=nao why=- branch=feat/totdocs marker=m-e11 forced=0 total_lines=1200"

set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/totexcl; RC=$?
eq "arm B, 400 written lines among 14.000 generated/vendor/lockfile/dist/changelog/snapshot lines: accepted" "$RC" "0"
has "excluded paths do not count: total_lines=400 (production 300)" "$LOGF" "verdict=dentro-do-teto production_lines=300 cap=800 exempt=nao-consultado why=- branch=feat/totexcl marker=m-e11 forced=0 total_lines=400"
eq "...and no bd call" "$(calls_n)" "0"

run_e11 1 "$RIG_OK" "$BB" feat/nonprod; RC=$?
eq "arm B, the 4050-line non-production branch (tests, fixtures, docs, selftest + 50 prod): REFUSED now — the production-only cap let it through" "$RC" "1"
has "nonprod: production_lines=50 total_lines=4050 cap_hit=total" "$LOGF" "verdict=recusa production_lines=50 cap=800 exempt=nao why=- branch=feat/nonprod marker=m-e11 forced=0 total_lines=4050 total_cap=1000 cap_hit=total"

set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "900 prod + 100 test = 1000 total: still refused, by the PRODUCTION cap alone" "$RC" "1"
has "production only: cap_hit=producao" "$LOGF" "total_lines=1000 total_cap=1000 cap_hit=producao fix_attempt=no"
has "production only: the text names the production cap" "$CALLS" "Os tetos por submissao sao 1000 no total e 800 de producao. Estourou o teto de producao."
lacks "production only: the text does not blame the total" "$CALLS" "Estourou o teto do total."

echo "  — both caps over —"
set_beads "$BB" "$PLAIN" "$PLAIN"
GATE_E11_TOTAL_CAP=950 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "900 prod + 100 test with a total cap of 950: REFUSED" "$RC" "1"
has "both over: cap_hit=ambos, total_cap=950" "$LOGF" "total_lines=1000 total_cap=950 cap_hit=ambos"
has "both over: the text names both" "$CALLS" "Os tetos por submissao sao 950 no total e 800 de producao. Estourou os dois tetos."
has "both over: err line states both" "$LOGF" "900 production lines (cap 800) and 1000 total lines (cap 950) on feat/prod900 vs origin/main exceed both caps"

echo "  — the exemptions of the total cap —"
set_beads "$BB" '["story:approved","gate:fix-attempt:1"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "a bead that already has gate:fix-attempt:1, 1300 total: accepted" "$RC" "0"
has "fix-attempt: isento, the cap was hit and the exemption is named" "$LOGF" "verdict=isento production_lines=600 cap=800 exempt=nao why=- branch=feat/tot1300 marker=m-e11 forced=0 total_lines=1300 total_cap=1000 cap_hit=total fix_attempt=yes"
lacks "fix-attempt: nothing refused" "$CALLS" "gate-guard:refused-e11"
lacks "fix-attempt: no gate-status written" "$CALLS" "STATUS"
has "fix-attempt: the source bead is read from BEAD_CITY" "$CALLS" "BD -C $SRC_STORE show $BB"
set_beads "$BB" '["story:approved","gate:fix-attempt:0"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "gate:fix-attempt:0 (a manual reset) counts too: accepted" "$RC" "0"
set_beads "$BB" '["story:approved","gate:needs-fix","gate:e11-refusals:2"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "a bead refused by E11 itself (gate:e11-refusals:2) is NOT a fix-attempt bead: still REFUSED" "$RC" "1"
set_beads "$BB" '["story:approved","gate:fix-attempt:1"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "fix-attempt does NOT exempt the PRODUCTION cap (900 > 800): still REFUSED — its behavior is unchanged" "$RC" "1"
has "fix-attempt + production over: cap_hit=producao fix_attempt=yes" "$LOGF" "cap_hit=producao fix_attempt=yes"
set_beads "$BB" '["story:approved","gate:fix-attempt:1"]' "$PLAIN"
GATE_E11_TOTAL_CAP=950 run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "fix-attempt, both caps over: the production cap refuses alone" "$RC" "1"
has "...and the text names only the cap that refuses" "$CALLS" "Estourou o teto de producao."

set_beads "$BB" "$EXEMPT" "$PLAIN"
printf '%s' "$RSN_OK" > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "gate:size-exempt + a reason, 1300 total: accepted" "$RC" "0"
has "size-exempt: isento, exempt=exempt" "$LOGF" "verdict=isento production_lines=600 cap=800 exempt=exempt why=- branch=feat/tot1300 marker=m-e11 forced=0 total_lines=1300 total_cap=1000 cap_hit=total fix_attempt=no"
set_beads "$BB" "$EXEMPT" "$PLAIN"
printf '%s' "$RSN_SHORT" > "$SRC_STORE/comments-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "gate:size-exempt with a token reason, 1300 total: still REFUSED" "$RC" "1"
has "token reason: exempt=label-sem-motivo" "$LOGF" "exempt=label-sem-motivo"
set_beads "$BB" "$PLAIN" "$EXEMPT"
printf '%s' "$RSN_OK" > "$MRK_STORE/comments-m-e11.json"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "label + reason on the MARKER bead instead, 1300 total: accepted" "$RC" "0"

echo "  — a total that cannot be read, a bead that cannot be read: accept + say so —"
set_beads "$BB" "$PLAIN" "$PLAIN"; rm -f "$SRC_STORE/show-$BB.json"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "source bead unreadable, 1300 total: accepted, not refused" "$RC" "0"
has "unreadable source: nao-medido-isencao, fix_attempt=desconhecido, the cause NAMED" "$LOGF" "verdict=nao-medido-isencao production_lines=600 cap=800 exempt=desconhecido why=isencao-ilegivel branch=feat/tot1300 marker=m-e11 forced=0 total_lines=1300 total_cap=1000 cap_hit=total fix_attempt=desconhecido"
lacks "unreadable source: nothing refused" "$CALLS" "STATUS"
set_beads "$BB" "$PLAIN" "$PLAIN"; rm -f "$MRK_STORE/show-m-e11.json"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "marker bead unreadable (source readable, no exemption), 1300 total: accepted, not refused" "$RC" "0"
has "unreadable marker: nao-medido-isencao" "$LOGF" "verdict=nao-medido-isencao production_lines=600"
set_beads "$BB" '["story:approved","gate:fix-attempt:2"]' "$PLAIN"; rm -f "$MRK_STORE/show-m-e11.json"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "fix-attempt read on the source, marker unreadable: accepted" "$RC" "0"
has "the readable exemption wins over the unreadable one: isento" "$LOGF" "verdict=isento production_lines=600"
set_beads "$BB" "$EXEMPT" "$PLAIN"      # label present, its comments cannot be read
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "size-exempt label present, comments unreadable, 1300 total: accepted" "$RC" "0"
has "comments unreadable: nao-medido-isencao" "$LOGF" "verdict=nao-medido-isencao"
set_beads "$BB" "$PLAIN" "$PLAIN"
run_e11 1 "" "$BB" feat/tot1300; RC=$?
eq "RIG_PATH empty: accepted" "$RC" "0"
has "RIG_PATH empty: both counts unknown, the cause named, nothing hit" "$LOGF" "verdict=nao-medido production_lines=unknown cap=800 exempt=nao-consultado why=entrada-vazia branch=feat/tot1300 marker=m-e11 forced=0 total_lines=unknown total_cap=1000 cap_hit=nenhum fix_attempt=nao-consultado"
run_e11 1 "$NOT_A_REPO" "$BB" feat/tot1300; RC=$?
eq "git cannot answer (not a repo): accepted" "$RC" "0"
has "not a repo: total_lines=unknown" "$LOGF" "total_lines=unknown"
run_e11 1 "$RIG_OK" "$BB" feat/ghost; RC=$?
eq "branch missing on origin: accepted" "$RC" "0"
has "branch missing: total_lines=unknown" "$LOGF" "total_lines=unknown"
run_e11 1 "$RIG_STALE" "$BB" feat/small; RC=$?
$GITC -C "$RIG_STALE" remote set-url origin "$TMPD/origin-is-gone.git"
run_e11 1 "$RIG_STALE" "$BB" feat/small; RC=$?
eq "origin unreachable (stale main): accepted" "$RC" "0"
has "stale main: total_lines=unknown, no 1010 as a measurement" "$LOGF" "why=fetch-falhou branch=feat/small marker=m-e11 forced=0 total_lines=unknown"
lacks "stale main: no total_lines=1010" "$LOGF" "total_lines=1010"
$GITC -C "$RIG_STALE" remote set-url origin "$ORIGIN2"

echo "  — a total cap override: readable ones decide, unreadable ones accept + say so —"
set_beads "$BB" "$PLAIN" "$PLAIN"
GATE_E11_TOTAL_CAP=1500 run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "GATE_E11_TOTAL_CAP=1500, 1300 total: accepted" "$RC" "0"
has "readable loose total cap: dentro-do-teto at total_cap=1500" "$LOGF" "verdict=dentro-do-teto production_lines=600 cap=800 exempt=nao-consultado why=- branch=feat/tot1300 marker=m-e11 forced=0 total_lines=1300 total_cap=1500 cap_hit=nenhum"
GATE_E11_TOTAL_CAP=1200 run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "GATE_E11_TOTAL_CAP=1200, 1300 total: still REFUSED (positive evidence, nothing weakened)" "$RC" "1"
has "readable tight total cap: the refusal names that cap" "$LOGF" "total_lines=1300 total_cap=1200 cap_hit=total"
for JC in "1,000" abc 0 " " 1000000000; do
  set_beads "$BB" "$PLAIN" "$PLAIN"
  GATE_E11_TOTAL_CAP="$JC" run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
  eq "total cap override '$JC' (unreadable), 1300 total: ACCEPTED, not refused at a cap nobody chose" "$RC" "0"
  has "total cap override '$JC': nao-medido, the measured counts stay in the log, the cause is NAMED" "$LOGF" "LOG E11-DIFF-CAP bead=$BB arm=B verdict=nao-medido production_lines=600 cap=800 exempt=nao-consultado why=cap-invalido"
  lacks "total cap override '$JC': nothing refused, nothing labelled" "$CALLS" "STATUS"
  eq "total cap override '$JC': no bd call (no exemption lookup for a refusal that cannot happen)" "$(calls_n)" "0"
  set_beads "$BB" "$PLAIN" "$PLAIN"
  GATE_E11_TOTAL_CAP="$JC" run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
  eq "total cap override '$JC' unreadable, but the production cap is understood: 900 prod REFUSED by it, alone" "$RC" "1"
done
set_beads "$BB" "$PLAIN" "$PLAIN"
GATE_E11_CAP_LINES=abc run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "production cap unreadable, total cap understood: the total decides on its own — 1300 REFUSED" "$RC" "1"
has "...cap_hit=total" "$LOGF" "total_lines=1300 total_cap=1000 cap_hit=total"

echo "  — arm A, the 100% switch, the crew author, the 3rd refusal —"
run_e11 1 "$RIG_OK" "$AA" feat/tot1300; RC=$?
eq "arm A, 1300 total: accepted, today's behavior" "$RC" "0"
has "arm A: not measured by design — total_lines=- and nothing hit" "$LOGF" "LOG E11-DIFF-CAP bead=$AA arm=A verdict=controle production_lines=- cap=800 exempt=nao-consultado why=- branch=feat/tot1300 marker=m-e11 forced=0 total_lines=- total_cap=1000 cap_hit=nenhum fix_attempt=nao-consultado"
eq "arm A: nothing touched" "$(calls_n)" "0"
set_beads "$AA" "$PLAIN" "$PLAIN"
touch "$MRK_STORE/.gc/gate-e11-diff-cap.all"
run_e11 1 "$RIG_OK" "$AA" feat/tot1300; RC=$?
eq "100% switch: an arm-A bead gets the total cap too — 1300 REFUSED" "$RC" "1"
has "100%: arm=B forced=1 total_lines=1300" "$LOGF" "bead=$AA arm=B verdict=recusa production_lines=600 cap=800 exempt=nao why=- branch=feat/tot1300 marker=m-e11 forced=1 total_lines=1300"
rm -f "$MRK_STORE/.gc/gate-e11-diff-cap.all"

set_beads "$BB" '["story:approved","gate:queued"]' "$PLAIN"
git -C "$RIG_OK" push -q origin origin/feat/tot1300:refs/heads/crew/oracle/wa-def456 >/dev/null 2>&1 && git -C "$RIG_OK" fetch -q origin >/dev/null 2>&1 || echo "  (could not publish the crew branch in the fake origin)"
run_e11 1 "$RIG_OK" "$BB" crew/oracle/wa-def456; RC=$?
eq "crew branch, 1300 total: refused" "$RC" "1"
has "crew branch: the author mail states the total" "$CALLS" "GC --city $MRK_STORE mail send oracle -s Gate recusou $BB na submissao: 1300 linhas no total (producao: 600) > teto do total 1000 (E11)"
set_beads "$BB" '["story:approved","gate:e11-refusals:2"]' "$PLAIN"
run_e11 1 "$RIG_OK" "$BB" feat/tot1300; RC=$?
eq "3rd refusal on the total cap still refuses" "$RC" "1"
has "3rd: gate:needs-human" "$CALLS" "BD -C $SRC_STORE label add $BB gate:needs-human"
has "3rd: the mayor is told what was exceeded" "$CALLS" "foi recusado na submissao pela 3a vez: 1300 linhas no total (producao: 600) > teto do total 1000. Ficou com gate:needs-human"
has "3rd: ...and that the slices are VERTICAL, not layers (ga-x8mmt7)" "$CALLS" "e fatia VERTICAL: um comportamento testavel de ponta a ponta, nao uma camada so de schema/API/infra"

echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; fi
echo "  RESULT: FAIL"; exit 1
