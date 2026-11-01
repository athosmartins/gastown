#!/bin/bash
# git-loose-repack.sh (ga-pmu761v) — pack the LOOSE git objects of the live repos at night, with a lean incremental repack.
#
# ## Contents
#   Why · What it does · Verdict and states · Safety · Not done on purpose · Seams · Usage
#
# WHY. gc.auto=0 and maintenance.auto=false are set on purpose (a 52-way detached auto-gc storm once filled the boot disk), so git never packs
# loose objects by itself, and they grow without a ceiling. Measured 31/10 21:2x (Mayor): the live WhatsApp repo held 54,830 loose objects =
# 2.47 GiB against 440 MiB packed. A manual `git repack -d` with lean settings took ~8 min at load ~50, did not raise swap and FREED 2,085 MB
# (disk 4.0 -> 6.0 GB). The one job that packs loose objects today, ~/.gastown/scripts/git-maintenance-runner.sh (every 6h), does nothing below
# 10 GB free — and this host lives at 3-6 GB (its log: 245 SKIPs against 640 runs; 4 of the last 6 cycles skipped). A repack gives disk back, so a
# guard that waits for the disk to be comfortable blocks the cleanup exactly when it helps. That is the gap this job closes. The runner is not
# versioned (it lives outside the repo) and is left alone.
#
# WHAT IT DOES. Every order tick (30 min) the script reads the clock; outside the night window it ends at once, with one stdout line and no log line. Inside it, for each repo
# of the list it reads `git count-objects -v` and, when the LOOSE bytes are over the limit (GLR_LIMIT_KIB, 256 MiB — the number
# jsonl-archive-compact.sh already uses; the bead said 512 as "ex.", and ~/gt holds 430 MiB), runs ONE incremental repack:
#     nice -n 10 git -C <repo> -c pack.threads=1 -c pack.windowMemory=100m -c pack.deltaCacheSize=32m repack -d -q
# through heavy-guard.sh (the 6 GB disk floor), under a watchdog (below). The repo list is: ~/gt, every ~/gt/<rig>/ and every ~/gt/<rig>/crew/<name>/ that has a
# real .git DIRECTORY (a git worktree has a .git FILE and shares its parent's objects, so it is skipped). Measured 31/10: only the WA repo (674 MiB) and
# ~/gt (430 MiB) are over the limit; the 13 crew clones hold <= 4 MiB loose each, so they cost one count each and nothing else.
#
# VERDICT AND STATES. Each tick that did something ends with ONE line: `VEREDITO: OK|ADIADO|FALHOU — ...`, and the log keeps it.
#   OK       below      the loose bytes are not over the limit — nothing was done
#            repacked   the repack ended 0 and the count AFTER is under the limit; the line carries before -> after (objects, MiB) and the free disk before -> after
#   ADIADO   deferred-disk  heavy-guard refused (rc 75/76), the room estimate says no, or the free disk cannot be read
#            deferred-swap  swap in use is over GLR_SWAP_START_MAX_MB, or cannot be read
#            deferred-time  this run's budget (GLR_DEADLINE_S) is spent; the next tick continues with the repos left
#            A deferral is not a failure and not an OK: it is retried on the next tick of the SAME night, and a repo that ends GLR_ALARM_NIGHTS (3) nights in a row
#            deferred makes the first tick of the next night notify (priority 3) — without that, "wait for the next night" could repeat for weeks, unseen.
#   FALHOU   unreadable   `git count-objects -v` failed, timed out, or printed no numeric count/size — the script does NOT measure, does NOT act, and says so
#            failed / timeout   the repack ended non-zero / was cut at GLR_REPACK_TIMEOUT_S
#            interrupted  the watchdog stopped the repack (free disk under the Dolt CRITICAL class, free disk unreadable 3 polls in a row, or swap grew > GLR_SWAP_GROW_MAX_MB)
#            stalled      the repack ended 0 but the loose bytes are STILL over the limit
#            unverified   the repack ended 0 but the count after cannot be read — "probably fine" is not "OK"
#            Every FALHOU is terminal for the night (the heavy step is not repeated every 30 min) and sends `notify -p 4 "... job falhou ..."`. Exit code 1.
#   A repo already settled tonight (any state above except deferred-*) is skipped by the later ticks (a tick where every repo is settled logs nothing). "Tonight" is the LOCAL date of the tick.
#   "In a row" counts the nights on which the job ran and saw the repo: a night the machine was off breaks nothing and adds nothing.
#
# SAFETY.
#   - Window: jaw_window_open from jsonl-archive-repack-window-lib.sh — a run may START between 00:00 and 04:59 local (the heavy-maintenance window Athos set on 15/10 is 00:00-06:00, and the last start is
#     an hour before its end) — the same lib the jsonl-archive uses, so the two cannot disagree. A clock that cannot be read is "closed". A repack's time limit is also cut to the window's end
#     (jaw_window_left_s, less GLR_WINDOW_MARGIN_S 300 s): one that would not end by 06:00 is not started (deferred-time), and one still running then is stopped. If the lib cannot be loaded
#     the job fails (rc 2 + notify): a missing gate must never read as "no gate".
#   - ONE repacker at a time: the script takes the SAME lock directory as git-maintenance-runner.sh (/tmp/git-maintenance-runner.lock, mkdir, stale after 120 min), so the 6-hourly runner and
#     this job never repack together. The run's whole budget (GLR_DEADLINE_S 6000 s = 100 min) is below that stale age, so the runner cannot reclaim a live lock. If the runner's lock path
#     changes, GLR_LOCK must follow.
#   - Room: the repack writes a new pack before the loose copies go. The pack is ~0.18x of the loose bytes in the one measurement we have (2.47 GiB -> ~450 MB), so the estimate is
#     GLR_PEAK_PCT (50) % of the loose bytes, and the start needs free - estimate >= (Dolt CRITICAL floor + 1) GiB, the rule jsonl-archive-compact.sh uses (ga-q8z86s: dolt-disk-floor-guard calls the
#     disk critical at <= 3 GiB free, rounded down). Free disk that cannot be read = deferred, never "enough".
#   - Watchdog: heavy-guard.sh checks the disk only AT THE START of a plain step and never reads swap, so this script polls every GLR_WATCH_SECS while the repack runs: it sends SIGTERM (git removes its
#     own tmp_pack on TERM; KILL only after a grace) when the free disk falls under (CRITICAL + 1) GiB, when the free disk cannot be read 3 polls in a row, or when swap in use grew by more than
#     GLR_SWAP_GROW_MAX_MB since the start. A single unreadable swap poll is ignored (the disk poll is the effective guard); an unreadable swap AT THE START defers the repo.
#     DEFAULTS CHOSEN WITHOUT A MEASUREMENT OF THIS JOB: GLR_SWAP_START_MAX_MB (8192), GLR_SWAP_GROW_MAX_MB (1024), GLR_PEAK_PCT (50). The manual run of 31/10 saw no swap growth.
#   - Every git/notify call is bounded by `timeout`. This script deletes nothing: the only removal is `rmdir` of its own lock.
#
# NOT DONE ON PURPOSE (the bead): `gc --aggressive`, `repack -a`/`-A`/`-f`, `prune`, `--cruft`. The selftest fails if one of them appears in the repack command. History is never shortened.
# KNOWN LIMIT: with the disk at 3-5 GB at night (the runner's log shows it) the 6 GB floor defers the repack. The alarm above makes that visible; a smaller-batch road for a tight disk
# (like ga-ft1iv6's for the jsonl archive) is the follow-up if the deferrals pile up.
#
# SEAMS (tests; every one has a default): GLR_ROOT GLR_REPOS GLR_LIMIT_KIB GLR_COUNT_TIMEOUT_S GLR_REPACK_TIMEOUT_S GLR_DEADLINE_S GLR_PEAK_PCT GLR_SWAP_START_MAX_MB GLR_SWAP_GROW_MAX_MB GLR_WATCH_SECS
# GLR_ALARM_NIGHTS GLR_WINDOW_MARGIN_S GLR_LOCK GLR_LOCK_STALE_MIN GLR_STATE_DIR GLR_LOG GLR_GIT GLR_HEAVY_GUARD GLR_NOTIFY GLR_TIMEOUT GLR_SYSCTL GLR_TODAY GLR_FREE_KIB_CMD GLR_SWAP_MB_CMD, JAW_HOUR / JAW_FREE_KIB (the lib's).
#
# USAGE: git-loose-repack.sh            the order's run (window-gated)
#        git-loose-repack.sh --dry-run  read-only: measure every repo and print what a run would do. Ignores the window, takes no lock, writes no state, repacks nothing.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${GLR_ROOT:-/Users/athos/gt}"
REPOS_OVERRIDE="${GLR_REPOS:-}"                       # space-separated paths (no spaces inside a path); empty = discover under ROOT
LIMIT_KIB="${GLR_LIMIT_KIB:-262144}"                  # loose bytes (count-objects `size`, KiB) STRICTLY over this = repack
COUNT_TIMEOUT_S="${GLR_COUNT_TIMEOUT_S:-120}"         # measured 31/10: 3-9 s on ~/gt at load 63, longer cold — 20 s was already too short once
REPACK_TIMEOUT_S="${GLR_REPACK_TIMEOUT_S:-3000}"      # one repack; the manual run took ~8 min
DEADLINE_S="${GLR_DEADLINE_S:-6000}"                  # the whole run; < the lock's stale age (120 min) and < the order's timeout
PEAK_PCT="${GLR_PEAK_PCT:-50}"
SWAP_START_MAX_MB="${GLR_SWAP_START_MAX_MB:-8192}"
SWAP_GROW_MAX_MB="${GLR_SWAP_GROW_MAX_MB:-1024}"
WATCH_SECS="${GLR_WATCH_SECS:-10}"
ALARM_NIGHTS="${GLR_ALARM_NIGHTS:-3}"
WINDOW_MARGIN_S="${GLR_WINDOW_MARGIN_S:-300}"         # a repack must end this long before the window's end (06:00), the margin jsonl-archive-compact.sh keeps too
CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-3}"       # the same variable, same default, as dolt-disk-floor-guard.sh
LOCK="${GLR_LOCK:-/tmp/git-maintenance-runner.lock}"
LOCK_STALE_MIN="${GLR_LOCK_STALE_MIN:-120}"
STATE_DIR="${GLR_STATE_DIR:-$RUNTIME/packs/town-deltas/git-loose-repack}"
LOG="${GLR_LOG:-$CITY/.gc/logs/git-loose-repack.log}"
GIT="${GLR_GIT:-git}"
HEAVY_GUARD="${GLR_HEAVY_GUARD:-$CITY/scripts/heavy-guard.sh}"
NOTIFY="${GLR_NOTIFY:-${HOME:-/Users/athos}/.local/bin/notify}"
TIMEOUT_BIN="${GLR_TIMEOUT:-}"
SYSCTL="${GLR_SYSCTL:-}"
LOG_MAX_LINES=4000
KIB_PER_GIB=1048576

_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 15 ]; }

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
say() {
  echo "git-loose-repack: $*"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || return 0
  # vazio → wc printed nothing: the comparison fails and the log is left alone; falhou → the same (a log that cannot be trimmed is only long)
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt "$LOG_MAX_LINES" ] 2>/dev/null; then
    tail -n $((LOG_MAX_LINES / 2)) "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null
  fi
  return 0
}

notify_send() { # notify_send <priority> <title> <text>
  # vazio → no notify binary: say so in the log (the verdict line is there anyway); falhou → the same, the job's own result does not change
  if [ ! -x "$NOTIFY" ]; then say "WARN: notify not executable ($NOTIFY) — not sent: $2: $3"; return 0; fi
  "$TIMEOUT_BIN" -k 5 30 "$NOTIFY" -t "$2" -p "$1" "$3" >/dev/null 2>&1 || say "WARN: notify failed (rc=$?): $2"
  return 0
}

mib() { echo $(( $1 / 1024 )); }
gib1() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }

setup_fail() { # setup_fail <what> — the job cannot run: a failure, never a silent "nothing to do"
  say "VEREDITO: FALHOU — $1"
  if [ -n "$TIMEOUT_BIN" ]; then notify_send 4 "git-loose-repack: job falhou" "$1 (ver $LOG)"; fi
  exit 2
}

# ── setup ────────────────────────────────────────────────────────────────────────────────────────
DRY=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: git-loose-repack.sh [--dry-run]" >&2; exit 64 ;;
esac

# vazio → no timeout/gtimeout on PATH: TIMEOUT_BIN stays empty and setup_fail below refuses (git calls could hang unbounded); falhou → the same
if [ -z "$TIMEOUT_BIN" ]; then TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"; fi
if [ -z "$TIMEOUT_BIN" ]; then say "WARN: no timeout/gtimeout on PATH"; setup_fail "no timeout binary — the git calls cannot be bounded"; fi
# vazio → no sysctl on PATH: falls back to the absolute path, and an unreadable swap is "deferred" at the start; falhou → the same
if [ -z "$SYSCTL" ]; then SYSCTL="$(command -v sysctl 2>/dev/null || echo /usr/sbin/sysctl)"; fi

for _v in LIMIT_KIB COUNT_TIMEOUT_S REPACK_TIMEOUT_S DEADLINE_S PEAK_PCT SWAP_START_MAX_MB SWAP_GROW_MAX_MB ALARM_NIGHTS WINDOW_MARGIN_S CRITICAL_GB LOCK_STALE_MIN; do
  eval "_val=\${$_v}"
  _uint "$_val" || setup_fail "config $_v='$_val' is not a number — refusing to run on a setting it cannot trust"
done
case "$WATCH_SECS" in ''|*[!0-9.]*|*.*.*) setup_fail "config WATCH_SECS='$WATCH_SECS' is not a number" ;; esac
[ "$PEAK_PCT" -ge 1 ] || setup_fail "config PEAK_PCT must be >= 1"

# the window lib: a missing gate is a failure, not "no gate"
if ! { [ -r "$SCRIPT_DIR/jsonl-archive-repack-window-lib.sh" ] && . "$SCRIPT_DIR/jsonl-archive-repack-window-lib.sh"; }; then
  setup_fail "cannot load $SCRIPT_DIR/jsonl-archive-repack-window-lib.sh — without it the night window cannot be judged"
fi

# ── reads ────────────────────────────────────────────────────────────────────────────────────────
# count_loose <repo> — sets CNT_OBJS and CNT_KIB (the LOOSE objects: count and `size`, KiB) and returns 0, or returns 1 with COUNT_ERR. Three states: has a number / is zero / cannot tell — only the first two set the numbers.
# Called directly, never inside $(...): a subshell would lose COUNT_ERR (and the numbers) on the way back.
COUNT_ERR=""; CNT_OBJS=""; CNT_KIB=""
count_loose() {
  local repo="$1" out rc objs kib
  COUNT_ERR=""; CNT_OBJS=""; CNT_KIB=""
  # vazio → no output at all is NOT "zero loose": the numeric check below fails → rc 1 (unreadable); falhou/timeout → rc 1 with the exit code, nothing is measured
  out="$("$TIMEOUT_BIN" -k 10 "$COUNT_TIMEOUT_S" "$GIT" -C "$repo" count-objects -v 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then COUNT_ERR="git count-objects -v ended rc=$rc"; return 1; fi
  objs="$(printf '%s\n' "$out" | awk -F': *' '$1=="count"{print $2; exit}')"
  kib="$(printf '%s\n' "$out" | awk -F': *' '$1=="size"{print $2; exit}')"
  if ! _uint "$objs" || ! _uint "$kib"; then COUNT_ERR="git count-objects -v printed no numeric count/size"; return 1; fi
  CNT_OBJS="$objs"; CNT_KIB="$kib"
}

# free_kib <path> — free KiB of the filesystem, or nothing. GLR_FREE_KIB_CMD (a program that prints the reading) lets a test move the number between readings.
free_kib() {
  # vazio → nothing printed, callers read it as "cannot be read" (never as 0 free and never as plenty); falhou → the same
  if [ -n "${GLR_FREE_KIB_CMD:-}" ]; then "$GLR_FREE_KIB_CMD" "$1" 2>/dev/null; return 0; fi
  jaw_free_kib "$1"
}

# swap_used_mb — integer MB of swap in use, or rc 1 when it cannot be read.
swap_used_mb() {
  local raw v
  if [ -n "${GLR_SWAP_MB_CMD:-}" ]; then
    # vazio → rc 1 (unknown); falhou → the same
    v="$("$GLR_SWAP_MB_CMD" 2>/dev/null)"; _uint "$v" || return 1; echo "$v"; return 0
  fi
  # vazio → sed matched nothing (no "used = N<unit>"): rc 1, unknown; falhou → the same
  raw="$("$SYSCTL" -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)\([KMG]\).*/\1 \2/p')"
  [ -n "$raw" ] || return 1
  awk -v r="$raw" 'BEGIN{split(r,a," "); v=a[1]+0; u=a[2]; if(u=="K")v/=1024; else if(u=="G")v*=1024; printf "%d\n", v}'
}

# discover_repos — one path per line: ROOT, ROOT/<rig>, ROOT/<rig>/crew/<name>, each with a real .git DIRECTORY (a worktree's .git is a file). Dot-directories are not matched by the globs.
discover_repos() {
  local d
  # vazio → a glob that matches nothing stays literal and fails the -d test: no repo from that pattern; falhou → the same
  for d in "$ROOT" "$ROOT"/*/ "$ROOT"/*/crew/*/; do
    d="${d%/}"
    [ -d "$d/.git" ] && echo "$d"
  done | awk '!seen[$0]++'
}

repo_list() {
  if [ -n "$REPOS_OVERRIDE" ]; then printf '%s\n' $REPOS_OVERRIDE; return 0; fi
  discover_repos
}

# ── state (one line per repo: date|status|base|reason) ───────────────────────────────────────────
slugify() { printf '%s' "$1" | tr '/ ' '__'; }
P_DATE=""; P_STATUS=""; P_BASE=0; P_REASON=""
state_load() {
  local f="$STATE_DIR/$(slugify "$1")" line d s b r
  P_DATE=""; P_STATUS=""; P_BASE=0; P_REASON=""
  [ -f "$f" ] || return 0
  # vazio → an empty/corrupt file is "no previous state" (the streak restarts, a repo may be measured once more — harmless); falhou → the same, with a WARN
  line="$(head -n 1 "$f" 2>/dev/null)"
  IFS='|' read -r d s b r <<EOF
$line
EOF
  if [ -z "$d" ] || [ -z "$s" ] || ! _uint "$b"; then say "WARN: state file $f unreadable/corrupt — treated as no previous state"; return 0; fi
  P_DATE="$d"; P_STATUS="$s"; P_BASE="$b"; P_REASON="$r"
}
state_save() { # state_save <repo> <status> <base> <reason>
  local f="$STATE_DIR/$(slugify "$1")"
  mkdir -p "$STATE_DIR" 2>/dev/null || { say "WARN: cannot create $STATE_DIR — state not saved"; return 0; }
  printf '%s|%s|%s|%s\n' "$TONIGHT" "$2" "$3" "$(printf '%s' "$4" | tr '|\n' '  ')" > "$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f" 2>/dev/null || say "WARN: cannot write state $f"
  return 0
}

# ── the run ──────────────────────────────────────────────────────────────────────────────────────
RES_REPO=(); RES_STATUS=(); RES_TEXT=()
N_OK=0; N_DEF=0; N_FAIL=0; N_BELOW=0; N_DONE=0
BASE=0

is_failure() { case "$1" in unreadable|failed|timeout|interrupted|stalled|unverified) return 0 ;; esac; return 1; }
is_deferral() { case "$1" in deferred-*) return 0 ;; esac; return 1; }

finish() { # finish <repo> <status> <text>
  local repo="$1" st="$2" text="$3"
  say "repo=$repo status=$st $text"
  state_save "$repo" "$st" "$BASE" "$text"
  RES_REPO+=("$repo"); RES_STATUS+=("$st"); RES_TEXT+=("$text")
  if is_failure "$st"; then
    N_FAIL=$((N_FAIL + 1))
    notify_send 4 "git-loose-repack: job falhou" "$repo: $st — $text (ver $LOG)"
  elif is_deferral "$st"; then N_DEF=$((N_DEF + 1))
  elif [ "$st" = below ]; then N_BELOW=$((N_BELOW + 1)); N_OK=$((N_OK + 1))
  else N_OK=$((N_OK + 1)); fi
}

stop_tree() { # stop_tree <pid> — TERM (git cleans its tmp_pack), then KILL after a grace
  local pid="$1" i=0
  kill -TERM "$pid" 2>/dev/null
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; fi
}

REPACK_RC=0; REPACK_STOP=""; REPACK_PID=""
run_repack() { # run_repack <repo> <budget_s> — the repack under heavy-guard, with the watchdog
  local repo="$1" budget="$2" pid free bad=0 swap0 swap stop_floor
  stop_floor=$(( (CRITICAL_GB + 1) * KIB_PER_GIB ))
  REPACK_STOP=""
  swap0="$(swap_used_mb)" || swap0=""
  "$TIMEOUT_BIN" -k 30 "$budget" "$HEAVY_GUARD" --what git-loose-repack -- \
    nice -n 10 "$GIT" -C "$repo" -c pack.threads=1 -c pack.windowMemory=100m -c pack.deltaCacheSize=32m repack -d -q >> "$LOG" 2>&1 &
  pid=$!; REPACK_PID="$pid"
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$WATCH_SECS"
    kill -0 "$pid" 2>/dev/null || break
    free="$(free_kib "$repo")"
    if _uint "$free"; then
      bad=0
      if [ "$free" -lt "$stop_floor" ]; then REPACK_STOP="free disk $(gib1 "$free") GiB < $(gib1 "$stop_floor") GiB (Dolt CRITICAL class)"; stop_tree "$pid"; break; fi
    else
      bad=$((bad + 1))
      if [ "$bad" -ge 3 ]; then REPACK_STOP="free disk unreadable for $bad polls in a row"; stop_tree "$pid"; break; fi
    fi
    if [ -n "$swap0" ] && swap="$(swap_used_mb)" && [ "$swap" -gt $((swap0 + SWAP_GROW_MAX_MB)) ]; then
      REPACK_STOP="swap grew $((swap - swap0)) MB (> $SWAP_GROW_MAX_MB MB) since the start"; stop_tree "$pid"; break
    fi
  done
  wait "$pid"; REPACK_RC=$?; REPACK_PID=""
}

process_repo() {
  local repo="$1" objs kib elapsed budget swap free need floor t0 t1 free0 free1 free1_txt objs2 kib2 left wl
  state_load "$repo"
  BASE=0
  if [ -n "$P_DATE" ]; then
    if [ "$P_DATE" = "$TONIGHT" ]; then
      if ! is_deferral "$P_STATUS"; then
        RES_REPO+=("$repo"); RES_STATUS+=("settled"); RES_TEXT+=("$P_STATUS")
        N_DONE=$((N_DONE + 1)); return 0
      fi
      BASE="$P_BASE"
    elif is_deferral "$P_STATUS"; then
      BASE=$((P_BASE + 1))
      if [ "$BASE" -ge "$ALARM_NIGHTS" ]; then
        say "ALARM: $repo ended $BASE nights in a row deferred (last: $P_STATUS — $P_REASON)"
        notify_send 3 "git-loose-repack: $BASE noites sem repack" "$repo: $BASE noites seguidas adiado ($P_STATUS — $P_REASON). Os soltos seguem crescendo. Ver $LOG"
      fi
    fi
  fi

  if ! count_loose "$repo"; then finish "$repo" unreadable "$COUNT_ERR — not measured, nothing done"; return 0; fi
  objs="$CNT_OBJS"; kib="$CNT_KIB"
  if ! [ "$kib" -gt "$LIMIT_KIB" ]; then finish "$repo" below "loose=$objs objs $(mib "$kib") MiB, not over $(mib "$LIMIT_KIB") MiB"; return 0; fi

  # the repack's time: the least of the run's budget left, one repack's cap, and what the window has left less the margin.
  # vazio → jaw_window_left_s printed nothing (the clock cannot be read, or the window is already closed): "no time", never "plenty"; falhou → the same, deferred
  if ! left="$(jaw_window_left_s)"; then finish "$repo" deferred-time "loose=$objs objs $(mib "$kib") MiB; the time left in the window cannot be read, or it has closed"; return 0; fi
  elapsed=$(( $(date +%s) - RUN_T0 ))   # read AFTER the count: a slow count (up to COUNT_TIMEOUT_S) is part of the run's time
  budget=$(( DEADLINE_S - elapsed ))
  if [ "$budget" -gt "$REPACK_TIMEOUT_S" ]; then budget="$REPACK_TIMEOUT_S"; fi
  wl=$(( left - WINDOW_MARGIN_S ))
  if [ "$budget" -gt "$wl" ]; then budget="$wl"; fi
  if [ "$budget" -lt 60 ]; then finish "$repo" deferred-time "loose=$objs objs $(mib "$kib") MiB; only ${budget}s left (run budget ${DEADLINE_S}s, ${elapsed}s used; window left ${left}s less ${WINDOW_MARGIN_S}s margin)"; return 0; fi

  # vazio → swap unreadable: deferred (a repack is not worth the risk blind); falhou → the same
  if ! swap="$(swap_used_mb)"; then finish "$repo" deferred-swap "loose=$objs objs $(mib "$kib") MiB; swap in use cannot be read"; return 0; fi
  if [ "$swap" -ge "$SWAP_START_MAX_MB" ]; then finish "$repo" deferred-swap "loose=$objs objs $(mib "$kib") MiB; swap in use ${swap} MB >= ${SWAP_START_MAX_MB} MB"; return 0; fi

  free="$(free_kib "$repo")"
  if ! _uint "$free"; then finish "$repo" deferred-disk "loose=$objs objs $(mib "$kib") MiB; free disk cannot be read (got '${free:-nothing}')"; return 0; fi
  need=$(( kib * PEAK_PCT / 100 )); floor=$(( (CRITICAL_GB + 1) * KIB_PER_GIB ))
  if [ $(( free - need )) -lt "$floor" ]; then
    finish "$repo" deferred-disk "loose=$objs objs $(mib "$kib") MiB; free $(gib1 "$free") GiB - estimate $(mib "$need") MiB < $(gib1 "$floor") GiB (Dolt CRITICAL + 1)"; return 0
  fi

  free0="$free"; t0=$(date +%s)
  say "repo=$repo repacking: loose=$objs objs $(mib "$kib") MiB, free $(gib1 "$free0") GiB, swap ${swap} MB, budget ${budget}s"
  run_repack "$repo" "$budget"
  t1=$(date +%s)

  if [ -n "$REPACK_STOP" ]; then finish "$repo" interrupted "watchdog stopped the repack after $((t1 - t0))s: $REPACK_STOP"; return 0; fi
  case "$REPACK_RC" in
    75|76) finish "$repo" deferred-disk "heavy-guard refused (rc=$REPACK_RC): the disk is under its floor or cannot be read"; return 0 ;;
    124|137) finish "$repo" timeout "the repack was cut at ${budget}s (rc=$REPACK_RC)"; return 0 ;;
    0) ;;
    *) finish "$repo" failed "git repack ended rc=$REPACK_RC after $((t1 - t0))s (see $LOG)"; return 0 ;;
  esac

  # vazio → the free disk after cannot be read: the line says "?" for it, and the verdict does not depend on it; falhou → the same
  free1="$(free_kib "$repo")"; if _uint "$free1"; then free1_txt="$(gib1 "$free1")"; else free1_txt="?"; fi
  if ! count_loose "$repo"; then
    finish "$repo" unverified "repack ended 0 in $((t1 - t0))s but the count after cannot be read ($COUNT_ERR); before: $objs objs $(mib "$kib") MiB"; return 0
  fi
  objs2="$CNT_OBJS"; kib2="$CNT_KIB"
  if [ "$kib2" -gt "$LIMIT_KIB" ]; then
    finish "$repo" stalled "repack ended 0 but loose is STILL $objs2 objs $(mib "$kib2") MiB (limit $(mib "$LIMIT_KIB") MiB); before: $objs objs $(mib "$kib") MiB"; return 0
  fi
  finish "$repo" repacked "loose $objs -> $objs2 objs, $(mib "$kib") -> $(mib "$kib2") MiB; free $(gib1 "$free0") -> $free1_txt GiB; $((t1 - t0))s"
}

verdict() {
  local word i parts=""
  if [ "$N_FAIL" -gt 0 ]; then word=FALHOU; elif [ "$N_DEF" -gt 0 ]; then word=ADIADO; else word=OK; fi
  for i in $(seq 0 $(( ${#RES_REPO[@]} - 1 ))); do
    case "${RES_STATUS[$i]}" in below|settled) continue ;; esac
    parts="$parts [${RES_REPO[$i]##*/}: ${RES_STATUS[$i]}]"
  done
  say "VEREDITO: $word — $N_BELOW below the limit, $N_DONE settled earlier tonight, $N_DEF deferred, $N_FAIL failed;${parts:- nothing else to report}"
  [ "$word" = FALHOU ] && return 1
  return 0
}

dry_run() {
  local repo objs kib
  echo "git-loose-repack --dry-run: limit $(mib "$LIMIT_KIB") MiB; read-only (no window, no lock, no state, no repack)"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if count_loose "$repo"; then
      objs="$CNT_OBJS"; kib="$CNT_KIB"
      if [ "$kib" -gt "$LIMIT_KIB" ]; then echo "  REPACK    $repo  loose=$objs objs $(mib "$kib") MiB"; else echo "  below     $repo  loose=$objs objs $(mib "$kib") MiB"; fi
    else
      echo "  UNREADABLE $repo  $COUNT_ERR"
    fi
  done <<EOF
$(repo_list)
EOF
  exit 0
}

[ "$DRY" = 1 ] && dry_run

# outside the window is the normal state of 19 hours a day: stdout only, no log line
if ! jaw_window_open; then echo "git-loose-repack: $JAW_REASON — nothing to do"; exit 0; fi

# vazio → `date` printed nothing: TONIGHT empty → refuse (a state keyed on nothing would settle every night as one); falhou → the same
TONIGHT="${GLR_TODAY:-$(date +%F 2>/dev/null)}"
[ -n "$TONIGHT" ] || setup_fail "the local date cannot be read"

# single flight, shared with git-maintenance-runner.sh (mkdir is atomic). A lock older than LOCK_STALE_MIN is a dead run's.
if ! mkdir "$LOCK" 2>/dev/null; then
  # vazio → find printed nothing: the lock counts as fresh (in flight), never as stale; falhou → the same
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
    say "stale lock (> ${LOCK_STALE_MIN} min) — reclaiming"; rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { echo "git-loose-repack: lock contended after reclaim — exit"; exit 0; }
  else
    echo "git-loose-repack: another git maintenance run holds $LOCK — exit (single flight)"; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# a TERM/INT/HUP (the order's timeout, a restart) must not leave a repack running unwatched: stop it, say so, fail the night's run
on_signal() { # on_signal <name> <exit code>
  if [ -n "$REPACK_PID" ] && kill -0 "$REPACK_PID" 2>/dev/null; then stop_tree "$REPACK_PID"; fi
  say "VEREDITO: FALHOU — the run was ended by $1 while working; a repack in flight was stopped; nothing is settled for tonight"
  notify_send 4 "git-loose-repack: job falhou" "a execução foi encerrada por $1 no meio do trabalho (ver $LOG)"
  exit "$2"
}
trap 'on_signal TERM 143' TERM
trap 'on_signal INT 130' INT
trap 'on_signal HUP 129' HUP

RUN_T0=$(date +%s)
while IFS= read -r _repo; do
  [ -n "$_repo" ] || continue
  process_repo "$_repo"
done <<EOF
$(repo_list)
EOF

if [ "${#RES_REPO[@]}" -eq 0 ]; then say "VEREDITO: FALHOU — the repo list is EMPTY (ROOT=$ROOT, GLR_REPOS='${REPOS_OVERRIDE}'): nothing was measured"; notify_send 4 "git-loose-repack: job falhou" "lista de repos vazia (ROOT=$ROOT) — nada foi medido. Ver $LOG"; exit 1; fi
# a tick whose every repo was already settled has nothing new to say
if [ "$N_DONE" -eq "${#RES_REPO[@]}" ]; then exit 0; fi
verdict
