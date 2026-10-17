#!/usr/bin/env bash
# jsonl-archive-repack-window-lib.sh (ga-wkoij7) — WHEN the jsonl-archive may be repacked as a whole, and WITH WHAT room. Source it; it defines functions only.
#
# WHY: 17/10 ~10:4x a plain `git commit` in the archive ran git's auto maintenance (`git maintenance run --auto --detach` = `git repack -d -l --geometric=2 --write-midx` on git 2.54)
# in the middle of the working day: pack-objects held 1.8GB of RAM, swap went to 5.2GB, free disk to 1.4GB. Athos decided (15/10) that the heavy maintenance of this city runs ONLY
# in the 00:00-06:00 window (everything must be up again by 06:00 — WhatsApp traffic starts at 07:00). Two things in this city can repack the archive as a whole, and both ask here:
#   - jsonl-export.sh, whose every commit would otherwise start git's own repack (commit_archive_snapshot): outside the window, or without room, the commit starts nothing;
#   - jsonl-archive-compact.sh, whose tier-2 consolidating `git gc` rewrites every pack.
# The bounded pieces stay as they are, on purpose: tier 1 (loose-objects batches, 5-200 objects, ~243MiB/h of loose blobs must be packed by day or the disk fills) and tier 2a (the tail
# repack of the SMALL packs only: `--keep-pack` on the big ones, at most 120 objects, pack.windowMemory 256m). Neither touches the big pack.
#
# THE RULE (jaw_repack_allowed): a whole-repo repack may START only when BOTH hold —
#   1. the local clock is in [JAW_START_H, JAW_LAST_START_H) = 00:00-04:59. The window is 00:00-06:00, but a repack that starts at 05:59 ends at 06:19 or later (19+ minutes under this
#      host's load, measured 10/10; a detached run cannot be stopped when the window closes), so the last START is 05:00 and a run has an hour. The clock that cannot be read = closed.
#   2. free disk on the archive's filesystem >= 2 x the largest pack + JAW_SWAP_KIB (2GiB). The 2 x is the rewrite of the biggest pack while the old one still stands; the 2GiB is the
#      swap headroom: macOS keeps its swap files on this same volume (vm.swapusage grew to 5.2GB in the incident and took the free space with it), so swap room IS disk room here.
#      The largest pack or the free space that cannot be read = closed: under doubt the inert state is NO repack — a missing repack costs a few extra small packs (the pack alarm in
#      jsonl-archive-compact.sh judges the end state, so it is never silent), a wrong one costs the disk.
# Both are checked at the START; nothing here stops a repack that is running. Every decision goes to stdout; the ones that matter (an allowed repack, and a refusal INSIDE the window — the
# night's repack that did not happen) also go to $JAW_LOG with a local timestamp and the swap in use, so "why did it not repack last night" has an answer. An outside-the-window refusal is
# the normal state of 20 hours a day, and is not written there.
#
# Seams: JAW_HOUR (0-23) stands in for the clock; the free space is the 2nd argument of jaw_repack_allowed, or JAW_FREE_KIB, or df.

JAW_START_H="${JAW_START_H:-0}"
JAW_LAST_START_H="${JAW_LAST_START_H:-5}"
JAW_SWAP_KIB="${JAW_SWAP_KIB:-2097152}"
JAW_LOG_MAX_LINES=2000
JAW_REASON=""

_jaw_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# jaw_hour — the local hour 0-23 as a plain decimal (no leading zero: "08" is not octal here), or nothing and rc 1 when the clock gives anything else.
jaw_hour() {
  local h
  if [ -n "${JAW_HOUR:-}" ]; then h="$JAW_HOUR"; else h="$(date +%H 2>/dev/null)"; fi
  _jaw_uint "$h" || return 1
  h=$((10#$h))
  [ "$h" -le 23 ] || return 1
  echo "$h"
}

# jaw_window_open — rc 0 when a whole-repo repack may START now, else rc 1 with JAW_REASON saying which side failed.
jaw_window_open() {
  local h
  if ! _jaw_uint "$JAW_START_H" || ! _jaw_uint "$JAW_LAST_START_H"; then
    JAW_REASON="window misconfigured (JAW_START_H='$JAW_START_H' JAW_LAST_START_H='$JAW_LAST_START_H') — closed"
    return 1
  fi
  if ! h="$(jaw_hour)"; then
    JAW_REASON="the local hour cannot be read — closed (under doubt no repack)"
    return 1
  fi
  if [ "$h" -ge "$JAW_START_H" ] && [ "$h" -lt "$JAW_LAST_START_H" ]; then
    JAW_REASON="local hour $h is inside the start window [$JAW_START_H,$JAW_LAST_START_H)"
    return 0
  fi
  JAW_REASON="local hour $h is outside the start window [$JAW_START_H,$JAW_LAST_START_H) (the maintenance window is 00:00-06:00)"
  return 1
}

# jaw_largest_pack_kib <gitdir> — KiB of the biggest *.pack under <gitdir>/objects/pack: 0 when there is no pack at all (a young repo), rc 1 when one exists and cannot be measured.
jaw_largest_pack_kib() {
  local p kib max=0
  for p in "$1"/objects/pack/*.pack; do
    [ -e "$p" ] || continue
    kib="$(du -k "$p" 2>/dev/null | awk '{print $1}')"
    _jaw_uint "$kib" || return 1
    [ "$kib" -gt "$max" ] && max="$kib"
  done
  echo "$max"
}

# jaw_free_kib <path> — free KiB on the filesystem holding <path>; empty when df says nothing usable.
jaw_free_kib() {
  if [ -n "${JAW_FREE_KIB:-}" ]; then echo "$JAW_FREE_KIB"; return 0; fi
  df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# jaw_swap_used — what the host says about swap, for the log only (the rule does not depend on it): "used=4092.44M" or "unknown".
jaw_swap_used() {
  local s
  s="$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*[KMG]\).*/\1/p')"
  if [ -n "$s" ]; then echo "used=$s"; else echo "unknown"; fi
}

# jaw_resources_ok <gitdir> [free_kib] — rc 0 when the free disk covers 2 x the largest pack + JAW_SWAP_KIB; else rc 1 with JAW_REASON. An unreadable pack size or free space is rc 1.
jaw_resources_ok() {
  local gd="$1" free="${2:-}" big need
  if ! big="$(jaw_largest_pack_kib "$gd")"; then
    JAW_REASON="the largest pack under $gd cannot be measured — no repack (under doubt)"
    return 1
  fi
  [ -n "$free" ] || free="$(jaw_free_kib "$gd")"
  if ! _jaw_uint "$free"; then
    JAW_REASON="free disk cannot be read (got '${free:-nothing}') — no repack (under doubt)"
    return 1
  fi
  need=$(( big * 2 + JAW_SWAP_KIB ))
  if [ "$free" -lt "$need" ]; then
    JAW_REASON="free disk ${free}KiB < ${need}KiB needed (2 x largest pack ${big}KiB + ${JAW_SWAP_KIB}KiB swap headroom)"
    return 1
  fi
  JAW_REASON="free disk ${free}KiB >= ${need}KiB needed (2 x largest pack ${big}KiB + ${JAW_SWAP_KIB}KiB swap headroom)"
  return 0
}

# jaw_log <keep> <text> — stdout always; also $JAW_LOG (with a local timestamp) when <keep> is 1 and JAW_LOG is set. The file is best effort: the line is already on stdout, the order's own
# capture, and a log that cannot be written must not stop the run it describes — so every failure below returns 0.
jaw_log() {
  local keep="$1"; shift
  echo "jsonl-archive-window: $*"
  [ "$keep" = 1 ] && [ -n "${JAW_LOG:-}" ] || return 0
  mkdir -p "$(dirname "$JAW_LOG")" 2>/dev/null || return 0
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" >> "$JAW_LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$JAW_LOG" 2>/dev/null | tr -d ' ')" -gt "$JAW_LOG_MAX_LINES" ] 2>/dev/null; then
    tail -n $((JAW_LOG_MAX_LINES / 2)) "$JAW_LOG" > "$JAW_LOG.tmp.$$" 2>/dev/null && mv "$JAW_LOG.tmp.$$" "$JAW_LOG" 2>/dev/null
  fi
  return 0
}

# jaw_repack_allowed <gitdir> [free_kib] — the whole rule. rc 0 = a whole-repo repack may start now; rc 1 = it may not. JAW_REASON says why either way (a variable: call this directly, not in $(...)).
jaw_repack_allowed() {
  local gd="$1" free="${2:-}"
  if ! jaw_window_open; then
    jaw_log 0 "repack NOT allowed: $JAW_REASON"
    return 1
  fi
  if ! jaw_resources_ok "$gd" "$free"; then
    jaw_log 1 "repack NOT allowed, INSIDE the window: $JAW_REASON; swap $(jaw_swap_used)"
    return 1
  fi
  jaw_log 1 "repack allowed: $JAW_REASON; swap $(jaw_swap_used)"
  return 0
}
