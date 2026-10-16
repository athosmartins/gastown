#!/usr/bin/env python3
"""third-state-reads-check.py — ga-57e7l0.1 (fatia 2/3 of ga-57e7l0): /gate-done refuses a NEW failable read that no test makes fail.

Why: "could not read" handled as empty/zero is 6 of the 7 first-attempt rejections (14/10 baseline). Prose (the E12 doctrine) did not move first-attempt
approval (59% with vs 62% without), so the gate must refuse. This is the "has a failure test?" layer: error-empty-conflation-scan.sh judges HOW a script
handles a failed read (whole files, report-only); this reads only the ADDED lines of `git diff base...head`, finds the new reads, and asks per read whether
a test touched by the same diff makes that KIND of read fail (unreadable/missing file, corrupt JSON, failing command, locked or missing db, dead URL).
NOT reads (calibration on 90 real branches): a dict .get() (51 of the 122 first-pass flags), SQL that writes or configures, head/tail/cat on a pipe, a
heredoc write, code under docs/. Coverage is per FILE and KIND (a touched test that names the file and carries a failure marker for that kind), not per
read: the known limit, and why a waiver names its reason.
Exclusions are decided per CALL, never per line (a write-mode open() or an INSERT beside a read hides nothing). A failure marker is an INJECTION (an
exception raised or caught, a non-zero literal, a missing path, a stub that fails), never a bare word a happy-path test also contains (returncode,
timeout, 500, missing) and never a comment. It reads only what it recognises: files it has no rules for are counted and named, never silently ok.
A read that cannot meaningfully fail is waived on its line (or the line above) with  third-state-waiver: <reason of 10+ chars>  — listed, never silent.

Modes (<state>/third-state-reads.conf; the file is born ABSENT = not switched on, the Mayor writes it):  mode=enforce|warn|off  and  enforce_pct=1..100.
  enforce  exit = the verdict.   warn  prints the verdict, exits 0.   off  checks nothing.   enforce_pct<100: a bead is in the "enforce" arm or the
  "holdout" arm (checked like warn) by SHA-256("third-state-reads:<bead>") mod 100; the first assignment is recorded in <state>/third-state-reads-arms.jsonl
  as {"bead","arm"} and wins forever. Kill switch: THIRD_STATE_READS_CHECK=off or the flag file <state>/third-state-reads-check.off (loud no-op).
Exit: 0 ok / not on / warn / holdout, 1 = a read without a failure test (file:line listed), 2 = COULD NOT TELL (bad diff or base, unsupported language,
invalid conf, arm unknown or unrecorded). "Could not tell" is never printed as ok and never as an arm.
"""
import argparse
import errno
import hashlib
import json
import os
import re
import subprocess
import sys
import time

CONF, ARMS, KILL, SALT = "third-state-reads.conf", "third-state-reads-arms.jsonl", "third-state-reads-check.off", "third-state-reads"
MODES = ("enforce", "warn", "off")
SKIP_RE = re.compile(r"(^|/)(vendor|node_modules|\.gc-worktrees|\.beads|dist|build|docs|retired)/|[.]min[.]js$")
TEST_RE = re.compile(r"(^|/)(tests?|__tests__|spec|prod-tests)/|(^|/)test_[^/]*$|[._-](test|spec|selftest)[.][^/]*$")
LANG = {".py": "py", ".sh": "sh", ".bash": "sh", ".zsh": "sh"}
OTHER_CODE = (".go", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".rb", ".java", ".rs", ".c", ".cc", ".cpp", ".h", ".php", ".swift", ".kt", ".pl", ".lua")
GENERIC = re.compile(r"os\.Open\(|ReadFile\(|readFileSync|exec\.Command\(|http\.(Get|Post)\(|sql\.Open\(|Unmarshal\(|child_process|fetch\(|JSON\.parse\(|File\.read|open\(")
WAIVER = re.compile(r"third-state-waiver:\s*(\S.{9,})")

# a statement that WRITES or configures (DDL, INSERT/UPDATE/DELETE, SET, non-schema PRAGMA) is not a read; matched at the text right after each `.execute(`
# (the SQL may sit on the next added line). It is judged per call: one INSERT on a line does not hide a SELECT or a fetch beside it.
SQL_WRITE = r"\s*[rbfu]{0,2}(\"\"\"|\'\'\'|\"|\')\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|REPLACE|SET|BEGIN|COMMIT|ROLLBACK|VACUUM|ATTACH|DETACH|PRAGMA\s+(?!table_x?info|index_list|foreign_key_list))\b"
OPEN_RE = r"(?<![\w.])open\(|\b(?:gzip|bz2|lzma|io|codecs)\.open\("   # open(file, mode); Path(p).open(mode) takes the mode first (PATH_OPEN)
PATH_OPEN = r"\)\.open\("
OTHER_FILE = r"\.(read_text|read_bytes)\(|\bos\.(walk|listdir|scandir)\(|\bglob\.i?glob\(|\.(iterdir|rglob)\("
DB_READ = r"\bsqlite3\.connect\(|\.(fetchall|fetchone|fetchmany)\("


def strip_comments(s):
    """The code part of a line: a '#' outside quotes, at the start or after whitespace, begins a comment."""
    q = ""
    for i, c in enumerate(s):
        if q:
            q = "" if c == q and s[i - 1] != "\\" else q
        elif c in "\"'":
            q = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i]
    return s


def call_args(s, i):
    """Top-level arguments of the call whose '(' ends just before s[i]; None when it never closes in s (then the caller treats it as a read)."""
    args, cur, depth, q, k = [], "", 0, "", i
    while k < len(s):
        c = s[k]
        if q:
            if c == "\\":
                cur, k = cur + s[k:k + 2], k + 1
            else:
                cur, q = cur + c, "" if c == q else q
        elif c in "\"'":
            cur, q = cur + c, c
        elif c in "([{":
            cur, depth = cur + c, depth + 1
        elif c in ")]}" and depth:
            cur, depth = cur + c, depth - 1
        elif c == ")":
            return args + [cur.strip()] if cur.strip() else args
        elif c == "," and not depth:
            args, cur = args + [cur.strip()], ""
        else:
            cur += c
        k += 1
    return None


def writes_only(args, pos):
    """open() writes (and so reads nothing) only when its MODE argument -- mode= or the positional at `pos` -- is a string literal that starts with w, a or x.
    No mode, a variable, r / rb / r+, or a call that never closes is a read; a quoted 'w' elsewhere in the arguments (a filename) is not a mode."""
    if args is None:
        return False
    named = [a.split("=", 1)[1].strip() for a in args if re.match(r"mode\s*=(?!=)", a)]
    plain = [a for a in args if not re.match(r"[A-Za-z_]\w*\s*=(?!=)", a)]
    mode = named[0] if named else plain[pos] if len(plain) > pos else ""
    return bool(re.fullmatch(r"""(["'])[bt]*[wax][^"']*\1""", mode))


def file_not_read(code, probe):
    if re.search(OTHER_FILE, code):
        return False
    calls = [(m.end(), 1) for m in re.finditer(OPEN_RE, code)] + [(m.end(), 0) for m in re.finditer(PATH_OPEN, code)]
    return bool(calls) and all(writes_only(call_args(probe, e), pos) for e, pos in calls)


def db_not_read(code, probe):
    if re.search(DB_READ, code):
        return False
    ends = [m.end() for m in re.finditer(r"[.]execute\(", code)]
    return bool(ends) and all(re.match(SQL_WRITE, probe[e:], re.I) for e in ends)


# (kind, pattern that makes a line a read, f(code, probe) -> True when the line is NOT a read after all). `code` is the line without its comment, `probe` is
# `code` plus up to 3 following added lines (a wrapped call), so every exclusion is judged on the call, not on the line.
READS = {
    "py": (
        ("file", OPEN_RE + "|" + PATH_OPEN + "|" + OTHER_FILE, file_not_read),
        ("parse", r"\b(json|tomllib|yaml|pickle|plistlib)\.(loads?|safe_load)\(", None),
        ("cmd", r"\bsubprocess\.(run|check_output|check_call|call|Popen|getoutput|getstatusoutput)\(|\bos\.(popen|system)\(", None),
        ("db", DB_READ + r"|[.]execute\(", db_not_read),
        ("http", r"\burlopen\(|\brequests\.(get|post|put|delete|head|request)\(|\bhttpx\.|\bhttp\.client\.|\bcreate_connection\(", None),
    ),
    "sh": (
        ("cmd", r"[$][(]\s*(cat|jq|grep|egrep|sed|awk|head|tail|curl|wget|sqlite3|dolt|bd|gc|git|gh|python3?|find|stat|wc|cut|sort|ssh|aws|mysql|ls)(\s|[)]|$)", None),
        ("file", r"(^\s*|;\s*|&&\s*|\|\|\s*|\bdo\s+|\bthen\s+)(cat|head|tail)\s+(-\S+\s+)*[^\s|;&<>-]|\bread\b[^<]*<\s*[^<(&\s]|\bdone\s*<\s*[^<(&\s]", None),
    ),
}

# what, in the ADDED lines of a test (comments stripped) that names the file, counts as making that kind of read fail: an INJECTION, not a mention.
# Not markers, because happy-path tests contain them: returncode == 0, timeout=5, a bare 4xx/5xx, missing, invalid, partial, rm -f, exit N, "false" in JSON.
SIDE = r"side_effect\s*=\s*[\w.]*(?:Error|Exception|Expired|Timeout)\b"
NOFILE = r"""["'/][^"'\s]*(?:nonexist|inexist|no[-_/]?such|does[-_]?not[-_]?exist|n[aã]o[-_/]?existe|absent|ausente|/dev/null/|/nope\b|/nowhere\b|missing[\w-]*[.]\w{2,4}\b)"""
GARBAGE = r"""["'][^"'\n]*(?:garbage|corrupt|truncated|malformed|not[-_ ]?json|\{\{\{)|(?:echo|printf)\s[^|;&\n]*(?:garbage|corrupt|truncated|malformed|notjson)"""
FAILS = {k: "|".join((SIDE,) + v) for k, v in {
    "file": (r"FileNotFoundError|PermissionError|IsADirectoryError|NotADirectoryError|OSError|IOError|ENOENT|EACCES", NOFILE,
             r"chmod\s+(?:0+|[ugoa]*-[rwx]+)\b|os\.chmod\([^)]*\b0(?:o0+)?\s*\)"),
    "parse": (r"JSONDecodeError|ValueError|ParseError|TOMLDecodeError|YAMLError|UnpicklingError|ExpatError|UnicodeDecodeError", GARBAGE,
              r"""(["'])[\[{](?:(?!\1)[^\]}\n])*\1"""),
    "cmd": (r"CalledProcessError|TimeoutExpired|SubprocessError|FileNotFoundError|PermissionError|OSError",
            r"\b(?:returncode|exit_?code|rc)\s*(?:!=\s*0|>\s*0|==?\s*[1-9]|:\s*[1-9])|\$\?\s*(?:-ne|!=)\s*0|\$\?\s*(?:=|==|-eq)\s*[1-9]",
            r"\(\)\s*\{[^}]*\b(?:false|(?:return|exit)\s+[1-9])", r"\breturn\s+\(?\s*[1-9]\d*\s*,", r"(?:printf|echo)\b[^\n]*exit\s+[1-9]",
            r"<<-?\s*[\"']?(\w+)[\"']?[^\n]*\n(?:(?![ \t]*\1[ \t]*$)[^\n]*\n)*?[ \t]*exit\s+[1-9]", r"^\s*false\s*$", r"command not found",
            r"""PATH=["']?[^:\s"']*(?:nonexist|empty|nobin|no[-_]?such|/dev/null)|PATH=["']?(?=\s|$|["'])"""),
    "db": (r"OperationalError|DatabaseError|sqlite3\.Error|database is locked|database disk image is malformed|not a database|no such table|unable to open database|"
           r"read-?only database|BEGIN\s+(?:EXCLUSIVE|IMMEDIATE)", NOFILE, GARBAGE),
    "http": (r"URLError|HTTPError|HTTPStatusError|ConnectionError|ConnectionRefusedError|ConnectionResetError|TimeoutError|socket\.timeout|gaierror|ReadTimeout|"
             r"ConnectTimeout|RemoteDisconnected|requests\.exceptions|timed out|connection refused|name or service not known|network is unreachable",
             r"(?:status(?:_code)?|http_code)\W{1,4}[45]\d\d\b|\bHTTP/\d(?:[.]\d)?\s+[45]\d\d\b|send_(?:response|error)\(\s*[45]\d\d",
             r"""https?://[^\s"']*(?:localhost:[01]\b|127[.]0[.]0[.]1:[01]\b|nonexist\w*|[.]invalid\b|unreachable)"""),
}.items()}


class Cant(Exception):
    """The check could not be decided: becomes exit 2, never ok."""


def git_diff(repo, base, head):
    # vazio → diff vazio = a branch não muda nada (rc 0 legítimo); falhou/ilegível (sem git, base inexistente, timeout) → Cant, nunca "diff vazio"
    cmd = ["git", "-C", repo, "-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--unified=0", "%s...%s" % (base, head)]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise Cant("git diff could not run: %s" % e)
    if p.returncode != 0:
        raise Cant("git diff %s...%s failed in %s (rc %d): %s" % (base, head, repo, p.returncode, p.stderr.decode("utf-8", "replace").strip()[:200]))
    return p.stdout.decode("utf-8", "replace")


def parse_diff(text):
    """-> ({path: [(lineno, text)]}, unparsed). Only added lines; a '+' line outside any known file is counted in unparsed (-> Cant)."""
    files, cur, ln, hunk, bad = {}, None, 0, False, 0
    for line in text.splitlines():
        if line.startswith("diff --git "):
            cur, hunk = None, False
        elif not hunk and line.startswith("+++ "):
            p = line[4:].split("\t")[0]
            if p.startswith("b/"):
                cur = p[2:]
                files.setdefault(cur, [])
            elif p != "/dev/null":
                bad += 1
        elif line.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)", line)
            hunk, ln = True, int(m.group(1)) if m else 0
            bad += 0 if m else 1
        elif hunk and line.startswith("+"):
            if cur is None:
                bad += 1
            else:
                files[cur].append((ln, line[1:]))
            ln += 1
    return files, bad


def lang_of(path, added):
    """py / sh / other-code / "" by extension; a NEW extensionless file by its shebang (first added line is line 1)."""
    ext = os.path.splitext(path)[1]
    if ext in LANG:
        return LANG[ext]
    m = re.match(r"#!.*\b(python|bash|zsh|sh)\d*\b", added[0][1]) if not ext and added and added[0][0] == 1 else None
    return "" if not m else "py" if m.group(1) == "python" else "sh"


def waiver_of(t, before):
    w = WAIVER.search(t) or WAIVER.search(before)
    return w.group(1).strip() if w else ""


def find_reads(files):
    """-> (reads [(path, line, kind, text, waiver)], tests {path: (text, text without comments)}, unsupported [(path, line)], not_analysed [path])."""
    reads, tests, unsup, skipped = [], {}, [], []
    for path in sorted(files):
        added = files[path]
        if SKIP_RE.search(path):
            skipped.append(path)
            continue
        if TEST_RE.search(path):
            tests[path] = ("\n".join(t for _, t in added), "\n".join(strip_comments(t) for _, t in added))
            continue
        ext, lang = os.path.splitext(path)[1], lang_of(path, added)
        prev, text_of, nu = {}, dict(added), 0
        if ext in OTHER_CODE:
            for n, t in added:
                prev[n] = t
                if GENERIC.search(t):
                    w = waiver_of(t, prev.get(n - 1, ""))
                    if w:
                        reads.append((path, n, "other", t.strip(), w))
                    elif nu < 3:
                        unsup.append((path, n))
                        nu += 1
            continue
        if not lang:
            skipped.append(path)
            continue
        for n, t in added:
            prev[n] = t
            if t.lstrip().startswith("#"):
                continue
            code, nxt = strip_comments(t), []
            while len(nxt) < 3 and n + len(nxt) + 1 in text_of:
                nxt.append(strip_comments(text_of[n + len(nxt) + 1]))
            probe = " ".join([code] + nxt)
            for kind, inc, notread in READS[lang]:
                if re.search(inc, code) and not (notread and notread(code, probe)):
                    reads.append((path, n, kind, t.strip(), waiver_of(t, prev.get(n - 1, ""))))
    return reads, tests, unsup, skipped


def stem(path):
    return re.sub(r"[.](py|sh|bash|zsh)$", "", os.path.basename(path))


def covered(read, tests):
    path, _, kind, _, _ = read
    s = stem(path)
    return any((s in tp or s in raw) and re.search(FAILS[kind], code, re.I | re.M) for tp, (raw, code) in tests.items())


def load_conf(state):
    """-> (st, mode, pct); st = absent | ok | unreadable | invalid:<why>."""
    # vazio → arquivo vazio/só comentários = invalid:no-keys (é o que um write falho deixa; não liga nada em silêncio); falhou/ilegível → unreadable/invalid, nunca "absent"
    path = os.path.join(state, CONF)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return ("unreadable", None, None) if os.path.islink(path) else ("absent", None, None)
    except (OSError, ValueError):
        return "unreadable", None, None
    mode, pct, seen = "enforce", 100, 0
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        k, eq, v = (x.strip() for x in line.partition("="))
        seen += 1
        if k == "mode" and v in MODES:
            mode = v
        elif k == "enforce_pct" and re.fullmatch(r"[0-9]{1,3}", v) and 1 <= int(v) <= 100:
            pct = int(v)
        else:
            return "invalid:" + line, None, None
    return ("ok", mode, pct) if seen else ("invalid:no-keys", None, None)


def arm_of(state, bead, pct, record):
    """-> (arm, why). arm None = could not tell. The first recorded line of the bead wins; a new draw is appended before it is returned."""
    path = os.path.join(state, ARMS)
    # vazio → arquivo ausente/vazio = ninguém registrado ainda; falhou/ilegível → (None, why), nunca "enforce" por omissão
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        raw = b""
    except OSError as e:
        return None, "arms file unreadable (%s)" % (e.strerror or errno.errorcode.get(e.errno, "?"))
    for line in raw.decode("utf-8", "replace").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            if json.dumps(bead) in line:
                return None, "arms file has a corrupt line that names %s (repair or remove it; a redraw could flip a recorded holdout)" % bead
            continue
        if isinstance(d, dict) and d.get("bead") == bead:
            if d.get("arm") in ("enforce", "holdout"):
                return d["arm"], ""
            return None, "arms file: the row of %s has no valid arm (repair or remove it)" % bead
    arm = "enforce" if int(hashlib.sha256((SALT + ":" + bead).encode()).hexdigest()[:8], 16) % 100 < pct else "holdout"
    if record:
        row = json.dumps({"bead": bead, "arm": arm, "pct": pct, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}) + "\n"
        try:
            with open(path, "ab") as fh:
                fh.write((b"\n" if raw and not raw.endswith(b"\n") else b"") + row.encode())
        except OSError as e:
            return None, "arm %s drawn but NOT recorded (%s)" % (arm, e.strerror)
    return arm, ""


def killed(state):
    if os.environ.get("THIRD_STATE_READS_CHECK") == "off":
        return "THIRD_STATE_READS_CHECK=off"
    # vazio → flag ausente = a checagem não foi desligada; falhou/ilegível (stat negado) → roda a checagem, o lado seguro, nunca "desligada"
    try:
        os.stat(os.path.join(state, KILL))
        return "flag file " + os.path.join(state, KILL)
    except FileNotFoundError:
        return ""
    except OSError:
        print("NOTE: third-state-reads-check could not stat its kill-switch flag; running the check (the safe side).")
        return ""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=".")
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--bead", default="")
    ap.add_argument("--city", default=os.environ.get("GC_CITY") or os.environ.get("GC_CITY_PATH") or "/Users/athos/gt/.gascity-gastown-hq")
    ap.add_argument("--no-record", action="store_true")
    a = ap.parse_args()
    state = os.environ.get("THIRD_STATE_READS_STATE_DIR") or os.path.join(a.city, ".gc")
    tag = "third-state-reads-check:"

    why = killed(state)
    if why:
        print("NOTE: %s is switched OFF (%s) -- nothing checked." % (tag, why))
        return 0
    st, mode, pct = load_conf(state)
    if st == "absent":
        print("NOTE: %s not switched on (no %s/%s) -- nothing checked." % (tag, state, CONF))
        return 0
    if st != "ok":
        print("%s NÃO SEI -- %s/%s is %s. Fix or remove it (or kill-switch: THIRD_STATE_READS_CHECK=off). Not ok, not refused on the code." % (tag, state, CONF, st))
        return 2
    if mode == "off":
        print("NOTE: %s mode=off in %s -- nothing checked." % (tag, CONF))
        return 0

    arm = "-"
    if mode == "enforce":
        if not a.bead and pct < 100:
            print("%s NÃO SEI -- enforce_pct=%d needs --bead to draw the arm; none given." % (tag, pct))
            return 2
        if a.bead:
            arm, why = arm_of(state, a.bead, pct, not a.no_record)
            if arm is None:
                print("%s NÃO SEI -- %s." % (tag, why))
                return 2
        else:
            arm = "enforce"
    eff = "warn" if mode == "warn" or arm == "holdout" else "enforce"

    cant, findings, waived, nreads, skipped = [], [], [], 0, []
    try:
        files, bad = parse_diff(git_diff(a.repo, a.base, a.head))
        if bad:
            cant.append("%d diff line(s) outside a readable file header" % bad)
        reads, tests, unsup, skipped = find_reads(files)
        nreads = len(reads)
        for r in reads:
            if r[4]:
                waived.append(r)
            elif not covered(r, tests):
                findings.append(r)
        cant += ["%s:%d is code in a language this check has no rules for" % u for u in unsup]
    except Cant as e:
        cant.append(str(e))

    verdict = "reads-without-test" if findings else "nao-sei" if cant else "ok"
    refuse = "REFUSED" if eff == "enforce" else "AVISO (mode %s, does not refuse)" % ("holdout" if arm == "holdout" else "warn")
    if findings:
        print("%s %d new read(s) with no test that injects the failure -- %s:" % (tag, len(findings), refuse))
        for p, n, k, t, _ in findings:
            print("  %s:%d  [%s]  %s" % (p, n, k, t[:110]))
        print("  Fix: add, in a test of THIS diff that names the file, a case where the read FAILS (file unreadable/missing, JSON corrupt, command exits non-zero,\n"
              "  db locked or missing, URL down) and assert the code lands in the inert state -- inject it (raise/side_effect, a missing path, a stub that\n"
              "  fails); a comment, a test name or an assertion that the call succeeded is not an injection. Or waive on the line:  third-state-waiver: <why it cannot fail>")
    for p, n, k, t, w in waived:
        print("  waived  %s:%d  [%s]  %s" % (p, n, k, w))
    for c in cant:
        print("%s NÃO SEI -- %s -- %s" % (tag, c, refuse if not findings else "also"))
    if skipped:
        print("NOTE: %d changed file(s) NOT analysed (docs/ build/ dist/ vendor/ retired/, or no rules for the type; a read in them is not seen): %s%s"
              % (len(skipped), ", ".join(skipped[:5]), " ..." if len(skipped) > 5 else ""))
    if verdict == "ok":
        print("%s ok -- %d recognised new read(s), each with a failure test or a waiver (%d waived)." % (tag, nreads, len(waived)))
    print("%s verdict=%s mode=%s arm=%s reads=%d uncovered=%d waived=%d skipped=%d"
          % (tag, verdict, eff if arm != "holdout" else "holdout", arm, nreads, len(findings), len(waived), len(skipped)))
    if eff != "enforce":
        return 0
    return 1 if findings else 2 if cant else 0


if __name__ == "__main__":
    # an uncaught exception would exit 1 = "found a gap": a crashed checker must say it could not tell (2), never look like a finding
    try:
        sys.exit(main())
    except Exception as exc:
        print("third-state-reads-check: NÃO SEI -- internal error: %s: %s" % (type(exc).__name__, exc))
        sys.exit(2)
