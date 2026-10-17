#!/bin/sh
# disk-headroom-lib.sh (ga-vln2py, P0) — the ONE reader of "how much disk is left" for the two decisions that
# keep an agent from filling the mini's disk. SOURCED, never executed; POSIX sh (the dog probe is `sh`);
# no side effect at source time.
#
# ## Contents
#   Why · The two floors · Three states · Seams
#
# WHY. 17/10 12:40-12:56 the mini's disk went to ~0 while three agents were INSIDE heavy steps (a git repack,
# a selftest copying hq.jsonl, `go build` + golangci-lint). Dolt got ENOSPC writing its journal and the whole
# city lost its data plane for ~16 min. Nothing stops a session that is ALREADY open from starting a heavy
# step with the disk at the end, and the Pilot only held NEW dispatch when free swap < 512 MB AND disk < 4 GB
# (ga-9e446u) — with swap at 3-4.5 GB that predicate never fired while the disk went to zero.
#
# THE TWO FLOORS (free MB on the volume that holds the swapfiles and the Dolt data):
#   DISK_NEW_WORK_MIN_MB  5120 (5 GB)  below it nobody STARTS new work: the Pilot pauses dispatch and the pool
#                                      probes (dog, wa-worker, ps-worker) hand out no new bead.
#   DISK_HEAVY_MIN_MB     6144 (6 GB)  below it a heavy step (go build/test, golangci-lint, a selftest with
#                                      mutants, a copy of a database) does not start on this machine —
#                                      scripts/heavy-guard.sh refuses or waits. Higher than the first on
#                                      purpose: a step needs headroom to FINISH, dispatch only needs room to begin.
#
# THREE STATES, never two (the error-vs-empty family): disk_headroom_state prints
#   ok       a reading, and it is at or above the floor (or the lib is switched off)
#   low      a reading, and it is below the floor
#   unknown  no reading (df failed, printed nothing, or printed something that is not a number), or a floor
#            that is not a number
# What a caller does with `unknown` is the caller's decision and is NOT the same as `ok`:
#   - a gate on NEW work (Pilot, probes) fails OPEN and says so on its log: a df hiccup must not stop the city,
#     and one more session is a small risk;
#   - heavy-guard.sh fails CLOSED (refuses): it guards ONE step whose failure mode is ENOSPC on the database.
#
# SEAMS. DISK_FREE_OVERRIDE_MB pins the reading in selftests (a number = that many MB; any other non-empty value
# = "unreadable", so the unknown path is testable). DISK_HEADROOM_PATH picks the volume (default
# /private/var/vm — the same path the Pilot's swap-exhausted arm reads — else /). DISK_HEADROOM_ENABLED=0 makes
# every state `ok` (kill switch; never set in prod).

# What a low disk holds back from a pool probe (stdin: a JSON array of beads; prints the array without them). A STORY
# — a bead the Pilot routed to a builder — carries no gc.kind; the city's own formula work (shutdown dance, reaper,
# jsonl export: gc.kind=workflow) does, and that is exactly the work that has to keep running to get out of a low-disk
# hole. One definition, read by the dog probe (pool-probe.sh); the wa/ps worker probes serve only stories and just answer [].
DISK_HOLD_NEW_STORIES_JQ='[ .[] | select((.metadata["gc.kind"] // "") != "") ]'

DISK_NEW_WORK_MIN_MB="${DISK_NEW_WORK_MIN_MB:-5120}"
DISK_HEAVY_MIN_MB="${DISK_HEAVY_MIN_MB:-6144}"
case "$DISK_NEW_WORK_MIN_MB" in ''|*[!0-9]*) DISK_NEW_WORK_MIN_MB=5120 ;; esac
case "$DISK_HEAVY_MIN_MB" in ''|*[!0-9]*) DISK_HEAVY_MIN_MB=6144 ;; esac

# disk_free_mb — free MB as an integer on stdout and rc 0; rc 1 and NO stdout when it cannot be read.
disk_free_mb() {
  _dh_o="${DISK_FREE_OVERRIDE_MB:-}"
  if [ -n "$_dh_o" ]; then
    case "$_dh_o" in *[!0-9]*) return 1 ;; esac
    printf '%s' "$_dh_o"
    return 0
  fi
  _dh_p="${DISK_HEADROOM_PATH:-}"
  if [ -z "$_dh_p" ]; then
    if [ -d /private/var/vm ]; then _dh_p=/private/var/vm; else _dh_p=/; fi
  fi
  # vazio → unreadable (rc 1, no number); falhou/ilegível → unreadable too, never 0 MB and never "plenty"
  _dh_v=$(df -Pm "$_dh_p" 2>/dev/null | awk 'NR==2 {print $4}') || _dh_v=""
  case "$_dh_v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$_dh_v"
  return 0
}

# disk_headroom_state [min_mb] — prints ok | low | unknown (always rc 0, so $(...) is safe under set -e).
# min_mb defaults to the new-work floor; heavy callers pass "$DISK_HEAVY_MIN_MB".
disk_headroom_state() {
  _dh_min="${1:-$DISK_NEW_WORK_MIN_MB}"
  case "$_dh_min" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ "${DISK_HEADROOM_ENABLED:-1}" = "0" ]; then printf 'ok'; return 0; fi
  # vazio/falhou/ilegível → "unknown" (disk_free_mb returned 1); a reading below the floor → "low"
  _dh_f=$(disk_free_mb) || { printf 'unknown'; return 0; }
  if [ "$_dh_f" -lt "$_dh_min" ]; then printf 'low'; else printf 'ok'; fi
  return 0
}
