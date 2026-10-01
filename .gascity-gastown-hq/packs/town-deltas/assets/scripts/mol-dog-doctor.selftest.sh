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

# ── ga-ddwyw: backup_should_warn() — the age-vs-now check above answers "when
# ── did we last WRITE the backup file", never "is the backup CAUGHT UP with
# ── the source" — the only question that matters. CALL DOLT_BACKUP('sync') is
# ── incremental and writes NOTHING when there is no new commit to push, so an
# ── idle db's backup mtime freezes forever even though the backup already has
# ── everything: 7 of 12 real city databases were reported stale by this
# ── definition in one report, every one idle, none actually behind. Same
# ── style as the rest of this file: extract the REAL pure function from the
# ── shipped script and drive it with the actual reported shape, don't
# ── hand-copy the arithmetic.
echo "── backup freshness: commit-recency gate (ga-ddwyw) ──"

if grep -qE '^db_last_commit_epoch\(\)' "$SCRIPT" && grep -qE '^backup_should_warn\(\)' "$SCRIPT"; then
  ok "db_last_commit_epoch()/backup_should_warn() are defined in the shipped script"
else
  bad "db_last_commit_epoch()/backup_should_warn() missing from the shipped script"
fi

# ── ga-gh8mb: db_last_commit_epoch() must be timezone-agnostic. Dolt's
# ── dolt_log.date column is UTC already, but this server's @@time_zone=SYSTEM
# ── resolves to @@system_time_zone=-03 (this city's real value) — under that
# ── session tz, MySQL/Dolt's UNIX_TIMESTAMP(date) interprets the naive UTC
# ── string AS IF it were already -03 local and converts it AGAIN, adding a
# ── spurious +10800s (3h). Measured live on the real bug (gastown,
# ── 2026-09-04): UNIX_TIMESTAMP() returned 1788318993 for a commit `dolt log`
# ── itself displays (tz-aware, "-0300") as epoch 1788308193 — exactly
# ── +10800s off. That pushed a commit the backup had ALREADY captured
# ── (verified via `dolt backup restore` on the live staging dir — same HEAD
# ── commit hash present) to appear newer than the backup's mtime, tripping
# ── backup_should_warn()'s age-check branch and growing the "Nh old" alarm
# ── forever. Independently reproduced on lexbh (also named in ga-gh8mb):
# ── same +10800s exactly. Fix: TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00',
# ── date) computes a pure calendar difference with no timezone
# ── reinterpretation — verified live to match `dolt log`'s own tz-aware
# ── output exactly, on both affected DBs.
echo "── db_last_commit_epoch() timezone correctness (ga-gh8mb) ──"

DB_COMMIT_FN_TEXT=$(sed -n '/^db_last_commit_epoch()/,/^}/p' "$SCRIPT")
if printf '%s' "$DB_COMMIT_FN_TEXT" | grep -F "TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', " >/dev/null; then
  ok "db_last_commit_epoch() uses TIMESTAMPDIFF (timezone-agnostic), not session-tz-sensitive UNIX_TIMESTAMP"
else
  bad "db_last_commit_epoch() does not use TIMESTAMPDIFF — the ga-gh8mb timezone double-conversion bug may have regressed"
fi
if printf '%s' "$DB_COMMIT_FN_TEXT" | grep -F 'UNIX_TIMESTAMP(date)' >/dev/null; then
  bad "db_last_commit_epoch() still contains a bare UNIX_TIMESTAMP(date) call — the ga-gh8mb bug has regressed"
else
  ok "db_last_commit_epoch() no longer calls bare UNIX_TIMESTAMP(date)"
fi

# ── pure-bash reproduction of the exact bug arithmetic (hermetic — no live
# ── Dolt needed). This is the SAME misinterpretation a MySQL-family engine
# ── performs: parsing an already-UTC naive datetime string as if it were in
# ── the session's local timezone. Driven by the EXACT live-measured fixture
# ── (gastown's real commit, 2026-09-04) instead of a synthetic one, so this
# ── falsifies against the real incident, not a made-up shape.
parse_epoch_in_tz() {
  # BSD/macOS date -j first, GNU date -d fallback (portable across platforms
  # — same dual-form precaution as now_ms()'s gdate/python3 chain elsewhere
  # in this file).
  local tz="$1" naive="$2"
  TZ="$tz" date -j -f "%Y-%m-%d %H:%M:%S" "$naive" +%s 2>/dev/null \
    || TZ="$tz" date -d "$naive" +%s 2>/dev/null
}
FIXTURE_UTC_NAIVE="2026-09-02 00:16:33"     # dolt_log.date's raw string (already UTC)
EXPECTED_CORRECT_EPOCH=1788308193            # matches `dolt log` CLI's own tz-aware "-0300" display
BUGGY_EPOCH=$(parse_epoch_in_tz "America/Sao_Paulo" "$FIXTURE_UTC_NAIVE")
CORRECT_EPOCH=$(parse_epoch_in_tz "UTC" "$FIXTURE_UTC_NAIVE")

if [ -n "$BUGGY_EPOCH" ] && [ -n "$CORRECT_EPOCH" ]; then
  if [ "$BUGGY_EPOCH" -eq $((EXPECTED_CORRECT_EPOCH + 10800)) ]; then
    ok "sanity: reproducing UNIX_TIMESTAMP()'s SYSTEM-tz misinterpretation on the real fixture yields exactly +10800s over the correct epoch — confirms this reproduces the real ga-gh8mb bug"
  else
    bad "sanity check failed: buggy-interpretation reproduction ($BUGGY_EPOCH) is not exactly +10800s over the expected correct epoch ($EXPECTED_CORRECT_EPOCH) — the reproduction itself may be wrong"
  fi
  if [ "$CORRECT_EPOCH" -eq "$EXPECTED_CORRECT_EPOCH" ]; then
    ok "TIMESTAMPDIFF-equivalent (UTC-naive) interpretation of the real fixture matches dolt log's own tz-aware output ($EXPECTED_CORRECT_EPOCH)"
  else
    bad "UTC-naive interpretation ($CORRECT_EPOCH) does not match the expected correct epoch ($EXPECTED_CORRECT_EPOCH) — fixture or platform date behavior mismatch"
  fi
else
  bad "could not reproduce the timezone arithmetic on this platform (BSD 'date -j' and GNU 'date -d' both unavailable?) — skipping ga-gh8mb arithmetic sanity"
fi

# ── best-effort LIVE verification against the real Dolt server, if reachable
# ── right now. Uses fixed literal constants (never real dolt_log data, so
# ── this stays stable regardless of what commits exist in any given city) —
# ── the strongest possible proof, but non-fatal so the suite stays runnable
# ── without a live Dolt (same "best-effort, never required" spirit as this
# ── file's other live-server touches, e.g. nudge_deacon_done's `|| true`).
LIVE_DOLT_PORT="$(awk '/^listener:/{f=1} f&&/port:/{print $2; exit}' "${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}/.gc/runtime/packs/dolt/dolt-config.yaml" 2>/dev/null)"
case "${LIVE_DOLT_PORT:-}" in ''|*[!0-9]*) LIVE_DOLT_PORT="" ;; esac
if [ -n "$LIVE_DOLT_PORT" ] && DOLT_CLI_PASSWORD='' timeout 5 dolt --host 127.0.0.1 --port "$LIVE_DOLT_PORT" --user root --no-tls sql -q "SELECT 1" >/dev/null 2>&1; then
  LIVE_UNIX_TS=$(DOLT_CLI_PASSWORD='' timeout 5 dolt --host 127.0.0.1 --port "$LIVE_DOLT_PORT" --user root --no-tls sql -r csv -q "SELECT CAST(UNIX_TIMESTAMP('$FIXTURE_UTC_NAIVE') AS SIGNED)" 2>/dev/null | tail -1)
  LIVE_TS_DIFF=$(DOLT_CLI_PASSWORD='' timeout 5 dolt --host 127.0.0.1 --port "$LIVE_DOLT_PORT" --user root --no-tls sql -r csv -q "SELECT CAST(TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', '$FIXTURE_UTC_NAIVE') AS SIGNED)" 2>/dev/null | tail -1)
  case "${LIVE_TS_DIFF:-}" in
    "$EXPECTED_CORRECT_EPOCH")
      ok "LIVE: server's TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', ...) on the real fixture matches the expected correct epoch ($EXPECTED_CORRECT_EPOCH)"
      ;;
    *[0-9]*)
      bad "LIVE: server's TIMESTAMPDIFF result ($LIVE_TS_DIFF) does not match the expected correct epoch ($EXPECTED_CORRECT_EPOCH)"
      ;;
    *)
      echo "  SKIP: live TIMESTAMPDIFF query returned no usable result — skipping live verification"
      ;;
  esac
  case "${LIVE_UNIX_TS:-}" in
    "$EXPECTED_CORRECT_EPOCH")
      echo "  INFO: this server's UNIX_TIMESTAMP() is timezone-clean (matches correct epoch directly) — the ga-gh8mb double-conversion may not reproduce on this box's tz config, but the fix is tz-agnostic either way"
      ;;
    *[0-9]*)
      ok "LIVE: server's bare UNIX_TIMESTAMP() on the real fixture reproduces the double-conversion (got $LIVE_UNIX_TS, expected $EXPECTED_CORRECT_EPOCH) — confirms db_last_commit_epoch() must avoid it, exactly as this fix does"
      ;;
    *)
      echo "  SKIP: live UNIX_TIMESTAMP query returned no usable result"
      ;;
  esac
else
  echo "  SKIP: no live Dolt server reachable — skipping live ga-gh8mb verification (static + arithmetic checks above still apply)"
fi

# ── drift-guard: the backup-freshness loop must actually call both new ───────
# ── functions and gate the alarm on backup_should_warn(), not the bare ───────
# ── age-vs-threshold comparison this replaces.
if grep -qF 'DB_LAST_COMMIT_EPOCH=$(db_last_commit_epoch "$db")' "$SCRIPT" \
    && grep -qF 'if backup_should_warn "$NEWEST_BACKUP_MTIME" "$NOW_S" "$BACKUP_STALE_S" "$DB_LAST_COMMIT_EPOCH"; then' "$SCRIPT"; then
  ok "backup-freshness loop is gated by backup_should_warn(), fed by db_last_commit_epoch()"
else
  bad "backup-freshness loop no longer appears gated by backup_should_warn() — the commit-recency fix may have been bypassed"
fi
if grep -qF 'BACKUP_AGE=$((NOW_S - NEWEST_BACKUP_MTIME))' "$SCRIPT"; then
  ok "reported age (for the alarm text) is still computed from NEWEST_BACKUP_MTIME, unchanged by the gate"
else
  bad "could not confirm BACKUP_AGE is still computed the same way — check the alarm text by hand"
fi

BACKUP_FN_SNIPPET="$(mktemp)"
sed -n '/^backup_should_warn()/,/^}/p' "$SCRIPT" > "$BACKUP_FN_SNIPPET"
if [ -s "$BACKUP_FN_SNIPPET" ]; then
  # shellcheck disable=SC1090
  source "$BACKUP_FN_SNIPPET"
  if command -v backup_should_warn >/dev/null 2>&1; then
    # Fixed reference "now" for reproducible fixtures (no live clock).
    T_NOW=1788400000
    T_BACKUP_83H=$((T_NOW - 83 * 3600))                        # the exact ga-ddwyw reported age
    T_COMMIT_18D_BEFORE_BACKUP=$((T_BACKUP_83H - 18 * 86400))  # idle db: last commit long BEFORE the backup captured it

    # Falsifying check: the EXACT reported false positive — an idle db (no
    # commit since long before the backup last ran) at the EXACT reported
    # age (83h) — must NOT warn now, no matter how old the mtime is.
    if backup_should_warn "$T_BACKUP_83H" "$T_NOW" "$NEW_THRESHOLD" "$T_COMMIT_18D_BEFORE_BACKUP"; then
      bad "idle db, 83h backup age, commit 18d before the backup STILL warns — the ga-ddwyw bug is not fixed"
    else
      ok "idle db, 83h backup age, commit 18d before the backup does not warn — the ga-ddwyw bug is fixed"
    fi

    # Sanity: the age-only fallback (commit-recency unmeasured — empty arg)
    # DOES warn for this exact scenario. This is the literal old behavior
    # (age vs. threshold, nothing else) — confirms (a) the reproduction above
    # is real, not a vacuous always-false, and (b) an unmeasured commit-
    # recency never silently suppresses a real alarm.
    if backup_should_warn "$T_BACKUP_83H" "$T_NOW" "$NEW_THRESHOLD" ""; then
      ok "sanity: same 83h age with UNMEASURED commit-recency (empty) still warns — confirms the reproduction is real and unmeasured never suppresses"
    else
      bad "sanity check failed: 83h age with unmeasured commit-recency does not warn — either the reproduction is wrong or unmeasured is silently suppressing"
    fi
    # Same sanity for a non-numeric (garbage query output) commit-recency.
    if backup_should_warn "$T_BACKUP_83H" "$T_NOW" "$NEW_THRESHOLD" "notanumber"; then
      ok "non-numeric commit-recency (garbage/failed query) still warns at 83h — invalid input falls back to age-only, never silently suppresses"
    else
      bad "non-numeric commit-recency suppressed the 83h alarm — invalid input must fall back to age-only, not silently clear"
    fi

    # ACEITE (cheaper-alternative acceptance criterion, per the bead): a db
    # WITH a commit newer than what the backup captured, and stale by age,
    # MUST still warn.
    T_COMMIT_AFTER_BACKUP=$((T_BACKUP_83H + 3600))  # landed 1h after the backup ran — genuinely uncaptured
    if backup_should_warn "$T_BACKUP_83H" "$T_NOW" "$NEW_THRESHOLD" "$T_COMMIT_AFTER_BACKUP"; then
      ok "db WITH a newer uncaptured commit, 83h backup age, still warns — genuine staleness is still caught"
    else
      bad "db WITH a newer uncaptured commit, 83h backup age, does NOT warn — fix over-corrected into silence (ACEITE violated)"
    fi

    # Boundary: commit epoch exactly equal to the backup mtime — the backup
    # captured exactly that commit, must count as "no newer commit" (<=, not <).
    if backup_should_warn "$T_BACKUP_83H" "$T_NOW" "$NEW_THRESHOLD" "$T_BACKUP_83H"; then
      bad "commit epoch exactly equal to backup mtime still warns — boundary should count as 'no newer commit'"
    else
      ok "commit epoch exactly equal to backup mtime does not warn — equal counts as captured, not newer"
    fi

    # Non-regression: a healthy, recent backup (2h old, well under threshold)
    # with a newer commit must still not warn — age is what gates the alarm
    # once there IS a newer commit, unchanged from before this fix.
    T_BACKUP_2H=$((T_NOW - 2 * 3600))
    if backup_should_warn "$T_BACKUP_2H" "$T_NOW" "$NEW_THRESHOLD" "$T_NOW"; then
      bad "a healthy 2h-old backup with a just-landed newer commit warns — age threshold non-regression broken"
    else
      ok "a healthy 2h-old backup with a just-landed newer commit does not warn — non-regression holds"
    fi

    # Non-regression: the genuinely-stale 40h fixture used elsewhere in this
    # file, now WITH a newer uncaptured commit, must still warn (same shape
    # as the real hq/whatsapp_automation incident cited in ga-ddwyw, where the
    # backup was actually behind, not just idle).
    T_BACKUP_40H=$((T_NOW - GENUINELY_STALE_AGE_S))
    if backup_should_warn "$T_BACKUP_40H" "$T_NOW" "$NEW_THRESHOLD" "$T_NOW"; then
      ok "genuinely stale backup (40h) WITH a newer uncaptured commit still warns — a truly broken/behind backup is still caught"
    else
      bad "genuinely stale backup (40h) WITH a newer uncaptured commit does NOT warn — real staleness would go silent"
    fi
  else
    bad "backup_should_warn() extracted but not callable after sourcing — extraction produced invalid bash"
  fi
else
  bad "could not extract backup_should_warn() source from $SCRIPT — sed range matched nothing"
fi
rm -f "$BACKUP_FN_SNIPPET"

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

  # ── static drift-guard (ga-3bqak — 3rd occurrence of ga-ouqtg) ───────────────
  # ── The runtime probe above only proves now_ms() has ms resolution on ────────
  # ── THIS box, right now. On a GNU/Linux runner (native `date +%s%3N` works) ──
  # ── it would keep passing even if the gdate/python3 fallback branches were ───
  # ── silently stripped back to native-date-only, because they'd never be ──────
  # ── exercised there — exactly how this regressed twice before without the ────
  # ── selftest that ran on THAT box ever turning red. A text check on the ──────
  # ── actual fallback chain catches the regression on every platform, ──────────
  # ── regardless of which now_ms() branch the box running this selftest takes.
  if grep -qF 'gdate +%s%3N' "$RESOLVED_LATENCY" \
      && grep -qF "python3 -c 'import time; print(int(time.time()*1000))'" "$RESOLVED_LATENCY"; then
    ok "now_ms() still has the gdate/python3 fallback chain, not just native date — see ga-3bqak"
  else
    bad "now_ms() is missing the gdate and/or python3 fallback — regressed to native-date-only (ga-ouqtg/ga-3bqak class); a BSD-date box without coreutils will silently degrade to whole-second resolution again"
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
  if [ "$BOOT_RC" -eq 0 ] && printf '%s' "$BOOT_OUTPUT" | grep '^BOOTSTRAP_OK GC_DOLT_PORT=' >/dev/null; then
    ok "real bootstrap survives engine GC_PACK_DIR=.../packs/town-deltas (resolved a live port)"
  elif printf '%s' "$BOOT_OUTPUT" | grep 'port_resolve.sh: No such file' >/dev/null; then
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
# ── session nudge gastown.deacon/ ... || true` (the original silent-swallow
# ── bug) ───────────────────────────────────────────────────────────────────
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

# ── ga-ood0l: CONN_MAX must come from the live server, not a hardcoded guess ──
# ── (last value: 50, silently drifted from this town's real 256 for months, ───
# ── producing a false WARN at 16% of the real cap and — far worse — a
# ── numerically absurd "410% of max 50" right when a real near-exhaustion
# ── needed to be believed instead of dismissed as a monitor bug).
echo "── connection-cap resolution (ga-ood0l) ──"

if grep -qF 'CONN_MAX="${GC_DOCTOR_CONN_MAX:-}"' "$SCRIPT"; then
  ok "CONN_MAX has no hardcoded numeric default — only the explicit GC_DOCTOR_CONN_MAX override"
else
  bad "CONN_MAX default changed shape — verify by hand it still carries no numeric literal fallback"
fi

if grep -qF 'SELECT @@max_connections' "$SCRIPT"; then
  ok "CONN_MAX is resolved from the live server's own @@max_connections when no override is set"
else
  bad "no live @@max_connections query found — CONN_MAX can no longer learn the real cap"
fi

# ── real arithmetic, not hand-copied: extract conn_should_warn()'s ACTUAL ─────
# ── source from the shipped script and source just that function — pure, no ──
# ── GC_CITY_PATH/live-Dolt dependency, same rationale as deacon_nudge_allowed.
CONN_FN_SNIPPET="$(mktemp)"
sed -n '/^conn_should_warn()/,/^}/p' "$SCRIPT" > "$CONN_FN_SNIPPET"
if [ -s "$CONN_FN_SNIPPET" ]; then
  # shellcheck disable=SC1090
  source "$CONN_FN_SNIPPET"
  if command -v conn_should_warn >/dev/null 2>&1; then
    # Falsifying check: the EXACT reported false positive (42 connections,
    # real cap 256) must NOT warn against the real cap.
    if conn_should_warn 42 256 80; then
      bad "42 connections against the real cap (256) STILL warns — bug not fixed"
    else
      ok "42 connections against the real cap (256) does not warn"
    fi

    # Sanity: the SAME 42 DOES warn against the OLD hardcoded 50 — confirms
    # this reproduces the real bug, not a vacuous comparison.
    if conn_should_warn 42 50 80; then
      ok "sanity: 42 connections DOES warn against the old hardcoded cap (50) — confirms this reproduces the real bug"
    else
      bad "sanity check failed: 42 against 50 does not warn — the reproduction itself is wrong"
    fi

    # A genuine near-exhaustion against the real cap must still alarm — the
    # fix must not go deaf right when it matters (explicit ga-ood0l AC).
    if conn_should_warn 205 256 80; then
      ok "205/256 connections (>=80% of the real cap) still warns — real exhaustion is still caught"
    else
      bad "205/256 connections does NOT warn — fix over-corrected into silence at the real cap"
    fi

    # AC: "teste com teto injetado != 50 (ex. 256 e 1000)" — a second, larger
    # cap the old hardcoded 50 never exercised, so this can't pass by accident.
    if conn_should_warn 799 1000 80; then
      bad "799/1000 connections (<80%) incorrectly warns against an injected max=1000"
    else
      ok "799/1000 connections (<80% of an injected max=1000) does not warn"
    fi
    if conn_should_warn 801 1000 80; then
      ok "801/1000 connections (>=80% of an injected max=1000) warns"
    else
      bad "801/1000 connections (>=80% of an injected max=1000) does NOT warn"
    fi

    # An unmeasured cap (empty/non-numeric — the live query failed or
    # returned garbage) must never warn: a guessed cap presented as measured
    # is the bug being fixed, not an acceptable fallback (explicit ga-ood0l
    # AC: "nenhum default numérico novo entra no caminho do aviso").
    if conn_should_warn 999 "" 80; then
      bad "an empty (unmeasured) cap still warns — a silent numeric fallback is back"
    else
      ok "an empty (unmeasured) cap never warns — no silent numeric fallback"
    fi
    if conn_should_warn 999 "notanumber" 80; then
      bad "a non-numeric cap still warns — invalid input is not being rejected"
    else
      ok "a non-numeric cap never warns — invalid input is rejected, not coerced"
    fi
  else
    bad "conn_should_warn() extracted but not callable after sourcing — extraction produced invalid bash"
  fi
else
  bad "could not extract conn_should_warn() source from $SCRIPT — sed range matched nothing"
fi
rm -f "$CONN_FN_SNIPPET"

# ── drift-guard: the report/summary lines must cite the ACTUAL resolved cap ───
# ── (CONN_MAX_DISPLAY), not the raw CONN_MAX — which is allowed to be empty ───
# ── when unmeasured, so printing it raw would silently render "N/" instead of
# ── "N/unknown".
if grep -qF 'CONN_MAX_DISPLAY="${CONN_MAX:-unknown}"' "$SCRIPT" \
    && grep -qF 'Connections: ${CONN_COUNT}/${CONN_MAX_DISPLAY}${CONN_WARN}' "$SCRIPT" \
    && grep -qF 'conns: ${CONN_COUNT}/${CONN_MAX_DISPLAY}' "$SCRIPT"; then
  ok "report and summary lines render an unmeasured cap as 'unknown', not a blank"
else
  bad "report/summary lines may print a blank instead of 'unknown' for an unmeasured cap — check CONN_MAX_DISPLAY usage"
fi

# ── ga-2uz59: MEDIUM advisory cooldown/dedup — 85 identical "Dolt health ─────
# ── advisory [MEDIUM]" mails landed in the Mayor's inbox in ~10h30 (no dedup ──
# ── at all), burying 8 distinct real signals (including a P0). Same style as ──
# ── the rest of this file: extract the REAL pure function from the shipped ────
# ── script and drive it with the actual reported numbers, don't hand-copy. ────
# ── ga-wrl5x extends this same section: the ga-2uz59 cooldown was live and ────
# ── STILL got defeated, because (c) compared raw latency_ms/conn_count with a ─
# ── bare "greater than" with no floor — see advisory_should_alert()'s docblock
# ── for the full measured evidence (~4.6-7 advisories/h against a 6h cooldown).
echo "── MEDIUM advisory cooldown/dedup (ga-2uz59, refined by ga-wrl5x) ──"

if grep -qE '^advisory_should_alert\(\)' "$SCRIPT" \
    && grep -qE '^state_read_field\(\)' "$SCRIPT" \
    && grep -qE '^state_write\(\)' "$SCRIPT"; then
  ok "advisory_should_alert()/state_read_field()/state_write() are defined in the shipped script"
else
  bad "one or more of advisory_should_alert()/state_read_field()/state_write() missing from the shipped script"
fi

# ── drift-guard: the MEDIUM send_mayor_mail call site must actually be gated ──
# ── by the new predicate, not just have it sitting unused nearby ──────────────
if grep -qF 'if advisory_should_alert "${PREV_CLASS:-OK}"' "$SCRIPT"; then
  ok "MEDIUM advisory mail is gated by advisory_should_alert()"
else
  bad "MEDIUM advisory mail no longer appears gated by advisory_should_alert() — dedup may have been bypassed"
fi

# ── drift-guard (ga-wrl5x): the caller must actually compute and pass the ─────
# ── per-metric is_warn flags — without this wiring the function would always ──
# ── receive an empty/unset 6th/9th/12th arg and (c) would go permanently deaf.
if grep -qF 'LATENCY_IS_WARN="false"' "$SCRIPT" && grep -qF 'CONN_IS_WARN="false"' "$SCRIPT" \
    && grep -qF 'ORPHAN_IS_WARN="false"' "$SCRIPT" \
    && grep -qF '"$LATENCY_MS" "$PREV_LATENCY_MS" "$LATENCY_IS_WARN"' "$SCRIPT" \
    && grep -qF '"$CONN_COUNT_NUM" "$PREV_CONN_COUNT" "$CONN_IS_WARN"' "$SCRIPT" \
    && grep -qF '"$ORPHAN_COUNT" "$PREV_ORPHAN_COUNT" "$ORPHAN_IS_WARN"' "$SCRIPT"; then
  # ga-29lbag: the connection argument is now CONN_COUNT_NUM (numeric, empty when unmeasured) —
  # CONN_COUNT became the display string ("unknown"), which must never reach the numeric predicate.
  ok "caller computes and passes LATENCY_IS_WARN/CONN_IS_WARN/ORPHAN_IS_WARN into advisory_should_alert()"
else
  bad "caller no longer wires the is_warn flags into advisory_should_alert() — (c) may be permanently deaf or ungated again"
fi

# ── drift-guard (ga-wrl5x): each (c) comparison must be gated on that same ────
# ── metric's OWN is_warn flag — a bare "-gt" with no gate is exactly the class
# ── of regression this bug fixed (healthy-range noise re-arming the mail).
if grep -qE '\[ "\$latency_is_warn" = "true" \] && \[ "\$latency_ms" -gt "\$prev_latency_ms" \]' "$SCRIPT" \
    && grep -qE '\[ "\$conn_is_warn" = "true" \] && \[ "\$conn_count" -gt "\$prev_conn_count" \]' "$SCRIPT" \
    && grep -qE '\[ "\$orphan_is_warn" = "true" \] && \[ "\$orphan_count" -gt "\$prev_orphan_count" \]' "$SCRIPT"; then
  ok "each (c) comparison is gated on that metric's own is_warn flag (ga-wrl5x noise-gate)"
else
  bad "(c) comparisons no longer appear gated on is_warn — the ga-wrl5x healthy-range-noise bug may have regressed"
fi

# ── drift-guard: the CRITICAL/unreachable escalation must NEVER be gated by ───
# ── the cooldown — explicit ga-2uz59 acceptance criterion ("não suprimir ──────
# ── HIGH/CRITICAL por cooldown"). Extract the lines between the unreachable ───
# ── probe and its own exit 0, and confirm advisory_should_alert never ─────────
# ── appears in that span.
UNREACHABLE_SPAN=$(awk '/if ! dolt_sql -q "SELECT active_branch\(\)"/{f=1} f{print} f&&/^[[:space:]]*exit 0[[:space:]]*$/{exit}' "$SCRIPT")
if printf '%s' "$UNREACHABLE_SPAN" | grep 'ESCALATION: Dolt server unreachable' >/dev/null \
    && ! printf '%s' "$UNREACHABLE_SPAN" | grep 'advisory_should_alert' >/dev/null; then
  ok "CRITICAL/unreachable escalation is NOT gated by the new cooldown — always fires, per AC3"
else
  bad "could not confirm the CRITICAL/unreachable escalation is ungated — verify by hand it still always fires"
fi

# ── drift-guard: the full report body must still hit the log every cycle, ─────
# ── mail or not (ga-2uz59 AC2 — "o corte é no MAIL, não na medição") ──────────
if grep -qF "printf '%s\\n' \"\$REPORT_BODY\"" "$SCRIPT" \
    && grep -qF 'if [ -n "$WARNINGS" ]; then' "$SCRIPT"; then
  ok "full report body is unconditionally logged whenever WARNINGS is non-empty, independent of the mail-cooldown decision"
else
  bad "could not confirm the report body is still logged unconditionally — a suppressed alert may now also lose its log record"
fi

# ── real arithmetic, not hand-copied: extract advisory_should_alert()'s ───────
# ── ACTUAL source and drive it with the real reported numbers. ────────────────
ADVISORY_FN_SNIPPET="$(mktemp)"
sed -n '/^advisory_should_alert()/,/^}/p' "$SCRIPT" > "$ADVISORY_FN_SNIPPET"
if [ -s "$ADVISORY_FN_SNIPPET" ]; then
  # shellcheck disable=SC1090
  source "$ADVISORY_FN_SNIPPET"
  if command -v advisory_should_alert >/dev/null 2>&1; then

    # Structural guard: this function must NEVER take backup-staleness as an
    # input. Backup age only ever grows while the condition holds (every
    # 5-min cycle looks "worse" than the last, by construction, until the
    # next daily backup lands) — a worse-than-last-time check on that one
    # field would defeat the cooldown for the EXACT condition that produced
    # this bug's 85 duplicate mails. Guards against a well-intentioned future
    # "fix" silently reintroducing the monotonic-creep trap.
    if grep -qi 'backup' "$ADVISORY_FN_SNIPPET"; then
      bad "advisory_should_alert() now references backup-staleness — this would defeat the cooldown for a persistently stale backup (backup age is monotonic while stale, so 'worse than last time' is true on every cycle)"
    else
      ok "advisory_should_alert() does not take backup-staleness as a worsening signal (monotonic-creep trap avoided)"
    fi

    # Falsifying check: the EXACT reported bug — same condition, 5 minutes
    # (300s) apart, values unchanged — must now be SUPPRESSED, not re-mailed.
    # (all three is_warn flags false: 84ms/42conns/0orphans are healthy)
    if advisory_should_alert "MEDIUM" 300 21600 84 84 false 42 42 false 0 0 false; then
      bad "same MEDIUM condition 300s later with unchanged values STILL alerts — the ga-2uz59 duplicate-mail bug is not fixed"
    else
      ok "same MEDIUM condition 300s later with unchanged values is suppressed — the ga-2uz59 duplicate-mail bug is fixed"
    fi

    # Sanity: a FRESH occurrence (prev_class=OK, i.e. no prior state or a
    # recovered condition) must still alert immediately — confirms this
    # isn't a vacuous "always suppress" comparison.
    if advisory_should_alert "OK" 999999999 21600 84 -1 false 42 -1 false 0 -1 false; then
      ok "sanity: a fresh OK->MEDIUM transition still alerts immediately (not a vacuous always-suppress)"
    else
      bad "sanity check failed: a fresh OK->MEDIUM transition does not alert — the predicate is vacuously always-false"
    fi

    # AC1c: cooldown expiry must still re-alert on a persistently unchanged
    # condition (the exact stale-backup shape, where none of latency/conn/
    # orphan are ever in warn state) — otherwise this goes deaf and the
    # Mayor never hears about a stale backup again after the first mail.
    if advisory_should_alert "MEDIUM" 21600 21600 84 84 false 42 42 false 0 0 false; then
      ok "cooldown fully elapsed (21600s) re-alerts even with unchanged, never-warn values — a persistent condition is not silenced forever"
    else
      bad "cooldown fully elapsed does NOT re-alert — fix over-corrected into permanent silence for a persistent condition"
    fi
    if advisory_should_alert "MEDIUM" 21599 21600 84 84 false 42 42 false 0 0 false; then
      bad "1s under cooldown (21599s) still alerts — cooldown boundary is off by one"
    else
      ok "1s under cooldown (21599s) correctly suppresses"
    fi

    # ── ga-wrl5x falsifying check: the EXACT reported noisy sequences (both ────
    # ── independent samples) must now be SUPPRESSED — every pair below is a ────
    # ── real consecutive reading from the bug report, and every one sits ───────
    # ── comfortably under its own warn threshold (latency < 5000ms default; ────
    # ── conns < ~204 of a real 256 cap), so latency_is_warn/conn_is_warn are ───
    # ── false for all of them, exactly as the live caller would compute.
    echo "  ── ga-wrl5x: healthy-range noise no longer defeats the cooldown ──"
    NOISE_PAIRS="123:1387 1387:109 109:157 157:1649 1649:1443 1443:176 176:461 461:1491 1491:117 117:273 273:125 125:204 461:464 464:233 233:125 125:143 143:257 257:586"
    NOISE_FAIL=0
    for pair in $NOISE_PAIRS; do
      prev_ms="${pair%%:*}"; now_ms_val="${pair##*:}"
      if advisory_should_alert "MEDIUM" 300 21600 "$now_ms_val" "$prev_ms" false 42 42 false 0 0 false; then
        bad "reported healthy-range latency pair (${prev_ms}ms->${now_ms_val}ms) STILL alerts — the ga-wrl5x noise bug is not fixed"
        NOISE_FAIL=1
      fi
    done
    if [ "$NOISE_FAIL" -eq 0 ]; then
      ok "all $(printf '%s\n' "$NOISE_PAIRS" | wc -w | tr -d ' ') reported healthy-range latency pairs are suppressed — the ga-wrl5x noise bug is fixed"
    fi
    # Same shape for the second sample's connection-count noise (10-35 against
    # a real 256-connection cap, never near the 204 warn-at).
    CONN_NOISE_FAIL=0
    for pair in "23:24" "24:28" "28:33" "21:23"; do
      prev_c="${pair%%:*}"; now_c="${pair##*:}"
      if advisory_should_alert "MEDIUM" 300 21600 84 84 false "$now_c" "$prev_c" false 0 0 false; then
        bad "reported healthy-range connection pair (${prev_c}->${now_c}) STILL alerts — the ga-wrl5x noise bug is not fixed"
        CONN_NOISE_FAIL=1
      fi
    done
    [ "$CONN_NOISE_FAIL" -eq 0 ] && ok "reported healthy-range connection-count pairs are suppressed — the ga-wrl5x noise bug is fixed"

    # Sanity: the SAME noisy pair, with is_warn forced true (simulating the
    # OLD ungated "greater than" check this bug removed), DOES alert — proves
    # the reproduction above is real and the is_warn gate is what suppresses
    # it, not some unrelated change.
    if advisory_should_alert "MEDIUM" 300 21600 1387 123 true 42 42 false 0 0 false; then
      ok "sanity: the same noisy pair (123ms->1387ms) DOES alert when is_warn is forced true — confirms this reproduces the real ga-wrl5x bug (the gate, not the arithmetic, is what changed)"
    else
      bad "sanity check failed: 123ms->1387ms with is_warn=true does not alert — the reproduction itself is wrong"
    fi

    # ── genuine escalation must still bypass cooldown, even mid-incident ───────
    # AC1b (revised by ga-wrl5x): a metric that actually CROSSES INTO its own
    # warn territory (not just a raw increase) must still alert immediately.
    # 6000ms exceeds the 5000ms default LATENCY_WARN_MS threshold.
    if advisory_should_alert "MEDIUM" 300 21600 6000 84 true 42 42 false 0 0 false; then
      ok "latency escalating from healthy (84ms) into real warn territory (6000ms >= 5000ms threshold) still alerts immediately within cooldown"
    else
      bad "latency escalating into real warn territory does NOT alert — a genuine escalation would be silenced"
    fi
    # The ORIGINAL ga-2uz59 fixture (161ms->738ms) is real production data
    # showing this is NOT a genuine escalation (738ms never nears the 5000ms
    # threshold) — it must no longer bypass cooldown. This documents the
    # intentional behavior change from the original ga-2uz59 test.
    if advisory_should_alert "MEDIUM" 300 21600 738 161 false 42 42 false 0 0 false; then
      bad "latency worsening within healthy range (161ms->738ms) still bypasses cooldown — the ga-wrl5x noise bug has regressed"
    else
      ok "latency worsening within healthy range (161ms->738ms, the original ga-2uz59 fixture) no longer bypasses cooldown — intentional ga-wrl5x behavior change"
    fi
    # Same shape for connections: a genuine crossing into warn territory
    # (assuming a 256 cap at 80% = warn-at 204) still alerts immediately...
    if advisory_should_alert "MEDIUM" 300 21600 84 84 false 210 180 true 0 0 false; then
      ok "connection count escalating into real warn territory (210 >= warn-at 204) still alerts immediately within cooldown"
    else
      bad "connection count escalating into real warn territory does NOT alert"
    fi
    # ...but the ORIGINAL ga-2uz59 fixture (42->50, both far under any
    # realistic warn-at) no longer bypasses cooldown on its own.
    if advisory_should_alert "MEDIUM" 300 21600 84 84 false 50 42 false 0 0 false; then
      bad "connection-count worsening within healthy range (42->50) still bypasses cooldown — the ga-wrl5x noise bug has regressed"
    else
      ok "connection-count worsening within healthy range (42->50) no longer bypasses cooldown — intentional ga-wrl5x behavior change"
    fi
    # Orphan-count escalation (0->1) is UNCHANGED by ga-wrl5x: an orphan
    # appearing at all (count>0) is inherently its own warn state, same as
    # before this fix.
    if advisory_should_alert "MEDIUM" 300 21600 84 84 false 42 42 false 1 0 true; then
      ok "orphan-count worsening within cooldown still alerts immediately (non-regression: unchanged by ga-wrl5x)"
    else
      bad "orphan-count worsening within cooldown does NOT alert"
    fi

    # Non-regression: values getting BETTER within cooldown must NOT alert —
    # only "worse than last alert" fires (is_warn reflects the CURRENT, now-
    # healthy reading, so this is doubly guarded: neither "worse" nor "warn").
    if advisory_should_alert "MEDIUM" 300 21600 84 738 false 42 42 false 0 0 false; then
      bad "latency IMPROVING since the last alert (738ms->84ms) still re-alerts — only worsening should bypass cooldown"
    else
      ok "latency improving since the last alert correctly stays suppressed within cooldown"
    fi
  else
    bad "advisory_should_alert() extracted but not callable after sourcing — extraction produced invalid bash"
  fi
else
  bad "could not extract advisory_should_alert() source from $SCRIPT — sed range matched nothing"
fi
rm -f "$ADVISORY_FN_SNIPPET"

# ── real I/O, not hand-copied: state_read_field()/state_write() touch only ────
# ── the filesystem + jq (no GC_CITY_PATH/live-Dolt dependency), safe to run ───
# ── for real against a throwaway tmp file, same rationale as sourcing ─────────
# ── latency.sh for real above.
STATE_FN_SNIPPET="$(mktemp)"
sed -n '/^state_read_field()/,/^}/p' "$SCRIPT" > "$STATE_FN_SNIPPET"
sed -n '/^state_write()/,/^}/p' "$SCRIPT" >> "$STATE_FN_SNIPPET"
if [ -s "$STATE_FN_SNIPPET" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FN_SNIPPET"
  if command -v state_read_field >/dev/null 2>&1 && command -v state_write >/dev/null 2>&1; then
    STATE_TMPDIR="$(mktemp -d)"
    STATE_TMPFILE="$STATE_TMPDIR/mol-dog-doctor.state.json"

    if [ -z "$(state_read_field "$STATE_TMPFILE" class)" ]; then
      ok "state_read_field() on a non-existent state file returns empty, not an error"
    else
      bad "state_read_field() on a non-existent state file returned a non-empty value"
    fi

    state_write "$STATE_TMPFILE" "MEDIUM" 1788234056 84 42 0
    RT_CLASS=$(state_read_field "$STATE_TMPFILE" class)
    RT_ALERT_AT=$(state_read_field "$STATE_TMPFILE" alert_at)
    RT_LATENCY=$(state_read_field "$STATE_TMPFILE" latency_ms)
    if [ "$RT_CLASS" = "MEDIUM" ] && [ "$RT_ALERT_AT" = "1788234056" ] && [ "$RT_LATENCY" = "84" ]; then
      ok "state_write()/state_read_field() round-trip preserves class/alert_at/latency_ms exactly"
    else
      bad "state round-trip mismatch: class='$RT_CLASS' alert_at='$RT_ALERT_AT' latency_ms='$RT_LATENCY' (expected MEDIUM/1788234056/84)"
    fi

    # AC1a: a recovered (OK) cycle must clear the class so a future MEDIUM
    # occurrence is treated as a fresh transition, not gated by a stale
    # cooldown from an already-resolved incident.
    state_write "$STATE_TMPFILE" "OK" "" "" "" ""
    RT_CLASS2=$(state_read_field "$STATE_TMPFILE" class)
    if [ "$RT_CLASS2" = "OK" ]; then
      ok "a recovered cycle correctly resets state class to OK"
    else
      bad "recovered cycle did not reset state class to OK (got '$RT_CLASS2') — a future re-occurrence would inherit a stale cooldown instead of alerting immediately"
    fi

    rm -rf "$STATE_TMPDIR"
  else
    bad "state_read_field()/state_write() extracted but not callable after sourcing"
  fi
else
  bad "could not extract state_read_field()/state_write() source from $SCRIPT"
fi
rm -f "$STATE_FN_SNIPPET"

# ── ga-29lbag: the chronic `gc: order exec mol-dog-doctor failed: exit status 124` ──
# ── (48 runs in 6 days). Reproduced live 30/09: NOT the engine's 300s timeout — the ──
# ── script died by itself, at ~176s, because db_last_commit_epoch()'s bounded hq    ──
# ── query timed out (10s, run_bounded exit 124) and `set -e` + `pipefail` turned    ──
# ── that into the exit code of the whole probe. Plus ~103s of per-file forks in the ──
# ── backup-mtime scan. Run against the pre-fix script: the timeout/ORDER BY/stat    ──
# ── count/mtime/budget/unmeasured checks FAIL there; the normal reply and           ──
# ── no-artifact checks are regression guards and pass on both.                      ──
echo "── probe survives a timed-out step and finishes in time (ga-29lbag) ──"

GA29_TMP="$(mktemp -d)"
GA29_LCE_SNIP="$GA29_TMP/lce.sh"
sed -n '/^db_last_commit_epoch()/,/^}/p' "$SCRIPT" > "$GA29_LCE_SNIP"

# Run db_last_commit_epoch() in a CHILD bash under the script's own `set -euo pipefail`, called the
# way the script calls it (a plain `VAR=$(...)` assignment) — that is the shape the bug killed.
# $1 = body of the dolt_sql stub. Prints the child's stdout then "rc=<n>".
ga29_lce_child() {
  local child="$GA29_TMP/child.$RANDOM.sh"
  cat > "$child" <<CHILD
set -euo pipefail
dolt_sql() { $1; }
source "$GA29_LCE_SNIP"
DB_LAST_COMMIT_EPOCH=\$(db_last_commit_epoch hq)
echo "value=[\$DB_LAST_COMMIT_EPOCH]"
CHILD
  bash "$child" 2>/dev/null
  echo "rc=$?"
  rm -f "$child"
}

if [ -s "$GA29_LCE_SNIP" ]; then
  GA29_OUT=$(ga29_lce_child 'return 124')
  if [ "$GA29_OUT" = "$(printf 'value=[]\nrc=0')" ]; then
    ok "a timed-out dolt_sql (exit 124) makes db_last_commit_epoch() yield EMPTY and the caller survives set -euo pipefail — the old body killed the whole probe with that 124"
  else
    bad "db_last_commit_epoch() under set -euo pipefail with a timed-out dolt_sql gave: $(printf '%s' "$GA29_OUT" | tr '\n' ' ') — expected 'value=[] rc=0' (the chronic exit-124 bug)"
  fi

  GA29_OUT=$(ga29_lce_child "printf 'CAST(TIMESTAMPDIFF(SECOND, ...) AS SIGNED)\n'")
  if [ "$GA29_OUT" = "$(printf 'value=[]\nrc=0')" ]; then
    ok "a header-only / non-numeric reply (query returned no row) is reported as unmeasured (empty), never passed on as a number"
  else
    bad "non-numeric dolt_sql output was not normalised to empty: $(printf '%s' "$GA29_OUT" | tr '\n' ' ')"
  fi

  GA29_SQL_CAPTURE="$GA29_TMP/sql.captured"
  GA29_OUT=$(ga29_lce_child "printf '%s\n' \"\$*\" > '$GA29_SQL_CAPTURE'; printf 'hdr\n1790000000\n'")
  if [ "$GA29_OUT" = "$(printf 'value=[1790000000]\nrc=0')" ]; then
    ok "a normal reply (header + epoch) still comes through as the epoch"
  else
    bad "a normal reply was not passed through: $(printf '%s' "$GA29_OUT" | tr '\n' ' ')"
  fi

  # The query actually SENT: no full-history sort (ORDER BY is what made hq's query run >30s and
  # get aborted by the server), no dependence on dolt_log's row order (a bare `LIMIT 1` there is not
  # an SQL guarantee, and an older commit coming back first would SUPPRESS a real stale-backup
  # alarm), and the ga-gh8mb timezone-agnostic form is kept. The answer is MAX() over dolt_branches.
  if [ -s "$GA29_SQL_CAPTURE" ] && ! grep -qi 'ORDER BY' "$GA29_SQL_CAPTURE" \
      && ! grep -qi 'dolt_log' "$GA29_SQL_CAPTURE" \
      && grep -qF 'MAX(latest_commit_date)' "$GA29_SQL_CAPTURE" \
      && grep -qF '.dolt_branches' "$GA29_SQL_CAPTURE" \
      && grep -qF "TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', MAX(latest_commit_date))" "$GA29_SQL_CAPTURE"; then
    ok "the commit-recency query reads MAX(latest_commit_date) from dolt_branches: no ORDER BY, no dependence on dolt_log's row order, TIMESTAMPDIFF kept"
  else
    bad "the commit-recency query sent is wrong (ORDER BY or dolt_log back, MAX(latest_commit_date) over dolt_branches or TIMESTAMPDIFF gone): $(cat "$GA29_SQL_CAPTURE" 2>/dev/null)"
  fi
else
  bad "could not extract db_last_commit_epoch() from $SCRIPT"
fi

# newest_backup_mtime_for_db(): ONE stat for the whole match set, not one or two forks per file
# (hq's backup dir holds ~250 files; a fork costs 0.1-0.2s at this city's load => 83s for hq alone).
GA29_MT_SNIP="$GA29_TMP/mt.sh"
sed -n '/^backup_path_matches_db()/,/^}/p;/^newest_backup_mtime_for_db()/,/^}/p' "$SCRIPT" > "$GA29_MT_SNIP"
GA29_ART="$GA29_TMP/art"
mkdir -p "$GA29_ART/hq" "$GA29_ART/other"
for i in $(seq 1 60); do : > "$GA29_ART/hq/f$i"; touch -t 202501010101 "$GA29_ART/hq/f$i"; done
: > "$GA29_ART/hq/newest"; touch -t 202606150000 "$GA29_ART/hq/newest"
: > "$GA29_ART/other/later"; touch -t 202609010000 "$GA29_ART/other/later"   # newer, but another db's — must be ignored
GA29_EXPECT=$(stat -c %Y "$GA29_ART/hq/newest" 2>/dev/null || stat -f %m "$GA29_ART/hq/newest" 2>/dev/null)
mkdir -p "$GA29_TMP/bin"
GA29_REAL_STAT="$(command -v stat)"
cat > "$GA29_TMP/bin/stat" <<SHIM
#!/bin/sh
echo call >> "$GA29_TMP/stat.calls"
exec "$GA29_REAL_STAT" "\$@"
SHIM
chmod +x "$GA29_TMP/bin/stat"

if [ -s "$GA29_MT_SNIP" ] && [ -n "$GA29_EXPECT" ]; then
  : > "$GA29_TMP/stat.calls"
  # Under the script's own `set -euo pipefail`, as production runs it (gate fix: it used to run without).
  GA29_GOT=$(PATH="$GA29_TMP/bin:$PATH" BACKUP_ARTIFACT_DIR="$GA29_ART" bash -c "set -euo pipefail; source '$GA29_MT_SNIP'; newest_backup_mtime_for_db hq" 2>/dev/null)
  GA29_CALLS=$(wc -l < "$GA29_TMP/stat.calls" | tr -d ' ')
  if [ "$GA29_GOT" = "$GA29_EXPECT" ]; then
    ok "newest_backup_mtime_for_db hq returns the newest hq artifact's mtime ($GA29_EXPECT) and ignores another db's newer file"
  else
    bad "newest_backup_mtime_for_db hq returned '$GA29_GOT', expected '$GA29_EXPECT'"
  fi
  # 1..2, not just <=2 (gate fix): "0 calls" is a function that never reached stat at all, and a bound
  # that only checks the upper end lets a broken/absent scan pass this check vacuously.
  if [ "${GA29_CALLS:-999}" -ge 1 ] && [ "${GA29_CALLS:-999}" -le 2 ]; then
    ok "61 matching files cost $GA29_CALLS stat invocation(s) (1-2: GNU form, then BSD fallback) — not one or two per file"
  else
    bad "61 matching files cost $GA29_CALLS stat invocations, expected 1-2 (0 = the scan never ran; many = the per-file fork pattern, 83s on hq at load ~40, is back)"
  fi
  : > "$GA29_TMP/stat.calls"
  GA29_NONE=$(PATH="$GA29_TMP/bin:$PATH" BACKUP_ARTIFACT_DIR="$GA29_ART" bash -c "set -euo pipefail; source '$GA29_MT_SNIP'; newest_backup_mtime_for_db nosuchdb" 2>/dev/null)
  if [ "$GA29_NONE" = "0" ] && [ ! -s "$GA29_TMP/stat.calls" ]; then
    ok "a db with no artifacts reports 0 (the caller's 'backup missing') without calling stat"
  else
    bad "a db with no artifacts returned '$GA29_NONE' (stat calls: $(wc -l < "$GA29_TMP/stat.calls" | tr -d ' ')), expected 0 and none"
  fi
else
  bad "could not build the newest_backup_mtime_for_db fixture/snippet (snippet size: $(wc -c < "$GA29_MT_SNIP" 2>/dev/null), expected mtime: '${GA29_EXPECT:-}')"
fi

# The script budgets itself below the order timeout (the comment in mol-dog-doctor.toml promises this).
GA29_TIMEOUT=$(sed -n 's/^timeout = "\([0-9][0-9]*\)s".*/\1/p' "$ORDER_TOML" 2>/dev/null)
GA29_BUDGET=$(sed -n 's/^DOCTOR_BUDGET_S="${GC_DOCTOR_BUDGET_S:-\([0-9][0-9]*\)}".*/\1/p' "$SCRIPT")
if [ -n "$GA29_TIMEOUT" ] && [ -n "$GA29_BUDGET" ] && [ $((GA29_BUDGET + 60)) -le "$GA29_TIMEOUT" ]; then
  ok "the order declares timeout=${GA29_TIMEOUT}s and the script's own budget (${GA29_BUDGET}s) leaves >=60s of tail inside it"
else
  bad "order timeout ('${GA29_TIMEOUT:-undeclared}') / script budget ('${GA29_BUDGET:-missing}') violate budget+60 <= timeout — a run could be killed by the engine before it reports"
fi

# Step bounds and three-state reporting (static drift-guards; the main body needs a live Dolt).
if [ "$(grep -cF 'if [ "$SECONDS" -ge "$DOCTOR_BUDGET_S" ]; then' "$SCRIPT")" -ge 2 ]; then
  ok "both per-database loops (backup remotes, backup freshness) check the probe budget before starting a database"
else
  bad "a per-database loop no longer checks \$SECONDS against DOCTOR_BUDGET_S — it can run past the order timeout again"
fi
if grep -qF 'run_bounded "$STEP_TIMEOUT_S" dolt backup' "$SCRIPT" && grep -qF 'run_bounded "$STEP_TIMEOUT_S" du -sh' "$SCRIPT"; then
  ok "the dolt backup CLI and du are bounded (they used to run unbounded, once per database)"
else
  bad "dolt backup / du is no longer bounded by STEP_TIMEOUT_S"
fi
if grep -qF 'CONN_COUNT="${CONN_COUNT_NUM:-unknown}"' "$SCRIPT" && ! grep -E 'CONN_COUNT.*echo "0"' "$SCRIPT" >/dev/null; then
  ok "an unmeasured connection count is displayed as 'unknown', not folded into a measured 0"
else
  bad "CONN_COUNT can again report a failed query as 0 connections"
fi
if grep -qF '"$CONN_COUNT_NUM" "$PREV_CONN_COUNT" "$CONN_IS_WARN"' "$SCRIPT" \
    && grep -qF '"$LATENCY_MS" "$CONN_COUNT_NUM" "$ORPHAN_COUNT"' "$SCRIPT"; then
  ok "the cooldown predicate and state file receive the numeric count (empty when unmeasured), never the display string"
else
  bad "advisory_should_alert/state_write no longer receive CONN_COUNT_NUM — 'unknown' would reach jq --argjson"
fi

GA29_AU_SNIP="$GA29_TMP/au.sh"
sed -n '/^append_unmeasured()/,/^}/p' "$SCRIPT" > "$GA29_AU_SNIP"
GA29_AU_OUT=$(bash -c "UNMEASURED_ITEMS=''; source '$GA29_AU_SNIP'; append_unmeasured 'database list'; append_unmeasured 'backup remotes of hq'; printf '%s' \"\$UNMEASURED_ITEMS\"" 2>/dev/null)
if [ "$GA29_AU_OUT" = "database list, backup remotes of hq" ]; then
  ok "append_unmeasured() accumulates the not-measured items in order"
else
  bad "append_unmeasured() produced '$GA29_AU_OUT'"
fi
if grep -qF 'Not measured this run: ${UNMEASURED_ITEMS}' "$SCRIPT" && grep -qF '[not measured: $UNMEASURED_ITEMS]' "$SCRIPT"; then
  ok "unmeasured items reach both the report body and the log/DOG_DONE summary"
else
  bad "unmeasured items no longer reach the report body and/or the summary line"
fi
# ── ga-29lbag gate fix (attempt 1): the THIRD STATE. "Nothing to warn about" is only a recovery ──
# ── when every step that could warn was actually measured; and an unmeasured number must not ────
# ── be persisted as a measured 0. Reviewer's repro, on the real script: healthy cycle -> 1 mail, ──
# ── a cycle whose SHOW DATABASES failed reset the cooldown state to OK, the next healthy cycle ───
# ── mailed the Mayor AGAIN seconds later (the ga-2uz59/ga-wrl5x duplicate-mail class).         ───
echo "── an unmeasured cycle is not a recovery; an unmeasured value is not a measured 0 (ga-29lbag gate fix) ──"

# Pure predicate first: only a fully measured cycle (empty list) may clear the cooldown state.
GA29_RC_SNIP="$GA29_TMP/rc.sh"
sed -n '/^recovery_is_confirmed()/,/^}/p' "$SCRIPT" > "$GA29_RC_SNIP"
if [ -s "$GA29_RC_SNIP" ]; then
  if bash -c "source '$GA29_RC_SNIP'; recovery_is_confirmed ''" 2>/dev/null \
      && ! bash -c "source '$GA29_RC_SNIP'; recovery_is_confirmed 'database list (backup freshness skipped)'" 2>/dev/null \
      && ! bash -c "source '$GA29_RC_SNIP'; recovery_is_confirmed 'a, b'" 2>/dev/null; then
    ok "recovery_is_confirmed(): true only for an empty not-measured list"
  else
    bad "recovery_is_confirmed() gave the wrong answer for an empty / non-empty not-measured list"
  fi
else
  bad "could not extract recovery_is_confirmed() from $SCRIPT"
fi

# state_write(): an unmeasured (empty) measurement is stored as null and reads back empty; a measured
# 0 stays 0. Before the fix ${x:-0} stored a fake measured 0 for both, and the next cycle compared
# against a value nobody ever saw.
GA29_SW_SNIP="$GA29_TMP/sw.sh"
sed -n '/^state_read_field()/,/^}/p;/^state_write()/,/^}/p' "$SCRIPT" > "$GA29_SW_SNIP"
GA29_SW_OUT=$(bash -c "
  set -euo pipefail
  source '$GA29_SW_SNIP'
  f='$GA29_TMP/sw.state.json'
  state_write \"\$f\" MEDIUM 1790000000 84 '' ''
  echo \"unmeasured conn=[\$(state_read_field \"\$f\" conn_count)] orphan=[\$(state_read_field \"\$f\" orphan_count)] json=\$(jq -c '[.conn_count,.orphan_count]' \"\$f\")\"
  state_write \"\$f\" MEDIUM 1790000000 84 0 0
  echo \"measured-zero conn=[\$(state_read_field \"\$f\" conn_count)] orphan=[\$(state_read_field \"\$f\" orphan_count)] json=\$(jq -c '[.conn_count,.orphan_count]' \"\$f\")\"
" 2>&1)
if [ "$GA29_SW_OUT" = "$(printf 'unmeasured conn=[] orphan=[] json=[null,null]\nmeasured-zero conn=[0] orphan=[0] json=[0,0]')" ]; then
  ok "state_write() stores an unmeasured connection/orphan count as null (reads back empty) and keeps a measured 0 as 0"
else
  bad "state_write() null-vs-zero handling wrong: $(printf '%s' "$GA29_SW_OUT" | tr '\n' ' ')"
fi

# ── End-to-end on the REAL script (run as a child, never sourced), with stub dolt/gc first on PATH ──
# ── and a stub `gc mail send` that records instead of mailing. runtime.sh/latency.sh are replaced ──
# ── by a tiny shim: the real runtime.sh costs 6-10s of python start-ups per run at this city's ───
# ── load, and this needs ~20 runs; the real bootstrap is covered by the checks near the top of ───
# ── this file. Everything else — dolt_sql(), the probes, the state machine, the report — is the ──
# ── shipped code. Validated by running this whole file against the revision the gate rejected ──
# ── (34ce5307): 13 checks FAIL there — the state reset to OK after a blind cycle, the 2nd mail, ──
# ── 0/0 persisted for unknown counts, the unnamed blind spots — and all pass on the fixed script; ──
# ── the control and fresh-backup checks are regression guards and pass on both.                  ──
GA29_DOCTOR="$SCRIPT"
GA29_E2E="$GA29_TMP/e2e"
mkdir -p "$GA29_E2E/bin" "$GA29_E2E/packs/dolt/assets/scripts"
cat > "$GA29_E2E/packs/dolt/assets/scripts/runtime.sh" <<'SHIM'
DOLT_DATA_DIR="${GC_DOLT_DATA_DIR}"
GC_DOLT_PORT=39999
run_bounded() { shift; "$@"; }
SHIM
cat > "$GA29_E2E/packs/dolt/assets/scripts/latency.sh" <<'SHIM'
now_ms() { printf '%s\n' "$(( $(date +%s) * 1000 ))"; }
latency_should_warn() { [ "$1" -ge "$2" ]; }
SHIM
cat > "$GA29_E2E/bin/dolt" <<'STUB'
#!/bin/sh
# stub dolt: `dolt backup` (CLI, run inside a db dir) and `dolt --host .. sql [-r csv] -q <query>`.
# STUB_*_FAIL=1 makes that one step exit 124, exactly what run_bounded returns on a timeout.
if [ "$1" = "backup" ]; then
  [ "${STUB_BACKUP_FAIL:-0}" = 1 ] && exit 124
  echo "$(basename "$PWD")-backup file:///stub"; exit 0
fi
q=""; for a in "$@"; do q="$a"; done
case "$q" in
  *active_branch*) printf 'active_branch()\nmain\n' ;;
  *max_connections*) [ "${STUB_MAXCONN_FAIL:-0}" = 1 ] && exit 124; printf 'x\n256\n' ;;
  *information_schema.PROCESSLIST*) [ "${STUB_COUNT_FAIL:-0}" = 1 ] && exit 124; printf 'c\n7\n' ;;
  *"SHOW DATABASES"*) [ "${STUB_DBLIST_FAIL:-0}" = 1 ] && exit 124; printf 'Database\nhq\nlexbh\ninformation_schema\n' ;;
  *dolt_branches*|*dolt_log*) [ "${STUB_COMMIT_FAIL:-0}" = 1 ] && exit 124; printf 'x\n%s\n' "${STUB_COMMIT_EPOCH:-0}" ;;
  *) exit 0 ;;
esac
STUB
cat > "$GA29_E2E/bin/gc" <<'STUB'
#!/bin/sh
# stub gc: mail is recorded, never sent; canned replies for the few other calls the doctor makes.
case "$1 $2" in
  "mail send") { printf 'MAIL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$STUB_MAILLOG"; exit 0 ;;
  "agent list") echo '{"agents":[{"qualified_name":"gastown.deacon","suspended":true}]}'; exit 0 ;;
esac
if [ "$1" = "dolt-cleanup" ]; then
  [ "${STUB_CLEANUP_FAIL:-0}" = 1 ] && { echo '{"ok":false}'; exit 1; }
  echo '{"ok":true,"summary":{"errors_total":0},"dropped":{"count":0}}'; exit 0
fi
exit 0
STUB
cat > "$GA29_E2E/bin/aws" <<'STUB'
#!/bin/sh
# stub aws (ga-gqllbc): serves ONE object — s3://<bucket>/_meta/latest.json — from $STUB_FP_FILE.
# STUB_AWS_FAIL=1 = the call itself fails (no network, expired credentials...). Anything else: exit 1.
[ "${STUB_AWS_FAIL:-0}" = 1 ] && exit 255
if [ "$1 $2" = "s3 cp" ]; then
  case "$3" in s3://*/_meta/latest.json) [ -f "${STUB_FP_FILE:-/nonexistent}" ] || exit 1; cp "$STUB_FP_FILE" "$4"; exit 0 ;; esac
fi
exit 1
STUB
chmod +x "$GA29_E2E/bin/dolt" "$GA29_E2E/bin/gc" "$GA29_E2E/bin/aws"
GA29_ELIB="$HERE/../../../../scripts/dolt-backup-ephemeral-lib.sh"   # the real lib, from this tree

# ga29_new <name> [fresh] — a scratch city with two dbs whose backups are 2025 old (stale) unless "fresh".
ga29_new() {
  local d="$GA29_E2E/s-$1" db
  mkdir -p "$d/city" "$d/home" "$d/state"
  for db in hq lexbh; do
    mkdir -p "$d/data/$db/.dolt" "$d/art/$db"
    : > "$d/art/$db/backup.bin"
    [ "${2:-}" = "fresh" ] || touch -t 202501010101 "$d/art/$db/backup.bin"
  done
  printf '%s\n' "$d"
}
ga29_fresh()  { touch "$1"/art/*/backup.bin; }
# ga29_cycle <scenario-dir> [VAR=value ...] — one run of the doctor; output in <dir>/last.out
ga29_cycle() {
  local d="$1"; shift
  env -i PATH="$GA29_E2E/bin:$PATH" HOME="$d/home" GC_CITY_PATH="$d/city" \
      GC_SYSTEM_PACKS_DIR="$GA29_E2E/packs" GC_DOLT_DATA_DIR="$d/data" \
      GC_DOCTOR_STATE_DIR="$d/state" GC_BACKUP_ARTIFACT_DIR="$d/art" \
      DOLT_BACKUP_EPHEMERAL_LIB="$GA29_ELIB" DOLT_BACKUP_EPHEMERAL_DBS="" DOLT_BACKUP_EPHEMERAL_CONF="$d/no-such-eph.env" \
      STUB_MAILLOG="$d/mail.log" STUB_COMMIT_EPOCH="$(date +%s)" "$@" \
      bash "$GA29_DOCTOR" > "$d/last.out" 2>&1
  echo $? > "$d/last.rc"
}
ga29_mails() { local n; n=$(grep -c '^MAIL:' "$1/mail.log" 2>/dev/null); echo "${n:-0}"; }
ga29_class() { jq -r '.class // "?"' "$1/state/mol-dog-doctor.state.json" 2>/dev/null || echo "?"; }
ga29_field() { jq -r --arg f "$2" 'if has($f) then (.[$f] | if . == null then "null" else tostring end) else "absent" end' "$1/state/mol-dog-doctor.state.json" 2>/dev/null || echo "?"; }

# Each scenario is a function that prints "ok: <msg>" / "bad: <msg>" lines. They are independent (own
# scratch city), so they run in PARALLEL: a doctor cycle forks dozens of processes and a fork costs
# 0.1-0.2s at this city's load, so ~15 cycles back to back would be minutes. The MEDIUM starting
# state is written with the script's OWN state_write (not hand-built JSON) instead of spending a
# whole cycle to reach it.
sc_ok()  { echo "ok: $1"; }
sc_bad() { echo "bad: $(printf '%s' "$1" | tr '\n' ' ')"; }
ga29_seed_medium() {   # $1 scenario dir — as if a MEDIUM advisory was mailed just now
  bash -c "source '$GA29_SW_SNIP'; state_write '$1/state/mol-dog-doctor.state.json' MEDIUM \"\$(date +%s)\" 0 7 0"
}

# Reviewer's repro. State: MEDIUM was mailed a moment ago and the backup is still stale. A cycle whose
# SHOW DATABASES failed must NOT reset that state, so the next healthy cycle must not mail again.
sc_repro() {
  local d; d=$(ga29_new repro); ga29_seed_medium "$d"
  ga29_cycle "$d" STUB_DBLIST_FAIL=1
  local rc c2 m2 log2; rc=$(cat "$d/last.rc"); c2=$(ga29_class "$d"); m2=$(ga29_mails "$d"); log2=$(cat "$d/last.out")
  ga29_cycle "$d"; local m3; m3=$(ga29_mails "$d")
  if [ "$rc" = "0" ] && [ "$c2" = "MEDIUM" ] && [ "$m2" = "0" ] && [ "$m3" = "0" ]; then
    sc_ok "stale backup: a cycle whose SHOW DATABASES failed leaves the cooldown state at MEDIUM, and the next healthy cycle does NOT mail the Mayor a second time"
  else
    sc_bad "unmeasured cycle reset the alert state or re-mailed: failing cycle rc=$rc state=$c2 mails=$m2, next healthy cycle mails=$m3 (expected rc=0, MEDIUM, 0, 0)"
  fi
  case "$log2" in
    *"recovery is not confirmed"*) sc_ok "the skipped state reset is logged ('recovery is not confirmed — state left as-is'), not silent" ;;
    *) sc_bad "an unmeasured cycle left the state alone but did not say so: $log2" ;;
  esac
}

# Control for the above: with nothing failing, repeated cycles on a stale backup mail exactly once
# (so a 2nd mail in the repro could only come from the state having been reset). Also the measured
# side of the snapshot: real counts persist as numbers.
sc_control() {
  local d; d=$(ga29_new control)
  ga29_cycle "$d"; ga29_cycle "$d"
  if [ "$(ga29_mails "$d")" = "1" ] && [ "$(ga29_class "$d")" = "MEDIUM" ]; then
    sc_ok "control: two healthy cycles on a stale backup mail the Mayor once (the cooldown works)"
  else
    sc_bad "control run mailed $(ga29_mails "$d") time(s) / class $(ga29_class "$d") — expected 1 / MEDIUM"
  fi
  local snap; snap="$(ga29_field "$d" conn_count)/$(ga29_field "$d" orphan_count)"
  if [ "$snap" = "7/0" ]; then
    sc_ok "state file: measured connections/orphans persist as the numbers 7/0"
  else
    sc_bad "state file: measured connections/orphans persisted as $snap (want 7/0)"
  fi
}

# Every blind spot that can hide a warning. Backup FRESH (the cycle would otherwise look recovered),
# MEDIUM already recorded: a cycle that could not look must keep MEDIUM and name what it missed.
ga29_blind_spot() {   # $1 label, $2 expected "not measured" text, $3 "clear" to also run the recovery cycle, rest: env overrides
  local label="$1" expect="$2" clear="$3"; shift 3
  local d; d=$(ga29_new "blind-$label" fresh); ga29_seed_medium "$d"
  ga29_cycle "$d" "$@"
  local held named=no; held=$(ga29_class "$d"); grep -qF -- "$expect" "$d/last.out" && named=yes
  if [ "$held" = "MEDIUM" ] && [ "$named" = "yes" ] && [ "$(ga29_mails "$d")" = "0" ]; then
    sc_ok "blind spot '$label': the cycle names it ('$expect') and keeps the MEDIUM state"
  else
    sc_bad "blind spot '$label': state after the blind cycle=$held (want MEDIUM), named in report=$named (want yes), mails=$(ga29_mails "$d") (want 0)"
  fi
  if [ "$clear" = "clear" ]; then
    ga29_cycle "$d"
    if [ "$(ga29_class "$d")" = "OK" ]; then
      sc_ok "a fully measured cycle with no warnings still clears MEDIUM to OK (the guard does not make the state sticky forever)"
    else
      sc_bad "a fully measured, warning-free cycle left the state at $(ga29_class "$d") instead of OK"
    fi
  fi
}
sc_blind_dblist()     { ga29_blind_spot dblist     "database list"         clear STUB_DBLIST_FAIL=1; }
sc_blind_backup_cli() { ga29_blind_spot backup-cli "backup remotes of"     no    STUB_BACKUP_FAIL=1; }
sc_blind_budget()     { ga29_blind_spot budget     "probe budget"          no    GC_DOCTOR_BUDGET_S=0; }
sc_blind_conn_count() { ga29_blind_spot conn-count "connection count"      no    STUB_COUNT_FAIL=1; }
sc_blind_conn_limit() { ga29_blind_spot conn-limit "connection limit"      no    STUB_MAXCONN_FAIL=1; }
sc_blind_orphans()    { ga29_blind_spot orphans    "orphan database count" no    STUB_CLEANUP_FAIL=1; }

# The persisted snapshot: an unmeasured count is null, never a made-up 0, and the mail says 'unknown'.
sc_snapshot() {
  local d; d=$(ga29_new snap-unmeasured); ga29_cycle "$d" STUB_COUNT_FAIL=1 STUB_CLEANUP_FAIL=1
  local snap; snap="$(ga29_field "$d" conn_count)/$(ga29_field "$d" orphan_count)"
  if [ "$snap" = "null/null" ] && grep -qF 'Connections: unknown/256' "$d/mail.log" && grep -qF 'Orphan DBs: unknown' "$d/mail.log"; then
    sc_ok "state file: a failed COUNT(*) and a failed orphan probe persist as null/null (not 0/0), matching the 'unknown' in the mail"
  else
    sc_bad "unmeasured connection/orphan counts persisted as $snap (want null/null): $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null)"
  fi
}

# db_last_commit_epoch failing (the query this PR is about) is counted, but only when it matters: the
# epoch can only turn a warning into 'no warning', so it is a blind spot exactly when the age-only fallback warned.
sc_commit_stale() {
  local d; d=$(ga29_new lc-stale); ga29_cycle "$d" STUB_COMMIT_FAIL=1
  if grep -qF 'backup is' "$d/mail.log" && grep -qF 'Not measured this run: ' "$d/mail.log" && grep -qF 'last commit of hq' "$d/mail.log"; then
    sc_ok "commit-time query failed + backup old by age alone: the warning is sent AND the report says the commit time was not measured (the alarm may be a false one on an idle db)"
  else
    sc_bad "a failed commit-time query behind an age-only backup warning is not reported as unmeasured: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null)"
  fi
}
sc_commit_fresh() {
  local d; d=$(ga29_new lc-fresh fresh); ga29_seed_medium "$d"; ga29_cycle "$d" STUB_COMMIT_FAIL=1
  if [ "$(ga29_class "$d")" = "OK" ] && ! grep -qF 'last commit of' "$d/last.out"; then
    sc_ok "commit-time query failed but the backup is fresh by age: fully measured (the epoch cannot change that verdict), so the state clears to OK and nothing is listed as unmeasured"
  else
    sc_bad "fresh backup + failed commit-time query: state=$(ga29_class "$d") (want OK), output: $(tr '\n' ' ' < "$d/last.out")"
  fi
}

# ── ga-gqllbc: a db whose local staging is EPHEMERAL has no local artifacts by design. Its freshness
# comes from S3's run fingerprint; "no artifacts" must not read as "backup missing", and "could not
# read S3" must be a blind spot, not a warning and not a clean bill.
ga29_iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
ga29_eph_new() {   # <name> <hq-entry-json> [fresh] — hq has NO local artifacts, lexbh is fresh, S3's fingerprint says <entry>
  local d; d=$(ga29_new "eph-$1" fresh)
  rm -rf "$d/art/hq"
  printf '{"run_utc":"%s","databases":{"hq":%s,"lexbh":{"issues":1}}}' "$(ga29_iso "$(date +%s)")" "$2" > "$d/fp.json"
  printf '%s\n' "$d"
}
sc_eph_fresh() {
  local d; d=$(ga29_eph_new fresh "{\"issues\":5,\"run_utc\":\"$(ga29_iso $(( $(date +%s) - 7200 )))\"}")
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if [ "$(ga29_mails "$d")" = "0" ] && grep -qF 'doctor — server: ok' "$d/last.out" && ! grep -q 'MEDIUM condition\|backup missing\|Not measured' "$d/last.out"; then
    sc_ok "ephemeral hq, no local artifacts, S3 fingerprint says a backup 2h old → NO warning, nothing unmeasured (absence of a local copy is the design, not a missing backup)"
  else sc_bad "fresh S3 backup of an ephemeral db still warned: class=$(ga29_class "$d") mails=$(ga29_mails "$d") out=$(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_stale() {
  local d; d=$(ga29_eph_new stale "{\"issues\":5,\"run_utc\":\"$(ga29_iso $(( $(date +%s) - 180000 )))\"}")
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if grep -qF 'hq backup is 50h old' "$d/mail.log"; then sc_ok "ephemeral hq whose S3 backup is 50h old → the SAME age warning as a local backup would give ('hq backup is 50h old')"
  else sc_bad "stale S3 backup of an ephemeral db did not warn: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null) | $(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_failed_recent() {
  local d; d=$(ga29_eph_new failed-recent "{\"status\":\"failed\",\"reason\":\"disco\",\"last_ok_run_utc\":\"$(ga29_iso $(( $(date +%s) - 36000 )))\",\"last_ok\":{\"issues\":5}}")
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if [ "$(ga29_mails "$d")" = "0" ] && ! grep -q 'backup missing\|backup is' "$d/last.out"; then
    sc_ok "ephemeral hq: last night FAILED but the last good backup is 10h old (inside the 30h limit) → judged by that age, like a local backup — no warning yet"
  else sc_bad "failed-last-night-but-recent-good warned: $(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_failed_old() {
  local d; d=$(ga29_eph_new failed-old "{\"status\":\"failed\",\"reason\":\"disco\",\"last_ok_run_utc\":\"$(ga29_iso $(( $(date +%s) - 259200 )))\",\"last_ok\":{\"issues\":5}}")
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if grep -qF 'hq backup is 72h old' "$d/mail.log"; then sc_ok "ephemeral hq failing for 3 nights (last good 72h ago, the 09-29 shape) → warns with the real age: 'hq backup is 72h old'"
  else sc_bad "hq failed 3 nights and the doctor stayed quiet: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null) | $(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_failed_unknown() {
  local d; d=$(ga29_eph_new failed-unknown '{"status":"failed","reason":"disco","last_ok_run_utc":null,"last_ok":null}')
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if grep -qF 'hq backup FAILED last night and S3 records no last good backup' "$d/mail.log"; then sc_ok "ephemeral hq failed with NO recorded last-good time → warns by name (cannot be judged fresh)"
  else sc_bad "failed-with-unknown-last-good did not warn: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null) | $(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_absent() {
  local d; d=$(ga29_eph_new absent '{"issues":1}'); printf '{"run_utc":"%s","databases":{"lexbh":{"issues":1}}}' "$(ga29_iso "$(date +%s)")" > "$d/fp.json"
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if grep -qF 'hq backup missing (no entry for it in the S3 run fingerprint)' "$d/mail.log"; then sc_ok "ephemeral hq with no entry in S3's fingerprint → 'backup missing (no entry …)' — a real absence is still reported"
  else sc_bad "absent fingerprint entry did not warn: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null) | $(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_unreadable() {   # MEDIUM already recorded; S3 unreadable → a blind spot: named, state kept, no mail
  local d; d=$(ga29_eph_new unreadable '{"issues":1}'); ga29_seed_medium "$d"
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json" STUB_AWS_FAIL=1
  if [ "$(ga29_class "$d")" = "MEDIUM" ] && [ "$(ga29_mails "$d")" = "0" ] && grep -qF 'S3 backup fingerprint of hq' "$d/last.out" && ! grep -q 'hq backup missing' "$d/last.out"; then
    sc_ok "S3 unreadable → hq is a NAMED blind spot ('S3 backup fingerprint of hq'): the MEDIUM state is kept, no mail, and it is NOT reported as 'backup missing' (error ≠ empty)"
  else sc_bad "unreadable S3 fingerprint mishandled: class=$(ga29_class "$d") mails=$(ga29_mails "$d") out=$(tr '\n' ' ' < "$d/last.out")"; fi
}
sc_eph_off() {   # kill switch: the old, louder behaviour — no local artifacts = missing
  local d; d=$(ga29_eph_new off "{\"issues\":5,\"run_utc\":\"$(ga29_iso "$(date +%s)")\"}")
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS="" STUB_FP_FILE="$d/fp.json"
  if grep -qF 'hq backup missing' "$d/mail.log"; then sc_ok "mode off (empty list) → a db with no local artifacts is 'backup missing' again (legacy behaviour; S3 is not consulted)"
  else sc_bad "kill switch did not restore the legacy check: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null)"; fi
}
sc_eph_local_wins() {   # local artifacts exist (first night / a held-back release) → judged by their own mtime, as always
  local d; d=$(ga29_eph_new localwins "{\"issues\":5,\"run_utc\":\"$(ga29_iso "$(date +%s)")\"}")
  mkdir -p "$d/art/hq"; : > "$d/art/hq/backup.bin"; touch -t 202501010101 "$d/art/hq/backup.bin"
  ga29_cycle "$d" DOLT_BACKUP_EPHEMERAL_DBS=hq STUB_FP_FILE="$d/fp.json"
  if grep -qF 'hq backup is' "$d/mail.log"; then sc_ok "an ephemeral db that DOES still have local artifacts is judged by their mtime (S3 is only the fallback for 'no artifacts')"
  else sc_bad "local artifacts were ignored in favour of S3: $(tr '\n' ' ' < "$d/mail.log" 2>/dev/null)"; fi
}

GA29_SCENARIOS="eph_fresh eph_stale eph_failed_recent eph_failed_old eph_failed_unknown eph_absent eph_unreadable eph_off eph_local_wins repro control blind_dblist blind_backup_cli blind_budget blind_conn_count blind_conn_limit blind_orphans snapshot commit_stale commit_fresh"
for GA29_N in $GA29_SCENARIOS; do ( "sc_$GA29_N" > "$GA29_E2E/res.$GA29_N" 2>&1 ) & done
wait
for GA29_N in $GA29_SCENARIOS; do
  if [ ! -s "$GA29_E2E/res.$GA29_N" ]; then bad "e2e scenario '$GA29_N' produced no result"; continue; fi
  while IFS= read -r GA29_LINE; do
    case "$GA29_LINE" in
      "ok: "*)  ok  "${GA29_LINE#ok: }" ;;
      "bad: "*) bad "${GA29_LINE#bad: }" ;;
      *)        bad "e2e scenario '$GA29_N' printed unexpected output: $GA29_LINE" ;;
    esac
  done < "$GA29_E2E/res.$GA29_N"
done

rm -rf "$GA29_TMP"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
