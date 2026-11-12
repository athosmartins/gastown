#!/usr/bin/env bash
# pilot-dispatcher.topup-bind-identity.selftest.sh — ga-qnarixf
#
# THE BUG (measured by the WA witness, 12/11, per the bead ga-qnarixf): the pool top-up opened TWO sessions for the same bead.
# wa-qawq7l.2 (P0) got 2 in 54 s; 10 duplicate spawns in 105 top-ups since 09/11; with a pool cap of 2 a duplicate is the whole pool on one bead.
# The chain, each link read off the dispatcher:
#   1. `_pilot_topup_spawn` ran `gc session new <pool> --title-hint "pool top-up: <bead>"` and THREW AWAY its stdout, i.e. the identity of
#      the session it had just opened;
#   2. `_topup_bind_after_spawn` then found that session again BY TITLE (exact match, or prefix + space) to write the claim on the bead;
#   3. the engine does not keep the hint: the witness counted 23 of 44 top-up sessions in the city's store with another title
#      ("Pool top-up: <id>", "Pool top-up <id>", "Pool top-up for <id>", "Pool Top-Up: <id>"), so the lookup came back empty, "fail-open", no claim;
#   4. the bead stayed open and unassigned, `_pilot_pool_topup` is a WHILE loop that re-asks bd for the best pending bead after every spawn,
#      so the next pass of the SAME loop picked the same bead again and spawned again, until the pool was full.
# (Sweeps are minutes apart: scripts/com.gascity.pilot.plist says StartInterval 600 and a comment in the dispatcher says 300; the live launchd job
# was not read from here. Either way two spawns 54 s apart are one loop, not two sweeps.)
#
# THE FIX under test: the spawn asks for `--json` and keeps what it printed; the bind writes the claim for THAT identity (the roster is
# only asked for the work_dir and to refuse a session it shows dead); the title lookup stays as the fallback for an answer that carries no
# identity; and the loop never opens a second session for the same bead in one pass, whatever the bind said ("cannot read" never opens
# another session).
#
# This is the bead's own acceptance: a FAKE ENGINE (gc + a stateful bd, both real executables because `timeout` exec()s them) that
# REWRITES the title, driving the REAL _pilot_pool_topup / _pilot_topup_spawn / _topup_bind_after_spawn / _topup_note_spawn extracted
# verbatim from the dispatcher. On the dispatcher before the fix (PILOT_DISPATCHER_PATH=<pre-fix copy>) every scenario fails except the five
# controls A-keep, A-slice, B2, F1 and F4, which pass on both. Eligibility filters and the order of the pick are stubbed (their selftests are
# pilot-dispatcher.selftest.sh and pilot-dispatcher.topup-order.selftest.sh); what is under test is spawn -> identity -> claim -> loop.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
MISSING=""
need() { # need <fn>... — the sources; a missing function is recorded, not fatal here (the FATAL below names them all)
  local _f _s
  for _f in "$@"; do
    _s="$(fn_src "$_f")"
    if [ -z "$_s" ]; then MISSING="$MISSING $_f"; else printf '%s\n' "$_s"; fi
  done
}
FUNCS="$(need _pilot_pool_topup _pilot_topup_spawn _pilot_slow_spawn_budget_spent _pilot_note_spawn_timing \
              _topup_bind_after_spawn _topup_bind_claim _topup_session_for _topup_pending_store _topup_note_spawn \
              _topup_worker_probe_migrated _topup_exclude_braked _topup_validate_input _topup_rig_pending)"
if [ -n "$MISSING" ]; then
  echo "FATAL: not found in $DISPATCHER:$MISSING (extraction pattern drifted?)" >&2
  exit 2
fi
# The helpers the fix adds. Absent on a pre-fix dispatcher on purpose: the scenarios that need them are then the RED.
MISSING=""
FUNCS_NEW="$(need _topup_spawn_identity _topup_session_by_name)"
FUNCS="$FUNCS
$FUNCS_NEW"
TOPUP_VARS="$(awk '/^_TOPUP_WORKER_EXCLUDE_LABELS=\(/{f=1} f{print} f&&/^\)$/{exit}' "$DISPATCHER")
$(grep -m1 '^_TOPUP_EPIC_TITLE_RE=' "$DISPATCHER")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-topup-bind-identity.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
E="$WORK/engine"
mkdir -p "$WORK/bin" "$WORK/city/agents/wa-worker" "$E"
# The brake (ga-653ilw) is live in production once the worker's template carries the migrated probe: give the sandbox city that
# template so the bookkeeping that runs between the spawn and the bind is the real one.
printf '%s\n' '# Step 1b2' 'X_CAND="$(' 'bd ready --metadata-field "gc.routed_to=wa-worker" --unassigned --json --limit 0' ')"' \
  '  X_SORTED="$( . "$X_LIB" && printf '"'"'%s'"'"' "$X_CAND" | work_order_sort --age reclaim )" && [ -n "$X_SORTED" ]' \
  > "$WORK/city/agents/wa-worker/prompt.template.md"

# ── the fake engine ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# gc: `session new` registers a session in the roster with the title the ENGINE chooses (title.mode: keep|cap|nocolon|for|caps|slice) and
# prints its identity ONLY when asked for --json (call.<n> can say noid = print something else, fail = exit 1, dead = the roster shows
# it closed, wd = the answer carries its own work_dir). `session list --json` prints the roster (list.fail = the call fails, list.late = it
# answers only after 6 s, which a bounded caller never sees, list.raw = it prints that text).
cat > "$WORK/bin/gc" <<'GCEOF'
#!/usr/bin/env bash
E="${FAKE_ENGINE:?}"
printf '%s\n' "$*" >> "$E/gc.calls"
case "$*" in
  *"session new"*)
    n=$(( $(cat "$E/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$E/n"
    hint=""; json=0; prev=""
    for a in "$@"; do
      [ "$prev" = "--title-hint" ] && hint="$a"
      [ "$a" = "--json" ] && json=1
      prev="$a"
    done
    callmode="$(cat "$E/call.$n" 2>/dev/null || true)"
    [ "$callmode" = "fail" ] && { echo "session new: store unavailable" >&2; exit 1; }
    id="${hint#pool top-up: }"
    case "$(cat "$E/title.mode" 2>/dev/null || echo cap)" in
      keep)    title="$hint" ;;
      cap)     title="Pool top-up: $id" ;;
      nocolon) title="Pool top-up $id" ;;
      for)     title="Pool top-up for $id" ;;
      caps)    title="Pool Top-Up: $id" ;;
      slice)   title="$hint slice two" ;;
      *)       title="$hint" ;;
    esac
    name="$(printf 'wa-worker-gawisp%03d' "$n")"
    closed=false; state=creating
    [ "$callmode" = "dead" ] && { closed=true; state=closed; }
    [ -e "$E/list.lag" ] || jq -cn --arg n "$name" --arg i "ga-wisp-$n" --arg t "$title" --arg s "$state" --argjson c "$closed" \
      --arg wd "/rig/wa/crew/w$n" --arg ca "$(printf '2026-11-12T10:00:%02dZ' "$n")" \
      '{id: $i, name: $n, session_name: $n, alias: $n, agent_name: $n, template: "wa-worker", title: $t, state: $s, work_dir: $wd,
        created_at: $ca, closed: $c}' >> "$E/roster.ndjson"
    if [ "$json" = "1" ] && [ "$callmode" = "wd" ]; then
      jq -cn --arg n "$name" --arg i "ga-wisp-$n" '{session_id: $i, session_name: $n, alias: $n, work_dir: "/from/answer"}'
    elif [ "$json" = "1" ] && [ "$callmode" != "noid" ]; then
      jq -cn --arg n "$name" --arg i "ga-wisp-$n" '{session_id: $i, session_name: $n, alias: $n}'
    else
      echo "Session $name created."
    fi
    exit 0 ;;
  *"session list"*)
    [ -e "$E/list.fail" ] && { echo "listing sessions: search wisps (merge): search wisps: invalid connection" >&2; exit 1; }
    [ -e "$E/list.late" ] && sleep 6 >/dev/null 2>&1
    [ -f "$E/list.raw" ] && { cat "$E/list.raw"; exit 0; }
    if [ -f "$E/roster.ndjson" ]; then jq -sc '{ok: true, schema_version: "1", sessions: ., summary: {}}' "$E/roster.ndjson"
    else echo '{"ok":true,"schema_version":"1","sessions":[],"summary":{}}'; fi
    exit 0 ;;
esac
exit 0
GCEOF
# bd: a stateful store in $E/beads.json. ready = open + unassigned + routed to the pool (what the top-up asks); show; list --assignee
# --status; update with the CAS flags the claim uses (exit 13 = the condition failed); label/comment recorded. update.fail = every
# update fails; update.fail.assignee = only an update that sets the assignee (the CLAIM) fails, the brake's metadata writes still land.
cat > "$WORK/bin/bd" <<'BDEOF'
#!/usr/bin/env bash
E="${FAKE_ENGINE:?}"
printf '%s\n' "$*" >> "$E/bd.calls"
store="$E/beads.json"
args=(); skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  if [ "$a" = "-C" ]; then skip=1; continue; fi
  args+=("$a")
done
cmd="${args[0]:-}"
case "$cmd" in
  ready)
    pool=""; prev=""
    for a in "${args[@]}"; do case "$prev" in --metadata-field) pool="${a#gc.routed_to=}" ;; esac; prev="$a"; done
    jq -c --arg p "$pool" '[.[] | select(.status == "open") | select((.assignee // "") == "") | select((.metadata["gc.routed_to"] // "") == $p)] | sort_by(.priority)' "$store"
    exit 0 ;;
  show)
    [ -e "$E/show.fail" ] && exit 1
    out="$(jq -c --arg id "${args[1]:-}" '[.[] | select(.id == $id)]' "$store")"
    [ "$out" = "[]" ] && exit 1
    printf '%s\n' "$out"; exit 0 ;;
  list)
    st=""; asg=""; prev=""
    for a in "${args[@]}"; do
      case "$prev" in --status) st="$a" ;; --assignee) asg="$a" ;; esac
      prev="$a"
    done
    jq -c --arg st "$st" --arg asg "$asg" '[.[] | select(($st == "") or (.status == $st)) | select(($asg == "") or ((.assignee // "") == $asg))]' "$store"
    exit 0 ;;
  update)
    id="${args[1]:-}"
    st=""; asg=""; asg_set=0; ifasg=""; ifasg_set=0; ifst=""; ifst_set=0; md='{}'; prev=""
    for a in "${args[@]:2}"; do
      case "$prev" in
        --status) st="$a" ;;
        --assignee) asg="$a"; asg_set=1 ;;
        --if-assignee) ifasg="$a"; ifasg_set=1 ;;
        --if-status) ifst="$a"; ifst_set=1 ;;
        --set-metadata) md="$(jq -c --arg k "${a%%=*}" --arg v "${a#*=}" '. + {($k): $v}' <<<"$md")" ;;
      esac
      prev="$a"
    done
    [ -e "$E/update.fail" ] && exit 1
    [ "$asg_set" = 1 ] && [ -e "$E/update.fail.assignee" ] && exit 1
    cur="$(jq -c --arg id "$id" '[.[] | select(.id == $id)][0] // empty' "$store")"
    [ -n "$cur" ] || exit 1
    if [ "$ifasg_set" = 1 ] && [ "$(jq -r '.assignee // ""' <<<"$cur")" != "$ifasg" ]; then exit 13; fi
    if [ "$ifst_set" = 1 ] && [ "$(jq -r '.status // ""' <<<"$cur")" != "$ifst" ]; then exit 13; fi
    jq -c --arg id "$id" --arg st "$st" --arg asg "$asg" --argjson asg_set "$asg_set" --argjson md "$md" \
      'map(if .id == $id then
             (if $st != "" then .status = $st else . end)
             | (if $asg_set == 1 then .assignee = $asg else . end)
             | .metadata = ((.metadata // {}) + $md)
           else . end)' "$store" > "$store.new" && mv "$store.new" "$store"
    exit 0 ;;
  label|comment) exit 0 ;;
esac
exit 0
BDEOF
chmod +x "$WORK/bin/gc" "$WORK/bin/bd"
sandbox_path_init "$WORK" timeout jq || exit 2

# ── fixtures and the runner ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
new_engine() { # new_engine [title.mode] — a clean engine: no sessions, no beads, no failure switches
  rm -rf "$E"; mkdir -p "$E"
  printf '%s' "${1:-cap}" > "$E/title.mode"
  echo '[]' > "$E/beads.json"
  : > "$WORK/log.txt"
}
add_bead() { # add_bead <id> [priority] — an open, unassigned bead routed to wa-worker
  jq -c --arg id "$1" --argjson p "${2:-1}" \
    '. + [{id: $id, title: ("T " + $id), status: "open", priority: $p, issue_type: "task", assignee: "",
           created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z", labels: [], metadata: {"gc.routed_to": "wa-worker"}}]' \
    "$E/beads.json" > "$E/beads.new" && mv "$E/beads.new" "$E/beads.json"
}
# run_pass <max> [shell to eval before the pass] — ONE _pilot_pool_topup pass over wa-worker, in a subshell with the dispatcher's own
# `set -euo pipefail`; log()/warn() land in $WORK/log.txt.
run_pass() {
  local _pre="${2:-:}"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"
    FAKE_ENGINE="$E"; export FAKE_ENGINE
    GC_CITY="$WORK/city"; DRY_RUN="${RP_DRY:-0}"; GC_VARIABLE_SESSION_MAX=100
    PILOT_DOLT_SATURATED_AT_START=0; _PILOT_NODE_ONLY=0; PRIORITY_YIELDED=0
    PILOT_SPAWN_TIMEOUT_SECS=30; PILOT_TOPUP_RETRY_DELAY_SECS=0
    export PILOT_TEST_WA_WORKER_LIVE_COUNT=0
    log()  { printf 'log\t%s\n'  "$*" >> "$WORK/log.txt"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/log.txt"; }
    # Stubbed on purpose: eligibility and the order of the pick are other selftests' business.
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }
    _topup_pick_first() { jq -r '.[0].id // empty'; }
    _pilot_variable_session_count() { _PLSC_N=0; return 0; }
    _pilot_priority_yield_for_id() { return 1; }
    _topup_hq_serves_pool() { return 0; }
    eval "$TOPUP_VARS"; eval "$FUNCS"
    _TOPUP_RIG_PATHS=""
    eval "$_pre"
    _pilot_pool_topup wa-worker "$1"
  ) >> "$WORK/pass.out" 2>> "$WORK/pass.err"
}
spawns()       { cat "$E/n" 2>/dev/null || echo 0; }
bead_field()   { jq -r --arg id "$1" "[.[] | select(.id == \$id)][0] | $2" "$E/beads.json" 2>/dev/null; }
bead_asg()     { bead_field "$1" '.assignee // ""'; }
bead_meta()    { bead_field "$1" ".metadata[\"$2\"] // \"\""; }
logged()       { grep -qF -- "$1" "$WORK/log.txt" 2>/dev/null; }
warned()       { grep -F -- "warn	" "$WORK/log.txt" 2>/dev/null | grep -qF -- "$1"; }
warned_all()   { grep -F -- "warn	" "$WORK/log.txt" 2>/dev/null | grep -F -- "$1" | grep -qF -- "$2"; }   # ONE warn line carrying both texts
dump()         { echo "      log: $(tr '\n' '|' < "$WORK/log.txt" | cut -c1-900)"; echo "      gc: $(tr '\n' '|' < "$E/gc.calls" 2>/dev/null | cut -c1-500)"; }
S1="wa-worker-gawisp001"; S2="wa-worker-gawisp002"

echo "pilot-dispatcher.topup-bind-identity.selftest — the top-up binds the session it opened by the identity the spawn returned (ga-qnarixf)"

# ── A: the bug, with the engine rewriting the title ────────────────────────────────────────────────────────────────
echo "A. the engine REWRITES the title the Pilot asked for — one session, claimed by the identity the spawn returned"
for mode in cap nocolon for caps; do
  new_engine "$mode"; add_bead wa-p1 0
  run_pass 2
  if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] && [ "$(bead_field wa-p1 .status)" = "in_progress" ]; then
    ok "A-$mode: ONE session for the bead (cap 2), and the bead is in_progress with assignee = $S1"
  else
    bad "A-$mode: spawns=$(spawns) (want 1), assignee='$(bead_asg wa-p1)' (want $S1)"; dump
  fi
  if [ "$(bead_meta wa-p1 gc.session_name)" = "$S1" ] && [ "$(bead_meta wa-p1 gc.work_dir)" = "/rig/wa/crew/w1" ]; then
    ok "A-$mode: gc.session_name / gc.work_dir written (the reclaim guard heals from them): the work_dir is the ROSTER row of that very identity"
  else
    bad "A-$mode: gc.session_name='$(bead_meta wa-p1 gc.session_name)' gc.work_dir='$(bead_meta wa-p1 gc.work_dir)'"
  fi
done
new_engine keep; add_bead wa-p1 0
run_pass 2
[ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] \
  && ok "A-keep (control, passes before the fix too): the engine keeps the hint — one session, claimed" || { bad "A-keep: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump; }
new_engine slice; add_bead wa-p1 0
run_pass 2
[ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] \
  && ok "A-slice (control, passes before the fix too): '<hint> slice two' is the one rewrite the old prefix rule caught" || { bad "A-slice: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump; }

# ── B: what the spawn asks for and keeps ───────────────────────────────────────────────────────────────────────────────────────────────
echo "B. the spawn call"
new_engine cap; add_bead wa-p1 0
run_pass 2
if grep -q 'session new wa-worker --no-attach' "$E/gc.calls" && ! grep 'session new' "$E/gc.calls" | grep -qv -e '--json'; then
  ok "B1 every 'session new' of the top-up asks for --json (that is where the identity comes from)"
else
  bad "B1 a 'session new' call without --json: $(grep 'session new' "$E/gc.calls" | tr '\n' '|')"
fi
if grep 'session new' "$E/gc.calls" | grep -qF -- '--title-hint pool top-up: wa-p1'; then
  ok "B2 the hint 'pool top-up: <bead>' is still passed (a person reading 'gc session list' can tell what the session was opened for)"
else
  bad "B2 the title hint is gone: $(grep 'session new' "$E/gc.calls" | tr '\n' '|')"
fi

# ── C: the loop never opens a second session for the same bead in one pass ─────────────────────────────────────────
echo "C. whatever the bind says, one pass never opens a second session for the bead (cannot read NEVER opens another)"
new_engine cap; add_bead wa-p1 0; echo noid > "$E/call.1"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "" ]; then
  ok "C1 the engine printed no identity (and rewrote the title, so the title fallback misses too): ONE session, no claim written on a guess"
else
  bad "C1: spawns=$(spawns) (want 1), assignee='$(bead_asg wa-p1)' (want empty)"; dump
fi
if warned_all "wa-p1" "NOT opening a second"; then
  ok "C1b the pass says out loud that it stopped: ONE WARN naming the bead and the second session it did not open"
else
  bad "C1b no WARN line names wa-p1 and the refused second session"; dump
fi
if warned "gave no usable session identity"; then
  ok "C1c ...and an earlier WARN says why nothing was claimed: the spawn gave no usable identity (and the title fallback then missed)"
else
  bad "C1c no WARN about the missing identity"; dump
fi
new_engine cap; add_bead wa-p1 0; : > "$E/update.fail.assignee"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "" ] && warned "could not write the claim"; then
  ok "C2 the claim WRITE fails: ONE session, the failure is warned, the bead is not claimed on a guess"
else
  bad "C2: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi
new_engine keep; add_bead wa-p1 0; : > "$E/show.fail"
run_pass 2
if [ "$(spawns)" = "1" ]; then
  ok "C3 the bead's store cannot be read at bind time: ONE session (an unreadable store never reads as 'nobody has it')"
else
  bad "C3: spawns=$(spawns) (want 1)"; dump
fi
new_engine cap; add_bead wa-p1 0
run_pass 2 'PILOT_TOPUP_BIND=0'
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "" ]; then
  ok "C4 PILOT_TOPUP_BIND=0 (the bind kill switch): nothing is claimed, and still ONE session — the loop guard does not depend on the bind"
else
  bad "C4: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi

# ── D: the identity path does not depend on the roster ─────────────────────────────────────────────────────────────────────────────────────
echo "D. the identity is the engine's word; the roster only adds the work_dir and vetoes a dead session"
new_engine cap; add_bead wa-p1 0; : > "$E/list.fail"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] && [ -z "$(bead_meta wa-p1 gc.work_dir)" ] && [ "$(bead_meta wa-p1 gc.session_name)" = "$S1" ]; then
  ok "D1 the roster cannot be read: the claim is still written for the identity the spawn returned, without gc.work_dir"
else
  bad "D1: spawns=$(spawns) assignee='$(bead_asg wa-p1)' work_dir='$(bead_meta wa-p1 gc.work_dir)'"; dump
fi
new_engine cap; add_bead wa-p1 0; : > "$E/list.lag"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] && [ -z "$(bead_meta wa-p1 gc.work_dir)" ]; then
  ok "D2 the roster is readable but does not list the new session yet (lag): the claim is written, without gc.work_dir"
else
  bad "D2: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi
new_engine cap; add_bead wa-p1 0; echo dead > "$E/call.1"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "" ] && warned "not live"; then
  ok "D3 the roster shows the new session already CLOSED: no claim on a dead session, a WARN, and still ONE session"
else
  bad "D3: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi

new_engine cap; add_bead wa-p1 0; : > "$E/list.late"
run_pass 1 'PILOT_TOPUP_ROSTER_TIMEOUT_SECS=2'
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] && warned "could not read the session roster"; then
  ok "D4 the roster does not answer within the budget (2 s here, 20 s in production): that is 'cannot tell' too — the claim is written anyway"
else
  bad "D4: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi
# The stub answers after 6 s with a roster that WOULD give the claim a work_dir: a caller that waited for it (no timeout, or a timeout that
# does not bite) writes /rig/wa/crew/w1, one that gave up at 2 s writes none. The difference is in the data, so no clock is read.
if [ "$(bead_asg wa-p1)" = "$S1" ] && [ -z "$(bead_meta wa-p1 gc.work_dir)" ]; then
  ok "D4b ...and the wait is BOUNDED: the claim is there and the late roster never reached it (no gc.work_dir)"
else
  bad "D4b: the claim carries gc.work_dir='$(bead_meta wa-p1 gc.work_dir)' from a roster that answered after the budget — the lookup is not bounded by PILOT_TOPUP_ROSTER_TIMEOUT_SECS"
fi
new_engine cap; add_bead wa-p1 0; echo wd > "$E/call.1"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ] && [ "$(bead_meta wa-p1 gc.work_dir)" = "/from/answer" ]; then
  ok "D5 the answer carries its own work_dir and the roster lists another: the engine's own answer wins"
else
  bad "D5: spawns=$(spawns) assignee='$(bead_asg wa-p1)' work_dir='$(bead_meta wa-p1 gc.work_dir)' (want /from/answer)"; dump
fi

# ── E: two beads, two sessions, each claimed by ITS OWN identity ─────────────────────────────────────────────────────
echo "E. two pending beads: the second session is not mistaken for the first"
new_engine cap; add_bead wa-p1 0; add_bead wa-p2 1
run_pass 2
if [ "$(spawns)" = "2" ] && [ "$(bead_asg wa-p1)" = "$S1" ] && [ "$(bead_asg wa-p2)" = "$S2" ]; then
  ok "E1 wa-p1 -> $S1 and wa-p2 -> $S2: two sessions, two claims, the identities not crossed (cap 2)"
else
  bad "E1: spawns=$(spawns) wa-p1='$(bead_asg wa-p1)' wa-p2='$(bead_asg wa-p2)'"; dump
fi
new_engine cap; add_bead wa-p1.2 0; add_bead wa-p1 1
run_pass 2
if [ "$(spawns)" = "2" ] && [ "$(bead_asg wa-p1.2)" = "$S1" ] && [ "$(bead_asg wa-p1)" = "$S2" ]; then
  ok "E2 wa-p1.2 then wa-p1 (one id inside the other): both get a session — the one-session-per-bead guard matches whole ids, never a part of one"
else
  bad "E2: spawns=$(spawns) wa-p1.2='$(bead_asg wa-p1.2)' wa-p1='$(bead_asg wa-p1)'"; dump
fi
new_engine cap; add_bead wa-p1 0; add_bead wa-p2 1; echo noid > "$E/call.2"
run_pass 2
if [ "$(bead_asg wa-p1)" = "$S1" ] && [ "$(bead_asg wa-p2)" = "" ] && [ "$(spawns)" = "2" ]; then
  ok "E3 the SECOND spawn prints no identity: wa-p2 is NOT claimed for the first session's name (no stale identity), wa-p1 keeps its claim"
else
  bad "E3: spawns=$(spawns) wa-p1='$(bead_asg wa-p1)' wa-p2='$(bead_asg wa-p2)'"; dump
fi

# ── F: the fallback and the failure paths that must stay as they were ──────────────────────────────────────────────────────────────────
echo "F. no identity in the answer: the title lookup is still the fallback"
new_engine keep; add_bead wa-p1 0; echo noid > "$E/call.1"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "$S1" ]; then
  ok "F1 the answer has no identity but the title is the hint: the claim is written through the title lookup, ONE session"
else
  bad "F1: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi
new_engine keep; add_bead wa-p1 0; : > "$E/list.fail"; echo noid > "$E/call.1"
run_pass 2
if [ "$(spawns)" = "1" ] && [ "$(bead_asg wa-p1)" = "" ] && warned "CANNOT TELL"; then
  ok "F2 no identity AND an unreadable roster: nothing claimed, the 'CANNOT TELL' warn is kept, ONE session (the loop does not retry on a doubt)"
else
  bad "F2: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi
new_engine cap; add_bead wa-p1 0; echo fail > "$E/call.1"
run_pass 2
if [ "$(spawns)" = "2" ] && [ "$(bead_asg wa-p1)" = "$S2" ]; then
  ok "F3 attempt 1 of the spawn fails, the retry succeeds: the claim goes to the session of the RETRY ($S2), never to a stale identity"
else
  bad "F3: spawns=$(spawns) assignee='$(bead_asg wa-p1)' (want 2 calls, claim on $S2)"; dump
fi
new_engine cap; add_bead wa-p1 0
RP_DRY=1 run_pass 2
if [ "$(spawns)" = "0" ] && [ "$(bead_asg wa-p1)" = "" ] && logged "WOULD"; then
  ok "F4 DRY_RUN=1: no session, no claim, the log says WOULD"
else
  bad "F4: spawns=$(spawns) assignee='$(bead_asg wa-p1)'"; dump
fi

# ── G: _topup_spawn_identity — what an answer must look like to be an identity ──────────────────────────────────────────────────────────
echo "G. _topup_spawn_identity: an identity, 'the engine did not say who' (1) and 'unreadable' (2) are three different answers, never a guess"
ident() { # ident <answer> -> "rc|name|work_dir"
  ( PATH="$SANDBOX_PATH"; eval "$FUNCS"; _TOPUP_SPAWN_OUT="$1"; _irc=0; _topup_spawn_identity 2>/dev/null || _irc=$?
    printf '%s|%s|%s' "$_irc" "${_TOPUP_IDENT_NAME:-}" "${_TOPUP_IDENT_WD:-}" )
}
g_expect() { # g_expect <description> <want "rc|name|work_dir"> <answer>
  local _got; _got="$(ident "$3")"
  if [ "$_got" = "$2" ]; then ok "G: $1 → $_got"; else bad "G: $1 → '$_got' (want '$2')"; fi
}
g_expect "a full answer"                         "0|wa-worker-gawisp001|"  '{"session_id":"ga-wisp-1","session_name":"wa-worker-gawisp001"}'
g_expect "a work_dir in the answer is kept"      "0|s-1|/w/s-1"            '{"session_name":"s-1","work_dir":"/w/s-1"}'
g_expect "the alias when there is no session_name" "0|a-1|"                '{"alias":"a-1"}'
g_expect "session_name wins over the alias"      "0|s-1|"                  '{"session_name":"s-1","alias":"a-1"}'
g_expect "a pretty-printed answer"               "0|s-1|"                  $'{\n  "session_id": "x",\n  "session_name": "s-1"\n}\n'
g_expect "an empty answer (1: did not say)"      "1||"                     ''
g_expect "only whitespace (1)"                   "1||"                     $' \n\t '
g_expect "an object that names no session (1)"   "1||"                     '{"session_id":"x"}'
g_expect "an empty session_name, no alias (1)"   "1||"                     '{"session_name":""}'
g_expect "a null session_name (1)"               "1||"                     '{"session_name":null}'
g_expect "a non-text session_name (1)"           "1||"                     '{"session_name":5}'
g_expect "human text, not JSON (2: unreadable)"  "2||"                     'Session wa-worker-gawisp001 created.'
g_expect "a JSON array (2)"                      "2||"                     '[{"session_name":"s-1"}]'
g_expect "two objects (2)"                       "2||"                     '{"session_name":"s-1"}{"session_name":"s-2"}'
g_expect "a bare number (2)"                     "2||"                     '5'
g_expect "a bare null (2: not an object, so not 'names no session')" "2||"   'null'
g_expect "a name starting with a dash (2: it would read as a flag)" "2||"   '{"session_name":"-rf"}'
g_expect "a name starting with a dot (2)"        "2||"                     '{"session_name":".hidden"}'
g_expect "a name with a space (2)"               "2||"                     '{"session_name":"a b"}'
g_expect "a name with a shell metacharacter (2)" "2||"                     '{"session_name":"a;b"}'
g_expect "a name with a newline (2)"             "2||"                     "$(jq -cn --arg n $'a\nb' '{session_name: $n}')"
# The two states must also SAY different things: the caller's WARN is the only place the difference shows.
why_of() { ( PATH="$SANDBOX_PATH"; eval "$FUNCS"; _TOPUP_SPAWN_OUT="$1"; _topup_spawn_identity 2>/dev/null; printf '%s' "${_TOPUP_IDENT_WHY:-}" ) || true; }
w_empty="$(why_of '')"; w_obj="$(why_of '{"x":1}')"; w_text="$(why_of 'Session created.')"
if [ -n "$w_empty" ] && [ -n "$w_obj" ] && [ -n "$w_text" ] && [ "$w_empty" != "$w_obj" ] && [ "$w_obj" != "$w_text" ] && printf '%s' "$w_text" | grep -qF 'Session created.'; then
  ok "G: each failure has its OWN reason (nothing printed / names no session / not JSON, quoting what it started with)"
else
  bad "G: the reasons do not tell the states apart: '$w_empty' / '$w_obj' / '$w_text'"
fi

# ── H: _topup_session_by_name — the roster row of the session the spawn named ───────────────────────────────────────────────────────────
echo "H. _topup_session_by_name: live / not live / not listed / cannot tell"
US=$'\037'
rrow() { # rrow <session_name> <state> <closed true|false> <created_at> [alias] [id] [work_dir]
  jq -cn --arg n "$1" --arg s "$2" --argjson c "$3" --arg ca "$4" --arg al "${5:-$1}" --arg id "${6:-ga-wisp-$1}" --arg wd "${7:-/wd/$1}" \
    '{id: $id, name: $n, session_name: $n, alias: $al, agent_name: $n, template: "wa-worker", title: "x", state: $s, work_dir: $wd, created_at: $ca, closed: $c}'
}
roster() { rm -f "$E/list.fail" "$E/list.late" "$E/list.raw"; : > "$E/roster.ndjson"; local _r; for _r in "$@"; do printf '%s\n' "$_r" >> "$E/roster.ndjson"; done; }
by_name() { # by_name <name> [shell to eval first] -> "rc|stdout"
  ( PATH="$SANDBOX_PATH"; FAKE_ENGINE="$E"; export FAKE_ENGINE; GC_CITY="$WORK/city"
    eval "$FUNCS"; eval "${2:-:}"; _o=""; _brc=0; _o=$(_topup_session_by_name "$1") || _brc=$?; printf '%s|%s' "$_brc" "$_o" )
}
h_expect() { # h_expect <description> <want> <name> [shell]
  local _got; _got="$(by_name "$3" "${4:-:}")"
  if [ "$_got" = "$2" ]; then ok "H: $1"; else bad "H: $1 → '$_got' (want '$2')"; fi
}
h_fails() { # h_fails <description> <name> [shell] — exit 1 with nothing printed is 'cannot tell' (the contract in the function's header)
  local _got; _got="$(by_name "$2" "${3:-:}")"
  if [ "$_got" = "1|" ]; then ok "H: $1 → exit 1, nothing printed"; else bad "H: $1 → '$_got' (want '1|')"; fi
}
new_engine cap
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z)"
h_expect "an active session is live (1) and its work_dir comes with it" "0|1${US}/wd/s-1" s-1
roster "$(rrow s-1 creating false 2026-11-12T10:00:01Z)"; h_expect "creating is live" "0|1${US}/wd/s-1" s-1
roster "$(rrow s-1 start-pending false 2026-11-12T10:00:01Z)"; h_expect "start-pending is live" "0|1${US}/wd/s-1" s-1
roster "$(rrow s-1 active true 2026-11-12T10:00:01Z)"; h_expect "closed:true is NOT live (0) even when the state says active" "0|0${US}/wd/s-1" s-1
roster "$(rrow s-1 closed false 2026-11-12T10:00:01Z)"; h_expect "state closed is not live" "0|0${US}/wd/s-1" s-1
roster "$(rrow s-1 asleep false 2026-11-12T10:00:01Z)"; h_expect "an asleep session builds nothing: not live" "0|0${US}/wd/s-1" s-1
roster "$(rrow wa-w-9 active false 2026-11-12T10:00:01Z wa-alias-1)"; h_expect "found by its alias" "0|1${US}/wd/wa-w-9" wa-alias-1
roster "$(rrow wa-w-9 active false 2026-11-12T10:00:01Z wa-alias-1 ga-wisp-77)"; h_expect "found by its id" "0|1${US}/wd/wa-w-9" ga-wisp-77
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z s-1 ga-wisp-1 /wd/old)" "$(rrow s-1 closed true 2026-11-12T10:00:09Z s-1 ga-wisp-2 /wd/new)"
h_expect "two rows of the same name: the NEWEST one answers (a re-created session)" "0|0${US}/wd/new" s-1
roster "$(rrow s-2 active false 2026-11-12T10:00:01Z)"; h_expect "not listed: answered, nothing printed (still registering)" "0|" s-1
roster; h_expect "an empty roster: answered, nothing printed" "0|" s-1
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z)"; : > "$E/list.fail"; h_fails "the call fails: cannot tell, not 'not listed'" s-1
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z)"; echo 'not json' > "$E/list.raw"; h_fails "the roster is not JSON: cannot tell" s-1
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z)"; echo '{"ok":true}' > "$E/list.raw"; h_fails "the roster has no sessions array: cannot tell" s-1
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z)"; : > "$E/list.late"; h_fails "the roster answers after the budget (2 s here): cannot tell — the late answer is never used" s-1 'PILOT_TOPUP_ROSTER_TIMEOUT_SECS=2'
roster "$(rrow s-1 active false 2026-11-12T10:00:01Z)"; h_fails "no name at all (a clean roster: only the name check can answer 1)" ""

echo ""
echo "pilot-dispatcher.topup-bind-identity.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
