#!/usr/bin/env python3
"""nudge-pollers-prune — ga-9uv1xps (loose end 2 of the PENDING-fenced-to-an-old-session finding).

Prunes <city>/.gc/nudges/pollers/: the engine writes three files per poller stem there and
never removes them (measured 2026-11-01: 32,639 files in 17,956 stems = 17,200 .pid.lock + 15,069 .pid +
370 .log, the oldest from 19/09, growth ~700 files/day, ~96% of the stems from one-shot ad-hoc / dog / ps-worker
sessions).

Files (engine: cmd/gc/cmd_nudge.go, internal/nudgepoller/poller.go):
  <stem>.pid        the poller's PID (written atomically at start)
  <stem>.pid.lock   an empty flock(2) file taken around "is a poller already running for this stem"
  <stem>.log        the poller's log
  <stem> = <safe session name>-<hex(sha256(session + "\\x00" + agent)[:8])>

A stem is removed (all of its files) only when ALL of these hold:
  1. it is DEAD, decided by two independent signals, either of which keeps it:
       a. a live `gc nudge poll ... --session S <agent>` process whose sha256(S\\0agent)[:8] equals
          the stem's 16-hex suffix;
       b. the stem's .pid names a live process whose command line has `nudge poll` (looser than the
          engine's pidutil.AliveWithCmdline, which also matches session+agent: a PID reused by ANOTHER poller
          keeps the stem until that poller exits - seen once on the first run - and a PID reused by any
          other command does not keep it);
  2. its NEWEST file is at least --min-age-days old (default 7): a stem touched this week is
     never swept, so a poller that is about to restart is not raced;
  3. nobody holds its .pid.lock (taken LOCK_EX|LOCK_NB here; held -> skipped, counted).

"Cannot tell" is never folded into "nothing to do" or "dead":
  * `ps` fails, is empty, or does not contain THIS process      -> rc 2, nothing deleted
    (an empty process list is not "no pollers");
  * a live `nudge poll` process whose target cannot be parsed   -> rc 2, nothing deleted
    (it could own any stem, so no stem can be called dead);
  * a stem whose file times cannot be read, whose .pid exists but cannot be read, or whose .pid.lock can
    be neither opened nor locked for a reason other than "someone holds it"
                                                                -> kept, counted in kept_undecided, one
                                                                   WARN line each on stderr (first 20 of a run);
                                                                   never counted as kept_live;
  * the pollers dir missing                                     -> rc 2, never created (a wrong path);
  * a garbled/empty .pid is "no signal b", not "alive": signal a still covers every live poller.
What it never touches: a name that does not match <stem>.(pid|pid.lock|log), anything that is not a
regular file (symlinks, dirs), files of a live or young stem. It never uses rm: os.unlink per file.

Default is a DRY RUN; the order passes --apply. Every run appends its summary to --log.
rc: 0 ok, 1 some unlink failed (the rest is done), 2 cannot tell / refused (nothing deleted).
"""
import argparse
import datetime
import errno
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time

FILE_RE = re.compile(r"^(?P<stem>.+-(?P<digest>[0-9a-f]{16}))\.(?P<kind>pid\.lock|pid|log)$")
MAX_DELETES_DEFAULT = 100000   # a pollers dir this size is not a normal cleanup: stop and say so
MIN_AGE_DAYS_DEFAULT = 7.0
WARN_CAP = 20                  # stderr lines per run for "kept undecided"; the summary counts all of them
PID_LIVE, PID_NOT_LIVE, PID_UNREADABLE = "live", "not-live", "unreadable"


class CannotTell(Exception):
    """Raised where the honest answer is 'I cannot tell': the run must delete nothing (rc 2)."""


def snapshot_processes(ps_cmd):
    """pid -> command line, from a fresh `ps`. Fails loud: an empty or self-less list is NOT 'no pollers'."""
    try:
        res = subprocess.run(ps_cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        raise CannotTell(f"ps could not run: {exc}")
    if res.returncode != 0:
        raise CannotTell(f"ps rc={res.returncode}: {res.stderr.strip()[:120]}")
    procs = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            procs[int(parts[0])] = parts[1]
    # This very process must be in the list; if it is not, the snapshot is not a process table.
    if os.getpid() not in procs:
        raise CannotTell("ps output does not contain this process: not a usable process table")
    return procs


def loose_is_poll(cmdline):
    """Signal b only ever KEEPS a stem, so it may be loose: 'nudge' immediately followed by 'poll' anywhere."""
    argv = cmdline.split()
    return any(argv[i] == "nudge" and argv[i + 1] == "poll" for i in range(len(argv) - 1))


def poll_target(cmdline):
    """(session, agent) of a `gc nudge poll` command line; None when it is not a poller; raises CannotTell
    when it IS a poller but the target cannot be read. Mirrors argvHasPollTarget in the engine.
    Strict on purpose: argv[0] must be the gc binary, otherwise any process that merely MENTIONS 'nudge poll'
    (an editor, a `claude -p "..."` prompt) would be taken for a poller and abort every run with rc 2."""
    argv = cmdline.split()
    if not argv or not os.path.basename(argv[0]).startswith("gc"):
        return None
    for i in range(len(argv) - 1):
        if argv[i] != "nudge" or argv[i + 1] != "poll":
            continue
        session = ""
        j = i + 2
        while j < len(argv):
            arg = argv[j]
            if arg == "--session":
                if j + 1 >= len(argv):
                    raise CannotTell(f"poller without a --session value: {cmdline[:120]}")
                session = argv[j + 1]
                j += 2
            elif arg.startswith("--session="):
                session = arg[len("--session="):]
                j += 1
            elif arg in ("--city", "--interval", "--quiescence"):
                j += 2
            elif arg.startswith(("--city=", "--interval=", "--quiescence=")):
                j += 1
            elif arg.startswith("-"):
                if "=" not in arg and j + 1 < len(argv) and not argv[j + 1].startswith("-"):
                    j += 2
                else:
                    j += 1
            else:
                return session.strip(), arg.strip()
        raise CannotTell(f"poller without an agent argument: {cmdline[:120]}")
    return None


def stem_digest(session, agent):
    return hashlib.sha256((session.strip() + "\x00" + agent.strip()).encode()).digest()[:8].hex()


def live_digests(procs):
    """Digests of every live `nudge poll` process. Any poller whose target is unreadable aborts the run."""
    out = set()
    for cmdline in procs.values():
        tgt = poll_target(cmdline)
        if tgt is None:
            continue
        session, agent = tgt
        if not session or not agent:
            raise CannotTell(f"poller with an empty session/agent: {cmdline[:120]}")
        out.add(stem_digest(session, agent))
    return out


def pid_file_state(pid_path, procs):
    """Signal b, three answers (state, detail):
      PID_LIVE        the .pid names a live process whose command line has `nudge poll` (even one whose target we
                      cannot parse: keeping is the safe error);
      PID_NOT_LIVE    the .pid is missing, empty or garbled (no signal b, NOT 'alive': signal a still covers every
                      live poller), or names a dead PID, or a PID that exists but is some other command (PID reuse);
      PID_UNREADABLE  the .pid exists but cannot be read (EACCES, EIO...): we CANNOT TELL. The caller keeps the
                      stem (inert) but must count it as undecided and say so - it must not look like a live poller.
    detail is the OS error text for PID_UNREADABLE, else ''."""
    # vazio/lixo (sem dígitos) -> NOT_LIVE; ausente -> NOT_LIVE; falhou/ilegível (EACCES, EIO…) -> UNREADABLE (mantém E conta como undecided)
    try:
        with open(pid_path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read(64).strip()
    except FileNotFoundError:
        return PID_NOT_LIVE, ""
    except OSError as exc:
        return PID_UNREADABLE, str(exc)
    # ASCII digits only: str.isdigit() also accepts e.g. a superscript two, which int() rejects (ValueError -> every run dies)
    if not re.fullmatch(r"[0-9]+", text) or int(text) <= 0:
        return PID_NOT_LIVE, ""
    cmd = procs.get(int(text))
    # PID gone -> no signal; PID alive but not a `nudge poll` (reused PID) -> no signal;
    # alive and `nudge poll` (even one whose target we cannot parse) -> live: keeping is the safe error.
    if cmd is not None and loose_is_poll(cmd):
        return PID_LIVE, ""
    return PID_NOT_LIVE, ""


def collect_stems(pollers_dir):
    """stem -> {files: {kind: path}, digest, mtime: newest mtime of its files, mtime_ok: False if any stat failed}.
    Names that do not match the pattern, and anything that is not a regular file, are counted, never touched."""
    stems, ignored = {}, 0
    with os.scandir(pollers_dir) as it:
        for entry in it:
            m = FILE_RE.match(entry.name)
            # vazio -> n/a; falhou (is_file levanta) -> regular=False: o nome é ignorado, nunca apagado
            try:
                regular = entry.is_file(follow_symlinks=False)
            except OSError:
                regular = False
            if not m or not regular:
                ignored += 1
                continue
            rec = stems.setdefault(m.group("stem"), {"files": {}, "digest": m.group("digest"), "mtime": 0.0, "mtime_ok": True})
            rec["files"][m.group("kind")] = entry.path
            # vazio -> n/a (stat sempre devolve um mtime); falhou -> mtime_ok=False: o stem vira "kept_undecided", não é apagado
            try:
                rec["mtime"] = max(rec["mtime"], entry.stat(follow_symlinks=False).st_mtime)
            except OSError:
                rec["mtime_ok"] = False
    return stems, ignored


def append_log(path, summary):
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(summary, sort_keys=True) + "\n")
    except OSError as exc:
        print(f"WARN: could not append to log {path}: {exc}", file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--city", default=os.environ.get("GC_CITY", "."))
    ap.add_argument("--dir", help="pollers dir (default: <city>/.gc/nudges/pollers)")
    ap.add_argument("--min-age-days", type=float, default=MIN_AGE_DAYS_DEFAULT)
    ap.add_argument("--max-deletes", type=int, default=MAX_DELETES_DEFAULT)
    ap.add_argument("--apply", action="store_true", help="delete (default: dry run)")
    ap.add_argument("--log", help="append the run summary (json line) here")
    ap.add_argument("--ps-cmd", default="ps -axww -o pid=,command=", help="process table command (selftests inject failures)")
    args = ap.parse_args(argv)

    started = time.time()
    pollers_dir = args.dir or os.path.join(args.city, ".gc", "nudges", "pollers")
    summary = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
               "mode": "apply" if args.apply else "dry-run", "dir": pollers_dir, "min_age_days": args.min_age_days}

    undecided = {"shown": 0, "total": 0}

    def note_undecided(msg):
        """A stem kept because we could not tell. Always counted by the caller; the stderr line is capped so a
        systemic read problem (thousands of stems) does not drown the log, and finish() says how many were not shown."""
        undecided["total"] += 1
        if undecided["shown"] < WARN_CAP:
            undecided["shown"] += 1
            print(f"WARN: kept undecided: {msg}", file=sys.stderr)

    def finish(rc, **extra):
        if undecided["total"] > undecided["shown"]:
            print(f"WARN: ... and {undecided['total'] - undecided['shown']} more kept undecided (see kept_undecided)", file=sys.stderr)
        summary.update(extra)
        summary["rc"] = rc
        summary["elapsed_s"] = round(time.time() - started, 2)
        append_log(args.log, summary)
        print(json.dumps(summary, sort_keys=True))
        return rc

    if not (args.min_age_days >= 1):       # also refuses nan (nan < 1 is False and would make every dead stem eligible)
        return finish(2, error="--min-age-days must be a number >= 1: refusing (a stem touched today may be about to restart)")
    if not os.path.isdir(pollers_dir):
        # dir ausente -> rc 2, nunca criado (caminho errado, não "nada a limpar")
        return finish(2, error="pollers dir missing: not created, nothing to do")

    try:
        procs = snapshot_processes(args.ps_cmd.split())
        digests = live_digests(procs)
        # vazio -> dir sem stems: nada a fazer (rc 0); falhou/ilegível (ex.: scandir) -> exceção, nada apagado
        stems, ignored = collect_stems(pollers_dir)
    except CannotTell as exc:
        return finish(2, error=f"cannot tell: {exc}")
    except OSError as exc:
        return finish(2, error=f"cannot read pollers dir: {exc}")

    cutoff = time.time() - args.min_age_days * 86400
    counts = {"stems": len(stems), "files": sum(len(r["files"]) for r in stems.values()), "ignored_names": ignored,
              "live_pollers": len(digests), "kept_live": 0, "kept_young": 0, "kept_undecided": 0, "kept_locked": 0,
              "to_delete_stems": 0, "to_delete_files": 0}
    doomed = []
    for stem, rec in sorted(stems.items()):
        pid_state, pid_detail = PID_NOT_LIVE, ""
        if rec["digest"] not in digests and "pid" in rec["files"]:
            pid_state, pid_detail = pid_file_state(rec["files"]["pid"], procs)
        if rec["digest"] in digests or pid_state == PID_LIVE:
            counts["kept_live"] += 1
        elif pid_state == PID_UNREADABLE:
            counts["kept_undecided"] += 1          # .pid existe mas não lê -> mantém, mas como "não sei", nunca como "vivo"
            note_undecided(f"{rec['files']['pid']}: cannot read the .pid: {pid_detail}")
        elif not rec["mtime_ok"]:
            counts["kept_undecided"] += 1          # idade ilegível -> mantém
            note_undecided(f"{stem}: cannot read the file times")
        elif rec["mtime"] > cutoff:
            counts["kept_young"] += 1
        else:
            doomed.append((stem, rec))
    counts["to_delete_stems"] = len(doomed)
    counts["to_delete_files"] = sum(len(r["files"]) for _, r in doomed)

    if counts["to_delete_files"] > args.max_deletes:
        return finish(2, error=f"{counts['to_delete_files']} files to delete exceeds --max-deletes {args.max_deletes}: "
                               "not a normal cleanup, nothing deleted", **counts)
    if not args.apply:
        return finish(0, deleted_files=0, deleted_stems=0, unlink_errors=0, **counts)

    deleted_files = deleted_stems = errors = 0
    for stem, rec in doomed:
        lock_fh = None
        try:
            lock_path = rec["files"].get("pid.lock")
            if lock_path:
                # lock já sumiu (vazio) -> segue apagando o resto; falhou ao abrir por outro motivo -> mantém o stem (undecided)
                # Race residual: um poller que ENTRAR neste stem entre o flock e o unlink ficaria com um lock desvinculado do
                # nome e dois pollers poderiam disputar um lock novo. A janela é de microssegundos num stem parado há >= 7 dias
                # e sem poller vivo (os dois sinais acima), por isso não é fechada com mais código.
                try:
                    lock_fh = open(lock_path, "r+b")
                except FileNotFoundError:
                    lock_fh = None
                except OSError as exc:
                    counts["kept_undecided"] += 1
                    note_undecided(f"{lock_path}: cannot open the lock: {exc}")
                    continue
                if lock_fh is not None:
                    # lock livre -> segue; segurado por outro processo -> kept_locked; falhou por outro motivo -> kept_undecided
                    try:
                        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except OSError as exc:
                        if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                            counts["kept_locked"] += 1
                            continue
                        counts["kept_undecided"] += 1
                        note_undecided(f"{lock_path}: cannot lock: {exc}")
                        continue
            removed_all = True
            # the lock file goes last, while we still hold it
            for kind in ("pid", "log", "pid.lock"):
                path = rec["files"].get(kind)
                if not path:
                    continue
                try:
                    os.unlink(path)
                    deleted_files += 1
                except FileNotFoundError:
                    pass
                except OSError as exc:
                    errors += 1
                    removed_all = False
                    print(f"WARN: unlink {path}: {exc}", file=sys.stderr)
            if removed_all:
                deleted_stems += 1
        finally:
            if lock_fh is not None:
                lock_fh.close()
    return finish(1 if errors else 0, deleted_files=deleted_files, deleted_stems=deleted_stems, unlink_errors=errors, **counts)


if __name__ == "__main__":
    sys.exit(main())
