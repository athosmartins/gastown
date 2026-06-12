#!/usr/bin/env bash
# Selftest for pipeline-throughput-heartbeat.py — anti-flap hysteresis + live-sibling
# guard (ga-vym2m / ga-hwhtt) plus the widened in-flight-review guard.
#
# Imports the real module via importlib (main() is guarded by __name__=='__main__', so
# import does NOT start the loop) and monkeypatches detect / spawn_repair_agent / snapshot
# / notify / session_list so NOTHING live is touched (no gc, bd, git, notify, Dolt).
#
# Test cases:
#   HYSTERESIS (AC1 — slow-but-draining must not spawn):
#     1. single-tick detection → NO spawn (pending 1/2)
#     2. two consecutive detections → exactly ONE spawn
#     3. detect then recover next tick → NO spawn, pending reset (the historical flap)
#     4. replay of the real launchd flap pattern (fire,recover,fire,recover…) → 0 spawns
#   LIVE-SIBLING GUARD (AC2/AC3 — at most 1 repair dog alive, no feedback loop):
#     5. confirmed stall but a tracked repair dog is alive → NO spawn
#     6. confirmed stall but a title-signature repair dog is alive → NO spawn (restart-safe)
#     7. live_repair_dogs ignores closed / non-dog / normal-pool dogs
#     8. spawned id is tracked → next confirmed tick suppressed by the live sibling
#   WIDENED REVIEW GUARD (root false-positive reduction):
#     9. fresh Verdicts poll beyond a 40-line tail still suppresses gate_merge_stall
#    10. partial verdict (G>0) recently received counts as "progressing" (fresh)
#   REGRESSION:
#    11. spawn-route failure → no tracking, no cycle increment (retry next tick)
#    12. detect() still returns the four kinds unchanged (pure, side-effect free)
#
# Exit: 0 = all pass, 1 = any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HB_SCRIPT="${SCRIPT_DIR}/../../../scripts/pipeline-throughput-heartbeat.py"

if [[ ! -f "$HB_SCRIPT" ]]; then
  echo "FAIL: cannot locate pipeline-throughput-heartbeat.py (looked at $HB_SCRIPT)"
  exit 1
fi

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local code="$2"
  local expected="$3"   # exact substring expected in output
  local result
  result=$(HB_SCRIPT="$HB_SCRIPT" python3 -c "$code" 2>&1) || true
  if echo "$result" | grep -qF "$expected"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  expected substring: $expected"
    echo "  got: $result"
    FAIL=$((FAIL + 1))
  fi
}

# Common harness: import the module, neutralise side effects, expose helpers to drive
# run_tick deterministically. detect() is replaced per-test by setting m._FINDINGS (a list
# of (kind,reason) tuples) or m._FINDINGS_SEQ (a list consumed one entry per tick).
HARNESS='
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("hb", os.environ["HB_SCRIPT"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# --- neutralise all live side effects -----------------------------------------
m.SPAWNS = []            # records each (kind, reason) that reached spawn_repair_agent
m.NOTIFIES = []
def _fake_spawn(kind, reason, diag):
    m.SPAWNS.append((kind, reason))
    return getattr(m, "_SPAWN_RETURN", "dog-fake-%d" % len(m.SPAWNS))
m.spawn_repair_agent = _fake_spawn
m.snapshot = lambda kind, reason: "/tmp/diag-fake"
m.notify = lambda msg, prio: m.NOTIFIES.append((prio, msg))
m._SESSIONS = []
m.session_list = lambda: m._SESSIONS

# detect() driver: fixed list, or a per-tick sequence
m._REAL_DETECT = m.detect      # preserve the real implementation for purity regression
m._FINDINGS = []
m._FINDINGS_SEQ = None
def _fake_detect(now, sessions=None):
    if m._FINDINGS_SEQ is not None:
        if m._FINDINGS_SEQ:
            return m._FINDINGS_SEQ.pop(0)
        return []
    return list(m._FINDINGS)
m.detect = _fake_detect

# zero the cooldowns so they never mask a hysteresis/guard decision in tests that are not
# specifically exercising cooldowns (each tick uses a fresh, advancing now).
m.REPAIR_COOLDOWN_SEC = 0
m.GLOBAL_SPAWN_COOLDOWN_SEC = -1
'

# ---------------------------------------------------------------------------
# 1. single-tick detection → NO spawn (pending 1/2)
# ---------------------------------------------------------------------------
run_test "single-tick detection does not spawn (hysteresis)" "
$HARNESS
st = m.new_state(); tracked = set()
m._FINDINGS = [('gate-merge', 'fila não drena')]
m.run_tick(1000.0, st, 0.0, tracked)
print('SPAWNS=%d pending=%d' % (len(m.SPAWNS), st['gate-merge']['pending']))
assert len(m.SPAWNS) == 0, 'should not spawn on first detection'
print('OK_NO_SPAWN')
" "OK_NO_SPAWN"

# ---------------------------------------------------------------------------
# 2. two consecutive detections → exactly ONE spawn
# ---------------------------------------------------------------------------
run_test "two consecutive detections spawn exactly once" "
$HARNESS
st = m.new_state(); tracked = set()
m._FINDINGS = [('gate-merge', 'fila não drena')]
lgs = m.run_tick(1000.0, st, 0.0, tracked)        # pending 1/2 → no spawn
lgs = m.run_tick(1400.0, st, lgs, tracked)        # pending 2/2 → spawn
print('SPAWNS=%d' % len(m.SPAWNS))
assert len(m.SPAWNS) == 1, 'expected exactly one spawn after confirmation'
print('OK_ONE_SPAWN')
" "OK_ONE_SPAWN"

# ---------------------------------------------------------------------------
# 3. detect then recover next tick → NO spawn, pending reset
# ---------------------------------------------------------------------------
run_test "detect then recover → no spawn, pending reset (flap)" "
$HARNESS
st = m.new_state(); tracked = set()
m._FINDINGS_SEQ = [[('gate-merge','x')], []]      # tick1 fire, tick2 clear
m.run_tick(1000.0, st, 0.0, tracked)
m.run_tick(1400.0, st, 0.0, tracked)
print('SPAWNS=%d pending=%d' % (len(m.SPAWNS), st['gate-merge']['pending']))
assert len(m.SPAWNS) == 0
assert st['gate-merge']['pending'] == 0
print('OK_FLAP_SUPPRESSED')
" "OK_FLAP_SUPPRESSED"

# ---------------------------------------------------------------------------
# 4. replay the real launchd flap pattern → 0 spawns
#    (every historical spawn was immediately followed by 'recovered — resetting')
# ---------------------------------------------------------------------------
run_test "historical flap pattern (fire,recover x4) → zero spawns" "
$HARNESS
st = m.new_state(); tracked = set()
m._FINDINGS_SEQ = [
  [('gate-merge','11 markers')], [],
  [('gate-merge','12 markers')], [],
  [('gate-merge','13 markers')], [],
  [('gate-merge','6 markers')],  [],
]
lgs = 0.0
for i in range(8):
    lgs = m.run_tick(1000.0 + i*400, st, lgs, tracked)
print('SPAWNS=%d' % len(m.SPAWNS))
assert len(m.SPAWNS) == 0, 'flapping must never spawn'
print('OK_ZERO_SPAWNS')
" "OK_ZERO_SPAWNS"

# ---------------------------------------------------------------------------
# 5. confirmed stall but a TRACKED repair dog is alive → NO spawn
# ---------------------------------------------------------------------------
run_test "live tracked sibling suppresses spawn (AC2)" "
$HARNESS
st = m.new_state(); tracked = {'dog-prev'}
m._SESSIONS = [{'id':'dog-prev','template':'gastown.dog','state':'active','closed':False,'title':'reparo heartbeat: x'}]
m._FINDINGS = [('gate-merge','fila')]
lgs = m.run_tick(1000.0, st, 0.0, tracked)   # 1/2
lgs = m.run_tick(1400.0, st, lgs, tracked)   # 2/2 confirmed but sibling alive
print('SPAWNS=%d' % len(m.SPAWNS))
assert len(m.SPAWNS) == 0, 'must not spawn while a sibling is alive'
print('OK_SIBLING_SUPPRESS')
" "OK_SIBLING_SUPPRESS"

# ---------------------------------------------------------------------------
# 6. confirmed stall but a TITLE-SIGNATURE repair dog is alive → NO spawn
#    (tracked set empty, e.g. after a process restart — signature still catches it)
# ---------------------------------------------------------------------------
run_test "live title-signature sibling suppresses spawn (restart-safe)" "
$HARNESS
st = m.new_state(); tracked = set()
m._SESSIONS = [{'id':'dog-sig','template':'gastown.dog','state':'active','closed':False,'title':'Reparo Heartbeat: gate-merge'}]
m._FINDINGS = [('gate-merge','fila')]
lgs = m.run_tick(1000.0, st, 0.0, tracked)
lgs = m.run_tick(1400.0, st, lgs, tracked)
print('SPAWNS=%d' % len(m.SPAWNS))
assert len(m.SPAWNS) == 0
print('OK_SIG_SUPPRESS')
" "OK_SIG_SUPPRESS"

# ---------------------------------------------------------------------------
# 7. live_repair_dogs ignores closed / non-dog / normal-pool dogs
# ---------------------------------------------------------------------------
run_test "live_repair_dogs ignores closed/non-dog/normal-pool" "
$HARNESS
sessions = [
  {'id':'a','template':'gastown.dog','state':'active','closed':True,'title':'reparo heartbeat: x'},   # closed
  {'id':'b','template':'gate-reviewer','state':'active','closed':False,'title':'reparo heartbeat: x'},# not a dog
  {'id':'c','template':'gastown.dog','state':'active','closed':False,'title':'gastown.dog-1'},          # normal pool dog
  {'id':'d','template':'gastown.dog','state':'exited','closed':False,'title':'reparo heartbeat: x'},   # dead state
]
live = m.live_repair_dogs(sessions, set())
print('LIVE=%r' % live)
assert live == [], 'none of these should count as a live repair dog'
print('OK_IGNORE')
" "OK_IGNORE"

# ---------------------------------------------------------------------------
# 8. spawned id is tracked → a later confirmed tick is suppressed by it
# ---------------------------------------------------------------------------
run_test "spawned id tracked → suppresses later spawn while alive" "
$HARNESS
st = m.new_state(); tracked = set()
m._SPAWN_RETURN = 'dog-new1'
m._FINDINGS = [('gate-merge','fila')]
lgs = m.run_tick(1000.0, st, 0.0, tracked)   # 1/2
lgs = m.run_tick(1400.0, st, lgs, tracked)   # 2/2 → spawn dog-new1
assert len(m.SPAWNS) == 1, 'first spawn expected'
assert 'dog-new1' in tracked, 'spawned id must be tracked: %r' % tracked
# now that dog reports alive in the session list; a fresh stall must NOT spawn again
m._SESSIONS = [{'id':'dog-new1','template':'gastown.dog','state':'active','closed':False,'title':'reparo heartbeat: x'}]
st2 = m.new_state()
m.run_tick(2000.0, st2, lgs, tracked)
m.run_tick(2400.0, st2, lgs, tracked)
print('TOTAL_SPAWNS=%d' % len(m.SPAWNS))
assert len(m.SPAWNS) == 1, 'second spawn must be suppressed by the live sibling'
print('OK_TRACKED_SUPPRESS')
" "OK_TRACKED_SUPPRESS"

# ---------------------------------------------------------------------------
# 9. fresh Verdicts poll beyond a 40-line tail still suppresses gate_merge_stall
# ---------------------------------------------------------------------------
run_test "widened review guard: fresh verdict beyond 40-line tail suppresses stall" "
$HARNESS
import time
now = 1_000_000.0
def ts(epoch):
    return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(epoch))
# Build a log: a recent in-flight Verdicts poll, then 60 noisy headroom-defer lines after
# it (so the poll is >40 lines from the end), then the latest queued-marker line.
lines = []
lines.append(ts(now-120)+' Verdicts: 1/3 received (elapsed: 300s)\n')   # fresh, partial
for i in range(60):
    lines.append(ts(now-110+i)+' Headroom: deferring run (Dolt hot)\n')
lines.append(ts(now-5)+' Found 6 queued marker(s)\n')
m.tail_lines = lambda path, n: lines[-n:]
m.file_fresh = lambda path, max_age=None, now=None: True
r = m.gate_merge_stall(now)
print('STALL=%r' % r)
assert r is None, 'a fresh in-flight review beyond the 40-line tail must suppress the stall'
print('OK_WIDE_SCAN')
" "OK_WIDE_SCAN"

# ---------------------------------------------------------------------------
# 10. partial verdict (G>0) with large elapsed still counts as progressing (fresh)
# ---------------------------------------------------------------------------
run_test "partial verdict G>0 with large elapsed = progressing (not stall)" "
$HARNESS
import time
now = 1_000_000.0
def ts(epoch):
    return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(epoch))
# elapsed 4000s > REVIEW_FRESH_SEC(2700) but 2/3 verdicts already in → run is draining.
lines = [
  ts(now-120)+' Verdicts: 2/3 received (elapsed: 4000s)\n',
  ts(now-5)+' Found 3 queued marker(s)\n',
]
m.tail_lines = lambda path, n: lines[-n:]
m.file_fresh = lambda path, max_age=None, now=None: True
r = m.gate_merge_stall(now)
print('STALL=%r' % r)
assert r is None, 'partial verdicts received → progressing, not a stall'
print('OK_PARTIAL_PROGRESS')
" "OK_PARTIAL_PROGRESS"

# ---------------------------------------------------------------------------
# 11. spawn-route failure → no tracking, no cycle increment (retry next tick)
# ---------------------------------------------------------------------------
run_test "spawn route failure → not tracked, cycles not incremented" "
$HARNESS
st = m.new_state(); tracked = set()
m._SPAWN_RETURN = None      # spawn_repair_agent reports routing failed
m.spawn_repair_agent = lambda k, r, d: None
m._FINDINGS = [('gate-merge','fila')]
lgs = m.run_tick(1000.0, st, 0.0, tracked)
lgs = m.run_tick(1400.0, st, lgs, tracked)   # confirmed, attempts spawn, fails
print('tracked=%r cycles=%d' % (tracked, st['gate-merge']['cycles']))
assert tracked == set(), 'failed spawn must not be tracked'
assert st['gate-merge']['cycles'] == 0, 'failed spawn must not count a cycle'
print('OK_SPAWN_FAIL')
" "OK_SPAWN_FAIL"

# ---------------------------------------------------------------------------
# 12. detect() still returns the four kinds, pure / side-effect free (regression)
# ---------------------------------------------------------------------------
run_test "detect() pure, returns the four kinds when each check fires" "
$HARNESS
m.pilot_dispatch_stall = lambda now: 'pilot reason'
m.gate_merge_stall = lambda now: 'gate reason'
m.durable_landing_fail = lambda now: 'durable reason'
m.rotting_sessions = lambda now, self_name=None, sessions=None: [('lbl','nm',9000)]
out = m._REAL_DETECT(1000.0, [])
kinds = [k for k, _ in out]
print('KINDS=%r' % kinds)
assert kinds == ['pilot','gate-merge','durable','session-rot'], kinds
print('OK_DETECT_PURE')
" "OK_DETECT_PURE"

# ---------------------------------------------------------------------------
# 13. HEADROOM-DEFER suppression (ga-r1u20): a fresh 'Headroom DEFER' as the gate's most
#     recent decision means it is DELIBERATELY throttling reviews (ga-cw4pm) to protect
#     Dolt — no Verdicts polls is EXPECTED, not a stall. gate_merge_stall must return None.
# ---------------------------------------------------------------------------
run_test "headroom DEFER (deliberate ga-cw4pm throttle) suppresses gate_merge_stall" "
$HARNESS
import time
now = 1_000_000.0
def ts(epoch):
    return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(epoch))
# No Gate PASSED in window, backlog>0, no in-flight Verdicts — WITHOUT the fix this is a
# stall. The latest headroom decision is a fresh DEFER (dolt-hot, ceiling=0) → throttled.
lines = [
  ts(now-200)+' Headroom DEFER: gate em 1 runs (Dolt cpu=237% lat=64ms / cota=ok) — dolt-hot; ceiling=0 reviewers, leaving 3 marker(s) queued (ga-cw4pm).\n',
  ts(now-100)+' Found 3 queued marker(s)\n',
]
m.tail_lines = lambda path, n: lines[-n:]
m.file_fresh = lambda path, max_age=None, now=None: True
r = m.gate_merge_stall(now)
print('STALL=%r' % r)
assert r is None, 'a fresh Headroom DEFER (intentional throttle) must NOT be flagged as a stall'
print('OK_DEFER_SUPPRESS')
" "OK_DEFER_SUPPRESS"

# ---------------------------------------------------------------------------
# 14. NEGATIVE CONTROL (ga-r1u20): after the gate RECOVERS to 'Headroom OK' (resumed
#     admitting runs) a continuing no-merge IS a real stall — the DEFER suppression must
#     not mask it. The most recent decision is OK, so gate_merge_stall must still fire.
# ---------------------------------------------------------------------------
run_test "headroom recovered to OK → genuine no-merge stall still fires (no masking)" "
$HARNESS
import time
now = 1_000_000.0
def ts(epoch):
    return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(epoch))
lines = [
  ts(now-400)+' Headroom DEFER: gate em 1 runs (Dolt cpu=237% lat=64ms / cota=ok) — dolt-hot; ceiling=0 reviewers, leaving 3 marker(s) queued (ga-cw4pm).\n',
  ts(now-200)+' Headroom OK: gate em 0 runs (Dolt cpu=24% lat=40ms / cota=ok) — dolt-calm; ceiling=6 reviewers, admitting a new run (ga-cw4pm).\n',
  ts(now-100)+' Found 3 queued marker(s)\n',
]
m.tail_lines = lambda path, n: lines[-n:]
m.file_fresh = lambda path, max_age=None, now=None: True
r = m.gate_merge_stall(now)
print('STALL=%r' % r)
assert r is not None, 'after recovery to Headroom OK, a real no-merge stall must still be detected'
print('OK_RECOVERED_STILL_FIRES')
" "OK_RECOVERED_STILL_FIRES"

# ---------------------------------------------------------------------------
echo "----------------------------------------"
echo "pipeline-throughput-heartbeat selftest: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
