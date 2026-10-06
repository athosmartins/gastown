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

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # sourcing the guard leaks its `set -e` into this shell (same as the siblings)

# ── 0. preflight: every function the feature is made of exists ──────────────
# Without this a negative assertion ("prints nothing", "no bd call") passes VACUOUSLY on a guard that has no E11 at
# all — `command not found` also prints nothing. One assertion per function, so the old guard fails loudly here.
echo "── 0. the E11 functions exist ──"
E11_FNS="gate_e11_switch_state gate_e11_enabled gate_e11_arm_for_bead gate_e11_path_is_production gate_e11_count_production_lines
gate_e11_cap_lines gate_e11_exempt_label gate_e11_exempt_reason gate_e11_exempt_state gate_e11_exempt_merge gate_e11_verdict"
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
# …and the names that LOOK like tests but are product code must stay counted: only the anchored shapes above are
# excluded, never a bare 'test'/'selftest' substring.
for p in internal/daemon/main_branch_test_runner.go internal/doctor/testutil_symlink_check.go \
         .gascity-gastown-hq/packs/town-deltas/assets/gate_basetest_outcomes.py \
         .gascity-gastown-hq/packs/town-deltas/assets/heavy-selftest-guard.sh \
         src/latest-test-run.go src/contest-runner.sh src/selftestify.py; do
  prod "$p"; eq "still production (test-ish name, product code): $p" "$?" "0"
done

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

# ── 5. the cap ───────────────────────────────────────────────────────────────
echo "── 5. gate_e11_cap_lines ──"
eq "default is 800" "$(unset GATE_E11_CAP_LINES; gate_e11_cap_lines)" "800"
eq "numeric override" "$(GATE_E11_CAP_LINES=1000 gate_e11_cap_lines)" "1000"
eq "junk override falls back to 800" "$(GATE_E11_CAP_LINES=abc gate_e11_cap_lines)" "800"
eq "0 would refuse everything: falls back to 800" "$(GATE_E11_CAP_LINES=0 gate_e11_cap_lines)" "800"
eq "empty override falls back to 800" "$(GATE_E11_CAP_LINES= gate_e11_cap_lines)" "800"

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

# ── 8. the guard block, run LIVE ─────────────────────────────────────────────
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
set_gate_status() { echo "STATUS $*" >> "$CALLS"; }
# bd answers `show <id>` and `comments <id>` from files named per id AND per store (-C <dir>): the source bead lives in
# BEAD_CITY ($TMPD/beadcity), the marker in GC_CITY ($TMPD/city) — two DIFFERENT dirs, so a block that read the source
# bead from the marker's store (or the reverse) finds nothing and the assertions below fail (gate round 2 nit: the stub
# used to ignore -C and BEAD_CITY equalled GC_CITY, so swapping them would still have passed). Any other verb
# (comment ...) succeeds.
bd() {
  echo "BD $*" >> "$CALLS"
  local verb="" id="" prev="" dir="" a
  for a in "$@"; do
    case "$prev" in
      -C) dir="$a" ;;
      show) verb=show; id="$a" ;;
      comments) verb=comments; id="$a" ;;
      comment) [ -z "$verb" ] && verb=comment ;;
    esac
    prev="$a"
  done
  case "$verb" in
    show)     [ -n "$dir" ] && [ -f "$dir/show-$id.json" ] && cat "$dir/show-$id.json" || return 1 ;;
    comments) [ -n "$dir" ] && [ -f "$dir/comments-$id.json" ] && cat "$dir/comments-$id.json" || return 1 ;;
    *) return 0 ;;
  esac
}
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
  : > "$LOGF"; : > "$CALLS"
  ( set -euo pipefail
    export GATE_E11_ENABLED="$1"
    RIG_PATH="$2"; BEAD_ID="$3"; BRANCH="$4"; MARKER_ID="m-e11"; GC_CITY="$MRK_STORE"; BEAD_CITY="$SRC_STORE"
    . "$E11_FILE" ) >/dev/null 2>&1
  return $?
}
calls_n() { wc -c < "$CALLS" | tr -d ' '; }

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

echo "  — arm B, treated —"
run_e11 1 "$RIG_OK" "$BB" feat/prod900; RC=$?
eq "arm B, 900 prod lines (+100 test): REFUSED (rc 1)" "$RC" "1"
has "refusal: the record is written BEFORE the exit, with the production count (tests not counted)" "$LOGF" "LOG E11-DIFF-CAP bead=$BB arm=B verdict=recusa production_lines=900 cap=800"
has "refusal: gate-status:error on the marker" "$CALLS" "STATUS m-e11 error"
has "refusal: a comment goes on the marker" "$CALLS" "BD -C $TMPD/city comment m-e11"
has "refusal: the comment tells the builder to split into slices" "$CALLS" "fatias"
has "refusal: the comment names the exemption label" "$CALLS" "gate:size-exempt"
has "refusal: the comment gives the count and the cap" "$CALLS" "900"

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

echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; fi
echo "  RESULT: FAIL"; exit 1
