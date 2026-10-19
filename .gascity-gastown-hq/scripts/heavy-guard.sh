#!/usr/bin/env bash
# heavy-guard.sh (ga-vln2py, P0) — keep a HEAVY step from starting on the mini while the disk is near the floor.
#
# ## Contents
#   Why · Usage · Exit codes · What counts as heavy · Go class · Where it is wired · Lib lookup · Not covered
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
#   N defaults to DISK_HEAVY_MIN_MB (6144 = 6 GB, see packs/town-deltas/assets/scripts/disk-headroom-lib.sh);
#   for a Go build/test step (see "GO CLASS") the floor is DISK_GO_MIN_MB (13312 = 13 GB) instead.
#
# EXIT CODES (deliberately OUTSIDE mbp-run.sh's 96..99, which mean "run it locally" — a refusal here must never be
# read as that):
#   <command's own>  0..74, 77.. (propagated) when it ran
#   75  LOW      the disk is below the floor and stayed there for the whole wait. NOT a failure of the step: do not
#                run it here by another route. Send it to the Linux node when it can go there
#                (scripts/mbp-run.sh --repo hq --dir <worktree> -- scripts/X.selftest.sh), send a Go build/test to the
#                MacBook (scripts/mbp-run.sh --exec --go ..., see "GO CLASS"; golangci-lint has no remote today), or
#                wait for the disk and try again; tell the Mayor if it stays low.
#   76  UNKNOWN  no usable reading of the disk. The step is refused too — fail CLOSED, because the command this
#                guards fails by ENOSPC on the database — and the line says so.
#   64  usage    bad flag / no command and no --check.
#
# WHAT COUNTS AS HEAVY (anything that writes or holds hundreds of MB on this machine): go build / go test / go vet,
# golangci-lint, a git repack / gc / maintenance, a selftest that builds fixtures of tens of MB or runs mutants,
# a copy or export of a database. Short pytest runs and single-file edits are not heavy.
#
# GO CLASS (ga-edkfip). `go build`, `go test`, `go vet` and `go install` get their own, higher floor: DISK_GO_MIN_MB, 13312
# (13 GB; the why and the arithmetic are in disk-headroom-lib.sh). 19/10 06:03-06:09 a cold build of cmd/gc started with the
# disk just over the 6 GB heavy floor, wrote ~4 GB of build cache in 6 minutes and left 2 GB: Dolt sat at the CRITICAL floor
# for two cycles until the build was killed by hand. A step is in the class when
#   - its --what label starts with go, then "-", "_" or a space, then test|build|vet|install, capitals ignored ("go-test",
#     "Go build ./cmd/gc"; "go-testdata" and "gopher-build" are not), or
#   - `go <verb>` shows up as a word in the command itself, also inside `sh -c '…'` or `env K=V go test` (the argument
#     list is read with ; & | ( ) ` " ' as spaces, so a quoted script is seen too).
# A script that runs go INSIDE (bash scripts/x.sh) is not seen: label it --what go-test. Also not seen: `go -C <dir> test`,
# `go run`, `go generate` (cold builds too) and plural labels ("go-tests"). A false match (an `echo go test`, a
# `git commit -m "fix go test"`) only applies the HIGHER floor, never the lower one; keep that text out of the command line
# (put it in a script file) to get the 6 GB floor back. The matcher is pure bash: it has no outside command that could fail. The class floor is a minimum: --min-free-mb can raise it for one call,
# never lower it. A lib that has no DISK_GO_MIN_MB (older than this guard) refuses a Go step with 76 instead of falling
# back to the heavy floor. The refusal is rc 75 like any other, and its text sends the step to the MacBook:
#   scripts/mbp-run.sh --exec --go --push go.mod --push go.sum --push internal --push cmd … -- sh -c 'cd in && go test ./...'
# (docs/runbooks/mbp-offload.md, "Go no MBP"). mbp-run rc 96..99 there means the MacBook is unavailable: wait, do not come back
# here. Heavy-guard itself never runs anything remotely.
#
# WHERE IT IS WIRED. jsonl-archive-compact.selftest.sh (--check at the top); the doctrine paragraph in
# packs/town-deltas/template-fragments/town-deltas.template.md and the HQ SELFTESTS text of the gate
# (gate-review-task.lib.sh) tell agents to use it; docs/runbooks/disk-trabalho-pesado.md has the pre-commit snippet
# for the beads repo (that repo is not ours to edit from here).
#
# LIB LOOKUP (ga-g9ptej). The script needs packs/town-deltas/assets/scripts/disk-headroom-lib.sh and is also run from
# a COPY (.gc/scripts/heavy-guard.sh, re-synced at every boot) that has no packs/ next to it: there the old lookup
# (only <script dir>/../packs/...) always ended in rc 76 and a WA worker parked thinking it was a deploy fault.
# Without HEAVY_GUARD_LIB the first READABLE file among these wins:
#   1. <script dir>/../packs/town-deltas/assets/scripts/disk-headroom-lib.sh
#   2. the same path relative to the script's directory with symlinks followed (a symlinked heavy-guard.sh)
#   3. $GC_CITY_PATH (else $GC_CITY)/packs/town-deltas/assets/scripts/disk-headroom-lib.sh
# A candidate that is missing or cannot be read is "not there": the next one is tried. A file that IS readable but
# cannot decide (cannot be sourced, or lacks disk_state_of) is NOT skipped: the step is refused, because falling
# through to another copy would hide a stale or broken lib. Nothing readable anywhere stays rc 76 (fail CLOSED),
# and the refusal lists every place that was looked at. HEAVY_GUARD_LIB set means exactly that file and no other.
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
HG_LIB_REL="packs/town-deltas/assets/scripts/disk-headroom-lib.sh"

hg_real_dir() {
  # the directory this script really lives in, symlinks followed (macOS readlink has no -f we can rely on)
  local p="${BASH_SOURCE[0]}" t n=0
  # vazio → not a symlink, p stays as is; falhou/ilegível (readlink fails, empty target, >40 hops) → prints nothing: no such candidate, never a guessed one
  while [ -L "$p" ]; do
    n=$((n+1)); [ "$n" -le 40 ] || return 0
    t="$(readlink "$p" 2>/dev/null)" || return 0
    [ -n "$t" ] || return 0
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  # vazio/falhou (the directory cannot be entered) → prints nothing: no such candidate
  ( cd -P "$(dirname "$p")" 2>/dev/null && pwd -P )
}

# candidates, in the order of "LIB LOOKUP" in the header: next to the script, next to the real script, in the city
HG_CANDS=("$HG_HERE/../$HG_LIB_REL")
# vazio → the script is not a symlink or its target could not be followed → no second candidate; falhou → the same, the others are still tried
HG_REAL="$(hg_real_dir)"
[ -z "$HG_REAL" ] || [ "$HG_REAL" = "$HG_HERE" ] || HG_CANDS+=("$HG_REAL/../$HG_LIB_REL")
# vazio (neither GC_CITY_PATH nor GC_CITY is set) → no city candidate; falhou cannot happen here (an env read)
HG_CITY_ROOT="${GC_CITY_PATH:-${GC_CITY:-}}"
[ -z "$HG_CITY_ROOT" ] || HG_CANDS+=("$HG_CITY_ROOT/$HG_LIB_REL")

HG_LIB="${HEAVY_GUARD_LIB:-}"; HG_LOOKED=""
if [ -z "$HG_LIB" ]; then
  # no file readable among the candidates → HG_LIB stays the first one: the name the refusal below gives
  HG_LIB="${HG_CANDS[0]}"
  for hg_c in "${HG_CANDS[@]}"; do HG_LOOKED="${HG_LOOKED:+$HG_LOOKED, }$hg_c"; done
  for hg_c in "${HG_CANDS[@]}"; do
    # vazio (no such file) → next candidate; falhou/ilegível (exists, cannot be read) → "not there" too: next candidate, and with none left the refusal (76) below
    if [ -f "$hg_c" ] && [ -r "$hg_c" ]; then HG_LIB="$hg_c"; break; fi
  done
fi
HG_CITY="${GC_CITY_PATH:-${GC_CITY:-$HG_HERE/..}}"
HG_LOG="${HEAVY_GUARD_LOG:-$HG_CITY/.gc/logs/heavy-guard.log}"
HG_POLL="${HEAVY_GUARD_POLL_SECS:-15}"
case "$HG_POLL" in ''|*[!0-9]*|0) HG_POLL=15 ;; esac
[ "${#HG_POLL}" -le 9 ] || HG_POLL=15   # past int64 the cap below could not be compared: back to the default

# hg_go_step <label> [command...] — rc 0 when the step is a Go toolchain build/test/vet/install (see "GO CLASS"), else rc 1.
# Pure bash on purpose: no outside command (an earlier version split the command with `tr`, and when that fork failed under
# load a Go step glued to punctuation, "cd /tmp;go test", was read as NOT Go and got the cheaper 6 GB floor — the exact
# mistake this class exists to stop). Nothing here reads a file or the disk, so there is no failed-to-read arm either.
# vazio (no label, no command words) → rc 1, not a Go step; a wrong match can only be a false POSITIVE, which applies the
# higher floor and never the lower one.
hg_go_step() {
  local label="${1:-}" norm seps lre cre
  shift
  # the label is typed by a person or an agent: "Go-Test" and "go-test" are the same step, so each letter is a bracket class
  lre='^[Gg][Oo][- _]([Tt][Ee][Ss][Tt]|[Bb][Uu][Ii][Ll][Dd]|[Vv][Ee][Tt]|[Ii][Nn][Ss][Tt][Aa][Ll][Ll])([^[:alnum:]]|$)'
  [[ $label =~ $lre ]] && return 0
  # ; & | ( ) ` " ' → spaces, then "go <verb>" as a word (a path before it counts: /opt/homebrew/bin/go test)
  seps=$';&|()`"\''
  norm=" $* "
  norm="${norm//[$seps]/ }"
  cre='[[:space:]/]go[[:space:]]+(test|build|vet|install)[[:space:]]'
  [[ $norm =~ $cre ]] && return 0
  return 1
}

hg_log() {
  # best effort by design: the verdict was already reached, a full disk is exactly when this write fails
  mkdir -p "$(dirname "$HG_LOG")" 2>/dev/null || return 0
  printf '%s heavy-guard: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HG_LOG" 2>/dev/null || true
}

# vazio (lib absent/empty) → cannot decide → UNKNOWN (76); falhou/ilegível → the same, never "go ahead"
if [ ! -r "$HG_LIB" ] || ! . "$HG_LIB" 2>/dev/null || ! type disk_headroom_state disk_state_of disk_free_mb >/dev/null 2>&1; then
  echo "heavy-guard: cannot load $HG_LIB${HG_LOOKED:+ (search order: $HG_LOOKED)} — no way to read the disk, so the step is refused (rc 76). Deploy fault: tell the Mayor." >&2
  hg_log "REFUSED lib_unloadable=$HG_LIB rc=76${HG_LOOKED:+ search_order=$HG_LOOKED}"
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

go_class=0
if hg_go_step "$what" "$@"; then
  go_class=1
  # vazio (the lib has no DISK_GO_MIN_MB: it is older than this guard) → the Go floor is unknown, so the step is refused (76),
  # never decided on the looser heavy floor; falhou/ilegível → cannot happen (a variable read; the lib itself was loaded above)
  if [ -z "${DISK_GO_MIN_MB:-}" ]; then
    echo "heavy-guard: cannot decide '$what': a Go step needs DISK_GO_MIN_MB and $HG_LIB does not define it (the lib is older than this guard), so the step is refused (rc 76). Deploy fault: tell the Mayor." >&2
    hg_log "REFUSED what='$what' go_floor_missing lib=$HG_LIB rc=76"
    exit 76
  fi
  # the class floor is a MINIMUM: --min-free-mb may raise it for this call, never lower it. `[` has three outcomes; true keeps
  # the caller's value, false (below the class floor) and "could not compare" (rc 2) both land on the class floor
  [ "$min" -ge "$DISK_GO_MIN_MB" ] 2>/dev/null || min="$DISK_GO_MIN_MB"
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
    if [ "$go_class" = 1 ]; then
      echo "heavy-guard: REFUSED '$what': ${free} MB free < ${min} MB floor for a Go build/test (ga-edkfip: a cold build of cmd/gc writes 4-10 GB of build cache; 19/10 one started just over the 6 GB heavy floor and left 2 GB, Dolt sat at the CRITICAL floor). Do NOT run it on this machine by another route. Run it on the MacBook: scripts/mbp-run.sh --exec --go --push go.mod --push go.sum --push internal --push cmd (more --push for examples, test, schemas, schemas_embed.go, docs, third_party if the tests need them) -- sh -c 'cd in && go test ./...' (recipe: docs/runbooks/mbp-offload.md, \"Go no MBP\"). If mbp-run answers 96..99 the MacBook is unavailable: wait and retry, do not come back here; if it stays unavailable, tell the Mayor. But 97 is also a usage error (a missing command, --go with --check) and 98 also a --push path that does not exist: read the 'mbp-run:' line before you wait. If this step is not a Go build/test and only mentions go test in its text, keep that text out of the command line (a script file) to get the 6 GB floor. (rc 75)" >&2
      hg_log "REFUSED what='$what' free_mb=$free min_mb=$min class=go rc=75"
      exit 75
    fi
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
