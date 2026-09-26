#!/usr/bin/env bash
# gate-recovery-watchdog.orphan-proof-tiered.selftest.sh (ga-yprwyk)
#
# BUG (measured 25/09/2026, found by ga-b1iulk when the detector's log reader was finally un-blinded):
# orphaned_queued_marker() flagged ga-b9pz7q — a marker 3.5h old at the head of a 32-deep queue — as
# "skipped by the dispatcher". The dispatcher claimed that very marker 3 minutes later, and every claim
# since the gate resumed had gone out in STRICT created_at order: a healthy queue draining, zero markers lost.
# Three independent defects in the proof ("the head's BRANCH is unmentioned in the log tail while a NEWER
# marker's branch IS mentioned"):
#   1. it assumed the dispatcher takes ONE marker per sweep, OLDEST-first. It is tiered
#      (quality-gate-dispatcher.sh, marker-select): overdue oldest-first -> ONE freshest reserve marker ->
#      priority [aged, smallest-diff] -> everyone else [aged, smallest-diff] -> rebase-fail. A newer marker
#      ahead of an older one is the design, not a fault, below the overdue ceiling.
#   2. it matched the BRANCH NAME as a substring of the last 3000 log lines — which also matches an EARLIER
#      attempt of the same branch. The marker ID is unique per attempt and does not.
#   3. in a deep queue every head is already older than ORPHAN_MIN_AGE_SEC when it reaches the front, so the
#      condition trips for every head in turn (each false positive would hold the single repair-dog slot a real
#      outage needs).
#
# THE PROOF NOW (see the watchdog's module docstring): only an OVERDUE head can be proven skipped, because tier 1
# is priority-blind oldest-first over every overdue healthy marker — so a marker created AFTER the head cannot be
# claimed while the head is eligible. Four groups below:
#   A. the premise, against the dispatcher's REAL marker-select block (extracted by its sentinels, never a copy);
#   B. the pure core: labels that legitimately sink a head, cooldown, log reach, witness rules, boundaries;
#   C. the overdue ceiling is DERIVED from the dispatcher (source + launchd env) and equals what bash computes;
#   D. end to end through orphaned_queued_marker() with a faked bd/launchctl: the 25/09 ga-b9pz7q shape stays
#      SILENT, a genuine skip is FLAGGED, the witness lookups are bounded and cached, "cannot prove" is NOTED.
#
# Group D is written against orphaned_queued_marker() alone (same public shape before and after this fix), so
#   WD_OVERRIDE=<older copy of the watchdog> bash ...      shows the false positive on the code before ga-yprwyk.
# Line FORMATS are verbatim from the live dispatcher log (25/09/2026); timestamps are relative to now.
#
# Run: bash scripts/gate-recovery-watchdog.orphan-proof-tiered.selftest.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SCRIPT_DIR/gate-recovery-watchdog.py}"
DISPATCHER="${DISPATCHER_OVERRIDE:-$SCRIPT_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 2; }
[ -f "$DISPATCHER" ] || { echo "FATAL: quality-gate-dispatcher.sh not found at $DISPATCHER"; exit 2; }

/usr/bin/python3 - "$WD" "$DISPATCHER" "$SCRIPT_DIR" <<'PY'
import contextlib, importlib.util, io, json, os, re, subprocess, sys, tempfile, time, shutil, atexit

wd_path, dispatcher, scripts_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, scripts_dir)
for k in list(os.environ):                      # hermetic: a stray override must not move the thresholds under test
    if k.startswith("GRW_") or k.startswith("GATE_"):
        del os.environ[k]

def load():
    spec = importlib.util.spec_from_file_location("grw_tiered", wd_path)
    mod = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["grw"]                          # __name__ != "__main__" -> main() never runs
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = saved
    return mod
m = load()

TMP = tempfile.mkdtemp(prefix="grw-tiered-")
atexit.register(shutil.rmtree, TMP, ignore_errors=True)

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)
def check(cond, msg):
    (ok if cond else bad)(msg)

HAVE_CORE = all(hasattr(m, n) for n in ("_orphan_verdict", "_dispatcher_claims", "_dispatcher_hard_age_from"))
def need_core(what):
    if not HAVE_CORE:
        bad("watchdog has no marker-id/tier-aware proof (_orphan_verdict & co) — %s cannot be checked (ga-yprwyk has not landed)" % what)
    return HAVE_CORE

NOW = time.time()
HARD = 5400                                     # the dispatcher's default ceiling: 3 x GATE_MARKER_AGE_PROMOTE_SECONDS (1800)
MARGIN = getattr(m, "ORPHAN_PROOF_MARGIN_SEC", 120)
def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
def fmt(t): return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
def dl(t, body): return "[%s] [quality-gate-dispatcher] %s" % (fmt(t), body)

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# A. The premise, against the dispatcher's REAL marker-select block
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group A: the proof's premise holds in the dispatcher's own marker-select block (extracted by sentinel, run under bash)")
block = subprocess.run(["sed", "-n", "/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p", dispatcher],
                       capture_output=True, text=True).stdout
check(bool(block.strip()), "located the live marker-select block via its sentinels")

def mk(mid, created, author="mila", labels=("gate-status:queued",)):
    return {"id": mid, "created_at": iso(created), "description": "branch: crew/%s/%s" % (author, mid), "labels": list(labels)}

def real_select(markers, now=NOW, env=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("GATE_")}
    e.update({"MARKERS_JSON": json.dumps(markers), "GATE_MARKER_NOW_OVERRIDE_EPOCH": str(int(now)),
              "GATE_MARKER_AGE_PROMOTE_SECONDS": "1800", "GATE_MARKER_HARD_AGE_SECONDS": str(HARD), "GATE_PRIORITY_AUTHORS": "oracle"})
    e.update(env or {})
    r = subprocess.run(["bash", "-c", block + '\necho "$MARKER_ID"'], env=e, capture_output=True, text=True)
    return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""

if block.strip():
    # A1: the exact shape of the false positive — an overdue healthy head and a FRESH priority marker behind it.
    sel = real_select([mk("head", NOW - 6000), mk("newer", NOW - 60, "oracle")])
    check(sel == "head", "overdue healthy head beats a fresh PRIORITY marker (got %r) — the ceiling is priority-blind, so a newer claim contradicts an eligible head" % sel)
    # A2: two overdue markers -> oldest first.
    sel = real_select([mk("newer-overdue", NOW - 6000), mk("head", NOW - 7000)])
    check(sel == "head", "of two overdue markers the OLDEST is selected (got %r) — a newer marker cannot precede it" % sel)
    # A3: a rebase-fail head legitimately loses (tier 7) — the watchdog must treat it as explained.
    sel = real_select([mk("head", NOW - 6000, labels=("gate-status:queued", "gate:exiled-tier5:2")), mk("newer", NOW - 60)])
    check(sel == "newer", "an exiled (gate:exiled-tier5) overdue head is legitimately passed over (got %r)" % sel)
    # A4: a head inside its retry cooldown is excluded from EVERY tier.
    sel = real_select([mk("head", NOW - 6000, labels=("gate-status:queued", "gate:retry-cooldown-until:%d" % (NOW + 600))), mk("newer", NOW - 60)])
    check(sel == "newer", "a head inside its retry cooldown is legitimately passed over (got %r)" % sel)
    # A5: a YOUNG head (aged but not overdue) is legitimately passed over by a fresh priority marker.
    sel = real_select([mk("head", NOW - 3000), mk("newer", NOW - 60, "oracle")])
    check(sel == "newer", "a head still under the ceiling loses to a fresh priority marker BY DESIGN (got %r) — no claim order proves a skip there" % sel)

    # the watchdog's verdict must AGREE with the dispatcher on each of those same fixtures
    if need_core("agreement with the real block"):
        def verdict(head_age, labels, claim_ago=300, hard=HARD):
            created = NOW - head_age
            markers = [("ga-head", "crew/x/head", created, tuple(labels))]
            return m._orphan_verdict(markers, [NOW - 60], [(NOW - claim_ago, "ga-newer")], NOW - 30000, hard,
                                     lambda x: {"ga-newer": NOW - head_age + 1800}.get(x), NOW)[1]
        check(verdict(6000, ["gate-status:queued"]) == "orphan", "overdue healthy head + a newer claim -> the watchdog flags it (the dispatcher would have picked the head: A1/A2)")
        check(verdict(6000, ["gate-status:queued", "gate:exiled-tier5:2"]) == "sunk-by-label", "exiled head -> the watchdog calls it explained (A3)")
        check(verdict(6000, ["gate-status:queued", "gate:retry-cooldown-until:%d" % (NOW + 600)]) == "no-witness", "head in cooldown at the claim -> the watchdog calls it explained (A4)")
        check(verdict(3000, ["gate-status:queued"]) == "young", "young head -> the watchdog does not call it skipped (A5)")

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# B. The pure core
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group B: pure core — sink labels, cooldown, log reach, witness rules, boundaries")
if need_core("group B"):
    OVERDUE = HARD + MARGIN
    HEAD_AGE = OVERDUE + 3600
    def core(labels=("gate-status:queued",), claims=None, created=None, first=NOW - 30000, hard=HARD, sweeps=None, head_age=HEAD_AGE, markers=None):
        markers = markers if markers is not None else [("ga-head", "crew/x/head", NOW - head_age, None if labels is None else tuple(labels))]
        claims = claims if claims is not None else [(NOW - 300, "ga-newer")]
        created = created if created is not None else {"ga-newer": NOW - head_age + 1800}
        return m._orphan_verdict(markers, [NOW - 60] if sweeps is None else sweeps, claims, first, hard, lambda x: created.get(x), NOW)

    check(core()[1] == "orphan" and core()[0][0] == "ga-head", "baseline: overdue head, never claimed, newer claim past the ceiling -> orphan")
    for lb in ("gate:rebase-attempt:1", "gate:exiled-tier5:2", "gate:rebase-fail-count:3", "gate:exiled-since:1790000000"):
        check(core(labels=("gate-status:queued", lb))[1] == "sunk-by-label", "label %s legitimately sinks the head -> silent" % lb)
    check(core(labels=("gate-status:queued", "gate:retry-cooldown-until:%d" % (NOW + 900)))[1] == "no-witness",
          "an UNEXPIRED retry cooldown explains the skip -> silent")
    check(core(labels=("gate-status:queued", "gate:retry-cooldown-until:%d" % (NOW - 7200)))[1] == "orphan",
          "an EXPIRED retry cooldown (before the witness claim) explains nothing -> still flagged")
    check(core(labels=None)[1] == "labels-unknown", "a marker tuple without labels cannot rule the sink labels out -> silent (old 3-tuple shape)")
    check(core(first=NOW - 1000)[1] == "log-coverage", "the log read starts AFTER the head was created -> 'never claimed' is unprovable -> silent")
    check(core(first=None)[1] == "log-coverage", "log reach unknown (no timestamped line) -> silent")
    check(core(hard=None)[1] == "tunables", "the dispatcher's ceiling is unknown -> silent, never guessed")
    check(core(claims=[])[1] == "no-witness", "no claims at all -> nothing proves a skip -> silent")
    check(core(claims=[(NOW - 300, "ga-head"), (NOW - 200, "ga-newer")])[1] == "claimed", "the head's own id has a claim line -> attempted, not an orphan")
    check(core(created={"ga-newer": NOW - HEAD_AGE})[1] == "no-witness", "a claimed marker created the SAME second is not strictly newer -> ambiguous sort order -> silent")
    check(core(created={"ga-newer": NOW - HEAD_AGE - 60})[1] == "no-witness", "a claimed OLDER marker is FIFO, not a skip -> silent")
    check(core(created={})[1] == "no-witness", "the claimed marker's created_at could not be learned -> silent (inert)")
    head_created = NOW - HEAD_AGE
    check(core(claims=[(head_created + OVERDUE - 5, "ga-newer")])[1] == "no-witness",
          "a claim BEFORE the head was provably overdue (ceiling + margin) is not a witness")
    check(core(claims=[(head_created + OVERDUE + 5, "ga-newer")])[1] == "orphan", "a claim just AFTER ceiling + margin is a witness")
    check(core(head_age=OVERDUE - 1)[1] == "young" and core(head_age=OVERDUE + 1)[1] != "young", "the overdue boundary is ceiling + margin (strict)")
    check(core(sweeps=[NOW - m.ORPHAN_DRAIN_FRESH_SEC - 600])[1] == "no-candidate", "dispatcher not draining -> no candidate")
    # a witness anywhere in the window counts, and the claims need not arrive sorted
    older_then_newer = [(NOW - 100, "ga-old2"), (NOW - 900, "ga-newer"), (NOW - 500, "ga-old1")]
    cr = {"ga-newer": NOW - HEAD_AGE + 1800, "ga-old1": NOW - HEAD_AGE - 900, "ga-old2": NOW - HEAD_AGE - 300}
    check(core(claims=older_then_newer, created=cr)[1] == "orphan", "one skipped sweep among FIFO claims is enough, whatever the input order")
    # only the FIFO head is evaluated
    two = [("ga-a", "crew/x/a", NOW - HEAD_AGE, ("gate-status:queued", "gate:exiled-tier5:1")), ("ga-b", "crew/x/b", NOW - HEAD_AGE + 600, ("gate-status:queued",))]
    check(core(markers=two)[1] == "sunk-by-label", "head-only: the sunk head decides; the marker behind it is never reported")
    # the evidence names the witness
    ev = core()[2]
    check("ga-newer" in ev and "never claimed" in ev, "the evidence names the witness marker and the never-claimed fact")
    # claim parsing is anchored to the dispatcher's own line prefix
    live_line = "[2026-09-25 19:30:55] [quality-gate-dispatcher] Attempting to claim marker ga-b9pz7q ..."     # verbatim from the live log
    quoted = "    reviewer said: [2026-09-25 19:30:55] [quality-gate-dispatcher] Attempting to claim marker ga-fake ..."
    tail_text = "prefix Attempting to claim marker ga-fake2 ..."
    got = m._dispatcher_claims([live_line, quoted, tail_text, "[2026-09-25 19:30:56] [quality-gate-dispatcher] Attempting to claim marker ga-x"])
    check([x for _t, x in got] == ["ga-b9pz7q"], "only a line that STARTS with the dispatcher prefix and ends '<id> ...' is a claim (got %r)" % ([x for _t, x in got],))
    check(m._log_first_epoch(["  partial continuation line", "no timestamp here", live_line]) == m.log_ts_epoch(live_line),
          "log reach = the first well-formed dispatcher line, skipping a partial first line")

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# C. The ceiling is DERIVED from the dispatcher, and equals what bash computes
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group C: the overdue ceiling is derived from the dispatcher source + launchd env, and matches bash")
if need_core("group C"):
    src = open(dispatcher, encoding="utf-8", errors="replace").read()
    NO_ENV = "\tenvironment = {\n\t\tGATE_CODE_REVIEWERS => 1\n\t}\n"
    check(m._dispatcher_hard_age_from(src, NO_ENV) == HARD, "the real dispatcher source with no override -> %ds (got %r)" % (HARD, m._dispatcher_hard_age_from(src, NO_ENV)))
    check(m._dispatcher_hard_age_from(src, None) is None, "launchd environment unreadable -> None (an override cannot be ruled out)")
    check(m._dispatcher_hard_age_from("", NO_ENV) is None, "dispatcher source unreadable -> None")
    check(m._dispatcher_hard_age_from("GATE_MARKER_AGE_PROMOTE_SECONDS=1800\n", NO_ENV) is None, "the preamble changed shape -> None (never a guess)")
    # bash is the oracle: evaluate the dispatcher's own preamble assignments under each override and compare
    preamble = block.split('MARKER=$(printf', 1)[0] if block else ""
    def bash_ceiling(env):
        e = {k: v for k, v in os.environ.items() if not k.startswith("GATE_")}
        e.update(env)
        r = subprocess.run(["bash", "-c", preamble + '\necho "$GATE_MARKER_HARD_AGE_SECONDS"'], env=e, capture_output=True, text=True)
        return int(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else None
    def launchd_text(env):
        return "\tinherited environment = {\n\t\tPATH => /usr/bin\n\t}\n\tenvironment = {\n" + "".join("\t\t%s => %s\n" % kv for kv in env.items()) + "\t}\n"
    for label, env in [("no override", {}), ("PROMOTE=600", {"GATE_MARKER_AGE_PROMOTE_SECONDS": "600"}),
                       ("HARD=7200", {"GATE_MARKER_HARD_AGE_SECONDS": "7200"}),
                       ("PROMOTE=900 + HARD=3000", {"GATE_MARKER_AGE_PROMOTE_SECONDS": "900", "GATE_MARKER_HARD_AGE_SECONDS": "3000"}),
                       ("HARD non-numeric", {"GATE_MARKER_HARD_AGE_SECONDS": "abc"}),
                       ("PROMOTE non-numeric + HARD unset", {"GATE_MARKER_AGE_PROMOTE_SECONDS": "x9"}),
                       ("HARD empty", {"GATE_MARKER_HARD_AGE_SECONDS": ""})]:
        want, got = bash_ceiling(env), m._dispatcher_hard_age_from(src, launchd_text(env))
        check(want is not None and want == got, "%s: python derives %r, the dispatcher's own bash computes %r" % (label, got, want))
    two_seen = "\tinherited environment = {\n\t\tGATE_MARKER_HARD_AGE_SECONDS => 1111\n\t}\n\tenvironment = {\n\t\tGATE_MARKER_HARD_AGE_SECONDS => 2222\n\t}\n"
    check(m._dispatcher_hard_age_from(src, two_seen) == 2222, "the job's own environment (listed last) wins over the inherited one")

    # drift guards: the proof leans on these exact facts about the dispatcher
    claim_at = src.find('log "Attempting to claim marker $MARKER_ID ..."')
    end_at = src.find("# SELFTEST-EXTRACT marker-select: END")
    check(0 < end_at < claim_at and claim_at - end_at < 400,
          "the claim line the watchdog parses is still logged right after the marker-select block")
    check("def is_overdue: try (($now - (.created_at | fromdateiso8601)) > $hard_threshold) catch false;" in block, "is_overdue is still 'age > hard ceiling' on created_at")
    check("(map(select((is_overdue and (has_rebase_fail | not)) or (has_rebase_fail and exile_overdue))) | sort_by(.created_at))" in block,
          "tier 1 is still oldest-first over overdue healthy markers — the fact the whole proof rests on")
    check("map(select(in_retry_cooldown | not))" in block and 'test("^gate:(rebase-attempt|exiled-tier5):[0-9]+$")' in block,
          "the sink states (cooldown, rebase-attempt / exiled-tier5) are still the ones the watchdog exempts")

# ═════════════════════════════════════════════════════════════════════════════════════════════════════
# D. End to end through orphaned_queued_marker() with a faked bd / launchctl
# ═════════════════════════════════════════════════════════════════════════════════════════════════════
print("Group D: end to end — the 25/09 ga-b9pz7q shape is SILENT; a genuine skip is FLAGGED")

CP = subprocess.CompletedProcess
class World(object):
    """A fake bd + launchctl + dispatcher log. Both the old and the new watchdog talk to the world through m.sh."""
    def __init__(self, queue, show=None, launchd=None):
        self.queue, self.show, self.launchd, self.show_calls = queue, show or {}, launchd, 0
    def sh(self, args, timeout=20, stdin=None):
        if args and args[0] == "launchctl":
            return CP(args, 0, self.launchd, "") if self.launchd is not None else CP(args, 113, "", "Could not find service")
        if len(args) > 4 and args[0] == "bash" and args[2] == "-C":
            sub = args[4]
            if sub == "list":
                return CP(args, 0, json.dumps(self.queue), "")
            if sub == "show":
                self.show_calls += 1
                row = self.show.get(args[5])
                return CP(args, 0 if row else 1, json.dumps([row]) if row else "", "")
        return None

def qrow(mid, branch, created, labels=()):
    return {"id": mid, "status": "open", "created_at": iso(created),
            "labels": ["type:quality-gate-marker", "gate-status:queued", "branch:%s" % branch] + list(labels)}
def showrow(mid, created):
    return {"id": mid, "status": "closed", "created_at": iso(created), "labels": ["type:quality-gate-marker"]}

LAUNCHD_OK = "\tenvironment = {\n\t\tGATE_CODE_REVIEWERS => 1\n\t}\n"
HEAD, HEAD_BR, HEAD_AGE_S = "ga-b9pz7q", "crew/wa-worker/wa-yzump", 12564          # the 25/09 head: created 3.5h before it was flagged
NEXT, NEXT_BR = "ga-tdvx81", "crew/wa-worker/wa-o7vbh"                            # the next one in the queue

def write_log(name, lines):
    p = os.path.join(TMP, name)
    with open(p, "wb") as f:
        f.write(("\n".join(lines) + "\n").encode("utf-8"))
    return p

def run_world(world, log_path):
    """One poll of orphaned_queued_marker() against the world; returns (result, stdout)."""
    for c in (getattr(m, "_HARD_AGE_CACHE", None),):
        if c is not None:
            c.update({"at": 0.0, "value": None})
    for c in (getattr(m, "_MARKER_CREATED_CACHE", None), getattr(m, "_ORPHAN_NOTED", None), getattr(m, "_ORPHAN_EVIDENCE", None)):
        if c is not None:
            c.clear()
    return _poll(world, log_path)

def _poll(world, log_path):
    saved = (m.sh, m.DISPATCH_LOG, getattr(m, "DISPATCHER_SRC", None))
    m.sh, m.DISPATCH_LOG = world.sh, log_path
    if hasattr(m, "DISPATCHER_SRC"):
        m.DISPATCHER_SRC = dispatcher            # hermetic: derive the ceiling from THIS branch's dispatcher, not the live checkout
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            res = m.orphaned_queued_marker()
    except Exception as e:
        res = ("EXC", repr(e), 0)
    finally:
        m.sh, m.DISPATCH_LOG = saved[0], saved[1]
        if saved[2] is not None:
            m.DISPATCHER_SRC = saved[2]
    return res, buf.getvalue()

# The queue as bd sees it at the flagging instant: the head, the next marker, and a few more. Older markers were
# already claimed (no longer queued), in strict created_at order — exactly the 25/09 drain.
H_CREATED = NOW - HEAD_AGE_S
queue = [qrow(HEAD, HEAD_BR, H_CREATED), qrow(NEXT, NEXT_BR, H_CREATED + 180)] + \
        [qrow("ga-q%d" % i, "crew/wa-worker/wa-q%d" % i, H_CREATED + 360 + 180 * i) for i in range(6)]
older_claimed = [("ga-o%d" % i, NOW - (HEAD_AGE_S + 4000 - 700 * i)) for i in range(5)]     # created BEFORE the head
def healthy_log(name, extra=()):
    lines = [dl(NOW - 30000, "Found 32 queued marker(s)"),
             # defect #2: an EARLIER attempt of the next marker's branch, from before the head existed. The old proof
             # read this as 'a newer marker is being dispatched'.
             dl(NOW - 26000, "=== Dispatcher sweep complete: branch=%s verdict=FAILED ===" % NEXT_BR)]
    for i, (mid, created) in enumerate(older_claimed):
        t = NOW - 3600 + 600 * i
        lines += [dl(t, "Found 32 queued marker(s)"), dl(t + 50, "Attempting to claim marker %s ..." % mid),
                  dl(t + 400, "=== Dispatcher sweep complete: branch=crew/x/done%d verdict=PASSED ===" % i)]
    return write_log(name, lines + list(extra) + [dl(NOW - 60, "=== Dispatcher sweep complete: branch=crew/x/last verdict=PASSED ===")])
SHOW = dict((mid, showrow(mid, c)) for mid, c in older_claimed)

# D1 — the ga-b9pz7q false positive: silent
world = World(queue, SHOW, LAUNCHD_OK)
res, out = run_world(world, healthy_log("healthy.log"))
check(res == (None, None, 0),
      "25/09 shape: 3.5h-old head, dispatcher draining strictly oldest-first, an earlier attempt of the next branch in the log -> SILENT (got %r%s)"
      % (res, "  <- the old proof flags it" if res[0] == HEAD else ""))

# D2 — a genuine skip: the dispatcher claimed the NEXT marker (created after the head) while the head was overdue
world = World(queue, SHOW, LAUNCHD_OK)
res, out = run_world(world, healthy_log("skip.log", [dl(NOW - 400, "Attempting to claim marker %s ..." % NEXT)]))
check(res[0] == HEAD and res[1] == HEAD_BR and abs(res[2] - HEAD_AGE_S) < 5,
      "the dispatcher claimed a NEWER marker (%s) while the head was 3.5h overdue and never claimed -> FLAGGED (got %r)" % (NEXT, res))
if HAVE_CORE:
    check(NEXT in m._ORPHAN_EVIDENCE.get(HEAD, ""), "the evidence recorded for the hit names the witness marker")

# D2b — the witness is no longer queued: its created_at is learned through `bd show`
gone = "ga-gone1"
world = World(queue, dict(SHOW, **{gone: showrow(gone, H_CREATED + 1000)}), LAUNCHD_OK)
res, out = run_world(world, healthy_log("skip-gone.log", [dl(NOW - 400, "Attempting to claim marker %s ..." % gone)]))
check(res[0] == HEAD and world.show_calls >= 1, "a witness that left the queue is resolved with bd show (calls=%d) -> FLAGGED (got %r)" % (world.show_calls, res))

# D3 — the head itself has a claim line -> attempted -> silent, even with a newer claim after it
world = World(queue, SHOW, LAUNCHD_OK)
res, out = run_world(world, healthy_log("claimed.log", [dl(NOW - 900, "Attempting to claim marker %s ..." % HEAD), dl(NOW - 400, "Attempting to claim marker %s ..." % NEXT)]))
check(res == (None, None, 0), "the head has its own claim line in the log -> silent (got %r)" % (res,))

if HAVE_CORE:
    # D4 — witness lookups: bounded per poll, and cached across polls (a marker's created_at never changes)
    many = [("ga-m%02d" % i, H_CREATED - 20000 + 300 * i) for i in range(40)]          # 40 claimed markers, all OLDER than the head
    lines = [dl(NOW - 30000, "Found 32 queued marker(s)")]
    for i, (mid, c) in enumerate(many):
        lines.append(dl(NOW - 6000 + 100 * i, "Attempting to claim marker %s ..." % mid))
    lines.append(dl(NOW - 60, "=== Dispatcher sweep complete: branch=crew/x/last verdict=PASSED ==="))
    p = write_log("many.log", lines)
    world = World(queue, dict((mid, showrow(mid, c)) for mid, c in many), LAUNCHD_OK)
    res, out = run_world(world, p)
    check(res == (None, None, 0) and world.show_calls == m.ORPHAN_WITNESS_LOOKUPS,
          "a healthy queue with 40 older claims: silent, and the first poll spends exactly ORPHAN_WITNESS_LOOKUPS=%d bd show calls (got calls=%d)" % (m.ORPHAN_WITNESS_LOOKUPS, world.show_calls))
    world.show_calls = 0
    res, out = _poll(world, p)
    check(res == (None, None, 0) and world.show_calls == 40 - m.ORPHAN_WITNESS_LOOKUPS,
          "the second poll only looks up the markers it has not seen (calls=%d, want %d)" % (world.show_calls, 40 - m.ORPHAN_WITNESS_LOOKUPS))
    world.show_calls = 0
    res, out = _poll(world, p)
    check(res == (None, None, 0) and world.show_calls == 0, "the third poll costs zero bd calls: every created_at is cached (calls=%d)" % world.show_calls)

    # D5 — 'cannot prove' is NOTED, once, not silent (a quiet detector that cannot decide reads as 'no orphan')
    world = World(queue, SHOW, None)                                            # launchctl print fails
    res, out = run_world(world, healthy_log("notunables.log", [dl(NOW - 400, "Attempting to claim marker %s ..." % NEXT)]))
    check(res == (None, None, 0) and "orphan-proof unavailable (tunables)" in out,
          "launchctl unreadable -> no proof, and the reason is printed (got %r, out=%r)" % (res, out.strip()[:120]))
    res2, out2 = _poll(world, healthy_log("notunables2.log", [dl(NOW - 400, "Attempting to claim marker %s ..." % NEXT)]))
    check(res2 == (None, None, 0) and out2 == "", "the same note is not repeated on the next poll (rate-limited)")

    world = World(queue, SHOW, LAUNCHD_OK)                                      # log starts after the head was created
    p = write_log("shortreach.log", [dl(NOW - 3000, "Found 32 queued marker(s)"), dl(NOW - 400, "Attempting to claim marker %s ..." % NEXT),
                                     dl(NOW - 60, "=== Dispatcher sweep complete: branch=crew/x/last verdict=PASSED ===")])
    res, out = run_world(world, p)
    check(res == (None, None, 0) and "orphan-proof unavailable (log-coverage)" in out,
          "a log that does not reach back to the head's creation -> no proof, and it says so (got %r)" % (res,))

    # D5c — the wide claim-history read fails after the narrow state read succeeded: silent result, but NOTED
    world = World(queue, SHOW, LAUNCHD_OK)
    real_reader = m._read_log_last_lines
    def flaky_reader(path, n):
        if n == m.ORPHAN_CLAIM_TAIL_LINES:
            raise OSError("simulated I/O failure")
        return real_reader(path, n)
    m._read_log_last_lines = flaky_reader
    try:
        res, out = run_world(world, healthy_log("readfail.log", [dl(NOW - 400, "Attempting to claim marker %s ..." % NEXT)]))
    finally:
        m._read_log_last_lines = real_reader
    check(res == (None, None, 0) and "orphan-proof unavailable (log-read)" in out,
          "the claim-history read failing is inert AND noted, never a silent 'no orphan' (got %r, out=%r)" % (res, out.strip()[:110]))

    # D5d — `bd show` fails for the claimed marker: inert, but 'could not learn' must be NOTED, not read as 'not newer'
    world = World(queue, {}, LAUNCHD_OK)                                        # no show rows -> every lookup returns rc=1
    res, out = run_world(world, healthy_log("showfail.log"))
    check(res == (None, None, 0) and world.show_calls >= 1 and "orphan-proof unavailable (witness-lookup)" in out,
          "bd show failing for the claimed markers is inert AND noted (calls=%d, got %r, out=%r)" % (world.show_calls, res, out.strip()[:110]))

    # D6 — a young head with a newer claim (the tiered design) stays silent end to end
    young_q = [qrow("ga-young", "crew/x/young", NOW - 3000), qrow(NEXT, NEXT_BR, NOW - 2000)]
    world = World(young_q, SHOW, LAUNCHD_OK)
    res, out = run_world(world, write_log("young.log", [dl(NOW - 30000, "Found 3 queued marker(s)"), dl(NOW - 100, "Attempting to claim marker %s ..." % NEXT),
                                                          dl(NOW - 60, "=== Dispatcher sweep complete: branch=crew/x/last verdict=PASSED ===")]))
    check(res == (None, None, 0), "a 50-minute-old head with a NEWER marker claimed (priority / freshest-reserve, by design) -> silent (got %r)" % (res,))

print("\nPASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
