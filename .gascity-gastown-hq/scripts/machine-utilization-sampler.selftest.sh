#!/usr/bin/env bash
# Selftest for machine-utilization-sampler.py — proves an unhandled exception notifies (ga-4zpf).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/machine-utilization-sampler.py"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/notify"

echo "── Scenario: OUT path unwritable → uncaught exception must notify ──"
: > "$TMP/blocker"    # a FILE, not a dir — forces os.makedirs() to raise
UTIL_OUT="$TMP/blocker/sub/out.jsonl" UTIL_NOTIFY="$TMP/notify" PATH="/usr/bin:/bin" \
  python3 "$J" >/dev/null 2>"$TMP/stderr"
rc=$?
[ "$rc" -ne 0 ] && ok "exits nonzero on uncaught exception (crash visible)" || bad "expected nonzero exit on write failure, got $rc"
grep -qi 'machine-utilization-sampler' "$NOTIFY_LOG" 2>/dev/null && ok "notify_fail fired on uncaught exception (ga-4zpf)" || bad "uncaught exception did NOT notify — silent crash (ga-4zpf regression)"
grep -qi 'Traceback' "$TMP/stderr" 2>/dev/null && ok "traceback still visible on stderr (not swallowed)" || bad "traceback missing from stderr — exception was swallowed instead of re-raised"

echo ""
echo "── ga-30xi3: sh() must not collapse a text-decode failure into the same '' a clean"
echo "   empty read produces (truncated-multibyte session title in 'gc session list') ──"
# gc session list's table form truncates titles to fit column width; a cut mid multi-byte
# UTF-8 char makes stdout invalid UTF-8. text=True decodes INSIDE subprocess.run, so a
# strict (default) decode raises UnicodeDecodeError there, caught by sh()'s existing
# `except Exception: return ""` — collapsing "one line had a bad byte" into the SAME ""
# a clean empty read produces. active_sessions() then reports EVERY template as
# zero-active (tmpl_active stays {}), not just the one session with the corrupted title.
PY30XI3_OUT="$(python3 - "$J" <<'PY'
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("mus", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["mus"]
spec.loader.exec_module(m)

def _fake_run(args, **kwargs):
    if kwargs.get("errors") != "replace":
        raise UnicodeDecodeError("utf-8", b"\xe2\x80", 0, 2, "invalid continuation byte")
    return types.SimpleNamespace(
        returncode=0,
        stdout=("ID  TEMPLATE       STATE   AGE\n"
                "s1  gate-reviewer  active  wa-mgnkf: Broken capture �\n"
                "s2  gastown.dog    active  5m\n"))

m.subprocess.run = _fake_run
active = m.active_sessions()
want_ok = active.get("gate-reviewer", 0) == 1 and active.get("gastown.dog", 0) == 1
print("RESULT_OK" if want_ok else ("RESULT_BAD got=%r" % (active,)))
PY
)"
if echo "$PY30XI3_OUT" | grep "^RESULT_OK" >/dev/null; then
  ok "ga-30xi3: active_sessions() still counts BOTH templates despite one corrupted line"
else
  bad "ga-30xi3: active_sessions() lost session counts to a decode failure ($PY30XI3_OUT)"
fi

echo ""
echo "── Scenario: the sampler's reading, world by world (ga-hq1qc5y, hq-mutants lastro) ──"
# One in-process python run. Every external read (sh, bd_list, bd_store_rows, ps_lines, dolt_ok) is a stub, so each case is a small world whose record is known by hand: every flag of the
# record is read on both sides of its edge (a bead exactly BUILD_FRESH_SEC old, a marker exactly GATE_STALL_MIN old, the 3-column row of `gc session list`).
# EQUIVALENT, documented: 304e0ebd20 (`a > gate_oldest_queued_min` -> `>=`: at equality it assigns the same number).
# EQUIVALENT 304e0ebd20: `a > gate_oldest_queued_min` -> `>=`: at equality it assigns the same number
PYT='
import contextlib, datetime, importlib.util, io, json, os, sys, tempfile, types
for k in ("UTIL_OUT", "UTIL_NOTIFY", "UTIL_BUILD_FRESH_SEC", "UTIL_GATE_STALL_MIN"):
    os.environ.pop(k, None)
os.environ["UTIL_SAMPLE_EPOCH"] = "1000000000"
spec = importlib.util.spec_from_file_location("mus", sys.argv[1]); m = importlib.util.module_from_spec(spec); sys.argv = ["mus"]; spec.loader.exec_module(m)
E = m.SAMPLE_EPOCH
bad = []
def eq(name, got, want):
    if got != want:
        bad.append("%s: got %r, wanted %r" % (name, got, want))
def iso(ago):
    return datetime.datetime.fromtimestamp(E - ago, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
calls = []
def fake_sh(out):
    def f(args, timeout=20):
        calls.append((args, timeout))
        return out
    return f
real_run = m.subprocess.run
seen = []
m.subprocess.run = lambda args, **kw: (seen.append((args, kw)), types.SimpleNamespace(stdout="out"))[1]
eq("sh: text, bad bytes replaced, 20 s", (m.sh(["x"]), seen[-1][1]), ("out", {"capture_output": True, "text": True, "errors": "replace", "timeout": 20}))
m.subprocess.run = real_run
eq("knob defaults", (m.BUILD_FRESH_SEC, m.GATE_STALL_MIN), (7200, 165))
m.sh = fake_sh("[{\"id\": \"a\"}]")
eq("bd_list: open, no infra, one -l per label, the list", (m.bd_list("S", "x", "y"), calls[-1][0]), ([{"id": "a"}], ["bash", m.BD_LIST_CACHED, "-C", "S", "list", "--status", "open", "--json", "-l", "x", "-l", "y"]))
m.bd_list("S", include_infra=True)
eq("bd_list: infra on request", "--include-infra" in calls[-1][0], True)
m.sh = fake_sh("{\"issues\": [1], \"beads\": [2]}"); eq("bd_list: the issues key", m.bd_list("S"), [1])
m.sh = fake_sh(""); eq("bd_list: silence is an empty list", m.bd_list("S"), [])
eq("age_sec: none or junk is 2^30 s, a good stamp is the difference", (m.age_sec(""), m.age_sec("junk"), m.age_sec(iso(10))), (1073741824, 1073741824, 10))
eq("labels_of: the list, else empty", (m.labels_of({"labels": ["a"]}), m.labels_of({}), m.labels_of({"labels": None})), (["a"], [], []))
eq("ps_count: the lines the pattern matches", m.ps_count("[c]laude.*gate-reviewer", ["u 1 claude --x gate-reviewer", "u 2 grep [c]laude.*gate-reviewer", "u 3 claude", "gate-reviewer claude"]), 1)
eq("ps_count: none is 0", m.ps_count("p", ["a", "b"]), 0)
m.subprocess.run = lambda args, **kw: (seen.append((args, kw)), types.SimpleNamespace(returncode=0, stdout="USER PID %CPU\nu 1 2.0 x\n"))[1]
os.environ["LC_ALL"] = "pt_BR.UTF-8"
eq("ps_lines: one `ps aux`, C locale even when the caller runs pt-BR, the lines", (m.ps_lines(), seen[-1][0], seen[-1][1]["env"]["LC_ALL"]), (["USER PID %CPU", "u 1 2.0 x"], ["ps", "aux"], "C"))
m.subprocess.run = lambda args, **kw: types.SimpleNamespace(returncode=1, stdout="USER PID\nu 1\n"); eq("ps_lines: a failing ps is None, not an empty list", m.ps_lines(), None)
m.subprocess.run = lambda args, **kw: types.SimpleNamespace(returncode=0, stdout=" \n"); eq("ps_lines: silence is None, not an empty list", m.ps_lines(), None)
def _boom(args, **kw):
    raise OSError("no ps")
m.subprocess.run = _boom; eq("ps_lines: a ps that cannot start is None", m.ps_lines(), None)
m.subprocess.run = real_run
m.sh = fake_sh("ID TEMPLATE STATE AGE\ns1 gastown.dog active 5m\ns2 x active\ns3 y\nID z active\ns4 x asleep\ns5 x active 1m\n")
eq("active_sessions: header, short and asleep rows skipped, three columns are enough, 25 s", (m.active_sessions(), calls[-1][1]), ({"gastown.dog": 1, "x": 2}, 25))
m.sh = fake_sh("1\n"); eq("dolt_ok: 10 s, true on a 1", (m.dolt_ok(), calls[-1][1]), (True, 10))
m.sh = fake_sh(""); eq("dolt_ok: false on silence", m.dolt_ok(), False)
DL = "u 9 %s 0.1 1 2 ?? S 1 0:01 /x/dolt sql-server --config c"
eq("dolt_cpu_pct: summed over the dolt lines, one decimal", m.dolt_cpu_pct(["hdr", DL % "100.04", "u 1 7.0 claude", DL % "96.9"]), 196.9)
eq("dolt_cpu_pct: no dolt line is 0.0 (ps answered, dolt is cold)", m.dolt_cpu_pct(["hdr", "u 1 7.0 claude"]), 0.0)
eq("dolt_cpu_pct: a dolt line with junk %CPU is None", m.dolt_cpu_pct([DL % "x"]), None)
eq("dolt_cpu_pct: a dolt line too short to hold a %CPU is None", m.dolt_cpu_pct(["dolt sql-server"]), None)
eq("dolt_cpu_pct: no ps lines is None", m.dolt_cpu_pct(None), None)
good = json.dumps([{"id": "a", "labels": ["story:approved"]}])
def fake_run(rc, out):
    def f(args, **kw):
        seen.append((args, kw))
        return types.SimpleNamespace(returncode=rc, stdout=out)
    return f
m.subprocess.run = fake_run(0, good)
eq("bd_store_rows: ONE cached `bd list --label-any` over the six labels, 20 s, the rows", (m.bd_store_rows("S"), seen[-1][0], seen[-1][1]["timeout"]), ([{"id": "a", "labels": ["story:approved"]}], ["bash", m.BD_LIST_CACHED, "-C", "S", "list", "--status", "open", "--json", "--label-any", "story:in-flight,story:approved,ctx:ready,story:triage,story:unrefined,story:refino-escalado", "--limit", "0"], 20))
m.subprocess.run = fake_run(0, "[]"); eq("bd_store_rows: a real empty answer is an empty list, not a failure", m.bd_store_rows("S"), [])
# bd list cuts at 50 rows unless `--limit 0` is in argv (ga-21kmp): fake that. 60 beads on the store, the in-flight one LAST (a low-priority bead sorts after the 50 that fit).
BIG = [{"id": "b%d" % i, "labels": ["story:approved"]} for i in range(59)] + [{"id": "last", "labels": ["story:in-flight"]}]
def fake_bd_cut_at_50(args, **kw):
    i = args.index("--limit") if "--limit" in args else -1
    uncut = i >= 0 and i + 1 < len(args) and args[i + 1] == "0"
    return types.SimpleNamespace(returncode=0, stdout=json.dumps(BIG if uncut else BIG[:50]))
m.subprocess.run = fake_bd_cut_at_50
got = m.bd_store_rows("S")
eq("bd_store_rows: a store with more than 50 beads comes back whole, the in-flight row last included", (len(got), [b["id"] for b in m.rows_with(got, "story:in-flight")]), (60, ["last"]))
m.subprocess.run = fake_run(0, "{\"issues\": [1]}"); eq("bd_store_rows: the issues key", m.bd_store_rows("S"), [1])
m.subprocess.run = fake_run(1, good); eq("bd_store_rows: a non-zero exit is None even with rows on stdout", m.bd_store_rows("S"), None)
m.subprocess.run = fake_run(0, ""); eq("bd_store_rows: silence is None (a read that returned nothing), not []", m.bd_store_rows("S"), None)
m.subprocess.run = fake_run(0, "not json"); eq("bd_store_rows: garbage is None", m.bd_store_rows("S"), None)
m.subprocess.run = fake_run(0, "{\"id\": \"a\"}"); eq("bd_store_rows: an object with no list is None", m.bd_store_rows("S"), None)
m.subprocess.run = fake_run(0, "{\"issues\": \"x\"}"); eq("bd_store_rows: an issues key that is not a list is None", m.bd_store_rows("S"), None)
m.subprocess.run = fake_run(0, "5"); eq("bd_store_rows: a bare number is None", m.bd_store_rows("S"), None)
m.subprocess.run = _boom; eq("bd_store_rows: a bd that cannot start is None", m.bd_store_rows("S"), None)
m.subprocess.run = real_run
R = [{"labels": ["story:approved", "ctx:ready"]}, {"labels": ["story:triage"]}, {}, {"labels": None}]
eq("rows_with: a bead carrying two labels answers to both; no labels answers to none", ([len(m.rows_with(R, l)) for l in ("story:approved", "ctx:ready", "story:triage", "story:unrefined")]), [1, 1, 1, 0])
m.dolt_ok = lambda: False; m.dolt_cpu_pct = lambda lines: 12.5; m.ps_lines = lambda: ["ps"]
eq("sample: Dolt down is state unknown and nothing counted", m.sample(), {"ts": E, "working": 0, "had_work": 0, "state": "unknown", "dolt_ok": False, "reviewing": 0, "building": 0, "refining": 0, "dolt_cpu": 12.5})
m.dolt_ok = lambda: True; m.ps_lines = lambda: None
eq("sample: a ps that did not answer is state unknown (never zero reviewers), named", m.sample(), {"ts": E, "working": 0, "had_work": 0, "state": "unknown", "dolt_ok": True, "reviewing": 0, "building": 0, "refining": 0, "dolt_cpu": None, "read_failed": "ps"})
m.ps_lines = lambda: ["ps"]; m.bd_list = lambda *a, **k: []
m.bd_store_rows = lambda store: None if store == m.RIG_STORES[0] else []
eq("sample: one store whose read failed is state unknown (never no-work-there), named", m.sample(), {"ts": E, "working": 0, "had_work": 0, "state": "unknown", "dolt_ok": True, "reviewing": 0, "building": 0, "refining": 0, "dolt_cpu": 12.5, "read_failed": m.RIG_STORES[0]})
# the cut itself (ga-6gdsknp): a whole sample is 4 bd reads (markers + one per store) + 1 ps + 1 Dolt probe = 6 spawns, not 23
def spawn_world(args, **kw):
    seen.append((args, kw))
    if args[:2] == ["ps", "aux"]:
        return types.SimpleNamespace(returncode=0, stdout="USER PID %CPU\nu 9 5.0 x dolt sql-server\n")
    if args[0] == "bash" and len(args) > 1 and args[1] == m.BD_LIST_CACHED:
        return types.SimpleNamespace(returncode=0, stdout="[]")
    return types.SimpleNamespace(returncode=0, stdout="1")
m2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(m2)
m2.subprocess.run = spawn_world; n0 = len(seen); rec = m2.sample(); m2.subprocess.run = real_run
eq("sample: six spawns in all (4 bd + ps + Dolt probe)", len(seen) - n0, 6)
eq("sample: the Dolt %CPU is read from that one ps", (rec["dolt_cpu"], rec["state"]), (5.0, "idle_correct"))
m.dolt_ok = lambda: True; m.ps_lines = lambda: ["ps"]; m.dolt_cpu_pct = lambda lines: 12.5
def world(markers=(), inflight=(), approved=0, ready=(), refine=0, rev=0, ref=0):
    def bd(store, *labels, status="open", include_infra=False):
        eq("only the marker read is still per label", (store, labels[0]), (m.HQ, "type:quality-gate-marker"))
        eq("the marker read asks for infra beads", include_infra, True)
        return [{"labels": [labels[0], "gate-status:" + s], "updated_at": iso(a * 60)} for s, a in markers]
    def rows(store):
        if store != m.HQ:
            return []
        return ([{"labels": ["story:in-flight"], "updated_at": iso(a)} for a in inflight]
                + [{"labels": ["story:approved"]}] * approved
                + [{"labels": ["ctx:ready"] + x} for x in ready]
                + [{"labels": ["story:triage"]}] * refine)
    m.bd_list = bd
    m.bd_store_rows = rows
    m.ps_count = lambda pat, lines: rev if "gate-reviewer" in pat else ref
    return m.sample()
def chk(name, w, **want):
    eq(name, {k: w[k] for k in want}, want)
Z = dict(n_active_review_markers=0, n_reviewer_procs=0, n_building_fresh=0, n_inflight_total=0, n_refino_procs=0, avail_queued_markers=0, avail_approved=0, avail_ready_bugs=0, avail_refine_pending=0, gate_oldest_queued_min=0)
chk("empty world", world(), state="idle_correct", gate_state="idle_correct", build_state="idle_correct", refino_state="idle_correct", working=0, had_work=0, reviewing=0, building=0, refining=0, dolt_ok=True, **Z)
chk("a reviewer process alone", world(rev=1), state="winding_down", gate_state="winding_down", working=1, had_work=0, reviewing=1, n_reviewer_procs=1)
chk("one open review marker alone", world(markers=[("reviewing", 5)]), state="winding_down", gate_state="winding_down", reviewing=1, n_active_review_markers=1, avail_queued_markers=0, gate_oldest_queued_min=0)
chk("running and dispatching markers are open too", world(markers=[("running", 5), ("dispatching", 5)]), reviewing=1, n_active_review_markers=2)
chk("queued markers, no reviewer: the oldest decides", world(markers=[("ready", 30), ("claimed", 200), ("queued", 100)]), state="idle_stalled", gate_state="idle_stalled", working=0, had_work=1, avail_queued_markers=3, gate_oldest_queued_min=200)
chk("a queued marker AT the stall limit with a reviewer: productive", world(markers=[("queued", 165)], rev=1), state="productive", gate_state="productive", gate_oldest_queued_min=165)
chk("one minute past the limit: the gate is stalled, the machine still working", world(markers=[("queued", 166)], rev=1), state="productive", gate_state="idle_stalled")
chk("a fresh builder with approved work", world(inflight=[7199], approved=1), state="productive", build_state="productive", building=1, n_building_fresh=1, n_inflight_total=1, avail_approved=1)
chk("a builder untouched for exactly BUILD_FRESH_SEC is a zombie", world(inflight=[7200], approved=1), state="idle_stalled", build_state="idle_stalled", building=0, n_building_fresh=0, n_inflight_total=1)
chk("a builder with nothing waiting is winding down; the totals count every bead", world(inflight=[100, 7200, 8000]), state="winding_down", build_state="winding_down", n_building_fresh=1, n_inflight_total=3)
chk("refining with work, refining alone, work with no refiner", world(refine=2, ref=1), refino_state="productive", refining=1, avail_refine_pending=2, n_refino_procs=1)
chk("refine work alone", world(refine=1), state="idle_stalled", refino_state="idle_stalled", had_work=1, working=0)
chk("a refiner alone", world(ref=1), state="winding_down", refino_state="winding_down", refining=1, working=1, had_work=0)
chk("ready bugs: exec:auto and not already in flight", world(ready=[["exec:auto"], ["exec:auto", "x"], ["exec:auto", "story:in-flight"], ["x"], []]), build_state="idle_stalled", avail_ready_bugs=2, had_work=1)
m.bd_store_rows = lambda store: [{"labels": ["story:triage", "story:unrefined", "story:approved", "ctx:ready", "exec:auto", "story:in-flight"], "updated_at": iso(5)}] if store == m.HQ else []
chk("one bead on six labels is read once and counted once per label, as six reads counted it", m.sample(), avail_refine_pending=2, avail_approved=1, avail_ready_bugs=0, n_inflight_total=1, n_building_fresh=1)
m.subprocess.run = lambda args, **kw: seen.append((args, kw))
m.NOTIFY = "/n"; m.notify_fail("boom")
eq("notify_fail: titled, priority 4, captured, 10 s", seen[-1], (["/n", "-t", "Machine Utilization Sampler", "-p", "4", "\U0001f6a8 boom"], {"capture_output": True, "timeout": 10}))
m.subprocess.run = real_run
d = tempfile.mkdtemp(); m.OUT = os.path.join(d, "o.jsonl"); m.sample = lambda: {"ts": 1}
m.main(); m.main()
with open(m.OUT) as f:
    eq("main: one JSON line per run, into a directory that already exists", f.read(), "{\"ts\": 1}\n{\"ts\": 1}\n")
sys.argv = ["mus", "--print"]; buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.main()
eq("main --print: indented by 2", buf.getvalue(), "{\n  \"ts\": 1\n}\n")
for line in bad:
    print("FAIL " + line)
print("DONE %d" % len(bad))
'
PYOUT="$(python3 -c "$PYT" "$J" 2>&1)"
case "$PYOUT" in *"DONE 0") ok "sample(): every flag, state and counter answers as the contract says" ;; *) bad "sampler worlds: $PYOUT" ;; esac
echo ""
echo "machine-utilization-sampler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
