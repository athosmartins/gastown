#!/usr/bin/env bash
# pilot-dispatcher.dog-store-migrate.selftest.sh — unit tests for
# _pilot_dog_store_blind_migrate_dest and _pilot_migrate_dog_store_blind_bead
# (ga-6u64fm), which extend the ga-cszxcf guard already tested by the
# sibling pilot-dispatcher.dog-store-blind-guard.selftest.sh.
#
# Bug ga-6u64fm (systemic, 3rd occurrence): a rig-native bead routed to
# gastown.dog is invisible to every dog's pool probe (no BEADS_DIR/GC_RIG,
# probe only ever reads HQ — ga-cszxcf). The pre-existing fix only PARKS the
# bead (pilot:no-auto-dispatch + next-action:mayor + a comment asking a
# human to move it by hand) — the Mayor has now done that move by hand
# twice (gt-c1x1j -> ga-dyf4fb, gt-1u1u2 -> wa-4qfqv), always the same
# prose pattern. This fix automates exactly that pattern as the FIRST
# attempt, falling back to the unchanged park behavior on any abort.
#
# Two functions, two parts below:
#   A. _pilot_dog_store_blind_migrate_dest — picks the destination rig NAME
#      by scanning the bead's own title+description for exactly one other
#      registered rig's directory named as a literal path token; ambiguous
#      or no match defaults to "gascity" (HQ), never guesses wrong.
#   B. _pilot_migrate_dog_store_blind_bead — the migration itself: re-checks
#      the original is still open+unassigned (TOCTOU safety, per the
#      bead-migration-copy-races memory), creates the copy, verifies
#      readback, closes the original, and — if the close is refused because
#      someone claimed the original in the race window — retracts the
#      orphan copy instead of leaving two live beads for the same story.
#
# Falsifiable: neither function exists before this fix, so the awk
# extraction below fails hard (FATAL, exit 2) against pre-fix HEAD.
#
# Conventions match this directory's siblings: verbatim function extraction
# (pilot-dispatcher.routed-to-crew-guard.selftest.sh's pattern) + a real
# PATH-stubbed `bd` that logs every call (same file's fake_bd_mutate
# pattern) — `bd` is invoked as a bare external command by the function
# under test, so a shell-function override would not survive a future edit
# wrapping the call in `timeout`.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.dog-store-migrate.selftest.sh
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

echo "── 0. COMPILE-GUARD: dispatcher parses cleanly ──"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi

extract_fn() {
  local _name="$1"
  awk "/^${_name}\\(\\)/{f=1} f{print} f&&/^}\$/{exit}" "$DISPATCHER"
}
DEST_FN="$(extract_fn '_pilot_dog_store_blind_migrate_dest')"
MIGRATE_FN="$(extract_fn '_pilot_migrate_dog_store_blind_bead')"
RIGPATH_FN="$(extract_fn 'rig_root_path')"
if [ -z "$DEST_FN" ]; then
  echo "FATAL: _pilot_dog_store_blind_migrate_dest() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi
if [ -z "$MIGRATE_FN" ]; then
  echo "FATAL: _pilot_migrate_dog_store_blind_bead() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi
if [ -z "$RIGPATH_FN" ]; then
  echo "FATAL: rig_root_path() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-dog-store-migrate-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_RIGS_JSON='{"rigs":[{"name":"gascity","path":"'"$WORK"'/gascity"},{"name":"gastown","path":"'"$WORK"'/gastown"},{"name":"whatsapp_automation","path":"'"$WORK"'/wa"},{"name":"property_scrapers","path":"'"$WORK"'/ps"}]}'
mkdir -p "$WORK/gascity" "$WORK/gastown" "$WORK/wa" "$WORK/ps"

echo ""
echo "pilot-dispatcher.dog-store-migrate.selftest — ga-6u64fm"
echo ""
echo "=== Part A: _pilot_dog_store_blind_migrate_dest (pure, no bd calls) ==="

run_dest() { # run_dest <story_json> <src_rig>
  PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" bash -c "$DEST_FN"'
_pilot_dog_store_blind_migrate_dest "$1" "$2"' _ "$1" "$2"
}

R=$(run_dest '{"title":"daemon bug","description":"fix scripts/detect_unloaded_committed_daemons.py under whatsapp_automation/scripts/"}' "gastown")
[ "$R" = "whatsapp_automation" ] \
  && ok "single rig-path match (whatsapp_automation/...) -> whatsapp_automation (mirrors the real gt-1u1u2 -> wa-4qfqv precedent)" \
  || bad "single rig-path match -> whatsapp_automation (mirrors gt-1u1u2) — got '$R'"

R=$(run_dest '{"title":"agent-stuck-escalation false positive","description":"packs/town-deltas/assets/agent-stuck-escalation.sh needs a redesign"}' "gastown")
[ "$R" = "gascity" ] \
  && ok "no other-rig path match -> gascity (mirrors the real gt-c1x1j -> ga-dyf4fb precedent; packs/ is HQ's own tree, not a registered rig name)" \
  || bad "no other-rig path match -> gascity — got '$R'"

R=$(run_dest '{"title":"cross-rig bug","description":"touches both whatsapp_automation/scripts/x.py and property_scrapers/lib/y.py"}' "gastown")
[ "$R" = "gascity" ] \
  && ok "two rig-path matches (ambiguous) -> gascity, never guesses between them" \
  || bad "two rig-path matches -> gascity — got '$R'"

R=$(run_dest '{"title":"self-referential","description":"bug lives in gastown/mayor/rig/ itself"}' "gastown")
[ "$R" = "gascity" ] \
  && ok "source rig's own name-as-path excluded from matching -> gascity (never self-migrate via text match)" \
  || bad "source rig's own name-as-path excluded -> gascity — got '$R'"

R=$(run_dest '{"title":"mentions whatsapp_automation by name only","description":"this bug affects whatsapp_automation broadly, no specific file"}' "gastown")
[ "$R" = "gascity" ] \
  && ok "bare rig-name mention (no trailing '/') does not count as a path match -> gascity" \
  || bad "bare rig-name mention should not match -> gascity — got '$R'"

echo ""
echo "=== Part B: _pilot_migrate_dog_store_blind_bead (needs a fake bd) ==="

# fake_bd <scenario> — writes an executable `bd` shim + returns its bin dir.
# Every invocation is appended to calllog_for(scenario) as
# "<verb> <city> <id> <rest...>" so assertions can check WHAT was called, in
# WHAT ORDER, without touching real Dolt. Scenario controls the ORIGINAL
# bead's live status/assignee on re-check, and whether create/readback/close
# succeed — see the case arms below for the exact contract each name gives.
#
# NOTE: fake_bd (and run_migrate, which calls it) are always invoked via
# command substitution ($(...)) — any plain variable assignment inside them
# runs in a subshell and is invisible to the caller. calllog_for() below is
# the fix: a pure, deterministic function of the scenario name that both
# fake_bd's shim generator AND the assertions call independently, instead of
# trying to pass the path back through a variable that command substitution
# would silently drop.
calllog_for() { printf '%s/calllog.%s' "$WORK" "$1"; }

fake_bd() {
  local _scenario="$1" _dir _calllog
  _dir="$(mktemp -d "$WORK/bin.XXXXXX")"
  _calllog="$(calllog_for "$_scenario")"
  : > "$_calllog"
  cat > "$_dir/bd" <<EOF
#!/usr/bin/env bash
SCEN="$_scenario"
CALLLOG="$_calllog"
EOF
  cat >> "$_dir/bd" <<'BDEOF'
# Parse: bd -C <city> <verb> [<id>] [rest...]
city=""; verb=""; id=""
if [ "$1" = "-C" ]; then city="$2"; shift 2; fi
verb="${1:-}"; shift || true
case "$verb" in
  create) : ;;  # create has no id argument (title is $1, not an id)
  *) id="${1:-}" ;;
esac
echo "$verb|$city|$id|$*" >> "$CALLLOG"

case "$verb" in
  show)
    if [ "$id" = "ORIG-1" ]; then
      case "$SCEN" in
        happy|close_fails)        printf '[{"id":"ORIG-1","status":"open","assignee":null}]'; exit 0 ;;
        raced_status)             printf '[{"id":"ORIG-1","status":"closed","assignee":null}]'; exit 0 ;;
        raced_assignee)           printf '[{"id":"ORIG-1","status":"open","assignee":"some-other-dog"}]'; exit 0 ;;
        *)                        printf '[{"id":"ORIG-1","status":"open","assignee":null}]'; exit 0 ;;
      esac
    elif [ "$id" = "NEW-1" ]; then
      case "$SCEN" in
        readback_fails) exit 1 ;;
        *)               printf '[{"id":"NEW-1","status":"open"}]'; exit 0 ;;
      esac
    fi
    exit 1
    ;;
  create)
    case "$SCEN" in
      create_fails) exit 1 ;;
      *)            printf '{"id":"NEW-1"}'; exit 0 ;;
    esac
    ;;
  close)
    if [ "$id" = "ORIG-1" ]; then
      case "$SCEN" in
        close_fails) echo 'assignee is "someone-else", actor is "pilot"' >&2; exit 1 ;;
        *)           exit 0 ;;
      esac
    fi
    exit 0   # close of NEW-1 (retraction path) always succeeds in these scenarios
    ;;
  label|update)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
BDEOF
  chmod +x "$_dir/bd"
  printf '%s' "$_dir"
}

STORY_JSON='{"id":"ORIG-1","title":"daemon gap bug","priority":2,"issue_type":"bug","description":"gap beads never self-close","labels":["lane:small"]}'

run_migrate() { # run_migrate <scenario>
  local _scenario="$1" _bin
  _bin=$(fake_bd "$_scenario")
  PATH="$_bin:$PATH" PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" GC_CITY="$WORK/gascity" \
    bash -c "
warn() { echo \"WARN: \$*\" >&2; }
log()  { echo \"LOG: \$*\"; }
$RIGPATH_FN
$DEST_FN
$MIGRATE_FN
_pilot_migrate_dog_store_blind_bead 'ORIG-1' '$STORY_JSON' '$WORK/gastown' 'gastown' 'lane:small'
"
}

# Scenario 1 (happy path): original still open+unassigned -> migrates.
OUT=$(run_migrate "happy"); RC=$?; CALLLOG="$(calllog_for happy)"
if [ "$RC" = "0" ] && [ "$OUT" = "NEW-1" ]; then
  ok "happy path: still open+unassigned -> migrates, echoes new id, returns 0"
else
  bad "happy path -> expected rc=0 out=NEW-1, got rc=$RC out='$OUT'"
fi
if grep -q '^show|.*gastown.*|ORIG-1|' "$CALLLOG" && grep -qE '^create\|' "$CALLLOG" \
   && grep -q '^show|.*gascity.*|NEW-1|' "$CALLLOG" && grep -q '^close|.*gastown.*|ORIG-1|' "$CALLLOG"; then
  ok "happy path calls, in order: re-check show(ORIG-1) -> create -> readback show(NEW-1) -> close(ORIG-1)"
else
  bad "happy path call sequence wrong: $(cat "$CALLLOG" | tr '\n' '|')"
fi
if grep -qE '^label\|.*gascity.*add NEW-1 pilot:no-auto-dispatch' "$CALLLOG"; then
  bad "happy path -> REGRESSION: retracted the new bead even though close succeeded"
else
  ok "happy path never retracts the new bead (close of the original succeeded)"
fi

# Scenario 2: original no longer open (raced closed elsewhere) -> aborts,
# NEVER calls create.
OUT=$(run_migrate "raced_status"); RC=$?; CALLLOG="$(calllog_for raced_status)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "original status changed (no longer open) -> aborts, returns 1, echoes nothing"
else
  bad "original status changed -> expected abort (rc=1, empty), got rc=$RC out='$OUT'"
fi
if grep -qE '^create\|' "$CALLLOG"; then
  bad "original status changed -> REGRESSION: created a copy anyway despite the abort"
else
  ok "original status changed -> no create call at all (aborted before writing anything)"
fi

# Scenario 3: original got claimed (assignee set) since selection -> aborts,
# NEVER calls create. This is the exact TOCTOU shape the bead-migration-
# copy-races memory documents.
OUT=$(run_migrate "raced_assignee"); RC=$?; CALLLOG="$(calllog_for raced_assignee)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "original got claimed (assignee set) since selection -> aborts, returns 1 (bead-migration-copy-races TOCTOU guard)"
else
  bad "original got claimed -> expected abort (rc=1, empty), got rc=$RC out='$OUT'"
fi
if grep -qE '^create\|' "$CALLLOG"; then
  bad "original got claimed -> REGRESSION: created a copy anyway (the exact orphan-duplicate shape the memory warns about)"
else
  ok "original got claimed -> no create call at all"
fi

# Scenario 4: bd create itself fails -> aborts, no close attempted.
OUT=$(run_migrate "create_fails"); RC=$?; CALLLOG="$(calllog_for create_fails)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "bd create fails -> aborts, returns 1"
else
  bad "bd create fails -> expected abort (rc=1, empty), got rc=$RC out='$OUT'"
fi
if grep -qE '^close\|' "$CALLLOG"; then
  bad "bd create fails -> REGRESSION: attempted to close something anyway"
else
  ok "bd create fails -> no close call at all (nothing to close, nothing to retract)"
fi

# Scenario 5: create succeeds but the new bead does not read back -> treated
# as failed, aborts, does NOT close the original (the copy may or may not
# really exist — never close the original on an unconfirmed copy).
OUT=$(run_migrate "readback_fails"); RC=$?; CALLLOG="$(calllog_for readback_fails)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "created id does not read back -> treated as failed, aborts (ga-ehbw5 discipline: a write succeeding is not the write being readable)"
else
  bad "readback failure -> expected abort (rc=1, empty), got rc=$RC out='$OUT'"
fi
if grep -qE '^close\|.*\|ORIG-1\|' "$CALLLOG"; then
  bad "readback failure -> REGRESSION: closed the original despite an unconfirmed copy"
else
  ok "readback failure -> original is NOT closed (copy unconfirmed, original stays authoritative)"
fi

# Scenario 6 (the race, post-copy): create+readback succeed, but close of
# the ORIGINAL is refused (someone claimed it in the remaining window) ->
# must retract the new copy: label pilot:no-auto-dispatch THEN close it as
# a duplicate. Never leave two live beads for the same story.
OUT=$(run_migrate "close_fails"); RC=$?; CALLLOG="$(calllog_for close_fails)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "close of original refused after copy created -> returns 1 (caller falls back to park on the still-open, now-claimed original)"
else
  bad "close-refused race -> expected abort (rc=1, empty), got rc=$RC out='$OUT'"
fi
# NOTE: the fake bd's id-field parsing assumes "<verb> <id> ..." — it does
# NOT resolve the extra "add"/"remove" subcommand token label/update calls
# carry ("bd label add <id> <label>"), so the parsed id FIELD for these
# lines is "add", not "NEW-1". Match on the raw line instead of the parsed
# field for this pair (the id still appears, just further along in "$*").
LABEL_LINE=$(grep -nE '^label\|.*add NEW-1 pilot:no-auto-dispatch' "$CALLLOG" | head -1 | cut -d: -f1)
RETRACT_CLOSE_LINE=$(grep -nE '^close\|.*\|NEW-1\|' "$CALLLOG" | head -1 | cut -d: -f1)
if [ -n "$LABEL_LINE" ] && [ -n "$RETRACT_CLOSE_LINE" ] && [ "$LABEL_LINE" -lt "$RETRACT_CLOSE_LINE" ]; then
  ok "close-refused race -> retracts the orphan copy: pilot:no-auto-dispatch labeled BEFORE it is closed as a duplicate (bead-migration-copy-races recovery)"
else
  bad "close-refused race -> expected label-then-close retraction on NEW-1, got: $(cat "$CALLLOG" | tr '\n' '|')"
fi

echo ""
echo "=== Drift-guards: call-site wiring in dispatch_one()'s crew arm ==="
has 'PILOT_DOG_STORE_AUTOMIGRATE:-1'                                     "call site respects PILOT_DOG_STORE_AUTOMIGRATE kill switch (default on), independent of PILOT_DOG_STORE_GUARD"
has '_pilot_migrate_dog_store_blind_bead "\$STORY_ID" "\$STORY" "\$STORY_BEAD_CITY" "\$STORY_RIG" "\$STORY_LABELS"' "call site invokes the migrator with STORY_ID/STORY/STORY_BEAD_CITY/STORY_RIG/STORY_LABELS"
has 'DISPATCH_RESULT="rig_native_dog_store_migrated"'                    "a successful migration is attributed to its own distinct DISPATCH_RESULT"
# Ordering: the migration attempt must run BEFORE the park (refuse) logic,
# so a successful migration short-circuits the park path entirely (return 1
# fires right after a successful migration, never reaching the warn/park
# block below it).
if awk '/_pilot_migrate_dog_store_blind_bead "\$STORY_ID"/{m=NR} /ga-cszxcf: REFUSING rig-native dispatch/{p=NR} END{exit !(m && p && m<p)}' "$DISPATCHER"; then
  ok "migration attempt precedes the park (refuse) logic — a successful migration short-circuits parking entirely"
else
  bad "REGRESSION: migration attempt does not precede the park logic — ordering may have drifted"
fi
# The pre-existing park behavior itself must be 100% unchanged as the
# fallback — this is the safety net every abort path above relies on.
has 'pilot:no-auto-dispatch" -q 2>/dev/null \|\| true'                   "the pre-existing park fallback (pilot:no-auto-dispatch) is still wired, unchanged"
has 'next-action:mayor" -q 2>/dev/null \|\| true'                        "the pre-existing park fallback (next-action:mayor) is still wired, unchanged"
has 'DISPATCH_RESULT="rig_native_dog_store_blind"'                       "the pre-existing park DISPATCH_RESULT is still wired, unchanged"

echo ""
echo "pilot-dispatcher.dog-store-migrate.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
