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
# Gate-review ga-pvdwtc (error-vs-empty; covered by Part C and by the faithful fake_bd):
#   - the migration's stdout IS the new bead id, and the call site decided "migrated?" on
#     "captured stdout is non-empty" while acting on the exit status. The real `bd label add|
#     update|close ... -q` still print "✓ ..." on stdout, so a FAILED migration (a retraction
#     path) read as a success: the park was skipped and the dispatching marks were stripped off
#     an original that was still open. Now: every bd write is silenced, the decision is made by
#     _pilot_dog_store_try_migrate on the exit status + the id's shape, and fake_bd emits the real
#     confirmation lines (before, it answered label/update/close silently and hid exactly this).
#   - same class, three writes that can report failure yet have landed: a non-zero bd close is
#     resolved by re-reading the original (ours / closed by someone else / live / unreadable), a
#     bd create with no usable id by searching the destination for gc.migrated_from=<story>.
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
ISID_FN="$(extract_fn '_pilot_is_bead_id')"
RETRACT_FN="$(extract_fn '_pilot_migration_copy_retract')"
ORPHAN_FN="$(extract_fn '_pilot_retract_orphan_migration_copies')"
ORIGSTATE_FN="$(extract_fn '_pilot_migration_original_state')"
TRY_FN="$(extract_fn '_pilot_dog_store_try_migrate')"
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
for _fn_var in PATHTOK_FN MIGRATED_FN GUARD_FN BUILDERS_FN BUILDER_FN ISID_FN RETRACT_FN ORPHAN_FN ORIGSTATE_FN TRY_FN; do
  if [ -z "${!_fn_var}" ]; then
    echo "FATAL: helper for $_fn_var not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
    exit 2
  fi
done
# The dispatcher runs under `set -euo pipefail` (pilot-dispatcher.sh, top). A bare `bash -c` would NOT,
# and code that is fine without errexit/nounset can abort under them (a `jq -e` "false" is exit 1; a
# `[ .. ] && cmd` whose cmd fails is the LAST command of the list) — so every sandbox below starts with
# the dispatcher's own options, or the test would prove a shell the production code never runs in.
DISPATCHER_OPTS="$(grep -m1 -E '^set -[euo]+ ?[a-z]*' "$DISPATCHER" | tr -d '\r')"
case "$DISPATCHER_OPTS" in
  "set -euo pipefail") : ;;
  *) echo "FATAL: expected the dispatcher to run under 'set -euo pipefail', found '$DISPATCHER_OPTS' — update this selftest's sandbox to match" >&2; exit 2 ;;
esac

# Everything the two functions under test call, defined together so a sandbox can never
# silently lack one (a missing helper would degrade to the HQ default and pass by accident).
FN_PRELUDE="$RIGPATH_FN
$PATHTOK_FN
$MIGRATED_FN
$GUARD_FN
$BUILDERS_FN
$BUILDER_FN
$ISID_FN
$RETRACT_FN
$ORPHAN_FN
$ORIGSTATE_FN
$DEST_FN
$MIGRATE_FN
$TRY_FN"

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
  PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" bash -c "$DISPATCHER_OPTS
warn() { echo \"WARN: \$*\" >&2; }
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
RIGFAIL_OUT=$(PILOT_RIG_PATHS_JSON="" bash -c "$DISPATCHER_OPTS
warn() { echo \"WARN: \$*\" >&2; }
gc_json_or_unknown() { return 1; }
GC_CITY=/nonexistent
$FN_PRELUDE"'
_pilot_dog_store_blind_migrate_dest "{\"title\":\"x\",\"description\":\"whatsapp_automation/scripts/x.py\"}" gastown' 2>&1)
case "$RIGFAIL_OUT" in
  *"could not read any rig name"*gascity) ok "gc rig list failure (empty) -> destination defaults to gascity AND says why (not silent)" ;;
  *) bad "gc rig list failure (empty) -> expected a 'could not read any rig name' WARN then 'gascity', got: $RIGFAIL_OUT" ;;
esac
# A NON-empty but unusable list must be announced too (was silent: only an empty memo warned).
for _bad_list in '<html>502 bad gateway</html>' '{"rigs":[]}' '{"error":"x"}'; do
  _o=$(PILOT_RIG_PATHS_JSON="$_bad_list" bash -c "$DISPATCHER_OPTS
warn() { echo \"WARN: \$*\" >&2; }
GC_CITY=/nonexistent
$FN_PRELUDE"'
_pilot_dog_store_blind_migrate_dest "{\"title\":\"x\",\"description\":\"whatsapp_automation/scripts/x.py\"}" gastown' 2>&1)
  case "$_o" in
    *"could not read any rig name"*gascity) ok "unusable rig list '$_bad_list' -> defaults to gascity AND says why (not silent)" ;;
    *) bad "unusable rig list '$_bad_list' -> expected a WARN then 'gascity', got: $_o" ;;
  esac
done
# ... and a usable list stays QUIET (the warning must not become noise on the normal path).
_o=$(run_dest '{"title":"x","description":"whatsapp_automation/scripts/x.py"}' gastown 2>&1)
[ "$_o" = "whatsapp_automation" ] && ok "a usable rig list -> no warning, destination chosen from the text" \
                                  || bad "a usable rig list should be silent, got: $_o"

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
  # The stateful scenarios (close_lands_errors / close_other_closed / close_unreadable) keep their state in files
  # next to the call log; a scenario run twice must start from a clean slate, or its TOCTOU re-check would see the
  # PREVIOUS run's "already closed" original and abort before doing anything.
  rm -f "$_calllog.origclosed" "$_calllog.closeattempted"
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
      # close_lands_errors: the close reported failure but really landed -> the original now reads closed,
      # with the reason the migration passed.
      if [ -f "$CALLLOG.origclosed" ]; then
        jq -cn --arg r "$(cat "$CALLLOG.origclosed")" '[{id:"ORIG-1",status:"closed",assignee:null,close_reason:$r}]'
        exit 0
      fi
      if [ -f "$CALLLOG.closeattempted" ]; then
        case "$SCEN" in
          close_other_closed) printf '[{"id":"ORIG-1","status":"closed","assignee":null,"close_reason":"Duplicate of ga-zzzzzz -- closed by a human"}]'; exit 0 ;;
          close_unreadable)   exit 1 ;;
        esac
      fi
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
      # create_fails: nothing happened. create_lost: it exited non-zero and printed nothing, but the copy
      # LANDED (a timeout after the Dolt commit) -- see the list arm. create_rc_with_id: non-zero exit, id printed.
      create_fails|create_lost*)  exit 1 ;;
      create_rc_with_id)          printf '{"id":"NEW-1"}'; exit 1 ;;
      create_noid)                printf '{"id":""}'; exit 0 ;;   # the shape `bd create --dry-run --json` prints
      *)                          printf '{"id":"NEW-1"}'; exit 0 ;;
    esac
    ;;
  list)
    # The orphan search: bd list --metadata-field gc.migrated_from=<id> ... --json
    case "$SCEN" in
      create_lost|create_rc_with_id) printf '[{"id":"NEW-1"}]'; exit 0 ;;
      create_lost_junk_id)           printf '[{"id":"not an id"}]'; exit 0 ;;
      create_lost_search_fails)      exit 1 ;;
      create_lost_search_html)       printf '<html>502 bad gateway</html>'; exit 0 ;;
      *)                             printf '[]'; exit 0 ;;
    esac
    ;;
  close)
    if [ "$id" = "ORIG-1" ]; then
      reason=""; prev=""
      for a in "$@"; do [ "$prev" = "--reason" ] && reason="$a"; prev="$a"; done
      case "$SCEN" in
        close_fails)           echo 'assignee is "someone-else", actor is "pilot"' >&2; exit 1 ;;
        close_lands_errors)    printf '%s' "$reason" > "$CALLLOG.origclosed"; echo 'context deadline exceeded' >&2; exit 1 ;;
        close_other_closed|close_unreadable) : > "$CALLLOG.closeattempted"; echo 'context deadline exceeded' >&2; exit 1 ;;
        *)                     echo "✓ Closed ORIG-1: $reason"; exit 0 ;;
      esac
    fi
    echo "✓ Closed $id: $*"   # close of NEW-1 (retraction path) always succeeds in these scenarios
    exit 0
    ;;
  # The REAL bd prints these confirmations on STDOUT even with -q (measured 2026-09-25 on the live bd:
  # `bd label add <id> <label> -q` -> 41 bytes on stdout, 0 on stderr; the binary's format strings show
  # "Closed %s: %s" and "Updated issue: %s" the same way). A fake that answers these silently deletes
  # exactly the channel a `$(...)` caller decides success on (gate-review ga-pvdwtc).
  label)
    echo "✓ Added label '${3:-?}' to ${2:-?}"
    exit 0
    ;;
  update)
    echo "✓ Updated issue: ${id:-?}"
    exit 0
    ;;
  comment)
    echo "✓ Comment added to ${id:-?}"
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
    bash -c "$DISPATCHER_OPTS
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
    bash -c "$DISPATCHER_OPTS
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

# Scenario 9b: the predicate answers the same way whether or not its caller is an `if`. Under the
# dispatcher's `set -euo pipefail`, a bare `jq -e` that says "unreadable" (rc>=2) or "no marker" (rc 1)
# would abort the shell INSIDE the function instead of returning — masked today only because every call
# site happens to be an `if` condition. Called here as a plain statement, where errexit is live.
for _in in '{"metadata":"oops"}' 'not json at all' '[]' 'null' '' '"a string"' ; do
  _o=$(bash -c "$DISPATCHER_OPTS
$MIGRATED_FN"'
_pilot_story_already_migrated "$1"
echo survived' _ "$_in" 2>&1)
  [ "$_o" = "survived" ] \
    && ok "predicate as a bare statement under set -euo pipefail: '$_in' -> returns 0 (refuse) and the shell carries on" \
    || bad "predicate as a bare statement under set -euo pipefail: '$_in' -> the shell ABORTED inside the helper (got '${_o:-<nothing>}')"
done
# ... and the destination picker survives an unparseable rig list (jq exits 2, rig_root_path returns 2 under
# pipefail) as a bare statement — falls to the HQ default instead of dying in the memo warm-up.
_o=$(PILOT_RIG_PATHS_JSON="" bash -c "$DISPATCHER_OPTS
warn() { echo \"WARN: \$*\" >&2; }
gc_json_or_unknown() { printf '%s' '<html>502 bad gateway</html>'; }
GC_CITY=/nonexistent
$FN_PRELUDE"'
_pilot_dog_store_blind_migrate_dest "{\"title\":\"x\",\"description\":\"whatsapp_automation/scripts/x.py\"}" gastown >/dev/null 2>&1
echo survived' 2>&1)
[ "$_o" = "survived" ] \
  && ok "destination picker as a bare statement under set -euo pipefail with an UNPARSEABLE rig list -> survives (HQ default), does not die in the memo warm-up" \
  || bad "destination picker died under set -euo pipefail with an unparseable rig list (got '${_o:-<nothing>}')"

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
  if bash -c "$DISPATCHER_OPTS
$MIGRATED_FN"'
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

# ══════════════════════════════════════════════════════════════════════════════════════════════
# gate-review ga-pvdwtc — the migration's STDOUT *is* the new bead id, so it must be only that
# ══════════════════════════════════════════════════════════════════════════════════════════════
# Root class: error-vs-empty. The dispatch call site decided "migrated?" on "captured stdout is
# non-empty" while the value it ACTED on was the exit status, and the real `bd label add|close -q`
# still print "✓ ..." on stdout — so a FAILED migration read as a success (the park was skipped and
# the dispatching marks were stripped off an original that was still open). Every fake_bd write above
# now emits those lines, so Part B already fails on any leak; Part C pins the decision itself.
echo ""
echo "=== Part C: gate-review ga-pvdwtc — the stdout contract, the exit-status decision, ambiguous writes ==="

# C1 — _pilot_is_bead_id: an id is one token in an id's alphabet, never a confirmation line.
is_id() { bash -c "$DISPATCHER_OPTS
$ISID_FN"'
_pilot_is_bead_id "$1"' _ "$1"; }
for _v in NEW-1 ORIG-1 ga-6u64fm wa-2txhl ga-wisp-2ld24xp gt-c1x1j; do
  if is_id "$_v"; then ok "bead-id predicate accepts '$_v'"; else bad "bead-id predicate must accept '$_v'"; fi
done
for _v in "" "✓ Added label 'lane:small' to NEW-1" $'✓ Added label \'x\' to NEW-1\nNEW-1' $'NEW-1\n' "NEW-1 " " NEW-1" \
          "-NEW-1" "NEWONE" "ga abc-1" "ga-abc:def" "ga-'x'" '{"id":"NEW-1"}'; do
  _shown=$(printf '%s' "$_v" | tr '\n' '|')
  if is_id "$_v"; then bad "bead-id predicate must REJECT '${_shown}'"; else ok "bead-id predicate rejects '${_shown}'"; fi
done

# C2 — the wrapper in isolation, against a stub migrator: it decides on the EXIT STATUS. Each case is a
# state the old `[ -n "$_MIGRATED_ID" ]` test got wrong or could not tell apart.
try_stub() { # try_stub <stub body> -> "rc=<n> out=<stdout>"; stderr kept in $WORK/try.err
  local _o _rc
  _o=$(STUB="$1" bash -c "$DISPATCHER_OPTS
warn() { echo \"WARN: \$*\" >&2; }
$ISID_FN
$TRY_FN"'
_pilot_migrate_dog_store_blind_bead() { eval "$STUB"; }
_pilot_dog_store_try_migrate a b c d e' 2>"$WORK/try.err"); _rc=$?
  printf 'rc=%s out=%s' "$_rc" "$_o"
}
R=$(try_stub "echo \"✓ Added label 'pilot:no-auto-dispatch' to NEW-1\"; return 1")
[ "$R" = "rc=1 out=" ] && ok "wrapper: migration FAILED (rc 1) but printed a bd confirmation line -> not migrated, prints nothing (the reviewer's repro)" \
                       || bad "wrapper: a failed migration that leaked a confirmation line must not read as a success — got '$R'"
R=$(try_stub 'printf NEW-9; return 3')
[ "$R" = "rc=1 out=" ] && ok "wrapper: an id-shaped stdout with a NON-ZERO exit is still not a migration (the exit status is what decides)" \
                       || bad "wrapper: id on stdout + rc 3 must be 'not migrated' — got '$R'"
R=$(try_stub 'printf NEW-9; return 0')
[ "$R" = "rc=0 out=NEW-9" ] && ok "wrapper: exit 0 + a real id -> migrated, echoes exactly the id" \
                            || bad "wrapper: exit 0 + id -> expected 'rc=0 out=NEW-9', got '$R'"
R=$(try_stub "echo \"✓ Added label 'x' to NEW-1\"; printf NEW-9; return 0")
[ "$R" = "rc=1 out=" ] && grep -q 'contract violation' "$WORK/try.err" \
  && ok "wrapper: exit 0 but stdout is not a bare id -> NOT reported as migrated, and it says why (contract violation)" \
  || bad "wrapper: exit 0 + junk stdout must be refused with a warning — got '$R' / stderr: $(cat "$WORK/try.err")"
R=$(try_stub 'return 0')
[ "$R" = "rc=1 out=" ] && ok "wrapper: exit 0 and NOTHING printed -> not migrated (an empty id is not an id)" \
                       || bad "wrapper: exit 0 + empty stdout must not read as migrated — got '$R'"

# C3 — the DEPLOYED call-site expression itself, run under the dispatcher's own set -euo pipefail against the
# real function chain and the faithful fake. The `if ... ; then` text is extracted from pilot-dispatcher.sh by
# awk, so a call site that goes back to deciding on captured stdout is what this exercises — not a copy of it.
CALLSITE=$(awk '/if \[ "\$\{PILOT_DOG_STORE_AUTOMIGRATE:-1\}" = "1" \] \\$/{f=1} f{print} f&&/; then$/{exit}' "$DISPATCHER")
if [ -z "$CALLSITE" ]; then
  bad "call site: could not extract the PILOT_DOG_STORE_AUTOMIGRATE 'if ... ; then' from the dispatcher (drifted?)"
elif ! printf '%s' "$CALLSITE" | grep -qF '_pilot_dog_store_try_migrate "$STORY_ID"'; then
  bad "call site: the migration is not invoked through _pilot_dog_store_try_migrate (exit-status decision) — got: $CALLSITE"
else
  ok "call site: extracted from the dispatcher and invoked through _pilot_dog_store_try_migrate inside the if-condition"
  CALLSITE_SCRIPT="$WORK/callsite.sh"
  {
    echo "$DISPATCHER_OPTS"
    cat <<'EOS_HEAD'
warn() { echo "WARN: $*" >&2; }
log()  { echo "LOG: $*"; }
EOS_HEAD
    echo "$FN_PRELUDE"
    cat <<'EOS_OPEN'
t() {
  local _MIGRATED_ID=""
EOS_OPEN
    echo "$CALLSITE"
    cat <<'EOS_TAIL'
    echo "MIGRATED:$_MIGRATED_ID"
  else
    echo "PARKED"
  fi
}
t
EOS_TAIL
  } > "$CALLSITE_SCRIPT"
  run_callsite() { # run_callsite <scenario> -> MIGRATED:<id> | PARKED (stdout only; the WARN/LOG chatter is not the result)
    local _bin
    _bin=$(fake_bd "$1")
    PATH="$_bin:$PATH" PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" GC_CITY="$WORK/gascity" \
      STORY_ID=ORIG-1 STORY="$STORY_JSON" STORY_BEAD_CITY="$WORK/gastown" STORY_RIG=gastown STORY_LABELS=lane:small \
      /bin/bash "$CALLSITE_SCRIPT" 2>/dev/null | grep -E '^(MIGRATED:|PARKED$)'
  }
  R=$(run_callsite happy)
  [ "$R" = "MIGRATED:NEW-1" ] && ok "call site, happy path (with a lane:* label, i.e. with a bd confirmation line) -> MIGRATED:NEW-1, a clean id" \
                              || bad "call site, happy path -> expected 'MIGRATED:NEW-1', got '$R'"
  for _sc in close_fails readback_fails create_fails raced_status close_other_closed close_unreadable create_lost create_lost_search_fails; do
    R=$(run_callsite "$_sc")
    [ "$R" = "PARKED" ] && ok "call site, scenario $_sc -> PARKED (falls through to the park; never reads a leaked '✓ ...' line as a migration)" \
                        || bad "call site, scenario $_sc -> expected PARKED, got '$R' (the reviewer's repro: a failed migration taken as a success)"
  done
  R=$(run_callsite close_lands_errors)
  [ "$R" = "MIGRATED:NEW-1" ] && ok "call site, close reported failure but landed -> MIGRATED:NEW-1 (the copy IS the story; no park)" \
                              || bad "call site, close-landed-with-error -> expected 'MIGRATED:NEW-1', got '$R'"
fi

# C4 — the three AMBIGUOUS writes. A write that reports failure may have landed, and one that reports success may
# not be readable: each is resolved by READING STATE BACK. calls_of prints the fake's call log for a scenario.
calls_of() { tr '\n' '|' < "$(calllog_for "$1")"; }
# "close" of a given id / "label add <id> pilot:no-auto-dispatch" as the fake logged them (the label id sits in $*).
closed_id()  { grep -qE "^close\\|[^|]*\\|$2\\|" "$(calllog_for "$1")"; }
vetoed_id()  { grep -qE "^label\\|.*add $2 pilot:no-auto-dispatch" "$(calllog_for "$1")"; }
order_ok()   { # order_ok <scenario> <id>: veto of <id> logged BEFORE its close
  local _l _c
  _l=$(grep -nE "^label\\|.*add $2 pilot:no-auto-dispatch" "$(calllog_for "$1")" | head -1 | cut -d: -f1)
  _c=$(grep -nE "^close\\|[^|]*\\|$2\\|" "$(calllog_for "$1")" | head -1 | cut -d: -f1)
  [ -n "$_l" ] && [ -n "$_c" ] && [ "$_l" -lt "$_c" ]
}

# C4a — close returned non-zero but LANDED: the copy is the story. Retracting it would leave both closed.
OUT=$(run_migrate close_lands_errors 2>/dev/null); RC=$?
[ "$RC" = "0" ] && [ "$OUT" = "NEW-1" ] \
  && ok "close returned non-zero but the original reads closed WITH our reason -> success: echoes NEW-1, returns 0" \
  || bad "close landed-with-error -> expected rc=0 out=NEW-1, got rc=$RC out='$OUT'"
if closed_id close_lands_errors NEW-1 || vetoed_id close_lands_errors NEW-1; then
  bad "close landed-with-error -> REGRESSION: retracted the copy although the original IS closed (the story would vanish): $(calls_of close_lands_errors)"
else
  ok "close landed-with-error -> the copy is NOT vetoed or closed (both beads closed = the story lost)"
fi

# C4b — close returned non-zero and the original was closed by SOMEONE ELSE: the copy must not resurrect it.
OUT=$(run_migrate close_other_closed 2>/dev/null); RC=$?
[ "$RC" = "1" ] && [ -z "$OUT" ] && ok "original closed by another actor in the race window -> not migrated (rc 1, nothing on stdout)" \
                                  || bad "original closed by someone else -> expected rc=1 empty, got rc=$RC out='$OUT'"
order_ok close_other_closed NEW-1 && ok "original closed by another actor -> the copy is retracted: veto BEFORE close (does not resurrect a story someone closed)" \
                                  || bad "original closed by another actor -> expected veto-then-close on NEW-1, got: $(calls_of close_other_closed)"

# C4c — close returned non-zero and the original cannot be read: veto, never close, leave a trail.
OUT=$(run_migrate close_unreadable 2>/dev/null); RC=$?
[ "$RC" = "1" ] && [ -z "$OUT" ] && ok "close returned non-zero and the original is unreadable -> not migrated (rc 1, nothing on stdout)" \
                                  || bad "close-unreadable -> expected rc=1 empty, got rc=$RC out='$OUT'"
if vetoed_id close_unreadable NEW-1 && ! closed_id close_unreadable NEW-1; then
  ok "close-unreadable -> the copy is VETOED but NOT closed (closing it could leave both beads closed)"
else
  bad "close-unreadable -> expected veto without close on NEW-1, got: $(calls_of close_unreadable)"
fi
if grep -qE '^comment\|[^|]*\|NEW-1\|' "$(calllog_for close_unreadable)" && grep -qE '^comment\|[^|]*\|ORIG-1\|' "$(calllog_for close_unreadable)"; then
  ok "close-unreadable -> a comment on BOTH beads says a human must close one of the two"
else
  bad "close-unreadable -> expected a comment on NEW-1 and on ORIG-1, got: $(calls_of close_unreadable)"
fi

# C4c2 — the DEFAULT arm is the inert one. The state helper is meant to print only ours|closed-other|live|unknown;
# a token the case does not name (output noise, a future edit of the helper) is "cannot tell" — and under doubt the
# copy is VETOED, never closed (closing it could leave both beads closed: the story lost).
run_migrate_state_stub() { # run_migrate_state_stub <token> — scenario close_fails, state helper stubbed to print <token>
  local _bin
  _bin=$(fake_bd close_fails)
  STATE_TOKEN="$1" PATH="$_bin:$PATH" PILOT_RIG_PATHS_JSON="$FAKE_RIGS_JSON" GC_CITY="$WORK/gascity" \
    bash -c "$DISPATCHER_OPTS
warn() { echo \"WARN: \$*\" >&2; }
log()  { echo \"LOG: \$*\"; }
$FN_PRELUDE"'
_pilot_migration_original_state() { printf "%s" "$STATE_TOKEN"; }
_pilot_migrate_dog_store_blind_bead ORIG-1 "$1" "$2" gastown lane:small' _ "$STORY_JSON" "$WORK/gastown"
}
for _tok in garbage "" "LIVE" "✓ Closed ORIG-1: x"; do
  OUT=$(run_migrate_state_stub "$_tok" 2>/dev/null); RC=$?
  if [ "$RC" = "1" ] && [ -z "$OUT" ] && vetoed_id close_fails NEW-1 && ! closed_id close_fails NEW-1; then
    ok "unrecognised original-state token '$_tok' -> the DEFAULT arm is inert: copy vetoed, NOT closed, nothing on stdout"
  else
    bad "unrecognised original-state token '$_tok' -> expected rc=1 empty, veto without close on NEW-1; got rc=$RC out='$OUT' calls: $(calls_of close_fails)"
  fi
done
# ... and the two states the case DOES name still retract (so the default arm did not swallow them).
for _tok in live closed-other; do
  OUT=$(run_migrate_state_stub "$_tok" 2>/dev/null); RC=$?
  if [ "$RC" = "1" ] && [ -z "$OUT" ] && order_ok close_fails NEW-1; then
    ok "original-state '$_tok' -> retracts the copy (veto BEFORE close): the named states are not swallowed by the inert default"
  else
    bad "original-state '$_tok' -> expected veto-then-close on NEW-1, got rc=$RC out='$OUT' calls: $(calls_of close_fails)"
  fi
done

# C4d — bd create failed but the copy LANDED (output lost): found by gc.migrated_from and retracted.
for _sc in create_lost create_rc_with_id; do
  OUT=$(run_migrate "$_sc" 2>/dev/null); RC=$?
  [ "$RC" = "1" ] && [ -z "$OUT" ] && ok "scenario $_sc: create reported failure -> not migrated (rc 1, nothing on stdout)" \
                                    || bad "scenario $_sc -> expected rc=1 empty, got rc=$RC out='$OUT'"
  if grep -qE '^list\|' "$(calllog_for "$_sc")" && grep -qF 'gc.migrated_from=ORIG-1' "$(calllog_for "$_sc")"; then
    ok "scenario $_sc: searched the destination for a live copy by gc.migrated_from=<the story>"
  else
    bad "scenario $_sc -> expected a bd list --metadata-field gc.migrated_from=ORIG-1 search, got: $(calls_of "$_sc")"
  fi
  order_ok "$_sc" NEW-1 && ok "scenario $_sc: the copy that landed is retracted (veto BEFORE close)" \
                        || bad "scenario $_sc -> expected veto-then-close on NEW-1, got: $(calls_of "$_sc")"
  closed_id "$_sc" ORIG-1 && bad "scenario $_sc -> REGRESSION: closed the original although the copy was never confirmed" \
                          || ok "scenario $_sc: the original is NOT closed"
done
# ... and when nothing landed (create_fails) the search runs, finds nothing, and writes nothing.
OUT=$(run_migrate create_fails 2>/dev/null); RC=$?
if [ "$RC" = "1" ] && [ -z "$OUT" ] && grep -qE '^list\|' "$(calllog_for create_fails)" \
   && ! grep -qE '^(close|label|update|comment)\|' "$(calllog_for create_fails)"; then
  ok "create failed and nothing landed -> the search finds nothing and NOTHING is written (no close/label/update/comment)"
else
  bad "create_fails -> expected rc=1, a list search, and no writes; got rc=$RC out='$OUT' calls: $(calls_of create_fails)"
fi
# The search itself can fail: that is a THIRD state (could not tell), announced, never folded into 'found none'.
for _sc in create_lost_search_fails create_lost_search_html; do
  ERR=$(run_migrate "$_sc" 2>&1 >/dev/null); OUT=$(run_migrate "$_sc" 2>/dev/null); RC=$?
  case "$ERR" in
    *"could not search"*"check by hand"*) ok "scenario $_sc: the failed/unusable search is ANNOUNCED with the command to run by hand (not silent)" ;;
    *) bad "scenario $_sc -> expected a 'could not search ... check by hand' warning, got: $ERR" ;;
  esac
  [ "$RC" = "1" ] && [ -z "$OUT" ] && ! grep -qE '^(close|label)\|' "$(calllog_for "$_sc")" \
    && ok "scenario $_sc: not migrated, and it writes nothing it cannot justify" \
    || bad "scenario $_sc -> expected rc=1 empty and no close/label, got rc=$RC out='$OUT' calls: $(calls_of "$_sc")"
done
# A search hit whose id is not an id is not touched.
OUT=$(run_migrate create_lost_junk_id 2>/dev/null); RC=$?
if [ "$RC" = "1" ] && [ -z "$OUT" ] && ! grep -qE '^(close|label)\|' "$(calllog_for create_lost_junk_id)"; then
  ok "the search returned an unusable id -> not touched (a garbled id is never handed to bd close/label)"
else
  bad "create_lost_junk_id -> expected rc=1 empty and no close/label, got rc=$RC out='$OUT' calls: $(calls_of create_lost_junk_id)"
fi
# create exiting 0 with an EMPTY id (the shape `bd create --dry-run --json` prints) is a failure too.
OUT=$(run_migrate create_noid 2>/dev/null); RC=$?
if [ "$RC" = "1" ] && [ -z "$OUT" ] && ! closed_id create_noid ORIG-1 && grep -qE '^list\|' "$(calllog_for create_noid)"; then
  ok "create exit 0 but no usable id -> failed: searches for a landed copy, never closes the original"
else
  bad "create_noid -> expected rc=1 empty, a search, original not closed; got rc=$RC out='$OUT' calls: $(calls_of create_noid)"
fi

# C5 — a title that starts with '-' is passed as --title=<t>: the positional form is parsed as a flag by bd
# ("Error: title required", verified with `bd create --dry-run`), which fell back to park for no good reason.
DASH_STORY='{"id":"ORIG-1","title":"-starts with a dash","priority":2,"issue_type":"bug","description":"d","labels":[]}'
OUT=$(run_migrate happy "$DASH_STORY" 2>/dev/null); RC=$?
if [ "$RC" = "0" ] && [ "$OUT" = "NEW-1" ] && grep -qF -- '--title=-starts with a dash' "$(calllog_for happy)"; then
  ok "a title starting with '-' is passed as --title=<title> (not a positional bd would parse as a flag) and still migrates"
else
  bad "dash-title -> expected rc=0 out=NEW-1 with --title=-starts with a dash, got rc=$RC out='$OUT' calls: $(calls_of happy)"
fi

echo ""
echo "=== Drift-guards: call-site wiring in dispatch_one()'s crew arm ==="
has 'PILOT_DOG_STORE_AUTOMIGRATE:-1'                                     "call site respects PILOT_DOG_STORE_AUTOMIGRATE kill switch (default on), independent of PILOT_DOG_STORE_GUARD"
has '_pilot_dog_store_try_migrate "\$STORY_ID" "\$STORY" "\$STORY_BEAD_CITY" "\$STORY_RIG" "\$STORY_LABELS"' "call site invokes the migration through _pilot_dog_store_try_migrate with STORY_ID/STORY/STORY_BEAD_CITY/STORY_RIG/STORY_LABELS"
if grep -qF '_pilot_migrate_dog_store_blind_bead "$STORY_ID"' "$DISPATCHER"; then
  bad "REGRESSION: the call site calls the raw migrator again (decides on captured stdout) instead of _pilot_dog_store_try_migrate"
else
  ok "the call site no longer calls the raw migrator directly (the decision lives in _pilot_dog_store_try_migrate)"
fi
has 'DISPATCH_RESULT="rig_native_dog_store_migrated"'                    "a successful migration is attributed to its own distinct DISPATCH_RESULT"
# Ordering: the migration attempt must run BEFORE the park (refuse) logic,
# so a successful migration short-circuits the park path entirely (return 1
# fires right after a successful migration, never reaching the warn/park
# block below it).
if awk '/_pilot_dog_store_try_migrate "\$STORY_ID"/{m=NR} /ga-cszxcf: REFUSING rig-native dispatch/{p=NR} END{exit !(m && p && m<p)}' "$DISPATCHER"; then
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
