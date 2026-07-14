#!/usr/bin/env bash
# gate-needs-human-divergence-sweep.sh — ga-u4yi (2026-07-14).
#
# PROBLEM (ga-u4yi, filed by thies-wa, P1): a branch parked at gate:needs-human
# (auto-fix cap exhausted, or one of the ga-acb circuit-breaks in
# quality-gate-dispatcher.sh) is a SILENT PARK, not a queue — the Pilot will
# never re-dispatch it (by design) and the guard silently parks every
# resubmission (quality-gate-guard.sh Step 5a). Nothing watches whether the
# files that branch touches keep moving on origin/main while it sits there.
# thies's branch rotted 20h; meanwhile 7 commits landed on main touching the
# SAME files (demand_mobile.{js,css,html}) — by the time a human looked, the
# branch was 1523 lines vs main's 2270, containing NONE of the 7 commits.
# Force-merging would have deleted shipped work; the whole phase had to be
# re-anchored. (This sweep is the companion to the durable author-mail added
# at all 4 gate:needs-human label-add sites in quality-gate-dispatcher.sh —
# that fix tells the author IMMEDIATELY; this one watches for the situation
# getting WORSE the longer nobody acts.)
#
# FIX: a periodic sweep that watches every gate:needs-human bead. On first
# sighting of a bead, it snapshots origin/<default_branch>'s current SHA as a
# BASELINE and the branch's own touched-files list (both frozen — a parked
# branch never gains commits, and the dispatcher will not re-run gate logic on
# it until a human clears the label) into a durable ledger. On every later
# sweep it checks whether any commit has landed on origin/<default_branch>
# since the baseline that touches one of those same files — exactly the
# "git log main -- <files>" signal ga-u4yi calls out as cheap and
# already-available (quality-gate-dispatcher.sh already computes an equivalent
# CHANGED_FILES diff for tier classification; this reuses the same triple-dot
# diff, just checked in the opposite temporal direction). The first time that
# happens for a bead, ESCALATE: label gate:needs-human:diverging, comment the
# bead with the actual colliding commits, mail BOTH the author and the Mayor
# (durable — mail survives a dead/restarted session, nudge does not), and
# ntfy P4 — while the branch is presumably still rebaseable (the earlier in
# its life this fires, the more true that is). Re-alerts are rate-limited per
# bead (cooldown), same idiom as the sibling gate-merge-survival-sweep.sh. A
# bead that leaves gate:needs-human (resolved, closed) is pruned from the
# ledger on its next sweep; a time-based retention backstop also applies so a
# transient query failure can't pin an entry forever.
#
# NOTE: gate:needs-human is NOT applied exclusively by the quality-gate
# dispatcher — inflight-reclaim-guard.py and the auto-refino escalation path
# also use it for unrelated stuck-work signals. Beads that reached
# gate:needs-human via those paths have no quality-gate-marker (no
# source-bead:/branch: labels) — this sweep resolves a branch via the bead's
# newest marker and SKIPS quietly (nothing to watch) when none exists. This is
# expected and common, not an error.
#
# Mirrors gate-merge-survival-sweep.sh's shape closely (ledger + periodic
# re-verify + rate-limited escalate) but the trigger is the OPPOSITE: that
# sweep re-verifies work ALREADY merged hasn't been orphaned; this one watches
# work NOT YET merged (parked) for main moving out from under it.
#
# Idempotent, dry-run-first (DIVERGENCE_DRY_RUN=1 or --dry-run), set -uo
# pipefail safe. Lib-only mode: `DIVERGENCE_LIB_ONLY=1 source
# gate-needs-human-divergence-sweep.sh` defines the pure + git helpers WITHOUT
# running the sweep, so the selftest exercises the REAL functions (one source
# of truth, no copy-drift).

set -uo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
GC_CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/gate-needs-human-divergence-sweep.log"
SOURCE_BEAD="ga-u4yi"
LEDGER="${DIVERGENCE_LEDGER_FILE:-$GC_CITY/.gc/needs-human-divergence-ledger.jsonl}"
ALERT_DIR="${DIVERGENCE_ALERT_DIR:-$GC_CITY/.gc/needs-human-divergence-alerted}"
FETCH_TIMEOUT="${DIVERGENCE_FETCH_TIMEOUT:-30}"
# Retention is a BACKSTOP, not the primary pruner — the primary pruner is "no
# longer in the live gate:needs-human candidate set" (checked every sweep).
LEDGER_RETENTION_DAYS="${DIVERGENCE_RETENTION_DAYS:-30}"
# Re-alert cooldown per diverging bead (seconds). LOUD but not spammy.
ALERT_COOLDOWN="${DIVERGENCE_ALERT_COOLDOWN:-21600}"  # 6h, matches survival-sweep

# DRY_RUN: 1 = report only, never mutate (no label/comment/mail/ledger-write).
# Supports --dry-run and DIVERGENCE_DRY_RUN.
DRY_RUN="${DIVERGENCE_DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

# ── Logging (stdout when interactive/dry-run; appended to log under launchd) ──
_log_emit() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] [needs-human-divergence] $*"
  if [ -t 1 ] || [ "${DIVERGENCE_LOG_STDOUT:-0}" = "1" ]; then echo "$line"; fi
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
# GIT HELPERS — same shape as gate-merge-survival-sweep.sh (each sweep in this
# pack keeps its own local copy of these; that's the established convention,
# not drift — quality-gate-dispatcher.sh has its own git_rig() too).
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

# iso_to_epoch <iso8601-utc> — echoes epoch seconds, or empty on parse failure.
# Uses `-u -j -f` so the input is read as UTC (ga-35zp1: never omit -u).
iso_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true
}

# entry_within_retention <iso_ts> <now_epoch> <retention_days> — rc0 iff the
# entry timestamp is within retention_days of now (fail-OPEN: an unparseable
# ts is KEPT so a transient failure never silently drops a tracked bead).
entry_within_retention() {
  local ts="$1" now="$2" days="$3" e
  e=$(iso_to_epoch "$ts")
  [ -z "$e" ] && return 0
  [ $(( now - e )) -le $(( days * 86400 )) ]
}

# in_list <needle> <haystack...> — rc0 iff needle appears among the rest of
# the args. macOS bash 3.2 has no associative arrays; this is the linear
# membership check used throughout this pack for small candidate sets.
in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

# branch_touched_files <git_dir> <is_container> <default_ref> <branch_ref>
# Echoes the newline-separated list of files the branch touches relative to
# the default branch's merge-base (triple-dot diff) — the SAME computation
# quality-gate-dispatcher.sh already does for tier classification
# (CHANGED_FILES), reused here to seed what this sweep watches.
branch_touched_files() {
  local gdir="$1" container="$2" dref="$3" bref="$4"
  git_in "$gdir" "$container" diff --name-only "${dref}...${bref}" 2>/dev/null || true
}

# files_diverged <git_dir> <is_container> <baseline_sha> <main_ref> <files...>
# Echoes one line per commit ("<sha7> <subject>") on main_ref that is (a) NOT
# an ancestor of baseline_sha and (b) touches at least one of <files>. Empty
# output = no divergence yet. This IS ga-u4yi's suggested signal
# (`git log main -- <branch's files>`), scoped to commits strictly after the
# baseline so a sweep never re-reports old history. Fails safe to empty
# (nothing to report) if either ref doesn't resolve or no files given.
files_diverged() {
  local gdir="$1" container="$2" baseline="$3" mref="$4"; shift 4
  local files=("$@")
  [ "${#files[@]}" -eq 0 ] && return 0
  git_in "$gdir" "$container" rev-parse -q --verify "${baseline}^{commit}" >/dev/null 2>&1 || return 0
  git_in "$gdir" "$container" rev-parse -q --verify "${mref}^{commit}" >/dev/null 2>&1 || return 0
  git_in "$gdir" "$container" log --oneline "${baseline}..${mref}" -- "${files[@]}" 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════════
# Guard: when sourced for tests, stop here (no live sweep).
# ═════════════════════════════════════════════════════════════════════════════
[ "${DIVERGENCE_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# SWEEP
# ═════════════════════════════════════════════════════════════════════════════
log "=== gate-needs-human-divergence-sweep start (dry_run=$DRY_RUN, source=$SOURCE_BEAD, ledger=$LEDGER) ==="

command -v jq >/dev/null 2>&1 || { err "jq required — aborting"; exit 1; }
command -v gc >/dev/null 2>&1 || { err "gc required — aborting"; exit 1; }
command -v bd >/dev/null 2>&1 || { err "bd required — aborting"; exit 1; }

NOW_EPOCH=$(date -u +%s)
mkdir -p "$ALERT_DIR" 2>/dev/null || true
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true

RIG_LIST_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo '{}')

# ── Discover candidates: beads labeled gate:needs-human, across HQ + every
# rig store (a bead's DATA can live in HQ or a rig store — same multi-store
# probe already established in commands/gate-done.md's ga-u4yi bead_id
# validation fix). gate:needs-human beads are left OPEN (not closed) by every
# producer of the label, with any prior in-flight status cleared, so
# --status=open is correct and cheap.
declare -a CANDIDATE_STORES=("$GC_CITY")
for _rp in $(printf '%s' "$RIG_LIST_JSON" | jq -r '.rigs[].path // empty' 2>/dev/null); do
  in_list "$_rp" "${CANDIDATE_STORES[@]}" || CANDIDATE_STORES+=("$_rp")
done

CANDIDATES_JSONL=""
declare -a CANDIDATE_IDS=()
for _store in "${CANDIDATE_STORES[@]}"; do
  [ -d "$_store" ] || continue
  _found=$(bd -C "$_store" list --label "gate:needs-human" --status=open --json 2>/dev/null || echo "[]")
  if [ -z "$_found" ] || [ "$_found" = "null" ]; then _found="[]"; fi
  _tagged=$(printf '%s' "$_found" | jq -c --arg store "$_store" '.[] | . + {_bead_city: $store}' 2>/dev/null || true)
  [ -z "$_tagged" ] && continue
  CANDIDATES_JSONL="${CANDIDATES_JSONL}${_tagged}
"
  while IFS= read -r _id; do
    [ -n "$_id" ] && CANDIDATE_IDS+=("$_id")
  done <<EOF
$(printf '%s' "$_tagged" | jq -r '.id' 2>/dev/null)
EOF
done
log "candidates: ${#CANDIDATE_IDS[@]} bead(s) currently labeled gate:needs-human across ${#CANDIDATE_STORES[@]} store(s)"

declare -a KEEP_LINES=()
declare -a SEEN_BEAD_IDS=()
declare -a FETCHED_DIRS=()
declare -a ALERT_SUMMARY=()
CHECKED=0; DIVERGED=0; PRUNED=0; ADDED=0

# fetch_once <git_dir> <is_container> — bounded `git fetch origin`, at most
# once per git-dir per sweep (a bad remote can never hang the whole sweep).
fetch_once() {
  local gdir="$1" container="$2"
  in_list "$gdir" "${FETCHED_DIRS[@]:-}" && return 0
  FETCHED_DIRS+=("$gdir")
  timeout "$FETCH_TIMEOUT" sh -c '
    if [ "$2" = "1" ]; then git --git-dir="$1" fetch origin --quiet; else git -C "$1" fetch origin --quiet; fi
  ' _ "$gdir" "$container" 2>/dev/null \
    || warn "fetch failed/timeout for $gdir (verifying against stale refs)"
}

# escalation rate-limit: rc0 iff we should alert now for <bead_id> (stamps it).
should_alert() {
  local bead="$1" stamp="$ALERT_DIR/$bead" last age
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    age=$(( NOW_EPOCH - ${last:-0} ))
    [ "$age" -lt "$ALERT_COOLDOWN" ] && return 1
  fi
  [ "$DRY_RUN" = "1" ] || printf '%s' "$NOW_EPOCH" > "$stamp" 2>/dev/null || true
  return 0
}

# escalate_diverging <bead> <bead_city> <rig> <branch> <default> <baseline> <origin_now> <colliding_commits>
# Label + comment the bead, mail the author AND the Mayor (durable), ntfy P4.
# Rate-limited per-bead via should_alert.
escalate_diverging() {
  local bead="$1" beadcity="$2" rig="$3" branch="$4" default="$5" baseline="$6" origin_now="$7" colliding="$8"
  DIVERGED=$((DIVERGED+1))
  err "DIVERGING $bead ($rig) — origin/$default gained commits on branch $branch's files since baseline $baseline"
  should_alert "$bead" || { log "diverging $bead ($rig) — alert suppressed (cooldown not elapsed)"; return 0; }
  ALERT_SUMMARY+=("DIVERGING $bead ($rig) branch=$branch")
  if [ "$DRY_RUN" = "1" ]; then
    log "WOULD-ESCALATE(diverging) $bead ($rig) — label+comment bead, mail author+Mayor, ntfy P4"
    return 0
  fi
  local author
  author=$(bd -C "$beadcity" show "$bead" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.assignee // .created_by // .owner // "")' 2>/dev/null || echo "")
  bd -C "$beadcity" label add "$bead" "gate:needs-human:diverging" -q 2>/dev/null || true
  bd -C "$beadcity" comment "$bead" \
    "$(printf 'DIVERGING (ga-u4yi divergence sweep): while this bead sat parked at gate:needs-human, origin/%s gained commits touching the SAME files as branch %s. The longer this sits, the harder it is to rebase.\n\nColliding commits:\n%s\n\nAct now while it is still rebaseable — re-anchor the branch onto current origin/%s (cherry-pick or rebuild), or close this bead if the work is now obsolete.' \
      "$default" "$branch" "$colliding" "$default")" 2>/dev/null || true
  if [ -n "$author" ]; then
    gc --city "$GC_CITY" mail send "$author" \
      -s "Gate needs-human DIVERGING: $branch — main moved on your files ($bead)" \
      -m "$(printf 'Your branch %s (bead %s, rig %s) is parked at gate:needs-human, and origin/%s has now landed NEW commits touching the SAME files your branch touches:\n\n%s\n\nThe longer this sits, the harder it will be to rebase without losing work. Re-anchor the branch onto current origin/%s (or ask the Mayor to) while it is still rebaseable, or close the bead if this work is now obsolete.' \
        "$branch" "$bead" "$rig" "$default" "$colliding" "$default")" \
      2>/dev/null || warn "could not mail author $author for diverging $bead"
  fi
  gc --city "$GC_CITY" mail send mayor \
    -s "Gate needs-human DIVERGING: $branch ($bead, $rig)" \
    -m "$(printf 'Bead %s (rig %s, branch %s) is parked at gate:needs-human AND main has now diverged on the same files — the longer it sits the harder it is to rebase.\n\nColliding commits on origin/%s:\n%s\n\nAuthor: %s. This is the ga-u4yi divergence watch — the "act while still rebaseable" signal the original incident (20h silent rot, unmergeable branch) was missing.' \
      "$bead" "$rig" "$branch" "$default" "$colliding" "${author:-<unknown>}")" \
    2>/dev/null || warn "could not mail Mayor for diverging $bead"
  notify_athos -t "Gate needs-human: DIVERGING" -p 4 \
    "$rig bead $bead branch $branch — main diverged on the same files while parked. Act before it's unmergeable (ga-u4yi)."
}

# ── PASS 1: walk the existing ledger — prune resolved/aged entries, else
# check tracked entries for divergence. ──────────────────────────────────────
if [ -s "$LEDGER" ]; then
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    BEAD_ID=$(printf '%s' "$entry" | jq -r '.bead_id // ""' 2>/dev/null || true)
    [ -z "$BEAD_ID" ] && continue
    TS=$(printf '%s' "$entry" | jq -r '.ts_first_seen // ""' 2>/dev/null || true)

    # Primary pruner: no longer a live gate:needs-human candidate → resolved.
    if ! in_list "$BEAD_ID" "${CANDIDATE_IDS[@]:-}"; then
      PRUNED=$((PRUNED+1))
      log "prune $BEAD_ID — no longer gate:needs-human (resolved/closed)"
      rm -f "${ALERT_DIR:?}/$BEAD_ID" 2>/dev/null || true
      continue
    fi
    # Backstop pruner: retention window (fail-open on unparseable ts).
    if ! entry_within_retention "$TS" "$NOW_EPOCH" "$LEDGER_RETENTION_DAYS"; then
      PRUNED=$((PRUNED+1))
      log "prune $BEAD_ID — ts_first_seen=$TS older than ${LEDGER_RETENTION_DAYS}d retention backstop"
      rm -f "${ALERT_DIR:?}/$BEAD_ID" 2>/dev/null || true
      continue
    fi

    KEEP_LINES+=("$entry")
    SEEN_BEAD_IDS+=("$BEAD_ID")

    RIG_PATH=$(printf '%s' "$entry" | jq -r '.rig_path // ""' 2>/dev/null || true)
    RIG=$(printf '%s' "$entry" | jq -r '.rig // ""' 2>/dev/null || true)
    DEFAULT=$(printf '%s' "$entry" | jq -r '.default_branch // "main"' 2>/dev/null || true)
    BRANCH=$(printf '%s' "$entry" | jq -r '.branch // ""' 2>/dev/null || true)
    BASELINE=$(printf '%s' "$entry" | jq -r '.baseline_sha // ""' 2>/dev/null || true)
    BEADCITY=$(printf '%s' "$entry" | jq -r '.bead_city // ""' 2>/dev/null || true)
    [ -z "$BEADCITY" ] && BEADCITY="$GC_CITY"

    if [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; then
      warn "rig_path missing for $BEAD_ID: '$RIG_PATH' — cannot verify this sweep (keeping entry)"
      continue
    fi

    declare -a FILES=()
    while IFS= read -r _f; do
      [ -n "$_f" ] && FILES+=("$_f")
    done <<EOF
$(printf '%s' "$entry" | jq -r '.files[]? // empty' 2>/dev/null)
EOF
    [ "${#FILES[@]}" -eq 0 ] && continue

    PAIR=$(rig_gitdir "$RIG_PATH"); RGITDIR="${PAIR%$'\t'*}"; RCONTAINER="${PAIR#*$'\t'}"
    fetch_once "$RGITDIR" "$RCONTAINER"
    CHECKED=$((CHECKED+1))

    COLLIDING=$(files_diverged "$RGITDIR" "$RCONTAINER" "$BASELINE" "origin/$DEFAULT" "${FILES[@]}")
    if [ -n "$COLLIDING" ]; then
      ORIGIN_NOW=$(git_in "$RGITDIR" "$RCONTAINER" rev-parse -q --verify "origin/$DEFAULT" 2>/dev/null || echo "<none>")
      escalate_diverging "$BEAD_ID" "$BEADCITY" "$RIG" "$BRANCH" "$DEFAULT" "$BASELINE" "$ORIGIN_NOW" "$COLLIDING"
    else
      log "clean $BEAD_ID ($RIG) — no new commits on origin/$DEFAULT touching branch $BRANCH's files since baseline $BASELINE"
    fi
  done <<EOF
$(cat "$LEDGER" 2>/dev/null || true)
EOF
fi

# ── PASS 2: discover NEW candidates not already tracked — capture baseline. ──
while IFS= read -r cand; do
  [ -z "$cand" ] && continue
  BEAD_ID=$(printf '%s' "$cand" | jq -r '.id // ""' 2>/dev/null || true)
  [ -z "$BEAD_ID" ] && continue
  in_list "$BEAD_ID" "${SEEN_BEAD_IDS[@]:-}" && continue

  BEADCITY=$(printf '%s' "$cand" | jq -r '._bead_city // ""' 2>/dev/null || true)
  [ -z "$BEADCITY" ] && BEADCITY="$GC_CITY"

  # Resolve rig (name/path/default_branch) from the bead id's PREFIX — same
  # "RIG fallback via source-bead prefix" pattern established in gate-done.md.
  PFX="${BEAD_ID%%-*}"
  if [ -z "$PFX" ] || [ "$PFX" = "$BEAD_ID" ]; then
    log "skip $BEAD_ID — cannot derive a rig prefix from the bead id"
    continue
  fi
  RIG_ROW=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg p "$PFX" \
    '.rigs[] | select(.prefix == $p) | [.name, .path, (.default_branch // "main")] | @tsv' 2>/dev/null | head -1)
  if [ -z "$RIG_ROW" ]; then
    log "skip $BEAD_ID — prefix '$PFX' matches no registered rig"
    continue
  fi
  RIG="${RIG_ROW%%$'\t'*}"
  _REST="${RIG_ROW#*$'\t'}"
  RIG_PATH="${_REST%%$'\t'*}"
  DEFAULT="${_REST#*$'\t'}"
  if [ ! -d "$RIG_PATH" ]; then
    warn "skip $BEAD_ID — rig path missing: $RIG_PATH"
    continue
  fi

  # Resolve branch via the newest gate marker (ANY status — a parked bead's
  # marker is normally CLOSED by quality-gate-guard.sh Step 5a, so `--all` is
  # required or every real case is missed). Absence is EXPECTED and common —
  # inflight-reclaim-guard.py and auto-refino also apply gate:needs-human for
  # unrelated reasons with no marker at all; skip quietly, not a warning.
  MARKERS=$(bd -C "$GC_CITY" list --label "source-bead:$BEAD_ID" --all --json 2>/dev/null || echo "[]")
  if [ -z "$MARKERS" ] || [ "$MARKERS" = "null" ]; then MARKERS="[]"; fi
  BRANCH=$(printf '%s' "$MARKERS" | jq -r '
    sort_by(.created_at // "") | last // empty
    | (.labels // [])[] | select(startswith("branch:")) | sub("^branch:";"")' 2>/dev/null | head -1)
  if [ -z "$BRANCH" ]; then
    log "skip $BEAD_ID ($RIG) — no gate marker with a branch label (likely reached gate:needs-human via a non-gate path; nothing to watch)"
    continue
  fi

  PAIR=$(rig_gitdir "$RIG_PATH"); RGITDIR="${PAIR%$'\t'*}"; RCONTAINER="${PAIR#*$'\t'}"
  fetch_once "$RGITDIR" "$RCONTAINER"

  if ! git_in "$RGITDIR" "$RCONTAINER" rev-parse -q --verify "origin/$BRANCH^{commit}" >/dev/null 2>&1; then
    log "skip $BEAD_ID ($RIG) — branch $BRANCH no longer resolves on origin (already gone; nothing to watch)"
    continue
  fi
  if ! git_in "$RGITDIR" "$RCONTAINER" rev-parse -q --verify "origin/$DEFAULT^{commit}" >/dev/null 2>&1; then
    warn "skip $BEAD_ID ($RIG) — default branch origin/$DEFAULT does not resolve"
    continue
  fi

  declare -a FILES=()
  while IFS= read -r _f; do
    [ -n "$_f" ] && FILES+=("$_f")
  done <<EOF
$(branch_touched_files "$RGITDIR" "$RCONTAINER" "origin/$DEFAULT" "origin/$BRANCH")
EOF
  if [ "${#FILES[@]}" -eq 0 ]; then
    log "skip $BEAD_ID ($RIG) — branch $BRANCH touches no files relative to origin/$DEFAULT (nothing to watch)"
    continue
  fi

  BASELINE_SHA=$(git_in "$RGITDIR" "$RCONTAINER" rev-parse -q --verify "origin/$DEFAULT" 2>/dev/null || echo "")
  [ -z "$BASELINE_SHA" ] && continue

  ADDED=$((ADDED+1))
  FILES_JSON=$(printf '%s\n' "${FILES[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  NEW_LINE=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg bead "$BEAD_ID" --arg beadcity "$BEADCITY" \
    --arg rig "$RIG" --arg rigpath "$RIG_PATH" --arg default "$DEFAULT" --arg branch "$BRANCH" \
    --arg baseline "$BASELINE_SHA" --argjson files "$FILES_JSON" \
    '{ts_first_seen:$ts, bead_id:$bead, bead_city:$beadcity, rig:$rig, rig_path:$rigpath, default_branch:$default, branch:$branch, baseline_sha:$baseline, files:$files}' 2>/dev/null)
  [ -z "$NEW_LINE" ] && continue
  if [ "$DRY_RUN" = "1" ]; then
    log "WOULD-TRACK NEW $BEAD_ID ($RIG, branch=$BRANCH) — baseline=$BASELINE_SHA, ${#FILES[@]} file(s)"
  else
    KEEP_LINES+=("$NEW_LINE")
    log "tracking NEW $BEAD_ID ($RIG, branch=$BRANCH) — baseline=$BASELINE_SHA, ${#FILES[@]} file(s) to watch"
  fi
done <<EOF
$CANDIDATES_JSONL
EOF

# ── Atomic ledger rewrite ────────────────────────────────────────────────────
if [ "$DRY_RUN" = "0" ]; then
  TMP_LEDGER="$LEDGER.tmp.$$"
  : > "$TMP_LEDGER" 2>/dev/null || true
  for ln in "${KEEP_LINES[@]:-}"; do
    [ -z "$ln" ] && continue
    printf '%s\n' "$ln" >> "$TMP_LEDGER" 2>/dev/null || true
  done
  if [ -f "$TMP_LEDGER" ]; then
    mv "$TMP_LEDGER" "$LEDGER" 2>/dev/null \
      && log "ledger written: ${#KEEP_LINES[@]} entry(ies)" \
      || { warn "ledger rewrite mv failed (kept original)"; rm -f "$TMP_LEDGER" 2>/dev/null || true; }
  fi
fi

log "=== divergence-sweep complete — candidates=${#CANDIDATE_IDS[@]} checked=$CHECKED diverging=$DIVERGED added=$ADDED pruned=$PRUNED dry_run=$DRY_RUN ==="
exit 0
