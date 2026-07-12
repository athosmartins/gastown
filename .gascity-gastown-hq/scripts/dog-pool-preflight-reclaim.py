#!/usr/bin/env python3
"""dog-pool-preflight-reclaim — gt-fppb0 pre_start preflight for the dog pool.

Wired via city.toml (`[[patches.agent]] name="gastown.dog" pre_start=[...]`), this
runs immediately before a fresh dog executes `gc hook`. It reclaims any
PROVABLY-DEAD dog-pool claim — a zombie a dead claimant left as
in_progress + assignee=gastown.dog — so the fresh dog's Tier-1 work_query
(`bd list --status in_progress --assignee gastown.dog`) does NOT re-adopt it. That
re-adoption is the NEVERSTART respawn-loop root that burns pool workers and
pollutes APROVADAS.

CONTRACT — FAST and FAIL-OPEN. A pre_start hook must NEVER block or delay a spawn:
  * a hard wall-clock cap (SIGALRM) forces exit 0 on any hang;
  * a catch-all forces exit 0 on any error;
  * the branch check runs with fetch=False (no network) for speed.
All real work + guards live in the shared, tested guard driver
(reclaim_dead_dog_claims); this script is only the thin, safe entry point. The
inflight-reclaim-guard poll remains the authoritative backstop.
"""
import os
import sys

_BUDGET_SEC = int(os.environ.get("DOG_PREFLIGHT_BUDGET_SEC", "45"))


def _bail(*_a):
    # SIGALRM handler: over budget → fail-open, never block the spawn.
    print("[DOG-PREFLIGHT] budget exceeded — exit 0 (fail-open)", flush=True)
    os._exit(0)


def main():
    try:
        import signal
        signal.signal(signal.SIGALRM, _bail)
        signal.alarm(_BUDGET_SEC)
    except Exception:
        pass  # no SIGALRM (unlikely) → the try/except below is the safety net
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import reclaim_liveness
        # pre_start runs BEFORE this dog's own session exists, so there is nothing
        # to exclude; still pass GC_SESSION_* if present as belt-and-suspenders in
        # case the engine ever pre-registers the session.
        exclude = {os.environ.get(k, "") for k in
                   ("GC_SESSION_ID", "GC_SESSION", "GC_SESSION_NAME", "GC_WISP_ID")}
        exclude.discard("")
        reclaimed = reclaim_liveness.reclaim_dead_dog_claims(
            exclude_session_ids=(exclude or None))
        if reclaimed:
            print(f"[DOG-PREFLIGHT] gt-fppb0: reclaimed {len(reclaimed)} "
                  f"provably-dead dog claim(s): {', '.join(reclaimed)}", flush=True)
    except Exception as exc:
        print(f"[DOG-PREFLIGHT] fail-open (no spawn block): {exc}", flush=True)
    finally:
        try:
            import signal
            signal.alarm(0)
        except Exception:
            pass


if __name__ == "__main__":
    main()
    sys.exit(0)
