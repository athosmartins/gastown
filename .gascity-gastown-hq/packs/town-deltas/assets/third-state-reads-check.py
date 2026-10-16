#!/usr/bin/env python3
"""third-state-reads-check.py — ga-57e7l0.1 (fatia 2/3 of ga-57e7l0): /gate-done refuses a NEW failable read that no test makes fail.

Why: "could not read" handled as empty/zero is 6 of the 7 first-attempt rejections (14/10 baseline). Prose (the E12 doctrine) did not move first-attempt
approval (59% with vs 62% without), so the gate must refuse. This is the "has a failure test?" layer: error-empty-conflation-scan.sh judges HOW a script
handles a failed read (whole files, report-only); this reads only the ADDED lines of `git diff base...head`, finds the new reads, and asks per read whether
a test touched by the same diff makes that KIND of read fail (unreadable/missing file, corrupt JSON, failing command, locked or missing db, dead URL).
NOT reads, from the calibration on 90 real branches (HQ + WA rig, see the bead): a dict .get() (51 of the 122 first-pass flags were in-memory lookups), SQL that
writes or configures, head/tail/cat on a pipe or a heredoc write, code under docs/. Coverage is per FILE and KIND (a touched test that names the file and
carries a failure marker for that kind), not per read: that is the check's known limit, and why a waiver names its reason.
It never judges the handling: a test that injects the failure is the evidence that somebody looked. A read that cannot meaningfully fail is waived on its
line (or the line above) with  third-state-waiver: <reason of 10+ chars>  — listed in the output, never silent.

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

# a statement that WRITES or configures (DDL, INSERT/UPDATE/DELETE, SET, non-schema PRAGMA) is not a read; the SQL text may sit on the next added line
DB_WRITE = r"\.execute\(\s*[rbfu]{0,2}(\"\"\"|\'\'\'|\"|\')\s*(CREATE|INSERT|UPDATE|DELETE|DROP|ALTER|REPLACE|SET|BEGIN|COMMIT|ROLLBACK|VACUUM|ATTACH|DETACH|PRAGMA\s+(?!table_x?info|index_list|foreign_key_list))\b"

# (kind, pattern that makes a line a read, pattern that makes it NOT one)
READS = {
    "py": (
        ("file", r"(^|[^\w.])open\(|\.(read_text|read_bytes)\(|\bos\.(walk|listdir|scandir)\(|\bglob\.i?glob\(|\.(iterdir|rglob)\(", r"open\([^)]*['\"][wax]"),
        ("parse", r"\b(json|tomllib|yaml|pickle|plistlib)\.(loads?|safe_load)\(", None),
        ("cmd", r"\bsubprocess\.(run|check_output|check_call|call|Popen|getoutput|getstatusoutput)\(|\bos\.(popen|system)\(", None),
        ("db", r"\bsqlite3\.connect\(|\.(fetchall|fetchone|fetchmany)\(|\.execute\(", DB_WRITE),
        ("http", r"\burlopen\(|\brequests\.(get|post|put|delete|head|request)\(|\bhttpx\.|\bhttp\.client\.|\bcreate_connection\(", None),
    ),
    "sh": (
        ("cmd", r"[$][(]\s*(cat|jq|grep|egrep|sed|awk|head|tail|curl|wget|sqlite3|dolt|bd|gc|git|gh|python3?|find|stat|wc|cut|sort|ssh|aws|mysql|ls)(\s|[)]|$)", None),
        ("file", r"(^\s*|;\s*|&&\s*|\|\|\s*|\bdo\s+|\bthen\s+)(cat|head|tail)\s+(-\S+\s+)*[^\s|;&<>-]|\bread\b[^<]*<\s*[^<(&\s]|\bdone\s*<\s*[^<(&\s]", None),
    ),
}
# what, inside the ADDED lines of a test that mentions the file, counts as making that kind of read fail
FAILS = {
    "file": r"chmod\s+0|unreadable|ilegív|inexist|nonexist|does[-_ ]not[-_ ]exist|no[-_ ]such|missing|ausente|rm\s+-f|FileNotFoundError|PermissionError|OSError|IOError|ENOENT|EACCES",
    "parse": r"corrupt|garbage|truncat|malformed|invalid|not[-_ ]?json|broken|\{\{\{|partial|ilegív|JSONDecodeError|ValueError|ParseError",
    "cmd": r"exit\s+[1-9]|return\s+[1-9]|returncode|rc\s*=\s*[1-9]|(?-i:\bfalse\b)|command not found|not on PATH|PATH=|CalledProcessError|TimeoutExpired|FileNotFoundError|non-?zero",
    "db": r"OperationalError|DatabaseError|locked|corrupt|not a database|no such table|readonly|read-only|missing db|unable to open|ausente|ilegív|inexist|n[aã]o existe|does not exist",
    "http": r"URLError|HTTPError|ConnectionError|timeout|timed out|refused|unreachable|offline|\b[45][0-9][0-9]\b|DNS",
}


class Cant(Exception):
    """The check could not be decided: becomes exit 2, never ok."""


def git_diff(repo, base, head):
    # vazio → diff vazio = a branch não muda nada (rc 0 legítimo); falhou/ilegível (sem git, base inexistente, timeout) → Cant, nunca "diff vazio"
    cmd = ["git", "-C", repo, "-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", "--unified=0", "%s...%s" % (base, head)]
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


def find_reads(files):
    """-> (reads [(path, line, kind, text, waiver)], tests {path: text}, unsupported [(path, line)])."""
    reads, tests, unsup = [], {}, []
    for path in sorted(files):
        added = files[path]
        if SKIP_RE.search(path):
            continue
        if TEST_RE.search(path):
            tests[path] = "\n".join(t for _, t in added)
            continue
        ext = os.path.splitext(path)[1]
        if ext in OTHER_CODE:
            unsup += [(path, n) for n, t in added if GENERIC.search(t)][:3]
            continue
        rules = READS.get(LANG.get(ext, ""), ())
        prev, text_of = {}, dict(added)
        for n, t in added:
            prev[n] = t
            if t.lstrip().startswith("#"):
                continue
            for kind, inc, exc in rules:
                # a line that ends in `.execute(` carries its SQL on the next added line; no other line looks ahead
                probe = t + " " + text_of.get(n + 1, "") if kind == "db" and re.search(r"[.]execute\(\s*$", t) else t
                if re.search(inc, t) and not (exc and re.search(exc, probe, re.I if kind == "db" else 0)):
                    w = WAIVER.search(t) or WAIVER.search(prev.get(n - 1, ""))
                    reads.append((path, n, kind, t.strip(), w.group(1).strip() if w else ""))
    return reads, tests, unsup


def stem(path):
    return re.sub(r"[.](py|sh|bash|zsh)$", "", os.path.basename(path))


def covered(read, tests):
    path, _, kind, _, _ = read
    s = stem(path)
    return any((s in tp or s in tt) and re.search(FAILS[kind], tt, re.I) for tp, tt in tests.items())


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
            continue
        if isinstance(d, dict) and d.get("bead") == bead and d.get("arm") in ("enforce", "holdout"):
            return d["arm"], ""
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

    cant, findings, waived, nreads = [], [], [], 0
    try:
        files, bad = parse_diff(git_diff(a.repo, a.base, a.head))
        if bad:
            cant.append("%d diff line(s) outside a readable file header" % bad)
        reads, tests, unsup = find_reads(files)
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
              "  db locked or missing, URL down) and assert the code lands in the inert state; or waive on the line:  third-state-waiver: <why it cannot fail>")
    for p, n, k, t, w in waived:
        print("  waived  %s:%d  [%s]  %s" % (p, n, k, w))
    for c in cant:
        print("%s NÃO SEI -- %s -- %s" % (tag, c, refuse if not findings else "also"))
    if verdict == "ok":
        print("%s ok -- %d new read(s), each with a failure test or a waiver (%d waived)." % (tag, nreads, len(waived)))
    print("%s verdict=%s mode=%s arm=%s reads=%d uncovered=%d waived=%d" % (tag, verdict, eff if arm != "holdout" else "holdout", arm, nreads, len(findings), len(waived)))
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
