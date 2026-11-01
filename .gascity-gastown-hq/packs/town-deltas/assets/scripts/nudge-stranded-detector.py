#!/usr/bin/env python3
"""nudge-stranded-detector — ga-gj1jr7x. DETECTION ONLY: finds a PENDING nudge nobody is going to deliver.

Measured 31/10: `digo-wa` had a nudge PENDING (due now, never attempted) for 1 h 54 min with the session alive and
idle and no `gc nudge poll` process. The crew missed a "DELIVERY HALTED" notice for that whole time; it showed only in
`gc nudge status digo-wa`. The engine starts a poller ONLY when a nudge is enqueued (ga-55jx16q: that poller can die of
SIGPIPE; any other death — OOM, reboot, kill — has the same result), and nothing re-arms it. nudge-queue-hygiene cannot
see this: it only touches WARNING-prefixed items. This script is the missing alarm.

STRANDED = a pending item that is (a) due and older than --min-age-min, (b) not expired, not under a live claim, (c)
addressed to a session that is LIVE, and (d) that session has NO live poller. Everything else is "fine" and is counted
by reason; what the script cannot vouch for is "cannot tell" and is counted on its own line. THREE states, never two:
an alarm needs positive evidence of (c) and (d); a failed read is never read as "no poller" nor as "not live".

What it reads (all read-only; it never writes the queue and never takes the engine's queue lock):
  * <city>/.gc/nudges/state.json  — the engine replaces it by atomic rename, so a plain read is consistent.
    Absent file / 0 bytes / a bare JSON null / pending absent-or-null = EMPTY queue (the engine tags pending
    `omitempty`, same rule as nudge-queue-hygiene). Missing dir, unparseable JSON, top level not an object, or pending present but not a list
    of id-bearing objects = CANNOT TELL (rc 2).
  * `ps` — the ONLY authority on pollers. A poller is a live (non-zombie) `gc nudge poll --city <this city> ...`
    process that carries the item's session_id as an argument. The argv was MEASURED on the live city, not taken
    from the bead's sketch: `gc nudge poll --city <city> --session <session NAME> <session ID>` — the positional
    argument is the session id (ga-wisp-…), not the agent name. The PID files under .gc/nudges/pollers/ are
    deliberately NOT read: 15,066 of them sit there against 4 live pollers (never pruned), and the process table
    answers the question directly.
  * session liveness: local tmux first (`tmux -L gascity`, GC_SESSION_ID of each pane, no Dolt). tmux can only say
    "live"; its silence is NOT "gone", because remote-node sessions (gate-reviewer-remote-*, …) are `active` in gc
    with no local pane. When tmux does not settle it, `gc session list --json --state all` does (measured ~10 s,
    Dolt) — and ONLY then, so a quiet queue costs zero external calls. LIVE = a local pane carries the item's
    session id, or gc says that id is `active` and not closed; asleep / start-pending / closed / unknown to gc =
    not live (fine: the session is not there to be missed). If gc cannot be read either, the item is
    "cannot tell", never "not live".

Alarm (only with --alarm; the default is a dry run that prints and logs, so a hand-run never pings anyone): one
`notify` per run listing the NEW stranded ids, deduped per nudge id in --state-dir (an id alarms once while it stays
pending; ids that left the queue are pruned from the seen-file). It goes through `notify` (ntfy), NOT through a nudge
or mail: the nudge queue is the very channel that is broken. Before alarming, the queue is re-read and an item that
was delivered meanwhile is dropped (a poller can finish and exit between the two reads). An alarm that could not be
sent (notify missing/failing) is NOT recorded as sent: the next sweep retries, and the run exits rc 3.
"cannot tell" also raises one notify, with its own cooldown (--cannot-tell-cooldown-min) PER REASON-SET, on EVERY path
that ends blind — an unreadable queue, a lib that will not load, a crash while classifying, items that could not be
decided — because a detector that is blind and silent is indistinguishable from one that sees nothing.

Cost: one 1.4 MB JSON read per run (a second one only when something is stranded, for the re-read); ps/tmux/gc only when
an old due item needs them. Measured on the live city, 1/11: 10 s wall with `gc session list` in play. Single instance
(flock on <state-dir>/nudge-stranded-detector.lock — ga-y0g5x: four overlapping guards took the city's bd down).

rc: 0 ran and everything was decided; 2 something could not be decided (queue/ps/tmux+gc unreadable, malformed item,
or the instance lock could not be taken); 3 an alarm could not be delivered (or the seen-file could not be written).
Every run — a failed one too — prints its summary and tries to append it to --log (a log that cannot be written is
reported on stderr, not fatal).
Known blind spot: if the state dir itself is unwritable, the lock cannot be taken and the run ends rc 2 WITHOUT a notify
(the cannot-tell cooldown lives in that same dir, so a notify every sweep would be a flood). It shows only in the order
history and in --log; nothing else in this script can see it.
Not in scope: the engine fix (ga-55jx16q), items fenced to an OLDER session id of a live agent (they are "session not
live" here — a separate question), re-arming the poller (a later, separate decision).
"""
import argparse
import contextlib
import datetime
import fcntl
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HYGIENE = os.path.join(HERE, "nudge-queue-hygiene.py")

MIN_AGE_MIN_DEFAULT = 10
CANNOT_TELL_COOLDOWN_MIN_DEFAULT = 360
TMUX_SOCKET_DEFAULT = "gascity"
ALARM_LINES_MAX = 8

ABSENT = object()        # read_queue(): the queue dir exists, no state.json yet -> an empty queue
ZERO_LENGTH = object()   # read_queue(): state.json of exactly 0 bytes -> an empty queue


class Undecided(Exception):
    """A source could not be read: the caller must report 'cannot tell', never an empty/false value."""


def load_hygiene():
    """Reuse the Go-timestamp parser of nudge-queue-hygiene (module-level, import has no side effects).
    vazio → n/a; falhou/ilegível → raise Undecided (the whole run is rc 2: without the parser every age is unknown)."""
    try:
        spec = importlib.util.spec_from_file_location("nudge_queue_hygiene", HYGIENE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        if not (callable(getattr(mod, "parse_ts", None)) and callable(getattr(mod, "is_zero_ts", None))):
            raise Undecided("nudge-queue-hygiene.py has no parse_ts/is_zero_ts")
        return mod
    except Undecided:
        raise
    except Exception as exc:   # SyntaxError / OSError / ImportError: all mean "cannot reuse it"
        raise Undecided("cannot load %s: %s" % (HYGIENE, exc))


def read_queue(qdir):
    """The engine's state document. Three different things, never collapsed:
    ABSENT / ZERO_LENGTH = empty queue; the parsed dict otherwise; Undecided for everything we cannot vouch for."""
    path = os.path.join(qdir, "state.json")
    # vazio → ABSENT/ZERO_LENGTH (an empty queue, nothing to alarm); falhou/ilegível → Undecided (rc 2, no alarm)
    try:
        with open(path) as fh:
            raw = fh.read()
    except FileNotFoundError:
        if os.path.isdir(qdir):
            return ABSENT
        raise Undecided("queue dir %s does not exist" % qdir)
    except OSError as exc:
        raise Undecided("cannot read %s: %s" % (path, exc))
    if len(raw) == 0:
        return ZERO_LENGTH
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise Undecided("state.json is not valid JSON: %s" % exc)
    if doc is None:
        return {}
    if not isinstance(doc, dict):
        raise Undecided("unrecognised queue shape (top level is not an object)")
    return doc


def pending_of(doc):
    """List of pending items. absent/null = []; present-but-not-a-list = Undecided. Items are NOT filtered here:
    a malformed one must reach classify() so it is counted as 'cannot tell' instead of vanishing."""
    if doc is ABSENT or doc is ZERO_LENGTH:
        return []
    pending = doc.get("pending")
    if pending is None:
        return []
    if not isinstance(pending, list):
        raise Undecided("unrecognised queue shape (pending is not a list)")
    return pending


def run_cmd(argv, timeout):
    """-> stdout text. Raises Undecided on rc != 0, timeout or exec failure (never returns '' for a failure)."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Undecided("%s: %s" % (argv[0], exc))
    if out.returncode != 0:
        raise Undecided("%s exited %d" % (argv[0], out.returncode))
    return out.stdout


def read_file(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as exc:
        raise Undecided("cannot read %s: %s" % (path, exc))


class Sources:
    """Lazy, memoised readers: each external source is read at most once per run, and only if needed.
    A failed read is remembered as a failure (Undecided is re-raised), never cached as an empty answer."""

    def __init__(self, args, city):
        self.args, self.city = args, city
        self._ps = self._tmux = self._gc = None   # None = not read yet; ("ok", value) | ("fail", reason)
        self.used = {}

    def _memo(self, slot, name, loader):
        cur = getattr(self, slot)
        if cur is None:
            try:
                cur = ("ok", loader())
            except Undecided as exc:
                cur = ("fail", str(exc))
            setattr(self, slot, cur)
            self.used[name] = cur[0]
        if cur[0] == "fail":
            raise Undecided("%s: %s" % (name, cur[1]))
        return cur[1]

    def pollers(self):
        """Set of session ids with a live poller for THIS city. vazio (no poller at all) → empty set, a real answer;
        falhou (ps unreadable) → Undecided, never the empty set."""
        def load():
            text = read_file(self.args.ps_file) if self.args.ps_file else run_cmd(
                ["ps", "-ax", "-ww", "-o", "pid=,stat=,command="], 20)
            if not text.strip():
                raise Undecided("ps returned nothing (it always lists itself)")
            return parse_pollers(text, self.city)
        return self._memo("_ps", "ps", load)

    def tmux_ids(self):
        """Set of GC_SESSION_ID of the local tmux panes. tmux can only prove 'live': an empty set or a failure here is
        not evidence of 'gone', so this method returns an empty set on failure (the caller then asks gc) and the
        failure is still recorded in `used`."""
        def load():
            if self.args.tmux_file:
                ids = set()
                for line in read_file(self.args.tmux_file).splitlines():
                    parts = line.split("\t")
                    if len(parts) >= 2 and parts[1].strip():
                        ids.add(parts[1].strip())
                return ids
            sock = self.args.tmux_socket
            names = run_cmd(["tmux", "-L", sock, "list-sessions", "-F", "#{session_name}"], 10).split()
            ids = set()
            for name in names:
                try:
                    env = run_cmd(["tmux", "-L", sock, "show-environment", "-t", name, "GC_SESSION_ID"], 10)
                except Undecided:
                    continue      # the pane vanished between the two calls: just not counted live by tmux
                if env.startswith("GC_SESSION_ID="):
                    ids.add(env.strip().split("=", 1)[1])
            return ids
        try:
            return self._memo("_tmux", "tmux", load)
        except Undecided:
            return set()

    def gc_sessions(self):
        """id -> session row, from `gc session list --json --state all`. An empty universe of sessions is implausible
        (the engine itself is one) and is Undecided, not 'every session is gone'."""
        def load():
            if self.args.sessions_file:
                text = read_file(self.args.sessions_file)
            else:
                text = run_cmd(["gc", "--city", self.city, "session", "list", "--json", "--state", "all"], 60)
            try:
                doc = json.loads(text)
            except ValueError as exc:
                raise Undecided("gc session list is not JSON: %s" % exc)
            rows = doc.get("sessions") if isinstance(doc, dict) else None
            if not isinstance(rows, list) or not rows:
                raise Undecided("gc session list has no sessions array (or it is empty)")
            return {str(r["id"]): r for r in rows if isinstance(r, dict) and r.get("id")}
        return self._memo("_gc", "gc_sessions", load)


def parse_pollers(ps_text, city):
    """Session ids that have a live `gc nudge poll --city <city> …` process. A zombie (stat Z) is not alive. Every
    non-flag argument after `poll` (except the values of --city/--session) counts as a candidate session id: tolerant
    of an extra flag in a future engine, because the failure of a too-strict match is a FALSE ALARM (loud, harmless),
    while a too-loose one hides a stranded nudge."""
    want_city = os.path.realpath(city)
    ids = set()
    for line in ps_text.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        stat, argv = parts[1], parts[2:]
        if stat.startswith("Z"):
            continue
        if os.path.basename(argv[0]) != "gc" or argv[1:3] != ["nudge", "poll"]:
            continue
        rest, city_arg, positional, i = argv[3:], None, [], 0
        while i < len(rest):
            tok = rest[i]
            if tok in ("--city", "--session") and i + 1 < len(rest):
                if tok == "--city":
                    city_arg = rest[i + 1]
                i += 2
            elif tok.startswith("--city="):
                city_arg = tok.split("=", 1)[1]
                i += 1
            elif tok.startswith("-"):
                i += 1
            else:
                positional.append(tok)
                i += 1
        if city_arg is None or os.path.realpath(city_arg) != want_city:
            continue          # another city's poller, or one we cannot attribute to this city
        ids.update(positional)
    return ids


def fmt_age(seconds):
    m = int(seconds // 60)
    return "%dh%02dmin" % (m // 60, m % 60) if m >= 60 else "%dmin" % m


def classify(items, now, args, hyg, src):
    """-> (stranded: list of dict, fine: {reason: n}, cannot: {reason: [ids]}).

    Order matters: cheap local checks first, so a quiet queue never touches ps/tmux/gc."""
    stranded, fine, cannot = [], {}, {}

    def f(reason):
        fine[reason] = fine.get(reason, 0) + 1

    def c(reason, ident):
        cannot.setdefault(reason, []).append(ident)

    min_age = args.min_age_min * 60
    for it in items:
        ident = str(it.get("id")) if isinstance(it, dict) and it.get("id") else "?"
        if ident == "?":
            c("malformed-item", ident)
            continue
        # claimed with a lease still running = a poller is delivering it right now
        lease = hyg.parse_ts(it.get("lease_until"))
        if lease is not None and lease > now:
            f("in_delivery")
            continue
        # expired = the message can no longer be delivered: moot. zero/unparseable expires_at does NOT suppress an alarm.
        exp = hyg.parse_ts(it.get("expires_at"))
        if exp is not None and exp <= now:
            f("expired")
            continue
        # the age clock starts when the item became due (deliver_after); a zero deliver_after = due at creation.
        # vazio/zero → fall back to created_at; ilegível both → cannot tell (never "young", never "old").
        start = hyg.parse_ts(it.get("deliver_after")) or hyg.parse_ts(it.get("created_at"))
        if start is None:
            c("no-timestamp", ident)
            continue
        if start > now:
            f("not_due")
            continue
        age = (now - start).total_seconds()
        if age < min_age:
            f("young")
            continue
        sid = str(it.get("session_id") or "")
        if not sid:
            c("no-session-id", ident)
            continue
        try:
            if sid in src.pollers():
                f("poller_alive")
                continue
        except Undecided:
            c("ps-unreadable", ident)
            continue
        # no poller: is the target worth alarming about, i.e. is it live?
        if sid in src.tmux_ids():
            live = True
        else:
            try:
                row = src.gc_sessions().get(sid)
            except Undecided:
                c("liveness-unreadable", ident)
                continue
            live = bool(row) and row.get("closed") is not True and row.get("state") == "active"
        if not live:
            f("session_not_live")
            continue
        stranded.append({"id": ident, "agent": str(it.get("agent") or ""), "session_id": sid,
                         "age_s": int(age)})
    return stranded, fine, cannot


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".seen.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def load_seen(path):
    """vazio (no file) → fresh state; ilegível/corrupt → fresh state too, on purpose: a repeated alarm is loud and
    harmless, while refusing to alarm would silence the detector. Once, if the rewrite then works (it heals the file);
    if the state dir is read-only it repeats on every sweep, and save_seen() makes that visible (rc 3, seen_write)."""
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return {"alerted": {}, "cannot_tell": {}}
    if not isinstance(doc, dict):
        return {"alerted": {}, "cannot_tell": {}}
    alerted, ct = doc.get("alerted"), doc.get("cannot_tell")
    return {"alerted": alerted if isinstance(alerted, dict) else {},
            "cannot_tell": ct if isinstance(ct, dict) else {}}


def send_notify(args, title, body):
    """True only if notify exited 0. A missing binary / timeout / non-zero is False: NOT delivered."""
    try:
        out = subprocess.run([args.notify_bin, "-t", title, "-p", "3", body], capture_output=True, text=True,
                             timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    return out.returncode == 0


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(args):
    started = time.monotonic()
    city = args.city
    qdir = args.queue_dir or os.path.join(city, ".gc", "nudges")
    state_dir = args.state_dir or os.path.join(city, ".gc", "runtime", "packs", "town-deltas")
    summary = {"ts": now_iso(), "alarm": bool(args.alarm), "min_age_min": args.min_age_min}

    def emit(code):
        summary["rc"] = code
        summary["duration_s"] = round(time.monotonic() - started, 2)
        line = json.dumps(summary, ensure_ascii=False)
        print(line)
        if args.log:
            try:
                os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)
                with open(args.log, "a") as fh:
                    fh.write(line + "\n")
            except OSError as exc:
                print("nudge-stranded-detector: could not append to %s: %s" % (args.log, exc), file=sys.stderr)
        return code

    # single instance (ga-y0g5x). Opened in the state dir, which we may create: it is OUR dir, not the engine's.
    lock = None
    if args.alarm or args.lock_file:
        try:
            lock_path = args.lock_file or os.path.join(state_dir, "nudge-stranded-detector.lock")
            os.makedirs(os.path.dirname(lock_path), exist_ok=True)
            lock = open(lock_path, "a+")
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            summary["skipped"] = "another instance is running"
            return emit(0)
        except OSError as exc:
            summary["error"] = "cannot take the instance lock: %s" % exc
            return emit(2)

    seen_path = os.path.join(state_dir, "nudge-stranded-detector-seen.json")

    def blind_alarm(seen, keys, text):
        """The 'cannot tell' notify, throttled per reason-set. -> (rc_part, changed). Sent => recorded; not delivered =>
        NOT recorded (the next sweep retries) and rc 3; inside the cooldown => nothing."""
        key = ",".join(sorted(keys))
        last = seen["cannot_tell"].get(key, 0)
        wall = time.time()
        if isinstance(last, (int, float)) and wall - last < args.cannot_tell_cooldown_min * 60:
            return 0, False
        if send_notify(args, "Detector de nudge preso: cego", text):
            seen["cannot_tell"][key] = int(wall)
            return 0, True
        summary["notify"] = "failed"
        return 3, False

    def save_seen(seen):
        try:
            atomic_write(seen_path, json.dumps(seen, ensure_ascii=False, sort_keys=True))
            return 0
        except OSError as exc:
            summary["seen_write"] = "failed: %s" % exc     # next sweep may repeat an alarm: visible, not silent
            return 3

    def blind_run(key, reason, n):
        """The whole run is blind (the queue itself could not be read, or the run crashed): say so out loud (alarm
        mode), then end rc 2 — or rc 3 if the alarm could not be delivered."""
        summary["error"] = reason
        summary["cannot_tell"] = n
        rc = 2
        if args.alarm:
            seen = load_seen(seen_path)
            part, changed = blind_alarm(seen, [key], "Detector de nudge preso NAO consegue decidir (%s): %s" % (key, reason[:300]))
            if part:
                rc = part
            if changed:
                rc = max(rc, save_seen(seen))
        return emit(rc)

    try:
        hyg = load_hygiene()
        now = (hyg.parse_ts(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc))
        if now is None:
            raise Undecided("--now is not a timestamp")
        doc = read_queue(qdir)
        items = pending_of(doc)
    except Undecided as exc:
        return blind_run("queue-unreadable", str(exc), 1)

    src = Sources(args, city)
    try:
        stranded, fine, cannot = classify(items, now, args, hyg, src)
    except Exception as exc:    # a bug or an odd item shape: the run is BLIND, which must show — never a bare traceback
        return blind_run("classify-crashed", "classify crashed: %s: %s" % (type(exc).__name__, exc), len(items))

    # Re-read the queue: a poller can deliver and exit between our first read and the ps read. An item that is gone
    # from pending was delivered — drop it. If the re-read fails we cannot confirm, so those items are 'cannot tell'.
    resolved = 0
    if stranded:
        try:
            still = {str(i.get("id")) for i in pending_of(read_queue(qdir)) if isinstance(i, dict)}
            kept = [s for s in stranded if s["id"] in still]
            resolved, stranded = len(stranded) - len(kept), kept
        except Undecided:
            for s in stranded:
                cannot.setdefault("reread-failed", []).append(s["id"])
            stranded = []

    cannot_n = sum(len(v) for v in cannot.values())
    summary.update(
        pending=len(items), stranded=len(stranded), fine=fine, resolved_during_run=resolved,
        cannot_tell=cannot_n, cannot_tell_reasons={k: len(v) for k, v in sorted(cannot.items())},
        sources=src.used, pollers_seen=(len(src.pollers()) if src.used.get("ps") == "ok" else None),
        stranded_items=[dict(s, age=fmt_age(s["age_s"])) for s in stranded])
    rc = 2 if cannot_n else 0

    if args.alarm:
        seen = load_seen(seen_path)
        pending_ids = {str(i.get("id")) for i in items if isinstance(i, dict) and i.get("id")}
        changed = False
        # ids that left the queue are pruned: the seen-file stays bounded by the queue itself.
        for k in [k for k in seen["alerted"] if k not in pending_ids]:
            del seen["alerted"][k]
            changed = True
        new = [s for s in stranded if s["id"] not in seen["alerted"]]
        summary["already_alerted"] = len(stranded) - len(new)
        summary["alarmed"] = []
        if new:
            lines = ["%s -> %s (%s) ha %s" % (s["id"], s["agent"] or "?", s["session_id"], fmt_age(s["age_s"]))
                     for s in new[:ALARM_LINES_MAX]]
            if len(new) > ALARM_LINES_MAX:
                lines.append("... e mais %d" % (len(new) - ALARM_LINES_MAX))
            body = ("Nudge PENDENTE com a sessao viva e SEM poller (ninguem vai entregar). "
                    "Confira: gc nudge status <agente>.\n" + "\n".join(lines))
            if send_notify(args, "Nudge preso sem poller (%d)" % len(new), body):
                for s in new:
                    seen["alerted"][s["id"]] = now_iso()
                summary["alarmed"] = [s["id"] for s in new]
                changed = True
            else:
                summary["notify"] = "failed"      # NOT recorded as sent: the next sweep retries
                rc = 3
        if cannot_n:
            part, ch = blind_alarm(seen, list(cannot), "Detector de nudge preso NAO consegue decidir: " + ", ".join(
                "%s=%d" % (k, len(v)) for k, v in sorted(cannot.items())))
            rc, changed = (part or rc), (changed or ch)
        if changed:
            rc = max(rc, save_seen(seen))
    return emit(rc)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--city", default=os.environ.get("GC_CITY") or os.getcwd())
    ap.add_argument("--queue-dir", help="override <city>/.gc/nudges (tests)")
    ap.add_argument("--state-dir", help="where the seen-file and lock live (default <city>/.gc/runtime/packs/town-deltas)")
    ap.add_argument("--min-age-min", type=float, default=MIN_AGE_MIN_DEFAULT,
                    help="a due item pending longer than this is a candidate (default %d)" % MIN_AGE_MIN_DEFAULT)
    ap.add_argument("--alarm", action="store_true", help="send notify + keep the dedupe file (default: dry run)")
    ap.add_argument("--cannot-tell-cooldown-min", type=float, default=CANNOT_TELL_COOLDOWN_MIN_DEFAULT)
    ap.add_argument("--log", default=None, help="append the json summary here")
    ap.add_argument("--notify-bin", default=os.environ.get("NOTIFY_BIN", "notify"))
    ap.add_argument("--tmux-socket", default=TMUX_SOCKET_DEFAULT)
    ap.add_argument("--lock-file", default=None, help="instance lock (default <state-dir>/…; taken with --alarm)")
    # test seams: each replaces ONE external command with a canned file (a missing file = that source failed)
    ap.add_argument("--now", default=None, help="RFC3339 'now' (tests)")
    ap.add_argument("--ps-file", default=None, help="canned `ps -ax -ww -o pid=,stat=,command=` output (tests)")
    ap.add_argument("--tmux-file", default=None, help="canned '<session_name>\\t<GC_SESSION_ID>' lines (tests)")
    ap.add_argument("--sessions-file", default=None, help="canned `gc session list --json` output (tests)")
    return run(ap.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
