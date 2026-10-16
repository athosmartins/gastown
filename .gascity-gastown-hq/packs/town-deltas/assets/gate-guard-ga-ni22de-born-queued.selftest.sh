#!/usr/bin/env bash
# gate-guard-ga-ni22de-born-queued.selftest.sh — Prove the ga-ni22de fix: a gate
# marker BORN gate-status:queued (never claimed by quality-gate-guard.sh) is sent
# to gate-status:error with a reason, and a gate-status:ready marker keeps taking
# the normal flow.
#
# THE DEFECT: docs/gate-marker-recipe.md told builders to create the marker with
# `gate-status:queued`, and the dispatcher's repair text told its dogs to follow
# that recipe and promised "o guard supersede o marker antigo sozinho (Step 4b)".
# The guard only DISCOVERS `ready` (Step 1), so a marker born `queued` skipped the
# E11 size cap, the Step 4b dedup/supersede, the A/B base test and the bash-3.2
# check, and went straight to the dispatcher unvetted. The promise was false.
#
# What it pins:
#   1. The recipe's label loop writes gate-status:ready, never queued; the
#      dispatcher's repair text says the new marker is born ready.
#   2. gate_born_queued_ids (pure): a marker is "born queued" iff it is open, has
#      exactly one gate-status label (queued), and has NEITHER gate.state_since NOR
#      gate.submitted_by. Anything else — ready, claimed+queued (Step 7's own
#      window), error, closed, stamped either way, odd metadata — is not listed; an
#      unreadable list is a non-zero exit, never an empty "none found".
#   3. The live Step 0d block (extracted from the guard between its
#      SELFTEST-EXTRACT sentinels, run under the guard's `set -euo pipefail`
#      against a stateful fake `bd` and the guard's REAL set_gate_status):
#      the born-queued marker ends with ONE gate-status label, error, and ONE
#      comment that opens with the watchdog's guard-rejected prefix (ga-hp4wrx) and
#      names the reason and the fix; ready / stamped / mid-park markers are left
#      alone; the guard's Step 1 query still selects the ready marker and not the
#      rejected one; a second sweep does nothing more.
#   4. Fail-inert: list failing / empty / not JSON / not an array, and a `bd show`
#      re-check that fails, is unreadable, or shows a stamp the list did not — in
#      every case NO label and NO comment is written and the sweep still exits 0.
#
# Runs under PATH bash AND /bin/bash 3.2 (the interpreter launchd uses) — keep it
# 3.2-clean. Exit 0 iff every assertion holds.
# Negative control: GATE_GUARD_UNDER_TEST=<the guard as of the commit before this
# fix> (git show <rev>:<path>) — section 0 finds no Step 0d block and sections 1-2
# fail. Run it by hand when editing; also drop the submitted_by / single-label
# conditions or the bd-show re-check from a copy of the guard — the matching
# assertions below must FAIL.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GATE_GUARD_UNDER_TEST:-$SELF_DIR/quality-gate-guard.sh}"
DISPATCHER="${GATE_DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
RECIPE="${GATE_RECIPE_UNDER_TEST:-$SELF_DIR/../../../docs/gate-marker-recipe.md}"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }
# has <label> <file> <fixed-string>: the string must be in the file.
has()   { grep -F -- "$3" "$2" >/dev/null 2>&1 && ok "$1" || bad "$1 — '$3' not in: $(tr '\n' '|' < "$2" | cut -c1-300)"; }
lacks() { grep -F -- "$3" "$2" >/dev/null 2>&1 && bad "$1 — '$3' unexpectedly in: $(tr '\n' '|' < "$2" | cut -c1-300)" || ok "$1"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq missing"; exit 1; }

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # sourcing the guard leaks its `set -e` into this shell (same as the siblings)

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/gate-ni22de-selftest.XXXXXX") || { echo "FATAL: no scratch dir"; exit 1; }
case "$TMPD" in /?*) ;; *) echo "FATAL: unusable scratch path '$TMPD'"; exit 1 ;; esac
finish() {
  if command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$TMPD" >/dev/null 2>&1; then safe-clean "$TMPD" >/dev/null 2>&1
  else
    # safe-clean refuses $TMPDIR (/var/folders/…). The dir is flat — only files this
    # run wrote — so remove those by name and rmdir it: no recursive delete.
    rm -f "${TMPD:?}"/* >/dev/null 2>&1
    rmdir "${TMPD:?}" >/dev/null 2>&1 || echo "(scratch dir left behind: $TMPD — not empty and safe-clean does not cover this location)"
  fi
}
trap finish EXIT

LOGF="$TMPD/log.txt"
CALLS="$TMPD/calls.txt"
COMMENTS="$TMPD/comments.txt"
STORE="$TMPD/store.json"
OUTF="$TMPD/out.txt"
: > "$LOGF"; : > "$CALLS"; : > "$COMMENTS"; echo '[]' > "$STORE"

# Stubs for what the live block calls. log/warn/err are defined BELOW the guard's
# GATE_GUARD_LIB_ONLY cutoff, so lib-only sourcing never defines them.
log()  { echo "LOG $*" >> "$LOGF"; }
warn() { echo "WARN $*" >> "$LOGF"; }
err()  { echo "ERR $*" >> "$LOGF"; }

# ── a stateful fake bd ───────────────────────────────────────────────────────
# LIST_MODE: ok | fail | empty | garbage | object      SHOW_MODE: ok | fail | garbage | stamped
LIST_MODE=ok
SHOW_MODE=ok
bd() {
  if [ "${1:-}" = "-C" ]; then shift 2; fi
  local cmd="${1:-}"
  [ "$#" -gt 0 ] && shift
  echo "BD $cmd $*" >> "$CALLS"
  local tmp="$STORE.tmp" a prev want
  case "$cmd" in
    list)
      case "$LIST_MODE" in
        fail)    return 1 ;;
        empty)   return 0 ;;
        garbage) echo "boom: this is not json"; return 0 ;;
        object)  echo '{"issues": []}'; return 0 ;;
      esac
      want='[]'; prev=""
      for a in "$@"; do
        [ "$prev" = "-l" ] && want=$(printf '%s' "$want" | jq -c --arg l "$a" '. + [$l]')
        prev="$a"
      done
      jq -c --argjson want "$want" \
        '[ .[] | select(.status == "open") | select(.labels as $l | $want | all(. as $w | $l | index($w) != null)) ]' "$STORE"
      ;;
    show)
      case "$SHOW_MODE" in
        fail)    return 1 ;;
        garbage) echo "boom: this is not json"; return 0 ;;
        stamped) jq -c --arg id "$1" '[ .[] | select(.id == $id) | .metadata["gate.state_since"] = "claimed@1" ]' "$STORE"; return 0 ;;
      esac
      jq -c --arg id "$1" '[ .[] | select(.id == $id) ]' "$STORE"
      ;;
    label)
      case "$1" in
        add)    jq -c --arg id "$2" --arg l "$3" 'map(if .id == $id and ((.labels | index($l)) == null) then .labels += [$l] else . end)' "$STORE" > "$tmp" && mv "$tmp" "$STORE" ;;
        remove) jq -c --arg id "$2" --arg l "$3" 'map(if .id == $id then .labels -= [$l] else . end)' "$STORE" > "$tmp" && mv "$tmp" "$STORE" ;;
      esac
      ;;
    comment) printf '%s\t%s\n' "$1" "$2" >> "$COMMENTS" ;;
    *) ;;
  esac
  return 0
}

# mk <id> <labels,csv> <metadata-json> [status] → one `bd list --json` element
mk() {
  jq -cn --arg id "$1" --arg labels "$2" --argjson md "$3" --arg st "${4:-open}" \
    '{id:$id, status:$st, labels:($labels | split(",")), metadata:$md}'
}
# seed <element>... → the fake store
seed() { local e; for e in "$@"; do printf '%s\n' "$e"; done | jq -cs . > "$STORE"; }
# labels_of <id> → sorted, comma-joined
labels_of() { jq -r --arg id "$1" '.[] | select(.id == $id) | .labels | sort | join(",")' "$STORE"; }
ncomments() { wc -l < "$COMMENTS" | tr -d ' '; }

TYPE="type:quality-gate-marker"
SS='{"gate.state_since":"claimed@1760000000"}'
SB='{"gate.submitted_by":"wa-worker"}'
BOTH='{"gate.state_since":"claimed@1760000000","gate.submitted_by":"wa-worker"}'

# ── 0. the live pieces can be found ──────────────────────────────────────────
echo "── 0. the recipe, the dispatcher text and the guard block are in place ──"
BLK="$TMPD/born-queued-block.sh"
sed -n '/# SELFTEST-EXTRACT born-queued-sweep: BEGIN/,/# SELFTEST-EXTRACT born-queued-sweep: END/p' "$GUARD" > "$BLK"
STEP1="$TMPD/step1.sh"
awk '/^MARKERS_JSON=\$\(bd -C/,/echo "\[\]"\)$/' "$GUARD" > "$STEP1"

[ -f "$RECIPE" ] && ok "recipe found" || bad "recipe not found at $RECIPE"
RLOOP=$(grep -n -A1 -E '^for L in type:quality-gate-marker' "$RECIPE" 2>/dev/null | tr '\n' ' ')
case "$RLOOP" in
  *"gate-status:ready"*) ok "recipe label loop writes gate-status:ready" ;;
  *) bad "recipe label loop does not write gate-status:ready — '$RLOOP'" ;;
esac
case "$RLOOP" in
  *"gate-status:queued"*) bad "recipe label loop still writes gate-status:queued — '$RLOOP'" ;;
  *) ok "recipe label loop does not write gate-status:queued" ;;
esac
has "dispatcher repair text says the new marker is born ready" "$DISPATCHER" "NASCE com gate-status:ready"
lacks "dispatcher repair text no longer promises a bare 'o guard supersede o marker antigo sozinho'" "$DISPATCHER" "O guard supersede o marker antigo sozinho (Step 4b). Não mexa"

if [ -s "$BLK" ]; then ok "Step 0d block found between its SELFTEST-EXTRACT sentinels ($(wc -l < "$BLK" | tr -d ' ') lines)"
else bad "Step 0d SELFTEST-EXTRACT sentinels not found in $GUARD"; fi
[ -s "$STEP1" ] && ok "Step 1 query found" || bad "Step 1 'MARKERS_JSON=\$(bd -C' statement not found in $GUARD"
if [ "$(type -t gate_born_queued_ids)" = "function" ]; then ok "gate_born_queued_ids is defined by the guard's lib region"
else bad "gate_born_queued_ids is not defined by the guard"; fi
if [ ! -s "$BLK" ] || [ "$(type -t gate_born_queued_ids)" != "function" ] || [ ! -s "$STEP1" ]; then
  echo "  PASS=$PASS  FAIL=$FAIL"; echo "  RESULT: FAIL"; exit 1
fi
has "the block's refusal opens with the guard-rejected prefix, in the literal comment \"\$MARKER_ID\" shape (ga-hp4wrx)" \
  "$BLK" 'comment "$MARKER_ID" "Gate guard rejected marker: born gate-status:queued'

# ── 1. the pure decision ─────────────────────────────────────────────────────
echo "── 1. gate_born_queued_ids: who is 'born queued' ──"
ids() { gate_born_queued_ids "$1" | tr '\n' ' ' | sed 's/ $//'; }
list() { printf '%s\n' "$@" | jq -cs .; }

eq "queued, no stamps (metadata {}) → listed" "$(ids "$(list "$(mk b1 "$TYPE,gate-status:queued" '{}')")")" "b1"
eq "queued, metadata missing altogether → listed" \
  "$(ids '[{"id":"b2","status":"open","labels":["type:quality-gate-marker","gate-status:queued"]}]')" "b2"
eq "queued, both stamps present but EMPTY strings → listed" \
  "$(ids "$(list "$(mk b3 "$TYPE,gate-status:queued" '{"gate.state_since":"","gate.submitted_by":""}')")")" "b3"
eq "queued + gate.state_since → NOT listed (went through the claim)" "$(ids "$(list "$(mk v1 "$TYPE,gate-status:queued" "$SS")")")" ""
eq "queued + gate.submitted_by only → NOT listed (went through Step 7)" "$(ids "$(list "$(mk v2 "$TYPE,gate-status:queued" "$SB")")")" ""
eq "queued + both stamps → NOT listed" "$(ids "$(list "$(mk v3 "$TYPE,gate-status:queued" "$BOTH")")")" ""
eq "ready, no stamps → NOT listed (that is the normal flow)" "$(ids "$(list "$(mk r1 "$TYPE,gate-status:ready" '{}')")")" ""
eq "queued + claimed, no stamps (Step 7 add-before-remove window) → NOT listed" \
  "$(ids "$(list "$(mk w1 "$TYPE,gate-status:queued,gate-status:claimed" '{}')")")" ""
eq "queued + error (ambiguous) → NOT listed" "$(ids "$(list "$(mk a1 "$TYPE,gate-status:queued,gate-status:error" '{}')")")" ""
eq "no gate-status label at all → NOT listed" "$(ids "$(list "$(mk n1 "$TYPE" '{}')")")" ""
eq "closed queued marker → NOT listed" "$(ids "$(list "$(mk c1 "$TYPE,gate-status:queued" '{}' closed)")")" ""
eq "metadata that is not an object → NOT listed (cannot tell)" \
  "$(ids '[{"id":"o1","status":"open","labels":["gate-status:queued"],"metadata":"oops"}]')" ""
eq "mixed list → only the born-queued ids, in order" \
  "$(ids "$(list "$(mk b1 "$TYPE,gate-status:queued" '{}')" "$(mk v1 "$TYPE,gate-status:queued" "$SS")" "$(mk b4 "$TYPE,gate-status:queued" '{"other":"x"}')" "$(mk r1 "$TYPE,gate-status:ready" '{}')")")" "b1 b4"

gate_born_queued_ids '[]' >"$OUTF" 2>/dev/null; RC=$?
eq "'[]' → exit 0 (read fine)" "$RC" "0"
eq "'[]' → no output" "$(wc -c < "$OUTF" | tr -d ' ')" "0"
for BADIN in "" "   " "not json" '{"a":1}' 'null' '"str"'; do
  gate_born_queued_ids "$BADIN" >"$OUTF" 2>/dev/null; RC=$?
  [ "$RC" != "0" ] && ok "unreadable input '$BADIN' → non-zero exit (not 'none found')" || bad "unreadable input '$BADIN' → exit 0 (reads as 'none found')"
  eq "unreadable input '$BADIN' → no ids" "$(wc -c < "$OUTF" | tr -d ' ')" "0"
done

# run_sweep → rc; the block runs in a subshell under the guard's real `set -euo pipefail`.
run_sweep() {
  : > "$LOGF"; : > "$CALLS"; : > "$COMMENTS"
  ( set -euo pipefail
    GC_CITY="$TMPD/no-city"
    . "$BLK" ) >"$OUTF" 2>&1
  return $?
}

# ── 2. the live block: the criterion of the bead ─────────────────────────────
echo "── 2. Step 0d: born queued → error with a reason; ready → normal flow ──"
LIST_MODE=ok; SHOW_MODE=ok
seed "$(mk m-born "$TYPE,gate-status:queued,branch:fix/x" '{}')" \
     "$(mk m-ready "$TYPE,gate-status:ready,branch:fix/y" '{}')" \
     "$(mk m-vetted "$TYPE,gate-status:queued" "$BOTH")" \
     "$(mk m-since "$TYPE,gate-status:queued" "$SS")" \
     "$(mk m-sub "$TYPE,gate-status:queued" "$SB")" \
     "$(mk m-window "$TYPE,gate-status:queued,gate-status:claimed" '{}')"
run_sweep; RC=$?
eq "sweep exits 0" "$RC" "0"
eq "born-queued marker: exactly ONE gate-status label, and it is error" "$(labels_of m-born)" "branch:fix/x,gate-status:error,type:quality-gate-marker"
eq "ready marker: untouched" "$(labels_of m-ready)" "branch:fix/y,gate-status:ready,type:quality-gate-marker"
eq "queued + both stamps: untouched" "$(labels_of m-vetted)" "gate-status:queued,type:quality-gate-marker"
eq "queued + gate.state_since: untouched" "$(labels_of m-since)" "gate-status:queued,type:quality-gate-marker"
eq "queued + gate.submitted_by: untouched" "$(labels_of m-sub)" "gate-status:queued,type:quality-gate-marker"
eq "queued + claimed (mid-park): untouched" "$(labels_of m-window)" "gate-status:claimed,gate-status:queued,type:quality-gate-marker"
eq "exactly one comment was written" "$(ncomments)" "1"
case "$(cut -f1 "$COMMENTS")" in m-born) ok "…and it is on the born-queued marker" ;; *) bad "comment is on '$(cut -f1 "$COMMENTS")', want m-born" ;; esac
CTEXT="$TMPD/comment-text.txt"; cut -f2- "$COMMENTS" > "$CTEXT"
case "$(cat "$CTEXT")" in "Gate guard rejected marker:"*) ok "…it OPENS with the watchdog's guard-rejected prefix, so it is never auto-requeued (ga-hp4wrx)" ;; *) bad "comment does not open with the guard-rejected prefix: $(cut -c1-120 "$CTEXT")" ;; esac
has "…it names the reason (no claim / skipped checks)" "$CTEXT" "never went through the guard's claim"
has "…it names the missing stamps" "$CTEXT" "gate.state_since"
has "…it says what to create instead" "$CTEXT" "gate-status:ready"
has "…it gives the resubmit command for THIS marker" "$CTEXT" "label add m-born gate-status:ready"
has "…it names the bead" "$CTEXT" "ga-ni22de"
has "log records the rejection" "$LOGF" "marker m-born was born gate-status:queued"
lacks "no warning on the clean path" "$LOGF" "WARN"

# Step 1 — the guard's own discovery query — still picks the ready marker and not the rejected one.
S1=$( ( set -euo pipefail; GC_CITY="$TMPD/no-city"; . "$STEP1"; printf '%s\n' "$MARKERS_JSON" | jq -r '[.[].id] | join(",")' ) 2>/dev/null )
eq "Step 1 discovery now returns the ready marker only (the born-queued one is gone from the queue)" "$S1" "m-ready"

# idempotent
run_sweep; RC=$?
eq "second sweep exits 0" "$RC" "0"
eq "second sweep writes no further comment" "$(ncomments)" "0"
eq "second sweep: the rejected marker stays error" "$(labels_of m-born)" "branch:fix/x,gate-status:error,type:quality-gate-marker"
has "second sweep says there is nothing to reject" "$LOGF" "no marker born gate-status:queued"

# ── 3. fail-inert ────────────────────────────────────────────────────────────
echo "── 3. Step 0d fails INERT: nothing is written when it cannot be sure ──"
BORN_BEFORE="branch:fix/x,gate-status:queued,type:quality-gate-marker"
reseed() { seed "$(mk m-born "$TYPE,gate-status:queued,branch:fix/x" '{}')" "$(mk m-ready "$TYPE,gate-status:ready" '{}')"; }
inert() { # <label> <expected warn fragment>
  run_sweep; local rc=$?
  eq "$1: sweep exits 0" "$rc" "0"
  eq "$1: the born-queued marker is untouched" "$(labels_of m-born)" "$BORN_BEFORE"
  eq "$1: the ready marker is untouched" "$(labels_of m-ready)" "gate-status:ready,type:quality-gate-marker"
  eq "$1: no comment written" "$(ncomments)" "0"
  lacks "$1: no label write was attempted" "$CALLS" "BD label"
  has "$1: says so, distinct from 'none found'" "$LOGF" "$2"
  lacks "$1: does NOT log the clean 'no marker born' outcome" "$LOGF" "no marker born gate-status:queued"
}
SHOW_MODE=ok
LIST_MODE=fail;    reseed; inert "bd list fails"          "born-queued check SKIPPED"
LIST_MODE=empty;   reseed; inert "bd list prints nothing" "born-queued check SKIPPED"
LIST_MODE=garbage; reseed; inert "bd list prints garbage" "born-queued check SKIPPED"
LIST_MODE=object;  reseed; inert "bd list prints an object, not an array" "born-queued check SKIPPED"
LIST_MODE=ok
SHOW_MODE=fail;    reseed; inert "bd show re-check fails"        "did not confirm it"
SHOW_MODE=garbage; reseed; inert "bd show re-check is unreadable" "did not confirm it"
SHOW_MODE=stamped; reseed; inert "bd show re-check finds a stamp the list did not" "did not confirm it"
SHOW_MODE=ok

# ── 4. the fix is the guard's ────────────────────────────────────────────────
echo "── 4. the rejected marker really is the one Step 1 would never have claimed ──"
# The reason this sweep exists: Step 1 selects only `ready`. A queued marker is invisible to it.
case "$(cat "$STEP1")" in
  *"-l gate-status:ready"*) ok "Step 1 selects gate-status:ready" ;;
  *) bad "Step 1 no longer selects gate-status:ready" ;;
esac
case "$(cat "$STEP1")" in
  *"gate-status:queued"*) bad "Step 1 selects gate-status:queued too — the premise of this sweep changed" ;;
  *) ok "Step 1 does not select gate-status:queued" ;;
esac

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
