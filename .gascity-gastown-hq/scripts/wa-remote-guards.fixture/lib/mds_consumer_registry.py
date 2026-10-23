"""Registro MDS do fixture: a interface do lib/mds_consumer_registry.py do WA (_REPO_ROOT, _REGISTRY_DIR, registered_script_paths)."""
from __future__ import annotations

import json
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_REGISTRY_DIR = _REPO_ROOT / "lib" / "mds_consumers.d"


def registered_script_paths() -> set:
    out: set = set()
    for p in sorted(_REGISTRY_DIR.glob("*.json")):
        out.update(json.loads(p.read_text()).get("scripts", []))
    return out
