#!/usr/bin/env bash
# dog-formula-source-guard.selftest.sh — ga-5a87qv
#
# `.`/source is a POSIX special builtin: when the target cannot be read, the
# shell terminates IMMEDIATELY under set -euo pipefail — this is the same
# mechanism ga-q4sadt fixed for the core gate/dispatch pipeline, applied here
# to 5 dog-formula scripts that dot-sourced a sibling with NO guard at all
# (not even a broken `|| true`):
#
#   wisp-compact.sh     — _bd_trace.sh
#   gate-sweep.sh        — _bd_trace.sh
#   orphan-sweep.sh      — _bd_trace.sh
#   digest-sweep.sh      — _bd_trace.sh
#   mol-dog-doctor.sh    — runtime.sh AND latency.sh (2 sites)
#
# A briefly missing/unreadable sibling would kill any of these dog formulas
# with a raw bash error and zero context, instead of a clear diagnosis.
#
# Each extraction below pulls the REAL guarded block out of the shipped
# file (anchored by line ranges, not a hand-copied paraphrase), so this
# test tracks the actual code instead of drifting from it.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dog-formula-source-guard-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "dog-formula-source-guard.selftest (ga-5a87qv)"

extract() {
  # $1=file $2=start-regex $3=end-regex
  sed -n "/$2/,/$3/p" "$SELF_DIR/$1" | grep -vE '^[[:space:]]*#'
}

run_probe() {
  local idiom="$1" dir="$2"
  cat > "$dir/probe.sh" <<EOF
#!/bin/bash
set -euo pipefail
$idiom
echo "REACHED"
EOF
  ( /bin/bash "$dir/probe.sh" 2>/dev/null )
}

# --- for the 4 _bd_trace.sh sites (sibling lives next to the probe itself) ---
test_bd_trace_site() {
  local label="$1" file="$2" start_re="$3" end_re="$4"
  local idiom
  idiom="$(extract "$file" "$start_re" "$end_re")"
  if [ -z "$(printf '%s' "$idiom" | tr -d '[:space:]')" ]; then
    bad "$label: extracted an EMPTY block from $file (did the anchors move?)"
    return
  fi

  local d1 out1
  d1=$(mktemp -d "$WORK/missing.XXXXXX")
  out1=$(run_probe "$idiom" "$d1")
  [ "$out1" = "REACHED" ] \
    && ok "$label: sibling MISSING survives (pre-fix: died before REACHED)" \
    || bad "$label: sibling MISSING killed execution (got: '${out1:-<empty>}')"

  local d2 out2
  d2=$(mktemp -d "$WORK/noread.XXXXXX")
  printf 'true\n' > "$d2/_bd_trace.sh"
  chmod 000 "$d2/_bd_trace.sh"
  out2=$(run_probe "$idiom" "$d2")
  [ "$out2" = "REACHED" ] \
    && ok "$label: sibling UNREADABLE survives" \
    || bad "$label: sibling UNREADABLE killed execution (got: '${out2:-<empty>}')"

  local d3 out3
  d3=$(mktemp -d "$WORK/present.XXXXXX")
  printf 'true\n' > "$d3/_bd_trace.sh"
  out3=$(run_probe "$idiom" "$d3")
  [ "$out3" = "REACHED" ] \
    && ok "$label: sibling PRESENT still loads (guard did not make it permanently inert)" \
    || bad "$label: sibling PRESENT case broke (got: '${out3:-<empty>}')"
}

# --- for mol-dog-doctor.sh's 2 GC_CITY_PATH-relative sites ---
run_gc_city_probe() {
  local idiom="$1" dir="$2"
  cat > "$dir/probe.sh" <<EOF
#!/bin/bash
set -euo pipefail
GC_CITY_PATH="$dir"
$idiom
echo "REACHED"
EOF
  ( /bin/bash "$dir/probe.sh" 2>/dev/null )
}

# ga-5a87qv (gate FAIL, run ga-zpj88y): for mol-dog-doctor.sh's two sites
# specifically, "survives" is the WRONG expectation — see the FATAL checks
# added right after each [ -r ] guard in the real file. dolt_sql() calls
# run_bounded (runtime.sh) inside `if ! dolt_sql ...; then`, a set -e
# EXEMPTED context; an undefined run_bounded there reads as "the Dolt query
# failed" and the script mails the Mayor a FALSE "Dolt server unreachable"
# escalation for what was actually a missing sibling script. now_ms()
# (latency.sh) is called unconditionally, so it WOULD crash correctly on its
# own — but with a bare "command not found" pointing at the wrong line, not
# a message naming the real missing dependency. Both sites now hard-exit
# with a FATAL message naming the actual undefined symbol, immediately after
# the guard, instead of letting either failure mode reach downstream code.
# This test extracts guard+check together (sed range, not a single grep
# line) and asserts the CORRECTED three-way contract: missing/unreadable →
# loud, correctly-attributed FATAL exit (not silent survival, not a
# misattributed error); present-and-actually-defines-the-symbol → normal
# REACHED.
run_gc_city_probe_capture_err() {
  local idiom="$1" dir="$2"
  cat > "$dir/probe.sh" <<EOF
#!/bin/bash
set -euo pipefail
GC_CITY_PATH="$dir"
$idiom
echo "REACHED"
EOF
  ( /bin/bash "$dir/probe.sh" 2>&1 )
}

test_mol_dog_doctor_site() {
  local label="$1" start_re="$2" rel_path="$3" symbol="$4"
  local idiom
  # ga-5a87qv fix2: '#' delimiter, not '/' — $start_re contains literal '/'
  # (dolt/assets/scripts/...), which collides with sed's default '/' address
  # delimiter (BSD sed: "command a expects \ followed by text").
  idiom="$(sed -n "\\#$start_re#,/^}\$/p" "$SELF_DIR/mol-dog-doctor.sh" | grep -vE '^[[:space:]]*#')"
  if [ -z "$(printf '%s' "$idiom" | tr -d '[:space:]')" ]; then
    bad "$label: could not extract the guard+FATAL-check block from mol-dog-doctor.sh (did it move?)"
    return
  fi

  local d1 out1
  d1=$(mktemp -d "$WORK/gccity_missing.XXXXXX")
  out1=$(run_gc_city_probe_capture_err "$idiom" "$d1")
  case "$out1" in
    *FATAL*"$symbol"*) ok "$label: sibling MISSING fails LOUDLY, correctly naming '$symbol' (not silent survival, not a misattributed downstream error)" ;;
    *REACHED*) bad "$label: sibling MISSING silently reached downstream code (ga-5a87qv gate-FAIL regression — should FATAL naming '$symbol', not survive)" ;;
    *) bad "$label: sibling MISSING produced an unattributed failure (got: '${out1:-<empty>}')" ;;
  esac

  local d2 out2
  d2=$(mktemp -d "$WORK/gccity_noread.XXXXXX")
  mkdir -p "$d2/$(dirname "$rel_path")"
  printf 'true\n' > "$d2/$rel_path"
  chmod 000 "$d2/$rel_path"
  out2=$(run_gc_city_probe_capture_err "$idiom" "$d2")
  case "$out2" in
    *FATAL*"$symbol"*) ok "$label: sibling UNREADABLE fails LOUDLY, correctly naming '$symbol'" ;;
    *REACHED*) bad "$label: sibling UNREADABLE silently reached downstream code (ga-5a87qv gate-FAIL regression)" ;;
    *) bad "$label: sibling UNREADABLE produced an unattributed failure (got: '${out2:-<empty>}')" ;;
  esac

  local d3 out3
  d3=$(mktemp -d "$WORK/gccity_present.XXXXXX")
  mkdir -p "$d3/$(dirname "$rel_path")"
  printf '%s() { :; }\n' "$symbol" > "$d3/$rel_path"
  out3=$(run_gc_city_probe_capture_err "$idiom" "$d3")
  [ "$out3" = "REACHED" ] \
    && ok "$label: sibling PRESENT and defines '$symbol' → reaches REACHED normally (guard did not make it permanently inert)" \
    || bad "$label: sibling PRESENT-and-defines-'$symbol' case broke (got: '${out3:-<empty>}')"
}

echo ""
echo "-- wisp-compact.sh --"
test_bd_trace_site "_bd_trace.sh source" "wisp-compact.sh" \
  '^__SCRIPT_DIR=' '^fi$'

echo ""
echo "-- gate-sweep.sh --"
test_bd_trace_site "_bd_trace.sh source" "gate-sweep.sh" \
  '^__SCRIPT_DIR=' '^fi$'

echo ""
echo "-- orphan-sweep.sh --"
test_bd_trace_site "_bd_trace.sh source" "orphan-sweep.sh" \
  'Trace bd invocations' '^fi$'

echo ""
echo "-- digest-sweep.sh --"
test_bd_trace_site "_bd_trace.sh source" "digest-sweep.sh" \
  '^__SCRIPT_DIR=' '^fi$'

echo ""
echo "-- mol-dog-doctor.sh --"
test_mol_dog_doctor_site "runtime.sh source" \
  '^\[ -r .*dolt/assets/scripts/runtime\.sh' ".gc/system/packs/dolt/assets/scripts/runtime.sh" "run_bounded"
test_mol_dog_doctor_site "latency.sh source" \
  '^\[ -r .*dolt/assets/scripts/latency\.sh' ".gc/system/packs/dolt/assets/scripts/latency.sh" "now_ms"

echo ""
echo "dog-formula-source-guard.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
