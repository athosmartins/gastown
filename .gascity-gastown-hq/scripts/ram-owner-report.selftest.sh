#!/usr/bin/env bash
# Selftest for ram-owner-report.py (ga-yr8vm). Fixture-driven, deterministic.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SELF_DIR/ram-owner-report.py"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW=1787700000

mkrec() {  # ts owner1 rss1 owner2 rss2 owner3 rss3 owner4 rss4
  python3 -c "
import json
ts=$1
by_owner={'$2': $3, '$4': $5, '$6': $7, '$8': $9}
owner_kind={'$2':'daemon','$4':'daemon','$6':'session','$8':'session'}
print(json.dumps({'ts': ts, 'by_owner': by_owner, 'owner_kind': owner_kind,
                   'by_rig': {'hq': $3+$5}, 'total_rss_kb': $3+$5+$7+$9,
                   'unresolved_kb': 0, 'swap_used_mb': 100.0, 'swap_total_mb': 200.0,
                   'free_pct': 40}))
"
}

{
  mkrec $((NOW-3*3600)) daemon-x 1000 other-daemon 500 idle-sess 2000 active-sess 1500
  mkrec $((NOW-2*3600)) daemon-x 1000 other-daemon 500 idle-sess 2000 active-sess 1500
  mkrec $((NOW-1*3600)) daemon-x 1000 other-daemon 500 idle-sess 2000 active-sess 1500
  mkrec "$NOW"          daemon-x 2000 other-daemon 500 idle-sess 2000 active-sess 1500
} > "$TMP/history.jsonl"

python3 -c "
import json, datetime
now = $NOW
def iso(sec_ago):
    return datetime.datetime.fromtimestamp(now - sec_ago, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
print(json.dumps({'sessions': [
  {'session_key': 'idle', 'name': 'idle-sess', 'template': 'x', 'work_dir': '/x', 'last_active': iso(3*3600)},
  {'session_key': 'active', 'name': 'active-sess', 'template': 'x', 'work_dir': '/x', 'last_active': iso(1800)},
]}))
" > "$TMP/sessions.json"

run_report() {
  RAM_OWNER_NOW_EPOCH="$NOW" RAM_OWNER_SESSIONS_FIXTURE="$TMP/sessions.json" \
  RAM_OWNER_PS_FIXTURE="$TMP/empty_ps.txt" \
    python3 "$REPORT" "$@"
}
: > "$TMP/empty_ps.txt"

echo "── Scenario: history mode — growth, median, top3 ──"
OUT=$(run_report --in "$TMP/history.jsonl" --json 2>"$TMP/stderr")
rc=$?
[ "$rc" -eq 0 ] || bad "report exited $rc: $(cat "$TMP/stderr")"

jget() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d$1)" "$OUT" 2>/dev/null; }

[ "$(jget "['growth_since_last_kb']['daemon-x']")" = "1000" ] && ok "growth-since-last: daemon-x +1000kb detected" || bad "growth wrong: $(jget "['growth_since_last_kb']")"
[ "$(jget "['growth_since_last_kb']['other-daemon']")" = "0" ] && ok "growth-since-last: unchanged owner shows 0, not missing" || bad "other-daemon growth wrong"
[ "$(jget "['historical_medians_kb']['daemon-x']")" = "1000" ] && ok "historical median excludes the latest sample (1000, not pulled toward the 2000 spike)" || bad "median wrong: $(jget "['historical_medians_kb']")"

N_TOP3=$(jget "['top3_opportunities']" | python3 -c "import ast,sys; print(len(ast.literal_eval(sys.stdin.read())))" 2>/dev/null)
[ "$N_TOP3" = "2" ] && ok "top3 found exactly the 2 real candidates (not the 2 unchanged owners)" || bad "top3 count wrong: got $N_TOP3 — $(jget "['top3_opportunities']")"

FIRST_OWNER=$(jget "['top3_opportunities'][0]['owner']")
[ "$FIRST_OWNER" = "idle-sess" ] && ok "top3 ranked by estimated gain: idle-sess (2000kb) ranks above daemon-x (1000kb)" || bad "top3 ordering wrong, first=$FIRST_OWNER"
SECOND_KIND=$(jget "['top3_opportunities'][1]['kind']")
[ "$SECOND_KIND" = "above_median_daemon" ] && ok "daemon-x correctly classified as above_median_daemon (2x its own median)" || bad "second candidate kind wrong: $SECOND_KIND"

echo ""
echo "── Scenario: active-sess (idle <2h) must NOT appear as a cut opportunity ──"
# scope the check to the top3 array specifically — active-sess legitimately
# appears elsewhere in the JSON (growth/medians cover every owner), so a
# whole-blob grep would false-positive on those unrelated sections.
jget "['top3_opportunities']" | grep -q "active-sess" && bad "active-sess leaked into top3 despite being active <2h" || ok "active-sess correctly excluded from top3 (not idle long enough)"

echo ""
echo "── Scenario: --top N live mode, ps read fails -> explicit failure message, not a happy-path-shaped line ──"
# Genuinely empty ps fixture. (A prior version of this scenario fed
# $SELF_DIR/../scripts/ram-owner-sampler.selftest.sh itself as "garbage" —
# it isn't: that sibling file's own heredoc embeds a verbatim, well-formed
# "pid ppid rss comm args" row for ITS fixtures, so ps_snapshot() parsed one
# real process out of it and this scenario silently exercised the HAPPY path
# while claiming to prove the FAILURE path. Caught in ga-yr8vm gate review,
# attempt 1.) RAM_OWNER_SESSIONS_FIXTURE is set too so a future reordering of
# sample()'s failure check couldn't silently make this scenario shell out to
# a live `gc session list`.
TOP_FAIL_OUT=$(RAM_OWNER_NOW_EPOCH="$NOW" \
  RAM_OWNER_PS_FIXTURE="$TMP/empty_ps.txt" \
  RAM_OWNER_SESSIONS_FIXTURE="$TMP/sessions.json" \
  python3 "$REPORT" --top 3 2>&1)
echo "$TOP_FAIL_OUT" | grep -qi "falha na leitura" && ok "--top on a failed ps read prints the explicit failure message" || bad "--top did not degrade explicitly on empty ps: $TOP_FAIL_OUT"

echo ""
echo "── Scenario: --top N live mode, real ps data -> resolves owners, never touches the JSONL ──"
cat > "$TMP/top_ps.txt" <<EOF
100 1 40000 dolt dolt sql-server
200 50000 362576 claude claude --settings {} --model sonnet --session-id 5923529a-5a66-49c7-a5eb-cced45033d61 --effort max
EOF
python3 -c "
import json
print(json.dumps({'sessions': [
  {'session_key': '5923529a-5a66-49c7-a5eb-cced45033d61', 'name': 'gastown.dog-2', 'template': 'gastown.dog', 'work_dir': '/x'},
]}))
" > "$TMP/top_sessions.json"
TOP_OK_OUT=$(RAM_OWNER_NOW_EPOCH="$NOW" \
  RAM_OWNER_PS_FIXTURE="$TMP/top_ps.txt" \
  RAM_OWNER_SESSIONS_FIXTURE="$TMP/top_sessions.json" \
  python3 "$REPORT" --top 3 2>&1)
echo "$TOP_OK_OUT" | grep -q "gastown.dog-2=354MB" && ok "--top resolves a real claude PID to its session name via --session-id join" || bad "--top did not resolve real owners: $TOP_OK_OUT"
echo "$TOP_OK_OUT" | grep -qi "AVISO" && bad "--top wrongly showed the session-lookup-failed AVISO despite a successful lookup: $TOP_OK_OUT" || ok "--top shows no AVISO when the session lookup actually succeeded"

echo ""
echo "── Scenario: no history file yet -> graceful message, not a crash ──"
NO_DATA=$(run_report --in "$TMP/does-not-exist.jsonl" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "missing JSONL exits 0 with an explanatory message" || bad "missing JSONL should not be a hard failure, got rc=$rc"
echo "$NO_DATA" | grep -qi "sem" && ok "message says explicitly there's no data yet (not silently empty output)" || bad "no-data message missing/unclear: $NO_DATA"

echo ""
echo "ram-owner-report selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
