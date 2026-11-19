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
  RAM_OWNER_TOP_FIXTURE="${TOP_FIX-$TMP/top.txt}" \
  RAM_OWNER_OUT="$1" \
  RAM_OWNER_NOW_EPOCH="${2:-1787700000}" \
  RAM_OWNER_NOTIFY="$TMP/notify" \
  PATH="${PATH_FIRST:+$PATH_FIRST:}/usr/bin:/bin:/usr/sbin:/sbin:$PATH" \
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
tail -1 "$TMP/rotate.jsonl" | grep '"gastown.dog-2"' >/dev/null && ok "new sample still appended after rotation" || bad "new sample missing after rotation"

echo ""
echo "── Scenario: byte cap (ga-mswg06s) — all records recent, file over 16MB: oldest whole records go, newest stay, no half line ──"
NOW_T=1787700000
python3 -I - "$TMP/bytecap.jsonl" "$NOW_T" <<'PYEOF'
import json, sys
out, now = sys.argv[1], int(sys.argv[2])
pad = "x" * 1500
with open(out, "w") as f:
    for i in range(11500):  # ~1.6KB each: ~18MB, every record from the last 2 days (the age rule drops none)
        f.write(json.dumps({"ts": now - 172800 + i * 10, "by_owner": {"pad": i}, "by_rig": {}, "owner_kind": {}, "total_rss_kb": 1, "unresolved_kb": 0, "pad": pad}) + "\n")
PYEOF
BEFORE_B=$(wc -c < "$TMP/bytecap.jsonl")
[ "$BEFORE_B" -gt $((16*1024*1024)) ] || bad "fixture bytecap.jsonl is only $BEFORE_B bytes, under the 16MB default cap: the cases below prove nothing"
run_sampler "$TMP/bytecap.jsonl" "$NOW_T" >/dev/null 2>"$TMP/stderr_bc"
AFTER_B=$(wc -c < "$TMP/bytecap.jsonl")
[ "$AFTER_B" -le $((8*1024*1024 + 4096)) ] && [ "$AFTER_B" -gt $((7*1024*1024)) ] && ok "file over the cap comes back to ~8MB (was $BEFORE_B, now $AFTER_B)" || bad "after the cut the file has $AFTER_B bytes (was $BEFORE_B), expected ~8MB"
python3 -I - "$TMP/bytecap.jsonl" "$NOW_T" <<'PYEOF' && ok "every line after the cut is a whole JSON record, the oldest are gone, the newest kept, the new sample last" || bad "byte-cap cut left a half line, lost the newest record or kept the oldest"
import json, sys
lines = open(sys.argv[1]).read().split("\n")
assert lines[-1] == "", "ends with a newline"
recs = [json.loads(x) for x in lines[:-1]]
now = int(sys.argv[2])
by = [r["by_owner"].get("pad") for r in recs]
assert by[0] is not None and by[0] > 1000, f"oldest kept = {by[0]}, the oldest records should be gone"
assert 11499 in by, "newest fixture record lost"
assert by[-1] is None and "gastown.dog-2" in recs[-1]["by_owner"], "the sample of this cycle is the last line"
pads = [b for b in by if b is not None]
assert pads == sorted(pads) and pads == list(range(pads[0], pads[0] + len(pads))), "kept records are one contiguous run, in order"
PYEOF
[ ! -s "$TMP/stderr_bc" ] && [ ! -e "$TMP/bytecap.jsonl.rotate.tmp" ] && ok "byte-cap cut is silent and leaves no .rotate.tmp" || bad "byte-cap cut wrote to stderr or left a tmp: $(head -c 200 "$TMP/stderr_bc")"
# under the cap (and over the 2MB check threshold) nothing but the age rule applies: all records stay
python3 -I - "$TMP/undercap.jsonl" "$NOW_T" <<'PYEOF'
import json, sys
out, now = sys.argv[1], int(sys.argv[2])
with open(out, "w") as f:
    for i in range(2500):  # ~4MB
        f.write(json.dumps({"ts": now - 3600 + i, "by_owner": {"pad": i}, "by_rig": {}, "owner_kind": {}, "total_rss_kb": 1, "unresolved_kb": 0, "pad": "y" * 1500}) + "\n")
PYEOF
run_sampler "$TMP/undercap.jsonl" "$NOW_T" >/dev/null 2>&1
[ "$(wc -l < "$TMP/undercap.jsonl" | tr -d ' ')" = 2501 ] && ok "file between 2MB and the cap loses nothing (2500 records + the new sample)" || bad "under-cap file lost records: $(wc -l < "$TMP/undercap.jsonl") lines"
# the knobs: a small RAM_OWNER_ROTATE_MAX_BYTES / KEEP_BYTES cut a small file, and the newest record survives even when it alone exceeds KEEP
python3 -I - "$TMP/knob.jsonl" "$NOW_T" <<'PYEOF'
import json, sys
out, now = sys.argv[1], int(sys.argv[2])
with open(out, "w") as f:
    for i in range(400):
        f.write(json.dumps({"ts": now - 3600 + i, "by_owner": {"pad": i}, "by_rig": {}, "owner_kind": {}, "total_rss_kb": 1, "unresolved_kb": 0, "pad": "z" * 1000}) + "\n")
PYEOF
RAM_OWNER_ROTATE_MAX_BYTES=300000 RAM_OWNER_ROTATE_KEEP_BYTES=100000 run_sampler "$TMP/knob.jsonl" "$NOW_T" >/dev/null 2>&1
KB=$(wc -c < "$TMP/knob.jsonl")
[ "$KB" -le 101500 ] && [ "$KB" -gt 90000 ] && ok "RAM_OWNER_ROTATE_MAX_BYTES / KEEP_BYTES are honored (400KB file → ~100KB, now $KB)" || bad "knobs ignored: knob.jsonl has $KB bytes"
NEWEST_BEFORE=$(tail -1 "$TMP/knob.jsonl")
RAM_OWNER_ROTATE_MAX_BYTES=1000 RAM_OWNER_ROTATE_KEEP_BYTES=10 run_sampler "$TMP/knob.jsonl" "$NOW_T" >/dev/null 2>&1
[ "$(head -1 "$TMP/knob.jsonl")" = "$NEWEST_BEFORE" ] && [ "$(wc -l < "$TMP/knob.jsonl" | tr -d ' ')" = 2 ] && ok "a KEEP smaller than one record still keeps the newest record (never empties the file)" || bad "KEEP smaller than a record emptied or kept too much: $(wc -l < "$TMP/knob.jsonl") lines"
# unreadable size (stat fails for a reason other than "missing") → warn, do NOT cut, never treated as 0
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$TMP/noperm"; cp "$TMP/knob.jsonl" "$TMP/noperm/s.jsonl"; chmod 000 "$TMP/noperm"
  SAMPLER_PATH="$SAMPLER" RAM_OWNER_ROTATE_MAX_BYTES=1 RAM_OWNER_ROTATE_CHECK_MIN_BYTES=1 python3 -I - "$TMP/noperm/s.jsonl" "$NOW_T" 2>"$TMP/stderr_np" <<'PYEOF'
import importlib.util, os, sys
path, now = sys.argv[1], int(sys.argv[2])
spec = importlib.util.spec_from_file_location("sampler", os.environ["SAMPLER_PATH"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.rotate_if_needed(path, 30, now)
PYEOF
  chmod 755 "$TMP/noperm"
  grep -q "aviso: rotação falhou" "$TMP/stderr_np" && [ "$(wc -l < "$TMP/noperm/s.jsonl" | tr -d ' ')" = "$(wc -l < "$TMP/knob.jsonl" | tr -d ' ')" ] && [ ! -e "$TMP/noperm/s.jsonl.rotate.tmp" ] && ok "size unreadable (EACCES) → warns, file untouched, no tmp (not read as 0)" || bad "unreadable-size case: stderr='$(head -c 200 "$TMP/stderr_np")'"
fi
# no file yet → silent no-op (the first sample creates it)
python3 -I - "$SAMPLER" "$NOW_T" 2>"$TMP/stderr_nf" <<'PYEOF'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("sampler", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.rotate_if_needed("/nonexistent-dir-ga-mswg06s/none.jsonl", 30, int(sys.argv[2]))
PYEOF
[ ! -s "$TMP/stderr_nf" ] && ok "missing file → silent no-op" || bad "missing file warned: $(head -c 200 "$TMP/stderr_nf")"

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
echo "── Scenario: footprint per owner from top MEM (ga-1p1i5jr.14) — MEM already includes the compressed memory: CMPRS sits beside it, never added ──"
cat > "$TMP/top.txt" <<'EOF'
Processes: 521 total, 3 running, 518 sleeping, 2530 threads
2026/11/19 13:05:11
Load Avg: 3.12, 3.45, 3.60
CPU usage: 6.25% user, 9.37% sys, 84.37% idle
PhysMem: 15G used (2204M wired, 6347M compressor), 296M unused.
VM: 232T vsize, 4125M framework vsize, 0(0) swapins, 0(0) swapouts.
PID file: /var/run/top.pid

PID    MEM    CMPRS
100    2433M  1433M
200    345M+  210M-
201    1G     0B
202    12288B 0B
300    20M    4M
600    3000K  0B
1      100K   0B
50000  500K   0B
999    0.5M   0B
abc    1M     1M
77     12X    1M
88     1M     1M     1M
EOF
run_sampler "$TMP/top.jsonl" >/dev/null 2>"$TMP/stderr_top"
cat > "$TMP/check-top.py" <<'EOF'
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
tm = {n: (m, c) for n, m, c in r["top_mem"]}
assert r["top_mem"][0] == ["dolt", 2491392, 1467392], r["top_mem"][0]          # 2433M, not 2433M + 1433M
assert tm["gastown.dog-2"] == (353280, 215040) and tm["wa-worker-x"] == (1048576, 0) and tm["claude (no session-id match)"] == (12, 0), tm
assert r["top_mem_unmatched_kb"] == 3512 and r["top_mem_bad_rows"] == 3 and r["top_mem_other_kb"] == 0, r   # pid 600 (no owner) + pid 999 (not in ps, a decimal size: 0.5M); `abc`, `12X` and a row with a 4th field
assert sum(m for _, m, _ in r["top_mem"]) + r["top_mem_other_kb"] + r["top_mem_unmatched_kb"] == 3917852   # every readable row is somewhere
assert r["by_owner"]["dolt"] == 1012304                                          # RSS stays as it was
EOF
python3 -I "$TMP/check-top.py" "$TMP/top.jsonl" && ok "top_mem: sorted by MEM, +/- and K/M/G read, CMPRS beside MEM (never added), unmatched and bad rows COUNTED, nothing lost" || bad "top_mem record wrong: $(tail -1 "$TMP/top.jsonl" | cut -c1-300)"
cat > "$TMP/check-cap.py" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import ram_owner_lib as lib
assert lib.MEM_TOP_N == 40                        # the record-size contract (a record is ~26KB already, ga-mswg06s)
lib.MEM_TOP_N = 2
r = lib.sample(now=1, ps_fixture=sys.argv[2] + "/ps.txt", sessions_fixture=sys.argv[2] + "/sessions.json", top_fixture=sys.argv[2] + "/top.txt", compute_rig=False)
assert [n for n, _, _ in r["top_mem"]] == ["dolt", "wa-worker-x"], r["top_mem"]
assert sum(m for _, m, _ in r["top_mem"]) + r["top_mem_other_kb"] + r["top_mem_unmatched_kb"] == 3917852
EOF
python3 -I "$TMP/check-cap.py" "$SELF_DIR" "$TMP" && ok "only the MEM_TOP_N biggest owners are listed and the rest is COUNTED in top_mem_other_kb" || bad "MEM_TOP_N cap lost memory or listed too many"
echo "── Scenario: top unreadable -> top_mem is null, never [] and never 0; the RSS sample is still written ──"
printf 'Processes: 1 total\nsome banner\n' > "$TMP/top-no-header.txt"; printf 'PID    MEM    CMPRS \n' > "$TMP/top-no-rows.txt"
cat > "$TMP/check-null.py" <<'EOF'
import json, sys
r = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert r["top_mem"] is None and r["top_mem_unmatched_kb"] is None and r["top_mem_bad_rows"] is None and r["top_mem_other_kb"] is None and r["by_owner"]["dolt"] == 1012304
EOF
for how in no-such-top.txt top-no-header.txt top-no-rows.txt; do
  TOP_FIX="$TMP/$how" run_sampler "$TMP/topfail.jsonl" >/dev/null 2>&1
  python3 -I "$TMP/check-null.py" "$TMP/topfail.jsonl" && ok "unreadable top ($how): top_mem and its counters null, by_owner intact" || bad "unreadable top ($how) did not yield null fields: $(tail -1 "$TMP/topfail.jsonl" | cut -c1-200)"
done
echo "── Scenario: the real command line is top -l 1 -stats pid,mem,cmprs (a fake top on PATH records its argv; one that fails gives null) ──"
mkdir -p "$TMP/fakebin"
printf '%s\n' '#!/bin/sh' 'echo "$*" > "$TOPARGV"' 'cat "$TOPOUT"' > "$TMP/fakebin/top"; chmod +x "$TMP/fakebin/top"
TOP_FIX= TOPARGV="$TMP/top.argv" TOPOUT="$TMP/top.txt" PATH_FIRST="$TMP/fakebin" run_sampler "$TMP/topcmd.jsonl" >/dev/null 2>&1
[ "$(cat "$TMP/top.argv" 2>/dev/null)" = "-l 1 -stats pid,mem,cmprs" ] && ok "top is called as -l 1 -stats pid,mem,cmprs" || bad "top argv: '$(cat "$TMP/top.argv" 2>/dev/null)'"
tail -1 "$TMP/topcmd.jsonl" | grep -q '"top_mem": \[\["dolt", 2491392' && ok "the live path parses what top prints" || bad "live-path record lacks top_mem"
mkdir -p "$TMP/failbin"; printf '%s\n' '#!/bin/sh' 'cat "$TOPOUT"' 'exit 1' > "$TMP/failbin/top"; chmod +x "$TMP/failbin/top"
TOP_FIX= TOPOUT="$TMP/top.txt" PATH_FIRST="$TMP/failbin" run_sampler "$TMP/topbad.jsonl" >/dev/null 2>&1
python3 -I "$TMP/check-null.py" "$TMP/topbad.jsonl" && ok "a top that prints a good table and exits 1 is unreadable: null, not the table" || bad "failing top still produced top_mem"

echo ""
echo "ram-owner-sampler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
