#!/bin/sh
# disk-headroom-lib.sh (ga-vln2py, P0) — the ONE reader of "how much disk is left" for the decisions that
# keep an agent from filling the mini's disk. SOURCED, never executed; POSIX sh (the pool probes that will read it
# are `sh`); no side effect at source time.
#
# ## Contents
#   Why · The three floors · Three states · Seams
#
# WHY. 17/10 12:40-12:56 the mini's disk went to ~0 while three agents were INSIDE heavy steps (a git repack,
# a selftest copying hq.jsonl, `go build` + golangci-lint). Dolt got ENOSPC writing its journal and the whole
# city lost its data plane for ~16 min. Nothing stopped a session that was ALREADY open from starting a heavy
# step with the disk at the end. This lib plus scripts/heavy-guard.sh is the piece that stops it; the pool probes
# (ga-09hfgh) stop NEW work with it, and the Pilot sweep (ga-ydaslo) is a separate slice of ga-vln2py.
#
# THE THREE FLOORS (free MB on the volume that holds the swapfiles and the Dolt data):
#   DISK_NEW_WORK_MIN_MB  5120 (5 GB)  the floor for STARTING new work, and the default floor of
#                                      disk_headroom_state. Its readers are the pool probes (ga-09hfgh) and, in a
#                                      separate slice of ga-vln2py, the Pilot sweep (ga-ydaslo); heavy-guard.sh passes its own.
#   DISK_HEAVY_MIN_MB     6144 (6 GB)  below it a heavy step (go build/test, golangci-lint, a selftest with
#                                      mutants, a copy of a database) does not start on this machine —
#                                      scripts/heavy-guard.sh refuses or waits. Higher than the first on
#                                      purpose: a step needs headroom to FINISH, dispatch only needs room to begin.
#   DISK_GO_MIN_MB       13312 (13 GB) the floor for `go build/test/vet/install` (ga-edkfip). The 6 GB heavy floor is
#                                      not enough for them: 19/10 06:03-06:09 a cold build of cmd/gc started at ~6 GB
#                                      and took the disk to 2 GB (Dolt at the CRITICAL floor). A cold build/test of the
#                                      engine writes 4-10 GB of build cache (measured), and dolt-disk-floor-guard
#                                      goes CRITICAL at 3 GB: 10 + 3 = 13. heavy-guard.sh uses the LARGER of this and
#                                      the heavy floor for a Go step, and its refusal sends the step to the MacBook
#                                      (mbp-run.sh --exec --go). The mini had ~7 GB free on 19/10, so in practice this
#                                      reads as "Go does not run on the mini" until someone frees space.
#
# THREE STATES, never two (the error-vs-empty family): disk_headroom_state prints
#   ok       a reading, and it is at or above the floor (or the lib is switched off)
#   low      a reading, and it is below the floor
#   unknown  no reading (df failed, printed nothing, or printed something that is not a number), or a floor
#            that is not a number, or one `[ -lt ]` cannot compare (a digit string past int64)
# `[` has three outcomes (true, false, could not compare) and only "false" means ok: a comparison that could not be
# made is `unknown`, never "plenty". The edges also refuse more than 9 digits (a reading, a floor in the env, the
# guard's --min-free-mb), so that case is rare by construction; the comparison stays three-way for what slips by.
# What a caller does with `unknown` is the caller's decision and is NOT the same as `ok`:
#   - heavy-guard.sh fails CLOSED (refuses): it guards ONE step whose failure mode is ENOSPC on the database;
#   - a gate on NEW work (the pool probes) fails OPEN and says so on its log: a df hiccup must not stop the city, and
#     one more session is a small risk. Each of those callers carries its own test for it.
#
# SEAMS. DISK_FREE_OVERRIDE_MB pins the reading in selftests (a number = that many MB; any other non-empty value
# = "unreadable", so the unknown path is testable). DISK_HEADROOM_PATH picks the volume (default
# /private/var/vm — the same path the Pilot's swap-exhausted arm reads — else /). DISK_HEADROOM_ENABLED=0 makes
# every state `ok` (kill switch; never set in prod).

# What a low disk holds back from a pool probe (stdin: a JSON array of beads; prints the array without them). It holds
# back a STORY: a bead of a story type (task, bug, feature, chore, epic, spike) that carries NONE of the marks the city's
# own formula work carries (gc.kind, gc.step_ref, gc.pool_demand). Formula work is what has to keep running to get out
# of a low-disk hole, and it does NOT always have a gc.kind: measured on the dog pool 17/10 (1684 beads), the stale-db
# cleanup molecule (type molecule, gc.pool_demand=order) and its steps (type step / task with gc.step_ref) are the
# bulk of it and carry none. So the rule leans to LET THROUGH: a type it does not know (molecule, step, wisp, an empty
# one) or any one formula mark flows, exactly as it did before this lib; only a positively recognised story is held.
# One definition, read by the dog probe (pool-probe.sh). The wa/ps worker probes answer [] without it: measured the
# same day, the 1125 beads routed to wa-worker and the 51 to ps-worker are all story types with none of the marks (and
# no order in the town config routes there). If that ever changes, those two probes must use this filter instead.
# That [] has no exception for the FIX class either (gate:needs-fix, gate:fix-attempt:*, origem:auto-healer-notify,
# impacto:dano-ao-vivo - the focus-mode set), same as the Pilot's full pause: a fix bead held there is named in a NOTE on
# stderr (Step 1b2 of both prompts) and the Mayor decides whether it runs on a low disk (ga-nyug12).
DISK_HOLD_NEW_STORIES_JQ='[ .[] | select( (((.issue_type // "") as $t | ["task","bug","feature","chore","epic","spike"] | any(. == $t)) | not) or ((.metadata["gc.kind"] // "") != "") or ((.metadata["gc.step_ref"] // "") != "") or ((.metadata["gc.pool_demand"] // "") != "") ) ]'

DISK_NEW_WORK_MIN_MB="${DISK_NEW_WORK_MIN_MB:-5120}"
DISK_HEAVY_MIN_MB="${DISK_HEAVY_MIN_MB:-6144}"
DISK_GO_MIN_MB="${DISK_GO_MIN_MB:-13312}"
# empty / not a number / more than 9 digits -> the default (a floor must be a number `[ -lt ]` can compare)
case "$DISK_NEW_WORK_MIN_MB" in ''|*[!0-9]*) DISK_NEW_WORK_MIN_MB=5120 ;; esac
case "$DISK_HEAVY_MIN_MB" in ''|*[!0-9]*) DISK_HEAVY_MIN_MB=6144 ;; esac
case "$DISK_GO_MIN_MB" in ''|*[!0-9]*) DISK_GO_MIN_MB=13312 ;; esac
[ "${#DISK_NEW_WORK_MIN_MB}" -le 9 ] || DISK_NEW_WORK_MIN_MB=5120
[ "${#DISK_HEAVY_MIN_MB}" -le 9 ] || DISK_HEAVY_MIN_MB=6144
[ "${#DISK_GO_MIN_MB}" -le 9 ] || DISK_GO_MIN_MB=13312

# disk_free_mb — free MB as an integer on stdout and rc 0; rc 1 and NO stdout when it cannot be read.
disk_free_mb() {
  _dh_o="${DISK_FREE_OVERRIDE_MB:-}"
  if [ -n "$_dh_o" ]; then
    case "$_dh_o" in *[!0-9]*) return 1 ;; esac
    [ "${#_dh_o}" -le 9 ] || return 1
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
  [ "${#_dh_v}" -le 9 ] || return 1
  printf '%s' "$_dh_v"
  return 0
}

# disk_state_of <free_mb> <min_mb> — the ONE comparison: prints ok | low | unknown from two numbers already read, so a
# caller that also PRINTS the number (heavy-guard.sh) shows the very reading the verdict came from. Always rc 0.
disk_state_of() {
  _dh_f="${1:-}"; _dh_min="${2:-}"
  if [ "${DISK_HEADROOM_ENABLED:-1}" = "0" ]; then printf 'ok'; return 0; fi
  # vazio/falhou/ilegível → "unknown": a missing reading or floor, anything that is not all digits
  case "$_dh_f" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  case "$_dh_min" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  # `[` has THREE outcomes (0 true, 1 false, 2 could not compare); only 1 means "not below the floor"
  _dh_rc=0
  [ "$_dh_f" -lt "$_dh_min" ] 2>/dev/null || _dh_rc=$?
  case "$_dh_rc" in 0) printf 'low' ;; 1) printf 'ok' ;; *) printf 'unknown' ;; esac
  return 0
}

# disk_headroom_state [min_mb] — reads the disk and prints ok | low | unknown (always rc 0, so $(...) is safe under
# set -e). min_mb defaults to the new-work floor; heavy callers pass "$DISK_HEAVY_MIN_MB".
disk_headroom_state() {
  _dh_m="${1:-$DISK_NEW_WORK_MIN_MB}"
  if [ "${DISK_HEADROOM_ENABLED:-1}" = "0" ]; then printf 'ok'; return 0; fi
  # vazio/falhou/ilegível → "unknown" (disk_free_mb returned 1, no number); a number goes to the one comparison
  _dh_r=$(disk_free_mb) || _dh_r=""
  disk_state_of "$_dh_r" "$_dh_m"
  return 0
}
