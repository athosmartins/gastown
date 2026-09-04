#!/bin/bash
# dolt-disk-floor-guard.selftest.sh — unit tests for the PURE decision logic of
# dolt-disk-floor-guard.sh: avail-GB df-parsing, floor classification, worsening
# detection, and cooldown + worsening-bypass notify gating.
#
# Hermetic: sources the script as a LIBRARY (DOLT_DISK_FLOOR_GUARD_LIB=1) so main()
# never runs, points the log at a throwaway path. Never calls `gc dolt-cleanup`,
# `gc mail send`, `notify`, or the real scratchpad-reaper.sh; nothing is deleted,
# nothing is sent, nothing in Dolt's data dir or /private/tmp is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-disk-floor-guard.sh"

export DOLT_DISK_FLOOR_GUARD_LIB=1
export DOLT_DISK_FLOOR_GUARD_LOG="/tmp/dolt-disk-floor-guard-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-disk-floor-guard.selftest.sh ==="

# ── _avail_gb: real df parsing (NOT stubbed — proves the -k/1024/1024 math matches
#    this machine's actual df output format; the decision-function tests below
#    stub avail directly and don't depend on this) ────────────────────────────────
g="$(_avail_gb /tmp)"
case "$g" in
  ''|*[!0-9]*) bad "_avail_gb(/tmp) did not return an integer (got: '$g')" ;;
  *) [ "$g" -gt 0 ] && ok "_avail_gb(/tmp) returns a positive integer GB ($g)" || bad "_avail_gb(/tmp) returned non-positive: $g" ;;
esac

# ── _avail_gb: nonexistent path → "" (surfaces as UNKNOWN, never a silent 0 —
#    ga-p5q3: error and empty must not collapse to the same value as "fine") ──────
g="$(_avail_gb "/nonexistent/path/$$/does-not-exist")"
[ "$g" = "" ] && ok "_avail_gb(nonexistent path) → '' (df failure surfaces, not masked)" || bad "_avail_gb(nonexistent) got: '$g' (expected empty)"

# ── _vm_swap_gb: real du parsing on this host's macOS virtual-memory volume
#    (NOT stubbed — proves the -k/1024/1024 math against this machine's
#    actual du output, same rationale as the _avail_gb(/tmp) test above;
#    ga-sfj3i.2) ─────────────────────────────────────────────────────────────
g="$(_vm_swap_gb)"
case "$g" in
  ''|*[!0-9]*) bad "_vm_swap_gb() did not return an integer (got: '$g')" ;;
  *) [ "$g" -ge 0 ] && ok "_vm_swap_gb() returns a non-negative integer GB ($g)" || bad "_vm_swap_gb() returned negative: $g" ;;
esac

# ── _vm_swap_gb: du failure → "" (surfaces as "unknown" in the log line,
#    never a silent 0 — same ga-p5q3 error/empty discipline as _avail_gb
#    above). Shadows `du` with a local function for exactly one call
#    (function lookup wins over PATH in bash) rather than reparameterizing
#    _vm_swap_gb, since its whole point is one fixed, non-configurable
#    target path, unlike _avail_gb's optional [path] arg. ───────────────────
du() { echo "not a number"; }
g="$(_vm_swap_gb)"
unset -f du
[ "$g" = "" ] && ok "_vm_swap_gb() → '' when du output is unparseable (failure surfaces, not masked)" || bad "_vm_swap_gb(du failure) got: '$g' (expected empty)"

# ── _floor_class: NONE / WARN / CRITICAL / UNKNOWN boundaries (warn=8 crit=3) ─────
[ "$(_floor_class 20 8 3)" = "NONE" ]      && ok "class: 20GB avail, floors(8,3) → NONE"                    || bad "class 20/8/3 wrong: $(_floor_class 20 8 3)"
[ "$(_floor_class 8  8 3)" = "WARN" ]      && ok "class: avail==warn floor → WARN (boundary inclusive)"     || bad "class 8/8/3 wrong: $(_floor_class 8 8 3)"
[ "$(_floor_class 5  8 3)" = "WARN" ]      && ok "class: between crit and warn → WARN"                      || bad "class 5/8/3 wrong: $(_floor_class 5 8 3)"
[ "$(_floor_class 3  8 3)" = "CRITICAL" ]  && ok "class: avail==crit floor → CRITICAL (boundary inclusive)" || bad "class 3/8/3 wrong: $(_floor_class 3 8 3)"
[ "$(_floor_class 0  8 3)" = "CRITICAL" ]  && ok "class: avail=0 → CRITICAL"                                || bad "class 0/8/3 wrong: $(_floor_class 0 8 3)"
[ "$(_floor_class ""  8 3)" = "UNKNOWN" ]  && ok "class: empty avail (df failed) → UNKNOWN, never NONE"     || bad "class empty wrong: $(_floor_class "" 8 3)"
[ "$(_floor_class abc 8 3)" = "UNKNOWN" ]  && ok "class: non-numeric avail → UNKNOWN"                       || bad "class abc wrong: $(_floor_class abc 8 3)"

# ── _worsening: avail-GB FALLING = worsening (inverse framing of
#    disk-pressure-monitor's usage-% rising; same idiom) ─────────────────────────
_worsening 5 8  && ok "worsening: 5GB < last-notified 8GB → true (pressure increased)"              || bad "worsening 5<8 should be true"
_worsening 8 5  && bad "worsening: 8GB > last-notified 5GB should be FALSE (avail improved)"         || ok "worsening: improved avail → false"
_worsening 5 5  && bad "worsening: unchanged avail should be FALSE (no new info)"                    || ok "worsening: unchanged avail → false"
_worsening 5 "" && bad "worsening: no prior value should be FALSE (unknown trend isn't a bypass)"    || ok "worsening: no prior notified value → false"

# ── _cooldown_elapsed: fail-open on no/invalid prior timestamp ───────────────────
_cooldown_elapsed "" 1000 3600   && ok "cooldown: no prior timestamp → elapsed (fail-open)"        || bad "cooldown empty should fail-open"
_cooldown_elapsed 1000 1000 3600 && bad "cooldown: 0s elapsed should NOT be elapsed"                 || ok "cooldown: just-notified → still cooling down"
_cooldown_elapsed 1000 4601 3600 && ok "cooldown: 3601s elapsed >= 3600s window → elapsed"          || bad "cooldown: should have elapsed"
_cooldown_elapsed 1000 4600 3600 && ok "cooldown: exactly 3600s elapsed → elapsed (boundary >=)"    || bad "cooldown: boundary should be inclusive"

# ── _should_notify: composed gate — cooldown-elapsed OR worsening (ga-vs55 furo #2
#    lesson: a cooldown blind to trend silenced a real emergency 28min before Dolt
#    died; this MUST NOT regress that fix onto the new guard) ────────────────────
_should_notify 1000 1100 3600 5 8  && ok "should_notify: within cooldown BUT worsening (5<8) → notify anyway"      || bad "should_notify: worsening should bypass cooldown"
_should_notify 1000 1100 3600 8 5  && bad "should_notify: within cooldown, improved, no bypass → should suppress" || ok "should_notify: within cooldown + improved avail → suppressed"
_should_notify 1000 4601 3600 8 8  && ok "should_notify: cooldown elapsed, stable avail → notify (repeat allowed)" || bad "should_notify: elapsed cooldown should notify regardless of trend"
_should_notify "" 1100 3600 8 ""   && ok "should_notify: never notified before → notify (fail-open)"               || bad "should_notify: first-ever call should notify"

# ── _sustain_confirmed: CRITICAL-mail debounce gate (ga-q4cqr) — the
#    boundary is >= (inclusive), and a corrupt/non-numeric pending count
#    fails CLOSED (never confirmed), the opposite direction from
#    _cooldown_elapsed's fail-open — see the function's own comment for why.
_sustain_confirmed 2 2   && ok "sustain_confirmed: pending==threshold → confirmed (boundary inclusive)" || bad "sustain_confirmed: 2>=2 should confirm"
_sustain_confirmed 3 2   && ok "sustain_confirmed: pending>threshold → confirmed"                        || bad "sustain_confirmed: 3>=2 should confirm"
_sustain_confirmed 1 2   && bad "sustain_confirmed: pending<threshold should NOT confirm"                || ok "sustain_confirmed: 1<2 → not yet confirmed"
_sustain_confirmed 0 2   && bad "sustain_confirmed: pending=0 should NOT confirm"                        || ok "sustain_confirmed: 0<2 → not yet confirmed"
_sustain_confirmed "" 2  && bad "sustain_confirmed: empty pending should fail CLOSED, not confirm"       || ok "sustain_confirmed: empty pending → fails closed (never confirmed)"
_sustain_confirmed abc 2 && bad "sustain_confirmed: non-numeric pending should fail CLOSED"              || ok "sustain_confirmed: non-numeric pending → fails closed"
_sustain_confirmed 1 1   && ok "sustain_confirmed: threshold=1 (sustain disabled/immediate) → confirmed on 1st sample" || bad "sustain_confirmed: 1>=1 should confirm"

# ── _top_rss_processes: real ps/sort parsing (NOT stubbed — proves the
#    pid,rss,comm/-k2 sort matches this machine's actual `ps` output format,
#    same rationale as the _avail_gb(/tmp) and _vm_swap_gb() real tests
#    above; ga-sfj3i.3 item 4) ────────────────────────────────────────────
g="$(_top_rss_processes 5)"
line_count="$(printf '%s\n' "$g" | grep -c .)"
[ "$line_count" -eq 5 ] && ok "_top_rss_processes(5) returns exactly 5 lines" || bad "_top_rss_processes(5) returned $line_count lines (expected 5): $g"
g2="$(_top_rss_processes 2)"
line_count2="$(printf '%s\n' "$g2" | grep -c .)"
[ "$line_count2" -eq 2 ] && ok "_top_rss_processes(2) respects the N argument" || bad "_top_rss_processes(2) returned $line_count2 lines (expected 2)"
# each line: PID RSS_KB COMMAND — first two whitespace fields must be numeric.
# Guard explicitly on empty output first — a `while read` over an empty
# variable still iterates once with an empty line, which would otherwise
# leave bad_line/order_bad at their innocent defaults and PASS vacuously
# (ga-p5q3: empty must never grade the same as "checked and fine").
if [ -z "$g" ]; then
  bad_line="(no output — cannot check shape)"
else
  bad_line=""
  while IFS= read -r ln; do
    pid_f="$(printf '%s' "$ln" | awk '{print $1}')"
    rss_f="$(printf '%s' "$ln" | awk '{print $2}')"
    case "$pid_f" in ''|*[!0-9]*) bad_line="$ln" ;; esac
    case "$rss_f" in ''|*[!0-9]*) bad_line="$ln" ;; esac
  done <<RSS_SHAPE
$g
RSS_SHAPE
fi
[ -z "$bad_line" ] && ok "_top_rss_processes: every line has numeric PID + RSS_KB as its first two fields" || bad "_top_rss_processes: non-numeric PID/RSS or no output: '$bad_line'"
# descending order: field 2 (RSS) must be non-increasing line-to-line
if [ -z "$g" ]; then
  order_bad=1
else
  prev_rss=""
  order_bad=0
  while IFS= read -r ln; do
    rss_f="$(printf '%s' "$ln" | awk '{print $2}')"
    if [ -n "$prev_rss" ] && [ "$rss_f" -gt "$prev_rss" ]; then order_bad=1; fi
    prev_rss="$rss_f"
  done <<RSS_ORDER
$g
RSS_ORDER
fi
[ "$order_bad" -eq 0 ] && ok "_top_rss_processes: rows sorted by RSS descending" || bad "_top_rss_processes: rows NOT sorted descending by RSS (or no output)"

# ── _top_rss_processes: ps failure → "" (surfaces as unmeasured, never a
#    silent empty-looking-like-zero-processes — same ga-p5q3 discipline) ────
ps() { echo "not process output"; }
g="$(_top_rss_processes 5 | grep -c .)"
unset -f ps
[ "$g" -eq 0 ] && ok "_top_rss_processes: unparseable ps output → no rows (failure surfaces as empty, not fabricated rows)" || bad "_top_rss_processes(ps failure) got $g rows (expected 0)"

# ── _vm_bound_pressure: reclaimed<=0 AND vm>=threshold → VM-bound (the exact
#    ga-sfj3i incident shape: "reclaim OK — avail X -> X" while GB are stuck
#    in virtual memory) ──────────────────────────────────────────────────
_vm_bound_pressure 0 5 2   && ok "vm_bound: reclaimed=0, vm=5>=2 → VM-bound"                      || bad "vm_bound 0/5/2 should be true"
_vm_bound_pressure -3 5 2  && ok "vm_bound: reclaimed=-3 (worse), vm=5>=2 → VM-bound"              || bad "vm_bound -3/5/2 should be true"
_vm_bound_pressure 0 2 2   && ok "vm_bound: vm==threshold → VM-bound (boundary inclusive)"         || bad "vm_bound 0/2/2 should be true (inclusive boundary)"
_vm_bound_pressure 5 5 2   && bad "vm_bound: reclaimed=5 (cleanup worked) should NOT be VM-bound"  || ok "vm_bound: positive reclaim → not VM-bound"
_vm_bound_pressure 0 1 2   && bad "vm_bound: vm=1 below threshold=2 should NOT be VM-bound"        || ok "vm_bound: vm below threshold → not VM-bound"
_vm_bound_pressure 0 "" 2  && bad "vm_bound: unmeasurable vm should NEVER confirm VM-bound"        || ok "vm_bound: empty vm → not VM-bound (unmeasurable, not false-negative-as-fine)"
_vm_bound_pressure 0 abc 2 && bad "vm_bound: non-numeric vm should NEVER confirm VM-bound"         || ok "vm_bound: non-numeric vm → not VM-bound"

echo ""
echo "=== _reap_dead_scratch: production sentinel wiring (ga-h565g) ==="
# _reap_dead_scratch is the REAL caller scratchpad-reaper.sh's own header
# names as the one allowed to set SCRATCHPAD_REAPER_PROD=1 (ga-h565g) — this
# proves it actually does, BEFORE _reap_dead_scratch gets stubbed out below
# for the main() scenarios. Hermetic: CITY is a plain global (not readonly),
# reassigned here to a disposable tmp dir containing a FAKE
# scratchpad-reaper.sh that only records what env it received — never touches
# the real scratchpad-reaper.sh, no real `gc session list`, no real deletion.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/scratchpad-reaper.sh" <<EOF
#!/bin/bash
echo "PROD=\${SCRATCHPAD_REAPER_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/scratchpad-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_dead_scratch
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch: sets SCRATCHPAD_REAPER_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_dead_scratch: did NOT set SCRATCHPAD_REAPER_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_dead_scratch: CRITICAL-pressure plumbing (ga-rjhfz) ==="
# scratchpad-reaper.sh's own size-escape gate (independently selftested)
# only activates when it sees SCRATCHPAD_REAPER_PRESSURE=CRITICAL.
# _reap_dead_scratch is the ONLY place that can set it — main() passes
# was_critical (1 iff this cycle was CRITICAL at any point, pre- or
# post-reclaim) as $1. Same hermetic fake-CITY/capture-file technique as the
# PROD=1 wiring test above: never touches the real reaper.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/scratchpad-reaper.sh" <<EOF
#!/bin/bash
echo "PRESSURE=\${SCRATCHPAD_REAPER_PRESSURE:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/scratchpad-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_dead_scratch 1
CITY="$REAL_CITY"
if [ -f "$CAPTURE_FILE" ] && grep -qx "PRESSURE=CRITICAL" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch(was_critical=1): sets SCRATCHPAD_REAPER_PRESSURE=CRITICAL (size-escape enabled)"
else
  bad "_reap_dead_scratch(was_critical=1): did NOT set SCRATCHPAD_REAPER_PRESSURE=CRITICAL (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi

CITY="$FAKE_CITY"
_reap_dead_scratch 0
CITY="$REAL_CITY"
if [ -f "$CAPTURE_FILE" ] && grep -qx "PRESSURE=unset" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch(was_critical=0): leaves SCRATCHPAD_REAPER_PRESSURE unset (non-critical cycle, no escape)"
else
  bad "_reap_dead_scratch(was_critical=0): should NOT set SCRATCHPAD_REAPER_PRESSURE (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi

CITY="$FAKE_CITY"
_reap_dead_scratch   # no arg at all — must default the same as explicit 0 (backward compatible with the PROD=1 test above, which calls it bare)
CITY="$REAL_CITY"
if [ -f "$CAPTURE_FILE" ] && grep -qx "PRESSURE=unset" "$CAPTURE_FILE"; then
  ok "_reap_dead_scratch(no arg): defaults was_critical to non-critical (backward compatible)"
else
  bad "_reap_dead_scratch(no arg): should default to no pressure escape (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_dead_transcripts: production sentinel wiring (ga-lfj05) ==="
# Same proof as _reap_dead_scratch above, for the sibling lever: transcript-
# reaper.sh's own header names _reap_dead_transcripts as the ONLY allowed
# setter of TRANSCRIPT_REAPER_PROD=1. Hermetic: CITY is a plain global (not
# readonly), reassigned here to a disposable tmp dir containing a FAKE
# transcript-reaper.sh that only records what env it received — never
# touches the real transcript-reaper.sh, no real `gc session list`, no real
# deletion.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city2.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/transcript-reaper.sh" <<EOF
#!/bin/bash
echo "PROD=\${TRANSCRIPT_REAPER_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/transcript-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_dead_transcripts
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_dead_transcripts: sets TRANSCRIPT_REAPER_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_dead_transcripts: did NOT set TRANSCRIPT_REAPER_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_dead_transcripts: TIMEOUT and FAILURE must not log the same thing ==="
# WHY: measured 2026-08-01 in the live guard log — 5 runs, 5 timeouts, ZERO
# successes, each lasting exactly ~60s against the old `timeout 60`. Every one
# logged the generic "transcript-reap FAILED or aborted (nonzero exit)", which
# reads as "tried and could not free space" when the truth was "was killed
# before it could try". A full pass measures ~39s on this host, and the
# liveness call it makes first stretches 1.3s -> 10-20s exactly when Dolt is
# warm — i.e. exactly when disk pressure triggers this path. Collapsing the two
# outcomes hid a completely broken emergency disk-reclaim (root-class:error-vs-empty).
FAKE_CITY_T="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city3.XXXXXX)"
mkdir -p "$FAKE_CITY_T/scripts"
REAL_CITY="$CITY"; REAL_LOG="$LOG"

# (a) reaper that OUTLIVES the bound -> must say TIMED OUT, not FAILED
cat > "$FAKE_CITY_T/scripts/transcript-reaper.sh" <<'EOF'
#!/bin/bash
sleep 5
exit 0
EOF
chmod +x "$FAKE_CITY_T/scripts/transcript-reaper.sh"
LOG="$FAKE_CITY_T/timeout.log"; : > "$LOG"
CITY="$FAKE_CITY_T"; TRANSCRIPT_REAP_TIMEOUT_SECS=1 _reap_dead_transcripts; CITY="$REAL_CITY"
if grep -q "TIMED OUT" "$LOG" 2>/dev/null; then
  ok "_reap_dead_transcripts: a run killed by the bound logs TIMED OUT (reclaim did not complete)"
else
  bad "_reap_dead_transcripts: bound-kill did NOT log TIMED OUT — got: $(tr '\n' ';' < "$LOG" | cut -c1-140)"
fi
if grep -qE "FAILED after" "$LOG" 2>/dev/null; then
  bad "_reap_dead_transcripts: a TIMEOUT was also reported as FAILED — the two are still conflated"
else
  ok "_reap_dead_transcripts: a TIMEOUT is not also reported as a genuine failure"
fi

# (b) reaper that exits nonzero QUICKLY -> must say FAILED, not TIMED OUT
cat > "$FAKE_CITY_T/scripts/transcript-reaper.sh" <<'EOF'
#!/bin/bash
exit 3
EOF
chmod +x "$FAKE_CITY_T/scripts/transcript-reaper.sh"
LOG="$FAKE_CITY_T/failed.log"; : > "$LOG"
CITY="$FAKE_CITY_T"; TRANSCRIPT_REAP_TIMEOUT_SECS=30 _reap_dead_transcripts; CITY="$REAL_CITY"
if grep -qE "FAILED after" "$LOG" 2>/dev/null && ! grep -q "TIMED OUT" "$LOG" 2>/dev/null; then
  ok "_reap_dead_transcripts: a genuine nonzero exit logs FAILED (not TIMED OUT) — no blind spot introduced"
else
  bad "_reap_dead_transcripts: genuine failure misreported — got: $(tr '\n' ';' < "$LOG" | cut -c1-140)"
fi

# (c) the real default bound must cover the measured ~39s pass with margin
LOG="$FAKE_CITY_T/default.log"; : > "$LOG"
cat > "$FAKE_CITY_T/scripts/transcript-reaper.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_CITY_T/scripts/transcript-reaper.sh"
CITY="$FAKE_CITY_T"; unset TRANSCRIPT_REAP_TIMEOUT_SECS; _reap_dead_transcripts; CITY="$REAL_CITY"
if grep -q "bound=300s" "$LOG" 2>/dev/null; then
  ok "_reap_dead_transcripts: default bound is 300s — covers the measured ~39s pass even when Dolt is warm"
else
  bad "_reap_dead_transcripts: default bound is not 300s — got: $(tr '\n' ';' < "$LOG" | cut -c1-140)"
fi
LOG="$REAL_LOG"
rm -rf "$FAKE_CITY_T"

echo ""
echo "=== _reap_hf_cache: production sentinel wiring (wa-9eh0v) ==="
# Same hermetic fake-CITY/capture-file technique as the other levers above:
# CITY reassigned to a disposable tmp dir containing a FAKE
# .gc/recall-venv/bin/python3 that only records the env it received — never
# touches the real recall-venv, no real huggingface_hub import, no real
# cache deletion. _reap_hf_cache is the REAL caller hf_cache_reap.py's own
# header names as the one allowed to set HF_CACHE_REAP_PROD=1 — this proves
# it actually does, when the cycle was CRITICAL (was_critical=1).
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY_H/scripts" "$FAKE_CITY_H/.gc/recall-venv/bin"
touch "$FAKE_CITY_H/scripts/hf_cache_reap.py"
CAPTURE_FILE="$FAKE_CITY_H/capture.txt"
cat > "$FAKE_CITY_H/.gc/recall-venv/bin/python3" <<EOF
#!/bin/bash
echo "PROD=\${HF_CACHE_REAP_PROD:-unset} ARG1=\${1:-none}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY_H/.gc/recall-venv/bin/python3"

REAL_CITY="$CITY"
CITY="$FAKE_CITY_H"
_reap_hf_cache 1
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -q "^PROD=1 " "$CAPTURE_FILE"; then
  ok "_reap_hf_cache(was_critical=1): sets HF_CACHE_REAP_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_hf_cache(was_critical=1): did NOT set HF_CACHE_REAP_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
if [ -f "$CAPTURE_FILE" ] && grep -q "ARG1=$FAKE_CITY_H/scripts/hf_cache_reap.py" "$CAPTURE_FILE"; then
  ok "_reap_hf_cache(was_critical=1): invokes the venv python3 with the script's own path as argv[1]"
else
  bad "_reap_hf_cache(was_critical=1): did not pass the expected script path (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_hf_cache: CRITICAL-only gating (wa-9eh0v) ==="
# UNLIKE _reap_dead_scratch/_reap_dead_transcripts/_reap_growing_logs (which
# all run at WARN too), this lever has a real recurring cost (next `recall`
# call pays a re-download) and must be a strict no-op below CRITICAL — the
# capture file must never even be created.
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY_H/scripts" "$FAKE_CITY_H/.gc/recall-venv/bin"
touch "$FAKE_CITY_H/scripts/hf_cache_reap.py"
CAPTURE_FILE="$FAKE_CITY_H/capture.txt"
cat > "$FAKE_CITY_H/.gc/recall-venv/bin/python3" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY_H/.gc/recall-venv/bin/python3"

REAL_CITY="$CITY"
CITY="$FAKE_CITY_H"
_reap_hf_cache 0
if [ ! -f "$CAPTURE_FILE" ]; then
  ok "_reap_hf_cache(was_critical=0): never invokes the venv (WARN-tier is a strict no-op — cost is CRITICAL-only)"
else
  bad "_reap_hf_cache(was_critical=0): invoked the venv when it should have skipped (got: $(cat "$CAPTURE_FILE")"
fi

_reap_hf_cache   # no arg at all — must default the same as explicit 0
if [ ! -f "$CAPTURE_FILE" ]; then
  ok "_reap_hf_cache(no arg): defaults was_critical to non-critical (backward-compatible no-op)"
else
  bad "_reap_hf_cache(no arg): should default to skip, invoked the venv instead (got: $(cat "$CAPTURE_FILE")"
fi
CITY="$REAL_CITY"
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_hf_cache: guard-level ENABLED kill switch (wa-9eh0v) ==="
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
mkdir -p "$FAKE_CITY_H/scripts" "$FAKE_CITY_H/.gc/recall-venv/bin"
touch "$FAKE_CITY_H/scripts/hf_cache_reap.py"
CAPTURE_FILE="$FAKE_CITY_H/capture.txt"
cat > "$FAKE_CITY_H/.gc/recall-venv/bin/python3" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY_H/.gc/recall-venv/bin/python3"

REAL_CITY="$CITY"; CITY="$FAKE_CITY_H"
REAL_ENABLED="$ENABLED"; ENABLED=0
_reap_hf_cache 1
ENABLED="$REAL_ENABLED"; CITY="$REAL_CITY"
if [ ! -f "$CAPTURE_FILE" ]; then
  ok "_reap_hf_cache: ENABLED=0 skips this lever too (not just the other four)"
else
  bad "_reap_hf_cache: ENABLED=0 did not prevent invocation (got: $(cat "$CAPTURE_FILE")"
fi
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_hf_cache: missing script/venv degrades to SKIP, never errors (wa-9eh0v) ==="
# A fresh checkout without the recall-venv built yet (or a future refactor
# that moves hf_cache_reap.py) must never crash the guard cycle — same
# defensive contract as _reap_dead_scratch's [ ! -f "$reaper" ] check.
FAKE_CITY_H="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city.XXXXXX)"
REAL_CITY="$CITY"; CITY="$FAKE_CITY_H"
if _reap_hf_cache 1; then
  ok "_reap_hf_cache: missing script AND missing venv — returns cleanly (no crash)"
else
  bad "_reap_hf_cache: missing script/venv should still return 0, got nonzero"
fi
CITY="$REAL_CITY"
rm -rf "$FAKE_CITY_H"

echo ""
echo "=== _reap_growing_logs: production sentinel wiring (ga-dnc2m) ==="
# Same proof as _reap_dead_scratch/_reap_dead_transcripts above, for the 4th
# lever: log-reaper.sh's own header names _reap_growing_logs as the ONLY
# allowed setter of LOG_REAPER_PROD=1. Hermetic: CITY is a plain global (not
# readonly), reassigned here to a disposable tmp dir containing a FAKE
# log-reaper.sh that only records what env it received — never touches the
# real log-reaper.sh, no real file truncation.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city4.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/log-reaper.sh" <<EOF
#!/bin/bash
echo "PROD=\${LOG_REAPER_PROD:-unset}" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/log-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
_reap_growing_logs
CITY="$REAL_CITY"

if [ -f "$CAPTURE_FILE" ] && grep -qx "PROD=1" "$CAPTURE_FILE"; then
  ok "_reap_growing_logs: sets LOG_REAPER_PROD=1 when invoking the real reaper (production opt-in wired)"
else
  bad "_reap_growing_logs: did NOT set LOG_REAPER_PROD=1 — real launchd path would silently dry-run forever (got: $([ -f "$CAPTURE_FILE" ] && cat "$CAPTURE_FILE" || echo 'capture file missing'))"
fi
rm -rf "$FAKE_CITY"

echo ""
echo "=== _reap_growing_logs: guard-level ENABLED kill switch (ga-dnc2m) ==="
# DOLT_DISK_FLOOR_GUARD_ENABLED=0 must skip this lever too, same as the other
# three — the header's "Kill switch" note says ALL FOUR reclaim actions.
FAKE_CITY="$(mktemp -d /tmp/dolt-disk-floor-guard-selftest-city5.XXXXXX)"
mkdir -p "$FAKE_CITY/scripts"
CAPTURE_FILE="$FAKE_CITY/capture.txt"
cat > "$FAKE_CITY/scripts/log-reaper.sh" <<EOF
#!/bin/bash
echo "CALLED" > "$CAPTURE_FILE"
exit 0
EOF
chmod +x "$FAKE_CITY/scripts/log-reaper.sh"

REAL_CITY="$CITY"
CITY="$FAKE_CITY"
ENABLED=0
_reap_growing_logs
# shellcheck disable=SC2034  # read by every _reap_* call and main() in later scenarios below
ENABLED=1
CITY="$REAL_CITY"
[ -f "$CAPTURE_FILE" ] && bad "_reap_growing_logs: ran the real log-reaper.sh despite ENABLED=0" || ok "_reap_growing_logs: ENABLED=0 skips this lever too (not just the other three)"
rm -rf "$FAKE_CITY"

echo ""
echo "=== main(): CRITICAL-latch across reclaim reclassification (gate-fix-1: GATE-FEEDBACK gate_run=ga-wisp-9b4hnh) ==="
# The pure-function tests above prove _should_notify is correct in ISOLATION.
# They do NOT exercise main() itself, which is where the actual bug lived:
# main() re-derives `class` from the POST-reclaim avail and (pre-fix) used
# that alone to decide the CRITICAL-only "always notify, mail Mayor" path —
# so a reclaim that recovered avail lost all memory that the cycle was ever
# CRITICAL. These tests call main() directly (still library-sourced, so it
# doesn't auto-run) with _avail_gb/_safe_reclaim/_reap_dead_scratch/NOTIFY/GC
# stubbed — no real df dependency, no real reclaim, no real scratchpad reap, no
# real notification or mail sent, and the state files are redirected to a
# throwaway tmp dir (never touches the real .gc/logs state).

STATE_TMP="/tmp/dolt-disk-floor-guard-selftest-state-$$"
mkdir -p "$STATE_TMP"
# shellcheck disable=SC2034  # read by _write_state() in the sourced script
STATE_DIR="$STATE_TMP"
STATE_EPOCH_FILE="$STATE_TMP/.last-notify"
STATE_AVAIL_FILE="$STATE_TMP/.last-notify-avail-gb"
# ga-q4cqr: MUST be redirected exactly like the two state files above — it was
# evaluated at SOURCE time against the real $CITY/.gc/logs (before this
# override runs), and _read_critical_sustain/_write_critical_sustain reference
# the variable by name at call time, so without this line every scenario below
# would read/write the REAL production sustain-count file instead of this
# disposable one (caught live: a first draft of this suite leaked a stray
# `.dolt-disk-floor-guard.critical-sustain-count` file into the real
# $CITY/.gc/logs before this redirect was added).
STATE_CRITICAL_SUSTAIN_FILE="$STATE_TMP/.critical-sustain-count"

# Canned avail-GB readings: main() calls _avail_gb exactly twice per cycle
# (pre-reclaim, then post-reclaim), both via `$(...)` command substitution —
# which forks a SUBSHELL, so a shell-variable/array queue popped inside
# _avail_gb would silently discard its own mutation on subshell exit (every
# call would keep re-reading the same first element). A FILE-backed queue
# survives across subshells since the pop is a real filesystem write, not
# in-memory shell state. Exhausting the queue returns "" (UNKNOWN) rather
# than erroring under `set -u`, so an unexpected extra call fails the
# assertion instead of aborting the whole selftest.
AVAIL_QUEUE_FILE="$STATE_TMP/.avail-queue"
queue_avail() { printf '%s\n' "$@" > "$AVAIL_QUEUE_FILE"; }
_avail_gb() {
  [ -s "$AVAIL_QUEUE_FILE" ] || { echo ""; return; }
  local v; v="$(head -n1 "$AVAIL_QUEUE_FILE")"
  tail -n +2 "$AVAIL_QUEUE_FILE" > "$AVAIL_QUEUE_FILE.tmp" 2>/dev/null || true
  mv "$AVAIL_QUEUE_FILE.tmp" "$AVAIL_QUEUE_FILE"
  echo "$v"
}
# _vm_swap_gb is real, hermetic (du -sk, read-only, already proven correct in
# isolation above) but STUBBED here anyway so these main()-scenario
# assertions don't depend on this host's actual VM-swap size at test time —
# a fixed, known value lets the log-line assertion below (Scenario A) check
# the EXACT logged number instead of merely "some number" (ga-sfj3i.2).
_vm_swap_gb() { echo "7"; }
# _top_rss_processes is real, hermetic (ps -Ao pid,rss,comm, read-only,
# already proven correct in isolation above) but STUBBED here anyway so
# main()-scenario assertions on log/mail content don't depend on this
# host's actual process table at test time — same rationale as the
# _vm_swap_gb stub immediately above (ga-sfj3i.3).
_top_rss_processes() { printf '%s\n' "51664 1925776 dolt" "11357 253072 claude"; }

# _safe_reclaim's own mechanics (gc dolt-cleanup --force, health probe) are
# EXECUTION code out of scope for this file (see section banner above) —
# stubbed as a no-op here too, same as every other main()-only side effect.
_safe_reclaim() { :; }

# _reap_dead_scratch is new (ga-02pnu): stubbed as a no-op for the SAME reason
# _safe_reclaim is — it's EXECUTION code (shells out to scratchpad-reaper.sh,
# which has its own independent selftest). REAP_CALLS proves main() actually
# invokes it as part of the reclaim step (integration wiring), without ever
# running the real reaper (no `gc session list`, no `rm -rf`, hermetic).
# REAP_LAST_ARG (ga-rjhfz) captures the was_critical arg main() passes, so a
# scenario below can prove the CRITICAL-latch value actually reaches this
# call, not just that the call happened.
REAP_CALLS=0
REAP_LAST_ARG=""
_reap_dead_scratch() { REAP_CALLS=$((REAP_CALLS+1)); REAP_LAST_ARG="${1:-}"; }

# _reap_dead_transcripts is new (ga-t1ub9), same reasoning: EXECUTION code
# (shells out to transcript-reaper.sh, which has its own independent unit +
# integration selftest) stubbed as a no-op here so main()'s WIRING is what
# gets proven, not the real reaper's file-deletion logic.
REAP_TRANSCRIPT_CALLS=0
_reap_dead_transcripts() { REAP_TRANSCRIPT_CALLS=$((REAP_TRANSCRIPT_CALLS+1)); }

# _reap_growing_logs is new (ga-dnc2m), same reasoning as the other two reap
# stubs: EXECUTION code (shells out to log-reaper.sh, which has its own
# independent selftest) stubbed as a no-op here so main()'s WIRING is what
# gets proven. REAP_LOGS_CALLS is checked in Scenario F below specifically
# BECAUSE it must behave differently from the other two — see that scenario.
REAP_LOGS_CALLS=0
_reap_growing_logs() { REAP_LOGS_CALLS=$((REAP_LOGS_CALLS+1)); }

# _reap_hf_cache is new (wa-9eh0v), same reasoning as the other reap stubs:
# EXECUTION code (shells out to hf_cache_reap.py via the recall-venv, which
# has its own dedicated wiring tests earlier in this file) stubbed as a
# no-op here so main()'s WIRING is what gets proven. REAP_HF_LAST_ARG mirrors
# REAP_LAST_ARG above — this lever also receives was_critical as $1, and
# Scenario E/E2 below prove it must be CALLED at all only when CRITICAL
# (unlike the other three, which run at WARN too).
REAP_HF_CALLS=0
REAP_HF_LAST_ARG=""
_reap_hf_cache() { REAP_HF_CALLS=$((REAP_HF_CALLS+1)); REAP_HF_LAST_ARG="${1:-}"; }

NOTIFY_CALLS=0; NOTIFY_LAST_PRIO=""; NOTIFY_LAST_MSG=""; NOTIFY_LAST_FORCE_PUSH=""
record_notify() {
  NOTIFY_CALLS=$((NOTIFY_CALLS+1))
  # ga-ff6t9: capture whether THIS call was force-pushed (env var set only
  # for the duration of this function call by the SUT's own
  # `NOTIFY_FORCE_PUSH=1 "$NOTIFY" ...` prefix — verified empirically that a
  # bash env-var prefix on a function call IS visible inside it and reverts
  # after). Read fresh every call so a later non-forced call doesn't inherit
  # a stale "1" from an earlier one.
  NOTIFY_LAST_FORCE_PUSH="${NOTIFY_FORCE_PUSH:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) NOTIFY_LAST_PRIO="$2"; shift 2 ;;
      # ga-sfj3i.3: capture the message text too (last positional arg wins,
      # same loop shape as before — -t's title value passes through here
      # too, but the actual message is genuinely the LAST token processed).
      *) NOTIFY_LAST_MSG="$1"; shift ;;
    esac
  done
}
# shellcheck disable=SC2034  # read by main() in the sourced script
NOTIFY=record_notify

GC_MAIL_CALLS=0; GC_MAIL_LAST_BODY=""
record_gc() {
  if [ "$1" = "mail" ] && [ "$2" = "send" ]; then
    GC_MAIL_CALLS=$((GC_MAIL_CALLS+1))
    GC_MAIL_LAST_BODY=""
    shift 2
    # ga-sfj3i.3: capture the -m body too, so scenarios can assert on the
    # actual diagnosis/RSS content mailed to the Mayor, not just the count.
    while [ $# -gt 0 ]; do
      case "$1" in
        -m) GC_MAIL_LAST_BODY="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
  fi
}
# shellcheck disable=SC2034  # read by main() in the sourced script
GC=record_gc

reset_capture() { NOTIFY_CALLS=0; NOTIFY_LAST_PRIO=""; NOTIFY_LAST_MSG=""; NOTIFY_LAST_FORCE_PUSH=""; GC_MAIL_CALLS=0; GC_MAIL_LAST_BODY=""; REAP_CALLS=0; REAP_LAST_ARG=""; REAP_TRANSCRIPT_CALLS=0; REAP_LOGS_CALLS=0; REAP_HF_CALLS=0; REAP_HF_LAST_ARG=""; }
seed_state() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_EPOCH_FILE"; else rm -f "$STATE_EPOCH_FILE"; fi
  if [ -n "$2" ]; then echo "$2" > "$STATE_AVAIL_FILE"; else rm -f "$STATE_AVAIL_FILE"; fi
}
# ga-q4cqr: seed/read the CRITICAL-mail sustain counter directly, so scenarios
# can set up "already N cycles into a streak" without needing N real main()
# calls, and can verify main() left the expected count behind afterward.
seed_critical_sustain() {
  if [ -n "$1" ]; then echo "$1" > "$STATE_CRITICAL_SUSTAIN_FILE"; else rm -f "$STATE_CRITICAL_SUSTAIN_FILE"; fi
}
read_critical_sustain_state() { [ -f "$STATE_CRITICAL_SUSTAIN_FILE" ] && cat "$STATE_CRITICAL_SUSTAIN_FILE" || echo ""; }

# Scenario A — repro path (a) from the GATE-FEEDBACK: CRITICAL (2GB) fully
# recovers to NONE (20GB) after reclaim. Pre-fix, main() hit the early return
# "back above floor after reclaim — no notify needed" and NEITHER notify nor
# mail-Mayor ever fired for a reading that was CRITICAL moments earlier.
# ga-q4cqr: mail is now sustain-gated (default threshold 2) — a single
# CRITICAL cycle notifies immediately (prio 5, unconditional per imp07) but
# must NOT yet mail; it should leave a pending count of 1 behind for the next
# cycle to potentially confirm. See Scenario A2 for the 2nd-cycle confirm.
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 2 20
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "0" ] && [ "$(read_critical_sustain_state)" = "1" ] && [ "$NOTIFY_LAST_FORCE_PUSH" = "1" ]; then
  ok "main(): CRITICAL avail fully recovered by reclaim still notifies (prio 5, force-push); mail debounced (pending 1/2)"
else
  bad "main(): CRITICAL->NONE recovery — notify/debounce/force-push wrong (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state) force_push='$NOTIFY_LAST_FORCE_PUSH')"
fi
if grep -q "vm_swap_gb=7" "$LOG" 2>/dev/null; then
  ok "main(): logs vm_swap_gb as its own metric line every cycle, not just on breach (ga-sfj3i.2)"
else
  bad "main(): expected a 'vm_swap_gb=7' log line this cycle, log contains: $(tr '\n' ';' < "$LOG" 2>/dev/null | tail -c 300)"
fi

# Scenario A2 — ga-q4cqr sustain confirm: a SECOND consecutive CRITICAL cycle
# (pending already 1 from a prior cycle) must confirm the streak and mail the
# Mayor this time, while notify keeps firing unconditionally every cycle
# regardless (same as before this bead — only mail is new/gated).
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2 20
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "1" ] && [ "$(read_critical_sustain_state)" = "2" ]; then
  ok "main(): 2nd consecutive CRITICAL cycle confirms sustain (2/2) — mails Mayor"
else
  bad "main(): 2nd consecutive CRITICAL cycle should confirm + mail (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state))"
fi

# Scenario A3 — ga-q4cqr streak reset: a non-critical cycle between two
# CRITICAL cycles must reset the sustain counter, so the second CRITICAL
# cycle (pending resets to 1, not 3) does NOT prematurely mail. Reuses
# Scenario D's readings (6 -> 20, fully resolved, non-critical) to perform
# the reset, then a fresh CRITICAL cycle.
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 6 20
main
if [ "$(read_critical_sustain_state)" != "0" ]; then
  bad "main(): non-critical cycle should reset sustain count to 0, got '$(read_critical_sustain_state)'"
else
  reset_capture
  queue_avail 2 20
  main
  if [ "$GC_MAIL_CALLS" = "0" ] && [ "$(read_critical_sustain_state)" = "1" ]; then
    ok "main(): sustain streak correctly reset by an intervening non-critical cycle (next CRITICAL starts back at 1/2, does not prematurely mail)"
  else
    bad "main(): streak reset didn't take — next CRITICAL cycle should start at 1/2 (mail_calls=$GC_MAIL_CALLS pending=$(read_critical_sustain_state))"
  fi
fi

# Scenario B — repro path (b), reviewer's exact numbers (WARN=8 CRIT=3
# cooldown=3600): CRITICAL (2GB) reclaims back to EXACTLY the WARN floor
# (8GB), within cooldown and not "worsening" vs. a last-notified avail of
# 8GB. Pre-fix, class was reclassified WARN post-reclaim and ordinary WARN
# cooldown/worsening suppression swallowed the CRITICAL-only mail-Mayor alert.
# ga-q4cqr: seeds sustain=1 explicitly (this cycle is the CONFIRMING 2nd) so
# this scenario stays self-contained/order-independent and keeps proving its
# original point — cooldown/worsening suppression must never swallow an
# already-sustain-confirmed CRITICAL mail — rather than accidentally passing
# on leftover state from whichever scenario happened to run before it.
reset_capture
past_epoch=$(( $(date +%s) - 600 ))
seed_state "$past_epoch" 8
seed_critical_sustain 1
queue_avail 2 8
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ] && [ "$GC_MAIL_CALLS" = "1" ] && [ "$NOTIFY_LAST_FORCE_PUSH" = "1" ]; then
  ok "main(): CRITICAL avail partially recovered into WARN tier still bypasses cooldown + mails Mayor + force-pushes (sustain already confirmed) — proves the force-push gate keys off was_critical, not the recomputed post-reclaim class"
else
  bad "main(): CRITICAL->WARN partial recovery lost the always-notify/mail-Mayor/force-push guarantee (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO mail_calls=$GC_MAIL_CALLS force_push='$NOTIFY_LAST_FORCE_PUSH')"
fi

# Scenario C — non-regression: a cycle that is NEVER critical (WARN both
# before and after reclaim) still respects ordinary cooldown + not-worsening
# suppression — proves the was_critical latch didn't make the guard noisier.
reset_capture
past_epoch=$(( $(date +%s) - 100 ))
seed_state "$past_epoch" 6
queue_avail 6 6
main
if [ "$NOTIFY_CALLS" = "0" ] && [ "$GC_MAIL_CALLS" = "0" ]; then
  ok "main(): non-critical WARN cycle within cooldown + not worsening still suppresses (no regression)"
else
  bad "main(): non-critical WARN suppression regressed (notify_calls=$NOTIFY_CALLS mail_calls=$GC_MAIL_CALLS)"
fi

# Scenario D — non-regression: a non-critical WARN cycle fully resolved by
# reclaim takes the early-return silent path, same as before the fix.
reset_capture; seed_state "" ""
queue_avail 6 20
main
if [ "$NOTIFY_CALLS" = "0" ] && [ "$GC_MAIL_CALLS" = "0" ]; then
  ok "main(): non-critical WARN fully resolved by reclaim stays silent (no regression)"
else
  bad "main(): non-critical WARN->NONE early-return regressed (notify_calls=$NOTIFY_CALLS mail_calls=$GC_MAIL_CALLS)"
fi

echo ""
echo "=== main(): VM-bound vs file-bound diagnosis (ga-sfj3i.3) ==="
# WHY: the real incident this bead exists for — the 4 reclaim levers ran,
# reclaimed ~0 bytes, and the guard said "reclaim OK — avail X -> X" while
# 15GB sat in /System/Volumes/VM. These scenarios prove the alert now
# distinguishes "cleanup will help" from "cleanup cannot help" instead of
# emitting the same text either way. Default VM_SIGNIFICANT_GB=2 throughout
# (not overridden).

# Scenario G — VM-bound CRITICAL: reclaim achieves nothing (2GB -> 2GB) AND
# vm_swap (stubbed 7GB, well above the 2GB threshold) is significant. Must
# say explicitly that cleanup will not help and name the GB figure — the
# bead's own item 2 wording.
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2 2
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "5" ]; then
  ok "main(): VM-bound CRITICAL still notifies unconditionally (prio 5)"
else
  bad "main(): VM-bound CRITICAL notify wrong (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO)"
fi
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*"7GB"*) ok "main(): VM-bound notify message states cleanup will not resolve it, with the GB figure" ;;
  *) bad "main(): VM-bound notify message missing the explicit non-resolution statement — got: $NOTIFY_LAST_MSG" ;;
esac
if [ "$GC_MAIL_CALLS" = "1" ]; then
  case "$GC_MAIL_LAST_BODY" in
    *"will NOT resolve"*"reducing RAM pressure"*"51664 1925776 dolt"*)
      ok "main(): VM-bound mail body states the RAM-pressure-only remedy AND includes the top-RSS listing" ;;
    *)
      bad "main(): VM-bound mail body missing diagnosis and/or RSS listing — got: $(printf '%s' "$GC_MAIL_LAST_BODY" | tr '\n' ';' | cut -c1-400)" ;;
  esac
else
  bad "main(): expected VM-bound CRITICAL (sustain already 1) to confirm and mail this cycle, GC_MAIL_CALLS=$GC_MAIL_CALLS"
fi
if grep -q "diagnosis:.*VM-bound\|diagnosis:.*NOT resolve" "$LOG" 2>/dev/null; then
  ok "main(): VM-bound diagnosis is logged for the permanent record"
else
  bad "main(): no VM-bound diagnosis line found in LOG"
fi

# Scenario H — file-bound CRITICAL: reclaim actually recovers a lot (2GB ->
# 20GB) while vm_swap is stubbed low (1GB, below the 2GB threshold). Must
# credit file cleanup, NOT claim virtual memory is the blocker — opposite
# remedies must not produce the same message (bead item 3).
reset_capture; seed_state "" ""; seed_critical_sustain 1
_vm_swap_gb() { echo "1"; }
queue_avail 2 20
main
_vm_swap_gb() { echo "7"; }   # restore default stub for later scenarios
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*) bad "main(): file-bound case wrongly claimed VM is the blocker — got: $NOTIFY_LAST_MSG" ;;
  *"recovered 18GB"*)   ok "main(): file-bound notify message credits file cleanup with the actual GB recovered" ;;
  *) bad "main(): file-bound notify message missing the recovered-GB framing — got: $NOTIFY_LAST_MSG" ;;
esac
case "$GC_MAIL_LAST_BODY" in
  *"will NOT resolve"*) bad "main(): file-bound mail body wrongly used the VM-bound framing" ;;
  *"cleanup worked"*)   ok "main(): file-bound mail body uses the file-cleanup-worked framing, not the VM one" ;;
  *) bad "main(): file-bound mail body missing the cleanup-worked framing — got: $(printf '%s' "$GC_MAIL_LAST_BODY" | tr '\n' ';' | cut -c1-400)" ;;
esac

# Scenario I — unresolved CRITICAL: reclaim achieves nothing (2GB -> 2GB) AND
# vm_swap (1GB) is below the significance threshold too. Neither known cause
# applies — must say so honestly rather than guessing one of the two.
reset_capture; seed_state "" ""; seed_critical_sustain 1
_vm_swap_gb() { echo "1"; }
queue_avail 2 2
main
_vm_swap_gb() { echo "7"; }   # restore default stub for later scenarios
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*|*"recovered"*) bad "main(): unresolved case wrongly claimed a specific known cause — got: $NOTIFY_LAST_MSG" ;;
  *"cause not identified"*)           ok "main(): unresolved case honestly states neither known cause applies" ;;
  *) bad "main(): unresolved notify message missing the honest-unknown framing — got: $NOTIFY_LAST_MSG" ;;
esac

# Scenario J — reclaim effect UNMEASURABLE (post-reclaim df read itself
# fails, e.g. a transient df hiccup): must say "could not measure", never
# silently fall back to claiming either specific cause on fabricated data
# (ga-p5q3 discipline extended to this new diagnosis).
reset_capture; seed_state "" ""; seed_critical_sustain 1
queue_avail 2   # only ONE reading queued — the post-reclaim _avail_gb call empties the queue and returns ""
main
case "$NOTIFY_LAST_MSG" in
  *"will NOT resolve"*|*"recovered"*|*"cause not identified"*) bad "main(): unmeasurable-reclaim case fabricated a specific diagnosis — got: $NOTIFY_LAST_MSG" ;;
  *"unmeasured"*) ok "main(): unmeasurable post-reclaim reading honestly says so, not a fabricated cause" ;;
  *) bad "main(): unmeasurable-reclaim notify message missing the honest-unmeasured framing — got: $NOTIFY_LAST_MSG" ;;
esac

# Scenario K (ga-ff6t9): a FRESH WARN-tier cycle (no prior state -> cooldown
# fail-open fires notify unconditionally on the first read) must NOT
# force-push. Mutation check on the fix above: force-push is reserved for the
# guaranteed-page CRITICAL tier (was_critical=1); a routine WARN notify is
# meant to keep going through notify's normal content-based routing (the
# established low-blast-radius pattern this codebase already uses for
# routine, non-emergency alerts). Without this negative control, a fix that
# accidentally force-pushed EVERY notify call (not just CRITICAL) would pass
# every other scenario in this file (none of them assert force-push is
# ABSENT) — same discipline as escalate_emergency.py's own T2 "unsanctioned
# class rejected" test.
reset_capture; seed_state "" ""; seed_critical_sustain ""
queue_avail 6 6
main
if [ "$NOTIFY_CALLS" = "1" ] && [ "$NOTIFY_LAST_PRIO" = "3" ] && [ -z "$NOTIFY_LAST_FORCE_PUSH" ]; then
  ok "main(): fresh WARN-tier notify (prio 3) does NOT force-push (scoped correctly to CRITICAL only)"
else
  bad "main(): WARN-tier force-push scoping regressed (notify_calls=$NOTIFY_CALLS prio=$NOTIFY_LAST_PRIO force_push='$NOTIFY_LAST_FORCE_PUSH')"
fi

echo ""
echo "=== main(): scratchpad + transcript reap integration (ga-02pnu, ga-t1ub9) ==="
# Scenario E — BOTH new reclaim levers must actually be wired into main()'s
# reclaim step (called alongside _safe_reclaim, before the post-reclaim avail
# re-read) on EVERY cycle that reaches the reclaim step at all — regardless of
# whether the outcome ends up CRITICAL, WARN-notify, or WARN-suppressed. Reuses
# scenario A's readings (CRITICAL -> recovers to NONE).
reset_capture; seed_state "" ""
queue_avail 2 20
main
if [ "$REAP_CALLS" = "1" ] && [ "$REAP_TRANSCRIPT_CALLS" = "1" ] && [ "$REAP_LOGS_CALLS" = "1" ] && [ "$REAP_HF_CALLS" = "1" ]; then
  ok "main(): _reap_dead_scratch, _reap_dead_transcripts, _reap_growing_logs, AND _reap_hf_cache each invoked exactly once alongside _safe_reclaim"
else
  bad "main(): expected all four reap levers called once, got REAP_CALLS=$REAP_CALLS REAP_TRANSCRIPT_CALLS=$REAP_TRANSCRIPT_CALLS REAP_LOGS_CALLS=$REAP_LOGS_CALLS REAP_HF_CALLS=$REAP_HF_CALLS"
fi
if [ "$REAP_LAST_ARG" = "1" ]; then
  ok "main(): CRITICAL cycle (even after reclaim recovers it to NONE) passes was_critical=1 to _reap_dead_scratch (ga-rjhfz pressure plumbing)"
else
  bad "main(): expected _reap_dead_scratch to receive was_critical=1 on a CRITICAL cycle, got REAP_LAST_ARG='$REAP_LAST_ARG'"
fi
if [ "$REAP_HF_LAST_ARG" = "1" ]; then
  ok "main(): CRITICAL cycle also passes was_critical=1 to _reap_hf_cache (wa-9eh0v)"
else
  bad "main(): expected _reap_hf_cache to receive was_critical=1 on a CRITICAL cycle, got REAP_HF_LAST_ARG='$REAP_HF_LAST_ARG'"
fi

# Scenario E2 (ga-rjhfz) — a cycle that is WARN, never CRITICAL, must pass
# was_critical=0 — the size-escape must not activate on ordinary WARN
# pressure. Reuses scenario C's readings (WARN both before and after).
reset_capture; seed_state "" ""
past_epoch=$(( $(date +%s) - 100 ))
seed_state "$past_epoch" 6
queue_avail 6 6
main
if [ "$REAP_LAST_ARG" = "0" ]; then
  ok "main(): non-critical WARN cycle passes was_critical=0 to _reap_dead_scratch (no size-escape)"
else
  bad "main(): expected _reap_dead_scratch to receive was_critical=0 on a WARN-only cycle, got REAP_LAST_ARG='$REAP_LAST_ARG'"
fi
if [ "$REAP_HF_CALLS" = "1" ] && [ "$REAP_HF_LAST_ARG" = "0" ]; then
  ok "main(): non-critical WARN cycle still calls _reap_hf_cache but with was_critical=0 (the CRITICAL-only gate lives INSIDE the real function, not in main()'s wiring — wa-9eh0v)"
else
  bad "main(): expected _reap_hf_cache called once with was_critical=0 on a WARN-only cycle, got REAP_HF_CALLS=$REAP_HF_CALLS REAP_HF_LAST_ARG='$REAP_HF_LAST_ARG'"
fi

# Scenario F — a cycle that never reaches the floor at all (avail comfortably
# above warn on the FIRST read) must take the top early-return and never touch
# the scratch/transcript/hf-cache reapers — proves none of those reap calls
# got hoisted above the floor check.
VM_LOG_PRE_COUNT=$(grep -c "vm_swap_gb=" "$LOG" 2>/dev/null || echo 0)
reset_capture; seed_state "" ""
queue_avail 20
main
if [ "$REAP_CALLS" = "0" ] && [ "$REAP_TRANSCRIPT_CALLS" = "0" ] && [ "$REAP_HF_CALLS" = "0" ]; then
  ok "main(): avail above floor on first read never invokes the scratch/transcript/hf-cache reapers"
else
  bad "main(): expected zero scratch/transcript/hf-cache reap calls when floor never breached, got REAP_CALLS=$REAP_CALLS REAP_TRANSCRIPT_CALLS=$REAP_TRANSCRIPT_CALLS REAP_HF_CALLS=$REAP_HF_CALLS"
fi
# ga-sfj3i.2: the exact case this acceptance criterion exists for — a cycle
# that never breaches ANY floor is precisely where the pre-fix guard logged
# nothing extra at all. Prove the vm_swap_gb line still fires here, by COUNT
# (not a bare grep -q, since $LOG accumulates across every scenario in this
# file and Scenario A already put one occurrence in it) — an unconditional
# line hoisted above the floor check must appear exactly once more.
VM_LOG_POST_COUNT=$(grep -c "vm_swap_gb=" "$LOG" 2>/dev/null || echo 0)
if [ "$VM_LOG_POST_COUNT" -eq $(( VM_LOG_PRE_COUNT + 1 )) ]; then
  ok "main(): vm_swap_gb still logs even when avail never breaches any floor (not silence — ga-sfj3i.2)"
else
  bad "main(): vm_swap_gb log line missing on a floor-never-breached cycle (pre=$VM_LOG_PRE_COUNT post=$VM_LOG_POST_COUNT)"
fi

# Scenario F2 (ga-dnc2m) — UNLIKE the two dead-session reapers just proven
# absent above, _reap_growing_logs must STILL run on this exact same
# comfortably-above-floor cycle — it is deliberately unconditional (see this
# file's own header note and the call site at the very top of main(), before
# the avail/class computation at all). This is the one assertion that
# actually distinguishes the 4th lever's behavior from the other three; if a
# future edit accidentally moves its call site below the floor check, this
# is what catches it.
if [ "$REAP_LOGS_CALLS" = "1" ]; then
  ok "main(): _reap_growing_logs runs even when avail never breaches the floor (unconditional, unlike the dead-session reapers)"
else
  bad "main(): _reap_growing_logs should run unconditionally every cycle, got REAP_LOGS_CALLS=$REAP_LOGS_CALLS"
fi

rm -rf "$STATE_TMP"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
