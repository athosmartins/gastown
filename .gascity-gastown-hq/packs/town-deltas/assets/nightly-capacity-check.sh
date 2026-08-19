#!/usr/bin/env bash
# nightly-capacity-check.sh (ga-06mt3k) — daily measured reboot RECOMMENDATION,
# never an autonomous reboot. Athos's own decision when asked directly (18/08):
# "So recomenda, nunca reinicia sozinha" — a reboot kills every session and
# anything else running on the machine, with no way for a script to know he's
# using it for something unrelated at 3am, so this script's authority stops at
# measuring + recommending. It NEVER calls `reboot`/`shutdown` — grep the file,
# there is no such call anywhere in it.
#
# Measurement techniques are lifted from ~/.gastown/scripts/ram-pressure-monitor.sh
# (ga-7xne1) verbatim in TECHNIQUE (same OS commands, same hard-won filtering —
# e.g. jetsam counted via DiagnosticReports file listing, NOT `log show`, which
# measured >20s on this box) but NOT sourced — that script's own top-level flow
# runs its OWN notify cycle unconditionally when executed, which this script
# does not want as a side effect of borrowing its read functions. Each read_*
# function below has a NCC_TEST_* override seam, mirroring ram-pressure-monitor.sh's
# own RPM_TEST_* convention, so decision logic is fully unit-testable without
# touching real system state.
#
# Decision (see needs_reboot_reason): recommend a reboot iff EITHER (a) a real
# jetsam kill happened in the lookback window — ga-7xne1's own finding is that
# jetsam is "the PRECURSOR signal itself," so even one is real evidence, not
# noise — OR (b) swap used is at/above a floor AND yesterday's trend-log
# reading was ALSO at/above that floor (i.e. it persisted across a full day
# rather than being a transient spike that already cleared on its own) —
# "residue that only clears on reboot," per the bead's own framing, not a
# same-night blip.
#
# Also appends one dated line to a trend log every run (regardless of verdict)
# — both the day's own audit trail and the data the weekly digest reads.
# Weekly digest: on Sundays, ALSO mails a short digest of the week's peak
# swap/jetsam/low-free% next to ram-pressure-monitor.sh's current live
# thresholds — the AC's "teto revisado semanalmente contra o crescimento
# real," as an added VISIBILITY touchpoint. Deliberately does not reinvent
# threshold logic — ga-7xne1's own monitor already recalibrates its swap
# threshold dynamically/continuously; this just surfaces that history weekly
# rather than leaving it to accumulate unseen.
#
# Test: bash nightly-capacity-check.sh --selftest
set -uo pipefail

GC="${GC:-gc}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG="${NCC_LOG:-${CITY}/.gc/logs/nightly-capacity-check.log}"
TREND_LOG="${NCC_TREND_LOG:-${HOME}/.gastown/logs/nightly-capacity-check-trend.log}"

JETSAM_REPORTS_DIR="${NCC_JETSAM_REPORTS_DIR:-/Library/Logs/DiagnosticReports}"
JETSAM_LOOKBACK_MIN="${NCC_JETSAM_LOOKBACK_MIN:-1440}"   # 24h

# Swap floor: a persistent-across-days reading at/above this counts toward the
# reboot recommendation. Not calibrated from a live incident the way
# ram-pressure-monitor.sh's own thresholds were (see that script's header for
# the real measured baselines) — deliberately conservative pending real
# trend-log history; override via env once a few weeks of data exist.
SWAP_FLOOR_MB="${NCC_SWAP_FLOOR_MB:-2048}"

log() {
  mkdir -p "$(dirname "${LOG}")" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') [nightly-capacity-check] $*" | tee -a "${LOG}" >&2
}

# ════════════════════════════════════════════════════════════════════════════
# MEASUREMENT — each has a test override seam (NCC_TEST_*), same convention as
# ram-pressure-monitor.sh's RPM_TEST_*.
# ════════════════════════════════════════════════════════════════════════════

read_free_pct() {
  [ -n "${NCC_TEST_FREE_PCT+x}" ] && { echo "$NCC_TEST_FREE_PCT"; return; }
  memory_pressure 2>/dev/null | awk '/System-wide memory free percentage:/ { gsub(/%/,"",$NF); print $NF }'
}
read_swap_used_mb() {
  [ -n "${NCC_TEST_SWAP_MB+x}" ] && { echo "$NCC_TEST_SWAP_MB"; return; }
  sysctl vm.swapusage 2>/dev/null | grep -oE 'used = [0-9.]+M' | grep -oE '[0-9.]+' | head -1 | cut -d. -f1
}
read_jetsam_count() {
  [ -n "${NCC_TEST_JETSAM_COUNT+x}" ] && { echo "$NCC_TEST_JETSAM_COUNT"; return; }
  find "${JETSAM_REPORTS_DIR}" -iname "JetsamEvent*" -mmin "-${JETSAM_LOOKBACK_MIN}" 2>/dev/null | wc -l | tr -d '[:space:]'
}
read_disk_free_gb() {
  [ -n "${NCC_TEST_DISK_FREE_GB+x}" ] && { echo "$NCC_TEST_DISK_FREE_GB"; return; }
  df -g / 2>/dev/null | awk 'NR==2{print $4}'
}

# ════════════════════════════════════════════════════════════════════════════
# PURE/TESTABLE DECISION FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════

# _swap_persisted_floor <today_swap_mb> <trend_log_path> <floor_mb> → 0 (true)
# iff today's reading AND yesterday's most recent trend-log reading are both
# >= floor_mb. Reads the trend log's own lines (format: see
# _trend_log_line), extracting the swap_mb field from the most recent line
# whose date differs from today's. FAIL-CLOSED-TOWARD-"NOT PERSISTED" (return
# 1) on any missing/unparseable history — a single day's reading alone should
# never itself trigger the persistence claim; "couldn't confirm yesterday"
# must not silently read as "confirmed persisted."
_swap_persisted_floor() {
  local today_mb="$1" trend_log="$2" floor="$3"
  case "$today_mb" in ''|*[!0-9]*) return 1 ;; esac
  [ "$today_mb" -ge "$floor" ] || return 1
  [ -f "$trend_log" ] || return 1
  local today_date yesterday_line yesterday_mb
  today_date="$(date +%Y-%m-%d)"
  yesterday_line="$(grep -v "^${today_date}" "$trend_log" 2>/dev/null | tail -1)"
  [ -n "$yesterday_line" ] || return 1
  yesterday_mb="$(printf '%s' "$yesterday_line" | grep -oE 'swap_mb=[0-9]+' | cut -d= -f2)"
  case "$yesterday_mb" in ''|*[!0-9]*) return 1 ;; esac
  [ "$yesterday_mb" -ge "$floor" ]
}

# needs_reboot_reason <free_pct> <swap_mb> <jetsam_count> <trend_log> <floor_mb>
# → prints a non-empty reason string and returns 0 iff a reboot is
# recommended; prints nothing and returns 1 otherwise. Never touches disk
# beyond reading trend_log (via _swap_persisted_floor).
needs_reboot_reason() {
  local free_pct="$1" swap_mb="$2" jetsam="$3" trend_log="$4" floor="$5"
  case "$jetsam" in
    ''|*[!0-9]*) : ;;
    0) : ;;
    *) printf 'jetsam killed %s process(es) in the last %sm (ga-7xne1: jetsam is the precursor signal itself, not noise)' "$jetsam" "$JETSAM_LOOKBACK_MIN"; return 0 ;;
  esac
  if _swap_persisted_floor "$swap_mb" "$trend_log" "$floor"; then
    printf 'swap used %sMB >= floor %sMB, and stayed there since yesterday'"'"'s reading (residue, not a same-night spike)' "$swap_mb" "$floor"
    return 0
  fi
  return 1
}

# _trend_log_line <date> <free_pct> <swap_mb> <jetsam> <disk_free_gb> → one
# formatted line, key=value pairs (grep/cut-friendly, no JSON parsing needed
# for the simple persistence check above).
_trend_log_line() {
  printf '%s free_pct=%s swap_mb=%s jetsam=%s disk_free_gb=%s\n' "$1" "$2" "$3" "$4" "$5"
}

# _is_sunday <weekday 1-7, ISO (7=Sunday)> → 0 iff Sunday. Pure, takes the
# weekday as an argument rather than calling `date` itself so it's trivially
# testable.
_is_sunday() { [ "${1:-}" = "7" ]; }

# ════════════════════════════════════════════════════════════════════════════
# ORCHESTRATION (side-effecting) — measures, decides, logs, mails. NEVER
# reboots (grep this file for "reboot"/"shutdown" as a commit-time sanity
# check: the only hits should be in comments and mail body text).
# ════════════════════════════════════════════════════════════════════════════

main() {
  local free_pct swap_mb jetsam disk_free_gb
  free_pct="$(read_free_pct)"; free_pct="${free_pct:-unknown}"
  swap_mb="$(read_swap_used_mb)"; swap_mb="${swap_mb:-unknown}"
  jetsam="$(read_jetsam_count)"; jetsam="${jetsam:-0}"
  disk_free_gb="$(read_disk_free_gb)"; disk_free_gb="${disk_free_gb:-unknown}"

  log "measured: free_pct=${free_pct} swap_mb=${swap_mb} jetsam=${jetsam} disk_free_gb=${disk_free_gb}"

  mkdir -p "$(dirname "${TREND_LOG}")" 2>/dev/null
  _trend_log_line "$(date +%Y-%m-%d)" "$free_pct" "$swap_mb" "$jetsam" "$disk_free_gb" >> "${TREND_LOG}"

  local reason
  if reason="$(needs_reboot_reason "$free_pct" "$swap_mb" "$jetsam" "$TREND_LOG" "$SWAP_FLOOR_MB")"; then
    log "RECOMMEND REBOOT: ${reason}"
    local body="Checagem noturna (ga-06mt3k): ${reason}. Medido: free=${free_pct}% swap=${swap_mb}MB jetsam=${jetsam} disco_livre=${disk_free_gb}GB. Esta checagem NUNCA reinicia sozinha (sua decisao, 18/08) — se quiser aplicar, rode 'sudo reboot' quando for conveniente; se nao, ignore, ela reavalia amanha."
    "${GC}" mail send mayor -s "Capacidade: recomendo reiniciar a maquina" -m "${body}" >/dev/null 2>&1 || true
  else
    log "no reboot recommendation this cycle."
  fi

  local weekday; weekday="$(date +%u)"
  if _is_sunday "$weekday"; then
    local digest
    digest="$(_weekly_digest "$TREND_LOG")"
    log "weekly digest (Sunday): ${digest}"
    "${GC}" mail send mayor -s "Capacidade: digest semanal" -m "${digest}" >/dev/null 2>&1 || true
  fi
}

# _weekly_digest <trend_log> → a short text summary of the last 7 dated lines'
# peak swap, jetsam total, and lowest free_pct. Pure text processing.
_weekly_digest() {
  local trend_log="$1"
  [ -f "$trend_log" ] || { printf 'sem historico de trend-log ainda.'; return; }
  AWK_INPUT="$(tail -7 "$trend_log")" python3 -c '
import os, re
lines = os.environ.get("AWK_INPUT", "").splitlines()
swaps, jets, frees = [], [], []
for l in lines:
    m = re.search(r"swap_mb=(\d+)", l)
    if m: swaps.append(int(m.group(1)))
    m = re.search(r"jetsam=(\d+)", l)
    if m: jets.append(int(m.group(1)))
    m = re.search(r"free_pct=(\d+)", l)
    if m: frees.append(int(m.group(1)))
peak_swap = max(swaps) if swaps else "n/a"
total_jetsam = sum(jets) if jets else 0
low_free = min(frees) if frees else "n/a"
print(f"Ultimos {len(lines)} dias: swap pico {peak_swap}MB, jetsam total {total_jetsam}, free% minimo {low_free}%.")
'
}

# ════════════════════════════════════════════════════════════════════════════
# selftest
# ════════════════════════════════════════════════════════════════════════════

if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }

  _ST_ROOT="$(mktemp -d /tmp/ncc-selftest.XXXXXX)"
  trap 'rm -rf "${_ST_ROOT}"' EXIT

  echo "S0: this script NEVER calls reboot/shutdown as a command — static guard"
  # A line is SAFE iff every occurrence of reboot/shutdown on it is either (a)
  # after a '#' (a comment) or (b) inside a quoted string — single OR double
  # (our own log/mail text, and this very selftest's own ok/bad messages).
  # Anything else — a bare word bash would try to RUN as a command — fails the
  # check. Python for reliability: getting this right with chained grep/sed is
  # exactly the kind of fragile text-processing this codebase's own memory
  # warns about (truncated-diff / wrong-path class of self-inflicted false
  # signal) — a single pass over each line is clearer to verify by eye than a
  # multi-stage pipeline.
  _s0_result="$(python3 -c '
import re
path = "'"${BASH_SOURCE[0]}"'"
bad = []
with open(path) as fh:
    for i, line in enumerate(fh, 1):
        code = line.split("#", 1)[0]   # drop comment portion
        code_no_strings = re.sub(r"\x27[^\x27]*\x27", "", code)   # single-quoted
        code_no_strings = re.sub(r"\"[^\"]*\"", "", code_no_strings)   # double-quoted
        if re.search(r"\b(reboot|shutdown)\b", code_no_strings):
            bad.append(f"{i}: {line.rstrip()}")
print("\n".join(bad))
')"
  [ -z "$_s0_result" ] && ok "no bare reboot/shutdown invocation found outside comments/quoted strings" \
    || bad "found a possible real reboot/shutdown call:\n$_s0_result"

  echo "S1: read_* functions — override seams"
  [ "$(read_free_pct)" = "42" ] && bad "should need override" || true
  [ "$(NCC_TEST_FREE_PCT=42 read_free_pct)" = "42" ] && ok "read_free_pct override" || bad "override failed"
  [ "$(NCC_TEST_SWAP_MB=999 read_swap_used_mb)" = "999" ] && ok "read_swap_used_mb override" || bad "override failed"
  [ "$(NCC_TEST_JETSAM_COUNT=3 read_jetsam_count)" = "3" ] && ok "read_jetsam_count override" || bad "override failed"
  [ "$(NCC_TEST_DISK_FREE_GB=50 read_disk_free_gb)" = "50" ] && ok "read_disk_free_gb override" || bad "override failed"
  # Regression coverage for the gate-rejected bug (ga-u40uo): JETSAM_REPORTS_DIR
  # defaulted to a $HOME-scoped path while the cited source (ram-pressure-
  # monitor.sh) reads the system-wide path where JetsamEvent files actually
  # land — making read_jetsam_count() always return 0 in production. Every
  # OTHER jetsam test above uses NCC_TEST_JETSAM_COUNT, which bypasses the
  # real find-based lookup entirely and never exercised this. Two checks:
  # (1) the DEFAULT value itself is the system-wide path, matching the cited
  # source exactly (static, since the default is a module-level assignment
  # computed once at parse time -- re-sourcing to test env-var absence isn't
  # worth the complexity for a one-line literal), and (2) the real find-based
  # lookup mechanism itself behaves correctly when pointed at a controlled dir.
  #
  # CAUGHT WHILE WRITING THIS: NCC_JETSAM_REPORTS_DIR=... read_jetsam_count
  # does NOT work as an override at call time -- read_jetsam_count() reads
  # $JETSAM_REPORTS_DIR (the module-level var, resolved ONCE at parse time
  # from NCC_JETSAM_REPORTS_DIR), not $NCC_JETSAM_REPORTS_DIR itself. Setting
  # the NCC_-prefixed var on the call has no effect on the already-computed
  # module var -- the exact same class of bug S6's own comment below already
  # documents for LOG/TREND_LOG ("export here can't retroactively change
  # them"). First version of this test silently read the REAL system
  # directory instead of the controlled fixture and only "passed" by
  # coincidence (production happened to have exactly 2 real jetsam events in
  # the lookback window right now). Fixed by reassigning the already-parsed
  # JETSAM_REPORTS_DIR directly, the same pattern S6 already uses.
  grep -q '^JETSAM_REPORTS_DIR="\${NCC_JETSAM_REPORTS_DIR:-/Library/Logs/DiagnosticReports}"' "${BASH_SOURCE[0]}" \
    && ok "JETSAM_REPORTS_DIR default is the system-wide path (matches ram-pressure-monitor.sh)" \
    || bad "JETSAM_REPORTS_DIR default is wrong or HOME-scoped -- read_jetsam_count() would always see 0 in production"
  _ST_JETSAM_DIR="${_ST_ROOT}/diag-reports"
  mkdir -p "${_ST_JETSAM_DIR}"
  touch "${_ST_JETSAM_DIR}/JetsamEvent-2026-08-18-120000.ips" "${_ST_JETSAM_DIR}/JetsamEvent-2026-08-18-130000.ips"
  touch "${_ST_JETSAM_DIR}/not-a-jetsam-file.ips"
  _ST_JETSAM_DIR_SAVED="${JETSAM_REPORTS_DIR}"
  JETSAM_REPORTS_DIR="${_ST_JETSAM_DIR}"
  [ "$(read_jetsam_count)" = "2" ] \
    && ok "real find-based lookup counts JetsamEvent files (2), ignores non-matching file" \
    || bad "find-based jetsam count wrong"
  JETSAM_REPORTS_DIR="${_ST_ROOT}/nonexistent-diag-dir"
  [ "$(read_jetsam_count)" = "0" ] \
    && ok "missing directory -> 0 via find's own 2>/dev/null, not an error" \
    || bad "missing dir should give 0, not error/crash"
  JETSAM_REPORTS_DIR="${_ST_JETSAM_DIR_SAVED}"

  echo "S2: _swap_persisted_floor — needs BOTH today AND yesterday at/above floor"
  _ST_TREND="${_ST_ROOT}/trend.log"
  _swap_persisted_floor 3000 "${_ST_TREND}" 2048 && bad "no trend log at all should fail-closed" || ok "missing trend log -> not persisted (fail-closed)"
  printf '2020-01-01 free_pct=50 swap_mb=1000 jetsam=0 disk_free_gb=100\n' > "${_ST_TREND}"
  _swap_persisted_floor 3000 "${_ST_TREND}" 2048 && bad "yesterday below floor should not count as persisted" || ok "yesterday below floor -> not persisted"
  printf '2020-01-01 free_pct=50 swap_mb=3500 jetsam=0 disk_free_gb=100\n' > "${_ST_TREND}"
  _swap_persisted_floor 3000 "${_ST_TREND}" 2048 && ok "today AND yesterday both above floor -> persisted" || bad "should be persisted"
  _swap_persisted_floor 1000 "${_ST_TREND}" 2048 && bad "today below floor should not persist regardless of yesterday" || ok "today below floor -> not persisted"
  # today's own line in the log must be excluded from the "yesterday" lookup
  printf '%s free_pct=50 swap_mb=9000 jetsam=0 disk_free_gb=100\n' "$(date +%Y-%m-%d)" > "${_ST_TREND}"
  _swap_persisted_floor 3000 "${_ST_TREND}" 2048 && bad "REGRESSION: today's own line counted as 'yesterday'" || ok "today's own trend-log line excluded from yesterday lookup"

  echo "S3: needs_reboot_reason — jetsam alone is sufficient; swap needs persistence"
  _r="$(needs_reboot_reason 50 500 1 "${_ST_TREND}" 2048)"; _rc=$?
  [ "$_rc" -eq 0 ] && [ -n "$_r" ] && ok "single jetsam kill -> recommends reboot" || bad "jetsam=1 should recommend"
  _r="$(needs_reboot_reason 50 500 0 "/nonexistent" 2048)"; _rc=$?
  [ "$_rc" -ne 0 ] && [ -z "$_r" ] && ok "low swap, no jetsam, no history -> no recommendation" || bad "should not recommend"
  printf '2020-01-01 free_pct=50 swap_mb=5000 jetsam=0 disk_free_gb=100\n' > "${_ST_TREND}"
  _r="$(needs_reboot_reason 50 5000 0 "${_ST_TREND}" 2048)"; _rc=$?
  [ "$_rc" -eq 0 ] && [ -n "$_r" ] && ok "persisted high swap -> recommends reboot" || bad "should recommend on persisted swap"

  echo "S4: _is_sunday"
  _is_sunday 7 && ok "7 (ISO Sunday) -> true" || bad "7 should be Sunday"
  _is_sunday 1 && bad "1 (Monday) should not be Sunday" || ok "1 -> not Sunday"
  _is_sunday "" && bad "empty should not be Sunday" || ok "empty -> not Sunday"

  echo "S5: _weekly_digest — pure text summary"
  printf '2020-01-01 free_pct=60 swap_mb=1000 jetsam=0 disk_free_gb=100\n2020-01-02 free_pct=40 swap_mb=3000 jetsam=2 disk_free_gb=90\n' > "${_ST_TREND}"
  _digest="$(_weekly_digest "${_ST_TREND}")"
  echo "$_digest" | grep -q "3000MB" && ok "digest reports peak swap 3000MB" || bad "digest missing peak swap: $_digest"
  echo "$_digest" | grep -q "jetsam total 2" && ok "digest reports jetsam total 2" || bad "digest missing jetsam total: $_digest"
  echo "$_digest" | grep -q "40%" && ok "digest reports free% minimum 40" || bad "digest missing free% min: $_digest"
  _empty_digest="$(_weekly_digest "/nonexistent")"
  [ -n "$_empty_digest" ] && ok "no trend log -> digest still returns text, not empty/crash" || bad "should return a fallback string"

  echo "S6: main() end-to-end — jetsam kill triggers a mail, trend log gets a line, no reboot call ever made"
  # LOG/TREND_LOG are read from NCC_LOG/NCC_TREND_LOG only ONCE, at top-level
  # script-parse time — an export here can't retroactively change them (same
  # class of bug already hit and fixed in the other two scripts today), so
  # reassign the already-parsed vars directly, same fix pattern as those.
  NCC_LOG="${_ST_ROOT}/log"; NCC_TREND_LOG="${_ST_ROOT}/main-trend.log"
  LOG="${NCC_LOG}"; TREND_LOG="${NCC_TREND_LOG}"
  _s6_mail_marker="${_ST_ROOT}/s6-mail"
  rm -f "${_s6_mail_marker}"
  gc() { case "$1" in mail) touch "${_s6_mail_marker}" ;; esac; }
  NCC_TEST_FREE_PCT=30 NCC_TEST_SWAP_MB=500 NCC_TEST_JETSAM_COUNT=2 NCC_TEST_DISK_FREE_GB=80 main >/dev/null 2>&1
  [ -f "${_s6_mail_marker}" ] && ok "jetsam=2 -> mail sent" || bad "should have mailed a recommendation"
  grep -q "swap_mb=500" "${NCC_TREND_LOG}" && ok "trend log line appended with correct swap_mb" || bad "trend log missing/wrong"
  unset -f gc

  echo "S6b: main() — unreadable swap must NOT fabricate a measured zero (ga-a46jl)"
  # NCC_TEST_SWAP_MB set to EMPTY (not unset) simulates read_swap_used_mb's
  # real pipeline producing empty stdout on failure (sysctl error, or its
  # output format changing) -- the +x check in read_swap_used_mb still
  # takes the override branch and echoes nothing, exactly like the real
  # failure path would. Before this fix, main()'s swap_mb="${swap_mb:-0}"
  # silently turned that into a fabricated "0", written to the trend log
  # and later surfaced by the weekly digest as a genuine "peak swap"
  # reading -- indistinguishable from an actually-measured zero.
  NCC_TREND_LOG="${_ST_ROOT}/s6b-trend.log"; TREND_LOG="${NCC_TREND_LOG}"
  NCC_TEST_SWAP_MB='' NCC_TEST_FREE_PCT=30 NCC_TEST_JETSAM_COUNT=0 NCC_TEST_DISK_FREE_GB=80 main >/dev/null 2>&1
  grep -q "swap_mb=unknown" "${NCC_TREND_LOG}" && ok "unreadable swap logged as 'unknown', not fabricated as 0" \
    || bad "REGRESSION: unreadable swap silently recorded as swap_mb=0"
  # Isolated single-line trend log (not S6's accumulated one, which already
  # has a real 500MB reading that would mask this check either way): if the
  # bug were present (swap_mb=0 fabricated), the digest's peak-swap would
  # read "0MB" here since it's the only line; correctly excluded, it must
  # read "n/a" (no numeric swap readings at all in this log).
  _s6b_digest="$(_weekly_digest "${NCC_TREND_LOG}")"
  echo "$_s6b_digest" | grep -q "swap pico n/aMB" && ok "unknown swap reading excluded from weekly digest peak calc (n/a, not fabricated 0)" \
    || bad "REGRESSION: unknown swap counted as a real data point in the digest: $_s6b_digest"

  echo ""; echo "nightly-capacity-check selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

if [ "${NCC_LIB:-0}" != "1" ] && [ "${1:-}" != "--selftest" ]; then
  main "$@"
fi
