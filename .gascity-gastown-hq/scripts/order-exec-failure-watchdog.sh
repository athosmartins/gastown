#!/usr/bin/env bash
# order-exec-failure-watchdog.sh — alerts when a supervisor `order exec` keeps
# failing, instead of the failure being swallowed silently by supervisor.log.
#
# ga-q5t8r: mol-dog-backup + mol-dog-doctor died on every bootstrap for ~26h
# (78 occurrences) with ZERO alerts — the only record was supervisor.log, which
# no daemon reads and no human tails. The dog that died was itself the backup
# verifier: the component whose job is to shout when backups break went dark
# with nobody the wiser. Runs every 5 min via launchd
# (com.gascity.order-exec-failure-watchdog, StartInterval), fresh each run,
# self-recovering by design (no daemon state to get wedged).
#
# What it does:
#   - Tails ONLY the bytes appended to supervisor.log since the last sweep, via
#     a persisted byte-offset cursor (classic log-shipper position file) — NOT
#     a fixed-size recent-window read. A fixed window would keep re-seeing (and
#     re-counting) the SAME old failure lines for as long as they stay inside
#     the window, well after the underlying problem was fixed.
#   - Ignores `failed: context canceled` (routine city-shutdown noise — e.g. the
#     2026-07-28 entries). Counts `failed: exit status N` as a real failure.
#   - An order needs OEFW_FAIL_THRESHOLD (default 2) consecutive SWEEPS with a
#     new real failure before it alerts. One transient blip never pages anyone;
#     since orders retry on their own ~5m cooldown (see packs/town-deltas/orders/
#     *.toml), 2 consecutive sweeps already means back-to-back attempts failed.
#   - A sweep with ZERO new failures for a previously-failing order resets that
#     order's counter (supervisor.log has no explicit "succeeded" line — silence
#     is the only recovery signal available) and clears its cooldown, so a LATER
#     recurrence alerts fresh instead of inheriting a stale window.
#   - Cooldown-dedups per order (OEFW_COOLDOWN_SEC, default 3600s) so a
#     persistently-broken order re-reminds hourly instead of flooding — the
#     ga-q5t8r complaint was 78 mails for ONE incident across 26h, not one mail.
#   - Captures the engine's own `order exec <name> output: ...` line (the
#     diagnostic detail — e.g. exactly which file was missing) and includes it
#     verbatim in the alert body.
#
# Fail-safe: any read/parse error is logged and the sweep continues; it never
# crashes launchd into a retry loop of its own, and a failed read never
# advances the cursor (so the unread bytes are retried next sweep instead of
# silently skipped).
#
# TEST (hermetic, no live supervisor.log/gc/notify):
#   bash scripts/order-exec-failure-watchdog.selftest.sh
set -uo pipefail

HQ="${OEFW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
LOG="${OEFW_LOG:-$HQ/.gc/logs/order-exec-failure-watchdog.log}"
STATE="${OEFW_STATE:-$HQ/.gc/order-exec-failure-state}"
# Same env var name gate-recovery-watchdog.py and supervisor-config-guard.py
# already read for this exact file — keep all three pointed at one override.
SUPERVISOR_LOG="${GC_SUPERVISOR_LOG:-/Users/athos/.gc/supervisor.log}"

OEFW_FAIL_THRESHOLD="${OEFW_FAIL_THRESHOLD:-2}"
OEFW_COOLDOWN_SEC="${OEFW_COOLDOWN_SEC:-3600}"
# Safety clamp: if the offset cursor is stale/corrupt and the "new" region
# would be huge, don't awk-parse a multi-MB backlog in one sweep — clamp to the
# most recent slice and log a WARN instead.
OEFW_MAX_READ_BYTES="${OEFW_MAX_READ_BYTES:-5000000}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

_fail_count_file()  { echo "${STATE}.fail-counts/$1"; }
_fail_count_get()   { local f; f="$(_fail_count_file "$1")"; [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0; }
_fail_count_set()   { local f; f="$(_fail_count_file "$1")"; mkdir -p "$(dirname "$f")" 2>/dev/null || true; printf '%s\n' "$2" > "$f" 2>/dev/null || true; }
_fail_count_reset() { local f; f="$(_fail_count_file "$1")"; rm -f "$f" 2>/dev/null || true; }

_cooldown_file()     { echo "${STATE}.cooldown/$1"; }
_cooldown_last_get() { local f; f="$(_cooldown_file "$1")"; [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0; }
_cooldown_last_set() { local f; f="$(_cooldown_file "$1")"; mkdir -p "$(dirname "$f")" 2>/dev/null || true; printf '%s\n' "$2" > "$f" 2>/dev/null || true; }
_cooldown_clear()    { rm -f "$(_cooldown_file "$1")" 2>/dev/null || true; }

# Alert helper — notify is PRIMARY (fires first, unconditionally); gc mail send
# mayor is SECONDARY (durable record, best-effort — a mail failure never blocks
# or is blocked by notify). Matches the house CALL INVARIANT used by every other
# daemon/watchdog in this tree (gc-dolt-probe.sh, throughput-stall-watchdog.py, …).
_alert() {
  local subject="$1" msg="$2"
  log "ALERT $subject — $msg"
  command -v notify >/dev/null 2>&1 && notify -t "Order-exec watchdog: $subject" -p 4 "$msg" 2>/dev/null || true
  command -v gc >/dev/null 2>&1 && gc mail send mayor -s "Order-exec: $subject" -m "$msg" 2>/dev/null || true
}

run_sweep() {
  local offset_f="$STATE" size offset new_bytes start_at new_lines tail_rc parsed

  if [ ! -f "$SUPERVISOR_LOG" ]; then
    log "WARN supervisor.log not found at $SUPERVISOR_LOG — skipping sweep"
    return 0
  fi

  size=$(wc -c < "$SUPERVISOR_LOG" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) log "WARN could not stat $SUPERVISOR_LOG — skipping"; return 0 ;; esac

  if [ ! -f "$offset_f" ]; then
    mkdir -p "$(dirname "$offset_f")" 2>/dev/null || true
    printf '%s\n' "$size" > "$offset_f" 2>/dev/null || true
    log "BOOTSTRAP: first run — seeded cursor at EOF ($size bytes), skipping historical backlog"
    return 0
  fi

  offset=$(cat "$offset_f" 2>/dev/null | tr -d ' ')
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac

  if [ "$size" -lt "$offset" ] 2>/dev/null; then
    log "NOTE: $SUPERVISOR_LOG shrank ($size < $offset) — treating as rotated/truncated, resetting cursor to 0"
    offset=0
  fi

  local names=""
  if [ "$size" -eq "$offset" ] 2>/dev/null; then
    log "OK: no new supervisor.log data (offset=$offset)"
    # Falls through (not return) — a quiet sweep is exactly the signal the
    # recovery pass below needs to reset any previously-failing order; an
    # early return here would make that pass permanently unreachable for the
    # normal case where an order simply stops being invoked.
  else
    new_bytes=$(( size - offset ))
    start_at=$offset
    if [ "$new_bytes" -gt "$OEFW_MAX_READ_BYTES" ] 2>/dev/null; then
      log "WARN: $new_bytes new bytes exceeds clamp ($OEFW_MAX_READ_BYTES) — cursor likely stale; reading only the last $OEFW_MAX_READ_BYTES bytes"
      start_at=$(( size - OEFW_MAX_READ_BYTES ))
    fi

    new_lines=$(tail -c +$((start_at + 1)) "$SUPERVISOR_LOG" 2>/dev/null)
    tail_rc=$?
    if [ "$tail_rc" -ne 0 ]; then
      log "WARN: tail read of $SUPERVISOR_LOG failed (rc=$tail_rc) — skipping sweep, cursor NOT advanced (will retry same range)"
      # A failed read is inconclusive (not evidence of recovery) — unlike the
      # quiet-sweep case above, bail out entirely rather than falling through.
      return 0
    fi

    # Cursor advances only after a confirmed-successful read — a failed read
    # above already returned before this point, so the unread bytes stay
    # unread (retried next sweep) instead of being silently skipped.
    printf '%s\n' "$size" > "$offset_f" 2>/dev/null || true

    # Emit "FAIL\t<ts>\t<name>\t<reason>" for real failures (context-canceled
    # is skipped here, not just left uncounted, so it never reaches the bash
    # side at all) and "OUT\t<ts>\t<name>\t<detail>" for the engine's paired
    # diagnostic line. Portable awk only (no gawk-only match()/capture-group
    # extensions — macOS ships BSD awk).
    #
    # Both patterns REQUIRE a leading "YYYY/MM/DD HH:MM:SS" timestamp, not
    # just the "gc: order exec ..." substring: live supervisor.log writes
    # every event as TWO consecutive lines — one timestamped, and a bare
    # untimestamped duplicate (the order's own stderr, captured raw). An
    # untimestamped-tolerant pattern would still match, but `$1 " " $2` would
    # then grab "gc: order" as the "timestamp" for that duplicate — silently
    # corrupting the first-seen/last-seen fields of the eventual alert with
    # garbage instead of a real time. Requiring the anchor makes each real
    # event contribute exactly one record, from the line that actually has a
    # timestamp to report.
    parsed=$(printf '%s\n' "$new_lines" | awk '
      {
        line = $0
        if (line ~ /^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} gc: order exec [^ ]+ failed: /) {
          tstamp = $1 " " $2
          name = line; sub(/^.*gc: order exec /, "", name); sub(/ failed:.*$/, "", name)
          reason = line; sub(/^.*failed: /, "", reason)
          if (reason !~ /^context canceled/) {
            printf "FAIL\t%s\t%s\t%s\n", tstamp, name, reason
          }
          next
        }
        if (line ~ /^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} gc: order exec [^ ]+ output: /) {
          tstamp = $1 " " $2
          name = line; sub(/^.*gc: order exec /, "", name); sub(/ output:.*$/, "", name)
          detail = line; sub(/^.*output: /, "", detail)
          printf "OUT\t%s\t%s\t%s\n", tstamp, name, detail
        }
      }
    ' 2>/dev/null)

    if [ -z "$parsed" ]; then
      log "OK: $new_bytes new bytes, no order-exec failures (benign context-canceled lines, if any, don't count)"
    else
      # Space-joined, not newline-joined: the recovery pass below does a
      # `case " $names " in *" $prev_name "*)` substring-containment check,
      # which requires space padding between entries. `for name in $names`
      # would tolerate either (newline is a default IFS char too), but a
      # bare `sort -u` output (newline-separated) silently broke the case
      # match whenever 2+ orders failed in the same sweep — each order's
      # name was only newline-adjacent to its neighbor, never space-adjacent
      # to it, so the check never found it and reset a just-incremented
      # counter. Only a concurrent multi-order failure exposes this; a
      # single-order sweep's "$names" has no internal separator to get wrong.
      names=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="FAIL"{print $3}' | sort -u | tr '\n' ' ')
      [ -n "$names" ] || log "OK: $new_bytes new bytes, only benign(context-canceled)/output lines"
    fi
  fi

  # From here on, $names may legitimately be empty (a quiet sweep, or one with
  # no real failures) — that IS the recovery signal, so the loop below and the
  # recovery pass after it both run unconditionally rather than being gated
  # behind "this sweep found a failing order".
  local name fc first_ts last_ts last_out now cd_last since msg="" fired=""
  now=$(date +%s)
  for name in $names; do
    fc=$(( $(_fail_count_get "$name") + 1 ))
    _fail_count_set "$name" "$fc"
    first_ts=$(printf '%s\n' "$parsed" | awk -F'\t' -v n="$name" '$1=="FAIL" && $3==n {print $2; exit}')
    last_ts=$(printf '%s\n'  "$parsed" | awk -F'\t' -v n="$name" '$1=="FAIL" && $3==n {v=$2} END{print v}')
    last_out=$(printf '%s\n' "$parsed" | awk -F'\t' -v n="$name" '$1=="OUT"  && $3==n {v=$4} END{print v}')
    log "FAILING candidate: order=$name sweep-count=$fc (threshold=$OEFW_FAIL_THRESHOLD) first=$first_ts last=$last_ts output=${last_out:-(none captured)}"

    [ "$fc" -lt "$OEFW_FAIL_THRESHOLD" ] 2>/dev/null && continue

    cd_last=$(_cooldown_last_get "$name")
    since=$(( now - cd_last ))
    if [ "$since" -lt "$OEFW_COOLDOWN_SEC" ] 2>/dev/null; then
      log "COOLDOWN: order=$name already alerted ${since}s ago (cooldown ${OEFW_COOLDOWN_SEC}s) — suppressing re-mail"
      continue
    fi

    _cooldown_last_set "$name" "$now"
    fired="$fired $name"
    msg="${msg}order '$name' — $fc consecutive sweeps with real failures (exit status, not context-canceled).
  first seen (supervisor.log time): $first_ts
  last seen:  $last_ts
  engine output: ${last_out:-(no output: line captured this sweep)}
  check: grep \"order exec $name\" $SUPERVISOR_LOG | tail -20

"
  done

  # Recovery pass: any order with a STORED fail-count from a prior sweep but NO
  # new failure THIS sweep has gone quiet since — reset it and clear its
  # cooldown so a later recurrence alerts fresh rather than inheriting this
  # incident's window.
  local prev_f prev_name
  for prev_f in "${STATE}.fail-counts/"*; do
    [ -f "$prev_f" ] || continue
    prev_name="$(basename "$prev_f")"
    case " $names " in
      *" $prev_name "*) ;;
      *)
        log "RECOVERED: order=$prev_name had no new failures this sweep — resetting fail-count + cooldown"
        _fail_count_reset "$prev_name"
        _cooldown_clear "$prev_name"
        ;;
    esac
  done

  if [ -n "$fired" ]; then
    _alert "order(s) repeatedly failing —${fired}" "$msg"
    return 1
  fi
  return 0
}

# Lib mode (ORDER_EXEC_FAILURE_WATCHDOG_LIB=1): define functions, do not run —
# lets the selftest source this file and drive run_sweep() directly against a
# hermetic fixture. Matches the house convention (GATE_DISPATCHER_LIB_ONLY,
# CITY_HEALTH_SENTINEL_LIB, …) used throughout this tree's *.selftest.sh files.
if [ "${ORDER_EXEC_FAILURE_WATCHDOG_LIB:-0}" != "1" ]; then
  run_sweep
fi
