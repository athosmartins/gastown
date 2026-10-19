#!/usr/bin/env python3
"""claude-security-janitor.py (ga-j4r9o8) — keep the security-guidance plugin from eating the mini's disk.

## Contents
- Why
- What it does
- Safety
- Switches
- Exit code
- Not here

## Why
On 2026-10-19 the official `security-guidance` plugin (2.0.14) was costing the mini ~1.5 GB
twice over. (1) Its SessionStart hook `ensure_agent_sdk.py` tests the SDK in a venv with
`import claude_agent_sdk` under a 10 s timeout; at load 40-50 a cold import takes ~15 s, so
the venv looks "broken", is rebuilt (`venv --clear` + a 108 MB `pip install`, no cache), the
120 s timeout kills the install and leaves `pip-unpack-*` in TMPDIR (381 dirs / 797 MB that
day), and the next session repeats it. The Mayor broke the loop by installing
`claude-agent-sdk` once into the brew python3.13 that `sg-python.sh` picks (the hook then
answers NOOP_SYSTEM via `importlib.util.find_spec`). (2) The plugin writes
`security_warnings_state_<session>.json|.lock` per session into ~/.claude/security and only
sweeps those after 30 days (`cleanup_old_state_files`): ~10,000 files, ~55 MB/day.

## What it does
1. State files — delete `security_warnings_state_*` ending in `.json`, `.lock` or `.tmp`
   (the plugin's own three shapes) in ~/.claude/security when their mtime is older than
   STATE_MAX_AGE (3 days).
2. pip debris — delete `pip-{unpack,metadata,install,ephem-wheel-cache,build-tracker}-*`
   directories in the user temp dir (`getconf DARWIN_USER_TEMP_DIR`, the TMPDIR the hook's
   pip runs in) when older than PIP_MAX_AGE (2 h) AND no pip process is alive.

## Safety
Every read has three outcomes — has / has not / could not find out — and "could not find
out" lands in the inert state, never in "nothing there" and never in a delete:
- the security dir is listed in full BEFORE anything is acted on; a listing that fails (or
  fails half way) deletes nothing and ends the part INCOMPLETE. A dir that does not exist is
  "absent" (nothing to clean); any other error is INCOMPLETE;
- only regular files, never symlinks, with the exact name shape; an entry whose stat fails
  is kept and counted; a file whose mtime/inode changed between the listing and the unlink
  (a session just wrote it) is kept;
- pip dirs: exact name regex, real directory (not a symlink), older than the age on its own
  mtime. Before the first delete `ps -Ao command=` must answer non-empty (empty or failing
  = cannot tell = keep everything, INCOMPLETE) and no command line may START as a pip /
  `-m pip` / `-m ensurepip` / `ensure_agent_sdk.py` run (anchored at the start so a Claude
  agent whose argv merely quotes "pip" does not freeze the sweep; `pipedrive_*` never
  matches). A live pip keeps everything and is NOT an error (it retries next hour). After
  rmtree the path is looked at again: ENOENT = deleted; still there = PARTIAL; any other
  error = UNVERIFIED (both INCOMPLETE);
- one instance at a time (flock); the loser exits 0;
- PRODUCTION SENTINEL (same ga-h565g idea as claude_home_trim.py): a target that resolves to
  the real ~/.claude/security or the real user temp dir is only ever a dry run unless
  CLAUDE_SECURITY_JANITOR_PROD=1. The plist sets it; a test or a manual run that forgets to
  point at a fixture cannot delete real files.

## Switches
CLAUDE_SECURITY_JANITOR_DIR (default /Users/athos/.claude/security), _TMPDIR (default
`getconf DARWIN_USER_TEMP_DIR`), _STATE_MAX_AGE_SECS, _PIP_MAX_AGE_SECS, _PS_BIN (ps), _LOCK
(single-instance lock, default <city>/.gc/runtime/claude-security-janitor.lock), _ENABLED=0
(no-op), _DRY_RUN=1 or --dry-run (report only: nothing deleted), _PROD=1 (see above).
Test seams for the production sentinel: _REAL_DIR and _REAL_TMPDIR say which path counts as "the
real one" (defaults: the constants above / getconf), so the selftest can declare a fixture real.

## Exit code
0 = every part ran (nothing to do counts; another instance holding the lock counts).
1 = a part was INCOMPLETE (could not read / could not confirm a delete / a bad limit); the lines
above say which.

## Not here
The check that the hook's python still has claude_agent_sdk (and its notify alarm), from the same
bead, ships as a separate slice on top of this one.
"""
import errno
import fcntl
import os
import re
import shutil
import stat
import subprocess
import sys
import time

REAL_SECURITY_DIR = "/Users/athos/.claude/security"
STATE_PREFIX = "security_warnings_state_"
STATE_SUFFIXES = (".json", ".lock", ".tmp")
PIP_DIR_RE = re.compile(
    r"^pip-(?:unpack|metadata|install|ephem-wheel-cache|build-tracker)-[A-Za-z0-9_]+$"
)
# A command line that STARTS as a pip run: `pip ...`, `<python> [args] -m pip|ensurepip ...`
# (also `-Im ensurepip`, how venv bootstraps pip) or `<python> [args] .../ensure_agent_sdk.py`.
# Anchored at the first token: only a process that IS python/pip counts, never an agent whose
# argv merely contains such a command.
_PY = r"\S*[Pp]ython[0-9.]*"
_PY_OPTS = r"(?:\S+\s+)*?"
PIP_LIVE_RES = [
    re.compile(r"^(?:\S*/)?pip[0-9.]*(?:\s|$)"),
    re.compile(r"^" + _PY + r"\s+" + _PY_OPTS + r"-[A-Za-z]*m\s+(?:pip|ensurepip)(?:\s|$)"),
    re.compile(r"^" + _PY + r"\s+" + _PY_OPTS + r"\S*ensure_agent_sdk\.py(?:\s|$)"),
]
PS_TIMEOUT_SECS = 30

# part states. OK_STATES are the ones that do not make the run INCOMPLETE.
OK_STATES = {"absent", "none-old", "pruned", "dry-run", "pip-live"}


def log(msg):
    print("claude-security-janitor: %s" % msg, flush=True)


def cfg_int(name, default):
    """Positive integer from the environment. Unset/empty -> default. Anything that is not a
    positive integer -> None, and the caller SKIPs that part: a limit the script cannot read is
    never guessed (a guessed one could delete more than was meant)."""
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    if re.fullmatch(r"[0-9]+", raw) and int(raw) > 0:
        return int(raw)
    log("%s='%s' is not a positive integer" % (name, raw))
    return None


def is_real_target(path, real):
    """True when `path` is the production location `real`. A path that cannot be resolved
    counts as real: the sentinel then keeps the run a dry run instead of guessing it is a fixture."""
    if real is None:
        return True
    try:
        return os.path.realpath(path) == os.path.realpath(real)
    except (OSError, ValueError):
        return True


def real_user_temp_dir():
    """The per-user temp dir the hook's pip runs in. None when it cannot be asked."""
    # vazio -> None (caller falls back to $TMPDIR and treats it as the real one);
    # falhou/ilegivel -> None, same: with no explicit _TMPDIR fixture the sentinel keeps it a dry run,
    # so nothing is deleted on a guess.
    try:
        r = subprocess.run(
            ["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None
    out = r.stdout.strip()
    if r.returncode != 0 or not out.startswith("/"):
        return None
    return out


def human(n):
    return "%.1f MB" % (n / 1048576.0)


# ── 1. state files ──────────────────────────────────────────────────────────────────────────


def sweep_state(sec_dir, max_age, now, dry):
    """Returns (state, text). Never deletes anything unless the whole dir was listed."""
    # vazio (no entries) -> "none-old", nothing to do; dir missing -> "absent", nothing to do;
    # falhou/ilegivel (scandir or the iteration raised) -> "unreadable" and NOTHING is deleted.
    try:
        with os.scandir(sec_dir) as it:
            entries = list(it)
    except FileNotFoundError:
        return "absent", "%s does not exist" % sec_dir
    except OSError as e:
        return "unreadable", "cannot list %s: %s" % (sec_dir, e)

    old = []
    kept_fresh = 0
    unreadable = 0
    nonregular = 0
    for e in entries:
        name = e.name
        if not (name.startswith(STATE_PREFIX) and name.endswith(STATE_SUFFIXES)):
            continue
        # vazio -> n/a (the entry exists, it was just listed); falhou -> entry KEPT and counted.
        try:
            st = e.stat(follow_symlinks=False)
        except OSError:
            unreadable += 1
            continue
        if not stat.S_ISREG(st.st_mode):
            nonregular += 1
            continue
        if now - st.st_mtime > max_age:
            old.append((e.path, st))
        else:
            kept_fresh += 1

    deleted = gone = failed = changed = 0
    freed = 0
    for path, st in old:
        if dry:
            continue
        # vazio (ENOENT: someone else removed it) -> counted as gone; falhou/ilegivel -> KEPT, counted failed.
        try:
            st2 = os.lstat(path)
        except FileNotFoundError:
            gone += 1
            continue
        except OSError:
            failed += 1
            continue
        if st2.st_mtime != st.st_mtime or st2.st_ino != st.st_ino:
            changed += 1  # written (or replaced) since the listing: not stale any more
            continue
        try:
            os.unlink(path)
        except FileNotFoundError:
            gone += 1
        except OSError:
            failed += 1
        else:
            deleted += 1
            freed += st.st_size

    would = sum(st.st_size for _, st in old)
    tail = "kept_fresh=%d changed=%d unreadable=%d nonregular=%d" % (
        kept_fresh, changed, unreadable, nonregular)
    if dry:
        sample = " ".join(os.path.basename(p) for p, _ in old[:3])
        return "dry-run", "DRY-RUN would delete %d file(s) %s; %s; e.g. %s" % (
            len(old), human(would), tail, sample)
    if failed or unreadable:
        return "incomplete", "deleted=%d (%s) gone=%d FAILED=%d; %s" % (
            deleted, human(freed), gone, failed, tail)
    if deleted or gone:
        return "pruned", "deleted=%d (%s) gone=%d; %s" % (deleted, human(freed), gone, tail)
    return "none-old", "nothing older than %d s; %s" % (max_age, tail)


# ── 2. pip debris ───────────────────────────────────────────────────────────────────────────


def pip_alive(ps_bin):
    """Returns (True|False|None, text). None = could not tell."""
    # vazio (no output) -> None, a live system always has processes so empty means ps did not
    # really run; falhou/ilegivel (rc != 0, timeout, missing binary) -> None. Both KEEP everything.
    try:
        r = subprocess.run(
            [ps_bin, "-Ao", "command="], capture_output=True, text=True, timeout=PS_TIMEOUT_SECS
        )
    except (OSError, subprocess.SubprocessError) as e:
        return None, "ps failed: %s" % e
    if r.returncode != 0 or not r.stdout.strip():
        return None, "ps rc=%s, %d byte(s) of output" % (r.returncode, len(r.stdout))
    for line in r.stdout.splitlines():
        line = line.strip()
        for rx in PIP_LIVE_RES:
            if rx.match(line):
                return True, line[:120]
    return False, ""


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def sweep_pip(tmp_dir, max_age, now, dry, ps_bin):
    """Returns (state, text)."""
    # vazio (no entries) -> "none-old"; dir missing -> "absent"; falhou/ilegivel -> "unreadable", nothing deleted.
    try:
        with os.scandir(tmp_dir) as it:
            entries = list(it)
    except FileNotFoundError:
        return "absent", "%s does not exist" % tmp_dir
    except OSError as e:
        return "unreadable", "cannot list %s: %s" % (tmp_dir, e)

    old = []
    kept_fresh = 0
    unreadable = 0
    for e in entries:
        if not PIP_DIR_RE.match(e.name):
            continue
        # falhou -> entry KEPT and counted (never read as "not old").
        try:
            if e.is_symlink() or not e.is_dir(follow_symlinks=False):
                continue
            st = e.stat(follow_symlinks=False)
        except OSError:
            unreadable += 1
            continue
        if now - st.st_mtime > max_age:
            old.append((e.path, st))
        else:
            kept_fresh += 1

    tail = "kept_fresh=%d unreadable=%d" % (kept_fresh, unreadable)
    if not old:
        return ("incomplete" if unreadable else "none-old"), "no pip-* dir older than %d s; %s" % (
            max_age, tail)

    alive, why = pip_alive(ps_bin)
    if alive is None:
        return "incomplete", "cannot tell whether pip is running (%s): kept %d old dir(s); %s" % (
            why, len(old), tail)
    if alive:
        return "pip-live", "a pip is running (%s): kept %d old dir(s), retry next run; %s" % (
            why, len(old), tail)

    if dry:
        return "dry-run", "DRY-RUN would delete %d dir(s); %s; e.g. %s" % (
            len(old), tail, " ".join(os.path.basename(p) for p, _ in old[:3]))

    deleted = partial = unverified = 0
    freed = 0
    for path, _st in old:
        # falhou while sizing -> size counts as 0 (only the report is affected, never the delete).
        size = dir_size(path)
        shutil.rmtree(path, ignore_errors=True)
        # vazio (ENOENT) -> deleted; still there -> PARTIAL; any other error -> UNVERIFIED.
        try:
            os.lstat(path)
        except FileNotFoundError:
            deleted += 1
            freed += size
        except OSError:
            unverified += 1
        else:
            partial += 1
    if partial or unverified or unreadable:
        return "incomplete", "deleted=%d (%s) PARTIAL=%d UNVERIFIED=%d; %s" % (
            deleted, human(freed), partial, unverified, tail)
    return "pruned", "deleted=%d dir(s) (%s); %s" % (deleted, human(freed), tail)


# ── main ────────────────────────────────────────────────────────────────────────────────────


def acquire_lock(lock_path):
    """Returns (fd|None, held_by_other). A lock that cannot be taken for any other reason is an error."""
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return None, True
        raise
    return fd, False


def main(argv):
    if "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0
    env = os.environ.get
    if env("CLAUDE_SECURITY_JANITOR_ENABLED", "1") != "1":
        log("CLAUDE_SECURITY_JANITOR_ENABLED != 1: no-op")
        return 0
    dry_all = "--dry-run" in argv or env("CLAUDE_SECURITY_JANITOR_DRY_RUN", "0") == "1"
    prod = env("CLAUDE_SECURITY_JANITOR_PROD", "0") == "1"
    city = env("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
    lock_path = env("CLAUDE_SECURITY_JANITOR_LOCK", "") or os.path.join(
        city, ".gc", "runtime", "claude-security-janitor.lock")

    real_sec = env("CLAUDE_SECURITY_JANITOR_REAL_DIR", "") or REAL_SECURITY_DIR
    sec_dir = env("CLAUDE_SECURITY_JANITOR_DIR", "") or real_sec
    real_tmp = env("CLAUDE_SECURITY_JANITOR_REAL_TMPDIR", "") or real_user_temp_dir()
    tmp_override = env("CLAUDE_SECURITY_JANITOR_TMPDIR", "")
    tmp_dir = tmp_override or real_tmp or env("TMPDIR", "")
    if tmp_override and real_tmp is None:
        tmp_real_target = False  # an explicit fixture path and no real dir to confuse it with
    else:
        tmp_real_target = is_real_target(tmp_dir, real_tmp) if tmp_dir else True
    sec_real_target = is_real_target(sec_dir, real_sec)

    try:
        lock_fd, other = acquire_lock(lock_path)
    except OSError as e:
        log("cannot take the lock %s: %s — nothing done" % (lock_path, e))
        return 1
    if other:
        log("another run holds the lock: exiting")
        return 0

    now = time.time()
    state_age = cfg_int("CLAUDE_SECURITY_JANITOR_STATE_MAX_AGE_SECS", 3 * 86400)
    pip_age = cfg_int("CLAUDE_SECURITY_JANITOR_PIP_MAX_AGE_SECS", 2 * 3600)
    ps_bin = env("CLAUDE_SECURITY_JANITOR_PS_BIN", "ps")

    rc = 0
    results = []

    def run_part(name, fn):
        nonlocal rc
        try:
            state, text = fn()
        except Exception as e:  # one part crashing must not skip the others, nor look like success
            state, text = "incomplete", "crashed: %r" % (e,)
        log("%s: %s — %s" % (name, state, text))
        results.append("%s=%s" % (name, state))
        if state not in OK_STATES:
            rc = 1

    # 1. state files
    if state_age is None:
        run_part("state-files", lambda: ("incomplete", "bad STATE_MAX_AGE_SECS, skipped"))
    else:
        dry1 = dry_all or (sec_real_target and not prod)
        if dry1 and not dry_all:
            log("state-files: target is the real %s and CLAUDE_SECURITY_JANITOR_PROD != 1: dry run" % sec_dir)
        run_part("state-files", lambda: sweep_state(sec_dir, state_age, now, dry1))

    # 2. pip debris
    if pip_age is None:
        run_part("pip-debris", lambda: ("incomplete", "bad PIP_MAX_AGE_SECS, skipped"))
    elif not tmp_dir:
        run_part("pip-debris", lambda: ("incomplete", "no user temp dir to look in (getconf and TMPDIR both empty)"))
    else:
        dry2 = dry_all or (tmp_real_target and not prod)
        if dry2 and not dry_all:
            log("pip-debris: target is the real %s and CLAUDE_SECURITY_JANITOR_PROD != 1: dry run" % tmp_dir)
        run_part("pip-debris", lambda: sweep_pip(tmp_dir, pip_age, now, dry2, ps_bin))

    log("summary: %s exit=%d" % (" ".join(results), rc))
    os.close(lock_fd)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
