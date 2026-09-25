#!/usr/bin/env python3
"""nudge-queue-hygiene — ga-aijm2v.5 (Camada 1 da portaria, regra 2).

Cleans the WARNING items out of the engine's nudge queue, without an engine patch.

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
    backing bead;
  * writes NOTHING when there is nothing to move (no needless rewrite of 7 MB);
  * "cannot tell" is never "gone": if the live-session lookup fails or comes back
    empty, only the dedupe rule runs.

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

DEAD_REASON = "superseded"   # engine terminal state for a queued nudge made moot
MAX_MOVES_DEFAULT = 1000     # a queue this size is not a normal cleanup — stop and say so


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


def plan(pending, live):
    """Return (to_move, reasons) where to_move maps item id -> 'dup' | 'gone'."""
    move = {}
    candidates = [it for it in pending if is_warning(it) and not is_claimed(it)]

    if live is not None:
        for it in candidates:
            agent, sid = str(it.get("agent") or ""), str(it.get("session_id") or "")
            known = (agent in live) or (sid != "" and sid in live)
            if not known:
                move[it["id"]] = "gone"

    groups = {}
    for it in candidates:
        if it["id"] in move:
            continue
        groups.setdefault((str(it.get("agent") or ""), str(it.get("session_id") or "")), []).append(it)
    epoch = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    for items in groups.values():
        if len(items) < 2:
            continue
        # newest wins; ties broken by id so the choice is deterministic
        items.sort(key=lambda it: (parse_ts(it.get("created_at")) or epoch, str(it.get("id"))))
        for it in items[:-1]:
            move[it["id"]] = "dup"
    return move


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

    live = live_identities(load_sessions(city, args.sessions_file))
    summary = {"ts": now_go_ts(), "apply": bool(args.apply), "live_lookup": "ok" if live is not None else "unknown"}

    def evaluate(state):
        pending = state.get("pending")
        if not isinstance(pending, list) or not all(isinstance(i, dict) and i.get("id") for i in pending):
            raise ValueError("unrecognised queue shape (pending is not a list of items with ids)")
        move = plan(pending, live)
        summary.update(
            pending_before=len(pending),
            warnings_before=sum(1 for i in pending if is_warning(i)),
            moved_dup=sum(1 for v in move.values() if v == "dup"),
            moved_gone=sum(1 for v in move.values() if v == "gone"),
        )
        return move

    def read_state():
        with open(state_path) as fh:
            return json.load(fh)

    try:
        if not args.apply:
            state = read_state()
            move = evaluate(state)
            summary["pending_after"] = summary["pending_before"] - len(move)
        else:
            os.makedirs(qdir, exist_ok=True)
            with open(lock_path, "a+") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    state = read_state()      # fresh, UNDER the lock
                    move = evaluate(state)
                    if len(move) > args.max_moves:
                        raise ValueError("refusing to move %d items (> --max-moves %d)" % (len(move), args.max_moves))
                    if move:
                        stamp = now_go_ts()
                        keep, dead = [], state.setdefault("dead", [])
                        if not isinstance(dead, list):
                            raise ValueError("unrecognised queue shape (dead is not a list)")
                        for it in state["pending"]:
                            if it["id"] in move:
                                it["dead_at"] = stamp
                                it["last_error"] = DEAD_REASON
                                dead.append(it)
                            else:
                                keep.append(it)
                        state["pending"] = keep
                        atomic_write(state_path, json.dumps(state, indent=2, ensure_ascii=False) + "\n")
                    summary["pending_after"] = summary["pending_before"] - len(move)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    except (OSError, ValueError) as exc:
        summary["error"] = str(exc)
        print(json.dumps(summary, ensure_ascii=False))
        return 2

    print(json.dumps(summary, ensure_ascii=False))
    if args.log:
        try:
            os.makedirs(os.path.dirname(args.log), exist_ok=True)
            with open(args.log, "a") as fh:
                fh.write(json.dumps(summary, ensure_ascii=False) + "\n")
        except OSError as exc:
            # The run log is the before/after record: a failure to append must be seen, not swallowed.
            print("nudge-queue-hygiene: could not append to %s: %s" % (args.log, exc), file=sys.stderr)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true", help="mutate the queue (default: dry run)")
    ap.add_argument("--city", default=os.environ.get("GC_CITY") or os.getcwd())
    ap.add_argument("--queue-dir", help="override <city>/.gc/nudges (tests)")
    ap.add_argument("--sessions-file", help="use this `gc session list --json` output instead of calling gc (tests)")
    ap.add_argument("--log", default=None, help="append the json summary here")
    ap.add_argument("--max-moves", type=int, default=MAX_MOVES_DEFAULT)
    return run(ap.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
