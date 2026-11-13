#!/usr/bin/env bash
# patrol-next-wisp.selftest.sh — behavioral guard for ga-d8dfjg9 (class of ga-jhsxo4p / ga-x9jivyf).
#
# ## Contents
#   - What it proves
#   - Groups
#   - Usage
#
# ## What it proves
# scripts/patrol-next-wisp.sh replaces the 8 pasted pour/burn blocks of the refinery formula and of the refinery and deacon prompts.
# The blocks it replaces poured without reading first, left the wisp they had just poured with no owner when the assign failed, read a
# failed read as "I have no wisp", and burned the wrong wisp. This selftest runs the script under a STATEFUL fake gc (a store on disk,
# one line "id|assignee|title|created_at" per wisp; faults armed per scenario as "mode:count"; a spy that logs every call) and, after
# every failure, runs it AGAIN in the same world: "no second pour" and "no burn of the current one" are asserted as the absence of the
# call AND as the state of the store.
#
# ## Groups
#   A healthy cycle (read before pour, args verbatim, assign by GC_AGENT, a re-run after exit 0 of a 2-live world is a no-op)
#   B a next wisp already exists: no pour; --burn-current picks the right wisp (GC_BEAD_ID live / older of two / ambiguous = nothing burned)
#   C the live read is "não sei" (fails, empty stdout, text, object): exit 1, no pour, no assign, no burn, no mail by guess
#   D the pour fails or answers with no usable id: exit 1, no assign by guess, mail to the mayor
#   E the assign fails (applied or not): the wisp just poured is burned, never the current one; the re-run converges to ONE next wisp
#   F the burn of the current wisp fails: exit 1, a re-run does not pour again and ends with ONE live wisp
#   G bootstrap: pours only when none is live; unreadable = no pour
#   H GC_BEAD_ID stale (a burned wisp, set once at session start): ignored, never burned, never trusted
#   I scope: another formula's molecule, or another agent's wisp, is not "mine"; an identity with a space reaches the store whole
#   J usage: no GC_AGENT / unknown mode / no gc on PATH = exit 2 or an inert exit, nothing called
#
# ## Usage
#   bash patrol-next-wisp.selftest.sh        (PATROL_SCRIPT_UNDER_TEST=<path> runs another copy: mutants)
# Exit 0 iff every scenario holds; 2 when the harness cannot run (never read as a pass).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${PATROL_SCRIPT_UNDER_TEST:-$SELF_DIR/scripts/patrol-next-wisp.sh}"
PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$SCRIPT" ] || { echo "FATAL: script not found at $SCRIPT" >&2; exit 2; }
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }

echo "patrol-next-wisp.selftest — ga-d8dfjg9: read before pour, assign read, burn the right wisp, three states"

AGENT="gastown/refinery"
F="mol-refinery-patrol"

# ── Stub gc + sandbox PATH ────────────────────────────────────────────────────
STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"

cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# fake gc with state. $WORLD: store ("id|assignee|title|created_at" per wisp), seq (pours attempted), spy (one line per call), fault.<kind> ("mode:count").
W="${WORLD:-}"
[ -n "$W" ] && [ -d "$W" ] || { echo "stub gc: WORLD is not set" >&2; exit 98; }
printf 'GC %s\n' "$*" >> "$W/spy"
sf="$W/store"
fault_mode() {
  local f="$W/fault.$1" line mode n
  [ -f "$f" ] || return 1
  line=$(cat "$f"); mode=${line%%:*}; n=${line##*:}
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  n=$((n - 1))
  if [ "$n" -gt 0 ]; then printf '%s:%s\n' "$mode" "$n" > "$f"; else rm -f "$f"; fi
  printf '%s' "$mode"
}
has_id() { grep -q "^$1|" "$sf"; }
case "${1:-}" in
  mail) exit 0 ;;
  runtime|session) exit 0 ;;
  bd)
    shift
    case "${1:-}" in
      list)
        who=""; lim=50; typ=""; infra=0
        for a in "$@"; do
          case "$a" in
            --assignee=*) who=${a#--assignee=} ;;
            --limit=*) lim=${a#--limit=} ;;
            --type=*) typ=${a#--type=} ;;
            --include-infra) infra=1 ;;
          esac
        done
        if m=$(fault_mode list); then
          case "$m" in
            fail)     echo "Error: timed out after 30s" >&2; exit 1 ;;
            failjson) echo "Error: timed out after 30s" >&2; printf '[]'; exit 1 ;;
            empty)    exit 0 ;;
            text)     echo "Error: database is locked"; exit 0 ;;
            object)   printf '{"error":"x"}'; exit 0 ;;
          esac
        fi
        # a wisp is invisible without --include-infra and under any type but molecule (the real bd: ga-3v2n4)
        [ "$infra" = 1 ] && [ "$typ" = molecule ] || { printf '[]'; exit 0; }
        out=""; n=0
        while IFS='|' read -r id as ti ca; do
          [ -n "$id" ] || continue
          [ "$as" = "$who" ] || continue
          [ "$lim" = 0 ] || [ "$n" -lt "$lim" ] || break
          out="$out${out:+,}{\"id\":\"$id\",\"assignee\":\"$as\",\"title\":\"$ti\",\"status\":\"open\",\"issue_type\":\"molecule\",\"created_at\":\"$ca\"}"
          n=$((n + 1))
        done < "$sf"
        printf '[%s]' "$out"
        exit 0
        ;;
      update)
        id=${2:-}; who=""
        for a in "$@"; do
          case "$a" in --assignee=*) who=${a#--assignee=} ;; esac
        done
        um=$(fault_mode update) || um=ok
        case "$um" in
          fail)        echo "Error: 1 of 1 issues failed to update (timed out after 30s)" >&2; exit 1 ;;
          failapplied) has_id "$id" && { awk -F'|' -v id="$id" -v w="$who" 'BEGIN{OFS="|"} $1==id{$2=w} {print}' "$sf" > "$sf.new" && mv "$sf.new" "$sf"; }
                       echo "Error: 1 of 1 issues failed to update (timed out after 30s)" >&2; exit 1 ;;
        esac
        has_id "$id" || { echo "Error resolving $id: no issue found" >&2; exit 1; }
        awk -F'|' -v id="$id" -v w="$who" 'BEGIN{OFS="|"} $1==id{$2=w} {print}' "$sf" > "$sf.new" && mv "$sf.new" "$sf"
        exit 0
        ;;
      mol)
        case "${2:-}" in
          wisp)
            ti=${3:-}
            pm=$(fault_mode pour) || pm=ok
            n=$(cat "$W/seq"); n=$((n + 1)); echo "$n" > "$W/seq"; id="ga-wisp-new$n"
            case "$pm" in
              fail)    echo "Error: timed out after 30s" >&2; exit 1 ;;
              noid)    echo "$id||$ti|2026-11-13T10:0$n:00Z" >> "$sf"; exit 1 ;;
              garbage) echo "$id||$ti|2026-11-13T10:0$n:00Z" >> "$sf"; echo "Created wisp"; exit 0 ;;
              nokey)   echo "$id||$ti|2026-11-13T10:0$n:00Z" >> "$sf"; printf '{"created":1,"phase":"vapor"}'; exit 0 ;;
              badid)   echo "$id||$ti|2026-11-13T10:0$n:00Z" >> "$sf"; printf '{"new_epic_id":"ga-wisp bad;id"}'; exit 0 ;;   # created, the answer is an id with a space and a ;
            esac
            echo "$id||$ti|2026-11-13T10:0$n:00Z" >> "$sf"
            printf '{"new_epic_id":"%s","created":1,"phase":"vapor"}' "$id"
            exit 0
            ;;
          burn)
            id=${3:-}
            if fault_mode burn >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
            has_id "$id" || { echo "Error: $id not found" >&2; exit 1; }
            grep -v "^$id|" "$sf" > "$sf.new"; mv "$sf.new" "$sf"
            exit 0
            ;;
        esac
        ;;
    esac
    echo "unstubbed gc bd call: $*" >&2
    exit 99
    ;;
esac
echo "unstubbed gc call: $*" >&2
exit 99
STUB
chmod +x "$STUBDIR/bin/gc"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2

# ── World + runner ────────────────────────────────────────────────────────────
W=""
CUR_ID="ga-wisp-cur"
# world_new [rows...]: a fresh world. Default: the wisp being executed (ga-wisp-cur, created first) is live and mine.
world_new() {
  W="$(mktemp -d "$STUBDIR/world.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
  : > "$W/store"; : > "$W/spy"; echo 0 > "$W/seq"
  if [ "$#" -eq 0 ]; then printf '%s|%s|%s|2026-11-13T09:00:00Z\n' "$CUR_ID" "$AGENT" "$F" > "$W/store"; else for r in "$@"; do printf '%s\n' "$r" >> "$W/store"; done; fi
}
arm() { printf '%s:%s\n' "$2" "$3" > "$W/fault.$1"; }   # arm KIND MODE COUNT
row() { printf '%s|%s|%s|%s' "$1" "${2:-$AGENT}" "${3:-$F}" "${4:-2026-11-13T09:00:00Z}"; }   # row ID [ASSIGNEE [TITLE [CREATED]]]

# run_script ARGS... [-- env: VAR=value ...]  — one run in a clean environment (env -i: none of this session's GC_* leaks in).
# Sets OUT (stdout+stderr), RC, SPY_LOG (the gc calls of THIS run). The world persists between runs: that is the point.
ENVV=()
run() {
  : > "$W/spy"
  OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" WORLD="$W" GC_AGENT="$AGENT" ${ENVV[@]+"${ENVV[@]}"} bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  SPY_LOG="$(cat "$W/spy")"
}
spy_n()     { printf '%s\n' "$SPY_LOG" | grep -c -E -- "$1"; }
spy_first() { printf '%s\n' "$SPY_LOG" | grep -n -E -- "$1" | head -n 1 | cut -d: -f1; }
POUR_RE='^GC bd mol wisp'
BURN_RE='^GC bd mol burn'
UPDATE_RE='^GC bd update '
LIST_RE='^GC bd list '
MAIL_RE='^GC mail send'
pours()   { cat "$W/seq"; }
live_n()  { grep -c . "$W/store"; }
has_live() { grep -q "^$1|" "$W/store"; }
unowned_n() { awk -F'|' '$1 != "" && $2 == "" { n++ } END { print n + 0 }' "$W/store"; }   # live wisps with no owner = the leak
mail_to_mayor_only() { [ "$(spy_n "$MAIL_RE")" -ge 1 ] && [ "$(spy_n "$MAIL_RE")" -eq "$(spy_n '^GC mail send mayor/ ')" ]; }
# inert: nothing was poured, assigned or burned, and no mail went out
inert() { [ "$(spy_n "$POUR_RE")" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 0 ]; }

ARGS=(next "$F" -- --var target_branch=main --var rig_name=wa --var binding_prefix=bp)

# ── Group A ───────────────────────────────────────────────────────────────────
echo ""; echo "Group A: healthy cycle (this wisp live, no next one)"
world_new
run "${ARGS[@]}"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_n)" -eq 2 ] && [ "$(unowned_n)" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && has_live "$CUR_ID"; then
  ok "exit 0, one pour, the next wisp is owned, this wisp neither burned nor touched (no --burn-current)"
else bad "healthy cycle (exit $RC, pours=$(pours), live=$(live_n), unowned=$(unowned_n)) :: $OUT"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd list --assignee=$AGENT --type=molecule --include-infra --limit=0 --json"; then ok "the read is by GC_AGENT, molecules incl. infra, all of them (--limit=0)"
else bad "the read is not '--assignee=GC_AGENT --type=molecule --include-infra --limit=0 --json': $SPY_LOG"; fi
r="$(spy_first "$LIST_RE")"; p="$(spy_first "$POUR_RE")"
if [ -n "$r" ] && [ -n "$p" ] && [ "$r" -lt "$p" ]; then ok "the read comes BEFORE the pour"; else bad "the read does not precede the pour ($r / $p): $SPY_LOG"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol wisp $F --root-only --var target_branch=main --var rig_name=wa --var binding_prefix=bp --json"; then ok "the pour carries the formula, --root-only and the caller's --var flags verbatim"
else bad "the pour line is not the expected one: $SPY_LOG"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd update ga-wisp-new1 --assignee=$AGENT"; then ok "the assign names the id the pour answered and GC_AGENT"; else bad "the assign is not 'update <pour id> --assignee=GC_AGENT': $SPY_LOG"; fi
a="$(spy_first "$UPDATE_RE")"
if [ -n "$a" ] && [ -n "$p" ] && [ "$a" -gt "$p" ] && [ "$(spy_n '^GC bd show')" -eq 0 ]; then ok "assign after the pour, and no read-back in between (the 5cl2vvn window: a failed read-back leaves an unowned wisp)"; else bad "assign order or read-back wrong: $SPY_LOG"; fi
run "${ARGS[@]}"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_n)" -eq 2 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then ok "IDEMPOTENT: a second run in the world with a next wisp pours/assigns/burns nothing, exit 0"
else bad "second run is not a no-op (exit $RC, pours=$(pours), live=$(live_n)) :: $OUT"; fi
world_new
run next "$F" --burn-current -- --var k=v
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_n)" -eq 1 ] && ! has_live "$CUR_ID" && [ "$(unowned_n)" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ]; then ok "--burn-current without GC_BEAD_ID: the one live wisp was the current one: next poured+owned, current burned, ONE live wisp left"
else bad "--burn-current healthy (exit $RC, pours=$(pours), live=$(live_n)) :: $OUT $SPY_LOG"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol burn $CUR_ID --force"; then ok "the burn names the CURRENT wisp, with --force"; else bad "the burn is not 'mol burn $CUR_ID --force': $SPY_LOG"; fi
b="$(spy_first "$BURN_RE")"; u="$(spy_first "$UPDATE_RE")"
if [ -n "$b" ] && [ -n "$u" ] && [ "$b" -gt "$u" ]; then ok "the burn comes AFTER the assign (pour, assign, only then burn)"; else bad "burn does not follow the assign: $SPY_LOG"; fi
world_new
run next "$F" --burn-current
if [ "$RC" -eq 0 ] && [ "$(spy_n "$POUR_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol wisp $F --root-only --json"; then ok "no pour args at all (the deacon has none beyond its vars): the pour is 'mol wisp F --root-only --json'"; else bad "empty pour args broke the pour (exit $RC): $OUT $SPY_LOG"; fi
world_new "$(row ga-wisp-x "$AGENT" "$F" 2026-11-13T09:00:00Z)"
run next "$F" --burn-current -- --var 'test_command=/v/bin/python3 -m pytest tests/ -q'
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol wisp $F --root-only --var test_command=/v/bin/python3 -m pytest tests/ -q --json"; then ok "a pour arg with spaces stays ONE word (test_command)"; else bad "a spaced pour arg was split or lost: $SPY_LOG"; fi

# ── Group B ───────────────────────────────────────────────────────────────────
echo ""; echo "Group B: a next wisp already exists"
world_new "$(row ga-wisp-cur)" "$(row ga-wisp-nxt "$AGENT" "$F" 2026-11-13T09:05:00Z)"
run "${ARGS[@]}"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 0 ]; then ok "two live wisps: no pour, no assign, no burn, exit 0 (the pour-after-pour of the old text)"; else bad "two live wisps: (exit $RC, pours=$(pours)) :: $OUT"; fi
world_new "$(row ga-wisp-cur)" "$(row ga-wisp-nxt "$AGENT" "$F" 2026-11-13T09:05:00Z)"
ENVV=(GC_BEAD_ID=ga-wisp-cur); run next "$F" --burn-current; ENVV=()
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && ! has_live ga-wisp-cur && has_live ga-wisp-nxt && [ "$(live_n)" -eq 1 ]; then ok "--burn-current with GC_BEAD_ID live: no pour, burns exactly the current wisp, keeps the next"; else bad "burn with GC_BEAD_ID (exit $RC): $OUT $(cat "$W/store")"; fi
world_new "$(row ga-wisp-nxt "$AGENT" "$F" 2026-11-13T09:05:00Z)" "$(row ga-wisp-cur "$AGENT" "$F" 2026-11-13T09:00:00Z)"
run next "$F" --burn-current
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && ! has_live ga-wisp-cur && has_live ga-wisp-nxt; then ok "--burn-current without GC_BEAD_ID, two live: burns the OLDER one (the store lists the next first, so order is not what decides)"; else bad "older-of-two burn (exit $RC): $OUT $(cat "$W/store")"; fi
world_new "$(row ga-wisp-a "$AGENT" "$F" 2026-11-13T09:00:00Z)" "$(row ga-wisp-b "$AGENT" "$F" 2026-11-13T09:00:00Z)"
run next "$F" --burn-current
if [ "$RC" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(live_n)" -eq 2 ] && printf '%s' "$OUT" | grep -q 'ga-wisp-a' && printf '%s' "$OUT" | grep -q 'ga-wisp-b'; then ok "two live with the SAME created_at: cannot tell which is current -> nothing burned, exit 1, both ids printed"; else bad "tie did not stop (exit $RC): $OUT"; fi
world_new "$(row ga-wisp-a "$AGENT" "$F" "")" "$(row ga-wisp-b "$AGENT" "$F" 2026-11-13T09:00:00Z)"
run next "$F" --burn-current
if [ "$RC" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then ok "two live, one without created_at: not burned by guess, exit 1"; else bad "missing created_at was guessed (exit $RC): $OUT"; fi
world_new "$(row ga-wisp-a "$AGENT" "$F" 2026-11-13T09:00:00Z)" "$(row ga-wisp-b "$AGENT" "$F" 2026-11-13T09:01:00Z)" "$(row ga-wisp-c "$AGENT" "$F" 2026-11-13T09:02:00Z)"
run next "$F" --burn-current
if [ "$RC" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(pours)" -eq 0 ]; then ok "three live (a stray among them), no GC_BEAD_ID: no pour, nothing burned by guess, exit 1"; else bad "three live (exit $RC, pours=$(pours)): $OUT"; fi

# ── Group C ───────────────────────────────────────────────────────────────────
echo ""; echo "Group C: the live read is 'não sei' -> inert"
for m in fail failjson empty text object; do
  world_new; arm list "$m" 1
  run next "$F" --burn-current -- --var k=v
  if [ "$RC" -eq 1 ] && inert && [ "$(pours)" -eq 0 ] && [ "$(live_n)" -eq 1 ]; then ok "read '$m': exit 1, no pour/assign/burn/mail, store untouched (not read as 'no wisp')"; else bad "read '$m' was not inert (exit $RC, pours=$(pours)) :: $OUT $SPY_LOG"; fi
  if printf '%s' "$OUT" | grep -q 'NOT pouring'; then ok "read '$m': says it is NOT pouring"; else bad "read '$m': no 'NOT pouring' in the output: $OUT"; fi
  run next "$F" --burn-current -- --var k=v     # the fault is spent: the re-run works and converges
  if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_n)" -eq 1 ] && [ "$(unowned_n)" -eq 0 ]; then ok "read '$m': the re-run converges (one pour, one owned live wisp)"; else bad "read '$m': re-run did not converge (exit $RC, pours=$(pours), live=$(live_n)) :: $OUT"; fi
done
world_new; arm list fail 1
run bootstrap "$F" -- --var k=v
if [ "$RC" -eq 1 ] && inert; then ok "bootstrap, read failed: no pour (the prompts' old 'pour unconditionally' is gone), exit 1"; else bad "bootstrap with a failed read poured (exit $RC): $OUT $SPY_LOG"; fi

# ── Group D ───────────────────────────────────────────────────────────────────
echo ""; echo "Group D: the pour fails or answers without a usable id"
for m in fail noid garbage nokey badid; do
  world_new; arm pour "$m" 1
  run "${ARGS[@]}"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && mail_to_mayor_only; then ok "pour '$m': exit 1, no assign and no burn by guess, the mayor is mailed"; else bad "pour '$m' (exit $RC, updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE"), mails=$(spy_n "$MAIL_RE")) :: $OUT"; fi
  if has_live "$CUR_ID"; then ok "pour '$m': the current wisp is untouched"; else bad "pour '$m': the current wisp is gone"; fi
done
world_new; arm pour noid 1
run "${ARGS[@]}"
if printf '%s\n' "$SPY_LOG" | grep -F -q 'gc bd list --no-assignee --type=molecule --include-infra'; then ok "the mail carries the read that finds the stray (--no-assignee ... --include-infra)"; else bad "the mail does not name the read that finds the stray: $SPY_LOG"; fi

# ── Group E ───────────────────────────────────────────────────────────────────
echo ""; echo "Group E: the assign fails"
for m in fail failapplied; do
  world_new; arm update "$m" 1
  run next "$F" --burn-current -- --var k=v
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol burn ga-wisp-new1 --force" && has_live "$CUR_ID" && [ "$(live_n)" -eq 1 ]; then ok "assign '$m': burns the wisp JUST POURED (never the current one); nothing left behind; exit 1"; else bad "assign '$m' (exit $RC, live=$(live_n)) :: $OUT $SPY_LOG"; fi
  if [ "$(unowned_n)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 0 ]; then ok "assign '$m': no unowned wisp, no mail (the cleanup worked)"; else bad "assign '$m': leak or mail: unowned=$(unowned_n) mails=$(spy_n "$MAIL_RE")"; fi
  run next "$F" --burn-current -- --var k=v
  if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 2 ] && [ "$(live_n)" -eq 1 ] && [ "$(unowned_n)" -eq 0 ] && ! has_live "$CUR_ID"; then ok "assign '$m': the re-run converges: ONE next wisp, owned, current burned (pours=2 is the retry, not a leak)"; else bad "assign '$m': re-run (exit $RC, pours=$(pours), live=$(live_n), unowned=$(unowned_n)) :: $OUT"; fi
done
world_new; arm update fail 1; arm burn fail 1
run next "$F" --burn-current
if [ "$RC" -eq 1 ] && mail_to_mayor_only && [ "$(unowned_n)" -eq 1 ] && printf '%s' "$OUT" | grep -q 'ga-wisp-new1' && has_live "$CUR_ID"; then ok "assign AND burn fail: exit 1, the stray's id is in the output and mailed to the mayor, the current wisp is untouched"; else bad "assign+burn failure (exit $RC, mails=$(spy_n "$MAIL_RE"), unowned=$(unowned_n)) :: $OUT"; fi

# ── Group F ───────────────────────────────────────────────────────────────────
echo ""; echo "Group F: the burn of the current wisp fails"
world_new; arm burn fail 1
run next "$F" --burn-current -- --var k=v
if [ "$RC" -eq 1 ] && [ "$(live_n)" -eq 2 ] && [ "$(unowned_n)" -eq 0 ] && printf '%s' "$OUT" | grep -q "$CUR_ID"; then ok "burn fails: exit 1, next wisp stays owned, the unburned current is named"; else bad "burn failure (exit $RC, live=$(live_n)) :: $OUT"; fi
run next "$F" --burn-current -- --var k=v
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_n)" -eq 1 ] && ! has_live "$CUR_ID" && [ "$(unowned_n)" -eq 0 ]; then ok "the re-run does NOT pour again and ends with ONE live wisp (the older one burned)"; else bad "re-run after a burn failure (exit $RC, pours=$(pours), live=$(live_n)) :: $OUT"; fi

# ── Group G ───────────────────────────────────────────────────────────────────
echo ""; echo "Group G: bootstrap"
world_new ""; : > "$W/store"
run bootstrap "$F" -- --var k=v
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_n)" -eq 1 ] && [ "$(unowned_n)" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then ok "no live wisp: one pour, owned, nothing burned"; else bad "bootstrap from empty (exit $RC, pours=$(pours), live=$(live_n)) :: $OUT"; fi
run bootstrap "$F" -- --var k=v
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ]; then ok "IDEMPOTENT: a second bootstrap pours nothing (the old prompt poured on every session start)"; else bad "second bootstrap poured (exit $RC, pours=$(pours)) :: $OUT"; fi
world_new
run bootstrap "$F" -- --var k=v
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && inert && printf '%s' "$OUT" | grep -q "$CUR_ID"; then ok "one live wisp (a restarted session): no pour, names it, exit 0"; else bad "bootstrap with a live wisp (exit $RC, pours=$(pours)) :: $OUT"; fi
world_new ""; : > "$W/store"; arm pour noid 1
run bootstrap "$F"
if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && mail_to_mayor_only; then ok "bootstrap, pour with no id: exit 1, no assign by guess, mayor mailed"; else bad "bootstrap noid (exit $RC): $OUT"; fi
world_new ""; : > "$W/store"; arm update fail 1
run bootstrap "$F"
if [ "$RC" -eq 1 ] && [ "$(live_n)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 0 ]; then ok "bootstrap, assign fails: the wisp just poured is burned, nothing left behind, exit 1"; else bad "bootstrap assign failure (exit $RC, live=$(live_n)): $OUT"; fi
run bootstrap "$F"
if [ "$RC" -eq 0 ] && [ "$(live_n)" -eq 1 ] && [ "$(unowned_n)" -eq 0 ]; then ok "bootstrap re-run converges to ONE owned wisp"; else bad "bootstrap re-run (exit $RC, live=$(live_n)): $OUT"; fi
world_new; run bootstrap "$F" --burn-current
if [ "$RC" -eq 2 ] && [ "$(spy_n '^GC ')" -eq 0 ]; then ok "bootstrap --burn-current is refused (exit 2), nothing called"; else bad "bootstrap --burn-current was not refused (exit $RC): $OUT"; fi

# ── Group H ───────────────────────────────────────────────────────────────────
echo ""; echo "Group H: GC_BEAD_ID names a burned wisp (set once at session start)"
world_new "$(row ga-wisp-y "$AGENT" "$F" 2026-11-13T09:10:00Z)"
ENVV=(GC_BEAD_ID=ga-wisp-x-burned); run next "$F" --burn-current -- --var k=v; ENVV=()
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && ! has_live ga-wisp-y && [ "$(live_n)" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol burn ga-wisp-y --force"; then ok "stale GC_BEAD_ID: ignored; the wisp that is REALLY live is burned (the old text burned the stale id and leaked the real one)"; else bad "stale GC_BEAD_ID (exit $RC, pours=$(pours)) :: $OUT $SPY_LOG"; fi
world_new "$(row ga-wisp-y "$AGENT" "$F" 2026-11-13T09:10:00Z)"
ENVV=(GC_BEAD_ID=ga-wisp-x-burned); run next "$F" -- --var k=v; ENVV=()
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then ok "stale GC_BEAD_ID without --burn-current: one live wisp is read as 'the current one' -> pours"; else bad "stale GC_BEAD_ID, no burn (exit $RC, pours=$(pours)): $OUT"; fi

# ── Group I ───────────────────────────────────────────────────────────────────
echo ""; echo "Group I: what counts as 'mine'"
world_new "$(row ga-wisp-cur)" "$(row ga-wisp-other "$AGENT" mol-witness-patrol 2026-11-13T09:05:00Z)"
run "${ARGS[@]}"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ]; then ok "another formula's molecule of mine is not a 'next wisp' (it would stall the loop): pours"; else bad "foreign molecule counted (exit $RC, pours=$(pours)): $OUT"; fi
world_new "$(row ga-wisp-cur)" "$(row ga-wisp-theirs other/refinery "$F" 2026-11-13T09:05:00Z)"
run "${ARGS[@]}"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ]; then ok "another agent's wisp is not mine: pours"; else bad "foreign assignee counted (exit $RC, pours=$(pours)): $OUT"; fi
SP="gastown refinery"
world_new "$(row ga-wisp-cur "$SP")"
AGENT_SAVE="$AGENT"; AGENT="$SP"; run "${ARGS[@]}"; AGENT="$AGENT_SAVE"
# the spy joins argv with spaces, so a split identity looks the same in it: what proves the quote is what the STORE received
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(awk -F'|' '$1 == "ga-wisp-new1" { print $2 }' "$W/store")" = "$SP" ]; then ok "an identity with a space reaches the ASSIGN whole (the store's owner of the new wisp is the full identity)"; else bad "identity with a space in the assign (exit $RC): owner=[$(awk -F'|' '$1 == "ga-wisp-new1" { print $2 }' "$W/store")] $OUT $SPY_LOG"; fi
world_new "$(row ga-wisp-cur "$SP")" "$(row ga-wisp-nxt "$SP" "$F" 2026-11-13T09:05:00Z)"
AGENT_SAVE="$AGENT"; AGENT="$SP"; run "${ARGS[@]}"; AGENT="$AGENT_SAVE"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ]; then ok "an identity with a space reaches the READ whole (its two live wisps are found: no pour)"; else bad "identity with a space in the read (exit $RC, pours=$(pours)): $OUT"; fi

# ── Group J ───────────────────────────────────────────────────────────────────
echo ""; echo "Group J: usage and harness"
world_new
OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" WORLD="$W" bash "$SCRIPT" next "$F" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [ ! -s "$W/spy" ]; then ok "GC_AGENT empty: exit 2, no gc call (cannot tell which wisps are mine)"; else bad "empty GC_AGENT (exit $RC): $OUT"; fi
run frobnicate "$F"
if [ "$RC" -eq 2 ] && [ ! -s "$W/spy" ]; then ok "unknown mode: exit 2, no gc call"; else bad "unknown mode (exit $RC): $OUT"; fi
run next
if [ "$RC" -eq 2 ] && [ ! -s "$W/spy" ]; then ok "no formula: exit 2, no gc call"; else bad "missing formula (exit $RC): $OUT"; fi
OUT="$(env -i HOME="$STUBDIR" PATH="/usr/bin:/bin" WORLD="$W" GC_AGENT="$AGENT" bash "$SCRIPT" next "$F" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "no gc and no jq on PATH: non-zero, nothing poured (exit $RC)"; else bad "ran with no tools and said exit 0: $OUT"; fi

echo ""
echo "== patrol-next-wisp.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
