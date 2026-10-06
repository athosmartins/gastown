#!/usr/bin/env python3
"""work_order — Python entry point to the ONE bead-ordering rule (ga-9t9acg.1).

The rule (priority > type > age, on every stage of the board) is implemented once, in
packs/town-deltas/assets/scripts/work-order.sh. This module does NOT re-implement it: it runs
that library in a subprocess, so the shell consumers and the Python consumers cannot drift apart.
Read the header of work-order.sh for the key, the three age rules and the three-state contract.

Run it isolated: `python3 -I scripts/work_order.py sort [--age created|field|reclaim] < beads.json`

  sort   stdin: ONE JSON array of bead objects (`bd list/ready --json`). stdout: the ordered array,
         exit 0. The library's `work-order WARN:` lines go to stderr unchanged.
         Cannot tell (not an array, jq/bash missing, library failed) -> stdout EMPTY, exit 2.
         Callers MUST treat empty as "I do not know" and keep their previous order with a visible
         WARN — it never means "no bead".

  lint   `lint [--root DIR] [--registry FILE]` — the registry lint. Every line in the scope that
         orders or windows beads by its own idiom must be matched by a row of
         work-order.registry.tsv, and every row must still match a line. exit 0 clean, 1 findings
         (one `LINT FAIL:` line each), 2 cannot tell (registry unreadable, or no file in scope under
         the root — a lint that looked at nothing never says "clean"). See the registry header.

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
    proc = _run_lib(raw, age)
    err = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0 or not proc.stdout.strip():
        first = err.strip().splitlines()[0] if err.strip() else "exit %d, no output" % proc.returncode
        raise WorkOrderUnknown(first)
    try:
        out = json.loads(proc.stdout)
    except ValueError as exc:
        raise WorkOrderUnknown("library output is not JSON: %s" % exc)
    if not isinstance(out, list):
        raise WorkOrderUnknown("library output is not an array")
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
IDIOMS = (
    ("M1-jq-sort_by", r"sort_by\(.*\b(created_at|updated_at|priority)\b"),
    ("M2-sort-flag", r"--sort[ =]"),
    ("M3-pilot-sort-jq", r"_PILOT_SORT_JQ"),
    ("M4-py-sort", r"(\.sort\(.*key=.*\b(created_at|updated_at|priority)\b"
                   r"|\bsorted\(.*key=.*\b(created_at|updated_at|priority)\b)"),
    ("M5-positive-limit", r"--limit(=|\s+)[1-9]"),
)
SCOPE_GLOBS = (
    "packs/town-deltas/assets/*.sh",
    "packs/town-deltas/assets/scripts/*.sh",
    "agents/*/prompt.template.md",
    "scripts/*.py",
)
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
    files = []
    for pat in SCOPE_GLOBS:
        for path in sorted(glob.glob(os.path.join(root, pat))):
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            if os.path.isfile(path) and not SCOPE_SKIP.search("/" + rel):
                files.append(rel)
    return files


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
    """-> (findings, summary). Findings are strings; an empty list means the registry is clean."""
    errors = []
    rows = _parse_registry(registry, errors)
    local = [r for r in rows if r["kind"] != "ext"]
    scope = _scope_files(root)
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
    summary = "LINT: files=%d idiom_lines=%d rows=%d consumer_rows_left=%d unassigned=%d ext=%d reviewed=%d" % (
        len(scope), hits, len(rows), len(owners), owners.count("UNASSIGNED"),
        sum(1 for r in rows if r["kind"] == "ext"), sum(1 for r in rows if r["kind"] == "reviewed"))
    return errors, summary


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
        findings, summary = lint(root, registry)
    except OSError as exc:
        sys.stderr.write("work-order ERROR: lint: cannot read the registry or the tree (%s); cannot tell\n" % exc)
        return 2
    for item in findings:
        sys.stdout.write("LINT FAIL: %s\n" % item)
    sys.stdout.write(summary + "\n")
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
