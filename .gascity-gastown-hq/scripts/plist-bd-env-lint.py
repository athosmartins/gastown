#!/usr/bin/env python3
"""plist-bd-env-lint.py — every launchd plist the city loads must set BEADS_DOLT_AUTO_START to "0" (ga-d3ryi7k).

WHY: at the 23/11 23:41 reboot a `bd` started by launchd, from a plist without this variable, started a local Dolt of
its own (the "decoy", on the port the production Dolt had before the reboot) for three rigs. The decoy had no database,
every job that read those rigs got "database not found", and the Pilot read its lanes as full for ~12 h. The same switch
is what `gc` already sets on every `bd` it runs: with it off a `bd` has no server of its own to fall back on, so a server
that does not answer is an error in the log and nothing is left listening. 103 of the 104 plists the city loads carried no
such value; a plist added tomorrow would start the same way unless something refuses it.

The verdict is plistlib, the SAME reader plist-comment-lint.py and the WA lint use, never a grep: the name inside an XML
comment or a ProgramArguments string is a mention, not a setting, and only EnvironmentVariables is read by launchd.

Usage:  plist-bd-env-lint.py [FILE ...]          check. No FILE: every plist git tracks under the city this script
                                                 lives in (PLIST_LINT_ROOT=<dir> points the discovery somewhere else;
                                                 the selftest uses it).
        plist-bd-env-lint.py --fix [FILE ...]    insert the missing key into each plist that has none, textually (the
                                                 comments, the indentation and the line endings stay as they are) and
                                                 only when the parsed result is the original plus that one key. It never
                                                 rewrites a value that is already there, never touches a binary or an
                                                 unparseable plist, and never reloads a job: that is launchctl's.
        plist-bd-env-lint.py --installed [--fix] judge (and with --fix, repair) the INSTALLED copies of the tracked plists: for each
                                                 one, the file <Label>.plist under PLIST_LINT_AGENTS_DIR (default
                                                 ~/Library/LaunchAgents). Nothing else in that directory is read or touched
                                                 (it holds plists that are not ours). A tracked plist with no installed copy is
                                                 listed as "not installed", which is not a failure; if NOTHING is installed
                                                 there it is exit 2 (wrong directory?), never a clean 0. Takes no FILE.
        Paths under docs/launchd-archive/ (retired jobs) and internal/templates/ (the engine's own service templates)
        are not plists this city loads and are skipped (named on stdout when you pass them as FILE).
Exit:   0  every plist carries it (or, with --fix, every plist does now)
        1  at least one does not (named on stdout, with why)         [check only]
        2  could not decide: git failed, no plist found, a file could not be read or parsed, or --fix could not fix one
           (never reported as clean; a finding in the same run still wins and exits 1)

Python 3.9 compatible on purpose: the gate resolves whichever `python3` is on PATH (stock macOS ships 3.9).
"""
from __future__ import annotations

import copy
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

KEY = "BEADS_DOLT_AUTO_START"
WANT = "0"
RUNBOOK = ".gascity-gastown-hq/docs/runbooks/bd-dolt-auto-start.md"
# plists no launchd loads from this repo: retired/disabled jobs and the engine's own service templates
NOT_LIVE = ("docs/launchd-archive/", "internal/templates/")

HINT = (
    "Every plist the city loads must carry <key>%s</key><string>%s</string> inside EnvironmentVariables: a bd that launchd "
    "starts without it may start a Dolt of its own (the 23/11 decoy). Add the two lines, or run: "
    "python3 .gascity-gastown-hq/scripts/plist-bd-env-lint.py --fix <file>. Why and how to roll it out: %s (ga-d3ryi7k)."
    % (KEY, WANT, RUNBOOK)
)

# comments and CDATA are blanked (same length, newlines kept) before any tag search, so a `</dict>` written inside a
# comment is never taken for markup
_BLANK = re.compile(r"<!--.*?-->|<!\[CDATA\[.*?\]\]>", re.S)
_ENV_KEY = re.compile(r"<key>\s*EnvironmentVariables\s*</key>")
_DICT_OPEN = re.compile(r"\s*<dict\s*>")
_DICT_TOK = re.compile(r"<dict\s*/>|<dict\s*>|</dict\s*>")
_PAIR = re.compile(r"<key>[^<]*</key>(\s*)<")


def is_live(path):
    p = "/" + path.replace(os.sep, "/")
    return not any("/" + frag in p for frag in NOT_LIVE)


def _why(e):
    return (str(e).splitlines() or [type(e).__name__])[0][:160]


def judge(data):
    """(state, detail). state: ok | lacks | wrong | undecided."""
    # vazio → arquivo de 0 bytes não parseia: undecided (nunca "ok"); falhou/ilegível → undecided também, e o motivo vai na mensagem
    try:
        d = plistlib.loads(data)
    except Exception as e:  # ExpatError, InvalidFileException, ValueError: all mean "this reader refuses it"
        return "undecided", "does not parse: %s" % _why(e)
    if not isinstance(d, dict):
        return "undecided", "the top level is not a dict"
    env = d.get("EnvironmentVariables")
    if env is None:
        return "lacks", "no EnvironmentVariables dict"
    if not isinstance(env, dict):
        return "wrong", "EnvironmentVariables is not a dict"
    if KEY not in env:
        return "lacks", "EnvironmentVariables has no %s" % KEY
    v = env[KEY]
    if isinstance(v, str) and v == WANT:
        return "ok", ""
    return "wrong", "%s is %r, must be the string %r" % (KEY, v, WANT)


def _mask(text):
    return _BLANK.sub(lambda m: re.sub(r"[^\r\n]", " ", m.group(0)), text)


def _dict_end(masked, start):
    """Index of the </dict> that closes the dict whose opening tag ends at `start`, or None."""
    depth = 1
    for m in _DICT_TOK.finditer(masked, start):
        t = m.group(0)
        if t.startswith("</"):
            depth -= 1
            if depth == 0:
                return m.start()
        elif not t.endswith("/>"):
            depth += 1
    return None


def _line_indent(text, pos):
    """Leading whitespace of the line that holds text[pos]."""
    ls = text.rfind("\n", 0, pos) + 1
    return re.match(r"[ \t]*", text[ls:]).group(0)


def _insert_point(text, start, close):
    """Where a new last entry goes: after the last real content, before the whitespace that precedes the closing tag."""
    i = close
    while i > start and text[i - 1] in " \t\r\n":
        i -= 1
    return i


def _entry_indent(text, masked, open_pos, inner_start, close):
    """The indentation of the entries of the dict that opens at `open_pos` and closes at `close`."""
    first_key = masked.find("<key>", inner_start, close)
    if first_key < 0:
        return _line_indent(text, close) + "  "
    if "\n" not in text[open_pos:first_key]:  # <dict> and its first <key> share a line: the line's own indent is the parent's
        return _line_indent(text, open_pos) + "  "
    return _line_indent(text, first_key)


def _fix_existing_env(text, masked, em):
    """(new_text, why). The EnvironmentVariables dict exists and lacks the key: add it as its last entry."""
    nl = "\r\n" if "\r\n" in text else "\n"
    m = _DICT_OPEN.match(masked, em.end())
    if not m:
        return None, "EnvironmentVariables is not followed by a <dict> (an empty <dict/>? add the key by hand)"
    open_pos = masked.find("<dict", em.end(), m.end())
    inner_start = m.end()
    close = _dict_end(masked, inner_start)
    if close is None:
        return None, "cannot find where the EnvironmentVariables dict ends"
    indent = _entry_indent(text, masked, open_pos, inner_start, close)
    pairs = _PAIR.findall(masked[inner_start:close])
    sep = pairs[-1] if pairs else "\n"
    sep = nl + indent if "\n" in sep else sep
    at = _insert_point(text, inner_start, close)
    return text[:at] + nl + indent + "<key>%s</key>%s<string>%s</string>" % (KEY, sep, WANT) + text[at:], ""


def _fix_missing_env(text, masked):
    """(new_text, why). There is no EnvironmentVariables at all: add the whole block as the last top-level entry."""
    nl = "\r\n" if "\r\n" in text else "\n"
    pm = re.compile(r"<plist[^>]*>\s*<dict\s*>").search(masked)
    if not pm:
        return None, "no top-level <dict> found"
    open_pos = masked.rfind("<dict", pm.start(), pm.end())
    inner_start = pm.end()
    close = _dict_end(masked, inner_start)
    if close is None:
        return None, "cannot find where the top-level dict ends"
    dict_indent = _line_indent(text, open_pos)
    entry = _entry_indent(text, masked, open_pos, inner_start, close)
    unit = entry[len(dict_indent):] if entry.startswith(dict_indent) and len(entry) > len(dict_indent) else "  "
    pairs = _PAIR.findall(masked[inner_start:close])
    if (not pairs) or ("\n" in pairs[0]):
        block = (nl + entry + "<key>EnvironmentVariables</key>" + nl + entry + "<dict>" + nl + entry + unit
                 + "<key>%s</key>" % KEY + nl + entry + unit + "<string>%s</string>" % WANT + nl + entry + "</dict>")
    else:
        block = (nl + entry + "<key>EnvironmentVariables</key><dict>" + nl + entry + unit
                 + "<key>%s</key><string>%s</string>" % (KEY, WANT) + nl + entry + "</dict>")
    at = _insert_point(text, inner_start, close)
    return text[:at] + block + text[at:], ""


def fix_text(text, data):
    """(new_text, why): `text` is `data` decoded; None as new_text means it was not (safely) fixable."""
    masked = _mask(text)
    envs = list(_ENV_KEY.finditer(masked))
    if len(envs) > 1:
        return None, "EnvironmentVariables appears %d times" % len(envs)
    new, why = _fix_existing_env(text, masked, envs[0]) if envs else _fix_missing_env(text, masked)
    if new is None:
        return None, why
    # the only edit that is ever written: the parsed result must be the original plus exactly this one key
    try:
        before = plistlib.loads(data)
        after = plistlib.loads(new.encode("utf-8"))
    except Exception as e:
        return None, "the edited text does not parse (%s); not written" % _why(e)
    want = copy.deepcopy(before)
    want.setdefault("EnvironmentVariables", {})[KEY] = WANT
    if after != want:
        return None, "the edited text parses to something other than the original plus the key; not written"
    return new, ""


def write_atomic(path, payload):
    target = os.path.realpath(path)  # a symlinked plist (LaunchAgents -> the repo) has its TARGET edited, not the link replaced
    fd, tmp = tempfile.mkstemp(prefix=".plist-fix-", dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
        shutil.copymode(target, tmp)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def tracked_plists(root):
    """(files, why). files is None when git could not answer; [] when git answered with nothing."""
    # vazio → git respondeu sem nenhum plist: devolve [] e o main recusa (rc 2), uma cidade com dezenas de plists não está "limpa";
    # falhou/ilegível → git não rodou ou saiu != 0: devolve None e o main sai com rc 2 — nunca vira "nada a checar"
    try:
        r = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", "*.plist"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return None, "git did not run: %s" % e
    if r.returncode != 0:
        return None, "git ls-files rc=%d: %s" % (r.returncode, r.stderr.decode("utf-8", "replace").strip()[:200])
    names = [n for n in r.stdout.decode("utf-8", "surrogateescape").split("\0") if n]
    return [os.path.join(root, n) for n in names], ""


def installed_copies(tracked, agents_dir, shown):
    """(copies, missing_labels, problems): the installed file of each live tracked plist, found by its Label."""
    copies, missing, problems, seen = [], [], [], set()
    for path in tracked:
        if not is_live(shown(path)):
            continue
        # vazio (sem Label, ou Label que não é um nome de arquivo) → não sei qual é a cópia: problema (rc 2), nunca "não instalado"; falhou/ilegível → idem
        try:
            with open(path, "rb") as f:
                label = plistlib.load(f).get("Label")
        except Exception as e:
            problems.append((path, "cannot read its Label: %s" % _why(e)))
            continue
        if not isinstance(label, str) or not label or "/" in label:
            problems.append((path, "no usable Label (a plain string): cannot tell which installed file is its copy"))
            continue
        if label in seen:
            continue
        seen.add(label)
        cand = os.path.join(agents_dir, label + ".plist")
        if os.path.isfile(cand):
            copies.append(cand)
        else:
            missing.append(label)
    return copies, missing, problems


def main(argv):
    fix = False
    installed = False
    files = []
    for a in argv[1:]:
        if a == "--fix":
            fix = True
        elif a == "--installed":
            installed = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("--"):
            print("plist-bd-env-lint: unknown option %s (see --help)" % a, file=sys.stderr)
            return 2
        else:
            files.append(a)
    root = os.environ.get("PLIST_LINT_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    explicit = bool(files)
    if installed and explicit:
        print("plist-bd-env-lint: --installed finds the files itself (by Label); it takes no FILE", file=sys.stderr)
        return 2
    if not explicit:
        found, why = tracked_plists(root)
        if found is None:
            print("plist-bd-env-lint: cannot list the plists: %s" % why, file=sys.stderr)
            return 2
        if not found:
            print("plist-bd-env-lint: no plist tracked under %s; refusing to call that clean" % root, file=sys.stderr)
            return 2
        files = found

    def shown(p):
        return os.path.relpath(p, root) if p.startswith(root + os.sep) else p

    failed, undecided, skipped, fixed, already = [], [], [], [], []
    missing = []
    judged = 0
    if installed:
        agents = os.environ.get("PLIST_LINT_AGENTS_DIR") or os.path.expanduser("~/Library/LaunchAgents")
        files, missing, problems = installed_copies(files, agents, shown)
        undecided.extend(problems)
        if not files and not problems:
            print("plist-bd-env-lint: no installed copy of any tracked plist under %s; refusing to call that clean (wrong directory?)" % agents,
                  file=sys.stderr)
            return 2
    for path in files:
        if not is_live(shown(path)):
            skipped.append(path)
            continue
        judged += 1
        # vazio → arquivo de 0 bytes cai em judge() e vira undecided (não é "limpo"); falhou/ilegível → undecided, rc 2
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            undecided.append((path, str(e)))
            continue
        state, detail = judge(data)
        if state == "undecided":
            undecided.append((path, detail))
        elif state == "ok":
            already.append(path)
        elif not fix:
            failed.append((path, detail))
        elif state == "wrong":
            undecided.append((path, "%s: --fix does not rewrite a value somebody set; fix it by hand" % detail))
        elif data.startswith(b"bplist"):
            undecided.append((path, "binary-format plist: --fix edits text only; convert it (plutil -convert xml1) or edit by hand"))
        else:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                undecided.append((path, "not UTF-8: --fix does not guess an encoding"))
                continue
            new, why = fix_text(text, data)
            if new is None:
                undecided.append((path, "cannot fix: %s" % why))
                continue
            try:
                write_atomic(path, new.encode("utf-8"))
            except OSError as e:
                undecided.append((path, "cannot write: %s" % e))
                continue
            fixed.append(path)
            print("FIXED %s" % shown(path))

    if explicit:
        for path in skipped:
            print("skip %s: not a live plist (archive or engine template)" % shown(path))
    for path, detail in undecided:
        print("UNREADABLE %s: %s" % (shown(path), detail), file=sys.stderr)
    for path, detail in failed:
        print("FAIL %s: %s" % (shown(path), detail))

    note = ""
    if installed:
        note = ", %d tracked plist(s) not installed" % len(missing)
        if missing:
            print("not installed (no <Label>.plist under the agents dir): %s%s" % (", ".join(sorted(missing)[:15]), " ..." if len(missing) > 15 else ""))
    if fix:
        print("plist-bd-env-lint --fix: %d file(s), %d fixed, %d already ok, %d could not be fixed, %d skipped%s"
              % (judged, len(fixed), len(already), len(undecided), len(skipped), note))
        return 2 if undecided else 0
    print("plist-bd-env-lint: %d file(s), %d fail, %d unreadable, %d skipped%s" % (judged, len(failed), len(undecided), len(skipped), note))
    if failed:
        print(HINT)
        return 1
    return 2 if undecided else 0


if __name__ == "__main__":
    # an uncaught exception exits 1, the code for "a plist lacks it", which the pre-push hook turns into a BLOCK: a bug here
    # must read as "could not decide" (2, the hook warns and lets the push through), never as a finding
    try:
        rc = main(sys.argv)
    except Exception as exc:
        print("plist-bd-env-lint: internal error, could not decide: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        rc = 2
    sys.exit(rc)
