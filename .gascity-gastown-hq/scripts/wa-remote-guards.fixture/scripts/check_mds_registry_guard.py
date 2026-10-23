"""G6 do fixture: a interface do scripts/check_mds_registry_guard.py do WA (_REPO_ROOT, subprocess, check(git_range, skipped=None), main() que dá "fail OPEN" em exceção)."""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT))


def check(git_range: str, skipped: list | None = None) -> list:
    from lib.mds_consumer_registry import registered_script_paths
    out = subprocess.run(["git", "diff", "--name-only", "--diff-filter=A", git_range], cwd=_REPO_ROOT, capture_output=True, text=True, check=True, timeout=10).stdout
    registered = registered_script_paths()
    bad = []
    for f in out.splitlines():
        if f.endswith(".py") and f.startswith(("scripts/", "daemons/", "lib/")) and f not in registered:
            text = (_REPO_ROOT / f).read_text(errors="replace")
            if "mega_data_set" in text and re.search(r"\.to_csv\(", text):
                bad.append(f)
    return bad


def main() -> int:
    if os.environ.get("FIXTURE_TRACE"):  # só o main() deixa rastro: o atalho chama check(), nunca o main()
        open(os.environ["FIXTURE_TRACE"], "a").write("main do G6 de confianca rodou\n")
    try:
        return 1 if check(sys.argv[1] if len(sys.argv) > 1 else "origin/main..HEAD") else 0
    except Exception:
        return 0  # fail OPEN, como o real


if __name__ == "__main__":
    sys.exit(main())
