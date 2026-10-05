#!/usr/bin/env bash
# token-ledger-harvest.selftest.sh — ga-5c3msy: the order wrapper must (1) really run the tool's `harvest`, (2) leave one
# log line per run with rc and duration, (3) hand a failing tool's exit code to the order runner (a harvest that fails
# silently is the "ledger quietly stops filling, then a week of numbers is gone" failure), (4) work with a bare PATH
# (orders do not run in a login shell), (5) with the REAL tool: a transcripts root that cannot be read must reach the order runner
# as a failure and show up in the log line (gate attempt 3: it used to print the normal summary and exit 0 - "nothing to harvest" -
# while the reaper deleted the transcripts 24h later). Hermetic: a fake tool stands in for bead-token-meter.py, except in (5).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$SELF_DIR/scripts/token-ledger-harvest.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/token-ledger-harvest-selftest.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cat > "$W/fake-tool.py" <<'PY'
import os, sys
open(os.environ["FAKE_ARGV_OUT"], "w").write(" ".join(sys.argv[1:]))
print("harvest: fake run"); print("second line")
sys.exit(int(os.environ.get("FAKE_RC", "0")))
PY
run() { env -i PATH="/usr/bin:/bin" HOME="$W" GC_CITY_PATH="$W/city" TOKEN_LEDGER_TOOL="$W/fake-tool.py" TOKEN_LEDGER_LOG="$W/city/.gc/logs/h.log" FAKE_ARGV_OUT="$W/argv" "$@" /bin/bash "${WRAP_UNDER_TEST:-$WRAP}"; }
run FAKE_RC=0 >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && ok "tool rc 0 -> wrapper rc 0" || bad "rc=$rc"
[ "$(cat "$W/argv")" = "harvest" ] && ok "the tool is invoked as: <tool> harvest" || bad "argv: $(cat "$W/argv")"
l="$(wc -l < "$W/city/.gc/logs/h.log" | tr -d ' ')"; [ "$l" = "1" ] && grep -Eq '^[0-9T:Z-]+ rc=0 secs=[0-9]+ harvest: fake run second line' "$W/city/.gc/logs/h.log" && ok "one log line per run: timestamp, rc, secs, the tool's own summary (newlines folded)" || bad "log: $(cat "$W/city/.gc/logs/h.log")"
run FAKE_RC=3 >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 3 ] && ok "tool rc 3 -> wrapper rc 3 (the order runner sees the failure)" || bad "failure swallowed: rc=$rc"
grep -q "harvest failed rc=3" "$W/err" && ok "failure text goes to stderr" || bad "no stderr: $(cat "$W/err")"
grep -q "rc=3" "$W/city/.gc/logs/h.log" && [ "$(wc -l < "$W/city/.gc/logs/h.log" | tr -d ' ')" = "2" ] && ok "a failed run is logged too (appends, never rewrites)" || bad "failed run not logged"
[ -x "$WRAP" ] && ok "wrapper is executable (the order execs it directly)" || bad "wrapper not executable"

# ---- (5) the REAL tool through the wrapper: unreadable input must fail loudly
REAL="$SELF_DIR/bead-token-meter.py"
real() { run TOKEN_LEDGER_TOOL="$REAL" BTM_LEDGER="$W/real-ledger/sessions.jsonl" "$@"; }
mkdir -p "$W/okroot/-p"
printf '%s\n' '{"type":"user","timestamp":"2026-09-30T10:00:00Z","message":{"role":"user","content":"[gascity] gastown.dog-1 x"}}' > "$W/okroot/-p/s1.jsonl"
case_real_missing_root() {   # sets MR_RC and MR_LINE
  : > "$W/city/.gc/logs/h.log"
  real BTM_PROJECTS="$W/does-not-exist" >"$W/out" 2>"$W/err"; MR_RC=$?
  MR_LINE="$(tail -n 1 "$W/city/.gc/logs/h.log")"
}
case_real_missing_root
[ "$MR_RC" -eq 6 ] && ok "real tool, transcripts root missing: wrapper exit 6 (the order runner sees it)" || bad "missing root swallowed: wrapper rc=$MR_RC"
case "$MR_LINE" in *" rc=6 "*"SEM ENTRADA"*"não existe"*) ok "the log line carries rc=6 AND the alarm text inside the 500-char cut: ${MR_LINE:0:110}..." ;; *) bad "log line: $MR_LINE" ;; esac
grep -q "harvest failed rc=6" "$W/err" && ok "stderr says the harvest failed (what the order history shows)" || bad "no stderr: $(cat "$W/err")"
real BTM_PROJECTS="$W/okroot" >"$W/out" 2>"$W/err"; rc=$?
[ "$rc" -eq 0 ] && tail -n 1 "$W/city/.gc/logs/h.log" | grep -q ' rc=0 .*harvest: 1 sess' && ok "real tool, readable root: exit 0 and the summary shows 1 session read" || bad "healthy real harvest: rc=$rc | $(tail -n 1 "$W/city/.gc/logs/h.log")"
# mutation control: a wrapper that swallows the tool's exit code must be rejected by the missing-root case
sed 's/^exit "\$rc"$/exit 0/' "$WRAP" > "$W/swallow.sh"
if cmp -s "$W/swallow.sh" "$WRAP"; then bad "mutant 'wrapper swallows the exit code': the sed did not change the wrapper - the control is blind"
else
  WRAP_UNDER_TEST="$W/swallow.sh"; case_real_missing_root; unset WRAP_UNDER_TEST
  [ "$MR_RC" -ne 6 ] && ok "mutant 'wrapper swallows the exit code' rejected (the missing-root case saw rc=$MR_RC, not 6)" || bad "mutant survived"
fi

# ---- (6) the prod test's "a report is read-only" proof (gate attempt 5). It compared the ledger's mtime at 1 s resolution: a write inside the same
# second read as untouched, and the 30-min harvest order rewrites the ledger on every tick, so a changed mtime was a ~1-3% false FAIL. The proof is now
# by content (size, inode, sha256); when the live file moved it is re-proven on a private copy; "could not find out" is counted, never a silent pass.
# The helpers live in the prod test and are SOURCED here (it returns before any live check when sourced); a stub meter stands in for `report`.
STORY="${STORY_UNDER_TEST:-$SELF_DIR/prod-tests/gascity/story-ga-5c3msy.sh}"
cat > "$W/stub-meter.py" <<'PY'
import os, sys
a = sys.argv[1:]
led = a[a.index("--ledger") + 1] if "--ledger" in a else os.environ["STUB_LEDGER"]
live = led == os.environ["STUB_LEDGER"]
mode = os.environ.get("STUB_MODE", "read")
if mode in ("append", "silent"):                       # the REPORT writes to the ledger it reads
    st = os.stat(led)
    with open(led, "ab") as fh:
        fh.write(b'{"sid":"c"}\n')
    if mode == "silent":                               # ... and puts the mtime back: a 1 s mtime comparison cannot see it
        os.utime(led, ns=(st.st_atime_ns, st.st_mtime_ns))
elif mode == "samesize":                               # ... or rewrites a byte IN PLACE: same size, same inode, mtime put back
    st = os.stat(led)
    data = open(led, "rb").read().replace(b'"a"', b'"z"')
    with open(led, "r+b") as fh:
        fh.write(data)
    os.utime(led, ns=(st.st_atime_ns, st.st_mtime_ns))
elif mode in ("tick", "tick_copy_fails") and live:     # a concurrent harvest tick: atomic rewrite (new inode, new bytes) of the LIVE file only
    tmp = led + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(open(led, "rb").read() + b'{"sid":"tick"}\n')
    os.replace(tmp, led)
if mode == "tick_copy_fails" and not live:
    sys.exit(3)
print("{}")
PY
ro_case() {   # <mode> [story-file] -> RO_RC, RO_OUT: the story's own check_report_readonly in a subshell, against the stub meter and a scratch ledger
  local story="${2:-$STORY}"
  RO_OUT="$( ( set +e
    export STUB_MODE="$1" STUB_LEDGER="$W/ro-ledger.jsonl"
    printf '%s\n' '{"sid":"a"}' '{"sid":"b"}' > "$STUB_LEDGER"
    source "$story" || exit 97
    LEDGER="$STUB_LEDGER"; METER="$W/stub-meter.py"; TMPROOT="$W/ro-tmp"; mkdir -p "$TMPROOT"
    touch -t 202601010000 "$LEDGER"                     # an old mtime: whatever the stub does to the file, the mtime of the write is "now"
    cp "$LEDGER" "$TMPROOT/ledger-pre.jsonl"           # what the prod test snapshots BEFORE the report runs
    b="$(_ledger_stamp "$LEDGER")"; python3 "$METER" report --from x --json >/dev/null 2>&1
    a="$(_ledger_stamp "$LEDGER")"
    check_report_readonly "$b" "$a" "$TMPROOT/ledger-pre.jsonl" --from x --json
    echo "PROOF=[$RO_PROOF] UNPROVEN=[$UNPROVEN]"
  ) 2>&1 )"; RO_RC=$?
}
ro_case read
[ "$RO_RC" -eq 0 ] && [[ "$RO_OUT" == *"PROOF=[live ledger byte-identical"*"UNPROVEN=[]"* ]] && ok "report that only reads: proven read-only on the live ledger (size, inode, sha256)" || bad "read-only report not proven: rc=$RO_RC $RO_OUT"
ro_case append
[ "$RO_RC" -ne 0 ] && [[ "$RO_OUT" == *"changed the ledger it reads"* ]] && ok "report that WRITES the ledger: FAIL (re-run on a private copy shows the write)" || bad "a writing report passed: rc=$RO_RC $RO_OUT"
ro_case silent
[ "$RO_RC" -ne 0 ] && [[ "$RO_OUT" == *"changed the ledger it reads"* ]] && ok "report that writes and RESTORES the mtime: still a FAIL (an mtime comparison would have called it untouched)" || bad "a silent write passed: rc=$RO_RC $RO_OUT"
ro_case samesize
[ "$RO_RC" -ne 0 ] && [[ "$RO_OUT" == *"changed the ledger it reads"* ]] && ok "report that rewrites a byte in place (same size, same inode, mtime restored): FAIL - only the content hash sees it" || bad "an in-place write passed: rc=$RO_RC $RO_OUT"
ro_case tick
[ "$RO_RC" -eq 0 ] && [[ "$RO_OUT" == *"PROOF=[the live ledger moved during the run (a harvest tick)"*"UNPROVEN=[]"* ]] && ok "a harvest tick rewrites the live ledger mid-report: NOT a false FAIL (read-only proven on a private copy, and said so)" || bad "tick in the window: rc=$RO_RC $RO_OUT"
ro_case tick_copy_fails
[ "$RO_RC" -eq 0 ] && [[ "$RO_OUT" == *"PROOF=[UNPROVEN]"*"UNPROVEN=[report read-only"* ]] && ok "tick in the window and the private-copy run fails: 'could not find out' is listed as UNPROVEN, neither a pass nor a FAIL" || bad "unprovable case: rc=$RO_RC $RO_OUT"
# mutation controls on the proof itself: each must be rejected by at least one of the cases above
ro_mutant() {   # <name> <old> <new> <case-mode...>   (the old snippet must occur exactly once, or the control is blind)
  local name="$1" old="$2" new="$3"; shift 3
  python3 - "$STORY" "$W/story-mutant.sh" "$old" "$new" <<'PY' || { bad "mutant '$name': the snippet to mutate does not occur exactly once in the prod test - the control is blind"; return; }
import sys
src = open(sys.argv[1]).read()
if src.count(sys.argv[3]) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(src.replace(sys.argv[3], sys.argv[4]))
PY
  local mode caught=""
  for mode in "$@"; do ro_case "$mode" "$W/story-mutant.sh"; case "$mode" in read|tick) [ "$RO_RC" -ne 0 ] && caught=1 ;; *) [ "$RO_RC" -eq 0 ] && caught=1 ;; esac; done
  [ -n "$caught" ] && ok "mutant '$name' rejected" || bad "mutant '$name' SURVIVED"
}
ro_mutant "an unchanged stamp is not required"            'if [[ "$before" == "$after" ]]; then RO_PROOF=' 'if true; then RO_PROOF='                                         append silent
ro_mutant "a changed private copy is not a FAIL"          '[[ "$c0" == "$c1" ]] || fail ' '[[ "$c0" == "$c1" ]] || : '                                                                                            append silent
ro_mutant "an unrunnable proof is silently a pass"        '_unproven "report read-only (the live ledger moved during the run and the report failed on the private copy)"' ':' tick_copy_fails
ro_mutant "the stamp ignores the content"                 'hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' '"-")' samesize
echo; echo "$PASS ok, $FAIL failed"; [ "$FAIL" -eq 0 ]
