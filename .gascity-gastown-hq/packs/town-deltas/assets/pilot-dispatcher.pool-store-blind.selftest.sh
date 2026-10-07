#!/usr/bin/env bash
# pilot-dispatcher.pool-store-blind.selftest.sh — ga-653ilw.
#
# Bug ga-653ilw (measured 27/09-01/10): the Pilot's pool top-up spawned a ps-worker every ~23 min for
# lx-b5q — a bead living in the LEXBH store — 251 times, and every one of those sessions found nothing and
# drained (~188k WTE each). A pool worker reads exactly ONE store: the rig clone it runs in (ps-worker's
# work_dir is property_scrapers/crew/worker, wa-worker's is whatsapp_automation/crew/worker). Three holes let
# a bead the pool can never see keep spawning workers:
#
#   1. DISPATCH (root). The ga-wnojmm reroute sends a lexbh bead to ps-worker but leaves STORY_BEAD_CITY on the
#      lexbh store, and the rig-native pool arm just leaves it "unassigned + routed" for the worker to find.
#      Only gastown.dog had a store-blind guard (ga-cszxcf). Fix: _pilot_pool_store_blind_guard, and the call
#      site migrates the bead into the pool's OWN store (same machinery as ga-6u64fm) or parks it.
#   2. TOP-UP SCAN. _topup_rig_pending looked for gc.routed_to=<pool> in EVERY non-HQ rig store, so it found
#      lx-b5q for ps-worker. Fix: scan only the rig(s) whose own builder pool IS <pool>.
#   3. NO BRAKE. Nothing counted spawns per bead. Fix: _topup_note_spawn counts consecutive top-up spawns for
#      the same bead; at the cap (default 5) the bead is labelled pilot:topup-braked, commented, and
#      _topup_exclude_braked drops it from the candidates (so it cannot block the beads queued behind it).
#
# Falsifiable: run it against the pre-fix dispatcher
#   PILOT_DISPATCHER_PATH=<pre-fix pilot-dispatcher.sh> bash <this file>
# and every Part fails on an assertion (B1/B2 get the wrong bead, C1 sees 12 spawns instead of 5).
#
# Conventions: verbatim function extraction (awk) from the live dispatcher + PATH-stubbed gc/bd inside the
# sandbox PATH (selftest-sandbox-path.lib.sh: the REAL gc/bd cannot resolve). bash 3.2-safe.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.pool-store-blind.selftest.sh
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-pool-store-blind-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/bin" "$WORK/city" "$WORK/rigs/lexbh" "$WORK/rigs/property_scrapers" \
         "$WORK/rigs/whatsapp_automation" "$WORK/rigs/gastown" "$WORK/rigs/marketing" "$WORK/stores"
ln -s "$WORK/rigs/property_scrapers" "$WORK/rigs/ps-link"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK" timeout jq || exit 2
export FAKE_WORK="$WORK"

# ga-9t9acg.4: the respawn brake counts a top-up spawn only while the pool worker's template carries the migrated Step 1b2
# probe (_topup_worker_probe_migrated reads $GC_CITY/agents/<pool>/prompt.template.md). This selftest is about the brake and
# the store scoping, not about the probe: its sandbox city declares a worker that is on the shared order. (The cases where
# it is not — brake off, visibly — are pilot-dispatcher.topup-order.selftest.sh part F.)
for _p in wa-worker ps-worker; do
  mkdir -p "$WORK/city/agents/$_p"
  cat > "$WORK/city/agents/$_p/prompt.template.md" <<'TPL'
  X_SORTED="$( . "$X_LIB" && printf '%s' "$X_CAND" | work_order_sort --age reclaim )" && [ -n "$X_SORTED" ]
TPL
done

# ── extraction ──────────────────────────────────────────────────────────────
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
MISSING=""
need() { # need <fn>... — echoes the extracted sources; records (does not abort on) a missing function
  local _f _s
  for _f in "$@"; do
    _s="$(fn_src "$_f")"
    if [ -z "$_s" ]; then MISSING="$MISSING $_f"; else printf '%s\n' "$_s"; fi
  done
}

# Everything the guard needs, defined together so a sandbox can never silently lack one.
GUARD_PRELUDE="$(need gc_json_or_unknown rig_root_path rig_to_builders wa_worker_template \
                      _pilot_rig_builds_pool _pilot_pool_rig _pilot_same_dir _pilot_pool_store_blind_guard)"
# ga-9t9acg.4: the top-up pick goes through _topup_pick_first, which orders with scripts/work-order.sh. Both are part of
# the preludes: without the lib the helper runs its fallback (the previous pick + a WARN), and a prelude that lacks the
# helper itself fails with "command not found" — either way this selftest would stop testing the store scoping.
WO_LIB_PRELUDE='. "$SELF_DIR/scripts/work-order.sh"'
[ -r "$SELF_DIR/scripts/work-order.sh" ] || { echo "FATAL: $SELF_DIR/scripts/work-order.sh missing" >&2; exit 2; }
TOPUP_PRELUDE="$WO_LIB_PRELUDE
$(need rig_to_builders wa_worker_template _pilot_rig_builds_pool _topup_rig_serves_pool _topup_exclude_braked _topup_pick_first _topup_rig_pending)"
LOOP_PRELUDE="$WO_LIB_PRELUDE
$(need rig_to_builders wa_worker_template _pilot_rig_builds_pool _topup_rig_serves_pool _topup_rig_pending \
                     _topup_exclude_braked _topup_pick_first _topup_pending_store _topup_note_spawn _topup_worker_probe_migrated _pilot_pool_topup)"
MIGRATE_PRELUDE="$(need gc_json_or_unknown rig_root_path rig_to_builders rig_to_builder wa_worker_template \
                        _pilot_text_names_rig_path _pilot_story_already_migrated _pilot_dog_store_blind_guard \
                        _pilot_dog_store_blind_migrate_dest _pilot_is_bead_id _pilot_migration_copy_retract \
                        _pilot_retract_orphan_migration_copies _pilot_migration_original_state \
                        _pilot_migrate_dog_store_blind_bead _pilot_dog_store_try_migrate)"
TOPUP_VARS="$(awk '/^_TOPUP_WORKER_EXCLUDE_LABELS=\(/{f=1} f{print} f&&/^\)$/{exit}' "$DISPATCHER")
$(grep -m1 '^_TOPUP_EPIC_TITLE_RE=' "$DISPATCHER")"

echo "pilot-dispatcher.pool-store-blind.selftest — ga-653ilw"
if [ -n "$MISSING" ]; then
  echo "  (pre-fix dispatcher? these functions are not defined:$MISSING — the scenarios that need them fail below)"
fi

# ── fakes ───────────────────────────────────────────────────────────────────
write_rigs() { # the registered rig list the fake `gc rig list --json` returns
  cat > "$WORK/rigs.json" <<EOF
{"rigs":[
 {"name":"gascity","path":"$WORK/city","hq":true},
 {"name":"lexbh","path":"$WORK/rigs/lexbh","hq":false},
 {"name":"property_scrapers","path":"$WORK/rigs/property_scrapers","hq":false},
 {"name":"gastown","path":"$WORK/rigs/gastown","hq":false},
 {"name":"marketing","path":"$WORK/rigs/marketing","hq":false},
 {"name":"whatsapp_automation","path":"$WORK/rigs/whatsapp_automation","hq":false}
]}
EOF
}
write_rigs

cat > "$WORK/bin/gc" <<'GC'
#!/usr/bin/env bash
case "$*" in
  *"rig list"*) [ -f "$FAKE_WORK/gc_fail" ] && exit 1; cat "$FAKE_WORK/rigs.json" ;;
  *) : ;;
esac
exit 0
GC
chmod +x "$WORK/bin/gc"

# A stateful fake bd. One bead per file: $FAKE_WORK/stores/<basename of the -C dir>/<id>.json. Only the verbs
# the code under test uses: ready / show / update --set-metadata / label add / comment.
cat > "$WORK/bin/bd" <<'BD'
#!/usr/bin/env bash
W="${FAKE_WORK:?}"
printf 'bd\t%s\n' "$*" >> "$W/bd.calls"
store=""
if [ "${1:-}" = "-C" ]; then store="$(basename "$2")"; shift 2; fi
sub="${1:-}"; shift || true
dir="$W/stores/$store"
case "$sub" in
  ready)
    want=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--metadata-field" ] && want="${a#gc.routed_to=}"
      prev="$a"
    done
    out="[]"
    if [ -d "$dir" ] && ls "$dir"/*.json >/dev/null 2>&1; then
      out=$(cat "$dir"/*.json | jq -s --arg w "$want" '[.[] | select((.assignee // "") == "") | select(.status == "open") | select((.metadata["gc.routed_to"] // "") == $w)]')
    fi
    printf '%s\n' "${out:-[]}"
    ;;
  show)
    id="$1"
    if [ -f "$dir/$id.json" ]; then
      n=$(cat "$W/show.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$W/show.n"
      # FAKE_SHOW_FAIL_FROM=N: the Nth and later SUCCESSFUL shows fail (a Dolt hiccup), so one call can be targeted.
      if [ "${FAKE_SHOW_FAIL_FROM:-0}" -gt 0 ] && [ "$n" -ge "${FAKE_SHOW_FAIL_FROM:-0}" ]; then echo "Error: connection lost" >&2; exit 1; fi
      jq -s '.' "$dir/$id.json"
    else echo "Error: no such bead" >&2; exit 1; fi
    ;;
  update)
    id="$1"; shift
    f="$dir/$id.json"; [ -f "$f" ] || exit 1
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata) k="${2%%=*}"; v="${2#*=}"; jq --arg k "$k" --arg v "$v" '.metadata[$k]=$v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "✓ Updated issue: $id"
    ;;
  label)
    if [ "${1:-}" = add ]; then
      id="$2"; l="$3"; f="$dir/$id.json"
      # FAKE_LABEL_FAIL=1: every `label add` fails without writing (a Dolt hiccup on the one call C8 targets).
      if [ "${FAKE_LABEL_FAIL:-0}" = "1" ]; then echo "Error: connection lost" >&2; exit 1; fi
      [ -f "$f" ] && jq --arg l "$l" '.labels=((.labels//[])+[$l]|unique)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      echo "✓ Added label '$l' to $id"
    fi
    ;;
  comment)
    printf 'COMMENT\t%s/%s\t%s\n' "$store" "$1" "${2:-}" >> "$W/comments.log"
    ;;
  create)
    title=""; itype="task"; prio="2"; meta="{}"; desc=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title=*) title="${1#--title=}"; shift ;;
        -t) itype="$2"; shift 2 ;;
        -p) prio="$2"; shift 2 ;;
        -l) shift 2 ;;
        --metadata) meta="$2"; shift 2 ;;
        -d) desc="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$dir"
    n=$(( $(ls "$dir" 2>/dev/null | wc -l) + 1 ))
    id="ps-c$n"
    jq -n --arg id "$id" --arg t "$title" --arg ty "$itype" --argjson p "${prio:-2}" --arg d "$desc" --argjson m "$meta" \
      '{id:$id,title:$t,issue_type:$ty,priority:$p,description:$d,status:"open",assignee:null,labels:["ctx:ready","exec:auto","story:approved"],metadata:$m}' > "$dir/$id.json"
    printf '{"id":"%s"}\n' "$id"
    ;;
  close)
    id="$1"; shift; reason=""
    while [ $# -gt 0 ]; do
      case "$1" in --reason) reason="$2"; shift 2 ;; *) shift ;; esac
    done
    f="$dir/$id.json"; [ -f "$f" ] || exit 1
    jq --arg r "$reason" '.status="closed" | .close_reason=$r' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "✓ Closed $id"
    ;;
  *) : ;;
esac
exit 0
BD
chmod +x "$WORK/bin/bd"

reset_world() { rm -rf "$WORK/stores"; mkdir -p "$WORK/stores"; : > "$WORK/bd.calls"; : > "$WORK/comments.log"; : > "$WORK/spawns.log"; : > "$WORK/warns.log"; rm -f "$WORK/gc_fail" "$WORK/show.n"; unset FAKE_SHOW_FAIL_FROM FAKE_LABEL_FAIL; write_rigs; }

# mkbead <store> <id> <routed_to> [labels-json] [metadata-extra-json]
mkbead() {
  local _store="$1" _id="$2" _pool="$3" _labels="${4:-[]}" _meta="${5:-{\}}"
  mkdir -p "$WORK/stores/$_store"
  jq -n --arg id "$_id" --arg pool "$_pool" --argjson labels "$_labels" --argjson meta "$_meta" \
    '{id:$id,title:("bead "+$id),status:"open",assignee:null,priority:2,issue_type:"bug",labels:$labels,
      metadata:({"gc.routed_to":$pool} + $meta)}' > "$WORK/stores/$_store/$_id.json"
}

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part A: _pilot_pool_store_blind_guard / _pilot_pool_rig (hole 1 — the dispatch decision) ==="

run_guard() { # run_guard <sling_target> <bead_city> -> prints the guard's exit status (0=REFUSE, 1=PROCEED, 127=missing)
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log()  { :; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    eval "$GUARD_PRELUDE"
    _rc=0
    _pilot_pool_store_blind_guard "$1" "$2" || _rc=$?
    echo "$_rc"
  ) 2>/dev/null
}
expect_guard() { # expect_guard <want-rc> <desc> <target> <bead_city>
  local _want="$1" _desc="$2" _got
  _got="$(run_guard "$3" "$4")"
  if [ "$_got" = "$_want" ]; then ok "$_desc"; else bad "$_desc — expected rc=$_want, got rc='${_got:-<none>}'"; fi
}

reset_world
# The exact lx-b5q shape: ps-worker target, bead in the lexbh store.
expect_guard 0 "ps-worker + bead in the LEXBH store -> REFUSE (the lx-b5q shape: the pool can never see it)" ps-worker "$WORK/rigs/lexbh"
expect_guard 1 "ps-worker + bead in its OWN store (property_scrapers) -> PROCEED"                              ps-worker "$WORK/rigs/property_scrapers"
expect_guard 1 "ps-worker + own store written with a trailing slash -> PROCEED (same directory)"               ps-worker "$WORK/rigs/property_scrapers/"
expect_guard 1 "ps-worker + a symlink to its own store -> PROCEED (same directory once resolved)"              ps-worker "$WORK/rigs/ps-link"
expect_guard 0 "ps-worker + bead in the whatsapp_automation store -> REFUSE"                                   ps-worker "$WORK/rigs/whatsapp_automation"
expect_guard 1 "wa-worker + bead in its OWN store (whatsapp_automation) -> PROCEED"                            wa-worker "$WORK/rigs/whatsapp_automation"
expect_guard 0 "wa-worker + bead in the lexbh store -> REFUSE"                                                 wa-worker "$WORK/rigs/lexbh"
expect_guard 0 "wa-worker + bead in the property_scrapers store -> REFUSE"                                     wa-worker "$WORK/rigs/property_scrapers"
expect_guard 1 "gastown.dog + lexbh store -> PROCEED (the dog has its OWN guard, ga-cszxcf; not this one's business)" gastown.dog "$WORK/rigs/lexbh"
expect_guard 1 "mila-wa (named crew) + lexbh store -> PROCEED (guard is scoped to the ephemeral rig pools)"     mila-wa "$WORK/rigs/lexbh"
expect_guard 1 "ps-worker + EMPTY bead store -> PROCEED (cannot tell is never a refusal)"                       ps-worker ""

# Three states, not two: "the rig list could not be read" must not read as "different store".
: > "$WORK/gc_fail"
expect_guard 1 "ps-worker + lexbh store but 'gc rig list' FAILS -> PROCEED (cannot tell -> keep the old behaviour, never a guess)" ps-worker "$WORK/rigs/lexbh"
rm -f "$WORK/gc_fail"
jq '.rigs |= map(select(.name != "property_scrapers"))' "$WORK/rigs.json" > "$WORK/rigs.json.new" && mv "$WORK/rigs.json.new" "$WORK/rigs.json"
expect_guard 1 "ps-worker + lexbh store but property_scrapers is not a registered rig -> PROCEED (pool's own store unknown)" ps-worker "$WORK/rigs/lexbh"
write_rigs

run_pool_rig() { # run_pool_rig <pool> -> the rig name (empty when unknown)
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }; warn() { :; }
    eval "$GUARD_PRELUDE"
    rig_root_path gascity >/dev/null 2>&1 || true   # warm the memo in THIS shell, as the real guard does
    _pilot_pool_rig "$1"
  ) 2>/dev/null
}
for pair in "ps-worker:property_scrapers" "wa-worker:whatsapp_automation" "wa-worker-3:whatsapp_automation" "gastown.dog:" "mila-wa:"; do
  _p="${pair%%:*}"; _want="${pair#*:}"; _got="$(run_pool_rig "$_p")"
  if [ "$_got" = "$_want" ]; then ok "_pilot_pool_rig $_p -> '${_want:-<none>}'"; else bad "_pilot_pool_rig $_p -> expected '${_want:-<none>}', got '${_got:-<none>}'"; fi
done

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part B: _topup_rig_pending only scans the store(s) the pool actually reads (hole 2) ==="

run_rig_pending() { # run_rig_pending <pool> -> the pending bead id the top-up scan would spawn for ("" = none)
  : > "$WORK/bd.calls"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }; warn() { :; }
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }   # eligibility is not under test
    eval "$TOPUP_VARS"
    eval "$TOPUP_PRELUDE"
    _TOPUP_RIG_PATHS_JSON="$(cat "$WORK/rigs.json")"
    _TOPUP_RIG_PATHS="${TEST_RIG_PATHS-$(printf '%s' "$_TOPUP_RIG_PATHS_JSON" | jq -r '.rigs[] | select(.hq == false) | .path')}"
    _topup_rig_pending "$1" || true
  ) 2>/dev/null
}
bd_scanned() { grep -c "^bd	-C $WORK/rigs/$1 " "$WORK/bd.calls" 2>/dev/null || true; }

reset_world
mkbead lexbh lx-b5q ps-worker
mkbead property_scrapers ps-h04q ps-worker
_got="$(run_rig_pending ps-worker)"
if [ "$_got" = "ps-h04q" ]; then
  ok "B1: ps-worker top-up picks ps-h04q (its OWN store), not lx-b5q from lexbh (rigs list order puts lexbh FIRST)"
else
  bad "B1: ps-worker top-up picked '${_got:-<none>}' — expected ps-h04q; a bead in the lexbh store keeps spawning workers that can never see it"
fi
if [ "$(bd_scanned lexbh)" = "0" ]; then ok "B1b: the lexbh store was never queried for a ps-worker pending bead"; else bad "B1b: the lexbh store WAS queried for ps-worker ($(bd_scanned lexbh) call(s)) — a foreign store must not be scanned"; fi

reset_world
mkbead lexbh lx-b5q ps-worker
_got="$(run_rig_pending ps-worker)"
if [ -z "$_got" ]; then
  ok "B2: the ONLY pool-routed bead sits in lexbh (the lx-b5q incident) -> nothing to spawn for, 0 spawns instead of one per 23 min"
else
  bad "B2: top-up found '$_got' for ps-worker in a store ps-worker cannot read — the 251-spawn loop"
fi

reset_world
mkbead whatsapp_automation wa-x1 wa-worker
mkbead property_scrapers ps-y1 wa-worker
mkbead lexbh lx-z1 wa-worker
_got="$(run_rig_pending wa-worker)"
if [ "$_got" = "wa-x1" ]; then ok "B3: wa-worker top-up picks wa-x1 from whatsapp_automation (its store) — still works"; else bad "B3: wa-worker top-up picked '${_got:-<none>}', expected wa-x1"; fi
if [ "$(bd_scanned property_scrapers)" = "0" ] && [ "$(bd_scanned lexbh)" = "0" ]; then ok "B3b: wa-worker never scans property_scrapers or lexbh"; else bad "B3b: wa-worker scanned a foreign store"; fi

# A directory that EXISTS on disk but is not a registered rig: nothing proves it is the pool's store.
mkdir -p "$WORK/rigs/unregistered"
reset_world
mkbead unregistered ps-ghost ps-worker
mkbead property_scrapers ps-h04q ps-worker
_got="$(TEST_RIG_PATHS="$WORK/rigs/unregistered
$WORK/rigs/property_scrapers" run_rig_pending ps-worker)"
[ "$_got" = "ps-h04q" ] && ok "B4: an existing directory that is not a registered rig is skipped, the pool's real store still scans" || bad "B4: expected ps-h04q, got '${_got:-<none>}'"
reset_world
mkbead unregistered ps-ghost ps-worker
_got="$(TEST_RIG_PATHS="$WORK/rigs/unregistered" run_rig_pending ps-worker)"
[ -z "$_got" ] && ok "B4b: an unregistered path is never scanned (cannot prove it is the pool's store -> inert)" || bad "B4b: scanned an unregistered path and got '$_got'"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part C: the respawn brake (hole 3) — _pilot_pool_topup, _topup_note_spawn, _topup_exclude_braked ==="

# run_sweeps <pool> <max> <n> — run n top-up sweeps against the fake world, as the launchd loop would. The
# spawn is a stub that records and succeeds; the bead is never claimed (the incident's shape: the worker
# starts, finds nothing, drains).
run_sweeps() {
  local _pool="$1" _max="$2" _n="$3"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""; DRY_RUN=0
    GC_VARIABLE_SESSION_MAX=100; PILOT_DOLT_SATURATED_AT_START=0
    log()  { :; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }
    _pilot_live_session_count() { _PLSC_N=0; return 0; }
    _pilot_variable_session_count() { _PLSC_N=0; return 0; }
    _pilot_topup_spawn() { printf 'SPAWN\t%s\t%s\n' "$1" "$2" >> "$WORK/spawns.log"; return 0; }
    eval "$TOPUP_VARS"
    eval "$LOOP_PRELUDE"
    _TOPUP_RIG_PATHS_JSON="$(cat "$WORK/rigs.json")"
    _TOPUP_RIG_PATHS="$(printf '%s' "$_TOPUP_RIG_PATHS_JSON" | jq -r '.rigs[] | select(.hq == false) | .path')"
    _i=0
    while [ "$_i" -lt "$_n" ]; do _pilot_topup_spawn_count_before=0; _pilot_pool_topup "$_pool" "$_max"; _i=$((_i + 1)); done
  ) >/dev/null 2>&1
}
spawn_count() { grep -c "^SPAWN	$1	${2:-}" "$WORK/spawns.log" 2>/dev/null || true; }
bead_field() { jq -r "$3" "$WORK/stores/$1/$2.json" 2>/dev/null; }

# C1 — the incident: ONE visible, routed, never-claimed bead, one sweep per 5 min for an hour.
reset_world
mkbead property_scrapers ps-stuck ps-worker
run_sweeps ps-worker 1 12
_spawns="$(spawn_count ps-worker ps-stuck)"
if [ "$_spawns" = "5" ]; then
  ok "C1: 12 sweeps over a bead nobody claims -> EXACTLY 5 spawns (the cap), then the brake holds (was 12, and 251 in 4 days)"
else
  bad "C1: 12 sweeps -> $_spawns spawns for the same unclaimed bead — expected exactly 5 (the brake is missing or off by one)"
fi
if bead_field property_scrapers ps-stuck '(.labels // []) | index("pilot:topup-braked") != null' | grep -qx true; then
  ok "C1b: the braked bead carries the label pilot:topup-braked (durable, visible, the single source of truth)"
else
  bad "C1b: no pilot:topup-braked label on the bead after the cap — the brake is invisible and not durable"
fi
_cm="$(grep -c "^COMMENT	property_scrapers/ps-stuck	" "$WORK/comments.log" 2>/dev/null || true)"
if [ "$_cm" = "1" ]; then ok "C1c: exactly ONE explanatory comment was left on the bead (not one per sweep)"; else bad "C1c: $_cm brake comments on the bead — expected exactly 1"; fi
if grep -q 'remove' "$WORK/comments.log" 2>/dev/null && grep -q 'pilot:topup-braked' "$WORK/comments.log" 2>/dev/null; then
  ok "C1d: the comment says how to release it (remove the label)"
else
  bad "C1d: the brake comment does not tell the reader how to release the bead"
fi

# C2 — head-of-line: a braked bead must not starve the eligible bead queued behind it.
reset_world
mkbead property_scrapers a-stuck ps-worker '["pilot:topup-braked"]'
mkbead property_scrapers b-good  ps-worker
run_sweeps ps-worker 1 1
if [ "$(spawn_count ps-worker b-good)" = "1" ] && [ "$(spawn_count ps-worker a-stuck)" = "0" ]; then
  ok "C2: a braked bead is skipped and the eligible one behind it is served (no head-of-line blocking)"
else
  bad "C2: spawns -> a-stuck=$(spawn_count ps-worker a-stuck) b-good=$(spawn_count ps-worker b-good) — expected the braked bead skipped, b-good served once"
fi

# C3 — a stale streak is not "consecutive": spawns hours apart restart the count.
reset_world
_old=$(( $(date +%s) - 25200 ))   # 7h ago > the 6h reset window
mkbead property_scrapers ps-old ps-worker '[]' "{\"pilot.topup_spawn_count\":\"4\",\"pilot.topup_last_spawn_at\":\"$_old\"}"
run_sweeps ps-worker 1 1
_cnt="$(bead_field property_scrapers ps-old '.metadata["pilot.topup_spawn_count"]')"
if [ "$_cnt" = "1" ] && [ "$(spawn_count ps-worker ps-old)" = "1" ] \
   && ! bead_field property_scrapers ps-old '(.labels // []) | index("pilot:topup-braked") != null' | grep -qx true; then
  ok "C3: 4 spawns but the last was 7h ago -> the streak restarts at 1, no brake (a slow legitimate bead is not punished)"
else
  bad "C3: stale streak -> count='$_cnt' spawns=$(spawn_count ps-worker ps-old) — expected the streak restarted at 1 with no brake"
fi

# C4 — the 5th consecutive recent spawn brakes it.
reset_world
_recent=$(( $(date +%s) - 600 ))
mkbead property_scrapers ps-4th ps-worker '[]' "{\"pilot.topup_spawn_count\":\"4\",\"pilot.topup_last_spawn_at\":\"$_recent\"}"
run_sweeps ps-worker 1 1
_cnt="$(bead_field property_scrapers ps-4th '.metadata["pilot.topup_spawn_count"]')"
if [ "$_cnt" = "5" ] && bead_field property_scrapers ps-4th '(.labels // []) | index("pilot:topup-braked") != null' | grep -qx true; then
  ok "C4: the 5th consecutive spawn inside the window sets count=5 and brakes the bead"
else
  bad "C4: 4 recent spawns + 1 -> count='$_cnt' — expected 5 with pilot:topup-braked"
fi

# C5 — control: a bead the worker DOES claim never accumulates anything (it leaves the unassigned set).
reset_world
mkbead property_scrapers ps-claimed ps-worker
jq '.assignee="ps-worker-adhoc-1" | .status="in_progress"' "$WORK/stores/property_scrapers/ps-claimed.json" > "$WORK/x.json" && mv "$WORK/x.json" "$WORK/stores/property_scrapers/ps-claimed.json"
run_sweeps ps-worker 1 6
if [ "$(spawn_count ps-worker)" = "0" ]; then ok "C5: an already-claimed bead causes no spawns at all (control: the brake changes nothing for healthy beads)"; else bad "C5: spawned for a claimed bead"; fi

# C6 — the brake is per bead: a different pending bead starts with its own count.
reset_world
mkbead property_scrapers a-first ps-worker
run_sweeps ps-worker 1 6   # a-first gets 5 spawns and is braked
mkbead property_scrapers b-second ps-worker
run_sweeps ps-worker 1 2
if [ "$(spawn_count ps-worker b-second)" = "2" ] && [ "$(spawn_count ps-worker a-first)" = "5" ]; then
  ok "C6: the brake is per bead — a-first stopped at 5, the new b-second is served normally"
else
  bad "C6: a-first=$(spawn_count ps-worker a-first) b-second=$(spawn_count ps-worker b-second) — expected 5 and 2"
fi

# C7 — three states for the count: a bead whose count cannot be READ is not "count 0". Writing count=1 over a real 4
# would silently reset the brake exactly when Dolt is struggling. The 1st successful show is the store lookup, the
# 2nd is the count read — fail from the 2nd on.
reset_world
_recent=$(( $(date +%s) - 600 ))
mkbead property_scrapers ps-unread ps-worker '[]' "{\"pilot.topup_spawn_count\":\"4\",\"pilot.topup_last_spawn_at\":\"$_recent\"}"
export FAKE_SHOW_FAIL_FROM=2
run_sweeps ps-worker 1 1
unset FAKE_SHOW_FAIL_FROM
_cnt="$(bead_field property_scrapers ps-unread '.metadata["pilot.topup_spawn_count"]')"
if [ "$_cnt" = "4" ] && ! bead_field property_scrapers ps-unread '(.labels // []) | index("pilot:topup-braked") != null' | grep -qx true \
   && grep -q 'could not be READ' "$WORK/warns.log"; then
  ok "C7: an UNREADABLE count is not 'zero': nothing was written (count still 4), no brake set, and the skipped bookkeeping is announced"
else
  bad "C7: unreadable count -> count='$_cnt' (expected 4 untouched), warns: $(tr '\n' '|' < "$WORK/warns.log" | cut -c1-200)"
fi

# C8 — the comment must not promise more than the code did: when the brake LABEL could not be written, the bead is
# NOT braked, so a comment saying "stopping top-up for this bead (label pilot:topup-braked)" would be false on the
# bead itself — the next reader would stop looking for why it keeps spawning. The failure is warned, and the next
# sweep (which counts again and retries) is the one that labels AND comments, exactly once.
reset_world
_recent=$(( $(date +%s) - 600 ))
mkbead property_scrapers ps-nolabel ps-worker '[]' "{\"pilot.topup_spawn_count\":\"4\",\"pilot.topup_last_spawn_at\":\"$_recent\"}"
export FAKE_LABEL_FAIL=1
run_sweeps ps-worker 1 1
unset FAKE_LABEL_FAIL
_cm="$(grep -c "^COMMENT	property_scrapers/ps-nolabel	" "$WORK/comments.log" 2>/dev/null || true)"
if [ "$_cm" = "0" ] && grep -q 'FAILED to label' "$WORK/warns.log" \
   && ! bead_field property_scrapers ps-nolabel '(.labels // []) | index("pilot:topup-braked") != null' | grep -qx true; then
  ok "C8: the brake label could not be written -> NO 'braked' comment on the bead (it is not braked), and the failure is warned"
else
  bad "C8: label write failed -> $_cm brake comment(s) on a bead that is not braked (expected 0), warns: $(tr '\n' '|' < "$WORK/warns.log" | cut -c1-200)"
fi
run_sweeps ps-worker 1 1
_cm="$(grep -c "^COMMENT	property_scrapers/ps-nolabel	" "$WORK/comments.log" 2>/dev/null || true)"
if [ "$_cm" = "1" ] && bead_field property_scrapers ps-nolabel '(.labels // []) | index("pilot:topup-braked") != null' | grep -qx true; then
  ok "C8b: the next sweep retries — the label lands and the ONE comment is posted then, not before"
else
  bad "C8b: after the retry sweep -> $_cm comment(s), label present=$(bead_field property_scrapers ps-nolabel '(.labels // []) | index("pilot:topup-braked") != null') — expected 1 comment and the label"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part E: the migration lands the bead in the POOL's store (forced destination, never HQ) ==="

STORY_LX='{"id":"lx-b5q","title":"Dashboard de scrapers: Blow volta a parado","issue_type":"bug","priority":2,"description":"fixture body, quota de terreno","labels":["lane:small","story:approved"],"metadata":{}}'
run_migrate() { # run_migrate <dest_rig_or_empty> -> prints "<rc>|<stdout>"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    eval "$MIGRATE_PRELUDE"
    _rc=0; _out=""
    _out=$(_pilot_dog_store_try_migrate lx-b5q "$STORY_LX" "$WORK/rigs/lexbh" lexbh "lane:small" "$1" 2>/dev/null) || _rc=$?
    echo "$_rc|$_out"
  ) 2>/dev/null
}

reset_world
mkbead lexbh lx-b5q gastown.dog '["lane:small"]'
_res="$(run_migrate property_scrapers)"
if [ "${_res%%|*}" = "0" ] && [ "${_res#*|}" = "ps-c1" ] && [ -f "$WORK/stores/property_scrapers/ps-c1.json" ]; then
  ok "E1: with a forced destination the copy is created in the POOL's store (property_scrapers), id handed back"
else
  bad "E1: expected rc=0 and a copy ps-c1 in the property_scrapers store, got '$_res' (stores: $(ls "$WORK/stores" | tr '\n' ' '))"
fi
if [ "$(jq -r '.metadata["gc.migrated_from"] + "|" + .metadata["gc.migrated_from_rig"]' "$WORK/stores/property_scrapers/ps-c1.json" 2>/dev/null)" = "lx-b5q|lexbh" ]; then
  ok "E1b: the copy records where it came from (gc.migrated_from=lx-b5q, gc.migrated_from_rig=lexbh)"
else
  bad "E1b: the copy's provenance metadata is wrong or missing"
fi
_close_reason="$(jq -r '.close_reason // ""' "$WORK/stores/lexbh/lx-b5q.json" 2>/dev/null)"
case "$_close_reason" in
  "Movida para ps-c1 (property_scrapers, "*"ga-653ilw"*) ok "E1c: the original is closed pointing at the copy, and the reason names this fix (not the dog guard's)" ;;
  *) bad "E1c: unexpected close reason on the original: '$_close_reason'" ;;
esac
if ! ls "$WORK/stores/city" >/dev/null 2>&1; then ok "E1d: nothing was written to the HQ store"; else bad "E1d: something landed in the HQ store"; fi

reset_world
mkbead lexbh lx-b5q gastown.dog '["lane:small"]'
_res="$(run_migrate no_such_rig)"
if [ "${_res%%|*}" = "1" ] && [ -z "${_res#*|}" ] && ! grep -q 'create' "$WORK/bd.calls" \
   && [ "$(jq -r .status "$WORK/stores/lexbh/lx-b5q.json")" = "open" ]; then
  ok "E2: a forced destination that cannot be resolved ABORTS — no create, original untouched, never a silent fall-back to HQ (the pool cannot read HQ either)"
else
  bad "E2: unresolvable forced destination -> '$_res', creates=$(grep -c 'create' "$WORK/bd.calls" 2>/dev/null || true) — expected rc=1, no create, original open"
fi

reset_world
mkbead lexbh lx-b5q gastown.dog '["lane:small"]'
_res="$(run_migrate lexbh)"
if [ "${_res%%|*}" = "1" ] && ! grep -q 'create' "$WORK/bd.calls"; then
  ok "E3: a forced destination equal to the SOURCE store refuses to self-migrate (no create)"
else
  bad "E3: forced destination == source -> '$_res' — expected a refusal without a create"
fi

reset_world
mkbead lexbh lx-b5q gastown.dog '["lane:small"]'
_res="$(run_migrate "")"
if [ "${_res%%|*}" = "0" ] && [ -f "$WORK/stores/city/ps-c1.json" ]; then
  ok "E4 (control): WITHOUT a forced destination the old behaviour is unchanged — picked from the text, HQ default"
else
  bad "E4 (control): the no-override path changed — '$_res'"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part D: wiring (drift-guards on the live dispatcher) ==="
has() { local pat="$1" desc="$2"; if grep -Eq -- "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }

has 'PILOT_POOL_STORE_GUARD:-1'                                             "call site respects the PILOT_POOL_STORE_GUARD kill switch (default on)"
has 'PILOT_POOL_STORE_AUTOMIGRATE:-1'                                       "call site respects the PILOT_POOL_STORE_AUTOMIGRATE kill switch (default on)"
has '_pilot_pool_store_blind_guard "\$_SLING_TARGET" "\$STORY_BEAD_CITY"'   "call site invokes the guard with _SLING_TARGET / STORY_BEAD_CITY"
has 'DISPATCH_RESULT="rig_native_pool_store_migrated"'                      "a successful migration has its own DISPATCH_RESULT"
has 'DISPATCH_RESULT="rig_native_pool_store_blind"'                         "a refusal that could not migrate has its own DISPATCH_RESULT"
has '"rig_native_pool_store_blind", "rig_native_pool_store_migrated"|"rig_native_pool_store_migrated", "rig_native_pool_store_blind"' \
                                                                            "both outcomes are classified as guard outcomes in _pilot_sweep_emit (not Pilot faults)"
if awk '/_pilot_pool_store_blind_guard "\$_SLING_TARGET"/{g=NR} /log "DRY_RUN=1 — WOULD DISPATCH/{d=NR} END{exit !(g && d && g<d)}' "$DISPATCHER"; then
  ok "the guard runs BEFORE the DRY_RUN branch (a dry run reports the refusal instead of 'WOULD spawn a worker that can never see the bead')"
else
  bad "the guard call does not precede the DRY_RUN branch"
fi
if awk '/_pilot_pool_store_blind_guard "\$_SLING_TARGET"/{g=NR} /ga-sndpm: re-verify ownership guard before routing to the pool/{o=NR} END{exit !(g && o && g<o)}' "$DISPATCHER"; then
  ok "the guard runs BEFORE the pool arm stamps gc.routed_to / leaves the bead for the pool to find"
else
  bad "the guard call does not precede the pool arm"
fi
has 'done <<< "\$_TOPUP_RIG_PATHS"'                                         "_topup_rig_pending still consumes the pre-computed rig-path list"
if awk '/^_topup_rig_pending\(\)/{f=1} f&&/_topup_rig_serves_pool "\$_rp" "\$_pool"/{s=1} f&&/^}$/{exit} END{exit !s}' "$DISPATCHER"; then
  ok "_topup_rig_pending asks _topup_rig_serves_pool before scanning a rig store"
else
  bad "_topup_rig_pending does not gate each store on _topup_rig_serves_pool"
fi
_n_excl="$(awk '/^_pilot_pool_topup\(\)/{f=1} f&&/_topup_exclude_braked/{c++} f&&/^}$/{exit} END{print c+0}' "$DISPATCHER")"
_n_excl_rig="$(awk '/^_topup_rig_pending\(\)/{f=1} f&&/_topup_exclude_braked/{c++} f&&/^}$/{exit} END{print c+0}' "$DISPATCHER")"
if [ "$_n_excl" -ge 3 ] && [ "$_n_excl_rig" -ge 1 ]; then
  ok "_topup_exclude_braked is chained into every pending pipeline (HQ query + both test seams in _pilot_pool_topup: $_n_excl, rig query: $_n_excl_rig)"
else
  bad "_topup_exclude_braked is missing from a pending pipeline (_pilot_pool_topup: $_n_excl of >=3, _topup_rig_pending: $_n_excl_rig of >=1)"
fi
if awk '/^_pilot_pool_topup\(\)/{f=1} f&&/if _pilot_topup_spawn "\$_pool" "\$_pending"; then/{s=NR} f&&/_topup_note_spawn "\$_pool" "\$_pending"/{n=NR} f&&/^}$/{exit} END{exit !(s && n && n>s)}' "$DISPATCHER"; then
  ok "a successful top-up spawn is recorded via _topup_note_spawn (after the spawn, so a failed spawn never burns the budget)"
else
  bad "_topup_note_spawn is not called after a successful top-up spawn"
fi

echo ""
echo "pilot-dispatcher.pool-store-blind.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
