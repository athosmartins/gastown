#!/bin/bash
# nightly-reboot.sh — recurring nightly reboot to reclaim the macOS swap
# ratchet that never releases on its own (ga-i9q44).
#
# ⚠️ STATUS (updated 2026-09-05, ga-nnp5b): the 2026-09-04 AND 2026-09-05
# fires both SKIPPED — kern.boottime never advanced past 2026-09-02 despite
# firing two nights running. Root cause: the LaunchDaemon fires at 01:00:00,
# squarely in the tail of the 00:00-00:30 nightly job burst (7 jobs hitting
# Dolt/disk); bd/Dolt were still too busy to answer at 01:00:00 both nights,
# gate-queue-composition.sh returned rc=2 (UNKNOWN), and this script
# correctly fail-closed — but did so EVERY night, silently, so the reboot
# that exists specifically to relieve swap pressure never relieved it: swap
# rose 14336M->15360M in ~30min on the night of 04->05, until disk hit
# ENOSPC and took Dolt down city-wide (ga-nnp5b).
#
# THE FIX BELOW, AND WHY IT DOES NOT MOVE THE 01:00 SLOT: ga-nnp5b's own
# text asks to move the LaunchDaemon's StartCalendarInterval to a slot
# outside the burst. That plist lives at /Library/LaunchDaemons/, owned
# root:wheel, and reinstalling it needs `sudo launchctl bootout`+`bootstrap`
# — a step this bug's autonomous builder session cannot perform
# (`Bash(sudo:*)` is an "ask" rule in ~/.claude/settings.json; an unattended
# session that hits it just hangs forever waiting for an approval that will
# never come — the same class of trap as the documented ga-gkap9p `rm -rf`
# incident). Rather than leave that half of the fix as a "someone should
# sudo this" doc that may never get executed — which is literally how
# ga-i9q44 itself was born, an authorization that never became a live
# mechanism — Guards 2+3 below are rewritten to retry the WHOLE pre-flight
# evaluation, together, patiently, for up to ~90 minutes past the 01:00
# fire. That's long enough to span BOTH gaps a fresh 2026-09-05 survey of
# every StartCalendarInterval job on this box found genuinely clear of
# other jobs (01:41-02:14 and 02:18-02:59), and to stop comfortably short of
# the dense Dolt/backup cluster starting at 03:00 (dolthub-backup,
# dolt-s3-backup, dolt-compact-routine, backup-all-dbs, pbh-freshness, a
# 6-way pileup at 04:00). Net effect is the same as moving the fire time —
# the actual reboot decision lands wherever the night turns out to be quiet
# — without touching a root-owned file this session has no way to safely
# change. Guard 1's 01:00-01:19 window for the LEGACY flow is unchanged (ga-a2v0bz
# adds a 23:00-23:19 DRAIN window beside it — see DRAIN MODE below): it only gates
# the initial fire (rejecting a late launchd replay), not how long the retry
# loop below may then run once that initial fire is accepted.
#
# A separate, additive fix for item 4 of ga-nnp5b ("alarme quando o job
# pular N noites seguidas — hoje falha em silêncio"): the existing
# per-night notify_athos() SKIP push already fired both nights and went
# unnoticed. record_skip()/reset_streak() below track how many nights IN A
# ROW ended in a skip (any guard, any reason — the swap ratchet doesn't
# care WHY the reboot didn't happen) and escalate louder + durably (mail to
# mayor, which the doctrine already uses for automated Dolt-trouble
# escalation) once that streak crosses NIGHTLY_REBOOT_ALARM_THRESHOLD.
#
# ga-i9q44 itself stays open pending two consecutive clean nights of log
# evidence (fired -> real reboot, kern.boottime advances) before it accepts
# — do not close it from this bug alone.
#
# WHY A REAL-TIME PRE-CHECK, NOT JUST A QUIET TIMER SLOT: city-night-window
# (the mechanism that would guarantee the whole city is quiet 00:00-08:00) is
# OFF by deliberate Athos decision since 2026-08-20, for token-cost reasons —
# see scripts/city-night-window.sh's own header. So no calendar slot is
# structurally guaranteed idle; this script checks REAL in-flight state at
# fire-time instead. The two hard gates below started as exactly what the
# 2026-08-29 human-supervised reboot required
# (docs/runbooks/reboot-20260829-pre.txt): zero gate markers in flight, zero
# hq beads in_progress. The second was relaxed by ga-2vl5yr: a human reads
# "in_progress" and knows which of those beads has a builder behind it; a script
# that counts them never reaches zero once the Mayor keeps a mission bead open
# (12 skipped nights, swap 9 GB, disk 4.7 GB). Guard 3 now blocks only on an
# hq bead whose assignee is a live, non-coordinator session that touched it
# recently — rule, rationale and knobs in the comment above guard_hq_in_progress().
# Non-hq in-progress beads (e.g. wa crew work) are logged but NOT blocking —
# that precedent already treated those as fine, since inflight-reclaim-guard
# reclaims them afterward regardless of reboot.
#
# Runs as root (LaunchDaemon, no UserName key) so it can call /sbin/shutdown
# directly, same as the proven com.athos.reboot-once-0700 /
# reboot_once_0700.sh precedent — this sidesteps any TCC/GUI-session
# ambiguity an osascript-from-a-LaunchAgent approach would carry.
#
# FAIL-CLOSED (the LEGACY 01:00 flow): any check this script cannot complete
# (bd/gc unreachable, gate composition script errors) is treated as "unknown →
# do not reboot", never as "zero → safe". An error and an empty result must not
# collapse to the same value (see [[error-empty-must-not-produce-same-value]]).
# The retry loop only buys TIME for a transient condition to clear — the LAST
# attempt in the budget still fail-closes exactly like before if nothing ever
# clears. In DRAIN mode (23:00, ga-a2v0bz) only the two SAFETY guards (a send in
# flight, Dolt maintenance) are fail-closed. Gate / hq / scraper are
# informational there: an unreadable one is logged as "unknown" or "TIMED OUT"
# and does NOT hold the reboot — and every bd/Dolt call between the fire and the
# shutdown, the SKIP bookkeeping included, has a deadline (run_bounded: TERM at the
# deadline, KILL after a short grace — a call that ignores TERM does not outlive it),
# because a call that can veto the reboot by hanging is the same silent failure this
# mode exists to end. Not bounded (none of them is a bd/Dolt call, which is the class this
# deadline covers): `softwareupdate --install` (an install is long by design and must
# not be cut), `softwareupdate --list --no-scan` (macos_update_check_state, local cache),
# notify (its own curl/mail limits), `sync` and `sudo`.
#
# NOTIFY ROUTING: `notify` sends to the silent digest unless the message is on its
# allowlist or NOTIFY_FORCE_PUSH is set (-p 4/5 and a "🚨" do not force it). Alarm-grade
# messages — a skipped night, the N-in-a-row alarm — are sent with route=push; progress
# notes stay on the digest. nightly-reboot.drain.selftest.sh asks the REAL notify
# (NOTIFY_ROUTE_TEST=1) where each of them lands.
#
# MANUAL REBOOTS (the Mayor's, or anyone's, ga-7e3fwa): run
#     scripts/nightly-reboot.sh --check-guards
# BEFORE rebooting by hand. Measured: the manual reboots of 2026-09-26 03:36,
# 09-27 05:50, 09-28 13:08 and 09-29 06:56 (osascript -> loginwindow, each
# authorized for swap pressure) killed the property_scrapers nightly because
# that path never went through Guard 4 — this script had no way to just CHECK.
# The mode runs Guards 2+3+4 once, through the very same functions the nightly
# uses, and prints one line per guard:
#     guard2 gate-markers: ok
#     guard3 hq-in-progress: BLOCK hq beads in_progress = 1 blocking: ga-xyz [builder gastown.dog-1 (gastown.dog), touched 3m ago]
#     guard4 scraper-daily: unknown <why it could not tell>
# Three states, never collapsed: ok (safe), BLOCK (something is in flight),
# unknown (the guard could not look — NOT safe). An "ok" can carry a caveat,
# e.g. "guard2 gate-markers: ok (3 unreadable markers, ...)": markers the gate
# could not classify never block (nightly rule, unchanged) but are not silent.
# Exit 0 only if all three are ok, and 1 for BLOCK and unknown alike — read the
# label, not just the code. Every guard is evaluated even after one blocks, so a
# single run shows everything in the way, one line each even when the command's
# stderr spans several. There is no timeout: a wedged Dolt hangs this like it
# hangs bd (Ctrl-C = treat as unknown; macOS has no /usr/bin/timeout, and the
# nightly must not gain a dependency on one). It does NOT reboot, does NOT
# touch the skip streak, sends no mail or notify, writes nothing to the nightly
# log, and ignores the 01:00-01:19 window (a manual reboot is not at 01:05). An
# unknown argument is refused with exit 2 — a typo must never fall through into
# the real flow.
# A Guard 4 BLOCK means: wait for the rodada to finish, or write in the
# reboot runbook (docs/runbooks/reboot-*-pre.txt) that it WILL be killed.

set -uo pipefail

CHECK_GUARDS_ONLY=0
if [ "$#" -eq 1 ] && [ "$1" = "--check-guards" ]; then
    CHECK_GUARDS_ONLY=1
elif [ "$#" -ne 0 ]; then
    echo "usage: nightly-reboot.sh [--check-guards]" >&2
    exit 2
fi

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC_BIN:-/opt/homebrew/bin/gc}"
BD="${BD_BIN:-/opt/homebrew/bin/bd}"
SHUTDOWN_BIN="${SHUTDOWN_BIN:-/sbin/shutdown}"
LOG="${CITY}/.gc/logs/nightly-reboot.log"
STREAK_FILE="${CITY}/.gc/logs/nightly-reboot.streak"
NOTIFY_AS_USER="${NOTIFY_AS_USER:-athos}"
NOTIFY_BIN="${NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
# Unique per-invocation temp files (not fixed /tmp names): a fixed name
# reused night after night ends up owned by whichever user first created it
# (root, in production) — a later run under a different user (e.g. testing
# this script by hand) then gets a silent "Permission denied" on the stderr
# redirect instead of the diagnostic it's there to capture.
GATE_ERR="$(mktemp -t nightly-reboot-gate-err)"
HQ_ERR="$(mktemp -t nightly-reboot-hq-err)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}" 2>/dev/null; }
# notify_athos <title> <body> [priority] [route]
# `notify` ROUTES by an allowlist whose DEFAULT is the silent hourly digest: -p 4/-p 5 and
# a "🚨" in the title do not change that. Measured (ga-a2v0bz) in notify's own history.db,
# 2026-09-04..10-01: 47 of 47 "Reboot noturno…" messages this script sent were routed to the
# digest, none to the push — the per-night SKIP (22x) and the six "🚨 N noites seguidas"
# alarms (N=2..12) included. route=push sets
# NOTIFY_FORCE_PUSH=1 for the alarm-grade ones (a skipped night, a streak). `env` carries the
# variable across sudo's env_reset, which would drop a plain `VAR=1 sudo ...`. Routine
# progress ("Reiniciando às…", the update notes) stays on the digest on purpose.
notify_athos() {
  # Root can sudo to another user with no password — same trick
  # reboot_once_0700.sh used for its pre-reboot heads-up.
  if [ "${4:-}" = "push" ]; then
    sudo -u "${NOTIFY_AS_USER}" /usr/bin/env NOTIFY_FORCE_PUSH=1 "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
  else
    sudo -u "${NOTIFY_AS_USER}" "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
  fi
}

# --- DRAIN MODE: signal helpers (ga-a2v0bz) --------------------------------
# From 23:00 the city DRAINS: this script writes DRAIN_FILE, which pilot,
# quality-gate, refino-gate, auto-refino and context-check read (via
# quiet-hours-check.sh, _drain_window_blocks) to stop ADMITTING new work. It
# carries the boot-epoch it was written under, so the reboot itself invalidates
# it — nothing needs to clear it after boot. Everything here is best-effort and
# FAILS TOWARD "the city keeps working": if the signal cannot be written the
# reboot still proceeds on the safety guards alone, and if this script dies the
# EXIT trap removes the signal (a hard kill is bounded by the reader's
# staleness window, 30min, and by DRAIN_MAX_SECS below). The one exception is a
# death inside the shutdown call itself: see drain_cleanup.
DRAIN_REBOOT_AT="${NIGHTLY_REBOOT_REBOOT_AT:-23:40}"
DRAIN_FILE="${NIGHTLY_REBOOT_DRAIN_FILE:-/Users/athos/.gastown/run/city-drain.level}"
DRAIN_MAX_SECS="${NIGHTLY_REBOOT_DRAIN_MAX_SECS:-5400}"          # hard ceiling: 23:00 + 90min covers wait + safety budget + a macOS install
DRAIN_STAMP_INTERVAL="${NIGHTLY_REBOOT_DRAIN_STAMP_INTERVAL:-300}"
PENDING_FILE="${NIGHTLY_REBOOT_PENDING_FILE:-${CITY}/.gc/logs/nightly-reboot.pending}"
DRAIN_ACTIVE=0
DRAIN_STARTED=""
DRAIN_SLEEP_PID=""

# boot_epoch: kern.boottime's `sec` by EXACT TOKEN. `sysctl -n kern.boottime`
# prints `{ sec = 1789579812, usec = 958892 } Wed Sep 16 ...` and a greedy
# `.*sec = ([0-9]+)` matches the "sec" inside "usec" and returns the
# microseconds (ga-ljncyt, ga-rc7tz: third time this city hit it).
boot_epoch() {
  sysctl -n kern.boottime 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }'
}

# drain_stamp: (re)write the signal atomically: DRAIN | written | boot | until.
# `until` is fixed at DRAIN_STARTED + DRAIN_MAX_SECS and never extended.
drain_stamp() {
  local boot tmp prev
  boot="$(boot_epoch)"
  case "${boot}" in ''|*[!0-9]*)
    log "ERROR: drain: kern.boottime unreadable — NOT writing the drain signal (it could not be tied to this boot, and an unprovable signal is ignored by the readers anyway)"
    return 1 ;;
  esac
  tmp="${DRAIN_FILE}.tmp.$$"
  # Take over the cleanup duty BEFORE the file can exist. This flag used to be set after the
  # `mv`: a TERM that landed between the two (the trap runs as soon as `mv` returns) ran the
  # EXIT trap with DRAIN_ACTIVE still 0, which then removed nothing — the city stayed drained
  # until the reader's 30min staleness window. A cleanup that finds no file removes nothing,
  # so claiming early is harmless; the flag goes back only if the write failed.
  prev="${DRAIN_ACTIVE:-0}"
  DRAIN_ACTIVE=1
  if { printf 'DRAIN\n%s\n%s\n%s\n' "$(date +%s)" "${boot}" "$(( DRAIN_STARTED + DRAIN_MAX_SECS ))" > "${tmp}" \
       && chmod 644 "${tmp}" && mv -f "${tmp}" "${DRAIN_FILE}"; } 2>/dev/null; then
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null
  DRAIN_ACTIVE="${prev}"
  log "ERROR: drain: could not write ${DRAIN_FILE} — the drain is INERT tonight; the reboot proceeds on the safety guards alone"
  return 1
}

# drain_end: release the city NOW (a skipped night must not keep it frozen).
drain_end() {
  rm -f "${DRAIN_FILE}" 2>/dev/null
  if [ -e "${DRAIN_FILE}" ]; then
    log "ERROR: drain: could not remove ${DRAIN_FILE} — it will expire on its own (<=30min stale window, hard ceiling DRAIN_MAX_SECS)"
  else
    log "drain: signal removed — the city admits new work again"
  fi
  DRAIN_ACTIVE=0
}

# EXIT trap target: any way out of this script releases the drain, EXCEPT the shutdown call
# itself: reboot_now_sequence sets DRAIN_ACTIVE=0 right BEFORE it invokes shutdown, so this
# trap finds nothing to release on either way out of that call — the rc 0 return, or the TERM
# the OS sends the script while the shutdown runs (trap 'exit 143' -> here; on the nights
# that reboot this is the path that runs, the line after `shutdown -r now` is never reached).
# The signal is left on disk until the reboot invalidates it: releasing the gates seconds
# before the machine goes down would let work start that the reboot then kills. A failed
# shutdown (rc != 0) releases it explicitly (drain_end) and so does every skip, kill or
# error before the call.
drain_cleanup() {
  [ -n "${DRAIN_SLEEP_PID:-}" ] && kill "${DRAIN_SLEEP_PID}" 2>/dev/null
  # Release the city FIRST: taking a probe's process tree down can cost a TERM -> KILL grace
  # (seconds), and the dispatchers should not stay paused behind it. The temp file is this
  # shell's own ($$): a kill that lands mid-write must not leave it behind either.
  if [ "${DRAIN_ACTIVE:-0}" = "1" ]; then
    rm -f "${DRAIN_FILE}" "${DRAIN_FILE}.tmp.$$" 2>/dev/null
    DRAIN_ACTIVE=0
  fi
  # a kill that lands while run_bounded waits must take the probe (bd, and whatever
  # bd started) down with it, not leave it running past this script
  [ -n "${BOUNDED_WD:-}" ] && kill "${BOUNDED_WD}" 2>/dev/null
  [ -n "${BOUNDED_PID:-}" ] && _kill_tree_escalate "${BOUNDED_PID}"
  return 0
}
trap 'drain_cleanup; rm -f "${GATE_ERR}" "${HQ_ERR}"' EXIT

# drain_sleep <secs>: sleep that a TERM/INT/HUP can interrupt AT ONCE. A bare
# foreground `sleep` defers the trap until it returns, so a kill during the
# 40-minute wait would leave the drain on the disk for the whole stretch.
drain_sleep() {
  sleep "$1" &
  DRAIN_SLEEP_PID=$!
  wait "${DRAIN_SLEEP_PID}" 2>/dev/null
  DRAIN_SLEEP_PID=""
  return 0
}

# --- Deadlines for calls that can hang (ga-a2v0bz, gate fix 1) -------------
# bd / gc / gate-queue-composition.sh talk to Dolt, and a wedged Dolt does not
# fail, it WAITS (ga-nnp5b: the night swap relief mattered most was the night Dolt
# was sick). In the legacy flow bd had already answered before any reboot step
# ran, so a call after that point could trust it. In drain mode the safety
# guards never touch bd, so the FIRST bd contact is an "informational" one — and
# with no deadline it vetoes the reboot by hanging, with the log's last line
# saying "rebooting". run_bounded gives such a call a deadline; the caller turns
# a missed deadline into an explicit "unknown" and goes on.
BOUNDED_PID=""
BOUNDED_WD=""
INFO_PROBE_TIMEOUT="${NIGHTLY_REBOOT_INFO_PROBE_TIMEOUT_SECS:-30}"   # one informational probe
INFO_BUDGET_SECS="${NIGHTLY_REBOOT_INFO_BUDGET_SECS:-75}"            # all of them together
case "${INFO_PROBE_TIMEOUT}" in ''|*[!0-9]*|0) INFO_PROBE_TIMEOUT=30 ;; esac
case "${INFO_BUDGET_SECS}" in ''|*[!0-9]*|0) INFO_BUDGET_SECS=75 ;; esac
INFO_DEADLINE=0

# _tree_pids <pid>: <pid> and everything below it, one per line, leaves first. The
# list is taken BEFORE anything is signalled: a parent killed first re-parents its
# children to launchd and `pgrep -P` can no longer find them.
_tree_pids() {
  local c
  for c in $(/usr/bin/pgrep -P "$1" 2>/dev/null); do _tree_pids "${c}"; done
  echo "$1"
}

# _kill_tree_escalate <pid>: TERM the tree, give it KILL_GRACE seconds, then KILL
# whatever is still alive (gate FAIL 3/3). A deadline that is one TERM is only a deadline
# for children that honor TERM: `trap '' TERM; while :; do sleep 1; done` ignores it, and
# run_bounded, which `wait`s for the child, then never returned — the silent hang the
# deadlines exist to end. The survivors are looked up in the snapshot taken before the
# TERM, so a child its parent's death re-parented is still found. Counted with $SECONDS
# and `kill -0` (builtins), like the rest of the deadline code.
_kill_tree_escalate() {
  local pids p alive end
  pids="$(_tree_pids "$1")"
  for p in ${pids}; do kill -TERM "${p}" 2>/dev/null; done
  end=$(( SECONDS + ${NIGHTLY_REBOOT_KILL_GRACE_SECS:-2} ))
  while :; do
    alive=""
    for p in ${pids}; do kill -0 "${p}" 2>/dev/null && alive="${alive} ${p}"; done
    [ -z "${alive}" ] && return 0
    [ "${SECONDS}" -ge "${end}" ] && break
    sleep 1 2>/dev/null || :
  done
  for p in ${alive}; do kill -KILL "${p}" 2>/dev/null; done
  return 0
}

# run_bounded <secs> <outfile> <cmd...>: run <cmd> with stdout+stderr in <outfile>;
# if it has not finished in <secs>, kill it and everything it started. Returns
# the command's own rc, or 124 when the deadline fired. <cmd> may be a shell
# function (it runs in a subshell, so it cannot set variables here — print what
# the caller needs). macOS has no timeout(1), and the nightly must not gain a
# dependency on one. The deadline is counted with $SECONDS and `kill -0`, which
# are builtins: it does not need a fork to succeed, and a box at load 60-88 is
# exactly where a fork may not. `wait` returns the moment a trapped TERM arrives,
# so a kill is never deferred behind a hung call (the foreground-call hazard).
run_bounded() {
  local secs="$1" out="$2" rc
  shift 2
  rm -f "${out}.deadline"
  "$@" > "${out}" 2>&1 &
  BOUNDED_PID=$!
  (
    end=$(( SECONDS + secs ))
    while kill -0 "${BOUNDED_PID}" 2>/dev/null; do
      if [ "${SECONDS}" -ge "${end}" ]; then
        : > "${out}.deadline"
        _kill_tree_escalate "${BOUNDED_PID}"
        break
      fi
      sleep 1 2>/dev/null || :
    done
  ) >/dev/null 2>&1 &
  BOUNDED_WD=$!
  wait "${BOUNDED_PID}" 2>/dev/null; rc=$?
  if [ -e "${out}.deadline" ]; then
    # The deadline fired, so the watchdog is escalating TERM -> KILL on the tree. <cmd> (a
    # function in a subshell) dies at the TERM and ends the `wait` above at once — but what IT
    # started (bd) may ignore TERM, and only the watchdog's KILL stage reaches it. Killing the
    # watchdog here, as the normal path does, left exactly those orphans alive (E18). Bounded:
    # one KILL_GRACE and a poll.
    wait "${BOUNDED_WD}" 2>/dev/null
  else
    kill "${BOUNDED_WD}" 2>/dev/null
    wait "${BOUNDED_WD}" 2>/dev/null
  fi
  BOUNDED_PID=""; BOUNDED_WD=""
  if [ -e "${out}.deadline" ]; then rm -f "${out}.deadline"; return 124; fi
  return "${rc}"
}

# record_skip with a deadline. record_skip (the streak + alarm block below, which the legacy
# selftest extracts verbatim, so it stays as it is) ends in `gc mail send`, and that writes a
# bead: with Dolt wedged it hangs, the instance never exits, and launchd does not start the
# next night while this one is still "running" — a SKIP that silently becomes every night's
# SKIP. The streak file is written FIRST inside record_skip, so a timeout keeps the count.
SKIP_RECORD_TIMEOUT="${NIGHTLY_REBOOT_SKIP_RECORD_TIMEOUT_SECS:-120}"   # notify can use ~75s of it, the mail the rest
case "${SKIP_RECORD_TIMEOUT}" in ''|*[!0-9]*|0) SKIP_RECORD_TIMEOUT=120 ;; esac
record_skip_bounded() {
  local out rc
  out="$(mktemp -t nightly-reboot-skip)"
  run_bounded "${SKIP_RECORD_TIMEOUT}" "${out}" record_skip "$1"; rc=$?
  if [ "${rc}" -eq 124 ]; then
    log "ERROR: recording the skip (notify + alarm mail) TIMED OUT after ${SKIP_RECORD_TIMEOUT}s — the streak count is already on disk, but the alarm may not have gone out (Dolt not answering?)"
  fi
  rm -f "${out}" "${out}.deadline"
  return 0
}

# The informational phase (guard report + rig counts) shares ONE time budget, so a
# bad night costs at most INFO_BUDGET_SECS before the reboot, not N x timeout.
info_begin() { INFO_DEADLINE=$(( SECONDS + INFO_BUDGET_SECS )); }
# info_probe_secs: how long the next probe may run — INFO_PROBE_TIMEOUT, but never
# past the shared deadline. 0 = the budget is spent.
info_probe_secs() {
  local left=$(( INFO_DEADLINE - SECONDS ))
  [ "${left}" -gt "${INFO_PROBE_TIMEOUT}" ] && left="${INFO_PROBE_TIMEOUT}"
  [ "${left}" -lt 0 ] && left=0
  printf '%s' "${left}"
}

# --- Consecutive-skip streak (ga-nnp5b item 4) ----------------------------
# Every SKIP below sends a per-night notify — it only LOOKED like a push until
# ga-a2v0bz: notify routes to the digest by default (history.db: 0 of 47 of this script's
# messages ever pushed), so the notify that was meant to catch a run of skipped nights
# (ga-nnp5b: two nights went unnoticed while swap climbed to ENOSPC) could not. The SKIP
# and the alarm below now ask for route=push. This
# tracks how many nights IN A ROW ended in a skip (any guard, any reason —
# the swap ratchet does not care WHY the reboot didn't happen) and escalates
# louder + durably once that streak is long enough to matter, instead of
# relying on a push notification that can go unread forever.
#
# nightly-reboot.selftest.sh:STREAK-FUNCTIONS-START — sentinel for the
# selftest, which extracts exactly this block (via sed, to this file's
# matching END sentinel below) to unit-test the streak logic in total
# isolation from Guards 1-3 and the reboot call. Deliberate: those guards
# and the final /sbin/shutdown invocation must NEVER execute during a test
# (see the selftest's own header for why — the short version is that the
# quality gate replays this exact test file, unmodified, against the
# PRE-FIX commit of this script as part of an automated check, and that
# older script has no override hook for the reboot call at all). Keep this
# block self-contained (no reference to CITY/GC/BD/etc. beyond what's
# already visible above it) if you touch it, so the extraction keeps working.
ALARM_THRESHOLD="${NIGHTLY_REBOOT_ALARM_THRESHOLD:-2}"
read_streak() {
  local n
  n=$(cat "${STREAK_FILE}" 2>/dev/null)
  case "${n}" in (''|*[!0-9]*) n=0 ;; esac
  printf '%s' "${n}"
}
reset_streak() { printf '0\n' > "${STREAK_FILE}" 2>/dev/null || true; }
record_skip() {
  local reason="$1" n
  n=$(( $(read_streak) + 1 ))
  printf '%s\n' "${n}" > "${STREAK_FILE}" 2>/dev/null || true
  log "skip streak: ${n} consecutive night(s) without a reboot (reason: ${reason})"
  if [ "${n}" -gt 0 ] && [ $((n % ALARM_THRESHOLD)) -eq 0 ]; then
    log "ALARM: ${n} consecutive skipped nights (threshold ${ALARM_THRESHOLD}) — escalating to mayor"
    notify_athos "🚨 Reboot noturno: ${n} noites seguidas sem reiniciar" "Motivo mais recente: ${reason}. Swap pode estar acumulando sem alívio. Ver ${LOG}." 5 push
    "${GC}" --city "${CITY}" mail send mayor --from nightly-reboot.sh \
      -s "nightly-reboot: ${n} noites seguidas sem reiniciar (ga-nnp5b)" \
      -m "$(printf 'O reboot noturno pulou %s noites seguidas (fail-closed, correto por si so, mas nunca chega a aliviar o swap).\nMotivo mais recente: %s\nLog: %s\nSe isto continuar, investigar se a causa e estrutural (nao so um hiccup transiente) antes que vire ENOSPC de novo.' "${n}" "${reason}" "${LOG}")" \
      >/dev/null 2>&1 || true
  fi
}
# nightly-reboot.selftest.sh:STREAK-FUNCTIONS-END

# --- macOS update install-before-reboot (ga-l5m50, hardened by ga-i8n6s) ---
# ga-i9q44 reboots nightly to reclaim swap; separately, AutomaticDownload=1
# means macOS downloads recommended updates in the background on its own
# (AutomaticallyInstallMacOSUpdates stays 0 — deliberately: Athos chose to
# install in OUR nightly window, not delegate the policy to macOS). Without
# this, a fully-downloaded update sits on disk forever (measured: ~2.7GB,
# macOS Tahoe 26.6.2) because nothing ever tells it to install. This installs
# it right before the existing reboot, reusing that reboot rather than
# triggering a second one.
#
# ga-i8n6s: rc=0 from `--install` is NOT proof the update installed. Measured
# live 2026-09-11: softwareupdate printed "Not enough free disk space: a
# total of 17.13 GB is required." and still exited 0 — the original code
# below trusted that rc and logged "instalado com sucesso", so the Tahoe
# 26.6.2 update sat pending in silence night after night. Fix asks the same
# --list --no-scan question again AFTER the install attempt (three states:
# clear/pending/unknown — never collapse "couldn't tell" into "succeeded",
# see [[error-empty-must-not-produce-same-value]]), and — as a cheap,
# approximate optimization only, NOT a substitute for that re-check — skips
# the attempt entirely on a night that is obviously hopeless on free space.
#
# nightly-reboot.selftest.sh:MACOS-UPDATE-FUNCTIONS-START — sentinel for the
# selftest, which extracts exactly this block (via sed) to unit-test this
# logic in total isolation from Guards 1-3 and the reboot call — same reason
# as the streak block above (see its own comment): the quality gate replays
# this selftest, unmodified, against the pre-fix commit, which has no
# override hook for a real `softwareupdate --install` call either. Keep this
# block self-contained (log()/notify_athos() already defined above,
# SOFTWAREUPDATE_BIN/MACOS_UPDATE_MIN_FREE_GB overridable) if you touch it.
SOFTWAREUPDATE_BIN="${SOFTWAREUPDATE_BIN:-/usr/sbin/softwareupdate}"
MACOS_UPDATE_MIN_FREE_GB="${MACOS_UPDATE_MIN_FREE_GB:-10}"

# Sets MACOS_UPDATE_STATE to "pending" | "clear" | "unknown" and
# MACOS_UPDATE_REASON to a human string, by asking --list --no-scan the same
# question every time: is anything with Action: restart still pending? Used
# both to decide whether to attempt an install (state != "pending" -> nothing
# to do) and, after attempting one, to verify it actually took effect (state
# != "pending" anymore) instead of trusting softwareupdate's own exit code.
macos_update_check_state() {
  # --no-scan: report from the catalog the AutomaticDownload daemon already
  # scanned in the background — never triggers a fresh scan/download of our
  # own at 01:00. Only a label whose Action includes "restart" counts as
  # ready: that is the distinction this bead asks for between "an update
  # exists" (could be a Safari/config-data-only entry that needs no reboot,
  # or one still downloading) and "ready to install".
  SU_LIST_OUT=$("${SOFTWAREUPDATE_BIN}" --list --no-scan 2>/dev/null)
  SU_LIST_RC=$?
  if [ "${SU_LIST_RC}" -ne 0 ]; then
    MACOS_UPDATE_STATE="unknown"
    MACOS_UPDATE_REASON="softwareupdate --list --no-scan failed (rc=${SU_LIST_RC})"
    return 0
  fi
  if printf '%s' "${SU_LIST_OUT}" | grep "Action: restart" >/dev/null; then
    MACOS_UPDATE_STATE="pending"
    MACOS_UPDATE_REASON="update with Action: restart pending"
  else
    MACOS_UPDATE_STATE="clear"
    MACOS_UPDATE_REASON="no update with Action: restart pending"
  fi
  return 0
}
macos_update_ready() {
  macos_update_check_state
  [ "${MACOS_UPDATE_STATE}" = "pending" ]
}

# Cheap, approximate pre-check only — NOT a substitute for the post-install
# re-check in macos_update_install_if_ready below. There is no way to know in
# advance exactly how much space a given update needs (the 17.13GB figure in
# ga-i8n6s came from softwareupdate itself, mid-attempt); this only catches a
# night that is obviously hopeless on space, to skip wasting the attempt.
macos_update_free_gb() {
  local avail_kb
  avail_kb=$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
  case "${avail_kb}" in (''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( avail_kb / 1024 / 1024 ))
  return 0
}

macos_update_install_if_ready() {
  if ! macos_update_ready; then
    log "macOS update: ${MACOS_UPDATE_REASON} — reboot normal (sem instalar)"
    return 0
  fi

  local free_gb
  free_gb=$(macos_update_free_gb)
  if [ -n "${free_gb}" ] && [ "${free_gb}" -lt "${MACOS_UPDATE_MIN_FREE_GB}" ]; then
    log "macOS update pendente, mas só ${free_gb}GB livres (mínimo ${MACOS_UPDATE_MIN_FREE_GB}GB) — pulando a instalação pra não gastar tempo à toa; reboot normal"
    notify_athos "Reboot noturno: update de macOS pulado" "Só ${free_gb}GB livres (mínimo ${MACOS_UPDATE_MIN_FREE_GB}GB) — não tentei instalar. Ver ${LOG}." 3
    return 0
  fi

  log "macOS update pendente (Action: restart) — instalando antes do reboot; pode demorar mais que o normal (ga-l5m50)"
  notify_athos "Reboot noturno" "Instalando atualização de macOS antes de reiniciar — pode levar mais tempo que o normal." 3
  SU_INSTALL_OUT=$("${SOFTWAREUPDATE_BIN}" --install --all --no-scan --agree-to-license 2>&1)
  local su_rc=$?
  printf '%s\n' "${SU_INSTALL_OUT}" >>"${LOG}"

  # rc alone is not trustworthy (ga-i8n6s: rc=0 measured with nothing
  # actually installed) — ask the same pending/clear/unknown question again
  # to see what really happened.
  macos_update_check_state
  if [ "${MACOS_UPDATE_STATE}" = "clear" ]; then
    log "macOS update instalado com sucesso (rc=${su_rc})"
    return 0
  fi

  if printf '%s' "${SU_INSTALL_OUT}" | grep -i "not enough free disk space" >/dev/null; then
    local disk_msg
    disk_msg=$(printf '%s' "${SU_INSTALL_OUT}" | grep -i "not enough free disk space" | head -1)
    log "ERROR: macOS update falhou por falta de espaço em disco (rc=${su_rc}): ${disk_msg} — update continua pendente; prosseguindo com o reboot mesmo assim"
    notify_athos "Reboot noturno: update falhou (disco cheio)" "${disk_msg} — reiniciando sem instalar. Ver ${LOG}." 4
    return 0
  fi

  if [ "${MACOS_UPDATE_STATE}" = "unknown" ]; then
    log "ERROR: macOS update — não consegui confirmar se instalou (rc=${su_rc}; ${MACOS_UPDATE_REASON}) — prosseguindo com o reboot mesmo assim"
    notify_athos "Reboot noturno: update indeterminado" "Não consegui confirmar se o update instalou (rc=${su_rc}) — ver ${LOG}." 4
    return 0
  fi

  log "ERROR: macOS update falhou ao instalar (rc=${su_rc}) — update continua pendente; prosseguindo com o reboot mesmo assim"
  notify_athos "Reboot noturno: update falhou" "softwareupdate retornou ${su_rc} e o update continua pendente — reiniciando sem instalar. Ver ${LOG}." 4
  return 0
}
# nightly-reboot.selftest.sh:MACOS-UPDATE-FUNCTIONS-END

# --check-guards is a read-only preflight, not a fire of the nightly job: it
# neither writes the "fired" line nor is subject to the window below.
[ "${CHECK_GUARDS_ONLY}" -eq 1 ] || log "=== fired (uptime: $(uptime | sed 's/.*up //; s/,.*users.*//') ) ==="

# --- Guard 1: window sanity ---------------------------------------------
# Only fire inside 23:00-23:19 (DRAIN mode, ga-a2v0bz) or 01:00-01:19 (the
# legacy slot, still honored so this script is safe to merge BEFORE the root
# LaunchDaemon is moved to 23:00). Catches a late replay if the box was
# down/asleep at the scheduled StartCalendarInterval hit (this mini runs
# sleep=0, but a power loss or panic can still cause a late catch-up fire).
# This window is INDEPENDENT of the retry budget below: it only gates
# whether tonight's run is accepted as a real scheduled fire at all, not how
# long that run may then spend retrying once accepted.
HOUR=$(date +%-H)
MINUTE=$(date +%-M)
DRAIN_MODE=0
if [ "${CHECK_GUARDS_ONLY}" -eq 0 ]; then
    if [ "${HOUR}" -eq 23 ] && [ "${MINUTE}" -lt 20 ]; then
        DRAIN_MODE=1
    elif [ "${HOUR}" -eq 1 ] && [ "${MINUTE}" -lt 20 ]; then
        DRAIN_MODE=0   # legacy flow below, unchanged
    else
        log "SKIP: fired at ${HOUR}:$(printf '%02d' "${MINUTE}") — outside the 23:00-23:19 (drain) and 01:00-01:19 (legacy) firing windows, likely a late replay. Not rebooting."
        exit 0
    fi
fi

# --- Guards 2+3, retried together as one unit (ga-nnp5b) ------------------
# ga-g5bzf's 2-attempt/10s retry (Guard 2 only) was not enough: the very
# next night (2026-09-05) failed both attempts again. This session cannot
# move the root-owned LaunchDaemon that would sidestep the collision
# directly (see header — needs sudo). So instead: retry the FULL pre-flight
# evaluation — gate markers AND hq in-progress, re-read together on every
# attempt, never just the first failing half, so a guard that clears late
# doesn't get judged on stale state from 90 minutes earlier — every
# RETRY_INTERVAL seconds, for up to RETRY_MAX_ATTEMPTS tries. Sized
# (5min x 18 = 90min) to span both windows the 2026-09-05 survey found clear
# of every other StartCalendarInterval job on this box (01:41-02:14 and
# 02:18-02:59) while stopping well short of the dense Dolt/backup cluster
# starting at 03:00. A healthy night still finishes on attempt 1 in seconds,
# same as before — this budget only spends time on a night that would
# otherwise have silently skipped.
# --- Guard 4 helper: property_scrapers daily still running (ps-70jq) -------
# 2026-09-06..16 this reboot killed the property_scrapers nightly daily
# (starts 00:01, scraping + MotherDuck sync historically end 02:00-02:45)
# mid-run TEN nights in a row: kern.boottime lined up night by night with the
# last scraper_health.db row of each night, 6-7 long scrapers stopped
# collecting and the sync phase never ran. Guards 2+3 only look at gate
# markers and hq beads, so nothing here knew a scraper run was in flight.
#
# Source of truth is the daily's OWN durable per-rodada marker
# (runner.py _write_rodada_status, ps-i9jf): one JSON per rodada with
# status/pid/started_at. Three states, never collapsed:
#   running  a marker is status=running, its pid is alive, AND it started
#            after this boot (a pid recorded before the boot may since have
#            been reused by an unrelated process)
#   clear    no marker dir, or no marker satisfies the above
#   unknown  a marker file exists but cannot be parsed -> treated as NOT safe,
#            same fail-closed doctrine as Guards 2+3
#
# nightly-reboot.selftest.sh:SCRAPER-DAILY-GUARD-START — sentinel for the
# selftest (Scenario 6), same isolation technique as the blocks above. Keep it
# self-contained: only /usr/bin/python3 and the two overridable env vars.
scraper_daily_state() {
    local dir="${SCRAPER_RODADA_DIR:-/Users/athos/.property-scrapers/runtime/main/logs/rodada_status}"
    local boot="${SCRAPER_BOOT_EPOCH:-}"
    if [ -z "${boot}" ]; then
        # Token EXATO, não regex gulosa. `sysctl -n kern.boottime` imprime
        #     { sec = 1789579812, usec = 958892 } Wed Sep 16 14:30:12 2026
        # e um padrão `.*sec = ([0-9]+)` casa com o "sec" de **u**sec (o token
        # "usec" termina em "sec"), devolvendo os MICROSSEGUNDOS — medido ao
        # vivo nesta máquina: 958892 em vez de 1789579812, quatro ordens de
        # grandeza abaixo. Com um valor desses, a comparação "iniciou antes do
        # boot" nunca é verdadeira e a proteção contra pid reusado fica INERTE
        # em silêncio. Mesmo bug já achado e consertado no ram-pressure-monitor
        # (ga-rc7tz, 26/08) — é a segunda vez da cidade, então aqui vai por
        # comparação de token, que não tem como casar "usec" com "sec".
        boot=$(sysctl -n kern.boottime 2>/dev/null \
               | awk '{for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }')
    fi
    local out
    out=$(/usr/bin/python3 - "${dir}" "${boot}" <<'PY'
import json, os, sys
from datetime import datetime
d, boot = sys.argv[1], sys.argv[2]
if not os.path.isdir(d):
    print("clear\tno marker dir"); sys.exit(0)
try:
    boot = float(boot)
except ValueError:
    boot = None
bad = []
for name in sorted(os.listdir(d)):
    if not name.endswith(".json"):
        continue
    try:
        m = json.load(open(os.path.join(d, name)))
        assert isinstance(m, dict)
    except Exception as e:
        bad.append(name); continue
    if m.get("status") != "running":
        continue
    try:
        os.kill(int(m.get("pid")), 0)
    except ProcessLookupError:
        continue
    except PermissionError:
        pass
    except Exception:
        continue
    try:
        started = datetime.fromisoformat(str(m.get("started_at"))).timestamp()
    except Exception:
        started = None
    if boot is not None and started is not None and started < boot:
        continue  # recorded before this boot: that pid is someone else now
    print("running\trodada %s (pid %s, fase '%s', desde %s)" % (
        m.get("rodada_id"), m.get("pid"), m.get("phase"), m.get("started_at")))
    sys.exit(0)
if bad:
    print("unknown\tmarker(s) ilegível(is): " + ", ".join(bad)); sys.exit(0)
print("clear\tnenhuma rodada de scraper em execução")
PY
)
    if [ -z "${out}" ]; then
        SCRAPER_DAILY_STATE="unknown"; SCRAPER_DAILY_REASON="marker check produced no output"
        return 0
    fi
    SCRAPER_DAILY_STATE="${out%%	*}"
    SCRAPER_DAILY_REASON="${out#*	}"
    return 0
}
# nightly-reboot.selftest.sh:SCRAPER-DAILY-GUARD-END

RETRY_INTERVAL="${NIGHTLY_REBOOT_RETRY_INTERVAL:-300}"
RETRY_MAX_ATTEMPTS="${NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS:-18}"

# Guard 2 (gate markers), Guard 3 (hq in-progress) and Guard 4 (scraper daily
# in flight, ps-70jq), one function each, shared by the nightly retry loop
# (check_guards_once) and the read-only --check-guards mode
# (check_guards_report, ga-7e3fwa) — one implementation, so a manual reboot is
# judged by exactly what the nightly is judged by. Each guard sets
# GUARD_STATE to
#   ok       it looked and it is safe
#   block    it looked and something is in flight
#   unknown  it could not look (or could not parse what it saw) -> NOT safe
# and GUARD_REASON to a human string, and returns 0 only for "ok" — callers
# decide on the return code, GUARD_STATE only picks the label. It starts as
# "unknown" on entry, so a failing path that forgets to set it is reported as
# unknown (NOT safe), never as ok or BLOCK. GUARD_NOTE (reset on entry too) is a
# caveat that --check-guards prints after an "ok"; it never changes a return code.
#
# nightly-reboot.selftest.sh:GUARDS-FUNCTIONS-START — sentinel for the selftest
# (Scenario 7f), same isolation technique as the blocks above: it extracts this
# block, with no Guard 1 and no reboot call in it, to prove the nightly path
# still yields the same BLOCK_REASON text. Needs CITY, BD, GATE_ERR, HQ_ERR and
# scraper_daily_state from above.
guard_gate_markers() {
    GUARD_STATE="unknown"; GUARD_REASON=""; GUARD_NOTE=""
    GATE_JSON=$("${CITY}/scripts/gate-queue-composition.sh" --json 2>"${GATE_ERR}")
    GATE_RC=$?
    if [ "${GATE_RC}" -ne 0 ] || [ -z "${GATE_JSON}" ]; then
        GUARD_REASON="gate-queue-composition.sh failed (rc=${GATE_RC}: $(cat "${GATE_ERR}" 2>/dev/null)) — unknown gate state treated as NOT safe"
        return 1
    fi
    GATE_REAL=$(printf '%s' "${GATE_JSON}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("real","?"))' 2>/dev/null)
    case "${GATE_REAL}" in
        0)
            GUARD_STATE="ok"
            # Markers the gate could not classify (its "unknown" count) are not
            # "real" work, so — like the nightly always did — they do not block.
            # But an "ok" that hides them reads as "looked and saw nothing", so
            # --check-guards says how many there were. GUARD_NOTE only decorates
            # the label; the return code, and so the nightly, is unchanged. If the
            # count itself cannot be read (key absent, null) that is said too —
            # "could not tell how many" must not print the same bare "ok" as "zero".
            GATE_UNREADABLE=$(printf '%s' "${GATE_JSON}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("unknown","?"))' 2>/dev/null)
            case "${GATE_UNREADABLE}" in
                0) ;;
                ''|*[!0-9]*) GUARD_NOTE="unreadable-marker count unavailable (gate JSON has no numeric \"unknown\") — see scripts/gate-queue-composition.sh" ;;
                *) GUARD_NOTE="${GATE_UNREADABLE} unreadable markers, not counted as real work — see scripts/gate-queue-composition.sh" ;;
            esac
            return 0
            ;;
        ''|*[!0-9]*)  # "?" (no "real" key) or unparseable: could not tell
            GUARD_REASON="gate JSON has no numeric \"real\" count (raw: ${GATE_JSON}) — unknown gate state treated as NOT safe"
            return 1
            ;;
        *) GUARD_STATE="block" ;;
    esac
    GUARD_REASON="gate real-work markers in flight = ${GATE_REAL} (raw: ${GATE_JSON})"
    return 1
}
# Guard 3 — which hq in_progress beads can a reboot actually break (ga-2vl5yr)?
# It used to block on ANY in_progress bead. In a city where the Mayor keeps
# mission beads open for days that never reaches zero: the nightly SKIPPED 12
# nights in a row (swap 9 GB, disk 4.7 GB, wa-worker ceiling stuck at 2). A
# reboot breaks a bead only when a process is running for it right now, so a bead
# blocks only if ALL of these hold:
#   - its assignee (matched by session id, alias or session_name) is a LIVE
#     session: any state except asleep/suspended/closed/drained — an unrecognized
#     or missing state counts as live, "cannot tell" is not "dead";
#   - that session's template is not a coordinator (mayor, deacon, dispatcher,
#     boot, witnesses: their beads are missions, and the session is restarted
#     after the reboot anyway; override with NIGHTLY_REBOOT_COORDINATOR_TEMPLATES);
#   - the bead was touched within the last NIGHTLY_REBOOT_ACTIVE_WINDOW_MIN
#     minutes (default 60; the newer of updated_at and heartbeat_at). A live
#     builder that went silent for longer is stuck, and must not pin the reboot
#     forever the way any-in_progress did. A timestamp that cannot be read blocks.
# Everything else (no assignee, no session, dead session, coordinator, idle) is
# ignored but NAMED, with the reason, in GUARD_NOTE / HQ_IGNORED_NOTE — nothing
# is dropped silently. Unreadable input (bd query fails, JSON is not a list of
# objects) is "unknown" (NOT safe), never "no live session".
#
# Sessions come from `bd query 'type=session AND status=open'`, NOT from
# `bd list --type session`: list is blind to ephemeral wisp sessions (gate
# reviewers, pool workers) and saw 7 of 20 sessions when measured, which would
# have read every live gate reviewer as absent. Going through bd also keeps the
# guard off gc, whose behavior as root in this LaunchDaemon was not verified
# (bd list is proven as root by the nightly log; bd query reads the same store).
# Known residual: bd omits the assignee key on an unassigned bead, so a bd that
# renamed that field would look like "everything unassigned" and cannot be told
# apart from it. Python source below has no apostrophes on purpose: it lives in
# a single-quoted shell string (bash 3.2 safe, no heredoc).
HQ_CLASSIFY_PY='
import calendar, fnmatch, json, re, sys, time

def emit(state, text):
    print(state + "\t" + " ".join(str(text).split()))
    sys.exit(0)

DEAD = ("asleep", "suspended", "closed", "drained")
TS = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})$")

def parse_ts(v):
    m = TS.match(v.strip()) if isinstance(v, str) else None
    if not m:
        return None
    try:
        y, mo, d, h, mi, s = [int(m.group(i)) for i in range(1, 7)]
        t = calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))
        z = m.group(7)
        if z != "Z":
            digits = z[1:].replace(":", "")
            off = int(digits[:2]) * 3600 + int(digits[2:]) * 60
            t -= off if z[0] == "+" else -off
        return t
    except Exception:
        return None

def main():
    try:
        window = int(sys.argv[1])
    except ValueError:
        emit("unknown", "NIGHTLY_REBOOT_ACTIVE_WINDOW_MIN is not an integer: " + sys.argv[1])
    globs = sys.argv[2].split()
    doc = json.load(sys.stdin)
    beads, sessions = doc["beads"], doc["sessions"]
    if not isinstance(beads, list) or any(not isinstance(b, dict) for b in beads):
        emit("unknown", "in_progress JSON is not a list of objects")
    if not isinstance(sessions, list) or any(not isinstance(s, dict) for s in sessions):
        emit("unknown", "session query returned JSON that is not a list of objects")

    def md_of(s):
        m = s.get("metadata")
        return m if isinstance(m, dict) else {}
    # A store that cannot name a single session would read every assignee as
    # "no session for assignee" and pass the guard by default. A running city
    # always has sessions (the Mayor is pinned), so none at all, or none with a
    # readable session_name/alias, means the read is broken: unknown, not "safe".
    if any(isinstance(b.get("assignee"), str) and b["assignee"].strip() for b in beads):
        if not sessions:
            emit("unknown", "session query returned no sessions at all while in_progress beads have assignees")
        if not any(md_of(s).get("session_name") or md_of(s).get("alias") for s in sessions):
            emit("unknown", "no session carries a readable session_name or alias, so assignees cannot be matched")
    def names(s):
        m = md_of(s)
        return set(v for v in (s.get("id"), m.get("session_name"), m.get("alias")) if isinstance(v, str) and v)
    def state_of(s):
        v = md_of(s).get("state")
        return v.strip().lower() if isinstance(v, str) else ""
    def template_of(s):
        v = md_of(s).get("template")
        return v.strip() if isinstance(v, str) else ""
    def is_coordinator(s):
        t = template_of(s)
        return bool(t) and any(fnmatch.fnmatchcase(t, g) for g in globs)

    now = time.time()
    blocking, ignored = [], []
    for b in beads:
        bid = str(b.get("id") or "?")
        who = b.get("assignee")
        who = who.strip() if isinstance(who, str) else ""
        if not who:
            ignored.append(bid + " (no assignee)")
            continue
        mine = [s for s in sessions if who in names(s)]
        if not mine:
            ignored.append(bid + " (no session for assignee " + who + ")")
            continue
        live = [s for s in mine if state_of(s) not in DEAD]
        if not live:
            ignored.append(bid + " (session " + who + " is " + (state_of(mine[0]) or "not running") + ")")
            continue
        builders = [s for s in live if not is_coordinator(s)]
        if not builders:
            ignored.append(bid + " (coordinator " + who + ")")
            continue
        tpl = template_of(builders[0]) or "unknown template"
        stamps, unreadable = [], False
        for k in ("updated_at", "heartbeat_at"):
            v = b.get(k)
            if v is None or v == "":
                continue
            t = parse_ts(v)
            if t is None:
                unreadable = True
            else:
                stamps.append(t)
        if unreadable or not stamps:
            blocking.append(bid + " [builder " + who + " (" + tpl + "), activity unknown: no readable updated_at/heartbeat_at]")
            continue
        age = max(0, int((now - max(stamps)) // 60))
        if age > window:
            ignored.append(bid + " (idle " + str(age) + "m, over the " + str(window) + "m window: " + who + ")")
        else:
            blocking.append(bid + " [builder " + who + " (" + tpl + "), touched " + str(age) + "m ago]")

    if blocking:
        emit("block", "hq beads in_progress = %d blocking: %s" % (len(blocking), "; ".join(blocking)))
    emit("ok", "%d hq in_progress beads not blocking: %s" % (len(ignored), "; ".join(ignored)))

try:
    main()
except Exception as e:
    emit("unknown", "classifier error: " + type(e).__name__ + ": " + str(e))
'
guard_hq_in_progress() {
    GUARD_STATE="unknown"; GUARD_REASON=""; GUARD_NOTE=""; HQ_IGNORED_NOTE=""
    HQ_INPROGRESS_JSON=$("${BD}" -C "${CITY}" list --status in_progress --json --limit 0 2>"${HQ_ERR}")
    HQ_RC=$?
    if [ "${HQ_RC}" -ne 0 ] || ! printf '%s' "${HQ_INPROGRESS_JSON}" | /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
        GUARD_REASON="bd list --status in_progress (hq) failed (rc=${HQ_RC}: $(cat "${HQ_ERR}" 2>/dev/null)) — unknown state treated as NOT safe"
        return 1
    fi
    # Only a JSON LIST has a count. Valid JSON that is not a list (null, {}, an
    # error envelope) prints "?" — it must not be read as "zero in_progress".
    HQ_INPROGRESS_COUNT=$(printf '%s' "${HQ_INPROGRESS_JSON}" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else "?")' 2>/dev/null)
    case "${HQ_INPROGRESS_COUNT}" in
        0) GUARD_STATE="ok"; return 0 ;;
        ''|*[!0-9]*)  # not a list: the count could not be computed
            GUARD_REASON="bd list --status in_progress (hq) returned JSON that is not a list (raw: ${HQ_INPROGRESS_JSON}) — count unknown, treated as NOT safe"
            return 1
            ;;
    esac
    # Something is in progress: which of it has a process a reboot would kill?
    # (HQ_ERR is free again — the list call's stderr is no longer needed.)
    HQ_SESSIONS_JSON=$("${BD}" -C "${CITY}" query --json 'type=session AND status=open' --limit=0 2>"${HQ_ERR}")
    HQ_SESS_RC=$?
    if [ "${HQ_SESS_RC}" -ne 0 ]; then
        GUARD_REASON="bd query type=session (hq) failed (rc=${HQ_SESS_RC}: $(cat "${HQ_ERR}" 2>/dev/null)) — cannot tell which in_progress beads have a live session, treated as NOT safe"
        return 1
    fi
    local tab window coordinators verdict detail
    tab="$(printf '\t')"
    window="${NIGHTLY_REBOOT_ACTIVE_WINDOW_MIN:-60}"
    coordinators="${NIGHTLY_REBOOT_COORDINATOR_TEMPLATES:-gastown.mayor gastown.deacon control-dispatcher gastown.boot gastown.witness */gastown.witness}"
    HQ_CLASSIFY_OUT=$(printf '{"beads":%s,"sessions":%s}' "${HQ_INPROGRESS_JSON}" "${HQ_SESSIONS_JSON}" \
        | /usr/bin/python3 -c "${HQ_CLASSIFY_PY}" "${window}" "${coordinators}" 2>&1)
    verdict="${HQ_CLASSIFY_OUT%%"${tab}"*}"
    detail="${HQ_CLASSIFY_OUT#*"${tab}"}"
    case "${verdict}" in
        ok)
            GUARD_STATE="ok"
            HQ_IGNORED_NOTE="${detail}"
            GUARD_NOTE="${detail}"
            return 0
            ;;
        block)
            GUARD_STATE="block"
            GUARD_REASON="${detail}"
            return 1
            ;;
    esac
    # No verdict (python missing/crashed, or the classifier said unknown): NOT safe.
    [ "${verdict}" = "unknown" ] || detail="no verdict from the classifier (raw: ${HQ_CLASSIFY_OUT})"
    GUARD_REASON="hq in_progress beads could not be classified (${detail}) — treated as NOT safe"
    return 1
}
guard_scraper_daily() {
    GUARD_STATE="unknown"; GUARD_REASON=""; GUARD_NOTE=""
    scraper_daily_state
    case "${SCRAPER_DAILY_STATE}" in
        clear) GUARD_STATE="ok"; return 0 ;;
        running)
            GUARD_STATE="block"
            GUARD_REASON="property_scrapers daily em execução — ${SCRAPER_DAILY_REASON}"
            ;;
        *) GUARD_REASON="property_scrapers daily: estado desconhecido (${SCRAPER_DAILY_REASON}) — unknown treated as NOT safe" ;;
    esac
    return 1
}

# Nightly: runs the three guards in order ONCE and stops at the first that is
# not ok, so the log gets a single BLOCK_REASON per attempt and a guard that is
# not reached is not queried (a failing gate never calls bd). Sets BLOCK_REASON
# on failure. Returns 0 only if ALL guards pass.
check_guards_once() {
    guard_gate_markers || { BLOCK_REASON="${GUARD_REASON}"; return 1; }
    guard_hq_in_progress || { BLOCK_REASON="${GUARD_REASON}"; return 1; }
    guard_scraper_daily || { BLOCK_REASON="${GUARD_REASON}"; return 1; }
    return 0
}

# --check-guards: same guards, but every one is evaluated (no stopping at the
# first) and each gets its own stdout line "<label>: ok" or
# "<label>: BLOCK|unknown <reason>", so one run shows everything in the way of
# a manual reboot. Returns 0 only if all three are ok.
report_guard() {
    local label="$1" fn="$2" reason
    if "${fn}"; then
        if [ -n "${GUARD_NOTE}" ]; then
            printf '%s: ok (%s)\n' "${label}" "$(printf '%s' "${GUARD_NOTE}" | tr '\n' ' ')"
        else
            printf '%s: ok\n' "${label}"
        fi
        return 0
    fi
    # bd/gate stderr can span lines; the contract is one line per guard.
    reason=$(printf '%s' "${GUARD_REASON}" | tr '\n' ' ')
    case "${GUARD_STATE}" in
        block) printf '%s: BLOCK %s\n' "${label}" "${reason}" ;;
        *) printf '%s: unknown %s\n' "${label}" "${reason}" ;;
    esac
    return 1
}
check_guards_report() {
    local rc=0
    report_guard "guard2 gate-markers" guard_gate_markers || rc=1
    report_guard "guard3 hq-in-progress" guard_hq_in_progress || rc=1
    report_guard "guard4 scraper-daily" guard_scraper_daily || rc=1
    return "${rc}"
}
# nightly-reboot.selftest.sh:GUARDS-FUNCTIONS-END

# =========================================================================
# DRAIN MODE (ga-a2v0bz) — why the reboot finally happens
# =========================================================================
# 13 nights in a row this script skipped. The dominant blocker was not the
# scraper but Guard 3: the city never stops working at night (gate reviewers,
# pool dogs, builders), so "no live builder on an hq bead" never held for the
# ~85 minutes the legacy flow waited. Athos (01/10): reboot BEFORE the scraper
# starts at 00:01. So the LaunchDaemon fires at 23:00 and this script:
#   1. opens a DRAIN (DRAIN_FILE): pilot / gate / refino / auto-refino /
#      context-check stop ADMITTING new work; what is in flight finishes;
#   2. waits until DRAIN_REBOOT_AT (23:40), re-stamping the signal;
#   3. at 23:40 only the SAFETY guards decide, retrying until ~23:55:
#        - a send in flight (central_sender_restart_safe.py — a cut send is a
#          lead who may get two messages), and
#        - Dolt maintenance (compact/gc/backup/table-swap) mid-run;
#      "could not look" (script missing, rc>1, pgrep error) is NOT safe;
#   4. gate markers, hq in_progress beads and the scraper rodada are now
#      INFORMATIVE: they are logged (and snapshotted) as "what this reboot
#      cuts". The gate re-queues its markers, inflight-reclaim-guard hands
#      beads back, and the scraper's catch-up (--skip-done-today) resumes;
#   5. reboots, leaving PENDING_FILE so the post-boot check knows this boot
#      was ours.
# A night that cannot reboot by ~23:55 lifts the drain at once and SKIPs
# (streak/alarm as before) — a failed night must never freeze the city.
#
# LIMIT of guard_dolt_maintenance: it sees maintenance WRAPPERS and the dolt
# CLI by process, not a bare `CALL dolt_gc()` typed into an interactive SQL
# session. The wrappers are what this city runs.
SAFETY_RETRY_INTERVAL="${NIGHTLY_REBOOT_SAFETY_RETRY_INTERVAL:-60}"
SAFETY_MAX_ATTEMPTS="${NIGHTLY_REBOOT_SAFETY_MAX_ATTEMPTS:-16}"      # 16 x 60s: 23:40 -> ~23:55
DRAIN_FALLBACK_WAIT_SECS="${NIGHTLY_REBOOT_DRAIN_FALLBACK_WAIT_SECS:-2400}"
SENDER_SAFE_PY="${NIGHTLY_REBOOT_SENDER_SAFE_PY:-/Users/athos/gt/whatsapp_automation/scripts/central_sender_restart_safe.py}"
PYTHON3_BIN="${NIGHTLY_REBOOT_PYTHON:-/usr/bin/python3}"
PGREP_BIN="${NIGHTLY_REBOOT_PGREP_BIN:-/usr/bin/pgrep}"
SCRAPER_CUT_FILE="${CITY}/.gc/logs/nightly-reboot.scraper-cut.streak"
SCRAPER_CUT_ALARM_THRESHOLD="${NIGHTLY_REBOOT_SCRAPER_CUT_ALARM_THRESHOLD:-2}"

# nightly-reboot.drain.selftest.sh:DRAIN-SCHEDULE-START — pure, extracted by the selftest
# secs_until_hhmm HH:MM [now_epoch] -> seconds from now until HH:MM TODAY (the day of
# now_epoch); 0 if that moment has passed (never negative); "ERR" if it cannot be
# computed. ERR is its own answer on purpose: collapsing "cannot tell" into 0 would
# read as "it is already time" and reboot early.
secs_until_hhmm() {
    local hhmm="$1" now="${2:-$(date +%s)}" hh mm day target
    case "${hhmm}" in [0-9][0-9]:[0-9][0-9]) ;; *) printf 'ERR'; return 0 ;; esac
    case "${now}" in ''|*[!0-9]*) printf 'ERR'; return 0 ;; esac
    hh="${hhmm%%:*}"; mm="${hhmm##*:}"
    { [ "$(( 10#${hh} ))" -le 23 ] && [ "$(( 10#${mm} ))" -le 59 ]; } || { printf 'ERR'; return 0; }
    day="$(date -j -f %s "${now}" +%Y-%m-%d 2>/dev/null)" || { printf 'ERR'; return 0; }
    target="$(date -j -f '%Y-%m-%d %H:%M:%S' "${day} ${hh}:${mm}:00" +%s 2>/dev/null)" || { printf 'ERR'; return 0; }
    if [ "${target}" -gt "${now}" ]; then printf '%s' $(( target - now )); else printf '0'; fi
}
# nightly-reboot.drain.selftest.sh:DRAIN-SCHEDULE-END

# nightly-reboot.drain.selftest.sh:DOLT-MAINT-PATTERN-START — extracted by the selftest
# Matches the maintenance WRAPPERS and the mutating dolt CLI, anchored at argv[0] (pgrep -f
# sees "argv0 argv1 ..."): a Claude session whose prompt merely MENTIONS "dolt-compact-routine"
# does not match, and `dolt sql-server` never does. Three arms:
#   1. a shell (any path: /bin/bash, /opt/homebrew/bin/bash, bare bash...) running one of the
#      wrapper scripts. The list is every scripts/dolt-*.sh that can be running at 23:40 and
#      that a kill would leave half-done: the maintenance wrappers, the backup/restore
#      wrappers (dolt-s3-backup.sh is scheduled 04:00 by com.gascity.dolt-s3-backup; an
#      overrunning or re-kicked run is invisible to arm 2 because the wrapper's sync is a
#      `dolt ... sql -q` child, arm 3) and dolt-restore-verify. The selftest (E12) lists
#      scripts/dolt-*.sh and fails on one that is neither here nor in its explicit
#      "not a hazard" list — a new wrapper has to be classified, not forgotten.
#   2. the dolt CLI verbs that mutate or move data (`dolt gc`, `dolt backup`, ...).
#   3. `dolt [flags] sql ... CALL DOLT_GC / DOLT_BACKUP` — the same operations through the
#      SQL procedures (a CLI client; a long-lived `dolt sql-server` never matches).
DOLT_MAINT_PATTERN_DEFAULT='^([^ ]*/)?(bash|sh)( -[A-Za-z]+)* ([^ ]*/)?(dolt-compact-routine|dolt-gc-maintenance|dolt-gc-release-trigger|dolt-backup-reseed|dolt-backup-swap-repair|dolt-backup-residue-reclaim|dolt-offline-backup-sync|dolt-s3-backup|dolt-restore-verify)\.sh( |$)|^([^ ]*/)?dolt (gc|backup|push|pull|fetch|table)( |$)|^([^ ]*/)?dolt( [^ ]+)* sql .*[Cc][Aa][Ll][Ll] +[Dd][Oo][Ll][Tt]_([Gg][Cc]|[Bb][Aa][Cc][Kk][Uu][Pp])'
# nightly-reboot.drain.selftest.sh:DOLT-MAINT-PATTERN-END
DOLT_MAINT_PATTERN="${NIGHTLY_REBOOT_DOLT_MAINT_PATTERN:-${DOLT_MAINT_PATTERN_DEFAULT}}"

# Safety guard 1: a send in flight. Same contract as central_sender_restart_safe.py:
# exit 0 = safe, 1 = in flight, anything else (2 = "could not read the queue", or the
# script missing / not runnable) = unknown -> NOT safe. Cutting a send mid-sequence
# can make a lead receive two messages; waiting costs a retry.
guard_sender_in_flight() {
    GUARD_STATE="unknown"; GUARD_REASON=""; GUARD_NOTE=""
    local out rc
    if [ ! -r "${SENDER_SAFE_PY}" ]; then
        GUARD_REASON="central_sender_restart_safe.py not readable at ${SENDER_SAFE_PY} — cannot tell whether a send is in flight, unknown treated as NOT safe"
        return 1
    fi
    # Run as the user, not as root (this script is a root LaunchDaemon): the check opens the
    # sender's SQLite queue (WAL mode, mode=ro) and imports its sibling modules, and as root that
    # CAN leave root-owned -shm/-wal files next to queue.db (the athos sender could then no longer
    # write them) and root-owned .pyc files in the athos-owned scripts/__pycache__. Gate review
    # ga-iwyczc raised this as a risk it did not reproduce, so "can", not "does". Same trick as
    # notify_athos: root sudoes to another user with no password.
    out=$(sudo -u "${NOTIFY_AS_USER}" "${PYTHON3_BIN}" "${SENDER_SAFE_PY}" 2>&1); rc=$?
    case "${rc}" in
        0) GUARD_STATE="ok"; GUARD_NOTE="${out}"; return 0 ;;
        1)
            # rc 1 is the script's "send in flight" — and also what sudo itself exits with when it
            # cannot run the command (unknown user, no sudoers rule). Both hold the reboot, but only
            # one is a send: a sudo that could not run it is "could not look", never "in flight"
            # (the SKIP push would otherwise send the operator hunting a send that does not exist).
            # The script's own rc-1 text starts with "central_sender_restart_safe:", never "sudo:".
            case "${out}" in
                "sudo: "*) GUARD_REASON="could not run central_sender_restart_safe.py as ${NOTIFY_AS_USER} ($(printf '%s' "${out}" | tr '\n' ' ')) — cannot tell whether a send is in flight, unknown treated as NOT safe" ;;
                *) GUARD_STATE="block"; GUARD_REASON="central_sender send in flight: $(printf '%s' "${out}" | tr '\n' ' ')" ;;
            esac ;;
        *) GUARD_REASON="central_sender_restart_safe.py rc=${rc}: $(printf '%s' "${out}" | tr '\n' ' ') — unknown treated as NOT safe" ;;
    esac
    return 1
}

# Safety guard 2: Dolt maintenance mid-run. pgrep rc 0 = running, 1 = none, other = could not look.
guard_dolt_maintenance() {
    GUARD_STATE="unknown"; GUARD_REASON=""; GUARD_NOTE=""
    local out rc
    out=$("${PGREP_BIN}" -fl "${DOLT_MAINT_PATTERN}" 2>&1); rc=$?
    case "${rc}" in
        1) GUARD_STATE="ok"; return 0 ;;
        0) GUARD_STATE="block"; GUARD_REASON="Dolt maintenance process running: $(printf '%s' "${out}" | tr '\n' ';')" ;;
        *) GUARD_REASON="pgrep failed (rc=${rc}: $(printf '%s' "${out}" | tr '\n' ' ')) — cannot tell whether Dolt maintenance is running, unknown treated as NOT safe" ;;
    esac
    return 1
}

check_safety_guards_once() {
    guard_sender_in_flight || { BLOCK_REASON="${GUARD_REASON}"; return 1; }
    guard_dolt_maintenance || { BLOCK_REASON="${GUARD_REASON}"; return 1; }
    return 0
}

# safety_gate_wait: the safety guards must be clear before the machine is cut. Tries up
# to SAFETY_MAX_ATTEMPTS times, SAFETY_RETRY_INTERVAL apart. Returns 0 = clear (ATTEMPT is
# the attempt that cleared) or 1 = still blocked (BLOCK_REASON says why, ATTEMPT is how
# many were made). Run TWICE in drain mode: to decide, and again just before the shutdown.
# The central sender is not gated by the drain, so a send can start in the minutes between
# the two (informational probes, the macOS install, the notify) — a verdict is only good
# for the moment it was read.
safety_gate_wait() {
    ATTEMPT=1
    while true; do
        drain_stamp || true
        if check_safety_guards_once; then
            return 0
        fi
        if [ "${ATTEMPT}" -ge "${SAFETY_MAX_ATTEMPTS}" ]; then
            return 1
        fi
        log "attempt ${ATTEMPT}/${SAFETY_MAX_ATTEMPTS} blocked by a safety guard (${BLOCK_REASON}) — retrying in ${SAFETY_RETRY_INTERVAL}s."
        drain_sleep "${SAFETY_RETRY_INTERVAL}"
        ATTEMPT=$((ATTEMPT+1))
    done
}

# drain_skip_night: a safety guard held the reboot. Release the city, say so where a human
# will SEE it (route=push: the digest is where the 13 silent nights went), count the night,
# and leave. Never returns.
drain_skip_night() {
    log "SKIP: safety guards still blocked after ${ATTEMPT}/${SAFETY_MAX_ATTEMPTS} attempts over ~$(( (ATTEMPT-1) * SAFETY_RETRY_INTERVAL / 60 ))min (last: ${BLOCK_REASON}). Not rebooting; lifting the drain."
    drain_end
    notify_athos "Reboot noturno pulado" "guard de segurança ainda bloqueando após ${ATTEMPT}/${SAFETY_MAX_ATTEMPTS} tentativas às $(date '+%H:%M') — ${BLOCK_REASON}. Dreno encerrado. Ver ${LOG}." 3 push
    record_skip_bounded "${BLOCK_REASON}"
    exit 0
}

# What this reboot is about to cut. Guards 2/3/4 do not hold the reboot in drain
# mode, but their verdicts are the only record of what was in flight, so each one
# lands in the log ("informational: ...") and in a per-night snapshot.
#
# Every probe here has a deadline. These calls are what first touches bd/Dolt in
# drain mode (the safety guards never do), so without one a wedged Dolt turns an
# "informational" line into a veto that nobody sees. A probe that misses its
# deadline is written as "unknown ... TIMED OUT" — not "ok", not silence — and
# the reboot goes on.
info_guard() {
    local label="$1" fn="$2" into="$3" secs rc gtmp
    secs="$(info_probe_secs)"
    if [ "${secs}" -le 0 ]; then
        printf '%s: unknown NOT ATTEMPTED — the %ss informational time budget was already spent (informational only: the reboot proceeds)\n' "${label}" "${INFO_BUDGET_SECS}" >> "${into}"
        return 0
    fi
    gtmp="$(mktemp -t nightly-reboot-info-guard)"
    run_bounded "${secs}" "${gtmp}" report_guard "${label}" "${fn}"; rc=$?
    if [ "${rc}" -eq 124 ]; then
        printf '%s: unknown TIMED OUT after %ss — the probe did not answer, bd/Dolt wedged? (informational only: the reboot proceeds)\n' "${label}" "${secs}" >> "${into}"
    elif [ -s "${gtmp}" ]; then
        cat "${gtmp}" >> "${into}"
    else
        printf '%s: unknown the probe printed nothing (rc=%s)\n' "${label}" "${rc}" >> "${into}"
    fi
    rm -f "${gtmp}" "${gtmp}.deadline"
    return 0
}

drain_informational_report() {
    local snap tmp line
    snap="${CITY}/.gc/logs/nightly-reboot-pre-$(date +%Y%m%d-%H%M).txt"
    tmp="$(mktemp -t nightly-reboot-info)"
    info_begin
    : > "${tmp}"
    info_guard "guard2 gate-markers" guard_gate_markers "${tmp}"          # rc ignored: informative only
    info_guard "guard3 hq-in-progress" guard_hq_in_progress "${tmp}"
    info_guard "guard4 scraper-daily" guard_scraper_daily "${tmp}"
    {
        printf 'Pre-reboot snapshot, nightly reboot in DRAIN mode (ga-a2v0bz) - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'These guards do NOT hold the reboot. What they show is what it cuts: the gate re-queues its markers, inflight-reclaim-guard hands beads back, the scraper catch-up resumes its rodada.\n'
        cat "${tmp}"
    } > "${snap}" 2>/dev/null || log "WARN: could not write the pre-reboot snapshot ${snap}"
    while IFS= read -r line; do
        log "informational: ${line}"
    done < "${tmp}"
    rm -f "${tmp}"
}

# Scraper cut counter: how many nights in a row the reboot found a rodada running.
# "unknown" leaves the counter alone (could-not-look is neither a cut nor a clean night).
#
# This function only BUMPS the counter and decides whether the alarm is DUE. It does not
# send it: the alarm tells the mayor "the scraper was cut N nights in a row", and at this
# point in the night nothing has been cut yet. A mail sent here would be wrong on every night
# whose shutdown fails (gate ga-f9ks5v), and it cannot be taken back. Nor can it wait for
# the shutdown to return: the live log shows nothing written after `shutdown -r now` on any
# night that rebooted. The verdict goes into the pending file (write_pending_file) and the
# post-boot check — which only acts on a boot that IS the nightly's, i.e. after the cut — sends it.
SCRAPER_ALARM_N=""
SCRAPER_ALARM_REASON=""
record_scraper_cut() {
    local state="$1" reason="$2" n
    SCRAPER_ALARM_N=""; SCRAPER_ALARM_REASON=""
    n=$(cat "${SCRAPER_CUT_FILE}" 2>/dev/null)
    case "${n}" in (''|*[!0-9]*) n=0 ;; esac
    case "${state}" in
        running)
            n=$(( n + 1 ))
            if printf '%s\n' "${n}" > "${SCRAPER_CUT_FILE}" 2>/dev/null; then
                log "scraper: a rodada is in flight — IF the shutdown below is accepted this reboot cuts it and the daily catch-up resumes it at boot (counter -> ${n}; put back if the shutdown fails): ${reason}"
            else
                log "ERROR: scraper: a rodada is in flight but the cut counter ${SCRAPER_CUT_FILE} could not be written — the count is NOT kept (tonight would be night ${n}): ${reason}"
            fi
            if [ "${n}" -ge "${SCRAPER_CUT_ALARM_THRESHOLD}" ] && [ $(( n % SCRAPER_CUT_ALARM_THRESHOLD )) -eq 0 ]; then
                SCRAPER_ALARM_N="${n}"
                SCRAPER_ALARM_REASON="${reason}"
                log "ALARM due: the scraper would be cut ${n} nights in a row — the mail to the mayor goes from the post-boot check, once the boot is confirmed as the nightly's (not before: a failed shutdown cuts nothing)"
            fi
            ;;
        clear) printf '0\n' > "${SCRAPER_CUT_FILE}" 2>/dev/null || log "ERROR: scraper: could not reset the cut counter ${SCRAPER_CUT_FILE} — it keeps the old count" ;;
        *) log "scraper: state unknown (${reason}) — cut counter left at ${n}" ;;
    esac
}

# The night's two counters (the skip streak and the scraper-cut counter) are written BEFORE
# the shutdown call, because nothing written after it is reliable (see record_scraper_cut).
# So a shutdown that does not take has to put them back, and exactly: a file that did not
# exist stays absent, one that held 13 holds 13 again. "Could not read it" is its own state —
# it is reported and the file is left as it is now, never "restored" to a guess.
STREAK_PREV_STATE=""; STREAK_PREV=""
CUT_PREV_STATE="";    CUT_PREV=""
night_counters_save() {
    if [ -e "${STREAK_FILE}" ]; then
        if STREAK_PREV="$(cat "${STREAK_FILE}" 2>/dev/null)"; then STREAK_PREV_STATE="present"; else STREAK_PREV_STATE="unreadable"; fi
    else STREAK_PREV_STATE="absent"; fi
    if [ -e "${SCRAPER_CUT_FILE}" ]; then
        if CUT_PREV="$(cat "${SCRAPER_CUT_FILE}" 2>/dev/null)"; then CUT_PREV_STATE="present"; else CUT_PREV_STATE="unreadable"; fi
    else CUT_PREV_STATE="absent"; fi
}
# restore_counter <file> <state> <value> <label>
restore_counter() {
    case "$2" in
        present)
            if printf '%s\n' "$3" > "$1" 2>/dev/null; then log "counters: $4 put back to ${3:-<empty>}"
            else log "ERROR: counters: could not put the $4 back to ${3:-<empty>} (write to $1 failed) — it holds tonight's value"; fi ;;
        absent)
            rm -f "$1" 2>/dev/null
            if [ -e "$1" ]; then log "ERROR: counters: could not remove $1 — the $4 holds tonight's value, it was absent before"
            else log "counters: $4 put back to absent"; fi ;;
        *) log "WARN: counters: the $4 file was unreadable before tonight's write — left as it is now, not restored from a guess" ;;
    esac
}
night_counters_restore() {
    restore_counter "${STREAK_FILE}" "${STREAK_PREV_STATE}" "${STREAK_PREV}" "skip streak"
    restore_counter "${SCRAPER_CUT_FILE}" "${CUT_PREV_STATE}" "${CUT_PREV}" "scraper-cut counter"
}

# Handoff to the post-boot check (scripts/nightly-reboot-postcheck.sh): "this boot is ours".
write_pending_file() {
    local mode="$1" tmp="${PENDING_FILE}.tmp.$$" reason
    # The scraper-cut alarm owed to the mayor (record_scraper_cut) rides in the same file: the
    # post-boot check sends it only once it has confirmed this boot is the nightly's. One line
    # per field — a newline in the reason would become a bogus extra key.
    reason="$(printf '%s' "${SCRAPER_ALARM_REASON}" | tr '\n\r' '  ')"
    if { printf 'issued=%s\nboot_before=%s\nmode=%s\n' "$(date +%s)" "$(boot_epoch)" "${mode}" > "${tmp}" \
         && { [ -z "${SCRAPER_ALARM_N}" ] || printf 'scraper_cut_alarm=%s\nscraper_cut_reason=%s\n' "${SCRAPER_ALARM_N}" "${reason}" >> "${tmp}"; } \
         && chmod 644 "${tmp}" && mv -f "${tmp}" "${PENDING_FILE}"; } 2>/dev/null; then
        return 0
    fi
    rm -f "${tmp}" 2>/dev/null
    log "WARN: could not write ${PENDING_FILE} — the post-boot check will not know this reboot was the nightly one${SCRAPER_ALARM_N:+, and the scraper-cut alarm owed to the mayor (night ${SCRAPER_ALARM_N}) will NOT be sent}"
    return 0
}

# Informational only: other rigs' in_progress count (not a gate).
# Precedent (2026-08-29 runbook) treated non-hq in-progress as non-blocking —
# inflight-reclaim-guard reclaims stale crew claims regardless of reboot.
# Runs under run_bounded (one bd call per rig, any of which can hang on a wedged
# Dolt), so it logs each rig as it goes: a deadline mid-loop keeps what was read.
# Unindented lines inside are a python -c string; do not re-indent them.
info_rig_in_progress() {
local RIG_DIR RIG_NAME CNT
for RIG_DIR in "${CITY%/.gascity-gastown-hq}"/*/; do
    RIG_NAME=$(basename "${RIG_DIR}")
    [ -d "${RIG_DIR}/.beads" ] || continue
    CNT=$("${BD}" -C "${RIG_DIR}" list --status in_progress --json --limit 0 2>/dev/null | /usr/bin/python3 -c 'import json,sys
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print("?")' 2>/dev/null)
    log "info: ${RIG_NAME} in_progress = ${CNT} (non-blocking, logged only)"
done
}

# The shared tail: both modes end here (legacy at 01:00, drain at 23:40). Unindented
# lines inside are a python -c string; do not re-indent them.
reboot_now_sequence() {
REBOOT_MODE="$1"
# --- Informational only: other rigs' in_progress count (not a gate) ------
# In drain mode drain_informational_report already opened the shared time budget;
# the legacy flow opens it here (bd answered during its guards, but the cost of
# asking again must still be bounded).
[ "${REBOOT_MODE}" = "drain" ] || info_begin
RIG_SECS="$(info_probe_secs)"
if [ "${RIG_SECS}" -le 0 ]; then
    log "info: other rigs' in_progress counts NOT ATTEMPTED — the ${INFO_BUDGET_SECS}s informational time budget was already spent (unknown; the reboot proceeds)"
else
    RIG_OUT="$(mktemp -t nightly-reboot-rigs)"
    run_bounded "${RIG_SECS}" "${RIG_OUT}" info_rig_in_progress; RIG_RC=$?
    if [ "${RIG_RC}" -eq 124 ]; then
        log "info: other rigs' in_progress counts TIMED OUT after ${RIG_SECS}s — bd/Dolt did not answer, wedged? (unknown; the reboot proceeds)"
    fi
    rm -f "${RIG_OUT}" "${RIG_OUT}.deadline"
fi

# --- macOS update: install before reboot if one is ready (ga-l5m50) -------
# The drain signal is stamped once here, not kept alive: the readers ignore a signal older
# than 30min, so an install that outlasts that lets the dispatchers admit work again
# (fail-open by design). Work admitted then is cut by the reboot like any work in flight.
if [ "${DRAIN_ACTIVE:-0}" = "1" ]; then drain_stamp || true; fi
macos_update_install_if_ready

# --- All clear: record pre-reboot state, then reboot ----------------------
log "disk before: $(df -h /System/Volumes/Data | tail -1 | awk '{print $4" free ("$5" used)"}')"
log "swap before: $(sysctl -n vm.swapusage 2>/dev/null)"
log "swapfiles before: $(ls /System/Volumes/VM/ 2>/dev/null | grep -c swapfile)"

# Drain mode: the safety verdict was read before the informational probes and the macOS
# install above, and none of them stops the central sender. Read it again as late as
# possible; a send that started in the gap holds the reboot like one that was there at
# 23:40. The streak is reset only after this, so a night that ends here as a SKIP keeps
# counting. What is left between this read and the shutdown is the routine note below
# (notify: not bounded here, see the header), the counters' bookkeeping (two local files;
# the scraper-cut alarm mail is NOT sent from here, it rides in the pending file), the
# pending file itself and `sync` — seconds, not minutes.
if [ "${REBOOT_MODE}" = "drain" ]; then
    log "final safety re-check, just before the shutdown (the 23:40 verdict is minutes old)"
    safety_gate_wait || drain_skip_night
fi

# The routine "Reiniciando" note is sent AFTER the re-check (gate FAIL 3/3): the re-check
# can still turn the night into a SKIP — up to ~16 min later — and a "reiniciando às HH:MM"
# that is followed by "pulado" is a message that said something that did not happen. The
# price is that notify's own time now sits between the re-check and the shutdown: notify is
# one of the calls this script does not bound (see the header), and that time was not
# measured here — it is a routine note on the digest route, not an alarm push.
notify_athos "Reboot noturno" "Reiniciando às $(date '+%H:%M') pra liberar swap acumulado. Volto em ~2min (auto-login)." 3

# The night's bookkeeping — the skip streak back to 0, the scraper-cut counter — is written
# HERE, right before the shutdown call and not earlier, so nothing slow sits between it and
# the shutdown; and it is written BEFORE the call because nothing written after it can be
# counted on (the live log shows no line after `shutdown -r now` on any night that rebooted:
# the machine takes the script down). The price is the failure branch below, which has to put
# it back: a shutdown that does not take is a night WITHOUT a reboot — the streak must keep
# counting it, not erase it. The scraper-cut alarm mail is not sent from here at all (see
# record_scraper_cut); drain_main stored the verdict in SCRAPER_DAILY_STATE / SCRAPER_DAILY_REASON.
# LIMIT: only a shutdown that RETURNS non-zero is undone. A TERM/KILL that lands between this
# write and the shutdown call is not: from inside the script it cannot be told apart from the
# reboot taking the script down (the normal end of a good night), so an EXIT-trap "restore"
# would undo the counters on every night that works. The window is a few local file writes
# and `sync`.
night_counters_save
reset_streak
if [ "${REBOOT_MODE}" = "drain" ]; then
    record_scraper_cut "${SCRAPER_DAILY_STATE:-unknown}" "${SCRAPER_DAILY_REASON:-no reason}"
fi

write_pending_file "${REBOOT_MODE}"
log "rebooting now"
sync
# The drain signal must outlive this call, so the EXIT trap is told to leave it alone BEFORE
# the call, not after it: on a night that reboots the OS TERMs this script while the shutdown
# runs (the live log has no line after `shutdown -r now` on any of those nights), drain_main's
# TERM trap turns that into exit 143, and the EXIT trap -> drain_cleanup runs with whatever
# DRAIN_ACTIVE holds at that moment. Cleared only on the rc 0 line below, that was still 1 and
# the TERM path (the one that actually runs) removed the signal seconds before power-off.
# The price, same as the counters' window below: a TERM/KILL that lands between this line and
# the shutdown call leaves the signal on disk; it expires on its own (30min staleness,
# DRAIN_MAX_SECS ceiling). A shutdown that RETURNS non-zero releases it explicitly, below.
DRAIN_ACTIVE=0
"${SHUTDOWN_BIN}" -r now >>"${LOG}" 2>&1
RC=$?
# A NON-ZERO return means shutdown did not take: nothing is rebooting, so the hand-off
# to the post-boot check is a lie, and left on disk a DIFFERENT reboot inside the
# check's 3h window would be credited to the nightly (a false "Reboot noturno OK").
# rc 0 is the opposite case — the machine is going down while this line runs — and
# the file MUST survive it: it is the only thing telling the post-boot check this
# boot was ours.
if [ "${RC}" -eq 0 ]; then
    # The drain signal STAYS (DRAIN_ACTIVE was cleared before the call): releasing the city's
    # admission gates seconds before the machine is down would let a dispatcher start work the
    # reboot is about to kill — the very thing the drain exists to prevent. The signal carries
    # this boot's epoch, so every reader ignores it after the reboot (nothing has to clear it),
    # and if the machine somehow does not go down it expires on its own (30min staleness,
    # DRAIN_MAX_SECS ceiling).
    log "shutdown accepted (rc 0) — the machine is going down; the drain signal is left in place (the reboot invalidates it) and the post-boot check takes over"
    exit 0
fi
# The shutdown did not take: tonight is a SKIP that the "Reiniciando" note above got wrong.
# The city is released FIRST (drain_end, as drain_skip_night does): the push and the skip
# bookkeeping below take up to ~2min (record_skip_bounded), and the dispatchers should not stay
# paused behind a reboot that is not coming. Then everything tonight wrote on the assumption
# that the reboot would happen is undone — the pending file, the streak reset, the scraper-cut
# counter and the alarm owed for it (it was only ever in the pending file, now gone, so no
# "scraper cortado" mail goes out for a cut that did not happen) — and the night is counted
# as a skipped one, with the push that the digest-routed "Reiniciando" cannot be.
if [ "${REBOOT_MODE}" = "drain" ]; then drain_end; fi
rm -f "${PENDING_FILE}" 2>/dev/null
SCRAPER_ALARM_N=""; SCRAPER_ALARM_REASON=""
log "ERROR: shutdown returned ${RC} — reboot did NOT happen"
night_counters_restore
notify_athos "Reboot noturno FALHOU" "o shutdown devolveu rc=${RC} às $(date '+%H:%M') — a máquina NÃO reiniciou (o 'Reiniciando às…' de antes não aconteceu). A noite conta como pulada. Ver ${LOG}." 4 push
record_skip_bounded "shutdown returned ${RC}"
exit 1
}

# Drain mode, start to finish. Never returns: it ends in the reboot sequence (which
# exits) or in a SKIP.
drain_main() {
    local wait remaining chunk deadline now
    DRAIN_STARTED="$(date +%s)"
    # a kill must reach drain_cleanup NOW; the legacy path never installs these
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
    log "drain mode: the city stops admitting new work until the reboot at ${DRAIN_REBOOT_AT} (signal ${DRAIN_FILE}); at that time only the SAFETY guards decide — agent work in flight does not hold the reboot"
    drain_stamp || true

    wait="${NIGHTLY_REBOOT_DRAIN_WAIT_SECS:-$(secs_until_hhmm "${DRAIN_REBOOT_AT}")}"
    case "${wait}" in ''|*[!0-9]*)
        log "ERROR: could not work out how long to wait for ${DRAIN_REBOOT_AT} (got '${wait}') — waiting the default ${DRAIN_FALLBACK_WAIT_SECS}s from the fire instead"
        wait="${DRAIN_FALLBACK_WAIT_SECS}" ;;
    esac
    case "${DRAIN_STAMP_INTERVAL}" in ''|*[!0-9]*|0) DRAIN_STAMP_INTERVAL=300 ;; esac
    remaining="${wait}"
    log "drain: waiting ${remaining}s until ${DRAIN_REBOOT_AT} (re-stamping the signal every ${DRAIN_STAMP_INTERVAL}s)"
    # The wait is decided by the WALL CLOCK, not by a counter of the seconds we asked
    # to sleep: a sleep that cannot start or returns early (this host runs load 60-88)
    # must not shrink 40 minutes into none and put the safety guards at ~23:00 with the
    # city barely drained. `remaining` is re-derived from the clock after every chunk;
    # the countdown is only the fallback for when the clock itself cannot be read.
    deadline="$(date +%s)"
    case "${deadline}" in ''|*[!0-9]*) deadline="" ;; *) deadline=$(( deadline + remaining )) ;; esac
    while [ "${remaining}" -gt 0 ]; do
        chunk="${DRAIN_STAMP_INTERVAL}"
        [ "${remaining}" -lt "${chunk}" ] && chunk="${remaining}"
        drain_sleep "${chunk}"
        remaining=$(( remaining - chunk ))
        drain_stamp || true
        if [ -n "${deadline}" ]; then
            now="$(date +%s)"
            case "${now}" in ''|*[!0-9]*) ;; *) remaining=$(( deadline - now )) ;; esac
        fi
    done

    safety_gate_wait || drain_skip_night
    log "safety guards OK on attempt ${ATTEMPT}/${SAFETY_MAX_ATTEMPTS}: no send in flight, no Dolt maintenance running — rebooting with agent work possibly in flight (drain mode, ga-a2v0bz)"

    drain_informational_report
    guard_scraper_daily || true                    # sets SCRAPER_DAILY_STATE/REASON in THIS shell (local files only: no bd, no Dolt)
    reboot_now_sequence drain                      # bumps the scraper-cut counter from that verdict, just before shutdown
}

if [ "${CHECK_GUARDS_ONLY}" -eq 1 ]; then
    check_guards_report
    exit $?
fi

# Drain mode (fired 23:00-23:19) never reaches the legacy loop below: drain_main
# ends in the reboot sequence or in a SKIP.
if [ "${DRAIN_MODE}" -eq 1 ]; then
    drain_main
    exit $?
fi

ATTEMPT=1
while true; do
    if check_guards_once; then
        break
    fi
    if [ "${ATTEMPT}" -ge "${RETRY_MAX_ATTEMPTS}" ]; then
        log "SKIP: guards still blocked after ${ATTEMPT}/${RETRY_MAX_ATTEMPTS} attempts over ~$(( (ATTEMPT-1) * RETRY_INTERVAL / 60 ))min (last: ${BLOCK_REASON}). Not rebooting."
        notify_athos "Reboot noturno pulado" "bloqueado após ${ATTEMPT}/${RETRY_MAX_ATTEMPTS} tentativas às $(date '+%H:%M') — ${BLOCK_REASON}. Ver ${LOG}." 3 push
        record_skip_bounded "${BLOCK_REASON}"
        exit 0
    fi
    log "attempt ${ATTEMPT}/${RETRY_MAX_ATTEMPTS} blocked (${BLOCK_REASON}) — retrying in ${RETRY_INTERVAL}s."
    sleep "${RETRY_INTERVAL}"
    ATTEMPT=$((ATTEMPT+1))
done
log "guards OK on attempt ${ATTEMPT}/${RETRY_MAX_ATTEMPTS}: 0 real gate markers, no recently-active live builder on any hq in_progress bead, no scraper daily running${HQ_IGNORED_NOTE:+ (${HQ_IGNORED_NOTE})}"

reboot_now_sequence legacy
