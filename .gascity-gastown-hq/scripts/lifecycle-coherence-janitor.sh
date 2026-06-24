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
set -uo pipefail

LCJ_STORES="${LCJ_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
LCJ_DRY_RUN="${LCJ_DRY_RUN:-0}"
LCJ_ENABLED="${LCJ_ENABLED:-1}"
BD="${LCJ_BD:-bd}"
LOG="${LCJ_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/lifecycle-coherence-janitor.log}"
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
_ids() {    # store + list-args → bead ids (one per line), jq-filtered
  "$BD" -C "$1" "${@:2}" --json -n 0 2>/dev/null | jq -r "$JQ" 2>/dev/null
}

run_sweep() {
  if [ "$LCJ_ENABLED" != "1" ]; then log "disabled (LCJ_ENABLED!=1)"; return 0; fi
  # imp10: sweep-level mutual exclusion — only one janitor sweep at a time.
  mkdir -p "$LIFECYCLE_LOCK_DIR" 2>/dev/null || true
  exec 9>"$LIFECYCLE_SWEEP_LOCK" && flock -n 9 2>/dev/null || { log "sweep: concurrent sweep in progress (flock) — skipping"; return 0; }
  local store id n=0 lbl
  for store in $LCJ_STORES; do
    [ -d "$store" ] || continue

    # R1: terminal status carrying an ACTIVE lifecycle label (story:in-flight OR story:approved)
    # → strip it + transition to story:done. The close path skipped the lifecycle update, so a
    # DONE/implemented bead lingered in the painel's Em-Execução / Aprovadas columns (Athos:
    # "várias coisas em aprovados que já foram implementadas"). A bead explicitly marked
    # story:cancelled is left cancelled (never re-labelled done).
    for lbl in story:in-flight story:approved; do
      for id in $("$BD" -C "$store" list -l "$lbl" --status closed --json -n 0 2>/dev/null \
                  | jq -r '.[] | select(([.labels[]?]|index("story:cancelled"))|not) | .id' 2>/dev/null); do
        [ -n "$id" ] || continue
        _strip "$store" "$id" "$lbl"; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:done
        log "R1 closed-vestigial: $id ($(basename "$store")) — stripped $lbl, set story:done"; n=$((n+1))
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
    for id in $("$BD" -C "$store" list --status in_progress --json -n 0 2>/dev/null | jq -r '.[] | select((.assignee // "") == "") | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _open "$store" "$id"; _strip "$store" "$id" pilot:dispatched
      log "R3 in_progress-no-worker: $id ($(basename "$store")) — set status=open"; n=$((n+1))
    done

    # R4: READY (story:approved OR ctx:ready), status=open, WITH an assignee but NOT being built
    # (no story:in-flight) → the assignee is a STALE/phantom worker. Athos: "quase todas as Aprovadas
    # com worker desnecessário" — manual cleanups kept recurring (the Pilot/refiner leaves an assignee
    # on a bead that then sits ready, not building). Clear it so the painel shows it unassigned and the
    # Pilot re-routes cleanly on real dispatch. EXCLUDE intentional assignments: exec:manual (held for
    # a human), gate:needs-human (braked for review), story:blocked (assignee may be unblocking).
    _r4_seen=" "
    for _rlbl in story:approved ctx:ready; do
      for id in $("$BD" -C "$store" list -l "$_rlbl" --status open --json -n 0 2>/dev/null \
                  | jq -r '.[] | select((.assignee // "") != "" and (.assignee // "") != "mayor")
                          | ([.labels[]?]) as $l
                          | select(($l|index("story:in-flight"))==null and ($l|index("exec:manual"))==null and ($l|index("gate:needs-human"))==null and ($l|index("story:blocked"))==null)
                          | .id' 2>/dev/null); do
        [ -n "$id" ] || continue
        case "$_r4_seen" in *" $id "*) continue ;; esac
        _r4_seen="$_r4_seen$id "
        _bead_locked "$id" && { log "R4 skip-locked (imp10): $id — advisory lock active"; continue; }
        _unassign "$store" "$id"; _strip "$store" "$id" pilot:dispatched
        log "R4 ready-stale-assignee: $id ($(basename "$store")) — cleared phantom assignee"; n=$((n+1))
      done
    done
    # R5 (imp15 invariant auditor): ctx:ready + status=closed → strip ctx:ready + set
    # story:done. R1 already handles story:in-flight and story:approved on closed beads;
    # ctx:ready was missing. A closed bead carrying ctx:ready shows up in the Aprovadas
    # column (which unions story:approved + ctx:ready) as a zombie card. Same exclusion as
    # R1: a story:cancelled bead stays cancelled, never re-labelled done.
    for id in $("$BD" -C "$store" list -l ctx:ready --status closed --json -n 0 2>/dev/null \
                | jq -r '.[] | select(([.labels[]?]|index("story:cancelled"))|not) | .id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _bead_locked "$id" && { log "R5 skip-locked (imp10): $id — advisory lock active"; continue; }
      # Skip if already has story:done (idempotent safety)
      if "$BD" -C "$store" show "$id" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0] else . end | (.labels // []) | any(. == "story:done")' \
          >/dev/null 2>&1; then continue; fi
      _strip "$store" "$id" ctx:ready; _strip "$store" "$id" pilot:dispatched; _add "$store" "$id" story:done
      log "R5 ctx-ready-vestigial: $id ($(basename "$store")) — stripped ctx:ready, set story:done"; n=$((n+1))
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
  # r5: closed ctx:ready without story:done (R5 target)
  # r5-locked: closed ctx:ready with an advisory lock (imp10 — must be SKIPPED by R5)
  cat > "$TMP/bd" <<SHIM
#!/usr/bin/env bash
a="\$*"
case "\$a" in
  *"list -l story:in-flight --status closed"*)  echo '[{"id":"cl-1"},{"id":"cl-2"}]' ;;
  *"list -l story:approved --status closed"*)   echo '[{"id":"ca-1"},{"id":"ca-cancel","labels":["story:cancelled","story:approved"]}]' ;;
  *"list -l story:in-flight --status blocked"*) echo '[{"id":"bl-1"}]' ;;
  *"list --status in_progress"*)                echo '[{"id":"ip-noasg","assignee":""},{"id":"ip-asg","assignee":"mila-wa"}]' ;;
  *"list -l story:approved --status open"*)     echo '[{"id":"r4-asg","assignee":"mila-wa","labels":["story:approved"]}]' ;;
  *"list -l ctx:ready --status open"*)          echo '[]' ;;
  *"list -l ctx:ready --status closed"*)        echo '[{"id":"r5","labels":["ctx:ready"]},{"id":"r5-locked","labels":["ctx:ready"]},{"id":"r5-cancel","labels":["ctx:ready","story:cancelled"]}]' ;;
  *"show r5 "*|*"show r5-locked "*)             echo '[{"id":"r5","labels":["ctx:ready"]}]' ;;
  *"label remove"*|*"label add"*|*"update"*|*"dolt commit"*) echo "\$a" >> "$ACT" ;;
  *) echo '[]' ;;
esac
SHIM
  chmod +x "$TMP/bd"
  # Reassign script vars DIRECTLY (top-level reads happen at LOAD, before this block).
  BD="$TMP/bd"; LCJ_STORES="$TMP"; LOG="$TMP/log"; LCJ_DRY_RUN=0; LCJ_ENABLED=1
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
  grep -q 'label remove bl-1 story:in-flight' "$ACT" && ok "R2: blocked+story:in-flight → stripped"           || bad "R2 not stripped"
  grep -q 'update ip-noasg --status open'     "$ACT" && ok "R3: in_progress + no assignee → status=open"      || bad "R3 not opened"
  grep -q 'ip-asg'                            "$ACT" && bad "TOUCHED an in_progress bead WITH an assignee (unsafe!)" || ok "left the assigned in_progress bead alone (safe)"
  grep -q 'update r4-asg --assignee'          "$ACT" && ok "R4: open story:approved with stale assignee → cleared (phantom worker)" || bad "R4 did not clear stale assignee"
  grep -q 'label remove r5 ctx:ready'         "$ACT" && ok "R5 (imp15): closed+ctx:ready → stripped (Aprovadas zombie fix)" || bad "R5 did not strip ctx:ready"
  grep -q 'label add r5 story:done'           "$ACT" && ok "R5 (imp15): closed ctx:ready bead → set story:done" || bad "R5 did not set story:done"
  grep -q 'r5-locked'                         "$ACT" && bad "imp10: touched a lifecycle-locked bead (must be skipped)" || ok "imp10: skipped the advisory-locked bead (r5-locked)"
  grep -q 'r5-cancel'                         "$ACT" && bad "R5: TOUCHED a story:cancelled closed ctx:ready bead (must stay cancelled)" || ok "R5: left story:cancelled bead alone"
  grep -q 'dolt commit'                       "$ACT" && ok "commits the Dolt working set (auto-commit off → else strips invisible to painel)" || bad "did NOT commit → normalization invisible to readers"
  # DRY-RUN makes no changes
  : > "$ACT"; LCJ_DRY_RUN=1; run_sweep
  [ ! -s "$ACT" ] && ok "DRY_RUN performs zero mutations" || bad "DRY_RUN mutated beads"
  echo ""; echo "lifecycle-coherence-janitor selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep
