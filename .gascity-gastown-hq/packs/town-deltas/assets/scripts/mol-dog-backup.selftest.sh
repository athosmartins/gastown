#!/bin/bash
# mol-dog-backup.selftest.sh — unit tests for classify_sync_failure() and
# bound_for_size_kb(), the pure logic behind the ga-gquc1 timeout-vs-failure fix.
#
# Hermetic: sources mol-dog-backup.sh in library mode (MOL_DOG_BACKUP_LIB=1), which
# returns before PACK_DIR/runtime.sh is sourced — no live Dolt server, port
# resolution, or GC_CITY_PATH is ever required. Real dolt/mail/nudge are NEVER
# called; nothing is deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/mol-dog-backup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Runs "$@" as a command after sourcing mol-dog-backup.sh in library mode, in a
# subshell — so the sourced script's `set -euo pipefail` never leaks into this
# selftest's own shell, and each call starts from a clean function/var state.
lib_call() {
  (
    export MOL_DOG_BACKUP_LIB=1
    . "$SCRIPT" >/dev/null 2>&1
    "$@"
  )
}

echo "=== mol-dog-backup.selftest.sh ==="

if lib_call type classify_sync_failure >/dev/null 2>&1 \
  && lib_call type bound_for_size_kb >/dev/null 2>&1; then
  ok "classify_sync_failure and bound_for_size_kb defined by lib-mode source"
else
  bad "pure functions NOT defined — lib mode broken"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

# ── classify_sync_failure: timeout (run_bounded exit 124) ────────────────────────
result=$(lib_call classify_sync_failure "hq" 124 120 "")
[ "$result" = "hq(timeout after 120s)" ] \
  && ok "timeout (rc=124) → 'hq(timeout after 120s)'" \
  || bad "timeout (rc=124) → got '$result', want 'hq(timeout after 120s)'"
case "$result" in
  *"sync failed"*) bad "timeout message must NOT contain 'sync failed' — got '$result'" ;;
  *) ok "timeout message does not contain 'sync failed'" ;;
esac

# ── classify_sync_failure: real failure (ga-b5h83-shaped captured error) ─────────
REAL_ERR="error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): error opening table file: table file not found: /Users/athos/gt/.gascity-gastown-hq/.dolt-backup/hq/vljre1ianoi9rv9j7429njjiosmr1ior"
result=$(lib_call classify_sync_failure "hq" 1 120 "$REAL_ERR")
case "$result" in
  "hq(sync failed: "*) ok "real failure (rc=1) → tagged 'sync failed' with detail" ;;
  *) bad "real failure (rc=1) → got '$result', want prefix 'hq(sync failed: '" ;;
esac
case "$result" in
  *"timeout"*) bad "real-failure message must NOT contain 'timeout' — got '$result'" ;;
  *) ok "real-failure message does not contain 'timeout'" ;;
esac

# ── AC: a DB that exceeds the bound MUST produce a DIFFERENT message than a DB ───
# ── whose sync really fails (the original ga-gquc1 bug: both collapsed to the ────
# ── identical "sync failed" string once stderr was discarded) ────────────────────
echo "── falsifying check: timeout vs real failure must differ ──"
timeout_msg=$(lib_call classify_sync_failure "hq" 124 120 "")
failure_msg=$(lib_call classify_sync_failure "hq" 1 120 "$REAL_ERR")
if [ "$timeout_msg" != "$failure_msg" ]; then
  ok "timeout message ('$timeout_msg') differs from real-failure message ('$failure_msg')"
else
  bad "timeout and real-failure produced the SAME message ('$timeout_msg') — the original bug"
fi

# ── classify_sync_failure: nonzero rc with empty/whitespace-only output ──────────
result=$(lib_call classify_sync_failure "dc" 1 120 "")
[ "$result" = "dc(sync failed: exit 1)" ] \
  && ok "nonzero rc + empty output → 'dc(sync failed: exit 1)'" \
  || bad "nonzero rc + empty output → got '$result'"
result=$(lib_call classify_sync_failure "dc" 2 120 "   ")
[ "$result" = "dc(sync failed: exit 2)" ] \
  && ok "nonzero rc + whitespace-only output → 'dc(sync failed: exit 2)'" \
  || bad "nonzero rc + whitespace-only output → got '$result'"

# ── bound_for_size_kb: small vs large vs boundary vs invalid input ───────────────
result=$(lib_call bound_for_size_kb 1000)
[ "$result" = "120" ] && ok "small size (1000KB) → bound 120" || bad "small size (1000KB) → got '$result', want 120"

result=$(lib_call bound_for_size_kb 600000)
[ "$result" = "600" ] && ok "large size (600000KB, ~hq) → bound 600" || bad "large size (600000KB) → got '$result', want 600"

result=$(lib_call bound_for_size_kb 1533572)
[ "$result" = "600" ] && ok "large size (1533572KB, ~whatsapp_automation) → bound 600" || bad "whatsapp_automation-sized input → got '$result', want 600"

result=$(lib_call bound_for_size_kb 512000)
[ "$result" = "600" ] && ok "boundary size (512000KB, ==threshold) → bound 600 (inclusive)" || bad "boundary size → got '$result', want 600"

result=$(lib_call bound_for_size_kb 511999)
[ "$result" = "120" ] && ok "just-below-boundary size (511999KB) → bound 120" || bad "just-below-boundary → got '$result', want 120"

result=$(lib_call bound_for_size_kb "")
[ "$result" = "120" ] && ok "empty size input → safe default bound 120" || bad "empty size input → got '$result', want 120"

result=$(lib_call bound_for_size_kb "notanumber")
[ "$result" = "120" ] && ok "non-numeric size input → safe default bound 120" || bad "non-numeric size input → got '$result', want 120"

# ── drift-guard: live script actually wires the fix into the sync step ───────────
echo "── drift-guard: wiring present in live script ──"
if grep -qF 'dolt backup sync "${db}-backup" 2>/dev/null' "$SCRIPT"; then
  bad "the sync line still discards stderr via 2>/dev/null — the original ga-gquc1 bug"
else
  ok "the sync line no longer discards stderr with 2>/dev/null"
fi
if grep -qF 'dolt backup sync "${db}-backup" 2>&1' "$SCRIPT"; then
  ok "the sync line captures combined stdout+stderr (2>&1) for classification"
else
  bad "the sync line does not capture output — cannot classify failures"
fi
# ga-bz7war: classify_sync_failure moved from an inline main-loop call to
# inside sync_db_with_fallback (called there as "$bound", its own parameter
# name — not the loop's "$sync_bound" the caller passes in). Check the
# current, real call site rather than the pre-refactor literal.
if grep -qF 'classify_sync_failure "$db" "$sync_rc" "$bound" "$sync_output"' "$SCRIPT"; then
  ok "sync_db_with_fallback calls classify_sync_failure with the captured exit code and output"
else
  bad "classify_sync_failure is defined but never called — dead code"
fi
if grep -qF 'sync_bound=$(bound_for_size_kb' "$SCRIPT"; then
  ok "the main loop calls bound_for_size_kb to size the per-db timeout"
else
  bad "bound_for_size_kb is defined but never called from the main loop — dead code"
fi
if grep -qE 'run_bounded[[:space:]]+120[[:space:]]+dolt backup sync' "$SCRIPT"; then
  bad "a hardcoded 'run_bounded 120 dolt backup sync' is still present — bound is no longer proportional"
else
  ok "no hardcoded 'run_bounded 120 dolt backup sync' remains"
fi

# ── drift-guard: runtime.sh sourced from its real (dolt pack) location, not ──
# ── the self-relative $PACK_DIR that broke gate attempt 1 (crashed before ────
# ── Step 1 ever ran because vendoring this script under town-deltas made ─────
# ── $PACK_DIR resolve to town-deltas, which never had its own runtime.sh) ────
if grep -qE '^\s*PACK_DIR=.*BASH_SOURCE' "$SCRIPT"; then
  bad "self-relative \$PACK_DIR computation is back — this resolves to town-deltas post-vendoring, not the dolt pack, and has no runtime.sh there (the exact gate attempt-1 bootstrap crash)"
else
  ok "no self-relative \$PACK_DIR computation for locating runtime.sh"
fi
if grep -qF '.gc/system/packs' "$SCRIPT" && grep -qE '\.\s+"\$\{GC_SYSTEM_PACKS_DIR:-\$GC_CITY_PATH' "$SCRIPT"; then
  ok "runtime.sh is sourced from the dolt pack's GC_CITY_PATH-anchored live location"
else
  bad "runtime.sh sourcing no longer anchors to GC_CITY_PATH/.gc/system/packs/dolt — verify it still resolves to a real, always-materialized file"
fi

# ── real-bootstrap check (ga-v75ka): the drift-guard above proves the SOURCE ──
# ── LINE PATTERN is safe; it does NOT prove port_resolve.sh actually resolves ─
# ── when GC_PACK_DIR is set to the WRONG pack — exactly as the engine sets it ─
# ── for a town-deltas-owned order (GC_PACK_DIR=.../packs/town-deltas). That ───
# ── one extra level of sourcing (runtime.sh sourcing ITS OWN port_resolve.sh) ─
# ── is exactly what lib-mode/early-return checks never execute (see memory:
# ── hermetic-selftest-cannot-test-the-bootstrap-it-stubs — 26h dead in prod ───
# ── with this exact class of check green). This extracts the REAL bootstrap ───
# ── lines (not a stub) from the shipped script and runs them for real against ─
# ── the live Dolt server, stopping right after the runtime.sh source line so ──
# ── no real backup sync is triggered.
echo "── real-bootstrap check: engine GC_PACK_DIR does not break port_resolve.sh ──"
: "${GC_CITY_PATH:=/Users/athos/gt/.gascity-gastown-hq}"
BOOT_LINE=$(grep -n 'assets/scripts/runtime\.sh"' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$BOOT_LINE" ]; then
  bad "could not locate the runtime.sh source line in $SCRIPT to build a bootstrap snippet"
else
  BOOT_SNIPPET="$(mktemp)"
  head -n "$BOOT_LINE" "$SCRIPT" > "$BOOT_SNIPPET"
  echo 'echo "BOOTSTRAP_OK GC_DOLT_PORT=$GC_DOLT_PORT"' >> "$BOOT_SNIPPET"
  BOOT_OUTPUT=$(GC_CITY_PATH="$GC_CITY_PATH" GC_PACK_DIR="$GC_CITY_PATH/packs/town-deltas" bash "$BOOT_SNIPPET" 2>&1)
  BOOT_RC=$?
  rm -f "$BOOT_SNIPPET"
  if [ "$BOOT_RC" -eq 0 ] && printf '%s' "$BOOT_OUTPUT" | grep '^BOOTSTRAP_OK GC_DOLT_PORT=' >/dev/null; then
    ok "real bootstrap survives engine GC_PACK_DIR=.../packs/town-deltas (resolved a live port)"
  elif printf '%s' "$BOOT_OUTPUT" | grep 'port_resolve.sh: No such file' >/dev/null; then
    bad "THE ORIGINAL BUG IS BACK: port_resolve.sh not found when GC_PACK_DIR=town-deltas (ga-v75ka) — output: $BOOT_OUTPUT"
  else
    bad "real-bootstrap check inconclusive (rc=$BOOT_RC, not the ga-v75ka 'No such file' signature — verify live Dolt is reachable and rerun): $BOOT_OUTPUT"
  fi
fi


# ── ga-clgc2: deacon_nudge_allowed() — nudging a suspended agent queues
# ── forever and gets reloaded on every gc nudge poll iteration; 379 such
# ── DOG_DONE nudges to a 20-day-asleep, suspended deacon dominated Dolt poll
# ── load (48-58% across 3 measurements). Pure/leaf function, defined before
# ── the MOL_DOG_BACKUP_LIB early-return, so lib_call exercises the real code
# ── — same treatment as classify_sync_failure/bound_for_size_kb above.
echo "── deacon suspended-agent nudge guard (ga-clgc2) ──"

if lib_call type deacon_nudge_allowed >/dev/null 2>&1; then
  ok "deacon_nudge_allowed defined by lib-mode source"
else
  bad "deacon_nudge_allowed NOT defined — lib mode broken or function missing"
fi

# Falsifying check: the EXACT reported scenario — deacon's real suspended
# flag (city.toml: suspended=true) — must now be REFUSED, not queued.
if lib_call deacon_nudge_allowed "true"; then
  bad "suspended=true is ALLOWED to nudge — the exact ga-clgc2 scenario is NOT fixed"
else
  ok "suspended=true is REFUSED (skipped) — the exact ga-clgc2 scenario is fixed"
fi

# AC4 non-regression: an ACTIVE (non-suspended) agent must still be nudged.
if lib_call deacon_nudge_allowed "false"; then
  ok "suspended=false is ALLOWED to nudge — non-regression: active agents are still reachable"
else
  bad "suspended=false is REFUSED — active-agent nudging regressed (AC4 violated)"
fi

# Fail-closed on lookup failure/unknown (empty string, or any value other than
# the literal "false" — gc/jq error, deacon not found in `gc agent list
# --json`, malformed jq output): must skip, not guess-allow.
if lib_call deacon_nudge_allowed ""; then
  bad "empty/unknown suspended flag is ALLOWED to nudge — lookup failure should fail CLOSED (skip), not open"
else
  ok "empty/unknown suspended flag is REFUSED — lookup failure fails closed (skip), as designed"
fi
if lib_call deacon_nudge_allowed "garbage"; then
  bad "garbage suspended flag is ALLOWED to nudge — anything other than the literal 'false' must fail closed"
else
  ok "garbage suspended flag is REFUSED — anything other than the literal 'false' fails closed"
fi

# ── drift-guard: every DOG_DONE call site must route through
# ── nudge_deacon_done(), not raw `gc session nudge gastown.deacon/ ... ||
# ── true` (the original silent-swallow bug) ────────────────────────────────
RAW_NUDGE_COUNT=$(grep -cE '^\s*gc session nudge gastown\.deacon/' "$SCRIPT" || true)
if [ "${RAW_NUDGE_COUNT:-0}" -eq 1 ]; then
  ok "exactly one raw 'gc session nudge gastown.deacon/' call remains — inside nudge_deacon_done() itself, as expected"
else
  bad "expected exactly 1 raw 'gc session nudge gastown.deacon/' call (inside the wrapper), found $RAW_NUDGE_COUNT — a call site may have bypassed the guard"
fi
# ── mutation-guard (ga-4zbjs): bare "deacon/" (no gastown. qualifier) resolves
# ── via bd issue-ID lookup and fuzzy-matches 2 unrelated beads in this city
# ── (dc-deacon-refinery, dc-deacon-witness) — ambiguous, so the nudge fails
# ── and `|| true` swallows it silently. Must never reappear. ────────────────
BARE_DEACON_COUNT=$(grep -cE '^\s*gc session nudge deacon/' "$SCRIPT" || true)
if [ "${BARE_DEACON_COUNT:-0}" -eq 0 ]; then
  ok "no bare 'gc session nudge deacon/' call sites — the ambiguous-target bug (ga-4zbjs) has not regressed"
else
  bad "found $BARE_DEACON_COUNT bare 'gc session nudge deacon/' call site(s) — ga-4zbjs ambiguous-target bug has regressed"
fi
CALL_SITE_COUNT=$(grep -cE '^\s*nudge_deacon_done ' "$SCRIPT" || true)
if [ "${CALL_SITE_COUNT:-0}" -ge 2 ]; then
  ok "found $CALL_SITE_COUNT call sites routed through nudge_deacon_done() (expect >=2: dolt-too-old early exit, normal summary)"
else
  bad "expected >=2 call sites routed through nudge_deacon_done(), found $CALL_SITE_COUNT — a DOG_DONE nudge may still call gc session nudge directly"
fi

# ── is_fallback_eligible_failure: the NEW pure classifier (ga-bz7war) ────────────
# ga-bz7war: mol-dog-backup.sh already told a timeout apart from a real
# failure (ga-gquc1 above), but hq still failed EVERY round because the
# SERVER CONNECTION itself (not any per-db timeout budget) was the
# bottleneck. is_fallback_eligible_failure() is the single place that
# decides whether a failure is that specific, retriable-via-a-different-path
# class, vs. a genuine failure that a fallback would just misreport.
echo "── is_fallback_eligible_failure (ga-bz7war) ──"

if lib_call type is_fallback_eligible_failure >/dev/null 2>&1; then
  ok "is_fallback_eligible_failure defined by lib-mode source"
else
  bad "is_fallback_eligible_failure NOT defined — lib mode broken or function missing"
fi

# Falsifying check: the EXACT reported production symptom (ga-bz7war,
# hq failed 2026-09-14 23:15) must be recognized as fallback-eligible.
if lib_call is_fallback_eligible_failure 1 "error on line 1 for query CALL DOLT_BACKUP('sync', 'hq-backup'): Error 1105 (HY000): context canceled"; then
  ok "'context canceled' (the exact ga-bz7war production symptom) is fallback-eligible"
else
  bad "'context canceled' is NOT fallback-eligible — the exact reported bug is not fixed"
fi

if lib_call is_fallback_eligible_failure 124 ""; then
  ok "rc=124 (run_bounded timeout) is fallback-eligible"
else
  bad "rc=124 (timeout) is NOT fallback-eligible"
fi

if lib_call is_fallback_eligible_failure 1 "mysql: connection was closed"; then
  ok "'connection was closed' (dolt-s3-backup.sh's own signature for the same root cause) is fallback-eligible"
else
  bad "'connection was closed' is NOT fallback-eligible"
fi

# AC non-regression: a GENUINE failure must NOT fall back — falling back
# would just reproduce the same failure over a slower path and misreport a
# real problem as transient. Reuses REAL_ERR (defined above): a real
# ga-b5h83-shaped captured error, not a timeout/connection symptom.
if lib_call is_fallback_eligible_failure 1 "$REAL_ERR"; then
  bad "a genuine sync failure (table file not found) is treated as fallback-eligible — would mask a real problem"
else
  ok "a genuine sync failure (table file not found) is correctly NOT fallback-eligible"
fi

if lib_call is_fallback_eligible_failure 1 ""; then
  bad "a bare nonzero exit with no output is treated as fallback-eligible — should require rc=124 or a specific signature"
else
  ok "a bare nonzero exit with no matching signature is correctly NOT fallback-eligible"
fi

# ── drift-guard: sync_db_with_fallback defined AND wired into the main loop ──────
echo "── drift-guard: fallback wiring present in live script (ga-bz7war) ──"

if lib_call type sync_db_with_fallback >/dev/null 2>&1; then
  ok "sync_db_with_fallback defined by lib-mode source"
else
  bad "sync_db_with_fallback NOT defined — lib mode broken or function missing"
fi

if grep -qF 'result=$(sync_db_with_fallback "$db" "$db_dir" "$sync_bound")' "$SCRIPT"; then
  ok "the main loop calls sync_db_with_fallback with db/db_dir/sync_bound"
else
  bad "sync_db_with_fallback is defined but never called from the main loop with the expected args — dead code"
fi

if grep -qF 'is_fallback_eligible_failure "$sync_rc" "$sync_output"' "$SCRIPT"; then
  ok "sync_db_with_fallback calls is_fallback_eligible_failure to decide the fallback trigger"
else
  bad "sync_db_with_fallback never calls is_fallback_eligible_failure — dead code"
fi

if grep -qF '_offline_backup_sync "$db" "$dest"' "$SCRIPT"; then
  ok "sync_db_with_fallback calls the shared _offline_backup_sync (ga-o3nqy2)"
else
  bad "sync_db_with_fallback never calls _offline_backup_sync — no actual fallback happens"
fi

if grep -qF '_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB"' "$SCRIPT"; then
  ok "sync_db_with_fallback checks disk floor via _floor_class before falling back (AC3)"
else
  bad "sync_db_with_fallback never checks disk floor — AC3 (disk-floor guard) not wired"
fi

if grep -qF '. "$GC_CITY_PATH/scripts/dolt-offline-backup-sync.sh"' "$SCRIPT"; then
  ok "dolt-offline-backup-sync.sh is sourced from its real, GC_CITY_PATH-anchored location"
else
  bad "dolt-offline-backup-sync.sh sourcing missing or no longer GC_CITY_PATH-anchored"
fi
if grep -qF 'DOLT_DISK_FLOOR_GUARD_LIB=1 . "$GC_CITY_PATH/scripts/dolt-disk-floor-guard.sh"' "$SCRIPT"; then
  ok "dolt-disk-floor-guard.sh is sourced in library mode from its real, GC_CITY_PATH-anchored location"
else
  bad "dolt-disk-floor-guard.sh library-mode sourcing missing or no longer GC_CITY_PATH-anchored"
fi

# ── drift-guard: three states (OK/SKIP/FAILED) never collapse (AC4) ──────────────
if grep -qF 'SKIP) append_skipped_db "$detail" ;;' "$SCRIPT"; then
  ok "the main loop routes a SKIP result to append_skipped_db, not append_failed_db"
else
  bad "a SKIP result is not routed to append_skipped_db — may be miscounted as OK or FAILED"
fi

# Mail must key on $FAILED_COUNT (=$FAILED) ONLY — a SKIP must never be
# mail-worthy ("So FAILED gera mail", AC4).
if grep -qF 'if [ "$FAILED_COUNT" -gt 0 ]; then' "$SCRIPT"; then
  ok "mail is still gated on \$FAILED_COUNT (unchanged)"
else
  bad "the mail-trigger condition changed shape — verify SKIP was not folded into it"
fi
if grep -qE 'FAILED_COUNT=.*SKIPPED' "$SCRIPT"; then
  bad "FAILED_COUNT appears derived from SKIPPED — a SKIP would now incorrectly trigger mail"
else
  ok "FAILED_COUNT is never derived from SKIPPED — a SKIP cannot trigger mail"
fi

# ── sync_db_with_fallback(): real end-to-end (ga-bz7war) ─────────────────────────
# Simulates the SPECIFIC production failure (server-mediated `dolt backup
# sync <name>` cut with "context canceled") via a thin `dolt` wrapper on
# PATH that intercepts ONLY that exact invocation shape and passes every
# other dolt call straight through to the REAL binary — so the fallback
# itself (_offline_backup_sync, the disk-floor check) runs for real against
# a tiny throwaway `dolt init` repo, the same hermetic-integration approach
# dolt-offline-backup-sync.selftest.sh's own Scenario A already uses. This
# is the test that must FAIL on HEAD (sync_db_with_fallback does not exist
# there — the bare "dolt backup sync" call has no fallback path at all) and
# PASS after the fix (the simulated failure recovers via a real fallback).
#
# The genuine-failure non-regression (a real error must NOT fall back) is
# already covered by the pure-function REAL_ERR check above — not repeated
# here as a second, redundant integration scenario.
echo "── sync_db_with_fallback() — real end-to-end (ga-bz7war) ──"

: "${GC_CITY_PATH:=/Users/athos/gt/.gascity-gastown-hq}"
OFFLINE_LIB="$GC_CITY_PATH/scripts/dolt-offline-backup-sync.sh"
FLOOR_LIB="$GC_CITY_PATH/scripts/dolt-disk-floor-guard.sh"

if [ ! -f "$OFFLINE_LIB" ] || [ ! -f "$FLOOR_LIB" ]; then
  bad "cannot locate dolt-offline-backup-sync.sh / dolt-disk-floor-guard.sh under \$GC_CITY_PATH — skipping real end-to-end scenarios"
else
  FB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/mol-dog-backup-fallback-selftest.XXXXXX")"
  FB_DATA_DIR="$FB_WORK/data-dir"
  mkdir -p "$FB_DATA_DIR"
  ( mkdir -p "$FB_DATA_DIR/testdb" && cd "$FB_DATA_DIR/testdb" && dolt init >/dev/null 2>&1 )

  FB_FAKE_LIVE_PORT=54021   # arbitrary, != the embedded CLI's default (3306)
  FB_CFG="$FB_WORK/dolt-config.yaml"
  cat > "$FB_CFG" <<EOF2
data_dir: "$FB_DATA_DIR"
listener:
  port: $FB_FAKE_LIVE_PORT
EOF2

  # Register a real file:// backup remote for testdb, matching what
  # mol-dog-backup.sh's own discovery loop expects to find via `dolt backup -v`.
  FB_BACKUP_DIR="$FB_WORK/backup/testdb"
  ( cd "$FB_DATA_DIR/testdb" && dolt backup add testdb-backup "file://$FB_BACKUP_DIR" >/dev/null 2>&1 )

  # A thin `dolt` wrapper: intercept ONLY the bare 3-arg server-mediated
  # form (`dolt backup sync <name>`, no --data-dir/--host) and simulate the
  # exact ga-bz7war production error; pass everything else (backup -v,
  # --data-dir ... sql / backup sync-url, used internally by
  # _offline_backup_sync) straight through to the REAL dolt binary.
  REAL_DOLT="$(command -v dolt)"
  FB_BIN="$FB_WORK/bin"
  mkdir -p "$FB_BIN"
  cat > "$FB_BIN/dolt" <<EOF2
#!/bin/bash
if [ "\$1" = "backup" ] && [ "\$2" = "sync" ] && [ "\$#" -eq 3 ]; then
  echo "error on line 1 for query CALL DOLT_BACKUP('sync', '\$3'): Error 1105 (HY000): context canceled" >&2
  exit 1
fi
exec "$REAL_DOLT" "\$@"
EOF2
  chmod +x "$FB_BIN/dolt"

  # fallback_call: like lib_call, but also sources the two real dependency
  # libraries and stubs run_bounded (a runtime.sh helper never sourced in
  # library mode) as a bare passthrough — the fake dolt above supplies the
  # actual failure behavior, so run_bounded's own timeout semantics are not
  # what this test exercises.
  fallback_call() {
    (
      export MOL_DOG_BACKUP_LIB=1
      . "$SCRIPT" >/dev/null 2>&1
      . "$OFFLINE_LIB"
      export DOLT_DISK_FLOOR_GUARD_LIB=1
      . "$FLOOR_LIB"
      run_bounded() { shift; "$@"; }
      "$@"
    )
  }

  # Scenario 1: simulated "context canceled" + healthy disk headroom (forced
  # via DOLT_DISK_FLOOR_WARN_GB=0/..._CRITICAL_GB=0 — the ACTUAL override
  # env vars dolt-disk-floor-guard.sh reads into its own FLOOR_WARN_GB/
  # FLOOR_CRITICAL_GB at source time; setting those internal names directly
  # is a no-op, since sourcing unconditionally overwrites them from the
  # DOLT_DISK_FLOOR_* vars — so the scenario is deterministic regardless of
  # this host's actual free space) → falls back → real OK.
  FB1_OUT=$(PATH="$FB_BIN:$PATH" \
    OFFLINE_SYNC_DOLT_CFG="$FB_CFG" OFFLINE_SYNC_TMP_ROOT="$FB_WORK" \
    DOLT_DATA_DIR="$FB_DATA_DIR" DOLT_DISK_FLOOR_WARN_GB=0 DOLT_DISK_FLOOR_CRITICAL_GB=0 \
    fallback_call sync_db_with_fallback testdb "$FB_DATA_DIR/testdb" 120 2>"$FB_WORK/scenario1.stderr")
  FB1_RC=$?
  if [ "$FB1_RC" -eq 0 ] && [ "$FB1_OUT" = "OK testdb" ]; then
    ok "simulated 'context canceled' + healthy disk → real offline fallback → OK (the ga-bz7war fix, end to end)"
  else
    bad "simulated 'context canceled' did not recover via fallback — got rc=$FB1_RC output='$FB1_OUT' (stderr: $(cat "$FB_WORK/scenario1.stderr" 2>/dev/null))"
  fi
  # Confirm the fallback that ran was the REAL one, not a no-op: the synced
  # backup directory must actually exist with content.
  if [ -d "$FB_BACKUP_DIR" ] && [ -n "$(find "$FB_BACKUP_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    ok "the offline fallback wrote real content to the backup destination — not a mocked success"
  else
    bad "OK was reported but the backup destination ($FB_BACKUP_DIR) is empty/missing — success was not real"
  fi

  # Scenario 2: same simulated failure, but disk floor forced breached
  # (DOLT_DISK_FLOOR_WARN_GB set absurdly high — see Scenario 1's note on
  # why this is the var that actually has effect) → must SKIP, never OK and
  # never silently counted as FAILED.
  FB2_OUT=$(PATH="$FB_BIN:$PATH" \
    OFFLINE_SYNC_DOLT_CFG="$FB_CFG" OFFLINE_SYNC_TMP_ROOT="$FB_WORK" \
    DOLT_DATA_DIR="$FB_DATA_DIR" DOLT_DISK_FLOOR_WARN_GB=999999 DOLT_DISK_FLOOR_CRITICAL_GB=999999 \
    fallback_call sync_db_with_fallback testdb "$FB_DATA_DIR/testdb" 120 2>/dev/null)
  FB2_STATUS="${FB2_OUT%% *}"
  if [ "$FB2_STATUS" = "SKIP" ]; then
    ok "simulated failure + breached disk floor → SKIP with a reason (AC3+AC4): $FB2_OUT"
  else
    bad "simulated failure + breached disk floor did not SKIP — got: '$FB2_OUT' (expected a 'SKIP testdb(...)' line)"
  fi

  rm -rf "$FB_WORK" 2>/dev/null
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
