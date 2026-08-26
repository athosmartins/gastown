#!/usr/bin/env python3
"""ram-owner-sampler.py (ga-yr8vm) — periodic RSS-by-owner snapshot, appended
to a rotating JSONL. Answers "who is using the RAM" (agent/session, daemon,
rig), the thing ram-pressure-monitor.sh's own top_by_family() cannot: it
groups by app-bundle, so every `claude` process — the single largest RSS
class on this machine (measured 25/08: ~2.9GB across the agent fleet) —
collapses into one row regardless of which of the 13 concurrent sessions is
actually growing.

Attribution logic lives in ram_owner_lib.py (shared with ram-owner-report.py,
whose --top mode is called live by ram-pressure-monitor.sh — see that
script's RAM_OWNER_TOP addition).

Runs via com.gascity.ram-owner-sampler (StartInterval 300s — dense enough to
catch the kind of pressure event that hit Athos today, cheap enough not to
become its own line item: one ps snapshot + one `gc session list`, no loops,
no per-process subprocess calls beyond a bounded lsof for daemon owners).

ROTATION: kept self-contained rather than reusing log-reaper.sh — that tool
copytruncates known noise logs to near-zero, but this JSONL's whole purpose
is the "faixa histórica" (item 2 of the bead) a truncate-to-empty would erase
every cycle. Instead: keep the trailing RAM_OWNER_ROTATE_MAX_DAYS of records,
checked cheaply (file size) before paying for a full read+rewrite.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ram_owner_lib as lib

HQ = "/Users/athos/gt/.gascity-gastown-hq"
OUT = os.environ.get("RAM_OWNER_OUT", os.path.join(HQ, ".gc", "ram-owner-samples.jsonl"))
NOTIFY = os.environ.get("RAM_OWNER_NOTIFY", "/Users/athos/.local/bin/notify")
ROTATE_MAX_DAYS = float(os.environ.get("RAM_OWNER_ROTATE_MAX_DAYS", "30"))
# Cheap short-circuit: only pay for a full read+filter pass once the file is
# already substantial. A "light" time series (bead's own word) at one record
# every 5min is roughly a few hundred KB per month, so this rarely fires.
ROTATE_CHECK_MIN_BYTES = int(os.environ.get("RAM_OWNER_ROTATE_CHECK_MIN_BYTES", str(2 * 1024 * 1024)))
NOW = int(os.environ.get("RAM_OWNER_NOW_EPOCH", str(int(time.time()))))
PS_FIXTURE = os.environ.get("RAM_OWNER_PS_FIXTURE")
SESSIONS_FIXTURE = os.environ.get("RAM_OWNER_SESSIONS_FIXTURE")


def notify_fail(msg):
    try:
        import subprocess
        subprocess.run([NOTIFY, "-t", "ram-owner-sampler", "-p", "4", f"🚨 {msg}"],
                        capture_output=True, timeout=10)
    except Exception:
        pass


def rotate_if_needed(path, max_days, now):
    """Keep only records newer than now - max_days. No-ops if the file is
    small (cheap stat-only path) or doesn't exist yet."""
    try:
        if not os.path.exists(path) or os.path.getsize(path) < ROTATE_CHECK_MIN_BYTES:
            return
        cutoff = now - max_days * 86400
        kept = []
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue  # a corrupt line is dropped, not fatal — matches "unreadable != zero" only for RSS accounting, not for log hygiene
                if rec.get("ts", 0) >= cutoff:
                    kept.append(line)
        tmp = path + ".rotate.tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(kept) + ("\n" if kept else ""))
        os.replace(tmp, path)  # atomic on the same filesystem
    except Exception as e:
        # Rotation failing must never block the actual sample from being
        # recorded — worst case the file grows a bit more, never data loss.
        print(f"(aviso: rotação falhou: {e})", file=sys.stderr)


def main():
    try:
        rec = lib.sample(now=NOW, ps_fixture=PS_FIXTURE, sessions_fixture=SESSIONS_FIXTURE)
        rotate_if_needed(OUT, ROTATE_MAX_DAYS, NOW)
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "a") as f:
            f.write(json.dumps(rec) + "\n")
        if "--print" in sys.argv:
            print(json.dumps(rec, indent=2))
    except Exception as e:
        notify_fail(f"ram-owner-sampler: crash inesperado — {type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    main()
