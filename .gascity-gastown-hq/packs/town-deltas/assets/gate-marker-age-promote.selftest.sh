#!/usr/bin/env bash
# gate-marker-age-promote.selftest.sh (ga-tgo7q)
#
# Proves the starvation-bound aging fix: the 2026-06-24 newest-first tiebreak
# (4cae0a2c49, Athos: gate>execute>refine>create, bugs>stories, desempate=mais
# novo) is an EXPLICIT, INTENDED policy — not a regression — and must stay the
# default for markers still within the aging window. But under continuous
# submission it can starve an old healthy marker indefinitely (observed live:
# ga-wisp-7yity6v queued 90+ min while newer healthy markers kept jumping
# ahead — see ga-tgo7q), which also defeats gt-mqkwj's orphan-marker re-queue
# (created_at is immutable, so a starved marker's rank never improves on its
# own). The fix: once a healthy marker's wait exceeds
# GATE_MARKER_AGE_PROMOTE_SECONDS, it is force-promoted ahead of every
# not-yet-aged healthy marker (FIFO among the aged set), giving every marker a
# hard wait bound while leaving Athos's newest-first tiebreak untouched for
# markers still inside the window.
#
# Aging must NOT reach into the rebase-fail tier: a broken marker aging its way
# back to the front would reintroduce the exact ga-q3ig2 outage class (one
# stale-conflict branch travando a fila inteira). Tier order stays fixed:
#   1. healthy + aged     (FIFO, oldest first)
#   2. healthy + not aged (newest first — Athos's tiebreak, unchanged)
#   3. rebase-fail        (newest first, unchanged — never promoted by age)
#
# Strategy: extract the LIVE marker-selection block verbatim from the
# dispatcher (between sentinel comments) and execute it in a subshell with
# MARKERS_JSON + the GATE_MARKER_NOW_OVERRIDE_EPOCH test seam set, so this test
# cannot silently diverge from shipped code the way gate-head-of-line-skip's
# hand-copied jq did (it hardcoded the pre-4cae0a2c49 ascending sort and kept
# passing for a week+ after production flipped to descending — see that file's
# ga-tgo7q-era fix for the postmortem).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER"; exit 1; }

echo "== gate-marker-age-promote.selftest (ga-tgo7q) =="

# ── Genuine live extraction (not a hand-copied jq string) ────────────────────
SELECT_BLOCK="$(sed -n '/# SELFTEST-EXTRACT marker-select: BEGIN/,/# SELFTEST-EXTRACT marker-select: END/p' "$DISPATCHER")"
if [ -z "$SELECT_BLOCK" ]; then
  echo "FATAL: could not locate 'marker-select' sentinel block in $DISPATCHER"
  echo "  (expected '# SELFTEST-EXTRACT marker-select: BEGIN' / '...: END' markers"
  echo "   around the MARKER=/MARKER_ID= assignment — aging fix not present yet?)"
  exit 1
fi
ok "located live marker-select block via sentinel extraction"

mk() { # id created_at [labels-csv]
  local id="$1" ts="$2" labels="${3:-}"
  local labarr='["gate-status:queued"]'
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  printf '{"id":"%s","created_at":"%s","labels":%s}' "$id" "$ts" "$labarr"
}

select_marker() {
  # args: $1=MARKERS_JSON(array)  $2=now_epoch  $3=age_threshold_secs(default 1800)
  local markers_json="$1" now_epoch="$2" age_threshold="${3:-1800}"
  MARKERS_JSON="$markers_json" \
  GATE_MARKER_NOW_OVERRIDE_EPOCH="$now_epoch" \
  GATE_MARKER_AGE_PROMOTE_SECONDS="$age_threshold" \
  bash -c "$SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
}

# All timestamps are derived from a fixed epoch base via offset arithmetic
# (never hand-written ISO strings) so the test never depends on the wall
# clock and can't drift out of sync with itself.
NOW_EPOCH=1782863814   # arbitrary fixed instant; only the offsets matter
THRESH=1800            # 30 min

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }   # ago SECONDS -> ISO timestamp SECONDS before NOW_EPOCH

echo "── (1) all-fresh healthy queue: newest wins (Athos's 6/24 tiebreak, unchanged) ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk h1 "$(ago 600)")" \
  "$(mk h2 "$(ago 300)")" \
  "$(mk h3 "$(ago 60)")")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH")
[ "$SEL" = "h3" ] && ok "newest (h3, 1m old) selected when nothing is aged (all well under 30m)" \
  || bad "expected h3, got '$SEL' (newest-first tiebreak broken)"

echo "── (2) one healthy marker past the age threshold: it wins over newer arrivals ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk h1 "$(ago 2340)")" \
  "$(mk h2 "$(ago 300)")" \
  "$(mk h3 "$(ago 60)")")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH")
[ "$SEL" = "h1" ] && ok "aged oldest (h1, waited 2340s > 1800s) promoted ahead of newer h2/h3" \
  || bad "expected h1 (starved marker), got '$SEL' — starvation bound not enforced"

echo "── (3) two aged healthy markers: FIFO within the aged tier (oldest of the aged wins) ──"
FIX=$(printf '[%s,%s,%s]' \
  "$(mk h1 "$(ago 7200)")" \
  "$(mk h2 "$(ago 3600)")" \
  "$(mk h3 "$(ago 60)")")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH")
[ "$SEL" = "h1" ] && ok "both h1+h2 aged → oldest of the aged (h1) wins, not just 'any aged one'" \
  || bad "expected h1, got '$SEL' (aged tier is not FIFO)"

echo "── (4) aged rebase-fail marker must NOT jump ahead of a fresh healthy one (ga-q3ig2 guarantee) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk broken "$(ago 7200)" 'gate-status:queued,gate:exiled-tier5:2')" \
  "$(mk fresh "$(ago 60)" 'gate-status:queued')")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH")
[ "$SEL" = "fresh" ] && ok "aged-but-broken marker still sinks behind a fresh healthy one — aging is healthy-tier-only" \
  || bad "expected fresh, got '$SEL' — aging leaked into the rebase-fail tier (ga-q3ig2 regression risk)"

echo "── (5) boundary: exactly at the threshold is NOT yet aged (strict >, no flakiness) ──"
FIX=$(printf '[%s,%s]' \
  "$(mk atboundary "$(ago "$THRESH")")" \
  "$(mk newer "$(ago 60)")")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH")
[ "$SEL" = "newer" ] && ok "marker at exactly the threshold age is NOT promoted (strict >)" \
  || bad "expected newer, got '$SEL' (off-by-one on the aging boundary)"

echo "── (6) all-rebase-fail queue: newest-broken still wins, aging irrelevant (unchanged behavior) ──"
# ga-gpcx: b1 carries the legacy pre-2026-07-17 label name (gate:rebase-attempt:N),
# b2 the current name — proves both still sink here and interoperate under the
# newest-first tiebreak.
FIX=$(printf '[%s,%s]' \
  "$(mk b1 "$(ago 10800)" 'gate-status:queued,gate:rebase-attempt:3')" \
  "$(mk b2 "$(ago 7200)" 'gate-status:queued,gate:exiled-tier5:1')")
SEL=$(select_marker "$FIX" "$NOW_EPOCH" "$THRESH")
[ "$SEL" = "b2" ] && ok "newest broken (b2, current label name) wins over legacy-named b1 when only rebase-fail markers are queued (matches 4cae0a2c49, no aging applied even though both are 'aged')" \
  || bad "expected b2, got '$SEL'"

echo "── (7) drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'SELFTEST-EXTRACT marker-select: BEGIN' "$DISPATCHER" \
  && ok "extraction sentinel present (prevents future silent copy-drift)" || bad "extraction sentinel missing"
grep -q 'def is_aged' "$DISPATCHER" \
  && ok "is_aged predicate present" || bad "is_aged predicate missing"
grep -q 'fromdateiso8601' "$DISPATCHER" \
  && ok "age computed from created_at via fromdateiso8601" || bad "fromdateiso8601 usage missing"
grep -q 'GATE_MARKER_AGE_PROMOTE_SECONDS' "$DISPATCHER" \
  && ok "age threshold is a configurable GATE_* tunable (matches house convention)" || bad "age threshold not configurable"
grep -q 'GATE_MARKER_NOW_OVERRIDE_EPOCH' "$DISPATCHER" \
  && ok "test-only 'now' override seam present (matches GATE_DOLT_LATENCY_OVERRIDE_MS convention)" || bad "no now-override seam — this selftest would be flaky/untestable"
# Tier order in source: aged-healthy chunk must textually precede the
# not-aged-healthy chunk, which must precede the rebase-fail chunk.
AGED_LINE=$(grep -n 'is_aged))' "$DISPATCHER" | grep -v 'is_aged | not' | head -1 | cut -d: -f1)
FRESH_LINE=$(grep -n 'is_aged | not' "$DISPATCHER" | head -1 | cut -d: -f1)
BROKEN_LINE=$(grep -n 'map(select(has_rebase_fail))' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$AGED_LINE" ] && [ -n "$FRESH_LINE" ] && [ -n "$BROKEN_LINE" ] \
   && [ "$AGED_LINE" -lt "$FRESH_LINE" ] && [ "$FRESH_LINE" -lt "$BROKEN_LINE" ]; then
  ok "tier order fixed: aged-healthy, then fresh-healthy, then rebase-fail"
else
  bad "tier order drifted (aged=$AGED_LINE fresh=$FRESH_LINE broken=$BROKEN_LINE) — re-check concat order"
fi

echo "── (8) gate-feedback regression: malformed created_at must not crash the whole sweep ──"
# Live gate review on this fix (2026-07-02, gate_run=ga-wisp-calttxm) found:
# is_aged's fromdateiso8601 call was unguarded, and MARKER=$(... | jq ...) has
# no `|| echo` fallback (unlike sibling MARKERS_JSON/VERIFY_JSON reads in the
# same file). Under `set -euo pipefail` (as the live dispatcher runs), a
# single healthy marker with a null/malformed created_at threw inside
# fromdateiso8601 and aborted the ENTIRE sweep at this assignment — not just
# that one marker. Run the extracted block under set -euo pipefail explicitly
# so a regression here fails the same way it would live.
# (8a) reviewer's exact empirical repro: created_at=null must not crash, and
# must resolve to 'not aged' so the well-formed marker still wins fairly.
FIX=$(printf '[{"id":"bad","created_at":null,"labels":["gate-status:queued"]},%s]' \
  "$(mk good "$(ago 60)")")
SEL=$(MARKERS_JSON="$FIX" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "good" ]; then
  ok "created_at=null degrades to 'not aged' instead of crashing the sweep (exit=$STATUS, selected=$SEL)"
else
  bad "created_at=null broke selection (exit=$STATUS, selected='$SEL') — is_aged must catch fromdateiso8601 errors"
fi

# (8b) reviewer also named "not exactly strict format" as a crash trigger.
# Assert only non-crash here — WHICH marker wins is a separate, lower-
# severity sort-fairness question (sort_by(.created_at) does raw string
# comparison, so a garbage string can lexicographically look "newest"),
# out of scope for this fix: bd-managed created_at is never a malformed
# non-null string in practice, unlike the empirically-observed null case
# above. Tracked separately, not blocking here.
FIX=$(printf '[{"id":"bad","created_at":"not-a-date","labels":["gate-status:queued"]},%s]' \
  "$(mk good "$(ago 60)")")
SEL=$(MARKERS_JSON="$FIX" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ -n "$SEL" ]; then
  ok "created_at=malformed-string no longer crashes the sweep (exit=$STATUS, selected=$SEL)"
else
  bad "created_at=malformed-string broke selection (exit=$STATUS, selected='$SEL') — is_aged must catch fromdateiso8601 errors"
fi

echo "── (9) gate-feedback regression: malformed GATE_* tunables must not crash the whole sweep ──"
# Live gate review on this fix (2026-07-02, gate_run=ga-wisp-a7b4r5) found:
# GATE_MARKER_AGE_PROMOTE_SECONDS and GATE_MARKER_NOW_EPOCH were passed to
# `jq --argjson` with no numeric validation, unlike every sibling GATE_*
# tunable in this file (GATE_DOLT_CPU_HOT etc.), which all get a
# `case ... in ''|*[!0-9]*) VAR=default ;; esac` guard. A non-numeric value
# (e.g. a config typo) makes jq exit 2 BEFORE the marker array is read, which
# — under this script's `set -euo pipefail` — aborts the ENTIRE sweep, not a
# graceful per-marker skip. Reproduce both tunables' bad-input paths under
# set -euo pipefail exactly as case (8) does for created_at.
FIX=$(printf '[%s,%s]' "$(mk h1 "$(ago 600)")" "$(mk h2 "$(ago 60)")")

SEL=$(MARKERS_JSON="$FIX" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" GATE_MARKER_AGE_PROMOTE_SECONDS="not-a-number" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ "$SEL" = "h2" ]; then
  ok "malformed GATE_MARKER_AGE_PROMOTE_SECONDS falls back to default instead of crashing the sweep (exit=$STATUS, selected=$SEL)"
else
  bad "malformed GATE_MARKER_AGE_PROMOTE_SECONDS broke selection (exit=$STATUS, selected='$SEL') — needs the same case-guard as sibling GATE_* tunables"
fi

SEL=$(MARKERS_JSON="$FIX" GATE_MARKER_NOW_OVERRIDE_EPOCH="not-a-number" GATE_MARKER_AGE_PROMOTE_SECONDS="$THRESH" \
  bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null)
STATUS=$?
if [ "$STATUS" = "0" ] && [ -n "$SEL" ]; then
  ok "malformed GATE_MARKER_NOW_OVERRIDE_EPOCH falls back to real wall clock instead of crashing the sweep (exit=$STATUS, selected=$SEL)"
else
  bad "malformed GATE_MARKER_NOW_OVERRIDE_EPOCH broke selection (exit=$STATUS, selected='$SEL') — needs the same case-guard as sibling GATE_* tunables"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
