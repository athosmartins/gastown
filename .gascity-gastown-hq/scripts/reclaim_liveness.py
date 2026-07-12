#!/usr/bin/env python3
"""reclaim_liveness — importable surface for the inflight-reclaim liveness +
classification helpers (gt-fppb0).

`inflight-reclaim-guard.py` holds the single, canonical implementation of the
session-liveness rails, the provably-dead classifier, the pure reclaim decision,
and the dog-pool preflight driver. Its filename contains hyphens, so it cannot be
imported with a plain `import` statement. This module loads it by path ONCE and
re-exports the public API, giving other scripts — notably the dog pre_start
preflight — a clean `import reclaim_liveness` surface with ZERO duplicated logic:
every name below resolves to the guard's own single definition.

Importing the guard does NOT run its poll loop: main() is guarded by
`if __name__ == "__main__"`, and only pure module-level defs/constants execute.
"""
import importlib.util as _ilu
import os as _os

_GUARD_PATH = _os.path.join(
    _os.path.dirname(_os.path.abspath(__file__)), "inflight-reclaim-guard.py")

_spec = _ilu.spec_from_file_location("inflight_reclaim_guard", _GUARD_PATH)
if _spec is None or _spec.loader is None:  # pragma: no cover - defensive
    raise ImportError(f"cannot load guard module from {_GUARD_PATH!r}")
_guard = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_guard)

# --- Re-exports (single source of truth = the guard module) ---
# Liveness + classification:
list_active_sessions           = _guard.list_active_sessions
session_is_live                = _guard.session_is_live
pool_has_live_worker           = _guard.pool_has_live_worker
concrete_adhoc_session_is_live = _guard.concrete_adhoc_session_is_live
list_live_sling_source_beads   = _guard.list_live_sling_source_beads
list_gate_active_source_beads  = _guard.list_gate_active_source_beads
list_suspended_agents          = _guard.list_suspended_agents
get_branch_recent              = _guard.get_branch_recent
account_is_rate_limited        = _guard.account_is_rate_limited
claimant_provably_dead         = _guard.claimant_provably_dead
# Decision + actuation:
reclaim_decision               = _guard.reclaim_decision
do_reclaim                     = _guard.do_reclaim
reclaim_dead_dog_claims        = _guard.reclaim_dead_dog_claims
# Constants callers may need:
EPHEMERAL_POOL_ASSIGNEES       = _guard.EPHEMERAL_POOL_ASSIGNEES
DOG_POOL_ALIAS                 = _guard.DOG_POOL_ALIAS
RECLAIM_TTL                    = _guard.RECLAIM_TTL
POOL_ZOMBIE_TTL                = _guard.POOL_ZOMBIE_TTL
MAX_RECLAIMS                   = _guard.MAX_RECLAIMS

# Underlying module, for advanced callers/tests.
guard = _guard

__all__ = [
    "list_active_sessions", "session_is_live", "pool_has_live_worker",
    "concrete_adhoc_session_is_live", "list_live_sling_source_beads",
    "list_gate_active_source_beads", "list_suspended_agents", "get_branch_recent",
    "account_is_rate_limited", "claimant_provably_dead", "reclaim_decision",
    "do_reclaim", "reclaim_dead_dog_claims", "EPHEMERAL_POOL_ASSIGNEES",
    "DOG_POOL_ALIAS", "RECLAIM_TTL", "POOL_ZOMBIE_TTL", "MAX_RECLAIMS", "guard",
]
