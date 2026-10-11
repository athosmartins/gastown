#!/usr/bin/env python3
"""nudge-queue-hygiene — ga-aijm2v.5 (Camada 1 da portaria, regra 2) + ga-j96y0n (dead-letter TTL).

Cleans the engine's nudge queue without an engine patch: (1) the WARNING items, (2) the
bead-less dead-letter items the engine never prunes (see "Dead-letter TTL" below).

Measured 2026-09-25: 173 items were pending (7.7 MB state.json), 79 of them the
warning "check for assigned work" (22 for gastown.dog-2 alone). Each pending item is
injected as a "deferred reminder" into the target's NEXT turn, so every stale
duplicate costs that session a turn re-reading its whole context (~230k tokens for a
dog) for a message that says nothing new. TTL is 24 h (cmd_nudge.go
defaultQueuedNudgeTTL), so they sit there a full day.

What it does (only for WARNING items — see WARNING_PREFIXES):
  1. dedupe: at most ONE pending warning per (agent, session_id); the newest wins
     (it lives longest against the TTL), the older ones are dead-lettered;
  2. drop warnings whose target no longer exists: neither the agent nor the
     session_id is a live (non-closed) session. A reminder to a session that is gone
     cannot be read, and a fresh session probes for work by itself at startup.

What it never touches: any non-warning item (reviewer tasks, the Pilot's
DISPATCH_TASK, gate feedback — those are WORK, not notices), in_flight items, items
that are claimed, and any state whose shape it does not recognise.

How it mutates the queue safely (no engine patch, mirrors nudgequeue.WithState):
  * takes LOCK_EX on <city>/.gc/nudges/state.lock — the SAME flock the
    engine holds around every queue operation — reads state.json fresh under the
    lock, and replaces it atomically (tmp + fsync + rename, mode 0644);
  * moves items pending -> dead with last_error="superseded" instead of deleting
    them. That is the engine's own terminal classification: terminalStateForDead
    QueuedNudge maps it to the "superseded" state, and pruneDeadQueuedNudges
    repairs the backing wisp bead of any dead item that is not terminal yet, then
    prunes it after the dead-retention window. Deleting instead would orphan the
    backing bead. That holds ONLY for an item that has a bead_id: pruneDeadQueuedNudges
    keeps every bead-less dead item forever (see "Dead-letter TTL"), so a bead-less
    warning moved here used to stay in the file for good;
  * writes NOTHING when there is nothing to move (no needless rewrite of 7 MB);
  * "cannot tell" is never "gone": if the live-session lookup fails or comes back
    empty, only the dedupe rule runs. The lookup is read BEFORE the lock (it can take
    up to 90 s and the engine's lock must not be held that long), so a warning is judged
    "gone" only if it was created BEFORE that snapshot began; a newer one, or one whose
    created_at cannot be read, is left alone and counted in "kept_undecided". Likewise an
    item whose created_at cannot be read is never ranked in the dedupe (it is neither the
    survivor nor a casualty);
  * three states are never collapsed into two. EMPTY queue (rc 0, nothing written): a queue DIR
    with no state.json (summary "queue": "absent"), a state.json of exactly 0 bytes ("queue":
    "zero-length" — nudgequeue.LoadState agrees on both), and a document whose pending key is
    absent or null (the engine tags pending/in_flight/dead `omitempty`, so a drained queue is
    written as {} or {"dead":[...]}). CANNOT TELL (rc 2, nothing written): a missing DIR (a wrong
    path — never created here), unparseable JSON (a whitespace-only file included), a top level
    that is not an object, or a pending/dead key that is PRESENT but not a list.
  * every run — a failed one too — appends its summary to --log, so the before/after record has no
    holes where the errors are.

Dead-letter TTL (ga-j96y0n). pruneDeadQueuedNudges (cmd/gc/cmd_nudge.go) drops a dead item only when it
has a bead_id AND the backing bead is terminal AND dead_at is older than 1 h; an item with NO bead_id falls
straight through to "keep" and is never dropped. Measured 2026-10-10: 110 of the 118 dead items had no
bead_id, 108 of those were 7-98 days old (one 98 days), and they were 3.96 of the 4.23 MB of dead items
that nudgequeue.WithState reads in full on every queue operation and rewrites in full on every
mutation. (The 8 bead-backed ones were all <= 7 days: the engine does prune
those.) This script drops a dead item when ALL of these hold:
  * it is an object whose dead_at parses and is older than --dead-retention-days (default 7; 0 = off);
  * it has no bead_id (nothing durable points at it: the dead-letter entry is the only record, and a week
    is the time anyone has to read it). A bead-backed item is NEVER dropped here, however old: the engine
    owns the terminal-bead repair for it. If one is still around after the retention it is counted in
    dead_kept_bead_backed_old, so the engine failing at it shows up in the log instead of vanishing.
Three states, not two: an item whose dead_at is missing or unparseable, or that is not an object at all,
is "cannot tell" — kept, counted in dead_kept_undecided. (A dead_at in the FUTURE parses fine: it is simply
not old, so it is kept without being counted.) The same holds for the file: a dead key that is PRESENT but
not a list is rc 2, nothing written. The decision keys on dead_at, never on created_at (an item
dead-lettered by this very run has an old created_at and a fresh dead_at).
The engine patch that makes this redundant is staged in docs/pending-engine-window/ga-j96y0n-*.patch;
until that window this script is the only thing bounding the file.

Default is a DRY RUN; the order passes --apply.
"""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
import subprocess
import sys
import tempfile

# Notices whose only content is "go look for work". Matched case-insensitively on
# the stripped message start. Keep this list to pure notices: anything that carries
# a task or feedback must never be added here.
WARNING_PREFIXES = ("check for assigned work",)

ABSENT = object()            # read_state(): queue dir exists, no state.json yet (an empty queue)
ZERO_LENGTH = object()       # read_state(): state.json exists with 0 bytes (an empty queue; LoadState agrees)

DEAD_REASON = "superseded"   # engine terminal state for a queued nudge made moot
MAX_MOVES_DEFAULT = 1000     # a queue this size is not a normal cleanup — stop and say so (caps moves AND prunes)
DEAD_RETENTION_DAYS_DEFAULT = 7


def is_zero_ts(value):
    return (not value) or str(value).startswith("0001-01-01")


def parse_ts(value):
    """Go RFC3339 (Z / offset, 0-9 fractional digits) -> aware datetime; None if zero/unparseable."""
    if is_zero_ts(value):
        return None
    s = str(value).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    tz = ""
    for sign in ("+", "-"):
        idx = s.rfind(sign)
        if idx > 10:              # after the date part, so a date's '-' is not mistaken
            s, tz = s[:idx], s[idx:]
            break
    if "." in s:
        head, frac = s.split(".", 1)
        s = head + "." + (frac + "000000")[:6]
    try:
        return datetime.datetime.fromisoformat(s + (tz or "+00:00"))
    except ValueError:
        return None


def is_warning(item):
    msg = str(item.get("message") or "").strip().lower()
    return any(msg.startswith(p) for p in WARNING_PREFIXES)


def is_claimed(item):
    return not (is_zero_ts(item.get("claimed_at")) and is_zero_ts(item.get("lease_until")))


def live_identities(sessions_doc):
    """Set of every identity string of every non-closed session, or None when unknown."""
    sessions = sessions_doc.get("sessions") if isinstance(sessions_doc, dict) else None
    if not isinstance(sessions, list) or not sessions:
        return None   # an empty universe of sessions is implausible: treat as "cannot tell"
    ids = set()
    for s in sessions:
        if not isinstance(s, dict) or s.get("closed") is True or s.get("state") == "closed":
            continue
        for key in ("id", "name", "alias", "agent_name", "session_name"):
            v = s.get(key)
            if v:
                ids.add(str(v))
    return ids or None


def plan(pending, live, snapshot_started):
    """Return (move, undecided).

    move maps item id -> 'dup' | 'gone'. undecided is the set of ids of warnings the sessions
    snapshot cannot vouch for, which are therefore left alone (never called 'gone').

    Destructive decisions are made only on data that can support them:
      * 'gone' needs a snapshot that was taken AFTER the warning existed. The snapshot is read
        (up to 90 s) BEFORE the queue lock is taken, so a session created — and warned — during
        that window is absent from it although it is alive. Only a warning with a parseable
        created_at strictly BEFORE snapshot_started can be judged gone; a newer one, or one whose
        created_at cannot be read, is 'undecided' (cannot tell != gone).
      * 'dup' needs an ordering. Only items with a parseable created_at are ranked; one that
        cannot be ordered is neither the survivor nor a casualty (it used to sort as the epoch,
        i.e. always the OLDEST, so an unparseable stamp could lose to an older item)."""
    move, undecided = {}, set()
    candidates = [it for it in pending if is_warning(it) and not is_claimed(it)]

    if live is not None:
        for it in candidates:
            agent, sid = str(it.get("agent") or ""), str(it.get("session_id") or "")
            known = (agent in live) or (sid != "" and sid in live)
            if known:
                continue
            created = parse_ts(it.get("created_at"))
            if created is None or created >= snapshot_started:
                undecided.add(it["id"])
                continue
            move[it["id"]] = "gone"

    groups = {}
    for it in candidates:
        if it["id"] in move:
            continue
        groups.setdefault((str(it.get("agent") or ""), str(it.get("session_id") or "")), []).append(it)
    for items in groups.values():
        ranked = [it for it in items if parse_ts(it.get("created_at")) is not None]
        if len(ranked) < 2:
            continue
        # newest wins; ties broken by id so the choice is deterministic
        ranked.sort(key=lambda it: (parse_ts(it.get("created_at")), str(it.get("id"))))
        for it in ranked[:-1]:
            move[it["id"]] = "dup"
    return move, undecided


def plan_dead_prune(dead, now, retention_days):
    """Return (prune, stats): prune is the set of INDEXES into `dead` to drop (see "Dead-letter TTL").

    Only an old item with no bead_id is dropped. Everything we cannot judge — dead_at missing / unparseable /
    in the future, or an entry that is not an object — is kept and counted: "cannot tell" is never "old"."""
    stats = {"dead_kept_bead_backed_old": 0, "dead_kept_undecided": 0}
    prune = set()
    if retention_days <= 0:
        return prune, stats
    horizon = now - datetime.timedelta(days=retention_days)
    for idx, it in enumerate(dead):
        dead_at = parse_ts(it.get("dead_at")) if isinstance(it, dict) else None
        if dead_at is None:
            stats["dead_kept_undecided"] += 1
            continue
        if dead_at >= horizon:        # recent, or stamped in the future (clock skew): not old
            continue
        if it.get("bead_id"):         # the engine's pruneDeadQueuedNudges owns these (!= "" there too)
            stats["dead_kept_bead_backed_old"] += 1
            continue
        prune.add(idx)
    return prune, stats


def load_sessions(city, sessions_file):
    try:
        if sessions_file:
            with open(sessions_file) as fh:
                return json.load(fh)
        out = subprocess.run(
            ["gc", "--city", city, "session", "list", "--json", "--state", "all"],
            capture_output=True, text=True, timeout=90)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def atomic_write(path, text):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".state.json.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        # Error path: the ORIGINAL error is re-raised below; a temp file we could not remove
        # is only litter and must not mask it.
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def now_go_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def run(args):
    city = args.city
    # citylayout.RuntimePath(city, "nudges", ...) = <city>/<RuntimeRoot=.gc>/nudges (NOT .gc/runtime,
    # which is the separate GC_CITY_RUNTIME_DIR used for pack state).
    qdir = args.queue_dir or os.path.join(city, ".gc", "nudges")
    state_path = os.path.join(qdir, "state.json")
    lock_path = os.path.join(qdir, "state.lock")

    # The sessions snapshot is taken BEFORE the queue lock (it can take up to 90 s; holding the
    # engine's lock that long would stall the engine), so plan() must not call a warning "gone" on
    # the strength of a snapshot that predates it. Stamp the moment the snapshot BEGINS.
    snapshot_started = datetime.datetime.now(datetime.timezone.utc)
    live = live_identities(load_sessions(city, args.sessions_file))
    summary = {"ts": now_go_ts(), "apply": bool(args.apply), "live_lookup": "ok" if live is not None else "unknown"}

    def evaluate(state):
        if not isinstance(state, dict):
            raise ValueError("unrecognised queue shape (top level is not an object)")
        # The engine's State tags pending/in_flight/dead `omitempty` (nudgequeue/state.go), so a queue with
        # nothing pending is written as {} or {"dead":[...]}: the key is ABSENT (or, for Go's tolerant
        # decoder, null). Absent/null is an EMPTY list — not an error. A key that is PRESENT with anything
        # but a list of id-bearing items is a shape we cannot vouch for: that one stays an error.
        pending = state.get("pending")
        if pending is None:
            pending = []
        if not isinstance(pending, list) or not all(isinstance(i, dict) and i.get("id") for i in pending):
            raise ValueError("unrecognised queue shape (pending is not a list of items with ids)")
        move, undecided = plan(pending, live, snapshot_started)
        # `dead` is read for the TTL on every run, so its shape must be vouched for on every run — not only
        # when a move happens to need it. Absent / null = empty (omitempty); present-but-not-a-list = rc 2.
        dead = state.get("dead")
        if dead is None:
            dead = []
        if not isinstance(dead, list):
            raise ValueError("unrecognised queue shape (dead is not a list)")
        prune, dead_stats = plan_dead_prune(dead, datetime.datetime.now(datetime.timezone.utc), args.dead_retention_days)
        summary.update(
            pending_before=len(pending),
            warnings_before=sum(1 for i in pending if is_warning(i)),
            moved_dup=sum(1 for v in move.values() if v == "dup"),
            moved_gone=sum(1 for v in move.values() if v == "gone"),
            kept_undecided=len(undecided),
            dead_before=len(dead),
            pruned_dead=len(prune),
            pruned_dead_bytes=sum(len(json.dumps(dead[i], ensure_ascii=False)) for i in prune),
            **dead_stats,
        )
        return move, prune

    def read_state():
        """The queue state. Three different things must never collapse into one value:
          * ABSENT      — the queue DIR exists but holds no state.json yet: an empty queue;
          * ZERO_LENGTH — a state.json of exactly 0 bytes: an empty queue too (nudgequeue.LoadState
                          returns State{} for a missing file and for len(data)==0; a whitespace-only
                          file is a parse error THERE as well, so it is one here);
          * the parsed document otherwise (a JSON null decodes to an empty State in Go: {}).
        A missing DIR is a wrong path — an error, never 'empty'; unparseable JSON is an error."""
        try:
            with open(state_path) as fh:
                raw = fh.read()
        except FileNotFoundError:
            if os.path.isdir(qdir):
                return ABSENT
            raise
        if len(raw) == 0:
            return ZERO_LENGTH
        doc = json.loads(raw)     # a bad document raises ValueError (JSONDecodeError) -> rc 2 below
        return {} if doc is None else doc

    def evaluate_or_empty(state):
        if state is ABSENT or state is ZERO_LENGTH:
            summary.update(queue="absent" if state is ABSENT else "zero-length", pending_before=0,
                           warnings_before=0, moved_dup=0, moved_gone=0, kept_undecided=0, dead_before=0,
                           pruned_dead=0, pruned_dead_bytes=0, dead_kept_bead_backed_old=0, dead_kept_undecided=0)
            return {}, set()
        return evaluate(state)

    def emit(code):
        """Print the summary and append it to the run log. A FAILED run is logged too: the log is the
        before/after record, and a record that only exists for the runs that worked has its holes
        exactly where the failures are."""
        line = json.dumps(summary, ensure_ascii=False)
        print(line)
        if args.log:
            try:
                log_dir = os.path.dirname(args.log)
                if log_dir:     # a bare file name has no dir part; makedirs("") would raise and the log would never be written
                    os.makedirs(log_dir, exist_ok=True)
                with open(args.log, "a") as fh:
                    fh.write(line + "\n")
            except OSError as exc:
                # A failure to append must be seen, not swallowed — and must not change the run's own rc.
                print("nudge-queue-hygiene: could not append to %s: %s" % (args.log, exc), file=sys.stderr)
        return code

    try:
        if not args.apply:
            state = read_state()
            move, prune = evaluate_or_empty(state)
            summary["pending_after"] = summary["pending_before"] - len(move)
            summary["dead_after"] = summary["dead_before"] - len(prune) + len(move)
        else:
            # The engine owns this directory. A missing one is a wrong --city/--queue-dir: fail closed
            # (rc 2) instead of creating it and then reading an "empty" queue out of thin air.
            if not os.path.isdir(qdir):
                raise OSError("queue dir %s does not exist" % qdir)
            with open(lock_path, "a+") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    state = read_state()      # fresh, UNDER the lock
                    move, prune = evaluate_or_empty(state)
                    if len(move) > args.max_moves:
                        raise ValueError("refusing to move %d items (> --max-moves %d)" % (len(move), args.max_moves))
                    if len(prune) > args.max_moves:
                        raise ValueError("refusing to prune %d dead items (> --max-moves %d)" % (len(prune), args.max_moves))
                    if move or prune:
                        # evaluate() already vouched for the shape: dead is a list, or absent/null (= empty)
                        dead = [it for i, it in enumerate(state.get("dead") or []) if i not in prune]
                        if move:
                            stamp = now_go_ts()
                            keep = []
                            for it in state["pending"]:
                                if it["id"] in move:
                                    it["dead_at"] = stamp
                                    it["last_error"] = DEAD_REASON
                                    dead.append(it)
                                else:
                                    keep.append(it)
                            state["pending"] = keep
                        if dead:
                            state["dead"] = dead
                        else:
                            state.pop("dead", None)   # the engine tags dead `omitempty`: a drained bucket has no key
                        atomic_write(state_path, json.dumps(state, indent=2, ensure_ascii=False) + "\n")
                    summary["pending_after"] = summary["pending_before"] - len(move)
                    summary["dead_after"] = summary["dead_before"] - len(prune) + len(move)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    except (OSError, ValueError) as exc:
        summary["error"] = str(exc)
        return emit(2)

    return emit(0)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true", help="mutate the queue (default: dry run)")
    ap.add_argument("--city", default=os.environ.get("GC_CITY") or os.getcwd())
    ap.add_argument("--queue-dir", help="override <city>/.gc/nudges (tests)")
    ap.add_argument("--sessions-file", help="use this `gc session list --json` output instead of calling gc (tests)")
    ap.add_argument("--log", default=None, help="append the json summary here")
    ap.add_argument("--max-moves", type=int, default=MAX_MOVES_DEFAULT,
                    help="refuse (rc 2) to move, or to prune, more items than this in one run")
    ap.add_argument("--dead-retention-days", type=int, default=DEAD_RETENTION_DAYS_DEFAULT,
                    help="drop bead-less dead-letter items older than this many days (0 = never)")
    return run(ap.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
