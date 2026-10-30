#!/bin/sh
# pool-probe.sh <target> — the dog's Step 1c probe ("find routed pool work") as a versioned file.
# ga-witezg (P0); stderr/exit-code contract: ga-iu0ms2 (gate findings on ga-witezg).
#
# Why it is a file. The engine renders the probe into the dog's prompt as a ~5.5 KB `sh -c '...'`
# (internal/config/config.go: routedReadyTierCommand + probe_pool_demand). Claude Code's built-in
# "dangerous removal" check DENIES that command ("could not check the script for dangerous
# removals") although it contains no rm, and a pool session has nobody to approve the prompt: dog-1
# and dog-3 sat idle ~2h on 10/10 with three P0 routed to gastown.dog. Bisected the same day: no
# single construct trips it (the ${x#..}/${x%..} trims, the function, the while-read loop, size, the
# count of '\'' escapes, the count of $( ) — each passes alone); it reproduces on the real tier-1
# half and on a combined 1a+1b, so the trigger is the combination, which nobody controls. A short
# call to a file has no such combination: `sh <this file> gastown.dog`.
#
# Contract. The SAME probe: same bd calls (same flags, same order), same veto filter, same tiers, and
# the same STDOUT in every case (one JSON array of at most one bead, or `[]`) - except the three deliberate
# differences below (the disk floor, ga-vln2py; the sling filter, ga-b97dgq; the gate focus hold, ga-6fkx9je), each with its own selftest.
# It is read-only (bd ready/list/query/show, gc session list, jq): nothing in here removes anything. The proof
# is pool-probe.selftest.sh, which runs the engine's own text (pool-probe.golden-1c.txt) and this file against
# the same fixtures and compares stdout, the argv of every bd call and the exit code.
#
# Where it deliberately differs from the engine's probe: the engine's probe answers `[]` with exit 0
# and no word on stderr both for "nothing to pick up" and for "I could not tell" (bd failed, bd
# answered something that is not JSON, no <target>). A dog that reads `[]` as "no work" drains and
# exits while work waits. So, without touching stdout:
#   * no <target>                      -> `[]`, a line on stderr, exit 2 (nothing was probed)
#   * a tier whose bd call failed or whose answer is not JSON, and nothing found anywhere
#                                      -> `[]`, a line on stderr naming the tier(s), exit 3
#   * a molecule whose children could not be read (the bead is kept, as the engine does)
#                                      -> a line on stderr, the answer is unchanged
# Anything on stderr (or a non-zero exit) means `[]` is NOT "no work": do not drain, tell the Mayor.
#
# Drift. This is a snapshot of the live binary's probe (gc-1.1.1-engwin0919). When an engine window
# changes the probe (engine-window-0926 adds the next-action:* class — see pool-probe-vetoes.sh), the
# selftest's `--live` mode (compares the golden with what `gc prime` renders now) goes red: update the
# golden AND this file together, never one of them. Run it after every engine window
# (docs/runbooks/janela-manutencao-bd-e-engine.md, "Verificação").
#
# Usage: sh pool-probe.sh <target>        e.g. sh pool-probe.sh gastown.dog
# Like the original it prints nothing when GC_SESSION_ORIGIN is neither ephemeral nor empty.

case "$GC_SESSION_ORIGIN" in ephemeral|"") ;; *) exit 0 ;; esac

target="$1"
if [ -z "$target" ]; then
  printf "[]"
  echo "pool-probe: no <target> given (usage: sh pool-probe.sh <target>, e.g. gastown.dog) - nothing was probed, so [] here does NOT mean there is no work" >&2
  exit 2
fi

# Tiers whose answer could not be read, e.g. " 1 3". `mark N` records one without repeating it.
unreadable=""
mark() {
  case " $unreadable " in *" $1 "*) ;; *) unreadable="$unreadable $1" ;; esac
}

# ga-vln2py (P0): DISK FLOOR. With the free disk under the new-work floor (disk-headroom-lib.sh, 5 GB) this probe hands
# out no NEW STORY from tier 1: a builder started on a disk that low is what filled it on 17/10 and took Dolt down.
# The city's own formula work still flows - it is what gets the city out of the hole: order molecules and their steps
# (the stale-db cleanup: type molecule / step, gc.pool_demand, gc.step_ref - no gc.kind), gc.kind work, and tiers 2 and 3.
# What counts as a story is ONE definition, DISK_HOLD_NEW_STORIES_JQ in the lib; a shape it does not recognise flows.
# This is one of the three places where the answer deliberately differs from the engine's probe (the others are the gate focus
# hold, ga-6fkx9je, and the sling filter, ga-b97dgq, both below), and it differs only while the disk is low:
# with the disk fine (or unreadable) stdout, the bd calls and the exit code are byte-for-byte the engine's.
# `[]` from the hold is a real "nothing for you": drain, do not look for a story by another route.
# The hold runs AFTER the engine's --limit=20 window (ga-nyug12): 20 stories older than a formula bead would fill the window,
# the hold would empty it and `[]` would say "drain" while formula work waits outside. So when the disk is low, the window was
# full and the hold removed everything, tier 1 is asked ONE more time with --limit=0 (the only extra bd call, only on that path);
# if that second read fails the tier is unreadable (exit 3), never "no work".
# Three states: low -> hold; ok -> as before; unknown (lib missing/corrupt, df unreadable) -> as before (fail OPEN: a df
# hiccup must not starve the pool) with a line in the pool-probe log. The lib is read in a subshell so a corrupt copy
# cannot kill the probe. DISK_FREE_OVERRIDE_MB pins the reading (selftests).
disk_lib="${POOL_PROBE_DISK_LIB:-$(dirname "$0")/disk-headroom-lib.sh}"
# vazio/falhou/ilegível -> disk_state stays "unknown" (answer unchanged, fail-open, logged); never "low"
disk_state=$( ( . "$disk_lib" && disk_headroom_state "$DISK_NEW_WORK_MIN_MB" ) 2>/dev/null )
case "$disk_state" in ok|low) ;; *) disk_state=unknown ;; esac
# vazio/falhou/ilegível -> empty text; only read when the disk is low, where an empty text makes tier 1 answer nothing
disk_hold_jq=""
[ "$disk_state" = low ] && disk_hold_jq=$( ( . "$disk_lib" && printf "%s" "$DISK_HOLD_NEW_STORIES_JQ" ) 2>/dev/null )

pp_log() {
  # best effort: the answer is already decided and a full disk is exactly when this write fails
  pp_city="${GC_CITY_PATH:-${GC_CITY:-}}"
  # no POOL_PROBE_LOG and no city: nowhere to log. The old "." fallback made ./.gc/logs in whatever directory the session stood in (ga-nyug12)
  [ -n "${POOL_PROBE_LOG:-$pp_city}" ] || return 0
  pp_f="${POOL_PROBE_LOG:-$pp_city/.gc/logs/pool-probe.log}"
  mkdir -p "$(dirname "$pp_f")" 2>/dev/null || return 0
  printf "%s pool-probe[%s]: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" "$*" >> "$pp_f" 2>/dev/null || true
}
[ "$disk_state" = unknown ] && pp_log "free disk unreadable (lib=$disk_lib) - fail-open, new stories not held back (ga-vln2py)"

# ga-6fkx9je: GATE FOCUS MODE (Athos 07/10, ga-kqa08j). While the gate is the bottleneck (gate-focus-mode.sh says active=1) the
# builder pools take no NEW story, only fixes: gate:needs-fix / gate:fix-attempt:N, origem:auto-healer-notify, impacto:dano-ao-vivo
# (GATE_FOCUS_FIX_JQ, gate-focus-lib.sh). The wa/ps worker probes keep ONLY fixes; this probe cannot. The dog pool also carries the
# city's own formula work (the stale-db cleanup molecule and its steps, gc.kind work - see the disk floor above): the Pilot never
# dispatches it, so the mode never held it back, and starving it for the hours the mode stays ON would stop the reaper and the
# orders. So the hold is the disk floor's minus the fix class: tier 1 loses the positively recognised NEW STORIES (the ONE
# definition, DISK_HOLD_NEW_STORIES_JQ in the disk lib) that are not fixes; formula work, fixes and tiers 2 and 3 flow.
# Three states of the mode, never two: ON -> hold; OFF -> as before; unknown (lib missing or corrupt, no state file, a state
# older than GATE_FOCUS_STALE_S, anything but 0/1) -> as before, FAIL OPEN as the lib's contract says and as every other pause
# does, with a line in the pool-probe log so "the mode is off" and "nobody could tell" never look the same. And a fourth case:
# ON but the hold cannot be built or applied (a lib that does not give its text, jq failing) -> tier 1 answers nothing and is
# marked unreadable (exit 3 when tiers 2 and 3 find nothing either): inert AND loud, never "no work" and never "go ahead".
# A low disk wins over the mode: it holds every story, fixes included, so the disk block alone handles that case.
# `[]` from the hold is a real "nothing for you": drain, do not look for a story by another route. The libs are read in
# subshells so a corrupt copy cannot kill the probe. GATE_FOCUS_ACTIVE_OVERRIDE (the lib's own seam) pins the reading (selftests).
focus_lib="${POOL_PROBE_FOCUS_LIB:-$(dirname "$0")/gate-focus-lib.sh}"
# vazio/falhou/ilegível -> focus_state stays "unknown" (answer unchanged, fail-open, logged); never "1" and never a silent "0"
focus_state=$( ( . "$focus_lib" && gate_focus_active ) 2>/dev/null )
case "$focus_state" in 0|1) ;; *) focus_state=unknown ;; esac
[ "$focus_state" = unknown ] && pp_log "gate focus state unreadable (lib=$focus_lib) - fail-open, new stories not held back (ga-6fkx9je)"
focus_hold_jq=""
if [ "$focus_state" = 1 ] && [ "$disk_state" != low ]; then
  # vazio/falhou/ilegível -> empty fix predicate; the hold is then not built and tier 1 answers nothing (inert, marked, exit 3 if nothing else is found)
  focus_fix_jq=$( ( . "$focus_lib" && printf "%s" "$GATE_FOCUS_FIX_JQ" ) 2>/dev/null )
  # vazio/falhou/ilegível -> empty story definition; same: the hold is not built, tier 1 answers nothing
  focus_story_jq=$( ( . "$disk_lib" && printf "%s" "$DISK_HOLD_NEW_STORIES_JQ" ) 2>/dev/null )
  if [ -n "$focus_fix_jq" ] && [ -n "$focus_story_jq" ]; then
    # per bead: it flows when the ONE story definition lets it through ([.] kept = not a story) or when it is a fix
    focus_hold_jq="[ .[] | select( ([.] | $focus_story_jq) != [] or ($focus_fix_jq) ) ]"
  fi
fi

# The length of the JSON list in $1, on stdout. rc 1 and NOTHING on stdout when jq cannot say (it failed, or it answered nothing).
# One definition for a count (ga-nyug12, gate attempt 1): a count that could not be read is not 0. A caller that DECIDES on a count
# marks the tier unreadable (`n=$(pp_len "$x") || mark 1`); a caller that only prints it uses pp_minus, which shows "?".
pp_len() {
  pp_n=$(printf "%s" "$1" | jq length 2>/dev/null) || return 1
  [ -n "$pp_n" ] || return 1
  printf "%s" "$pp_n"
}
# $1 - $2 for a log line, "?" when either count is missing. Log text only: nothing decides on what this prints.
pp_minus() {
  [ -n "$1" ] && [ -n "$2" ] || { printf "?"; return 0; }
  printf "%s" "$(( $1 - $2 ))"
}

# The veto filter every tier ends with (the engine's poolDemandLabelFilterJQ). The engine pastes the
# same 655-byte program into all three tiers; it is one variable here. Prefix families (bd's
# --exclude-label is exact, so these cannot be flags), an unexpired pilot hold, EPIC-titled beads.
VETO_FILTER='[ .[] | select(((.labels // []) | map(select(startswith("pool:refused"))) | length) == 0) | select((((.labels // []) | map(select(. == "pilot:held" or startswith("pilot:held-until:"))) | length) == 0) or (((.labels // []) | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber)) | if length > 0 then (max < $now_ts) else false end)) | select(((.title // "") | test("^(EPIC|ÉPICO)[:\\s]"; "i")) | not) | select(((.labels // []) | map(select(startswith("blocked:") or startswith("blocked-reason:") or startswith("gate:needs-human") or startswith("pilot:refused-reason:") or startswith("pilot:text-veto"))) | length) == 0) ]'

# Tier 1, second half: stdin is the JSON array of routed ready beads; keep the ones whose molecule has
# no in-progress child (a bead with no molecule_id is always kept; an answer that is not proof of a
# live child keeps the bead too — and says so on stderr, so the fail-open is visible).
drop_molecules_in_flight() {
  cands=$(cat)
  keep_ids=$(printf "%s" "$cands" | jq -r '.[] | [.id, (.metadata["molecule_id"] // "")] | @tsv' 2>/dev/null | while IFS="$(printf '\t')" read -r cid mid; do
    [ -z "$cid" ] && continue
    if [ -z "$mid" ]; then printf "%s\n" "$cid"; continue; fi
    live=$(bd list --parent "$mid" --status in_progress --json --limit 1 2>/dev/null)
    live_rc=$?
    if [ "$live" = "[]" ]; then
      printf "%s\n" "$cid"
    elif [ -z "$live" ]; then
      echo "pool-probe: could not read the children of molecule $mid (bd exit $live_rc) - kept $cid" >&2
      printf "%s\n" "$cid"
    elif [ "${live#\[}" != "$live" ] && [ "${live%\]}" != "$live" ]; then
      :
    else
      echo "pool-probe: unreadable answer for the children of molecule $mid - kept $cid" >&2
      printf "%s\n" "$cid"
    fi
  done)
  printf "%s" "$cands" | jq -c --arg ids "$keep_ids" '($ids | split("\n") | map(select(length > 0))) as $keep | [.[] | select(.id as $i | $keep | index($i) != null)]' 2>/dev/null
}

# Sling wisps whose story is already in live hands (ga-b97dgq): the filter is `drop_slings_for_taken_stories`, defined in
# pool-probe-sling-lib.sh (its comment says what "in hand" means and the three states). It is applied to the candidates of
# every tier BEFORE the oldest-pick: after it, a duplicate wisp that is the oldest would empty the answer while legitimate
# work waits right behind it. This is the second deliberate difference from the engine's answer (the first is the disk floor).
# vazio/falhou/ilegível (lib missing, or it does not source cleanly) -> the pass-through below stays: the tier answers exactly
# as the engine's probe would, and a line in the pool-probe log says the filter is off. The lib is tried in a subshell first so a
# corrupt copy cannot kill the probe.
drop_slings_for_taken_stories() { cat; }
sling_lib="${POOL_PROBE_SLING_LIB:-$(dirname "$0")/pool-probe-sling-lib.sh}"
if [ -f "$sling_lib" ] && ( . "$sling_lib" ) >/dev/null 2>&1; then
  . "$sling_lib"
else
  pp_log "sling filter lib missing or corrupt (lib=$sling_lib) - sling wisps are NOT filtered, tiers answer as the engine's probe would (ga-b97dgq)"
fi

# Print $1 and stop the whole probe when it holds a bead.
found() {
  [ -n "$1" ] && [ "$1" != "[]" ] && printf "%s" "$1" && exit 0
}

# Tier 1: unassigned beads routed to <target> (the exact --exclude-label list is the engine's
# bdReadyPoolDemandExcludeLabelArgs, in the engine's order), oldest first, then the veto filter,
# the molecule check, and the oldest-updated one.
t1_fetch() { # $1 = --limit: the engine asks for 20; the disk hold may ask again with 0 (= unlimited, see above)
  bd ready --metadata-field "gc.routed_to=$target" --unassigned --exclude-type=epic \
    --exclude-label "story:needs-human" --exclude-label "needs-human" --exclude-label "ctx:thin" \
    --exclude-label "story:needs-approval" --exclude-label "story:epic" --exclude-label "needs:engine-window" \
    --exclude-label "pilot:no-auto-dispatch" --exclude-label "story:blocked" --exclude-label "delivery:partial" \
    --exclude-label "scope:needs-review" --exclude-label "exec:manual" --exclude-label "needs-human-decision" \
    --exclude-label "auto-refino:refining" --exclude-label "auto-refino:escalated" --exclude-label "refino:info-gap" \
    --exclude-label "refino:policy-gap" --exclude-label "story:unrefined" --exclude-label "story:refinement-in-progress" \
    --exclude-label "story:refino-review" --exclude-label "story:refino-escalado" --exclude-label "story:needs-device" \
    --exclude-label "on-device" --exclude-label "phone-proxy" --exclude-label "gate:queued" \
    --exclude-label "gate:reviewing" --json --sort oldest --limit="$1" 2>/dev/null
}
# The engine asks for 20 in tier 1. The refetch test below compares the size of the answer with this SAME number: one definition.
t1_window=20
t1_raw=$(t1_fetch "$t1_window") || mark 1
t1_kept=$(printf "%s" "$t1_raw" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null) || mark 1
if [ "$disk_state" = low ]; then
  # vazio/falhou/ilegível (no hold text, or jq failed) -> tier 1 answers NOTHING (inert) and is marked unreadable, like any
  # tier that could not be read: if tiers 2 and 3 find nothing either, the exit-3 line on stderr says so. A hold that could
  # not be applied is never read as "no work" and never as "go ahead"
  if [ -n "$disk_hold_jq" ] && t1_held=$(printf "%s" "$t1_kept" | jq -c "$disk_hold_jq" 2>/dev/null); then
    # The three counts below DECIDE the refetch, so all three are read the same way (gate attempt 1 caught the window size guarded
    # and its two siblings not). A count that cannot be read stays EMPTY and the decision test reads it as 0; what tells it apart
    # from a list that really has 0 beads is the mark: tier 1 is marked unreadable, so if tiers 2 and 3 find nothing either the
    # exit-3 line says `[]` is not "no work". A list that is really empty counts 0 WITHOUT the mark.
    # vazio -> 0, no mark; falhou/ilegível (jq cannot count it, or answers nothing) -> tier 1 marked, count empty = 0: the "-gt 0" fails, no refetch on a guess
    n_before=$(pp_len "$t1_kept") || mark 1
    # vazio -> 0, no mark; falhou/ilegível -> tier 1 marked, count empty = 0: the "-eq 0" holds, so at worst ONE harmless extra refetch (it re-applies veto and hold itself)
    n_after=$(pp_len "$t1_held") || mark 1
    # vazio -> 0, no mark; falhou/ilegível -> tier 1 marked, count empty = 0: the "-ge" fails, no refetch - and never the silent conclusion "the window was not full"
    n_window=$(pp_len "$t1_raw") || mark 1
    pp_log "free disk under the floor - tier 1 held back $(pp_minus "$n_before" "$n_after") new story/stories (ga-vln2py)"
    t1_kept="$t1_held"
    if [ "${n_before:-0}" -gt 0 ] && [ "${n_after:-0}" -eq 0 ] && [ "${n_window:-0}" -ge "$t1_window" ]; then
      # vazio/falhou/ilegível (bd failed, the answer is empty or not JSON, or the hold cannot read it) -> tier 1 is marked
      # unreadable and answers NOTHING (inert; exit 3 if tiers 2 and 3 find nothing either); a valid [] is a real "nothing"
      if t1_all=$(t1_fetch 0) \
        && t1_all_kept=$(printf "%s" "$t1_all" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null) \
        && t1_all_held=$(printf "%s" "$t1_all_kept" | jq -c "$disk_hold_jq" 2>/dev/null) && [ -n "$t1_all_held" ]; then
        # vazio/falhou/ilegível -> LOG TEXT ONLY (the list itself was read above and is what gets used): a count jq cannot give prints "?", never "0 left"
        n_all=$(pp_len "$t1_all_kept"); n_all_held=$(pp_len "$t1_all_held")
        pp_log "free disk under the floor, the --limit=$t1_window window held nothing but new stories - tier 1 refetched without a limit: $(pp_minus "$n_all" "$n_all_held") new story/stories held back, ${n_all_held:-?} left (ga-nyug12)"
        t1_kept="$t1_all_held"
      else
        mark 1; t1_kept="[]"
        pp_log "free disk under the floor, the --limit=$t1_window window held nothing but new stories and the unlimited refetch could not be read - tier 1 answers nothing (ga-nyug12)"
      fi
    fi
  else
    mark 1; t1_kept="[]"
    pp_log "free disk under the floor but the hold could not be applied (lib or jq) - tier 1 answers nothing (ga-vln2py)"
  fi
fi
if [ "$focus_state" = 1 ] && [ "$disk_state" != low ]; then
  # The disk block's shape, for the same reasons (the three counts DECIDE the refetch; the --limit=20 window can hold nothing but held
  # stories while a fix or a formula bead waits outside it). Its variables are reused: the two blocks never both run, a low disk skips this one.
  # vazio/falhou/ilegível (no hold text, or jq failed) -> tier 1 answers NOTHING (inert) and is marked unreadable like any tier that could not be read
  if [ -n "$focus_hold_jq" ] && t1_held=$(printf "%s" "$t1_kept" | jq -c "$focus_hold_jq" 2>/dev/null); then
    # vazio -> 0, no mark; falhou/ilegível (jq cannot count it, or answers nothing) -> tier 1 marked, count empty = 0: the "-gt 0" fails, no refetch on a guess
    n_before=$(pp_len "$t1_kept") || mark 1
    # vazio -> 0, no mark; falhou/ilegível -> tier 1 marked, count empty = 0: the "-eq 0" holds, so at worst ONE harmless extra refetch (it re-applies veto and hold itself)
    n_after=$(pp_len "$t1_held") || mark 1
    # vazio -> 0, no mark; falhou/ilegível -> tier 1 marked, count empty = 0: the "-ge" fails, no refetch - and never the silent conclusion "the window was not full"
    n_window=$(pp_len "$t1_raw") || mark 1
    pp_log "gate focus mode ON - tier 1 held back $(pp_minus "$n_before" "$n_after") new story/stories (ga-6fkx9je)"
    t1_kept="$t1_held"
    if [ "${n_before:-0}" -gt 0 ] && [ "${n_after:-0}" -eq 0 ] && [ "${n_window:-0}" -ge "$t1_window" ]; then
      # vazio/falhou/ilegível (bd failed, the answer is empty or not JSON, or the hold cannot read it) -> tier 1 is marked unreadable and
      # answers NOTHING (inert; exit 3 if tiers 2 and 3 find nothing either); a valid [] is a real "nothing"
      if t1_all=$(t1_fetch 0) \
        && t1_all_kept=$(printf "%s" "$t1_all" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null) \
        && t1_all_held=$(printf "%s" "$t1_all_kept" | jq -c "$focus_hold_jq" 2>/dev/null) && [ -n "$t1_all_held" ]; then
        # vazio/falhou/ilegível -> LOG TEXT ONLY (the list itself was read above and is what gets used): a count jq cannot give prints "?", never "0 left"
        n_all=$(pp_len "$t1_all_kept"); n_all_held=$(pp_len "$t1_all_held")
        pp_log "gate focus mode ON, the --limit=$t1_window window held nothing but new stories - tier 1 refetched without a limit: $(pp_minus "$n_all" "$n_all_held") new story/stories held back, ${n_all_held:-?} left (ga-6fkx9je)"
        t1_kept="$t1_all_held"
      else
        mark 1; t1_kept="[]"
        pp_log "gate focus mode ON, the --limit=$t1_window window held nothing but new stories and the unlimited refetch could not be read - tier 1 answers nothing (ga-6fkx9je)"
      fi
    fi
  else
    mark 1; t1_kept="[]"
    pp_log "gate focus mode ON but the hold could not be applied (lib or jq) - tier 1 answers nothing (ga-6fkx9je)"
  fi
fi
t1_kept=$(printf "%s" "$t1_kept" | drop_slings_for_taken_stories)   # ga-b97dgq: its own statement, so the line below stays the text work-order.registry.tsv matches
r=$(printf "%s" "$t1_kept" | drop_molecules_in_flight | jq -c 'sort_by(.updated_at // .created_at // "") | .[0:1]' 2>/dev/null)
found "$r"

# Tier 2 (legacy): workflow beads that carry gc.run_target=<target> and no gc.routed_to.
legacy_candidates=$(bd ready --metadata-field "gc.run_target=$target" --metadata-field "gc.kind=workflow" --unassigned --exclude-type=epic --json --sort oldest --limit=20 2>/dev/null) || mark 2
t2_unrouted=$(printf "%s" "$legacy_candidates" | jq '[.[] | select((.metadata["gc.routed_to"] // "") == "")]' 2>/dev/null) || mark 2
r=$(printf "%s" "$t2_unrouted" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null | drop_slings_for_taken_stories | jq -c '.[0:1]' 2>/dev/null)
found "$r"

# Tier 3 (legacy, ephemeral store): open, unassigned, no open blocking dependency. As in the engine, a
# jq that fails leaves "[]" appended to whatever it printed.
t3_raw=$(bd query --json 'ephemeral=true AND status=open AND assignee=none' --limit=0 2>/dev/null) || mark 3
legacy_ephemeral_candidates=$(printf "%s" "$t3_raw" | jq --arg target "$target" '[.[] | select((.assignee // "") == "") | select(((.metadata["gc.routed_to"] // "") == $target) or (((.metadata["gc.routed_to"] // "") == "") and ((.metadata["gc.run_target"] // "") == $target) and ((.metadata["gc.kind"] // "") == "workflow"))) | select(((.issue_type // .type // "") != "epic")) | select(([ (.dependencies // [])[] | select((.type // .dep_type // "") as $t | ($t == "blocks" or $t == "waits-for" or $t == "conditional-blocks")) | select((.status // .depends_on_status // "") != "closed") ] | length) == 0)] | sort_by(.created_at // "") | .[:20]' 2>/dev/null) || { mark 3; legacy_ephemeral_candidates="$legacy_ephemeral_candidates[]"; }
r=$(printf "%s" "$legacy_ephemeral_candidates" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null | drop_slings_for_taken_stories | jq -c '.[0:1]' 2>/dev/null)
found "$r"

printf "[]"
if [ -n "$unreadable" ]; then
  echo "pool-probe: tier(s)$unreadable unreadable (bd failed or answered something that is not JSON) and nothing was found - [] here does NOT mean there is no work" >&2
  exit 3
fi
