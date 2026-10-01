#!/usr/bin/env bash
# gate-lane-tally.selftest.sh (ga-atsahv item 4) — the weekly "rounds saved" tally, against a synthetic
# quality-gate.jsonl and a fixed clock. Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALLY="$SELF_DIR/gate-lane-tally.py"
WEEKLY="$SELF_DIR/scripts/gate-lane-weekly.sh"
ORDER="$SELF_DIR/../orders/gate-lane-weekly.toml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-lane-tally.selftest =="
for f in "$TALLY" "$WEEKLY" "$ORDER"; do [ -r "$f" ] && ok "present: $(basename "$f")" || bad "missing: $f"; done

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-lane-tally.XXXXXX")" || { echo "mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
NOW="2026-10-08T12:00:00Z"   # window (7d) opens 2026-10-01T12:00:00Z

L="$T/qg.jsonl"
cat > "$L" <<'EOF'
{"ts":"2026-09-20T10:00:00Z","event":"gate_lane","lane":"fast","marker":"m-old","would_have_reviewers":1,"reason":"old"}
{"ts":"2026-09-20T10:05:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-old","result":"PASS","dry_run":"0"}
{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"fast","marker":"m-f1","would_have_reviewers":2,"reason":"every file is DOC or TEST"}
{"ts":"2026-10-02T09:01:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-f1","result":"PASS","dry_run":"0","reviewers":0}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"normal","marker":"m-r","reason":"content scan found personal data / a credential on added lines (cpf×1) — normal gate"}
{"ts":"2026-10-03T09:30:00Z","event":"gate_lane","lane":"fast","marker":"m-r","would_have_reviewers":1,"reason":"every file is DOC or TEST"}
{"ts":"2026-10-03T09:31:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-r","result":"FAIL","dry_run":"0"}
{"ts":"2026-10-04T09:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n1","reason":"2 file(s) are production code or prompt/doctrine (code=2 prompt=0) — normal gate"}
{"ts":"2026-10-04T10:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n2","reason":"1 file(s) are production code or prompt/doctrine (code=0 prompt=1) — normal gate"}
{"ts":"2026-10-04T11:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n3","reason":"fast-lane test check did not pass: test tests/x.selftest.sh exited rc=1 — normal gate decides"}
{"ts":"2026-10-04T12:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n4","reason":"changed test(s) in a language the fast lane cannot run — normal gate"}
{"ts":"2026-10-04T13:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n5","reason":"something nobody anticipated"}
{"ts":"2026-10-05T09:00:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-nomatch","result":"PASS","dry_run":"0"}
{"ts":"2026-10-05T10:00:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-dry","result":"PASS","dry_run":"1"}
{"ts":"2026-10-05T11:00:00Z","event":"dispatcher_complete","lane":"normal","marker":"m-n1","result":"PASS","dry_run":"0"}
this line is not json at all
{"ts":"garbage","event":"gate_lane","lane":"fast","marker":"m-badts"}
EOF

J=$(python3 "$TALLY" --log "$L" --now "$NOW" --json); rc=$?
[ "$rc" = "0" ] && ok "tally exits 0" || bad "tally rc=$rc"
get() { printf '%s' "$J" | python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }
chk() { local got; got=$(get "$2"); [ "$got" = "$3" ] && ok "$1 = $3" || bad "$1: got '$got', want '$3'"; }
chk "events before the window are excluded (m-old)"                   "['decisions']" 7
chk "a marker re-claimed (normal, then fast) counts ONCE, last wins"  "['fast']" 2
chk "normal-lane diffs"                                              "['normal']" 5
chk "completed fast runs (dry-run and non-fast excluded)"            "['fast_runs_completed']" 3
chk "fast PASS"                                                      "['fast_pass']" 2
chk "fast FAIL (the safety signal: a fast-lane run that did not merge)" "['fast_fail']" 1
chk "reviewer runs saved = Σ would_have_reviewers (2 + 1) + 1 assumed for the unmatched run" "['reviewer_runs_saved']" 4
chk "the unmatched fast run is flagged, not hidden"                  "['saved_unmatched_assumed_1']" 1
chk "doc/test-only diffs bounced by a mechanical check (test fail + no-runner)" "['doc_test_only_bounced_by_check']" 2
chk "unreadable lines are counted, not silently dropped"             "['unreadable_lines']" 2
chk "reason bucket: code/prompt"                                     "['normal_reasons']['tem arquivo de código ou prompt/doutrina']" 2
chk "reason bucket: unanticipated reasons land in 'outro'"           "['normal_reasons']['outro']" 1

TXT=$(python3 "$TALLY" --log "$L" --now "$NOW")
case "$TXT" in *"fast-lane 2 (29%)"*) ok "text report shows the share (2 of 7 = 29%)" ;; *) bad "text report: $TXT" ;; esac
case "$TXT" in *"ATENÇÃO: 2 linha(s)"*) ok "text report warns about skipped lines" ;; *) bad "no warning about skipped lines: $TXT" ;; esac
case "$TXT" in *"contados como 1 revisor"*) ok "text report discloses the assumption for the unmatched run" ;; *) bad "assumption not disclosed" ;; esac

# empty vs error are different outcomes
python3 "$TALLY" --log "$T/does-not-exist.jsonl" --now "$NOW" >"$T/o" 2>"$T/e"; rc=$?
[ "$rc" = "2" ] && grep -q 'NOT a zero tally' "$T/e" && ok "a missing log is exit 2 'NOT a zero tally' — never '0 saved'" || bad "missing log: rc=$rc $(cat "$T/e")"
: > "$T/empty.jsonl"
EMPTY=$(python3 "$TALLY" --log "$T/empty.jsonl" --now "$NOW"); rc=$?
[ "$rc" = "0" ] && case "$EMPTY" in *"nenhuma decisão"*) true ;; *) false ;; esac && ok "an empty log is a valid tally that says 'nenhuma decisão'" || bad "empty log: rc=$rc '$EMPTY'"

# --weekly: history appended + ONE notify, only when the window has decisions
cat > "$T/bin/notify" <<'EOF'
#!/bin/bash
echo "$@" >> "$FAKE_NOTIFY_LOG"
EOF
chmod +x "$T/bin/notify"
OUT="$T/history.jsonl"; NL="$T/notify.log"; : > "$NL"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$OUT" >/dev/null; rc=$?
[ "$rc" = "0" ] && [ "$(wc -l < "$OUT" | tr -d ' ')" = "1" ] && ok "--weekly appends exactly one history line" || bad "--weekly history: rc=$rc lines=$(wc -l < "$OUT" 2>/dev/null)"
[ "$(wc -l < "$NL" | tr -d ' ')" = "1" ] && grep -q 'gate-lane-weekly' "$NL" && grep -q '2/7 diffs na fast-lane, 4 rodada' "$NL" && ok "--weekly sends ONE notify line with the headline numbers" || bad "notify: $(cat "$NL")"
: > "$NL"; rm -f "$OUT"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$T/empty.jsonl" --now "$NOW" --weekly --out "$OUT" >/dev/null
[ ! -s "$NL" ] && [ ! -e "$OUT" ] && ok "--weekly on an empty window: no notify, no history line (no noise)" || bad "empty window still wrote/notified"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$OUT" --no-notify >/dev/null
[ ! -s "$NL" ] && ok "--no-notify suppresses the notify" || bad "--no-notify still notified"
# notify absent: history still written, and it SAYS so
PATH="/usr/bin:/bin" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$T/h2.jsonl" >/dev/null 2>"$T/e2"; rc=$?
[ "$rc" = "0" ] && [ -s "$T/h2.jsonl" ] && grep -q 'notify. is not on PATH' "$T/e2" && ok "notify missing: tally still recorded, and the gap is reported on stderr" || bad "notify missing: rc=$rc $(cat "$T/e2")"

# the order + wrapper agree
grep -q '^exec = "\$PACK_DIR/assets/scripts/gate-lane-weekly.sh"$' "$ORDER" && ok "order exec points at the wrapper (single path, like jev-preambulo)" || bad "order exec line drifted"
grep -q '^interval = "168h"$' "$ORDER" && grep -q '^trigger = "cooldown"$' "$ORDER" && ok "order is weekly (cooldown 168h)" || bad "order schedule drifted"
grep -q 'gate-lane-tally.py" --weekly --days 7' "$WEEKLY" && ok "wrapper runs the tally in --weekly mode over 7 days" || bad "wrapper drifted"
grep -q -i -E 'gc mail|mail send' "$TALLY" "$WEEKLY" && bad "the tally mails someone (the pattern that got the previous weekly report disabled)" || ok "no mail path anywhere in the tally/wrapper"
if grep -n -o -E 'ga-[a-z0-9]{5,7}' "$TALLY" "$WEEKLY" | grep -v 'ga-atsahv' | grep -q .; then bad "a hardcoded bead id other than the story's own appears in the tally"; else ok "no hardcoded bead id besides the story's own"; fi

echo
echo "== gate-lane-tally.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
