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
#   (A) COMMIT  — the bead id is the IMPLEMENTING conventional-commit SCOPE (the
#                 header BEFORE the first colon) of an origin/main commit in the
#                 bead's OWN rig repo: `feat(<id>):` / `fix(<id>):` / `Merge …/<id>:`.
#                 Two things are REJECTED (ga-wisp-ld35wuw, 2026-07-01): (1) body-only
#                 mentions AND trailing "(ga-x/<id>)" context parens — they are
#                 motivation, not delivery; and (2) a commit in the HQ repo for a
#                 RIG-NATIVE bead — a rig bead's completion commit lives in its own
#                 rig repo, so an HQ framework commit that merely NAMES the rig id as
#                 context (`fix(pilot): … (ga-4aree/wa-iy9s8)`) can never count. HQ is
#                 consulted ONLY for a FOREIGN (non-rig-native) bead in a rig store.
#                 Uses subject_impl_scopes_bead via scan_commit_subject_for_bead (shared
#                 with the story sweep). False-negative (real merge missed this sweep) is
#                 far safer than a false-positive (unbuilt work silently closed); signals
#                 B/C (terminal marker, crew/*/<id> branch-ancestor) are the catch-up.
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

# ── Branch-prune sweep (ga-tijv5 extension, 2026-07-01) — OPT-IN, default OFF ─
# Merged crew branches (crew/<persona>/<id>) accumulate on the shared remotes and
# are NEVER pruned after merge (measured 2026-07-01: 495 on whatsapp-automation,
# 14 on property_scrapers). This sweep prunes the FULLY-MERGED cruft (ahead=0 vs
# origin/<default>) whose bead is closed/gone, that has no live worktree, and is
# past a freshness grace window. It is DELIBERATELY conservative — it NEVER touches
# a branch with unique unmerged commits (ahead>0), so remote history is never lost.
#
# STAGED, not deployed: default OFF so the already-loaded launchd job keeps its
# current behaviour untouched. Enable per-run with --prune-branches / JANITOR_PRUNE_BRANCHES=1,
# or durably by adding <key>JANITOR_PRUNE_BRANCHES</key><string>1</string> to the
# plist's EnvironmentVariables (the Mayor's deploy step, after reviewing a dry-run:
#   JANITOR_PRUNE_BRANCHES=1 JANITOR_DRY_RUN=1 ./merged-bead-janitor.sh).
PRUNE_BRANCHES="${JANITOR_PRUNE_BRANCHES:-0}"
# Freshness grace: never prune a branch whose tip is younger than this many days,
# even if merged (an agent may still reference a just-merged branch).
BRANCH_FRESH_DAYS="${BRANCH_FRESH_DAYS:-7}"
# Anti-Dolt-spike / anti-runaway: cap real branch deletions per sweep. The first
# real run drains a large backlog over several cadence cycles instead of at once.
BRANCH_PRUNE_MAX_PER_SWEEP="${BRANCH_PRUNE_MAX:-100}"

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --prune-branches) PRUNE_BRANCHES=1 ;;
    --rig=*)          RIGS_FILTER="$RIGS_FILTER ${arg#--rig=}" ;;
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
#                <sig_commit_stale>
# Each arg is 0|1 (sig_commit_stale defaults to 0 when omitted — backward-compatible
# with every pre-ga-2zp4h caller/test). Echoes "<verdict>:<reason>" where verdict ∈
# {keep,close}. Guards are evaluated FIRST (an open marker or epic always wins over
# signals).
#
# sig_commit_stale (ga-2zp4h, 2026-07-26): Signal A alone only proves "a conventional
# commit scoped to this bead id landed in origin/main" — not that THIS bead's own
# remaining work is done. wa-d3136 was a JOINT bead split into two owners' halves;
# mila's half was delivered and gated under her OWN sibling bead (wa-eda28), but her
# commit's subject still scoped `chore(wa-d3136): …` (the shared parent id) — so
# Signal A matched and the janitor closed wa-d3136 while thies's half was still
# undone. sig_commit_stale=1 means a bead comment postdates the matched commit (see
# commit_evidence_stale) — a cheap proxy for "this bead's story continued after that
# commit; the commit alone may not mean THIS bead is finished." It suppresses ONLY
# signal A's ability to close ALONE — signals B (marker) and C (branch) are
# bead-specific and authoritative, so they are UNAFFECTED and still close normally.
# ═════════════════════════════════════════════════════════════════════════════
janitor_decide() {
  local is_epic="$1" has_open_marker="$2" sig_commit="$3" sig_marker="$4" sig_branch="$5" \
        sig_commit_stale="${6:-0}"
  if [ "$is_epic" = "1" ]; then            echo "keep:epic-parent-never-autoclosed"; return 0; fi
  if [ "$has_open_marker" = "1" ]; then    echo "keep:active-open-gate-marker"; return 0; fi
  if [ "$sig_commit" = "1" ] && [ "$sig_commit_stale" != "1" ]; then
                                            echo "close:commit-in-origin-main"; return 0; fi
  if [ "$sig_marker" = "1" ]; then         echo "close:terminal-gate-marker-passed-or-superseded"; return 0; fi
  if [ "$sig_branch" = "1" ]; then         echo "close:branch-ancestor-of-origin-main"; return 0; fi
  if [ "$sig_commit" = "1" ]; then         echo "keep:commit-evidence-superseded-by-newer-comment"; return 0; fi
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
#                      <sig_commit> <sig_marker> <sig_branch> <sig_commit_stale>
# Each arg is 0|1 (sig_commit_stale defaults to 0 when omitted — backward-compatible).
# Echoes "<verdict>:<reason>", verdict ∈ {done,keep}. Guards are evaluated FIRST and in
# a fixed precedence — ANY active-rework or not-a-merged-story condition wins over the
# merge signals (zero false-positive is paramount: a genuinely-pending approved story
# must NEVER be force-done). sig_commit_stale (ga-2zp4h): same suppression as
# janitor_decide — a bead comment postdating Signal A's matched commit means that
# commit alone should not force story:done; signals B/C are unaffected.
# ═════════════════════════════════════════════════════════════════════════════
janitor_story_decide() {
  local is_epic="$1" has_open_marker="$2" already_done="$3" in_flight="$4" \
        has_builder="$5" delivery_active="$6" sig_commit="$7" sig_marker="$8" sig_branch="$9" \
        sig_commit_stale="${10:-0}"
  # — Guards (keep) — first match wins (each returns) —
  # SECURITY (sibling-path parity, ga-v3o6i sweep): ACTIVE-WORK guards MUST precede
  # already_done. A bead can carry a stale story:done label AND be re-opened (open
  # gate-marker / in-flight rework / live builder / delivery-active). If already_done
  # were checked first (it was — bug), such a bead verdicts "already-story-done" and the
  # orphan-close backstop would FALSE-CLOSE active rework. Order: active-work → already_done.
  if [ "$is_epic" = "1" ];         then echo "keep:epic-parent-never-autoclosed"; return 0; fi
  if [ "$has_open_marker" = "1" ]; then echo "keep:active-open-gate-marker"; return 0; fi
  if [ "$in_flight" = "1" ];       then echo "keep:story-in-flight-active-rework"; return 0; fi
  if [ "$has_builder" = "1" ];     then echo "keep:live-builder-assignee"; return 0; fi
  if [ "$delivery_active" = "1" ]; then echo "keep:delivery-owns-it"; return 0; fi
  if [ "$already_done" = "1" ];    then echo "keep:already-story-done"; return 0; fi
  # — Merge evidence (done) — same triangulation as janitor_decide —
  if [ "$sig_commit" = "1" ] && [ "$sig_commit_stale" != "1" ]; then
                                   echo "done:commit-in-origin-main"; return 0; fi
  if [ "$sig_marker" = "1" ];      then echo "done:terminal-gate-marker-passed-or-superseded"; return 0; fi
  if [ "$sig_branch" = "1" ];      then echo "done:branch-ancestor-of-origin-main"; return 0; fi
  if [ "$sig_commit" = "1" ];      then echo "keep:commit-evidence-superseded-by-newer-comment"; return 0; fi
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
# PURE DECISION FUNCTION #4 — crew-branch prune (ga-tijv5 extension, 2026-07-01).
#
# WHY: merged crew branches (crew/<persona>/<id>) are never pruned after their
# work lands in origin/<default>. They pile up on the shared remotes (495 on
# whatsapp-automation, 14 on property_scrapers when measured) and never shrink.
#
# SAFETY POSTURE — provably lossless. A branch is pruned ONLY when its CONTENT is
# fully in origin/<default>, established by EITHER of two lossless signals:
#   • ahead==0                — every commit is a strict ancestor of the default
#                               branch (fast-forward / merge landing).
#   • content_in_main (cim==1) — the branch landed via SQUASH / re-commit: its tip
#                               is NOT an ancestor (a new sha), but every one of its
#                               patches is already present in main by patch-id
#                               equivalence (git --cherry-pick). This is the
#                               wa-fvxj1 class: feat(warming/wa-fvxj1) was
#                               re-committed onto main, so the crew branch tip
#                               (ahead>0) is not an ancestor yet loses nothing when
#                               deleted. See content_in_main() for the exact check.
# A branch that has ANY unique patch NOT in main (ahead>0 AND cim!=1) is NEVER
# pruned here — that is the destructive case and it is categorically excluded. On
# top of the merged-by-content gate, three KEEP guards protect edge cases:
#   • live worktree  — an agent has the branch checked out locally (active work).
#   • fresh          — tip younger than BRANCH_FRESH_DAYS (grace: just-merged work
#                      an agent might still push follow-ups to).
#   • bead active    — the branch's bead is open/in_progress/blocked/deferred/etc
#                      (kept as a courtesy even though the content is already in main).
# And it is FAIL-OPEN: if the bead status could not be read (Dolt hiccup), the
# state is "readerror" → KEEP. Only a definitively-closed or definitively-gone
# bead (clean not-found in BOTH the rig store AND the HQ store) permits a prune.
#
# janitor_branch_decide <ahead> <content_in_main> <bead_state> <live_worktree> <is_fresh>
#   ahead           — integer string; commits on the branch NOT in origin/<default>
#                     by SHA. Non-numeric (e.g. "ERR" from a failed rev-list) is
#                     treated as ahead>0; only cim==1 can then permit a prune.
#   content_in_main — 0|1; 1 iff every branch patch is already in main (ahead==0 OR
#                     squash/re-commit). The lossless gate. Non-1 with ahead>0 = KEEP.
#   bead_state      — closed | active | gone | readerror  (see resolve_bead_state).
#   live_worktree   — 0|1.   is_fresh — 0|1.
# Echoes "<verdict>:<reason>", verdict ∈ {prune,keep}. KEEP-biased: every guard
# and every uncertain state resolves to keep. Guards evaluated in fixed precedence.
# The prune reason distinguishes the strict-ancestor case (merged-*) from the
# squash/re-commit case (squash-merged-*) for auditability of the dry-run log.
# ═════════════════════════════════════════════════════════════════════════════
janitor_branch_decide() {
  local ahead="$1" cim="$2" bead_state="$3" live="$4" fresh="$5"
  if [ "$live" = "1" ];               then echo "keep:live-worktree"; return 0; fi
  # MERGED-BY-CONTENT gate: keep only if there is unique unmerged work — i.e.
  # ahead>0 (by sha) AND the content is NOT patch-present in main (cim!=1). A
  # squash/re-commit (ahead>0 but cim==1) is lossless to prune and falls through.
  if [ "$ahead" != "0" ] && [ "$cim" != "1" ]; then echo "keep:has-unmerged-commits"; return 0; fi
  if [ "$fresh" = "1" ];              then echo "keep:fresh-branch-grace-window"; return 0; fi
  if [ "$bead_state" = "readerror" ]; then echo "keep:bead-read-error-failopen"; return 0; fi
  if [ "$bead_state" = "active" ];    then echo "keep:bead-open-or-active"; return 0; fi
  # Prune paths — distinguish strict-ancestor (ahead==0) from squash/re-commit
  # (ahead>0 but content patch-present in main) purely for log auditability.
  if [ "$ahead" = "0" ]; then
    if [ "$bead_state" = "closed" ];  then echo "prune:merged-and-bead-closed"; return 0; fi
    if [ "$bead_state" = "gone" ];    then echo "prune:merged-and-bead-gone"; return 0; fi
  else
    if [ "$bead_state" = "closed" ];  then echo "prune:squash-merged-and-bead-closed"; return 0; fi
    if [ "$bead_state" = "gone" ];    then echo "prune:squash-merged-and-bead-gone"; return 0; fi
  fi
  echo "keep:unknown-bead-state-failsafe"
}

# normalize_bead_status <raw_bd_status> — map a raw bd `status` string to the
# coarse {closed|active} classification the branch decider uses. Pure/testable.
# "closed" → closed; any other non-empty status (open/in_progress/blocked/
# deferred/hooked/pinned/…) → active; empty → active (a found-but-blank status
# is treated as active, i.e. KEEP — the safe direction).
normalize_bead_status() {
  case "$1" in
    closed) echo "closed" ;;
    *)      echo "active" ;;
  esac
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

# subject_impl_scopes_bead <subject_line> <bead_id> — THE DISCRIMINATOR (ga-wisp-ld35wuw,
# 2026-07-01). rc0 iff <bead_id> is the IMPLEMENTING conventional-commit SCOPE of <subject>;
# rc1 if it is only a trailing context/motivation reference. This is the exact test that has
# to separate a genuine delivery from a framework commit that merely NAMES the bead as context:
#     MERGED     (rc0)  fix(wa-iy9s8): auto-deploy viewer/ to S3 on merge     ← id IS the scope
#     NOT-MERGED (rc1)  fix(pilot): … rig re-fix bugs dispatch (ga-4aree/wa-iy9s8)
#                       ← id is a TRAILING "(scope/…)" context paren; the real scope is `pilot`.
#
# WHY token-bounding the WHOLE subject was not enough (the wa-iy9s8 false-close): a Pilot
# framework commit's SUBJECT can carry the rig bead-id in a trailing "(ga-x/<id>)" motivation
# parenthetical. token_bounded matched it anywhere in the subject → the old scan reported it
# MERGED and the in_progress sweep auto-CLOSED the bead — hiding un-built work behind "done".
#
# RULE: a conventional-commit's type/scope lives in the HEADER `type(scope):` that PRECEDES the
# FIRST colon. The bead id must be token-bounded WITHIN that header — as the whole scope
# `fix(<id>)`, a path segment `feat(area/<id>)`, a genuine merge landing `Merge crew/x/<id>:`,
# or a bare `<id>:` / `fix bug <id>:` lead. ANYTHING after the first colon — the description,
# the "(ga-x/<id>)" motivation paren, "fixes dispatch for <id>", "refs <id>", "(interim until
# <id> Phase-2)" — is CONTEXT, never delivery. FAIL-CLOSED: a subject with NO colon (no
# locatable conventional scope) does NOT match; a Revert header (git's default `Revert "…"` or
# a `revert: …` conventional) does NOT match — the change is being UNDONE, not delivered. Pure.
# Verified 2026-07-01: rc1 on 286cb29c7-HQ (`fix(pilot): … (ga-4aree/wa-iy9s8)`), rc0 on
# d0219063-WA (`fix(wa-iy9s8): …`).
subject_impl_scopes_bead() {
  local subj="$1" id="$2" header
  case "$subj" in *:*) : ;; *) return 1 ;; esac    # no colon → no conventional scope → fail-closed
  header="${subj%%:*}"                             # text before the FIRST colon = type(scope) / merge / bare-id lead
  case "$header" in [Rr]evert*) return 1 ;; esac   # revert (undo, not delivery) → reject
  token_bounded "$id" "$header"                    # id must be a whole token WITHIN the header/scope
}

# scan_commit_subject_for_bead <git_dir> <is_container> <ref> <bead_id>
# STRICTER variant of scan_commit_for_bead used by BOTH the in_progress→close sweep and the
# story:done reconciliation sweep (ga-gosfs): rc0 + prints the first matching sha iff an
# ancestor commit of <ref> references the bead id as an IMPLEMENTING conventional-commit SCOPE
# in its SUBJECT line (feat(<id>): / fix(<id>): / feat(area/<id>): / Merge …/<id>: / <id>: /
# "fix bug <id>:"). The scope test is subject_impl_scopes_bead: the id must be token-bounded in
# the header BEFORE the first colon, NOT anywhere in the subject. Body-only mentions AND trailing
# "(context/<id>)" description parens are REJECTED (see subject_impl_scopes_bead for the why).
#
# WHY strict: closing a bead / marking a story done is irreversible UX (it leaves the board) so
# zero false-positive is paramount (AC3). Unrelated commits routinely name a bead in their BODY
# or as trailing context — "remains open in ga-r471 engine window", "rig re-fix bugs dispatch
# (ga-4aree/wa-iy9s8)". A genuine delivery always puts the id in the SUBJECT SCOPE (gate-done
# commits as feat(<id>)/fix(<id>)). The unambiguous marker + branch signals still cover the
# cross-store / superseded cases where no subject-scoped commit exists. `-F --grep` pre-filters
# to commits mentioning the id (subject OR body); subject_impl_scopes_bead then keeps only the
# ones whose SUBJECT SCOPE is the id.
scan_commit_subject_for_bead() {
  local gdir="$1" container="$2" ref="$3" id="$4"
  git_in "$gdir" "$container" rev-parse -q --verify "$ref" >/dev/null 2>&1 || return 1
  local shas sha subj
  shas=$(git_in "$gdir" "$container" log "$ref" -F --grep="$id" --format='%H' 2>/dev/null || true)
  [ -z "$shas" ] && return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    subj=$(git_in "$gdir" "$container" log -1 --format='%s' "$sha" 2>/dev/null || true)
    if subject_impl_scopes_bead "$subj" "$id"; then printf '%s' "$sha"; return 0; fi
  done <<EOF
$shas
EOF
  return 1
}

# commit_epoch <git_dir> <is_container> <sha> — echoes <sha>'s committer-date epoch
# seconds (git %ct), rc1 + prints nothing if <sha> is empty/unresolvable. Live-git
# helper; pairs with commit_evidence_stale (ga-2zp4h) to test whether a bead's own
# activity postdates the commit Signal A matched.
commit_epoch() {
  local gdir="$1" container="$2" sha="$3"
  [ -z "$sha" ] && return 1
  git_in "$gdir" "$container" log -1 --format='%ct' "$sha" 2>/dev/null
}

# commit_evidence_stale <comments_json> <commit_epoch> — rc0 iff any comment's
# created_at (ISO-8601 UTC, the `bd comments <id> --json` shape) is STRICTLY newer
# than <commit_epoch>.
#
# WHY (ga-2zp4h, 2026-07-26): Signal A (scan_commit_subject_for_bead) only proves a
# conventional commit SCOPED to this bead id exists in origin/main — it says nothing
# about whether THIS bead's own remaining work is done. wa-d3136 was a JOINT bead:
# mila's half was delivered and gated under her OWN sibling bead (wa-eda28), but her
# commit's subject still read `chore(wa-d3136): …` (the shared PARENT id) — a
# legitimate subject-scope match, yet the bead was reassigned to a second owner
# (thies) via a comment a full DAY after that commit landed, and his half was never
# built. The janitor closed it anyway. A comment newer than the matched commit is a
# cheap, general proxy for "this bead's story continued after that commit" — it does
# not prove the bead is unfinished, it just means Signal A's single commit should not
# be trusted ALONE (see janitor_decide's sig_commit_stale gate).
#
# FAIL-OPEN (rc1, "not stale") on an empty/non-numeric commit_epoch or on any
# comment whose created_at cannot be parsed — preserves today's Signal-A behaviour
# rather than introducing a new way for the janitor to go silent on a genuine merge
# because a comment read/parse hiccuped. This mirrors the file's existing best-effort
# idiom (markers_for_bead, convoy_dep_counts, etc. all default to the pre-existing,
# already-shipped behaviour on read failure).
commit_evidence_stale() {
  local comments_json="$1" commit_epoch="$2"
  case "$commit_epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$comments_json" | jq -e --argjson ts "$commit_epoch" '
    any(.[]?; (try (.created_at // "" | fromdateiso8601) catch -1) > $ts)
  ' >/dev/null 2>&1
}

# branch_merged <git_dir> <is_container> <branch_ref> <main_ref>
# rc0 iff branch_ref resolves and is an ancestor of main_ref.
branch_merged() {
  local gdir="$1" container="$2" bref="$3" mref="$4"
  # ga-tijv5 (2026-06-30): REJECT the degenerate self-referential check. A bref that
  # resolved to the main ref itself (a bad marker-label, or a molecule fold-linkage
  # giving "main") makes "origin/main ⊑ origin/main" trivially true → it FALSE-closed an
  # in_progress bead whose real crew branch was 3 commits AHEAD of main, unmerged
  # (wa-85iv8). A branch signal must compare a SEPARATE crew branch against main, never
  # main against itself. (Primary root fix: the caller's basename==bead-id guard.)
  [ -z "$bref" ] && return 1
  [ "$bref" = "$mref" ] && return 1
  git_in "$gdir" "$container" rev-parse -q --verify "$bref" >/dev/null 2>&1 || return 1
  git_in "$gdir" "$container" merge-base --is-ancestor "$bref" "$mref" 2>/dev/null
}

# content_in_main <git_dir> <is_container> <branch_ref> <main_ref>
# rc0 iff EVERY commit unique to <branch_ref> already has its patch present in
# <main_ref> — the SQUASH-AWARE "is the work merged" test. Unlike branch_merged
# (which requires the tip to be a strict git ANCESTOR), this recognises a branch
# whose content landed via a SQUASH-merge or a re-commit: main carries a NEW sha
# with the same diff, so the branch tip is not an ancestor (ahead>0 by sha) yet
# nothing on the branch is missing from main.
#
#   git rev-list --count --cherry-pick --right-only <main>...<branch>
#     counts the commits reachable from <branch> but not <main> whose patch is NOT
#     also present on the <main> side (git matches squashed/re-committed changes by
#     patch-id). A count of 0 ⟺ every branch patch is already in main ⟺ deleting
#     the branch loses NOTHING. This is provably lossless: a false "merged" verdict
#     would require a genuinely-unique diff to collide with an identical diff in
#     main, in which case the content IS byte-for-byte in main and nothing is lost.
#
# FAIL-CLOSED: any non-"0" / empty / error count → rc1 (treated as NOT merged), so
# the janitor's destructive prune path keeps the branch on any doubt. Rejects the
# degenerate self-check (bref==mref) and unresolvable refs. Verified 2026-07-01 on
# wa-fvxj1 (squash: count 0 → rc0) vs a genuinely-unmerged branch (count>0 → rc1).
content_in_main() {
  local gdir="$1" container="$2" bref="$3" mref="$4"
  [ -z "$bref" ] && return 1
  [ "$bref" = "$mref" ] && return 1
  git_in "$gdir" "$container" rev-parse -q --verify "$bref" >/dev/null 2>&1 || return 1
  git_in "$gdir" "$container" rev-parse -q --verify "$mref" >/dev/null 2>&1 || return 1
  local n
  n=$(git_in "$gdir" "$container" rev-list --count --cherry-pick --right-only "$mref...$bref" 2>/dev/null || echo ERR)
  [ "$n" = "0" ]
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

# comments_for_bead <store_path> <bead_id> — echoes the bead's comments as a JSON
# array (`bd comments <id> --json` shape: each entry has .created_at), or '[]' on
# any failure. Feeds commit_evidence_stale ONLY — never itself a decision signal,
# same live-fetch-then-pure-decide split as markers_for_bead/has_open_marker.
comments_for_bead() {
  local store="$1" id="$2" out
  out=$(bd -C "$store" comments "$id" --json 2>/dev/null) || out=""
  case "$out" in ''|null) out='[]' ;; esac
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

# ── Branch-prune live helpers (ga-tijv5 extension) ───────────────────────────

# branch_is_fresh <git_dir> <container> <ref> <days> — echoes 1 iff <ref>'s tip
# committer date is within <days> of now, else 0. Unknown/unreadable date → 0
# (a branch with no resolvable tip date is not treated as fresh; the ahead==0 +
# closed/gone-bead gates still protect it). Pure-git (no Dolt) → selftest-able.
branch_is_fresh() {
  local gdir="$1" container="$2" ref="$3" days="$4" ts now
  ts=$(git_in "$gdir" "$container" log -1 --format='%ct' "$ref" 2>/dev/null || echo "")
  case "$ts" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  now=$(date +%s)
  if [ "$(( (now - ts) / 86400 ))" -lt "$days" ] 2>/dev/null; then echo 1; else echo 0; fi
}

# bead_lookup_one <store_path> <bead_id> — echoes "found:<status>" | "notfound" |
# "readerror". A clean not-found is bd emitting {"error":"no issue(s) found …"}
# with rc0; anything unparseable / empty / a non-not-found error → readerror
# (fail-open: the caller keeps the branch). Single-bead read (cheap).
bead_lookup_one() {
  local store="$1" id="$2" out st
  out=$(bd -C "$store" show "$id" --json 2>/dev/null) || { echo "readerror"; return 0; }
  [ -z "$out" ] && { echo "readerror"; return 0; }
  if printf '%s' "$out" | jq -e '(.error // "") | test("no issue")' >/dev/null 2>&1; then
    echo "notfound"; return 0
  fi
  st=$(printf '%s' "$out" | jq -r '(if type=="array" then .[0] else . end) | .status // ""' 2>/dev/null) \
    || { echo "readerror"; return 0; }
  [ -z "$st" ] && { echo "readerror"; return 0; }
  echo "found:$st"
}

# resolve_bead_state <rig_store> <bead_id> — echoes closed | active | gone |
# readerror. Queries the rig store first, then the HQ store (crew branches in a
# rig repo are routinely tied to HQ-store ga-*/dc-* beads). "gone" is returned
# ONLY when BOTH stores CLEANLY report not-found — a read error in EITHER store
# yields "readerror" so the decider fails open (keeps the branch). This is the
# guard that prevents a transient Dolt hiccup from ever being read as "no bead".
resolve_bead_state() {
  local rig_store="$1" id="$2" r h
  r=$(bead_lookup_one "$rig_store" "$id")
  case "$r" in
    found:*)   normalize_bead_status "${r#found:}"; return 0 ;;
    readerror) echo "readerror"; return 0 ;;
  esac
  # rig store said notfound → consult HQ store.
  h=$(bead_lookup_one "$GC_CITY" "$id")
  case "$h" in
    found:*)   normalize_bead_status "${h#found:}"; return 0 ;;
    readerror) echo "readerror"; return 0 ;;
    notfound)  echo "gone"; return 0 ;;
  esac
  echo "readerror"
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
# --prune is REQUIRED: the branch-prune sweep enumerates local remote-tracking
# refs (refs/remotes/origin/crew/*) to decide deletions; without --prune a stale
# tracking ref for a branch already deleted (or deleted-then-recreated) on the
# remote would make the sweep act on outdated state. Pruning tracking refs is
# also harmless to the commit/marker/branch signals of the other sweeps.
declare -a FETCHED=()
fetch_once() {
  local gdir="$1" container="$2" key prune=""
  # --prune ONLY when the branch-prune sweep is enabled — it enumerates local
  # remote-tracking refs, so it must not act on stale ones. Gated behind
  # PRUNE_BRANCHES so the deployed job's behaviour is byte-for-byte unchanged
  # until the Mayor flips the switch (staged posture). The commit/marker/branch
  # signals of the other sweeps are unaffected by pruning stale tracking refs.
  [ "$PRUNE_BRANCHES" = "1" ] && prune="--prune"
  key="$gdir"
  for k in "${FETCHED[@]:-}"; do [ "$k" = "$key" ] && return 0; done
  FETCHED+=("$key")
  timeout "$FETCH_TIMEOUT" sh -c '
    if [ "$3" = "1" ]; then git --git-dir="$1" fetch origin $2 --quiet; else git -C "$1" fetch origin $2 --quiet; fi
  ' _ "$gdir" "$prune" "$container" 2>/dev/null || warn "fetch failed/timeout for $gdir (continuing with stale refs)"
}
fetch_once "$HQ_GITDIR" "$HQ_CONTAINER"

CLOSED_COUNT=0
SIBLING_ADVISORIES=0
INFLIGHT_CLOSED_COUNT=0 # ga-hcj4: stranded open+story:in-flight beads closed (Pilot sling-wrapper gap)
DONE_COUNT=0   # ga-gosfs: stories reconciled story:approved → story:done
CONVOY_COUNT=0 # convoy-reconciler: orphaned wrapper/coordination beads closed
CONVOY_MAX_PER_SWEEP="${CONVOY_MAX_PER_SWEEP:-60}" # anti-Dolt-spike: cap REAL closes/sweep; the ~480 backlog drains over a few 15min sweeps instead of 480 commits at once
BRANCH_PRUNE_COUNT=0 # ga-tijv5 extension: merged crew branches pruned this sweep
declare -a CLOSED_SUMMARY=()
declare -a INFLIGHT_CLOSED_SUMMARY=()
declare -a DONE_SUMMARY=()
declare -a CONVOY_SUMMARY=()
declare -a BRANCH_PRUNE_SUMMARY=()

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

    # Signal A — commit whose SUBJECT SCOPE is this bead id, in the bead's OWN rig repo.
    # Uses the STRICT subject-scope scanner: only a conventional-commit whose SCOPE (the
    # header before the first colon) is this bead id (feat(<id>)/fix(<id>)/Merge …/<id>:)
    # counts as delivery evidence. Body-only mentions AND trailing "(ga-x/<id>)" context
    # parens are REJECTED. See scan_commit_subject_for_bead / subject_impl_scopes_bead.
    #
    # REPO-SCOPING (ga-wisp-ld35wuw, 2026-07-01): a RIG-NATIVE bead (id prefix == this rig's
    # prefix, e.g. wa-* in the WA rig) is matched ONLY against its OWN rig repo — NEVER HQ.
    # A rig bead's completion commit lives in its own rig repo; an HQ framework commit that
    # merely NAMES the rig bead-id as context (fix(pilot): … (ga-4aree/wa-iy9s8)) must never
    # count as that rig bead's delivery (that false-closed the P1 bug wa-iy9s8 @ 286cb29c7-HQ).
    # The HQ fallback is retained ONLY for a FOREIGN (non-rig-native) bead sitting in this
    # rig's store — an HQ-home ga-*/dc-* bead — the legitimate cross-store case. (HQ-store
    # beads are swept in the HQ rig iteration where RGITDIR==HQ_GITDIR, so they scan HQ as
    # their own repo; this fallback covers a foreign bead that lives in a rig store.)
    SIG_COMMIT=0; COMMIT_EVID=""; SIG_COMMIT_STALE=0
    if [ "$IS_EPIC" = "0" ] && [ "$HAS_OPEN" = "0" ]; then
      MATCH_GITDIR=""; MATCH_CONTAINER=""
      if sha=$(scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$BID"); then
        SIG_COMMIT=1; COMMIT_EVID="$RNAME origin/$RDEFAULT@${sha:0:9}"
        MATCH_GITDIR="$RGITDIR"; MATCH_CONTAINER="$RCONTAINER"
      elif [ "${BID%%-*}" != "$RPREFIX" ] && [ "$RGITDIR" != "$HQ_GITDIR" ] \
           && sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$BID"); then
        SIG_COMMIT=1; COMMIT_EVID="hq origin/$HQ_DEFAULT@${sha:0:9}"
        MATCH_GITDIR="$HQ_GITDIR"; MATCH_CONTAINER="$HQ_CONTAINER"
      fi
      # ga-2zp4h: a bead comment newer than the matched commit suppresses signal A
      # ALONE (signals B/C below are unaffected) — see commit_evidence_stale /
      # janitor_decide's sig_commit_stale gate (joint/split-bead false-close guard).
      if [ "$SIG_COMMIT" = "1" ]; then
        CEPOCH=$(commit_epoch "$MATCH_GITDIR" "$MATCH_CONTAINER" "$sha")
        BCOMMENTS=$(comments_for_bead "$RPATH" "$BID")
        commit_evidence_stale "$BCOMMENTS" "$CEPOCH" && SIG_COMMIT_STALE=1
      fi
    fi
    # SIG_COMMIT_TRUSTED — signal A only when NOT stale (see above). Signal C below
    # gates on this, not on raw SIG_COMMIT, so a stale signal A never blinds the
    # sweep to an independent, genuinely-merged crew branch for this same bead.
    SIG_COMMIT_TRUSTED=0
    [ "$SIG_COMMIT" = "1" ] && [ "$SIG_COMMIT_STALE" != "1" ] && SIG_COMMIT_TRUSTED=1

    # Signal C — branch ancestor of origin/main. Branch from marker labels, else
    # the crew/*/<id> convention discovered on the remote.
    SIG_BRANCH=0; BRANCH_EVID=""
    if [ "$IS_EPIC" = "0" ] && [ "$HAS_OPEN" = "0" ] && [ "$SIG_COMMIT_TRUSTED" = "0" ] && [ "$SIG_MARKER" = "0" ]; then
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
        # ga-tijv5 (2026-06-30): a branch signal MUST be the bead's OWN crew/*/<id>
        # branch — its final path segment must equal this bead id. branch_label_from_markers
        # can return "main" or a FOLDED bead's branch (shared molecule_id — wa-85iv8's notes
        # said "FOLDED into wa-zjkll"), which then self-matches origin/main ⊑ origin/main and
        # FALSE-closes an in_progress bead with unmerged work. Skip any candidate whose final
        # path segment != this bead id (the convention fallback already enforces this; this
        # extends the same guard to the marker-label source).
        case "$br" in */"$BID") : ;; *) continue ;; esac
        if branch_merged "$RGITDIR" "$RCONTAINER" "origin/$br" "origin/$RDEFAULT"; then
          SIG_BRANCH=1; BRANCH_EVID="origin/$br ⊑ origin/$RDEFAULT"; break
        fi
      done
    fi

    VERDICT_LINE=$(janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE")
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
      # ga-2zp4h: when kept via the stale-comment suppression, surface the
      # suppressed commit evidence so the log line stays auditable (which commit
      # matched but was not trusted alone) instead of a bare reason with no evidence.
      KEEP_MSG="keep $BID ($RNAME) — $REASON"
      [ -n "$COMMIT_EVID" ] && KEEP_MSG="$KEEP_MSG [$COMMIT_EVID]"
      log "$KEEP_MSG"
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

  # ── ga-hcj4: stranded open+story:in-flight sweep (Pilot sling-wrapper gap) ──
  # WHY a bucket alongside in_progress/story:approved: Pilot's "fix bug X" / "fix
  # story X" dispatch convention creates a ROTATING SLING-TASK WRAPPER bead per
  # redispatch attempt (e.g. ga-a1tdi, ga-dp7s, ga-flwo). The wrapper cycles
  # through open/in_progress/closed, but the underlying WORK bead (bug/task, or a
  # story whose gate-PASS handoff never stripped the label) stays status=open with
  # label story:in-flight the ENTIRE time — it is never itself in_progress and
  # never carries story:approved, so it falls into NEITHER sweep, no matter how
  # long its own "fix bug <id>:"/"fix(<id>):" scoped commit has sat merged in
  # origin/main (ga-ap7od: commit merged 1h48m past a healthy 15min sweep cadence,
  # invisible because the WRAPPER, not the bead, was the in_progress row each time).
  #
  # Reuses janitor_decide UNCHANGED — same triangulation as the in_progress sweep
  # (commit-subject-scope / terminal marker / branch-ancestor, keyed on the bead's
  # OWN id) — this bucket only widens which beads FEED that decision. Signal
  # computation below mirrors the in_progress sweep line-for-line (F_-prefixed
  # vars); see that sweep's comments above for the false-close history each guard
  # defends against (repo-scoping, branch self-guard, strict subject-scope).
  INFLIGHT=$(bd -C "$RPATH" list --status open --json -l story:in-flight 2>/dev/null || echo '[]')
  [ -z "$INFLIGHT" ] && INFLIGHT='[]'
  FN=$(printf '%s' "$INFLIGHT" | jq 'length' 2>/dev/null || echo 0)
  [ "$FN" = "0" ] || log "rig $RNAME ($RPREFIX): $FN open story:in-flight bead(s) to check for stranded-wrapper reconciliation"

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    FID=$(printf '%s' "$f" | jq -r '.id' 2>/dev/null || true)
    FTYPE=$(printf '%s' "$f" | jq -r '(.issue_type // .type // "")' 2>/dev/null || true)
    FTITLE=$(printf '%s' "$f" | jq -r '(.title // "")[0:60]' 2>/dev/null || true)
    [ -z "$FID" ] && continue

    F_EPIC=0; [ "$FTYPE" = "epic" ] && F_EPIC=1

    FMK=$(markers_for_bead "$FID")
    F_HASOPEN=0; has_open_marker "$FMK" && F_HASOPEN=1
    F_SIGMARKER=0; has_terminal_passed_marker "$FMK" && F_SIGMARKER=1

    # Signal A — same strict subject-scope commit scan + rig/HQ repo-scoping as
    # the in_progress sweep above.
    F_SIGCOMMIT=0; F_COMMIT_EVID=""; F_SIGCOMMIT_STALE=0
    if [ "$F_EPIC" = "0" ] && [ "$F_HASOPEN" = "0" ]; then
      F_MATCH_GITDIR=""; F_MATCH_CONTAINER=""
      if sha=$(scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$FID"); then
        F_SIGCOMMIT=1; F_COMMIT_EVID="$RNAME origin/$RDEFAULT@${sha:0:9}"
        F_MATCH_GITDIR="$RGITDIR"; F_MATCH_CONTAINER="$RCONTAINER"
      elif [ "${FID%%-*}" != "$RPREFIX" ] && [ "$RGITDIR" != "$HQ_GITDIR" ] \
           && sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$FID"); then
        F_SIGCOMMIT=1; F_COMMIT_EVID="hq origin/$HQ_DEFAULT@${sha:0:9}"
        F_MATCH_GITDIR="$HQ_GITDIR"; F_MATCH_CONTAINER="$HQ_CONTAINER"
      fi
      # ga-2zp4h: same stale-comment suppression as the in_progress sweep above
      # (joint/split-bead false-close guard) — signal A alone, not B/C.
      if [ "$F_SIGCOMMIT" = "1" ]; then
        F_CEPOCH=$(commit_epoch "$F_MATCH_GITDIR" "$F_MATCH_CONTAINER" "$sha")
        F_BCOMMENTS=$(comments_for_bead "$RPATH" "$FID")
        commit_evidence_stale "$F_BCOMMENTS" "$F_CEPOCH" && F_SIGCOMMIT_STALE=1
      fi
    fi
    F_SIGCOMMIT_TRUSTED=0
    [ "$F_SIGCOMMIT" = "1" ] && [ "$F_SIGCOMMIT_STALE" != "1" ] && F_SIGCOMMIT_TRUSTED=1

    # Signal C — branch ancestor of origin/main, same final-path-segment self-guard
    # (must equal this bead id) as the in_progress sweep above.
    F_SIGBRANCH=0; F_BRANCH_EVID=""
    if [ "$F_EPIC" = "0" ] && [ "$F_HASOPEN" = "0" ] && [ "$F_SIGCOMMIT_TRUSTED" = "0" ] && [ "$F_SIGMARKER" = "0" ]; then
      declare -a FCANDS=()
      while IFS= read -r br; do [ -n "$br" ] && FCANDS+=("$br"); done <<EOF
$(branch_label_from_markers "$FMK")
EOF
      while IFS= read -r br; do [ -n "$br" ] && FCANDS+=("$br"); done <<EOF
$(git_in "$RGITDIR" "$RCONTAINER" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/**' 2>/dev/null | sed 's#^origin/##' | awk -v id="$FID" -F/ '$NF==id' || true)
EOF
      for br in "${FCANDS[@]:-}"; do
        [ -z "$br" ] && continue
        case "$br" in */"$FID") : ;; *) continue ;; esac
        if branch_merged "$RGITDIR" "$RCONTAINER" "origin/$br" "origin/$RDEFAULT"; then
          F_SIGBRANCH=1; F_BRANCH_EVID="origin/$br ⊑ origin/$RDEFAULT"; break
        fi
      done
    fi

    F_VERDICT_LINE=$(janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE")
    F_VERDICT="${F_VERDICT_LINE%%:*}"; F_REASON="${F_VERDICT_LINE#*:}"

    if [ "$F_VERDICT" = "close" ]; then
      F_EVID="$F_REASON"
      [ -n "$F_COMMIT_EVID" ] && F_EVID="$F_EVID [$F_COMMIT_EVID]"
      [ -n "$F_BRANCH_EVID" ] && F_EVID="$F_EVID [$F_BRANCH_EVID]"
      [ "$F_SIGMARKER" = "1" ] && F_EVID="$F_EVID [terminal-marker]"
      if [ "$DRY_RUN" = "1" ]; then
        log "WOULD-CLOSE-INFLIGHT $FID ($RNAME) — $F_EVID — \"$FTITLE\""
      else
        F_REASON_MSG="merged-bead-janitor ($SOURCE_BEAD, ga-hcj4 stranded-wrapper reconciliation): work merged to origin/main — $F_EVID. Bead was stuck open+story:in-flight — the Pilot sling-wrapper dispatch convention never put the bead ITSELF in_progress, so the in_progress sweep never scanned it. Auto-closed."
        bd -C "$RPATH" close "$FID" -r "$F_REASON_MSG" 2>/dev/null \
          && log "CLOSED-INFLIGHT $FID ($RNAME) — $F_EVID" \
          || { err "in-flight close failed for $FID ($RNAME)"; continue; }
        bd -C "$RPATH" label remove "$FID" "story:in-flight" -q 2>/dev/null || true
        INFLIGHT_CLOSED_COUNT=$((INFLIGHT_CLOSED_COUNT+1))
        INFLIGHT_CLOSED_SUMMARY+=("$FID ($RNAME): $F_EVID")
      fi
    else
      F_KEEP_MSG="keep-inflight $FID ($RNAME) — $F_REASON"
      [ -n "$F_COMMIT_EVID" ] && F_KEEP_MSG="$F_KEEP_MSG [$F_COMMIT_EVID]"
      log "$F_KEEP_MSG"
    fi
  done <<EOF
$(printf '%s' "$INFLIGHT" | jq -rc '.[]?')
EOF

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
    S_SIGCOMMIT=0; S_SIGBRANCH=0; S_COMMIT_EVID=""; S_BRANCH_EVID=""; S_SIGCOMMIT_STALE=0
    if [ "$S_EPIC" = "0" ] && [ "$S_DONE" = "0" ] && [ "$S_OPENMK" = "0" ] \
       && [ "$S_INFLIGHT" = "0" ] && [ "$S_BUILDER" = "0" ] && [ "$S_DELIV" = "0" ]; then
      # Signal A — commit whose SUBJECT SCOPE is this story id, in the story's OWN rig repo.
      # Strict subject-scope (header before the first colon) to reject incidental body
      # mentions AND trailing "(context/<id>)" parens of a still-open story — see
      # scan_commit_subject_for_bead / subject_impl_scopes_bead. REPO-SCOPING (ga-wisp-ld35wuw):
      # a RIG-NATIVE story (id prefix == rig prefix) is matched ONLY against its own rig repo;
      # the HQ fallback is kept ONLY for a FOREIGN (non-rig-native) story in this rig's store,
      # so a rig story can never be marked done by an HQ framework commit that merely names it.
      S_MATCH_GITDIR=""; S_MATCH_CONTAINER=""
      if sha=$(scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$SID"); then
        S_SIGCOMMIT=1; S_COMMIT_EVID="$RNAME origin/$RDEFAULT@${sha:0:9}"
        S_MATCH_GITDIR="$RGITDIR"; S_MATCH_CONTAINER="$RCONTAINER"
      elif [ "${SID%%-*}" != "$RPREFIX" ] && [ "$RGITDIR" != "$HQ_GITDIR" ] \
           && sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$SID"); then
        S_SIGCOMMIT=1; S_COMMIT_EVID="hq origin/$HQ_DEFAULT@${sha:0:9}"
        S_MATCH_GITDIR="$HQ_GITDIR"; S_MATCH_CONTAINER="$HQ_CONTAINER"
      fi
      # ga-2zp4h: same stale-comment suppression as the in_progress sweep — a story
      # can be a joint/split bead too. Suppresses signal A alone, not B/C.
      if [ "$S_SIGCOMMIT" = "1" ]; then
        S_CEPOCH=$(commit_epoch "$S_MATCH_GITDIR" "$S_MATCH_CONTAINER" "$sha")
        S_BCOMMENTS=$(comments_for_bead "$RPATH" "$SID")
        commit_evidence_stale "$S_BCOMMENTS" "$S_CEPOCH" && S_SIGCOMMIT_STALE=1
      fi
      S_SIGCOMMIT_TRUSTED=0
      [ "$S_SIGCOMMIT" = "1" ] && [ "$S_SIGCOMMIT_STALE" != "1" ] && S_SIGCOMMIT_TRUSTED=1
      # Signal C — branch ancestor of origin/main (marker branch label, else crew/*/<id>).
      if [ "$S_SIGCOMMIT_TRUSTED" = "0" ] && [ "$S_SIGMK" = "0" ]; then
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
                       "$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE")
    S_VERDICT="${S_VERDICT_LINE%%:*}"; S_REASON="${S_VERDICT_LINE#*:}"

    if [ "$S_VERDICT" = "done" ]; then
      S_EVID="$S_REASON"
      [ -n "$S_COMMIT_EVID" ] && S_EVID="$S_EVID [$S_COMMIT_EVID]"
      [ -n "$S_BRANCH_EVID" ] && S_EVID="$S_EVID [$S_BRANCH_EVID]"
      [ "$S_SIGMK" = "1" ] && S_EVID="$S_EVID [terminal-marker]"
      if [ "$DRY_RUN" = "1" ]; then
        log "WOULD-DONE $SID ($RNAME) — $S_EVID — \"$STITLE\""
        log "WOULD-DONE: story:done added, story:approved removed, story:in-flight removed, bead closed (delivery close_reason → painel Done)"
      else
        # Drive to the durable terminal — mirrors story-delivery (ga-i53ua):
        #   1. add story:done          (terminal label)
        #   2. remove story:approved   (exits Aprovadas query; safe even if close fails)
        #   3. remove story:in-flight  (defensive cleanup)
        #   4. close with delivery reason → painel routes closed bead to Done
        #      (_closed_bead_belongs_in_done/_is_delivery_close: "merged" triggers Done)
        # story-delivery.sh L886 explicitly delegates this close to the janitor:
        #   "merged-bead-janitor backstops the close".
        # All steps || true — idempotent.
        bd -C "$RPATH" label add "$SID" "story:done" -q 2>/dev/null || true
        bd -C "$RPATH" label remove "$SID" "story:approved" -q 2>/dev/null || true
        bd -C "$RPATH" label remove "$SID" "story:in-flight" -q 2>/dev/null || true
        JCLOSE_MSG="merged-bead-janitor ($SOURCE_BEAD): code merged to origin/main — $S_EVID. Gate→delivery→done did not complete (cross-store, superseded path, rig-store delivery blind spot, or delivery crash); janitor drives durable terminal: story:done added, story:approved removed, bead closed. Mirrors story-delivery ga-i53ua."
        if bd -C "$RPATH" close "$SID" -r "$JCLOSE_MSG" 2>/dev/null; then
          log "DONE $SID ($RNAME) — $S_EVID"
          bd -C "$RPATH" comment "$SID" "merged-bead-janitor ($SOURCE_BEAD, ga-gosfs story:done reconciliation): code is in origin/main — $S_EVID — but the story was stranded story:approved (gate→delivery→done did not complete: cross-store gate:passed, superseded path, rig-store delivery never scanned, or a delivery crash). Driven to durable terminal: story:done added, story:approved removed (exits Aprovadas), bead closed (painel Done via delivery close_reason). Mirrors story-delivery ga-i53ua." 2>/dev/null || true
          DONE_COUNT=$((DONE_COUNT+1))
          DONE_SUMMARY+=("$SID ($RNAME): $S_EVID")
        else
          err "story close failed for $SID ($RNAME)"
          DONE_COUNT=$((DONE_COUNT+1))
          DONE_SUMMARY+=("$SID ($RNAME): $S_EVID [close-failed-but-story:approved-removed]")
        fi
      fi
    else
      S_KEEP_MSG="keep-story $SID ($RNAME) — $S_REASON"
      [ -n "$S_COMMIT_EVID" ] && S_KEEP_MSG="$S_KEEP_MSG [$S_COMMIT_EVID]"
      log "$S_KEEP_MSG"
      # Orphan-close backstop: a bead that already has story:done (from a prior
      # janitor pass) but was never closed — the close step was missing until this
      # fix. The bead keeps appearing in Aprovadas because:
      #   • The story:approved label was NOT removed (prior janitor left it).
      #   • The status is still "open" (prior janitor did not close it).
      # Close + remove story:approved now to complete the durable terminal.
      # Guard: skip epics and delivery-active beads (delivery owns the terminal).
      if [ "$S_REASON" = "already-story-done" ] && [ "$S_EPIC" = "0" ] \
         && [ "$S_DELIV" = "0" ] && [ "$DRY_RUN" != "1" ]; then
        bd -C "$RPATH" label remove "$SID" "story:approved"  -q 2>/dev/null || true
        bd -C "$RPATH" label remove "$SID" "story:in-flight" -q 2>/dev/null || true
        JORPHAN_MSG="merged-bead-janitor ($SOURCE_BEAD): orphan-close — story:done label was set by a prior janitor pass but the bead was never closed (story:approved not removed). Completing the durable terminal: story:approved removed, bead closed. Mirrors story-delivery ga-i53ua. wa-7nz9l/wa-14w76 shape."
        bd -C "$RPATH" close "$SID" -r "$JORPHAN_MSG" 2>/dev/null \
          && log "ORPHAN-CLOSED $SID ($RNAME) — already had story:done, closing now" \
          || warn "orphan-close failed for $SID ($RNAME) (non-fatal; story:approved already removed)"
      fi
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

  # ── branch-prune sweep (ga-tijv5 extension) — OPT-IN, default OFF ────────────
  # Prune crew branches (crew/<persona>/<id>) whose CONTENT is fully in
  # origin/<default> — either ahead==0 (strict ancestor) OR squash/re-committed
  # (content_in_main: ahead>0 by sha but every patch already in main, the wa-fvxj1
  # class) — whose bead is closed/gone, with no live worktree, past the freshness
  # grace. NEVER prunes a branch with a unique patch NOT in main. Every real
  # deletion RE-VERIFIES content-in-main immediately before `push --delete` (a
  # destructive, outward-facing op), and is capped per sweep.
  if [ "$PRUNE_BRANCHES" = "1" ]; then
    CREW_BRANCHES=$(git_in "$RGITDIR" "$RCONTAINER" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/crew/**' 2>/dev/null | sed 's#^origin/##' || true)
    NCREW=$(printf '%s' "$CREW_BRANCHES" | grep -c . 2>/dev/null || echo 0)
    [ "$NCREW" = "0" ] || log "rig $RNAME ($RPREFIX): $NCREW crew branch(es) to check for merged-branch prune"
    # Crew branches currently checked out in a local worktree (never delete these).
    WT_CREW=$(git_in "$RGITDIR" "$RCONTAINER" worktree list --porcelain 2>/dev/null | awk '/^branch refs\/heads\/crew\//{sub("branch refs/heads/","");print}' || true)
    while IFS= read -r cb; do
      [ -z "$cb" ] && continue
      # Per-sweep cap (real runs only; dry-run stays unbounded for auditing).
      if [ "$DRY_RUN" != "1" ] && [ "$BRANCH_PRUNE_COUNT" -ge "$BRANCH_PRUNE_MAX_PER_SWEEP" ]; then
        log "branch-prune: per-sweep cap $BRANCH_PRUNE_MAX_PER_SWEEP reached — deferring remaining to next sweep"
        break
      fi
      AHEAD=$(git_in "$RGITDIR" "$RCONTAINER" rev-list --count "origin/$RDEFAULT..origin/$cb" 2>/dev/null || echo "ERR")
      LWT=0; printf '%s\n' "$WT_CREW" | grep -Fxq "$cb" && LWT=1
      FRESH=$(branch_is_fresh "$RGITDIR" "$RCONTAINER" "origin/$cb" "$BRANCH_FRESH_DAYS")
      # CONTENT-IN-MAIN (squash-aware merge test). ahead==0 is the cheap fast-path
      # (strict ancestor ⟹ trivially content-in-main, no extra git call). Otherwise
      # a branch with ahead>0 may still be a squash / re-commit whose patches are all
      # in main (the wa-fvxj1 class) — verify by patch-id equivalence, but ONLY for a
      # branch that is otherwise prunable (no live worktree, not fresh, readable
      # ahead) so the (bounded) cherry-pick cost is never paid for a kept branch.
      CIM=0
      if [ "$AHEAD" = "0" ]; then
        CIM=1
      elif [ "$AHEAD" != "ERR" ] && [ "$LWT" = "0" ] && [ "$FRESH" = "0" ]; then
        content_in_main "$RGITDIR" "$RCONTAINER" "origin/$cb" "origin/$RDEFAULT" && CIM=1
      fi
      # Only pay the Dolt read when the branch could actually be pruned
      # (content-in-main, not fresh, no live worktree). Otherwise the decider KEEPs
      # on a cheaper guard before it ever consults the bead state.
      BSTATE="active"; BID="${cb##*/}"
      if [ "$LWT" = "0" ] && [ "$CIM" = "1" ] && [ "$FRESH" = "0" ]; then
        BSTATE=$(resolve_bead_state "$RPATH" "$BID")
        # Suffix convention: crew/<persona>/<id>-<slug> (e.g. ga-kpaym-hardening)
        # → the bead is the <prefix>-<token> head (ga-kpaym). Only fall back when
        # the full segment was cleanly gone (never override a found/readerror).
        if [ "$BSTATE" = "gone" ]; then
          PREF=$(printf '%s' "$BID" | awk -F- '{if(NF>=2)print $1"-"$2; else print $0}')
          if [ "$PREF" != "$BID" ]; then
            P2=$(resolve_bead_state "$RPATH" "$PREF")
            [ "$P2" != "gone" ] && { BSTATE="$P2"; BID="$PREF"; }
          fi
        fi
      fi
      BV=$(janitor_branch_decide "$AHEAD" "$CIM" "$BSTATE" "$LWT" "$FRESH")
      BVERD="${BV%%:*}"; BREASON="${BV#*:}"
      if [ "$BVERD" = "prune" ]; then
        # RE-VERIFY content still fully in main at delete time — the remote may have
        # advanced since the decision. Uses the SAME squash-aware patch-equivalence
        # check (covers both strict-ancestor and squash/re-commit); any unique patch
        # now present → abort (fail-closed). A strict ahead recheck alone would
        # WRONGLY abort every legitimate squash prune (those have ahead>0 by sha).
        if ! content_in_main "$RGITDIR" "$RCONTAINER" "origin/$cb" "origin/$RDEFAULT"; then
          RECHECK=$(git_in "$RGITDIR" "$RCONTAINER" rev-list --count --cherry-pick --right-only "origin/$RDEFAULT...origin/$cb" 2>/dev/null || echo "ERR")
          log "branch-prune SKIP origin/$cb ($RNAME) — recheck content-in-main failed (cherry-ahead=$RECHECK, changed since decision)"; continue
        fi
        if [ "$DRY_RUN" = "1" ]; then
          log "WOULD-PRUNE-BRANCH origin/$cb ($RNAME) — $BREASON [bead=$BID state=$BSTATE ahead=$AHEAD cim=$CIM]"
          BRANCH_PRUNE_COUNT=$((BRANCH_PRUNE_COUNT+1))
          BRANCH_PRUNE_SUMMARY+=("$cb ($RNAME): $BREASON")
        else
          # AUTHORITATIVE delete-time guard (compare-and-swap approximation). git
          # has no --force-with-lease for deletes, so before removing an
          # outward-facing ref we confirm via ls-remote that the remote branch
          # STILL exists and STILL points at the exact SHA our (pruned) tracking
          # ref recorded. If it is gone → already deleted (skip). If it moved →
          # the branch was advanced or deleted-then-recreated with new work since
          # we judged it merged → SKIP (never delete on a mismatch). This closes
          # the stale-tracking-ref / re-create race for the destructive op.
          REMOTE_SHA=$(git_in "$RGITDIR" "$RCONTAINER" ls-remote origin "refs/heads/$cb" 2>/dev/null | awk 'NR==1{print $1}')
          LOCAL_SHA=$(git_in "$RGITDIR" "$RCONTAINER" rev-parse "origin/$cb" 2>/dev/null || echo "")
          if [ -z "$REMOTE_SHA" ]; then
            log "branch-prune SKIP origin/$cb ($RNAME) — no longer on remote (already gone)"
            git_in "$RGITDIR" "$RCONTAINER" update-ref -d "refs/remotes/origin/$cb" 2>/dev/null || true
            continue
          fi
          if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
            log "branch-prune SKIP origin/$cb ($RNAME) — remote moved since decision (remote=${REMOTE_SHA:0:9} local=${LOCAL_SHA:0:9})"; continue
          fi
          if git_in "$RGITDIR" "$RCONTAINER" push origin --delete "$cb" >/dev/null 2>&1; then
            git_in "$RGITDIR" "$RCONTAINER" update-ref -d "refs/remotes/origin/$cb" 2>/dev/null || true
            log "PRUNED-BRANCH origin/$cb ($RNAME) — $BREASON [bead=$BID state=$BSTATE ahead=$AHEAD cim=$CIM sha=${REMOTE_SHA:0:9}]"
            BRANCH_PRUNE_COUNT=$((BRANCH_PRUNE_COUNT+1))
            BRANCH_PRUNE_SUMMARY+=("$cb ($RNAME): $BREASON")
          else
            err "branch-prune push --delete failed for origin/$cb ($RNAME) — kept"; continue
          fi
        fi
      elif [ "${JANITOR_BRANCH_VERBOSE:-0}" = "1" ]; then
        log "keep-branch origin/$cb ($RNAME) — $BREASON [ahead=$AHEAD fresh=$FRESH wt=$LWT bead=$BSTATE]"
      fi
    done <<EOF
$CREW_BRANCHES
EOF
  fi
done <<EOF
$RIG_ROWS
EOF

log "=== merged-bead-janitor sweep complete — closed=$CLOSED_COUNT inflight_closed=$INFLIGHT_CLOSED_COUNT story_done=$DONE_COUNT convoy_reaped=$CONVOY_COUNT branches_pruned=$BRANCH_PRUNE_COUNT advisories=$SIBLING_ADVISORIES dry_run=$DRY_RUN ==="
if [ "$DRY_RUN" = "0" ]; then
  if [ "$CLOSED_COUNT" -gt 0 ]; then
    SUMMARY=$(printf '%s; ' "${CLOSED_SUMMARY[@]}")
    notify_athos -t "Kanban janitor" "Auto-closed $CLOSED_COUNT merged-but-stuck bead(s): $SUMMARY"
  fi
  if [ "$INFLIGHT_CLOSED_COUNT" -gt 0 ]; then
    ISUMMARY=$(printf '%s; ' "${INFLIGHT_CLOSED_SUMMARY[@]}")
    notify_athos -t "Kanban janitor" "Auto-closed $INFLIGHT_CLOSED_COUNT stranded open+story:in-flight bead(s) (ga-hcj4, Pilot sling-wrapper gap): $ISUMMARY"
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
  if [ "$BRANCH_PRUNE_COUNT" -gt 0 ]; then
    # The first real run may prune a large merged-branch backlog — cap the message.
    BSAMPLE=$(printf '%s; ' "${BRANCH_PRUNE_SUMMARY[@]:0:8}")
    [ "$BRANCH_PRUNE_COUNT" -gt 8 ] && BSAMPLE="$BSAMPLE…(+$((BRANCH_PRUNE_COUNT-8)) more)"
    notify_athos -t "Kanban janitor" "Pruned $BRANCH_PRUNE_COUNT fully-merged crew branch(es): $BSAMPLE"
  fi
fi
exit 0
