#!/usr/bin/env python3
"""home-scan-guard.py (ga-02cqk4) -- the classifier behind home-scan-guard.sh.

Reads a Claude Code PreToolUse hook payload on stdin. Exit 2 (+ a message on stderr, which Claude Code hands back to the
model) when the Bash command would ENUMERATE, MEASURE or READ RECURSIVELY $HOME or a macOS-protected folder; exit 0 in every
other case, INCLUDING every internal error (fail-open: a guard that breaks all Bash calls of all agents is worse than the
problem).

WHY (ga-6cyp1l, 26/09 14:52): a crew session ran
    cd /Users/athos && for d in $(ls -A); do ... timeout 60 du -xsk "$d" ...; done
and four `du` calls hit Desktop, Documents, Downloads and Photos in ~1s. macOS TCC blames every file access of an agent
session on gc (the supervisor is the "responsible" process of tmux and of every session): Athos saw "gc wants to access ...",
and a headless session blocks on it or is denied in silence. Prose does not restrict a tool (ga-1udgm); this is the stop.

WHAT IT IS: a small LEXICAL net for that one pattern -- a recursive scanner (du, find, ls -R, tree, ncdu, rg, grep -r, rsync,
cp -r, tar c, rm -r, mv, chmod/chown -R, xattr -r, ...) that meets $HOME, an ancestor of it, a protected folder, or a cwd that
is one of those -- and NOTHING ELSE. rm/mv/chmod/chown/xattr are included because they readdir() the whole tree too, the exact
TCC trigger this bead is about, even though they modify rather than read.
It never touches a path the command mentions (not even a stat: from the guard that would itself be the TCC access). Not a sandbox.

WHY IT IS SMALL (read this before making it bigger). Gate rounds 1-4 each reproduced one more spelling of ONE defect in a
larger design: tables said which option of which tool takes a value, which wrapper option does, which depth flag stops the
walk, which variable "is a listing of $HOME"; every wrong or MISSING entry silently turned a scan into "not hot" (`caffeinate
-i du ~`, `rg --sort path foo` from $HOME, `find /Users -maxdepth 1 | xargs du`). The Mayor's decision (26/09 00:49): no fifth
round of that design; a smaller guard that is right beats a complete one that does not pass. So this one asks nothing about
what an option means: it reads EVERY non-dash word of a scanner's command as a candidate path, and wrappers need no table
(`sudo -n du ~` is just words around `du`). home-scan-guard.selftest.sh locks that FORM.

THE RULES. A word is HOT if -- after ~ / $HOME / tracked-variable / brace expansion, `..` normalising, and resolving
relative words against the possible cwds -- it is $HOME, an ancestor of it (/ and /Users), /Volumes, ~/Library, a protected
folder or anything under one (Desktop Documents Downloads Pictures Movies Music .Trash, Library/{Mobile Documents,
CloudStorage, Containers, Group Containers, Mail, Messages, Safari}), or an entry of $HOME a glob / run-time value can name.
  A. A SEGMENT (one simple command: ; && || | ( ) and newline end it) with a recursive scanner and a hot word: BLOCK.
     The one exemption: `find / -maxdepth 1|2` (an ancestor, and a depth flag that does stop find).
  A'. A plain `ls` (no -d) of a protected folder itself, or of a glob over $HOME / a protected folder: BLOCK. (`ls ~`, `ls ~/gt`
     and `ls -l ~/Downloads/one-file.pdf` are fine.) Anything under a Drive / iCloud mount counts: those mounts hang a session.
  B. A scanner that can run with NO explicit operand at all (du, find, tree, ncdu, rg-family, grep -r, ls, eza -- the ones
     that implicitly walk the cwd when given none) while ANY cwd it may run in is $HOME / an ancestor / a protected folder /
     /Volumes: BLOCK, whatever its operands say (an absolute path can be an option's VALUE, and options are not read here).
     cp/tar/zip/rsync/rm/mv/chmod/chown/xattr/chflags always need an explicit operand -- rule A already catches every
     resolvable one (including a bare "." or "$var", which reads the cwd through a different path). The possible cwds are the
     payload's cwd plus the target of every `cd` / `pushd` seen so far (a set that only grows). This is the incident: `cd
     $HOME && ... du "$d"`. Measured on 9,334 real agent commands: none had a hot payload cwd, so this costs nothing in practice.
  C. A LISTING PRODUCER (ls, find, echo, printf, a for-list) naming $HOME or an ancestor -- or ANY command carrying a glob that
     matches protected names (`stat ~/*`) -- and a scanner ANYWHERE in the same command (a plain `ls` is one once its operand
     is fed: xargs, a loop variable, `{}`): BLOCK -- the whole "a listing feeds a measurement" family (xargs, while read,
     $( ), mapfile, sh -c): no data-flow, just co-occurrence.
Variables: `NAME=value` and `for NAME in words` are tracked (a hot value makes `$NAME` hot); nothing else is. Quoted strings that
are COMMANDS (the word after a shell's -c, the words after eval / watch / parallel, `env -S`) are lexed again as scripts; other
quoted text -- a commit message, a bead comment, an echo, an argument of a script -- is data.

ACCEPTED FALSE POSITIVES (the selftest pins them): the guard errs toward blocking where guessing was the bug -- `du` of ONE
file under Downloads (use cat / stat / Read), `mv` of ONE file into or out of a protected folder (`mv` has no recursion flag to
gate on, and text alone cannot tell "a same-volume rename" -- instant, no readdir -- from "a cross-volume copy" -- which does
readdir a directory but not a single file -- so `mv` is treated like `cp -r`, unconditionally), `tree -L 2 /`, `find ~
-maxdepth 1`, any scan run from $HOME or a protected cwd, even with an explicit safe path (`cd ~ && du -sk ~/gt`), a hot `cd`
earlier in the command taints the cwd for the rest of it (even inside a subshell), a search PATTERN spelled like a hot path,
and a listing of $HOME plus a scanner in one command (run two).

KNOWN GAPS (pinned too; not chased -- the bead is about CLI scanners, not an adversary):
  * a scan through an interpreter (python os.walk, node fs.readdir), a script FILE (`bash x.sh`), a script on a shell's stdin
    (`bash <<EOF`), a function / alias, `eval "$var"` (a bare `$T -sk ~` DOES resolve if T is tracked -- eval's OWN argument
    does not); a target known only at run time (`du -sk "$1"`, `"${X:-$HOME}"`) from a
    cwd that is not itself hot; `env -C DIR` / `sudo -D DIR` (read as a word, not as a cd); the spelling `$'\\x2fUsers'`;
  * a glob under a protected folder handed to something that is NOT a scanner (`cat ~/Downloads/*.csv`: reading the files the
    operator pointed at is the legitimate use of Downloads), `git -C ~ status`, a listing saved to a FILE and measured later,
    and any tool the tables above do not name (duf, dua, erdtree, ugrep, doas -- not one of the plain names this file matches);
  * WHO IS GUARDED: the crews / witness / refinery settings.json (home-scan-guard-activate.sh) and the four pool overlays that
    carry the hook (dog, ps-worker, reviewer, wa-worker: pool-roles.json). NOT guarded: the Mayor, boot, the deacon, auto-refiner
    and context-check-reviewer (base pool overlay, no hook), any other workdir, and the built-in Grep / Glob tools of every
    session (the matcher is `^Bash$`). Those rely on the doctrine text alone;
  * FAIL-OPEN, said without softening: an internal error is an ALLOW (logged ENGINE-ERROR after the fact); input that is not UTF-8
    or has no usable home is an ALLOW (GAVE-UP); a relative scan whose cwd is unknown is an ALLOW (UNKNOWN-CWD). No depth cap
    is one of them: $( ) nested past MAX_DEPTH_LEX is read flat, quoted scripts nested past MAX_SCRIPT_DEPTH are BLOCKED.
"""
import json
import os
import posixpath
import re
import sys
import time
import warnings
from collections import deque

warnings.filterwarnings("ignore")   # a stray warning on stderr would break the wrapper's own marker check (its first line)
_POSIX_CLASS = re.compile(r"\[(?:\[:[a-z]+:\])+\]")   # a WHOLE bracket made of one or more POSIX classes: [[:upper:]], [[:upper:][:digit:]]

# ----------------------------------------------------------------------------- policy
# Names are compared case-insensitively: the macOS volume is case-insensitive by default, so ~/downloads IS ~/Downloads.
PROTECTED_TOP = ("desktop", "documents", "downloads", "pictures", "movies", "music", ".trash")
LIBRARY_HOT = ("mobile documents", "cloudstorage", "containers", "group containers", "mail", "messages", "safari")

# The recursive scanners. Which words of a segment are scanners is a fact about the NAME (basename, case-folded); whether
# the segment RECURSES is decided per family below, and only from switches the family defines (-R, -r, a create mode).
ALWAYS = frozenset(["du", "gdu", "dust", "ncdu", "tree", "fd", "fdfind", "rg", "ripgrep", "ag", "ack", "mdfind", "ditto"])
FIND = frozenset(["find", "gfind"])
GREP = frozenset(["grep", "egrep", "fgrep", "zgrep", "ggrep"])
LS = frozenset(["ls", "gls"])
EZA = frozenset(["eza", "exa", "lsd"])            # not ls: they spell recursion -T / --tree, and `ls -T` is a timestamp switch
CP = frozenset(["cp", "gcp"])
RSYNC = frozenset(["rsync"])
ZIP = frozenset(["zip"])
TAR = frozenset(["tar", "gtar", "bsdtar"])
RM = frozenset(["rm"])
CHFLAGS = frozenset(["chflags"])
CHMOD_CHOWN = frozenset(["chmod", "chown"])
XATTR = frozenset(["xattr"])
MOVE = frozenset(["mv", "gmv"])   # no flag needed: `mv` across filesystems copies+deletes the WHOLE tree (readdir), like cp -r
# Rule B (a bare invocation with no resolvable operand implicitly walks the cwd) only applies to tools that HAVE that mode:
# du/find/tree/rg-family/grep -r/ls/eza bare or with just flags operate on the cwd. cp/tar/zip/rsync/rm/mv/chmod/chown/xattr/
# chflags all REQUIRE an explicit operand (or do nothing) -- rule A (their operand IS a hot word) already catches every
# resolvable one, including a bare "." or "$var" (absolutize() reads self.cwds directly, unaffected by this set).
IMPLICIT_CWD = ALWAYS | FIND | GREP | LS | EZA
PRODUCERS = LS | EZA | FIND | frozenset(["echo", "printf", "for", "select"])
LISTING = frozenset(["home", "ancestor", "home-glob"])   # kinds of hit that mean "the ENTRIES of $HOME" when a producer names them
GLOB_LISTING = frozenset(["home-glob"])                  # ...and a glob over $HOME IS a listing, whatever command carries it
# The quoted strings that are COMMANDS (lexed again as scripts): the word after a shell's -c (`bash -c '...'`, `sudo sh -lc '...'`),
# every quoted word after eval / watch / parallel, and `env -S '...'`. Any other quoted text is data: a commit message, a bead
# comment, an argument of a script (`bash probe.sh 'du -sk ~'`).
SHELLS = frozenset(["sh", "bash", "zsh", "dash", "ksh", "su"])
EVALS = frozenset(["eval", "watch", "parallel"])
DATA_CMDS = frozenset(["echo", "printf"])      # print their arguments, never run them: `echo du ~/Downloads` is not a scan
PROGRAMS = ALWAYS | FIND | GREP | LS | EZA | CP | RSYNC | ZIP | TAR | SHELLS | EVALS | PRODUCERS   # a bare program name is not an operand
CD_PREFIX = frozenset(["then", "do", "else", "elif", "if", "while", "until", "{", "!", "builtin", "command", "time", "exec"])

MAX_DEPTH_LEX = 12        # nesting of $( ) / ` ` / <( ): past it the text is lexed FLAT (separators), never dropped
MAX_SCRIPT_DEPTH = 64     # nesting of quoted scripts (bash -c '... bash -c ...'): past it the command is BLOCKED, never allowed
MAX_ALTERNATIVES = 64     # a bound on WORK: a brace expression past it is a hit ("could be anything"), not a pass
MAX_WORD = 2048           # no path is longer than that on macOS; a longer word is not one

# ----------------------------------------------------------------------------- the lexer's private alphabet
DYN = "\ue000"            # a value the text does not reveal ($(...), $1, ${x:-y})
TOK0, TOK1 = "\ue020", "\ue021"   # TOK0 NAME TOK1 = a reference to variable NAME
_SPECIAL = "*?[]{},~$"
_LIT = {c: chr(0xE100 + i) for i, c in enumerate(_SPECIAL)}     # a quoted / escaped special char loses its meaning
_UNLIT = {v: k for k, v in _LIT.items()}
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
_TOKRE = re.compile(TOK0 + r"([A-Za-z0-9_]+)" + TOK1)
_BR = re.compile(r"\{([^{}]*,[^{}]*)\}")
_BR_SEQ = re.compile(r"\{[^{},]*\.\.[^{},]*\}")
_MULTI = re.compile(r"[\s;&|]")
_BARE_DYN = re.compile("(?:" + DYN + "|" + TOK0 + "[A-Za-z0-9_]+" + TOK1 + ")+")


_UNLIT_TABLE = str.maketrans(dict(_UNLIT, **{DYN: "?"}))


def lit(s):
    """Text from OUTSIDE the command (the home, the payload's cwd) in the classifier's alphabet: its glob characters are just characters."""
    return "".join(_LIT.get(c, c) for c in s)


def unlit(t):
    """The text as a reader sees it: quoted specials back to themselves, a variable as $NAME, an unknown value as ?."""
    return _TOKRE.sub(lambda m: "$" + m.group(1), t).translate(_UNLIT_TABLE)


class Block(Exception):
    pass


class Word:
    __slots__ = ("t", "p", "b")

    def __init__(self, t, p):
        self.t = t        # classification form: real globs/braces/~/$ only where the shell would act on them
        self.p = p        # plain form: one level of quoting removed, for lexing again as a script
        self.b = None     # cached program name (Analyzer.base)


class Lexer:
    """A working subset of the shell grammar: quotes, escapes, comments, heredocs, redirections (their target is not an
    operand), $( ), backticks, <( ), ${ }, and the separators ; & && || | ( ) newline. It yields SEGMENTS (lists of Word),
    nested substitutions first, which is also the order they run in."""

    def __init__(self, s, depth=0):
        self.s, self.n, self.depth = s, len(s), depth
        self.out, self.cur = [], []
        self.t, self.p, self.in_word, self.drop = [], [], False, False
        self.paren, self.heredocs = 0, []

    # -- words and segments
    def end_word(self):
        if not self.in_word:
            return
        w = Word("".join(self.t), "".join(self.p))
        self.t, self.p, self.in_word = [], [], False
        if self.drop:
            self.drop = False          # a redirect's target is a file name, not an operand
        else:
            self.cur.append(w)

    def end_seg(self):
        self.end_word()
        if self.cur:
            self.out.append(self.cur)
        self.cur, self.drop = [], False

    def add(self, c):
        self.in_word = True
        if c == "~" and self.t and not (len(self.t) < 64 and _ASSIGN.fullmatch("".join(self.t))):
            c = _LIT["~"]              # ~ expands at the start of a word and right after NAME= only
        self.t.append(c)
        self.p.append(c)

    def add_lit(self, c, plain=None):
        self.in_word = True
        self.t.append(_LIT.get(c, c))
        self.p.append(c if plain is None else plain)

    # -- driver
    def lex(self):
        self.run(0, False)
        return self.out

    def run(self, i, stop_close):
        s, n = self.s, self.n
        while i < n:
            c = s[i]
            if c in " \t":
                self.end_word(); i += 1
            elif c == "\n":
                self.end_seg(); i += 1
                if self.heredocs:
                    i = self.take_heredocs(i)
            elif c == "\\":
                if i + 1 < n and s[i + 1] != "\n":
                    self.add_lit(s[i + 1], "\\" + s[i + 1])
                i += 2 if i + 1 < n else 1
            elif c == "'":
                i = self.single(i + 1)
            elif c == '"':
                i = self.double(i + 1)
            elif c == "`":
                i = self.backtick(i + 1)
            elif c == "$":
                i = self.dollar(i, False)
            elif c == "#" and not self.in_word:
                k = s.find("\n", i)
                i = n if k < 0 else k
            elif c in ";|":
                self.end_seg(); i += 1
            elif c == "&":
                if s.startswith("&>", i):
                    self.end_word(); self.drop = True; i += 3 if s.startswith("&>>", i) else 2
                else:
                    self.end_seg(); i += 1
            elif c == "(":
                self.end_seg(); self.paren += 1; i += 1
            elif c == ")":
                self.end_seg(); i += 1
                if self.paren > 0:
                    self.paren -= 1
                elif stop_close:
                    return i
            elif c in "<>":
                i = self.redirect(i)
            else:
                self.add(c); i += 1
        self.end_seg()
        return n

    # -- quoting
    def single(self, i):
        k = self.s.find("'", i)
        k = self.n if k < 0 else k
        self.in_word = True
        for ch in self.s[i:k]:
            self.add_lit(ch)
        return min(k + 1, self.n)

    def double(self, i):
        s, n = self.s, self.n
        self.in_word = True
        while i < n and s[i] != '"':
            c = s[i]
            if c == "\\" and i + 1 < n:
                d = s[i + 1]
                if d in '"\\$`':
                    self.add_lit(d, d)
                elif d != "\n":
                    self.add_lit("\\"); self.add_lit(d)
                i += 2
            elif c == "$":
                i = self.dollar(i, True)
            elif c == "`":
                i = self.backtick(i + 1)
            else:
                self.add_lit(c); i += 1
        return min(i + 1, n)

    def dollar(self, i, quoted):
        s, n = self.s, self.n
        nx = s[i + 1] if i + 1 < n else ""
        self.in_word = True
        if nx == "(":
            return self.subshell(i, i + 2, DYN)
        if nx == "{":
            k = s.find("}", i + 2)
            k = n if k < 0 else k
            body = s[i + 2:k]
            if _NAME.fullmatch(body):
                self.t.append(TOK0 + body + TOK1)
            else:
                self.t.append(DYN)
                if self.depth < MAX_DEPTH_LEX and body:       # ${x:-$(cmd)} still runs cmd
                    self.out.extend(Lexer(body, self.depth + 1).lex())
            self.p.append(s[i:k + 1])
            return min(k + 1, n)
        if nx == "'" and not quoted:
            return self.single(i + 2)
        if nx == '"' and not quoted:
            return self.double(i + 2)
        m = _NAME.match(s, i + 1)
        if m:
            self.t.append(TOK0 + m.group(0) + TOK1); self.p.append(s[i:m.end()])
            return m.end()
        if nx and nx in "0123456789@*#?$!-":
            self.t.append(DYN); self.p.append(s[i:i + 2])
            return i + 2
        self.add_lit("$")
        return i + 1

    def subshell(self, start, i, placeholder):
        """$( ... ) and <( ... ): lex the body with the SAME lexer (so quotes, heredocs and nested parens agree about
        where it ends). Past MAX_DEPTH_LEX it is read flat: the opener becomes a separator, its `)` closes it."""
        self.in_word = True
        self.t.append(placeholder)
        if self.depth >= MAX_DEPTH_LEX:
            self.end_seg(); self.paren += 1
            return i
        sub = Lexer(self.s, self.depth + 1)
        j = sub.run(i, True)
        self.out.extend(sub.out)
        self.p.append(self.s[start:j])
        return j

    def backtick(self, i):
        s, n = self.s, self.n
        k = i
        while k < n and s[k] != "`":
            k += 2 if s[k] == "\\" else 1
        k = min(k, n)
        self.in_word = True
        self.t.append(DYN)
        self.p.append("`" + s[i:k] + "`")
        if self.depth < MAX_DEPTH_LEX + 2:
            inner = re.sub(r"\\([`\\$])", r"\1", s[i:k])
            self.out.extend(Lexer(inner, self.depth + 1).lex())
        else:
            self.end_seg()
        return min(k + 1, n)

    # -- redirections and heredocs
    def redirect(self, i):
        s, n = self.s, self.n
        if s.startswith("<<<", i):
            self.end_word(); self.drop = True
            return i + 3
        if s.startswith("<<", i):
            return self.heredoc(i)
        if i + 1 < n and s[i + 1] == "(":
            return self.subshell(i, i + 2, DYN)
        j = i + 1
        if s[i] == ">" and j < n and s[j] in ">|&":
            j += 1
        elif s[i] == "<" and j < n and s[j] in "&>":
            j += 1
        if self.in_word and "".join(self.t).isdigit():
            self.t, self.p, self.in_word = [], [], False       # `2>` : the digits are a file descriptor
        else:
            self.end_word()
        self.drop = True
        return j

    def heredoc(self, i):
        s, n = self.s, self.n
        j = i + 2
        strip = j < n and s[j] == "-"
        j += 1 if strip else 0
        while j < n and s[j] in " \t":
            j += 1
        quoted, delim = False, []
        while j < n and s[j] not in " \t\n;|&()<>":
            c = s[j]
            if c in "'\"":
                k = s.find(c, j + 1)
                k = n if k < 0 else k
                delim.append(s[j + 1:k]); quoted = True; j = min(k + 1, n)
            elif c == "\\" and j + 1 < n:
                delim.append(s[j + 1]); quoted = True; j += 2
            else:
                delim.append(c); j += 1
        self.end_word()
        if delim:
            self.heredocs.append(("".join(delim), strip, quoted))
        else:
            self.drop = True
        return j

    def take_heredocs(self, i):
        """Skip each pending body. A body whose terminator never comes is NOT skipped: the text is read as code (a phantom
        `<<` such as `(( 1 << 3 ))` must not be able to swallow the rest of the command)."""
        s, n = self.s, self.n
        for delim, strip, quoted in self.heredocs:
            j = i
            while j <= n:
                k = s.find("\n", j)
                end = n if k < 0 else k
                line = s[j:end]
                if (line.lstrip("\t") if strip else line) == delim:
                    if not quoted:
                        self.scan_substitutions(s[i:j])
                    i = n if k < 0 else k + 1
                    break
                if k < 0:
                    break
                j = k + 1
        self.heredocs = []
        return i

    def scan_substitutions(self, body):
        """An UNQUOTED heredoc body still runs its $( ) and backticks. A single forward pass: a match already covered by a
        substitution just consumed (each `$(` / backtick is read AT MOST once) is skipped, so many stray/unclosed openers --
        `cat <<EOF` followed by hundreds of bare `$(` -- cost one linear scan, not one re-lex of the tail per opener (the
        thing that made it hang: re-lexing the remaining body from EVERY match independently was O(matches x body length))."""
        if self.depth >= MAX_DEPTH_LEX:
            return
        done = 0
        for m in re.finditer(r"(?<!\\)(\$\(|`)", body):
            if m.start() < done:
                continue
            if m.group(1) == "`":
                k = body.find("`", m.end())
                end = k if k >= 0 else len(body)
                self.out.extend(Lexer(body[m.end():end], self.depth + 1).lex())
                done = end + 1
            else:
                sub = Lexer(body, self.depth + 1)
                done = sub.run(m.end(), True)
                self.out.extend(sub.out)


# ----------------------------------------------------------------------------- paths
class Hit:
    __slots__ = ("kind", "desc", "root")

    def __init__(self, kind, desc, root=False):
        self.kind, self.desc, self.root = kind, desc, root


DESC = {
    "home": "it is $HOME itself",
    "ancestor": "it is an ancestor of $HOME (/ or /Users): a walk from there enters $HOME",
    "volumes": "it is under /Volumes (external and network volumes)",
    "library": "it is ~/Library, which holds the protected Mobile Documents / CloudStorage / Mail / Messages / Safari / Containers",
    "protected": "it is a macOS-protected folder (Desktop, Documents, Downloads, Pictures, Movies, Music, iCloud Drive, CloudStorage)",
    "home-glob": "it is a glob over $HOME that matches protected folders",
    "home-dyn": "it is an entry of $HOME chosen at run time, which can be a protected folder",
    "unknown": "it is a brace expression too big to expand, so it could name anything",
}


CWD_LABEL = {"home": "$HOME", "ancestor": "an ancestor of $HOME (/ or /Users)", "volumes": "under /Volumes",
             "library": "~/Library", "protected": "a macOS-protected folder"}


def _special(c):
    return any(x in c for x in "*?[") or DYN in c or TOK0 in c


_ANY = re.compile(".*", re.S)


def comp_regex(c):
    if c.count("*") + c.count(DYN) + c.count(TOK0) > 4:      # `*a*a*a*...x` is exponential to match: it could be anything, so it is
        return _ANY
    c = _POSIX_CLASS.sub("?", c)   # [[:upper:]] etc: one unknown char, read as a plain wildcard OUTSIDE any bracket -- not fed
                                    # raw to re (which warns "nested set" and, left inside "[...]", matches nothing real)
    out, i, n = [], 0, len(c)
    while i < n:
        ch = c[i]
        if ch == "*":
            out.append(".*")
        elif ch == "?":
            out.append(".")
        elif ch == DYN:
            out.append(".*")
        elif ch == TOK0:
            k = c.find(TOK1, i)
            i = n if k < 0 else k
            out.append(".*")
        elif ch == "[":
            k = c.find("]", i + 2)
            if k < 0:
                out.append(r"\[")
            else:
                cls = c[i + 1:k].replace("\\", "\\\\")
                out.append("[" + ("^" + cls[1:] if cls[:1] in "!^" else cls) + "]")
                i = k
        else:
            out.append(re.escape(_UNLIT.get(ch, ch)))
        i += 1
    return re.compile("".join(out), re.S)


_RX = {}


def comp_matches(comp, name):
    """Could the (lower-cased) path component `comp` -- literal, glob or run-time value -- be `name`?"""
    if not _special(comp):
        return comp.translate(_UNLIT_TABLE) == name
    rx = _RX.get(comp)
    if rx is None:
        try:
            rx = _RX[comp] = comp_regex(comp)
        except re.error:
            return True                  # a pattern we cannot read could be anything: fail toward blocking
    return rx.fullmatch(name) is not None


def brace_expand(s):
    """Alternatives of the REAL braces in s (a quoted brace was neutralised by the lexer); None past the work bound."""
    if len(s) > MAX_WORD:
        return [s]
    s = _BR_SEQ.sub(DYN, s)
    work, done = [s], []
    while work:
        x = work.pop()
        m = _BR.search(x)
        if not m:
            done.append(x)
            continue
        if len(work) + len(done) > MAX_ALTERNATIVES:
            return None
        for alt in m.group(1).split(","):
            work.append(x[:m.start()] + alt + x[m.end():])
    return done


def dash_candidates(t):
    """An option can carry a path glued to it: --directory=/Users/athos, -C/Users/athos, -xzC$HOME."""
    out = []
    if "=" in t:
        out.append(t.split("=", 1)[1])
    m = re.search(r"[/~]|" + TOK0, t)
    if m and not t.startswith("--"):
        out.append(t[m.start():])
    return out


class Analyzer:
    def __init__(self, homes, cwd):
        homes = [h.rstrip("/") for h in homes]
        self.homes = [lit(h) for h in homes]                      # what `~` and $HOME expand to, in the classifier's alphabet
        self.home_names = {posixpath.basename(h).lower() for h in homes}
        self.home_comps = [[c.lower() for c in h.split("/") if c] for h in homes]     # plain text: the SUBJECT of comp_matches
        self.cwds = []
        if isinstance(cwd, str) and cwd.startswith("/"):
            self.cwds.append(lit(posixpath.normpath(cwd)))
        self.cwd_unknown = False
        self.vars, self.cache = {}, {}
        self.notes = []
        self.listing = self.tool = None        # rule C: (word, hit) / scanner name, over the WHOLE command

    # ---------------------------------------------------------------- expansion
    def dirty(self):
        self.cache = {}

    def subst(self, a):
        for _ in range(3):
            def rep(m):
                name = m.group(1)
                if name in self.vars:
                    return self.vars[name]
                if name == "HOME":
                    return self.homes[0]
                return m.group(0)
            b = _TOKRE.sub(rep, a)
            if b == a:
                break
            a = b
        return a

    def absolutize(self, a):
        a = self.subst(a)
        if a.startswith("~"):
            m = re.match(r"~([^/]*)(.*)$", a, re.S)
            if m.group(1) == "" or m.group(1).lower().translate(_UNLIT_TABLE) in self.home_names:
                return [self.homes[0] + m.group(2)]
            return []                               # ~other, ~+, ~-: not a path this guard can read
        if a.startswith("/"):
            return [a]
        pwd = TOK0 + "PWD" + TOK1
        if a.startswith(pwd):
            return [c + a[len(pwd):] for c in self.cwds]
        if not a or a[0] in (DYN, TOK0) or not self.cwds:
            return []
        return [c + "/" + a for c in self.cwds]

    def classify_path(self, p):
        comps = []
        for c in p.split("/"):
            if c in ("", "."):
                continue
            if c == "..":
                if comps:
                    comps.pop()
                continue
            comps.append(c)
        low = [c.lower() for c in comps]
        if low[:3] == ["system", "volumes", "data"]:      # the firmlink: /System/Volumes/Data/Users/x IS /Users/x
            comps, low = comps[3:], low[3:]
        if not comps:
            return [Hit("ancestor", DESC["ancestor"])]
        hits = []
        if comp_matches(low[0], "volumes"):
            hits.append(Hit("volumes", DESC["volumes"]))
        for hc in self.home_comps:
            n = len(hc)
            if len(low) < n and all(comp_matches(low[i], hc[i]) for i in range(len(low))):
                hits.append(Hit("ancestor", DESC["ancestor"]))
            elif len(low) >= n and all(comp_matches(low[i], hc[i]) for i in range(n)):
                hits.extend(self.classify_home(low[n:]))
        return hits

    def classify_home(self, low):
        if not low:
            return [Hit("home", DESC["home"])]
        r0 = low[0]
        rest_special = all(_special(c) for c in low[1:])
        if _special(r0):
            if _BARE_DYN.fullmatch(r0):
                return [Hit("home-dyn", DESC["home-dyn"])]
            if any(comp_matches(r0, name) for name in PROTECTED_TOP + ("library",)):
                return [Hit("home-glob", DESC["home-glob"])]
            return []
        if r0 in PROTECTED_TOP:
            return [Hit("protected", DESC["protected"], rest_special)]
        if r0 == "library":
            if len(low) == 1:
                return [Hit("library", DESC["library"])]
            r1 = low[1]
            if (_special(r1) and any(comp_matches(r1, name) for name in LIBRARY_HOT)) or r1 in LIBRARY_HOT:
                return [Hit("protected", DESC["protected"], True)]   # Drive / iCloud mounts: any `ls` under them is a listing
        return []

    def hits_of_text(self, text):
        if text in self.cache:
            return self.cache[text]
        res = []
        if len(text) <= MAX_WORD:
            alts = brace_expand(text)
            if alts is None:
                res = [Hit("unknown", DESC["unknown"])]
            else:
                for a in alts:
                    for p in self.absolutize(a):
                        res.extend(self.classify_path(p))
        self.cache[text] = res
        return res

    def hits_of(self, w):
        cands = dash_candidates(w.t) if w.t.startswith("-") else [w.t]
        return [h for c in cands for h in self.hits_of_text(c)]

    # ---------------------------------------------------------------- words
    def base(self, w):
        """The lower-cased basename of a word that names a program (an absolute path counts only under a bin dir). A word that
        is PURELY a variable reference (`$T`, `${cmd}`) is resolved through tracked assignments first (`T=du; $T -sk ~` runs
        `du` exactly as real bash does): only a fully-resolved literal counts, never a value the text still cannot show."""
        if w.b is None:
            t = w.t
            if _BARE_DYN.fullmatch(t):
                r = self.subst(t)
                if DYN not in r and TOK0 not in r:
                    t = r
            w.b = ""
            if not any(c in t for c in "*?[{" + DYN + TOK0):
                lit = unlit(t).lower()
                d, _, name = lit.rpartition("/")
                if not d or d.endswith("bin") or d.endswith("gnubin"):
                    w.b = name
        return w.b

    def tools(self, words):
        """-> (names of the RECURSIVE scanners in the segment, is a plain `ls` listing something, depth of a find)"""
        flags = [unlit(w.t) for w in words if w.t.startswith("-")]
        shorts = [f[1:] for f in flags if not f.startswith("--")]

        def cluster(chars):
            return any(ch in f for f in shorts for ch in chars)

        def long(*names):
            return any(f.split("=")[0] in names for f in flags)
        has_git = any(self.base(x) == "git" for x in words)               # hoisted: O(n) once, not once per grep-family word
        has_recurse_word = any(unlit(x.t) == "recurse" for x in words)
        rec, lister = [], False
        for i, w in enumerate(words):
            b = self.base(w)
            if not b:
                continue
            if b in ALWAYS or b in FIND:
                rec.append(b)
            elif b in GREP:
                if cluster("rR") or has_git or has_recurse_word or long("--recursive", "--dereference-recursive", "--directories=recurse"):
                    rec.append(b)
            elif b in LS or b in EZA:
                if (cluster("RT") or long("--recursive", "--recurse", "--tree")) if b in EZA else (cluster("R") or long("--recursive")):
                    rec.append(b)
                elif not cluster("d") and not long("--directory"):
                    lister = True
            elif b in CP and (cluster("rRa") or long("--recursive", "--archive")):
                rec.append(b)
            elif b in RSYNC and (cluster("ar") or long("--archive", "--recursive")):
                rec.append(b)
            elif b in ZIP and (cluster("rR") or long("--recurse-paths")):
                rec.append(b)
            elif b in TAR:
                nxt = unlit(words[i + 1].t) if i + 1 < len(words) else ""
                if cluster("c") or long("--create") or (re.fullmatch(r"[A-Za-z]+", nxt) and "c" in nxt):
                    rec.append(b)
            elif b in RM and cluster("rR"):
                rec.append(b)
            elif (b in CHFLAGS or b in CHMOD_CHOWN) and cluster("R"):
                rec.append(b)
            elif b in XATTR and cluster("r"):
                rec.append(b)
            elif b in MOVE:
                rec.append(b)
        return rec, lister, self.find_depth(words)

    @staticmethod
    def find_depth(words):
        depth = None
        for i, w in enumerate(words):
            if unlit(w.t) == "-maxdepth":
                v = unlit(words[i + 1].t) if i + 1 < len(words) else ""
                if not v.isdigit():
                    return None                     # a limit the text does not show is no limit
                depth = max(depth or 0, int(v))
        return depth

    # ---------------------------------------------------------------- state
    def assign(self, w):
        m = _ASSIGN.match(w.t)
        self.vars[m.group(1)] = w.t[m.end():]
        self.dirty()

    def for_var(self, words):
        name = unlit(words[1].t)
        hot = next((w for w in words[3:] if self.hits_of(w)), None)
        if hot is not None:
            self.vars[name] = hot.t
        else:
            self.vars.pop(name, None)
        self.dirty()

    def maybe_cd(self, words):
        j = next((i for i, w in enumerate(words) if self.base(w) in ("cd", "pushd")), None)
        if j is None or any(self.base(w) not in CD_PREFIX and not _ASSIGN.match(w.t) for w in words[:j]):
            return
        args = [w for w in words[j + 1:] if not w.t.startswith("-")]
        if any(w.t == "-" for w in words[j + 1:]) and not args:
            return                                     # cd - : the previous dir is already in the set
        targets = [self.homes[0]] if not args else [p for a in brace_expand(args[0].t) or [] for p in self.absolutize(a)]
        if not targets:
            self.cwd_unknown = True
            return
        for t in targets:
            t = posixpath.normpath(t)
            if t not in self.cwds and len(self.cwds) < 64:
                self.cwds.append(t)
        self.dirty()

    def hot_cwds(self):
        return [h for c in self.cwds for h in self.classify_path(c)]

    # ---------------------------------------------------------------- rules
    def run(self, segs):
        """Segments in the order they run. A quoted script is lexed and its segments run BEFORE the segment that carries it (its
        `cd` and assignments count for what follows); a worklist, not recursion, so no nesting depth can exhaust the stack."""
        work = deque(("seg", words, 0) for words in segs)
        while work:
            kind, words, depth = work.popleft()
            if kind == "judge":
                self.judge(words)
                continue
            for w in words:
                if _ASSIGN.match(w.t):
                    self.assign(w)
            if self.base(words[0]) in ("for", "select") and len(words) >= 3 and words[2].t == "in":
                self.for_var(words)
            self.maybe_cd(words)
            todo = []
            for w in self.scripts(words):
                if depth >= MAX_SCRIPT_DEPTH:
                    self.block("quoted scripts nested more than %d deep: the guard does not read that far, so it refuses" % MAX_SCRIPT_DEPTH)
                todo.extend(("seg", ws, depth + 1) for ws in Lexer(w.p).lex())
            todo.append(("judge", words, depth))
            work.extendleft(reversed(todo))

    def scripts(self, words):
        bases = [self.base(w) for w in words]
        evals, shell, env = any(b in EVALS for b in bases), any(b in SHELLS for b in bases), "env" in bases
        for i, w in enumerate(words):
            if _MULTI.search(w.p):
                prev = unlit(words[i - 1].t) if i else ""
                if evals or (shell and re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", prev)) or (env and prev in ("-S", "--split-string")):
                    yield w

    def block(self, why):
        raise Block(why)

    def judge(self, words):
        if not words:
            return
        rec, lister, depth = ([], False, None) if self.base(words[0]) in DATA_CMDS else self.tools(words)
        shallow = bool(rec) and all(r in FIND for r in rec) and depth is not None and depth <= 2
        name = rec[0] if rec else "ls"
        hits = [(w, h) for w in words if self.base(w) not in PROGRAMS or "/" in w.t for h in self.hits_of(w)]
        fed = lister and (any(h.kind == "home-dyn" for _, h in hits) or any(
            _BARE_DYN.fullmatch(w.t) or "{}" in unlit(w.t) or self.base(w) in ("xargs", "parallel") for w in words))
        if (rec and not shallow or fed) and self.tool is None:       # a plain `ls` counts as a scanner once its operand is FED to it
            self.tool = name
        if self.listing is None:
            kinds = LISTING if any(self.base(w) in PRODUCERS for w in words) else GLOB_LISTING
            self.listing = next(((unlit(w.t), h) for w, h in hits if h.kind in kinds), None)
        if rec:                                                            # A
            for w, h in hits:
                if not (shallow and h.kind == "ancestor"):
                    self.block("%s %s -- %s" % (name, unlit(w.t), h.desc))
        if lister:                                                         # A'
            for w, h in hits:
                if (h.kind == "protected" and h.root) or h.kind in ("volumes", "home-glob"):
                    self.block("ls %s -- lists a macOS-protected location: %s" % (unlit(w.t), h.desc))
        if lister or any(r in IMPLICIT_CWD for r in rec):
            self.judge_cwd(words, rec, shallow, name)

    def judge_cwd(self, words, rec, shallow, name):                       # B
        """A scanner (or, at a protected cwd, a plain ls) while ANY cwd it may run in is hot. Its operands are NOT consulted for
        THAT: an absolute path in the command can be an option's VALUE (`rg --ignore-file /tmp/x foo` still walks the cwd), and
        reading options is exactly what this guard does not do. Measured on 9,334 real agent commands: none had a hot PAYLOAD
        cwd, so the only way to get here is a `cd` to $HOME (the incident) or a `..` climb -- and the message says what to do.
        The cwd-unknown NOTE is different: it exists to count "don't know" as a third state, not to second-guess a block, so it
        fires only when the scan's OWN operand does not already say where it reads -- `du -sk ~/gt` with no cwd in the payload
        is not "scanning while the cwd is unknown", it is scanning an explicit path that never looks at the cwd at all."""
        hot = [h for h in self.hot_cwds() if not (shallow and h.kind == "ancestor")]
        if not rec:
            hot = [h for h in hot if h.kind in ("protected", "volumes")]
        if hot:
            self.block("%s runs while the cwd can be %s (its operands are not consulted: run it from a directory that is not)"
                       % (name, CWD_LABEL.get(hot[0].kind, hot[0].kind)))
        if rec and (not self.cwds or self.cwd_unknown):
            pwd = TOK0 + "PWD" + TOK1
            operands = [w for w in words[1:] if not w.t.startswith("-")]
            explicit = operands and all(self.subst(w.t).startswith(("/", "~", pwd)) for w in operands)
            if not explicit:
                self.notes.append("%s scans while the cwd is unknown" % name)

    def finish(self):                                                      # C
        if self.listing and self.tool:
            word, h = self.listing
            self.block("a listing of $HOME or of an ancestor of it (%s -- %s) and a scanner (%s) in the same command: "
                       "the scanner walks what the listing names" % (word, h.desc, self.tool))


def analyze(command, cwd, homes):
    """Raises Block on a scan of $HOME / a protected folder. Returns the notes (places where the cwd was unknown and a
    relative scan was allowed anyway: the caller logs them -- 'don't know' is not 'not hot')."""
    st = Analyzer(homes, cwd)
    st.run(Lexer(command).lex())
    st.finish()
    return st.notes


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
  * one file the operator pointed you at in Downloads: read it by its exact path (cat / Read / stat) --
    a single named file is not a scan.
Do not route around this with python os.walk / node fs.readdir: that touches the same folders and
raises the same prompt. This check is lexical and errs toward blocking: if the command is harmless,
split it (a listing of $HOME and a scanner in one command, a relative scan from a hot cwd -> use an
absolute path) or say so on the bead instead."""


def _log(result, reason, command, cwd):
    """One tab-separated line per event. BLOCKED = a block; GAVE-UP = deliberate fail-open (input that is not UTF-8, no
    usable home); UNKNOWN-CWD = allowed because the cwd was not knowable (a third state, not "not hot"); ENGINE-ERROR = an
    internal error, also a fail-open -- but a guard that fails open on its own bug is a guard that is silently OFF, so this
    line is the only trace of it and the selftest asserts none of its cases produced one."""
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
        # Bytes, decoded here: `except ValueError` around json.loads used to swallow a UnicodeDecodeError too, with no trace.
        raw = sys.stdin.buffer.read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            _log("GAVE-UP", "hook input is not valid UTF-8", None, None)
            return 0
        try:
            payload = json.loads(text)
        except ValueError:
            return 0            # not JSON: expected bad input, not an engine bug (the wrapper counts it as UNGUARDED)
        if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
            return 0
        command = (payload.get("tool_input") or {}).get("command")
        if not isinstance(command, str) or not command.strip():
            return 0
        cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
        home = os.environ.get("HOME_SCAN_GUARD_HOME") or os.environ.get("HOME") or ""
        home = home.rstrip("/")
        if not home.startswith("/") or home.count("/") < 2:
            _log("GAVE-UP", "no usable home (%r): cannot classify anything, so not guessing" % home, command, cwd)
            return 0
        homes = [home]
        alt = "/Users/" + posixpath.basename(home)
        if alt != home:
            homes.append(alt)
        notes = analyze(command, cwd, homes)
        if notes:
            _log("UNKNOWN-CWD", "; ".join(notes[:4]), command, cwd)
        return 0
    except Block as blocked:
        reason = str(blocked)
        _log("BLOCKED", reason, command, cwd)
        sys.stderr.write(MESSAGE.format(reason=reason) + "\n")
        return 2
    except BaseException as exc:    # noqa: B036 -- fail open, whatever went wrong ...
        import traceback
        tb = traceback.extract_tb(exc.__traceback__)
        where = "%s:%s" % (tb[-1].name, tb[-1].lineno) if tb else "?"
        _log("ENGINE-ERROR", "%s: %s at %s" % (type(exc).__name__, exc, where), command, cwd)   # ... but never silently
        return 0


if __name__ == "__main__":
    sys.exit(main())
