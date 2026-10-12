#!/usr/bin/env bash
# gate-lane-tally.selftest.sh (ga-atsahv item 4) — the weekly "rounds saved" tally, against a synthetic
# quality-gate.jsonl and a fixed clock. Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALLY="$SELF_DIR/gate-lane-tally.py"
WEEKLY="$SELF_DIR/scripts/gate-lane-weekly.sh"
ORDER="$SELF_DIR/../orders/gate-lane-weekly.toml"
LIB="$SELF_DIR/gate-fastlane.lib.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
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
{"ts":"2026-09-20T10:00:00Z","event":"gate_lane","lane":"fast","marker":"m-old","would_have_reviewers":1,"reason":"old","reason_code":"fast"}
{"ts":"2026-09-20T10:05:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-old","result":"PASS","dry_run":"0"}
{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"fast","marker":"m-f1","would_have_reviewers":2,"reason":"every file is DOC or TEST","reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-02T09:01:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-f1","result":"PASS","dry_run":"0","reviewers":0}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"normal","marker":"m-r","reason":"content scan found personal data / a credential on added lines (cpf×1) — normal gate","reason_code":"scan-findings","dry_run":"0"}
{"ts":"2026-10-03T09:30:00Z","event":"gate_lane","lane":"fast","marker":"m-r","would_have_reviewers":1,"reason":"every file is DOC or TEST","reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-03T09:31:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-r","result":"FAIL","dry_run":"0"}
{"ts":"2026-10-04T09:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n1","reason":"2 file(s) are production code, prompt/doctrine or the gate's own policy (code=2 prompt=0 policy=0) — normal gate","reason_code":"code-or-prompt","dry_run":"0"}
{"ts":"2026-10-04T10:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n2","reason":"1 file(s) are production code, prompt/doctrine or the gate's own policy (code=0 prompt=1 policy=0) — normal gate","reason_code":"code-or-prompt","dry_run":"0"}
{"ts":"2026-10-04T11:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n3","reason":"fast-lane test check did not pass: test tests/x.selftest.sh exited rc=1 — normal gate decides","reason_code":"test-failed","dry_run":"0"}
{"ts":"2026-10-04T12:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n4","reason":"changed test(s) in a language the fast lane cannot run — normal gate","reason_code":"test-unrunnable","dry_run":"0"}
{"ts":"2026-10-04T13:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n5","reason":"something nobody anticipated","reason_code":"banana","dry_run":"0"}
{"ts":"2026-10-04T14:00:00Z","event":"gate_lane","lane":"normal","marker":"m-n6","reason":"an event written before reason_code existed"}
{"ts":"2026-10-04T15:00:00Z","event":"gate_lane","lane":"normal","marker":"m-lib","reason":"fast-lane lib not loaded (gate-fastlane.lib.sh missing or unreadable) — normal gate","reason_code":"lib-not-loaded","dry_run":"0"}
{"ts":"2026-10-05T09:00:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-nomatch","result":"PASS","dry_run":"0"}
{"ts":"2026-10-05T10:00:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-dry","result":"PASS","dry_run":"1"}
{"ts":"2026-10-05T10:30:00Z","event":"gate_lane","lane":"fast","marker":"m-dryfast","would_have_reviewers":5,"reason":"every file is DOC or TEST","reason_code":"fast","dry_run":"1"}
{"ts":"2026-10-05T10:31:00Z","event":"gate_lane","lane":"normal","marker":"m-dryn","reason":"dry-run sweep","reason_code":"code-or-prompt","dry_run":"1"}
{"ts":"2026-10-05T11:00:00Z","event":"dispatcher_complete","lane":"normal","marker":"m-n1","result":"PASS","dry_run":"0"}
this line is not json at all
{"ts":"garbage","event":"gate_lane","lane":"fast","marker":"m-badts"}
EOF

J=$(python3 "$TALLY" --log "$L" --now "$NOW" --json); rc=$?
[ "$rc" = "0" ] && ok "tally exits 0" || bad "tally rc=$rc"
get() { printf '%s' "$J" | python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }
chk() { local got; got=$(get "$2"); [ "$got" = "$3" ] && ok "$1 = $3" || bad "$1: got '$got', want '$3'"; }
chk "events before the window and DRY_RUN=1 sweeps are excluded (m-old, m-dryfast, m-dryn)" "['decisions']" 9
chk "a marker re-claimed (normal, then fast) counts ONCE, last wins"  "['fast']" 2
chk "normal-lane diffs"                                              "['normal']" 7
chk "completed fast runs (dry-run and non-fast excluded)"            "['fast_runs_completed']" 3
chk "fast PASS"                                                      "['fast_pass']" 2
chk "fast FAIL (the safety signal: a fast-lane run that did not merge)" "['fast_fail']" 1
chk "reviewer runs saved = Σ would_have_reviewers of the runs that PASSED (m-f1: 2) + 1 assumed for the unmatched PASS — the FAIL run (m-r) saved nothing" "['reviewer_runs_saved']" 3
chk "the unmatched fast run is flagged, not hidden"                  "['saved_unmatched_assumed_1']" 1
chk "doc/test-only diffs bounced by a mechanical check (test fail + no-runner)" "['doc_test_only_bounced_by_check']" 2
chk "a gate_lane line whose ts is garbage is damage: counted, not silently dropped" "['unreadable_lines']" 1
chk "a stray line of prose inside the window is reported as undatable, not as damage of ours" "['undatable_lines']" 1
chk "reason bucket: code/prompt — keyed on the CODE the lib emits"   "['normal_reasons']['tem arquivo de código ou prompt/doutrina']" 2
chk "reason bucket: a code nobody listed lands in 'outro', loudly"   "['normal_reasons']['outro (reason_code desconhecido)']" 1
chk "reason bucket: an event with no reason_code is its own bucket"  "['normal_reasons']['sem reason_code no evento']" 1
chk "reason bucket: the broken-lib period is visible"                "['normal_reasons']['lib da fast-lane não carregou']" 1
chk "no code/prompt diff is reported as touching the gate's own policy" "['normal_reasons'].get('mexe na política do próprio gate', 0)" 0

TXT=$(python3 "$TALLY" --log "$L" --now "$NOW")
case "$TXT" in *"fast-lane 2 (22%)"*) ok "text report shows the share (2 of 9 = 22%)" ;; *) bad "text report: $TXT" ;; esac
case "$TXT" in *"ATENÇÃO: 1 linha(s)"*) ok "text report warns about skipped lines" ;; *) bad "no warning about skipped lines: $TXT" ;; esac
case "$TXT" in *"contados como 1 revisor"*) ok "text report discloses the assumption for the unmatched run" ;; *) bad "assumption not disclosed" ;; esac

# a lane that was GRANTED and then REVOKED at the push (gate round 2, blocking issue 2) — and the two crediting rules
# (a run that did not PASS saved nothing; a completion is paired with the decision in effect WHEN IT RAN)
L2="$T/qg2.jsonl"
cat > "$L2" <<'EOF'
{"ts":"2026-10-02T10:00:00Z","event":"gate_lane","lane":"fast","marker":"m-rv1","would_have_reviewers":2,"reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-02T10:05:00Z","event":"gate_lane","lane":"normal","marker":"m-rv1","would_have_reviewers":2,"reason":"revoked at the push","reason_code":"revoked-at-push","dry_run":"0"}
{"ts":"2026-10-02T10:30:00Z","event":"gate_lane","lane":"fast","marker":"m-rv1","would_have_reviewers":2,"reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-02T10:31:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-rv1","result":"PASS","dry_run":"0"}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"fast","marker":"m-rv2","would_have_reviewers":1,"reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-03T09:05:00Z","event":"gate_lane","lane":"normal","marker":"m-rv2","would_have_reviewers":1,"reason":"revoked at the push","reason_code":"revoked-at-push","dry_run":"0"}
{"ts":"2026-10-04T09:00:00Z","event":"gate_lane","lane":"fast","marker":"m-tp","would_have_reviewers":3,"reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-04T09:01:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-tp","result":"PASS","dry_run":"0"}
{"ts":"2026-10-04T09:30:00Z","event":"gate_lane","lane":"normal","marker":"m-tp","would_have_reviewers":1,"reason_code":"code-or-prompt","dry_run":"0"}
{"ts":"2026-10-05T09:00:00Z","event":"gate_lane","lane":"fast","marker":"m-fl","would_have_reviewers":8,"reason_code":"fast","dry_run":"0"}
{"ts":"2026-10-05T09:01:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-fl","result":"FAIL","dry_run":"0"}
{"ts":"2026-10-05T10:00:00Z","event":"gate_lane","lane":"normal","marker":"m-dry","would_have_reviewers":2,"reason_code":"revoked-at-push","dry_run":"1"}
EOF
J2=$(python3 "$TALLY" --log "$L2" --now "$NOW" --json)
get2() { printf '%s' "$J2" | python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }
chk2() { local got; got=$(get2 "$2"); [ "$got" = "$3" ] && ok "$1 = $3" || bad "$1: got '$got', want '$3'"; }
chk2 "revocations are counted per EVENT, so a marker revoked and then re-decided still shows it (m-rv1, m-rv2; the dry run is left out)" "['lane_revoked_at_push']" 2
chk2 "a re-decided marker is still ONE diff, its last decision wins (4 markers, the dry-run one excluded)" "['decisions']" 4
chk2 "…m-rv1 ended fast, m-rv2 ended revoked (normal), m-tp ended normal, m-fl ended fast" "['fast']" 2
chk2 "a revoked decision is bucketed under its own code, not as 'outro'" "['normal_reasons']['fast-lane concedida e revogada no push (o diff mudou ou deixou de ser elegível)']" 1
# the magnitudes are chosen so each rule moves the total on its own: right on both = 5; credits the FAIL (+8) = 13;
# pairs with the LAST decision (m-tp's later normal: 1, not 3) = 3; wrong on both = 11 — a single number tells them apart
chk2 "reviewer runs saved: m-rv1 PASS (2) + m-tp PASS paired with the decision in effect WHEN IT RAN (3, not the later normal's 1); the m-fl FAIL (8 would-have) saved nothing" "['reviewer_runs_saved']" 5
chk2 "no PASS completion went unmatched here" "['saved_unmatched_assumed_1']" 0
TXT2=$(python3 "$TALLY" --log "$L2" --now "$NOW")
case "$TXT2" in *"revogada(s) no push: 2"*) ok "text report says how many lanes were revoked at the push" ;; *) bad "the report hides the revocations: $TXT2" ;; esac

# empty vs error are different outcomes
python3 "$TALLY" --log "$T/does-not-exist.jsonl" --now "$NOW" >"$T/o" 2>"$T/e"; rc=$?
[ "$rc" = "2" ] && grep -q 'NOT a zero tally' "$T/e" && ok "a missing log is exit 2 'NOT a zero tally' — never '0 saved'" || bad "missing log: rc=$rc $(cat "$T/e")"
: > "$T/empty.jsonl"
EMPTY=$(python3 "$TALLY" --log "$T/empty.jsonl" --now "$NOW"); rc=$?
[ "$rc" = "0" ] && case "$EMPTY" in *"nenhuma decisão"*) true ;; *) false ;; esac && ok "an empty log is a valid tally that says 'nenhuma decisão'" || bad "empty log: rc=$rc '$EMPTY'"

# ZERO decisions is not always an empty week (gate round 1 of slice 3): a log whose gate_lane lines are damaged, or whose
# producer stopped while fast runs kept merging, also has zero decisions — and must NOT read as "nothing happened".
QUIET="nenhuma decisão de lane registrada na janela"
LA="$T/qg-truncated.jsonl"   # every gate_lane line cut short, what a disk-full partial append leaves
printf '%s\n' '{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"fast","marker":"m1","reaso' \
              '{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"nor' > "$LA"
LB="$T/qg-silent-producer.jsonl"   # two fast runs merged with zero reviewers, and no lane decision on record for either
cat > "$LB" <<'EOF'
{"ts":"2026-10-02T09:01:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-s1","result":"PASS","dry_run":"0"}
{"ts":"2026-10-03T09:01:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-s2","result":"PASS","dry_run":"0"}
EOF
TA=$(python3 "$TALLY" --log "$LA" --now "$NOW"); rc=$?
JA=$(python3 "$TALLY" --log "$LA" --now "$NOW" --json)
[ "$rc" = "0" ] && [ "$(printf '%s' "$JA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['decisions'], d['unreadable_lines'])")" = "0 2" ] && ok "premise (truncated log): 0 decisions, 2 unreadable lines, exit 0" || bad "truncated-log premise: rc=$rc $JA"
case "$TA" in *"$QUIET"*) bad "a log with every gate_lane line truncated reads as 'nothing happened': $TA" ;; *) ok "truncated log: the report does NOT say the window was empty" ;; esac
case "$TA" in *"ATENÇÃO: 2 linha(s) do log ilegíveis"*"subcontados"*) ok "truncated log: the report says 2 lines were unreadable and that the numbers may be under-counted" ;; *) bad "truncated log: the unreadable-lines warning is missing: $TA" ;; esac
TB=$(python3 "$TALLY" --log "$LB" --now "$NOW"); rc=$?
JB=$(python3 "$TALLY" --log "$LB" --now "$NOW" --json)
[ "$rc" = "0" ] && [ "$(printf '%s' "$JB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['decisions'], d['fast_runs_completed'], d['reviewer_runs_saved'])")" = "0 2 2" ] && ok "premise (silent producer): 0 decisions, 2 fast runs completed, 2 reviewer runs saved (assumed)" || bad "silent-producer premise: rc=$rc $JB"
case "$TB" in *"$QUIET"*) bad "fast runs merged with no decision on record, and the report says the window was empty: $TB" ;; *) ok "silent producer: the report does NOT say the window was empty" ;; esac
case "$TB" in *"2 run(s) fast concluído(s)"*"sem nenhuma decisão de lane gravada"*) ok "silent producer: the report says 2 fast runs completed with no decision on record" ;; *) bad "silent producer: the fast runs are not in the report: $TB" ;; esac
case "$TB" in *"contados como 1 revisor"*) ok "silent producer: the reviewer count is disclosed as an assumption" ;; *) bad "silent producer: the assumed count is not disclosed: $TB" ;; esac
# …and the quiet window stays quiet: out-of-window damage, a normal-lane completion, a DRY_RUN fast completion and a
# foreign event are not signals (otherwise the weekly would cry wolf every week)
LQ="$T/qg-quiet.jsonl"
cat > "$LQ" <<'EOF'
{"ts":"2026-09-01T00:00:00Z","event":"gate_lane","lane":"fast","marker":"m-old","reaso
{"ts":"2026-10-04T09:00:00Z","event":"dispatcher_complete","lane":"normal","marker":"m-n","result":"PASS","dry_run":"0"}
{"ts":"2026-10-05T10:00:00Z","event":"dispatcher_complete","lane":"fast","marker":"m-dry","result":"PASS","dry_run":"1"}
{"ts":"2026-10-05T10:30:00Z","event":"something_else","x":1}
EOF
TQ=$(python3 "$TALLY" --log "$LQ" --now "$NOW"); rc=$?
[ "$rc" = "0" ] && case "$TQ" in *"$QUIET"*) true ;; *) false ;; esac && ok "a window with only out-of-window damage, a normal-lane completion, a dry run and a foreign event is still quiet" || bad "quiet window woke the report: rc=$rc $TQ"

# --weekly: history appended + ONE notify, only when the window has decisions
cat > "$T/bin/notify" <<'EOF'
#!/bin/bash
echo "$@" >> "$FAKE_NOTIFY_LOG"
EOF
chmod +x "$T/bin/notify"
OUT="$T/history.jsonl"; NL="$T/notify.log"; : > "$NL"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$OUT" >/dev/null; rc=$?
[ "$rc" = "0" ] && [ "$(wc -l < "$OUT" | tr -d ' ')" = "1" ] && ok "--weekly appends exactly one history line" || bad "--weekly history: rc=$rc lines=$(wc -l < "$OUT" 2>/dev/null)"
[ "$(wc -l < "$NL" | tr -d ' ')" = "1" ] && grep -q -- '-k info' "$NL" && ! grep -q 'gate-lane-weekly' "$NL" && grep -q '2/9 diffs na fast-lane, 3 rodada' "$NL" && ok "--weekly sends ONE notify line with the headline numbers, kind 'info' (a kind outside notify's catalog warns every week)" || bad "notify: $(cat "$NL")"
# the notify line is the only thing a human reads (the text report goes to the order's log): what the report warns about must be in it
grep -q 'ATENÇÃO 1 linha(s) do log ilegíveis' "$NL" && grep -q '1 run(s) fast sem decisão pareada contado(s) como 1 revisor' "$NL" && ok "…and that line carries the unreadable-lines warning and the assumed-reviewer disclosure, not only the headline" || bad "notify line hides the report's warnings: $(cat "$NL")"
: > "$NL"; rm -f "$OUT"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$T/empty.jsonl" --now "$NOW" --weekly --out "$OUT" >/dev/null
[ ! -s "$NL" ] && [ ! -e "$OUT" ] && ok "--weekly on an empty window: no notify, no history line (no noise)" || bad "empty window still wrote/notified"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$OUT" --no-notify >/dev/null
[ ! -s "$NL" ] && ok "--no-notify suppresses the notify" || bad "--no-notify still notified"
# zero decisions but a SIGNAL (truncated log / silent producer): --weekly still appends the history line and still notifies, with the warning
for c in A B; do
  case "$c" in A) F="$LA"; WANT_HIST='"unreadable_lines": 2'; WANT_NOTIFY='ATENÇÃO 2 linha(s) do log ilegíveis' ;; B) F="$LB"; WANT_HIST='"fast_runs_completed": 2'; WANT_NOTIFY='2 run(s) fast concluído(s) sem decisão gravada' ;; esac
  : > "$NL"; rm -f "$T/hs-$c.jsonl"
  PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$F" --now "$NOW" --weekly --out "$T/hs-$c.jsonl" >/dev/null 2>"$T/es-$c"; rc=$?
  [ "$rc" = "0" ] && [ "$(wc -l < "$T/hs-$c.jsonl" 2>/dev/null | tr -d ' ')" = "1" ] && grep -q -F "$WANT_HIST" "$T/hs-$c.jsonl" && ok "--weekly, zero decisions + a signal (case $c): one history line is appended, rc 0" || bad "--weekly case $c wrote no history line: rc=$rc $(cat "$T/es-$c")"
  [ "$(wc -l < "$NL" | tr -d ' ')" = "1" ] && grep -q 'ATENÇÃO: nenhuma decisão de lane legível' "$NL" && grep -q -- "$WANT_NOTIFY" "$NL" && ok "--weekly, zero decisions + a signal (case $c): ONE notify line, with the warning (never a silent week)" || bad "--weekly case $c notify: $(cat "$NL")"
done
# …and the same --weekly on the quiet window still sends nothing and writes nothing
: > "$NL"; rm -f "$T/hs-q.jsonl"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$LQ" --now "$NOW" --weekly --out "$T/hs-q.jsonl" >/dev/null
[ ! -s "$NL" ] && [ ! -e "$T/hs-q.jsonl" ] && ok "--weekly on the quiet window (no decision, no signal): no notify, no history line" || bad "quiet window cried wolf: $(cat "$NL" 2>/dev/null)"
# A line the tally cannot DATE is not damage (gate round 2 of slice 3). The live log opens with two pretty-printed objects
# (a lone "{", one key per line, a lone "}") from before the producers wrote one compact object per line: 20 permanent
# lines that carry no ts of their own, so no window can exclude them by it. They were counted as "unreadable" in EVERY
# window, so the weekly reported damage on every run, forever, and the one number built to flag real damage (20 -> 21)
# carried no information. This head is copied VERBATIM from .gc/quality-gate.jsonl (lines 1-24), not made up to fit the
# code: the tests above build their damage by hand, which is how the bug passed them.
LH="$T/qg-real-head.jsonl"
cat > "$LH" <<'EOF'
{"ts": "2026-06-04T15:52:36Z", "event": "guard_dispatched", "branch": "hotfix-sync-codigo", "bead": "ga-5nx", "rig": "property_scrapers", "marker": "ga-wisp-si89i", "gate_run": "ga-wisp-6sl6a", "target": "gastown.mayor"}
{"ts": "2026-06-04T15:56:43Z", "event": "guard_dispatched", "branch": "hotfix-sync-codigo", "bead": "ga-5nx", "rig": "property_scrapers", "marker": "ga-wisp-si89i", "gate_run": "ga-wisp-um91c", "target": "gastown.mayor"}
{"ts": "2026-06-04T16:03:07Z", "event": "guard_dispatched", "branch": "hotfix-sync-codigo", "bead": "ga-5nx", "rig": "property_scrapers", "marker": "ga-wisp-si89i", "gate_run": "ga-wisp-9nylm", "target": "gastown.mayor"}
{"ts": "2026-06-04T16:12:24Z", "branch": "hotfix-sync-codigo", "bead": "ga-5nx", "rig": "property_scrapers", "tier": "CODE", "result": "PASS", "reason": "quorum_3_of_3_independent_reviewers", "gate_run": "manual-mayor-dispatch", "elapsed_s": 0, "merge_sha": "74be8502f50d22a1a2ae7fc2aa79e9193fafedca"}
{
  "ts": "2026-06-04T16:47:28Z",
  "event": "guard_dispatched",
  "branch": "hotfix-sync-codigo",
  "bead": "ga-zal",
  "rig": "unknown",
  "marker": "ga-wisp-nno3z",
  "gate_run": "ga-wisp-tcuz4",
  "target": "gastown.mayor"
}
{
  "ts": "2026-06-04T16:49:33Z",
  "event": "guard_dispatched",
  "branch": "hotfix-sync-codigo",
  "bead": "ga-zal",
  "rig": "property_scrapers",
  "marker": "ga-wisp-8hsts",
  "gate_run": "ga-wisp-5h3oq",
  "target": "gastown.mayor"
}
EOF
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(str(d[k]) for k in sys.argv[1:]))" "$@"; }
# (a) the weekly's real situation: the head is months old, the window is this week
HNOW="2026-10-12T09:00:00Z"
JH=$(python3 "$TALLY" --log "$LH" --now "$HNOW" --days 7 --json)
[ "$(printf '%s' "$JH" | jget decisions unreadable_lines undatable_lines)" = "0 0 0" ] && ok "real log head, this week's window: 0 decisions, 0 unreadable, 0 undatable (the 20 lines sit in an old stretch of the append-only log)" || bad "real log head, this week: $JH"
TH=$(python3 "$TALLY" --log "$LH" --now "$HNOW" --days 7)
case "$TH" in *"$QUIET"*) ok "real log head, this week: the report is the quiet one" ;; *) bad "real log head woke the report: $TH" ;; esac
case "$TH" in *ATENÇÃO*|*ilegíveis*) bad "real log head, this week: the report warns about damage that is not there: $TH" ;; *) ok "real log head, this week: no damage warning" ;; esac
: > "$NL"; rm -f "$T/hs-h.jsonl"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$LH" --now "$HNOW" --weekly --days 7 --out "$T/hs-h.jsonl" >/dev/null
[ ! -s "$NL" ] && [ ! -e "$T/hs-h.jsonl" ] && ok "real log head, --weekly --days 7 (the order's exact flags): a quiet week sends nothing and writes nothing" || bad "real log head: the weekly cried wolf: $(cat "$NL" 2>/dev/null)"
# (b) a window that CONTAINS the head: the fragments are still not damage — they are reported, as information
JH2=$(python3 "$TALLY" --log "$LH" --now "2026-06-05T00:00:00Z" --days 7 --json)
[ "$(printf '%s' "$JH2" | jget decisions unreadable_lines undatable_lines)" = "0 0 20" ] && ok "real log head, a window that contains it: 0 unreadable, the 20 fragment lines reported as undatable" || bad "real log head, window containing it: $JH2"
TH2=$(python3 "$TALLY" --log "$LH" --now "2026-06-05T00:00:00Z" --days 7)
case "$TH2" in *"$QUIET"*"20 linha(s) sem timestamp"*) ok "…and the report says so on a line of its own, still the quiet one" ;; *) bad "the undatable lines are not disclosed, or woke the report: $TH2" ;; esac
case "$TH2" in *ATENÇÃO*) bad "undatable lines raised a damage warning: $TH2" ;; *) ok "…without a damage warning" ;; esac
: > "$NL"; rm -f "$T/hs-h2.jsonl"
PATH="$T/bin:$PATH" FAKE_NOTIFY_LOG="$NL" python3 "$TALLY" --log "$LH" --now "2026-06-05T00:00:00Z" --weekly --days 7 --out "$T/hs-h2.jsonl" >/dev/null
[ ! -s "$NL" ] && [ ! -e "$T/hs-h2.jsonl" ] && ok "…and --weekly over that window still sends nothing: undatable lines are not a signal" || bad "undatable lines triggered the weekly: $(cat "$NL" 2>/dev/null)"
# (c) real damage AFTER that head is still caught — the fix must not blind the counter it exists to protect
LHD="$T/qg-real-head-then-damage.jsonl"
{ cat "$LH"; printf '%s\n' '{"ts":"2026-10-11T09:00:00Z","event":"gate_li'; } > "$LHD"
JHD=$(python3 "$TALLY" --log "$LHD" --now "$HNOW" --days 7 --json)
[ "$(printf '%s' "$JHD" | jget decisions unreadable_lines undatable_lines)" = "0 1 0" ] && ok "real log head + one truncated line from this week: exactly 1 unreadable (the 20 old fragments add nothing)" || bad "head + damage: $JHD"
THD=$(python3 "$TALLY" --log "$LHD" --now "$HNOW" --days 7)
case "$THD" in *"$QUIET"*) bad "head + damage reads as a quiet week: $THD" ;; *"ATENÇÃO: 1 linha(s) do log ilegíveis"*) ok "head + damage: the report is not quiet and counts the 1 line" ;; *) bad "head + damage: unreadable-lines warning missing: $THD" ;; esac

# What IS damage, and what is not — one log, every shape (window opens 2026-10-01T12:00:00Z):
#   damage   = a line that claims to be ours (starts {"ts" — compact or spaced — or names gate_lane/dispatcher_complete) and cannot be
#              read, AND sits in the window: by its own ts when it has one, otherwise by its place in the append-only log
#   noise    = anything else the tally cannot date (a lone "{", a key line, prose): reported as undatable, never as damage
#   old      = either of the above in a stretch before the window: ignored
LD="$T/qg-shapes.jsonl"
cat > "$LD" <<'EOF'
{"ts":"2026-09-01T00:00:00Z","event":"something_else","x":1}
{"ts":"2026-09-01T00:00:01Z","event":"gate_lane","lane":"fast","marker":"m-old","reaso
  "event": "gate_lane",
{"ts":"garbage","event":"gate_lane","lane":"fast","marker":"m-old-badts"}
prose from some other writer, old
{"ts":"2026-10-02T09:00:00Z","event":"somethi
{"ts": "2026-10-03T09:00:00Z", "event": "gate_la
{"ts":"2026-10-04T09:00:00Z","event":"something_else","x":1}
{
  "ts": "2026-10-04T09:30:00Z",
  "event": "gate_lane",
  "lane": "fast"
}
{"ts":"2026-10-05
EOF
JD=$(python3 "$TALLY" --log "$LD" --now "$NOW" --json)
[ "$(printf '%s' "$JD" | jget decisions unreadable_lines undatable_lines)" = "0 4 4" ] && ok "shapes: 4 damaged lines (truncated compact, truncated spaced, a head-less fragment naming gate_lane, a head cut inside its ts) and 4 undatable noise lines; the old stretch contributes nothing" || bad "shapes: $JD"
TD=$(python3 "$TALLY" --log "$LD" --now "$NOW")
case "$TD" in *"$QUIET"*) bad "damage in the window reads as a quiet week: $TD" ;; *"ATENÇÃO: 4 linha(s) do log ilegíveis"*"4 linha(s) sem timestamp"*) ok "shapes: the report counts the 4 damaged lines AND discloses the 4 undatable ones, separately" ;; *) bad "shapes: report: $TD" ;; esac
# a head-less line BEFORE any dated line cannot be placed in the log at all: it is disclosed as undatable, not dropped and not damage
LF="$T/qg-first-line-cut.jsonl"
printf '%s\n' 'ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"fast"}' \
              '{"ts":"2026-10-03T09:00:00Z","event":"something_else","x":1}' > "$LF"
JF=$(python3 "$TALLY" --log "$LF" --now "$NOW" --json)
[ "$(printf '%s' "$JF" | jget decisions unreadable_lines undatable_lines)" = "0 0 1" ] && ok "a head-less line before any dated line is reported as undatable (not dropped, not damage)" || bad "first line cut: $JF"


# notify absent: history still written, and it SAYS so
PATH="/usr/bin:/bin" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$T/h2.jsonl" >/dev/null 2>"$T/e2"; rc=$?
[ "$rc" = "0" ] && [ -s "$T/h2.jsonl" ] && grep -q 'notify. is not on PATH' "$T/e2" && ok "notify missing: tally still recorded, and the gap is reported on stderr" || bad "notify missing: rc=$rc $(cat "$T/e2")"
# notify present but REFUSING (exit != 0): same promise — the tally is recorded, the run does not fail, and the stderr says the line never went out
mkdir -p "$T/bin-refuse"; printf '#!/bin/bash\nexit 3\n' > "$T/bin-refuse/notify"; chmod +x "$T/bin-refuse/notify"
PATH="$T/bin-refuse:/usr/bin:/bin" python3 "$TALLY" --log "$L" --now "$NOW" --weekly --out "$T/h3.jsonl" >/dev/null 2>"$T/e3"; rc=$?
[ "$rc" = "0" ] && [ -s "$T/h3.jsonl" ] && grep -q 'notify. exited 3' "$T/e3" && ok "notify refusing (exit 3): tally still recorded, rc 0, and the failed send is reported on stderr" || bad "notify refusing: rc=$rc $(cat "$T/e3")"

# the CODES are the contract with the producers: every code the lib / dispatcher can emit is bucketed, and no
# bucket is dead. (The tally once matched the free-text reason; the lib's sentence differed, and ~96% of decisions
# landed in the wrong bucket while this selftest stayed green on a hand-written fixture.)
KNOWN=$(python3 "$TALLY" --list-codes | cut -f1 | sort -u)
EMITTED=$( { grep -o '_gate_fastlane_normal "[a-z-]*"' "$LIB" | sed 's/.*"\(.*\)"/\1/'
             grep -h -o 'GATE_LANE_REASON_CODE="[a-z-]*"' "$LIB" "$DISPATCHER" | sed 's/.*="\(.*\)"/\1/'; } | grep -v -x -e fast -e '' | sort -u)
[ -n "$EMITTED" ] && ok "found the reason codes the producers emit: $(printf '%s' "$EMITTED" | tr '\n' ' ')" || bad "could not extract any emitted reason code (grep drifted)"
MISSING=$(comm -23 <(printf '%s\n' "$EMITTED") <(printf '%s\n' "$KNOWN") | tr '\n' ' ')
[ -z "$MISSING" ] && ok "every emitted reason code has a tally bucket" || bad "emitted but NOT bucketed (would read as 'outro'): $MISSING"
DEAD=$(comm -13 <(printf '%s\n' "$EMITTED") <(printf '%s\n' "$KNOWN") | tr '\n' ' ')
[ -z "$DEAD" ] && ok "every tally bucket is a code some producer emits (no dead bucket)" || bad "bucket no producer emits: $DEAD"

# the order + wrapper agree
grep -q '^exec = "\$PACK_DIR/assets/scripts/gate-lane-weekly.sh"$' "$ORDER" && ok "order exec points at the wrapper (single path, like jev-preambulo)" || bad "order exec line drifted"
grep -q '^interval = "168h"$' "$ORDER" && grep -q '^trigger = "cooldown"$' "$ORDER" && ok "order is weekly (cooldown 168h)" || bad "order schedule drifted"
grep -q 'gate-lane-tally.py" --weekly --days 7' "$WEEKLY" && ok "wrapper runs the tally in --weekly mode over 7 days" || bad "wrapper drifted"
grep -q -i -E 'gc mail|mail send' "$TALLY" "$WEEKLY" && bad "the tally mails someone (the pattern that got the previous weekly report disabled)" || ok "no mail path anywhere in the tally/wrapper"
STRAY_IDS=$(grep -n -o -E 'ga-[a-z0-9]{5,7}' "$TALLY" "$WEEKLY" | grep -v 'ga-atsahv' || true)
if [ -n "$STRAY_IDS" ]; then bad "a hardcoded bead id other than the story's own appears in the tally"; else ok "no hardcoded bead id besides the story's own"; fi

echo
echo "== gate-lane-tally.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
