#!/usr/bin/env bash
# lifecycle-coherence-janitor.sh — normalize INCOHERENT bead lifecycle state across stores.
#
# Born 2026-06-22: the painel's "Em Execução" column repeatedly showed phantom cards because
# a bead's STATUS and its story:* lifecycle LABEL drifted out of sync, and nothing reconciled
# them. Three recurring incoherences, each user-visible on the Kanban:
#   R1  status=closed   + label story:in-flight  → vestigial: `bd close` does NOT strip the
#       lifecycle label, so a DONE bead keeps story:in-flight and renders in Em Execução.
#   R2  status=blocked  + label story:in-flight  → leak: a blocked/design-first bead carries
#       the execution label and renders as actively executing.
#   R3  status=in_progress + assignee EMPTY      → a released/un-claimed bead whose status was
#       never reset (assignee cleared but status left in_progress) → renders as a live worker
#       with no one building it (the painel keys Em Execução on status=in_progress).
#
# The janitor ONLY touches PROVABLY-incoherent beads (a terminal/blocked status with an
# execution label, or in_progress with NO worker). A genuinely-building bead (in_progress +
# a live assignee) is NEVER touched — that is the Pilot's owner-grace / never-started domain.
# FAIL-OPEN: any bd/jq error skips that bead; the sweep never aborts. Idempotent. Knobs:
# LCJ_STORES, LCJ_DRY_RUN=1 (report only), LCJ_ENABLED=0 (off). Test seam: LCJ_BD.
#
# ga-ibz0 (2026-07-11): R3/R7 additionally exclude any bead with an active/pending gate
# marker (gate-status:ready|dispatching|queued|claimed) — see _gate_active_beads below.
# quality-gate-guard.sh silently detaches a bead's assignee for the FULL gate duration
# (no bd comment), and a marker can sit queued for a long time; without this exclusion R3
# reopens such a bead the instant it crosses the 30min staleness threshold — a SILENT
# status/assignee revert on a bead that is still actively/pending gated (confirmed live on
# wa-bkjy7 2026-07-11, and via quality-gate-guard.log on ga-ibz0's original wa-ntakm/wa-2mxsb).
#
# ga-6plfv/ga-u8e55 (2026-07-18): R4 and R5 were surgically disabled 2026-07-09
# (MAYOR-DISABLED markers) after R4 cleared LIVE builders' assignees (duplicate
# work) and R5 stamped story:done on active, not-actually-done beads. The stated
# re-enable condition was DUAL: (a) wa-muesb merges, AND (b) R4/R5 gain a real
# session-liveness/merge check. The script was reverted 2026-07-17 with (a) true
# but (b) never implemented — R4 ran for a full day clearing live crews' assignees
# every ~15min sweep (102 firings) before this fix landed. Lesson operationalized
# here, not just noted: (b) is now actual code (_provably_dead(), R4's live-assignee
# selftest fixtures below) rather than a bead comment a future re-enable could miss
# — the check IS the precondition, it can't silently regress without failing
# --selftest. R5 gained a narrower, zero-git-risk partial fix (AC3: skip beads
# still carrying gate:failed/gate:needs-fix — the exact wa-g1b58 failure shape);
# full git-ancestry merge verification was assessed and deferred (see follow-up
# bead) because this codebase's rig-repo topology is genuinely inconsistent
# across HQ/whatsapp_automation/property_scrapers (see rig-repo-topology in
# project memory) and a rushed generic implementation risks a NEW false-verdict
# class, not just leaving the known one unfixed.
#
# KNOWN GAP left open by ga-6plfv (AC2, documented per that bug's own "or
# documented" clause rather than built): queued-but-not-yet-started work (the
# 2nd/3rd/4th bead in a crew's queue) has no lifecycle state that survives BOTH
# R4 and inflight-reclaim-guard.py. Without story:in-flight, R4 clears the
# assignee in ~1 sweep (now gated on liveness, but a live crew's QUEUED-not-yet-
# started bead has no in-flight signal to protect it either way). With
# story:in-flight, inflight-reclaim-guard.py's RECLAIM_TTL takes the bead back
# after ~25min of no branch progress. A crew can only "hold" the ONE bead it is
# actively building right now — there is no representable "mine, next in queue"
# state. Fixing this needs coordinated change across this janitor AND
# inflight-reclaim-guard.py AND however Pilot enqueues multi-bead dispatches to
# one crew — out of scope for a single dispatch; a design bead should own it if/
# when queued-dispatch becomes load-bearing.
set -uo pipefail

LCJ_STORES="${LCJ_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
LCJ_DRY_RUN="${LCJ_DRY_RUN:-0}"
LCJ_ENABLED="${LCJ_ENABLED:-1}"
BD="${LCJ_BD:-bd}"
GC="${LCJ_GC:-gc}"
LCJ_GIT="${LCJ_GIT:-git}"
LOG="${LCJ_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/lifecycle-coherence-janitor.log}"
LCJ_NOTIFY="${LCJ_NOTIFY:-/Users/athos/.local/bin/notify}"
# ga-hn34 (2026-07-14): cancellation/obsolescence keyword regex tested against a closed
# bead's close_reason by R1/R5 below. Nothing enforces stamping story:cancelled AT
# close-time — there is no dedicated cancel path anywhere; cancellation today is just a
# plain `bd close -r "<prose reason>"`. Without this, a closed bead that still carries an
# active lifecycle label falls through to R1/R5's default of story:done, silently
# converting an intentional cancellation into a fake completion (confirmed live: wa-flba
# + 4 siblings, data-fixed under ga-9pj4). Mirrors LCA_SUPPRESS_RE, added to
# lifecycle-correctness-auditor.sh by that same bug — that fix suppresses a downstream
# FALSE-CLOSE warning; this one fixes the mislabeling at its source instead.
LCJ_CANCEL_RE="${LCJ_CANCEL_RE:-obsolet[oa]|obsolete|cancelad[oa]|cancell?ed|descomission|decommission|discontinu|deprecat}"
# imp10: per-bead lifecycle advisory lock. Any process that will mutate lifecycle labels
# on a specific bead should create $LIFECYCLE_LOCK_DIR/<bead-id> (containing "pid:epoch")
# with a TTL of LIFECYCLE_LOCK_TTL seconds. The janitor skips any bead with a fresh lock,
# preventing concurrent writes from racing. Sweep-level flock prevents concurrent janitor
# sweeps from starting.
LIFECYCLE_LOCK_DIR="${LIFECYCLE_LOCK_DIR:-/tmp/gc-lifecycle-lock}"
LIFECYCLE_LOCK_TTL="${LIFECYCLE_LOCK_TTL:-30}"
LIFECYCLE_SWEEP_LOCK="${LIFECYCLE_LOCK_DIR}/.janitor-sweep.lock"
_bead_locked() {  # bead-id → return 0 if locked (fresh advisory lock exists), 1 otherwise
  local lockfile="$LIFECYCLE_LOCK_DIR/$1"
  [ -f "$lockfile" ] || return 1
  local ts; ts=$(cut -d: -f2 "$lockfile" 2>/dev/null) || return 1
  local now; now=$(date +%s)
  [ "$(( now - ts ))" -lt "$LIFECYCLE_LOCK_TTL" ] && return 0 || return 1
}
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
notify_fail() { "$LCJ_NOTIFY" -t "Lifecycle Coherence Janitor" -p 4 "🚨 $*" 2>/dev/null || true; }

_strip() {  # store id label
  [ "$LCJ_DRY_RUN" = "1" ] && { log "  DRY: would strip $3 from $2"; return 0; }
  "$BD" -C "$1" label remove "$2" "$3" -q >/dev/null 2>&1 || true
}
_open() {   # store id
  [ "$LCJ_DRY_RUN" = "1" ] && { log "  DRY: would set $2 status=open"; return 0; }
  "$BD" -C "$1" update "$2" --status open -q >/dev/null 2>&1 || true
}
_add() {    # store id label
  [ "$LCJ_DRY_RUN" = "1" ] && { log "  DRY: would add $3 to $2"; return 0; }
  "$BD" -C "$1" label add "$2" "$3" -q >/dev/null 2>&1 || true
}
_unassign() {  # store id — clear a stale assignee (R4)
  [ "$LCJ_DRY_RUN" = "1" ] && { log "  DRY: would clear assignee of $2"; return 0; }
  "$BD" -C "$1" update "$2" --assignee "" -q >/dev/null 2>&1 || true
}
_unset_metadata() { # store id key [key2 key3...] — clear routing metadata (R7)
  local store="$1" id="$2"
  shift 2
  local key
  for key in "$@"; do
    [ "$LCJ_DRY_RUN" = "1" ] && { log "  DRY: would unset-metadata $key from $id"; continue; }
    "$BD" -C "$store" update "$id" --unset-metadata "$key" -q >/dev/null 2>&1 || true
  done
}
_close_bead() { # store id notes — close a non-implementable bead's sling/molecule/step (R7)
  [ "$LCJ_DRY_RUN" = "1" ] && { log "  DRY: would close $2 (notes: $3)"; return 0; }
  "$BD" -C "$1" update "$2" --status closed --notes "$3" -q >/dev/null 2>&1 || true
}
_ids() {    # store + list-args → bead ids (one per line), jq-filtered
  "$BD" -C "$1" "${@:2}" --json -n 0 2>/dev/null | jq -r "$JQ" 2>/dev/null
}

# ── Gate-active protection (ga-ibz0 / wa-bkjy7, 2026-07-11) ──────────────────
# quality-gate-guard.sh detaches a bead's assignee the INSTANT /gate-done is
# submitted (Step 5b, ga-e7zk7/gt-gwng6) — silently, no bd comment, status left
# in_progress — on the reasoning that inflight-reclaim-guard.py already excludes
# any gate-active bead from reclaim. True for THAT guard (it queries gate
# markers directly), but R3/R7 below had no equivalent check: a marker can sit
# QUEUED for a long time (quality-gate-guard.sh's own comment: "hours behind
# the single-threaded backlog"), so R3's 30min in_progress-stale-no-assignee
# sweep can fire on a bead that is still actively/pending gated — flipping
# status=open with ZERO comment and ZERO reclaim-count interaction. Confirmed
# LIVE on wa-bkjy7: R3 fired 18:42:28Z, four minutes before the dispatcher even
# claimed the still-queued marker (gate passed clean nine minutes later
# regardless — the danger is the open+unassigned WINDOW, not gate breakage: any
# pool worker/dog querying for ready work during that window sees a false
# vacancy — exactly ga-ibz0's "completed+gated bead → open/assignee:null"
# report, confirmed separately via quality-gate-guard.log on both of its
# original beads, wa-ntakm and wa-2mxsb).
#
# Mirrors inflight-reclaim-guard.py's list_gate_active_source_beads() (ga-cxzby
# "ready" inclusion + ga-lrglm sling back-reference), ported to bash/jq. Gate
# markers always live in the HQ store regardless of which store the source
# bead is native to (mirrors quality-gate-guard.sh's own -C "$GC_CITY" writes).
#
# FAIL-SAFE (deliberately stricter than this file's own FAIL-OPEN mutation
# contract, see file header): a query FAILURE is NOT the same as "zero active
# markers" — conflating them would silently drop gate protection exactly when
# Dolt is under the contention that makes false reclaims most likely (the same
# guard-bug class already fixed twice elsewhere, ga-ap7od/ga-jfo7). On failure
# this returns a sentinel and R3/R7 skip their mutations entirely for the
# sweep rather than proceeding as if nothing were gated.
LCJ_GATE_CITY="${LCJ_GATE_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
_GATE_UNKNOWN_SENTINEL="__GATE_ACTIVE_UNKNOWN__"
_gate_active_beads() {
  local lbl raw ids="" resolved
  for lbl in gate-status:ready gate-status:dispatching gate-status:queued gate-status:claimed; do
    raw=$("$BD" -C "$LCJ_GATE_CITY" list --label type:quality-gate-marker --label "$lbl" --json -n 0 2>/dev/null)
    if [ $? -ne 0 ]; then
      printf '%s' "$_GATE_UNKNOWN_SENTINEL"
      return 0
    fi
    [ -z "$raw" ] && continue
    ids="$ids
$(printf '%s' "$raw" | jq -r '.[]?.labels[]? | select(startswith("source-bead:")) | ltrimstr("source-bead:")' 2>/dev/null)"
  done
  ids=$(printf '%s\n' "$ids" | awk 'NF && !seen[$0]++')
  # ga-lrglm parity: a bug/story dispatched through the standard sling-task
  # wrapper ("fix bug <ID>: ..." / "build story <ID>: ...") has its gate marker
  # keyed on the SLING bead's id, not the original's — resolve the original
  # too. Best-effort: a lookup failure here keeps the directly-active set as-is
  # (never widens the fail-safe contract above — that only applies to the
  # primary marker queries).
  if [ -n "$ids" ]; then
    resolved=$("$BD" -C "$LCJ_GATE_CITY" show $ids --json 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$resolved" ]; then
      ids="$ids
$(printf '%s' "$resolved" | jq -r '
          (if type=="array" then . else [.] end)[]
          | (.title // "")
          | capture("^(?:fix bug|build story)\\s+(?<sid>\\S+):")? | .sid' 2>/dev/null)"
      ids=$(printf '%s\n' "$ids" | awk 'NF && !seen[$0]++')
    fi
  fi
  printf ' %s ' "$(printf '%s' "$ids" | tr '\n' ' ')"
}

# ── Session-liveness for R4 (ga-6plfv/ga-u8e55, 2026-07-18) ──────────────────
# R4 must only clear an assignee when the owning session is PROVABLY dead — not
# merely "doesn't carry an in-flight label" (the bug: R4 was re-enabled
# 2026-07-17 without ever gaining this check, so it ripped live crews'
# assignees every ~15min sweep; see the file header note above and ga-6plfv for
# the full incident). Reuses the canonical claimant_provably_dead() from
# inflight-reclaim-guard.py, via its reclaim_liveness.py re-export (already the
# pattern dog-pool-preflight-reclaim.py uses) — instead of writing a FIFTH
# independent liveness check. This codebase already has four
# (gate-recovery-watchdog.py, quorum-convergence-watchdog.py,
# gatefix-deadworker-recovery.sh, and inflight-reclaim-guard.py's own rails),
# each checking a different subset of identifier fields / dead-state lists and
# silently disagreeing with each other — adding a bash-native fifth here would
# make that worse, not better.
#
# "Provably dead" (not merely "not proven live") is deliberately the STRICTER
# predicate — a session that's present but stale/frozen, or in an unrecognized
# state, is NOT provably dead, so R4 leaves it alone (fail-safe). This matches
# AC1's own wording ("sessao dona... comprovadamente MORTA") and R4's shape: it
# has no hysteresis/TTL (fires every sweep, unlike inflight-reclaim-guard.py's
# RECLAIM_TTL-gated reclaim), so only a CERTAIN verdict should act immediately.
# Side benefit: claimant_provably_dead()'s is_coordinator() check also protects
# "deacon" assignees, a gap R4's own jq prefilter never closed (it only ever
# excluded the literal "mayor").
#
# Sessions are fetched ONCE per sweep (mirrors _gate_active_beads' "computed
# once" pattern above) — one `gc session list` call regardless of how many
# candidate beads R4 walks across all stores.
LCJ_RECLAIM_LIB="${LCJ_RECLAIM_LIB:-/Users/athos/gt/.gascity-gastown-hq/scripts}"
_SESSIONS_JSON=""
_sessions_json() {
  [ -n "$_SESSIONS_JSON" ] && { printf '%s' "$_SESSIONS_JSON"; return 0; }
  _SESSIONS_JSON=$("$GC" session list --json 2>/dev/null)
  [ -n "$_SESSIONS_JSON" ] || _SESSIONS_JSON="{}"
  printf '%s' "$_SESSIONS_JSON"
}
# _provably_dead <assignee> → return 0 if PROVABLY dead, 1 otherwise. Fail-safe:
# an empty assignee, an unreadable session roster, or a python/import failure
# all resolve to "not provably dead" (1) — R4 leaves the bead alone rather than
# risk clearing a live claim on a diagnostic hiccup.
_provably_dead() {
  local assignee="$1"
  [ -n "$assignee" ] || return 1
  _sessions_json | python3 -c '
import sys, json
sys.path.insert(0, "'"$LCJ_RECLAIM_LIB"'")
try:
    import reclaim_liveness as rl
except Exception:
    sys.exit(1)
assignee = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sessions = d.get("sessions", []) if isinstance(d, dict) else (d or [])
sys.exit(0 if rl.claimant_provably_dead(assignee, sessions) else 1)
' "$assignee" 2>/dev/null
}

# ── AC3 (ga-to242): bead-id → branch(es) resolution + real git-ancestry merge
# verification for R5. R4/R5 were re-enabled 2026-07-17 (ga-6plfv) with R5 only
# partially fixed: it skipped beads still carrying gate:failed/needs-fix at sweep
# time, but a bead closed+relabeled some other way was never checked against git
# at all — "closed" does NOT prove "merged" (same lesson as gate-recovery-
# watchdog.py's orphan_marker_verdict, ga-w5agg/ga-d2jil, and lifecycle-
# correctness-auditor.sh's FALSE-CLOSE check, which independently confirmed the
# identical failure shape live on wa-g1b58).
#
# R5 fires on the SOURCE bead directly — by the time it runs, any gate marker
# that might have recorded a known branch name is long gone — so unlike
# gate-recovery-watchdog.py's _branch_merged_state(branch, rig_name)
# (scripts/gate-recovery-watchdog.py:1487-1510), which takes an already-known
# branch name, R5 first has to DISCOVER candidate branch names from the bead id
# itself. Any local or origin branch where the bead id appears as a /-or--
# delimited path component is a candidate — this covers crew/<owner>/<bead>,
# fix/<bead>-*, feat/<bead>-*, crew/worker-<bead>, and any other prefix
# convention sharing that same delimiter shape. Deliberately NOT a hardcoded
# enum of prefixes: chore/, feat/, and a handful of legacy bare-<bead>-<slug>
# branches (no prefix at all) were all observed live in this repo's actual
# branch history — a fixed 3-pattern whitelist would have missed them. Escapes
# the bead id the same way R7 already does for sling-title matching (rxesc,
# above) — ids contain literal dots (e.g. wa-8yw4i.1). KNOWN RESIDUAL RISK: if
# one bead's full id happens to be an exact prefix of a second bead's full id
# (e.g. "ga-ab" vs "ga-abcd"), a branch belonging to the second bead could
# spuriously match the first — inherent to any delimiter-based heuristic
# search with no registry of id→branch truth to check against; accepted as a
# rare residual given the alternative (today's unconditional stamp, ga-to242's
# whole reason for existing) is a confirmed-live, strictly worse failure mode.
#
# The merge-ancestry CHECK itself mirrors _branch_merged_state's semantics
# exactly (rev-parse --verify, merge-base --is-ancestor against origin/main;
# fetch is done ONCE per store by the caller, see R5 below, not per-call here
# — a live backlog of ~148 closed+ctx:ready beads in a single store was
# observed while verifying this fix, and fetching inside this function would
# mean up to several hundred redundant `git fetch` calls in one sweep;
# mirrors lifecycle-correctness-auditor.sh's fetch_rig(), called once per
# store outside its own per-bead loop) — ported to bash rather than shelled
# out to, matching this file's own precedent (_gate_active_beads above
# already mirrors inflight-reclaim-guard.py's list_gate_active_source_beads()
# the same way, "ported to bash/jq"). Deliberately the SIMPLER ancestor-only
# signal, not lifecycle-correctness-auditor.sh's squash-aware 3-signal branch_merged_in_main
# (ancestor OR patch-id content-equivalence OR scoped-commit-subject) — that
# auditor is DETECTION-ONLY and free to spend extra git calls chasing every
# signal; R5 is a live per-sweep mutation gate, and its OWN fail-safe below (no
# positive merge evidence → skip, never stamp done) already makes a missed
# squash-merge safe (a real done-via-squash bead just stays unlabelled-but-
# visible instead of being silently mislabeled) rather than another false-close.
_bead_id_regex() {  # bead-id → grep -E safe: escapes literal dots (e.g. wa-8yw4i.1) so
                     # "." is matched literally, not as ERE any-char. Real bead ids are
                     # lowercase alnum + hyphens + occasional dot (never the other ERE
                     # metachars), so a dot-only escape is sufficient here — a broader
                     # bracket-expression escape (mirroring R7's jq rxesc) was tried first
                     # and PROVEN silently non-functional on this platform's sed (backslash
                     # has no escaping meaning inside a POSIX bracket expression, so `\.`
                     # inside `[...]` was passed through literally and matched nothing);
                     # this narrower, verified-correct version replaces it.
  printf '%s' "$1" | sed -e 's/\./\\./g'
}
_resolve_bead_branches() {  # store bead-id → candidate branch short-names (origin/ stripped, deduped, one per line)
  local store="$1" bid="$2" bre
  bre=$(_bead_id_regex "$bid")
  "$LCJ_GIT" -C "$store" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
    | sed 's#^origin/##' \
    | grep -E "(^|/|-)${bre}(-|/|\$)" 2>/dev/null \
    | sort -u
}
_branch_merged_state() {  # store branch → merged|unmerged|missing|unknown (mirrors gate-recovery-watchdog.py:1487-1510)
  # NOTE: does NOT fetch — caller (R5, once per store) is responsible. See comment above.
  local store="$1" branch="$2" rc
  [ -z "$branch" ] && { echo "unknown"; return; }
  "$LCJ_GIT" -C "$store" rev-parse --verify -q "origin/${branch}^{commit}" >/dev/null 2>&1
  if [ $? -ne 0 ]; then echo "missing"; return; fi
  "$LCJ_GIT" -C "$store" merge-base --is-ancestor "origin/${branch}" origin/main 2>/dev/null
  rc=$?
  case "$rc" in
    0) echo "merged" ;;
    1) echo "unmerged" ;;
    *) echo "unknown" ;;
  esac
}
# _r5_merge_verdict store bead-id → merged|stranded|unresolved
#   merged     — at least one candidate branch is a positive ancestor of origin/main:
#                safe to stamp story:done.
#   stranded   — EVERY candidate branch resolved definitively (none missing/unknown)
#                and at least one is confirmed unmerged: the wa-g1b58 false-close
#                shape. Never touch; rare + actionable, so escalate loudly (see
#                _r5_stranded_notify_once below).
#   unresolved — no candidate branch found at all, OR at least one candidate could
#                not be resolved (missing/unknown) with no "merged" verdict found
#                elsewhere: can't confirm either way. Never touch; log only.
#
# WHY a mixed missing+unmerged set is "unresolved", not "stranded" (found live
# while verifying this fix, not a hypothetical): a bead can have MULTIPLE
# candidate branches — an abandoned/superseded first attempt plus the branch
# that actually shipped (see the r5mb selftest fixture, and real precedent:
# ga-26df had 3 historical attempt branches). If the ACTUAL winning branch was
# deleted after merging (confirmed live on wa-1t8x9/wa-tkvwb — both closed with
# a close_reason citing a specific merged sha that `merge-base --is-ancestor`
# confirms IS on origin/main, yet the branch recorded in bd metadata no longer
# exists on origin) while an EARLIER, unrelated attempt branch still lingers
# and resolves "unmerged", treating that alone as proof of a false-close would
# itself be a false positive — the exact failure class this fix exists to
# prevent, just relocated. Only trust "stranded" when every candidate could be
# checked and NONE came back merged.
_r5_merge_verdict() {
  local store="$1" bid="$2" branches b state any_unmerged=0 any_inconclusive=0 verdict="unresolved"
  branches=$(_resolve_bead_branches "$store" "$bid")
  [ -z "$branches" ] && { echo "unresolved"; return; }
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    state=$(_branch_merged_state "$store" "$b")
    case "$state" in
      merged)   verdict="merged"; break ;;
      unmerged) any_unmerged=1 ;;
      *)        any_inconclusive=1 ;;  # missing or unknown — resolves nothing either way
    esac
  done <<< "$branches"
  if [ "$verdict" != "merged" ]; then
    if [ "$any_unmerged" -eq 1 ] && [ "$any_inconclusive" -eq 0 ]; then
      verdict="stranded"
    else
      verdict="unresolved"
    fi
  fi
  echo "$verdict"
}
# Cooldown for the R5 "stranded" push-notification specifically (NOT the log
# line, which stays append-only every sweep) — R5's own sweep runs every 10min
# (lifecycle-coherence-janitor.plist StartInterval=600); without a cooldown a
# still-stranded bead would re-notify every single sweep until a human
# intervenes. Separate namespace from $LIFECYCLE_LOCK_DIR's flat <bead-id>
# advisory-lock files (_bead_locked) — writing flat files here would collide
# with real locks and make R4-R8 wrongly treat a notified bead as locked.
# Cooldown state is only touched/consulted in real (non-dry) runs — a DRY_RUN
# preview always notifies, mirroring the gate-unknown-sentinel notify_fail
# above which likewise never gates on LCJ_DRY_RUN (a detection signal, not a
# bead mutation).
R5_STRANDED_NOTIFY_COOLDOWN_SEC="${R5_STRANDED_NOTIFY_COOLDOWN_SEC:-21600}"
_r5_stranded_notify_once() {  # bead-id message → notify_fail at most once per cooldown window
  # $LIFECYCLE_LOCK_DIR resolved HERE, not cached at top-level load time — the
  # selftest reassigns it to a sandboxed $TMP path AFTER this file is sourced,
  # and a top-level ${LIFECYCLE_LOCK_DIR}/... assignment would have frozen in
  # the pre-reassignment (real /tmp/gc-lifecycle-lock) default, leaking
  # cooldown-marker writes outside the test sandbox.
  local id="$1" msg="$2" notify_dir="${LIFECYCLE_LOCK_DIR}/.r5-stranded-notify" marker fts now
  marker="$notify_dir/$id"
  if [ "$LCJ_DRY_RUN" != "1" ]; then
    mkdir -p "$notify_dir" 2>/dev/null || true
    if [ -f "$marker" ]; then
      fts=$(cat "$marker" 2>/dev/null) || fts=0
      now=$(date +%s)
      [ "$(( now - ${fts:-0} ))" -lt "$R5_STRANDED_NOTIFY_COOLDOWN_SEC" ] 2>/dev/null && return 0
    fi
    date +%s > "$marker" 2>/dev/null || true
  fi
  notify_fail "$msg"
}

run_sweep() {
  if [ "$LCJ_ENABLED" != "1" ]; then log "disabled (LCJ_ENABLED!=1)"; return 0; fi
  # imp10: sweep-level mutual exclusion — only one janitor sweep at a time.
  mkdir -p "$LIFECYCLE_LOCK_DIR" 2>/dev/null || true
  exec 9>"$LIFECYCLE_SWEEP_LOCK" && flock -n 9 2>/dev/null || { log "sweep: concurrent sweep in progress (flock) — skipping"; return 0; }
  local store id n=0 lbl
  # ga-ibz0: computed ONCE per sweep (same marker set regardless of which
  # store's beads R3/R7 are currently walking) — see _gate_active_beads above.
  local _gate_active; _gate_active=$(_gate_active_beads)
  case "$_gate_active" in
    *"$_GATE_UNKNOWN_SENTINEL"*) notify_fail "lifecycle-coherence-janitor: consulta de gate-markers FALHOU nesta sweep — protecoes R3/R7 degradadas (fail-safe ativo, bd/Dolt pode estar instavel)" ;;
  esac
  for store in $LCJ_STORES; do
    [ -d "$store" ] || continue

    # R1: terminal status carrying an ACTIVE lifecycle label (story:in-flight OR story:approved)
    # → strip it + transition to story:done. The close path skipped the lifecycle update, so a
    # DONE/implemented bead lingered in the painel's Em-Execução / Aprovadas columns (Athos:
    # "várias coisas em aprovados que já foram implementadas"). A bead explicitly marked
    # story:cancelled is left cancelled (never re-labelled done).
    for lbl in story:in-flight story:approved; do
      local _r1_list; _r1_list=$("$BD" -C "$store" list -l "$lbl" --status closed --json -n 0 2>/dev/null)
      for id in $(printf '%s' "$_r1_list" | jq -r --arg re "$LCJ_CANCEL_RE" \
                  '.[] | select(([.labels[]?]|index("story:cancelled"))|not)
                       | select(((.close_reason // "") | test($re; "i")) | not)
                       | .id' 2>/dev/null); do
        [ -n "$id" ] || continue
        _strip "$store" "$id" "$lbl"; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:done
        log "R1 closed-vestigial: $id ($(basename "$store")) — stripped $lbl, set story:done"; n=$((n+1))
      done
      # ga-hn34: close_reason carries a cancellation/obsolescence keyword but the
      # story:cancelled label was never applied (no dedicated cancel path stamps it
      # atomically at close-time) — land on story:cancelled instead of the story:done
      # default, so a label-less cancel is never silently converted into a fake completion.
      for id in $(printf '%s' "$_r1_list" | jq -r --arg re "$LCJ_CANCEL_RE" \
                  '.[] | select(([.labels[]?]|index("story:cancelled"))|not)
                       | select((.close_reason // "") | test($re; "i"))
                       | .id' 2>/dev/null); do
        [ -n "$id" ] || continue
        _strip "$store" "$id" "$lbl"; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:cancelled
        log "R1 closed-vestigial-cancelled (ga-hn34): $id ($(basename "$store")) — stripped $lbl, close_reason matched cancellation keywords, set story:cancelled"; n=$((n+1))
      done
    done

    # R2: blocked status carrying story:in-flight → strip (blocked ≠ executing). Keep blocked.
    for id in $("$BD" -C "$store" list -l story:in-flight --status blocked --json -n 0 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _strip "$store" "$id" story:in-flight; _strip "$store" "$id" pilot:dispatched
      log "R2 blocked-leak: $id ($(basename "$store")) — stripped story:in-flight"; n=$((n+1))
    done

    # R3: in_progress with NO assignee → no worker is building it → reset status=open. A bead
    # WITH a live assignee is left alone (genuine build OR Pilot owner-grace territory).
    # GUARD (routed-pool double-dispatch fix, 2026-07-03): R3 was the odd rule out — it had
    # NO advisory-lock check and NO age-grace, unlike R4/R5/R6 (`_bead_locked && continue`).
    # A live NAMED crew that self-selects work sets in_progress with an EMPTY assignee for a
    # brief window before it claims/pushes; R3 flipped it back to `open` on the very next
    # sweep → the routed-pool then legitimately dispatched a wa-worker onto the crew's active
    # bead (mila-wa, 3x: wa-6j2b6/wa-ya17c/wa-4dcbg — R3 was the empirical enabler). Now: skip
    # a still-fresh bead (updated within R3_GRACE_MIN) and honor the advisory lock, so R3 only
    # resets a GENUINELY-abandoned in_progress bead (stale) and never races a live build.
    R3_GRACE_MIN="${R3_GRACE_MIN:-30}"
    _r3_cutoff=$(( $(date +%s) - R3_GRACE_MIN * 60 ))
    for id in $("$BD" -C "$store" list --status in_progress --json -n 0 2>/dev/null \
               | jq -r --argjson cut "$_r3_cutoff" '.[]
                       | select((.assignee // "") == "")
                       | select(((( .updated_at // .created_at // "") | fromdateiso8601?) // 9999999999) < $cut)
                       | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      case "$_gate_active" in
        *"$_GATE_UNKNOWN_SENTINEL"*) log "R3 skip-gate-unknown: $id — gate-active query failed this sweep, treating as protected (fail-safe, ga-ibz0)"; continue ;;
        *" $id "*) log "R3 skip-gate-active: $id ($(basename "$store")) — active/pending gate marker, protected (ga-ibz0)"; continue ;;
      esac
      _bead_locked "$id" && { log "R3 skip-locked: $id — advisory lock active (live build)"; continue; }
      _open "$store" "$id"; _strip "$store" "$id" pilot:dispatched
      log "R3 in_progress-no-worker (stale >${R3_GRACE_MIN}m): $id ($(basename "$store")) — set status=open"; n=$((n+1))
    done

    # R4: READY (story:approved OR ctx:ready), status=open, WITH an assignee but NOT being built
    # (no story:in-flight) → the assignee is a STALE/phantom worker. Athos: "quase todas as Aprovadas
    # com worker desnecessário" — manual cleanups kept recurring (the Pilot/refiner leaves an assignee
    # on a bead that then sits ready, not building). Clear it so the painel shows it unassigned and the
    # Pilot re-routes cleanly on real dispatch. EXCLUDE intentional assignments: exec:manual (held for
    # a human), gate:needs-human (braked for review), story:blocked (assignee may be unblocking).
    # NOTE (wa-muesb, corrected after gate_run=ga-wisp-05leh8 FAIL): gate:needs-human is written
    # BOTH bare (inflight-reclaim-guard.py, quorum-convergence-watchdog.py, gate-recovery-watchdog.py
    # all add the plain label with no suffix) AND colon-suffixed with a reason (e.g.
    # gate:needs-human:review). A first attempt here matched only the colon-suffixed form via
    # test("^gate:needs-human:") — that traded the original exact-match gap for a new one, still
    # missing the bare label actively written by production code. Matched by PREFIX with an
    # optional colon-suffix instead, so both forms are covered.
    _r4_seen=" "
    for _rlbl in story:approved ctx:ready; do
      for _pair in $("$BD" -C "$store" list -l "$_rlbl" --status open --json -n 0 2>/dev/null \
                  | jq -r '.[] | select((.assignee // "") != "" and (.assignee // "") != "mayor")
                          | ([.labels[]?]) as $l
                          | select(($l|index("story:in-flight"))==null and ($l|index("exec:manual"))==null and (($l|any(test("^gate:needs-human(:.*)?$")))|not) and ($l|index("story:blocked"))==null)
                          | .id + "|" + .assignee' 2>/dev/null); do
        [ -n "$_pair" ] || continue
        id="${_pair%%|*}"; _r4_assignee="${_pair#*|}"
        case "$_r4_seen" in *" $id "*) continue ;; esac
        _r4_seen="$_r4_seen$id "
        _bead_locked "$id" && { log "R4 skip-locked (imp10): $id — advisory lock active"; continue; }
        if ! _provably_dead "$_r4_assignee"; then
          log "R4 skip-live-assignee (ga-6plfv): $id ($(basename "$store")) — assignee '$_r4_assignee' not provably dead, protected"; continue
        fi
        _unassign "$store" "$id"; _strip "$store" "$id" pilot:dispatched
        log "R4 ready-stale-assignee: $id ($(basename "$store")) — cleared assignee ($_r4_assignee, provably dead)"; n=$((n+1))
      done
    done
    # R6 (imp19 pilot:held expiry): pilot:held + pilot:held-until:<past-epoch> → strip both
    # (the hold expired). pilot:held + NO pilot:held-until:* → set a 24h default expiry so
    # permanent trapdoors are impossible: every hold now has a ceiling.
    _now_lcj=$(date +%s)
    for id in $("$BD" -C "$store" list -l pilot:held --json -n 0 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _bead_locked "$id" && { log "R6 skip-locked (imp10): $id"; continue; }
      # Get label list
      _lbls=$("$BD" -C "$store" show "$id" --json 2>/dev/null \
              | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | .[]' 2>/dev/null) || continue
      _expiry_lbl=$(printf '%s\n' "$_lbls" | grep -E '^pilot:held-until:[0-9]+$' | head -1)
      if [ -n "$_expiry_lbl" ]; then
        _expiry_ep=$(echo "$_expiry_lbl" | cut -d: -f3)
        if [ "$(( _expiry_ep + 0 ))" -lt "$_now_lcj" ] 2>/dev/null; then
          _strip "$store" "$id" pilot:held; _strip "$store" "$id" "$_expiry_lbl"
          log "R6 pilot-held-expired: $id ($(basename "$store")) — hold expired at $(date -r "$_expiry_ep" 2>/dev/null || echo "$_expiry_ep"), stripped"; n=$((n+1))
        fi
      else
        # No expiry: stamp a 24h ceiling so the hold can't be permanent
        _default_expiry="pilot:held-until:$(( _now_lcj + 86400 ))"
        _add "$store" "$id" "$_default_expiry"
        log "R6 pilot-held-no-expiry: $id ($(basename "$store")) — stamped default 24h expiry ($_default_expiry)"; n=$((n+1))
      fi
    done
    # R5 (imp15 invariant auditor): ctx:ready + status=closed → strip ctx:ready + set
    # story:done. R1 already handles story:in-flight and story:approved on closed beads;
    # ctx:ready was missing. A closed bead carrying ctx:ready shows up in the Aprovadas
    # column (which unions story:approved + ctx:ready) as a zombie card. Same exclusion as
    # R1: a story:cancelled bead stays cancelled, never re-labelled done.
    # ga-to242 AC3: "closed" is NOT proof of "merged" — the ga-6plfv partial fix only
    # caught beads still carrying gate:failed/needs-fix at sweep time. Require positive
    # git-ancestry evidence (see _r5_merge_verdict above) before stamping story:done.
    local _r5_list; _r5_list=$("$BD" -C "$store" list -l ctx:ready --status closed --json -n 0 2>/dev/null)
    # Fetch ONCE per store, only if there's at least one candidate — not once per bead/
    # branch inside _branch_merged_state (see comment on that function for why: a live
    # backlog of ~148 candidates in one store was observed while verifying this fix).
    # --prune: without it, a branch deleted on origin after merging (confirmed live —
    # not every rig keeps merged branches around the way gascity/HQ's fix/* convention
    # does) leaves a STALE local refs/remotes/origin/* entry behind; rev-parse would
    # then "successfully" resolve that stale tip and merge-base would ancestor-check
    # against content that no longer represents anything real on the remote, instead of
    # correctly reporting "missing" (which _r5_merge_verdict's mixed-signal handling
    # above depends on to avoid a false "stranded").
    if [ -n "$(printf '%s' "$_r5_list" | jq -r '.[0].id // empty' 2>/dev/null)" ]; then
      "$LCJ_GIT" -C "$store" fetch origin --prune --quiet 2>/dev/null
    fi
    for id in $(printf '%s' "$_r5_list" | jq -r --arg re "$LCJ_CANCEL_RE" \
                '.[] | select(([.labels[]?]|index("story:cancelled"))|not)
                     | select(((.close_reason // "") | test($re; "i")) | not)
                     | select(([.labels[]?]|any(test("^gate:failed(:.*)?$|^gate:needs-fix(:.*)?$")))|not)
                     | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _bead_locked "$id" && { log "R5 skip-locked (imp10): $id — advisory lock active"; continue; }
      # Skip if already has story:done (idempotent safety)
      if "$BD" -C "$store" show "$id" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0] else . end | (.labels // []) | any(. == "story:done")' \
          >/dev/null 2>&1; then continue; fi
      case "$(_r5_merge_verdict "$store" "$id")" in
        merged)
          _strip "$store" "$id" ctx:ready; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:done
          log "R5 ctx-ready-vestigial: $id ($(basename "$store")) — verified merged, stripped ctx:ready, set story:done"; n=$((n+1))
          ;;
        stranded)
          log "R5 skip-stranded (ga-to242 AC3): $id ($(basename "$store")) — closed+ctx:ready but its candidate branch exists on origin and is NOT merged into origin/main; NOT stamping story:done (wa-g1b58 false-close shape)"
          _r5_stranded_notify_once "$id" "lifecycle-coherence-janitor: $id ($(basename "$store")) closed+ctx:ready but its branch is UNMERGED — possible false-close, needs manual recovery (ga-to242 AC3)"
          ;;
        unresolved)
          log "R5 skip-unverified (ga-to242 AC3): $id ($(basename "$store")) — closed+ctx:ready but no branch found matching bead-id naming conventions; cannot confirm merge, NOT stamping story:done"
          ;;
      esac
    done
    # ga-6plfv (AC3, partial/zero-git-risk subset — full merge-ancestry
    # verification deferred, see file header): a closed+ctx:ready bead that
    # STILL carries gate:failed/gate:needs-fix is definitely not "done" — R5's
    # default-to-story:done assumption is exactly wrong here (confirmed live:
    # wa-g1b58, deliberately parked/hard-stopped with gate:failed+gate:needs-fix
    # still attached, got story:done stamped anyway 2026-07-17). Log-only, no
    # notify — this file's convention reserves notify for genuine anomalies, and
    # a backlog of these would otherwise spam every sweep; left for human/Mayor
    # triage (story:done vs story:cancelled) via the follow-up audit bead.
    for id in $(printf '%s' "$_r5_list" | jq -r --arg re "$LCJ_CANCEL_RE" \
                '.[] | select(([.labels[]?]|index("story:cancelled"))|not)
                     | select(((.close_reason // "") | test($re; "i")) | not)
                     | select([.labels[]?]|any(test("^gate:failed(:.*)?$|^gate:needs-fix(:.*)?$")))
                     | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      log "R5 skip-gate-failed (ga-6plfv AC3): $id ($(basename "$store")) — closed+ctx:ready but still carries gate:failed/needs-fix; NOT stamping story:done (not proven delivered), needs human/Mayor triage"
    done
    # ga-hn34: close_reason carries a cancellation/obsolescence keyword but the
    # story:cancelled label was never applied — land on story:cancelled instead of the
    # story:done default (mirrors the R1 cancel-keyword check above).
    for id in $(printf '%s' "$_r5_list" | jq -r --arg re "$LCJ_CANCEL_RE" \
                '.[] | select(([.labels[]?]|index("story:cancelled"))|not)
                     | select((.close_reason // "") | test($re; "i"))
                     | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _bead_locked "$id" && { log "R5 skip-locked-cancelled (imp10): $id — advisory lock active"; continue; }
      _strip "$store" "$id" ctx:ready; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:cancelled
      log "R5 ctx-ready-vestigial-cancelled (ga-hn34): $id ($(basename "$store")) — stripped ctx:ready, close_reason matched cancellation keywords, set story:cancelled"; n=$((n+1))
    done

    # R7 (wa-muesb, 3rd recurrence of this leak class: wa-o4kuh, wa-06yog, wa-8yw4i.1): a
    # NON-implementable bead (epic, unrefined, needs-approval, in escalated/in-progress refino, or
    # braked gate:needs-human:*) gets slung to the impl pool (gc.routed_to set + a sling/molecule
    # created) — often because the label lands AFTER routing, or a human/Mayor slings prematurely.
    # `gc hook` then offers it to every worker that spawns: each claims, detects it's
    # non-implementable, drains — burning pool slots in a loop with zero useful work. Self-heals:
    # any bead carrying one of these labels AND active routing/sling/molecule → clear the routing
    # metadata (open it back up if in_progress), and close the sling/molecule (and its steps).
    local non_imp_beads
    non_imp_beads=$("$BD" -C "$store" list --all --json 2>/dev/null \
                    | jq -r '.[] | select([.labels[]?] | any(test("^story:epic$|^story:unrefined$|^story:needs-approval$|^story:refino-|^story:refinement-in-progress$|^refino:|^auto-refino:|^gate:needs-human(:.*)?$")) ) | .id' 2>/dev/null)
    for id in $non_imp_beads; do
      [ -n "$id" ] || continue
      case "$_gate_active" in
        *"$_GATE_UNKNOWN_SENTINEL"*) log "R7 skip-gate-unknown: $id — gate-active query failed this sweep, treating as protected (fail-safe, ga-ibz0)"; continue ;;
        *" $id "*) log "R7 skip-gate-active: $id ($(basename "$store")) — active/pending gate marker, protected (ga-ibz0)"; continue ;;
      esac
      _bead_locked "$id" && { log "R7 skip-locked: $id — advisory lock active"; continue; }

      local bead_json; bead_json=$("$BD" -C "$store" show "$id" --json 2>/dev/null)
      local routed_to; routed_to=$(echo "$bead_json" | jq -r 'if type=="array" then .[0] else . end | (.metadata // {})["gc.routed_to"] // ""' 2>/dev/null)
      local status; status=$(echo "$bead_json" | jq -r 'if type=="array" then .[0] else . end | .status // ""' 2>/dev/null)
      local mutated=0

      # 1. Clear routing metadata if set
      if [ -n "$routed_to" ] && [ "$routed_to" != "null" ]; then
        _unset_metadata "$store" "$id" "gc.routed_to" "gc.session_name" "gc.work_dir"
        if [ "$status" = "in_progress" ]; then
          _open "$store" "$id"
          # Same intentional-hold convention R4 already uses (its != "mayor" exclusion above):
          # don't strip an assignee that IS "mayor". Without this, reopening leaves
          # status=open + assignee=<worker> — the exact incoherent "phantom card" state this
          # whole janitor exists to prevent (see file header) — and R4 won't clean it up after
          # the fact here, since these non-implementable beads (epic/unrefined/refino-escalated/
          # gate:needs-human) typically carry neither story:approved nor ctx:ready, R4's own triggers.
          local assignee; assignee=$(echo "$bead_json" | jq -r 'if type=="array" then .[0] else . end | .assignee // ""' 2>/dev/null)
          if [ -n "$assignee" ] && [ "$assignee" != "mayor" ]; then
            _unassign "$store" "$id"
          fi
        fi
        mutated=1
      fi

      # 2. Find and close molecules (via metadata)
      local metadata_mol_id; metadata_mol_id=$(echo "$bead_json" | jq -r 'if type=="array" then .[0] else . end | (.metadata // {}).molecule_id // ""' 2>/dev/null)
      if [ -n "$metadata_mol_id" ] && [ "$metadata_mol_id" != "null" ]; then
        local m_status; m_status=$("$BD" -C "$store" show "$metadata_mol_id" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .status // ""' 2>/dev/null)
        if [ "$m_status" = "open" ] || [ "$m_status" = "in_progress" ]; then
          _close_bead "$store" "$metadata_mol_id" "Closed by lifecycle-coherence-janitor: parent bead is non-implementable"
          local child_id
          for child_id in $("$BD" -C "$store" list --parent "$metadata_mol_id" --status open,in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
            [ -n "$child_id" ] || continue
            _close_bead "$store" "$child_id" "Closed by lifecycle-coherence-janitor: parent molecule closed"
          done
          mutated=1
        fi
      fi

      # 3. Find and close molecules (via gc.var.issue query)
      local mol_id
      for mol_id in $("$BD" -C "$store" list -t molecule --metadata-field gc.var.issue="$id" --status open,in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
        [ -n "$mol_id" ] || continue
        _close_bead "$store" "$mol_id" "Closed by lifecycle-coherence-janitor: parent bead is non-implementable"
        local child_id
        for child_id in $("$BD" -C "$store" list --parent "$mol_id" --status open,in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
          [ -n "$child_id" ] || continue
          _close_bead "$store" "$child_id" "Closed by lifecycle-coherence-janitor: parent molecule closed"
        done
        mutated=1
      done

      # 4. Find and close slings. $bid is regex-escaped (rxesc) before use in test() — bead ids
      # can contain literal dots (e.g. wa-8yw4i.1); unescaped, "." is regex any-char and would
      # false-positive match an unrelated sibling id differing by exactly one character.
      # SAFETY (wa-muesb, corrected after gate_run=ga-wisp-05leh8 FAIL): a bare dependency-link
      # check with no type/issue_type filter closes ANY open dependent of the target — including
      # a real in-progress child story (parent-child) or a bug that merely tracks/relates to an
      # unrefined story (discovered-from/related), not just disposable wrappers (confirmed live:
      # wa-tpr3t depends on wa-ffg4c via discovered-from and is a real P0 bug, not a wrapper).
      # `gc sling` (see --help) auto-creates a coordination wrapper unless --no-convoy/--owned is
      # passed: issue_type=convoy, title "sling-<target-id>", linked via dependency type "tracks"
      # (confirmed against live beads, e.g. wa-0w6ig/wa-zbnb5/wa-vmhza). This is the SAME wrapper
      # signature quality-gate-dispatcher.sh's merge-boundary reaper (ga-dcclose) already uses to
      # safely auto-close coordination beads — mirrored here rather than inventing a new rule.
      # Gate the whole find (title OR dependency match) on that signature so a same-named or
      # dependency-linked REAL story/bug is never touched. Also fixes a latent bug: dependency
      # objects carry `depends_on_id` (confirmed via live data), never `.id` — the old
      # `.dependencies[]?.id` reference was always null, so the dependency-match arm never fired.
      local sling_id
      for sling_id in $("$BD" -C "$store" list --status open,in_progress --json 2>/dev/null \
                       | jq -r --arg bid "$id" '
                           def rxesc: gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.c)");
                           ($bid | rxesc) as $ebid
                           | .[] | select(.id != $bid)
                           | select(((.issue_type // .type // "") == "convoy") or (((.id // "") | startswith("dc-"))))
                           | select(
                               (.title // "" | test("^sling-" + $ebid + "$|^(build story|fix bug|build|fix|implement)\\s+" + $ebid + "$"; "i")) or
                               ([.dependencies[]? | select((.type // "") == "tracks") | .depends_on_id] | any(. == $bid))
                             ) | .id' 2>/dev/null); do
        [ -n "$sling_id" ] || continue
        _close_bead "$store" "$sling_id" "Closed by lifecycle-coherence-janitor: parent bead is non-implementable"
        mutated=1
      done

      if [ "$mutated" -eq 1 ]; then
        log "R7 non-implementable-cleanup: $id ($(basename "$store")) — cleared routing metadata, closed sling/molecule"
        n=$((n+1))
      fi
    done

    # R8 (ga-ipm4): PARK and ARM are orthogonal states that must never coexist. A bead
    # carrying an arm label (exec:auto or ctx:ready) that is ALSO parked (needs-human,
    # pool:refused:<any reason>, or story:blocked) must have the arm labels stripped —
    # parking is a deliberate human/dog decision that must survive automated
    # re-classification (same lesson as R4's bare+colon-suffixed gate:needs-human fix,
    # here applied to a different label family). No status filter: the invariant is
    # unconditional, not just for open beads. Confirmed live: ga-66wc carried
    # needs-human + pool:refused:engine-rebuild-required alongside ctx:ready + exec:auto
    # simultaneously; context-check-dispatcher.sh (separately fixed, ga-ipm4) re-added
    # the arm labels on its next ~10min sweep the moment a human/dog stripped them,
    # because a stripped bead has no ctx:* label left and looks unjudged again — 17+
    # dog sessions re-claimed and re-confirmed the same refused verdict over 11 hours.
    # Only the arm labels are stripped; the park labels are the correct, intended state
    # and are left untouched. Strip-only footprint (no status/assignee mutation), so —
    # like R1/R2/R5/R6 — this does NOT consult _gate_active_beads (that check is
    # reserved for R3/R7's status-flip/close mutations); it DOES honor the advisory
    # lock, matching R4-R7.
    _r8_seen=" "
    for _armlbl in exec:auto ctx:ready; do
      for id in $("$BD" -C "$store" list -l "$_armlbl" --json -n 0 2>/dev/null \
                  | jq -r '.[] | ([.labels[]?]) as $l
                          | select($l | any(. == "needs-human" or . == "story:blocked" or test("^pool:refused:")))
                          | .id' 2>/dev/null); do
        [ -n "$id" ] || continue
        case "$_r8_seen" in *" $id "*) continue ;; esac
        _r8_seen="$_r8_seen$id "
        _bead_locked "$id" && { log "R8 skip-locked: $id — advisory lock active"; continue; }
        _strip "$store" "$id" exec:auto
        _strip "$store" "$id" ctx:ready
        log "R8 park-arm-invariant (ga-ipm4): $id ($(basename "$store")) — parked bead carried exec:auto/ctx:ready, stripped both"; n=$((n+1))
      done
    done
  done
  # CRITICAL: Dolt auto-commit is OFF (dolt.auto-commit=off). A `bd label remove`/`update` writes
  # to the WORKING SET but does NOT commit — so OTHER processes that read committed HEAD (the
  # painel's `bd list`, a fresh bd) never see the change, and the phantom card persists despite
  # this janitor running. We MUST commit, or the normalization is invisible to exactly the reader
  # it exists to fix. (Diagnosed 2026-06-22: stripped labels stayed visible to the painel until an
  # explicit `bd dolt commit`.)
  if [ "$n" -gt 0 ] && [ "$LCJ_DRY_RUN" != "1" ]; then
    for store in $LCJ_STORES; do
      [ -d "$store" ] || continue
      "$BD" -C "$store" dolt commit -m "lifecycle-coherence-janitor: persist label/status normalization" >/dev/null 2>&1 || true
    done
    log "committed Dolt working set across stores (auto-commit is off → uncommitted strips stay invisible to the painel)"
  fi
  log "sweep complete: normalized $n bead(s)$([ "$LCJ_DRY_RUN" = "1" ] && echo ' (DRY)')"
  return 0
}

# ── selftest (hermetic bd shim records actions; no real beads touched) ─────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ACT="$TMP/actions"; : > "$ACT"
  # r4-asg: open story:approved with stale assignee (no story:in-flight/exec:manual/gate:needs-human/story:blocked)
  # r4-human: same shape as r4-asg but ALSO carries gate:needs-human:foo — must be EXCLUDED (regression
  #           for the original exact-match bug: index("gate:needs-human") never matches a colon-suffixed label)
  # r4-human-bare: same shape but carries the BARE gate:needs-human label (no suffix) — must ALSO be
  #           EXCLUDED (regression for gate_run=ga-wisp-05leh8: a colon-only test("^gate:needs-human:")
  #           traded one gap for another, missing the bare form production code actually writes)
  # ga-6plfv/ga-u8e55 (2026-07-18) R4 liveness fixtures — regression coverage for the incident
  # itself: R4 was re-enabled 2026-07-17 with NO session-liveness check and ripped live crews'
  # assignees every sweep. Fake session roster (see the "gc" shim below) has exactly two entries:
  # "crew-live" (state:active) and "crew-ambiguous" (an unrecognized state string). "mila-wa" (used
  # by r4-asg/r4-human/r4-human-bare above) deliberately does NOT appear in that roster, so it stays
  # provably-dead and those fixtures' existing cleared/excluded assertions are unchanged by this fix.
  # r4-live: same shape as r4-asg but assignee="crew-live" (a LIVE session) — R4 must NOT clear it.
  #          This is the direct regression test: this fixture would have caught ga-6plfv before it
  #          shipped (assignee present, no protecting label, but liveness says "leave it alone").
  # r4-ambiguous: assignee="crew-ambiguous" (a session that exists but whose state matches neither
  #          the live nor the dead vocabulary) — R4 must NOT clear it either (fail-safe: unknown is
  #          not proof of death, matches claimant_provably_dead()'s own documented contract).
  # r4-deacon: assignee="deacon" — R4's own jq prefilter only ever excluded the literal "mayor", not
  #          "deacon"; the liveness check's is_coordinator() closes that gap as a side effect — must
  #          NOT be cleared regardless of what (if anything) "deacon" resolves to in the roster.
  # r5: closed ctx:ready without story:done (R5 target)
  # r5-locked: closed ctx:ready with an advisory lock (imp10 — must be SKIPPED by R5)
  # r5-gate-failed (ga-6plfv AC3, partial fix): closed+ctx:ready but STILL carries gate:failed +
  #          gate:needs-fix — must NOT get story:done stamped (wa-g1b58's exact live shape: parked/
  #          hard-stopped, not delivered). Log-only skip, no story:cancelled/story:done mutation.
  # AC3 (ga-to242) fixtures — R5 must now verify git-ancestry before stamping story:done:
  # r5m: candidate branch fix/r5m-some-fix IS an ancestor of origin/main → story:done (merged path)
  # r5s: candidate branch fix/r5s-some-fix EXISTS on origin but is NOT an ancestor → left alone,
  #      logged "skip-stranded", notified once (the wa-g1b58 false-close shape)
  # r5u: NO branch matches any naming convention → left alone, logged "skip-unverified", no notify
  # r9dot.1: dot-escaping regression (mirrors R7's wa-8yw4i.1/sling-8yw4iX1 pair) — its REAL
  #      branch fix/r9dot.1-real is UNMERGED (stranded); a DECOY branch fix/r9dotX1-decoy
  #      (literal X where r9dot.1 has a literal dot) IS merged. If the dot were treated as
  #      ERE any-char instead of a literal, the decoy would wrongly match and r9dot.1 would
  #      be misreported "merged" instead of "stranded". (Named r9, not r5-prefixed, so its
  #      id does not itself collide with the bare "r5" fixture's own delimiter match — "r5"
  #      is a literal prefix of "r5-dot...", which DOES spuriously match "fix/r5-dot...-*"
  #      branches; verified empirically before picking this naming.)
  # r5's own AC3 branch is fix/r5-legacy-fix (merged) — added so the pre-existing "r5 →
  # story:done" assertion still holds under the new merge-gated R5.
  # R8 fixtures (ga-ipm4, park+arm invariant): r8-parked-auto (exec:auto+pool:refused:<reason>),
  # r8-parked-auto2 (exec:auto+a DIFFERENT pool:refused:<reason> suffix — proves prefix
  # genericity), r8-parked-ready (ctx:ready+needs-human), r8-parked-both (BOTH arm labels+
  # story:blocked — dedup guard: must be processed exactly once, not once per arm-label pass),
  # r8-locked (ctx:ready+needs-human, advisory-locked — must be SKIPPED like R4-R7),
  # r8-clean-auto/r8-clean-ready (arm label, no park label — must be left alone).
  # R7 fixtures (list --all): 3 historical recurrences (wa-o4kuh epic+molecule, wa-06yog
  # needs-approval+sling, wa-8yw4i.1 in-progress escalated-refino+molecule+step+sling — id has a
  # literal dot to regression-test regex-escaping) + one bead per remaining exclusion label
  # (t-unrefined/t-refinement/t-refino/t-auto/t-human/t-human-bare) + t-valid (a genuinely
  # in-flight bead that R7 must NEVER touch). sling-8yw4iX1 is a DECOY sibling whose title differs
  # from wa-8yw4i.1 by one character (X vs literal dot) — must NOT close (regression for the
  # sling-regex-escape bug). All three sling-* fixtures now carry issue_type:convoy, matching real
  # `gc sling` wrapper beads (confirmed live: wa-0w6ig/wa-zbnb5/wa-vmhza) — regression fixtures for
  # gate_run=ga-wisp-05leh8's second finding:
  # dep-only-wrap: convoy, title does NOT match the sling-title pattern, found ONLY via a
  #           dependency of type "tracks" pointing at wa-06yog — must close (also regression-tests
  #           the .depends_on_id field-name fix; the old `.dependencies[]?.id` reference was
  #           always null since dependency objects never carry a bare `.id` key).
  # real-tracker-bug: issue_type:bug, linked via the SAME "tracks" dependency type to wa-06yog —
  #           must survive (a bug that merely tracks a non-implementable bead is not a disposable
  #           wrapper; the reviewer's exact cited hazard).
  # real-title-collision: issue_type:bug, title literally "fix wa-06yog" (matches the title regex)
  #           — must survive; the issue_type gate now applies to the title-match arm too, not just
  #           the dependency arm.
  cat > "$TMP/bd" <<SHIM
#!/usr/bin/env bash
a="\$*"
case "\$a" in
  *"list -l story:in-flight --status closed"*)  echo '[{"id":"cl-1"},{"id":"cl-2"},{"id":"cl-byreason","close_reason":"Obsoleto pelo pivo on-device — descomissionamento do Whapi/proxy"}]' ;;
  *"list -l story:approved --status closed"*)   echo '[{"id":"ca-1"},{"id":"ca-cancel","labels":["story:cancelled","story:approved"]},{"id":"ca-byreason","close_reason":"CANCELLED — requirements changed, replaced by ga-xyz"}]' ;;
  *"list -l story:in-flight --status blocked"*) echo '[{"id":"bl-1"}]' ;;
  *"list --status in_progress"*)                echo '[{"id":"ip-noasg","assignee":"","updated_at":"2020-01-01T00:00:00Z"},{"id":"ip-fresh","assignee":"","updated_at":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"},{"id":"ip-asg","assignee":"mila-wa"},{"id":"ip-gate-active","assignee":"","updated_at":"2020-01-01T00:00:00Z"}]' ;;
  *"list -l story:approved --status open"*)     echo '[{"id":"r4-asg","assignee":"mila-wa","labels":["story:approved"]},{"id":"r4-human","assignee":"mila-wa","labels":["story:approved","gate:needs-human:foo"]},{"id":"r4-human-bare","assignee":"mila-wa","labels":["story:approved","gate:needs-human"]},{"id":"r4-live","assignee":"crew-live","labels":["story:approved"]},{"id":"r4-ambiguous","assignee":"crew-ambiguous","labels":["story:approved"]},{"id":"r4-deacon","assignee":"deacon","labels":["story:approved"]}]' ;;
  *"list -l ctx:ready --status open"*)          echo '[]' ;;
  *"list -l ctx:ready --status closed"*)        echo '[{"id":"r5","labels":["ctx:ready"]},{"id":"r5-locked","labels":["ctx:ready"]},{"id":"r5-cancel","labels":["ctx:ready","story:cancelled"]},{"id":"r5-byreason","labels":["ctx:ready"],"close_reason":"discontinued: replaced by wa-xyz redesign"},{"id":"r5-gate-failed","labels":["ctx:ready","gate:failed","gate:needs-fix"]},{"id":"r5m","labels":["ctx:ready"]},{"id":"r5s","labels":["ctx:ready"]},{"id":"r5u","labels":["ctx:ready"]},{"id":"r9dot.1","labels":["ctx:ready"]},{"id":"r5mb","labels":["ctx:ready"]},{"id":"r5mm","labels":["ctx:ready"]}]' ;;
  *"show r5 "*|*"show r5-locked "*)             echo '[{"id":"r5","labels":["ctx:ready"]}]' ;;
  *"show r5m"*)                                 echo '[{"id":"r5m","labels":["ctx:ready"]}]' ;;
  *"show r5s"*)                                 echo '[{"id":"r5s","labels":["ctx:ready"]}]' ;;
  *"show r5mb"*)                                echo '[{"id":"r5mb","labels":["ctx:ready"]}]' ;;
  *"show r5mm"*)                                echo '[{"id":"r5mm","labels":["ctx:ready"]}]' ;;
  *"show r5u"*)                                 echo '[{"id":"r5u","labels":["ctx:ready"]}]' ;;
  *"show r9dot.1"*)                             echo '[{"id":"r9dot.1","labels":["ctx:ready"]}]' ;;
  # R6 (imp19): r6-exp has an expired held-until; r6-noexp has pilot:held but no expiry
  *"list -l pilot:held"*)                       echo '[{"id":"r6-exp","labels":["pilot:held","pilot:held-until:1000000"]},{"id":"r6-noexp","labels":["pilot:held"]}]' ;;
  *"show r6-exp"*) echo '[{"id":"r6-exp","labels":["pilot:held","pilot:held-until:1000000"]}]' ;;
  *"show r6-noexp"*) echo '[{"id":"r6-noexp","labels":["pilot:held"]}]' ;;
  # R7 (wa-muesb): historical recurrences + one bead per exclusion label + a valid control
  *"list --all"*)                               echo '[{"id":"wa-o4kuh","status":"open","labels":["story:epic"],"metadata":{"gc.routed_to":"pool","molecule_id":"mol-o4kuh"}},{"id":"wa-06yog","status":"open","labels":["story:needs-approval"],"metadata":{"gc.routed_to":"pool"}},{"id":"wa-8yw4i.1","status":"in_progress","assignee":"mila-wa","labels":["story:refino-escalado"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-unrefined","status":"open","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-refinement","status":"open","labels":["story:refinement-in-progress"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-refino","status":"open","labels":["refino:policy-gap"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-auto","status":"open","labels":["auto-refino:foo"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-human","status":"open","labels":["gate:needs-human:bar"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-human-bare","status":"open","labels":["gate:needs-human"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-valid","status":"in_progress","labels":["story:in-flight"],"metadata":{"gc.routed_to":"pool"}},{"id":"t-mayor-assigned","status":"in_progress","assignee":"mayor","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}},{"id":"wa-gate-protect","status":"open","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}},{"id":"r7-original-target","status":"open","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show wa-o4kuh"*)                             echo '[{"id":"wa-o4kuh","status":"open","labels":["story:epic"],"metadata":{"gc.routed_to":"pool","molecule_id":"mol-o4kuh"}}]' ;;
  *"show wa-06yog"*)                             echo '[{"id":"wa-06yog","status":"open","labels":["story:needs-approval"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show wa-8yw4i.1"*)                           echo '[{"id":"wa-8yw4i.1","status":"in_progress","assignee":"mila-wa","labels":["story:refino-escalado"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-mayor-assigned"*)                     echo '[{"id":"t-mayor-assigned","status":"in_progress","assignee":"mayor","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-unrefined"*)                          echo '[{"id":"t-unrefined","status":"open","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-refinement"*)                         echo '[{"id":"t-refinement","status":"open","labels":["story:refinement-in-progress"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-refino"*)                             echo '[{"id":"t-refino","status":"open","labels":["refino:policy-gap"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-auto"*)                               echo '[{"id":"t-auto","status":"open","labels":["auto-refino:foo"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-human "*)                             echo '[{"id":"t-human","status":"open","labels":["gate:needs-human:bar"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-human-bare"*)                         echo '[{"id":"t-human-bare","status":"open","labels":["gate:needs-human"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show t-valid"*)                              echo '[{"id":"t-valid","status":"in_progress","labels":["story:in-flight"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show mol-o4kuh"*)                            echo '[{"id":"mol-o4kuh","status":"open"}]' ;;
  *"show mol-8yw4i"*)                            echo '[{"id":"mol-8yw4i","status":"open"}]' ;;
  *"list -t molecule --metadata-field gc.var.issue=wa-8yw4i.1"*) echo '[{"id":"mol-8yw4i","status":"open"}]' ;;
  *"list --parent mol-8yw4i"*)                   echo '[{"id":"step-8yw4i","status":"open"}]' ;;
  *"list --status open,in_progress"*)            echo '[{"id":"sling-wa-06yog","title":"sling-wa-06yog","status":"open","issue_type":"convoy"},{"id":"sling-8yw4i","title":"fix wa-8yw4i.1","status":"open","issue_type":"convoy"},{"id":"sling-8yw4iX1","title":"fix wa-8yw4iX1","status":"open","issue_type":"convoy"},{"id":"dep-only-wrap","title":"tracks wa-06yog work","status":"open","issue_type":"convoy","dependencies":[{"depends_on_id":"wa-06yog","type":"tracks"}]},{"id":"real-tracker-bug","title":"investigate related issue","status":"open","issue_type":"bug","dependencies":[{"depends_on_id":"wa-06yog","type":"tracks"}]},{"id":"real-title-collision","title":"fix wa-06yog","status":"open","issue_type":"bug"}]' ;;
  # Gate-active fixtures (ga-ibz0): gm-r3/gm-sling under gate-status:ready, gm-r7 under
  # gate-status:queued. LCJ_TEST_GATE_FAIL toggles a simulated query failure (fail-safe test).
  *"list --label type:quality-gate-marker --label gate-status:ready"*)
    [ "\${LCJ_TEST_GATE_FAIL:-0}" = "1" ] && exit 1
    echo '[{"id":"gm-r3","labels":["type:quality-gate-marker","gate-status:ready","source-bead:ip-gate-active"]},{"id":"gm-sling","labels":["type:quality-gate-marker","gate-status:ready","source-bead:sling-gate-src"]}]' ;;
  *"list --label type:quality-gate-marker --label gate-status:dispatching"*)
    [ "\${LCJ_TEST_GATE_FAIL:-0}" = "1" ] && exit 1
    echo '[]' ;;
  *"list --label type:quality-gate-marker --label gate-status:queued"*)
    [ "\${LCJ_TEST_GATE_FAIL:-0}" = "1" ] && exit 1
    echo '[{"id":"gm-r7","labels":["type:quality-gate-marker","gate-status:queued","source-bead:wa-gate-protect"]}]' ;;
  *"list --label type:quality-gate-marker --label gate-status:claimed"*)
    [ "\${LCJ_TEST_GATE_FAIL:-0}" = "1" ] && exit 1
    echo '[]' ;;
  # Multi-id resolve of the directly-active source beads (ga-lrglm sling→original parity):
  # sling-gate-src's title resolves back to r7-original-target.
  *"show ip-gate-active"*)
    echo '[{"id":"ip-gate-active","title":"gate-active in_progress bead"},{"id":"sling-gate-src","title":"fix bug r7-original-target: gate parity test"},{"id":"wa-gate-protect","title":"gate-active non-implementable bead"}]' ;;
  # Individual per-id shows R7 would issue ONLY if the gate-active skip regresses — real
  # routed_to data here means a regression is caught (not masked by an empty-shim fallback).
  *"show wa-gate-protect"*)     echo '[{"id":"wa-gate-protect","status":"open","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  *"show r7-original-target"*)  echo '[{"id":"r7-original-target","status":"open","labels":["story:unrefined"],"metadata":{"gc.routed_to":"pool"}}]' ;;
  # R8 (ga-ipm4): park+arm invariant. r8-parked-auto (exec:auto + pool:refused:<reason>),
  # r8-parked-auto2 (exec:auto + a DIFFERENT pool:refused:<reason> suffix, proves prefix
  # genericity, not a single hardcoded reason string), r8-parked-ready (ctx:ready +
  # needs-human), r8-parked-both (BOTH arm labels + story:blocked — one bead, one pass,
  # dedup guard), r8-locked (ctx:ready + needs-human, advisory-locked — must be skipped),
  # r8-clean-auto/r8-clean-ready (arm label, no park label — must be left alone).
  *"list -l exec:auto --json"*)
    echo '[{"id":"r8-parked-auto","labels":["exec:auto","pool:refused:engine-rebuild-required"]},{"id":"r8-parked-auto2","labels":["exec:auto","pool:refused:some-other-reason"]},{"id":"r8-parked-both","labels":["exec:auto","ctx:ready","story:blocked"]},{"id":"r8-clean-auto","labels":["exec:auto","lane:small"]}]' ;;
  *"list -l ctx:ready --json"*)
    echo '[{"id":"r8-parked-ready","labels":["ctx:ready","needs-human"]},{"id":"r8-parked-both","labels":["exec:auto","ctx:ready","story:blocked"]},{"id":"r8-locked","labels":["ctx:ready","needs-human"]},{"id":"r8-clean-ready","labels":["ctx:ready","lane:small"]}]' ;;
  *"label remove"*|*"label add"*|*"update"*|*"dolt commit"*) echo "\$a" >> "$ACT" ;;
  *) echo '[]' ;;
esac
SHIM
  chmod +x "$TMP/bd"
  NOTIFY_LOG="$TMP/notify.log"
  cat > "$TMP/notify" <<NOTIFYSHIM
#!/usr/bin/env bash
echo "\$*" >> "${TMP}/notify.log"
NOTIFYSHIM
  chmod +x "$TMP/notify"
  # ga-6plfv: fake session roster for R4's liveness check. "crew-live" is active
  # (must protect r4-live), "crew-ambiguous" carries a state in neither the live
  # nor dead vocabulary (must ALSO protect r4-ambiguous — fail-safe). "mila-wa"
  # and "deacon" deliberately do NOT appear here: mila-wa must still resolve
  # provably-dead (absent from the roster, matching the pre-fix r4-asg/r4-human/
  # r4-human-bare assertions below), and deacon must be protected regardless of
  # roster contents (is_coordinator() short-circuits before any session lookup).
  # _provably_dead() runs the REAL reclaim_liveness.py/claimant_provably_dead()
  # against this fake roster — only `gc session list` itself is shimmed, so the
  # selftest exercises the actual canonical liveness logic, not a re-mocked copy.
  cat > "$TMP/gc" <<'GCSHIM'
#!/usr/bin/env bash
case "$*" in
  *"session list --json"*) echo '{"sessions":[{"id":"sess-1","name":"crew-live","session_name":"crew-live","state":"active","closed":false},{"id":"sess-2","name":"crew-ambiguous","session_name":"crew-ambiguous","state":"paused-unknown-state","closed":false}]}' ;;
  *) echo '{}' ;;
esac
GCSHIM
  chmod +x "$TMP/gc"
  # AC3 (ga-to242) git shim: for-each-ref always returns the full fixed branch set (real
  # git for-each-ref takes no bead-id filter — _resolve_bead_branches does the grep
  # filtering); rev-parse/merge-base respond per-branch so each fixture gets an
  # independent merged/unmerged/missing verdict.
  cat > "$TMP/git" <<GITSHIM
#!/usr/bin/env bash
a="\$*"
case "\$a" in
  *"for-each-ref"*)
    echo "origin/fix/r5-legacy-fix"
    echo "origin/fix/r5m-some-fix"
    echo "origin/fix/r5s-some-fix"
    echo "origin/fix/r9dot.1-real"
    echo "origin/fix/r9dotX1-decoy"
    echo "origin/fix/r5mb-attempt1"
    echo "origin/fix/r5mb-attempt2"
    echo "origin/fix/r5mm-attempt1"
    echo "origin/fix/r5mm-attempt2"
    ;;
  *"fetch"*) exit 0 ;;
  *"fix/r5-legacy-fix^{commit}"*) exit 0 ;;
  *"fix/r5m-some-fix^{commit}"*)  exit 0 ;;
  *"fix/r5s-some-fix^{commit}"*)  exit 0 ;;
  *"fix/r9dot.1-real^{commit}"*)  exit 0 ;;
  *"fix/r9dotX1-decoy^{commit}"*) exit 0 ;;
  *"fix/r5mb-attempt1^{commit}"*) exit 0 ;;
  *"fix/r5mb-attempt2^{commit}"*) exit 0 ;;
  *"fix/r5mm-attempt2^{commit}"*) exit 0 ;;
  # r5mm-attempt1 deliberately has NO rev-parse case here — falls through to the
  # generic "^{commit}" miss below (exit 1 = missing), simulating a candidate
  # branch name that was found by for-each-ref (e.g. a stale/local ref) but does
  # not actually resolve on origin (the wa-1t8x9/wa-tkvwb real shape: the branch
  # that actually merged was deleted afterward; a DIFFERENT, unrelated candidate
  # for the same bead id lingers and resolves fine).
  *"^{commit}"*) exit 1 ;;
  *"is-ancestor origin/fix/r5-legacy-fix"*) exit 0 ;;  # merged
  *"is-ancestor origin/fix/r5m-some-fix"*)  exit 0 ;;  # merged
  *"is-ancestor origin/fix/r5s-some-fix"*)  exit 1 ;;  # unmerged (stranded)
  *"is-ancestor origin/fix/r9dot.1-real"*)  exit 1 ;;  # unmerged (stranded — the REAL match)
  *"is-ancestor origin/fix/r9dotX1-decoy"*) exit 0 ;;  # merged (decoy — must NOT be reached)
  *"is-ancestor origin/fix/r5mb-attempt1"*) exit 1 ;;  # unmerged (an earlier abandoned attempt)
  *"is-ancestor origin/fix/r5mb-attempt2"*) exit 0 ;;  # merged (the successful re-attempt)
  *"is-ancestor origin/fix/r5mm-attempt2"*) exit 1 ;;  # unmerged — but attempt1 is MISSING, not confirmed unmerged: must be "unresolved", not "stranded"
  *"is-ancestor"*) exit 1 ;;
  *) exit 0 ;;
esac
GITSHIM
  chmod +x "$TMP/git"
  # Reassign script vars DIRECTLY (top-level reads happen at LOAD, before this block).
  BD="$TMP/bd"; GC="$TMP/gc"; LCJ_STORES="$TMP"; LOG="$TMP/log"; LCJ_DRY_RUN=0; LCJ_ENABLED=1
  LCJ_NOTIFY="$TMP/notify"; LCJ_GIT="$TMP/git"
  LCJ_GATE_CITY="$TMP"  # ga-ibz0: route _gate_active_beads() through the same shim
  LIFECYCLE_LOCK_DIR="$TMP/.lifecycle-lock"
  LIFECYCLE_SWEEP_LOCK="$LIFECYCLE_LOCK_DIR/.janitor-sweep.lock"
  # imp10: plant an advisory lock for r5-locked to verify the janitor skips it
  mkdir -p "$LIFECYCLE_LOCK_DIR"
  echo "$$:$(date +%s)" > "$LIFECYCLE_LOCK_DIR/r5-locked"
  # ga-ipm4: same, for r8-locked (R8 park+arm invariant must also honor the advisory lock)
  echo "$$:$(date +%s)" > "$LIFECYCLE_LOCK_DIR/r8-locked"
  run_sweep
  echo "Scenario: janitor normalizes R1-R5 incoherences, respects locks (imp10), never touches coherent beads"
  grep -q 'label remove cl-1 story:in-flight' "$ACT" && ok "R1: closed+story:in-flight → stripped"            || bad "R1 not stripped"
  grep -q 'label add cl-1 story:done'         "$ACT" && ok "R1: closed bead transitioned to story:done"       || bad "R1 did not set story:done"
  grep -q 'label remove ca-1 story:approved'  "$ACT" && ok "R1: closed+story:approved → stripped (Aprovadas pollution fix)" || bad "R1 approved-vestigial not stripped"
  grep -q 'ca-cancel'                         "$ACT" && bad "TOUCHED a story:cancelled closed bead (must stay cancelled)" || ok "left the story:cancelled closed bead alone"
  grep -q 'label remove cl-byreason story:in-flight' "$ACT" && ok "R1 (ga-hn34): closed+story:in-flight w/ cancellation close_reason → still stripped the active label" || bad "R1 (ga-hn34) did not strip story:in-flight on cl-byreason"
  grep -q 'label add cl-byreason story:cancelled'    "$ACT" && ok "R1 (ga-hn34): close_reason matched a cancellation keyword → set story:cancelled instead of story:done" || bad "R1 (ga-hn34) did not set story:cancelled on cl-byreason"
  grep -q 'label add cl-byreason story:done'         "$ACT" && bad "R1 (ga-hn34): mislabeled a cancelled-by-close_reason bead story:done — the exact silent mislabeling this fix exists to prevent" || ok "R1 (ga-hn34): did not mislabel cl-byreason story:done"
  grep -q 'label add ca-byreason story:cancelled'    "$ACT" && ok "R1 (ga-hn34): keyword match is case-insensitive (CANCELLED, uppercase) and works on the story:approved path too" || bad "R1 (ga-hn34) did not set story:cancelled on ca-byreason (case-insensitivity or story:approved path broken)"
  grep -q 'label add ca-byreason story:done'         "$ACT" && bad "R1 (ga-hn34): mislabeled ca-byreason story:done" || ok "R1 (ga-hn34): did not mislabel ca-byreason story:done"
  grep -q 'label remove bl-1 story:in-flight' "$ACT" && ok "R2: blocked+story:in-flight → stripped"           || bad "R2 not stripped"
  grep -q 'update ip-noasg --status open'     "$ACT" && ok "R3: STALE in_progress + no assignee → status=open" || bad "R3 not opened"
  grep -q 'ip-fresh'                          "$ACT" && bad "R3 flipped a FRESH in_progress bead (routed-pool race!)" || ok "R3: fresh in_progress + no assignee → LEFT ALONE (grace protects a live crew build)"
  grep -q 'ip-asg'                            "$ACT" && bad "TOUCHED an in_progress bead WITH an assignee (unsafe!)" || ok "left the assigned in_progress bead alone (safe)"
  grep -q 'update r4-asg --assignee'          "$ACT" && ok "R4: open story:approved with stale assignee → cleared (phantom worker)" || bad "R4 did not clear stale assignee"
  grep -q 'update r4-human --assignee'        "$ACT" && bad "R4: cleared assignee on a gate:needs-human:foo bead (must be excluded — human braked for review)" || ok "R4: left gate:needs-human:foo bead's assignee alone (colon-suffixed exclusion works)"
  grep -q 'update r4-human-bare --assignee'   "$ACT" && bad "R4 bare-label bug (gate_run=ga-wisp-05leh8): cleared assignee on a BARE gate:needs-human bead (production code writes this form with no suffix)" || ok "R4: left bare gate:needs-human bead's assignee alone (bare-label exclusion works)"
  grep -q 'update r4-live --assignee'         "$ACT" && bad "R4 REGRESSION (ga-6plfv): cleared the assignee of a PROVABLY-LIVE session — this is the exact incident that ran 102 times in production before this fix" || ok "R4 (ga-6plfv): left a live session's assignee alone (liveness check works)"
  grep -q 'update r4-ambiguous --assignee'    "$ACT" && bad "R4 (ga-6plfv): cleared the assignee of a session in an UNRECOGNIZED state — unknown must fail safe as NOT provably dead" || ok "R4 (ga-6plfv): left an ambiguous-state session's assignee alone (fail-safe on unknown state)"
  grep -q 'update r4-deacon --assignee'       "$ACT" && bad "R4 (ga-6plfv): cleared assignee=deacon — coordinator exclusion gap the liveness check was supposed to close" || ok "R4 (ga-6plfv): left assignee=deacon alone (is_coordinator() protects it, same convention as assignee=mayor)"
  grep -q 'update r4-asg --assignee'          "$ACT" && ok "R4 (ga-6plfv): mila-wa is absent from the session roster → still provably dead → still cleared (pre-fix behavior preserved for genuine phantoms)" || bad "R4 (ga-6plfv): regressed the genuinely-phantom case — mila-wa should still be cleared"
  grep -q 'label remove r6-exp pilot:held'     "$ACT" && ok "R6 (imp19): expired pilot:held-until → stripped pilot:held" || bad "R6 did not strip expired pilot:held"
  grep -q 'label remove r6-exp pilot:held-until:1000000' "$ACT" && ok "R6 (imp19): stripped the expiry label" || bad "R6 did not strip expiry label"
  grep -q 'label add r6-noexp pilot:held-until:' "$ACT" && ok "R6 (imp19): pilot:held with no expiry → stamped default 24h expiry" || bad "R6 did not stamp default expiry"
  grep -q 'label remove r5 ctx:ready'         "$ACT" && ok "R5 (imp15): closed+ctx:ready → stripped (Aprovadas zombie fix)" || bad "R5 did not strip ctx:ready"
  grep -q 'label add r5 story:done'           "$ACT" && ok "R5 (imp15): closed ctx:ready bead → set story:done" || bad "R5 did not set story:done"

  # R5 AC3 (ga-to242): closed is not proof of merged — require positive git-ancestry
  # evidence before stamping story:done. (The "r5"/"r5 story:done" assertions just above
  # already prove the merged path still works via r5's own dedicated fix/r5-legacy-fix
  # branch; these add the stranded/unresolved fail-safe paths + the dot-escaping regression.)
  grep -q 'label add r5m story:done'          "$ACT" && ok "R5 AC3: merged branch found (r5m) → story:done stamped" || bad "R5 AC3: r5m (merged branch) did NOT get story:done"
  grep -q 'label remove r5m ctx:ready'        "$ACT" && ok "R5 AC3: r5m ctx:ready stripped on the merged path" || bad "R5 AC3: r5m ctx:ready not stripped"
  grep -q 'r5s'                               "$ACT" && bad "R5 AC3: TOUCHED r5s (branch exists but UNMERGED — must never stamp story:done, wa-g1b58 false-close shape)" || ok "R5 AC3: left r5s alone (stranded — branch found but not merged)"
  grep -q 'r5s' "$NOTIFY_LOG" 2>/dev/null     && ok "R5 AC3: stranded finding (r5s) was escalated via notify_fail" || bad "R5 AC3: stranded finding (r5s) was NOT notified — silent false-close risk"
  grep -q 'r5u'                               "$ACT" && bad "R5 AC3: TOUCHED r5u (no branch found at all — must never stamp story:done)" || ok "R5 AC3: left r5u alone (unresolved — no branch found)"
  grep -q 'r5u' "$NOTIFY_LOG" 2>/dev/null     && bad "R5 AC3: notified for r5u (unresolved/no-branch is the expected common case, not push-worthy — only 'stranded' should notify)" || ok "R5 AC3: did not notify for r5u (unresolved stays log-only, avoiding notification spam)"
  grep -q 'r9dot.1'                           "$ACT" && bad "R5 AC3 dot-escaping regression: r9dot.1 got touched via its UNMERGED real branch leaking a match from the MERGED decoy (fix/r9dotX1-decoy) — dot was treated as ERE any-char instead of literal" || ok "R5 AC3: dot-escaping correct — r9dot.1 (unmerged real branch) did not pick up the merged decoy's verdict"
  grep -q 'label add r5mb story:done'         "$ACT" && ok "R5 AC3 multi-branch (real shape: ga-26df had 3 attempt branches): an UNMERGED first candidate does not short-circuit — a LATER merged candidate still stamps story:done" || bad "R5 AC3 multi-branch: r5mb (2 candidates, 2nd merged) did NOT get story:done — early-unmerged wrongly won"
  grep -q 'r5mm'                               "$ACT" && bad "R5 AC3 mixed-signal false-positive (real shape: wa-1t8x9/wa-tkvwb — the winning branch was deleted after merge, an unrelated abandoned attempt lingers): r5mm was TOUCHED — a missing+unmerged mix must never be confident enough for 'stranded'" || ok "R5 AC3 mixed-signal: r5mm (1 missing candidate + 1 unmerged candidate) left alone — correctly downgraded to unresolved, not falsely 'stranded'"
  grep -q 'r5mm' "$NOTIFY_LOG" 2>/dev/null     && bad "R5 AC3 mixed-signal: notified for r5mm — 'unresolved' must stay log-only like r5u, not escalate on an inconclusive mix" || ok "R5 AC3 mixed-signal: did not notify for r5mm (correctly treated as unresolved, not stranded)"

  grep -q 'r5-locked'                         "$ACT" && bad "imp10: touched a lifecycle-locked bead (must be skipped)" || ok "imp10: skipped the advisory-locked bead (r5-locked)"
  grep -q 'r5-cancel'                         "$ACT" && bad "R5: TOUCHED a story:cancelled closed ctx:ready bead (must stay cancelled)" || ok "R5: left story:cancelled bead alone"
  grep -q 'label remove r5-byreason ctx:ready'    "$ACT" && ok "R5 (ga-hn34): closed+ctx:ready w/ cancellation close_reason → still stripped ctx:ready" || bad "R5 (ga-hn34) did not strip ctx:ready on r5-byreason"
  grep -q 'label add r5-byreason story:cancelled' "$ACT" && ok "R5 (ga-hn34): close_reason matched a cancellation keyword → set story:cancelled instead of story:done" || bad "R5 (ga-hn34) did not set story:cancelled on r5-byreason"
  grep -q 'label add r5-byreason story:done'      "$ACT" && bad "R5 (ga-hn34): mislabeled a cancelled-by-close_reason bead story:done — the exact silent mislabeling this fix exists to prevent" || ok "R5 (ga-hn34): did not mislabel r5-byreason story:done"
  grep -q 'r5-gate-failed'                        "$ACT" && bad "R5 (ga-6plfv AC3): mutated a closed+ctx:ready bead that still carries gate:failed/gate:needs-fix — wa-g1b58's exact failure shape (parked/hard-stopped, not delivered)" || ok "R5 (ga-6plfv AC3): left a gate:failed/needs-fix bead alone (no story:done stamped on unproven work)"
  grep -q 'dolt commit'                       "$ACT" && ok "commits the Dolt working set (auto-commit off → else strips invisible to painel)" || bad "did NOT commit → normalization invisible to readers"

  # R7 (wa-muesb — historical recurrences, pattern coverage, and the two gate-flagged bugs)
  grep -q 'update wa-o4kuh --unset-metadata gc.routed_to' "$ACT" && ok "R7 (historical wa-o4kuh): unset gc.routed_to on story:epic" || bad "R7 did not unset gc.routed_to on wa-o4kuh"
  grep -q 'update mol-o4kuh --status closed' "$ACT" && ok "R7 (historical wa-o4kuh): closed molecule mol-o4kuh" || bad "R7 did not close molecule mol-o4kuh"
  grep -q 'update wa-06yog --unset-metadata gc.routed_to' "$ACT" && ok "R7 (historical wa-06yog): unset gc.routed_to on story:needs-approval" || bad "R7 did not unset gc.routed_to on wa-06yog"
  grep -q 'update sling-wa-06yog --status closed' "$ACT" && ok "R7 (historical wa-06yog): closed sling sling-wa-06yog" || bad "R7 did not close sling-wa-06yog"
  grep -q 'update wa-8yw4i.1 --status open' "$ACT" && ok "R7 (historical wa-8yw4i.1): reset in_progress bead to open" || bad "R7 did not reset wa-8yw4i.1 status"
  grep -q 'update wa-8yw4i.1 --assignee' "$ACT" && ok "R7 (historical wa-8yw4i.1): cleared stale worker assignee on reopen" || bad "R7 reopened wa-8yw4i.1 but left its assignee set — recreates the open+assigned phantom-card state this janitor exists to prevent, and R4 won't catch it (no story:approved/ctx:ready on an escalated-refino bead)"
  grep -q 'update t-mayor-assigned --status open' "$ACT" && ok "R7: reopened mayor-assigned in_progress bead" || bad "R7 did not reopen t-mayor-assigned"
  grep -q 'update t-mayor-assigned --assignee' "$ACT" && bad "R7: cleared assignee=mayor on reopen (must be excluded — same intentional-hold convention R4 already uses)" || ok "R7: left assignee=mayor alone on reopen (matches R4's convention)"
  grep -q 'update mol-8yw4i --status closed' "$ACT" && ok "R7 (historical wa-8yw4i.1): closed molecule mol-8yw4i" || bad "R7 did not close molecule mol-8yw4i"
  grep -q 'update step-8yw4i --status closed' "$ACT" && ok "R7 (historical wa-8yw4i.1): closed molecule child step-8yw4i" || bad "R7 did not close step-8yw4i"
  grep -q 'update sling-8yw4i --status closed' "$ACT" && ok "R7 (historical wa-8yw4i.1): closed matching sling sling-8yw4i" || bad "R7 did not close sling-8yw4i"
  grep -q 'update sling-8yw4iX1 --status closed' "$ACT" && bad "R7 sling-regex bug: unescaped dot false-matched a DIFFERENT sibling id (wa-8yw4iX1 vs wa-8yw4i.1)" || ok "R7 sling-regex: correctly spared a differently-named sibling (bead id is regex-escaped)"
  grep -q 'update dep-only-wrap --status closed' "$ACT" && ok "R7 (gate_run=ga-wisp-05leh8 fix): closed a convoy wrapper found ONLY via tracks-dependency (title didn't match; also proves the depends_on_id field-name fix)" || bad "R7 did not close dep-only-wrap (convoy, tracks-linked, non-matching title) — dependency-match arm still broken"
  grep -q 'update real-tracker-bug --status closed' "$ACT" && bad "R7 over-broad fix (gate_run=ga-wisp-05leh8 hazard): closed a real bug that merely TRACKS a non-implementable bead — not a disposable wrapper" || ok "R7: left real-tracker-bug alone (tracks-dependency alone is not enough without issue_type:convoy)"
  grep -q 'update real-title-collision --status closed' "$ACT" && bad "R7 over-broad fix (gate_run=ga-wisp-05leh8 hazard): closed a real bug whose title coincidentally matched the sling-title pattern" || ok "R7: left real-title-collision alone (title match alone is not enough without issue_type:convoy)"
  grep -q 'update t-unrefined --unset-metadata gc.routed_to' "$ACT" && ok "R7: unset gc.routed_to on story:unrefined" || bad "R7 did not unset gc.routed_to on t-unrefined"
  grep -q 'update t-refinement --unset-metadata gc.routed_to' "$ACT" && ok "R7: unset gc.routed_to on story:refinement-in-progress" || bad "R7 did not unset gc.routed_to on t-refinement"
  grep -q 'update t-refino --unset-metadata gc.routed_to' "$ACT" && ok "R7: unset gc.routed_to on refino:policy-gap" || bad "R7 did not unset gc.routed_to on t-refino"
  grep -q 'update t-auto --unset-metadata gc.routed_to' "$ACT" && ok "R7: unset gc.routed_to on auto-refino:foo" || bad "R7 did not unset gc.routed_to on t-auto"
  grep -q 'update t-human --unset-metadata gc.routed_to' "$ACT" && ok "R7: unset gc.routed_to on gate:needs-human:bar" || bad "R7 did not unset gc.routed_to on t-human"
  grep -q 'update t-human-bare --unset-metadata gc.routed_to' "$ACT" && ok "R7 (gate_run=ga-wisp-05leh8 fix): unset gc.routed_to on BARE gate:needs-human" || bad "R7 did not unset gc.routed_to on t-human-bare (bare-label trigger still broken)"
  grep -q 't-valid' "$ACT" && bad "R7: modified a valid in-flight bead (t-valid)" || ok "R7 left valid bead t-valid alone"

  # R8 (ga-ipm4): park+arm invariant — a parked bead (needs-human/pool:refused:*/
  # story:blocked) must never keep exec:auto/ctx:ready. Reproduced live on ga-66wc.
  grep -q 'label remove r8-parked-auto exec:auto' "$ACT" && ok "R8: exec:auto + pool:refused:<reason> → stripped exec:auto" || bad "R8 did not strip exec:auto on r8-parked-auto"
  grep -q 'label remove r8-parked-auto2 exec:auto' "$ACT" && ok "R8: pool:refused:* prefix matches a DIFFERENT reason suffix, not one hardcoded string" || bad "R8 did not strip exec:auto on r8-parked-auto2 (pool:refused:* prefix match broken)"
  grep -q 'label remove r8-parked-ready ctx:ready' "$ACT" && ok "R8: ctx:ready + needs-human → stripped ctx:ready" || bad "R8 did not strip ctx:ready on r8-parked-ready"
  grep -q 'label remove r8-parked-both exec:auto' "$ACT" && ok "R8: bead with BOTH arm labels + story:blocked → stripped exec:auto" || bad "R8 did not strip exec:auto on r8-parked-both"
  grep -q 'label remove r8-parked-both ctx:ready' "$ACT" && ok "R8: bead with BOTH arm labels + story:blocked → stripped ctx:ready" || bad "R8 did not strip ctx:ready on r8-parked-both"
  [ "$(grep -c 'r8-parked-both' "$ACT")" = "2" ] && ok "R8: r8-parked-both processed exactly once despite matching both the exec:auto and ctx:ready queries (dedup guard)" || bad "R8 dedup guard broken: r8-parked-both processed more than once (found in both arm-label passes)"
  grep -q 'r8-locked' "$ACT" && bad "R8: touched an advisory-locked parked+armed bead (must be skipped, matches R4-R7 convention)" || ok "R8: skipped the advisory-locked bead (r8-locked)"
  grep -q 'r8-clean-auto' "$ACT" && bad "R8: touched an exec:auto bead with NO park label (false positive)" || ok "R8: left a clean exec:auto bead alone (no park label)"
  grep -q 'r8-clean-ready' "$ACT" && bad "R8: touched a ctx:ready bead with NO park label (false positive)" || ok "R8: left a clean ctx:ready bead alone (no park label)"

  # Gate-active protection (ga-ibz0/wa-bkjy7, 2026-07-11): quality-gate-guard.sh silently
  # detaches a bead's assignee for the FULL gate duration (no bd comment); R3/R7 must never
  # mutate a bead with an active/pending gate marker, mirroring inflight-reclaim-guard.py's
  # list_gate_active_source_beads() (including its sling→original title back-reference).
  grep -q 'update ip-gate-active --status open' "$ACT" && bad "R3 (ga-ibz0): reopened a bead with an ACTIVE gate marker — reproduces the exact silent revert this fix exists to prevent" || ok "R3 (ga-ibz0): left a gate-active in_progress-no-assignee bead alone (protected)"
  grep -q 'wa-gate-protect' "$ACT" && bad "R7 (ga-ibz0): touched a bead directly referenced by an ACTIVE gate marker" || ok "R7 (ga-ibz0): left a directly gate-active non-implementable bead alone (protected)"
  grep -q 'r7-original-target' "$ACT" && bad "R7 (ga-ibz0/ga-lrglm parity): touched the ORIGINAL bead behind a gate-active sling wrapper — sling-title back-reference not applied" || ok "R7 (ga-ibz0/ga-lrglm parity): left the original bead behind a gate-active sling wrapper alone (resolved via sling-gate-src's title)"

  # FAIL-SAFE (ga-ibz0): a gate-active query FAILURE is NOT the same as "zero active
  # markers" — conflating them would silently drop gate protection exactly when Dolt is
  # under the contention that makes false reclaims most likely (same guard-bug class fixed
  # twice elsewhere: ga-ap7od/ga-jfo7). On failure, R3/R7 must skip ALL mutations for the
  # sweep rather than proceed as if nothing were gated.
  : > "$ACT"; : > "$NOTIFY_LOG"; export LCJ_TEST_GATE_FAIL=1; run_sweep; export LCJ_TEST_GATE_FAIL=0
  grep -q 'update ip-noasg --status open' "$ACT" && bad "R3 fail-safe (ga-ibz0): fired despite a gate-active query FAILURE (should treat as protected, not as zero-active)" || ok "R3 fail-safe (ga-ibz0): gate-query failure → skipped mutation entirely"
  grep -q 'wa-o4kuh' "$ACT" && bad "R7 fail-safe (ga-ibz0): fired despite a gate-active query FAILURE (should treat as protected, not as zero-active)" || ok "R7 fail-safe (ga-ibz0): gate-query failure → skipped mutation entirely"
  grep -q 'lifecycle-coherence-janitor' "$NOTIFY_LOG" && ok "gate-query failure (ga-4zpf): notified — R3/R7 protection degradation is not silent" || bad "gate-query failure (ga-4zpf): did NOT notify — silent degradation of R3/R7 protection (ga-4zpf regression)"

  # DRY-RUN makes no changes
  : > "$ACT"; LCJ_DRY_RUN=1; run_sweep
  [ ! -s "$ACT" ] && ok "DRY_RUN performs zero mutations" || bad "DRY_RUN mutated beads"
  echo ""; echo "lifecycle-coherence-janitor selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep
