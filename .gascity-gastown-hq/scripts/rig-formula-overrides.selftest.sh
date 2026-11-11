#!/usr/bin/env bash
# rig-formula-overrides.selftest.sh — ga-p8ip28d.
#
# ## Contents
#   - What it guards
#   - Checks (A-D) and mutants (M1-M5)
#   - Usage
#
# ## What it guards
# Each [[rigs]] in city.toml imports only the gastown pack; town-deltas is imported only at the
# city level. Without a formulas_dir line a rig's witness poured the NATIVE mol-witness-patrol, so
# the wisp-store guard of the override (ga-3v2n4) held on the HQ only. The fix is
#     formulas_dir = "rig-overrides/formulas"
# on every rig, where rig-overrides/formulas/ holds one RELATIVE symlink per override pointing at
# the single source in packs/town-deltas/formulas/.
# Measured 2026-11-11 on a throwaway city (full config): the 5 rigs resolve the override
# (3314 -> 3881 bytes, the city's own), `gc order list` and `gc formula list` identical, config valid.
# TRAP: gc reads <formulas_dir>/../orders as the rig's ORDER layer, so rig-overrides/ must NEVER get
# an orders/ sibling (formulas_dir inside the pack gave 174 orders instead of 84).
#
# ## Checks and mutants
#   A. every [[rigs]] block carries formulas_dir = "rig-overrides/formulas" (before its first
#      [rigs.*] sub-table, where TOML would no longer read it as a rig key)
#   B. rig-overrides/formulas/ is non-empty and holds ONLY relative symlinks, each resolving to a
#      regular file inside packs/town-deltas/formulas/ (a copy drifts; a dangling link silently
#      falls back to the native formula); mol-witness-patrol.toml is one of them
#   C. rig-overrides/ has no orders/ sibling (nor any entry besides formulas/)
#   D. no [[rigs]] points formulas_dir anywhere else (one layer, one place)
#   M1 a rig without the line -> A fails     M2 a copied file instead of a symlink -> B fails
#   M3 a dangling link -> B fails            M4 an orders/ sibling -> C fails
#   M5 formulas_dir pointing into the pack -> A/D fail
#
# ## Usage
#   scripts/rig-formula-overrides.selftest.sh          (against the city dir this script lives in)
#   CITY_DIR=<dir> scripts/rig-formula-overrides.selftest.sh   (another copy; mutants are built from it)
# Exit 0 = all green, 1 = a check or a mutant failed. Works under /bin/bash 3.2.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY_DIR="${CITY_DIR:-$(cd "$HERE/.." && pwd)}"
WANT='rig-overrides/formulas'
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

# rig_lines <city.toml>: prints one line per [[rigs]] ("<name>|<formulas_dir or ->"), nothing
# else. vazio (no [[rigs]]) -> prints nothing and check_a fails (a city with no rigs is not this
# city); falhou/ilegível (file missing) -> prints "UNREADABLE" and check_a fails.
rig_lines() {
  [ -r "$1" ] || { echo "UNREADABLE"; return 0; }
  awk '
    function flush() { if (inrig) print name "|" (fd == "" ? "-" : fd) }
    /^\[\[rigs\]\]/ { flush(); inrig = 1; keys = 1; name = "?"; fd = ""; next }
    /^\[/           { keys = 0; next }
    keys && /^name[ \t]*=/ {
      v = $0; sub(/^name[ \t]*=[ \t]*"/, "", v); sub(/".*$/, "", v); name = v; next
    }
    keys && /^formulas_dir[ \t]*=/ {
      v = $0; sub(/^formulas_dir[ \t]*=[ \t]*"/, "", v); sub(/".*$/, "", v); fd = v; next
    }
    END { flush() }
  ' "$1"
}

# check_a <city dir>: 0 when every rig carries the line and there is at least one rig.
check_a() {
  local out line n=0 badn=0
  out="$(rig_lines "$1/city.toml")"
  [ "$out" = "UNREADABLE" ] && { echo "city.toml unreadable"; return 1; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$((n + 1))
    [ "${line#*|}" = "$WANT" ] || { badn=$((badn + 1)); echo "rig ${line%%|*}: formulas_dir=${line#*|}"; }
  done <<EOF
$out
EOF
  [ "$n" -gt 0 ] || { echo "no [[rigs]] found"; return 1; }
  [ "$badn" -eq 0 ]
}

# check_b <city dir>: relative symlinks only, each resolving into packs/town-deltas/formulas/.
check_b() {
  local d="$1/$WANT" f tgt real src n=0 rc=0 saw_witness=0
  [ -d "$d" ] || { echo "$WANT missing"; return 1; }
  src="$(cd "$1/packs/town-deltas/formulas" 2>/dev/null && pwd -P)" || { echo "packs/town-deltas/formulas missing"; return 1; }
  for f in "$d"/* "$d"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=$((n + 1))
    [ -L "$f" ] || { echo "$(basename "$f"): not a symlink (a copy drifts)"; rc=1; continue; }
    tgt="$(readlink "$f")"
    case "$tgt" in /*) echo "$(basename "$f"): absolute target $tgt"; rc=1; continue ;; esac
    real="$(cd "$d" && cd "$(dirname "$tgt")" 2>/dev/null && pwd -P)/$(basename "$tgt")" || real=""
    case "$real" in
      "$src"/*) [ -f "$real" ] || { echo "$(basename "$f"): dangling -> $tgt"; rc=1; } ;;
      *) echo "$(basename "$f"): resolves outside packs/town-deltas/formulas ($tgt)"; rc=1 ;;
    esac
    [ "$(basename "$f")" = "mol-witness-patrol.toml" ] && saw_witness=1
  done
  [ "$n" -gt 0 ] || { echo "$WANT is empty"; return 1; }
  [ "$saw_witness" -eq 1 ] || { echo "mol-witness-patrol.toml not linked"; rc=1; }
  return "$rc"
}

# check_c <city dir>: nothing in rig-overrides/ but formulas/.
check_c() {
  local d="$1/rig-overrides" e rc=0
  [ -d "$d" ] || { echo "rig-overrides missing"; return 1; }
  for e in "$d"/* "$d"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$(basename "$e")" = "formulas" ] || { echo "unexpected entry rig-overrides/$(basename "$e") (orders/ becomes the rig's order layer)"; rc=1; }
  done
  return "$rc"
}

# check_d <city dir>: no formulas_dir other than WANT anywhere in city.toml (rigs or not).
check_d() {
  local lines rc offenders
  # vazio (grep rc 1: no formulas_dir at all) -> ok here, check_a is the one that demands the line;
  # falhou/ilegível (grep rc >= 2: file missing/unreadable) -> fail, never read as "no offenders".
  lines="$(grep -E '^[[:space:]]*formulas_dir[[:space:]]*=' "$1/city.toml" 2>&1)"
  rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -ge 2 ] && { echo "grep failed: $lines"; return 1; }
  offenders="$(printf '%s\n' "$lines" | grep -v -F "\"$WANT\"")"
  [ -z "$offenders" ] || { echo "$offenders"; return 1; }
  return 0
}

echo "== real city ($CITY_DIR)"
for c in a b c d; do
  if out="$(check_$c "$CITY_DIR")"; then ok "check $c"; else bad "check $c: $out"; fi
done

# --- mutants: a tiny copy of the three things the checks read, mutated one way each -------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rfo-selftest.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT # own mktemp dir, contents are this script'"'"'s copies only

fresh() { # fresh <name> -> copy of the real inputs in $TMP/<name>
  local m="$TMP/$1"
  mkdir -p "$m/packs/town-deltas/formulas" || return 1
  cp "$CITY_DIR/city.toml" "$m/city.toml" || return 1
  cp -R "$CITY_DIR/rig-overrides" "$m/rig-overrides" || return 1
  # the link targets: copy the files the real links point at (so a good copy resolves)
  local f
  for f in "$CITY_DIR"/rig-overrides/formulas/*; do
    [ -e "$f" ] && cp "$f" "$m/packs/town-deltas/formulas/$(basename "$f")"
  done
  echo "$m"
}

expect_fail() { # expect_fail <label> <check letter> <city dir>
  if out="$(check_"$2" "$3")"; then bad "$1: check $2 stayed GREEN (mutant survived)"; else ok "$1: check $2 fails ($(echo "$out" | head -1))"; fi
}

echo "== mutants"
if m="$(fresh m1)"; then
  # drop the line from the first rig that has it
  awk 'BEGIN{d=0} /^formulas_dir[ \t]*=/ && !d { d=1; next } { print }' "$m/city.toml" > "$m/city.toml.new" && mv "$m/city.toml.new" "$m/city.toml"
  expect_fail "M1 rig without the line" a "$m"
else bad "M1 setup"; fi

if m="$(fresh m2)"; then
  f="$m/rig-overrides/formulas/mol-witness-patrol.toml"
  cp "$m/packs/town-deltas/formulas/mol-witness-patrol.toml" "$f.copy" && mv "$f.copy" "$f"
  expect_fail "M2 copy instead of symlink" b "$m"
else bad "M2 setup"; fi

if m="$(fresh m3)"; then
  rm "$m/packs/town-deltas/formulas/mol-witness-patrol.toml"
  expect_fail "M3 dangling link" b "$m"
else bad "M3 setup"; fi

if m="$(fresh m4)"; then
  mkdir "$m/rig-overrides/orders"
  expect_fail "M4 orders/ sibling" c "$m"
else bad "M4 setup"; fi

if m="$(fresh m5)"; then
  sed 's#^formulas_dir = "rig-overrides/formulas"#formulas_dir = "packs/town-deltas/rig-formulas"#' "$m/city.toml" > "$m/city.toml.new" && mv "$m/city.toml.new" "$m/city.toml"
  expect_fail "M5 formulas_dir into the pack" a "$m"
  expect_fail "M5 formulas_dir into the pack" d "$m"
else bad "M5 setup"; fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
