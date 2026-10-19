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
#   2a. the TAIL (ga-3sf9r8), by BYTES held by SMALL packs and not by how many packs there are: when the small packs the batches left hold >= JAC_TAIL_LIMIT_KIB (256MiB), up to
#      JAC_TAIL_MAX_OBJECTS (120) objects of them, smallest packs first, become ONE pack with the deltas recomputed (`repack -a -d -f --depth=250 --cruft`), and every other pack — the big
#      old one above all — is passed as --keep-pack and never read or written. MEASURED 15/10 on the real archive: .git was 5.26GiB, 3.84GiB (73%) of it ONE file's history
#      (whatsapp_automation/comments.jsonl, 59MB x 7809 versions): 384 versions (5%) were stored at 10-18MB each — a compressed near-full copy — and the other 7425 cost ~1KiB. git cannot
#      delta ACROSS packs, so every batch pack (tier 1: 5-40 objects) carries its own first copy ("seed") of every giant file, 80-118MB per pack; 406MiB of loose objects became +311MiB
#      of pack (77% kept; a delta would keep ~0.1%). The consolidators this script had do not undo that: a `gc` without -f reuses the stored representations (14/10: -225MiB on 5GiB) and
#      needs the WHOLE pack size free (~5.2GiB on a disk with 1-5GiB: skipped-low-disk 13/10 and 15/10), git's own geometric repack merges packs without recomputing a single delta (it is how
#      a 378MB pack was born), and tier 2 only fires at 8 packs (there were 3). Repacking just the small packs with -f collapses N seeds into one (synthetic 58MB history, 12 versions:
#      19s, 1 seed + 11 deltas of ~5KiB, vs 81s for the first loose->pack conversion), needs only the SMALL packs' size free, and its cost is bounded by objects (the delta search),
#      not by the size of the archive. A pack it grew to the cap is left alone by the next pass (it no longer fits), so history costs one seed per ~120 objects instead of one per batch.
#      It never starts while loose bytes are still over the loose limit (`repack -a` would pack those too, an amount of work the object cap does not bound: tier 1 drains them first), nor
#      while another git process is repacking the repo (ONE REPACKER AT A TIME, below), and it takes a pack only when it can count its objects from the .idx (cruft packs, .keep packs and
#      packs it cannot read stay kept). Status: `consolidated` when it ended 0 and nothing before it had failed (the tail never overwrites a failure with a green); a pass that did NOTHING (busy,
#      cut by the run deadline, not started) never launders a failure; its own cap running out is `timeout`, a repack that ended non-zero is `failed`. One exception, on purpose: tier 2 below judges
#      the END state, so when the packs are still >= JAC_PACKS_LIMIT after the tail and its gc then ends 0, that gc sets `consolidated` over whatever the tail (or tier 1) left — it rewrites
#      every pack the tail would have merged — and the tail's failure survives in the log only. The disk it needs is the small packs' size + a quarter of the loose
#      bytes + the headroom, else `skipped-low-disk`; and what is left AFTER the pass (free − that need) must still be outside Dolt's CRITICAL class (ga-q8z86s): dolt-disk-floor-guard calls the disk
#      critical when the free GiB, rounded down, is <= DOLT_DISK_FLOOR_CRITICAL_GB (3), so the pass needs free − need >= (that + 1) GiB. This script reads the same variable with the same default (a
#      selftest compares the default with the guard's); a free-space reading or a floor that is not a number is `skipped-low-disk` too — the pass does not start on a disk it cannot judge. 17/10
#      the pass wrote ~800MB of temp files every run with the disk under that floor, and Dolt took ENOSPC.
#      The pass ADAPTS (ga-q8z86s). Its object cap is per repo, kept in the state file next to tier 1's batch size (`tail_objects`, at most JAC_TAIL_MAX_OBJECTS). A pass cut by its OWN cap (600s;
#      not by the run's deadline) writes nothing — a killed repack keeps no packed work — so repeating it unchanged is the same 600s and the same temp files again, every run, for nothing: the next
#      pass takes at most HALF the objects the cut one took (never below JAC_TAIL_MIN_OBJECTS, 15; at that floor it can only repeat, and the log says so). A pass that finished in under a
#      quarter of its budget while the cap kept a pack out that the configured cap would have taken doubles the cap again, up to JAC_TAIL_MAX_OBJECTS — tier 1's rule. The byte trigger scales with the
#      cap (JAC_TAIL_LIMIT_KIB at the full cap), because a half-size pass holds about half the bytes and would otherwise never start, and so never grow back. A lowered cap can still leave NO two
#      packs that fit (similar packs, each over half the cap): then the pass waits, with the reason in the log each run, and the cap is doubled once JAC_TAIL_RETRY_S (6h) has passed since the last cut
#      (`tail_cut_epoch`) — a slow spell that has gone is retried, and a host that stays slow costs one cut per that interval from this retry, not one per run (at the floor itself a cut pass can only repeat, as said above).
#   2b. the ROOM PASS (ga-978f1y), the way out of a deadlock. Tier 2's gc is gated twice on a rewrite of EVERY pack: the window's lib wants free >= the largest pack + 2GiB (6.6GB with the 4.5GB pack), and
#      compact_repo's disk_low wants all the packs + headroom (~10.3GB). The mini sits at 5-6GB free, so neither could ever pass: 48 runs deferred (bad_streak 48-49), 56 packs, 10GB,
#      and the disk never went down. The room pass is what runs INSTEAD, only when the window is OPEN (00:00-04:59, a clock that can be read) and one of those two gates said no: `repack -a -d -l -f --cruft` over
#      as many of the SMALLEST packs as the room holds, with every other pack — the largest above all, always — as --keep-pack, so the 4.5GB pack is never read or written and the pass needs only the picked packs' size free.
#      Packs with a .mtimes (cruft), a .keep, an .idx it cannot count or a size it cannot read are kept too. "Room" = free − Dolt's floor ((DOLT_DISK_FLOOR_CRITICAL_GB + 1) GiB) − headroom − a quarter of the loose
#      bytes; the picked packs must fit in it, and so must the pass's cap. At least two packs are picked or the pass is not started (the log says why each run) — one pack alone gains nothing. Its cap is adaptive,
#      like tier 2a's, per repo in the state (`room_kib`: the most KiB of packs a pass takes; starts at JAC_ROOM_START_KIB 256MiB, grows by doubling up to JAC_ROOM_MAX_KIB 1GiB after a pass that finished in under a
#      quarter of its budget while the cap had left a pack out, halves down to JAC_ROOM_MIN_KIB 64MiB after a cut). The first two packs are taken within the room even above the cap, so a repo whose small packs are all
#      big still moves. It never runs while loose bytes are over the loose limit (tier 1 first), while another git repacks the repo, or without budget (`deferred`).
#      WHY IT IS WATCHED. The measured limit of the mini is not pack space, it is RAM→swap (Mayor, 19/10 08:57Z): a manual `repack -a -d --keep-pack=<largest>` with threads=2, windowMemory=256m, deltaCacheSize=128m at
#      nice 10 grew swap 4096→6144MB, free disk fell 5133→2998MB — already inside Dolt's CRITICAL class — and a floor watchdog killed it after 28 min with a 224MB temp pack. macOS keeps its swap files on the same volume
#      as the archive and Dolt, so swap growth IS disk loss, and a floor on free disk alone looks too late. So the pass runs smaller (threads 1, windowMemory 128m, deltaCacheSize 32m — JAC_ROOM_*) AND under a
#      watchdog (run_step with WATCH_ON): every JAC_WATCH_INTERVAL_S (10s) it reads free disk and swap in use (`sysctl -n vm.swapusage`) and STOPS the step — TERM to the whole process tree, KILL for what is alive after
#      JAC_WATCH_KILL_GRACE_S (5s) — when free disk falls below Dolt's floor + JAC_WATCH_SLACK_KIB (256MiB), when swap in use grows more than JAC_WATCH_SWAP_MAX_KIB (512MiB) past where it stood at the START of the
#      pass, or when JAC_WATCH_BLIND_MAX (3) looks in a row could not read one of the two. Unreadable free disk, swap or floor BEFORE the start = the pass does not start (the usual THREE STATES rule: not knowing is
#      not "fine"); an unusable JAC_ROOM_* / JAC_WATCH_* setting turns the pass OFF with the reason in the log, and the lib's old verdict stands (deferred / skipped-low-disk).
#      Status: a watchdog stop is `aborted` — a failure (bad_status, exit 1, LOUD, the log says which reading tripped it), because it means this host did not have the room the pass thought it had. The cap halves and the pass
#      waits JAC_ROOM_RETRY_S (2h, `room_cut_epoch` in the state) before the next, so a host that keeps tripping costs one stopped pass per interval, not one per run. A pass cut at its own cap (JAC_ROOM_TIMEOUT_S,
#      40 min) is `timeout` (same shrink and wait); at the run's / the night window's end `deferred`, no shrink; a repack that ended non-zero `failed` (same wait); rc 0 `consolidated`. Like every other step it goes
#      through run_step, so a stopped or failed pass has its temp files reclaimed by the LEAKS rules. Nothing here deletes history: --keep-pack never drops a pack, and the pass is a repack, not a prune.
#      NOT VALIDATED ON THE REAL ARCHIVE: the thresholds are defaults, not measurements (swap noise of ±1.3GiB between runs was seen on 19/10, so 512MiB may false-trip — the log then says "swap in use grew" and the
#      next pass is smaller). The first night's log is the evidence. Moving the archive off the mini (the Mayor's option b) was judged out of scope here.
#   2. pack count >= JAC_PACKS_LIMIT (8): one full `git gc` to consolidate. Each batch pack
#      carries its own first full copy of every big file (batches cannot delta against earlier
#      packs); the gc re-deltas those against the whole history and merges the packs. The alarm judges
#      the END state, so a gc that succeeds clears a failed tier 1 (it packs the loose objects too); a gc
#      that did NOTHING (busy, or killed) never launders one: only a status that is not a failure on its own
#      (bad_status: failed / stalled / timeout / aborted / unmeasured / skipped-low-disk) can be replaced by `busy` or
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
# times in the log, on a 4GiB repo), so it must not be switched off for good — and since ga-wkoij7 it is not: it is confined to the 00:00-04:59 start window with room on the disk
# (WINDOW below), where the exporter still asks for it. The rule against the two colliding: never two repackers at once, from both sides.
#   1. This script, before it starts the consolidating gc, looks for another git process repacking the repo (other_repacker: ps for this user's git maintenance/repack/gc/
#      pack-objects/... processes, then lsof for the working directory of each — a detached run keeps the directory of the commit that spawned it). Found = the gc is NOT started: status `busy`
#      (a failed/stalled/timed-out/unmeasured/skipped state is never replaced by it, same rule as a busy gc.pid), the log names the process. Cannot tell (no ps/lsof, either cut at
#      its cap, a candidate lsof gave no answer for) = the gc is not started either — under doubt the inert state — and the log says so. The END state still judges the run: a
#      repo that stays over the pack alarm is BAD whatever the status, so a gc that is deferred forever is not silent.
#   2. The exporter, whose commits are what spawn that run, commits with maintenance.auto=false while this script's lock is held (jsonl-export.sh, commit_archive_snapshot): no
#      new background repack can start during a compaction run. When the run ends the exporter goes back to the window rule (WINDOW below), so this lock only delays git's
#      consolidation, it never removes it.
# WINDOW (ga-wkoij7): on 17/10 ~10:4x the exporter's commit started git's geometric repack of the 4.4GB pack at midday (pack-objects 1.8GB of RAM, swap 5.2GB, free disk 1.4GB). Athos
# decided (15/10) that the heavy maintenance runs only in 00:00-06:00. So the tier-2 consolidating gc — a rewrite of every pack, the other whole-repo repack of this city — starts only when
# jaw_repack_allowed says so (jsonl-archive-repack-window-lib.sh: local hour in [0,5) AND free disk >= JAC_GC_PACK_FACTOR (1) x the largest pack + 2GiB — the Mayor's rule for this gc; the exporter's
# detached repack keeps 2 x; a clock or a df that cannot be read = no; disk_low below still asks for ALL the packs + headroom): outside that
# it is `deferred` and logged with the reason, like a gc without budget — never a failure by itself, and never silent, because the pack alarm still judges the END state (>= JAC_PACKS_ALARM
# packs = BAD whatever the status). INSIDE the window, a gc that the room refuses — the lib's rule or disk_low — is not the end of it: the room pass (tier 2b, ga-978f1y) is tried in its place, the largest pack kept. Tier 1 (loose-objects batches) and tier 2a (the tail repack, `--keep-pack` on the big packs) are NOT gated on purpose: they are bounded by objects and by
# pack.windowMemory, leave the big packs alone, and the loose backlog (~243MiB/h) has to be packed by day or the disk fills. A known cost of leaving tier 2a ungated: on 17/10 it
# hit its own 600s cap at 13:13Z and 14:19Z (pack-objects paged out at ~1% CPU, 4.7GB of swap in use), so by day it can burn the cap and produce nothing; confining it to the
# window would let the small packs pile up toward JAC_PACKS_ALARM instead — a trade-off left to the Mayor (ga-wkoij7), not decided here.
# THE NIGHT GC IS NOT HELD TO 600s (ga-wkoij7, Mayor): the 600s cap killed this gc three runs in a row on the 6.5GB archive (9 packs, 285MiB loose), and a killed gc keeps nothing — while 26/09 the
# same gc took 36 minutes for 6GB. So inside the window (night_gc_extend) the gc gets the time left until 06:00 less JAC_NIGHT_MARGIN_S (300s, so its cleanup and the alarm are done by 06:00),
# at most JAC_NIGHT_GC_MAX_S (21600; 0 = no extension, the 600s cap as before); it still runs under `nice -n 10`. The run's deadline moves with it for the length of the gc only (restored right
# after: the next repo gets what is left of the ordinary budget, i.e. none), the order's timeout is 21900s to cover it, and the lock records the run's end ($LOCK/until) so the next 30-minute
# ticks do not take a 90-minute-old lock from a gc that is still working (lock_is_stale): they exit 0 "in flight". If the lock cannot record that end, the gc keeps its 600s cap — never a long
# gc whose lock another run can reclaim. A gc killed at ITS night cap is `timeout` (evidence: the window is not enough), not `deferred`. By day nothing changes: 780s deadline, 900s of worst case.
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
# failed / could not measure / was skipped for low disk / stalled / was stopped by the room pass's watchdog (`aborted`) / timed out at the minimum
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
# CADENCE: order jsonl-archive-compact, interval 30m, timeout 21900s; JAC_DEADLINE_S (780s) is
# this script's own budget by day, so it can log its outcome long before the order's timeout fires (the 21900s is for the night gc: 6h window + 5min). One
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
# the gate reported the leak for the batch, and measured on this host's git the gc leaks the same way; the tail repack (tier 2a) is the fourth and the room pass (tier 2b, the only one run under the watchdog) the fifth — a sixth would be one more thing that can be killed mid-write.
#
# TEST: bash packs/town-deltas/assets/scripts/jsonl-archive-compact.selftest.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"

# The repack window and the room a whole-repo repack needs (ga-wkoij7), shared with jsonl-export.sh so the two cannot disagree. Failing to load it is a failure, not "no gate":
# a gate that is silently absent would let the gc run at noon again.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# (-r first: bash 3.2 ends a non-interactive shell at a `.` of a missing file before any `||` or `if !` can answer, and the message below is the one that names the cause)
if ! { [ -r "$SCRIPT_DIR/jsonl-archive-repack-window-lib.sh" ] && . "$SCRIPT_DIR/jsonl-archive-repack-window-lib.sh"; }; then
  echo "jsonl-archive-compact: cannot load $SCRIPT_DIR/jsonl-archive-repack-window-lib.sh — without it the consolidating gc cannot tell whether it may start" >&2
  exit 1
fi

# The two archives. maintenance/ is the one dolt-s3-backup.sh mirrors offsite and the one the
# per-rig mol-dog-jsonl instances write; town-deltas/ is the city-scope instance's and is being
# retired by ga-7sxdmb (left in place, no longer written) — a missing repo is fine as long as
# at least one exists.
REPOS="${JAC_REPOS:-$RUNTIME/packs/maintenance/jsonl-archive $RUNTIME/packs/town-deltas/jsonl-archive}"
LOOSE_LIMIT_KIB="${JAC_LOOSE_LIMIT_KIB:-262144}"     # 256MiB of loose objects triggers a batch pack
LOOSE_ALARM_KIB="${JAC_LOOSE_ALARM_KIB:-1048576}"    # 1GiB still loose after a run = BAD, unless the run really shrank it (a backlog draining, see ALARM)
PACKS_LIMIT="${JAC_PACKS_LIMIT:-8}"                  # this many packs triggers the consolidating gc
PACKS_ALARM="${JAC_PACKS_ALARM:-20}"                 # this many after a run = BAD (git's own autoPackLimit is 50)
TAIL_LIMIT_KIB="${JAC_TAIL_LIMIT_KIB:-262144}"       # tier 2a: small packs holding this many bytes trigger the tail pass (256MiB; 0 = off)
TAIL_MAX_OBJECTS="${JAC_TAIL_MAX_OBJECTS:-120}"      # ...which takes at most this many objects per pass: the cost of `repack -f` is the delta search, so the pass is bounded by objects
TAIL_TIMEOUT_S="${JAC_TAIL_TIMEOUT_S:-600}"          # per tail pass (a 58MB blob costs ~1.6s per version to re-delta on this host: 120 objects is minutes at most, under load)
TAIL_WINDOW="${JAC_TAIL_WINDOW:-10}"                 # pack-objects --window: a small window — the versions of one file are neighbours
TAIL_DEPTH="${JAC_TAIL_DEPTH:-250}"                  # pack-objects --depth: the default (50) leaves one seed per 50 versions (~156 x 12MB on the WA comments); 250 leaves ~31
TAIL_MIN_OBJECTS="${JAC_TAIL_MIN_OBJECTS:-15}"       # the floor of the adaptive object cap: a cut pass is followed by one with half its objects, never fewer than this (or than the configured max, if that is lower)
TAIL_RETRY_S="${JAC_TAIL_RETRY_S:-21600}"            # a cap lowered by a cut that leaves no two packs to merge is doubled once this long has passed since the cut (6h)
DOLT_CRIT_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-3}"     # Dolt's CRITICAL disk class (dolt-disk-floor-guard.sh: free whole GiB <= this): the tail pass must leave the disk above it. Same variable, same default as the guard (a selftest compares them)
BATCH_OBJECTS="${JAC_BATCH_OBJECTS:-60}"             # starting batch (~7 commits, ~300MiB loose); adapts, see header
BATCH_MIN=5
BATCH_MAX="${JAC_BATCH_MAX:-200}"
MAX_BATCHES="${JAC_MAX_BATCHES:-0}"                  # 0 = as many as the deadline allows
GIT_TIMEOUT_S="${JAC_GIT_TIMEOUT_S:-300}"            # per batch
GC_TIMEOUT_S="${JAC_GC_TIMEOUT_S:-600}"              # per consolidating gc, outside the night window (inside it: NIGHT_GC_MAX_S)
NIGHT_GC_MAX_S="${JAC_NIGHT_GC_MAX_S:-21600}"        # the most the gc may run INSIDE the repack window (the window is 6h); 0 = never longer than GC_TIMEOUT_S
NIGHT_MARGIN_S="${JAC_NIGHT_MARGIN_S:-300}"          # ...stopped this long before the window closes, so the cleanup after a cut gc is done by 06:00
GC_PACK_FACTOR="${JAC_GC_PACK_FACTOR:-1}"            # free disk for the gc must be >= this x the largest pack + 2GiB (the Mayor's rule, ga-wkoij7); the exporter's own repack uses the lib's default (2)
# Tier 2b, the ROOM PASS (header, ga-978f1y): when the window is open but the disk has no room for the whole-repo gc, a smaller repack with the LARGEST pack kept. DEFAULTS CHOSEN WITHOUT A MEASUREMENT ON THE REAL ARCHIVE —
# the first night's log (and the watchdog's lines in it) is the evidence to tune them by; every one is an env var for that.
ROOM_START_KIB="${JAC_ROOM_START_KIB:-262144}"       # the first pass takes packs holding at most this much (256MiB: the 28 min the Mayor's manual run lasted wrote 224MB of temp pack before it was killed)
ROOM_MAX_KIB="${JAC_ROOM_MAX_KIB:-1048576}"          # ...and the cap never grows past this (1GiB)
ROOM_MIN_KIB="${JAC_ROOM_MIN_KIB:-65536}"            # ...nor shrinks below this after a cut (64MiB; a pass always takes the two smallest packs if the room holds them, whatever the cap)
ROOM_TIMEOUT_S="${JAC_ROOM_TIMEOUT_S:-2400}"         # one room pass is cut at this (40 min), or at the night window's end / the run's budget, whichever is first
ROOM_RETRY_S="${JAC_ROOM_RETRY_S:-7200}"             # after a pass was cut (watchdog or timeout) the next waits this long (2h)
ROOM_THREADS="${JAC_ROOM_THREADS:-1}"                # pack.threads of the room pass (the by-day repacks use 2)
ROOM_WINDOW_MEM="${JAC_ROOM_WINDOW_MEM:-128m}"       # pack.windowMemory (by day: 256m)
ROOM_DELTA_CACHE="${JAC_ROOM_DELTA_CACHE:-32m}"      # pack.deltaCacheSize (by day: 64m)
# The WATCHDOG over a room pass (header): polled while the step runs; ends it, with every process under it, when free disk falls below Dolt's floor + slack, when swap grows past a budget, or when either reading is lost.
WATCH_INTERVAL_S="${JAC_WATCH_INTERVAL_S:-10}"       # seconds between two looks (a decimal is fine: sleep takes it)
WATCH_SWAP_MAX_KIB="${JAC_WATCH_SWAP_MAX_KIB:-524288}"   # swap in use may grow this much (512MiB) above where it stood when the pass started. The Mayor's manual run grew it 2048MiB (4096 -> 6144) in 28 min
WATCH_SLACK_KIB="${JAC_WATCH_SLACK_KIB:-262144}"     # free disk must stay this far (256MiB) ABOVE Dolt's floor: the watchdog looks every WATCH_INTERVAL_S, and a pass writes and swaps faster than that
WATCH_BLIND_MAX="${JAC_WATCH_BLIND_MAX:-3}"          # this many looks in a row that could not read free disk or swap end the pass: a watchdog that cannot see is not a watchdog
WATCH_KILL_GRACE_S="${JAC_WATCH_KILL_GRACE_S:-5}"    # TERM first, KILL for what is still alive after this long
LOCK_GRACE_S=600                                     # a run that wrote its end time (night gc) is still alive this long after it
DEADLINE_S="${JAC_DEADLINE_S:-780}"                  # whole run by day; the order's timeout is 21900s (a night gc lasts hours, see "THE NIGHT GC")
DEADLINE_BASE="$DEADLINE_S"                          # night_gc_extend moves DEADLINE_S for the length of the gc and puts it back here
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
SYSCTL="${JAC_SYSCTL:-}"                             # test seam; empty = the first sysctl on PATH, else /usr/sbin/sysctl (where swap in use is read from, for the room pass's watchdog)
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
JAW_LOG="${JAW_LOG:-$CITY/.gc/logs/jsonl-archive-repack-window.log}"   # the repack window's own decisions (ga-wkoij7); the lib writes it, this log keeps the run's line
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
tail_limit_kib=$TAIL_LIMIT_KIB tail_max_objects=$TAIL_MAX_OBJECTS tail_timeout_s=$TAIL_TIMEOUT_S tail_window=$TAIL_WINDOW tail_depth=$TAIL_DEPTH
tail_min_objects=$TAIL_MIN_OBJECTS tail_retry_s=$TAIL_RETRY_S dolt_critical_gb=$DOLT_CRIT_GB
git_timeout_s=$GIT_TIMEOUT_S gc_timeout_s=$GC_TIMEOUT_S prune_timeout_s=$PRUNE_TIMEOUT_S prune_min_s=$PRUNE_MIN_S deadline_s=$DEADLINE_S min_batch_s=$MIN_BATCH_S
list_timeout_s=$LIST_TIMEOUT_S lsof_timeout_s=$LSOF_TIMEOUT_S reclaim_wait_s=$RECLAIM_WAIT_S ps_timeout_s=$PS_TIMEOUT_S
alert_after=$ALERT_AFTER alert_every_s=$ALERT_EVERY_S mail_timeout_s=$MAIL_TIMEOUT_S check_fresh_s=$CHECK_FRESH_S
repack_window_start_h=$JAW_START_H repack_window_last_start_h=$JAW_LAST_START_H repack_window_end_h=$JAW_END_H repack_swap_headroom_kib=$JAW_SWAP_KIB repack_window_log=$JAW_LOG
night_gc_max_s=$NIGHT_GC_MAX_S night_margin_s=$NIGHT_MARGIN_S gc_pack_factor=$GC_PACK_FACTOR
room_start_kib=$ROOM_START_KIB room_max_kib=$ROOM_MAX_KIB room_min_kib=$ROOM_MIN_KIB room_timeout_s=$ROOM_TIMEOUT_S room_retry_s=$ROOM_RETRY_S
room_threads=$ROOM_THREADS room_window_memory=$ROOM_WINDOW_MEM room_delta_cache=$ROOM_DELTA_CACHE
watch_interval_s=$WATCH_INTERVAL_S watch_swap_max_kib=$WATCH_SWAP_MAX_KIB watch_slack_kib=$WATCH_SLACK_KIB watch_blind_max=$WATCH_BLIND_MAX watch_kill_grace_s=$WATCH_KILL_GRACE_S
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
R_PACK_EXTRA=()      # more `-c` settings for the NEXT git_arch, after the defaults below so that they win (git takes the last value): the room pass sets leaner pack.* here and empties it afterwards
git_arch() {  # git_arch <seconds> <git args...>   — uses $R_GITDIR and the repo's current batch size $R_BATCH
  local t="$1"; shift
  _bounded "$t" "$GITBIN" --git-dir="$R_GITDIR" \
    -c pack.threads=2 -c pack.windowMemory=256m -c pack.deltaCacheSize=64m \
    -c maintenance.loose-objects.batchSize="${R_BATCH:-$BATCH_OBJECTS}" ${R_PACK_EXTRA[@]+"${R_PACK_EXTRA[@]}"} "$@"
}

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# bad_status <status> — a status that is a failure on its own. A step that did NOTHING (gc busy, a step cut by the run
# deadline) may only replace a status that is NOT one of these: the failure it carries is still true.
bad_status() { case "$1" in failed|unmeasured|skipped-low-disk|stalled|timeout|aborted) return 0 ;; esac; return 1; }
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
# night_gc_extend — called when jaw_repack_allowed said yes: the gc is not held to GC_TIMEOUT_S inside the window ("THE NIGHT GC" in the header). Sets GC_CAP (what budget_for gets): the time left until the
# window closes, less NIGHT_MARGIN_S, at most NIGHT_GC_MAX_S. When that is longer than GC_TIMEOUT_S it also moves DEADLINE_S to now + GC_CAP + NIGHT_SLACK_S (the slack covers the looks between here and the gc, so the
# cap — not the run's budget — is what ends it: a kill at the cap is `timeout`, evidence the window is not enough) and has the lock record that end. The caller puts DEADLINE_S back. Every doubt — a setting
# that is not a number, a clock that cannot be read, a lock that cannot record the end — leaves GC_CAP at GC_TIMEOUT_S and DEADLINE_S alone, and the log says which: the inert state is the old cap.
NIGHT_SLACK_S=120
night_gc_extend() {
  local left cap
  GC_CAP="$GC_TIMEOUT_S"
  if ! { is_uint "$NIGHT_GC_MAX_S" && is_uint "$NIGHT_MARGIN_S"; }; then
    log "  night gc: JAC_NIGHT_GC_MAX_S='$NIGHT_GC_MAX_S' or JAC_NIGHT_MARGIN_S='$NIGHT_MARGIN_S' is not a number — the gc keeps its ${GC_TIMEOUT_S}s cap"
    return 0
  fi
  if ! left="$(jaw_window_left_s)"; then
    log "  night gc: cannot tell how long the repack window lasts (clock unreadable, or it closed meanwhile) — the gc keeps its ${GC_TIMEOUT_S}s cap"
    return 0
  fi
  cap=$(( left - NIGHT_MARGIN_S ))
  [ "$cap" -le "$NIGHT_GC_MAX_S" ] || cap="$NIGHT_GC_MAX_S"
  if [ "$cap" -gt "$GC_TIMEOUT_S" ]; then    # else: NIGHT_GC_MAX_S=0 (off), or too little of the window left to give the gc more than its ordinary cap
    DEADLINE_S=$(( $(date +%s) - START + cap + NIGHT_SLACK_S ))
    if lock_note_until; then
      GC_CAP="$cap"
      log "  night gc: $(( left / 60 )) min of the repack window left — the gc may run up to $(( cap / 60 )) min (not ${GC_TIMEOUT_S}s), run deadline moved to ${DEADLINE_S}s"
    else
      DEADLINE_S="$DEADLINE_BASE"
      log "  night gc: this run's end time cannot be recorded in $LOCK/until — a long gc could have its lock taken by the next tick, so the gc keeps its ${GC_TIMEOUT_S}s cap"
    fi
  fi
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

# ── The WATCHDOG over a watched step (the room pass, tier 2b; header) ──
# While a watched step runs, free disk and swap are read every WATCH_INTERVAL_S. The step is stopped — with every process under it — when free disk falls below Dolt's floor + slack, when swap in use grows more than
# WATCH_SWAP_MAX_KIB past where it stood at the start, or when WATCH_BLIND_MAX looks in a row could not read one of the two (a watchdog that cannot see does not say "all clear"). Why swap and not free disk alone: macOS keeps
# its swap files on the volume that holds the archive and Dolt, so swap growth IS free-disk loss, but it is the one that shows first and the one the 19/10 manual run (swap 4096 -> 6144MB, free 5133 -> 2998MB, killed
# too late by a floor watchdog that looked only at the disk) died of.
WATCH_ON=0; WATCH_FREE_MIN_KIB=0; WATCH_SWAP_BASE_KIB=0; WATCH_BLIND_N=0; WATCH_WHY=""; STEP_PID=""

# dolt_floor_kib — Dolt's CRITICAL floor in KiB: the free disk the machine must keep, (DOLT_CRIT_GB + 1) GiB, because dolt-disk-floor-guard calls the disk critical at free whole GiB <= DOLT_CRIT_GB. rc 1 and nothing
# printed when DOLT_CRIT_GB is not a whole number of at most 9 digits: the floor cannot be shown, and a step that needs it does not start.
dolt_floor_kib() {
  is_uint "$DOLT_CRIT_GB" && [ "${#DOLT_CRIT_GB}" -le 9 ] || return 1
  echo $(( (10#$DOLT_CRIT_GB + 1) * 1048576 ))
}

# swap_used_kib — swap in use, in KiB. JAC_SWAP_USED_FILE (a file holding the KiB) is the test seam; otherwise `sysctl -n vm.swapusage` ("total = 4096.00M  used = 3003.88M  free = 1092.12M  (encrypted)", the same reading the
# repack window's log carries), its unit K / M / G converted. rc 1 and nothing printed when it cannot be read: no sysctl, no answer, a unit or a value it does not know. Unreadable is never 0.
swap_used_kib() {
  local s bin
  if [ -n "${JAC_SWAP_USED_FILE+x}" ]; then
    s="$(cat "$JAC_SWAP_USED_FILE" 2>/dev/null | tr -d ' \n')"
  else
    bin="$SYSCTL"; [ -n "$bin" ] || bin="$(command -v sysctl 2>/dev/null)"
    [ -n "$bin" ] || { [ -x /usr/sbin/sysctl ] && bin=/usr/sbin/sysctl; }
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    s="$(_bounded "$PS_TIMEOUT_S" "$bin" -n vm.swapusage 2>/dev/null | awk '{
        for (i = 1; i < NF; i++) if ($i == "used" && $(i + 1) == "=") {
          v = $(i + 2); u = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
          if (n !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
          if (u == "K") k = n; else if (u == "M") k = n * 1024; else if (u == "G") k = n * 1048576; else exit 1
          printf "%d\n", k; exit
        }
        exit 1 }')" || return 1
  fi
  is_uint "$s" && [ "${#s}" -le 12 ] || return 1
  echo "$s"
}

# watch_free_kib — free KiB on the archive's filesystem for the watchdog: JAC_WATCH_FREE_FILE (test seam: a file holding the KiB) if set, else free_kib. rc 1 when it is not a number.
watch_free_kib() {
  local f
  if [ -n "${JAC_WATCH_FREE_FILE:-}" ]; then f="$(cat "$JAC_WATCH_FREE_FILE" 2>/dev/null | tr -d ' \n')"; else f="$(free_kib "$R_GITDIR")"; fi
  is_uint "$f" && [ "${#f}" -le 12 ] || return 1
  echo "$f"
}

# desc_pids <pid> — <pid> and every process under it, one pid per line (a walk over `ps -A -o pid=,ppid=`). rc 1 when the process table cannot be listed.
desc_pids() {
  local tbl
  tbl="$(_bounded "$PS_TIMEOUT_S" ps -A -o pid=,ppid= 2>/dev/null)" || return 1
  [ -n "$tbl" ] || return 1
  printf '%s\n' "$tbl" | awk -v root="$1" '
    { pid[NR] = $1; par[NR] = $2; n = NR }
    END {
      seen[root] = 1; out[1] = root; c = 1
      for (i = 1; i <= c; i++) for (j = 1; j <= n; j++) if (par[j] == out[i] && !(pid[j] in seen)) { seen[pid[j]] = 1; out[++c] = pid[j] }
      for (i = 1; i <= c; i++) print out[i]
    }'
}

# step_kill <pid> — stop a watched step: TERM to it and everything under it (git removes its own temp pack on TERM), then WATCH_KILL_GRACE_S for them to go, then KILL for what is still alive. A process table that cannot be
# listed stops only <pid> itself, and the log says so: the processes under it then run on until their own cap.
step_kill() {
  local root="$1" pids p alive ticks=0 max
  if ! pids="$(desc_pids "$root")"; then
    log "  WATCHDOG: the process table cannot be listed — only the step's own process ($root) is stopped; what runs under it may be left to its own cap"
    pids="$root"
  fi
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  max=$(( 10#$WATCH_KILL_GRACE_S * 5 ))
  while [ "$ticks" -lt "$max" ]; do
    alive=0
    for p in $pids; do if kill -0 "$p" 2>/dev/null; then alive=1; fi; done
    if [ "$alive" -eq 0 ]; then break; fi
    sleep 0.2
    ticks=$(( ticks + 1 ))
  done
  for p in $pids; do if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null; fi; done
}

# stop_step_at_exit — the first half of the EXIT trap: a watched step still running when this script ends (the order's timeout TERMs it, an interrupt, a fatal error) must not be left running unwatched.
stop_step_at_exit() {
  if [ -n "$STEP_PID" ] && kill -0 "$STEP_PID" 2>/dev/null; then
    log "  the run is ending with its watched step (pid $STEP_PID) still running — stopping it and everything under it"
    step_kill "$STEP_PID"
  fi
}

# watch_check — one look at free disk and swap. rc 0 = go on; rc 1 = stop the step, WATCH_WHY says why. Needs WATCH_FREE_MIN_KIB and WATCH_SWAP_BASE_KIB. A look that cannot read one of the two counts toward WATCH_BLIND_MAX
# (a reading that comes back resets the count); the rest is a plain comparison.
watch_check() {
  local fr sw
  fr="$(watch_free_kib)"; sw="$(swap_used_kib)"
  if ! { is_uint "$fr" && is_uint "$sw"; }; then
    WATCH_BLIND_N=$(( WATCH_BLIND_N + 1 ))
    if [ "$WATCH_BLIND_N" -ge "$WATCH_BLIND_MAX" ]; then
      WATCH_WHY="free disk or swap could not be read in $WATCH_BLIND_N looks in a row (free='${fr:-unreadable}' swap='${sw:-unreadable}') — a watchdog that cannot see does not let the step go on"
      return 1
    fi
    return 0
  fi
  WATCH_BLIND_N=0
  if [ "$fr" -lt "$WATCH_FREE_MIN_KIB" ]; then
    WATCH_WHY="free disk fell to ${fr}KiB, below Dolt's floor + slack (${WATCH_FREE_MIN_KIB}KiB)"
    return 1
  fi
  if [ "$sw" -gt $(( WATCH_SWAP_BASE_KIB + WATCH_SWAP_MAX_KIB )) ]; then
    WATCH_WHY="swap in use grew to ${sw}KiB from ${WATCH_SWAP_BASE_KIB}KiB at the start (more than the ${WATCH_SWAP_MAX_KIB}KiB the pass may add; free disk is ${fr}KiB)"
    return 1
  fi
  return 0
}

# watch_loop <pid> — until the step's process <pid> is gone: wait, and every WATCH_INTERVAL_S look (watch_check). On a verdict: STEP_WATCH = why, a WATCHDOG line in the log, and step_kill. A whole-number interval is waited
# one second at a time, so a step that ends early is not held for the rest of the interval; a decimal one (the selftest's) is waited in one piece.
watch_loop() {
  local pid="$1" tick every k=0
  WATCH_BLIND_N=0
  case "$WATCH_INTERVAL_S" in *.*) tick="$WATCH_INTERVAL_S"; every=1 ;; *) tick=1; every=$(( 10#$WATCH_INTERVAL_S )) ;; esac
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$tick"
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    k=$(( k + 1 ))
    if [ "$k" -ge "$every" ]; then
      k=0
      if ! watch_check; then
        STEP_WATCH="$WATCH_WHY"
        log "  WATCHDOG: $WATCH_WHY — stopping the step and everything under it"
        step_kill "$pid"
        break
      fi
    fi
  done
}

STEP_OUT=""; STEP_RC=0; STEP_WATCH=""
# run_step <cap_s> <git args...> — THE way this script runs a git step that writes to the repo (a batch, prune-packed, gc); sets STEP_OUT (its output) and STEP_RC (its exit
# status) and never fails itself. Lists the temp files before the step; after a step that did NOT end 0, whatever appeared during it is its leak (reclaim_leak). A step
# that ended 0 is not suspected — but a leak it left anyway is still MEASURED at the end of the run (garbage growth, is_bad). Selftest S34 pins that every step goes through here.
# With WATCH_ON=1 (the room pass) the step runs in the background, its output in a temp file, under watch_loop: STEP_WATCH is then the reason the watchdog stopped it ("" = it was not stopped by the watchdog).
run_step() {
  local cap="$1" before before_failed=0 outf pid
  shift
  STEP_WATCH=""
  before="$(list_tmp)" || before_failed=1
  if [ "$WATCH_ON" -eq 1 ]; then
    if ! outf="$(mktemp "${TMPDIR:-/tmp}/jsonl-archive-compact-step.XXXXXX")"; then
      STEP_OUT="could not make a temp file for the step's output under ${TMPDIR:-/tmp} — the watched step was not started"; STEP_RC=1
      return 0
    fi
    git_arch "$cap" "$@" >"$outf" 2>&1 </dev/null &
    pid=$!; STEP_PID="$pid"
    watch_loop "$pid"
    wait "$pid"; STEP_RC=$?
    STEP_PID=""
    STEP_OUT="$(cat "$outf")"
    rm -f -- "$outf"
  else
    STEP_OUT="$(git_arch "$cap" "$@" 2>&1)"; STEP_RC=$?
  fi
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
      def bad: ((.key | IN("bad_streak","last_alert_epoch","batch_objects","tail_objects","tail_cut_epoch","room_kib","room_cut_epoch")) and badnum) or (.key == "loose_kib" and .value != null and badnum);
      (.[$r] // {}) | to_entries | map(select(bad)) | map(.key) | join(",")' <<<"$STATE_JSON" 2>/dev/null)" || bad_fields="?"
  if [ -n "$bad_fields" ]; then
    case "$ENTRY_LOGGED" in
      *" $1:f "*) ;;
      *) ENTRY_LOGGED="$ENTRY_LOGGED$1:f "
         log "  state entry for $1: field(s) $bad_fields are not non-negative whole numbers (or could not be checked) — dropped, read as unset" ;;
    esac
    STATE_JSON="$(jq --arg r "$1" 'def badnum: (.value | type) != "number" or .value < 0 or .value != (.value | floor);
        def bad: ((.key | IN("bad_streak","last_alert_epoch","batch_objects","tail_objects","tail_cut_epoch","room_kib","room_cut_epoch")) and badnum) or (.key == "loose_kib" and .value != null and badnum);
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
If the log says gc timed out at its OWN cap (${GC_TIMEOUT_S}s by day, the window's length at night), the repo is too big for one gc: run it by
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
        --arg lk "$M_LOOSE_KIB" --arg lc "$M_LOOSE_COUNT" --arg pk "$M_PACKS" --arg pks "$M_PACK_KIB" --arg g "${G_KIB:-}" --arg bo "${R_BATCH_SAVE:-}" --arg to "${R_TAIL_SAVE:-}" --arg tc "${R_TAIL_CUT_SAVE:-}" \
        --arg rk "${R_ROOM_SAVE:-}" --arg rc "${R_ROOM_CUT_SAVE:-}" \
        --arg gf "$M_GARBAGE_COUNT" --arg gk "$M_GARBAGE_KIB" \
        'def n($x): (try ($x | tonumber) catch null);
         .[$r] = ((.[$r] // {}) + {last_run_epoch:$now, status:$st, loose_kib:n($lk), loose_objects:n($lc), packs:n($pk), pack_kib:n($pks), gitdir_kib:n($g), garbage_files:n($gf), garbage_kib:n($gk), bad_streak:$streak, last_alert_epoch:$last})
         | if n($bo) != null then .[$r].batch_objects = n($bo) else . end
         | if n($to) != null then .[$r].tail_objects = n($to) else . end
         | if n($tc) != null then .[$r].tail_cut_epoch = n($tc) else . end
         | if n($rk) != null then .[$r].room_kib = n($rk) else . end
         | if n($rc) != null then .[$r].room_cut_epoch = n($rc) else . end' <<<"$state" 2>&1)"; jrc=$?
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

# pack_objects <x.pack> — how many objects a pack holds, read from its .idx without running git: a v2 index is the 8-byte header (ff744f63 00000002), 256 fan-out words of 4 bytes each, and the last
# fan-out word is the total. Prints the number and returns 0. Returns 1 and prints NOTHING when the .idx is missing, short, or not v2 — "cannot tell" is never a count (tail_plan keeps such a pack out).
pack_objects() {
  local idx="${1%.pack}.idx" magic words
  [ -f "$idx" ] || return 1
  # vazio → a short file has no magic to compare, which is not the v2 magic (return 1, no number); falhou/ilegível → od failing prints nothing, the same "not v2" (return 1)
  magic="$(od -An -tx1 -N8 "$idx" 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "ff744f6300000002" ] || return 1
  # vazio → fewer than 4 bytes at the offset is not 4 numbers (return 1); falhou/ilegível → od failing is a return 1 as well, never a total of 0
  words="$(od -An -tu1 -j1028 -N4 "$idx" 2>/dev/null)" || return 1
  set -- $words
  [ "$#" -eq 4 ] || return 1
  is_uint "$1" && is_uint "$2" && is_uint "$3" && is_uint "$4" || return 1
  echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

# tail_plan <cap> — which packs the tail pass would take within <cap> objects, from the object store as it is now. Sets TAIL_PICK (pack file names), TAIL_KEEP (a --keep-pack=<name> for EVERY other pack, so the pass can touch
# nothing else), TAIL_N, TAIL_OBJ (objects in the picked packs), TAIL_KIB, and TAIL_CAPPED (1 = a pack was left out only because of <cap>: the configured TAIL_MAX_OBJECTS would still have taken it at that point of the walk;
# always 0 when <cap> is the configured max). Returns 1 when the pack directory cannot be listed (TAIL_N is then 0). A pack is never picked — it stays under --keep-pack — when it is a cruft pack
# (.mtimes: the unreachable objects waiting out gc's two weeks), carries a .keep, has an object count or a size that cannot be read, or does not fit: packs are taken smallest first (by objects)
# while the total stays within <cap>, so the big old pack — and any pack a previous pass grew to the cap — is left alone, and one pass costs a bounded delta search.
tail_plan() {
  local cap="$1" dir="$R_GITDIR/objects/pack" p b n sz sorted
  local -a rows=()
  TAIL_PICK=(); TAIL_KEEP=(); TAIL_N=0; TAIL_OBJ=0; TAIL_KIB=0; TAIL_CAPPED=0
  # vazio → a directory without a .pack is a repo with nothing to consolidate (the loop below sees only the literal pattern and skips it); falhou/ilegível → a directory that is missing or cannot be read and entered is "could not be listed" (return 1, the caller logs it): never an empty list
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
  for p in "$dir"/*.pack; do
    [ -e "$p" ] || continue
    b="${p##*/}"
    if [ -e "${p%.pack}.mtimes" ] || [ -e "${p%.pack}.keep" ]; then TAIL_KEEP+=("--keep-pack=$b"); continue; fi
    if ! n="$(pack_objects "$p")"; then TAIL_KEEP+=("--keep-pack=$b"); continue; fi
    # vazio → no number is not a size (kept); falhou/ilegível → wc failing prints nothing, the same (kept)
    sz="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
    if ! is_uint "$sz"; then TAIL_KEEP+=("--keep-pack=$b"); continue; fi
    rows+=("$n|$sz|$b")
  done
  if [ "${#rows[@]}" -gt 0 ]; then
    # vazio → a sort that printed nothing leaves nothing picked (TAIL_N 0, the pass does not run); falhou/ilegível → the same: the pass runs only on packs it listed itself
    sorted="$(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n -k3,3)"
    while IFS='|' read -r n sz b; do
      [ -n "$b" ] || continue
      if [ $(( TAIL_OBJ + n )) -le "$cap" ]; then
        TAIL_PICK+=("$b"); TAIL_OBJ=$(( TAIL_OBJ + n )); TAIL_KIB=$(( TAIL_KIB + (sz + 1023) / 1024 ))
      else
        TAIL_KEEP+=("--keep-pack=$b")
        if [ $(( TAIL_OBJ + n )) -le "$TAIL_MAX_OBJECTS" ]; then TAIL_CAPPED=1; fi
      fi
    done <<EOF
$sorted
EOF
  fi
  TAIL_N="${#TAIL_PICK[@]}"
}

# tail_floor — the least the adaptive object cap goes to: TAIL_MIN_OBJECTS, or the configured max when that is lower (the cap is never above the max, so the floor is never above it either).
tail_floor() { if [ "$TAIL_MIN_OBJECTS" -le "$TAIL_MAX_OBJECTS" ]; then echo "$TAIL_MIN_OBJECTS"; else echo "$TAIL_MAX_OBJECTS"; fi; }

# tail_limit_for <cap> — the byte trigger of a pass capped at <cap> objects: TAIL_LIMIT_KIB at the configured max, in proportion below it (at least 1KiB). A pass on half the cap holds about half the bytes, so the
# unscaled trigger would never be reached by it again: it would never start, and so never grow back. (The limit has at most 8 digits and the cap at most 10 — tail_pass checks — so the product stays under 10^18.)
tail_limit_for() {
  local lim="$TAIL_LIMIT_KIB"
  if [ "$TAIL_MAX_OBJECTS" -gt 0 ]; then lim=$(( TAIL_LIMIT_KIB * $1 / TAIL_MAX_OBJECTS )); fi
  [ "$lim" -ge 1 ] || lim=1
  echo "$lim"
}

# tail_grow <why> — doubles the cap (at most TAIL_MAX_OBJECTS) and has the state remember it. Callers decide WHEN; this only moves the number.
tail_grow() {
  local was="$R_TAIL"
  R_TAIL=$(( R_TAIL * 2 ))
  [ "$R_TAIL" -le "$TAIL_MAX_OBJECTS" ] || R_TAIL="$TAIL_MAX_OBJECTS"
  R_TAIL_SAVE="$R_TAIL"
  log "  tail object cap $was -> $R_TAIL ($1)"
}

# tail_retry_due — 0 when the cap a cut lowered may be doubled again: TAIL_RETRY_S have passed since the cut. vazio → no cut time on record (a state edited by hand, or written before this field existed): the clock starts now
# and the answer is no; falhou/ilegível → a cut time that is not a number, or lies in the future: the same, no. Under doubt the cap stays small (the cheap pass is the inert one).
tail_retry_due() {
  local now age
  now="$(date +%s)"
  if is_uint "$R_TAIL_CUT" && [ "$R_TAIL_CUT" -le "$now" ]; then
    age=$(( now - R_TAIL_CUT ))
    [ "$age" -ge "$TAIL_RETRY_S" ]
    return
  fi
  R_TAIL_CUT="$now"; R_TAIL_CUT_SAVE="$now"
  return 1
}

# tail_unstick — the plan at R_TAIL is not due. When the cap is the reason (the configured max would have run it), say so, and once TAIL_RETRY_S have passed since the last cut double the cap and plan again.
# 0 = the cap was doubled and TAIL_* describe the plan at the new cap (the caller judges it again); 1 = nothing changed (not held back by the cap, or too soon to retry) and TAIL_* describe the plan at R_TAIL.
# Needs the plan at R_TAIL (TAIL_CAPPED). A listing that fails leaves TAIL_N at 0, which is "not due".
tail_unstick() {
  local m_n m_kib
  [ "$TAIL_CAPPED" -eq 1 ] || return 1
  tail_plan "$TAIL_MAX_OBJECTS" || return 1
  m_n="$TAIL_N"; m_kib="$TAIL_KIB"
  tail_plan "$R_TAIL" || return 1
  if [ "$m_n" -lt 2 ] || [ "$m_kib" -lt "$TAIL_LIMIT_KIB" ]; then return 1; fi
  log "  tail consolidation held back by its object cap: $R_TAIL objects (lowered after a pass was cut; configured max $TAIL_MAX_OBJECTS) take only $TAIL_N pack(s) ($(fmt "$TAIL_KIB")), too little to start, while the cap of $TAIL_MAX_OBJECTS would take $m_n packs ($(fmt "$m_kib")) — the cap is retried larger ${TAIL_RETRY_S}s after the last cut"
  if tail_retry_due; then
    tail_grow "${TAIL_RETRY_S}s since the last cut and no pass could run since — trying a larger cap"
    R_TAIL_CUT_SAVE="$(date +%s)"; R_TAIL_CUT="$R_TAIL_CUT_SAVE"
    tail_plan "$R_TAIL" || return 1
    return 0
  fi
  return 1
}

# tail_pass <repo> — tier 2a (header): the small packs the batches left, held >= TAIL_LIMIT_KIB (scaled to the object cap), become ONE pack whose deltas are recomputed (-f), by BYTES and not by how many packs there are. Obeys the same
# rules as the consolidating gc: a step that did NOTHING (busy, cut by the run's deadline, not started) may only replace a status that is not a failure; one that finished (rc 0) is `consolidated` unless
# something before it had failed (that failure stays visible). Inert under doubt: an unreadable pack directory, a setting that is not a number, loose objects still waiting for tier 1, a repacker it
# cannot rule out, and a disk it cannot show would stay above Dolt's CRITICAL class all mean "not started", with the reason in the log. Needs a fresh `measure` (M_LOOSE_KIB, M_LOOSE_COUNT) and the repo's entry
# in STATE_JSON (load_state). Sets R_TAIL (the object cap of this pass), and R_TAIL_SAVE / R_TAIL_CUT_SAVE when the state must remember a change (write_state).
tail_pass() {
  local repo="$1" need orc out rc t_left by_deadline b0 took lim fl fr floor_kib next jrc after
  if [ "$TAIL_LIMIT_KIB" = 0 ]; then return 0; fi
  if ! { is_uint "$TAIL_LIMIT_KIB" && is_uint "$TAIL_MAX_OBJECTS" && is_uint "$TAIL_TIMEOUT_S" && is_uint "$TAIL_WINDOW" && is_uint "$TAIL_DEPTH" && is_uint "$TAIL_MIN_OBJECTS" && is_uint "$TAIL_RETRY_S" \
         && [ "${#TAIL_LIMIT_KIB}" -le 8 ] && [ "${#TAIL_MAX_OBJECTS}" -le 10 ]; }; then
    log "  tail consolidation is OFF: a JAC_TAIL_* setting is not a number, or is too long to scale safely (limit over 8 digits, objects over 10) (limit='$TAIL_LIMIT_KIB' objects='$TAIL_MAX_OBJECTS' timeout='$TAIL_TIMEOUT_S' window='$TAIL_WINDOW' depth='$TAIL_DEPTH' min_objects='$TAIL_MIN_OBJECTS' retry_s='$TAIL_RETRY_S') — nothing is consolidated by size until it is fixed"
    return 0
  fi
  # the pass also reads three settings it does not own: `[ n -ge abc ]` ends 2, which an `if` takes as FALSE, so a loose limit it cannot read would read as "no loose backlog" and the pass would start (measured: packs 5 -> 2)
  if ! { is_uint "$LOOSE_LIMIT_KIB" && is_uint "$HEADROOM_KIB" && is_uint "$MIN_GC_BUDGET_S"; }; then
    log "  tail consolidation is OFF: a setting it depends on is not a number (loose_limit_kib='$LOOSE_LIMIT_KIB' headroom_kib='$HEADROOM_KIB' min_gc_budget_s='$MIN_GC_BUDGET_S') — nothing is consolidated by size until it is fixed"
    return 0
  fi
  # the object cap this repo's passes are on. vazio → nothing remembered (never cut, or a first run): the configured max; falhou/ilegível → a remembered value that cannot be read (jq failed, or it is not a whole number)
  # is not "never cut": the floor, the cheap pass, which grows back by itself if it is fast
  fl="$(tail_floor)"
  R_TAIL="$(jq -r --arg r "$repo" '.[$r].tail_objects // empty' <<<"$STATE_JSON" 2>/dev/null)"; jrc=$?
  if [ "$jrc" -ne 0 ]; then R_TAIL="$fl"; log "  the remembered tail object cap of $repo could not be read — the pass starts from the floor ($fl objects)"
  elif [ -z "$R_TAIL" ]; then R_TAIL="$TAIL_MAX_OBJECTS"
  elif is_uint "$R_TAIL"; then
    [ "$R_TAIL" -ge "$fl" ] || R_TAIL="$fl"
    [ "$R_TAIL" -le "$TAIL_MAX_OBJECTS" ] || R_TAIL="$TAIL_MAX_OBJECTS"
  else R_TAIL="$fl"; log "  the remembered tail object cap of $repo is not a whole number — the pass starts from the floor ($fl objects)"; fi
  # vazio/falhou/ilegível → no cut time on record: tail_retry_due starts the clock and answers no
  R_TAIL_CUT="$(jq -r --arg r "$repo" '.[$r].tail_cut_epoch // empty' <<<"$STATE_JSON" 2>/dev/null)"; is_uint "$R_TAIL_CUT" || R_TAIL_CUT=""
  if ! tail_plan "$R_TAIL"; then
    log "  tail consolidation skipped: the pack directory of $repo could not be listed — nothing consolidated by size this run"
    return 0
  fi
  lim="$(tail_limit_for "$R_TAIL")"
  if [ "$TAIL_N" -lt 2 ] || [ "$TAIL_KIB" -lt "$lim" ]; then
    # not due at this cap. If the cap is the reason, tail_unstick says so and may double it; then the plan is judged again
    if ! tail_unstick; then return 0; fi      # 1 = the plan stays as it is and is not due (tail_unstick's answer, not a failure)
    lim="$(tail_limit_for "$R_TAIL")"
    if [ "$TAIL_N" -lt 2 ] || [ "$TAIL_KIB" -lt "$lim" ]; then return 0; fi
  fi
  # `repack -a` packs every reachable loose object too, with -f, and the object cap does not bound those: tier 1 drains them in measured batches first, so a loose backlog still over its limit waits
  if [ "$M_LOOSE_KIB" -ge "$LOOSE_LIMIT_KIB" ]; then
    log "  tail consolidation not started: $TAIL_N small packs hold $(fmt "$TAIL_KIB") but $(fmt "$M_LOOSE_KIB") is still loose (limit $(fmt "$LOOSE_LIMIT_KIB")) — tier 1 drains that first; retried next run"
    return 0
  fi
  if [ "$(remaining)" -lt "$MIN_GC_BUDGET_S" ]; then
    bad_status "$STATUS" || STATUS="deferred"
    log "repo=$repo $TAIL_N small packs hold $(fmt "$TAIL_KIB") but only $(remaining)s of budget left — tail consolidation deferred to the next run"
    return 0
  fi
  need=$(( TAIL_KIB + M_LOOSE_KIB / 4 + HEADROOM_KIB ))      # the new pack is at most as big as the packs it replaces (those stay until it is written) plus what the loose objects pack to (tier 1's assumption: <= 1/4)
  # The disk: free − need must stay OUTSIDE Dolt's CRITICAL class. dolt-disk-floor-guard calls the disk critical when the free GiB, rounded DOWN, is <= DOLT_DISK_FLOOR_CRITICAL_GB, so free − need must be at least
  # (that + 1) GiB. vazio → free space that df did not give is not "plenty" and not "nothing": the pass does not start; falhou/ilegível → a free-space reading or a floor that is not a number (or has more than 9
  # digits) is the same: it does not start, and says why in the same words as a disk that is low (free_kib reads the volume that holds the repo, which in production is the one that holds Dolt's data; ga-q8z86s; the other tiers still proceed on an unreadable df, this one writes ~800MB of temp files and does not).
  fr="$(free_kib "$repo")"
  if ! { is_uint "$fr" && is_uint "$DOLT_CRIT_GB" && [ "${#DOLT_CRIT_GB}" -le 9 ]; }; then
    bad_status "$STATUS" || STATUS="skipped-low-disk"      # a failure tier 1 left stays the status (header 2a: a pass that did nothing replaces only a status that is not a failure)
    log "repo=$repo status=skipped-low-disk (tail) free='${fr:-nothing}' dolt_critical_gb='$DOLT_CRIT_GB' — cannot tell whether the pass would leave the disk above Dolt's CRITICAL floor, so it does not start; small packs=$TAIL_N ($(fmt "$TAIL_KIB"))"
    return 0
  fi
  floor_kib=$(( (DOLT_CRIT_GB + 1) * 1048576 ))
  if [ "$fr" -lt $(( need + floor_kib )) ]; then
    bad_status "$STATUS" || STATUS="skipped-low-disk"
    after="below zero"; if [ "$fr" -ge "$need" ]; then after="$(fmt $(( fr - need )))"; fi
    log "repo=$repo status=skipped-low-disk (tail) free=$(fmt "$fr") need~$(fmt "$need") — free after the pass would be $after, and Dolt's CRITICAL class is a free disk of ${DOLT_CRIT_GB}GiB or less (the pass needs $(fmt "$floor_kib") left) small packs=$TAIL_N ($(fmt "$TAIL_KIB"))"
    return 0
  fi
  # ONE REPACKER AT A TIME (header): the same check, and the same answer, as before the consolidating gc
  other_repacker "$repo"; orc=$?
  if [ "$orc" -eq 1 ]; then
    bad_status "$STATUS" || STATUS="busy"
    log "  tail consolidation not started: $OTHER_WHO is repacking $repo — two repackers at once make a pass fail with 'could not find pack' (ga-8z0hy7); retried next run"
    return 0
  elif [ "$orc" -ne 0 ]; then
    bad_status "$STATUS" || STATUS="busy"
    log "  tail consolidation not started: cannot tell whether another git process is repacking $repo (no ps or lsof, one cut at its cap or failed, or a candidate lsof gave no directory for) — under doubt it waits; retried next run"
    return 0
  fi
  budget_for "$TAIL_TIMEOUT_S"
  log "  tail consolidation: $TAIL_N packs ($(fmt "$TAIL_KIB"), $TAIL_OBJ objects, + ${M_LOOSE_COUNT:-?} loose) -> one pack, deltas recomputed; ${#TAIL_KEEP[@]} other pack(s) kept untouched; object cap $R_TAIL (max $TAIL_MAX_OBJECTS)"
  b0="$(date +%s)"
  run_step "$t_left" repack --quiet -a -d -l -f --window="$TAIL_WINDOW" --depth="$TAIL_DEPTH" --cruft --cruft-expiration=2.weeks.ago ${TAIL_KEEP[@]+"${TAIL_KEEP[@]}"}; out="$STEP_OUT"; rc="$STEP_RC"
  took=$(( $(date +%s) - b0 ))
  if [ "$rc" -eq 0 ]; then
    bad_status "$STATUS" || STATUS="consolidated"
    # tier 1's rule: a pass that used under a quarter of its budget while the cap kept a pack out that the configured max would have taken says the cap is tighter than the host needs
    if [ "$TAIL_CAPPED" -eq 1 ] && [ $(( took * 4 )) -lt "$t_left" ]; then tail_grow "the pass took ${took}s of its ${t_left}s and the cap left a pack out"; fi
  elif [ "$rc" -eq 124 ] && [ "$by_deadline" -eq 1 ]; then
    # it did NOTHING useful (a killed repack keeps no packed work — and leaves a tmp_pack, which run_step has just reclaimed or the garbage measurement will report): it cannot turn a failed / stalled / timed-out / skipped tier 1 green
    bad_status "$STATUS" || STATUS="deferred"
    log "  tail repack was cut by the run deadline after ${t_left}s — the budget ended, not evidence the pass is too big (retried next run, same cap)"
  elif [ "$rc" -eq 124 ]; then
    # its OWN cap ran out: this many objects do not fit in the budget on this host, and the same pass would be cut the same way next run (ga-q8z86s). The next one takes half of what this one carried
    # (not half the cap: a cap of 120 over a pass of 40 would otherwise repeat that pass once more at 60), and the state remembers when it happened for tail_retry_due
    STATUS="timeout"
    next=$(( TAIL_OBJ / 2 ))
    [ "$next" -ge "$fl" ] || next="$fl"
    [ "$next" -le "$R_TAIL" ] || next="$R_TAIL"
    R_TAIL_CUT="$(date +%s)"; R_TAIL_CUT_SAVE="$R_TAIL_CUT"
    if [ "$next" -lt "$R_TAIL" ]; then
      R_TAIL="$next"; R_TAIL_SAVE="$next"
      log "  tail repack timed out after ${t_left}s (its own cap) — it carried $TAIL_OBJ objects; the next pass takes at most $next (half of that, never below the floor of $fl)"
    else
      log "  tail repack timed out after ${t_left}s (its own cap) — it carried $TAIL_OBJ objects and the cap is already at its floor ($fl): the next pass can only repeat this one"
    fi
  else STATUS="failed"; log "  tail repack failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; fi
}

# room_settings_ok — 0 when every JAC_ROOM_* and JAC_WATCH_* setting is usable; else 1 and ROOM_BAD names what is wrong. The lengths are capped so the arithmetic below cannot overflow; the pack.* memory sizes take git's own
# suffixes (k, m, g); threads must be at least 1 (0 means "one per CPU" to git, the opposite of lean); the watch interval is a positive decimal (it is handed to sleep).
room_settings_ok() {
  ROOM_BAD=""
  local k v
  for k in ROOM_START_KIB ROOM_MAX_KIB ROOM_MIN_KIB ROOM_TIMEOUT_S ROOM_RETRY_S WATCH_SWAP_MAX_KIB WATCH_SLACK_KIB WATCH_BLIND_MAX WATCH_KILL_GRACE_S ROOM_THREADS; do
    v="${!k}"
    if ! { is_uint "$v" && [ "${#v}" -le 9 ]; }; then ROOM_BAD="$k='$v' is not a whole number of at most 9 digits"; return 1; fi
    printf -v "$k" '%d' "$(( 10#$v ))"      # "0262144" would be octal to the arithmetic below
  done
  if [ "$ROOM_THREADS" -lt 1 ] || [ "$WATCH_BLIND_MAX" -lt 1 ] || [ "$ROOM_TIMEOUT_S" -lt 1 ]; then ROOM_BAD="ROOM_THREADS='$ROOM_THREADS', WATCH_BLIND_MAX='$WATCH_BLIND_MAX' and ROOM_TIMEOUT_S='$ROOM_TIMEOUT_S' must each be at least 1"; return 1; fi
  case "$ROOM_WINDOW_MEM" in ''|*[!0-9kKmMgG]*|[kKmMgG]*) ROOM_BAD="ROOM_WINDOW_MEM='$ROOM_WINDOW_MEM' is not a size (digits and one of k, m, g)"; return 1 ;; esac
  case "$ROOM_DELTA_CACHE" in ''|*[!0-9kKmMgG]*|[kKmMgG]*) ROOM_BAD="ROOM_DELTA_CACHE='$ROOM_DELTA_CACHE' is not a size (digits and one of k, m, g)"; return 1 ;; esac
  case "$WATCH_INTERVAL_S" in
    ''|*[!0-9.]*|.*|*.|*.*.*) ROOM_BAD="WATCH_INTERVAL_S='$WATCH_INTERVAL_S' is not a positive number of seconds"; return 1 ;;
  esac
  if [ "${#WATCH_INTERVAL_S}" -gt 6 ] || [ -z "${WATCH_INTERVAL_S//[0.]/}" ]; then ROOM_BAD="WATCH_INTERVAL_S='$WATCH_INTERVAL_S' is zero or too long"; return 1; fi
  return 0
}

# room_plan <cap_kib> <avail_kib> — which packs the room pass would take, from the object store as it is now. Sets ROOM_PICK (pack file names), ROOM_KEEP (a --keep-pack=<name> for EVERY other pack, so the pass can touch nothing
# else), ROOM_N, ROOM_KIB (bytes in the picked packs), ROOM_BIG (the largest eligible pack: ALWAYS kept, whatever the room — it is what makes the gc big), ROOM_TWO (1 = the second pack exceeded <cap_kib> and was taken because
# a pass of one pack consolidates nothing and the room still holds two), ROOM_CAPPED (1 = a pack was left out only because of <cap_kib>: min(ROOM_MAX_KIB, <avail_kib>) would have taken it). Returns 1 when the pack
# directory cannot be listed. A pack is kept, never picked, when it is a cruft pack (.mtimes), carries a .keep, has an index or a size that cannot be read. Smallest first by BYTES — the bytes are what the pass writes
# and what its pack-objects holds in memory — while the total stays within <cap_kib>; the first two are taken while they fit <avail_kib>. <avail_kib> is the room over Dolt's floor: no pass bigger than it is planned.
room_plan() {
  local cap="$1" avail="$2" dir="$R_GITDIR/objects/pack" p b sz kib sorted hi total=0 n=0
  local -a rows=()
  ROOM_PICK=(); ROOM_KEEP=(); ROOM_N=0; ROOM_KIB=0; ROOM_CAPPED=0; ROOM_TWO=0; ROOM_BIG=""
  # vazio → a directory without a .pack has nothing to consolidate (the loop sees only the literal pattern and skips it); falhou/ilegível → missing or not readable is "could not be listed" (return 1), never an empty list
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
  for p in "$dir"/*.pack; do
    [ -e "$p" ] || continue
    b="${p##*/}"
    if [ -e "${p%.pack}.mtimes" ] || [ -e "${p%.pack}.keep" ] || ! pack_objects "$p" >/dev/null; then ROOM_KEEP+=("--keep-pack=$b"); continue; fi
    # vazio/falhou/ilegível → no number is not a size: the pack is kept
    sz="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
    if ! is_uint "$sz"; then ROOM_KEEP+=("--keep-pack=$b"); continue; fi
    rows+=("$sz|$b")
  done
  if [ "${#rows[@]}" -gt 0 ]; then
    # vazio/falhou → a sort that printed nothing leaves nothing picked (ROOM_N 0, the pass does not run)
    sorted="$(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n -k2,2)"
    ROOM_BIG="$(printf '%s\n' "$sorted" | tail -n 1)"; ROOM_BIG="${ROOM_BIG#*|}"
    hi="$ROOM_MAX_KIB"; [ "$avail" -ge "$hi" ] || hi="$avail"
    while IFS='|' read -r sz b; do
      [ -n "$b" ] || continue
      if [ "$b" = "$ROOM_BIG" ]; then ROOM_KEEP+=("--keep-pack=$b"); continue; fi
      kib=$(( (sz + 1023) / 1024 ))
      if [ $(( total + kib )) -le "$cap" ]; then
        ROOM_PICK+=("$b"); total=$(( total + kib )); n=$(( n + 1 ))
      elif [ "$n" -lt 2 ] && [ $(( total + kib )) -le "$avail" ]; then
        ROOM_PICK+=("$b"); total=$(( total + kib )); n=$(( n + 1 )); ROOM_TWO=1
      else
        ROOM_KEEP+=("--keep-pack=$b")
        if [ $(( total + kib )) -le "$hi" ]; then ROOM_CAPPED=1; fi
      fi
    done <<EOF
$sorted
EOF
  fi
  ROOM_N="$n"; ROOM_KIB="$total"
}

# room_pass <repo> — tier 2b (header, ga-978f1y): the window is open but the whole-repo gc cannot have the room it asks for (the repack window's rule, or compact_repo's disk gate, said no). A partial repack — only as many of
# the SMALLEST packs as the room over Dolt's floor holds, the largest ALWAYS kept, lean pack.* settings — under the WATCHDOG (watch_loop). Returns 1 when it did not run for a reason that is INERT (a setting that is not a number, a
# backoff in force, a reading it needs that cannot be read, no room for two packs, loose objects still waiting for tier 1): STATUS is untouched and the caller says what it said before this tier existed. Returns 0 when it
# handled the outcome (STATUS is set): ran and finished, was stopped, was cut, found another repacker, or had no budget left. Needs a fresh `measure`, the repo's entry in STATE_JSON (load_state) and, from compact_repo, GC_CAP and GC_EXT_DONE.
# Sets R_ROOM_SAVE / R_ROOM_CUT_SAVE when the state must remember a change (write_state). A pass that did NOTHING (busy, deferred) may only replace a status that is not a failure, like every pass before it.
room_pass() {
  local repo="$1" t_left by_deadline orc out rc b0 took fr floor avail cap now cut jrc swp0 swp1 next cap_s swp_txt
  if ! room_settings_ok; then
    log "  room pass is OFF: a JAC_ROOM_* / JAC_WATCH_* setting cannot be used ($ROOM_BAD) — nothing is consolidated by this tier until it is fixed"
    return 1
  fi
  # vazio → nothing remembered (a first run): the configured start; falhou/ilegível → a remembered cap that cannot be read is not "never cut": the smallest, the cheap pass
  R_ROOM="$(jq -r --arg r "$repo" '.[$r].room_kib // empty' <<<"$STATE_JSON" 2>/dev/null)"; jrc=$?
  if [ "$jrc" -ne 0 ]; then R_ROOM="$ROOM_MIN_KIB"; log "  the remembered room-pass cap of $repo could not be read — the pass starts from the smallest cap (${ROOM_MIN_KIB}KiB)"
  elif [ -z "$R_ROOM" ]; then R_ROOM="$ROOM_START_KIB"
  elif is_uint "$R_ROOM" && [ "${#R_ROOM}" -le 9 ]; then
    [ "$R_ROOM" -ge "$ROOM_MIN_KIB" ] || R_ROOM="$ROOM_MIN_KIB"
    [ "$R_ROOM" -le "$ROOM_MAX_KIB" ] || R_ROOM="$ROOM_MAX_KIB"
  else R_ROOM="$ROOM_MIN_KIB"; log "  the remembered room-pass cap of $repo is not a whole number — the pass starts from the smallest cap (${ROOM_MIN_KIB}KiB)"; fi
  # BACKOFF: a pass that was cut (watchdog, own cap) or failed is not tried again at once — the host that could not carry it is no different 30 minutes later. vazio/0 → never cut; a time in the future (a clock that moved,
  # a state edited by hand) starts the clock now and backs off
  cut="$(jq -r --arg r "$repo" '.[$r].room_cut_epoch // empty' <<<"$STATE_JSON" 2>/dev/null)"; is_uint "$cut" || cut=""
  now="$(date +%s)"
  if [ -n "$cut" ] && [ "$cut" -gt 0 ]; then
    if [ "$cut" -gt "$now" ]; then
      R_ROOM_CUT_SAVE="$now"
      log "  room pass: the last cut is dated in the future ($cut > $now) — the clock starts now; backing off ${ROOM_RETRY_S}s"
      return 1
    elif [ $(( now - cut )) -lt "$ROOM_RETRY_S" ]; then
      log "  room pass: the last one was cut $(( now - cut ))s ago — backing off until ${ROOM_RETRY_S}s have passed (cap ${R_ROOM}KiB)"
      return 1
    fi
  fi
  # `repack -a` packs every reachable loose object too, which the pass's cap does not bound: tier 1 drains them first
  if [ "$M_LOOSE_KIB" -ge "$LOOSE_LIMIT_KIB" ]; then
    log "  room pass not started: $(fmt "$M_LOOSE_KIB") is still loose (limit $(fmt "$LOOSE_LIMIT_KIB")) — tier 1 drains that first; retried next run"
    return 1
  fi
  # the room: what is free over Dolt's CRITICAL floor, less the headroom and the quarter of the loose bytes a repack -a packs too. Every reading must be a number — free disk, the floor and swap (the watchdog needs the
  # swap at the start to know what "grew" means): the pass writes into the disk Dolt lives on and does not start blind
  fr="$(free_kib "$repo")"
  if ! is_uint "$fr"; then log "  room pass not started: free disk cannot be read (free='${fr:-nothing}') — cannot tell what room there is over Dolt's floor"; return 1; fi
  if ! floor="$(dolt_floor_kib)"; then log "  room pass not started: Dolt's floor cannot be shown (dolt_critical_gb='$DOLT_CRIT_GB' is not a whole number) — cannot tell what room there is over it"; return 1; fi
  swp0="$(swap_used_kib)"
  if ! is_uint "$swp0"; then log "  room pass not started: swap in use cannot be read — the watchdog would have nothing to compare against, and the 19/10 run died of swap, not of pack space"; return 1; fi
  avail=$(( fr - floor - HEADROOM_KIB - M_LOOSE_KIB / 4 )); [ "$avail" -ge 0 ] || avail=0
  cap="$R_ROOM"; [ "$cap" -le "$avail" ] || cap="$avail"
  if ! room_plan "$cap" "$avail"; then
    log "  room pass not started: the pack directory of $repo could not be listed"
    return 1
  fi
  if [ "$ROOM_N" -lt 2 ]; then
    log "  room pass not started: $(fmt "$fr") free, Dolt's floor $(fmt "$floor") + headroom $(fmt "$HEADROOM_KIB") leave ${avail}KiB, and the smallest two packs (other than the largest, $ROOM_BIG) need more — a pass of fewer than two packs consolidates nothing (adaptive cap ${R_ROOM}KiB)"
    return 1
  fi
  # ONE REPACKER AT A TIME (header): the same check, and the same answer, as before the gc and the tail pass
  other_repacker "$repo"; orc=$?
  if [ "$orc" -eq 1 ]; then
    bad_status "$STATUS" || STATUS="busy"
    log "  room pass not started: $OTHER_WHO is repacking $repo — two repackers at once make a pass fail with 'could not find pack' (ga-8z0hy7); retried next run"
    return 0
  elif [ "$orc" -ne 0 ]; then
    bad_status "$STATUS" || STATUS="busy"
    log "  room pass not started: cannot tell whether another git process is repacking $repo (no ps or lsof, one cut at its cap or failed, or a candidate lsof gave no directory for) — under doubt it waits; retried next run"
    return 0
  fi
  # the pass runs for tens of minutes: the run's deadline is moved for it like the gc's (once — the disk gate's road has done it already)
  if [ "$GC_EXT_DONE" -eq 0 ]; then night_gc_extend; GC_EXT_DONE=1; fi
  if [ "$(remaining)" -lt "$MIN_GC_BUDGET_S" ]; then
    bad_status "$STATUS" || STATUS="deferred"
    log "repo=$repo room pass ($ROOM_N packs, $(fmt "$ROOM_KIB")) but only $(remaining)s of budget left — deferred to the next run"
    return 0
  fi
  cap_s="$GC_CAP"; [ "$cap_s" -le "$ROOM_TIMEOUT_S" ] || cap_s="$ROOM_TIMEOUT_S"
  budget_for "$cap_s"
  swp_txt="$(( swp0 / 1024 ))MiB"
  log "  room pass: the whole-repo gc cannot have its room (free $(fmt "$fr"), Dolt's floor $(fmt "$floor")) — consolidating $ROOM_N pack(s) ($(fmt "$ROOM_KIB"); adaptive cap ${R_ROOM}KiB, room over the floor ${avail}KiB) into one with the largest pack ($ROOM_BIG) kept untouched; ${ROOM_THREADS} thread, windowMemory $ROOM_WINDOW_MEM, deltaCacheSize $ROOM_DELTA_CACHE; swap in use now $swp_txt, the watchdog stops it above +$(( WATCH_SWAP_MAX_KIB / 1024 ))MiB or free disk under $(fmt $(( floor + WATCH_SLACK_KIB ))), at most ${t_left}s"
  jaw_log 1 "room pass: $ROOM_N pack(s) $(fmt "$ROOM_KIB") of $repo, the largest kept; adaptive cap ${R_ROOM}KiB; free $(fmt "$fr"), swap $swp_txt"
  R_PACK_EXTRA=(-c "pack.threads=$ROOM_THREADS" -c "pack.windowMemory=$ROOM_WINDOW_MEM" -c "pack.deltaCacheSize=$ROOM_DELTA_CACHE")
  WATCH_ON=1; WATCH_FREE_MIN_KIB=$(( floor + WATCH_SLACK_KIB )); WATCH_SWAP_BASE_KIB="$swp0"
  b0="$(date +%s)"
  run_step "$t_left" repack --quiet -a -d -l -f --window="$TAIL_WINDOW" --depth="$TAIL_DEPTH" --cruft --cruft-expiration=2.weeks.ago ${ROOM_KEEP[@]+"${ROOM_KEEP[@]}"}; out="$STEP_OUT"; rc="$STEP_RC"
  took=$(( $(date +%s) - b0 ))
  WATCH_ON=0; WATCH_FREE_MIN_KIB=0; WATCH_SWAP_BASE_KIB=0; R_PACK_EXTRA=()
  swp1="$(swap_used_kib)"
  if is_uint "$swp1"; then swp_txt="swap $(( swp0 / 1024 ))MiB -> $(( swp1 / 1024 ))MiB"; else swp_txt="swap was $(( swp0 / 1024 ))MiB and cannot be read now"; fi
  # the smaller cap a cut leaves behind: half of what the pass carried, never below ROOM_MIN_KIB or above the cap it ran at
  next=$(( ROOM_KIB / 2 )); [ "$next" -ge "$ROOM_MIN_KIB" ] || next="$ROOM_MIN_KIB"; [ "$next" -le "$R_ROOM" ] || next="$R_ROOM"
  if [ "$rc" -eq 0 ]; then
    bad_status "$STATUS" || STATUS="consolidated"
    R_ROOM_CUT_SAVE=0
    log "  room pass done in ${took}s ($swp_txt): $ROOM_N pack(s) became one"
    # tier 1's rule: a pass that used under a quarter of its budget while the cap kept a pack out that the room would have taken says the cap is tighter than the host needs
    if [ "$ROOM_CAPPED" -eq 1 ] && [ $(( took * 4 )) -lt "$t_left" ]; then
      next=$(( R_ROOM * 2 )); [ "$next" -le "$ROOM_MAX_KIB" ] || next="$ROOM_MAX_KIB"
      if [ "$next" -gt "$R_ROOM" ]; then R_ROOM_SAVE="$next"; log "  room-pass cap ${R_ROOM}KiB -> ${next}KiB (the pass took ${took}s of its ${t_left}s and the cap left a pack out)"; fi
    fi
  elif [ -n "$STEP_WATCH" ]; then
    # the watchdog ended it (log line written by watch_loop): LOUD, not deferred — the host showed it cannot carry a pass this size
    STATUS="aborted"
    R_ROOM_CUT_SAVE="$(date +%s)"
    if [ "$next" -lt "$R_ROOM" ]; then R_ROOM_SAVE="$next"; fi
    log "  room pass STOPPED by the watchdog after ${took}s ($swp_txt): $STEP_WATCH — the next pass carries at most ${next}KiB (half of this one's $(fmt "$ROOM_KIB"), never below ${ROOM_MIN_KIB}KiB), tried again after ${ROOM_RETRY_S}s"
  elif [ "$rc" -eq 124 ] && [ "$by_deadline" -eq 1 ]; then
    # it did NOTHING useful (a killed repack keeps no packed work — and leaves a tmp_pack, which run_step has just reclaimed or the garbage measurement will report): not evidence the pass is too big
    bad_status "$STATUS" || STATUS="deferred"
    log "  room pass was cut by the run deadline after ${t_left}s ($swp_txt) — the budget ended, not evidence the pass is too big (retried next run, same cap)"
  elif [ "$rc" -eq 124 ]; then
    STATUS="timeout"
    R_ROOM_CUT_SAVE="$(date +%s)"
    if [ "$next" -lt "$R_ROOM" ]; then R_ROOM_SAVE="$next"; fi
    log "  room pass timed out after ${t_left}s (its own cap, $swp_txt) — it carried $ROOM_N pack(s), $(fmt "$ROOM_KIB"); the next one carries at most ${next}KiB, tried again after ${ROOM_RETRY_S}s"
  else
    STATUS="failed"
    R_ROOM_CUT_SAVE="$(date +%s)"
    log "  room pass failed rc=$rc after ${took}s ($swp_txt): $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ') — tried again after ${ROOM_RETRY_S}s"
  fi
  return 0
}

compact_repo() {  # compact_repo <repo> — sets STATUS, returns nothing; caller handles is_bad via record
  local repo="$1" t0 before_loose before_packs before_kib batches=0 prev_count prev_packs prev_unpacked prev_loose need out rc t_left batch_left b0 took timeouts=0 fast=0 saved by_deadline progressed over before_gcount before_gkib window_ok in_window why
  R_GITDIR="$repo/.git"
  STATUS="ok"; G_KIB=""; R_PROGRESS=0; R_BATCH_SAVE=""; R_TAIL_SAVE=""; R_TAIL_CUT_SAVE=""; R_ROOM_SAVE=""; R_ROOM_CUT_SAVE=""; R_GARBAGE_GREW=0; R_GARBAGE_BEFORE=""; R_LEAK_UNKNOWN=0
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

  # ── tier 2a: the small packs hold too many BYTES → one pack with the deltas recomputed (header). After tier 1, so the loose backlog is drained; before tier 2, so the gc below finds fewer packs ──
  measure || STATUS="unmeasured"
  if [ "$STATUS" != unmeasured ]; then tail_pass "$repo"; fi

  # ── tier 2: too many packs → one consolidating gc, only with budget to finish ──
  measure || STATUS="unmeasured"
  if [ "$STATUS" != unmeasured ] && [ "$M_PACKS" -ge "$PACKS_LIMIT" ]; then
    need=$(( M_PACK_KIB + HEADROOM_KIB ))
    # WINDOW (header, ga-wkoij7): the gc rewrites every pack, so it starts only in the night window and with room for it. jaw_repack_allowed logs its own reason; free_kib is passed in
    # so JAC_FREE_KIB (the seam of every disk test here) stays the one source of free space; an empty answer is read again by the lib's own df, and empty twice is "cannot read" = no gc. Not allowed = it did NOTHING, so it
    # cannot turn a failed / stalled / timed-out / unmeasured / skipped tier 1 green — the same rule as a gc without budget.
    # ROOM (header, tier 2b, ga-978f1y): both guards below are sized on a FULL rewrite — the largest pack, all the packs — and on the 19/10 archive (10GB, the largest pack 4.5GB, free 5-6GB on the mini) they said no 48 runs in
    # a row, so the packs were never consolidated and the disk never recovered. When it is the ROOM that refused, INSIDE the window, the room pass (watched, the largest pack kept) takes what the room over Dolt's floor
    # holds. It answers 1 when it did not run for an inert reason: the answer is then the one this tier gave before the room pass existed.
    GC_CAP="$GC_TIMEOUT_S"; GC_EXT_DONE=0; window_ok=0; in_window=0; why=""
    if jaw_repack_allowed "$R_GITDIR" "$(free_kib "$repo")" "$GC_PACK_FACTOR"; then window_ok=1; night_gc_extend; GC_EXT_DONE=1; else why="$JAW_REASON"; in_window="$JAW_IN_WINDOW"; fi
    if [ "$window_ok" -eq 0 ]; then
      if [ "$in_window" -ne 1 ] || ! room_pass "$repo"; then
        bad_status "$STATUS" || STATUS="deferred"
        log "repo=$repo packs=$M_PACKS >= $PACKS_LIMIT but the repack window does not allow it now — consolidating gc deferred: $why (the pack alarm still judges the end state)"
      fi
    elif [ "$(remaining)" -lt "$MIN_GC_BUDGET_S" ]; then
      bad_status "$STATUS" || STATUS="deferred"
      log "repo=$repo packs=$M_PACKS >= $PACKS_LIMIT but only $(remaining)s of budget left — gc deferred to the next run"
    elif disk_low "$repo" "$need"; then
      if ! room_pass "$repo"; then
        STATUS="skipped-low-disk"
        log "repo=$repo status=skipped-low-disk (gc) free=$(fmt "$(free_kib "$repo")") need~$(fmt "$need") packs=$M_PACKS"
      fi
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
        budget_for "$GC_CAP"
        run_step "$t_left" -c gc.autoDetach=false gc --quiet; out="$STEP_OUT"; rc="$STEP_RC"
        if [ "$rc" -eq 0 ]; then STATUS="consolidated"
        elif [ "$rc" -eq 124 ] && [ "$by_deadline" -eq 1 ]; then
          # it did NOTHING useful (a killed gc keeps no packed work — and leaves a tmp_pack, which run_step has just reclaimed or the garbage measurement will report): it cannot turn a failed / stalled / timed-out / skipped tier 1 green
          bad_status "$STATUS" || STATUS="deferred"
          log "  gc was cut by the run deadline after ${t_left}s — the budget ended, not evidence the repo is too big for one gc (retried next run)"
        elif [ "$rc" -eq 124 ]; then STATUS="timeout"; log "  gc timed out after ${t_left}s (its own cap$([ "$GC_CAP" -gt "$GC_TIMEOUT_S" ] && echo ' — the night window, so a gc that big cannot finish in one night'))"
        elif printf '%s' "$out" | grep -q 'already running'; then
          # it did NOTHING: it cannot turn a failed / stalled / timed-out / unmeasured / skipped tier 1 into a green "busy"
          bad_status "$STATUS" || STATUS="busy"
          log "  gc already running elsewhere — leaving it to finish"
        else STATUS="failed"; log "  gc failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; fi
      fi
    fi
  fi
  DEADLINE_S="$DEADLINE_BASE"   # the night gc's longer deadline (night_gc_extend) was for the gc only: what follows — the next repo — is back on the ordinary budget

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
# lock_note_until — the holder writes the epoch at which its own budget ends (START + DEADLINE_S), so a run that is allowed to last hours (the night gc) is not taken for a hung one when the lock gets
# LOCK_STALE_MIN old. rc 1 when it cannot be written: the caller then does not take the long budget.
lock_note_until() { printf '%s\n' "$(( START + DEADLINE_S ))" > "$LOCK/until" 2>/dev/null; }
# lock_within_budget — rc 0 only when the holder wrote an end time and it has not passed (LOCK_GRACE_S of slack for the work after the deadline). No file, an unreadable one or a non-number is rc 1:
# the lock is then judged by age alone, exactly as before the night gc existed.
lock_within_budget() {
  local u
  u="$(cat "$LOCK/until" 2>/dev/null)"
  is_uint "$u" && [ "$(date +%s)" -le $(( u + LOCK_GRACE_S )) ]
}
lock_older_than() {  # lock_older_than <minutes> — 0 = older, 1 = not older, 2 = could not tell (find failed): never "not older"
  local o
  o="$(find "$LOCK" -maxdepth 0 -mmin +"$1" 2>/dev/null)" || return 2
  [ -n "$o" ]
}
# lock_is_stale — 0 = stale (reclaim it), 1 = a live run's lock (yield to it), 2 = cannot tell (an age could not be read, and nothing else proved it stale)
lock_is_stale() {
  local old_hung old_dead
  lock_older_than "$LOCK_STALE_MIN"; old_hung=$?
  # old for a hung run — unless its holder said it may last this long (the night gc) and its own end time has not passed: then it is judged by its owner pid alone (dead = reclaim, alive = in flight)
  if [ "$old_hung" -eq 0 ] && ! lock_within_budget; then return 0; fi
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
lock_release() { rm -f "$LOCK/pid" "$LOCK/until" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; }
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
  trap 'stop_step_at_exit; release_at_exit' EXIT      # a watched step (the room pass) still running when the run ends is stopped FIRST: it must not outlive the lock that says nobody is repacking
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
