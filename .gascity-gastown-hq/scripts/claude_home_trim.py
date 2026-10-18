#!/usr/bin/env python3
"""claude_home_trim.py (ga-mnznp8) — keep ~/.claude from eating the disk Dolt lives on.

## Contents
- Why
- What it does
- Safety
- Switches
- Exit code

## Why
On 2026-10-18 the mini sat at 409-554 MB free (Dolt CRITICAL, 6 GB of swap). Two
files nothing ever rotates were 3.1 GB of it: ~/.claude/history.jsonl (1.55 GB; the
~20 Claude Code sessions of the city append a line per prompt) and
~/.claude/file-history (1.58 GB; one /rewind checkpoint folder per session). A manual
cut freed 2.3 GB. This is that cut, as a lever the disk-floor guard can call.

## What it does
1. history.jsonl — when it is over HISTORY_MAX_BYTES (100 MB), keep only its last
   HISTORY_KEEP_BYTES (40 MB), starting at a line break, rewritten IN THE SAME INODE
   (writers hold the file open for append, so a rename would orphan them).
2. file-history/<session-id>/ — delete a folder when nothing in it was touched for
   FILE_HISTORY_MIN_AGE_SECS (3 days) AND the session is not alive.
3. Report-only: size of usage-analytics.jsonl and credit-cache-updater.log, the two
   other files that grow here (written by ~/.claude/hooks/log-token-usage.sh and by
   the com.claude.credit-cache-updater launchd job). Neither is touched.

## Safety
A folder of file-history is only deleted when ALL of these hold, and the answer to each
has three states (has / has not / could not find out) — "could not find out" always keeps
the folder AND ends the part INCOMPLETE (exit 1), never "OK":
- the name is a session UUID and the entry is a real directory (never a symlink);
- the newest mtime of the folder and of everything in it is older than the age;
- it is not the caller's own session (CLAUDE_CODE_SESSION_ID);
- `gc session list --json` answered and its session_key set does not contain it (a
  failed or malformed answer keeps EVERY folder, never reads as "nobody is alive"; neither
  does a non-empty list in which no entry has a session_key — a renamed field);
- no transcript projects/*/<session-id>.jsonl was written within the age either (a
  session that is open but only talking, not editing, keeps its transcript fresh; this
  also protects a live session `gc session list` lists without a session_key — 3 of 20 on
  2026-10-18). A project dir that cannot be searched counts as "could not find out".
history.jsonl is only cut when it is a regular file, the cut point is a line break
that really exists in the last KEEP bytes, the path still names the file we hold, and the
file did not shrink under us.
The cut copies the lines appended while it ran, for at most COPYBACK_MAX_ROUNDS rounds.
Two losses are left: the few microseconds between the last size check and the ftruncate,
where a line appended in that gap is lost without a trace; and a writer that outruns all
the rounds, which is counted and reported ("DROPPED n byte(s)", state "lossy", exit 1).
history.jsonl is Claude Code's prompt-recall list (up-arrow). The only
other reader found is the daily 04:00 com.athos.claude-history-backup, which `cp`s it to S3:
after a cut that copy holds only the kept part, while the session transcripts (the real
record, ~/.claude/projects) are synced separately and are not touched here. One lost line
costs less than the 1.5 GB of disk.

## Switches
CLAUDE_HOME_TRIM_HOME (default /Users/athos/.claude), _HISTORY_MAX_BYTES,
_HISTORY_KEEP_BYTES, _FILE_HISTORY_MIN_AGE_SECS, _GC_BIN (gc), _ENABLED=0 or _DRY_RUN=1
(report what it would do, change nothing).
PRODUCTION SENTINEL (same ga-h565g idea as transcript-reaper.sh): when the resolved home
is the real ~/.claude and CLAUDE_HOME_TRIM_PROD is not 1, it runs as a dry-run. Only the
real caller (dolt-disk-floor-guard.sh, _trim_claude_home) sets it; a test that forgets to
point at a fixture cannot cut the real files.

## Exit code
0 = every part ran (nothing to do counts; a home that does not exist counts). 1 = a part
failed, lost lines, or had to be skipped or keep something because a thing it needs to be
sure of could not be read (including the home itself, or a home that is not a directory);
the lines above say which.
"""
import errno
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

REAL_DEFAULT_HOME = "/Users/athos/.claude"
SESSION_ID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
)
GC_LIST_TIMEOUT_SECS = 60
COPYBACK_MAX_ROUNDS = 8

# part states. OK_STATES are the ones that do not make the run INCOMPLETE.
OK_STATES = {"absent", "under", "rotated", "none-old", "pruned", "dry-run"}


def log(msg):
    print("claude-home-trim: %s" % msg, flush=True)


def cfg_int(name, default):
    """Positive integer from the environment. Unset/empty → default. Anything that is not a
    positive integer → None, and the caller SKIPs that part: a limit the script cannot read is
    never guessed (a guessed one could cut or delete more than was meant)."""
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    if re.fullmatch(r"[0-9]+", raw) and int(raw) > 0:
        return int(raw)
    log("%s='%s' is not a positive integer" % (name, raw))
    return None


def mb(n):
    return int(n) // 1048576


def _pread_all(fd, length, offset):
    chunks = []
    got = 0
    while got < length:
        piece = os.pread(fd, min(length - got, 1 << 24), offset + got)
        if not piece:
            raise OSError(errno.EIO, "short read at offset %d" % (offset + got))
        chunks.append(piece)
        got += len(piece)
    return b"".join(chunks)


def _pwrite_all(fd, data, offset):
    view = memoryview(data)
    done = 0
    while done < len(view):
        done += os.pwrite(fd, view[done:], offset + done)


# ─── 1. history.jsonl ────────────────────────────────────────────────────────


def rotate_history(path, max_bytes, keep_bytes, dry_run):
    """Returns (state, freed_bytes)."""
    if max_bytes is None or keep_bytes is None:
        log("history: SKIP — a size limit is not readable (see above); nothing cut")
        return "failed", 0
    if keep_bytes >= max_bytes:
        log(
            "history: SKIP — KEEP (%d) is not smaller than MAX (%d); a cut that keeps "
            "everything would never shrink the file" % (keep_bytes, max_bytes)
        )
        return "failed", 0
    # vazio → the file does not exist: nothing to rotate; falhou/ilegível → left alone, reported
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    except FileNotFoundError:
        log("history: %s does not exist — nothing to rotate" % path)
        return "absent", 0
    except OSError as exc:
        log("history: SKIP — cannot open %s read-write (%s); left untouched" % (path, exc))
        return "failed", 0
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            log("history: SKIP — %s is not a regular file; left untouched" % path)
            return "failed", 0
        size0 = st.st_size
        if size0 <= max_bytes:
            log("history: %d MB, under the %d MB cap — nothing to cut" % (mb(size0), mb(max_bytes)))
            return "under", 0

        # Read the last KEEP bytes plus the one byte before them: if that byte is a line break,
        # the window already starts on a line; otherwise drop up to the first break.
        start = size0 - keep_bytes
        try:
            window = _pread_all(fd, size0 - (start - 1), start - 1)
        except OSError as exc:
            log("history: SKIP — could not read the tail of %s (%s); left untouched" % (path, exc))
            return "failed", 0
        brk = window.find(b"\n")
        if brk < 0:
            log(
                "history: SKIP — no line break in the last %d bytes of %s; a cut would "
                "split a line, so the file is left untouched" % (keep_bytes, path)
            )
            return "failed", 0
        kept = window[brk + 1 :]
        if not kept:
            log("history: SKIP — the last line break is the final byte; nothing would be kept")
            return "failed", 0
        del window

        if dry_run:
            log(
                "history: DRY-RUN — would cut %s from %d MB to %d MB (same inode)"
                % (path, mb(size0), mb(len(kept)))
            )
            return "dry-run", 0

        # The path must still name the file we hold: a writer or janitor that replaced it
        # while we were reading would make this cut hit an unlinked inode.
        try:
            now_st = os.stat(path)
        except OSError as exc:
            log("history: SKIP — %s vanished while reading (%s); left untouched" % (path, exc))
            return "failed", 0
        if (now_st.st_ino, now_st.st_dev) != (st.st_ino, st.st_dev):
            log("history: SKIP — %s was replaced while reading (new inode); left untouched" % path)
            return "failed", 0
        if os.fstat(fd).st_size < size0:
            log("history: SKIP — %s shrank while reading (someone else cut it); left untouched" % path)
            return "failed", 0

        # Critical section: from the first write to the ftruncate the file is "kept + stale
        # bytes". Block the polite signals so the guard's `timeout` cannot land in the middle
        # (SIGKILL cannot be blocked; the window is the time of one 40 MB write, a fraction of a second).
        blocked = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
        dropped = 0  # bytes seen at the end of the file that the copy-back did not carry over
        try:
            _pwrite_all(fd, kept, 0)
            total = len(kept)
            seen = size0  # bytes [0, seen) of the original file are accounted for
            rounds = 0
            while True:
                cur = os.fstat(fd).st_size
                if cur <= seen:
                    break
                if rounds >= COPYBACK_MAX_ROUNDS:
                    # The file is still growing after the last round. The head is already
                    # overwritten, so the tail must go (a stale stretch in the middle is worse);
                    # what is dropped is counted here and reported below, never silent.
                    dropped = cur - seen
                    break
                extra = _pread_all(fd, cur - seen, seen)
                _pwrite_all(fd, extra, total)
                total += len(extra)
                seen = cur
                rounds += 1
            os.ftruncate(fd, total)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        log(
            "history: CUT %s from %d MB to %d MB, freed≈%d MB (same inode, cut at a line break)"
            % (path, mb(seen), mb(total), mb(seen - total))
        )
        if dropped:
            log(
                "history: DROPPED %d byte(s) appended while the copy-back was still catching up "
                "(the file kept growing for %d rounds); those lines are gone from %s"
                % (dropped, COPYBACK_MAX_ROUNDS, path)
            )
            return "lossy", seen - total
        return "rotated", seen - total
    except OSError as exc:
        log(
            "history: FAILED while cutting %s (%s) — the file may hold a stale stretch in "
            "the middle; check it" % (path, exc)
        )
        return "failed", 0
    finally:
        os.close(fd)


# ─── 2. file-history ─────────────────────────────────────────────────────────


def fetch_live_keys(gc_bin):
    """Set of session_key strings from `gc session list --json`, or None when the answer cannot
    be trusted (a failure must never read as "nobody is alive")."""
    # vazio → a well-formed answer with zero sessions is a real empty set; falhou/ilegível → None
    try:
        proc = subprocess.run(
            [gc_bin, "session", "list", "--json"],
            capture_output=True,
            text=True,
            timeout=GC_LIST_TIMEOUT_SECS,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log("file-history: ABORT — `gc session list --json` could not run (%s)" % exc)
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        log("file-history: ABORT — `gc session list --json` failed (rc=%d) or was empty" % proc.returncode)
        return None
    try:
        data = json.loads(proc.stdout)
        sessions = data["sessions"]
    except (ValueError, KeyError, TypeError):
        log("file-history: ABORT — `gc session list --json` answer is not {\"sessions\": [...]}")
        return None
    if not isinstance(sessions, list):
        log("file-history: ABORT — `.sessions` is not an array")
        return None
    keys = set()
    keyless = 0
    for entry in sessions:
        key = entry.get("session_key") if isinstance(entry, dict) else None
        if isinstance(key, str) and key:
            keys.add(key)
        else:
            keyless += 1
    if sessions and not keys:
        # Every entry without a key is what a renamed field would look like, and it would read as
        # a valid "nobody is alive" — so a non-empty list that yields no key is not believed.
        log(
            "file-history: ABORT — `gc session list --json` lists %d session(s) and none has a "
            "session_key (did the field change?); liveness not established" % len(sessions)
        )
        return None
    if keyless:
        log(
            "file-history: %d of %d listed session(s) have no session_key; their folders are "
            "protected by the transcript check only" % (keyless, len(sessions))
        )
    return keys


def newest_mtime(path):
    """Newest mtime of a folder and everything under it; None when any part cannot be read."""
    newest = 0.0
    try:
        newest = os.lstat(path).st_mtime
        for dirpath, dirnames, filenames in os.walk(path, followlinks=False, onerror=_raise):
            for name in dirnames + filenames:
                newest = max(newest, os.lstat(os.path.join(dirpath, name)).st_mtime)
    except OSError:
        return None
    return newest


def _raise(exc):
    raise exc


def tree_bytes(path):
    """Allocated bytes under path (best effort; only used for the freed figure)."""
    # vazio → 0 bytes; falhou/ilegível → that entry counts 0: this is a measurement for the log, never an input to a keep/delete decision
    total = 0
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_blocks * 512
            except OSError:
                pass
    return total


def transcript_recent(projects, project_dirs, name, now, min_age_secs):
    """Three-state look at projects/*/<name>.jsonl → (recent, unknown).
    recent  — a transcript of the session was written within the age.
    unknown — somewhere a transcript could be, it could not be read (a project dir that cannot
              be searched, a transcript that cannot be stat'ed). The caller keeps the folder and
              reports the part as INCOMPLETE; glob.glob would have swallowed that error and
              answered "no transcript", which is the answer that deletes the folder.
    (False, 0) means every project dir answered and none holds a fresh transcript."""
    recent = False
    unknown = 0
    for project in project_dirs:
        candidate = os.path.join(projects, project, name + ".jsonl")
        # vazio → no such transcript in this project dir (ENOENT, or the entry is not a directory): nothing to protect here; falhou/ilegível → any other error is unknown, the folder is kept and the part is INCOMPLETE
        try:
            mtime = os.lstat(candidate).st_mtime
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            unknown += 1
            continue
        if now - mtime < min_age_secs:  # also true for a future mtime: never stale
            recent = True
    return recent, unknown


def prune_file_history(home, min_age_secs, now, dry_run, gc_bin, self_sid):
    """Returns (state, freed_bytes)."""
    if min_age_secs is None:
        log("file-history: SKIP — the age limit is not readable (see above); nothing deleted")
        return "failed", 0
    root = os.path.join(home, "file-history")
    # vazio → no file-history folder: nothing to prune; falhou/ilegível → reported, nothing deleted
    try:
        names = sorted(os.listdir(root))
    except FileNotFoundError:
        log("file-history: %s does not exist — nothing to prune" % root)
        return "absent", 0
    except OSError as exc:
        log("file-history: SKIP — cannot list %s (%s); nothing deleted" % (root, exc))
        return "failed", 0
    real_root = os.path.realpath(root)

    old = []  # (name, path, age_secs) — old enough, not yet checked for liveness
    spared = {"young": 0, "unreadable": 0, "not-a-session-dir": 0}
    unsure = 0  # folders kept because something about them could not be read: the part ends INCOMPLETE
    for name in names:
        path = os.path.join(root, name)
        try:
            st = os.lstat(path)
        except OSError as exc:
            spared["unreadable"] += 1
            unsure += 1
            log("file-history: %s KEPT — cannot read it (%s), so its age is unknown" % (name, exc))
            continue
        if not stat.S_ISDIR(st.st_mode) or not SESSION_ID_RE.match(name):
            spared["not-a-session-dir"] += 1
            continue
        newest = newest_mtime(path)
        if newest is None:
            spared["unreadable"] += 1
            unsure += 1
            log("file-history: %s KEPT — part of it cannot be read, so its age is unknown" % name)
            continue
        age = now - newest
        if age < min_age_secs:  # also true for a future mtime (negative age): never stale
            spared["young"] += 1
            continue
        old.append((name, path, age))

    if not old:
        log(
            "file-history: %d folder(s), none untouched for %d days (spared: young=%d, "
            "unreadable=%d, not-a-session-dir=%d)"
            % (len(names), min_age_secs // 86400, spared["young"], spared["unreadable"], spared["not-a-session-dir"])
        )
        return ("failed" if unsure else "none-old"), 0

    projects = os.path.join(home, "projects")
    # vazio → projects/ exists and has no entries: no transcript can be fresh, an empty list is a real answer; falhou/ilegível → absent or cannot be listed: ABORT, nothing deleted
    try:
        project_dirs = sorted(os.listdir(projects))
    except OSError as exc:
        log(
            "file-history: ABORT — cannot list %s (%s), so recent transcripts cannot be "
            "checked; %d old folder(s) kept" % (projects, exc, len(old))
        )
        return "failed", 0
    live = fetch_live_keys(gc_bin)
    if live is None:
        log("file-history: ABORT — liveness not established; %d old folder(s) kept" % len(old))
        return "failed", 0

    deleted = 0
    freed = 0
    failed = 0
    for name, path, age in old:
        if self_sid and name == self_sid:
            log("file-history: %s SPARED (the caller's own session)" % name)
            continue
        if name in live:
            log("file-history: %s SPARED (listed by gc session list)" % name)
            continue
        recent, unknown = transcript_recent(projects, project_dirs, name, now, min_age_secs)
        if unknown:
            unsure += 1
            log(
                "file-history: %s KEPT — %d place(s) that could hold its transcript could not be "
                "read, so it cannot be shown idle" % (name, unknown)
            )
            continue
        if recent:
            log("file-history: %s SPARED (its transcript was written within the last %d days)" % (name, min_age_secs // 86400))
            continue
        if os.path.dirname(os.path.realpath(path)) != real_root:
            log("file-history: %s SPARED (does not resolve to a direct child of %s)" % (name, root))
            continue
        size = tree_bytes(path)
        if dry_run:
            log("file-history: DRY-RUN would delete %s (%d MB, idle %d days)" % (name, mb(size), int(age) // 86400))
            continue
        shutil.rmtree(path, ignore_errors=True)
        if os.path.lexists(path):
            failed += 1
            log("file-history: %s DELETE PARTIAL — the folder is still there after rmtree" % name)
        else:
            deleted += 1
            freed += size
            log("file-history: DELETED %s (%d MB, idle %d days)" % (name, mb(size), int(age) // 86400))
    if not dry_run:
        log("file-history: deleted=%d failed=%d kept-unsure=%d freed≈%d MB" % (deleted, failed, unsure, mb(freed)))
    if failed or unsure:
        return "failed", freed
    return ("dry-run", 0) if dry_run else ("pruned", freed)


# ─── 3. report-only ──────────────────────────────────────────────────────────


def report_sizes(home):
    parts = []
    for rel in ("usage-analytics.jsonl", "credit-cache-updater.log", "history.jsonl"):
        try:
            parts.append("%s=%dMB" % (rel, mb(os.lstat(os.path.join(home, rel)).st_size)))
        except FileNotFoundError:
            parts.append("%s=absent" % rel)
        except OSError:
            parts.append("%s=unreadable" % rel)
    parts.append("file-history=%dMB" % mb(tree_bytes(os.path.join(home, "file-history"))))
    log("measure (usage-analytics.jsonl and credit-cache-updater.log are report-only, not trimmed): " + " ".join(parts))


def main():
    home = os.environ.get("CLAUDE_HOME_TRIM_HOME", REAL_DEFAULT_HOME)
    dry_run = os.environ.get("CLAUDE_HOME_TRIM_DRY_RUN", "0") == "1"
    if os.environ.get("CLAUDE_HOME_TRIM_ENABLED", "1") != "1":
        log("DISABLED (CLAUDE_HOME_TRIM_ENABLED != 1) — running as a dry-run")
        dry_run = True
    if os.path.realpath(home) == os.path.realpath(REAL_DEFAULT_HOME) and os.environ.get("CLAUDE_HOME_TRIM_PROD") != "1":
        log("SENTINEL: the home is the real %s and CLAUDE_HOME_TRIM_PROD=1 is not set — forcing a dry-run" % REAL_DEFAULT_HOME)
        dry_run = True
    # vazio → the home does not exist: nothing to trim, exit 0; falhou/ilegível → it cannot be stat'ed or is not a directory: nothing was trimmed, exit 1 so the guard logs INCOMPLETE
    try:
        home_st = os.stat(home)
    except FileNotFoundError:
        log("home %s does not exist — nothing to do" % home)
        return 0
    except OSError as exc:
        log("home %s cannot be read (%s) — nothing was trimmed" % (home, exc))
        return 1
    if not stat.S_ISDIR(home_st.st_mode):
        log("home %s is not a directory — nothing was trimmed" % home)
        return 1

    max_bytes = cfg_int("CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES", 100 * 1048576)
    keep_bytes = cfg_int("CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES", 40 * 1048576)
    min_age = cfg_int("CLAUDE_HOME_TRIM_FILE_HISTORY_MIN_AGE_SECS", 3 * 86400)
    gc_bin = os.environ.get("CLAUDE_HOME_TRIM_GC_BIN", "gc")
    self_sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    now = time.time()

    h_state, h_freed = rotate_history(os.path.join(home, "history.jsonl"), max_bytes, keep_bytes, dry_run)
    f_state, f_freed = prune_file_history(home, min_age, now, dry_run, gc_bin, self_sid)
    report_sizes(home)

    complete = h_state in OK_STATES and f_state in OK_STATES
    log(
        "%s — history=%s file-history=%s freed≈%d MB dry_run=%d"
        % ("OK" if complete else "INCOMPLETE", h_state, f_state, mb(h_freed + f_freed), 1 if dry_run else 0)
    )
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main())
