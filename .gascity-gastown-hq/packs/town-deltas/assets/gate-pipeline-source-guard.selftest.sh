#!/usr/bin/env bash
# gate-pipeline-source-guard.selftest.sh — ga-q4sadt
#
# `2>/dev/null || true` does NOT guard a bash `source`. `source`/`.` is a
# POSIX special builtin: when the target cannot be read, the shell
# terminates IMMEDIATELY — the trailing `|| true` (or an enclosing `if`) is
# never evaluated (measured on /bin/bash 3.2.57 — see
# framework-marker-labels-source-guard.selftest.sh, ga-vmn7kv, for the full
# writeup of this mechanism). Before this fix, 8 call sites across the core
# gate/dispatch pipeline sourced a sibling lib with an idiom that looked
# guarded but was not:
#
#   quality-gate-dispatcher.sh  — git-lock-hygiene.sh   (was [ -f ], not [ -r ])
#   quality-gate-dispatcher.sh  — quiet-hours-check.sh  (was [ -f ], not [ -r ])
#   quality-gate-dispatcher.sh  — quality-gate-guard.sh (was UNGUARDED)
#   story-delivery.sh           — quality-gate-guard.sh (was UNGUARDED)
#   pilot-dispatcher.sh         — quiet-hours-check.sh  (was UNGUARDED)
#   auto-refino-dispatcher.sh   — quiet-hours-check.sh  (was UNGUARDED)
#   refino-gate-dispatcher.sh   — quiet-hours-check.sh  (was UNGUARDED)
#   context-check-dispatcher.sh — quiet-hours-check.sh  (was UNGUARDED)
#
# quality-gate-dispatcher.sh IS the gate (no reviews or merges without it);
# story-delivery.sh is the delivery reconciler (merged beads never close
# without it); the other four are the dispatchers that decide what work
# runs at all. A briefly missing/unreadable sibling — the exact partial-
# deploy failure class this directory has hit before — would have killed
# EACH of them silently, before any log/warn call exists, every launchd
# cycle, with nothing anywhere explaining why.
#
# Each extraction below pulls the REAL guarded block out of the shipped
# file (anchored by line ranges, not a hand-copied paraphrase), so this
# test tracks the actual code instead of drifting from it — same discipline
# as the ga-vmn7kv template this file is modeled on.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-pipeline-source-guard-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "gate-pipeline-source-guard.selftest (ga-q4sadt)"

extract() {
  # $1=file $2=start-regex $3=end-regex
  sed -n "/$2/,/$3/p" "$SELF_DIR/$1" | grep -vE '^[[:space:]]*#'
}

# --- harness for a BASH_SOURCE-relative sibling (sibling lives next to the
# probe script itself; matches pilot/auto-refino/refino-gate/context-check's
# quiet-hours-check.sh sites and both quality-gate-guard.sh sites) ---
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

test_relative_site() {
  local label="$1" file="$2" start_re="$3" end_re="$4" sib_name="$5"
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
  printf 'true\n' > "$d2/$sib_name"
  chmod 000 "$d2/$sib_name"
  out2=$(run_probe "$idiom" "$d2")
  [ "$out2" = "REACHED" ] \
    && ok "$label: sibling UNREADABLE survives ([ -r ], not [ -f ]/bare)" \
    || bad "$label: sibling UNREADABLE killed execution (got: '${out2:-<empty>}')"

  local d3 out3
  d3=$(mktemp -d "$WORK/present.XXXXXX")
  printf 'true\n' > "$d3/$sib_name"
  out3=$(run_probe "$idiom" "$d3")
  [ "$out3" = "REACHED" ] \
    && ok "$label: sibling PRESENT still loads (guard did not make it permanently inert)" \
    || bad "$label: sibling PRESENT case broke (got: '${out3:-<empty>}')"
}

# --- harness for a GC_CITY-relative sibling (quality-gate-dispatcher.sh's
# git-lock-hygiene.sh and quiet-hours-check.sh sites resolve via
# ${GC_CITY}/<rel_path>, not BASH_SOURCE) ---
run_gc_city_probe() {
  local idiom="$1" dir="$2"
  cat > "$dir/probe.sh" <<EOF
#!/bin/bash
set -euo pipefail
GC_CITY="$dir"
$idiom
echo "REACHED"
EOF
  ( /bin/bash "$dir/probe.sh" 2>/dev/null )
}

test_gc_city_site() {
  local label="$1" file="$2" start_re="$3" end_re="$4" rel_path="$5"
  local idiom
  idiom="$(extract "$file" "$start_re" "$end_re")"
  if [ -z "$(printf '%s' "$idiom" | tr -d '[:space:]')" ]; then
    bad "$label: extracted an EMPTY block from $file (did the anchors move?)"
    return
  fi

  local d1 out1
  d1=$(mktemp -d "$WORK/gccity_missing.XXXXXX")
  out1=$(run_gc_city_probe "$idiom" "$d1")
  [ "$out1" = "REACHED" ] \
    && ok "$label: sibling MISSING survives (pre-fix: died before REACHED)" \
    || bad "$label: sibling MISSING killed execution (got: '${out1:-<empty>}')"

  local d2 out2
  d2=$(mktemp -d "$WORK/gccity_noread.XXXXXX")
  mkdir -p "$d2/$(dirname "$rel_path")"
  printf 'true\n' > "$d2/$rel_path"
  chmod 000 "$d2/$rel_path"
  out2=$(run_gc_city_probe "$idiom" "$d2")
  [ "$out2" = "REACHED" ] \
    && ok "$label: sibling UNREADABLE survives ([ -r ], not [ -f ])" \
    || bad "$label: sibling UNREADABLE killed execution (got: '${out2:-<empty>}')"

  local d3 out3
  d3=$(mktemp -d "$WORK/gccity_present.XXXXXX")
  mkdir -p "$d3/$(dirname "$rel_path")"
  printf 'true\n' > "$d3/$rel_path"
  out3=$(run_gc_city_probe "$idiom" "$d3")
  [ "$out3" = "REACHED" ] \
    && ok "$label: sibling PRESENT still loads (guard did not make it permanently inert)" \
    || bad "$label: sibling PRESENT case broke (got: '${out3:-<empty>}')"
}

echo ""
echo "-- quality-gate-dispatcher.sh --"
test_gc_city_site "git-lock-hygiene.sh source" "quality-gate-dispatcher.sh" \
  '^_GLH_SCRIPT=' '^unset _GLH_SCRIPT' "scripts/git-lock-hygiene.sh"
test_gc_city_site "quiet-hours-check.sh source" "quality-gate-dispatcher.sh" \
  '^_QHC_SCRIPT=' '^unset _QHC_SCRIPT' "packs/town-deltas/assets/quiet-hours-check.sh"
test_relative_site "quality-gate-guard.sh source" "quality-gate-dispatcher.sh" \
  '^_GATE_DISPATCHER_SELF_DIR=' '^unset _GATE_DISPATCHER_SELF_DIR' "quality-gate-guard.sh"

echo ""
echo "-- story-delivery.sh --"
test_relative_site "quality-gate-guard.sh source" "story-delivery.sh" \
  '^_STORY_DELIVERY_SELF_DIR=' '^unset _STORY_DELIVERY_SELF_DIR' "quality-gate-guard.sh"

echo ""
echo "-- pilot-dispatcher.sh --"
test_relative_site "quiet-hours-check.sh source" "pilot-dispatcher.sh" \
  '^_PILOT_QHC_SIB=' '^unset _PILOT_QHC_SIB' "quiet-hours-check.sh"

echo ""
echo "-- auto-refino-dispatcher.sh --"
test_relative_site "quiet-hours-check.sh source" "auto-refino-dispatcher.sh" \
  '^_AUTO_REFINO_QHC_SIB=' '^unset _AUTO_REFINO_QHC_SIB' "quiet-hours-check.sh"

echo ""
echo "-- refino-gate-dispatcher.sh --"
test_relative_site "quiet-hours-check.sh source" "refino-gate-dispatcher.sh" \
  '^_REFINO_GATE_QHC_SIB=' '^unset _REFINO_GATE_QHC_SIB' "quiet-hours-check.sh"

echo ""
echo "-- context-check-dispatcher.sh --"
test_relative_site "quiet-hours-check.sh source" "context-check-dispatcher.sh" \
  '^_CONTEXT_CHECK_QHC_SIB=' '^unset _CONTEXT_CHECK_QHC_SIB' "quiet-hours-check.sh"

echo ""
echo "gate-pipeline-source-guard.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
