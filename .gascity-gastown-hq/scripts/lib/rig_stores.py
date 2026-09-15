#!/usr/bin/env python3
"""lib/rig_stores.py — Python mirror of lib/rig-stores.sh (ga-vjybz8, the Python
slice of ga-wz03iq: 10 shell janitors/watchdogs already migrated off a hardcoded
HQ/WA/PS rig list onto the live `gc rig list`; this is the shared helper for the
handful of PYTHON callers with the same bug class).

WHY: a script whose rig-store list is hardcoded to a subset of `gc rig list`
silently never covers a rig added later — lexbh, marketing, gastown, deacon were
all added after the original HQ/WA/PS default was written, and every hardcoded
caller stayed blind to them (see lib/rig-stores.sh's header for the incident that
motivated the whole class: a lexbh bead sat 19 days invisible to a janitor that
never had lexbh in its list).

CONTRACT (mirrors lib/rig-stores.sh exactly, so a caller that already trusts the
shell contract can trust this one identically):
  - Success: returns data (a non-empty list).
  - Failure (gc missing/non-zero/timed out, unparseable JSON, zero rigs): returns
    None. NEVER an empty list on success, NEVER None with data — a caller can
    trust "is not None" and "is non-empty" to always agree.
  - Pure: no logging, no notification, no global state, no caching. Deciding how
    loudly to complain about a fallback (and how often to re-derive) is the
    CALLER's job — same division of responsibility as the shell version.
  - `gc rig list --json` alone can take 8-17s under load (ga-eu2x) — every call
    here is bounded by an explicit timeout (default 20s, same bound as the shell
    version) so a slow city never blocks a caller's sweep indefinitely.
"""
import json
import subprocess


def rig_stores(gc_bin="gc", timeout=20):
    """Return a deduplicated (by path) list of {"prefix", "path", "name"} dicts,
    one per live rig, or None on any failure. Tolerant of both the
    `{"rigs": [...]}` envelope and a bare list, matching what `gc rig list --json`
    actually emits either way."""
    try:
        r = subprocess.run([gc_bin, "rig", "list", "--json"],
                            capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout or "")
    except Exception:
        return None
    rigs = data.get("rigs") if isinstance(data, dict) else data
    if not isinstance(rigs, list):
        return None
    out = []
    seen = set()
    for entry in rigs:
        if not isinstance(entry, dict):
            continue
        path = (entry.get("path") or entry.get("work_dir") or "").strip()
        if not path or path in seen:
            continue
        seen.add(path)
        out.append({
            "prefix": (entry.get("prefix") or "").strip(),
            "path": path,
            "name": (entry.get("name") or "").strip(),
        })
    if not out:
        return None
    return out


def rig_store_paths(gc_bin="gc", timeout=20):
    """Convenience wrapper over rig_stores(): just the paths, in the same order,
    or None. Mirrors lib/rig-stores.sh's rig_stores_paths()."""
    rigs = rig_stores(gc_bin, timeout)
    if rigs is None:
        return None
    return [r["path"] for r in rigs]


def rig_store_for_prefix(prefix, rigs):
    """Look up one rig's path by its bead-id prefix (e.g. "wa", "lx") in an
    ALREADY-DERIVED `rigs` list (from rig_stores()) — takes the list as an
    argument rather than re-deriving, so a caller resolving this per-item in a
    loop derives once up front and reuses, never shelling out to `gc rig list`
    per item (mirrors lib/rig-stores.sh's rig_store_for_prefix). Returns None if
    `rigs` is falsy or the prefix isn't in it — caller supplies its own fallback."""
    if not rigs:
        return None
    for r in rigs:
        if r.get("prefix") == prefix:
            return r.get("path")
    return None


def rig_name_for_path(path, rigs):
    """Look up one rig's canonical name by its EXACT store path in an
    ALREADY-DERIVED `rigs` list (from rig_stores()). Returns None if `rigs` is
    falsy or the path isn't in it — caller supplies its own fallback (e.g. a
    substring heuristic for a path this derivation never saw)."""
    if not rigs:
        return None
    for r in rigs:
        if r.get("path") == path:
            return r.get("name") or None
    return None
