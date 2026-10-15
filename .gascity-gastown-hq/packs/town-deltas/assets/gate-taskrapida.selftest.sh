#!/usr/bin/env bash
# gate-taskrapida.selftest.sh (ga-dzzqvw)
#
# Proves the gate's "task-rapida" lane: a SMALL TASK (<= 200 production lines) outside message sending, money and customer
# data gets ONE short review; everything else — and everything that merely could not be verified — stays in the normal gate.
# The lane is only GRANTED, on positive evidence, all at once: issue_type == task, E11's production lines <= 200, no file on
# the risk list, the switch file present. A missing or unreadable input is the third state, and the third state is the normal gate.
#
# Executed, not described: 1-6 gate_taskrapida_decide against REAL git history in a temp repo (the story's five controls, type,
# size boundaries, risk list, switch, every lookup that can fail); 7 the short prompt; 8 the code list vs the cases; 9 the
# dispatcher's own blocks (lib load, decision, recorder, placement). Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/gate-taskrapida.lib.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
RISK_DEFAULT="$SELF_DIR/gate-task-rapida-risco.default.txt"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2) — never the first `bash` on PATH

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-taskrapida.selftest =="
for f in "$LIB" "$GUARD" "$DISPATCHER" "$RISK_DEFAULT"; do
  if [ -r "$f" ]; then ok "present: $(basename "$f")"; else bad "missing: $f"; fi
done
[ -x "$B32" ] || { echo "FATAL: $B32 not found"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-taskrapida.XXXXXX")" || { echo "mktemp failed"; exit 2; }
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/city/.gc" "$T/bin"
ON_FILE="$T/city/.gc/gate-task-rapida.on"
RISK_FILE="$T/city/.gc/gate-task-rapida-risco.txt"
: > "$ON_FILE"
cp "$RISK_DEFAULT" "$RISK_FILE" 2>/dev/null || : > "$RISK_FILE"

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

# tr_env <ENV=VAL ...> <cmd ...> — `env` for EVERY child that runs the lib. The lane's controls and tuning knobs are
# pinned to their defaults first (by NAME PATTERN, so a knob added later is covered too), so a case never depends on the
# caller's environment; a case that WANTS a control passes it as ENV=VAL, which comes after the pin and wins.
tr_env() {
  local a=() v
  for v in $(compgen -e | grep '^GATE_TASKRAPIDA_' || true); do a[${#a[@]}]="-u"; a[${#a[@]}]="$v"; done
  env ${a[@]+"${a[@]}"} -u GC_CITY -u GATE_E5_ACTIVE \
    GATE_TASKRAPIDA_ON_FILE="$ON_FILE" GATE_TASKRAPIDA_RISK_FILE="$RISK_FILE" "$@"
}

# ── the driver: what the dispatcher does, minus the dispatcher ───────────────────────────────────────────────
# Sources the guard lib-only (that is where E11's counter comes from in the dispatcher) and the lane lib, under the
# dispatcher's own shell options, and prints what the decision left behind.
cat > "$T/driver.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
GUARD="$1"; LIB="$2"
# the guard hard-sets GC_CITY when sourced (the dispatcher's own value is the same, so it never notices); the case under test
# decides whether GC_CITY exists, so what the caller had is put back
_had="${GC_CITY+set}"; _old="${GC_CITY-}"
if [ "${DRV_NO_E11:-0}" != "1" ]; then GATE_GUARD_LIB_ONLY=1 source "$GUARD"; fi
if [ -n "$_had" ]; then GC_CITY="$_old"; else unset GC_CITY; fi
source "$LIB"
gfn()          { git -C "$DRV_REPO" "$@"; }
failing_git()  { return 1; }
garbage_git()  { printf 'not-a-number\tx\tsrc/a.py\n'; }
blank_git()    { printf '\t\t\n'; }
binary_git()   { printf -- '-\t-\tassets/logo.bin\n3\t1\tsrc/a.py\n'; }
GATE_LANE="${DRV_LANE_IN:-normal}"; GATE_LANE_REASON=""; GATE_LANE_REASON_CODE=""; GATE_LANE_FILES=""; GATE_LANE_COUNTS=""
rc=0
gate_taskrapida_decide "${DRV_GITFN:-gfn}" "${DRV_BASE:-main}" "$DRV_HEAD" "${DRV_BEAD_JSON-}" "${DRV_RIG:-}" "${DRV_POLICY:-}" || rc=$?
printf 'RC=%s\nLANE=%s\nCODE=%s\nLINES=%s\nLCODE=%s\nREASON=%s\nWHY=%s\nCOUNTS=%s\nFILES=%s\n' \
  "$rc" "$GATE_LANE" "${GATE_TR_CODE:-}" "${GATE_TR_LINES:-}" "${GATE_LANE_REASON_CODE:-}" \
  "$(printf '%s' "${GATE_LANE_REASON:-}" | tr '\n' '|')" "$(printf '%s' "${GATE_TR_WHY:-}" | tr '\n' '|')" \
  "${GATE_LANE_COUNTS:-}" "$(printf '%s' "${GATE_LANE_FILES:-}" | tr '\n' '|')"
EOF

# ── a real git repo: main + one branch per case ──────────────────────────────────────────────────────────────
REPO="$T/repo"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO"; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t; git -C "$REPO" config commit.gpgsign false
printf 'base\n' > "$REPO/README.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m base
BR_N=0
# mkbranch <spec...> — one branch off main; each spec is path:lines (N distinct lines in that file). Leaves the name in $BR
# (not on stdout: a $(...) would run it in a subshell and lose the counter, and every case would get the same branch name).
mkbranch() {
  BR_N=$((BR_N+1)); local b="case-$BR_N" s p n i; BR="$b"
  git -C "$REPO" checkout -q -b "$b" main
  for s in "$@"; do
    p="${s%:*}"; n="${s##*:}"
    mkdir -p "$REPO/$(dirname "$p")"
    : > "$REPO/$p"; i=1
    while [ "$i" -le "$n" ]; do printf 'line %s of %s\n' "$i" "$b" >> "$REPO/$p"; i=$((i+1)); done
  done
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m "$b"
  git -C "$REPO" checkout -q main
}
bj() { printf '[{"id":"ga-x","issue_type":"%s","status":"in_progress"}]' "$1"; }

OUT=""
field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
# decide <branch> <bead_json> [ENV=VAL ...] — runs the driver under the daemon's shell, leaves its output in $OUT
decide() {
  local b="$1" j="$2"; shift 2
  OUT=$(tr_env DRV_REPO="$REPO" DRV_HEAD="$b" DRV_BEAD_JSON="$j" "$@" "$B32" "$T/driver.sh" "$GUARD" "$LIB" 2>&1) || true
}
# expect <label> <lane> <code> — assert the last decision
expect() {
  local label="$1" wl="$2" wc="$3" gl gc rc
  gl=$(field LANE); gc=$(field CODE); rc=$(field RC)
  if [ "$gl" = "$wl" ] && [ "$gc" = "$wc" ]; then
    if { [ "$wl" = "task-rapida" ] && [ "$rc" = "0" ]; } || { [ "$wl" = "normal" ] && [ "$rc" = "1" ]; }; then ok "$label → lane=$wl code=$wc"; return 0; fi
    bad "$label: lane/code right but rc=$rc (granted must be 0, refused 1)"; return 1
  fi
  bad "$label: want lane=$wl code=$wc, got lane='$gl' code='$gc' rc='$rc' why='$(field WHY)' $(printf '%s' "$OUT" | grep -v -E '^(RC|LANE|CODE|LINES|LCODE|REASON|WHY|COUNTS|FILES)=' | head -3 | tr '\n' ' ')"
  return 1
}

# ── 1. the story's five controls ─────────────────────────────────────────────────────────────────────────────
echo "── 1. the five controls from the story ──"
mkbranch src/report/format.py:150; B=$BR
decide "$B" "$(bj task)";                                  expect "task 150 lines outside the risk list" task-rapida granted
[ "$(field LINES)" = "150" ] && ok "  …the measured production lines are reported (150)" || bad "  …LINES want 150, got '$(field LINES)'"
case "$(field COUNTS)" in *prod=150*) ok "  …the counts carry prod=150" ;; *) bad "  …COUNTS want prod=150, got '$(field COUNTS)'" ;; esac
case "$(field FILES)" in *src/report/format.py*) ok "  …the file that decided is listed" ;; *) bad "  …FILES want src/report/format.py, got '$(field FILES)'" ;; esac
[ "$(field LCODE)" = "task-rapida-granted" ] && ok "  …GATE_LANE_REASON_CODE is task-rapida-granted" || bad "  …LCODE want task-rapida-granted, got '$(field LCODE)'"
mkbranch src/envio/whatsapp_sender.py:150; B=$BR
decide "$B" "$(bj task)";                                  expect "task 150 lines touching a send file" normal risk-file
[ "$(field LANE)" = "normal" ] && [ -z "$(field LCODE)" ] && ok "  …a refusal leaves the lane code to the fast lane (GATE_LANE_REASON_CODE untouched)" || bad "  …LCODE after a refusal want empty, got '$(field LCODE)'"
case "$(field WHY)" in *"envio"*) ok "  …the refusal names the pattern that matched" ;; *) bad "  …WHY should name the matching pattern, got '$(field WHY)'" ;; esac
mkbranch src/report/format.py:250; B=$BR
decide "$B" "$(bj task)";                                  expect "task 250 lines" normal over-limit
mkbranch src/report/format.py:100; B=$BR
decide "$B" "$(bj feature)";                               expect "feature 100 lines" normal not-task
mkbranch src/report/format.py:100; B=$BR
decide "$B" "";                                            expect "type unreadable (no bead JSON)" normal type-unreadable

# ── 2. the type: only the word "task" is positive evidence ───────────────────────────────────────────────────
echo "── 2. the type ──"
mkbranch src/report/format.py:10; B=$BR
for ty in bug feature chore epic Task TASK molecule; do
  decide "$B" "$(bj "$ty")"; expect "issue_type=$ty" normal not-task
done
for j in 'garbage' '{"error":"not found"}' '[]' '[{"id":"ga-x"}]' '[{"id":"ga-x","issue_type":""}]' '[{"id":"ga-x","issue_type":null}]' '[{"id":"ga-x","issue_type":42}]' 'null'; do
  decide "$B" "$j"; expect "bead JSON unreadable: $j" normal type-unreadable
done
decide "$B" '{"id":"ga-x","issue_type":"task"}'; expect "a bare object (not an array) with issue_type=task" task-rapida granted

# the opt-out label: the short prompt tells a builder to add gate:normal-only and resubmit — that has to keep the task in the normal gate.
# (labels are an array of strings in bd show --json; an absent labels key is a bead with none)
bjl() { printf '[{"id":"ga-x","issue_type":"task","labels":%s}]' "$1"; }
decide "$B" "$(bjl '["gate:normal-only"]')";                     expect "label gate:normal-only → the builder or a reviewer asked for the normal gate" normal opted-out
decide "$B" "$(bjl '["exec:auto","gate:normal-only","lane:small"]')"; expect "gate:normal-only among other labels" normal opted-out
decide "$B" "$(bjl '["Gate:Normal-Only"]')";                     expect "the label in other case still opts out (the doubtful reading is the normal gate)" normal opted-out
decide "$B" "$(bjl '["exec:auto","lane:small","story:approved"]')"; expect "other labels, no opt-out" task-rapida granted
decide "$B" "$(bjl '[]')";                                       expect "an empty labels array" task-rapida granted
decide "$B" "$(bjl 'null')";                                     expect "labels null is a bead with no labels" task-rapida granted
decide "$B" "$(bjl '["gate:normal-only-not"]')";                 expect "a label that only starts like the opt-out is not the opt-out" task-rapida granted
decide "$B" "$(bjl '["gate:normal"]')";                          expect "gate:normal alone is not the opt-out" task-rapida granted
decide "$B" "$(bjl '"gate:normal-only"')";                       expect "labels as a string, not an array: the read is not what bd emits" normal labels-unreadable
decide "$B" "$(bjl '{"a":1}')";                                  expect "labels as an object" normal labels-unreadable
decide "$B" "$(bjl '42')";                                       expect "labels as a number" normal labels-unreadable
decide "$B" "$(bjl '[["gate:normal-only"]]')";                   expect "a label that is not a string (nested array)" normal labels-unreadable
decide "$B" "$(bjl '[42, "exec:auto"]')";                        expect "a non-string label among strings" normal labels-unreadable
# the type is judged before the labels: a bug carrying the opt-out is still just "not a task"
decide "$B" '[{"id":"ga-x","issue_type":"bug","labels":["gate:normal-only"]}]'; expect "a bug with the opt-out label: the type answers first" normal not-task

# ── 3. the size: E11's production lines, 200 inclusive ───────────────────────────────────────────────────────
echo "── 3. the size ──"
mkbranch src/report/format.py:200; B=$BR; decide "$B" "$(bj task)"; expect "exactly 200 production lines" task-rapida granted
mkbranch src/report/format.py:201; B=$BR; decide "$B" "$(bj task)"; expect "201 production lines" normal over-limit
mkbranch src/a.py:100 src/b.py:101; B=$BR; decide "$B" "$(bj task)"; expect "201 production lines over two files" normal over-limit
mkbranch src/report/format.py:150 tests/test_format.py:400 docs/format.md:80; B=$BR
decide "$B" "$(bj task)"; expect "150 production + 400 test + 80 doc lines (only production counts)" task-rapida granted
mkbranch src/report/format.py:150 tests/test_format.py:900; B=$BR
decide "$B" "$(bj task)"; expect "150 production + 900 test lines (1050 in all: the total bound)" normal over-total
mkbranch docs/big.md:1500; B=$BR
decide "$B" "$(bj task)"; expect "1500 doc lines, 0 production (E11 would call it zero: the total bound does not)" normal over-total
mkbranch src/report/format.py:60; B=$BR
decide "$B" "$(bj task)" GATE_TASKRAPIDA_MAX_LINES=50;  expect "cap lowered to 50 by env, 60 lines" normal over-limit
decide "$B" "$(bj task)" GATE_TASKRAPIDA_MAX_LINES=60;  expect "cap 60 by env, 60 lines" task-rapida granted
for badcap in abc 0 -5 "1,200" "" 99999 "20 0"; do
  decide "$B" "$(bj task)" GATE_TASKRAPIDA_MAX_LINES="$badcap"
  if [ -z "$badcap" ]; then expect "cap set but empty (= the documented default)" task-rapida granted
  else expect "cap unreadable ('$badcap')" normal cap-invalid; fi
done
decide "$B" "$(bj task)" GATE_TASKRAPIDA_MAX_TOTAL_LINES=abc; expect "total bound unreadable" normal cap-invalid

# ── 4. the risk list: every keyword of the story ─────────────────────────────────────────────────────────────
echo "── 4. the risk list ──"
for p in app/whapi/client.py src/campaign_runner.py src/envio_x.py lib/send_mail.py jobs/outreach.py bot/autoreply.py \
         svc/notifier.py jobs/followup.py voice/voicebot/agent.py fin/pagamento.py fin/billing.py fin/cobranca.py fin/credito.py \
         crm/pipedrive_sync.py crm/contato.py crm/lead_score.py crm/fila_espera.py crm/proprietario.py \
         db/migrations/001_add_col.sql data/clientes.db data/app.db db/schema.sql App/Whapi/Client.py src/cobrança.py src/crédito.py; do
  mkbranch "$p:20"; B=$BR; decide "$B" "$(bj task)"; expect "risk keyword in path: $p" normal risk-file
done
mkbranch tests/test_envio.py:20 src/report/format.py:20; B=$BR
decide "$B" "$(bj task)"; expect "a TEST file named for a send file is in the diff (any file of the diff counts)" normal risk-file
mkbranch src/report/format.py:20 src/report/table.py:20 docs/guide.md:10 tests/test_format.py:30; B=$BR
decide "$B" "$(bj task)"; expect "four ordinary files" task-rapida granted

# the loop above ran against a copy of the shipped list, so every keyword of the story is proven to match it; only its size is pinned here
n=$(grep -v -E '^[[:space:]]*(#|$)' "$RISK_DEFAULT" 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -ge 20 ] && ok "the shipped risk list carries $n patterns" || bad "the shipped risk list should carry the story's keywords (>= 20 patterns), has '${n:-0}'"

# the list as a file: absent / unreadable / empty / only comments / malformed are all "could not tell"
mkbranch src/report/format.py:20; B=$BR
decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/city/.gc/does-not-exist.txt"; expect "risk list absent" normal risk-unreadable
: > "$T/empty-risk.txt"
decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/empty-risk.txt"; expect "risk list empty" normal risk-unreadable
printf '# only a comment\n\n   \n' > "$T/comment-risk.txt"
decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/comment-risk.txt"; expect "risk list with no pattern at all" normal risk-unreadable
printf 'envio\n[broken\nwhapi\n' > "$T/broken-risk.txt"
decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/broken-risk.txt"; expect "risk list with an unterminated [section" normal risk-unreadable
mkdir -p "$T/dir-risk"
decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/dir-risk"; expect "risk list is a directory" normal risk-unreadable
if [ "$(id -u)" != "0" ]; then
  cp "$RISK_DEFAULT" "$T/locked-risk.txt"; chmod 000 "$T/locked-risk.txt"
  decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/locked-risk.txt"; expect "risk list exists but cannot be read" normal risk-unreadable
  chmod 600 "$T/locked-risk.txt"
else
  ok "(running as root: the unreadable-file case cannot be built, skipped)"
fi
# no location at all (GC_CITY and the override both unset) is a switch/list nobody can find, not "no risk"
decide "$B" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE=; expect "risk list location unknown (override empty, GC_CITY unset)" normal risk-unreadable

# syntax of the list: comments, blanks, case, globs, [rig] sections
printf '# comment\n\n  Mailer  \n*.cfg\n' > "$T/syn-risk.txt"
mkbranch src/MAILER_core.py:20; B1=$BR;     decide "$B1" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/syn-risk.txt"; expect "pattern is trimmed and case-insensitive" normal risk-file
mkbranch conf/app.cfg:20; B2=$BR;           decide "$B2" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/syn-risk.txt"; expect "a glob pattern (*.cfg) matches" normal risk-file
mkbranch conf/app.cfgx:20; B3=$BR;          decide "$B3" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/syn-risk.txt"; expect "a glob pattern is anchored (app.cfgx is not *.cfg)" task-rapida granted
mkbranch src/comment.py:20; B4=$BR;         decide "$B4" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/syn-risk.txt"; expect "a comment line is not a pattern ('comment' matches nothing)" task-rapida granted
printf 'common\n[rig_a]\nonlya\n[rig_b]\nonlyb\n[*]\nanyrig\n' > "$T/rig-risk.txt"
mkbranch src/onlya_x.py:20; Ba=$BR; mkbranch src/onlyb_x.py:20; Bb=$BR; mkbranch src/common_x.py:20; Bc=$BR; mkbranch src/anyrig_x.py:20; Bd=$BR
decide "$Ba" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/rig-risk.txt" DRV_RIG=rig_a; expect "[rig_a] pattern, rig_a" normal risk-file
decide "$Ba" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/rig-risk.txt" DRV_RIG=rig_b; expect "[rig_a] pattern, rig_b (another rig's pattern does not apply)" task-rapida granted
decide "$Bb" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/rig-risk.txt" DRV_RIG=rig_b; expect "[rig_b] pattern, rig_b" normal risk-file
decide "$Bc" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/rig-risk.txt" DRV_RIG=rig_b; expect "pattern before any [section] applies to every rig" normal risk-file
decide "$Bd" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/rig-risk.txt" DRV_RIG=rig_a; expect "[*] section applies to every rig" normal risk-file
decide "$Ba" "$(bj task)" GATE_TASKRAPIDA_RISK_FILE="$T/rig-risk.txt" DRV_RIG=;      expect "rig unknown: only the global patterns apply, and that is said by a grant only when nothing else matches" task-rapida granted

# ── 5. the switch (.gc/gate-task-rapida.on, born ON) ─────────────────────────────────────────────────────────
echo "── 5. the switch ──"
mkbranch src/report/format.py:20; B=$BR
decide "$B" "$(bj task)";                                                           expect "switch file present (ON)" task-rapida granted
decide "$B" "$(bj task)" GATE_TASKRAPIDA_ON_FILE="$T/city/.gc/absent.on";           expect "switch file absent (OFF)" normal switch-off
decide "$B" "$(bj task)" GATE_TASKRAPIDA_ENABLED=0;                                 expect "kill by env (GATE_TASKRAPIDA_ENABLED=0)" normal disabled
decide "$B" "$(bj task)" GATE_TASKRAPIDA_ON_FILE=;                                  expect "switch location unknown (override empty, GC_CITY unset)" normal switch-unreadable
decide "$B" "$(bj task)" GATE_TASKRAPIDA_ON_FILE= GC_CITY="$T/city";                expect "switch located through GC_CITY/.gc (present)" task-rapida granted
decide "$B" "$(bj task)" GATE_TASKRAPIDA_ON_FILE= GC_CITY="$T/nowhere";             expect "switch located through GC_CITY/.gc (absent)" normal switch-off
mkdir -p "$T/city/.gc/dir.on"
decide "$B" "$(bj task)" GATE_TASKRAPIDA_ON_FILE="$T/city/.gc/dir.on";              expect "switch is a directory (not a file that says ON)" normal switch-off

# ── 6. the third state: every lookup that can fail ends in the normal gate ───────────────────────────────────
echo "── 6. could not tell → normal ──"
mkbranch src/report/format.py:20; B=$BR
decide "$B" "$(bj task)" DRV_GITFN=failing_git;      expect "git fails" normal diff-failed
decide "$B" "$(bj task)" DRV_GITFN=garbage_git;      expect "git answers a row that is not a numstat row" normal count-failed
decide "$B" "$(bj task)" DRV_GITFN=blank_git;        expect "git answers only blank rows: nothing was read, so nothing was checked against the risk list" normal count-failed
mkdir -p "$T/failtr" && printf '#!/bin/sh\nexit 1\n' > "$T/failtr/tr" && chmod +x "$T/failtr/tr"; decide "$B" "$(bj task)" PATH="$T/failtr:$PATH"; expect "tr fails while the risk list is read: a pattern that could not be lower-cased is not a pattern that matched nothing" normal risk-unreadable
decide "$B" "$(bj task)" DRV_GITFN=binary_git;       expect "a binary file in the diff (nothing to count, nothing to scan)" normal binary-file
decide "$B" "$(bj task)" DRV_BASE=no-such-ref;       expect "base ref does not exist" normal diff-failed
decide "$B" "$(bj task)" DRV_HEAD=no-such-branch;    expect "head ref does not exist" normal diff-failed
decide "$B" "$(bj task)" DRV_NO_E11=1;               expect "E11's counter is not loaded (the guard sibling is missing)" normal counter-missing
decide "$B" "$(bj task)" DRV_BASE="$B";              expect "base == head: an empty diff is not evidence of anything" normal empty-diff
decide "$B" "$(bj task)" DRV_POLICY="packs/town-deltas/assets/quality-gate-dispatcher.sh"; expect "the diff touches the gate's own policy files" normal policy-files
decide "$B" "$(bj task)" GATE_E5_ACTIVE=1;           expect "E5 (extra reviewer slot) is active on this run" normal e5-active
decide "$B" "$(bj task)" DRV_LANE_IN=fast
if [ "$(field LANE)" = "fast" ] && [ "$(field CODE)" = "lane-decided" ] && [ "$(field RC)" = "1" ]; then ok "the fast lane already granted → this lane decides nothing and leaves that grant untouched"; else bad "an earlier fast grant must be left untouched (lane=fast code=lane-decided rc=1), got lane='$(field LANE)' code='$(field CODE)' rc='$(field RC)'"; fi
# missing arguments
decide "$B" "$(bj task)" DRV_HEAD=;                  expect "empty head ref" normal bad-inputs

# ── 7. the short prompt: one reviewer, diff only, no suites ───────────────────────────────────────────────
echo "── 7. the short prompt (gate-review-task.lib.sh, GATE_REVIEW_PROMPT_MODE=task-rapida) ──"
PROMPT_LIB="$SELF_DIR/gate-review-task.lib.sh"
cat > "$T/render.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$1"
if [ "$2" = bead ]; then
  gate_render_review_task 1 1 feat/x author-1 rig-1 abc1234 "LENS: correctness" $'a.py\nb.py' "2 files changed" "FULL DIFF (complete)" $'diff --git a/a.py b/a.py\n+MARKER_DIFF_LINE = 1' /city ga-verdict bead
else
  gate_render_review_task 1 1 feat/x author-1 rig-1 abc1234 "LENS: correctness" $'a.py\nb.py' "2 files changed" "FULL DIFF (complete)" $'diff --git a/a.py b/a.py\n+MARKER_DIFF_LINE = 1' "" "" text
fi
EOF
render() { # <bead|text> [ENV=VAL ...]
  local m="$1"; shift
  env -u GATE_REVIEW_PROMPT_MODE "$@" "$B32" "$T/render.sh" "$PROMPT_LIB" "$m" 2>&1
}
P_DEF=$(render bead) || P_DEF=""
P_RAP=$(render bead GATE_REVIEW_PROMPT_MODE=task-rapida) || P_RAP=""
P_EMPTY=$(render bead GATE_REVIEW_PROMPT_MODE=) || P_EMPTY=""
P_BOGUS=$(render bead GATE_REVIEW_PROMPT_MODE=task-rapida-typo) || P_BOGUS=""
P_TEXT_DEF=$(render text) || P_TEXT_DEF=""
P_TEXT_RAP=$(render text GATE_REVIEW_PROMPT_MODE=task-rapida) || P_TEXT_RAP=""
[ -n "$P_DEF" ] && ok "the default prompt renders" || bad "the default prompt did not render"
[ "$P_EMPTY" = "$P_DEF" ] && ok "mode empty renders the default prompt byte for byte" || bad "mode empty must render the default prompt byte for byte"
[ "$P_BOGUS" = "$P_DEF" ] && ok "a mode the lib does not know renders the default prompt (a garbled switch never shortens what a reviewer is told)" || bad "an unknown mode must render the default prompt"
case "$P_DEF" in *"REFUTATION PASS"*"RUNNING TESTS"*) ok "the default prompt is still the full one (refutation pass, running-tests guidance)" ;; *) bad "the default prompt lost its full body" ;; esac
[ -n "$P_RAP" ] && [ "$P_RAP" != "$P_DEF" ] && ok "task-rapida renders a different prompt" || bad "task-rapida rendered the default prompt (or nothing)"
case "$P_RAP" in *MARKER_DIFF_LINE*) ok "  …it carries the diff" ;; *) bad "  …the short prompt must carry the diff" ;; esac
case "$P_RAP" in *"feat/x"*"author-1"*"abc1234"*) ok "  …it names the branch, the author (excluded) and the SHA" ;; *) bad "  …branch / author / SHA missing from the short prompt" ;; esac
case "$P_RAP" in *"reviewer 1 of 1 for branch: feat/x"*) ok "  …reviewer index / count / branch reach it the way they reach the full prompt" ;; *) bad "  …the short prompt must say which reviewer this is and for which branch" ;; esac
n_once=$(grep -c 'QUALITY GATE REVIEW' "$PROMPT_LIB" 2>/dev/null) || n_once=""
[ "$n_once" = "1" ] && ok "  …the lib still holds exactly one QUALITY GATE REVIEW heading (pre-gate-review.selftest counts it: one copy of the prompt)" || bad "  …the short body must not repeat the QUALITY GATE REVIEW heading (found '$n_once')"
case "$P_RAP" in *"DO NOT run test suites"*) ok "  …it forbids running suites" ;; *) bad "  …it must tell the reviewer NOT to run suites" ;; esac
case "$P_RAP" in *"ONLY the tests that this diff itself adds or changes"*) ok "  …it allows only the tests the diff adds or changes" ;; *) bad "  …it must allow only the tests the diff itself adds or changes" ;; esac
case "$P_RAP" in *"3 minutes"*) ok "  …those tests have a cap of about 3 minutes" ;; *) bad "  …the tests need a cap of about 3 minutes" ;; esac
case "$P_RAP" in *"5 minutes"*) ok "  …the verdict is asked for in about 5 minutes" ;; *) bad "  …the verdict needs the 5-minute target" ;; esac
case "$P_RAP" in *"reports success when the operation failed"*) ok "  …it keeps the third-state family as a blocker" ;; *) bad "  …the third-state family must still block in the short prompt" ;; esac
case "$P_RAP" in *"gate:normal-only"*) ok "  …a diff that turns out to touch messages / money / customer data is sent back with the label that keeps it in the normal gate" ;; *) bad "  …the scope check must tell the builder about gate:normal-only" ;; esac
case "$P_RAP" in *"out of the task-rapida scope"*) ok "  …the scope check has its own FAIL wording" ;; *) bad "  …the scope check needs the out-of-scope FAIL wording" ;; esac
case "$P_RAP" in *"RUNNING TESTS"*|*"REFUTATION PASS"*) bad "  …the short prompt still carries the long guidance" ;; *) ok "  …none of the long guidance is left in it" ;; esac
apos=$(printf '%s' "$P_RAP" | tr -cd "'" | wc -c | tr -d ' ')
[ "$apos" = "0" ] && ok "  …zero apostrophes (the invariant of the prompt lib)" || bad "  …the short prompt has $apos apostrophe(s)"
# the verdict is recorded the same way: the tail of both prompts, from the line that starts it, is the normal gate's
tail_def=$(printf '%s\n' "$P_DEF" | sed -n '/^After completing your review/,$p'); tail_rap=$(printf '%s\n' "$P_RAP" | sed -n '/^After completing your review/,$p')
if [ -n "$tail_def" ] && [ "$tail_def" = "$tail_rap" ]; then ok "  …the verdict tail (where the verdict is recorded) is the normal gate's, byte for byte"; else bad "  …the verdict tail must be identical to the default's"; fi
[ "$P_TEXT_DEF" != "$P_TEXT_RAP" ] && ok "  …the builder (text mode) can ask for it too" || bad "  …text mode ignores the short mode"
case "$P_TEXT_RAP" in *"DO NOT run test suites"*"FINAL TEXT"*) ok "  …and keeps its own tail (the verdict as final text)" ;; *) bad "  …text mode with the short mode should carry the short body and the text tail" ;; esac

# ── 8. the code list and the cases agree ─────────────────────────────────────────────────────────────────────
echo "── 8. every code has a case, every case names a real code ──"
LIB_CODES=$("$B32" -c 'source "$1"; gate_taskrapida_codes | cut -f1' _ "$LIB" 2>/dev/null) || LIB_CODES=""
# a case names its code either through expect (lane + code) or, for the one that needs a custom check, with field CODE
CASE_CODES=$({ sed -En 's/.*expect "[^"]*" (normal|task-rapida|fast) ([a-z0-9-]+).*/\2/p' "${BASH_SOURCE[0]}"; sed -En 's/.*\[ "\$\(field CODE\)" = "([a-z0-9-]+)" \].*/\1/p' "${BASH_SOURCE[0]}"; } | sort -u)
[ -n "$LIB_CODES" ] && ok "the lib lists its codes ($(printf '%s\n' "$LIB_CODES" | wc -l | tr -d ' '))" || bad "gate_taskrapida_codes printed nothing"
# three codes are the dispatcher's own (its block sets them when the lib is missing, the dispatcher's file list is empty, or the lib's answer is
# not one it can trust): they are exercised by the wiring cases of section 9, not by the decision driver, and each must be set in the dispatcher
DISPATCHER_CODES="lib-not-loaded no-changed-files decision-errored"
for c in $LIB_CODES; do
  case " $DISPATCHER_CODES " in *" $c "*) continue ;; esac
  if printf '%s\n' "$CASE_CODES" | grep -qx "$c"; then ok "code with a case: $c"; else bad "code with NO case in this selftest: $c"; fi
done
for c in $CASE_CODES; do
  if printf '%s\n' "$LIB_CODES" | grep -qx "$c"; then :; else bad "a case expects the code '$c' but gate_taskrapida_codes does not list it"; fi
done
for c in $DISPATCHER_CODES; do
  if printf '%s\n' "$LIB_CODES" | grep -qx "$c"; then ok "dispatcher-level code listed by the lib: $c"; else bad "dispatcher-level code '$c' is not in gate_taskrapida_codes (the tally would not know the bucket)"; fi
  if grep -q "GATE_TR_CODE=\"$c\"" "$DISPATCHER"; then ok "the dispatcher sets GATE_TR_CODE=$c on its own path"; else bad "the dispatcher never sets GATE_TR_CODE=\"$c\""; fi
done
# the weekly tally (python) buckets the lane's refusals by its own copy of this list: same codes, same words. A tally that does not know
# a code files it under "outro", so a code added here and not there is a refusal nobody can read; and a reworded label is a different report
# (ga-dzzqvw.1). Mutation below: the check can fail.
LIB_LIST=$("$B32" -c 'source "$1"; gate_taskrapida_codes' _ "$LIB" 2>/dev/null | sort) || LIB_LIST=""
TALLY_PY="$SELF_DIR/gate-lane-tally.py"
TALLY_LIST=$(python3 "$TALLY_PY" --list-tr-codes 2>/dev/null | sort) || TALLY_LIST=""
if [ -n "$LIB_LIST" ] && [ "$LIB_LIST" = "$TALLY_LIST" ]; then ok "the tally lists exactly the lib's codes and labels ($(printf '%s\n' "$LIB_LIST" | wc -l | tr -d ' '))"
else bad "the tally's TR_REASON_CODES and gate_taskrapida_codes differ: $(diff <(printf '%s\n' "$LIB_LIST") <(printf '%s\n' "$TALLY_LIST") | head -6 | tr '\n' ' ')"; fi
sed 's/"over-limit": *"[^"]*"/"over-limit": "reworded"/' "$TALLY_PY" > "$T/tally-mut.py"
[ "$(python3 "$T/tally-mut.py" --list-tr-codes 2>/dev/null | sort)" != "$LIB_LIST" ] && ok "mutation: a reworded label in the tally IS seen as a difference" || bad "mutation: the drift check cannot tell a reworded label apart"
sed '/^    "decision-errored":/d' "$TALLY_PY" > "$T/tally-mut2.py"
[ "$(python3 "$T/tally-mut2.py" --list-tr-codes 2>/dev/null | sort)" != "$LIB_LIST" ] && ok "mutation: a code missing from the tally IS seen as a difference" || bad "mutation: the drift check cannot tell a missing code apart"

# ── 9. the dispatcher wiring: the blocks it runs, extracted verbatim ─────────────────────────────────────────
echo "── 9. dispatcher wiring ──"
TR_LOADBLK="$(extract_block "$DISPATCHER" taskrapida-lib-load)"
TR_DECBLK="$(extract_block "$DISPATCHER" taskrapida-decide)"
RECBLK="$(extract_block "$DISPATCHER" fastlane-record)"
for n in TR_LOADBLK TR_DECBLK RECBLK; do
  if [ -n "${!n}" ]; then ok "located the dispatcher block $n ($(printf '%s\n' "${!n}" | wc -l | tr -d ' ') lines)"; else bad "dispatcher block $n not found (sentinels missing/renamed)"; fi
done

# 9a. lib load: present / missing / unreadable / syntax error — the daemon must survive all four, and only "present" loads the decision
tr_load_case() { # name setup-cmd want
  local d="$T/trload-$1" out
  mkdir -p "$d"
  { printf 'set -euo pipefail\n'; printf '%s\n' "$TR_LOADBLK"; printf 'if declare -F gate_taskrapida_decide >/dev/null 2>&1; then echo LOADED; else echo ABSENT; fi\necho ALIVE\n'; } > "$d/disp.sh"
  eval "$2"
  out=$("$B32" "$d/disp.sh" 2>/dev/null | tr '\n' ' ') || out="DIED($out)"
  case "$out" in "$3 ALIVE ") ok "lib load: $1 → $3, daemon alive" ;; *) bad "lib load: $1 → '$out', want '$3 ALIVE'" ;; esac
}
tr_load_case present    'cp "$LIB" "$d/gate-taskrapida.lib.sh"'                                        LOADED
tr_load_case missing    ':'                                                                            ABSENT
tr_load_case unreadable 'cp "$LIB" "$d/gate-taskrapida.lib.sh"; chmod 000 "$d/gate-taskrapida.lib.sh"' ABSENT
tr_load_case syntaxerr  'printf "if then fi\n" > "$d/gate-taskrapida.lib.sh"'                          ABSENT
tr_load_case truncated  'head -c 900 "$LIB" > "$d/gate-taskrapida.lib.sh"; printf "gate_taskrapida_x() {\n" >> "$d/gate-taskrapida.lib.sh"' ABSENT

# 9b. the decision block, with the lib's answer stubbed: what the dispatcher does with each kind of answer
# The run is set up as a CODE-tier run with 2 reviewers, so "rev=1" can only come from the grant, and a refusal shows the tier untouched.
tr_dec() { # <name> <stub-setup> <want> [ENV=VAL ...]
  local name="$1" stub="$2" want="$3" out; shift 3
  { cat <<'HDR'
set -euo pipefail
git_rig() { :; }
log() { :; }
warn() { :; }
bd() { printf '%s\n' "$*" >> "$TR_BD_LOG"; printf '%s' "${TR_FAKE_BEAD:-}"; [ "${TR_FAKE_BD_FAIL:-0}" != 1 ]; }
DEFAULT_BRANCH=main; BRANCH_SHA=abc123; POLICY_FILES=""; TIER="CODE"; REQUIRED_REVIEWERS=2; RIG=gascity
GC_CITY=/city; BEAD_CITY=/beadcity; BEAD_ID=ga-x
CHANGED_FILES="src/a.py"
GATE_LANE="normal"; GATE_LANE_REASON="fast-reason"; GATE_LANE_REASON_CODE="not-fast"; GATE_LANE_FILES="f"; GATE_LANE_COUNTS="c"
GATE_REVIEW_PROMPT_MODE="stale"; GATE_TR_CODE="stale"; GATE_TR_WHY="stale"; GATE_TR_LINES="999"
HDR
    printf '%s\n' "$stub"
    printf '%s\n' "$TR_DECBLK"
    printf 'echo "RESULT lane=$GATE_LANE tier=$TIER rev=$REQUIRED_REVIEWERS mode=${GATE_REVIEW_PROMPT_MODE:-} trcode=${GATE_TR_CODE:-} reason=$GATE_LANE_REASON rcode=$GATE_LANE_REASON_CODE"\n'
  } > "$T/trdec.sh"
  : > "$T/trbd.log"
  out=$(env TR_BD_LOG="$T/trbd.log" "$@" "$B32" "$T/trdec.sh" 2>&1 | tail -1) || out="DIED"
  if [ "$out" = "RESULT $want" ]; then ok "decide block: $name"; else bad "decide block: $name → '$out', want 'RESULT $want'"; fi
}
GRANT_STUB='gate_taskrapida_decide() { GATE_LANE=task-rapida; GATE_LANE_REASON=granted-stub; GATE_LANE_REASON_CODE=task-rapida-granted; GATE_TR_CODE=granted; GATE_TR_LINES=5; return 0; }'
REFUSED_NORMAL="lane=normal tier=CODE rev=2 mode= "
tr_dec "the lib grants → lane task-rapida, tier TASK-RAPIDA, ONE reviewer, the short prompt" "$GRANT_STUB" \
  "lane=task-rapida tier=TASK-RAPIDA rev=1 mode=task-rapida trcode=granted reason=granted-stub rcode=task-rapida-granted"
tr_dec "the lib refuses (rc=1) → the normal gate untouched: tier, reviewers, the fast lane's reason; the prompt mode of an earlier round cleared" \
  'gate_taskrapida_decide() { GATE_TR_CODE=risk-file; GATE_TR_WHY=w; GATE_TR_LINES=150; return 1; }' \
  "${REFUSED_NORMAL}trcode=risk-file reason=fast-reason rcode=not-fast"
tr_dec "the lib returns a lane that is not task-rapida → normal, decision-errored, the reason it had kept" \
  'gate_taskrapida_decide() { GATE_LANE=banana; GATE_LANE_REASON=junk; GATE_TR_CODE=granted; return 0; }' \
  "${REFUSED_NORMAL}trcode=decision-errored reason=fast-reason rcode=not-fast"
tr_dec "the lib ERRORS after setting the grant (rc=7) → normal, decision-errored, nothing it wrote survives" \
  'gate_taskrapida_decide() { GATE_LANE=task-rapida; GATE_LANE_REASON=junk; GATE_LANE_REASON_CODE=task-rapida-granted; GATE_TR_CODE=granted; return 7; }' \
  "${REFUSED_NORMAL}trcode=decision-errored reason=fast-reason rcode=not-fast"
tr_dec "rc=0 but the lib says it refused (lane task-rapida with code risk-file): contradictory → normal, decision-errored" \
  'gate_taskrapida_decide() { GATE_LANE=task-rapida; GATE_LANE_REASON=junk; GATE_TR_CODE=risk-file; return 0; }' \
  "${REFUSED_NORMAL}trcode=decision-errored reason=fast-reason rcode=not-fast"
tr_dec "rc=1 with no code at all → normal, decision-errored (a refusal nobody can name is not recorded as one)" \
  'gate_taskrapida_decide() { return 1; }' \
  "${REFUSED_NORMAL}trcode=decision-errored reason=fast-reason rcode=not-fast"
tr_dec "the lib is not loaded → normal, lib-not-loaded" ':' \
  "${REFUSED_NORMAL}trcode=lib-not-loaded reason=fast-reason rcode=not-fast"
tr_dec "the dispatcher's own file list is EMPTY (git error) though the lib would grant → normal, no-changed-files" \
  "CHANGED_FILES=\"\"; $GRANT_STUB" \
  "${REFUSED_NORMAL}trcode=no-changed-files reason=fast-reason rcode=not-fast"
tr_dec "the fast lane already took the run → left exactly as it was, the lib is never asked, no refusal recorded" \
  "GATE_LANE=fast; TIER=FAST-LANE; REQUIRED_REVIEWERS=0; gate_taskrapida_decide() { echo LIB-WAS-CALLED >> \"\$TR_BD_LOG\"; GATE_LANE=task-rapida; GATE_TR_CODE=granted; return 0; }" \
  "lane=fast tier=FAST-LANE rev=0 mode= trcode= reason=fast-reason rcode=not-fast"
case "$(cat "$T/trbd.log" 2>/dev/null)" in *LIB-WAS-CALLED*|*" show "*) bad "a run the fast lane took must not cost a bd read or a lib call: $(cat "$T/trbd.log")" ;; *) ok "  …and it cost no bd read and no lib call" ;; esac
# what the lib is handed
ARGS_STUB='gate_taskrapida_decide() { printf "ARGS %s|%s|%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" "$5" "$6" >> "$TR_BD_LOG"; GATE_TR_CODE=risk-file; return 1; }'
tr_dec "args case" "POLICY_FILES=quality-gate-x.sh; $ARGS_STUB" "${REFUSED_NORMAL}trcode=risk-file reason=fast-reason rcode=not-fast" TR_FAKE_BEAD='[{"issue_type":"task"}]'
BDLOG=$(cat "$T/trbd.log" 2>/dev/null)
case "$BDLOG" in *'ARGS git_rig|origin/main|abc123|[{"issue_type":"task"}]|gascity|quality-gate-x.sh'*) ok "  …the lib gets (git_rig, origin/<default>, the claimed SHA, the bead JSON, the rig, the policy files)" ;; *) bad "  …the lib was handed something else: $BDLOG" ;; esac
case "$BDLOG" in *"-C /beadcity show ga-x --json"*) ok "  …the source bead is read from ITS store (BEAD_CITY), not the HQ's" ;; *) bad "  …the bead was not read from BEAD_CITY: $BDLOG" ;; esac
tr_dec "bd fails after printing part of an answer" "$ARGS_STUB" "${REFUSED_NORMAL}trcode=risk-file reason=fast-reason rcode=not-fast" TR_FAKE_BEAD='[{"issue_type":"task"' TR_FAKE_BD_FAIL=1
case "$(cat "$T/trbd.log" 2>/dev/null)" in *'ARGS git_rig|origin/main|abc123||gascity|'*) ok "  …a failed bd read is handed over as EMPTY (never the half answer): the lib then says type-unreadable" ;; *) bad "  …a failed bd read must reach the lib as an empty string: $(cat "$T/trbd.log")" ;; esac
tr_dec "BEAD_CITY unset → the HQ store is the fallback" "unset BEAD_CITY; $ARGS_STUB" "${REFUSED_NORMAL}trcode=risk-file reason=fast-reason rcode=not-fast"
case "$(cat "$T/trbd.log" 2>/dev/null)" in *"-C /city show ga-x --json"*) ok "  …bd -C falls back to GC_CITY" ;; *) bad "  …no fallback to GC_CITY: $(cat "$T/trbd.log")" ;; esac

# (no end-to-end case with the real lib behind the dispatcher block: section 1 proves the lib on real git, 9b proves the block and the argument order it hands the lib)

# 9d. the recorder: the marker gets the lane and the reason; the jsonl event gets the lane and the lane's own refusal code + measured lines
FL_LIB="$SELF_DIR/gate-fastlane.lib.sh"
cat > "$T/bin/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_BD_LOG:-/dev/null}"
case "$*" in *" show "*) printf '[{"id":"m","metadata":{"gate.lane":"%s"}}]\n' "${FAKE_BD_LANE:-}" ;; esac
exit 0
EOF
chmod +x "$T/bin/bd"
rec_tr() { # <qg_log> <setup-file> <lane-the-marker-reads-back> — the REAL gate_fastlane_record, stub bd first on PATH
  : > "$T/rec-bd.log"
  PATH="$T/bin:$PATH" FAKE_BD_LOG="$T/rec-bd.log" FAKE_BD_LANE="$3" "$B32" -c 'set -euo pipefail; source "$1"; . "$3"; gate_fastlane_record /city mk-1 ga-x feat/x gascity 2 "$2"' _ "$FL_LIB" "$1" "$2" >/dev/null 2>&1 || true
}
cat > "$T/rec-granted.sh" <<'EOF'
GATE_LANE=task-rapida; GATE_LANE_REASON="task of 150 production lines (limit 200)"; GATE_LANE_REASON_CODE=task-rapida-granted
GATE_LANE_COUNTS="prod=150 total=150 files=1"; GATE_LANE_FILES="src/a.py	150"; GATE_TR_CODE=granted; GATE_TR_LINES=150
EOF
cat > "$T/rec-refused.sh" <<'EOF'
GATE_LANE=normal; GATE_LANE_REASON="not doc or test"; GATE_LANE_REASON_CODE=code-or-prompt
GATE_LANE_COUNTS="c"; GATE_LANE_FILES=""; GATE_TR_CODE=risk-file; GATE_TR_LINES=150
EOF
cat > "$T/rec-notevaluated.sh" <<'EOF'
GATE_LANE=fast; GATE_LANE_REASON="docs only"; GATE_LANE_REASON_CODE=""; GATE_LANE_COUNTS="doc=1"; GATE_LANE_FILES=""
unset GATE_TR_CODE GATE_TR_LINES
EOF
RQ="$T/rec-granted.jsonl"; : > "$RQ"; rec_tr "$RQ" "$T/rec-granted.sh" task-rapida
[ "$(tail -1 "$RQ" | jq -r '[.event,.lane,.reason_code,.would_have_reviewers,.counts,.tr_code,.tr_lines]|join("|")' 2>/dev/null)" = "gate_lane|task-rapida|task-rapida-granted|2|prod=150 total=150 files=1|granted|150" ] \
  && ok "granted: ONE gate_lane event with lane=task-rapida, the reviewers a normal run would have used (2), the counts, tr_code=granted, tr_lines=150" || bad "granted event: $(cat "$RQ")"
[ "$(wc -l < "$RQ" | tr -d ' ')" = "1" ] && ok "  …exactly one event for the decision (the tally counts events)" || bad "  …more than one event for one decision: $(cat "$RQ")"
RB=$(cat "$T/rec-bd.log")
for kv in "gate.lane=task-rapida" "gate.lane_reason=task of 150 production lines (limit 200)" "gate.tr_code=granted"; do
  case "$RB" in *"--set-metadata $kv"*) ok "  …the marker carries $kv" ;; *) bad "  …marker lacks $kv: $RB" ;; esac
done
RQ2="$T/rec-refused.jsonl"; : > "$RQ2"; rec_tr "$RQ2" "$T/rec-refused.sh" normal
[ "$(tail -1 "$RQ2" | jq -r '[.lane,.reason_code,.tr_code,.tr_lines]|join("|")' 2>/dev/null)" = "normal|code-or-prompt|risk-file|150" ] \
  && ok "refused: lane=normal keeps the fast lane's reason_code, and the lane's own refusal rides in tr_code / tr_lines (the fast lane's tally buckets are not polluted)" || bad "refused event: $(cat "$RQ2")"
RQ3="$T/rec-notevaluated.jsonl"; : > "$RQ3"; rec_tr "$RQ3" "$T/rec-notevaluated.sh" fast
[ "$(tail -1 "$RQ3" | jq -r '[.lane,(if has("tr_code") then .tr_code else "ABSENT" end),(if has("tr_lines") then .tr_lines else "ABSENT" end)]|join("|")' 2>/dev/null)" = "fast||" ] \
  && ok "not evaluated (the fast lane took the run): tr_code and tr_lines are empty, and an unset GATE_TR_CODE does not kill the recorder under set -u" || bad "not-evaluated event: $(cat "$RQ3")"
case "$(cat "$T/rec-bd.log")" in *"gate.tr_code"*) bad "  …no tr_code should be written to the marker when the lane never decided" ;; *) ok "  …and no gate.tr_code is written to the marker" ;; esac

# 9e. the fallback event (lib not loaded): the dispatcher writes it itself and it must carry the same two fields
recfb_tr() { # <qg_log> <tr_code>
  { cat <<'HDR'
set -euo pipefail
GC_CITY=/city; MARKER_ID=mk-9; BEAD_ID=ga-x; BRANCH=feat/x; RIG=gascity
GATE_LANE=normal; GATE_LANE_REASON="fast-lane lib not loaded"; GATE_LANE_REASON_CODE=lib-not-loaded
HDR
    printf 'QG_LOG=%q; GATE_LANE_WOULD_REVIEWERS=2; DRY_RUN=0; GATE_TR_CODE=%q; GATE_TR_LINES=\n' "$1" "$2"
    printf '%s\n' "$RECBLK"
  } > "$T/recfb-tr.sh"
  "$B32" "$T/recfb-tr.sh" >/dev/null 2>&1 || true
}
RF="$T/recfb-tr.jsonl"; : > "$RF"; recfb_tr "$RF" lib-not-loaded
[ "$(tail -1 "$RF" | jq -r '[.event,.lane,.reason_code,.tr_code,.tr_lines]|join("|")' 2>/dev/null)" = "gate_lane|normal|lib-not-loaded|lib-not-loaded|" ] \
  && ok "fallback event (no fast-lane lib): one gate_lane event that carries tr_code too" || bad "fallback event: $(cat "$RF")"

# 9f. where the blocks sit
L_FLD_E=$(grep -n 'SELFTEST-EXTRACT fastlane-decide: END' "$DISPATCHER" | head -1 | cut -d: -f1)
L_TRD_B=$(grep -n 'SELFTEST-EXTRACT taskrapida-decide: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_TRD_E=$(grep -n 'SELFTEST-EXTRACT taskrapida-decide: END' "$DISPATCHER" | head -1 | cut -d: -f1)
L_REC_B=$(grep -n 'SELFTEST-EXTRACT fastlane-record: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_S6=$(grep -n '^# ── Step 6: Create gate-run tracking bead' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$L_FLD_E" ] && [ -n "$L_TRD_B" ] && [ -n "$L_TRD_E" ] && [ -n "$L_REC_B" ] && [ -n "$L_S6" ] && [ "$L_FLD_E" -lt "$L_TRD_B" ] && [ "$L_TRD_E" -lt "$L_REC_B" ] && [ "$L_REC_B" -lt "$L_S6" ]; then
  ok "the lane decision (lines $L_TRD_B-$L_TRD_E) comes after the fast lane's (ends line $L_FLD_E) and before the record (line $L_REC_B) and Step 6 (line $L_S6)"
else bad "lane decision placement: fast-decide-end=$L_FLD_E task-rapida=$L_TRD_B-$L_TRD_E record=$L_REC_B step6=$L_S6"; fi
L_TRL=$(grep -n 'SELFTEST-EXTRACT taskrapida-lib-load: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
L_GUARD=$(grep -n 'GATE_GUARD_LIB_ONLY=1' "$DISPATCHER" | head -1 | cut -d: -f1)   # E11's counter comes from the guard sourced lib-only: declared BEFORE the decision runs
{ [ -n "$L_TRL" ] && [ -n "$L_GUARD" ] && [ -n "$L_TRD_B" ] && [ "$L_TRL" -lt "$L_TRD_B" ] && [ "$L_GUARD" -lt "$L_TRD_B" ]; } && ok "the lib (line $L_TRL) and E11's counter (line $L_GUARD) are both loaded before the decision (line $L_TRD_B)" || bad "load placement: lib=$L_TRL guard=$L_GUARD decision=$L_TRD_B"
# only the fast lane is special downstream: everything that is not exactly "fast" takes the normal merge path
BAD_LANE_USES=$(grep -n 'GATE_LANE' "$DISPATCHER" | grep -F 'task-rapida' | awk -F: -v b="${L_TRD_B:-0}" -v e="${L_TRD_E:-0}" '($1 < b || $1 > e) && $0 !~ /^[0-9]+:[[:space:]]*#/' || true)
[ -z "$BAD_LANE_USES" ] && ok "no line outside the lane's own block treats GATE_LANE=task-rapida specially (the merge path is the normal gate's)" || bad "something else in the dispatcher special-cases task-rapida: $BAD_LANE_USES"

echo
echo "gate-taskrapida.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
