#!/usr/bin/env python3
"""doc-rules-lint — the two doc rules Athos set on 11/10 (epic ga-vhzdh5, story .1).

  (a) CLAUDE.md / CLAUDE.local.md / AGENTS.md: effective line count <= 200,
      summing `@imports` (recursive, cycle-safe).
  (b) any .md with more than 300 chars: a `## Contents` section BEFORE the
      first other `##`, and every `##` title of the doc appears in that
      section's text (free format: bullets, `·` lines, `[x](#anchor)` links).

Usage:
  doc-rules-lint.py --check [--root DIR] [--diff BASE..HEAD | BASE...HEAD] [FILE ...]
  doc-rules-lint.py --fix-contents [--root DIR] FILE ...

Relative FILE paths (and scope exclusions) are taken relative to --root
(default: cwd). `--diff` lints only the .md files ADDED/COPIED/MODIFIED/RENAMED
in that git range (deleted files are never linted) — files the diff does not
touch are never evaluated, so a legacy doc without Contents does not fail an
unrelated change (the backfill is slice ga-vhzdh5.3).

Exit codes: 0 pass | 1 violations | 2 could NOT evaluate (unreadable file, git
failure, missing explicit file, bad args, internal error). The gate treats 2 as
a failure too: unknown is not pass.

Kill switch / negative control: DOC_RULES_LINT=off (or the flag file
$GC_CITY_PATH/.gc/doc-rules-lint.off) turns --check into a loud no-op that
exits 0. --fix-contents is never affected (it only ever edits what you ask).

Decisions (recorded in bead ga-vhzdh5.1):
  * Threshold: len(text.strip()) > 300 CHARACTERS (not bytes), frontmatter
    included. Exactly 300 is exempt.
  * Lines for rule (a): raw lines incl. blanks; > 200 violates, == 200 passes.
    An import-only line (`@path`) is REPLACED by the imported file's lines
    (the host line counts 0); a line with other text counts 1 plus the imports.
    An import counts only if it resolves to an existing file (so emails,
    @mentions and dangling refs are not imports); each expansion is counted
    (no dedupe); a file already on the import stack contributes 0 (cycle).
  * Imports inside code fences / inline code spans are not imports.
  * Only ATX headings (`## x`, up to 3 leading spaces) are titles; `##x`,
    4-space-indented lines, fenced code, HTML comments and YAML frontmatter
    lines are not.
  * Preamble before Contents may hold frontmatter, `#` headings and at most
    ONE other block (the "1 intro paragraph" of the story).
  * A doc with zero `##` and > 300 chars still needs a Contents (the rule says
    "every doc"); the fixer writes a placeholder bullet. Flip
    REQUIRE_CONTENTS_WITHOUT_H2 to exempt such docs instead.
  * Scope: only what is OURS. Excluded: path components third_party, vendor,
    node_modules, .gc-worktrees, .worktrees, .wt-*, .git, .gc, logs; the
    top-level beads/ (upstream mirror); and files that exist in the upstream
    ref (default upstream/main — touching them conflicts with the upstream
    sync). The upstream ref is only consulted for a file that would otherwise
    violate. A repo without that ref has no upstream: its files are linted.
    A ref that exists but cannot be listed is exit 2, never a silent pass.
    Non-.md files are never linted (so logs / *.baseline.txt are out by
    construction).

Python 3.9 compatible on purpose: the gate resolves whichever `python3` is on
PATH (stock macOS ships 3.9).
"""
from __future__ import annotations

import argparse
import errno
import os
import re
import stat
import subprocess
import sys
from typing import Dict, List, Optional, Set, Tuple

PROG = "doc-rules-lint"
MAX_CLAUDE_LINES = 200
CONTENTS_THRESHOLD = 300
MAX_IMPORT_DEPTH = 20
REQUIRE_CONTENTS_WITHOUT_H2 = True
NAMED_FILES = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md")
EXCLUDED_DIRS = {
    "third_party", "vendor", "node_modules",
    ".gc-worktrees", ".worktrees", ".git", ".gc", "logs",
}
EXCLUDED_DIR_PREFIXES = (".wt-",)
EXCLUDED_TOP_LEVEL = {"beads"}
DEFAULT_UPSTREAM_REF = "upstream/main"
MAX_LINE_COLS = 100
NO_H2_PLACEHOLDER = "(sem seções ##)"

R_MAX_LINES = "claude-md-max-lines"
R_MISSING = "contents-missing"
R_LATE = "contents-late"
R_INCOMPLETE = "contents-incomplete"


class LintError(Exception):
    """The file/range could not be evaluated -> exit 2 (never a silent pass)."""


# ----------------------------------------------------------------- reading
def read_text(path: str) -> str:
    # vazio → "" (arquivo vazio: <=300 chars, nada a checar); falhou/ilegível → LintError (exit 2), nunca "" (desconhecido ≠ passa)
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise LintError("%s: cannot read (%s)" % (path, exc.strerror or exc))
    # surrogateescape: invalid UTF-8 bytes survive a read -> write round trip
    return data.decode("utf-8", errors="surrogateescape")


def split_lines(text: str) -> Tuple[List[str], bool]:
    parts = text.split("\n")
    trailing_nl = parts[-1] == ""
    if trailing_nl:
        parts.pop()
    return [p[:-1] if p.endswith("\r") else p for p in parts], trailing_nl


# ----------------------------------------------------------------- parsing
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$")
CLOSER_RE = re.compile(r"[ \t]+#+[ \t]*$")


class Doc:
    """Per-line classification of a markdown text (outside code/comments/frontmatter)."""

    def __init__(self, lines: List[str]):
        self.lines = lines
        self.kinds: List[str] = []              # fm | blank | code | comment | heading | text
        self.heads: Dict[int, Tuple[int, str]] = {}   # line idx -> (level, raw title)
        self.fm_end = 0
        self._scan()

    def _scan(self) -> None:
        lines = self.lines
        n = len(lines)
        i = 0
        first = lines[0].lstrip("﻿") if n else ""
        if n and first.rstrip() == "---":
            for j in range(1, n):
                if lines[j].rstrip() in ("---", "..."):
                    self.fm_end = j + 1
                    break
        self.kinds = ["fm"] * self.fm_end
        fence: Optional[Tuple[str, int]] = None
        in_comment = False
        for i in range(self.fm_end, n):
            line = lines[i]
            if fence is not None:
                self.kinds.append("code")
                m = FENCE_RE.match(line)
                if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= fence[1] and not m.group(2).strip():
                    fence = None
                continue
            if in_comment:
                self.kinds.append("comment")
                if "-->" in line:
                    in_comment = False
                continue
            m = FENCE_RE.match(line)
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = (m.group(1)[0], len(m.group(1)))
                self.kinds.append("code")
                continue
            if line.lstrip().startswith("<!--"):
                self.kinds.append("comment")
                if "-->" not in line.lstrip()[4:]:
                    in_comment = True
                continue
            if not line.strip():
                self.kinds.append("blank")
                continue
            h = HEADING_RE.match(line)
            if h:
                title = CLOSER_RE.sub("", h.group(2) or "").strip()
                if title and set(title) == {"#"}:
                    title = ""
                self.heads[i] = (len(h.group(1)), title)
                self.kinds.append("heading")
                continue
            self.kinds.append("text")

    def h2(self) -> List[Tuple[int, str]]:
        return [(i, t) for i, (lv, t) in sorted(self.heads.items()) if lv == 2]

    def section_end(self, idx: int) -> int:
        """First line after the section opened at idx (next level<=2 heading or EOF)."""
        for j in range(idx + 1, len(self.lines)):
            h = self.heads.get(j)
            if h and h[0] <= 2:
                return j
        return len(self.lines)


def norm(s: str) -> str:
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"[`*_~]", "", s)
    return re.sub(r"\s+", " ", s).strip().casefold()


def title_in(title_n: str, text_n: str) -> bool:
    if not title_n:
        return True
    pre = r"(?<!\w)" if re.match(r"\w", title_n[0]) else ""
    post = r"(?!\w)" if re.match(r"\w", title_n[-1]) else ""
    return re.search(pre + re.escape(title_n) + post, text_n) is not None


def evaluate_contents(doc: Doc) -> Optional[Tuple[str, int, str]]:
    """Rule (b) on the text already known to be > threshold. None = compliant,
    else (rule_id, 1-based line, message)."""
    h2 = doc.h2()
    c_idx = next((i for i, t in h2 if norm(t) == "contents"), None)
    others = [(i, t) for i, t in h2 if i != c_idx and norm(t) != "contents"]
    if c_idx is None:
        if not others and not REQUIRE_CONTENTS_WITHOUT_H2:
            return None
        where = others[0][0] + 1 if others else 1
        return (R_MISSING, where, 'doc has > %d chars but no "## Contents" section before the first other "##"' % CONTENTS_THRESHOLD)
    early = [(i, t) for i, t in others if i < c_idx]
    if early:
        return (R_LATE, c_idx + 1, '"## Contents" must come before the first other "##" (found after "## %s" at line %d)' % (early[0][1], early[0][0] + 1))
    blocks = 0
    in_block = False
    for i in range(doc.fm_end, c_idx):
        k = doc.kinds[i]
        h = doc.heads.get(i)
        eligible = k in ("text", "code") or (k == "heading" and h is not None and h[0] > 2)
        if eligible and not in_block:
            blocks += 1
        in_block = eligible
    if blocks > 1:
        return (R_LATE, c_idx + 1, '"## Contents" must follow the title (at most 1 intro paragraph before it); found %d blocks before it' % blocks)
    section = norm("\n".join(doc.lines[c_idx + 1:doc.section_end(c_idx)]))
    missing = [t for _, t in others if not title_in(norm(t), section)]
    if missing:
        shown = ", ".join('"%s"' % t for t in missing[:8]) + (" …" if len(missing) > 8 else "")
        return (R_INCOMPLETE, c_idx + 1, "Contents does not list %d title(s): %s" % (len(missing), shown))
    return None


# ----------------------------------------------------------------- rule (a)
IMPORT_RE = re.compile(r"(?:^|(?<=[\s(\[{\"']))@(\S+)")
SPAN_RE = re.compile(r"(`+)(.+?)\1")


def import_tokens(line: str) -> Tuple[List[str], bool]:
    """(@import candidates on this line, is the line import-only)."""
    bare = SPAN_RE.sub(lambda m: " " * len(m.group(0)), line)
    tokens = []
    for m in IMPORT_RE.finditer(bare):
        tok = m.group(1).rstrip(".,;:!?)]}\"'")
        if tok:
            tokens.append(tok)
    only = len(tokens) == 1 and bare.strip().rstrip(".,;:!?)]}\"'") == "@" + tokens[0]
    return tokens, only


def resolve_import(tok: str, host_dir: str) -> Optional[str]:
    # vazio → None (o token não é um arquivo: e-mail, @menção, import quebrado — não é import); falhou (stat ≠ "não existe") → LintError (exit 2), nunca None
    path = os.path.expanduser(tok)
    if not os.path.isabs(path):
        path = os.path.join(host_dir, path)
    try:
        st = os.stat(path)
    except (FileNotFoundError, NotADirectoryError, ValueError):
        return None
    except OSError as exc:
        if exc.errno == errno.ENAMETOOLONG:
            return None
        raise LintError("%s: cannot stat @import target (%s)" % (path, exc.strerror or exc))
    return path if stat.S_ISREG(st.st_mode) else None


def effective_lines(path: str, stack: List[str], imported: List[str]) -> Tuple[int, int]:
    """(own lines, imported lines) of `path`, expanding @imports recursively."""
    if len(stack) > MAX_IMPORT_DEPTH:
        raise LintError("%s: @import chain deeper than %d" % (path, MAX_IMPORT_DEPTH))
    real = os.path.realpath(path)
    text = read_text(path)
    doc = Doc(split_lines(text)[0])
    stack = stack + [real]
    own = 0
    inc = 0
    for i, line in enumerate(doc.lines):
        if doc.kinds[i] not in ("text", "heading"):
            own += 1
            continue
        tokens, only = import_tokens(line)
        # vazio → import que não resolve a arquivo não é import (a linha conta 1); falhou/ilegível → LintError em effective_lines/read_text
        resolved = [(t, resolve_import(t, os.path.dirname(real))) for t in tokens]
        resolved = [(t, tgt) for t, tgt in resolved if tgt]
        if not (only and len(resolved) == 1):
            own += 1
        for _tok, target in resolved:
            if os.path.realpath(target) in stack:
                continue
            imported.append(os.path.basename(target))
            o, c = effective_lines(target, stack, imported)
            inc += o + c
    return own, inc


def check_max_lines(path: str) -> Optional[Tuple[str, int, str]]:
    # vazio → 0 linhas, passa; falhou/ilegível → LintError (exit 2) via read_text/effective_lines, nunca passa
    imported: List[str] = []
    own, inc = effective_lines(path, [], imported)
    total = own + inc
    if total <= MAX_CLAUDE_LINES:
        return None
    if inc:
        names = ", ".join(sorted(set(imported)))
        return (R_MAX_LINES, 1, "effective %d lines > %d (own %d + imported %d from %s)" % (total, MAX_CLAUDE_LINES, own, inc, names))
    return (R_MAX_LINES, MAX_CLAUDE_LINES + 1, "%d lines > %d" % (total, MAX_CLAUDE_LINES))


# ----------------------------------------------------------------- scope
def norm_abs(path: str) -> str:
    """abspath with the DIRECTORY realpath'd (macOS /tmp vs /private/tmp) but the leaf kept."""
    ab = os.path.abspath(path)
    return os.path.join(os.path.realpath(os.path.dirname(ab)), os.path.basename(ab))


def rel_to(root: str, path: str) -> str:
    rel = os.path.relpath(norm_abs(path), os.path.realpath(root))
    return rel if not rel.startswith("..") else path


def excluded_by_path(rel: str) -> bool:
    parts = rel.replace("\\", "/").split("/")
    dirs = parts[:-1]
    if len(parts) > 1 and parts[0] in EXCLUDED_TOP_LEVEL:
        return True
    return any(d in EXCLUDED_DIRS or d.startswith(EXCLUDED_DIR_PREFIXES) for d in dirs)


def run_git(args: List[str], cwd: str) -> "subprocess.CompletedProcess[bytes]":
    try:
        return subprocess.run(["git"] + args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LintError("git %s: %s" % (" ".join(args[:2]), exc))


_TOP_CACHE: Dict[str, Optional[str]] = {}


def git_toplevel(directory: str) -> Optional[str]:
    # vazio/falhou → None (fora de repositório git: sem upstream, arquivo é linted; --diff trata None como erro)
    if directory not in _TOP_CACHE:
        proc = run_git(["rev-parse", "--show-toplevel"], directory)
        top = os.fsdecode(proc.stdout).strip() if proc.returncode == 0 else ""
        _TOP_CACHE[directory] = os.path.realpath(top) if top else None
    return _TOP_CACHE[directory]


class Upstream:
    """'Does this file exist in the upstream ref?' — lazy, per git toplevel."""

    def __init__(self, ref: str):
        self.ref = ref
        self.cache: Dict[str, Optional[Set[str]]] = {}

    def contains(self, path: str) -> bool:
        if self.ref.lower() == "none":
            return False
        ab = norm_abs(path)
        top = git_toplevel(os.path.dirname(ab))
        if top is None:
            return False
        if top not in self.cache:
            self.cache[top] = self._list(top)
        files = self.cache[top]
        return files is not None and os.path.relpath(ab, top) in files

    def _list(self, top: str) -> Optional[Set[str]]:
        # vazio → None (ref ausente, rc 1: o repo não tem upstream, arquivos são linted); falhou (rc ≠ 0/1, ou ls-tree) → LintError (exit 2), nunca "não está no upstream"
        probe = run_git(["rev-parse", "--verify", "--quiet", self.ref], top)
        if probe.returncode == 1:
            return None
        if probe.returncode != 0:
            raise LintError("git rev-parse %s failed in %s: %s" % (self.ref, top, os.fsdecode(probe.stderr).strip()))
        proc = run_git(["ls-tree", "-r", "--name-only", "-z", self.ref], top)
        if proc.returncode != 0:
            raise LintError("git ls-tree %s failed in %s: %s" % (self.ref, top, os.fsdecode(proc.stderr).strip()))
        return set(os.fsdecode(p) for p in proc.stdout.split(b"\0") if p)


def diff_files(root: str, rng: str) -> List[str]:
    # vazio → [] (diff sem .md alterados: nada a checar); falhou → LintError (exit 2), nunca [] (range ruim ≠ "sem mudanças")
    top = git_toplevel(root)
    if top is None:
        raise LintError("--diff needs a git repository, %s is not one" % root)
    proc = run_git(["diff", "--name-only", "--diff-filter=ACMR", "-z", rng, "--"], top)
    if proc.returncode != 0:
        raise LintError("git diff %s failed: %s" % (rng, os.fsdecode(proc.stderr).strip()))
    return [os.path.join(top, os.fsdecode(p)) for p in proc.stdout.split(b"\0") if p]


# ----------------------------------------------------------------- the checks
Violation = Tuple[str, int, str, str]   # (display path, line, rule, message)


def lint_file(path: str) -> List[Tuple[str, int, str]]:
    found: List[Tuple[str, int, str]] = []
    if os.path.basename(path) in NAMED_FILES:
        v = check_max_lines(path)
        if v:
            found.append((v[0], v[1], v[2]))
    text = read_text(path)
    if len(text.strip()) > CONTENTS_THRESHOLD:
        v = evaluate_contents(Doc(split_lines(text)[0]))
        if v:
            found.append(v)
    return found


def kill_switch() -> Optional[str]:
    # vazio/falhou ao ler env ou flag file → None = lint LIGADO (o lado seguro: só um "off"/flag legível desliga)
    if os.environ.get("DOC_RULES_LINT", "").strip().lower() == "off":
        return "DOC_RULES_LINT=off"
    city = os.environ.get("GC_CITY_PATH") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    flag = os.path.join(city, ".gc", "doc-rules-lint.off")
    return "flag file " + flag if os.path.exists(flag) else None


Item = Tuple[str, str, str]   # (path on disk, display name, path used for scope exclusions)


def collect(args: argparse.Namespace, root: str) -> Tuple[List[Item], int]:
    """(files to evaluate, number of explicit files that do not exist)."""
    items: List[Item] = []
    missing = 0
    if args.diff:
        top = git_toplevel(root) or root
        for p in diff_files(root, args.diff):
            rel = os.path.relpath(p, top)
            items.append((p, rel, rel))
    for f in args.files:
        p = f if os.path.isabs(f) else os.path.join(root, f)
        if not os.path.isfile(p):
            print("%s: ERROR: %s: no such file" % (PROG, f), file=sys.stderr)
            missing += 1
            continue
        rel = rel_to(root, p)
        outside = os.path.isabs(rel)
        items.append((p, rel, os.path.basename(p) if outside else rel))
    seen: Set[str] = set()
    uniq: List[Item] = []
    for it in items:
        key = norm_abs(it[0])
        if key not in seen:
            seen.add(key)
            uniq.append(it)
    return uniq, missing


def cmd_check(args: argparse.Namespace, root: str) -> int:
    off = kill_switch()
    if off:
        print("%s: DISABLED via %s — nothing was checked (negative control / kill switch)" % (PROG, off))
        return 0
    upstream = Upstream(args.upstream_ref)
    violations: List[Violation] = []
    checked = skipped = 0
    items, errors = collect(args, root)
    for path, rel, scope in items:
        if not path.lower().endswith(".md"):
            continue
        if excluded_by_path(scope):
            skipped += 1
            continue
        try:
            found = lint_file(path)
            if found and upstream.contains(path):
                skipped += 1
                continue
        except LintError as exc:
            print("%s: ERROR: %s" % (PROG, exc), file=sys.stderr)
            errors += 1
            continue
        checked += 1
        for rule, line, msg in found:
            violations.append((rel, line, rule, msg))
    for rel, line, rule, msg in violations:
        print("%s:%d: [%s] %s" % (rel, line, rule, msg))
    print("%s: %d file(s) checked, %d violation(s), %d skipped (excluded)" % (PROG, checked, len(violations), skipped))
    if violations:
        files = " ".join(sorted(set(v[0] for v in violations if v[2] != R_MAX_LINES)))
        if files:
            print("hint: python3 %s --fix-contents %s   (generates/repairs the Contents section)" % (os.path.abspath(__file__), files))
    if errors:
        print("%s: ERROR: %d file(s) could not be evaluated — treated as FAIL (unknown is not pass)" % (PROG, errors), file=sys.stderr)
        return 2
    return 1 if violations else 0


# ----------------------------------------------------------------- --fix-contents
def contents_lines(titles: List[str]) -> List[str]:
    uniq: List[str] = []
    for t in titles:
        if t and t not in uniq:
            uniq.append(t)
    if not uniq:
        return ["• " + NO_H2_PLACEHOLDER]
    out: List[str] = []
    cur = ""
    for t in uniq:
        if not cur:
            cur = "• " + t
        elif len(cur) + 3 + len(t) <= MAX_LINE_COLS:
            cur += " · " + t
        else:
            out.append(cur)
            cur = "• " + t
    out.append(cur)
    return out


def fix_text(text: str) -> str:
    """Return text with a compliant Contents (the input object itself when already fine)."""
    if len(text.strip()) <= CONTENTS_THRESHOLD:
        return text
    lines, trailing_nl = split_lines(text)
    doc = Doc(lines)
    if evaluate_contents(doc) is None:
        return text
    crlf = text.count("\r\n")
    eol = "\r\n" if crlf and crlf * 2 > text.count("\n") else "\n"

    c_idx = next((i for i, t in doc.h2() if norm(t) == "contents"), None)
    if c_idx is not None:
        end = doc.section_end(c_idx)
        at_eof = end == len(lines)
        del lines[c_idx:end]
        while at_eof and lines and lines[-1] == "":
            lines.pop()
        if 0 < c_idx < len(lines) and lines[c_idx - 1] == "" and lines[c_idx] == "":
            del lines[c_idx]
        doc = Doc(lines)
    titles = [t for _, t in doc.h2()]

    ins = doc.fm_end
    j = ins
    while j < len(lines) and not lines[j].strip():
        j += 1
    h = doc.heads.get(j)
    if j < len(lines) and h is not None and h[0] == 1:
        ins = j + 1
    block = ["## Contents", ""] + contents_lines(titles) + [""]
    if ins > 0 and lines[ins - 1] != "":
        block.insert(0, "")
    if ins < len(lines) and lines[ins] == "":
        block.pop()
    lines[ins:ins] = block

    fixed = eol.join(lines) + (eol if trailing_nl else "")
    again = evaluate_contents(Doc(split_lines(fixed)[0]))
    if again is not None:
        raise LintError("fixer could not produce a compliant Contents (%s: %s)" % (again[0], again[2]))
    return fixed


def write_text(path: str, text: str) -> None:
    target = os.path.realpath(path)
    tmp = target + ".doc-rules-lint.tmp"
    try:
        with open(tmp, "wb") as fh:
            fh.write(text.encode("utf-8", errors="surrogateescape"))
        try:
            # vazio/falhou → mantém o modo padrão do tmp (só permissão; o conteúdo já foi escrito inteiro)
            os.chmod(tmp, os.stat(target).st_mode & 0o7777)
        except OSError:
            pass
        os.replace(tmp, target)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise LintError("%s: cannot write (%s)" % (path, exc.strerror or exc))


def cmd_fix(args: argparse.Namespace, root: str) -> int:
    upstream = Upstream(args.upstream_ref)
    items, errors = collect(args, root)
    for path, rel, scope in items:
        if not path.lower().endswith(".md"):
            print("skipped: %s (not .md)" % rel)
            continue
        if excluded_by_path(scope):
            print("skipped: %s (excluded)" % rel)
            continue
        try:
            text = read_text(path)
            new = fix_text(text)
            if new == text:
                print("unchanged: %s" % rel)
            elif upstream.contains(path):
                print("skipped: %s (exists upstream)" % rel)
            else:
                write_text(path, new)
                print("fixed: %s" % rel)
        except LintError as exc:
            print("%s: ERROR: %s" % (PROG, exc), file=sys.stderr)
            errors += 1
    return 2 if errors else 0


# ----------------------------------------------------------------- main
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog=PROG, description="CLAUDE.md <=200 lines (incl. @imports) and Contents in every .md > 300 chars.")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="lint the given files / the --diff range")
    mode.add_argument("--fix-contents", action="store_true", help="generate/repair the Contents section of the given files")
    ap.add_argument("--root", default=".", help="base dir for relative paths and scope exclusions (default: cwd)")
    ap.add_argument("--diff", metavar="RANGE", help="git range (BASE..HEAD or BASE...HEAD): lint only the .md files it changed")
    ap.add_argument("--upstream-ref", default=os.environ.get("DOC_RULES_UPSTREAM_REF", DEFAULT_UPSTREAM_REF),
                    help="ref whose files are not ours (default %s; 'none' disables)" % DEFAULT_UPSTREAM_REF)
    ap.add_argument("files", nargs="*", metavar="FILE")
    return ap


def main(argv: Optional[List[str]] = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")  # type: ignore[attr-defined]
        except (AttributeError, ValueError):
            pass
    ap = build_parser()
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        ap.error("--root %s is not a directory" % args.root)
    if args.fix_contents and args.diff:
        ap.error("--diff is only for --check")
    if not args.files and not args.diff:
        ap.error("give at least one FILE (or --diff RANGE with --check)")
    try:
        return cmd_check(args, root) if args.check else cmd_fix(args, root)
    except LintError as exc:
        print("%s: ERROR: %s" % (PROG, exc), file=sys.stderr)
        return 2
    except Exception as exc:  # unknown is not pass
        print("%s: ERROR: internal error: %s: %s" % (PROG, type(exc).__name__, exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
