#!/usr/bin/env bash
# daemon-import-smoke.selftest.sh — ga-n3czl1.
#
# THE DEFECT (06/10, wa-acp18q): a route module gained `from lib import dispensada`;
# classification_dashboard launches with only lib/ and daemons/ on sys.path, so it
# died at import and crash-looped, while the tests (pytest, run from the repo root)
# and the post-merge refresh both said fine. daemon-import-smoke.py rebuilds the
# daemon's own launch and executes the entrypoint's import phase.
#
# Every guard in the helper has a case here that FAILS without it:
#   T2/T3   the daemon's sys.path, not the cwd's and not the CALLER's PYTHONPATH
#   T5      a bash wrapper is READ, never RUN (the real one blocks ~180 s on a vault)
#   T18     the entrypoint module is registered in sys.modules (Flask(__name__) finds
#           its root there; unregistered, it silently gets "/") and its __main__
#           block does not run
#   T20     a crash of the helper itself is UNKNOWN (an uncaught python error exits
#           1, which is the FAIL code)
#   T22-T27 (ga-u6ueg0q) the numbers a reader of the output depends on: the default
#           timeout and its precedence, the help exit, the width of each cut-off line,
#           the tail of a child that left no result, and the PATH search's test for an
#           executable FILE
# and the three-state contract: only ImportError/SyntaxError is FAIL; anything the
# helper could not run or that is not an import problem is UNKNOWN, never PASS.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELF_DIR/daemon-import-smoke.py"
PY="$(command -v python3)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-import-smoke-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "== daemon-import-smoke.selftest (ga-n3czl1) =="

# mk_plist <out> <workdir|-> <env-json> <program-argument...>
mk_plist() {
  python3 -I - "$@" <<'PYEOF'
import json, plistlib, sys
out, wd, envj = sys.argv[1:4]
d = {"Label": "test.smoke", "ProgramArguments": sys.argv[4:]}
if wd != "-":
    d["WorkingDirectory"] = wd
e = json.loads(envj)
if e:
    d["EnvironmentVariables"] = e
with open(out, "wb") as f:
    plistlib.dump(d, f)
PYEOF
}

# mk_tree <dir> — the incident's shape: lib/ holds a module, the daemon puts lib/ and
# daemons/ on its sys.path (NOT the root), a route does `from lib import dispensada`.
# `lib` has no __init__.py: from the repo root it is a namespace package, which is why
# pytest passes; under the daemon only lib/'s CONTENTS are importable.
mk_tree() {
  local r="$1"
  mkdir -p "$r/lib" "$r/daemons/routes" "$r/venv/bin" "$r/logs"
  ln -sfn "$PY" "$r/venv/bin/python3"
  echo 'FLAG = "dispensada"' > "$r/lib/dispensada.py"
  : > "$r/daemons/routes/__init__.py"
  cat > "$r/daemons/routes/cls_contacts.py" <<'EOF'
from lib import dispensada
X = dispensada.FLAG
EOF
  cat > "$r/daemons/dash.py" <<'EOF'
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "lib"))
sys.path.insert(0, str(Path(__file__).parent))
# Flask(__name__) resolves its root through sys.modules[__name__] — it must be registered.
ROOT = os.path.dirname(sys.modules[__name__].__file__)
if os.environ.get("SMOKE_ENVFILE"):
    open(os.environ["SMOKE_ENVFILE"], "w").write(os.environ.get("DAEMON_IMPORT_SMOKE", "<unset>"))
from routes import cls_contacts
if __name__ == "__main__":
    open(os.environ.get("SMOKE_MAINFILE", "/dev/null"), "w").write("main ran")
EOF
}

# mk_wrapper <path> <basedir> — the real classification-dashboard-wrapper.sh's shape:
# BASEDIR, cd, exports, a blocking secret fetch (must never run), a nested override
# branch, and a final `exec <venv python> <script>`.
mk_wrapper() {
  cat > "$1" <<EOF
#!/bin/bash
set -e
BASEDIR="$2"
cd "\$BASEDIR"
export WA_API_REQUIRE_AUTH="1"
SECRET_BIN="\${WA_DASHBOARD_SECRET_BIN:-/nonexistent/secret}"
touch "$TMP_ROOT/wrapper-ran-top-level"
ADMIN_TOKEN="\$(touch "$TMP_ROOT/wrapper-ran-subshell"; "\$SECRET_BIN" token 2>/dev/null || true)"
attempts=0
while :; do
    attempts=\$((attempts + 1))
    touch "$TMP_ROOT/wrapper-ran-loop"
    [ "\$attempts" -ge 1 ] && break
done
if [ -n "\${OVERRIDE:-}" ]; then
    exec "\$OVERRIDE"
fi
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/dash.py"
EOF
}

# run_smoke <plist> [extra args...] -> sets OUT and RC; the caller env is CLEAN unless
# the test sets PYTHONPATH on the call.
run_smoke() { OUT="$(python3 -I "$HELPER" "$@" 2>/dev/null)"; RC=$?; }
verdict() { printf '%s\n' "$OUT" | sed -n 's/^SMOKE=//p' | head -1; }
reason()  { printf '%s\n' "$OUT" | sed -n 's/^SMOKE_REASON=//p' | head -1; }

# ── T1: a clean daemon -> PASS ────────────────────────────────────────────────
R="$TMP_ROOT/t1"; mk_tree "$R"; echo 'X = 1' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t1.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t1.plist"
[ "$(verdict)" = "PASS" ] && [ "$RC" -eq 0 ] && ok "T1 clean daemon: PASS rc=0" || bad "T1 got verdict=$(verdict) rc=$RC out=[$OUT]"

# ── T2: THE INCIDENT, direct launch, cwd = repo root -> FAIL ──────────────────
# cwd is the repo root on purpose: `python script.py` does NOT put the cwd on sys.path,
# `python -c` does. A smoke that leaked the cwd would resolve `lib` and PASS here.
R="$TMP_ROOT/t2"; mk_tree "$R"
mk_plist "$TMP_ROOT/t2.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t2.plist"
[ "$(verdict)" = "FAIL" ] && [ "$RC" -eq 1 ] && ok "T2 incident class: FAIL rc=1" || bad "T2 got verdict=$(verdict) rc=$RC out=[$OUT]"
has "$(reason)" "ModuleNotFoundError: No module named 'lib'" && ok "T2 reason names the missing module" || bad "T2 reason: $(reason)"
has "$OUT" "cls_contacts.py" && ok "T2 detail points at the offending route" || bad "T2 detail lacks the route: $OUT"

# ── T3: the CALLER's PYTHONPATH must not rescue it ────────────────────────────
# Called WITHOUT -I on purpose: a dispatcher/launchd job can export PYTHONPATH, and the
# CHILD must not inherit it from the caller.
OUT="$(PYTHONPATH="$R" python3 "$HELPER" "$TMP_ROOT/t2.plist" 2>/dev/null)"; RC=$?
[ "$(verdict)" = "FAIL" ] && ok "T3 caller PYTHONPATH=<root> does not mask the failure" || bad "T3 got verdict=$(verdict) rc=$RC"

# ── T4: the hotfix (root appended LAST to sys.path) -> PASS ───────────────────
R="$TMP_ROOT/t4"; mk_tree "$R"
python3 -I - "$R/daemons/dash.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
a = "from routes import cls_contacts\n"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, "sys.path.append(str(Path(__file__).resolve().parent.parent))  # the wa-acp18q hotfix\n" + a))
PYEOF
mk_plist "$TMP_ROOT/t4.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t4.plist"
[ "$(verdict)" = "PASS" ] && ok "T4 hotfixed daemon: PASS" || bad "T4 got verdict=$(verdict) out=[$OUT]"

# ── T5: THE REAL SHAPE — bash wrapper -> FAIL, and the wrapper is never run ───
R="$TMP_ROOT/t5"; mk_tree "$R"; mk_wrapper "$R/wrapper.sh" "$R"
mk_plist "$TMP_ROOT/t5.plist" "$R" '{"PATH":"/usr/bin:/bin"}' /bin/bash "$R/wrapper.sh"
rm -f "$TMP_ROOT"/wrapper-ran-*
run_smoke "$TMP_ROOT/t5.plist"
[ "$(verdict)" = "FAIL" ] && has "$(reason)" "No module named 'lib'" && ok "T5 wrapper-form incident: FAIL" || bad "T5 got verdict=$(verdict) out=[$OUT]"
ran="$(ls "$TMP_ROOT"/wrapper-ran-* 2>/dev/null | tr '\n' ' ')"
[ -z "$ran" ] && ok "T5 the wrapper was READ, never run (no top-level / subshell / loop side effect)" || bad "T5 wrapper executed: $ran"

# ── T6: wrapper form, healthy -> PASS ─────────────────────────────────────────
R="$TMP_ROOT/t6"; mk_tree "$R"; echo 'X = 1' > "$R/daemons/routes/cls_contacts.py"; mk_wrapper "$R/wrapper.sh" "$R"
mk_plist "$TMP_ROOT/t6.plist" "$R" '{}' /bin/bash "$R/wrapper.sh"
run_smoke "$TMP_ROOT/t6.plist"
[ "$(verdict)" = "PASS" ] && ok "T6 healthy wrapper-form daemon: PASS" || bad "T6 got verdict=$(verdict) out=[$OUT]"

# ── T7: a SyntaxError in an imported module -> FAIL ───────────────────────────
R="$TMP_ROOT/t7"; mk_tree "$R"; printf 'def broken(:\n  pass\n' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t7.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t7.plist"
[ "$(verdict)" = "FAIL" ] && has "$(reason)" "SyntaxError" && ok "T7 SyntaxError: FAIL" || bad "T7 got verdict=$(verdict) reason=$(reason)"

# ── T8/T9: NOT an import problem -> UNKNOWN, never FAIL, never PASS ───────────
R="$TMP_ROOT/t8"; mk_tree "$R"; echo 'raise RuntimeError("db is down")' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t8.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t8.plist"
[ "$(verdict)" = "UNKNOWN" ] && [ "$RC" -eq 2 ] && has "$(reason)" "RuntimeError" && ok "T8 RuntimeError at import: UNKNOWN rc=2 (environment-shaped, not a verdict)" || bad "T8 got verdict=$(verdict) rc=$RC reason=$(reason)"
R="$TMP_ROOT/t9"; mk_tree "$R"; echo 'import sys; sys.exit(3)' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t9.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t9.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "SystemExit" && ok "T9 sys.exit() at import: UNKNOWN" || bad "T9 got verdict=$(verdict) reason=$(reason)"

# ── T10: a hang is killed (whole group) and is UNKNOWN ────────────────────────
R="$TMP_ROOT/t10"; mk_tree "$R"
cat > "$R/daemons/routes/cls_contacts.py" <<'EOF'
import os, subprocess, time
open(os.environ["SMOKE_PIDFILE"], "w").write(str(os.getpid()))
subprocess.Popen(["sleep", "300"])   # a grandchild too
time.sleep(300)
EOF
mk_plist "$TMP_ROOT/t10.plist" "$R" "{\"SMOKE_PIDFILE\":\"$R/pid\"}" "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t10.plist" --timeout 2
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "did not finish within" && ok "T10 hang: UNKNOWN after the timeout" || bad "T10 got verdict=$(verdict) reason=$(reason)"
pid="$(cat "$R/pid" 2>/dev/null)"; alive=1
if [ -n "$pid" ]; then for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || { alive=0; break; }; sleep 0.1; done; fi
[ -n "$pid" ] && [ "$alive" -eq 0 ] && ok "T10 the hung import process is gone" || bad "T10 import process pid=[$pid] still alive"

# ── T11-T17: launches / wrappers this script does not emulate -> UNKNOWN ──────
R="$TMP_ROOT/t11"; mk_tree "$R"
mk_plist "$TMP_ROOT/t11.plist" "$R" '{}' "$R/venv/bin/python3" -m flask run
run_smoke "$TMP_ROOT/t11.plist"
[ "$(verdict)" = "UNKNOWN" ] && ok "T11 python -m: UNKNOWN" || bad "T11 got verdict=$(verdict) out=[$OUT]"
mk_plist "$TMP_ROOT/t12.plist" "$R" '{}' "$R/venv/bin/does-not-exist-python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t12.plist"
[ "$(verdict)" = "UNKNOWN" ] && ok "T12 missing interpreter: UNKNOWN" || bad "T12 got verdict=$(verdict) out=[$OUT]"
echo 'not a plist' > "$TMP_ROOT/t13.plist"
run_smoke "$TMP_ROOT/t13.plist"
[ "$(verdict)" = "UNKNOWN" ] && ok "T13 unreadable plist: UNKNOWN" || bad "T13 got verdict=$(verdict) out=[$OUT]"
printf '#!/bin/bash\nexec "$NOPE/venv/bin/python3" "$NOPE/daemons/dash.py"\n' > "$R/w14.sh"
mk_plist "$TMP_ROOT/t14.plist" "$R" '{}' /bin/bash "$R/w14.sh"
run_smoke "$TMP_ROOT/t14.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "unresolved" && ok "T14 unresolved \$VAR in the launch line: UNKNOWN (never guessed)" || bad "T14 got verdict=$(verdict) reason=$(reason)"
printf '#!/bin/bash\nB="%s"\nexec "$B/venv/bin/python3" "$B/daemons/dash.py"\nexec "$B/venv/bin/python3" "$B/daemons/other.py"\n' "$R" > "$R/w15.sh"
mk_plist "$TMP_ROOT/t15.plist" "$R" '{}' /bin/bash "$R/w15.sh"
run_smoke "$TMP_ROOT/t15.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "different python launch" && ok "T15 two different launch lines: UNKNOWN (ambiguous)" || bad "T15 got verdict=$(verdict) reason=$(reason)"
printf '#!/bin/bash\nsource /etc/profile\nB="%s"\nexec "$B/venv/bin/python3" "$B/daemons/dash.py"\n' "$R" > "$R/w16.sh"
mk_plist "$TMP_ROOT/t16.plist" "$R" '{}' /bin/bash "$R/w16.sh"
run_smoke "$TMP_ROOT/t16.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "sources another file" && ok "T16 wrapper that sources a file: UNKNOWN" || bad "T16 got verdict=$(verdict) reason=$(reason)"
printf '#!/bin/bash\nB="%s"\nexport PYTHONPATH="$(cat /etc/hosts | head -1)"\nexec "$B/venv/bin/python3" "$B/daemons/dash.py"\n' "$R" > "$R/w17.sh"
mk_plist "$TMP_ROOT/t17.plist" "$R" '{}' /bin/bash "$R/w17.sh"
run_smoke "$TMP_ROOT/t17.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "PYTHONPATH" && ok "T17 dynamic PYTHONPATH in a wrapper: UNKNOWN (a guess would invert the verdict)" || bad "T17 got verdict=$(verdict) reason=$(reason)"

# ── T18: registered module; __main__ block does not run; DAEMON_IMPORT_SMOKE=1 ─
R="$TMP_ROOT/t18"; mk_tree "$R"; echo 'X = 1' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t18.plist" "$R" "{\"SMOKE_ENVFILE\":\"$R/envfile\",\"SMOKE_MAINFILE\":\"$R/mainfile\"}" "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t18.plist"
[ "$(verdict)" = "PASS" ] && ok "T18 the entrypoint is registered in sys.modules (sys.modules[__name__].__file__ resolves)" || bad "T18 got verdict=$(verdict) reason=$(reason)"
[ ! -e "$R/mainfile" ] && ok "T18 the if __name__ == '__main__' block did not run" || bad "T18 the __main__ block ran"
[ "$(cat "$R/envfile" 2>/dev/null)" = "1" ] && ok "T18 the child sees DAEMON_IMPORT_SMOKE=1" || bad "T18 DAEMON_IMPORT_SMOKE=[$(cat "$R/envfile" 2>/dev/null)]"

# ── T19: the plist's own EnvironmentVariables ARE honoured (the contrast to T3) ─
R="$TMP_ROOT/t19"; mk_tree "$R"
mk_plist "$TMP_ROOT/t19.plist" "$R" "{\"PYTHONPATH\":\"$R\"}" "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t19.plist"
[ "$(verdict)" = "PASS" ] && ok "T19 PYTHONPATH set IN the plist is what launchd would give the daemon: PASS" || bad "T19 got verdict=$(verdict) reason=$(reason)"

# ── T20: a crash of the helper itself is UNKNOWN, never the FAIL exit code ────
R="$TMP_ROOT/t20"; mk_tree "$R"
mk_plist "$TMP_ROOT/t20.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t20.plist" --timeout notanumber
[ "$(verdict)" = "UNKNOWN" ] && [ "$RC" -eq 2 ] && has "$(reason)" "crashed" && ok "T20 helper crash: UNKNOWN rc=2 (not rc=1)" || bad "T20 got verdict=$(verdict) rc=$RC out=[$OUT]"

# ── T21: /usr/bin/env launch form ─────────────────────────────────────────────
R="$TMP_ROOT/t21"; mk_tree "$R"; echo 'X = 1' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t21.plist" "$R" '{}' /usr/bin/env FOO=bar "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t21.plist"
[ "$(verdict)" = "PASS" ] && ok "T21 /usr/bin/env python script.py: PASS" || bad "T21 got verdict=$(verdict) out=[$OUT]"

# ── T22: the timeout handed to the child: 45 s by default, DAEMON_SMOKE_TIMEOUT over it, --timeout over both ─
# Waiting out 45 s is not a test; the module is loaded and the child process is replaced by one that records the
# timeout run() gives to communicate() and claims it expired. No output / a python error -> the check below fails.
tmo="$(python3 -I - "$HELPER" "$TMP_ROOT/t1.plist" <<'PYEOF'
import contextlib, importlib.util, io, os, sys
spec = importlib.util.spec_from_file_location("daemon_import_smoke_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
seen = []
class Popen:
    pid = 0
    returncode = 0
    def __init__(self, cmd, **kw):
        pass
    def communicate(self, timeout=None):
        if timeout is None:
            return b"", b""
        seen.append(timeout)
        raise m.subprocess.TimeoutExpired("x", timeout)
m.subprocess.Popen = Popen
m.os.killpg = lambda *a: None   # pid 0 would be OUR process group
plist = sys.argv[2]
def smoke(argv):
    with contextlib.redirect_stdout(io.StringIO()):
        m.main(argv)
os.environ.pop("DAEMON_SMOKE_TIMEOUT", None)
smoke([plist])
os.environ["DAEMON_SMOKE_TIMEOUT"] = "7"
smoke([plist])
smoke([plist, "--timeout", "3"])
print(*seen)
PYEOF
)"
[ "$tmo" = "45.0 7.0 3.0" ] && ok "T22 timeout: 45 s default, DAEMON_SMOKE_TIMEOUT over it, --timeout over both" || bad "T22 timeouts handed to the child: [$tmo]"

# ── T23: no argument / -h / --help print the usage and exit 2 (not a plist path, not a crash report) ────────
for a in none -h --help; do
  if [ "$a" = none ]; then H="$(python3 -I "$HELPER" 2>/dev/null)"; else H="$(python3 -I "$HELPER" "$a" 2>/dev/null)"; fi; rc=$?
  if [ "$rc" -eq 2 ] && has "$H" "THREE STATES" && ! printf '%s\n' "$H" | grep -q '^SMOKE='; then ok "T23 [$a]: usage text, rc=2"; else bad "T23 [$a]: rc=$rc out=[$H]"; fi
done

# ── T24: the reason line is cut at 400 characters (397 + "..."), and the unreadable-plist detail at 120 ─────
R="$TMP_ROOT/t24"; mk_tree "$R"
LONGWD="$(python3 -I -c 'print("/" + "a" * 200 + "/" + "b" * 200, end="")')"
mk_plist "$TMP_ROOT/t24.plist" "$LONGWD" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t24.plist"
want="$(python3 -I -c 'import sys; s = "working directory %s does not exist" % sys.argv[1]; print(s[:397] + "...", end="")' "$LONGWD")"
[ "$(verdict)" = "UNKNOWN" ] && [ "$(reason)" = "$want" ] && ok "T24 a reason longer than 400 characters is cut to exactly 400 (397 + ...)" || bad "T24 reason is ${#OUT} chars: [$(reason)]"
LONGPL="$TMP_ROOT/$(python3 -I -c 'print("p" * 200, end="")').plist"   # does not exist: the error message carries the whole path
run_smoke "$LONGPL"
r="$(reason)"
[ "$(verdict)" = "UNKNOWN" ] && [ "${r#plist unreadable: }" != "$r" ] && [ "${#r}" -eq $((18 + 120)) ] && [ "${r: -3}" = "..." ] && ok "T24 the unreadable-plist detail is cut to exactly 120 characters" || bad "T24 unreadable plist: ${#r} chars: [$r]"

# ── T25: the PATH search takes the first executable FILE: a non-executable file and a directory of that name are skipped ─
R="$TMP_ROOT/t25"; mk_tree "$R"; echo 'X = 1' > "$R/daemons/routes/cls_contacts.py"
mkdir -p "$R/pathA" "$R/pathB/python3" "$R/pathC"
: > "$R/pathA/python3"; chmod 644 "$R/pathA/python3"
ln -sfn "$PY" "$R/pathC/python3"
mk_plist "$TMP_ROOT/t25.plist" "$R" "{\"PATH\":\"$R/pathA:$R/pathB:$R/pathC\"}" python3 "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t25.plist"
[ "$(verdict)" = "PASS" ] && ok "T25 bare interpreter name: skips a non-executable file and a directory on the launchd PATH, finds the real one" || bad "T25 got verdict=$(verdict) reason=$(reason)"

# ── T26: a child that leaves no result: the reason carries the LAST 300 characters of its stderr, cut to 200 ──
R="$TMP_ROOT/t26"; mk_tree "$R"
cat > "$R/daemons/routes/cls_contacts.py" <<'EOF'
import os, sys
sys.stderr.write("0123456789" * 40)   # 400 characters, no newline, and no result line after them
sys.stderr.flush()
os._exit(0)
EOF
mk_plist "$TMP_ROOT/t26.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t26.plist"
want="no result from the child (rc=0): $(python3 -I -c 'print(("0123456789" * 30)[:197] + "...", end="")')"
[ "$(verdict)" = "UNKNOWN" ] && [ "$(reason)" = "$want" ] && ok "T26 no result: the reason shows stderr from its last 300 characters, cut to 200" || bad "T26 got verdict=$(verdict) reason=[$(reason)]"

# ── T27: on FAIL the sys.path detail is cut to 600 characters (the incident's own evidence must stay readable) ─
R="$TMP_ROOT/t27"; mk_tree "$R"
PADPATH="$(python3 -I -c 'print(":".join("/nonexistent/pad/dir%02d" % i for i in range(60)), end="")')"
mk_plist "$TMP_ROOT/t27.plist" "$R" "{\"PYTHONPATH\":\"$PADPATH\"}" "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t27.plist"
line="$(printf '%s\n' "$OUT" | sed -n 's/^SMOKE_DETAIL=sys.path at failure: //p' | head -1)"
[ "$(verdict)" = "FAIL" ] && [ "${#line}" -eq 600 ] && [ "${line: -3}" = "..." ] && ok "T27 sys.path detail on FAIL: exactly 600 characters" || bad "T27 got verdict=$(verdict) detail is ${#line} chars"

# ── hq-mutants lastro (ga-ow127o6): interpreter flags, wrapper corners, interpreter checks and cut widths that T1-T27 never crossed ──
# T1-T27 launch every daemon as `python script.py` with no flag and no script argument, so parse_python_args' flag loop, the wrapper
# reader's indentation/comment/cd rules and the width of the reason lines only ever ran on their easy side. The probe entrypoint below
# writes what the CHILD saw (argv, working directory, -O level), so how the launch was rebuilt is observable and not only the verdict.
mk_probe() {   # $1 = a mk_tree dir
  cat > "$1/daemons/probe.py" <<'EOF'
import json, os, sys
open(os.environ["SMOKE_PROBE"], "w").write(json.dumps({"argv": sys.argv, "cwd": os.path.realpath(os.getcwd()), "opt": sys.flags.optimize}))
EOF
}
# probe <file> <key> -> that key of the child's record as json text; vazio/falhou: arquivo ausente, ilegível ou sem a chave -> o python falha e não imprime nada,
# então a comparação reprova (nunca passa por ausência)
probe() { python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]), end="")' "$1" "$2" 2>/dev/null; }
realdir() { (cd "$1" && pwd -P); }
cut_to() {   # cut_to <char> <total> -> <total> chars ending in "..." (what one_line does to a longer string)
  python3 -I -c 'import sys; print(sys.argv[1] * (int(sys.argv[2]) - 3) + "...", end="")' "$1" "$2"
}

# ── T28: interpreter flags are skipped to find the script, forwarded to the child, and the script's own arguments follow it ──
# mutants 57de7c394d 56d94c7f7c 5720549856 45af532eb0 4445607091 (the flag loop) 7ace4b6549 c967a877a5 (a 3-character flag is not -m/-c) 9d0bf05fad (script args)
R="$TMP_ROOT/t28"; mk_tree "$R"; mk_probe "$R"
mk_plist "$TMP_ROOT/t28.plist" "$R" "{\"SMOKE_PROBE\":\"$R/probe.json\"}" "$R/venv/bin/python3" -u -W ignore -OO "$R/daemons/probe.py" a "b c"
run_smoke "$TMP_ROOT/t28.plist"
[ "$(verdict)" = "PASS" ] && ok "T28 -u -W ignore -OO before the script: PASS" || bad "T28 got verdict=$(verdict) reason=$(reason)"
[ "$(probe "$R/probe.json" argv)" = "[\"$R/daemons/probe.py\", \"a\", \"b c\"]" ] && ok "T28 the child's argv is the script then ITS arguments, nothing else" || bad "T28 argv: [$(probe "$R/probe.json" argv)]"
[ "$(probe "$R/probe.json" opt)" = "2" ] && ok "T28 the flags reach the interpreter (-OO -> optimize level 2)" || bad "T28 optimize level: [$(probe "$R/probe.json" opt)]"

# ── T29: flags and no script -> UNKNOWN (rc 2) with the right reason, never a crash ──
# mutants e3ad19e0ed b6041760ce (loop bound), 16137b38a7 (`i >= len`), 8afb773209 e5d846e2ab (`-W` as the LAST argument), 152840c599 (the UNKNOWN exit code)
R="$TMP_ROOT/t29"; mk_tree "$R"
for fl in "-u" "-W" "-W x"; do
  # shellcheck disable=SC2086
  mk_plist "$TMP_ROOT/t29.plist" "$R" '{}' "$R/venv/bin/python3" $fl
  run_smoke "$TMP_ROOT/t29.plist"
  [ "$(verdict)" = "UNKNOWN" ] && [ "$RC" -eq 2 ] && has "$(reason)" "no script argument after the interpreter flags" && ok "T29 [$fl] and no script: UNKNOWN rc=2, 'no script argument'" || bad "T29 [$fl] got verdict=$(verdict) rc=$RC reason=$(reason)"
done

# ── T30: -m / -c in every spelling is not emulated ──
# mutants 33b1d68afb (`-m` / `-c` alone), f7d821e50b 6647b79f6b afb09a5837 ab4b5c4024 e3dac23f52 (attached: -mx, -cx)
R="$TMP_ROOT/t30"; mk_tree "$R"
for fl in "-m flask run" "-c x" "-mx $R/daemons/dash.py" "-cx $R/daemons/dash.py"; do
  # shellcheck disable=SC2086
  mk_plist "$TMP_ROOT/t30.plist" "$R" '{}' "$R/venv/bin/python3" $fl
  run_smoke "$TMP_ROOT/t30.plist"
  [ "$(verdict)" = "UNKNOWN" ] && [ "$RC" -eq 2 ] && has "$(reason)" "launch (-m/-c) is not emulated" && ok "T30 [${fl%% *}] launch: UNKNOWN rc=2, said to be -m/-c" || bad "T30 [$fl] got verdict=$(verdict) rc=$RC reason=$(reason)"
done
# EQUIVALENT (ga-ow127o6; 43a00b5a1b and 9e5c3fe8fd, `len(a) > 2` -> `len(a) >= 2` on the attached -m / -c forms): the only 2-character
# string that startswith("-m") is "-m" itself, which the `a in ("-m", "-c")` alternative before it already took, so `> 2` and `>= 2`
# raise for exactly the same arguments: no launch line separates them.

# ── T32: a relative entrypoint is resolved against the WorkingDirectory ──
# mutant a508996b07 (`if not os.path.isabs(script)`)
R="$TMP_ROOT/t32"; mk_tree "$R"; mk_probe "$R"
mk_plist "$TMP_ROOT/t32.plist" "$R/daemons" "{\"SMOKE_PROBE\":\"$R/probe.json\"}" "$R/venv/bin/python3" probe.py x
run_smoke "$TMP_ROOT/t32.plist"
[ "$(verdict)" = "PASS" ] && [ "$(probe "$R/probe.json" argv)" = "[\"$R/daemons/probe.py\", \"x\"]" ] && ok "T32 relative script + WorkingDirectory: PASS, argv carries the resolved absolute path" || bad "T32 got verdict=$(verdict) reason=$(reason) argv=[$(probe "$R/probe.json" argv)]"

# ── T33: an interpreter that is not an executable FILE is refused before any launch ──
# mutant c11d0573d1 (`isfile and access` -> `isfile or access`): a non-executable file and a directory both slip through to Popen
R="$TMP_ROOT/t33"; mk_tree "$R"; mkdir -p "$R/xbin" "$R/dbin/python3"
: > "$R/xbin/python3"; chmod 644 "$R/xbin/python3"
for p in "$R/xbin/python3" "$R/dbin/python3"; do
  mk_plist "$TMP_ROOT/t33.plist" "$R" '{}' "$p" "$R/daemons/dash.py"
  run_smoke "$TMP_ROOT/t33.plist"
  [ "$(verdict)" = "UNKNOWN" ] && [ "$RC" -eq 2 ] && has "$(reason)" "interpreter not found: $p" && ok "T33 [${p#$R/}] not an executable file: UNKNOWN 'interpreter not found'" || bad "T33 [${p#$R/}] got verdict=$(verdict) rc=$RC reason=$(reason)"
done

# ── T34: /usr/bin/env with assignments and no program ──
# mutant cfc4e8a612 (`while i < len` -> `<=` walks off the end of ProgramArguments)
R="$TMP_ROOT/t34"; mk_tree "$R"
mk_plist "$TMP_ROOT/t34.plist" "$R" '{}' /usr/bin/env FOO=bar
run_smoke "$TMP_ROOT/t34.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "env with no program" && ok "T34 env FOO=bar and nothing else: UNKNOWN 'env with no program' (not a crash)" || bad "T34 got verdict=$(verdict) reason=$(reason)"

# ── T35: the wrapper reader — blank and indented lines, a trailing comment, `cd`, and which of two launch lines wins ──
# mutants 7542298235 420bb46b76 (blank line / TAB and one-space indent are not top level), f63110c146 (comments=True: an apostrophe in a trailing
# comment must not unbalance the line), 9b1e1f520a 52f5f75b3c b21af0b1a4 (the `cd`), a04cb470b3 (the LAST of two launch lines that agree on exe/script/args)
R="$TMP_ROOT/t35"; mk_tree "$R"; mk_probe "$R"
{
  printf '#!/bin/bash\n'
  printf 'B="%s"\n' "$R"
  printf '\n'
  printf 'if [ -n "${NOPE:-}" ]; then\n'
  printf '\texec "$B/venv/bin/python3" "$B/daemons/other.py"\n'
  printf ' exec "$B/venv/bin/python3" "$B/daemons/other2.py"\n'
  printf 'fi\n'
  printf 'cd "$B/daemons"\n'
  printf 'exec "$B/venv/bin/python3" -O "$B/daemons/probe.py" a\n'
  printf 'exec "$B/venv/bin/python3" "$B/daemons/probe.py" a  # it'"'"'s the launch\n'
} > "$R/w35.sh"
mk_plist "$TMP_ROOT/t35.plist" "$R" "{\"SMOKE_PROBE\":\"$R/probe.json\"}" /bin/bash "$R/w35.sh"
run_smoke "$TMP_ROOT/t35.plist"
[ "$(verdict)" = "PASS" ] && ok "T35 wrapper with a blank line, indented launch lines and a trailing comment: PASS" || bad "T35 got verdict=$(verdict) reason=$(reason)"
[ "$(probe "$R/probe.json" argv)" = "[\"$R/daemons/probe.py\", \"a\"]" ] && ok "T35 the comment is not part of the launch line" || bad "T35 argv: [$(probe "$R/probe.json" argv)]"
[ "$(probe "$R/probe.json" opt)" = "0" ] && ok "T35 of two agreeing launch lines the LAST one wins (no -O)" || bad "T35 optimize level: [$(probe "$R/probe.json" opt)]"
[ "$(probe "$R/probe.json" cwd)" = "\"$(realdir "$R/daemons")\"" ] && ok "T35 the wrapper's top-level cd decides the working directory" || bad "T35 cwd: [$(probe "$R/probe.json" cwd)]"

# ── T36: the `source` refusal quotes the offending line cut to exactly 80 characters ──
# mutant bcca73d5e5 (80 -> 81)
R="$TMP_ROOT/t36"; mk_tree "$R"
SRCLINE="source /$(python3 -I -c 'print("s" * 120, end="")')"
printf '#!/bin/bash\n%s\nexec "%s/venv/bin/python3" "%s/daemons/dash.py"\n' "$SRCLINE" "$R" "$R" > "$R/w36.sh"
mk_plist "$TMP_ROOT/t36.plist" "$R" '{}' /bin/bash "$R/w36.sh"
run_smoke "$TMP_ROOT/t36.plist"
want="wrapper sources another file ($(python3 -I -c 'import sys; print(sys.argv[1][:77] + "...", end="")' "$SRCLINE"))"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "$want" && ok "T36 the quoted wrapper line is cut to exactly 80 characters (77 + ...)" || bad "T36 got verdict=$(verdict) reason=[$(reason)]"

# ── T37: a reason of EXACTLY 400 characters is not cut ──
# mutant 1fcab409cb (`len(s) <= limit` -> `<`)
R="$TMP_ROOT/t37"; mk_tree "$R"
EXACTWD="$(python3 -I -c 'print("/" + "a" * 183 + "/" + "b" * 182, end="")')"
mk_plist "$TMP_ROOT/t37.plist" "$EXACTWD" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t37.plist"
want="working directory $EXACTWD does not exist"
[ "${#want}" -eq 400 ] && [ "$(verdict)" = "UNKNOWN" ] && [ "$(reason)" = "$want" ] && ok "T37 a 400-character reason is shown whole" || bad "T37 want ${#want} chars, got [$(reason)]"

# ── T38: the FAIL reason is cut to 200, each detail line to 300; the UNKNOWN-at-import reason to 160 and its detail to 300 ──
# mutants 24c0e17fb3 (FAIL reason 200), e96bf68147 (FAIL detail 300), f0221ce263 (other-error reason 160), 42ba05b778 (other-error detail 300)
R="$TMP_ROOT/t38"; mk_tree "$R"
python3 -I -c 'print("raise ImportError(\"x\" * 400)")' > "$R/daemons/routes/cls_contacts.py"
mk_plist "$TMP_ROOT/t38.plist" "$R" '{}' "$R/venv/bin/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t38.plist"
want="ImportError: $(cut_to x 200) (entrypoint $R/daemons/dash.py, cwd $R)"
[ "$(verdict)" = "FAIL" ] && [ "$(reason)" = "$want" ] && ok "T38 FAIL reason: the message is cut to exactly 200 characters" || bad "T38 FAIL reason [$(reason)]"
dline="$(printf '%s\n' "$OUT" | sed -n 's/^SMOKE_DETAIL=\(ImportError: .*\)$/\1/p' | head -1)"
[ "${#dline}" -eq 300 ] && [ "${dline: -3}" = "..." ] && ok "T38 FAIL detail line: cut to exactly 300 characters" || bad "T38 FAIL detail is ${#dline} chars: [${dline:0:60}]"
python3 -I -c 'print("raise RuntimeError(\"y\" * 400)")' > "$R/daemons/routes/cls_contacts.py"
run_smoke "$TMP_ROOT/t38.plist"
[ "$(verdict)" = "UNKNOWN" ] && has "$(reason)" "RuntimeError at import ($(cut_to y 160))" && ok "T38 UNKNOWN-at-import reason: the message is cut to exactly 160 characters" || bad "T38 UNKNOWN reason [$(reason)]"
dline="$(printf '%s\n' "$OUT" | sed -n 's/^SMOKE_DETAIL=\(RuntimeError: .*\)$/\1/p' | head -1)"
[ "${#dline}" -eq 300 ] && [ "${dline: -3}" = "..." ] && ok "T38 UNKNOWN-at-import detail line: cut to exactly 300 characters" || bad "T38 UNKNOWN detail is ${#dline} chars: [${dline:0:60}]"

# ── T39: a crash of the helper is reported with the error cut to exactly 200 characters ──
# mutant ba5e57b48d (200 -> 201)
run_smoke "$TMP_ROOT/t1.plist" --timeout "$(python3 -I -c 'print("z" * 300, end="")')"
r="$(reason)"
[ "$(verdict)" = "UNKNOWN" ] && [ "$RC" -eq 2 ] && [ "${r#smoke script crashed: ValueError: }" != "$r" ] && [ "${#r}" -eq 234 ] && [ "${r: -3}" = "..." ] && ok "T39 helper crash: the error text is cut to exactly 200 characters" || bad "T39 got verdict=$(verdict) rc=$RC reason is ${#r} chars: [${r:0:80}]"

# ── T40: an interpreter that exists but cannot start (bad shebang): the OS error is cut to exactly 160 characters ──
# mutant 5981a174c8 (160 -> 161)
R="$TMP_ROOT/t40"; mk_tree "$R"
LONGD="$R/$(python3 -I -c 'print("d" * 150, end="")')"; mkdir -p "$LONGD"
printf '#!/nonexistent/interpreter\n' > "$LONGD/python3"; chmod 755 "$LONGD/python3"
mk_plist "$TMP_ROOT/t40.plist" "$R" '{}' "$LONGD/python3" "$R/daemons/dash.py"
run_smoke "$TMP_ROOT/t40.plist"
r="$(reason)"; prefix="could not start the interpreter: "
[ "$(verdict)" = "UNKNOWN" ] && [ "${r#$prefix}" != "$r" ] && [ "${#r}" -eq $(( ${#prefix} + 160 )) ] && [ "${r: -3}" = "..." ] && ok "T40 could-not-start: the OS error is cut to exactly 160 characters" || bad "T40 got verdict=$(verdict) reason is ${#r} chars: [${r:0:100}]"

echo
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
