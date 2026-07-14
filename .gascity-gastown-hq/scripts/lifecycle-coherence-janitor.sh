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
set -uo pipefail

LCJ_STORES="${LCJ_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
LCJ_DRY_RUN="${LCJ_DRY_RUN:-0}"
LCJ_ENABLED="${LCJ_ENABLED:-1}"
BD="${LCJ_BD:-bd}"
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
      for id in $("$BD" -C "$store" list -l "$_rlbl" --status open --json -n 0 2>/dev/null \
                  | jq -r '.[] | select((.assignee // "") != "" and (.assignee // "") != "mayor")
                          | ([.labels[]?]) as $l
                          | select(($l|index("story:in-flight"))==null and ($l|index("exec:manual"))==null and (($l|any(test("^gate:needs-human(:.*)?$")))|not) and ($l|index("story:blocked"))==null)
                          | .id' 2>/dev/null); do
        [ -n "$id" ] || continue
        case "$_r4_seen" in *" $id "*) continue ;; esac
        _r4_seen="$_r4_seen$id "
        _bead_locked "$id" && { log "R4 skip-locked (imp10): $id — advisory lock active"; continue; }
        _unassign "$store" "$id"; _strip "$store" "$id" pilot:dispatched
        log "R4 ready-stale-assignee: $id ($(basename "$store")) — cleared phantom assignee"; n=$((n+1))
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
    local _r5_list; _r5_list=$("$BD" -C "$store" list -l ctx:ready --status closed --json -n 0 2>/dev/null)
    for id in $(printf '%s' "$_r5_list" | jq -r --arg re "$LCJ_CANCEL_RE" \
                '.[] | select(([.labels[]?]|index("story:cancelled"))|not)
                     | select(((.close_reason // "") | test($re; "i")) | not)
                     | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _bead_locked "$id" && { log "R5 skip-locked (imp10): $id — advisory lock active"; continue; }
      # Skip if already has story:done (idempotent safety)
      if "$BD" -C "$store" show "$id" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0] else . end | (.labels // []) | any(. == "story:done")' \
          >/dev/null 2>&1; then continue; fi
      _strip "$store" "$id" ctx:ready; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:done
      log "R5 ctx-ready-vestigial: $id ($(basename "$store")) — stripped ctx:ready, set story:done"; n=$((n+1))
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
  # r5: closed ctx:ready without story:done (R5 target)
  # r5-locked: closed ctx:ready with an advisory lock (imp10 — must be SKIPPED by R5)
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
  *"list -l story:approved --status open"*)     echo '[{"id":"r4-asg","assignee":"mila-wa","labels":["story:approved"]},{"id":"r4-human","assignee":"mila-wa","labels":["story:approved","gate:needs-human:foo"]},{"id":"r4-human-bare","assignee":"mila-wa","labels":["story:approved","gate:needs-human"]}]' ;;
  *"list -l ctx:ready --status open"*)          echo '[]' ;;
  *"list -l ctx:ready --status closed"*)        echo '[{"id":"r5","labels":["ctx:ready"]},{"id":"r5-locked","labels":["ctx:ready"]},{"id":"r5-cancel","labels":["ctx:ready","story:cancelled"]},{"id":"r5-byreason","labels":["ctx:ready"],"close_reason":"discontinued: replaced by wa-xyz redesign"}]' ;;
  *"show r5 "*|*"show r5-locked "*)             echo '[{"id":"r5","labels":["ctx:ready"]}]' ;;
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
  # Reassign script vars DIRECTLY (top-level reads happen at LOAD, before this block).
  BD="$TMP/bd"; LCJ_STORES="$TMP"; LOG="$TMP/log"; LCJ_DRY_RUN=0; LCJ_ENABLED=1
  LCJ_NOTIFY="$TMP/notify"
  LCJ_GATE_CITY="$TMP"  # ga-ibz0: route _gate_active_beads() through the same shim
  LIFECYCLE_LOCK_DIR="$TMP/.lifecycle-lock"
  LIFECYCLE_SWEEP_LOCK="$LIFECYCLE_LOCK_DIR/.janitor-sweep.lock"
  # imp10: plant an advisory lock for r5-locked to verify the janitor skips it
  mkdir -p "$LIFECYCLE_LOCK_DIR"
  echo "$$:$(date +%s)" > "$LIFECYCLE_LOCK_DIR/r5-locked"
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
  grep -q 'label remove r6-exp pilot:held'     "$ACT" && ok "R6 (imp19): expired pilot:held-until → stripped pilot:held" || bad "R6 did not strip expired pilot:held"
  grep -q 'label remove r6-exp pilot:held-until:1000000' "$ACT" && ok "R6 (imp19): stripped the expiry label" || bad "R6 did not strip expiry label"
  grep -q 'label add r6-noexp pilot:held-until:' "$ACT" && ok "R6 (imp19): pilot:held with no expiry → stamped default 24h expiry" || bad "R6 did not stamp default expiry"
  grep -q 'label remove r5 ctx:ready'         "$ACT" && ok "R5 (imp15): closed+ctx:ready → stripped (Aprovadas zombie fix)" || bad "R5 did not strip ctx:ready"
  grep -q 'label add r5 story:done'           "$ACT" && ok "R5 (imp15): closed ctx:ready bead → set story:done" || bad "R5 did not set story:done"
  grep -q 'r5-locked'                         "$ACT" && bad "imp10: touched a lifecycle-locked bead (must be skipped)" || ok "imp10: skipped the advisory-locked bead (r5-locked)"
  grep -q 'r5-cancel'                         "$ACT" && bad "R5: TOUCHED a story:cancelled closed ctx:ready bead (must stay cancelled)" || ok "R5: left story:cancelled bead alone"
  grep -q 'label remove r5-byreason ctx:ready'    "$ACT" && ok "R5 (ga-hn34): closed+ctx:ready w/ cancellation close_reason → still stripped ctx:ready" || bad "R5 (ga-hn34) did not strip ctx:ready on r5-byreason"
  grep -q 'label add r5-byreason story:cancelled' "$ACT" && ok "R5 (ga-hn34): close_reason matched a cancellation keyword → set story:cancelled instead of story:done" || bad "R5 (ga-hn34) did not set story:cancelled on r5-byreason"
  grep -q 'label add r5-byreason story:done'      "$ACT" && bad "R5 (ga-hn34): mislabeled a cancelled-by-close_reason bead story:done — the exact silent mislabeling this fix exists to prevent" || ok "R5 (ga-hn34): did not mislabel r5-byreason story:done"
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
