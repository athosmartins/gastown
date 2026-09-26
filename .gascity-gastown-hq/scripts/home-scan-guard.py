#!/usr/bin/env python3
"""home-scan-guard.py (ga-02cqk4) -- the classifier behind home-scan-guard.sh.

Reads a Claude Code PreToolUse hook payload on stdin. Exit 2 (+ a message on stderr, which
Claude Code hands back to the model) when the Bash command would ENUMERATE, MEASURE or
READ RECURSIVELY $HOME or a macOS-protected folder; exit 0 in every other case, INCLUDING
every internal error (fail-open: a guard that breaks all Bash calls of all agents is worse
than the problem).

WHY (ga-6cyp1l, 26/09 14:52): a crew session ran
    cd /Users/athos && for d in $(ls -A); do ... timeout 60 du -xsk "$d" ...; done
Four `du` calls hit Desktop, Documents, Downloads and Photos in ~1s. macOS TCC attributes
every file access of an agent session to gc (the supervisor is the "responsible" process of
tmux and of every session), so Athos saw "gc wants to access ..." and a headless session
blocks on it or is denied in silence. Prose does not restrict a tool (ga-1udgm); this is the
mechanical stop.

WHAT THIS IS NOT: a sandbox. It is a LEXICAL heuristic over the command text, on purpose:
  * It never touches any path the COMMAND mentions. Not even a stat: doing that on a protected path
    from the guard would itself be the TCC access it exists to prevent (and the guard is a child of
    the session, so the prompt would be blamed on gc all the same). No realpath, no isdir. (It does
    write its own log line, under ~/.gastown/logs, when it blocks or fails.)
  * Known gaps, deliberately not chased (the bead is about CLI scanners, not about an
    adversary): scans through an interpreter (python os.walk, node fs.readdir, perl File::Find),
    shell functions/aliases, `eval "$var"`, `bash script.sh`, any command whose scan target is
    computed at run time from something the text does not show, and a glob that the SHELL
    expands under a protected folder for a command that is not a scanner
    (`cat ~/Downloads/*.csv`, `for f in ~/Downloads/*; do ...`) -- reading files the operator
    pointed at is the legitimate use of Downloads, so that stays out of scope.
  * The shell grammar it understands is a working subset (quotes, escapes, heredocs, $(...),
    backticks, pipelines, &&/||/;, for/while/if bodies, subshells and braces, redirections,
    wrappers such as timeout/nice/env/xargs, bash -c / eval), enough that text which merely
    MENTIONS a scan (a bead comment, a commit message, a heredoc body) is not a scan.

STATE MODEL, in one paragraph: as the command is walked left to right the classifier tracks the
working directory (starting from the hook payload's `cwd`, moved by cd/pushd), simple variable
assignments (H=$HOME), and a set of "tainted" variables -- loop or `read` variables that iterate
over the entries of $HOME (`for d in $(ls -A)` with cwd=$HOME, `ls ~ | while read d`). A scanner
whose operand is (or lies under) $HOME, a protected folder, /Volumes, or a tainted variable, or
whose implicit operand (the cwd) is one of those, is a finding.
"""
import json
import os
import posixpath
import re
import sys
import time

# ----------------------------------------------------------------------------- policy tables
# Names are compared case-insensitively: the macOS volume is case-insensitive by default, so
# ~/downloads IS ~/Downloads.
PROTECTED_TOP = ("desktop", "documents", "downloads", "pictures", "movies", "music", ".trash")
LIBRARY_HOT = ("mobile documents", "cloudstorage", "containers", "group containers",
               "mail", "messages", "safari")
ALL_TOP = PROTECTED_TOP + ("library",)

# A path that ends in one of these is a DIRECTORY even though it has an extension, so it never
# earns the "one named file" exemption (a Photos library is the exact thing that prompts).
DIR_EXTENSIONS = {"app", "photoslibrary", "bundle", "framework", "xcodeproj", "xcworkspace",
                  "sparsebundle", "rtfd", "pages", "numbers", "key", "imovielibrary",
                  "fcpbundle", "logicx", "band", "dsym", "plugin", "kext", "xcarchive",
                  "playground", "lproj", "download", "theater", "photolibrary", "musiclibrary",
                  "tvlibrary", "aplibrary", "migratedphotolibrary"}

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
KEYWORDS = {"if", "then", "elif", "else", "fi", "while", "until", "do", "done", "{", "}", "!",
            "esac", "in", "function", "coproc"}
TOOL_ALIASES = {"gfind": "find", "gdu": "du", "ggrep": "grep", "gls": "ls", "gcp": "cp",
                "gtar": "tar", "fdfind": "fd", "ripgrep": "rg", "egrep": "grep",
                "fgrep": "grep", "zgrep": "grep", "exa": "ls", "eza": "ls", "lsd": "ls"}

MAX_DEPTH = 8
MAX_BRACE_ALTERNATIVES = 64

# ----------------------------------------------------------------------------- markers
DYN = "\ue000"     # a value the text does not reveal
HDYN = "\ue001"    # a value that is an ENTRY OF $HOME (loop/read variable over a home listing)
_QMAP = {"*": "\ue010", "?": "\ue011", "[": "\ue012", "{": "\ue013", "}": "\ue014", ",": "\ue015"}
_UNQMAP = {v: k for k, v in _QMAP.items()}


def quote_map(text):
    """Quoted glob/brace characters are literal: hide them from the glob/brace logic."""
    return "".join(_QMAP.get(ch, ch) for ch in text)


def unquote_map(text):
    return "".join(_UNQMAP.get(ch, ch) for ch in text)


class Block(Exception):
    pass


class Abort(Exception):
    """Unparseable beyond what we are willing to guess: a deliberate fail-open (logged as GAVE-UP)."""


# ----------------------------------------------------------------------------- shell scanner
class Seg:
    __slots__ = ("kind", "text", "quoted", "script")

    def __init__(self, kind, text="", quoted=False, script=None):
        self.kind, self.text, self.quoted, self.script = kind, text, quoted, script


class Word:
    __slots__ = ("segs",)

    def __init__(self, segs):
        self.segs = segs


class Segment:
    __slots__ = ("words", "op_before", "extra")

    def __init__(self, words, op_before, extra):
        self.words, self.op_before, self.extra = words, op_before, extra


_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_SPECIAL_VARS = "@*#?$!-0123456789"
_OP_CHARS = ";|&<>()"


def _find_close(s, i, opener, closer):
    """Index just past the closer that balances an already-open `opener` (text starts at i)."""
    depth = 1
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "\\":
            i += 2
            continue
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _parse_dollar(s, i, quoted, depth):
    """s[i] == '$'. Returns (Seg | None, new_i)."""
    n = len(s)
    if s.startswith("$((", i):
        return Seg("var", "?arith", quoted), _find_close(s, i + 3, "(", ")")
    if s.startswith("$(", i):
        segments, j = scan(s, i + 2, True, depth + 1)
        return Seg("sub", quoted=quoted, script=segments), j
    if s.startswith("${", i):
        j = _find_close(s, i + 2, "{", "}")
        content = s[i + 2:j - 1] if j - 1 >= i + 2 else ""
        m = _IDENT.match(content)
        return Seg("var", m.group(0) if m else "?", quoted), j
    if i + 1 < n:
        m = _IDENT.match(s, i + 1)
        if m:
            return Seg("var", m.group(0), quoted), m.end()
        if s[i + 1] in _SPECIAL_VARS:
            return Seg("var", "?" + s[i + 1], quoted), i + 2
    return Seg("lit", "$", quoted), i + 1


def _parse_backtick(s, i, quoted, depth):
    """s[i] == '`'. Returns (Seg, new_i)."""
    n = len(s)
    j = i + 1
    buf = []
    while j < n and s[j] != "`":
        if s[j] == "\\" and j + 1 < n and s[j + 1] in "`\\$":
            buf.append(s[j + 1])
            j += 2
            continue
        buf.append(s[j])
        j += 1
    segments, _ = scan("".join(buf), 0, False, depth + 1)
    return Seg("sub", quoted=quoted, script=segments), min(j + 1, n)


def _parse_dq(s, i, depth, terminator='"'):
    """Double-quote-like text starting at s[i] (just after the opening quote, or the start of an
    unquoted heredoc body when terminator is None). Returns (list[Seg], new_i)."""
    n = len(s)
    segs = []
    buf = []

    def flush():
        if buf:
            segs.append(Seg("lit", "".join(buf), True))
            buf.clear()

    while i < n:
        ch = s[i]
        if terminator is not None and ch == terminator:
            flush()
            return segs, i + 1
        if ch == "\\" and i + 1 < n and s[i + 1] in '$`"\\\n':
            if s[i + 1] != "\n":
                buf.append(s[i + 1])
            i += 2
            continue
        if ch == "$":
            flush()
            seg, i = _parse_dollar(s, i, True, depth)
            segs.append(seg)
            continue
        if ch == "`":
            flush()
            seg, i = _parse_backtick(s, i, True, depth)
            segs.append(seg)
            continue
        buf.append(ch)
        i += 1
    flush()
    return segs, n


def scan(s, i, in_paren, depth):
    """Parse shell text s[i:] into a list of Segment. With in_paren, stop after the ')' that
    closes an already-open `$(`."""
    if depth > MAX_DEPTH:
        raise Abort("nesting too deep")
    n = len(s)
    segments = []
    words = []
    extra = []
    segs = None
    op_before = ";"
    pending = []          # heredocs whose body starts after the next newline: (delim, strip, expand)
    skip_word = False     # the next word is a redirection target
    paren_depth = 0

    def add_lit(text, quoted):
        nonlocal segs
        if segs is None:
            segs = []
        if segs and segs[-1].kind == "lit" and segs[-1].quoted == quoted:
            segs[-1].text += text
        else:
            segs.append(Seg("lit", text, quoted))

    def end_word():
        nonlocal segs, skip_word
        if segs is None:
            return
        w = Word(segs)
        segs = None
        if skip_word:
            extra.append(w)
            skip_word = False
        else:
            words.append(w)

    def end_segment(op):
        nonlocal words, extra, op_before
        end_word()
        if words or extra:
            segments.append(Segment(words, op_before, extra))
        words, extra = [], []
        op_before = op

    while i < n:
        c = s[i]
        if c in " \t":
            end_word()
            i += 1
            continue
        if c == "\n":
            end_segment("\n")
            i += 1
            for delim, strip, expand in pending:
                body = []
                while i < n:
                    j = s.find("\n", i)
                    line_end = n if j < 0 else j
                    line = s[i:line_end]
                    i = min(line_end + 1, n)
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    body.append(line)
                if expand:
                    subs, _ = _parse_dq("\n".join(body), 0, depth + 1, None)
                    hd = [Word([sg]) for sg in subs if sg.kind == "sub"]
                    if hd:
                        if segments:
                            segments[-1].extra.extend(hd)
                        else:
                            extra.extend(hd)
            pending = []
            continue
        if c == "#" and segs is None:
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2
                continue
            if i + 1 < n:
                add_lit(s[i + 1], True)
                i += 2
                continue
            i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            if segs is None:
                segs = []
            add_lit(s[i + 1:j], True)
            i = min(j + 1, n)
            continue
        if c == '"':
            if segs is None:
                segs = []
            parts, i = _parse_dq(s, i + 1, depth)
            segs.extend(parts)
            continue
        if c == "$":
            if segs is None:
                segs = []
            seg, i = _parse_dollar(s, i, False, depth)
            segs.append(seg)
            continue
        if c == "`":
            if segs is None:
                segs = []
            seg, i = _parse_backtick(s, i, False, depth)
            segs.append(seg)
            continue
        if c in "<>":
            if i + 1 < n and s[i + 1] == "(":
                if segs is None:
                    segs = []
                sub, i = scan(s, i + 2, True, depth + 1)
                segs.append(Seg("sub", script=sub))
                continue
            if s.startswith("<<<", i):
                end_word()
                i += 3
                skip_word = True
                continue
            if s.startswith("<<", i):
                end_word()
                i += 2
                strip = i < n and s[i] == "-"
                if strip:
                    i += 1
                while i < n and s[i] in " \t":
                    i += 1
                delim = []
                quoted_delim = False
                while i < n and s[i] not in " \t\n" and s[i] not in _OP_CHARS:
                    if s[i] in "'\"":
                        quoted_delim = True
                        j = s.find(s[i], i + 1)
                        j = n if j < 0 else j
                        delim.append(s[i + 1:j])
                        i = min(j + 1, n)
                    elif s[i] == "\\":
                        quoted_delim = True
                        if i + 1 < n:
                            delim.append(s[i + 1])
                        i += 2
                    else:
                        delim.append(s[i])
                        i += 1
                pending.append(("".join(delim), strip, not quoted_delim))
                continue
            # fd number glued to the operator (2>/dev/null): not a word
            if segs is not None and len(segs) == 1 and segs[0].kind == "lit" \
                    and not segs[0].quoted and segs[0].text.isdigit():
                segs = None
            end_word()
            m = re.match(r">>|>&|>\||<&|<>|>|<", s[i:])
            i += len(m.group(0))
            skip_word = True
            continue
        if c == "&":
            if i + 1 < n and s[i + 1] == ">":
                end_word()
                i += 3 if s.startswith("&>>", i) else 2
                skip_word = True
                continue
            if i + 1 < n and s[i + 1] == "&":
                end_segment("&&")
                i += 2
                continue
            end_segment("&")
            i += 1
            continue
        if c == "|":
            if i + 1 < n and s[i + 1] == "|":
                end_segment("||")
                i += 2
            elif i + 1 < n and s[i + 1] == "&":
                end_segment("|&")
                i += 2
            else:
                end_segment("|")
                i += 1
            continue
        if c == ";":
            end_segment(";")
            i += 2 if s.startswith(";;", i) else 1
            continue
        if c == "(":
            end_segment("(")
            paren_depth += 1
            i += 1
            continue
        if c == ")":
            end_segment(")")
            i += 1
            if in_paren and paren_depth == 0:
                return segments, i
            if paren_depth > 0:
                paren_depth -= 1
            continue
        add_lit(c, False)
        i += 1
    end_segment(";")
    return segments, n


# ----------------------------------------------------------------------------- word resolution
class Res:
    __slots__ = ("s", "tainted")

    def __init__(self, s, tainted):
        self.s, self.tainted = s, tainted


class State:
    def __init__(self, homes, cwd):
        self.homes = homes
        self.home = homes[0]
        self.cwd = cwd
        self.vars = {}
        self.tainted = set()

    def fork(self):
        st = State(self.homes, self.cwd)
        st.vars = dict(self.vars)
        st.tainted = set(self.tainted)
        return st


def lit_text(w):
    """The word's text when it has no expansion in it, else None."""
    parts = []
    for sg in w.segs:
        if sg.kind != "lit":
            return None
        parts.append(sg.text)
    return "".join(parts)


def render(w):
    """Best-effort source text of a word (used to re-parse `bash -c STRING` / `eval STRING`)."""
    parts = []
    for sg in w.segs:
        if sg.kind == "lit":
            parts.append(sg.text)
        elif sg.kind == "var":
            parts.append("$" + sg.text if _IDENT.fullmatch(sg.text) else DYN)
        else:
            parts.append("__sub__")
    return "".join(parts)


_BRACE = re.compile(r"\{([^{}]*,[^{}]*)\}")


def expand_braces(s):
    out = [s]
    for _ in range(6):
        nxt = []
        changed = False
        for item in out:
            m = _BRACE.search(item)
            if not m:
                nxt.append(item)
                continue
            changed = True
            for alt in m.group(1).split(","):
                nxt.append(item[:m.start()] + alt + item[m.end():])
        out = nxt
        if len(out) > MAX_BRACE_ALTERNATIVES:
            return [s]
        if not changed:
            break
    return out


def resolve(word, st, in_assignment=False):
    """word -> list[Res]. Vars and ~ are substituted with what the text/state reveals; anything
    else becomes DYN (unknown) or HDYN (an entry of $HOME)."""
    out = []
    tainted = False
    for idx, sg in enumerate(word.segs):
        if sg.kind == "lit":
            t = sg.text
            if sg.quoted:
                t = quote_map(t)
            elif idx == 0 and t.startswith("~") and (len(t) == 1 or t[1] == "/"):
                t = st.home + t[1:]
            out.append(t)
        elif sg.kind == "var":
            name = sg.text
            if name in st.tainted:
                tainted = True
                out.append(HDYN)
            elif name in st.vars:
                out.append(st.vars[name])
            elif name == "HOME":
                out.append(st.home)
            else:
                out.append(DYN)
        else:  # sub
            if script_lists_home(sg.script, st):
                tainted = True
                out.append(HDYN)
            else:
                out.append(DYN)
    return [Res(s, tainted) for s in expand_braces("".join(out))]


# ----------------------------------------------------------------------------- path model
def has_glob(s):
    return any(ch in s for ch in "*?[")


def _is_static(comp):
    return not any(ch in comp for ch in (DYN, HDYN, "*", "?", "["))


def _comp_regex(comp):
    parts = []
    i = 0
    while i < len(comp):
        ch = comp[i]
        if ch in (DYN, HDYN, "*"):
            parts.append(".*")
        elif ch == "?":
            parts.append(".")
        elif ch == "[":
            j = comp.find("]", i + 1)
            if j < 0:
                parts.append(re.escape(ch))
            else:
                parts.append(".")
                i = j
        else:
            parts.append(re.escape(ch.lower()))
        i += 1
    return re.compile("".join(parts), re.S)


def comp_matches(comp, names):
    if _is_static(comp):
        return comp.lower() in names
    rx = _comp_regex(comp)
    return any(rx.fullmatch(n) for n in names)


def norm(p):
    p = posixpath.normpath(p)
    return "/" if p.startswith("//") and set(p) == {"/"} else p


def _comp_ok(comp, target):
    """Can path component `comp` (static, glob or unknown) denote the directory named `target`?"""
    if _is_static(comp):
        return comp.lower() == target.lower()
    return bool(_comp_regex(comp).fullmatch(target.lower()))


def home_rel(p, st):
    """Components of `p` below $HOME (list, possibly empty), or None when `p` is not under it."""
    pc = [c for c in norm(p).split("/") if c]
    for h in st.homes:
        hc = [c for c in h.split("/") if c]
        if len(pc) >= len(hc) and all(_comp_ok(pc[i], hc[i]) for i in range(len(hc))):
            return pc[len(hc):]
    return None


def classify(p, st):
    """None | 'home-root' | 'hot' | 'ancestor'.
    home-root: $HOME itself. hot: a protected folder or anything below it, /Volumes, or a
    component of $HOME we cannot rule out. ancestor: / or /Users -- a recursive scan from there
    walks into $HOME. A glob or unknown component is compared against $HOME's own components, so
    /Users/* and /Users/*/Downloads are recognised (they expand to $HOME and to a folder in it)."""
    if p is None:
        return None
    p = norm(p)
    if p == "/Volumes" or p.startswith("/Volumes/"):
        return "hot"
    pc = [c for c in p.split("/") if c]
    for h in st.homes:
        hc = [c for c in h.split("/") if c]
        if len(pc) <= len(hc):
            if all(_comp_ok(pc[i], hc[i]) for i in range(len(pc))):
                return "home-root" if len(pc) == len(hc) else "ancestor"
            continue
        if not all(_comp_ok(pc[i], hc[i]) for i in range(len(hc))):
            continue
        rel = pc[len(hc):]
        first = rel[0]
        if not _is_static(first):
            return "hot" if comp_matches(first, ALL_TOP) else None
        lf = first.lower()
        if lf in PROTECTED_TOP:
            return "hot"
        if lf == "library":
            if len(rel) == 1:
                return "hot"
            return "hot" if comp_matches(rel[1], LIBRARY_HOT) else None
        return None
    return None


def _join_cwd(s, st):
    if s.startswith("/"):
        return s
    if st.cwd is None:
        return None
    return st.cwd + "/" + s


def path_of(res, st):
    """Resolved absolute path (with markers) of an operand, or None when it cannot be placed."""
    s = res.s
    if not s:
        return None
    if res.tainted and s[0] in (HDYN,):
        return st.home + "/" + HDYN
    p = _join_cwd(s, st)
    return None if p is None else norm(p)


def kind_of(res, st):
    p = path_of(res, st)
    return classify(p, st)


def looks_like_file(p, st):
    """`~/Downloads/relatorio.pdf` -- a single named file the operator pointed at, not a sweep."""
    p = norm(p)
    rel = home_rel(p, st)
    if rel is None or len(rel) < 2:
        return False
    last = rel[-1]
    if not _is_static(last):
        return False
    m = re.fullmatch(r"[^.].*\.([A-Za-z0-9]{1,8})", last)
    return bool(m) and m.group(1).lower() not in DIR_EXTENSIONS


# ----------------------------------------------------------------------------- argument parsing
NUMERIC = re.compile(r"-?[0-9]+")


def parse_args(args, valued_short=(), valued_long=()):
    """-> (flags:set, operands:list[Word], values:dict). flags holds single letters and long
    names; `values` maps a valued option to the word that followed it."""
    flags = set()
    ops = []
    values = {}
    i = 0
    only_ops = False
    while i < len(args):
        w = args[i]
        t = lit_text(w)
        if only_ops or t is None or not t.startswith("-") or t == "-":
            ops.append(w)
            i += 1
            continue
        if t == "--":
            only_ops = True
            i += 1
            continue
        if t.startswith("--"):
            name = t.split("=", 1)[0]
            flags.add(name)
            if "=" in t:
                values[name] = t.split("=", 1)[1]
            elif name in valued_long and i + 1 < len(args):
                values[name] = lit_text(args[i + 1]) or ""
                i += 1
            i += 1
            continue
        cluster = t[1:]
        for k, ch in enumerate(cluster):
            flags.add(ch)
            if ch in valued_short:
                rest = cluster[k + 1:]
                if rest:
                    values[ch] = rest
                elif i + 1 < len(args):
                    values[ch] = lit_text(args[i + 1]) or ""
                    i += 1
                break
        i += 1
    return flags, ops, values


def _numeric_word(w):
    t = lit_text(w)
    return t is not None and bool(NUMERIC.fullmatch(t))


def shallow_depth(args):
    """Smallest explicit depth limit (find -maxdepth N, du -d N / --max-depth=N, tree -L N ...)."""
    best = None
    for k, w in enumerate(args):
        t = lit_text(w)
        if t is None:
            continue
        val = None
        if t in ("-maxdepth", "-d", "-L", "--max-depth", "--depth", "-mindepth") and k + 1 < len(args):
            val = lit_text(args[k + 1])
        elif t.startswith("--max-depth=") or t.startswith("--depth="):
            val = t.split("=", 1)[1]
        elif re.fullmatch(r"-[dL][0-9]+", t):
            val = t[2:]
        if val is not None and NUMERIC.fullmatch(val):
            if t != "-mindepth":
                best = int(val) if best is None else min(best, int(val))
    return best


# ----------------------------------------------------------------------------- listers / taint
LISTERS = {"ls", "find", "fd", "tree", "echo", "printf"}


def _operand_words(name, args):
    if name == "find":
        ops = []
        skip = {"-H", "-L", "-P", "-E", "-X", "-x", "-s", "-d"}
        for w in args:
            t = lit_text(w)
            if t is not None and t in skip:
                continue
            if t is not None and (t.startswith("-") or t in ("(", "!", ",")):
                break
            ops.append(w)
        return ops
    if name in ("echo", "printf"):
        return list(args)
    flags, ops, _ = parse_args(args)
    return [w for w in ops if not _numeric_word(w)]


def command_lists_home(name, args, st):
    """`ls ~`, `ls -A` with cwd=$HOME, `echo ~/*` ...: the OUTPUT is entries of $HOME."""
    if name not in LISTERS:
        return False
    ops = _operand_words(name, args)
    if not ops:
        if name in ("echo", "printf"):
            return False
        return classify(st.cwd, st) in ("home-root", "hot")
    for w in ops:
        for res in resolve(w, st):
            if res.tainted or kind_of(res, st) in ("home-root", "hot"):
                return True
    return False


def script_lists_home(script, st, depth=0):
    if depth > MAX_DEPTH:
        return False
    st = st.fork()
    for seg in script:
        words = list(seg.words)
        while words and lit_text(words[0]) in KEYWORDS:
            words.pop(0)
        while words and _is_assignment(words[0]):
            words.pop(0)
        if not words:
            continue
        for w in words:
            for sg in w.segs:
                if sg.kind == "sub" and script_lists_home(sg.script, st, depth + 1):
                    return True
        try:
            unwrapped = unwrap(words, st)
        except Abort:
            continue
        if unwrapped is None:
            continue
        name, args, _implicit = unwrapped
        if name in ("cd", "pushd"):
            _apply_cd(args, st)
            continue
        if command_lists_home(name, args, st):
            return True
    return False


# ----------------------------------------------------------------------------- wrappers
_ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def _is_assignment(w):
    if not w.segs or w.segs[0].kind != "lit" or w.segs[0].quoted:
        return False
    return bool(_ASSIGN.match(w.segs[0].text))


def _skip_opts(words, valued=()):
    """Drop leading -options (and the value of those in `valued`)."""
    i = 0
    while i < len(words):
        t = lit_text(words[i])
        if t is None or not t.startswith("-") or t == "-":
            break
        i += 2 if t in valued and i + 1 < len(words) else 1
    return words[i:]


def unwrap(words, st):
    """Strip env-style prefixes. Returns (name, args, implicit_stdin) or None when the command
    name is not a literal we can reason about."""
    implicit = False
    words = list(words)
    for _ in range(8):
        if not words:
            return None
        t = lit_text(words[0])
        if t is None:
            return None
        name = posixpath.basename(t)
        name = TOOL_ALIASES.get(name, name)
        rest = words[1:]
        if name in ("command", "builtin", "exec", "nohup", "setsid", "time"):
            opts = [lit_text(w) for w in rest[:2]]
            if name == "command" and ("-v" in opts or "-V" in opts):
                return None
            words = _skip_opts(rest)
        elif name == "env":
            rest = _skip_opts(rest, valued=("-u", "-C", "-S", "-P"))
            while rest and _is_assignment(rest[0]):
                rest = rest[1:]
            words = rest
        elif name in ("nice", "ionice", "stdbuf", "arch", "caffeinate", "sudo"):
            words = _skip_opts(rest, valued=("-n", "-c", "-u", "-t", "-w", "-o", "-e", "-i", "-g"))
        elif name in ("timeout", "gtimeout"):
            rest = _skip_opts(rest, valued=("-s", "-k", "--signal", "--kill-after"))
            words = rest[1:]
        elif name == "xargs":
            words = _skip_opts(rest, valued=("-I", "-n", "-P", "-L", "-d", "-s", "-E", "-a", "-J", "-R"))
            implicit = True
        else:
            return name, rest, implicit
    return None


def _apply_cd(args, st):
    flags, ops, _ = parse_args(args)
    if not ops:
        st.cwd = st.home
        return
    res = resolve(ops[0], st)[0]
    if lit_text(ops[0]) == "-":
        st.cwd = None
        return
    st.cwd = path_of(res, st)


# ----------------------------------------------------------------------------- scanners
class Ctx:
    def __init__(self):
        self.pipe_home = False


def _block(reason):
    raise Block(reason)


def _operand_findings(name, ops, st, ctx, implicit_cwd, args, allow_file, describe):
    """Common tail for recursive scanners: every operand (or the cwd) that is hot is a block."""
    shallow = shallow_depth(args)
    targets = []
    for w in ops:
        for res in resolve(w, st):
            targets.append(res)
    if not ops and implicit_cwd:
        cwd_res = Res(".", False)
        targets.append(cwd_res)
    for res in targets:
        p = path_of(res, st)
        kind = classify(p, st)
        if kind is None:
            continue
        if kind == "ancestor" and shallow is not None and shallow <= 2:
            continue
        if kind == "hot" and allow_file and p is not None and looks_like_file(p, st):
            continue
        shown = unquote_map(res.s).replace(DYN, "<?>").replace(HDYN, "<entry-of-$HOME>")
        _block("%s %s -- %s" % (name, shown if ops else "(cwd)", describe(kind)))


def _describe_recursive(kind):
    return {"home-root": "recurses over $HOME",
            "hot": "recurses into a macOS-protected folder",
            "ancestor": "recursing from / or /Users walks into $HOME"}[kind]


def check_command(name, args, st, ctx, implicit_stdin, stdin_is_pipe):
    if name in ("du", "dust", "gdu", "ncdu", "tree"):
        flags, ops, _ = parse_args(args, valued_short=("d", "L", "P", "I", "t", "B", "n"),
                                   valued_long=("--max-depth", "--exclude", "--threshold"))
        ops = [w for w in ops if not _numeric_word(w)]
        if implicit_stdin and ctx.pipe_home:
            _block("%s fed by a listing of $HOME through xargs" % name)
        _operand_findings(name, ops, st, ctx, True, args, name == "du", _describe_recursive)
        return
    if name == "find":
        ops = _operand_words("find", args)
        _operand_findings(name, ops, st, ctx, True, args, False, _describe_recursive)
        return
    if name in ("rg", "ag", "ack", "fd", "grep"):
        if name == "grep":
            flags, ops, values = parse_args(
                args, valued_short=("e", "f", "A", "B", "C", "m", "d", "D"),
                valued_long=("--regexp", "--file", "--include", "--exclude", "--exclude-dir",
                             "--max-count", "--context", "--after-context", "--before-context",
                             "--directories", "--devices", "--label"))
            recursive = bool(flags & {"r", "R", "--recursive", "--dereference-recursive"}) \
                or values.get("d") == "recurse" or values.get("--directories") == "recurse"
            if not recursive:
                return
        elif name == "rg":
            flags, ops, values = parse_args(
                args, valued_short=("e", "f", "g", "t", "T", "A", "B", "C", "m", "j", "M", "d", "r"),
                valued_long=("--regexp", "--file", "--glob", "--iglob", "--type", "--type-not",
                             "--max-depth", "--max-count", "--threads", "--context",
                             "--after-context", "--before-context", "--max-columns", "--replace",
                             "--type-add"))
        elif name == "fd":
            flags, ops, values = parse_args(
                args, valued_short=("e", "E", "d", "t", "S", "x", "X", "j", "c"),
                valued_long=("--extension", "--exclude", "--max-depth", "--type", "--size",
                             "--threads", "--color"))
        else:  # ag / ack
            flags, ops, values = parse_args(args, valued_short=("A", "B", "C", "G", "m", "g"),
                                            valued_long=("--ignore", "--file-search-regex"))
        has_pattern_flag = bool(flags & {"e", "f", "--regexp", "--file"})
        paths = ops if has_pattern_flag else ops[1:]
        # A pattern that looks like a path is examined too: `rg ~` is far more likely a path.
        if not has_pattern_flag and ops:
            t = lit_text(ops[0])
            if t is None or t.startswith(("/", "~", "$")):
                paths = ops
        # rg/ag/ack/fd/grep read stdin (not the cwd) when they are fed by a pipe
        implicit = not (stdin_is_pipe or implicit_stdin)
        _operand_findings(name, paths, st, ctx, implicit, args, False, _describe_recursive)
        return
    if name == "ls":
        flags, ops, _ = parse_args(args)
        if "d" in flags:
            return
        recursive = "R" in flags or "--recursive" in flags or "T" in flags
        if implicit_stdin and ctx.pipe_home:
            _block("ls fed by a listing of $HOME through xargs")
        ops = [w for w in ops if not _numeric_word(w)]
        targets = [r for w in ops for r in resolve(w, st)]
        if not ops:
            targets = [Res(".", False)]
        for res in targets:
            p = path_of(res, st)
            kind = classify(p, st)
            if kind is None:
                continue
            if recursive:
                if kind == "ancestor" and (shallow_depth(args) or 99) <= 2:
                    continue
                _block("ls -R %s -- %s" % (unquote_map(res.s) or "(cwd)", _describe_recursive(kind)))
            elif kind == "hot":
                if p is not None and looks_like_file(p, st):
                    continue
                _block("ls %s -- lists a macOS-protected folder" % (unquote_map(res.s) or "(cwd)"))
        return
    if name == "mdfind":
        flags, ops, values = parse_args(args, valued_short=(), valued_long=())
        for k, w in enumerate(args):
            if lit_text(w) == "-onlyin" and k + 1 < len(args):
                for res in resolve(args[k + 1], st):
                    kind = classify(path_of(res, st), st)
                    if kind is not None:
                        _block("mdfind -onlyin %s -- %s" % (unquote_map(res.s), _describe_recursive(kind)))
        return
    if name in ("rsync", "ditto", "tar", "zip", "cp", "scp"):
        flags, ops, values = parse_args(args, valued_short=("C",) if name == "tar" else (),
                                        valued_long=())
        if name == "tar" and args:
            first = lit_text(args[0])
            if first is not None and not first.startswith("-") and first.isalpha():
                flags |= set(first)          # old-style bundled flags: tar czf out.tgz dir
                ops = ops[1:] if ops and lit_text(ops[0]) == first else ops
        recursive = {"cp": bool(flags & {"R", "r", "a", "--recursive", "--archive"}),
                     "scp": "r" in flags,
                     "rsync": bool(flags & {"r", "a", "--recursive", "--archive"}),
                     "zip": "r" in flags,
                     "tar": True, "ditto": True}[name]
        if not recursive:
            return
        operands = list(ops)
        if name == "tar" and "f" in flags:
            if "f" in values:
                pass
            elif operands:
                operands = operands[1:]      # the archive itself
        for k, w in enumerate(args):
            if name == "tar" and lit_text(w) in ("-C", "--directory") and k + 1 < len(args):
                operands.append(args[k + 1])
        _operand_findings(name, operands, st, ctx, False, args, True, _describe_recursive)
        return


# ----------------------------------------------------------------------------- statement walker
def analyze_script(script, st, depth=0):
    if depth > MAX_DEPTH:
        raise Abort("nesting too deep")
    ctx = Ctx()
    for seg in script:
        if seg.op_before not in ("|", "|&"):
            ctx.pipe_home = False
        stdin_is_pipe = seg.op_before in ("|", "|&")
        for w in list(seg.words) + list(seg.extra):
            for sg in w.segs:
                if sg.kind == "sub":
                    analyze_script(sg.script, st.fork(), depth + 1)
        words = list(seg.words)
        while words and lit_text(words[0]) in KEYWORDS:
            words.pop(0)
        if not words:
            continue
        head = lit_text(words[0])
        if head in ("for", "select") and len(words) >= 3:
            var = lit_text(words[1])
            lst = words[3:] if lit_text(words[2]) == "in" else []
            if var and any(_word_home_derived(w, st) for w in lst):
                st.tainted.add(var)
            continue
        if head in ("case", "[", "[[", "((", "continue", "break", "return", "exit", "local",
                    "declare", "export", "readonly", "unset", "true", "false", ":"):
            if head in ("export", "local", "declare", "readonly"):
                _record_assignments(words[1:], st)
            continue
        assigns = []
        while words and _is_assignment(words[0]):
            assigns.append(words.pop(0))
        if not words:
            _record_assignments(assigns, st)
            continue
        if head == "read" or lit_text(words[0]) == "read":
            if ctx.pipe_home and seg.op_before in ("|", "|&"):
                flags, ops, _ = parse_args(words[1:], valued_short=("d", "n", "N", "p", "t", "u"))
                for w in ops:
                    t = lit_text(w)
                    if t:
                        st.tainted.add(t)
            continue
        unwrapped = unwrap(words, st)
        if unwrapped is None:
            continue
        name, args, implicit = unwrapped
        if name in SHELLS:
            flags, ops, _ = parse_args(args, valued_short=("o", "O"))
            if any(len(f) == 1 and f == "c" for f in flags) and ops:
                inner, _ = scan(render(ops[0]), 0, False, depth + 1)
                analyze_script(inner, st.fork(), depth + 1)
            continue
        if name == "eval":
            inner, _ = scan(" ".join(render(w) for w in args), 0, False, depth + 1)
            analyze_script(inner, st.fork(), depth + 1)
            continue
        if name in ("cd", "pushd"):
            _apply_cd(args, st)
            continue
        if name == "popd":
            st.cwd = None
            continue
        check_command(name, args, st, ctx, implicit, stdin_is_pipe)
        if command_lists_home(name, args, st):
            ctx.pipe_home = True
        elif implicit and ctx.pipe_home:
            ctx.pipe_home = True


def _word_home_derived(w, st):
    for res in resolve(w, st):
        if res.tainted:
            return True
        if kind_of(res, st) in ("home-root", "hot"):
            return True
        if res.s and res.s[0] in (DYN,) and classify(st.cwd, st) in ("home-root", "hot"):
            return True
    return False


def _record_assignments(assigns, st):
    for w in assigns:
        if not w.segs or w.segs[0].kind != "lit" or not _ASSIGN.match(w.segs[0].text):
            continue
        name, _, first_val = w.segs[0].text.partition("=")
        head = Seg("lit", first_val, w.segs[0].quoted)
        value_word = Word([head] + list(w.segs[1:]))
        res = resolve(value_word, st)[0]
        st.vars[name] = res.s
        if res.tainted:
            st.tainted.add(name)


def analyze(command, cwd, homes):
    script, _ = scan(command, 0, False, 0)
    analyze_script(script, State(homes, cwd or None))


# ----------------------------------------------------------------------------- entry point
MESSAGE = """home-scan-guard: BLOCKED ({reason}).
Why: macOS (TCC) blames every file access made by a Gas Town agent session on gc -- the
supervisor is the "responsible" process of tmux and of every session. Enumerating, measuring or
recursing over $HOME or a protected folder (Desktop, Documents, Downloads, Pictures, Movies,
Music, iCloud Drive = ~/Library/Mobile Documents, ~/Library/CloudStorage, /Volumes) makes macOS
show Athos the "gc wants to access ..." prompt, and a headless session blocks on it or is denied
in silence (ga-6cyp1l).
Instead:
  * disk space:           df -h /
  * what grew on disk:    read /Users/athos/gt/.gascity-gastown-hq/.gc/logs/disk-growth-*.txt
  * size of a known dir:  du -xsk on an EXPLICIT list of city roots, e.g.
                          du -xsk ~/gt ~/.gastown ~/.local /private/tmp/claude-501
  * one file the operator pointed you at in Downloads: read it by its exact path (cat / Read) --
    a single named file is not a scan.
Do not route around this with python os.walk / node fs.readdir: that touches the same folders and
raises the same prompt. If this block is wrong for your case, say so on the bead instead."""


def _log(result, reason, command, cwd):
    """One tab-separated line per event. BLOCKED = a block; GAVE-UP = deliberate fail-open (nesting
    too deep to trust); ENGINE-ERROR = an internal error, also a fail-open -- but a guard that fails
    open on its own bug is a guard that is silently OFF, so this line is the only trace of it and
    the selftest asserts none of its cases produced one."""
    path = os.environ.get("HOME_SCAN_GUARD_LOG") or os.path.join(
        os.path.expanduser("~"), ".gastown", "logs", "home-scan-guard.log")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        agent = (os.environ.get("GC_AGENT") or os.environ.get("GC_ALIAS")
                 or os.environ.get("GC_SESSION_NAME") or os.environ.get("GC_DIR") or "none")
        flat = (command or "").replace("\\", "\\\\").replace("\n", "\\n").replace("\t", " ")[:400]
        reason = str(reason).replace("\n", " | ").replace("\t", " ")[:600]
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("%s\tagent=%s\tresult=%s\treason=%s\tcwd=%s\tcmd=%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), agent, result, reason, cwd or "", flat))
    except Exception:
        pass


def main():
    command = cwd = None
    try:
        try:
            payload = json.loads(sys.stdin.read())
        except ValueError:
            return 0            # not JSON: expected bad input, not an engine bug
        if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
            return 0
        command = (payload.get("tool_input") or {}).get("command")
        if not isinstance(command, str) or not command.strip():
            return 0
        cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
        home = os.environ.get("HOME_SCAN_GUARD_HOME") or os.environ.get("HOME") or ""
        home = home.rstrip("/")
        if not home.startswith("/") or home.count("/") < 2:
            return 0           # no usable home: cannot classify anything, so do not guess
        homes = [home]
        alt = "/Users/" + posixpath.basename(home)
        if alt != home:
            homes.append(alt)
        analyze(command, cwd, homes)
        return 0
    except Block as blocked:
        reason = str(blocked)
        _log("BLOCKED", reason, command, cwd)
        sys.stderr.write(MESSAGE.format(reason=reason) + "\n")
        return 2
    except Abort as gave_up:
        _log("GAVE-UP", gave_up, command, cwd)
        return 0
    except BaseException as exc:    # noqa: B036 -- fail open, whatever went wrong ...
        import traceback
        tb = traceback.extract_tb(exc.__traceback__)
        where = "%s:%s" % (tb[-1].name, tb[-1].lineno) if tb else "?"
        _log("ENGINE-ERROR", "%s: %s at %s" % (type(exc).__name__, exc, where), command, cwd)   # ... but never silently
        return 0


if __name__ == "__main__":
    sys.exit(main())
