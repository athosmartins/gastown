#!/bin/bash
# dolt-compact-routine.sh (ga-6uz7yn) — scheduled, guarded wrapper around
# `gc dolt compact`.
#
# WHY: hq grows ~617 commits/hour (~14.8k/day, ~1.3GB/day). At 30GB free that's
# ~22 days to the next disk squeeze — a recurring crisis (2026-08-14: disk hit
# 100%, emergency reboot, hours of human+agent time to unwedge) unless
# something runs the existing compactor BEFORE the floor is hit again. Athos's
# decision (14/08): a routine, not a bigger disk.
#
# WHAT ALREADY EXISTS — DELIBERATELY NOT REBUILT HERE:
#   `gc dolt compact` (.gc/system/packs/dolt/commands/compact/run.sh) already:
#     - skips any db below GC_DOLT_COMPACT_THRESHOLD_COMMITS (default 2000)
#     - refuses (return 1) any db with a live integrity-quarantine marker in
#       compact-quarantine/<db> — see ga-wfzmk (hq is quarantined ON PURPOSE
#       since 2026-06-06; do not touch that marker, ever, from this script)
#     - has its OWN internal single-run lock (host:port scoped)
#   This script's ONLY job is the safety envelope the bead asked for on top of
#   that: scheduling, 4 mandatory preconditions, mandatory post-verification,
#   silent steady-state, a wrapper-level lock (so the precondition-check +
#   invoke + verify sequence is atomic as a unit, not just the invoke itself).
#
# THE GC_DOLT_COMPACT_ONLY_DBS GOTCHA (why this script always sets it):
#   flatten_database() checks ONLY_DBS *before* the quarantine marker, and a
#   quarantined db hit directly (no ONLY_DBS) returns 1 — main() then always
#   `exit 1`s whenever failed_count>0. Since hq's quarantine is permanent by
#   design, a plain `gc dolt compact` invocation would exit 1 FOREVER, even on
#   a perfectly healthy day, making the exit code useless as a signal. This
#   script computes the live non-quarantined db set every run and passes it as
#   GC_DOLT_COMPACT_ONLY_DBS — hq (or any future quarantined db) is excluded
#   BEFORE compact ever evaluates it, so exit 0 stays a meaningful "fully
#   clean" signal and "never touch a quarantined db" is enforced structurally,
#   not just by trusting compact's own internal check.
#
# THE 4 PRECONDITIONS (bead's own text, ga-1dx2v's proven manual protocol):
#   1. Today's Dolt backup closed ok=N failed=0 (scripts/dolt-s3-backup.sh's
#      log at .gc/logs/dolt-s3-backup.log — the only durable, parseable
#      record; there is no per-db staging dir on this host, verified).
#   2. Disk headroom >= HEADROOM_MULTIPLIER (default 2x) the size of the
#      LARGEST eligible (non-quarantined) db. Deliberately conservative: does
#      NOT replicate compact's own below-threshold skip logic (a below-
#      threshold db inflating this bound only makes it MORE conservative,
#      never less safe — reimplementing that logic is exactly what this bead
#      says not to do).
#   3. City quiet: 0 gate markers/runs in gate-status:dispatching|claimed|
#      running (queued/ready/needs-rebase are idle-queue states and do not
#      block — see header comment on _check_quiet for why this script does
#      NOT reuse inflight-reclaim-guard.py's list_gate_active_source_beads()
#      label set verbatim).
#   4. GC_DOLT_COMPACT_CALL_TIMEOUT_SECS generous (>=300s) AND an outer
#      process timeout on the whole invocation, belt-and-suspenders — compact's
#      own coded default (1800s) is already generous, but this script never
#      trusts an unverified assumption about "the default" over an explicit
#      floor of its own.
#
# Precondition failure = ALWAYS log + notify (the bead's own AC: "falha em
# qualquer uma = não roda + alerta explicando qual faltou") — this is safe to
# be unconditional because 04:30 is chosen specifically as a normally-quiet
# window (ga-1dx2v: "foi quando load caiu pra 6 e a fila do gate zerou"), so a
# refusal at that hour is itself an actionable, rare signal, not daily noise.
#
# STEADY-STATE SILENCE: when preconditions pass but compact finds nothing to
# do (every eligible db still below threshold — the common case, since a db
# only crosses ~2000 commits every ~2 weeks), this script logs only, no
# notify. This is detected by parsing compact's own stdout for the
# "— flattening..." line (the only line that marks a REAL attempt, not a
# skip) rather than trusting compact's exit code alone (see ONLY_DBS gotcha
# above for why exit code alone is not trustworthy).
#
# MANDATORY POST-VERIFICATION (bead's own AC, ga-wfzmk's exact protocol):
# for every ELIGIBLE db (attempted or not — a skipped db verifying clean too
# is a free structural sanity check that compact confined its blast radius),
# compare before/after: total bead count (bd count, which — verified live —
# excludes the ephemeral/infra tier by default, so ordinary gate-marker/
# session churn during the ~1min compact window cannot false-positive this;
# only real work-item creation/closure can, which the quiet-window scheduling
# choice above already minimizes) and one control bead's comment_count (the
# OLDEST non-ephemeral bead in that db — `list --sort created --reverse
# --limit 1`, no --include-infra — chosen specifically because new activity
# can never displace position 0, unlike sorting by id). ANY divergence in
# either signal, or `gc dolt status` failing post-run, writes a HALT sentinel
# and mails the Mayor — the bead is explicit: "não rodar de novo até revisão
# humana." disk-gain and bd-latency are measured and reported but are NOT
# divergence triggers (informational only — ga-wfzmk's own healthy run had
# ~zero gain some days, which is not a failure).
#
# OUT OF SCOPE (bead's own text): touching any quarantine marker, compacting
# hq, the engine window. This script never writes to compact-quarantine/.
#
# TEST: bash scripts/dolt-compact-routine.selftest.sh
# Library mode: DOLT_COMPACT_ROUTINE_LIB=1 source dolt-compact-routine.sh
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
DOLTDIR="$CITY/.beads/dolt"
QUARANTINE_DIR="$CITY/.gc/runtime/packs/dolt/compact-quarantine"
LOG="${DOLT_COMPACT_ROUTINE_LOG:-$CITY/.gc/logs/dolt-compact-routine.log}"
BACKUP_LOG="${DOLT_COMPACT_ROUTINE_BACKUP_LOG:-$CITY/.gc/logs/dolt-s3-backup.log}"
NOTIFY="/Users/athos/.local/bin/notify"
GC="${GC_BIN:-gc}"
BD="$(command -v bd 2>/dev/null || echo /Users/athos/.local/bin/bd)"
# ga-jz7gg: dolt-backup-reseed.sh (ga-ydrg9) re-seeds ONE db's .dolt-backup
# staging dir. .dolt-backup is append-only, so a compaction's history-squash
# never shrinks it on its own — without this hook, orphan blobs accumulate
# exactly like the 3 prior incidents this story cites (9.6G/12G/13G). The
# reseed script owns its own disk/data preflight; this hook never duplicates
# that logic, only decides WHEN to call it (after a real, clean-verified
# flatten of that specific db).
RESEED_SCRIPT="$CITY/scripts/dolt-backup-reseed.sh"

ENABLED="${DOLT_COMPACT_ROUTINE_ENABLED:-1}"

HEADROOM_MULTIPLIER="${DOLT_COMPACT_HEADROOM_MULTIPLIER:-2}"
# _backup_today_ok requires "today" (same calendar date as this run, local
# time — matches the backup log's own local timestamps: ts() in
# dolt-s3-backup.sh uses plain `date`, not UTC, so this is a same-clock
# comparison, not a UTC/local mismatch — see
# gate-diagnostic-timezone-comparison-false-stall for the failure this
# avoids). Not configurable — the bead's own AC is unconditional here.

# Outer process bound on the WHOLE `gc dolt compact` invocation (all eligible
# dbs, sequential). 3600s is generous versus the one measured real run (55s
# for a 6GB db) while still bounded — a wedged call must not hang this script
# (and hold its lock) forever. Distinct from GC_DOLT_COMPACT_CALL_TIMEOUT_SECS,
# which bounds each individual SQL CALL inside compact, not the whole process.
OUTER_TIMEOUT_SECS="${DOLT_COMPACT_OUTER_TIMEOUT_SECS:-3600}"
# Floor for GC_DOLT_COMPACT_CALL_TIMEOUT_SECS — compact's own coded default is
# 1800 (verified in run.sh), already above the bead's ">=300" ask, but this
# script sets an explicit floor rather than trust an unverified assumption
# about which default is actually in effect at call time.
CALL_TIMEOUT_FLOOR="${DOLT_COMPACT_CALL_TIMEOUT_FLOOR:-300}"
# Bound for each individual `bd -C <rig>` query in the post-verification
# loop (_snapshot_db / _rescan_control_bead) and the final bd-latency probe.
# Dolt can be briefly overloaded right after a compact/DOLT_GC call; without
# this, a hung query here is caught only by the wrapper lock's age-based
# reclaim (LOCK_MAX_AGE, much later) instead of failing loud and fast.
BD_QUERY_TIMEOUT_SECS="${DOLT_COMPACT_BD_QUERY_TIMEOUT_SECS:-30}"

HALT_SENTINEL="${DOLT_COMPACT_HALT_SENTINEL:-$CITY/.gc/logs/.dolt-compact-routine.HALT}"

# ── single-instance lock: same mechanism as quality-gate-dispatcher.sh's
# GATE_LOCK (mkdir-atomic + heartbeat mtime + PID:RANDOM token + single-
# winner staleness reclaim) — named per ga-y0g5x's explicit "the same
# pattern... não invente outro" ruling. LOCK_MAX_AGE is set above
# OUTER_TIMEOUT_SECS with margin: this script writes its heartbeat ONCE at
# acquire (no long-poll loop to refresh it mid-run, unlike the gate
# dispatcher), so the age tolerance must alone cover the worst-case full
# runtime or a second invocation (manual re-trigger while the scheduled one
# is still legitimately running) could steal the lock mid-operation.
LOCK_DIR="${DOLT_COMPACT_LOCK_DIR:-${TMPDIR:-/tmp}/dolt-compact-routine$(printf '%s' "$CITY" | tr '/ ' '__').lock.d}"
LOCK_HB="$LOCK_DIR/heartbeat"
LOCK_MAX_AGE="${DOLT_COMPACT_LOCK_MAX_AGE:-5400}"
LOCK_REAP_TTL="${DOLT_COMPACT_LOCK_REAP_TTL:-10}"
LOCK_TOKEN="${DOLT_COMPACT_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"
[ "${LOCK_TOKEN%%:*}" = "$$" ] || LOCK_TOKEN="$$:${RANDOM}${RANDOM}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE / LOW-SIDE-EFFECT DECISION FUNCTIONS — unit-tested by
# dolt-compact-routine.selftest.sh. Each takes explicit inputs so the selftest
# can drive them without a live Dolt/gc/bd.
# ════════════════════════════════════════════════════════════════════════════

# _avail_mb [path] — same idiom as dolt-disk-floor-guard.sh's _avail_gb, but
# stops at MB (not GB): `df -k` + one division (macOS/BSD df has no -g).
# Empty (not 0) on failure — a failed read must never read the same as
# "plenty of room" (error and empty must not produce the same value). MB, not
# GB: see _largest_db_mb for why whole-GB truncation is unsafe here.
_avail_mb() {
  local path="${1:-$DOLTDIR}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo $(( kb / 1024 ))
}

# _is_quarantined <db> — EXACT filename match only. A resolved/released
# marker (renamed with a suffix, e.g. "whatsapp_automation.resolvido-ga-wfzmk"
# — see ga-1dx2v) does NOT match a bare db name and is correctly treated as
# released; this script never touches the quarantine directory itself.
_is_quarantined() {
  [ -f "$QUARANTINE_DIR/$1" ]
}

# _rig_list_json — thin wrapper around `gc rig list --json`, isolated so the
# selftest can stub it instead of touching the live registry.
_rig_list_json() { "$GC" rig list --json 2>/dev/null; }

# _db_rig_paths <rig_list_json> — echoes "db_name<TAB>rig_path" for every
# registered rig, keyed by THAT RIG'S OWN dolt_database (read from its
# .beads/metadata.json), never by the rig's .name. Rig name and db name can
# differ — e.g. rig "deacon" -> db "dc" (verified live, ga-6uz7yn adversarial
# review) — so matching by name would silently miss/mismatch entries. A rig
# whose metadata.json is missing/unreadable is skipped (not fabricated as a
# blank mapping — see _enumerate_eligible_dbs for why an unmapped db must be
# excluded, not defaulted to some path).
_db_rig_paths() {
  local json="$1" path db
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    db="$(jq -r '.dolt_database // empty' "$path/.beads/metadata.json" 2>/dev/null)"
    [ -n "$db" ] && printf '%s\t%s\n' "$db" "$path"
  done < <(printf '%s' "$json" | jq -r '.rigs[]?.path // empty' 2>/dev/null)
}

# _rig_path_for_db <db> <db_rig_paths> — pure lookup into the db_rig_paths
# table built by _db_rig_paths. Empty if db has no rig mapping.
_rig_path_for_db() {
  local db="$1" table="$2"
  printf '%s\n' "$table" | awk -F'\t' -v d="$db" '$1==d{print $2; exit}'
}

# _enumerate_eligible_dbs <doltdir> <quarantine_dir> <db_rig_paths> —
# newline-separated list of db names under doltdir that (a) have no live
# quarantine marker AND (b) resolve to a real rig checkout in db_rig_paths.
#
# (b) is not cosmetic filtering — it is THE fix for ga-6uz7yn's adversarial
# review finding 1: `bd -C "$doltdir/$db"` does NOT scope to that database.
# Every path under $CITY/.beads/dolt/* is nested INSIDE $CITY/.beads/, so
# `bd -C` (which walks UP to the nearest ancestor .beads/metadata.json, same
# as `git -C`) always re-resolves to the CITY's own metadata.json — which
# hardcodes dolt_database=hq — regardless of which subdirectory was passed.
# Verified empirically: `bd -C "$DOLTDIR/whatsapp_automation" count` and
# `bd -C "$DOLTDIR/property_scrapers" count` both returned hq's count, not
# whatsapp_automation's/property_scrapers' own (3288 and 283 respectively,
# via each rig's REAL checkout path). The only correct way to query a
# specific database's own content is through ITS OWN registered rig checkout
# (which has its own .beads/metadata.json declaring its own dolt_database),
# resolved via _db_rig_paths — never by constructing a path under $doltdir.
#
# A db with NO rig mapping (verified live: `beads` and 3 `fixdepkeys_*`
# scratch/migration-artifact databases have no registered rig at all) cannot
# be verified this way, so it is excluded from eligibility ENTIRELY — not
# just from verification. This is deliberate: this routine's ONLY_DBS and
# its post-verification target set are the SAME list (see _decide_and_run) —
# a database this routine cannot verify must never be one it compacts,
# because an unverifiable compaction is exactly the blind spot ga-wfzmk
# investigated. These four are small (beads ~2MB, each fixdepkeys_* ~2.8MB —
# live `du` measurement; an earlier draft of this comment said "sub-1MB",
# caught wrong by the ga-6uz7yn adversarial review) and essentially certain
# to never cross the commit threshold anyway, so the practical cost of
# excluding them is negligible.
_enumerate_eligible_dbs() {
  local dd="${1:-$DOLTDIR}" qd="${2:-$QUARANTINE_DIR}" db_rig_paths="$3" dir db path
  for dir in "$dd"/*/; do
    [ -d "$dir" ] || continue
    db="$(basename "$dir")"
    [ -f "$qd/$db" ] && continue
    path="$(_rig_path_for_db "$db" "$db_rig_paths")"
    [ -n "$path" ] && printf '%s\n' "$db"
  done
}

# _largest_db_mb <doltdir> <db-list-newline-separated> — max `du -sm` across
# the given dbs under doltdir. MB, not GB: `du -sg` TRUNCATES to whole GB, so
# any eligible db under 1GB would read as size 0 — and _headroom_ok(avail, 0,
# mult) is "avail >= 0", trivially true regardless of how little disk is
# actually free. MB granularity closes that gap at negligible cost (the
# largest real db here is currently ~1-2GB, so `du -sm` is still fast).
# Echoes 0 if the list is empty or every size read fails (an empty ELIGIBLE
# set is a legitimate "nothing to size against" case, not an error — contrast
# _avail_mb, which distinguishes empty-as-error).
_largest_db_mb() {
  local dd="$1" list="$2" db size max=0
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    size="$(du -sm "$dd/$db" 2>/dev/null | awk '{print $1}')"
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -gt "$max" ] && max="$size"
  done <<EOF
$list
EOF
  echo "$max"
}

# _headroom_ok <avail_gb> <largest_gb> <multiplier> — pure arithmetic. Empty/
# non-numeric avail (df failed) or largest never reads as "ok" (fail-closed —
# this gates an irreversible operation).
_headroom_ok() {
  local avail="$1" largest="$2" mult="$3"
  case "$avail" in ''|*[!0-9]*) return 1 ;; esac
  case "$largest" in ''|*[!0-9]*) return 1 ;; esac
  case "$mult" in ''|*[!0-9]*) return 1 ;; esac
  [ "$avail" -ge $(( largest * mult )) ]
}

# _backup_today_ok <backup_log_path> <today_yyyy-mm-dd> <eligible-db-list> —
# parses the LAST "=== run start ===".."=== run complete ===" block in the
# real dolt-s3-backup.sh log. Returns 0 only if: the block's timestamp date
# matches today, its "run complete" line shows failed=0, and every eligible
# db appears as "<db>: OK" somewhere in that block. Missing log / no runs /
# any parse failure -> 1 (fail-closed).
_backup_today_ok() {
  local log="$1" today="$2" dbs="$3" block start_line db
  [ -f "$log" ] || { echo "no backup log at $log"; return 1; }
  # Last run's block: from the LAST "run start" line to end of file.
  block="$(awk '/=== run start/{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$log" 2>/dev/null)"
  [ -n "$block" ] || { echo "backup log has no run-start marker"; return 1; }
  start_line="$(printf '%s' "$block" | grep -m1 '=== run start')"
  case "$start_line" in
    "[$today "*) ;;
    *) echo "latest backup run is not from today ($today): $start_line"; return 1 ;;
  esac
  if ! printf '%s' "$block" | grep -qE '=== run complete: ok=[0-9]+ failed=0 total=[0-9]+ ==='; then
    echo "latest backup run did not close failed=0: $(printf '%s' "$block" | grep -m1 'run complete')"
    return 1
  fi
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    if ! printf '%s' "$block" | grep -qE "\] ${db}: OK \("; then
      echo "backup block does not list ${db}: OK"
      return 1
    fi
  done <<EOF
$dbs
EOF
  return 0
}

# _classify_compact_output <captured-stdout> — echoes newline-separated db
# names that reached the real "— flattening..." line (an ACTUAL attempt, not
# a below-threshold or ONLY_DBS skip). Empty output = pure no-op run.
_classify_compact_output() {
  printf '%s\n' "$1" | grep -E '^compact: db=[^ ]+ commits=[0-9]+ root=.* — flattening\.\.\.$' \
    | sed -E 's/^compact: db=([^ ]+) .*/\1/'
}

# _gate_quiet <dispatching> <claimed> <running> <reviewing> — pure arithmetic
# over the 4 live counts _check_quiet gathers. Non-numeric (a failed/errored
# bd query) never reads as quiet — fail-closed, matching this gate's role in
# front of an irreversible operation.
_gate_quiet() {
  local d="$1" c="$2" r="$3" v="$4"
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$c" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in ''|*[!0-9]*) return 1 ;; esac
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$d" -eq 0 ] && [ "$c" -eq 0 ] && [ "$r" -eq 0 ] && [ "$v" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════════════
# LOCK — mkdir-atomic + heartbeat-mtime + PID:RANDOM token, single-winner
# stale reclaim. Verbatim shape of quality-gate-dispatcher.sh's GATE_LOCK
# (ga-T1 hardening included) — see this file's header for why that exact
# pattern, not dolt-s3-backup.sh's simpler mtime-only lock, was reused.
# ════════════════════════════════════════════════════════════════════════════

_lock_path_age() {
  local p="$1" mt now
  now=$(date +%s)
  mt=$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo "")
  [ -z "$mt" ] && { echo 999999999; return; }
  echo $(( now - mt ))
}
_lock_hb_age() { _lock_path_age "$LOCK_HB"; }

_lock_holder_dead() {
  local pid
  pid=$(head -n1 "$LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

_lock_write_hb() { printf '%s\n' "$LOCK_TOKEN" > "$LOCK_HB" 2>/dev/null || true; }

_release_lock() {
  local own
  own=$(head -n1 "$LOCK_HB" 2>/dev/null || true)
  [ "$own" = "$LOCK_TOKEN" ] && rm -rf "$LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE run holds it (back off, silently
# — a second invocation deferring to a live one is serialization, not error).
_acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    _lock_write_hb
    if [ ! -s "$LOCK_HB" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  local age
  age=$(_lock_hb_age)
  if [ "$age" -lt "$LOCK_MAX_AGE" ] && ! _lock_holder_dead; then
    return 1
  fi
  if [ ! -s "$LOCK_HB" ]; then
    return 1   # holder mid-mkdir/hb-write race — treat as live, back off
  fi
  local reaping="${LOCK_DIR}.reaping"
  if ! mkdir "$reaping" 2>/dev/null; then
    if [ "$(_lock_path_age "$reaping")" -ge "$LOCK_REAP_TTL" ]; then
      local dead="${reaping}.dead.${LOCK_TOKEN}"
      if mv "$reaping" "$dead" 2>/dev/null; then rm -rf "$dead" 2>/dev/null || true; fi
    fi
    if ! mkdir "$reaping" 2>/dev/null; then
      return 1
    fi
  fi
  if [ "$(_lock_hb_age)" -lt "$LOCK_MAX_AGE" ] && ! _lock_holder_dead; then
    rmdir "$reaping" 2>/dev/null || true
    return 1
  fi
  _lock_write_hb
  if [ ! -s "$LOCK_HB" ]; then
    rmdir "$reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$reaping" 2>/dev/null || true
  log "recovered STALE lock (heartbeat age ${age}s >= ${LOCK_MAX_AGE}s) — taking over"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# LIVE-QUERY WRAPPERS — side-effecting reads, kept thin so the selftest can
# override each one individually and drive _decide_and_run end-to-end without
# a live Dolt/gc/bd.
# ════════════════════════════════════════════════════════════════════════════

_check_backup() {
  local reason
  reason="$(_backup_today_ok "$BACKUP_LOG" "$(date '+%Y-%m-%d')" "$ELIGIBLE_DBS")" && return 0
  _REASON="backup precondition failed: $reason"
  return 1
}

_check_headroom() {
  local avail largest
  avail="$(_avail_mb "$DOLTDIR")"
  largest="$(_largest_db_mb "$DOLTDIR" "$ELIGIBLE_DBS")"
  _headroom_ok "$avail" "$largest" "$HEADROOM_MULTIPLIER" && return 0
  _REASON="headroom precondition failed: avail=${avail:-?}MB largest-eligible=${largest:-?}MB need>=$(( largest * HEADROOM_MULTIPLIER ))MB (${HEADROOM_MULTIPLIER}x)"
  return 1
}

# "City quiet": counts markers with type:quality-gate-marker in each of 4
# ACTIVE gate-status states. Deliberately NOT inflight-reclaim-guard.py's
# list_gate_active_source_beads() label set (ready+dispatching+queued+
# claimed) verbatim — that function answers "is the dispatcher still working
# this bead's claim" (its own consumer's question), which counts idle
# ready/queued markers as "active" (over-cautious re: this script's actual
# concern, Dolt load) while omitting gate-status:running (a reviewer actually
# executing — the state most likely to be generating real Dolt load, and
# under-cautious to omit). This script's own live measurement matches the
# bead's own text instead: "0 gate-runs ativos, 0 markers dispatching" ==
# dispatching+claimed+running == 0; queued/ready/needs-rebase are idle-queue
# states and legitimately nonzero.
#
# gate-status:reviewing is included too (ga-6uz7yn adversarial review finding
# 1): grep across scripts/*.py and *.sh shows no CURRENT writer of this exact
# label value (a live query confirms 0 today), but gate-orphaned-label-
# watchdog.sh's own state-list comment and gate-recovery-watchdog.py's FIX 6
# both treat "reviewing" as functionally equivalent to "dispatching" — a
# review in progress, no live run yet. Omitting a currently-dead label costs
# nothing (it can only ever contribute 0); the risk was in NOT checking it if
# that label is ever written again, since gate-status:reviewing dropping in
# would then silently pass this precondition as "quiet" while a real review
# was active — exactly the fail-open shape this precondition exists to avoid.
_check_quiet() {
  local d c r v out
  # jq 'length' on the parsed array — NOT grep -c '"id"' — deliberately: a
  # substring count is only correct if bd emits one-key-per-line pretty JSON
  # AND no object anywhere (e.g. a dependency entry) has its own nested "id"
  # field. Compact single-line JSON would make grep -c undercount every
  # multi-marker result down to "1" — a dangerous false-"quiet" direction for
  # a precondition gating an irreversible operation. jq counts array elements
  # regardless of formatting.
  out="$($BD -C "$CITY" list --include-infra --label "type:quality-gate-marker" --label "gate-status:dispatching" --status open,in_progress --json --limit 0 2>/dev/null)" \
    && d="$(printf '%s' "$out" | jq 'length' 2>/dev/null)" || d=""
  out="$($BD -C "$CITY" list --include-infra --label "type:quality-gate-marker" --label "gate-status:claimed" --status open,in_progress --json --limit 0 2>/dev/null)" \
    && c="$(printf '%s' "$out" | jq 'length' 2>/dev/null)" || c=""
  out="$($BD -C "$CITY" list --include-infra --label "type:quality-gate-marker" --label "gate-status:running" --status open,in_progress --json --limit 0 2>/dev/null)" \
    && r="$(printf '%s' "$out" | jq 'length' 2>/dev/null)" || r=""
  out="$($BD -C "$CITY" list --include-infra --label "type:quality-gate-marker" --label "gate-status:reviewing" --status open,in_progress --json --limit 0 2>/dev/null)" \
    && v="$(printf '%s' "$out" | jq 'length' 2>/dev/null)" || v=""
  _gate_quiet "$d" "$c" "$r" "$v" && return 0
  _REASON="quiet-city precondition failed: dispatching=${d:-UNKNOWN} claimed=${c:-UNKNOWN} running=${r:-UNKNOWN} reviewing=${v:-UNKNOWN} (need all 0)"
  return 1
}

_preconditions_ok() {
  _REASON=""
  _check_backup   || return 1
  _check_headroom || return 1
  _check_quiet    || return 1
  return 0
}

# ── baseline / verification (per eligible db: total count + one stable
# control bead's comment_count) ────────────────────────────────────────────

# _snapshot_db <rig_path> — echoes "count controlbead_id controlbead_comments"
# (or "ERR ERR ERR" on any read failure — never silently substitutes 0, which
# would make a genuine read failure indistinguishable from a real empty db).
#
# <rig_path> MUST be a real registered rig checkout (from _db_rig_paths /
# _rig_path_for_db) — NEVER a path under $DOLTDIR/. `bd -C` walks UP to the
# nearest ancestor .beads/metadata.json exactly like `git -C` walks up to the
# nearest .git — a path under $DOLTDIR ($CITY/.beads/dolt/<db>) is nested
# INSIDE $CITY/.beads/, so it always re-resolves to the CITY's own
# metadata.json (dolt_database=hq) regardless of which db subdirectory was
# named. This was ga-6uz7yn's adversarial-review finding 1 — verified live,
# every $DOLTDIR/<db> path returned hq's count, never the target db's own.
#
# Bounded by BD_QUERY_TIMEOUT_SECS: this runs right after a `gc dolt compact`
# call that may have just triggered DOLT_GC, and this codebase's own history
# (dolt-cpu-root-is-poll-frequency, dolt-hang-watchdog) shows Dolt can be
# briefly overloaded post-compaction — an unbounded query here would only be
# caught by the outer lock's age-based reclaim (LOCK_MAX_AGE), far too late.
_snapshot_db() {
  local dir="$1" cnt cb_json cb_id cb_cc
  cnt="$(timeout "$BD_QUERY_TIMEOUT_SECS" "$BD" -C "$dir" count --json 2>/dev/null | jq -r '.count // empty' 2>/dev/null)"
  case "$cnt" in ''|*[!0-9]*) echo "ERR ERR ERR"; return ;; esac
  # Oldest non-ephemeral bead (no --include-infra): new activity during the
  # compact window can only be NEWER, so it can never displace this pick —
  # unlike sorting by id, which is not guaranteed chronological. Indexed via
  # jq (.[0].id / .[0].comment_count), not grep — a grep for a bare "id"
  # substring risks matching a NESTED id (e.g. inside a dependencies array)
  # instead of the top-level bead id.
  cb_json="$(timeout "$BD_QUERY_TIMEOUT_SECS" "$BD" -C "$dir" list --sort created --reverse --status open,in_progress,blocked,deferred,closed --json --limit 1 2>/dev/null)"
  cb_id="$(printf '%s' "$cb_json" | jq -r '.[0].id // empty' 2>/dev/null)"
  if [ -z "$cb_id" ]; then
    # Empty db (0 beads) is legitimate — cnt=0 with no control bead is not an
    # error in that case; anything else with no control bead is suspicious.
    if [ "$cnt" = "0" ]; then echo "0 NONE 0"; return; fi
    echo "ERR ERR ERR"; return
  fi
  cb_cc="$(printf '%s' "$cb_json" | jq -r '.[0].comment_count // empty' 2>/dev/null)"
  case "$cb_cc" in ''|*[!0-9]*) echo "ERR ERR ERR"; return ;; esac
  echo "$cnt $cb_id $cb_cc"
}

# _rescan_control_bead <rig_path> <id> — re-fetches BY THE SAME ID (not by
# re-running the sort query) so a vanished bead is detected as vanished, not
# silently replaced by whatever now sorts first. Echoes comment_count or
# "MISSING" / "ERR". Same rig_path requirement and timeout bound as
# _snapshot_db above.
_rescan_control_bead() {
  local dir="$1" id="$2" json cc
  [ "$id" = "NONE" ] && { echo "0"; return; }
  json="$(timeout "$BD_QUERY_TIMEOUT_SECS" "$BD" -C "$dir" show "$id" --json 2>/dev/null)"
  [ -z "$json" ] && { echo "MISSING"; return; }
  # `bd show --json` returns a single object OR a 1-element array depending
  # on version (verified inconsistently across this codebase's own memory
  # notes) — try both shapes rather than assume one.
  cc="$(printf '%s' "$json" | jq -r 'if type=="array" then .[0].comment_count else .comment_count end // empty' 2>/dev/null)"
  case "$cc" in ''|*[!0-9]*) echo "ERR" ;; *) echo "$cc" ;; esac
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the pure-function selftest
# cases — the selftest instead stubs _check_backup/_check_headroom/
# _check_quiet/_run_compact and drives _decide_and_run directly).
# ════════════════════════════════════════════════════════════════════════════

# _run_compact <only_dbs_csv> — the ONE function that actually invokes the
# real tool. Isolated so the selftest can override it with a call-counting
# stub and prove _decide_and_run never reaches it when a precondition fails.
# Sets _COMPACT_STDOUT and _COMPACT_RC as globals (avoids relying on
# command-substitution + $? across the outer `timeout`, which would lose
# stdout on a timeout kill otherwise).
_run_compact() {
  local only_dbs="$1" call_timeout="$CALL_TIMEOUT_FLOOR"
  [ "${GC_DOLT_COMPACT_CALL_TIMEOUT_SECS:-0}" -gt "$call_timeout" ] 2>/dev/null \
    && call_timeout="$GC_DOLT_COMPACT_CALL_TIMEOUT_SECS"
  _COMPACT_STDOUT="$(cd "$CITY" && GC_DOLT_COMPACT_ONLY_DBS="$only_dbs" GC_DOLT_COMPACT_CALL_TIMEOUT_SECS="$call_timeout" \
    timeout "$OUTER_TIMEOUT_SECS" "$GC" dolt compact 2>&1)"
  _COMPACT_RC=$?
}

_halt() {
  local reason="$1"
  {
    echo "HALTED $(ts)"
    echo "reason: $reason"
    echo "to resume: review the reason above, then: rm '$HALT_SENTINEL'"
  } > "$HALT_SENTINEL" 2>/dev/null || true
  log "HALT written: $reason"
  "$NOTIFY" -t "Dolt compact routine" -p 5 "🚨 HALTED — verification divergence, needs human review before next run. See $HALT_SENTINEL" 2>/dev/null || true
  local mail_body="dolt-compact-routine.sh detected a post-compaction verification divergence and HALTED (will refuse to run again until a human clears the sentinel).

$reason

This is the exact class of risk ga-wfzmk investigated (post-flatten hash/row-count drift) — do not assume this is benign without checking what actually changed in the affected db. If it IS benign (e.g. ordinary bead activity landed inside the ~1min compact window), clear it with: rm '$HALT_SENTINEL'
Full log: $LOG"
  "$GC" mail send mayor -s "Dolt compact routine HALTED — verification divergence" -m "$mail_body" 2>/dev/null || log "WARN: gc mail send mayor failed"
}

_decide_and_run() {
  if [ "$ENABLED" != "1" ]; then
    log "SKIP — DOLT_COMPACT_ROUTINE_ENABLED=0"
    return 0
  fi
  if [ -f "$HALT_SENTINEL" ]; then
    log "SKIP — HALT sentinel present ($HALT_SENTINEL) — needs human review"
    "$NOTIFY" -t "Dolt compact routine" -p 3 "⏸️ still HALTED (verification divergence pending human review) — see $HALT_SENTINEL" 2>/dev/null || true
    return 0
  fi

  if ! _acquire_lock; then
    log "SKIP — another run holds the lock"
    return 0
  fi
  trap '_release_lock' RETURN

  DB_RIG_PATHS="$(_db_rig_paths "$(_rig_list_json)")"
  ELIGIBLE_DBS="$(_enumerate_eligible_dbs "$DOLTDIR" "$QUARANTINE_DIR" "$DB_RIG_PATHS")"
  if [ -z "$ELIGIBLE_DBS" ]; then
    log "no eligible (non-quarantined, rig-verifiable) databases found under $DOLTDIR — nothing to do"
    return 0
  fi

  if ! _preconditions_ok; then
    log "REFUSE — $_REASON"
    "$NOTIFY" -t "Dolt compact routine" -p 3 "⚠️ refused today — $_REASON" 2>/dev/null || true
    return 0
  fi

  # ── baseline (right before invoking — tightest possible window) ─────────
  local db baseline_before="" baseline_after="" line rig_path
  local db_sizes_before="" db_sizes_after=""
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    rig_path="$(_rig_path_for_db "$db" "$DB_RIG_PATHS")"
    line="$(_snapshot_db "$rig_path")"
    baseline_before="${baseline_before}${db}=${line}"$'\n'
    db_sizes_before="${db_sizes_before}${db}=$(du -sm "$DOLTDIR/$db" 2>/dev/null | awk '{print $1}')"$'\n'
  done <<EOF
$ELIGIBLE_DBS
EOF

  local only_dbs_csv; only_dbs_csv="$(printf '%s' "$ELIGIBLE_DBS" | paste -sd, -)"
  log "invoking: GC_DOLT_COMPACT_ONLY_DBS=$only_dbs_csv (outer timeout ${OUTER_TIMEOUT_SECS}s)"
  _run_compact "$only_dbs_csv"
  log "compact rc=$_COMPACT_RC output:"
  printf '%s\n' "$_COMPACT_STDOUT" >> "$LOG" 2>/dev/null || true

  local attempted; attempted="$(_classify_compact_output "$_COMPACT_STDOUT")"
  if [ -z "$attempted" ]; then
    if [ "$_COMPACT_RC" -eq 0 ]; then
      log "NOOP — every eligible db below threshold or otherwise skipped; nothing attempted (silent, steady state)"
      return 0
    fi
    # rc!=0 with nothing attempted is unexpected (ONLY_DBS should prevent the
    # quarantine-exit-1 gotcha) — treat as a refusal-class alert, not a silent
    # noop, and not a full verification HALT (nothing was touched to verify).
    log "REFUSE — compact exited rc=$_COMPACT_RC with no db reaching flattening; see output above"
    "$NOTIFY" -t "Dolt compact routine" -p 4 "⚠️ gc dolt compact exited rc=$_COMPACT_RC with nothing attempted — check $LOG" 2>/dev/null || true
    return 0
  fi

  # ── something was attempted: mandatory post-verification for EVERY
  # eligible db (attempted or not — see header) ────────────────────────────
  local divergences="" gain_report=""

  # rc!=0 alongside a non-empty $attempted means a DIFFERENT eligible db
  # failed inside this same compact invocation (e.g. its own post-flatten
  # verify_counts found a real drift and flatten_database newly quarantined
  # it — the exact class of risk ga-wfzmk investigated) while another db
  # flattened cleanly. This is NOT a case remote-push failures can trigger
  # (compact records those as pending-push markers and always returns 0 for
  # them; only real per-db integrity/probe failures return 1 to main()) — so
  # a nonzero rc here is a genuine per-db failure signal, and the per-db
  # bead-count/control-bead check below is too coarse to be trusted to catch
  # it on its own (DOLT_HASHOF_TABLE drift on a table `bd` doesn't surface
  # through count/comment_count can pass that check while compact's own,
  # stricter internal verification already quarantined the db). Fold it into
  # the SAME divergences+HALT path rather than letting a bare "✅ compacted"
  # notify mask a real failure elsewhere in the run.
  if [ "$_COMPACT_RC" -ne 0 ]; then
    divergences="${divergences}gc dolt compact exited rc=$_COMPACT_RC even though db(s) [$(printf '%s' "$attempted" | paste -sd, -)] reached flattening — another eligible db likely failed (e.g. newly quarantined by compact's own verify_counts); do not trust the bead-count check alone to rule this out, see $LOG for the full compact output"$'\n'
  fi
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    rig_path="$(_rig_path_for_db "$db" "$DB_RIG_PATHS")"
    line="$(_snapshot_db "$rig_path")"
    baseline_after="${baseline_after}${db}=${line}"$'\n'
    db_sizes_after="${db_sizes_after}${db}=$(du -sm "$DOLTDIR/$db" 2>/dev/null | awk '{print $1}')"$'\n'

    local before_line after_line b_cnt b_id b_cc a_cnt a_cc
    before_line="$(printf '%s' "$baseline_before" | grep "^${db}=" | sed "s/^${db}=//")"
    after_line="$(printf '%s' "$baseline_after"   | grep "^${db}=" | sed "s/^${db}=//")"
    b_cnt="$(echo "$before_line" | awk '{print $1}')"; b_id="$(echo "$before_line" | awk '{print $2}')"; b_cc="$(echo "$before_line" | awk '{print $3}')"
    a_cnt="$(echo "$after_line"  | awk '{print $1}')"

    if [ "$b_cnt" = "ERR" ] || [ "$a_cnt" = "ERR" ]; then
      divergences="${divergences}db=${db}: could not read bead count (before='${b_cnt}' after='${a_cnt}') — treat as UNKNOWN, not clean"$'\n'
      continue
    fi
    if [ "$b_cnt" != "$a_cnt" ]; then
      divergences="${divergences}db=${db}: bead count changed ${b_cnt} -> ${a_cnt}"$'\n'
    fi
    if [ "$b_id" != "ERR" ]; then
      a_cc="$(_rescan_control_bead "$rig_path" "$b_id")"
      case "$a_cc" in
        MISSING) divergences="${divergences}db=${db}: control bead ${b_id} is MISSING after compact"$'\n'  ;;
        ERR)     divergences="${divergences}db=${db}: could not re-read control bead ${b_id} after compact"$'\n' ;;
        *) [ "$a_cc" != "$b_cc" ] && divergences="${divergences}db=${db}: control bead ${b_id} comment_count changed ${b_cc} -> ${a_cc}"$'\n' ;;
      esac
    fi

    local bsz asz; bsz="$(printf '%s' "$db_sizes_before" | grep "^${db}=" | sed "s/^${db}=//")"; asz="$(printf '%s' "$db_sizes_after" | grep "^${db}=" | sed "s/^${db}=//")"
    gain_report="${gain_report}${db}: ${bsz:-?}MB -> ${asz:-?}MB"$'\n'
  done <<EOF
$ELIGIBLE_DBS
EOF

  local status_ok=1; "$GC" dolt status >/dev/null 2>&1 || status_ok=0
  [ "$status_ok" = "0" ] && divergences="${divergences}gc dolt status did not respond cleanly after compact"$'\n'

  # bd latency probe: informational per the bead's AC (not itself a pass/fail
  # threshold), EXCEPT a hard error/timeout on the simplest possible query
  # (bare count against hq) is a legitimate post-op health signal on its own,
  # not merely "slow" — that DOES count as a divergence.
  local lat_start lat_end lat_ms bd_ok
  lat_start=$(date +%s%N 2>/dev/null || date +%s)
  timeout "$BD_QUERY_TIMEOUT_SECS" "$BD" -C "$CITY" count >/dev/null 2>&1
  bd_ok=$?
  lat_end=$(date +%s%N 2>/dev/null || date +%s)
  case "$lat_start$lat_end" in
    *[!0-9]*) lat_ms="unknown" ;;
    *) lat_ms=$(( (lat_end - lat_start) / 1000000 )); [ "$lat_ms" -lt 0 ] && lat_ms="unknown (clock skew)" ;;
  esac
  [ "$bd_ok" -ne 0 ] && divergences="${divergences}post-run bd probe (bd -C hq count) failed/timed out (exit=$bd_ok) — Dolt may be unhealthy after compact"$'\n'

  if [ -n "$divergences" ]; then
    _halt "attempted dbs: $(printf '%s' "$attempted" | paste -sd, -)

Divergences:
$divergences
gc dolt status ok=$status_ok, post-run bd probe exit=$bd_ok, bd latency=${lat_ms}ms

Disk sizes:
$gain_report"
    return 0
  fi

  log "post-verification clean (bead counts + control-bead comments identical for all $(printf '%s' "$ELIGIBLE_DBS" | wc -l | tr -d ' ') eligible db(s); gc dolt status ok; bd latency=${lat_ms}ms)"
  log "disk sizes: $gain_report"
  "$NOTIFY" -t "Dolt compact routine" -p 3 "✅ compacted: $(printf '%s' "$attempted" | paste -sd, -) — verification clean (bd latency ${lat_ms}ms). $(printf '%s' "$gain_report" | tr '\n' ' ')" 2>/dev/null || true

  # ga-jz7gg scope item 1: re-seed the backup staging dir for every db that
  # was actually flattened above — ONLY reached after the divergence check
  # returned early (line ~722), so this never fires on a HALTed/unverified db.
  _reseed_after_compact "$attempted"
}

# _reseed_after_compact <newline-separated attempted dbs> — best-effort
# follow-up, never a data-integrity gate. Compact's own post-verification
# (above) already proved the DATA is correct; this only refreshes the BACKUP
# of that data, so a reseed failure must notify (silent failure recreates the
# exact orphan-blob accumulation this hook exists to close — see file header)
# but must NEVER write a HALT sentinel or block a future run. One db's
# failure does not stop the others (best-effort per db, not all-or-nothing).
_reseed_after_compact() {
  local dbs="$1" db rc failures=""
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    log "reseed: iniciando '$db' pos-compactacao"
    if timeout "${RESEED_TIMEOUT_SECS:-1800}" "$RESEED_SCRIPT" "$db" >>"$LOG" 2>&1; then
      log "reseed: '$db' OK"
    else
      rc=$?
      log "reseed: '$db' FALHOU (rc=$rc) — ver $LOG"
      failures="${failures}${db}(rc=$rc) "
    fi
  done <<EOF
$dbs
EOF
  if [ -n "$failures" ]; then
    "$NOTIFY" -t "Dolt compact routine" -p 4 "⚠️ reseed pos-compactacao falhou: $failures— blobs orfaos podem acumular no .dolt-backup, ver $LOG" 2>/dev/null || true
  fi
}

main() { _decide_and_run; }

if [ "${DOLT_COMPACT_ROUTINE_LIB:-0}" != "1" ]; then
  main
  exit 0
fi
