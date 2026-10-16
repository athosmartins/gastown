#!/bin/bash
# third-state-reads-check.selftest.sh — ga-57e7l0.1 (fatia 2/3): /gate-done refuses a NEW failable read that no test makes fail.
#
#   A. kinds     each kind of read (py file/parse/cmd/db/http, sh cmd/file): a happy-path test is refused (rc 1, file:line), a test that INJECTS the failure
#                passes (rc 0), and the previous HEAD of that branch (no failure test yet) is refused again
#   B. edges     no test, a test for ANOTHER file, waivers, comments / reads inside tests / old reads are not new reads, and the shapes that are NOT reads
#                (SQL that writes, a dict .get, a heredoc write, docs/) each beside a control that is; an unsupported language, a bad base, no git: rc 2
#      B3        open(): the MODE argument decides, per call (a quoted w/a/x elsewhere in the call, or a write on the same line, hides nothing)
#      B4        a failure test must INJECT: bare words, comments and test names (returncode, timeout, 500, missing) do not count
#      B5        what the check cannot read (unrecognised files, other languages, a non-default diff prefix, a corrupt arms row) is said, never ok
#   C. modes     conf absent / off / warn / enforce / invalid, kill switches, enforce_pct arms (first assignment wins, unreadable arms file = rc 2)
#   D. controls  sixteen mutants of the checker, each of which one case above must catch (a check that cannot fail proves nothing)
#   E. wiring    step 2e of the gate formula extracted and run (bash 3.2 and zsh) against fixture worktrees; gate-done.md and its template copy, in parity
# Hermetic: scratch dir only, throw-away git repos, needs python3 and git. Env: TSR_HQ (city root, default: three levels up), TSR_KEEP=1. bash 3.2 safe.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ="${TSR_HQ:-$(cd "$HERE/../../.." && pwd)}"
CHK="$HERE/third-state-reads-check.py"
FORMULA="$HQ/formulas/mol-quality-gate-runner.toml"
GATE_DONE="$HQ/commands/gate-done.md"
GATE_DONE_BODY="$HQ/../internal/templates/commands/bodies/gate-done.md"
PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf '  FAIL %s\n' "$1" >&2; }

[ -r "$CHK" ] || { echo "FATAL: $CHK not found" >&2; exit 2; }
PY="$(command -v python3)" || { echo "FATAL: python3 missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git missing" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/third-state-reads-check.XXXXXX")" || { echo "FATAL: no scratch dir" >&2; exit 2; }
case "$W" in /?*) ;; *) echo "FATAL: unusable scratch path '$W'" >&2; exit 2 ;; esac
REACHED_END=0
finish() {
  local rc=$?
  chmod -R u+rw "$W" 2>/dev/null
  if [ "${TSR_KEEP:-0}" = 1 ]; then echo "(kept: $W)"
  elif command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$W" >/dev/null 2>&1; then safe-clean "$W" >/dev/null 2>&1
  else echo "(scratch dir left behind: $W — safe-clean does not cover this location)"; fi
  if [ "$REACHED_END" != 1 ] && [ "$rc" = 0 ]; then echo "FAIL: selftest aborted before its last line" >&2; exit 1; fi
}
trap finish EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
STATE="$W/state"; mkdir -p "$STATE"; export THIRD_STATE_READS_STATE_DIR="$STATE"; unset THIRD_STATE_READS_CHECK
conf() { rm -rf "$STATE/third-state-reads.conf"; printf '%s\n' "$@" > "$STATE/third-state-reads.conf"; }
newrepo() { R="$W/repo-$1"; rm -rf "$R"; mkdir -p "$R"; git -C "$R" init -q -b main && printf 'base\n' > "$R/README.md" && git -C "$R" add README.md \
  && git -C "$R" commit -q -m base && git -C "$R" update-ref refs/remotes/origin/main HEAD && git -C "$R" checkout -q -b feat; }
put() { mkdir -p "$(dirname "$R/$1")"; cat > "$R/$1"; }
commit() { git -C "$R" add . && git -C "$R" commit -q -m "$1"; }   # fixture repos only, never the shared tree
RC=0; OUT=""
chk() { OUT="$("$PY" -I "${CHKX:-$CHK}" --repo "$R" "$@" 2>&1)"; RC=$?; }
want() {   # want <rc> <label> [pattern the output must match]
  if [ "$RC" != "$1" ]; then bad "$2: rc=$RC, want $1 :: $(printf '%s' "$OUT" | head -3 | tr '\n' '|')"
  elif [ -n "${3:-}" ] && ! printf '%s' "$OUT" | grep -Eq -- "$3"; then bad "$2: rc ok but no /$3/ in :: $(printf '%s' "$OUT" | head -3 | tr '\n' '|')"
  else ok "$2"; fi
}
fx() {   # fx <kind> <prod|happy|fail>: a fixture file body. happy = a test touching the file with no failure injected; fail = one that injects it
  case "$1:$2" in
    file:prod)   printf 'def load(p):\n    return open(p).read()\n' ;;
    file:happy)  printf 'import m_file\ndef test_ok(tmp_path):\n    assert m_file.load(str(tmp_path / "x")) == "a"\n' ;;
    file:fail)   printf 'import m_file\ndef test_missing_file(tmp_path):\n    assert m_file.load(str(tmp_path / "nonexistent.txt")) is None\n' ;;
    parse:prod)  printf 'import json\ndef parse(s):\n    return json.loads(s)\n' ;;
    parse:happy) printf 'import m_parse\ndef test_ok():\n    assert m_parse.parse("[1]") == [1]\n' ;;
    parse:fail)  printf 'import m_parse\ndef test_corrupt():\n    assert m_parse.parse("{not json") is None\n' ;;
    cmd:prod)    printf 'import subprocess\ndef run():\n    return subprocess.run(["true"], capture_output=True)\n' ;;
    cmd:happy)   printf 'import m_cmd\ndef test_ok():\n    r = m_cmd.run()\n    assert r.returncode == 0\n    assert r.stdout == b""\n' ;;
    cmd:fail)    printf 'import subprocess\nimport m_cmd\ndef test_nonzero(monkeypatch):\n    def boom(*a, **k):\n        raise subprocess.CalledProcessError(3, "x")\n    monkeypatch.setattr(m_cmd.subprocess, "run", boom)\n    assert m_cmd.run() is None\n' ;;
    db:prod)     printf 'import sqlite3\ndef conn(p):\n    return sqlite3.connect(p)\n' ;;
    db:happy)    printf 'import m_db\ndef test_ok():\n    assert m_db.conn(":memory:")\n' ;;
    db:fail)     printf 'import m_db\ndef test_unopenable():\n    assert m_db.conn("/dev/null/x") is None\n' ;;
    http:prod)   printf 'import urllib.request\ndef get(u):\n    return urllib.request.urlopen(u)\n' ;;
    http:happy)  printf 'import m_http\ndef test_ok():\n    assert m_http.get("http://stub.local/x")\n' ;;
    http:fail)   printf 'import urllib.error\nimport m_http\ndef test_down(monkeypatch):\n    def down(*a, **k):\n        raise urllib.error.URLError("refused")\n    monkeypatch.setattr(m_http.urllib.request, "urlopen", down)\n    assert m_http.get("http://stub.local/x") is None\n' ;;
    shcmd:prod)  printf '#!/bin/bash\nout=$(git status --short)\necho "$out"\n' ;;
    shcmd:happy) printf '#!/bin/bash\nbash m_shcmd.sh | grep -q x && echo ok\n' ;;
    shcmd:fail)  printf '#!/bin/bash\nPATH=/nonexistent bash m_shcmd.sh; test $? = 127\n' ;;
    shfile:prod) printf '#!/bin/bash\nwhile read -r l; do echo "$l"; done < "$1"\n' ;;
    shfile:happy) printf '#!/bin/bash\nbash m_shfile.sh /etc/hostname\n' ;;
    shfile:fail) printf '#!/bin/bash\nbash m_shfile.sh /nonexistent/file\n' ;;
  esac
}
kind_case() {
  local k="$1" pp tp
  case "$k" in sh*) pp="bin/m_$k.sh"; tp="tests/m_$k.selftest.sh" ;; *) pp="lib/m_$k.py"; tp="tests/test_m_$k.py" ;; esac
  newrepo "k-$k"; fx "$k" prod | put "$pp"; fx "$k" happy | put "$tp"; commit "read + happy-path test"
  chk; want 1 "$k: a touched test that injects no failure is refused, file:line listed" "$pp:[0-9]+ "
  fx "$k" fail | put "$tp"; commit "failure test"
  chk; want 0 "$k: with a test that injects the failure it passes" "ok --"
  chk --head HEAD~1; want 1 "$k: control — the previous HEAD (no failure test yet) is refused"
}

conf mode=enforce
echo "== A. each kind of read: refused without a failure test, ok with one, refused again on the previous HEAD =="
for k in file parse cmd db http shcmd shfile; do kind_case "$k"; done

echo "== B. what is and is not a new read / what could not be told =="
newrepo b1; fx file prod | put lib/m_file.py; commit r
chk; want 1 "no test touched at all is refused" "lib/m_file.py:2 "
newrepo b2; fx file prod | put lib/m_file.py; printf 'def test_unreadable_other():\n    assert other_load("/nope") is None   # unreadable\n' | put tests/test_other.py; commit r
chk; want 1 "a file-failure test that names ANOTHER file does not cover this read" "lib/m_file.py:2 "
newrepo b3; printf 'def load(p):\n    # third-state-waiver: reads a packaged constant, cannot fail\n    return open(p).read()\n' | put lib/m_file.py; commit r
chk; want 0 "a waiver with a reason is accepted and listed" "waived  lib/m_file.py:3"
newrepo b4; printf 'def load(p):\n    return open(p).read()  # third-state-waiver: ok\n' | put lib/m_file.py; commit r
chk; want 1 "a waiver without a real reason (under 10 chars) is not a waiver" "lib/m_file.py:2 "
newrepo b5; printf '# x = open(p).read()\nopen(p, "w").write("a")\nOUT = "$(cat x)"\n' | put lib/w.py; printf '#!/bin/bash\nx=$(cat f)\n' | put tests/w.selftest.sh; printf 'open(x) and json.loads(y)\n' | put docs/n.md; commit r
chk; want 0 "comments, write-mode open, reads inside tests and in docs are not new reads" "0 recognised new read"
newrepo b6; fx file prod | put lib/old.py; commit old; git -C "$R" update-ref refs/remotes/origin/main HEAD; printf '# a comment\n' >> "$R/lib/old.py"; commit c
chk; want 0 "a read already on main is not new when the branch touches another line of the file" "0 recognised new read"
newrepo b7; printf 'package x\nfunc f() { os.ReadFile("a") }\n' | put pkg/x.go; commit r
chk; want 2 "unsupported language (go) with a read-looking line: could not tell" "no rules for"
newrepo b8; printf 'package x\nfunc f() int { return 1 }\n' | put pkg/x.go; commit r
chk; want 0 "unsupported language with no read-looking line: nothing to tell" "0 recognised new read"
newrepo b9; fx file prod | put lib/m_file.py; printf 'package x\nfunc f() { os.ReadFile("a") }\n' | put pkg/x.go; commit r
chk; want 1 "a gap found beats a 'could not tell' elsewhere (rc 1, both printed)" "also"
chk --base no-such-ref; want 2 "an unresolvable base is rc 2, not an empty diff" "NÃO SEI"
mkdir -p "$W/norepo"; OUT="$("$PY" -I "$CHK" --repo "$W/norepo" 2>&1)"; RC=$?; want 2 "not a git repository is rc 2" "NÃO SEI"
mkdir -p "$W/nogit"; OUT="$(PATH="$W/nogit" "$PY" -I "$CHK" --repo "$R" 2>&1)"; RC=$?; want 2 "no git binary is rc 2" "could not run"
newrepo b10; printf 'x\n' | put README.md; commit nothing
chk; want 0 "a diff with no reads at all is ok" "0 recognised new read"

echo "== B2. shapes that are NOT reads (found on 90 real branches), each next to a control that still is =="
newrepo b11; printf '%s\n' 'def w(c, rows):' '    c.execute("INSERT INTO t VALUES (1)")' '    c.executemany("INSERT INTO t VALUES (?)", rows)' '    c.execute("CREATE TABLE IF NOT EXISTS t (a)")' '    c.execute("SET threads=3")' '    c.execute(' '        "UPDATE t SET a = 2"' '    )' '    c.execute("PRAGMA busy_timeout=5000")' | put lib/w.py; commit r
chk; want 0 "SQL that writes or configures (INSERT, executemany, CREATE, SET, UPDATE on the next line, PRAGMA) is not a read" "0 recognised new read"
newrepo b12; printf '%s\n' 'def r(c):' '    return c.execute("SELECT a FROM t").fetchall()' | put lib/r.py; commit r
chk; want 1 "control: a SELECT in the same shape is a read" "lib/r.py:2 "
newrepo b13; printf '%s\n' 'def r(c, sql):' '    rows = c.execute(sql).fetchall()' '    c.execute("INSERT INTO t VALUES (1)")' '    return rows' | put lib/r.py; commit r
chk; want 1 "control: a write on the NEXT line does not hide the read on this one" "lib/r.py:2 "
newrepo b14; printf '%s\n' 'def r(c):' '    return c.execute(' '        "SELECT a FROM t"' '    ).fetchall()' | put lib/r.py; commit r
chk; want 1 "control: a SELECT whose SQL sits on the next line is a read" "lib/r.py:2 "
newrepo b15; printf '%s\n' '#!/bin/bash' 'echo "$1" | head -4' 'echo "$1" | head -n 4' 'echo "$1" | tail -1' 'cat > "$2" <<EOF' 'hi' 'EOF' | put bin/p.sh; commit r
chk; want 0 "head/tail on a pipe (stdin) and a heredoc write are not file reads" "0 recognised new read"
newrepo b16; printf '%s\n' '#!/bin/bash' '  tail -1 "$LOG" | grep -q x' 'true && cat "$2"' | put bin/q.sh; commit r
chk; want 1 "control: an indented tail with an operand is a file read" "bin/q.sh:2 "
want 1 "control: cat after && is a file read" "bin/q.sh:3 "
newrepo b17; fx file prod | put docs/launchd-archive/retired/old.py; fx shcmd prod | put docs/x/y.sh; commit r
chk; want 0 "code under docs/ or retired/ is archive, not a new read" "0 recognised new read"
newrepo b18; printf 'def pick(d):\n    return d.get("name")\n' | put lib/k.py; commit r
chk; want 0 "a dict .get() is not a read (the key kind was dropped: 51 of 122 flagged reads on the calibration set were in-memory lookups)" "0 recognised new read"
newrepo b19; fx db prod | put lib/m_db.py; printf 'import m_db\ndef test_banco_ausente():\n    assert m_db.conn("/nao/existe/x.db") is None\n' | put tests/test_m_db.py; commit r
chk; want 0 "a db test that says the file is absent covers the db read" "ok --"
newrepo b20; fx shcmd prod | put bin/m_shcmd.sh; printf '#!/bin/bash\nbd() { return 1; }\nbash m_shcmd.sh\n' | put tests/m_shcmd.selftest.sh; commit r
chk; want 0 "a bash stub that returns 1 covers the failing command" "ok --"
newrepo b20p; fx cmd prod | put lib/m_cmd.py; printf 'import m_cmd\ndef fake(*a):\n    return 1, ""\ndef test_f():\n    assert m_cmd.run() is None\n' | put tests/test_m_cmd.py; commit r
chk; want 0 "a python fake runner that returns (1, ...) covers the failing command" "ok --"
newrepo b20q; fx cmd prod | put lib/m_cmd.py; printf 'import m_cmd\ndef fake(*a):\n    return 0, ""\ndef test_f():\n    assert m_cmd.run() is None\n' | put tests/test_m_cmd.py; commit r
chk; want 1 "control: a python fake runner that returns (0, ...) is the happy path, still refused" "lib/m_cmd.py:3 "

newrepo b21; printf '%s\n' 'def r(c, sql):' '    c.execute("INSERT INTO t VALUES (1)"); return c.execute(sql)' | put lib/r.py; commit r
chk; want 1 "control: an INSERT and a SELECT on ONE line is a read (SQL writes are judged per execute call, not per line)" "lib/r.py:2 "

echo "== B3. open(): the MODE argument decides, per call (gate review ga-57e7l0.1: a quoted w/a/x anywhere in the call, or a write elsewhere on the line, hid a read) =="
SN=0
shape() {   # shape <rc> <label> <python body lines (printf %b)> [pattern]: lib/s.py holding only this, and no test at all
  SN=$((SN+1)); newrepo "sh$SN"; printf 'def f(p, src, dst, d, mode):\n%b\n' "$3" | put lib/s.py; commit r; chk; want "$1" "$2" "${4:-}"
}
shape 1 'open("agents.toml").read(): a filename starting with a is a READ' '    return open("agents.toml").read()' "lib/s.py:2 "
shape 1 'open("x.json"): a bare open of a quoted name is a READ' '    return open("x.json")' "lib/s.py:2 "
shape 1 'open(p, encoding="ascii"): a keyword value starting with a is not a mode, it is a READ' '    return open(p, encoding="ascii")' "lib/s.py:2 "
shape 1 'a read and a write on ONE line (with open(src) as f, open(dst, "w") as g) is a READ' '    with open(src) as f, open(dst, "w") as g:' "lib/s.py:2 "
shape 1 'open(os.path.join(d, "arms.jsonl")).read(): a quoted a inside a nested call is a READ' '    return open(os.path.join(d, "arms.jsonl")).read()' "lib/s.py:2 "
shape 1 'control: open(p).read()' '    return open(p).read()' "lib/s.py:2 "
shape 1 'open(p, mode): a mode we cannot see is a READ, not a write' '    return open(p, mode)' "lib/s.py:2 "
shape 1 'open(p, "r+") reads' '    return open(p, "r+")' "lib/s.py:2 "
shape 1 'open(os.path.join(d, "w")): a w inside the FILENAME argument is not a mode' '    return open(os.path.join(d, "w"))' "lib/s.py:2 "
shape 1 'open(dst, "w").write(open(src).read()): the write does not hide the read inside it' '    open(dst, "w").write(open(src).read())' "lib/s.py:2 "
shape 1 'gzip.open(p) and Path(p).open() are reads too' '    return gzip.open(p), Path(p).open()' "lib/s.py:2 "
shape 1 'an open( that never closes on the added lines is a READ' '    return open(p,' "lib/s.py:2 "
shape 0 'open(dst, "w") writes: not a read' '    open(dst, "w").write("a")' "0 recognised new read"
shape 0 'open(dst, mode="wb") writes: not a read' '    open(dst, mode="wb").write(b"a")' "0 recognised new read"
shape 0 'open(file=dst, mode="x", encoding="utf-8") writes: not a read' '    open(file=dst, mode="x", encoding="utf-8").write("a")' "0 recognised new read"
shape 0 'a wrapped open(dst, then "a+" on the next added line writes: the mode is read across lines' '    with open(dst,\n        "a+") as g:\n        g.write("a")' "0 recognised new read"
shape 0 'Path(dst).open("w") and gzip.open(dst, "wb") write: not reads' '    Path(dst).open("w").write("a"); gzip.open(dst, "wb")' "0 recognised new read"

echo "== B4. a failure test must INJECT the failure: bare words, comments and test names do not count (gate review: returncode, timeout, 500, missing) =="
mk() {   # mk <rc> <label> <prod path> <prod body> <test path> <test body>: a read beside a test of the same module, in one diff
  SN=$((SN+1)); newrepo "mk$SN"; printf '%b\n' "$4" | put "$3"; printf '%b\n' "$6" | put "$5"; commit r; chk; want "$1" "$2"
}
MKP='import subprocess\ndef f():\n    return subprocess.run(["x"])'; MKT='tests/test_m_mk.py'
HP='import requests\ndef fetch(u):\n    return requests.get(u).json()'; FP='def load(p):\n    return open(p).read()'
SHP='#!/bin/bash\nout=$(git status --short)'
mk 1 'subprocess.run beside a test that asserts returncode == 0: refused (happy path, not a failure)' lib/m_mk.py "$MKP" $MKT 'import m_mk\ndef test_ok():\n    assert m_mk.f().returncode == 0'
mk 1 'requests.get beside fetch(u, timeout=5) == {...}: refused (a timeout kwarg injects nothing)' lib/m_mk.py "$HP" $MKT 'import m_mk\ndef test_ok():\n    assert m_mk.fetch("http://stub.local/", timeout=5) == {"a": 1}'
mk 1 'requests.get beside len(fetch(u)) == 500: refused (a bare 500 is a length, not a status)' lib/m_mk.py "$HP" $MKT 'import m_mk\ndef test_ok():\n    assert len(m_mk.fetch("http://stub.local/")) == 500'
mk 1 'a file read beside a test whose only failure words are in a comment and a test name: refused' lib/m_mk.py "$FP" $MKT 'import m_mk\ndef test_missing_key():\n    # FileNotFoundError, chmod 000, /nonexistent, timeout, 500\n    assert m_mk.load("a") == "a"'
mk 1 'json.loads beside test_invalid_partial() that parses a valid list: refused (invalid / partial are names)' lib/m_mk.py 'import json\ndef p(s):\n    return json.loads(s)' $MKT 'import m_mk\ndef test_invalid_partial():\n    assert m_mk.p("[1]") == [1]'
mk 1 'a bash read beside a test that ends in "|| exit 1", echoes a JSON false and keeps its failure words in comments: refused' bin/m_mk.sh "$SHP" tests/m_mk.selftest.sh '#!/bin/bash\nbash m_mk.sh | grep -q x || exit 1\necho "{\\"ok\\": false}"\n# PATH=/nonexistent, command not found\ntrue'
mk 0 'control: subprocess.run answering returncode=3 (a CompletedProcess) is an injected failure' lib/m_mk.py "$MKP" $MKT 'import m_mk\nimport subprocess\ndef test_nonzero(monkeypatch):\n    monkeypatch.setattr(m_mk.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, returncode=3))\n    assert m_mk.f() is None'
mk 0 'control: requests.get answering status_code = 503 is an injected failure' lib/m_mk.py "$HP" $MKT 'import m_mk\nclass R:\n    status_code = 503\ndef test_down(monkeypatch):\n    monkeypatch.setattr(m_mk.requests, "get", lambda *a, **k: R())\n    assert m_mk.fetch("http://stub.local/") is None'
mk 0 'control: open patched with side_effect=PermissionError is an injected failure' lib/m_mk.py "$FP" $MKT 'import m_mk\ndef test_denied(mocker):\n    mocker.patch("builtins.open", side_effect=PermissionError)\n    assert m_mk.load("a") is None'
mk 0 'control: json.loads on a truncated literal is an injected failure' lib/m_mk.py 'import json\ndef p(s):\n    return json.loads(s)' $MKT "import m_mk\ndef test_cut():\n    assert m_mk.p('[1,') is None"
mk 0 'control: a bash stub function that returns 1 is an injected failure' bin/m_mk.sh "$SHP" tests/m_mk.selftest.sh '#!/bin/bash\ngit() { return 1; }\nbash m_mk.sh'
mk 0 'control: a stub script written with exit 3 is an injected failure' bin/m_mk.sh "$SHP" tests/m_mk.selftest.sh "#!/bin/bash\nprintf '#!/bin/sh\\\\nexit 3\\\\n' > bin/git\nbash m_mk.sh"

echo "== B5. what the check cannot read is said, not silently ok =="
newrepo b22; printf '#!/bin/bash\nout=$(git status --short)\n' | put bin/tool; commit r
chk; want 1 "a NEW extensionless executable is read by its shebang (bash)" "bin/tool:2 "
newrepo b23; printf '#!/usr/bin/env python3\nimport subprocess\nsubprocess.run(["x"])\n' | put bin/tool2; commit r
chk; want 1 "...and so is a python3 one" "bin/tool2:3 "
newrepo b24; printf 'all:\n\tcurl x\n' | put Makefile; printf 'x = 1\n' | put docs/y.py; printf 'a = 1\n' | put cfg.toml; commit r
chk; want 0 "files with no rules (Makefile, toml) and docs/ are counted and named, not silently ok" "NOTE: 3 changed file\\(s\\) NOT analysed.*Makefile"
printf '%s' "$OUT" | grep -q 'verdict=ok .*skipped=3' && ok "...and the verdict line carries skipped=3" || bad "verdict line lost skipped=: $(printf '%s' "$OUT" | tail -1)"
newrepo b25; printf 'package x\n// third-state-waiver: reads a packaged constant, cannot fail\nfunc f() { os.ReadFile("a") }\n' | put pkg/x.go; commit r
chk; want 0 "a waiver works on a line of a language with no rules (the author can clear the exit 2)" "waived  pkg/x.go:3"
newrepo b26; fx file prod | put lib/m_file.py; commit r; git -C "$R" config diff.noprefix true
chk; want 1 "diff.noprefix=true in the user's git config does not turn the branch into rc 2 (the prefixes are pinned)" "lib/m_file.py:2 "

echo "== C. modes, switches, arms =="
newrepo c1; fx file prod | put lib/m_file.py; commit r
rm -f "$STATE/third-state-reads.conf"; chk; want 0 "conf absent: not switched on, nothing checked" "not switched on"
conf mode=off; chk; want 0 "mode=off checks nothing" "mode=off"
conf mode=warn; chk; want 0 "mode=warn: the gap is listed (file:line), exit 0" "lib/m_file.py:2 "
printf '%s' "$OUT" | grep -q 'AVISO' && ok "warn prints AVISO, not REFUSED" || bad "warn lost the AVISO"
conf mode=warn; chk --base no-such-ref; want 0 "warn + could not tell: exit 0 but it SAYS NÃO SEI" "NÃO SEI"
printf '%s' "$OUT" | grep -q 'verdict=nao-sei' && ok "the raw verdict survives the mode" || bad "warn hid the could-not-tell verdict"
conf mode=enforce; chk; want 1 "mode=enforce refuses" "REFUSED"
conf enforce_pct=100; chk; want 1 "no mode key = enforce" "REFUSED"
for badconf in "modee=enforce" "mode=bogus" "enforce_pct=0" "enforce_pct=101" "enforce_pct=abc" "mode enforce" "# only a comment"; do
  conf "$badconf"; chk; want 2 "invalid conf '$badconf' is rc 2 (NÃO SEI), not off" "NÃO SEI"
done
: > "$STATE/third-state-reads.conf"; chk; want 2 "an EMPTY conf (what a failed write leaves) is rc 2, not off"
rm -f "$STATE/third-state-reads.conf"; mkdir "$STATE/third-state-reads.conf"; chk; want 2 "a conf that cannot be read is rc 2, not 'absent'"
rmdir "$STATE/third-state-reads.conf"; ln -s "$W/nowhere" "$STATE/third-state-reads.conf"; chk; want 2 "a dangling-symlink conf is there and unreadable: rc 2"
rm -f "$STATE/third-state-reads.conf"
conf mode=enforce; THIRD_STATE_READS_CHECK=off chk; want 0 "kill switch by env var" "switched OFF"
touch "$STATE/third-state-reads-check.off"; chk; want 0 "kill switch by flag file" "switched OFF"; rm -f "$STATE/third-state-reads-check.off"
chk; want 1 "...and enforce is back once the flag is gone"

# arms: 30 beads at 50%, on a branch that has a gap
conf mode=enforce enforce_pct=50
ENF=0; HOLD=0; i=0
while [ "$i" -lt 30 ]; do
  i=$((i+1)); chk --bead "ga-t$i"
  case "$OUT" in *"arm=enforce"*) ENF=$((ENF+1)); [ "$RC" = 1 ] || bad "ga-t$i enforce arm did not refuse (rc=$RC)" ;; *"arm=holdout"*) HOLD=$((HOLD+1)); [ "$RC" = 0 ] || bad "ga-t$i holdout arm refused (rc=$RC)" ;; *) bad "ga-t$i: no arm in the output" ;; esac
done
[ "$ENF" -ge 8 ] && [ "$HOLD" -ge 8 ] && ok "enforce_pct=50: both arms are drawn ($ENF enforce / $HOLD holdout of 30)" || bad "enforce_pct=50 drew $ENF enforce / $HOLD holdout"
[ "$(wc -l < "$STATE/third-state-reads-arms.jsonl" | tr -d ' ')" = 30 ] && ok "one line per bead (30)" || bad "arms file has $(wc -l < "$STATE/third-state-reads-arms.jsonl") lines, want 30"
HB="$(grep '"holdout"' "$STATE/third-state-reads-arms.jsonl" | head -1 | "$PY" -I -c 'import json,sys; print(json.loads(sys.stdin.readline())["bead"])')"
conf mode=enforce enforce_pct=100; chk --bead "$HB"; want 0 "the FIRST assignment wins: a recorded holdout stays holdout after the pct rises to 100" "arm=holdout"
[ "$(grep -c "\"$HB\"" "$STATE/third-state-reads-arms.jsonl")" = 1 ] && ok "...and the bead still has exactly one line" || bad "bead $HB has several lines"
conf "enforce_pct=50"; N0="$(wc -l < "$STATE/third-state-reads-arms.jsonl")"; chk --bead ga-norec --no-record; [ "$(wc -l < "$STATE/third-state-reads-arms.jsonl")" = "$N0" ] && ok "--no-record writes nothing" || bad "--no-record wrote a row"
chk; want 2 "enforce_pct<100 without a bead id: cannot draw, rc 2" "needs --bead"
"$PY" -I -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("r", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
st, arms, bad = m.arm_map(sys.argv[2]); assert st == "ok" and bad == 0 and len(arms) == 30 and set(arms.values()) == {"enforce", "holdout"}, (st, bad, len(arms))
' "$HERE/third-state-report.py" "$STATE/third-state-reads-arms.jsonl" 2>"$W/armmap.err" && ok "the arms file reads back through third-state-report.py's arm_map (30 beads, first line wins)" || bad "arm_map could not read it: $(cat "$W/armmap.err")"
conf mode=warn; rm -f "$STATE/third-state-reads-arms.jsonl"; chk --bead ga-w; [ ! -e "$STATE/third-state-reads-arms.jsonl" ] && ok "mode=warn draws no arm (nobody is enforced)" || bad "warn wrote an arms file"
conf "enforce_pct=50"
printf 'not json\n{"arm":"holdout"}\n{"bead":"ga-x","arm":"holdout"}\n{"bead":"ga-z","arm":"enforce"}' > "$STATE/third-state-reads-arms.jsonl"
chk --bead ga-x; want 0 "arms file with a corrupt line and a row missing the bead key: both skipped, ga-x still reads holdout" "arm=holdout"
chk --bead ga-y; [ "$(tail -c1 "$STATE/third-state-reads-arms.jsonl" | wc -l | tr -d ' ')" = 1 ] && [ "$(grep -c 'ga-y' "$STATE/third-state-reads-arms.jsonl")" = 1 ] && ok "a row appended after a line with no trailing newline lands on its own line" || bad "append glued rows: $(tail -2 "$STATE/third-state-reads-arms.jsonl")"
printf '{"bead": "ga-cx", "arm": "holdou\n{"bead": "ga-dx", "arm": "bogus"}\n' > "$STATE/third-state-reads-arms.jsonl"
chk --bead ga-cx; want 2 "a corrupt arms line that names the bead: rc 2, not a redraw at the current pct" "corrupt line that names ga-cx"
chk --bead ga-dx; want 2 "the bead's own row with an invalid arm: rc 2, not a redraw" "no valid arm"
chk --bead ga-other; printf '%s' "$OUT" | grep -q 'arm=' && ok "...while another bead is untouched by the corrupt line (an arm is drawn)" || bad "a corrupt line for ga-cx blocked ga-other: $OUT"
rm -f "$STATE/third-state-reads-arms.jsonl"; mkdir "$STATE/third-state-reads-arms.jsonl"; chk --bead ga-q; want 2 "arms file unreadable: rc 2, never 'enforce' by default" "arms file unreadable"
rmdir "$STATE/third-state-reads-arms.jsonl"
if [ "$(id -u)" != 0 ]; then chmod a-w "$STATE"; chk --bead ga-ro; want 2 "arm drawn but not recorded (state dir read-only): rc 2" "NOT recorded"; chmod u+w "$STATE"; else ok "(root: read-only state dir case skipped)"; fi
rm -f "$STATE/third-state-reads-arms.jsonl"; conf mode=enforce

echo "== D. controls: mutants of the checker that one case above must catch =="
mutate() { sed "$2" "$CHK" > "$W/mut-$1.py"; if cmp -s "$CHK" "$W/mut-$1.py"; then bad "mutant $1: the sed changed nothing (the control is void)"; return 1; fi; }
newrepo d1; fx file prod | put lib/m_file.py; commit r
mutate never 's/elif not covered(r, tests):/elif False:/' && { CHKX="$W/mut-never.py" chk; [ "$RC" = 0 ] && ok "control: a checker that never flags is caught (rc 0 where case A wants 1)" || bad "mutant 'never' still refused"; }
newrepo d2; fx file prod | put lib/m_file.py; printf 'def test_unreadable_other():\n    assert other_load("/nope") is None   # unreadable\n' | put tests/test_other.py; commit r
mutate unlinked 's/(s in tp or s in raw) and //' && { CHKX="$W/mut-unlinked.py" chk; [ "$RC" = 0 ] && ok "control: a checker that ignores which file a test names is caught (case B2)" || bad "mutant 'unlinked' still refused"; }
newrepo d3; fx file prod | put lib/m_file.py; fx file happy | put tests/test_m_file.py; commit r
mutate anytest 's/re.search(FAILS\[kind\], code, re.I | re.M)/True/' && { CHKX="$W/mut-anytest.py" chk; [ "$RC" = 0 ] && ok "control: a checker that takes any touched test as a failure test is caught" || bad "mutant 'anytest' still refused"; }
mutate cantok 's/return 1 if findings else 2 if cant else 0/return 1 if findings else 0/' && { CHKX="$W/mut-cantok.py" chk --base no-such-ref; [ "$RC" = 0 ] && ok "control: 'could not tell' turned into ok is caught (case B: rc 2)" || bad "mutant 'cantok' still said 2"; }
conf "modee=enforce"; mutate confabsent 's/return "invalid:" + line, None, None/return "absent", None, None/' && { CHKX="$W/mut-confabsent.py" chk; [ "$RC" = 0 ] && ok "control: an invalid conf read as 'absent' is caught (case C: rc 2)" || bad "mutant 'confabsent' still said 2"; }
conf "enforce_pct=50"; rm -f "$STATE/third-state-reads-arms.jsonl"; mutate redraw 's/d.get("bead") == bead:/d.get("bead") == "nobody":/' && { CHKX="$W/mut-redraw.py" chk --bead ga-m; CHKX="$W/mut-redraw.py" chk --bead ga-m; [ "$(grep -c ga-m "$STATE/third-state-reads-arms.jsonl")" = 2 ] && ok "control: a checker that re-draws instead of reading the first line is caught (2 rows for one bead)" || bad "mutant 'redraw' kept one row"; }
rm -f "$STATE/third-state-reads-arms.jsonl"; conf mode=enforce
pmutate() { "$PY" -I -c 'import sys; s = open(sys.argv[1], encoding="utf-8").read(); assert s.count(sys.argv[3]) == 1; open(sys.argv[2], "w", encoding="utf-8").write(s.replace(sys.argv[3], sys.argv[4]))' "$CHK" "$W/mut-$1.py" "$2" "$3" || { bad "mutant $1: the text was not found exactly once (the control is void)"; return 1; }; }
R="$W/repo-b11"; pmutate dbwrite 'execute\(", db_not_read),' 'execute\(", None),' && { CHKX="$W/mut-dbwrite.py" chk; [ "$RC" = 1 ] && ok "control: a checker that counts SQL writes as reads is caught (case B2: rc 1 where 0 is wanted)" || bad "mutant 'dbwrite' still said $RC"; }
R="$W/repo-b21"; pmutate dbany 'all(re.match(SQL_WRITE, probe[e:], re.I) for e in ends)' 'any(re.match(SQL_WRITE, probe[e:], re.I) for e in ends)' && { CHKX="$W/mut-dbany.py" chk; [ "$RC" = 0 ] && ok "control: a checker where ONE write on the line hides the other execute calls is caught (case B2: rc 0 where 1 is wanted)" || bad "mutant 'dbany' still said $RC"; }
R="$W/repo-b15"; pmutate pipe '(^\s*|;\s*|&&\s*|\|\|\s*|\bdo\s+|\bthen\s+)' '(^|[;&|]\s*|\bdo\s+)' && { CHKX="$W/mut-pipe.py" chk; [ "$RC" = 1 ] && ok "control: a checker that reads head/tail on a pipe as a file is caught (case B2)" || bad "mutant 'pipe' still said $RC"; }
R="$W/repo-b17"; pmutate docs '|dist|build|docs|retired)/' '|dist|build)/' && { CHKX="$W/mut-docs.py" chk; [ "$RC" = 1 ] && ok "control: a checker that treats docs/ code as production is caught (case B2)" || bad "mutant 'docs' still said $RC"; }
R="$W/repo-sh1"; pmutate openline 'return bool(calls) and all(writes_only(call_args(probe, e), pos) for e, pos in calls)' 'return bool(re.search(r"open\([^)]*[\x27\"][wax]", code))' && { CHKX="$W/mut-openline.py" chk; [ "$RC" = 0 ] && ok "control: the old line-level 'a quoted w/a/x inside open(...)' exclusion is caught (case B3: open(\"agents.toml\") reported ok)" || bad "mutant 'openline' still said $RC"; }
newrepo d7; printf '%b\n' "$MKP" | put lib/m_mk.py; printf '%b\n' 'import m_mk\ndef test_ok():\n    assert m_mk.f().returncode == 0' | put "$MKT"; commit r
pmutate cmdword '\b(?:returncode|exit_?code|rc)\s*(?:!=\s*0|>\s*0|==?\s*[1-9]|:\s*[1-9])' '\breturncode' && { CHKX="$W/mut-cmdword.py" chk; [ "$RC" = 0 ] && ok "control: the bare word returncode as a failure marker is caught (case B4: rc 0 where 1 is wanted)" || bad "mutant 'cmdword' still said $RC"; }
newrepo d8; printf '%b\n' "$HP" | put lib/m_mk.py; printf '%b\n' 'import m_mk\ndef test_ok():\n    assert len(m_mk.fetch("http://stub.local/")) == 500' | put "$MKT"; commit r
pmutate httpword '(?:status(?:_code)?|http_code)\W{1,4}[45]\d\d\b' '\b[45]\d\d\b' && { CHKX="$W/mut-httpword.py" chk; [ "$RC" = 0 ] && ok "control: a bare 4xx/5xx number as a failure marker is caught (case B4)" || bad "mutant 'httpword' still said $RC"; }
newrepo d9; printf '%b\n' "$FP" | put lib/m_mk.py; printf '%b\n' 'import m_mk\ndef test_missing_key():\n    # FileNotFoundError, chmod 000, /nonexistent\n    assert m_mk.load("a") == "a"' | put "$MKT"; commit r
pmutate nostrip 're.search(FAILS[kind], code, re.I | re.M)' 're.search(FAILS[kind], raw, re.I | re.M)' && { CHKX="$W/mut-nostrip.py" chk; [ "$RC" = 0 ] && ok "control: markers matched in comments is caught (case B4: a failure word in a comment is not an injection)" || bad "mutant 'nostrip' still said $RC"; }
R="$W/repo-b26"; pmutate prefix '"--src-prefix=a/", "--dst-prefix=b/", ' '' && { CHKX="$W/mut-prefix.py" chk; [ "$RC" = 2 ] && ok "control: an unpinned diff prefix is caught (case B5: rc 2 with diff.noprefix where 1 is wanted)" || bad "mutant 'prefix' still said $RC"; }
R="$W/repo-c1"; conf enforce_pct=50; printf '{"bead": "ga-cx", "arm": "holdou\n' > "$STATE/third-state-reads-arms.jsonl"
pmutate armcorrupt 'if json.dumps(bead) in line:' 'if False:' && { CHKX="$W/mut-armcorrupt.py" chk --bead ga-cx; [ "$RC" != 2 ] && ok "control: a corrupt arms line silently skipped (a redraw) is caught (case C: rc 2 wanted)" || bad "mutant 'armcorrupt' still said 2"; }
rm -f "$STATE/third-state-reads-arms.jsonl"; conf mode=enforce

echo "== E. wiring: step 2e of the gate formula, extracted and run; gate-done.md =="
STEP="$W/step2e.sh"
awk '/SELFTEST-EXTRACT third-state-reads-step2e: BEGIN/{f=1;next} /SELFTEST-EXTRACT third-state-reads-step2e: END/{f=0} f' "$FORMULA" | sed 's/{{bead_id}}/ga-fixture/' > "$STEP"
[ -s "$STEP" ] && ok "step 2e is in the formula, between its SELFTEST-EXTRACT markers" || bad "step 2e not found in $FORMULA"
[ "$(grep -c '[\\]' "$STEP")" = 0 ] && ok "the snippet has no backslash (a TOML triple-quoted string would eat it)" || bad "the snippet contains a backslash"
/bin/bash -n "$STEP" && ok "the snippet parses under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION'))" || bad "the snippet does not parse under /bin/bash"
"$PY" -I -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); assert "third-state-reads-check.py" in str(d)' "$FORMULA" 2>"$W/toml.err" && ok "the formula is still valid TOML and names the script" || bad "formula TOML: $(cat "$W/toml.err")"
[ "$(grep -c 'SELFTEST-EXTRACT third-state-reads-step2e: BEGIN' "$FORMULA")" = 1 ] && ok "step 2e appears once" || bad "step 2e marker count is not 1"
CITY="$W/city"; mkdir -p "$CITY/packs/town-deltas/assets" "$CITY/.gc"; cp "$CHK" "$CITY/packs/town-deltas/assets/"
cwconf() { rm -f "$CITY/.gc/third-state-reads.conf"; printf '%s\n' "$@" > "$CITY/.gc/third-state-reads.conf"; }
STEP_TE=""
runstep() {   # runstep <shell> [VAR=val ...]: the hard-gate variables in, TEST_EXIT / TEST_OUTPUT out
  local sh="$1"; shift
  ( cd "$R" && env -u THIRD_STATE_READS_STATE_DIR WORKTREE_PATH="$R" GC_CITY_PATH="$CITY" CHANGED_FILES="lib/m_file.py" TEST_EXIT="${TE0:-0}" TEST_OUTPUT="" "$@" \
      "$sh" -c '. "$1"; echo "TEST_EXIT=$TEST_EXIT"; echo "---"; echo "$TEST_OUTPUT"' x "$STEP" ) > "$W/step.out" 2>&1
  OUT="$(cat "$W/step.out")"; STEP_TE="$(sed -n 's/^TEST_EXIT=//p' "$W/step.out" | tail -1)"
}
stepwant() { if [ "$STEP_TE" != "$1" ]; then bad "$2: TEST_EXIT=$STEP_TE, want $1 :: $(printf '%s' "$OUT" | head -4 | tr '\n' '|')"; elif [ -n "${3:-}" ] && ! printf '%s' "$OUT" | grep -Eq -- "$3"; then bad "$2: no /$3/ :: $(printf '%s' "$OUT" | head -4 | tr '\n' '|')"; else ok "$2"; fi; }
newrepo e1; fx file prod | put lib/m_file.py; commit r
cwconf mode=enforce
for sh in /bin/bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "  SKIP $sh not installed"; continue; }
  runstep "$sh"; stepwant 1 "[$sh] a read with no failure test fails the gate (TEST_EXIT=1)" "THIRD-STATE READS CHECK FAILED.*"
  printf '%s' "$OUT" | grep -q 'lib/m_file.py:2' && ok "[$sh] ...and TEST_OUTPUT lists file:line" || bad "[$sh] file:line missing from TEST_OUTPUT"
done
grep -q '"ga-fixture"' "$CITY/.gc/third-state-reads-arms.jsonl" 2>/dev/null && ok "the step passes the gate's bead id: the arm row is for it" || bad "no arm row for the fixture bead (--bead not wired)"
fx file fail | put tests/test_m_file.py; commit t
runstep /bin/bash; stepwant 0 "with the failure test the step leaves TEST_EXIT alone" "ok --"
TE0=3 runstep /bin/bash; stepwant 3 "a prior failure (3) is kept when this check passes"
git -C "$R" reset -q --hard HEAD~1; TE0=0 runstep /bin/bash; stepwant 1 "(back to the gap) fails again"
cwconf mode=warn; runstep /bin/bash; stepwant 0 "mode=warn: listed, TEST_EXIT untouched" "AVISO"
cwconf mode=enforce; runstep /bin/bash THIRD_STATE_READS_CHECK=off; stepwant 0 "kill switch by env var is a loud no-op" "switched OFF"
touch "$CITY/.gc/third-state-reads-check.off"; runstep /bin/bash; stepwant 0 "kill switch by flag file is a loud no-op" "switched OFF"; rm -f "$CITY/.gc/third-state-reads-check.off"
cwconf "modee=enforce"; runstep /bin/bash; stepwant 2 "an invalid conf fails the gate with 2 (could not tell)" "NÃO SEI"
cwconf mode=enforce; git -C "$R" update-ref -d refs/remotes/origin/main; runstep /bin/bash; stepwant 2 "no origin/main in the worktree: 2, not 'no diff'"
git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$R" rev-list --max-parents=0 HEAD)"
mv "$CITY/packs/town-deltas/assets/third-state-reads-check.py" "$W/stash.py"; runstep /bin/bash; stepwant 0 "script absent from city and branch: fail-soft NOTE" "not found in the city or the branch"
printf 'import sys\nprint("Traceback: boom")\nsys.exit(1)\n' > "$CITY/packs/town-deltas/assets/third-state-reads-check.py"; runstep /bin/bash; stepwant 2 "a crashed script (exit 1 with no verdict line) is 2, never a finding" "FAILED"
runstep /bin/bash THIRD_STATE_READS_CHECK=off; stepwant 0 "...and the kill switch still gets a crashed script out of the way" "switched OFF"
mv "$W/stash.py" "$CITY/packs/town-deltas/assets/third-state-reads-check.py"
mkdir -p "$R/.gascity-gastown-hq/packs/town-deltas/assets"; cp "$CHK" "$R/.gascity-gastown-hq/packs/town-deltas/assets/"; printf 'import sys\nsys.exit(0)\n' > "$CITY/packs/town-deltas/assets/third-state-reads-check.py"
runstep /bin/bash; stepwant 0 "the city's copy is used before the branch's (a branch cannot weaken its own judge)"
GD_LINE="$(grep -n 'third-state-reads-check.py' "$GATE_DONE" | head -1 | cut -d: -f1)"
AUDIT="$(grep -n '^## Pre-flight Self-Audit: THE THIRD STATE' "$GATE_DONE" | head -1 | cut -d: -f1)"; STEP1="$(grep -n '^## Step 1: Push your branch' "$GATE_DONE" | head -1 | cut -d: -f1)"
[ -n "$GD_LINE" ] && [ -n "$AUDIT" ] && [ -n "$STEP1" ] && [ "$GD_LINE" -gt "$AUDIT" ] && [ "$GD_LINE" -lt "$STEP1" ] && ok "gate-done.md runs the check after the third-state self-audit and before Step 1" || bad "gate-done.md: check at line '$GD_LINE', audit '$AUDIT', step 1 '$STEP1'"
grep -q '^## Pre-flight Check: NEW READS NEED A FAILURE TEST' "$GATE_DONE" && sed -n '/^## Contents/,/^## [^C]/p' "$GATE_DONE" | grep -q 'NEW READS NEED A FAILURE TEST' && ok "gate-done.md: the section exists and is listed under ## Contents" || bad "gate-done.md: section or its Contents entry missing"
if [ -f "$GATE_DONE_BODY" ]; then cmp -s "$GATE_DONE" "$GATE_DONE_BODY" && ok "internal/templates/commands/bodies/gate-done.md is byte-identical to the city copy" || bad "the two gate-done.md copies differ"
else echo "  SKIP $GATE_DONE_BODY not present in this tree (parity checked where the repo is)"; fi

echo "selftest: $PASS passed, $FAILN failed"
REACHED_END=1
[ "$FAILN" = 0 ]
