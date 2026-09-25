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
# Gate-review ga-tguml6 hardening (two blocking findings, both covered below):
#   - the destination must be a rig whose OWN builder reads its store — gastown,
#     lexbh and marketing map to gastown.dog, so migrating INTO them only
#     relocates the blindness and (the copy keeps the original text) ping-pongs
#     one bead per 5-minute sweep; the match on the bead's text is anchored on a
#     real path token (URLs / prose no longer count);
#   - one hop only: a story that already carries gc.migrated_from is parked, not
#     migrated again (snapshot AND live record; unreadable metadata refuses too).
#   The other blocking finding — the new DISPATCH_RESULT "rig_native_dog_store_
#   migrated" read as a Pilot fault — is classified in
#   pilot-dispatcher.sweep-event.selftest.sh (B4 + A2).
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
PATHTOK_FN="$(extract_fn '_pilot_text_names_rig_path')"
MIGRATED_FN="$(extract_fn '_pilot_story_already_migrated')"
GUARD_FN="$(extract_fn '_pilot_dog_store_blind_guard')"
BUILDERS_FN="$(extract_fn 'rig_to_builders')"
BUILDER_FN="$(extract_fn 'rig_to_builder')"
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
for _fn_var in PATHTOK_FN MIGRATED_FN GUARD_FN BUILDERS_FN BUILDER_FN; do
  if [ -z "${!_fn_var}" ]; then
    echo "FATAL: helper for $_fn_var not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
    exit 2
  fi
done
# Everything the two functions under test call, defined together so a sandbox can never
# silently lack one (a missing helper would degrade to the HQ default and pass by accident).
FN_PRELUDE="$RIGPATH_FN
$PATHTOK_FN
$MIGRATED_FN
$GUARD_FN
$BUILDERS_FN
$BUILDER_FN
$DEST_FN
$MIGRATE_FN"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-dog-store-migrate-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_RIGS_JSON='{"rigs":[{"name":"gascity","path":"'"$WORK"'/gascity"},{"name":"gastown","path":"'"$WORK"'/gastown"},{"name":"lexbh","path":"'"$WORK"'/lexbh"},{"name":"marketing","path":"'"$WORK"'/marketing"},{"name":"whatsapp_automation","path":"'"$WORK"'/wa"},{"name":"property_scrapers","path":"'"$WORK"'/ps"}]}'
mkdir -p "$WORK/gascity" "$WORK/gastown" "$WORK/lexbh" "$WORK/marketing" "$WORK/wa" "$WORK/ps"

echo ""
echo "pilot-dispatcher.dog-store-migrate.selftest — ga-6u64fm"
echo ""
echo "=== Part A: _pilot_dog_store_blind_migrate_dest (pure, no bd calls) ==="

run_dest() { # run_dest <story_json> <src_rig>
  PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" bash -c "warn() { echo \"WARN: \$*\" >&2; }
$FN_PRELUDE"'
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

# ── gate-review ga-tguml6, blocking issue 2 — the destination must be a store a builder READS ──
# rig_to_builders maps gastown, lexbh and marketing to gastown.dog, the builder whose probe cannot
# read a rig store. Each case below is one of the reviewer's executed repros (or its mirror image).
expect_dest() { # expect_dest <expected> <src_rig> <text> <description>
  local _exp="$1" _src="$2" _txt="$3" _desc="$4" _story _got
  _story=$(jq -cn --arg t "$_txt" '{title:"x",description:$t}')
  _got=$(run_dest "$_story" "$_src" 2>/dev/null)
  if [ "$_got" = "$_exp" ]; then ok "$_desc"; else bad "$_desc — expected '$_exp', got '$_got'"; fi
}
expect_dest gascity lexbh   'fix lexbh/scripts/x.py; see .gc/system/packs/gastown/agents/dog' \
  "repro (a): src=lexbh, text names gastown/ as a path -> gascity (gastown is dog-routed: not a valid destination)"
expect_dest gascity gastown 'fix lexbh/scripts/x.py; see .gc/system/packs/gastown/agents/dog' \
  "repro (a) mirror: same text, src=gastown -> gascity, NOT lexbh (the loop lexbh -> gastown -> lexbh is closed on both legs)"
expect_dest gascity gastown 'tune email marketing/ads copy' \
  "repro (b): 'marketing/' in prose -> gascity (marketing is dog-routed)"
expect_dest gascity gastown 'see github.com/athosmartins/lexbh/issues/9' \
  "repro (c): a github URL containing lexbh/ -> gascity"
expect_dest whatsapp_automation gastown 'touches lexbh/scripts/x.py and whatsapp_automation/scripts/y.py' \
  "a dog-routed rig named alongside a readable one is IGNORED, not counted as ambiguity -> the readable rig wins"
expect_dest whatsapp_automation gastown 'see .gc/worktrees/whatsapp_automation/scripts/x.py' \
  "a hidden-directory path (.gc/...) is a path, not a hostname -> whatsapp_automation (a leading '.' is not a TLD dot)"
expect_dest gascity gastown 'newrig/scripts/x.py' \
  "a rig name the routing table does not know is never a destination (rig_to_builders defaults it to the dog)"

# The anchor: the rig must be a path COMPONENT of a path-shaped token, not a substring of one.
expect_dest gascity gastown 'see https://github.com/athosmartins/whatsapp_automation/issues/9' \
  "a full URL naming a readable rig is not a path token -> gascity"
expect_dest gascity gastown 'see github.com/athosmartins/whatsapp_automation/issues/9' \
  "a bare host.tld/... URL naming a readable rig is not a path token -> gascity"
expect_dest gascity gastown 'git clone git@github.com:athosmartins/whatsapp_automation/x.git' \
  "an scp-style remote is not a path token -> gascity"
expect_dest gascity gastown 'the foo_whatsapp_automation/x.py helper is unrelated' \
  "a rig name that is only a SUFFIX of another word ('foo_whatsapp_automation/') does not match -> gascity"
expect_dest whatsapp_automation gastown 'bug in /Users/athos/gt/whatsapp_automation/scripts/x.py' \
  "an absolute path with the rig as a middle component matches -> whatsapp_automation"
expect_dest property_scrapers gastown 'bug in ~/gt/property_scrapers/lib/y.py' \
  "a ~/ path matches (the '~' is quoted in the case pattern; unquoted it would tilde-expand to \$HOME and never match) -> property_scrapers"
expect_dest whatsapp_automation gastown 'corrigir o erro em whatsapp_automation/scripts/x.py — não é urgente, ação simples' \
  "accented Portuguese around the token does not break tokenizing (LC_ALL=C tr) -> whatsapp_automation"
expect_dest whatsapp_automation gastown 'ver "whatsapp_automation/scripts/x.py", (linha 9)' \
  "quotes/parens/commas delimit the token -> whatsapp_automation"

# gc rig list failing must be ANNOUNCED, not silently read as "no other rig was named".
RIGFAIL_OUT=$(PILOT_RIG_PATHS_JSON="" bash -c "warn() { echo \"WARN: \$*\" >&2; }
gc_json_or_unknown() { return 1; }
GC_CITY=/nonexistent
$FN_PRELUDE"'
_pilot_dog_store_blind_migrate_dest "{\"title\":\"x\",\"description\":\"whatsapp_automation/scripts/x.py\"}" gastown' 2>&1)
case "$RIGFAIL_OUT" in
  *"could not list rigs"*gascity) ok "gc rig list failure -> destination defaults to gascity AND says why (not silent)" ;;
  *) bad "gc rig list failure -> expected a 'could not list rigs' WARN then 'gascity', got: $RIGFAIL_OUT" ;;
esac

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
        already_migrated_live)    printf '[{"id":"ORIG-1","status":"open","assignee":null,"metadata":{"gc.migrated_from":"PREV-0","gc.migrated_from_rig":"lexbh"}}]'; exit 0 ;;
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

run_migrate() { # run_migrate <scenario> [<story_json>]
  local _scenario="$1" _story="${2:-$STORY_JSON}" _bin
  _bin=$(fake_bd "$_scenario")
  PATH="$_bin:$PATH" PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" GC_CITY="$WORK/gascity" \
    bash -c "
warn() { echo \"WARN: \$*\" >&2; }
log()  { echo \"LOG: \$*\"; }
$FN_PRELUDE
_pilot_migrate_dog_store_blind_bead 'ORIG-1' '$_story' '$WORK/gastown' 'gastown' 'lane:small'
"
}

# run_migrate_cold <scenario> — same, but the rig-list memo starts EMPTY and `gc rig list` is a counting
# stub, so the number of times the migration pays for it (8-17s each under Dolt load) is observable.
GCLIST_COUNT="$WORK/gclist.count"
run_migrate_cold() {
  local _scenario="$1" _bin
  _bin=$(fake_bd "$_scenario")
  : > "$GCLIST_COUNT"
  PATH="$_bin:$PATH" PILOT_RIG_PATHS_JSON="" GC_CITY="$WORK/gascity" FAKE_RIGS_JSON="$FAKE_RIGS_JSON" GCLIST_COUNT="$GCLIST_COUNT" \
    bash -c "
warn() { echo \"WARN: \$*\" >&2; }
log()  { echo \"LOG: \$*\"; }
gc_json_or_unknown() { echo x >> \"\$GCLIST_COUNT\"; printf '%s' \"\$FAKE_RIGS_JSON\"; }
$FN_PRELUDE
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
# really exist — never close the original on an unconfirmed copy). But the
# create call may have actually landed with only the readback lagging, so
# the copy must be retracted too (label pilot:no-auto-dispatch THEN close),
# same as the close_fails race in Scenario 6 — otherwise an unconfirmed
# copy that DID land stays live and fully dispatchable forever.
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
READBACK_LABEL_LINE=$(grep -nE '^label\|.*add NEW-1 pilot:no-auto-dispatch' "$CALLLOG" | head -1 | cut -d: -f1)
READBACK_RETRACT_CLOSE_LINE=$(grep -nE '^close\|.*\|NEW-1\|' "$CALLLOG" | head -1 | cut -d: -f1)
if [ -n "$READBACK_LABEL_LINE" ] && [ -n "$READBACK_RETRACT_CLOSE_LINE" ] && [ "$READBACK_LABEL_LINE" -lt "$READBACK_RETRACT_CLOSE_LINE" ]; then
  ok "readback failure -> retracts the possibly-orphaned copy too: pilot:no-auto-dispatch labeled BEFORE it is closed (matches the close_fails race's retraction, gate-review ga-7tjx1r)"
else
  bad "readback failure -> expected label-then-close retraction on NEW-1 (an unconfirmed copy that actually landed must not stay live), got: $(cat "$CALLLOG" | tr '\n' '|')"
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

# ── gate-review ga-tguml6, blocking issue 2 — one hop only (gc.migrated_from) ──
# Scenario 7: the sweep SNAPSHOT already says this story is a migration's copy -> refuse before ANY bd call.
MIG_STORY='{"id":"ORIG-1","title":"daemon gap bug","priority":2,"issue_type":"bug","description":"gap","labels":[],"metadata":{"gc.migrated_from":"PREV-0","gc.migrated_from_rig":"lexbh"}}'
OUT=$(run_migrate "happy" "$MIG_STORY" 2>/dev/null); RC=$?; CALLLOG="$(calllog_for happy)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "already migrated (snapshot carries gc.migrated_from) -> refuses, returns 1, echoes nothing (caller parks)"
else
  bad "already migrated (snapshot) -> expected rc=1 empty, got rc=$RC out='$OUT'"
fi
if [ -s "$CALLLOG" ]; then
  bad "already migrated (snapshot) -> REGRESSION: it still called bd: $(tr '\n' '|' < "$CALLLOG")"
else
  ok "already migrated (snapshot) -> NO bd call at all (refused before reading or writing anything)"
fi

# Scenario 8: the snapshot is clean but the LIVE record carries the marker (a snapshot may omit metadata).
OUT=$(run_migrate "already_migrated_live" 2>/dev/null); RC=$?; CALLLOG="$(calllog_for already_migrated_live)"
if [ "$RC" = "1" ] && [ -z "$OUT" ]; then
  ok "already migrated (only the LIVE bd show carries gc.migrated_from) -> refuses, returns 1"
else
  bad "already migrated (live) -> expected rc=1 empty, got rc=$RC out='$OUT'"
fi
if grep -qE '^(create|close|label|update)\|' "$CALLLOG"; then
  bad "already migrated (live) -> REGRESSION: it wrote something: $(tr '\n' '|' < "$CALLLOG")"
else
  ok "already migrated (live) -> only the re-check read happened; no create/close/label/update"
fi

# Scenario 9: unreadable metadata is a THIRD state, and it must not collapse into 'no marker'.
BAD_META_STORY='{"id":"ORIG-1","title":"daemon gap bug","priority":2,"issue_type":"bug","description":"gap","labels":[],"metadata":"oops-a-string"}'
OUT=$(run_migrate "happy" "$BAD_META_STORY" 2>/dev/null); RC=$?
[ "$RC" = "1" ] && [ -z "$OUT" ] \
  && ok "metadata present but not an object (can't tell) -> refuses (inert), never treated as 'no marker'" \
  || bad "unreadable metadata -> expected refusal, got rc=$RC out='$OUT'"

# Scenario 10: refusing must not be over-broad — empty/unrelated metadata still migrates.
for _m in '{}' 'null' '{"pilot.dispatched_at":"1"}'; do
  _st=$(jq -cn --argjson m "$_m" '{id:"ORIG-1",title:"daemon gap bug",priority:2,issue_type:"bug",description:"gap",labels:[],metadata:$m}')
  OUT=$(run_migrate "happy" "$_st" 2>/dev/null); RC=$?
  [ "$RC" = "0" ] && [ "$OUT" = "NEW-1" ] \
    && ok "metadata=$_m (no gc.migrated_from) -> still migrates (the hop guard is not over-broad)" \
    || bad "metadata=$_m -> expected a normal migration, got rc=$RC out='$OUT'"
done

# Scenario 11: round trip — the marker the migration WRITES is the one the guard READS. A rename on
# either side would leave the guard matching nothing and the ping-pong open, with every other test green.
run_migrate "happy" >/dev/null 2>&1; CALLLOG="$(calllog_for happy)"
WRITTEN_META=$(grep -E '^create\|' "$CALLLOG" | head -1 | sed -n 's/.*--metadata \({[^ ]*}\).*/\1/p')
if [ -n "$WRITTEN_META" ] && printf '%s' "$WRITTEN_META" | jq -e 'has("gc.migrated_from")' >/dev/null 2>&1; then
  COPY_JSON=$(jq -cn --argjson m "$WRITTEN_META" '{id:"NEW-1",title:"t",metadata:$m}')
  if bash -c "$MIGRATED_FN"'
_pilot_story_already_migrated "$1"' _ "$COPY_JSON"; then
    ok "round trip: the metadata the migration stamps on a copy IS refused by _pilot_story_already_migrated"
  else
    bad "round trip: the copy's stamped metadata ($WRITTEN_META) is NOT recognised as already-migrated — writer/reader key drifted"
  fi
else
  bad "round trip: could not extract the --metadata JSON the migration passes to bd create (got '$WRITTEN_META')"
fi

# Scenario 12: the rig-list memo is warmed ONCE in the migration's own shell (was: picker + caller each paid).
OUT=$(run_migrate_cold "happy" 2>/dev/null); RC=$?
N_GCLIST=$(wc -l < "$GCLIST_COUNT" | tr -d ' ')
[ "$RC" = "0" ] && [ "$OUT" = "NEW-1" ] && ok "cold rig-list memo: the migration still succeeds" \
                                        || bad "cold rig-list memo -> expected rc=0 out=NEW-1, got rc=$RC out='$OUT'"
[ "$N_GCLIST" = "1" ] && ok "cold rig-list memo: exactly ONE 'gc rig list' for the whole migration (was two: the picker's subshell memo was thrown away)" \
                      || bad "cold rig-list memo: expected exactly 1 'gc rig list', got $N_GCLIST"

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
