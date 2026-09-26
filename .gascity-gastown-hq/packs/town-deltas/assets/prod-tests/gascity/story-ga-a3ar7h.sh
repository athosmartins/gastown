#!/usr/bin/env bash
# prod-tests/gascity/story-ga-a3ar7h.sh — prod test for ga-a3ar7h: the jsonl-archive git repos
# are compacted by BYTES (git's own auto-gc counts objects and left 5.5GiB of loose hq.jsonl
# copies on the boot disk on 2026-09-26).
#
# "Merged" is not "live": this checks the DEPLOYED script, that the supervisor has actually
# LOADED the order, and that the real archives are inside the alarm limits right now. It never
# writes to an archive — `--check` is read-only.
#
# Called by run.sh after deploy (STORY_ID=ga-a3ar7h). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPT="$CITY/packs/town-deltas/assets/scripts/jsonl-archive-compact.sh"
ORDER_FILE="$CITY/packs/town-deltas/orders/jsonl-archive-compact.toml"

log()  { echo "[prod-test:gascity ga-a3ar7h] $*"; }
fail() { echo "[prod-test:gascity ga-a3ar7h] FAIL: $*" >&2; exit 1; }

# ── 1. deployed artifacts exist and are the byte-triggered version ─────────────
[[ -x "$SCRIPT" ]] || fail "deployed script missing or not executable: $SCRIPT"
[[ -f "$ORDER_FILE" ]] || fail "deployed order file missing: $ORDER_FILE"
grep -q 'LOOSE_LIMIT_KIB' "$SCRIPT" || fail "deployed script has no byte-based loose limit — the object-count version is live"
log "script + order file deployed ✓"

# ── 2. the supervisor loaded the order (a file on disk is not a scheduled order) ──
orders="$(timeout 60 gc --city "$CITY" order list --json 2>/dev/null)" || fail "gc order list failed or timed out"
n="$(printf '%s' "$orders" | jq '[.orders[] | select(.name == "jsonl-archive-compact")] | length' 2>/dev/null)"
[[ "$n" =~ ^[0-9]+$ ]] || fail "could not read gc order list (jq: '$n')"
[[ "$n" -ge 1 ]] || fail "order jsonl-archive-compact is NOT loaded by the supervisor — reload it (gc order list shows $n)"
src="$(printf '%s' "$orders" | jq -r '[.orders[] | select(.name == "jsonl-archive-compact")][0].source' 2>/dev/null)"
[[ "$src" == *"packs/town-deltas/orders/jsonl-archive-compact.toml" ]] || fail "order loaded from an unexpected source: $src"
log "order loaded by the supervisor ($n instance) from $src ✓"

# ── 3. the real archives are inside the alarm limits (read-only) ──────────────
out="$("$SCRIPT" --check 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
[[ "$rc" -eq 0 ]] || fail "--check reports a BAD archive (loose/packs past the alarm, or unmeasurable) — compaction is not keeping up"
log "archives within limits ✓"

# ── 4. informational: has the order run since the reload? ─────────────────────
logfile="$CITY/.gc/logs/jsonl-archive-compact.log"
if [[ -f "$logfile" ]]; then
  log "last order log line: $(tail -n 1 "$logfile")"
else
  log "note: $logfile does not exist yet — the order has not run since the reload (cooldown 30m); not a failure"
fi

log "PASS"
exit 0
