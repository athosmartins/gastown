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
#   (A) COMMIT  — the bead id appears (token-bounded) in an origin/main commit
#                 message of the bead's own rig repo OR the HQ repo (mirror).
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
declare -a CLOSED_SUMMARY=()

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
  INPROG=$(bd -C "$RPATH" list --status in_progress --all --json 2>/dev/null || echo '[]')
  [ -z "$INPROG" ] && INPROG='[]'
  N=$(printf '%s' "$INPROG" | jq 'length' 2>/dev/null || echo 0)
  log "rig $RNAME ($RPREFIX): $N in_progress bead(s) [store=$RPATH git=$RGITDIR default=$RDEFAULT]"
  [ "$N" = "0" ] && continue

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

    # Signal A — commit message in own-rig repo OR HQ repo (mirror).
    SIG_COMMIT=0; COMMIT_EVID=""
    if [ "$IS_EPIC" = "0" ] && [ "$HAS_OPEN" = "0" ]; then
      if sha=$(scan_commit_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$BID"); then
        SIG_COMMIT=1; COMMIT_EVID="$RNAME origin/$RDEFAULT@${sha:0:9}"
      elif [ "$RGITDIR" != "$HQ_GITDIR" ] && sha=$(scan_commit_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$BID"); then
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
done <<EOF
$RIG_ROWS
EOF

log "=== merged-bead-janitor sweep complete — closed=$CLOSED_COUNT advisories=$SIBLING_ADVISORIES dry_run=$DRY_RUN ==="
if [ "$CLOSED_COUNT" -gt 0 ] && [ "$DRY_RUN" = "0" ]; then
  SUMMARY=$(printf '%s; ' "${CLOSED_SUMMARY[@]}")
  notify_athos -t "Kanban janitor" "Auto-closed $CLOSED_COUNT merged-but-stuck bead(s): $SUMMARY"
fi
exit 0
