#!/bin/bash
# mol-dog-doctor.selftest.sh — checks for the ga-3wdlv/ga-v6y3p backup-freshness
# threshold fix, the runtime.sh vendoring fix that accompanies it, and the
# ga-br5sw/ga-ouqtg latency-threshold + ms-precision fix (LATENCY_WARN_S +
# latency.sh sourcing) — the latter regressed once already (ga-ouqtg) with no
# detector, which is why this file grew a matching arithmetic-reproduction
# section instead of just fixing the value again.
#
# Hermetic: never sources mol-dog-doctor.sh (it has no library mode, and its main
# body needs a live Dolt server + GC_CITY_PATH; sourcing it here would require
# faking those or risk a REAL send_mayor_mail call to the Mayor — the exact class
# of noise this fix exists to stop, e.g. this city currently has 3 real orphan
# DBs, which would trip ORPHAN_WARN on any live run). Instead: (1) static text
# checks against the shipped script, mirroring mol-dog-backup.selftest.sh's
# drift-guards, (2) a real filesystem check that the runtime.sh/latency.sh paths
# the script resolves at are actually present right now — the concrete thing a
# lib-mode/early-return selftest would be structurally blind to (see
# hermetic-selftest-cannot-test-the-bootstrap-it-stubs: 20/20 PASS + mutation
# test still missed a runtime.sh path that didn't exist), and (3) a pure
# arithmetic reproduction of each reported bug using the ACTUAL values/functions
# extracted from (or sourced from) the shipped scripts, not hand-copied constants
# — latency.sh itself is pure/leaf (no GC_CITY_PATH, no live Dolt) so it is
# sourced for real here rather than reimplemented.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/mol-dog-doctor.sh"
ORDER_TOML="$HERE/../../orders/mol-dog-doctor.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== mol-dog-doctor.selftest.sh ==="

if [ -f "$SCRIPT" ]; then
  ok "vendored script exists at $SCRIPT"
else
  bad "vendored script missing at $SCRIPT"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

if bash -n "$SCRIPT"; then
  ok "script passes bash -n syntax check"
else
  bad "script has a syntax error"
fi

# ── drift-guard: runtime.sh sourced from its real (dolt pack) location, not ──
# ── a self-relative $PACK_DIR (the ga-gquc1 attempt-1 bootstrap-crash class: ──
# ── vendoring under town-deltas makes a self-relative $PACK_DIR resolve to ───
# ── town-deltas, which never has its own runtime.sh) ──────────────────────────
if grep -qE '^\s*PACK_DIR=.*BASH_SOURCE' "$SCRIPT"; then
  bad "self-relative \$PACK_DIR computation is present — resolves to town-deltas post-vendoring, no runtime.sh there (ga-gquc1 attempt-1 class)"
else
  ok "no self-relative \$PACK_DIR computation for locating runtime.sh"
fi
if grep -qF '.gc/system/packs' "$SCRIPT" && grep -qE '\.\s+"\$\{GC_SYSTEM_PACKS_DIR:-\$GC_CITY_PATH' "$SCRIPT"; then
  ok "runtime.sh is sourced from the dolt pack's GC_CITY_PATH-anchored live location"
else
  bad "runtime.sh sourcing no longer anchors to GC_CITY_PATH/.gc/system/packs/dolt"
fi

# ── bootstrap reality-check: the resolved runtime.sh path must actually EXIST ─
# ── right now. A passing grep above proves the PATTERN is safe, not that the ──
# ── path resolves — this closes that gap with a real filesystem check. ───────
: "${GC_CITY_PATH:=/Users/athos/gt/.gascity-gastown-hq}"
RESOLVED_RUNTIME="${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/runtime.sh"
if [ -f "$RESOLVED_RUNTIME" ]; then
  ok "resolved runtime.sh path exists on disk: $RESOLVED_RUNTIME"
else
  bad "resolved runtime.sh path does NOT exist: $RESOLVED_RUNTIME — script would abort at the sourcing line under set -e"
fi

# ── threshold fix: extract the ACTUAL shipped default, not a hand-copied ─────
# ── constant, so this test fails if the value is silently reverted/changed ───
THRESHOLD_LINE=$(grep -E '^BACKUP_STALE_S=' "$SCRIPT" || true)
NEW_THRESHOLD=$(printf '%s\n' "$THRESHOLD_LINE" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' || true)
if [ -n "$NEW_THRESHOLD" ]; then
  ok "extracted BACKUP_STALE_S default from shipped script: ${NEW_THRESHOLD}s"
else
  bad "could not extract BACKUP_STALE_S default from shipped script — got line: '$THRESHOLD_LINE'"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

# ── falsifying check: the EXACT reported false positive (ga-3wdlv, all 10 DBs ─
# ── at "19h old") must NOT trip the new threshold ─────────────────────────────
REPORTED_AGE_S=$((19 * 3600))
if [ "$REPORTED_AGE_S" -gt "$NEW_THRESHOLD" ]; then
  bad "reported false-positive age (19h=${REPORTED_AGE_S}s) STILL exceeds new threshold (${NEW_THRESHOLD}s) — bug not fixed"
else
  ok "reported false-positive age (19h=${REPORTED_AGE_S}s) no longer exceeds threshold (${NEW_THRESHOLD}s)"
fi

# ── sanity: the same age DOES exceed the OLD embedded threshold, proving this ─
# ── reproduces the real bug and isn't a vacuous comparison ────────────────────
OLD_THRESHOLD=43200
if [ "$REPORTED_AGE_S" -gt "$OLD_THRESHOLD" ]; then
  ok "sanity: the reported age (19h) DOES exceed the old 12h threshold — confirms this reproduces the real bug"
else
  bad "sanity check failed: 19h does not exceed 43200s — the reproduction itself is wrong"
fi

# ── a genuinely missed backup must still alarm — the fix must not widen the ──
# ── window into silence. 40h covers a full missed daily run plus margin ──────
GENUINELY_STALE_AGE_S=$((40 * 3600))
if [ "$GENUINELY_STALE_AGE_S" -gt "$NEW_THRESHOLD" ]; then
  ok "genuinely stale backup (40h) still exceeds new threshold — real staleness is still caught"
else
  bad "genuinely stale backup (40h=${GENUINELY_STALE_AGE_S}s) does NOT exceed new threshold (${NEW_THRESHOLD}s) — fix over-corrected into silence"
fi

# ── sanity bound: threshold must clear a full day, since the real job is ─────
# ── once-daily — anything <=24h would still false-positive near the boundary ─
ONE_DAY_S=86400
if [ "$NEW_THRESHOLD" -gt "$ONE_DAY_S" ]; then
  ok "new threshold (${NEW_THRESHOLD}s) clears a full 24h day (the real backup cadence)"
else
  bad "new threshold (${NEW_THRESHOLD}s) does not even clear 24h — will still false-positive near the daily boundary"
fi

# ── order override: exec/interval unchanged from the embedded order — this ───
# ── fix is scoped to the threshold + sourcing only, not the check cadence ────
if [ -f "$ORDER_TOML" ] && grep -qF 'exec = "$PACK_DIR/assets/scripts/mol-dog-doctor.sh"' "$ORDER_TOML" \
    && grep -qF 'interval = "5m"' "$ORDER_TOML"; then
  ok "town-deltas order override points at the vendored script, cooldown interval unchanged (5m)"
else
  bad "town-deltas order override missing or does not match expected [order] shape: $ORDER_TOML"
fi

# ── ga-br5sw: latency threshold + ms-precision fix — this is the SECOND time ──
# ── this exact class regressed (ga-ouqtg was the 1st, closed 52 days earlier, ─
# ── no detector). Same recipe as the BACKUP_STALE_S checks above: extract the ─
# ── ACTUAL value from the shipped script (not a hand-copied constant) and ─────
# ── reproduce the real bug arithmetic, so a future regression of THIS SAME ────
# ── pattern (threshold too low + whole-second quantization) fails the next ────
# ── selftest run instead of being discovered only once the inbox floods again.
echo "── latency threshold + ms-precision (ga-br5sw) ──"

LATENCY_THRESHOLD_LINE=$(grep -E '^LATENCY_WARN_S=' "$SCRIPT" || true)
NEW_LATENCY_THRESHOLD_S=$(printf '%s\n' "$LATENCY_THRESHOLD_LINE" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' || true)
if [ -n "$NEW_LATENCY_THRESHOLD_S" ]; then
  ok "extracted LATENCY_WARN_S default from shipped script: ${NEW_LATENCY_THRESHOLD_S}s"
else
  bad "could not extract LATENCY_WARN_S default from shipped script — got line: '$LATENCY_THRESHOLD_LINE'"
fi

# Defense in depth: whole-second quantization can only ever read 0s or 1s, so
# any threshold >= 2s independently blocks the ga-ouqtg/ga-br5sw failure mode
# even if the ms-precision sourcing below were ever reverted on its own.
if [ -n "$NEW_LATENCY_THRESHOLD_S" ] && [ "$NEW_LATENCY_THRESHOLD_S" -ge 2 ]; then
  ok "LATENCY_WARN_S (${NEW_LATENCY_THRESHOLD_S}s) clears the quantization floor (>=2s) — safe even if ms-precision regresses independently"
else
  bad "LATENCY_WARN_S (${NEW_LATENCY_THRESHOLD_S:-unset}s) does NOT clear 2s — whole-second quantization (0s or 1s only) can trip this threshold on ANY sub-second probe"
fi

# ── drift-guard: latency.sh must still be sourced, and the probe must still ───
# ── use it — if any of these lines are stripped back out, the script silently
# ── falls back to whole-second `date +%s` (the exact ga-ouqtg/ga-br5sw class).
if grep -qF '. "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/latency.sh"' "$SCRIPT"; then
  ok "latency.sh is sourced from the dolt pack's GC_CITY_PATH-anchored live location"
else
  bad "latency.sh sourcing is missing or no longer anchors to GC_CITY_PATH/.gc/system/packs/dolt — script will regress to whole-second quantization (ga-ouqtg/ga-br5sw class)"
fi
if grep -qF 'PROBE_START_MS=$(now_ms)' "$SCRIPT" && grep -qF 'PROBE_END_MS=$(now_ms)' "$SCRIPT"; then
  ok "probe timing uses now_ms() (ms-resolution), not whole-second date +%s"
else
  bad "probe timing no longer uses now_ms() — regressed to whole-second date +%s (ga-ouqtg/ga-br5sw class)"
fi
if grep -qF 'if latency_should_warn "$LATENCY_MS" "$LATENCY_WARN_MS"; then' "$SCRIPT"; then
  ok "warn comparison uses latency_should_warn() in ms, not a raw integer-second comparison"
else
  bad "warn comparison no longer uses latency_should_warn() — check the comparison logic by hand"
fi

# ── bootstrap reality-check: the resolved latency.sh path must actually EXIST ─
RESOLVED_LATENCY="${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/latency.sh"
if [ -f "$RESOLVED_LATENCY" ]; then
  ok "resolved latency.sh path exists on disk: $RESOLVED_LATENCY"
else
  bad "resolved latency.sh path does NOT exist: $RESOLVED_LATENCY — script would abort at the sourcing line under set -e"
fi

# ── real arithmetic, not hand-copied: source the ACTUAL latency.sh (pure, no ──
# ── GC_CITY_PATH/live-Dolt dependency, safe to source directly) and drive it ──
# ── with the real reported numbers instead of reimplementing the comparison. ──
if [ -f "$RESOLVED_LATENCY" ] && [ -n "$NEW_LATENCY_THRESHOLD_S" ]; then
  # shellcheck disable=SC1090
  source "$RESOLVED_LATENCY"
  NEW_THRESHOLD_MS=$((NEW_LATENCY_THRESHOLD_S * 1000))

  # Falsifying check: the EXACT reported real latencies (84ms and 272ms, per
  # ga-br5sw) must NOT trip the new ms-based threshold.
  for REPORTED_MS in 84 272; do
    if latency_should_warn "$REPORTED_MS" "$NEW_THRESHOLD_MS"; then
      bad "reported real latency (${REPORTED_MS}ms) STILL trips the new threshold (${NEW_THRESHOLD_MS}ms) — bug not fixed"
    else
      ok "reported real latency (${REPORTED_MS}ms) does not trip the new threshold (${NEW_THRESHOLD_MS}ms)"
    fi
  done

  # Sanity: the OLD symptom — a sub-second probe quantized to 1s under
  # whole-second `date +%s` — DOES trip the OLD 1s(=1000ms) threshold. Confirms
  # this reproduces the real bug, not a vacuous comparison.
  if latency_should_warn 1000 1000; then
    ok "sanity: a quantized 1s reading DOES trip the old 1s threshold — confirms this reproduces the real bug"
  else
    bad "sanity check failed: 1000ms does not trip a 1000ms threshold — the reproduction itself is wrong"
  fi

  # Alarm-not-deaf check (explicit ga-br5sw acceptance criterion): forcing the
  # threshold to 0 must STILL fire on any positive latency — trading a
  # false-positive for a false-negative would be worse, per the bug report.
  if latency_should_warn 1 0; then
    ok "GC_DOCTOR_LATENCY_WARN_S=0 still fires on a 1ms latency — alarm has not gone deaf"
  else
    bad "GC_DOCTOR_LATENCY_WARN_S=0 does NOT fire on a 1ms latency — false-positive traded for a worse false-negative"
  fi

  # now_ms() correctness (explicit ga-br5sw acceptance criterion): a real
  # ~200ms probe must read back as ~200, not exactly 0 or exactly 1000 — the
  # signature of whole-second quantization. Uses a real sleep against the
  # ACTUAL now_ms(), not a hand-simulated value.
  PROBE_BEFORE_MS=$(now_ms)
  sleep 0.2
  PROBE_AFTER_MS=$(now_ms)
  MEASURED_MS=$((PROBE_AFTER_MS - PROBE_BEFORE_MS))
  if [ "$MEASURED_MS" -eq 0 ] || [ "$MEASURED_MS" -eq 1000 ]; then
    bad "a real ~200ms probe read back as exactly ${MEASURED_MS}ms — the ga-ouqtg whole-second quantization signature (reads only ever 0 or 1000) is back"
  elif [ "$MEASURED_MS" -ge 100 ] && [ "$MEASURED_MS" -le 3000 ]; then
    ok "a real ~200ms probe reads back as ${MEASURED_MS}ms (neither 0 nor 1000) — now_ms() has real ms resolution"
  else
    bad "a real ~200ms probe read back as ${MEASURED_MS}ms — outside the sane 100-3000ms band, something else is wrong"
  fi
else
  bad "skipping latency.sh arithmetic checks — resolved path missing or LATENCY_WARN_S extraction failed (see checks above)"
fi

# ── real-bootstrap check (ga-v75ka): the "resolved runtime.sh path exists" ────
# ── check above proves runtime.sh ITSELF is reachable — it does NOT prove ─────
# ── port_resolve.sh (sourced from WITHIN runtime.sh) resolves when GC_PACK_DIR
# ── is set to the WRONG pack, exactly as the engine sets it for a ─────────────
# ── town-deltas-owned order (GC_PACK_DIR=.../packs/town-deltas). That one ─────
# ── extra level of sourcing is exactly what a static existence check never ────
# ── executes (see memory: hermetic-selftest-cannot-test-the-bootstrap-it-stubs
# ── — 26h dead in prod with this exact class of check green). This extracts ───
# ── the REAL bootstrap lines (not a stub) from the shipped script and runs ────
# ── them for real against the live Dolt server — doctor's body is read-only ───
# ── but we still stop right after the source line to avoid a real ─────────────
# ── send_mayor_mail call if this city currently has orphan DBs (see header).
echo "── real-bootstrap check: engine GC_PACK_DIR does not break port_resolve.sh ──"
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
  if [ "$BOOT_RC" -eq 0 ] && printf '%s' "$BOOT_OUTPUT" | grep -q '^BOOTSTRAP_OK GC_DOLT_PORT='; then
    ok "real bootstrap survives engine GC_PACK_DIR=.../packs/town-deltas (resolved a live port)"
  elif printf '%s' "$BOOT_OUTPUT" | grep -q 'port_resolve.sh: No such file'; then
    bad "THE ORIGINAL BUG IS BACK: port_resolve.sh not found when GC_PACK_DIR=town-deltas (ga-v75ka) — output: $BOOT_OUTPUT"
  else
    bad "real-bootstrap check inconclusive (rc=$BOOT_RC, not the ga-v75ka 'No such file' signature — verify live Dolt is reachable and rerun): $BOOT_OUTPUT"
  fi
fi


# ── ga-clgc2: deacon_nudge_allowed()/nudge_deacon_done() — nudging a suspended
# ── agent queues forever and gets reloaded on every gc nudge poll iteration;
# ── 379 such DOG_DONE nudges to a 20-day-asleep, suspended deacon dominated
# ── Dolt poll load (48-58% across 3 measurements). Same hermetic philosophy as
# ── the rest of this file: deacon_nudge_allowed() is pure/leaf (a single
# ── string comparison, no GC_CITY_PATH/live-Dolt dependency) so its REAL
# ── source is extracted from the shipped script and sourced directly — not
# ── hand-copied — while nudge_deacon_done() (which shells out to `gc agent
# ── list`) stays a drift-guard-only check, same treatment as send_mayor_mail().
echo "── deacon suspended-agent nudge guard (ga-clgc2) ──"

if grep -qE '^deacon_nudge_allowed\(\)' "$SCRIPT" && grep -qE '^nudge_deacon_done\(\)' "$SCRIPT"; then
  ok "deacon_nudge_allowed() and nudge_deacon_done() are defined in the shipped script"
else
  bad "deacon_nudge_allowed() and/or nudge_deacon_done() missing from the shipped script"
fi

# ── drift-guard: every call site must route through the guard, not raw `gc
# ── session nudge deacon/ ... || true` (the original silent-swallow bug) ─────
RAW_NUDGE_COUNT=$(grep -cE '^\s*gc session nudge deacon/' "$SCRIPT" || true)
if [ "${RAW_NUDGE_COUNT:-0}" -eq 1 ]; then
  ok "exactly one raw 'gc session nudge deacon/' call remains — inside nudge_deacon_done() itself, as expected"
else
  bad "expected exactly 1 raw 'gc session nudge deacon/' call (inside the wrapper), found $RAW_NUDGE_COUNT — a call site may have bypassed the guard"
fi
CALL_SITE_COUNT=$(grep -cE '^\s*(nudge_deacon_done|\s+nudge_deacon_done) ' "$SCRIPT" || true)
if [ "${CALL_SITE_COUNT:-0}" -ge 3 ]; then
  ok "found $CALL_SITE_COUNT call sites routed through nudge_deacon_done() (expect >=3: unreachable-escalated, unreachable-mail-failed, normal summary)"
else
  bad "expected >=3 call sites routed through nudge_deacon_done(), found $CALL_SITE_COUNT — a DOG_DONE nudge may still call gc session nudge directly"
fi

# ── real arithmetic, not hand-copied: extract deacon_nudge_allowed()'s ACTUAL
# ── source from the shipped script (sed range /^func()/,/^}/) and source ─────
# ── just that function definition — no live Dolt/GC_CITY_PATH needed, so this
# ── is safe to do directly, same rationale as sourcing latency.sh above. ─────
DEACON_FN_SNIPPET="$(mktemp)"
sed -n '/^deacon_nudge_allowed()/,/^}/p' "$SCRIPT" > "$DEACON_FN_SNIPPET"
if [ -s "$DEACON_FN_SNIPPET" ]; then
  # shellcheck disable=SC1090
  source "$DEACON_FN_SNIPPET"
  if command -v deacon_nudge_allowed >/dev/null 2>&1; then
    # Falsifying check: the EXACT reported scenario — deacon's real suspended
    # flag (city.toml: suspended=true) — must now be REFUSED, not queued.
    if deacon_nudge_allowed "true"; then
      bad "suspended=true is ALLOWED to nudge — the exact ga-clgc2 scenario is NOT fixed"
    else
      ok "suspended=true is REFUSED (skipped) — the exact ga-clgc2 scenario is fixed"
    fi
    # AC4 non-regression: an ACTIVE (non-suspended) agent must still be nudged.
    if deacon_nudge_allowed "false"; then
      ok "suspended=false is ALLOWED to nudge — non-regression: active agents are still reachable"
    else
      bad "suspended=false is REFUSED — active-agent nudging regressed (AC4 violated)"
    fi
    # Fail-closed on lookup failure/unknown (empty string — gc/jq error, or
    # deacon not found in `gc agent list --json`): must skip, not guess-allow.
    if deacon_nudge_allowed ""; then
      bad "empty/unknown suspended flag is ALLOWED to nudge — lookup failure should fail CLOSED (skip), not open"
    else
      ok "empty/unknown suspended flag is REFUSED — lookup failure fails closed (skip), as designed"
    fi
  else
    bad "deacon_nudge_allowed() extracted but not callable after sourcing — extraction produced invalid bash"
  fi
else
  bad "could not extract deacon_nudge_allowed() source from $SCRIPT — sed range matched nothing"
fi
rm -f "$DEACON_FN_SNIPPET"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
