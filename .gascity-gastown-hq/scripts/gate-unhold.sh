#!/usr/bin/env bash
# gate-unhold.sh — ga-6qbgy: clear ALL prefix-variant labels of a gate-veto
# family from a bead in ONE verified operation.
#
# THE BUG THIS EXISTS TO FIX: several guards in this city (quality-gate-guard.sh
# Step 5a, inflight-reclaim-guard.py, pilot-dispatcher.sh, gate-orphaned-label-
# watchdog.sh) treat a label like `gate:needs-human` as a PREFIX FAMILY —
# `gate:needs-human`, `gate:needs-human:technical`, `gate:needs-human:refused`,
# and any future sub-reason all trigger the same veto. But `bd label remove
# <id> <label>` only ever removes an EXACT name — there is no `bd`-native way
# to clear a whole family in one shot. An operator who removes the bare
# `gate:needs-human` label, then re-verifies BY EXACT NAME, sees a clean list
# and declares the veto cleared — while a sibling variant they never knew
# existed (e.g. `gate:needs-human:technical`) silently keeps vetoing. The
# verification the operator ran was incapable of detecting the state it was
# checking for. This happened for real on wa-vcd01 (2026-08-06): ~4h of
# blocked crew work plus a dead marker requiring manual resubmission.
#
# This script closes the gap WITHOUT touching `bd` itself (bd is a globally
# shared binary across the whole city — rebuilding/swapping it is out of a
# single dog's autonomous authority, same reasoning as the engine-rebuild
# refuse doctrine; see ga-vhyd). It composes only already-shipped `bd`
# primitives (`show --json`, `label remove`) in a loop, using the SAME
# bare-or-colon-suffixed matching rule the guards themselves use to VETO —
# so clearing is finally symmetric with matching.
#
# Usage:
#   gate-unhold.sh <bead-id> <prefix> [<prefix> ...]
#
# Examples:
#   gate-unhold.sh wa-vcd01 gate:needs-human
#   gate-unhold.sh wa-vcd01 gate:needs-human pilot:no-auto-dispatch
#
# For each <prefix>, removes every label on <bead-id> that equals the prefix
# exactly OR starts with "<prefix>:". Prints exactly what it removed, then
# RE-FETCHES the bead and fails loudly (non-zero exit) if any matching label
# survives — the same "prove the state you verified is the state you meant to
# verify" property that removing-by-exact-name broke.
#
# Exit codes: 0 = cleared and verified (or nothing matched); 1 = could not
# read the bead, or a matching label survived verification.
#
# Testability: `source`-able with GATE_UNHOLD_LIB_ONLY=1 to load
# matching_veto_labels()/gate_unhold_main() without executing against a live
# bead — see gate-unhold.selftest.sh.

set -euo pipefail

GC_CITY_DEFAULT="/Users/athos/gt/.gascity-gastown-hq"

# matching_veto_labels <space_sep_labels> <prefix>
# Echoes the space-joined subset of <labels> that equal <prefix> exactly OR
# start with "<prefix>:". Kept textually identical (by inspection) to
# quality-gate-guard.sh's function of the same name — both exist because
# shell scripts in this city cannot share a sourced library across process
# boundaries without adding a new coupling; if you change the matching rule
# here, change it there too.
matching_veto_labels() {
  local labels="$1" prefix="$2" lbl out=""
  for lbl in $labels; do
    case "$lbl" in
      "$prefix"|"$prefix":*)
        out="${out:+$out }$lbl" ;;
    esac
  done
  printf '%s' "$out"
}

# fetch_labels <bead-id> <gc-city> — echoes the bead's labels, space-joined.
# Tries `gc bd show` first (cross-rig authoritative), falls back to `bd -C`
# (HQ-local) — same fallback order quality-gate-guard.sh uses for BEAD_RAW.
fetch_labels() {
  local bead_id="$1" city="$2" raw=""
  raw=$(gc --city "$city" bd show "$bead_id" --json 2>/dev/null) || raw=""
  if [ -z "$raw" ]; then
    raw=$(bd -C "$city" show "$bead_id" --json 2>/dev/null) || raw=""
  fi
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null
}

gate_unhold_main() {
  local bead_id="${1:?usage: gate-unhold.sh <bead-id> <prefix> [<prefix> ...]}"
  shift
  local prefixes=("$@")
  if [ "${#prefixes[@]}" -eq 0 ]; then
    echo "usage: gate-unhold.sh <bead-id> <prefix> [<prefix> ...]" >&2
    return 2
  fi
  local city="${GC_CITY:-$GC_CITY_DEFAULT}"

  local before_labels
  if ! before_labels=$(fetch_labels "$bead_id" "$city"); then
    echo "gate-unhold: could not read bead $bead_id (gc bd show and bd -C both failed/empty)" >&2
    return 1
  fi

  local prefix matched lbl removed_any=0
  for prefix in "${prefixes[@]}"; do
    matched=$(matching_veto_labels "$before_labels" "$prefix")
    for lbl in $matched; do
      echo "gate-unhold: removing $lbl from $bead_id"
      bd -C "$city" label remove "$bead_id" "$lbl" -q
      removed_any=1
    done
  done

  if [ "$removed_any" = "0" ]; then
    echo "gate-unhold: no label on $bead_id matched (${prefixes[*]}) — nothing to do"
    return 0
  fi

  # Verify: re-fetch and confirm no matching label survives. This is the
  # step the original incident skipped — not out of carelessness, but
  # because exact-name re-verification is structurally unable to see a
  # sibling variant. Checking by the SAME prefix rule used to remove closes
  # that gap.
  local after_labels
  if ! after_labels=$(fetch_labels "$bead_id" "$city"); then
    echo "gate-unhold: removed labels but could not re-fetch $bead_id to verify — treat as UNVERIFIED, check manually" >&2
    return 1
  fi
  local residual=""
  for prefix in "${prefixes[@]}"; do
    matched=$(matching_veto_labels "$after_labels" "$prefix")
    [ -n "$matched" ] && residual="${residual:+$residual }$matched"
  done
  if [ -n "$residual" ]; then
    echo "gate-unhold: FAILED — still present on $bead_id after removal: $residual" >&2
    return 1
  fi

  echo "gate-unhold: verified clear — no label matching (${prefixes[*]}) remains on $bead_id"
  return 0
}

if [ -z "${GATE_UNHOLD_LIB_ONLY:-}" ]; then
  gate_unhold_main "$@"
fi
