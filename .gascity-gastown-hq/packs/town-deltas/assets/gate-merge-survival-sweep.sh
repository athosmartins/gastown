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

SURVIVED=0; HEALED=0; DIVERGED=0; UNRESOLVED=0; CHECKED=0; PRUNED=0
# NOTE: macOS /bin/bash is 3.2 — NO associative arrays. Dedup fetches with an
# indexed array + linear membership check (same pattern as merged-bead-janitor).
declare -a KEEP_LINES=()
declare -a ALERT_SUMMARY=()
declare -a FETCHED_DIRS=()

# fetch_once <git_dir> <is_container> — bounded `git fetch origin`, at most once
# per git-dir per sweep (a bad remote can never hang the whole sweep).
fetch_once() {
  local gdir="$1" container="$2" k
  for k in "${FETCHED_DIRS[@]:-}"; do [ "$k" = "$gdir" ] && return 0; done
  FETCHED_DIRS+=("$gdir")
  timeout "$FETCH_TIMEOUT" sh -c '
    if [ "$2" = "1" ]; then git --git-dir="$1" fetch origin --quiet; else git -C "$1" fetch origin --quiet; fi
  ' _ "$gdir" "$container" 2>/dev/null \
    || warn "fetch failed/timeout for $gdir (verifying against stale refs)"
}

# escalation rate-limit: rc0 iff we should alert now for <sha> (and stamps it).
should_alert() {
  local sha="$1" stamp="$ALERT_DIR/$sha" last age
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    age=$(( NOW_EPOCH - ${last:-0} ))
    [ "$age" -lt "$ALERT_COOLDOWN" ] && return 1
  fi
  [ "$DRY_RUN" = "1" ] || printf '%s' "$NOW_EPOCH" > "$stamp" 2>/dev/null || true
  return 0
}

# escalate_divergent <sha> <rig> <branch> <bead> <beadcity> <gaterun> <rdefault> <origin_now> [extra_note]
# Reopen + label + comment the source bead, mail the Mayor, ntfy P4. Called for a
# genuine clobber AND for a heal attempt that failed (FF re-push rejected). Counts
# the event and appends to ALERT_SUMMARY. Rate-limited per-sha via should_alert.
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

while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  TS=$(printf '%s' "$entry"        | jq -r '.ts // ""' 2>/dev/null || true)
  RIG=$(printf '%s' "$entry"       | jq -r '.rig // ""' 2>/dev/null || true)
  RPATH=$(printf '%s' "$entry"     | jq -r '.rig_path // ""' 2>/dev/null || true)
  RDEFAULT=$(printf '%s' "$entry"  | jq -r '.default_branch // "main"' 2>/dev/null || true)
  BRANCH=$(printf '%s' "$entry"    | jq -r '.branch // ""' 2>/dev/null || true)
  BEAD=$(printf '%s' "$entry"      | jq -r '.bead // ""' 2>/dev/null || true)
  BEADCITY=$(printf '%s' "$entry"  | jq -r '.bead_city // ""' 2>/dev/null || true)
  GATERUN=$(printf '%s' "$entry"   | jq -r '.gate_run // ""' 2>/dev/null || true)
  SHA=$(printf '%s' "$entry"       | jq -r '.merge_sha // ""' 2>/dev/null || true)
  [ -z "$SHA" ] && continue
  [ -z "$RDEFAULT" ] && RDEFAULT="main"
  [ -z "$BEADCITY" ] && BEADCITY="$GC_CITY"

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
  VERDICT=$(survival_classify "$RGITDIR" "$RCONTAINER" "$SHA" "origin/$RDEFAULT")
  ORIGIN_NOW=$(git_in "$RGITDIR" "$RCONTAINER" rev-parse -q --verify "origin/$RDEFAULT" 2>/dev/null || echo "<none>")

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
        # Heal attempt failed → escalate (decrement the ff_heal classification;
        # escalate_divergent owns the DIVERGED count + alert).
        if [ -n "$HEAL_NOTE" ]; then
          escalate_divergent "$SHA" "$RIG" "$BRANCH" "$BEAD" "$BEADCITY" "$GATERUN" "$RDEFAULT" "$ORIGIN_NOW" "heal failed: $HEAL_NOTE"
        fi
      fi
      ;;

    divergent)
      escalate_divergent "$SHA" "$RIG" "$BRANCH" "$BEAD" "$BEADCITY" "$GATERUN" "$RDEFAULT" "$ORIGIN_NOW"
      ;;

    unresolved)
      escalate_unresolved "$SHA" "$RIG" "$BEAD" "$BEADCITY" "$RGITDIR" "$RDEFAULT"
      ;;
  esac
done <<EOF
$DEDUP_STREAM
EOF

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

log "=== survival-sweep complete — checked=$CHECKED survived=$SURVIVED healed=$HEALED divergent=$DIVERGED unresolved=$UNRESOLVED pruned=$PRUNED dry_run=$DRY_RUN ==="
# Per-event notifies (heal / orphan / unresolved) already fired above — loud and
# per-sha rate-limited; no duplicate roll-up here.
exit 0
