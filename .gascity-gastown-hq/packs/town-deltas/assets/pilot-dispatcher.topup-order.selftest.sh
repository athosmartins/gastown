#!/usr/bin/env bash
# pilot-dispatcher.topup-order.selftest.sh — ga-9t9acg.4 (programa ga-9t9acg: ordem única, prioridade > tipo > idade).
#
# THE BUG. Pool top-up (_pilot_pool_topup, HQ query; _topup_rig_pending, rig fallback) asked bd for
# `--limit=20` with no --sort and spawned a session for `.[0].id`. A window of 20 cut the oldest P0 feature off before
# anything was ordered (ga-g7yt: window + post-filter hides real work), and the survivor was whatever bd listed first
# — not the bead the rule serves first (all P0 features oldest-first, then the other P0s, then P1 features, ...).
#
# THE FIX. Fetch the whole population (`--limit 0`), keep the same filters and vetoes, order with the shared library
# (scripts/work-order.sh, work_order_sort --age reclaim) in _topup_pick_first, take the first. Library says "cannot
# tell" -> keep the previous pick and WARN; never "nothing pending".
#
# Parts:
#   A  the 25-bead fixture: 25 routed P0/P1 beads, the oldest P0 feature 24th in bd's order. Top-up must choose it —
#      through the real query path (a fake bd that honours --limit), through the test seam, and through the rig fallback.
#      THIS IS THE RED ON THE PRE-FIX DISPATCHER (window of 20 + bd's order -> the first bead, not the oldest feature).
#   B  the rule on small populations (priority > type > age, the reclaim age, the epic/brake filters still apply).
#   C  the three states: an illegible field stays and is WARNed on stderr; "cannot tell" keeps the previous pick + WARN
#      (and says so when even that pick has no id). C6..C9: the same for the INPUT — not an array / non-bead elements /
#      a title that is not a string — never the same silence as an empty queue.
#   D  AGREEMENT WITH THE WORKER PROBE (R5/R6): the dispatcher comment above _topup_pick_first names THIS part as the
#      test that top-up and the pool worker pick the same bead. It runs the probe's own Step 1b2, taken live from
#      agents/{wa,ps}-worker/prompt.template.md, on the same populations as top-up: the `bd ready … | jq …` line before
#      the migration, the WHOLE `X_CAND="$(…)" … work_order_sort … printf '%s\n' "$X_PICK"` block after slices
#      ga-9t9acg.5/.6 (run with GC_CITY_PATH naming the tree this selftest lives in; a probe that WARNs and falls back to
#      its pre-library order is a FAIL, not an agreement). Each case is `must` or a NAMED known divergence. D1/D1b
#      (priority + age, a reclaimed bead) are `must`: both orders agree there TODAY, so a worker that disagrees is a FAIL
#      even before it migrates. D2/D3 (the type tier, the window of 20) are reported by name while the template still
#      carries the pre-migration probe, and must agree the moment it is migrated; and a divergence is only ever a note
#      while the respawn brake is OFF for that pool (see F) — a divergence that reaches the brake is a FAIL. D0 checks
#      the extraction itself on a synthetic template; DM checks `must` and the brake rule with synthetic workers.
#   E  the library-sourcing block of the dispatcher (present -> loaded; missing -> a visible WARN, no abort).
#   F  THE BRAKE (ga-653ilw) vs THIS ORDER: _pilot_pool_topup counts a top-up spawn toward the respawn brake only while the
#      pool worker's template carries the migrated probe. Real _topup_note_spawn over a stateful fake bd, several
#      consecutive sweeps, a bead nobody claims: an unmigrated worker -> NOT counted, NOT braked, a WARN each time; a
#      migrated one -> counted, braked at the cap of 5, the next bead is served; the switch re-arms the brake by itself.
#   G  mutation controls: the rule reverted in a COPY of the dispatcher (window back to 20, no ordering, no reclaim age,
#      "cannot tell" read as empty, the library's stderr swallowed, the brake counting spawns of an unmigrated worker,
#      the first-stage guards of _topup_pick_first removed)
#      must each fail the part that guards it.
#
# Falsifiable: run it against the pre-fix dispatcher and every part fails on assertions (A, B, C, D, E, F, G; measured 35 pass / 76 fail — the passes include D0, which tests the harness, not the dispatcher):
#   PILOT_DISPATCHER_PATH=<pre-fix pilot-dispatcher.sh> bash pilot-dispatcher.topup-order.selftest.sh
#
# Conventions: verbatim function extraction (awk) from the live dispatcher + PATH-stubbed gc/bd/timeout inside the sandbox
# PATH (selftest-sandbox-path.lib.sh: the REAL gc/bd cannot resolve). bash 3.2-safe. Exit 0 iff every assertion holds.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.topup-order.selftest.sh

set -uo pipefail
# ga-kqa08j: the worker probes read the gate focus mode; pin it OFF so a run inside the
# live city (or a gate reviewer whose env names it) never inherits the real state.
export GATE_FOCUS_ACTIVE_OVERRIDE=0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="$SELF_DIR/scripts/work-order.sh"
ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
WA_TEMPLATE="$ROOT/agents/wa-worker/prompt.template.md"
PS_TEMPLATE="$ROOT/agents/ps-worker/prompt.template.md"

PASS=0
FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
note() { echo "  ℹ $*"; }
eq() { # eq <what> <got> <expected>
  if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> got '$2', expected '$3'"; fi
}

for _f in "$DISPATCHER" "$LIB"; do
  [ -f "$_f" ] || { echo "FATAL: $_f not found" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-topup-order-selftest.XXXXXX")" || exit 2
case "$WORK" in /*/pilot-topup-order-selftest.*) ;; *) echo "FATAL: unexpected scratch dir '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city" "$WORK/rigs/whatsapp_automation" "$WORK/rigs/property_scrapers" "$WORK/stores" "$WORK/mut"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK" jq || exit 2
export FAKE_WORK="$WORK"

# ── fakes ───────────────────────────────────────────────────────────────────
# `timeout` shim: drop the duration and exec (this harness's PATH has no real one).
cat > "$WORK/bin/timeout" <<'TO'
#!/usr/bin/env bash
shift
exec "$@"
TO
chmod +x "$WORK/bin/timeout"

cat > "$WORK/rigs.json" <<EOF
{"rigs":[
 {"name":"gascity","path":"$WORK/city","hq":true},
 {"name":"property_scrapers","path":"$WORK/rigs/property_scrapers","hq":false},
 {"name":"whatsapp_automation","path":"$WORK/rigs/whatsapp_automation","hq":false}
]}
EOF

# A fake bd that answers `bd [-C dir] ready …` (and, for Part F, show / update --set-metadata / label add / comment), from
# $FAKE_WORK/stores/<basename of -C>.json (no -C: $PROBE_STORE).
# The file is the population IN THE ORDER bd WOULD RETURN IT (bd's own tie order is its business: the fixtures say what it
# is). It honours the flags the code under test sends: --metadata-field gc.routed_to=, --unassigned (every fixture bead is
# open and unassigned), --exclude-type, --exclude-label, --limit N / --limit=N / -n N (0 = everything), --sort priority
# (a STABLE sort by priority, so bd's tie order survives — the worst case for a window).
cat > "$WORK/bin/bd" <<'BD'
#!/usr/bin/env bash
W="${FAKE_WORK:?}"
printf 'bd\t%s\n' "$*" >> "$W/bd.calls"
store=""
if [ "${1:-}" = "-C" ]; then store="$(basename "$2")"; shift 2; fi
sub="${1:-}"; shift || true
sf="$W/stores/${store:-city}.json"
case "$sub" in
  ready) ;;
  show)    # one bead, as bd prints it: a one-element array. Unknown id / no store: an error, as bd does.
    out="$(jq -c --arg id "${1:-}" '[.[] | select(.id == $id)]' "$sf" 2>/dev/null)"
    { [ -n "$out" ] && [ "$out" != "[]" ]; } || { echo "Error: no such bead" >&2; exit 1; }
    printf '%s\n' "$out"; exit 0 ;;
  update)  # --set-metadata k=v (repeatable)
    id="${1:-}"; shift || true
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata) jq --arg id "$id" --arg k "${2%%=*}" --arg v "${2#*=}" 'map(if .id == $id then .metadata[$k] = $v else . end)' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  label)
    if [ "${1:-}" = add ]; then
      jq --arg id "${2:-}" --arg l "${3:-}" 'map(if .id == $id then .labels = (((.labels // []) + [$l]) | unique) else . end)' "$sf" > "$sf.tmp" && mv "$sf.tmp" "$sf"
    fi
    exit 0 ;;
  comment) printf 'COMMENT\t%s/%s\t%s\n' "$store" "${1:-}" "${2:-}" >> "$W/comments.log"; exit 0 ;;
  *) exit 0 ;;
esac
want=""; limit=100; sort="priority"; extype=""; exl=""
while [ $# -gt 0 ]; do
  case "$1" in
    --metadata-field) want="${2#gc.routed_to=}"; shift 2 ;;
    --exclude-label)  exl="$exl
$2"; shift 2 ;;
    --exclude-type)   extype="$2"; shift 2 ;;
    --exclude-type=*) extype="${1#*=}"; shift ;;
    --limit|-n)       limit="$2"; shift 2 ;;
    --limit=*)        limit="${1#--limit=}"; shift ;;
    --sort|-s)        sort="$2"; shift 2 ;;
    --sort=*)         sort="${1#--sort=}"; shift ;;
    *) shift ;;
  esac
done
f="$W/stores/${store:-${PROBE_STORE:-city}}.json"
[ -f "$f" ] || { echo "[]"; exit 0; }
exjson="$(printf '%s\n' "$exl" | jq -R . | jq -sc '.')"
jq -c --arg w "$want" --arg et "$extype" --arg sort "$sort" --argjson lim "$limit" --argjson ex "$exjson" '
  [ .[] | select(.status == "open") | select((.assignee // "") == "")
        | select(($w == "") or ((.metadata["gc.routed_to"] // "") == $w))
        | select(($et == "") or ((.issue_type // "") != $et))
        | select(((.labels // []) | map(select(. as $l | $ex | index($l))) | length) == 0) ]
  | (if $sort == "priority" then sort_by(.priority) else . end)
  | (if $lim > 0 then .[:$lim] else . end)' "$f"
BD
chmod +x "$WORK/bin/bd"

# ── extraction (from $DISP, so the mutation controls can point it at a mutated copy) ─────────────────────────
DISP="$DISPATCHER"
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISP"; }
MISSING=""
need() { # need <fn>... — echoes the sources; records (does not abort on) a missing function
  local _f _s
  for _f in "$@"; do
    _s="$(fn_src "$_f")"
    if [ -z "$_s" ]; then MISSING="$MISSING $_f"; else printf '%s\n' "$_s"; fi
  done
}
prelude_for() { # sets PRELUDE and TOPUP_VARS from $DISP
  MISSING=""
  PRELUDE="$(need rig_to_builders wa_worker_template _pilot_rig_builds_pool _topup_rig_serves_pool _topup_exclude_braked \
                  _topup_pick_first _topup_rig_pending _pilot_pool_topup)"
  TOPUP_VARS="$(awk '/^_TOPUP_WORKER_EXCLUDE_LABELS=\(/{f=1} f{print} f&&/^\)$/{exit}' "$DISP")
$(grep -m1 '^_TOPUP_EPIC_TITLE_RE=' "$DISP")"
}

# The library is loaded the way the dispatcher's own block loads it, except where a scenario says otherwise.
LIBMODE=ok
apply_libmode() {
  case "$LIBMODE" in
    ok)        . "$LIB" ;;
    none)      : ;;                                                                        # the library never loaded
    emptyfeat) WORK_ORDER_FEATURE_TYPES=""; export WORK_ORDER_FEATURE_TYPES; . "$LIB" ;;  # work_order_cfg refuses: exit 2
    silent)    . "$LIB"; work_order_sort() { cat >/dev/null; return 0; } ;;                # exit 0 and EMPTY stdout
    headfail)  . "$LIB"; work_order_head() { cat >/dev/null; return 2; } ;;                # cannot read the first bead
  esac
}

# pick_direct <json> -> the id _topup_pick_first prints for that candidate array; the run's stderr lands in run.err.
pick_direct() {
  local _json="$1"
  prelude_for
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"
    eval "$TOPUP_VARS"; eval "$PRELUDE"
    apply_libmode
    printf '%s' "$_json" | _topup_pick_first
  ) 2>"$WORK/run.err"
}

write_store() { printf '%s' "$2" > "$WORK/stores/$1.json"; }
clear_stores() { rm -f "$WORK"/stores/*.json; }

# run_topup <pool> <mode> [json] -> the bead id _pilot_pool_topup spawned a session for ("" = none).
#   mode bd    the real HQ query path: the fake bd answers from stores/city.json
#   mode rig   HQ empty, the pool's own rig store answers (the _topup_rig_pending path)
#   mode seam  PILOT_TEST_*_TOPUP_CANDIDATES_JSON = <json>
# The three eligibility filters are `cat` here (eligibility is not under test; the main selftest covers it with the
# real ones); _topup_exclude_braked, the epic filter and the order are the real code.
run_topup() {
  local _pool="$1" _mode="$2" _json="${3:-}"
  : > "$WORK/spawn.log"; : > "$WORK/bd.calls"; : > "$WORK/warn.log"
  prelude_for
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; DRY_RUN=0; GC_VARIABLE_SESSION_MAX=100
    PILOT_DOLT_SATURATED_AT_START=0
    export PILOT_TEST_WA_WORKER_LIVE_COUNT=0 PILOT_TEST_PS_WORKER_LIVE_COUNT=0
    log()  { :; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warn.log"; }
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }
    _pilot_variable_session_count() { _PLSC_N=0; return 0; }
    _pilot_topup_spawn() { printf '%s\n' "$2" >> "$WORK/spawn.log"; return 0; }
    _topup_note_spawn() { return 0; }
    eval "$TOPUP_VARS"; eval "$PRELUDE"
    apply_libmode
    _TOPUP_RIG_PATHS_JSON="$(cat "$WORK/rigs.json")"
    _TOPUP_RIG_PATHS="$(printf '%s' "$_TOPUP_RIG_PATHS_JSON" | jq -r '.rigs[] | select(.hq == false) | .path')"
    if [ "$_mode" = seam ]; then
      case "$_pool" in
        wa-worker) export PILOT_TEST_WA_WORKER_TOPUP_CANDIDATES_JSON="$_json" ;;
        ps-worker) export PILOT_TEST_PS_WORKER_TOPUP_CANDIDATES_JSON="$_json" ;;
      esac
    fi
    _pilot_pool_topup "$_pool" 1
  ) >/dev/null 2>"$WORK/run.err"
  head -n1 "$WORK/spawn.log"
}

# run_sweeps <pool> <n> — n CONSECUTIVE top-up sweeps over the stores as they are, with the brake code REAL
# (_topup_pending_store, _topup_note_spawn, _topup_worker_probe_migrated, all extracted from $DISP). The spawn is a stub
# that records the bead and succeeds, and nothing ever claims the bead: the shape of a worker that takes some other
# bead. spawn.log / warn.log accumulate over the n sweeps (run_topup clears them; this does not).
run_sweeps() {
  local _pool="$1" _n="$2"
  : > "$WORK/spawn.log"; : > "$WORK/warn.log"; : > "$WORK/comments.log"
  prelude_for
  (
    set -euo pipefail
    PATH="$SANDBOX_PATH"; GC_CITY="$WORK/city"; DRY_RUN=0; GC_VARIABLE_SESSION_MAX=100
    PILOT_DOLT_SATURATED_AT_START=0
    export PILOT_TEST_WA_WORKER_LIVE_COUNT=0 PILOT_TEST_PS_WORKER_LIVE_COUNT=0
    log()  { :; }
    warn() { printf 'warn\t%s\n' "$*" >> "$WORK/warn.log"; }
    _filter_exec_manual() { cat; }; _filter_candidates() { cat; }; _filter_label_vetoes() { cat; }
    _pilot_variable_session_count() { _PLSC_N=0; return 0; }
    _pilot_topup_spawn() { printf '%s\n' "$2" >> "$WORK/spawn.log"; return 0; }
    eval "$TOPUP_VARS"; eval "$PRELUDE"
    eval "$(need _topup_pending_store _topup_note_spawn _topup_worker_probe_migrated)"
    apply_libmode
    _TOPUP_RIG_PATHS_JSON="$(cat "$WORK/rigs.json")"
    _TOPUP_RIG_PATHS="$(printf '%s' "$_TOPUP_RIG_PATHS_JSON" | jq -r '.rigs[] | select(.hq == false) | .path')"
    _i=0
    while [ "$_i" -lt "$_n" ]; do _pilot_pool_topup "$_pool" 1; _i=$((_i + 1)); done
  ) >/dev/null 2>"$WORK/run.err"
}
spawns_for() { grep -c "^$1\$" "$WORK/spawn.log" 2>/dev/null || true; }
bead_in() { jq -r --arg id "$2" "[.[] | select(.id == \$id)][0] | $3" "$WORK/stores/$1.json" 2>/dev/null; }

# set_worker_template <pool> <migrated|legacy|none> — what the sandbox city's agents/<pool>/prompt.template.md carries
# (the file _topup_worker_probe_migrated reads). `migrated` is the shape slices ga-9t9acg.5/.6 deploy; `legacy` is the
# one-liner of today.
set_worker_template() {
  mkdir -p "$WORK/city/agents/$1"
  case "$2" in
    migrated) printf '%s\n' '# Step 1b2' 'X_CAND="$(' "bd ready --metadata-field \"gc.routed_to=$1\" --unassigned --json --limit 0" ')"' \
                '  X_SORTED="$( . "$X_LIB" && printf '"'"'%s'"'"' "$X_CAND" | work_order_sort --age reclaim )" && [ -n "$X_SORTED" ]' \
                > "$WORK/city/agents/$1/prompt.template.md" ;;
    legacy)   printf '%s\n' '# Step 1b2' "bd ready --metadata-field \"gc.routed_to=$1\" --unassigned --json --limit=20 | jq -c '.[:1]'" \
                > "$WORK/city/agents/$1/prompt.template.md" ;;
    none)     rm -f "$WORK/city/agents/$1/prompt.template.md" ;;
  esac
}

# ── fixtures ────────────────────────────────────────────────────────────────
# bead <id> <prio> <type> <created> [updated] [labels-json] [pool] -> one routed, open, unassigned bead
bead() {
  jq -nc --arg id "$1" --argjson p "$2" --arg t "$3" --arg c "$4" --arg u "${5:-$4}" --argjson l "${6:-[]}" --arg pool "${7:-wa-worker}" \
    '{id:$id, title:("T " + $id), status:"open", priority:$p, issue_type:$t, created_at:$c, updated_at:$u, labels:$l,
      metadata:{"gc.routed_to":$pool}}'
}
arr() { jq -sc '.'; }
# big25 <prefix> <pool> -> 25 routed beads in bd's order: 22 recent P0s (odd = feature, even = bug, newest first), then the
# OLDEST P0 BUG (23rd), the OLDEST P0 FEATURE (24th — the bead the rule serves first) and a P1 feature older than all (25th).
big25() {
  jq -n --arg pre "$1" --arg pool "$2" '
    def b($id; $pri; $type; $created): {id:$id, title:("T " + $id), status:"open", priority:$pri, issue_type:$type,
        created_at:$created, updated_at:$created, labels:[], metadata:{"gc.routed_to":$pool}};
    def pad: tostring | if length < 2 then "0" + . else . end;
    [ range(1; 23) as $i
      | b(($pre + "-p0-" + ($i | pad)); 0; (if $i % 2 == 1 then "feature" else "bug" end);
          ("2026-10-06T10:" + ((60 - $i) | pad) + ":00Z")) ]
    + [ b(($pre + "-p0-oldbug"); 0; "bug"; "2026-09-01T00:00:00Z"),
        b(($pre + "-p0-oldfeat"); 0; "feature"; "2026-09-10T00:00:00Z"),
        b(($pre + "-p1-ancient"); 1; "feature"; "2026-08-01T00:00:00Z") ]'
}

echo "pilot-dispatcher.topup-order.selftest — ga-9t9acg.4"
prelude_for
if [ -n "$MISSING" ]; then
  echo "  (pre-fix dispatcher? these functions are not defined:$MISSING — the scenarios that need them fail below)"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part A: 25 routed P0/P1 beads, the oldest P0 feature is 24th in bd's order ==="

BIG_WA="$(big25 wa wa-worker)"
eq "A0 fixture: 25 beads" "$(printf '%s' "$BIG_WA" | jq 'length')" "25"
eq "A0 fixture: the oldest P0 feature is 24th in bd's order" "$(printf '%s' "$BIG_WA" | jq -r '.[23].id')" "wa-p0-oldfeat"
eq "A0 fixture: bd's first bead is NOT it (what the pre-fix code takes)" "$(printf '%s' "$BIG_WA" | jq -r '.[0].id')" "wa-p0-01"

clear_stores; write_store city "$BIG_WA"
_got="$(run_topup wa-worker bd)"
eq "A1 wa-worker top-up, real HQ query path (fake bd honours --limit): spawns for the oldest P0 feature" "$_got" "wa-p0-oldfeat"
if grep -qE "^bd	-C $WORK/city ready .* --limit 0( |\$)" "$WORK/bd.calls" && ! grep -qE -- '--limit[ =][1-9]' "$WORK/bd.calls"; then
  ok "A1b the HQ query asks for the WHOLE population (--limit 0) and no call carries a positive window"
else
  bad "A1b the top-up query is not 'whole population' — bd calls: $(tr '\t\n' ' ' < "$WORK/bd.calls" | cut -c1-400)"
fi

_got="$(run_topup wa-worker seam "$BIG_WA")"
eq "A2 wa-worker top-up, test seam (…_TOPUP_CANDIDATES_JSON): same bead" "$_got" "wa-p0-oldfeat"

BIG_PS="$(big25 ps ps-worker)"
clear_stores; write_store city "$BIG_PS"
_got="$(run_topup ps-worker bd)"
eq "A3 ps-worker top-up, real HQ query path: spawns for the oldest P0 feature" "$_got" "ps-p0-oldfeat"
_got="$(run_topup ps-worker seam "$BIG_PS")"
eq "A3b ps-worker top-up, test seam: same bead" "$_got" "ps-p0-oldfeat"

clear_stores; write_store city "[]"; write_store whatsapp_automation "$BIG_WA"
_got="$(run_topup wa-worker rig)"
eq "A4 rig fallback (HQ empty; _topup_rig_pending over the wa rig store): spawns for the oldest P0 feature" "$_got" "wa-p0-oldfeat"
if grep -qE "^bd	-C $WORK/rigs/whatsapp_automation ready .* --limit 0( |\$)" "$WORK/bd.calls" && ! grep -qE -- '--limit[ =][1-9]' "$WORK/bd.calls"; then
  ok "A4b the rig query asks for the WHOLE population (--limit 0) and no call carries a positive window"
else
  bad "A4b the rig query is not 'whole population' — bd calls: $(tr '\t\n' ' ' < "$WORK/bd.calls" | cut -c1-400)"
fi
clear_stores; write_store city "[]"; write_store property_scrapers "$BIG_PS"
_got="$(run_topup ps-worker rig)"
eq "A4c rig fallback, ps-worker over the ps rig store" "$_got" "ps-p0-oldfeat"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part B: the rule on small populations (priority > type > age; reclaim age; filters still apply) ==="

B1="$( { bead b1-p1-ancient-feat 1 feature 2026-07-01T00:00:00Z; bead b1-p0-new-bug 0 bug 2026-10-05T00:00:00Z; } | arr)"
eq "B1 priority beats type and age: a recent P0 bug beats an ancient P1 feature" "$(pick_direct "$B1")" "b1-p0-new-bug"
B2="$( { bead b2-p0-old-bug 0 bug 2026-09-01T00:00:00Z; bead b2-p0-new-feat 0 feature 2026-10-05T00:00:00Z; } | arr)"
eq "B2 type beats age inside a priority: a newer P0 feature beats an older P0 bug" "$(pick_direct "$B2")" "b2-p0-new-feat"
B3="$( { bead b3-new 0 feature 2026-10-05T00:00:00Z; bead b3-old 0 feature 2026-09-02T00:00:00Z; bead b3-mid 0 feature 2026-09-20T00:00:00Z; } | arr)"
eq "B3 age: the OLDEST of the P0 features first" "$(pick_direct "$B3")" "b3-old"
B3b="$( { bead b3b-p1-old-task 1 task 2026-08-01T00:00:00Z; bead b3b-p1-new-feat 1 feature 2026-10-05T00:00:00Z; bead b3b-p2-old-feat 2 feature 2026-07-01T00:00:00Z; } | arr)"
eq "B3b P1 features before the other P1s, and every P1 before any P2" "$(pick_direct "$B3b")" "b3b-p1-new-feat"
# reclaim age (inherited anti-starvation ga-w4k2z/ga-oc6knj/ga-x80j1): a reclaimed bead ages by updated_at.
B4="$( { bead b4-reclaimed 0 feature 2026-08-01T00:00:00Z 2026-10-06T00:00:00Z '["pilot:reclaim-count:2"]'; bead b4-plain 0 feature 2026-09-20T00:00:00Z; } | arr)"
eq "B4 a P0 feature reclaimed twice (created 08-01, touched 10-06) does NOT hold position 0 on its ancient created_at" "$(pick_direct "$B4")" "b4-plain"
B4b="$( { bead b4b-unlabelled 0 feature 2026-08-01T00:00:00Z 2026-10-06T00:00:00Z; bead b4b-plain 0 feature 2026-09-20T00:00:00Z; } | arr)"
eq "B4b control: the same bead WITHOUT the reclaim label is aged by created_at and wins" "$(pick_direct "$B4b")" "b4b-unlabelled"
# filters kept: an EPIC-titled bead is never picked; a braked one is dropped; neither blocks the beads behind it.
B5="$( { bead b5-epic 0 feature 2026-08-01T00:00:00Z | jq -c '.title = "EPIC: x"'; bead b5-real 0 feature 2026-09-20T00:00:00Z; } | arr)"
eq "B5 an EPIC-titled P0 feature (older) is skipped, the real one is picked" "$(pick_direct "$B5")" "b5-real"
B5b="$( { bead b5b-braked 0 feature 2026-08-01T00:00:00Z '2026-08-01T00:00:00Z' '["pilot:topup-braked"]'; bead b5b-real 0 feature 2026-09-20T00:00:00Z; } | arr)"
clear_stores; write_store city "$B5b"
eq "B5b a pilot:topup-braked P0 feature (older) is dropped by the brake, the next one is picked (real query path)" "$(run_topup wa-worker bd)" "b5b-real"
eq "B6 an empty population: no id (and not an error)" "$(pick_direct '[]')" ""
eq "B6b a bd error envelope instead of an array: no id — the same inert answer the pipeline always ended in" "$(pick_direct '{"error":"boom"}')" ""
eq "B6c nothing on stdin at all: no id" "$(pick_direct '')" ""

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part C: the three states — an illegible field is kept and WARNed; 'cannot tell' keeps the previous pick ==="

LIBMODE=ok
C1="$( { bead c1-bad-prio '"high"' feature 2026-06-01T00:00:00Z; } | arr)"
_got="$(pick_direct "$C1")"
eq "C1 a bead with an illegible priority is NOT dropped (it is the only one: it is picked)" "$_got" "c1-bad-prio"
if grep -q '^work-order WARN: c1-bad-prio: prio?' "$WORK/run.err"; then
  ok "C1b the library's WARN line for it reaches stderr (its only signal): $(grep -m1 '^work-order WARN' "$WORK/run.err")"
else
  bad "C1b no 'work-order WARN: c1-bad-prio: prio?' on stderr — an illegible field would be silently misordered: [$(cat "$WORK/run.err")]"
fi
C1c="$( { bead c1c-bad-prio '"high"' feature 2026-06-01T00:00:00Z; bead c1c-p3-task 3 task 2026-10-05T00:00:00Z; } | arr)"
eq "C1c an illegible priority is never promoted: it goes BEHIND a P3" "$(pick_direct "$C1c")" "c1c-p3-task"

# cannot tell: each failure mode of the library must keep the previous pick (the first bead in bd's order) and WARN.
CT="$( { bead ct-first 1 task 2026-10-05T00:00:00Z; bead ct-second 0 feature 2026-09-01T00:00:00Z; } | arr)"
for _m in none emptyfeat silent headfail; do
  LIBMODE="$_m"
  _got="$(pick_direct "$CT")"
  eq "C2[$_m] the library cannot order: the PREVIOUS pick (first in bd's order), not 'nothing pending'" "$_got" "ct-first"
  if grep -q 'WARN ga-9t9acg.4: pool top-up cannot apply the order rule' "$WORK/run.err" && grep -q "NOT 'nothing pending'" "$WORK/run.err"; then
    ok "C2[$_m]b a visible WARN on stderr says so"
  else
    bad "C2[$_m]b no ga-9t9acg.4 WARN on stderr: [$(cat "$WORK/run.err")]"
  fi
done
LIBMODE=ok
_got="$(pick_direct "$CT")"
eq "C3 control: the same two beads with the library working -> the P0 feature (the rule, not the fallback)" "$_got" "ct-second"
if [ ! -s "$WORK/run.err" ]; then ok "C3b a clean run writes nothing to stderr"; else bad "C3b a clean run wrote to stderr: [$(cat "$WORK/run.err")]"; fi
# the same through the whole top-up loop: a broken library must not stop the pool being topped up.
LIBMODE=none
clear_stores; write_store city "$BIG_WA"
eq "C4 whole loop, library missing: top-up still spawns (for bd's first bead) — a visible WARN, not a silent stop" "$(run_topup wa-worker bd)" "wa-p0-01"
if grep -q 'WARN ga-9t9acg.4' "$WORK/run.err"; then ok "C4b ...and the WARN reached the loop's stderr (the dispatcher log)"; else bad "C4b no WARN on the loop's stderr: [$(cat "$WORK/run.err")]"; fi
LIBMODE=ok
# structural: the library call carries no stderr redirection (its stderr is the signal). The judge looks at the ONE line
# that really pipes into the sorter — not at "some line that mentions work_order_sort", which a comment, the `type`
# probe above it or an error message would satisfy whatever the call itself did (that was the first version of C5).
# c5_judge <function source> -> ok | swallows | no-call (zero or several lines pipe into the sorter: it cannot be judged)
c5_judge() {
  local _calls _n
  _calls="$(printf '%s\n' "$1" | grep -E '^[^#]*\$\(.*\| *work_order_sort --age' || true)"
  _n="$(printf '%s' "$_calls" | grep -c . || true)"
  if [ "$_n" != "1" ]; then echo no-call
  elif printf '%s\n' "$_calls" | grep -q '2>'; then echo swallows
  else echo ok; fi
}
_pf="$(fn_src _topup_pick_first)"
eq "C5 the line of _topup_pick_first that pipes into work_order_sort carries no stderr redirection" "$(c5_judge "$_pf")" "ok"
# C5 controls: the judge must be able to say "swallows" and "no-call" — on a decoy where the OLD C5 passed.
_decoy='  # ... | work_order_sort --age reclaim 2>&1 (a comment)
  if ! type work_order_sort >/dev/null 2>&1; then _why=x
  elif ! _ordered=$(printf %s "$_eligible" | work_order_sort --age "$_age" 2>/dev/null) || [ -z "$_ordered" ]; then _why=y; fi
  echo "WARN: work_order_sort could not order" >&2'
eq "C5b control: a call that swallows its stderr is judged 'swallows' even with innocent work_order_sort lines around it" "$(c5_judge "$_decoy")" "swallows"
eq "C5c control: a function with no such call is judged 'no-call', never 'ok'" "$(c5_judge '  # work_order_sort --age reclaim lives elsewhere')" "no-call"

# C6..C9: the FIRST stage of _topup_pick_first (before the library is called) has the same three states. Found by the
# gate's review of the first submission and by the pre-gate self-audit of this diff: an input that is not a candidate array,
# or an array jq cannot filter, used to end in the same silent "no pending bead" as an empty queue.
LIBMODE=ok
for _bad_in in '{"error":"database unavailable"}' 'Error: dolt server is not reachable' 'null'; do
  _got="$(pick_direct "$_bad_in")"
  _tag="$(printf '%s' "$_bad_in" | head -c 24)"
  eq "C6 input that is not a JSON array [$_tag]: nothing is picked" "$_got" ""
  if grep -q "WARN ga-9t9acg.4: pool top-up got something that is not a JSON array" "$WORK/run.err" && grep -q "NOT 'nothing pending'" "$WORK/run.err"; then
    ok "C6b [$_tag] ...and a visible WARN says it is NOT 'nothing pending'"
  else
    bad "C6b [$_tag] input that is not a candidate array ended silently (indistinguishable from an empty queue): [$(cat "$WORK/run.err")]"
  fi
done
# controls: the two inputs that REALLY mean "no candidate" stay quiet — otherwise C6b would pass by warning on everything.
_got="$(pick_direct '[]')"; eq "C6c control: an empty array is an empty queue" "$_got" ""
if [ ! -s "$WORK/run.err" ]; then ok "C6d ...and says nothing"; else bad "C6d an empty array wrote to stderr: [$(cat "$WORK/run.err")]"; fi
_got="$(pick_direct '')"; eq "C6e control: bd printed nothing at all (the stages upstream swallow bd's exit status, so this cannot be told from an empty queue — said so in the header)" "$_got" ""
if [ ! -s "$WORK/run.err" ]; then ok "C6f ...and says nothing"; else bad "C6f blank input wrote to stderr: [$(cat "$WORK/run.err")]"; fi

# C7: a title that is not a string must not make jq fail and take the valid P0 feature down with it.
C7="$( { bead c7-weird-title 0 task 2026-09-01T00:00:00Z; bead c7-p0-feature 0 feature 2026-09-02T00:00:00Z; } | arr | jq -c '.[0].title = 5')"
eq "C7 a bead whose title is a number sits next to a valid P0 feature: the feature is served (the rule), not 'nothing'" "$(pick_direct "$C7")" "c7-p0-feature"
if [ ! -s "$WORK/run.err" ]; then ok "C7b ...with nothing on stderr"; else bad "C7b stderr is not empty for a mere odd title: [$(cat "$WORK/run.err")]"; fi

# C8: elements that are not beads (a string, null, a number) cannot be ordered: dropped and COUNTED out loud, the rest goes on.
C8="$( { bead c8-p0-feature 0 feature 2026-09-02T00:00:00Z; } | arr | jq -c '["junk", null, 7] + .')"
eq "C8 three non-bead elements around a valid bead: the bead is still served" "$(pick_direct "$C8")" "c8-p0-feature"
if grep -q "WARN ga-9t9acg.4: pool top-up ignored 3 element(s) of bd's array that are not beads" "$WORK/run.err"; then
  ok "C8b ...and the 3 dropped elements are counted on stderr"
else
  bad "C8b the dropped elements were not counted: [$(cat "$WORK/run.err")]"
fi

# C9: the fallback WARN may only promise a pick that exists. Library missing + a first bead with no readable id.
LIBMODE=none
C9="$( { bead c9-first 1 task 2026-10-05T00:00:00Z; bead c9-second 0 feature 2026-09-01T00:00:00Z; } | arr | jq -c 'del(.[0].id)')"
_got="$(pick_direct "$C9")"
eq "C9 library missing and bd's first bead has no id: nothing can be named" "$_got" ""
if grep -q "has no readable id either" "$WORK/run.err" && grep -q "NOT 'nothing pending'" "$WORK/run.err" && ! grep -q "keeping the PREVIOUS pick" "$WORK/run.err"; then
  ok "C9b ...and the WARN says so, instead of promising 'the PREVIOUS pick'"
else
  bad "C9b the fallback WARN promised a pick that does not exist: [$(cat "$WORK/run.err")]"
fi
LIBMODE=ok

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part D: top-up and the pool worker's probe (R5/R6, Step 1b2) must pick the same bead ==="

# probe_line <template> <pool> -> the Step 1b2 probe of <pool>, verbatim, as a runnable script. Two shapes exist:
#   - the pre-migration one-liner:  bd ready --metadata-field "gc.routed_to=<pool>" … | jq …
#   - the migrated block (slices ga-9t9acg.5/.6):  X_CAND="$(  <newline>  bd ready … | jq …  <newline>  )"  …sort via the
#     library, fall back with a WARN…  printf '%s\n' "$X_PICK"
# Taking only the `bd ready` line of the migrated block would leave out the very step that orders the pool, and "the probe
# picks bd's own first bead" would then be this harness's doing, not the probe's. Prints nothing (rc!=0) when the
# probe is not there OR is the migrated shape without its closing `printf … _PICK` line — an unreadable probe is never
# an agreement.
probe_line() {
  awk -v pool="$2" '
    BEGIN { want = "^bd ready --metadata-field \"gc.routed_to=" pool "\" " }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (line[i] ~ want) break
      if (i > NR) exit 1
      if (i > 1 && line[i-1] ~ /^[A-Z_]+="\$\($/) {
        for (j = i; j <= NR; j++) if (index(line[j], "printf ") == 1 && line[j] ~ /_PICK"$/) break
        if (j > NR) exit 2
        for (k = i - 1; k <= j; k++) print line[k]
      } else print line[i]
    }' "$1"
}
# probe_pick <template> <pool> <fixture-json> -> the id the template's OWN probe returns first ("" = it returned [] / nothing)
# The probe runs the way a worker session runs it: GC_CITY_PATH names the city whose packs/town-deltas/assets/scripts holds
# work-order.sh (here: the tree this selftest lives in; D0c points PROBE_CITY elsewhere), PATH is the sandbox with the
# fake bd. Its stderr is kept in $WORK/probe.err for the caller — a probe that fell back to its pre-library order did
# not apply the rule.
# GATE_FOCUS_ACTIVE_OVERRIDE=0: since ga-kqa08j the Step 1b2 block also sources the LIVE city's gate-focus-lib.sh (an
# absolute path, so GC_CITY_PATH cannot redirect it) and, while the gate queue is deep, keeps only gate:needs-fix beads —
# every fixture here has none, so on a city in focus mode the probe would print [] and Part D would FAIL on the weather.
# The override is the lib's own switch; it makes this part about ORDER, whatever the city is doing right now.
probe_pick() {
  local _line
  _line="$(probe_line "$1" "$2")" || return 1
  [ -n "$_line" ] || return 1
  printf '%s' "$3" > "$WORK/stores/probe.json"
  ( PATH="$SANDBOX_PATH"; PROBE_STORE=probe; GC_CITY_PATH="${PROBE_CITY:-$ROOT}"; GATE_FOCUS_ACTIVE_OVERRIDE=0
    export PROBE_STORE GC_CITY_PATH GATE_FOCUS_ACTIVE_OVERRIDE
    bash -c "$_line" 2>"$WORK/probe.err" ) | jq -r '.[0].id // ""'
}
# brake_gate_for <template> <pool> -> counted | off | unreadable: what the DISPATCHER's own _topup_worker_probe_migrated
# (extracted from $DISP) decides for that template — i.e. whether top-up spawns for <pool> count toward the respawn brake.
brake_gate_for() {
  local _src _rc
  _src="$(need _topup_worker_probe_migrated)"
  [ -n "$_src" ] || { echo unreadable; return 0; }
  mkdir -p "$WORK/gate-city/agents/$2"
  cp "$1" "$WORK/gate-city/agents/$2/prompt.template.md" || { echo unreadable; return 0; }
  ( GC_CITY="$WORK/gate-city"; eval "$_src"; _topup_worker_probe_migrated "$2" ) && _rc=0 || _rc=$?
  case "$_rc" in 0) echo counted ;; 1) echo off ;; *) echo unreadable ;; esac
}
# agree <label> <pool> <template> <prefix> <fixture-json> <expected-by-the-rule> <must | what-differs>
#   must          priority and age are the same in both orders, so the probe has to agree TODAY: a difference is a FAIL
#   <what-differs> a known divergence of the PRE-migration probe (named in the report). It is only a note while the
#                 respawn brake is OFF for the pool (brake_gate_for says `off`); once the probe is migrated it must agree.
agree() {
  local _label="$1" _pool="$2" _tpl="$3" _fx="$5" _want="$6" _mode="${7:-}" _top _probe _line _gate
  if [ -z "$_mode" ]; then bad "$_label: Part D bug — agree() needs 'must' or a description of the known divergence as its 7th argument"; return; fi
  clear_stores; write_store city "$_fx"
  _top="$(run_topup "$_pool" bd)"
  eq "$_label: top-up ($_pool) picks the bead the rule serves first" "$_top" "$_want"
  _line="$(probe_line "$_tpl" "$_pool")" || _line=""
  if [ -z "$_line" ]; then
    bad "$_label: the Step 1b2 'bd ready … | jq …' line for $_pool was not found in $(basename "$(dirname "$_tpl")")/prompt.template.md — update Part D to the migrated probe (slice ga-9t9acg.5/.6); an unreadable probe is not an agreement"
    return
  fi
  _probe="$(probe_pick "$_tpl" "$_pool" "$_fx")" || _probe="?"
  if grep -q 'WARN Step 1b2' "$WORK/probe.err" 2>/dev/null; then
    # The migrated probe announced that it could not apply the library and fell back (or printed nothing). Whatever it
    # picked then, it did not pick it BY THE RULE — matching top-up by luck must not read as agreement.
    bad "$_label: the $_pool probe did not run the shared order (it printed a WARN Step 1b2 and fell back): $(head -c 300 "$WORK/probe.err" | tr '\n' ' ')"
  elif [ "$_probe" = "$_top" ]; then
    ok "$_label: the worker's probe picks the SAME bead ($_probe)"
  elif [ "$_mode" = must ]; then
    bad "$_label: top-up picks '$_top' but the $_pool probe picks '$_probe' — priority and age are the same in both orders, so this case must agree TODAY (and a worker that disagrees here also breaks the respawn brake's premise)"
  elif printf '%s' "$_line" | grep -qE -- 'work[-_]order|--limit[ =]0( |$)' || ! printf '%s' "$_line" | grep -q -- '--limit=20'; then
    bad "$_label: the probe was migrated but picks '$_probe' while top-up picks '$_top' — they must agree (Part D header)"
  else
    _gate="$(brake_gate_for "$_tpl" "$_pool")"
    if [ "$_gate" = off ]; then
      note "$_label: KNOWN divergence — $_mode. The $_pool probe still carries the pre-migration Step 1b2 and picks '$_probe' where top-up picks '$_top'; the respawn brake is OFF for $_pool meanwhile, so the divergence cannot brake the rule's bead. Closed by slice ga-9t9acg.5/.6; from then on this case must agree."
    else
      bad "$_label: the $_pool probe diverges ($_mode: '$_probe' vs top-up '$_top') while the dispatcher's brake gate says '$_gate' — spawns would count toward the brake for a worker that takes another bead, and the rule's #1 bead would be braked for nothing"
    fi
  fi
}
mk_d1() { # mk_d1 <pool> -> priority + age populations with ONE reclaimed bead (old created_at, recent updated_at)
  { bead d1-p0-new 0 task 2026-10-05T00:00:00Z '2026-10-05T00:00:00Z' '[]' "$1"
    bead d1-p0-old 0 task 2026-09-01T00:00:00Z '2026-09-01T00:00:00Z' '[]' "$1"
    bead d1-p1-ancient 1 task 2026-07-01T00:00:00Z '2026-07-01T00:00:00Z' '[]' "$1"
    bead d1-p0-reclaimed 0 task 2026-08-01T00:00:00Z '2026-10-06T00:00:00Z' '["pilot:reclaim-count:1"]' "$1"; } | arr
}
for _p in wa-worker ps-worker; do
  case "$_p" in wa-worker) _tpl="$WA_TEMPLATE"; _pre=wa ;; *) _tpl="$PS_TEMPLATE"; _pre=ps ;; esac
  # D1: priority and age decide (no type difference, window not reached, one reclaimed bead): must agree TODAY.
  D1="$(mk_d1 "$_p")"
  agree "D1[$_p] priority + age, with a reclaimed bead" "$_p" "$_tpl" "$_pre" "$D1" "d1-p0-old" must
  D1b="$(printf '%s' "$D1" | jq -c '[.[] | select(.id != "d1-p0-old")]')"
  agree "D1b[$_p] the oldest is gone: the reclaimed bead (old created_at, recent updated_at) does not win on either side" "$_p" "$_tpl" "$_pre" "$D1b" "d1-p0-new" must
  # D2: the type tier (the rule: a P0 feature before an older P0 bug).
  D2="$( { bead d2-p0-old-bug 0 bug 2026-09-01T00:00:00Z '2026-09-01T00:00:00Z' '[]' "$_p"
           bead d2-p0-new-feat 0 feature 2026-10-05T00:00:00Z '2026-10-05T00:00:00Z' '[]' "$_p"; } | arr)"
  agree "D2[$_p] type tier: P0 feature vs an older P0 bug" "$_p" "$_tpl" "$_pre" "$D2" "d2-p0-new-feat" "the old probe has no type tier: it serves an older P0 bug before a newer P0 feature"
  # D3: the window (25 beads, the oldest P0 feature 24th: the probe's --limit=20 never sees it).
  agree "D3[$_p] window: 25 beads, the oldest P0 feature is 24th" "$_p" "$_tpl" "$_pre" "$(big25 "$_pre" "$_p")" "${_pre}-p0-oldfeat" "the old probe sees a window of 20 beads and the oldest P0 feature is the 24th"
done

# D0: the extraction itself. A harness that cannot run the migrated block would report "the probe picks bd's own first
# bead" whatever the template says (that is what taking only the `bd ready` line did against ga-9t9acg.6). So: a synthetic
# template in the migrated shape, whose sort step is swapped, must make probe_pick tell the two apart.
mk_probe_tpl() { # mk_probe_tpl <file> <the sort command of the pipeline> [no-end]
  cat > "$1" <<'TPL'
# Step 1b2 (synthetic)
PS_CAND="$(
bd ready --metadata-field "gc.routed_to=ps-worker" --unassigned --json --limit 0
)"
PS_LIB="${GC_CITY_PATH:-$GC_CITY}/packs/town-deltas/assets/scripts/work-order.sh"
PS_PICK=""
PS_SORTED="$( . "$PS_LIB" && printf '%s' "$PS_CAND" | __SORT__ )" && [ -n "$PS_SORTED" ] && PS_PICK="$(printf '%s' "$PS_SORTED" | jq -c '.[:1]')"
if [ -z "$PS_PICK" ]; then echo "WARN Step 1b2: could not order the pool" >&2; fi
printf '%s\n' "$PS_PICK"
# trailing prose
TPL
  sed -i.bak "s/__SORT__/$2/" "$1" && rm -f "$1.bak"
  if [ "${3:-}" = no-end ]; then grep -v '^printf ' "$1" > "$1.new" && mv "$1.new" "$1"; fi
}
D0="$( { bead d0-p0-old-bug 0 bug 2026-09-01T00:00:00Z '2026-09-01T00:00:00Z' '[]' ps-worker
         bead d0-p0-new-feat 0 feature 2026-10-05T00:00:00Z '2026-10-05T00:00:00Z' '[]' ps-worker; } | arr)"
mk_probe_tpl "$WORK/d0-ordering.md" 'work_order_sort --age reclaim'
mk_probe_tpl "$WORK/d0-noop.md" 'cat'
mk_probe_tpl "$WORK/d0-truncated.md" 'work_order_sort --age reclaim' no-end
eq "D0a the migrated block is run whole: its sort step orders the pool (P0 feature before the older P0 bug)" "$(probe_pick "$WORK/d0-ordering.md" ps-worker "$D0")" "d0-p0-new-feat"
eq "D0b a migrated block whose sort step does nothing returns bd's own first bead — the harness can tell" "$(probe_pick "$WORK/d0-noop.md" ps-worker "$D0")" "d0-p0-old-bug"
_o="$(PROBE_CITY="$WORK/no-such-city" probe_pick "$WORK/d0-ordering.md" ps-worker "$D0")"
if [ -z "$_o" ] && grep -q 'WARN Step 1b2' "$WORK/probe.err"; then ok "D0c the library missing under GC_CITY_PATH: nothing picked and the probe's WARN reaches the harness (agree() turns that into a FAIL)"
else bad "D0c the library missing under GC_CITY_PATH: picked '$_o', stderr: $(head -c 200 "$WORK/probe.err")"; fi
if probe_line "$WORK/d0-truncated.md" ps-worker >/dev/null 2>&1; then bad "D0d a migrated block without its closing 'printf … _PICK' line was accepted as a probe"
else ok "D0d a migrated block without its closing 'printf … _PICK' line is refused, not half-run"; fi

# DM: `must`, and the brake rule, on synthetic workers. agree() runs in $(…) so its counters stay out of ours; what is
# asserted is the verdict line it prints.
cat > "$WORK/dm-legacy-created.md" <<'TPL'
# Step 1b2 (synthetic worker that ages by created_at: no reclaim anti-starvation)
bd ready --metadata-field "gc.routed_to=ps-worker" --unassigned --json --limit=20 | jq -c 'sort_by([.priority, .created_at]) | .[:1]'
TPL
{ cat "$WORK/dm-legacy-created.md"
  echo '  PS_SORTED="$( . "$PS_LIB" && printf '"'"'%s'"'"' "$PS_CAND" | work_order_sort --age reclaim )"   # a second, migrated-looking line'; } > "$WORK/dm-split.md"
_o="$(agree DM1 ps-worker "$WORK/dm-legacy-created.md" ps "$(mk_d1 ps-worker)" d1-p0-old must)"
case "$_o" in *"✗ DM1"*"must agree TODAY"*) ok "DM1 a worker that ages by created_at disagrees on the reclaimed-bead case (D1): a FAIL in must-mode, not a note" ;; *) bad "DM1 a worker disagreeing on a must case was not failed: $_o" ;; esac
D2ps="$( { bead dm-old-bug 0 bug 2026-09-01T00:00:00Z '2026-09-01T00:00:00Z' '[]' ps-worker
           bead dm-new-feat 0 feature 2026-10-05T00:00:00Z '2026-10-05T00:00:00Z' '[]' ps-worker; } | arr)"
_o="$(agree DM2 ps-worker "$WORK/dm-legacy-created.md" ps "$D2ps" dm-new-feat "the old probe has no type tier")"
case "$_o" in *"✗ DM2"*) bad "DM2 a named divergence of an unmigrated worker (brake OFF) was failed: $_o" ;; *"ℹ DM2"*"KNOWN divergence — the old probe has no type tier"*"brake is OFF"*) ok "DM2 the same worker on the type tier is a NAMED note, because the brake is OFF for it" ;; *) bad "DM2 unexpected verdict: $_o" ;; esac
_o="$(agree DM3 ps-worker "$WORK/dm-split.md" ps "$D2ps" dm-new-feat "the old probe has no type tier")"
case "$_o" in *"✗ DM3"*"brake gate says 'counted'"*) ok "DM3 a divergence while the dispatcher's gate says the brake COUNTS this pool is a FAIL (it reaches the brake)" ;; *) bad "DM3 a divergence that reaches the brake was not failed: $_o" ;; esac

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part E: the library-sourcing block of the dispatcher ==="

_blk="$(awk '/SELFTEST-EXTRACT work-order-topup-source: BEGIN/{f=1;next} /SELFTEST-EXTRACT work-order-topup-source: END/{f=0} f' "$DISP")"
if [ -z "$_blk" ]; then
  bad "E0 no 'SELFTEST-EXTRACT work-order-topup-source' block in the dispatcher (pre-fix, or the markers moved)"
else
  ok "E0 the sourcing block is present"
  for _t in with without; do
    mkdir -p "$WORK/tree-$_t/scripts"
    [ "$_t" = with ] && cp "$LIB" "$WORK/tree-$_t/scripts/work-order.sh"
    { echo 'set -euo pipefail'; echo 'warn() { echo "WARNED: $*"; }'; printf '%s\n' "$_blk"
      echo 'if type work_order_sort >/dev/null 2>&1 && type work_order_head >/dev/null 2>&1; then echo LOADED; else echo NOT-LOADED; fi'
      echo 'echo SURVIVED'; } > "$WORK/tree-$_t/pilot-dispatcher.sh"
  done
  for _sh in /bin/bash bash; do
    _o="$(PATH="$SANDBOX_PATH" "$_sh" "$WORK/tree-with/pilot-dispatcher.sh" 2>&1)"
    case "$_o" in *LOADED*SURVIVED*) case "$_o" in *NOT-LOADED*|*WARNED*) bad "E1[$_sh] the library next to the dispatcher was not loaded cleanly: $_o" ;; *) ok "E1[$_sh] scripts/work-order.sh next to the dispatcher is loaded, no warning" ;; esac ;; *) bad "E1[$_sh] unexpected output: $_o" ;; esac
    _o="$(PATH="$SANDBOX_PATH" "$_sh" "$WORK/tree-without/pilot-dispatcher.sh" 2>&1)"
    case "$_o" in
      *NOT-LOADED*WARNED:*ga-9t9acg.4*SURVIVED*|*WARNED:*ga-9t9acg.4*NOT-LOADED*SURVIVED*) ok "E2[$_sh] a missing library: a visible WARN naming ga-9t9acg.4, the script goes on (set -euo pipefail did not abort it)" ;;
      *) bad "E2[$_sh] a missing library was not announced and survived: $_o" ;;
    esac
  done
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part F: the respawn brake (ga-653ilw) vs this order — a spawn counts only for a worker on the shared order ==="

# The brake reads "spawned for A, A still unclaimed" as "A is stuck". Top-up now spawns for the rule's #1 bead; a worker that
# still runs the pre-migration probe takes ITS first bead instead, so the rule's #1 bead stays unclaimed through no fault of
# its own and the brake would label it pilot:topup-braked after 5 sweeps — and the next one after that, down the queue.
# _pilot_pool_topup therefore counts a spawn only when agents/<pool>/prompt.template.md carries the migrated probe.
# These are REAL consecutive sweeps (real _topup_note_spawn over a stateful fake bd); nothing ever claims the bead.
GB="$( { bead f-first 0 feature 2026-09-01T00:00:00Z '2026-09-01T00:00:00Z' '[]' wa-worker
         bead f-second 1 task 2026-09-02T00:00:00Z '2026-09-02T00:00:00Z' '[]' wa-worker; } | arr)"
f_braked() { bead_in city "$1" '(.labels // []) | (index("pilot:topup-braked") | tostring)'; }   # "null" = not braked
f_count()  { bead_in city "$1" '.metadata["pilot.topup_spawn_count"] // "none"'; }
f_warns()  { grep -c "$1" "$WORK/warn.log" 2>/dev/null || true; }

# F0: the gate itself (the dispatcher's own _topup_worker_probe_migrated), on the shapes that matter.
printf '%s\n' 'X_CAND="$(' 'bd ready --metadata-field "gc.routed_to=wa-worker" --json --limit 0' ')"' \
  '  WA_SORTED="$( . "$WA_LIB" && printf '"'"'%s'"'"' "$WA_CAND" | work_order_sort --age reclaim )" && [ -n "$WA_SORTED" ]' > "$WORK/f0-migrated.md"
printf '%s\n' '# (work_order_sort --age reclaim, sourced from ${GC_CITY_PATH:-$GC_CITY}) — this probe is not migrated yet' \
  'bd ready --metadata-field "gc.routed_to=wa-worker" --json --limit=20 | jq -c ".[:1]"' > "$WORK/f0-comment-only.md"
printf '%s\n' '  WA_SORTED="$( . "$WA_LIB" && printf '"'"'%s'"'"' "$WA_CAND" | work_order_sort --age created )"' > "$WORK/f0-age-created.md"
eq "F0a the migrated probe line (X_SORTED=\"\$( … work_order_sort --age reclaim …)\") -> the brake COUNTS" "$(brake_gate_for "$WORK/f0-migrated.md" wa-worker)" "counted"
eq "F0b a template that only MENTIONS work_order_sort in a comment is not migrated -> brake off" "$(brake_gate_for "$WORK/f0-comment-only.md" wa-worker)" "off"
eq "F0c a probe ordering by --age created is not the order top-up uses (reclaim) -> brake off" "$(brake_gate_for "$WORK/f0-age-created.md" wa-worker)" "off"
eq "F0d the pre-migration one-liner -> brake off" "$(brake_gate_for "$WORK/dm-legacy-created.md" ps-worker)" "off"
eq "F0e no template to read -> not 'counted' and not 'off': cannot tell" "$(brake_gate_for "$WORK/no-such-template.md" wa-worker)" "unreadable"

# F1: unmigrated worker, 8 sweeps (the cap is 5): spawns keep happening for the rule's #1 bead, none counted, none braked,
# and every one says so.
set_worker_template wa-worker legacy; clear_stores; write_store city "$GB"; run_sweeps wa-worker 8
eq "F1a unmigrated worker: top-up spawns for the rule's #1 bead on every sweep (8 of 8) — the trade-off: no brake until the probe migrates" "$(spawns_for f-first)" "8"
eq "F1b ...and the bead is NOT braked after 8 sweeps (the cap is 5)" "$(f_braked f-first)" "null"
eq "F1c ...nothing was counted on it" "$(f_count f-first)" "none"
eq "F1d ...each of the 8 spawns says the brake is OFF for wa-worker (a visible WARN, never silent)" "$(f_warns 'respawn brake OFF for wa-worker')" "8"
eq "F1e ...the next bead was never reached (the rule's #1 is not braked away)" "$(spawns_for f-second)" "0"

# F2: migrated worker: the brake works as ga-653ilw built it.
set_worker_template wa-worker migrated; clear_stores; write_store city "$GB"; run_sweeps wa-worker 8
eq "F2a migrated worker: 5 spawns for the rule's #1 bead (the cap), then the brake stops them" "$(spawns_for f-first)" "5"
eq "F2b ...the bead is labelled pilot:topup-braked" "$([ "$(f_braked f-first)" != null ] && echo braked || echo not-braked)" "braked"
eq "F2c ...with the count the brake recorded" "$(f_count f-first)" "5"
eq "F2d ...top-up then serves the NEXT bead (3 sweeps), it is not blocked behind the braked one" "$(spawns_for f-second)" "3"
eq "F2e ...which is counted too, and not braked yet (3 < 5)" "$(f_count f-second)/$(f_braked f-second)" "3/null"
eq "F2f ...the brake left exactly one comment on the braked bead" "$(grep -c '^COMMENT	city/f-first' "$WORK/comments.log" || true)" "1"
eq "F2g ...and no sweep said the brake was off" "$(f_warns 'respawn brake OFF')" "0"

# F3: the template cannot be read: cannot tell is not "migrated" — nothing counted, said out loud.
set_worker_template wa-worker none; clear_stores; write_store city "$GB"; run_sweeps wa-worker 3
eq "F3a no template: spawns still happen (3 of 3), none counted, none braked" "$(spawns_for f-first)/$(f_count f-first)/$(f_braked f-first)" "3/none/null"
eq "F3b ...each one WARNs that it cannot read the template" "$(f_warns 'cannot read .*agents/wa-worker/prompt.template.md')" "3"

# F4: self-arming. The same bead, the same store: counting starts the moment the template is migrated — and not before.
set_worker_template wa-worker legacy; clear_stores; write_store city "$GB"; run_sweeps wa-worker 3
eq "F4a 3 sweeps before the migration: nothing counted" "$(f_count f-first)/$(f_braked f-first)" "none/null"
set_worker_template wa-worker migrated; run_sweeps wa-worker 2
eq "F4b the template is migrated: the next 2 sweeps are counted from 0 (count 2), not braked" "$(f_count f-first)/$(f_braked f-first)" "2/null"
run_sweeps wa-worker 3
eq "F4c 3 more: the count reaches the cap of 5 and the bead is braked" "$(f_count f-first)/$([ "$(f_braked f-first)" != null ] && echo braked || echo not-braked)" "5/braked"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Part G: mutation controls — the rule reverted in a COPY of the dispatcher must fail the part that guards it ==="

# mutate <name> <old> <new> [expected-occurrences] -> $WORK/mut/<name>.sh ; fails if <old> is not there that many times
mutate() {
  local _n="${4:-1}" _have
  _have="$(python3 -I - "$DISPATCHER" "$2" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().count(sys.argv[2]))
PY
)"
  if [ "$_have" != "$_n" ]; then
    bad "G[$1] the mutation cannot be applied: expected $_n occurrence(s) of the text to revert, found $_have (pre-fix dispatcher?) — a control that cannot run proves nothing"
    return 1
  fi
  python3 -I - "$DISPATCHER" "$WORK/mut/$1.sh" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4]))
PY
}
killed() { # killed <name> <what the mutant did> <got> <the right answer>
  if [ "$3" != "$4" ]; then ok "G[$1] $2 -> the guarding scenario FAILS on the mutant (got '$3', the rule says '$4')"; else bad "G[$1] $2 -> the mutant still passes the guarding scenario ('$3'): the selftest does not guard this rule"; fi
}

clear_stores; write_store city "$BIG_WA"
if mutate window '--json --limit 0 2>/dev/null' '--json --limit=20 2>/dev/null' 2; then
  DISP="$WORK/mut/window.sh"; killed window "the window of 20 is back (both queries)" "$(run_topup wa-worker bd)" "wa-p0-oldfeat"; DISP="$DISPATCHER"
fi
if mutate noorder 'work_order_sort --age "$_age")' 'cat)'; then
  DISP="$WORK/mut/noorder.sh"; killed noorder "the ordering is gone (bd's order again)" "$(run_topup wa-worker bd)" "wa-p0-oldfeat"; DISP="$DISPATCHER"
fi
if mutate age 'work_order_sort --age "$_age")' 'work_order_sort --age created)'; then
  DISP="$WORK/mut/age.sh"; killed age "the reclaim age is reverted to created_at" "$(pick_direct "$B4")" "b4-plain"; DISP="$DISPATCHER"
fi
if mutate empty "printf '%s' \"\$_prev\"" 'true'; then
  DISP="$WORK/mut/empty.sh"; LIBMODE=none; killed empty "'cannot tell' is read as an empty queue" "$(pick_direct "$CT")" "ct-first"; LIBMODE=ok; DISP="$DISPATCHER"
fi
# the FIRST stage (C6..C8): each of its three guards reverted in a copy must fail the case that guards it.
if mutate firststage '*[![:space:]]*)' '*[![:space:]]X)'; then
  DISP="$WORK/mut/firststage.sh"; pick_direct '{"error":"database unavailable"}' >/dev/null
  _w="$(grep -c 'not a JSON array' "$WORK/run.err")"; DISP="$DISPATCHER"
  killed firststage "input that is not a JSON array ends silently again (the same as an empty queue)" "$_w" "1"
fi
if mutate title '(((.title // "") | tostring) | test($epic_re; "i"))' '((.title // "") | test($epic_re; "i"))'; then
  DISP="$WORK/mut/title.sh"; killed title "a title that is not a string makes jq fail on the whole array again" "$(pick_direct "$C7")" "c7-p0-feature"; DISP="$DISPATCHER"
fi
if mutate nonbead '.[] | select(type == "object") | select(' '.[] | select('; then
  DISP="$WORK/mut/nonbead.sh"; killed nonbead "elements that are not beads take the whole array down again" "$(pick_direct "$C8")" "c8-p0-feature"; DISP="$DISPATCHER"
fi
if mutate stderr 'work_order_sort --age "$_age")' 'work_order_sort --age "$_age" 2>/dev/null)'; then
  DISP="$WORK/mut/stderr.sh"; pick_direct "$C1" >/dev/null
  _w="$(grep -c '^work-order WARN: c1-bad-prio' "$WORK/run.err")"; DISP="$DISPATCHER"
  killed stderr "the library's stderr is swallowed (the WARN lines vanish)" "$_w" "1"
fi

if mutate gate '_mig=0; _topup_worker_probe_migrated "$_pool" || _mig=$?' '_mig=0'; then
  DISP="$WORK/mut/gate.sh"
  set_worker_template wa-worker legacy; clear_stores; write_store city "$GB"; run_sweeps wa-worker 8
  _g="$(f_braked f-first)"; DISP="$DISPATCHER"
  killed gate "the brake counts every spawn again, whatever the worker's probe (the gate bypassed; F1 shape)" "$_g" "null"
fi
# the C5 judge on the real mutant: a swallowed stderr must be seen by the structural check too.
if [ -f "$WORK/mut/stderr.sh" ]; then
  DISP="$WORK/mut/stderr.sh"; _pfm="$(fn_src _topup_pick_first)"; DISP="$DISPATCHER"
  killed c5 "the library's stderr is swallowed -> the structural C5 judge" "$(c5_judge "$_pfm")" "ok"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "pilot-dispatcher.topup-order.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
