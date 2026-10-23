"""G7 do fixture: a interface do scripts/check_ntfy_bypass_guard.py do WA (_REPO_ROOT, subprocess, check(git_range))."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT))


def check(git_range: str) -> list:
    out = subprocess.run(["git", "diff", "--name-only", git_range], cwd=_REPO_ROOT, capture_output=True, text=True, check=True, timeout=10).stdout
    bad = []
    for f in out.splitlines():
        if f.endswith(".py") and f not in ("lib/notify_cli.py",):
            p = _REPO_ROOT / f
            if p.is_file() and "https://ntfy.sh/" in p.read_text(errors="replace"):
                bad.append(f)
    return bad
