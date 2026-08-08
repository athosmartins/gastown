#!/usr/bin/env bash
# wa-beads-config-guard.sh — Durable guard for WA .beads/config.yaml types.custom corruption.
#
# ROOT CAUSE (wa-qhy2):
#   gc v1.2.0 binary's embedded gc-beads-bd.sh ensure_types_custom_in_yaml reads the
#   current types.custom value with: current=$(sed 's/^types\.custom: *//p' config.yaml)
#   If the value was previously written with double-quotes (e.g., "agent,role,..."), sed
#   leaves the quotes in `current`. The awk dedup then treats '"agent' as different from
#   'agent', producing: "agent,...,step",agent,step  — INVALID YAML.
#   bd fails on init: "yaml: line 55: did not find expected key"
#   → agents cannot spawn in WA context.
#
# TRIGGER: any gc operation that calls gc-beads-bd.sh init for the WA rig
#   (gc session new, gc rig resume/sling, gc doctor --fix with custom-types repair, etc.)
#   Each of these calls ensure_types_custom_in_yaml which re-corrupts the file if
#   the value on disk currently has quotes.
#
# GUARD STRATEGY (launchd WatchPaths):
#   - launchd watches .beads/config.yaml for ANY write/change
#   - On change, this script runs IMMEDIATELY (within ~1-2 seconds)
#   - Validates config with Python yaml.safe_load
#   - If invalid: strips quotes from types.custom, deduplicates, rewrites atomically
#   - If valid: logs "OK" and exits
#   - Mode: poll fallback (every 15s) handles cases where launchd misses rapid writes
#
# IDEMPOTENT: running on a clean config is a no-op (validate succeeds, exits immediately).
# ATOMIC: repair uses os.replace (rename) to avoid partial-write races with gc.
#
# NOTE: This is a BINARY-SOURCE workaround. The durable fix requires patching the Go
#   binary (gastownhall/gascity) to quote-strip in ensure_types_custom_in_yaml before
#   the awk dedup — i.e., add: current=$(echo "$current" | sed 's/^"//;s/"$//')
#   Until the binary is patched and deployed, this guard is the durable mitigation.
#
# Deployed as: com.gascity.wa-beads-config-guard (launchd KeepAlive + WatchPaths)
# Log: .gc/logs/wa-beads-config-guard.log

set -uo pipefail

CONFIG="/Users/athos/gt/whatsapp_automation/.beads/config.yaml"
LOG_DIR="/Users/athos/gt/.gascity-gastown-hq/.gc/logs"
LOG="$LOG_DIR/wa-beads-config-guard.log"
POLL_INTERVAL=15  # fallback poll interval in seconds

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { printf '[%s] [wa-config-guard] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err()  { printf '[%s] [wa-config-guard] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "=== wa-beads-config-guard started (PID $$) ==="

# ── YAML Validation ───────────────────────────────────────────────────────────
validate_config() {
    [ -f "$CONFIG" ] || return 1
    python3 -c "
import yaml, sys
try:
    yaml.safe_load(open('$CONFIG'))
    sys.exit(0)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# ── Repair: strip quotes from types.custom value, dedup, rewrite atomically ──
repair_config() {
    [ -f "$CONFIG" ] || return 1

    local repair_result repair_rc
    repair_result=$(python3 << 'PYEOF' 2>&1
import re, os, sys

config_path = '/Users/athos/gt/whatsapp_automation/.beads/config.yaml'

try:
    with open(config_path) as f:
        content = f.read()
except Exception as e:
    print(f'read-error: {e}')
    sys.exit(1)

lines = content.splitlines(keepends=True)
repaired = []
changed = False

for line in lines:
    # Match types.custom: <any value>
    m = re.match(r'^(types\.custom:)\s*(.+?)\s*$', line)
    if m:
        key, val = m.groups()
        # Extract all identifier tokens (handles quoted + bare tokens, hyphenated names)
        # This regex handles: "a,b,merge-request",c,d → [a, b, merge-request, c, d]
        all_types = []
        seen = set()
        for t in re.findall(r'[a-zA-Z0-9][a-zA-Z0-9_-]*', val):
            if t not in seen:
                seen.add(t)
                all_types.append(t)
        if not all_types:
            repaired.append(line)
            continue
        new_val = ','.join(all_types)
        new_line = f'{key} {new_val}\n'
        if new_line.rstrip() != line.rstrip():
            changed = True
            repaired.append(new_line)
            print(f'fixed: {line.rstrip()!r} -> {new_line.rstrip()!r}')
        else:
            repaired.append(line)
    else:
        repaired.append(line)

if not changed:
    print('no-change')
    sys.exit(0)

# Atomic write via tmp + os.replace
tmp_path = config_path + '.guard-repair.tmp'
try:
    with open(tmp_path, 'w') as f:
        f.write(''.join(repaired))
    os.replace(tmp_path, config_path)
    print('repaired')
    sys.exit(0)
except Exception as e:
    try:
        os.unlink(tmp_path)
    except Exception:
        pass
    print(f'write-error: {e}')
    sys.exit(1)
PYEOF
    )
    # ga-879wu gate-feedback: $? right after `echo` reflected echo's own status
    # (always 0), never python3's — capture it immediately after the assignment
    # instead, so check_and_repair()'s `[ $exit_code -ne 0 ]` branch (its
    # dedicated "Repair failed (exit ...)" message) can actually fire. Neutral
    # in practice before this fix (check_and_repair's own validate_config()
    # re-check catches a failed repair either way and still returns 1), but the
    # dead branch's more specific diagnostic was unreachable.
    repair_rc=$?
    echo "$repair_result"
    return "$repair_rc"
}

# ── Check-and-repair cycle ────────────────────────────────────────────────────
check_and_repair() {
    if validate_config; then
        return 0
    fi

    log "YAML parse failed — repairing types.custom..."

    local repair_out
    repair_out=$(repair_config 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        err "Repair failed (exit $exit_code): $repair_out"
        return 1
    fi

    log "Repair output: $repair_out"

    if validate_config; then
        log "Repair SUCCESSFUL — config.yaml is valid again"
        return 0
    else
        err "Repair ran but config STILL invalid — manual intervention required"
        return 1
    fi
}

# ── Main poll loop ─────────────────────────────────────────────────────────────
# NOTE: launchd WatchPaths triggers this script on each file change.
# When triggered by WatchPaths, launchd does a single run and exits (no KeepAlive loop).
# KeepAlive=true restarts this script after exit. We do one check then sleep+poll
# so that: (a) the file-change trigger gets an immediate check, (b) we also catch
# any rapid corruption cycles that happen between restarts.
#
# This loop approach (check once + poll) works correctly with launchd KeepAlive:
# - On WatchPaths trigger: script starts, does immediate check, then enters poll loop
# - poll loop runs indefinitely until process exits (e.g., launchd unloads it)
# - If process crashes/exits unexpectedly, KeepAlive restarts it

log "Starting check-and-repair loop (poll interval: ${POLL_INTERVAL}s)"

# Immediate check on startup (handles file-change trigger case)
check_and_repair || true

# Periodic poll fallback
while true; do
    sleep "$POLL_INTERVAL"
    check_and_repair || true
done
