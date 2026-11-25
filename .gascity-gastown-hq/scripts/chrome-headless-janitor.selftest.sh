#!/usr/bin/env bash
# chrome-headless-janitor.selftest.sh — drives the REAL chrome-headless-janitor.py (ga-xjv29mb).
#
# Contents
#   Stubs and fixtures · 0 in-process cases · 1 sweep and live process · 2 never touched · 3 reads that fail · 4 modes · 5 mutants
#
# Everything runs in a scratch tree: a fake HOME holding fake ~/Library/{Application Support,Caches}/Google/Chrome-headless
# trees, and a stub `ps` that can FAIL (rc 1, empty) or cut every line at 80 columns the way BSD ps does when it is not asked
# for unlimited width (two -w). Nothing reaches the real ~/Library, the live city or a real Chrome.
# The failing stubs must land in the INERT state: nothing deleted, and "could not tell" never read as "no Chrome running".
#
# --mutants (or CHJ_MUTANTS=1) re-runs this battery against deliberately broken copies of the janitor and requires every one to FAIL it.
set -uo pipefail
[ "${1:-}" = "--mutants" ] && CHJ_MUTANTS=1   # mbp-run.sh passes args to the script, not env

HERE="$(cd "$(dirname "$0")" && pwd)"
JAN="${CHROME_HEADLESS_JANITOR_PATH:-$HERE/chrome-headless-janitor.py}"
[ -f "$JAN" ] || { echo "FATAL: janitor not found at $JAN"; exit 1; }
PY="$(command -v python3)" || { echo "FATAL: python3 missing"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/chj-selftest.XXXXXX")"
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export HOME="$W/home"
AS="$HOME/Library/Application Support/Google/Chrome-headless"
CA="$HOME/Library/Caches/Google/Chrome-headless"
ASX="$HOME/Library/Application Support/Google/Chrome for Testing-headless"
RT="$W/rt"; LOCK="$RT/lock"
H=3600; D=86400
PASS=0; FAIL=0; OUT=""; RC=0; RUN_CWD=""
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() {
  FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"
  [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | head -14
  [ "${CHJ_FAILFAST:-0}" = "1" ] && exit 1   # mutant runs: the first failure is enough
  return 0
}

# ── stubs ────────────────────────────────────────────────────────────────────────────────────────
# `ps -A -w -w -o command=` prints the FULL command line only with two -w; with fewer, BSD ps cuts each line at 80 columns.
cat > "$W/ps" <<'STUB'
#!/bin/sh
ww=0
for a in "$@"; do [ "$a" = "-w" ] && ww=$((ww+1)); done
emit() { if [ "$ww" -ge 2 ]; then printf '%s\n' "$1"; else printf '%.80s\n' "$1"; fi; }
case "${STUB_PS_MODE:-ok}" in
  ok)    emit "/sbin/launchd"
         emit "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222 --user-data-dir=/Users/athos/.chrome-cdp"
         [ -n "${STUB_PS_EXTRA:-}" ] && emit "$STUB_PS_EXTRA"
         exit 0 ;;
  empty) exit 0 ;;
  rc1)   echo "/sbin/launchd"; exit 1 ;;
  killparent) kill -KILL "$PPID" ;;   # SIGKILLs whoever asked: only the janitor under test ever starts this stub
esac
STUB
chmod +x "$W/ps"

# Fixture builder (a module, so the in-process cases reuse it). Lines "<kind> <age_secs> <path>", ages relative to now:
#   P  a Chrome-like profile, every mtime = now-age     PR  as P, plus Default/Cache/recent written <recent> s ago ("path@recent"),
#   the DIRECTORIES staying old     F  regular file     L  symlink "link=>target"
cat > "$W/mk.py" <<'PYEOF'
import os, sys, time
now = time.time()
def put(p, n):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        fh.write("x" * n)
def build(kind, age, path):
    t = now - float(age)
    if kind in ("P", "PR"):
        recent = None
        if kind == "PR":
            path, recent = path.rsplit("@", 1)
        for rel, n in (("Local State", 50), ("Default/Preferences", 200), ("Default/Cache/data_0", 2000)):
            put(os.path.join(path, rel), n)
        if recent is not None:
            put(os.path.join(path, "Default/Cache/recent"), 1)
        for root, dirs, files in os.walk(path, topdown=False):   # bottom-up: the old mtimes go back on last
            for f in files:
                tt = now - float(recent) if f == "recent" else t
                os.utime(os.path.join(root, f), (tt, tt))
            os.utime(root, (t, t))
    elif kind == "F":
        put(path, 10); os.utime(path, (t, t))
    elif kind == "L":
        link, target = path.split("=>")
        os.makedirs(os.path.dirname(link), exist_ok=True); os.symlink(target, link)
        os.utime(link, (t, t), follow_symlinks=False)
if __name__ == "__main__":
    for line in sys.stdin:
        if line.strip():
            build(*line.rstrip("\n").split(" ", 2))
PYEOF
mk() { "$PY" "$W/mk.py"; }

reset() { chmod -R u+rwx "$HOME" "$W/outside" 2>/dev/null; rm -rf "$HOME/Library" "$W/outside" "$RT"; mkdir -p "$HOME/Library" "$RT"; }
# run_jan [VAR=val ...] [-- args]   → OUT, RC. Every path is a fixture; nothing real is reachable. RUN_CWD=<dir> moves the working directory.
run_jan() {
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  OUT=$(cd "${RUN_CWD:-.}" && env CHROME_HEADLESS_JANITOR_LOCK="$LOCK" CHROME_HEADLESS_JANITOR_PS_BIN="$W/ps" \
        ${envs[@]+"${envs[@]}"} "$PY" "$JAN" ${args[@]+"${args[@]}"} 2>&1); RC=$?
}
exists()     { [ -e "$1" ] || [ -L "$1" ]; }
chk_exists() { if exists "$1"; then ok "$2"; else nope "$2 (missing: $1)"; fi; }
chk_gone()   { if exists "$1"; then nope "$2 (still there: $1)"; else ok "$2"; fi; }
chk_rc()     { if [ "$RC" -eq "$1" ]; then ok "$2"; else nope "$2 (rc=$RC, want $1)"; fi; }
chk_out()    { if printf '%s' "$OUT" | grep -qE -- "$1"; then ok "$2"; else nope "$2 (no match: $1)"; fi; }
chk_noout()  { if printf '%s' "$OUT" | grep -qE -- "$1"; then nope "$2 (unexpected: $1)"; else ok "$2"; fi; }   # always next to a chk_out on the SAME output

# A live headless Chrome helper: the switch the browser hands to EVERY child process, far past column 80.
live_line() {
  printf '%s' "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.58/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=gpu-process --headless --user-data-dir=$1 --use-angle=swiftshader"
}

fixture_basic() {
  reset
  mk <<EOF
P $((2*D)) $AS/scoped_dirOld001
P $((3*D)) $AS/scoped_dir12345_678
P $((2*H)) $AS/scoped_dirYoung01
PR $((5*D)) $AS/scoped_dirDeepFresh@$H
P $((2*D)) $AS/scoped_dirLive001
P $((2*D)) $CA/scoped_dirCacheOld
P $((2*H)) $CA/scoped_dirCacheYoung
EOF
}

# ══ 0. in-process: the cases a subprocess cannot reach (first: cheap, and mutant runs fail fast on it) ═══════════════════════
cat > "$W/unit.py" <<'PYEOF'
import importlib.util, os, re, subprocess, sys, tempfile, types
from unittest import mock
sys.path.insert(0, sys.argv[3]); import mk
spec = importlib.util.spec_from_file_location("chj", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W, now, DAY, bad = sys.argv[3], mk.now, 86400, []
def check(name, cond, extra=""):
    if callable(cond):   # a lambda: an exception becomes a FAIL line, not a crash of the whole block
        try:
            cond = cond()
        except Exception as e:
            cond, extra = False, "raised %r" % (e,)
    print(("ok   - " if cond else "FAIL - ") + name + ("" if cond else "  :: " + str(extra)))
    if not cond:
        bad.append(name)
def profile(root, name, age):
    p = os.path.join(root, name); mk.build("P", age, p); return p
def newroot():
    return tempfile.mkdtemp(prefix="chj-unit.", dir=W)
def fake_run(stdout="", rc=0, exc=None):
    def run(cmd, **kw):
        if exc:
            raise exc
        return subprocess.CompletedProcess(cmd, rc, stdout, "")
    return run
nolive = lambda: (set(), "")

# live_names: a set (answered, even if empty) or None (could not tell) — never the same value for both
with mock.patch.object(m.subprocess, "run", fake_run("a --user-data-dir=/x/scoped_dirAbC1 b\nzzz scoped_dir_9_8\nscoped_dir\n")):
    live, why = m.live_names("ps")
check("live_names: tokens found, a bare 'scoped_dir' is not one", live == {"scoped_dirAbC1", "scoped_dir_9_8"}, live)
with mock.patch.object(m.subprocess, "run", fake_run("/sbin/launchd\n")):
    live, why = m.live_names("ps")
check("live_names: answered, nothing cites a scoped_dir → empty set, not None", live == set(), live)
for label, fr in (("rc != 0", fake_run("x\n", rc=1)), ("empty output", fake_run("")), ("whitespace only", fake_run(" \n\n")),
                  ("timeout", fake_run(exc=subprocess.TimeoutExpired("ps", 30))), ("missing binary", fake_run(exc=FileNotFoundError("ps")))):
    with mock.patch.object(m.subprocess, "run", fr):
        live, why = m.live_names("ps")
    check("live_names: %s → None (could not tell), never an empty set" % label, live is None, (live, why))

# a path that cannot be resolved counts as a real root (dry run, never a guess)
with mock.patch.object(m.os.path, "realpath", side_effect=OSError("boom")):
    check("is_real_target: unresolvable → real", m.is_real_target("/a/c", ["/a/b"]) is True)

# judge_tree: a sub-directory that cannot be listed is unknown, never old
r = newroot(); p = profile(r, "scoped_dirC", 3 * DAY)
real_scandir = os.scandir
def scandir_dies_in_cache(path):
    if path.endswith("Cache"):
        raise PermissionError(13, "denied", path)
    return real_scandir(path)
with mock.patch.object(m.os, "scandir", side_effect=scandir_dies_in_cache):
    v, size, why = m.judge_tree(p, now, DAY, 1000)
check("judge_tree: a sub-directory that cannot be listed → unknown, never old", v == "unknown", (v, why))

# an mtime in the future on the top dir (clock skew) is recent, never old — even when everything inside is old
r = newroot(); p = profile(r, "scoped_dirF", 3 * DAY); os.utime(p, (now + 3600, now + 3600))
v, size, why = m.judge_tree(p, now, DAY, 1000)
check("judge_tree: top dir stamped in the future → fresh", v == "fresh", (v, why))

# sweep_root: the delete phase
real_lstat = os.lstat
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY); b = profile(r, "scoped_dirB", 3 * DAY); seen = []
def lstat_changes_a(p, *x, **k):
    st = real_lstat(p, *x, **k)
    if p == a and not seen:
        seen.append(1)
        return os.stat_result((st.st_mode, st.st_ino, st.st_dev, st.st_nlink, st.st_uid, st.st_gid, st.st_size, st.st_atime, now, st.st_ctime))
    return st
with mock.patch.object(m.os, "lstat", side_effect=lstat_changes_a):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: a dir written between the decision and the delete is kept", os.path.exists(a) and not os.path.exists(b) and "changed=1" in text, (state, text))
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY)
with mock.patch.object(m.shutil, "rmtree", lambda *x, **k: None):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: rmtree that leaves the dir → incomplete, PARTIAL counted, not 'deleted'", state == "incomplete" and "PARTIAL=1" in text and "deleted=0" in text, (state, text))
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY); n = []
def lstat_dies_after(p, *x, **k):
    if p == a:
        n.append(1)
        if len(n) >= 2:
            raise PermissionError(13, "denied", p)
    return real_lstat(p, *x, **k)
with mock.patch.object(m.os, "lstat", side_effect=lstat_dies_after):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: a look after the delete that fails → UNVERIFIED, incomplete", state == "incomplete" and "UNVERIFIED=1" in text, (state, text))
r = newroot(); profile(r, "scoped_dirA", 3 * DAY)
with mock.patch.object(m.os, "scandir", side_effect=PermissionError(13, "denied", r)):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: a root that cannot be listed → unreadable (not 'none-old')", state == "unreadable", (state, text))

# ── exact values, edges and counters (ga-zoij0fp): what the cases above never read ───────────────────────────────────────────────
T = float(int(now))   # whole seconds: an mtime of exactly T - DAY reads back exact, so "age == max_age" is hit on the nose

# the limits: what a positive integer is, and the defaults the docstring documents under Switches (86400 s, 100000 entries)
def cfg(v):
    with mock.patch.dict(os.environ, {"CHJ_T": v}):
        return m.cfg_int("CHJ_T", 7)
got = [cfg(v) for v in ("1", "", "0", "-1", "abc")]
check("cfg_int: 1 is a positive integer, empty → the default, 0 / negative / text → None", got == [1, 7, None, None, None], got)
check("defaults: 24 h and 100000 entries per profile", (m.DEFAULT_MAX_AGE, m.DEFAULT_ENTRY_CAP) == (86400, 100000), (m.DEFAULT_MAX_AGE, m.DEFAULT_ENTRY_CAP))
calls = []
def run_recorder(cmd, **kw):
    calls.append(kw)
    return subprocess.CompletedProcess(cmd, 0, "x\n", "")
with mock.patch.object(m.subprocess, "run", run_recorder):
    m.live_names("ps")
check("live_names: ps is given 30 s to answer", [c.get("timeout") for c in calls] == [30], calls)

# what an entry costs: blocks * 512, or the apparent size where the platform has no st_blocks
check("disk_bytes: st_blocks * 512", lambda: m.disk_bytes(types.SimpleNamespace(st_blocks=3, st_size=1)) == 1536)
check("disk_bytes: no st_blocks → the apparent size", lambda: m.disk_bytes(types.SimpleNamespace(st_size=1234)) == 1234)

# judge_tree: a path that cannot even be stat'ed is unknown with size 0; then the edges (age == max_age is still fresh)
v, size, why = m.judge_tree(os.path.join(newroot(), "scoped_dirGone"), now, DAY, 1000)
check("judge_tree: a path that cannot be stat'ed → unknown, size 0", (v, size) == ("unknown", 0) and "cannot stat" in why, (v, size, why))
r = newroot(); p = profile(r, "scoped_dirT", 3 * DAY)
os.utime(p, (T - DAY - 1, T - DAY - 1)); v_over = m.judge_tree(p, T, DAY, 1000)[0]
os.utime(p, (T - DAY, T - DAY)); v_edge, s_edge, _ = m.judge_tree(p, T, DAY, 1000)
check("judge_tree: a top dir DAY+1 s old is old, one written exactly DAY s ago is still fresh (size 0)", (v_over, v_edge, s_edge) == ("old", "fresh", 0), (v_over, v_edge, s_edge))
p = profile(r, "scoped_dirC", 3 * DAY); f = os.path.join(p, "Local State")
os.utime(f, (T - DAY - 1, T - DAY - 1)); c_over = m.judge_tree(p, T, DAY, 1000)[0]
os.utime(f, (T - DAY, T - DAY)); c_edge = m.judge_tree(p, T, DAY, 1000)[0]
check("judge_tree: an entry DAY+1 s old is old, one written exactly DAY s ago is fresh", (c_over, c_edge) == ("old", "fresh"), (c_over, c_edge))
# the entry cap counts every entry once: exactly the cap is judged, one over is unknown; and the size is exact
p = profile(r, "scoped_dirN", 3 * DAY)
# vazio → n/a (the tree was just built); falhou/ilegível → an entry lstat cannot read raises here and stops unit.py (a visible red, never a pass)
walked = [os.lstat(os.path.join(dp, nm)) for dp, dns, fns in os.walk(p) for nm in dns + fns]
v_ok, v_short = m.judge_tree(p, T, DAY, len(walked))[0], m.judge_tree(p, T, DAY, len(walked) - 1)[0]
check("judge_tree: exactly entry_cap entries are judged (old), one over the cap is unknown", (v_ok, v_short) == ("old", "unknown"), (len(walked), v_ok, v_short))
v, size, why = m.judge_tree(p, T, DAY, 1000)
check("judge_tree: an old profile's size is what its entries cost on disk (blocks * 512), exactly", (v, size) == ("old", sum(st.st_blocks * 512 for st in walked)) and size > 0, (v, size))
# a symlink inside a profile is judged by itself, never followed: what it points at is brand new here
q = profile(r, "scoped_dirS", 3 * DAY)
away = os.path.join(newroot(), "away"); os.makedirs(away); open(os.path.join(away, "recent"), "w").write("x")
cache = os.path.join(q, "Default", "Cache")
mk.build("L", 3 * DAY, "%s=>%s" % (os.path.join(cache, "link"), away))
os.utime(cache, (now - 3 * DAY, now - 3 * DAY))   # the new link moved the directory's own mtime
v, size, why = m.judge_tree(q, T, DAY, 1000)
check("judge_tree: a symlink inside a profile is not followed (what it points at is brand new)", v == "old", (v, why))

# sweep_root: the counters, and the states they decide
r = newroot(); mk.build("F", 3 * DAY, os.path.join(r, "scoped_dirFILE"))
state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: a plain file named scoped_dir… is counted nonregular, not a profile", state == "none-old" and "nonregular=1" in text, (state, text))
class BadEntry:   # a DirEntry whose stat fails (the entry went away or is not ours); a real one needs a listable but not searchable directory, which root reads through
    name, path = "scoped_dirBad", "/nonexistent/scoped_dirBad"
    def is_symlink(self): return False
    def is_dir(self, follow_symlinks=True): return True
    def stat(self, follow_symlinks=True): raise PermissionError(13, "denied", self.path)
class Listing:
    def __init__(self, entries): self.entries = entries
    def __enter__(self): return iter(self.entries)
    def __exit__(self, *exc): return False
r = newroot()
with mock.patch.object(m.os, "scandir", lambda path: Listing([BadEntry()])):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: an entry whose stat fails is counted unreadable, the root is incomplete (never none-old)", state == "incomplete" and "unreadable=1" in text, (state, text))
r = newroot()
for nm in ("scoped_dirA", "scoped_dirB", "scoped_dirC"):
    profile(r, nm, 3 * DAY)
state, text = m.sweep_root(r, now, DAY, False, nolive, 2)
check("sweep_root: three profiles over the cap → incomplete, unjudged=3, the note names two of them", state == "incomplete" and "unjudged=3" in text and "; unjudged: " in text and text.count(" | ") == 1, (state, text))
def fat(root, name, extra):   # a profile with 5 + extra entries, every mtime still 3 days old
    fp = profile(root, name, 3 * DAY)
    fcache = os.path.join(fp, "Default", "Cache")
    for i in range(extra):
        mk.build("F", 3 * DAY, os.path.join(fcache, "more%d" % i))
    os.utime(fcache, (now - 3 * DAY, now - 3 * DAY))   # the new files moved the directory's own mtime
    return fp
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY); b = fat(r, "scoped_dirB", 3)   # 5 and 8 entries, the cap is 6
state, text = m.sweep_root(r, now, DAY, False, nolive, 6)
check("sweep_root: one profile deleted, one over the cap → incomplete (unjudged alone is enough), deleted=1 unjudged=1", state == "incomplete" and "deleted=1" in text and "unjudged=1" in text and not os.path.exists(a) and os.path.exists(b), (state, text))
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY); b = fat(r, "scoped_dirB", 3)
state, text = m.sweep_root(r, now, DAY, False, lambda: ({"scoped_dirA"}, ""), 6)
check("sweep_root: the only old profile is cited by a live process, another is over the cap → incomplete, not live", state == "incomplete" and "every one of the 1 old" in text and os.path.exists(a), (state, text))
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY); first = []
def lstat_gone_first(path, *x, **k):
    if path == a and not first:
        first.append(1)
        raise FileNotFoundError(2, "gone", path)
    return real_lstat(path, *x, **k)
with mock.patch.object(m.os, "lstat", side_effect=lstat_gone_first):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: a profile someone else removed first is counted gone, the root is not incomplete", state == "pruned" and "gone=1" in text and "deleted=0" in text, (state, text))
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY); first = []
def lstat_denied_first(path, *x, **k):
    if path == a and not first:
        first.append(1)
        raise PermissionError(13, "denied", path)
    return real_lstat(path, *x, **k)
with mock.patch.object(m.os, "lstat", side_effect=lstat_denied_first):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: a look before the delete that fails → FAILED=1, the profile is kept, the root is incomplete", state == "incomplete" and "FAILED=1" in text and os.path.exists(a), (state, text))
r = newroot(); a = profile(r, "scoped_dirA", 3 * DAY)
# vazio → n/a (the tree was just built); falhou/ilegível → an entry lstat cannot read raises here and stops unit.py (a visible red, never a pass)
want = sum(os.lstat(os.path.join(dp, nm)).st_blocks * 512 for dp, dns, fns in os.walk(a) for nm in dns + fns)
with mock.patch.object(m, "human", lambda nbytes: "<%d>" % nbytes):
    state, text = m.sweep_root(r, now, DAY, False, nolive, 1000)
check("sweep_root: the freed size is exactly what the deleted profile's entries cost on disk", state == "pruned" and want > 0 and "deleted=1 (<%d>)" % want in text, (state, text, want))
r = newroot()
for nm in ("scoped_dirA", "scoped_dirB", "scoped_dirC", "scoped_dirD"):
    profile(r, nm, 3 * DAY)
state, text = m.sweep_root(r, now, DAY, True, nolive, 1000)
check("sweep_root dry run: says 4, and 'e.g.' names three profiles by name, not by path", state == "dry-run" and "would delete 4 dir" in text and re.search(r"e\.g\. (scoped_dir[A-D] ){2}scoped_dir[A-D]$", text) is not None, (state, text))

print("unit: %d failed" % len(bad))
sys.exit(1 if bad else 0)
PYEOF
UOUT=$("$PY" "$W/unit.py" "$JAN" "$W/ps" "$W" 2>&1); URC=$?
printf '%s\n' "$UOUT" | grep -E '^(ok|FAIL)'
UF=$(printf '%s\n' "$UOUT" | grep -c '^FAIL - ')
PASS=$((PASS+$(printf '%s\n' "$UOUT" | grep -c '^ok   - '))); FAIL=$((FAIL+UF))
if [ "$URC" -ne 0 ] && [ "$UF" -eq 0 ]; then FAIL=$((FAIL+1)); printf 'FAIL - unit.py crashed (rc=%s)\n' "$URC"; printf '%s\n' "$UOUT" | tail -8 | sed 's/^/        | /'; fi
[ "${CHJ_FAILFAST:-0}" = "1" ] && [ "$FAIL" -ne 0 ] && exit 1

# ══ 1. the sweep, and the live process ═════════════════════════════════════════════════════════════════════════════════════
fixture_basic
run_jan "STUB_PS_EXTRA=$(live_line "$AS/scoped_dirLive001")"
chk_rc 0 "sweep: exit 0"
chk_gone   "$AS/scoped_dirOld001"      "sweep: old profile in Application Support deleted"
chk_gone   "$AS/scoped_dir12345_678"   "sweep: old profile with the older name shape (scoped_dir<pid>_<n>) deleted"
chk_gone   "$CA/scoped_dirCacheOld"    "sweep: old profile in the Caches twin deleted"
chk_exists "$AS/scoped_dirYoung01"     "sweep: profile younger than 24 h kept"
chk_exists "$AS/scoped_dirDeepFresh"   "sweep: old top dir with a file written 1 h ago deep inside kept"
chk_exists "$AS/scoped_dirLive001"     "sweep: old profile a live process cites (past column 80) kept — needs ps -w -w"
chk_out "Application Support/Google/Chrome-headless: pruned - deleted=2 .*kept_fresh=2 kept_live=1" "sweep: the line says 2 deleted, 2 fresh, 1 live"
chk_noout "PROD != 1" "sweep: an ordinary run does not say its target is the real root (same output as the line above)"
run_jan "STUB_PS_EXTRA=$(live_line "$AS/scoped_dirLive001")"
chk_out "Application Support/Google/Chrome-headless: live - " "second run: the only old profile left is cited by a live process, so the state says live"
chk_exists "$AS/scoped_dirLive001" "second run: the live one is still there"
run_jan
chk_gone "$AS/scoped_dirLive001" "once no process cites it, the old profile goes"
chk_exists "$AS/scoped_dirYoung01" "…and the young one is still kept"

# the Chrome for Testing twin is swept, the NORMAL Chrome dirs are not
reset
mk <<EOF
P $((2*D)) $ASX/scoped_dirCft001
P $((2*D)) $HOME/Library/Application Support/Google/Chrome/scoped_dirNotOurs
EOF
run_jan
chk_gone   "$ASX/scoped_dirCft001" "Chrome for Testing headless root is swept"
chk_exists "$HOME/Library/Application Support/Google/Chrome/scoped_dirNotOurs" "a scoped_dir inside the NORMAL Chrome profile dir is never touched"

# a clock that ran ahead: an mtime in the future counts as recent, never as old
reset
mk <<EOF
P -7200 $AS/scoped_dirFuture01
P $((2*D)) $AS/scoped_dirOld001
EOF
run_jan
chk_exists "$AS/scoped_dirFuture01" "a profile stamped in the future (clock skew) is kept, not read as old"
chk_gone "$AS/scoped_dirOld001" "…while the genuinely old one goes"

# ══ 2. never touched ═══════════════════════════════════════════════════════════════════════════════════════════════════════
reset
mk <<EOF
P $((3*D)) $AS/scoped_dir
P $((3*D)) $AS/xscoped_dirXYZ
P $((3*D)) $AS/scoped_dir with space
F $((3*D)) $AS/scoped_dirFILE
P $((3*D)) $W/outside/realprofile
L $((3*D)) $AS/scoped_dirLINK=>$W/outside/realprofile
P $((3*D)) $AS/scoped_dirReal001
EOF
run_jan
chk_gone   "$AS/scoped_dirReal001"     "look-alikes: the genuine old one still goes (the run did act)"
chk_rc 0 "look-alikes: exit 0 (a symlink that was followed would end in a failed delete, exit 1)"
chk_exists "$AS/scoped_dir"            "look-alikes: bare 'scoped_dir' kept"
chk_exists "$AS/xscoped_dirXYZ"        "look-alikes: xscoped_dir… kept"
chk_exists "$AS/scoped_dir with space" "look-alikes: a name with a space kept"
chk_exists "$AS/scoped_dirFILE"        "a regular FILE named scoped_dir… is kept"
chk_exists "$AS/scoped_dirLINK"        "a symlink named scoped_dir… is kept"
chk_exists "$W/outside/realprofile/Local State" "…and what it points at is untouched"

# a root that is itself a symlink is not followed
reset
mk <<EOF
P $((3*D)) $W/elsewhere/scoped_dirViaLink
P $((3*D)) $CA/scoped_dirCacheOld
EOF
mkdir -p "$(dirname "$AS")"; ln -s "$W/elsewhere" "$AS"
run_jan
chk_exists "$W/elsewhere/scoped_dirViaLink" "a root that is a symlink is not followed"
chk_out "not-a-dir" "a symlinked root is reported, not silently skipped"
chk_rc 1 "a symlinked root: INCOMPLETE, exit 1"
chk_gone "$CA/scoped_dirCacheOld" "…and the other root is still swept"

# a root that is a plain file is "not-a-dir" as well: reported as such, not read as a directory that cannot be listed
reset
: > "$W/rootfile"
run_jan CHROME_HEADLESS_JANITOR_ROOTS="$W/rootfile"
chk_out "rootfile: not-a-dir" "a root that is a regular file: not-a-dir"
chk_rc 1 "a root that is a regular file: INCOMPLETE, exit 1"

# ══ 3. reads that fail land in the inert state ════════════════════════════════════════════════════════════════════════════
fixture_basic
run_jan STUB_PS_MODE=rc1
chk_rc 1 "ps exits 1: INCOMPLETE, exit 1"
chk_exists "$AS/scoped_dirOld001" "ps exits 1: old profile kept"
run_jan STUB_PS_MODE=empty
chk_rc 1 "ps prints nothing: INCOMPLETE, exit 1"
chk_exists "$AS/scoped_dirOld001" "ps prints nothing: old profile kept (a live mini always has processes)"
reset
mk <<EOF
P $((2*H)) $AS/scoped_dirYoung01
EOF
run_jan STUB_PS_MODE=rc1
chk_rc 0 "only fresh profiles and a broken ps: nothing to decide, exit 0"
reset
run_jan
chk_rc 0 "no roots at all: nothing to clean, exit 0"

# ══ 4. modes and configuration ════════════════════════════════════════════════════════════════════════════════════════════
fixture_basic
run_jan -- --dry-run
chk_exists "$AS/scoped_dirOld001" "dry run (flag): nothing deleted"
chk_out "DRY-RUN would delete 3 dir" "dry run: says what it would delete (Live001 is not cited here, so 3 in Application Support)"
run_jan CHROME_HEADLESS_JANITOR_ENABLED=0
chk_exists "$AS/scoped_dirOld001" "kill switch: nothing deleted"
chk_rc 0 "kill switch: exit 0 (a no-op is not a failure)"
run_jan CHROME_HEADLESS_JANITOR_REAL_ROOTS="$AS:$CA"
chk_exists "$AS/scoped_dirOld001" "sentinel: real root without PROD=1 → nothing deleted"
chk_out "PROD != 1: dry run" "sentinel: said why"
run_jan CHROME_HEADLESS_JANITOR_REAL_ROOTS="$AS:$CA" CHROME_HEADLESS_JANITOR_PROD=1
chk_gone "$AS/scoped_dirOld001" "sentinel: PROD=1 → deleted"
# limits that cannot be read are never guessed
for bad in abc 0; do
  fixture_basic
  run_jan CHROME_HEADLESS_JANITOR_MAX_AGE_SECS=$bad
  chk_rc 1 "MAX_AGE_SECS=$bad: exit 1"
  chk_exists "$AS/scoped_dirOld001" "MAX_AGE_SECS=$bad: nothing deleted (a guessed limit could delete more than meant)"
  chk_out "CHROME_HEADLESS_JANITOR_MAX_AGE_SECS='$bad' is not a positive integer" "MAX_AGE_SECS=$bad: names the variable"
  chk_out "summary: bad limit, nothing swept" "MAX_AGE_SECS=$bad: the run stops before it sweeps anything"
done
fixture_basic
run_jan CHROME_HEADLESS_JANITOR_ENTRY_CAP=abc
chk_rc 1 "ENTRY_CAP=abc: exit 1"
chk_out "summary: bad limit, nothing swept" "ENTRY_CAP=abc: one bad limit is enough to stop before sweeping"
chk_exists "$AS/scoped_dirOld001" "ENTRY_CAP=abc: nothing deleted"
run_jan CHROME_HEADLESS_JANITOR_ENTRY_CAP=2
chk_exists "$AS/scoped_dirOld001" "ENTRY_CAP=2: a profile with more entries than the cap is kept"
chk_out "unjudged=" "ENTRY_CAP=2: counted as unjudged"
chk_rc 1 "ENTRY_CAP=2: INCOMPLETE, exit 1"
# the age limit moves the line in both directions (Young01 is 2 h old, DeepFresh has a file 1 h old, Old001 is 2 d old)
fixture_basic
run_jan CHROME_HEADLESS_JANITOR_MAX_AGE_SECS=$H "STUB_PS_EXTRA=$(live_line "$AS/scoped_dirLive001")"
chk_gone "$AS/scoped_dirYoung01" "MAX_AGE_SECS=1h: the 2 h old profile is now old enough"
chk_exists "$AS/scoped_dirLive001" "MAX_AGE_SECS=1h: a profile a live process cites is still kept"
# one instance at a time
fixture_basic
"$PY" -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_CREAT|os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2],"w").write("held")
time.sleep(30)' "$LOCK" "$W/lock.held" &
HOLDER=$!
i=0; while [ ! -e "$W/lock.held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
run_jan
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
chk_rc 0 "lock held by another run: exit 0"
chk_out "another run holds the lock" "lock held: says so"
chk_exists "$AS/scoped_dirOld001" "lock held: nothing deleted"
run_jan
chk_gone "$AS/scoped_dirOld001" "lock free again: the run goes ahead"
# a lock that cannot be taken for any other reason: nothing done, and it says so (never a silent exit 0)
fixture_basic
: > "$W/afile"
run_jan CHROME_HEADLESS_JANITOR_LOCK="$W/afile/sub/lock"
chk_rc 1 "lock that cannot be taken: exit 1"
chk_exists "$AS/scoped_dirOld001" "lock that cannot be taken: nothing deleted"
# -h and --help print the docstring and stop, each on its own: exit 0, nothing swept
fixture_basic
for flag in --help -h; do
  run_jan -- "$flag"
  chk_rc 0 "$flag: exit 0"
  chk_out "## Switches" "$flag: prints the docstring"
  chk_exists "$AS/scoped_dirOld001" "$flag: nothing swept"
done
# HOME empty: the default roots come from expanduser("~") = "/", never from the working directory (a dry run, so nothing
# can be deleted wherever it points)
reset
mkdir -p "$W/cwdfix"
mk <<EOF
P $((2*D)) $W/cwdfix/Library/Application Support/Google/Chrome-headless/scoped_dirRel001
EOF
RUN_CWD="$W/cwdfix"; run_jan HOME= CHROME_HEADLESS_JANITOR_DRY_RUN=1; RUN_CWD=""
chk_out "^chrome-headless-janitor: /Library/Application Support/Google/Chrome-headless: " "HOME empty: the default roots are absolute (under /)"
chk_noout "DRY-RUN would delete" "HOME empty: nothing under the working directory was looked at (same output as the line above)"
# the log goes out line by line: a run killed half way (the stub SIGKILLs it while it asks ps) has already said what it did
fixture_basic
run_jan "CHROME_HEADLESS_JANITOR_ROOTS=$W/noroot:$AS" STUB_PS_MODE=killparent
chk_rc 137 "a run killed while it asks ps: exit 137 (SIGKILL)"
chk_out "noroot: absent" "a run killed half way: the line of the root it had finished is already out (flush)"
chk_exists "$AS/scoped_dirOld001" "a run killed while it asks ps: nothing deleted"

# Declared equivalents (the registry of the lastro: one line, ids of 10 hex, a reason of 12 or more characters)
# EQUIVALENT 0ca1f660c1: L209 `e.is_dir(follow_symlinks=False)` -> `True`: `e.is_symlink()` is the first operand of the `or` and is True for every link, so only non-links reach is_dir, and for a non-link both forms answer from the same cached entry
# EQUIVALENT d932c2e178: L212 `e.stat(follow_symlinks=False)` -> `True`: the lines above `continue` on every symlink, so this stat only ever sees a real directory, and the inode and mtime it reads are the same either way
# EQUIVALENT 4533d154f5: L379 `sys.argv[1:]` -> `[0:]`: main() only asks whether "-h", "--help" or "--dry-run" is among the arguments, and the script path is none of them

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# ══ 5. mutants: each must fail this battery ═══════════════════════════════════════════════════════════════════════════════
if [ "${CHJ_MUTANTS:-0}" = "1" ] && [ "$FAIL" -eq 0 ]; then
  cat > "$W/mutate.py" <<'PYEOF'
import sys
name, src, dst = sys.argv[1:4]
s = open(src).read()
AGE = '    if now - top_stat.st_mtime <= max_age:\n        return "fresh", 0,'
NAME = 'NAME_RE = re.compile(r"^scoped_dir[A-Za-z0-9_]+$")'
M = {
 "age-inverted": (AGE, AGE.replace("<=", ">")),
 "future-mtime-as-old": (AGE, AGE.replace("if now", "if 0 <= now")),
 "tree-ignored": ('                    if now - st.st_mtime <= max_age:\n                        return "fresh", size,',
                  '                    if False:\n                        return "fresh", size,'),
 "unreadable-subtree-as-old": ('        except OSError as err:\n            return "unknown", size, "cannot read %s: %s" % (d, err)',
                               '        except OSError as err:\n            continue'),
 "entry-cap-as-old": ('                        return "unknown", size, "more than %d entries" % entry_cap', '                        return "old", size, ""'),
 "ps-failure-as-no-process": ('        return None, "ps rc=%s, %d byte(s) of output" % (r.returncode, len(r.stdout))', '        return set(), ""'),
 "ps-missing-as-no-process": ('        return None, "ps failed: %s" % e', '        return set(), ""'),
 "live-ignored": ('    todo = [o for o in old if o[1] not in live]', '    todo = list(old)'),
 "ps-not-wide": ('[ps_bin, "-A", "-w", "-w", "-o", "command="]', '[ps_bin, "-A", "-o", "command="]'),
 "ps-always-asked": ('    if not old:\n        tail = ', '    if False:\n        tail = '),
 "name-prefix-only": (NAME, NAME.replace('[A-Za-z0-9_]+$', '')),
 "name-bare-allowed": (NAME, NAME.replace("+$", "*$")),
 "symlink-followed": ('            if e.is_symlink() or not e.is_dir(follow_symlinks=False):', '            if not e.is_dir():'),
 "root-symlink-followed": ('        rst = os.lstat(root)\n', '        rst = os.stat(root)\n'),
 "wrong-root": ('    "Library/Application Support/Google/Chrome-headless",', '    "Library/Application Support/Google/Chrome",'),
 "sentinel-dropped": ('        dry = dry_all or (is_real_target(root, real_roots) and not prod)', '        dry = dry_all'),
 "dryrun-deletes": ('    if dry:\n        return "dry-run"', '    if False:\n        return "dry-run"'),
 "killswitch-ignored": ('    if env("CHROME_HEADLESS_JANITOR_ENABLED", "1") != "1":', '    if False:'),
 "lock-ignored": ('    if other:\n        log("another run holds the lock: exiting")', '    if False:\n        log("another run holds the lock: exiting")'),
 "lock-failure-as-ok": ('        log("cannot take the lock %s: %s - nothing done" % (lock_path, e))\n        return 1', '        log("cannot take the lock %s: %s - nothing done" % (lock_path, e))\n        return 0'),
 "bad-limit-defaulted": ('''    log("%s='%s' is not a positive integer" % (name, raw))\n    return None''', '''    log("%s='%s' is not a positive integer" % (name, raw))\n    return default'''),
 "unlistable-as-empty": ('        return "unreadable", "cannot list %s: %s" % (root, e)', '        return "none-old", "cannot list %s: %s" % (root, e)'),
 "recheck-dropped": ('        if st2.st_ino != st.st_ino or st2.st_mtime != st.st_mtime:', '        if False:'),
 "partial-as-deleted": ('        else:\n            partial += 1\n', '        else:\n            deleted += 1\n'),
 "exit-code-ignored": ('        if state not in OK_STATES:\n            rc = 1', '        if False:\n            rc = 1'),
}
old, new = M[name]
assert s.count(old) == 1, "mutation %s: pattern found %d times" % (name, s.count(old))
open(dst, "w").write(s.replace(old, new))
PYEOF
  SURV=0
  for mut in age-inverted future-mtime-as-old tree-ignored unreadable-subtree-as-old entry-cap-as-old \
             ps-failure-as-no-process ps-missing-as-no-process live-ignored ps-not-wide ps-always-asked \
             name-prefix-only name-bare-allowed symlink-followed root-symlink-followed wrong-root \
             sentinel-dropped dryrun-deletes killswitch-ignored lock-ignored lock-failure-as-ok bad-limit-defaulted \
             unlistable-as-empty recheck-dropped partial-as-deleted exit-code-ignored; do
    "$PY" "$W/mutate.py" "$mut" "$JAN" "$W/mutant-$mut.py" || { echo "FAIL - mutant $mut: could not be built"; SURV=$((SURV+1)); continue; }
    # A mutant that does not even parse would "fail" the battery for the wrong reason: refuse it.
    "$PY" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$W/mutant-$mut.py" 2>/dev/null \
      || { echo "FAIL - mutant $mut: does not parse, proves nothing"; SURV=$((SURV+1)); continue; }
    MOUT=$(CHROME_HEADLESS_JANITOR_PATH="$W/mutant-$mut.py" CHJ_MUTANTS=0 CHJ_FAILFAST=1 bash "$0" 2>&1); MRC=$?
    FIRST=$(printf '%s\n' "$MOUT" | grep -m1 '^FAIL - ')
    # Killed = the battery failed AND said which assertion caught it (a FATAL or a crash is not a kill).
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
