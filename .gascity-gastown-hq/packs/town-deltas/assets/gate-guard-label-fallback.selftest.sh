#!/usr/bin/env bash
# gate-guard-label-fallback.selftest.sh — ga-nt0b18f: the guard vets a marker whose routing lives in its LABELS (oracle-wa's shape).
#
# THE BUG. A marker submitted outside /gate-done's canonical writer — routing in the labels branch:<val>, source-bead:<val>, bead-rig:<val> and a
# human-prose description — has no `branch:` / `bead_id:` / `rig:` line for the guard's extract() to read. The guard answered with Step 4's refusal,
# and Step 4 wrote its "Gate guard rejected marker:" comment ONLY when bead_id was known. So the marker sat in gate-status:error with nothing on it
# saying the guard had refused it on purpose; gate-recovery-watchdog read that as a transient error and re-queued it (it does not re-queue a marker
# whose comments carry that one, ga-hp4wrx), and the dispatcher, whose own ga-9oxah label fallback resolves the fields, reviewed it. Every
# check the guard runs after Step 4 was skipped for it: 4b dedup, the E11 caps, the A/B base test, the bash 3.2 check, the skill-token check and the
# four hard checks 2b-2e, so step 2e never drew or recorded an arm (the 24/11 alarm gate:3o-estado-braco-nao-gravado: 8 of 71 beads, all crew/oracle/*).
#
# THE FIX under test, in two parts: (1) Step 3 reads a field from its label when the description line came back empty (the dispatcher's rule, the
# same three labels); (2) Step 4's refusal comment goes on the marker whether or not bead_id is known, so the watchdog tells the author (else the
# Mayor) instead of re-queueing past the guard.
#
# STRATEGY. The live blocks between the SELFTEST-EXTRACT sentinels (marker-fields, field-validation, rig-path, hardchecks) are cut out of the guard
# and EXECUTED here under the guard's own `set -euo pipefail`, with the guard's real validate_branch / validate_bead_id / validate_rig and the real
# gate-hard-checks.sh over a real git origin; only log/err/warn/set_gate_status/bd/gc are stubbed. The end-to-end case chains the four blocks in
# the guard's order for a crew/oracle/<bead> marker and then asks the ALARM'S OWN readers (third-state-arm-coverage.py guard_lines / scan_arms)
# whether they see the HARDCHECK step=2e line and the arm row for it: the same two sources the alarm uses to decide "sem braco".
# Run it against the pre-fix guard (GATE_GUARD_SUT=<old copy>) and it stops at section A: the blocks are not there.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GATE_GUARD_SUT:-$SELF_DIR/quality-gate-guard.sh}"
CHECKER="${GHC_SUT:-$SELF_DIR/gate-hard-checks.sh}"
RHQ="${GHC_HQ:-$(cd "$SELF_DIR/../../.." && pwd)}"
ALARM="$SELF_DIR/third-state-arm-coverage.py"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }          # has <file> <fixed string>
hasnt() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
fatal() { echo "FATAL: $*"; echo; echo "gate-guard-label-fallback selftest: $PASS passed, $FAIL failed"; exit 1; }

for f in "$GUARD" "$CHECKER" "$RHQ/scripts/doc-rules-lint.py" "$RHQ/packs/town-deltas/assets/third-state-reads-check.py" "$ALARM"; do [ -f "$f" ] || fatal "missing $f"; done
command -v jq >/dev/null 2>&1 || fatal "jq is required"
command -v python3 >/dev/null 2>&1 || fatal "python3 is required"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/guard-lblfb-selftest.XXXXXX")" || fatal "no scratch dir"
trap 'rm -rf "$WORK"' EXIT

echo "A. the live blocks are extractable and parse"
MISSING=""
for n in marker-fields field-validation rig-path hardchecks; do
  b=$(grep -c "^# SELFTEST-EXTRACT $n: BEGIN\$" "$GUARD"); e=$(grep -c "^# SELFTEST-EXTRACT $n: END\$" "$GUARD")
  if [ "$b/$e" = "1/1" ]; then ok "sentinels '$n' present exactly once each"; else bad "sentinels '$n': BEGIN=$b END=$e (want 1/1)"; MISSING="$MISSING $n"; fi
done
[ -z "$MISSING" ] || fatal "block(s)$MISSING not in $GUARD: this guard has no label fallback, so nothing below can run"
blk() { sed -n "/^# SELFTEST-EXTRACT $2: BEGIN\$/,/^# SELFTEST-EXTRACT $2: END\$/p" "$1" | sed '1d;$d'; }
B_FIELDS="$WORK/fields.sh"; B_VALID="$WORK/valid.sh"; B_RIGPATH="$WORK/rigpath.sh"; B_HARD="$WORK/hard.sh"
blk "$GUARD" marker-fields > "$B_FIELDS"; blk "$GUARD" field-validation > "$B_VALID"; blk "$GUARD" rig-path > "$B_RIGPATH"; blk "$GUARD" hardchecks > "$B_HARD"
for f in "$B_FIELDS" "$B_VALID" "$B_RIGPATH" "$B_HARD"; do
  [ -s "$f" ] && bash -n "$f" 2>/dev/null || fatal "block $(basename "$f") is empty or does not parse"
done
ok "all four blocks extracted and parse"
VR_FILE="$WORK/validate_rig.sh"      # validate_rig lives below the lib-only cutoff, so it is cut out too: the real one, not a stub
awk '/^validate_rig\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$GUARD" > "$VR_FILE"
[ -s "$VR_FILE" ] && bash -n "$VR_FILE" 2>/dev/null || fatal "validate_rig() not found in the guard"
ok "the guard's real validate_rig() is cut out"

# a marker row shaped like `bd list --json` returns it
mk() { jq -cn --arg d "$1" --argjson l "$2" '{id:"ga-fixture1",title:"ready-for-gate: x",status:"open",issue_type:"chore",description:$d,labels:$l}'; }
D_PROSE='Gate fix 1: the screen keeps the last good reading when the new read fails; tests for each case.'
D_CANON=$'branch: fix/wa-fx0002-thing\nbead_id: wa-fx0002\nauthor: dog\nbase_commit: 0123abcd\nrig: whatsapp_automation\nbead_rig: whatsapp_automation\nsubmitted_at: 2026-11-25T00:00:00Z\nself_audit: checked'
L_ORACLE='["bead-rig:whatsapp_automation","branch:crew/oracle/wa-fx0001","gate-status:claimed","source-bead:wa-fx0001","type:quality-gate-marker"]'
RES_ORACLE="RESULT|branch=crew/oracle/wa-fx0001|bead_id=wa-fx0001|rig=whatsapp_automation|"

run_fields() { # run_fields <marker_json> [block]: the live Step 3 under the guard's flags; prints its log lines and a RESULT line
  MARKER="$1" BLK="${2:-$B_FIELDS}" bash -c '
    set -euo pipefail
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*"; }
    MARKER_ID="ga-fixture1"
    . "$BLK"
    echo "RESULT|branch=${BRANCH}|bead_id=${BEAD_ID}|rig=${RIG}|author=${MARKER_AUTHOR}|base=${BASE_COMMIT}|bead_rig=${BEAD_RIG}|"
  ' 2>&1
}

echo "B. Step 3 (marker-fields): each field comes from its description line, and from its label only when that line is empty"
O="$WORK/b1"; run_fields "$(mk "$D_PROSE" "$L_ORACLE")" > "$O"; RC=$?
[ "$RC" = 0 ] && ok "the oracle-wa shape survives the guard's set -euo pipefail" || bad "oracle shape: rc=$RC :: $(head -3 "$O" | tr '\n' '|')"
has "$O" "$RES_ORACLE" && ok "branch, bead_id and rig are resolved from branch:, source-bead: and bead-rig:" || bad "oracle shape resolved: $(grep RESULT "$O")"
has "$O" "resolved from label 'branch:crew/oracle/wa-fx0001'" && has "$O" "resolved from label 'source-bead:wa-fx0001'" && has "$O" "resolved from label 'bead-rig:whatsapp_automation'" \
  && ok "each fallback is logged (the sweep log now names the bead for these markers)" || bad "fallback log lines: $(grep LOG "$O" | tr '\n' '|')"
has "$O" "|author=|base=|bead_rig=|" && ok "fields that have no label stay empty (author, base_commit, bead_rig are not invented)" || bad "unexpected values: $(grep RESULT "$O")"

O="$WORK/b2"; run_fields "$(mk "$D_CANON" '["bead-rig:gascity","branch:crew/oracle/wa-other","source-bead:wa-other"]')" > "$O"
has "$O" "RESULT|branch=fix/wa-fx0002-thing|bead_id=wa-fx0002|rig=whatsapp_automation|author=dog|base=0123abcd|bead_rig=whatsapp_automation|" && hasnt "$O" "resolved from label" \
  && ok "a canonical marker is untouched: the description wins over labels that disagree, and nothing is logged" || bad "canonical precedence: $(cat "$O" | tr '\n' '|')"

D_NORIG=$'branch: fix/wa-fx0005-thing\nbead_id: wa-fx0005'
L_NORIG='["bead-rig:whatsapp_automation","branch:crew/oracle/wa-other","source-bead:wa-other"]'
O="$WORK/b2b"; run_fields "$(mk "$D_NORIG" "$L_NORIG")" > "$O"
has "$O" "RESULT|branch=fix/wa-fx0005-thing|bead_id=wa-fx0005|rig=whatsapp_automation|" && hasnt "$O" "label 'branch:" && hasnt "$O" "label 'source-bead:" \
  && ok "the fallback runs (rig is missing) and still never overrides a field the description has: branch and bead_id stay the description's" || bad "precedence with a missing rig: $(cat "$O" | tr '\n' '|')"

O="$WORK/b3"; run_fields "$(mk $'a human note\nbead_id: wa-fx0003\nmore prose' '["branch:crew/oracle/wa-fx0003","bead-rig:whatsapp_automation","source-bead:wa-zzzzzz"]')" > "$O"
has "$O" "RESULT|branch=crew/oracle/wa-fx0003|bead_id=wa-fx0003|rig=whatsapp_automation|" && ok "partial: the label fills only the missing fields (bead_id stays the description's, not the label's)" || bad "partial: $(grep RESULT "$O")"

O="$WORK/b4"; run_fields "$(mk $'branch:\nbead_id: wa-fx0004\nrig:   ' '["branch:crew/oracle/wa-fx0004","bead-rig:whatsapp_automation"]')" > "$O"
has "$O" "RESULT|branch=crew/oracle/wa-fx0004|bead_id=wa-fx0004|rig=whatsapp_automation|" && ok "a description line with an empty value counts as missing" || bad "empty line: $(grep RESULT "$O")"

O="$WORK/b5"; run_fields "$(mk "$D_PROSE" '["gate-status:claimed","type:quality-gate-marker"]')" > "$O"; RC=$?
[ "$RC" = 0 ] && has "$O" "RESULT|branch=|bead_id=|rig=|" && hasnt "$O" "resolved from label" && hasnt "$O" "WARN" \
  && ok "labels with no routing: fields stay empty, no abort (a no-match grep must not kill the sweep), no warning: empty is a read that answered" || bad "no routing: rc=$RC :: $(cat "$O" | tr '\n' '|')"

O="$WORK/b6"; run_fields "$(jq -cn '{id:"ga-fixture1",description:"x"}')" > "$O"; RC=$?
[ "$RC" = 0 ] && has "$O" "RESULT|branch=|bead_id=|rig=|" && hasnt "$O" "WARN" && ok "a marker row with no labels key reads as no labels (not a failed read)" || bad "no labels key: rc=$RC :: $(cat "$O" | tr '\n' '|')"

O="$WORK/b7"; run_fields "$(mk "$D_PROSE" '["source-bead-type:epic","bead-rig-note:x","branchy:foo","xbranch:foo","source-bead"]')" > "$O"
has "$O" "RESULT|branch=|bead_id=|rig=|" && ok "the colon anchors the prefix: source-bead-type:, bead-rig-note:, branchy: and a bare source-bead are not routing" || bad "prefix boundary: $(grep RESULT "$O")"

L_UNKRIG='["bead-rig:unknown","branch:crew/oracle/wa-fx0006","source-bead:wa-fx0006"]'
O="$WORK/b7b"; run_fields "$(mk "$D_PROSE" "$L_UNKRIG")" > "$O"
has "$O" "RESULT|branch=crew/oracle/wa-fx0006|bead_id=wa-fx0006|rig=|" && hasnt "$O" "label 'bead-rig:" \
  && ok "bead-rig:unknown (/gate-done's could-not-determine sentinel) is not a rig: RIG stays empty, as before the fallback existed" || bad "unknown rig sentinel: $(grep -E 'RESULT|LOG' "$O" | tr '\n' '|')"

O="$WORK/b8"; run_fields "$(jq -cn --arg d "$D_PROSE" '{id:"ga-fixture1",description:$d,labels:"branch:crew/oracle/wa-fx0001"}')" > "$O"; RC=$?
[ "$RC" = 0 ] && has "$O" "RESULT|branch=|bead_id=|rig=|" && has "$O" "WARN: marker ga-fixture1: its labels could not be read" \
  && ok "labels that cannot be read (a string, not a list) say so in the log and resolve nothing: the failed read is not the empty one" || bad "unreadable labels: rc=$RC :: $(cat "$O" | tr '\n' '|')"

O="$WORK/b9"; run_fields "$(mk "$D_PROSE" '["branch:../../etc/passwd","source-bead:wa-fx0001;touch-x","bead-rig:whatsapp_automation"]')" > "$O"
has "$O" "RESULT|branch=../../etc/passwd|bead_id=wa-fx0001;touch-x|rig=whatsapp_automation|" && ok "label values are copied as data: judging them is Step 4's job (next section)" || bad "hostile labels: $(grep RESULT "$O")"

run_valid() { # run_valid <branch> <bead_id> <rig> [block]: the live Step 4 with the real validators; output on stdout, exit status in RC
  BRANCH_IN="$1" BEAD_IN="$2" RIG_IN="$3" BLK="${4:-$B_VALID}" GUARD="$GUARD" VR="$VR_FILE" bash -c '
    set -euo pipefail
    GATE_GUARD_LIB_ONLY=1 . "$GUARD"
    GC_CITY=/nonexistent-city
    log()  { echo "LOG: $*"; }
    err()  { echo "ERR: $*"; }
    warn() { echo "WARN: $*"; }
    set_gate_status() { echo "STATUS: $1 $2"; }
    bd() { echo "BD: $*"; }
    gc() { echo "{\"rigs\":[{\"name\":\"whatsapp_automation\",\"prefix\":\"wa\",\"path\":\"/nonexistent/wa\"},{\"name\":\"gascity\",\"prefix\":\"ga\",\"path\":\"/nonexistent/ga\"}]}"; }
    . "$VR"
    MARKER_ID="ga-fixture1"; BRANCH="$BRANCH_IN"; BEAD_ID="$BEAD_IN"; RIG="$RIG_IN"
    . "$BLK"
    echo "FELL-THROUGH"
  ' 2>&1
  RC=$?
}
REJ="BD: -C /nonexistent-city comment ga-fixture1 Gate guard rejected marker: invalid/unsafe field values."

echo "C. Step 4 (field-validation): label-sourced values pass the same validators, and a refusal always speaks"
V="$WORK/c1"; run_valid crew/oracle/wa-fx0001 wa-fx0001 whatsapp_automation > "$V"
[ "$RC" = 0 ] && has "$V" "FELL-THROUGH" && hasnt "$V" "STATUS" && ok "a crew branch + bead + rig resolved from labels is accepted" || bad "crew marker: rc=$RC :: $(cat "$V" | tr '\n' '|')"
V="$WORK/c2"; run_valid crew/oracle/wa-5d5wnv.1 wa-5d5wnv.1 whatsapp_automation > "$V"
[ "$RC" = 0 ] && has "$V" "FELL-THROUGH" && ok "a dotted sub-bead id (wa-5d5wnv.1) on a crew branch is accepted" || bad "dotted id: rc=$RC :: $(cat "$V" | tr '\n' '|')"
V="$WORK/c3"; run_valid "" "" "" > "$V"
[ "$RC" = 1 ] && hasnt "$V" "FELL-THROUGH" && has "$V" "STATUS: ga-fixture1 error" && ok "no branch, no bead, no rig anywhere: refused, marker set to gate-status:error" || bad "unroutable: rc=$RC :: $(cat "$V" | tr '\n' '|')"
has "$V" "$REJ" && ok "the refusal comment IS written with bead_id empty (it carries the prefix gate-recovery-watchdog holds a marker on)" || bad "no refusal comment when bead_id is empty :: $(grep '^BD' "$V" | cut -c1-100)"
has "$V" "source-bead:" && has "$V" "bead-rig:" && has "$V" "Fix the marker fields and re-submit" && ok "and it says where the fields were looked for (description lines, then the labels) and what to do" || bad "refusal text lacks the label hint"
V="$WORK/c4"; run_valid ../../etc/passwd "wa-fx0001;touch-x" whatsapp_automation > "$V"
[ "$RC" = 1 ] && has "$V" "STATUS: ga-fixture1 error" && has "$V" "$REJ" && has "$V" "branch='../../etc/passwd'" && ok "hostile label values are refused with the comment, and the comment shows what was read" || bad "hostile: rc=$RC :: $(cat "$V" | tr '\n' '|' | cut -c1-300)"
V="$WORK/c5"; run_valid crew/oracle/wa-fx0001 wa-fx0001 no_such_rig > "$V"
[ "$RC" = 1 ] && has "$V" "STATUS: ga-fixture1 error" && ok "a rig that is not registered is still refused" || bad "unknown rig: rc=$RC :: $(cat "$V" | tr '\n' '|' | cut -c1-300)"
V="$WORK/c5b"; run_valid crew/oracle/wa-fx0006 wa-fx0006 "" > "$V"
[ "$RC" = 0 ] && has "$V" "FELL-THROUGH" && ok "an empty rig is not validated (the rig is then derived from the bead id): what a marker with bead-rig:unknown still gets" || bad "empty rig: rc=$RC :: $(cat "$V" | tr '\n' '|' | cut -c1-300)"
V="$WORK/c5c"; run_valid crew/oracle/wa-fx0006 wa-fx0006 unknown > "$V"
[ "$RC" = 1 ] && has "$V" "STATUS: ga-fixture1 error" && ok "...while RIG=unknown would be refused by validate_rig: the reason the sentinel must not be read as a rig" || bad "RIG=unknown: rc=$RC :: $(cat "$V" | tr '\n' '|' | cut -c1-300)"
V="$WORK/c6"; run_valid main wa-fx0001 whatsapp_automation > "$V"
[ "$RC" = 0 ] && has "$V" "BD: -C /nonexistent-city close ga-fixture1" && hasnt "$V" "STATUS" && hasnt "$V" "FELL-THROUGH" && ok "branch=main keeps its own path: the marker is closed cleanly, exit 0 (not an error)" || bad "main: rc=$RC :: $(cat "$V" | tr '\n' '|' | cut -c1-300)"

echo "D. end to end: a crew/oracle/<bead> marker as Dolt returns it reaches step 2e, is recorded, and the alarm's own readers see it"
CITY0="$WORK/city0"; AS="$CITY0/packs/town-deltas/assets"
mkdir -p "$CITY0/scripts" "$AS" "$CITY0/.gc" && cp "$RHQ/scripts/doc-rules-lint.py" "$CITY0/scripts/" && cp "$CHECKER" "$AS/" || fatal "cannot build the fixture city"
for f in third-state-reads-check.py e12-crew-doctrine.sh e12-arms.sh template-fragment-lint-guard.sh; do cp "$RHQ/packs/town-deltas/assets/$f" "$AS/" || fatal "cannot build the fixture city ($f)"; done
for f in gate-hard-checks-imports.py gate-hard-checks-lint.py; do cp "$(dirname "$CHECKER")/$f" "$AS/" || fatal "cannot build the fixture city ($f beside the checker)"; done
printf 'mode=enforce\n' > "$CITY0/.gc/third-state-reads.conf"       # the arm is drawn and recorded only when the check is switched on
ORIGIN="$WORK/origin.git"; BUILD="$WORK/build"; RIGCLONE="$WORK/rigclone"
git init -q --bare "$ORIGIN" && git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
mkdir -p "$BUILD/lib" && git -C "$BUILD" init -q && git -C "$BUILD" symbolic-ref HEAD refs/heads/main
git -C "$BUILD" config user.email t@example.invalid; git -C "$BUILD" config user.name t; git -C "$BUILD" config commit.gpgsign false
printf 'x = 1\n' > "$BUILD/lib/app.py"
git -C "$BUILD" add -A && git -C "$BUILD" commit -q -m base && git -C "$BUILD" remote add origin "$ORIGIN" && git -C "$BUILD" push -q origin main
git clone -q "$ORIGIN" "$RIGCLONE" 2>/dev/null
push_branch() { # push_branch <name> <file> <content>   (branches from main)
  git -C "$BUILD" checkout -q -b "$1" main && printf '%b' "$3" > "$BUILD/$2" && git -C "$BUILD" add -A && git -C "$BUILD" commit -q -m "$1" && git -C "$BUILD" push -q origin "$1" && git -C "$BUILD" checkout -q main
}
push_branch crew/oracle/wa-fx0001 lib/app.py 'x = 2\n' && push_branch fix/wa-fx0002-thing lib/app.py 'x = 3\n' || fatal "cannot push the fixture branches"

CHAIN_DRIVER="$WORK/chain-driver.sh"
cat > "$CHAIN_DRIVER" <<'DRV'
set -euo pipefail
GATE_GUARD_LIB_ONLY=1 . "$GUARD"                  # the real validate_branch / validate_bead_id / gc_json_or_unknown
GC_CITY="$CITY"
exec >> "$GLOG" 2>&1                              # the guard's own stdout is its log, as under launchd
eval "$(grep -E '^(log|err|warn)\(\) ' "$GUARD")" # the guard's own one-line log/err/warn: their format is what the alarm parses
set_gate_status() { printf 'STATUS %s %s\n' "$1" "$2" >> "$CALLS"; }
bd() { printf 'BD %s\n' "$*" >> "$CALLS"; }
gc() { printf '{"rigs":[{"name":"whatsapp_automation","prefix":"wa","path":"%s"},{"name":"gascity","prefix":"ga","path":"%s"}]}\n' "$RIGCLONE" "$RIGCLONE"; }
. "$VR"
MARKER_ID="ga-fixture1"
. "$FIELDS"        # Step 3
. "$VALID"         # Step 4
. "$RIGPATH"       # Step 5, RIG_PATH from RIG
. "$HARD"          # Step 5b-pre5
echo "CHAIN-REACHED-END" >> "$CALLS"
DRV
CHAIN_N=0
chain() { # chain <marker_json> <fields_block> <valid_block>: the four live blocks in the guard's order; CH_DIR = the run's dir, CH_RC = its exit status
  CHAIN_N=$((CHAIN_N+1)); CH_DIR="$WORK/run.$CHAIN_N"
  mkdir -p "$CH_DIR" && cp -R "$CITY0" "$CH_DIR/city" || { CH_RC=99; return 1; }
  : > "$CH_DIR/calls.txt"; : > "$CH_DIR/guard.log"
  MARKER="$1" FIELDS="$2" VALID="$3" RIGPATH="$B_RIGPATH" HARD="$B_HARD" VR="$VR_FILE" GUARD="$GUARD" CITY="$CH_DIR/city" CALLS="$CH_DIR/calls.txt" GLOG="$CH_DIR/guard.log" RIGCLONE="$RIGCLONE" \
    bash "$CHAIN_DRIVER" > "$CH_DIR/driver.out" 2>&1
  CH_RC=$?
}
alarm_view() { # alarm_view <run dir> <bead>: what the alarm's guard_lines() and scan_arms() make of the run's log and arms file
  python3 -I - "$ALARM" "$1/guard.log" "$1/city/.gc/third-state-reads-arms.jsonl" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tsac", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bead = sys.argv[4]
gs, lines = m.guard_lines(sys.argv[2], {bead}, 8 * 1024 * 1024)
as_, arms, rows, bad, last = m.scan_arms(sys.argv[3], {bead})
print("GUARD_LINES %s %s" % (gs, "/".join(lines[bead]) if bead in lines else "none"))
print("ARMS %s %s" % (as_, arms.get(bead, "none")))
PY
}

chain "$(mk "$D_PROSE" "$L_ORACLE")" "$B_FIELDS" "$B_VALID"; D1="$CH_DIR"
[ "$CH_RC" = 0 ] && has "$D1/calls.txt" "CHAIN-REACHED-END" && hasnt "$D1/calls.txt" "STATUS" && ok "the marker passes Step 4 and the sweep reaches the end of Step 5b-pre5 (nothing set to error)" || bad "crew marker chain: rc=$CH_RC :: $(head -3 "$D1/driver.out" | tr '\n' '|') :: $(cat "$D1/calls.txt" | tr '\n' '|' | cut -c1-300)"
n="$(grep -c 'HARDCHECK step=' "$D1/guard.log")"; [ "$n" = 4 ] && ok "four HARDCHECK lines in the guard log, one per step" || bad "HARDCHECK lines: $n (want 4)"
grep -E 'HARDCHECK step=2e verdict=ok reason=sem-leituras-vistas bead=wa-fx0001 branch=crew/oracle/wa-fx0001 mode=enforce marker=ga-fixture1 checker=\[VERDICT=ok step=2e .* arm=enforce\]' "$D1/guard.log" >/dev/null \
  && ok "the 2e line names the bead and the crew branch and carries the checker's own line with arm=enforce" || bad "2e line: $(grep 'step=2e' "$D1/guard.log" | cut -c1-300)"
has "$D1/calls.txt" "label add ga-fixture1 gate-tsr:ok" && ok "the marker got its gate-tsr:ok label" || bad "labels: $(grep 'label add' "$D1/calls.txt" | tr '\n' '|')"
grep -F '"bead": "wa-fx0001"' "$D1/city/.gc/third-state-reads-arms.jsonl" 2>/dev/null | grep -F '"arm": "enforce"' >/dev/null && ok "the bead's arm is a row in .gc/third-state-reads-arms.jsonl (the proof step 2e ran for a real submission)" || bad "no arms row: $(cat "$D1/city/.gc/third-state-reads-arms.jsonl" 2>/dev/null)"
AV="$WORK/alarm1"; alarm_view "$D1" wa-fx0001 > "$AV" 2>&1
has "$AV" "GUARD_LINES ok ok/sem-leituras-vistas/enforce" && has "$AV" "ARMS ok enforce" && ok "the alarm's own readers find the 2e line and the arm for the bead: it is COVERED, not 'sem braco'" || bad "alarm view: $(cat "$AV" | tr '\n' '|')"

chain "$(mk "$D_CANON" '["bead-rig:whatsapp_automation","branch:fix/wa-fx0002-thing","source-bead:wa-fx0002","type:quality-gate-marker"]')" "$B_FIELDS" "$B_VALID"; D2="$CH_DIR"
[ "$CH_RC" = 0 ] && has "$D2/calls.txt" "CHAIN-REACHED-END" && ok "control: a canonical builder marker takes the same road" || bad "canonical chain: rc=$CH_RC :: $(cat "$D2/calls.txt" | tr '\n' '|' | cut -c1-300)"
V1="$(grep -o 'HARDCHECK step=[0-9a-z]* verdict=[a-z-]* reason=[^ ]*' "$D1/guard.log" | tr '\n' ';')"; V2="$(grep -o 'HARDCHECK step=[0-9a-z]* verdict=[a-z-]* reason=[^ ]*' "$D2/guard.log" | tr '\n' ';')"
norm_labels() { grep 'label add' "$1" | sed 's#^BD -C [^ ]* #BD #; s/ga-fixture1/M/' | sort | tr '\n' ';'; }   # the run's own city path is not part of the comparison
L1="$(norm_labels "$D1/calls.txt")"; L2="$(norm_labels "$D2/calls.txt")"
[ -n "$V1" ] && [ "$V1" = "$V2" ] && [ "$L1" = "$L2" ] && ok "the crew marker gets exactly the verdicts and labels a builder marker gets for the same kind of diff: 2b-2e run 'igual ao de builder'" || bad "parity: crew [$V1 | $L1] vs builder [$V2 | $L2]"

echo "E. mutants: each one must turn a case red (a test that no change can fail proves nothing)"
pred_oracle_fields() { local o; o="$(run_fields "$(mk "$D_PROSE" "$L_ORACLE")" "$1")" || return 1; printf '%s\n' "$o" | grep -qF "$RES_ORACLE"; }
pred_precedence() { local o; o="$(run_fields "$(mk "$D_NORIG" "$L_NORIG")" "$1")" || return 1; printf '%s\n' "$o" | grep -qF "RESULT|branch=fix/wa-fx0005-thing|bead_id=wa-fx0005|rig=whatsapp_automation|"; }   # rig is missing, so the fallback block RUNS; the description's own fields must survive it
pred_unknown_rig() { local o; o="$(run_fields "$(mk "$D_PROSE" "$L_UNKRIG")" "$1")" || return 1; printf '%s\n' "$o" | grep -qF "RESULT|branch=crew/oracle/wa-fx0006|bead_id=wa-fx0006|rig=|"; }
pred_no_routing_survives() { run_fields "$(mk "$D_PROSE" '["gate-status:claimed"]')" "$1" > "$WORK/pm.out"; [ "$?" = 0 ] && grep -qF "RESULT|branch=|bead_id=|rig=|" "$WORK/pm.out"; }
pred_chain_fields() { chain "$(mk "$D_PROSE" "$L_ORACLE")" "$1" "$B_VALID"; [ "$CH_RC" = 0 ] && grep -qF "HARDCHECK step=2e" "$CH_DIR/guard.log"; }
pred_refusal_speaks() { run_valid "" "" "" "$1" > "$WORK/pv.out"; [ "$RC" = 1 ] && grep -qF "$REJ" "$WORK/pv.out"; }
mutant() { # mutant <name> <block> <sed expression> <predicate>: the predicate must hold on the shipped block and FAIL on the mutated one
  local name="$1" in="$2" expr="$3" pred="$4" out="$WORK/mut.$RANDOM.sh"
  sed "$expr" "$in" > "$out"
  if cmp -s "$in" "$out"; then bad "mutant $name does not apply (the block text moved)"; return; fi
  bash -n "$out" 2>/dev/null || { bad "mutant $name does not parse"; return; }
  if ! "$pred" "$in"; then bad "mutant $name: the predicate is already red on the shipped block"; return; fi
  if "$pred" "$out"; then bad "mutant $name SURVIVED: no case notices it"; else ok "mutant $name killed"; fi
}
mutant "M1 no branch: fallback"                    "$B_FIELDS" 's/label_fallback "branch:"/printf ""/'                                              pred_oracle_fields
mutant "M2 no source-bead: fallback"               "$B_FIELDS" 's/label_fallback "source-bead:"/printf ""/'                                         pred_oracle_fields
mutant "M3 no bead-rig: fallback"                  "$B_FIELDS" 's/label_fallback "bead-rig:"/printf ""/'                                            pred_oracle_fields
mutant "M3b bead-rig:unknown is read as a rig"     "$B_FIELDS" 's/ \&\& \[ "\$LBL_VAL" != "unknown" \]//'                                           pred_unknown_rig
mutant "M4 a branch label overrides the description" "$B_FIELDS" 's/^  if \[ -z "\$BRANCH" \]; then$/  if true; then/'                                 pred_precedence
mutant "M4b a bead label overrides the description"  "$B_FIELDS" 's/^  if \[ -z "\$BEAD_ID" \]; then$/  if true; then/'                                pred_precedence
mutant "M5 no-match grep aborts the sweep (no || true)" "$B_FIELDS" 's/ || true$//'                                                            pred_no_routing_survives
mutant "M6 end to end loses the branch label"      "$B_FIELDS" 's/label_fallback "branch:"/printf ""/'                                              pred_chain_fields
mutant "M7 end to end loses the bead label"        "$B_FIELDS" 's/label_fallback "source-bead:"/printf ""/'                                         pred_chain_fields
mutant "M8 refusal comment waits for bead_id again" "$B_VALID" 's/^  bd -C "\$GC_CITY" comment "\$MARKER_ID" "Gate guard rejected marker: invalid/  [ -n "$BEAD_ID" ] \&\& bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard rejected marker: invalid/' pred_refusal_speaks

echo "F. the blocks sit where the sweep needs them"
lineno() { grep -n -- "$1" "$GUARD" | head -1 | cut -d: -f1; }
L_DESC="$(lineno '^DESC=\$(printf')"; L_BEADRIG="$(lineno '^BEAD_RIG=\$(extract "bead_rig")')"; L_FEND="$(lineno '^# SELFTEST-EXTRACT marker-fields: END$')"; L_LOG="$(lineno '^log "  branch=\$BRANCH  bead_id=\$BEAD_ID  marker_author=')"
if [ -n "$L_DESC" ] && [ -n "$L_BEADRIG" ] && [ -n "$L_FEND" ] && [ -n "$L_LOG" ] && [ "$L_DESC" -lt "$L_BEADRIG" ] && [ "$L_BEADRIG" -lt "$L_FEND" ] && [ "$L_FEND" -lt "$L_LOG" ]; then
  ok "the fallback sits after the last extract() and before the Step 3 field log (the log shows the resolved values)"
else bad "placement: DESC=$L_DESC BEAD_RIG=$L_BEADRIG fields-end=$L_FEND log=$L_LOG"; fi
L_VB="$(lineno '^# SELFTEST-EXTRACT field-validation: BEGIN$')"; L_VT="$(lineno '^VALIDATION_OK=true$')"; L_VE="$(lineno '^# SELFTEST-EXTRACT field-validation: END$')"; L_4B="$(lineno '^# ── Step 4b')"
if [ -n "$L_VB" ] && [ -n "$L_VT" ] && [ -n "$L_VE" ] && [ -n "$L_4B" ] && [ "$L_VB" -lt "$L_VT" ] && [ "$L_VT" -lt "$L_VE" ] && [ "$L_VE" -lt "$L_4B" ]; then
  ok "the validation block wraps all of Step 4 and ends before Step 4b"
else bad "validation placement: begin=$L_VB true=$L_VT end=$L_VE step4b=$L_4B"; fi
grep -q '^BEAD_RIG=\$(extract "bead_rig")$' "$GUARD" && ok "the canonical bead_rig extract line is still there (gate-crossstore-bead-rig-thirdstore.selftest.sh reads it)" || bad "BEAD_RIG extract line changed"

echo
echo "gate-guard-label-fallback selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
