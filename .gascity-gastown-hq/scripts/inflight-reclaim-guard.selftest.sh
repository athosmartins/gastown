#!/usr/bin/env bash
# inflight-reclaim-guard.selftest.sh — Regression harness for
# list_gate_active_source_beads() fail-safe contract (ga-ap7od).
#
# Bug: on a per-label sub-query subprocess failure (non-zero returncode from
# `bd list --label type:quality-gate-marker --label <gate_lbl>`), the loop did
# `continue` — treating a QUERY FAILURE the same as "no beads matched" — instead
# of returning None like the function's own docstring promises ("Returns...
# None on error (fail-safe: caller treats None as unknown and skips the cycle
# rather than risking a false reclaim)"). A transient failure on just the
# gate-status:queued sub-query (e.g. brief Dolt contention) silently dropped
# ALL currently-queued markers from the active set for that cycle without
# tripping the fail-safe, risking a false reclaim of a bead with a live,
# healthy gate review in flight.
#
# Scenarios:
#   1. All sub-queries succeed, some return beads → correct frozenset of
#      source-bead IDs (baseline, unaffected by the fix).
#   2. All sub-queries succeed with zero matches → empty frozenset, not None
#      ("no beads matching this label combo" remains a legitimate non-error).
#   3. One sub-query returns non-zero (simulated transient failure) → None
#      (THE regression test — was a partial frozenset pre-fix).
#   4. A sub-query raises an exception (e.g. timeout) → None (already
#      fail-safe pre-fix; verify the fix didn't disturb this path).
#   5. A sub-query returns unparseable JSON → None (same, pre-existing path).
#   6. A sub-query returns valid JSON that isn't a list → None (same,
#      pre-existing path).
#   7. Drift guard: source still returns None (not `continue`) on non-zero
#      returncode, and the docstring's fail-safe contract line is intact.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$SCRIPT_DIR/inflight-reclaim-guard.py"

/usr/bin/python3 - "$WD" <<'PY'
import sys, importlib.util, json

wd_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("inflight_reclaim_guard", wd_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)  # top-level defines only; main loop is guarded by __name__

PASS = 0
FAIL = 0

def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)

def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

GATE_LABELS = ("gate-status:ready", "gate-status:dispatching", "gate-status:queued", "gate-status:claimed")

class FakeResult:
    def __init__(self, returncode, stdout):
        self.returncode = returncode
        self.stdout = stdout

def install_fake_run(fail_labels=None, raise_labels=None, label_beads=None, bad_json_labels=None, non_list_labels=None):
    """Monkeypatch m.subprocess.run to simulate per-label bd-list outcomes.
    cmd shape (current, ga-vm20x): ["bd","list","--include-infra","--label",
    "type:quality-gate-marker","--label",gate_lbl,"--json","--limit","0"]
    """
    fail_labels = fail_labels or set()
    raise_labels = raise_labels or set()
    label_beads = label_beads or {}
    bad_json_labels = bad_json_labels or set()
    non_list_labels = non_list_labels or set()

    def fake_run(cmd, capture_output=True, text=True, timeout=20):
        # gate_lbl is the value after the SECOND "--label" flag (the first is
        # always type:quality-gate-marker). Found by flag name, not fixed
        # position (ga-vm20x/ga-z30sv): a hardcoded cmd[5] was correct before
        # --include-infra was inserted at index 2, shifting every later index
        # by one — cmd[5] then silently read the literal string "--label"
        # instead of the real gate_lbl, so no scenario's fail_labels/
        # raise_labels/bad_json_labels/non_list_labels ever matched and every
        # sub-query silently fell through to the empty-success default,
        # regardless of what the scenario intended to simulate. Mirrors the
        # same by-flag-name fix already proven correct in this file's sibling
        # stub, inflight-reclaim-guard.py's own _stub_bd() (Section 6, SB-7b).
        _label_positions = [i for i, a in enumerate(cmd) if a == "--label"]
        gate_lbl = (cmd[_label_positions[1] + 1]
                    if len(_label_positions) >= 2 and _label_positions[1] + 1 < len(cmd)
                    else "")
        if gate_lbl in raise_labels:
            raise RuntimeError("simulated subprocess crash for %s" % gate_lbl)
        if gate_lbl in fail_labels:
            return FakeResult(1, "")
        if gate_lbl in bad_json_labels:
            return FakeResult(0, "{not valid json")
        if gate_lbl in non_list_labels:
            return FakeResult(0, json.dumps({"unexpected": "shape"}))
        beads = label_beads.get(gate_lbl, [])
        markers = [{"labels": ["type:quality-gate-marker", gate_lbl, "source-bead:%s" % b]} for b in beads]
        return FakeResult(0, json.dumps(markers))

    orig = m.subprocess.run
    m.subprocess.run = fake_run
    return orig

def restore_run(orig):
    m.subprocess.run = orig

# ── Scenario 1: all succeed, some beads → correct frozenset ─────────────────
print("Scenario 1: all sub-queries succeed with matches → correct frozenset")
orig = install_fake_run(label_beads={
    "gate-status:queued": ["ga-aaaaa", "ga-bbbbb"],
    "gate-status:claimed": ["ga-ccccc"],
})
try:
    res = m.list_gate_active_source_beads()
    if res == frozenset({"ga-aaaaa", "ga-bbbbb", "ga-ccccc"}):
        ok("frozenset correctly aggregated across labels: %r" % sorted(res))
    else:
        bad("expected {ga-aaaaa,ga-bbbbb,ga-ccccc}, got %r" % res)
finally:
    restore_run(orig)

# ── Scenario 2: all succeed, zero matches → empty frozenset, not None ───────
print("Scenario 2: all sub-queries succeed with zero matches → empty frozenset (not None)")
orig = install_fake_run()
try:
    res = m.list_gate_active_source_beads()
    if res == frozenset():
        ok("zero matches → empty frozenset (legitimate non-error)")
    else:
        bad("expected empty frozenset, got %r" % res)
finally:
    restore_run(orig)

# ── Scenario 3: THE REGRESSION — one sub-query fails (non-zero) → None ──────
print("Scenario 3: gate-status:queued sub-query fails (returncode=1) → None (fail-safe)")
orig = install_fake_run(
    fail_labels={"gate-status:queued"},
    label_beads={"gate-status:claimed": ["ga-live-review"]},
)
try:
    res = m.list_gate_active_source_beads()
    if res is None:
        ok("sub-query failure correctly fails safe → None (bug ga-ap7od FIXED)")
    else:
        bad("REGRESSION (ga-ap7od): sub-query failure silently dropped instead of "
            "failing safe — got %r instead of None. A caller would treat this "
            "partial/wrong result as ground truth and could falsely reclaim a bead "
            "with a live, healthy gate review." % res)
finally:
    restore_run(orig)

# ── Scenario 4: a sub-query raises → None (pre-existing fail-safe path) ─────
print("Scenario 4: gate-status:dispatching sub-query raises → None (pre-existing path)")
orig = install_fake_run(raise_labels={"gate-status:dispatching"})
try:
    res = m.list_gate_active_source_beads()
    if res is None:
        ok("exception during sub-query → None (unaffected by the fix)")
    else:
        bad("expected None on exception, got %r" % res)
finally:
    restore_run(orig)

# ── Scenario 5: unparseable JSON → None (pre-existing path) ─────────────────
print("Scenario 5: gate-status:ready sub-query returns unparseable JSON → None")
orig = install_fake_run(bad_json_labels={"gate-status:ready"})
try:
    res = m.list_gate_active_source_beads()
    if res is None:
        ok("unparseable JSON → None (unaffected by the fix)")
    else:
        bad("expected None on JSON parse failure, got %r" % res)
finally:
    restore_run(orig)

# ── Scenario 6: valid JSON, wrong shape (not a list) → None (pre-existing) ──
print("Scenario 6: gate-status:claimed sub-query returns non-list JSON → None")
orig = install_fake_run(non_list_labels={"gate-status:claimed"})
try:
    res = m.list_gate_active_source_beads()
    if res is None:
        ok("non-list JSON payload → None (unaffected by the fix)")
    else:
        bad("expected None on non-list payload, got %r" % res)
finally:
    restore_run(orig)

# ── Scenario 7: drift guard — source still fails safe, docstring intact ─────
print("Scenario 7: drift guard — fail-safe return + docstring contract present")
src = open(wd_path).read()
import re
fn_match = re.search(r"def list_gate_active_source_beads\(\):.*?(?=\ndef |\Z)", src, re.S)
if not fn_match:
    bad("could not locate list_gate_active_source_beads() source for drift check")
else:
    fn_src = fn_match.group(0)
    # Strip full-line comments so an interleaved `# ...` line between `if` and
    # its body can't hide the real next statement from either regex below.
    fn_src_nocomments = "\n".join(
        line for line in fn_src.splitlines() if not line.strip().startswith("#")
    )
    if re.search(r"if result\.returncode != 0:\s*\n\s*return None", fn_src_nocomments):
        ok("non-zero returncode path returns None (fail-safe, not silently continuing)")
    else:
        bad("MISSING: non-zero returncode path no longer returns None directly — "
            "regression back to silent `continue` (or equivalent) is possible")
    if re.search(r"returncode != 0:\s*\n\s*continue", fn_src_nocomments):
        bad("REGRESSION: found `continue` directly on the returncode!=0 branch")
    else:
        ok("no bare `continue` on the returncode!=0 branch")
    # Docstring wraps across lines with leading indentation; normalize
    # whitespace runs to single spaces before matching so a reflow doesn't
    # false-fail this check.
    normalized = " ".join(src.split())
    if "fail-safe: caller treats None as unknown and skips the cycle" in normalized:
        ok("docstring fail-safe contract line intact")
    else:
        bad("MISSING: docstring fail-safe contract line changed/removed")

# Scenario 8 (wa-og36j): update_strand_clock() must RESET the strand clock on a
# FRESH claim (assignee changed to a new worker) so a reclaimed->re-dispatched
# bead is not born-stale — inheriting the prior claim's stranding age and being
# reclaimed within minutes before the new builder can engage (structural churn).
print("Scenario 8: strand-clock fresh-claim reset (wa-og36j born-stale fix)")
_TTL = m.RECLAIM_TTL
_NOW = 1_000_000.0
_st = {"first_seen_stranded": _NOW - 3000, "last_assignee": "wa-worker-adhoc-A"}
_secs, _ = m.update_strand_clock(_st, True, "wa-worker-adhoc-B", _NOW)
if _secs < _TTL:
    ok("fresh claim (A->B) while still stranded resets clock (%.0fs < TTL)" % _secs)
else:
    bad("BORN-STALE: fresh claim kept old clock (%.0fs >= TTL) -> instant reclaim" % _secs)
_st = {"first_seen_stranded": _NOW - 3000, "last_assignee": ""}
_secs, _ = m.update_strand_clock(_st, True, "wa-worker-adhoc-B", _NOW)
if _secs < _TTL:
    ok("re-dispatch after reclaim ('' -> B) resets clock")
else:
    bad("BORN-STALE after reclaim gap (%.0fs)" % _secs)
_st = {"first_seen_stranded": _NOW - 3000, "last_assignee": "wa-worker-adhoc-A"}
_secs, _ = m.update_strand_clock(_st, True, "wa-worker-adhoc-A", _NOW)
if _secs >= _TTL:
    ok("same assignee keeps clock (genuine dead builder still reclaimable)")
else:
    bad("REGRESSION: same-assignee clock wrongly reset (%.0fs)" % _secs)
_st = {"first_seen_stranded": _NOW - 3000, "last_assignee": "wa-worker-adhoc-A"}
_secs, _ = m.update_strand_clock(_st, False, "wa-worker-adhoc-A", _NOW)
if _secs == 0.0 and "first_seen_stranded" not in _st:
    ok("live/branch (not stranded) resets clock to 0")
else:
    bad("not-stranded did not reset (%.0fs)" % _secs)

# ── Scenario 9 (ga-21kmp): every sub-query must emit --limit 0. `bd list --json`
# defaults to --limit 50 and truncates SILENTLY (no error, no envelope flag) —
# a gate-status label with 51+ active markers would drop the 51st+ out of the
# active source-bead set without either sub-query returning non-zero, so
# scenarios 3-6 above (which all key off returncode/JSON shape) cannot catch
# this failure mode at all. ──
print("Scenario 9 (ga-21kmp): every sub-query emits --limit 0 (no silent truncation)")
_captured_cmds = []
def _capture_run(cmd, capture_output=True, text=True, timeout=20):
    _captured_cmds.append(cmd)
    return FakeResult(0, "[]")
orig = m.subprocess.run
m.subprocess.run = _capture_run
try:
    m.list_gate_active_source_beads()
    _missing = [c for c in _captured_cmds
                if "--limit" not in c or c[c.index("--limit") + 1] != "0"]
    if _captured_cmds and not _missing:
        ok("all %d sub-queries include --limit 0" % len(_captured_cmds))
    elif not _captured_cmds:
        bad("no sub-queries were issued — cannot verify --limit 0 (test setup problem)")
    else:
        bad("%d/%d sub-queries missing --limit 0 — silent-truncation regression: %r" % (
            len(_missing), len(_captured_cmds), _missing))
finally:
    m.subprocess.run = orig

print("")
print("Results: %d passed, %d failed" % (PASS, FAIL))
if FAIL == 0:
    print("SELFTEST PASS"); sys.exit(0)
print("SELFTEST FAIL"); sys.exit(1)
PY
