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
jget "['top3_opportunities']" | grep "active-sess" >/dev/null && bad "active-sess leaked into top3 despite being active <2h" || ok "active-sess correctly excluded from top3 (not idle long enough)"

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
echo "$TOP_FAIL_OUT" | grep -i "falha na leitura" >/dev/null && ok "--top on a failed ps read prints the explicit failure message" || bad "--top did not degrade explicitly on empty ps: $TOP_FAIL_OUT"

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
echo "$TOP_OK_OUT" | grep "gastown.dog-2=354MB" >/dev/null && ok "--top resolves a real claude PID to its session name via --session-id join" || bad "--top did not resolve real owners: $TOP_OK_OUT"
echo "$TOP_OK_OUT" | grep -i "AVISO" >/dev/null && bad "--top wrongly showed the session-lookup-failed AVISO despite a successful lookup: $TOP_OK_OUT" || ok "--top shows no AVISO when the session lookup actually succeeded"

echo ""
echo "── Scenario: no history file yet -> graceful message, not a crash ──"
NO_DATA=$(run_report --in "$TMP/does-not-exist.jsonl" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "missing JSONL exits 0 with an explanatory message" || bad "missing JSONL should not be a hard failure, got rc=$rc"
echo "$NO_DATA" | grep -i "sem" >/dev/null && ok "message says explicitly there's no data yet (not silently empty output)" || bad "no-data message missing/unclear: $NO_DATA"

echo ""
echo "── Scenario: the module's own functions, edge by edge (ga-hq1qc5y, hq-mutants lastro) ──"
# EQUIVALENT, documented (63dc55df69, the sys.path.insert position, is NOT one: it dies to the namesake case at the end, ga-u7idiy2): c7bbe33248 (`base <= 0` -> `<` after `not base`: 0 is caught by `not base`,
# a negative base by both), d0754f3e66 (`d and d > 0` -> `>=`: 0 is falsy before the comparison), 27cf8f8597 (sys.argv[1:] -> [0:]: the script path is not a flag).
# One in-process python run: the pure functions are called with the numbers that sit ON each edge (the idle limit, the median ratio, the window), and cmd_top / main with a stub for the live sample.
# EQUIVALENT c7bbe33248: `base <= 0` -> `<` after `not base`: 0 is caught by `not base`, a negative base by both
# EQUIVALENT d0754f3e66: `d and d > 0` -> `>=`: 0 is falsy before the comparison
# EQUIVALENT 27cf8f8597: `sys.argv[1:]` -> `[0:]`: the script path is not a flag
PYT='
import contextlib, datetime, importlib.util, io, json, os, sys, tempfile
for k in ("RAM_OWNER_IDLE_SESSION_SEC", "RAM_OWNER_ABOVE_MEDIAN_RATIO", "RAM_OWNER_MIN_SAMPLES_FOR_BASELINE", "RAM_OWNER_NOW_EPOCH", "RAM_OWNER_OUT"):
    os.environ.pop(k, None)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec = importlib.util.spec_from_file_location("rop", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = []
def eq(name, got, want):
    if got != want:
        bad.append("%s: got %r, wanted %r" % (name, got, want))
def put(path, text):
    with open(path, "w") as f:
        f.write(text)
def out_of(fn, *a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(*a)
    return rc, buf.getvalue()
eq("knob defaults", (m.IDLE_SESSION_SEC, m.ABOVE_MEDIAN_RATIO, m.MIN_SAMPLES_FOR_BASELINE), (7200, 1.5, 3))
eq("window 2d / 3h / junk", (m.parse_window("2d"), m.parse_window("3h"), m.parse_window("x")), (172800.0, 10800.0, 604800))
eq("median odd / even / empty", (m.median([5, 1, 3]), m.median([4, 1, 3, 2]), m.median([])), (3, 2.5, None))
p = os.path.join(tempfile.mkdtemp(), "h.jsonl")
put(p, "\n".join(json.dumps(r) for r in [{"ts": 10, "a": 1}, {"ts": 5, "a": 2}, {"a": 3}, {"ts": 7, "a": 4}, {"ts": 0.5, "a": 5}]) + "\nnot json\n\n")
eq("load: sorted by ts, a row with no ts counts as 0", [r["a"] for r in m.load(p)], [3, 5, 2, 4, 1])
eq("load: a row AT since_ts is in, one with no ts is out", ([r["a"] for r in m.load(p, since_ts=7)], [r["a"] for r in m.load(p, since_ts=1)]), ([4, 1], [2, 4, 1]))
r0, r1, r2 = {"by_owner": {"a": 1}}, {"by_owner": {"a": 10, "b": 5}}, {"by_owner": {"a": 30, "c": 7}}
eq("growth: two rows needed, the last two used, a new owner counts whole", (m.growth_since_last([]), m.growth_since_last([r1]), m.growth_since_last([r1, r2]), m.growth_since_last([r0, r1, r2])), ({}, {}, {"a": 20, "c": 7}, {"a": 20, "c": 7}))
rows4 = [{"by_owner": {"a": v}} for v in (10, 20, 40, 999)]
eq("medians: the latest row is left out; included on request", (m.historical_medians(rows4), m.historical_medians(rows4, exclude_latest=False)), ({"a": 20}, {"a": 30.0}))
m.MIN_SAMPLES_FOR_BASELINE = 1
eq("medians: a single row is its own history", m.historical_medians([{"by_owner": {"a": 8}}]), {"a": 8})
m.MIN_SAMPLES_FOR_BASELINE = 3
now = 1000000000
def iso(ago):
    return datetime.datetime.fromtimestamp(now - ago, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
sess = {"k1": {"name": "s-idle", "last_active": iso(7200)}, "k2": {"name": "s-fresh", "last_active": iso(7199)}}
kinds = {"s-idle": "session", "s-fresh": "session", "d-edge": "daemon", "d-under": "daemon", "d-one": "daemon", "d-none": "daemon", "d-neg": "daemon"}
latest = {"by_owner": {"s-idle": 100, "s-fresh": 200, "d-edge": 3, "d-under": 2, "d-one": 2, "d-none": 5, "d-neg": 5}, "owner_kind": kinds}
c = {x["owner"]: x for x in m.top3_opportunities(latest, {"d-edge": 2, "d-under": 2, "d-one": 1, "d-neg": -5}, sess, now)}
eq("top3: idle AT the limit, ratio AT 1.5, a base of 1 count; fresh, under, no baseline and negative do not", sorted(c), ["d-edge", "d-one", "s-idle"])
eq("top3: gains and the idle text", (c["d-edge"]["est_gain_kb"], c["d-one"]["est_gain_kb"], c["s-idle"]["detail"]), (1, 1, "ociosa h\xe1 2.0h"))
many = {"by_owner": {"s%d" % i: 50 - 10 * i for i in range(5)}, "owner_kind": {"s%d" % i: "session" for i in range(5)}}
eq("top3: the best three by gain", [x["owner"] for x in m.top3_opportunities(many, {}, {"k%d" % i: {"name": "s%d" % i, "last_active": iso(9000)} for i in range(5)}, now)], ["s0", "s1", "s2"])
m.IDLE_SESSION_SEC = 0
eq("top3: the idle hours divide by 3600", m.top3_opportunities({"by_owner": {"s": 1}, "owner_kind": {"s": "session"}}, {}, {"k": {"name": "s", "last_active": iso(1000000)}}, now)[0]["detail"], "ociosa h\xe1 277.8h")
m.IDLE_SESSION_SEC = 7200
m.ABOVE_MEDIAN_RATIO = 0.5
eq("top3: a daemon under its median (ratio knob below 1) gains 0, not 1", m.top3_opportunities({"by_owner": {"d": 1}, "owner_kind": {"d": "daemon"}}, {"d": 2}, {}, now)[0]["est_gain_kb"], 0)
m.ABOVE_MEDIAN_RATIO = 1.5
lat = {"ts": 5, "total_rss_kb": 2048, "unresolved_kb": 0, "swap_used_mb": 1, "swap_total_mb": 2, "free_pct": 3, "by_owner": {"o%02d" % i: 1024 * (20 - i) for i in range(17)}, "by_rig": {"r1": 2048, "r2": 1024}}
t = m.render_table(lat, {"o00": 2048, "o01": 0, "o02": -1024, "o03": 1}, [], {})
owners = [ln for ln in t.splitlines() if ln.startswith("o")]
eq("table: 15 owners, with their delta (plus only when it grew; none; no history)", (len(owners), "+2MB" in owners[0], owners[1].rstrip().endswith(" 0MB") and "+" not in owners[1], "-1MB" in owners[2] and "+" not in owners[2], "+0MB" in owners[3], "(sem historico)" in owners[4]), (15, True, True, True, True, True))
eq("table: no AVISO by default, one when the session lookup failed; the empty top3 line only when it is empty", ("AVISO" in t, "AVISO" in m.render_table(lat, {}, [], {}, sess_ok=False), "(nenhuma" in t, "(nenhuma" in m.render_table(lat, {}, [{"owner": "s0", "est_gain_kb": 5, "detail": "d"}], {})), (False, True, True, False))
seen = {}
def fake_sample(**k):
    seen.update(k)
    return {"by_owner": {"a": 4096, "b": 2048, "c": 1024, "d": 512}}
m.lib.sample = fake_sample
rc, o = out_of(m.cmd_top, 3)
rc2, o2 = out_of(m.main, ["--top"])
rc3, o3 = out_of(m.main, ["--top", "2"])
eq("--top: the live sample asks for no rig scan; an N, a default of 3, a record with no unresolved key, exit 0", (seen.get("compute_rig"), o2.strip(), o3.strip(), rc2, rc3), (False, "top RSS: a=4MB, b=2MB, c=1MB", "top RSS: a=4MB, b=2MB", 0, 0))
m.lib.sessions_by_key = lambda fx: ({}, True)
m.NOW = now
hp = os.path.join(tempfile.mkdtemp(), "w.jsonl")
put(hp, "\n".join(json.dumps({"ts": now - ago, "by_owner": {"a": kb}, "owner_kind": {"a": "daemon"}}) for ago, kb in ((7 * 86400 + 1, 1000000), (7 * 86400, 10), (6 * 86400, 20), (3600, 30), (0, 40))) + "\n")
rc, o = out_of(m.main, ["--in", hp, "--json"])
eq("main: the default window is 7 days (a row AT the edge in, one second older out); JSON indented by 2; the lookup flag", (json.loads(o)["historical_medians_kb"], o.startswith("{\n  \"latest\""), json.loads(o)["sessions_lookup_failed"], rc), ({"a": 20}, True, False, 0))
rc, o = out_of(m.main, ["--in", hp, "--json", "--window", "1d"])
eq("main: --window 1d keeps only the last day", (json.loads(o)["historical_medians_kb"], json.loads(o)["growth_since_last_kb"]), ({}, {"a": 10}))
m.lib.sessions_by_key = lambda fx: ({}, False)
eq("main: a failed session lookup is flagged in the JSON", json.loads(out_of(m.main, ["--in", hp, "--json"])[1])["sessions_lookup_failed"], True)
for line in bad:
    print("FAIL " + line)
print("DONE %d" % len(bad))
'
PYOUT="$(python3 -c "$PYT" "$REPORT" 2>&1)"
case "$PYOUT" in *"DONE 0") ok "pure functions and main: every edge answered as the contract says" ;; *) bad "module edges: $PYOUT" ;; esac
echo ""
echo "── Scenario: the sibling module comes from the script's own directory, never from a namesake in the cwd (ga-u7idiy2, hq-mutants lastro) ──"
# `sys.path.insert(0, d)` puts the script's directory in front of everything; `insert(1, d)` puts it AFTER sys.path[0], which for a `python -c` run WITHOUT -I is the cwd: a ram_owner_lib.py there would win
# (63dc55df69, declared equivalent until now). The PYT run above inserts the directory itself before it loads the module, so it could never see this. The control runs the same command with no namesake.
mkdir -p "$TMP/voc/dir" "$TMP/voc/cwd" "$TMP/voc/vazio"; cp "$REPORT" "$SELF_DIR/ram_owner_lib.py" "$TMP/voc/dir/"; printf 'WHO = "namesake in the cwd"\n' > "$TMP/voc/cwd/ram_owner_lib.py"
PYVOC='import importlib.util, sys
sys.dont_write_bytecode = True
sp = importlib.util.spec_from_file_location("rop_voc", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(getattr(m.lib, "WHO", "canonical"))'
VOC0="$(cd "$TMP/voc/vazio" && env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 python3 -B -c "$PYVOC" "$TMP/voc/dir/ram-owner-report.py" 2>&1)"
VOC1="$(cd "$TMP/voc/cwd" && env -i PATH="$PATH" PYTHONDONTWRITEBYTECODE=1 python3 -B -c "$PYVOC" "$TMP/voc/dir/ram-owner-report.py" 2>&1)"
[ "$VOC0" = "canonical" ] && ok "control: with no namesake in the cwd the python -c run finds the ram_owner_lib next to the script" || bad "control: got [$VOC0]"
[ "$VOC1" = "canonical" ] && ok "a ram_owner_lib.py in the cwd of a python -c run (no -I) does not shadow the one next to the script" || bad "the namesake in the cwd won: got [$VOC1]"
echo ""
echo "ram-owner-report selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
