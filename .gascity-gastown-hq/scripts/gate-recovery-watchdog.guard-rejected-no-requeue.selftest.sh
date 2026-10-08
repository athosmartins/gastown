#!/usr/bin/env bash
# Selftest for gate-recovery-watchdog.py — ga-hp4wrx regression only.
#
# BUG: FIX 2 (requeue_error_markers) re-queues ANY gate-status:error marker that sat in
# error past ERROR_REQUEUE_MINUTES, on the premise that the error was a TRANSIENT
# dispatcher/ghost-yield/reclaim hiccup. A marker the GUARD rejected on purpose
# ("Gate guard rejected marker: invalid/unsafe field values" — or the coherence / base-test /
# bash-3.2 checks, all of which tell the author to fix and re-run /gate-done) is not transient:
# nothing about it changes by itself. Measured 08/10, marker ga-xj6rp0: the guard rejected
# bead_id wa-d3ys32.2.1 at 12:28Z, the watchdog "auto-requeued" it at 12:40Z, so it burned up
# to ERROR_REQUEUE_MAX_ATTEMPTS (3) requeues before the oscillation page — late, and with the
# real reason (a field the submitter must fix) buried. Worse, error→queued hands the marker to
# the DISPATCHER, which never re-runs the guard's checks: the same shape as ga-h3cje3, where a
# refused diff was requeued and merged. The E11 refusal already escapes this through its
# gate-guard:refused-e11 label; the other refusals only leave a COMMENT.
#
# FIX: before the requeue, read the marker's comments (a THREE-state read: rejected / none /
# could-not-read). rejected → no requeue; tell the author ONCE (nudge, else mail the Mayor) and
# stamp a durable label so the next sweep is silent. could-not-read → no requeue either (inert
# under doubt) plus one batched alarm. none → today's behavior, untouched.
#
# These scenarios drive error_requeue_verdict(), guard_rejection_from_comments_json() and
# requeue_error_markers() against synthetic fixtures with sh() mocked — no live Dolt, no gc.
# The last block is a CONTRACT check against the real quality-gate-guard.sh: the watchdog matches
# the guard's comment text, so the two cannot be allowed to drift apart unnoticed.
#
# NOT a general test harness for this file — scoped narrowly to this one bug, same convention as
# gate-recovery-watchdog.stuck-dispatching-dead-regex.selftest.sh.
#
# Run: bash scripts/gate-recovery-watchdog.guard-rejected-no-requeue.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
GUARD="${GUARD_OVERRIDE:-$SELF_DIR/../packs/town-deltas/assets/quality-gate-guard.sh}"
[ -f "$WD" ] || { echo "FATAL: gate-recovery-watchdog.py not found at $WD"; exit 1; }

python3 - "$WD" "$GUARD" <<'PY'
import importlib.util, sys, time, json, re, subprocess

spec = importlib.util.spec_from_file_location("grw", sys.argv[1])
m = importlib.util.module_from_spec(spec)
GUARD_PATH = sys.argv[2]
sys.argv = ["grw"]                      # __name__ != "__main__" → main() never runs
spec.loader.exec_module(m)

PASS = FAIL = 0
def ok(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1; print("  ok: %s" % msg)
    else:
        FAIL += 1; print("  BAD: %s" % msg)

E = 8 * 60
REJ_TEXT = ("Gate guard rejected marker: invalid/unsafe field values.\n"
            "branch='crew/wa-worker/wa-d3ys32.2.1' bead_id='wa-d3ys32.2.1' rig='whatsapp_automation'\n"
            "Marker set to gate-status:error. Fix the marker fields and re-submit.")
REQ_TEXT = ("gate-recovery-watchdog: auto-requeued gate-status:error→queued after 10m stuck in error "
            "(attempt 1/3). A transient dispatcher error/ghost-yield/reclaim left this marker stranded.")

def comments(*texts):
    return json.dumps([{"id": "c%d" % i, "issue_id": "ga-x", "author": "Test", "text": t,
                        "created_at": "2026-10-08T12:%02d:00Z" % i} for i, t in enumerate(texts)])

# ── 1. The pure verdict ──────────────────────────────────────────────────────────────────
print("[1] error_requeue_verdict: a guard rejection is never a requeue")
def verdict(age=E + 120, resolved=True, closed=False, needs_human=False, req=0, branch_state="unknown",
            refused=False, **kw):
    try:
        return m.error_requeue_verdict(age, E, resolved, closed, needs_human, req, 3, branch_state,
                                       guard_refused=refused, **kw)
    except TypeError as e:              # pre-fix signature has no guard_rejection: a FAIL, not a crash
        return "TypeError: %s" % e

ok(verdict(guard_rejection="rejected") == "escalate:guard-rejected",
   "rejected + past grace → escalate:guard-rejected, NOT requeue (the ga-xj6rp0 shape)")
ok(verdict(guard_rejection="rejected", req=3) == "escalate:guard-rejected",
   "rejected + requeue budget already spent → still the REAL reason, not 'oscillating'")
ok(verdict(guard_rejection="unknown") == "hold:rejection-unknown",
   "could-not-read → hold (inert under doubt), not requeue")
ok(verdict(guard_rejection="unknown", req=3) == "hold:rejection-unknown",
   "could-not-read + budget spent → hold, not a mail that blames oscillation")
ok(verdict(guard_rejection="none") == "requeue", "comments read, no rejection → today's requeue (control)")
ok(verdict() == "requeue", "param omitted → today's behavior (existing callers unchanged)")
ok(verdict(guard_rejection="none", req=3) == "escalate:oscillating", "no rejection + budget spent → oscillating, as before")
ok(verdict(age=60, guard_rejection="rejected") == "skip:young", "rejected but still inside the grace period → skip:young")
ok(verdict(needs_human=True, guard_rejection="rejected") == "skip:parked-needs-human",
   "rejected + source parked for a human → the park wins (a human already owns it)")
ok(verdict(closed=True, branch_state="merged", guard_rejection="rejected") == "close:source-done",
   "rejected but the work already landed (merged) → close:source-done still comes first")
ok(verdict(refused=True, guard_rejection="rejected") == "close:guard-refused",
   "E11 label refusal keeps its own close path ahead of the comment-based one")

# ── 2. The three-state comment reader (pure) ─────────────────────────────────────────────
print("[2] guard_rejection_from_comments_json: tem / não-tem / não-consegui-saber")
f = getattr(m, "guard_rejection_from_comments_json", None)
ok(callable(f), "guard_rejection_from_comments_json exists")
if callable(f):
    st, txt = f(comments(REJ_TEXT, REQ_TEXT))
    ok(st == "rejected", "the real ga-xj6rp0 comments → rejected")
    ok("wa-d3ys32.2.1" in txt and txt.startswith("Gate guard rejected marker:"),
       "the rejection text is handed back whole, so the author is told the actual fields")
    ok(f(comments(REQ_TEXT, "outro comentario"))[0] == "none", "readable comments, none is a rejection → none")
    ok(f("[]")[0] == "none", "readable empty list → none (a marker with no comments is not 'unreadable')")
    ok(f(comments("Retirado: o validate_bead_id do guard recusa; ver 'Gate guard rejected marker: ...' no log"))[0] == "none",
       "a comment that merely QUOTES the phrase mid-text is not a guard rejection")
    for variant in ("Gate guard rejected marker: branch-content-coherence check (ga-pj5va).\nNone of the 2 commit(s)...",
                    "Gate guard rejected marker: base-commit test check (ga-rstae, A/B experiment arm B).\n...",
                    "Gate guard rejected marker: bash-3.2 syntax check (ga-7dx2vw).\n..."):
        ok(f(comments(variant))[0] == "rejected", "same family, same verdict: %s" % variant.split("(")[0].strip())
    ok(f("")[0] == "unknown", "empty stdout → unknown (never 'none')")
    ok(f("not json at all")[0] == "unknown", "garbage → unknown")
    ok(f("null")[0] == "unknown", "JSON null → unknown")
    ok(f('{"comments": []}')[0] == "unknown", "a shape we do not recognise → unknown")
    ok(f(json.dumps(["texto solto"]))[0] == "unknown", "a list of non-objects → unknown")
    ok(f(json.dumps([{"id": "c1", "author": "x"}]))[0] == "unknown", "a comment with no text field → cannot tell → unknown")
    ok(f(json.dumps([{"id": "c1"}, {"text": REJ_TEXT}]))[0] == "rejected",
       "a positive is a positive even when a sibling comment is malformed")
    ok(f(None)[0] == "unknown", "None → unknown")

# ── 3. requeue_error_markers end to end (sh mocked) ──────────────────────────────────────
print("[3] requeue_error_markers: sweep behaviour")
NOW = time.time()

class CP:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err

class World:
    def __init__(self, comments_out=None, comments_rc=0, nudge_rc=0, mail_rc=0, label_rc=0):
        self.calls = []; self.statuses = []; self.notifies = []; self.ledger = []
        self.comments_out = comments_out; self.comments_rc = comments_rc
        self.nudge_rc = nudge_rc; self.mail_rc = mail_rc; self.label_rc = label_rc
    def sh(self, args, timeout=20, stdin=None):
        args = list(args); self.calls.append(args)
        if self.comments_rc is None and "comments" in args:
            return None
        if "comments" in args:
            return CP(self.comments_rc, self.comments_out if self.comments_out is not None else "[]")
        if "nudge" in args:
            return CP(self.nudge_rc)
        if "mail" in args:
            return CP(self.mail_rc)
        if "label" in args and "add" in args:
            return CP(self.label_rc)
        return CP(0)
    def find(self, *needles):
        return [c for c in self.calls if all(n in c for n in needles)]

def marker(mid="ga-mk1", labels=None, author="wa-worker-1"):
    meta = {m.GRW_STATUS_ANCHOR_KEY: "error@%d" % (NOW - 3600)}
    if author:
        meta["gate.submitted_by"] = author
    return {"id": mid, "created_at": "2026-10-08T12:28:00Z", "metadata": meta,
            "labels": ["type:quality-gate-marker", "gate-status:error", "source-bead:wa-d3ys32.2.1",
                       "bead-rig:whatsapp_automation", "branch:crew/wa-worker/wa-d3ys32.2.1"] + (labels or [])}

SAVED = {k: getattr(m, k) for k in ("sh", "_open_error_markers", "_source_bead_state", "set_gate_status_py",
                                    "notify", "_recovery_ledger", "GRW_DRY_RUN", "GRW_ENABLED",
                                    "GRW_REQUEUE_ERROR_ENABLED")}
def sweep(world, markers, rstate=None, dry=False):
    rstate = rstate or m.RecoveryState()
    m.sh = world.sh
    m._open_error_markers = lambda: markers
    m._source_bead_state = lambda *a, **k: (True, False, False)     # source open, not parked
    m.set_gate_status_py = lambda mid, st: world.statuses.append((mid, st))
    m.notify = lambda msg, prio: world.notifies.append((msg, prio))
    m._recovery_ledger = lambda ev, fields: world.ledger.append((ev, fields))
    m.GRW_DRY_RUN = dry; m.GRW_ENABLED = True; m.GRW_REQUEUE_ERROR_ENABLED = True
    try:
        m.requeue_error_markers(NOW, rstate)
    finally:
        for k, v in SAVED.items():
            setattr(m, k, v)
    return rstate

STAMP = getattr(m, "GRW_GUARD_REJECTED_LABEL", "grw-guard-rejected")
def requeued(world):
    return (any(s == "queued" for _, s in world.statuses)
            or bool(world.find("label", "add", "gate-status:queued"))
            or any(str(a).startswith("grw-requeue:") for c in world.calls for a in c))

# 3a. THE BUG: a guard-rejected marker must not be requeued
w = World(comments_out=comments(REJ_TEXT))
rs = sweep(w, [marker()])
ok(not requeued(w), "3a guard-rejected marker is NOT requeued (HEAD: error→queued + grw-requeue:1)")
nud = w.find("nudge")
ok(len(nud) == 1 and "wa-worker-1" in nud[0], "3a the author (gate.submitted_by) is nudged exactly once")
ok(nud and "wa-d3ys32.2.1" in " ".join(nud[0]) and "ga-mk1" in " ".join(nud[0]),
   "3a the nudge carries the marker id and the rejected fields — the reason the submitter must act on")
ok(bool(w.find("label", "add", "ga-mk1", STAMP)), "3a a durable label is stamped on the marker")
ok(not w.find("mail"), "3a the nudge got through → no Mayor mail (no extra noise)")

# 3b. next sweep (the label is now on the marker): silent, and does not even re-read comments
w2 = World(comments_out=comments(REJ_TEXT))
sweep(w2, [marker(labels=[STAMP])])
ok(not requeued(w2) and not w2.find("nudge") and not w2.find("mail"),
   "3b stamped marker: no requeue, no second nudge, no mail")
ok(not w2.find("comments"), "3b stamped marker: the comments are not re-read every sweep")

# 3c. same process, label write lost: still no second nudge
w3 = World(comments_out=comments(REJ_TEXT), label_rc=1)
rs = sweep(w3, [marker()])
sweep(w3, [marker()], rstate=rs)
ok(len(w3.find("nudge")) == 1 and not requeued(w3), "3c label write failed → in-process memory still prevents a second nudge")

# 3d. delivery fallbacks
w4 = World(comments_out=comments(REJ_TEXT), nudge_rc=1)
sweep(w4, [marker()])
ok(len(w4.find("mail", "mayor")) == 1 and bool(w4.find("label", "add", STAMP)),
   "3d nudge failed → durable mail to the Mayor instead, and the marker is stamped")
w5 = World(comments_out=comments(REJ_TEXT))
sweep(w5, [marker(author="")])
ok(not w5.find("nudge") and len(w5.find("mail", "mayor")) == 1, "3d no author on the marker → Mayor mail (nobody to nudge)")
w6 = World(comments_out=comments(REJ_TEXT), nudge_rc=1, mail_rc=1)
sweep(w6, [marker()])
ok(not requeued(w6) and not w6.find("label", "add", STAMP),
   "3d both channels failed → NOT stamped (retried next sweep), and still not requeued")

# 3e. already-spent budget: a marker the OLD watchdog already requeued twice gets the real reason
w7 = World(comments_out=comments(REJ_TEXT, REQ_TEXT, REJ_TEXT, REQ_TEXT))
sweep(w7, [marker(labels=["grw-requeue:3"])])
ok(len(w7.find("nudge")) == 1 and not requeued(w7) and not w7.find("mail")
   and not any("re-erra" in n[0] for n in w7.notifies),
   "3e budget exhausted + guard rejection → the author is told the real cause (no 'oscillating' page, no mail)")

# 3f. could-not-read: inert + one alarm
for label, kw in (("rc!=0", dict(comments_rc=1)), ("sh() returned None", dict(comments_rc=None)),
                  ("garbage stdout", dict(comments_out="Error: dolt unavailable"))):
    wu = World(**kw)
    sweep(wu, [marker("ga-mk1"), marker("ga-mk2")])
    ok(not requeued(wu), "3f comments unreadable (%s) → NOT requeued" % label)
    ok(len(wu.notifies) == 1 and "ga-mk1" in wu.notifies[0][0] and "ga-mk2" in wu.notifies[0][0],
       "3f comments unreadable (%s) → ONE batched alarm naming both markers" % label)

# 3g. control: a genuinely transient error still self-heals
wc = World(comments_out=comments("dispatcher: ghost-yield, reclaimed"))
sweep(wc, [marker()])
ok(any(s == "queued" for _, s in wc.statuses) and bool(wc.find("label", "add", "grw-requeue:1")),
   "3g comments readable and clean → requeued as before (transient self-heal intact)")
wcc = World(comments_out="[]")
sweep(wcc, [marker()])
ok(any(s == "queued" for _, s in wcc.statuses), "3g a marker with no comments at all → requeued as before")

# 3h. young markers cost no comment read
wy = World(comments_out=comments(REJ_TEXT))
young = marker(); young["metadata"][m.GRW_STATUS_ANCHOR_KEY] = "error@%d" % (NOW - 30)
sweep(wy, [young])
ok(not wy.find("comments") and not requeued(wy), "3h marker younger than the grace period: untouched, no comment read")

# 3i. dry-run writes nothing
wd = World(comments_out=comments(REJ_TEXT))
sweep(wd, [marker()], dry=True)
ok(not wd.find("nudge") and not wd.find("mail") and not wd.find("label", "add") and not wd.statuses,
   "3i dry-run: reads comments, writes/nudges/mails/stamps nothing, requeues nothing")

# ── 4. Contract with the real guard ──────────────────────────────────────────────────────
print("[4] contract: the watchdog's match text vs the guard's comments")
try:
    guard = open(GUARD_PATH, encoding="utf-8", errors="replace").read()
except OSError as e:
    guard = None
    ok(False, "guard source readable at %s (%s)" % (GUARD_PATH, e))
if guard is not None:
    prefix = getattr(m, "GUARD_REJECTION_COMMENT_PREFIX", None)
    ok(bool(prefix), "GUARD_REJECTION_COMMENT_PREFIX is defined")
    total = len(re.findall(r"Gate guard rejected marker", guard))
    opening = len(re.findall(r'comment "\$MARKER_ID" "' + re.escape(prefix or "<undefined>"), guard))
    ok(total >= 5, "the guard still has its refusal comments (found %d)" % total)
    ok(total == opening, "EVERY refusal comment the guard writes OPENS with the watchdog's prefix (%d of %d) — "
                         "a reworded or re-templated refusal would silently turn this guard off" % (opening, total))
    inv = re.search(r'comment "\$MARKER_ID" "(Gate guard rejected marker: invalid/unsafe field values\.)', guard)
    ok(bool(inv), "the 'invalid/unsafe field values' refusal (the ga-hp4wrx case) is still emitted by the guard")

print("")
print("RESULT: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
rc=$?
echo ""
[ "$rc" = "0" ] && echo "SELFTEST: PASS" || echo "SELFTEST: FAIL (rc=$rc)"
exit $rc
