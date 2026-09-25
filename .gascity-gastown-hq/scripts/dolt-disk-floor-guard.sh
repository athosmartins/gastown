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
#                             documented safe while Dolt is up), PLUS six more
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
#                             failure), and trimming the Go build cache
#                             (GOCACHE) once it has grown large enough to
#                             matter (see _reap_gocache, ga-yi68q: MEASURED
#                             2026-09-10 — GOCACHE went from ~0 to 4.8GB in
#                             ~1h of `bd` builds/tests (bd embeds the whole
#                             Dolt engine, so each build/test run generates
#                             GBs of compiled artifact), pushing this guard's
#                             own floor down to 1.2GB avail; `go clean
#                             -cache` recovered 5.5GB instantly. Skipped at
#                             WARN while a go/compile/link process is
#                             actively running — an interrupted build just
#                             recompiles on retry, avoidable churn at that
#                             tier — forced at CRITICAL regardless, since
#                             Dolt hitting ENOSPC mid-journal-write (ga-vs55)
#                             is not similarly recoverable), and reaping
#                             orphaned go-build<N> work dirs under
#                             DARWIN_USER_TEMP_DIR left behind by an
#                             interrupted `go build`/`go test` (see
#                             _reap_go_build_orphans, ga-ilmjgo: MEASURED —
#                             4th occurrence by 2026-09-15, 0.5-2.5GB each,
#                             including a plain SIGINT that still orphaned
#                             its dir — same APFS container as Dolt's
#                             data-dir, never reused once orphaned, only a
#                             human ever cleared it before this. Reaps at
#                             WARN same as CRITICAL — an orphan is never
#                             useful again — gated PER DIRECTORY on a real
#                             `lsof` liveness check (no open file/cwd inside
#                             it) plus a 30min mtime grace period, never on
#                             a global go-active flag the way gocache is) —
#                             then
#                             rate-limited notify. Cooldown is
#                             bypassed if avail is WORSENING since the last
#                             notify (mirrors the exact fix ga-vs55 furo #2
#                             added to disk-pressure-monitor.sh's
#                             dpm_should_notify — a cooldown blind to trend is
#                             what let the city monitor stay silent 28min
#                             before Dolt died; must not regress that lesson
#                             onto this guard).
#
#                             UNLIKE the other six levers, _reap_growing_logs
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
#                             log-reap/gocache-reap, it has a real recurring cost each time
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
#                             they need this message? yes -> mail"). Once
#                             sustain-confirmed, this durable mail does NOT
#                             then repeat on every subsequent CRITICAL cycle
#                             (ga-4f4opx — the sustain gate alone stayed true
#                             forever once confirmed, producing one Mayor mail
#                             per 5min cycle: measured 32 of 65 Mayor mails in
#                             one night, same disk event). Re-mail requires a
#                             new relevant minimum (avail drops by
#                             >= CRITICAL_MAIL_MIN_DROP_GB, default 1GB) or
#                             CRITICAL_MAIL_COOLDOWN_SECS (default 2h) since
#                             the last mail — see _should_mail_critical. The
#                             FIRST recovery cycle after an episode that
#                             actually mailed the Mayor also sends exactly one
#                             RECOVERED mail (_maybe_mail_recovery) and resets
#                             the debounce state for the next episode.
#
#   DISK-GROWTH PHOTO (ga-ond0fa) — READ-ONLY diagnostic, not a reclaim lever.
#                             2026-09-25 free space fell ~10GB -> 3GB in ~25min
#                             (CRITICAL for 3 cycles) and recovered by 02:16 with
#                             no author: the guard logged only "avail=", the reclaim
#                             levers found nothing, ~7GB stayed anonymous. Now, on
#                             the FIRST WARN cycle and again on the first CRITICAL
#                             cycle of an episode — before any reclaim lever runs,
#                             since they delete the very things that grew — it
#                             photographs one-level `du -sk` under a fixed set of
#                             roots (the dolt data-dir per database, .dolt-backup,
#                             ~/shared/data, /private/tmp, DARWIN_USER_TEMP_DIR,
#                             ~/.claude/projects, every .gc-worktrees, ~/Library/
#                             Caches) plus vm.swapusage and /System/Volumes/VM plus
#                             the biggest files currently held open for WRITE, and
#                             diffs it against a "last OK" baseline photo refreshed
#                             (rate-limited, nice'd) on class=NONE cycles. Output:
#                             .gc/logs/disk-growth-<ts>.txt, the top growers in this
#                             log, and a WHAT GREW paragraph in the Mayor CRITICAL
#                             mail. A root that timed out says PARTIAL, one the scan
#                             budget never reached says SKIPPED — and the diff never
#                             calls anything "new" or "grown" from a root that was
#                             not completely measured on both sides. macOS has no
#                             per-process write counter without root, so "who wrote"
#                             is approximated by "which held-open file grew and which
#                             pid holds it" (labelled as a proxy everywhere it is
#                             shown). Own switch: DOLT_DISK_FLOOR_GROWTH_PHOTO_ENABLED
#                             (NOT DOLT_DISK_FLOOR_GUARD_ENABLED — nothing here
#                             deletes or stops anything).
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
# Kill switch: DOLT_DISK_FLOOR_GUARD_ENABLED=0 → skip ALL SEVEN reclaim actions
# (dolt-cleanup, the scratchpad reaper, the transcript reaper, the log
# reaper, the hf-cache reaper, the gocache reaper, AND the go-build-orphan
# reaper) only. Notification is NEVER gated by this switch (imp07 CALL
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

# ga-yi68q: GB the Go build cache (GOCACHE) must reach before _reap_gocache
# considers it worth trimming. Independent axis from the two floors above and
# from VM_SIGNIFICANT_GB: those gate on Dolt's own remaining headroom (or on
# how much of the SAME container is VM); this gates on how large GOCACHE
# itself has grown, regardless of avail — a small cache isn't worth the
# recompile cost of wiping it even while Dolt's floor is breached by
# something else. Default of 3 matches the bead's own "~3 GB" framing
# (MEASURED 2026-09-10: grew to 4.8GB in ~1h of `bd` builds/tests).
GOCACHE_REAP_THRESHOLD_GB="${DOLT_DISK_FLOOR_GOCACHE_REAP_THRESHOLD_GB:-3}"

# ga-ilmjgo: seconds an orphaned go-build<N> work dir under
# DARWIN_USER_TEMP_DIR must sit untouched (mtime age) before
# _reap_go_build_orphans will delete it — grace window for a build that JUST
# created the dir (matches the bead's own "carência para build que acabou de
# criar o dir" framing). Independent axis from GOCACHE_REAP_THRESHOLD_GB:
# that gates on GOCACHE's total size; this gates on a SINGLE orphan dir's
# age, regardless of size — an orphan is never reused once its owning
# process exits (unlike GOCACHE, which Go keeps reusing), so size never
# factors into whether it's worth reaping (see this file's own header).
# Default of 1800 (30min) is the bead's own stated grace period.
GO_BUILD_ORPHAN_GRACE_SECS="${DOLT_DISK_FLOOR_GO_BUILD_ORPHAN_GRACE_SECS:-1800}"

# ga-nkqook: same grace-window rationale as GO_BUILD_ORPHAN_GRACE_SECS above,
# applied to macOS's own com.google.Chrome.code_sign_clone dirs (one created
# per Chrome (re)launch under /private/var/folders/.../X — confirmed via a
# live crash loop: com.athos.chrome-cdp SIGSEGVs and relaunches roughly every
# 12-16min, 57 clones ~1:1 with 56 successive crashes since boot, 78GB in du
# though CoW makes the real growth much smaller — see that bead for the full
# measurement). An orphan here is never reused once its owning Chrome exits,
# same as a go-build dir, so the same age-only (not size-based) grace applies.
CODE_SIGN_CLONE_ORPHAN_GRACE_SECS="${DOLT_DISK_FLOOR_CODE_SIGN_CLONE_ORPHAN_GRACE_SECS:-1800}"

# ga-ofi307: seconds a per-invocation shadow git repo under
# /private/tmp/claude-<uid>/bash-edit-diff/<hash>/ (Claude Code's own Bash-tool
# edit-diff rendering cache — see _reap_bash_edit_diff_orphans) must sit
# untouched (mtime age) before this lever will delete it. Age-ONLY grace,
# deliberately with NO liveness check (unlike GO_BUILD_ORPHAN_GRACE_SECS/
# CODE_SIGN_CLONE_ORPHAN_GRACE_SECS above, both gated by a real lsof liveness
# probe): each subdirectory is named by a content hash, not a PID or session
# id, so there is no live-process correlation this guard could check even if
# it wanted to (confirmed live, ga-ofi307: "sem correlacao com sessao viva").
# mtime is the only signal available, and it is a reliable one — an active
# session rewrites its own dir's index on every edit. Default of 7200 (2h)
# matches this bead's own manual remediation the night it was filed: 31 dirs
# untouched >2h were safe to delete (3.4GB freed), preserving the 7 still-
# active ones with zero side effects (the cache regenerates on next use).
BASH_EDIT_DIFF_ORPHAN_GRACE_SECS="${DOLT_DISK_FLOOR_BASH_EDIT_DIFF_GRACE_SECS:-7200}"

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

# ga-4f4opx: once CRITICAL_MAIL_SUSTAIN first confirms and mails the Mayor,
# this guard used to mail AGAIN on every single subsequent CRITICAL cycle —
# `pending` (above) only grows and _sustain_confirmed stays true forever once
# the streak crosses the threshold, so a CRITICAL condition that persisted
# overnight (5min StartInterval) produced one Mayor mail EVERY cycle: measured
# 32 of 65 Mayor mails in one night, all re-reporting the SAME disk event
# (ga-6gp0a6) with the "for N consecutive cycles" count as the only thing that
# changed. Re-mail (after the first sustain-confirmed one) is now gated the
# same shape as the WARN-tier notify below (_should_notify: cooldown OR
# worsening) but on its OWN, longer cooldown, its OWN drop threshold, and its
# OWN state track (STATE_LAST_MAIL_*) — this channel wakes the Mayor, the
# WARN-tier NOTIFY-cooldown state above does not, and the two must never
# share a debounce clock. Defaults (2h / 1GB) are this bead's own stated
# policy ("passar 2h desde o último aviso" / "cair mais 1GB"), not yet tuned
# against production history. NOTIFY itself is UNCHANGED by this — still
# unconditional on every CRITICAL cycle (imp07), only the DURABLE mail is
# further debounced here, on top of (not instead of) the sustain gate above.
CRITICAL_MAIL_COOLDOWN_SECS="${DOLT_DISK_FLOOR_CRITICAL_MAIL_COOLDOWN_SECS:-7200}"
CRITICAL_MAIL_MIN_DROP_GB="${DOLT_DISK_FLOOR_CRITICAL_MAIL_MIN_DROP_GB:-1}"
STATE_LAST_MAIL_EPOCH_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-mail-epoch"
STATE_LAST_MAIL_AVAIL_FILE="$STATE_DIR/.dolt-disk-floor-guard.last-mail-avail-gb"
# Tracks whether THIS CRITICAL episode ever actually mailed the Mayor, so a
# recovery mail only fires when there's something to close out — never for a
# WARN/CRITICAL dip the Mayor was never told about (ga-4f4opx: "manter ... o
# [aviso] de recuperação").
STATE_CRITICAL_EPISODE_MAILED_FILE="$STATE_DIR/.dolt-disk-floor-guard.critical-episode-mailed"

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

# ga-74tts6: bound on one `dolt-backup-reseed.sh <db>` attempt triggered by
# THIS guard at CRITICAL (see _reap_bloated_backup_staging) — separate from
# dolt-s3-backup.sh's own RESEED_TIMEOUT_SECS (default 1800s) for the SAME
# script's daily 04:00 call. That 1800s budget is fine for a once-a-day cron
# job but would block this guard's own ~300s StartInterval cycle for up to 30
# cycles' worth of wall time; 240s mirrors _reap_backup_residue's 180s
# same-file precedent (a bit larger because a reseed does real sync/restore
# I/O, not just an S3 head-object check). A timeout kill mid-reseed carries
# the same "SEM BACKUP LOCAL, unalarmed" residual risk the daily cron's own
# timeout wrapper already has — not a new risk this lever introduces, just a
# second, shorter-fused caller of it.
RESEED_TRIGGER_TIMEOUT_SECS="${DOLT_DISK_FLOOR_RESEED_TRIGGER_TIMEOUT_SECS:-240}"

# ga-74tts6: per-db cooldown between guard-triggered reseed attempts. A
# success moves avail back up, so the NEXT cycle's was_critical gate alone
# would normally stop repeats — this cooldown only matters for the FAILURE
# case (S3 proof failing, or the reseed timing out), where without it the
# guard would retry the SAME losing attempt every single 5min CRITICAL cycle.
# 30min gives a transient cause (e.g. a flaky S3 call) room to clear without
# hammering, while still being far shorter than dolt-s3-backup.sh's own
# once-a-day cadence — the whole point of this lever (ga-74tts6) is to not
# wait for that.
RESEED_TRIGGER_COOLDOWN_SECS="${DOLT_DISK_FLOOR_RESEED_TRIGGER_COOLDOWN_SECS:-1800}"
STATE_RESEED_TRIGGER_DIR="$STATE_DIR/.dolt-disk-floor-guard.reseed-attempt"

# ga-ond0fa: DISK-GROWTH PHOTO — see the header's DISK-GROWTH PHOTO paragraph for
# the incident and the design. Read-only diagnostic (never a reclaim lever), so
# NOT gated by DOLT_DISK_FLOOR_GUARD_ENABLED — it has its own switch. The state
# files are resolved at CALL time from $STATE_DIR (_growth_baseline_file /
# _growth_episode_file below), not frozen here at source time: this suite has
# twice leaked a stray state file into the real $CITY/.gc/logs because a
# source-time path was evaluated before the selftest's STATE_DIR redirect (see
# STATE_CRITICAL_SUSTAIN_FILE's redirect comment in the selftest), and a helper
# that reads $STATE_DIR when it runs cannot repeat that.
GROWTH_PHOTO_ENABLED="${DOLT_DISK_FLOOR_GROWTH_PHOTO_ENABLED:-1}"
# Seconds between refreshes of the "last OK" baseline photo (taken only on
# class=NONE cycles). Each scan is I/O — MEASURED 2026-09-25 at load ~47 (this
# city's normal): ~/Library/Caches alone took 91s serially — so it is
# rate-limited and nice'd rather than run every 5min cycle (a detector's poll
# cost is part of the load it observes; ga-y0g5x). 30min keeps the baseline
# fresh enough to bracket a ~25min fill like the 2026-09-25 01:0x->01:30 dive.
GROWTH_BASELINE_INTERVAL_SECS="${DOLT_DISK_FLOOR_GROWTH_BASELINE_INTERVAL_SECS:-1800}"
# Per-root bound, and a whole-scan budget. A root that hits its bound keeps the
# rows that finished (PARTIAL); once the budget is spent the remaining roots are
# recorded SKIPPED — an explicit "not measured", never a silent zero (ga-p5q3).
# The episode photo runs BEFORE the reclaim levers (they delete the very things
# that grew), so the budget is also the most this photo can delay them.
GROWTH_ROOT_TIMEOUT_SECS="${DOLT_DISK_FLOOR_GROWTH_ROOT_TIMEOUT_SECS:-60}"
GROWTH_TOTAL_BUDGET_SECS="${DOLT_DISK_FLOOR_GROWTH_TOTAL_BUDGET_SECS:-150}"
# Tighter budget for the photo taken on a CRITICAL cycle: it runs before the
# reclaim levers, and MEASURED 2026-09-25 (load ~47) an unbounded-in-practice
# photo took 90s of scanning — 90s the last-resort reclaim would otherwise not
# have waited. A partial CRITICAL photo (later roots SKIPPED, said so) beats a
# delayed reclaim; the WARN photo and the baseline get the full budget above.
GROWTH_CRITICAL_BUDGET_SECS="${DOLT_DISK_FLOOR_GROWTH_CRITICAL_BUDGET_SECS:-60}"
# Smallest growth (MB) worth listing, how many growers to list, and how many
# disk-growth-<ts>.txt files to keep (each is a few KB; the cap only stops an
# oscillating disk from accumulating them forever).
GROWTH_MIN_DELTA_MB="${DOLT_DISK_FLOOR_GROWTH_MIN_DELTA_MB:-50}"
GROWTH_TOP_N="${DOLT_DISK_FLOOR_GROWTH_TOP_N:-8}"
GROWTH_KEEP_PHOTOS="${DOLT_DISK_FLOOR_GROWTH_KEEP_PHOTOS:-20}"
# Smallest regular file (MB) that _top_open_write_files reports as "held open
# for write".
GROWTH_WRITER_MIN_MB="${DOLT_DISK_FLOOR_GROWTH_WRITER_MIN_MB:-100}"

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

# _top_mem_processes [n] → top N processes on this host by TOTAL physical-
# memory footprint (top's own "mem" stat key — `man top`: "Physical memory
# footprint of the process" — resident AND compressed pages combined, the
# same metric Activity Monitor's "Memory" column and the `footprint` tool
# report), one "PID PPID MEM CMPRS LAUNCHD_LABEL FULL_COMMAND" line per
# process, highest footprint first. REPLACES _top_rss_processes (ga-xz5re):
# `ps`'s RSS only counts resident, UNCOMPRESSED pages, so a process whose
# memory is mostly swapped/compressed is invisible to it. Confirmed live
# 2026-09-11: a 22GB python search-index build (PID 89690) had RSS small
# enough to rank behind ordinary dolt/claude processes in the OLD `ps -Ao
# pid,rss,comm` listing, and only surfaced when the Mayor ran `top -l 1 -o
# mem -stats pid,ppid,command,mem,cmprs` by hand — this guard's own alert
# never mentioned it. MEM reads equal to CMPRS (22G/22G) for a process
# that's entirely compressed precisely because "mem" already folds CMPRS in
# — sorting by it, not by RSS, is what surfaces that shape.
#
# FULL_COMMAND resolves via `ps -o command=` per PID — top's own COMMAND
# column is name-only and truncated (e.g. every python process shows as
# "Python"), which is exactly how PID 89690 would have stayed anonymous
# even in a mem-sorted listing; full args are what let a human tell
# build_ficha360_search_index.py apart from any other python process.
# LAUNCHD_LABEL resolves via one shared `launchctl list` call (a PID→label
# map built once, not N calls) and reads "-" for the common case of a
# process that isn't itself a directly launchd-managed job.
#
# This guard still never kills anything itself (see OUT OF SCOPE above) —
# purely informational, for whoever reads the alert. Best-effort throughout,
# same "empty means unmeasured, never zero processes" contract as every
# other read in this file (ga-p5q3): `top`/`ps`/`launchctl` failing, an
# unparseable/reordered top banner, or a process exiting between the `top`
# snapshot and the per-PID `ps`/`launchctl` lookups (expected — this guard
# polls a live, changing process table every 5min) all surface as
# fewer/emptier fields, never a crash and never a fabricated row. Not gated
# by ENABLED — this is a read, not a reclaim action, same precedent as
# _vm_swap_gb above.
_top_mem_processes() {
  local n="${1:-5}"
  local top_out
  top_out="$(top -l 1 -o mem -stats pid,ppid,command,mem,cmprs -n "$n" 2>/dev/null)"
  [ -z "$top_out" ] && { echo ""; return; }

  # top's banner (process/CPU/mem/VM/network/disk summary, ~10 lines)
  # precedes a blank line then the column header — skip everything through
  # the header line itself (matched by leading-whitespace + "PID", not a
  # fixed line count, so a reordered/added banner line can't silently shift
  # which rows get treated as data).
  local rows
  rows="$(printf '%s\n' "$top_out" | awk '
    started { if (NF > 0) print; next }
    /^[[:space:]]*PID/ { started=1; next }
  ')"
  [ -z "$rows" ] && { echo ""; return; }

  local launchd_map=""
  if command -v launchctl >/dev/null 2>&1; then
    launchd_map="$(launchctl list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $3}')"
  fi

  # PID/PPID are grabbed from the FRONT and MEM/CMPRS from the BACK ($(NF-1)/
  # $NF) rather than by fixed field index — top's own COMMAND field can in
  # principle contain whitespace, and this stays correct regardless of how
  # many "middle" fields that expands to.
  printf '%s\n' "$rows" | head -n "$n" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pid ppid mem cmprs cmd label found
    pid="$(printf '%s' "$line" | awk '{print $1}')"
    ppid="$(printf '%s' "$line" | awk '{print $2}')"
    mem="$(printf '%s' "$line" | awk '{print $(NF-1)}')"
    cmprs="$(printf '%s' "$line" | awk '{print $NF}')"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ppid" in ''|*[!0-9]*) continue ;; esac

    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    [ -z "$cmd" ] && cmd="(unavailable — process may have exited)"

    label="-"
    if [ -n "$launchd_map" ]; then
      found="$(printf '%s\n' "$launchd_map" | awk -v p="$pid" '$1==p {print $2; exit}')"
      [ -n "$found" ] && label="$found"
    fi

    printf '%s %s %s %s %s %s\n' "$pid" "$ppid" "$mem" "$cmprs" "$label" "$cmd"
  done
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

# _should_mail_critical <last_mail_epoch> <now> <cooldown_secs> <current_avail>
#   <last_mail_avail> <min_drop_gb> → 0 (true, mail again) when there is no
# valid prior-mail record for this episode (fail-open via _cooldown_elapsed's
# own no-prior-timestamp case — the first sustain-confirmed mail of an episode
# must never be blocked by this gate) OR the mail-specific cooldown elapsed OR
# avail has dropped by at least min_drop_gb since the last mail (a "new
# relevant minimum" — ga-4f4opx acceptance criteria (a)/(b): re-mail only on a
# new minimum, or after 2h, while CRITICAL persists). Deliberately a SEPARATE
# function/state track from _should_notify above, never reusing its cooldown
# or its worsening direction — this gates the Mayor-mail channel specifically,
# on its own (longer) cooldown and its own drop threshold; conflating the two
# would make the WARN-tier push cadence and the CRITICAL-tier mail cadence
# move together, which they must not (see this file's own CRITICAL_MAIL_
# COOLDOWN_SECS comment). A non-numeric/empty current can't actually reach
# this call (main() returns before this point when class=UNKNOWN — see
# _floor_class's own UNKNOWN handling), but is still checked here (fails
# closed on the drop check only, not the cooldown check) so this function
# stays safe to unit-test and to call in isolation, same discipline
# _sustain_confirmed's own comment documents for this file.
_should_mail_critical() {
  local last_mail_epoch="$1" now="$2" cooldown="$3" current="$4" last_mail_avail="$5" min_drop="$6"
  _cooldown_elapsed "$last_mail_epoch" "$now" "$cooldown" && return 0
  case "$last_mail_avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$current" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( last_mail_avail - current )) -ge "$min_drop" ]
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

# _gocache_dir → the Go build cache directory (GOCACHE). Prefers `go env
# GOCACHE` (respects any GOENV/env override on this host) and falls back to
# the well-known macOS default if `go` isn't on PATH — same
# never-crash-on-a-missing-external-binary shape as the optional $_PROBE
# source above (ga-yi68q).
_gocache_dir() {
  local d
  d="$(command -v go >/dev/null 2>&1 && go env GOCACHE 2>/dev/null)"
  [ -n "$d" ] && { echo "$d"; return; }
  echo "$HOME/Library/Caches/go-build"
}

# _gocache_size_gb [dir] → integer GB used by the Go build cache (default
# _gocache_dir), or "" if du fails/parses oddly (e.g. dir doesn't exist) —
# same never-silently-assume-0 contract as _avail_gb/_vm_swap_gb above
# (ga-yi68q).
_gocache_size_gb() {
  local dir="${1:-$(_gocache_dir)}" kb
  kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 / 1024 ))
}

# _go_toolchain_active → 0 (true, exit code) if a `go build`/`go test`/`go
# install`/`go run` invocation or one of the toolchain's own internal
# subprocesses (compile/link) is currently running. Best-effort, like
# _top_mem_processes: pgrep absence/failure reads as "not active" (1/false)
# — the safe direction, since _should_reap_gocache's CRITICAL branch forces
# the reap regardless of this reading; a false negative here only costs one
# WARN-tier cycle (5min), never blocks the CRITICAL guarantee (ga-yi68q).
_go_toolchain_active() {
  pgrep -x compile >/dev/null 2>&1 && return 0
  pgrep -x link >/dev/null 2>&1 && return 0
  pgrep -f '(^|/)go (build|test|install|run)' >/dev/null 2>&1
}

# _should_reap_gocache <cache_gb> <threshold_gb> <go_active> <was_critical> →
# 0 (true) when the cache is large enough to be worth reaping (cache_gb >=
# threshold_gb) AND EITHER no go/compile/link process is active OR this
# cycle is CRITICAL (ga-yi68q's own two-tier policy: prefer not to disrupt
# an in-flight build at WARN — a build that fails from a vanished cache
# entry just recompiles on retry, recoverable — but CRITICAL overrides,
# since Dolt hitting ENOSPC mid-journal-write is not). cache_gb
# empty/non-numeric (du failed) fails CLOSED — never guess a size to
# justify wiping the cache (ga-p5q3 discipline, same asymmetry
# _sustain_confirmed's own comment already documents for this file's
# corrupt-state case).
_should_reap_gocache() {
  local cache_gb="$1" threshold_gb="$2" go_active="$3" was_critical="$4"
  case "$cache_gb" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cache_gb" -ge "$threshold_gb" ] || return 1
  if [ "$go_active" = "1" ] && [ "$was_critical" != "1" ]; then
    return 1
  fi
  return 0
}

# _go_build_tmp_root → DARWIN_USER_TEMP_DIR (macOS per-user scratch root,
# trailing slash stripped), or "" if getconf fails/unsupported (non-macOS
# host). Same never-silently-assume-a-default contract as _gocache_dir's `go
# env GOCACHE` call above — an unresolved root must skip the lever entirely
# (see _reap_go_build_orphans), never silently fall back to a guessed path
# this guard doesn't actually control (ga-ilmjgo).
_go_build_tmp_root() {
  local d
  d="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  [ -z "$d" ] && { echo ""; return; }
  echo "${d%/}"
}

# _code_sign_clone_root → the per-user "X" scratch dir macOS clones code-signed
# app binaries into (sibling of DARWIN_USER_TEMP_DIR's "T" and
# DARWIN_USER_CACHE_DIR's "C" under the same /var/folders/<xx>/<yyyy...>/
# per-user root), plus the fixed com.google.Chrome.code_sign_clone leaf
# observed live (ga-nkqook: .../X/com.google.Chrome.code_sign_clone held 57
# code_sign_clone.* subdirs, 78GB du, after a multi-hour crash loop). There is
# no getconf key for "X" itself, so this derives it from the one macOS DOES
# expose (DARWIN_USER_TEMP_DIR) by stripping the trailing "T" segment — same
# never-hardcode-an-unverified-path discipline as _go_build_tmp_root: an
# unresolved TEMP dir (non-macOS host, getconf failure) must skip the lever
# entirely, never guess "/var/folders/.../X" from nothing.
_code_sign_clone_root() {
  local t parent
  t="$(_go_build_tmp_root)"
  [ -z "$t" ] && { echo ""; return; }
  parent="$(dirname "$t")"
  echo "$parent/X/com.google.Chrome.code_sign_clone"
}

# _bash_edit_diff_root → /private/tmp/claude-<uid>/bash-edit-diff, the root
# Claude Code's own Bash-tool edit-diff renderer uses for its per-invocation
# shadow git repos (see _reap_bash_edit_diff_orphans's header for the full
# incident, ga-ofi307). Same "claude-$(id -u)" convention scratchpad-
# reaper.sh's own SCRATCH_REAL_DEFAULT_ROOT already uses — this is a SIBLING
# of that scratchpad root, not nested inside it, which is exactly why neither
# the scratchpad reaper nor the transcript reaper ever saw it ("ficam num
# diretorio irmao, com nome proprio, sem correlacao com sessao viva").
_bash_edit_diff_root() {
  echo "/private/tmp/claude-$(id -u 2>/dev/null)/bash-edit-diff"
}

# _dir_size_mb <dir> → integer MB used by <dir>, or "" if du fails/parses
# oddly (e.g. dir doesn't exist) — MB granularity (not GB, unlike
# _gocache_size_gb) because individual go-build<N> dirs commonly run well
# under 1GB. Same never-silently-assume-0 contract as every other size read
# in this file (ga-p5q3, ga-ilmjgo).
_dir_size_mb() {
  local dir="$1" kb
  kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 ))
}

# _go_build_dir_in_use <dir> → tristate exit code, mirrors the
# 0=confirmed-healthy/1=confirmed-down/2=unknown convention
# gc_dolt_probe_robust already uses elsewhere in this file (see
# _should_resurrect): 0 = lsof found an open file or cwd anywhere inside
# <dir> (IN USE — never reap), 1 = lsof ran clean and found NOTHING
# (CONFIRMED orphaned), 2 = could not determine (lsof missing from PATH,
# timed out, or reported a real error) — rc=2 must NEVER be treated as rc=1
# (ga-p5q3: "couldn't see" must never collapse into "nothing is alive",
# ga-ilmjgo item 3).
#
# Content-based, not exit-code-based: lsof's own exit code conflates "no
# matches found" and "a real error occurred" (both commonly surface as a
# nonzero exit with nothing on stdout), so this trusts stdout CONTENT for
# the positive case (anything printed means a match) and stderr CONTENT to
# distinguish a genuine error from a clean empty result, rather than
# trusting lsof's raw exit code the way a simpler check might.
_go_build_dir_in_use() {
  local dir="$1" out err rc errfile
  if ! command -v lsof >/dev/null 2>&1; then
    return 2
  fi
  errfile="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-lsof-err.XXXXXX" 2>/dev/null)" || return 2
  out="$(timeout 10 lsof +D "$dir" 2>"$errfile")"
  rc=$?
  err=""
  [ -s "$errfile" ] && err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile" 2>/dev/null
  if [ "$rc" -eq 124 ]; then
    return 2
  fi
  if [ -n "$out" ]; then
    return 0
  fi
  if [ -n "$err" ]; then
    return 2
  fi
  return 1
}

# _code_sign_clone_dir_in_use <dir> → tristate liveness check, SAME
# 0=in-use/1=confirmed-orphaned/2=unknown contract as _go_build_dir_in_use,
# but deliberately NOT implemented as `lsof +D <dir>` the way that one is —
# doing so was tried first and shipped, then found live to be a permanent
# false-positive (ga-nkqook): every code_sign_clone.<token> generation's
# "Google Chrome" binary shares the IDENTICAL device+inode (confirmed via
# `stat -f %i` on two different, independently-timestamped clone dirs — both
# returned inode 1051924544 on this host), because macOS pins the SAME
# validated bytes across launches rather than copying them (this is also why
# `du` overcounts these dirs so badly — see this bead). `lsof +D` resolves
# matches by (device, inode), so it reports EVERY historical clone as
# "in use" for as long as ANY Chrome process anywhere is alive — which, under
# a KeepAlive LaunchAgent, is always. Shipped-and-measured: with +D, a live
# run against 62 real clones (some hours old, all from long-dead processes)
# spared all 62 (freed=0MB) — a silent, permanent no-op in exactly the
# crash-loop scenario this lever exists for.
#
# Fix: never trust lsof's own directory-argument resolution for this file
# family. Dump every process's real open-file NAME strings with no directory
# filter (lsof -Fn) and do the prefix match ourselves in bash — the NAME
# field itself is the literal path a process opened (confirmed live: a
# per-PID `lsof -p <pid> -Fn` for the one truly-live Chrome showed exactly
# one code_sign_clone path, the current one), so string-matching it sidesteps
# whatever inode-collapsing shortcut +D takes internally. Same content-based
# (not exit-code-based) rc=124/stderr/stdout handling as _go_build_dir_in_use
# — see its header for that part of the rationale.
#
# [snapshot] (optional): path to an lsof-Fn capture ALREADY TAKEN by the
# caller. When given, this function trusts it completely and does no lsof
# call of its own — required for _reap_code_sign_clone_orphans below, which
# must judge every candidate against the SAME instant (see that function's
# header: with 60+ candidates and each fresh `lsof -Fn` costing real wall
# time, checking each one separately raced the crash loop itself — measured
# live, a 62-candidate loop with a fresh lsof per dir took ~19s, long enough
# for the truly-live dir's OWN process to crash and be replaced mid-scan,
# reading the live dir as orphaned. Never actually unsafe here, since a dir
# that fresh is always well under the grace window regardless — but wrong
# in the log and needlessly slow). Omitted (the selftest's standalone calls):
# runs lsof itself, same as before.
_code_sign_clone_dir_in_use() {
  local dir="$1" snapshot="${2:-}" out rc errfile outfile owns_outfile=0
  # Always defined before the final [ -n "$err" ] check below — the
  # snapshot-provided branch never touches it (there's no fresh stderr to
  # read, the caller already validated the capture), so leaving it purely
  # bare-declared would read as an unbound variable on that path under this
  # script's `set -u` (caught live while wiring this in: the go-build sibling
  # this was copied from never hits its own final err-check without first
  # unconditionally assigning err="", since it only has the one code path).
  local err=""
  if [ -n "$snapshot" ]; then
    [ -f "$snapshot" ] || return 2
    outfile="$snapshot"
  else
    if ! command -v lsof >/dev/null 2>&1; then
      return 2
    fi
    errfile="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-lsof-err.XXXXXX" 2>/dev/null)" || return 2
    outfile="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-lsof-out.XXXXXX" 2>/dev/null)" || { rm -f "$errfile"; return 2; }
    owns_outfile=1
    timeout 10 lsof -Fn >"$outfile" 2>"$errfile"
    rc=$?
    [ -s "$errfile" ] && err="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile" 2>/dev/null
    if [ "$rc" -eq 124 ]; then
      rm -f "$outfile" 2>/dev/null
      return 2
    fi
  fi
  # -F's NAME lines are prefixed "n"; grep the literal (-F) directory prefix
  # with a trailing slash so a dir whose random suffix happens to prefix
  # another dir's name (e.g. code_sign_clone.AB vs code_sign_clone.ABC)
  # can never cross-match.
  out="$(grep -F -- "${dir}/" "$outfile" 2>/dev/null)"
  [ "$owns_outfile" = "1" ] && rm -f "$outfile" 2>/dev/null
  if [ -n "$out" ]; then
    return 0
  fi
  if [ -n "$err" ]; then
    return 2
  fi
  return 1
}

# _should_reap_go_build_dir <in_use_rc> <age_secs> <grace_secs> → 0 (true)
# only when in_use_rc=1 (CONFIRMED orphaned by _go_build_dir_in_use — rc=0
# in-use and rc=2 unknown must NEVER reap) AND age_secs >= grace_secs
# (ga-ilmjgo item 2: grace window for a build that just created the dir).
# Non-numeric/empty age or grace fails CLOSED — never guess an age to
# justify deleting, same asymmetry _should_reap_gocache's own empty-cache_gb
# handling already documents for this file.
_should_reap_go_build_dir() {
  local in_use_rc="$1" age_secs="$2" grace_secs="$3"
  [ "$in_use_rc" -eq 1 ] || return 1
  case "$age_secs" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace_secs" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age_secs" -ge "$grace_secs" ]
}

# _should_reap_code_sign_clone_dir <in_use_rc> <age_secs> <grace_secs> →
# identical contract to _should_reap_go_build_dir (ga-nkqook): reap ONLY when
# CONFIRMED orphaned (rc=1) AND past the mtime grace window; rc=0 (in use) and
# rc=2 (unknown) never reap, non-numeric/empty age or grace fails CLOSED.
_should_reap_code_sign_clone_dir() {
  local in_use_rc="$1" age_secs="$2" grace_secs="$3"
  [ "$in_use_rc" -eq 1 ] || return 1
  case "$age_secs" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace_secs" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age_secs" -ge "$grace_secs" ]
}

# _should_reap_bash_edit_diff_dir <age_secs> <grace_secs> → 0 (true) only when
# age_secs >= grace_secs. Age-ONLY — see BASH_EDIT_DIFF_ORPHAN_GRACE_SECS's own
# comment for why no liveness check exists for this lever (no PID/session
# correlation to check against, unlike the two _should_reap_*_dir functions
# above). Non-numeric/empty age or grace fails CLOSED — same never-guess-to-
# justify-deleting discipline as every other _should_reap_* function here.
_should_reap_bash_edit_diff_dir() {
  local age_secs="$1" grace_secs="$2"
  case "$age_secs" in ''|*[!0-9]*) return 1 ;; esac
  case "$grace_secs" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age_secs" -ge "$grace_secs" ]
}

# _top_disk_consumers [n] → the N largest immediate entries across a fixed,
# bounded set of scratch/cache roots this guard already knows about (one
# level deep each) — printed as "MB path", largest first. Companion to
# _top_mem_processes above, same rationale (ga-ofi307, invariant b of that
# bead): this guard's other reclaim levers each only ever look at the ONE
# specific directory shape they were written for, so a genuinely NEW consumer
# (like the bash-edit-diff cache before this bead — 3.5GB, larger than every
# Dolt database in the city combined, sitting in a directory none of the
# other levers ever looked at) stays invisible until a human runs `du` by
# hand to find it, exactly what happened the night this bead was filed. This
# does NOT replace a lever with real reclaim logic of its own — a genuinely
# new consumer still needs one written for it, same as bash-edit-diff got
# here — it exists so the NEXT unknown consumer shows up in this guard's own
# alert BEFORE a human has to go looking, by measuring one level into the
# SAME parent directories the levers above already resolve (the bash-edit-
# diff parent, the go-build tmp root, the code-sign-clone parent, GOCACHE's
# parent, and $CITY/.dolt-backup) — the bash-edit-diff parent in particular
# is the exact directory that hid this incident's own consumer ("ficam num
# diretorio irmao" — see this file's own header).
#
# Deliberately NOT a whole-filesystem walk (never `find /`, `find ~`, or a
# recursive scan from `/`) — every root here is one this guard (or a reaper
# it already shells out to) already touches, so this stays a handful of
# bounded, ONE-LEVEL scans, never a scan of TCC-protected user directories
# (Desktop/Documents/Downloads/iCloud/network mounts).
#
# ONE `du -sk` PER ENTRY, NOT ONE PER ROOT: an earlier version of this
# function looped calling _dir_size_mb (its own `du -sk` process) per
# immediate entry — measured LIVE against this guard's own
# DARWIN_USER_TEMP_DIR (_go_build_tmp_root): ~20,000 entries, 100s+ wall time
# from pure fork/exec overhead alone, an unacceptable cost for something that
# runs on every alert. The opposite extreme — one single `du -sk "$dir"/*`
# call passing every entry as an argv — measured WORSE: "argument list too
# long" (ARG_MAX) on that same ~20,000-entry root, a hard failure, not just
# slow. `find -maxdepth 1 -mindepth 1 -print0 | xargs -0 du -sk` is the
# correct middle ground: xargs chunks the argv itself to stay under ARG_MAX
# while still batching far fewer `du` process spawns than one-per-entry —
# measured on the SAME 20,000-entry root: ~4s (and correctly surfaced an
# 812MB outlier). timeout-bounded per root (20s — comfortably above the
# slowest root measured live, ~/Library/Caches at ~15s) so one unusually
# large or deep root can't stall the others; a partial result across the
# remaining roots is far better than none (ga-p5q3 "couldn't finish" is not
# "couldn't measure" — a bounded partial scan still reports what it saw).
#
# Best-effort, same empty-means-unmeasured contract as _top_mem_processes: a
# root that doesn't resolve, doesn't exist, or times out is silently skipped,
# never fabricated as a zero-size entry. Not gated by ENABLED — this is a
# read, not a reclaim action, same precedent as _vm_swap_gb/_top_mem_processes
# above.
_top_disk_consumers() {
  local n="${1:-8}"
  local roots="" r
  r="$(_bash_edit_diff_root)";  [ -n "$r" ] && [ -d "$(dirname "$r")" ] && roots="${roots}$(dirname "$r")"$'\n'
  r="$(_go_build_tmp_root)";    [ -n "$r" ] && [ -d "$r" ]              && roots="${roots}${r}"$'\n'
  r="$(_code_sign_clone_root)"; [ -n "$r" ] && [ -d "$(dirname "$r")" ] && roots="${roots}$(dirname "$r")"$'\n'
  r="$(_gocache_dir)";          [ -n "$r" ] && [ -d "$(dirname "$r")" ] && roots="${roots}$(dirname "$r")"$'\n'
  [ -d "$CITY/.dolt-backup" ] && roots="${roots}${CITY}/.dolt-backup"$'\n'
  [ -z "$roots" ] && { echo ""; return; }

  local out="" dir kb path
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    while IFS=$'\t' read -r kb path; do
      case "$kb" in ''|*[!0-9]*) continue ;; esac
      out="${out}$(( kb / 1024 )) ${path}"$'\n'
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -print0 2>/dev/null | timeout 20 xargs -0 du -sk 2>/dev/null)
  done <<< "$roots"

  [ -z "$out" ] && { echo ""; return; }
  printf '%s' "$out" | sort -rn | head -n "$n"
}

# ── ga-ond0fa: DISK-GROWTH PHOTO ────────────────────────────────────────────────
# WHY: 2026-09-25 free space fell ~10GB -> 5GB (01:30) -> 3GB (01:51-02:09,
# CRITICAL for 3 cycles, Dolt at the ENOSPC floor that killed it 24/09 13:02) and
# came back to 10GB at 02:16 with no author: this guard logged only "avail=" and
# the reclaim levers found nothing, so ~7GB of writes in 45min stayed anonymous.
# _top_disk_consumers above answers "what is BIG" across a few scratch roots; it
# cannot answer "what GREW", which is the question an unexplained dive poses.
#
# HOW: a photo is one-level `du -sk` under a fixed set of roots (_growth_roots).
# A BASELINE photo is refreshed (rate-limited) on class=NONE cycles — the "last
# OK" one; the first WARN cycle and the first CRITICAL cycle of an episode each
# take a fresh photo BEFORE the reclaim levers run and diff it against that
# baseline. The result lands in $STATE_DIR/disk-growth-<ts>.txt, its top growers
# in the log and in the Mayor CRITICAL mail. Read-only throughout: nothing is
# deleted or stopped, and only this guard's own state dir is written.
#
# PHOTO FILE FORMAT (tab-separated; '#' lines are commentary and ignored by the
# parser, which is what lets the human report be appended to the same file):
#   TS <epoch>   AVAIL_GB <n>   VM_SWAP <sysctl text>   VM_DIR_KB <n|unknown>
#   ROOT <STATUS> <root>        — STATUS: OK | PARTIAL | MISSING | SYMLINK | SKIPPED
#   ENT <kb> <path>             — immediate child of the ROOT line above it
#   WRITERS <ok|unmeasured>     WRITER <mb> <pid> <command> <path>
# "Unmeasured" is always a STATUS or an absent line, never a 0: a root that timed
# out keeps the rows that finished and says PARTIAL; one the budget never reached
# says SKIPPED; the diff refuses to call an entry "new" or "grown" on the strength
# of a root that was not completely measured on both sides (ga-p5q3: "could not
# measure" must never read as "did not grow").

# _growth_baseline_file / _growth_episode_file → state paths, resolved from
# $STATE_DIR at call time (see the config block for why).
_growth_baseline_file() { echo "$STATE_DIR/.dolt-disk-floor-guard.growth-baseline"; }
_growth_episode_file()  { echo "$STATE_DIR/.dolt-disk-floor-guard.growth-episode"; }

# _growth_roots → the roots to photograph, one per line, cheap ones first so a
# spent budget skips the slowest (Library/Caches) rather than the dolt data-dir.
# Every root is a directory this guard's own reapers or the bead's list already
# name — never a walk from / or ~ (TCC-protected Desktop/Documents/iCloud/
# CloudStorage stay untouched, same rule as _top_disk_consumers above). Deduped
# so a root shared with another lever is measured once.
_growth_roots() {
  local town t d
  town="$(dirname "$CITY")"
  t="$(_go_build_tmp_root)"
  {
    echo "$DOLTDIR"                                # one entry per Dolt database
    echo "$CITY/.dolt-backup"
    echo "$HOME/shared/data"
    echo "/private/tmp/claude-$(id -u 2>/dev/null)"
    echo "/private/tmp"
    if [ -n "$t" ]; then
      echo "$t"                                    # DARWIN_USER_TEMP_DIR: go-build orphans
      echo "$(dirname "$t")/X"                     # code_sign_clone parent
    fi
    echo "$HOME/.claude/projects"
    echo "$CITY/.gc-worktrees"
    echo "$town/.gc-worktrees"
    echo "$town/.claude/worktrees"
    for d in "$town"/*/.gc-worktrees; do [ -e "$d" ] && echo "$d"; done
    echo "$HOME/Library/Caches"                    # slowest (~91s at load 47); GOCACHE lives here
  } | awk 'NF && !seen[$0]++'
}

# _growth_scan_root <root> <timeout_secs> → "ROOT<TAB>STATUS<TAB>root" then one
# "ENT<TAB>kb<TAB>path" per immediate child. Chunked + parallel (`xargs -n 4 -P 3`),
# NOT one big `du -sk`: du block-buffers its stdout to a pipe, so a timeout-killed
# single du yields ZERO rows (measured 2026-09-25: ~/Library/Caches hit a 90s
# bound and returned nothing), whereas chunks that already finished have already
# flushed and survive the kill. Chunks of 4 keep each du's output under PIPE_BUF
# (512B on macOS) so two parallel dus cannot interleave mid-line. Symlinked roots
# are never descended (a symlink into CloudStorage/FUSE could hang the scan).
_growth_scan_root() {
  local root="$1" tmo="$2" tmpf xrc status
  if [ -L "$root" ]; then printf 'ROOT\tSYMLINK\t%s\n' "$root"; return 0; fi
  if [ ! -d "$root" ]; then printf 'ROOT\tMISSING\t%s\n' "$root"; return 0; fi
  tmpf="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-growth.XXXXXX" 2>/dev/null)" \
    || { printf 'ROOT\tPARTIAL\t%s\n' "$root"; return 0; }
  find "$root" -maxdepth 1 -mindepth 1 -print0 2>/dev/null \
    | timeout "$tmo" nice -n 10 xargs -0 -n 4 -P 3 du -sk > "$tmpf" 2>/dev/null
  xrc="${PIPESTATUS[1]}"
  # A du chunk that hit a permission error or a vanished child exits nonzero — the
  # routine case here (TCC-protected subdirs under ~/Library/Caches, entries
  # deleted mid-scan under /private/tmp) — and the rows it printed are still
  # valid. What xargs reports for that depends on WHICH xargs: macOS's BSD xargs
  # exits 1 (MEASURED 2026-09-25: 1 for T, /private/tmp and ~/shared/data; a first
  # draft treated only GNU's 123 as routine and marked nearly every root PARTIAL,
  # which would have suppressed every "new" claim in the diff), GNU xargs 123. 124
  # is timeout's own "bound hit"; anything else (126/127 cannot exec, 137/143
  # killed) means rows may be missing. Those are PARTIAL — never OK.
  case "$xrc" in 0|1|123) status="OK" ;; *) status="PARTIAL" ;; esac
  printf 'ROOT\t%s\t%s\n' "$status" "$root"
  # Only well-formed "<kb><TAB>/abs/path" rows survive; anything else (a
  # truncated line, a path with a newline) is dropped rather than guessed at.
  awk -F'\t' '$1 ~ /^[0-9]+$/ && substr($2,1,1) == "/" { printf "ENT\t%s\t%s\n", $1, $2 }' "$tmpf"
  rm -f "$tmpf" 2>/dev/null
  return 0
}

# _lsof_writers_parse <min_mb> → stdin: `lsof -F pcaftsn` output. Prints
# "mb<TAB>pid<TAB>command<TAB>path" for every REGULAR file held open for WRITE
# ('w' or 'u') that is >= min_mb, largest first, one row per (pid, path) — a
# process holding the same file on 6 fds (measured live: Google Drive's
# metadata_sqlite_db) is one row, not six. A record ends at the next `f`/`p`
# line or EOF, never at `n`: lsof's field order within a record is not something
# to lean on.
_lsof_writers_parse() {
  local min_mb="${1:-100}"
  awk -v min="$min_mb" '
    function flush() {
      if (have && (a == "w" || a == "u") && t == "REG" && s + 0 >= min * 1048576) {
        key = pid SUBSEP n
        if (!(key in seen)) { seen[key] = 1; printf "%d\t%s\t%s\t%s\n", s / 1048576, pid, cmd, n }
      }
      have = 0
    }
    /^p/ { flush(); pid = substr($0, 2); next }
    /^c/ { cmd = substr($0, 2); next }
    /^f/ { flush(); have = 1; a = ""; t = ""; s = ""; n = ""; next }
    /^a/ { a = substr($0, 2); next }
    /^t/ { t = substr($0, 2); next }
    /^s/ { s = substr($0, 2); next }
    /^n/ { n = substr($0, 2); next }
    END { flush() }
  ' | sort -t"$(printf '\t')" -k1,1nr
}

# _top_open_write_files [n] [min_mb] → tri-state, like _go_build_dir_in_use:
# rc 0 = lsof ran; stdout = up to n rows (possibly none — a real "nothing that
# big is open for write"); rc 2 = could not measure (no lsof, timed out, or it
# reported an error and printed nothing) — which must never be read as rc 0's
# empty. This is a PROXY for "top writers": macOS exposes no per-process
# bytes-written counter without root (powermetrics/fs_usage need it), so this
# shows who is HOLDING the biggest files open for write right now — it caught a
# 2.1GB fileproviderd database no scan root covers — not who wrote the most
# recently. Label it as such wherever it is shown. ~3s measured at load 47.
_top_open_write_files() {
  local n="${1:-10}" min_mb="${2:-$GROWTH_WRITER_MIN_MB}" raw rc
  command -v lsof >/dev/null 2>&1 || return 2
  raw="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-lsofw.XXXXXX" 2>/dev/null)" || return 2
  timeout 30 nice -n 10 lsof -nP -w -F pcaftsn > "$raw" 2>/dev/null
  rc=$?
  # A live machine always has open files, so an EMPTY capture means lsof failed
  # (or was killed at the 30s bound, rc 124) — never "nothing is open". A
  # non-empty capture from an lsof that exited nonzero is still valid rows (it
  # skips what it cannot stat).
  if [ "$rc" -eq 124 ] || [ ! -s "$raw" ]; then
    rm -f "$raw" 2>/dev/null
    return 2
  fi
  _lsof_writers_parse "$min_mb" < "$raw" | head -n "$n"
  rm -f "$raw" 2>/dev/null
  return 0
}

# _disk_growth_photo <outfile> [writers] [budget_secs] → reads the roots (one per
# line) from STDIN and writes the photo (format above) to <outfile>, atomically
# (tmp + mv, so a reader never sees half a photo). Pass "writers" to also record
# the open-for-write proxy (~3s; both the baseline and the episode photo do, so
# the diff can show which held-open file GREW and which pid holds it). rc 0 =
# <outfile> written; rc 1 = it could not be written. The root scan is bounded by
# budget_secs (default GROWTH_TOTAL_BUDGET_SECS): each root's own timeout is
# clamped to what is left, and once nothing is left every remaining root is
# recorded SKIPPED — so the scan, not just its start, stays inside the budget.
# The VM du (<=20s) and the writers lsof (<=30s) sit outside it. Read-only apart
# from <outfile>.
_disk_growth_photo() {
  local out="$1" want_writers="${2:-}" budget="${3:-$GROWTH_TOTAL_BUDGET_SECS}" roots root start="$SECONDS" tmp vm_kb rows wrc left tmo
  roots="$(cat)"
  tmp="${out}.tmp.$$"
  vm_kb="$(timeout 20 du -sk /System/Volumes/VM 2>/dev/null | awk '{print $1}')"
  case "$vm_kb" in ''|*[!0-9]*) vm_kb="unknown" ;; esac
  {
    printf '# dolt-disk-floor-guard disk-growth photo (ga-ond0fa) — read-only; sizes in KB (du -sk), one level under each ROOT\n'
    printf 'TS\t%s\n' "$(date +%s)"
    printf 'AVAIL_GB\t%s\n' "$(_avail_gb "$DOLTDIR")"
    printf 'VM_SWAP\t%s\n' "$(sysctl -n vm.swapusage 2>/dev/null | tr '\t\n' '  ')"
    printf 'VM_DIR_KB\t%s\n' "$vm_kb"
    while IFS= read -r root; do
      [ -z "$root" ] && continue
      left=$(( budget - (SECONDS - start) ))
      if [ "$left" -le 0 ]; then
        printf 'ROOT\tSKIPPED\t%s\n' "$root"
        continue
      fi
      tmo="$GROWTH_ROOT_TIMEOUT_SECS"
      [ "$left" -lt "$tmo" ] && tmo="$left"
      _growth_scan_root "$root" "$tmo"
    done <<< "$roots"
    if [ "$want_writers" = "writers" ]; then
      rows="$(_top_open_write_files 10 "$GROWTH_WRITER_MIN_MB")"; wrc=$?
      if [ "$wrc" -eq 0 ]; then
        printf 'WRITERS\tok\n'
        [ -n "$rows" ] && printf '%s\n' "$rows" | awk -F'\t' '{ printf "WRITER\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }'
      else
        printf 'WRITERS\tunmeasured\n'
      fi
    fi
  } 2>/dev/null > "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# _growth_delta <baseline> <now> [n] [min_mb] → what GREW between two photos.
# Output, tab-separated, one record per line:
#   G <delta_mb> <now_mb> <was_mb|new> <path>   — grew by >= min_mb, largest first, top n
#   W <delta_mb> <now_mb> <was_mb|absent> <pid> <command> <path>
#                                               — a file held open for WRITE that grew by >= min_mb
#                                                 (or was not in the baseline's list), top n; only
#                                                 when BOTH photos measured writers. This is the
#                                                 nearest thing macOS gives to "which process wrote
#                                                 it": the growing file plus who holds it open.
#   V <delta_mb> <now_mb> <was_mb>              — /System/Volumes/VM residency, when both known
#   U <root> <reason>                           — a root that could NOT be fully compared
# Only entries present in BOTH photos are compared, plus "new" entries — and
# "new" is claimed only when the baseline scan of that root was OK (complete): an
# entry absent from a PARTIAL/SKIPPED baseline root is "not measured then", not
# "did not exist". A root that is not OK on either side is reported as U (with
# the reason) so a dive hiding in it reads as "unmeasured", never as "nothing
# grew". Empty output means no growth >= min_mb AND nothing uncomparable.
# Reads two files, writes nothing.
_growth_delta() {
  local base="$1" now="$2" n="${3:-8}" min_mb="${4:-$GROWTH_MIN_DELTA_MB}" rows
  [ -s "$base" ] && [ -s "$now" ] || return 0
  rows="$(awk -F'\t' -v min_kb="$(( min_mb * 1024 ))" -v min_mb="$min_mb" '
    FNR == 1 { fileno++ }
    $1 == "ROOT" { root = $3; st[fileno SUBSEP root] = $2; if (!(root in roots)) { roots[root] = 1; order[++nr] = root }; next }
    $1 == "ENT"  { kb[fileno SUBSEP root SUBSEP $3] = $2; if (fileno == 2) { nowkeys[++nn] = root SUBSEP $3 }; next }
    $1 == "VM_DIR_KB" { vm[fileno] = $2; next }
    $1 == "WRITERS" { wst[fileno] = $2; next }
    $1 == "WRITER" {
      if (fileno == 1) { if (!($5 in wbase) || $2 + 0 > wbase[$5] + 0) wbase[$5] = $2 }
      else { wn++; wmb[wn] = $2; wpid[wn] = $3; wcmd[wn] = $4; wpath[wn] = $5 }
      next
    }
    END {
      for (i = 1; i <= nn; i++) {
        key = nowkeys[i]; split(key, kp, SUBSEP); r = kp[1]; p = kp[2]
        if (st[1 SUBSEP r] == "" || st[2 SUBSEP r] == "") continue        # root not in both photos
        cur = kb[2 SUBSEP key]
        if ((1 SUBSEP key) in kb) { was = kb[1 SUBSEP key]; wtxt = int(was / 1024) }
        else if (st[1 SUBSEP r] == "OK") { was = 0; wtxt = "new" }
        else continue                                                      # absent from an incomplete baseline
        d = cur - was
        if (d > 0 && d >= min_kb) printf "G\t%d\t%d\t%s\t%s\n", int(d / 1024), int(cur / 1024), wtxt, p
      }
      for (i = 1; i <= nr; i++) {
        r = order[i]; b = st[1 SUBSEP r]; c = st[2 SUBSEP r]
        if (b == "" && c == "") continue
        if (b != "OK" || c != "OK") printf "U\t%s\tbaseline=%s now=%s\n", r, (b == "" ? "absent" : b), (c == "" ? "absent" : c)
      }
      if (wst[1] == "ok" && wst[2] == "ok") {
        for (i = 1; i <= wn; i++) {
          p = wpath[i]
          if (p in wdone) continue
          wdone[p] = 1
          if (p in wbase) { was = wbase[p] + 0; wtxt = wbase[p] } else { was = 0; wtxt = "absent" }
          d = wmb[i] - was
          if (d > 0 && d >= min_mb) printf "W\t%d\t%d\t%s\t%s\t%s\t%s\n", d, wmb[i], wtxt, wpid[i], wcmd[i], p
        }
      }
      if (vm[1] ~ /^[0-9]+$/ && vm[2] ~ /^[0-9]+$/) printf "V\t%d\t%d\t%d\n", int((vm[2] - vm[1]) / 1024), int(vm[2] / 1024), int(vm[1] / 1024)
    }
  ' "$base" "$now")"
  [ -z "$rows" ] && return 0
  printf '%s\n' "$rows" | awk -F'\t' '$1 == "G"' | sort -t"$(printf '\t')" -k2,2nr | head -n "$n"
  printf '%s\n' "$rows" | awk -F'\t' '$1 == "W"' | sort -t"$(printf '\t')" -k2,2nr | head -n "$n"
  printf '%s\n' "$rows" | awk -F'\t' '$1 == "V" || $1 == "U"'
}

# _growth_report <baseline> <now> → the human text for a finished photo. With a
# baseline: the growers (or an explicit "nothing >= N MB grew in the comparable
# roots"), the VM delta, and every root that could not be compared. Without one
# (the guard has not yet seen an OK cycle): says so and falls back to the biggest
# entries by absolute size, which is still more than "avail=" ever gave.
_growth_report() {
  local base="$1" now="$2" delta bts nts age g w v u
  nts="$(awk -F'\t' '$1 == "TS" { print $2; exit }' "$now" 2>/dev/null)"
  if [ ! -s "$base" ]; then
    echo "No baseline photo yet (this guard has not completed an OK cycle since the baseline was introduced) — cannot compute growth."
    echo "Largest entries by absolute size in this photo (MB path):"
    awk -F'\t' '$1 == "ENT" { printf "%d\t%s\n", $2 / 1024, $3 }' "$now" | sort -t"$(printf '\t')" -k1,1nr | head -n "$GROWTH_TOP_N" | awk -F'\t' '{ printf "  %s %s\n", $1, $2 }'
    return 0
  fi
  bts="$(awk -F'\t' '$1 == "TS" { print $2; exit }' "$base" 2>/dev/null)"
  age="unknown age"
  case "$bts" in ''|*[!0-9]*) ;; *)
    case "$nts" in ''|*[!0-9]*) ;; *) age="$(( (nts - bts) / 60 )) min old" ;; esac
  esac
  echo "Growth since the last OK photo (${age}; entries that grew >= ${GROWTH_MIN_DELTA_MB}MB, MB path):"
  delta="$(_growth_delta "$base" "$now" "$GROWTH_TOP_N" "$GROWTH_MIN_DELTA_MB")"
  g="$(printf '%s\n' "$delta" | awk -F'\t' '$1 == "G" { printf "  +%sMB  %s  (now %sMB, was %s%s)\n", $2, $5, $3, $4, ($4 == "new" ? "" : "MB") }')"
  if [ -n "$g" ]; then printf '%s\n' "$g"; else echo "  (none in the roots that could be compared — the growth is outside them, in VM, or in an unmeasured root below)"; fi
  w="$(printf '%s\n' "$delta" | awk -F'\t' '$1 == "W" { printf "  +%sMB  pid=%s %s  %s  (now %sMB, was %s)\n", $2, $5, $6, $7, $3, ($4 == "absent" ? "not in the baseline open-for-write list" : $4 "MB") }')"
  if [ -n "$w" ]; then
    echo "Files held open for WRITE that grew (or appeared) since the baseline — the process holding one is the prime suspect:"
    printf '%s\n' "$w"
  fi
  v="$(printf '%s\n' "$delta" | awk -F'\t' '$1 == "V" { printf "  /System/Volumes/VM: %sMB now, %+dMB vs baseline (%sMB)\n", $3, $2, $4 }')"
  [ -n "$v" ] && printf '%s\n' "$v"
  u="$(printf '%s\n' "$delta" | awk -F'\t' '$1 == "U" { printf "  NOT FULLY COMPARED: %s (%s)\n", $2, $3 }')"
  [ -n "$u" ] && printf '%s\n' "$u"
  return 0
}

# _growth_baseline_due <baseline_file> <now> <interval_secs> → 0 when a baseline
# refresh is due: no baseline, an unreadable/garbled TS, a TS in the FUTURE (clock
# step — a baseline that looks younger than zero must not freeze refreshing), or
# the interval elapsed. Fail-open on purpose: the cost of a wrongly-taken photo is
# one rate-limited scan, the cost of a wrongly-suppressed one is a diff against
# nothing at the exact moment it is needed.
_growth_baseline_due() {
  local f="$1" now="$2" interval="$3" ts_
  ts_="$([ -s "$f" ] && awk -F'\t' '$1 == "TS" { print $2; exit }' "$f" 2>/dev/null)"
  case "$ts_" in ''|*[!0-9]*) return 0 ;; esac
  [ "$ts_" -gt "$now" ] && return 0
  [ $(( now - ts_ )) -ge "$interval" ]
}

# _growth_should_photo <episode_level> <class> → 0 when this cycle earns an
# episode photo: episode_level is the HIGHEST class already photographed this
# episode ('' none | WARN | CRITICAL), class is this cycle's pre-reclaim class.
# So: the first WARN cycle photographs; the first CRITICAL cycle photographs
# again (a fill that started at WARN is usually worse by the time it is
# CRITICAL); every later cycle of the same or lower level does not. Any other
# class (NONE/UNKNOWN never reach here, but stay safe in isolation) never does.
_growth_should_photo() {
  local level="$1" class="$2" have want
  case "$level" in CRITICAL) have=2 ;; WARN) have=1 ;; *) have=0 ;; esac
  case "$class" in CRITICAL) want=2 ;; WARN) want=1 ;; *) return 1 ;; esac
  [ "$want" -gt "$have" ]
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

# _read_last_mail_state / _write_last_mail_state / _clear_last_mail_state
# (ga-4f4opx) — persist when the Mayor was last actually MAILED for a
# CRITICAL episode and at what avail, mirroring _read_state/_write_state's
# own global-side-effect shape above but on a SEPARATE state track (see
# CRITICAL_MAIL_COOLDOWN_SECS's own comment for why this must never share
# the WARN-tier notify cooldown files). Missing state reads as empty (never
# mailed yet this episode), which _should_mail_critical's own
# _cooldown_elapsed call already treats as fail-open (mail).
_read_last_mail_state() {
  _LAST_MAIL_EPOCH=""; _LAST_MAIL_AVAIL=""
  [ -f "$STATE_LAST_MAIL_EPOCH_FILE" ] && _LAST_MAIL_EPOCH="$(cat "$STATE_LAST_MAIL_EPOCH_FILE" 2>/dev/null)"
  [ -f "$STATE_LAST_MAIL_AVAIL_FILE" ] && _LAST_MAIL_AVAIL="$(cat "$STATE_LAST_MAIL_AVAIL_FILE" 2>/dev/null)"
}

_write_last_mail_state() {
  local epoch="$1" avail="$2"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$epoch" > "$STATE_LAST_MAIL_EPOCH_FILE" 2>/dev/null || true
  echo "$avail" > "$STATE_LAST_MAIL_AVAIL_FILE" 2>/dev/null || true
}

_clear_last_mail_state() {
  rm -f "$STATE_LAST_MAIL_EPOCH_FILE" "$STATE_LAST_MAIL_AVAIL_FILE" 2>/dev/null || true
}

# _read_critical_episode_mailed / _write_critical_episode_mailed (ga-4f4opx) —
# same shape/fail-direction as _read_critical_sustain/_write_critical_sustain
# above (missing/corrupt state reads as "0" — no episode mail sent — never as
# "1", since a corrupt flag must not fabricate a recovery mail for an episode
# the Mayor was never actually told about).
_read_critical_episode_mailed() {
  local f="$STATE_CRITICAL_EPISODE_MAILED_FILE" v
  v="$([ -f "$f" ] && cat "$f" 2>/dev/null)"
  case "$v" in 1) echo 1 ;; *) echo 0 ;; esac
}

_write_critical_episode_mailed() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$1" > "$STATE_CRITICAL_EPISODE_MAILED_FILE" 2>/dev/null || true
}

# _maybe_mail_recovery <avail> <now> (ga-4f4opx) — sends ONE recovery mail to
# the Mayor the first non-CRITICAL cycle observed after this guard already
# mailed at least one CRITICAL alert this episode. No-op when no CRITICAL
# mail went out this episode — nothing for the Mayor to be told is over,
# same "don't alert on what nobody was told about" principle
# _sustain_confirmed's own gate already applies to the FIRST mail. Clears the
# mail-debounce state too, so the NEXT CRITICAL episode's first mail is
# unconditional again (fail-open via _should_mail_critical's own
# no-prior-record case), exactly like a brand-new episode — never carries a
# stale "last mailed at Xgb" comparison across a recovery gap. Never gated by
# ENABLED (same "notification is never gated by the reclaim kill switch"
# invariant this file's header already documents for NOTIFY/mail above).
_maybe_mail_recovery() {
  local avail="$1" now="$2"
  [ "$(_read_critical_episode_mailed)" = "1" ] || return 0
  local mail_body="dolt-disk-floor-guard: Dolt data-dir RECOVERED — avail is now ${avail}GB, back above the CRITICAL floor (${FLOOR_CRITICAL_GB}GB). This closes the CRITICAL episode reported by the earlier mail(s) above."
  "$GC" mail send mayor -s "Dolt disk-floor RECOVERED: avail=${avail}GB" -m "$mail_body" 2>/dev/null || log "WARN: gc mail send mayor (recovery) failed"
  _write_critical_episode_mailed 0
  _clear_last_mail_state
  log "CRITICAL episode recovered (avail=${avail}GB) — mailed Mayor recovery notice, cleared mail-debounce state"
}

# ── ga-ond0fa: disk-growth photo — execution side (design: see the DISK-GROWTH
# PHOTO block above _growth_roots). The episode file holds two lines: the highest
# class already photographed this episode (WARN|CRITICAL), then the path of the
# most recent photo — the second line is what lets a LATER cycle's Mayor mail cite
# the photo an EARLIER cycle took (each cycle is a separate process). Missing or
# garbled reads as "no photo yet", which errs toward one extra scan, never toward
# a suppressed one.
_growth_read_episode() {
  local f v; f="$(_growth_episode_file)"
  v="$([ -f "$f" ] && sed -n '1p' "$f" 2>/dev/null)"
  case "$v" in WARN|CRITICAL) echo "$v" ;; *) echo "" ;; esac
}

_growth_read_episode_photo() {
  local f; f="$(_growth_episode_file)"
  [ -f "$f" ] && sed -n '2p' "$f" 2>/dev/null
  return 0
}

_growth_write_episode() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n%s\n' "$1" "$2" > "$(_growth_episode_file)" 2>/dev/null || true
}

_growth_clear_episode() { rm -f "$(_growth_episode_file)" 2>/dev/null || true; }

# _growth_prune_photos → keep only the newest GROWTH_KEEP_PHOTOS photo files. Only
# this guard's own disk-growth-<stamp>.txt files are ever removed.
_growth_prune_photos() {
  ls -1 "$STATE_DIR"/disk-growth-[0-9]*.txt 2>/dev/null | sort -r | tail -n +"$(( GROWTH_KEEP_PHOTOS + 1 ))" \
    | while IFS= read -r _old_photo; do rm -f "$_old_photo" 2>/dev/null; done
  return 0
}

# _growth_writers_text <photo> → the WRITERS section of a photo as report lines.
# Says outright that this is a proxy (see _top_open_write_files) and keeps the
# three cases apart: measured-with-rows, measured-and-empty, unmeasured.
_growth_writers_text() {
  local f="$1" st
  st="$(awk -F'\t' '$1 == "WRITERS" { print $2; exit }' "$f" 2>/dev/null)"
  echo "Largest files held open for WRITE right now (proxy — macOS gives no per-process write counter without root; this is who HOLDS big files open, not who wrote most recently):"
  case "$st" in
    ok)
      if awk -F'\t' '$1 == "WRITER" { found = 1 } END { exit !found }' "$f" 2>/dev/null; then
        awk -F'\t' '$1 == "WRITER" { printf "  %sMB  pid=%s %s  %s\n", $2, $3, $4, $5 }' "$f"
      else
        echo "  (none >= ${GROWTH_WRITER_MIN_MB}MB)"
      fi ;;
    *) echo "  (unmeasured — lsof failed or timed out)" ;;
  esac
}

# _growth_baseline_refresh <now> → on a class=NONE cycle, refresh the "last OK"
# baseline photo if GROWTH_BASELINE_INTERVAL_SECS has passed. Never affects the
# guard's decisions: a failed scan only logs, and the previous baseline (the
# refresh is an atomic tmp+mv) stays in place.
_growth_baseline_refresh() {
  local now="$1" f t0 notok
  [ "$GROWTH_PHOTO_ENABLED" = "1" ] || return 0
  f="$(_growth_baseline_file)"
  _growth_baseline_due "$f" "$now" "$GROWTH_BASELINE_INTERVAL_SECS" || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  t0=$SECONDS
  if _growth_roots | _disk_growth_photo "$f" writers; then
    notok="$(awk -F'\t' '$1 == "ROOT" && $2 != "OK" && $2 != "MISSING" { printf "%s(%s) ", $3, $2 }' "$f" 2>/dev/null)"
    log "growth baseline photo refreshed ($(( SECONDS - t0 ))s; roots not fully measured: ${notok:-none}) (ga-ond0fa)"
  else
    log "WARN: growth baseline photo could not be written to ${f} — keeping the previous baseline (ga-ond0fa)"
  fi
  return 0
}

# _growth_episode_photo <class> <avail> → on the first WARN cycle and again
# on the first CRITICAL cycle of an episode (_growth_should_photo), photograph the
# growth roots and write $STATE_DIR/disk-growth-<stamp>.txt with the diff against
# the baseline. MUST be called BEFORE the reclaim levers: they delete scratch,
# caches and orphans, which are exactly the things a growth photo should still be
# able to see. The top growers are also logged. The episode is only marked as
# photographed once the file actually landed, so a failed write is retried.
_growth_episode_photo() {
  local class="$1" avail="$2" level stamp file base report t0 l budget
  [ "$GROWTH_PHOTO_ENABLED" = "1" ] || return 0
  level="$(_growth_read_episode)"
  _growth_should_photo "$level" "$class" || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  stamp="$(date '+%Y%m%d-%H%M%S')"
  file="$STATE_DIR/disk-growth-${stamp}.txt"
  base="$(_growth_baseline_file)"
  budget="$GROWTH_TOTAL_BUDGET_SECS"
  [ "$class" = "CRITICAL" ] && budget="$GROWTH_CRITICAL_BUDGET_SECS"
  log "disk-growth photo (ga-ond0fa): class=${class} avail=${avail}GB — photographing the growth roots BEFORE the reclaim levers run (scan budget ${budget}s)"
  t0=$SECONDS
  if ! _growth_roots | _disk_growth_photo "$file" writers "$budget"; then
    log "WARN: disk-growth photo could not be written to ${file} — will retry next cycle (ga-ond0fa)"
    return 0
  fi
  report="$(_growth_report "$base" "$file")"
  {
    echo "# ==== disk-growth report (ga-ond0fa) — class=${class} avail=${avail}GB at $(ts) ===="
    printf '%s\n' "$report" | sed 's/^/# /'
    _growth_writers_text "$file" | sed 's/^/# /'
  } >> "$file" 2>/dev/null
  log "disk-growth photo written: ${file} ($(( SECONDS - t0 ))s)"
  printf '%s\n' "$report" | while IFS= read -r l; do log "  $l"; done
  _growth_write_episode "$class" "$file"
  _growth_prune_photos
  return 0
}

# _growth_mail_text → the disk-growth paragraph for the Mayor CRITICAL mail: the
# photo THIS EPISODE took (which may be from an earlier cycle than the mail), or
# an explicit statement that there is none — never silence.
_growth_mail_text() {
  local pf; pf="$(_growth_read_episode_photo)"
  if [ -z "$pf" ] || [ ! -s "$pf" ]; then
    echo "  (no disk-growth photo recorded for this episode — DOLT_DISK_FLOOR_GROWTH_PHOTO_ENABLED=0, or the scan could not write its file; see ga-ond0fa)"
    return 0
  fi
  echo "  Photo file: ${pf}"
  awk '/^# ==== disk-growth report/ { on = 1; next } on && /^# / { sub(/^# /, "  "); print }' "$pf"
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
    # ga-ofi307: a command that exits 0 but frees literally nothing, while the
    # disk is STILL at/below the warn floor, is not "OK" — logging it that way
    # reads as calm success when it is the most misleading form of failure
    # (see this file's own header). "OK" stays reserved for a real gain, or
    # for avail already back above floor by the time this ran; zero-or-
    # negative gain while still at/below floor gets its own, explicitly
    # non-calm wording instead. main()'s post-reclaim diagnosis (ga-sfj3i.3)
    # is what actually escalates this across the whole cycle — this is just
    # the one per-lever line that must never read as calm success on its own.
    #
    # Same discipline extended to a THIRD case the original one-line version
    # of this log call already had, unchanged, before this bead: an
    # unmeasurable post-reclaim read (df itself failing right after a
    # successful dolt-cleanup) used to fall through to the exact same "OK"
    # text as a genuine large gain (`${after:-?}GB` silently printing "?GB"
    # while still saying "OK") — "don't know" collapsing into "good news",
    # the same family of bug this whole bead exists to fix, just one level
    # narrower. Caught during this bead's own pre-flight self-audit, not the
    # original incident — fixed here since the block was already being
    # rewritten.
    if [ -z "$after" ]; then
      log "reclaim: dolt-cleanup succeeded but post-reclaim avail is UNMEASURABLE (df failed) — effect unknown, not 'OK' (avail_before=${before}GB)"
    elif [ "$after" -le "$before" ] && [ "$after" -le "$FLOOR_WARN_GB" ]; then
      log "reclaim ZERO GAIN — avail ${before}GB -> ${after}GB, still at/below floor(${FLOOR_WARN_GB}GB): dolt-cleanup ran but freed nothing measurable — NOT relief, see diagnosis below"
    else
      log "reclaim OK — avail ${before}GB -> ${after}GB"
    fi
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

# _reap_gocache — sixth reclaim lever, alongside _safe_reclaim,
# _reap_dead_scratch, _reap_dead_transcripts, _reap_hf_cache and
# _reap_growing_logs (ga-yi68q): the Go build cache (GOCACHE, normally
# ~/Library/Caches/go-build) is not touched by any of the other five —
# MEASURED 2026-09-10 (Mayor): it grew from ~0 to 4.8GB in ~1h of `bd`
# builds/tests (bd embeds the whole Dolt engine — each build/test run
# generates GBs of compiled artifact), pushing this guard's own data-dir
# floor down to 1.2GB avail. `go clean -cache` recovered 5.5GB instantly
# (1210 -> 6729 MB). Inlined here (no delegate script/PROD-sentinel, unlike
# the four scratch/transcript/hf-cache/log levers above) because — like
# _safe_reclaim's `gc dolt-cleanup --force` — this is a single, blunt,
# idempotent-ish external command with no per-item staleness/liveness
# decision of its own to test in isolation; Go's own cache invalidation
# already decides what's safe to lose.
#
# Two-tier by design (_should_reap_gocache): at WARN, skip while a go
# build/test is actively running (killing/racing a live build's inputs out
# from under it is avoidable churn); at CRITICAL, reap regardless. `go
# clean -cache` may print "unlinkat ... directory not empty" when a
# concurrent build is still writing into the cache — harmless per this
# bead's own investigation, but NOT specially parsed out of the exit code
# here (this file never trusts message content over exit status elsewhere,
# e.g. the TIMEOUT-vs-FAILED split above) — a nonzero exit still logs
# FAILED, with this comment as the pointer for whoever reads that line.
_reap_gocache() {
  local was_critical="${1:-0}"
  if [ "$ENABLED" != "1" ]; then
    log "gocache-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if ! command -v go >/dev/null 2>&1; then
    log "gocache-reap SKIP — go binary not found on PATH"
    return
  fi
  local dir; dir="$(_gocache_dir)"
  if [ ! -d "$dir" ]; then
    log "gocache-reap SKIP — $dir not found"
    return
  fi
  local cache_gb go_active=0
  cache_gb="$(_gocache_size_gb "$dir")"
  _go_toolchain_active && go_active=1
  if ! _should_reap_gocache "$cache_gb" "$GOCACHE_REAP_THRESHOLD_GB" "$go_active" "$was_critical"; then
    log "gocache-reap SKIP — cache=${cache_gb:-unmeasured}GB threshold=${GOCACHE_REAP_THRESHOLD_GB}GB go_active=${go_active} was_critical=${was_critical}"
    return
  fi
  log "gocache-reap: cache=${cache_gb}GB >= ${GOCACHE_REAP_THRESHOLD_GB}GB (go_active=${go_active} was_critical=${was_critical}) — running 'go clean -cache' …"
  if timeout 60 go clean -cache >> "$LOG" 2>&1; then
    local after_gb; after_gb="$(_gocache_size_gb "$dir")"
    log "gocache-reap OK — cache ${cache_gb}GB -> ${after_gb:-?}GB"
  else
    log "gocache-reap FAILED (nonzero exit; may be the harmless 'directory not empty' race noted above — see log lines just above for the real message)"
  fi
}

# _reap_go_build_orphans [root] — seventh reclaim lever, alongside
# _safe_reclaim, _reap_dead_scratch, _reap_dead_transcripts, _reap_hf_cache,
# _reap_growing_logs and _reap_gocache (ga-ilmjgo): an interrupted `go
# build`/`go test` (Bash-tool timeout, SIGKILL, and — MEASURED 2026-09-15
# 03:06 — plain SIGINT too: `go test` exited in 0.0s and still left its work
# dir behind) leaves its work dir at
# $(getconf DARWIN_USER_TEMP_DIR)/go-build<N>, 0.5-2.5GB each, sitting in the
# same APFS container as Dolt's data-dir until a human clears it by hand
# (4th occurrence by 2026-09-15, 2.15GB the latest — see this file's own
# header). Independent leak class from _reap_gocache: GOCACHE is Go's
# persistent, REUSABLE build-artifact cache (wiping it just costs a
# recompile); a go-build<N> dir is a ONE-SHOT scratch workspace for a
# SPECIFIC invocation that already ended — once its owning process exits,
# nothing ever reuses that directory again, orphan or not. That is also why
# this lever has no gocache-style "skip while a build is active" WARN-tier
# trade-off of its own: a build's own IN-PROGRESS dir is excluded by the
# per-directory lsof liveness check below, not by a global go-active gate —
# so it runs at WARN same as CRITICAL (an orphan is never useful again, per
# this file's own header).
#
# Safety, per candidate directory (ga-ilmjgo items 2-3), both evaluated by
# the pure, unit-tested _should_reap_go_build_dir — this function only does
# the real directory walk, real `lsof`/`stat`/`du` calls, and the real `rm`:
#   1. _go_build_dir_in_use: lsof-confirmed no open file/cwd inside it. Its
#      rc=2 (unknown — lsof missing/timed out/errored) NEVER reaps that
#      directory this cycle (ga-p5q3: "couldn't see" != "nothing alive").
#   2. mtime age >= GO_BUILD_ORPHAN_GRACE_SECS (default 1800s/30min) — a
#      build that just created its dir gets a grace window.
# No global ENABLED-style ordering issue with a live build elsewhere: two
# concurrent `go build` invocations never share a go-build<N> dir (each gets
# its own mktemp'd name), so reaping one orphan can never disturb another,
# still-running build.
#
# Logs one line per candidate (name, MB, age, kept-or-deleted-and-why) —
# ga-ilmjgo item 4 — even when nothing qualifies, so a human reading the log
# can see what this lever considered, not just what it did. [root] overrides
# the resolved DARWIN_USER_TEMP_DIR for the selftest's hermetic fixture;
# production always calls this with no argument.
_reap_go_build_orphans() {
  local root="${1:-$(_go_build_tmp_root)}"
  if [ "$ENABLED" != "1" ]; then
    log "go-build-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    log "go-build-reap SKIP — DARWIN_USER_TEMP_DIR unresolved or missing (root='${root:-empty}')"
    return
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    log "go-build-reap SKIP — lsof not found on PATH (cannot confirm liveness; never guess)"
    return
  fi

  local now; now=$(date +%s)
  local dir base mb mtime age in_use_rc reason considered=0 freed_mb=0 unmeasured_deleted=0

  for dir in "$root"/go-build*; do
    [ -d "$dir" ] || continue
    considered=$((considered+1))
    base="$(basename "$dir")"
    mb="$(_dir_size_mb "$dir")"
    mtime="$(stat -f %m "$dir" 2>/dev/null)"
    if [ -z "$mtime" ]; then
      log "go-build-reap: ${base} (${mb:-unmeasured}MB) — SPARED (could not stat mtime; never guess age)"
      continue
    fi
    age=$(( now - mtime ))

    _go_build_dir_in_use "$dir"; in_use_rc=$?
    if [ "$in_use_rc" -eq 2 ]; then
      log "go-build-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — SPARED (lsof could not confirm liveness this cycle; never treat unknown as safe)"
      continue
    fi

    if _should_reap_go_build_dir "$in_use_rc" "$age" "$GO_BUILD_ORPHAN_GRACE_SECS"; then
      if rm -rf "$dir" 2>>"$LOG"; then
        # ga-p5q3: an unmeasured size (mb="") must never silently add as 0 to
        # the running total — that would report a confident-looking freed_mb
        # that's actually a KNOWN undercount as if it were exact. Track the
        # gap explicitly instead (see the summary line below) — same
        # discipline this file's own main() already applies to reclaimed_gb.
        if [ -n "$mb" ]; then
          freed_mb=$(( freed_mb + mb ))
        else
          unmeasured_deleted=$((unmeasured_deleted+1))
        fi
        log "go-build-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — DELETED (orphaned, no open refs, past ${GO_BUILD_ORPHAN_GRACE_SECS}s grace)"
      else
        log "go-build-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — DELETE FAILED (rm nonzero exit)"
      fi
    else
      if [ "$in_use_rc" -eq 0 ]; then
        reason="in use (open file/cwd inside)"
      else
        reason="too young (age=${age}s < grace=${GO_BUILD_ORPHAN_GRACE_SECS}s)"
      fi
      log "go-build-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — SPARED (${reason})"
    fi
  done

  if [ "$considered" -eq 0 ]; then
    log "go-build-reap: no go-build* dirs under ${root}"
  elif [ "$unmeasured_deleted" -gt 0 ]; then
    log "go-build-reap: considered=${considered} freed=${freed_mb}MB+ (${unmeasured_deleted} deleted dir(s) had unmeasured size, not counted in freed total) under ${root}"
  else
    log "go-build-reap: considered=${considered} freed=${freed_mb}MB under ${root}"
  fi
}

# _reap_code_sign_clone_orphans [root] — eighth reclaim lever (ga-nkqook),
# same shape as _reap_go_build_orphans immediately above (mirror its header
# for the full safety rationale): per-candidate lsof liveness via
# _code_sign_clone_dir_in_use (rc=2 unknown NEVER reaps) plus the
# CODE_SIGN_CLONE_ORPHAN_GRACE_SECS mtime grace, both evaluated by the pure
# _should_reap_code_sign_clone_dir — this function only does the real walk +
# real lsof/stat/du + real rm.
#
# Root cause this lever cleans up after (see ga-nkqook for the full
# measurement): com.athos.chrome-cdp crashes (SIGSEGV, EXC_BAD_ACCESS) and
# relaunches roughly every 12-16 minutes — confirmed live via chrome-cdp.log
# timestamps to be Chrome's OWN internal per-launch update self-check
# (chrome/updater/ipc/update_service_internal_proxy_mojo.cc's "Run", firing
# shortly after each (re)start) racing the still-starting new instance, NOT
# the independent hourly com.google.GoogleUpdater.wake LaunchAgent the bead
# originally suspected. Each crash-relaunch leaves exactly one
# code_sign_clone.* dir behind (57 clones ~= 56 successive crashes since
# boot). Fixing the crash loop itself is out of scope for this lever — it
# only reclaims what the loop leaves behind, same "detector/janitor, not the
# writer" split as every other lever in this file.
#
# [root] overrides the resolved _code_sign_clone_root for the selftest's
# hermetic fixture; production always calls this with no argument.
_reap_code_sign_clone_orphans() {
  local root="${1:-$(_code_sign_clone_root)}"
  if [ "$ENABLED" != "1" ]; then
    log "code-sign-clone-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    log "code-sign-clone-reap SKIP — code_sign_clone dir unresolved or missing (root='${root:-empty}')"
    return
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    log "code-sign-clone-reap SKIP — lsof not found on PATH (cannot confirm liveness; never guess)"
    return
  fi

  # One shared lsof -Fn snapshot for every candidate this cycle, not one call
  # per candidate. Measured live: a fresh `lsof -Fn` per dir across ~62
  # candidates took ~19s wall-clock — long enough for the crash loop itself
  # (relaunches as fast as every ~10s in a burst) to replace the truly-live
  # process mid-scan, so a per-dir check could read the CURRENTLY live clone
  # as orphaned depending on where in the loop it landed (the grace window
  # still made this safe — a dir that fresh is never past 1800s regardless —
  # but the log line was wrong and 62 sequential lsof calls is wasteful). A
  # single snapshot judges every candidate against the identical instant and
  # costs ~0.3s instead of ~19s. A failed/timed-out capture skips the WHOLE
  # lever this cycle (never guess per-dir liveness from a snapshot that
  # doesn't exist).
  local snap_err snap_out_file snap_rc
  snap_err="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-lsof-err.XXXXXX" 2>/dev/null)" || { log "code-sign-clone-reap SKIP — could not create temp file for lsof snapshot"; return; }
  snap_out_file="$(mktemp "${TMPDIR:-/tmp}/dolt-disk-floor-guard-lsof-snapshot.XXXXXX" 2>/dev/null)" || { rm -f "$snap_err"; log "code-sign-clone-reap SKIP — could not create temp file for lsof snapshot"; return; }
  timeout 10 lsof -Fn >"$snap_out_file" 2>"$snap_err"
  snap_rc=$?
  # ga-hxki9f: unlike the per-directory `lsof +D <dir>` check (where empty
  # output legitimately means "nothing open in this one dir"), a SYSTEM-WIDE
  # `lsof -Fn` snapshot coming back completely empty is never a plausible
  # "confirmed nothing open on this host" result — there is always at least
  # lsof's own process, the calling shell, and every other running daemon.
  # Gate on empty stdout REGARDLESS of stderr content, not only when stderr is
  # ALSO non-empty: a quietly-broken or PATH-shadowed lsof that exits 0 with
  # no output on either stream must still read as unknown, never as
  # "confirmed nothing in use" — the old stderr-gated check let exactly that
  # shape through, and because every candidate this cycle shares the ONE
  # snapshot, a single quiet lsof failure misread that way would mark EVERY
  # candidate orphaned in one shot (mass-delete, including genuinely in-use
  # dirs) rather than just missing one (ga-p5q3: error and empty must not
  # collapse to the same value — verified live via a fake exit-0/no-output
  # lsof; see this bead's selftest addition).
  if [ "$snap_rc" -eq 124 ] || [ ! -s "$snap_out_file" ]; then
    log "code-sign-clone-reap SKIP — lsof -Fn snapshot failed, timed out, or returned empty this cycle (never guess liveness without it)"
    rm -f "$snap_err" "$snap_out_file" 2>/dev/null
    return
  fi
  rm -f "$snap_err" 2>/dev/null

  local now; now=$(date +%s)
  local dir base mb mtime age in_use_rc reason considered=0 freed_mb=0 unmeasured_deleted=0

  for dir in "$root"/code_sign_clone.*; do
    [ -d "$dir" ] || continue
    considered=$((considered+1))
    base="$(basename "$dir")"
    mb="$(_dir_size_mb "$dir")"
    mtime="$(stat -f %m "$dir" 2>/dev/null)"
    if [ -z "$mtime" ]; then
      log "code-sign-clone-reap: ${base} (${mb:-unmeasured}MB) — SPARED (could not stat mtime; never guess age)"
      continue
    fi
    age=$(( now - mtime ))

    _code_sign_clone_dir_in_use "$dir" "$snap_out_file"; in_use_rc=$?
    if [ "$in_use_rc" -eq 2 ]; then
      log "code-sign-clone-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — SPARED (lsof could not confirm liveness this cycle; never treat unknown as safe)"
      continue
    fi

    if _should_reap_code_sign_clone_dir "$in_use_rc" "$age" "$CODE_SIGN_CLONE_ORPHAN_GRACE_SECS"; then
      if rm -rf "$dir" 2>>"$LOG"; then
        if [ -n "$mb" ]; then
          freed_mb=$(( freed_mb + mb ))
        else
          unmeasured_deleted=$((unmeasured_deleted+1))
        fi
        log "code-sign-clone-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — DELETED (orphaned, no open refs, past ${CODE_SIGN_CLONE_ORPHAN_GRACE_SECS}s grace)"
      else
        log "code-sign-clone-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — DELETE FAILED (rm nonzero exit)"
      fi
    else
      if [ "$in_use_rc" -eq 0 ]; then
        reason="in use (open file/cwd inside)"
      else
        reason="too young (age=${age}s < grace=${CODE_SIGN_CLONE_ORPHAN_GRACE_SECS}s)"
      fi
      log "code-sign-clone-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — SPARED (${reason})"
    fi
  done

  rm -f "$snap_out_file" 2>/dev/null

  if [ "$considered" -eq 0 ]; then
    log "code-sign-clone-reap: no code_sign_clone.* dirs under ${root}"
  elif [ "$unmeasured_deleted" -gt 0 ]; then
    log "code-sign-clone-reap: considered=${considered} freed=${freed_mb}MB+ (${unmeasured_deleted} deleted dir(s) had unmeasured size, not counted in freed total) under ${root}"
  else
    log "code-sign-clone-reap: considered=${considered} freed=${freed_mb}MB under ${root}"
  fi
}

# _reap_bash_edit_diff_orphans [root] — reclaim lever (ga-ofi307): Claude
# Code's own Bash-tool edit-diff renderer creates one full shadow git repo
# (HEAD, config, index, objects/, refs/) per distinct edit target under
# /private/tmp/claude-<uid>/bash-edit-diff/<hash>/ and never cleans any of
# them up itself. MEASURED 2026-09-17 20:36: 38 of these, 250-360MB each
# (3.5GB total) — the single largest consumer on the host that night, LARGER
# than every Dolt database in the city combined (whatsapp_automation, the
# next biggest, is 340MB) — and invisible to every other lever in this file:
# not a scratchpad (_reap_dead_scratch only walks REGISTERED session
# scratchpad dirs, and this is a sibling directory with its own name, not
# nested under any of them), not a transcript, not GOCACHE, not a go-build or
# code-sign-clone orphan. The guard ran that night and logged "reclaim OK —
# avail 7GB -> 7GB" — a confident-looking success over a complete non-effect
# (see this file's own header and _safe_reclaim's zero-gain wording above,
# also fixed by this bead).
#
# Same directory-walk/mtime-age shape as _reap_go_build_orphans and
# _reap_code_sign_clone_orphans above, deliberately MINUS their lsof
# liveness check — see BASH_EDIT_DIFF_ORPHAN_GRACE_SECS's own comment for why
# no liveness signal exists for this class of directory (no PID/session
# correlation to check against; mtime is the only signal). Runs at WARN same
# as CRITICAL (no two-tier trade-off of its own, same reasoning as go-build/
# code-sign-clone: this is a regenerable cache, not live session state — the
# bug's own overnight manual remediation deleted from a LIVE host with zero
# side effects, "cache efemero, regeneravel sob demanda — nao e dado de
# ninguem").
#
# Logs one line per candidate (name, MB, age, kept-or-deleted-and-why), same
# as the two sibling orphan-reap levers above, even when nothing qualifies.
# [root] overrides the resolved _bash_edit_diff_root for the selftest's
# hermetic fixture; production always calls this with no argument.
_reap_bash_edit_diff_orphans() {
  local root="${1:-$(_bash_edit_diff_root)}"
  if [ "$ENABLED" != "1" ]; then
    log "bash-edit-diff-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    log "bash-edit-diff-reap SKIP — bash-edit-diff cache dir unresolved or missing (root='${root:-empty}')"
    return
  fi

  local now; now=$(date +%s)
  local dir base mb mtime age considered=0 freed_mb=0 unmeasured_deleted=0

  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    considered=$((considered+1))
    base="$(basename "$dir")"
    mb="$(_dir_size_mb "$dir")"
    mtime="$(stat -f %m "$dir" 2>/dev/null)"
    if [ -z "$mtime" ]; then
      log "bash-edit-diff-reap: ${base} (${mb:-unmeasured}MB) — SPARED (could not stat mtime; never guess age)"
      continue
    fi
    age=$(( now - mtime ))

    if _should_reap_bash_edit_diff_dir "$age" "$BASH_EDIT_DIFF_ORPHAN_GRACE_SECS"; then
      if rm -rf "$dir" 2>>"$LOG"; then
        if [ -n "$mb" ]; then
          freed_mb=$(( freed_mb + mb ))
        else
          unmeasured_deleted=$((unmeasured_deleted+1))
        fi
        log "bash-edit-diff-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — DELETED (past ${BASH_EDIT_DIFF_ORPHAN_GRACE_SECS}s grace; ephemeral, regenerated on next edit)"
      else
        log "bash-edit-diff-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — DELETE FAILED (rm nonzero exit)"
      fi
    else
      log "bash-edit-diff-reap: ${base} (${mb:-unmeasured}MB, age=${age}s) — SPARED (too young: age=${age}s < grace=${BASH_EDIT_DIFF_ORPHAN_GRACE_SECS}s)"
    fi
  done

  if [ "$considered" -eq 0 ]; then
    log "bash-edit-diff-reap: no cache dirs under ${root}"
  elif [ "$unmeasured_deleted" -gt 0 ]; then
    log "bash-edit-diff-reap: considered=${considered} freed=${freed_mb}MB+ (${unmeasured_deleted} deleted dir(s) had unmeasured size, not counted in freed total) under ${root}"
  else
    log "bash-edit-diff-reap: considered=${considered} freed=${freed_mb}MB under ${root}"
  fi
}

# _is_test_dolt_config_path <config_path> — pure classifier (ga-fqj42): true
# iff <config_path> sits under one of the SIX cmd/bd test-tmp-dir prefixes
# third_party/beads/scripts/clean-test-tmp.sh already treats as test-only
# (mirrors disk-pressure-monitor.sh pass 14's own list verbatim — both lists
# must stay in sync; see that pass's header for the canonical source).
# Substring match, not a path-segment match: MkdirTemp always creates the
# prefixed dir as a single top-level entry directly under $TMPDIR, so a
# plain case-glob is sufficient without a second stat/split round-trip.
# Empty input never matches (fails closed — never guess a path is a test
# path from nothing).
_is_test_dolt_config_path() {
  local cfg="${1:-}"
  [ -n "$cfg" ] || return 1
  case "$cfg" in
    *beads-bd-tests-*|*beads-shared-server-bd-*|*bd-testbin-*|*bd-init-test-*|*bd-init-permissions-test-*|*bd-embedded-init-test-*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# _reap_orphan_test_dolt_processes — reclaim lever (ga-fqj42): SIGTERMs a
# `dolt sql-server` TEST instance (spun up by `go test -tags=integration
# ./cmd/bd/...`) that outlived its parent test run and got reparented to
# launchd. MEASURED incident (2026-09-10): pid 4768, 25min old, holding
# 785MB, mis-classified "active server or non-test path" and PROTECTED by
# `gc dolt-cleanup`'s own testConfigPathPrefixes() allowlist — that
# classifier only ever covered cmd/gc's own test prefixes, never cmd/bd's
# (a separate, vendored Go module under third_party/beads). This lever is
# the live-PROCESS half of that gap; the DIRECTORY half (a server that
# already died on its own, leaving pure disk litter with no PID to key off)
# is disk-pressure-monitor.sh pass 14's job, already live since 2026-09-10.
#
# Mayor's own triage (2026-09-18, ga-fqj42 comment) placed the process-kill
# half here, in shell — deliberately NOT inside gc dolt-cleanup's Go
# classifier, even though a separate, already-staged engine patch
# (docs/pending-engine-window/ga-fqj42-dolt-cleanup-beads-test-prefixes.patch)
# extends that SAME classifier for a different purpose (so a human running
# `gc dolt-cleanup` by hand also recognizes these dirs). Reasoning: that
# classifier's job is choosing which DATABASES to DROP inside an
# already-running server, by name prefix; this job is choosing which OS
# PROCESS to kill, by its --config PATH — a different domain. Folding this
# into the DB-name classifier would (a) make routine tuning of this list
# depend on a Mayor-coordinated engine window, (b) put a process kill
# inside a tool whose blast radius today is bounded to "DROP DATABASE under
# an allowlisted prefix", and (c) mix two different safety models into one
# decision point. This lever needs no engine window: it is a shell-only,
# unattended stopgap that starts protecting the city the next time this
# guard's own StartInterval (5min) fires, not whenever the next engine
# window happens to land.
#
# Safe-by-construction discriminator, REQUIRING BOTH conditions together —
# NEVER ppid==1 alone: production-drift-guard.sh:328-332 already documents
# that ppid==1 alone also matches the real, launchd-owned PRODUCTION dolt
# sql-server (a "launchd-owned daemon" is exactly what ppid==1 means, and
# production is one). VERIFIED live 2026-09-18 (Mayor's own triage comment
# on this bead): prod's pid was ppid=1 with --config under
# $CITY/.gc/runtime/packs/dolt/dolt-config.yaml, which contains none of
# _is_test_dolt_config_path's six prefixes — so the two conditions can
# never both hold for a real production server, by construction, not by
# convention:
#   1. ppid == 1 (reparented to launchd — a live test run's dolt sql-server
#      is still parented to the `go test` process itself, never launchd;
#      still-parented is never a reap candidate, at any age)
#   2. _is_test_dolt_config_path on its --config argument's value
#
# Extra belt-and-suspenders beyond the two conditions above (which are
# already safe by construction): unconditionally excludes whatever PID
# dolt-pid-lib.sh's dolt_server_pid resolves as the CANONICAL production
# server — the same basename==dolt + live-LISTEN-socket-verified resolver
# every other destructive Dolt lever in this city already trusts (ga-0bjqix)
# — even if it somehow also matched both conditions above. A missing/
# unreadable dolt-pid-lib.sh degrades this ONE extra check silently (the
# primary two-condition discriminator above still holds by construction),
# rather than blocking every OTHER lever in this file.
#
# Candidate enumeration mirrors dolt-pid-lib.sh's own false-positive
# defenses rather than trusting a bare `pgrep -f`: pgrep's search STRING
# ("dolt" + "sql-server") can match a `claude` agent session whose injected
# system prompt embeds this exact doctrine text verbatim — this very
# file's own header comment is one such text, and a headless agent's argv
# can legally contain multi-thousand-token prompt text (ga-0bjqix,
# "pgrep-f-matches-other-agents-embedded-prompt"). Every pgrep hit is
# re-verified by executable basename (`ps -o comm=` must resolve to
# "dolt") before its ppid/--config are ever inspected; a candidate failing
# that check is skipped, never guessed at.
#
# kill -TERM only, never -KILL: dolt sql-server shuts down cleanly on
# SIGTERM, and this lever's job is only to stop the leak from growing, not
# to guarantee instant death. The DATA/CONFIG DIRECTORY is deliberately
# left alone here for the existing lsof-gated directory reapers to remove
# once THEY can confirm no process still holds it open — killing and
# rm -rf-ing in the same breath would race a process that takes a moment
# to exit.
#
# Test seam: DOLT_DISK_FLOOR_GUARD_KILL_SINK=<file> appends the pid instead
# of signaling it (mirrors worktree-reaper.sh's own WORKTREE_REAPER_KILL_SINK
# convention) — the selftest fakes `pgrep`/`ps` on PATH and asserts against
# this sink file, so no real process is ever involved.
_reap_orphan_test_dolt_processes() {
  if [ "$ENABLED" != "1" ]; then
    log "orphan-test-dolt-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if ! command -v pgrep >/dev/null 2>&1; then
    log "orphan-test-dolt-reap SKIP — pgrep not found on PATH (cannot enumerate candidates; never guess)"
    return
  fi

  if ! declare -f dolt_server_pid >/dev/null 2>&1 && [ -r "$CITY/scripts/dolt-pid-lib.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$CITY/scripts/dolt-pid-lib.sh"
  fi
  local prod_pid=""
  declare -f dolt_server_pid >/dev/null 2>&1 && prod_pid="$(dolt_server_pid 2>/dev/null)"

  local pid="" comm="" ppid="" cmd="" cfg="" considered=0 killed=0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    considered=$((considered+1))

    if [ -n "$prod_pid" ] && [ "$pid" = "$prod_pid" ]; then
      log "orphan-test-dolt-reap: pid=${pid} — SPARED (is the canonical production server per dolt-pid-lib.sh)"
      continue
    fi

    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "${comm##*/}" in
      dolt) ;;
      *)
        log "orphan-test-dolt-reap: pid=${pid} — SPARED (basename '${comm:-unknown}' != dolt; pgrep -f matched something else, e.g. an agent's own prompt text)"
        continue
        ;;
    esac

    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ "$ppid" != "1" ]; then
      log "orphan-test-dolt-reap: pid=${pid} — SPARED (ppid=${ppid:-unknown} != 1; still parented to its own test run)"
      continue
    fi

    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    cfg="$(printf '%s\n' "$cmd" | awk '{for (i=1;i<=NF;i++) if ($i=="--config") {print $(i+1); exit}}')"
    if ! _is_test_dolt_config_path "$cfg"; then
      log "orphan-test-dolt-reap: pid=${pid} — SPARED (ppid=1 but --config='${cfg:-none}' is not under a known cmd/bd test-tmp prefix; ppid==1 alone is never sufficient — production-drift-guard.sh:328-332)"
      continue
    fi

    if [ -n "${DOLT_DISK_FLOOR_GUARD_KILL_SINK:-}" ]; then
      echo "$pid" >> "$DOLT_DISK_FLOOR_GUARD_KILL_SINK"
    else
      kill -TERM "$pid" 2>/dev/null
    fi
    killed=$((killed+1))
    log "orphan-test-dolt-reap: pid=${pid} — KILLED (SIGTERM; ppid=1, --config='${cfg}')"
  done < <(pgrep -f 'dolt sql-server' 2>/dev/null)

  if [ "$considered" -eq 0 ]; then
    log "orphan-test-dolt-reap: no dolt sql-server processes found"
  else
    log "orphan-test-dolt-reap: considered=${considered} killed=${killed}"
  fi
}

# _reap_backup_residue — ninth reclaim lever, alongside _safe_reclaim and the
# seven scratch/transcript/log/hf-cache/gocache/go-build/code-sign-clone
# levers above (ga-8f1uh0): retired .dolt-backup/<db>.old residue left behind
# by dolt-backup-reseed.sh (ga-ydrg9) accumulates with nothing to release it.
# Each reseed swap creates exactly one .old, and dolt-backup-reseed.sh
# deliberately never deletes it ("fica em .old para um humano remover depois
# de olhar" — the right call when that mechanism was new and unproven). The
# cost measured in production: dolt-s3-backup.sh's own reseed call REFUSES
# outright while a db's prior .old still exists, so without this lever every
# db can self-heal its backup bloat AT MOST ONCE before permanently needing a
# human again — the opposite of what Athos's P0 escalation on ga-8f1uh0 asks
# for ("a nossa própria infraestrutura consegue rodar esse comando quando ela
# identificar que é seguro fazer isso").
#
# Delegates to the standalone, independently-selftested dolt-backup-residue-
# reclaim.sh so its S3-verification safety logic — manifest presence (a real
# `aws s3api head-object` on <db>/manifest) + generation freshness (the S3
# fingerprint's run must be NEWER than the residue) + size coherence, ALL
# three required before any delete — is unit- AND stubbed-integration-tested
# in isolation, same pattern as the scratch/transcript/log reapers above.
# Runs at WARN same as CRITICAL (no two-tier trade-off of its own, unlike
# gocache/hf-cache): releasing S3-verified residue never disrupts anything
# live, so there is no "wait for CRITICAL" reason to hold it back.
#
# DOLT_BACKUP_RESIDUE_RECLAIM_PROD=1 (same ga-h565g production-sentinel
# pattern as SCRATCHPAD_REAPER_PROD/TRANSCRIPT_REAPER_PROD/LOG_REAPER_PROD
# above): this function IS the real, launchd-driven caller dolt-backup-
# residue-reclaim.sh's own sentinel is designed to trust — the ONLY place
# that should ever set this opt-in. Without it, that script dry-runs (logs
# what it would free, deletes nothing) whenever its BACKUP_ROOT resolves to
# the real default — which is also what keeps this safe to invoke from this
# file's own selftest below.
_reap_backup_residue() {
  if [ "$ENABLED" != "1" ]; then
    log "backup-residue-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  local reaper="$CITY/scripts/dolt-backup-residue-reclaim.sh"
  if [ ! -f "$reaper" ]; then
    log "backup-residue-reap SKIP — $reaper not found"
    return
  fi
  # 180s: each candidate makes up to two bounded (20s default) AWS calls plus
  # a couple of `du` reads; generous enough for a handful of .old residues
  # (realistically at most one per db) even under a slow network, while still
  # bounded so a wedged guard cycle can't hang past this file's own 300s
  # StartInterval.
  if DOLT_BACKUP_RESIDUE_RECLAIM_PROD=1 timeout 180 bash "$reaper" >> "$LOG" 2>&1; then
    log "backup-residue-reap OK"
  else
    log "backup-residue-reap FAILED or aborted (nonzero exit) — see log lines above"
  fi
}

# _reap_bloated_backup_staging <was_critical> — tenth reclaim lever (ga-74tts6):
# unlike _reap_backup_residue above (which only ever releases ALREADY-retired
# .old residue), this one triggers dolt-backup-reseed.sh's full shrink-in-place
# mechanism for a db's LIVE .dolt-backup/<db> staging directory itself —
# CRITICAL only, whereas residue-reap runs at WARN too, because a reseed is a
# real reconstruct-and-verify operation (network/disk I/O, briefly no local
# backup in the ultra-low-disk path), not a pure "delete what's already proven
# safe" release.
#
# WHY THIS EXISTS: dolt-backup-reseed.sh (see its own header) now has a
# low-disk AND an ultra-low-disk fallback so hq's staging bloat can shrink
# even when free space is critically tight — but until now the ONLY caller was
# dolt-s3-backup.sh's once-a-day 04:00 cron. The incident that opened this bead
# happened at noon: dolt-disk-floor-guard was CRITICAL for two cycles, Athos
# had to run the reseed by hand, and the very same catch-22 would have refused
# again at the next 04:00 anyway (see ga-74tts6/ga-i99qsp's own history). This
# lever closes that gap: the SAME relief the daily cron already runs, fired
# immediately when the disk-floor guard confirms CRITICAL, instead of waiting
# up to 24h.
#
# Enumerates "$CITY/.dolt-backup"/<db> (skipping *.old/*.new residue and any
# db without a live counterpart under $DOLTDIR) rather than querying Dolt for
# "SHOW DATABASES" — a pure filesystem listing keeps this lever usable even
# when Dolt itself is degraded, consistent with this guard's own "last resort,
# external, non-invasive" framing (see file header). Skips a db whose backup
# dir already carries .new/.old residue — a reseed for it is either already in
# flight or needs a human to clear stale residue first (dolt-backup-reseed.sh's
# own Preflight 3); piling another attempt on top would only race it.
#
# Processes AT MOST ONE db per cycle (returns after the first attempt) so this
# lever's worst-case added latency is bounded by RESEED_TRIGGER_TIMEOUT_SECS
# regardless of how many dbs are eligible — if more than one genuinely needs
# it, later CRITICAL cycles (5min apart) pick up the rest. Per-db cooldown
# (RESEED_TRIGGER_COOLDOWN_SECS) avoids hammering a db whose reseed attempt
# just failed; deliberately does NOT try to judge "is this db's backup
# actually bloated enough to be worth it" — dolt-backup-reseed.sh's own
# preflight already picks the safest available mode (normal/low-disk/ultra)
# for whatever the CURRENT free space is, so an unnecessary attempt on an
# already-lean backup just does the same reseed the daily cron would have
# done anyway, not a wasted or risky one.
_reap_bloated_backup_staging() {
  local was_critical="${1:-0}"
  if [ "$ENABLED" != "1" ]; then
    log "backup-staging-reap SKIP — DOLT_DISK_FLOOR_GUARD_ENABLED=0 (notify-only mode)"
    return
  fi
  if [ "$was_critical" != "1" ]; then
    return
  fi
  local reseed="$CITY/scripts/dolt-backup-reseed.sh"
  if [ ! -f "$reseed" ]; then
    log "backup-staging-reap SKIP — $reseed not found"
    return
  fi
  local backup_root="$CITY/.dolt-backup"
  if [ ! -d "$backup_root" ]; then
    log "backup-staging-reap SKIP — $backup_root not found"
    return
  fi

  mkdir -p "$STATE_RESEED_TRIGGER_DIR" 2>/dev/null || true
  local now_epoch; now_epoch=$(date +%s)
  local dir base db state_file last
  for dir in "$backup_root"/*/; do
    [ -d "$dir" ] || continue
    base="$(basename "$dir")"
    case "$base" in *.old|*.new) continue ;; esac
    db="$base"
    [ -d "$DOLTDIR/$db" ] || continue

    if [ -e "$backup_root/$db.new" ] || [ -e "$backup_root/$db.old" ]; then
      log "backup-staging-reap SKIP $db — .new/.old residue present (a reseed is already in flight or needs manual attention first)"
      continue
    fi

    state_file="$STATE_RESEED_TRIGGER_DIR/$db"
    last=""
    [ -f "$state_file" ] && last="$(cat "$state_file" 2>/dev/null)"
    if ! _cooldown_elapsed "$last" "$now_epoch" "$RESEED_TRIGGER_COOLDOWN_SECS"; then
      log "backup-staging-reap SKIP $db — attempted within the last ${RESEED_TRIGGER_COOLDOWN_SECS}s (cooldown)"
      continue
    fi
    echo "$now_epoch" > "$state_file" 2>/dev/null || true

    log "backup-staging-reap: CRITICAL — triggering '$reseed $db' now instead of waiting for the daily 04:00 dolt-s3-backup.sh run (ga-74tts6) …"
    if timeout "$RESEED_TRIGGER_TIMEOUT_SECS" "$reseed" "$db" >> "$LOG" 2>&1; then
      log "backup-staging-reap OK — $db reseed completed"
    else
      log "backup-staging-reap: $db reseed did not complete within ${RESEED_TRIGGER_TIMEOUT_SECS}s this cycle, or refused (non-fatal — see log lines above for reseed's own diagnosis; eligible again after the ${RESEED_TRIGGER_COOLDOWN_SECS}s per-db cooldown)"
    fi
    return
  done
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
  gc_dolt_probe_robust
  local recheck_rc=$?
  if [ "$recheck_rc" -eq 0 ]; then
    log "resurrect OK — Dolt serving again after 'gc dolt start' (rc=${start_rc})"
    "$NOTIFY" -t "Dolt disk-floor guard" -p 4 "🔁 Dolt was confirmed down — auto-restarted via 'gc dolt start' (disk avail=${avail}GB, class=${class}). Verify the city is healthy. See ga-f4l2z." 2>/dev/null || true
    return 0
  fi

  # recheck_rc=1 (confirmed still down) and recheck_rc=2 (inconclusive — e.g.
  # a fresh process still settling under a CPU burst the robust probe
  # couldn't rule out in time) are DELIBERATELY handled identically here: an
  # inconclusive post-restart read must never be treated as success (that
  # would risk silently leaving a real outage unescalated), so both fall
  # through to the same FAILED/escalate path — the safe direction to collapse
  # toward when uncertain. Logged distinctly so a human reading this later
  # knows which one actually happened.
  if [ "$recheck_rc" -eq 2 ]; then
    log "resurrect INCONCLUSIVE — could not confirm Dolt is healthy after 'gc dolt start' (rc=${start_rc}); treating as failure (never treat unknown as success)"
  else
    log "resurrect FAILED — Dolt still unreachable after 'gc dolt start' (rc=${start_rc})"
  fi
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
    _maybe_mail_recovery "$avail" "$now"
    # ga-ond0fa: the disk is healthy — end any growth-photo episode (the next
    # WARN/CRITICAL earns a fresh photo) and, if the interval has passed, refresh
    # the "last OK" baseline that episode photos are diffed against. Last on
    # purpose: it is the only part of this branch that can take real time, and
    # the alerts/recovery above must not wait behind it.
    _growth_clear_episode
    _growth_baseline_refresh "$now"
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

  # ga-ond0fa: photograph WHAT GREW before any lever below runs — they delete
  # scratch, caches and orphans, the very things a growth photo must still see.
  # Once per episode level (first WARN, first CRITICAL); no-op otherwise.
  _growth_episode_photo "$class" "$avail"

  _read_state
  _safe_reclaim "$avail"
  _reap_dead_scratch "$was_critical"
  _reap_dead_transcripts
  _reap_hf_cache "$was_critical"
  _reap_gocache "$was_critical"
  _reap_go_build_orphans
  _reap_code_sign_clone_orphans
  _reap_bash_edit_diff_orphans
  _reap_orphan_test_dolt_processes
  _reap_backup_residue
  _reap_bloated_backup_staging "$was_critical"

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
  # future edit adds a fourth. ga-4f4opx: the same single spot is where a
  # CRITICAL episode's recovery is detected, so the recovery-mail check
  # (no-op unless this episode actually mailed) lives right alongside it.
  if [ "$was_critical" = "0" ]; then
    _write_critical_sustain 0
    _maybe_mail_recovery "$avail" "$now"
  fi

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

    # ga-sfj3i.3 item 4 (superseded by ga-xz5re — see _top_mem_processes'
    # own header for why RSS was replaced with physical-memory footprint):
    # top memory consumers, so a kill decision (made by a human/Mayor — this
    # guard still never kills anything itself) is informed rather than a
    # guess. Logged only when actually alerting, not every cycle — unlike
    # vm_swap_gb, this isn't needed for historical mining, only for the
    # moment someone has to act.
    local top_mem; top_mem="$(_top_mem_processes 5)"
    if [ -n "$top_mem" ]; then
      log "top memory-footprint processes (PID PPID MEM CMPRS LAUNCHD_LABEL COMMAND):"
      printf '%s\n' "$top_mem" | while IFS= read -r _mem_line; do log "  $_mem_line"; done
    else
      log "top memory-footprint processes: unmeasured (top produced no rows)"
    fi

    # ga-ofi307 (invariant b): top DISK consumers across this guard's known
    # scratch/cache roots — see _top_disk_consumers' own header. Logged only
    # when actually alerting, same placement/rationale as top_mem above. This
    # is what turns a bare "cause not identified" (below) into something a
    # human can act on without first running `du` by hand.
    local top_disk; top_disk="$(_top_disk_consumers 8)"
    if [ -n "$top_disk" ]; then
      log "top disk consumers (MB path, known scratch/cache roots):"
      printf '%s\n' "$top_disk" | while IFS= read -r _disk_line; do log "  $_disk_line"; done
    else
      log "top disk consumers: unmeasured (no known roots present or du failed)"
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
        # ga-4f4opx: sustain-confirmed no longer mails unconditionally on
        # EVERY subsequent CRITICAL cycle — that was the actual bug (32 of 65
        # Mayor mails in one night, one per 5min cycle, same disk event).
        # Gate the repeat mail on its own cooldown/new-minimum track; the
        # FIRST sustain-confirmed mail of an episode always goes out
        # regardless (no prior record → _should_mail_critical's own
        # _cooldown_elapsed fail-open).
        _read_last_mail_state
        if ! _should_mail_critical "$_LAST_MAIL_EPOCH" "$now" "$CRITICAL_MAIL_COOLDOWN_SECS" "$avail" "$_LAST_MAIL_AVAIL" "$CRITICAL_MAIL_MIN_DROP_GB"; then
          log "CRITICAL sustain confirmed (${pending}/${CRITICAL_MAIL_SUSTAIN}) but re-mail SUPPRESSED (ga-4f4opx): avail=${avail}GB vs last-mailed=${_LAST_MAIL_AVAIL:-none}GB (need -${CRITICAL_MAIL_MIN_DROP_GB}GB new minimum), last mail <${CRITICAL_MAIL_COOLDOWN_SECS}s ago. notify above already fired unconditionally."
        else
        log "CRITICAL sustain confirmed (${pending}/${CRITICAL_MAIL_SUSTAIN} consecutive cycles) — mailing Mayor (avail=${avail}GB last-mailed=${_LAST_MAIL_AVAIL:-none}GB)"
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
        local growth_txt; growth_txt="$(_growth_mail_text)"
        local mail_body="dolt-disk-floor-guard: Dolt data-dir hit CRITICAL floor (<= ${FLOOR_CRITICAL_GB}GB) for ${pending} consecutive cycles.
Safe reclaim (gc dolt-cleanup --force), dead-session scratchpad cleanup, and dead-session
transcript cleanup were already attempted this cycle. This is the same class of event that
killed the HQ Dolt server on 2026-07-14 (ga-vs55): a full disk hitting Dolt mid-journal-write.
CRITICAL persisted across multiple cycles and could recur even if the current reading looks
recovered.

DIAGNOSIS (ga-sfj3i.3): ${diagnosis}. ${diagnosis_detail}

Top 5 processes by physical memory footprint (PID  PPID  MEM  CMPRS  LAUNCHD_LABEL  COMMAND),
for an informed decision on what to bring down if RAM pressure is the lever (this guard never
kills anything itself):
${top_mem:-  (unmeasured — top produced no rows)}

(ga-sfj3i.2 measured the vm_swap<->disk correlation and the Mayor's own follow-up falsified a
broader causal claim against 40 days of this guard's history — see that bead for the raw numbers.)

Top disk consumers measured this cycle across this guard's known scratch/cache roots (MB path;
ga-ofi307 — catches a new large consumer, the way bash-edit-diff's 3.5GB cache was before this
bead, before a human has to find it by hand):
${top_disk:-  (unmeasured — no known roots present or du failed)}

WHAT GREW (ga-ond0fa) — this episode's disk-growth photo, taken before any reclaim lever ran and
diffed against the last OK photo:
${growth_txt}"
        "$GC" mail send mayor -s "Dolt disk-floor CRITICAL: avail=${avail}GB" -m "$mail_body" 2>/dev/null || log "WARN: gc mail send mayor failed"
        _write_last_mail_state "$now" "$avail"
        _write_critical_episode_mailed 1
        fi
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
