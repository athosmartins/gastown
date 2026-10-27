#!/usr/bin/env bash
# heavy-guard.sh (ga-vln2py, P0) — keep a HEAVY step from starting on the mini while the disk is near the floor.
#
# ## Contents
#   Why · Usage · Exit codes · What counts as heavy · Go class · Push class · File-cap class · Where it is wired · Lib lookup · Not covered
#
# WHY. 17/10 12:40-12:56 three agent steps (a git repack, a selftest copying hq.jsonl, `go build` + golangci-lint of
# the beads repo) ran with the disk already low and filled it: Dolt took ENOSPC writing its journal and the data
# plane was down ~16 min. The prompt said "avoid heavy work on a low disk" and nobody read it at the moment it
# mattered, so this is a command, not a paragraph: it checks `df` and either runs the step or says no.
#
# USAGE
#   heavy-guard.sh [--min-free-mb N] [--wait-secs S] [--max-file-mb M] [--what LABEL] -- <command> [args...]
#       free >= N  -> runs the command (exec) and returns its exit code.
#       free <  N  -> waits up to S seconds (default 0) for the disk to recover, then refuses WITHOUT running it.
#   heavy-guard.sh --check [--min-free-mb N] [--wait-secs S] [--what LABEL]
#       same decision, no command: exit 0 = go ahead. For a script or a git hook that runs its own heavy part:
#           "$GC_CITY_PATH/scripts/heavy-guard.sh" --check --what "golangci-lint" || exit $?
#   N defaults to DISK_HEAVY_MIN_MB (6144 = 6 GB, see packs/town-deltas/assets/scripts/disk-headroom-lib.sh);
#   for a Go build/test step (see "GO CLASS") the floor is DISK_GO_MIN_MB (13312 = 13 GB) instead;
#   for a `git push` (see "PUSH CLASS") it is DISK_PUSH_MIN_MB (5000), and the push runs under a watch and a lock:
#           "$GC_CITY_PATH/scripts/heavy-guard.sh" --what pre-push --wait-secs 600 -- git push origin HEAD
#   a selftest or a mutant battery also runs with a cap on the size of each file it writes (see "FILE-CAP CLASS"):
#           "$GC_CITY_PATH/scripts/heavy-guard.sh" --what selftest-hq --max-file-mb 512 -- bash scripts/X.selftest.sh
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
#                guards fails by ENOSPC on the database — and the line says so. Also: the file-size cap (below) was asked for
#                and could not be set, or could not be read back.
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
#     a message that says not to repeat it and to tell the Mayor: the disk is near the Dolt CRITICAL floor (3 GB). A reading the watch
#     cannot take (df fails) never kills a push — it goes on, and the log gets one WATCH_UNREADABLE line; the decision to START was
#     taken on a good reading. An unreadable disk BEFORE the start is the usual 76.
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
# FILE-CAP CLASS (ga-e6ug8gq). 27/10 05:09-05:24 an ad-hoc mutant battery on a selftest ran an awk mutant that looped for ever and wrote
# 4.2 GB and then 5.6 GB into $TMPDIR, one file each time: the disk hit 0 twice and Dolt took a sticky ENOSPC until `gc dolt restart --force`.
# The disk floor above is read BEFORE a step starts, and nothing watched the step: a loop that only writes is not stopped by it. The cure is a
# limit the KERNEL enforces, on the size of each file the step writes: `ulimit -f`, set here right before the exec, in the shell that becomes the
# command, so the command and everything it starts inherit it and cannot raise it (soft and hard are set together).
#   - a step is in the class when `selftest`, `mutant` or `mutat…` (mutate, mutation) shows up in its --what label or in any word of its
#     command, capitals ignored (`--what selftest-hq`, `bash x.selftest.sh`, `python3 hq-mutate.py`, `run-mutants.sh`). It is a substring
#     read, so a false match only caps a step that did not need it; the way out is `--max-file-mb 0`. A command that starts with `git`, a Go
#     step and a push are never in the class (a repack or a Go build writes big files on purpose; they have their own rules above).
#   - the default cap is HEAVY_GUARD_SELFTEST_MAX_FILE_MB, 512 (MB per file; 1-9 digits, else 512). 512 MB is far above what a selftest
#     writes on purpose (tens of MB) and far below what empties the disk. --max-file-mb M sets M for any step, class or not, and beats the
#     default; --max-file-mb 0 is the explicit way to run a class step uncapped.
#   - what the cap does to a runaway loop: the write that would pass the limit makes the kernel send SIGXFSZ, which ends the writer (rc 153
#     in a shell), or fails with EFBIG when the program ignores that signal (Python does, and so does anything started from a Python
#     launcher). Either way a file written in sequence stops at the limit, to the byte. With SIGXFSZ at its default the loop is gone in seconds (the selftest requires < 5 s); with EFBIG the file is still capped, but a shell loop that ignores write errors keeps spinning until its own timeout (measured 27/10 on Darwin: rc 124 after 5 s, file held at 65536 B). For a mutant that is the right verdict: a mutant
#     whose selftest dies from the cap is KILLED (caught); it is never an infra failure.
#   - fail CLOSED: a cap that was asked for and cannot be set (ulimit fails and the reading is not already at or under the cap), or cannot
#     be read back, or reads looser than asked, refuses the step with rc 76 and runs nothing. A tighter HARD limit inherited from the caller is
#     kept (ulimit cannot raise it, and the read-back is at or under the ask); a tighter SOFT limit alone is raised together with the hard one
#     to the ask, because `ulimit -f N` sets both. What holds either way is the contract: the cap in force is at most the ask, never more.
#   - --check runs nothing, so it has nothing to cap: it accepts the option and only judges the disk.
# NOT covered: on macOS (the mini, where this guard runs) the limit is not applied at all to a write opened with O_APPEND (`>>`): measured 27/10 on Darwin, an `echo >>` loop under `ulimit -f 64` reached 303 KB, while the same loop
# through `exec 3>` stopped at 65536 B; not measured on Linux. A `>>` loop on the mini has only `timeout` and a `df` check. And the cap is per FILE. A loop that writes many small files, or appends to one file after another, is not stopped by it
# (the aggregate of a slot is a separate watchdog). A selftest that swallows the dead child's rc can still exit 0 and let a mutant survive:
# that is the selftest's own weakness, not the cap's.
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
# reads HEAVY_GUARD_WATCH_SECS, HEAVY_GUARD_KILL_GRACE_SECS and HEAVY_GUARD_PUSH_LOCK_{DIR,WAIT_SECS,POLL_SECS,MAXAGE_SECS};
# the file-cap class reads HEAVY_GUARD_SELFTEST_MAX_FILE_MB.

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
# file-cap class (ga-e6ug8gq) tunable, see "FILE-CAP CLASS": 0, empty or not a number can never UNCAP a selftest, it is the 512 MB default
hg_posint HG_FCAP_DEFAULT "${HEAVY_GUARD_SELFTEST_MAX_FILE_MB:-}" 512 0
# disk-watch tunable (ga-2d14tow), see "DISK-WATCH": 0, empty or not a number can never LIFT the limit of a selftest, it is the 2048 MB default
hg_posint HG_DROP_DEFAULT "${HEAVY_GUARD_SELFTEST_MAX_DROP_MB:-}" 2048 0

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

# hg_selftest_step <label> [command...] — rc 0 when the step is a selftest or a mutant battery (see "FILE-CAP CLASS"), else rc 1. Pure
# bash and substring-based, like the other matchers: no outside command that could fail. A false match only puts a cap on a step that did
# not need one (and --max-file-mb 0 lifts it); a miss is the direction that matters, so the words are read from the label AND every word of
# the command. A git command (a repack/gc writes a big pack on purpose) is never in the class.
# vazio (no label, no command words) → rc 1, not in the class; falhou cannot happen (nothing is read from a file or the disk)
hg_selftest_step() {
  local label="${1:-}" cre
  shift
  case "${1:-}" in git|*/git) return 1 ;; esac
  # capitals are ignored by bracket classes (bash 3.2 on the mini has no ${var,,})
  cre='[Ss][Ee][Ll][Ff][Tt][Ee][Ss][Tt]|[Mm][Uu][Tt]([Aa][Nn][Tt]|[Aa][Tt])'
  [[ " $label $* " =~ $cre ]] && return 0
  return 1
}

# hg_apply_fcap <MB> — ulimit -f for this shell, which becomes the command. Returns 0 when the cap in force is at most <MB> (set now, or a
# tighter HARD limit that ulimit would not let go; a tighter soft-only limit is raised to <MB> with the hard one), else rc 1. The caller refuses with 76 on rc 1: a cap that was asked for is never silently absent.
# bash counts ulimit -f in 1024-byte blocks (512 in POSIX mode: then both the set and the read-back are in 512s, and the cap is tighter, never looser)
hg_apply_fcap() {
  local kb=$(( $1 * 1024 )) cur
  # vazio/falhou (ulimit refuses: the hard limit is lower than asked) → no stderr noise, the reading below decides
  ulimit -f "$kb" 2>/dev/null
  # vazio/falhou/ilegível (nothing printed, "unlimited", not a number) → `[` cannot compare (rc 2) → rc 1: no proof a cap is in force; a reading above the ask → rc 1
  cur="$(ulimit -f 2>/dev/null)" || return 1
  [ "$cur" -le "$kb" ] 2>/dev/null
}

hg_log() {
  # best effort by design: the verdict was already reached, a full disk is exactly when this write fails
  mkdir -p "$(dirname "$HG_LOG")" 2>/dev/null || return 0
  printf '%s heavy-guard: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HG_LOG" 2>/dev/null || true
}

# ── push class (ga-pwd2h6): the lock and the watch ──────────────────────────────────────────────────────────
HG_LOCK_HELD=0; HG_CHILD=""; HG_WATCHER=""; HG_INTERRUPTED=0; HG_LOCK_VERDICT=held; HG_LOCK_HOLDER=unknown
HG_WKIND=push; HG_WSTOP=0; HG_WDROP=0; HG_WSTART=""   # what the watch watches: push (default) or step (ga-2d14tow)

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

# hg_traps — from here a TERM/INT/HUP stops the child and lets the lock go, and the watch's USR1 is the "interrupted" flag (without its trap USR1 would kill the guard)
hg_traps() {
  trap 'HG_INTERRUPTED=1' USR1
  trap 'hg_on_signal' TERM INT HUP
  trap 'hg_lock_release' EXIT
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
  hg_traps
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

# hg_watch <child pid> <guard pid> — runs in a background subshell for as long as the child runs. Push: stops it when the disk is under DISK_PUSH_STOP_MB.
# Step (ga-2d14tow, HG_WKIND=step): stops it under HG_WSTOP, or when the free disk has fallen HG_WDROP MB or more since HG_WSTART (HG_WDROP 0 = floor only).
hg_watch() {
  local pid="$1" main="$2" f st blind=0 stop="$DISK_PUSH_STOP_MB" d
  [ "$HG_WKIND" != step ] || stop="$HG_WSTOP"
  while :; do
    sleep "$HG_WATCH"
    # vazio/falhou/ilegível → st is not "ok" nor "low": this round is blind; the child goes on and the log says so once
    f="$(disk_free_mb 2>/dev/null)" || f=""
    st="$(disk_state_of "$f" "$stop" 2>/dev/null)" || st=""
    # the drop rule needs two real numbers: st=ok means f is one (the kill switch makes every state ok, so it switches this rule off too) and HG_WSTART was checked when the watch was set up; a round that cannot judge it is no verdict, never a kill
    if [ "$st" = ok ] && [ "$HG_WKIND" = step ] && [ "$HG_WDROP" -gt 0 ] && [ "${DISK_HEADROOM_ENABLED:-1}" != 0 ]; then
      d=$(( 10#$HG_WSTART - 10#$f ))
      [ "$d" -lt "$HG_WDROP" ] || st=drop
    fi
    case "$st" in
      ok) ;;
      low|drop)
        if [ "$HG_WKIND" != step ]; then
          echo "heavy-guard: INTERRUPTED '$what': ${f} MB free < ${DISK_PUSH_STOP_MB} MB stop floor while it ran (ga-pwd2h6) — the push is being stopped (TERM to its process group). Do NOT repeat it and do NOT work around it (no --no-verify, no other route): the disk is near the Dolt CRITICAL floor. Tell the Mayor. (rc 78)" >&2
          hg_log "INTERRUPTED what='$what' free_mb=$f stop_mb=$DISK_PUSH_STOP_MB rc=78"
        elif [ "$st" = drop ]; then
          echo "heavy-guard: INTERRUPTED '$what': the free disk fell ${d} MB (${HG_WSTART} -> ${f} MB) while it ran, limit ${HG_WDROP} MB (ga-2d14tow) — the step is being stopped (TERM to its process group). A loop that writes many small files goes under the per-file cap and is the usual cause (27/10 ga-e6ug8gq). Do NOT re-run it unchanged and do NOT lift the limit to get around it: what it wrote is still on disk (look under its TMPDIR, clean scratch with safe-clean). If the step really writes this much, re-run THAT one with --max-disk-drop-mb and say so in the bead; if you cannot tell, tell the Mayor. (rc 78)" >&2
          hg_log "INTERRUPTED what='$what' class=step free_mb=$f start_mb=$HG_WSTART drop_mb=$d max_drop_mb=$HG_WDROP rc=78"
        else
          echo "heavy-guard: INTERRUPTED '$what': ${f} MB free < ${stop} MB stop floor while it ran (ga-2d14tow) — the step is being stopped (TERM to its process group). Do NOT re-run it unchanged and do NOT work around it: the disk is near the Dolt CRITICAL floor, and what the step wrote is still on disk (look under its TMPDIR, clean scratch with safe-clean). Tell the Mayor. (rc 78)" >&2
          hg_log "INTERRUPTED what='$what' class=step free_mb=$f stop_mb=$stop rc=78"
        fi
        # told in memory (no disk needed): the guard marks the run as interrupted before the child's own exit shows up
        kill -USR1 "$main" 2>/dev/null
        hg_stop_group "$pid"
        return 0 ;;
      *) if [ "$blind" = 0 ]; then
           blind=1
           if [ "$HG_WKIND" = step ]; then hg_log "WATCH_UNREADABLE what='$what' class=step stop_mb=$stop (the step goes on)"
           else hg_log "WATCH_UNREADABLE what='$what' stop_mb=$DISK_PUSH_STOP_MB (the push goes on)"; fi
         fi ;;
    esac
  done
}

# hg_run_watched <command...> — run the push with the watch beside it; never returns (exits with the push's rc, or 78)
hg_run_watched() {
  local rc seen
  # job control only to give the push its OWN process group, so the TERM of the watch reaches its hook and children too
  set -m
  "$@" &
  HG_CHILD=$!
  hg_watch "$HG_CHILD" "$$" &
  HG_WATCHER=$!
  set +m
  # `wait` returns early (rc > 128) when the watch's USR1 arrives: that return is the signal, not the push. Detected by the trap having
  # flipped HG_INTERRUPTED during THIS wait (not by probing the pid: the push may already be gone, and its real status is still
  # there for the next `wait` to collect). Wait again until the status is the push's own.
  while :; do
    seen="$HG_INTERRUPTED"
    { wait "$HG_CHILD"; } 2>/dev/null; rc=$?
    [ "$HG_INTERRUPTED" = 1 ] && [ "$seen" = 0 ] || break
  done
  # a push that ended with 0 ended fine, whatever the watch did at that very moment; any other rc after an interruption is the 78
  if [ "$HG_INTERRUPTED" = 1 ] && [ "$rc" -ne 0 ]; then
    # the watch is still giving the rest of the push's group its grace (TERM sent, KILL to come): let it finish, so a hook
    # that cleans up on TERM can; hg_watch returns by itself once the group is gone or has been killed
    { wait "$HG_WATCHER"; } 2>/dev/null
    rc=78
  else
    kill -TERM -- "-$HG_WATCHER" 2>/dev/null || kill -TERM "$HG_WATCHER" 2>/dev/null
    { wait "$HG_WATCHER"; } 2>/dev/null
  fi
  hg_lock_release
  exit "$rc"
}

# vazio (lib absent/empty) → cannot decide → UNKNOWN (76); falhou/ilegível → the same, never "go ahead"
if [ ! -r "$HG_LIB" ] || ! . "$HG_LIB" 2>/dev/null || ! type disk_headroom_state disk_state_of disk_free_mb >/dev/null 2>&1; then
  echo "heavy-guard: cannot load $HG_LIB${HG_LOOKED:+ (search order: $HG_LOOKED)} — no way to read the disk, so the step is refused (rc 76). Deploy fault: tell the Mayor." >&2
  hg_log "REFUSED lib_unloadable=$HG_LIB rc=76${HG_LOOKED:+ search_order=$HG_LOOKED}"
  exit 76
fi

min=""; wait_s=0; what="heavy step"; mode=run; fcap=""; fcap_given=0; drop=""; drop_given=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min-free-mb) min="${2:-}"; shift 2 || { echo "heavy-guard: --min-free-mb needs a number" >&2; exit 64; } ;;
    --wait-secs)   wait_s="${2:-}"; shift 2 || { echo "heavy-guard: --wait-secs needs a number" >&2; exit 64; } ;;
    --what)        what="${2:-}"; shift 2 || { echo "heavy-guard: --what needs a label" >&2; exit 64; } ;;
    --max-file-mb) fcap="${2:-}"; fcap_given=1; shift 2 || { echo "heavy-guard: --max-file-mb needs a number" >&2; exit 64; } ;;
    --max-disk-drop-mb) drop="${2:-}"; drop_given=1; shift 2 || { echo "heavy-guard: --max-disk-drop-mb needs a number" >&2; exit 64; } ;;
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
if [ "$fcap_given" = 1 ]; then
  case "$fcap" in ''|*[!0-9]*) echo "heavy-guard: --max-file-mb must be a whole number of MB, 0 for no cap (got '$fcap')" >&2; exit 64 ;; esac
  [ "${#fcap}" -le 9 ] || { echo "heavy-guard: --max-file-mb takes at most 9 digits (got '$fcap')" >&2; exit 64; }
  fcap=$(( 10#$fcap ))
fi
if [ "$drop_given" = 1 ]; then
  case "$drop" in ''|*[!0-9]*) echo "heavy-guard: --max-disk-drop-mb must be a whole number of MB, 0 for no drop limit (got '$drop')" >&2; exit 64 ;; esac
  [ "${#drop}" -le 9 ] || { echo "heavy-guard: --max-disk-drop-mb takes at most 9 digits (got '$drop')" >&2; exit 64; }
  drop=$(( 10#$drop ))
fi
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

# FILE-CAP CLASS (ga-e6ug8gq): the cap each file of the step may reach, in MB; 0 = none. The caller's number wins; else a selftest/mutant step
# that is not a Go step gets the class default (a push starts with git, which hg_selftest_step leaves out). vazio (no option, not in the class) → 0, as before this class.
fcap_mb=0
if [ "$fcap_given" = 1 ]; then
  fcap_mb="$fcap"
elif [ "$go_class" = 0 ] && hg_selftest_step "$what" "$@"; then
  fcap_mb="$HG_FCAP_DEFAULT"
fi

# DISK-WATCH (ga-2d14tow): a step that RUNS (not a push, which has its own watch) is watched while it runs when it is a selftest/mutant battery that is not a
# Go step, or when the caller gives --max-disk-drop-mb N > 0. drop_mb is the fall in free MB that stops it (the caller's number wins over the class default;
# 0 lifts the drop rule only, the floor stays). The floor is DISK_PUSH_STOP_MB, pulled down to the start floor in force so a step the caller let start low is not
# killed at the first round. vazio (no option, not in the class) -> no watch, as before this class.
watch_kind=""; drop_mb=0
if [ "$mode" = run ] && [ "$push_class" = 0 ]; then
  [ "$drop_given" = 0 ] || drop_mb="$drop"
  if [ "$go_class" = 0 ] && hg_selftest_step "$what" "$@"; then
    watch_kind=step
    [ "$drop_given" = 1 ] || drop_mb="$HG_DROP_DEFAULT"
  elif [ "$drop_mb" -gt 0 ]; then
    watch_kind=step
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
    # last thing before the step: the cap is set in THIS shell, which the exec turns into the command. fail CLOSED (rc 76): a step that was
    # to run capped never runs without it
    if [ "$fcap_mb" -gt 0 ] && ! hg_apply_fcap "$fcap_mb"; then
      echo "heavy-guard: REFUSED '$what': the cap of ${fcap_mb} MB per file (ulimit -f) could not be set or read back, so the step is not started — without it a runaway write loop has no limit (27/10 ga-e6ug8gq: two loops filled the disk and Dolt took ENOSPC). Retry; if it persists, tell the Mayor. (rc 76)" >&2
      hg_log "REFUSED what='$what' fsize_cap_mb=$fcap_mb unsettable rc=76"
      exit 76
    fi
    [ "$push_class" = 1 ] && { HG_WKIND=push; hg_run_watched "$@"; }
    if [ "$watch_kind" = step ]; then
      HG_WKIND=step; HG_WDROP="$drop_mb"; HG_WSTART="$free"; HG_WSTOP="${DISK_PUSH_STOP_MB:-4000}"
      # vazio/falhou/ilegível (no number to count a fall from: the bypass switches leave $free empty or "?") -> the floor alone; `[` false or "could not compare" both clamp the stop floor to the start floor
      case "$HG_WSTART" in ''|*[!0-9]*) HG_WDROP=0 ;; esac
      [ "$HG_WSTOP" -le "$min" ] 2>/dev/null || HG_WSTOP="$min"
      hg_traps
      hg_run_watched "$@"
    fi
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
