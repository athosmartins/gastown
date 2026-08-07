#!/usr/bin/env bash
# inflight-reclaim-guard.label-removal-durability.selftest.sh — Regression
# harness for ga-jzye0: do_reclaim()'s label-removal step used to trust a
# single unverified `bd label remove` call. A remove that reports success
# (rc=0) but doesn't durably land (Dolt replication lag / transient hiccup)
# let do_reclaim proceed to clear assignee + reset status + bump
# pilot:reclaim-count anyway — producing a bead with story:in-flight /
# pilot:dispatched STILL present alongside an EMPTY assignee: invisible to
# re-dispatch (still reads in-flight) and invisible to every dead-worker /
# lane-occupancy check in pilot-dispatcher.sh (they only evaluate a
# non-empty assignee; an empty one is deliberately treated as an unresolved
# leg -> keep). Confirmed live: wa-zly4n sat in exactly this state —
# pilot:reclaim-count:1, assignee cleared, story:in-flight still present —
# hours after the reclaim that produced it.
#
# Original bug report (ga-jzye0) theorized the mechanism was Pilot's
# dead-session lane-count treating a DEAD-BUT-ASSIGNED owner as live. Direct
# inspection of the three cited beads disproved that for two of three (both
# were type:quality-gate-verdict beads that never carry story:in-flight at
# all — structurally outside that count). The third, wa-zly4n, is a real,
# still-open, currently-live zombie — but its actual mechanism is THIS one:
# a partially-applied reclaim, not a dead session with a lingering assignee.
#
# Scenarios:
#   1. Label removal confirmed gone on the FIRST read-back → True immediately
#      (baseline, unaffected by the fix).
#   2. Label removal reports rc=0 but a read-back shows it STILL present for
#      2 attempts, then gone on the 3rd → _remove_label_verified retries and
#      confirms (proves the retry loop, not just the first read-back, is
#      exercised).
#   3. THE REGRESSION: label removal reports rc=0 but a read-back NEVER shows
#      it gone (persistent failure / stuck replica) → _remove_label_verified
#      returns False. Pre-fix, the equivalent single-attempt check only
#      looked at the remove command's own returncode (0 = "done"), so this
#      exact case sailed through undetected.
#   4. Integration: do_reclaim returns False and NEVER calls `bd assign` /
#      `bd update --status` when label removal can't be confirmed — the
#      abort-before-mutating-further contract that prevents the wa-zly4n
#      zombie from ever being producible.
#   5. Pre-existing short-circuit (ga-7m191): a label already absent from the
#      bead's last-known label set is never remove/read-back attempted at
#      all — unaffected by this fix.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$SCRIPT_DIR/inflight-reclaim-guard.py"

/usr/bin/python3 - "$WD" <<'PY'
import sys, importlib.util, json

wd_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("inflight_reclaim_guard", wd_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

PASS = 0
FAIL = 0

def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)

def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

class FakeResult:
    def __init__(self, returncode, stdout):
        self.returncode = returncode
        self.stdout = stdout

def install_fake_run(target_label, remove_rc=0, show_label_present_for=0,
                      bead_id="wa-zly4n", other_labels=None):
    """Simulate `bd label remove` (always reports remove_rc) and `bd show
    --json` read-backs: target_label stays present for the first
    `show_label_present_for` READ-BACK calls, then reads as gone."""
    other_labels = other_labels or ["lane:small", "ctx:ready"]
    state = {"show_calls": 0}

    def fake_run(cmd, capture_output=True, text=True, timeout=15):
        if len(cmd) >= 3 and cmd[1] == "label" and cmd[2] == "remove":
            return FakeResult(remove_rc, "")
        if len(cmd) >= 2 and cmd[1] == "show":
            state["show_calls"] += 1
            present = state["show_calls"] <= show_label_present_for
            labels = list(other_labels) + ([target_label] if present else [])
            return FakeResult(0, json.dumps([{"id": bead_id, "labels": labels}]))
        raise AssertionError("unexpected cmd in _remove_label_verified test: %r" % (cmd,))

    orig = m.subprocess.run
    m.subprocess.run = fake_run
    return orig, state

def restore_run(orig):
    m.subprocess.run = orig

orig_sleep = m.time.sleep
m.time.sleep = lambda *_a, **_k: None  # selftest must not actually sleep

# ── Scenario 1: confirmed gone on first read-back ────────────────────────
print("Scenario 1: label confirmed gone on first read-back -> True immediately")
orig, state = install_fake_run("story:in-flight", remove_rc=0, show_label_present_for=0)
try:
    res = m._remove_label_verified(["bd"], "wa-zly4n", "story:in-flight")
    if res is True and state["show_calls"] == 1:
        ok("confirmed on first read-back, 1 show call")
    else:
        bad("expected True with 1 show call, got res=%r show_calls=%d" % (res, state["show_calls"]))
finally:
    restore_run(orig)

# ── Scenario 2: retries through 2 stale read-backs, confirms on the 3rd ──
print("Scenario 2: label reads present for 2 read-backs, gone on 3rd -> retries and confirms")
orig, state = install_fake_run("story:in-flight", remove_rc=0, show_label_present_for=2)
try:
    res = m._remove_label_verified(["bd"], "wa-zly4n", "story:in-flight")
    if res is True and state["show_calls"] == 3:
        ok("retried through staleness and confirmed on read-back 3")
    else:
        bad("expected True after 3 show calls, got res=%r show_calls=%d" % (res, state["show_calls"]))
finally:
    restore_run(orig)

# ── Scenario 3: THE REGRESSION — label never confirmed gone ──────────────
print("Scenario 3 (ga-jzye0): remove reports rc=0 but label NEVER confirmed gone")
orig, state = install_fake_run("story:in-flight", remove_rc=0, show_label_present_for=999)
try:
    res = m._remove_label_verified(["bd"], "wa-zly4n", "story:in-flight", attempts=4)
    if res is False:
        ok("persistent failure correctly returns False (bug ga-jzye0 FIXED)")
    else:
        bad("REGRESSION (ga-jzye0): expected False when label is never confirmed "
            "removed, got %r — a caller would proceed to clear ownership on an "
            "unverified label removal, producing the wa-zly4n zombie" % res)
finally:
    restore_run(orig)

# ── Scenario 3b (self-audit, ga-jzye0): read-back returns an error envelope ──
# Third-state check on THIS fix's own read-back: `bead.get("labels")` alone
# can't tell "confirmed empty labels list" apart from "bd show returned an
# error envelope with no labels key at all" — both look like `[]`/None to a
# bare .get(). An error envelope must NOT be read as "label confirmed gone".
print("Scenario 3b (ga-jzye0 self-audit): bd show returns an error envelope, "
      "not a real bead -> never confirmed, not silently treated as removed")
def fake_run_error_envelope(cmd, capture_output=True, text=True, timeout=15):
    if len(cmd) >= 3 and cmd[1] == "label" and cmd[2] == "remove":
        return FakeResult(0, "")
    if len(cmd) >= 2 and cmd[1] == "show":
        # No "labels" key at all -- an error envelope, not a bead object.
        return FakeResult(0, json.dumps({"error": "no issues found matching the provided IDs"}))
    raise AssertionError("unexpected cmd: %r" % (cmd,))

orig = m.subprocess.run
m.subprocess.run = fake_run_error_envelope
try:
    res = m._remove_label_verified(["bd"], "wa-zly4n", "story:in-flight", attempts=2)
    if res is False:
        ok("error envelope (no labels key) correctly NOT treated as confirmed-gone")
    else:
        bad("REGRESSION (ga-jzye0 self-audit): an error envelope with no labels key "
            "was read as 'label confirmed absent' -> got %r, expected False. This is "
            "the exact third-state collapse (can't-check == confirmed) the fix exists "
            "to eliminate." % res)
finally:
    restore_run(orig)

# ── Scenario 4: do_reclaim aborts before mutating further ────────────────
print("Scenario 4 (ga-jzye0 integration): do_reclaim returns False and never "
      "calls assign/update when label removal can't be confirmed")
calls = []
def fake_run_integration(cmd, capture_output=True, text=True, timeout=15):
    calls.append(list(cmd))
    if len(cmd) >= 3 and cmd[1] == "label" and cmd[2] == "remove":
        return FakeResult(0, "")
    if len(cmd) >= 2 and cmd[1] == "show":
        # story:in-flight always reads back present -> never confirmed removed
        return FakeResult(0, json.dumps([{"id": "wa-zly4n",
                                           "labels": ["story:in-flight", "pilot:dispatched",
                                                      "lane:small"]}]))
    if len(cmd) >= 2 and cmd[1] == "assign":
        bad("do_reclaim called `bd assign` despite unconfirmed label removal — "
            "this is exactly the pre-fix half-reclaim that produced the wa-zly4n zombie")
        return FakeResult(0, "")
    if len(cmd) >= 2 and cmd[1] == "update":
        bad("do_reclaim called `bd update --status` despite unconfirmed label removal")
        return FakeResult(0, "")
    return FakeResult(0, "")

orig = m.subprocess.run
m.subprocess.run = fake_run_integration
orig_preserve = m.preserve_unpushed_branch
m.preserve_unpushed_branch = lambda *_a, **_k: []
try:
    res = m.do_reclaim("wa-zly4n", "some title", 0, 30.0,
                        ["story:in-flight", "pilot:dispatched", "lane:small"])
    if res is False:
        ok("do_reclaim returned False on unconfirmed label removal")
    else:
        bad("expected do_reclaim to return False, got %r" % res)
    label_remove_calls = [c for c in calls
                           if len(c) >= 3 and c[1] == "label" and c[2] == "remove"]
    if label_remove_calls:
        ok("do_reclaim attempted label removal (%d call(s)) before aborting"
           % len(label_remove_calls))
    else:
        bad("do_reclaim never attempted label removal at all")
finally:
    m.subprocess.run = orig
    m.preserve_unpushed_branch = orig_preserve

# ── Scenario 5: label already absent -> no remove/show attempted for it ──
print("Scenario 5 (ga-7m191, pre-existing): pilot:dispatched already absent from "
      "labels -> do_reclaim never calls remove/show for it")
calls5 = []
def fake_run_absent(cmd, capture_output=True, text=True, timeout=15):
    calls5.append(list(cmd))
    if len(cmd) >= 3 and cmd[1] == "label" and cmd[2] == "remove":
        return FakeResult(0, "")
    if len(cmd) >= 2 and cmd[1] == "show":
        return FakeResult(0, json.dumps([{"id": "wa-zly4n", "labels": ["lane:small"]}]))
    return FakeResult(0, "")

orig = m.subprocess.run
m.subprocess.run = fake_run_absent
orig_preserve = m.preserve_unpushed_branch
m.preserve_unpushed_branch = lambda *_a, **_k: []
try:
    m.do_reclaim("wa-zly4n", "some title", 0, 30.0,
                 ["story:in-flight", "lane:small"])  # pilot:dispatched NOT present
    dispatched_calls = [c for c in calls5
                         if len(c) >= 5 and c[1] == "label" and c[4] == "pilot:dispatched"]
    if not dispatched_calls:
        ok("no label remove/read-back attempted for already-absent pilot:dispatched")
    else:
        bad("unexpected calls referencing absent pilot:dispatched: %r" % dispatched_calls)
finally:
    m.subprocess.run = orig
    m.preserve_unpushed_branch = orig_preserve

m.time.sleep = orig_sleep

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
