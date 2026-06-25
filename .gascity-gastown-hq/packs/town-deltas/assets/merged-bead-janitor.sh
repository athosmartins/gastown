#!/usr/bin/env bash
# merged-bead-janitor.sh — ga-tijv5 (2026-06-11).
#
# PROBLEM (Athos): beads whose code is ALREADY merged to origin/main stay
# in_progress ("em voo") in the Kanban forever, inflating the in-flight count
# and eroding trust in the board. Two confirmed root causes:
#
#   1. SIBLING-UNDER-PARENT — several sub-task beads are worked on ONE shared
#      branch (e.g. crew/thies/wa-ab6z) and committed under the PARENT id
#      (feat(wa-ab6z)). The gate only closes the source-bead NAMED in the
#      marker, so the un-named siblings never close even though their code is
#      in main (e.g. wa-t6pa, wa-r4zr — closed by hand 2026-06-11).
#   2. ERRORED-THEN-MERGED — the branch lands via a SUPERSEDED/error path
#      (after a marker timeout) instead of a clean PASS, so the source-bead
#      close step never fires (e.g. wa-27jn merged @04f6c76f, marker errored).
#
#   A third real shape this sweep also covers: CROSS-STORE MIRROR — a rig-store
#   bead whose artifact is HQ-local lands in the HQ repo under a mirror bead
#   (e.g. wa-1or2 ↔ ga-piycl, "feat(refino): … Mirrors WA bead wa-1or2",
#   merged in HQ origin/main @9bdd48df3) — so the wa bead's own rig repo shows
#   no merge, but the HQ repo does.
#
# FIX — a periodic per-rig-store janitor. For every in_progress bead it asks
# "is this bead's work in origin/main?" via THREE independent signals (OR):
#   (A) COMMIT  — the bead id appears as the conventional-commit SCOPE in the
#                 SUBJECT line of an origin/main commit in the bead's own rig
#                 repo OR the HQ repo (mirror): `feat(<id>):` / `fix(<id>):` /
#                 etc. Body-only mentions of an id in an unrelated commit are
#                 REJECTED — they are incident reports, not deliveries. Uses
#                 scan_commit_subject_for_bead (same strict fn as the story
#                 sweep). False-negative (real merge missed this sweep) is far
#                 safer than a false-positive (unbuilt work silently closed);
#                 signal C (crew/*/<id> branch-ancestor) is the reliable catch-up.
#   (B) MARKER  — the bead has a CLOSED gate marker (source-bead:<id>) whose
#                 terminal label is gate-status:passed or gate-status:superseded.
#   (C) BRANCH  — the bead's branch (from a marker's branch:<…> label, or the
#                 crew/*/<id> convention) is an ancestor of origin/main.
# If any fires → close the bead + drop story:in-flight + comment the evidence
# (sha / marker / branch) + notify.
#
# GUARDS (zero false-positive is AC3, the paramount constraint):
#   • EPIC beads are NEVER auto-closed (they are parents; keep them).
#   • A bead with ANY OPEN gate marker (queued/ready/dispatching/needs-rebase/
#     error/deferred) is actively in the gate — NEVER closed (protects wa-lstd,
#     wa-ab6z). This also means an errored-but-NOT-yet-merged bead is kept.
#   • No merge signal → KEEP. A stale UNMERGED branch contributes nothing.
#
# SIBLING cascade is ADVISORY by default: a bead with no own signal that is a
# child of a merged parent is LOGGED as a candidate (not closed) — auto-closing
# work that has no per-bead merge proof would risk a false-positive. The durable
# prevention is the commit convention (see merged-bead-janitor.README below):
# gate-done / workers MUST reference every completed bead id in the commit body
# so signal (A) catches it.
#
# Idempotent (closing a closed bead is a no-op), dry-run-first
# (JANITOR_DRY_RUN=1 or --dry-run), set -e/pipefail safe (every VAR=$(cmd) that
# can fail is `|| true`-guarded — the documented gate dispatcher crash class).
#
# Lib-only mode: `JANITOR_LIB_ONLY=1 source merged-bead-janitor.sh` defines the
# pure + git helpers WITHOUT running the sweep, so the selftest exercises the
# real functions (one source of truth, no copy-drift).

set -uo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
GC_CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/merged-bead-janitor.log"
SOURCE_BEAD="ga-tijv5"
FETCH_TIMEOUT="${JANITOR_FETCH_TIMEOUT:-30}"

# DRY_RUN: 1 = report only, never mutate. Supports --dry-run and JANITOR_DRY_RUN.
DRY_RUN="${JANITOR_DRY_RUN:-0}"
# Optional rig filter (space-separated prefixes/names); empty = all rigs.
RIGS_FILTER="${JANITOR_RIGS:-}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --rig=*)   RIGS_FILTER="$RIGS_FILTER ${arg#--rig=}" ;;
  esac
done

# ── Logging (stdout when interactive/dry-run; appended to log under launchd) ──
_log_emit() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] [merged-bead-janitor] $*"
  if [ -t 1 ] || [ "${JANITOR_LOG_STDOUT:-0}" = "1" ]; then echo "$line"; fi
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  echo "$line" >> "$LOG" 2>/dev/null || true
}
log()  { _log_emit "$*"; }
warn() { _log_emit "WARN: $*"; }
err()  { _log_emit "ERROR: $*"; }

# ── notify (best-effort) ─────────────────────────────────────────────────────
notify_athos() {
  command -v notify >/dev/null 2>&1 || return 0
  notify "$@" >/dev/null 2>&1 || true
}

# ═════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTION — the heart of the janitor; fully unit-testable.
# janitor_decide <is_epic> <has_open_marker> <sig_commit> <sig_marker> <sig_branch_merged>
# Each arg is 0|1. Echoes "<verdict>:<reason>" where verdict ∈ {keep,close}.
# Guards are evaluated FIRST (an open marker or epic always wins over signals).
# ═════════════════════════════════════════════════════════════════════════════
janitor_decide() {
  local is_epic="$1" has_open_marker="$2" sig_commit="$3" sig_marker="$4" sig_branch="$5"
  if [ "$is_epic" = "1" ]; then            echo "keep:epic-parent-never-autoclosed"; return 0; fi
  if [ "$has_open_marker" = "1" ]; then    echo "keep:active-open-gate-marker"; return 0; fi
  if [ "$sig_commit" = "1" ]; then         echo "close:commit-in-origin-main"; return 0; fi
  if [ "$sig_marker" = "1" ]; then         echo "close:terminal-gate-marker-passed-or-superseded"; return 0; fi
  if [ "$sig_branch" = "1" ]; then         echo "close:branch-ancestor-of-origin-main"; return 0; fi
  echo "keep:no-merge-evidence"
}

# ═════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTION #2 — story:approved → story:done reconciliation (ga-gosfs).
#
# WHY a SECOND sweep: the in_progress sweep above closes merged bug/task beads.
# STORY beads behave differently. After a gate PASS the dispatcher hands a story
# OFF to story-delivery: it CLEARS the builder, STRIPS story:in-flight, sets
# gate:passed, and leaves the bead OPEN with story:approved (delivery's pickup
# selector is `story:approved + gate:passed`, see story-delivery.sh). Delivery
# then deploys + prod-tests and adds story:done.
#
# The bug (ga-gosfs): that handoff strands stories at story:approved whenever the
# normal gate→delivery→done path does not complete, e.g.
#   • CROSS-STORE: an HQ ga-* story merged via a rig path set gate:passed on the
#     wrong store (pre-ga-qw7y6), so delivery's HQ `story:approved + gate:passed`
#     query never matches → no story:done.
#   • SUPERSEDED: the branch landed via a supersede/error path that never set the
#     gate:passed LABEL on the bead.
#   • RIG STORIES: story-delivery only scans the HQ store (`bd -C $GC_CITY`), so a
#     rig-store story with gate:passed is never picked up at all.
#   • DELIVERY CRASH: delivery died between gate:passed and story:done.
# A stranded story keeps story:approved (no story:in-flight, no story:done) →
# the Kanban shows it as backlog though its code is already in origin/main.
#
# This sweep is the durable CATCH-ALL. It reuses the SAME merge-evidence
# triangulation as janitor_decide (commit-in-main / terminal marker / branch
# ancestry) — which is STRONGER than the gate:passed label: the commit-grep
# signal (A) heals exactly the cross-store / superseded cases that LACK the
# label. With merge evidence AND no active rework, it drives story:approved →
# story:done (the same terminal story-delivery would have reached).
#
# janitor_story_decide <is_epic> <has_open_marker> <already_done> <in_flight>
#                      <has_builder> <delivery_active>
#                      <sig_commit> <sig_marker> <sig_branch>
# Each arg is 0|1. Echoes "<verdict>:<reason>", verdict ∈ {done,keep}.
# Guards are evaluated FIRST and in a fixed precedence — ANY active-rework or
# not-a-merged-story condition wins over the merge signals (zero false-positive
# is paramount: a genuinely-pending approved story must NEVER be force-done).
# ═════════════════════════════════════════════════════════════════════════════
janitor_story_decide() {
  local is_epic="$1" has_open_marker="$2" already_done="$3" in_flight="$4" \
        has_builder="$5" delivery_active="$6" sig_commit="$7" sig_marker="$8" sig_branch="$9"
  # — Guards (keep) — lower lines win the label when several apply —
  if [ "$is_epic" = "1" ];         then echo "keep:epic-parent-never-autoclosed"; return 0; fi
  if [ "$already_done" = "1" ];    then echo "keep:already-story-done"; return 0; fi
  if [ "$has_open_marker" = "1" ]; then echo "keep:active-open-gate-marker"; return 0; fi
  if [ "$in_flight" = "1" ];       then echo "keep:story-in-flight-active-rework"; return 0; fi
  if [ "$has_builder" = "1" ];     then echo "keep:live-builder-assignee"; return 0; fi
  if [ "$delivery_active" = "1" ]; then echo "keep:delivery-owns-it"; return 0; fi
  # — Merge evidence (done) — same triangulation as janitor_decide —
  if [ "$sig_commit" = "1" ];      then echo "done:commit-in-origin-main"; return 0; fi
  if [ "$sig_marker" = "1" ];      then echo "done:terminal-gate-marker-passed-or-superseded"; return 0; fi
  if [ "$sig_branch" = "1" ];      then echo "done:branch-ancestor-of-origin-main"; return 0; fi
  echo "keep:no-merge-evidence"
}

# ═════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTION #3 — convoy/coordination wrapper reconciliation.
#
# WHY a THIRD sweep: the Pilot/gate create CONVOY wrapper beads (issue_type:convoy,
# "build story X" / "fix bug X" slings) and the engine deacon creates dc-*
# coordination beads ("Merge failed", "Rebase required") per failed merge. NO
# daemon ever closes them when the underlying work completes. Audit: ~700 open
# junk beads; 100% of still-open convoy wrappers DEPEND ON a bead that is already
# CLOSED (work done, wrapper orphaned). The Pilot also re-slings the same target
# every sweep, multiplying them.
#
# SAFETY — dependency-closure ONLY, NO commit-matching. Sibling bug ga-92o95
# proved commit-matching false-closes (a docs commit body-mentioned an unrelated
# in-flight bead). This sweep is evidence-free of "merged": it asserts ONLY "this
# wrapper's tracked work is done" by reading the wrapper's OWN dependency list and
# checking that EVERY DEPENDS-ON target is CLOSED. That dodges the commit-mismatch
# hazard entirely. A wrapper with ≥1 dependency, all of them CLOSED → orphaned →
# close. ANY open dep, OR no deps at all, OR an unreadable dep list → KEEP.
#
# janitor_convoy_decide <dep_count> <open_dep_count> <deps_readable>
#   dep_count       — total DEPENDS-ON targets (integer ≥0)
#   open_dep_count  — how many of those are NOT closed (integer ≥0)
#   deps_readable   — 0|1; 0 when the wrapper's show JSON could not be parsed
# Echoes "<verdict>:<reason>", verdict ∈ {close,keep}. KEEP-biased: every
# uncertain or work-still-pending condition resolves to keep (zero false-close).
# ═════════════════════════════════════════════════════════════════════════════
janitor_convoy_decide() {
  local dep_count="$1" open_dep_count="$2" deps_readable="$3"
  if [ "$deps_readable" != "1" ];        then echo "keep:deps-unreadable"; return 0; fi
  if [ "$dep_count" -lt 1 ] 2>/dev/null; then echo "keep:no-dependencies"; return 0; fi
  if [ "$open_dep_count" -gt 0 ] 2>/dev/null; then echo "keep:dependency-still-open"; return 0; fi
  echo "close:all-dependencies-closed"
}

# ═════════════════════════════════════════════════════════════════════════════
# GIT HELPERS — match the dispatcher's container/self-repo handling exactly.
# ═════════════════════════════════════════════════════════════════════════════

# rig_gitdir <rig_path> — echoes "<git_dir_path>\t<is_container 0|1>".
# Container rigs keep a bare .repo.git (preferred when present, per dispatcher
# line 717); self-repo rigs use their working tree .git.
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

# token_bounded <bead_id> <text> — rc0 iff text contains bead_id as a whole
# token (not a substring of a longer id). Guards e.g. wa-1 vs wa-12.
token_bounded() {
  printf '%s' "$2" | grep -Eq "(^|[^[:alnum:]-])$1([^[:alnum:]-]|\$)"
}

# scan_commit_for_bead <git_dir> <is_container> <ref> <bead_id>
# rc0 + prints first matching sha iff an ancestor commit of <ref> mentions the
# bead id (token-bounded) in its message. Fixed-string --grep then boundary
# check (avoids regex-meta + substring false matches).
scan_commit_for_bead() {
  local gdir="$1" container="$2" ref="$3" id="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "$ref" >/dev/null 2>&1 || return 1
  local shas sha body
  shas=$(git_in "$gdir" "$container" log "$ref" -F --grep="$id" --format='%H' 2>/dev/null || true)
  [ -z "$shas" ] && return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    body=$(git_in "$gdir" "$container" log -1 --format='%B' "$sha" 2>/dev/null || true)
    if token_bounded "$id" "$body"; then printf '%s' "$sha"; return 0; fi
  done <<EOF
$shas
EOF
  return 1
}

# scan_commit_subject_for_bead <git_dir> <is_container> <ref> <bead_id>
# STRICTER variant of scan_commit_for_bead used by the story:done reconciliation
# sweep (ga-gosfs): rc0 + prints the first matching sha iff an ancestor commit of
# <ref> references the bead id (token-bounded) in its SUBJECT line — the
# conventional-commit scope an *implementing* commit carries (feat(<id>): /
# fix(<id>): / "fix bug <id>:" / (<id>)). Body-only mentions are REJECTED.
#
# WHY stricter than the in_progress sweep: a story:approved bead can sit OPEN for
# days (engine-window / deferred work). Unrelated commits routinely name it in
# their BODY as still-open or future work — "remains open in ga-r471 engine
# window", "enforce … moves to wa-qggy (after tbbc)". The body-wide scan reads
# those as "merged" and would falsely mark the story done. Marking a story done
# is irreversible UX (it leaves the board) so zero false-positive is paramount
# (AC3) — and a genuine story merge always puts the id in the SUBJECT (gate-done
# commits as feat(<id>)/fix(<id>)). The unambiguous marker + branch signals still
# cover the cross-store / superseded cases where no subject-scoped commit exists.
scan_commit_subject_for_bead() {
  local gdir="$1" container="$2" ref="$3" id="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "$ref" >/dev/null 2>&1 || return 1
  local shas sha subj
  shas=$(git_in "$gdir" "$container" log "$ref" -F --grep="$id" --format='%H' 2>/dev/null || true)
  [ -z "$shas" ] && return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    subj=$(git_in "$gdir" "$container" log -1 --format='%s' "$sha" 2>/dev/null || true)
    if token_bounded "$id" "$subj"; then printf '%s' "$sha"; return 0; fi
  done <<EOF
$shas
EOF
  return 1
}

# branch_merged <git_dir> <is_container> <branch_ref> <main_ref>
# rc0 iff branch_ref resolves and is an ancestor of main_ref.
branch_merged() {
  local gdir="$1" container="$2" bref="$3" mref="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "$bref" >/dev/null 2>&1 || return 1
  git_in "$gdir" "$container" merge-base --is-ancestor "$bref" "$mref" 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
# BEAD / MARKER HELPERS (live Dolt; only used in the sweep, not the pure tests).
# ═════════════════════════════════════════════════════════════════════════════

# markers_for_bead <bead_id> — echoes the HQ quality-gate markers (JSON array)
# whose source-bead label is this bead. Empty array on any failure.
markers_for_bead() {
  local id="$1" out
  out=$(bd -C "$GC_CITY" list --all --json -l type:quality-gate-marker -l "source-bead:$id" 2>/dev/null || echo '[]')
  [ -z "$out" ] && out='[]'
  printf '%s' "$out"
}

# has_open_marker <markers_json> — rc0 iff any marker is not closed.
has_open_marker() {
  printf '%s' "$1" | jq -e 'any(.[]; (.status // "") != "closed")' >/dev/null 2>&1
}

# has_terminal_passed_marker <markers_json> — rc0 iff any CLOSED marker carries
# a gate-status:passed or gate-status:superseded label.
has_terminal_passed_marker() {
  printf '%s' "$1" | jq -e '
    any(.[];
      (.status // "") == "closed"
      and ((.labels // []) | any(. == "gate-status:passed" or . == "gate-status:superseded")))' \
    >/dev/null 2>&1
}

# branch_label_from_markers <markers_json> — echoes branch names from any
# branch:<…> marker labels (one per line, de-duplicated).
branch_label_from_markers() {
  printf '%s' "$1" | jq -r '.[].labels[]? | select(startswith("branch:")) | sub("^branch:";"")' 2>/dev/null \
    | awk 'NF && !seen[$0]++' || true
}

# convoy_dep_counts <show_json> — parse a `bd show <id> --json` blob and echo a
# single line "<dep_count> <open_dep_count> <deps_readable>" for the convoy
# reconciler (PURE: jq-only, no live store, so the selftest can exercise it on
# synthetic fixtures).
#   • `bd show` may return an object OR a 1-element array → normalize both.
#   • dependency list lives in `.dependencies[]`; each entry's `.status` field is
#     the DEPENDS-ON target's status. A dep is CLOSED iff `.status == "closed"`;
#     anything else (open/in_progress/null/missing) counts as OPEN (KEEP-biased).
#   • If jq cannot parse the blob (bd emits unescaped control chars in some
#     descriptions — observed live), echo "0 0 0" so the decider KEEPS the bead.
convoy_dep_counts() {
  local out
  out=$(printf '%s' "$1" | jq -r '
      (if type=="array" then .[0] else . end) as $b
      | ($b.dependencies // []) as $d
      | "\($d | length) \([$d[] | select((.status // "") != "closed")] | length) 1"
    ' 2>/dev/null) || out=""
  if [ -z "$out" ]; then echo "0 0 0"; else echo "$out"; fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Guard: when sourced for tests, stop here (no live sweep).
# ═════════════════════════════════════════════════════════════════════════════
[ "${JANITOR_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# SWEEP
# ═════════════════════════════════════════════════════════════════════════════
log "=== merged-bead-janitor sweep start (dry_run=$DRY_RUN, source=$SOURCE_BEAD) ==="

RIG_LIST_JSON=$(gc --city "$GC_CITY" rig list --json 2>/dev/null || echo '{}')
HQ_GITDIR_PAIR=$(rig_gitdir "$GC_CITY"); HQ_GITDIR="${HQ_GITDIR_PAIR%$'\t'*}"; HQ_CONTAINER="${HQ_GITDIR_PAIR#*$'\t'}"
HQ_DEFAULT=$(printf '%s' "$RIG_LIST_JSON" | jq -r '.rigs[] | select(.hq == true) | .default_branch // "main"' 2>/dev/null | head -1)
[ -z "$HQ_DEFAULT" ] && HQ_DEFAULT="main"

# Best-effort fetch of every repo we will inspect (deduped), bounded so a bad
# remote can never hang the sweep. Stale refs are tolerated (next sweep retries).
declare -a FETCHED=()
fetch_once() {
  local gdir="$1" container="$2" key
  key="$gdir"
  for k in "${FETCHED[@]:-}"; do [ "$k" = "$key" ] && return 0; done
  FETCHED+=("$key")
  timeout "$FETCH_TIMEOUT" sh -c '
    if [ "$2" = "1" ]; then git --git-dir="$1" fetch origin --quiet; else git -C "$1" fetch origin --quiet; fi
  ' _ "$gdir" "$container" 2>/dev/null || warn "fetch failed/timeout for $gdir (continuing with stale refs)"
}
fetch_once "$HQ_GITDIR" "$HQ_CONTAINER"

CLOSED_COUNT=0
SIBLING_ADVISORIES=0
DONE_COUNT=0   # ga-gosfs: stories reconciled story:approved → story:done
CONVOY_COUNT=0 # convoy-reconciler: orphaned wrapper/coordination beads closed
CONVOY_MAX_PER_SWEEP="${CONVOY_MAX_PER_SWEEP:-60}" # anti-Dolt-spike: cap REAL closes/sweep; the ~480 backlog drains over a few 15min sweeps instead of 480 commits at once
declare -a CLOSED_SUMMARY=()
declare -a DONE_SUMMARY=()
declare -a CONVOY_SUMMARY=()

# Iterate every rig store.
RIG_ROWS=$(printf '%s' "$RIG_LIST_JSON" | jq -rc '.rigs[]? | {name,prefix,path,default_branch:(.default_branch // "main"),hq:(.hq // false)}' 2>/dev/null || true)
while IFS= read -r rig; do
  [ -z "$rig" ] && continue
  RNAME=$(printf '%s' "$rig" | jq -r '.name' 2>/dev/null || true)
  RPREFIX=$(printf '%s' "$rig" | jq -r '.prefix' 2>/dev/null || true)
  RPATH=$(printf '%s' "$rig" | jq -r '.path' 2>/dev/null || true)
  RDEFAULT=$(printf '%s' "$rig" | jq -r '.default_branch' 2>/dev/null || true)
  [ -z "$RPATH" ] && continue
  [ -d "$RPATH" ] || { warn "rig path missing: $RPATH ($RNAME)"; continue; }

  # Apply rig filter if set.
  if [ -n "$RIGS_FILTER" ]; then
    case " $RIGS_FILTER " in *" $RNAME "*|*" $RPREFIX "*) : ;; *) continue ;; esac
  fi

  PAIR=$(rig_gitdir "$RPATH"); RGITDIR="${PAIR%$'\t'*}"; RCONTAINER="${PAIR#*$'\t'}"
  fetch_once "$RGITDIR" "$RCONTAINER"

  # in_progress beads in this rig's store.
  INPROG=$(bd -C "$RPATH" list --status in_progress --json 2>/dev/null || echo '[]')
  [ -z "$INPROG" ] && INPROG='[]'
  N=$(printf '%s' "$INPROG" | jq 'length' 2>/dev/null || echo 0)
  log "rig $RNAME ($RPREFIX): $N in_progress bead(s) [store=$RPATH git=$RGITDIR default=$RDEFAULT]"

  # NOTE (convoy-reconciler): the in_progress pass below is now GUARDED rather
  # than `continue`-ing the whole rig on N==0 — the original early-continue also
  # skipped the story:done (ga-gosfs) AND this convoy sweep for any rig with no
  # in_progress beads (e.g. gascity routinely has 0). Only the in_progress body
  # is conditional; the story + convoy sweeps always run for every rig.
  if [ "$N" != "0" ]; then
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    BID=$(printf '%s' "$b" | jq -r '.id' 2>/dev/null || true)
    BTYPE=$(printf '%s' "$b" | jq -r '(.issue_type // .type // "")' 2>/dev/null || true)
    BTITLE=$(printf '%s' "$b" | jq -r '(.title // "")[0:60]' 2>/dev/null || true)
    [ -z "$BID" ] && continue

    IS_EPIC=0; [ "$BTYPE" = "epic" ] && IS_EPIC=1

    # Gate markers (HQ) for this bead → open-marker guard + terminal signal + branch.
    MK=$(markers_for_bead "$BID")
    HAS_OPEN=0; has_open_marker "$MK" && HAS_OPEN=1
    SIG_MARKER=0; has_terminal_passed_marker "$MK" && SIG_MARKER=1

    # Signal A — commit SUBJECT-scoped to this bead id in own-rig repo OR HQ repo (mirror).
    # Uses the STRICT subject scanner (same as the story sweep): only a conventional-commit
    # whose SCOPE is this bead id (feat(<id>)/fix(<id>)/etc.) counts as delivery evidence.
    # Body-only mentions — incident descriptions, cross-references, "wa-oxkg dispatch
    # surfaced mid-conversation" — are REJECTED. See scan_commit_subject_for_bead.
    SIG_COMMIT=0; COMMIT_EVID=""
    if [ "$IS_EPIC" = "0" ] && [ "$HAS_OPEN" = "0" ]; then
      if sha=$(scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$BID"); then
        SIG_COMMIT=1; COMMIT_EVID="$RNAME origin/$RDEFAULT@${sha:0:9}"
      elif [ "$RGITDIR" != "$HQ_GITDIR" ] && sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$BID"); then
        SIG_COMMIT=1; COMMIT_EVID="hq origin/$HQ_DEFAULT@${sha:0:9}"
      fi
    fi

    # Signal C — branch ancestor of origin/main. Branch from marker labels, else
    # the crew/*/<id> convention discovered on the remote.
    SIG_BRANCH=0; BRANCH_EVID=""
    if [ "$IS_EPIC" = "0" ] && [ "$HAS_OPEN" = "0" ] && [ "$SIG_COMMIT" = "0" ] && [ "$SIG_MARKER" = "0" ]; then
      declare -a CANDS=()
      while IFS= read -r br; do [ -n "$br" ] && CANDS+=("$br"); done <<EOF
$(branch_label_from_markers "$MK")
EOF
      # Convention fallback: remote branches whose final path segment == bead id.
      while IFS= read -r br; do [ -n "$br" ] && CANDS+=("$br"); done <<EOF
$(git_in "$RGITDIR" "$RCONTAINER" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/**' 2>/dev/null | sed 's#^origin/##' | awk -v id="$BID" -F/ '$NF==id' || true)
EOF
      for br in "${CANDS[@]:-}"; do
        [ -z "$br" ] && continue
        if branch_merged "$RGITDIR" "$RCONTAINER" "origin/$br" "origin/$RDEFAULT"; then
          SIG_BRANCH=1; BRANCH_EVID="origin/$br ⊑ origin/$RDEFAULT"; break
        fi
      done
    fi

    VERDICT_LINE=$(janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH")
    VERDICT="${VERDICT_LINE%%:*}"; REASON="${VERDICT_LINE#*:}"

    if [ "$VERDICT" = "close" ]; then
      EVID="$REASON"
      [ -n "$COMMIT_EVID" ] && EVID="$EVID [$COMMIT_EVID]"
      [ -n "$BRANCH_EVID" ] && EVID="$EVID [$BRANCH_EVID]"
      [ "$SIG_MARKER" = "1" ] && EVID="$EVID [terminal-marker]"
      if [ "$DRY_RUN" = "1" ]; then
        log "WOULD-CLOSE $BID ($RNAME) — $EVID — \"$BTITLE\""
      else
        REASON_MSG="merged-bead-janitor ($SOURCE_BEAD): work merged to origin/main — $EVID. Auto-closed; was stuck in_progress."
        bd -C "$RPATH" close "$BID" -r "$REASON_MSG" 2>/dev/null \
          && log "CLOSED $BID ($RNAME) — $EVID" \
          || { err "close failed for $BID ($RNAME)"; continue; }
        bd -C "$RPATH" label remove "$BID" "story:in-flight" -q 2>/dev/null || true
        CLOSED_COUNT=$((CLOSED_COUNT+1))
        CLOSED_SUMMARY+=("$BID ($RNAME): $EVID")
      fi
    else
      # Keep — but if kept only for "no-merge-evidence" and a SIBLING heuristic
      # suggests it rode a merged parent branch, emit an advisory (never close).
      log "keep $BID ($RNAME) — $REASON"
      if [ "$REASON" = "no-merge-evidence" ] && [ "$IS_EPIC" = "0" ]; then
        # Advisory sibling detection: a crew/*/<parent> branch that is merged and
        # whose parent != this bead, but this bead shares the rig & is open.
        # We only LOG candidates here; closing requires a per-bead signal.
        : # placeholder kept intentionally light — see README for the convention fix.
      fi
    fi
  done <<EOF
$(printf '%s' "$INPROG" | jq -rc '.[]?')
EOF
  fi  # end in_progress pass guard (N != 0)

  # ── ga-gosfs: story:done reconciliation sweep ───────────────────────────────
  # OPEN story:approved beads (distinct from the in_progress sweep above). After a
  # gate PASS, stories are handed to delivery OPEN with story:approved; if delivery
  # never completes they strand here and the Kanban shows false backlog. With merge
  # evidence AND no active rework, drive story:approved → story:done.
  STORIES=$(bd -C "$RPATH" list --status open --json -l story:approved 2>/dev/null || echo '[]')
  [ -z "$STORIES" ] && STORIES='[]'
  SN=$(printf '%s' "$STORIES" | jq 'length' 2>/dev/null || echo 0)
  [ "$SN" = "0" ] || log "rig $RNAME ($RPREFIX): $SN open story:approved bead(s) to check for story:done reconciliation"

  while IFS= read -r s; do
    [ -z "$s" ] && continue
    SID=$(printf '%s' "$s" | jq -r '.id' 2>/dev/null || true)
    [ -z "$SID" ] && continue
    STYPE=$(printf '%s' "$s" | jq -r '(.issue_type // .type // "")' 2>/dev/null || true)
    STITLE=$(printf '%s' "$s" | jq -r '(.title // "")[0:60]' 2>/dev/null || true)
    SLABELS=$(printf '%s' "$s" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || true)
    SASSIGNEE=$(printf '%s' "$s" | jq -r '.assignee // ""' 2>/dev/null || true)

    S_EPIC=0;     [ "$STYPE" = "epic" ] && S_EPIC=1
    S_DONE=0;     printf '%s' "$SLABELS" | grep -qw "story:done"      && S_DONE=1
    S_INFLIGHT=0; printf '%s' "$SLABELS" | grep -qw "story:in-flight" && S_INFLIGHT=1
    S_BUILDER=0;  [ -n "$SASSIGNEE" ] && S_BUILDER=1
    # delivery owns the bead while it is actively running OR has a recorded
    # failure (a failed deploy/prod-test must NOT be masked as story:done).
    S_DELIV=0
    if printf '%s' "$SLABELS" | grep -qw "delivery:running" \
       || printf '%s' "$SLABELS" | grep -qw "delivery:failed"; then S_DELIV=1; fi

    # Markers (HQ-resident, regardless of which store the bead lives in).
    SMK=$(markers_for_bead "$SID")
    S_OPENMK=0;  has_open_marker "$SMK"           && S_OPENMK=1
    S_SIGMK=0;   has_terminal_passed_marker "$SMK" && S_SIGMK=1

    # Only pay for the git scans when no cheap guard already forces keep.
    S_SIGCOMMIT=0; S_SIGBRANCH=0; S_COMMIT_EVID=""; S_BRANCH_EVID=""
    if [ "$S_EPIC" = "0" ] && [ "$S_DONE" = "0" ] && [ "$S_OPENMK" = "0" ] \
       && [ "$S_INFLIGHT" = "0" ] && [ "$S_BUILDER" = "0" ] && [ "$S_DELIV" = "0" ]; then
      # Signal A — SUBJECT-scoped commit in own-rig repo OR HQ repo (cross-store /
      # HQ-via-rig). Strict (subject only) to reject incidental body mentions of a
      # still-open story — see scan_commit_subject_for_bead.
      if sha=$(scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$SID"); then
        S_SIGCOMMIT=1; S_COMMIT_EVID="$RNAME origin/$RDEFAULT@${sha:0:9}"
      elif [ "$RGITDIR" != "$HQ_GITDIR" ] && sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$SID"); then
        S_SIGCOMMIT=1; S_COMMIT_EVID="hq origin/$HQ_DEFAULT@${sha:0:9}"
      fi
      # Signal C — branch ancestor of origin/main (marker branch label, else crew/*/<id>).
      if [ "$S_SIGCOMMIT" = "0" ] && [ "$S_SIGMK" = "0" ]; then
        declare -a SCANDS=()
        while IFS= read -r br; do [ -n "$br" ] && SCANDS+=("$br"); done <<EOF
$(branch_label_from_markers "$SMK")
EOF
        while IFS= read -r br; do [ -n "$br" ] && SCANDS+=("$br"); done <<EOF
$(git_in "$RGITDIR" "$RCONTAINER" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/**' 2>/dev/null | sed 's#^origin/##' | awk -v id="$SID" -F/ '$NF==id' || true)
EOF
        for br in "${SCANDS[@]:-}"; do
          [ -z "$br" ] && continue
          if branch_merged "$RGITDIR" "$RCONTAINER" "origin/$br" "origin/$RDEFAULT"; then
            S_SIGBRANCH=1; S_BRANCH_EVID="origin/$br ⊑ origin/$RDEFAULT"; break
          fi
        done
      fi
    fi

    S_VERDICT_LINE=$(janitor_story_decide "$S_EPIC" "$S_OPENMK" "$S_DONE" "$S_INFLIGHT" \
                       "$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH")
    S_VERDICT="${S_VERDICT_LINE%%:*}"; S_REASON="${S_VERDICT_LINE#*:}"

    if [ "$S_VERDICT" = "done" ]; then
      S_EVID="$S_REASON"
      [ -n "$S_COMMIT_EVID" ] && S_EVID="$S_EVID [$S_COMMIT_EVID]"
      [ -n "$S_BRANCH_EVID" ] && S_EVID="$S_EVID [$S_BRANCH_EVID]"
      [ "$S_SIGMK" = "1" ] && S_EVID="$S_EVID [terminal-marker]"
      if [ "$DRY_RUN" = "1" ]; then
        log "WOULD-DONE $SID ($RNAME) — $S_EVID — \"$STITLE\""
      else
        # Mirror story-delivery's terminal: leave the bead OPEN (delivered stories
        # are not closed — story:done is the terminal label), keep story:approved
        # (the persistent story-type marker the Pilot/gate/delivery selectors rely
        # on), strip any lingering story:in-flight, add story:done. Idempotent.
        bd -C "$RPATH" label remove "$SID" "story:in-flight" -q 2>/dev/null || true
        if bd -C "$RPATH" label add "$SID" "story:done" -q 2>/dev/null; then
          log "DONE $SID ($RNAME) — $S_EVID"
          bd -C "$RPATH" comment "$SID" "merged-bead-janitor ($SOURCE_BEAD, ga-gosfs story:done reconciliation): code is in origin/main — $S_EVID — but the story was stranded story:approved (gate→delivery→done did not complete: cross-store gate:passed, superseded path, rig-store delivery never scanned, or a delivery crash). Transitioned story:approved → story:done so the Kanban no longer shows it as false backlog. story:approved kept (story-type marker); bead left open (story:done is the terminal label, matching story-delivery)." 2>/dev/null || true
          DONE_COUNT=$((DONE_COUNT+1))
          DONE_SUMMARY+=("$SID ($RNAME): $S_EVID")
        else
          err "story:done label add failed for $SID ($RNAME)"
        fi
      fi
    else
      log "keep-story $SID ($RNAME) — $S_REASON"
    fi
  done <<EOF
$(printf '%s' "$STORIES" | jq -rc '.[]?')
EOF

  # ── convoy-reconciler: orphaned wrapper / coordination bead sweep ───────────
  # Closes Pilot/gate CONVOY wrapper beads (issue_type:convoy, "build story X" /
  # "fix bug X" slings) and engine-deacon dc-* coordination beads ("Merge failed",
  # "Rebase required") whose tracked work is DONE — proven PURELY by dependency
  # closure (NO commit-matching; see janitor_convoy_decide + ga-92o95). A wrapper
  # with ≥1 dependency where EVERY DEPENDS-ON target is CLOSED is orphaned → close.
  # No deps / any open dep / unreadable deps → KEEP. dc-* beads live in the HQ
  # store but accrue per-rig too, so this runs in every rig store like the sweeps
  # above. Idempotent; DRY_RUN-aware.
  CONVOYS=$(bd -C "$RPATH" list --status open --limit 0 --json 2>/dev/null \
              | jq -c '[.[]? | select((.issue_type // .type // "") == "convoy" or ((.id // "") | startswith("dc-")))]' 2>/dev/null || echo '[]')
  [ -z "$CONVOYS" ] && CONVOYS='[]'
  CN=$(printf '%s' "$CONVOYS" | jq 'length' 2>/dev/null || echo 0)
  [ "$CN" = "0" ] || log "rig $RNAME ($RPREFIX): $CN open convoy/coordination wrapper(s) to check for orphan reconciliation"

  while IFS= read -r c; do
    [ -z "$c" ] && continue
    CID=$(printf '%s' "$c" | jq -r '.id' 2>/dev/null || true)
    [ -z "$CID" ] && continue
    # anti-Dolt-spike cap: stop CLOSING once the per-sweep limit is hit (real runs
    # only — dry-run stays unbounded for auditing). Remaining orphans drain next sweep.
    if [ "$DRY_RUN" != "1" ] && [ "$CONVOY_COUNT" -ge "$CONVOY_MAX_PER_SWEEP" ]; then
      log "convoy-reconciler: per-sweep cap $CONVOY_MAX_PER_SWEEP reached — deferring remaining orphans to next sweep (anti-Dolt-spike)"
      break
    fi
    CTITLE=$(printf '%s' "$c" | jq -r '(.title // "")[0:60]' 2>/dev/null || true)

    # Read the wrapper's OWN dependency list (the only signal — no commit scan).
    CSHOW=$(bd -C "$RPATH" show "$CID" --json 2>/dev/null || true)
    read -r C_DEPN C_OPENN C_READABLE <<<"$(convoy_dep_counts "$CSHOW")"

    C_VERDICT_LINE=$(janitor_convoy_decide "$C_DEPN" "$C_OPENN" "$C_READABLE")
    C_VERDICT="${C_VERDICT_LINE%%:*}"; C_REASON="${C_VERDICT_LINE#*:}"

    if [ "$C_VERDICT" = "close" ]; then
      C_EVID="$C_REASON [deps=$C_DEPN open=$C_OPENN]"
      if [ "$DRY_RUN" = "1" ]; then
        log "WOULD-CLOSE-CONVOY $CID ($RNAME) — $C_EVID — \"$CTITLE\""
      else
        C_REASON_MSG="reaped: convoy/coordination wrapper orphaned — all dependencies closed (merged-bead-janitor convoy-reconciler)"
        # First try a clean close; if blocked (e.g. an already-closed/obsolete
        # dependency makes bd refuse), retry once with --force.
        if bd -C "$RPATH" close "$CID" -r "$C_REASON_MSG" 2>/dev/null \
           || bd -C "$RPATH" close "$CID" --force -r "$C_REASON_MSG" 2>/dev/null; then
          log "CLOSED-CONVOY $CID ($RNAME) — $C_EVID"
          CONVOY_COUNT=$((CONVOY_COUNT+1))
          CONVOY_SUMMARY+=("$CID ($RNAME): $C_EVID")
        else
          err "convoy close failed for $CID ($RNAME)"; continue
        fi
      fi
    else
      log "keep-convoy $CID ($RNAME) — $C_REASON"
    fi
  done <<EOF
$(printf '%s' "$CONVOYS" | jq -rc '.[]?')
EOF
done <<EOF
$RIG_ROWS
EOF

log "=== merged-bead-janitor sweep complete — closed=$CLOSED_COUNT story_done=$DONE_COUNT convoy_reaped=$CONVOY_COUNT advisories=$SIBLING_ADVISORIES dry_run=$DRY_RUN ==="
if [ "$DRY_RUN" = "0" ]; then
  if [ "$CLOSED_COUNT" -gt 0 ]; then
    SUMMARY=$(printf '%s; ' "${CLOSED_SUMMARY[@]}")
    notify_athos -t "Kanban janitor" "Auto-closed $CLOSED_COUNT merged-but-stuck bead(s): $SUMMARY"
  fi
  if [ "$DONE_COUNT" -gt 0 ]; then
    DSUMMARY=$(printf '%s; ' "${DONE_SUMMARY[@]}")
    notify_athos -t "Kanban janitor" "Reconciled $DONE_COUNT merged story/stories → story:done: $DSUMMARY"
  fi
  if [ "$CONVOY_COUNT" -gt 0 ]; then
    # The first sweep may reap hundreds of orphaned wrappers — cap the message to
    # a count + a short sample so the notification stays readable.
    CSAMPLE=$(printf '%s; ' "${CONVOY_SUMMARY[@]:0:8}")
    [ "$CONVOY_COUNT" -gt 8 ] && CSAMPLE="$CSAMPLE…(+$((CONVOY_COUNT-8)) more)"
    notify_athos -t "Kanban janitor" "Reaped $CONVOY_COUNT orphaned convoy/coordination wrapper(s) (all deps closed): $CSAMPLE"
  fi
fi
exit 0
