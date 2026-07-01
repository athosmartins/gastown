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
