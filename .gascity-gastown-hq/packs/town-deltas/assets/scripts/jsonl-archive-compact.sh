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
#      JAC_BATCH_OBJECTS (60), is halved whenever a batch hits its timeout (retried at once with the
#      smaller size, down to 5), is remembered per repo in the state file, and doubles once after
#      a run with no timeouts and a fast batch. Measured on 41MB blobs (9 versions, same output
#      5.8MiB every time): 177s at nice 19 + background QoS, 69-101s at nice 10, 52s at nice 0,
#      under load 35-63 — this host is always loaded, so a fixed batch size could time out
#      forever and never make progress. Bounded batches matter: a run killed by its timeout still
#      keeps every batch it finished, so even a multi-GiB backlog drains instead of restarting
#      from zero each cycle (a single full gc over the backlog throws all its work away when it
#      times out).
#   2. pack count >= JAC_PACKS_LIMIT (8): one full `git gc` to consolidate. Each batch pack
#      carries its own first full copy of every big file (batches cannot delta against earlier
#      packs); the gc re-deltas those against the whole history and merges the packs.
# Nothing here ever shortens history: no prune of reachable objects, no shallow, no squash.
# `git gc` keeps its own 2-week expiry for unreachable objects. The S3 mirror
# (dolt-s3-backup.sh) copies only the working tree (`--exclude ".git/*"`), so the git history
# has NO offsite copy — compaction is the only thing this script may do to it.
#
# THREE STATES, NEVER TWO: a repo whose objects cannot be measured is `unmeasured` (failure),
# not "0 loose". git is always called with --git-dir=<repo>/.git: without it a broken .git
# makes git walk UP and act on the enclosing repo (these archives live inside the city's own
# git tree — a plain `git -C` there would have gc'd the town monorepo).
#
# ALARM: a run is BAD when the repo ends >= JAC_LOOSE_ALARM_KIB loose WITHOUT the run having shrunk
# it (a backlog that is visibly draining is not news), or >= JAC_PACKS_ALARM packs, or the run
# failed / could not measure / was skipped for low disk / stalled / timed out at the minimum
# batch size. After
# JAC_ALERT_AFTER (3) consecutive BAD runs one mail goes to the mayor, at most once per
# JAC_ALERT_EVERY_S (6h); an undelivered mail is retried next run (delivered != attempted).
# Exit 1 whenever any repo is BAD, so the order runner shows the failure too.
#
# MODES:  (none)        compact + state + alarm
#         --check       read-only: measure, print, exit 1 if BAD (no lock, state, mail, git writes)
#         --print-config  print the effective config and exit 0
#
# CADENCE: order jsonl-archive-compact, interval 30m, timeout 900s; JAC_DEADLINE_S (780s) is
# this script's own budget so it can log its outcome before the order's timeout fires. One
# instance at a time: an mkdir lock that records its owner's pid — reclaimed at once when the
# owner is dead (a run SIGKILLed by the order timeout), after 90m when it still looks alive.
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
LOOSE_ALARM_KIB="${JAC_LOOSE_ALARM_KIB:-1048576}"    # 1GiB still loose after a run = BAD, unless the run shrank it (a backlog draining)
PACKS_LIMIT="${JAC_PACKS_LIMIT:-8}"                  # this many packs triggers the consolidating gc
PACKS_ALARM="${JAC_PACKS_ALARM:-20}"                 # this many after a run = BAD (git's own autoPackLimit is 50)
BATCH_OBJECTS="${JAC_BATCH_OBJECTS:-60}"             # starting batch (~7 commits, ~300MiB loose); adapts, see header
BATCH_MIN=5
BATCH_MAX="${JAC_BATCH_MAX:-200}"
MAX_BATCHES="${JAC_MAX_BATCHES:-0}"                  # 0 = as many as the deadline allows
GIT_TIMEOUT_S="${JAC_GIT_TIMEOUT_S:-300}"            # per batch
GC_TIMEOUT_S="${JAC_GC_TIMEOUT_S:-600}"              # per consolidating gc
DEADLINE_S="${JAC_DEADLINE_S:-780}"                  # whole run; the order's timeout is 900s
MIN_GC_BUDGET_S="${JAC_MIN_GC_BUDGET_S:-240}"        # do not START a gc with less than this left
HEADROOM_KIB="${JAC_HEADROOM_KIB:-524288}"           # free space that must remain after the estimate
ALERT_AFTER="${JAC_ALERT_AFTER:-3}"
ALERT_EVERY_S="${JAC_ALERT_EVERY_S:-21600}"
LOCK_STALE_MIN="${JAC_LOCK_STALE_MIN:-90}"
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
git_timeout_s=$GIT_TIMEOUT_S gc_timeout_s=$GC_TIMEOUT_S deadline_s=$DEADLINE_S
alert_after=$ALERT_AFTER alert_every_s=$ALERT_EVERY_S
state=$STATE log=$LOG lock=$LOCK
EOF
  exit 0
fi

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {
  local line="[$(ts)] $*"
  echo "$line"
  [ "$MODE" = check ] && return 0
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  echo "$line" >> "$LOG" 2>/dev/null || true
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt "$LOG_MAX_LINES" ] 2>/dev/null; then
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
for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { _timeout_bin="$_t"; break; }; done
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
mib() { echo $(( $1 / 1024 )); }
# fmt <kib> — "<n>MiB", or "?" when git could not say (an unknown must never read as 0)
fmt() { if is_uint "${1:-}"; then echo "$(( $1 / 1024 ))MiB"; else echo "?"; fi; }

# measure — fills M_LOOSE_COUNT M_LOOSE_KIB M_PACKS M_PACK_KIB M_GARBAGE_KIB, or returns 1 when
# git cannot say (never a quiet zero).
measure() {
  local out k v
  M_LOOSE_COUNT=""; M_LOOSE_KIB=""; M_PACKS=""; M_PACK_KIB=""; M_GARBAGE_KIB=""
  out="$(git --git-dir="$R_GITDIR" count-objects -v 2>/dev/null)" || return 1
  while IFS=': ' read -r k v; do
    case "$k" in
      count) M_LOOSE_COUNT="$v" ;;
      size) M_LOOSE_KIB="$v" ;;
      packs) M_PACKS="$v" ;;
      size-pack) M_PACK_KIB="$v" ;;
      size-garbage) M_GARBAGE_KIB="$v" ;;
    esac
  done <<EOF
$out
EOF
  is_uint "$M_LOOSE_COUNT" && is_uint "$M_LOOSE_KIB" && is_uint "$M_PACKS" \
    && is_uint "$M_PACK_KIB" && is_uint "$M_GARBAGE_KIB"
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

state_json() {
  if [ -f "$STATE" ] && jq -e . "$STATE" >/dev/null 2>&1; then cat "$STATE"; else echo '{}'; fi
}

# is_bad <status> — the alarm rule, over the repo's END state ($M_* already re-measured).
# Over the loose alarm size is BAD only when this run did not shrink it: a backlog that is visibly
# draining (R_PROGRESS=1) must not page the mayor for a state they already know about.
is_bad() {
  case "$1" in failed|unmeasured|skipped-low-disk|stalled|timeout) return 0 ;; esac
  [ "$M_LOOSE_KIB" -ge "$LOOSE_ALARM_KIB" ] 2>/dev/null && [ "${R_PROGRESS:-0}" != 1 ] && return 0
  [ "$M_PACKS" -ge "$PACKS_ALARM" ] 2>/dev/null && return 0
  return 1
}

send_alarm() {  # send_alarm <repo> <status> <streak> — 0 only when the mail was really sent
  local body
  body="jsonl-archive compaction is not keeping up.
repo:    $1
status:  $2 (bad for $3 consecutive runs, every ~30m)
loose:   $(fmt "$M_LOOSE_KIB") in ${M_LOOSE_COUNT:-?} objects (limit $(fmt "$LOOSE_LIMIT_KIB"), alarm $(fmt "$LOOSE_ALARM_KIB"))
packs:   ${M_PACKS:-?} (limit $PACKS_LIMIT, alarm $PACKS_ALARM), packed $(fmt "$M_PACK_KIB")
.git:    $(fmt "$G_KIB")
log:     $LOG
state:   $STATE
Why it matters: without compaction this repo grows ~5GiB/day of loose hq.jsonl copies (ga-a3ar7h).
Nothing was deleted. Check: bash $0 --check ; then the last lines of the log.
If the status is timeout on a consolidating gc, the repo is too big for one order run (780s): run it by
hand, without a timeout, at low priority:  nice -n 10 git --git-dir=$1/.git gc   (26/09: 36 min for a 6GB backlog)."
  "$GCBIN" mail send mayor/ -s "ESCALATION: jsonl-archive compaction failing [HIGH]" -m "$body" >/dev/null 2>&1
}

# record <repo> <status> — writes the state entry, bumps/reset the bad streak, and mails when due.
record() {
  local repo="$1" status="$2" state streak last now bad=0 new
  state="$(state_json)"
  streak="$(jq -r --arg r "$repo" '.[$r].bad_streak // 0' <<<"$state" 2>/dev/null)"; is_uint "$streak" || streak=0
  last="$(jq -r --arg r "$repo" '.[$r].last_alert_epoch // 0' <<<"$state" 2>/dev/null)"; is_uint "$last" || last=0
  now="$(date +%s)"
  if is_bad "$status"; then bad=1; streak=$((streak + 1)); else streak=0; fi
  if [ "$bad" -eq 1 ] && [ "$streak" -ge "$ALERT_AFTER" ] && [ $((now - last)) -ge "$ALERT_EVERY_S" ]; then
    if send_alarm "$repo" "$status" "$streak"; then last="$now"; log "  alarm mailed to mayor ($repo, status=$status, bad_streak=$streak)"
    else log "  alarm mail FAILED — will retry next run ($repo)"; fi
  fi
  new="$(jq --arg r "$repo" --arg st "$status" --argjson streak "$streak" --argjson last "$last" --argjson now "$now" \
        --arg lk "$M_LOOSE_KIB" --arg lc "$M_LOOSE_COUNT" --arg pk "$M_PACKS" --arg pks "$M_PACK_KIB" --arg g "${G_KIB:-}" --arg bo "${R_BATCH_SAVE:-}" \
        'def n($x): (try ($x | tonumber) catch null);
         .[$r] = ((.[$r] // {}) + {last_run_epoch:$now, status:$st, loose_kib:n($lk), loose_objects:n($lc), packs:n($pk), pack_kib:n($pks), gitdir_kib:n($g), bad_streak:$streak, last_alert_epoch:$last})
         | if n($bo) != null then .[$r].batch_objects = n($bo) else . end' <<<"$state" 2>/dev/null)" || new=""
  if [ -n "$new" ]; then
    mkdir -p "$(dirname "$STATE")" 2>/dev/null
    printf '%s\n' "$new" > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE" 2>/dev/null || log "  state write failed ($STATE)"
  fi
  return "$bad"
}

BAD_ANY=0
EXISTING=0

compact_repo() {  # compact_repo <repo> — sets STATUS, returns nothing; caller handles is_bad via record
  local repo="$1" t0 before_loose before_packs before_kib batches=0 prev_count need out rc t_left b0 took timeouts=0 fast=0 saved
  R_GITDIR="$repo/.git"
  STATUS="ok"; G_KIB=""; R_PROGRESS=0; R_BATCH_SAVE=""
  t0="$(date +%s)"
  saved="$(jq -r --arg r "$repo" '.[$r].batch_objects // empty' <<<"$(state_json)" 2>/dev/null)"
  if is_uint "$saved" && [ "$saved" -ge "$BATCH_MIN" ] && [ "$saved" -le "$BATCH_MAX" ]; then R_BATCH="$saved"; else R_BATCH="$BATCH_OBJECTS"; fi

  if ! measure; then
    STATUS="unmeasured"
    log "repo=$repo status=unmeasured (git count-objects failed or returned no number — NOT treated as 0 loose)"
    return
  fi
  before_loose="$M_LOOSE_KIB"; before_packs="$M_PACKS"; before_kib="$M_PACK_KIB"

  if [ "$MODE" = check ]; then
    G_KIB="$(gitdir_kib)"
    log "repo=$repo mode=check loose=$(fmt "$M_LOOSE_KIB")/${M_LOOSE_COUNT}obj packs=$M_PACKS packed=$(fmt "$M_PACK_KIB") garbage=$(fmt "$M_GARBAGE_KIB") .git=$(fmt "$G_KIB")"
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
        if [ "$(remaining)" -lt 30 ]; then STATUS="deferred"; break; fi
        if [ "$MAX_BATCHES" -gt 0 ] && [ "$batches" -ge "$MAX_BATCHES" ]; then STATUS="deferred"; break; fi
        prev_count="$M_LOOSE_COUNT"
        t_left="$(remaining)"; [ "$t_left" -gt "$GIT_TIMEOUT_S" ] && t_left="$GIT_TIMEOUT_S"
        b0="$(date +%s)"
        out="$(git_arch "$t_left" maintenance run --task=loose-objects --quiet 2>&1)"; rc=$?
        took=$(( $(date +%s) - b0 ))
        batches=$((batches + 1))
        if [ "$rc" -eq 124 ]; then
          timeouts=$((timeouts + 1))
          if [ "$R_BATCH" -le "$BATCH_MIN" ]; then STATUS="timeout"; log "  batch $batches (${R_BATCH} objects, the minimum) timed out after ${t_left}s"; break; fi
          log "  batch $batches (${R_BATCH} objects) timed out after ${t_left}s — retrying with $(( R_BATCH / 2 > BATCH_MIN ? R_BATCH / 2 : BATCH_MIN ))"
          R_BATCH=$(( R_BATCH / 2 > BATCH_MIN ? R_BATCH / 2 : BATCH_MIN ))
          continue
        fi
        [ "$((took * 4))" -lt "$t_left" ] && fast=1 || fast=0
        if [ "$rc" -ne 0 ]; then STATUS="failed"; log "  batch $batches failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; break; fi
        # `maintenance run --task=loose-objects` prunes the loose copies of the PREVIOUS batch
        # first and packs the next one after, so this batch's own loose copies are still on disk
        # (measured: count 6 -> pack written -> count still 6 -> prune-packed -> 3). Prune them
        # now, or every batch reads as "no progress" and the loop gives up after one.
        out="$(git_arch 120 prune-packed --quiet 2>&1)"; rc=$?
        if [ "$rc" -ne 0 ]; then STATUS="failed"; log "  prune-packed after batch $batches failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; break; fi
        if ! measure; then STATUS="unmeasured"; break; fi
        if [ "$M_LOOSE_COUNT" -ge "$prev_count" ]; then STATUS="stalled"; log "  batch $batches made no progress (loose objects $prev_count -> $M_LOOSE_COUNT)"; break; fi
      done
      [ "$STATUS" = ok ] && STATUS="packed-loose"
      # grow the remembered batch once, and only after a run with no timeout whose last batch was fast
      if [ "$timeouts" -eq 0 ] && [ "$fast" -eq 1 ] && [ "$R_BATCH" -lt "$BATCH_MAX" ]; then R_BATCH=$(( R_BATCH * 2 > BATCH_MAX ? BATCH_MAX : R_BATCH * 2 )); fi
      R_BATCH_SAVE="$R_BATCH"
    fi
  fi

  # ── tier 2: too many packs → one consolidating gc, only with budget to finish ──
  measure || STATUS="unmeasured"
  if [ "$STATUS" != unmeasured ] && [ "$M_PACKS" -ge "$PACKS_LIMIT" ]; then
    need=$(( M_PACK_KIB + HEADROOM_KIB ))
    if [ "$(remaining)" -lt "$MIN_GC_BUDGET_S" ]; then
      case "$STATUS" in ok|packed-loose) STATUS="deferred" ;; esac
      log "repo=$repo packs=$M_PACKS >= $PACKS_LIMIT but only $(remaining)s of budget left — gc deferred to the next run"
    elif disk_low "$repo" "$need"; then
      STATUS="skipped-low-disk"
      log "repo=$repo status=skipped-low-disk (gc) free=$(fmt "$(free_kib "$repo")") need~$(fmt "$need") packs=$M_PACKS"
    else
      t_left="$(remaining)"; [ "$t_left" -gt "$GC_TIMEOUT_S" ] && t_left="$GC_TIMEOUT_S"
      out="$(git_arch "$t_left" -c gc.autoDetach=false gc --quiet 2>&1)"; rc=$?
      if [ "$rc" -eq 0 ]; then STATUS="consolidated"
      elif [ "$rc" -eq 124 ]; then STATUS="timeout"; log "  gc timed out after ${t_left}s"
      elif printf '%s' "$out" | grep -q 'already running'; then STATUS="busy"; log "  gc already running elsewhere — leaving it to finish"
      else STATUS="failed"; log "  gc failed rc=$rc: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; fi
    fi
  fi

  measure || STATUS="unmeasured"
  is_uint "$M_LOOSE_KIB" && [ "$M_LOOSE_KIB" -lt "$before_loose" ] && R_PROGRESS=1
  G_KIB="$(gitdir_kib)"
  log "repo=$repo status=$STATUS loose=$(fmt "$before_loose")->$(fmt "$M_LOOSE_KIB") packs=${before_packs}->${M_PACKS:-?} packed=$(fmt "$before_kib")->$(fmt "$M_PACK_KIB") .git=$(fmt "$G_KIB") batches=$batches batch=${R_BATCH} elapsed=$(( $(date +%s) - t0 ))s"
}

# ── single-flight (check mode is read-only and skips it) ──
# The lock records its owner's pid. A run SIGKILLed by the order's timeout never runs its EXIT
# trap, and an age-only rule would then skip every run for the next 90 minutes with exit 0 — a
# quiet gap in the one job this is. So a lock is stale as soon as its owner is dead (with a
# 1-minute floor for the instant between another run's mkdir and its pid write), or — when the
# owner still looks alive — after LOCK_STALE_MIN (a hung run).
lock_owner_alive() { local p; p="$(cat "$LOCK/pid" 2>/dev/null)"; is_uint "$p" && kill -0 "$p" 2>/dev/null; }
lock_release() { rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null || true; }
if [ "$MODE" = run ]; then
  command -v jq >/dev/null 2>&1 || { echo "jsonl-archive-compact: jq is required but not found in PATH" >&2; exit 1; }
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    if { ! lock_owner_alive && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; } \
       || [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
      log "stale lock (owner gone, or older than ${LOCK_STALE_MIN}m) — reclaiming"; lock_release
      mkdir "$LOCK" 2>/dev/null || { log "lock contended after reclaim — exit"; exit 0; }
    else
      log "another compaction run is in flight — exit (single-flight)"; exit 0
    fi
  fi
  echo "$$" > "$LOCK/pid" 2>/dev/null || true
  trap lock_release EXIT
fi

if [ "$MODE" = run ] && [ -s "$STATE" ] && ! jq -e . "$STATE" >/dev/null 2>&1; then
  log "state file $STATE is unreadable — starting fresh (bad-run streaks and remembered batch sizes reset)"
fi

for repo in $REPOS; do
  if [ ! -d "$repo/.git" ]; then log "repo=$repo absent — skipped"; continue; fi
  EXISTING=$((EXISTING + 1))
  compact_repo "$repo"
  if [ "$MODE" = check ]; then
    if [ "$STATUS" = unmeasured ] || is_bad "$STATUS"; then BAD_ANY=1; fi
    continue
  fi
  record "$repo" "$STATUS" || BAD_ANY=1
done

if [ "$EXISTING" -eq 0 ]; then
  log "no archive repo found under: $REPOS — nothing was compacted (a misconfigured path must not look like a healthy run)"
  exit 1
fi
[ "$BAD_ANY" -eq 0 ] || exit 1
exit 0
