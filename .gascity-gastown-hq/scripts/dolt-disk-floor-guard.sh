#!/bin/bash
# dolt-disk-floor-guard.sh (ga-gpzr) — last-resort disk-floor guard for Dolt.
#
# WHY: 2026-07-14 the HQ Dolt server (port 52756) died mid-journal-write when the
# disk filled to 100% (ga-vs55). It came back up clean this time (data intact,
# verified by the Mayor via positive control) but nothing actually PROTECTS Dolt
# from ENOSPC — a future full-disk event (any source, not just the symlink-descent
# vector already fixed) could hit Dolt mid-write again with no guarantee of a clean
# recovery. ga-vs55's other two furos (rising-pressure notify, symlink guard) don't
# cover this: they slow/warn about a fill that's already underway; neither reserves
# Dolt any headroom of its own, and disk-pressure-monitor.sh polls hourly — a lot
# can fill in an hour.
#
# WHAT: an EXTERNAL, non-invasive watchdog (same shape as dolt-hang-watchdog.sh /
# dolt-gc-maintenance.sh — NOT a patch to Dolt's config or its gitignored,
# framework-managed start wrapper under .gc/, which isn't a durable place to put a
# fix). Polls avail space on Dolt's data-dir filesystem every StartInterval and:
#
#   WARN_GB (default 8)     — attempt the pre-sanctioned-safe reclaim
#                             (`gc dolt-cleanup --force` — orphan test-DB SQL DROP,
#                             documented safe while Dolt is up), PLUS four more
#                             levers — reaping dead-session scratchpads under
#                             /private/tmp (see _reap_dead_scratch, ga-hjcxy/
#                             ga-02pnu: a single dead session's 1GB scratchpad
#                             caused a CRITICAL incident that this follow-up
#                             fixes — dolt-cleanup alone never touched that class
#                             of file), dead-session transcripts under
#                             ~/.claude/projects (see _reap_dead_transcripts,
#                             ga-t1ub9: 1.4GB/1232 files accumulated with no
#                             reaper at all — a disjoint leak class from
#                             scratch), capping known unrotated app logs
#                             under /private/tmp and ~/shared/logs (see
#                             _reap_growing_logs, ga-dnc2m: ~4G across six
#                             never-rotated logs on the SAME APFS container as
#                             Dolt's own data-dir competed directly for this
#                             guard's floor, and none of the other levers
#                             touch that file class — the guard used to
#                             log "reclaim OK — avail 6GB -> 6GB" through an
#                             entire log-driven CRITICAL dip, a reported
#                             success over a complete non-effect), and — CRITICAL
#                             tier only — clearing the `recall` CLI's
#                             huggingface_hub model cache (see _reap_hf_cache,
#                             wa-9eh0v: the 2026-09-04 double outage showed the
#                             OTHER FOUR levers can all report "0GB reclaimed"
#                             in the same cycle — they'd already run their
#                             course; the lever that actually recovered the
#                             disk both times was a human manually clearing
#                             ~/.cache/huggingface, already Athos-authorized
#                             for this cache since the 2026-07-14 ga-vs55
#                             incident, and safe to automate because
#                             recall_lib.py's own bootstrap already treats a
#                             wiped cache as a self-healing cache-miss, not a
#                             failure) — then rate-limited notify. Cooldown is
#                             bypassed if avail is WORSENING since the last
#                             notify (mirrors the exact fix ga-vs55 furo #2
#                             added to disk-pressure-monitor.sh's
#                             dpm_should_notify — a cooldown blind to trend is
#                             what let the city monitor stay silent 28min
#                             before Dolt died; must not regress that lesson
#                             onto this guard).
#
#                             UNLIKE the other four levers, _reap_growing_logs
#                             runs on EVERY cycle regardless of floor class
#                             (see its call at the top of main(), before the
#                             avail/class computation) — ga-dnc2m's own
#                             acceptance criteria ask for these logs to always
#                             carry a cap, not merely to be capped reactively
#                             once Dolt is already under pressure. It is still
#                             gated by ENABLED (see Kill switch below), and
#                             being cheap (a handful of `stat` calls; a
#                             copytruncate only when a file is actually over
#                             its threshold) costs nothing on the common no-op
#                             cycle.
#
#                             UNLIKE the other floor-triggered levers,
#                             _reap_hf_cache only fires at CRITICAL, never at
#                             plain WARN (see its own header comment) — unlike
#                             dolt-cleanup/scratch-reap/transcript-reap/
#                             log-reap, it has a real recurring cost each time
#                             it fires (the next `recall` call pays a bounded
#                             re-download), so it is reserved for the severity
#                             this bead's own incident actually reached
#                             (avail as low as 1GB), not every routine WARN dip.
#
#   CRITICAL_GB (default 3) — same reclaim attempts + notify ALWAYS (cooldown
#                             bypassed unconditionally — this is the last rung
#                             before repeating ga-vs55) + a DURABLE mail to the
#                             Mayor once CRITICAL_MAIL_SUSTAIN (default 2)
#                             consecutive cycles confirm it (ga-q4cqr —
#                             debounces a single self-recovering compaction
#                             spike; see the Mayor's own 2026-07-27 comment on
#                             that bead: one such spike fired 4 pages in one
#                             incident). NOTIFY is never debounced, only the
#                             mail. A near-miss this close to repeating a
#                             city-wide outage must survive a session restart, so
#                             this is mail, not a nudge (see mail-lifecycle
#                             doctrine: "if the recipient dies and restarts, do
#                             they need this message? yes -> mail").
#
# Absolute-GB floors (not percent, unlike disk-pressure-monitor's WARN/EMERGENCY/
# HALT_IMMINENT_PCT): a %-based floor can look "fine" on a large disk while the
# absolute room left is thin, and vice versa on a small one. This guard is a
# Dolt-specific backstop underneath the general city-wide monitor, not a
# replacement for it.
#
#   RESURRECT (ga-f4l2z) — when Dolt is CONFIRMED unreachable
#                             (gc_dolt_probe_robust: retry + SELECT-1
#                             serve-confirm, the SAME module imp08/imp24 use —
#                             never the single-shot probe, which would
#                             false-positive "down" on a mere CPU burst) AND
#                             disk headroom is safe (class NONE or WARN —
#                             NEVER CRITICAL: restarting into a still-full
#                             disk can hit the identical ENOSPC within
#                             seconds, the crash-loop risk this bead exists to
#                             avoid; NEVER UNKNOWN either — an unmeasurable
#                             floor is never "safe", same ga-p5q3 discipline
#                             as every other decision in this file), attempts
#                             `gc dolt start`. NOT `launchctl kickstart`, and
#                             notably NOT relying on the plist's own
#                             KeepAlive: the live com.gastown.dolt-server
#                             .plist DOES already set KeepAlive
#                             (Crashed=true), but its ProgramArguments is
#                             `gc dolt start` itself — a LAUNCHER that forks
#                             the real `dolt sql-server` process and then
#                             exits 0 (success) once it confirms the spawn.
#                             launchd only ever supervises that launcher, and
#                             the launcher's own exit is a SuccessfulExit
#                             (KeepAlive.SuccessfulExit=false, deliberately —
#                             see the plist's own comment), so a LATER crash
#                             of the real, independent dolt sql-server process
#                             is structurally invisible to launchd: there is
#                             no second "Crashed" event to catch, because the
#                             process launchd is watching already exited
#                             cleanly, long before. That is the actual
#                             mechanism behind "presente, ultimo status 0, SEM
#                             PID" (thies-wa's own words on ga-f4l2z) — an
#                             external, disk-aware POLLER is the fix, not a
#                             plist tweak. `gc dolt start` is confirmed
#                             (Mayor's comment on ga-f4l2z) to have its own
#                             port-resolution fallback that brings the process
#                             up from a fully-dead state — unlike
#                             `launchctl kickstart -k`, which re-invokes that
#                             same launcher directly and hits the OTHER known
#                             gap: the shared port_resolve.sh helper other
#                             Dolt-adjacent scripts source has no such
#                             fallback and exits EX_CONFIG (78) cold when
#                             nothing is already up. `gc dolt start` is also
#                             documented idempotent ("start the Dolt server if
#                             not already running") so a probe race can never
#                             cause this guard to disrupt an actually-healthy
#                             Dolt. Checked on EVERY cycle, before the
#                             disk-floor early-returns below, using the
#                             PRE-reclaim class — the common real-world shape
#                             (disk already recovered on its own hours ago;
#                             only Dolt itself never came back) is exactly the
#                             class=NONE fast path this guard used to return
#                             from silently. Mirrors dolt-hang-watchdog.sh's
#                             own proven restart -> reverify -> escalate
#                             shape (same probe module) rather than inventing
#                             a new one — but unlike that watchdog, gates the
#                             restart on disk being safe FIRST: dolt-hang-
#                             watchdog.sh has no disk check of its own and
#                             would blindly retry `gc dolt restart` against a
#                             still-full disk, hitting the identical ENOSPC
#                             again — this guard is the one with both the
#                             disk visibility AND the reclaim levers above, so
#                             it is the correct place to sequence "reclaim,
#                             THEN resurrect" rather than "restart and hope".
#                             Failure to recover escalates via the canonical
#                             escalate_emergency.py --class town-halted (same
#                             path dolt-hang-watchdog.sh's own failure branch
#                             uses) — cooldown-debounced (RESURRECT_ESCALATE
#                             _COOLDOWN_SECS) so a persistent failure pages
#                             once, not every single 5min cycle; see ga-q4cqr
#                             for why an un-debounced repeat page is itself a
#                             documented incident class in this exact file.
#
# OUT OF SCOPE (deliberately — see ga-gpzr's own description: "needs design...
# this is NOT a lane:small fix"): this guard does NOT stop Dolt, does NOT refuse
# writes, and does NOT touch Dolt's data directory. An automated system unilaterally
# halting the town's SOLE data plane is a materially bigger policy decision than
# alerting + pre-sanctioned-safe cleanup, and deserves explicit Mayor/operator
# sign-off rather than being silently bundled into a no-human-review small-lane
# merge. Filed as a separate follow-up bead (see this commit's gate-done note).
# (ga-f4l2z, added AFTER this paragraph was first written: this guard now DOES
# attempt to START a CONFIRMED-dead Dolt back up — see RESURRECT above. That
# is a materially different, much lower-risk action than the STOP/halt this
# paragraph rules out: bringing up an already-dead process cannot itself take
# a healthy Dolt down, `gc dolt start` is a no-op when Dolt is already
# running, and the action is gated to disk-safe classes only.)
#
# Kill switch: DOLT_DISK_FLOOR_GUARD_ENABLED=0 → skip ALL FIVE reclaim actions
# (dolt-cleanup, the scratchpad reaper, the transcript reaper, the log
# reaper, AND the hf-cache reaper) only. Notification is NEVER gated by this switch (imp07 CALL
# INVARIANT: alerting is the lowest-blast-radius action here and the one furo
# #2 just fixed for being wrongly suppressible — don't reintroduce that
# failure mode one guard over).
#
# TEST (no Dolt, no deletions, no real disk mutation, no mail/notify sent):
#   bash scripts/dolt-disk-floor-guard.selftest.sh
# Library mode: `DOLT_DISK_FLOOR_GUARD_LIB=1 source dolt-disk-floor-guard.sh` defines
# the pure decision functions WITHOUT running the guard flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
DOLTDIR="$CITY/.beads/dolt"
LOG="${DOLT_DISK_FLOOR_GUARD_LOG:-$CITY/.gc/logs/dolt-disk-floor-guard.log}"
NOTIFY="/Users/athos/.local/bin/notify"
GC="${GC_BIN:-gc}"
ENABLED="${DOLT_DISK_FLOOR_GUARD_ENABLED:-1}"

FLOOR_WARN_GB="${DOLT_DISK_FLOOR_WARN_GB:-8}"
FLOOR_CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-3}"

# ga-sfj3i.3: GB of macOS virtual-memory residency (/System/Volumes/VM)
# treated as a "significant" consumer when deciding whether a floor breach
# is VM-bound (file cleanup cannot help — see _vm_bound_pressure) vs
# file-bound (cleanup can help). Independent axis from the two floors
# above: those gate on Dolt's own remaining headroom; this gates on how
# much of the SAME container is VM, regardless of avail. Default picked
# from the bead's own "varios GB" framing (more than a rounding blip), not
# yet tuned against production history.
VM_SIGNIFICANT_GB="${DOLT_DISK_FLOOR_VM_SIGNIFICANT_GB:-2}"

NOTIFY_COOLDOWN_SECS="${DOLT_DISK_FLOOR_NOTIFY_COOLDOWN_SECS:-3600}"   # 1h — tighter
                        # than disk-pressure-monitor's 6h; this is Dolt-specific
                        # last-resort protection, not general city monitoring.
STATE_DIR="${DOLT_DISK_FLOOR_STATE_DIR:-$CITY/.gc/logs}"
STATE_EPOCH_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-notify"
STATE_AVAIL_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-notify-avail-gb"

# ga-q4cqr: consecutive CRITICAL cycles required before mailing the Mayor.
# Mayor's own comment on ga-q4cqr (2026-07-27 incident): a single transient
# compaction spike (avail dipped to 2GB then self-recovered within one cycle)
# fired 4 separate pages across the city's guards — "must debounce so a
# self-recovering condition does not storm the inbox." NOTIFY itself stays
# UNCONDITIONAL on every CRITICAL cycle (imp07 CALL INVARIANT, unchanged —
# alerting is the lowest-blast-radius action and must never be suppressed);
# only the DURABLE mail-Mayor escalation is debounced. Poll cadence is 5min
# (StartInterval), so the default of 2 consecutive cycles is a ~5-10min
# confirmation window — mirrors ram-pressure-monitor.sh's RPM_EMERGENCY_SUSTAIN.
CRITICAL_MAIL_SUSTAIN="${DOLT_DISK_FLOOR_CRITICAL_MAIL_SUSTAIN:-2}"
STATE_CRITICAL_SUSTAIN_FILE="$STATE_DIR/.dolt-disk-floor-guard.critical-sustain-count"

# ga-f4l2z: bound on `gc dolt start` when resurrecting a CONFIRMED-down Dolt
# (see _resurrect_dolt). Not yet measured for a cold start specifically after
# an ENOSPC crash (unlike _reap_dead_transcripts's 300s, which has real
# production timing data behind it) — picked conservatively above
# _safe_reclaim's 60s bound for a comparable `gc dolt ___` subcommand, since a
# cold start may replay/recover the noms journal and do more I/O than a
# cleanup DROP. Revisit with real numbers if this ever times out in the log.
RESURRECT_TIMEOUT_SECS="${DOLT_DISK_FLOOR_RESURRECT_TIMEOUT_SECS:-90}"

# ga-f4l2z: once a resurrection attempt FAILS (Dolt still unreachable after
# `gc dolt start`), re-escalate (page Athos again via escalate_emergency.py)
# at most once per this window while the condition persists — mirrors
# ga-q4cqr's CRITICAL_MAIL_SUSTAIN debounce (added to THIS file for the exact
# same reason: a repeat-failure page firing every single 5min StartInterval
# cycle is itself a documented incident class here, not a hypothetical one).
# A cooldown (not a consecutive-cycle sustain counter like ga-q4cqr's) is the
# right shape here: escalation should fire on the FIRST failure immediately
# (there is no "wait and see if it self-recovers" case for a confirmed outage
# the way there was for a transient disk dip), then rate-limit repeats.
RESURRECT_ESCALATE_COOLDOWN_SECS="${DOLT_DISK_FLOOR_RESURRECT_ESCALATE_COOLDOWN_SECS:-3600}"
STATE_RESURRECT_ESCALATE_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-resurrect-escalate"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# optional shared Dolt-health probe (reuse gc-dolt-probe.sh; fail open if missing —
# _safe_reclaim's own timeout still bounds the write it gates)
_PROBE="$CITY/scripts/gc-dolt-probe.sh"
# shellcheck disable=SC1090
[ -f "$_PROBE" ] && . "$_PROBE" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by dolt-disk-floor-guard.selftest.sh.
# No side effects (the df call is read-only); config is passed as explicit params
# so the selftest can exercise arbitrary values without touching globals.
# ════════════════════════════════════════════════════════════════════════════════

# _avail_gb [path] → integer GB available on the filesystem hosting [path]
# (default $CITY), or "" if df fails/parses oddly (e.g. nonexistent path). Uses
# `df -k` + division rather than `df -g` (macOS/BSD df has no -g; -k is portable).
_avail_gb() {
  local path="${1:-$CITY}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 / 1024 ))
}

# _vm_swap_gb → integer GB currently resident in macOS virtual memory
# (/System/Volumes/VM), or "" if unmeasurable (non-macOS host, or the volume
# is absent). Lives in the SAME APFS container as $DOLTDIR but is root-owned,
# kernel-managed, grows monotonically within a boot, and is untouched by any
# of this guard's four reclaim levers — see ga-sfj3i.2. `du -sk` works
# without sudo: directory listing/size is readable even though individual
# swapfile *contents* are root-only (mode 0600).
_vm_swap_gb() {
  local kb
  kb="$(du -sk /System/Volumes/VM 2>/dev/null | awk '{print $1}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 / 1024 ))
}

# _top_rss_processes [n] → top N processes on this host by resident set size
# (RSS, KB), one "PID RSS_KB COMMAND" line per process, highest first —
# ga-sfj3i.3 item 4: "top 5 RSS so the kill decision is informed, not a
# guess." This guard still never kills anything itself (see OUT OF SCOPE
# above) — purely informational, for whoever reads the alert. Best-effort:
# empty output (not a crash) if `ps` is missing or produces no rows; callers
# must treat empty as "unmeasured", same contract as _avail_gb/_vm_swap_gb,
# never as "no processes running". Not gated by ENABLED — this is a read,
# not a reclaim action, same precedent as _vm_swap_gb above.
_top_rss_processes() {
  local n="${1:-5}"
  ps -Ao pid,rss,comm 2>/dev/null | tail -n +2 | sort -rn -k2 | head -n "$n"
}

# _floor_class <avail_gb> <warn_gb> <crit_gb> → NONE|WARN|CRITICAL|UNKNOWN.
# UNKNOWN (empty/non-numeric avail_gb, e.g. df failed) is NEVER silently treated as
# NONE — a failed read must fail LOUD, not collapse into "no problem" (ga-p5q3:
# error and empty must not produce the same value when the emptiness is load-bearing).
_floor_class() {
  local avail="$1" warn="$2" crit="$3"
  case "$avail" in ''|*[!0-9]*) echo "UNKNOWN"; return ;; esac
  if [ "$avail" -le "$crit" ]; then echo "CRITICAL"; return; fi
  if [ "$avail" -le "$warn" ]; then echo "WARN"; return; fi
  echo "NONE"
}

# _vm_bound_pressure <reclaimed_gb> <vm_gb> <threshold_gb> → 0 (true) when
# the three floor-triggered reclaim levers (_safe_reclaim, _reap_dead_scratch,
# _reap_dead_transcripts — NOT _reap_growing_logs, which always runs before
# any of this is even measured) returned ~0 bytes (reclaimed_gb <= 0) AND
# macOS virtual-memory residency is a significant, MEASURED consumer
# (vm_gb >= threshold_gb). This is the exact ga-sfj3i.3 incident shape:
# "reclaim OK — avail X -> X" while GB are actually stuck in
# /System/Volumes/VM. Requires vm_gb to be a valid measurement — same
# never-silently-assume discipline as _floor_class's own UNKNOWN handling —
# an unmeasurable vm_gb (empty; non-macOS host or the volume absent) can
# never confirm VM-bound pressure, only ever false/unknown. reclaimed_gb is
# a caller-computed arithmetic result (avail_after - avail_before, always a
# clean signed integer when both reads succeeded) and threshold_gb is a
# config value — both trusted without re-validation here, same trust level
# _floor_class already extends to its own warn/crit params.
_vm_bound_pressure() {
  local reclaimed="$1" vm="$2" threshold="$3"
  case "$vm" in ''|*[!0-9]*) return 1 ;; esac
  [ "$reclaimed" -le 0 ] && [ "$vm" -ge "$threshold" ]
}

# _worsening <current_avail_gb> <last_notified_avail_gb_or_empty> → 0 (true) only
# when there IS a valid prior value AND current is strictly LOWER — avail-GB
# FALLING is pressure worsening (the inverse framing of disk-pressure-monitor's
# usage-% RISING; same idiom, same reason: dpm_pressure_rising in
# disk-pressure-monitor.sh). No prior value → false (unknown trend is not on its
# own a reason to bypass the cooldown — _cooldown_elapsed's fail-open already
# covers "never notified").
_worsening() {
  local current="$1" last="$2"
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  case "$current" in ''|*[!0-9]*) return 1 ;; esac
  [ "$current" -lt "$last" ]
}

# _cooldown_elapsed <last_epoch_or_empty> <now_epoch> <cooldown_secs> → 0 (true)
# when there's no/invalid prior timestamp (fail-open — a corrupt state file must
# never silence a real emergency) or the cooldown window has passed.
_cooldown_elapsed() {
  local last="$1" now="$2" cd="$3"
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( now - last )) -ge "$cd" ]
}

# _should_notify <last_epoch> <now_epoch> <cooldown> <current_avail> <last_avail>
# → 0 (notify) when the cooldown elapsed OR pressure is worsening since the last
# notify. This is the WARN-tier gate; CRITICAL always notifies unconditionally
# (handled directly in main — the last rung before repeating ga-vs55 must never be
# rate-limited).
_should_notify() {
  local last_epoch="$1" now="$2" cooldown="$3" current="$4" last_avail="$5"
  _cooldown_elapsed "$last_epoch" "$now" "$cooldown" && return 0
  _worsening "$current" "$last_avail"
}

# _sustain_confirmed <pending_count> <threshold> → 0 (true) once pending_count
# has reached threshold. Trivial arithmetic, but kept as a named, unit-tested
# function — matching this file's own "decisions are pure + tested" convention
# — so the boundary (>= not >) is explicit and covered, same as _floor_class's
# inclusive boundaries above. A non-numeric pending_count (corrupt state file)
# fails CLOSED here (never confirmed) — the OPPOSITE fail-direction from
# _cooldown_elapsed's fail-open, deliberately: a corrupt cooldown timestamp
# must never SILENCE a real emergency (imp07), but a corrupt sustain COUNTER
# must never PREMATURELY confirm one on garbage data — _write_critical_sustain
# always writes a clean integer, so corruption here would mean external
# interference, not a normal empty-state case (contrast STATE_EPOCH_FILE/
# STATE_AVAIL_FILE, which are legitimately empty on a fresh install).
_sustain_confirmed() {
  local pending="$1" threshold="$2"
  case "$pending" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pending" -ge "$threshold" ]
}

# _should_resurrect <probe_rc> <class> → 0 (true) only when Dolt is CONFIRMED
# down (probe_rc=1 — gc_dolt_probe_robust's documented "unreachable, confirmed"
# code, NEVER 0=healthy or 2=unknown/transient) AND disk headroom is safely
# above the critical floor (class NONE or WARN — never CRITICAL, the exact
# crash-loop risk ga-f4l2z warns about: restarting into a still-full disk can
# hit the same ENOSPC within seconds; and never UNKNOWN, which means df itself
# failed and headroom cannot be confirmed either way — an unmeasurable floor
# must never be treated as safe, same ga-p5q3 discipline as _floor_class's own
# UNKNOWN handling above). probe_rc=2 (unknown/transient, e.g. a CPU burst the
# robust probe could not rule out) must never be conflated with a confirmed
# outage — same never-treat-indeterminate-as-a-specific-value discipline this
# whole file already applies to disk reads.
_should_resurrect() {
  local probe_rc="$1" class="$2"
  [ "$probe_rc" = "1" ] || return 1
  case "$class" in
    NONE|WARN) return 0 ;;
    *) return 1 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest)
# ════════════════════════════════════════════════════════════════════════════════

_read_state() {
  _LAST_EPOCH=""; _LAST_AVAIL=""
  [ -f "$STATE_EPOCH_FILE" ] && _LAST_EPOCH="$(cat "$STATE_EPOCH_FILE" 2>/dev/null)"
  [ -f "$STATE_AVAIL_FILE" ] && _LAST_AVAIL="$(cat "$STATE_AVAIL_FILE" 2>/dev/null)"
}

_write_state() {
  local epoch="$1" avail="$2"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$epoch" > "$STATE_EPOCH_FILE" 2>/dev/null || true
  echo "$avail" > "$STATE_AVAIL_FILE" 2>/dev/null || true
}

# _read_critical_sustain / _write_critical_sustain — persist the consecutive-
# CRITICAL-cycle counter the mail-Mayor sustain-guard reads. Missing/corrupt
# state reads as 0 (fresh install / no prior streak — NOT "sustain already
# confirmed"; see _sustain_confirmed's fail-CLOSED note above for why that
# asymmetry with the notify-cooldown state files is intentional).
_read_critical_sustain() {
  local f="$STATE_CRITICAL_SUSTAIN_FILE" v
  v="$([ -f "$f" ] && cat "$f" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

_write_critical_sustain() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$1" > "$STATE_CRITICAL_SUSTAIN_FILE" 2>/dev/null || true
}

# _safe_reclaim <before_avail_gb> → best-effort `gc dolt-cleanup --force` (orphan
# test-DB SQL DROP — pre-sanctioned safe while Dolt is up; see gastown.dog
# operational doctrine's dolt cleanup entry). Only runs when Dolt is confirmed
# healthy (never pile a write onto an already-struggling server — same
# skip-unless-healthy gate dolt-gc-maintenance.sh's _run_prune uses) and only when
# the kill switch is on. Bounded by timeout so a wedged Dolt can't hang the guard.
_safe_reclaim() {
  local before="$1"
  if [ "$ENABLED" != "1" ]; then
    log "reclaim SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if declare -f gc_dolt_probe >/dev/null 2>&1; then
    if ! gc_dolt_probe; then
      log "reclaim SKIP — dolt not confirmed-healthy (cleanup is a write; retry next cycle)"
      return
    fi
  fi
  # ga-eu2x: use the HYPHEN command (gc dolt-cleanup, the Go path) — NOT the space
  # form (gc dolt cleanup, shell). This runs AUTOMATICALLY and unattended when the
  # disk is low, which is EXACTLY when Dolt is slow and `gc rig list` degrades — and
  # the space form decides "orphan" by non-reference to a rig list that just failed,
  # so a degraded lookup could see a production DB as orphan and DROP it. The hyphen
  # form is prefix-gated (only test/agent DB name patterns) and cannot drop
  # production by construction, so it is the correct command for an automatic guard.
  # It still reclaims disk (drops stale test DBs + DOLT_PURGE_DROPPED_DATABASES).
  log "reclaim: avail=${before}GB at/below floor — running 'gc dolt-cleanup --force' …"
  if timeout 60 "$GC" dolt-cleanup --force >> "$LOG" 2>&1; then
    local after; after="$(_avail_gb "$DOLTDIR")"
    log "reclaim OK — avail ${before}GB -> ${after:-?}GB"
  else
    log "reclaim FAILED (gc dolt-cleanup --force nonzero exit)"
  fi
}

# _reap_dead_scratch — second reclaim lever, alongside _safe_reclaim (ga-hjcxy,
# fixing ga-02pnu): dead Claude Code sessions' scratchpads under /private/tmp
# accumulate with nothing to reap them (the worktree-reaper only covers
# REGISTERED git worktrees, not loose scratch dirs) — a single 1GB dead
# scratchpad caused a CRITICAL disk-floor incident this follow-up fixes.
# Delegates to the standalone, independently-selftested scratchpad-reaper.sh so
# its liveness/staleness safety logic is unit-tested in isolation rather than
# inlined here. Bounded by timeout so a wedged `gc session list` can't hang this
# guard; best-effort — a failure here must never block the dolt-cleanup lever or
# the notify decision that follows it.
#
# SCRATCHPAD_REAPER_PROD=1 (ga-h565g): this function IS the real, launchd-driven
# caller scratchpad-reaper.sh's own production-sentinel guard is designed to
# trust — the ONLY place that should ever set this opt-in. It authorizes
# scratchpad-reaper.sh to actually delete when its resolved root equals its
# real default; without it, a harness bug that leaves that root at the default
# (exactly what caused the sibling transcript-reaper.sh incident) forces a
# dry-run instead of deleting real data.
#
# <was_critical> (ga-rjhfz, optional, defaults "0"): main() passes whether
# THIS cycle was CRITICAL at any point (pre- or post-reclaim — see the
# was_critical latch above). "1" sets SCRATCHPAD_REAPER_PRESSURE=CRITICAL,
# which is the ONLY thing that activates scratchpad-reaper.sh's own
# size-escape gate (independently selftested there) — a large dead scratchpad
# too fresh for its normal 24h grace window can still be freed during a real
# crisis instead of surviving it, which is what happened 2026-08-06 (a 10GB/
# 3.5h dead scratchpad outlived two CRITICAL cycles because age was the only
# gate). "0"/omitted leaves the variable unset — behavior identical to before
# ga-rjhfz.
_reap_dead_scratch() {
  local was_critical="${1:-0}"
  if [ "$ENABLED" != "1" ]; then
    log "scratch-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/scratchpad-reaper.sh"
  if [ ! -f "$reaper" ]; then
    log "scratch-reap SKIP — $reaper not found"
    return
  fi
  if [ "$was_critical" = "1" ]; then
    log "scratch-reap: running dead-session scratchpad cleanup (pressure=CRITICAL, size-escape eligible) …"
    if SCRATCHPAD_REAPER_PROD=1 SCRATCHPAD_REAPER_PRESSURE=CRITICAL timeout 60 bash "$reaper" >> "$LOG" 2>&1; then
      log "scratch-reap OK"
    else
      log "scratch-reap FAILED or aborted (nonzero exit) — see log lines above"
    fi
  else
    log "scratch-reap: running dead-session scratchpad cleanup …"
    if SCRATCHPAD_REAPER_PROD=1 timeout 60 bash "$reaper" >> "$LOG" 2>&1; then
      log "scratch-reap OK"
    else
      log "scratch-reap FAILED or aborted (nonzero exit) — see log lines above"
    fi
  fi
}

# _reap_dead_transcripts — third reclaim lever, alongside _safe_reclaim and
# _reap_dead_scratch (ga-t1ub9, same family as ga-02pnu): Claude Code session
# transcripts under ~/.claude/projects/<project>/<session-id>.jsonl accumulate
# forever with nothing to reap them — 1.4GB across 1232 files by 2026-07-26,
# contributing to two Dolt ENOSPC hits that day. Delegates to the standalone,
# independently-selftested transcript-reaper.sh so its liveness/staleness
# safety logic (NEVER reap a live or suspended session's transcript — losing
# one is unrecoverable, unlike scratch) is unit- AND integration-tested in
# isolation rather than inlined here. Bounded by timeout so a wedged `gc
# session list` can't hang this guard; best-effort — a failure here must never
# block the other two reclaim levers or the notify decision that follows.
#
# TRANSCRIPT_REAPER_PROD=1 (ga-lfj05, completing ga-h565g for this file): this
# function IS the real, launchd-driven caller transcript-reaper.sh's own
# production-sentinel guard is designed to trust — the ONLY place that should
# ever set this opt-in. It authorizes transcript-reaper.sh to actually delete
# when its resolved root equals its real default; without it, a harness bug
# that leaves that root at the default (exactly what caused this script's own
# 2026-07-26 185-transcript incident) forces a dry-run instead of deleting
# real data.
_reap_dead_transcripts() {
  if [ "$ENABLED" != "1" ]; then
    log "transcript-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/transcript-reaper.sh"
  if [ ! -f "$reaper" ]; then
    log "transcript-reap SKIP — $reaper not found"
    return
  fi
  log "transcript-reap: running dead-session transcript cleanup …"
  # Bound sized to the MEASURED cost of the work, not to a round number.
  # MEASURED 2026-08-01: a full pass takes ~39s on this host (1854 transcripts
  # across 122 project dirs; the reaper `du -sk`s each candidate AND its sibling
  # dir, and calls `gc session list --json` first to verify liveness before any
  # irreversible delete). 39s against a 60s bound is a ~35% margin — and the
  # liveness call alone stretches from ~1.3s to 10-20s whenever Dolt is warm,
  # which is precisely WHEN this path runs (disk pressure and Dolt pressure
  # arrive together). Live evidence in this very log: 5 runs, 5 timeouts, ZERO
  # successes, each lasting exactly ~60s (23:36:56->23:37:57, 23:43:21->23:44:21).
  # An emergency disk-reclaim that never completes is worse than none, because
  # the "FAILED" line reads as "tried and could not free space" when the truth
  # is "was killed before it could try". Same class as ga-gquc1 (backup dog:
  # 120s bound vs a 6.3G database) and ga-q4cqr's ladder.
  # 300s is deliberately generous: this runs only at/below the disk floor, at
  # most once per guard cycle, and finishing LATE is strictly better than not
  # finishing. The reaper is itself fail-safe — it ABORTS rather than delete
  # when it cannot verify session liveness (ga-lfj05, after the 2026-07-26
  # incident that deleted 185 live transcripts), so a longer bound cannot make
  # it delete anything it would not have deleted at 60s.
  local _reap_bound="${TRANSCRIPT_REAP_TIMEOUT_SECS:-300}"
  local _reap_start _reap_elapsed
  _reap_start=$(date +%s)
  if TRANSCRIPT_REAPER_PROD=1 timeout "$_reap_bound" bash "$reaper" >> "$LOG" 2>&1; then
    _reap_elapsed=$(( $(date +%s) - _reap_start ))
    log "transcript-reap OK (${_reap_elapsed}s, bound=${_reap_bound}s)"
  else
    _reap_elapsed=$(( $(date +%s) - _reap_start ))
    # Distinguish "ran out of time" from "ran and failed" — they need different
    # responses, and collapsing them is what hid 5 consecutive timeouts as a
    # generic FAILED (root-class:error-vs-empty).
    if [ "$_reap_elapsed" -ge "$_reap_bound" ]; then
      log "transcript-reap TIMED OUT after ${_reap_elapsed}s (bound=${_reap_bound}s) — reclaim did NOT run to completion; raise TRANSCRIPT_REAP_TIMEOUT_SECS if this repeats"
    else
      log "transcript-reap FAILED after ${_reap_elapsed}s (nonzero exit, not a timeout) — see log lines above"
    fi
  fi
}

# _reap_hf_cache — fourth reclaim lever, alongside _safe_reclaim,
# _reap_dead_scratch and _reap_dead_transcripts (wa-9eh0v, 2026-09-04 double
# outage 12h apart): the three levers above can ALL report "0GB reclaimed"
# in the same cycle — live evidence in this guard's own log that day,
# 07:31:23: "reclaimed=0GB avail_before=2GB". They'd already run their
# course. The lever that actually recovered the disk both times was a human
# manually clearing ~/.cache/huggingface (the `recall` CLI's
# sentence-transformers model cache — see scripts/recall_lib.py) via
# huggingface_hub's own scan_cache_dir()/delete_revisions() API, already
# authorized by Athos for this specific cache in the prior (2026-07-14,
# ga-vs55) incident. This automates that exact, already-proven action.
# Delegates to the standalone hf_cache_reap.py (run through the `recall`
# CLI's own venv — huggingface_hub is NOT on the guard's plain launchd
# PATH's system python3, verified live) so the huggingface_hub call is
# independently testable/runnable in isolation, same pattern as the
# scratch/transcript levers above delegating to their own scripts.
#
# CRITICAL-only (unlike the three levers above, which run at WARN too): this
# one has a real cost each time it fires — recall_lib.py's own bootstrap
# (wa-h9dc1) already treats a wiped cache as expected/self-healing (one
# ~180s-bounded re-download on next use), but paying that on every ordinary
# WARN dip would degrade `recall` for everyone far more often than the
# emergency it exists for. Reserved for the tier this bead's own incident
# actually hit (avail as low as 1GB).
#
# HF_CACHE_REAP_PROD=1: same production-sentinel pattern as
# SCRATCHPAD_REAPER_PROD/TRANSCRIPT_REAPER_PROD above (ga-h565g/ga-lfj05) —
# only this function, the real launchd-driven caller, should ever set it.
# Without it, hf_cache_reap.py dry-runs (scans + reports, deletes nothing) —
# which is also what keeps this safe to invoke from the selftest below.
_reap_hf_cache() {
  local was_critical="${1:-0}"
  if [ "$ENABLED" != "1" ]; then
    log "hf-cache-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if [ "$was_critical" != "1" ]; then
    log "hf-cache-reap SKIP — not CRITICAL this cycle (emergency-only lever)"
    return
  fi
  local script="$CITY/scripts/hf_cache_reap.py"
  local venv_py="$CITY/.gc/recall-venv/bin/python3"
  if [ ! -f "$script" ]; then
    log "hf-cache-reap SKIP — $script not found"
    return
  fi
  if [ ! -x "$venv_py" ]; then
    log "hf-cache-reap SKIP — $venv_py not found/executable"
    return
  fi
  log "hf-cache-reap: CRITICAL — reclaiming recall's huggingface model cache …"
  if HF_CACHE_REAP_PROD=1 timeout 30 "$venv_py" "$script" >> "$LOG" 2>&1; then
    log "hf-cache-reap OK"
  else
    log "hf-cache-reap FAILED or aborted (nonzero exit) — see log lines above"
  fi
}

# _reap_growing_logs — fifth reclaim lever, alongside _safe_reclaim,
# _reap_dead_scratch, _reap_dead_transcripts, and _reap_hf_cache (ga-dnc2m):
# known app logs under /private/tmp and ~/shared/logs that nothing ever
# rotated — a distinct leak class from the others (none of them look at
# app-log files at all). Delegates to the standalone, independently-selftested log-reaper.sh
# so its size-cap logic is unit-tested in isolation rather than inlined here
# — same pattern as the scratch/transcript levers. Cheap and bounded by
# timeout so it can safely run on every cycle (see the UNLIKE note in this
# file's own header): a handful of `stat` calls, with a `cp`+truncate only
# for a file that is actually over threshold.
#
# LOG_REAPER_PROD=1 (same ga-h565g pattern as the other two reapers): this
# function IS the real, launchd-driven caller log-reaper.sh's own
# production-sentinel guard is designed to trust — the ONLY place that
# should ever set this opt-in.
_reap_growing_logs() {
  if [ "$ENABLED" != "1" ]; then
    log "log-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/log-reaper.sh"
  if [ ! -f "$reaper" ]; then
    log "log-reap SKIP — $reaper not found"
    return
  fi
  if LOG_REAPER_PROD=1 timeout 30 bash "$reaper" >> "$LOG" 2>&1; then
    log "log-reap OK"
  else
    log "log-reap FAILED or aborted (nonzero exit) — see log lines above"
  fi
}

# _resurrect_dolt <avail_gb> <class> — last-resort auto-respawn for a Dolt
# sql-server CONFIRMED down while disk headroom is safe. Caller (main) has
# already run _should_resurrect's gate; this function does the actual work.
# See this file's own header ("RESURRECT") for the full reasoning on why
# `gc dolt start` (not kickstart, not relying on the plist's KeepAlive) is
# the correct action, and why dolt-hang-watchdog.sh's own restart path isn't
# a substitute (no disk check of its own).
#
# Bounded by RESURRECT_TIMEOUT_SECS so a wedged start attempt can't hang this
# guard's own cycle. Best-effort: on failure, the condition is picked up
# again next cycle (5min StartInterval) rather than retried in a tight loop —
# same "bounded, not looped" discipline as every other reclaim lever in this
# file. Re-probes after a brief settle sleep to confirm the start actually
# worked (mirrors dolt-hang-watchdog.sh's own restart->sleep->reverify shape)
# rather than trusting `gc dolt start`'s exit code alone — a launcher that
# exits 0 having merely INITIATED a start that then itself fails slightly
# later (e.g. disk fills again mid-recovery) must not be logged as success.
_resurrect_dolt() {
  local avail="$1" class="$2"
  if [ "$ENABLED" != "1" ]; then
    log "resurrect SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return 1
  fi
  log "resurrect: Dolt CONFIRMED unreachable (gc_dolt_probe_robust) with disk safe (class=${class} avail=${avail}GB) — attempting 'gc dolt start' …"
  ( cd "$CITY" && GC_CITY="$CITY" timeout "$RESURRECT_TIMEOUT_SECS" "$GC" dolt start >> "$LOG" 2>&1 )
  local start_rc=$?
  sleep 5
  if gc_dolt_probe_robust; then
    log "resurrect OK — Dolt serving again after 'gc dolt start' (rc=${start_rc})"
    "$NOTIFY" -t "Dolt disk-floor guard" -p 4 "🔁 Dolt was confirmed down — auto-restarted via 'gc dolt start' (disk avail=${avail}GB, class=${class}). Verify the city is healthy. See ga-f4l2z." 2>/dev/null || true
    return 0
  fi

  log "resurrect FAILED — Dolt still unreachable after 'gc dolt start' (rc=${start_rc})"
  local now_epoch last_escalate
  now_epoch=$(date +%s)
  last_escalate=""
  [ -f "$STATE_RESURRECT_ESCALATE_FILE" ] && last_escalate="$(cat "$STATE_RESURRECT_ESCALATE_FILE" 2>/dev/null)"
  if ! _cooldown_elapsed "$last_escalate" "$now_epoch" "$RESURRECT_ESCALATE_COOLDOWN_SECS"; then
    log "resurrect escalation SUPPRESSED — already escalated within the last ${RESURRECT_ESCALATE_COOLDOWN_SECS}s (avoids paging every 5min cycle while unresolved, ga-q4cqr precedent)"
    return 1
  fi

  local escalator="$CITY/scripts/escalate_emergency.py"
  if [ ! -f "$escalator" ]; then
    log "resurrect escalation SKIP — $escalator not found"
    return 1
  fi
  python3 "$escalator" --class town-halted \
    --title "dolt-disk-floor-guard: auto-restart did not recover Dolt" \
    "Dolt was confirmed down (gc_dolt_probe_robust) with disk safe (avail=${avail}GB, class=${class}) but 'gc dolt start' (rc=${start_rc}) did not bring it back. NEEDS HUMAN: run 'gc dolt start' by hand and investigate. See ga-f4l2z for background — the Mayor's comment there also notes 'gc start --dry-run' failed once with 'gc-fatal: gc start failed', which may be the same root cause." \
    >> "$LOG" 2>&1 || log "WARN: escalate_emergency.py call failed (non-fatal)"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$now_epoch" > "$STATE_RESURRECT_ESCALATE_FILE" 2>/dev/null || true
  return 1
}

main() {
  local avail class now

  # UNLIKE the other three levers below, this runs UNCONDITIONALLY, before
  # the avail/class computation — see this file's own header for why.
  _reap_growing_logs

  avail="$(_avail_gb "$DOLTDIR")"
  now=$(date +%s)
  class="$(_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB")"

  # ga-sfj3i.2: log macOS virtual memory residency as its OWN metric line
  # EVERY cycle, regardless of class or whether avail was even readable —
  # an unmeasurable reading must be a logged "unknown", never silence, so
  # this guard's own log (the same file 40 days of avail-GB history were
  # mined from for ga-sfj3i.2) carries this consumer as a real, gate-able
  # line instead of an absence. This space is NOT one of the four reclaim
  # levers below — it is non-recoverable without a reboot.
  local vm_gb; vm_gb="$(_vm_swap_gb)"
  log "vm_swap_gb=${vm_gb:-unknown} (macOS virtual memory, /System/Volumes/VM — same APFS container as \$DOLTDIR, non-recoverable without reboot; ga-sfj3i.2)"

  # ga-f4l2z: resurrection check runs BEFORE the disk-floor early-returns
  # below (including the class=NONE fast path) and uses the PRE-reclaim
  # class — the common real-world shape is disk already comfortably NONE
  # (recovered on its own hours ago) with Dolt simply never having come back
  # on its own; that case must not wait for a WARN/CRITICAL breach to even be
  # considered. _should_resurrect's own gate (never CRITICAL, never UNKNOWN)
  # is what actually restricts when this can act — see this file's own
  # header ("RESURRECT") for the full reasoning. Skipped entirely if the
  # probe module failed to source (fail-open, same guard _safe_reclaim
  # already uses for gc_dolt_probe) — never treat "can't probe" as "must
  # resurrect". Deliberately NOT re-evaluated against the post-reclaim class
  # later in this function: a cycle that reads CRITICAL here defers
  # resurrection to the NEXT cycle even if reclaim happens to recover it
  # same-cycle — a one-cycle (5min) delay is the safe tradeoff against ever
  # trusting a same-cycle recovery enough to restart into it.
  if [ "$class" != "UNKNOWN" ] && declare -f gc_dolt_probe_robust >/dev/null 2>&1; then
    gc_dolt_probe_robust
    local probe_rc=$?
    if _should_resurrect "$probe_rc" "$class"; then
      _resurrect_dolt "$avail" "$class"
    fi
  fi

  if [ "$class" = "UNKNOWN" ]; then
    log "WARN: could not read avail space for $DOLTDIR (df failed/unparseable) — cannot verify Dolt's disk floor this cycle"
    "$NOTIFY" -t "Dolt disk-floor guard" -p 3 "⚠️ disk-floor guard couldn't read df for Dolt's data dir — check manually" 2>/dev/null || true
    return 0
  fi
  if [ "$class" = "NONE" ]; then
    log "avail=${avail}GB > floor(warn=${FLOOR_WARN_GB}GB) — OK"
    _write_critical_sustain 0
    return 0
  fi

  # Latch whether THIS reading (pre-reclaim) was CRITICAL. The CRITICAL-tier
  # guarantee ("notify ALWAYS, cooldown bypassed, mail Mayor" — see header) must
  # key off "was CRITICAL at any point this cycle", not solely the `class`
  # recomputed below AFTER reclaim — otherwise a reclaim that recovers avail
  # back into WARN/NONE silently swallows the exact breach this guard exists to
  # report (gate-fix-1: GATE-FEEDBACK on gate_run=ga-wisp-9b4hnh — repro'd with
  # shipped defaults WARN=8/CRIT=3/cooldown=3600: a CRITICAL 2GB reading
  # reclaimed back to exactly 8GB was reclassified WARN and suppressed by
  # ordinary WARN cooldown/worsening logic, skipping the CRITICAL-only
  # mail-Mayor alert entirely).
  local was_critical=0
  [ "$class" = "CRITICAL" ] && was_critical=1

  # ga-sfj3i.3: snapshot avail BEFORE the three floor-triggered levers run,
  # so their combined effect can be measured (reclaimed_gb below) instead of
  # only inferred from the reclassified `class`.
  local avail_before="$avail"

  _read_state
  _safe_reclaim "$avail"
  _reap_dead_scratch "$was_critical"
  _reap_dead_transcripts
  _reap_hf_cache "$was_critical"

  # re-read avail — reclaim may have freed space; `class` becomes the CURRENT
  # (post-reclaim) reading, used for logging/messaging. was_critical also
  # latches a post-reclaim CRITICAL reading (e.g. a concurrent fill worsens
  # avail during the reclaim window) so the guarantee holds regardless of
  # which direction avail moved this cycle.
  local avail_after; avail_after="$(_avail_gb "$DOLTDIR")"
  [ -n "$avail_after" ] && avail="$avail_after"
  class="$(_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB")"
  [ "$class" = "CRITICAL" ] && was_critical=1

  # ga-sfj3i.3: how much did the three floor-triggered levers actually free?
  # Empty (not 0) when either read failed — an unmeasurable reclaim must
  # never be treated as "reclaimed nothing" (ga-p5q3: error and empty must
  # not collapse to the same value). vm_bound requires a NON-empty
  # reclaimed_gb, so an unmeasurable reclaim can never spuriously confirm
  # VM-bound pressure either.
  local reclaimed_gb=""
  if [ -n "$avail_before" ] && [ -n "$avail_after" ]; then
    reclaimed_gb=$(( avail_after - avail_before ))
  fi
  local vm_bound=0
  if [ -n "$reclaimed_gb" ] && _vm_bound_pressure "$reclaimed_gb" "${vm_gb:-}" "$VM_SIGNIFICANT_GB"; then
    vm_bound=1
  fi

  # ga-q4cqr: any cycle that is NOT critical (post-reclaim) breaks a
  # CRITICAL-mail sustain streak, regardless of which of the three
  # non-critical exits below this cycle takes — mirrors
  # ram-pressure-monitor.sh resetting its own EMERGENCY sustain count on
  # every OK *and* every WARN-but-not-EMERGENCY sample. Placed once here
  # (rather than in each of the three exits) so it can't be missed if a
  # future edit adds a fourth.
  [ "$was_critical" = "0" ] && _write_critical_sustain 0

  if [ "$class" = "NONE" ] && [ "$was_critical" = "0" ]; then
    log "avail=${avail}GB back above floor after reclaim — no notify needed"
    _write_state "$now" "$avail"
    return 0
  fi

  local do_notify=1
  if [ "$was_critical" = "0" ] && [ "$class" = "WARN" ] && ! _should_notify "$_LAST_EPOCH" "$now" "$NOTIFY_COOLDOWN_SECS" "$avail" "$_LAST_AVAIL"; then
    do_notify=0
    log "avail=${avail}GB <= warn floor(${FLOOR_WARN_GB}GB) but within cooldown + not worsening — suppressing (last notified avail=${_LAST_AVAIL:-none}GB)"
  fi

  if [ "$do_notify" = "1" ]; then
    local prio=3
    [ "$was_critical" = "1" ] && prio=5

    # ga-sfj3i.3: distinguish the two opposite remedies instead of always
    # emitting the same "reclaim attempted" text (item 3) — exhaustive over
    # four cases so an unmeasurable reclaim is never mistaken for a specific
    # known cause (ga-p5q3 discipline, same as the rest of this file).
    local diagnosis
    if [ "$vm_bound" = "1" ]; then
      diagnosis="cleanup will NOT resolve this — ${vm_gb}GB stuck in virtual memory; the only lever is reducing RAM pressure"
    elif [ -z "$reclaimed_gb" ]; then
      diagnosis="reclaim effect unmeasured (post-reclaim df read failed)"
    elif [ "$reclaimed_gb" -gt 0 ]; then
      diagnosis="file cleanup recovered ${reclaimed_gb}GB"
    else
      diagnosis="file cleanup found nothing to reclaim; cause not identified"
    fi
    log "diagnosis: ${diagnosis} (reclaimed=${reclaimed_gb:-unmeasured}GB avail_before=${avail_before}GB vm_swap=${vm_gb:-unknown}GB vm_threshold=${VM_SIGNIFICANT_GB}GB)"

    # ga-sfj3i.3 item 4: top RSS consumers, so a kill decision (made by a
    # human/Mayor — this guard still never kills anything itself) is
    # informed rather than a guess. Logged only when actually alerting, not
    # every cycle — unlike vm_swap_gb, this isn't needed for historical
    # mining, only for the moment someone has to act.
    local top_rss; top_rss="$(_top_rss_processes 5)"
    if [ -n "$top_rss" ]; then
      log "top RSS processes (PID RSS_KB COMMAND):"
      printf '%s\n' "$top_rss" | while IFS= read -r _rss_line; do log "  $_rss_line"; done
    else
      log "top RSS processes: unmeasured (ps produced no rows)"
    fi

    log "class=${class} was_critical=${was_critical}: avail=${avail}GB (warn=${FLOOR_WARN_GB}GB crit=${FLOOR_CRITICAL_GB}GB) — notifying"
    # ga-ff6t9: notify's own content classifier (classify_route_detail(), in
    # whatsapp_automation/scripts/notify) decides push-vs-digest from MESSAGE
    # WORDING, not from -p/priority — this exact CRITICAL message ("avail=2GB
    # ... Dolt data-dir ...") was measured (2026-09-04 disk-full incident, and
    # reproduced via NOTIFY_ROUTE_TEST=1) to match none of its push rules and
    # fall to the muted hourly digest despite -p 5, silencing the guard at the
    # one moment (Dolt about to die of ENOSPC) it must reach the phone
    # regardless of Dolt's own health. NOTIFY_FORCE_PUSH=1 is notify's
    # documented, Dolt-independent escape hatch for a caller that already
    # knows the message must page — the same mechanism escalate_emergency.py
    # uses for its 3 sanctioned classes. Scoped to was_critical (not the
    # recomputed `class`, which a reclaim can already move back to WARN — see
    # the CRITICAL->WARN scenario in the selftest): only the guaranteed-page
    # tier forces delivery; ordinary WARN keeps using notify's normal
    # cooldown/content-routing path.
    if [ "$was_critical" = "1" ]; then
      NOTIFY_FORCE_PUSH=1 "$NOTIFY" -t "Dolt disk-floor guard" -p "$prio" "🚨 [${class}] Dolt data-dir avail=${avail}GB, vm_swap=${vm_gb:-unknown}GB — ${diagnosis}. See ga-gpzr." 2>/dev/null || true
    else
      "$NOTIFY" -t "Dolt disk-floor guard" -p "$prio" "🚨 [${class}] Dolt data-dir avail=${avail}GB, vm_swap=${vm_gb:-unknown}GB — ${diagnosis}. See ga-gpzr." 2>/dev/null || true
    fi
    if [ "$was_critical" = "1" ]; then
      # ga-q4cqr sustain-guard: require CRITICAL_MAIL_SUSTAIN consecutive
      # CRITICAL cycles before mailing the Mayor — debounces a single
      # transient dip (self-recovering compaction spike). NOTIFY above is
      # UNCONDITIONAL regardless (imp07 invariant, unchanged) — only this
      # durable escalation is gated.
      local pending; pending=$(( $(_read_critical_sustain) + 1 ))
      _write_critical_sustain "$pending"
      if _sustain_confirmed "$pending" "$CRITICAL_MAIL_SUSTAIN"; then
        log "CRITICAL sustain confirmed (${pending}/${CRITICAL_MAIL_SUSTAIN} consecutive cycles) — mailing Mayor"
        # ga-sfj3i.3: same exhaustive four-way split as the short `diagnosis`
        # above, expanded to a full paragraph for the durable mail channel.
        # Opposite remedies (file cleanup vs reduce RAM pressure) must never
        # produce the same paragraph — that was the bug this bead exists to
        # fix (item 3).
        local diagnosis_detail
        if [ "$vm_bound" = "1" ]; then
          diagnosis_detail="File-based reclaim (dolt-cleanup + scratchpad/transcript reaping) returned
essentially 0 bytes this cycle (avail ${avail_before}GB -> ${avail}GB) while ${vm_gb}GB sits in
macOS virtual memory (/System/Volumes/VM, same APFS container as this data-dir). That space is
NOT visible to du (root-owned, outside the user tree) and will NOT be freed by this guard's
reclaim levers or by any du-guided cleanup — it only shrinks when RAM pressure drops or on
reboot. The only lever left is reducing RAM pressure (see the RSS listing below)."
        elif [ -z "$reclaimed_gb" ]; then
          diagnosis_detail="Could not measure how much the file-based reclaim levers freed this
cycle (the post-reclaim df read failed). vm_swap is ${vm_gb:-also unmeasured}GB. Investigate
manually (df -h, du -sh on shared/data and .gc/logs)."
        elif [ "$reclaimed_gb" -gt 0 ]; then
          diagnosis_detail="File cleanup worked: file-based reclaim (dolt-cleanup + scratchpad/
transcript reaping) recovered ${reclaimed_gb}GB this cycle (avail ${avail_before}GB -> ${avail}GB)
— a file-fillable event, not a virtual-memory one. vm_swap is currently ${vm_gb:-an unmeasured amount}GB
(below the ${VM_SIGNIFICANT_GB}GB significance threshold, or unmeasured) and is not implicated here."
        else
          diagnosis_detail="File-based reclaim returned essentially 0 bytes this cycle (avail
${avail_before}GB -> ${avail}GB), and vm_swap (${vm_gb:-unmeasured}GB) is not a confirmed
significant contributor either (below the ${VM_SIGNIFICANT_GB}GB threshold, or unmeasured) —
neither known cause explains this reading. Investigate manually (df -h, du -sh on shared/data
and .gc/logs)."
        fi
        # NOTE: deliberately NOT a heredoc — bash 3.2 (macOS system /bin/bash, what
        # launchd invokes per the plist) mis-parses a heredoc nested inside a $(...)
        # command substitution when the body contains an apostrophe (confirmed by
        # direct repro on this machine). A plain multi-line double-quoted assignment
        # has no such bug and is otherwise equivalent.
        local mail_body="dolt-disk-floor-guard: Dolt data-dir hit CRITICAL floor (<= ${FLOOR_CRITICAL_GB}GB) for ${pending} consecutive cycles.
Safe reclaim (gc dolt-cleanup --force), dead-session scratchpad cleanup, and dead-session
transcript cleanup were already attempted this cycle. This is the same class of event that
killed the HQ Dolt server on 2026-07-14 (ga-vs55): a full disk hitting Dolt mid-journal-write.
CRITICAL persisted across multiple cycles and could recur even if the current reading looks
recovered.

DIAGNOSIS (ga-sfj3i.3): ${diagnosis}. ${diagnosis_detail}

Top 5 processes by resident memory (PID  RSS_KB  COMMAND), for an informed decision on what to
bring down if RAM pressure is the lever (this guard never kills anything itself):
${top_rss:-  (unmeasured — ps produced no rows)}

(ga-sfj3i.2 measured the vm_swap<->disk correlation and the Mayor's own follow-up falsified a
broader causal claim against 40 days of this guard's history — see that bead for the raw numbers.)"
        "$GC" mail send mayor -s "Dolt disk-floor CRITICAL: avail=${avail}GB" -m "$mail_body" 2>/dev/null || log "WARN: gc mail send mayor failed"
      else
        log "CRITICAL sample ${pending}/${CRITICAL_MAIL_SUSTAIN} — PENDING, not yet mailing Mayor (single-cycle dip may self-recover; notify above already fired unconditionally)"
      fi
    fi
    _write_state "$now" "$avail"
  fi
}

# ── run unless sourced as a library (selftest sources with DOLT_DISK_FLOOR_GUARD_LIB=1) ──
if [ "${DOLT_DISK_FLOOR_GUARD_LIB:-0}" != "1" ]; then
  main
  exit 0
fi
