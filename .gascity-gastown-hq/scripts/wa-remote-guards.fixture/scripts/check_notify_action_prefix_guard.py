"""G7b do fixture: a interface do scripts/check_notify_action_prefix_guard.py do WA (check(src) -> lista de problemas; função pura)."""
from __future__ import annotations


def check(src: str) -> list:
    return [] if "ACTION_PREFIX_OK" in src else ["scripts/notify: ação sem o prefixo registrado"]
