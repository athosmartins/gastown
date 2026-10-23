"""G12 do fixture: a MESMA interface do lib/launchd_paid_guard.py do WA (REPO_ROOT, subprocess, scan_plist, all_repo_plists, unapproved_scheduled_paid_daemons), em ~25 linhas.
Um plist é "pago e agendado" se tem StartInterval/StartCalendarInterval e algum script dos ProgramArguments (lido de REPO_ROOT) contém PAID_API."""
from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def all_repo_plists() -> list:
    out = subprocess.run(["git", "-C", str(REPO_ROOT), "ls-files", "-z", "--", "*.plist"], capture_output=True, check=True, timeout=10).stdout
    return [REPO_ROOT / p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def scan_plist(path) -> dict:
    try:
        d = plistlib.loads(Path(path).read_bytes())
    except Exception as e:  # o contrato do scanner real: plist ilegível vira parse_error, nunca exceção
        return {"plist_path": str(path), "label": None, "parse_error": str(e)}
    scripts = [a for a in (d.get("ProgramArguments") or []) if str(a).endswith((".py", ".sh"))]
    paid = ["PAID_API"] if any((REPO_ROOT / s).is_file() and "PAID_API" in (REPO_ROOT / s).read_text(errors="replace") for s in scripts) else []
    return {"plist_path": str(path), "label": d.get("Label"), "scheduled": bool(d.get("StartInterval") or d.get("StartCalendarInterval")), "scripts": scripts, "paid_markers": paid}


def unapproved_scheduled_paid_daemons(plists) -> list:
    from lib.approved_scheduled_paid_daemons import APPROVED_SCHEDULED_PAID_DAEMONS
    return [i for i in (scan_plist(p) for p in plists) if i.get("scheduled") and i.get("paid_markers") and i.get("label") not in APPROVED_SCHEDULED_PAID_DAEMONS]
