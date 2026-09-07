#!/bin/bash
# dolt-s3-backup.selftest.sh — unit tests for is_stale_manifest_error(), the pure
# detection logic behind the ga-b5h83 staging-auto-reinit hardening.
#
# Hermetic: sources dolt-s3-backup.sh as a LIBRARY (DOLT_S3_BACKUP_LIB=1) so the
# live backup flow (lock, PORT probe, DOLT_BACKUP, aws s3 sync) never runs. Real
# Dolt/AWS are NEVER called; nothing is deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-s3-backup.sh"

export DOLT_S3_BACKUP_LIB=1
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-s3-backup.selftest.sh ==="

type is_stale_manifest_error >/dev/null 2>&1 \
  && ok "is_stale_manifest_error defined by lib-mode source" \
  || { bad "is_stale_manifest_error NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

# ── real captured failure (ga-b5h83, 2026-07-28 04:00 hq run) → MUST match ───────
REAL_ERR="error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): error opening table file: table file not found: /Users/athos/gt/.gascity-gastown-hq/.dolt-backup/hq/vljre1ianoi9rv9j7429njjiosmr1ior"
is_stale_manifest_error "$REAL_ERR" && ok "real captured error → detected" || bad "real captured error NOT detected"

# ── unrelated failures → must NOT match (never mask a different root cause) ──────
is_stale_manifest_error "connection refused" && bad "unrelated 'connection refused' should NOT match" || ok "unrelated 'connection refused' → not detected"
is_stale_manifest_error "context deadline exceeded" && bad "unrelated timeout should NOT match" || ok "unrelated timeout → not detected"
is_stale_manifest_error "" && bad "empty string should NOT match" || ok "empty string → not detected"
is_stale_manifest_error "no such file or directory" && bad "unrelated 'no such file' should NOT match" || ok "unrelated 'no such file or directory' → not detected"

# ── substring anywhere in a multi-line blob still matches (log captures full output) ─
MULTI="line one
line two: error opening table file: table file not found: /some/path
line three"
is_stale_manifest_error "$MULTI" && ok "substring mid-multiline blob → detected" || bad "multiline blob NOT detected"

# ── drift-guard: live script must actually wire the retry into the sync step ─────
echo "── drift-guard: wiring present in live script ──"
if grep -qF 'is_stale_manifest_error "$(cat "$SYNC_OUT")"' "$SCRIPT"; then
  ok "sync step calls is_stale_manifest_error on the captured sync output"
else
  bad "sync step does NOT call is_stale_manifest_error — detection is dead code"
fi
if grep -qF 'rm -rf "${dest:?}"' "$SCRIPT"; then
  ok "auto-reinit clears the per-db staging dir on detection"
else
  bad "auto-reinit rm -rf wiring missing — staging never gets reinitialized"
fi
if grep -qF '"$BACKUP_ROOT"/*)' "$SCRIPT"; then
  ok "auto-reinit path-safety guard present (dest must be under BACKUP_ROOT)"
else
  bad "auto-reinit path-safety guard missing"
fi
if grep -qF 'after auto-recover retry' "$SCRIPT"; then
  ok "retry is bounded to once (no infinite retry loop)"
else
  bad "bounded-retry-once wiring missing"
fi

# ── is_connection_timeout_error() — ga-gdsq5 transient-timeout retry mitigation ──
echo "── is_connection_timeout_error() (ga-gdsq5) ──"

type is_connection_timeout_error >/dev/null 2>&1 \
  && ok "is_connection_timeout_error defined by lib-mode source" \
  || { bad "is_connection_timeout_error NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }

# ── real captured failure (ga-gdsq5, 2026-09-02 04:00:45 hq run) → MUST match ────
REAL_TIMEOUT_ERR="error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): connection was closed"
is_connection_timeout_error "$REAL_TIMEOUT_ERR" && ok "real captured error → detected" || bad "real captured error NOT detected"

# ── unrelated failures, INCLUDING the sibling detector's own case → must NOT match ─
is_connection_timeout_error "connection refused" && bad "unrelated 'connection refused' should NOT match" || ok "unrelated 'connection refused' → not detected"
is_connection_timeout_error "context deadline exceeded" && bad "unrelated timeout should NOT match" || ok "unrelated timeout → not detected"
is_connection_timeout_error "" && bad "empty string should NOT match" || ok "empty string → not detected"
is_connection_timeout_error "$REAL_ERR" && bad "stale-manifest error should NOT match connection-timeout detector" || ok "stale-manifest error → not detected by connection-timeout detector"
is_stale_manifest_error "$REAL_TIMEOUT_ERR" && bad "connection-timeout error should NOT match stale-manifest detector" || ok "connection-timeout error → not detected by stale-manifest detector"

# ── substring anywhere in a multi-line blob still matches (log captures full output) ─
MULTI_TIMEOUT="line one
line two: Error 1105 (HY000): connection was closed
line three"
is_connection_timeout_error "$MULTI_TIMEOUT" && ok "substring mid-multiline blob → detected" || bad "multiline blob NOT detected"

# ── drift-guard: live script must actually wire the retry into the sync step ─────
echo "── drift-guard: connection-timeout retry wiring present in live script ──"
if grep -qF 'is_connection_timeout_error "$(cat "$SYNC_OUT")"' "$SCRIPT"; then
  ok "sync step calls is_connection_timeout_error on the captured sync output"
else
  bad "sync step does NOT call is_connection_timeout_error — detection is dead code"
fi
if grep -qF 'after connection-timeout retry' "$SCRIPT"; then
  ok "retry is bounded (single retry, distinct log marker for frequency tracking)"
else
  bad "bounded connection-timeout-retry wiring missing"
fi
if grep -qF 'RETRY_WAIT_SEC' "$SCRIPT"; then
  ok "retry waits before retrying (gives a different load window a chance)"
else
  bad "retry-wait wiring missing"
fi

# ── preflight-unreachable retry (ga-abrbt) — a transient blip in reachability
# at 04:00 used to cost the whole day (no retry at all: FATAL + exit 0 on the
# very first probe). Not independently unit-testable without a real Dolt
# connection (unlike the two pure detectors above), so — same convention as
# the drift-guards below — assert the live script actually wires the retry
# in, rather than skip coverage entirely.
echo "── drift-guard: preflight-unreachable retry wiring present in live script (ga-abrbt) ──"
if grep -qF '_dolt_reachable' "$SCRIPT"; then
  ok "reachability probe factored into a named function (reused by first check + each retry, not copy-pasted)"
else
  bad "_dolt_reachable helper missing — reachability check should be a single reused function"
fi
if grep -qF 'PREFLIGHT_RETRY_WAITS_MIN' "$SCRIPT" && grep -qE 'sleep "\$\(\( *wait_min \* 60 *\)\)"' "$SCRIPT"; then
  ok "retry loop actually sleeps using the configured wait-minutes list"
else
  bad "preflight retry does not wire PREFLIGHT_RETRY_WAITS_MIN into a real sleep"
fi
if grep -qF 'for wait_min in $PREFLIGHT_RETRY_WAITS_MIN' "$SCRIPT"; then
  ok "retry iterates the configured waits (not a single hardcoded attempt)"
else
  bad "retry loop over PREFLIGHT_RETRY_WAITS_MIN missing"
fi
# The ONLY two `_dolt_reachable` call sites must remain: the first probe and
# the retry-loop re-probe. A 3rd call site would mean the check drifted back
# into an inline duplicate somewhere (exactly the copy-paste this refactor
# exists to prevent).
callsites="$(grep -cF '_dolt_reachable' "$SCRIPT")"
[ "$callsites" -eq 3 ] \
  && ok "exactly 3 occurrences of _dolt_reachable (1 definition + 2 call sites: first probe, retry re-probe)" \
  || bad "expected exactly 3 occurrences of _dolt_reachable (def + 2 calls), got $callsites — check for a reintroduced duplicate inline probe"
# Safety invariant, unchanged by this fix: still NEVER attempts to start/
# restart Dolt anywhere in this script, retry included. Strip comments first
# (sed 's/#.*$//') — the script legitimately MENTIONS "dolt sql-server" twice
# in prose (a fallback-port comment, and the RESTORE section's own
# description), neither of which is an invocation; a plain grep over the
# whole file would false-positive on those two pre-existing comments.
if sed -E 's/#.*$//' "$SCRIPT" | grep -qiE '\bdolt (start|restart)\b|\bsql-server\b'; then
  bad "found a Dolt start/restart/sql-server invocation (outside comments) — this script must remain READ + export only, retry must never escalate to a restart"
else
  ok "no Dolt start/restart/sql-server invocation anywhere in the script (mentions in comments don't count) — retry only re-probes, never restarts"
fi
# The exhausted-retries message must still read as FATAL+unreachable so
# dolt-compact-routine.sh's _backup_today_ok() (ga-abrbt fix) can surface it
# verbatim as the reason a run never reached "run complete".
if grep -qE 'FATAL: Dolt server unreachable on \$HOST:\$PORT after retries' "$SCRIPT"; then
  ok "final give-up message still says FATAL + unreachable (so the compact routine's precondition message can quote it)"
else
  bad "final give-up message no longer identifiable as FATAL+unreachable — downstream _backup_today_ok parsing would degrade"
fi
if grep -qF 'notify_fail "backup off-box: Dolt inacessível' "$SCRIPT" && grep -cF 'exit 0' "$SCRIPT" | grep -qE '^[1-9][0-9]*$'; then
  ok "give-up path still notifies and exits 0 (never restarts, never a nonzero exit that could trip an external supervisor into restarting Dolt)"
else
  bad "give-up path's notify/exit-0 wiring looks different than expected"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
