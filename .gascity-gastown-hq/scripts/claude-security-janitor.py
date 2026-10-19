#!/usr/bin/env python3
"""claude-security-janitor.py (ga-j4r9o8) — keep the security-guidance plugin from eating the mini's disk.

## Contents
- Why
- What it does
- Safety
- Switches
- Exit code

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
3. SDK check (detection only) — pick the interpreter the way `sg-python.sh` does (first of
   python3.13 .. python3.10, then python3, python, that runs and is >= 3.10) and ask it the
   hook's own question, `importlib.util.find_spec("claude_agent_sdk")`. If the SDK is gone
   (a `brew upgrade` of python3.13 wipes its site-packages) it sends a `notify` alarm with the
   repair command, at most once per ALARM_REPEAT (6 h) while it stays gone. It never installs
   anything: a pip run under load is exactly what started the loop.

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
- SDK check: a probe that times out, exits non-zero or prints something unparseable is
  "could not tell" (it never reads as "SDK missing"); "unknown" alarms only after
  UNKNOWN_AFTER (3) consecutive runs and with its own text. A `notify` that fails is NOT
  recorded as sent, so the next run retries;
- one instance at a time (flock); the loser exits 0;
- PRODUCTION SENTINEL (same ga-h565g idea as claude_home_trim.py): a target that resolves to
  the real ~/.claude/security or the real user temp dir is only ever a dry run unless
  CLAUDE_SECURITY_JANITOR_PROD=1. The plist sets it; a test or a manual run that forgets to
  point at a fixture cannot delete real files.

## Switches
CLAUDE_SECURITY_JANITOR_DIR (default /Users/athos/.claude/security), _TMPDIR (default
`getconf DARWIN_USER_TEMP_DIR`), _STATE_MAX_AGE_SECS, _PIP_MAX_AGE_SECS, _ALARM_REPEAT_SECS,
_UNKNOWN_AFTER, _PYTHONS (space-separated names or paths, default
"python3.13 python3.12 python3.11 python3.10 python3 python"), _MIN_PY ("3.10"), _PS_BIN (ps),
_NOTIFY_BIN (~/.local/bin/notify), _PROBE_TIMEOUT_SECS (60), _STATE (alarm state, default
<city>/.gc/runtime/claude-security-janitor.state.json), _ENABLED=0 (no-op), _DRY_RUN=1 or
--dry-run (report only: nothing deleted, nothing sent, no state written), _PROD=1 (see above).
Test seams for the production sentinel: _REAL_DIR and _REAL_TMPDIR say which path counts as "the
real one" (defaults: the constants above / getconf), so the selftest can declare a fixture real.

## Exit code
0 = every part ran (nothing to do counts; another instance holding the lock counts).
1 = a part was INCOMPLETE (could not read / could not confirm a delete / a bad limit), the
SDK is missing or could not be checked, or a notify failed; the lines above say which.
"""
import errno
import fcntl
import json
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
# What the hook asks (ensure_agent_sdk.py: find_spec, no import) plus the version, one process.
PROBE_CODE = (
    "import sys, importlib.util as u; "
    'print("%d.%d %s" % (sys.version_info[0], sys.version_info[1], '
    'u.find_spec("claude_agent_sdk") is not None))'
)
PROBE_OUT_RE = re.compile(r"^(\d+)\.(\d+) (True|False)$")
PROBE_TIMEOUT_SECS = 60
PS_TIMEOUT_SECS = 30
NOTIFY_TIMEOUT_SECS = 30

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


# ── 3. SDK check ────────────────────────────────────────────────────────────────────────────


def resolve_python(cand):
    if "/" in cand:
        return cand if os.path.isfile(cand) and os.access(cand, os.X_OK) else None
    return shutil.which(cand)


def probe_python(path, timeout):
    """Returns ((major, minor, has_sdk), None) or (None, why)."""
    # vazio (no output) -> (None, why); falhou/ilegivel (timeout, rc != 0, unparseable) -> (None, why).
    # A probe that did not answer is never "SDK missing".
    try:
        r = subprocess.run(
            [path, "-c", PROBE_CODE], capture_output=True, text=True, timeout=timeout,
            env=dict(os.environ, PYTHONUTF8="1"),
        )
    except subprocess.TimeoutExpired:
        return None, "timed out after %d s" % timeout
    except (OSError, subprocess.SubprocessError) as e:
        return None, "cannot run: %s" % e
    m = PROBE_OUT_RE.match(r.stdout.strip())
    if r.returncode != 0 or not m:
        return None, "rc=%s, output %r" % (r.returncode, r.stdout.strip()[:60])
    return (int(m.group(1)), int(m.group(2)), m.group(3) == "True"), None


def parse_min_py(raw):
    m = re.fullmatch(r"(\d+)\.(\d+)", raw)
    return (int(m.group(1)), int(m.group(2))) if m else None


def check_sdk(candidates, min_py, probe_timeout=PROBE_TIMEOUT_SECS):
    """Returns (verdict, interpreter, detail); verdict is present | missing | unknown.
    Same walk as sg-python.sh: the first interpreter that answers and is new enough decides."""
    failures = []
    older = []
    for cand in candidates:
        path = resolve_python(cand)
        if path is None:
            continue  # not installed: not a failure, sg-python skips it too
        got, why = probe_python(path, probe_timeout)
        if got is None:
            failures.append("%s: %s" % (path, why))
            continue
        major, minor, has_sdk = got
        if (major, minor) < min_py:
            older.append("%s is %d.%d" % (path, major, minor))
            continue
        if has_sdk:
            return "present", path, "find_spec(claude_agent_sdk) found it in %d.%d" % (major, minor)
        if failures:
            return "unknown", path, "%s lacks the SDK but an earlier candidate did not answer (%s)" % (
                path, "; ".join(failures))
        return "missing", path, "find_spec(claude_agent_sdk) found nothing in %s (%d.%d)" % (
            path, major, minor)
    if failures:
        return "unknown", "", "no interpreter answered: %s" % "; ".join(failures)
    return "missing", "", "no python >= %d.%d on PATH (%s)" % (
        min_py[0], min_py[1], "; ".join(older) if older else "none found")


def read_alarm_state(path):
    """Returns (dict, note). A state file that is absent or unreadable reads as 'no alarm sent
    yet': the worst outcome is one extra notification, never a lost alarm."""
    # vazio (absent) -> {}; falhou/ilegivel (corrupt, not an object, unreadable) -> {} plus a note.
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}, ""
    except (OSError, ValueError) as e:
        return {}, "alarm state %s unreadable (%s): treating as no alarm sent yet" % (path, e)
    if not isinstance(data, dict):
        return {}, "alarm state %s is not an object: treating as no alarm sent yet" % path
    return data, ""


def write_alarm_state(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def send_notify(notify_bin, title, body):
    """True only when notify exited 0. Anything else = NOT sent."""
    try:
        r = subprocess.run(
            [notify_bin, "-t", title, "-p", "4", body],
            capture_output=True, text=True, timeout=NOTIFY_TIMEOUT_SECS,
        )
    except (OSError, subprocess.SubprocessError) as e:
        log("NOTIFY FAILED (%s): %s" % (notify_bin, e))
        return False
    if r.returncode != 0:
        log("NOTIFY FAILED (%s): rc=%s %s" % (notify_bin, r.returncode, r.stderr.strip()[:120]))
        return False
    return True


def handle_sdk(verdict, interp, detail, now, dry, state_path, notify_bin, repeat, unknown_after):
    """Applies the alarm policy. Returns True when this part is OK."""
    state, note = read_alarm_state(state_path)
    if note:
        log(note)
    new = dict(state)
    ok = verdict == "present"

    if verdict == "present":
        new = {}
        log("sdk: present — %s" % detail)
    elif verdict == "missing":
        last = state.get("last_alarm_missing")
        due = not isinstance(last, (int, float)) or now - last >= repeat
        log("sdk: MISSING — %s" % detail)
        fix = ("%s -m pip install --break-system-packages claude-agent-sdk" % interp
               if interp else "brew install python@3.13 e instalar claude-agent-sdk nele")
        if not due:
            log("sdk: alarm already sent %d s ago (repeat every %d s)" % (now - last, repeat))
        elif dry:
            log("sdk: DRY-RUN would notify (repair: %s)" % fix)
        elif send_notify(
            notify_bin,
            "claude_agent_sdk sumiu do python do hook",
            "O plugin security-guidance volta a reinstalar o venv a cada sessao (pip sem cache, "
            "~800 MB/dia em pip-*). %s Conserto: %s (ga-j4r9o8)" % (detail, fix),
        ):
            new["last_alarm_missing"] = now
        else:
            ok = False
        new["unknown_streak"] = 0
    else:  # unknown
        streak = state.get("unknown_streak")
        streak = (streak if isinstance(streak, int) and streak >= 0 else 0) + 1
        new["unknown_streak"] = streak
        log("sdk: UNKNOWN (%d in a row) — %s" % (streak, detail))
        last = state.get("last_alarm_unknown")
        due = not isinstance(last, (int, float)) or now - last >= repeat
        if streak >= unknown_after and due:
            if dry:
                log("sdk: DRY-RUN would notify (could not check)")
            elif send_notify(
                notify_bin,
                "nao consegui checar o claude_agent_sdk",
                "%d rodadas seguidas sem conseguir perguntar ao python do hook se o "
                "claude_agent_sdk existe: %s (ga-j4r9o8)" % (streak, detail),
            ):
                new["last_alarm_unknown"] = now
            else:
                ok = False

    if not dry and new != state:
        try:
            os.makedirs(os.path.dirname(state_path), exist_ok=True)
            write_alarm_state(state_path, new)
        except OSError as e:
            log("cannot write alarm state %s: %s (a repeat alarm is possible)" % (state_path, e))
            ok = False
    return ok


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
    state_path = env("CLAUDE_SECURITY_JANITOR_STATE", "") or os.path.join(
        city, ".gc", "runtime", "claude-security-janitor.state.json")

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
        lock_fd, other = acquire_lock(state_path + ".lock")
    except OSError as e:
        log("cannot take the lock %s.lock: %s — nothing done" % (state_path, e))
        return 1
    if other:
        log("another run holds the lock: exiting")
        return 0

    now = time.time()
    state_age = cfg_int("CLAUDE_SECURITY_JANITOR_STATE_MAX_AGE_SECS", 3 * 86400)
    pip_age = cfg_int("CLAUDE_SECURITY_JANITOR_PIP_MAX_AGE_SECS", 2 * 3600)
    repeat = cfg_int("CLAUDE_SECURITY_JANITOR_ALARM_REPEAT_SECS", 6 * 3600)
    unknown_after = cfg_int("CLAUDE_SECURITY_JANITOR_UNKNOWN_AFTER", 3)
    probe_timeout = cfg_int("CLAUDE_SECURITY_JANITOR_PROBE_TIMEOUT_SECS", PROBE_TIMEOUT_SECS)
    min_py = parse_min_py(env("CLAUDE_SECURITY_JANITOR_MIN_PY", "3.10"))
    pythons = (env("CLAUDE_SECURITY_JANITOR_PYTHONS", "") or
               "python3.13 python3.12 python3.11 python3.10 python3 python").split()
    ps_bin = env("CLAUDE_SECURITY_JANITOR_PS_BIN", "ps")
    notify_bin = env("CLAUDE_SECURITY_JANITOR_NOTIFY_BIN", "/Users/athos/.local/bin/notify")

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

    # 3. SDK check
    if min_py is None or repeat is None or unknown_after is None or probe_timeout is None:
        log("sdk-check: incomplete — bad MIN_PY / ALARM_REPEAT_SECS / UNKNOWN_AFTER / PROBE_TIMEOUT_SECS, skipped")
        results.append("sdk-check=incomplete")
        rc = 1
    else:
        try:
            verdict, interp, detail = check_sdk(pythons, min_py, probe_timeout)
            ok = handle_sdk(verdict, interp, detail, now, dry_all, state_path, notify_bin, repeat, unknown_after)
        except Exception as e:
            verdict, ok = "crashed", False
            log("sdk-check: crashed: %r" % (e,))
        results.append("sdk-check=%s" % verdict)
        if not ok:
            rc = 1

    log("summary: %s exit=%d" % (" ".join(results), rc))
    os.close(lock_fd)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
