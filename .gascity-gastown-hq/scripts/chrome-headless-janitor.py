#!/usr/bin/env python3
"""chrome-headless-janitor.py (ga-xjv29mb) — sweep the throwaway profiles headless Chrome leaves on the mini.

## Contents
- Why
- What it does
- Safety
- Switches
- Exit code

## Why
Since Chromium commit d36b68b00 (2026-06-11, bug 522307607, chrome/browser/headless/headless_mode_init.cc) a
`chrome --headless` started WITHOUT --user-data-dir makes itself a throwaway profile: a base::ScopedTempDir named
scoped_dirXXXXXX under "<default user data dir>-headless", which on the mini is
~/Library/Application Support/Google/Chrome-headless/scoped_dirXXXXXX (its disk cache goes to the twin under
~/Library/Caches/Google/Chrome-headless/, by the rule of chrome_paths_mac.mm; not measured here). Before that commit the
directory lived in $TMPDIR, which macOS cleans over time (not verified here); in Application Support nobody does.
Chrome removes the directory only when the process shuts down in an orderly way (the ScopedTempDir destructor). SIGTERM,
SIGKILL and a crash leave it for good (rstudio/chromote#239 has a macOS reprex for the signals; a crash was seen on the
node; a shutdown that hangs until Chrome's own watchdog kills it is the same case, by inference). The Chromium issue
361615573 is closed Won't Fix and the official answer is "pass your own --user-data-dir".
On 2026-11-19 that was 8,223 folders and 22 GB (ga-xjv29mb, "since 11/08" = 11 August). The caller found is
whatsapp_automation tests/_chrome_dump_dom.py (wa-d1wbl): it starts Chrome without --user-data-dir and SIGKILLs it as
soon as it has read the DOM, once per smoke-test call. The fix at the source is a private --user-data-dir that the caller
deletes (a WA bead). This janitor is the net under that fix, and it also catches a caller nobody has found yet.

## What it does
For each root (default: the Application Support and Caches twins of Chrome-headless and of Chrome for Testing-headless,
under $HOME) it lists the direct children named scoped_dir<letters, digits, underscore> and deletes each one that is
1. a real directory (never a symlink, never a file);
2. OLD: nothing inside it, at any depth, was written within MAX_AGE (24 h) — the walk stops at the first recent entry;
3. UNOWNED: no running process cites its name. Every child process of a live headless Chrome carries
   --user-data-dir=<that directory> (Chrome copies the switch to all of them), so `ps` finds it.
Nothing else is ever touched: not the normal Chrome profile (Google/Chrome), not ~/.chrome-cdp, not anything outside the roots.

## Safety
Every read has three outcomes — has / has not / could not find out — and "could not find out" lands in the inert state:
- a root that does not exist is "absent" (nothing to clean); a root that is a symlink or cannot be listed is reported
  ("not-a-dir" / "unreadable", exit 1) and never followed; the listing is complete before anything is deleted;
- `ps -A -w -w -o command=` (two -w: BSD ps cuts every line at 80 columns otherwise, which would hide the switch) must
  answer non-empty (a live system always has processes) before the first delete; empty or failing = cannot tell = keep
  everything, INCOMPLETE. ps is only asked when something is old enough to delete. A live Chrome keeps ITS directory and
  is not an error;
- a directory whose subtree cannot be read in full, or that holds more than ENTRY_CAP entries, is "unjudged": kept,
  counted, INCOMPLETE (a dry run only reports it). An mtime in the future (clock skew) counts as recent;
- the directory is looked at again right before rmtree (inode and mtime must be as they were when it was listed), and
  again after it: ENOENT = deleted; still there = PARTIAL; any other error = UNVERIFIED (both INCOMPLETE);
- one instance at a time (flock); the loser exits 0;
- PRODUCTION SENTINEL (same idea as claude-security-janitor.py): a root that resolves to one of the real /Users/athos
  roots is only ever a dry run unless CHROME_HEADLESS_JANITOR_PROD=1. The plist sets it; a test or a manual run that
  forgets to point at a fixture cannot delete real profiles.

## Switches
CHROME_HEADLESS_JANITOR_ROOTS (colon-separated; default the four roots under $HOME), _REAL_ROOTS (colon-separated, what the
sentinel calls real; default the same four under /Users/athos), _MAX_AGE_SECS (86400), _ENTRY_CAP (100000 entries per
profile), _PS_BIN (ps), _LOCK (default <city>/.gc/runtime/chrome-headless-janitor.lock), _ENABLED=0 (no-op),
_DRY_RUN=1 or --dry-run (report only: nothing deleted), _PROD=1 (see above). A limit that is not a positive integer stops
the run (exit 1, nothing deleted): a guessed limit could delete more than was meant.

## Exit code
0 = every root ran (nothing to do counts; a profile kept because a Chrome is using it counts; another instance holding
the lock counts). 1 = a root was INCOMPLETE (could not read / could not confirm a delete / could not tell about live
processes), a limit was bad, or the lock could not be taken; the lines above say which.
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

REAL_HOME = "/Users/athos"
ROOT_RELS = (
    "Library/Application Support/Google/Chrome-headless",
    "Library/Caches/Google/Chrome-headless",
    "Library/Application Support/Google/Chrome for Testing-headless",
    "Library/Caches/Google/Chrome for Testing-headless",
)
# What ScopedTempDir::CreateUniqueTempDirUnderPath names the directory: the "scoped_dir" prefix plus the mkdtemp suffix
# (letters and digits) — and the older scoped_dir<pid>_<n> shape. The bare prefix is not a profile.
NAME_RE = re.compile(r"^scoped_dir[A-Za-z0-9_]+$")
# The same names, found anywhere in a command line (the switch value is a path ending in one of them).
LIVE_RE = re.compile(r"scoped_dir[A-Za-z0-9_]+")
DEFAULT_MAX_AGE = 24 * 3600
DEFAULT_ENTRY_CAP = 100000
PS_TIMEOUT_SECS = 30

# root states. OK_STATES are the ones that do not make the run INCOMPLETE.
OK_STATES = {"absent", "none-old", "pruned", "dry-run", "live"}


def log(msg):
    print("chrome-headless-janitor: %s" % msg, flush=True)


def cfg_int(name, default):
    """Positive integer from the environment. Unset/empty -> default. Anything that is not a positive integer -> None,
    and the caller stops: a limit the script cannot read is never guessed (a guessed one could delete more than meant)."""
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    if re.fullmatch(r"[0-9]+", raw) and int(raw) > 0:
        return int(raw)
    log("%s='%s' is not a positive integer" % (name, raw))
    return None


def is_real_target(path, real_paths):
    """True when `path` is one of the production roots. A path that cannot be resolved counts as real: the sentinel then
    keeps the run a dry run instead of guessing it is a fixture."""
    try:
        here = os.path.realpath(path)
        return any(here == os.path.realpath(r) for r in real_paths)
    except (OSError, ValueError):
        return True


def human(n):
    return "%.1f MB" % (n / 1048576.0)


def disk_bytes(st):
    """What the entry costs on disk (blocks, like du); the apparent size where the platform has no st_blocks."""
    blocks = getattr(st, "st_blocks", None)
    return blocks * 512 if blocks is not None else st.st_size


def live_names(ps_bin):
    """Returns (set of scoped_dir names that some running process cites, "") or (None, why) when that could not be found out."""
    # vazio (no output) -> None: a live system always has processes, so empty means ps did not really run;
    # falhou/ilegivel (rc != 0, timeout, missing binary) -> None. Both make the caller keep EVERYTHING.
    try:
        r = subprocess.run(
            [ps_bin, "-A", "-w", "-w", "-o", "command="],
            capture_output=True, encoding="utf-8", errors="replace", timeout=PS_TIMEOUT_SECS,
        )
    except (OSError, subprocess.SubprocessError) as e:
        return None, "ps failed: %s" % e
    if r.returncode != 0 or not r.stdout.strip():
        return None, "ps rc=%s, %d byte(s) of output" % (r.returncode, len(r.stdout))
    return set(LIVE_RE.findall(r.stdout)), ""


def judge_tree(path, now, max_age, entry_cap, top_stat=None):
    """Was anything inside `path` written within max_age? Returns (verdict, size, why):
    old (the whole tree was read and nothing in it is that new), fresh (something is), unknown (a part could not be read,
    or there are more than entry_cap entries). Symlinks are never followed."""
    # vazio -> n/a (the directory was just listed); falhou/ilegivel (lstat raised) -> unknown: kept, never "old".
    if top_stat is None:
        try:
            top_stat = os.lstat(path)
        except OSError as e:
            return "unknown", 0, "cannot stat %s: %s" % (path, e)
    if now - top_stat.st_mtime <= max_age:
        return "fresh", 0, "the directory itself was written %d s ago" % (now - top_stat.st_mtime)
    size = 0
    seen = 0
    stack = [path]
    while stack:
        d = stack.pop()
        # vazio (no entries) -> nothing to add; falhou/ilegivel (scandir, the iteration or a stat raised) -> unknown:
        # the part we could not read may hold the newest file.
        try:
            with os.scandir(d) as it:
                for e in it:
                    seen += 1
                    if seen > entry_cap:
                        return "unknown", size, "more than %d entries" % entry_cap
                    st = e.stat(follow_symlinks=False)
                    if now - st.st_mtime <= max_age:
                        return "fresh", size, "%s written %d s ago" % (e.path, now - st.st_mtime)
                    size += disk_bytes(st)
                    if stat.S_ISDIR(st.st_mode):
                        stack.append(e.path)
        except OSError as err:
            return "unknown", size, "cannot read %s: %s" % (d, err)
    return "old", size, ""


def sweep_root(root, now, max_age, dry, live_fn, entry_cap):
    """Returns (state, text). live_fn() answers like live_names and is only called when something is old enough to delete."""
    # vazio (the root does not exist) -> "absent", nothing to clean; falhou/ilegivel (lstat raised) -> "unreadable".
    try:
        rst = os.lstat(root)
    except FileNotFoundError:
        return "absent", "does not exist"
    except OSError as e:
        return "unreadable", "cannot stat %s: %s" % (root, e)
    if stat.S_ISLNK(rst.st_mode) or not stat.S_ISDIR(rst.st_mode):
        return "not-a-dir", "%s is a symlink or not a directory: not followed" % root

    # vazio (no entries) -> "none-old"; falhou/ilegivel (scandir or the iteration raised) -> "unreadable", NOTHING is deleted.
    try:
        with os.scandir(root) as it:
            entries = list(it)
    except OSError as e:
        return "unreadable", "cannot list %s: %s" % (root, e)

    cands = []
    nonregular = unreadable = 0
    for e in entries:
        if not NAME_RE.match(e.name):
            continue
        # falhou/ilegivel -> the entry is KEPT and counted, never read as "not a profile".
        try:
            if e.is_symlink() or not e.is_dir(follow_symlinks=False):
                nonregular += 1
                continue
            st = e.stat(follow_symlinks=False)
        except OSError:
            unreadable += 1
            continue
        cands.append((e.path, e.name, st))

    old = []
    kept_fresh = unjudged = 0
    unjudged_why = []
    for path, name, st in cands:
        verdict, size, why = judge_tree(path, now, max_age, entry_cap, st)
        if verdict == "old":
            old.append((path, name, st, size))
        elif verdict == "fresh":
            kept_fresh += 1
        else:
            unjudged += 1
            if len(unjudged_why) < 2:
                unjudged_why.append("%s: %s" % (name, why))
    unjudged_note = ("; unjudged: " + " | ".join(unjudged_why)) if unjudged_why else ""

    if not old:
        tail = "kept_fresh=%d unjudged=%d nonregular=%d unreadable=%d" % (kept_fresh, unjudged, nonregular, unreadable)
        state = "incomplete" if (unjudged or unreadable) else "none-old"
        return state, "no scoped_dir* older than %d s; %s%s" % (max_age, tail, unjudged_note)

    live, why = live_fn()
    if live is None:
        return "incomplete", "cannot tell whether a Chrome is running (%s): kept %d old dir(s); kept_fresh=%d unjudged=%d%s" % (
            why, len(old), kept_fresh, unjudged, unjudged_note)
    todo = [o for o in old if o[1] not in live]
    kept_live = len(old) - len(todo)
    tail = "kept_fresh=%d kept_live=%d unjudged=%d nonregular=%d unreadable=%d" % (
        kept_fresh, kept_live, unjudged, nonregular, unreadable)

    if not todo:
        state = "incomplete" if (unjudged or unreadable) else "live"
        return state, "every one of the %d old dir(s) is cited by a running process: kept, retry next run; %s%s" % (
            len(old), tail, unjudged_note)
    if dry:
        return "dry-run", "DRY-RUN would delete %d dir(s) (%s); %s; e.g. %s" % (
            len(todo), human(sum(o[3] for o in todo)), tail, " ".join(o[1] for o in todo[:3]))

    deleted = gone = failed = changed = partial = unverified = 0
    freed = 0
    for path, name, st, size in todo:
        # vazio (ENOENT: someone else removed it) -> counted as gone; falhou/ilegivel -> KEPT, counted failed.
        try:
            st2 = os.lstat(path)
        except FileNotFoundError:
            gone += 1
            continue
        except OSError:
            failed += 1
            continue
        if st2.st_ino != st.st_ino or st2.st_mtime != st.st_mtime:
            changed += 1  # written (or replaced) since it was judged: not stale any more
            continue
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
    tail = "%s changed=%d" % (tail, changed)
    if partial or unverified or failed or unjudged or unreadable:
        return "incomplete", "deleted=%d (%s) gone=%d PARTIAL=%d UNVERIFIED=%d FAILED=%d; %s%s" % (
            deleted, human(freed), gone, partial, unverified, failed, tail, unjudged_note)
    return "pruned", "deleted=%d (%s) gone=%d; %s" % (deleted, human(freed), gone, tail)


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


def split_paths(raw):
    return [p for p in raw.split(":") if p]


def short_label(root):
    """A name for the summary line that tells the Application Support root from its Caches twin (same basename)."""
    base = os.path.basename(root.rstrip("/")).replace(" ", "_")
    if "/Application Support/" in root:
        return "AppSupport/" + base
    if "/Caches/" in root:
        return "Caches/" + base
    return base


def main(argv):
    if "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0
    env = os.environ.get
    if env("CHROME_HEADLESS_JANITOR_ENABLED", "1") != "1":
        log("CHROME_HEADLESS_JANITOR_ENABLED != 1: no-op")
        return 0
    dry_all = "--dry-run" in argv or env("CHROME_HEADLESS_JANITOR_DRY_RUN", "0") == "1"
    prod = env("CHROME_HEADLESS_JANITOR_PROD", "0") == "1"
    home = env("HOME", "") or os.path.expanduser("~")
    roots_raw = env("CHROME_HEADLESS_JANITOR_ROOTS", "")
    roots = split_paths(roots_raw) if roots_raw else [os.path.join(home, rel) for rel in ROOT_RELS]
    real_raw = env("CHROME_HEADLESS_JANITOR_REAL_ROOTS", "")
    real_roots = split_paths(real_raw) if real_raw else [os.path.join(REAL_HOME, rel) for rel in ROOT_RELS]
    city = env("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
    lock_path = env("CHROME_HEADLESS_JANITOR_LOCK", "") or os.path.join(city, ".gc", "runtime", "chrome-headless-janitor.lock")
    ps_bin = env("CHROME_HEADLESS_JANITOR_PS_BIN", "ps")
    max_age = cfg_int("CHROME_HEADLESS_JANITOR_MAX_AGE_SECS", DEFAULT_MAX_AGE)
    entry_cap = cfg_int("CHROME_HEADLESS_JANITOR_ENTRY_CAP", DEFAULT_ENTRY_CAP)
    if max_age is None or entry_cap is None:
        log("summary: bad limit, nothing swept exit=1")
        return 1

    try:
        lock_fd, other = acquire_lock(lock_path)
    except OSError as e:
        log("cannot take the lock %s: %s - nothing done" % (lock_path, e))
        return 1
    if other:
        log("another run holds the lock: exiting")
        return 0

    now = time.time()
    live_cache = []

    def live_fn():
        # One ps per run, shared by every root.
        if not live_cache:
            live_cache.append(live_names(ps_bin))
        return live_cache[0]

    rc = 0
    results = []
    for root in roots:
        dry = dry_all or (is_real_target(root, real_roots) and not prod)
        if dry and not dry_all:
            log("%s: target is the real root and CHROME_HEADLESS_JANITOR_PROD != 1: dry run" % root)
        try:
            state, text = sweep_root(root, now, max_age, dry, live_fn, entry_cap)
        except Exception as e:  # one root crashing must not skip the others, nor look like success
            state, text = "incomplete", "crashed: %r" % (e,)
        log("%s: %s - %s" % (root, state, text))
        results.append("%s=%s" % (short_label(root), state))
        if state not in OK_STATES:
            rc = 1

    log("summary: %s exit=%d" % (" ".join(results), rc))
    os.close(lock_fd)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
