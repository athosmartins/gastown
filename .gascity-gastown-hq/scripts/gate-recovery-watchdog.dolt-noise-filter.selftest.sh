#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-rwpwz8 regression only.
#
# BUG: dolt_instability() counted ANY DOLT_SIG match in the last 200KB of
# supervisor.log, with NO time bound. DOLT_SIG included "provider-health
# registry unavailable" — a benign line the session reconciler writes on EVERY
# cycle ("...for \"claude-headless\"; treating as green"), not a Dolt symptom.
# Measured live 2026-09-14: an alarm fired on 87 "instability" matches — 100%
# of them this one benign line, zero real signal (connection reset / bead store
# closed / unexpected EOF / invalid connection: all zero). The runbook then
# unconditionally blamed Dolt and prescribed `gc dolt restart` as a repair step,
# and spawn_repair_agent() handed that runbook to an AUTONOMOUS dog with no
# human in the loop — restarting Dolt would have dropped the city's whole data
# plane without fixing the real (unrelated) causes that day: an aborted
# reviewer spawn and a reviewer killed by the reconciler under load.
#
# FIX: (1) drop the noise phrase from DOLT_SIG so it can never count as a real
# signal; (2) count matches within a recent TIME window (DOLT_INSTABILITY_
# WINDOW_SEC, default 30min), parsed from supervisor.log's own Go-stdlib
# timestamp prefix ("2026/09/14 13:55:39 ..."), not the raw 200KB byte tail
# (which can span hours and mix a stale incident with right now); (3)
# repair_runbook()'s default (kind="gate") branch only blames Dolt / prescribes
# the restart ladder when the real count crosses DOLT_INSTABILITY_MIN_HITS —
# below that it states the measured number and points first at the dispatcher
# log (spawn_err / YIELDED / still in flight); (4) spawn_repair_agent(), for
# kind=="gate" specifically, does not spawn or pool-route an autonomous dog
# when evidence is insufficient — it creates an unrouted audit bead (no
# --assignee, so no gc.routed_to; labeled pilot:no-auto-dispatch) and wakes the
# Mayor instead, so a human judgment call replaces a reflexive Dolt restart.
#
# These scenarios drive dolt_instability(), repair_runbook(), and
# spawn_repair_agent() against synthetic fixtures — no live Dolt, no live
# supervisor.log, no gc/bd (sh() is mocked throughout).
#
# NOT a general test harness for this file — scoped narrowly to this one bug,
# same convention as gate-recovery-watchdog.stuck-dispatching-dead-regex.selftest.sh.
#
# Run: bash scripts/gate-recovery-watchdog.dolt-noise-filter.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" <<'PY'
import importlib.util, sys, time, os, tempfile, json

spec = importlib.util.spec_from_file_location("grw", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

for sym in ("DOLT_SIG", "DOLT_INSTABILITY_WINDOW_SEC", "DOLT_INSTABILITY_MIN_HITS",
            "dolt_instability", "repair_runbook", "spawn_repair_agent",
            "_create_unrouted_audit_bead"):
    if not hasattr(m, sym):
        print("FATAL: %s not found — has ga-rwpwz8 landed?" % sym, file=sys.stderr)
        sys.exit(2)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

NOW = time.time()

def sup_ts(secs_ago):
    return time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(NOW - secs_ago))

NOISE = 'session reconciler: provider-health registry unavailable for "claude-headless"; treating as green'

def noise_line(secs_ago, timestamped=True):
    return ("%s %s\n" % (sup_ts(secs_ago), NOISE)) if timestamped else (NOISE + "\n")

def real_line(phrase, secs_ago, timestamped=True):
    msg = "session reconciler: %s talking to dolt" % phrase
    return ("%s %s\n" % (sup_ts(secs_ago), msg)) if timestamped else (msg + "\n")

def with_supervisor_log(lines):
    """Write `lines` to a REAL temp file and point m.SUPERVISOR_LOG at it for the
    duration of the `with` body, restoring afterward — mirrors how the sibling
    dead-regex selftest swaps m.DISPATCH_LOG."""
    fd, path = tempfile.mkstemp(prefix="grw-supervisor-log-")
    with os.fdopen(fd, "w") as f:
        f.writelines(lines)
    return path

def dolt_hits_for(lines):
    path = with_supervisor_log(lines)
    orig = m.SUPERVISOR_LOG
    m.SUPERVISOR_LOG = path
    try:
        return m.dolt_instability()
    finally:
        m.SUPERVISOR_LOG = orig
        os.unlink(path)

# ── Scenario AC1: the exact reported incident shape — 87 noise lines, 0 real ──────────
lines = [noise_line(secs_ago=i) for i in range(87)]
hits = dolt_hits_for(lines)
if hits == 0:
    ok("ga-rwpwz8 AC1: 87x benign 'provider-health registry unavailable' lines (the exact "
       "measured incident shape), zero real signal → count 0, not 87")
else:
    bad("ga-rwpwz8 AC1 REGRESSION: noise-only tail still counts as Dolt instability: %r" % (hits,))

# ── Scenario A: noise-only, larger volume, still 0 ─────────────────────────────────────
lines = [noise_line(secs_ago=(i % 300)) for i in range(200)]
hits = dolt_hits_for(lines)
if hits == 0:
    ok("200x noise lines spread across 5min, all recent (would ALL be in-window if they "
       "counted) → still 0: the exclusion is the pattern fix, not a time-window accident")
else:
    bad("noise lines counted despite being removed from DOLT_SIG: %r" % (hits,))

# ── Scenario B: real recent signals count, cross the threshold ─────────────────────────
lines = ([noise_line(secs_ago=i) for i in range(50)]
         + [real_line("invalid connection", secs_ago=30),
            real_line("invalid connection", secs_ago=60),
            real_line("connection reset", secs_ago=90)])
hits = dolt_hits_for(lines)
if hits == 3:
    ok("3 real signal lines (invalid connection x2, connection reset x1) mixed with 50 "
       "noise lines, all recent → counted exactly 3 (noise excluded, real signal intact)")
else:
    bad("expected 3 real hits, got %r" % (hits,))
if hits >= m.DOLT_INSTABILITY_MIN_HITS:
    ok("3 real recent hits cross DOLT_INSTABILITY_MIN_HITS(%d) — AC2's 'current behavior "
       "continues' precondition holds" % m.DOLT_INSTABILITY_MIN_HITS)
else:
    bad("3 real hits did NOT cross DOLT_INSTABILITY_MIN_HITS(%d) — threshold too high for "
        "the AC2 scenario" % m.DOLT_INSTABILITY_MIN_HITS)

# ── Scenario C: real signal AGES OUT of the time window — the actual "by time, not ────
#    bytes" fix, independent of the noise-phrase fix ───────────────────────────────────
old_secs = m.DOLT_INSTABILITY_WINDOW_SEC + 3600  # well outside the window (+1h margin)
lines = ([real_line("connection reset", secs_ago=old_secs) for _ in range(5)]
         + [noise_line(secs_ago=i) for i in range(10)])  # recent tail, noise only
hits = dolt_hits_for(lines)
if hits == 0:
    ok("5 real 'connection reset' lines from %dmin ago (outside the %dmin window) → aged "
       "out, count 0 — proves counting is TIME-bound, not just a bigger byte tail"
       % (old_secs // 60, m.DOLT_INSTABILITY_WINDOW_SEC // 60))
else:
    bad("stale real signal outside the time window still counted: %r" % (hits,))

# ── Scenario G2: untimestamped REAL signal after a stale timestamp must still count ────
#    — the exact gap named in GATE-FEEDBACK (gate_run=ga-eucmoy): a stale last_ts must
#    not poison a later, currently-happening untimestamped line. Neither noise_line()
#    nor real_line()'s timestamped=False path was exercised by any scenario above.
old_secs = m.DOLT_INSTABILITY_WINDOW_SEC + 3660  # ~91min for the 30min default — well outside
lines = [noise_line(secs_ago=old_secs),                                   # stale, but timestamped
         real_line("invalid connection", secs_ago=0, timestamped=False)]  # untimestamped ≈ "now"
hits = dolt_hits_for(lines)
if hits == 1:
    ok("gate-feedback repro: a stale (91min-ago) timestamped line followed by an "
       "untimestamped real-signal line still counts that line (1), not 0 — a stale "
       "earlier timestamp no longer poisons a later untimestamped line")
else:
    bad("gate-feedback REGRESSION: stale timestamp poisoned a later untimestamped real "
        "line, got hits=%r (expected 1)" % (hits,))

# ── Scenario G3: mirror of G2 — an untimestamped line bounded on BOTH sides by STALE ───
#    timestamps (nothing recent follows it) must still be excluded, proving the fix is
#    bounded rather than a blanket "count every untimestamped line" escape hatch ────────
lines = [real_line("connection reset", secs_ago=old_secs + 120, timestamped=True),
         real_line("connection reset", secs_ago=old_secs, timestamped=False),
         real_line("connection reset", secs_ago=old_secs - 60, timestamped=True)]
hits = dolt_hits_for(lines)
if hits == 0:
    ok("an untimestamped real-signal line bounded on both sides by stale (>91min-old) "
       "timestamps is still excluded (0) — the fix bounds forward to the NEXT timestamp, "
       "it doesn't just count every untimestamped line")
else:
    bad("untimestamped line bounded by two stale timestamps was wrongly counted: %r" % (hits,))

# ── Scenario D: repair_runbook() text branches on the threshold ────────────────────────
below = m.repair_runbook("2 timeouts em 20min", "/tmp/diag-fake.txt", 0, "gate")
if "gc dolt restart" not in below and "Causa-raiz mais provável" not in below:
    ok("AC1 (runbook half): dolt_hits=0 → no 'gc dolt restart' step, no unconditional "
       "Dolt-blame framing in the generated runbook text")
else:
    bad("below-threshold runbook still prescribes the Dolt restart / blames Dolt: contains "
        "'gc dolt restart'=%s contains blame-phrase=%s"
        % ("gc dolt restart" in below, "Causa-raiz mais provável" in below))
if "spawn_err" in below and "YIELDED" in below:
    ok("below-threshold runbook redirects to the dispatcher-log markers named by the bead "
       "(spawn_err, YIELDED, still in flight)")
else:
    bad("below-threshold runbook doesn't mention the dispatcher-log triage markers")

above = m.repair_runbook("2 timeouts em 20min", "/tmp/diag-fake.txt",
                          m.DOLT_INSTABILITY_MIN_HITS, "gate")
if "gc dolt restart" in above and "Causa-raiz mais provável" in above:
    ok("AC2 (runbook half): dolt_hits==threshold → the ORIGINAL restart-ladder text is "
       "unchanged (current behavior continues when evidence IS present)")
else:
    bad("at-threshold runbook lost the original restart ladder / Dolt-blame framing")

# other kinds' runbooks are untouched by the threshold branch (still take a plain dolt_hits
# positional the way they always did, e.g. supervisor's config-detail slot)
sup_rb = m.repair_runbook("init failure #3", "/tmp/diag-fake.txt", "site.toml: rig X sem path",
                           "supervisor")
if "site.toml: rig X sem path" in sup_rb and "NÃO presuma Dolt" not in sup_rb:
    ok("kind='supervisor' runbook still threads its own (non-Dolt-hits) 4th-arg value through "
       "unchanged, and never takes the new gate-only low-evidence branch — the threshold "
       "branch is scoped to kind=='gate' only")
else:
    bad("kind='supervisor' runbook text looks broken after the gate-kind-only change: %r"
        % (sup_rb[:300],))

# ── Fake sh() dispatcher for spawn_repair_agent() scenarios ────────────────────────────
class FakeCompleted:
    def __init__(self, returncode, stdout):
        self.returncode = returncode
        self.stdout = stdout

def make_fake_sh(calls, mayor_id="mayor-sess-1", audit_bead_id="ga-audit-fake1",
                  direct_session_name="dog-fake1", direct_ok=True, bd_create_ok=True,
                  mayor_present=True):
    def fake_sh(args, timeout=20, stdin=None):
        calls.append(list(args))
        a = list(args)
        if a[:3] == ["gc", "session", "list"]:
            sessions = ([{"id": mayor_id, "template": "gastown.mayor", "closed": False}]
                        if mayor_present else [])
            return FakeCompleted(0, json.dumps({"sessions": sessions}))
        if a[:3] == ["gc", "session", "wake"]:
            return FakeCompleted(0, "")
        if a[:3] == ["gc", "session", "nudge"]:
            return FakeCompleted(0, "")
        if a[:3] == ["gc", "session", "new"]:
            if not direct_ok:
                return FakeCompleted(1, "")
            return FakeCompleted(0, json.dumps({"session_id": "sid-1",
                                                 "session_name": direct_session_name}))
        if a[:3] == ["bd", "-C", m.CITY] and len(a) > 3 and a[3] == "create":
            if not bd_create_ok:
                return FakeCompleted(1, "")
            return FakeCompleted(0, json.dumps([{"id": audit_bead_id}]))
        if a[:3] == ["bd", "-C", m.CITY] and len(a) > 3 and a[3] in ("label", "update"):
            return FakeCompleted(0, "")
        if a[:2] == ["gc", "sling"]:
            return FakeCompleted(0, "")
        return FakeCompleted(0, "")
    return fake_sh

def run_spawn(dolt_hits, kind="gate", **fake_kwargs):
    calls = []
    orig_sh = m.sh
    m.sh = make_fake_sh(calls, **fake_kwargs)
    try:
        how, sid = m.spawn_repair_agent("2 timeouts em 20min", "/tmp/diag-fake.txt",
                                         dolt_hits, kind)
    finally:
        m.sh = orig_sh
    return how, sid, calls

# ── Scenario E: kind='gate', no evidence → no autonomous dog, unrouted audit bead ──────
how, sid, calls = run_spawn(0, kind="gate")
spawned_dog = any(c[:3] == ["gc", "session", "new"] for c in calls)
create_calls = [c for c in calls if c[:4] == ["bd", "-C", m.CITY, "create"]]
label_calls = [c for c in calls if c[:4] == ["bd", "-C", m.CITY, "label"]]
woke_calls = any(c[:3] == ["gc", "session", "wake"] for c in calls)

if not spawned_dog:
    ok("AC3/AC4: dolt_hits=0, kind='gate' → spawn_repair_agent() never calls "
       "`gc session new` — no autonomous dog materialized")
else:
    bad("an autonomous dog WAS spawned (`gc session new` called) despite zero Dolt evidence")

if len(create_calls) == 1 and "--assignee" not in create_calls[0]:
    ok("AC3: exactly one `bd create` call, WITHOUT --assignee — the audit bead is born "
       "unassigned (no gc.routed_to), matching 'nasce sem rota de pool'")
else:
    bad("bd create call shape wrong for an unrouted audit bead: %r" % (create_calls,))

if any(("pilot:no-auto-dispatch" in c) for c in label_calls):
    ok("AC4: the audit bead is labeled pilot:no-auto-dispatch")
else:
    bad("no `bd label add ... pilot:no-auto-dispatch` call found: %r" % (label_calls,))

if woke_calls:
    ok("the Mayor is woken (gc session wake) instead of an autonomous dog")
else:
    bad("Mayor was never woken")

if sid is None:
    ok("no session_id returned — nothing was materialized for the governor ledger to track")
else:
    bad("unexpected session_id returned from the no-evidence path: %r" % (sid,))

if "audit-fake1" in (how or "") or "Mayor" in (how or ""):
    ok("status string documents what happened: %r" % (how,))
else:
    bad("status string doesn't explain the no-dispatch decision: %r" % (how,))

# ── Scenario F: kind='gate', evidence PRESENT → normal autonomous-dog path unchanged ───
how2, sid2, calls2 = run_spawn(m.DOLT_INSTABILITY_MIN_HITS, kind="gate")
spawned_dog2 = any(c[:3] == ["gc", "session", "new"] for c in calls2)
if spawned_dog2 and sid2 == "sid-1":
    ok("AC2: dolt_hits==threshold, kind='gate' → normal _direct() autonomous-dog spawn path "
       "still fires exactly as before this fix")
else:
    bad("at-threshold spawn path regressed: spawned=%s sid=%r" % (spawned_dog2, sid2))

# ── Scenario G: other kinds are NOT gated by dolt_hits — the gate is 'gate'-only ───────
how3, sid3, calls3 = run_spawn(0, kind="pilot")
spawned_dog3 = any(c[:3] == ["gc", "session", "new"] for c in calls3)
if spawned_dog3:
    ok("kind='pilot' with dolt_hits=0 still spawns normally — the no-evidence gate is "
       "scoped to kind=='gate' only, pilot/gate-loop/supervisor/gate-orphan untouched")
else:
    bad("kind='pilot' was unexpectedly blocked by the Dolt-evidence gate meant for 'gate' only")

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
