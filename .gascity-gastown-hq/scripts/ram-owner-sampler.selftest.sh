#!/usr/bin/env bash
# Selftest for ram-owner-sampler.py + ram_owner_lib.py (ga-yr8vm).
# Fixture-driven (RAM_OWNER_PS_FIXTURE / RAM_OWNER_SESSIONS_FIXTURE) — never
# shells out to real ps/gc, so this is deterministic and touches no live state.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLER="$SELF_DIR/ram-owner-sampler.py"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── fixtures ─────────────────────────────────────────────────────────────
# pid ppid rss comm args...  (mirrors `ps -eo pid=,ppid=,rss=,comm=,args=`)
cat > "$TMP/ps.txt" <<'EOF'
1 0 100 launchd /sbin/launchd
50000 1 500 tmux tmux -u -L gascity new-session -d -s gastown__mayor
100 1 1012304 dolt dolt sql-server --config /Users/athos/gt/.gascity-gastown-hq/.gc/runtime/packs/dolt/dolt-config.yaml
200 50000 362576 claude claude --settings {} --model sonnet --session-id 5923529a-5a66-49c7-a5eb-cced45033d61 --effort max
201 50000 150000 claude claude --settings {} --model sonnet --session-id 11111111-1111-1111-1111-111111111111 --effort max
202 50000 50000 claude claude --settings {} --model sonnet --effort max --dangerously-skip-permissions
300 1 20000 bash /bin/bash /Users/athos/.gastown/scripts/ram-pressure-monitor.sh
600 700 3000 python3 python3 -c some-adhoc-thing-with-unreachable-parent
EOF

cat > "$TMP/sessions.json" <<'EOF'
{"sessions": [
  {"session_key": "5923529a-5a66-49c7-a5eb-cced45033d61", "name": "gastown.dog-2", "template": "gastown.dog", "work_dir": "/Users/athos/gt/.gascity-gastown-hq/.gc/agents/dogs/gastown.dog-2"},
  {"session_key": "11111111-1111-1111-1111-111111111111", "name": "wa-worker-x", "template": "wa-worker", "work_dir": "/Users/athos/gt/whatsapp_automation/crew/x"}
]}
EOF

run_sampler() {
  RAM_OWNER_PS_FIXTURE="$TMP/ps.txt" \
  RAM_OWNER_SESSIONS_FIXTURE="$TMP/sessions.json" \
  RAM_OWNER_OUT="$1" \
  RAM_OWNER_NOW_EPOCH="${2:-1787700000}" \
  RAM_OWNER_NOTIFY="$TMP/notify" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
    python3 "$SAMPLER" "${@:3}"
}

echo "── Scenario: one sample, correct attribution ──"
run_sampler "$TMP/out.jsonl" >/dev/null 2>"$TMP/stderr"
rc=$?
[ "$rc" -eq 0 ] || bad "sampler exited $rc (stderr: $(cat "$TMP/stderr"))"
REC=$(tail -1 "$TMP/out.jsonl" 2>/dev/null)
[ -n "$REC" ] && ok "wrote one JSONL record" || bad "no record written"

py_get() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d$1)" "$REC" 2>/dev/null; }

[ "$(py_get '["by_owner"]["gastown.dog-2"]')" = "362576" ] && ok "claude pid 200 -> session name via --session-id join" || bad "gastown.dog-2 RSS wrong/missing: $(py_get '["by_owner"]')"
[ "$(py_get '["by_owner"]["wa-worker-x"]')" = "150000" ] && ok "claude pid 201 -> different session correctly disambiguated" || bad "wa-worker-x RSS wrong/missing"
[ "$(py_get '["by_owner"]["claude (no session-id match)"]')" = "50000" ] && ok "claude pid 202 (no --session-id) falls back cleanly, not merged into another session" || bad "unmatched-claude fallback bucket wrong"
[ "$(py_get '["by_owner"]["dolt"]')" = "1012304" ] && ok "dolt pid 100 -> 'dolt' label directly" || bad "dolt attribution wrong"
[ "$(py_get '["by_owner"]["ram-pressure-monitor"]')" = "20000" ] && ok "bash-launched daemon under launchd -> script basename label" || bad "daemon label wrong: $(py_get '["by_owner"]')"
[ "$(py_get '["unresolved_kb"]')" = "3000" ] && ok "unreachable-parent process (pid 600) bucketed as unresolved, not silently dropped or misattributed" || bad "unresolved_kb wrong: $(py_get '["unresolved_kb"]')"
[ "$(py_get '["by_rig"]["hq"]')" = "362576" ] && ok "gastown.dog-2 (HQ work_dir) attributed to rig=hq" || bad "rig hq total wrong: $(py_get '["by_rig"]')"
[ "$(py_get '["by_rig"]["whatsapp_automation"]')" = "150000" ] && ok "wa-worker-x (whatsapp_automation work_dir) attributed to rig=whatsapp_automation" || bad "rig whatsapp_automation total wrong"
[ "$(py_get '["sessions_lookup_failed"]')" = "False" ] && ok "sessions_lookup_failed is False when the session lookup actually succeeded" || bad "sessions_lookup_failed wrong on a successful lookup: $(py_get '["sessions_lookup_failed"]')"

TOTAL=$(py_get '["total_rss_kb"]')
# every row in the ps fixture counts, including launchd (100) and tmux (500)
# themselves — total_rss_kb is the sum of the whole snapshot, not just the
# rows that ended up with a resolved owner label.
EXPECT_TOTAL=$((100+500+1012304+362576+150000+50000+20000+3000))
[ "$TOTAL" = "$EXPECT_TOTAL" ] && ok "total_rss_kb == sum of every sampled process (nothing double-counted or dropped from the total, even the unresolved one)" || bad "total_rss_kb=$TOTAL expected=$EXPECT_TOTAL"

echo ""
echo "── Scenario: rotation drops records older than the window, keeps recent ones ──"
OLD_TS=$((1787700000 - 40*86400))   # 40 days before NOW, older than default 30d
python3 -c "import json; print(json.dumps({'ts': $OLD_TS, 'by_owner': {'x': 1}, 'by_rig': {}, 'owner_kind': {}, 'total_rss_kb': 1, 'unresolved_kb': 0}))" > "$TMP/rotate.jsonl"
RECENT_TS=$((1787700000 - 1*86400))
python3 -c "import json; print(json.dumps({'ts': $RECENT_TS, 'by_owner': {'y': 1}, 'by_rig': {}, 'owner_kind': {}, 'total_rss_kb': 1, 'unresolved_kb': 0}))" >> "$TMP/rotate.jsonl"
# pad past the 2MB rotate-check threshold so rotation actually runs
python3 -c "
with open('$TMP/rotate.jsonl', 'a') as f:
    import json
    for i in range(20000):
        f.write(json.dumps({'ts': $RECENT_TS, 'by_owner': {'pad': i}, 'by_rig': {}, 'owner_kind': {}, 'total_rss_kb': 1, 'unresolved_kb': 0}) + '\n')
"
run_sampler "$TMP/rotate.jsonl" 1787700000 >/dev/null 2>"$TMP/stderr2"
grep -q "\"ts\": $OLD_TS" "$TMP/rotate.jsonl" && bad "40-day-old record survived rotation" || ok "40-day-old record dropped by rotation"
grep -q "\"ts\": $RECENT_TS" "$TMP/rotate.jsonl" && ok "1-day-old record survived rotation" || bad "recent record wrongly dropped by rotation"
tail -1 "$TMP/rotate.jsonl" | grep -q '"gastown.dog-2"' && ok "new sample still appended after rotation" || bad "new sample missing after rotation"

echo ""
echo "── Scenario: OUT path unwritable -> uncaught exception must notify (mirrors machine-utilization-sampler's own contract) ──"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/notify.log"
EOF
chmod +x "$TMP/notify"
: > "$TMP/blocker"   # a FILE, not a dir, forces os.makedirs() to raise
run_sampler "$TMP/blocker/sub/out.jsonl" >/dev/null 2>"$TMP/stderr3"
rc=$?
[ "$rc" -ne 0 ] && ok "exits nonzero on uncaught exception" || bad "expected nonzero exit, got $rc"
grep -qi 'ram-owner-sampler' "$TMP/notify.log" 2>/dev/null && ok "notify_fail fired on uncaught exception" || bad "uncaught exception did NOT notify"

echo ""
echo "── Scenario: ps itself failed (empty ps table) -> measurement gap, not a fake zero-RSS sample ──"
: > "$TMP/empty_ps.txt"   # simulates a `ps` call that returned nothing
: > "$TMP/notify2.log"
cat > "$TMP/notify2" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/notify2.log"
EOF
chmod +x "$TMP/notify2"
BEFORE_LINES=0
[ -f "$TMP/gap.jsonl" ] && BEFORE_LINES=$(wc -l < "$TMP/gap.jsonl")
RAM_OWNER_PS_FIXTURE="$TMP/empty_ps.txt" \
RAM_OWNER_SESSIONS_FIXTURE="$TMP/sessions.json" \
RAM_OWNER_OUT="$TMP/gap.jsonl" \
RAM_OWNER_NOW_EPOCH=1787700000 \
RAM_OWNER_NOTIFY="$TMP/notify2" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
  python3 "$SAMPLER" >/dev/null 2>"$TMP/stderr4"
rc=$?
[ "$rc" -eq 0 ] && ok "a measurement gap is not treated as a crash (exits 0, not a hard failure)" || bad "expected rc=0 for a graceful skip, got $rc"
[ ! -f "$TMP/gap.jsonl" ] && ok "no JSONL record written for a failed ps read (would have poisoned growth/median math with a false zero)" || bad "a fake zero-RSS record was written to history despite the ps read failing: $(cat "$TMP/gap.jsonl")"
grep -qi 'ps_snapshot_empty\|amostra pulada' "$TMP/notify2.log" 2>/dev/null && ok "the skipped sample still notifies (visible, not silent)" || bad "skipped sample was silent — no notify fired"

echo ""
echo "── Scenario: session lookup itself fails (bad fixture path) -> flagged explicitly, not indistinguishable from 'confirmed zero sessions' ──"
# Reuses the main ps.txt fixture (3 claude PIDs) but points the sessions
# fixture at a file that does not exist, so sessions_by_key() hits its
# open()-failure branch (ok=False) instead of parsing a real, empty {"sessions":
# []} — the exact "error vs. empty" distinction ga-yr8vm's gate review (attempt
# 1) found missing: a transient `gc session list` failure used to collapse to
# the same {} as a genuine zero-sessions reading, silently degrading every
# claude PID's attribution with no signal anywhere that the LOOKUP failed.
RAM_OWNER_PS_FIXTURE="$TMP/ps.txt" \
RAM_OWNER_SESSIONS_FIXTURE="$TMP/does-not-exist.json" \
RAM_OWNER_OUT="$TMP/sessfail.jsonl" \
RAM_OWNER_NOW_EPOCH=1787700000 \
RAM_OWNER_NOTIFY="$TMP/notify" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
  python3 "$SAMPLER" >/dev/null 2>"$TMP/stderr5"
rc=$?
[ "$rc" -eq 0 ] && ok "a failed session lookup alone does not crash the sampler" || bad "expected rc=0, got $rc"
SESSFAIL_REC=$(tail -1 "$TMP/sessfail.jsonl" 2>/dev/null)
sessfail_get() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d$1)" "$SESSFAIL_REC" 2>/dev/null; }
[ "$(sessfail_get '["sessions_lookup_failed"]')" = "True" ] && ok "sessions_lookup_failed is explicitly True when the lookup itself failed" || bad "sessions_lookup_failed not flagged: $(sessfail_get '["sessions_lookup_failed"]')"
EXPECT_UNMATCHED=$((362576+150000+50000))
[ "$(sessfail_get '["by_owner"]["claude (no session-id match)"]')" = "$EXPECT_UNMATCHED" ] && ok "all 3 claude PIDs still counted (RSS not lost), merged into the fallback bucket since no session data was available to disambiguate them" || bad "unmatched-claude bucket wrong during a failed lookup: $(sessfail_get '["by_owner"]')"

echo ""
echo "── Scenario: claude invoked via a full path whose ps comm= column would truncate away 'claude' -- still attributed by session, not merged into a generic bucket ──"
# macOS ps truncates its comm= column to a fixed ~16 chars regardless of how
# many other columns are requested (confirmed live against this exact
# machine, ga-yr8vm gate review attempt 2) -- a real running session invoked
# via /Users/athos/.local/bin/claude truncated to "/Users/athos/.lo", whose
# basename is ".lo", not "claude". The comm field below is deliberately wrong
# ("whatever-wrong-value") to prove owner_of() no longer depends on ps's
# comm= column at all -- only on args_head, which is not truncated.
cat > "$TMP/fullpath_ps.txt" <<'EOF'
500 50000 300000 whatever-wrong-value /Users/athos/.local/bin/claude --settings {} --model sonnet --session-id 22222222-2222-2222-2222-222222222222 --effort max
EOF
python3 -c "
import json
print(json.dumps({'sessions': [
  {'session_key': '22222222-2222-2222-2222-222222222222', 'name': 'full-path-session', 'template': 'x', 'work_dir': '/x'},
]}))
" > "$TMP/fullpath_sessions.json"
RAM_OWNER_PS_FIXTURE="$TMP/fullpath_ps.txt" \
RAM_OWNER_SESSIONS_FIXTURE="$TMP/fullpath_sessions.json" \
RAM_OWNER_OUT="$TMP/fullpath.jsonl" \
RAM_OWNER_NOW_EPOCH=1787700000 \
RAM_OWNER_NOTIFY="$TMP/notify" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
  python3 "$SAMPLER" >/dev/null 2>"$TMP/stderr6"
FULLPATH_REC=$(tail -1 "$TMP/fullpath.jsonl" 2>/dev/null)
fullpath_get() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d$1)" "$FULLPATH_REC" 2>/dev/null; }
[ "$(fullpath_get '["by_owner"]["full-path-session"]')" = "300000" ] && ok "full-path claude session attributed by its real session name despite a wrong/truncated-looking comm field" || bad "full-path claude session not attributed: $(fullpath_get '["by_owner"]')"
[ "$(fullpath_get '["owner_kind"]["full-path-session"]')" = "session" ] && ok "kind is 'session', not merged into a generic daemon bucket" || bad "kind wrong: $(fullpath_get '["owner_kind"]')"

echo ""
echo "── Scenario: macOS app-bundle path with an embedded space in its final component -- label preserves the full name, not the first word ──"
# a.split()[0] on ".../Google Chrome.app/Contents/MacOS/Google Chrome
# --type=renderer ..." truncates at the space inside "Google Chrome",
# producing the generic label "Google" -- which every OTHER app whose path
# happens to share that truncated prefix then also collapses into. Proven
# live: 34 real Chrome-family pids (~900MB) merged into one "Google" bucket
# before this fix (ga-yr8vm gate review attempt 2).
cat > "$TMP/chrome_ps.txt" <<'EOF'
501 1 400000 Google /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer --field-trial-handle=abc
EOF
RAM_OWNER_PS_FIXTURE="$TMP/chrome_ps.txt" \
RAM_OWNER_SESSIONS_FIXTURE="$TMP/does-not-exist.json" \
RAM_OWNER_OUT="$TMP/chrome.jsonl" \
RAM_OWNER_NOW_EPOCH=1787700000 \
RAM_OWNER_NOTIFY="$TMP/notify" \
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
  python3 "$SAMPLER" >/dev/null 2>"$TMP/stderr7"
CHROME_REC=$(tail -1 "$TMP/chrome.jsonl" 2>/dev/null)
chrome_get() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d$1)" "$CHROME_REC" 2>/dev/null; }
[ "$(chrome_get '["by_owner"]["Google Chrome"]')" = "400000" ] && ok "app-bundle path labeled by its full name 'Google Chrome', not truncated to 'Google'" || bad "chrome label wrong: $(chrome_get '["by_owner"]')"

echo ""
echo "ram-owner-sampler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
