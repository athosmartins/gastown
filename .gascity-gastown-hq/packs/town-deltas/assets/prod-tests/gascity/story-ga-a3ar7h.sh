#!/usr/bin/env bash
# prod-tests/gascity/story-ga-a3ar7h.sh — prod test for ga-a3ar7h: the jsonl-archive git repos
# are compacted by BYTES (git's own auto-gc counts objects and left 5.5GiB of loose hq.jsonl
# copies on the boot disk on 2026-09-26).
#
# "Merged" is not "live": this checks the DEPLOYED script, that `gc order list` resolves the order
# from the deployed pack, whether the order has actually FIRED, and that the real archives are
# inside the alarm limits right now. It never writes to an archive — `--check` is read-only.
#
# What each order check can and cannot prove: `gc order list` scans the orders/ directories on the
# CLI side (its own --help says so), so it proves the file parses and resolves — NOT that the
# controller loaded it. Only `gc order history` (a past run recorded by the controller) proves
# that; on a fresh deploy the 30m cooldown may not have elapsed, so "never fired" is a loud WARN
# and the PASS line says the controller side is UNPROVEN — re-run this test after >= 30m.
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

# ── 2. `gc order list` resolves the order from the deployed pack (CLI-side scan of orders/) ──
# This is NOT proof that the controller loaded it — section 4 is.
orders="$(timeout 60 gc --city "$CITY" order list --json 2>/dev/null)" || fail "gc order list failed or timed out"
n="$(printf '%s' "$orders" | jq '[.orders[] | select(.name == "jsonl-archive-compact")] | length' 2>/dev/null)"
[[ "$n" =~ ^[0-9]+$ ]] || fail "could not read gc order list (jq: '$n')"
[[ "$n" -ge 1 ]] || fail "order jsonl-archive-compact is NOT listed by gc order list — the pack is not deployed or the file does not parse (listed: $n)"
src="$(printf '%s' "$orders" | jq -r '[.orders[] | select(.name == "jsonl-archive-compact")][0].source' 2>/dev/null)"
[[ "$src" == *"packs/town-deltas/orders/jsonl-archive-compact.toml" ]] || fail "order resolved from an unexpected source: $src"
log "gc order list resolves the order ($n instance) from $src ✓ (CLI-side scan; whether the controller loaded it is section 4)"

# ── 3. the real archives are inside the alarm limits (read-only) ──────────────
out="$("$SCRIPT" --check 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
[[ "$rc" -eq 0 ]] || fail "--check reports a BAD archive (loose/packs past the alarm, or unmeasurable) — compaction is not keeping up"
log "archives within limits ✓"

# ── 4. has the CONTROLLER fired the order? (the only proof it loaded it) ───────
# Three states, never two: fired / never fired / could not read. A read failure is UNKNOWN, not "0".
# Not a FAIL in any of them — a fresh reload legitimately has not reached its first tick (cooldown
# 30m) — but neither is it silent: it is counted and printed in the PASS line.
UNPROVEN=""
hist="$(timeout 90 gc --city "$CITY" order history jsonl-archive-compact --json 2>/dev/null)"; hrc=$?
fired="$(printf '%s' "$hist" | jq -r 'if .ok == true and (.entries | type == "array") then [.entries[] | select(.order == "jsonl-archive-compact")] | length else "unreadable" end' 2>/dev/null)"
if [[ "$hrc" -ne 0 || ! "$fired" =~ ^[0-9]+$ ]]; then
  log "WARN: could not read gc order history (rc=$hrc, parsed '${fired:-nothing}') — whether the controller has fired the order is UNKNOWN"
  UNPROVEN="controller firing UNKNOWN (gc order history unreadable)"
elif [[ "$fired" -eq 0 ]]; then
  log "WARN: gc order history has 0 runs of jsonl-archive-compact — the controller has NOT fired it yet, so 'the controller loaded the order' is UNPROVEN. Re-run this test after >= 30m."
  UNPROVEN="controller has not fired the order yet (0 runs)"
else
  last="$(printf '%s' "$hist" | jq -r '[.entries[] | select(.order == "jsonl-archive-compact") | .executed] | max' 2>/dev/null)"
  log "controller has fired the order $fired time(s), last at $last ✓"
fi
logfile="$CITY/.gc/logs/jsonl-archive-compact.log"
if [[ -f "$logfile" ]]; then
  log "last order log line: $(tail -n 1 "$logfile")"
else
  log "no $logfile yet — the script has not run under the order since the reload"
fi

if [[ -n "$UNPROVEN" ]]; then log "PASS (1 unproven: $UNPROVEN)"; else log "PASS"; fi
exit 0
