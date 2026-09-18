#!/usr/bin/env bash
# gate-merge-survival-sweep.sh — ga-lzj2e (2026-06-11).
#
# PROBLEM (spun off ga-eptel → ga-lzj2e): the gastown rig SHARES its remote
# (athosmartins/gastown.git) with the town main. ga-eptel's durable-landing
# AUDIT inside quality-gate-dispatcher.sh do_merge_ff confirms a just-merged
# container-rig SHA survives in BOTH the bare .repo.git main AND origin/main —
# but ONLY at merge time. It cannot catch a FULLY ASYNC clobber: a town-main
# push that lands on the shared remote minutes/hours AFTER the gate has exited
# can still orphan a gate-verified gastown merge, and by then the inline audit
# window is long closed. ga-eptel makes any IN-FLIGHT occurrence loud; this is
# the residual ASYNC gap.
#
# FIX (option c from ga-lzj2e: "periodic post-delivery survival sweep") — a
# durable append-only ledger + a periodic re-verification daemon:
#
#   • PRODUCER (quality-gate-dispatcher.sh, PASS path): on every CONTAINER-rig
#     merge, append one compact JSON line to .gc/merge-survival-ledger.jsonl
#     recording {ts,rig,rig_path,default_branch,branch,bead,bead_city,marker,
#     gate_run,merge_sha}. Fully guarded — never affects the gate outcome.
#
#   • CONSUMER (this sweep, every StartInterval): for each ledger SHA still
#     inside the retention window, re-fetch the rig's origin and CLASSIFY:
#       survived  — merge_sha IS ancestor of origin/<default_branch> → no-op.
#       ff_heal   — origin/main IS ancestor of merge_sha (merge_sha strictly
#                   ahead; re-landing it loses NOTHING, incl. anything the town
#                   push added that is already in origin/main) → FF-only re-push
#                   + re-advance the bare local main → self-healed.
#       divergent — neither is an ancestor of the other: a genuine shared-remote
#                   clobber with new conflicting work on origin/main. Auto-FF is
#                   UNSAFE (would either be rejected or, if forced, drop the
#                   town push) → ESCALATE: reopen + label gate:merge-orphan +
#                   comment the source bead, mail the Mayor, ntfy P4. Re-anchor
#                   is a human/Mayor decision (matches the dead-author/conflict
#                   re-anchor doctrine), NOT an autonomous force-push.
#       unresolved— merge_sha or origin/main not resolvable (sha gc'd, ref gone)
#                   → soft-escalate (ntfy P3 + comment), rate-limited.
#
# ga-8hm65g (2026-09-18): a single sweep run classified 31 genuinely-survived
# merges as DIVERGENT and reopened 29 already-delivered beads. Root cause was
# never fully isolated, but the classify+report pair used TWO separate,
# independently-timed resolutions of origin/<default_branch> — one to decide
# the verdict, one only to print it — so a concurrent external fetch/push
# against the same shared git-dir between those two reads could make the
# printed ORIGIN_NOW disagree with what was actually classified. Fix, per four
# invariants: (a) before ANY divergent classification is acted on, an
# independent, unconditional fresh fetch + a SINGLE literal re-resolution of
# origin/<default_branch> must confirm it again (see recheck_divergent);
# (b) whatever value is printed is the exact value that was classified, never
# a second, separately-timed read; (c) reopening a bead never happens on an
# unconfirmed first snapshot — confirm, then reopen, never in the same pass;
# (d) if MANY entries are still confirmed-divergent after (a) in one run, that
# surge is itself evidence of a systemic/detector problem, not proof of that
# many simultaneous real clobbers (ordinary runs show divergent=0) — per-bead
# reopen is suspended for the whole run in favor of one aggregated alarm (see
# escalate_surge).
#
# Why FF-only is provably lossless: ff_heal fires iff origin/main is an ancestor
# of merge_sha, i.e. merge_sha already CONTAINS every commit in origin/main
# (including a later town-main push that happens to be in origin/main). Pushing
# merge_sha to origin/main therefore strictly advances it and drops nothing.
#
# Retention is the ONLY pruner: a survived SHA is NOT permanently marked done —
# the whole point is that a town push HOURS later can still clobber it, so each
# SHA is re-checked every sweep until it ages out of LEDGER_RETENTION_DAYS
# (default 14). gastown sees few gate merges, so the ledger stays tiny.
#
# Idempotent, dry-run-first (SURVIVAL_DRY_RUN=1 or --dry-run), set -e/pipefail
# safe (every VAR=$(cmd) that can fail is `|| true`-guarded — the documented
# gate dispatcher crash class). Escalations are rate-limited per-sha to stay
# LOUD without spamming.
#
# Lib-only mode: `SURVIVAL_LIB_ONLY=1 source gate-merge-survival-sweep.sh`
# defines the pure + git helpers WITHOUT running the sweep, so the selftest
# exercises the REAL functions (one source of truth, no copy-drift).

set -uo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
GC_CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/gate-merge-survival-sweep.log"
SOURCE_BEAD="ga-lzj2e"
LEDGER="${SURVIVAL_LEDGER_FILE:-$GC_CITY/.gc/merge-survival-ledger.jsonl}"
ALERT_DIR="${SURVIVAL_ALERT_DIR:-$GC_CITY/.gc/merge-survival-alerted}"
FETCH_TIMEOUT="${SURVIVAL_FETCH_TIMEOUT:-30}"
LEDGER_RETENTION_DAYS="${SURVIVAL_RETENTION_DAYS:-14}"
# Re-alert cooldown per orphaned sha (seconds). LOUD but not spammy.
ALERT_COOLDOWN="${SURVIVAL_ALERT_COOLDOWN:-21600}"  # 6h
# ga-8hm65g invariant (d): above this many INDEPENDENTLY-CONFIRMED divergent
# classifications in one sweep, treat the whole batch as a suspected
# detector/race false positive rather than that many simultaneous real
# shared-remote clobbers (ordinary runs show divergent=0) — suspend per-bead
# reopen and send ONE aggregated alarm instead. See escalate_surge below.
SURGE_THRESHOLD="${SURVIVAL_DIVERGENT_SURGE_THRESHOLD:-5}"

# DRY_RUN: 1 = report only, never mutate (no push/ref-move/bead/mail). Supports
# --dry-run and SURVIVAL_DRY_RUN.
DRY_RUN="${SURVIVAL_DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

# ── Logging (stdout when interactive/dry-run; appended to log under launchd) ──
_log_emit() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] [survival-sweep] $*"
  if [ -t 1 ] || [ "${SURVIVAL_LOG_STDOUT:-0}" = "1" ]; then echo "$line"; fi
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$line" >> "$LOG" 2>/dev/null || true
}
log()  { _log_emit "$*"; }
warn() { _log_emit "WARN: $*"; }
err()  { _log_emit "ERROR: $*"; }

notify_athos() {
  command -v notify >/dev/null 2>&1 || return 0
  notify "$@" >/dev/null 2>&1 || true
}

# ═════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTION — the heart of the sweep; fully unit-testable on a real
# local git repo with no network.
#
# survival_classify <git_dir> <is_container> <merge_sha> <main_ref>
# Echoes exactly one of: survived | ff_heal | divergent | unresolved
#   survived   — merge_sha is an ancestor of main_ref (the merge is still live).
#   ff_heal    — main_ref is an ancestor of merge_sha (merge_sha strictly ahead;
#                a FF-only re-push of merge_sha is provably lossless).
#   divergent  — neither is an ancestor of the other (genuine clobber, new work
#                on main_ref; auto-FF unsafe → escalate).
#   unresolved — merge_sha or main_ref does not resolve to a commit object.
# Ancestry note: `merge-base --is-ancestor X X` is rc0, so an exact match
# (origin == merge_sha) classifies as survived (X is an ancestor of itself).
# ═════════════════════════════════════════════════════════════════════════════
survival_classify() {
  local gdir="$1" container="$2" sha="$3" mref="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1 || { echo "unresolved"; return 0; }
  git_in "$gdir" "$container" rev-parse -q --verify "${mref}^{commit}" >/dev/null 2>&1 || { echo "unresolved"; return 0; }
  if git_in "$gdir" "$container" merge-base --is-ancestor "$sha" "$mref" 2>/dev/null; then
    echo "survived"; return 0
  fi
  if git_in "$gdir" "$container" merge-base --is-ancestor "$mref" "$sha" 2>/dev/null; then
    echo "ff_heal"; return 0
  fi
  echo "divergent"
}

# ═════════════════════════════════════════════════════════════════════════════
# GIT HELPERS — match the dispatcher's container/self-repo handling exactly.
# ═════════════════════════════════════════════════════════════════════════════

# rig_gitdir <rig_path> — echoes "<git_dir_path>\t<is_container 0|1>".
rig_gitdir() {
  local rig_path="$1"
  if [ -d "$rig_path/.repo.git" ]; then
    printf '%s\t1\n' "$rig_path/.repo.git"
  else
    printf '%s\t0\n' "$rig_path"
  fi
}

# git_in <git_dir> <is_container> <git-args...> — run git against a rig repo.
git_in() {
  local gdir="$1" container="$2"; shift 2
  if [ "$container" = "1" ]; then
    git --git-dir="$gdir" "$@"
  else
    git -C "$gdir" "$@"
  fi
}

# iso_to_epoch <iso8601-utc> — echoes epoch seconds for a "%Y-%m-%dT%H:%M:%SZ"
# UTC timestamp, or empty on parse failure. Uses `-u -j -f` so the input is read
# as UTC (the ga-35zp1 local-vs-UTC age bug: never omit -u with -j -f).
iso_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true
}

# entry_within_retention <iso_ts> <now_epoch> <retention_days> — rc0 iff the
# entry timestamp is within retention_days of now (fail-OPEN: an unparseable ts
# is KEPT so we never silently drop a real merge from the audit window).
entry_within_retention() {
  local ts="$1" now="$2" days="$3" e
  e=$(iso_to_epoch "$ts")
  [ -z "$e" ] && return 0   # unparseable → keep (fail-open)
  [ $(( now - e )) -le $(( days * 86400 )) ]
}

# ═════════════════════════════════════════════════════════════════════════════
# ga-8hm65g HELPERS — placed here (before the lib-only guard, like the pure
# functions above) specifically so the selftest can unit-test them directly
# against a real local git repo, the same way it already does for
# survival_classify. raw_fetch/recheck_divergent do real (local, no-network)
# git I/O; divergent_surge and parse_entry_fields are pure.
# ═════════════════════════════════════════════════════════════════════════════

# raw_fetch <git_dir> <is_container> — unconditional bounded `git fetch
# origin`, no per-sweep memo. fetch_once() (SWEEP section, below the guard)
# wraps this with the once-per-git-dir memo used by the first pass;
# recheck_divergent calls raw_fetch directly, because a memoized fetch_once
# would silently skip the very re-fetch that closes the race (ga-8hm65g
# invariant a).
raw_fetch() {
  local gdir="$1" container="$2"
  timeout "$FETCH_TIMEOUT" sh -c '
    if [ "$2" = "1" ]; then git --git-dir="$1" fetch origin --quiet; else git -C "$1" fetch origin --quiet; fi
  ' _ "$gdir" "$container" 2>/dev/null
}

# recheck_divergent <git_dir> <container> <sha> <rdefault> — ga-8hm65g
# invariant (a)+(b): an UNCONDITIONAL fresh fetch (via raw_fetch), then ONE
# literal resolution of origin/<rdefault> that is used for BOTH the
# classification and the value reported back — so the verdict and the value
# it was computed against can never drift apart. Echoes "<verdict>\t<origin_now>".
recheck_divergent() {
  local gdir="$1" container="$2" sha="$3" rdefault="$4" origin_now verdict
  raw_fetch "$gdir" "$container" \
    || warn "recheck fetch failed/timeout for $gdir ($sha) — re-verifying against whatever refs are on disk"
  origin_now=$(git_in "$gdir" "$container" rev-parse -q --verify "origin/$rdefault" 2>/dev/null || echo "<none>")
  verdict=$(survival_classify "$gdir" "$container" "$sha" "$origin_now")
  printf '%s\t%s\n' "$verdict" "$origin_now"
}

# divergent_surge <confirmed_count> <threshold> — ga-8hm65g invariant (d):
# rc0 iff the confirmed-divergent count for this run exceeds the surge
# threshold. This many independently-reverified clobbers in ONE run is itself
# the signal of a systemic problem, not proof of that many real disasters
# (ordinary runs show divergent=0). Requires count>0 too, so a misconfigured
# (e.g. negative) threshold can never fire a surge alarm about zero entries.
divergent_surge() {
  [ "$1" -gt 0 ] && [ "$1" -gt "$2" ]
}

# parse_entry_fields <json_entry> — extracts one ledger line into the global
# vars the sweep operates on (TS RIG RPATH RDEFAULT BRANCH BEAD BEADCITY
# GATERUN SHA), applying the same defaults the main loop always applied.
# Factored out so PASS 2 (SWEEP section, below) can re-parse a deferred entry
# without duplicating the jq extraction.
parse_entry_fields() {
  local entry="$1"
  TS=$(printf '%s' "$entry"        | jq -r '.ts // ""' 2>/dev/null || true)
  RIG=$(printf '%s' "$entry"       | jq -r '.rig // ""' 2>/dev/null || true)
  RPATH=$(printf '%s' "$entry"     | jq -r '.rig_path // ""' 2>/dev/null || true)
  RDEFAULT=$(printf '%s' "$entry"  | jq -r '.default_branch // "main"' 2>/dev/null || true)
  BRANCH=$(printf '%s' "$entry"    | jq -r '.branch // ""' 2>/dev/null || true)
  BEAD=$(printf '%s' "$entry"      | jq -r '.bead // ""' 2>/dev/null || true)
  BEADCITY=$(printf '%s' "$entry"  | jq -r '.bead_city // ""' 2>/dev/null || true)
  GATERUN=$(printf '%s' "$entry"   | jq -r '.gate_run // ""' 2>/dev/null || true)
  SHA=$(printf '%s' "$entry"       | jq -r '.merge_sha // ""' 2>/dev/null || true)
  [ -z "$RDEFAULT" ] && RDEFAULT="main"
  [ -z "$BEADCITY" ] && BEADCITY="$GC_CITY"
}

# ═════════════════════════════════════════════════════════════════════════════
# Guard: when sourced for tests, stop here (no live sweep).
# ═════════════════════════════════════════════════════════════════════════════
[ "${SURVIVAL_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# SWEEP
# ═════════════════════════════════════════════════════════════════════════════
log "=== gate-merge-survival-sweep start (dry_run=$DRY_RUN, source=$SOURCE_BEAD, ledger=$LEDGER) ==="

if [ ! -s "$LEDGER" ]; then
  log "ledger empty or missing ($LEDGER) — nothing to verify. Done."
  exit 0
fi

NOW_EPOCH=$(date -u +%s)
mkdir -p "$ALERT_DIR" 2>/dev/null || true

# Read the ledger newest-first and keep the LAST (most-recent) entry per
# merge_sha. tac may be absent on macOS → use awk to reverse, then jq to dedupe
# by .merge_sha keeping first-seen (= newest after reversal).
LEDGER_DEDUP=$(awk '{ lines[NR]=$0 } END { for (i=NR;i>=1;i--) print lines[i] }' "$LEDGER" 2>/dev/null \
  | jq -rc 'select(.merge_sha != null and .merge_sha != "")' 2>/dev/null \
  | awk '!seen[$0]++' 2>/dev/null || true)

# Group by merge_sha (keep newest occurrence). Build a deduped JSON-line stream.
DEDUP_STREAM=$(printf '%s\n' "$LEDGER_DEDUP" \
  | jq -rc '.' 2>/dev/null \
  | awk 'match($0,/"merge_sha":"[0-9a-f]+"/){ k=substr($0,RSTART,RLENGTH); if(!s[k]++) print }' 2>/dev/null || true)

SURVIVED=0; HEALED=0; DIVERGED=0; UNRESOLVED=0; CHECKED=0; PRUNED=0; DOWNGRADED=0
# NOTE: macOS /bin/bash is 3.2 — NO associative arrays. Dedup fetches with an
# indexed array + linear membership check (same pattern as merged-bead-janitor).
declare -a KEEP_LINES=()
declare -a ALERT_SUMMARY=()
declare -a FETCHED_DIRS=()
# ga-8hm65g invariant (a)/(c): first-pass DIVERGENT candidates are queued here
# instead of escalated immediately — PASS 2 (after the main loop) re-verifies
# each with an independent fresh fetch before any bead is ever reopened.
declare -a PENDING_DIVERGENT=()

# fetch_once <git_dir> <is_container> — bounded `git fetch origin`, at most once
# per git-dir per sweep (a bad remote can never hang the whole sweep).
fetch_once() {
  local gdir="$1" container="$2" k
  for k in "${FETCHED_DIRS[@]:-}"; do [ "$k" = "$gdir" ] && return 0; done
  FETCHED_DIRS+=("$gdir")
  raw_fetch "$gdir" "$container" \
    || warn "fetch failed/timeout for $gdir (verifying against stale refs)"
}

# escalation rate-limit: rc0 iff we should alert now for <sha> (and stamps it).
should_alert() {
  # sha and stamp are split across two statements deliberately: a single
  # `local sha="$1" stamp="$ALERT_DIR/$sha"` word-expands its WHOLE argument
  # list before `local` runs, so "$sha" in the same line resolves via bash's
  # dynamic scoping to whatever `sha` the CALLER happens to have locally
  # declared (or unbound, under set -u, if it doesn't) — never this
  # function's own $1. Every caller until now happened to already have its
  # own local `sha="$1"` (masking the bug); escalate_surge (ga-8hm65g) does
  # not, since it handles many shas at once, and hit it directly.
  local sha="$1" stamp last age
  stamp="$ALERT_DIR/$sha"
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    age=$(( NOW_EPOCH - ${last:-0} ))
    [ "$age" -lt "$ALERT_COOLDOWN" ] && return 1
  fi
  [ "$DRY_RUN" = "1" ] || printf '%s' "$NOW_EPOCH" > "$stamp" 2>/dev/null || true
  return 0
}

# escalate_divergent <sha> <rig> <branch> <bead> <beadcity> <gaterun> <rdefault> <origin_now> [extra_note]
# Reopen + label + comment the source bead, mail the Mayor, ntfy P4. Only
# called from PASS 2 (after the main loop below), once an independent
# fresh-fetch recheck has CONFIRMED divergent (ga-8hm65g invariant a/c) and
# the confirmed count for this run is under SURGE_THRESHOLD (invariant d —
# see escalate_surge for the over-threshold path). Counts the event and
# appends to ALERT_SUMMARY. Rate-limited per-sha via should_alert.
escalate_divergent() {
  local sha="$1" rig="$2" branch="$3" bead="$4" beadcity="$5" gaterun="$6" rdefault="$7" origin_now="$8" extra="${9:-}"
  DIVERGED=$((DIVERGED+1))
  err "DIVERGENT $sha ($rig) — merge orphaned from origin/$rdefault ($origin_now)${extra:+ — $extra}"
  should_alert "$sha" || { log "divergent $sha ($rig) — alert suppressed (cooldown not elapsed)"; return 0; }
  ALERT_SUMMARY+=("ORPHAN(divergent) $sha ($rig) bead=${bead:-?}")
  if [ "$DRY_RUN" = "1" ]; then
    log "WOULD-ESCALATE(divergent) $sha ($rig) — reopen+label+comment bead, mail Mayor, ntfy P4"
    return 0
  fi
  if [ -n "$bead" ]; then
    bd -C "$beadcity" reopen "$bead" 2>/dev/null || true   # surface lost work (no-op if open)
    bd -C "$beadcity" label add "$bead" "gate:merge-orphan" -q 2>/dev/null || true
    bd -C "$beadcity" comment "$bead" \
      "ORPHANED (ga-lzj2e survival sweep): the gate-merged SHA $sha (branch $branch, gate_run ${gaterun:-?}) is NO LONGER an ancestor of $rig origin/$rdefault ($origin_now). An async push to the shared remote clobbered it with divergent work. The merge cannot be safely FF-re-landed (would drop the other side). Re-anchor needed: cherry-pick this branch onto current origin/$rdefault and re-merge, OR confirm the change is obsolete and close. Escalated to Mayor." 2>/dev/null || true
  fi
  gc --city "$GC_CITY" mail send mayor \
    -s "Gate survival: $rig merge $sha orphaned (shared-remote clobber)" \
    -m "$(printf 'A gate-verified %s merge was orphaned from the shared remote AFTER the gate exited (ga-lzj2e async gap).\n\n  rig:        %s\n  merge_sha:  %s\n  branch:     %s\n  bead:       %s (city %s)\n  gate_run:   %s\n  origin/%s now: %s\n  note:       %s\n\nClassification: DIVERGENT — origin/%s and the merge each carry unique commits, so a FF re-push is impossible and a forced push would drop the other side. The sweep reopened + labelled gate:merge-orphan + commented the source bead. Re-anchor decision is yours: cherry-pick the branch onto current origin/%s and re-merge via the gate, or confirm obsolete and close.' \
      "$rig" "$rig" "$sha" "$branch" "${bead:-<none>}" "$beadcity" "${gaterun:-<none>}" "$rdefault" "$origin_now" "${extra:-<none>}" "$rdefault" "$rdefault")" \
    2>/dev/null || warn "could not mail Mayor for orphan $sha"
  notify_athos -t "Gate survival: ORPHAN" -p 4 \
    "$rig merge $sha orphaned from origin/$rdefault by async shared-remote clobber — needs re-anchor (ga-lzj2e). Mayor notified."
}

# escalate_unresolved <sha> <rig> <bead> <beadcity> <rgitdir> <rdefault>
# The merge SHA no longer resolves (gc'd / ref gone). Comment + ntfy P3,
# rate-limited. Lighter than divergent (no Mayor mail) — needs eyes, not a
# re-anchor decision.
escalate_unresolved() {
  local sha="$1" rig="$2" bead="$3" beadcity="$4" rgitdir="$5" rdefault="$6"
  UNRESOLVED=$((UNRESOLVED+1))
  err "UNRESOLVED $sha ($rig) — merge_sha or origin/$rdefault not resolvable (sha gc'd or ref gone)"
  should_alert "$sha" || return 0
  ALERT_SUMMARY+=("UNRESOLVED $sha ($rig)")
  if [ "$DRY_RUN" = "1" ]; then
    log "WOULD-ESCALATE(unresolved) $sha ($rig) — comment bead + ntfy P3"
    return 0
  fi
  [ -n "$bead" ] && bd -C "$beadcity" comment "$bead" \
    "WARNING (ga-lzj2e survival sweep): gate-merged SHA $sha is no longer resolvable in $rig ($rgitdir) — the commit object is missing from origin/$rdefault and local refs. Possible orphan + gc, or a moved/rewritten ref. Manual check recommended." 2>/dev/null || true
  notify_athos -t "Gate survival: unresolved SHA" -p 3 \
    "$rig merge $sha not resolvable against origin/$rdefault — possible orphan+gc (ga-lzj2e)"
}

# escalate_surge <count> <rec...> — ga-8hm65g invariant (d): ONE aggregated
# alarm for a suspected detector/race false-positive storm. Each <rec> is
# "sha|rig|branch|bead|beadcity|gaterun|rdefault|origin_now". Never touches bd
# (no reopen, no label) — that is exactly the destructive action being
# suspended for this run. Rate-limited as ONE aggregate stamp (key
# "__surge__") so a persisting storm doesn't re-mail every sweep.
escalate_surge() {
  local count="$1"; shift
  DIVERGED=$((DIVERGED+count))
  err "SURGE: $count confirmed-divergent in one sweep — suspected detector/race false positive, suspending per-bead reopen (ga-8hm65g invariant d)"
  should_alert "__surge__" || { log "surge alert suppressed (cooldown not elapsed, $count confirmed-divergent)"; return 0; }
  local rec rsha rrig rbranch rbead rbeadcity rgaterun rrdefault rorigin list=""
  for rec in "$@"; do
    IFS='|' read -r rsha rrig rbranch rbead rbeadcity rgaterun rrdefault rorigin <<< "$rec"
    list="${list}  - ${rsha} (${rrig}) bead=${rbead:-<none>} vs origin/${rrdefault}=${rorigin}
"
    ALERT_SUMMARY+=("SURGE-HELD(divergent) $rsha ($rrig) bead=${rbead:-?}")
  done
  if [ "$DRY_RUN" = "1" ]; then
    log "WOULD-ESCALATE(surge) $count confirmed-divergent — one aggregated mail, NO bead reopen"
    return 0
  fi
  gc --city "$GC_CITY" mail send mayor \
    -s "Gate survival: SURGE — $count merges look orphaned in one sweep (suspected false positive)" \
    -m "$(printf 'gate-merge-survival-sweep independently re-verified %s merges as DIVERGENT in a single run (each with its own fresh fetch, ga-8hm65g invariant a) and they are STILL divergent.\n\nThis many simultaneous genuine shared-remote clobbers is implausible (history: ordinary runs show divergent=0) — per-bead reopen has been SUSPENDED for all %s as a suspected detector or race false positive (ga-8hm65g invariant d). No bead was reopened or labelled.\n\n%s\nInvestigate the detector (or the shared remote) directly before manually clearing any of these.' \
      "$count" "$count" "$list")" \
    2>/dev/null || warn "could not mail Mayor for surge"
  notify_athos -t "Gate survival: SURGE (held)" -p 4 \
    "$count merges look orphaned in one sweep — suspended as suspected false positive, Mayor notified, no beads touched (ga-8hm65g)."
}

while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  parse_entry_fields "$entry"
  [ -z "$SHA" ] && continue

  # Retention prune: drop entries older than the window (assumed long-survived —
  # an async town clobber would have fired well within 14 days).
  if ! entry_within_retention "$TS" "$NOW_EPOCH" "$LEDGER_RETENTION_DAYS"; then
    PRUNED=$((PRUNED+1))
    log "prune $SHA ($RIG) — ts=$TS older than ${LEDGER_RETENTION_DAYS}d"
    continue
  fi
  KEEP_LINES+=("$entry")

  if [ -z "$RPATH" ] || [ ! -d "$RPATH" ]; then
    warn "rig_path missing for $SHA ($RIG): '$RPATH' — cannot verify (keeping entry)"
    continue
  fi

  PAIR=$(rig_gitdir "$RPATH"); RGITDIR="${PAIR%$'\t'*}"; RCONTAINER="${PAIR#*$'\t'}"

  # One bounded fetch per rig git-dir per sweep (a bad remote can never hang us).
  fetch_once "$RGITDIR" "$RCONTAINER"

  CHECKED=$((CHECKED+1))
  # Resolve origin/$RDEFAULT to a literal value ONCE and classify against
  # THAT literal, not the symbolic ref a second time (ga-8hm65g invariant b):
  # the old code re-resolved the symbolic ref a second time just to print it,
  # so a concurrent external fetch/push against this shared git-dir between
  # the two resolutions could make the printed value disagree with what was
  # actually classified.
  ORIGIN_NOW=$(git_in "$RGITDIR" "$RCONTAINER" rev-parse -q --verify "origin/$RDEFAULT" 2>/dev/null || echo "<none>")
  VERDICT=$(survival_classify "$RGITDIR" "$RCONTAINER" "$SHA" "$ORIGIN_NOW")

  case "$VERDICT" in
    survived)
      SURVIVED=$((SURVIVED+1))
      log "survived $SHA ($RIG) — ancestor of origin/$RDEFAULT ($ORIGIN_NOW)"
      # A prior orphan that self-resolved: clear its alert stamp.
      [ -f "$ALERT_DIR/$SHA" ] && rm -f "$ALERT_DIR/$SHA" 2>/dev/null || true
      ;;

    ff_heal)
      if [ "$DRY_RUN" = "1" ]; then
        HEALED=$((HEALED+1))
        log "WOULD-HEAL $SHA ($RIG) — origin/$RDEFAULT ($ORIGIN_NOW) is ancestor of merge; FF re-push would re-land it"
      else
        # FF-only re-push (lossless: merge_sha ⊇ origin/main) + re-advance the
        # bare local main, then re-verify the heal actually took. On any failure,
        # escalate as divergent (origin moved again, or ancestry not restored).
        HEAL_NOTE=""
        if git_in "$RGITDIR" "$RCONTAINER" push origin "${SHA}:refs/heads/$RDEFAULT" 2>/dev/null; then
          git_in "$RGITDIR" "$RCONTAINER" fetch origin --quiet 2>/dev/null || true
          if [ "$RCONTAINER" = "1" ]; then
            git_in "$RGITDIR" "$RCONTAINER" update-ref "refs/heads/$RDEFAULT" "$SHA" 2>/dev/null \
              || warn "  heal: bare update-ref of $RDEFAULT → $SHA failed (push landed)"
          fi
          RECHECK=$(survival_classify "$RGITDIR" "$RCONTAINER" "$SHA" "origin/$RDEFAULT")
          if [ "$RECHECK" = "survived" ]; then
            HEALED=$((HEALED+1))
            [ -f "$ALERT_DIR/$SHA" ] && rm -f "$ALERT_DIR/$SHA" 2>/dev/null || true
            log "HEALED $SHA ($RIG) — FF re-push re-landed orphaned merge on origin/$RDEFAULT"
            notify_athos -t "Gate survival: auto-healed" -p 3 \
              "Re-landed orphaned $RIG merge $SHA on origin/$RDEFAULT (async shared-remote clobber, ga-lzj2e)"
            [ -n "$BEAD" ] && bd -C "$BEADCITY" comment "$BEAD" \
              "gate-merge-survival-sweep (ga-lzj2e): merge $SHA was orphaned from origin/$RDEFAULT by an async shared-remote push; auto-healed via FF-only re-push (lossless — merge contained the newer origin). Work is live again." 2>/dev/null || true
            ALERT_SUMMARY+=("HEALED $SHA ($RIG)")
          else
            HEAL_NOTE="re-push did not re-establish ancestry (recheck=$RECHECK)"
          fi
        else
          HEAL_NOTE="FF re-push REJECTED (origin moved again mid-sweep)"
        fi
        # Heal attempt failed → same fate as a first-pass divergent: queue for
        # an independent fresh-fetch recheck rather than escalating on this
        # single attempt (ga-8hm65g invariant a/c). HEAL_NOTE is logged here
        # for the record; the eventual escalation (only if PASS 2 confirms
        # still-divergent) uses the generic divergent message like any other
        # confirmed entry.
        if [ -n "$HEAL_NOTE" ]; then
          warn "$SHA ($RIG) heal attempt failed ($HEAL_NOTE) — queued for recheck before any reopen"
          PENDING_DIVERGENT+=("$entry")
        fi
      fi
      ;;

    divergent)
      # Do NOT escalate on a single snapshot (ga-8hm65g invariant a/c) — queue
      # for an independent fresh-fetch recheck after the full pass.
      log "$SHA ($RIG) looks divergent vs origin/$RDEFAULT ($ORIGIN_NOW) on first pass — queued for recheck before any reopen"
      PENDING_DIVERGENT+=("$entry")
      ;;

    unresolved)
      escalate_unresolved "$SHA" "$RIG" "$BEAD" "$BEADCITY" "$RGITDIR" "$RDEFAULT"
      ;;
  esac
done <<EOF
$DEDUP_STREAM
EOF

# ═════════════════════════════════════════════════════════════════════════════
# PASS 2 (ga-8hm65g invariants a+b+c+d) — every first-pass DIVERGENT candidate
# gets ONE independent, unconditional fresh fetch + a re-classify against that
# SAME freshly-resolved value before it is ever escalated. Only entries still
# divergent after this re-check are eligible to reopen a bead — and even then,
# if too many are confirmed in this single run, individual reopen is
# suspended in favor of one aggregated alarm (a surge is itself evidence of a
# systemic/race problem, not proof of that many real clobbers at once).
# ═════════════════════════════════════════════════════════════════════════════
declare -a CONFIRMED_DIVERGENT=()
if [ "${#PENDING_DIVERGENT[@]}" -gt 0 ]; then
  log "re-verifying ${#PENDING_DIVERGENT[@]} first-pass DIVERGENT candidate(s) with an independent fresh fetch before any escalation (ga-8hm65g invariant a)"
  for entry in "${PENDING_DIVERGENT[@]}"; do
    parse_entry_fields "$entry"
    [ -z "$SHA" ] && continue
    PAIR=$(rig_gitdir "$RPATH"); RGITDIR="${PAIR%$'\t'*}"; RCONTAINER="${PAIR#*$'\t'}"
    RECHECK_OUT=$(recheck_divergent "$RGITDIR" "$RCONTAINER" "$SHA" "$RDEFAULT")
    RECHECK_VERDICT="${RECHECK_OUT%%$'\t'*}"; RECHECK_ORIGIN="${RECHECK_OUT#*$'\t'}"
    log "RECHECK $SHA ($RIG) — fresh fetch done, origin/$RDEFAULT re-read as $RECHECK_ORIGIN, verdict=$RECHECK_VERDICT"
    if [ "$RECHECK_VERDICT" != "divergent" ]; then
      log "$SHA ($RIG) downgraded on recheck ($RECHECK_VERDICT) — first-pass divergent was stale, NOT escalating"
      if [ "$RECHECK_VERDICT" = "survived" ]; then
        SURVIVED=$((SURVIVED+1))
        [ -f "$ALERT_DIR/$SHA" ] && rm -f "$ALERT_DIR/$SHA" 2>/dev/null || true
      else
        # ff_heal or unresolved on recheck: this run took no action for the
        # entry (heal isn't re-attempted here — see parse_entry_fields's
        # doc-comment on why — and unresolved is soft-escalated only from the
        # first pass), so it belongs in neither SURVIVED/HEALED/DIVERGED/
        # UNRESOLVED. Tally it separately rather than let it vanish from the
        # summary entirely — checked=... should stay reconcilable against
        # what actually happened to every candidate.
        DOWNGRADED=$((DOWNGRADED+1))
      fi
      continue
    fi
    CONFIRMED_DIVERGENT+=("$SHA|$RIG|$BRANCH|$BEAD|$BEADCITY|$GATERUN|$RDEFAULT|$RECHECK_ORIGIN")
  done
fi

if divergent_surge "${#CONFIRMED_DIVERGENT[@]}" "$SURGE_THRESHOLD"; then
  escalate_surge "${#CONFIRMED_DIVERGENT[@]}" "${CONFIRMED_DIVERGENT[@]:-}"
else
  for rec in "${CONFIRMED_DIVERGENT[@]:-}"; do
    [ -z "$rec" ] && continue
    IFS='|' read -r SHA RIG BRANCH BEAD BEADCITY GATERUN RDEFAULT RECHECK_ORIGIN <<< "$rec"
    escalate_divergent "$SHA" "$RIG" "$BRANCH" "$BEAD" "$BEADCITY" "$GATERUN" "$RDEFAULT" "$RECHECK_ORIGIN"
  done
fi

# ── Atomic ledger prune (drop aged-out entries; keep everything still in-window).
if [ "$PRUNED" -gt 0 ] && [ "$DRY_RUN" = "0" ]; then
  TMP_LEDGER="$LEDGER.tmp.$$"
  : > "$TMP_LEDGER" 2>/dev/null || true
  for ln in "${KEEP_LINES[@]:-}"; do
    [ -z "$ln" ] && continue
    printf '%s\n' "$ln" >> "$TMP_LEDGER" 2>/dev/null || true
  done
  if [ -f "$TMP_LEDGER" ]; then
    mv "$TMP_LEDGER" "$LEDGER" 2>/dev/null \
      && log "ledger pruned: dropped $PRUNED aged-out entry(ies), kept ${#KEEP_LINES[@]}" \
      || { warn "ledger prune mv failed (kept original)"; rm -f "$TMP_LEDGER" 2>/dev/null || true; }
  fi
fi

log "=== survival-sweep complete — checked=$CHECKED survived=$SURVIVED healed=$HEALED divergent=$DIVERGED unresolved=$UNRESOLVED downgraded=$DOWNGRADED pruned=$PRUNED dry_run=$DRY_RUN ==="
# Per-event notifies (heal / orphan / unresolved) already fired above — loud and
# per-sha rate-limited; no duplicate roll-up here.
exit 0
