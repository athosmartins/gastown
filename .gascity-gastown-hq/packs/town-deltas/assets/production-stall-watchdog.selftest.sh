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
