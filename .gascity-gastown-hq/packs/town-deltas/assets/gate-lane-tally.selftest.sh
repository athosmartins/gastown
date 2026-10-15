#!/usr/bin/env bash
# gate-lane-tally.selftest.sh (ga-atsahv item 4) — the weekly "rounds saved" tally, against a synthetic
# quality-gate.jsonl and a fixed clock. Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALLY="${GATE_LANE_TALLY_UNDER_TEST:-$SELF_DIR/gate-lane-tally.py}"   # a control run points this at the previous tally
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
STRAY_IDS=$(grep -h -n -o -E 'ga-[a-z0-9]{5,7}' "$TALLY" "$WEEKLY" | grep -v -E 'ga-(atsahv|dzzqvw)' || true)   # -h: the file's NAME is not part of what is checked (a worktree path with ga-dzzqvw in it hid every hit)
if [ -n "$STRAY_IDS" ]; then bad "a hardcoded bead id other than the two stories this tally serves appears in the tally"; else ok "no hardcoded bead id besides the two stories this tally serves (ga-atsahv, ga-dzzqvw)"; fi

# ── the task-rapida lane (ga-dzzqvw): how many, why not, first review, time, bugs after ──────────────────────────────────────
cat > "$T/bin/bd" <<'EOF'
#!/bin/bash
echo "$*" >> "${FAKE_BD_LOG:-/dev/null}"
if [ -n "${FAKE_BD_BY_STORE:-}" ]; then   # per-store answers: <dir>/<path with / as _> is the JSON, <that>.fail makes THAT store fail; a store with neither is a real empty list
  f="$FAKE_BD_BY_STORE/$(printf %s "$2" | tr '/' '_')"
  if [ -e "$f.fail" ]; then echo "boom in $2" >&2; exit 1; fi
  if [ -e "$f" ]; then cat "$f"; else echo '[]'; fi
  exit 0
fi
case "${FAKE_BD_MODE:-ok}" in
  fail) echo "boom" >&2; exit 1 ;;
  notlist) echo '{"error":"x"}' ;;
  badrow) echo '[{"title":"a row with no id"}]' ;;
  *) cat "$FAKE_BD_JSON" ;;
esac
EOF
cat > "$T/bin/gc" <<'EOF'
#!/bin/bash
echo "$*" >> "${FAKE_GC_LOG:-/dev/null}"
case "${FAKE_GC_MODE:-ok}" in
  fail) echo "gc boom" >&2; exit 1 ;;
  junk) echo "not json" ;;
  notlist) echo '{"rigs":{"whatsapp_automation":"/rigW"}}' ;;
  *) cat "$FAKE_GC_JSON" ;;
esac
EOF
chmod +x "$T/bin/bd" "$T/bin/gc"
cat > "$T/bugs.json" <<'EOF'
[{"id":"bug-1","title":"quebrou depois de ga-b1","created_at":"2026-10-02T12:00:00Z"},
 {"id":"bug-2","title":"y","description":"regressao em ga-b2.","created_at":"2026-10-03T10:00:00Z"},
 {"id":"bug-3","title":"antes da decisao: ga-b1","created_at":"2026-10-02T08:00:00Z"},
 {"id":"bug-4","title":"ga-b10 ga-b1-x ga-b1.2 xga-b1","created_at":"2026-10-06T00:00:00Z"},
 {"id":"bug-5","title":"nada a ver","created_at":"2026-10-06T00:00:00Z"},
 {"id":"bug-6","title":"w","description":"ga-b3 falhou","created_at":"sem data"}]
EOF
L3="$T/qg3.jsonl"
cat > "$L3" <<'EOF'
{"ts":"2026-09-20T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg-old","bead":"ga-bold","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg1","bead":"ga-b1","tr_code":"granted","tr_lines":"150","dry_run":"0"}
{"ts":"2026-10-02T09:05:00Z","event":"dispatcher_complete","lane":"task-rapida","marker":"tg1","result":"PASS","elapsed_s":300,"dry_run":"0"}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg2","bead":"ga-b2","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-03T09:15:00Z","event":"dispatcher_complete","lane":"normal","marker":"tg2","result":"FAIL","elapsed_s":900,"dry_run":"0"}
{"ts":"2026-10-03T11:00:00Z","event":"dispatcher_complete","lane":"normal","marker":"tg2","result":"PASS","elapsed_s":200,"dry_run":"0"}
{"ts":"2026-10-04T08:00:00Z","event":"gate_lane","lane":"normal","marker":"tg4","reason_code":"code-or-prompt","tr_code":"over-limit","dry_run":"0"}
{"ts":"2026-10-04T08:30:00Z","event":"dispatcher_complete","lane":"normal","marker":"tg4","result":"FAIL","elapsed_s":77777,"dry_run":"0"}
{"ts":"2026-10-04T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg3","bead":"ga-b3","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-04T10:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg4","bead":"ga-b4","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-04T10:20:00Z","event":"dispatcher_complete","lane":"normal","marker":"tg4","result":"PASS","dry_run":"0"}
{"ts":"2026-10-05T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg5","bead":"ga-b5","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-05T09:30:00Z","event":"gate_lane","lane":"normal","marker":"tg5","reason_code":"code-or-prompt","tr_code":"risk-file","dry_run":"0"}
{"ts":"2026-10-05T10:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"tg-dry","bead":"ga-bdry","tr_code":"granted","dry_run":"1"}
{"ts":"2026-10-06T09:00:00Z","event":"gate_lane","lane":"normal","marker":"r1","reason_code":"code-or-prompt","tr_code":"not-task","dry_run":"0"}
{"ts":"2026-10-06T09:30:00Z","event":"dispatcher_complete","lane":"normal","marker":"r1","result":"FAIL","elapsed_s":99999,"dry_run":"0"}
{"ts":"2026-10-06T09:01:00Z","event":"gate_lane","lane":"normal","marker":"r2","reason_code":"code-or-prompt","tr_code":"not-task","dry_run":"0"}
{"ts":"2026-10-06T09:02:00Z","event":"gate_lane","lane":"normal","marker":"r3","reason_code":"code-or-prompt","tr_code":"over-limit","dry_run":"0"}
{"ts":"2026-10-06T09:03:00Z","event":"gate_lane","lane":"normal","marker":"r4","reason_code":"code-or-prompt","tr_code":"banana","dry_run":"0"}
{"ts":"2026-10-06T09:04:00Z","event":"gate_lane","lane":"normal","marker":"r5","reason_code":"code-or-prompt","tr_code":"switch-off","dry_run":"0"}
{"ts":"2026-10-06T09:05:00Z","event":"gate_lane","lane":"normal","marker":"r6","reason_code":"code-or-prompt","tr_code":42,"dry_run":"0"}
{"ts":"2026-10-06T09:06:00Z","event":"gate_lane","lane":"normal","marker":"n1","reason_code":"code-or-prompt","dry_run":"0"}
{"ts":"2026-10-06T09:07:00Z","event":"gate_lane","lane":"fast","marker":"f1","would_have_reviewers":1,"reason_code":"fast","tr_code":"","dry_run":"0"}
{"ts":"2026-10-06T09:08:00Z","event":"dispatcher_complete","lane":"fast","marker":"f1","result":"PASS","dry_run":"0"}
EOF
BDLOG="$T/bd.log"; : > "$BDLOG"
J3=$(PATH="$T/bin:$PATH" FAKE_BD_JSON="$T/bugs.json" FAKE_BD_LOG="$BDLOG" python3 "$TALLY" --log "$L3" --now "$NOW" --json --bug-city /cityA --bug-city /cityB)
chkj() { local got; got=$(printf '%s' "$J3" | python3 -c "import sys,json; print(json.load(sys.stdin)$2)" 2>&1); [ "$got" = "$3" ] && ok "task-rapida: $1 = $3" || bad "task-rapida: $1: got '$got', want '$3'"; }
chkj "decisions (the re-decided tg5 counts once, as normal; dry run and pre-window grant are out)" "['decisions']" 13
chkj "grants (last decision per marker): tg1-tg4" "['tr_granted']" 4
chkj "a grant is neither fast nor normal: normal = tg5 + r1-r6 + n1" "['normal']" 8
chkj "…and a grant never lands in the fast-lane's 'outro' bucket" "['normal_reasons'].get('outro (reason_code desconhecido)', 0)" 0
chkj "refusals: tg5 (risk-file) + 2 not-task + over-limit + banana + switch-off + a non-string code; n1 (no tr_code) is not one" "['tr_refused']" 7
chkj "refusal bucket, a listed code, by its label" "['tr_refusals']['bead de origem nao e task']" 2
chkj "refusal bucket: a code nobody listed AND a non-string code land in 'outro', loudly" "['tr_refusals']['outro (reason_code desconhecido)']" 2
chkj "first review: PASS (tg1, whose event says lane=task-rapida; tg4, whose event says lane=normal — the shape the dispatcher really writes, ga-ufeq1c — and whose earlier normal-lane FAIL is not the lane's)" "['tr_first_pass']" 2
chkj "first review: FAIL (tg2, completed as lane=normal — its later PASS is not the first review; r1's normal-lane FAIL is no lane run)" "['tr_first_fail']" 1
chkj "granted with no completed run in the window (tg3)" "['tr_no_verdict']" 1
chkj "time: median of the first runs with a readable elapsed_s (300, 900)" "['tr_elapsed_median_s']" 600.0
chkj "time: max" "['tr_elapsed_max_s']" 900
chkj "time: first runs above 10 min (the story's bar)" "['tr_over_10min']" 1
chkj "time: a run with no elapsed_s is counted apart, not as 0 (tg4)" "['tr_elapsed_unknown']" 1
chkj "time: max is the lane's own 900 s — the 77777 s (tg4, before its grant) and 99999 s (r1, normal lane) runs are not the lane's" "['tr_elapsed_max_s']" 900
# the join is what finds the lane's runs (their events say lane=normal): take it out and the lane's first reviews vanish — the check can fail
sed 's/ or (decision_in_effect(c.get("marker"), t) or {}).get("lane") == "task-rapida"//' "$TALLY" > "$T/tally-mut-join.py"
if cmp -s "$TALLY" "$T/tally-mut-join.py"; then bad "task-rapida mutation: the join expression was not found in the tally (the control is a no-op)"
else
  JMJ=$(PATH="$T/bin:$PATH" FAKE_BD_JSON="$T/bugs.json" python3 "$T/tally-mut-join.py" --log "$L3" --now "$NOW" --json)
  [ "$(printf '%s' "$JMJ" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tr_first_pass'], d['tr_first_fail'], d['tr_no_verdict'])")" = "1 0 3" ] \
    && ok "task-rapida mutation: without the join only tg1 (lane=task-rapida on its event) is seen — the other three read as 'no verdict'" \
    || bad "task-rapida mutation: the join does not matter to the counts: $JMJ"
fi
chkj "bugs after: bug-1 (ga-b1), bug-2 (ga-b2 + sentence dot), bug-6 (ga-b3, undated: counted); not bug-3 (before the grant), bug-4 (ga-b10, ga-b1-x, ga-b1.2, xga-b1), bug-5" "['tr_bugs_after_ids']" "['bug-1', 'bug-2', 'bug-6']"
grep -q -- '-C /cityA list -t bug --all --limit 0 --created-after 2026-10-01T12:00:00Z --json' "$BDLOG" && grep -q -- '-C /cityB list' "$BDLOG" && ok "task-rapida: every --bug-city is searched, all statuses, no truncation, from the window start" || bad "task-rapida: bd calls: $(cat "$BDLOG")"
for mode in fail notlist badrow; do
  JM=$(PATH="$T/bin:$PATH" FAKE_BD_MODE=$mode python3 "$TALLY" --log "$L3" --now "$NOW" --json)
  [ "$(printf '%s' "$JM" | python3 -c "import sys,json; print(json.load(sys.stdin)['tr_bugs_after'])")" = "None" ] && ok "task-rapida: bd answers '$mode' → bugs-after is null (could not tell), never 0" || bad "task-rapida: bd '$mode' collapsed to a number: $JM"
done
TM=$(PATH="$T/bin:$PATH" FAKE_BD_MODE=fail python3 "$TALLY" --log "$L3" --now "$NOW")
case "$TM" in *"NÃO DEU PARA APURAR"*"NÃO é zero"*) ok "task-rapida: the report says the bug look-up failed and that it is not zero" ;; *) bad "task-rapida: the failed look-up is not loud: $TM" ;; esac
JNONE=$(PATH="$T/bin:$PATH" FAKE_BD_LOG="$T/bd-none.log" python3 "$TALLY" --log "$L2" --now "$NOW" --json)
[ "$(printf '%s' "$JNONE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tr_granted'], d['tr_refused'], d['tr_bugs_after'])")" = "0 0 0" ] && [ ! -s "$T/bd-none.log" ] && ok "task-rapida: nothing granted → bugs-after is a real 0 and bd is not even called" || bad "task-rapida: no-grant window: $JNONE / $(cat "$T/bd-none.log" 2>/dev/null)"
T3=$(PATH="$T/bin:$PATH" FAKE_BD_JSON="$T/bugs.json" python3 "$TALLY" --log "$L3" --now "$NOW" --bug-city /cityA --bug-city /cityB)
for want in "task-rapida 4" "1ª revisão: PASS 2 | FAIL 1 | sem veredito na janela 1 (de 4 concedida(s))" "mediana 10.0 min, máx 15.0 min, acima de 10 min: 1" "1 run(s) sem elapsed_s legível" "2  não concedida: bead de origem nao e task" "bugs abertos depois citando uma task da faixa: 3 (bug-1, bug-2, bug-6) [lojas buscadas:"; do
  case "$T3" in *"$want"*) ok "task-rapida report: '$want'" ;; *) bad "task-rapida report lacks '$want': $T3" ;; esac
done
NL3=$(PATH="$T/bin:$PATH" FAKE_BD_JSON="$T/bugs.json" python3 -c "
import importlib.util, json, sys
s = importlib.util.spec_from_file_location('t', '$TALLY'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.notify_line(json.loads(sys.argv[1])))" "$J3")
case "$NL3" in *"task-rapida: 4 concedida(s), 7 não concedida(s), 1ª revisão PASS 2/FAIL 1, mediana 10.0 min, bugs depois 3"*) ok "task-rapida: the notify line (the only thing a human reads) carries the lane's numbers" ;; *) bad "task-rapida: notify line: $NL3" ;; esac
[ "$(python3 "$TALLY" --list-tr-codes | wc -l | tr -d ' ')" = "25" ] && python3 "$TALLY" --list-tr-codes | grep -q '^granted	' && ok "task-rapida: --list-tr-codes lists the 25 codes (granted + 24 refusals)" || bad "task-rapida: --list-tr-codes"

# ── gate-fix 1 (gate_run ga-lkohfb): the bugs-after search looks where the answer lives, and says when it did not ─────────────────────────
# The lane's tasks are rig beads (wa-, ps-), and their bugs are filed in THEIR rig's store. A search of the HQ store alone reported "no bugs" for
# a place where none are filed. The stores now come from the rig on each grant's event (rig list), and a grant whose store was not looked at
# makes the count unknown (null + how many + why), never a number.
pj() { printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)" 2>&1; }
chk4() { local got; got=$(pj "$2" "$3"); [ "$got" = "$4" ] && ok "task-rapida: $1 = $4" || bad "task-rapida: $1: got '$got', want '$4'"; }
mkdir -p "$T/st"
cat > "$T/rigs.json" <<'EOF'
{"rigs":[{"name":"gascity","path":"/hq"},{"name":"whatsapp_automation","path":"/rigW"},{"name":"property_scrapers","path":"/rigP"}]}
EOF
L4="$T/qg4.jsonl"
cat > "$L4" <<'EOF'
{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"w1","bead":"wa-w1","rig":"whatsapp_automation","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-02T09:05:00Z","event":"dispatcher_complete","lane":"normal","marker":"w1","result":"PASS","elapsed_s":300,"dry_run":"0"}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"p1","bead":"ps-p1","rig":"property_scrapers","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-03T09:05:00Z","event":"dispatcher_complete","lane":"normal","marker":"p1","result":"PASS","elapsed_s":400,"dry_run":"0"}
{"ts":"2026-10-04T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"g1","bead":"ga-g1","rig":"gascity","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-04T09:05:00Z","event":"dispatcher_complete","lane":"normal","marker":"g1","result":"PASS","elapsed_s":500,"dry_run":"0"}
EOF
echo '[{"id":"bug-w","title":"quebrou wa-w1","created_at":"2026-10-02T12:00:00Z"}]' > "$T/st/_rigW"
echo '[{"id":"bug-g","title":"quebrou ga-g1","created_at":"2026-10-04T12:00:00Z"},{"id":"bug-h","title":"infra do gate","description":"citou wa-w1 sem o bead de origem","created_at":"2026-10-02T13:00:00Z"}]' > "$T/st/_hq"
GCLOG="$T/gc.log"; : > "$GCLOG"; BDLOG4="$T/bd4.log"; : > "$BDLOG4"
run4() { GC_CITY_PATH=/hq PATH="$T/bin:$PATH" FAKE_GC_JSON="$T/rigs.json" FAKE_GC_LOG="$GCLOG" FAKE_BD_BY_STORE="$T/st" FAKE_BD_LOG="$BDLOG4" python3 "$1" --log "$2" --now "$NOW" "${@:3}"; }
J4=$(run4 "$TALLY" "$L4" --json)
chk4 "no --bug-city at all: the rig stores AND the HQ store are searched (bug-h is filed in HQ about a wa- task; bug-w in the rig's own store)" "$J4" "d['tr_bugs_after'], d['tr_bugs_after_ids']" "3 ['bug-g', 'bug-h', 'bug-w']"
chk4 "coverage is carried: the stores that were read" "$J4" "d['tr_stores']" "['/hq', '/rigP', '/rigW']"
chk4 "nothing left un-looked-up" "$J4" "d['tr_bugs_uncovered'], d['tr_stores_failed']" "0 []"
chk4 "the rigs the grants came from are in the output (what 'every store was read' is measured against)" "$J4" "d['tr_grant_rigs']" "['gascity', 'property_scrapers', 'whatsapp_automation']"
grep -q -- '-C /rigW list' "$BDLOG4" && grep -q -- '-C /rigP list' "$BDLOG4" && grep -q -- '-C /hq list' "$BDLOG4" && ok "task-rapida: bd was called on /rigW, /rigP and the HQ store (the rig list drove it)" || bad "task-rapida: bd calls: $(cat "$BDLOG4")"
grep -q -- 'rig list --json' "$GCLOG" && ok "task-rapida: the stores come from gc rig list" || bad "task-rapida: gc was not asked: $(cat "$GCLOG")"
NL4=$(python3 -c "
import importlib.util, json, sys
s = importlib.util.spec_from_file_location('t', '$TALLY'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.notify_line(json.loads(sys.argv[1])))" "$J4")
case "$NL4" in *"bugs depois 3 (lojas: hq, rigP, rigW)"*) ok "task-rapida: the notify line says WHICH stores the bug count covers" ;; *) bad "task-rapida: notify line carries no store coverage: $NL4" ;; esac

# a rig nobody can resolve: its grant was not looked up, so the count is unknown — the other grants' finds are kept as a floor
L5="$T/qg5.jsonl"; { head -n 2 "$L4"; echo '{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"x1","bead":"zz-x1","rig":"mystery_rig","tr_code":"granted","dry_run":"0"}'; } > "$L5"
J5=$(run4 "$TALLY" "$L5" --json)
chk4 "a grant whose rig is not in the rig list: the count is null, not a number" "$J5" "d['tr_bugs_after']" "None"
chk4 "…one grant of two was not looked up, and the other's finds (bug-w in its rig, bug-h in HQ) are kept as a floor" "$J5" "d['tr_bugs_uncovered'], d['tr_bugs_found_partial']" "1 2"
case "$(pj "$J5" "d['tr_bugs_note']")" in *"mystery_rig"*"não resolvida"*) ok "task-rapida: the note names the rig whose store did not resolve" ;; *) bad "task-rapida: note: $(pj "$J5" "d['tr_bugs_note']")" ;; esac
T5=$(run4 "$TALLY" "$L5")
case "$T5" in *"NÃO DEU PARA APURAR em 1 de 2 concedida(s)"*"achados nas outras: 2"*"NÃO é zero"*) ok "task-rapida: the report says 1 of 2 was not looked up, what the others found, and that it is not zero" ;; *) bad "task-rapida: report: $T5" ;; esac
NL5=$(python3 -c "
import importlib.util, json, sys
s = importlib.util.spec_from_file_location('t', '$TALLY'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.notify_line(json.loads(sys.argv[1])))" "$J5")
case "$NL5" in *"ATENÇÃO bugs depois NÃO apurado em 1/2 concedida(s)"*"mystery_rig"*"não é zero"*) ok "task-rapida: the notify line (the one a human reads) carries the gap and its reason" ;; *) bad "task-rapida: notify line hides the gap: $NL5" ;; esac

# the rig list itself fails or is garbage: every rig grant is un-looked-up, and the reason says what gc said
for mode in fail junk notlist; do
  JG=$(GC_CITY_PATH=/hq PATH="$T/bin:$PATH" FAKE_GC_MODE=$mode FAKE_GC_JSON="$T/rigs.json" FAKE_BD_BY_STORE="$T/st" python3 "$TALLY" --log "$L4" --now "$NOW" --json)
  chk4 "gc rig list '$mode': the count is null, all 3 grants un-looked-up" "$JG" "d['tr_bugs_after'], d['tr_bugs_uncovered']" "None 3"
done
JG=$(GC_CITY_PATH=/hq PATH="$T/bin:$PATH" FAKE_GC_MODE=fail FAKE_GC_JSON="$T/rigs.json" FAKE_BD_BY_STORE="$T/st" python3 "$TALLY" --log "$L4" --now "$NOW" --json)
case "$(pj "$JG" "d['tr_bugs_note']")" in *"gc rig list saiu com 1"*"gc boom"*) ok "task-rapida: the note carries gc's exit code and stderr" ;; *) bad "task-rapida: note: $(pj "$JG" "d['tr_bugs_note']")" ;; esac
JGN=$(GC_CITY_PATH=/hq PATH="$T/bin:$PATH" FAKE_GC_MODE=notlist FAKE_GC_JSON="$T/rigs.json" FAKE_BD_BY_STORE="$T/st" python3 "$TALLY" --log "$L4" --now "$NOW" --json)
case "$(pj "$JGN" "d['tr_bugs_note']")" in *"o campo rigs não é uma lista"*) ok "task-rapida: a rig list in another shape is named as such, not read as 'no rig has a path'" ;; *) bad "task-rapida: note: $(pj "$JGN" "d['tr_bugs_note']")" ;; esac

# one store cannot be read: the grants of that store are un-looked-up; the failed store is named with bd's own rc and stderr
touch "$T/st/_rigP.fail"
J6=$(run4 "$TALLY" "$L4" --json)
chk4 "one store failing (bd rc 1): the count is null" "$J6" "d['tr_bugs_after'], d['tr_bugs_uncovered'], d['tr_bugs_found_partial']" "None 1 3"
case "$(pj "$J6" "d['tr_stores_failed']")" in *"/rigP: bd saiu com 1: boom in /rigP"*) ok "task-rapida: the failed store is named with bd's rc and stderr (not a JSON-decode message)" ;; *) bad "task-rapida: failed: $(pj "$J6" "d['tr_stores_failed']")" ;; esac
rm -f "$T/st/_rigP.fail"
touch "$T/st/_hq.fail"
J6B=$(run4 "$TALLY" "$L4" --json)
chk4 "the HQ store failing leaves all 3 grants un-looked-up (the gate's own bugs are filed there)" "$J6B" "d['tr_bugs_after'], d['tr_bugs_uncovered']" "None 3"
rm -f "$T/st/_hq.fail"

# events with no rig and no --bug-city: nothing says where to look, so nothing is claimed
J7=$(PATH="$T/bin:$PATH" FAKE_BD_JSON="$T/bugs.json" python3 "$TALLY" --log "$L3" --now "$NOW" --json)
chk4 "grants with no rig on the event and no --bug-city: null, not a number" "$J7" "d['tr_bugs_after'], d['tr_bugs_uncovered']" "None 4"
case "$(pj "$J7" "d['tr_bugs_note']")" in *"sem rig no evento"*) ok "task-rapida: the note says why" ;; *) bad "task-rapida: note: $(pj "$J7" "d['tr_bugs_note']")" ;; esac
JF=$(PATH="$T/bin:$PATH" FAKE_BD_MODE=fail python3 "$TALLY" --log "$L3" --now "$NOW" --json --bug-city /cityA)
case "$(pj "$JF" "d['tr_stores_failed']")" in *"/cityA: bd saiu com 1: boom"*) ok "task-rapida: bd's rc is read BEFORE its output (a failing bd prints nothing parseable) and stderr is kept" ;; *) bad "task-rapida: failed: $(pj "$JF" "d['tr_stores_failed']")" ;; esac

# ── gate-fix 1, second blocking issue: a run that ended with neither PASS nor FAIL is no review and no run time ─────────────────────────────
L8="$T/qg8.jsonl"
cat > "$L8" <<'EOF'
{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"s1","bead":"ga-s1","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-02T09:01:00Z","event":"dispatcher_complete","lane":"normal","marker":"s1","result":"SKIPPED_BEAD_CLOSED","elapsed_s":0,"dry_run":"0"}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"s2","bead":"ga-s2","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-03T09:10:00Z","event":"dispatcher_complete","lane":"normal","marker":"s2","result":"PASS","elapsed_s":600,"dry_run":"0"}
{"ts":"2026-10-04T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"s3","bead":"ga-s3","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-04T09:01:00Z","event":"dispatcher_complete","lane":"normal","marker":"s3","result":"SKIPPED_BEAD_CLOSED","elapsed_s":0,"dry_run":"0"}
{"ts":"2026-10-04T10:00:00Z","event":"dispatcher_complete","lane":"normal","marker":"s3","result":"FAIL","elapsed_s":900,"dry_run":"0"}
{"ts":"2026-10-05T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"s4","bead":"ga-s4","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-05T09:01:00Z","event":"dispatcher_complete","lane":"normal","marker":"s4","dry_run":"0"}
{"ts":"2026-10-05T09:02:00Z","event":"dispatcher_complete","lane":"normal","marker":"s4","result":42,"dry_run":"0"}
EOF
run8() { PATH="$T/bin:$PATH" FAKE_BD_BY_STORE="$T/st" python3 "$1" --log "$L8" --now "$NOW" --bug-city /cityA "${@:2}"; }
J8=$(run8 "$TALLY" --json)
chk4 "first review: PASS s2; FAIL s3 (its earlier SKIPPED run is not a review); s1 and s4 have none" "$J8" "d['tr_first_pass'], d['tr_first_fail'], d['tr_no_verdict']" "1 1 2"
chk4 "the three parts add up to the grants (PASS + FAIL + no verdict = granted)" "$J8" "d['tr_first_pass'] + d['tr_first_fail'] + d['tr_no_verdict'] == d['tr_granted']" "True"
chk4 "runs that ended without a verdict are counted apart, by result (a missing and a non-string result both read '(sem result)')" "$J8" "d['tr_ended_no_verdict'], sorted(d['tr_ended_results'].items())" "4 [('(sem result)', 2), ('SKIPPED_BEAD_CLOSED', 2)]"
chk4 "time: the median is of s2 (600) and s3 (900) only — a 0 s SKIPPED run is no run time" "$J8" "d['tr_elapsed_median_s'], d['tr_elapsed_max_s'], d['tr_elapsed_unknown']" "750.0 900 0"
T8=$(run8 "$TALLY")
for want in "1ª revisão: PASS 1 | FAIL 1 | sem veredito na janela 2 (de 4 concedida(s))" "4 run(s) da faixa encerrado(s) sem veredito PASS/FAIL ((sem result) 2, SKIPPED_BEAD_CLOSED 2)" "mediana 12.5 min"; do
  case "$T8" in *"$want"*) ok "task-rapida report: '$want'" ;; *) bad "task-rapida report lacks '$want': $T8" ;; esac
done
NL8=$(python3 -c "
import importlib.util, json, sys
s = importlib.util.spec_from_file_location('t', '$TALLY'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.notify_line(json.loads(sys.argv[1])))" "$J8")
case "$NL8" in *"4 run(s) da faixa encerrado(s) sem veredito"*) ok "task-rapida: the notify line counts the runs that ended without a verdict" ;; *) bad "task-rapida: notify line: $NL8" ;; esac

# the low findings of the same review: a marker re-decided after its run, and runs with no marker
L9="$T/qg9.jsonl"
cat > "$L9" <<'EOF'
{"ts":"2026-10-02T09:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"d1","bead":"ga-d1","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-02T09:05:00Z","event":"dispatcher_complete","lane":"normal","marker":"d1","result":"PASS","elapsed_s":300,"dry_run":"0"}
{"ts":"2026-10-03T09:00:00Z","event":"gate_lane","lane":"normal","marker":"d1","reason_code":"code-or-prompt","tr_code":"risk-file","dry_run":"0"}
{"ts":"2026-10-03T10:00:00Z","event":"gate_lane","lane":"task-rapida","marker":"d2","bead":"ga-d2","tr_code":"granted","dry_run":"0"}
{"ts":"2026-10-04T09:05:00Z","event":"dispatcher_complete","lane":"task-rapida","result":"PASS","elapsed_s":100,"dry_run":"0"}
{"ts":"2026-10-04T09:06:00Z","event":"dispatcher_complete","lane":"task-rapida","result":"FAIL","elapsed_s":200,"dry_run":"0"}
EOF
J9=$(PATH="$T/bin:$PATH" FAKE_BD_BY_STORE="$T/st" python3 "$TALLY" --log "$L9" --now "$NOW" --json --bug-city /cityA)
chk4 "runs with no marker are each their own run, not merged into one '?' (PASS 1 + FAIL 1), next to d1's PASS" "$J9" "d['tr_first_pass'], d['tr_first_fail'], d['tr_unattributed']" "2 1 2"
chk4 "a marker re-decided to normal after its run: its first review counts in PASS/FAIL and is said to be outside 'granted'" "$J9" "d['tr_granted'], d['tr_first_outside_grants'], d['tr_no_verdict']" "1 1 1"
T9=$(PATH="$T/bin:$PATH" FAKE_BD_BY_STORE="$T/st" python3 "$TALLY" --log "$L9" --now "$NOW" --bug-city /cityA)
for want in "1 1ª revisão(ões) de marker(s) cuja concessão foi trocada depois" "2 run(s) da faixa sem marker no evento"; do
  case "$T9" in *"$want"*) ok "task-rapida report: '$want'" ;; *) bad "task-rapida report lacks '$want': $T9" ;; esac
done

# the checks above can fail: each guard taken out of the tally makes one of them see the difference
mutant() {   # mutant <name> <sed expression> <scenario that must then differ from the real tally's answer>
  sed "$2" "$TALLY" > "$T/mut-$1.py"
  if cmp -s "$TALLY" "$T/mut-$1.py"; then bad "task-rapida mutation '$1': the expression was not found in the tally (the control is a no-op)"; return 1; fi
}
mutant count-number 's/count=len(found) if not res\["uncovered"\] else None/count=len(found)/' && {
  [ "$(pj "$(run4 "$T/mut-count-number.py" "$L5" --json)" "d['tr_bugs_after']")" != "None" ] && ok "task-rapida mutation: with the 'uncovered → null' guard removed, an un-looked-up grant still yields a number (the checks above see it)" || bad "task-rapida mutation 'count-number' survives"; }
mutant store-down 's/if looked_up and down:/if False:/' && {
  touch "$T/st/_rigP.fail"; [ "$(pj "$(run4 "$T/mut-store-down.py" "$L4" --json)" "d['tr_bugs_after']")" != "None" ] && ok "task-rapida mutation: with the 'store could not be read' guard removed the count is a number (the checks above see it)" || bad "task-rapida mutation 'store-down' survives"; rm -f "$T/st/_rigP.fail"; }
mutant hq-down 's/for s in list(always) + (\[path\] if path else list(explicit)) if s in bad\]/for s in ([path] if path else list(explicit)) if s in bad]/' && {
  touch "$T/st/_hq.fail"; [ "$(pj "$(run4 "$T/mut-hq-down.py" "$L4" --json)" "d['tr_bugs_uncovered']")" != "3" ] && ok "task-rapida mutation: with the HQ store out of the coverage check, its failure no longer leaves the grants un-looked-up (the check above sees it)" || bad "task-rapida mutation 'hq-down' survives"; rm -f "$T/st/_hq.fail"; }
mutant no-verdict 's/if res not in ("PASS", "FAIL"):/if False:/' && {
  [ "$(pj "$(run8 "$T/mut-no-verdict.py" --json)" "d['tr_first_pass'], d['tr_first_fail'], d['tr_ended_no_verdict']")" != "1 1 4" ] && ok "task-rapida mutation: with the verdict filter removed, a SKIPPED run is counted as a review (the checks above see it)" || bad "task-rapida mutation 'no-verdict' survives"; }
mutant merged-unmarked 's/key = f"?{i}"/key = "?"/' && {
  [ "$(pj "$(PATH="$T/bin:$PATH" FAKE_BD_BY_STORE="$T/st" python3 "$T/mut-merged-unmarked.py" --log "$L9" --now "$NOW" --json --bug-city /cityA)" "d['tr_first_pass'], d['tr_first_fail']")" != "2 1" ] && ok "task-rapida mutation: with the per-run key removed the marker-less runs merge into one (the checks above see it)" || bad "task-rapida mutation 'merged-unmarked' survives"; }
mutant rc-after-json 's/    if p.returncode != 0:   # before the JSON/    if False:   # before the JSON/' && {
  [ "$(pj "$(PATH="$T/bin:$PATH" FAKE_BD_MODE=fail python3 "$T/mut-rc-after-json.py" --log "$L3" --now "$NOW" --json --bug-city /cityA)" "d['tr_stores_failed']")" != "$(pj "$JF" "d['tr_stores_failed']")" ] && ok "task-rapida mutation: without the rc check the failure reads as a JSON-decode message (the check above sees it)" || bad "task-rapida mutation 'rc-after-json' survives"; }

echo
echo "== gate-lane-tally.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
