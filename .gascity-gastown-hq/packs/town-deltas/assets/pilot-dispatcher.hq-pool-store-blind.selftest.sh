#!/usr/bin/env bash
# pilot-dispatcher.hq-pool-store-blind.selftest.sh — ga-vp2zr0.
#
# Bug ga-vp2zr0 (measured 2026-10-07): HQ P0 beads ga-9t9acg.11 / .12, gc.routed_to=wa-worker, sat in "Aprovadas"
# while P1 beads of the WA store were being built. wa-worker and ps-worker each read ONE store — their own rig
# clone — so an HQ bead routed to them is invisible to every worker of the pool. Three holes of the Pilot let it
# strand quietly instead of being noticed:
#
#   1. PRE-CLAIM CAP SKIP (_pilot_pool_cap_full_for). It queued every wa-worker-routed bead behind the pool cap, the
#      HQ P0 included — a bead no freed slot can ever serve, "queued" for ever behind P1s that can be served.
#   2. HQ TOP-UP (_pilot_pool_topup). It asked HQ for beads routed to the pool and counted them as demand: it opened
#      wa-worker sessions "for" the P0 — ~188k WTE each, finding nothing — and the rig sweep (which already asked
#      "does this pool read this store?", _topup_rig_serves_pool) was the only place with that filter.
#   3. STORE-BLIND GUARD (dispatch_one). ga-653ilw's guard ran only for rig-native beads and treated "cannot tell" as
#      "proceed". An HQ bead was never asked, and a bead whose store could not be identified went through.
#
# The fix, and what each Part below pins:
#   A  _pilot_bead_home_store      where a bead LIVES: the id's prefix in $GC_CITY/.beads/routes.jsonl (ga -> HQ ...)
#   B  _pilot_pool_store_verdict   serves | blind | unknown — three states; "cannot tell" is never "serves"
#   C  _topup_hq_serves_pool       the HQ top-up's "does the pool read this store?" filter (same question as the rig sweep)
#   D  ACCEPTANCE (d): an HQ P0 routed=wa-worker plus a P1 in the WA store -> the top-up does NOT open a wa-worker
#      session for the P0 (it serves the P1, which the pool can see)
#   E  _pilot_heal_hq_blind_routes an HQ bead never KEEPS a blind route: it is re-routed to gastown.dog (which reads HQ)
#   F  _pilot_pool_cap_full_for    the pre-claim does not queue a bead the pool cannot see (or whose store is unknown)
#   G  the store-blind guard call site in dispatch_one, outside _IS_RIG_NATIVE: HQ-blind -> refuse + hold/escalate;
#      unknown -> release + alert, never dispatch
#   H  wiring (drift guards) and mutation controls: the rule reverted in a COPY of the dispatcher fails the part
#      that guards it
#
# Falsifiable: run it against the pre-fix dispatcher
#   PILOT_DISPATCHER_PATH=<pre-fix pilot-dispatcher.sh> bash <this file>
# and every Part fails on an assertion (the functions are missing, the top-up spawns for the HQ P0).
#
# Conventions: verbatim function extraction (awk) from the live dispatcher + PATH-stubbed gc/bd inside the sandbox
# PATH (selftest-sandbox-path.lib.sh: the REAL gc/bd cannot resolve). bash 3.2-safe.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.hq-pool-store-blind.selftest.sh
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { # eq <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', expected '$3'"; fi
}

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-hq-pool-store-blind-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/bin" "$WORK/city/.beads" "$WORK/rigs/lexbh" "$WORK/rigs/property_scrapers" \
         "$WORK/rigs/whatsapp_automation" "$WORK/rigs/gastown" "$WORK/rigs/marketing" "$WORK/stores" "$WORK/mut"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK" timeout jq || exit 2
export FAKE_WORK="$WORK"

# The respawn brake counts a top-up spawn only while the pool worker's template carries the migrated Step 1b2 probe
# (_topup_worker_probe_migrated). This selftest is about the store gate, not the brake: its sandbox city declares workers
# that are on the shared order, so a spawn is just a spawn.
for _p in wa-worker ps-worker; do
  mkdir -p "$WORK/city/agents/$_p"
  cat > "$WORK/city/agents/$_p/prompt.template.md" <<'TPL'
  X_SORTED="$( . "$X_LIB" && printf '%s' "$X_CAND" | work_order_sort --age reclaim )" && [ -n "$X_SORTED" ]
TPL
done

# The authoritative prefix -> store map, in the shape of the real $GC_CITY/.beads/routes.jsonl ("." is HQ itself, the
# rest relative to $GC_CITY — the rigs are its siblings in production, `../property_scrapers`).
write_routes() {
  cat > "$WORK/city/.beads/routes.jsonl" <<EOF
{"prefix":"ga","path":"."}
{"prefix":"ps","path":"../rigs/property_scrapers"}
{"prefix":"ma","path":"../rigs/marketing"}
{"prefix":"lx","path":"../rigs/lexbh"}
{"prefix":"gt","path":"../rigs/gastown"}
{"prefix":"wa","path":"../rigs/whatsapp_automation"}
EOF
}
write_routes

# ── extraction ──────────────────────────────────────────────────────────────
DISP="$DISPATCHER"
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISP"; }
MISSING=""
need() { # need <fn>... — echoes the extracted sources; records (does not abort on) a missing function
  local _f _s
  for _f in "$@"; do
    _s="$(fn_src "$_f")"
    if [ -z "$_s" ]; then MISSING="$MISSING $_f"; else printf '%s\n' "$_s"; fi
  done
}
[ -r "$SELF_DIR/scripts/work-order.sh" ] || { echo "FATAL: $SELF_DIR/scripts/work-order.sh missing" >&2; exit 2; }

build_preludes() { # re-extract from $DISP (the mutation controls point $DISP at a mutated copy)
  MISSING=""
  # What every verdict needs, defined together so a sandbox can never silently lack one.
  COMMON_PRELUDE="$(need gc_json_or_unknown rig_root_path rig_to_builders wa_worker_template _pilot_rig_builds_pool \
                         _pilot_pool_rig _pilot_same_dir _pilot_bead_home_store _pilot_pool_store_verdict \
                         _pilot_psv_warn_once _pilot_pool_store_blind_guard _topup_hq_serves_pool)
_PSV_WARNED=\"\"; _PSV_VERDICT=\"\"; _PSV_POOL_RIG=\"\""
  LOOP_PRELUDE=". \"$SELF_DIR/scripts/work-order.sh\"
$COMMON_PRELUDE
$(need _topup_rig_serves_pool _topup_rig_pending _topup_exclude_braked _topup_validate_input _topup_pick_first \
       _topup_pending_store _topup_note_spawn _topup_worker_probe_migrated _pilot_pool_topup)"
  HEAL_PRELUDE="$COMMON_PRELUDE
$(need _pilot_heal_hq_blind_routes)"
  CAP_PRELUDE="$COMMON_PRELUDE
$(need _pilot_pool_live_count _pilot_pool_cap_full_for)"
  TOPUP_VARS="$(awk '/^_TOPUP_WORKER_EXCLUDE_LABELS=\(/{f=1} f{print} f&&/^\)$/{exit}' "$DISP")
$(grep -m1 '^_TOPUP_EPIC_TITLE_RE=' "$DISP")"
  # The guard call site is INLINE in dispatch_one(): extract it as a block (from `local _PSB_RC=1` to the migrate arm).
  GUARD_BLOCK="$(awk '/^  local _PSB_RC=1$/{f=1} f&&/^  if \[ "\$_IS_RIG_NATIVE" = "1" \] && \[ "\$_PSB_RC" = "0" \]; then$/{exit} f{print}' "$DISP")"
}
build_preludes

echo "pilot-dispatcher.hq-pool-store-blind.selftest — ga-vp2zr0"
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

# A stateful fake bd. One bead per file: $FAKE_WORK/stores/<basename of the -C dir>/<id>.json (HQ = "city"). The verbs
# the code under test uses: ready / show / update (--set-metadata, --unset-metadata) / label add|remove / comment.
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
    [ -f "$W/bd_ready_fail" ] && { echo "Error: connection lost" >&2; exit 1; }
    if [ -f "$W/bd_ready_raw" ]; then cat "$W/bd_ready_raw"; exit 0; fi
    want=""; extype=""; exl=""; prev=""
    for a in "$@"; do
      case "$prev" in
        --metadata-field) want="${a#gc.routed_to=}" ;;
        --exclude-type)   extype="$a" ;;
        --exclude-label)  exl="$exl
$a" ;;
      esac
      prev="$a"
    done
    out="[]"
    if [ -d "$dir" ] && ls "$dir"/*.json >/dev/null 2>&1; then
      exjson="$(printf '%s\n' "$exl" | jq -R . | jq -sc '.')"
      out=$(cat "$dir"/*.json | jq -s --arg w "$want" --arg et "$extype" --argjson ex "$exjson" '
        [.[] | select(.status == "open") | select((.assignee // "") == "")
             | select((.metadata["gc.routed_to"] // "") == $w)
             | select(($et == "") or ((.issue_type // "") != $et))
             | select(((.labels // []) | map(select(. as $l | $ex | index($l))) | length) == 0)]')
    fi
    printf '%s\n' "${out:-[]}"
    ;;
  show)
    id="$1"
    if [ -f "$dir/$id.json" ]; then jq -s '.' "$dir/$id.json"; else echo "Error: no such bead" >&2; exit 1; fi
    ;;
  update)
    id="$1"; shift
    f="$dir/$id.json"; [ -f "$f" ] || exit 1
    [ -f "$W/bd_update_fail" ] && { echo "Error: connection lost" >&2; exit 1; }
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata)   k="${2%%=*}"; v="${2#*=}"; jq --arg k "$k" --arg v "$v" '.metadata[$k]=$v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; shift 2 ;;
        --unset-metadata) jq --arg k "$2" 'del(.metadata[$k])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "✓ Updated issue: $id"
    ;;
  label)
    op="${1:-}"; id="${2:-}"; l="${3:-}"; f="$dir/$id.json"
    if [ "$op" = add ]; then
      [ -f "$f" ] && jq --arg l "$l" '.labels=((.labels//[])+[$l]|unique)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    elif [ "$op" = remove ]; then
      [ -f "$f" ] && jq --arg l "$l" '.labels=((.labels//[])-[$l])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    ;;
  comment)
    printf 'COMMENT\t%s/%s\t%s\n' "$store" "$1" "${2:-}" >> "$W/comments.log"
    ;;
  *) : ;;
esac
exit 0
BD
chmod +x "$WORK/bin/bd"

reset_world() {
  rm -rf "$WORK/stores"; mkdir -p "$WORK/stores"
  : > "$WORK/bd.calls"; : > "$WORK/comments.log"; : > "$WORK/spawns.log"; : > "$WORK/warns.log"; : > "$WORK/logs.log"; : > "$WORK/holds.log"
  rm -f "$WORK/gc_fail" "$WORK/bd_ready_fail" "$WORK/bd_ready_raw" "$WORK/bd_update_fail"
  write_rigs; write_routes
}

# mkbead <store> <id> <routed_to> [priority] [labels-json] [type] [assignee]
mkbead() {
  local _store="$1" _id="$2" _pool="$3" _prio="${4:-2}" _labels="${5:-[]}" _type="${6:-bug}" _asg="${7:-}"
  mkdir -p "$WORK/stores/$_store"
  jq -n --arg id "$_id" --arg pool "$_pool" --argjson prio "$_prio" --argjson labels "$_labels" --arg type "$_type" --arg asg "$_asg" \
    '{id:$id,title:("bead "+$id),status:"open",assignee:(if $asg == "" then null else $asg end),priority:$prio,issue_type:$type,
      labels:$labels,metadata:{"gc.routed_to":$pool}}' > "$WORK/stores/$_store/$_id.json"
}
route_of() { jq -r '.metadata["gc.routed_to"] // ""' "$WORK/stores/$1/$2.json" 2>/dev/null; }
has_label() { jq -e --arg l "$3" '(.labels // []) | index($l) != null' "$WORK/stores/$1/$2.json" >/dev/null 2>&1; }
spawn_count() { grep -c "^SPAWN	$1	${2:-}" "$WORK/spawns.log" 2>/dev/null || true; }
phys() { (cd -P "$1" 2>/dev/null && pwd -P); }
hq_ready_calls() { grep -c "^bd	-C $WORK/city ready" "$WORK/bd.calls" 2>/dev/null || true; }

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part A: _pilot_bead_home_store — where a bead LIVES (routes.jsonl, by id prefix) ==="

run_home() { # run_home <bead_id> -> the store directory ("" = unknown)
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }; warn() { :; }
    eval "$COMMON_PRELUDE"
    _pilot_bead_home_store "$1"
  ) 2>/dev/null
}
reset_world
eq "A1 an ga- id lives in HQ (routes.jsonl: ga -> .)"                       "$(run_home ga-9t9acg.11)"  "$(phys "$WORK/city")"
eq "A2 a wa- id lives in the whatsapp_automation store (relative path)"    "$(run_home wa-u4k)"        "$(phys "$WORK/rigs/whatsapp_automation")"
eq "A3 a ps- id lives in the property_scrapers store"                      "$(run_home ps-h04q)"       "$(phys "$WORK/rigs/property_scrapers")"
eq "A4 an lx- id lives in the lexbh store"                                 "$(run_home lx-b5q)"        "$(phys "$WORK/rigs/lexbh")"
eq "A5 a prefix routes.jsonl does not list -> unknown (empty), never HQ"   "$(run_home zz-1)"          ""
eq "A6 an id with no prefix at all -> unknown"                             "$(run_home nodash)"        ""
eq "A7 an empty id -> unknown"                                             "$(run_home "")"            ""
eq "A8 a dotted child id (ga-9t9acg.11) reads the prefix before the first dash" "$(run_home ga-x.1.2)"  "$(phys "$WORK/city")"

printf '{"prefix":"zz","path":"%s"}\n' "$WORK/rigs/marketing" >> "$WORK/city/.beads/routes.jsonl"
eq "A9 an ABSOLUTE path in routes.jsonl is used as is"                     "$(run_home zz-1)"          "$(phys "$WORK/rigs/marketing")"
printf '{"prefix":"qq","path":"../rigs/does-not-exist"}\n' >> "$WORK/city/.beads/routes.jsonl"
eq "A10 an entry whose directory does not exist -> unknown (not a guessed path)" "$(run_home qq-1)"    ""
printf 'this is not json\n' > "$WORK/city/.beads/routes.jsonl"
eq "A11 a routes.jsonl jq cannot parse -> unknown (illegible is not 'HQ')" "$(run_home ga-1)"          ""
rm -f "$WORK/city/.beads/routes.jsonl"
eq "A12 no routes.jsonl at all -> unknown"                                 "$(run_home ga-1)"          ""
write_routes

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part B: _pilot_pool_store_verdict — serves | blind | unknown ==="

run_verdict() { # run_verdict <pool> <store_dir> -> "<verdict>|<pool rig>"
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    eval "$COMMON_PRELUDE"
    _pilot_pool_store_verdict "$1" "$2"
    echo "$_PSV_VERDICT|$_PSV_POOL_RIG"
  ) 2>/dev/null
}
reset_world
eq "B1 wa-worker + the HQ store -> blind (the ga-9t9acg.11 shape), pool rig named"  "$(run_verdict wa-worker "$WORK/city")"                    "blind|whatsapp_automation"
eq "B2 ps-worker + the HQ store -> blind"                                          "$(run_verdict ps-worker "$WORK/city")"                    "blind|property_scrapers"
eq "B3 wa-worker + its OWN store -> serves"                                        "$(run_verdict wa-worker "$WORK/rigs/whatsapp_automation")" "serves|whatsapp_automation"
eq "B4 ps-worker + the lexbh store -> blind"                                       "$(run_verdict ps-worker "$WORK/rigs/lexbh")"              "blind|property_scrapers"
eq "B5 gastown.dog is not a rig pool: the predicate does not apply -> serves"      "$(run_verdict gastown.dog "$WORK/rigs/lexbh")"            "serves|"
eq "B6 an EMPTY store -> unknown (no store is not a store the pool reads)"         "$(run_verdict wa-worker "")"                              "unknown|"
eq "B6b a store path that is not a directory -> unknown, NOT blind (nothing was compared; 'could not read' is not 'a different store')" "$(run_verdict wa-worker "$WORK/city/does-not-exist")" "unknown|"
if [ "$(id -u)" != "0" ]; then # root can enter any directory, so there is no "exists but cannot be entered" to build
  mkdir -p "$WORK/noenter" && chmod 000 "$WORK/noenter"
  eq "B6c a store directory that exists but cannot be entered -> unknown, NOT blind (cd fails, same as a missing one)" "$(run_verdict wa-worker "$WORK/noenter")" "unknown|"
  chmod 755 "$WORK/noenter"
fi
: > "$WORK/gc_fail"
eq "B7 'gc rig list' FAILS -> unknown, never serves" "$(run_verdict wa-worker "$WORK/city")" "unknown|"
rm -f "$WORK/gc_fail"
jq '.rigs |= map(select(.name != "whatsapp_automation"))' "$WORK/rigs.json" > "$WORK/rigs.json.new" && mv "$WORK/rigs.json.new" "$WORK/rigs.json"
eq "B8 the pool's rig is not registered -> unknown"                                "$(run_verdict wa-worker "$WORK/city")"                    "unknown|"
write_rigs
jq --arg p "$WORK/rigs/gone" '(.rigs[] | select(.name == "whatsapp_automation") | .path) = $p' "$WORK/rigs.json" > "$WORK/rigs.json.new" && mv "$WORK/rigs.json.new" "$WORK/rigs.json"
eq "B9 the pool's rig path is not a directory on disk -> unknown"                  "$(run_verdict wa-worker "$WORK/city")"                    "unknown|whatsapp_automation"
write_rigs

# unknown warns ONCE per pool per sweep (the cause is the same for every candidate), not once per bead.
: > "$WORK/warns.log"; : > "$WORK/gc_fail"
(
  set -euo pipefail
  PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
  log() { :; }; warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
  eval "$COMMON_PRELUDE"
  _pilot_pool_store_verdict wa-worker "$WORK/city"; _pilot_pool_store_verdict wa-worker "$WORK/rigs/lexbh"; _pilot_pool_store_verdict wa-worker "$WORK/city"
  _pilot_pool_store_verdict ps-worker "$WORK/city"
) >/dev/null 2>&1
rm -f "$WORK/gc_fail"
eq "B10 three unknown verdicts for wa-worker + one for ps-worker -> exactly 2 warns (once per pool)" "$(grep -c '^warn' "$WORK/warns.log" 2>/dev/null || true)" "2"

# the guard wrapper: 0 REFUSE / 1 PROCEED / 2 UNKNOWN
run_guard() { # run_guard <target> <bead_city> -> the guard's exit status
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }; warn() { :; }
    eval "$COMMON_PRELUDE"
    _rc=0; _pilot_pool_store_blind_guard "$1" "$2" || _rc=$?
    echo "$_rc"
  ) 2>/dev/null
}
reset_world
eq "B11 guard: wa-worker + an HQ bead -> 0 (REFUSE)"                "$(run_guard wa-worker "$WORK/city")"                    "0"
eq "B12 guard: wa-worker + a bead of its own store -> 1 (PROCEED)"  "$(run_guard wa-worker "$WORK/rigs/whatsapp_automation")" "1"
eq "B13 guard: wa-worker + no store -> 2 (UNKNOWN, not PROCEED)"    "$(run_guard wa-worker "")"                              "2"
eq "B14 guard: gastown.dog -> 1 (not this guard's business)"        "$(run_guard gastown.dog "$WORK/city")"                  "1"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part C: _topup_hq_serves_pool — the HQ top-up asks the rig sweep's question ==="

run_hq_serves() { # run_hq_serves <pool> -> 0 (the pool reads HQ) / 1
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }; warn() { :; }
    eval "$COMMON_PRELUDE"
    _rc=0; _topup_hq_serves_pool "$1" || _rc=$?
    echo "$_rc"
  ) 2>/dev/null
}
reset_world
eq "C1 wa-worker does NOT read HQ -> the HQ top-up is gated off"  "$(run_hq_serves wa-worker)"   "1"
eq "C2 ps-worker does NOT read HQ -> gated off"                    "$(run_hq_serves ps-worker)"   "1"
eq "C3 a pool outside this predicate (gastown.dog) -> not gated"   "$(run_hq_serves gastown.dog)" "0"
: > "$WORK/gc_fail"
eq "C4 'gc rig list' fails -> gated off too (cannot tell is not 'reads HQ')" "$(run_hq_serves wa-worker)" "1"
rm -f "$WORK/gc_fail"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part D: ACCEPTANCE (d) — HQ P0 routed=wa-worker + a P1 in WA: the top-up does NOT open a session for the P0 ==="

# run_topup <pool> <n> — n top-up sweeps with the REAL _pilot_pool_topup / _topup_rig_pending / _topup_hq_serves_pool; the
# eligibility filters are `cat` (eligibility is not under test), the spawn is a stub that records and succeeds.
run_topup() {
  local _pool="$1" _n="${2:-1}"
  build_preludes
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""; DRY_RUN=0
    GC_VARIABLE_SESSION_MAX=100; PILOT_DOLT_SATURATED_AT_START=0
    export PILOT_TEST_WA_WORKER_LIVE_COUNT=0 PILOT_TEST_PS_WORKER_LIVE_COUNT=0
    log()  { printf 'log\t%s\n' "$*" >> "$WORK/logs.log"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }
    _pilot_live_session_count() { _PLSC_N=0; return 0; }
    _pilot_variable_session_count() { _PLSC_N=0; return 0; }
    _pilot_topup_spawn() {
      printf 'SPAWN\t%s\t%s\n' "$1" "$2" >> "$WORK/spawns.log"
      # the spawned session claims the bead it was opened for, as in production: it is no longer unassigned demand
      for _f in "$WORK"/stores/*/"$2".json; do
        [ -f "$_f" ] && jq '.assignee = "spawned-session"' "$_f" > "$_f.tmp" && mv "$_f.tmp" "$_f"
      done
      return 0
    }
    eval "$TOPUP_VARS"
    eval "$LOOP_PRELUDE"
    _TOPUP_RIG_PATHS_JSON="$(cat "$WORK/rigs.json")"
    _TOPUP_RIG_PATHS="$(printf '%s' "$_TOPUP_RIG_PATHS_JSON" | jq -r '.rigs[] | select(.hq == false) | .path')"
    _i=0
    while [ "$_i" -lt "$_n" ]; do _pilot_pool_topup "$_pool" 4; _i=$((_i + 1)); done
  ) >/dev/null 2>&1
}

# D1 — the incident: the HQ P0 (ga-) routed to wa-worker, a P1 in the WA store routed to wa-worker.
reset_world
mkbead city ga-p0 wa-worker 0
mkbead whatsapp_automation wa-p1 wa-worker 1
run_topup wa-worker 1
eq "D1 wa-worker top-up spawns for the WA P1 (the bead its workers can see)"                  "$(spawn_count wa-worker wa-p1)" "1"
eq "D1b ...and NEVER for the HQ P0 (invisible to wa-worker: a session 'for' it finds nothing)" "$(spawn_count wa-worker ga-p0)" "0"
eq "D1c the HQ store was not even queried for wa-worker demand"                                "$(hq_ready_calls)"              "0"

# D2 — only the HQ P0: nothing to spawn for (pre-fix: one session per sweep, for ever).
reset_world
mkbead city ga-p0 wa-worker 0
run_topup wa-worker 3
eq "D2 the HQ P0 alone -> 0 wa-worker sessions over 3 sweeps (was one per sweep)"             "$(spawn_count wa-worker)"       "0"

# D3 — ps-worker, symmetrically.
reset_world
mkbead city ga-p0 ps-worker 0
mkbead property_scrapers ps-p1 ps-worker 1
run_topup ps-worker 1
eq "D3 ps-worker top-up spawns for the PS P1 and not for the HQ P0" "$(spawn_count ps-worker ps-p1)/$(spawn_count ps-worker ga-p0)" "1/0"

# D4 — control: an HQ bead routed to gastown.dog is no wa-worker demand either; the WA P1 is still served.
reset_world
mkbead city ga-p0 gastown.dog 0
mkbead whatsapp_automation wa-p1 wa-worker 1
run_topup wa-worker 1
eq "D4 (control) the rig P1 is served exactly as before when HQ holds only dog-routed work" "$(spawn_count wa-worker wa-p1)/$(spawn_count wa-worker ga-p0)" "1/0"

# D5 — 'cannot tell' lands in the inert state: the rig list cannot be read -> the HQ is not scanned for demand.
reset_world
mkbead city ga-p0 wa-worker 0
: > "$WORK/gc_fail"
run_topup wa-worker 1
rm -f "$WORK/gc_fail"
eq "D5 rig list unreadable -> no spawn for the HQ P0, no HQ query" "$(spawn_count wa-worker)/$(hq_ready_calls)" "0/0"

# D6 — the skip is announced, once per pool (not once per sweep).
reset_world
mkbead city ga-p0 wa-worker 0
run_topup wa-worker 3
eq "D6 the 'top-up gate' line is logged once, not per sweep" "$(grep -c 'ga-vp2zr0: top-up gate' "$WORK/logs.log" 2>/dev/null || true)" "1"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part E: _pilot_heal_hq_blind_routes — an HQ bead never KEEPS the route of a pool that cannot read HQ ==="

run_heal() { # run_heal [ENV=VAL ...] — one heal pass; the env pairs are exported into the run
  build_preludes
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""; DRY_RUN=0
    PILOT_DOLT_SATURATED_AT_START=0
    for _kv in "$@"; do export "${_kv?}"; done
    log()  { printf 'log\t%s\n' "$*" >> "$WORK/logs.log"; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }
    eval "$TOPUP_VARS"
    eval "$HEAL_PRELUDE"
    _pilot_heal_hq_blind_routes
  ) >/dev/null 2>&1
}

reset_world
mkbead city ga-p0 wa-worker 0
mkbead city ga-ps ps-worker 1
mkbead city ga-dog gastown.dog 1
mkbead whatsapp_automation wa-p1 wa-worker 1
run_heal
eq "E1 an HQ bead routed to wa-worker is re-routed to gastown.dog"      "$(route_of city ga-p0)"  "gastown.dog"
eq "E1b an HQ bead routed to ps-worker is re-routed to gastown.dog"     "$(route_of city ga-ps)"  "gastown.dog"
eq "E1c a bead of the WA store routed to wa-worker is NOT touched (its pool reads it)" "$(route_of whatsapp_automation wa-p1)" "wa-worker"
eq "E1d an HQ bead already routed to gastown.dog is untouched"          "$(route_of city ga-dog)" "gastown.dog"
eq "E1e the re-route leaves ONE explanatory comment per bead"           "$(grep -c '^COMMENT	city/ga-' "$WORK/comments.log" 2>/dev/null || true)" "2"

reset_world
mkbead city ga-owned wa-worker 0 '[]' bug "gastown.dog-1"
mkbead city ga-epic wa-worker 0 '[]' epic
mkbead city ga-human wa-worker 0 '["gate:needs-human"]'
mkbead city ga-engine wa-worker 0 '["needs:engine-window"]'
run_heal
eq "E2 an ASSIGNED bead is left alone (someone owns it; the dispatch-side guard covers it)" "$(route_of city ga-owned)"  "wa-worker"
eq "E2b an EPIC is left alone (the top-up never counted it as demand either)"              "$(route_of city ga-epic)"   "wa-worker"
eq "E2c a gate:needs-human bead is left alone (it must not become dog work by a re-route)" "$(route_of city ga-human)"  "wa-worker"
eq "E2d a needs:engine-window bead is left alone"                                          "$(route_of city ga-engine)" "wa-worker"

reset_world
mkbead city ga-a wa-worker 0
mkbead city ga-b wa-worker 0
mkbead city ga-c wa-worker 0
run_heal PILOT_HQ_BLIND_ROUTE_HEAL_MAX=2
eq "E3 PILOT_HQ_BLIND_ROUTE_HEAL_MAX=2 with three blind beads -> exactly two healed (no write storm)" "$(grep -l gastown.dog "$WORK"/stores/city/*.json 2>/dev/null | wc -l | tr -d ' ')" "2"
run_heal PILOT_HQ_BLIND_ROUTE_HEAL_MAX=2
eq "E3b the next sweep heals the remaining one"                                                   "$(grep -l gastown.dog "$WORK"/stores/city/*.json 2>/dev/null | wc -l | tr -d ' ')" "3"

reset_world
mkbead city ga-p0 wa-worker 0
run_heal DRY_RUN=1
eq "E4 DRY_RUN=1 writes nothing"                                  "$(route_of city ga-p0)" "wa-worker"
eq "E4b ...and says what it WOULD do"                             "$(grep -c 'WOULD re-route HQ bead ga-p0' "$WORK/logs.log" 2>/dev/null || true)" "1"

reset_world
mkbead city ga-p0 wa-worker 0
run_heal PILOT_HQ_BLIND_ROUTE_HEAL=0
eq "E5 PILOT_HQ_BLIND_ROUTE_HEAL=0 disables it (no write, no bd call)" "$(route_of city ga-p0)/$(wc -l < "$WORK/bd.calls" | tr -d ' ')" "wa-worker/0"

reset_world
mkbead city ga-p0 wa-worker 0
run_heal PILOT_DOLT_SATURATED_AT_START=1
eq "E6 a saturated Dolt backs the heal off (it is a write)"       "$(route_of city ga-p0)/$(wc -l < "$WORK/bd.calls" | tr -d ' ')" "wa-worker/0"

# falhou/ilegível → warn, heal nothing, never write on a guess.
reset_world
mkbead city ga-p0 wa-worker 0
: > "$WORK/bd_ready_fail"
run_heal
eq "E7 bd ready FAILS -> nothing healed, a warn names it" "$(route_of city ga-p0)/$(grep -c 'could not read the HQ beads routed to wa-worker' "$WORK/warns.log" 2>/dev/null || true)" "wa-worker/1"
reset_world
mkbead city ga-p0 wa-worker 0
printf 'Error: dolt server is not reachable\n' > "$WORK/bd_ready_raw"
run_heal
eq "E8 bd prints something that is not a JSON array -> nothing healed, a warn names it" "$(route_of city ga-p0)/$(grep -c 'could not read the HQ beads routed to wa-worker' "$WORK/warns.log" 2>/dev/null || true)" "wa-worker/1"

# cannot tell which store the pool reads -> never write.
reset_world
mkbead city ga-p0 wa-worker 0
: > "$WORK/gc_fail"
run_heal
rm -f "$WORK/gc_fail"
eq "E9 the rig list cannot be read (verdict unknown) -> no query, no write" "$(route_of city ga-p0)/$(hq_ready_calls)" "wa-worker/0"

# a failed write leaves the bead as it was, warns, and does not stop the pass.
reset_world
mkbead city ga-p0 wa-worker 0
: > "$WORK/bd_update_fail"
run_heal
eq "E10 the write FAILS -> the bead is left as it was and a warn says so" "$(route_of city ga-p0)/$(grep -c 'could not re-route HQ bead ga-p0' "$WORK/warns.log" 2>/dev/null || true)" "wa-worker/1"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part F: _pilot_pool_cap_full_for — the pre-claim does not queue a bead the pool cannot see ==="

run_capfull() { # run_capfull <story_json> [rig-list-fails] -> the function's exit status (0 = 'queued behind the cap')
  build_preludes
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    export PILOT_TEST_WA_WORKER_LIVE_COUNT=4 PILOT_TEST_PS_WORKER_LIVE_COUNT=2
    PILOT_WA_WORKER_MAX=4; PILOT_PS_WORKER_MAX=2
    log() { :; }; warn() { :; }
    eval "$CAP_PRELUDE"
    _rc=0; _pilot_pool_cap_full_for "$1" || _rc=$?
    echo "$_rc"
  ) 2>/dev/null
}
story() { jq -nc --arg id "$1" --arg pool "$2" '{id:$id,title:"t",priority:0,metadata:{"gc.routed_to":$pool}}'; }

reset_world
eq "F1 an HQ P0 routed to wa-worker, pool AT its cap -> NOT queued (the claim runs and names the real problem)" "$(run_capfull "$(story ga-9t9acg.11 wa-worker)")" "1"
eq "F2 (control) a WA-store bead routed to wa-worker, pool at cap -> queued, as ever"                          "$(run_capfull "$(story wa-u4k wa-worker)")"       "0"
eq "F3 a bead whose store cannot be identified (prefix not in routes.jsonl) -> NOT queued on a guess"          "$(run_capfull "$(story zz-1 wa-worker)")"        "1"
eq "F4 an HQ bead routed to ps-worker, pool at cap -> NOT queued"                                              "$(run_capfull "$(story ga-1 ps-worker)")"        "1"
eq "F5 (control) a PS-store bead routed to ps-worker, pool at cap -> queued"                                   "$(run_capfull "$(story ps-h04q ps-worker)")"     "0"
eq "F6 a story with no id -> NOT queued"                                                                       "$(run_capfull '{"title":"t","metadata":{"gc.routed_to":"wa-worker"}}')" "1"
rm -f "$WORK/city/.beads/routes.jsonl"
eq "F7 routes.jsonl missing -> NOT queued even for a bead that would have been (cannot tell -> not 'queued')"  "$(run_capfull "$(story wa-u4k wa-worker)")"       "1"
write_routes
: > "$WORK/gc_fail"
eq "F8 the rig list cannot be read -> NOT queued"                                                              "$(run_capfull "$(story wa-u4k wa-worker)")"       "1"
rm -f "$WORK/gc_fail"
eq "F9 (control) a WA-store bead routed to gastown.dog is outside this skip -> unchanged (not queued)"         "$(run_capfull "$(story wa-u4k gastown.dog)")"     "1"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part G: the store-blind guard call site in dispatch_one(), OUTSIDE _IS_RIG_NATIVE ==="

# run_block <target> <bead_city> <rig_native 0|1> <dry_run 0|1> <store fixture dir name> <story_id>
#   -> "<rc>|<DISPATCH_RESULT>|<fell through 0|1>"; the block runs ONCE, so the state assertions read a single run.
#   <bead_city> is what dispatch_one() has in STORY_BEAD_CITY (may be "" = unknown); the bead's JSON is read from the fixture dir.
run_block() {
  local _target="$1" _city="$2" _rn="$3" _dry="$4" _fix="$5" _sid="$6"
  build_preludes
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; PILOT_RIG_PATHS_JSON=""
    log() { :; }; warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warns.log"; }
    _pilot_hold_or_escalate() { printf 'HOLD\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/holds.log"; }
    unmark_pool_builder() { printf 'UNMARK\t%s\n' "$1" >> "$WORK/holds.log"; }
    eval "$COMMON_PRELUDE"
    DISPATCH_RESULT=""; _FELL=0
    _blk() {
      local _SLING_TARGET="$1" STORY_BEAD_CITY="$2" _IS_RIG_NATIVE="$3" DRY_RUN="$4" STORY_ID="$6" BUILDER_TARGET="$1"
      local STORY
      STORY="$(jq -c . "$WORK/stores/$5/$6.json")"
      eval "$GUARD_BLOCK"
      _FELL=1
    }
    _rc=0; _blk "$_target" "$_city" "$_rn" "$_dry" "$_fix" "$_sid" >/dev/null 2>&1 || _rc=$?
    echo "$_rc|$DISPATCH_RESULT|$_FELL"
  ) 2>/dev/null
}

reset_world
mkbead city ga-blind wa-worker 0 '["pilot:dispatching"]'
_r="$(run_block wa-worker "$WORK/city" 0 0 city ga-blind)"
eq "G1 an HQ bead, target wa-worker, NOT rig-native -> refused (rc 1, hq_pool_store_blind), not fallen through" "$_r" "1|hq_pool_store_blind|0"
eq "G1b the blind gc.routed_to is stripped"                         "$(route_of city ga-blind)" ""
eq "G1c the claim is released (pilot:dispatching removed)"          "$(has_label city ga-blind pilot:dispatching && echo still-claimed || echo released)" "released"
eq "G1d it goes through the shared hold/escalate counter (slug ga-vp2zr0-hq-pool-blind)" "$(grep -c "^HOLD	$WORK/city	ga-blind	ga-vp2zr0-hq-pool-blind" "$WORK/holds.log" 2>/dev/null || true)" "1"

reset_world
mkbead city ga-blind wa-worker 0 '["pilot:dispatching"]'
_r="$(run_block wa-worker "$WORK/city" 0 1 city ga-blind)"
eq "G2 DRY_RUN=1 -> still reported as refused (rc 1, hq_pool_store_blind)" "$_r" "1|hq_pool_store_blind|0"
eq "G2b ...and nothing is written (route and claim intact)"               "$(route_of city ga-blind)/$(has_label city ga-blind pilot:dispatching && echo claimed || echo released)" "wa-worker/claimed"

reset_world
mkbead whatsapp_automation wa-own wa-worker 1 '["pilot:dispatching"]'
_r="$(run_block wa-worker "$WORK/rigs/whatsapp_automation" 1 0 whatsapp_automation wa-own)"
eq "G3 (control) a rig-native bead of the pool's OWN store falls through to the dispatch (no result)" "$_r" "0||1"

reset_world
mkbead city ga-dogbound gastown.dog 1 '["pilot:dispatching"]'
_r="$(run_block gastown.dog "$WORK/city" 0 0 city ga-dogbound)"
eq "G4 (control) an HQ bead going to gastown.dog is not this guard's business -> falls through" "$_r" "0||1"

reset_world
mkbead lexbh lx-blind wa-worker 1 '["pilot:dispatching"]'
_r="$(run_block wa-worker "$WORK/rigs/lexbh" 1 0 lexbh lx-blind)"
eq "G5 a RIG-NATIVE bead in a store the pool does not read falls through this block (the migrate/park arm below owns it)" "$_r" "0||1"

# cannot tell -> release + alert, NEVER dispatch.
reset_world
mkbead city ga-unk wa-worker 0 '["pilot:dispatching"]'
: > "$WORK/gc_fail"
_r="$(run_block wa-worker "$WORK/city" 0 0 city ga-unk)"
rm -f "$WORK/gc_fail"
eq "G6 the rig list cannot be read -> pool_store_unknown: rc 1, not fallen through"       "$_r" "1|pool_store_unknown|0"
eq "G6b ...the claim is released, the route is NOT stripped on a doubt"                    "$(has_label city ga-unk pilot:dispatching && echo claimed || echo released)/$(route_of city ga-unk)" "released/wa-worker"
eq "G6c ...and it is NOT held/escalated (the next sweep just asks again)"                   "$(grep -c '^HOLD' "$WORK/holds.log" 2>/dev/null || true)" "0"
eq "G6d ...but it is ALERTED: a warn names the doubt"                                       "$(grep -c 'cannot tell whether wa-worker reads the store' "$WORK/warns.log" 2>/dev/null || true)" "1"

reset_world
mkbead lexbh lx-unk wa-worker 0 '["pilot:dispatching"]'
: > "$WORK/gc_fail"
_r="$(run_block wa-worker "$WORK/rigs/lexbh" 1 0 lexbh lx-unk)"
rm -f "$WORK/gc_fail"
eq "G7 the unknown branch also covers a RIG-NATIVE bead (the guard no longer proceeds on a doubt there either)" "$_r" "1|pool_store_unknown|0"

reset_world
mkbead city ga-nostore wa-worker 0 '["pilot:dispatching"]'
_r="$(run_block wa-worker "" 0 0 city ga-nostore)"
eq "G8 STORY_BEAD_CITY empty (the bead's store is not known) -> pool_store_unknown, never fallen through" "$_r" "1|pool_store_unknown|0"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part H: wiring (drift guards) and mutation controls ==="

has() { local pat="$1" desc="$2"; if grep -Eq -- "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has 'DISPATCH_RESULT="hq_pool_store_blind"'                    "the HQ refusal has its own DISPATCH_RESULT"
has 'DISPATCH_RESULT="pool_store_unknown"'                     "the unknown outcome has its own DISPATCH_RESULT"
has '"rig_native_pool_store_migrated", "hq_pool_store_blind"'  "hq_pool_store_blind is classified as a guard outcome in _pilot_sweep_emit (a refusal, not a Pilot fault)"
if awk '/^_pilot_heal_hq_blind_routes$/{h=NR} /^_pilot_pool_topup "wa-worker"/{t=NR} END{exit !(h && t && h<t)}' "$DISPATCHER"; then
  ok "the heal runs BEFORE the first pool top-up of the sweep"
else
  bad "the heal does not precede _pilot_pool_topup in the sweep"
fi
if awk '/^_pilot_pool_topup\(\)/{f=1} f&&/if _topup_hq_serves_pool "\$_pool"; then/{g=NR} f&&/bd -C "\$GC_CITY" ready --metadata-field "gc.routed_to=\$_pool"/{q=NR} f&&/^}$/{exit} END{exit !(g && q && g<q)}' "$DISPATCHER"; then
  ok "the HQ query in _pilot_pool_topup sits behind the _topup_hq_serves_pool gate"
else
  bad "the HQ query in _pilot_pool_topup is not behind _topup_hq_serves_pool"
fi
if awk '/^_pilot_pool_cap_full_for\(\)/{f=1} f&&/_pilot_pool_store_verdict "\$_pool" "\$_home"/{v=NR} f&&/_pilot_pool_live_count "\$_pool"/{c=NR} f&&/^}$/{exit} END{exit !(v && c && v<c)}' "$DISPATCHER"; then
  ok "the pre-claim asks the store verdict BEFORE it counts the pool's sessions"
else
  bad "the pre-claim does not ask the store verdict before the cap count"
fi
if awk '/_pilot_pool_store_blind_guard "\$_SLING_TARGET" "\$STORY_BEAD_CITY"/{g=NR} /_IS_RIG_NATIVE.*= *"1".*&&.*_PSB_RC|_IS_RIG_NATIVE" = "1" \] && \[ "\$_PSB_RC"/{r=NR} END{exit !(g && r && g<r)}' "$DISPATCHER" \
   && ! awk '/_pilot_pool_store_blind_guard "\$_SLING_TARGET"/{print; exit}' "$DISPATCHER" | grep -q '_IS_RIG_NATIVE'; then
  ok "the guard is invoked unconditionally, before the rig-native migrate arm (not inside 'if _IS_RIG_NATIVE')"
else
  bad "the guard call is still conditional on _IS_RIG_NATIVE"
fi

# Mutation controls — the rule reverted in a COPY of the dispatcher must fail the scenario that guards it.
mutate() { # mutate <name> <old> <new> [expected-occurrences] -> $WORK/mut/<name>.sh ; fails when <old> is not there that many times
  local _n="${4:-1}" _have
  _have="$(python3 -I - "$DISPATCHER" "$2" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().count(sys.argv[2]))
PY
)"
  if [ "$_have" != "$_n" ]; then
    bad "H[$1] the mutation cannot be applied: expected $_n occurrence(s) of the text to revert, found $_have (pre-fix dispatcher?) — a control that cannot run proves nothing"
    return 1
  fi
  python3 -I - "$DISPATCHER" "$WORK/mut/$1.sh" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4]))
PY
}
killed() { # killed <name> <what the mutant did> <got> <the right answer>
  if [ "$3" != "$4" ]; then ok "H[$1] $2 -> the guarding scenario FAILS on the mutant (got '$3', the rule says '$4')"; else bad "H[$1] $2 -> the mutant still passes the guarding scenario ('$3'): the selftest does not guard this rule"; fi
}

# the HQ top-up gate reverted: the query runs for every pool -> the P0 gets its session again.
if mutate hqgate 'if _topup_hq_serves_pool "$_pool"; then' 'if true; then'; then
  DISP="$WORK/mut/hqgate.sh"
  reset_world; mkbead city ga-p0 wa-worker 0; mkbead whatsapp_automation wa-p1 wa-worker 1
  run_topup wa-worker 1; _got="$(spawn_count wa-worker ga-p0)"
  DISP="$DISPATCHER"
  killed hqgate "the HQ top-up asks nobody whether the pool reads HQ" "$_got" "0"
fi
# the verdict's "unknown" read as "serves": an unreadable rig list lets the HQ query run.
if mutate unk2serves '_PSV_VERDICT="unknown"
  _PSV_POOL_RIG=""' '_PSV_VERDICT="serves"
  _PSV_POOL_RIG=""'; then
  DISP="$WORK/mut/unk2serves.sh"
  reset_world; mkbead city ga-p0 wa-worker 0; : > "$WORK/gc_fail"
  run_topup wa-worker 1; _got="$(spawn_count wa-worker ga-p0)"; rm -f "$WORK/gc_fail"
  DISP="$DISPATCHER"
  killed unk2serves "'cannot tell' defaults to 'the pool reads this store'" "$_got" "0"
fi
# the pre-claim store check reverted: the HQ P0 is queued behind the cap again.
if mutate precaim 'if [ "$_PSV_VERDICT" != "serves" ]; then return 1; fi
  # Return 1 either way' '# (mutant) no store check
  # Return 1 either way'; then
  DISP="$WORK/mut/precaim.sh"
  reset_world; _got="$(run_capfull "$(story ga-9t9acg.11 wa-worker)")"
  DISP="$DISPATCHER"
  killed precaim "the pre-claim queues an HQ bead behind the wa-worker cap" "$_got" "1"
fi
# the heal's write reverted to a no-op.
if mutate noheal 'bd -C "$GC_CITY" update "$_id" --set-metadata "gc.routed_to=gastown.dog" -q' 'true'; then
  DISP="$WORK/mut/noheal.sh"
  reset_world; mkbead city ga-p0 wa-worker 0
  run_heal; _got="$(route_of city ga-p0)"
  DISP="$DISPATCHER"
  killed noheal "the heal no longer re-routes" "$_got" "gastown.dog"
fi

echo ""
echo "pilot-dispatcher.hq-pool-store-blind.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
