#!/usr/bin/env bash
# claude-security-janitor.selftest.sh — drives the REAL claude-security-janitor.py (ga-j4r9o8).
#
# Everything runs in a scratch tree: a fake HOME / ~/.claude/security / user temp dir / city state,
# and stub `ps`, `notify` and "python interpreters" (shell scripts that print what a real probe
# would). Nothing reaches the live city, the real ~/.claude or the real notifier. The stubs are made
# to FAIL — ps non-zero or empty, an unlistable dir, a probe that hangs / prints garbage / exits 1, a
# notify that exits 1 — and the janitor must land in the INERT state: nothing deleted, "could not
# tell" never read as "missing" or "nothing there", a failed notify never recorded as sent.
#
# A second block (python, in-process) covers what a subprocess cannot reach: a file rewritten
# between the listing and the unlink, an unlink that fails, a listing that dies half way, an rmtree
# that leaves the dir, a post-delete look that fails, and the pip-liveness / interpreter-selection
# rules line by line.
#
# CSJ_MUTANTS=1 additionally re-runs this whole battery against deliberately broken copies of the
# janitor and requires every one of them to FAIL it (a test that only passes proves nothing).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JAN="${CLAUDE_SECURITY_JANITOR_PATH:-$HERE/claude-security-janitor.py}"
[ -f "$JAN" ] || { echo "FATAL: janitor not found at $JAN"; exit 1; }
PY="$(command -v python3)" || { echo "FATAL: python3 missing"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/csj-selftest.XXXXXX")"
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export HOME="$W/home"
SEC="$HOME/.claude/security"; TMP="$W/tmp"; RT="$W/rt"; STATE="$RT/state.json"; LOCK="$RT/lock"
NCALLS="$W/notify.calls"; export STUB_NOTIFY_CALLS="$NCALLS"
H=3600; D=86400; STALE=$((3*D)); PIPAGE=$((2*H))
PASS=0; FAIL=0; OUT=""; RC=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() {
  FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"
  [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | head -14
  [ "${CSJ_FAILFAST:-0}" = "1" ] && exit 1   # mutant runs: the first failure is enough
  return 0
}

# ── stubs ────────────────────────────────────────────────────────────────────────────────────
cat > "$W/ps" <<'STUB'
#!/bin/sh
case "${STUB_PS_MODE:-ok}" in
  ok)    printf '%s\n' "/sbin/launchd" "/usr/bin/python3 /Users/athos/gt/pipedrive_sync.py" \
           "claude -p please run python -m pip install x" "/usr/bin/python3 -m pipx run foo" "gzip -c f"
         [ -n "${STUB_PS_EXTRA:-}" ] && printf '%s\n' "$STUB_PS_EXTRA"
         exit 0 ;;
  empty) exit 0 ;;
  rc1)   echo "/sbin/launchd"; exit 1 ;;
esac
STUB
cat > "$W/notify" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_NOTIFY_CALLS"
exit "${STUB_NOTIFY_RC:-0}"
STUB
mkpy() { printf '#!/bin/sh\n%s\n' "$2" > "$W/$1"; }
mkpy py-present 'echo "3.13 True"'
mkpy py-absent  'echo "3.13 False"'
mkpy py-old     'echo "3.9 False"'
mkpy py-old-sdk 'echo "3.9 True"'
mkpy py-garbage 'echo "hello"'
mkpy py-rc1     'exit 1'
mkpy py-hang    'exec sleep 300'
chmod +x "$W/ps" "$W/notify" "$W"/py-*

# Fixture builder: lines "<kind> <age_secs> <path>"; kinds f (file), d (dir with a nested file),
# e (empty dir), l (symlink, path is "link=>target"). Ages are relative to now.
cat > "$W/mk.py" <<'PYEOF'
import os, sys, time
now = time.time()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    kind, age, path = line.split(" ", 2)
    t = now - float(age)
    if kind == "f":
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write("x" * 100)
        os.utime(path, (t, t))
    elif kind == "d":
        os.makedirs(path + "/sub", exist_ok=True)
        open(path + "/sub/blob", "w").write("y" * 1000)
        for p in (path + "/sub/blob", path + "/sub", path):
            os.utime(p, (t, t))
    elif kind == "e":
        os.makedirs(path, exist_ok=True)
        os.utime(path, (t, t))
    elif kind == "l":
        link, target = path.split("=>")
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(target, link)
        os.utime(link, (t, t), follow_symlinks=False)
PYEOF
# State seeding: "key=age:SECS" stores now-SECS, "key=int:N" stores N.
cat > "$W/seed.py" <<'PYEOF'
import json, os, sys, time
out = {}
for a in sys.argv[2:]:
    k, v = a.split("=", 1)
    kind, val = v.split(":", 1)
    out[k] = (time.time() - float(val)) if kind == "age" else int(val)
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
json.dump(out, open(sys.argv[1], "w"))
PYEOF
mk() { "$PY" "$W/mk.py"; }
seed() { "$PY" "$W/seed.py" "$STATE" "$@"; }
jget() { "$PY" -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("<none>" if v is None else v)' "$STATE" "$1"; }

reset() { rm -rf "$SEC" "$TMP" "$RT" "$W/outside"; mkdir -p "$SEC" "$TMP" "$RT"; : > "$NCALLS"; }
# run_jan [VAR=val ...] [-- args]   → OUT, RC. Every path is a fixture; nothing real is reachable.
run_jan() {
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  OUT=$(env CLAUDE_SECURITY_JANITOR_DIR="$SEC" CLAUDE_SECURITY_JANITOR_TMPDIR="$TMP" \
        CLAUDE_SECURITY_JANITOR_STATE="$STATE" CLAUDE_SECURITY_JANITOR_LOCK="$LOCK" CLAUDE_SECURITY_JANITOR_PS_BIN="$W/ps" \
        CLAUDE_SECURITY_JANITOR_NOTIFY_BIN="$W/notify" CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-present" \
        ${envs[@]+"${envs[@]}"} "$PY" "$JAN" ${args[@]+"${args[@]}"} 2>&1); RC=$?
}
exists()     { [ -e "$1" ] || [ -L "$1" ]; }
chk_exists() { if exists "$1"; then ok "$2"; else nope "$2 (missing: $1)"; fi; }
chk_gone()   { if exists "$1"; then nope "$2 (still there: $1)"; else ok "$2"; fi; }
chk_rc()     { if [ "$RC" -eq "$1" ]; then ok "$2"; else nope "$2 (rc=$RC, want $1)"; fi; }
chk_out()    { if printf '%s' "$OUT" | grep -qE -- "$1"; then ok "$2"; else nope "$2 (no match: $1)"; fi; }
chk_noout()  { if printf '%s' "$OUT" | grep -qE -- "$1"; then nope "$2 (unexpected match: $1)"; else ok "$2"; fi; }
ncalls()     { wc -l < "$NCALLS" | tr -d ' '; }
chk_calls()  { if [ "$(ncalls)" -eq "$1" ]; then ok "$2"; else nope "$2 (notify calls=$(ncalls), want $1: $(cat "$NCALLS" | head -3))"; fi; }

fixture_mixed() {
  reset
  mk <<EOF
f $((10*D)) $SEC/security_warnings_state_aaa.json
f $((10*D)) $SEC/security_warnings_state_aaa.lock
f $((10*D)) $SEC/security_warnings_state_bbb.json.x1y2z3.tmp
f $((STALE+600)) $SEC/security_warnings_state_edge-old.json
f $((STALE-600)) $SEC/security_warnings_state_edge-new.json
f $H $SEC/security_warnings_state_fresh.json
f $H $SEC/security_warnings_state_fresh.lock
f $((30*D)) $SEC/log.txt
f $((30*D)) $SEC/log.txt.1
f $((30*D)) $SEC/review_model.json
f $((30*D)) $SEC/agent-sdk-venv.cooldown
f $((30*D)) $SEC/.sdk_bootstrap_spawned
d $((30*D)) $SEC/agent-sdk-venv
f $((10*D)) $SEC/security_warnings_state_aaa.json.bak
f $((10*D)) $SEC/xsecurity_warnings_state_y.json
e $((10*D)) $SEC/security_warnings_state_isdir.json
f $((10*D)) $W/outside/target.json
l $((10*D)) $SEC/security_warnings_state_link.json=>$W/outside/target.json
d $((3*H)) $TMP/pip-unpack-abc123
d $((3*H)) $TMP/pip-metadata-abc_123
d $((3*H)) $TMP/pip-install-AbC9
d $((3*H)) $TMP/pip-ephem-wheel-cache-q1w2
d $((3*H)) $TMP/pip-build-tracker-z9
d $((PIPAGE+600)) $TMP/pip-unpack-edgeold
d $((PIPAGE-600)) $TMP/pip-unpack-edgenew
d $((H/2)) $TMP/pip-metadata-fresh
d $((3*H)) $TMP/pip-other-abc
d $((3*H)) $TMP/pip-unpack-
d $((3*H)) $TMP/notpip-unpack-abc
d $((3*H)) $TMP/pip-unpack-has.dot
f $((3*H)) $TMP/pip-unpack-afile
f $((3*H)) $W/outside/pipdir/keep
l $((3*H)) $TMP/pip-unpack-linkdir=>$W/outside/pipdir
EOF
}

# ══ 0. in-process: the cases a subprocess cannot reach (first: cheap, and mutant runs fail fast on it) ═
cat > "$W/unit.py" <<'PYEOF'
import importlib.util, os, shutil, sys, tempfile, time, types
from unittest import mock
spec = importlib.util.spec_from_file_location("csj", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
PS, W = sys.argv[2], sys.argv[3]
bad = []
def check(name, cond, extra=""):
    print(("ok   - " if cond else "FAIL - ") + name + ("" if cond or not extra else "  :: " + str(extra)))
    if not cond: bad.append(name)
now = time.time()
real_lstat, real_unlink, real_rmtree = os.lstat, os.unlink, shutil.rmtree

def newdir():
    return tempfile.mkdtemp(prefix="csj-unit.", dir=W)
def mkf(d, name, age):
    p = os.path.join(d, name); open(p, "w").write("x"); t = now - age; os.utime(p, (t, t)); return p

# state: rewritten between listing and unlink → kept
d = newdir(); a = mkf(d, "security_warnings_state_a.json", 10*86400); b = mkf(d, "security_warnings_state_b.json", 10*86400)
def fake_lstat(p, *x, **k):
    st = real_lstat(p, *x, **k)
    return types.SimpleNamespace(st_mtime=now, st_ino=st.st_ino) if p == a else st
with mock.patch.object(m.os, "lstat", side_effect=fake_lstat):
    state, text = m.sweep_state(d, 3*86400, now, False)
check("state: a file rewritten between listing and unlink is kept", os.path.exists(a) and not os.path.exists(b) and "changed=1" in text, text)
# state: replaced by another inode → kept
d = newdir(); a = mkf(d, "security_warnings_state_a.json", 10*86400)
def fake_lstat2(p, *x, **k):
    st = real_lstat(p, *x, **k)
    return types.SimpleNamespace(st_mtime=st.st_mtime, st_ino=st.st_ino + 1) if p == a else st
with mock.patch.object(m.os, "lstat", side_effect=fake_lstat2):
    state, text = m.sweep_state(d, 3*86400, now, False)
check("state: a file replaced by another inode is kept", os.path.exists(a) and "changed=1" in text, text)
# state: unlink fails for one file → INCOMPLETE, the rest still go
d = newdir(); a = mkf(d, "security_warnings_state_a.json", 10*86400); b = mkf(d, "security_warnings_state_b.json", 10*86400)
def fake_unlink(p, *x, **k):
    if p == a: raise PermissionError(13, "denied")
    return real_unlink(p, *x, **k)
with mock.patch.object(m.os, "unlink", side_effect=fake_unlink):
    state, text = m.sweep_state(d, 3*86400, now, False)
check("state: unlink failure → incomplete, file kept, the other deleted", state == "incomplete" and os.path.exists(a) and not os.path.exists(b) and "FAILED=1" in text, (state, text))
# state: listing dies half way → NOTHING deleted
d = newdir(); a = mkf(d, "security_warnings_state_a.json", 10*86400); mkf(d, "security_warnings_state_b.json", 10*86400)
first = next(os.scandir(d))
class Boom:
    def __enter__(self): return self
    def __exit__(self, *x): return False
    def __iter__(self):
        yield first
        raise OSError(5, "EIO")
with mock.patch.object(m.os, "scandir", return_value=Boom()):
    state, text = m.sweep_state(d, 3*86400, now, False)
check("state: a listing that fails half way deletes nothing", state == "unreadable" and len(os.listdir(d)) == 2, (state, text))
# state: entry whose stat fails is kept and counted
d = newdir(); a = mkf(d, "security_warnings_state_a.json", 10*86400)
class Ent:
    name = "security_warnings_state_a.json"; path = a
    def stat(self, follow_symlinks=True): raise PermissionError(13, "denied")
class OneEnt:
    def __enter__(self): return self
    def __exit__(self, *x): return False
    def __iter__(self): return iter([Ent()])
with mock.patch.object(m.os, "scandir", return_value=OneEnt()):
    state, text = m.sweep_state(d, 3*86400, now, False)
check("state: an entry whose stat fails is kept and makes the part incomplete", state == "incomplete" and os.path.exists(a) and "unreadable=1" in text, (state, text))

# pip: rmtree that leaves the dir → PARTIAL
t = newdir(); p = os.path.join(t, "pip-unpack-abc"); os.makedirs(p); os.utime(p, (now - 3*3600,)*2)
with mock.patch.object(m.shutil, "rmtree", side_effect=lambda *a, **k: None):
    state, text = m.sweep_pip(t, 7200, now, False, PS)
check("pip: rmtree that leaves the dir → incomplete, PARTIAL=1", state == "incomplete" and "PARTIAL=1" in text and os.path.exists(p), (state, text))
# pip: the look after rmtree fails → UNVERIFIED, not "deleted"
t = newdir(); p = os.path.join(t, "pip-unpack-abc"); os.makedirs(p); os.utime(p, (now - 3*3600,)*2)
flag = {"rm": False}
def rm_then_flag(path, *a, **k):
    real_rmtree(path, *a, **k); flag["rm"] = True
def lstat_denied_after(path, *a, **k):
    if flag["rm"] and path == p: raise PermissionError(13, "denied")
    return real_lstat(path, *a, **k)
with mock.patch.object(m.shutil, "rmtree", side_effect=rm_then_flag), mock.patch.object(m.os, "lstat", side_effect=lstat_denied_after):
    state, text = m.sweep_pip(t, 7200, now, False, PS)
check("pip: a post-delete look that fails → incomplete, UNVERIFIED=1 (not counted deleted)", state == "incomplete" and "UNVERIFIED=1" in text and "deleted=0" in text, (state, text))

# pip liveness: lines that ARE a pip run
live = [
    "/opt/homebrew/bin/python3.13 -m pip install claude-agent-sdk",
    "/Users/athos/.claude/security/agent-sdk-venv/bin/python -m pip install --no-cache-dir x",
    "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python -m pip install x",
    "/x/python3.13 -Im ensurepip --upgrade --default-pip",
    "/usr/local/bin/pip3 install foo", "pip install foo", "/opt/homebrew/bin/pip3.13 download y",
    "python3.13 /Users/athos/.claude/plugins/cache/claude-plugins-official/security-guidance/2.0.14/hooks/ensure_agent_sdk.py",
    "/usr/bin/python3 -X utf8 -m pip list",
]
for line in live:
    os.environ["STUB_PS_EXTRA"] = line
    got, why = m.pip_alive(PS)
    check("pip_alive: LIVE  %s" % line[:70], got is True, (got, why))
# lines that are NOT a pip run (the stub's own benign lines already include pipedrive / pipx / a quoted -m pip)
notlive = ["/usr/bin/python3 /Users/athos/gt/pipedrive_sync.py", "/usr/bin/python3 -m pipx run foo",
           "claude --append-system-prompt use /usr/bin/python3 -m pip install x", "/usr/sbin/gzip -c f", "/bin/zsh -c pip",
           "/usr/bin/python3 /x/pip_audit.py", "/Applications/Pipeline.app/Contents/MacOS/Pipeline"]
for line in notlive:
    os.environ["STUB_PS_EXTRA"] = line
    got, why = m.pip_alive(PS)
    check("pip_alive: not live  %s" % line[:70], got is False, (got, why))
os.environ.pop("STUB_PS_EXTRA", None)
for mode in ("empty", "rc1"):
    os.environ["STUB_PS_MODE"] = mode
    got, why = m.pip_alive(PS)
    check("pip_alive: ps '%s' → could not tell (None)" % mode, got is None, (got, why))
os.environ.pop("STUB_PS_MODE", None)
got, why = m.pip_alive(os.path.join(W, "no-such-ps"))
check("pip_alive: ps binary missing → could not tell (None)", got is None, (got, why))

# interpreter selection (same walk as sg-python.sh)
def v(cands, to=3):
    return m.check_sdk(cands, (3, 10), to)[0]
P = lambda n: os.path.join(W, n)
check("select: first usable interpreter decides — absent before present → missing", v([P("py-absent"), P("py-present")]) == "missing")
check("select: an interpreter that is not installed is skipped", v([P("nope"), P("py-present")]) == "present")
check("select: too old (even with the SDK) is skipped, the next decides", v([P("py-old-sdk"), P("py-absent")]) == "missing")
check("select: only too-old interpreters → missing", v([P("py-old")]) == "missing")
check("select: nothing installed at all → missing", v([P("nope1"), P("nope2")]) == "missing")
check("select: a failing candidate then one lacking the SDK → unknown", v([P("py-rc1"), P("py-absent")]) == "unknown")
check("select: a failing candidate then one WITH the SDK → present", v([P("py-rc1"), P("py-present")]) == "present")
check("select: only a failing candidate → unknown", v([P("py-garbage")]) == "unknown")
check("select: a hanging candidate is cut off by the timeout → unknown", v([P("py-hang")], 2) == "unknown")

# corrupt alarm state reads as 'none sent yet' with a note
p = os.path.join(newdir(), "s.json"); open(p, "w").write("{not json")
data, note = m.read_alarm_state(p)
check("alarm state: corrupt file → {} plus a note", data == {} and "unreadable" in note, (data, note))
p2 = os.path.join(newdir(), "s.json"); open(p2, "w").write("[1,2]")
data, note = m.read_alarm_state(p2)
check("alarm state: not an object → {} plus a note", data == {} and "not an object" in note, (data, note))
sys.exit(1 if bad else 0)
PYEOF
UNIT_OUT=$("$PY" "$W/unit.py" "$JAN" "$W/ps" "$W" 2>&1)
UNIT_RC=$?
printf '%s\n' "$UNIT_OUT"
PASS=$((PASS + $(printf '%s\n' "$UNIT_OUT" | grep -c '^ok   - ')))
FAIL=$((FAIL + $(printf '%s\n' "$UNIT_OUT" | grep -c '^FAIL - ')))
[ "$UNIT_RC" -ne 0 ] && [ "$(printf '%s\n' "$UNIT_OUT" | grep -c '^FAIL - ')" -eq 0 ] && { FAIL=$((FAIL+1)); echo "FAIL - in-process block crashed (rc=$UNIT_RC)"; }
[ "${CSJ_FAILFAST:-0}" = "1" ] && [ "$FAIL" -gt 0 ] && exit 1

# ══ 0b. in-process, second block (lastro hq-mutants, ga-5mnu1pp): every limit, count and default ON its exact value ═══════════════
# What no fixture above puts on an edge: a file AT the age limit, a count of exactly 1 or 2, 52428 bytes (0.0 MB, where 52429 reads 0.1),
# a timeout, a default, a notify that exits 1 and not 3, a stderr of 130 characters. Not killable, on purpose: L305 and L307
# `follow_symlinks=False -> True` (29ee7f07a7 0ec3503a86: `e.is_symlink()` has already skipped every link, so the flag only ever sees a
# real dir); L490 `streak >= 0` -> `> 0` and `>= 1` (73eeca5977 af60fea0b4: a stored 0 and the `else 0` both give 0); L559 `else True -> False` (81e4dcc18c: with
# an empty tmp_dir the branch that reads it is not taken); L639 `sys.argv[1:]` -> `[0:]` (bf8c509a65: main() looks for three flags, and the
# script path is none of them).
# EQUIVALENT 29ee7f07a7 0ec3503a86: `follow_symlinks=False` -> True: `e.is_symlink()` has already skipped every link, so the flag only ever sees a real dir
# EQUIVALENT 73eeca5977 af60fea0b4: `streak >= 0` -> `> 0` and `>= 1`: a stored 0 and the `else 0` both give 0
# EQUIVALENT 81e4dcc18c: `else True` -> False: with an empty tmp_dir the branch that reads it is not taken
# EQUIVALENT bf8c509a65: `sys.argv[1:]` -> `[0:]`: main() looks for three flags, and the script path is none of them
cat > "$W/unit2.py" <<'PYEOF'
import contextlib, importlib.util, io, json, os, sys, tempfile, time, types
from unittest import mock
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("csj", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W, PS = sys.argv[2], sys.argv[3]
for k in [k for k in os.environ if k.startswith("CLAUDE_SECURITY_JANITOR_")]:
    del os.environ[k]
bad = []
def check(name, cond, extra=""):
    print(("ok   - " if cond else "FAIL - ") + name + ("" if cond or not extra else "  :: " + str(extra)))
    if not cond: bad.append(name)
def got(fn):
    try: return fn()
    except Exception as e: return "raised " + repr(e)
def quiet(fn, *a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): r = got(lambda: fn(*a))
    return r, buf.getvalue()
now = float(int(time.time()))   # whole seconds: an mtime of exactly now - age reads back exactly
H, D = 3600, 86400
def newdir(): return tempfile.mkdtemp(prefix="csj-unit2.", dir=W)
def mkf(d, name, age, size=1):
    p = os.path.join(d, name)
    with open(p, "wb") as f: f.truncate(size)
    os.utime(p, (now - age, now - age)); return p
def mkd(d, name, age):
    p = os.path.join(d, name); os.makedirs(p); os.utime(p, (now - age, now - age)); return p
def fake(rc=0, out="", err="", boom=None):   # what subprocess.run gives back: text only with text=True, nothing without capture_output
    seen = []
    def f(cmd, **kw):
        seen.append(kw)
        if boom: raise boom
        o, e = (out, err) if kw.get("text") else (out.encode(), err.encode())
        return types.SimpleNamespace(returncode=rc, stdout=o if kw.get("capture_output") else None, stderr=e if kw.get("capture_output") else None)
    f.seen = seen
    return f
def prun(f): return mock.patch.object(m.subprocess, "run", side_effect=f)

# log, cfg_int, is_real_target, real_user_temp_dir
spy = type("Spy", (io.StringIO,), {"n": 0, "flush": lambda s: (setattr(type(s), "n", type(s).n + 1), io.StringIO.flush(s))[1]})()
with contextlib.redirect_stdout(spy): m.log("hello")
check("log: every line is flushed", (spy.getvalue(), type(spy).n >= 1) == ("claude-security-janitor: hello\n", True), (spy.getvalue(), type(spy).n))
os.environ["CSJ_U2"] = "0"
check("cfg_int: 0 is not a positive integer", quiet(m.cfg_int, "CSJ_U2", 5)[0] is None)
os.environ["CSJ_U2"] = "1"
check("cfg_int: 1 is the smallest positive integer", quiet(m.cfg_int, "CSJ_U2", 5)[0] == 1)
del os.environ["CSJ_U2"]
check("is_real_target: no real dir to compare with counts as real", m.is_real_target("/p", None) is True)
check("is_real_target: a path that cannot be resolved counts as real", got(lambda: m.is_real_target("a\0b", "/x")) is True)
for rc, out, want in ((0, "/var/folders/x/T/\n", "/var/folders/x/T/"), (1, "/var/x", None), (0, "relative", None), (0, "", None), (2, "/x", None)):
    f = fake(rc, out)
    with prun(f): r = got(m.real_user_temp_dir)
    check("real_user_temp_dir: rc=%d out=%r gives %r" % (rc, out, want), r == want, r)
check("real_user_temp_dir: getconf gets a 10 s budget", f.seen[-1].get("timeout") == 10, f.seen)

# ps, notify, the probe and the interpreter walk
f = fake(0, "/sbin/launchd\n")
with prun(f): m.pip_alive("ps")
check("pip_alive: ps gets a 30 s budget", f.seen[-1].get("timeout") == 30, f.seen)
live = "pip install " + "z" * 130
with prun(fake(0, "/sbin/launchd\n" + live + "\n")): r = m.pip_alive("ps")
check("pip_alive: a live pip line is quoted up to 120 characters", r == (True, live[:120]), r)
f = fake(0)
with prun(f): r = m.send_notify("nb", "t", "b")
check("send_notify: notify exit 0 is sent, with a 30 s budget", (r, f.seen[-1].get("timeout")) == (True, 30), (r, f.seen))
f = fake(1, "", "e" * 130)
with prun(f): r, text = quiet(m.send_notify, "nb", "t", "b")
check("send_notify: notify exit 1 is not sent, and its stderr is quoted up to 120 characters", (r, text.strip().endswith("rc=1 " + "e" * 120)) == (False, True), (r, text))
with prun(fake(boom=OSError(2, "no notify"))): r, text = quiet(m.send_notify, "nb", "t", "b")
check("send_notify: a notify that cannot run is not sent", r is False, (r, text))
with prun(fake(1, "y" * 70)): r = m.probe_python("/p", 5)
check("probe_python: a probe that did not answer quotes its output up to 60 characters", r == (None, "rc=1, output " + repr("y" * 60)), r)
with mock.patch.object(m, "resolve_python", side_effect=lambda c: c), mock.patch.object(m, "probe_python", side_effect=lambda p, t: ((3, 10, True), None)):
    r = m.check_sdk(["pyX"], (3, 10))
check("check_sdk: an interpreter at exactly the minimum version is new enough", r[:2] == ("present", "pyX"), r)
with mock.patch.object(m, "resolve_python", side_effect=lambda c: None): r = m.check_sdk(["a"], (3, 10))
check("check_sdk: with nothing installed the minimum is said as major.minor", r == ("missing", "", "no python >= 3.10 on PATH (none found)"), r)
check("resolve_python: a regular file that is not executable and a directory are no interpreter", (m.resolve_python(mkf(newdir(), "nx", 0)), m.resolve_python(W)) == (None, None))

# state files: counts, the age limit, the byte total, and what vanishes or fails between the listing and the unlink
d = newdir()
for n in "1234": mkf(d, "security_warnings_state_old%s.json" % n, 10 * D)
mkf(d, "security_warnings_state_exact.json", 3 * D); mkf(d, "security_warnings_state_fresh.tmp", H); mkf(d, "security_warnings_state_other.txt", 10 * D)
os.symlink(mkf(newdir(), "target.json", 10 * D), os.path.join(d, "security_warnings_state_link.json")); os.makedirs(os.path.join(d, "security_warnings_state_dir.json"))
state, text = m.sweep_state(d, 3 * D, now, True)
check("state dry run: 4 old, 2 fresh (one AT the limit), 2 not regular (a link is not followed), a sample of 3", state == "dry-run" and "would delete 4 file(s)" in text and "kept_fresh=2 changed=0 unreadable=0 nonregular=2" in text and len(text.rsplit("e.g. ", 1)[1].split()) == 3, text)
d = newdir(); mkf(d, "security_warnings_state_big.json", 10 * D, 52428)
check("state: the bytes freed are the deleted file's alone (52428 B reads 0.0 MB)", m.sweep_state(d, 3 * D, now, False) == ("pruned", "deleted=1 (0.0 MB) gone=0; kept_fresh=0 changed=0 unreadable=0 nonregular=0"))
d = newdir(); nm = {k: mkf(d, "security_warnings_state_%s.json" % k, 10 * D) for k in ("lg", "lf", "ug", "ok")}
real_lstat, real_unlink = os.lstat, os.unlink
def lst(p, *a, **k):
    if p == nm["lg"]: raise FileNotFoundError(2, "gone")
    if p == nm["lf"]: raise PermissionError(13, "denied")
    return real_lstat(p, *a, **k)
def unl(p, *a, **k):
    if p == nm["ug"]: raise FileNotFoundError(2, "gone")
    return real_unlink(p, *a, **k)
with mock.patch.object(m.os, "lstat", side_effect=lst), mock.patch.object(m.os, "unlink", side_effect=unl): r = m.sweep_state(d, 3 * D, now, False)
check("state: gone at lstat or at unlink is gone (2), an lstat that fails is failed (1), one is deleted", r == ("incomplete", "deleted=1 (0.0 MB) gone=2 FAILED=1; kept_fresh=0 changed=0 unreadable=0 nonregular=0"), r)

# pip debris: the same counts, and an rmtree that cannot finish
t = newdir()
for n in "1234": mkd(t, "pip-unpack-old%s" % n, 3 * H)
mkd(t, "pip-unpack-exact", 2 * H); mkd(t, "pip-metadata-fresh", H // 2)
os.symlink(mkd(newdir(), "somedir", 3 * H), os.path.join(t, "pip-unpack-link")); open(os.path.join(t, "pip-unpack-afile"), "w").close()
state, text = m.sweep_pip(t, 2 * H, now, True, PS)
check("pip dry run: 4 old, 2 fresh (one AT the limit), a sample of 3", state == "dry-run" and "would delete 4 dir(s)" in text and "kept_fresh=2 unreadable=0" in text and len(text.rsplit("e.g. ", 1)[1].split()) == 3, text)
class Ent:
    name = "pip-unpack-zz"; path = "/x/pip-unpack-zz"
    def is_symlink(self): raise PermissionError(13, "denied")
class Ents:
    def __enter__(self): return self
    def __exit__(self, *x): return False
    def __iter__(self): return iter([Ent()])
with mock.patch.object(m.os, "scandir", return_value=Ents()): r = m.sweep_pip(newdir(), 2 * H, now, False, PS)
check("pip: an entry that cannot be examined is counted and makes the part incomplete", r == ("incomplete", "no pip-* dir older than 7200 s; kept_fresh=0 unreadable=1"), r)
t = newdir(); p = os.path.join(t, "pip-unpack-big"); os.makedirs(p); mkf(p, "blob", 0, 52428); os.utime(p, (now - 3 * H,) * 2)
check("pip: freed counts the deleted bytes and deleted the dirs (52428 B reads 0.0 MB)", m.sweep_pip(t, 2 * H, now, False, PS) == ("pruned", "deleted=1 dir(s) (0.0 MB); kept_fresh=0 unreadable=0"))
if os.geteuid() != 0:
    t = newdir(); p = os.path.join(t, "pip-unpack-locked"); sub = os.path.join(p, "sub"); os.makedirs(sub); mkf(sub, "f", 0); os.chmod(sub, 0o555); os.utime(p, (now - 3 * H,) * 2)
    r = got(lambda: m.sweep_pip(t, 2 * H, now, False, PS)); os.chmod(sub, 0o755)
    check("pip: an rmtree that cannot remove part of the dir leaves it PARTIAL, it never raises", isinstance(r, tuple) and r[0] == "incomplete" and "PARTIAL=1" in r[1], r)
else:
    check("(root: the dir that cannot be removed is skipped)", True)

# the alarm policy of the SDK part
def hs(verdict, state, notify=True, path=None):
    sp = path or os.path.join(newdir(), "s.json"); sent = []
    if state is not None and not path: json.dump(state, open(sp, "w"))
    with mock.patch.object(m, "send_notify", side_effect=lambda nb, t, b: (sent.append(t) or notify)): r, text = quiet(m.handle_sdk, verdict, "/py", "detail", now, False, sp, "nb", 21600, 3)
    return r, len(sent), (json.load(open(sp)) if os.path.exists(sp) else None)
check("sdk missing: an alarm sent exactly one repeat ago is due again; the state says when and resets the unknown streak", hs("missing", {"last_alarm_missing": now - 21600})[1:] == (1, {"last_alarm_missing": now, "unknown_streak": 0}))
check("sdk unknown: a streak that is not a count restarts at 1", hs("unknown", {"unknown_streak": "garbage"})[2]["unknown_streak"] == 1)
check("sdk unknown: the 3rd run in a row alarms when the last alarm is exactly one repeat old", hs("unknown", {"unknown_streak": 2, "last_alarm_unknown": now - 21600})[1:] == (1, {"unknown_streak": 3, "last_alarm_unknown": now}))
check("sdk unknown: a notify that fails makes the part not OK", hs("unknown", {"unknown_streak": 2}, notify=False)[:2] == (False, 1))
check("sdk: an alarm state that cannot be written makes the part not OK", hs("missing", None, path=os.path.join(mkf(newdir(), "afile", 0), "s.json"))[0] is False)

# main(): the defaults, the dry-run rule, the temp dir it picks, bad limits, a lock that cannot be taken, a crash, --help
M = newdir(); SECD, TMPD = os.path.join(M, "sec"), os.path.join(M, "tmp"); os.makedirs(SECD); os.makedirs(TMPD)
cap = {}
def runmain(argv, env=None, **over):
    cap.clear()
    e = dict(CLAUDE_SECURITY_JANITOR_DIR=SECD, CLAUDE_SECURITY_JANITOR_TMPDIR=TMPD, CLAUDE_SECURITY_JANITOR_STATE=os.path.join(M, "st.json"), CLAUDE_SECURITY_JANITOR_LOCK=os.path.join(M, "lk"), CLAUDE_SECURITY_JANITOR_PS_BIN=PS, CLAUDE_SECURITY_JANITOR_NOTIFY_BIN="nb", CLAUDE_SECURITY_JANITOR_PYTHONS="pyX", GC_CITY_PATH=M)
    s = dict(sweep_state=lambda sd, a, n, dry: cap.update(state_age=a, dry1=dry) or ("none-old", "x"), sweep_pip=lambda td, a, n, dry, ps: cap.update(td=td, pip_age=a, dry2=dry) or ("none-old", "x"),
             check_sdk=lambda c, mp, pt: cap.update(probe=pt, calls=cap.get("calls", 0) + 1) or ("present", "p", "d"), handle_sdk=lambda v, i, dt, n, dry, sp, nb, rep, ua: cap.update(repeat=rep, ua=ua) or True)
    s.update(over)
    with mock.patch.dict(os.environ, dict(e, **(env or {}))), contextlib.ExitStack() as es:
        for k, v in s.items(): es.enter_context(mock.patch.object(m, k, side_effect=v))
        return quiet(m.main, argv)
r, text = runmain([])
check("main: the defaults are 3 days, 2 hours, 6 hours, 3 runs and a 60 s probe", (r, cap.get("state_age"), cap.get("pip_age"), cap.get("repeat"), cap.get("ua"), cap.get("probe")) == (0, 259200, 7200, 21600, 3, 60), (r, cap))
real = dict(CLAUDE_SECURITY_JANITOR_REAL_DIR=SECD, CLAUDE_SECURITY_JANITOR_REAL_TMPDIR=TMPD)
r, text = runmain([], real)
check("main: a target that IS the real one is a dry run unless PROD=1, and says so", (text.count("target is the real"), cap.get("dry1"), cap.get("dry2")) == (2, True, True), (text, cap))
r, text = runmain(["--dry-run"], real)
check("main --dry-run: dry everywhere, and the real-target line is not printed (it would repeat what was asked)", ("target is the real" in text, cap.get("dry1"), cap.get("dry2")) == (False, True, True), (text, cap))
r, text = runmain([])
check("main: a fixture target is not a dry run and prints no real-target line", ("target is the real" in text, cap.get("dry1"), cap.get("dry2")) == (False, False, False), (text, cap))
runmain([], dict(CLAUDE_SECURITY_JANITOR_REAL_TMPDIR="/other-real"))
check("main: an explicit _TMPDIR fixture wins over the real user temp dir", cap.get("td") == TMPD, cap)
runmain([], dict(CLAUDE_SECURITY_JANITOR_TMPDIR="", CLAUDE_SECURITY_JANITOR_REAL_TMPDIR=TMPD, TMPDIR="/elsewhere"))
check("main: with no fixture the real user temp dir is used, not $TMPDIR", cap.get("td") == TMPD, cap)
for k, v in (("MIN_PY", "garbage"), ("ALARM_REPEAT_SECS", "0"), ("UNKNOWN_AFTER", "0"), ("PROBE_TIMEOUT_SECS", "x")):
    r, text = runmain([], {"CLAUDE_SECURITY_JANITOR_" + k: v})
    check("main: a bad %s skips the SDK check, says so, exits 1, and never runs the check" % k, (r, cap.get("calls", 0), "sdk-check=incomplete" in text) == (1, 0, True), (r, cap, text))
r, text = runmain([], {"CLAUDE_SECURITY_JANITOR_LOCK": os.path.join(mkf(newdir(), "afile", 0), "lk")})
check("main: a lock that cannot be taken is exit 1 and nothing is done", (r, "state_age" in cap) == (1, False), (r, cap, text))
def boom(*a): raise RuntimeError("boom")
r, text = runmain([], check_sdk=boom)
check("main: a crash inside the SDK part is exit 1 and says crashed", (r, "sdk-check=crashed" in text) == (1, True), (r, text))
r, text = runmain(["--help"])
check("main --help: prints the docs, exits 0, runs nothing", (r, "## Contents" in text, "state_age" in cap) == (0, True, False), (r, cap))
sys.exit(1 if bad else 0)
PYEOF
UNIT2_OUT=$("$PY" "$W/unit2.py" "$JAN" "$W" "$W/ps" 2>&1)
UNIT2_RC=$?
printf '%s\n' "$UNIT2_OUT"
PASS=$((PASS + $(printf '%s\n' "$UNIT2_OUT" | grep -c '^ok   - ')))
FAIL=$((FAIL + $(printf '%s\n' "$UNIT2_OUT" | grep -c '^FAIL - ')))
[ "$UNIT2_RC" -ne 0 ] && [ "$(printf '%s\n' "$UNIT2_OUT" | grep -c '^FAIL - ')" -eq 0 ] && { FAIL=$((FAIL+1)); echo "FAIL - second in-process block crashed (rc=$UNIT2_RC)"; }
[ "${CSJ_FAILFAST:-0}" = "1" ] && [ "$FAIL" -gt 0 ] && exit 1

# ══ 1. baseline: stale goes, fresh / unrelated / look-alikes stay ═══════════════════════════════
fixture_mixed
run_jan
chk_rc 0 "baseline: every part ran, exit 0"
chk_gone "$SEC/security_warnings_state_aaa.json" "state: 10-day-old .json deleted"
chk_gone "$SEC/security_warnings_state_aaa.lock" "state: 10-day-old .lock deleted"
chk_gone "$SEC/security_warnings_state_bbb.json.x1y2z3.tmp" "state: 10-day-old .json.<rand>.tmp deleted"
chk_gone "$SEC/security_warnings_state_edge-old.json" "state: 3 d + 10 min deleted"
chk_exists "$SEC/security_warnings_state_edge-new.json" "state: 3 d - 10 min kept"
chk_exists "$SEC/security_warnings_state_fresh.json" "state: 1-hour-old .json kept"
chk_exists "$SEC/security_warnings_state_fresh.lock" "state: 1-hour-old .lock kept"
for f in log.txt log.txt.1 review_model.json agent-sdk-venv.cooldown .sdk_bootstrap_spawned agent-sdk-venv \
         security_warnings_state_aaa.json.bak xsecurity_warnings_state_y.json security_warnings_state_isdir.json; do
  chk_exists "$SEC/$f" "state: unrelated/look-alike '$f' kept even when ancient"
done
chk_exists "$SEC/security_warnings_state_link.json" "state: symlink named like a state file kept"
chk_exists "$W/outside/target.json" "state: the symlink's target kept"
for k in pip-unpack-abc123 pip-metadata-abc_123 pip-install-AbC9 pip-ephem-wheel-cache-q1w2 pip-build-tracker-z9 pip-unpack-edgeold; do
  chk_gone "$TMP/$k" "pip: 3 h-old (or 2 h + 10 min) $k deleted with its contents"
done
chk_exists "$TMP/pip-unpack-edgenew" "pip: 2 h - 10 min kept"
chk_exists "$TMP/pip-metadata-fresh" "pip: 30-min-old kept"
for k in pip-other-abc pip-unpack- notpip-unpack-abc pip-unpack-has.dot pip-unpack-afile pip-unpack-linkdir; do
  chk_exists "$TMP/$k" "pip: non-matching '$k' kept even when old"
done
chk_exists "$W/outside/pipdir/keep" "pip: the symlinked dir's content kept (symlink not followed)"
chk_calls 0 "baseline: SDK present → no notify"
[ ! -f "$STATE" ] && ok "baseline: SDK present → no alarm state written" || nope "baseline: state file written"
chk_out "sdk: present" "baseline: reports the SDK present"
chk_out "summary: state-files=pruned pip-debris=pruned sdk-check=present exit=0" "baseline: summary line"

# ══ 2. a live pip protects every old dir (not an error); ps that cannot answer protects them too ═
fixture_mixed
run_jan STUB_PS_EXTRA="/opt/homebrew/bin/python3.13 -m pip install claude-agent-sdk"
chk_rc 0 "pip live: not an error, exit 0"
chk_exists "$TMP/pip-unpack-abc123" "pip live: old dir kept"
chk_out "pip-debris: pip-live" "pip live: said so"
chk_gone "$SEC/security_warnings_state_aaa.json" "pip live: the state-file part still ran"
fixture_mixed
run_jan STUB_PS_MODE=rc1
chk_rc 1 "ps rc=1: INCOMPLETE, exit 1"
chk_exists "$TMP/pip-unpack-abc123" "ps rc=1: old dir kept (cannot tell ≠ no pip)"
chk_out "cannot tell whether pip is running" "ps rc=1: said it could not tell"
chk_gone "$SEC/security_warnings_state_aaa.json" "ps rc=1: the state-file part still ran"
reset; mk <<EOF
d $((H/2)) $TMP/pip-unpack-fresh
EOF
run_jan STUB_PS_MODE=rc1
chk_rc 0 "ps is not asked when no dir is old enough (a broken ps cannot fail a no-op)"

# ══ 3. dry run, kill switch, bad limit, single instance ════════════════════════════════════════
fixture_mixed
run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-absent" -- --dry-run
chk_exists "$SEC/security_warnings_state_aaa.json" "dry-run: state file kept"
chk_exists "$TMP/pip-unpack-abc123" "dry-run: pip dir kept"
chk_out "DRY-RUN would delete" "dry-run: says what it would do"
chk_calls 0 "dry-run: SDK missing but nothing sent"
[ ! -f "$STATE" ] && ok "dry-run: no alarm state written" || nope "dry-run: wrote alarm state"
fixture_mixed
run_jan CLAUDE_SECURITY_JANITOR_ENABLED=0
chk_rc 0 "kill switch: exit 0"
chk_exists "$SEC/security_warnings_state_aaa.json" "kill switch: nothing deleted"
fixture_mixed
run_jan CLAUDE_SECURITY_JANITOR_STATE_MAX_AGE_SECS=abc
chk_rc 1 "bad STATE_MAX_AGE_SECS: INCOMPLETE, exit 1"
chk_exists "$SEC/security_warnings_state_aaa.json" "bad limit: not guessed, nothing deleted"
chk_gone "$TMP/pip-unpack-abc123" "bad limit: the other part still ran"
fixture_mixed
"$PY" -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_CREAT|os.O_RDWR); fcntl.flock(fd,2); open(sys.argv[2],"w").write("held"); time.sleep(120)' "$LOCK" "$W/held" &
HOLDER=$!
i=0; while [ ! -s "$W/held" ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$W/held" ] || nope "lock holder never took the lock (test setup)"
run_jan
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
chk_rc 0 "lock held by another run: exit 0"
chk_out "another run holds the lock" "lock held: said so"
chk_exists "$SEC/security_warnings_state_aaa.json" "lock held: nothing deleted"

# ══ 4. unreadable / absent dirs: nothing deleted, never "nothing there" ═════════════════════════
reset; echo x > "$W/afile"
run_jan CLAUDE_SECURITY_JANITOR_DIR="$W/afile" CLAUDE_SECURITY_JANITOR_TMPDIR="$W/afile"
chk_rc 1 "dirs that cannot be listed: INCOMPLETE, exit 1"
chk_out "state-files: unreadable" "unlistable security dir: reported unreadable"
chk_out "pip-debris: unreadable" "unlistable temp dir: reported unreadable"
if [ "$(id -u)" -ne 0 ]; then
  fixture_mixed; chmod 000 "$SEC" "$TMP"
  run_jan
  chmod 755 "$SEC" "$TMP"
  chk_rc 1 "chmod 000 dirs: INCOMPLETE, exit 1"
  chk_exists "$SEC/security_warnings_state_aaa.json" "chmod 000: stale state file still there"
  chk_exists "$TMP/pip-unpack-abc123" "chmod 000: old pip dir still there"
else
  printf 'skip - chmod 000 case (running as root: the mode does not stop root)\n'
fi
reset; rm -rf "$SEC" "$TMP"
run_jan
chk_rc 0 "dirs that do not exist: nothing to clean, exit 0"
chk_out "state-files: absent" "missing security dir: absent"

# ══ 5. production sentinel: the "real" target is a dry run unless PROD=1 ═══════════════════════
fixture_mixed
run_jan CLAUDE_SECURITY_JANITOR_REAL_DIR="$SEC" CLAUDE_SECURITY_JANITOR_REAL_TMPDIR="$TMP"
chk_exists "$SEC/security_warnings_state_aaa.json" "sentinel: real security dir without PROD=1 → nothing deleted"
chk_exists "$TMP/pip-unpack-abc123" "sentinel: real temp dir without PROD=1 → nothing deleted"
chk_out "CLAUDE_SECURITY_JANITOR_PROD != 1: dry run" "sentinel: said why"
fixture_mixed
run_jan CLAUDE_SECURITY_JANITOR_REAL_DIR="$SEC" CLAUDE_SECURITY_JANITOR_REAL_TMPDIR="$TMP" CLAUDE_SECURITY_JANITOR_PROD=1
chk_gone "$SEC/security_warnings_state_aaa.json" "sentinel: PROD=1 → state file deleted"
chk_gone "$TMP/pip-unpack-abc123" "sentinel: PROD=1 → pip dir deleted"

# ══ 6. SDK check + alarm policy ════════════════════════════════════════════════════════════════
reset
run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-absent"
chk_rc 1 "sdk missing: exit 1"
chk_calls 1 "sdk missing: one notify"
grep -q -- '-p 4' "$NCALLS" && grep -q 'claude_agent_sdk sumiu' "$NCALLS" && grep -q "$W/py-absent -m pip install --break-system-packages claude-agent-sdk" "$NCALLS" \
  && ok "sdk missing: priority 4, title, and the exact repair command for the interpreter" || nope "sdk missing: notify args wrong: $(cat "$NCALLS")"
[ "$(jget last_alarm_missing)" != "<none>" ] && ok "sdk missing: alarm recorded" || nope "sdk missing: alarm not recorded"
seed last_alarm_missing=age:$H
: > "$NCALLS"; run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-absent"
chk_calls 0 "sdk missing, alarmed 1 h ago: no repeat inside the 6 h window"
chk_rc 1 "sdk missing, suppressed: still exit 1 (it IS missing)"
seed last_alarm_missing=age:$((7*H))
: > "$NCALLS"; run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-absent"
chk_calls 1 "sdk missing, alarmed 7 h ago: repeats"
reset
run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-absent" STUB_NOTIFY_RC=1
chk_rc 1 "notify fails: exit 1"
chk_out "NOTIFY FAILED" "notify fails: said so"
[ -f "$STATE" ] && [ "$(jget last_alarm_missing)" != "<none>" ] && nope "notify fails: recorded as SENT" || ok "notify fails: NOT recorded as sent"
: > "$NCALLS"; run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-absent"
chk_calls 1 "after a failed notify the next run sends it"
seed last_alarm_missing=age:$H unknown_streak=int:2
: > "$NCALLS"; run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-present"
chk_rc 0 "sdk back: exit 0"
chk_calls 0 "sdk back: no notify"
[ "$(cat "$STATE")" = "{}" ] && ok "sdk back: alarm state cleared" || nope "sdk back: state is $(cat "$STATE")"
reset
run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-hang" CLAUDE_SECURITY_JANITOR_PROBE_TIMEOUT_SECS=3
chk_rc 1 "probe hangs: exit 1"
chk_out "sdk: UNKNOWN \(1 in a row\)" "probe hangs: UNKNOWN, not MISSING"
chk_noout "sdk: MISSING" "probe hangs: never read as missing"
chk_calls 0 "probe hangs once: no alarm yet (needs 3 in a row)"
[ "$(jget unknown_streak)" = "1" ] && ok "probe hangs: streak counted" || nope "probe hangs: streak=$(jget unknown_streak)"
seed unknown_streak=int:2
run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-garbage"
chk_calls 1 "3rd unknown in a row (garbage output): alarms"
grep -q 'nao consegui checar' "$NCALLS" && ok "3rd unknown: its own text, not the 'sumiu' alarm" || nope "3rd unknown: wrong text: $(cat "$NCALLS")"
reset
run_jan CLAUDE_SECURITY_JANITOR_PYTHONS="$W/py-rc1 $W/py-absent"
chk_noout "sdk: MISSING" "an earlier candidate failing + a later one lacking the SDK: UNKNOWN, not MISSING"
reset
mkdir -p "$W/fakesite/claude_agent_sdk" && : > "$W/fakesite/claude_agent_sdk/__init__.py"
run_jan PYTHONPATH="$W/fakesite" CLAUDE_SECURITY_JANITOR_PYTHONS="$PY" CLAUDE_SECURITY_JANITOR_MIN_PY=3.0
chk_out "sdk: present" "real interpreter + a package on PYTHONPATH: find_spec says present"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# ══ 8. mutants: each must fail this battery ═════════════════════════════════════════════════════
if [ "${CSJ_MUTANTS:-0}" = "1" ] && [ "$FAIL" -eq 0 ]; then
  cat > "$W/mutate.py" <<'PYEOF'
import sys
name, src, dst = sys.argv[1:4]
s = open(src).read()
M = {
 "state-age-inverted": ("        if now - st.st_mtime > max_age:\n            old.append((e.path, st))\n        else:\n            kept_fresh += 1\n\n    deleted = gone",
                        "        if now - st.st_mtime < max_age:\n            old.append((e.path, st))\n        else:\n            kept_fresh += 1\n\n    deleted = gone"),
 "pip-age-inverted": ("        if now - st.st_mtime > max_age:\n            old.append((e.path, st))\n        else:\n            kept_fresh += 1\n\n    tail",
                      "        if now - st.st_mtime < max_age:\n            old.append((e.path, st))\n        else:\n            kept_fresh += 1\n\n    tail"),
 "ps-failure-as-no-pip": ('        return None, "ps rc=%s, %d byte(s) of output" % (r.returncode, len(r.stdout))',
                          '        return False, ""'),
 "unlistable-as-empty": ('        return "unreadable", "cannot list %s: %s" % (sec_dir, e)',
                         '        return "none-old", "cannot list %s: %s" % (sec_dir, e)'),
 "probe-failure-as-missing": ('        if got is None:\n            failures.append("%s: %s" % (path, why))\n            continue',
                              '        if got is None:\n            got = (3, 13, False)'),
 "failed-notify-as-sent": ('    try:\n        r = subprocess.run(\n            [notify_bin, "-t", title, "-p", "4", body],',
                           '    return True\n    try:\n        r = subprocess.run(\n            [notify_bin, "-t", title, "-p", "4", body],'),
 "pip-match-not-anchored": ("            if rx.match(line):", "            if re.search(rx.pattern.lstrip(\"^\"), line):"),
 "symlink-followed": ("        if not stat.S_ISREG(st.st_mode):", "        if False:"),
 "sentinel-dropped": ("        dry1 = dry_all or (sec_real_target and not prod)", "        dry1 = dry_all"),
 "unlink-without-recheck": ("        if st2.st_mtime != st.st_mtime or st2.st_ino != st.st_ino:", "        if False:"),
 "partial-rmtree-as-deleted": ("        else:\n            partial += 1\n", "        else:\n            deleted += 1\n"),
 "repeat-alarm-every-run": ("        due = not isinstance(last, (int, float)) or now - last >= repeat\n        log(\"sdk: MISSING",
                            "        due = True\n        log(\"sdk: MISSING"),
}
old, new = M[name]
assert s.count(old) == 1, "mutation %s: pattern found %d times" % (name, s.count(old))
open(dst, "w").write(s.replace(old, new))
PYEOF
  SURV=0
  for mut in state-age-inverted pip-age-inverted ps-failure-as-no-pip unlistable-as-empty probe-failure-as-missing \
             failed-notify-as-sent pip-match-not-anchored symlink-followed sentinel-dropped unlink-without-recheck \
             partial-rmtree-as-deleted repeat-alarm-every-run; do
    "$PY" "$W/mutate.py" "$mut" "$JAN" "$W/mutant-$mut.py" || { echo "FAIL - mutant $mut: could not be built"; SURV=$((SURV+1)); continue; }
    # A mutant that does not even parse would "fail" the battery for the wrong reason: refuse it.
    "$PY" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$W/mutant-$mut.py" 2>/dev/null \
      || { echo "FAIL - mutant $mut: does not parse, proves nothing"; SURV=$((SURV+1)); continue; }
    MOUT=$(CLAUDE_SECURITY_JANITOR_PATH="$W/mutant-$mut.py" CSJ_MUTANTS=0 CSJ_FAILFAST=1 bash "$0" 2>&1); MRC=$?
    FIRST=$(printf '%s\n' "$MOUT" | grep -m1 '^FAIL - ')
    # Killed = the battery failed AND said which assertion caught it (a FATAL or crash is not a kill).
    if [ "$MRC" -ne 0 ] && [ -n "$FIRST" ]; then
      echo "ok   - mutant killed: $mut   [$FIRST]"
    else
      echo "FAIL - mutant SURVIVED or died for the wrong reason (rc=$MRC): $mut"; SURV=$((SURV+1))
    fi
  done
  [ "$SURV" -eq 0 ] || FAIL=$((FAIL+SURV))
  printf '\nmutants: %d survived\n' "$SURV"
fi

[ "$FAIL" -eq 0 ]
