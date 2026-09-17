#!/usr/bin/env python3
"""compute_symbol_reachability.py — ranks a closure-affected daemon by whether it
actually REACHES a changed symbol, not just whether it imports the changed file
(wa-th4b1).

THE GAP THIS CLOSES: daemon-refresh.sh's ga-9lsuq0 block already trusts a rig's
deploy_deps.json "closure" (a rig's own recursive import-file-set per entrypoint,
e.g. whatsapp_automation/scripts/gen_daemon_deps.py) to decide whether an
entrypoint is AFFECTED by a deploy. That closure answers "could this entrypoint
possibly be touched?" — it is deliberately over-inclusive (importing a module is
enough to join its closure, regardless of which name was imported or whether that
name changed). wa-th4b1 measured three independent live deploys where the
resulting AFFECTED/GUARDED list was 12x-50x bigger than the set of daemons that
actually execute the changed code, because "imports the file" and "calls the
function that changed" are different questions.

The three measured cases are this module's test oracle (see the .selftest.sh
beside this file):
  1. lib/ficha360_data.py gained get_consultas/_read_one/_fmt_consulta_data,
     called INTERNALLY by build_perfil (unchanged). daemons/ficha360_app.py is
     the only entrypoint that imports build_perfil -> reachable via the
     intra-file call graph, even though it never names the new functions.
     demand_dashboard.py imports a DIFFERENT, unchanged symbol from the same
     file (normalize_doc) -> not reachable.
  2/3. daemons/inbound_sweep.py changed 5 private helpers
     (_propagate_twins, _load_pending_media_targets, _contact_card_key,
     _recovered_contact_bodies, _apply_recovered_contact_bodies).
     lib/device_human_sender.py does
     `from daemons.inbound_sweep import _capture_from_dump, _resolve_own_identity`
     (both unchanged, and neither calls any of the 5 changed helpers) -> NOT
     reachable, even though the file-level closure is correct that
     device_human_sender.py (and therefore referral_outreach_daemon, which
     imports it) transitively imports inbound_sweep.py.

DESIGN, matching this file's own bounded-hop precedent (see daemon-refresh.sh's
daemon_imports_stem_via_routes: "one more hop... not a full transitive
closure"): this is single-hop PLUS one intra-file call-graph hop, not a full
whole-program call-graph solver.
  - "Changed symbols" in a changed .py file = its top-level (module-level, not
    nested in a class) function/async-function defs whose ast.dump() differs
    between PRE and POST, or that are new at POST. A changed CLASS body, a
    changed module-level constant, or a changed method is deliberately NOT
    tracked as a "symbol" here (see toplevel_functions()) — the three measured
    cases are all plain top-level functions, and widening scope without a
    measured case to justify it risks a false sense of precision.
  - For an entrypoint E already flagged AFFECTED via closure intersection with
    changed file F, this asks: does some file M in E's OWN closure import
    something from F, where that imported name either IS a changed symbol, or
    (Case 1's shape) is an unchanged top-level function in F whose own
    intra-file call graph reaches a changed symbol?
  - FAILS OPEN, always, the same direction as every other check in
    daemon-refresh.sh: a parse failure, an unresolvable import, a changed file
    with no determinable symbol diff, or any other indeterminate state reports
    the entrypoint as reachable rather than silently demoting it. A false
    positive here just leaves a daemon in the ranked-equal, undifferentiated
    list it is in today; a false negative would hide a daemon that genuinely
    needs a restart — the exact class of error this codebase's own docstrings
    (detect_stale_daemons.py, daemon-refresh.sh) repeatedly call out as the
    worse one.

Usage:
  compute_symbol_reachability.py --repo <runtime_dir> --deps <deploy_deps.json>
      --pre <sha> --post <sha> --entrypoints <relpath> [<relpath> ...]

Prints, one per line, the subset of --entrypoints confirmed to reach a changed
symbol. Always exits 0 (best-effort helper); on any file-level failure the
affected input is echoed back unfiltered (fail open) rather than raising.
Entrypoints not printed are not proven UNreachable in some absolute sense —
they are simply the ones this bounded check could positively confirm are
closure-only for every changed file in the deploy. Caller (daemon-refresh.sh)
must keep treating the full AFFECTED/GUARDED set as the safety net; this output
is a ranking signal layered on top, never a replacement for it.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys

MODULE_BASES = ("", "lib", "daemons", "utils", "scripts")


def _run_git(repo: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def changed_python_files(repo: str, pre: str, post: str) -> list[str] | None:
    proc = _run_git(repo, "diff", "--name-only", pre, post)
    if proc.returncode != 0:
        return None
    return [ln for ln in proc.stdout.splitlines() if ln.endswith(".py")]


def read_at(repo: str, sha: str, relpath: str) -> str | None:
    proc = _run_git(repo, "show", f"{sha}:{relpath}")
    return proc.stdout if proc.returncode == 0 else None


def resolve_module(repo: str, dotted: str) -> str | None:
    """Mirrors whatsapp_automation/scripts/gen_daemon_deps.py::_module_to_paths
    (same base dirs, same file-then-package precedence) so this script's own
    import resolution agrees with the closure it is refining. Keep the two in
    sync if that resolution order ever changes — same documented duplication
    daemon-refresh.sh's own restart_policy.yaml parser already accepts."""
    rel = dotted.replace(".", os.sep)
    for base in MODULE_BASES:
        for suffix in (rel + ".py", os.path.join(rel, "__init__.py")):
            cand = os.path.join(repo, base, suffix) if base else os.path.join(repo, suffix)
            if os.path.isfile(cand):
                return os.path.relpath(os.path.realpath(cand), os.path.realpath(repo))
    return None


def toplevel_functions(tree: ast.Module) -> dict[str, ast.AST]:
    return {n.name: n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def changed_toplevel_names(repo: str, pre: str, post: str, relpath: str) -> tuple[frozenset[str], bool]:
    """(changed_names, ok). ok=False means "could not determine" (parse
    failure) — caller must fail open, never treat False the same as an empty
    confirmed set."""
    new_src = read_at(repo, post, relpath)
    if new_src is None:
        return frozenset(), True  # deleted at POST: nothing left to reach
    try:
        new_tree = ast.parse(new_src)
    except SyntaxError:
        return frozenset(), False
    new_funcs = toplevel_functions(new_tree)
    old_src = read_at(repo, pre, relpath)
    if old_src is None:
        return frozenset(new_funcs), True  # brand-new file: every def is "new"
    try:
        old_funcs = toplevel_functions(ast.parse(old_src))
    except SyntaxError:
        return frozenset(), False
    changed = {
        name for name, node in new_funcs.items()
        if name not in old_funcs or ast.dump(node) != ast.dump(old_funcs[name])
    }
    return frozenset(changed), True


def call_graph(tree: ast.Module, names: set[str]) -> dict[str, set[str]]:
    """Intra-file, name-based only (Name calls, not attribute/method calls —
    see module docstring on scope). `names` is every top-level function in the
    file, not just the changed ones, so a chain through an unchanged
    intermediate function (wa-th4b1 Case 1's build_perfil) is still found."""
    funcs = toplevel_functions(tree)
    graph: dict[str, set[str]] = {n: set() for n in names}
    for name in names:
        node = funcs.get(name)
        if node is None:
            continue
        for sub in ast.walk(node):
            if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name)
                    and sub.func.id in names and sub.func.id != name):
                graph[name].add(sub.func.id)
    return graph


def reaches(graph: dict[str, set[str]], start: str, targets: frozenset[str]) -> bool:
    seen: set[str] = set()
    stack = [start]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        if n in targets:
            return True
        stack.extend(graph.get(n, ()))
    return False


class Edge:
    __slots__ = ("target", "names", "bound")

    def __init__(self, target: str, names: frozenset[str] | None, bound: str | None):
        self.target = target      # relpath of the imported file
        self.names = names        # specific symbol names imported, or None = whole module
        self.bound = bound        # local bound name for a whole-module import we CAN track precisely


def file_edges(repo: str, relpath: str, cache: dict[str, list[Edge]]) -> list[Edge]:
    """Import edges out of `relpath`, memoized — the exact fix ga-pntex already
    applied to daemon-refresh.sh's own per-file AST scan (33min citywide stall
    from re-parsing the same file once per candidate stem instead of once,
    period). One parse per unique file for this whole run, regardless of how
    many entrypoints' closures happen to include it."""
    if relpath in cache:
        return cache[relpath]
    edges: list[Edge] = []
    path = os.path.join(repo, relpath)
    try:
        tree = ast.parse(open(path, encoding="utf-8", errors="replace").read(), filename=path)
    except (OSError, SyntaxError):
        cache[relpath] = edges
        return edges
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                target = resolve_module(repo, alias.name)
                if not target:
                    continue
                # precise attribute tracking only for a single-component module
                # or an explicit alias — see module docstring's scope note.
                bound = alias.asname or (alias.name if "." not in alias.name else None)
                edges.append(Edge(target, None, bound))
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            for alias in node.names:
                # "from pkg import submodule" resolves to submodule's OWN file
                # (whole-module semantics) before falling back to "symbol
                # imported from node.module" — same duck-typing gen_daemon_deps
                # .py's _imports_of()/_module_to_paths() already do by trying
                # both candidate strings.
                sub_target = resolve_module(repo, f"{node.module}.{alias.name}")
                if sub_target:
                    edges.append(Edge(sub_target, None, alias.asname or alias.name))
                    continue
                target = resolve_module(repo, node.module)
                if target:
                    edges.append(Edge(target, frozenset({alias.name}), None))
    cache[relpath] = edges
    return edges


def all_attribute_uses(repo: str, relpath: str, cache: dict[str, dict[str, set[str]]]) -> dict[str, set[str]]:
    if relpath in cache:
        return cache[relpath]
    result: dict[str, set[str]] = {}
    path = os.path.join(repo, relpath)
    try:
        tree = ast.parse(open(path, encoding="utf-8", errors="replace").read(), filename=path)
    except (OSError, SyntaxError):
        cache[relpath] = result
        return result
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            result.setdefault(node.value.id, set()).add(node.attr)
    cache[relpath] = result
    return result


def importers_of(repo: str, target: str, files: set[str], cache: dict[str, list[Edge]]):
    for m in files:
        if m == target:
            continue
        for e in file_edges(repo, m, cache):
            if e.target == target:
                yield m, e


def entrypoint_reaches_symbol(
    repo: str,
    entry: str,
    closure_files: set[str],
    relevant_changed: set[str],
    changed_syms: dict[str, frozenset[str]],
    syms_ok: dict[str, bool],
    call_graphs: dict[str, dict[str, set[str]]],
    edge_cache: dict[str, list[Edge]],
    attr_cache: dict[str, dict[str, set[str]]],
) -> bool:
    for f in relevant_changed:
        if f == entry:
            return True  # the entrypoint's OWN file changed — no tracing needed
        if not syms_ok.get(f, False):
            return True  # could not diff f's symbols — fail open
        names_changed = changed_syms.get(f) or frozenset()
        if not names_changed:
            continue  # confirmed: nothing at top-level-function granularity changed in f
        found_importer = False
        for m, edge in importers_of(repo, f, closure_files, edge_cache):
            found_importer = True
            if edge.names is not None:
                used_names = edge.names
            elif edge.bound is not None:
                uses = all_attribute_uses(repo, m, attr_cache).get(edge.bound)
                if uses is None:
                    # A whole-module import with literally zero attribute
                    # access anywhere in m is unusual enough (dynamic
                    # getattr, a bare reference passed elsewhere, a
                    # side-effect-only import) that "confirmed unused" is
                    # less likely than "our single-level Attribute scan
                    # missed the real usage pattern" — fail open rather than
                    # silently treat this edge as contributing nothing.
                    return True
                used_names = uses
            else:
                return True  # whole-module import we can't precisely track — fail open
            if used_names & names_changed:
                return True
            graph = call_graphs.get(f)
            if graph:
                for y in used_names:
                    if y in graph and reaches(graph, y, names_changed):
                        return True
        if not found_importer:
            # f is in entry's own closure yet no closure member directly
            # imports it — contradicts how gen_daemon_deps.py's closure() is
            # built (every non-seed member is discovered via some importer
            # inside the same closure). Treat as a resolution mismatch between
            # this script and the upstream generator and fail open rather than
            # silently disagree with a closure the caller already trusts.
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--deps", required=True)
    ap.add_argument("--pre", required=True)
    ap.add_argument("--post", required=True)
    ap.add_argument("--entrypoints", nargs="*", default=[])
    args = ap.parse_args()

    entrypoints = [e for e in args.entrypoints if e]
    if not entrypoints:
        return 0

    try:
        with open(args.deps, encoding="utf-8") as fh:
            deps = json.load(fh)["daemons"]
        if not isinstance(deps, dict):
            raise ValueError("'daemons' is not an object")
    except Exception as exc:  # noqa: BLE001 — best-effort helper, never hard-fails the caller
        print(f"WARN: could not read {args.deps} ({exc}) — failing open", file=sys.stderr)
        for e in entrypoints:
            print(e)
        return 0

    changed = changed_python_files(args.repo, args.pre, args.post)
    if changed is None:
        print("WARN: git diff failed — failing open", file=sys.stderr)
        for e in entrypoints:
            print(e)
        return 0
    changed_set = set(changed)

    changed_syms: dict[str, frozenset[str]] = {}
    syms_ok: dict[str, bool] = {}
    call_graphs: dict[str, dict[str, set[str]]] = {}
    for f in changed_set:
        names, ok = changed_toplevel_names(args.repo, args.pre, args.post, f)
        changed_syms[f] = names
        syms_ok[f] = ok
        if ok and names:
            new_src = read_at(args.repo, args.post, f)
            if new_src is not None:
                try:
                    tree = ast.parse(new_src)
                    call_graphs[f] = call_graph(tree, set(toplevel_functions(tree)))
                except SyntaxError:
                    pass

    edge_cache: dict[str, list[Edge]] = {}
    attr_cache: dict[str, dict[str, set[str]]] = {}
    for entry in entrypoints:
        info = deps.get(entry) or {}
        closure_files = {x for x in (info.get("closure") or []) if isinstance(x, str)}
        closure_files.add(entry)
        relevant_changed = closure_files & changed_set
        if not relevant_changed:
            # not covered by deploy_deps.json, or its recorded closure doesn't
            # intersect this deploy at all — the caller should not have asked
            # about this entry, but fail open rather than silently drop it.
            print(entry)
            continue
        if entrypoint_reaches_symbol(args.repo, entry, closure_files, relevant_changed,
                                      changed_syms, syms_ok, call_graphs, edge_cache, attr_cache):
            print(entry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
