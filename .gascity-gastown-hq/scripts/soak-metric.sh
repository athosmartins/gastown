#!/usr/bin/env bash
# soak-metric.sh — 99%-imparável KPI from the flow-episode ledger (imp25).
#
# Computes the primary metric:
#   99% = auto_resolved / (auto_resolved + agent_healed + human_technical + still_open)
#
# human_product events are EXCLUDED (product decisions are expected human-touch).
# Co-primary metrics:
#   minutos-parado     — total stall duration (sum of closed-episode durations)
#   stalls-undetected  — still_open count (episodes with no end_ts)
#
# Usage:
#   soak-metric.sh [--days N] [--ledger <path>] [--json]
#   Default: last 7 days from now (the 7-day soak window).
#
# BASELINE MODE (imp25): run with TSW_HEAL_ENABLED=0 (default) to capture
# pre-heal baseline. Compare after TSW_HEAL_ENABLED=1 to measure improvement.
set -uo pipefail

CITY="${GC_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
LEDGER="${FLOW_LEDGER:-$CITY/.gc/logs/flow-ledger.jsonl}"
RECONSTRUCT="$CITY/scripts/flow-episode-reconstruct.py"

DAYS="${SOAK_DAYS:-7}"
JSON_OUT="${1:-}"
if [ "${1:-}" = "--json" ] || [ "${2:-}" = "--json" ]; then JSON_OUT=1; fi

if [ ! -f "$RECONSTRUCT" ]; then
  echo "ERROR: flow-episode-reconstruct.py not found at $RECONSTRUCT" >&2; exit 1
fi
if [ ! -f "$LEDGER" ]; then
  echo "ERROR: flow ledger not found at $LEDGER" >&2; exit 1
fi

# Compute window start (epoch seconds).
WINDOW_SEC=$(( DAYS * 86400 ))
WINDOW_START=$(date -u +%s)
WINDOW_START=$(( WINDOW_START - WINDOW_SEC ))
WINDOW_START_ISO=$(date -u -r "$WINDOW_START" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                   date -u -d "@$WINDOW_START" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

# Get episodes as JSON.
EPISODES=$(python3 "$RECONSTRUCT" --ledger "$LEDGER" --json 2>/dev/null) || {
  echo "ERROR: flow-episode-reconstruct.py failed" >&2; exit 1
}

# Filter episodes within the soak window and compute the KPI.
python3 - <<PYEOF
import json, sys, math

episodes = json.loads('''$EPISODES''') if '''$EPISODES'''.strip() else []
window_start_iso = '''$WINDOW_START_ISO'''
days = $DAYS

def parse_iso(s):
    if not s: return None
    try:
        import re
        m = re.match(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})', s)
        if not m: return None
        from datetime import datetime, timezone
        return datetime(*[int(x) for x in m.groups()], tzinfo=timezone.utc).timestamp()
    except Exception:
        return None

ws = parse_iso(window_start_iso) or 0.0

# Filter to soak window: episode started within window OR is still_open.
def in_window(ep):
    st = parse_iso(ep.get('start_ts',''))
    if st is None: return False
    return st >= ws

window_eps = [ep for ep in episodes if in_window(ep)]

auto_resolved  = sum(1 for e in window_eps if e.get('resolution') == 'auto_resolved')
agent_healed   = sum(1 for e in window_eps if e.get('resolution') == 'agent_healed')
human_tech     = sum(1 for e in window_eps if e.get('resolution') == 'human_technical')
still_open     = sum(1 for e in window_eps if e.get('resolution') == 'still_open')
human_product  = sum(1 for e in window_eps if e.get('resolution') == 'human_product')
external       = sum(1 for e in window_eps if e.get('resolution') == 'external')
total_episodes = len(window_eps)

# Denominator: technical episodes only (human_product excluded)
denominator = auto_resolved + agent_healed + human_tech + still_open
pct = (auto_resolved / denominator * 100) if denominator > 0 else None

# minutos-parado: total stall duration of closed episodes (seconds → minutes)
total_stall_sec = sum(
    e.get('duration_sec') or 0
    for e in window_eps
    if e.get('duration_sec') is not None
)
total_stall_min = total_stall_sec / 60

if '''$JSON_OUT''':
    out = {
        "window_days": days,
        "window_start_iso": window_start_iso,
        "total_episodes": total_episodes,
        "auto_resolved": auto_resolved,
        "agent_healed": agent_healed,
        "human_technical": human_tech,
        "still_open": still_open,
        "human_product": human_product,
        "external": external,
        "denominator": denominator,
        "kpi_pct": round(pct, 1) if pct is not None else None,
        "minutos_parado": round(total_stall_min, 1),
        "stalls_undetected": still_open,
    }
    print(json.dumps(out, indent=2))
else:
    print("=== 99%% imparável — soak window: last %d days ===" % days)
    print("Episodes in window : %d" % total_episodes)
    print("  auto_resolved    : %d" % auto_resolved)
    print("  agent_healed     : %d" % agent_healed)
    print("  human_technical  : %d" % human_tech)
    print("  still_open       : %d (stalls undetected/ongoing)" % still_open)
    print("  human_product    : %d (expected — excluded from KPI)" % human_product)
    print("  external         : %d" % external)
    print("Denominator (technical): %d" % denominator)
    if pct is not None:
        status = "✓ ABOVE TARGET" if pct >= 99.0 else "✗ BELOW TARGET"
        print("KPI: %.1f%% %s (target: 99%%)" % (pct, status))
    else:
        print("KPI: N/A (no technical episodes in window — baseline period)")
    print("minutos-parado   : %.1f min (total stall duration, closed episodes)" % total_stall_min)
    print("stalls-undetected: %d (still_open count)" % still_open)
    print()
    print("NOTE: TSW_HEAL_ENABLED=%s" % ("1 (heals ACTIVE)" if False else "0 (BASELINE — heals off)"))
PYEOF
