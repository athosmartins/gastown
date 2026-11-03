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

# ga-30xi3: captured BEFORE any test below gets a chance to replace m._sh with a
# fake (many do, via _fake_sh_factory, and never restore the true original — only
# their OWN fake round-trips). The ga-30xi3 block further down needs the REAL,
# unmodified _sh() (the one that actually calls subprocess.run) to prove its fix;
# grabbing "whatever m._sh currently is" at that point would silently test a fake
# instead and pass vacuously.
_TRUE_ORIGINAL_SH_30xi3 = m._sh

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
# ga-58bnot: kept intentionally as-is. This file only ever READS classify_bead's
# verdict to decide whether to alarm "stuck" — it never adds/removes a label, so
# treating needs-label-review as "parked" here is harmless (suppresses a false
# stall alarm while a human hasn't confirmed the reconciler's keyword flag yet).
# bead_state.py's PARK_EXACT (a DIFFERENT vocabulary, consulted by consumers that
# DO mutate labels — lifecycle-coherence-janitor.sh's R4/R8) dropped
# needs-label-review for the opposite reason: there, it was silently disarming
# approved+armed beads (wa-ycawt). The two vocabularies now diverge on this one
# label ON PURPOSE — see bead_state.py's PARK_EXACT comment for the full story.
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

print("── ga-k5gl8hd: lane:kimi — a bead the Kimi pass owns is PARKED (reason kimi-lane), never "
      "'stuck'; pilot-dispatchable.json is written BEFORE that pass, so it is in the snapshot ──")
# The lane being open or closed is invisible to the classifier on purpose (it only sees labels), so
# one label set stands for both: a waiting lane:kimi bead is parked either way.
eq("lane:kimi waiting → ('parked', 'kimi-lane')",
   C("b", ["ctx:ready", "exec:auto", "lane:kimi"], NONE), ("parked", "kimi-lane"))
eq("lane:kimi + story:approved → parked kimi-lane",
   C("b", ["ctx:ready", "story:approved", "lane:kimi"], NONE), ("parked", "kimi-lane"))
eq("lane:kimi + gate:needs-fix (bounced) → parked kimi-lane (the normal loop never sees it either)",
   C("b", ["ctx:ready", "gate:needs-fix", "lane:kimi"], NONE), ("parked", "kimi-lane"))
# pilot:held-until:* is itself a parking label (prefix rule), so it wins with reason 'label' — what
# matters here is that a lane:kimi bead with holds, even past HELD_LOOP_MAX, is never 'stuck'.
eq("lane:kimi + pilot:held-until:<epoch> → parked (not stuck)",
   C("b", ["ctx:ready", "lane:kimi", "pilot:held-until:99999999999"], NONE)[0], "parked")
eq("lane:kimi + 6 held-until marks → parked, NOT a held-loop stuck",
   C("b", ["lane:kimi"] + ["pilot:held-until:%d" % (1000 + i) for i in range(6)], NONE)[0], "parked")
eq("lane:kimi + story:in-flight → flowing (the Kimi worker is building it: keeps the delivery-stall age check)",
   C("b", ["ctx:ready", "lane:kimi", "story:in-flight"], NONE)[0], "flowing")
eq("lane:kimi + an OPEN gate marker → parked in-gate (the gate marker still outranks, same bucket count as before)",
   C("wa-8y45", ["ctx:ready", "lane:kimi"], IN_GATE), ("parked", "in-gate"))
eq("lane:kimi + needs-human → parked label (a parking label still wins and keeps its own reason)",
   C("b", ["ctx:ready", "lane:kimi", "story:needs-human"], NONE)[0:1], ("parked",))
eq("CONTROL: the same bead WITHOUT lane:kimi stays stuck",
   C("b", ["ctx:ready", "exec:auto"], NONE)[0], "stuck")
eq("CONTROL: lane:small / lane:big stay stuck (only the Kimi lane is owned by another pass)",
   (C("b", ["ctx:ready", "lane:small"], NONE)[0], C("b", ["ctx:ready", "lane:big"], NONE)[0]),
   ("stuck", "stuck"))
eq("CONTROL: lane:kimi-not is NOT the Kimi lane (exact match, like the dispatcher's index(\"lane:kimi\")) → stuck",
   C("b", ["ctx:ready", "lane:kimi-not"], NONE)[0], "stuck")
eq("CONTROL: a label that merely CONTAINS lane:kimi (x-lane:kimi) is not the Kimi lane → stuck",
   C("b", ["ctx:ready", "x-lane:kimi"], NONE)[0], "stuck")

print("── ga-26us5: classify_in_flight() — a story:in-flight LABEL alone is not proof of "
      "progress; only real recent updated_at is (AC1/AC3) ──")
CIF = m.classify_in_flight
eq("just updated (0min), well within a 180min threshold -> building", CIF(0.0, 180.0), "building")
eq("fresh (5min) within threshold -> building", CIF(5.0, 180.0), "building")
eq("exactly at the threshold boundary (180min == 180min) -> building (inclusive)",
   CIF(180.0, 180.0), "building")
eq("just past the boundary (180.1min > 180min) -> delivery-stalled", CIF(180.1, 180.0), "delivery-stalled")
eq("4h stale (240min) against the default 3h(180min) threshold -> delivery-stalled "
   "(reproduces the wa-v66xt shape from the original report)", CIF(240.0, 180.0), "delivery-stalled")
eq("unknown age (None, e.g. missing/unparseable updated_at) -> delivery-stalled, NEVER a free pass",
   CIF(None, 180.0), "delivery-stalled")

print("── ga-26us5 AC2: DELIVERY_STALL_HOURS is IMPORTED from throughput-stall-watchdog.py, "
      "never a new hardcoded number — cross-checked against an independent fresh import of "
      "the real source, so the two checks cannot silently drift apart ──")
import os
eq("import of DELIVERY_STALL_HOURS from throughput-stall-watchdog.py succeeded (no fallback warning)",
   m._TSW_LOAD_WARN, None)
_tsw_indep_spec = importlib.util.spec_from_file_location(
    "tsw_independent",
    os.path.join(os.path.dirname(os.path.abspath(m.__file__)), "throughput-stall-watchdog.py"))
_tsw_indep = importlib.util.module_from_spec(_tsw_indep_spec)
_tsw_indep_spec.loader.exec_module(_tsw_indep)
eq("imparavel-check.DELIVERY_STALL_HOURS == an INDEPENDENTLY loaded throughput-stall-watchdog.DELIVERY_STALL_HOURS "
   "(not just internal self-consistency — proves single-sourcing, not a coincidental fallback match)",
   m.DELIVERY_STALL_HOURS, _tsw_indep.DELIVERY_STALL_HOURS)

print("── _label_is_gate_inflight helper ──")
eq("gate:reviewing in-flight", m._label_is_gate_inflight("gate:reviewing"), True)
eq("gate:needs-rebase in-flight", m._label_is_gate_inflight("gate:needs-rebase"), True)
eq("gate:passed in-flight", m._label_is_gate_inflight("gate:passed"), True)
eq("gate:needs-fix NOT in-flight (re-dispatchable)", m._label_is_gate_inflight("gate:needs-fix"), False)
eq("gate:needs-human NOT in-flight (parked separately)", m._label_is_gate_inflight("gate:needs-human"), False)
eq("ctx:ready NOT gate-inflight", m._label_is_gate_inflight("ctx:ready"), False)

print("── _read_pilot_log_tail()+_pilot_slots(): parses the Pilot's 'Available slots' log line ──")
import types
def _fake_sh_factory(stdout):
    def _fake(args, timeout=20):
        return types.SimpleNamespace(returncode=0, stdout=stdout)
    return _fake

# ga-zkxdw attempt 2 GATE-FEEDBACK: _pilot_slots()/_pilot_candidates()/_sweep_in_flight()
# no longer call _sh()/tail on their own — main() reads PILOT_LOG's tail EXACTLY ONCE via
# _read_pilot_log_tail() and threads that SAME snapshot into all three, so they can never
# describe different sweeps. Tests below fake _sh, take the seam's reading via
# _read_pilot_log_tail(), then feed that snapshot into the pure functions — the same
# integration path main() uses.
# NOTE: every fixture below needs a leading '=== Pilot sweep start' marker —
# _pilot_slots()/_pilot_candidates() are sweep-segmented post-GATE-FEEDBACK fix
# (see the dedicated section further down) and return None without one.
m._sh = _fake_sh_factory(
    "[2026-07-16 13:42:49] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-07-16 13:42:49] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n"
    "[2026-07-16 13:42:54] [pilot-dispatcher] Available slots: small=0  big=1\n"
    "[2026-07-16 13:42:59] [pilot-dispatcher] === Pilot sweep complete: dispatched=1"
    " (small_slots=0 big_slots=1 dolt_saturated_at_start=0) ===\n"
    "[2026-07-16 13:50:34] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-07-16 13:50:34] [pilot-dispatcher] In-flight: live=5 small=4/5  big=1/2\n"
    "[2026-07-16 13:50:36] [pilot-dispatcher] Available slots: small=1  big=1\n")
eq("picks the CURRENT sweep's Available-slots line, not an older sweep's",
   m._pilot_slots(m._read_pilot_log_tail()), {"small": 1, "big": 1})

m._sh = _fake_sh_factory(
    "[2026-07-16 13:42:49] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-07-16 13:42:49] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n")
eq("sweep started but no Available-slots line yet → None", m._pilot_slots(m._read_pilot_log_tail()), None)

m._sh = _fake_sh_factory("")
eq("empty log → None (_read_pilot_log_tail)", m._read_pilot_log_tail(), None)
eq("empty log → None (_pilot_slots)", m._pilot_slots(m._read_pilot_log_tail()), None)

m._sh = lambda args, timeout=20: None
eq("_sh failure (command errored) → None (_read_pilot_log_tail)", m._read_pilot_log_tail(), None)
eq("_sh failure (command errored) → None (_pilot_slots)", m._pilot_slots(m._read_pilot_log_tail()), None)

m._sh = _fake_sh_factory(
    "[2026-07-16 13:42:49] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n"
    "[2026-07-16 13:42:54] [pilot-dispatcher] Available slots: small=9  big=9\n")
eq("no sweep-start marker visible at all → None, not a best-effort read", m._pilot_slots(m._read_pilot_log_tail()), None)

eq("_pilot_slots(None) — no snapshot at all → None (pure-function contract, no I/O)", m._pilot_slots(None), None)

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

m._sh = _fake_sh_factory(
    "[2026-07-16 14:00:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-07-16 14:00:00] [pilot-dispatcher] Available slots: small=0  big=0\n")
_slots_sat = m._pilot_slots(m._read_pilot_log_tail())
eq("both lanes saturated parses as small=0 big=0", _slots_sat, {"small": 0, "big": 0})
_pool_saturated = bool(_slots_sat) and _slots_sat["small"] <= 0 and _slots_sat["big"] <= 0
eq("pool_saturated flag true when both lanes are 0", _pool_saturated, True)

m._sh = _fake_sh_factory(
    "[2026-07-16 14:00:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-07-16 14:00:00] [pilot-dispatcher] Available slots: small=0  big=2\n")
_slots_room = m._pilot_slots(m._read_pilot_log_tail())
_pool_saturated2 = bool(_slots_room) and _slots_room["small"] <= 0 and _slots_room["big"] <= 0
eq("pool_saturated flag false when a lane still has room (small=0 big=2)", _pool_saturated2, False)

print("── main() end-to-end: saturated pool → verdict is ✅, not ❌ (ga-wmrr) ──")
import io, contextlib
_orig_check_approved, _orig_check_gate = m.check_approved, m.check_gate
_orig_check_pilot, _orig_check_dolt = m.check_pilot, m.check_dolt
_orig_pilot_slots, _orig_rigs = m._pilot_slots, m.RIGS
_orig_pilot_candidates0, _orig_sweep_in_flight0 = m._pilot_candidates, m._sweep_in_flight
_orig_read_pilot_log_tail0 = m._read_pilot_log_tail

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
# _read_pilot_log_tail() is pinned to a harmless constant — the snapshot value is
# irrelevant here since _pilot_slots()/_pilot_candidates()/_sweep_in_flight() are
# ALSO pinned below and ignore whatever `lines` they receive; pinning it too just
# avoids a real subprocess `tail` against the live PILOT_LOG path during this test.
m._read_pilot_log_tail = lambda: None
m._pilot_slots = lambda lines: {"small": 0, "big": 0}
# _pilot_candidates()/_sweep_in_flight() explicitly pinned (not left to whatever
# m._sh happened to be set to by an earlier, unrelated section) — this end-to-end
# block tests main()'s branching on pool_saturated alone, so the other two signals
# must be neutral/unknown rather than an accidental leftover value deciding it.
m._pilot_candidates = lambda lines: None
m._sweep_in_flight = lambda lines: False
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
# ga-zkxdw attempt 5 GATE-FEEDBACK: both lanes are literally 0 here (the one
# real "both_empty" case) — the exact wording changed from "pool saturado" to
# "pool cheio" (matching the Mayor's spec text), but the claim itself is still
# correctly made, with numbers, since this fixture genuinely has 0 free
# capacity in both lanes.
eq("saturated pool: report mentions 'pool cheio'", "pool cheio" in _out, True)
eq("saturated pool: ✅ summary names it with numbers, not silence",
   "Pool cheio (slots small=0 big=0)" in _out, True)
eq("saturated pool: report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _out, False)

print("── main() end-to-end: a lane still has room + stuck → STILL ❌ (real stall preserved) ──")
m._pilot_slots = lambda lines: {"small": 1, "big": 0}   # small has a free slot, queue skipped it anyway
m._pilot_candidates = lambda lines: None   # pinned — see note above; sweep_in_flight stays False
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
m._pilot_candidates, m._sweep_in_flight = _orig_pilot_candidates0, _orig_sweep_in_flight0
m._read_pilot_log_tail = _orig_read_pilot_log_tail0

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
_ca_orig_age_min = m._age_min                       # ga-26us5: restore below — this was
                                                      # previously left permanently faked,
                                                      # silently corrupting every later test
                                                      # that depends on real _age_min() output.
m._age_min = lambda iso: 1.0                       # treat snapshot as 1 min old (live)
m._gate_source_beads = lambda: {"wa-INGATE"}       # only the in-gate bead has an open marker
_LIVE = {"wa-INGATE": ["ctx:ready", "exec:auto", "gate:reviewing"],
         "wa-STUCK":  ["ctx:ready", "exec:auto"]}
m._bd_show_labels_text = lambda root, bid: _LIVE.get(bid)
_a = m.check_approved()
os.unlink(_p)
m._age_min = _ca_orig_age_min
eq("in_gate_count == 1", _a["in_gate_count"], 1)
eq("stuck list == [wa-STUCK] (in-gate NOT flagged, genuine IS)",
   [s["id"] for s in _a["stuck"]], ["wa-STUCK"])
eq("from_dispatchable path used (not fallback)", _a["from_dispatchable"], True)

print("── ga-k5gl8hd end-to-end: ONE lane:kimi bead waiting in the snapshot is parked, not stuck ──")
# The Mayor's pre-flight before the first .gc/kimi-lane.on: this is the exact shape (one lane:kimi
# bead + one plain buildable bead in the queue). The Kimi bead must land in kimi_lane_count and
# parked_count; ONLY the plain bead may reach `stuck`.
snap_k = {"generated_at": "2999-01-01T00:00:00Z", "ttl_seconds": 600, "count": 2,
          "items": [
              {"id": "wa-KIMI",  "store": "whatsapp_automation", "title": "waits for the Kimi lane"},
              {"id": "wa-PLAIN", "store": "whatsapp_automation", "title": "buildable, never built"}]}
_fd_k, _p_k = tempfile.mkstemp(suffix=".json"); os.write(_fd_k, json.dumps(snap_k).encode()); os.close(_fd_k)
_k_orig = (m.DISPATCHABLE_JSON, m._age_min, m._gate_source_beads, m._bd_show_labels_text)
m.DISPATCHABLE_JSON = _p_k
m._age_min = lambda iso: 1.0
m._gate_source_beads = lambda: set()
_K_LIVE = {"wa-KIMI":  ["ctx:ready", "exec:auto", "lane:kimi"],
           "wa-PLAIN": ["ctx:ready", "exec:auto"]}
m._bd_show_labels_text = lambda root, bid: _K_LIVE.get(bid)
_ak = m.check_approved()
os.unlink(_p_k)
eq("stuck == [wa-PLAIN] only (the lane:kimi bead is NOT flagged)", [s["id"] for s in _ak["stuck"]], ["wa-PLAIN"])
eq("kimi_lane_count == 1", _ak["kimi_lane_count"], 1)
eq("parked_count == 1 (the Kimi bead is parked)", _ak["parked_count"], 1)
eq("buildable_count == 1 (the Kimi bead is not 'genuinely buildable')", _ak["buildable_count"], 1)
eq("in_gate_count == 0 (a Kimi bead is not mistaken for an in-gate one)", _ak["in_gate_count"], 0)

# Only a Kimi bead in the queue: nothing stuck at all, so the verdict can be ✅ (the false ❌ is gone).
snap_k1 = {"generated_at": "2999-01-01T00:00:00Z", "ttl_seconds": 600, "count": 1,
           "items": [{"id": "wa-KIMI", "store": "whatsapp_automation", "title": "waits for the Kimi lane"}]}
_fd_k1, _p_k1 = tempfile.mkstemp(suffix=".json"); os.write(_fd_k1, json.dumps(snap_k1).encode()); os.close(_fd_k1)
m.DISPATCHABLE_JSON = _p_k1
_ak1 = m.check_approved()
os.unlink(_p_k1)
eq("ONE lane:kimi bead alone → stuck == []", _ak1["stuck"], [])
eq("ONE lane:kimi bead alone → parked_count == 1 and buildable_count == 0",
   (_ak1["parked_count"], _ak1["buildable_count"]), (1, 0))

# The same bead WITHOUT the label is the control: it IS a stuck bead.
_K_LIVE["wa-KIMI"] = ["ctx:ready", "exec:auto"]
_fd_k2, _p_k2 = tempfile.mkstemp(suffix=".json"); os.write(_fd_k2, json.dumps(snap_k1).encode()); os.close(_fd_k2)
m.DISPATCHABLE_JSON = _p_k2
_ak2 = m.check_approved()
os.unlink(_p_k2)
eq("CONTROL: the same single bead without lane:kimi → stuck == [wa-KIMI]",
   [s["id"] for s in _ak2["stuck"]], ["wa-KIMI"])
eq("CONTROL: ...and kimi_lane_count == 0", _ak2["kimi_lane_count"], 0)
m.DISPATCHABLE_JSON, m._age_min, m._gate_source_beads, m._bd_show_labels_text = _k_orig

print("── ga-k5gl8hd fallback (snapshot unavailable → story:approved): a waiting lane:kimi bead "
      "does not age into stuck either ──")
_fb_orig = (m._bd_json, m._age_min, m._gate_source_beads, m.RIGS)
m.RIGS = [("wa", "/x")]
m._gate_source_beads = lambda: set()
m._age_min = lambda iso: 9999.0                       # old enough that a plain bead IS stuck
m._bd_json = lambda root, label, status="open", include_infra=False: ([
    {"id": "wa-KIMI",  "title": "k", "labels": ["story:approved", "lane:kimi"], "updated_at": "2020-01-01T00:00:00Z"},
    {"id": "wa-PLAIN", "title": "p", "labels": ["story:approved"],              "updated_at": "2020-01-01T00:00:00Z"},
    {"id": "wa-NOT",   "title": "n", "labels": ["story:approved", "lane:kimi-not"], "updated_at": "2020-01-01T00:00:00Z"},
], True)
_af = m._check_approved_fallback([])
eq("fallback: stuck == [wa-PLAIN, wa-NOT] (the lane:kimi bead is NOT; lane:kimi-not IS)",
   [s["id"] for s in _af["stuck"]], ["wa-PLAIN", "wa-NOT"])
eq("fallback: kimi_lane_count == 1 and _ok_reasons['kimi-lane'] == 1",
   (_af["kimi_lane_count"], _af["_ok_reasons"]["kimi-lane"]), (1, 1))
eq("fallback: the Kimi bead is counted in parked_count", _af["parked_count"], 1)
m._bd_json, m._age_min, m._gate_source_beads, m.RIGS = _fb_orig

print("── ga-lwi4b regression: check_gate()'s stalled_by_age must respect reviewer_alive ──")
# batista's measured incident (04:17): a queued marker sat 475min (> GATE_STALL_MIN=165)
# purely from queue congestion (24 in the fila) while gate-reviewer was ACTIVE and
# reviewing it that instant. stalled_by_age used to ignore reviewer_alive (only
# stalled_by_silence consulted it), so age alone declared a false GATE travado.
_orig_bd_json, _orig_age_min, _orig_sh_gate = m._bd_json, m._age_min, m._sh
m._bd_json = lambda root, label, status="open", include_infra=False: (
    [{"id": "mk-OLD", "updated_at": "2020-01-01T00:00:00Z", "labels": ["gate-status:dispatching"]}],
    True)
m._age_min = lambda iso: 475.0

def _fake_sh_reviewer_alive(args, timeout=20):
    if args and "session" in args:
        return types.SimpleNamespace(returncode=0, stdout="gastown.gate-reviewer  active  0s\n")
    return types.SimpleNamespace(returncode=0, stdout="")   # DISPATCH_LOG tail: no "Gate PASSED:" lines
m._sh = _fake_sh_reviewer_alive
_g_alive = m.check_gate()
eq("reviewer alive + 475min-old marker: reviewer_alive detected True", _g_alive["reviewer_alive"], True)
eq("reviewer alive + 475min-old marker: stalled must be False (the ga-lwi4b bug)", _g_alive["stalled"], False)

def _fake_sh_reviewer_dead(args, timeout=20):
    return types.SimpleNamespace(returncode=0, stdout="")   # no gate-reviewer active/awake, no Gate PASSED
m._sh = _fake_sh_reviewer_dead
_g_dead = m.check_gate()
eq("reviewer dead + 475min-old marker: reviewer_alive detected False", _g_dead["reviewer_alive"], False)
eq("reviewer dead + 475min-old marker: stalled must STILL be True (real stall preserved)", _g_dead["stalled"], True)

m._bd_json, m._age_min, m._sh = _orig_bd_json, _orig_age_min, _orig_sh_gate

print("── ga-30xi3: _sh() must not collapse a text-decode failure into the same None "
      "a genuine command failure produces (truncated-multibyte session title) ──")
# `gc session list`'s table form truncates titles to fit the column width; when the
# cut lands mid multi-byte UTF-8 char (e.g. an ellipsis U+2026 = bytes e2 80 a6, cut
# after 2 bytes), the process's stdout is not valid UTF-8. subprocess.run(...,
# text=True) decodes INSIDE the call, so THAT decode is what raises
# UnicodeDecodeError — not anything _sh() does — and _sh()'s existing
# `except Exception: return None` swallows it exactly like a real command failure.
# reviewer_alive then collapses "I couldn't read this" into the same False a truly
# dead reviewer produces (error-empty-must-not-produce-same-value class).
#
# The fakes below reproduce that failure mode precisely: they raise unless the
# caller passed errors="replace" (the fix) — mirroring how Python's text-mode
# decode only tolerates bad bytes with that flag, strict (the default) otherwise.
#
# NOTE: m._sh may currently be a leftover fake from an earlier block (several
# reassign it via _fake_sh_factory and never restore it) — that fake never calls
# subprocess.run at all, so testing against "whatever m._sh is right now" would
# pass vacuously regardless of the fix. Pin it to the TRUE original for this
# block, restore the ambient value afterward so later blocks are undisturbed.
_ambient_sh_30xi3 = m._sh
m._sh = _TRUE_ORIGINAL_SH_30xi3
_orig_run_30xi3 = m.subprocess.run

def _fake_run_strict_decode_30xi3(args, **kwargs):
    if kwargs.get("errors") != "replace":
        raise UnicodeDecodeError("utf-8", b"\xe2\x80", 0, 2, "invalid continuation byte")
    return types.SimpleNamespace(returncode=0, stdout="ok\n")

m.subprocess.run = _fake_run_strict_decode_30xi3
eq("_sh() survives a decode failure (passes errors='replace') instead of returning None",
   m._sh(["whatever"]) is not None, True)
m.subprocess.run = _orig_run_30xi3

# End-to-end, faithful to the measured incident: ONE queued marker, old enough
# (475min, mirroring ga-lwi4b's own fixture) to trip stalled_by_age UNLESS
# reviewer_alive is correctly detected — exercised through check_gate()'s real,
# unmodified calls to _sh(["tail", ...]) and _sh([GC, "session", "list"]).
import datetime as _dt30xi3
_ts_3min_ago_30xi3 = _dt30xi3.datetime.fromtimestamp(m.NOW - 180).strftime("%Y-%m-%d %H:%M:%S")

def _fake_run_gate_e2e_30xi3(args, **kwargs):
    if kwargs.get("errors") != "replace":
        raise UnicodeDecodeError("utf-8", b"\xe2\x80", 0, 2, "invalid continuation byte")
    if args and args[0] == "tail":
        return types.SimpleNamespace(
            returncode=0, stdout="[%s] Gate PASSED: fix/x merged\n" % _ts_3min_ago_30xi3)
    # `gc session list` table: one line truncated mid multi-byte char (the measured
    # shape — wa-mgnkf's title cut after "\xe2\x80"), one clean live gate-reviewer.
    return types.SimpleNamespace(
        returncode=0,
        stdout=("ga-wisp-oxvuvra  wa-worker      active  wa-mgnkf: Broken capture �\n"
                "ga-wisp-gnh6j4n  gate-reviewer  active  10m  1s ago\n"))

_orig_bd_json_30xi3, _orig_age_min_30xi3 = m._bd_json, m._age_min
m._bd_json = lambda root, label, status="open", include_infra=False: (
    [{"id": "mk-Q30xi3", "updated_at": "2020-01-01T00:00:00Z", "labels": ["gate-status:queued"]}],
    True)
m._age_min = lambda iso: 475.0   # old marker, mirrors ga-lwi4b's exact fixture
m.subprocess.run = _fake_run_gate_e2e_30xi3

_g30xi3 = m.check_gate()
eq("ga-30xi3: truncated-multibyte session title does not blind reviewer_alive (was: False)",
   _g30xi3["reviewer_alive"], True)
eq("ga-30xi3: last_pass_min still reads the real merge, not '—' (was: None)",
   2.5 <= (_g30xi3["last_pass_min"] or -1) <= 3.5, True)
eq("ga-30xi3: 475min-old marker + reviewer alive → NOT falsely declared 'GATE travado'",
   _g30xi3["stalled"], False)

m._bd_json, m._age_min, m.subprocess.run = _orig_bd_json_30xi3, _orig_age_min_30xi3, _orig_run_30xi3
m._sh = _ambient_sh_30xi3

print("── ga-zkxdw DEFEITO 1: _pilot_candidates() parses 'Candidates split' log line ──")
m._sh = _fake_sh_factory(
    "[2026-08-02 21:26:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-02 21:26:00] [pilot-dispatcher] Available slots: small=0  big=2\n"
    "[2026-08-02 21:26:01] [pilot-dispatcher] Candidates split: small=9  big=0\n")
eq("picks the CURRENT sweep's Candidates-split line", m._pilot_candidates(m._read_pilot_log_tail()), {"small": 9, "big": 0})

m._sh = _fake_sh_factory(
    "[2026-08-02 21:26:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-02 21:26:00] [pilot-dispatcher] Available slots: small=0  big=2\n")
eq("sweep started but no Candidates-split/no-candidates line yet → None", m._pilot_candidates(m._read_pilot_log_tail()), None)

m._sh = _fake_sh_factory("")
eq("empty log → None (candidates)", m._pilot_candidates(m._read_pilot_log_tail()), None)

m._sh = _fake_sh_factory(
    "[2026-08-02 21:26:00] [pilot-dispatcher] Available slots: small=0  big=2\n"
    "[2026-08-02 21:26:01] [pilot-dispatcher] Candidates split: small=9  big=0\n")
eq("no sweep-start marker visible at all → None, not a best-effort read (candidates)",
   m._pilot_candidates(m._read_pilot_log_tail()), None)

eq("_pilot_candidates(None) — no snapshot at all → None (pure-function contract, no I/O)",
   m._pilot_candidates(None), None)

print("── ga-zkxdw DEFEITO 1: _pool_saturated() is lane-aware, not just both-lanes-empty ──")
# Cenário A (measured live 2026-08-02 21:26): small=0 big=2 slots, but ALL 9 real
# candidates are lane:small — the free big slots are the WRONG shape for them, so
# this must still read as saturated (healthy backpressure), not a dispatch skip.
eq("Cenário A: small=0/big=2 slots, candidates ALL small (9/0) → saturated",
   m._pool_saturated({"small": 0, "big": 2}, {"small": 9, "big": 0}), True)
# Cenário C: a free small slot exists AND a small candidate wants it → NOT saturated —
# the defeito-1 fix must not overcorrect into hiding a genuine skip.
eq("Cenário C: small=1/big=0 slots, candidates small=1 → NOT saturated (real stall preserved)",
   m._pool_saturated({"small": 1, "big": 0}, {"small": 1, "big": 0}), False)
eq("both lanes literally 0 slots, no candidates data → saturated (ga-wmrr fallback preserved)",
   m._pool_saturated({"small": 0, "big": 0}, None), True)
eq("a lane has room, no candidates data → NOT saturated (fallback, old behavior preserved)",
   m._pool_saturated({"small": 0, "big": 2}, None), False)
eq("no slots data at all → NOT saturated (unknown must never suppress a real stall)",
   m._pool_saturated(None, {"small": 9, "big": 0}), False)

print("── ga-zkxdw attempt 5 GATE-FEEDBACK: _saturation_reason() names WHY pool_saturated is "
      "True — the notes/summary text must never say cheio/saturado unless it actually is ──")
eq("both lanes 0, no candidates data → both_empty",
   m._saturation_reason({"small": 0, "big": 0}, None), "both_empty")
eq("both lanes 0 even WITH unmatched demand present → still both_empty (slots decide this, not candidates)",
   m._saturation_reason({"small": 0, "big": 0}, {"small": 3, "big": 0}), "both_empty")
eq("Cenário A shape (small=0/big=2, candidates all small) → wrong_lane",
   m._saturation_reason({"small": 0, "big": 2}, {"small": 9, "big": 0}), "wrong_lane")
eq("confirmed zero candidates this sweep → zero_candidates regardless of slots",
   m._saturation_reason({"small": 2, "big": 0}, {"small": 0, "big": 0}), "zero_candidates")
eq("overlap (confirmed zero candidates AND both slots 0) → zero_candidates wins: nothing is "
   "waiting explains 0-dispatch on its own",
   m._saturation_reason({"small": 0, "big": 0}, {"small": 0, "big": 0}), "zero_candidates")
eq("not saturated (room + matching demand) → None",
   m._saturation_reason({"small": 1, "big": 0}, {"small": 1, "big": 0}), None)
eq("slots None → None (mirrors _pool_saturated's own `not slots` guard)",
   m._saturation_reason(None, {"small": 1, "big": 0}), None)

eq("_starved_lanes: small starved (small=0 slot, small=9 candidates, big has room but no demand)",
   m._starved_lanes({"small": 0, "big": 2}, {"small": 9, "big": 0}), "small")
eq("_starved_lanes: big starved (mirror case)",
   m._starved_lanes({"small": 2, "big": 0}, {"small": 0, "big": 9}), "big")

_note_a = m._saturation_note("wrong_lane", {"small": 0, "big": 2}, {"small": 9, "big": 0},
                              [{"id": "wa-S0", "rig": "WA"}])
eq("wrong_lane note: no 'chei' substring (cheio/cheios/cheia)", "chei" in _note_a, False)
eq("wrong_lane note: no 'satura' substring (saturado/saturação/...)", "satura" in _note_a, False)
eq("wrong_lane note: names the starved lane computed by _starved_lanes",
   m._starved_lanes({"small": 0, "big": 2}, {"small": 9, "big": 0}) in _note_a, True)

_note_z = m._saturation_note("zero_candidates", {"small": 2, "big": 0}, {"small": 0, "big": 0},
                              [{"id": "ga-STALE", "rig": "HQ"}])
eq("zero_candidates note: no 'chei' substring", "chei" in _note_z, False)
eq("zero_candidates note: no 'satura' substring", "satura" in _note_z, False)
eq("zero_candidates note: says this sweep saw no candidate",
   ("candidato" in _note_z and "sweep" in _note_z), True)

_note_both = m._saturation_note("both_empty", {"small": 0, "big": 0}, None,
                                 [{"id": "wa-X", "rig": "WA"}])
eq("both_empty note: DOES say 'chei' (the one case this claim is true — must not "
   "become a text false-negative)", "chei" in _note_both, True)

_sum_a = m._saturation_summary("wrong_lane", {"small": 0, "big": 2}, {"small": 9, "big": 0})
eq("wrong_lane summary: no chei/satura", ("chei" in _sum_a) or ("satura" in _sum_a), False)
eq("wrong_lane summary: carries the real numbers (0, 2, 9)",
   all(n in _sum_a for n in ("0", "2", "9")), True)
_sum_z = m._saturation_summary("zero_candidates", {"small": 2, "big": 0}, {"small": 0, "big": 0})
eq("zero_candidates summary: no chei/satura", ("chei" in _sum_z) or ("satura" in _sum_z), False)
_sum_both = m._saturation_summary("both_empty", {"small": 0, "big": 0}, None)
eq("both_empty summary: DOES say chei", "chei" in _sum_both, True)

print("── ga-zkxdw DEFEITO 2: _sweep_in_flight() detects an unfinished Pilot sweep ──")
m._sh = _fake_sh_factory(
    "[2026-08-02 21:34:54] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n")
eq("sweep started, no complete line yet → True (in flight)", m._sweep_in_flight(m._read_pilot_log_tail()), True)

m._sh = _fake_sh_factory(
    "[2026-08-02 21:34:54] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-02 21:40:12] [pilot-dispatcher] === Pilot sweep complete: dispatched=6"
    " (small_slots=0 big_slots=2 dolt_saturated_at_start=0) ===\n")
eq("sweep start THEN complete → False (finished)", m._sweep_in_flight(m._read_pilot_log_tail()), False)

m._sh = _fake_sh_factory(
    "[2026-08-02 21:34:54] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-02 21:40:12] [pilot-dispatcher] === Pilot sweep complete: dispatched=6 (...) ===\n"
    "[2026-08-02 21:45:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n")
eq("complete THEN a new start → True (next sweep now in flight)", m._sweep_in_flight(m._read_pilot_log_tail()), True)

m._sh = _fake_sh_factory(
    "[2026-08-02 21:38:00] [pilot-dispatcher] === Pilot sweep complete: dispatched=0"
    " (paused: cota 5h limitada) ===\n")
eq("an early-exit 'sweep complete' variant also counts as finished → False",
   m._sweep_in_flight(m._read_pilot_log_tail()), False)

m._sh = _fake_sh_factory("")
eq("empty log → None (unknown, not False)", m._sweep_in_flight(m._read_pilot_log_tail()), None)

m._sh = lambda args, timeout=20: None
eq("_sh failure → None (unknown)", m._sweep_in_flight(m._read_pilot_log_tail()), None)

eq("_sweep_in_flight(None) — no snapshot at all → None (pure-function contract, no I/O)",
   m._sweep_in_flight(None), None)

print("── ga-zkxdw attempt 4: _sweep_in_flight_elapsed_min() reads the CURRENT sweep's "
      "OWN start timestamp, capped by SWEEP_IN_FLIGHT_BUDGET_MIN in main() ──")
import time as _time4
def _ts_ago(minutes_ago):
    return _time4.strftime("%Y-%m-%d %H:%M:%S", _time4.localtime(m.NOW - minutes_ago * 60))

m._sh = _fake_sh_factory(
    "[%s] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n" % _ts_ago(3))
_elapsed_3 = m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail())
eq("in-flight sweep started ~3min ago -> elapsed ~= 3.0",
   _elapsed_3 is not None and abs(_elapsed_3 - 3.0) < 0.2, True)

m._sh = _fake_sh_factory(
    "[%s] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n" % _ts_ago(45))
_elapsed_45 = m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail())
eq("in-flight sweep started ~45min ago -> elapsed ~= 45.0",
   _elapsed_45 is not None and abs(_elapsed_45 - 45.0) < 0.2, True)

# heartbeat proof: incidental lines AFTER 'start' (the kind that keep
# check_pilot()'s separate 20min liveness heartbeat alive during a stuck
# retry) must NOT reset the elapsed clock — it stays keyed to the sweep's OWN
# start line, never the tail's last line.
m._sh = _fake_sh_factory(
    ("[%s] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n" % _ts_ago(45))
    + "[%s] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n" % _ts_ago(20)
    + "[%s] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n" % _ts_ago(1))
_elapsed_hb = m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail())
eq("incidental heartbeat lines after 'start' don't reset elapsed -> still ~=45min from the START line",
   _elapsed_hb is not None and abs(_elapsed_hb - 45.0) < 0.2, True)

m._sh = _fake_sh_factory(
    "[2026-08-02 21:34:54] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-02 21:40:12] [pilot-dispatcher] === Pilot sweep complete: dispatched=6"
    " (small_slots=0 big_slots=2 dolt_saturated_at_start=0) ===\n")
eq("most recent boundary is 'complete' (not in flight) -> None, nothing to report",
   m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail()), None)

m._sh = _fake_sh_factory(
    "[pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n")   # no leading timestamp
eq("in-flight but 'sweep start' timestamp unparseable -> None (not measured, not 'fresh')",
   m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail()), None)

m._sh = _fake_sh_factory("")
eq("empty log -> None", m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail()), None)

m._sh = lambda args, timeout=20: None
eq("_sh failure -> None", m._sweep_in_flight_elapsed_min(m._read_pilot_log_tail()), None)

eq("_sweep_in_flight_elapsed_min(None) — no snapshot at all -> None (pure-function contract, no I/O)",
   m._sweep_in_flight_elapsed_min(None), None)

print("── main() end-to-end: ga-zkxdw attempt 4 — sweep_in_flight budget cap "
      "(a hung sweep must eventually escalate to ❌, not wait forever) ──")
_e_ca, _e_cg, _e_cp, _e_cd, _e_rigs = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS
_e_sh = m._sh

m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []
m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 1,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-HUNG", "rig": "WA", "title": "room+demand+sweep hung", "lane": "small"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}

# Fixture: sweep started ~3min ago, no complete, matching room+demand -> still
# within budget -> WARN (exit 2), NOT FAIL. This is attempt-2's original,
# intentional behavior — must not regress while fixing the budget gap.
m._sh = _fake_sh_factory(
    ("[%s] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n" % _ts_ago(3))
    + "[%s] [pilot-dispatcher] Available slots: small=1  big=0\n" % _ts_ago(3)
    + "[%s] [pilot-dispatcher] Candidates split: small=1  big=0\n" % _ts_ago(3))
_bufD1 = io.StringIO(); _exitD1 = None
try:
    with contextlib.redirect_stdout(_bufD1):
        m.main()
except SystemExit as e:
    _exitD1 = e.code
eq("sweep in flight ~3min (within budget): exit 2 (INCERTO, not FAIL) — attempt-2 behavior preserved",
   _exitD1, 2)
eq("sweep in flight ~3min: report does NOT say NAO IMPARAVEL", "NÃO IMPARÁVEL" in _bufD1.getvalue(), False)

# Fixture: sweep started ~45min ago, no complete, matching room+demand -> PAST
# budget -> the sweep can no longer justify a wait. This is the test that
# DEFINES the attempt-4 defect (a hung sweep must eventually escalate).
m._sh = _fake_sh_factory(
    ("[%s] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n" % _ts_ago(45))
    + "[%s] [pilot-dispatcher] Available slots: small=1  big=0\n" % _ts_ago(45)
    + "[%s] [pilot-dispatcher] Candidates split: small=1  big=0\n" % _ts_ago(45))
_bufD2 = io.StringIO(); _exitD2 = None
try:
    with contextlib.redirect_stdout(_bufD2):
        m.main()
except SystemExit as e:
    _exitD2 = e.code
eq("sweep in flight ~45min (past budget): exit 1 (FAIL) — the attempt-4 defect fixture",
   _exitD2, 1)
eq("sweep in flight ~45min: report says NAO IMPARAVEL", "NÃO IMPARÁVEL" in _bufD2.getvalue(), True)
eq("sweep in flight ~45min: report explains the elapsed/budget, not silent",
   "orçamento" in _bufD2.getvalue(), True)

# Fixture: sweep hung, but KEEPS emitting incidental heartbeat lines (the kind
# that would keep check_pilot()'s separate 20min liveness heartbeat alive
# indefinitely) — proves the cap is anchored to the sweep's OWN start
# timestamp, not the log's last line.
m._sh = _fake_sh_factory(
    ("[%s] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n" % _ts_ago(45))
    + "[%s] [pilot-dispatcher] Available slots: small=1  big=0\n" % _ts_ago(45)
    + "[%s] [pilot-dispatcher] Candidates split: small=1  big=0\n" % _ts_ago(45)
    + "[%s] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n" % _ts_ago(10)
    + "[%s] [pilot-dispatcher] In-flight: live=6 small=5/5  big=1/2\n" % _ts_ago(1))
_bufD3 = io.StringIO(); _exitD3 = None
try:
    with contextlib.redirect_stdout(_bufD3):
        m.main()
except SystemExit as e:
    _exitD3 = e.code
eq("sweep hung + incidental heartbeat lines keep coming, still past budget: exit 1 (cap doesn't depend on heartbeat)",
   _exitD3, 1)

# Fixture: 'sweep start' timestamp unreadable — NOT MEASURED. Must not
# downgrade forever; falls through to the fail path (with a note explaining why).
m._sh = _fake_sh_factory(
    "[pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[pilot-dispatcher] Available slots: small=1  big=0\n"
    "[pilot-dispatcher] Candidates split: small=1  big=0\n")
_bufD4 = io.StringIO(); _exitD4 = None
try:
    with contextlib.redirect_stdout(_bufD4):
        m.main()
except SystemExit as e:
    _exitD4 = e.code
eq("sweep start timestamp unreadable: exit 1 (does not wait forever on an unmeasured clock)",
   _exitD4, 1)
eq("sweep start timestamp unreadable: report says NAO IMPARAVEL", "NÃO IMPARÁVEL" in _bufD4.getvalue(), True)
eq("sweep start timestamp unreadable: report explains the limitation (not silent)",
   ("ilegível" in _bufD4.getvalue()) or ("não medido" in _bufD4.getvalue()), True)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _e_ca, _e_cg, _e_cp, _e_cd, _e_rigs
m._sh = _e_sh

print("── ga-zkxdw GATE-FEEDBACK (attempt 1 FAIL): _pilot_slots()/_pilot_candidates() "
      "never cross a sweep boundary ──")
# Reviewer's traced regression, confirmed by the Mayor's spec comment: a backward
# scan with no sweep-boundary awareness can pair the CURRENT sweep's slots with an
# OLDER sweep's stale 'Candidates split' line whenever the current sweep hits the
# zero-candidates early exit (pilot-dispatcher.sh ~L4491-4493), which logs
# 'Available slots' (~L3974, unconditional) but skips 'Candidates split' (~L4525)
# entirely. Four fixtures, matching the Mayor's falsifiable acceptance criteria.

# Fixture 1 (Cenário A — the concrete regression traced in the FAIL comment): an
# OLDER sweep logged split=small:0/big:5; the CURRENT sweep logs slots then hits
# the explicit zero-candidates exit. Must read 0/0 (a positive zero), never the
# older sweep's 0/5 — and must NOT silently adopt any other stale sweep's numbers.
m._sh = _fake_sh_factory(
    "[2026-08-03 05:20:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-03 05:20:01] [pilot-dispatcher] Candidates split: small=0  big=5\n"
    "[2026-08-03 05:20:02] [pilot-dispatcher] === Pilot sweep complete: dispatched=0"
    " (small_slots=2 big_slots=0 dolt_saturated_at_start=0) ===\n"
    "[2026-08-03 05:26:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-03 05:26:01] [pilot-dispatcher] Available slots: small=2  big=0\n"
    "[2026-08-03 05:26:02] [pilot-dispatcher] No dispatchable candidates (Tier 1 or Tier 2). Exiting.\n")
eq("Fixture1: current sweep's explicit zero-candidates exit reads 0/0, not the older sweep's split",
   m._pilot_candidates(m._read_pilot_log_tail()), {"small": 0, "big": 0})
eq("Fixture1: slots still read from the CURRENT sweep only", m._pilot_slots(m._read_pilot_log_tail()), {"small": 2, "big": 0})

# Fixture 2 (Cenário B): sweep in flight — has 'start', no 'complete', no
# candidates-related line yet. Must be None (unknown), never an older sweep's
# reading picked up because it was merely the nearest match in the file.
m._sh = _fake_sh_factory(
    "[2026-08-03 05:30:00] [pilot-dispatcher] === Pilot sweep complete: dispatched=6"
    " (small_slots=0 big_slots=2 dolt_saturated_at_start=0) ===\n"
    "[2026-08-03 05:34:54] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n")
eq("Fixture2: sweep in flight, no candidates line yet → None (not the prior sweep's reading)",
   m._pilot_candidates(m._read_pilot_log_tail()), None)
eq("Fixture2: sweep in flight, no slots line yet → None", m._pilot_slots(m._read_pilot_log_tail()), None)

# Fixture 3: log rotated/truncated mid-sweep — no '=== Pilot sweep start' marker
# visible anywhere in the tail window. Must be None, not a partial/best-effort
# read of whatever matching line happens to be in view.
m._sh = _fake_sh_factory(
    "[2026-08-03 05:20:01] [pilot-dispatcher] Candidates split: small=9  big=0\n"
    "[2026-08-03 05:20:05] [pilot-dispatcher] Available slots: small=3  big=1\n")
eq("Fixture3: no sweep-start marker visible at all → None, not a partial read (candidates)",
   m._pilot_candidates(m._read_pilot_log_tail()), None)
eq("Fixture3: no sweep-start marker visible at all → None, not a partial read (slots)",
   m._pilot_slots(m._read_pilot_log_tail()), None)

# Fixture 4 (Mayor's control — must NOT become a false negative): free slot +
# matching candidate + sweep COMPLETE + 0 dispatch, all within the SAME segment.
# The sweep-boundary fix must not swallow a genuine reading.
m._sh = _fake_sh_factory(
    "[2026-08-03 05:40:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-03 05:40:01] [pilot-dispatcher] Available slots: small=1  big=0\n"
    "[2026-08-03 05:40:02] [pilot-dispatcher] Candidates split: small=1  big=0\n"
    "[2026-08-03 05:40:03] [pilot-dispatcher] === Pilot sweep complete: dispatched=0"
    " (small_slots=1 big_slots=0 dolt_saturated_at_start=0) ===\n")
eq("Fixture4 control: matching lane demand still reads through (not swallowed by the fix)",
   m._pilot_candidates(m._read_pilot_log_tail()), {"small": 1, "big": 0})
eq("Fixture4 control: slots still reads through", m._pilot_slots(m._read_pilot_log_tail()), {"small": 1, "big": 0})

print("── main() end-to-end: GATE-FEEDBACK Fixture 1 — confirmed-zero candidates must not "
      "fabricate a stale 9 nor fail ──")
_zz_ca, _zz_cg, _zz_cp, _zz_cd = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt
_zz_slots, _zz_cand, _zz_swf, _zz_rigs = m._pilot_slots, m._pilot_candidates, m._sweep_in_flight, m.RIGS
_zz_read_tail = m._read_pilot_log_tail
m._read_pilot_log_tail = lambda: None   # irrelevant: the 3 signals below are pinned directly
# pilot-dispatchable.json can lag the live sweep by up to ttl*2 (~20min per the
# reviewer's comment), so a snapshot-stuck bead coexisting with a live sweep that
# just read zero real candidates is a realistic, not contrived, combination.
m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 1,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "ga-STALE", "rig": "HQ", "title": "stale-snapshot candidate", "lane": "small"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 5.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []
m._pilot_slots = lambda lines: {"small": 2, "big": 0}
m._pilot_candidates = lambda lines: {"small": 0, "big": 0}   # correctly-segmented read: explicit zero
m._sweep_in_flight = lambda lines: False
_bufZ = io.StringIO()
_exitZ = None
try:
    with contextlib.redirect_stdout(_bufZ):
        m.main()
except SystemExit as e:
    _exitZ = e.code
eq("confirmed-zero candidates this sweep → exit 0, never ❌ (not a fabricated 9)", _exitZ, 0)
eq("confirmed-zero candidates: report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _bufZ.getvalue(), False)
# ga-zkxdw attempt 5 GATE-FEEDBACK: slots here are small=2 big=0 — a lane plainly
# has room — so the report must not claim the pool is full, and must say WHY
# nothing dispatched (this sweep saw zero real candidates), not just "cheio".
eq("REGRESSION GREP: this fixture has a free slot (small=2>0) → no 'chei' anywhere in report",
   "chei" in _bufZ.getvalue(), False)
eq("REGRESSION GREP: this fixture has a free slot (small=2>0) → no 'satura' anywhere in report",
   "satura" in _bufZ.getvalue(), False)
eq("confirmed-zero candidates: report says the Pilot saw no candidate this sweep",
   ("candidato" in _bufZ.getvalue() and "sweep" in _bufZ.getvalue()), True)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt = _zz_ca, _zz_cg, _zz_cp, _zz_cd
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight, m.RIGS = _zz_slots, _zz_cand, _zz_swf, _zz_rigs
m._read_pilot_log_tail = _zz_read_tail

print("── ga-in9ebr: _pool_cap_saturated() reads the POOL-SATURATED marker from the CURRENT sweep only ──")
_pcs_start = "[2026-09-19 12:00:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ==="
_pcs_complete = ("[2026-09-19 12:00:04] [pilot-dispatcher] === Pilot sweep complete: dispatched=0"
                 " (small_slots=2 big_slots=0 dolt_saturated_at_start=0) ===")
_pcs_mark = ("[2026-09-19 12:00:03] [pilot-dispatcher] ga-in9ebr: POOL-SATURATED sweep — dispatched=0 only because"
             " 3 candidate(s) are queued behind full worker capacity (backpressure, not a stall).")
eq("marker inside the current sweep → True",
   m._pool_cap_saturated([_pcs_start, "x", _pcs_mark, _pcs_complete]), True)
eq("current sweep WITHOUT the marker → False",
   m._pool_cap_saturated([_pcs_start, "x", _pcs_complete]), False)
eq("marker only in an OLDER sweep (a later start follows) → False (segment-scoped: no stale reading)",
   m._pool_cap_saturated([_pcs_start, _pcs_mark, _pcs_complete,
                          "[2026-09-19 12:05:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===", "x"]), False)
eq("no snapshot at all → None (unknown, never False)", m._pool_cap_saturated(None), None)
eq("no sweep-start boundary visible → None (unknown, never a positive)",
   m._pool_cap_saturated(["x", _pcs_mark]), None)

print("── main() end-to-end: ga-in9ebr — worker-capacity backpressure is ℹ️/✅, never a false ❌ ──")
_pc_ca, _pc_cg, _pc_cp, _pc_cd = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt
_pc_slots, _pc_cand, _pc_swf, _pc_rigs = m._pilot_slots, m._pilot_candidates, m._sweep_in_flight, m.RIGS
_pc_read_tail, _pc_elapsed = m._read_pilot_log_tail, m._sweep_in_flight_elapsed_min
m.check_approved = lambda: {
    "total": 2, "parked_count": 0, "in_gate_count": 0, "buildable_count": 2,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-QUEUED1", "rig": "WA", "title": "queued behind the worker cap", "lane": "small"},
              {"id": "wa-QUEUED2", "rig": "WA", "title": "queued behind the worker cap", "lane": "small"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []
# A lane HAS room and the sweep's candidates want it → the lane-level _pool_saturated() is False. Before
# ga-in9ebr this exact shape (beads queued behind a full WORKER pool, lanes free) was a false ❌ once the
# Pilot stopped faking those beads as in-flight.
m._pilot_slots = lambda lines: {"small": 2, "big": 0}
m._pilot_candidates = lambda lines: {"small": 3, "big": 0}
m._sweep_in_flight = lambda lines: False
m._sweep_in_flight_elapsed_min = lambda lines: 3.0

def _pc_run(lines):
    m._read_pilot_log_tail = lambda: lines
    buf = io.StringIO(); code = None
    try:
        with contextlib.redirect_stdout(buf):
            m.main()
    except SystemExit as e:
        code = e.code
    return code, buf.getvalue()

_pc_code, _pc_out = _pc_run([_pcs_start, "x", _pcs_mark, _pcs_complete])
eq("marker present → exit 0 (✅ IMPARÁVEL), not ❌", _pc_code, 0)
eq("marker present → report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _pc_out, False)
eq("marker present → the ℹ️ note names WORKER capacity and the queued beads",
   ("pool de workers" in _pc_out and "wa-QUEUED1" in _pc_out), True)
eq("marker present → the recap never claims lane slots are full (they are free)",
   ("Pool cheio" in _pc_out or "slots cheios" in _pc_out), False)
_pc_code2, _pc_out2 = _pc_run([_pcs_start, "x", _pcs_complete])
eq("CONTROL: same fixture WITHOUT the marker → exit 1 (a real stall is still a ❌)", _pc_code2, 1)
eq("CONTROL: the ❌ verdict text is present", "NÃO IMPARÁVEL" in _pc_out2, True)
_pc_code3, _pc_out3 = _pc_run(["x", _pcs_mark])
eq("marker but NO sweep-start boundary (unreadable segment) → does NOT suppress the ❌", _pc_code3, 1)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt = _pc_ca, _pc_cg, _pc_cp, _pc_cd
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight, m.RIGS = _pc_slots, _pc_cand, _pc_swf, _pc_rigs
m._read_pilot_log_tail, m._sweep_in_flight_elapsed_min = _pc_read_tail, _pc_elapsed

print("── main() end-to-end: ga-zkxdw regression — defects 1+2, all 3 falsifiable cenários ──")
_z_ca, _z_cg, _z_cp, _z_cd = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt
_z_slots, _z_cand, _z_swf, _z_rigs = m._pilot_slots, m._pilot_candidates, m._sweep_in_flight, m.RIGS
_z_read_tail = m._read_pilot_log_tail
_z_swf_elapsed = m._sweep_in_flight_elapsed_min
# ga-zkxdw attempt 4: sweep_in_flight alone is no longer sufficient to downgrade
# a FAIL to WARN — main() now also checks elapsed time via
# _sweep_in_flight_elapsed_min(). Pin it to a small in-budget value wherever a
# test pins _sweep_in_flight directly to True (bypassing real log parsing) so
# these cenários keep testing what they originally meant: a NORMAL, healthy
# in-flight sweep well within its usual ~5-6min duration, not an unmeasured one.
m._sweep_in_flight_elapsed_min = lambda lines: 3.0
m._read_pilot_log_tail = lambda: None   # irrelevant: the 3 signals below are pinned directly

m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []

# Cenário A: small=0 big=2, ALL 9 candidates lane:small, sweep already complete.
m.check_approved = lambda: {
    "total": 9, "parked_count": 0, "in_gate_count": 0, "buildable_count": 9,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-S%d" % i, "rig": "WA", "title": "small candidate", "lane": "small"}
              for i in range(9)],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m._pilot_slots = lambda lines: {"small": 0, "big": 2}
m._pilot_candidates = lambda lines: {"small": 9, "big": 0}
m._sweep_in_flight = lambda lines: False
_bufA = io.StringIO()
_exitA = None
try:
    with contextlib.redirect_stdout(_bufA):
        m.main()
except SystemExit as e:
    _exitA = e.code
eq("Cenário A: wrong-shape free slots (small=0/big=2, all-small candidates) → exit 0, not ❌",
   _exitA, 0)
eq("Cenário A: report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _bufA.getvalue(), False)
# ga-zkxdw attempt 5 GATE-FEEDBACK: big=2 is plainly free here — the report must
# not claim the pool is full, and must name the actual wrong-shape lane (small).
eq("REGRESSION GREP: Cenário A has a free slot (big=2>0) → no 'chei' anywhere in report",
   "chei" in _bufA.getvalue(), False)
eq("REGRESSION GREP: Cenário A has a free slot (big=2>0) → no 'satura' anywhere in report",
   "satura" in _bufA.getvalue(), False)
# Precise phrase check (not just "small" anywhere — that substring would also
# trivially match the pre-existing slots/candidates/lane-annotation lines that
# print regardless of this fix): the NEW wrong_lane branch must itself name the
# starved lane via _starved_lanes(), which computes "small" for this fixture.
eq("Cenário A: report's saturation text itself names the wrong lane ('sem vaga pra lane small')",
   "sem vaga pra lane small" in _bufA.getvalue(), True)
eq("Cenário A: report's saturation text says backpressure is about FORMA, not capacity",
   "backpressure de FORMA" in _bufA.getvalue(), True)

# Cenário B: lane is now RIGHT (small=2 free, matches candidates) — defeito 1 alone
# would flag this. Only defeito 2 (sweep still running) can save it.
m._pilot_slots = lambda lines: {"small": 2, "big": 0}
m._pilot_candidates = lambda lines: {"small": 9, "big": 0}
m._sweep_in_flight = lambda lines: True
_bufB = io.StringIO()
_exitB = None
try:
    with contextlib.redirect_stdout(_bufB):
        m.main()
except SystemExit as e:
    _exitB = e.code
eq("Cenário B: sweep still in flight → exit 2 (⚠️ INCERTO), never ❌", _exitB, 2)
eq("Cenário B: report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _bufB.getvalue(), False)

# Cenário C: room + matching demand + sweep COMPLETE + 0 dispatch → the false-negative
# fix from defeito 1/2 must NOT become a false-positive — this must stay ❌.
m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 1,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-REALSTALL", "rig": "WA", "title": "room+demand+sweep done", "lane": "small"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m._pilot_slots = lambda lines: {"small": 1, "big": 0}
m._pilot_candidates = lambda lines: {"small": 1, "big": 0}
m._sweep_in_flight = lambda lines: False
_bufC = io.StringIO()
_exitC = None
try:
    with contextlib.redirect_stdout(_bufC):
        m.main()
except SystemExit as e:
    _exitC = e.code
eq("Cenário C: room+demand+sweep done+0 dispatch → exit 1 (❌ preserved, no regression)",
   _exitC, 1)
eq("Cenário C: report says NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _bufC.getvalue(), True)

# Cenário E (ga-zkxdw attempt 5): BOTH lanes literally 0 free slots — the one
# real case where the report legitimately MUST say the pool is full. Candidates
# carry real demand in both lanes (not the confirmed-zero-candidates shape) so
# this fixture is unambiguously "both_empty", not "zero_candidates" — a false
# NEGATIVE here (never saying "cheio" when it is actually true) would be the
# mirror-image mistake of Cenário A/the zero-candidates fixture.
m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 1,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-BOTHFULL", "rig": "WA", "title": "both lanes full", "lane": "small"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m._pilot_slots = lambda lines: {"small": 0, "big": 0}
m._pilot_candidates = lambda lines: {"small": 5, "big": 3}
m._sweep_in_flight = lambda lines: False
_bufE = io.StringIO()
_exitE = None
try:
    with contextlib.redirect_stdout(_bufE):
        m.main()
except SystemExit as e:
    _exitE = e.code
eq("Cenário E: both lanes literally 0 free slots → exit 0 (healthy backpressure, not ❌)", _exitE, 0)
eq("Cenário E: report DOES say cheio (the one case where this claim is true — a text "
   "false-negative here would be as wrong as Cenário A's false-positive)",
   "chei" in _bufE.getvalue(), True)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt = _z_ca, _z_cg, _z_cp, _z_cd
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight, m.RIGS = _z_slots, _z_cand, _z_swf, _z_rigs
m._read_pilot_log_tail = _z_read_tail
m._sweep_in_flight_elapsed_min = _z_swf_elapsed

print("── ga-zkxdw GATE-FEEDBACK (attempt 2 FAIL): main() reads PILOT_LOG's tail EXACTLY ONCE per "
      "veredito, shares ONE snapshot across slots/candidates/sweep_in_flight ──")
# Reviewer's traced regression (attempt 2): _pilot_slots()/_pilot_candidates() each called
# _current_sweep_lines() independently, and _sweep_in_flight() did its own third independent
# read — three live `tail` subprocess calls racing an actively-appended file. If a sweep
# boundary passed between calls, the three signals could each describe a DIFFERENT sweep and
# get silently combined into one incoherent verdict. The Mayor's spec (attempt 3): read once,
# thread the SAME immutable snapshot into all three. Two falsifiable properties below:
#   (1) instrumentation — the tail-read seam is invoked EXACTLY ONCE per full main() run
#       (today, pre-fix, this would be 3 — one from each of _pilot_slots/_pilot_candidates/
#       _sweep_in_flight; check_pilot()'s separate -n 60 liveness read is a different seam
#       and is not counted here);
#   (2) mutant content — a seam that would hand out DIFFERENT content on a second call proves,
#       by never reaching that branch, that slots/candidates/sweep_in_flight cannot disagree
#       about which sweep is "current".
_i_ca, _i_cg, _i_cp, _i_cd, _i_rigs = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS
_i_orig_slots, _i_orig_cand, _i_orig_swf = m._pilot_slots, m._pilot_candidates, m._sweep_in_flight

m.check_approved = lambda: {
    "total": 0, "parked_count": 0, "in_gate_count": 0, "buildable_count": 0,
    "flowing_count": 0, "held_count": 0, "stuck": [],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []

SWEEP_N = (
    "[2026-08-03 05:20:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-03 05:20:01] [pilot-dispatcher] Available slots: small=1  big=0\n"
    "[2026-08-03 05:20:02] [pilot-dispatcher] Candidates split: small=1  big=0\n"
    "[2026-08-03 05:20:03] [pilot-dispatcher] === Pilot sweep complete: dispatched=0"
    " (small_slots=1 big_slots=0 dolt_saturated_at_start=0) ===\n")
SWEEP_N_ADVANCED = SWEEP_N + (
    "[2026-08-03 05:26:00] [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ===\n"
    "[2026-08-03 05:26:01] [pilot-dispatcher] No dispatchable candidates (Tier 1 or Tier 2). Exiting.\n")

_sh_calls = {"n": 0}
def _counting_mutant_sh(args, timeout=20):
    _sh_calls["n"] += 1
    # A correct fix reads PILOT_LOG's tail once; this fake proves it by only ever handing
    # out sweep N to that single read. If the code under test were to read a SECOND time
    # (the attempt-2 bug), it would observe the log having advanced to sweep N+1 (explicit-
    # zero candidates, early exit) and produce a mixed, incoherent verdict.
    text = SWEEP_N if _sh_calls["n"] == 1 else SWEEP_N_ADVANCED
    return types.SimpleNamespace(returncode=0, stdout=text)
m._sh = _counting_mutant_sh

_captured = {}
def _spy_slots(lines):
    r = _i_orig_slots(lines); _captured["slots"] = r; return r
def _spy_cand(lines):
    r = _i_orig_cand(lines); _captured["candidates"] = r; return r
def _spy_swf(lines):
    r = _i_orig_swf(lines); _captured["sweep_in_flight"] = r; return r
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight = _spy_slots, _spy_cand, _spy_swf

try:
    with contextlib.redirect_stdout(io.StringIO()):
        m.main()
except SystemExit:
    pass

eq("instrumentation: PILOT_LOG tail read EXACTLY ONCE for the whole verdict (today this would be 3)",
   _sh_calls["n"], 1)
eq("mutant content: slots reflect sweep N (the only sweep actually read)",
   _captured.get("slots"), {"small": 1, "big": 0})
eq("mutant content: candidates ALSO reflect sweep N — same snapshot as slots, never sweep N+1's explicit zero",
   _captured.get("candidates"), {"small": 1, "big": 0})
eq("mutant content: sweep_in_flight ALSO reflects sweep N (complete) — same snapshot, not sweep N+1 (in-flight)",
   _captured.get("sweep_in_flight"), False)

print("── ga-26us5 end-to-end: main() must not count a delivery-stalled story:in-flight bead as "
      "building, must name it as awaiting-human, and must not let it alone sustain a ✅ "
      "'producing' claim (AC1/AC3/AC4) ──")

def _if_iso_ago(minutes_ago):
    return _time4.strftime("%Y-%m-%dT%H:%M:%SZ", _time4.gmtime(m.NOW - minutes_ago * 60))

_if_orig_run = m.subprocess.run
_if_calls = []

m.check_approved = lambda: {
    "total": 0, "parked_count": 0, "in_gate_count": 0, "buildable_count": 0,
    "flowing_count": 0, "held_count": 0, "stuck": [],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = [("HQ", "/fake/hq/root")]

# Mixed fixture: one genuinely fresh build, one 4h-stale (the wa-v66xt shape), one with
# unknown age, and one wisp-id (must stay excluded regardless — pre-existing, unrelated
# behavior this fix must not disturb).
_if_mixed_fixture = [
    {"id": "ga-freshb", "updated_at": _if_iso_ago(5)},
    {"id": "ga-stale4h", "updated_at": _if_iso_ago(240)},
    {"id": "ga-noage", "updated_at": None},
    {"id": "ga-wisp-skip", "updated_at": _if_iso_ago(1)},
]
def _if_fake_run_mixed(args, **kwargs):
    _if_calls.append(args)
    return types.SimpleNamespace(returncode=0, stdout=json.dumps(_if_mixed_fixture))
m.subprocess.run = _if_fake_run_mixed

_bufI = io.StringIO()
_exitI = None
try:
    with contextlib.redirect_stdout(_bufI):
        m.main()
except SystemExit as e:
    _exitI = e.code
_outI = _bufI.getvalue()
_if_lines = _outI.split("\n")
_if_building_line = next((l for l in _if_lines if l.startswith("🔨 EM BUILD AGORA")), "")
_if_stalled_line = next((l for l in _if_lines if l.startswith("⏸️")), "")

eq("mixed fixture: nothing else wrong -> exit 0 (✅)", _exitI, 0)
eq("mixed: fresh (5min) bead DOES appear in the building-now line (regression guard — real "
   "progress still detected, not over-corrected)", "ga-freshb" in _if_building_line, True)
eq("mixed: 4h-stale bead does NOT appear in the building-now line (AC1)",
   "ga-stale4h" in _if_building_line, False)
eq("mixed: unknown-age bead does NOT appear in the building-now line (never a free pass)",
   "ga-noage" in _if_building_line, False)
eq("mixed: 4h-stale bead IS named in the awaiting-human line (AC4)",
   "ga-stale4h" in _if_stalled_line, True)
eq("mixed: unknown-age bead IS named in the awaiting-human line too (AC4, treated as stalled)",
   "ga-noage" in _if_stalled_line, True)
eq("mixed: fresh bead is NOT in the awaiting-human line (not misclassified the other way)",
   "ga-freshb" in _if_stalled_line, False)
eq("mixed: the awaiting-human line cites the SAME threshold the watchdog uses (no drift, AC2)",
   ("%.0fh" % m.DELIVERY_STALL_HOURS) in _if_stalled_line, True)
eq("mixed: wisp-id beads stay excluded from BOTH lines (pre-existing behavior, undisturbed)",
   ("ga-wisp-skip" in _if_building_line) or ("ga-wisp-skip" in _if_stalled_line), False)

# Lone-stale fixture: AC3's exact clause — if the ONLY 'in-flight' bead is delivery-stalled,
# it must not alone sustain a ✅ 'the machine IS producing' narrative.
def _if_fake_run_lone(args, **kwargs):
    _if_calls.append(args)
    return types.SimpleNamespace(returncode=0,
                                  stdout=json.dumps([{"id": "ga-lonestale", "updated_at": _if_iso_ago(240)}]))
m.subprocess.run = _if_fake_run_lone

_bufJ = io.StringIO()
_exitJ = None
try:
    with contextlib.redirect_stdout(_bufJ):
        m.main()
except SystemExit as e:
    _exitJ = e.code
_outJ = _bufJ.getvalue()

eq("AC3: lone 4h-stale in-flight bead, nothing else wrong -> still exit 0 (✅)", _exitJ, 0)
eq("AC3: the ✅ narrative must NOT claim the machine is producing off this phantom build",
   "ESTÁ produzindo" in _outJ, False)
eq("AC3: the building-now line must not print at all (building_now == 0, no phantom count)",
   "🔨 EM BUILD AGORA" in _outJ, False)
eq("AC3: the lone stale bead is still named as awaiting-human even as the sole in-flight bead",
   "ga-lonestale" in _outJ, True)

eq("regression guard: the story:in-flight query carries NO --status flag — attempt-1's exact "
   "bug was switching to _bd_json()'s implicit status=\"open\" default, which silently drops "
   "in_progress beads (the NORMAL state of a freshly-dispatched in-flight bead)",
   any("--status" in c for c in _if_calls), False)
eq("regression guard: the query still filters on the right label",
   all(("story:in-flight" in c) for c in _if_calls), True)

m.subprocess.run = _if_orig_run

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _i_ca, _i_cg, _i_cp, _i_cd, _i_rigs
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight = _i_orig_slots, _i_orig_cand, _i_orig_swf

print("── ga-g9o5zm DEFEITO 2: _lane_gap()/_mixed_lane_demand() — mixed lane demand pure "
      "functions (unit) ──")
eq("live incident shape (small=0/big=2 slots, candidatos small=44/big=1): big open, small starved",
   m._lane_gap({"small": 0, "big": 2}, {"small": 44, "big": 1}),
   {"open": ["big"], "starved": ["small"], "idle": []})
eq("live incident shape: _mixed_lane_demand True",
   m._mixed_lane_demand({"small": 0, "big": 2}, {"small": 44, "big": 1}), True)
eq("Cenário A shape (small=0/big=2, candidatos ALL small 9/0): small starved, big idle (not "
   "open) -> gap has no open lane",
   m._lane_gap({"small": 0, "big": 2}, {"small": 9, "big": 0}),
   {"open": [], "starved": ["small"], "idle": ["big"]})
eq("Cenário A: _mixed_lane_demand False (no open lane at all — _pool_saturated already "
   "handles this shape correctly)",
   m._mixed_lane_demand({"small": 0, "big": 2}, {"small": 9, "big": 0}), False)
eq("Cenário C shape (small=1/big=0 slots, candidatos small=1/big=0): small open, big idle",
   m._lane_gap({"small": 1, "big": 0}, {"small": 1, "big": 0}),
   {"open": ["small"], "starved": [], "idle": ["big"]})
eq("Cenário C: _mixed_lane_demand False (no starved lane — a real stall, must not be "
   "downgraded)", m._mixed_lane_demand({"small": 1, "big": 0}, {"small": 1, "big": 0}), False)
eq("Cenário E shape (both lanes 0 slots, candidatos small=5/big=3): both starved, no open",
   m._lane_gap({"small": 0, "big": 0}, {"small": 5, "big": 3}),
   {"open": [], "starved": ["small", "big"], "idle": []})
eq("Cenário E: _mixed_lane_demand False (no open lane — _pool_saturated already handles "
   "both-empty)", m._mixed_lane_demand({"small": 0, "big": 0}, {"small": 5, "big": 3}), False)
eq("unknown slots -> _lane_gap None (fail-open, same convention as _pool_saturated)",
   m._lane_gap(None, {"small": 1, "big": 1}), None)
eq("unknown candidates -> _lane_gap None", m._lane_gap({"small": 1, "big": 1}, None), None)
eq("unknown slots -> _mixed_lane_demand False (never act on an unreadable signal)",
   m._mixed_lane_demand(None, {"small": 1, "big": 1}), False)

_note_g9 = m._mixed_lane_note({"small": 0, "big": 2}, {"small": 44, "big": 1})
eq("_mixed_lane_note names the open lane (big) with its own numbers",
   "big (slots=2 livre, 1 candidato" in _note_g9, True)
eq("_mixed_lane_note names the starved lane (small) with its own numbers",
   "small (0 vaga, 44 candidato" in _note_g9, True)
eq("_mixed_lane_note frames the starved lane as healthy backpressure, not failure",
   "backpressure saudável" in _note_g9, True)

print("── main() end-to-end: ga-g9o5zm — the EXACT live-measured false negative (slots "
      "small=0/big=2, candidatos small=44/big=1, sweep complete) must not read as ❌ NÃO "
      "IMPARÁVEL, and must not carry the false 'act now' imperative ──")
_g9_ca, _g9_cg, _g9_cp, _g9_cd, _g9_rigs = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS
_g9_slots, _g9_cand, _g9_swf = m._pilot_slots, m._pilot_candidates, m._sweep_in_flight
_g9_read_tail = m._read_pilot_log_tail
_g9_run = m.subprocess.run

m.check_approved = lambda: {
    "total": 23, "parked_count": 0, "in_gate_count": 0, "buildable_count": 23,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-S%d" % i, "rig": "WA", "title": "small candidate", "lane": "small"}
              for i in range(22)] + [{"id": "wa-BIG1", "rig": "WA", "title": "big candidate", "lane": "big"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 5.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = [("HQ", "/fake/hq/root")]
m._pilot_slots = lambda lines: {"small": 0, "big": 2}
m._pilot_candidates = lambda lines: {"small": 44, "big": 1}
m._sweep_in_flight = lambda lines: False
m._read_pilot_log_tail = lambda: None

def _g9_fake_run(args, **kwargs):
    return types.SimpleNamespace(returncode=0, stdout=json.dumps(
        [{"id": "ga-building%d" % i,
          "updated_at": _time4.strftime("%Y-%m-%dT%H:%M:%SZ", _time4.gmtime(m.NOW - 1 * 60))}
         for i in range(7)]))
m.subprocess.run = _g9_fake_run

_bufG9 = io.StringIO()
_exitG9 = None
try:
    with contextlib.redirect_stdout(_bufG9):
        m.main()
except SystemExit as e:
    _exitG9 = e.code
_outG9 = _bufG9.getvalue()

eq("ga-g9o5zm repro: exit 2 (⚠️ INCERTO), never ❌ — the reported false negative", _exitG9, 2)
eq("ga-g9o5zm repro: report does NOT say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _outG9, False)
eq("ga-g9o5zm repro: report does NOT carry the false 'act now' imperative",
   "deve agir AGORA" in _outG9, False)
eq("ga-g9o5zm repro: mixed-lane note explains it (MISTURADA)", "MISTURADA" in _outG9, True)
eq("ga-g9o5zm repro: body still shows the real building-now count (7), unaffected",
   "🔨 EM BUILD AGORA (real, todos os stores): 7" in _outG9, True)
eq("ga-g9o5zm repro: the literal '0 em build' phrase never appears (nothing computes it here "
   "any more; superseded by the mixed-lane note)", "0 em build" in _outG9, False)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _g9_ca, _g9_cg, _g9_cp, _g9_cd, _g9_rigs
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight = _g9_slots, _g9_cand, _g9_swf
m._read_pilot_log_tail = _g9_read_tail
m.subprocess.run = _g9_run

print("── main() end-to-end: ga-g9o5zm DEFEITO 1 (AC4) — a genuine, non-mixed real stall "
      "must still say NÃO IMPARÁVEL, and must cite the REAL building-now count instead of a "
      "hardcoded '0 em build' whenever something else IS building ──")
_g1_ca, _g1_cg, _g1_cp, _g1_cd, _g1_rigs = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS
_g1_slots, _g1_cand, _g1_swf = m._pilot_slots, m._pilot_candidates, m._sweep_in_flight
_g1_read_tail = m._read_pilot_log_tail
_g1_run = m.subprocess.run

# Same shape as the existing Cenário C control (room+demand+sweep done+0 dispatch, a REAL
# stall, no starved lane at all — see the _lane_gap unit test above) — but now with a fresh
# in-flight bead building ELSEWHERE, so building_now=1>0 while this bead is still stuck.
m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 1,
    "flowing_count": 0, "held_count": 0,
    "stuck": [{"id": "wa-REALSTALL2", "rig": "WA", "title": "room+demand+sweep done", "lane": "small"}],
    "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = [("HQ", "/fake/hq/root")]
m._pilot_slots = lambda lines: {"small": 1, "big": 0}
m._pilot_candidates = lambda lines: {"small": 1, "big": 0}
m._sweep_in_flight = lambda lines: False
m._read_pilot_log_tail = lambda: None

def _g1_fake_run(args, **kwargs):
    return types.SimpleNamespace(returncode=0, stdout=json.dumps(
        [{"id": "ga-elsewhere",
          "updated_at": _time4.strftime("%Y-%m-%dT%H:%M:%SZ", _time4.gmtime(m.NOW - 1 * 60))}]))
m.subprocess.run = _g1_fake_run

_bufG1 = io.StringIO()
_exitG1 = None
try:
    with contextlib.redirect_stdout(_bufG1):
        m.main()
except SystemExit as e:
    _exitG1 = e.code
_outG1 = _bufG1.getvalue()

eq("AC4 real-stall control: exit 1 (❌ preserved — a genuine stall must still fail)", _exitG1, 1)
eq("AC4 real-stall control: report DOES say NÃO IMPARÁVEL", "NÃO IMPARÁVEL" in _outG1, True)
eq("AC4 real-stall control: body shows 1 building elsewhere",
   "🔨 EM BUILD AGORA (real, todos os stores): 1" in _outG1, True)
eq("AC4: veredicto does NOT say the contradictory '0 em build' while 1 IS building",
   "0 em build" in _outG1, False)
eq("AC4: veredicto cites the real count instead ('1 em build agora')",
   "1 em build agora" in _outG1, True)

# Control-of-the-control: identical fixture, but with NOTHING building anywhere (RIGS empty)
# — proves the fix doesn't ALWAYS hide '0 em build', only when it would be dishonest to say it.
m.RIGS = []
_bufG1b = io.StringIO()
_exitG1b = None
try:
    with contextlib.redirect_stdout(_bufG1b):
        m.main()
except SystemExit as e:
    _exitG1b = e.code
_outG1b = _bufG1b.getvalue()
eq("control: with nothing building anywhere, '0 em build' legitimately still appears",
   "0 em build" in _outG1b, True)
eq("control: exit 1 unaffected", _exitG1b, 1)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _g1_ca, _g1_cg, _g1_cp, _g1_cd, _g1_rigs
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight = _g1_slots, _g1_cand, _g1_swf
m._read_pilot_log_tail = _g1_read_tail
m.subprocess.run = _g1_run

print("── ga-n47qo: _root_for_bead() must use .beads/routes.jsonl for the id-prefix "
      "fallback, and must NEVER silently guess HQ for an unrouted prefix ──")
_rfb_orig_routes = m._ROUTES

m._ROUTES = {}
eq("store=whatsapp_automation unaffected", m._root_for_bead("x-1", "whatsapp_automation"),
   ("/Users/athos/gt/whatsapp_automation", "WA"))
eq("store=property_scrapers unaffected", m._root_for_bead("x-1", "property_scrapers"),
   ("/Users/athos/gt/property_scrapers", "PS"))
eq("store=hq unaffected", m._root_for_bead("x-1", "hq"), (m.CITY, "HQ"))

print("── ga-n47qo: routes.jsonl-derived prefixes (the actual bug — lx-/gt- previously "
      "fell through to a wrongly-guessed HQ) ──")
m._ROUTES = {"lx": "/Users/athos/gt/lexbh", "gt": "/Users/athos/gt/gastown",
             "ga": m.CITY, "wa": "/Users/athos/gt/whatsapp_automation",
             "ps": "/Users/athos/gt/property_scrapers", "ma": "/Users/athos/gt/marketing",
             "dc": "/Users/athos/gt/deacon"}
eq("lx-dnw (the exact bead from the bug report) resolves to the lexbh store, not HQ",
   m._root_for_bead("lx-dnw"), ("/Users/athos/gt/lexbh", "LX"))
eq("gt-4i3ei (the other exact bead from the bug report) resolves to the gastown store, not HQ",
   m._root_for_bead("gt-4i3ei"), ("/Users/athos/gt/gastown", "GT"))
eq("ma-xxxx (marketing, never hardcoded before) resolves via routes.jsonl",
   m._root_for_bead("ma-xxxx"), ("/Users/athos/gt/marketing", "MA"))
eq("dc-xxxx (deacon, never hardcoded before) resolves via routes.jsonl",
   m._root_for_bead("dc-xxxx"), ("/Users/athos/gt/deacon", "DC"))
eq("ga-xxxx via routes.jsonl still reports rig name HQ (not 'GA') — CITY-rooted stays HQ",
   m._root_for_bead("ga-xxxx"), (m.CITY, "HQ"))
eq("wa-xxxx via routes.jsonl still reports WA (unchanged from the old hardcoded path)",
   m._root_for_bead("wa-xxxx"), ("/Users/athos/gt/whatsapp_automation", "WA"))

print("── ga-n47qo: a prefix with NO route anywhere (not in routes.jsonl, not in the "
      "hardcoded wa-/ps-/ga- fallback) must return (None, None) — NEVER a guessed HQ ──")
eq("totally unknown prefix → (None, None), not (CITY, 'HQ')",
   m._root_for_bead("zz-1234"), (None, None))
eq("empty bead_id → (None, None), not a crash", m._root_for_bead(""), (None, None))

print("── ga-n47qo: when routes.jsonl is unavailable (_ROUTES empty), the OLD hardcoded "
      "wa-/ps-/ga- behavior is preserved as a fallback — but an unknown prefix STILL "
      "must not guess HQ (this is the actual regression: it used to) ──")
m._ROUTES = {}
eq("fallback: wa- still hardcoded to WA", m._root_for_bead("wa-x"), ("/Users/athos/gt/whatsapp_automation", "WA"))
eq("fallback: ps- still hardcoded to PS", m._root_for_bead("ps-x"), ("/Users/athos/gt/property_scrapers", "PS"))
eq("fallback: ga- still hardcoded to HQ (HQ's own prefix, not \"unknown\")", m._root_for_bead("ga-x"), (m.CITY, "HQ"))
eq("THE BUG ITSELF: lx- with no routes.jsonl → (None, None), not the old silent (CITY, 'HQ') guess",
   m._root_for_bead("lx-dnw"), (None, None))
eq("gt- with no routes.jsonl → (None, None), not the old silent (CITY, 'HQ') guess",
   m._root_for_bead("gt-4i3ei"), (None, None))

m._ROUTES = _rfb_orig_routes

print("── ga-n47qo: _load_routes() actually parses .beads/routes.jsonl from disk ──")
import tempfile as _tf_n47qo, os as _os_n47qo, shutil as _shutil_n47qo
_tmpdir_n47qo = _tf_n47qo.mkdtemp()
_os_n47qo.makedirs(_os_n47qo.path.join(_tmpdir_n47qo, ".beads"), exist_ok=True)
with open(_os_n47qo.path.join(_tmpdir_n47qo, ".beads", "routes.jsonl"), "w") as _f_n47qo:
    _f_n47qo.write('{"prefix":"lx","path":"../lexbh"}\n')
    _f_n47qo.write('{"prefix":"ga","path":"."}\n')
    _f_n47qo.write('not even json\n')          # malformed line must not break the good ones
    _f_n47qo.write('{"prefix":"gt","path":"../gastown"}\n')
_loaded_n47qo = m._load_routes(city=_tmpdir_n47qo)
eq("_load_routes resolves 'lx' relative to city", _loaded_n47qo.get("lx"),
   _os_n47qo.path.normpath(_os_n47qo.path.join(_tmpdir_n47qo, "../lexbh")))
eq("_load_routes resolves 'ga' (path '.') to city itself", _loaded_n47qo.get("ga"), _tmpdir_n47qo)
eq("_load_routes resolves 'gt' (after the malformed line) — one bad line doesn't lose the rest",
   _loaded_n47qo.get("gt"), _os_n47qo.path.normpath(_os_n47qo.path.join(_tmpdir_n47qo, "../gastown")))
eq("_load_routes: malformed line produces no extra key", len(_loaded_n47qo), 3)
eq("_load_routes: missing routes.jsonl entirely → {} (fail-open, never a crash)",
   m._load_routes(city=_tf_n47qo.mkdtemp()), {})
_shutil_n47qo.rmtree(_tmpdir_n47qo, ignore_errors=True)

print("── ga-n47qo: check_approved() end-to-end — an unrouted-prefix bead lands in a "
      "distinct no_route bucket, and bd show is NEVER attempted for it ──")
_ca_orig_routes = m._ROUTES
m._ROUTES = {"wa": "/Users/athos/gt/whatsapp_automation"}   # lx/gt intentionally absent
snap3 = {"generated_at": "2999-01-01T00:00:00Z", "ttl_seconds": 600, "count": 2,
         "items": [{"id": "lx-dnw", "store": "", "title": "no known route"},
                   {"id": "wa-OK", "store": "whatsapp_automation", "title": "routed fine"}]}
_fd3, _p3 = tempfile.mkstemp(suffix=".json"); os.write(_fd3, json.dumps(snap3).encode()); os.close(_fd3)
m.DISPATCHABLE_JSON = _p3
m._gate_source_beads = lambda: set()
_bd_show_calls_n47qo = []
def _bd_show_spy_n47qo(root, bid):
    _bd_show_calls_n47qo.append(bid)
    return ["ctx:ready", "exec:auto"]
m._bd_show_labels_text = _bd_show_spy_n47qo
_a3 = m.check_approved()
os.unlink(_p3)
eq("lx-dnw lands in no_route, not read_err", _a3.get("no_route"), ["lx-dnw"])
eq("lx-dnw does NOT appear in read_err (distinct failure mode — no read was even attempted)",
   "lx-dnw" in _a3["read_err"], False)
eq("bd show was called ONLY for the routable bead (wa-OK) — never for the unrouted one",
   _bd_show_calls_n47qo, ["wa-OK"])
eq("the routable bead still classifies normally (stuck)", [s["id"] for s in _a3["stuck"]], ["wa-OK"])
m._ROUTES = _ca_orig_routes

print("── ga-n47qo: main() end-to-end — a no_route bead still yields an honest INCERTO "
      "(never a false ✅, never a crash), with a message naming 'rota' distinctly from "
      "the generic 'bd show falhou' read-error message ──")
_nr_ca, _nr_cg, _nr_cp, _nr_cd, _nr_rigs = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS
_nr_read_tail = m._read_pilot_log_tail
m.check_approved = lambda: {
    "total": 1, "parked_count": 0, "in_gate_count": 0, "buildable_count": 0,
    "flowing_count": 0, "held_count": 0, "stuck": [],
    "read_err": [], "no_route": ["lx-dnw", "gt-4i3ei"], "warns": [],
    "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []
m._read_pilot_log_tail = lambda: None
_bufNR = io.StringIO()
_exitNR = None
try:
    with contextlib.redirect_stdout(_bufNR):
        m.main()
except SystemExit as e:
    _exitNR = e.code
_outNR = _bufNR.getvalue()
eq("no_route beads alone → exit 2 (INCERTO), never ❌ NÃO IMPARÁVEL nor a crash", _exitNR, 2)
eq("report names both unrouted ids", ("lx-dnw" in _outNR) and ("gt-4i3ei" in _outNR), True)
eq("report says 'rota' (distinct from the generic bd-show-failed wording)", "rota" in _outNR, True)
eq("report does NOT claim 'bd show falhou' for these (that would misattribute the cause)",
   "bd show falhou" in _outNR, False)

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _nr_ca, _nr_cg, _nr_cp, _nr_cd, _nr_rigs
m._read_pilot_log_tail = _nr_read_tail

print("── ga-k5gl8hd: main() end-to-end — a queue holding only a waiting lane:kimi bead is ✅, "
      "and the report says why ──")
_km_ca, _km_cg, _km_cp, _km_cd, _km_rigs = m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS
_km_read_tail = m._read_pilot_log_tail
m.check_approved = lambda: {
    "total": 1, "parked_count": 1, "in_gate_count": 0, "kimi_lane_count": 1, "buildable_count": 0,
    "flowing_count": 0, "held_count": 0, "stuck": [],
    "read_err": [], "no_route": [], "warns": [],
    "from_dispatchable": True, "snap_age_min": 1.0,
}
m.check_gate = lambda: {"active": [], "parked": [], "last_pass_min": 1.0,
                         "reviewer_alive": True, "oldest_active_min": None,
                         "stalled": False, "stall_reason": ""}
m.check_pilot = lambda: {"alive": True, "last_sweep_min": 0.5}
m.check_dolt = lambda: {"responsive": True, "latency_ms": 10}
m.RIGS = []
m._read_pilot_log_tail = lambda: None
_bufKM = io.StringIO()
_exitKM = None
try:
    with contextlib.redirect_stdout(_bufKM):
        m.main()
except SystemExit as e:
    _exitKM = e.code
_outKM = _bufKM.getvalue()
eq("only a waiting lane:kimi bead in the queue → exit 0 (✅), not ❌", _exitKM, 0)
eq("report prints the Kimi-lane count (esperando na faixa Kimi: 1)",
   "esperando na faixa Kimi: 1" in _outKM, True)
eq("report does not list it among CONSTRUÍVEIS MAS PARADAS", "CONSTRUÍVEIS MAS PARADAS" in _outKM, False)
m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _km_ca, _km_cg, _km_cp, _km_cd, _km_rigs
m._read_pilot_log_tail = _km_read_tail

print("── ga-7n003iz: hq-mutants do lastro — copia FRESCA do modulo, cada limite, contagem e corte no valor exato ──")
# O modulo `m` acima ja foi remendado por muitos testes (e nem todos devolvem o original); aqui cada caso carrega o
# arquivo de novo, entao nenhum fake antigo vaza. NOWV tem segundos inteiros: "N minutos atras" volta como N exato.
import contextlib, io, json, os, subprocess, sys, tempfile, time, types
import importlib.util as _iu

NOWV = 1760000000.0
_LW = tempfile.mkdtemp(prefix="imp-lastro.")


_KNOBS = ("IMP_STARVE_MIN", "IMP_HELD_LOOP_MAX", "IMP_GATE_STALL_MIN", "IMP_PILOT_DEAD_MIN", "IMP_MAX_CLASSIFY",
          "IMP_SWEEP_BUDGET_MIN", "TSW_DELIVERY_STALL_HOURS")


def _fresh():
    # os limiares nascem de variaveis de ambiente: tira-as so durante a carga, para os valores esperados valerem
    env0 = {k: os.environ.pop(k) for k in _KNOBS if k in os.environ}
    try:
        sp = _iu.spec_from_file_location("imp_lastro", m.__file__)
        f = _iu.module_from_spec(sp)
        sp.loader.exec_module(f)
    finally:
        os.environ.update(env0)
    f.NOW = NOWV
    return f


def _t(name, fn, exp):
    # excecao -> uma linha FAIL com o motivo, nao a queda do selftest inteiro
    try:
        got = fn()
    except Exception as e:
        got = "raised %s: %s" % (type(e).__name__, e)
    eq(name, got, exp)


def _iso(sec_ago):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOWV - sec_ago))


def _logts(sec_ago):
    # os logs do dispatcher/pilot trazem hora LOCAL sem fuso; o modulo faz strptime ingenuo e .timestamp() local
    return time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(NOWV - sec_ago))


def _res(rc=0, out=""):
    return types.SimpleNamespace(returncode=rc, stdout=out)


# ── carga do modulo: a ordem do sys.path e o aviso quando o watchdog nao importa ──
_shadow = tempfile.mkdtemp(prefix="imp-shadow.", dir=_LW)
with open(os.path.join(_shadow, "park_labels.py"), "w") as _fh:
    _fh.write("PARK_LABELS = ('shadow-label',)\n")
_path0, _pl0 = list(sys.path), sys.modules.pop("park_labels", None)
sys.path.insert(0, _shadow)
try:
    _t("sys.path: o diretorio do proprio script vem ANTES de uma entrada anterior (park_labels e o dele, nao o da sombra)",
       lambda: "shadow-label" in _fresh().PARKING_LABELS, False)
finally:
    sys.path[:] = _path0
    sys.modules.pop("park_labels", None)
    if _pl0 is not None:
        sys.modules["park_labels"] = _pl0

_sfl0 = _iu.spec_from_file_location


def _sfl_boom(name, *a, **k):
    if name == "throughput_stall_watchdog":
        raise RuntimeError("x" * 100)
    return _sfl0(name, *a, **k)


_iu.spec_from_file_location = _sfl_boom
try:
    _t("import do watchdog falhou: o aviso leva os 80 primeiros caracteres do erro, nem 79 nem 81",
       lambda: _fresh()._TSW_LOAD_WARN.count("x"), 80)
finally:
    _iu.spec_from_file_location = _sfl0

# ── _sh: o que ele PEDE ao subprocess (texto capturado, errors=replace, 20 s) ──
_kw = []


def _run_faithful(args, **kw):
    _kw.append(kw)
    if not kw.get("capture_output"):
        return types.SimpleNamespace(returncode=0, stdout=None)
    raw = ("caf" + chr(233) + "\n").encode("utf-8")
    return types.SimpleNamespace(returncode=0, stdout=raw.decode("utf-8", kw.get("errors", "strict")) if kw.get("text") else raw)


_run0 = subprocess.run
subprocess.run = _run_faithful
try:
    _sh_r = _fresh()._sh(["x"])
finally:
    subprocess.run = _run0
eq("_sh: stdout capturado e decodificado (str, nao bytes e nao None)", _sh_r.stdout, "caf" + chr(233) + "\n")
eq("_sh: errors=replace e timeout padrao de 20 s", (_kw[0].get("errors"), _kw[0].get("timeout")), ("replace", 20))

# ── _bd_json: saida lida, e os tres estados (lista / vazio / nao consegui ler) ──
def _bdj(r, **kw):
    f = _fresh()
    seen = []
    f._sh = lambda args, timeout=20: (seen.append((args, timeout)) or r)
    return f._bd_json("/root", "lab", **kw), seen, f


_v, _seen, _f = _bdj(_res(0, '[{"id": "a"}]'))
eq("_bd_json: rc 0 e lista JSON -> (lista, True)", _v, ([{"id": "a"}], True))
eq("_bd_json: sem include_infra a consulta NAO leva --include-infra (padrao False)",
   _seen[0][0], [_f.BD, "-C", "/root", "list", "-l", "lab", "--status", "open", "--json", "-n", "200"])
_v, _seen, _f = _bdj(_res(0, "[]"), include_infra=True, status="closed")
eq("_bd_json: include_infra=True acrescenta --include-infra no fim e o status vai na consulta",
   _seen[0][0][-3:], ["-n", "200", "--include-infra"])
eq("_bd_json: status passado vai na consulta", _seen[0][0][6:8], ["--status", "closed"])
eq("_bd_json: envelope {issues: [...]}", _bdj(_res(0, '{"issues": [{"id": "i"}]}'))[0], ([{"id": "i"}], True))
eq("_bd_json: envelope {beads: [...]}", _bdj(_res(0, '{"beads": [{"id": "b"}]}'))[0], ([{"id": "b"}], True))
eq("_bd_json: objeto sem issues/beads -> ([], True)", _bdj(_res(0, "{}"))[0], ([], True))
eq("_bd_json: stdout vazio com rc 0 -> ([], True) (vazio nao e falha)", _bdj(_res(0, ""))[0], ([], True))
eq("_bd_json: comando nao rodou (None) -> (None, False)", _bdj(None)[0], (None, False))
eq("_bd_json: rc 1 mesmo com JSON bom na saida -> (None, False)", _bdj(_res(1, '[{"id": "a"}]'))[0], (None, False))
eq("_bd_json: rc 0 e JSON ilegivel -> (None, False)", _bdj(_res(0, "{nope"))[0], (None, False))

# ── _load_routes: so entradas com prefixo E caminho; linha torta pulada ──
_city = tempfile.mkdtemp(prefix="imp-city.", dir=_LW)
os.makedirs(os.path.join(_city, ".beads"))
with open(os.path.join(_city, ".beads", "routes.jsonl"), "w") as _fh:
    _fh.write('{"prefix": "lx", "path": "../lexbh"}\n\n{"path": "../only-path"}\n{"prefix": "nopath"}\nnot json\n')
eq("_load_routes: so a entrada com prefixo E caminho entra (caminho sem prefixo nao vira chave None)",
   _fresh()._load_routes(_city), {"lx": os.path.normpath(os.path.join(_city, "../lexbh"))})

# ── _bd_show_labels_text ──
def _lt(r):
    f = _fresh()
    seen = []
    f._sh = lambda args, timeout=20: (seen.append((args, timeout)) or r)
    return f._bd_show_labels_text("/root", "ga-1"), seen, f


eq("labels: comando nao rodou -> None", _lt(None)[0], None)
eq("labels: rc 1 mesmo com LABELS na saida -> None", _lt(_res(1, "LABELS: a\n"))[0], None)
_v, _seen, _f = _lt(_res(0, "ga-1 [P2 · DEFERRED]\nLABELS: a, b ,c\n"))
eq("labels: cabecalho com a bolinha + LABELS (aparados) -> status:deferred, a, b, c", _v, ["status:deferred", "a", "b", "c"])
eq("labels: o bd show roda com timeout de 15 s e o argv exato", _seen[0], ([_f.BD, "-C", "/root", "show", "ga-1"], 15))
eq("labels: ' DEFERRED]' sem a bolinha tambem vale", _lt(_res(0, "ga-1 [P2 DEFERRED]\n"))[0], ["status:deferred"])
eq("labels: ' BLOCKED]' sem a bolinha tambem vale", _lt(_res(0, "ga-1 [P2 BLOCKED]\n"))[0], ["status:blocked"])
eq("labels: cabecalho com a bolinha + BLOCKED", _lt(_res(0, "ga-1 [P2 · BLOCKED]\nLABELS: z\n"))[0], ["status:blocked", "z"])
eq("labels: sem linha LABELS -> [] (vazio nao e falha)", _lt(_res(0, "ga-1 [P2 OPEN]\n"))[0], [])

# ── _gate_source_beads ──
def _gsb(markers, ok):
    f = _fresh()
    seen = []
    f._bd_json = lambda root, label, status="open", include_infra=False: (seen.append((root, label, include_infra)) or (markers, ok))
    return f._gate_source_beads(), seen, f


_mk = [{"labels": ["type:quality-gate-marker", "source-bead:ga-1", "source-bead: ga-2 ", "source-bead:"]},
       {"labels": ["source-bead:wa-3", 7]}]
_v, _seen, _f = _gsb(_mk, True)
eq("gate_source_beads: ids dos source-bead:* aparados, label vazio ignorado", _v, {"ga-1", "ga-2", "wa-3"})
eq("gate_source_beads: le os markers do city com include_infra=True", _seen, [(_f.CITY, "type:quality-gate-marker", True)])
eq("gate_source_beads: leitura falhou (ok False) com markers na mao -> conjunto vazio, nunca suprime", _gsb(_mk, False)[0], set())
eq("gate_source_beads: sem markers -> conjunto vazio", _gsb([], True)[0], set())
eq("gate_source_beads: markers None -> conjunto vazio", _gsb(None, True)[0], set())

# ── classify_bead: o teto do held-loop vale mesmo se o vocabulario de parqueio deixar de cobrir pilot:held ──
_f = _fresh()
_f.PARKING_LABELS = ()
_held = ["pilot:held-until:%d" % i for i in range(5)]
eq("classify held-loop: 5 labels com teto 5 -> held (no teto ainda e espera legitima)", _f.classify_bead("b", _held, set()), ("held", ""))
eq("classify held-loop: 6 labels com teto 5 -> stuck held-loop:6x", _f.classify_bead("b", _held + ["pilot:held-until:9"], set()), ("stuck", "held-loop:6x"))
eq("classify held-loop: teto passado por argumento (2): 2 labels held, 3 labels stuck",
   (_f.classify_bead("b", _held[:2], set(), 2), _f.classify_bead("b", _held[:3], set(), 2)), (("held", ""), ("stuck", "held-loop:3x")))

# ── check_approved: o snapshot do Pilot (idade x ttl), o erro de leitura e as contagens ──
def _snap(obj):
    p = os.path.join(_LW, "snap-%d.json" % len(os.listdir(_LW)))
    with open(p, "w") as fh:
        json.dump(obj, fh)
    return p


def _ca(snap, path=None, patch=None):
    f = _fresh()
    f.DISPATCHABLE_JSON = path or _snap(snap)
    f._check_approved_fallback = lambda warns: {"FALLBACK": True, "warns": list(warns)}
    f._gate_source_beads = lambda: set()
    if patch:
        patch(f)
    return f.check_approved()


_STALE = "snapshot dispatchable desatualizado (%s > ttl×2=%dmin) — usando story:approved como fallback"
eq("snapshot de 5 min com ttl 600: fresco, vai pelo caminho dispatchable com idade 5.0",
   (lambda r: (r.get("FALLBACK"), r["from_dispatchable"], r["total"], r["snap_age_min"], r["warns"]))(
       _ca({"generated_at": _iso(300), "ttl_seconds": 600, "items": []})), (None, True, 0, 5.0, []))
eq("snapshot de 25 min com ttl 600 (limite 20): velho -> fallback e o aviso diz 25min e ttl×2=20min",
   _ca({"generated_at": _iso(1500), "ttl_seconds": 600, "items": []}), {"FALLBACK": True, "warns": [_STALE % ("25min", 20)]})
eq("snapshot com idade IGUAL ao limite (20 min) ainda e fresco",
   "FALLBACK" in _ca({"generated_at": _iso(1200), "ttl_seconds": 600, "items": []}), False)
eq("sem ttl_seconds vale o padrao de 600 s: 1201 s de idade passa de 20 min -> fallback",
   "FALLBACK" in _ca({"generated_at": _iso(1201), "items": []}), True)
eq("sem ttl_seconds: 1200 s de idade ainda e fresco",
   "FALLBACK" in _ca({"generated_at": _iso(1200), "items": []}), False)
eq("generated_at ilegivel -> velho por falta de idade: o aviso diz 9999min",
   _ca({"generated_at": "", "ttl_seconds": 600, "items": []}), {"FALLBACK": True, "warns": [_STALE % ("9999min", 20)]})

_longdir = os.path.join(_LW, "d" * 100)
os.makedirs(_longdir)
try:
    open(_longdir)
except Exception as _e:
    _msg = str(_e)
eq("a mensagem de erro do open() passa de 81 caracteres (precondicao do teste de corte)", len(_msg) > 81, True)
eq("snapshot ilegivel: o aviso carrega os 80 primeiros caracteres do erro",
   _ca(None, path=_longdir)["warns"], ["erro ao ler pilot-dispatchable.json (%s) — usando story:approved" % _msg[:80]])
eq("snapshot ausente: aviso proprio e fallback",
   _ca(None, path=os.path.join(_LW, "nao-existe.json"))["warns"], ["~/.gc/pilot-dispatchable.json ausente — usando story:approved como fallback"])


def _items_fixture(f):
    kinds = {"ga-p1": ("parked", "label"), "ga-p2": ("parked", "in-gate"), "ga-p3": ("parked", "kimi-lane"),
             "ga-f": ("flowing", ""), "ga-h": ("held", ""), "ga-s": ("stuck", ""), "ga-l": ("stuck", "held-loop:6x")}
    f.classify_bead = lambda bid, labels, gsb: kinds[bid]
    f._root_for_bead = lambda bid, store: (None, None) if bid == "ga-nr" else ("/root", "HQ")
    f._bd_show_labels_text = lambda root, bid: None if bid == "ga-re" else (["lane:small", "x"] if bid == "ga-s" else [])


_r = _ca({"generated_at": _iso(180), "ttl_seconds": 600, "items": [
    {"id": i, "store": "hq", "title": "t" * 60} for i in ("ga-p1", "ga-p2", "ga-p3", "ga-f", "ga-h", "ga-s", "ga-l", "ga-nr", "ga-re")]},
    patch=_items_fixture)
eq("check_approved: contagens exatas por tipo (parked 3 = label + in-gate + kimi; construiveis 4; flowing 1; held 1)",
   {k: _r[k] for k in ("total", "parked_count", "in_gate_count", "kimi_lane_count", "buildable_count", "flowing_count", "held_count")},
   {"total": 9, "parked_count": 3, "in_gate_count": 1, "kimi_lane_count": 1, "buildable_count": 4, "flowing_count": 1, "held_count": 1})
eq("check_approved: as paradas levam titulo cortado em 55, a faixa (lane:) e o motivo do held-loop",
   _r["stuck"], [{"id": "ga-s", "rig": "HQ", "title": "t" * 55, "lane": "small"},
                 {"id": "ga-l", "rig": "HQ", "title": "t" * 55, "reason": "held-loop:6x"}])
eq("check_approved: sem rota -> no_route; bd show falhou -> read_err (cada um no seu balde)", (_r["no_route"], _r["read_err"]), (["ga-nr"], ["ga-re"]))
_r0 = _ca({"generated_at": _iso(180), "ttl_seconds": 600, "items": [{"id": "ga-p1", "title": None}]}, patch=_items_fixture)
eq("check_approved: so um parked (titulo None, sem quebrar) -> flowing 0, held 0, nenhuma parada, nenhuma construivel",
   (_r0["flowing_count"], _r0["held_count"], _r0["stuck"], _r0["buildable_count"]), (0, 0, [], 0))

# ── _check_approved_fallback ──
def _fb(beads_by_root, rigs, gate=frozenset()):
    f = _fresh()
    f.RIGS = rigs
    f._gate_source_beads = lambda: set(gate)
    f._bd_json = lambda root, label, status="open", include_infra=False: beads_by_root[root]
    return f._check_approved_fallback(["herdado"])


_hdr = lambda i: "pilot:held-until:%d" % i
_HQ = [{"id": "fl", "labels": ["story:in-flight"]}, {"id": "km", "labels": ["lane:kimi"]},
       {"id": "hd", "labels": [_hdr(NOWV + 3600)]}, {"id": "mg", "assignee": "mayor", "labels": []},
       {"id": "nd", "labels": ["story:needs-device"]}, {"id": "mk", "labels": []}, {"id": "gl", "labels": ["gate:reviewing"]}]
_WA = [{"id": "nf", "labels": ["gate:needs-fix", "gate:reviewing"], "updated_at": _iso(45 * 60), "title": "n" * 60},
       {"id": "frs", "labels": [], "updated_at": _iso(5 * 60)},
       {"id": "hl6", "labels": [_hdr(i) for i in range(6)], "title": "h" * 60},
       {"id": "pasth", "labels": [_hdr(NOWV - 10)]},
       {"id": "noage", "labels": []},
       {"id": "edge", "labels": [], "updated_at": _iso(20 * 60)},
       {"id": "old", "labels": [], "updated_at": _iso(61 * 60), "title": "o" * 60}]
_r = _fb({"/hq": (_HQ, True), "/wa": (_WA, True)}, [("HQ", "/hq"), ("WA", "/wa")], gate={"mk"})
eq("fallback: balde por balde (in-flight 1, kimi 1, held 3, mayor 1, fresca 2, no gate 2)",
   _r["_ok_reasons"], {"in-flight": 1, "held": 3, "mayor": 1, "fresh": 2, "in-gate": 2, "kimi-lane": 1})
eq("fallback: totais (14 aprovadas; parked = held 3 + mayor 1 + gate 2 + kimi 1; construiveis = total - paradas - in-flight)",
   {k: _r[k] for k in ("total", "_total_approved", "parked_count", "in_gate_count", "kimi_lane_count", "buildable_count", "flowing_count", "held_count")},
   {"total": 14, "_total_approved": 14, "parked_count": 7, "in_gate_count": 2, "kimi_lane_count": 1, "buildable_count": 10, "flowing_count": 1, "held_count": 3})
eq("fallback: so 3 ficam paradas, na ordem das rigs, com idade em minutos (ou 'idade?') e titulo cortado em 55",
   _r["stuck"], [{"rig": "WA", "id": "nf", "title": "n" * 55, "reason": "45min"},
                 {"rig": "WA", "id": "noage", "title": "", "reason": "idade?"},
                 {"rig": "WA", "id": "old", "title": "o" * 55, "reason": "61min"}])
eq("fallback: marca o caminho como NAO-dispatchable, sem idade de snapshot, e herda os avisos",
   (_r["from_dispatchable"], _r["snap_age_min"], _r["warns"], _r["read_err"]), (False, None, ["herdado"], []))
# Equivalentes que NENHUM caso pega (o lastro continua listando): no fallback, o ramo do teto de held-loop (len(held) > HELD_LOOP_MAX, o titulo, `future` e o
# float(...) > NOW) e codigo morto, porque o `any(l.startswith("pilot:held-until"))` anterior ja deu `continue` em toda bead com esse label e `held` ali e sempre []:
# 034ff3c5c7 28aef54d0b 65d267fb2c 7b6ccba54c 11c28b96bf 103b46b79f 23488fecc2 b5f5119856 ccbe12616b 7b47daf7fe 530e68166d. Mais cb7a532be1 f4d95ae8c3 (os booleanos
# flowing/held do dicionario de `buildable` nunca sao lidos: so len(buildable) sai) e 561c28a6c7 (`>=` atribui o mesmo valor). O caso abaixo prova a premissa do ramo morto.
# EQUIVALENT 034ff3c5c7 28aef54d0b 65d267fb2c 7b6ccba54c 11c28b96bf 103b46b79f 23488fecc2 b5f5119856 ccbe12616b 7b47daf7fe 530e68166d: o ramo do teto de held-loop do fallback e codigo morto: o `any(l.startswith("pilot:held-until"))` anterior ja deu `continue` em toda bead com esse label, e `held` ali e sempre []
# EQUIVALENT cb7a532be1 f4d95ae8c3: os booleanos flowing/held do dicionario de `buildable` nunca sao lidos: so len(buildable) sai
# EQUIVALENT 561c28a6c7: `age > oldest_active_min` -> `>=`: no empate atribui o mesmo valor
eq("fallback: qualquer pilot:held-until:* (6 labels, passado ou futuro) e held, nunca parada - o ramo do teto de held-loop fica atras deste",
   [b["id"] for b in _r["stuck"] if b["id"] in ("hl6", "pasth", "hd")], [])
_r = _fb({"/hq": ([], True)}, [("HQ", "/hq")])
eq("fallback sem nenhuma aprovada: tudo zero (total, baldes, in-flight)",
   (_r["total"], _r["flowing_count"], _r["buildable_count"], _r["_ok_reasons"]),
   (0, 0, 0, {"in-flight": 0, "held": 0, "mayor": 0, "fresh": 0, "in-gate": 0, "kimi-lane": 0}))
_r = _fb({"/hq": (None, False)}, [("HQ", "/hq")])
eq("fallback com loja ilegivel: aviso por loja e nada contado como 'sem aprovadas'",
   (_r["warns"], _r["total"]), (["herdado", "não consegui ler story:approved de: HQ (Dolt/bd)"], 0))

# ── check_gate ──
def _cg(markers, ok=True, tail=None, gc=None):
    f = _fresh()
    seen = []
    f._bd_json = lambda root, label, status="open", include_infra=False: (seen.append((root, label, include_infra)) or (markers, ok))

    def sh(args, timeout=20):
        if args[0] == "tail":
            return None if tail is None else _res(0, tail)
        return None if gc is None else _res(0, gc)

    f._sh = sh
    return f.check_gate(), seen, f


_v, _seen, _f = _cg(None, ok=False)
eq("check_gate: marker ilegivel -> {read_err: True} (e a leitura pede include_infra=True do city)", (_v, _seen), ({"read_err": True}, [(_f.CITY, "type:quality-gate-marker", True)]))
_M = [{"id": "m1", "labels": ["gate-status:queued"], "updated_at": _iso(1800)},
      {"id": "m2", "labels": ["gate-status:dispatching"], "updated_at": _iso(300)},
      {"id": "m3", "labels": ["gate-status:needs-rebase"]}, {"id": "m4", "labels": ["gate-status:error"]},
      {"id": "m5", "labels": ["gate-status:passed"]}]
_PASS = lambda sec: _logts(sec) + " [qgd] Gate PASSED: ga-x\n"
_v = _cg(_M, tail=_PASS(60), gc="gate-reviewer-1  active\n")[0]
eq("check_gate: ativos (queued+dispatching), parked (needs-rebase+error), o mais antigo e o ultimo merge",
   (_v["active"], _v["parked"], _v["oldest_active_min"], _v["last_pass_min"], _v["reviewer_alive"], _v["stalled"], _v["stall_reason"]),
   (["m1", "m2"], ["m3", "m4"], 30.0, 1.0, True, False, ""))
eq("check_gate: o mais antigo vence mesmo quando o jovem vem primeiro",
   _cg(list(reversed(_M[:2])), tail=_PASS(60), gc="")[0]["oldest_active_min"], 30.0)
eq("check_gate: marker sem idade legivel convive com um de idade (a idade que existe vence)",
   _cg([{"id": "a", "labels": ["gate-status:queued"], "updated_at": _iso(600)},
        {"id": "b", "labels": ["gate-status:queued"]}], tail=_PASS(60), gc="")[0]["oldest_active_min"], 10.0)
eq("check_gate: so-needs-rebase e so-error, cada um sozinho, vao para parked",
   _cg([{"id": "r", "labels": ["gate-status:needs-rebase"]}, {"id": "e", "labels": ["gate-status:error"]}], tail=_PASS(60), gc="")[0]["parked"], ["r", "e"])

for _gc, _alive in (("foo active\nbar awake\n", False), ("gate-reviewer-1 asleep\n", False), ("gate-reviewer-1 awake\n", True),
                    ("x\ngate-reviewer-2 active\n", True), ("", False), (None, False)):
    eq("reviewer vivo? %r -> %s" % (_gc, _alive), _cg(_M, tail=_PASS(60), gc=_gc)[0]["reviewer_alive"], _alive)

def _stall(active_sec, pass_sec, gc=""):
    mk = [] if active_sec is None else [{"id": "q", "labels": ["gate-status:queued"], "updated_at": _iso(active_sec)}]
    v = _cg(mk, tail=None if pass_sec is None else _PASS(pass_sec), gc=gc)[0]
    return (v["stalled"], v["stall_reason"])


_H = 165 * 60
eq("stall por idade: marker de 166 min, merge recente, sem reviewer -> travado, motivo cita 166min",
   _stall(166 * 60, 60), (True, "marker preso há 166min (reviewer pode estar congelado)"))
eq("stall por idade: marker de EXATOS 165 min nao e travado", _stall(_H, 60), (False, ""))
eq("stall por idade: com reviewer vivo nao e travado", _stall(200 * 60, 60, gc="gate-reviewer-1 active\n"), (False, ""))
eq("stall por silencio: 1 marker novo, nenhum merge no log, sem reviewer -> travado", _stall(60, None), (True, "0 merge na janela + nenhum reviewer vivo"))
eq("stall por silencio: ultimo merge ha EXATOS 165 min nao e travado", _stall(60, _H), (False, ""))
eq("stall por silencio: ultimo merge ha 166 min -> travado", _stall(60, _H + 60), (True, "0 merge na janela + nenhum reviewer vivo"))
eq("stall por silencio: merge recente -> nao travado", _stall(60, 60), (False, ""))
eq("stall por silencio: nenhum marker ativo nao e travamento, mesmo sem merge", _stall(None, None), (False, ""))
eq("stall por silencio: com reviewer vivo nao e travado", _stall(60, None, gc="gate-reviewer-1 awake\n"), (False, ""))
eq("check_gate: tail do log que nao rodou (None) -> last_pass_min None, sem quebrar", _cg(_M, tail=None, gc="")[0]["last_pass_min"], None)

# ── check_pilot / check_dolt ──
def _cp(tail):
    f = _fresh()
    f._sh = lambda args, timeout=20: None if tail is None else _res(0, tail)
    return f.check_pilot()


eq("check_pilot: log que nao veio -> {alive: None}", _cp(None), {"alive": None})
eq("check_pilot: log vazio -> {alive: None}", _cp(""), {"alive": None})
eq("check_pilot: ultima linha com hora ha 5 min -> vivo", _cp("x\n" + _logts(300) + " sweep\n"), {"alive": True, "last_sweep_min": 5.0})
eq("check_pilot: ha EXATOS 20 min -> nao vivo (limite)", _cp(_logts(1200) + " sweep\n"), {"alive": False, "last_sweep_min": 20.0})
eq("check_pilot: ha 19 min -> vivo", _cp(_logts(19 * 60) + " sweep\n")["alive"], True)
eq("check_pilot: ha 21 min -> morto", _cp(_logts(21 * 60) + " sweep\n")["alive"], False)
eq("check_pilot: texto sem nenhuma hora -> morto com last_sweep_min None", _cp("sem hora nenhuma\n"), {"alive": False, "last_sweep_min": None})


def _cd(r, ticks=(100.0, 101.0)):
    f = _fresh()
    seen = []
    f._sh = lambda args, timeout=20: (seen.append((args, timeout)) or r)
    it = iter(ticks)
    t0 = time.time
    time.time = lambda: next(it)
    try:
        return f.check_dolt(), seen, f
    finally:
        time.time = t0


_v, _seen, _f = _cd(_res(0, "[]"))
eq("check_dolt: rc 0 -> responde, latencia 1000 ms para 1 s (milissegundos, nao 1001)", _v, {"responsive": True, "latency_ms": 1000})
eq("check_dolt: o bd list roda com timeout de 15 s e o argv exato", _seen, [([_f.BD, "-C", _f.CITY, "list", "-n", "1", "--json"], 15)])
eq("check_dolt: rc 1 -> nao responde", _cd(_res(1, "[]"))[0]["responsive"], False)
eq("check_dolt: rc 2 -> nao responde", _cd(_res(2, "[]"))[0]["responsive"], False)
eq("check_dolt: comando que nao rodou -> nao responde", _cd(None)[0]["responsive"], False)

# ── auxiliares de saturacao: cada fronteira de vaga/candidato ──
_f = _fresh()
_S = lambda s, b: {"small": s, "big": b}
eq("_pool_saturated: big com 1 vaga e 3 candidatos pode despachar -> nao saturado", _f._pool_saturated(_S(0, 1), _S(0, 3)), False)
eq("_pool_saturated: sem candidatos conhecidos, small=0 big=1 -> nao saturado (1 vaga basta)", _f._pool_saturated(_S(0, 1), None), False)
eq("_pool_saturated: sem candidatos conhecidos, as duas lanes em 0 -> saturado", _f._pool_saturated(_S(0, 0), None), True)
eq("_saturation_reason: small=1 big=0, candidatos so de big -> wrong_lane", _f._saturation_reason(_S(1, 0), _S(0, 2)), "wrong_lane")
eq("_saturation_reason: small=0 big=1, candidatos so de small -> wrong_lane", _f._saturation_reason(_S(0, 1), _S(2, 0)), "wrong_lane")
eq("_saturation_reason: as duas lanes sem vaga -> both_empty", _f._saturation_reason(_S(0, 0), _S(2, 2)), "both_empty")
eq("_saturation_reason: zero candidatos nas duas lanes -> zero_candidates", _f._saturation_reason(_S(1, 1), _S(0, 0)), "zero_candidates")
eq("_saturation_reason: pool nao saturado -> None", _f._saturation_reason(_S(1, 1), _S(1, 1)), None)
eq("_starved_lanes: so small tem candidato sem vaga (big com 0 vagas mas 0 candidatos nao conta)", _f._starved_lanes(_S(0, 0), _S(3, 0)), "small")
eq("_starved_lanes: small com 1 vaga nao esta faltando -> '?'", _f._starved_lanes(_S(1, 0), _S(3, 0)), "?")
eq("_starved_lanes: 1 candidato basta para a lane contar", _f._starved_lanes(_S(0, 2), _S(1, 0)), "small")
eq("_starved_lanes: as duas faltando", _f._starved_lanes(_S(0, 0), _S(2, 5)), "small/big")
_stk7 = [{"rig": "HQ", "id": "s%d" % i} for i in range(1, 8)]
_six = ", ".join("HQ/s%d" % i for i in range(1, 7))
_n = _f._pool_cap_note(_stk7)
eq("_pool_cap_note: conta 7 mas lista so os 6 primeiros", (" 7 construível(is)" in _n, _six in _n, "HQ/s7" in _n), (True, True, False))
_n = _f._saturation_note("both_empty", _S(0, 0), _S(2, 2), _stk7)
eq("_saturation_note: conta 7 mas lista so os 6 primeiros", (" 7 construível(is)" in _n, _six in _n, "HQ/s7" in _n), (True, True, False))

# ── main(): o relatorio inteiro, com os check_* trocados por resultados conhecidos ──
_G_OK = {"active": [], "parked": [], "last_pass_min": 5.0, "reviewer_alive": True, "oldest_active_min": None, "stalled": False, "stall_reason": ""}
_P_OK = {"alive": True, "last_sweep_min": 1.0}
_D_OK = {"responsive": True, "latency_ms": 10}


def _A(**kw):
    a = {"total": 3, "parked_count": 0, "buildable_count": 0, "flowing_count": 0, "held_count": 0, "stuck": [],
         "read_err": [], "warns": [], "from_dispatchable": True, "snap_age_min": 3.0}
    a.update(kw)
    return a


def _stuck(n, **extra):
    return [dict({"rig": "HQ", "id": "s%d" % i}, **extra) for i in range(1, n + 1)]


def _main(a, g=None, p=None, d=None, log=None, rows=None):
    f = _fresh()
    f.check_approved = lambda: a
    f.check_gate = lambda: g or _G_OK
    f.check_pilot = lambda: p or _P_OK
    f.check_dolt = lambda: d or _D_OK
    f.RIGS = [("HQ", "/hq")]
    f._read_pilot_log_tail = lambda: log
    runs = []

    def fake_run(args, **kw):
        runs.append((args, kw))
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(rows or []))

    buf, code, run0 = io.StringIO(), None, subprocess.run
    subprocess.run = fake_run
    try:
        with contextlib.redirect_stdout(buf):
            try:
                f.main()
            except SystemExit as e:
                code = e.code
    finally:
        subprocess.run = run0
    return code, buf.getvalue(), runs, f


_ids = lambda lo, hi, pre="HQ/s", suf="": ", ".join("%s%d%s" % (pre, i, suf) for i in range(lo, hi + 1))
_c, _o, _runs, _f = _main(_A(stuck=_stuck(9, lane="small"), buildable_count=9, total=9))
eq("main: 9 construiveis paradas e nada em build -> exit 1; a falha lista as 6 primeiras",
   (_c, "9 bead(s) CONSTRUÍVEIS na fila do Pilot, 0 em build (pilot vivo): " + _ids(1, 6) + "\n" in _o), (1, True))
eq("main: a linha das paradas lista as 8 primeiras, cada uma com a sua lane",
   "CONSTRUÍVEIS MAS PARADAS (9): " + _ids(1, 8, suf="(lane:small)") + "\n" in _o, True)
eq("main: sem in_gate_count/kimi_lane_count no resultado, a linha de parked imprime 0 e 0",
   "(já-construídas-no-gate: 0, esperando na faixa Kimi: 0)" in _o, True)
eq("main: o cabecalho da fila cita a idade do snapshot (3min atras)", "dispatchable — snapshot 3min atrás): 9 total" in _o, True)
eq("main: a consulta de in-flight pede texto capturado, 15 s e o argv do store",
   _runs, [([_f.BD, "-C", "/hq", "list", "-l", "story:in-flight", "--json"], {"capture_output": True, "text": True, "timeout": 15})])
_c, _o, _, _ = _main(_A(stuck=_stuck(2), buildable_count=2, in_gate_count=2, kimi_lane_count=4, snap_age_min=None))
eq("main: in_gate_count 2 e kimi_lane_count 4 aparecem; sem snapshot o cabecalho nao tem nota de idade",
   ("(já-construídas-no-gate: 2, esperando na faixa Kimi: 4)" in _o, "FILA DO PILOT (dispatchable): 3 total" in _o), (True, True))

_c, _o, _, _ = _main(_A(from_dispatchable=False, total=7, buildable_count=7, stuck=_stuck(7, reason="30min"), snap_age_min=None))
eq("main (fallback): 7 aprovadas paradas -> exit 1; a falha lista as 6 primeiras com o motivo de cada uma",
   (_c, "7 bead(s) APROVADA(s) parada(s) em silêncio (pilot vivo, fallback story:approved): " + _ids(1, 6, suf=" (30min)") + "\n" in _o), (1, True))
eq("main (fallback): sem _ok_reasons todos os baldes imprimem 0",
   "em build agora (in-flight): 0   • held: 0   • mayor-reservada: 0   • recém-despachada: 0   • esperando na faixa Kimi: 0\n" in _o, True)
eq("main (fallback): o total vem de total quando _total_approved falta", "APROVADAS (fallback story:approved — snapshot indisponível): 7 total" in _o, True)

_H = _fresh().DELIVERY_STALL_HOURS
_rows = ([{"id": "r%d" % i, "updated_at": _iso(300)} for i in range(1, 10)]
         + [{"id": "t%d" % i, "updated_at": _iso((_H * 60 + 120) * 60)} for i in range(1, 9)]
         + [{"id": "edge", "updated_at": _iso((_H * 60 + 1) * 60)}, {"id": "x-wisp-1", "updated_at": _iso(60)}])
_c, _o, _, _ = _main(_A(parked_count=3), rows=_rows)
eq("main: 9 em build (lista as 8 primeiras) e 9 parados (8 primeiros; o de +1 min do limite conta como parado)",
   ("EM BUILD AGORA (real, todos os stores): 9 — " + _ids(1, 8, "HQ/r") + "\n" in _o,
    "9 in-flight mas parado(s) > %.0fh sem atualização → aguardando humano, não building: %s\n" % (_H, _ids(1, 8, "HQ/t")) in _o),
   (True, True))
eq("main: ✅ com build ativo: 'Construindo 9 agora' lista 6 ids e a fila parqueada diz que ha build acima",
   (_c, "Construindo 9 agora (" + _ids(1, 6, "HQ/r") + ") — a máquina ESTÁ produzindo, não ociosa.\n" in _o,
    "fila dispatchable parqueada (mas há build ativo acima) (3 parked)." in _o), (0, True, True))
_c, _o, _, _ = _main(_A(parked_count=3))
eq("main: fila so de parked e nenhum build -> 'ocioso correto (3 parked)'", (_c, "→ ocioso correto (3 parked)." in _o), (0, True))
_c, _o, _, _ = _main(_A(parked_count=1))
eq("main: 1 parked e 0 construiveis (parked > 0 no limite) ja cai no texto da fila parqueada", "→ ocioso correto (1 parked)." in _o, True)
for _name, _kw in (("0 construiveis e 0 parked", {}), ("2 construiveis e 3 parked", {"buildable_count": 2, "parked_count": 3}),
                   ("fallback com 0 construiveis e 3 parked", {"from_dispatchable": False, "parked_count": 3})):
    _c, _o, _, _ = _main(_A(**_kw))
    eq("main ✅ %s: texto generico, sem 'Fila inflada'" % _name,
       (_c, "Nenhuma construível parada em silêncio; gate fluindo" in _o, "Fila inflada" in _o), (0, True, False))

for _g, _want in (({"active": ["m1"], "oldest_active_min": 30.4}, "GATE: 1 ativo(s) na fila (mais antigo na fila: 30 min), 0 parked"),
                  ({"active": ["m1"], "oldest_active_min": None}, "GATE: 1 ativo(s) na fila (mais antigo na fila: ? min), 0 parked"),
                  ({"active": []}, "GATE: 0 ativo(s) na fila, 0 parked"),
                  ({"active": [], "last_pass_min": None}, "último merge —")):
    _c, _o, _, _ = _main(_A(), g=dict(_G_OK, **_g))
    eq("main: linha do GATE %r" % (_g,), _want in _o, True)

_c, _o, _, _ = _main(_A(read_err=["r%d" % i for i in range(1, 10)], no_route=["n%d" % i for i in range(1, 10)]))
eq("main: 9 bd show falhos e 9 sem rota -> exit 2 (INCERTO) com 8 ids em cada aviso",
   (_c, "não consegui classificar 9 bead(s) (bd show falhou): " + _ids(1, 8, "r") + "\n" in _o,
    "9 bead(s) com prefixo sem rota conhecida (fora de .beads/routes.jsonl e do fallback fixo wa-/ps-/ga-): "
    + _ids(1, 8, "n") + "\n" in _o), (2, True, True))

_stuck7 = _A(stuck=_stuck(7), buildable_count=7)
for _mins, _code, _frag in ((5, 2, "sweep do Pilot AINDA EM VOO há 5min (dentro do orçamento de 15min) — aguardando conclusão antes de julgar stall: " + _ids(1, 6) + "\n"),
                            (15, 2, "sweep do Pilot AINDA EM VOO há 15min (dentro do orçamento de 15min) — aguardando conclusão antes de julgar stall: " + _ids(1, 6) + "\n"),
                            (16, 1, "(pilot vivo) [sweep em voo há 16min, acima do orçamento de 15min — tratando como stall, não espera]: " + _ids(1, 6) + "\n")):
    _c, _o, _, _ = _main(_stuck7, log=[_logts(_mins * 60) + " [pilot-dispatcher] === Pilot sweep start (DRY_RUN=0) ==="])
    eq("main: sweep em voo ha %d min com 7 paradas -> exit %d e o aviso lista 6 ids" % (_mins, _code), (_c, _frag in _o), (_code, True))

import shutil
shutil.rmtree(_LW, ignore_errors=True)   # os arquivos do bloco acima nao sobram no TMPDIR

print()
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
