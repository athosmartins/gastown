#!/bin/sh
# ram-headroom-lib.sh (ga-1p1i5jr.14, P0) — the ONE reader of "how much real RAM can the mini still give" for the decisions that
# keep memory-hungry work off it. SOURCED, never executed; POSIX sh; no side effect at source time. Sibling of disk-headroom-lib.sh.
#
# ## Contents
#   Why · The floors · Three states · Seams
#
# WHY. 19/11 the mini grew 1 GB swapfiles in /System/Volumes/VM — macOS gives each one back only at the next reboot — with the disk
# falling ~1 GB/h: first a hand-run LiDAR build (2.1 GB), then, with no heavy job at all, the SUM of 16 Claude sessions + Dolt 2.4 GB +
# Chrome on a 16 GB box. RSS and vm.swapusage hide it (compressed memory counts in neither), so the decision reads what the kernel
# itself calls free: `memory_pressure`'s "System-wide memory free percentage" (free + reclaimable without paging) x `hw.memsize`.
# heavy-guard.sh (a RAM-hungry step on the mini) and the Pilot (a new local session) both ask this lib; what is refused goes to the Hetzner node.
#
# THE FLOORS (MB):
#   RAM_NEW_WORK_MIN_MB  2048  the free RAM below which the mini STARTS nothing memory-hungry: heavy-guard.sh refuses a python/node/duckdb
#                              step (rc 75), the Pilot opens no new local session. A step that DECLARES its size (--ram-mb N) needs floor + N.
#   RAM_JOB_MAX_MB       1024  the biggest job the mini runs: a step that declares this much or more goes to the node whatever the free RAM
#                              (a build/backfill > 1 GB is what turned into permanent swapfiles).
#   Both are first estimates, tunable from the free_pct history of ram-owner-samples.jsonl; junk, empty, 0, 08 or 10+ digits = the default.
#
# THREE STATES, never two: ram_state_of prints ok | low | unknown. unknown = no reading, a floor that is not a number, or one `[` could
# not compare; it is NEVER ok. What a caller does with it is its own decision: heavy-guard.sh fails CLOSED (the step is refused, rc 76);
# the Pilot fails OPEN and says so on its log. ram_host_kind: darwin | other (Linux: the swapfile problem is macOS's, nothing to read) |
# unknown (uname gave nothing: NOT "other", so a broken uname cannot switch a guard off).
#
# SEAMS. RAM_AVAIL_OVERRIDE_MB pins the reading in selftests (a number = that many MB, any other non-empty value = unreadable).
# RAM_HEADROOM_ENABLED=0 makes every state ok (kill switch; never set in prod).

RAM_NEW_WORK_MIN_MB="${RAM_NEW_WORK_MIN_MB:-2048}"
RAM_JOB_MAX_MB="${RAM_JOB_MAX_MB:-1024}"
case "$RAM_NEW_WORK_MIN_MB" in ''|0*|*[!0-9]*) RAM_NEW_WORK_MIN_MB=2048 ;; esac
case "$RAM_JOB_MAX_MB" in ''|0*|*[!0-9]*) RAM_JOB_MAX_MB=1024 ;; esac
[ "${#RAM_NEW_WORK_MIN_MB}" -le 9 ] || RAM_NEW_WORK_MIN_MB=2048
[ "${#RAM_JOB_MAX_MB}" -le 9 ] || RAM_JOB_MAX_MB=1024

# ram_host_kind — prints darwin | other | unknown.
ram_host_kind() {
  case "$(uname -s 2>/dev/null)" in Darwin) printf 'darwin' ;; '') printf 'unknown' ;; *) printf 'other' ;; esac
}

# ram_avail_mb — free RAM as an integer MB on stdout and rc 0; rc 1 and NO stdout when it cannot be read (not Darwin, a command that
# fails, a line or a number in a shape nobody modelled). 0 MB is a reading; "could not read" is never 0 and never plenty.
ram_avail_mb() {
  _ra_o="${RAM_AVAIL_OVERRIDE_MB:-}"
  if [ -n "$_ra_o" ]; then
    case "$_ra_o" in *[!0-9]*) return 1 ;; esac
    [ "${#_ra_o}" -le 9 ] || return 1
    printf '%s' "$_ra_o"
    return 0
  fi
  [ "$(ram_host_kind)" = darwin ] || return 1
  # vazio/falhou/ilegível → rc 1 with no number: the pipeline's rc is the last command's, so the emptiness checks below are the real test
  _ra_t=$(sysctl -n hw.memsize 2>/dev/null) || return 1
  _ra_p=$(memory_pressure 2>/dev/null | sed -n 's/^System-wide memory free percentage: \([0-9][0-9]*\)%.*/\1/p' | head -n 1)
  # a leading zero is no shape macOS prints and $(( )) would read it as octal ("08" is an error, "054" is 44); "0" alone is a reading (0% free)
  case "$_ra_t" in 0*) return 1 ;; esac
  case "$_ra_p" in 0?*) return 1 ;; esac
  # `[` is the number check: empty, junk, negative or 20 digits is rc 2 or false, and all of them land on the return. A machine under 1 MB
  # (hw.memsize in some other unit would read 0 MB free) and a "percentage" over 100 are nonsense, not readings.
  { [ "$_ra_t" -ge 1048576 ] && [ "$_ra_p" -le 100 ]; } 2>/dev/null || return 1
  printf '%s' $(( _ra_t / 1048576 * _ra_p / 100 ))
}

# ram_state_of <avail_mb> <min_mb> — the ONE comparison: prints ok | low | unknown from two numbers already read, so a caller that also
# PRINTS the number shows the very reading the verdict came from. Always rc 0.
ram_state_of() {
  _rs_a="${1:-}"; _rs_m="${2:-}"
  if [ "${RAM_HEADROOM_ENABLED:-1}" = "0" ]; then printf 'ok'; return 0; fi
  case "$_rs_a" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  case "$_rs_m" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  # `[` has THREE outcomes (0 true, 1 false, 2 could not compare); only 1 means "not below the floor"
  _rs_rc=0
  [ "$_rs_a" -lt "$_rs_m" ] 2>/dev/null || _rs_rc=$?
  case "$_rs_rc" in 0) printf 'low' ;; 1) printf 'ok' ;; *) printf 'unknown' ;; esac
  return 0
}
