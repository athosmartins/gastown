#!/usr/bin/env python3
"""daemon-import-smoke.py — does this launchd daemon's entrypoint still IMPORT? (ga-n3czl1)

THE INCIDENT (06/10): wa-acp18q merged `from lib import dispensada` into a route
module. classification_dashboard (Pregao, :8086) runs with only lib/ and daemons/
on sys.path, so the import died with ModuleNotFoundError, launchd crash-looped the
daemon and ops.urblink.com.br/pregao answered 502 until a human noticed. The
tests passed because pytest runs from the repo root, which puts the root on
sys.path; the daemon's launchd launch does not. The gate and the post-merge
refresh both said "fine".

WHAT THIS DOES: starts a NEW interpreter the way launchd would — the plist's own
interpreter, the entrypoint script, WorkingDirectory, and the plist's
EnvironmentVariables on top of launchd's minimal environment (the CALLER's
environment is deliberately not inherited: an ambient PYTHONPATH here is exactly
how the incident's bug would hide) — and executes the entrypoint's top level, so
its own sys.path edits and its imports (including its route blueprints) run, but
NOT its `if __name__ == "__main__":` block, so nothing is served.

Usage:  daemon-import-smoke.py <plist> [--timeout SECONDS]
Output (stdout):  SMOKE=PASS|FAIL|UNKNOWN, SMOKE_REASON=<one line>,
                  and on FAIL/UNKNOWN zero or more SMOKE_DETAIL=<one line>.
Exit code:        0 PASS, 1 FAIL, 2 UNKNOWN.

THREE STATES, never two. "I could not run the check" must never read as "the code
imports" (PASS) or as "the code is broken" (FAIL):
  PASS     the entrypoint's top level ran to completion.
  FAIL     it raised ImportError (incl. ModuleNotFoundError) or SyntaxError
           (incl. IndentationError/TabError). For a given tree + interpreter +
           sys.path these do not depend on timing, so the real boot dies the same
           way — unless the entrypoint branches at import time on state this smoke
           does not reproduce (a secret, a running service), which is why the
           caller keeps a post-restart stability check as well.
  UNKNOWN  anything else — a launch form this script does not emulate, a missing
           interpreter, a timeout, SystemExit, or any OTHER exception at import (a
           KeyError on a secret, a refused DB connection ... environment-shaped,
           and the real boot may differ). Callers fall back to their old behaviour.

Launch forms emulated: `python [flags] script.py [args]` (also behind /usr/bin/env)
and a bash/sh WRAPPER whose top-level (unindented) lines assign variables, `cd`, and
end in `exec python script.py` — the wrapper is READ, never RUN: a real wrapper may
block for minutes fetching secrets (classification-dashboard-wrapper.sh waits up to
180 s on Bitwarden). `-m`/`-c` launches, gunicorn/flask CLIs, conditional or
indented launch lines, and dynamic PYTHON* assignments are UNKNOWN.

Import-time code that must not run under a smoke can check the env var
DAEMON_IMPORT_SMOKE (set to "1" in the child).
"""
import os
import plistlib
import re
import shlex
import signal
import subprocess
import sys

MARK = "__DAEMON_IMPORT_SMOKE_RESULT__"
DEFAULT_TIMEOUT = 45   # measured 7-11 s wall for classification_dashboard under load 60 (0.9 s CPU)
LAUNCHD_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
# What launchd itself hands a user agent besides what the plist sets.
LAUNCHD_PASSTHROUGH = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL")
PY_EXE_RE = re.compile(r"^python(\d+(\.\d+)*)?$")
SHELLS = ("bash", "sh", "zsh")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
VAR_RE = re.compile(r"\$\{([A-Za-z_]\w*)(?::-([^}]*))?\}|\$([A-Za-z_]\w*)")
# An unresolvable value for one of these changes what the daemon can import, so a
# guess would turn a smoke FAIL into noise (or hide one): the wrapper is UNKNOWN.
PYENV_RE = re.compile(r"^(PYTHON\w*|VIRTUAL_ENV)$")

# The child. `-c` puts '' (the cwd) at sys.path[0]; `python script.py` puts the
# script's directory there instead, and the cwd is NOT on the path — the whole
# incident. So the first act is to drop '' and, after the stdlib imports this
# bootstrap needs, install the script's real directory.
# The entrypoint is loaded as a REGISTERED module (sys.modules[name]), as `import`
# would: Flask(__name__) finds its root path through sys.modules[__name__], and an
# UNREGISTERED module silently gets root_path "/" (measured, Flask 3.1.3).
# classification_dashboard builds its Flask app at import time. runpy.run_path(
# run_name=...) registers a temporary module and works as well (also measured);
# importlib is used so the module stays registered until the child exits.
CHILD = r'''
import sys
if sys.path and sys.path[0] == "":
    sys.path.pop(0)
import importlib.util, json, os, traceback
MARK = %(mark)r
def out(d):
    sys.stdout.flush(); sys.stderr.flush()
    sys.__stderr__.write(MARK + json.dumps(d) + "\n"); sys.__stderr__.flush()
    os._exit(0)
script = sys.argv[1]
sys.argv = sys.argv[1:]
sys.path.insert(0, os.path.dirname(os.path.realpath(script)))
name = "daemon_import_smoke_" + os.path.splitext(os.path.basename(script))[0].replace("-", "_").replace(".", "_")
try:
    spec = importlib.util.spec_from_file_location(name, script)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
except SystemExit as e:
    out({"outcome": "exit", "type": "SystemExit", "msg": repr(e.code)})
except (ImportError, SyntaxError) as e:
    tb = [l for l in traceback.format_exc().strip().splitlines() if l.strip(" ^~")]
    out({"outcome": "import_error", "type": type(e).__name__, "msg": str(e),
         "tail": tb[-6:], "sys_path": [p for p in sys.path]})
except BaseException as e:
    tb = [l for l in traceback.format_exc().strip().splitlines() if l.strip(" ^~")]
    out({"outcome": "other_error", "type": type(e).__name__, "msg": str(e)[:300], "tail": tb[-4:]})
out({"outcome": "ok"})
''' % {"mark": MARK}


class Unknown(Exception):
    """The launch could not be reconstructed or run — an UNKNOWN verdict, not a FAIL."""


def one_line(s, limit=400):
    s = " ".join(str(s).split())
    return s if len(s) <= limit else s[: limit - 3] + "..."


def expand(tok, scopes):
    """Expand $VAR / ${VAR} / ${VAR:-default} from the first scope that has it.
    A variable nobody defines raises Unknown: the launch line must not be guessed."""
    def repl(m):
        name = m.group(1) or m.group(3)
        for sc in scopes:
            if name in sc:
                return sc[name]
        if m.group(2) is not None:
            return expand(m.group(2), scopes)
        raise Unknown("unresolved $%s in the launch line" % name)
    return VAR_RE.sub(repl, tok)


def parse_python_args(args, exe_desc):
    """['-u', 'script.py', 'a'] -> (flags, script, script_args)."""
    flags, i = [], 0
    while i < len(args):
        a = args[i]
        if not a.startswith("-") or a == "-":
            break
        if a in ("-m", "-c") or a.startswith("-m") and len(a) > 2 or a.startswith("-c") and len(a) > 2:
            raise Unknown("%s launch (-m/-c) is not emulated" % exe_desc)
        if a in ("-I", "-P"):
            raise Unknown("interpreter flag %s changes how sys.path[0] is built — not emulated" % a)
        flags.append(a)
        if a in ("-W", "-X", "-Q") and i + 1 < len(args):
            i += 1
            flags.append(args[i])
        i += 1
    if i >= len(args):
        raise Unknown("no script argument after the interpreter flags")
    script = args[i]
    if not script.endswith(".py"):
        raise Unknown("entrypoint %r is not a .py file" % script)
    return flags, script, args[i + 1:]


def parse_wrapper(path, base_env, plist_env):
    """Read — never run — a bash wrapper. Returns (exe, flags, script, args, exports, cd)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise Unknown("wrapper unreadable: %s" % e)
    shell_vars, exports, cd = {}, {}, None
    candidates = []
    unresolved_exec = None
    env_scope = dict(base_env)
    env_scope.update(plist_env)
    for raw in lines:
        # Top-level lines only. Anything indented sits inside an if/while/case/
        # function this reader cannot evaluate, so it is never taken as fact.
        if not raw.strip() or raw[0] in " \t#":
            continue
        dynamic = "$(" in raw or "`" in raw
        try:
            toks = shlex.split(raw, comments=True, posix=True)
        except ValueError:
            continue
        if not toks:
            continue
        head = toks[0]
        if head in ("source", "."):
            raise Unknown("wrapper sources another file (%s) — its effect on sys.path is not emulated" % one_line(raw, 80))
        is_export = head == "export"
        if is_export or ASSIGN_RE.match(head):
            for t in (toks[1:] if is_export else toks):
                m = ASSIGN_RE.match(t)
                if not m:
                    break
                name, val = m.group(1), m.group(2)
                try:
                    if dynamic:
                        raise Unknown("dynamic value")
                    val = expand(val, [shell_vars, env_scope])
                except Unknown:
                    if PYENV_RE.match(name):
                        raise Unknown("wrapper sets %s from a value that cannot be resolved statically" % name)
                    shell_vars.pop(name, None)
                    continue
                shell_vars[name] = val
                if is_export:
                    exports[name] = val
            continue
        if head == "cd" and len(toks) == 2 and not dynamic:
            try:
                cd = expand(toks[1], [shell_vars, env_scope])
            except Unknown:
                cd = None
            continue
        launch = toks[1:] if head == "exec" else toks
        if not launch:
            continue
        try:
            exe = expand(launch[0], [shell_vars, env_scope])
        except Unknown as e:
            if head == "exec":   # most likely THE launch line — say why it is unusable
                unresolved_exec = unresolved_exec or e
            continue
        if not PY_EXE_RE.match(os.path.basename(exe)):
            continue
        # A python launch line: every token has to resolve, or this is not a fact.
        rest = [expand(t, [shell_vars, env_scope]) for t in launch[1:]]
        flags, script, sargs = parse_python_args(rest, "wrapper")
        candidates.append((exe, flags, script, sargs))
    if not candidates:
        if unresolved_exec is not None:
            raise unresolved_exec
        raise Unknown("no top-level `exec python script.py` line found in the wrapper")
    if len(set((c[0], c[2], tuple(c[3])) for c in candidates)) > 1:
        raise Unknown("wrapper has %d different python launch lines" % len(candidates))
    exe, flags, script, sargs = candidates[-1]
    return exe, flags, script, sargs, exports, cd


def build_launch(plist_path):
    try:
        with open(plist_path, "rb") as f:
            d = plistlib.load(f)
    except Exception as e:
        raise Unknown("plist unreadable: %s" % one_line(e, 120))
    args = [str(a) for a in (d.get("ProgramArguments") or [])]
    if not args:
        raise Unknown("plist has no ProgramArguments")
    plist_env = {str(k): str(v) for k, v in (d.get("EnvironmentVariables") or {}).items()}
    base_env = {"PATH": LAUNCHD_PATH}
    for k in LAUNCHD_PASSTHROUGH:
        if os.environ.get(k):
            base_env[k] = os.environ[k]
    wd = d.get("WorkingDirectory") or "/"

    # `/usr/bin/env [VAR=val ...] prog args` -> prog args (+ env)
    inline_env = {}
    if os.path.basename(args[0]) == "env":
        i = 1
        while i < len(args) and ASSIGN_RE.match(args[i]):
            k, v = args[i].split("=", 1)
            inline_env[k] = v
            i += 1
        args = args[i:]
        if not args:
            raise Unknown("env with no program")
    plist_env.update(inline_env)

    exe0 = args[0]
    exports, cd = {}, None
    if PY_EXE_RE.match(os.path.basename(exe0)):
        exe = exe0
        flags, script, sargs = parse_python_args(args[1:], "python")
    else:
        wrapper = None
        if os.path.basename(exe0) in SHELLS:
            rest = [a for a in args[1:] if not a.startswith("-")]
            if len(args[1:]) != len(rest):
                raise Unknown("shell flags (-c/-l/...) are not emulated")
            wrapper = rest[0] if rest else None
        elif exe0.endswith(".sh"):
            wrapper = exe0
        if not wrapper:
            raise Unknown("launch is neither a python script nor a shell wrapper (%s)" % os.path.basename(exe0))
        exe, flags, script, sargs, exports, cd = parse_wrapper(wrapper, base_env, plist_env)

    env = dict(base_env)
    env.update(plist_env)
    env.update(exports)
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    env["DAEMON_IMPORT_SMOKE"] = "1"
    cwd = cd or wd
    if not os.path.isdir(cwd):
        raise Unknown("working directory %s does not exist" % cwd)
    if os.sep not in exe:
        found = None
        for p in env["PATH"].split(":"):
            c = os.path.join(p, exe)
            if os.path.isfile(c) and os.access(c, os.X_OK):
                found = c
                break
        if not found:
            raise Unknown("interpreter %s not found on the launchd PATH" % exe)
        exe = found
    if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
        raise Unknown("interpreter not found: %s" % exe)
    if not os.path.isabs(script):
        script = os.path.normpath(os.path.join(cwd, script))
    if not os.path.isfile(script):
        raise Unknown("entrypoint not found: %s" % script)
    return exe, flags, script, sargs, env, cwd


def run(plist_path, timeout):
    exe, flags, script, sargs, env, cwd = build_launch(plist_path)
    cmd = [exe] + flags + ["-c", CHILD, script] + sargs
    try:
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
    except OSError as e:
        raise Unknown("could not start the interpreter: %s" % one_line(e, 160))
    try:
        _, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # The whole group: an import-time thread/subprocess must not outlive the smoke
        # (it could hold the port the real restart is about to bind).
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        raise Unknown("import did not finish within %ss (killed)" % timeout)
    err = err.decode("utf-8", "replace")
    res = None
    for line in err.splitlines():
        if line.startswith(MARK):
            res = line[len(MARK):]
    if res is None:
        raise Unknown("no result from the child (rc=%s): %s" % (p.returncode, one_line(err[-300:], 200)))
    import json
    try:
        r = json.loads(res)
    except ValueError:
        raise Unknown("unparseable result from the child")
    return r, script, cwd


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    plist, timeout = argv[0], float(os.environ.get("DAEMON_SMOKE_TIMEOUT", DEFAULT_TIMEOUT))
    if "--timeout" in argv:
        timeout = float(argv[argv.index("--timeout") + 1])
    try:
        r, script, cwd = run(plist, timeout)
    except Unknown as e:
        print("SMOKE=UNKNOWN")
        print("SMOKE_REASON=%s" % one_line(e))
        return 2
    oc = r.get("outcome")
    if oc == "ok":
        print("SMOKE=PASS")
        print("SMOKE_REASON=entrypoint %s imported cleanly under its launchd sys.path" % script)
        return 0
    if oc == "import_error":
        print("SMOKE=FAIL")
        print("SMOKE_REASON=%s: %s (entrypoint %s, cwd %s)" % (r.get("type"), one_line(r.get("msg", ""), 200), script, cwd))
        for t in r.get("tail", []):
            print("SMOKE_DETAIL=%s" % one_line(t, 300))
        print("SMOKE_DETAIL=sys.path at failure: %s" % one_line(r.get("sys_path", []), 600))
        return 1
    # exit / other_error: not an import/syntax error — cannot tell if the real boot hits it.
    print("SMOKE=UNKNOWN")
    print("SMOKE_REASON=%s at import (%s) — not an import/syntax error, so not treated as a failure" % (
        r.get("type"), one_line(r.get("msg", ""), 160)))
    for t in r.get("tail", []):
        print("SMOKE_DETAIL=%s" % one_line(t, 300))
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException as e:   # exit code 1 means FAIL here: a bug in this script must not look like one
        print("SMOKE=UNKNOWN")
        print("SMOKE_REASON=smoke script crashed: %s: %s" % (type(e).__name__, one_line(e, 200)))
        sys.exit(2)
