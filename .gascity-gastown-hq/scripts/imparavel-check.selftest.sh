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

print("── ga-lwi4b regression: check_gate()'s stalled_by_age must respect reviewer_alive ──")
# batista's measured incident (04:17): a queued marker sat 475min (> GATE_STALL_MIN=165)
# purely from queue congestion (24 in the fila) while gate-reviewer was ACTIVE and
# reviewing it that instant. stalled_by_age used to ignore reviewer_alive (only
# stalled_by_silence consulted it), so age alone declared a false GATE travado.
_orig_bd_json, _orig_age_min, _orig_sh_gate = m._bd_json, m._age_min, m._sh
m._bd_json = lambda root, label, status="open": (
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

m.check_approved, m.check_gate, m.check_pilot, m.check_dolt, m.RIGS = _i_ca, _i_cg, _i_cp, _i_cd, _i_rigs
m._pilot_slots, m._pilot_candidates, m._sweep_in_flight = _i_orig_slots, _i_orig_cand, _i_orig_swf

print()
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
