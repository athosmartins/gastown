#!/usr/bin/env bash
# heavy-guard.sh (ga-vln2py, P0) — keep a HEAVY step from starting on the mini while the disk is near the floor.
#
# ## Contents
#   Why · Usage · Exit codes · What counts as heavy · Go class · Push class · Where it is wired · Lib lookup · Not covered
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
#   for a Go build/test step (see "GO CLASS") the floor is DISK_GO_MIN_MB (13312 = 13 GB) instead;
#   for a `git push` (see "PUSH CLASS") it is DISK_PUSH_MIN_MB (5000), and the push runs under a watch and a lock:
#           "$GC_CITY_PATH/scripts/heavy-guard.sh" --what pre-push --wait-secs 600 -- git push origin HEAD
#
# EXIT CODES (deliberately OUTSIDE mbp-run.sh's 96..99, which mean "run it locally" — a refusal here must never be
# read as that):
#   <command's own>  0..74, 77, 80.. (propagated) when it ran (78 and 79 are the push class's own, below)
#   75  LOW      the disk is below the floor and stayed there for the whole wait. NOT a failure of the step: do not
#                run it here by another route. Send it to the Linux node when it can go there
#                (scripts/mbp-run.sh --repo hq --dir <worktree> -- scripts/X.selftest.sh), send a Go build/test to the
#                MacBook (scripts/mbp-run.sh --exec --go ..., see "GO CLASS"; golangci-lint has no remote today), or
#                wait for the disk and try again; tell the Mayor if it stays low.
#   76  UNKNOWN  no usable reading of the disk. The step is refused too — fail CLOSED, because the command this
#                guards fails by ENOSPC on the database — and the line says so.
#   64  usage    bad flag / no command and no --check.
#   78  INTERRUPTED (push class only) the disk fell UNDER DISK_PUSH_STOP_MB while the push ran and the guard stopped it. This is
#                not "try again": do NOT repeat the push or find another route (no --no-verify), tell the Mayor.
#   79  PUSH LOCK BUSY (push class only) another push held the push lock for the whole lock wait. NOT a disk problem and the
#                push did not start: retry in a minute.
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
# PUSH CLASS (ga-pwd2h6). A `git push` and the pre-push hook behind it write ~0-200 MB (the worktree and tmp), so the heavy floor
# was the wrong size for it: on 24/10 the mini's disk sat at 4.8-6.1 GB all day and five WA worker pushes stopped at 6144 and waited
# for a manual exception from the Mayor, each one run under the same hand-made recipe (floor 5000, a df watch that stops at 4000,
# one pre-push at a time, never --no-verify; lowest disk seen during a push: 5052 MB, no watch fired). This class IS that recipe:
#   - START floor DISK_PUSH_MIN_MB (5000), a MINIMUM like the Go floor: --min-free-mb can raise it for one call, never lower it.
#   - STOP floor DISK_PUSH_STOP_MB (4000): while the push runs, df is read every HEAVY_GUARD_WATCH_SECS (3); a reading UNDER it sends
#     TERM to the push's whole process group (KILL after HEAVY_GUARD_KILL_GRACE_SECS, 5, for what is left) and the guard exits 78 with
#     a message that says not to repeat it and to tell the Mayor: the disk is near the Dolt CRITICAL floor (3 GB). The guard hears it
#     from the watch's EXIT STATUS (78), never from a signal: a signal cuts its `wait` short and bash (3.2.57 and 5.2.21 alike) can then
#     answer -1 for the push instead of its status (ga-dousipw). A reading the watch cannot take (df fails) never kills a push — it goes
#     on, and the log gets one WATCH_UNREADABLE line; the decision to START was taken on a good reading. An unreadable disk BEFORE the
#     start is the usual 76.
#   - ONE push at a time: a mkdir lock ($HEAVY_GUARD_PUSH_LOCK_DIR, default $GC_CITY_PATH/.gc/heavy-guard-push.lock) holding
#     "<pid> <epoch>". A second push waits for it (HEAVY_GUARD_PUSH_LOCK_WAIT_SECS, 900; polled every HEAVY_GUARD_PUSH_LOCK_POLL_SECS,
#     2); still held after the wait -> rc 79. The lock is taken over when its pid is dead or its stamp is older than
#     HEAVY_GUARD_PUSH_LOCK_MAXAGE_SECS (7200: pid reuse, a hung push), and when the directory has no owner file and is older than
#     about a minute (the holder died between mkdir and writing it). A lock the guard cannot read or judge is respected, never taken.
#     A lock that cannot be created at all is rc 76: no push runs unlocked. It is mutual exclusion on a best-effort basis (two
#     waiters can judge the same stale lock and race on the takeover); the stop floor is what protects the disk.
# A step is in the class when its command is git (bare or by path), then git's own options (-C <dir>, -c <k=v>, --git-dir, ...),
# then `push`: `git push`, `git -C dir push origin HEAD`. With no command to look at (--check) a --what label that is `push`, `git push`
# or `pre-push` (- or _ or a space between, capitals ignored, anything after a non-alphanumeric) counts. A label cannot make another
# command a push: when there is a command, only the command is read. NOT seen: `sh -c 'git push'`, `env git push`, a git alias. They
# keep the heavy floor, which is the SAFE direction: this is the only class that LOWERS a floor, so every doubt lands on the stricter
# one. A Go step is never a push (its floor is higher). A lib that has no DISK_PUSH_* (older than this guard) leaves the push on the
# heavy floor and a plain exec, as before. --check in the class is the floor alone: no lock and no watch, since nothing runs under
# the guard — a script that pushes after --check is not covered by 78/79.
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
# NOT COVERED. A session that is ALREADY inside a step when the disk falls is not interrupted (the push class is the one exception:
# it carries its own watch). If the watch process cannot even be forked (the machine is out of processes) the push runs unwatched. dolt-disk-floor-guard.sh
# frees caches at CRITICAL; telling the open pool sessions to stop their heavy steps is a separate slice (ga-vln2py.3).
# Nothing here stops NEW work either (the Pilot sweep: ga-ydaslo; the pool probes: ga-09hfgh).
#
# Every refusal (including "cannot load the lib") and every bypass (DISK_HEADROOM_ENABLED=0 / a pinned
# DISK_FREE_OVERRIDE_MB let a step through unchecked; stderr says so too) is appended to $HEAVY_GUARD_LOG (default
# $GC_CITY_PATH/.gc/logs/heavy-guard.log), best effort: a log that cannot be written never changes the verdict.
#
# Seams (selftests): DISK_FREE_OVERRIDE_MB pins the reading; HEAVY_GUARD_POLL_SECS (default 15) is the wait step; the push class
# reads HEAVY_GUARD_WATCH_SECS, HEAVY_GUARD_KILL_GRACE_SECS and HEAVY_GUARD_PUSH_LOCK_{DIR,WAIT_SECS,POLL_SECS,MAXAGE_SECS}.

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

# hg_posint <varname> <value> <default> <zero-ok 0|1> — <varname> = <value> as a base-10 integer of 1-9 digits (0 only when zero-ok),
# else <default>. vazio/falhou/ilegível (empty, not digits, too long, a 0 where it cannot be) -> the default, never a guess. Base 10 on
# purpose: "08" is invalid OCTAL inside $(( )).
hg_posint() {
  local v="$2"
  case "$v" in ''|*[!0-9]*) v="$3" ;; esac
  [ "${#v}" -le 9 ] || v="$3"
  v=$(( 10#$v ))
  [ "$v" -gt 0 ] || [ "$4" = 1 ] || v="$3"
  printf -v "$1" '%s' "$v"
}
# push class (ga-pwd2h6) tunables, see "PUSH CLASS"
hg_posint HG_WATCH "${HEAVY_GUARD_WATCH_SECS:-}" 3 0
hg_posint HG_KILL_GRACE "${HEAVY_GUARD_KILL_GRACE_SECS:-}" 5 0
hg_posint HG_LOCK_WAIT "${HEAVY_GUARD_PUSH_LOCK_WAIT_SECS:-}" 900 1
hg_posint HG_LOCK_POLL "${HEAVY_GUARD_PUSH_LOCK_POLL_SECS:-}" 2 0
hg_posint HG_LOCK_MAXAGE "${HEAVY_GUARD_PUSH_LOCK_MAXAGE_SECS:-}" 7200 0
HG_LOCK_DIR="${HEAVY_GUARD_PUSH_LOCK_DIR:-$HG_CITY/.gc/heavy-guard-push.lock}"

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

# hg_push_step <label> [command...] — rc 0 when the step is a `git push` (see "PUSH CLASS"), else rc 1. Pure bash, like hg_go_step.
# This is the one class that LOWERS a floor, so unlike the Go matcher a doubt must land on rc 1 (the stricter, heavy floor): an
# unknown git option, a word other than push, another program, a label that has a command beside it -> rc 1.
# vazio (no label and no command words) -> rc 1, not a push; falhou cannot happen (no file, no disk, no outside command is read)
hg_push_step() {
  local label="${1:-}" lre
  shift
  if [ $# -eq 0 ]; then
    # nothing to look at (--check): the label is all there is. `push`, `git push`, `pre-push`, capitals ignored
    lre='^(([Gg][Ii][Tt]|[Pp][Rr][Ee])[- _])?[Pp][Uu][Ss][Hh]([^[:alnum:]]|$)'
    [[ $label =~ $lre ]] && return 0
    return 1
  fi
  # with a command, the label is ignored: it cannot make a heavy step a push
  case "$1" in git|*/git) ;; *) return 1 ;; esac
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      push) return 0 ;;
      -C|-c|--git-dir|--work-tree|--namespace) shift 2 || return 1 ;;
      --no-pager|--paginate|-p|-P|--bare|--no-optional-locks|--no-replace-objects|--git-dir=*|--work-tree=*|--namespace=*) shift ;;
      *) return 1 ;;
    esac
  done
  return 1
}

hg_log() {
  # best effort by design: the verdict was already reached, a full disk is exactly when this write fails
  mkdir -p "$(dirname "$HG_LOG")" 2>/dev/null || return 0
  printf '%s heavy-guard: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HG_LOG" 2>/dev/null || true
}

# ── push class (ga-pwd2h6): the lock and the watch ──────────────────────────────────────────────────────────
HG_LOCK_HELD=0; HG_CHILD=""; HG_WATCHER=""; HG_LOCK_VERDICT=held; HG_LOCK_HOLDER=unknown

hg_lock_release() {
  # best effort by design (it runs from an EXIT trap): a lock left behind is judged stale by the next push (dead pid / max age)
  [ "$HG_LOCK_HELD" = 1 ] || return 0
  HG_LOCK_HELD=0
  rm -f "$HG_LOCK_DIR/owner" 2>/dev/null
  rmdir "$HG_LOCK_DIR" 2>/dev/null
  return 0
}

# hg_lock_judge — the lock directory exists; sets HG_LOCK_VERDICT (stale | held) and HG_LOCK_HOLDER (for the messages).
# Three states: dead/too old → stale; alive → held; CANNOT TELL → held, because a lock that cannot be judged is never taken.
hg_lock_judge() {
  local pid="" at="" now old
  HG_LOCK_VERDICT=held; HG_LOCK_HOLDER=unknown
  if [ -e "$HG_LOCK_DIR/owner" ]; then
    # vazio/falhou/ilegível (the owner file is there but cannot be read, or is not "<pid> [<epoch>]") → held, holder unknown
    { IFS=' ' read -r pid at < "$HG_LOCK_DIR/owner"; } 2>/dev/null || true
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    HG_LOCK_HOLDER="pid $pid"
    # an epoch that is missing or not a number just switches the age rule off; the pid test below still applies
    case "$at" in ''|*[!0-9]*) at="" ;; esac
    [ "${#at}" -le 12 ] || at=""
    if [ -n "$at" ]; then
      # vazio/falhou/ilegível (no clock) → the age rule cannot be applied: only the pid test decides
      now=$(date +%s 2>/dev/null)
      case "$now" in
        ''|*[!0-9]*) ;;
        *) [ $(( now - 10#$at )) -le "$HG_LOCK_MAXAGE" ] || { HG_LOCK_VERDICT=stale; return 0; } ;;
      esac
    fi
    # alive → held; "no such process" → the holder died without letting go → stale. (kill -0 also fails for a process of ANOTHER user,
    # which would read as dead: every agent here runs as the same user, so that case does not arise.)
    kill -0 "$pid" 2>/dev/null || HG_LOCK_VERDICT=stale
    return 0
  fi
  # no owner file: somebody is between mkdir and writing it (fresh) or died there (old)
  # vazio (find prints nothing: younger than a minute) → fresh → held; falhou (find itself fails) → held too
  HG_LOCK_HOLDER="unknown (no owner file yet)"
  old="$(find "$HG_LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" || old=""
  [ "$old" != "$HG_LOCK_DIR" ] || HG_LOCK_VERDICT=stale
  return 0
}

# hg_lock_takeover — of several waiters judging the same stale lock only one rename succeeds
hg_lock_takeover() {
  local aside="$HG_LOCK_DIR.stale.$$"
  mv "$HG_LOCK_DIR" "$aside" 2>/dev/null || return 1
  rm -f "$aside/owner" 2>/dev/null
  rmdir "$aside" 2>/dev/null
  return 0
}

# hg_stop_group <pid> — TERM to the process group <pid> leads (just <pid> when it leads none); what is left after the grace gets KILL
hg_stop_group() {
  local p="$1" k=0 n=$(( HG_KILL_GRACE * 5 ))
  kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || return 0
  while [ "$k" -lt "$n" ] && { kill -0 -- "-$p" 2>/dev/null || kill -0 "$p" 2>/dev/null; }; do sleep 0.2; k=$((k+1)); done
  if kill -0 -- "-$p" 2>/dev/null || kill -0 "$p" 2>/dev/null; then
    kill -KILL -- "-$p" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
  fi
  return 0
}

# hg_on_signal — the guard was told to stop (the session closes, a timeout): the push and the watch go down with it, the lock is let go
hg_on_signal() {
  trap '' TERM INT HUP
  [ -z "$HG_WATCHER" ] || { kill -TERM -- "-$HG_WATCHER" 2>/dev/null || kill -TERM "$HG_WATCHER" 2>/dev/null; }
  [ -z "$HG_CHILD" ] || hg_stop_group "$HG_CHILD"
  hg_lock_release
  exit 143
}

# hg_push_lock_acquire — one pre-push at a time; returns holding the lock, or exits 79 (busy) / 76 (no lock can be had)
hg_push_lock_acquire() {
  local t0 deadline now step waited=0
  # the traps first: from here a TERM must let the lock go; the lock is only released if it was taken (HG_LOCK_HELD)
  trap 'hg_on_signal' TERM INT HUP
  trap 'hg_lock_release' EXIT
  # vazio/falhou (the parent cannot be made) → the mkdir below fails and the verdict is 76
  mkdir -p "${HG_LOCK_DIR%/*}" 2>/dev/null
  # vazio/falhou/ilegível (no clock) → no deadline can be made: one look at the lock, no waiting
  t0=$(date +%s 2>/dev/null)
  case "$t0" in ''|*[!0-9]*) t0=0; HG_LOCK_WAIT=0 ;; esac
  deadline=$(( t0 + HG_LOCK_WAIT ))
  while :; do
    if mkdir "$HG_LOCK_DIR" 2>/dev/null; then
      HG_LOCK_HELD=1
      # the owner file is what the next push judges this lock by; a lock we cannot stamp is a lock nobody can judge: not run.
      # vazio/falhou (no clock) → the stamp is "<pid> " without an epoch: the age rule is off for this lock, the pid test still applies
      if ! printf '%s %s\n' "$$" "$(date +%s 2>/dev/null)" > "$HG_LOCK_DIR/owner" 2>/dev/null; then
        echo "heavy-guard: REFUSED '$what': the push lock $HG_LOCK_DIR was created but its owner file could not be written (disk full?), so the push is not started. Retry; if it persists, tell the Mayor. (rc 76)" >&2
        hg_log "REFUSED what='$what' push_lock_owner_unwritable=$HG_LOCK_DIR rc=76"
        exit 76
      fi
      return 0
    fi
    # mkdir failed: the lock exists (held or stale), or it cannot be created at all
    if [ ! -d "$HG_LOCK_DIR" ]; then
      echo "heavy-guard: REFUSED '$what': cannot create the push lock $HG_LOCK_DIR (parent missing or not writable), and no push runs unlocked, so the push is not started. Retry; if it persists, tell the Mayor. (rc 76)" >&2
      hg_log "REFUSED what='$what' push_lock_unavailable=$HG_LOCK_DIR rc=76"
      exit 76
    fi
    hg_lock_judge
    if [ "$HG_LOCK_VERDICT" = stale ]; then
      hg_log "PUSH_LOCK_TAKEOVER what='$what' lock=$HG_LOCK_DIR holder='$HG_LOCK_HOLDER'"
      hg_lock_takeover && continue
    fi
    # vazio/falhou/ilegível (the clock stopped answering) → now=deadline: the wait ends here and the verdict is the 79 below, never an endless wait
    now=$(date +%s 2>/dev/null)
    case "$now" in ''|*[!0-9]*) now="$deadline" ;; esac
    if [ "$now" -ge "$deadline" ]; then
      [ "$t0" = 0 ] || waited=$(( now - t0 ))
      echo "heavy-guard: REFUSED '$what': another push holds the push lock ($HG_LOCK_HOLDER; $HG_LOCK_DIR) and did not let go in ${waited}s. This is not a disk problem and the push was NOT started: retry in a minute; if the holder is gone and the lock stays, tell the Mayor. (rc 79)" >&2
      hg_log "REFUSED what='$what' push_lock_busy holder='$HG_LOCK_HOLDER' waited_s=$waited rc=79"
      exit 79
    fi
    step=$(( deadline - now )); [ "$step" -gt "$HG_LOCK_POLL" ] && step="$HG_LOCK_POLL"
    sleep "$step"
  done
}

# hg_watch <push pid> — runs in a background subshell for as long as the push runs. Its EXIT STATUS is the guard's only word of what it
# did: 78 = it began to stop the push; anything else (the 143 of a TERM while it slept) is read as "it never touched the push"
hg_watch() {
  local pid="$1" f st blind=0
  while :; do
    sleep "$HG_WATCH"
    # vazio/falhou/ilegível → st is not "ok" nor "low": this round is blind; the push goes on and the log says so once
    f="$(disk_free_mb 2>/dev/null)" || f=""
    st="$(disk_state_of "$f" "$DISK_PUSH_STOP_MB" 2>/dev/null)" || st=""
    case "$st" in
      ok) ;;
      low)
        # decided, and the order matters: from here the guard's TERM (it sends one when the push ends) must not cut the stop short, and
        # it must be ignored BEFORE anything is done to the push, so that "78" is true whenever the push was touched
        trap '' TERM
        echo "heavy-guard: INTERRUPTED '$what': ${f} MB free < ${DISK_PUSH_STOP_MB} MB stop floor while it ran (ga-pwd2h6) — the push is being stopped (TERM to its process group). Do NOT repeat it and do NOT work around it (no --no-verify, no other route): the disk is near the Dolt CRITICAL floor. Tell the Mayor. (rc 78)" >&2
        hg_log "INTERRUPTED what='$what' free_mb=$f stop_mb=$DISK_PUSH_STOP_MB rc=78"
        hg_stop_group "$pid"
        exit 78 ;;
      *) if [ "$blind" = 0 ]; then blind=1; hg_log "WATCH_UNREADABLE what='$what' stop_mb=$DISK_PUSH_STOP_MB (the push goes on)"; fi ;;
    esac
  done
}

# hg_run_watched <command...> — run the push with the watch beside it; never returns (exits with the push's rc, or 78)
hg_run_watched() {
  local rc wrc
  # job control only to give the push its OWN process group, so the TERM of the watch reaches its hook and children too
  set -m
  "$@" &
  HG_CHILD=$!
  hg_watch "$HG_CHILD" &
  HG_WATCHER=$!
  set +m
  # Nothing signals the guard while it waits (ga-dousipw): a trapped signal cuts `wait` short (rc > 128) and the `wait` after it can answer
  # -1 instead of the push's status, so a push that ended with 0 came back as 78 (measured on bash 3.2.57 and on 5.2.21: from 1 run in 40
  # to 1 in 3, the more load the more). So the watch says what it did through its exit status, read below after this undisturbed wait.
  # vazio/falhou/ilegível → not expected: only the guard's own TERM/INT/HUP can cut this wait and that trap exits 143 first; a status that is
  # not a number would still end as a failure (exit 255 or 2), never as a 0
  { wait "$HG_CHILD"; } 2>/dev/null; rc=$?
  # the push is over: tell the watch. Asleep between two readings it dies of the TERM (143); once it began to stop the push it ignores the
  # TERM, gives the rest of the push's group its grace (so a hook that cleans up on TERM can) and exits 78 by itself
  kill -TERM -- "-$HG_WATCHER" 2>/dev/null || kill -TERM "$HG_WATCHER" 2>/dev/null
  # vazio/falhou/ilegível (no status to read, or one that is not 78) → read as "the watch did not stop it": the push answers with its own rc, never a made-up 0
  { wait "$HG_WATCHER"; } 2>/dev/null; wrc=$?
  # a push that ended with 0 ended fine, whatever the watch did at that very moment; any other rc after the watch stopped it is the 78
  if [ "$wrc" = 78 ] && [ "$rc" -ne 0 ]; then rc=78; fi
  hg_lock_release
  exit "$rc"
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
# whether the caller chose the floor matters to the push class (its default is lower than the heavy one)
min_given=1
[ -n "$min" ] || { min_given=0; min="$DISK_HEAVY_MIN_MB"; }
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

# PUSH CLASS (ga-pwd2h6): a `git push` has its own, LOWER start floor plus a watch and a lock. A Go step is never one (its floor is higher).
push_class=0
if [ "$go_class" = 0 ] && hg_push_step "$what" "$@"; then
  # vazio (the lib has no DISK_PUSH_*: it is older than this guard) → the push keeps the heavy floor and a plain exec, exactly as
  # before this class; falhou/ilegível → cannot happen (a variable read; the lib itself was loaded above)
  if [ -n "${DISK_PUSH_MIN_MB:-}" ] && [ -n "${DISK_PUSH_STOP_MB:-}" ]; then
    push_class=1
    if [ "$min_given" = 0 ]; then
      min="$DISK_PUSH_MIN_MB"
    else
      # the class floor is a MINIMUM: --min-free-mb may raise it for this call, never lower it (`[` false or "could not compare" both land on it)
      [ "$min" -ge "$DISK_PUSH_MIN_MB" ] 2>/dev/null || min="$DISK_PUSH_MIN_MB"
    fi
  else
    hg_log "PUSH_CLASS_UNAVAILABLE what='$what' lib=$HG_LIB (no DISK_PUSH_* floors: heavy floor, plain exec)"
  fi
fi

# a push that RUNS under the guard goes one at a time: the lock is taken before the disk is judged (the reading is made after the wait)
if [ "$push_class" = 1 ] && [ "$mode" = run ]; then hg_push_lock_acquire; fi

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
    [ "$push_class" = 1 ] && hg_run_watched "$@"
    exec "$@"
    ;;
  low)
    if [ "$push_class" = 1 ]; then
      echo "heavy-guard: REFUSED '$what': ${free} MB free < ${min} MB floor for a git push (ga-pwd2h6). Do NOT run it by another route and do NOT use --no-verify to get around the hook: wait for the disk to come back above ${min} MB and retry (--wait-secs N waits for it here); if it stays below, tell the Mayor. (rc 75)" >&2
      hg_log "REFUSED what='$what' free_mb=$free min_mb=$min class=push rc=75"
      exit 75
    fi
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
