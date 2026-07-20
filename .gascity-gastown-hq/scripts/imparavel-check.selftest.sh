#!/usr/bin/env bash
# Selftest for imparavel-check.py — proves the PURE classify_bead decision in
# isolation (no Dolt/bd/git I/O), the way the other *.selftest.sh prove their pure
# decision fn. Regression cover for the exec:manual / already-built-in-gate
# false-positive (observed as WA/wa-8y45, later reproduced live with WA/wa-k4r12 +
# HQ/ga-8zxcn): an already-built bead awaiting the gate must classify as PARKED,
# never as a silent buildable stall — WHILE a genuinely buildable, never-built,
# un-parked bead must STILL classify as STUCK (real ❌ detection preserved).
#
# Run: bash scripts/imparavel-check.selftest.sh   (exit 0 = all pass)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SELF_DIR/imparavel-check.py"
[ -f "$CHECK" ] || { echo "FATAL: imparavel-check.py not found at $CHECK"; exit 1; }

python3 - "$CHECK" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("imp", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["imp"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def eq(name, got, exp):
    global PASS, FAIL
    if got == exp:
        PASS += 1; print("  ✓ %s (=%r)" % (name, got))
    else:
        FAIL += 1; print("  ✗ %s: expected %r got %r" % (name, exp, got))

C = m.classify_bead
IN_GATE = {"wa-8y45", "wa-k4r12", "ga-8zxcn"}   # beads w/ an OPEN quality-gate-marker
NONE = set()

print("── parking labels → parked (not a silent stall) ──")
eq("exec:manual", C("wa-8y45", ["ctx:ready", "exec:manual"], NONE)[0], "parked")
eq("on-device", C("b", ["ctx:ready", "on-device"], NONE)[0], "parked")
eq("story:needs-device", C("b", ["story:needs-device"], NONE)[0], "parked")
eq("blocked", C("b", ["blocked"], NONE)[0], "parked")
eq("gate:needs-human:on-device (colon variant)", C("b", ["gate:needs-human:on-device"], NONE)[0], "parked")
eq("pilot:held-until:<future> (dash variant of pilot:held)",
   C("b", ["ctx:ready", "pilot:held-until:9999999999"], NONE)[0], "parked")
# NOTE: pilot:held (parking, added 2026-06-28) shadows the held-loop branch by design —
# ANY pilot:held-until:* bead parks. Held work is intentionally NOT a silent stall.
eq("pilot:held-until repeated 7x (held-loop) still parks", C("b", ["ctx:ready"]
   + ["pilot:held-until:%d" % i for i in range(7)], NONE)[0], "parked")

print("── ga-hzt8s: PARKING_LABELS now sourced from canonical park_labels.py — "
      "labels this file didn't previously recognize also park ──")
eq("needs-label-review", C("b", ["needs-label-review"], NONE)[0], "parked")
eq("phone-proxy", C("b", ["ctx:ready", "phone-proxy"], NONE)[0], "parked")
eq("story:refinement-in-progress", C("b", ["ctx:ready", "story:refinement-in-progress"], NONE)[0], "parked")
eq("ctx:thin", C("b", ["ctx:ready", "ctx:thin"], NONE)[0], "parked")
eq("story:cancelled", C("b", ["story:cancelled"], NONE)[0], "parked")
eq("framework:engine", C("b", ["framework:engine"], NONE)[0], "parked")
eq("story:awaiting-external-merge", C("b", ["story:awaiting-external-merge"], NONE)[0], "parked")
eq("pilot:no-auto-dispatch", C("b", ["ctx:ready", "pilot:no-auto-dispatch"], NONE)[0], "parked")
eq("pool:refused:engine-rebuild-required", C("b", ["pool:refused:engine-rebuild-required"], NONE)[0], "parked")
eq("blocked-on:<id> (via 'blocked' base + dash-suffix match)",
   C("b", ["ctx:ready", "blocked-on:wa-9999"], NONE)[0], "parked")
# regression guard: a genuinely buildable bead must still classify as stuck, unaffected
# by the wider PARKING_LABELS import.
eq("still stuck: ctx:ready+exec:auto, none of the new labels", C("fresh", ["ctx:ready", "exec:auto"], NONE)[0], "stuck")

print("── (b) REGRESSION: already-built / in-gate → parked, NOT stuck ──")
# wa-8y45 at symptom time: STALE ctx:ready+exec:auto (the context-check-dispatcher had
# not yet flipped exec:auto→exec:manual), but a DURABLE open gate marker named it.
k, r = C("wa-8y45", ["ctx:ready", "exec:auto"], IN_GATE)
eq("wa-8y45 stale exec:auto + open marker → parked", k, "parked")
eq("  …reason == in-gate", r, "in-gate")
# wa-k4r12 (live repro): ctx:ready+exec:auto+gate:reviewing + open marker.
eq("wa-k4r12 exec:auto+gate:reviewing + marker → parked",
   C("wa-k4r12", ["ctx:ready", "exec:auto", "gate:reviewing"], IN_GATE)[0], "parked")
# gate:* lifecycle label alone (no marker) also means already-in-gate.
eq("gate:reviewing label, no marker → parked",
   C("b", ["ctx:ready", "exec:auto", "gate:reviewing"], NONE)[0], "parked")
eq("gate:needs-rebase label, no marker → parked",
   C("b", ["ctx:ready", "gate:needs-rebase"], NONE)[0], "parked")
# ga-8zxcn: gate:needs-fix + gate:reviewing + ACTIVE marker → marker is authoritative
# (the gate is actively re-reviewing the fix-attempt) → parked, gate owns it.
eq("ga-8zxcn needs-fix + ACTIVE marker → parked (gate owns it)",
   C("ga-8zxcn", ["ctx:ready", "exec:auto", "gate:failed", "gate:needs-fix", "gate:reviewing"], IN_GATE)[0],
   "parked")

print("── needs-fix carve-out: re-dispatchable when NO active gate run ──")
# Mirrors the Pilot's _filter_built: gate:needs-fix (branch bounced back for a fix) is a
# fresh dispatch candidate again — so with NO active marker it stays eligible (stuck).
eq("gate:needs-fix, no marker → stuck", C("b", ["ctx:ready", "exec:auto", "gate:needs-fix"], NONE)[0], "stuck")
eq("needs-fix dominates a sibling gate:reviewing (no marker) → stuck",
   C("b", ["ctx:ready", "gate:needs-fix", "gate:reviewing"], NONE)[0], "stuck")

print("── real ❌ detection PRESERVED (genuinely buildable, never built) ──")
eq("ctx:ready+exec:auto, no parking/marker/gate → stuck", C("fresh", ["ctx:ready", "exec:auto"], NONE)[0], "stuck")
eq("bare ctx:ready → stuck", C("fresh", ["ctx:ready"], NONE)[0], "stuck")
eq("no labels → stuck", C("fresh", [], NONE)[0], "stuck")
# ...and being in the gate set only parks the bead whose id matches — not its neighbours.
eq("un-parked bead NOT in the gate set → stuck", C("other", ["ctx:ready"], IN_GATE)[0], "stuck")

print("── flowing ──")
eq("story:in-flight → flowing", C("b", ["ctx:ready", "story:in-flight"], NONE)[0], "flowing")

print("── _label_is_gate_inflight helper ──")
eq("gate:reviewing in-flight", m._label_is_gate_inflight("gate:reviewing"), True)
eq("gate:needs-rebase in-flight", m._label_is_gate_inflight("gate:needs-rebase"), True)
eq("gate:passed in-flight", m._label_is_gate_inflight("gate:passed"), True)
eq("gate:needs-fix NOT in-flight (re-dispatchable)", m._label_is_gate_inflight("gate:needs-fix"), False)
eq("gate:needs-human NOT in-flight (parked separately)", m._label_is_gate_inflight("gate:needs-human"), False)
eq("ctx:ready NOT gate-inflight", m._label_is_gate_inflight("ctx:ready"), False)

print("── _pilot_slots(): parses the Pilot's 'Available slots' log line ──")
import types
def _fake_sh_factory(stdout):
    def _fake(args, timeout=20):
        return types.SimpleNamespace(returncode=0, stdout=stdout)
    return _fake

m._sh = _fake_sh_factory(
    "[2026-07-16 13:42:49] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n"
    "[2026-07-16 13:42:54] [pilot-dispatcher] Available slots: small=0  big=1\n"
    "[2026-07-16 13:50:34] [pilot-dispatcher] In-flight: live=5 small=4/5  big=1/2\n"
    "[2026-07-16 13:50:36] [pilot-dispatcher] Available slots: small=1  big=1\n")
eq("picks the LAST (most recent) Available-slots line", m._pilot_slots(), {"small": 1, "big": 1})

m._sh = _fake_sh_factory("[2026-07-16 13:42:49] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n")
eq("no Available-slots line yet → None", m._pilot_slots(), None)

m._sh = _fake_sh_factory("")
eq("empty log → None", m._pilot_slots(), None)

m._sh = lambda args, timeout=20: None
eq("_sh failure (command errored) → None", m._pilot_slots(), None)

print("── ga-wmrr regression: saturated pool downgrades ❌ stuck → ℹ️  note, not fails ──")
# Reproduces the reported incident: pilot-dispatchable.json has 1 genuinely
# buildable, never-built bead; the Pilot log says BOTH lanes are fully saturated
# (small=0 big=0). main()'s verdict must NOT treat this as a dispatch failure.
import json, tempfile, os
snap2 = {"generated_at": "2999-01-01T00:00:00Z", "ttl_seconds": 600, "count": 1,
         "items": [{"id": "wa-QUEUED", "store": "whatsapp_automation", "title": "queued behind full pool"}]}
_fd2, _p2 = tempfile.mkstemp(suffix=".json"); os.write(_fd2, json.dumps(snap2).encode()); os.close(_fd2)
m.DISPATCHABLE_JSON = _p2
m._gate_source_beads = lambda: set()
m._bd_show_labels_text = lambda root, bid: ["ctx:ready", "exec:auto"]
_a2 = m.check_approved()
os.unlink(_p2)
eq("fixture: exactly one genuinely-stuck bead pre-fix", [s["id"] for s in _a2["stuck"]], ["wa-QUEUED"])

m._sh = _fake_sh_factory("[2026-07-16 14:00:00] [pilot-dispatcher] Available slots: small=0  big=0\n")
_slots_sat = m._pilot_slots()
eq("both lanes saturated parses as small=0 big=0", _slots_sat, {"small": 0, "big": 0})
_pool_saturated = bool(_slots_sat) and _slots_sat["small"] <= 0 and _slots_sat["big"] <= 0
eq("pool_saturated flag true when both lanes are 0", _pool_saturated, True)

m._sh = _fake_sh_factory("[2026-07-16 14:00:00] [pilot-dispatcher] Available slots: small=0  big=2\n")
_slots_room = m._pilot_slots()
_pool_saturated2 = bool(_slots_room) and _slots_room["small"] <= 0 and _slots_room["big"] <= 0
eq("pool_saturated flag false when a lane still has room (small=0 big=2)", _pool_saturated2, False)

print("── main() end-to-end: saturated pool → verdict is ✅, not ❌ (ga-wmrr) ──")
import io, contextlib
_orig_check_approved, _orig_check_gate = m.check_approved, m.check_gate
_orig_check_pilot, _orig_check_dolt = m.check_pilot, m.check_dolt
_orig_pilot_slots, _orig_rigs = m._pilot_slots, m.RIGS

m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 1,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-QUEUED", "rig": "WA", "title": "queued behind full pool"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m._pilot_slots = lambda: {"small": 0, "big": 0}
m.RIGS = []   # skip the live `bd` subprocess calls in the building_now loop

_buf = io.StringIO()
_exit_code = None
try:
    with contextlib.redirect_stdout(_buf):
        m.main()
except SystemExit as e:
    _exit_code = e.code
_out = _buf.getvalue()
eq("saturated pool (small=0 big=0): exit code 0 (✅, no ❌/⚠️)", _exit_code, 0)
eq("saturated pool: report mentions 'pool saturado'", "pool saturado" in _out, True)
eq("saturated pool: ✅ summary names the saturation, not silence", "Pool saturado (slots cheios)" in _out, True)
eq("saturated pool: report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _out, False)

print("── main() end-to-end: a lane still has room + stuck → STILL ❌ (real stall preserved) ──")
m._pilot_slots = lambda: {"small": 1, "big": 0}   # small has a free slot, queue skipped it anyway
_buf2 = io.StringIO()
_exit_code2 = None
try:
    with contextlib.redirect_stdout(_buf2):
        m.main()
except SystemExit as e:
    _exit_code2 = e.code
_out2 = _buf2.getvalue()
eq("free slot unused: exit code 1 (❌ failure preserved)", _exit_code2, 1)
eq("free slot unused: report says NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _out2, True)

m.check_approved, m.check_gate = _orig_check_approved, _orig_check_gate
m.check_pilot, m.check_dolt = _orig_check_pilot, _orig_check_dolt
m._pilot_slots, m.RIGS = _orig_pilot_slots, _orig_rigs

print("── end-to-end: check_approved() over a fixture snapshot (bd/Dolt mocked) ──")
# Snapshot mixes an already-built in-gate bead with a GENUINELY stuck one. The in-gate
# bead must be parked (in_gate_count=1); ONLY the genuine bead may reach the stuck list.
import json, tempfile, os
snap = {"generated_at": "2999-01-01T00:00:00Z", "ttl_seconds": 600, "count": 2,
        "items": [
            {"id": "wa-INGATE", "store": "whatsapp_automation", "title": "built, awaiting gate"},
            {"id": "wa-STUCK",  "store": "whatsapp_automation", "title": "buildable, never built"}]}
_fd, _p = tempfile.mkstemp(suffix=".json"); os.write(_fd, json.dumps(snap).encode()); os.close(_fd)
m.DISPATCHABLE_JSON = _p
m._age_min = lambda iso: 1.0                       # treat snapshot as 1 min old (live)
m._gate_source_beads = lambda: {"wa-INGATE"}       # only the in-gate bead has an open marker
_LIVE = {"wa-INGATE": ["ctx:ready", "exec:auto", "gate:reviewing"],
         "wa-STUCK":  ["ctx:ready", "exec:auto"]}
m._bd_show_labels_text = lambda root, bid: _LIVE.get(bid)
_a = m.check_approved()
os.unlink(_p)
eq("in_gate_count == 1", _a["in_gate_count"], 1)
eq("stuck list == [wa-STUCK] (in-gate NOT flagged, genuine IS)",
   [s["id"] for s in _a["stuck"]], ["wa-STUCK"])
eq("from_dispatchable path used (not fallback)", _a["from_dispatchable"], True)

print()
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
