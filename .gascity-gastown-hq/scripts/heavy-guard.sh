#!/usr/bin/env bash
# heavy-guard.sh (ga-vln2py, P0) — keep a HEAVY step from starting on the mini while the disk is near the floor.
#
# ## Contents
#   Why · Usage · Exit codes · What counts as heavy · Where it is wired · Not covered
#
# WHY. 17/10 12:40-12:56 three agent steps (a git repack, a selftest copying hq.jsonl, `go build` + golangci-lint of
# the beads repo) ran with the disk already low and filled it: Dolt took ENOSPC writing its journal and the data
# plane was down ~16 min. The prompt said "avoid heavy work on a low disk" and nobody read it at the moment it
# mattered, so this is a command, not a paragraph: it checks `df` and either runs the step or says no.
#
# USAGE
#   heavy-guard.sh [--min-free-mb N] [--wait-secs S] [--what LABEL] -- <command> [args...]
#       free >= N  -> runs the command (exec) and returns its exit code.
#       free <  N  -> waits up to S seconds (default 0) for the disk to recover, then refuses WITHOUT running it.
#   heavy-guard.sh --check [--min-free-mb N] [--wait-secs S] [--what LABEL]
#       same decision, no command: exit 0 = go ahead. For a script or a git hook that runs its own heavy part:
#           "$GC_CITY_PATH/scripts/heavy-guard.sh" --check --what "golangci-lint" || exit $?
#   N defaults to DISK_HEAVY_MIN_MB (6144 = 6 GB, see packs/town-deltas/assets/scripts/disk-headroom-lib.sh).
#
# EXIT CODES (deliberately OUTSIDE mbp-run.sh's 96..99, which mean "run it locally" — a refusal here must never be
# read as that):
#   <command's own>  0..74, 77.. (propagated) when it ran
#   75  LOW      the disk is below the floor and stayed there for the whole wait. NOT a failure of the step: do not
#                run it here by another route. Send it to the Linux node when it can go there
#                (scripts/mbp-run.sh --repo hq --dir <worktree> -- scripts/X.selftest.sh; a go build / lint can NOT
#                go to the node today), or wait for the disk and try again; tell the Mayor if it stays low.
#   76  UNKNOWN  no usable reading of the disk. The step is refused too — fail CLOSED, because the command this
#                guards fails by ENOSPC on the database — and the line says so.
#   64  usage    bad flag / no command and no --check.
#
# WHAT COUNTS AS HEAVY (anything that writes or holds hundreds of MB on this machine): go build / go test / go vet,
# golangci-lint, a git repack / gc / maintenance, a selftest that builds fixtures of tens of MB or runs mutants,
# a copy or export of a database. Short pytest runs and single-file edits are not heavy.
#
# WHERE IT IS WIRED. jsonl-archive-compact.selftest.sh (--check at the top); the doctrine paragraph in
# packs/town-deltas/template-fragments/town-deltas.template.md and the HQ SELFTESTS text of the gate
# (gate-review-task.lib.sh) tell agents to use it; docs/runbooks/disk-trabalho-pesado.md has the pre-commit snippet
# for the beads repo (that repo is not ours to edit from here).
#
# NOT COVERED. A session that is ALREADY inside a step when the disk falls is not interrupted. dolt-disk-floor-guard.sh
# frees caches at CRITICAL; telling the open pool sessions to stop their heavy steps is a separate slice (ga-vln2py.3).
# Nothing here stops NEW work either (the Pilot sweep: ga-ydaslo; the pool probes: ga-09hfgh).
#
# Every refusal (including "cannot load the lib") and every bypass (DISK_HEADROOM_ENABLED=0 / a pinned
# DISK_FREE_OVERRIDE_MB let a step through unchecked; stderr says so too) is appended to $HEAVY_GUARD_LOG (default
# $GC_CITY_PATH/.gc/logs/heavy-guard.log), best effort: a log that cannot be written never changes the verdict.
#
# Seams (selftests): DISK_FREE_OVERRIDE_MB pins the reading; HEAVY_GUARD_POLL_SECS (default 15) is the wait step.

HG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HG_LIB="${HEAVY_GUARD_LIB:-$HG_HERE/../packs/town-deltas/assets/scripts/disk-headroom-lib.sh}"
HG_CITY="${GC_CITY_PATH:-${GC_CITY:-$HG_HERE/..}}"
HG_LOG="${HEAVY_GUARD_LOG:-$HG_CITY/.gc/logs/heavy-guard.log}"
HG_POLL="${HEAVY_GUARD_POLL_SECS:-15}"
case "$HG_POLL" in ''|*[!0-9]*|0) HG_POLL=15 ;; esac

hg_log() {
  # best effort by design: the verdict was already reached, a full disk is exactly when this write fails
  mkdir -p "$(dirname "$HG_LOG")" 2>/dev/null || return 0
  printf '%s heavy-guard: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HG_LOG" 2>/dev/null || true
}

# vazio (lib absent/empty) → cannot decide → UNKNOWN (76); falhou/ilegível → the same, never "go ahead"
if [ ! -r "$HG_LIB" ] || ! . "$HG_LIB" 2>/dev/null || ! type disk_headroom_state disk_state_of disk_free_mb >/dev/null 2>&1; then
  echo "heavy-guard: cannot load $HG_LIB — no way to read the disk, so the step is refused (rc 76). Deploy fault: tell the Mayor." >&2
  hg_log "REFUSED lib_unloadable=$HG_LIB rc=76"
  exit 76
fi

min=""; wait_s=0; what="heavy step"; mode=run
while [ $# -gt 0 ]; do
  case "$1" in
    --min-free-mb) min="${2:-}"; shift 2 || { echo "heavy-guard: --min-free-mb needs a number" >&2; exit 64; } ;;
    --wait-secs)   wait_s="${2:-}"; shift 2 || { echo "heavy-guard: --wait-secs needs a number" >&2; exit 64; } ;;
    --what)        what="${2:-}"; shift 2 || { echo "heavy-guard: --what needs a label" >&2; exit 64; } ;;
    --check)       mode=check; shift ;;
    --)            shift; break ;;
    -h|--help)     sed -n '2,/^HG_HERE=/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "heavy-guard: unknown option '$1' (use -- before the command)" >&2; exit 64 ;;
  esac
done
[ -n "$min" ] || min="$DISK_HEAVY_MIN_MB"
case "$min" in ''|*[!0-9]*) echo "heavy-guard: --min-free-mb must be a whole number of MB (got '$min')" >&2; exit 64 ;; esac
[ "${#min}" -le 9 ] || { echo "heavy-guard: --min-free-mb takes at most 9 digits (got '$min'): a floor past what [ -lt ] can compare would read as plenty" >&2; exit 64; }
case "$wait_s" in ''|*[!0-9]*) echo "heavy-guard: --wait-secs must be a whole number of seconds (got '$wait_s')" >&2; exit 64 ;; esac
[ "${#wait_s}" -le 9 ] || { echo "heavy-guard: --wait-secs takes at most 9 digits (got '$wait_s')" >&2; exit 64; }
# base 10 on purpose: "08" and "09" pass the digits check above but are invalid OCTAL to $(( )), which used to leave the
# deadline empty and the low-disk loop below spinning for ever
wait_s=$(( 10#$wait_s ))
if [ "$mode" = run ] && [ $# -eq 0 ]; then
  echo "heavy-guard: no command given (usage: heavy-guard.sh [opts] -- <command> [args...], or --check)" >&2
  exit 64
fi

# vazio/falhou/ilegível → no clock, so no deadline can be made: do not wait at all (one reading, then the verdict)
t0=$(date +%s 2>/dev/null)
case "$t0" in ''|*[!0-9]*) t0=0; wait_s=0 ;; esac
deadline=$(( t0 + wait_s ))
while :; do
  # ONE reading per pass: the verdict and the number shown in the refusal both come from this df, never from two
  # vazio/falhou/ilegível → free="" → state "unknown" (rc 76 below)
  free="$(disk_free_mb 2>/dev/null)" || free=""
  state="$(disk_state_of "$free" "$min")"
  [ "$state" = ok ] && break
  now=$(date +%s 2>/dev/null)
  # vazio/falhou/ilegível → the wait cannot be bounded: stop waiting, the verdict is taken on the reading just made
  case "$now" in ''|*[!0-9]*) break ;; esac
  # unknown is not worth waiting on: a reading that cannot be taken now will not fix itself in 15 s
  if [ "$state" != low ] || [ "$now" -ge "$deadline" ]; then break; fi
  step=$(( deadline - now )); [ "$step" -gt "$HG_POLL" ] && step="$HG_POLL"
  sleep "$step"
done

# vazio/falhou/ilegível -> "?" in the message only; the VERDICT below comes from $state, never from this number
[ -n "$free" ] || free="?"
case "$state" in
  ok)
    # a pinned reading or the kill switch lets the step through WITHOUT looking at the disk: visible, never silent
    if [ "${DISK_HEADROOM_ENABLED:-1}" = "0" ] || [ -n "${DISK_FREE_OVERRIDE_MB:-}" ]; then
      echo "heavy-guard: NOTE: '$what' goes ahead with the disk check bypassed (DISK_HEADROOM_ENABLED=0 or DISK_FREE_OVERRIDE_MB set in this environment) — meant for selftests only" >&2
      hg_log "BYPASS what='$what' DISK_HEADROOM_ENABLED=${DISK_HEADROOM_ENABLED:-} DISK_FREE_OVERRIDE_MB=${DISK_FREE_OVERRIDE_MB:-}"
    fi
    [ "$mode" = check ] && exit 0
    exec "$@"
    ;;
  low)
    echo "heavy-guard: REFUSED '$what': ${free} MB free < ${min} MB floor for heavy steps (ga-vln2py: 17/10 a step like this filled the disk and Dolt took ENOSPC). Do NOT run it on this machine by another route. Send it to the Linux node if it can go there (scripts/mbp-run.sh --repo hq --dir <worktree> -- scripts/X.selftest.sh), or wait for the disk and retry; if it stays low, tell the Mayor. (rc 75)" >&2
    hg_log "REFUSED what='$what' free_mb=$free min_mb=$min rc=75"
    exit 75
    ;;
  *)
    echo "heavy-guard: REFUSED '$what': the free disk could not be read (df failed or printed something else), so the step is not started — it fails by ENOSPC on the database. Retry; if it persists, tell the Mayor. (rc 76)" >&2
    hg_log "REFUSED what='$what' free_mb=unreadable min_mb=$min rc=76"
    exit 76
    ;;
esac
