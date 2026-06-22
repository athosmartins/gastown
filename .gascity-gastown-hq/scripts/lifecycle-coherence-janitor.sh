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
_ids() {    # store + list-args → bead ids (one per line), jq-filtered
  "$BD" -C "$1" "${@:2}" --json -n 0 2>/dev/null | jq -r "$JQ" 2>/dev/null
}

run_sweep() {
  if [ "$LCJ_ENABLED" != "1" ]; then log "disabled (LCJ_ENABLED!=1)"; return 0; fi
  local store id n=0 JQ='.[].id'
  for store in $LCJ_STORES; do
    [ -d "$store" ] || continue

    # R1: terminal status carrying story:in-flight → strip the vestigial execution label.
    for id in $(JQ='.[].id'; "$BD" -C "$store" list -l story:in-flight --status closed --json -n 0 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
      [ -n "$id" ] || continue
      _strip "$store" "$id" story:in-flight; _strip "$store" "$id" pilot:dispatched
      log "R1 closed-vestigial: $id ($(basename "$store")) — stripped story:in-flight"; n=$((n+1))
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
  done
  log "sweep complete: normalized $n bead(s)$([ "$LCJ_DRY_RUN" = "1" ] && echo ' (DRY)')"
  return 0
}

# ── selftest (hermetic bd shim records actions; no real beads touched) ─────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ACT="$TMP/actions"; : > "$ACT"
  cat > "$TMP/bd" <<SHIM
#!/usr/bin/env bash
a="\$*"
case "\$a" in
  *"list -l story:in-flight --status closed"*)  echo '[{"id":"cl-1"},{"id":"cl-2"}]' ;;
  *"list -l story:in-flight --status blocked"*) echo '[{"id":"bl-1"}]' ;;
  *"list --status in_progress"*)                echo '[{"id":"ip-noasg","assignee":""},{"id":"ip-asg","assignee":"mila-wa"}]' ;;
  *"label remove"*|*"update"*)                  echo "\$a" >> "$ACT" ;;
  *) echo '[]' ;;
esac
SHIM
  chmod +x "$TMP/bd"
  # Reassign script vars DIRECTLY (top-level reads happen at LOAD, before this block).
  BD="$TMP/bd"; LCJ_STORES="$TMP"; LOG="$TMP/log"; LCJ_DRY_RUN=0; LCJ_ENABLED=1
  run_sweep
  echo "Scenario: janitor normalizes the 3 incoherences, never touches coherent beads"
  grep -q 'label remove cl-1 story:in-flight' "$ACT" && ok "R1: closed+story:in-flight → stripped"            || bad "R1 not stripped"
  grep -q 'label remove bl-1 story:in-flight' "$ACT" && ok "R2: blocked+story:in-flight → stripped"           || bad "R2 not stripped"
  grep -q 'update ip-noasg --status open'     "$ACT" && ok "R3: in_progress + no assignee → status=open"      || bad "R3 not opened"
  grep -q 'ip-asg'                            "$ACT" && bad "TOUCHED an in_progress bead WITH an assignee (unsafe!)" || ok "left the assigned in_progress bead alone (safe)"
  # DRY-RUN makes no changes
  : > "$ACT"; LCJ_DRY_RUN=1; run_sweep
  [ ! -s "$ACT" ] && ok "DRY_RUN performs zero mutations" || bad "DRY_RUN mutated beads"
  echo ""; echo "lifecycle-coherence-janitor selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep
