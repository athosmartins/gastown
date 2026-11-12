#!/usr/bin/env bash
# rig-formula-redirect-link.selftest.sh — ga-6pil72r.
#
# ## Contents
#   - What it guards
#   - Cases
#
# ## What it guards
# rig-formula-redirect-link.sh keeps ~/gt/.beads/formulas/<name>.formula.toml pointing at
# rig-overrides/formulas/<name>.toml. Each case builds a throwaway city + root and asserts the
# EFFECT on the link (readlink / file content), not only the exit code.
#
# ## Cases
#   1 wrong link, report only -> rc 1, link untouched   2 wrong link, --apply -> rc 0, fixed
#   3 already right -> rc 0, still the same link        4 real file in the way -> rc 1, content intact (both modes)
#   5 missing link, --apply -> created                  6 second --apply -> rc 0 (idempotent)
#   7 no <root>/.beads/formulas -> rc 2, nothing created   8 no rig-overrides/formulas -> rc 2
#   9 bad argument -> rc 64, nothing changed
#   10 --apply with a `ln` that fails after making the right link, and with a `readlink` that does not read it back -> FAILED, rc 1 (never FIXED on one of the two alone)
# Exit 0 = all green, 1 = a case failed. Works under /bin/bash 3.2.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/rig-formula-redirect-link.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rfrl-selftest.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT # own mktemp dir, contents are this script'"'"'s fixtures only

# fresh <name>: a city with one override and a root whose .beads/formulas holds a link to the NATIVE file.
fresh() {
  local d="$TMP/$1"
  mkdir -p "$d/city/rig-overrides/formulas" "$d/root/.beads/formulas" "$d/native" || return 1
  printf 'override\n' > "$d/city/rig-overrides/formulas/mol-x.toml" || return 1
  printf 'native\n' > "$d/native/mol-x.toml" || return 1
  ln -s "$d/native/mol-x.toml" "$d/root/.beads/formulas/mol-x.formula.toml" || return 1
  echo "$d"
}
run() { # run <fixture> [args] -> output in $OUT, rc in $RC
  local d="$1"; shift
  OUT="$(CITY_DIR="$d/city" ROOT="$d/root" bash "$TOOL" "$@" 2>&1)"
  RC=$?
}
link_of() { readlink "$1/root/.beads/formulas/mol-x.formula.toml" 2>/dev/null; }

if ! [ -f "$TOOL" ]; then bad "tool missing: $TOOL"; echo "== $PASS passed, $FAIL failed"; exit 1; fi

if d="$(fresh c1)"; then
  run "$d"
  if [ "$RC" -eq 1 ] && [ "$(link_of "$d")" = "$d/native/mol-x.toml" ]; then ok "1 wrong link, report only: rc 1, link untouched"; else bad "1 rc=$RC link=$(link_of "$d") out=$OUT"; fi
else bad "1 setup"; fi

if d="$(fresh c2)"; then
  run "$d" --apply
  if [ "$RC" -eq 0 ] && [ "$(link_of "$d")" = "$d/city/rig-overrides/formulas/mol-x.toml" ]; then ok "2 wrong link, --apply: fixed, rc 0"; else bad "2 rc=$RC link=$(link_of "$d") out=$OUT"; fi
  run "$d" --apply
  if [ "$RC" -eq 0 ] && [ "$(link_of "$d")" = "$d/city/rig-overrides/formulas/mol-x.toml" ]; then ok "6 second --apply: rc 0, same link (idempotent)"; else bad "6 rc=$RC link=$(link_of "$d") out=$OUT"; fi
  run "$d"
  if [ "$RC" -eq 0 ]; then ok "3 already right: report only rc 0"; else bad "3 rc=$RC out=$OUT"; fi
else bad "2/3/6 setup"; fi

if d="$(fresh c4)"; then
  rm "$d/root/.beads/formulas/mol-x.formula.toml" # fixture's own symlink
  printf 'precious\n' > "$d/root/.beads/formulas/mol-x.formula.toml"
  run "$d" --apply
  if [ "$RC" -eq 1 ] && [ "$(cat "$d/root/.beads/formulas/mol-x.formula.toml")" = "precious" ] && [ ! -L "$d/root/.beads/formulas/mol-x.formula.toml" ]; then ok "4 real file in the way: rc 1, content intact (--apply)"; else bad "4 apply rc=$RC out=$OUT"; fi
  run "$d"
  if [ "$RC" -eq 1 ] && [ "$(cat "$d/root/.beads/formulas/mol-x.formula.toml")" = "precious" ]; then ok "4 real file in the way: rc 1 (report only)"; else bad "4 report rc=$RC out=$OUT"; fi
else bad "4 setup"; fi

if d="$(fresh c5)"; then
  rm "$d/root/.beads/formulas/mol-x.formula.toml" # fixture's own symlink
  run "$d"
  if [ "$RC" -eq 1 ] && [ ! -e "$d/root/.beads/formulas/mol-x.formula.toml" ] && [ ! -L "$d/root/.beads/formulas/mol-x.formula.toml" ]; then ok "5 missing link, report only: rc 1, nothing created"; else bad "5 report rc=$RC out=$OUT"; fi
  run "$d" --apply
  if [ "$RC" -eq 0 ] && [ "$(link_of "$d")" = "$d/city/rig-overrides/formulas/mol-x.toml" ]; then ok "5 missing link, --apply: created"; else bad "5 apply rc=$RC link=$(link_of "$d") out=$OUT"; fi
else bad "5 setup"; fi

if d="$(fresh c7)"; then
  rm "$d/root/.beads/formulas/mol-x.formula.toml" # fixture's own symlink
  rmdir "$d/root/.beads/formulas" "$d/root/.beads" # fixture's own, now-empty dirs
  run "$d" --apply
  if [ "$RC" -eq 2 ] && [ ! -e "$d/root/.beads" ]; then ok "7 no <root>/.beads/formulas: rc 2, nothing created"; else bad "7 rc=$RC out=$OUT"; fi
else bad "7 setup"; fi

if d="$(fresh c8)"; then
  rm "$d/city/rig-overrides/formulas/mol-x.toml" # fixture's own file
  run "$d" --apply
  if [ "$RC" -eq 2 ] && [ "$(link_of "$d")" = "$d/native/mol-x.toml" ]; then ok "8 no override file: rc 2, link untouched"; else bad "8 rc=$RC link=$(link_of "$d") out=$OUT"; fi
  rmdir "$d/city/rig-overrides/formulas"
  run "$d" --apply
  if [ "$RC" -eq 2 ]; then ok "8 no rig-overrides/formulas dir: rc 2"; else bad "8b rc=$RC out=$OUT"; fi
else bad "8 setup"; fi

if d="$(fresh c9)"; then
  run "$d" --bogus
  if [ "$RC" -eq 64 ] && [ "$(link_of "$d")" = "$d/native/mol-x.toml" ]; then ok "9 bad argument: rc 64, nothing changed"; else bad "9 rc=$RC out=$OUT"; fi
else bad "9 setup"; fi

# 10: FIXED needs BOTH: `ln` exited 0 AND the link reads back as the override. A `ln` that reports failure after it made the right link, and a readback that does not match after a `ln`
# that exited 0, are each FAILED (rc 1). The scene with the real ln and readlink is case 2 (FIXED, rc 0). (ga-0co26ac: `ln ... && [ readlink = want ]` read as `||` was not caught)
if d="$(fresh c10)"; then
  mkdir -p "$d/bin"; REAL_LN="$(command -v ln)"
  printf '%s\n' '#!/bin/sh' "\"$REAL_LN\" \"\$@\"" 'exit 1' > "$d/bin/ln"; chmod +x "$d/bin/ln"
  OUT="$(PATH="$d/bin:$PATH" CITY_DIR="$d/city" ROOT="$d/root" bash "$TOOL" --apply 2>&1)"; RC=$?
  case "$OUT" in *"FAILED "*) FAILED_SAID=1 ;; *) FAILED_SAID=0 ;; esac; case "$OUT" in *"FIXED "*) FIXED_SAID=1 ;; *) FIXED_SAID=0 ;; esac
  if [ "$RC" -eq 1 ] && [ "$FAILED_SAID" -eq 1 ] && [ "$FIXED_SAID" -eq 0 ] && [ "$(link_of "$d")" = "$d/city/rig-overrides/formulas/mol-x.toml" ]; then ok "10 ln fails after making the link: FAILED, rc 1, not FIXED"; else bad "10 ln rc=$RC out=$OUT"; fi
else bad "10 setup"; fi
if d="$(fresh c10b)"; then
  mkdir -p "$d/bin"; printf '%s\n' '#!/bin/sh' 'echo /not/the/override' > "$d/bin/readlink"; chmod +x "$d/bin/readlink"
  OUT="$(PATH="$d/bin:$PATH" CITY_DIR="$d/city" ROOT="$d/root" bash "$TOOL" --apply 2>&1)"; RC=$?
  case "$OUT" in *"FAILED "*) FAILED_SAID=1 ;; *) FAILED_SAID=0 ;; esac; case "$OUT" in *"FIXED "*) FIXED_SAID=1 ;; *) FIXED_SAID=0 ;; esac
  if [ "$RC" -eq 1 ] && [ "$FAILED_SAID" -eq 1 ] && [ "$FIXED_SAID" -eq 0 ]; then ok "10 readback that does not match after a ln that exited 0: FAILED, rc 1, not FIXED"; else bad "10 readlink rc=$RC out=$OUT"; fi
else bad "10b setup"; fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
