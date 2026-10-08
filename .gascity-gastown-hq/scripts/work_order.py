#!/usr/bin/env python3
"""work_order — Python entry point to the ONE bead-ordering rule (ga-9t9acg.1).

The rule (priority > type > age, on every stage of the board) is implemented once, in
packs/town-deltas/assets/scripts/work-order.sh. This module does NOT re-implement it: it runs
that library in a subprocess, so the shell consumers and the Python consumers cannot drift apart.
Read the header of work-order.sh for the key, the three age rules and the three-state contract.

Run it isolated: `python3 -I scripts/work_order.py sort [--age created|field|reclaim] < beads.json`

  sort   stdin: ONE JSON array of bead objects (`bd list/ready --json`). stdout: the ordered array,
         exit 0. The library's `work-order WARN:` lines go to stderr unchanged.
         If WORK_ORDER_LIB points at a library other than the one next to this module, the run is
         ordered by ANOTHER rule than the town's: stderr then starts with one
         `work-order WARN: WORK_ORDER_LIB override active: <path> ...` line (a stale variable in a daemon's
         environment must never be silent). The selftest uses the override for its mutants.
         Cannot tell (not an array, jq/bash missing, library failed) -> stdout EMPTY, exit 2; with an
         override active, that ERROR line carries the same notice (whatever the way it failed).
         Callers MUST treat empty as "I do not know" and keep their previous order with a visible
         WARN — it never means "no bead".

  lint   `lint [--root DIR] [--registry FILE]` — the registry lint. Every line, in a file matched by
         SCOPE_GLOBS, that has a SEEN shape of "order or window beads by an idiom of your own" (the
         IDIOMS below: one line, or a call left open at the end of a line) must be matched by a row of
         work-order.registry.tsv, and every row must still match a line. exit 0 clean, 1 findings
         (one `LINT FAIL:` line each), 2 cannot tell (registry unreadable, or no file in scope under
         the root — a lint that looked at nothing never says "clean").
         The lint is NOT total, and every run says so: after the summary it prints the scope and the
         shapes it cannot see (LINT SCOPE / LINT SEES / LINT NOT SEEN). "clean" means "no unregistered
         line of a seen shape in that scope" — never "no ad-hoc ordering exists". See the registry header.
         A scope glob that matches no file (a directory renamed away) is a part of the scope nobody read:
         the summary counts it (empty_globs=N) and a `LINT NOTE:` line names it. It does not fail the run
         (the real-tree selftest asserts it is 0), but it is never quiet.

As a module: `sort_beads(beads, age="created")` returns `(ordered_list, warnings)`, or
`(None, [reason])` when it cannot tell — the caller then keeps its previous order and logs a WARN.
`[]` returns `([], [])`: test `is None`, never falsiness. Never `--limit=N` before sorting.
"""
import glob
import json
import os
import re
import subprocess
import sys

AGES = ("created", "field", "reclaim")
_TIMEOUT_SEC = 30
_DEFAULT_LIB = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    os.pardir, "packs", "town-deltas", "assets", "scripts", "work-order.sh",
)


class WorkOrderUnknown(Exception):
    """The library could not tell the order. The caller keeps its previous order and warns."""


def lib_path():
    """The library under use; WORK_ORDER_LIB overrides it (the selftest points it at a mutant)."""
    return os.path.normpath(os.environ.get("WORK_ORDER_LIB") or _DEFAULT_LIB)


def _override_notice():
    """None when the library in use is the one shipped next to this module; else the WARN line that says so.

    WORK_ORDER_LIB exists so the selftest can point at a mutant. In a daemon's environment it is a stale
    variable waiting to happen: the queue would be ordered by another rule and nothing would show it.
    Compared by realpath, so a symlink or a ./ spelling of the default is not an override."""
    if not os.environ.get("WORK_ORDER_LIB"):
        return None
    lib = lib_path()
    if os.path.realpath(lib) == os.path.realpath(_DEFAULT_LIB):
        return None
    return ("work-order WARN: WORK_ORDER_LIB override active: %s (not the town's library %s); "
            "the order below is NOT the town's rule unless that file is a copy of it"
            % (lib, os.path.normpath(_DEFAULT_LIB)))


def _run_lib(raw, age):
    if age not in AGES:
        raise WorkOrderUnknown("unknown age rule %r (want one of %s)" % (age, ", ".join(AGES)))
    lib = lib_path()
    if not os.path.isfile(lib):
        raise WorkOrderUnknown("library not found: %s" % lib)
    try:
        proc = subprocess.run(
            ["bash", "-c", '. "$1" && shift && work_order_sort "$@"', "work-order", lib, "--age", age],
            input=raw, capture_output=True, timeout=_TIMEOUT_SEC, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise WorkOrderUnknown("could not run the library: %s" % exc)
    return proc


def sort_beads_raw(raw, age="created"):
    """bytes in (one JSON array) -> (ordered array as parsed JSON, stderr text with the WARN lines)."""
    notice = _override_notice()
    tail = "; " + notice if notice else ""      # every "cannot tell" below carries it: a stale override is the likely cause
    try:
        proc = _run_lib(raw, age)
    except WorkOrderUnknown as exc:
        raise WorkOrderUnknown(str(exc) + tail)
    err = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0 or not proc.stdout.strip():
        first = err.strip().splitlines()[0] if err.strip() else "exit %d, no output" % proc.returncode
        raise WorkOrderUnknown(first + tail)
    try:
        out = json.loads(proc.stdout)
    except ValueError as exc:
        raise WorkOrderUnknown("library output is not JSON: %s%s" % (exc, tail))
    if not isinstance(out, list):
        raise WorkOrderUnknown("library output is not an array" + tail)
    if notice:
        err = notice + "\n" + err
    return out, err


def sort_beads(beads, age="created"):
    """list of bead dicts -> (ordered list, warnings); or (None, [reason]) when the library cannot tell.

    None is "I do not know": the caller keeps its previous order and logs the reason as a visible WARN.
    It never means "no bead", and `[]` is a real answer — test `is None`, never falsiness."""
    try:
        out, err = sort_beads_raw(json.dumps(beads).encode("utf-8"), age)
    except (WorkOrderUnknown, TypeError, ValueError) as exc:
        return None, ["work-order ERROR: sort_beads: cannot tell (%s)" % exc]
    return out, [ln for ln in err.splitlines() if ln.strip()]


# ── registry lint ────────────────────────────────────────────────────────────────────────────
# The master idioms: the ways code in this tree decides "which bead first" or "how many beads to look
# at" by itself. A line matching one must be accounted for in the registry (a `consumer` row until its
# slice migrates it to the library, a `reviewed` row when it orders something that is not a bead queue).
#
# What the lint sees is exactly what these regexes match on ONE line of a file in SCOPE_GLOBS (comment
# lines excluded), and nothing else. That is a deliberate, narrow promise: LINT_NOT_SEEN below lists what
# falls outside it, and every run prints it, so a clean exit can never be read as "nothing is ordered
# ad hoc". Widen an idiom here (and add a fixture per shape to the selftest) rather than claim more.
_FIELD = r"\b(?:created_at|updated_at|priority)\b"
# The value of a window flag: anything but a literal 0 (0 = "the whole population", the safe form) — a digit,
# a shell variable / substitution ($N, "$N", ${N}, $(..)), an f-string brace, or a call (str(n)). A quoted
# "0" is a zero too. A bare word is NOT a value ("--limit N" in a usage string is prose, not a window)...
_VALUE = r"""["']?(?!0(?!\d))(?:[0-9]|[$({]|[A-Za-z_][\w.]*\()"""
# ...except as an element of a Python argv list, where a bare name closed by , ] ) is a variable:
# ["bd", "list", "--limit", n] / "-n", limit)
_LIST_VALUE = r"""["']?(?!0(?!\d))(?:[0-9]|[$({]|[A-Za-z_][\w.]*\(|[A-Za-z_][\w.]*\s*[,\])])"""
# `-n` is too common to count everywhere (tail -n, sed -n, sysctl -n, jq -n, `[ -n "$x" ]`), so it counts
# only (1) as its own quoted list element in a line that is not one of those tools, and (2) on a shell line
# that names a bd query (bd ... list|ready|query|search ... -n N), never as a test operator.
_NOT_OTHER_TOOL = r"""^(?!.*\[\s*["'](?:tail|head|sed|sysctl|sort|jq|cut)["'])"""
_N_FLAG_LIST = _NOT_OTHER_TOOL + r""".*["']-n["']\s*,\s*""" + _LIST_VALUE
_BD_WORD = r"""(?:\bbd\b|\$\{?[A-Za-z_]*BD[A-Za-z_]*\}?)"""
_N_FLAG_BD = _BD_WORD + r""".*\b(?:list|ready|query|search)\b.*(?<![\w\[-])(?<!\[ )(?<!\[\[ )(?<!test )-n(?:=|\s+)""" + _VALUE
IDIOMS = (
    # jq sort_by/min_by/max_by keyed on a bead field; or the call left OPEN at the end of the line
    # (the key is on a later line: a jq program split over lines).
    ("M1-jq-sort_by", r"\b(?:sort_by|min_by|max_by)\((?:.*%s|[^)]*$)" % _FIELD),
    # any --sort flag, in a shell line or as a Python list element ("--sort", "oldest")
    ("M2-sort-flag", r"--sort(?![A-Za-z-])"),
    ("M3-pilot-sort-jq", r"_PILOT_SORT_JQ"),
    # Python .sort / sorted / min / max keyed on a bead field; or the call left open at the end of the line
    ("M4-py-sort", r"(?:\.sort|\bsorted|\bmin|\bmax)\((?:.*\bkey=.*%s|[^)]*$)" % _FIELD),
    # a window taken before the sort (the ga-g7yt trap): --limit N / --limit=N / --limit "$N" / f"--limit={N}",
    # the Python list forms "--limit", "20" and "-n", "200", and `-n N` on a shell bd query
    ("M5-positive-limit", r"(?:--limit(?:=|\s+)%s|[\"']--limit[\"']\s*,\s*%s|%s|%s)"
                          % (_VALUE, _LIST_VALUE, _N_FLAG_LIST, _N_FLAG_BD)),
)
# The scope is a list of globs relative to .gascity-gastown-hq/ — files that carry bead queries as code.
# docs/, test fixtures and the library itself are out; see SCOPE_SKIP.
SCOPE_GLOBS = (
    "packs/town-deltas/assets/*.sh",
    "packs/town-deltas/assets/scripts/*.sh",
    "packs/town-deltas/orders/*.toml",
    "packs/town-deltas/formulas/*.toml",
    "packs/town-deltas/template-fragments/*.md",
    "formulas/*.toml",
    "commands/*.md",
    "agents/*/prompt.template.md",
    "scripts/*.sh",
    "scripts/*.py",
)
# Printed after EVERY lint run (clean or not): what the lint does and does not look at.
LINT_SEES = ("a one-line form of M1..M5 (shell, jq, Python incl. list-form args, `-n N` on a bd query, a variable "
             "or $(...) window), or a sort_by/min_by/max_by/.sort/sorted/min/max call left open at the end of a line")
LINT_NOT_SEEN = ("a sort keyed through a helper or variable (key=_age, sort_by($k)); a text pipeline "
                 "(... | sort -k.. | head -1); a window whose flag or size is assembled from pieces or sits on a "
                 "different line from its flag; a hand-rolled min/loop; any file outside LINT SCOPE "
                 "(docs/, other directories, other repos)")
# selftests carry the idioms as fixtures; the library and this module ARE the one implementation.
SCOPE_SKIP = re.compile(r"(\.selftest\.(sh|py)$|/test_[^/]*\.py$|/work-order\.sh$|/work_order\.py$)")
DEFAULT_REGISTRY = os.path.join("packs", "town-deltas", "assets", "scripts", "work-order.registry.tsv")
_KINDS = ("consumer", "reviewed", "ext")
_OWNER_RE = re.compile(r"^((ga|wa|ps)-[a-z0-9]+(\.[0-9]+)*|UNASSIGNED)$")
_COMMENT_RE = re.compile(r"^\s*#")


def _read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def _scope_files(root):
    """-> (files in scope, the globs that matched no file). An empty glob is a part of the scope the lint is
    NOT looking at (a directory renamed away): it is reported, never read as "that part is clean"."""
    files, empty = [], []
    for pat in SCOPE_GLOBS:
        before = len(files)
        for path in sorted(glob.glob(os.path.join(root, pat))):
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            if os.path.isfile(path) and not SCOPE_SKIP.search("/" + rel):
                files.append(rel)
        if len(files) == before:
            empty.append(pat)
    return files, empty


def _parse_registry(path, errors):
    rows = []
    seen = set()
    for lineno, line in enumerate(_read_lines(path), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        where = "%s:%d" % (os.path.basename(path), lineno)
        if len(cols) != 5:
            errors.append("registry row %s has %d tab-separated columns, want 5 (kind file regex owner note)" % (where, len(cols)))
            continue
        kind, file_, rx_src, owner, note = cols
        if kind not in _KINDS:
            errors.append("registry row %s: kind %r is not one of %s" % (where, kind, "/".join(_KINDS)))
            continue
        if not note.strip():
            errors.append("registry row %s: the note is empty — say which consumer it is, or why it is not a bead queue" % where)
        if kind == "reviewed" and owner != "-":
            errors.append("registry row %s: a reviewed row has owner '-', got %r" % (where, owner))
        if kind != "reviewed" and not _OWNER_RE.match(owner):
            errors.append("registry row %s: owner %r is not a bead id or UNASSIGNED" % (where, owner))
        if kind == "ext":
            if rx_src != "-":
                errors.append("registry row %s: an ext row (outside this repo) has regex '-', got %r" % (where, rx_src))
            rows.append({"kind": kind, "file": file_, "rx": None, "owner": owner, "where": where})
            continue
        try:
            rx = re.compile(rx_src)
        except re.error as exc:
            errors.append("registry row %s: regex does not compile: %s" % (where, exc))
            continue
        if (file_, rx_src) in seen:
            errors.append("registry row %s: duplicate of an earlier row (same file and regex)" % where)
        seen.add((file_, rx_src))
        rows.append({"kind": kind, "file": file_, "rx": rx, "owner": owner, "where": where})
    return rows


def lint(root, registry):
    """-> (findings, summary, notes). Findings are strings; an empty list means no unregistered line of a SEEN
    shape in the scope. Notes are lines about the scope itself (a glob that matched no file); they never
    fail the run, but the summary counts them (empty_globs=N) so they are not quiet."""
    errors = []
    rows = _parse_registry(registry, errors)
    local = [r for r in rows if r["kind"] != "ext"]
    scope, empty_globs = _scope_files(root)
    if not scope:
        # a lint that looked at nothing must not say "clean": a mistyped --root would pass for a clean tree
        raise OSError("no file in the lint scope under %s" % root)
    code = {}
    for rel in set(scope) | set(r["file"] for r in local):
        path = os.path.join(root, rel)
        if os.path.isfile(path):
            code[rel] = [(n, t) for n, t in enumerate(_read_lines(path), 1) if not _COMMENT_RE.match(t)]
    hits = 0
    for rel in scope:
        mine = [r for r in local if r["file"] == rel]
        for n, text in code.get(rel, ()):
            names = [k for k, rx in IDIOMS if re.search(rx, text)]
            if not names:
                continue
            hits += 1
            if not any(r["rx"].search(text) for r in mine):
                errors.append("UNREGISTERED %s:%d [%s] %s — order it with work-order.sh, or add a registry row "
                              "saying why it is not a bead queue" % (rel, n, ",".join(names), text.strip()[:140]))
    for r in local:
        if r["file"] not in code:
            errors.append("STALE row %s: file %s does not exist — delete the row" % (r["where"], r["file"]))
        elif not any(r["rx"].search(t) for _n, t in code[r["file"]]):
            errors.append("STALE row %s: %s no longer has a line matching /%s/ — the slice migrated it, delete the row"
                          % (r["where"], r["file"], r["rx"].pattern))
    owners = [r["owner"] for r in rows if r["kind"] == "consumer"]
    summary = "LINT: files=%d idiom_lines=%d rows=%d consumer_rows_left=%d unassigned=%d ext=%d reviewed=%d empty_globs=%d" % (
        len(scope), hits, len(rows), len(owners), owners.count("UNASSIGNED"),
        sum(1 for r in rows if r["kind"] == "ext"), sum(1 for r in rows if r["kind"] == "reviewed"), len(empty_globs))
    notes = ["no file matches scope glob %s — that part of the scope is empty (a renamed directory?); "
             "fix SCOPE_GLOBS or the tree" % g for g in empty_globs]
    return errors, summary, notes


def _main_lint(rest):
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))
    registry = None
    while rest:
        if rest[0] == "--root" and len(rest) >= 2:
            root, rest = rest[1], rest[2:]
        elif rest[0] == "--registry" and len(rest) >= 2:
            registry, rest = rest[1], rest[2:]
        else:
            sys.stderr.write("usage: work_order.py lint [--root DIR] [--registry FILE]\n")
            return 2
    registry = registry or os.path.join(root, DEFAULT_REGISTRY)
    try:
        findings, summary, notes = lint(root, registry)
    except OSError as exc:
        sys.stderr.write("work-order ERROR: lint: cannot read the registry or the tree (%s); cannot tell\n" % exc)
        return 2
    for item in findings:
        sys.stdout.write("LINT FAIL: %s\n" % item)
    sys.stdout.write(summary + "\n")
    for item in notes:
        sys.stdout.write("LINT NOTE: %s\n" % item)
    # always, clean or not: a clean exit must not be readable as "nothing is ordered ad hoc"
    sys.stdout.write("LINT SCOPE: %s (not: selftests, test_*.py, work-order.sh, work_order.py)\n" % " ".join(SCOPE_GLOBS))
    sys.stdout.write("LINT SEES: %s\n" % LINT_SEES)
    sys.stdout.write("LINT NOT SEEN: %s\n" % LINT_NOT_SEEN)
    return 1 if findings else 0


def main(argv):
    args = list(argv[1:])
    if args and args[0] == "lint":
        return _main_lint(args[1:])
    if not args or args[0] != "sort":
        sys.stderr.write("usage: work_order.py sort [--age created|field|reclaim] < beads.json\n"
                         "       work_order.py lint [--root DIR] [--registry FILE]\n")
        return 2
    age = "created"
    rest = args[1:]
    while rest:
        if rest[0] == "--age" and len(rest) >= 2:
            age, rest = rest[1], rest[2:]
        elif rest[0].startswith("--age="):
            age, rest = rest[0][len("--age="):], rest[1:]
        else:
            sys.stderr.write("work-order ERROR: work_order.py: unknown argument %r; cannot tell\n" % rest[0])
            return 2
    try:
        out, err = sort_beads_raw(sys.stdin.buffer.read(), age)
    except WorkOrderUnknown as exc:
        sys.stderr.write("work-order ERROR: work_order.py: cannot tell (%s)\n" % exc)
        return 2
    if err:
        sys.stderr.write(err)
    sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
