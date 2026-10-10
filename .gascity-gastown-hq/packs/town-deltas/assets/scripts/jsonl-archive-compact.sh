#!/bin/bash
# jsonl-archive-compact.sh (ga-a3ar7h) — keep the jsonl-archive git repos compacted, by BYTES.
#
# WHY: mol-dog-jsonl commits a fresh copy of hq.jsonl (41MB) and whatsapp_automation.jsonl
# (10-20MB) many times a day. Each commit leaves ~9 NEW loose objects that are huge: measured
# 2026-09-26, 124 commits since the last pack were 5.5GiB of loose objects = 45MiB per commit,
# ~243MiB/h; the same commits packed (delta-compressed) cost 67-189KB each (the packs of
# 14-23/09 and 23-25/09). Nothing in this city compacted them in time: git's own post-commit
# `maintenance run --auto` sizes the loose backlog by looking at ONE directory (objects/17) and
# needs more than one object there — a 1/256 sample of the object COUNT, blind to bytes. Proven
# on the real archive: 1227 loose objects, 241 of 256 directories holding >=2, objects/17
# holding 1, and `GIT_TRACE=1 git maintenance run --auto` printed one line and did nothing. The
# three packs that exist (14/09, 23/09, 25/09 16:09: 349/126/64MB, plus a multi-pack-index) look
# like the output of git's own geometric auto-repack firing only now and then; after 25/09 16:09
# it stayed quiet until the disk hit its 2GB floor at 12:4x. The single-flight git-maintenance-runner
# (~/.gastown/scripts) only lists /Users/athos/gt and whatsapp_automation, and skips below 10GB
# free — exactly when this repo needs it. The first manual `git gc` over the whole backlog was
# killed by its 900s timeout and threw all its work away; a second one, uncapped, finished after
# 36 minutes at normal priority (6.1GB -> 692MiB) — longer than any order run may last, which is
# why the steady state must never let a backlog form, and why a gc that keeps timing out is a
# mail to a human (below), not something to retry forever.
#
# WHAT: per archive repo, on every order run (30m), measure `git count-objects -v` and act on
#   1. loose bytes >= JAC_LOOSE_LIMIT_KIB (256MiB): pack the loose objects in BATCHES
#      (`git maintenance run --task=loose-objects`, the primitive the town's own runner already
#      uses) and `git prune-packed` after each. The batch size ADAPTS: it starts at
#      JAC_BATCH_OBJECTS (60), is halved whenever a batch hits its OWN timeout (retried at once with the
#      smaller size, down to 5), is remembered per repo in the state file, and doubles once after
#      a run whose batches all made progress, with no timeouts and a fast last FULL-size batch (one that had at least
#      that many unpacked loose objects to pack: the last batch of a drain is usually a REMAINDER of a few objects that
#      finishes at once whatever the size is, so it is no evidence about the size, and it leaves the verdict of the last
#      full batch as it was; so does a batch that only pruned copies of objects already in a pack). A batch that FAILED
#      or did nothing (pack-objects out of space; another maintenance run holding git's lock) is never
#      "fast": growing on a run where nothing was packed would start the first run after the cause
#      cleared at ~200 objects (~1GiB loose), which this host cannot pack inside a batch timeout. A batch
#      cut by the RUN DEADLINE (the budget ending, not the batch being too big) ends the run as
#      `deferred` and leaves the size alone — and so does the `prune-packed` after it (idempotent; its
#      own cap running out is a failure, the run's budget ending is not). A batch made progress when the
#      loose COUNT fell, or a new pack appeared whose loose copies are all gone (prune-packable 0): the
#      exporter adds ~9 loose objects per commit while a batch runs, which at the minimum batch of 5 can
#      leave the count level. A new pack alone is not enough — a prune-packed that removes nothing would
#      make every batch re-pack the same objects — so that run ends `stalled`. Measured on 41MB blobs (9 versions, same output
#      5.8MiB every time): 177s at nice 19 + background QoS, 69-101s at nice 10, 52s at nice 0,
#      under load 35-63 — this host is always loaded, so a fixed batch size could time out
#      forever and never make progress. Bounded batches matter: a run killed by its timeout still
#      keeps every batch it finished, so even a multi-GiB backlog drains instead of restarting
#      from zero each cycle (a single full gc over the backlog throws all its work away when it
#      times out).
#   2. pack count >= JAC_PACKS_LIMIT (8): one full `git gc` to consolidate. Each batch pack
#      carries its own first full copy of every big file (batches cannot delta against earlier
#      packs); the gc re-deltas those against the whole history and merges the packs. The alarm judges
#      the END state, so a gc that succeeds clears a failed tier 1 (it packs the loose objects too); a gc
#      that did NOTHING (busy, or killed) never launders one: only a status that is not a failure on its own
#      (bad_status: failed / stalled / timeout / unmeasured / skipped-low-disk) can be replaced by `busy` or
#      `deferred`. The gc gets the same budget rule as a batch: a kill at its OWN cap (600s) is `timeout`
#      (the repo is too big for one gc), a kill at the end of the RUN's budget is `deferred` — the run that
#      crosses the pack limit is by construction one whose tier 1 just spent part of the budget.
# Nothing here ever shortens history: no prune of reachable objects, no shallow, no squash.
# `git gc` keeps its own 2-week expiry for unreachable objects. The S3 mirror
# (dolt-s3-backup.sh) copies only the working tree (`--exclude ".git/*"`), so the git history
# has NO offsite copy — compaction is the only thing this script may do to it. Inside an archive
# repo the ONE thing it ever deletes is the temp file (tmp_*) that one of its OWN killed or failed
# steps left behind — never anything that was there before the step, never anything a process has
# open (see LEAKS). (Outside the repos it removes only its own lock, its state temp file and the old
# half of its log.)
#
# LEAKS (gate ga-obhsaf): a step killed mid-write — the run deadline or the step's own cap (SIGTERM from `timeout`), pack-objects out of space, the OOM
# killer — leaves the temp file of the pack it was writing: objects/pack/tmp_pack_*, partial and read-only. Measured on this host's git 2026-09-27: a killed
# `maintenance run` leaves it (11.9MB of a 12MB blob in the test, 153MiB in the reviewer's), a killed `gc` leaves it too; git's own prune keeps it two weeks. On the
# filesystem this script exists to protect, that is one batch pack per cut, and in a big drain every run ends with a cut batch. Three rules, one place each:
#   1. Every git step goes through run_step (selftest S34 pins it: git_arch is called from there only, the $GITBIN seam is used nowhere but in git_arch, the only git run
#      bare on the repo is the read-only count-objects of measure(), and the set of steps is pinned). It lists the temp files
#      before the step; after a step that did NOT end 0, the ones that APPEARED during it are that step's leak, and reclaim_leak removes them — only if lsof
#      positively says no process has any of them open. An lsof that says one is open, no lsof, an lsof that is cut or fails or answers in any way but a clean "nothing
#      open" (files_in_use lists them): the files are KEPT and the log says why. Under doubt the inert state is "do not delete". A list that cannot be read after a step
#      that did not end 0 means the leak is UNKNOWN: nothing is removed and the run is BAD (R_LEAK_UNKNOWN) — not knowing is not the same as nothing left.
#   2. What is kept, or was left by a step that ended 0, is not hidden: garbage (git count-objects: garbage files and size-garbage) is measured at the start and the end of
#      every run that can be measured, printed in the status line, recorded in the state (informational: nothing reads it back), and a run that ENDS with more garbage
#      FILES than it started with is BAD whatever its status: a cut that leaked is not a clean cut (is_bad, R_GARBAGE_GREW). Files, not bytes: a leak is always a new
#      file, and a garbage file that was already there growing is somebody else's live writer.
#   3. Not covered, on purpose: a run SIGKILLed as a whole (the order's own 900s timeout, the OOM killer, a reboot) cannot reclaim anything — its leak is garbage already
#      on disk at the next run's start, visible in `garbage=` and pruned by git after two weeks; the script's own 780s deadline is what keeps that case rare. Older
#      garbage is never touched BY THIS SCRIPT: it is not known to be this script's. The same goes for a leak kept under doubt (rule 1: lsof cut, failed or silent) —
#      measured 09/10 (ga-jvxr24): a gc cut at its 600s cap left a 1.7GB tmp_pack, the lsof look could not answer, the file was kept, and nothing came back for it.
#      The backstop lives elsewhere: scripts/git-lock-hygiene.sh PART 1b removes tmp_* files older than 6h when no git runs on the repo and nothing has them open, and
#      alarms when a repo's size-garbage passes 500MiB. It does not change anything above: this script still removes only what its own killed step left.
#
# ONE REPACKER AT A TIME (ga-8z0hy7): the consolidating gc failed twice (08/10 13:32Z, 09/10 22:11Z) with `fatal: could not find pack 'loose-<sha>.pack'` / `failed to run repack`
# (rc=128), 387-562s in. Reproduced on a scratch repo with this host's git 2.54 (a gc whose main pack-objects is slow, plus the background run below): gc's repack names the
# packs it will consume, writes the main pack for minutes, and only then asks for them again by name (the cruft pack-objects, `--stdin-packs`) — and the loose-*.pack batch
# packs this script made are gone. Who removed them is git itself: every `git commit` in an archive repo (the exporter's, every 15 minutes) runs `git maintenance run --auto
# --quiet --detach`, and on 2.54 that runs `git repack -d -l --geometric=2 --write-midx`, which merges the small packs and deletes them. Measured in production 10/10: such a
# run lasts 19+ minutes under this host's load (one was alive for 19:00 when it was looked at, another started 30 minutes later), and while it runs there is NO
# objects/maintenance.lock: git's lock file belongs to the process that forks the detached child, and goes with it when that parent exits (reproduced on a scratch repo too) —
# so neither `maintenance run` nor `git gc` (gc.pid only) is kept out by it. That run is also the consolidation that actually works here (this gc timed out at its 600s cap 17
# times in the log, on a 4GiB repo), so it must not be switched off (maintenance.auto=false would leave a gc that cannot finish as the only consolidator). The rule instead:
# never two repackers at once, from both sides.
#   1. This script, before it starts the consolidating gc, looks for another git process repacking the repo (other_repacker: ps for this user's git maintenance/repack/gc/
#      pack-objects/... processes, then lsof for the working directory of each — a detached run keeps the directory of the commit that spawned it). Found = the gc is NOT started: status `busy`
#      (a failed/stalled/timed-out/unmeasured/skipped state is never replaced by it, same rule as a busy gc.pid), the log names the process. Cannot tell (no ps/lsof, either cut at
#      its cap, a candidate lsof gave no answer for) = the gc is not started either — under doubt the inert state — and the log says so. The END state still judges the run: a
#      repo that stays over the pack alarm is BAD whatever the status, so a gc that is deferred forever is not silent.
#   2. The exporter, whose commits are what spawn that run, commits with maintenance.auto=false while this script's lock is held (jsonl-export.sh, commit_archive_snapshot): no
#      new background repack can start during a compaction run. It resumes the moment the run ends, so git's consolidation is only delayed, never removed.
# Together they leave one window: a commit that spawned a run in the instant before this script took its lock. If that run is still going when other_repacker looks (the gc
# starts after the batches, minutes into the run) it is seen; if it has finished it can no longer delete anything. Not covered, on purpose: a git run with --git-dir from another
# working directory (no cwd in the repo), and one of another user — nothing in this city does either to an archive but this script.
#
# THREE STATES, NEVER TWO: a repo whose objects cannot be measured is `unmeasured` (failure),
# not "0 loose". git is always called with --git-dir=<repo>/.git: without it a broken .git
# makes git walk UP and act on the enclosing repo (these archives live inside the city's own
# git tree — a plain `git -C` there would have gc'd the town monorepo).
#
# ALARM: a run is BAD when the repo ends >= JAC_LOOSE_ALARM_KIB loose WITHOUT the run having really
# shrunk it — smaller than at the run's start AND smaller than where the PREVIOUS run left it (state
# loose_kib; unknown = the run's own before/after alone), because a backlog emptied more slowly than
# it refills shrinks a little every run and still grows — or >= JAC_PACKS_ALARM packs, or the run
# ended with more git garbage files than it started with (LEAKS, rule 2), or the run
# failed / could not measure / was skipped for low disk / stalled / timed out at the minimum
# batch size or at gc's own cap. After
# JAC_ALERT_AFTER (3) consecutive BAD runs of a repo one mail goes to the mayor, at most one per repo per
# JAC_ALERT_EVERY_S (6h) — each repo keeps its own streak and its own last_alert_epoch, so two BAD repos can mail twice in
# a window, and a send that FAILED is given back and retried (that is not a second mail). The send is RECORDED FIRST (state
# last_alert_epoch = now, written before `gc mail send`), then ANNOUNCED in the log ("alarm mail: sending now"), then sent, and
# un-recorded when the send FAILS: a state that cannot be written means NO mail (logged, exit 1) — never a mail every 30
# minutes because the timestamp of one that went out was lost — and an undelivered mail is retried next run (delivered !=
# attempted), the log saying WHY. The send has its own cap (JAC_MAIL_TIMEOUT_S, 45s) so a hung gc/Dolt cannot hold the run until
# the order's kill; a send cut at that cap is delivery UNKNOWN (it may have gone out), so it stays on record — retrying could
# send it twice.
# Every announced attempt ends in exactly ONE of these outcome lines (mailed: "alarm mailed to mayor"; cut at the cap: "alarm mail
# TIMED OUT ... delivery UNKNOWN", stays on record, exit 1; failed: "alarm mail FAILED ... slot given back", retried next run; failed
# twice: "alarm mail FAILED ... could not be released", stays on record, exit 1) — OR NONE, when the run itself DIES between the record
# and the outcome (SIGKILL by the order's timeout, the OOM killer, a reboot): a dead process logs nothing and exits with nothing, so
# no "is logged and exits 1" can be promised for it. That case leaves this trace and no other: the state has the mail on record, and
# the log (and the order's captured output) ends its alarm lines at "sending now" with no outcome line after it. It means delivery
# NOT KNOWN, and under doubt the slot stays taken — the next alarm waits out JAC_ALERT_EVERY_S — while the next run's "stale lock ...
# reclaiming" line (once that lock is over a minute old) shows that a run died. When the record itself cannot be written there is no
# attempt and no mail: "alarm due but NOT mailed". Selftest S25 F kills a run in the middle of a send and pins all of the above; its
# trace check also runs over the mails of S9 and of S25 A-E (each attempt ends in exactly one outcome), and S25 F pins that this
# paragraph's vocabulary is the code's.
# Exit 1 whenever any repo is BAD, so the order runner shows the failure too --
# and also when the STATE cannot be updated: the streak is what reaches the alarm, so a run that cannot
# record it is blind, and must not look green. The state file must be a JSON OBJECT (a valid-JSON
# `[]`, `5` or `"x"`, an entry that is not an object, or an empty file, is repaired and LOGGED, never silently kept).
# With no `timeout`/`gtimeout` on PATH nothing is time-bounded and batch sizing cannot adapt: every run says so.
#
# MODES:  (none)        compact + state + alarm
#         --check       read-only: measure, print, and exit 0 healthy / 1 a failure (a repo git cannot measure, no archive, the PRIMARY archive
#                       absent) / 3 measured but over the alarm size (no lock, no state write, no mail, no git write). Over the loose alarm
#                       size is excused — exit 0, and the line says "judged draining" — only by the ORDER's own recorded verdict: a fresh
#                       (JAC_CHECK_FRESH_S, 2h) run that ended acceptably at bad_streak 0 with the backlog not grown by more than one trigger
#                       since. --check alone has one measurement and cannot see a backlog shrinking; the order can. Any doubt = not excused.
#         --print-config  print the effective config and exit 0
#
# EXIT CODES of a run: 0 healthy; 1 a failure — any repo BAD, the state cannot be written, the lock cannot be taken (and no other run holds it),
# the PRIMARY archive absent, no archive at all. The PRIMARY is the FIRST repo of JAC_REPOS (the one the exporter writes and dolt-s3-backup.sh
# mirrors); a later, retired one may be gone. The only quiet exit 0 that is not a healthy end of a run is "another run holds the lock".
#
# CADENCE: order jsonl-archive-compact, interval 30m, timeout 900s; JAC_DEADLINE_S (780s) is
# this script's own budget so it can log its outcome before the order's timeout fires. One
# instance at a time: an mkdir lock that records its owner's pid — reclaimed when the owner is dead
# (a run SIGKILLed by the order timeout) and the lock is over a minute old (the floor covers the instant
# between another run's mkdir and its pid write; a run that finds a younger dead lock yields to it as "in
# flight" and the next one reclaims it), after 90m when the owner still looks alive.
# Failing to TAKE the lock is not the same as another run HOLDING it (see take_lock below): only the
# second is a quiet exit 0. A pid that cannot be recorded, a stale lock that cannot be removed, a lock
# whose age cannot be read: exit 1 with the reason.
#
# STRUCTURE (selftest S30): every place in this file that DISCARDS a failure — `|| true`, `|| :`,
# `|| return 0`, `|| exit 0`, a literal `exit 0`, `mkdir -p`, a silenced `rm`/`rmdir` — carries
# `# benign[<key>]: <why a failure here cannot hide one that matters>`, and the selftest pins the set of
# keys. Adding or removing one fails the selftest until someone has read the site and updated the pin:
# four gate rounds each found one more discard that "the class sweep" had missed.
# STRUCTURE (selftest S34): every place that RUNS a git step goes through run_step (LEAKS, rule 1), no git that writes runs any other way, and the set of steps is pinned the same way —
# the gate reported the leak for the batch, and measured on this host's git the gc leaks the same way; a fourth step is one more thing that can be killed mid-write.
#
# TEST: bash packs/town-deltas/assets/scripts/jsonl-archive-compact.selftest.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"

# The two archives. maintenance/ is the one dolt-s3-backup.sh mirrors offsite and the one the
# per-rig mol-dog-jsonl instances write; town-deltas/ is the city-scope instance's and is being
# retired by ga-7sxdmb (left in place, no longer written) — a missing repo is fine as long as
# at least one exists.
REPOS="${JAC_REPOS:-$RUNTIME/packs/maintenance/jsonl-archive $RUNTIME/packs/town-deltas/jsonl-archive}"
LOOSE_LIMIT_KIB="${JAC_LOOSE_LIMIT_KIB:-262144}"     # 256MiB of loose objects triggers a batch pack
LOOSE_ALARM_KIB="${JAC_LOOSE_ALARM_KIB:-1048576}"    # 1GiB still loose after a run = BAD, unless the run really shrank it (a backlog draining, see ALARM)
PACKS_LIMIT="${JAC_PACKS_LIMIT:-8}"                  # this many packs triggers the consolidating gc
PACKS_ALARM="${JAC_PACKS_ALARM:-20}"                 # this many after a run = BAD (git's own autoPackLimit is 50)
BATCH_OBJECTS="${JAC_BATCH_OBJECTS:-60}"             # starting batch (~7 commits, ~300MiB loose); adapts, see header
BATCH_MIN=5
BATCH_MAX="${JAC_BATCH_MAX:-200}"
MAX_BATCHES="${JAC_MAX_BATCHES:-0}"                  # 0 = as many as the deadline allows
GIT_TIMEOUT_S="${JAC_GIT_TIMEOUT_S:-300}"            # per batch
GC_TIMEOUT_S="${JAC_GC_TIMEOUT_S:-600}"              # per consolidating gc
DEADLINE_S="${JAC_DEADLINE_S:-780}"                  # whole run; the order's timeout is 900s
MIN_BATCH_S="${JAC_MIN_BATCH_S:-30}"                 # do not START a batch with less than this left
MIN_GC_BUDGET_S="${JAC_MIN_GC_BUDGET_S:-240}"        # do not START a gc with less than this left
PRUNE_TIMEOUT_S="${JAC_PRUNE_TIMEOUT_S:-120}"        # per prune-packed after a batch
PRUNE_MIN_S="${JAC_PRUNE_MIN_S:-15}"                 # prune-packed always gets at least this, so a batch that ends at the deadline can still prune
# Leak accounting around every step (LEAKS in the header). The worst it can add PAST the deadline is 4 + 4 (the two temp-file lists) + 6 + 1 + 6 (two lsof
# looks and the pause between them) = 21s. The 120s between JAC_DEADLINE_S (780) and the order's 900s kill must also fit the alarm mail of each repo (2 x 45s):
# 780 + 21 + 90 = 891s, all caps hit at once — a limit no run is expected to touch, but it is the arithmetic, not a hope.
LIST_TIMEOUT_S="${JAC_LIST_TIMEOUT_S:-4}"            # one listing of the object store's temp files (ms in practice)
LSOF_TIMEOUT_S="${JAC_LSOF_TIMEOUT_S:-6}"            # one lsof look (measured 2-3.5s on this host under load 50)
RECLAIM_WAIT_S="${JAC_RECLAIM_WAIT_S:-1}"            # between the two looks: the writer may be a step that is still dying
LSOF="${JAC_LSOF:-}"                                 # test seam; empty = the first lsof on PATH, else /usr/sbin/lsof
PS="${JAC_PS:-}"                                     # test seam; empty = the first ps on PATH
PS_TIMEOUT_S="${JAC_PS_TIMEOUT_S:-4}"                # one process listing (ms in practice); other_repacker adds it to one lsof look (above), both before the gc's own budget is computed
HEADROOM_KIB="${JAC_HEADROOM_KIB:-524288}"           # free space that must remain after the estimate
ALERT_AFTER="${JAC_ALERT_AFTER:-3}"
ALERT_EVERY_S="${JAC_ALERT_EVERY_S:-21600}"
MAIL_TIMEOUT_S="${JAC_MAIL_TIMEOUT_S:-45}"           # the alarm mail's OWN cap — not the run's remaining budget: a run that used its whole budget must still be able to page (2 sends at 780s + 45s each end before the order's 900s kill)
LOCK_STALE_MIN="${JAC_LOCK_STALE_MIN:-90}"
CHECK_FRESH_S="${JAC_CHECK_FRESH_S:-7200}"           # --check trusts the order's recorded verdict only if that run ENDED within this many seconds (4 order intervals; the epoch is written after the run)
LOCK="${JAC_LOCK:-$RUNTIME/jsonl-archive-compact.lock}"
STATE="${JAC_STATE:-$RUNTIME/packs/town-deltas/jsonl-archive-compact-state.json}"
LOG="${JAC_LOG:-$CITY/.gc/logs/jsonl-archive-compact.log}"
GCBIN="${JAC_GC:-gc}"
GITBIN="${JAC_GIT:-git}"                             # test seam: a wrapper that can slow a batch down
LOG_MAX_LINES=4000

MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  --print-config) MODE=print ;;
  "") ;;
  *) echo "jsonl-archive-compact: unknown argument '$1' (use --check or --print-config)" >&2; exit 2 ;;
esac

if [ "$MODE" = print ]; then
  cat <<EOF
repos=$REPOS
loose_limit_kib=$LOOSE_LIMIT_KIB loose_alarm_kib=$LOOSE_ALARM_KIB
packs_limit=$PACKS_LIMIT packs_alarm=$PACKS_ALARM batch_objects=$BATCH_OBJECTS batch_max=$BATCH_MAX max_batches=$MAX_BATCHES
git_timeout_s=$GIT_TIMEOUT_S gc_timeout_s=$GC_TIMEOUT_S prune_timeout_s=$PRUNE_TIMEOUT_S prune_min_s=$PRUNE_MIN_S deadline_s=$DEADLINE_S min_batch_s=$MIN_BATCH_S
list_timeout_s=$LIST_TIMEOUT_S lsof_timeout_s=$LSOF_TIMEOUT_S reclaim_wait_s=$RECLAIM_WAIT_S ps_timeout_s=$PS_TIMEOUT_S
alert_after=$ALERT_AFTER alert_every_s=$ALERT_EVERY_S mail_timeout_s=$MAIL_TIMEOUT_S check_fresh_s=$CHECK_FRESH_S
state=$STATE log=$LOG lock=$LOCK
EOF
  exit 0   # benign[print-config]: --print-config only prints the effective configuration — no run happened, so there is no failure for this exit to hide
fi

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {
  local line="[$(ts)] $*"
  echo "$line"
  [ "$MODE" = check ] && return 0
  # benign[log-mkdir]: the line was already echoed to stdout (the order's own capture) — a log file that cannot be made must not stop the compaction it reports on
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  # benign[log-write]: same as above — stdout already has the line; the run's outcome is its exit code and its state, never this file
  echo "$line" >> "$LOG" 2>/dev/null || true
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt "$LOG_MAX_LINES" ] 2>/dev/null; then
    # benign[log-trim]: trimming is housekeeping of a diagnostic file; when it fails the file only grows until the next run's trim succeeds
    tail -n $((LOG_MAX_LINES / 2)) "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null || true
  fi
}

START="$(date +%s)"
remaining() { echo $(( DEADLINE_S - ( $(date +%s) - START ) )); }

# Lowered priority + bounded wrapper. nice 10, NOT the runner's `nice 19 taskpolicy -b`: measured
# 177s vs 69-101s for the same batch under this host's permanent load, and starving the one job
# that FREES disk is the worse trade — each batch is only ~300MiB of work. `timeout` when the
# host has one (a batch killed at the timeout keeps every earlier batch; without `timeout` the
# order's own 900s kill is the bound).
_pre=(nice -n 10)
_timeout_bin=""
for _t in ${JAC_TIMEOUT_CMDS:-timeout gtimeout}; do command -v "$_t" >/dev/null 2>&1 && { _timeout_bin="$_t"; break; }; done
_bounded() {  # _bounded <seconds> <cmd...>
  local t="$1"; shift
  if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$t" "${_pre[@]}" "$@"; else "${_pre[@]}" "$@"; fi
}

# pack.* bounds are the same three values jsonl-export.sh's ensure_archive_pack_config sets
# (ga-gtrc8n: unbounded pack-objects measured 3.2GB RSS on this repo, bounded 514MB). Passed with
# -c so this script never writes the repo's config.
git_arch() {  # git_arch <seconds> <git args...>   — uses $R_GITDIR and the repo's current batch size $R_BATCH
  local t="$1"; shift
  _bounded "$t" "$GITBIN" --git-dir="$R_GITDIR" \
    -c pack.threads=2 -c pack.windowMemory=256m -c pack.deltaCacheSize=64m \
    -c maintenance.loose-objects.batchSize="${R_BATCH:-$BATCH_OBJECTS}" "$@"
}

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# bad_status <status> — a status that is a failure on its own. A step that did NOTHING (gc busy, a step cut by the run
# deadline) may only replace a status that is NOT one of these: the failure it carries is still true.
bad_status() { case "$1" in failed|unmeasured|skipped-low-disk|stalled|timeout) return 0 ;; esac; return 1; }
# budget_for <cap_s> [floor_s] — sets t_left (what to give a step: its own cap, or what is left of the RUN when that is
# smaller; lifted to the floor, default 1 — `timeout 0` means "no limit" — but NEVER above the step's own cap) and
# by_deadline (1 = the RUN's budget, not the step's own cap, is the limit). A kill at t_left with by_deadline=1 is the budget
# ending: evidence of nothing about the step. (remaining == cap counts as the step's own cap.) Sets the CALLER's t_left /
# by_deadline (bash dynamic scope).
budget_for() {
  t_left="$(remaining)"; by_deadline=0
  [ "$t_left" -lt "$1" ] && by_deadline=1
  [ "$t_left" -ge "${2:-1}" ] || t_left="${2:-1}"
  [ "$t_left" -le "$1" ] || t_left="$1"
}
mib() { echo $(( $1 / 1024 )); }
# fmt <kib> — "<n>MiB", or "?" when git could not say (an unknown must never read as 0)
fmt() { if is_uint "${1:-}"; then echo "$(( $1 / 1024 ))MiB"; else echo "?"; fi; }

# measure — fills M_LOOSE_COUNT M_LOOSE_KIB M_PACKS M_PACK_KIB M_GARBAGE_COUNT M_GARBAGE_KIB, or returns 1 when
# git cannot say (never a quiet zero). M_PRUNABLE (loose objects that are ALSO in a pack) is filled when git reports it and
# is deliberately not required: only two rules read it — batch progress ("a new pack whose loose copies are all gone") and batch growth
# ("a batch with at least a full batch of objects to pack") — and in both "unknown" means "not proven", never "fine".
# Garbage (count-objects `garbage` files and `size-garbage`) is what a killed writer leaves: the count matters as much as the size, because a
# tmp_pack killed before it wrote anything is a 0KiB file that still counts as garbage.
measure() {
  local out k v
  M_LOOSE_COUNT=""; M_LOOSE_KIB=""; M_PACKS=""; M_PACK_KIB=""; M_GARBAGE_COUNT=""; M_GARBAGE_KIB=""; M_PRUNABLE=""
  out="$(git --git-dir="$R_GITDIR" count-objects -v 2>/dev/null)" || return 1      # the one git run outside run_step: it only reads (S34 pins that it is the only one)
  while IFS=': ' read -r k v; do
    case "$k" in
      count) M_LOOSE_COUNT="$v" ;;
      size) M_LOOSE_KIB="$v" ;;
      packs) M_PACKS="$v" ;;
      size-pack) M_PACK_KIB="$v" ;;
      garbage) M_GARBAGE_COUNT="$v" ;;
      size-garbage) M_GARBAGE_KIB="$v" ;;
      prune-packable) M_PRUNABLE="$v" ;;
    esac
  done <<EOF
$out
EOF
  is_uint "$M_LOOSE_COUNT" && is_uint "$M_LOOSE_KIB" && is_uint "$M_PACKS" \
    && is_uint "$M_PACK_KIB" && is_uint "$M_GARBAGE_COUNT" && is_uint "$M_GARBAGE_KIB"
}

# list_tmp — every temp file git may have left in the object store (objects/pack/tmp_pack_*, objects/??/tmp_obj_*), one path per line, sorted. A listing that
# FAILS — find erroring, or cut at its cap — is a non-zero return (pipefail), never an empty list: "could not list" must not read as "nothing left".
list_tmp() {
  [ -d "$R_GITDIR/objects" ] || return 1
  _bounded "$LIST_TIMEOUT_S" find "$R_GITDIR/objects" -maxdepth 2 -type f -name 'tmp_*' 2>/dev/null | sort
}

# files_in_use <file...> — 0 = no process has any of them open (a TRUSTED answer); 1 = at least one is open; 2 = cannot tell. lsof's exit status alone says nothing here — it
# exits 1 both when nothing is open and when only SOME of the named files are — so the answer is read from what it prints too: with `-F n` a file in use produces
# `p<pid>` `f<fd>` `n<path>` lines, and a clean "none" produces NOTHING. So 0 is exactly "exit 1 and no output at all"; an n-line among lsof's field lines (exit 0 or 1) is 1 and
# keeps ALL the files, whichever it names (attributing a hit means comparing paths, and /tmp vs /private/tmp is one symlink from "not the same file" = "not open");
# everything else is 2: no lsof, cut at its cap, an exit status above 1, exit 0 with no hit, output that is not field lines (a message), field lines with no file name.
files_in_use() {
  local bin="$LSOF" out rc line hit=0
  [ -n "$bin" ] || bin="$(command -v lsof 2>/dev/null)"
  [ -n "$bin" ] || { [ -x /usr/sbin/lsof ] && bin=/usr/sbin/lsof; }
  [ -n "$bin" ] && [ -x "$bin" ] || return 2
  out="$(_bounded "$LSOF_TIMEOUT_S" "$bin" -w -F n -- "$@" 2>&1)"; rc=$?
  [ "$rc" -le 1 ] || return 2
  if [ -z "$out" ]; then
    [ "$rc" -eq 1 ] && return 0
    return 2
  fi
  while IFS= read -r line; do
    case "$line" in
      "") ;;
      p*|f*) ;;
      n*) hit=1 ;;
      *) return 2 ;;
    esac
  done <<EOF
$out
EOF
  if [ "$hit" -eq 1 ]; then return 1; fi
  return 2
}

# other_repacker <repo> — is a git process of this user's, other than this script, repacking <repo> right now? (ONE REPACKER AT A TIME, header.) 0 = none, a TRUSTED answer (ps listed the
# processes and either no git process of a repacking kind exists, or each one that does has its working directory elsewhere / is gone); 1 = found (OTHER_WHO = "pid N: command");
# 2 = cannot tell. Cannot tell is every answer that is not one of those two: no ps, ps cut at its cap or empty (it always lists itself — an empty list is a ps that did not work, not a
# quiet machine), no lsof, lsof cut / failed / printing something that is not field lines, a directory line that is not a path, and a candidate that is still alive but that
# lsof gave no directory line for (not readable).
# The caller treats 2 like 1: the gc is not started. A detached `git maintenance run --auto` keeps the working directory of the commit that spawned it (measured on a live one
# 10/10), and so do the repack and pack-objects it starts, so the directory is what says which repo a process is working on — a git process in another repo, or none in this
# one, is not a reason to wait. Compared against the repo's PHYSICAL path (pwd -P): lsof prints the resolved one, and /tmp is a symlink to /private/tmp on this host.
other_repacker() {
  local repo="$1" real psbin lsbin pslist cands pids out rc line pid="" cwd seen=" " found=0 unknown=0 p
  OTHER_WHO=""
  real="$(cd "$repo" 2>/dev/null && pwd -P)" || return 2
  psbin="$PS"; [ -n "$psbin" ] || psbin="$(command -v ps 2>/dev/null)"
  [ -n "$psbin" ] && [ -x "$psbin" ] || return 2
  pslist="$(_bounded "$PS_TIMEOUT_S" "$psbin" -U "$(id -u)" -o pid=,command= 2>/dev/null)" || return 2      # this user's processes, tty-less ones (the detached run) included; only they can be repacking an archive this user owns, and for them `kill -0` below is exact
  [ -n "$pslist" ] || return 2
  # candidates: a `git` (bare or by path) followed, later on its command line, by a subcommand that repacks or writes packs; this script's own pid is not one
  cands="$(printf '%s\n' "$pslist" | awk -v me="$$" '
    $1 == me { next }
    { g = 0
      for (i = 2; i <= NF; i++) {
        if (!g) { if ($i ~ /(^|\/)git$/) g = 1; continue }
        if ($i ~ /^(maintenance|repack|gc|pack-objects|multi-pack-index|index-pack|prune|prune-packed|commit-graph)$/) { print $1; break }
      }
    }')"
  if [ -z "$cands" ]; then return 0; fi
  pids="$(printf '%s\n' "$cands" | tr '\n' ',' | sed 's/,$//')"
  lsbin="$LSOF"; [ -n "$lsbin" ] || lsbin="$(command -v lsof 2>/dev/null)"
  [ -n "$lsbin" ] || { [ -x /usr/sbin/lsof ] && lsbin=/usr/sbin/lsof; }
  [ -n "$lsbin" ] && [ -x "$lsbin" ] || return 2
  out="$(_bounded "$LSOF_TIMEOUT_S" "$lsbin" -w -a -d cwd -F pn -p "$pids" 2>&1)"; rc=$?
  [ "$rc" -le 1 ] || return 2      # lsof exits 1 when ANY listed pid has no match (one that exited since ps), so 0 and 1 are both answers; the output says which
  while IFS= read -r line; do
    case "$line" in
      "") ;;
      p*) pid="${line#p}" ;;
      f*) ;;
      n*) cwd="${line#n}"; seen="$seen$pid "      # a pid is answered only by its directory line: a `p` line with none leaves it unanswered (checked below)
          case "$cwd" in
            "$real"|"$real"/*) found=1; [ -n "$OTHER_WHO" ] || OTHER_WHO="pid $pid: $(printf '%s\n' "$pslist" | awk -v p="$pid" '$1 == p { $1 = ""; sub(/^ +/, ""); print substr($0, 1, 120); exit }')" ;;
            /*) ;;                  # an absolute path somewhere else: this repo is not what that process is working on
            *) unknown=1 ;;         # not a path (lsof's own words for a directory it could not read): that is not "somewhere else"
          esac ;;
      *) return 2 ;;      # not lsof's field lines: a message, an error text
    esac
  done <<EOF
$out
EOF
  if [ "$found" -eq 1 ]; then return 1; fi
  for p in $(printf '%s\n' "$cands"); do
    case "$seen" in *" $p "*) continue ;; esac
    if kill -0 "$p" 2>/dev/null; then unknown=1; fi      # alive, yet lsof gave no directory for it: it may be a repacker of this repo that cannot be read — not "none"
  done
  if [ "$unknown" -eq 1 ]; then return 2; fi
  return 0
}

# reclaim_leak <before-list-failed 0|1> <before-list> <what> — after a step that did NOT end 0 (STEP_RC): remove the temp files that APPEARED during it, if nobody has them open.
# Narrow on purpose (LEAKS in the header): only tmp_* (git's own temp prefix, which its prune removes after two weeks anyway), only what was not there before the step
# (older ones are not this step's to remove), only when files_in_use positively says 0. Every other answer keeps the files, says so in the log, and leaves the leak to the
# run's garbage measurement (grew = BAD). Never returns non-zero: what it did not remove is the measurement's to report, not this function's to fail on.
reclaim_leak() {
  local before_failed="$1" before="$2" what="$3" after f nl=$'\n' n=0 kib=0 sz look gone=0 err size_txt
  local -a files
  if [ "$before_failed" -ne 0 ] || ! after="$(list_tmp)"; then
    R_LEAK_UNKNOWN=1
    log "  step '$what' ended rc=$STEP_RC and the temp files of the object store could not be listed — what it left is UNKNOWN, nothing was removed, and the run counts as BAD: not knowing is not the same as nothing left"
    return 0
  fi
  files=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$nl$before$nl" in *"$nl$f$nl"*) continue ;; esac      # it was there before the step: not this step's
    files+=("$f")
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"; is_uint "$sz" && kib=$(( kib + (sz + 1023) / 1024 ))      # the size is for the log line only
  done <<EOF
$after
EOF
  n="${#files[@]}"
  if [ "$n" -eq 0 ]; then return 0; fi      # nothing new appeared during the step: it left nothing to reclaim
  if [ "$kib" -ge 1024 ]; then size_txt="$(fmt "$kib")"; else size_txt="${kib}KiB"; fi
  files_in_use "${files[@]}"; look=$?
  if [ "$look" -eq 1 ]; then
    sleep "$RECLAIM_WAIT_S"      # the writer may be a step that is still dying: one more look
    files_in_use "${files[@]}"; look=$?
  fi
  case "$look" in
    0) ;;
    1) log "  step '$what' ended rc=$STEP_RC and left $n temp file(s) ($size_txt); still open by a process (lsof), also at a second look — kept: not this run's to remove (the run's garbage growth counts)"
       return 0 ;;
    *) log "  step '$what' ended rc=$STEP_RC and left $n temp file(s) ($size_txt); cannot tell whether they are open (no lsof, lsof cut at its ${LSOF_TIMEOUT_S}s cap, failed, or printed a message) — kept (the run's garbage growth counts)"
       return 0 ;;
  esac
  for f in "${files[@]}"; do
    if err="$(rm -f -- "$f" 2>&1)"; then gone=$((gone + 1)); else log "  could not remove $f: ${err:-no output}"; fi      # rm -f exits non-zero when it cannot remove the file
  done
  log "  step '$what' ended rc=$STEP_RC and left $n temp file(s) ($size_txt): removed $gone of $n — none was there before the step and no process had them open (lsof)"
  return 0
}

STEP_OUT=""; STEP_RC=0
# run_step <cap_s> <git args...> — THE way this script runs a git step that writes to the repo (a batch, prune-packed, gc); sets STEP_OUT (its output) and STEP_RC (its exit
# status) and never fails itself. Lists the temp files before the step; after a step that did NOT end 0, whatever appeared during it is its leak (reclaim_leak). A step
# that ended 0 is not suspected — but a leak it left anyway is still MEASURED at the end of the run (garbage growth, is_bad). Selftest S34 pins that every step goes through here.
run_step() {
  local cap="$1" before before_failed=0
  shift
  before="$(list_tmp)" || before_failed=1
  STEP_OUT="$(git_arch "$cap" "$@" 2>&1)"; STEP_RC=$?
  if [ "$STEP_RC" -ne 0 ]; then reclaim_leak "$before_failed" "$before" "$*"; fi
  return 0
}

free_kib() {  # free KiB on the filesystem holding the repo; JAC_FREE_KIB is the test seam
  if [ -n "${JAC_FREE_KIB:-}" ]; then echo "$JAC_FREE_KIB"; return; fi
  df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# disk_low <repo> <need_kib> — 0 = free space is known and below the need; 1 = enough, OR unknown.
# Unknown (df failed / printed nothing) proceeds — refusing to compact because a status probe failed
# would leave the backlog growing — but it says so in the log: never a silent "enough".
disk_low() {
  local fr; fr="$(free_kib "$1")"
  if ! is_uint "$fr"; then log "  free space unknown (df returned '${fr:-nothing}') — proceeding without the disk guard"; return 1; fi
  [ "$fr" -lt "$2" ]
}

gitdir_kib() { du -sk "$R_GITDIR" 2>/dev/null | awk '{print $1}'; }

# state_json — the state file as a JSON OBJECT. Anything else (absent, empty, not JSON, or valid JSON of another shape:
# [] 5 "x" true null) reads as {}; state_problem says which, and the run logs it (below) instead of carrying on quietly.
state_json() {
  if [ -f "$STATE" ] && jq -e 'type == "object"' "$STATE" >/dev/null 2>&1; then cat "$STATE"; else echo '{}'; fi
}
state_problem() {  # prints why the state file is unusable and returns 0; returns 1 when it is fine (or there is none yet)
  [ -e "$STATE" ] || return 1
  [ -s "$STATE" ] || { echo "it is empty (0 bytes)"; return 0; }
  if ! jq empty "$STATE" >/dev/null 2>&1; then echo "it is not valid JSON"; return 0; fi
  jq -e 'type == "object"' "$STATE" >/dev/null 2>&1 && return 1
  echo "it is valid JSON but not a JSON object"; return 0
}
ENTRY_LOGGED=" "
# load_state <repo> — sets STATE_JSON with THIS repo's entry guaranteed to be an object. A number / array / string there made
# record()'s update fail, and `|| new=""` skipped the write with no trace: bad_streak could never reach the alarm. (Sets a
# global instead of printing: log() prints too, and would end up inside a $(...) capture.)
load_state() {
  STATE_JSON="$(state_json)"
  if jq -e --arg r "$1" 'has($r) and (.[$r] | type != "object")' <<<"$STATE_JSON" >/dev/null 2>&1; then
    case "$ENTRY_LOGGED" in
      *" $1 "*) ;;
      *) ENTRY_LOGGED="$ENTRY_LOGGED$1 "
         log "  state entry for $1 is not an object — reset to a fresh one (its bad-run streak and remembered batch size are lost)" ;;
    esac
    STATE_JSON="$(jq --arg r "$1" '.[$r] = {}' <<<"$STATE_JSON")"
  fi
  # ...and the numeric fields in it must be non-negative whole numbers: `is_uint || 0` read anything else as 0 with no trace
  # (a corrupted bad_streak restarted the count; a corrupted last_alert_epoch meant "never alerted", so the mail repeated; a
  # corrupted loose_kib — the previous run's end size, which the "draining" judgement compares against — fell back to the run's own
  # before/after, the rule that suppresses the alarm). loose_kib may also be null: a run that could not measure records that.
  local bad_fields
  bad_fields="$(jq -r --arg r "$1" 'def badnum: (.value | type) != "number" or .value < 0 or .value != (.value | floor);
      def bad: ((.key | IN("bad_streak","last_alert_epoch","batch_objects")) and badnum) or (.key == "loose_kib" and .value != null and badnum);
      (.[$r] // {}) | to_entries | map(select(bad)) | map(.key) | join(",")' <<<"$STATE_JSON" 2>/dev/null)" || bad_fields="?"
  if [ -n "$bad_fields" ]; then
    case "$ENTRY_LOGGED" in
      *" $1:f "*) ;;
      *) ENTRY_LOGGED="$ENTRY_LOGGED$1:f "
         log "  state entry for $1: field(s) $bad_fields are not non-negative whole numbers (or could not be checked) — dropped, read as unset" ;;
    esac
    STATE_JSON="$(jq --arg r "$1" 'def badnum: (.value | type) != "number" or .value < 0 or .value != (.value | floor);
        def bad: ((.key | IN("bad_streak","last_alert_epoch","batch_objects")) and badnum) or (.key == "loose_kib" and .value != null and badnum);
        .[$r] |= with_entries(select(bad | not))' <<<"$STATE_JSON" 2>/dev/null)" \
      || STATE_JSON="$(jq --arg r "$1" '.[$r] = {}' <<<"$(state_json)")"
  fi
}

# is_bad <status> — the alarm rule, over the repo's END state ($M_* already re-measured).
# Over the loose alarm size is BAD only when this run did not really SHRINK the backlog (R_PROGRESS=1: it ended smaller
# than it started AND smaller than where the previous run left it — a backlog drained slower than it refills shrinks a
# little every run and still grows): a backlog that is visibly draining must not page the mayor for a state they know.
is_bad() {
  bad_status "$1" && return 0
  [ "$M_LOOSE_KIB" -ge "$LOOSE_ALARM_KIB" ] 2>/dev/null && [ "${R_PROGRESS:-0}" != 1 ] && return 0
  [ "$M_PACKS" -ge "$PACKS_ALARM" ] 2>/dev/null && return 0
  [ "${R_GARBAGE_GREW:-0}" = 1 ] && return 0      # the run ended with more git garbage FILES than it started with, whatever its status (LEAKS, rule 2)
  [ "${R_LEAK_UNKNOWN:-0}" = 1 ] && return 0      # a step ended non-zero and what it left could not even be listed: unknown is not "nothing" (LEAKS, rule 1)
  return 1
}

# check_draining <repo> — sets R_PROGRESS (and R_VERDICT, the words for the log). `--check` has ONE measurement and no run start, so it cannot see a
# backlog shrinking; the ORDER can, and records its verdict in the state. Over the loose alarm size is excused (R_PROGRESS=1) only by a verdict that is
# FRESH (that run ENDED <= CHECK_FRESH_S ago: last_run_epoch is written by record(), after the run), ended with a status that is not a failure, at bad_streak 0 (its own alarm rule found the end state
# acceptable — a backlog it is draining), and the backlog has not grown by more than one trigger (LOOSE_LIMIT_KIB) since it ended. A verdict that
# is missing, stale, unreadable or of the wrong shape excuses NOTHING: the direction of every doubt here is "BAD", never "fine".
# (The early returns below leave R_PROGRESS=0 — the strict answer — so they are not discards of a failure; they are the failure's own answer.)
check_draining() {
  local row st streak lrun lkib age
  R_PROGRESS=0; R_VERDICT=""
  row="$(jq -r --arg r "$1" '.[$r] | if type == "object" then [(.status // "-"), (.bad_streak // "-"), (.last_run_epoch // "-"), (.loose_kib // "-")] | map(tostring) | join(" ") else empty end' <<<"$STATE_JSON" 2>/dev/null)"
  if [ -z "$row" ]; then return 0; fi
  read -r st streak lrun lkib <<<"$row"
  if ! { is_uint "$streak" && is_uint "$lrun" && is_uint "$lkib" && is_uint "$M_LOOSE_KIB"; }; then return 0; fi
  if [ "$st" = "-" ] || bad_status "$st"; then return 0; fi
  age=$(( $(date +%s) - lrun ))
  if [ "$age" -lt 0 ] || [ "$age" -gt "$CHECK_FRESH_S" ]; then return 0; fi
  if [ "$streak" -ne 0 ]; then return 0; fi
  if [ "$M_LOOSE_KIB" -gt $(( lkib + LOOSE_LIMIT_KIB )) ]; then return 0; fi
  R_PROGRESS=1
  R_VERDICT="the order's last run (${age}s ago) ended status=$st at bad_streak 0 and the backlog has not grown by more than one trigger since — judged draining"
}

ALARM_ERR=""; ALARM_TIMED_OUT=0
send_alarm() {  # send_alarm <repo> <status> <streak> — 0 only when the mail was really sent; ALARM_ERR = why not; ALARM_TIMED_OUT=1 = cut at the cap: delivery UNKNOWN, not "failed"
  local body out rc
  body="jsonl-archive compaction is not keeping up.
repo:    $1
status:  $2 (bad for $3 consecutive runs, every ~30m)
loose:   $(fmt "$M_LOOSE_KIB") in ${M_LOOSE_COUNT:-?} objects (limit $(fmt "$LOOSE_LIMIT_KIB"), alarm $(fmt "$LOOSE_ALARM_KIB"))
packs:   ${M_PACKS:-?} (limit $PACKS_LIMIT, alarm $PACKS_ALARM), packed $(fmt "$M_PACK_KIB")
garbage: ${M_GARBAGE_COUNT:-?} file(s), $(fmt "$M_GARBAGE_KIB") — temp files (tmp_*) that killed or failed git steps leave in objects/; this run started with ${R_GARBAGE_BEFORE:-?}$([ "${R_GARBAGE_GREW:-0}" = 1 ] && echo " — the file count GREW, and that is why this run counts as bad")$([ "${R_LEAK_UNKNOWN:-0}" = 1 ] && echo " — a step ended non-zero and the temp files it may have left could not be listed (leak UNKNOWN: also why this run counts as bad)")
.git:    $(fmt "$G_KIB")
log:     $LOG
state:   $STATE
Why it matters: without compaction this repo grows ~5GiB/day of loose hq.jsonl copies (ga-a3ar7h).
No history was deleted or shortened (the only files this script removes are temp files its own killed steps left; the log says which). Check: bash $0 --check ; then the last lines of the log.
If the log says gc timed out at its OWN cap (${GC_TIMEOUT_S}s), the repo is too big for one gc: run it by
hand, without a timeout, at low priority:  nice -n 10 git --git-dir=$1/.git gc   (26/09: 36 min for a 6GB backlog)."
  out="$(_bounded "$MAIL_TIMEOUT_S" "$GCBIN" mail send mayor/ -s "ESCALATION: jsonl-archive compaction failing [HIGH]" -m "$body" 2>&1)"; rc=$?
  ALARM_ERR="$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-200)"
  # 124 is `timeout`'s own "cut at the cap"; without a timeout binary nothing bounded the send, so the code is gc's.
  ALARM_TIMED_OUT=0; if [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ]; then ALARM_TIMED_OUT=1; fi
  return "$rc"
}

# write_state <repo> <state-json> <status> <streak> <last-alert-epoch> <now> — writes THIS repo's entry (this run's status and
# measurements, the bad-run streak, the time of the last alarm mail) into the state file. 0 = written; 1 = not computed or not
# written (logged, with the reason). Three outcomes, never two: computed and written / could not be computed / could not be
# written — the last two used to be a quiet skip (`|| new=""`): the streak never advanced, the alarm never fired, no log line.
write_state() {
  local repo="$1" state="$2" status="$3" streak="$4" last="$5" now="$6" new jrc
  new="$(jq --arg r "$repo" --arg st "$status" --argjson streak "$streak" --argjson last "$last" --argjson now "$now" \
        --arg lk "$M_LOOSE_KIB" --arg lc "$M_LOOSE_COUNT" --arg pk "$M_PACKS" --arg pks "$M_PACK_KIB" --arg g "${G_KIB:-}" --arg bo "${R_BATCH_SAVE:-}" \
        --arg gf "$M_GARBAGE_COUNT" --arg gk "$M_GARBAGE_KIB" \
        'def n($x): (try ($x | tonumber) catch null);
         .[$r] = ((.[$r] // {}) + {last_run_epoch:$now, status:$st, loose_kib:n($lk), loose_objects:n($lc), packs:n($pk), pack_kib:n($pks), gitdir_kib:n($g), garbage_files:n($gf), garbage_kib:n($gk), bad_streak:$streak, last_alert_epoch:$last})
         | if n($bo) != null then .[$r].batch_objects = n($bo) else . end' <<<"$state" 2>&1)"; jrc=$?
  if [ "$jrc" -ne 0 ] || ! jq -e 'type == "object"' <<<"$new" >/dev/null 2>&1; then
    log "  state update FAILED ($repo): jq rc=$jrc: $(printf '%s' "$new" | tail -n 2 | tr '\n' ' ' | cut -c1-200) — the bad-run streak cannot advance and no alarm mail can go out until the state can be written"
    return 1
  fi
  # benign[state-mkdir]: if the directory cannot be made, the write right below fails and is reported (state update FAILED, exit 1)
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  if ! { printf '%s\n' "$new" > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE" 2>/dev/null; }; then
    log "  state update FAILED ($repo): could not write $STATE — the bad-run streak cannot advance and no alarm mail can go out until the state can be written"
    # benign[state-tmp-cleanup]: removing a leftover temp file after a write that was already reported as FAILED; the failure is the log line above and return 1
    rm -f "$STATE.tmp.$$" 2>/dev/null
    return 1
  fi
  return 0
}

# record <repo> <status> — writes the state entry, bumps/resets the bad streak, and mails when due.
# The mail is RECORDED BEFORE it is sent: last_alert_epoch is the only thing that rate-limits it, and it used to be
# persisted only by the write AFTER the send — when that write failed, a mail that HAD been delivered was forgotten and
# went out again every run (an action took effect, its record was lost, so it is replayed). Now: no record, no mail.
# The record is followed by an ATTEMPT line and then the send, and every attempt is followed by exactly ONE outcome line — unless the run
# itself dies in between (SIGKILL by the order's timeout, the OOM killer, a reboot), which no code in a dead process can log. That case
# leaves the attempt line with no outcome after it: the trace of "on record, delivery not known" (selftest S25 F kills a run there).
record() {
  local repo="$1" status="$2" state streak last now bad=0 state_failed=0
  load_state "$repo"; state="$STATE_JSON"
  streak="$(jq -r --arg r "$repo" '.[$r].bad_streak // 0' <<<"$state" 2>/dev/null)"; is_uint "$streak" || streak=0
  last="$(jq -r --arg r "$repo" '.[$r].last_alert_epoch // 0' <<<"$state" 2>/dev/null)"; is_uint "$last" || last=0
  now="$(date +%s)"
  if is_bad "$status"; then bad=1; streak=$((streak + 1)); else streak=0; fi
  if [ "$bad" -eq 1 ] && [ "$streak" -ge "$ALERT_AFTER" ] && [ $((now - last)) -ge "$ALERT_EVERY_S" ]; then
    if write_state "$repo" "$state" "$status" "$streak" "$now" "$now"; then       # the mail is on record from here on
      log "  alarm mail: sending now, its slot already on record ($repo, status=$status, bad_streak=$streak) — its outcome is logged right after; a log that ends at this line means the run died mid-send and whether the mail went out is not known"
      if send_alarm "$repo" "$status" "$streak"; then
        log "  alarm mailed to mayor ($repo, status=$status, bad_streak=$streak)"
      elif [ "$ALARM_TIMED_OUT" -eq 1 ]; then
        # cut at the cap: the mail may have gone out and only its return hung. Not "failed" — UNKNOWN — so the slot is NOT given
        # back: a retry could send it twice, and under doubt the inert state is "do not contact again". Loud, and the run fails.
        log "  alarm mail TIMED OUT after ${MAIL_TIMEOUT_S}s — delivery UNKNOWN; it stays on record as sent (a retry could send it twice), so the next attempt waits up to ${ALERT_EVERY_S}s ($repo)"
        state_failed=1
      elif write_state "$repo" "$state" "$status" "$streak" "$last" "$now"; then   # it FAILED (gc said so): give the slot back
        log "  alarm mail FAILED (${ALARM_ERR:-no output}) — slot given back, will retry next run ($repo)"
      else
        log "  alarm mail FAILED (${ALARM_ERR:-no output}) and its slot could not be released — it stays on record as sent, so the next attempt waits up to ${ALERT_EVERY_S}s ($repo)"
        state_failed=1
      fi
    else
      log "  alarm due but NOT mailed ($repo, status=$status, bad_streak=$streak): it could not be recorded first, and a mail whose record is lost would repeat every run"
      state_failed=1
    fi
  else
    write_state "$repo" "$state" "$status" "$streak" "$last" "$now" || state_failed=1
  fi
  [ "$state_failed" -eq 1 ] && bad=1     # the run is not green when it cannot record itself
  return "$bad"
}

BAD_ANY=0
EXISTING=0

compact_repo() {  # compact_repo <repo> — sets STATUS, returns nothing; caller handles is_bad via record
  local repo="$1" t0 before_loose before_packs before_kib batches=0 prev_count prev_packs prev_unpacked prev_loose need out rc t_left batch_left b0 took timeouts=0 fast=0 saved by_deadline progressed over before_gcount before_gkib
  R_GITDIR="$repo/.git"
  STATUS="ok"; G_KIB=""; R_PROGRESS=0; R_BATCH_SAVE=""; R_GARBAGE_GREW=0; R_GARBAGE_BEFORE=""; R_LEAK_UNKNOWN=0
  t0="$(date +%s)"
  load_state "$repo"
  saved="$(jq -r --arg r "$repo" '.[$r].batch_objects // empty' <<<"$STATE_JSON" 2>/dev/null)"
  if is_uint "$saved" && [ "$saved" -ge "$BATCH_MIN" ] && [ "$saved" -le "$BATCH_MAX" ]; then R_BATCH="$saved"; else R_BATCH="$BATCH_OBJECTS"; fi
  # where the PREVIOUS run left this repo's loose bytes (its recorded end state); "" = not known (first run, that run could not
  # measure, or the state was reset) — the run's own before/after then decides alone
  prev_loose="$(jq -r --arg r "$repo" '.[$r].loose_kib // empty' <<<"$STATE_JSON" 2>/dev/null)"; is_uint "$prev_loose" || prev_loose=""

  if ! measure; then
    STATUS="unmeasured"
    log "repo=$repo status=unmeasured (git count-objects failed or returned no number — NOT treated as 0 loose)"
    return
  fi
  before_loose="$M_LOOSE_KIB"; before_packs="$M_PACKS"; before_kib="$M_PACK_KIB"
  before_gcount="$M_GARBAGE_COUNT"; before_gkib="$M_GARBAGE_KIB"; R_GARBAGE_BEFORE="${before_gcount} file(s), $(fmt "$before_gkib")"

  if [ "$MODE" = check ]; then
    G_KIB="$(gitdir_kib)"
    R_VERDICT=""
    if [ "$M_LOOSE_KIB" -ge "$LOOSE_ALARM_KIB" ]; then check_draining "$repo"; fi
    # the exit code alone (3) is not enough for someone reading the line: it must not look like a healthy one
    over=""; if is_bad ok; then over=" — OVER THE ALARM SIZE (loose >= $(fmt "$LOOSE_ALARM_KIB") or packs >= $PACKS_ALARM) and nothing excuses it: --check exits 3"; fi
    log "repo=$repo mode=check loose=$(fmt "$M_LOOSE_KIB")/${M_LOOSE_COUNT}obj packs=$M_PACKS packed=$(fmt "$M_PACK_KIB") garbage=${M_GARBAGE_COUNT}f/$(fmt "$M_GARBAGE_KIB") .git=$(fmt "$G_KIB")${R_VERDICT:+ — over the alarm size but $R_VERDICT}$over"
    return
  fi

  # ── tier 1: loose bytes over the limit → bounded batches until none are left ──
  if [ "$M_LOOSE_KIB" -ge "$LOOSE_LIMIT_KIB" ]; then
    need=$(( M_LOOSE_KIB / 4 + HEADROOM_KIB ))   # assumes the packed result is <=1/4 of the loose bytes (history: 200:1+)
    if disk_low "$repo" "$need"; then
      STATUS="skipped-low-disk"
      log "repo=$repo status=skipped-low-disk free=$(fmt "$(free_kib "$repo")") need~$(fmt "$need") loose=$(fmt "$M_LOOSE_KIB") — NOT compacted"
    else
      while [ "$M_LOOSE_COUNT" -gt 0 ]; do
        if [ "$(remaining)" -lt "$MIN_BATCH_S" ]; then STATUS="deferred"; break; fi
        if [ "$MAX_BATCHES" -gt 0 ] && [ "$batches" -ge "$MAX_BATCHES" ]; then STATUS="deferred"; break; fi
        prev_count="$M_LOOSE_COUNT"; prev_packs="$M_PACKS"
        # what this batch has to pack: the loose objects that are NOT already in a pack (git prunes those first). "" = git did not
        # say, which is "not proven" — the same direction as everywhere else in this file
        prev_unpacked=""; if is_uint "$M_PRUNABLE" && [ "$M_PRUNABLE" -le "$prev_count" ]; then prev_unpacked=$(( prev_count - M_PRUNABLE )); fi
        # t_left is the smaller of the per-batch timeout and what is left of the RUN: a kill at the first is a batch that was too
        # big, a kill at the second is the budget ending (equal = the batch's own cap)
        budget_for "$GIT_TIMEOUT_S"; batch_left="$t_left"     # t_left is reused for the prune below; "fast" is judged against THIS
        b0="$(date +%s)"
        run_step "$t_left" maintenance run --task=loose-objects --quiet; out="$STEP_OUT"; rc="$STEP_RC"
        took=$(( $(date +%s) - b0 ))
        batches=$((batches + 1))
        if [ "$rc" -eq 124 ] && [ "$by_deadline" -eq 1 ]; then
          STATUS="deferred"; fast=0
          log "  batch $batches (${R_BATCH} objects) was cut by the run deadline after ${t_left}s — the budget ended, not evidence the batch is too big (size kept)"
          break
        fi
        if [ "$rc" -eq 124 ]; then
          timeouts=$((timeouts + 1))
          if [ "$R_BATCH" -le "$BATCH_MIN" ]; then STATUS="timeout"; log "  batch $batches (${R_BATCH} objects, the minimum) timed out after ${t_left}s"; break; fi
          log "  batch $batches (${R_BATCH} objects) timed out after ${t_left}s — retrying with $(( R_BATCH / 2 > BATCH_MIN ? R_BATCH / 2 : BATCH_MIN ))"
          R_BATCH=$(( R_BATCH / 2 > BATCH_MIN ? R_BATCH / 2 : BATCH_MIN ))
          continue
        fi
        if [ "$rc" -ne 0 ]; then STATUS="failed"; log "  batch $batches failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; break; fi
        # `maintenance run --task=loose-objects` prunes the loose copies of the PREVIOUS batch
        # first and packs the next one after, so this batch's own loose copies are still on disk
        # (measured: count 6 -> pack written -> count still 6 -> prune-packed -> 3). Prune them
        # now, or every batch reads as "no progress" and the loop gives up after one.
        # ...with the same budget rule as the batch: its own cap, or what is left of the RUN (a floor keeps a batch that ended at the
        # deadline able to prune; the overrun is bounded by PRUNE_MIN_S, well inside the order's timeout). A kill by the budget is
        # not a failure of prune-packed — it is idempotent, and the loose copies it did not remove stay on disk (counted as loose,
        # so bounded by the loose limit) until a later batch or a consolidating gc prunes them; only its OWN cap running out is one.
        budget_for "$PRUNE_TIMEOUT_S" "$PRUNE_MIN_S"
        run_step "$t_left" prune-packed --quiet; out="$STEP_OUT"; rc="$STEP_RC"
        if [ "$rc" -eq 124 ] && [ "$by_deadline" -eq 1 ]; then
          STATUS="deferred"; fast=0
          log "  prune-packed after batch $batches was cut by the run deadline after ${t_left}s — the budget ended, not a failure of prune-packed (the loose copies of what the batch packed stay on disk until a later batch or gc prunes them; nothing is lost)"
          break
        fi
        if [ "$rc" -ne 0 ]; then
          STATUS="failed"
          log "  prune-packed after batch $batches failed rc=$rc$([ "$rc" -eq 124 ] && echo " (timed out after ${t_left}s, its own cap)"): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
          break
        fi
        if ! measure; then STATUS="unmeasured"; break; fi
        # progress = fewer loose objects, OR a new pack whose loose copies are all gone (prune-packable 0): the exporter commits ~9
        # new loose objects while a batch runs, which at the minimum batch size (5) can leave the count level though the batch
        # packed 5 of them. A new pack alone is NOT proof: if prune-packed silently removes nothing (read-only remount, permissions)
        # every batch re-packs the same objects — the pack count rises, prune-packable stays > 0, and the run must stop as stalled.
        progressed=0
        if [ "$M_LOOSE_COUNT" -lt "$prev_count" ]; then progressed=1
        elif [ "$M_PACKS" -gt "$prev_packs" ] && is_uint "$M_PRUNABLE" && [ "$M_PRUNABLE" -eq 0 ]; then progressed=1; fi
        if [ "$progressed" -eq 0 ]; then
          STATUS="stalled"
          log "  batch $batches made no progress (loose objects $prev_count -> $M_LOOSE_COUNT, packs $prev_packs -> $M_PACKS, prune-packable ${M_PRUNABLE:-?})"
          break
        fi
        # "fast" is judged only for a batch that PACKED something: a batch that died at once or did nothing is the quickest one
        # there is, and crediting it doubled the remembered size on runs where nothing succeeded. It is judged only for a FULL-size
        # batch too — one that had at least R_BATCH unpacked objects to pack. The last batch of a drain is a REMAINDER (fewer objects
        # left than the batch size) that finishes at once whatever the size is: crediting it doubled the remembered size after two
        # batches that were each nearly too slow, and a batch that only pruned copies of objects already packed is the same
        # thing. Those leave `fast` as the last full batch set it. (The variable decided on must be the one acted on.)
        if [ -n "$prev_unpacked" ] && [ "$prev_unpacked" -ge "$R_BATCH" ]; then
          [ "$((took * 4))" -lt "$batch_left" ] && fast=1 || fast=0
        fi
      done
      [ "$STATUS" = ok ] && STATUS="packed-loose"
      # grow the remembered batch once, and only after a run that was still making progress (packed everything, or ran out of
      # budget while draining), with no timeout, whose last batch was fast. failed / stalled / timeout / unmeasured never grow it.
      case "$STATUS" in packed-loose|deferred) ;; *) fast=0 ;; esac
      if [ "$timeouts" -eq 0 ] && [ "$fast" -eq 1 ] && [ "$R_BATCH" -lt "$BATCH_MAX" ]; then R_BATCH=$(( R_BATCH * 2 > BATCH_MAX ? BATCH_MAX : R_BATCH * 2 )); fi
      R_BATCH_SAVE="$R_BATCH"
    fi
  fi

  # ── tier 2: too many packs → one consolidating gc, only with budget to finish ──
  measure || STATUS="unmeasured"
  if [ "$STATUS" != unmeasured ] && [ "$M_PACKS" -ge "$PACKS_LIMIT" ]; then
    need=$(( M_PACK_KIB + HEADROOM_KIB ))
    if [ "$(remaining)" -lt "$MIN_GC_BUDGET_S" ]; then
      bad_status "$STATUS" || STATUS="deferred"
      log "repo=$repo packs=$M_PACKS >= $PACKS_LIMIT but only $(remaining)s of budget left — gc deferred to the next run"
    elif disk_low "$repo" "$need"; then
      STATUS="skipped-low-disk"
      log "repo=$repo status=skipped-low-disk (gc) free=$(fmt "$(free_kib "$repo")") need~$(fmt "$need") packs=$M_PACKS"
    else
      # ONE REPACKER AT A TIME (header): another git process repacking this repo — the background run an exporter commit spawned — deletes the loose-*.pack batch packs under a
      # running gc, which then dies at its cruft pass with "could not find pack". Found, or cannot tell: the gc is not started. Like a busy gc.pid it did NOTHING, so it cannot turn a
      # failed / stalled / timed-out / unmeasured / skipped tier 1 into a green "busy"; the end state (pack alarm below) still judges the run.
      other_repacker "$repo"; orc=$?
      if [ "$orc" -eq 1 ]; then
        bad_status "$STATUS" || STATUS="busy"
        log "  gc not started: $OTHER_WHO is repacking $repo — two repackers at once make the gc fail with 'could not find pack' (ga-8z0hy7); retried next run"
      elif [ "$orc" -ne 0 ]; then
        bad_status "$STATUS" || STATUS="busy"
        log "  gc not started: cannot tell whether another git process is repacking $repo (no ps or lsof, one cut at its cap or failed, or a candidate lsof gave no directory for) — under doubt the gc waits; retried next run"
      else
        # the same rule as a batch: a kill at gc's OWN cap says the repo is too big for one gc; a kill at the end of the RUN's budget
        # says nothing about gc (the run that crosses PACKS_LIMIT is one whose tier 1 just spent part of the budget)
        budget_for "$GC_TIMEOUT_S"
        run_step "$t_left" -c gc.autoDetach=false gc --quiet; out="$STEP_OUT"; rc="$STEP_RC"
        if [ "$rc" -eq 0 ]; then STATUS="consolidated"
        elif [ "$rc" -eq 124 ] && [ "$by_deadline" -eq 1 ]; then
          # it did NOTHING useful (a killed gc keeps no packed work — and leaves a tmp_pack, which run_step has just reclaimed or the garbage measurement will report): it cannot turn a failed / stalled / timed-out / skipped tier 1 green
          bad_status "$STATUS" || STATUS="deferred"
          log "  gc was cut by the run deadline after ${t_left}s — the budget ended, not evidence the repo is too big for one gc (retried next run)"
        elif [ "$rc" -eq 124 ]; then STATUS="timeout"; log "  gc timed out after ${t_left}s (its own cap)"
        elif printf '%s' "$out" | grep -q 'already running'; then
          # it did NOTHING: it cannot turn a failed / stalled / timed-out / unmeasured / skipped tier 1 into a green "busy"
          bad_status "$STATUS" || STATUS="busy"
          log "  gc already running elsewhere — leaving it to finish"
        else STATUS="failed"; log "  gc failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; fi
      fi
    fi
  fi

  measure || STATUS="unmeasured"
  if is_uint "$M_LOOSE_KIB" && [ "$M_LOOSE_KIB" -lt "$before_loose" ]; then
    R_PROGRESS=1
    # ...but smaller than this run's START is not yet "draining": a backlog emptied more slowly than it refills shrinks a little
    # every run and still grows, so it must also be smaller than where the PREVIOUS run left it
    if [ -n "$prev_loose" ] && [ "$M_LOOSE_KIB" -ge "$prev_loose" ]; then
      R_PROGRESS=0
      log "  loose shrank this run ($(fmt "$before_loose") -> $(fmt "$M_LOOSE_KIB")) but is not below where the previous run left it ($(fmt "$prev_loose")) — the backlog is not draining, only refilling as fast as it is emptied"
    fi
  fi
  # garbage: what run_step reclaimed is gone. A garbage FILE the run ends with that it did not start with — a temp file that was kept (in use, or not provably unused), one a
  # step that ended 0 left behind, or one that reclaim_leak could not even look for because the object store could not be listed — is a leak nothing reclaimed, and BAD
  # whatever the status: a cut that leaked is not a clean cut. Files, not bytes: a leak is a NEW file (git gives every temp file a fresh random name; a tmp_pack killed before
  # it wrote a byte is a 0KiB file that still counts), while bytes growing in a garbage file that was already there are somebody else's live writer, not this run's leak.
  # An unmeasured end (status unmeasured, already BAD) leaves R_GARBAGE_GREW at 0.
  if is_uint "$M_GARBAGE_COUNT" && is_uint "$before_gcount" && [ "$M_GARBAGE_COUNT" -gt "$before_gcount" ]; then
    R_GARBAGE_GREW=1
    log "  garbage grew this run ($R_GARBAGE_BEFORE -> $M_GARBAGE_COUNT file(s), $(fmt "$M_GARBAGE_KIB")): a temp file a killed or failed step left that nothing reclaimed — BAD whatever the status"
  fi
  G_KIB="$(gitdir_kib)"
  log "repo=$repo status=$STATUS loose=$(fmt "$before_loose")->$(fmt "$M_LOOSE_KIB") packs=${before_packs}->${M_PACKS:-?} packed=$(fmt "$before_kib")->$(fmt "$M_PACK_KIB") garbage=${before_gcount}f/$(fmt "$before_gkib")->${M_GARBAGE_COUNT:-?}f/$(fmt "$M_GARBAGE_KIB") .git=$(fmt "$G_KIB") batches=$batches batch=${R_BATCH} elapsed=$(( $(date +%s) - t0 ))s"
}

# ── single-flight (check mode is read-only and skips it) ──
# The lock records its owner's pid. A run SIGKILLed by the order's timeout never runs its EXIT
# trap, and an age-only rule would then skip every run for the next 90 minutes with exit 0 — a
# quiet gap in the one job this is. So a lock is stale as soon as its owner is dead (with a
# 1-minute floor for the instant between another run's mkdir and its pid write), or — when the
# owner still looks alive — after LOCK_STALE_MIN (a hung run).
#
# THREE outcomes, never two. This used to be "mkdir; if it failed, somebody else has the lock", so every OTHER reason mkdir can fail (the path
# is a file, the parent is read-only, no space) read as "another run is in flight" and exited 0: no compaction, no state, no alarm, an order
# that looks green while the backlog grows ~5GiB/day — the incident, through another door. Now:
#   this run holds the lock                                                          → go on
#   another run holds it, as far as anything can show: its lock DIRECTORY exists and is not stale (that includes the first minute after a
#   run died, before it counts as stale — bounded, and the next run reclaims it), or another run took it in the instant after this one
#   removed a stale one                                                              → exit 0, "in flight": the only quiet no-op there is
#   anything else (cannot create it, cannot remove a stale one, cannot read its age, cannot record our pid) → exit 1, and the log says which
# Known and accepted: the reclaim of a stale lock is check-then-act (lock_release, then mkdir). Two runs that both saw the same stale lock can each
# pass lock_release, the second removing the first's fresh lock, so both hold it. That takes two runs within about a second — the order is one
# instance whose interval (30m) exceeds its timeout (900s), so it needs a manual run racing a tick — and what two runs can then do to one repo is
# limited by git's own locks: a second gc is refused (gc.pid, selftest S8) and a second `maintenance run` skips its task (maintenance.lock).
lock_owner_alive() { local p; p="$(cat "$LOCK/pid" 2>/dev/null)"; is_uint "$p" && kill -0 "$p" 2>/dev/null; }
lock_older_than() {  # lock_older_than <minutes> — 0 = older, 1 = not older, 2 = could not tell (find failed): never "not older"
  local o
  o="$(find "$LOCK" -maxdepth 0 -mmin +"$1" 2>/dev/null)" || return 2
  [ -n "$o" ]
}
# lock_is_stale — 0 = stale (reclaim it), 1 = a live run's lock (yield to it), 2 = cannot tell (an age could not be read, and nothing else proved it stale)
lock_is_stale() {
  local old_hung old_dead
  lock_older_than "$LOCK_STALE_MIN"; old_hung=$?
  if [ "$old_hung" -eq 0 ]; then return 0; fi
  if ! lock_owner_alive; then
    lock_older_than 1; old_dead=$?
    if [ "$old_dead" -eq 0 ]; then return 0; fi
    if [ "$old_dead" -eq 2 ]; then return 2; fi
  fi
  if [ "$old_hung" -eq 2 ]; then return 2; fi
  return 1
}
# lock_release — 0 = the lock is gone (removed, or already gone), 1 = it is still there. What matters is the existence check on the last line.
# benign[lock-release]: the rm/rmdir errors are discarded because this function's own result is whether the lock still exists, tested right after them
lock_release() { rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; }
release_at_exit() { lock_release || log "WARNING: could not remove the lock $LOCK at exit — the next run reclaims it once this pid is gone, and fails loudly if that fails too"; }
take_lock() {  # returns 0 holding the lock; every other outcome EXITS, as above
  local err st
  # benign[lock-parent-mkdir]: if the parent cannot be made, the mkdir of the lock right below fails too and reports the real reason
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  if ! err="$(mkdir "$LOCK" 2>&1)"; then
    if [ ! -d "$LOCK" ]; then
      log "could not create the lock $LOCK: ${err:-no output} — NOT compacting. Nothing else holds it, so this is a failure and every run will fail the same way until it is fixed"
      exit 1
    fi
    lock_is_stale; st=$?
    if [ "$st" -eq 1 ]; then
      log "another compaction run is in flight — exit (single-flight)"; exit 0   # benign[lock-inflight]: the lock directory of another run exists and is neither stale nor unreadable — the one reason to leave without compacting and without a failure
    elif [ "$st" -ne 0 ]; then
      log "cannot tell whether the lock $LOCK is stale (its age could not be read — or its holder released it just now) — NOT compacting: a live run and a stale lock look the same from here; the next run decides"
      exit 1
    fi
    log "stale lock (owner gone, or older than ${LOCK_STALE_MIN}m) — reclaiming"
    if ! lock_release; then
      log "could not remove the stale lock $LOCK — NOT compacting. Every later run would meet the same lock, so this is a failure to fix, not a run to wait for"
      exit 1
    fi
    if ! err="$(mkdir "$LOCK" 2>&1)"; then
      if [ -d "$LOCK" ]; then
        log "another run took the lock right after this one removed the stale one — exit (single-flight)"; exit 0   # benign[lock-lost-race]: the stale lock WAS removed and a different run created its own in the gap; that run is the one compacting
      fi
      log "could not create the lock $LOCK after removing a stale one: ${err:-no output} — NOT compacting"
      exit 1
    fi
  fi
  if ! printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; then
    # a lock with no owner pid looks dead after one minute: a second run would reclaim it while this one still works
    log "could not record this run's pid in $LOCK/pid — releasing the lock and NOT compacting (an ownerless lock would be reclaimed as stale while this run still worked)"
    lock_release || log "  ...and the lock itself could not be removed either ($LOCK) — remove it by hand"
    exit 1
  fi
  trap release_at_exit EXIT
}
if [ "$MODE" = run ]; then
  command -v jq >/dev/null 2>&1 || { echo "jsonl-archive-compact: jq is required but not found in PATH" >&2; exit 1; }
  take_lock
fi

if [ "$MODE" = run ] && [ -z "$_timeout_bin" ]; then
  log "WARNING: no timeout/gtimeout on PATH — batches, prune, gc and the alarm mail are NOT time-bounded (only the order's own kill limits a run), and batch sizing cannot adapt (it reacts to timeouts)"
fi
if [ "$MODE" = run ] && why="$(state_problem)"; then
  log "state file $STATE is unreadable — starting fresh: $why (bad-run streaks and remembered batch sizes reset)"
fi

# The FIRST repo in $REPOS is the PRIMARY: the archive the exporter writes and dolt-s3-backup.sh mirrors. It may not be missing — with the
# retired archive still on disk, "absent — skipped" + exit 0 made a vanished primary read as a healthy run. A later (retired) one may be gone.
PRIMARY=1; ABSENT_PRIMARY=0; CHECK_FAIL=0; CHECK_SIZE=0
for repo in $REPOS; do
  if [ ! -d "$repo/.git" ]; then
    if [ "$PRIMARY" -eq 1 ]; then
      ABSENT_PRIMARY=1
      log "repo=$repo is the PRIMARY archive and it is absent — NOT compacted (moved or deleted?): a leftover retired archive must not make that look like a healthy run"
    else
      log "repo=$repo absent — skipped (a retired archive may be gone)"
    fi
    PRIMARY=0; continue
  fi
  PRIMARY=0
  EXISTING=$((EXISTING + 1))
  compact_repo "$repo"
  if [ "$MODE" = check ]; then
    if [ "$STATUS" = unmeasured ]; then CHECK_FAIL=1; elif is_bad "$STATUS"; then CHECK_SIZE=1; fi
    continue
  fi
  record "$repo" "$STATUS" || BAD_ANY=1
done

if [ "$EXISTING" -eq 0 ]; then
  log "no archive repo found under: $REPOS — nothing was compacted (a misconfigured path must not look like a healthy run)"
  exit 1
fi
# exit code: 0 healthy; 1 a failure (cannot measure, a run failed, the primary is absent); 3 (--check only) measured, over the alarm size, and no
# fresh verdict of the order excuses it. There is no literal success exit here on purpose: the code is computed from everything above.
RC=0
if [ "$MODE" = check ]; then
  if [ "$CHECK_FAIL" -eq 1 ] || [ "$ABSENT_PRIMARY" -eq 1 ]; then RC=1; elif [ "$CHECK_SIZE" -eq 1 ]; then RC=3; fi
elif [ "$BAD_ANY" -eq 1 ] || [ "$ABSENT_PRIMARY" -eq 1 ]; then
  RC=1
fi
exit "$RC"
