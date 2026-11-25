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
PASS=0; FAIL=0; OUT=""; RC=0
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
# run_jan [VAR=val ...] [-- args]   → OUT, RC. Every path is a fixture; nothing real is reachable.
run_jan() {
  local envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  OUT=$(env CHROME_HEADLESS_JANITOR_LOCK="$LOCK" CHROME_HEADLESS_JANITOR_PS_BIN="$W/ps" \
        ${envs[@]+"${envs[@]}"} "$PY" "$JAN" ${args[@]+"${args[@]}"} 2>&1); RC=$?
}
exists()     { [ -e "$1" ] || [ -L "$1" ]; }
chk_exists() { if exists "$1"; then ok "$2"; else nope "$2 (missing: $1)"; fi; }
chk_gone()   { if exists "$1"; then nope "$2 (still there: $1)"; else ok "$2"; fi; }
chk_rc()     { if [ "$RC" -eq "$1" ]; then ok "$2"; else nope "$2 (rc=$RC, want $1)"; fi; }
chk_out()    { if printf '%s' "$OUT" | grep -qE -- "$1"; then ok "$2"; else nope "$2 (no match: $1)"; fi; }

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
import importlib.util, os, subprocess, sys, tempfile
from unittest import mock
sys.path.insert(0, sys.argv[3]); import mk
spec = importlib.util.spec_from_file_location("chj", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
W, now, DAY, bad = sys.argv[3], mk.now, 86400, []
def check(name, cond, extra=""):
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
done
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
