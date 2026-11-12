#!/usr/bin/env bash
# rig-formula-redirect-link.sh — ga-6pil72r.
#
# ## Contents
#   - Why
#   - Usage and exit codes
#
# ## Why
# bd resolves a formula from the rig's resolved beads dir, then from the checkout root's
# .beads/formulas/ (~/gt/.beads/formulas/ for every rig dir under ~/gt), then ~/.beads and
# $GT_ROOT. gc materializes rig-overrides/formulas/ into <rig>/.beads/formulas/, but a rig with a
# .beads/redirect (gastown, lexbh, marketing) resolves to mayor/rig/.beads, which has no formulas/,
# so bd falls through to ~/gt/.beads/formulas/. There the symlink for mol-witness-patrol pointed at
# the NATIVE pack formula, and those rigs poured the native patrol (measured 2026-11-12).
# This script keeps one symlink per override in rig-overrides/formulas/ in that shared directory:
#     ~/gt/.beads/formulas/<name>.formula.toml -> <city>/rig-overrides/formulas/<name>.toml
# That directory is local, untracked state (git-excluded), so the fix cannot live in a commit;
# this script is how it is recreated and how drift is found.
#
# ## Usage and exit codes
#   scripts/rig-formula-redirect-link.sh            report only (changes nothing)
#   scripts/rig-formula-redirect-link.sh --apply    point each link at its override
#   CITY_DIR=<dir> ROOT=<dir> ...                   another city / checkout root (the selftest does)
# 0 = every link points at its override (after --apply, every link was fixed or already right)
# 1 = a link is wrong or missing (report only), or a REAL file sits where the link goes (never
#     overwritten: --apply leaves it alone and still exits 1)
# 2 = could not tell: rig-overrides/formulas or <root>/.beads/formulas is not a directory (the
#     latter is never created here). Not "all fine": nothing was checked.
# Works under /bin/bash 3.2.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CITY_DIR="${CITY_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="${ROOT:-$(dirname "$CITY_DIR")}"
APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "usage: $0 [--apply]" >&2; exit 64 ;;
esac

SRC="$CITY_DIR/rig-overrides/formulas"
DST="$ROOT/.beads/formulas"
# vazio (a directory with no *.toml) -> nothing to link, exit 2 below (not "all fine");
# falhou/ilegível (not a directory) -> exit 2, nothing touched, and DST is never created.
[ -d "$SRC" ] || { echo "UNREADABLE: $SRC is not a directory"; exit 2; }
[ -d "$DST" ] || { echo "UNREADABLE: $DST is not a directory (not creating it)"; exit 2; }

rc=0
n=0
for f in "$SRC"/*.toml; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  n=$((n + 1))
  name="$(basename "$f" .toml)"
  want="$SRC/$name.toml"
  link="$DST/$name.formula.toml"
  if [ -L "$link" ]; then
    # vazio (readlink prints nothing) -> treated as wrong target and fixed/reported like any other
    cur="$(readlink "$link" 2>/dev/null)"
    if [ "$cur" = "$want" ]; then echo "ok      $name"; continue; fi
    label="WRONG  "; detail="$name: $link -> ${cur:-<unreadable>} (want $want)"
  elif [ -e "$link" ]; then
    echo "REFUSED $name: $link is a real file, not a symlink; left alone"
    rc=1
    continue
  else
    label="MISSING"; detail="$name: $link (want $want)"
  fi
  if [ "$APPLY" -eq 1 ]; then
    # ln -sfn replaces only the symlink (or creates it); a real file was refused above.
    if ln -sfn "$want" "$link" && [ "$(readlink "$link")" = "$want" ]; then
      echo "FIXED   $detail"
    else
      echo "FAILED  $detail"
      rc=1
    fi
  else
    echo "$label $detail"
    rc=1
  fi
done
[ "$n" -gt 0 ] || { echo "UNREADABLE: no *.toml in $SRC"; exit 2; }
exit "$rc"
