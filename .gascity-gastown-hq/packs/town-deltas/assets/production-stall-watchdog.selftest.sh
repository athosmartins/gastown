#!/usr/bin/env bash
# Selftest for production-stall-watchdog.py — anti-flap hysteresis + per-dimension
# cooldown + fail-safe detection. Mirrors pipeline-throughput-heartbeat.selftest.sh.
#
# Imports the real module via importlib (main() is guarded by __name__=='__main__', so
# import does NOT start the loop) and monkeypatches sh / escalate_mayor / notify_athos /
# the dimension checks so NOTHING live is touched (no git, bd, gc, mail, notify, Dolt).
#
# Test cases:
#   HYSTERESIS:
#     1. single-tick detection → NO escalation (pending 1/2)
#     2. two consecutive detections → exactly ONE escalation
#     3. detect then recover → NO escalation, pending reset (flap suppressed)
#     4. replay flap pattern (fire,recover x4) → ZERO escalations
#   COOLDOWN:
#     5. confirmed + escalated, then re-confirmed within cooldown → suppressed (1 total)
#   FAIL-SAFE DETECTION (the heart of "never false-alarm a healthy/empty system"):
#     6. deploy_block: clean rig (ahead=0) → None
#     7. deploy_block: rig ahead by N → reason (the 2026-06-18 stall)
#     8. deploy_block: non-repo / fetch+rev-list failure → None (never flags)
#     9. merge_stall: recent merge in window → None
#    10. merge_stall: no merge BUT no demand (0 queued, 0 approved) → None (idle ≠ stall)
#    11. merge_stall: no merge + queued markers pending → reason
#    12. merge_stall: stale dispatcher log → None (dead engine ≠ our job)
#    13. stuck_execution: in_progress bead older than threshold → reason
#    14. stuck_execution: fresh in_progress bead → None
#    15. stuck_execution: bd failure / empty → None
#    15b. stuck_execution: story:awaiting-external-merge label → None (ga-e5tn8)
#    15c. stuck_execution: pilot:no-auto-dispatch label → None (ga-e5tn8)
#    15d. stuck_execution: exclusion is per-bead — excluded bead skipped, a
#         genuinely stuck sibling in the same result set still flags (ga-e5tn8)
#    15e. stuck_execution: in_progress + next-action:athos, 9h → None — the
#         Athos's turn is not an execution stall (ga-teljci, replay of ga-ormexj)
#    15f. stuck_execution: negative control, 9h with no park/turn label → flags
#    15g. stuck_execution: every bead_state.ATHOS_TURN label skipped per-bead,
#         a plain stuck sibling in the same set still flags (ga-teljci)
#    15h. stuck_execution: turn=external skipped by turn alone, turn=mayor not
#    15i. stuck_execution: model unavailable/raising/verdict-less → label fallback
#         preserved (a model with no verdict is "don't know", not "executing")
#   GATE QUEUE (ga-z5311j — in_progress but waiting for review is not a stall):
#    15j. in_progress + gate:queued + OPEN marker, 13h → None (replay of ga-gm5rv5)
#    15k. same bead, lookup answered [] → still flagged (residual label alone silences nothing)
#    15l. lookup FAILS (rc / garbage / empty body / no answer) → labeled bead out of the
#         alarm but called "marker não verificado", unlabeled bead still flagged
#    15m. marker keyed on the SLING bead (pilot.sling_bead) counts for the story (ga-lrglm)
#    15n. waiting bead listed apart, stuck sibling still flagged; waiting-only → None + log
#    15o. HQ git identity test@example.com → "sem dono"; real owners still shown
#    15p. lazy + bounded: no gate query on the healthy path, 2 queries however many stale
#    15q. _gate_active_source_beads classification table (marker vs run, active vs terminal)
#    15r. the 61st open marker is still found (--limit 0, no silent 50-row cut)
#   REGRESSION:
#    16. mail-send failure → not counted, ntfy still fires, retry next tick
#    17. detect() pure, returns the three dimensions when each fires
#    18. parse_bd_json tolerates a trailing non-JSON summary line
#
# Exit: 0 = all pass, 1 = any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD_SCRIPT="${SCRIPT_DIR}/../../../scripts/production-stall-watchdog.py"

if [[ ! -f "$WD_SCRIPT" ]]; then
  echo "FAIL: cannot locate production-stall-watchdog.py (looked at $WD_SCRIPT)"
  exit 1
fi

# ga-9d7it9: every scenario below runs `python3 -c`, whose argv is ['-c'] — the signal
# gc_ledger's selftest guard reads never sees it, so the confirmed-escalation scenarios'
# REAL _ledger("human-touch", ...) rows ("wa ahead=3") were landing in the LIVE ledger.
# Exported here, every python child is positively a test run and gc_ledger diverts its
# writes to a scratch dir (scenario 19 pins that).
export GC_SELFTEST=1

PASS=0
FAIL=0

run_test() {
  local name="$1"; local code="$2"; local expected="$3"
  local result
  result=$(WD_SCRIPT="$WD_SCRIPT" python3 -c "$code" 2>&1) || true
  if echo "$result" | grep -F "$expected" >/dev/null; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name"; echo "  expected substring: $expected"; echo "  got: $result"
    FAIL=$((FAIL + 1))
  fi
}

# Common harness: import module, neutralise side effects, drive run_tick deterministically.
# detect() is replaced per-test via m._FINDINGS (fixed) or m._FINDINGS_SEQ (per-tick).
HARNESS='
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("wd", os.environ["WD_SCRIPT"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.ESCALATIONS = []   # (dimension, reason) that reached escalate_mayor
m.NOTIFIES = []
def _fake_escalate(dim, reason):
    m.ESCALATIONS.append((dim, reason))
    return getattr(m, "_ESCALATE_RETURN", True)
m.escalate_mayor = _fake_escalate
m.notify_athos = lambda msg, prio: m.NOTIFIES.append((prio, msg))

m._REAL_DETECT = m.detect
m._FINDINGS = []
m._FINDINGS_SEQ = None
def _fake_detect(now):
    if m._FINDINGS_SEQ is not None:
        return m._FINDINGS_SEQ.pop(0) if m._FINDINGS_SEQ else []
    return list(m._FINDINGS)
m.detect = _fake_detect
'

# --- 1. single-tick → no escalation ----------------------------------------
run_test "single-tick detection does not escalate (hysteresis)" "
$HARNESS
st = m.new_state()
m._FINDINGS = [('deploy-block','wa ahead=3')]
m.run_tick(1000.0, st)
print('ESC=%d pending=%d' % (len(m.ESCALATIONS), st['deploy-block']['pending']))
assert len(m.ESCALATIONS) == 0
print('OK_NO_ESC')
" "OK_NO_ESC"

# --- 2. two consecutive → exactly one ----------------------------------------
run_test "two consecutive detections escalate exactly once" "
$HARNESS
st = m.new_state()
m._FINDINGS = [('deploy-block','wa ahead=3')]
m.run_tick(1000.0, st)
m.run_tick(2600.0, st)
print('ESC=%d' % len(m.ESCALATIONS))
assert len(m.ESCALATIONS) == 1
print('OK_ONE_ESC')
" "OK_ONE_ESC"

# --- 3. detect then recover → flap suppressed --------------------------------
run_test "detect then recover → no escalation, pending reset (flap)" "
$HARNESS
st = m.new_state()
m._FINDINGS_SEQ = [[('merge-stall','x')], []]
m.run_tick(1000.0, st)
m.run_tick(2600.0, st)
print('ESC=%d pending=%d' % (len(m.ESCALATIONS), st['merge-stall']['pending']))
assert len(m.ESCALATIONS) == 0 and st['merge-stall']['pending'] == 0
print('OK_FLAP')
" "OK_FLAP"

# --- 4. flap pattern x4 → zero -----------------------------------------------
run_test "historical flap pattern (fire,recover x4) → zero escalations" "
$HARNESS
st = m.new_state()
m._FINDINGS_SEQ = [
  [('merge-stall','a')], [], [('merge-stall','b')], [],
  [('merge-stall','c')], [], [('merge-stall','d')], [],
]
for i in range(8):
    m.run_tick(1000.0 + i*1600, st)
print('ESC=%d' % len(m.ESCALATIONS))
assert len(m.ESCALATIONS) == 0
print('OK_ZERO')
" "OK_ZERO"

# --- 5. cooldown suppresses re-escalation ------------------------------------
run_test "per-dimension cooldown suppresses re-escalation while handled" "
$HARNESS
st = m.new_state()
m._FINDINGS = [('deploy-block','wa ahead=3')]
m.run_tick(1000.0, st)            # 1/2
m.run_tick(2600.0, st)            # 2/2 → escalate
m.run_tick(4200.0, st)            # still confirmed but inside 3h cooldown
m.run_tick(5800.0, st)
print('ESC=%d' % len(m.ESCALATIONS))
assert len(m.ESCALATIONS) == 1, 'cooldown must suppress repeats: %d' % len(m.ESCALATIONS)
print('OK_COOLDOWN')
" "OK_COOLDOWN"

# --- 6. deploy_block: clean rig → None ---------------------------------------
run_test "deploy_block: clean rig (ahead=0 behind=0) → None" "
$HARNESS
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0; r.stdout=''
    if '--is-shallow-repository' in args: r.stdout='false\n'
    elif 'rev-parse' in args: r.stdout='true\n'
    elif 'fetch' in args: r.stdout=''
    elif 'rev-list' in args: r.stdout='0\t0\n'
    return r
m.sh = fake_sh
m.RIG_ROOTS = ['/fake/rig']
print('R=%r' % m.deploy_block(1000.0))
assert m.deploy_block(1000.0) is None
print('OK_CLEAN')
" "OK_CLEAN"

# --- 7. deploy_block: ahead by N → reason (the 2026-06-18 stall) -------------
run_test "deploy_block: rig ahead by N unpushed → flagged" "
$HARNESS
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0; r.stdout=''
    if '--is-shallow-repository' in args: r.stdout='false\n'
    elif 'rev-parse' in args: r.stdout='true\n'
    elif 'fetch' in args: r.stdout=''
    elif 'rev-list' in args: r.stdout='0\t3\n'   # behind=0 ahead=3
    return r
m.sh = fake_sh
m.RIG_ROOTS = ['/fake/wa']
r = m.deploy_block(1000.0)
print('R=%r' % r)
assert r is not None and 'AHEAD' in r and '3' in r
print('OK_AHEAD')
" "OK_AHEAD"

# --- 8. deploy_block: non-repo / failed git → None ---------------------------
run_test "deploy_block: non-repo / failed rev-list → None (never false-flags)" "
$HARNESS
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=1; r.stdout=''
    return r
m.sh = fake_sh
m.RIG_ROOTS = ['/not/a/repo']
print('R=%r' % m.deploy_block(1000.0))
assert m.deploy_block(1000.0) is None
print('OK_NONREPO')
" "OK_NONREPO"

# --- 9. merge_stall: recent merge → None -------------------------------------
run_test "merge_stall: recent Gate PASSED in window → None" "
$HARNESS
import time
now=1_000_000.0
def ts(e): return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(e))
lines=[ts(now-300)+' [quality-gate-dispatcher] Gate PASSED: branch=x merge_sha=abc\n',
       ts(now-100)+' [quality-gate-dispatcher] Found 4 queued marker(s)\n']
m.tail_lines=lambda p,n: lines[-n:]
m.file_fresh=lambda p,a,nw: True
print('R=%r' % m.merge_stall(now))
assert m.merge_stall(now) is None
print('OK_RECENT_MERGE')
" "OK_RECENT_MERGE"

# --- 10. merge_stall: no merge but NO demand → None (idle ≠ stall) -----------
run_test "merge_stall: no merge + no demand (0 queued, 0 approved) → None" "
$HARNESS
import time
now=1_000_000.0
def ts(e): return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(e))
lines=[ts(now-99999)+' [quality-gate-dispatcher] Gate PASSED: x\n',
       ts(now-100)+' [quality-gate-dispatcher] Found 0 queued marker(s)\n']
m.tail_lines=lambda p,n: lines[-n:]
m.file_fresh=lambda p,a,nw: True
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0; r.stdout='[]'   # zero approved beads
    return r
m.sh=fake_sh
print('R=%r' % m.merge_stall(now))
assert m.merge_stall(now) is None
print('OK_IDLE_NO_DEMAND')
" "OK_IDLE_NO_DEMAND"

# --- 11. merge_stall: no merge + queued pending → reason ---------------------
run_test "merge_stall: no merge + queued markers pending → flagged" "
$HARNESS
import time
now=1_000_000.0
def ts(e): return time.strftime('[%Y-%m-%d %H:%M:%S]', time.localtime(e))
lines=[ts(now-99999)+' [quality-gate-dispatcher] Gate PASSED: x\n',
       ts(now-100)+' [quality-gate-dispatcher] Found 5 queued marker(s)\n']
m.tail_lines=lambda p,n: lines[-n:]
m.file_fresh=lambda p,a,nw: True
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0; r.stdout='[]'
    return r
m.sh=fake_sh
r=m.merge_stall(now)
print('R=%r' % r)
assert r is not None and '5 marker' in r
print('OK_MERGE_STALL')
" "OK_MERGE_STALL"

# --- 12. merge_stall: stale dispatcher log → None ----------------------------
run_test "merge_stall: stale dispatcher log → None (dead engine ≠ our job)" "
$HARNESS
m.file_fresh=lambda p,a,nw: False
print('R=%r' % m.merge_stall(1_000_000.0))
assert m.merge_stall(1_000_000.0) is None
print('OK_STALE_LOG')
" "OK_STALE_LOG"

# --- 13. stuck_execution: old in_progress bead → reason ----------------------
run_test "stuck_execution: in_progress bead older than threshold → flagged" "
$HARNESS
import time, datetime
old = datetime.datetime.utcfromtimestamp(time.time()-40000).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout='[{\"id\":\"ga-x1\",\"owner\":\"crew/foo\",\"updated_at\":\"'+old+'\"}]'
    return r
m.sh=fake_sh
r=m.stuck_execution(time.time())
print('R=%r' % r)
assert r is not None and 'ga-x1' in r
print('OK_STUCK')
" "OK_STUCK"

# --- 14. stuck_execution: fresh in_progress bead → None ----------------------
run_test "stuck_execution: fresh in_progress bead → None" "
$HARNESS
import time, datetime
fresh = datetime.datetime.utcfromtimestamp(time.time()-60).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout='[{\"id\":\"ga-x2\",\"owner\":\"crew/foo\",\"updated_at\":\"'+fresh+'\"}]'
    return r
m.sh=fake_sh
print('R=%r' % m.stuck_execution(time.time()))
assert m.stuck_execution(time.time()) is None
print('OK_FRESH')
" "OK_FRESH"

# --- 15. stuck_execution: bd failure / empty → None --------------------------
run_test "stuck_execution: bd failure → None (fail-open)" "
$HARNESS
m.sh=lambda args, timeout=20: None
print('R=%r' % m.stuck_execution(1000.0))
assert m.stuck_execution(1000.0) is None
print('OK_BD_FAIL')
" "OK_BD_FAIL"

# --- 15b. stuck_execution: story:awaiting-external-merge → None (ga-e5tn8) ---
run_test "stuck_execution: story:awaiting-external-merge label → None (not stuck)" "
$HARNESS
import time, datetime
old = datetime.datetime.utcfromtimestamp(time.time()-40000).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout='[{\"id\":\"ga-5ksp5\",\"assignee\":\"dog-ga3wack\",\"updated_at\":\"'+old+'\",\"labels\":[\"story:awaiting-external-merge\",\"lane:small\"]}]'
    return r
m.sh=fake_sh
print('R=%r' % m.stuck_execution(time.time()))
assert m.stuck_execution(time.time()) is None
print('OK_EXCLUDE_EXTERNAL_MERGE')
" "OK_EXCLUDE_EXTERNAL_MERGE"

# --- 15c. stuck_execution: pilot:no-auto-dispatch → None (ga-e5tn8) ----------
run_test "stuck_execution: pilot:no-auto-dispatch label → None (not stuck)" "
$HARNESS
import time, datetime
old = datetime.datetime.utcfromtimestamp(time.time()-40000).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout='[{\"id\":\"ga-y1\",\"assignee\":\"crew/foo\",\"updated_at\":\"'+old+'\",\"labels\":[\"pilot:no-auto-dispatch\"]}]'
    return r
m.sh=fake_sh
print('R=%r' % m.stuck_execution(time.time()))
assert m.stuck_execution(time.time()) is None
print('OK_EXCLUDE_NO_AUTO_DISPATCH')
" "OK_EXCLUDE_NO_AUTO_DISPATCH"

# --- 15d. stuck_execution: mixed set — exclusion is per-bead, not global (regression) --
run_test "stuck_execution: excluded bead skipped, plain stuck bead still flagged (regression)" "
$HARNESS
import time, datetime
old = datetime.datetime.utcfromtimestamp(time.time()-40000).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout='[{\"id\":\"ga-excluded\",\"assignee\":\"dog-a\",\"updated_at\":\"'+old+'\",\"labels\":[\"story:awaiting-external-merge\"]},{\"id\":\"ga-realstuck\",\"assignee\":\"dog-b\",\"updated_at\":\"'+old+'\",\"labels\":[\"lane:small\"]}]'
    return r
m.sh=fake_sh
r = m.stuck_execution(time.time())
print('R=%r' % r)
assert r is not None and 'ga-realstuck' in r and 'ga-excluded' not in r
print('OK_MIXED_PER_BEAD')
" "OK_MIXED_PER_BEAD"

# --- 15e. stuck_execution: in_progress that is ATHOS'S TURN → None (ga-teljci) --
# Replay of the live false alarm (04/10 11:56Z, "STALL CONFIRMADO stuck-exec:
# ga-ormexj parado há 8h"): the bead is the Mayor's mission bead waiting for the
# Athos to buy an SSD. bead_state.derive() says awaiting_athos/turn=athos (rule 3,
# which runs BEFORE the park rule), NOT parked — so the old `parked is True` skip
# missed it, and the label fallback (which would have skipped it via
# pilot:no-auto-dispatch) is only consulted when the model is unavailable.
# The precondition asserts pin that this is the REAL model's verdict — without
# them the test could pass vacuously through that label fallback.
run_test "stuck_execution: in_progress + next-action:athos, 9h → None (athos's turn, not an exec stall)" "
$HARNESS
import time, datetime, json
labels = ['next-action:athos','waiting-on:athos-compra-ssd','pilot:no-auto-dispatch']
assert m._CANONICAL_STATE_FN is not None, 'canonical model not loaded — test would pass vacuously'
d = m._CANONICAL_STATE_FN({'status':'in_progress','labels':labels})
assert d['state']=='awaiting_athos' and d['turn']=='athos', d
old = datetime.datetime.utcfromtimestamp(time.time()-9*3600).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout=json.dumps([{'id':'ga-ormexj','assignee':'gastown.mayor','updated_at':old,'labels':labels}])
    return r
m.sh=fake_sh
print('R=%r' % m.stuck_execution(time.time()))
assert m.stuck_execution(time.time()) is None
print('OK_ATHOS_TURN_NOT_STALL')
" "OK_ATHOS_TURN_NOT_STALL"

# --- 15f. stuck_execution: negative control — same age, no park/turn label → flagged --
run_test "stuck_execution: in_progress with no park/turn label, 9h → flagged (negative control)" "
$HARNESS
import time, datetime, json
assert m._CANONICAL_STATE_FN is not None, 'canonical model not loaded'
old = datetime.datetime.utcfromtimestamp(time.time()-9*3600).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout=json.dumps([{'id':'ga-ctrl','assignee':'dog-ga3wack','updated_at':old,'labels':['lane:small','story:in-flight']}])
    return r
m.sh=fake_sh
r = m.stuck_execution(time.time())
print('R=%r' % r)
assert r is not None and 'ga-ctrl' in r and 'parado há 9h' in r
print('OK_CONTROL_STILL_FLAGS')
" "OK_CONTROL_STILL_FLAGS"

# --- 15g. stuck_execution: the whole ATHOS_TURN vocabulary, per-bead (ga-teljci) ---
# The fix is the CLASS "the canonical turn is the Athos's", not the one label the
# incident carried: iterate bead_state's OWN ATHOS_TURN set (never a hand copy, so a
# new turn label is covered the day it lands) plus the gate:needs-human:product
# variant, with a genuinely stuck sibling in the same result set that must still flag.
run_test "stuck_execution: every ATHOS_TURN label skipped per-bead, plain stuck sibling still flagged" "
$HARNESS
import time, datetime, json, bead_state
old = datetime.datetime.utcfromtimestamp(time.time()-9*3600).strftime('%Y-%m-%dT%H:%M:%SZ')
athos_labels = sorted(bead_state.ATHOS_TURN) + ['gate:needs-human:product']
beads = [{'id':'ga-athos%d' % i,'assignee':'crew/foo','updated_at':old,'labels':[l]} for i,l in enumerate(athos_labels)]
beads.append({'id':'ga-realstuck','assignee':'dog-b','updated_at':old,'labels':['lane:small']})
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout=json.dumps(beads)
    return r
m.sh=fake_sh
r = m.stuck_execution(time.time())
print('R=%r' % r)
assert r is not None and 'ga-realstuck' in r, r
assert 'ga-athos' not in r, 'an Athos-turn bead was flagged as an execution stall: %s' % r
print('OK_ATHOS_VOCAB_PER_BEAD')
" "OK_ATHOS_VOCAB_PER_BEAD"

# --- 15h. stuck_execution: turn=external skipped; an unrelated turn is NOT (ga-teljci) --
# derive() only emits turn=external together with state=parked today, so this pins
# the defensive half of the rule on a stubbed model: the turn alone is enough to skip,
# and a turn that IS the executor's (mayor/crew) must not widen the skip.
run_test "stuck_execution: turn=external skipped by turn alone; turn=mayor still flagged" "
$HARNESS
import time, datetime, json
old = datetime.datetime.utcfromtimestamp(time.time()-9*3600).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout=json.dumps([{'id':'ga-ext','assignee':'crew/foo','updated_at':old,'labels':['x:ext']},
                         {'id':'ga-mayor','assignee':'crew/foo','updated_at':old,'labels':['x:mayor']}])
    return r
m.sh=fake_sh
m._CANONICAL_STATE_FN = lambda b: ({'state':'stub','turn':'external'} if 'x:ext' in b['labels']
                                   else {'state':'stranded','turn':'mayor'})
r = m.stuck_execution(time.time())
print('R=%r' % r)
assert r is not None and 'ga-mayor' in r and 'ga-ext' not in r, r
print('OK_EXTERNAL_TURN')
" "OK_EXTERNAL_TURN"

# --- 15i. stuck_execution: fail-open to the label fallback is preserved (ga-teljci) --
# Model unavailable (None), erroring (raises), or answering with NO verdict (a dict
# with neither state nor turn, or not a dict) → the old STUCK_EXEC_EXCLUDE_LABELS
# fallback decides, exactly as before this fix: an excluded label still skips, and a
# bead with no excluded label still flags (error must not silence the alarm). The
# no-verdict case is the third state: "the model could not say" must reach the
# fallback, not collapse into "this bead is executing normally".
run_test "stuck_execution: model unavailable/raising/verdict-less → label fallback (excluded skipped, plain flagged)" "
$HARNESS
import time, datetime, json
old = datetime.datetime.utcfromtimestamp(time.time()-9*3600).strftime('%Y-%m-%dT%H:%M:%SZ')
def fake_sh(args, timeout=20):
    class R: pass
    r=R(); r.returncode=0
    r.stdout=json.dumps([{'id':'ga-excl','assignee':'crew/foo','updated_at':old,'labels':['pilot:no-auto-dispatch']},
                         {'id':'ga-plain','assignee':'crew/foo','updated_at':old,'labels':['lane:small']}])
    return r
m.sh=fake_sh
def boom(b): raise RuntimeError('model exploded')
for fn in (None, boom, (lambda b: {}), (lambda b: None)):
    m._CANONICAL_STATE_FN = fn
    r = m.stuck_execution(time.time())
    print('FN=%r R=%r' % (fn, r))
    assert r is not None and 'ga-plain' in r and 'ga-excl' not in r, (fn, r)
print('OK_FAIL_OPEN_FALLBACK')
" "OK_FAIL_OPEN_FALLBACK"

# --- ga-z5311j: a bead waiting in the gate's review queue is not an execution stall --
# Live false alarms (07/10, mails ga-wisp-xc05d / ga-wisp-dbeju): ga-bwtrrf, ga-nqjgf0,
# ga-gm5rv5, ga-pa3c6h ... "parado há 9h/13h" — all four sat in_progress with an OPEN
# gate-status:queued marker, i.e. in the gate's review queue (depth 25-30 that day), and
# the REMEDY text (shutdown-dance / kill / re-dispatch) would have been wrong and
# destructive for them. stuck_execution() used to make ONE call (the bd list) and never
# looked at the gate at all.
# Shared fixture for 15j-15r. fake_sh answers the three queries stuck_execution() can
# make and imitates the two bd behaviours that silently under-report a gate lookup in
# production: gate markers/runs are INFRA beads, hidden unless --include-infra is passed
# (ga-vm20x), and a list without --limit 0 is cut at 50 rows with no sign in the JSON
# (ga-21kmp). A failing lookup is a tuple spec: ("none",) sh() answered nothing,
# ("rc", n) bd exited n, ("raw", text) rc 0 with a body that is not a JSON array.
GATE_HARNESS='
import json, time
NOW = time.time()
def _age(h):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - h * 3600))
class _R:
    def __init__(self, out, rc=0):
        self.stdout, self.returncode, self.stderr = out, rc, ""
def _reply(spec):
    if isinstance(spec, list):
        return _R(json.dumps(spec))
    if spec[0] == "none":
        return None
    if spec[0] == "rc":
        return _R("", spec[1])
    if spec[0] == "raw":
        return _R(spec[1])
    raise AssertionError(spec)
CALLS = []
def make_sh(in_progress, markers=None, runs=None):
    del CALLS[:]
    def rows_of(spec, args):
        spec = [] if spec is None else spec
        if not isinstance(spec, list):
            return spec
        if "--include-infra" not in args:
            return []
        lim = args[args.index("--limit") + 1] if "--limit" in args else "50"
        return spec if lim == "0" else spec[:int(lim)]
    def fake_sh(args, timeout=20):
        CALLS.append(list(args))
        a = " ".join(args)
        if "type:quality-gate-marker" in a:
            return _reply(rows_of(markers, args))
        if "type:quality-gate-run" in a:
            return _reply(rows_of(runs, args))
        if "in_progress" in a:
            return _reply(in_progress)
        return _reply([])
    return fake_sh
def marker(src, *statuses):
    return {"id": "mk-" + src, "status": "open",
            "labels": ["type:quality-gate-marker", "source-bead:" + src] + ["gate-status:" + s for s in statuses]}
def gate_run(src, *statuses):
    return {"id": "run-" + src, "status": "open",
            "labels": ["type:quality-gate-run", "source-bead:" + src] + ["gate-status:" + s for s in statuses]}
def bead(i, hours, labels=(), assignee="", owner="test@example.com", meta=None):
    d = {"id": i, "status": "in_progress", "assignee": assignee, "owner": owner,
         "updated_at": _age(hours), "labels": list(labels)}
    if meta:
        d["metadata"] = meta
    return d
'

# --- 15j. in_progress + gate:queued + OPEN marker → None (the replay) --------
run_test "stuck_execution: in_progress + gate:queued + OPEN marker, 13h → None (waiting in the gate queue, replay of ga-gm5rv5)" "
$HARNESS
$GATE_HARNESS
m.sh = make_sh([bead('ga-gm5rv5', 13, ['gate:queued','story:in-flight'])],
               markers=[marker('ga-gm5rv5', 'queued')])
r = m.stuck_execution(NOW)
print('R=%r' % r)
assert r is None, r
print('OK_GATE_QUEUE_NOT_STUCK')
" "OK_GATE_QUEUE_NOT_STUCK"

# --- 15k. negative control: lookup answered [] → a residual label alone silences nothing --
# derive() documents the same rule: a caller that resolved the marker overrides the
# label in BOTH directions (a closed marker unlocks a leftover gate:queued, ga-zltsr).
run_test "stuck_execution: same bead, gate lookup answered [] (nobody at the gate) → still flagged" "
$HARNESS
$GATE_HARNESS
m.sh = make_sh([bead('ga-gm5rv5', 13, ['gate:queued'])], markers=[], runs=[])
r = m.stuck_execution(NOW)
print('R=%r' % r)
assert r is not None and 'ga-gm5rv5' in r, r
print('OK_RESIDUAL_LABEL_STILL_FLAGS')
" "OK_RESIDUAL_LABEL_STILL_FLAGS"

# --- 15l. the lookup FAILING is its own state — neither empty nor found -------
# found → out of the alarm, listed apart; empty ([] confirmed) → flagged (15k); failed →
# the canonical derive() fallback (no marker verdict → the gate:* label decides): a
# labeled bead stays out of the alarm but is listed as "marker não verificado"; a bead
# with no gate label at all is still flagged. rc != 0, a body that is not a JSON array,
# an EMPTY body (bd prints [] when nothing matches) and no answer at all are all failures.
run_test "stuck_execution: gate lookup FAILS → labeled bead listed as marker não verificado, unlabeled bead still flagged" "
$HARNESS
$GATE_HARNESS
labeled = bead('ga-labeled', 13, ['gate:queued'])
plain = bead('ga-plain', 13, ['lane:small'])
shapes = [('marker rc=1', dict(markers=('rc', 1))),
          ('marker garbage', dict(markers=('raw', 'not json at all'))),
          ('marker empty body', dict(markers=('raw', ''))),
          ('marker no answer', dict(markers=('none',))),
          ('marker object not array', dict(markers=('raw', '{}'))),
          ('run rc=1', dict(markers=[], runs=('rc', 1))),
          ('run garbage', dict(markers=[], runs=('raw', '{oops')))]
for name, kw in shapes:
    m.sh = make_sh([labeled, plain], **kw)
    r = m.stuck_execution(NOW)
    print('%s -> %r' % (name, r))
    assert r is not None, name
    head, sep, tail = r.partition('aguardando revisão')
    assert 'ga-plain' in head and 'ga-labeled' not in head, (name, r)
    assert 'ga-labeled' in tail and 'marker não verificado' in tail, (name, r)
print('OK_LOOKUP_FAILURE_IS_ITS_OWN_STATE')
" "OK_LOOKUP_FAILURE_IS_ITS_OWN_STATE"

# --- 15m. marker keyed on the SLING bead (ga-lrglm wrapper dispatch) ----------
run_test "stuck_execution: marker keyed on the SLING bead (pilot.sling_bead) counts for the story; an unrelated marker does not" "
$HARNESS
$GATE_HARNESS
story = bead('ga-story', 13, ['gate:queued'], meta={'pilot.sling_bead': 'ga-sling9'})
m.sh = make_sh([story], markers=[marker('ga-sling9', 'queued')])
r = m.stuck_execution(NOW)
print('KEYED_ON_SLING=%r' % r)
assert r is None, r
m.sh = make_sh([story], markers=[marker('ga-someone-else', 'queued')])
r = m.stuck_execution(NOW)
print('UNRELATED=%r' % r)
assert r is not None and 'ga-story' in r, r
print('OK_SLING_KEYED_MARKER')
" "OK_SLING_KEYED_MARKER"

# --- 15n. per-bead, not a blanket mute: waiting listed apart, stuck sibling flagged --
run_test "stuck_execution: gate-waiting bead listed apart, genuinely stuck sibling still flagged" "
$HARNESS
$GATE_HARNESS
m.sh = make_sh([bead('ga-waiting', 13, ['gate:queued']), bead('ga-realstuck', 9, ['lane:small'], assignee='dog-b')],
               markers=[marker('ga-waiting', 'queued')])
r = m.stuck_execution(NOW)
print('R=%r' % r)
assert r is not None, r
head, sep, tail = r.partition('aguardando revisão')
assert sep and 'ga-realstuck' in head and 'ga-waiting' not in head, r
assert 'ga-waiting' in tail and 'ga-realstuck' not in tail, r
print('OK_MIXED_WAITING_AND_STUCK')
" "OK_MIXED_WAITING_AND_STUCK"

run_test "stuck_execution: waiting-only set returns None but the bead is logged apart as aguardando revisão" "
$HARNESS
$GATE_HARNESS
import contextlib, io
m.sh = make_sh([bead('ga-gm5rv5', 13, ['gate:queued'])], markers=[marker('ga-gm5rv5', 'queued')])
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    r = m.stuck_execution(NOW)
out = buf.getvalue()
print('LOG=%r' % out)
assert r is None, r
assert 'aguardando revisão' in out and 'ga-gm5rv5' in out and 'há 13h' in out, out
print('OK_WAITING_LOGGED_APART')
" "OK_WAITING_LOGGED_APART"

# --- 15o. the HQ git identity is not an owner ---------------------------------
# bd stamps `owner` with the git user.email of the clone that ran `bd create`; for the
# HQ that is test@example.com — not a person or a session (the mails read
# "ga-gm5rv5 (owner=test@example.com) parado há 13h"). Real owners stay visible.
run_test "stuck_execution: the HQ git identity (test@example.com) is not an owner → sem dono; real owners still shown" "
$HARNESS
$GATE_HARNESS
def reason_for(**kw):
    m.sh = make_sh([bead('ga-o', 13, **kw)], markers=[], runs=[])
    return m.stuck_execution(NOW)
r = reason_for(assignee='', owner='test@example.com')
print('NO_ASSIGNEE=%r' % r)
assert 'ga-o (sem dono) parado há 13h' in r and 'test@example.com' not in r, r
r = reason_for(assignee='dog-1', owner='test@example.com')
print('WITH_ASSIGNEE=%r' % r)
assert 'ga-o (assignee=dog-1) parado há 13h' in r and 'test@example.com' not in r, r
r = reason_for(assignee='', owner='athosmartins@gmail.com')
print('REAL_OWNER=%r' % r)
assert 'ga-o (owner=athosmartins@gmail.com) parado há 13h' in r, r
print('OK_PLACEHOLDER_OWNER_IS_SEM_DONO')
" "OK_PLACEHOLDER_OWNER_IS_SEM_DONO"

# --- 15p. poll cost: lazy and bounded -----------------------------------------
# A detector costs a poll (ga-y0g5x): the healthy path must not touch the gate at all, and
# a sweep with many stale beads must read the gate ONCE (bulk), not once per bead.
run_test "stuck_execution: no gate query on the healthy path; stale beads cost exactly one marker + one run query, however many" "
$HARNESS
$GATE_HARNESS
def gate_calls():
    return [c for c in CALLS if any('quality-gate' in x for x in c)]
m.sh = make_sh([bead('ga-fresh', 1, ['gate:queued']), bead('ga-athos', 13, ['next-action:athos'])])
assert m.stuck_execution(NOW) is None
assert gate_calls() == [], gate_calls()
stale = [bead('ga-s%d' % i, 13, ['lane:small'], assignee='dog-%d' % i) for i in range(6)]
m.sh = make_sh(stale, markers=[], runs=[])
r = m.stuck_execution(NOW)
assert r is not None
kinds = sorted(('marker' if any('quality-gate-marker' in x for x in c) else 'run') for c in gate_calls())
print('GATE_QUERIES=%r' % kinds)
assert kinds == ['marker', 'run'], kinds
print('OK_GATE_LOOKUP_IS_LAZY_AND_BOUNDED')
" "OK_GATE_LOOKUP_IS_LAZY_AND_BOUNDED"

# --- 15q. what counts as "in the gate queue" ----------------------------------
# A MARKER counts with the active vocabulary of pilot-dispatcher's
# _beadid_has_active_gate_artifact and inflight-reclaim-guard's list_gate_active_source_beads
# (ready/claimed/queued/dispatching/reviewing/running), plus the guard's fail-safe: a marker
# with no gate-status label at all reads as active. needs-rebase / error and the terminal
# pairs do not (the gate stepped back onto an external actor — not "waiting for review").
# A RUN has its own rule (_gate_artifact_active): active unless it carries a gate-status and
# every one of them is terminal (superseded/aborted/passed/failed); a run with no gate-status
# label at all reads as active too, same fail-safe as the marker; one live status among
# terminal ones (a run caught mid-transition) keeps it active.
run_test "_gate_active_source_beads: active marker/run states and a label-less marker count; needs-rebase, error and terminal ones do not" "
$HARNESS
$GATE_HARNESS
mk = [marker('ga-a', 'queued'), marker('ga-b', 'needs-rebase'), marker('ga-c', 'reviewing'),
      marker('ga-d'), marker('ga-e', 'needs-rebase', 'superseded'), marker('ga-f', 'queued', 'dispatching'),
      marker('ga-g', 'ready'), marker('ga-h', 'claimed'), marker('ga-i', 'dispatching'), marker('ga-j', 'error')]
rn = [gate_run('ga-k', 'running'), gate_run('ga-l', 'passed'), gate_run('ga-n', 'superseded'), gate_run('ga-o', 'claimed'),
      gate_run('ga-p'), gate_run('ga-q', 'aborted', 'failed'), gate_run('ga-r', 'running', 'passed')]
m.sh = make_sh([], markers=mk, runs=rn)
got = m._gate_active_source_beads()
print('GOT=%r' % sorted(got))
want = {'ga-a','ga-c','ga-d','ga-f','ga-g','ga-h','ga-i','ga-k','ga-o','ga-p','ga-r'}
assert got == want, sorted(got ^ want)
print('OK_GATE_ACTIVE_CLASSIFICATION')
" "OK_GATE_ACTIVE_CLASSIFICATION"

# --- 15r. no silent 50-row cut (ga-21kmp) -------------------------------------
run_test "stuck_execution: the bead whose marker is the 61st open marker is still found (--limit 0)" "
$HARNESS
$GATE_HARNESS
others = [marker('ga-x%d' % i, 'queued') for i in range(60)]
m.sh = make_sh([bead('ga-gm5rv5', 13, ['gate:queued'])], markers=others + [marker('ga-gm5rv5', 'queued')])
r = m.stuck_execution(NOW)
print('R=%r' % r)
assert r is None, r
print('OK_NO_SILENT_TRUNCATION')
" "OK_NO_SILENT_TRUNCATION"

# --- 16. mail-send failure → not counted, ntfy fires, retry ------------------
run_test "mail-send failure → not counted, ntfy fires (retry next tick)" "
$HARNESS
st = m.new_state()
m.escalate_mayor = lambda d,r: False    # mail send reports failure
m._FINDINGS = [('deploy-block','wa ahead=3')]
m.run_tick(1000.0, st)
m.run_tick(2600.0, st)   # confirmed, attempts escalate, fails
print('esc_count=%d notifies=%d' % (st['deploy-block']['escalations'], len(m.NOTIFIES)))
assert st['deploy-block']['escalations'] == 0, 'failed mail must not count'
assert len(m.NOTIFIES) >= 1, 'failed mail must still ntfy Athos'
print('OK_MAIL_FAIL')
" "OK_MAIL_FAIL"

# --- 17. detect() pure, returns the three dimensions -------------------------
run_test "detect() pure, returns the three dimensions when each fires" "
$HARNESS
m.deploy_block = lambda now: 'd'
m.merge_stall = lambda now: 'm'
m.stuck_execution = lambda now: 's'
out = m._REAL_DETECT(1000.0)
dims = [d for d,_ in out]
print('DIMS=%r' % dims)
assert dims == ['deploy-block','merge-stall','stuck-exec'], dims
print('OK_DETECT_PURE')
" "OK_DETECT_PURE"

# --- 18. parse_bd_json tolerates trailing non-JSON line ----------------------
run_test "parse_bd_json tolerates a trailing non-JSON summary line" "
$HARNESS
raw='[{\"id\":\"ga-a\"}]\\nShowing 1 of 1 issues'
out = m.parse_bd_json(raw)
print('OUT=%r' % out)
assert isinstance(out, list) and len(out)==1 and out[0]['id']=='ga-a'
print('OK_BD_TRAILING')
" "OK_BD_TRAILING"

# --- 19. the harness's ledger writes are diverted, never live (ga-9d7it9) ------
# Same two-tick confirmed escalation as scenario 2, but this one looks at WHERE the
# real human-touch row went. Public gc_ledger API only: ledger_path() follows a
# selftest redirect, LIVE_LEDGER_DIR is the production dir the guard protects.
run_test "confirmed escalation writes its human-touch row to the diverted ledger, never the live one" "
$HARNESS
import gc_ledger
st = m.new_state()
m._FINDINGS = [('deploy-block','wa ahead=3')]
m.run_tick(1000.0, st)
m.run_tick(2600.0, st)   # confirmed -> escalates -> real _ledger('human-touch', ...)
p = gc_ledger.ledger_path('human-touch')
print('LEDGER_PATH=%s' % p)
assert not p.startswith(gc_ledger.LIVE_LEDGER_DIR), 'harness NOT diverted: its rows would hit the LIVE ledger'
rows = [l for l in open(p, encoding='utf-8') if 'wa ahead=3' in l]
assert len(rows) >= 1, 'the escalation row did not land where ledger_path() says'
print('OK_LEDGER_DIVERTED')
" "OK_LEDGER_DIVERTED"

echo "----------------------------------------"
echo "production-stall-watchdog selftest: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
