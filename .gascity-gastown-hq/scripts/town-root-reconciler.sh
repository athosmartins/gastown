#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# town-root-reconciler.sh  (ga-857v / propagation family — ga-iwv0, ga-84rm, ga-y3tx)
#
# PURPOSE — close the origin→live split-brain on the Gas City town root.
#
# The launchd dispatchers (quality-gate-dispatcher.sh, pilot-dispatcher.sh,
# story-delivery.sh, the guard, config-drift-watcher) run the framework scripts
# IN PLACE from /Users/athos/gt's working tree. When the autonomous gate merges a
# framework fix to origin/main, nothing pulls that merge down to the live root —
# so origin advances while the live dispatchers keep running the OLD code. The
# gascity delivery deploy_cmd attempts a best-effort `pull --ff-only ... || true`
# but only on a gascity-story delivery, swallows all errors, and never reloads.
#
# This reconciler makes propagation durable + observable:
#   • polls origin every RECONCILE_INTERVAL seconds
#   • if local main is strictly BEHIND origin/main and FAST-FORWARDABLE, it runs
#     `git pull --ff-only origin main` then `gc reload --soft` (NEVER hard — no
#     crew drain) so the next dispatcher tick uses the new code.
#   • if the local tree has DIVERGED (unpushed local commits or a non-FF), it
#     does NOT touch anything (no force, no reset) — it logs LOUDLY and fires a
#     single throttled ntfy so a human/Mayor reconciles deliberately. This is the
#     stop-if-risky guard: a new split-brain is surfaced, never silently forced.
#
# INVARIANTS (must hold forever):
#   • FF-ONLY. Never `reset --hard`, never force, never discard local commits.
#   • SOFT reload only. Never `gc reload --hard` — that drains live crew.
#   • Stays on main. Never checks out another branch (the post-checkout auto-
#     revert hook only fires on branch checkout; we never trigger it).
#   • Idempotent: a no-op when already up to date.
#
# INTERIM HARDENING (ga-84rm — config-drift drain near-miss; Mayor decision
# 2026-06-05):  A gate-merge / skill-publish that bumps config_revision races the
# session reconciler's ~30s tick. If a drain decision lands in the gap before
# this reconciler's soft-reload accepts the new config, externally-attached /
# pinned crew (Oracle, Mila, batista-*) receive a real `outcome=drain` decision
# (Oracle + Mila near-drained 2026-06-05). To SHRINK that race window we:
#   (a) do a SYNCHRONOUS `gc reload --soft` after an FF pull — block until the
#       reload is applied so drift is accepted before any reconciler tick can
#       act — instead of fire-and-forget `--soft --async`; and
#   (b) poll faster than the reconciler tick (RECONCILE_INTERVAL < 30s).
# This is a BAND-AID, NOT the durable fix. The durable fix is an ENGINE-level
# attached/pinned/recently-active guard in the COMPILED gascity binary (not on
# disk here; gascity v1.2.1 does NOT contain it — verified). ga-84rm stays OPEN;
# this change does not close it and must not be called "durable".
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# Defaults are the live town root; all four are env-overridable so the selftest
# harness can point the reconcile_* helpers at a throwaway repo + temp log
# without touching the live root (defaults are unchanged in production).
ROOT="${ROOT:-/Users/athos/gt}"
CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="${LOG_DIR:-$CITY/.gc/logs}"
LOG="${LOG:-$LOG_DIR/town-root-reconciler.log}"
GC="${GC:-gc}"
REMOTE="${RECONCILE_REMOTE:-origin}"
BRANCH="${RECONCILE_BRANCH:-main}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-25}"   # seconds between polls (ga-84rm: < ~30s reconciler tick to shrink the config-drift drain race)
DRY_RUN="${DRY_RUN:-0}"

# Keep git from walking above the town root (mirrors crew env per CLAUDE.md).
export GIT_CEILING_DIRECTORIES="$ROOT"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [root-reconciler] $*" | tee -a "$LOG" 2>/dev/null; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [root-reconciler] ERROR: $*" | tee -a "$LOG" 2>/dev/null; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [root-reconciler] WARN: $*"  | tee -a "$LOG" 2>/dev/null; }

# Throttle ntfy so a persistent divergence pings at most once per hour.
NTFY_STAMP="$LOG_DIR/.town-root-reconciler.last-ntfy"
NTFY_THROTTLE_SECONDS=3600
maybe_ntfy() {
  local msg="$1" now last
  now=$(date +%s)
  last=$(cat "$NTFY_STAMP" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge "$NTFY_THROTTLE_SECONDS" ]; then
    notify -t "Gas City: town root diverged" -p 4 "$msg" 2>/dev/null || true
    echo "$now" > "$NTFY_STAMP" 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# reconcile_untracked_for_ffpull  (ga-sejv — fixes ga-sxbs false-divergence)
#
# PROBLEM this fixes: CASE A below is a *pure fast-forward* (local is a strict
# ancestor of origin) — it SHOULD always land cleanly. But `git pull --ff-only`
# still ABORTS when the live working tree holds an UNTRACKED copy of a file that
# the incoming merge adds as TRACKED:
#   "The following untracked working tree files would be overwritten by merge:
#    <file> — Please move or remove them before you merge. Aborting"
# This is exactly how the 13 live scripts collided in ga-sxbs. The old CASE A
# then logged "FF pull failed though it should be a clean FF" and fired the
# divergence ntfy — a FALSE "town root diverged" alarm (Athos screenshot,
# 2026-06-05) on what is really a benign byte-identical duplicate.
#
# This helper mirrors the proven ga-857v reconcile in story-delivery.sh. For each
# untracked file the incoming upstream adds as tracked, it compares working-tree
# bytes against the upstream version:
#   IDENTICAL  → back up to /tmp then remove, so the ff-pull lands the tracked
#                copy. The NEVER-clobber invariant holds: we only delete a
#                proven-identical duplicate, never real content.
#   DIFFERENT  → do NOT touch it; collect into RECONCILE_DIFF_LIST and return 2
#                so the caller STOPS + escalates (uncommitted live work is never
#                destroyed — a genuine divergence on an untracked file).
# Sets globals RECONCILE_DIFF_LIST (space-separated paths that differ) and
# RECONCILE_COUNT (number auto-reconciled). Honours DRY_RUN.
RECONCILE_DIFF_LIST=""
RECONCILE_COUNT=0
reconcile_untracked_for_ffpull() {
  local dir="$1" upstream="$2"
  RECONCILE_DIFF_LIST=""
  RECONCILE_COUNT=0

  [ -n "$dir" ] || { log "reconcile: no dir — skip"; return 0; }
  [ -n "$upstream" ] || { log "reconcile: no upstream — skip"; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log "reconcile: $dir is not a git work tree — skip"; return 0; }

  local conflicts=0 u base ts backup
  # Enumerate untracked (non-ignored) files; -z keeps paths with spaces safe.
  while IFS= read -r -d '' u; do
    [ -n "$u" ] || continue
    # Does the incoming upstream add this path as tracked? If not, leave the
    # genuine local-only file completely alone — it won't block the ff-pull.
    git -C "$dir" cat-file -e "$upstream:$u" 2>/dev/null || continue
    # Collision candidate. Compare working-tree bytes against incoming version.
    if git -C "$dir" show "$upstream:$u" 2>/dev/null | cmp -s - "$dir/$u"; then
      # IDENTICAL → safe to remove so the ff-pull can land the tracked copy.
      base=$(basename "$u")
      ts=$(date +%Y%m%d-%H%M%S)
      backup="/tmp/${base}.backup.${ts}.$$"
      if [ "$DRY_RUN" = "1" ]; then
        log "reconcile: DRY_RUN — WOULD backup+remove identical untracked '$u' (backup $backup)"
      else
        cp -p "$dir/$u" "$backup" 2>/dev/null || cp "$dir/$u" "$backup" 2>/dev/null || true
        rm -f "$dir/$u"
        log "reconcile: auto-reconciled identical untracked '$u' (backup: $backup)"
      fi
      RECONCILE_COUNT=$((RECONCILE_COUNT + 1))
    else
      # GENUINELY DIFFERENT → never clobber. Record for halt + escalation.
      warn "reconcile: CONFLICT — untracked '$u' DIFFERS from incoming $upstream:$u (NOT removed)"
      RECONCILE_DIFF_LIST="$RECONCILE_DIFF_LIST $u"
      conflicts=$((conflicts + 1))
    fi
  done < <(git -C "$dir" ls-files --others --exclude-standard -z 2>/dev/null)

  [ "$conflicts" -gt 0 ] && return 2
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# reconcile_tracked_for_ffpull  (ga-y3tx — fixes tracked IDENTICAL modifications
# blocking FF that ga-sejv missed; gt-yjr20 — adds the ORTHOGONAL-edit case)
#
# PROBLEM: `git pull --ff-only` aborts with "Your local changes to the following
# files would be overwritten by merge" when the live working tree has locally-
# MODIFIED (tracked) files whose content happens to equal the incoming merge —
# e.g. a script edited in-place while the same change merged via the gate.
# ga-sejv fixed the UNTRACKED case only; git checks TRACKED dirty files FIRST,
# so the untracked reconcile never gets a chance and the FF stays jammed.
# Observed live 2026-06-05: story-delivery.sh + delivery-runbooks.toml were
# byte-identical dups that pinned the FF for minutes, firing repeated false
# 'town root diverged' ntfy to Athos.
#
# gt-yjr20 (recurring class): the original code blocked on ANY dirty tracked file
# whose bytes differ from the incoming version — EVEN when the incoming FF does
# not touch that file at all. A single uncommitted crew edit to a tracked file
# (skills/refino/SKILL.md, 2026-06-13) then froze EVERY subsequent UNRELATED
# framework FF until a human committed it. But git only refuses an ff-pull when a
# file the merge actually CHANGES is dirty; an edit to a file the FF leaves alone
# is preserved and the FF still lands. So we must classify by "does the incoming
# FF change this file?" (upstream blob vs HEAD blob), not "does it differ from the
# incoming version?".
#
# For each tracked file where the working tree differs from HEAD:
#   ORTHOGONAL (upstream blob == HEAD blob) → the FF does not touch this file;
#                            the ff-pull preserves the edit and still advances.
#                            Leave it; count ORTHOGONAL_COUNT. NEVER block. This
#                            is the gt-yjr20 fix.
#   IDENTICAL to incoming  → `git checkout -- $path` to restore HEAD copy;
#                            the ff-pull then advances it to the same bytes.
#                            Safe: we only discard a modification that equals
#                            the merge target — nothing is lost.
#   DIFFERENT from incoming (and the FF changes it) → do NOT touch it; collect
#                            into TRACKED_DIFF_LIST and return 2 so the caller
#                            STOPS + escalates. The NEVER-clobber invariant holds.
# Sets globals TRACKED_DIFF_LIST, TRACKED_COUNT, ORTHOGONAL_COUNT. Honours DRY_RUN.
TRACKED_DIFF_LIST=""
TRACKED_COUNT=0
ORTHOGONAL_COUNT=0
reconcile_tracked_for_ffpull() {
  local dir="$1" upstream="$2"
  TRACKED_DIFF_LIST=""
  TRACKED_COUNT=0
  ORTHOGONAL_COUNT=0

  [ -n "$dir" ] || { log "reconcile_tracked: no dir — skip"; return 0; }
  [ -n "$upstream" ] || { log "reconcile_tracked: no upstream — skip"; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log "reconcile_tracked: $dir is not a git work tree — skip"; return 0; }

  local conflicts=0 u up_blob head_blob
  # Enumerate tracked files where working tree differs from HEAD; -z for safety.
  while IFS= read -r -d '' u; do
    [ -n "$u" ] || continue
    # Resolve the incoming blob id for this path. If deleted upstream, leave it —
    # a tracked→deleted transition is not our concern here.
    up_blob=$(git -C "$dir" rev-parse --quiet --verify "$upstream:$u" 2>/dev/null || echo "")
    [ -n "$up_blob" ] || continue
    head_blob=$(git -C "$dir" rev-parse --quiet --verify "HEAD:$u" 2>/dev/null || echo "")
    # gt-yjr20 — ORTHOGONAL EDIT: the incoming FF does NOT modify this file
    # (upstream blob == HEAD blob). The dirty working-tree edit is unrelated to the
    # merge, so `git pull --ff-only` leaves it untouched and STILL advances. Blocking
    # here was the recurring jam: a single uncommitted crew edit to a tracked file
    # (e.g. skills/refino/SKILL.md) froze EVERY subsequent unrelated framework FF
    # until a human resolved it. Preserve the edit; do NOT block. (If a later FF
    # actually touches this file, upstream≠HEAD and we fall through to the real
    # conflict check below — never clobbering genuine divergent work.)
    if [ -n "$head_blob" ] && [ "$head_blob" = "$up_blob" ]; then
      log "reconcile_tracked: orthogonal local edit '$u' preserved (incoming $upstream does not modify it; ff-pull keeps the edit and still advances)"
      ORTHOGONAL_COUNT=$((ORTHOGONAL_COUNT + 1))
      continue
    fi
    # The incoming FF DOES change this file. Compare working-tree bytes vs incoming.
    if git -C "$dir" show "$upstream:$u" 2>/dev/null | cmp -s - "$dir/$u"; then
      # IDENTICAL → restore HEAD copy so git pull can advance it cleanly.
      # The FF pull will land the same bytes regardless; nothing is lost.
      if [ "$DRY_RUN" = "1" ]; then
        log "reconcile_tracked: DRY_RUN — WOULD restore HEAD copy of identical tracked '$u'"
      else
        git -C "$dir" checkout -- "$u"
        log "reconcile_tracked: auto-reconciled identical tracked '$u' (restored to HEAD; ff-pull advances to same bytes)"
      fi
      TRACKED_COUNT=$((TRACKED_COUNT + 1))
    else
      # GENUINELY DIFFERENT → never discard. Record for halt + escalation.
      warn "reconcile_tracked: CONFLICT — tracked '$u' DIFFERS from incoming $upstream:$u (NOT restored)"
      TRACKED_DIFF_LIST="$TRACKED_DIFF_LIST $u"
      conflicts=$((conflicts + 1))
    fi
  done < <(git -C "$dir" diff -z --name-only HEAD 2>/dev/null)

  [ "$conflicts" -gt 0 ] && return 2
  return 0
}

reconcile_once() {
  # Sanity: real git work tree.
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    err "$ROOT is not a git work tree — skip"; return 0; }

  # Must be ON the branch we reconcile (never switch branches ourselves).
  local cur
  cur=$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$cur" != "$BRANCH" ]; then
    err "town root is on '$cur', not '$BRANCH' — NOT switching (post-checkout hook owns that). Skipping."
    maybe_ntfy "town root on '$cur' not '$BRANCH'; reconciler standing down until back on $BRANCH."
    return 0
  fi

  # Refresh remote refs (network best-effort — a failed fetch is not fatal).
  git -C "$ROOT" fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null || {
    log "fetch $REMOTE $BRANCH failed (transient) — will retry next tick"; return 0; }

  local local_sha remote_sha base
  local_sha=$(git -C "$ROOT" rev-parse "$BRANCH" 2>/dev/null || echo "")
  remote_sha=$(git -C "$ROOT" rev-parse "$REMOTE/$BRANCH" 2>/dev/null || echo "")
  [ -n "$local_sha" ] && [ -n "$remote_sha" ] || { err "could not resolve SHAs"; return 0; }

  # Already in sync → no-op (idempotent).
  if [ "$local_sha" = "$remote_sha" ]; then
    return 0
  fi

  base=$(git -C "$ROOT" merge-base "$BRANCH" "$REMOTE/$BRANCH" 2>/dev/null || echo "")

  # CASE A: local is an ANCESTOR of remote → pure fast-forward. Safe to pull.
  if [ "$base" = "$local_sha" ]; then
    local behind
    behind=$(git -C "$ROOT" rev-list --count "$BRANCH..$REMOTE/$BRANCH" 2>/dev/null || echo "?")
    log "town root BEHIND $REMOTE/$BRANCH by $behind commit(s) — fast-forwarding live root."

    # ga-y3tx: clear byte-identical TRACKED modifications BEFORE the ff-pull (and
    # before the untracked reconcile, because git checks tracked dirty files first).
    # This is a pure FF, so any tracked file whose working-tree bytes equal the
    # incoming content is a benign in-place duplicate — safe to restore to HEAD so
    # the ff-pull can advance it cleanly. A genuinely DIFFERENT tracked modification
    # returns 2 → STOP + escalate (never clobber — real local work is never lost).
    if ! reconcile_tracked_for_ffpull "$ROOT" "$REMOTE/$BRANCH"; then
      err "town root FF blocked: tracked modification(s) DIFFER from incoming $REMOTE/$BRANCH (NOT clobbered):$TRACKED_DIFF_LIST"
      maybe_ntfy "Gas City town root: tracked file(s) differ from incoming $REMOTE/$BRANCH —$TRACKED_DIFF_LIST. NOT overwritten; needs deliberate human/Mayor resolve."
      return 0
    fi
    [ "$TRACKED_COUNT" -gt 0 ] && log "reconciled $TRACKED_COUNT byte-identical tracked modification(s) — ff-pull can now land cleanly."
    [ "${ORTHOGONAL_COUNT:-0}" -gt 0 ] && log "preserved $ORTHOGONAL_COUNT orthogonal local edit(s) the incoming FF does not touch (gt-yjr20) — ff-pull keeps them and still advances."

    # ga-sejv: clear byte-identical untracked collisions BEFORE the ff-pull. This
    # is a pure FF (local is an ancestor), so it SHOULD land — but an untracked
    # working-tree copy of a file the merge adds as tracked makes git abort the
    # pull. The old code then fired a FALSE "diverged" ntfy on a benign duplicate
    # (the ga-sxbs pattern). reconcile_untracked_for_ffpull backs up + removes only
    # PROVEN-identical duplicates; a genuinely DIFFERENT untracked file returns 2
    # → we STOP + escalate (never clobber), which is a real conflict, not a clean FF.
    if ! reconcile_untracked_for_ffpull "$ROOT" "$REMOTE/$BRANCH"; then
      err "town root FF blocked: untracked working-tree file(s) DIFFER from incoming $REMOTE/$BRANCH (NOT clobbered):$RECONCILE_DIFF_LIST"
      maybe_ntfy "Gas City town root: untracked file(s) differ from incoming $REMOTE/$BRANCH —$RECONCILE_DIFF_LIST. NOT overwritten; needs deliberate human/Mayor resolve before the FF can land."
      return 0
    fi
    [ "$RECONCILE_COUNT" -gt 0 ] && log "reconciled $RECONCILE_COUNT byte-identical untracked collision(s) — ff-pull can now land the tracked version(s)."

    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN=1 — WOULD: git pull --ff-only $REMOTE $BRANCH ; gc reload --soft (sync)"
      return 0
    fi
    if git -C "$ROOT" pull --ff-only "$REMOTE" "$BRANCH" >>"$LOG" 2>&1; then
      log "FF pull OK — now at $(git -C "$ROOT" rev-parse --short "$BRANCH"). Soft-reloading crew config (no drain)."
      # ga-84rm INTERIM: SYNCHRONOUS soft reload (drop --async). Soft never drains
      # live sessions (config-drift-watcher doctrine); blocking until the reload is
      # applied means config drift is ACCEPTED before the session reconciler's
      # ~30s tick can issue a drain against externally-attached/pinned crew. The
      # extra wall-time (seconds) is the cost of closing the drain race window.
      "$GC" reload --soft --city "$CITY" >>"$LOG" 2>&1 \
        && log "gc reload --soft (sync) applied — drift accepted; live dispatchers pick up new code next tick." \
        || err "gc reload --soft (sync) failed (files updated on disk regardless; dispatchers still get new code next tick)."
    else
      # After tracked+untracked reconcile, a still-failing FF is the RARE real
      # case (a raced-in collision, staged index changes, or a genuinely dirty
      # file that arrived between reconcile and pull). Surface it; do not force.
      err "FF pull FAILED after tracked+untracked reconcile — investigate (raced collision? staged index changes?)."
      maybe_ntfy "town root FF pull failed even after tracked+untracked reconcile — manual check needed."
    fi
    return 0
  fi

  # CASE B: remote is an ANCESTOR of local → local is AHEAD (unpushed commits).
  # Not our job to push; leave it. (story-delivery / gate push framework merges.)
  if [ "$base" = "$remote_sha" ]; then
    local ahead
    ahead=$(git -C "$ROOT" rev-list --count "$REMOTE/$BRANCH..$BRANCH" 2>/dev/null || echo "?")
    log "town root AHEAD of $REMOTE/$BRANCH by $ahead unpushed commit(s) — nothing to pull. (push is owned by the gate/delivery, not this reconciler.)"
    return 0
  fi

  # CASE C: TRUE DIVERGENCE — both sides have unique commits. STOP. Never force.
  err "town root DIVERGED from $REMOTE/$BRANCH (local=$local_sha remote=$remote_sha base=$base). NOT forcing — needs deliberate reconcile (the exact split-brain this guard watches for)."
  maybe_ntfy "Gas City town root diverged from $REMOTE/$BRANCH — autonomous reconcile blocked, needs a human/Mayor rebase. Framework fixes may be dormant."
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Library-source guard. The selftest harness sources this file with
# TOWN_ROOT_RECONCILER_LIB=1 to exercise the pure reconcile_* helpers against a
# throwaway repo, WITHOUT launching the daemon loop or touching the live root.
# Returns when sourced (the normal launchd exec never sets the var, so the daemon
# starts as before).
if [ "${TOWN_ROOT_RECONCILER_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

log "town-root-reconciler started (root=$ROOT remote=$REMOTE branch=$BRANCH interval=${RECONCILE_INTERVAL}s dry_run=$DRY_RUN)"

# Startup marker for delivery freshness verification (ga-fbjg).
# Prod-test reads this to confirm the live process was restarted, not merely
# that the script file changed on disk.
STATE_DIR="$CITY/.gc/state"
mkdir -p "$STATE_DIR"
printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/town-root-reconciler.startup"

# Single-shot mode for tests / manual runs: RECONCILE_ONCE=1
if [ "${RECONCILE_ONCE:-0}" = "1" ]; then
  reconcile_once
  exit 0
fi

while true; do
  reconcile_once
  sleep "$RECONCILE_INTERVAL"
done
