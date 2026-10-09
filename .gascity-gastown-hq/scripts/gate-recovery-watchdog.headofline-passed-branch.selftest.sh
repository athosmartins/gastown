#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-clexh7 regression.
#
# BUG: the head-of-line REPAIR signal is a trailing run of 'Dispatcher sweep complete ... QUEUED
# (retry' lines on one branch. A branch that leaves that loop for review writes NO further
# 'sweep complete' line (its finalize line is 'Gate run complete', by design — ga-eqjo), so the
# run stayed "trailing" after the branch had been reviewed, PASSED and merged, and the watchdog
# dispatched a repair dog for it. Measured 29/09/2026: branch crew/wa-worker/wa-umpwj, two QUEUED
# sweeps (10:43, 10:47), admitted 10:54, Gate PASSED + FF-merge 11:07, and the next
# 'sweep complete' line was 11:12 (another branch) — the stale run was still the newest thing
# naming the branch when ga-d5xw8l was dispatched 6 minutes AFTER the pass. Second false
# dispatch for the same branch in ~25 minutes (ga-y5lsyr, then ga-d5xw8l).
#
# DESIGN UNDER TEST (two layers, ga-clexh7):
#   1. PURE scan: a later dispatcher line proving THE SAME branch has a gate-run ('Phase C: gate-run
#      … (branch=X)', 'Gate PASSED: branch=X', 'Gate run complete: … branch=X') ends its run.
#      Lines for OTHER branches, and lines that merely contain 'branch=', end nothing.
#   2. ARTIFACT check before spawn: the branch must still be an open gate-status:queued marker.
#      THREE states — a marker list that could not be READ is not 'read it, branch not queued', and
#      only the second suppresses the repair (this is the detector for a stuck gate: it must not go
#      quiet because its own read failed).
#
# Fixtures are VERBATIM lines from the live quality-gate-dispatcher.log (29/09/2026) for the incident
# branch. The producer-side drift guard renders the progress-line shapes straight from
# quality-gate-dispatcher.sh, so a renamed log line cannot silently reopen the hole.
#
# Scenarios 1-6 use only the pre-existing API on purpose, so this file run against the previous
# watchdog (WD_OVERRIDE) fails with the literal symptom, not with a missing-attribute error.
#
# Run: bash scripts/gate-recovery-watchdog.headofline-passed-branch.selftest.sh
#      WD_OVERRIDE=<other copy of the watchdog> bash ...   (prove it fails on older code)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
DISPATCHER="${DISPATCHER_OVERRIDE:-$SELF_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }
[ -f "$DISPATCHER" ] || { echo "FATAL: quality-gate-dispatcher.sh not found at $DISPATCHER"; exit 1; }

python3 - "$WD" "$DISPATCHER" <<'PY'
import importlib.util, json, os, re, sys, tempfile, time

# Hermetic: a stray override in the runner's env must not move the thresholds under test.
for k in list(os.environ):
    if k.startswith("GRW_HOL_"):
        del os.environ[k]

wd_path, dispatcher_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("grw", wd_path)
m = importlib.util.module_from_spec(spec)
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

# ── Verbatim fixtures (live dispatcher log, 29/09/2026, branch wa-umpwj) ─────
BR = "crew/wa-worker/wa-umpwj"
D = "[quality-gate-dispatcher] "
def L(t, body): return "[2026-09-29 %s] %s%s" % (t, D, body)
Q1 = L("10:43:04", "=== Dispatcher sweep complete: branch=%s verdict=QUEUED (retry 1/3, dead author) ===" % BR)
Q2 = L("10:47:10", "=== Dispatcher sweep complete: branch=%s verdict=QUEUED (retry 2/3, dead author) ===" % BR)
# What the dispatcher wrote between the last QUEUED sweep and the pass. The first two carry 'branch='
# (or the branch name) but are NOT progress lines — they must end nothing.
NOISE_MID = [
    L("10:54:07", "  branch=%s  bead_id=wa-umpwj  rig=whatsapp_automation  bead_rig=whatsapp_automation" % BR),
    L("10:54:18", "  Auto-merge success: crew/wa-worker/wa-umpwj pushed to 4bcd0eaea35bff0d09c841ac606c89e148f5a641"),
    L("10:54:29", "Gate-run size: gate_run=ga-3cv5wm bead=wa-umpwj files=5 lines=829"),
    "✓ Comment added to ga-jumir9 — reviewer-verdict: %s (reviewer 1/1)" % BR,
]
P_FLIGHT = L("10:57:58", "Phase C: gate-run ga-3cv5wm (branch=%s) still in flight (0/1 verdicts, 207s/2100s, anchor=task-sent+52s) — leaving for a future sweep." % BR)
P_DONE = L("11:06:27", "Phase C: gate-run ga-3cv5wm (branch=%s) complete — 1/1 verdicts, overall=PASS (elapsed 723s). Finalizing." % BR)
P_PASSED = L("11:07:05", "Gate PASSED: branch=%s tier=CODE merge_sha=4bcd0eaea35bff0d09c841ac606c89e148f5a641 elapsed=726s" % BR)
P_RUNDONE = L("11:07:07", "=== Gate run complete: gate_run=ga-3cv5wm branch=%s verdict=PASS elapsed=726s ===" % BR)
INCIDENT_TAIL = [P_FLIGHT, P_DONE, P_PASSED, P_RUNDONE]
# The next sweep-complete line in the real log (11:12:15) was another branch; the exact text is not
# needed — only that it names a different branch and is not a QUEUED-retry.
OTHER = "crew/wa-worker/wa-zzzzz"
OTHER_YIELDED = L("11:12:15", "=== Dispatcher sweep complete: branch=%s verdict=YIELDED (live sibling ga-hjlkv8, pre-rebase) ===" % OTHER)

MIN_R = m.HEADOFLINE_MIN_SWEEPS
CONFLICT = m.HOL_KIND_CONFLICT_RETRY

def with_log(lines, fn, age_sec=0):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "quality-gate-dispatcher.log")
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    t = time.time() - age_sec
    os.utime(p, (t, t))
    old = m.DISPATCH_LOG
    m.DISPATCH_LOG = p
    try:
        return fn()
    finally:
        m.DISPATCH_LOG = old

# ── 1. The real incident ────────────────────────────────────────────────────
print("Scenario 1: replay of the 29/09 incident (2 QUEUED-retry sweeps, then review + PASS + merge)")
still = [Q1, Q2]
check(m._scan_headofline(still) == (CONFLICT, BR, 2) and with_log(still, m.headofline_stall) == (BR, 2),
      "premise: while the branch is still being re-picked, the two sweeps ARE the repair signal (BR, 2)")
passed = [Q1, Q2] + NOISE_MID + INCIDENT_TAIL
check(m._scan_headofline(passed) == (None, None, 0),
      "the same two sweeps followed by admit + Phase C + Gate PASSED + Gate run complete → NO run "
      "(old code: still (conflict-retry, BR, 2))")
check(with_log(passed, m.headofline_stall) == (None, 0),
      "headofline_stall() through the I/O wrapper on a fresh log → (None, 0): no repair dog for a merged branch")
check(with_log(passed + [OTHER_YIELDED], m.headofline_stall) == (None, 0),
      "…and it stays (None, 0) once the next sweep line (another branch, 11:12) arrives")

# ── 2. Each progress line, on its own, ends the run ─────────────────────────
print("Scenario 2: any ONE progress line for the branch ends its run (the branch may leave by different doors)")
for name, line in (("Phase C … still in flight", P_FLIGHT), ("Phase C … complete", P_DONE),
                   ("Gate PASSED", P_PASSED), ("Gate run complete", P_RUNDONE)):
    check(m._scan_headofline([Q1, Q2, line]) == (None, None, 0), "[Q1, Q2, '%s'] → no run" % name)
PASSED_PILOT = L("11:07:05", "Gate PASSED (origin=Pilot): branch=%s tier=CODE merge_sha=abc elapsed=9s" % BR)
check(m._scan_headofline([Q1, Q2, PASSED_PILOT]) == (None, None, 0),
      "'Gate PASSED (origin=Pilot): branch=…' (the second emitter in the dispatcher) ends the run too")
PC_WARN = "[2026-09-29 11:00:00] [quality-gate-dispatcher] WARN: Phase C: gate-run ga-3cv5wm (branch=%s) TIMED OUT after 2100s (limit=2100s) with 0/1 verdicts. Treating as FAIL." % BR
check(m._scan_headofline([Q1, Q2, PC_WARN]) == (None, None, 0),
      "the WARN-prefixed Phase C line (timeout / dead reviewers) ends the run: the branch was admitted")
RUN_FAIL = L("11:20:00", "=== Gate run complete: gate_run=ga-3cv5wm branch=%s verdict=FAIL elapsed=900s ===" % BR)
check(m._scan_headofline([Q1, Q2, RUN_FAIL]) == (None, None, 0),
      "'Gate run complete … verdict=FAIL' ends the run as well (it is the 1:1 finalize line for a FAIL)")

# ── 3. Other branches' lines end nothing ────────────────────────────────────
print("Scenario 3: progress lines for OTHER branches, and mere 'branch=' noise, do not end the run")
def prog(b):
    return [L("10:50:00", "Phase C: gate-run ga-other (branch=%s) still in flight (0/1 verdicts, 10s/2100s, anchor=task-sent+52s) — leaving for a future sweep." % b),
            L("10:50:05", "Gate PASSED: branch=%s tier=CODE merge_sha=abc elapsed=9s" % b),
            L("10:50:06", "=== Gate run complete: gate_run=ga-other branch=%s verdict=PASS elapsed=9s ===" % b)]
check(m._scan_headofline([Q1, Q2] + prog(OTHER)) == (CONFLICT, BR, 2),
      "another branch's Phase C / PASSED / run-complete AFTER the sweeps: the wedge on BR is untouched → (BR, 2)")
check(m._scan_headofline([Q1] + prog(OTHER) + [Q2]) == (CONFLICT, BR, 2),
      "another branch's progress lines BETWEEN the two sweeps do not split the run → count 2")
check(m._scan_headofline([Q1, Q2] + NOISE_MID) == (CONFLICT, BR, 2),
      "the real mid-flow noise (branch= header, auto-merge line, Gate-run size, reviewer-verdict) is NOT a progress line")
LONGER = BR + "-2"
check(m._scan_headofline([Q1, Q2] + prog(LONGER)) == (CONFLICT, BR, 2),
      "a branch whose name merely STARTS with BR (%s) is a different branch — equality, not substring" % LONGER)
check(m._scan_headofline([Q1, Q2] + prog(BR[:-1])) == (CONFLICT, BR, 2),
      "…and a shorter prefix of BR is a different branch too")

# ── 4. A progress line splits episodes; a real re-wedge still fires ─────────
print("Scenario 4: a progress line between sweeps splits episodes — and a genuine re-wedge is still caught")
Q3 = L("12:10:00", "=== Dispatcher sweep complete: branch=%s verdict=QUEUED (retry 1/3, dead author) ===" % BR)
Q4 = L("12:14:00", "=== Dispatcher sweep complete: branch=%s verdict=QUEUED (retry 2/3, dead author) ===" % BR)
check(m._scan_headofline([Q1, Q2, P_RUNDONE, Q3]) == (CONFLICT, BR, 1),
      "2 sweeps, review, then 1 new sweep: the run is 1, not 3 (the earlier 2 are a past episode)")
check(with_log([Q1, Q2, P_RUNDONE, Q3], m.headofline_stall) == (None, 0),
      "…1 sweep is below HEADOFLINE_MIN_SWEEPS(=%d) → no repair" % MIN_R)
check(m._scan_headofline([Q1, Q2, P_RUNDONE, Q3, Q4]) == (CONFLICT, BR, 2),
      "2 sweeps, review (e.g. FAIL → re-queue), 2 NEW sweeps → (BR, 2): a branch that re-wedges after review is repaired")
check(with_log([Q1, Q2, P_RUNDONE, Q3, Q4], m.headofline_stall) == (BR, 2),
      "…through the I/O wrapper: the repair signal fires (the fix must not blind the detector)")

# ── 5. Stale / unreadable log semantics are unchanged ───────────────────────
print("Scenario 5: log freshness gate unchanged")
check(with_log(still, m.headofline_scan, age_sec=m.HEADOFLINE_LOG_FRESH_SEC + 60) == (m.HOL_KIND_UNKNOWN, None, 0),
      "a STALE log is still UNKNOWN, not 'no run'")
check(with_log(passed, m.headofline_scan) == (None, None, 0),
      "a fresh log that was READ and shows the branch merged is (None, None, 0) — a known 'no run', not UNKNOWN")

# ── 6. The non-repair (observe-only) kind gets the same protection ──────────
print("Scenario 6: the log-only 'queued-other' run also ends when the branch is merged")
CLEAN_V = "QUEUED (merge-tree proven clean, transient failures repeat, staying in bounded retry — ga-y5c29l)"
CLEAN = [L("09:%02d:00" % (40 + i), "=== Dispatcher sweep complete: branch=%s verdict=%s ===" % (BR, CLEAN_V)) for i in range(m.HEADOFLINE_NONREPAIR_MIN_SWEEPS)]
check(with_log(CLEAN, m.headofline_nonrepair) == (BR, len(CLEAN)),
      "premise: %d proven-clean sweeps on BR ARE the observe-only signal" % len(CLEAN))
check(with_log(CLEAN + INCIDENT_TAIL, m.headofline_nonrepair) == (None, 0),
      "…and after Gate PASSED for BR the observe-only signal stops too (no 'head-of-line' log line about a merged branch)")

# ── 7. Producer-side drift guard ────────────────────────────────────────────
print("Scenario 7: the progress lines the DISPATCHER emits are all recognised (rendered from the producer)")
have_api = all(hasattr(m, n) for n in ("_hol_progress_branch", "HOL_PROGRESS_RES", "_hol_queue_state",
                                        "hol_repair_verdict", "hol_branch_queue_state", "_queued_markers_read"))
check(have_api, "watchdog exposes _hol_progress_branch / HOL_PROGRESS_RES / _hol_queue_state / hol_repair_verdict / "
                "hol_branch_queue_state / _queued_markers_read (ga-clexh7 has landed)")
src = open(dispatcher_path, encoding="utf-8").read()
render = lambda s: re.sub(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*", "X", s)
shapes = []
for pat in (r'log "(Phase C: gate-run \$GATE_RUN_ID \(branch=\$BRANCH\)[^"]*)"',
            r'warn "(Phase C: gate-run \$GATE_RUN_ID \(branch=\$BRANCH\)[^"]*)"',
            r'log "(Gate PASSED(?: \(origin=Pilot\))?: branch=\$BRANCH[^"]*)"',
            r'log "(=== Gate run complete: gate_run=\$GATE_RUN_ID branch=\$BRANCH[^"]*)"'):
    shapes += re.findall(pat, src)
check(len(shapes) >= 6,
      "extracted %d progress-line shapes from quality-gate-dispatcher.sh (>=6: Phase C log/warn variants, both Gate PASSED, "
      "Gate run complete — so an empty extraction cannot pass vacuously)" % len(shapes))
if have_api:
    missed = [s for s in shapes if m._hol_progress_branch(render(s)) != "X"]
    check(not missed, "every extracted progress line names its branch through _hol_progress_branch%s"
                      % ("" if not missed else " — UNRECOGNISED: %r" % missed))
    check(any("origin=Pilot" in s for s in shapes),
          "the 'Gate PASSED (origin=Pilot)' variant is among the extracted shapes (the one the live log did not show)")

# ── 8. Artifact layer: three states ─────────────────────────────────────────
print("Scenario 8: marker check — 'could not read' is NOT 'read, not queued'")
if have_api:
    rows = [("ga-4pdlt8", BR, 1, ()), ("ga-other1", OTHER, 2, ())]
    check(m._hol_queue_state(rows, BR) == m.HOL_QUEUE_QUEUED, "branch has an open queued marker → queued")
    check(m._hol_queue_state(rows, "crew/wa-worker/wa-gone") == m.HOL_QUEUE_NOT_QUEUED,
          "list read, no marker for the branch → not-queued")
    check(m._hol_queue_state([], BR) == m.HOL_QUEUE_NOT_QUEUED, "list read and EMPTY → not-queued")
    check(m._hol_queue_state(None, BR) == m.HOL_QUEUE_UNKNOWN, "list could not be read (None) → unknown, NOT not-queued")
    check(len({m.HOL_QUEUE_QUEUED, m.HOL_QUEUE_NOT_QUEUED, m.HOL_QUEUE_UNKNOWN}) == 3, "the three states are distinct values")
    check(m.hol_repair_verdict(m.HOL_QUEUE_QUEUED) == "repair", "still queued → repair")
    check(m.hol_repair_verdict(m.HOL_QUEUE_NOT_QUEUED) == "skip:not-queued", "proven not queued → skip (the incident)")
    check(m.hol_repair_verdict(m.HOL_QUEUE_UNKNOWN) == "repair",
          "UNREADABLE marker list → repair still proceeds (unreadable must NOT suppress a real repair)")
    check(m.hol_repair_verdict("something-unexpected") == "repair",
          "an unrecognised state never suppresses either — only the proven not-queued does")

    class R:
        def __init__(self, rc, out): self.returncode, self.stdout = rc, out
    def marker_row(mid, status="open", branch=BR):
        return {"id": mid, "status": status, "labels": ["type:quality-gate-marker", "gate-status:queued", "branch:%s" % branch],
                "created_at": "2026-09-29T13:00:00Z"}
    real_sh = m.sh
    def with_sh(result, fn):
        m.sh = lambda *a, **k: result
        try:
            return fn()
        finally:
            m.sh = real_sh
    check(with_sh(R(1, ""), m._queued_markers_read) is None, "bd exits non-zero → _queued_markers_read() is None")
    check(with_sh(None, m._queued_markers_read) is None, "subprocess raised/timed out (sh() → None) → None")
    check(with_sh(R(0, "not json"), m._queued_markers_read) is None, "garbage output → None")
    check(with_sh(R(0, json.dumps({"error": "x"})), m._queued_markers_read) is None, "JSON that is not a list → None")
    check(with_sh(R(0, "[]"), m._queued_markers_read) == [], "empty list → [] (read fine, nothing queued) — NOT None")
    rd = with_sh(R(0, json.dumps([marker_row("ga-4pdlt8"), marker_row("ga-closed", status="closed")])), m._queued_markers_read)
    check(rd is not None and [r[0] for r in rd] == ["ga-4pdlt8"] and rd[0][1] == BR,
          "a valid list parses as before (closed marker with a stale queued label still filtered, branch label extracted)")
    check(not hasattr(m, "_queued_markers"),
          "the collapsing _queued_markers() wrapper is gone (ga-dtecvq): no caller may read an unreadable queue as an empty one")
    check(with_sh(R(0, json.dumps([marker_row("ga-4pdlt8")])), lambda: m.hol_branch_queue_state(BR)) == m.HOL_QUEUE_QUEUED,
          "end to end: an open queued marker for the branch → queued")
    check(with_sh(R(0, "[]"), lambda: m.hol_branch_queue_state(BR)) == m.HOL_QUEUE_NOT_QUEUED,
          "end to end: the incident (marker closed by the dispatcher, list empty) → not-queued")
    check(with_sh(R(1, ""), lambda: m.hol_branch_queue_state(BR)) == m.HOL_QUEUE_UNKNOWN,
          "end to end: bd failing → unknown")

# ── 9. Design pin: main() consults the artifact BEFORE spawning ─────────────
print("Scenario 9: main()'s head-of-line block checks the marker before governed_spawn, and the skip arm cannot spawn")
wd_src = open(wd_path, encoding="utf-8").read()
a = wd_src.find("HEAD-OF-LINE block (closes the ga-hl0gq blind spot")
b = wd_src.find("HEAD-OF-LINE, non-conflict QUEUED endings (ga-mlzqg4)", a if a >= 0 else 0)
check(a >= 0 and b > a, "found the head-of-line repair block boundaries in main() (non-vacuous slice)")
block = wd_src[a:b] if (a >= 0 and b > a) else ""
code = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
i_check = code.find("hol_repair_verdict(hol_branch_queue_state(hb))")
i_spawn = code.find("governed_spawn(")
check(i_check >= 0 and i_spawn > i_check,
      "the block calls hol_repair_verdict(hol_branch_queue_state(hb)) and only afterwards governed_spawn(")
i_else = code.find("else:", i_check) if i_check >= 0 else -1
skip_arm = code[i_check:i_else] if (i_check >= 0 and i_else > i_check) else ""
check(bool(skip_arm) and "governed_spawn(" not in skip_arm and "snapshot(" not in skip_arm and "notify(" not in skip_arm,
      "the skip arm (from the verdict to its `else:`) contains no governed_spawn( / snapshot( / notify( — it only logs")
check('!= "repair"' in code, "the skip arm is taken on `!= \"repair\"`, so UNKNOWN (which yields 'repair') falls through to the spawn")

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
