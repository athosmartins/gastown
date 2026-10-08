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

echo
echo "== result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
