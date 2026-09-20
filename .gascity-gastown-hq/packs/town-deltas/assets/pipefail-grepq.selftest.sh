#!/usr/bin/env bash
# pipefail-grepq.selftest.sh — ga-5bxuam: `<writer> | grep -q ...` under pipefail.
#
# Under `set -o pipefail`, `writer | grep -q PAT` reports NO MATCH although PAT is there:
# grep -q leaves on its FIRST match, the writer can still be writing, catches SIGPIPE, and
# the pipeline's status becomes the writer's 141. A decision flips silently (7-22% per check
# at load 40 on this host; 100% once the input is bigger than the 64 KB pipe buffer).
#
# This file proves, against the REAL production scripts (not fixtures), that
#   A. the decision functions that used the idiom now answer correctly on a >64 KB input
#      (deterministic: the old idiom fails here every time — that is what makes this a test),
#   B. no production script under packs/ and scripts/ carries the idiom any more
#      (a ratchet: a new `| grep -q` under pipefail in production fails here, per file),
#   C. the detector behind B (error-empty-conflation-scan.sh, C10) is present.
# The detector's own fixtures and the race demonstration live in
# error-empty-conflation-scan.selftest.sh.
#
# NOT covered here (follow-up beads): *.selftest.sh and tests/*.test.sh carry the same idiom in
# their own ASSERTIONS (a false FAIL instead of a wrong decision); this file only reports how many.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_DIR="$(cd "$SELF_DIR/../../.." && pwd)"          # .../.gascity-gastown-hq
P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

# extract_fn <file> <name> — the function definition, from '^name() {' to the first '^}'.
extract_fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}/ {exit}' "$1"; }

# in_prod <script> <fn,fn,...> <snippet> — define the REAL functions under pipefail, run the snippet.
# A function that cannot be found is a FAILURE (rc 99), never a silent skip.
in_prod() {
  local script="$1" fns="$2" snippet="$3" body="" f def
  [ -f "$script" ] || { echo "MISSING_SCRIPT:$script"; return 99; }
  for f in ${fns//,/ }; do
    def="$(extract_fn "$script" "$f")"
    [ -n "$def" ] || { echo "MISSING_FN:$f"; return 99; }
    body+="$def"$'\n'
  done
  ( set -o pipefail; eval "$body"; eval "$snippet" )
}

# BIG: the match is on line 1; ~140 KB of filler follows (well over the pipe buffer).
FILL="$(head -c 140000 /dev/zero | tr '\0' 'x')"
BIG_LIST="$(printf 'target\n%s' "$FILL")"

echo "── A. production decision functions on a >64 KB input (the old idiom fails every time) ──"

# pilot-dispatcher.sh: is this session live / asleep?  (drives dispatch and reclaim)
PD="$SELF_DIR/pilot-dispatcher.sh"
for fn in _session_is_live _session_is_asleep; do
  var=$([ "$fn" = _session_is_live ] && echo _LIVE_SESSION_IDS || echo _ASLEEP_SESSION_IDS)
  out="$(in_prod "$PD" "$fn" "$var=\"\$BIG_LIST\"; $fn target && echo YES || echo NO" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = YES ] && ok "pilot-dispatcher $fn: session on line 1 of a 140 KB list is found" \
    || bad "pilot-dispatcher $fn: expected YES on a 140 KB list, got '$out' (rc=$rc)"
done
out="$(in_prod "$PD" _session_is_live '_LIVE_SESSION_IDS="$BIG_LIST"; _session_is_live absent && echo YES || echo NO' 2>&1)"
[ "$out" = NO ] && ok "pilot-dispatcher _session_is_live: a session that is NOT listed is still 'no' (no false positive)" || bad "pilot-dispatcher _session_is_live: absent id answered '$out'"

# quality-gate-guard.sh: is a gate marker still active? A 'done' marker must read as NOT active.
GG="$SELF_DIR/quality-gate-guard.sh"
DONE_LABELS="$(printf 'gate-status:done\n%s' "$FILL")"
out="$(in_prod "$GG" marker_active_from_labels 'marker_active_from_labels "$DONE_LABELS"' 2>&1)"
[ "$out" = 0 ] && ok "quality-gate-guard marker_active_from_labels: gate-status:done on line 1 of 140 KB -> 0 (not active)" \
  || bad "quality-gate-guard marker_active_from_labels: expected 0, got '$out' (a finished marker read as ACTIVE)"
ACTIVE_LABELS="$(printf 'gate-status:queued\n%s' "$FILL")"
out="$(in_prod "$GG" marker_active_from_labels 'marker_active_from_labels "$ACTIVE_LABELS"' 2>&1)"
[ "$out" = 1 ] && ok "quality-gate-guard marker_active_from_labels: gate-status:queued -> 1 (active)" || bad "quality-gate-guard marker_active_from_labels: queued read as '$out'"

# quality-gate-dispatcher.sh: does this marker carry a gate-status label?  (writer is tr, reader grep -q)
GD="$SELF_DIR/quality-gate-dispatcher.sh"
STATUS_LABELS="$(printf 'gate-status:ready %s' "$FILL")"
out="$(in_prod "$GD" gate_labels_have_status 'gate_labels_have_status "$STATUS_LABELS"' 2>&1)"
[ "$out" = 1 ] && ok "quality-gate-dispatcher gate_labels_have_status: label at the start of 140 KB -> 1" || bad "quality-gate-dispatcher gate_labels_have_status: expected 1, got '$out'"

# crew-hang-detector.sh: is the crew pane busy?  A false 'no' can file a hang warrant against a working agent.
CH="$SELF_DIR/crew-hang-detector.sh"
PANE="$(printf 'esc to interrupt\n%s' "$FILL")"
out="$(in_prod "$CH" is_active_work 'is_active_work "$PANE" && echo BUSY || echo IDLE' 2>&1)"
[ "$out" = BUSY ] && ok "crew-hang-detector is_active_work: 'esc to interrupt' on line 1 of a 140 KB pane -> BUSY" || bad "crew-hang-detector is_active_work: expected BUSY, got '$out'"
out="$(in_prod "$CH" is_active_work 'is_active_work "just a quiet prompt" && echo BUSY || echo IDLE' 2>&1)"
[ "$out" = IDLE ] && ok "crew-hang-detector is_active_work: a quiet pane is still IDLE (no false positive)" || bad "crew-hang-detector is_active_work: quiet pane read as '$out'"

# story-delivery.sh / merged-bead-janitor.sh: is TOKEN a whole word in TEXT?
for f in story-delivery.sh merged-bead-janitor.sh; do
  TXT="$(printf 'ga-abc123 first line\n%s' "$FILL")"
  out="$(in_prod "$SELF_DIR/$f" token_bounded 'token_bounded ga-abc123 "$TXT" && echo YES || echo NO' 2>&1)"
  [ "$out" = YES ] && ok "$f token_bounded: bead id on line 1 of 140 KB of text is found" || bad "$f token_bounded: expected YES, got '$out'"
done

# realistic size, many tries: at load 40 the old idiom flipped 5-22% of these; the fix must give 0 wrong answers.
# ONE extraction and ONE subshell for all calls (the gate gives a selftest 30 s against the base).
flips="$( ( set -o pipefail; eval "$(extract_fn "$GG" marker_active_from_labels)"
  n=0; for _i in $(seq 1 100); do
    [ "$(marker_active_from_labels "gate-status:done story:approved ctx:ready exec:auto lane:small")" = 0 ] || n=$((n + 1))
  done; echo "$n" ) 2>&1 )"
[ "$flips" = 0 ] && ok "quality-gate-guard marker_active_from_labels: 0 wrong answers in 100 realistic-size calls" || bad "quality-gate-guard marker_active_from_labels: '$flips' of 100 realistic-size calls answered wrong"

echo "── B. ratchet: no production script carries \`| grep -q\` under pipefail ──"
SCANNER="$SELF_DIR/error-empty-conflation-scan.sh"
if [ -f "$SCANNER" ]; then
  # shellcheck disable=SC1090
  CONFLATION_SCAN_LIB_ONLY=1 . "$SCANNER" || true
fi
if ! type scan_pipefail_grep_q_files >/dev/null 2>&1; then
  bad "error-empty-conflation-scan.sh has no C10 detector (scan_pipefail_grep_q_files) — nothing to ratchet with"
else
  # production-class files, RELATIVE exclusions only (an absolute-path exclude would empty the scan
  # whenever this checkout itself lives under .gc-worktrees).
  PROD_LIST="$(cd "$CITY_DIR" 2>/dev/null && find packs scripts -type f -name '*.sh' \
      -not -name '*.selftest.sh' -not -name '*.test.sh' -not -path '*/tests/*' \
      -not -path '*/.gc/*' -not -path '*/backup/*' -not -path '*/node_modules/*' -not -path '*/venv/*' \
      -not -path '*/__pycache__/*' -not -path '*/.local-patches/*' 2>/dev/null | sort)"
  n_files=$(grep -c . <<<"$PROD_LIST")
  if [ "$n_files" -lt 50 ]; then
    bad "ratchet scanned only $n_files production files (expected >= 50) — an empty scan must not read as 'clean'"
  else
    ok "ratchet scans $n_files production-class scripts under packs/ and scripts/"
    # shellcheck disable=SC2046
    FINDINGS="$(cd "$CITY_DIR" && scan_pipefail_grep_q_files $(printf '%s ' $PROD_LIST))"
    # known, tracked exception: reaper.sh is fixed in ga-hpdpij (in flight when this landed).
    KNOWN="packs/town-deltas/assets/scripts/reaper.sh"
    bad_files=0
    while IFS= read -r pf; do
      [ -z "$pf" ] && continue
      n=$(grep -c "^${pf//./\\.}:" <<<"$FINDINGS")
      if [ "$n" -gt 0 ]; then
        if [ "$pf" = "$KNOWN" ]; then
          ok "known exception (ga-hpdpij): $pf still has $n site(s) until that fix lands"
        else
          bad "$pf: $n \`| grep -q\` site(s) under pipefail (first: $(grep -m1 "^${pf//./\\.}:" <<<"$FINDINGS" | cut -c1-150))"
          bad_files=$((bad_files + 1))
        fi
      fi
    done < <(cut -d: -f1 <<<"$FINDINGS" | sort -u)
    [ "$bad_files" = 0 ] && ok "no production script (other than the tracked exception) carries the racy idiom"
  fi
  # informational, not asserted: the debt that remains in test code
  TEST_LIST="$(cd "$CITY_DIR" 2>/dev/null && find packs scripts -type f \( -name '*.selftest.sh' -o -name '*.test.sh' -o -path '*/tests/*.sh' \) \
      -not -path '*/.gc/*' -not -path '*/backup/*' -not -path '*/__pycache__/*' 2>/dev/null | sort)"
  if [ -n "$TEST_LIST" ]; then
    # shellcheck disable=SC2046
    n_test=$(cd "$CITY_DIR" && scan_pipefail_grep_q_files $(printf '%s ' $TEST_LIST) | grep -c ':C10:')
    echo "  note: $n_test C10 site(s) remain in selftests/tests (assertion flake, tracked as follow-ups; not asserted here)"
  fi
fi

echo "── C. the detector is wired into the scanner's run_scan ──"
if [ -f "$SCANNER" ] && grep -q 'scan_pipefail_grep_q "\$f"' "$SCANNER"; then
  ok "run_scan calls scan_pipefail_grep_q (the silent-ignorance monitor will alert on NEW occurrences)"
else
  bad "run_scan does not call scan_pipefail_grep_q — new occurrences would go unseen"
fi

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
